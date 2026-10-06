//! After the final verdict, one call's record and its install trace baseline.
//! Backstop entries and install records are mutually exclusive caller paths.
use super::{cat, Call, snapshot::Snapshot};
use crate::{callid,jq,json::Value,md5,os,state};
use std::{fs,io,os::unix::{fs::{DirBuilderExt,MetadataExt,OpenOptionsExt},ffi::OsStrExt},path::{Path,PathBuf}};

pub struct Record<'a> {
    pub cwd:&'a [u8],
    pub project_from:&'a str,
    pub trace:bool,
    pub attribution:&'a [u8],
    pub fetch:Option<&'a Value>,
    pub fetch_why:&'a [u8],
}
fn inode(path:&Path)->String {
    // ls -di names the link's own inode, but only when its target exists.
    if !path.exists(){return String::new()}
    fs::symlink_metadata(path).map(|m|m.ino().to_string()).unwrap_or_default()
}

pub fn write(call:&Call,snapshot:&Snapshot,record:&Record)->io::Result<PathBuf> {
    let dir=call.guard_dir.join("pending");
    fs::DirBuilder::new().recursive(true).mode(0o700).create(&dir)?;
    state::sweep_pending(&dir);
    let id=callid::from_stream(&call.input);
    let base=if let Some(id)=&id{dir.join(format!("id-{}",id))}else{
        let key=state::pending_key(&md5::hex(record.cwd),&call.command);
        state::log_advisory(&call.guard_dir,&cat(&[b"pre-guard: this hook's input names no tool_use_id, so the record of this install is kept under its directory and command, and another call of the same command in the same directory can use it. Command: ",&call.command]));
        dir.join(format!("{}__{}",key,snapshot.id))
    };
    let trace_path=os::path(&cat(&[base.as_os_str().as_bytes(),b".trace"]));
    let project=os::path(&snapshot.project);
    let trace=if record.trace{
        let value=jq::obj(vec![("baseline",jq::arg(trace_path.as_os_str().as_bytes())),("inodes",jq::obj(vec![
            ("package-lock.json",jq::s(&inode(&project.join("package-lock.json")))),
            ("node_modules/.package-lock.json",jq::s(&inode(&project.join("node_modules/.package-lock.json"))))]))]);
        fs::OpenOptions::new().create(true).truncate(true).write(true).mode(0o600).open(&trace_path)?;
        value
    }else{jq::J::Null};
    let fetch=if !record.trace{jq::J::Null}else if let Some(v @ Value::Obj(_))=record.fetch{jq::from_value(v)}else{
        jq::obj(vec![("unknown",jq::arg(&cat(&[b"npm was not asked which registry this install fetches from: ",record.fetch_why])))])
    };
    let value=jq::obj(vec![
        ("snapshot_id",jq::s(&snapshot.id)),("project_dir",jq::arg(&snapshot.project)),("dir_hash",jq::s(&snapshot.hash)),
        ("project_dir_from",jq::s(record.project_from)),("npm_trace",trace),("npm_unattributable",jq::arg(record.attribution)),
        ("npm_fetch",fetch),("tool_use_id",id.as_deref().map(jq::s).unwrap_or(jq::J::Null)),
    ]);
    let path=os::path(&cat(&[base.as_os_str().as_bytes(),b".json"]));
    state::write_state_file(&path,jq::pretty(&value).as_bytes())?;
    Ok(path)
}
