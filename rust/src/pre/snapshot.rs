//! The pre-install snapshot is one call's files. Its exclusive list file
//! claims the id before any copy is written. Post owns the file vocabulary
//! and workspace reader; both hooks use those same definitions.
use super::{cat, captured, Call, W};
use crate::{jq, json::{self, Value}, md5, os, post, sha256, state};
use std::{fs, io::{self, Write}, os::unix::{ffi::OsStrExt, fs::{OpenOptionsExt, PermissionsExt}}, path::{Path, PathBuf}};

pub enum Error { Io(io::Error), Workspace(W) }
impl From<io::Error> for Error { fn from(e:io::Error)->Self{Self::Io(e)} }

pub struct Snapshot { pub id:String, pub hash:String, pub project:W, pub parent:W, root:PathBuf }
impl Snapshot {
    pub fn path(&self, name:&[u8])->PathBuf { self.root.join(os::path(&cat(&[self.id.as_bytes(),b"_",name]))) }
    pub fn create(call:&Call, project:&[u8])->Result<Self,Error> {
        let root=call.guard_dir.join("snapshots"); let hash=md5::hex(project);
        let timestamp=os::now().0; let base=format!("{}_{}-{}",timestamp,hash,std::process::id());
        let mut n=0; let id=loop {
            let id=if n==0{base.clone()}else{format!("{}-{}",base,n)};
            let list=root.join(format!("{}_monitored_files.list",id));
            match fs::OpenOptions::new().create_new(true).write(true).mode(0o600).open(list) {
                Ok(_)=>break id,
                Err(e) if e.kind()==io::ErrorKind::AlreadyExists=>n+=1,
                Err(e)=>return Err(e.into()),
            }
        };
        let mut parent=fs::read(call.guard_dir.join(format!("confirmed_{}",hash))).map(captured).unwrap_or_default();
        let has_meta=|id:&[u8]|root.join(os::path(&cat(&[id,b"_meta.json"]))).is_file();
        if !parent.is_empty() && !has_meta(&parent) {
            parent=fs::read(call.guard_dir.join("confirmed")).map(captured).unwrap_or_default();
            if !has_meta(&parent){parent.clear();}
        }
        let snap=Self{id,hash,project:project.to_vec(),parent,root};
        let dir=os::path(project); let mut found=false;
        for name in post::LOCKS { found|=snap.file(name.as_bytes())?; }
        for name in post::MANIFESTS { snap.file(name.as_bytes())?; }
        let mut csproj:Vec<_>=fs::read_dir(&dir).into_iter().flatten().filter_map(Result::ok)
            .filter(|e|e.file_type().is_ok_and(|t|t.is_file())).map(|e|e.file_name())
            .filter(|s|s.as_bytes().ends_with(b".csproj")).collect();
        csproj.sort();for name in csproj{snap.file(name.as_bytes())?;}
        let tree=dir.join("node_modules/.package-lock.json");
        if tree.is_file() && state::copy_state_file(&tree,&snap.path(b"npm-tree-record.json")).is_err() {
            state::log_advisory(&call.guard_dir,&cat(&[b"pre-guard: could not keep a copy of ",tree.as_os_str().as_bytes(),b", so the effect gate will compare this install with package-lock.json alone and may read packages already installed as new. Command: ",&call.command]));
        }
        if let Err(e)=snap.members(&dir) { snap.discard();return Err(Error::Workspace(e.to_string().into_bytes())); }
        let node=dir.join("node_modules"); let mut packages=Vec::new();
        if node.is_dir(){list_packages(&node,0,&mut packages);}
        packages.sort();fs::write(snap.path(b"packages.list"),lines(&packages))?;
        let mut bins:Vec<W>=fs::read_dir(node.join(".bin")).into_iter().flatten().filter_map(Result::ok)
            .map(|e|e.file_name().as_bytes().to_vec()).filter(|n|!n.starts_with(b".")).collect();
        bins.sort();fs::write(snap.path(b"bins.list"),lines(&bins))?;
        let parent=if snap.parent.is_empty(){"null".to_owned()}else{jq::compact(&jq::arg(&snap.parent))};
        // The original writes this initial record as a here-document; later
        // rewrite updates use jq's object writer. Both spellings are observed.
        let meta=format!("{{\n  \"record\": 2,\n  \"snapshot_id\": \"{}\",\n  \"parent_snapshot_id\": {},\n  \"timestamp\": {},\n  \"project_dir\": {},\n  \"command\": {},\n  \"ignore_scripts_injected\": false,\n  \"ignore_scripts_unread\": false,\n  \"lock_files_found\": {}\n}}\n",snap.id,parent,timestamp,jq::compact(&jq::arg(project)),jq::compact(&jq::arg(&call.command)),found);
        fs::write(snap.path(b"meta.json"),meta)?;
        Ok(snap)
    }
    fn file(&self,name:&[u8])->io::Result<bool> {
        fs::OpenOptions::new().append(true).open(self.path(b"monitored_files.list"))?.write_all(&cat(&[name,b"\n"]))?;
        let source=os::path(&self.project).join(os::path(name));let dest=self.path(name);
        if !source.is_file(){fs::File::create(os::path(&cat(&[dest.as_os_str().as_bytes(),b".missing"])))?;return Ok(false)}
        copy(&source,&dest)?;
        fs::write(os::path(&cat(&[dest.as_os_str().as_bytes(),b".sha256"])),digest_line(&fs::read(&source)?,source.as_os_str().as_bytes()))?;
        Ok(true)
    }
    fn members(&self,dir:&Path)->io::Result<()> {
        let members=workspace_manifests(dir);if members.is_empty(){return Ok(())}
        let dest=self.path(b"members");
        let mut files=Vec::new();for m in &members{files.extend_from_slice(b"./");files.extend_from_slice(m);files.push(0);}
        fs::write(self.path(b"members.files"),files)?;fs::create_dir(&dest)?;
        let mut digests=Vec::new();
        for m in &members {
            let source=dir.join(os::path(m));let target=dest.join(os::path(m));
            if let Some(p)=target.parent(){fs::create_dir_all(p)?;}
            copy(&source,&target)?;digests.extend(digest_line(&fs::read(&target)?,m));
        }
        fs::write(self.path(b"members.sha256"),digests)?;
        fs::OpenOptions::new().append(true).open(self.path(b"monitored_files.list"))?.write_all(&lines(&members))
    }
    pub fn mark_rewrite(&self,command:&[u8],unread:bool)->io::Result<()> {
        let mut value=json::parse_one(&fs::read(self.path(b"meta.json"))?).map_err(|_|io::Error::new(io::ErrorKind::InvalidData,"snapshot meta is not JSON"))?;
        let Value::Obj(ref mut fields)=value else{return Err(io::Error::new(io::ErrorKind::InvalidData,"snapshot meta is not an object"))};
        json::set(fields,b"ignore_scripts_injected".to_vec(),Value::Bool(true));
        json::set(fields,b"updated_command".to_vec(),Value::Str(command.to_vec()));
        json::set(fields,b"ignore_scripts_unread".to_vec(),Value::Bool(unread));
        state::write_state_file(&self.path(b"meta.json"),jq::pretty(&jq::from_value(&value)).as_bytes())
    }
    fn discard(&self) {
        let _=fs::remove_dir_all(self.path(b"members"));let prefix=format!("{}_",self.id);
        for e in fs::read_dir(&self.root).into_iter().flatten().filter_map(Result::ok) {
            if e.file_name().as_bytes().starts_with(prefix.as_bytes()){let _=fs::remove_file(e.path());}
        }
    }
}
fn lines(values:&[W])->W {if values.is_empty(){Vec::new()}else{cat(&[&values.join(&b'\n'),b"\n"])}}
fn copy(source:&Path,dest:&Path)->io::Result<()> {
    let mode=fs::metadata(source)?.permissions().mode() & 0o700;
    let mut from=fs::File::open(source)?;
    let mut to=fs::OpenOptions::new().create(true).truncate(true).write(true).mode(mode).open(dest)?;
    io::copy(&mut from,&mut to)?;Ok(())
}
fn digest_line(data:&[u8],name:&[u8])->W {
    let escaped=name.contains(&b'\\')||name.contains(&b'\n');let mut out=Vec::new();if escaped{out.push(b'\\');}
    out.extend_from_slice(sha256::hex(data).as_bytes());out.extend_from_slice(b"  ");
    for &b in name{match b{b'\\'=>out.extend_from_slice(b"\\\\"),b'\n'=>out.extend_from_slice(b"\\n"),_=>out.push(b)}}out.push(b'\n');out
}
fn list_packages(dir:&Path,depth:usize,out:&mut Vec<W>){
    if depth==3{return}
    for e in fs::read_dir(dir).into_iter().flatten().filter_map(Result::ok){
        if e.file_name()=="package.json"{out.push(e.path().as_os_str().as_bytes().to_vec());}
        if e.file_type().is_ok_and(|t|t.is_dir()){list_packages(&e.path(),depth+1,out);}
    }
}
fn workspace_manifests(root:&Path)->Vec<W>{
    let Ok(root)=fs::canonicalize(root)else{return Vec::new()};
    let listing=post::workspace_members(&root);if listing==b"none"{return Vec::new()}
    let prefix=cat(&[root.as_os_str().as_bytes(),b"/"]);
    let mut members:Vec<W>=listing.split(|b|*b==b'\n').skip(1).filter(|p|!p.starts_with(b"?")).map(Vec::from).collect();
    for name in ["package-lock.json","node_modules/.package-lock.json"] {
        if let Some(st)=json::read_file(&root.join(name)){
            for v in st.values{if let Some(Value::Obj(fields))=v.get("packages"){
                for (key,_) in fields{
                    // Bash excludes (^|/)node_modules/, including its final
                    // slash; a terminal key named node_modules is different.
                    let dependency=key.starts_with(b"node_modules/")||key.windows(b"/node_modules/".len()).any(|w|w==b"/node_modules/");
                    if !key.is_empty()&&!dependency{members.push(cat(&[&prefix,key]));}
                }
            }}
        }
    }
    let mut out=Vec::new();for member in members{
        let Some(rel)=member.strip_prefix(prefix.as_slice())else{continue};
        if rel.split(|b|*b==b'/').any(|p|p==b".."||p==b"."){continue}
        let manifest=cat(&[rel,b"/package.json"]);if root.join(os::path(&manifest)).is_file(){out.push(manifest);}
    }out.sort();out.dedup();out
}

