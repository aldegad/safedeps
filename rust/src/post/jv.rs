//! jq operations used by the post hook. JSON input and spelling are owned
//! by the shared json and jq modules; this module only evaluates values.
use crate::json::Value;
use std::cmp::Ordering;
pub use crate::json::{Stream, read, read_file, read_one_object, captured, each, set};
pub static NULL: Value = Value::Null;

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
    crate::jq::from_value(v)
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
