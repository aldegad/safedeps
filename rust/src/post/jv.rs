//! JSON as jq reads it, and the orders and spellings jq gives values.
//!
//! The bash post hook reads every file and every payload with jq, and what it
//! does next turns on jq's answer: whether a file is JSON at all, how many
//! texts it holds, which of two records sorts first, how a number is spelled
//! in a message. So this reads the way jq 1.7.1 does, measured on the test
//! hosts (scripts/measure/core-post-jq.sh holds each rule to the host's jq):
//!
//! - An input is a stream of JSON texts. A text jq cannot parse stops the
//!   reading there, with the texts before it already read.
//! - jq is stricter than a lenient reader in the places that matter to a gate:
//!   a control byte in a string, a literal that is not one (`truex`, `0x10`),
//!   a high surrogate with no low one, a trailing comma, and nesting past 256
//!   open values are each no JSON. A lockfile that is no JSON is a finding, so
//!   a reader that took one of these would pass what the bash hook rolls back.
//!   Where this reader is stricter than jq (a record separator byte, which jq
//!   reads as a boundary between texts), it errs to the finding.
//! - A key given twice keeps its first place and its last value.
//! - A number keeps the spelling decNumber gives its literal (`1.0`, `1.50`,
//!   `1E+2`, `7` for `007`), and compares by its value.
//! - Values order as jq orders them: null, false, true, numbers, strings by
//!   byte, arrays, objects (by their sorted keys, then by value).

use crate::json::Value;
use std::cmp::Ordering;

pub static NULL: Value = Value::Null;

/// The JSON texts of one input, in order. `failed` when the reading stopped at
/// a text jq cannot parse: jq prints what it read before that and exits 5.
pub struct Stream {
    pub values: Vec<Value>,
    pub failed: bool,
}

enum Frame {
    Arr(Vec<Value>),
    Obj(Vec<(Vec<u8>, Value)>),
    Key(Vec<u8>),
}

#[derive(PartialEq)]
enum St {
    Normal,
    Str,
    Esc,
}

/// jq's MAX_PARSING_DEPTH: open arrays and objects, and a key waiting for its
/// value, each take one place (measured: 256 nested arrays parse and 257 do
/// not; 128 nested objects parse and 129 do not).
const MAX_DEPTH: usize = 256;

struct Parser {
    stack: Vec<Frame>,
    next: Option<Value>,
    tok: Vec<u8>,
    st: St,
}

/// `object[key] = value` as jq's parser sets it.
pub fn set(o: &mut Vec<(Vec<u8>, Value)>, k: Vec<u8>, v: Value) {
    match o.iter_mut().find(|(kk, _)| *kk == k) {
        Some(slot) => slot.1 = v,
        None => o.push((k, v)),
    }
}

/// A number literal as decNumber spells it back (its to-scientific-string),
/// or None for a token that is no number.
fn number(t: &[u8]) -> Option<String> {
    let s = std::str::from_utf8(t).ok()?;
    let (neg, body) = match *s.as_bytes().first()? {
        b'-' => (true, &s[1..]),
        b'+' => (false, &s[1..]),
        _ => (false, s),
    };
    let low = body.to_ascii_lowercase();
    if low == "nan" {
        return Some("NaN".to_string());
    }
    if low == "inf" || low == "infinity" {
        return Some(if neg { "-Infinity" } else { "Infinity" }.to_string());
    }
    let b = body.as_bytes();
    let mut i = 0;
    while i < b.len() && b[i].is_ascii_digit() {
        i += 1;
    }
    let int = &body[..i];
    let mut frac = "";
    if i < b.len() && b[i] == b'.' {
        let st = i + 1;
        i = st;
        while i < b.len() && b[i].is_ascii_digit() {
            i += 1;
        }
        frac = &body[st..i];
    }
    if int.is_empty() && frac.is_empty() {
        return None;
    }
    let mut exp: i64 = 0;
    if i < b.len() && (b[i] == b'e' || b[i] == b'E') {
        i += 1;
        let mut eneg = false;
        if i < b.len() && (b[i] == b'+' || b[i] == b'-') {
            eneg = b[i] == b'-';
            i += 1;
        }
        let st = i;
        while i < b.len() && b[i].is_ascii_digit() {
            i += 1;
        }
        if st == i || i - st > 9 {
            return None;
        }
        exp = body[st..i].parse::<i64>().ok()?;
        if eneg {
            exp = -exp;
        }
    }
    if i != b.len() {
        return None;
    }
    let all = format!("{}{}", int, frac);
    let e = exp - frac.len() as i64;
    let trimmed = all.trim_start_matches('0');
    let digits = if trimmed.is_empty() { "0" } else { trimmed };
    let n = digits.len() as i64;
    let adj = e + n - 1;
    let mut out = String::new();
    if neg {
        out.push('-');
    }
    if e <= 0 && adj >= -6 {
        if e == 0 {
            out.push_str(digits);
        } else if n > -e {
            let k = (n + e) as usize;
            out.push_str(&digits[..k]);
            out.push('.');
            out.push_str(&digits[k..]);
        } else {
            out.push_str("0.");
            for _ in 0..(-e - n) {
                out.push('0');
            }
            out.push_str(digits);
        }
    } else {
        out.push_str(&digits[..1]);
        if n > 1 {
            out.push('.');
            out.push_str(&digits[1..]);
        }
        out.push('E');
        out.push(if adj < 0 { '-' } else { '+' });
        out.push_str(&adj.abs().to_string());
    }
    Some(out)
}

