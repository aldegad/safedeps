//! npm records, fetch answers, and the machine-wide record of withheld bytes.
use super::{jv,sh,closure,workspaces,tree,trace::{self,Install},snapshot::Store,report::{self,Report,cat}};
use crate::{ask,json::Value,state,os,sha256};
use std::{fs,path::Path,time::{Duration,Instant}};
type W=Vec<u8>;
pub const WITHHELD_SCOPE:&[u8]=b"safedeps has recorded these bytes and withholds their install scripts in every project on this machine. This version has no way to release them: no tree that holds them is rebuilt automatically until a later release can approve a registry";
fn strval(v:&Value)->W{jv::tostring(v)}
fn field<'a>(v:&'a Value,k:&str)->Result<&'a Value,()>{jv::field(v,k)}
fn alt(v:&Value,d:Value)->Value{if jv::truthy(v){v.clone()}else{d}}
fn val_str(v:&Value,k:&str,default:&[u8])->Result<W,()>{Ok(strval(&alt(field(v,k)?,jv::s(default))))}
fn pretty(v:&Value)->W{crate::jq::pretty(&jv::to_j(v)).into_bytes()}
fn digest(p:&Path)->Option<String>{fs::read(p).ok().map(|b|sha256::hex(&b))}
fn sourced(current:&Value)->bool{matches!(jv::path(current,&["npm_fetch","cause"]),Ok(Value::Str(s)) if s==b"sourced")}
pub fn unread_note(meta:&Path)->W{if report::inert_unread(meta){cat(&[b". ",report::UNREAD])}else{Vec::new()}}

