//! File metadata and bounded walks used by the install and backstop traces.
use super::{jv, sh, report::cat};
use crate::{json::Value, os, state};
use std::{fs, path::{Path,PathBuf}, os::unix::fs::MetadataExt, time::{Duration,Instant}};

pub const RECORDS: [&str;2] = ["package-lock.json","node_modules/.package-lock.json"];

/// jq raw output, captured by a command substitution. Errors erase the
/// result where the shell caller assigns an explicit fallback.
pub fn read(v: &Value, keys: &[&str], default: &[u8]) -> Vec<u8> {
    match jv::path(v, keys) {
        Ok(v) if jv::truthy(v) => jv::captured(&[jv::tostring(v)]),
        Ok(_) => default.to_vec(), Err(()) => Vec::new(),
    }
}
pub fn newer(path: &Path, baseline: &Path, change: bool, follow: bool) -> bool {
    let m = if follow { fs::metadata(path) } else { fs::symlink_metadata(path) };
    let (Ok(m),Ok(b))=(m,fs::metadata(baseline)) else { return false };
    let time=if change {(m.ctime(),m.ctime_nsec())} else {(m.mtime(),m.mtime_nsec())};
    time > (b.mtime(),b.mtime_nsec())
}

/// find -H: follow the argument only; links below it are visited, not walked.
/// Entries keep the directory's order, as find does. Deadline checked between
/// operations; any incomplete walk is an error, never evidence of no trace.
pub fn walk(root:&Path, max:usize, follow_root:bool, until:Option<Instant>, mut visit:impl FnMut(&Path,&fs::Metadata)->bool) -> Result<(),i32> {
    let mut todo=vec![(root.to_path_buf(),0)];
    let mut failed=false;
    while let Some((p,depth))=todo.pop() {
        if until.is_some_and(|t| Instant::now()>=t) { return Err(124) }
        let m=if depth==0 && follow_root { fs::metadata(&p).or_else(|_| fs::symlink_metadata(&p)) } else { fs::symlink_metadata(&p) };
        let Ok(m)=m else { failed=true; continue };
        if visit(&p,&m) { return Ok(()) }
        if m.is_dir() && depth<max {
            match fs::read_dir(&p) {
                Ok(entries)=>{
                    let mut children=Vec::new();
                    for e in entries { match e {Ok(e)=>children.push((e.path(),depth+1)),Err(_)=>failed=true} }
                    todo.extend(children.into_iter().rev());
                }
                Err(_)=>failed=true,
            }
        }
    }
    if failed {Err(1)} else {Ok(())}
}
pub fn package_files(root:&Path, follow:bool) -> Vec<Vec<u8>> {
    let mut out=Vec::new();
    let _=walk(root,3,follow,None,|p,_| {if sh::basename(sh::bytes(p))==b"package.json" {out.push(sh::bytes(p).to_vec());} false});
    out
}
pub fn listing(dir:&Path) -> Vec<Vec<u8>> {
    let mut out:Vec<_>=fs::read_dir(dir).into_iter().flatten().filter_map(Result::ok).map(|e|sh::basename(sh::bytes(&e.path())))
        .filter(|n|!n.starts_with(b".")).collect();
    out.sort();out
}

#[derive(Default)]
pub struct Install { pub absent:bool,pub records:Vec<Vec<u8>>,pub line:Vec<u8>,pub said:bool }
impl Install {
    pub fn settle(project:&Path,home:&Path,current:&Value,command:&[u8])->Self {
        let mut out=Self::default();
        let baseline=read(current,&["npm_trace","baseline"],b"");
        if baseline.is_empty() {out.line=b"the pending state of this command names no install-trace baseline".to_vec();return out}
        let baseline=sh::p(&baseline);
        if sh::is_file(&baseline) {
            for rel in RECORDS {
                let file=project.join(rel); if !sh::exists(&file) {continue}
                let recorded=match jv::path(current,&["npm_trace","inodes",rel]) {Ok(v)=>if jv::truthy(v) {jv::tostring(v)}else{Vec::new()},Err(_)=>b"?".to_vec()};
                let inode=fs::symlink_metadata(&file).map(|m|m.ino().to_string().into_bytes()).unwrap_or_default();
                if (!inode.is_empty() && inode!=recorded) || newer(&file,&baseline,false,true) {out.records.push(rel.as_bytes().to_vec());}
            }
            if out.records.is_empty() {out.absent=true;out.line=cat(&[b"no install trace in ",sh::bytes(project),b": neither npm lockfile there is newer than the baseline taken before this command or has another inode"]);}
            else {
                let why=read(current,&["npm_unattributable"],b"");
                if !why.is_empty() {state::log_advisory(home,&cat(&[b"post-verify UNGATED: the install trace in ",sh::bytes(project),b" cannot answer for every npm install in this command: ",&why,b", so one of them may have landed elsewhere unread. Command: ",command]));}
            }
        } else {out.absent=true;out.line=cat(&[b"no install trace in ",sh::bytes(project),b": the baseline file ",sh::bytes(&baseline),b" does not exist"]);}
        if out.absent {state::log_advisory(home,&cat(&[b"post-verify UNGATED: ",&out.line,b". Command: ",command]));}
        sh::rm_f(&baseline);out
    }
}