fn hex4(t: &[u8], i: usize) -> Result<u32, ()> {
    let h = t.get(i..i + 4).ok_or(())?;
    if !h.iter().all(|b| b.is_ascii_hexdigit()) {
        return Err(());
    }
    u32::from_str_radix(std::str::from_utf8(h).map_err(|_| ())?, 16).map_err(|_| ())
}

impl Parser {
    fn push(&mut self, f: Frame) -> Result<(), ()> {
        if self.stack.len() >= MAX_DEPTH {
            return Err(());
        }
        self.stack.push(f);
        Ok(())
    }

    fn value(&mut self, v: Value) -> Result<(), ()> {
        if self.next.is_some() {
            return Err(());
        }
        self.next = Some(v);
        Ok(())
    }

    fn done(&mut self, out: &mut Vec<Value>) {
        if self.stack.is_empty() {
            if let Some(v) = self.next.take() {
                out.push(v);
            }
        }
    }

    fn literal(&mut self, out: &mut Vec<Value>) -> Result<(), ()> {
        if self.tok.is_empty() {
            return Ok(());
        }
        let t = std::mem::take(&mut self.tok);
        let v = match t[0] {
            b't' if t == b"true" => Value::Bool(true),
            b'f' if t == b"false" => Value::Bool(false),
            b't' | b'f' | b'\'' => return Err(()),
            // A word of three letters that starts with n can be `nan`.
            b'n' if t.len() != 3 => {
                if t != b"null" {
                    return Err(());
                }
                Value::Null
            }
            _ => Value::Num(number(&t).ok_or(())?),
        };
        self.value(v)?;
        self.done(out);
        Ok(())
    }