#[derive(Default)]
pub struct Npm{pub sources:Vec<W>,pub nodes:Vec<W>,pub facts:Option<Value>,pub recorded:Vec<W>}
impl Npm{
    pub fn facts(&mut self,store:&Store,current:&Value)->&Value{
        if self.facts.is_none(){
            let pre=match field(current,"npm_fetch"){Ok(v@Value::Obj(_))=>v.clone(),_=>jv::obj(vec![("unknown",jv::s(b"the pre-guard left no answer about which registry this install fetches from"))])};
            let post=ask::fetch_facts(&store.project,Instant::now()+Duration::from_secs(ask::POST_SECONDS),&[],&[b"--workspaces=false".to_vec()]);
            self.facts=Some(Value::Arr(vec![pre,post]));
        }self.facts.as_ref().unwrap()
    }
    pub fn collect(&mut self,store:&Store,reasons:&mut Vec<W>){
        let earlier:Vec<_>=["package-lock.json","npm-tree-record.json"].iter().map(|n|store.path(&store.id,n.as_bytes())).filter(|p|sh::is_file(p)).collect();
        let mut directories=Vec::new();
        for record in trace::RECORDS{
            let file=store.project.join(record);if !sh::is_file(&file){continue}
            let Ok(new)=closure::new_records(&file,&earlier)else{reasons.push(cat(&[b"npm record ",record.as_bytes(),b" could not be compared with the records before the command; fail-closed"]));continue};
            for line in new.split(|b|*b==b'\n'){
                let row=sh::read_tab(line,3);
                match row[0].as_slice(){
                    b"S"=>self.sources.push(cat(&[record.as_bytes(),b": ",&row[1]])),
                    b"N"=>self.nodes.push(row[1].clone()),
                    b"L"=>directories.push(vec![row[0].clone(),record.as_bytes().to_vec(),row[1].clone(),row[2].clone()]),
                    b"T"=>directories.push(vec![row[0].clone(),record.as_bytes().to_vec(),row[1].clone(),row[1].clone()]),_=>{}
                }
            }
        }
        if directories.is_empty(){return}
        let members=if sh::is_file(&store.project.join("package.json")){workspaces::physical_members(&store.project,&store.home)}else{Vec::new()};
        for row in directories{
            let physical=if row[3].is_empty(){None}else{sh::cd_physical(Path::new("."),&sh::p(&cat(&[sh::bytes(&store.project),b"/",&row[3]])))};
            if physical.is_some_and(|p|members.iter().any(|m|m==sh::bytes(&p))){continue}
            if row[0]==b"L"{
                if row[3].is_empty(){self.sources.push(cat(&[&row[1],b": ",&row[2],b" (a link that records no target)"]));}
                else{self.sources.push(cat(&[&row[1],b": ",&row[3]]));self.nodes.push(row[3].clone());}
            }else{self.nodes.push(row[3].clone());}
        }
    }
    fn observed(store:&Store,copy:&Path)->bool{
        let Some(hash)=digest(copy)else{return false};
        let Some(st)=jv::read_file(&store.home.join("npm-observed").join(format!("{}.json",store.hash)))else{return false};
        !st.failed&&st.values.last().is_some_and(|v|jv::path(v,&["project"]).is_ok_and(|p|jv::eq(p,&jv::s(sh::bytes(&store.project))))&&jv::path(v,&["tree"]).is_ok_and(|t|jv::eq(t,&jv::s(hash.as_bytes()))))
    }
    fn observe(store:&Store,copy:&Path){
        let dir=store.home.join("npm-observed");
        let ok=digest(copy).is_some_and(|hash|{
            let v=jv::obj(vec![("project",jv::s(sh::bytes(&store.project))),("tree",jv::s(hash.as_bytes())),("at",jv::num(os::wall(os::WallRole::NpmObserved).seconds()))]);
            state::write_state_file(&dir.join(format!("{}.json",store.hash)),&jv::dump(&v)).is_ok()
        });
        if !ok{state::log_advisory(&store.home,&cat(&[b"post-verify: could not keep the hash of the tree record judged in ",sh::bytes(&store.project),b" (",sh::bytes(&dir),b"), so the next install there counts every integrity in it as new."]));}
    }
    fn fresh_integrities(store:&Store,tree:&Path)->Result<Vec<Value>,()>{
        let mut files:Vec<_>=[store.project.join("package-lock.json"),tree.into()].into_iter().filter(|p|sh::is_file(p)).map(|p|(p,false)).collect();
        if files.is_empty(){return Ok(Vec::new())}
        let before=store.path(&store.id,b"npm-tree-record.json");
        if sh::is_file(&before){
            if Self::observed(store,&before){files.push((before,true));}
            else{state::log_advisory(&store.home,&cat(&[b"post-verify: the tree record in ",sh::bytes(&store.project),b" before this command is not one safedeps judged at the end of an install here, so every integrity in it counts as brought in by this install."]));}
        }
        let mut all=Vec::new();let mut seen=std::collections::HashSet::new();
        for (file,before) in files{
            let st=jv::read_file(&file).ok_or(())?;if st.failed{return Err(())}
            for v in st.values{
                let Value::Obj(entries)=field(&v,"packages")? else{continue};
                for(key,value) in entries{
                    if !jv::in_tree(key)||!matches!(value,Value::Obj(_))||matches!(field(value,"link")?,Value::Bool(true)){continue}
                    let tokens=jv::tokens(value);if tokens.is_empty(){continue}
                    if before&&tokens.len()==1{seen.insert(tokens[0].clone());}
                    let name=alt(field(value,"name")?,jv::s(jv::after_last_node_modules(key).unwrap_or(b"")));
                    all.push(jv::obj(vec![("before",Value::Bool(before)),("name",name),("version",alt(field(value,"version")?,jv::s(b"?"))),
                        ("resolved",field(value,"resolved")?.clone()),("tokens",Value::Arr(tokens.iter().map(|t|jv::s(t)).collect()))]));
                }
            }
        }
        let mut found=Vec::new();
        for mut v in all{
            if matches!(field(&v,"before")?,Value::Bool(true)){continue}
            let Value::Arr(tokens)=field(&v,"tokens")?else{return Err(())};
            let tokens:Vec<_>=tokens.iter().filter(|t|!seen.contains(jv::text(t).unwrap_or(b""))).cloned().collect();
            if tokens.is_empty(){continue}
            if let Value::Obj(o)=&mut v{jv::set(o,b"tokens".to_vec(),Value::Arr(tokens));}found.push(v);
        }
        Ok(jv::unique_by(found,|v|field(v,"tokens").unwrap_or(&jv::NULL).clone()))
    }
    fn withheld_values(store:&Store,found:Vec<Value>,facts:&Value)->Result<Value,()>{
        let inert=meta_true(&store.meta(),"ignore_scripts_injected");let mut out=Vec::new();
        for r in found{
            let resolved=field(&r,"resolved")?;
            let from=match resolved{
                Value::Str(url) if !closure::public_registry_url(url)=>vec![jv::s(url)],
                Value::Str(url)=>ask::fetch_origins(facts,&String::from_utf8_lossy(url))?.iter().map(|o|tree::origin_text(&o.value()).map(|s|jv::s(&s))).collect::<Result<Vec<_>,_>>()?,
                _=>{
                    let Value::Arr(fs)=facts else{return Err(())};let mut fs=fs.clone();
                    for f in &mut fs{if let Value::Obj(o)=f{if !o.iter().any(|(k,v)|k==b"unknown"&&!matches!(v,Value::Null)){jv::set(o,b"replace".to_vec(),jv::s(b"always"));}}}
                    let name=field(&r,"name")?;let Value::Str(n)=name else{return Err(())};
                    let last=n.split(|b|*b==b'/').last().unwrap_or(b"");let url=cat(&[b"https://registry.npmjs.org/",n,b"/-/",last,b"-",&strval(field(&r,"version")?),b".tgz"]);
                    ask::fetch_origins(&Value::Arr(fs),&String::from_utf8_lossy(&url))?.iter().map(|o|tree::origin_text(&o.value()).map(|s|jv::s(&s))).collect::<Result<Vec<_>,_>>()?
                }
            };
            if from.is_empty(){continue}
            let entry=jv::obj(vec![("package",jv::s(&cat(&[&strval(field(&r,"name")?),b"@",&strval(field(&r,"version")?)]))),
                ("origins",Value::Arr(jv::unique(from))),("project",jv::s(sh::bytes(&store.project))),("at",jv::num(os::wall(os::WallRole::NpmWithheldEntry).seconds())),("inert",Value::Bool(inert))]);
            let Value::Arr(tokens)=field(&r,"tokens")?else{return Err(())};
            for token in tokens{let Value::Str(t)=token else{return Err(())};jv::set(&mut out,t.clone(),entry.clone());}
        }Ok(Value::Obj(out))
    }
    pub fn record(&mut self,store:&Store,current:&Value,trace:&Install,report:&mut Report){
        if trace.absent{return}
        let hidden=store.project.join("node_modules/.package-lock.json");
        let judged=if sh::is_file(&hidden){sh::mktemp(&cat(&[sh::bytes(&store.home),b"/snapshots/.",&store.id,b"_judged."])).and_then(|p|if sh::cp(&hidden,&p)==0{Some(p)}else{sh::rm_f(&p);None})}else{None};
        let tree=judged.as_deref().unwrap_or(&hidden);
        let success=self.record_inner(store,current,tree,report);
        if success&&!sourced(current)&&trace.records.iter().any(|r|r==b"node_modules/.package-lock.json"){
            if let Some(j)=&judged{Self::observe(store,j);}
        }
        if let Some(j)=judged{sh::rm_f(&j);}
    }
    fn record_inner(&mut self,store:&Store,current:&Value,tree:&Path,report:&mut Report)->bool{
        let project=sh::bytes(&store.project);
        let found=match Self::fresh_integrities(store,tree){Ok(f)=>f,Err(_)=>{
            state::log_advisory(&store.home,&cat(&[b"post-verify: the npm records in ",project,b" could not be read for the bytes this install brought in, so none of them were recorded as withheld."]));
            report.say(cat(&[b"safedeps could not read which bytes this install brought into ",project,b", so if npm fetched any of them from a registry that is not the public npm registry, it has not recorded them, and another project that receives the same bytes may rebuild them"]));return false;
        }};
        if found.is_empty(){return true}
        let mut facts=self.facts(store,current).clone();
        if sourced(current){
            if let Value::Arr(fs)=&mut facts{fs.retain(|f|!matches!(field(f,"cause"),Ok(Value::Str(c)) if c==b"sourced"));}
            state::log_advisory(&store.home,&cat(&[b"post-verify: not recording the bytes this install brought into ",project,b" as withheld for want of npm's answer: the command runs code safedeps does not read or run (source, . or eval before the install, or npm under a PATH or NODE_OPTIONS of its own), and whoever controls that code already runs code in this shell. safedeps did not run npm rebuild for them this time",&unread_note(&store.meta()),b"."]));
        }
        let recorded=match Self::withheld_values(store,found,&facts){Ok(r)=>r,Err(_)=>{
            state::log_advisory(&store.home,&cat(&[b"post-verify: safedeps could not tell where npm fetched the bytes this install brought into ",project,b", so none of them were recorded as withheld."]));
            report.say(cat(&[b"safedeps could not tell where npm fetched the bytes this install brought into ",project,b", so it has not recorded them as withheld, and another project that receives the same bytes may rebuild them"]));return false;
        }};
        let Value::Obj(rows)=&recorded else{return false};if rows.is_empty(){return true}
        let mut descriptions=Vec::new();let mut packages=Vec::new();
        for(_,v)in rows{
            let name=field(v,"package").unwrap_or(&jv::NULL);packages.push(name.clone());
            let origins=match field(v,"origins"){Ok(Value::Arr(a))=>a.iter().map(strval).collect::<Vec<_>>().join(b" or ".as_slice()),_=>Vec::new()};
            descriptions.push(jv::s(&cat(&[&strval(name),b" from ",&origins])));
        }
        let summary=jv::unique(descriptions).iter().map(strval).collect::<Vec<_>>().join(b"; ".as_slice());
        let dir=store.home.join("npm-withheld");let tmp=if sh::mkdir_p(&dir){sh::mktemp(&cat(&[sh::bytes(&dir),b"/.record."]))}else{None};
        let wrote=tmp.as_ref().is_some_and(|tmp|{
            let tail=sh::basename(sh::bytes(tmp));let tail=tail.rsplit(|b|*b==b'.').next().unwrap_or(b"");
            let target=dir.join(sh::p(&cat(&[os::wall(os::WallRole::NpmWithheldName).seconds().to_string().as_bytes(),b"-",std::process::id().to_string().as_bytes(),b"-",tail,b".json"])));
            fs::write(tmp,cat(&[&jv::dump(&recorded),b"\n"])).is_ok()&&fs::rename(tmp,target).is_ok()
        });
        if !wrote{
            if let Some(t)=tmp{sh::rm_f(&t);}
            state::log_advisory(&store.home,&cat(&[b"post-verify: could not write the record of withheld bytes to ",sh::bytes(&dir),b": ",&summary,b"."]));
            report.say(cat(&[b"safedeps could not record the bytes this install fetched from a registry that is not the public npm registry (",sh::bytes(&dir),b"), so another project that receives the same bytes may rebuild them"]));return false;
        }
        self.recorded.extend(jv::unique(packages).iter().map(strval).filter(|s|!s.is_empty()));
        state::log_advisory(&store.home,&cat(&[b"post-verify: recorded as withheld on this machine, by integrity: ",&summary,b" (into ",project,b")."]));true
    }
}