pub fn backstop(project:&Path,entry:&[u8],none:&[u8])->(bool,Vec<u8>) {
    if entry.is_empty() {return (true,if none.is_empty(){b"the pre-guard left no trace entry for this call".to_vec()}else{none.to_vec()})}
    let st=jv::read(entry);
    let mut lines=Vec::new();
    for v in &st.values {
        for keys in [vec!["baseline"],vec!["resolution"],vec!["inodes","package-lock.json"],vec!["inodes","node_modules/.package-lock.json"],vec!["inodes","node_modules"],vec!["clocks","package-lock.json"],vec!["clocks","node_modules/.package-lock.json"]] {
            match jv::path(v,&keys) {Ok(x)=>lines.extend(if jv::truthy(x) {jv::tostring(x)}else{Vec::new()}.split(|b|*b==b'\n').map(Vec::from)),Err(_)=>break}
        }
    }
    lines.resize_with(lines.len().max(7),Vec::new);
    let baseline=sh::p(&lines[0]);
    if lines[0].is_empty(){return(true,b"the trace entry for this call names no baseline".to_vec())}
    if !sh::is_file(&baseline){return(true,cat(&[b"the trace baseline ",&lines[0],b" does not exist"]))}
    for (i,rel) in [RECORDS[0],RECORDS[1],"node_modules"].iter().enumerate() {
        let recorded=&lines[2+i];let file=project.join(rel);
        if !sh::present(&file) {
            if !recorded.is_empty(){return(true,cat(&[sh::bytes(&file),b" existed before this command and does not exist now"]))} continue;
        }
        if recorded.is_empty(){return(true,cat(&[sh::bytes(&file),b" exists now, and the entry recorded no inode for it before this command"]))}
        if os::tree_inode(&file).as_bytes()!=recorded{return(true,cat(&[sh::bytes(&file),b" has another inode than before this command"]))}
        if i==2 {continue}
        if lines[5+i].is_empty() || os::tree_clock(&file).as_bytes()!=lines[5+i]{return(true,cat(&[sh::bytes(&file),b" has another status change time than the one recorded before this command"]))}
        if lines[1]!=b"subsecond" && newer(&file,&baseline,true,true){return(true,cat(&[sh::bytes(&file),b" changed after the baseline taken before this command"]))}
    }
    let tree=project.join("node_modules");
    let no=cat(&[b"no trace in ",sh::bytes(project),b": neither npm lockfile nor node_modules there has another inode"]);
    if !sh::exists(&tree){return(false,cat(&[&no,b", and neither lockfile changed after the record taken before this command"]))}
    let seconds=std::env::var("SAFEDEPS_BACKSTOP_WALK_SECONDS").ok().filter(|s|!s.is_empty() && s.bytes().all(|b|b.is_ascii_digit())).and_then(|s|s.parse::<u64>().ok()).filter(|s|*s<=5).unwrap_or(5);
    let until=Instant::now()+Duration::from_secs(seconds);
    let Ok(b)=fs::metadata(&baseline) else{return(true,cat(&[b"the trace baseline ",sh::bytes(&baseline),b" does not exist"]))};
    let mut found=Vec::new();
    let rc=walk(&tree,usize::MAX,true,Some(until),|p,m|{
        if (m.ctime(),m.ctime_nsec())>(b.mtime(),b.mtime_nsec()){found=sh::bytes(p).to_vec();true}else{false}
    });
    if !found.is_empty(){return(true,cat(&[&found,b" changed after the baseline taken before this command"]))}
    match rc {
        Err(124)=>(true,cat(&[b"the walk of ",sh::bytes(&tree),b" did not finish within ",seconds.to_string().as_bytes(),b"s"])),
        Err(rc)=>(true,cat(&[b"the walk of ",sh::bytes(&tree),b" failed (find exit ",rc.to_string().as_bytes(),b")"])),
        Ok(())=>(false,cat(&[&no,b", neither lockfile changed after the record taken before this command, and nothing in node_modules changed after the baseline"])),
    }
}
pub fn drop_baseline(home:&Path,entry:&[u8]) {
    let st=jv::read(entry);
    let (lines,rc)=jv::each(&st,|v|{let x=jv::field(v,"baseline")?;Ok(if jv::truthy(x){vec![jv::tostring(x)]}else{Vec::new()})});
    if rc!=0{return}
    let path=jv::captured(&lines);
    let prefix=cat(&[sh::bytes(home),b"/pending/backstop/"]);
    if path.starts_with(&prefix) && path.ends_with(b".trace"){sh::rm_f(&sh::p(&path));}
}
