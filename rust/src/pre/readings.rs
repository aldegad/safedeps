//! Read each shell interpretation once, with the hook's target answers.
//! The core owns detection and specs. This layer keeps the target evidence
//! and records which unpinned operands have no effect gate behind them.
use super::{cat, targets, W};
use crate::{core::{self, Facts, Run}, ere::Regex, grammar, json::{self,Value}, lex::Reading, os};

pub fn name(r:Reading)->&'static str {match r {Reading::Bash=>"bash",Reading::Zsh=>"zsh",Reading::Dash=>"dash"}}
pub struct Readings {
    pub facts:Facts,
    pub set:Vec<Reading>,
    pub targets:Vec<targets::Target>,
    pub npm_seen:bool,
    pub npm_all_global:bool,
}
impl Readings {
    pub fn field(&self,key:&str)->&[u8] {self.facts.records.iter().find(|(k,_)|k==key).map(|(_,v)|v.as_slice()).unwrap_or_default()}
    pub fn yes(&self,key:&str)->bool {
        // The diagnostic record of detection precedes facts. The hook needs
        // the union after any additional reading was brought in by facts.
        if key=="piped"{self.facts.piped}else{self.field(key)==b"true"}
    }
    pub fn collect(run:&mut Run,command:&[u8],cwd:&[u8])->Self {
        let mut questions=targets::Questions::default();let mut targets=Vec::new();
        let npm=Regex::new(&grammar::patterns().npm_install_re,true).expect("npm install grammar");
        let mut seen=false;let mut all_global=true;
        let facts=run.facts_with(command,|run|{
            let resolved=targets::resolve(run,command,cwd,&mut questions);
            let mut fields=Vec::new();let mut found=false;
            for t in resolved {
                // resolve_install_targets is read as five IFS fields by its
                // consumers. Keep that boundary, including raw control bytes.
                let rendered=t.render();
                for line in rendered.split(|b|*b==b'\n').filter(|l|!l.is_empty()) {
                    let mut f=core::read_fields(line,&[0x1d],5).into_iter();
                    let kind=String::from_utf8_lossy(&f.next().unwrap()).into_owned();
                    let dir=f.next().unwrap();let why=f.next().unwrap();let fetch=f.next().unwrap();let words=f.next().unwrap();
                    if kind=="npm"||kind=="npm-unrecorded"{found=true;if dir!=b"global"{all_global=false}}
                    fields.push((kind.clone(),words.clone()));
                    targets.push(targets::Target{kind,dir,why,fetch:json::parse_one(&fetch).ok(),fields:words});
                }
            }
            if found {
                seen=true;
                for payload in run.raw_texts(command) {
                    let text=run.lex(&payload,"recognize").unwrap_or_default();
                    if npm.grep_any(&text){all_global=false;break}
                }
            }
            fields
        });
        let set=facts.records.iter().rev().find(|(k,_)|k=="reading_set.facts"||k=="reading_set")
            .map(|(_,v)|v.split(|b|*b==b' ').filter_map(|n|match n{b"bash"=>Some(Reading::Bash),b"zsh"=>Some(Reading::Zsh),b"dash"=>Some(Reading::Dash),_=>None}).collect()).unwrap_or_default();
        Self{facts,set,targets,npm_seen:seen,npm_all_global:all_global}
    }
    pub fn project(&self,cwd:&[u8])->(W,&'static str,Option<Value>,W) {
        for t in &self.targets {
            if t.dir.is_empty()||t.dir==b"?"||t.dir==b"global"{continue}
            return (t.dir.clone(),"target",t.fetch.clone(),if t.why.is_empty(){b"npm was not asked".to_vec()}else{t.why.clone()})
        }
        (cwd.to_vec(),"cwd",None,b"no npm install in this command named where it lands".to_vec())
    }
    pub fn reasons(&self)->Vec<W> {
        let mut out=Vec::new();
        for t in &self.targets {
            let mut lines=t.why.clone();
            if let Some(Value::Obj(fields))=&t.fetch {
                if fields.first().is_some_and(|(k,_)|k==b"unknown") {
                    if !lines.is_empty(){lines.push(b'\n')}
                    lines.extend_from_slice(&super::jq_r(t.fetch.as_ref().and_then(|v|v.get("unknown"))));
                }
            }
            for line in lines.split(|b|*b==b'\n').filter(|l|!l.is_empty()) {
                if !out.iter().any(|v:&W|v==line){out.push(line.to_vec())}
            }
        }out
    }
    pub fn ungated(&self,project:&[u8])->(W,W) {
        let mut eco=W::new();let mut all=W::new();
        for &r in &self.set {
            let i=match r{Reading::Bash=>0,Reading::Zsh=>1,Reading::Dash=>2};
            if self.facts.hidden[i]{continue}
            let e=self.field(&format!("eco.{}",name(r)));if e.is_empty(){continue}
            let operands=ungated(self.field(&format!("readings.{}",name(r))),project);
            if operands.is_empty(){continue}
            if eco.is_empty(){eco=e.to_vec()}
            if !all.is_empty(){all.extend_from_slice(b", ")}all.extend_from_slice(&operands);
        }(eco,all)
    }
}

