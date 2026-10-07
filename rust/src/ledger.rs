//! The hooks' approval reader. One predicate and one effect index per run.
//! lib/ledger/ledger.sh remains the writer; this does not approve anything.
pub mod context;

use crate::{jq, json::{self, Value}, os, sha256, state};
use std::{collections::HashSet, io, os::unix::fs::DirBuilderExt, path::{Path, PathBuf}};

type Spec = (String, String, String);
fn string<'a>(v: &'a Value, key: &str) -> Option<&'a str> { v.get(key).and_then(Value::as_str) }
fn nonempty(v: &Value, key: &str) -> bool { string(v, key).is_some_and(|s| !s.is_empty()) }
fn hash_field(v: &Value, key: &str) -> bool { string(v, key).is_some_and(|s| s.starts_with("sha256:")) }
fn defaulted(v: Option<&Value>) -> Option<&Value> { v.filter(|v| !matches!(v, Value::Null | Value::Bool(false))) }
fn object(v: Option<&Value>) -> bool { matches!(v, Some(Value::Obj(_))) }

/// SAFEDEPS_LEDGER_JQ_PREDICATE/ledger_is_valid, used by both readers.
pub fn valid(v: &Value) -> bool {
    if !matches!(v, Value::Obj(_)) || !hash_field(v, "hash")
        || !["ecosystem", "package", "version", "approved_at", "expires_at"].iter().all(|k| nonempty(v, k))
        || !["version_range", "approved_by"].iter().all(|k| string(v, k).is_some())
        || !object(v.get("evidence")) { return false; }
    if defaulted(v.get("transitive_specs")).is_some_and(|t| !matches!(t, Value::Arr(_))) { return false; }
    let Some(c) = defaulted(v.get("project_context")) else { return true; };
    if !matches!(c, Value::Obj(_)) || !hash_field(c, "context_hash") || !nonempty(c, "project_root") { return false; }
    match string(c, "type") {
        Some("npm-overrides-probe") => nonempty(c, "overrides_source") && hash_field(c, "overrides_sha256")
            && matches!(c.get("overrides"), Some(Value::Obj(o)) if !o.is_empty()),
        Some(kind @ ("yarn-project-lockfile" | "yarn-project-materialized-lockfile")) => {
            if !nonempty(c, "manifest_path") || !nonempty(c, "lockfile_path") || !hash_field(c, "input_sha256")
                || !matches!(c.get("input_files"), Some(Value::Arr(a)) if !a.is_empty()) { return false; }
            if kind == "yarn-project-lockfile" { return true; }
            let Some(m) = c.get("materialization") else { return false; };
            matches!(m, Value::Obj(_)) && nonempty(m, "candidate") && string(m, "input_sha256") == string(c, "input_sha256")
                && hash_field(m, "generated_lockfile_sha256")
                && string(m, "command") == Some("yarn install --mode=update-lockfile --no-immutable")
                && string(m, "isolation") == Some("private-project-mirror")
        }
        _ => false,
    }
}

/// The ISO UTC format the ledger writes and jq's fromdateiso8601 reads.
/// No subprocess and no local-zone interpretation.
pub fn epoch(s: &str) -> Option<i64> {
    let b = s.as_bytes();
    if b.len() != 20 || b[4] != b'-' || b[7] != b'-' || b[10] != b'T' || b[13] != b':' || b[16] != b':' || b[19] != b'Z' { return None; }
    let n = |a, z| std::str::from_utf8(&b[a..z]).ok()?.parse::<i64>().ok();
    let (y, m, d, h, min, sec) = (n(0,4)?, n(5,7)?, n(8,10)?, n(11,13)?, n(14,16)?, n(17,19)?);
    if !(1..=12).contains(&m) || !(1..=31).contains(&d) || h > 23 || min > 59 || sec > 60 { return None; }
    let y = y - i64::from(m <= 2);
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = m + if m > 2 { -3 } else { 9 };
    let days = era * 146097 + yoe * 365 + yoe / 4 - yoe / 100 + (153 * mp + 2) / 5 + d - 1 - 719468;
    Some(days * 86400 + h * 3600 + min * 60 + sec)
}