    fn string(&mut self) -> Result<Value, ()> {
        let t = std::mem::take(&mut self.tok);
        let mut o: Vec<u8> = Vec::with_capacity(t.len());
        let mut i = 0;
        while i < t.len() {
            let c = t[i];
            i += 1;
            if c != b'\\' {
                if c < 0x20 {
                    return Err(());
                }
                o.push(c);
                continue;
            }
            let e = *t.get(i).ok_or(())?;
            i += 1;
            match e {
                b'"' | b'\\' | b'/' => o.push(e),
                b'b' => o.push(8),
                b'f' => o.push(12),
                b'n' => o.push(b'\n'),
                b'r' => o.push(b'\r'),
                b't' => o.push(b'\t'),
                b'u' => {
                    let mut cp = hex4(&t, i)?;
                    i += 4;
                    if (0xd800..0xdc00).contains(&cp) {
                        if t.get(i) != Some(&b'\\') || t.get(i + 1) != Some(&b'u') {
                            return Err(());
                        }
                        let lo = hex4(&t, i + 2)?;
                        if !(0xdc00..0xe000).contains(&lo) {
                            return Err(());
                        }
                        i += 6;
                        cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00);
                    }
                    let ch = char::from_u32(cp).unwrap_or('\u{fffd}');
                    let mut b = [0u8; 4];
                    o.extend_from_slice(ch.encode_utf8(&mut b).as_bytes());
                }
                _ => return Err(()),
            }
        }
        // jq keeps a string as valid UTF-8: each invalid sequence is U+FFFD.
        Ok(Value::Str(crate::jq::text(&o).into_bytes()))
    }

    fn token(&mut self, ch: u8) -> Result<(), ()> {
        match ch {
            b'[' => {
                if self.next.is_some() {
                    return Err(());
                }
                self.push(Frame::Arr(Vec::new()))
            }
            b'{' => {
                if self.next.is_some() {
                    return Err(());
                }
                self.push(Frame::Obj(Vec::new()))
            }
            b':' => {
                if !matches!(self.stack.last(), Some(Frame::Obj(_))) {
                    return Err(());
                }
                match self.next.take() {
                    Some(Value::Str(k)) => self.push(Frame::Key(k)),
                    _ => Err(()),
                }
            }
            b',' => {
                let v = self.next.take().ok_or(())?;
                match self.stack.pop() {
                    Some(Frame::Arr(mut a)) => {
                        a.push(v);
                        self.stack.push(Frame::Arr(a));
                        Ok(())
                    }
                    Some(Frame::Key(k)) => match self.stack.last_mut() {
                        Some(Frame::Obj(o)) => {
                            set(o, k, v);
                            Ok(())
                        }
                        _ => Err(()),
                    },
                    _ => Err(()),
                }
            }
            b']' => {
                let Some(Frame::Arr(mut a)) = self.stack.pop() else { return Err(()) };
                match self.next.take() {
                    Some(v) => a.push(v),
                    None => {
                        if !a.is_empty() {
                            return Err(());
                        }
                    }
                }
                self.next = Some(Value::Arr(a));
                Ok(())
            }
            _ => {
                if let Some(v) = self.next.take() {
                    let Some(Frame::Key(k)) = self.stack.pop() else { return Err(()) };
                    match self.stack.last_mut() {
                        Some(Frame::Obj(o)) => set(o, k, v),
                        _ => return Err(()),
                    }
                } else if let Some(Frame::Obj(o)) = self.stack.last() {
                    if !o.is_empty() {
                        return Err(());
                    }
                }
                let Some(Frame::Obj(o)) = self.stack.pop() else { return Err(()) };
                self.next = Some(Value::Obj(o));
                Ok(())
            }
        }
    }

    fn scan(&mut self, ch: u8, out: &mut Vec<Value>) -> Result<(), ()> {
        match self.st {
            St::Normal => {
                match ch {
                    // jq reads a record separator as a boundary and drops what
                    // it was reading; here it is no JSON.
                    0x1e => return Err(()),
                    b' ' | b'\t' | b'\r' | b'\n' => self.literal(out)?,
                    b'"' => {
                        self.literal(out)?;
                        self.st = St::Str;
                    }
                    b'[' | b',' | b']' | b'{' | b':' | b'}' => {
                        self.literal(out)?;
                        self.token(ch)?;
                    }
                    _ => self.tok.push(ch),
                }
                self.done(out);
            }
            St::Str => match ch {
                0x1e => return Err(()),
                b'"' => {
                    let s = self.string()?;
                    self.value(s)?;
                    self.st = St::Normal;
                    self.done(out);
                }
                b'\\' => {
                    self.tok.push(ch);
                    self.st = St::Esc;
                }
                _ => self.tok.push(ch),
            },
            St::Esc => {
                self.tok.push(ch);
                self.st = St::Str;
            }
        }
        Ok(())
    }
}

/// Every JSON text in `s`.
pub fn read(s: &[u8]) -> Stream {
    let mut values = Vec::new();
    let body = if s.first() == Some(&0xef) {
        // jq strips a byte order mark and refuses half of one.
        if s.starts_with(&[0xef, 0xbb, 0xbf]) {
            &s[3..]
        } else {
            return Stream { values, failed: true };
        }
    } else {
        s
    };
    let mut p = Parser { stack: Vec::new(), next: None, tok: Vec::new(), st: St::Normal };
    for &ch in body {
        if p.scan(ch, &mut values).is_err() {
            return Stream { values, failed: true };
        }
    }
    let failed = p.st != St::Normal || p.literal(&mut values).is_err() || !p.stack.is_empty();
    Stream { values, failed }
}

/// Every JSON text in a file, or None when the file cannot be opened (jq
/// says so and exits 2).
pub fn read_file(path: &std::path::Path) -> Option<Stream> {
    std::fs::read(path).ok().map(|b| read(&b))
}