/// Component measurement only. The hook calls Snapshot after its judgment;
/// this entry lets the same file operations be compared before that path is
/// complete, without running an install or command from the input.
pub fn probe(input:&[u8])->i32 {
    let Ok(value)=json::parse_one(input)else{return 2};
    let Some(Value::Str(project))=value.get("project")else{return 2};
    let Some(Value::Str(command))=value.get("command")else{return 2};
    os::set_umask(0o077);
    let guard_dir=state::guard_dir();
    if state::ensure_dirs(&guard_dir).is_err(){return 1}
    let mut warnings=Vec::new();
    let Ok(_lock)=state::StateLock::acquire(&guard_dir.join("state.lock"),&mut warnings,None)else{return 1};
    let _=std::io::stderr().write_all(&warnings);
    let call=Call{input:value.clone(),command:command.clone(),guard:state::guard_text(),guard_dir};
    let snap=match Snapshot::create(&call,project){
        Ok(snap)=>snap,
        Err(Error::Io(e))=>{eprintln!("{}",e);return 1},
        Err(Error::Workspace(why))=>{let _=std::io::stderr().write_all(&why);return 1},
    };
    if let Some(Value::Str(rewrite))=value.get("rewrite") {
        let unread=matches!(value.get("unread"),Some(Value::Bool(true)));
        if snap.mark_rewrite(rewrite,unread).is_err(){return 1}
    }
    println!("{}",snap.id);0
}
