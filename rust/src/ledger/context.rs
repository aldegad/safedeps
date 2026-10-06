//! The project input evidence that scopes an npm ledger approval. No package
//! manager runs here: these hashes describe files and the declared overrides.
use crate::{json::{self,Value},jq,os,sha256};
use std::{fs,path::Path,os::unix::ffi::OsStrExt};
type W=Vec<u8>;
fn field<'a>(v:&'a Value,key:&str)->Result<Option<&'a Value>,()> {
    match v {Value::Null|Value::Obj(_)=>Ok(v.get(key)),_=>Err(())}
}
fn sorted(v:&Value)->Value {
    match v {
        Value::Obj(fields)=>{let mut fields:Vec<_>=fields.iter().map(|(k,v)|(k.clone(),sorted(v))).collect();fields.sort_by(|a,b|a.0.cmp(&b.0));Value::Obj(fields)},
        Value::Arr(values)=>Value::Arr(values.iter().map(sorted).collect()),
        v=>v.clone(),
    }
}
fn dump(v:&Value)->W {jq::compact(&jq::from_value(v)).into_bytes()}
fn string(b:impl AsRef<[u8]>)->Value {jq::into_value(jq::arg(b.as_ref()))}
fn bytes(path:&Path)->W {path.as_os_str().as_bytes().to_vec()}
fn cat(parts:&[&[u8]])->W {parts.concat()}

// The ledger writer uses shasum/sha256sum's first field. Those tools prefix
// an escaped filename's line with a backslash; cut preserves that byte.
// Keep this existing context identity, rather than turning a stored scoped
// approval into a miss by quietly replacing it with bare hexadecimal.
fn file_hash(data:&[u8],filename:&[u8])->String {
    format!("{}{}",if filename.iter().any(|b|matches!(b,b'\\'|b'\n')){"\\"}else{""},sha256::hex(data))
}

/// safedeps_npm_repo_overrides_json. The source follows the declaration even
/// when filtering dollar references leaves no supported overrides.
pub fn overrides(dir:&Path)->(W,W) {
    use std::os::unix::ffi::OsStringExt;
    let given=std::env::var_os("SAFEDEPS_NPM_OVERRIDES_JSON").map(|v|v.into_vec()).unwrap_or_default();
    if !given.is_empty(){return(given,b"env".to_vec())}
    let mut dir=dir.to_path_buf();
    while dir!=Path::new("/")&&!dir.as_os_str().is_empty() {
        let file=dir.join("package.json");
        if let Some(stream)=json::read_file(&file) {
            let (declared,rc)=json::each(&stream,|v|{
                Ok(if matches!(field(v,"overrides")?,Some(Value::Obj(o))if !o.is_empty()){vec![b"1".to_vec()]}else{Vec::new()})
            });
            if rc==0&&!declared.is_empty() {
                let (lines,rc)=json::each(&stream,|v|{
                    let value=field(v,"overrides")?;
                    let fields=match value {Some(Value::Obj(o))=>o.as_slice(),_=>&[]};
                    let kept=fields.iter().filter(|(_,v)|match v {
                        Value::Str(s)=>!s.starts_with(b"$"),Value::Obj(_)=>!dump(v).contains(&b'$'),_=>false,
                    }).cloned().collect();
                    Ok(vec![dump(&Value::Obj(kept))])
                });
                let mut text=json::captured(&lines);if rc!=0{text.extend_from_slice(b"{}");}
                return(text,bytes(&file));
            }
        }
        if dir.join(".git").exists(){break}
        let Some(parent)=dir.parent()else{break};
        let parent=if parent.as_os_str().is_empty(){Path::new(".")}else{parent};
        if parent==dir{break}dir=parent.to_path_buf();
    }
    (b"{}".to_vec(),W::new())
}

pub fn overrides_context(raw:&[u8],source:&[u8])->Option<Value> {
    if raw.is_empty()||raw==b"{}"||source.is_empty(){return None}
    let root=if source==b"env"{b"env".to_vec()}else{
        let path=os::path(source);bytes(&fs::canonicalize(path.parent()?).ok()?)
    };
    let values=json::parse_stream(raw).ok()?;
    let canonical=json::captured(&values.iter().map(|v|dump(&sorted(v))).collect::<Vec<_>>());
    if canonical.is_empty(){return None}
    let digest=sha256::hex(&canonical);let context=sha256::hex(&cat(&[&root,b"\n",digest.as_bytes()]));
    // --argjson accepts one value; extra texts cannot write a context file.
    if values.len()!=1{return None}
    Some(jq::into_value(jq::obj(vec![
        ("context_hash",jq::s(&format!("sha256:{}",context))),("project_root",jq::arg(&root)),
        ("overrides_source",jq::arg(source)),("overrides_sha256",jq::s(&format!("sha256:{}",digest))),
        ("overrides",jq::from_value(&values[0])),
    ])))
}