/// A file that holds exactly one JSON text, which is an object: what
/// `jq --slurp 'if length == 1 and (.[0] | type) == "object" ...'` lets
/// through.
pub fn read_one_object(path: &std::path::Path) -> Option<Value> {
    let st = read_file(path)?;
    if st.failed || st.values.len() != 1 {
        return None;
    }
    match st.values.into_iter().next() {
        Some(v @ Value::Obj(_)) => Some(v),
        _ => None,
    }
}

/// What a shell's `$(...)` keeps of a command's output: no NUL byte, and none
/// of the newlines that end it.
pub fn captured(lines: &[Vec<u8>]) -> Vec<u8> {
    let mut out: Vec<u8> = Vec::new();
    for l in lines {
        out.extend(l.iter().copied().filter(|&b| b != 0));
        out.push(b'\n');
    }
    while out.last() == Some(&b'\n') {
        out.pop();
    }
    out
}

/// One filter over every text of a stream, as `jq -r` runs it: the lines of
/// every text that did not fail, and jq's exit status, which is the last
/// text's (5 for a filter that failed on it, and for a stream that stopped at
/// a text jq cannot parse).
pub fn each<F>(st: &Stream, mut f: F) -> (Vec<Vec<u8>>, i32)
where
    F: FnMut(&Value) -> Result<Vec<Vec<u8>>, ()>,
{
    let mut out = Vec::new();
    let mut rc = 0;
    for v in &st.values {
        match f(v) {
            Ok(mut lines) => {
                out.append(&mut lines);
                rc = 0;
            }
            Err(()) => rc = 5,
        }
    }
    if st.failed {
        rc = 5;
    }
    (out, rc)
}

pub fn type_name(v: &Value) -> &'static str {
    match v {
        Value::Null => "null",
        Value::Bool(_) => "boolean",
        Value::Num(_) => "number",
        Value::Str(_) => "string",
        Value::Arr(_) => "array",
        Value::Obj(_) => "object",
    }
}

/// `.key`: null of null, the value or null of an object, and an error of
/// anything else. jq's `//` does not catch that error (measured).
pub fn field<'a>(v: &'a Value, k: &str) -> Result<&'a Value, ()> {
    match v {
        Value::Null => Ok(&NULL),
        Value::Obj(o) => Ok(o.iter().find(|(kk, _)| kk.as_slice() == k.as_bytes()).map(|(_, x)| x).unwrap_or(&NULL)),
        _ => Err(()),
    }
}

/// `.[key]` with a key that is bytes.
pub fn field_bytes<'a>(v: &'a Value, k: &[u8]) -> Result<&'a Value, ()> {
    match v {
        Value::Null => Ok(&NULL),
        Value::Obj(o) => Ok(o.iter().find(|(kk, _)| kk.as_slice() == k).map(|(_, x)| x).unwrap_or(&NULL)),
        _ => Err(()),
    }
}

/// A path of keys, each read with `field`.
pub fn path<'a>(v: &'a Value, keys: &[&str]) -> Result<&'a Value, ()> {
    let mut cur = v;
    for k in keys {
        cur = field(cur, k)?;
    }
    Ok(cur)
}

/// Neither null nor false: what `//`, `select` and `if` take as true.
pub fn truthy(v: &Value) -> bool {
    !matches!(v, Value::Null | Value::Bool(false))
}

pub fn text(v: &Value) -> Option<&[u8]> {
    match v {
        Value::Str(s) => Some(s),
        _ => None,
    }
}

pub fn s(b: &[u8]) -> Value {
    Value::Str(crate::jq::text(b).into_bytes())
}

pub fn num(n: i64) -> Value {
    Value::Num(n.to_string())
}

pub fn obj(pairs: Vec<(&str, Value)>) -> Value {
    let mut o: Vec<(Vec<u8>, Value)> = Vec::new();
    for (k, v) in pairs {
        set(&mut o, k.as_bytes().to_vec(), v);
    }
    Value::Obj(o)
}

pub fn is_nan(lit: &str) -> bool {
    lit == "NaN"
}

/// A number's value. NaN and the infinities are jq's: NaN is below every
/// number, and an infinity is the largest double.
pub fn f64_of(lit: &str) -> f64 {
    match lit {
        "NaN" => f64::NAN,
        "Infinity" => f64::MAX,
        "-Infinity" => f64::MIN,
        _ => lit.parse::<f64>().unwrap_or(f64::NAN),
    }
}

