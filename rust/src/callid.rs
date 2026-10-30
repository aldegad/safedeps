//! Which tool call a hook input belongs to. Both halves of the core read it
//! with this, so the pre hook and the post hook of one call name its files the
//! same way. It carries over `safedeps_call_id` and `safedeps_call_base` of
//! the Bash hooks (lib/gates/call-id.sh, deleted with them).

use crate::{jq, json::{self, Value}};

fn plain(id: &[u8]) -> bool {
    !id.is_empty() && id.len() <= 128 && id.iter().all(|b| b.is_ascii_alphanumeric() || *b == b'_' || *b == b'-')
}

/// `safedeps_call_id <hook input>`: the top-level `tool_use_id` when it is a
/// string and a plain word (`^[A-Za-z0-9_-]{1,128}$`). A file is named after
/// it, so a word with a slash or a dot in it names no call.
///
/// The shell reads it through `$(jq -r ...)`, which drops NUL bytes and the
/// newlines that end the output before the test, so they are dropped here.
/// Multiple values can emit one id, no id, or multiple lines; only the
/// captured result is validated.
pub fn from_stream(input: &json::Stream) -> Option<String> {
    let (lines, rc) = json::each(input, |v| Ok(match jq::field(v, "tool_use_id")? {
        Value::Str(raw) => vec![raw.clone()],
        _ => Vec::new(),
    }));
    if rc != 0 { return None }
    validated(json::captured(&lines))
}

fn validated(id: Vec<u8>) -> Option<String> {
    if !plain(&id) {
        return None;
    }
    String::from_utf8(id).ok()
}

/// `safedeps_call_base <dir> <id>`: the files of one call in `<dir>`, without
/// an extension.
pub fn call_base(dir: &str, id: &str) -> Option<String> {
    if !plain(id.as_bytes()) {
        return None;
    }
    Some(format!("{}/id-{}", dir, id))
}

/// The names in the two files the pre hook leaves for the post hook of one
/// call: the install record (`pre/pending.rs`, read by `post/call.rs`,
/// `post/trace.rs`, `post/run.rs` and `post/npm.rs`) and the backstop's trace
/// entry (`pre.rs`, read by `post/call.rs`, `post/trace.rs` and
/// `post/rollback.rs`). Only the
/// names are shared: each reader keeps its own answer for a field that is
/// missing or of another type. The hook input's own `tool_use_id`, read
/// above, is the runtime's name, not one of these.
pub mod record {
    pub const SNAPSHOT_ID: &str = "snapshot_id";
    pub const PROJECT_DIR: &str = "project_dir";
    pub const DIR_HASH: &str = "dir_hash";
    pub const PROJECT_DIR_FROM: &str = "project_dir_from";
    pub const NPM_INSTALL: &str = "npm_install";
    pub const RUNNER_ONLY: &str = "runner_only";
    pub const NPM_TRACE: &str = "npm_trace";
    pub const NPM_UNATTRIBUTABLE: &str = "npm_unattributable";
    pub const NPM_FETCH: &str = "npm_fetch";
    pub const TOOL_USE_ID: &str = "tool_use_id";
    pub const ACCEPT_RISK: &str = "accept_risk";
    /// In the install record's `npm_trace`, and in the backstop entry.
    pub const BASELINE: &str = "baseline";
    pub const INODES: &str = "inodes";
    /// The backstop entry's own.
    pub const KEY: &str = "key";
    pub const RESOLUTION: &str = "resolution";
    pub const CLOCKS: &str = "clocks";
    pub const ENTRIES: &str = "entries";
    /// The values of `resolution`: whether the clocks the entry was taken
    /// against hold fractions of a second.
    pub const SECONDS: &str = "seconds";
    pub const SUBSECOND: &str = "subsecond";
    /// The two npm records, under which `inodes` and `clocks` are kept, and
    /// the tree, whose inode the backstop entry also keeps.
    pub const RECORDS: [&str; 2] = ["package-lock.json", "node_modules/.package-lock.json"];
    pub const TREE: &str = "node_modules";
}

/// The files that write or read the two records spell none of their names
/// again: a writer that types a key its reader looks up by the constant, or
/// the reverse, is a second spelling no compiler sees. Three names are left
/// out: `tool_use_id`, which is also the runtime's name and the accepted-risk
/// entry's, and the project's `package-lock.json` and `node_modules`, which
/// these files also join as paths to walk, restore and report. pre/snapshot.rs
/// reads a probe's own input under some of the same names, so it is held to
/// the tree record's name alone. This sees a declared name spelled again,
/// not a new literal that misspells one: those are what the batteries that
/// read the records see.
#[cfg(test)]
#[test]
fn record_names_are_spelled_once() {
    let names = [record::SNAPSHOT_ID, record::PROJECT_DIR, record::DIR_HASH, record::PROJECT_DIR_FROM, record::NPM_INSTALL,
        record::RUNNER_ONLY, record::NPM_TRACE, record::NPM_UNATTRIBUTABLE, record::NPM_FETCH, record::ACCEPT_RISK,
        record::BASELINE, record::INODES, record::KEY, record::RESOLUTION, record::CLOCKS, record::ENTRIES,
        record::SECONDS, record::SUBSECOND, record::RECORDS[1]];
    for (file, text) in [("pre/pending.rs", include_str!("pre/pending.rs")), ("pre.rs", include_str!("pre.rs")),
                         ("post/call.rs", include_str!("post/call.rs")), ("post/trace.rs", include_str!("post/trace.rs")),
                         ("post/run.rs", include_str!("post/run.rs")), ("post/npm.rs", include_str!("post/npm.rs")),
                         ("post/rollback.rs", include_str!("post/rollback.rs")), ("post/tree.rs", include_str!("post/tree.rs"))] {
        for name in names {
            let quoted = format!("\"{name}\"");
            let lines: Vec<&str> = text.lines().filter(|line| line.contains(&quoted)).collect();
            assert!(lines.is_empty(), "{file} spells {quoted} outside callid::record: {lines:?}");
        }
    }
    let quoted = format!("\"{}\"", record::RECORDS[1]);
    assert!(!include_str!("pre/snapshot.rs").contains(&quoted), "pre/snapshot.rs spells {quoted} outside callid::record");
}
