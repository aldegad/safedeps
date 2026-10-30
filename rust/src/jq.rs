//! JSON as jq 1.7 writes it. The bash hooks build every answer, record and
//! state file with jq, and a reader of those bytes (the engines, the other
//! hook, the batteries) reads jq's spelling: which bytes are escaped, the
//! order of an object's keys, the two-space indent. This writes the same
//! bytes, so a record written here is a record the bash hooks would have
//! written.
//!
//! - A string argument (`--arg`, `-Rs`) is bytes read as UTF-8, each invalid
//!   sequence one U+FFFD, cut where jq's own decoder cuts it
//!   (`jvp_utf8_next`), which is not where Rust's lossy decoder cuts.
//! - `"` `\` and the control bytes below 0x20 are escaped (`\b \t \n \f \r`
//!   by name, the rest as `\u00xx`), and so is 0x7f. Nothing else is: `/`,
//!   `<`, `&` and every byte past ASCII go out as they are.
//! - An object keeps its keys in the order they were put in.

#[derive(Clone, Debug, PartialEq)]
pub enum J {
    Null,
    Bool(bool),
    /// A number as its literal: jq 1.7 prints back the literal it read.
    Num(String),
    Str(String),
    Arr(Vec<J>),
    Obj(Vec<(String, J)>),
}

pub static NULL: crate::json::Value = crate::json::Value::Null;

/// jq's string-key lookup. An absent object key and null produce null;
/// indexing a scalar or array with a string is an error, including before //.
pub fn field<'a>(v: &'a crate::json::Value, key: &str) -> Result<&'a crate::json::Value, ()> {
    use crate::json::Value;
    match v {
        Value::Null => Ok(&NULL),
        Value::Obj(_) => Ok(v.get(key).unwrap_or(&NULL)),
        _ => Err(()),
    }
}

pub fn path<'a>(mut v: &'a crate::json::Value, keys: &[&str]) -> Result<&'a crate::json::Value, ()> {
    for key in keys { v = field(v, key)?; }
    Ok(v)
}

/// $(jq -r '.path // empty'): evaluate the whole JSON stream, preserve the
/// last filter result's status, then capture stdout once. Newlines inside an
/// earlier value must not be trimmed before joining the following values.
pub fn capture_field(stream: &crate::json::Stream, keys: &[&str]) -> Result<Vec<u8>, i32> {
    use crate::json::{self, Value};
    let (lines, rc) = json::each(stream, |v| Ok(match path(v, keys)? {
        Value::Null | Value::Bool(false) => Vec::new(),
        Value::Str(s) => vec![s.clone()],
        value => vec![pretty(&from_value(value)).into_bytes()],
    }));
    if rc == 0 { Ok(json::captured(&lines)) } else { Err(rc) }
}

/// jq -e 'has("key")' with stdout/stderr discarded. The final value's
/// result controls success; a parse failure always fails the invocation.
pub fn stream_has(stream: &crate::json::Stream, key: &str) -> bool {
    use crate::json::{self, Value};
    let (lines, rc) = json::each(stream, |v| match v {
        Value::Obj(_) | Value::Null => Ok(vec![if v.get(key).is_some() { b"true".to_vec() } else { b"false".to_vec() }]),
        _ => Err(()),
    });
    rc == 0 && lines.last().is_some_and(|s| s == b"true")
}

/// jq's UTF-8 decoder: the next codepoint (or None for an invalid sequence)
/// and how many bytes it took.
fn utf8_next(b: &[u8]) -> (Option<u32>, usize) {
    let first = b[0];
    if first & 0x80 == 0 {
        return (Some(first as u32), 1);
    }
    let length = match first {
        0x80..=0xbf => return (None, 1),
        0xc0 | 0xc1 => return (None, 1),
        0xc2..=0xdf => 2,
        0xe0..=0xef => 3,
        0xf0..=0xf4 => 4,
        _ => return (None, 1),
    };
    if length > b.len() {
        return (None, b.len());
    }
    let bits = match length {
        2 => 0x1f,
        3 => 0x0f,
        _ => 0x07,
    };
    let mut cp: i64 = (first & bits) as i64;
    let mut used = length;
    for (i, &ch) in b.iter().enumerate().take(length).skip(1) {
        if ch & 0xc0 != 0x80 {
            cp = -1;
            used = i;
            break;
        }
        cp = (cp << 6) | (ch & 0x3f) as i64;
    }
    let firsts = [0i64, 0, 0x80, 0x800, 0x10000];
    if cp < firsts[used] {
        cp = -1;
    }
    if (0xd800..=0xdfff).contains(&cp) {
        cp = -1;
    }
    if cp > 0x10ffff {
        cp = -1;
    }
    (if cp < 0 { None } else { Some(cp as u32) }, used)
}

