//! The post hook's script, lockfile-change, and new-bin heuristics.
use super::{closure, jv, sh, snapshot::{self, Store}, trace, report::cat};
use crate::{ere::Regex, json::Value, sha256};
use std::{collections::HashSet, fs, path::Path, time::Instant};
type W = Vec<u8>;

pub(super) mod native;
#[cfg(test)]
mod lockfile_tests;

fn raw_field(st: &jv::Stream, keys: &[&str], default: &[u8]) -> Result<W, i32> {
    let (lines, rc) = jv::each(st, |v| {
        let v = jv::path(v, keys)?;
        Ok(if jv::truthy(v) { vec![jv::tostring(v)] } else if default.is_empty() { Vec::new() } else { vec![default.to_vec()] })
    });
    if rc == 0 { Ok(jv::captured(&lines)) } else { Err(rc) }
}
fn script_file(path: &Path) -> Result<bool, ()> {
    let st = jv::read_file(path).ok_or(())?;
    if st.failed { return Err(()) }
    for v in &st.values {
        if !matches!(v, Value::Obj(_)) { continue }
        let Ok(scripts @ Value::Obj(_)) = jv::field(v, "scripts") else { continue };
        for key in ["preinstall", "install", "postinstall"] {
            let val = jv::field(scripts, key)?;
            if jv::truthy(val) && !matches!(val, Value::Str(s) if s.is_empty()) { return Ok(true) }
        }
    }
    Ok(false)
}
fn redacted(script: &[u8]) -> W {
    let flat: W = script.iter().map(|b| if matches!(b, b'\r' | b'\n' | b'\t') { b' ' } else { *b }).take(160).collect();
    cat(&[b"[redacted install script sha256=", sha256::hex(script).as_bytes(), b" bytes=", script.len().to_string().as_bytes(), b" preview=", &flat, if script.len() > 160 { b"..." } else { b"" }, b"]"])
}
pub fn scripts(store: &Store, new_nodes: &[W], reasons: &mut Vec<W>) -> Result<(), i32> {
    let manifest = store.project.join("package.json");
    let changed = snapshot::LOCKS.iter().any(|name| snapshot::differs(&store.path(&store.id, name.as_bytes()), &store.project.join(name)))
        || snapshot::differs(&store.path(&store.id, b"package.json"), &manifest);
    let mut candidates = Vec::new();
    let tree = store.project.join("node_modules");
    if sh::is_file(&manifest) && sh::is_dir(&tree) && changed {
        let mut now = trace::package_files(&tree, false);
        let old = store.path(&store.id, b"packages.list");
        if sh::is_file(&old) {
            now.sort();
            let old = snapshot::sorted_lines(&old);
            now.retain(|p| !old.contains(p));
        }
        candidates.extend(now.into_iter().take(50).filter(|p| !p.is_empty()));
    }
    for node in new_nodes {
        let p = store.project.join(sh::p(node)).join("package.json");
        if sh::is_file(&p) { candidates.push(sh::bytes(&p).to_vec()); }
    }
    if candidates.is_empty() { return Ok(()) }
    let selected: Result<Vec<_>, ()> = candidates.iter().map(|p| script_file(&sh::p(p)).map(|yes| (yes, p.clone()))).collect();
    let mut selected = selected.map(|xs| xs.into_iter().filter(|(yes,_)| *yes).map(|(_,p)| p).collect::<Vec<_>>()).unwrap_or(candidates);
    selected.sort(); selected.dedup();
    let network = Regex::new("(curl|wget|fetch|http|https|net\\.|socket|dns)", true).map_err(|_| 1)?;
    let execution = Regex::new("(eval|exec|spawn|child_process|Function\\()", true).map_err(|_| 1)?;
    let paths = Regex::new("(/etc/|/home/|~/|\\$HOME|\\.ssh|\\.env|\\.aws|credentials|~/\\.safedeps|\\$HOME/\\.safedeps|\\.safedeps/|SAFEDEPS_HOME)", true).map_err(|_| 1)?;
    let encoded = Regex::new(r"(base64|atob|Buffer\.from|\\x[0-9a-f]{2}|\\u[0-9a-f]{4})", true).map_err(|_| 1)?;
    for p in selected {
        let st = jv::read_file(&sh::p(&p)).ok_or(2)?;
        let scripts = [raw_field(&st, &["scripts", "preinstall"], b"")?, raw_field(&st, &["scripts", "postinstall"], b"")?, raw_field(&st, &["scripts", "install"], b"")?];
        let name = raw_field(&st, &["name"], b"unknown")?;
        for script in scripts.iter().filter(|s| !s.is_empty()) {
            for (regex, label) in [(&network, b"network access".as_slice()), (&execution, b"code execution")] {
                if regex.is_match(script) { reasons.push(cat(&[b"Package '", &name, b"' has install script with ", label, b": ", &redacted(script)])); }
            }
            if paths.is_match(script) { reasons.push(cat(&[b"Package '", &name, b"' has install script accessing sensitive paths"])); }
            if encoded.is_match(script) { reasons.push(cat(&[b"Package '", &name, b"' has install script with obfuscated content"])); }
        }
    }
    Ok(())
}

/// What the count reads of an npm lockfile: no JSON text at all, or the
/// package names of one JSON object, those its `packages` map gives (None
/// where it has no such map) and those its `dependencies` tree gives.
enum Lock { Blank, Names(Option<HashSet<W>>, HashSet<W>) }

