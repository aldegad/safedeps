//! npm's two records of an install, as the effect gate reads them
//! (lib/npm/closure.sh): the closure a lockfile records, and what a record
//! holds that the records before the command did not.
//!
//! Both are jq programs in the bash hook. They are written out here value by
//! value, with jq's own answer wherever a field is not the type npm writes:
//! which shapes are an error (and so a lockfile that "could not be parsed"),
//! which are skipped, and which go on as they are.

use super::jv::{self, Stream};
use crate::json::Value;
use std::collections::HashSet;

/// One package of a closure. `package` is a string, or null where a key ends
/// in `node_modules/` and names none (jq's `split("/") | .[0]` of nothing).
#[derive(Clone, Debug)]
pub struct Spec {
    pub package: Value,
    pub version: Vec<u8>,
}

impl Spec {
    /// `.ecosystem + "\u0000" + .package + "\u0000" + .version`
    fn key(&self) -> Vec<u8> {
        let mut k = b"npm\0".to_vec();
        if let Value::Str(p) = &self.package {
            k.extend_from_slice(p);
        }
        k.push(0);
        k.extend_from_slice(&self.version);
        k
    }

    fn order(&self) -> Value {
        Value::Arr(vec![self.package.clone(), Value::Str(self.version.clone())])
    }

    pub fn to_value(&self) -> Value {
        jv::obj(vec![
            ("ecosystem", jv::s(b"npm")),
            ("package", self.package.clone()),
            ("version", Value::Str(self.version.clone())),
            ("direct", Value::Bool(false)),
        ])
    }
}

/// `unique_by(.ecosystem + "\u0000" + .package + "\u0000" + .version) |
/// sort_by(.package, .version)`
pub fn unique_sorted(specs: Vec<Spec>) -> Vec<Spec> {
    let mut keyed: Vec<(Vec<u8>, Spec)> = specs.into_iter().map(|s| (s.key(), s)).collect();
    keyed.sort_by(|a, b| a.0.cmp(&b.0));
    keyed.dedup_by(|b, a| a.0 == b.0);
    let mut out: Vec<(Value, Spec)> = keyed.into_iter().map(|(_, s)| (s.order(), s)).collect();
    out.sort_by(|a, b| jv::cmp(&a.0, &b.0));
    out.into_iter().map(|(_, s)| s).collect()
}

/// `package_name_from_path`: the package a key under node_modules names.
fn name_from_path(key: &[u8]) -> Value {
    let tail = jv::after_last_node_modules(key).unwrap_or(b"");
    if tail.is_empty() {
        // `"" | split("/") | .[0]`
        return Value::Null;
    }
    let mut parts = tail.split(|&b| b == b'/');
    let first = parts.next().unwrap_or(b"");
    if tail.starts_with(b"@") {
        match parts.next() {
            Some(second) => {
                let mut n = first.to_vec();
                n.push(b'/');
                n.extend_from_slice(second);
                Value::Str(n)
            }
            None => Value::Str(first.to_vec()),
        }
    } else {
        Value::Str(first.to_vec())
    }
}

/// The closure one JSON text records, or Err where jq's program fails on it.
fn closure_of(v: &Value) -> Result<Vec<Spec>, ()> {
    let packages = jv::field(v, "packages")?;
    let Value::Obj(entries) = packages else { return Ok(Vec::new()) };
    let mut specs = Vec::new();
    for (key, entry) in entries {
        if !jv::in_tree(key) {
            continue;
        }
        let version = jv::field(entry, "version")?;
        if !jv::truthy(version) || matches!(version, Value::Str(s) if s.is_empty()) {
            continue;
        }
        let name = jv::field(entry, "name")?;
        let package = if jv::truthy(name) { name.clone() } else { name_from_path(key) };
        if matches!(&package, Value::Str(s) if s.is_empty()) {
            continue;
        }
        // The key of unique_by adds the package to a string: a string or null
        // adds, and anything else is jq's error.
        if !matches!(package, Value::Str(_) | Value::Null) {
            return Err(());
        }
        specs.push(Spec { package, version: jv::tostring(version) });
    }
    Ok(unique_sorted(specs))
}

/// `safedeps_npm_lock_closure <lockfile>`: one closure per JSON text of the
/// file. Err where the bash function returns non-zero: a file jq cannot open
/// or parse to its end, or a text the program fails on.
pub fn lock_closure(path: &std::path::Path) -> Result<Vec<Vec<Spec>>, ()> {
    let st = jv::read_file(path).ok_or(())?;
    lock_closure_of(&st)
}

pub fn lock_closure_of(st: &Stream) -> Result<Vec<Vec<Spec>>, ()> {
    let mut out = Vec::new();
    let mut last_failed = false;
    for v in &st.values {
        match closure_of(v) {
            Ok(c) => {
                out.push(c);
                last_failed = false;
            }
            Err(()) => last_failed = true,
        }
    }
    if st.failed || last_failed {
        return Err(());
    }
    Ok(out)
}

struct Node<'a> {
    key: Vec<u8>,
    value: &'a Value,
}

/// `v1($prefix)`: lockfileVersion 1 nests its packages under `dependencies`.
fn v1<'a>(v: &'a Value, prefix: &[u8], out: &mut Vec<Node<'a>>) -> Result<(), ()> {
    let deps = jv::field(v, "dependencies")?;
    let Value::Obj(entries) = deps else { return Ok(()) };
    for (name, value) in entries {
        let mut key = prefix.to_vec();
        key.extend_from_slice(b"node_modules/");
        key.extend_from_slice(name);
        out.push(Node { key: key.clone(), value });
        if matches!(value, Value::Obj(_)) {
            key.push(b'/');
            v1(value, &key, out)?;
        }
    }
    Ok(())
}