fn rank(v: &Value) -> u8 {
    match v {
        Value::Null => 0,
        Value::Bool(false) => 1,
        Value::Bool(true) => 2,
        Value::Num(_) => 3,
        Value::Str(_) => 4,
        Value::Arr(_) => 5,
        Value::Obj(_) => 6,
    }
}

fn sorted_keys(o: &[(Vec<u8>, Value)]) -> Vec<&(Vec<u8>, Value)> {
    let mut k: Vec<&(Vec<u8>, Value)> = o.iter().collect();
    k.sort_by(|a, b| a.0.cmp(&b.0));
    k
}

/// jq's order of any two values.
pub fn cmp(a: &Value, b: &Value) -> Ordering {
    let (ra, rb) = (rank(a), rank(b));
    if ra != rb {
        return ra.cmp(&rb);
    }
    match (a, b) {
        (Value::Num(x), Value::Num(y)) => {
            if is_nan(x) {
                return Ordering::Less;
            }
            if is_nan(y) {
                return Ordering::Greater;
            }
            f64_of(x).partial_cmp(&f64_of(y)).unwrap_or(Ordering::Equal)
        }
        (Value::Str(x), Value::Str(y)) => x.cmp(y),
        (Value::Arr(x), Value::Arr(y)) => {
            for (p, q) in x.iter().zip(y.iter()) {
                let c = cmp(p, q);
                if c != Ordering::Equal {
                    return c;
                }
            }
            x.len().cmp(&y.len())
        }
        (Value::Obj(x), Value::Obj(y)) => {
            let (kx, ky) = (sorted_keys(x), sorted_keys(y));
            for (p, q) in kx.iter().zip(ky.iter()) {
                let c = p.0.cmp(&q.0);
                if c != Ordering::Equal {
                    return c;
                }
            }
            if kx.len() != ky.len() {
                return kx.len().cmp(&ky.len());
            }
            for (p, q) in kx.iter().zip(ky.iter()) {
                let c = cmp(&p.1, &q.1);
                if c != Ordering::Equal {
                    return c;
                }
            }
            Ordering::Equal
        }
        _ => Ordering::Equal,
    }
}

pub fn eq(a: &Value, b: &Value) -> bool {
    cmp(a, b) == Ordering::Equal
}

/// `sort`: stable, in jq's order.
pub fn sort(v: &mut [Value]) {
    v.sort_by(cmp);
}

/// `unique`: sorted, one of each.
pub fn unique(mut v: Vec<Value>) -> Vec<Value> {
    sort(&mut v);
    v.dedup_by(|b, a| eq(a, b));
    v
}

/// `unique_by(f)`: sorted by the key, and of the values that share a key the
/// one that came first.
pub fn unique_by<F: Fn(&Value) -> Value>(v: Vec<Value>, f: F) -> Vec<Value> {
    let mut keyed: Vec<(Value, Value)> = v.into_iter().map(|x| (f(&x), x)).collect();
    keyed.sort_by(|a, b| cmp(&a.0, &b.0));
    keyed.dedup_by(|b, a| eq(&a.0, &b.0));
    keyed.into_iter().map(|(_, x)| x).collect()
}

/// `sort_by(f)`.
pub fn sort_by<F: Fn(&Value) -> Value>(v: Vec<Value>, f: F) -> Vec<Value> {
    let mut keyed: Vec<(Value, Value)> = v.into_iter().map(|x| (f(&x), x)).collect();
    keyed.sort_by(|a, b| cmp(&a.0, &b.0));
    keyed.into_iter().map(|(_, x)| x).collect()
}

/// The value as the writer's type (src/jq.rs), which spells it as jq does.
pub fn to_j(v: &Value) -> crate::jq::J {
    use crate::jq::J;
    match v {
        Value::Null => J::Null,
        Value::Bool(b) => J::Bool(*b),
        Value::Num(n) => match n.as_str() {
            "NaN" => J::Null,
            "Infinity" => J::Num("1.7976931348623157e+308".to_string()),
            "-Infinity" => J::Num("-1.7976931348623157e+308".to_string()),
            _ => J::Num(n.clone()),
        },
        Value::Str(b) => crate::jq::arg(b),
        Value::Arr(a) => J::Arr(a.iter().map(to_j).collect()),
        Value::Obj(o) => J::Obj(o.iter().map(|(k, x)| (crate::jq::text(k), to_j(x))).collect()),
    }
}