pub fn hash(ecosystem: &str, package: &str, version: &str, context: &str) -> String {
    let mut text = format!("{}\n{}\n{}", ecosystem, package, version);
    if !context.is_empty() { text.push('\n'); text.push_str(context); }
    format!("sha256:{}", sha256::hex(text.as_bytes()))
}

fn filename(key: &str) -> String { format!("{}.json", key.replacen(':', "-", 1)) }

const DIRECTORY_ENV: &str = "SAFEDEPS_LEDGER_DIR";
const DIRECTORY_NAME: &str = "approved-specs";

pub fn directory() -> PathBuf {
    match std::env::var_os(DIRECTORY_ENV) {
        Some(p) if !p.is_empty() => p.into(),
        _ => state::guard_dir().join(DIRECTORY_NAME),
    }
}
fn init(dir: &Path) -> io::Result<()> { std::fs::DirBuilder::new().recursive(true).mode(0o700).create(dir) }

pub struct Check { pub approved: bool, pub answer: jq::J }
/// safedeps_ledger_check: direct pre-guard lookup (not closure approval).
/// Keep its order: shape, hash, context, expiry. Revocation is represented
/// there by expires_at; the effect index also checks revoked_at explicitly.
pub fn check(dir: &Path, ecosystem: &str, package: &str, version: &str, context: &str, now: i64) -> io::Result<Check> {
    init(dir)?;
    let key = hash(ecosystem, package, version, context);
    let path = dir.join(filename(&key));
    let mut fields = Vec::new();
    let reason = if !path.is_file() { "miss" } else {
        let spec = std::fs::read(path).ok().and_then(|b| json::parse_one(&b).ok());
        match spec.as_ref() {
            None => "invalid",
            Some(v) if !valid(v) => "invalid",
            Some(v) if string(v, "hash") != Some(key.as_str()) => {
                fields.push(("stored_hash", jq::s(string(v, "hash").unwrap_or_default()))); "hash_mismatch"
            }
            Some(v) if v.get("project_context").and_then(|c| string(c, "context_hash")).unwrap_or("") != context => {
                fields.push(("context_hash", jq::s(context)));
                fields.push(("stored_context_hash", jq::s(v.get("project_context").and_then(|c| string(c, "context_hash")).unwrap_or(""))));
                "context_mismatch"
            }
            Some(v) => {
                fields.push(("spec", jq::from_value(v)));
                if string(v, "expires_at").and_then(epoch).is_some_and(|t| t > now) { "hit" } else { "expired" }
            }
        }
    };
    let approved = reason == "hit";
    let mut answer = vec![("approved", jq::J::Bool(approved)), ("reason", jq::s(reason)), ("hash", jq::s(&key))];
    answer.extend(fields);
    Ok(Check { approved, answer: jq::obj(answer) })
}