/// `.[key]` where npm writes a map: None where it is absent or null, and Err
/// where it is anything else.
fn map<'a>(v: &'a Value, key: &str) -> Result<Option<&'a [(W, Value)]>, ()> {
    match jv::field(v, key)? { Value::Null => Ok(None), Value::Obj(o) => Ok(Some(o.as_slice())), _ => Err(()) }
}
/// The folder a key names: its last name, with the scope in front of it.
fn folder(key: &[u8]) -> Option<W> {
    let mut parts = key.rsplit(|b| *b == b'/').filter(|p| !p.is_empty());
    let last = parts.next()?;
    Some(match parts.next() { Some(scope) if scope.starts_with(b"@") => cat(&[scope, b"/", last]), _ => last.to_vec() })
}
/// The names an entry declares beside its place: the package it is (`name`,
/// where the place is an alias) and the package an `npm:` version aliases
/// (how the `dependencies` tree spells an alias).
fn declared(entry: &Value, names: &mut HashSet<W>) -> Result<(), ()> {
    match jv::field(entry, "name")? {
        Value::Str(name) => { names.insert(name.clone()); }
        other if jv::truthy(other) => return Err(()),
        _ => {}
    }
    if let Value::Str(version) = jv::field(entry, "version")? {
        if let Some(spec) = version.strip_prefix(b"npm:") {
            let end = spec.iter().rposition(|b| *b == b'@').filter(|at| *at > 0).unwrap_or(spec.len());
            names.insert(spec[..end].to_vec());
        }
    }
    Ok(())
}
/// The `dependencies` tree of lockfileVersion 1 and 2: each key is a name,
/// and an entry nests its own tree.
fn tree(v: &Value, names: &mut HashSet<W>) -> Result<(), ()> {
    let Some(entries) = map(v, "dependencies")? else { return Ok(()) };
    for (name, entry) in entries {
        names.insert(name.clone());
        declared(entry, names)?;
        tree(entry, names)?;
    }
    Ok(())
}
/// The names the lock gives a package, from each of npm's maps: a key of
/// `packages` gives the name npm's closure reads there and the folder it is,
/// a key of the tree is a name, and an entry adds the names it declares. A
/// name is its bytes, so a scope or case alone makes another one. Err where
/// the text is not one JSON object, or where a map npm writes, an entry, or a
/// declared name is there and is not one.
fn lock(text: &[u8]) -> Result<Lock, ()> {
    let st = jv::read(text);
    let v = match (st.failed, st.values.as_slice()) {
        (false, []) => return Ok(Lock::Blank),
        (false, [v @ Value::Obj(_)]) => v,
        _ => return Err(()),
    };
    let packages = match map(v, "packages")? {
        Some(entries) => {
            let mut names = HashSet::new();
            for (key, entry) in entries.iter().filter(|(key, _)| !key.is_empty()) {
                if jv::in_tree(key) { if let Value::Str(name) = closure::name_from_path(key) { names.insert(name); } }
                names.extend(folder(key));
                declared(entry, &mut names)?;
            }
            names.remove(&W::new());
            Some(names)
        }
        None => None,
    };
    let mut names = HashSet::new();
    tree(v, &mut names)?;
    names.remove(&W::new());
    Ok(Lock::Names(packages, names))
}
/// The reason an install that brings more than 50 package names into
/// package-lock.json is rolled back. It counts the names the lock after the
/// command lists in either map that the copy taken before the command does
/// not hold. The copy holds what npm reads of it, as the effect gate reads a
/// record (`closure::new_records`): its `packages` map where it has one, and
/// its `dependencies` tree where it does not. So a name only the copy's
/// unread tree lists is not held. Another version, place or source of a name
/// it holds is not a new name: the closure check judges that version against
/// the approvals and OSV, and the source and install-script checks read the
/// record it is. Each file is read once, and the comparison and the count act
/// on that one read.
///
/// A copy with no JSON text held no names, as npm reads an empty lockfile, so
/// every name after it counts. A lock that cannot be read is not counted as
/// none: it is a reason. With no copy there was no lockfile before, and the
/// count is not made: it would cross 50 on the first install of any project
/// with more than 50 dependencies.
pub fn lockfile(store: &Store, reasons: &mut Vec<W>) {
    let old = store.path(&store.id, b"package-lock.json");
    let now = store.project.join("package-lock.json");
    if !sh::is_file(&old) || !sh::is_file(&now) { return }
    let (before, after) = (fs::read(&old), fs::read(&now));
    if matches!((&before, &after), (Ok(a), Ok(b)) if a == b) { return }
    let before = before.map_err(drop).and_then(|t| lock(&t));
    let after = after.map_err(drop).and_then(|t| lock(&t));
    const UNCOUNTED: &[u8] = b"New dependencies could not be counted: package-lock.json";
    let (before, after): (HashSet<W>, HashSet<W>) = match (before, after) {
        (Ok(Lock::Blank), Ok(Lock::Names(packages, tree))) => (HashSet::new(), packages.unwrap_or_default().into_iter().chain(tree).collect()),
        (Ok(Lock::Names(held, tree)), Ok(Lock::Names(packages, more))) => (held.unwrap_or(tree), packages.unwrap_or_default().into_iter().chain(more).collect()),
        (before, after) => {
            if before.is_err() { reasons.push(cat(&[UNCOUNTED, b" from before the command could not be read as a lockfile"])); }
            if !matches!(after, Ok(Lock::Names(..))) { reasons.push(cat(&[UNCOUNTED, b" could not be read as a lockfile"])); }
            return
        }
    };
    let count = after.difference(&before).count();
    if count > 50 { reasons.push(cat(&[b"Unusually large number of new dependencies added: ", count.to_string().as_bytes()])); }
}
/// Keep the native heuristic out of an already rejected install's path.
pub fn binaries(store: &Store, reasons: &mut Vec<W>, post_started: Instant) {
    if !reasons.is_empty() { return }
    let result = native::supervise::inspect(store, post_started);
    if let Some(reason) = result.reason() { reasons.push(reason); }
}
