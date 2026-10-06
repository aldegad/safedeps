//! A JSON reader for the hook payload, enough for `tool_name` and
//! `tool_input.command`: objects, arrays, strings with every escape (a
//! surrogate pair joined, a lone surrogate read as U+FFFD, as jq reads it),
//! numbers, true, false and null.

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

struct P<'a> {
    s: &'a [u8],
    i: usize,
}

impl<'a> P<'a> {
    fn ws(&mut self) {
        while self.i < self.s.len() && matches!(self.s[self.i], b' ' | b'\t' | b'\n' | b'\r') {
            self.i += 1;
        }
    }
    fn value(&mut self) -> Result<Value, String> {
        self.ws();
        let c = *self.s.get(self.i).ok_or("end")?;
        match c {
            b'{' => {
                self.i += 1;
                let mut v = Vec::new();
                self.ws();
                if self.s.get(self.i) == Some(&b'}') {
                    self.i += 1;
                    return Ok(Value::Obj(v));
                }
                loop {
                    self.ws();
                    let k = match self.value()? {
                        Value::Str(k) => k,
                        _ => return Err("key".into()),
                    };
                    self.ws();
                    if self.s.get(self.i) != Some(&b':') {
                        return Err(":".into());
                    }
                    self.i += 1;
                    let x = self.value()?;
                    v.push((k, x));
                    self.ws();
                    match self.s.get(self.i) {
                        Some(b',') => self.i += 1,
                        Some(b'}') => {
                            self.i += 1;
                            return Ok(Value::Obj(v));
                        }
                        _ => return Err("object".into()),
                    }
                }
            }
            b'[' => {
                self.i += 1;
                let mut v = Vec::new();
                self.ws();
                if self.s.get(self.i) == Some(&b']') {
                    self.i += 1;
                    return Ok(Value::Arr(v));
                }
                loop {
                    v.push(self.value()?);
                    self.ws();
                    match self.s.get(self.i) {
                        Some(b',') => self.i += 1,
                        Some(b']') => {
                            self.i += 1;
                            return Ok(Value::Arr(v));
                        }
                        _ => return Err("array".into()),
                    }
                }
            }
            b'"' => {
                self.i += 1;
                let mut o = Vec::new();
                loop {
                    let c = *self.s.get(self.i).ok_or("string")?;
                    self.i += 1;
                    match c {
                        b'"' => return Ok(Value::Str(o)),
                        b'\\' => {
                            let e = *self.s.get(self.i).ok_or("escape")?;
                            self.i += 1;
                            match e {
                                b'"' => o.push(b'"'),
                                b'\\' => o.push(b'\\'),
                                b'/' => o.push(b'/'),
                                b'b' => o.push(8),
                                b'f' => o.push(12),
                                b'n' => o.push(b'\n'),
                                b'r' => o.push(b'\r'),
                                b't' => o.push(b'\t'),
                                b'u' => {
                                    let mut cp = self.hex4()?;
                                    if (0xd800..0xdc00).contains(&cp) {
                                        if self.s.get(self.i) == Some(&b'\\') && self.s.get(self.i + 1) == Some(&b'u') {
                                            let save = self.i;
                                            self.i += 2;
                                            let lo = self.hex4()?;
                                            if (0xdc00..0xe000).contains(&lo) {
                                                cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00);
                                            } else {
                                                self.i = save;
                                                cp = 0xfffd;
                                            }
                                        } else {
                                            cp = 0xfffd;
                                        }
                                    } else if (0xdc00..0xe000).contains(&cp) {
                                        cp = 0xfffd;
                                    }
                                    let ch = char::from_u32(cp).unwrap_or('\u{fffd}');
                                    let mut b = [0u8; 4];
                                    o.extend_from_slice(ch.encode_utf8(&mut b).as_bytes());
                                }
                                _ => return Err("bad escape".into()),
                            }
                        }
                        _ => o.push(c),
                    }
                }
            }
            b't' if self.s[self.i..].starts_with(b"true") => {
                self.i += 4;
                Ok(Value::Bool(true))
            }
            b'f' if self.s[self.i..].starts_with(b"false") => {
                self.i += 5;
                Ok(Value::Bool(false))
            }
            b'n' if self.s[self.i..].starts_with(b"null") => {
                self.i += 4;
                Ok(Value::Null)
            }
            _ => {
                let st = self.i;
                while self.i < self.s.len() && b"+-0123456789.eE".contains(&self.s[self.i]) {
                    self.i += 1;
                }
                if st == self.i {
                    return Err("value".into());
                }
                Ok(Value::Num(String::from_utf8_lossy(&self.s[st..self.i]).into_owned()))
            }
        }
    }
    fn hex4(&mut self) -> Result<u32, String> {
        let h = self.s.get(self.i..self.i + 4).ok_or("hex")?;
        let v = u32::from_str_radix(std::str::from_utf8(h).map_err(|_| "hex")?, 16).map_err(|_| "hex")?;
        self.i += 4;
        Ok(v)
    }
}

pub fn parse(s: &[u8]) -> Result<Value, String> {
    let mut p = P { s, i: 0 };
    let v = p.value()?;
    Ok(v)
}

/// One JSON text, with nothing after it but blanks.
pub fn parse_one(s: &[u8]) -> Result<Value, String> {
    let mut p = P { s, i: 0 };
    let v = p.value()?;
    p.ws();
    if p.i != s.len() {
        return Err("text after the value".into());
    }
    Ok(v)
}
