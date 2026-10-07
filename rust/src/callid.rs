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
pub fn call_id(input: &Value) -> Option<String> {
    let Value::Str(raw) = input.get("tool_use_id")? else { return None };
    validated(json::captured(&[raw.clone()]))
}

/// The same filter over a hook's JSON stream. Multiple values can emit one
/// id, no id, or multiple lines; only the captured result is validated.
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
