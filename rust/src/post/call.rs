//! Consume only this call's trace entry or pending record, while state.lock
//! is held. A trace entry owns the call even when its content is unreadable.
use super::{jv, sh, report::cat, snapshot::{self, Store}, trace};
use crate::{callid, ere::Regex, grammar, json::Value, md5, os, state};
use std::{fs, path::{Path, PathBuf}};
type W = Vec<u8>;

#[derive(Clone, Copy, PartialEq)]
pub enum Record { Install, Missing, Unread, Empty, Gone }
impl Record {
    pub fn clause(self) -> &'static [u8] {
        match self {
            Self::Gone => b"this hook found a pre-guard record, and the snapshot it names has no meta file",
            Self::Empty => b"this hook found a pre-guard record, and the record names no snapshot",
            Self::Unread => b"this hook found a pre-guard record, and the record is not one JSON object",
            _ => b"this hook found no record of this command from before it ran",
        }
    }
    pub fn subject(self) -> &'static [u8] {
        match self {
            Self::Gone => b"a command whose pre-guard record names a snapshot with no meta file",
            Self::Empty => b"a command whose pre-guard record names no snapshot",
            Self::Unread => b"a command with a pre-guard record that is not one JSON object",
            _ => b"install-looking command with no pending state",
        }
    }
}
pub struct Call {
    pub store: Store, pub current: Value, pub command: W, pub codex: bool,
    pub record: Record, pub entry: W, pub trace_none: W,
}
fn field(st: &jv::Stream, path: &[&str]) -> Result<W, i32> {
    let (lines, rc) = jv::each(st, |v| {
        let f = jv::path(v, path)?;
        Ok(if jv::truthy(f) { vec![jv::tostring(f)] } else { Vec::new() })
    });
    if rc == 0 { Ok(jv::captured(&lines)) } else { Err(rc) }
}
fn string(v: &Value, key: &str) -> W {
    jv::field(v, key).ok().and_then(jv::text).map(|s| jv::captured(&[s.to_vec()])).unwrap_or_default()
}
fn call_base(dir: &Path, id: &str) -> PathBuf { dir.join(format!("id-{}", id)) }

impl Call {
    pub fn take(home: &Path, input: &[u8]) -> Result<Option<Self>, i32> {
        let st = jv::read(input);
        if field(&st, &["tool_name"])? != b"Bash" { return Ok(None) }
        let command = field(&st, &["tool_input", "command"])?;
        let mut cwd = field(&st, &["cwd"])?;
        if cwd.is_empty() { cwd = sh::bytes(&std::env::current_dir().map_err(|_| 1)?).to_vec(); }
        let cwd = sh::p(&os::realpath(&cwd));
        let hash = md5::hex(sh::bytes(&cwd));
        let key = state::pending_key(&hash, &command);
        let id = if st.values.len() == 1 { callid::call_id(&st.values[0]) } else { None };
        let codex = st.values.last().is_some_and(|v| v.get("turn_id").is_some());
        // acquire() already reports the lock failure. The hook then exits 0.
        let Ok(lock) = snapshot::acquire(home) else { return Ok(None) };
        let mut entry = Vec::new();
        let mut found = false;
        let mut trace_none = b"the pre-guard left no trace entry for this call".to_vec();
        if let Some(id) = &id {
            let base = call_base(&home.join("pending/backstop"), id);
            let file = base.with_extension("json");
            if sh::is_file(&file) {
                found = true;
                entry = sh::cat_captured(&file).unwrap_or_default();
                sh::rm_f(&file);
                if entry.is_empty() {
                    trace_none = b"the trace entry for this call could not be read".to_vec();
                    sh::rm_f(&base.with_extension("trace"));
                } else if field(&jv::read(&entry), &["key"]).unwrap_or_default() != key.as_bytes() {
                    trace_none = b"the trace entry for this call was taken for another directory or command".to_vec();
                    sh::rm_f(&base.with_extension("trace"));
                    entry.clear();
                }
            }
        } else { trace_none = b"this hook's input names no tool_use_id, so no trace entry belongs to this call".to_vec(); }

        let pending = if found { None } else if let Some(id) = &id {
            let p = call_base(&home.join("pending"), id).with_extension("json");
            sh::is_file(&p).then_some(p)
        } else {
            let prefix = format!("{}__", key).into_bytes();
            let mut files: Vec<_> = fs::read_dir(home.join("pending")).into_iter().flatten().filter_map(Result::ok)
                .map(|e| e.path()).filter(|p| {
                    let name = sh::basename(sh::bytes(p));
                    name.starts_with(&prefix) && name.ends_with(b".json") && sh::is_file(p)
                }).collect();
            files.sort();
            let p = files.into_iter().next();
            if let Some(p) = &p {
                state::log_advisory(home, &cat(&[b"post-verify: this hook's input names no tool_use_id, so it took the record ", sh::bytes(p), b" by the directory and the command, and another call of the same command in the same directory can have written it"]));
            }
            p
        };
        let mut current = Value::Null;
        let mut record = Record::Missing;
        let mut snapshot_id = Vec::new();
        let mut project = cwd;
        if let Some(p) = &pending {
            if let Some(value) = jv::read_one_object(p) {
                snapshot_id = string(&value, "snapshot_id");
                let dir = string(&value, "project_dir");
                if !dir.is_empty() { project = sh::p(&dir); }
                current = value;
                record = Record::Install;
            } else {
                record = Record::Unread;
                state::log_advisory(home, &cat(&[b"post-verify: the pre-guard's record ", sh::bytes(p), b" is not one JSON object; this hook set the record aside"]));
            }
            sh::rm_f(p);
            if record == Record::Install && snapshot_id.is_empty() {
                state::log_advisory(home, &cat(&[b"post-verify: the pre-guard's record ", sh::bytes(p), b" names no snapshot; this hook set the record aside, and the command goes to the command-independent backstop"]));
                record = Record::Empty;
            }
        } else if !found && Regex::new(&grammar::patterns().backstop_re, true).map_err(|_| 1)?.grep_lines(&command).is_empty() {
            return Ok(None)
        }
        drop(lock);
        let mut store = Store::new(home.into(), project, snapshot_id);
        if record == Record::Install && !sh::is_file(&store.meta()) {
            state::log_advisory(home, &cat(&[b"post-verify: the pre-guard's record ", sh::bytes(pending.as_ref().unwrap()), b" names the snapshot ", &store.id, b", and ", sh::bytes(&store.meta()), b" is not a file; this hook set the record aside, and the command goes to the command-independent backstop"]));
            record = Record::Gone;
            store.id.clear();
        }
        if matches!(record, Record::Unread | Record::Empty | Record::Gone) {
            trace_none = cat(&[b"the command reached the backstop through a pre-guard record, and ", &trace_none]);
        }
        Ok(Some(Self { store, current, command, codex, record, entry, trace_none }))
    }
    pub fn backstop_trace(&self) -> bool {
        let home = &self.store.home;
        let (traced, line) = trace::backstop(&self.store.project, &self.entry, &self.trace_none);
        trace::drop_baseline(home, &self.entry);
        let line = if traced { cat(&[b"post-verify BACKSTOP traced: ", &line, b". Command: ", &self.command]) }
            else { cat(&[b"post-verify BACKSTOP UNTRACED: ", &line, b". No closure check ran and nothing was rolled back. Command: ", &self.command]) };
        state::log_advisory(home, &line);
        traced
    }
}