/// Bytes as the string jq makes of them.
pub fn text(b: &[u8]) -> String {
    let mut s = String::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        let (cp, n) = utf8_next(&b[i..]);
        s.push(cp.and_then(char::from_u32).unwrap_or('\u{fffd}'));
        i += n;
    }
    s
}

pub fn arg(b: &[u8]) -> J {
    J::Str(text(b))
}

pub fn s(v: &str) -> J {
    J::Str(v.to_string())
}

pub fn obj(pairs: Vec<(&str, J)>) -> J {
    J::Obj(pairs.into_iter().map(|(k, v)| (k.to_string(), v)).collect())
}

/// Keep the reader's values in jq's spelling, including object key order.
pub fn from_value(v: &crate::json::Value) -> J {
    use crate::json::Value;
    match v {
        Value::Null => J::Null,
        Value::Bool(b) => J::Bool(*b),
        Value::Num(n) => match n.as_str() {
            "NaN" => J::Null,
            "Infinity" => J::Num("1.7976931348623157e+308".into()),
            "-Infinity" => J::Num("-1.7976931348623157e+308".into()),
            _ => J::Num(n.clone()),
        },
        Value::Str(s) => arg(s),
        Value::Arr(a) => J::Arr(a.iter().map(from_value).collect()),
        Value::Obj(o) => J::Obj(o.iter().map(|(k, v)| (text(k), from_value(v))).collect()),
    }
}

pub fn into_value(v: J) -> crate::json::Value {
    use crate::json::Value;
    match v {
        J::Null => Value::Null,
        J::Bool(b) => Value::Bool(b),
        J::Num(n) => Value::Num(n),
        J::Str(s) => Value::Str(s.into_bytes()),
        J::Arr(a) => Value::Arr(a.into_iter().map(into_value).collect()),
        J::Obj(o) => Value::Obj(o.into_iter().map(|(k,v)| (k.into_bytes(), into_value(v))).collect()),
    }
}

fn put_str(out: &mut String, v: &str) {
    out.push('"');
    for c in v.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\u{8}' => out.push_str("\\b"),
            '\t' => out.push_str("\\t"),
            '\n' => out.push_str("\\n"),
            '\u{c}' => out.push_str("\\f"),
            '\r' => out.push_str("\\r"),
            c if (c as u32) < 0x20 || c as u32 == 0x7f => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
}

fn put(out: &mut String, v: &J, indent: Option<usize>) {
    match v {
        J::Null => out.push_str("null"),
        J::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        J::Num(n) => out.push_str(n),
        J::Str(x) => put_str(out, x),
        J::Arr(a) => {
            if a.is_empty() {
                out.push_str("[]");
                return;
            }
            out.push('[');
            for (k, x) in a.iter().enumerate() {
                if k > 0 {
                    out.push(',');
                }
                if let Some(n) = indent {
                    out.push('\n');
                    out.push_str(&" ".repeat(n + 2));
                }
                put(out, x, indent.map(|n| n + 2));
            }
            if let Some(n) = indent {
                out.push('\n');
                out.push_str(&" ".repeat(n));
            }
            out.push(']');
        }
        J::Obj(o) => {
            if o.is_empty() {
                out.push_str("{}");
                return;
            }
            out.push('{');
            for (k, (key, x)) in o.iter().enumerate() {
                if k > 0 {
                    out.push(',');
                }
                if let Some(n) = indent {
                    out.push('\n');
                    out.push_str(&" ".repeat(n + 2));
                }
                put_str(out, key);
                out.push(':');
                if indent.is_some() {
                    out.push(' ');
                }
                put(out, x, indent.map(|n| n + 2));
            }
            if let Some(n) = indent {
                out.push('\n');
                out.push_str(&" ".repeat(n));
            }
            out.push('}');
        }
    }
}

/// `jq -c`.
pub fn compact(v: &J) -> String {
    let mut out = String::new();
    put(&mut out, v, None);
    out
}

/// `jq` with its default indent.
pub fn pretty(v: &J) -> String {
    let mut out = String::new();
    put(&mut out, v, Some(0));
    out
}

