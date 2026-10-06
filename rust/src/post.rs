//! `safedeps-core post`: the PostToolUse hook (and Claude Code's
//! PostToolUseFailure). Not written yet.
//!
//! Until it is, `scripts/safedeps-post-verify.sh` is the hook, and this exits
//! 2 so that a shim pointed here early says so instead of staying silent.

mod jv;
mod sh;
mod closure;
mod report;
mod workspaces;
mod tree;

/// A measurement entry, fed one JSON request. It calls the same operations
/// the hook uses; the reference side calls their bash functions.
pub fn probe(input: &[u8]) -> i32 {
    use crate::json::Value;
    use std::io::Write;
    let Ok(v) = crate::json::parse_one(input) else { return 2 };
    let get = |key| jv::field(&v, key).unwrap_or(&jv::NULL);
    let bytes = |key| jv::text(get(key)).unwrap_or(b"");
    let path = sh::p(bytes("path"));
    let result: Result<Vec<u8>, i32> = match bytes("op") {
        b"closure" => closure::lock_closure(&path).map(|cs| {
            let mut out = Vec::new();
            for c in cs { out.extend(jv::dump(&Value::Arr(c.iter().map(closure::Spec::to_value).collect()))); out.push(b'\n'); }
            out
        }).map_err(|_| 1),
        b"new-records" => {
            let earlier = match get("earlier") { Value::Arr(a) => a.iter().filter_map(jv::text).map(sh::p).collect(), _ => Vec::new() };
            closure::new_records(&path, &earlier).map(|mut b| { if !b.is_empty() { b.push(b'\n'); } b }).map_err(|_| 1)
        }
        b"workspaces" => Ok([workspaces::members(&path), b"\n".to_vec()].concat()),
        b"workspace-dirs" => {
            let mut b = workspaces::physical_members(&path, &crate::state::guard_dir()).join(&b'\n');
            if !b.is_empty() { b.push(b'\n'); } Ok(b)
        }
        b"tree" => {
            let query = jv::read_file(&sh::p(bytes("query"))).unwrap_or(jv::Stream { values: Vec::new(), failed: true });
            let problems = |url: &Value| crate::ask::fetch_problems(get("facts"), &String::from_utf8_lossy(jv::text(url).ok_or(())?))
                .map(|xs| xs.iter().map(|s| jv::s(s.as_bytes())).collect());
            let origins = |url: &Value| crate::ask::fetch_origins(get("facts"), &String::from_utf8_lossy(jv::text(url).ok_or(())?))
                .map(|xs| xs.iter().map(|x| x.value()).collect());
            tree::judge(&path, &crate::state::guard_dir(), &query, get("withheld"), &problems, &origins)
                .map(|ls| { let mut b = ls.join(&b'\n'); if !b.is_empty() { b.push(b'\n'); } b }).map_err(|_| 1)
        }
        b"path" => Ok(report::path(&path)),
        b"outside" => Ok(report::outside(&sh::p(bytes("project")), &path).unwrap_or_default()),
        b"reach" => Ok(report::reach_blocker(&path).unwrap_or_default()),
        b"inert" => report::inert(&path, bytes("input")),
        b"report" => {
            let mut r = report::Report::default();
            match bytes("action") {
                b"restore" => r.restore(&sh::p(bytes("source")), &path),
                b"remove" => r.remove(&path),
                b"inert" => r.inert(&crate::state::guard_dir(), &path, bytes("input")),
                b"rebuild" => r.rebuild(&crate::state::guard_dir(), &path, bytes("input"), bytes("fact")),
                b"workspaces" => r.workspaces_key(&path),
                _ => return 2,
            }
            if matches!(get("changed_nothing"), Value::Bool(true)) { r.changed_nothing(); }
            let mut b = r.lines.join(&b'\n'); if !b.is_empty() { b.push(b'\n'); } Ok(b)
        }
        _ => return 2,
    };
    match result { Ok(out) => { let _ = std::io::stdout().write_all(&out); 0 }, Err(rc) => rc }
}

pub fn main(_input: &[u8]) -> i32 {
    eprintln!("safedeps-core post: not written yet. scripts/safedeps-post-verify.sh is the PostToolUse hook.");
    2
}
