//! The shared jq-compatible JSON stream reader for hook payloads and disk
//! records. A malformed value is a parse error; nesting has a fixed limit
//! before recursive values can exhaust the process stack. The parser uses an
//! explicit stack (jq counts object keys toward its 256-place limit).
//!
//! Origin: koon c8d15af, with the parser moved here so both hooks use one
//! definition of a readable record. core-json-differential.py checks actual
//! jq answers, including malformed input and deep nesting.

#[derive(Debug, Clone)]
pub enum Value {
    Null,
    Bool(bool),
    Num(String),
    Str(Vec<u8>),
    Arr(Vec<Value>),
    Obj(Vec<(Vec<u8>, Value)>),
}

impl Value {
    pub fn get(&self, k: &str) -> Option<&Value> {
        match self {
            Value::Obj(v) => v.iter().rev().find(|(kk, _)| kk.as_slice() == k.as_bytes()).map(|(_, v)| v),
            _ => None,
        }
    }
    pub fn as_str(&self) -> Option<&str> {
        match self {
            Value::Str(s) => std::str::from_utf8(s).ok(),
            _ => None,
        }
    }
    pub fn as_bytes(&self) -> Option<Vec<u8>> {
        match self {
            Value::Str(s) => Some(s.clone()),
            _ => None,
        }
    }
}

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
        // jq strips a byte order mark; a prefix cut at EOF produces no value.
        if s.starts_with(&[0xef, 0xbb, 0xbf]) {
            &s[3..]
        } else {
            return Stream { values, failed: ![0xef, 0xbb, 0xbf].starts_with(s) };
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


/// A complete stream; unlike read(), this caller wants no partial answer.
pub fn parse_stream(s: &[u8]) -> Result<Vec<Value>, String> {
    let stream = read(s);
    if stream.failed { Err("invalid JSON stream".into()) } else { Ok(stream.values) }
}

/// A payload or record that holds exactly one complete value.
pub fn parse_one(s: &[u8]) -> Result<Value, String> {
    let mut values = parse_stream(s)?;
    if values.len() != 1 { return Err("expected one JSON value".into()); }
    Ok(values.remove(0))
}

/// Legacy callers also require a whole record, never a prefix of one.
pub fn parse(s: &[u8]) -> Result<Value, String> { parse_one(s) }