/// The returned message is the original closure helper's stderr. Empty means
/// the file operation failed without an additional closure diagnostic.
fn yarn_inputs(root:&Path,manifest:&json::Stream)->Result<(W,Value),W> {
    let (patterns,rc)=json::each(manifest,|v| {
        let ws=field(v,"workspaces")?;
        let ws=match ws{Some(Value::Obj(_))=>ws.and_then(|v|v.get("packages")),ws=>ws};
        let values=match ws{Some(Value::Arr(a))=>a.as_slice(),Some(Value::Obj(o))=>return Ok(o.iter().map(|(_,v)|match v {Value::Str(s)=>s.clone(),v=>dump(v)}).collect()),_=>&[]};
        Ok(values.iter().map(|v|match v{Value::Str(s)=>s.clone(),v=>dump(v)}).collect())
    });
    if rc!=0{return Err(W::new())}
    let root_bytes=bytes(root);let mut sources=vec![root.join("package.json")];
    // jq -r plus read -r: a string containing a newline becomes two patterns.
    for pat in patterns.iter().flat_map(|p|p.split(|b|*b==b'\n')).filter(|p|!p.is_empty()) {
        if pat.iter().any(|b|b.is_ascii_whitespace())||pat.starts_with(b"/")||pat.windows(2).any(|w|matches!(w,b".."|b"**"))||pat.starts_with(b"!") {
            return Err(cat(&[b"safedeps npm closure: unsupported Yarn workspace pattern: ",pat,b"\n"]))
        }
        for member in crate::post::workspace_glob_members(root,pat) {
            let member=fs::canonicalize(os::path(&member)).map_err(|_|W::new())?;
            if !member.starts_with(root)||member==root{return Err(cat(&[b"safedeps npm closure: Yarn workspace escapes project root: ",pat,b"\n"]))}
            sources.push(member.join("package.json"));
        }
    }
    for name in ["yarn.lock",".yarnrc.yml"]{let p=root.join(name);if p.is_file(){sources.push(p)}}
    for name in [".yarn/releases",".yarn/plugins",".yarn/patches"] {
        let p=root.join(name);if !p.is_dir(){continue}
        // find's default -P does not follow the starting symlink, either.
        let mut dirs=vec![p];
        while let Some(d)=dirs.pop(){
            if fs::symlink_metadata(&d).is_ok_and(|m|m.file_type().is_symlink()){continue}
            let Ok(entries)=fs::read_dir(&d)else{continue};
            for entry in entries.flatten(){
                let Ok(kind)=entry.file_type()else{continue};
                if kind.is_dir(){dirs.push(entry.path())}else if kind.is_file(){sources.push(entry.path())}
            }
        }
    }
    // The shell's find output is line-oriented, then LC_ALL=C sort -u.
    let mut paths:Vec<W>=sources.iter().flat_map(|p|bytes(p).split(|b|*b==b'\n').map(Vec::from).collect::<Vec<_>>()).collect();
    paths.sort();paths.dedup();
    let prefix=cat(&[&root_bytes,b"/"]);let mut input=W::new();let mut files=Vec::new();
    for full in paths {
        let path=os::path(&full);if !path.is_file(){continue}
        // ${source_file#${project_root}/}: the expanded root is a shell
        // pattern, and # removes its shortest matching prefix. Matching
        // belongs to the shared shell matcher, including quoted bytes.
        // The pattern ends in a literal slash, so only slash boundaries
        // can end a match (also avoiding partial multibyte characters).
        let relative=full.iter().enumerate().filter(|(_,b)|**b==b'/')
            .find(|(i,_)|crate::post::shell_pattern_matches(&prefix,&full[..i+1]))
            .map(|(i,_)|&full[i+1..]).unwrap_or(&full);
        if relative==full||relative.is_empty()||relative.iter().any(|b|matches!(b,b'\n'|b'\r'|b'\t')) {
            return Err(b"safedeps npm closure: unsafe Yarn project input path\n".to_vec())
        }
        let data=fs::read(path).map_err(|_|W::new())?;let hash=format!("sha256:{}",file_hash(&data,&full));
        input.extend_from_slice(&cat(&[relative,b"\t",hash.as_bytes(),b"\n"]));
        files.push(Value::Obj(vec![(b"path".to_vec(),string(relative)),(b"sha256".to_vec(),string(hash.as_bytes()))]));
    }
    if input.is_empty(){return Err(b"safedeps npm closure: Yarn materialization has no canonical inputs\n".to_vec())}
    let tmp=std::env::var_os("TMPDIR").filter(|s|!s.is_empty()).unwrap_or_else(||"/tmp".into());
    Ok((format!("sha256:{}",file_hash(&input,tmp.as_os_str().as_bytes())).into_bytes(),Value::Arr(files)))
}

