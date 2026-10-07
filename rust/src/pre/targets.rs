//! resolve_reading_targets. The lexer and manager supply statement structure;
//! this module follows literal directories and asks only the hook's own npm.
use super::{cat, captured, env_bytes, W};
use crate::{ask, core::{Core,Run,TargetStatement}, extract, jq, json::{self,Value}, lex::Reading, manager, os};
use std::{collections::HashMap, os::unix::ffi::OsStrExt, time::{Duration,Instant}};
mod env;
mod npmrc;

pub struct Target { pub kind:String, pub dir:W, pub why:W, pub fetch:Option<Value>, pub fields:W }
impl Target {
    pub fn render(&self)->W {
        let fetch=self.fetch.as_ref().map(|v|jq::compact(&jq::from_value(v)).into_bytes()).unwrap_or_default();
        cat(&[self.kind.as_bytes(),&[0x1d],&self.dir,&[0x1d],&self.why,&[0x1d],&fetch,&[0x1d],&self.fields,b"\n"])
    }
}
#[derive(Default)]
pub struct Questions { memo:HashMap<(W,Vec<W>,Vec<W>),ask::Target> }
impl Questions {
    fn ask(&mut self,dir:&[u8],until:Instant,q:&env::Question)->ask::Target {
        let key=(dir.to_vec(),q.env.clone(),q.args.clone());
        self.memo.entry(key).or_insert_with(||ask::install_target(&os::path(dir),until,&q.env,&q.args)).clone()
    }
}

fn literal_dir(dir:&[u8],path:&[u8])->W {
    if path.is_empty()||matches!(path[0],b'-'|b'~')||path.iter().any(|b|b"\x01$`*?[".contains(b)){return b"?".to_vec()}
    if path.starts_with(b"/"){return path.to_vec()}
    if dir==b"?"{return b"?".to_vec()}
    cat(&[dir.strip_suffix(b"/").unwrap_or(dir),b"/",path])
}
fn npm_word_is_hooks(word:&[u8],dir:&[u8])->bool {
    let Some(hook)=ask::npm_on_path()else{return false};
    if !hook.is_absolute(){return false}
    if word==hook.as_os_str().as_bytes(){return true}
    let Some(at)=word.iter().rposition(|b|*b==b'/')else{return false};
    let Some(parent)=hook.parent()else{return false};
    let there=std::fs::canonicalize(parent);
    let here=std::fs::canonicalize(os::path(dir).join(os::path(&word[..=at])));
    matches!((here,there),(Ok(a),Ok(b))if a==b)
}
fn fetch_after(f:Value,settings:&env::Settings,q:&env::Question)->Value {
    let changer=if !settings.changer.is_empty(){&settings.changer}else if !q.code.is_empty(){&q.code}else{&settings.code};
    if changer.is_empty(){return f}
    let mut cause="";
    if settings.setting.is_empty()&&matches!(f,Value::Obj(_))&&f.get("unknown").is_none_or(|v|matches!(v,Value::Null)) {
        let scopes=match f.get("scopes"){Some(Value::Obj(v))=>v.iter().all(|(_,v)|ask::registry_public(Some(v),&f)),_=>true};
        cause=if ask::registry_public(f.get("registry"),&f)&&scopes{"sourced"}else{"answered"};
    }
    if cause=="answered"{return f}
    let setting=if !settings.setting.is_empty(){&settings.setting}else{&settings.changer};
    let why=if !setting.is_empty(){cat(&[b"an earlier statement (",env::unmark(setting),b") can change the environment npm runs with where the command does not show it"])}
        else{cat(&[b"the command chooses the code npm runs with (",env::unmark(changer),b"), and safedeps asks only its own npm and never runs that code"])};
    let mut fields=vec![(b"unknown".to_vec(),Value::Str(cat(&[&why,b", so safedeps cannot tell which registry this install fetches from"])))];
    if !cause.is_empty(){fields.push((b"cause".to_vec(),Value::Str(cause.as_bytes().to_vec())))}
    Value::Obj(fields)
}

