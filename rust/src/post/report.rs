//! The closed line forms in lib/gates/report-facts.sh. Each filesystem claim
//! is read here when it is said; the caller owns the rollback's ordering.
use super::{jv, sh};
use crate::{json::Value, state};
use std::{fs, path::Path};

pub const UNREAD: &[u8] = b"safedeps did not read all of the command it wrote as the shell will";
pub const ADDED: &[u8] = b"safedeps added --ignore-scripts to this install";
pub const NONE: &[u8] = b"safedeps did not add --ignore-scripts to this install";
pub const ASKED: &[u8] = b"safedeps asked for --ignore-scripts on this install; the command this hook received is not the one safedeps wrote";

pub fn cat(parts: &[&[u8]]) -> Vec<u8> { parts.concat() }

pub fn link_target(path: &Path) -> Vec<u8> {
    let Ok(link) = fs::read_link(path) else { return b"an unreadable target".to_vec() };
    let raw = if link.is_absolute() { link } else { sh::p(&cat(&[&sh::dirname(sh::bytes(path)), b"/", sh::bytes(&link)])) };
    if let Some(dir) = sh::cd_physical(Path::new("."), &raw) { return sh::bytes(&dir).to_vec() }
    let parent = sh::p(&sh::dirname(sh::bytes(&raw)));
    if let Some(dir) = sh::cd_physical(Path::new("."), &parent) {
        cat(&[sh::bytes(&dir), b"/", &sh::basename(sh::bytes(&raw))])
    } else { sh::bytes(&raw).to_vec() }
}

pub fn path(path: &Path) -> Vec<u8> {
    if sh::is_link(path) { cat(&[sh::bytes(path), b" is a symbolic link to ", &link_target(path)]) }
    else if sh::exists(path) { cat(&[sh::bytes(path), b" exists"]) }
    else { cat(&[sh::bytes(path), b" does not exist"]) }
}

pub fn outside(project: &Path, target: &Path) -> Option<Vec<u8>> {
    if sh::cd_physical(Path::new("."), project).is_none() {
        Some(cat(&[b"the project directory ", sh::bytes(project), b" cannot be resolved"]))
    } else if sh::is_link(target) { Some(path(target)) } else { None }
}

pub fn reach_blocker(project: &Path) -> Option<Vec<u8>> {
    if sh::cd_physical(Path::new("."), project).is_none() {
        return Some(cat(&[b"the directory ", sh::bytes(project), b" cannot be resolved"]));
    }
    for name in ["package.json", "package-lock.json", "npm-shrinkwrap.json", "node_modules"] {
        let p = project.join(name);
        if sh::is_link(&p) { return Some(path(&p)) }
    }
    None
}

pub fn file(label: &[u8], p: &Path) -> Vec<u8> {
    cat(&[label, b": ", sh::bytes(p), if sh::is_file(p) { b"" } else { b" is not a file" }])
}

pub fn refused(kind: &[u8], path: &Path, why: &[u8]) -> Vec<u8> {
    cat(&[b"refused ", kind, b" of ", sh::bytes(path), b": ", why])
}

/// Err(1): unreadable/not one object; Err(2): absent or the v2 fact is unstated.
pub fn inert(meta: &Path, input: &[u8]) -> Result<Vec<u8>, i32> {
    if !sh::present(meta) { return Err(2) }
    let m = jv::read_one_object(meta).ok_or(1)?;
    let st = jv::read(input);
    let (lines, rc) = jv::each(&st, |v| {
        let said: &[u8] = if !jv::eq(jv::field(&m, "record")?, &jv::num(2)) { b"unstated" }
        else if matches!(jv::field(&m, "ignore_scripts_injected")?, Value::Bool(false)) { b"none" }
        else if matches!(jv::field(&m, "ignore_scripts_injected")?, Value::Bool(true)) && matches!(jv::field(&m, "updated_command")?, Value::Str(_)) {
            if jv::eq(jv::path(v, &["tool_input", "command"])?, jv::field(&m, "updated_command")?) { b"added" } else { b"asked" }
        } else { b"unstated" };
        Ok(vec![said.to_vec()])
    });
    if rc != 0 { return Err(1) }
    match jv::captured(&lines).as_slice() {
        b"none" => Ok(NONE.to_vec()), b"added" => Ok(ADDED.to_vec()), b"asked" => Ok(ASKED.to_vec()), b"unstated" => Err(2), _ => Err(1),
    }
}

