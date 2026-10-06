//! Post-install snapshots: stage before reading, compare after reading, seal
//! the meta last, and only then move the confirmed pointer under state.lock.
use super::{jv, sh, report::{Report,cat}};
use crate::{json::Value, state, md5, os, jq};
use std::{fs,collections::HashSet,path::{Path,PathBuf},io::Write};

pub const LOCKS:[&str;13]=["package-lock.json","pnpm-lock.yaml","yarn.lock","bun.lock","bun.lockb","poetry.lock","uv.lock","Pipfile.lock","requirements.txt","Cargo.lock","go.sum","Gemfile.lock","packages.lock.json"];
pub const MANIFESTS:[&str;7]=["package.json","pyproject.toml","Pipfile","Cargo.toml","go.mod","Gemfile","pom.xml"];
pub const NODE_FILES:[&str;7]=["package.json","package-lock.json","npm-shrinkwrap.json","pnpm-lock.yaml","yarn.lock","bun.lock","bun.lockb"];

pub fn differs(a:&Path,b:&Path)->bool {
    if !sh::is_file(a) && !sh::is_file(b){false}else if !sh::is_file(a)||!sh::is_file(b){true}else{!sh::same_bytes(a,b)}
}
pub fn filename(name:&[u8])->Vec<u8>{if name.contains(&b'/'){cat(&[b"members/",name])}else{name.to_vec()}}
pub fn path(home:&Path,id:&[u8],name:&[u8])->PathBuf {sh::p(&cat(&[sh::bytes(home),b"/snapshots/",id,b"_",name]))}
pub fn sorted_lines(path:&Path)->Vec<Vec<u8>>{
    let raw=sh::cat_captured(path).unwrap_or_default();
    let mut out:Vec<_>=raw.split(|b|*b==b'\n').map(Vec::from).collect();out.sort();out.dedup();out
}
pub fn monitored(home:&Path,id:&[u8])->Vec<Vec<u8>>{
    let list=path(home,id,b"monitored_files.list");
    if sh::is_file(&list){sorted_lines(&list)}else{LOCKS.iter().chain(MANIFESTS.iter()).map(|s|s.as_bytes().to_vec()).collect()}
}
pub fn csproj(dir:&Path)->Vec<Vec<u8>>{
    let mut out:Vec<_>=fs::read_dir(dir).into_iter().flatten().filter_map(Result::ok)
        .filter(|e|e.file_type().is_ok_and(|t|t.is_file())).map(|e|sh::basename(sh::bytes(&e.path()))).filter(|n|n.ends_with(b".csproj")).collect();
    out.sort();out
}
pub fn acquire(home:&Path)->Result<state::StateLock,()> {
    let mut warnings=Vec::new();
    let result=state::StateLock::acquire(&home.join("state.lock"),&mut warnings,None);
    let _=std::io::stderr().write_all(&warnings);
    result.map_err(|_|{
        state::log_advisory(home,"post-verify UNVERIFIED: state lock unavailable (another safedeps run active) — install not verified by this run.".as_bytes());
        eprintln!("safedeps: could not acquire state lock; this install is UNVERIFIED by this run (logged to advisory.log).");
    })
}
pub fn confirmed_unlocked(home:&Path,hash:&str)->Vec<u8>{
    let own=home.join(format!("confirmed_{}",hash));
    let target=if !hash.is_empty() && sh::is_file(&own){own}else{home.join("confirmed")};
    sh::cat_captured(&target).unwrap_or_default()
}
pub fn confirmed(home:&Path,hash:&str)->Result<Vec<u8>,()>{let _lock=acquire(home)?;Ok(confirmed_unlocked(home,hash))}