/// `nodes`: every entry of a record that is not the root and is an object.
fn nodes<'a>(v: &'a Value, out: &mut Vec<Node<'a>>) -> Result<(), ()> {
    let mut all = Vec::new();
    match jv::field(v, "packages")? {
        Value::Obj(entries) => {
            for (key, value) in entries {
                all.push(Node { key: key.clone(), value });
            }
        }
        _ => v1(v, b"", &mut all)?,
    }
    out.extend(all.into_iter().filter(|n| !n.key.is_empty() && matches!(n.value, Value::Obj(_))));
    Ok(())
}

fn or_empty(v: &Value) -> Value {
    if jv::truthy(v) {
        v.clone()
    } else {
        Value::Str(Vec::new())
    }
}

fn get<'a>(n: &Node<'a>, k: &str) -> &'a Value {
    jv::field(n.value, k).unwrap_or(&jv::NULL)
}

/// `tuple`: what makes an entry the same entry.
fn tuple(n: &Node) -> Vec<u8> {
    jv::dump(&Value::Arr(vec![
        Value::Str(n.key.clone()),
        or_empty(get(n, "version")),
        or_empty(get(n, "resolved")),
        or_empty(get(n, "integrity")),
    ]))
}

fn is_link(n: &Node) -> bool {
    matches!(get(n, "link"), Value::Bool(true))
}

/// `safedeps_npm_new_records <current> <earlier>...`: what the bash function
/// prints, as the lines a `$(...)` keeps of it, or Err where it returns
/// non-zero.
///
///   S<TAB><resolved>       a source no earlier record names
///   N<TAB><key>            an installed package no earlier record has
///   L<TAB><key><TAB><dir>  a link, and the directory it points at
///   T<TAB><key>            a directory outside node_modules
pub fn new_records(current: &std::path::Path, earlier: &[std::path::PathBuf]) -> Result<Vec<u8>, ()> {
    // `--slurpfile now`: a file jq cannot read whole stops jq before it runs.
    let now = jv::read_file(current).ok_or(())?;
    if now.failed {
        return Err(());
    }
    let mut before_streams = Vec::new();
    for e in earlier {
        let st = jv::read_file(e).ok_or(())?;
        before_streams.push(st);
    }
    let mut before: Vec<Node> = Vec::new();
    for st in &before_streams {
        for v in &st.values {
            nodes(v, &mut before)?;
        }
        if st.failed {
            return Err(());
        }
    }
    let seen: HashSet<Vec<u8>> = before.iter().map(tuple).collect();
    let mut sources: HashSet<&[u8]> = HashSet::new();
    for n in before.iter().filter(|n| !is_link(n)) {
        if let Value::Str(r) = get(n, "resolved") {
            sources.insert(r);
        }
    }
    let mut current_nodes: Vec<Node> = Vec::new();
    if let Some(first) = now.values.first() {
        nodes(first, &mut current_nodes)?;
    }
    let new: Vec<&Node> = current_nodes.iter().filter(|n| !seen.contains(&tuple(n))).collect();

    let mut lines: Vec<Vec<u8>> = Vec::new();
    let mut fresh: Vec<Value> = Vec::new();
    for n in current_nodes.iter().filter(|n| jv::in_tree(&n.key) && !is_link(n)) {
        if let Value::Str(r) = get(n, "resolved") {
            if !sources.contains(r.as_slice()) {
                fresh.push(Value::Str(r.clone()));
            }
        }
    }
    for r in jv::unique(fresh) {
        let mut l = b"S\t".to_vec();
        l.extend_from_slice(&jv::tostring(&r));
        lines.push(l);
    }
    for n in new.iter().filter(|n| jv::in_tree(&n.key) && !is_link(n)) {
        let mut l = b"N\t".to_vec();
        l.extend_from_slice(&n.key);
        lines.push(l);
    }
    for n in new.iter().filter(|n| jv::in_tree(&n.key) && is_link(n)) {
        let mut l = b"L\t".to_vec();
        l.extend_from_slice(&n.key);
        l.push(b'\t');
        if let Value::Str(r) = get(n, "resolved") {
            l.extend_from_slice(r);
        }
        lines.push(l);
    }
    for n in new.iter().filter(|n| !jv::in_tree(&n.key)) {
        let mut l = b"T\t".to_vec();
        l.extend_from_slice(&n.key);
        lines.push(l);
    }
    Ok(jv::captured(&lines))
}

/// The public registries: npm's and Yarn's, over https, read as a scheme and
/// a host at the start of the value (SAFEDEPS_NPM_PUBLIC_REGISTRY_RE,
/// `^https://registry\.(npmjs\.org|yarnpkg\.com)/`, without regard to case).
///
/// Case is ASCII's. jq's `test(...; "i")` folds by Unicode, so a URL that
/// spells the host with a character outside ASCII that folds to an ASCII
/// letter is public to the bash hook's jq and is not here: such a source is
/// judged as one off the public registry (core-intended-post.tsv,
/// public-url-ascii-case).
pub fn public_registry_url(url: &[u8]) -> bool {
    for head in [&b"https://registry.npmjs.org/"[..], &b"https://registry.yarnpkg.com/"[..]] {
        if url.len() >= head.len() && url[..head.len()].eq_ignore_ascii_case(head) {
            return true;
        }
    }
    false
}