/// An index row owns its provenance, as the shell's six TSV fields do.
pub struct Entry {
    pub ecosystem: String, pub package: String, pub version: String,
    pub owner_hash: String, pub owner_package: String, pub owner_version: String,
}
pub struct EffectIndex { pub entries: Vec<Entry>, approved: HashSet<Spec> }
fn tostring(v: Option<&Value>) -> String {
    match v { Some(Value::Str(s)) => jq::text(s), Some(v) => jq::compact(&jq::from_value(v)), None => "null".into() }
}
fn tsv(s: &str) -> String { s.replace('\\', "\\\\").replace('\t', "\\t").replace('\r', "\\r").replace('\n', "\\n") }
fn field(v: Option<&Value>) -> Result<String, ()> {
    match v { None | Some(Value::Null) => Ok(String::new()), Some(Value::Arr(_) | Value::Obj(_)) => Err(()), Some(v) => Ok(tostring(Some(v))) }
}
impl EffectIndex {
    pub fn contains(&self, ecosystem: &str, package: &str, version: &str) -> bool {
        self.approved.contains(&(ecosystem.into(), package.into(), version.into()))
    }
    /// safedeps_ledger_effect_misses: Err is unreadable, distinct from no misses.
    pub fn misses(&self, ecosystem: &str, closure: &Value) -> Result<Vec<(String, String)>, ()> {
        let rows: Vec<&Value> = match closure { Value::Arr(a) => a.iter().collect(), Value::Obj(o) => o.iter().map(|(_,v)| v).collect(), _ => return Err(()) };
        let mut misses = Vec::new();
        for row in rows {
            if !matches!(row, Value::Obj(_) | Value::Null) { return Err(()); }
            let package = field(row.get("package"))?;
            let version = tostring(row.get("version"));
            if !self.contains(ecosystem, &package, &version) { misses.push((package, version)); }
        }
        Ok(misses)
    }
    pub fn tsv(&self) -> String {
        let mut out = String::new();
        for e in &self.entries {
            out.push_str(&[&e.ecosystem, &e.package, &e.version, &e.owner_hash, &e.owner_package, &e.owner_version].map(|s| tsv(s)).join("\t"));
            out.push('\n');
        }
        out
    }
}

/// Read the directory once. A damaged file is named and set aside; it cannot
/// empty the other approvals or make an unreadable closure count as approved.
pub fn effect_index(dir: &Path, context: &str, now: i64, warnings: &mut Vec<u8>) -> io::Result<EffectIndex> {
    init(dir)?;
    let mut index = EffectIndex { entries: Vec::new(), approved: HashSet::new() };
    let Ok(files) = std::fs::read_dir(dir) else { return Ok(index); };
    for entry in files.flatten() {
        if !entry.file_type().is_ok_and(|t| t.is_file()) || entry.path().extension().is_none_or(|e| e != "json") { continue; }
        let values = std::fs::read(entry.path()).ok().and_then(|s| json::parse_stream(&s).ok());
        let mut rows = Vec::new();
        let readable = values.is_some_and(|values| {
            for v in values {
                if !valid(&v) { continue; }
                if defaulted(v.get("revoked_at")).is_some_and(|r| r.as_str() != Some(""))
                    || !string(&v, "expires_at").and_then(epoch).is_some_and(|t| t > now) { continue; }
                let ctx = defaulted(v.get("project_context"));
                if if context.is_empty() { ctx.is_some() } else { ctx.and_then(|c| string(c, "context_hash")) != Some(context) } { continue; }
                let owner = string(&v, "ecosystem").unwrap();
                let mut specs = vec![(owner.to_string(), string(&v, "package").unwrap().to_string(), string(&v, "version").unwrap().to_string())];
                if let Some(Value::Arr(transitive)) = v.get("transitive_specs") {
                    for t in transitive {
                        if !matches!(t, Value::Obj(_) | Value::Null) { return false; }
                        let Ok(eco) = field(defaulted(t.get("ecosystem")).or(v.get("ecosystem"))) else { return false; };
                        let Ok(pkg) = field(t.get("package")) else { return false; };
                        specs.push((eco, pkg, tostring(t.get("version"))));
                    }
                }
                for (ecosystem, package, version) in specs {
                    rows.push(Entry { ecosystem, package, version, owner_hash: string(&v, "hash").unwrap().into(),
                        owner_package: string(&v, "package").unwrap().into(), owner_version: string(&v, "version").unwrap().into() });
                }
            }
            true
        });
        if !readable {
            warnings.extend_from_slice(format!("safedeps ledger: skipping unreadable ledger entry {}\n", entry.path().display()).as_bytes());
            continue;
        }
        for row in rows {
            index.approved.insert((row.ecosystem.clone(), row.package.clone(), row.version.clone()));
            index.entries.push(row);
        }
    }
    Ok(index)
}