pub fn meta_true(path:&Path,key:&str)->bool{
    let Some(st)=jv::read_file(path)else{return false};
    let (lines,rc)=jv::each(&st,|v|Ok(vec![if matches!(field(v,key)?,Value::Bool(true)){b"true".to_vec()}else{b"false".to_vec()}]));rc==0&&jv::captured(&lines)==b"true"
}
pub fn withheld_read(home:&Path)->Result<Value,()>{
    let dir=home.join("npm-withheld");if !sh::exists(&dir){return Ok(Value::Obj(Vec::new()))}
    let mut out=Vec::new();
    for entry in fs::read_dir(dir).map_err(|_|())?{
        let e=entry.map_err(|_|())?;if !e.file_type().map_err(|_|())?.is_file()||!sh::basename(sh::bytes(&e.path())).ends_with(b".json"){continue}
        let st=jv::read_file(&e.path()).ok_or(())?;if st.failed{return Err(())}
        for v in st.values{
            let entries=match v{Value::Obj(o)=>o,Value::Arr(a)=>a.into_iter().enumerate().map(|(i,v)|(i.to_string().into_bytes(),v)).collect(),_=>return Err(())};
            for (key,value) in entries{
                let old=out.iter().find(|(k,_)|k==&key).map(|(_,v)|v).unwrap_or(&jv::NULL);
                if matches!(old,Value::Null)||jv::cmp(&alt(field(old,"at")?,jv::num(0)),&alt(field(&value,"at")?,jv::num(0))).is_gt(){jv::set(&mut out,key,value);}
            }
        }
    }Ok(Value::Obj(out))
}

