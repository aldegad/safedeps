//! SAFEDEPS_NPM_FETCH_JQ, shared by pre and post. These functions read npm's
//! answers; they never infer a registry when npm gave no answer.
use crate::{ere::Regex, jq, json::Value};

const PUBLIC_REGISTRY_RE: &str = r"^https://registry\.(npmjs\.org|yarnpkg\.com)/";

fn text(v: Option<&Value>) -> Option<&str> { v.and_then(Value::as_str) }
fn null(v: Option<&Value>) -> bool { v.is_none_or(|v| matches!(v, Value::Null)) }
fn defaulted(v: Option<&Value>) -> Option<&Value> { v.filter(|v| !matches!(v, Value::Null | Value::Bool(false))) }
fn rendered(v: &Value) -> String { v.as_str().map(str::to_string).unwrap_or_else(|| jq::compact(&jq::from_value(v))) }

/// sd_host. The optional user information consumes at most one '@', as the
/// original pattern does; an unmatched '[' uses the ordinary-host branch.
pub fn host(url: &str) -> String {
    let Some((scheme, rest)) = url.split_once("://") else { return String::new(); };
    if !scheme.as_bytes().first().is_some_and(u8::is_ascii_alphabetic)
        || !scheme.bytes().all(|c| c.is_ascii_alphanumeric() || b"+.-".contains(&c)) { return String::new(); }
    let mut rest = rest;
    let auth = rest.split(['/', '?', '#']).next().unwrap_or("");
    if let Some(at) = auth.find('@') { rest = &rest[at+1..]; }
    if rest.starts_with('[') {
        if let Some(end) = rest.find(']') { return rest[..=end].to_ascii_lowercase(); }
    }
    rest.split(['/', ':', '?', '#']).next().unwrap_or("").to_ascii_lowercase()
}

/// sd_registry_public($f). This is the public-registry rule in ask.sh, not
/// a guess from the registry currently configured in this process.
pub fn registry_public(registry: Option<&Value>, facts: &Value) -> bool {
    let Some(registry) = text(registry) else { return false; };
    let s = if registry.ends_with('/') { registry.to_string() } else { format!("{}/", registry) };
    Regex::new(PUBLIC_REGISTRY_RE, true).expect("public registry").is_match(s.as_bytes())
        || (!null(facts.get("test_registry")) && text(facts.get("test_registry")) == Some(s.as_str()))
}

#[derive(Clone, Eq, PartialEq, Ord, PartialOrd)]
pub enum Origin {
    // Variant order is jq's object order: sorted keys before values, hence
    // unscoped {registry,replace}, scoped {registry,replace,scope}, unknown.
    Registry { registry: Option<String>, replace: Option<String> },
    Scoped { registry: Option<String>, replace: Option<String>, scope: String },
    Unknown(String),
}
impl Origin {
    pub fn value(&self) -> Value {
        let s = |v: &Option<String>| v.as_deref().map(jq::s).unwrap_or(jq::J::Null);
        jq::into_value(match self {
            Self::Unknown(why) => jq::obj(vec![("unknown", jq::s(why))]),
            Self::Registry { registry, replace } => jq::obj(vec![("registry", s(registry)), ("replace", s(replace))]),
            Self::Scoped { registry, replace, scope } => jq::obj(vec![("registry", s(registry)), ("replace", s(replace)), ("scope", jq::s(scope))]),
        })
    }
    pub fn problem(&self) -> String {
        match self {
            Self::Unknown(why) => why.clone(),
            Self::Registry { registry, replace } => format!("npm fetches it from the registry {} (replace-registry-host={})", registry.as_deref().unwrap_or("it will not print"), replace.as_deref().unwrap_or("not printed")),
            Self::Scoped { registry, replace, scope } => format!("npm has {}:registry={} (replace-registry-host={})", scope, registry.as_deref().unwrap_or("null"), replace.as_deref().unwrap_or("not printed")),
        }
    }
}
const NO_ANSWER: &str = "safedeps has no answer from npm about the registry";
fn maybe_string(v: Option<&Value>) -> Result<Option<String>, ()> {
    match v { None | Some(Value::Null) => Ok(None), Some(Value::Str(s)) => Ok(Some(jq::text(s))), _ => Err(()) }
}
fn scope(url: &str) -> Option<&str> {
    let (scheme, rest) = url.split_once("://")?;
    if scheme.is_empty() || scheme.contains(':') { return None; }
    let (authority, path) = rest.split_once('/')?;
    if authority.is_empty() { return None; }
    let (s, _) = path.split_once('/')?;
    (s.starts_with('@') && s.len() > 1).then_some(s)
}

