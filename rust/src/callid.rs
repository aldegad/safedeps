//! Which tool call a hook input belongs to (lib/gates/call-id.sh). Both hooks
//! read it with this, so the pre-guard and the post hook of one call name its
//! files the same way.

use crate::json::Value;

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
    let mut id: Vec<u8> = raw.iter().copied().filter(|&b| b != 0).collect();
    while id.last() == Some(&b'\n') {
        id.pop();
    }
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