fn split(s:&[u8])->(&[u8],&[u8]) {s.iter().position(|b|*b==b'\t').map(|i|(&s[..i],&s[i+1..])).unwrap_or((s,s))}
fn ungated(readings:&[u8],project:&[u8])->W {
    let mut out=W::new();let mut eco=W::new();let mut local=false;let mut reads=false;let mut bound=Vec::<W>::new();let mut ops=Vec::<W>::new();
    let record=|out:&mut W,eco:&[u8],local:bool,reads:bool,bound:&[W],ops:&[W]|{
        if reads{return}
        for op in ops {
            let (at,rest)=split(op);let (role,text)=split(rest);
            if bound.iter().any(|p|p==at){continue}
            if role!=b"D"&&(text.starts_with(b"-")||text.starts_with(b"./")||text.starts_with(b"../")||text.starts_with(b"/")||text.starts_with(b"~/")||matches!(text,b"."|b".."|b"~")){continue}
            if role==b"r"&&local&&!text.is_empty()&&text.iter().all(|b|b.is_ascii_alphanumeric()||b"._-".contains(b))&&os::executable(&os::path(project).join("node_modules/.bin").join(os::path(text))){continue}
            if text.iter().all(|b|*b==2||super::is_space(*b)){continue}
            let entry=cat(&[eco,b":",text]);
            if cat(&[b", ",out,b", "]).windows(entry.len()+4).any(|w|w==cat(&[b", ",&entry,b", "]).as_slice()){continue}
            if !out.is_empty(){out.extend_from_slice(b", ")}
            out.extend(entry.iter().map(|b|if *b==2{b' '}else{*b}));
        }
    };
    for line in readings.split(|b|*b==b'\n') {
        if let Some(s)=line.strip_prefix(b"S\t") {
            record(&mut out,&eco,local,reads,&bound,&ops);
            let(e,s)=split(s);let(l,r)=split(s);eco=e.to_vec();local=l==b"true";reads=r==b"true";bound.clear();ops.clear();
        }else if let Some(s)=line.strip_prefix(b"@\tbound\t"){bound.push(s.to_vec())}
        else if let Some(s)=line.strip_prefix(b"O\t"){ops.push(s.to_vec())}
    }
    record(&mut out,&eco,local,reads,&bound,&ops);out
}

/// Consumer comparison: npm asks, the spec union and the post trace facts.
pub fn probe(input:&[u8])->i32 {
    use crate::{core::Core,jq};
    let Ok(v)=json::parse_one(input)else{return 2};
    let Some(command)=v.get("command").and_then(Value::as_bytes)else{return 2};
    let Some(cwd)=v.get("cwd").and_then(Value::as_bytes)else{return 2};
    let core=Core::new();let mut run=Run::new(&core);let read=Readings::collect(&mut run,&command,&cwd);
    let(project,from,fetch,why)=read.project(&cwd);let (eco,ungated)=read.ungated(&os::realpath(&project));
    let mut trace=false;let mut attribution=W::new();
    for &r in &read.set{run.reading=Some(r);let(wanted,why)=super::effects::trace(&mut run,&command);trace|=wanted;if attribution.is_empty(){attribution=why}}
    let specs=read.field("ledger_specs").strip_suffix(b"\n").unwrap_or(read.field("ledger_specs"));
    let fields=vec![
        ("reading_set",jq::s(&read.set.iter().map(|&r|name(r)).collect::<Vec<_>>().join(" "))),
        ("closed",jq::J::Bool(read.yes("closed"))),("any_install",jq::J::Bool(read.yes("any_install"))),
        ("piped",jq::J::Bool(read.yes("piped"))),("hidden_unreduced",jq::J::Bool(read.yes("hidden_unreduced"))),
        ("ledger_eco",jq::arg(read.field("ledger_eco"))),("ledger_specs",jq::arg(specs)),
        ("project",jq::arg(&project)),("project_from",jq::s(from)),
        ("fetch",fetch.as_ref().map(jq::from_value).unwrap_or(jq::J::Null)),("fetch_why",jq::arg(&why)),
        ("npm_seen",jq::J::Bool(read.npm_seen)),("npm_all_global",jq::J::Bool(read.npm_all_global)),
        ("ungated_eco",jq::arg(&eco)),("ungated",jq::arg(&ungated)),
        ("trace",jq::J::Bool(trace)),("attribution",jq::arg(&attribution)),("failed",jq::J::Bool(run.failed)),
    ];println!("{}",jq::compact(&jq::obj(fields)));0
}
