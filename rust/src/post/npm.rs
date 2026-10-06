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
            let v=jv::obj(vec![("project",jv::s(sh::bytes(&store.project))),("tree",jv::s(hash.as_bytes())),("at",jv::num(os::now().0))]);
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
                ("origins",Value::Arr(jv::unique(from))),("project",jv::s(sh::bytes(&store.project))),("at",jv::num(os::now().0)),("inert",Value::Bool(inert))]);
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
            let target=dir.join(sh::p(&cat(&[os::now().0.to_string().as_bytes(),b"-",std::process::id().to_string().as_bytes(),b"-",tail,b".json"])));
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
