//! The post hook's script, lockfile-change, and new-bin heuristics. `file`
//! retains the host's classifier; it receives only an inspected path as argv.
use super::{jv, sh, snapshot::{self, Store}, trace, report::cat};
use crate::{ere::Regex, json::Value, sha256};
use std::{fs, path::Path, process::{Command, Stdio}};
type W = Vec<u8>;

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

/// Count resolved lines inserted along a shortest edit path. No patch or
/// subprocess is needed, and frontier storage is linear in the line count.
pub fn added_resolved(before: &[u8], after: &[u8]) -> usize {
    if before.contains(&0) || after.contains(&0) { return 0 }
    let a: Vec<_> = before.split_inclusive(|b| *b == b'\n').collect();
    let b: Vec<_> = after.split_inclusive(|b| *b == b'\n').collect();
    let n = a.len(); let m = b.len(); let max = n + m;
    let offset = max as isize + 1;
    let mut frontier = vec![(0usize, 0usize); 2 * max + 3];
    let index = |k: isize| (offset + k) as usize;
    for distance in 0..=max {
        let d = distance as isize;
        for k in (-d..=d).step_by(2) {
            let down = k == -d || (k != d && frontier[index(k-1)].0 < frontier[index(k+1)].0);
            let (mut x, mut count) = if down { frontier[index(k+1)] } else { let (x,c) = frontier[index(k-1)]; (x+1,c) };
            let mut y = (x as isize - k) as usize;
            if distance > 0 && down && y > 0 && y <= m && b[y-1].windows(10).any(|s| s == b"\"resolved\"") { count += 1; }
            while x < n && y < m && a[x] == b[y] { x += 1; y += 1; }
            frontier[index(k)] = (x,count);
            if x >= n && y >= m { return count }
        }
    }
    0
}
pub fn lockfile(store: &Store, reasons: &mut Vec<W>) {
    let old = store.path(&store.id, b"package-lock.json");
    let now = store.project.join("package-lock.json");
    if !sh::is_file(&old) || !sh::is_file(&now) || !snapshot::differs(&old, &now) { return }
    let count = match (fs::read(old), fs::read(now)) { (Ok(a),Ok(b)) => added_resolved(&a,&b), _ => 0 };
    if count > 50 { reasons.push(cat(&[b"Unusually large number of new dependencies added: ", count.to_string().as_bytes()])); }
}
pub fn binaries(store: &Store, reasons: &mut Vec<W>) {
    let dir = store.project.join("node_modules/.bin");
    if !sh::is_dir(&dir) { return }
    let old = store.path(&store.id, b"bins.list");
    let old = if sh::is_file(&old) { snapshot::sorted_lines(&old) } else { Vec::new() };
    let names: Vec<_> = trace::listing(&dir).into_iter().filter(|n| !old.contains(n)).take(20).collect();
    // The original `for bin in ${new_bins}` splits names on shell IFS.
    let names = names.join(&b'\n');
    let pattern = Regex::new("(executable|shared object|Mach-O|ELF)", true).unwrap();
    for name in names.split(|b| matches!(b, b' ' | b'\t' | b'\n')).filter(|s| !s.is_empty()) {
        let path = dir.join(sh::p(name));
        if !sh::is_file(&path) { continue }
        let answer = Command::new("file").arg(&path).stdin(Stdio::null()).stderr(Stdio::null()).output();
        if answer.is_ok_and(|o| o.status.success() && pattern.is_match(&o.stdout)) {
            reasons.push(cat(&[b"Native binary '", name, b"' found in node_modules/.bin"]));
        }
    }
}
