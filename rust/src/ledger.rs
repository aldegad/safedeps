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

/// The project_context kinds that scope an approval to a project.
/// lib/ledger/context-kinds.sh declares the same names, and
/// context_kinds_match_cli holds the two together.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum ContextKind { NpmOverrides, YarnLockfile, YarnMaterialized }
impl ContextKind {
    const ALL: [Self; 3] = [Self::NpmOverrides, Self::YarnLockfile, Self::YarnMaterialized];
    pub fn as_str(self) -> &'static str {
        match self {
            Self::NpmOverrides => "npm-overrides-probe",
            Self::YarnLockfile => "yarn-project-lockfile",
            Self::YarnMaterialized => "yarn-project-materialized-lockfile",
        }
    }
    fn parse(s: &str) -> Option<Self> { Self::ALL.into_iter().find(|k| k.as_str() == s) }
}
/// What a materialized Yarn candidate records it ran, and where.
const MATERIALIZE_COMMAND: &str = "yarn install --mode=update-lockfile --no-immutable";
const MATERIALIZE_ISOLATION: &str = "private-project-mirror";

/// SAFEDEPS_LEDGER_JQ_PREDICATE/ledger_is_valid, used by both readers.
pub fn valid(v: &Value) -> bool {
    if !matches!(v, Value::Obj(_)) || !hash_field(v, "hash")
        || !["ecosystem", "package", "version", "approved_at", "expires_at"].iter().all(|k| nonempty(v, k))
        || !["version_range", "approved_by"].iter().all(|k| string(v, k).is_some())
        || !object(v.get("evidence")) { return false; }
    if defaulted(v.get("transitive_specs")).is_some_and(|t| !matches!(t, Value::Arr(_))) { return false; }
    let Some(c) = defaulted(v.get("project_context")) else { return true; };
    if !matches!(c, Value::Obj(_)) || !hash_field(c, "context_hash") || !nonempty(c, "project_root") { return false; }
    match string(c, "type").and_then(ContextKind::parse) {
        Some(ContextKind::NpmOverrides) => nonempty(c, "overrides_source") && hash_field(c, "overrides_sha256")
            && matches!(c.get("overrides"), Some(Value::Obj(o)) if !o.is_empty()),
        Some(kind @ (ContextKind::YarnLockfile | ContextKind::YarnMaterialized)) => {
            if !nonempty(c, "manifest_path") || !nonempty(c, "lockfile_path") || !hash_field(c, "input_sha256")
                || !matches!(c.get("input_files"), Some(Value::Arr(a)) if !a.is_empty()) { return false; }
            if kind == ContextKind::YarnLockfile { return true; }
            let Some(m) = c.get("materialization") else { return false; };
            matches!(m, Value::Obj(_)) && nonempty(m, "candidate") && string(m, "input_sha256") == string(c, "input_sha256")
                && hash_field(m, "generated_lockfile_sha256")
                && string(m, "command") == Some(MATERIALIZE_COMMAND)
                && string(m, "isolation") == Some(MATERIALIZE_ISOLATION)
        }
        None => false,
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
    /// The union with another index: a package either one approves is
    /// approved. The post hook joins the approvals with no project context
    /// and the approvals of the project it judges, each read by
    /// `effect_index` under its own context rule.
    pub fn merge(&mut self, other: EffectIndex) {
        self.approved.extend(other.approved);
        self.entries.extend(other.entries);
    }
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
    let source = concat!(env!("CARGO_MANIFEST_DIR"), "/../lib/ledger/ledger.sh");
    assert_eq!(std::fs::read_to_string(source).unwrap(), cli, "CLI file is the compiled source");
    let script = format!("source \"$1\"\nprintf '%s\\n' \"$SAFEDEPS_HOME\" \"$SAFEDEPS_LEDGER_DIR\" \"$SAFEDEPS_LEDGER_DEFAULT_TTL_DAYS\"\nh=$(safedeps_ledger_hash npm @scope/pkg 1.2.3 context)\nprintf '%s\\n' \"$h\" \"$(safedeps_ledger_hash_to_filename \"$h\")\"");
    let run = |home: &str| {
        let out = std::process::Command::new("/bin/bash").env_clear()
            .env("PATH", "/usr/bin:/bin").env("HOME", "fixture home").env("SAFEDEPS_HOME", home)
            .args(["-c", &script, "ledger-contract", source]).output().unwrap();
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

#[cfg(test)]
#[test]
fn context_kinds_match_cli() {
    let kinds = include_str!("../../lib/ledger/context-kinds.sh");
    let named = [(ContextKind::NpmOverrides, "NPM_OVERRIDES"), (ContextKind::YarnLockfile, "YARN_LOCKFILE"), (ContextKind::YarnMaterialized, "YARN_MATERIALIZED")];
    assert!(ContextKind::ALL.iter().all(|kind| named.iter().any(|(k, _)| k == kind)), "every core kind is named here");
    for (kind, constant) in named {
        assert!(kinds.lines().any(|line| line == format!("SAFEDEPS_CONTEXT_{constant}=\"{}\"", kind.as_str())), "CLI declares context kind {}", kind.as_str());
    }
    assert!(kinds.lines().any(|line| line == format!("SAFEDEPS_CONTEXT_MATERIALIZE=({MATERIALIZE_COMMAND})")), "CLI materialization command");
    assert!(kinds.lines().any(|line| line == format!("SAFEDEPS_CONTEXT_MATERIALIZE_ISOLATION=\"{MATERIALIZE_ISOLATION}\"")), "CLI materialization isolation");
    // The kinds that scope an approval are listed twice in the declaration,
    // as jq's context_scopes and as the shell's case; both name the core's
    // three kinds and nothing else.
    let scopes = kinds.split("def context_scopes:").nth(1).and_then(|rest| rest.split(';').next()).unwrap();
    let case = kinds.lines().find(|line| line.trim_start().starts_with("\"${SAFEDEPS_CONTEXT_")).unwrap();
    for (_, constant) in named {
        assert!(scopes.contains(&format!(". == context_{}", constant.to_ascii_lowercase())), "context_scopes names {constant}");
        assert!(case.contains(&format!("\"${{SAFEDEPS_CONTEXT_{constant}}}\"")), "safedeps_context_kind_scopes names {constant}");
    }
    assert_eq!((scopes.matches(". == ").count(), case.matches('|').count() + 1), (named.len(), named.len()), "the scoping kinds are the core's: {scopes} / {case}");
    // What the two predicates answer is the core's answer, for every type the
    // declaration names and one it does not: a second definition, a changed
    // operator or a changed return shows here, whatever its text.
    let types: Vec<&str> = kinds.lines().filter(|line| line.starts_with("SAFEDEPS_CONTEXT_") || line.starts_with("SAFEDEPS_SOURCE_"))
        .filter_map(|line| line.split_once("=\"").map(|(_, v)| v.trim_end_matches('"'))).filter(|v| !v.contains('$')).chain(["other"]).collect();
    assert_eq!(types.len(), 8, "the declared types and one more: {types:?}");
    let script = format!("{kinds}\nfor t in \"$@\"; do if safedeps_context_kind_scopes \"$t\"; then printf 1; else printf 0; fi; jq -jn --arg t \"$t\" \"$SAFEDEPS_CONTEXT_JQ\"'if ($t | context_scopes) then 1 else 0 end'; done");
    let out = std::process::Command::new("/bin/bash").env_clear().env("PATH", std::env::var_os("PATH").unwrap_or_default())
        .arg("-c").arg(&script).arg("context-contract").args(&types).output().unwrap();
    assert!(out.status.success(), "CLI scoping predicates: {}", String::from_utf8_lossy(&out.stderr));
    let core: String = types.iter().map(|t| if ContextKind::parse(t).is_some() { "11" } else { "00" }).collect();
    assert_eq!(String::from_utf8(out.stdout).unwrap(), core, "the shell's and jq's scoping kinds are the core's, for {types:?}");
    // A closure source reaches its writer only as a declaration: the type is
    // its second argument and the reason, where there is one, its fourth, so
    // a word there, misspelt or not, is a second truth.
    use crate::cli_text::{bare_uses, code_lines, definitions, word, CLI_FILES};
    let closure = include_str!("../../lib/npm/closure.sh");
    let calls: Vec<Vec<&str>> = closure.lines().map(str::trim_start).filter(|line| !line.starts_with('#'))
        .filter_map(|line| line.split_once("safedeps_npm_write_source \"").map(|(_, rest)| rest.split_whitespace().collect())).collect();
    assert_eq!(calls.len(), 8, "the writer's calls");
    let declared = |arg: &str, prefixes: &[&str]| prefixes.iter().any(|p| arg.starts_with(&format!("\"${{{p}"))) && arg.ends_with("}\"");
    for args in &calls {
        assert!(declared(args[1], &["SAFEDEPS_SOURCE_", "SAFEDEPS_CONTEXT_"]), "a closure source type is a declaration: {args:?}");
        assert!(args.len() < 4 || declared(args[3], &["SAFEDEPS_NPM_"]), "a closure source's reason is a declaration: {args:?}");
    }
    // Each name the declarations give stands in the CLI files
    // (cli_text::CLI_FILES) only in its declaration and as a whole read, so
    // no assignment of any form follows it; the shell's scoping predicate and
    // each jq function they define are defined there and nowhere else.
    let npm: Vec<&str> = closure.lines().filter(|line| line.starts_with("SAFEDEPS_NPM_")).collect();
    assert_eq!(npm.len(), 5, "the closure source's declarations: {npm:?}");
    let declarations: Vec<&str> = kinds.lines().filter(|line| line.starts_with("SAFEDEPS_")).chain(npm.iter().copied()).collect();
    for line in &declarations {
        let name = line.split_once('=').unwrap().0;
        let uses: Vec<&str> = CLI_FILES.iter().flat_map(|(_, text)| bare_uses(text, name)).collect();
        assert_eq!(uses, [*line], "{name} stands only in its declaration and as a whole read");
    }
    let defined = |name: &str| -> Vec<&str> { CLI_FILES.iter().flat_map(|(_, text)| definitions(text, name)).collect() };
    assert_eq!(defined("safedeps_context_kind_scopes"), ["safedeps_context_kind_scopes() {"], "the shell's scoping predicate is defined once");
    for line in declarations.iter().filter(|line| line.contains("_JQ=")) {
        for def in line.split("def ").skip(1).map(|rest| rest.split(|c: char| !(c.is_ascii_alphanumeric() || c == '_')).next().unwrap()) {
            assert_eq!(defined(def), [*line], "jq's {def} is defined once, in its declaration");
        }
    }
    // The fields that carry the reason are SAFEDEPS_NPM_SOURCE_JQ's: outside
    // it a field's name stands in no file of the CLI but as prose (cli_text),
    // whatever its form. Inside it the writer and the readers name each field
    // once each, so what the readers read back is what the writer wrote.
    for (file, text) in CLI_FILES {
        for field in ["project_resolution_status", "approval_scope"] {
            let lines: Vec<&str> = code_lines(text, field, word).into_iter()
                .filter(|line| !line.starts_with("SAFEDEPS_NPM_SOURCE_JQ=")).collect();
            assert!(lines.is_empty(), "{file} spells the closure source's {field}: {lines:?}");
        }
    }
    let source_jq: Vec<&str> = closure.lines().filter(|line| line.starts_with("SAFEDEPS_NPM_SOURCE_JQ=")).collect();
    let script = format!("{}\njq -cn \"$SAFEDEPS_NPM_SOURCE_JQ\"'[(source_deny_only(\"why\"; \"scope\"), source_deny_only(\"\"; \"scope\")) | [keys_unsorted, source_resolution_status, source_approval_scope]]'", source_jq.join("\n"));
    let out = std::process::Command::new("/bin/bash").env_clear().env("PATH", std::env::var_os("PATH").unwrap_or_default())
        .args(["-c", &script, "source-contract"]).output().unwrap();
    assert!(out.status.success(), "CLI closure source fields: {}", String::from_utf8_lossy(&out.stderr));
    assert_eq!(String::from_utf8(out.stdout).unwrap(), "[[[\"project_resolution_status\",\"approval_scope\"],\"why\",\"scope\"],[[],null,null]]\n",
        "the closure source's readers read what its writer writes");
    // The shell reader reads what the writer wrote, on both of the writer's
    // branches: a read misspelt is a word no reading of the text knows.
    let function = |name: &str| -> String {
        let head = format!("{name}() {{");
        let body = closure.split_once(&head).unwrap().1.split_once("\n}").unwrap().0;
        format!("{head}{body}\n}}\n")
    };
    let script = format!("{}\n{}{}d=$(mktemp -d) && trap 'rm -rf \"$d\"' EXIT && cd \"$d\" && printf '{{}}' > ctx || exit 1\n\
        for c in '' ctx; do for r in why ''; do safedeps_npm_write_source out t \"$c\" \"$r\"; if safedeps_npm_source_is_deny_only out; then printf 1; else printf 0; fi; done; done",
        npm.join("\n"), function("safedeps_npm_write_source"), function("safedeps_npm_source_is_deny_only"));
    let out = std::process::Command::new("/bin/bash").env_clear().env("PATH", std::env::var_os("PATH").unwrap_or_default())
        .args(["-c", &script, "source-reader"]).output().unwrap();
    assert!(out.status.success(), "CLI closure source reader: {}", String::from_utf8_lossy(&out.stderr));
    assert_eq!(String::from_utf8(out.stdout).unwrap(), "1010", "a closure source the writer made deny-only reads as deny-only, and no other");
    // A kind, a source type, the materialization or a closure source's reason
    // is spelled in its declaration and nowhere else in the CLI files. A
    // spelling counts as a word, so `fixture` inside
    // `safedeps_npm_fixture_closure` is not one. A spelling with a hyphen or
    // a space is no word of prose, so it counts in every line, comments
    // included; a plain word, and the reasons' words, which the comments
    // use, count wherever they stand in code (cli_text), whatever the form.
    let mut spellings: Vec<(String, bool)> = kinds.lines()
        .filter_map(|line| line.strip_prefix("SAFEDEPS_").and_then(|line| line.split_once('=')))
        .filter_map(|(_, value)| value.strip_prefix('"').and_then(|v| v.strip_suffix('"')))
        .filter(|value| !value.contains('$')).map(|value| (value.into(), value.bytes().all(|b| b.is_ascii_lowercase()))).collect();
    spellings.push((MATERIALIZE_COMMAND.into(), false));
    assert_eq!(spellings.len(), 8, "the declared spellings: {spellings:?}");
    let reasons: Vec<(String, bool)> = npm.iter().filter_map(|line| line.split_once("=\"")).map(|(_, v)| (v.trim_end_matches('"').into(), true)).collect();
    assert_eq!(reasons.len(), 4, "the closure source's reasons: {reasons:?}");
    spellings.extend(reasons);
    let hyphened = |b: Option<&u8>| b.is_some_and(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-'));
    let part = |b: u8| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-');
    for (file, text) in CLI_FILES {
        for (spelling, plain) in &spellings {
            let lines: Vec<&str> = if *plain { code_lines(text, spelling, part) } else {
                text.lines().filter(|line| line.match_indices(spelling.as_str()).any(|(at, _)|
                    !hyphened(line.as_bytes().get(at.wrapping_sub(1))) && !hyphened(line.as_bytes().get(at + spelling.len())))).collect()
            };
            let lines: Vec<&str> = lines.into_iter().filter(|line| !declarations.contains(line)).collect();
            assert!(lines.is_empty(), "{file} spells {spelling} outside its declaration: {lines:?}");
        }
    }
}

/// The CLI's approval predicate and `valid` give one answer: the base
/// approval, each field of it and of each context kind set to each of a list
/// of values or removed, and a few texts only a parser sees.
#[cfg(test)]
#[test]
fn valid_matches_cli_predicate() {
    use std::io::Write;
    fn parse(text: &str) -> Value { json::parse_one(text.as_bytes()).unwrap() }
    fn dump(v: &Value) -> String { jq::compact(&jq::from_value(v)) }
    fn keys(v: &Value) -> Vec<String> { match v { Value::Obj(o) => o.iter().map(|(k, _)| String::from_utf8(k.clone()).unwrap()).collect(), _ => Vec::new() } }
    fn put(v: &Value, path: &[&str], value: Option<&Value>) -> Value {
        let mut v = v.clone();
        let mut at = &mut v;
        for key in &path[..path.len() - 1] {
            let Value::Obj(o) = at else { unreachable!() };
            at = &mut o.iter_mut().find(|(k, _)| k == key.as_bytes()).unwrap().1;
        }
        let Value::Obj(o) = at else { unreachable!() };
        let key = path[path.len() - 1].as_bytes().to_vec();
        match value { Some(x) => json::set(o, key, x.clone()), None => o.retain(|(k, _)| *k != key) }
        v
    }
    let values: Vec<Option<Value>> = std::iter::once(None)
        .chain(["null", "false", "true", "0", "1", "\"\"", "\"x\"", "\"sha256\"", "\"sha256:\"", "\"sha256:x\"", "[]", "[1]", "{}", "{\"a\":1}"].map(|t| Some(parse(t)))).collect();
    let mut cases: Vec<(String, String)> = Vec::new();
    let vary = |cases: &mut Vec<(String, String)>, label: &str, v: &Value, path: &[&str], with: &[Option<Value>]| {
        for x in with { cases.push((format!("{label} {}={}", path.join("."), x.as_ref().map_or("missing".into(), dump)), dump(&put(v, path, x.as_ref())))); }
    };
    let base = parse(r#"{"hash":"sha256:aa","ecosystem":"npm","package":"p","version":"1.0.0","version_range":"^1","approved_at":"2020-01-01T00:00:00Z","expires_at":"2099-01-01T00:00:00Z","approved_by":"cli","evidence":{},"transitive_specs":[]}"#);
    let overrides = parse(&format!(r#"{{"type":"{}","context_hash":"sha256:c","project_root":"/r","overrides_source":"/r/package.json","overrides_sha256":"sha256:o","overrides":{{"x":"1"}}}}"#, ContextKind::NpmOverrides.as_str()));
    let lockfile = parse(&format!(r#"{{"type":"{}","context_hash":"sha256:c","project_root":"/r","manifest_path":"/r/package.json","lockfile_path":"/r/yarn.lock","resolutions_sha256":"sha256:r","lockfile_sha256":"sha256:l","input_sha256":"sha256:i","input_files":[{{"path":"package.json","sha256":"sha256:f"}}]}}"#, ContextKind::YarnLockfile.as_str()));
    let materialization = parse(&format!(r#"{{"candidate":"p@npm:1.0.0","input_sha256":"sha256:i","generated_lockfile_sha256":"sha256:g","command":"{MATERIALIZE_COMMAND}","isolation":"{MATERIALIZE_ISOLATION}"}}"#));
    let materialized = put(&put(&lockfile, &["type"], Some(&Value::Str(ContextKind::YarnMaterialized.as_str().into()))), &["materialization"], Some(&materialization));
    cases.push(("base".into(), dump(&base)));
    for key in keys(&base) { vary(&mut cases, "base", &base, &[&key], &values); }
    vary(&mut cases, "base", &base, &["project_context"], &values);
    for text in ["null", "\"x\"", "1", "[]", "{}"] { cases.push((format!("top {text}"), text.into())); }
    let types: Vec<Option<Value>> = ContextKind::ALL.iter().map(|k| k.as_str())
        .chain(["fixture", "npm-package-probe", "yarn-project-candidate-materialization"])
        .map(|t| Some(Value::Str(t.into()))).chain([Some(Value::Null), Some(parse("1")), None]).collect();
    let mut complete = Vec::new();
    for (name, context) in [("overrides", &overrides), ("lockfile", &lockfile), ("materialized", &materialized)] {
        let approval = put(&base, &["project_context"], Some(context));
        complete.push(dump(&approval));
        cases.push((format!("{name} complete"), dump(&approval)));
        for key in keys(context) { vary(&mut cases, name, &approval, &["project_context", &key], &values); }
        vary(&mut cases, name, &approval, &["project_context", "type"], &types);
    }
    let materialized_approval = put(&base, &["project_context"], Some(&materialized));
    for key in keys(&materialization) { vary(&mut cases, "materialized", &materialized_approval, &["project_context", "materialization", &key], &values); }
    let mut union = overrides.clone();
    for key in keys(&lockfile).into_iter().filter(|k| k != "type") { union = put(&union, &[&key], lockfile.get(&key)); }
    cases.push(("overrides with the lockfile fields".into(), dump(&put(&base, &["project_context"], Some(&union)))));
    let text = dump(&base);
    cases.push(("a second hash, last".into(), format!("{},\"hash\":5}}", &text[..text.len() - 1])));
    cases.push(("a second hash, first".into(), format!("{{\"hash\":5,{}", &text[1..])));
    cases.push(("an escaped input hash".into(), complete[2].replacen("\"input_sha256\":\"sha256:i\",\"input_files\"", "\"input_sha256\":\"\\u0073ha256:i\",\"input_files\"", 1)));
    cases.push(("a NUL package".into(), text.replacen("\"package\":\"p\"", "\"package\":\"\\u0000\"", 1)));
    for text in &complete { assert!(valid(&parse(text)), "complete context is valid: {text}"); }

    let source = concat!(env!("CARGO_MANIFEST_DIR"), "/../lib/ledger/ledger.sh");
    let mut child = std::process::Command::new("/bin/bash").env_clear()
        .env("PATH", std::env::var_os("PATH").unwrap_or_default()).env("HOME", "fixture home")
        .args(["-c", "source \"$1\"\nexec jq -c \"${SAFEDEPS_LEDGER_JQ_PREDICATE}\"' try ledger_is_valid catch \"error\"'", "ledger-predicate", source])
        .stdin(std::process::Stdio::piped()).stdout(std::process::Stdio::piped()).stderr(std::process::Stdio::piped()).spawn().unwrap();
    child.stdin.take().unwrap().write_all(cases.iter().map(|(_, t)| format!("{t}\n")).collect::<String>().as_bytes()).unwrap();
    let out = child.wait_with_output().unwrap();
    assert!(out.status.success(), "CLI predicate: {}", String::from_utf8_lossy(&out.stderr));
    let stdout = String::from_utf8(out.stdout).unwrap();
    let answers: Vec<&str> = stdout.lines().collect();
    assert_eq!(answers.len(), cases.len(), "one CLI answer per case");
    let differ: Vec<String> = cases.iter().zip(&answers).filter_map(|((label, text), answer)| {
        let core = valid(&parse(text));
        (*answer != if core { "true" } else { "false" }).then(|| format!("{label}: core {core}, CLI {answer}"))
    }).collect();
    assert!(differ.is_empty(), "{} of {} cases differ:\n{}", differ.len(), cases.len(), differ.join("\n"));
}