/// The answers the hooks give the runtime are built here and nowhere else:
/// the PreToolUse deny with its reason, the PreToolUse allow that rewrites
/// the command (`updatedInput`, which only Claude Code reads), and the
/// PostToolUse message the user sees. A reason, a command or a message is
/// bytes, written as jq's `--arg` writes them.
fn pre_tool_use(fields: Vec<(&str, J)>) -> String {
    let mut answer = vec![("hookEventName", s("PreToolUse"))];
    answer.extend(fields);
    compact(&obj(vec![("hookSpecificOutput", obj(answer))]))
}

/// The PreToolUse answer every deny has: `jq -nc '{hookSpecificOutput:{...}}'`.
pub fn deny(reason: impl AsRef<[u8]>) -> String {
    pre_tool_use(vec![("permissionDecision", s("deny")), ("permissionDecisionReason", arg(reason.as_ref()))])
}

/// The PreToolUse answer that runs `command` in place of the one given.
pub fn allow_rewrite(command: &[u8]) -> String {
    pre_tool_use(vec![("permissionDecision", s("allow")), ("updatedInput", obj(vec![("command", arg(command))]))])
}

/// The PostToolUse answer that shows the user `message`.
pub fn system_message(message: &[u8]) -> String {
    compact(&obj(vec![("systemMessage", arg(message))]))
}

/// The runtimes read these bytes, so the event name and the key order are
/// part of the answer, and a reason that is not UTF-8 is written as `--arg`
/// writes it (jq 1.7.1, measured): jq reads a cut sequence as one U+FFFD
/// where Rust's lossy decoder writes one per byte, reads an overlong one as
/// one, takes the byte after a sequence cut at the end into it, and writes
/// one per stray byte. No line of a source file outside this one and the
/// `*_tests.rs` files, `//` comment lines aside, spells an answer's keys, in
/// any quoting.
#[cfg(test)]
#[test]
fn hook_answers_are_pinned() {
    assert_eq!(deny("no \"x\"\n"), r#"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"no \"x\"\n"}}"#);
    assert_eq!(deny(b"a\xffb".as_slice()), "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"a\u{fffd}b\"}}");
    assert_eq!(deny(b"a\xe0\x80b".as_slice()), "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"a\u{fffd}b\"}}");
    assert_eq!(allow_rewrite(b"npm i --ignore-scripts"), r#"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"command":"npm i --ignore-scripts"}}}"#);
    assert_eq!(allow_rewrite(b"npm i a\xf0\x80\x80b"), "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"allow\",\"updatedInput\":{\"command\":\"npm i a\u{fffd}b\"}}}");
    assert_eq!(system_message(b"rolled back\n\tx\xc3"), "{\"systemMessage\":\"rolled back\\n\\tx\u{fffd}\"}");
    assert_eq!(system_message(b"a\xed\xa0\x80b"), "{\"systemMessage\":\"a\u{fffd}b\"}");
    assert_eq!(deny(b"a\xe0\x80\x80b".as_slice()), "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"a\u{fffd}b\"}}");
    assert_eq!(deny(b"a\xe0\x80".as_slice()), "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"a\u{fffd}\"}}");
    assert_eq!(system_message(b"x\xf0A"), "{\"systemMessage\":\"x\u{fffd}\"}");
    assert_eq!(allow_rewrite(b"a\xff\xffb"), "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"allow\",\"updatedInput\":{\"command\":\"a\u{fffd}\u{fffd}b\"}}}");
    fn sources(dir: &std::path::Path, out: &mut Vec<(String, String)>) {
        for entry in std::fs::read_dir(dir).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() { sources(&path, out) }
            else if path.extension().is_some_and(|e| e == "rs") { out.push((path.display().to_string(), std::fs::read_to_string(&path).unwrap())) }
        }
    }
    let mut files = Vec::new();
    sources(&std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src"), &mut files);
    assert!(files.len() > 40, "the walk found the core's sources");
    for (file, text) in files.iter().filter(|(f, _)| !f.ends_with("/src/jq.rs") && !f.ends_with("_tests.rs")) {
        for line in text.lines().filter(|l| !l.trim_start().starts_with("//")) {
            for key in ["hookSpecificOutput", "hookEventName", "permissionDecision", "updatedInput", "systemMessage"] {
                assert!(!line.contains(key), "{file} spells {key}: the answer is built in jq.rs: {line}");
            }
        }
    }
}