/// `tojson`, and what `jq -c` prints.
pub fn dump(v: &Value) -> Vec<u8> {
    crate::jq::compact(&to_j(v)).into_bytes()
}

/// `tostring`, and what `"\(v)"` puts in a string: a string as it is, and
/// anything else as its JSON.
pub fn tostring(v: &Value) -> Vec<u8> {
    match v {
        Value::Str(b) => b.clone(),
        _ => dump(v),
    }
}

/// What `jq -r` prints for a value.
pub fn raw(v: &Value) -> Vec<u8> {
    tostring(v)
}

/// Oniguruma's `\s` and `[[:space:]]` over UTF-8: the White_Space property
/// (measured: U+00A0, U+0085, U+2003 and U+000B each count).
pub fn is_space(c: char) -> bool {
    matches!(
        c,
        '\u{9}'..='\u{d}' | ' ' | '\u{85}' | '\u{a0}' | '\u{1680}' | '\u{2000}'..='\u{200a}' | '\u{2028}' | '\u{2029}' | '\u{202f}' | '\u{205f}' | '\u{3000}'
    )
}

fn utf8(b: &[u8]) -> std::borrow::Cow<'_, str> {
    String::from_utf8_lossy(b)
}

/// `test("(^|/)node_modules/")`: a key of npm's that names a place in the
/// installed tree.
pub fn in_tree(key: &[u8]) -> bool {
    const M: &[u8] = b"node_modules/";
    if key.starts_with(M) {
        return true;
    }
    key.windows(M.len() + 1).any(|w| w[0] == b'/' && &w[1..] == M)
}

/// `split("node_modules/") | last`: what follows the last `node_modules/`,
/// or the whole key when it has none. None for the empty string, whose split
/// is the empty array.
pub fn after_last_node_modules(key: &[u8]) -> Option<&[u8]> {
    const M: &[u8] = b"node_modules/";
    if key.is_empty() {
        return None;
    }
    let mut at = None;
    let mut i = 0;
    // split takes the separators from the left without overlap.
    while i + M.len() <= key.len() {
        if &key[i..i + M.len()] == M {
            at = Some(i + M.len());
            i += M.len();
        } else {
            i += 1;
        }
    }
    Some(match at {
        Some(k) => &key[k..],
        None => key,
    })
}

/// `[.integrity | strings | splits("\\s+") | select(. != "")]`: the digests
/// one integrity value names.
pub fn tokens(entry: &Value) -> Vec<Vec<u8>> {
    let Ok(Value::Str(i)) = field(entry, "integrity") else { return Vec::new() };
    utf8(i).split(is_space).filter(|t| !t.is_empty()).map(|t| t.as_bytes().to_vec()).collect()
}

/// `tostring | sub("^[=v[:space:]]+"; "")`: a version without what npm lets
/// stand in front of it.
pub fn clean(v: &Value) -> Vec<u8> {
    let t = tostring(v);
    let st = utf8(&t);
    st.trim_start_matches(|c: char| c == '=' || c == 'v' || is_space(c)).as_bytes().to_vec()
}

/// `capture("^(?<parent>.*node_modules/.+)/node_modules/(?<name>(@[^/]+/)?[^/]+)$")`:
/// a key nested under another package, as that package's key and the name
/// below it. `.` takes no newline and `[^/]` does (measured).
pub fn nested(key: &[u8]) -> Option<(&[u8], &[u8])> {
    const SEP: &[u8] = b"/node_modules/";
    const M: &[u8] = b"node_modules/";
    if key.len() < SEP.len() {
        return None;
    }
    let p = (0..=key.len() - SEP.len()).rev().find(|&i| &key[i..i + SEP.len()] == SEP)?;
    let (parent, name) = (&key[..p], &key[p + SEP.len()..]);
    if parent.contains(&b'\n') {
        return None;
    }
    // `.*node_modules/.+`: a `node_modules/` with something after it.
    let holds = parent.len() > M.len() && parent[..parent.len() - 1].windows(M.len()).any(|w| w == M);
    if !holds {
        return None;
    }
    let slashes = name.iter().filter(|&&b| b == b'/').count();
    let ok = match slashes {
        0 => !name.is_empty(),
        1 => {
            let at = name.iter().position(|&b| b == b'/').unwrap_or(0);
            name[0] == b'@' && at > 1 && at + 1 < name.len()
        }
        _ => false,
    };
    if ok {
        Some((parent, name))
    } else {
        None
    }
}