struct Context { dir:W, conditional:W, depth:usize, grouped:bool, userconfig:bool, settings:env::Settings, until:Option<Instant> }
impl Context {
    fn statement(&mut self,run:&mut Run,statement:&TargetStatement,questions:&mut Questions)->Target {
        let mut out=Target{kind:"-".into(),dir:W::new(),why:W::new(),fetch:None,fields:statement.fields()};
        if statement.before==b"?" {
            run.failed=true;out.kind="?".into();out.dir=b"?".to_vec();
            out.why=b"the command could not be split into statements, so safedeps cannot tell where its installs land".to_vec();out.fields=W::new();return out
        }
        if statement.before!=b"&&"{self.conditional.clear()}
        let here=if self.conditional.is_empty(){self.dir.clone()}else{self.conditional.clone()};
        let mut toks=statement.tokens.clone();
        while !toks.is_empty() {
            let h=&toks[0];let start=h.iter().position(|b|!b"({!".contains(b)).unwrap_or(h.len());let head=h[start..].to_vec();
            match head.as_slice(){
                b"if"|b"while"|b"until"=>{self.depth+=1;toks.remove(0);},
                b""|b"then"|b"do"|b"else"|b"elif"|b"time"=>{toks.remove(0);},
                _=>{toks[0]=head;break}
            }
        }
        if toks.is_empty(){return out}
        match toks[0].as_slice(){b"for"|b"select"|b"case"=>self.depth+=1,b"fi"|b"done"|b"esac"=>self.depth=self.depth.saturating_sub(1),_=>{}}
        if matches!(toks[0].as_slice(),b"cd"|b"pushd"|b"popd") {
            let conditional=matches!(statement.before.as_slice(),b"&&"|b"||")||self.depth>0;
            let mut value=if self.grouped||toks[0]==b"popd"||matches!(statement.before.as_slice(),b"|"|b"&")||matches!(statement.after.as_slice(),b"|"|b"&"){b"?".to_vec()}
                else{literal_dir(&here,toks[1..].iter().find(|v|!matches!(v.as_slice(),b"-L"|b"-P"|b"-e"|b"-@"|b"-n")).map(Vec::as_slice).unwrap_or_default())};
            if value!=b"?"&&!os::path(&value).is_dir(){value=b"?".to_vec()}
            if !conditional{self.dir=value;self.conditional.clear()}else if statement.before==b"||"{self.conditional.clear()}else{self.conditional=value}
            return out
        }
        if self.settings.statement(&toks,&statement.text,self.grouped)||!run.recognized(&statement.rec){return out}
        let q=self.settings.question(&toks,&here);
        let mw=statement.manager_words();let mut rd=manager::Reader::new(&run.c.mrx);
        out.kind="other".into();out.dir=here.clone();let mut run_dir=here.clone();let mut manager=false;
        if !mw.is_empty() {
            rd.read(&mw);
            if rd.family=="npm"&&matches!(rd.kind.as_str(),"install"|"link"){out.kind="npm".into()}
            for (k,word) in mw.iter().enumerate() {
                if rd.role[k]==b'm'{manager=true}
                if rd.role[k]!=b'd'{continue}
                let text=if rd.text[k].is_empty(){word}else{&rd.text[k]};
                let mut value=extract::word_as_read("",text);
                if value==[2]{value.clear()}else{for b in &mut value{if *b==2{*b=b' '}}}
                if !manager{run_dir=literal_dir(&run_dir,&value)}
                out.dir=literal_dir(&out.dir,&value);
            }
        }
        if out.kind!="npm"{return out}
        if rd.kind=="link"{
            out.dir=b"global".to_vec();out.kind="npm-unrecorded".into();out.why=b"npm link installs a package the global tree does not have into npm's global prefix, where no lockfile records it".to_vec();return out
        }
        if q.word.is_empty(){out.dir=b"?".to_vec();out.why=b"safedeps could not find the npm word in this install statement, so it cannot ask npm where the install lands".to_vec();return out}
        if !q.unknown.is_empty(){out.dir=b"?".to_vec();out.why=cat(&[b"this npm install depends on ",&q.unknown,b", which the shell decides at run time or this gate does not reproduce, so safedeps cannot ask npm where it lands"]);return out}
        if run_dir==b"?"{out.dir=b"?".to_vec();return out}
        let until=*self.until.get_or_insert_with(||Instant::now()+Duration::from_secs(ask::PRE_SECONDS));
        let answer=questions.ask(&run_dir,until,&q);
        out.fetch=Some(fetch_after(answer.fetch,&self.settings,&q));
        let mut prefix=W::new();
        if let Some(why)=answer.location.strip_prefix(b"?") {out.dir=b"?".to_vec();out.why=why.strip_prefix(b"\t").unwrap_or(why).to_vec()}
        else if let Some(p)=answer.location.strip_prefix(b"global") {out.dir=b"global".to_vec();prefix=p.strip_prefix(b"\t").unwrap_or(p).to_vec();out.why=b"npm installs this in its global prefix, where no lockfile records it".to_vec()}
        else {out.dir=answer.location;prefix=out.dir.clone()}
        if prefix.is_empty(){return out}
        let mut home=env_bytes("HOME");for word in &q.env{if let Some(h)=word.strip_prefix(b"HOME="){home=h.to_vec()}}
        let mut user=W::new();let mut want=false;let mut global_off=false;
        for tok in &toks {
            if want{user=tok.clone();want=false;continue}
            if tok==b"--userconfig"{want=true}
            else if let Some(p)=tok.strip_prefix(b"--userconfig="){user=p.to_vec()}
            else if matches!(tok.as_slice(),b"--global=false"|b"--no-global"){global_off=true}
        }
        if want{user=b"?".to_vec()}
        else if user.is_empty(){
            user=if self.userconfig{b"?".to_vec()}else{
                let a=env_bytes("npm_config_userconfig");let b=env_bytes("NPM_CONFIG_USERCONFIG");
                if !a.is_empty(){a}else if !b.is_empty(){b}else{cat(&[&home,b"/.npmrc"])}
            };
        }
        if let Some(tail)=user.strip_prefix(b"~/"){user=cat(&[&home,b"/",tail])}
        if user!=b"?"{user=literal_dir(&here,&user)}
        let why=npmrc::unrecorded(&prefix,&user,global_off,&mut run.failed);
        if !why.is_empty(){out.kind="npm-unrecorded".into();out.why=why;if out.dir!=b"global"{out.dir=b"?".to_vec()}}
        out
    }
}