pub fn yarn(project:&Path)->Result<Option<Value>,W> {
    if !project.is_dir(){return Err(cat(&[b"safedeps npm closure: project directory not found: ",&bytes(project),b"\n"]))}
    let mut dir=fs::canonicalize(project).map_err(|_|W::new())?;
    loop {
        let manifest=dir.join("package.json");let lock=dir.join("yarn.lock");
        if manifest.is_file()&&lock.is_file(){
            if let Some(stream)=json::read_file(&manifest) {
                let (lines,rc)=json::each(&stream,|v|Ok(vec![if matches!(field(v,"resolutions")?,Some(Value::Obj(o))if !o.is_empty()){b"true".to_vec()}else{b"false".to_vec()}]));
                if rc==0&&lines.last().is_some_and(|v|v==b"true") {
                    let data=fs::read(&lock).map_err(|_|W::new())?;
                    if !data.split(|b|*b==b'\n').any(|line|line.starts_with(b"__metadata:")) {
                        return Err(cat(&[b"safedeps npm closure: Yarn resolutions found, but yarn.lock is not a supported Berry lockfile: ",&bytes(&lock),b"\n"]))
                    }
                    let (inputs,files)=yarn_inputs(&dir,&stream)?;
                    let (resolutions,rc)=json::each(&stream,|v|Ok(vec![dump(&sorted(field(v,"resolutions")?.unwrap_or(&Value::Null)))]));
                    if rc!=0{return Err(W::new())}
                    let resolutions=sha256::hex(&json::captured(&resolutions));let lock_hash=file_hash(&data,&bytes(&lock));
                    let context=sha256::hex(&cat(&[&bytes(&dir),b"\n",resolutions.as_bytes(),b"\n",lock_hash.as_bytes(),b"\n",&inputs]));
                    return Ok(Some(jq::into_value(jq::obj(vec![
                        ("type",jq::s("yarn-project-lockfile")),("context_hash",jq::s(&format!("sha256:{}",context))),
                        ("project_root",jq::arg(&bytes(&dir))),("manifest_path",jq::arg(&bytes(&manifest))),("lockfile_path",jq::arg(&bytes(&lock))),
                        ("resolutions_sha256",jq::s(&format!("sha256:{}",resolutions))),("lockfile_sha256",jq::s(&format!("sha256:{}",lock_hash))),
                        ("input_sha256",jq::arg(&inputs)),("input_files",jq::from_value(&files)),
                    ]))))
                }
            }
        }
        if dir.join(".git").exists()||!dir.pop(){return Ok(None)}
    }
}

pub fn project_context(project:&Path)->Result<Option<Value>,W> {
    if let Some(value)=yarn(project)?{return Ok(Some(value))}
    let (raw,source)=overrides(project);Ok(overrides_context(&raw,&source))
}


pub fn probe(input:&[u8])->i32 {
    use std::io::Write;
    let Ok(v)=json::parse_one(input)else{return 2};
    let Some(path)=v.get("path").and_then(Value::as_bytes)else{return 2};
    let result=match v.get("op").and_then(Value::as_str){
        Some("yarn")=>yarn(&os::path(&path)),
        Some("overrides")=>{let(raw,source)=overrides(&os::path(&path));Ok(overrides_context(&raw,&source))},
        Some("project")=>project_context(&os::path(&path)),
        _=>return 2,
    };
    match result {
        Ok(Some(v))=>{println!("{}",jq::compact(&jq::from_value(&v)));0},
        Ok(None)=>1,
        Err(message)=>{let _=std::io::stderr().write_all(&message);2},
    }
}