pub struct Store {pub home:PathBuf,pub project:PathBuf,pub id:Vec<u8>,pub hash:String,pub verified:Vec<u8>,pub staged:bool}
impl Store{
    pub fn new(home:PathBuf,project:PathBuf,id:Vec<u8>)->Self{
        let hash=md5::hex(sh::bytes(&project));let verified=cat(&[b"verified-",&id]);
        Self{home,project,id,hash,verified,staged:false}
    }
    pub fn path(&self,id:&[u8],name:&[u8])->PathBuf{path(&self.home,id,name)}
    pub fn copy(&self,id:&[u8],name:&[u8])->PathBuf{self.path(id,&filename(name))}
    pub fn meta(&self)->PathBuf{self.path(&self.id,b"meta.json")}
    pub fn monitored(&self)->Vec<Vec<u8>>{monitored(&self.home,&self.id)}
    fn verified_names(&self)->Vec<Vec<u8>>{
        let mut names=self.monitored();names.extend(csproj(&self.project));names.retain(|n|!n.is_empty());names.sort();names.dedup();names
    }
    fn stage_inner(&self)->Option<()> {
        let names=self.verified_names();
        let body=if names.is_empty(){Vec::new()}else{cat(&[&names.join(&b'\n'),b"\n"])};
        fs::write(self.path(&self.verified,b"monitored_files.list"),body).ok()?;
        for name in names {
            let dest=self.copy(&self.verified,&name);
            if name.contains(&b'/') && !sh::mkdir_p(dest.parent()?){return None}
            let src=self.project.join(sh::p(&name));
            if sh::is_file(&src){if sh::cp(&src,&dest)!=0{return None}}
            else{fs::File::create(sh::p(&cat(&[sh::bytes(&dest),b".missing"]))).ok()?;}
        }Some(())
    }
    pub fn stage(&mut self){self.staged=self.stage_inner().is_some();if !self.staged{self.discard();}}
    pub fn discard(&self){
        sh::rm_rf(&self.path(&self.verified,b"members"));
        let prefix=cat(&[&self.verified,b"_"]);
        for e in fs::read_dir(self.home.join("snapshots")).into_iter().flatten().filter_map(Result::ok){
            if sh::basename(sh::bytes(&e.path())).starts_with(&prefix){sh::rm_f(&e.path());}
        }
    }
    fn matches(&self)->bool{
        let names=self.verified_names();
        let list=sh::cat_captured(&self.path(&self.verified,b"monitored_files.list")).unwrap_or_default();
        if list!=names.join(&b'\n'){return false}
        for name in names {
            let saved=self.copy(&self.verified,&name);let live=self.project.join(sh::p(&name));
            if sh::is_file(&saved){if differs(&saved,&live){return false}}
            else if sh::exists(&live){return false}
        }true
    }
    fn seal(&self,parent:&[u8])->bool{
        let value=jv::obj(vec![("snapshot_id",jv::s(&self.verified)),("parent_snapshot_id",if parent.is_empty(){Value::Null}else{jv::s(parent)}),
            ("verified_from",jv::s(&self.id)),("timestamp",jv::num(os::now().0)),("project_dir",jv::s(sh::bytes(&self.project)))]);
        // jq -n is pretty here; the shared writer owns the spelling.
        let body=cat(&[jq::pretty(&jv::to_j(&value)).as_bytes(),b"\n"]);
        sh::write_renamed(&cat(&[sh::bytes(&self.home),b"/snapshots/.",&self.verified,b"_meta."]),&self.path(&self.verified,b"meta.json"),&body)
    }
    pub fn confirm(&self,report:&mut Report)->Result<(),()> {
        let mut parent=confirmed(&self.home,&self.hash)?;
        if !parent.is_empty() && !sh::is_file(&self.path(&parent,b"meta.json")){parent.clear();}
        let why:&[u8]=if !self.staged{b"its files could not be copied"}
            else if !self.matches(){b"the dependency files changed while they were being verified, so what they hold now was not read by this check"}
            else if !self.seal(&parent){b"its record could not be written"}else{b""};
        if !why.is_empty(){
            self.discard();let parent=if parent.is_empty(){b"none".as_slice()}else{&parent};
            state::log_advisory(&self.home,&cat(&[b"post-verify: the verified state of ",sh::bytes(&self.project),b" could not be recorded (",why,b"), so the rollback baseline was not moved (still ",parent,b")."]));
            report.say(cat(&[b"safedeps verified this install but could not record the result as the new rollback baseline (",why,b"), so a later rollback in ",sh::bytes(&self.project),b" returns to the baseline before it (",parent,b") and would undo this install too"]));return Ok(());
        }
        let _lock=acquire(&self.home)?;
        state::write_state_file(&self.home.join(format!("confirmed_{}",self.hash)),&self.verified).map_err(|_|())
    }
    pub fn cleanup(&self)->Result<(),()> {
        let mut id=confirmed(&self.home,&self.hash)?;
        let mut protected=HashSet::new();
        while !id.is_empty() && protected.insert(id.clone()) {
            let Some(st)=jv::read_file(&self.path(&id,b"meta.json"))else{break};
            let (ls,_)=jv::each(&st,|v|{let p=jv::field(v,"parent_snapshot_id")?;Ok(if jv::truthy(p){vec![jv::tostring(p)]}else{Vec::new()})});id=jv::captured(&ls);
        }
        let dir=self.home.join("snapshots");
        let mut metas:Vec<_>=fs::read_dir(&dir).into_iter().flatten().filter_map(Result::ok).map(|e|e.path())
            .filter(|p|sh::basename(sh::bytes(p)).ends_with(b"_meta.json")).collect();
        metas.sort_by(|a,b|fs::metadata(b).and_then(|m|m.modified()).ok().cmp(&fs::metadata(a).and_then(|m|m.modified()).ok()).then_with(||sh::bytes(a).cmp(sh::bytes(b))));
        let mut seen=0;
        for meta in metas {
            let Some(st)=jv::read_file(&meta)else{continue};
            let (ls,_)=jv::each(&st,|v|{let id=jv::field(v,"snapshot_id")?;Ok(if jv::truthy(id){vec![jv::tostring(id)]}else{Vec::new()})});
            let id=jv::captured(&ls);if id.is_empty()||protected.contains(&id){continue}seen+=1;if seen<=10{continue}
            if !id.contains(&b'/'){sh::rm_rf(&self.path(&id,b"members"));}
            let prefix=cat(&[&id,b"_"]);
            for e in fs::read_dir(&dir).into_iter().flatten().filter_map(Result::ok){if sh::basename(sh::bytes(&e.path())).starts_with(&prefix){sh::rm_f(&e.path());}}
        }Ok(())
    }
}