pub fn resolve(run:&mut Run,command:&[u8],cwd:&[u8],questions:&mut Questions)->Vec<Target> {
    let scan=run.lex(command,"scan").unwrap_or_default();
    let mut ctx=Context{dir:cwd.to_vec(),conditional:W::new(),depth:0,grouped:scan.iter().any(|b|b"(){}`".contains(b)),
        userconfig:scan.to_ascii_lowercase().windows(b"npm_config_userconfig=".len()).any(|w|w==b"npm_config_userconfig="),settings:env::Settings::default(),until:None};
    run.target_statements(command).iter().map(|s|{
        let mut target=ctx.statement(run,s,questions);
        if target.dir.iter().any(|b|matches!(b,0x1d|b'\n')){
            target.dir=b"?".to_vec();if !target.why.is_empty(){target.why.extend_from_slice(b"; ")}
            target.why.extend_from_slice(b"npm named a directory whose name holds a byte this record cannot carry");
        }
        for b in &mut target.why{if matches!(*b,0x1d|b'\n'){*b=b' '}}
        target
    }).collect()
}

pub fn probe(input:&[u8])->i32 {
    let Ok(v)=json::parse_one(input)else{return 2};
    let Some(Value::Str(command))=v.get("command")else{return 2};let Some(Value::Str(cwd))=v.get("cwd")else{return 2};
    let reading=match v.get("reading").and_then(Value::as_str){None|Some("bash")=>Reading::Bash,Some("zsh")=>Reading::Zsh,Some("dash")=>Reading::Dash,_=>return 2};
    let core=Core::new();let mut run=Run::new(&core);run.reading=Some(reading);
    if v.get("op").and_then(Value::as_str)==Some("target-statements") {
        let records=run.target_statements(command).into_iter().map(|s|jq::obj(vec![
            ("before",jq::arg(&s.before)),("text",jq::arg(&s.text)),("after",jq::arg(&s.after)),
            ("tokens",jq::J::Arr(s.tokens.iter().map(|t|jq::arg(t)).collect())),
            ("words",jq::arg(&s.words)),("uwords",jq::arg(&s.uwords)),("rec",jq::arg(&s.rec)),
        ])).collect();
        println!("{}",jq::compact(&jq::J::Arr(records)));return if run.failed{1}else{0}
    }
    let mut questions=Questions::default();
    let rows=resolve(&mut run,command,cwd,&mut questions);
    use std::io::Write;for row in rows{let _=std::io::stdout().write_all(&row.render());}
    if run.failed{1}else{0}
}