/// sd_fetch_origin. Err is a malformed fact that jq's program cannot read.
pub fn fetch_origin(facts: &Value, url: &str) -> Result<Option<Origin>, ()> {
    if !matches!(facts, Value::Obj(_)) { return Ok(Some(Origin::Unknown(NO_ANSWER.into()))); }
    if let Some(why) = facts.get("unknown").filter(|v| !matches!(v, Value::Null)) {
        return Ok(Some(Origin::Unknown(rendered(why))));
    }
    let replace = maybe_string(defaulted(facts.get("replace")))?;
    let swapped = match replace.as_deref() {
        None | Some("always") => true,
        Some("never") => false,
        Some(r) => (if r == "npmjs" { "registry.npmjs.org".into() } else if r.contains("://") { host(r) } else { r.to_ascii_lowercase() }) == host(url),
    };
    if !swapped { return Ok(None); }
    if !registry_public(facts.get("registry"), facts) {
        return Ok(Some(Origin::Registry { registry: maybe_string(facts.get("registry"))?, replace }));
    }
    if let Some(scope) = scope(url) {
        let registry = match facts.get("scopes") {
            None | Some(Value::Null) => None,
            Some(v @ Value::Obj(_)) => defaulted(v.get(scope)),
            _ => return Err(()),
        };
        if registry.is_some() && !registry_public(registry, facts) {
            return Ok(Some(Origin::Scoped { registry: maybe_string(registry)?, replace, scope: scope.into() }));
        }
    }
    Ok(None)
}

pub fn fetch_origins(facts: &Value, url: &str) -> Result<Vec<Origin>, ()> {
    let Value::Arr(facts) = facts else { return Ok(vec![Origin::Unknown(NO_ANSWER.into())]); };
    if facts.is_empty() { return Ok(vec![Origin::Unknown(NO_ANSWER.into())]); }
    let mut out = Vec::new();
    for f in facts { if let Some(o) = fetch_origin(f, url)? { out.push(o); } }
    out.sort(); out.dedup(); Ok(out)
}
pub fn fetch_problems(facts: &Value, url: &str) -> Result<Vec<String>, ()> {
    let mut out: Vec<String> = fetch_origins(facts, url)?.iter().map(Origin::problem).filter(|s| !s.is_empty()).collect();
    out.sort(); out.dedup(); Ok(out)
}
pub fn fetch_known_problems(facts: &Value, url: &str) -> Result<Vec<String>, ()> {
    let Value::Arr(facts) = facts else { return Ok(Vec::new()); };
    let mut out = Vec::new();
    for f in facts {
        if matches!(f, Value::Obj(_)) && null(f.get("unknown")) {
            if let Some(o) = fetch_origin(f, url)? { let p = o.problem(); if !p.is_empty() { out.push(p); } }
        }
    }
    out.sort(); out.dedup(); Ok(out)
}

#[cfg(test)]
#[test]
fn public_registry_rule_matches_cli() {
    let definitions: Vec<_> = include_str!("../../../lib/npm/ask.sh").lines()
        .filter_map(|line| line.strip_prefix("SAFEDEPS_NPM_PUBLIC_REGISTRY_RE="))
        .collect();
    assert_eq!(definitions.len(), 1, "the CLI must define one public-registry pattern");
    let pattern = definitions[0].strip_prefix('\'').and_then(|s| s.strip_suffix('\''))
        .expect("the CLI pattern must be a single-quoted literal");
    assert_eq!(pattern, PUBLIC_REGISTRY_RE, "CLI and hook public-registry patterns differ");

    let cases = [
        ("https://registry.npmjs.org/", true, true),
        ("HTTPS://REGISTRY.NPMJS.ORG/pkg", true, true),
        ("hTtPs://ReGiStRy.YaRnPkG.cOm/pkg", true, true),
        ("https://registry.npmjs.org.example/", false, false),
        ("file:registry.npmjs.org/pkg", false, false),
        ("http://registry.npmjs.org/", false, false),
        ("https://registry.npmjs.org", false, true),
    ];
    let output = std::process::Command::new("/bin/bash")
        .env_clear().env("PATH", "/usr/bin:/bin").env("LC_ALL", "C")
        .current_dir(std::path::Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap())
        .args(["-c", r#"
set -euo pipefail
source lib/npm/ask.sh
source lib/npm/closure.sh
shopt -u nocasematch
for url do
    if safedeps_npm_public_registry_url "$url"; then printf 'true\n'; else printf 'false\n'; fi
done
"#, "public-registry-test"])
        .args(cases.iter().map(|(url, _, _)| *url))
        .output().expect("run the CLI public-registry reader");
    assert!(output.status.success(), "CLI reader failed: {}", String::from_utf8_lossy(&output.stderr));
    let stdout = String::from_utf8(output.stdout).unwrap();
    let answers: Vec<_> = stdout.lines().collect();
    assert_eq!(answers.len(), cases.len(), "one CLI answer per URL");
    for ((url, cli, hook), answer) in cases.into_iter().zip(answers) {
        assert_eq!(answer, if cli { "true" } else { "false" }, "CLI: {url}");
        let registry = jq::into_value(jq::s(url));
        assert_eq!(registry_public(Some(&registry), &Value::Null), hook, "hook: {url}");
    }
}