fn name_sources(lines:&[W])->W{
    let mut out=lines.iter().take(3).cloned().collect::<Vec<_>>().join(b";".as_slice());
    let count=lines.iter().filter(|l|!l.is_empty()).count();if count>3{out.extend(cat(&[b"; and ",(count-3).to_string().as_bytes(),b" more"]));}out
}
fn fields(lines:&[W],kind:&[u8],column:usize,rest:bool)->Vec<W>{
    let prefix=cat(&[kind,b"\t"]);let mut out:Vec<W>=lines.iter().filter(|l|l.starts_with(&prefix)).map(|l|if rest{sh::cut_from(l,column)}else{sh::cut_field(l,column)}.to_vec()).collect();out.sort();out.dedup();out
}
fn clauses(lines:&[W])->W{
    let mut out=Vec::new();
    for (kind,label) in [
        (b"unrecorded".as_slice(),b"a package, or a version of one, that neither lockfile records".as_slice()),
        (b"source",b"a package not recorded as coming from the public registry"),
        (b"fetched",b"a package recorded on the public registry that safedeps cannot tell npm fetched from there"),
        (b"withheld",b"a package whose bytes safedeps withheld when an earlier install fetched them"),
        (b"nointegrity",b"a package recorded on the public registry with no integrity, so safedeps cannot tell its bytes from ones it withheld"),
        (b"directory",b"a directory that is not a declared workspace member")]{
        // grep/paste keeps query order and duplicates; sed expands every ';'.
        let prefix=cat(&[kind,b"\t"]);
        let values:Vec<_>=lines.iter().filter(|l|l.starts_with(&prefix)).map(|l|sh::cut_from(l,2).to_vec()).collect();
        if values.is_empty(){continue}
        let list=values.join(b";".as_slice()).split(|b|*b==b';').map(Vec::from).collect::<Vec<_>>().join(b"; ".as_slice());
        out.push(cat(&[label,b" (",&list,b")"]));
    }out.join(b", and ".as_slice())
}
impl Npm{
    pub fn sources(&mut self,store:&Store,current:&Value,input:&[u8],codex:bool,reasons:&mut Vec<W>,confirm:&mut Vec<W>){
        if self.sources.is_empty(){return}
        let mut nonstandard=Vec::new();let mut public=Vec::new();
        for line in &self.sources{
            let url=line.windows(2).position(|x|x==b": ").map(|p|&line[p+2..]).unwrap_or(line);
            if closure::public_registry_url(url){public.push(line.clone());}else{nonstandard.push(line.clone());}
        }
        if !public.is_empty(){
            let facts=self.facts(store,current).clone();let mut fetched=Vec::new();let mut failed=false;
            for entry in public{
                let url=entry.windows(2).position(|x|x==b": ").map(|p|&entry[p+2..]).unwrap_or(&entry);
                match ask::fetch_known_problems(&facts,&String::from_utf8_lossy(url)){
                    Ok(p) if !p.is_empty()=>fetched.push(cat(&[&entry,b", but ",p.join("; ").as_bytes()])),Ok(_)=>{},Err(_)=>{failed=true;break}
                }
            }
            if failed{
                state::log_advisory(&store.home,&cat(&[b"post-verify: the sources on the public registry in ",sh::bytes(&store.project),b" could not be judged against npm's answer about where it fetched them; the rebuild check judges them again and withholds what it cannot vouch for."]));
            }else if !fetched.is_empty(){
                let sources=name_sources(&fetched);
                state::log_advisory(&store.home,&cat(&[b"post-verify: kept in ",sh::bytes(&store.project),b", fetched from a registry that is not the public npm registry (",&sources,b"); not rolled back, and safedeps runs none of their install scripts."]));
                let mut inert=report::inert(&store.meta(),input).unwrap_or_default();
                if inert!=report::ADDED{
                    if inert==report::NONE&&codex{inert.extend(b" (on Codex it cannot)");}
                    if inert.is_empty(){inert=b"safedeps has no record it can read of adding --ignore-scripts to this install".to_vec();}
                    confirm.push(cat(&[b"this install fetched packages from a registry that is not the public npm registry (",&sources,b"). ",&inert,b", so their install scripts may already have run. The install is kept; confirm with the user that they trust that registry",&if self.recorded.is_empty(){Vec::new()}else{cat(&[b". ",WITHHELD_SCOPE])}]));
                }
            }
        }
        if !nonstandard.is_empty(){reasons.push(cat(&[b"Lock file contains resolved URLs from non-standard registries (",&name_sources(&nonstandard),b")"]));}
        let insecure:Vec<_>=self.sources.iter().filter(|s|{let s=s.to_ascii_lowercase();s.windows(7).any(|w|w==b"http://")||s.windows(6).any(|w|w==b"git://")}).cloned().collect();
        if !insecure.is_empty(){reasons.push(cat(&[b"Lock file contains insecure (non-HTTPS) resolved URLs (",&name_sources(&insecure),b")"]));}
    }
    fn describe_origins(&self,store:&Store,current:&Value,lines:&[W],held:bool)->W{
        let kind=if held{b"held".as_slice()}else{b"origin"};
        let names=fields(lines,kind,2,false).join(b" ".as_slice());
        let origins=fields(lines,kind,3,!held);let known=origins.iter().filter(|s|!s.starts_with(b"?")).cloned().collect::<Vec<_>>().join(b", ".as_slice());
        let unknown=origins.iter().filter_map(|s|s.strip_prefix(b"?").map(Vec::from)).collect::<Vec<_>>().join(b"; ".as_slice());
        let mut where_from=Vec::new();let trust=if known.is_empty(){b"where they came from".as_slice()}else{b"that registry"};
        if held{
            if known.is_empty(){where_from=cat(&[b"from a registry safedeps could not name (",if unknown.is_empty(){b"the record does not say"}else{&unknown},b")"]);}
            else{where_from.extend(cat(&[b"from ",&known,b", which is not the public npm registry"]));if !unknown.is_empty(){where_from.extend(cat(&[b", or from a registry safedeps could not name (",&unknown,b")"]));}}
            let projects=fields(lines,kind,4,false).join(b", ".as_slice());
            return cat(&[b"safedeps did not run npm rebuild in ",sh::bytes(&store.project),b" because the bytes of ",&names,b" here are the ones an install in ",&projects,b" first fetched ",&where_from,&unread_note(&store.meta()),b". They are kept. ",WITHHELD_SCOPE,b". If you trust ",trust,b", confirm with the user before running `npm rebuild ",&names,b"` yourself; do not rebuild without asking"]);
        }
        if known.is_empty(){where_from=cat(&[b"safedeps could not tell which registry this install fetched ",&names,b" from (",if unknown.is_empty(){b"npm did not say"}else{&unknown},b"), so it cannot tell they came from the public npm registry"]);}
        else{where_from.extend(cat(&[b"this install fetched ",&names,b" from ",&known,b", which is not the public npm registry"]));if !unknown.is_empty(){where_from.extend(cat(&[b" (one of npm's answers is missing as well: ",&unknown,b")"]));}}
        let mut out=cat(&[b"safedeps did not run npm rebuild in ",sh::bytes(&store.project),b" because ",&where_from,&unread_note(&store.meta()),b". The install is kept"]);
        if known.is_empty()&&sourced(current){out.extend(b". safedeps did not run them this time because the command runs code safedeps does not read or run (a file it sources, an eval, or npm under a PATH or NODE_OPTIONS of its own), and that code can change npm's environment where safedeps cannot see it. It has not recorded these bytes as withheld: whoever controls that code already runs code in this shell, so a record would protect nothing against them. The next install npm says fetches from the public npm registry rebuilds them as usual");}
        out.extend(cat(&[b". If you trust ",trust,b", confirm with the user before running `npm rebuild ",&names,b"` yourself; do not rebuild without asking"]));
        if !self.recorded.is_empty(){out.extend(cat(&[b". ",WITHHELD_SCOPE]));}out
    }
    fn query_tree(&self,store:&Store,withheld:&Value)->Result<Vec<W>,W>{
        let Some(facts)=&self.facts else{return Err(b"safedeps did not ask npm which registry this tree came from".to_vec())};
        let answer=ask::query(&store.project,Instant::now()+Duration::from_secs(ask::POST_SECONDS)).map_err(|s|s.into_bytes())?;
        let problems=|url:&Value|ask::fetch_problems(facts,&String::from_utf8_lossy(jv::text(url).ok_or(())?)).map(|ps|ps.iter().map(|p|jv::s(p.as_bytes())).collect());
        let origins=|url:&Value|ask::fetch_origins(facts,&String::from_utf8_lossy(jv::text(url).ok_or(())?)).map(|os|os.iter().map(|o|o.value()).collect());
        tree::judge(&store.project,&store.home,&jv::read(&answer.stdout),withheld,&problems,&origins).map_err(|_|b"npm query answered with something safedeps could not compare with the lockfiles".to_vec())
    }
    pub fn rebuild(&mut self,store:&Store,current:&Value,trace:&mut Install,input:&[u8],report:&mut Report){
        if !meta_true(&store.meta(),"ignore_scripts_injected"){return}
        let meta=store.meta();let home=&store.home;let project=sh::bytes(&store.project);
        if trace.absent{report.rebuild(home,&meta,input,&cat(&[b"did not run npm rebuild: ",&trace.line]));trace.said=true;return}
        if !sh::is_dir(&store.project.join("node_modules")){return}
        if let Some(why)=report::reach_blocker(&store.project){
            report.rebuild(home,&meta,input,&cat(&[b"did not run npm rebuild: ",&why]));
            state::log_advisory(home,&cat(&[b"post-verify rebuild skipped: ",&why,b" -- project ",project]));return;
        }
        if !sh::is_file(&store.project.join("node_modules/.package-lock.json")){
            state::log_advisory(home,&cat(&[b"post-verify: npm rebuild skipped in ",project," — node_modules has no .package-lock.json, so the tree it would rebuild is not the tree the effect gate read.".as_bytes()]));
            report.say(cat(&[b"npm rebuild was not run: ",project,b"/node_modules has no .package-lock.json, so safedeps could not read the tree it would rebuild. safedeps did not run npm rebuild; review node_modules, then run `npm rebuild` yourself if it is what you expect"]));return;
        }
        // This tree still needs npm's registry answers when the install
        // brought in no new integrity and record()/sources() needed none.
        self.facts(store,current);
        let withheld=match withheld_read(home){Ok(v)=>v,Err(_)=>{
            let why=cat(&[b"safedeps could not read its record of the bytes it withheld in ",sh::bytes(&home.join("npm-withheld"))]);
            state::log_advisory(home,&cat(&[b"post-verify: npm rebuild after the install skipped in ",project," — ".as_bytes(),&why,b", so it cannot tell that tree holds none of them."]));
            report.say(cat(&[b"npm rebuild was not run: ",&why,b", so it could not tell that the tree holds none of them. safedeps did not run npm rebuild; review node_modules, then run `npm rebuild` yourself if it is what you expect"]));return;
        }};
        let blockers=match self.query_tree(store,&withheld){Ok(b)=>b,Err(why)=>{
            state::log_advisory(home,&cat(&[b"post-verify: npm rebuild after the install skipped in ",project," — safedeps asked npm which packages a rebuild would run over and got no answer (".as_bytes(),&why,b"), so it cannot tell that tree is one it can vouch for."]));
            report.say(cat(&[b"npm rebuild was not run: safedeps asked npm which packages it would rebuild and got no answer (",&why,b"), so it could not tell they are the ones it read. safedeps did not run npm rebuild; review node_modules, then run `npm rebuild` yourself if it is what you expect"]));return;
        }};
        if !blockers.is_empty(){
            state::log_advisory(home,&cat(&[b"post-verify: npm rebuild after the install skipped in ",project," — the tree npm would rebuild holds ".as_bytes(),&clauses(&blockers),b"."]));
            if blockers.iter().any(|l|l.starts_with(b"fetched")){report.say(self.describe_origins(store,current,&blockers,false));}
            if blockers.iter().any(|l|l.starts_with(b"withheld")){report.say(self.describe_origins(store,current,&blockers,true));}
            let rest:Vec<_>=blockers.into_iter().filter(|l|![b"fetched\t".as_slice(),b"origin\t",b"withheld\t",b"held\t"].iter().any(|p|l.starts_with(p))).collect();
            if !rest.is_empty(){report.say(cat(&[b"npm rebuild was not run: the tree npm would rebuild in ",project,b" holds ",&clauses(&rest),b". safedeps runs install scripts only over a tree whose every package is on record and comes from the public registry or a declared workspace member. safedeps did not run npm rebuild; review it, then run `npm rebuild` yourself if it is what you expect"]));}return;
        }
        use std::process::{Command,Stdio};use crate::outcome::{Outcome,Form};
        let child=Command::new("npm").current_dir(&store.project).args(["rebuild","--global=false","--location=project","--prefix"]).arg(&store.project)
            .stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).spawn();
        let outcome=match child {
            Err(error)=>Outcome::StartFailure(error),
            Ok(mut child)=>match child.wait() {Ok(status)=>Outcome::status(status),Err(error)=>Outcome::StatusFailure(error)},
        };
        if !outcome.success(){report.rebuild(home,&meta,input,&outcome.describe(b"npm rebuild",Form::Action));}
    }
}