pub fn inert_unread(meta: &Path) -> bool {
    let Some(st) = jv::read_file(meta) else { return false };
    let (lines, rc) = jv::each(&st, |v| Ok(vec![if jv::eq(jv::field(v, "record")?, &jv::num(2))
        && matches!(jv::field(v, "ignore_scripts_injected")?, Value::Bool(true))
        && matches!(jv::field(v, "ignore_scripts_unread")?, Value::Bool(true)) { b"true".to_vec() } else { b"false".to_vec() }]));
    rc == 0 && jv::captured(&lines) == b"true"
}

pub fn inert_unsaid(home: &Path, meta: &Path, rc: i32) {
    let line = if rc == 2 { cat(&[b"post-verify: ", sh::bytes(meta), b" is not a version 2 pre-guard record that states whether safedeps rewrote this command, so no --ignore-scripts line was said"]) }
    else { cat(&[b"post-verify: could not read the pre-guard's record of this command in ", sh::bytes(meta), b", so no --ignore-scripts line was said"]) };
    state::log_advisory(home, &line);
}

// Only the result of our own operation is named. Some local checks return an
// I/O error without an OS code; none is invented for those checks.
fn io_outcome(action: &[u8], result: &std::io::Result<()>) -> Vec<u8> {
    match result {
        Ok(()) => cat(&[action, b" returned without error"]),
        Err(error) => match error.raw_os_error() {
            Some(code) => cat(&[action, b" returned OS error ", code.to_string().as_bytes()]),
            None => cat(&[action, b" returned an error without an OS code"]),
        },
    }
}

#[derive(Default)]
pub struct Report { pub lines: Vec<Vec<u8>>, pub changed: usize, pub inert: Vec<u8> }
impl Report {
    pub fn say(&mut self, s: impl AsRef<[u8]>) { self.lines.push(s.as_ref().to_vec()); }
    pub fn path(&mut self, p: &Path) { self.say(path(p)); }
    pub fn workspaces_key(&mut self, dir: &Path) {
        let Some(st) = jv::read_file(&dir.join("package.json")) else { return };
        // jq -e: only the final result determines truth, and parse errors win.
        if !st.failed && matches!(st.values.last(), Some(Value::Obj(o)) if o.iter().any(|(k,_)| k == b"workspaces")) {
            self.say(cat(&[sh::bytes(dir), b"/package.json has the key workspaces"]));
        }
    }
    pub fn restore(&mut self, src: &Path, dst: &Path) {
        if sh::exists(dst) && !sh::is_link(dst) && !sh::is_file(dst) {
            self.say(cat(&[b"not restored ", sh::bytes(dst), b": ", sh::bytes(dst), b" exists and is not a regular file"])); return;
        }
        self.changed += 1;
        let result = sh::copy_file(src, dst);
        if sh::same_bytes(src, dst) { self.say(cat(&[b"restored ", sh::bytes(dst)])); }
        else { self.say(cat(&[b"not restored ", sh::bytes(dst), b": ", &io_outcome(b"copy", &result), b"; ", sh::bytes(dst),
            if sh::present(dst) { b" differs from the snapshot" } else { b" does not exist" }])); }
    }
    pub fn remove(&mut self, p: &Path) {
        self.changed += 1;
        let result = sh::remove_tree(p);
        if sh::present(p) { self.say(cat(&[b"not removed ", sh::bytes(p), b": ", &io_outcome(b"removal", &result), b"; ", &path(p)])); }
        else { self.say(cat(&[b"removed ", sh::bytes(p)])); }
    }
    pub fn changed_nothing(&mut self) { if self.changed == 0 { self.say(b"The rollback changed nothing."); } }
    fn unread(&mut self, meta: &Path, line: &[u8]) -> bool {
        if line != NONE && inert_unread(meta) { self.say(UNREAD); true } else { false }
    }
    pub fn inert(&mut self, home: &Path, meta: &Path, input: &[u8]) {
        match inert(meta, input) {
            Ok(line) => {
                self.say(&line);
                self.inert = if self.unread(meta, &line) { cat(&[&line, b"; ", UNREAD]) } else { line };
            }
            Err(rc) => { self.inert.clear(); inert_unsaid(home, meta, rc); }
        }
    }
    pub fn rebuild(&mut self, home: &Path, meta: &Path, input: &[u8], fact: &[u8]) {
        match inert(meta, input) {
            Err(rc) => { inert_unsaid(home, meta, rc); self.say(cat(&[b"safedeps ", fact])); }
            Ok(line) if line == ADDED => { self.say(cat(&[&line, b" and ", fact])); self.unread(meta, &line); }
            Ok(line) => { self.say(&line); self.unread(meta, &line); self.say(cat(&[b"safedeps ", fact])); }
        }
    }
}