/// Read-only seam for the differential; hooks call the functions directly.
pub fn main(args: &[String], input: &[u8]) -> i32 {
    use std::io::Write;
    let dir = directory();
    let now = os::wall(os::WallRole::LedgerCliExpiry).seconds();
    match args.first().map(String::as_str) {
        Some("context-probe") => return context::probe(input),
        Some("hash") if (4..=5).contains(&args.len()) => { print!("{}", hash(&args[1], &args[2], &args[3], args.get(4).map(String::as_str).unwrap_or(""))); 0 }
        Some("check") if (4..=5).contains(&args.len()) => {
            match check(&dir, &args[1], &args[2], &args[3], args.get(4).map(String::as_str).unwrap_or(""), now) {
                Ok(c) => { println!("{}", jq::compact(&c.answer)); i32::from(!c.approved) }
                Err(e) => { eprintln!("safedeps ledger: {}", e); 2 }
            }
        }
        Some("index" | "misses") => {
            let mut warnings = Vec::new();
            let index = effect_index(&dir, args.get(2).map(String::as_str).unwrap_or(""), now, &mut warnings);
            let _ = std::io::stderr().write_all(&warnings);
            let Ok(index) = index else { return 2; };
            if args[0] == "index" { print!("{}", index.tsv()); return 0; }
            let Some(eco) = args.get(1) else { return 2; };
            let Ok(v) = json::parse_one(input) else { return 2; };
            let Ok(misses) = index.misses(eco, &v) else { return 2; };
            for (p,v) in &misses { println!("{}\t{}", tsv(p), tsv(v)); }
            i32::from(!misses.is_empty())
        }
        _ => 2,
    }
}

#[cfg(test)]
#[test]
fn ledger_defaults_match_cli() {
    let cli = include_str!("../../lib/ledger/ledger.sh");
    for (name, default) in [
        (state::GUARD_ENV, format!("${{{}}}{}", state::HOME_ENV, std::str::from_utf8(state::GUARD_SUFFIX).unwrap())),
        (DIRECTORY_ENV, format!("${{{}}}/{}", state::GUARD_ENV, DIRECTORY_NAME)),
        ("SAFEDEPS_LEDGER_DEFAULT_TTL_DAYS", state::DEFAULT_LEDGER_TTL_DAYS.into()),
    ] {
        assert!(cli.lines().any(|line| line == format!("{name}=\"${{{name}:-{default}}}\"")), "CLI default {name}");
    }
    let script = format!("{cli}\nprintf '%s\\n' \"$SAFEDEPS_HOME\" \"$SAFEDEPS_LEDGER_DIR\" \"$SAFEDEPS_LEDGER_DEFAULT_TTL_DAYS\"\nh=$(safedeps_ledger_hash npm @scope/pkg 1.2.3 context)\nprintf '%s\\n' \"$h\" \"$(safedeps_ledger_hash_to_filename \"$h\")\"");
    let run = |home: &str| {
        let out = std::process::Command::new("/bin/bash").env_clear()
            .env("PATH", "/usr/bin:/bin").env("HOME", "fixture home").env("SAFEDEPS_HOME", home)
            .args(["-c", &script]).output().unwrap();
        assert!(out.status.success(), "CLI ledger: {}", String::from_utf8_lossy(&out.stderr));
        String::from_utf8(out.stdout).unwrap()
    };
    let key = hash("npm", "@scope/pkg", "1.2.3", "context");
    let tail = format!("{}\n{}\n", key, filename(&key));
    assert_eq!(run(""), format!("fixture home/.safedeps\nfixture home/.safedeps/approved-specs\n30\n{tail}"));
    assert_eq!(run("x/"), format!("x/\nx//approved-specs\n30\n{tail}"));
    // Text expansion retains the extra slash; native Path::join normalizes it.
    assert_eq!(Path::new("x/").join(DIRECTORY_NAME).as_os_str(), "x/approved-specs");
    assert_ne!(Path::new("x/").join(DIRECTORY_NAME).as_os_str(), "x//approved-specs");
}
