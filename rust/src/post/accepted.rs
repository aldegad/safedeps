//! Which lock records an accepted source stands for: an entry of the
//! accepted-source ledger (`crate::sources`), or this call's own
//! `SAFEDEPS_ACCEPT_SOURCE`, which becomes entries when the install is kept.
//!
//! One judgment, read in four places. The effect gate does not call a covered
//! package unapproved, and the advisories its entry names do not count
//! against it (`effect::check`). The source check gives no reason for a URL
//! every record of which is covered (`Npm::sources`). The record of withheld
//! bytes leaves out bytes an entry covers (`Npm::record`). The rebuild check
//! counts a covered record as an approved one from the public registry, and
//! does not hold it back for a record of withheld bytes (`tree::judge`): the
//! entry is the person's release of exactly those bytes under exactly that
//! URL.
//!
//! A record is covered only by all four of its values: `resolved`,
//! `integrity`, the package name and the version, each the same bytes as the
//! entry's. A package is covered only where every record of it, in both npm
//! records, is covered. So a record of the same name and version from
//! another source, the same URL with other bytes, and the same bytes under
//! another URL or another name are each judged as before.
use super::{closure, jv, lockfile::Records, report::cat, sh};
use crate::{json::Value, sources::{self, Entry, Index}};
use std::{path::Path, time::{Duration, Instant}};
type W = Vec<u8>;

/// One package record of an npm record, in the installed tree and not a link.
#[derive(Clone, Debug)]
pub struct Node {
    pub record: &'static str,
    pub url: Option<W>,
    pub integrity: Option<W>,
    pub name: W,
    pub version: W,
}

/// The name the effect gate gives a record: its `name`, or the name its key
/// gives (`closure::name_from_path`). Empty where neither names one.
pub fn record_name(key: &[u8], rec: &Value) -> W {
    match jv::field(rec, "name") {
        Ok(Value::Str(n)) if !n.is_empty() => n.clone(),
        _ => match closure::name_from_path(key) { Value::Str(n) => n, _ => Vec::new() },
    }
}

fn string(rec: &Value, key: &str) -> Option<W> {
    match jv::field(rec, key) {
        Ok(Value::Str(s)) if !s.is_empty() => Some(s.clone()),
        _ => None,
    }
}

/// The advisories a covered package may have: any (this call accepts what
/// OSV names now), or those its entries name.
#[derive(Clone, Debug, PartialEq)]
pub enum Allowed {
    Any,
    Listed(Vec<W>),
}

/// Why a URL an entry or this call names does not cover a record of it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Miss {
    NoIntegrity,
    OtherBytes,
    OtherPackage,
}

#[derive(Default)]
pub struct Sources {
    /// The ledger, or why it could not be read.
    pub ledger: Option<Result<Index, W>>,
    /// This call's `SAFEDEPS_ACCEPT_SOURCE`: the URL, and who decided and why.
    pub bypass: Option<(W, W)>,
    nodes: Vec<Node>,
    /// An npm record that could not be read: then no record is covered.
    unread: bool,
    /// The advisory ids OSV named for each package this call covers, as the
    /// effect gate found them: they go into the entries it writes.
    pub found: Vec<(W, W, Vec<W>)>,
    /// The entries this call wrote, which cover from then on.
    pub written: Vec<Entry>,
}

/// How long a post run waits for the ledger's lock: no longer than its own
/// deadline leaves, less a second for what comes after.
pub fn wait(until: Instant) -> Duration {
    until.saturating_duration_since(Instant::now()).saturating_sub(Duration::from_secs(1)).min(sources::LOCK_WAIT)
}

impl Sources {
    /// The ledger of `home` and the package records of the project's two
    /// npm records, as the post hook read them once (post::lockfile): the
    /// lockfile npm reads and the tree record. A record that could not be
    /// read leaves every record uncovered. The ledger is read only where
    /// some record names a URL an entry could name, or the call has an
    /// override: an install from the public registry alone never waits on
    /// its lock.
    pub fn read(home: &Path, records: &Records, bypass: Option<(W, W)>, until: Instant) -> Self {
        let mut s = Sources { bypass, unread: records.unread.is_some(), ..Default::default() };
        for record in records.each() {
            let (rel, st) = (record.rel, &record.stream);
            if st.failed { s.unread = true; continue }
            for v in &st.values {
                let Ok(Value::Obj(entries)) = jv::field(v, "packages") else { continue };
                for (key, rec) in entries {
                    if !jv::in_tree(key) || !matches!(rec, Value::Obj(_)) || matches!(jv::field(rec, "link"), Ok(Value::Bool(true))) { continue }
                    s.nodes.push(Node { record: rel, url: string(rec, "resolved"), integrity: string(rec, "integrity"),
                        name: record_name(key, rec), version: string(rec, "version").unwrap_or_default() });
                }
            }
        }
        let wanted = s.bypass.is_some() || s.nodes.iter().any(|n| n.url.as_deref().is_some_and(|u| sources::url_acceptable(u).is_ok()));
        if wanted {
            s.ledger = Some(sources::index(home, wait(until)).map_err(|f| {
                cat(&[b"the accepted-source ledger ", sh::bytes(&sources::path(home)), b" could not be read (", &f.text(), b")"])
            }));
        }
        s
    }

    /// Why the ledger was wanted and could not be read.
    pub fn unreadable(&self) -> Option<&[u8]> {
        match &self.ledger { Some(Err(why)) => Some(why), _ => None }
    }

    fn entries(&self) -> impl Iterator<Item = &Entry> {
        let standing = match &self.ledger { Some(Ok(ix)) => ix.entries.as_slice(), _ => &[] };
        standing.iter().chain(self.written.iter())
    }

    /// The entries that stand for this record's four values.
    fn matching<'a>(&'a self, url: &'a [u8], integrity: &'a [u8], name: &'a [u8], version: &'a [u8]) -> impl Iterator<Item = &'a Entry> + 'a {
        self.entries().filter(move |e| e.covers(url, integrity, name, version))
    }

    /// An entry that stands, or one this call wrote, covers the record.
    pub fn entry_covers(&self, url: &[u8], integrity: &[u8], name: &[u8], version: &[u8]) -> bool {
        !self.unread && self.matching(url, integrity, name, version).next().is_some()
    }

    /// This call's override covers the record: it names its URL, and the
    /// record has an integrity to bind the acceptance to.
    fn bypass_covers(&self, url: &[u8], integrity: Option<&[u8]>) -> bool {
        !self.unread && integrity.is_some() && self.bypass.as_ref().is_some_and(|(u, _)| u == url)
    }

    fn node_allowed(&self, n: &Node) -> Option<Allowed> {
        let (Some(url), Some(integrity)) = (n.url.as_deref(), n.integrity.as_deref()) else { return None };
        if self.bypass_covers(url, Some(integrity)) { return Some(Allowed::Any) }
        if !self.entry_covers(url, integrity, &n.name, &n.version) { return None }
        let mut ids: Vec<W> = self.matching(url, integrity, &n.name, &n.version).flat_map(|e| e.advisories.iter().cloned()).collect();
        ids.sort();
        ids.dedup();
        Some(Allowed::Listed(ids))
    }

    /// The package is covered: it has a record, and every record of it is.
    /// The advisories it may have are those every one of its records allows.
    pub fn package(&self, name: &[u8], version: &[u8]) -> Option<Allowed> {
        let mut allowed = Allowed::Any;
        let mut any = false;
        for n in self.nodes.iter().filter(|n| n.name == name && n.version == version) {
            any = true;
            match (self.node_allowed(n)?, &allowed) {
                (Allowed::Any, _) => {}
                (Allowed::Listed(ids), Allowed::Any) => allowed = Allowed::Listed(ids),
                (Allowed::Listed(ids), Allowed::Listed(have)) => {
                    allowed = Allowed::Listed(have.iter().filter(|id| ids.contains(id)).cloned().collect())
                }
            }
        }
        any.then_some(allowed)
    }

    /// Every record of the URL is covered.
    pub fn url_covered(&self, url: &[u8]) -> bool {
        let mut of = self.nodes.iter().filter(|n| n.url.as_deref() == Some(url)).peekable();
        of.peek().is_some() && of.all(|n| self.node_allowed(n).is_some())
    }

    /// Where an entry or this call names the URL and a record of it is not
    /// covered, why: the first such record has no integrity, other bytes than
    /// any entry of the URL, or bytes an entry names under another package.
    /// None where nothing names the URL.
    pub fn url_miss(&self, url: &[u8]) -> Option<(Miss, &Node)> {
        let named = self.bypass.as_ref().is_some_and(|(u, _)| u == url) || self.entries().any(|e| e.url == url);
        if !named { return None }
        let n = self.nodes.iter().find(|n| n.url.as_deref() == Some(url) && self.node_allowed(n).is_none())?;
        let Some(integrity) = n.integrity.as_deref() else { return Some((Miss::NoIntegrity, n)) };
        if self.entries().any(|e| e.url == url && e.integrity == integrity) { Some((Miss::OtherPackage, n)) } else { Some((Miss::OtherBytes, n)) }
    }

    /// The reasons an accepted source gives this install: for each URL an
    /// entry or this call names, the first record of it no accepted source
    /// covers, and why; and a ledger that was wanted and could not be read,
    /// where a record it might have covered is not covered. A URL nothing
    /// names gives no reason here: the source check and the effect gate judge
    /// it as before.
    pub fn reasons(&self, reasons: &mut Vec<W>) {
        if let Some(why) = self.unreadable() {
            if self.nodes.iter().any(|n| n.url.as_deref().is_some_and(|u| sources::url_acceptable(u).is_ok()) && self.node_allowed(n).is_none()) {
                reasons.push(cat(&[why, b", so no accepted source covers what this install brought from outside the public registry"]));
            }
        }
        let mut urls: Vec<&[u8]> = self.nodes.iter().filter_map(|n| n.url.as_deref()).collect();
        urls.sort();
        urls.dedup();
        for url in urls {
            let Some((miss, n)) = self.url_miss(url) else { continue };
            let here = cat(&[n.record.as_bytes(), b": ", &n.name, b"@", &n.version, b" from ", url]);
            reasons.push(match miss {
                Miss::NoIntegrity => cat(&[&here, b" has no integrity, so no accepted source can cover it"]),
                Miss::OtherBytes => cat(&[&here, b" has an integrity no accepted-source entry of that URL names, so its bytes are not the ones accepted"]),
                Miss::OtherPackage => cat(&[&here, b" has the integrity an accepted-source entry names under another package or version, and an entry covers only the package and version it names"]),
            });
        }
    }

    /// This call names a URL neither npm record holds.
    pub fn bypass_unmatched(&self) -> Option<&[u8]> {
        let (url, _) = self.bypass.as_ref()?;
        (!self.nodes.iter().any(|n| n.url.as_deref() == Some(url.as_slice()))).then_some(url.as_slice())
    }

    /// The record `rec` at `key` is covered by an entry that stands or one
    /// this call wrote. The rebuild check and the record of withheld bytes
    /// ask this; this call's override counts only once its entries are
    /// written.
    pub fn record_covered(&self, key: &[u8], rec: &Value) -> bool {
        let (Some(url), Some(integrity)) = (string(rec, "resolved"), string(rec, "integrity")) else { return false };
        self.entry_covers(&url, &integrity, &record_name(key, rec), &string(rec, "version").unwrap_or_default())
    }

    /// The entries this call makes: one for each record its override covers,
    /// once per four values, with the advisory ids the effect gate found for
    /// that package.
    pub fn to_write(&self, project: &[u8]) -> Vec<Entry> {
        let Some((url, reason)) = &self.bypass else { return Vec::new() };
        let mut out: Vec<Entry> = Vec::new();
        for n in &self.nodes {
            let (Some(u), Some(integrity)) = (n.url.as_deref(), n.integrity.as_deref()) else { continue };
            if u != url.as_slice() || !self.bypass_covers(u, Some(integrity)) { continue }
            if out.iter().any(|e| e.covers(u, integrity, &n.name, &n.version)) { continue }
            let mut advisories: Vec<W> = self.found.iter().filter(|(p, v, _)| *p == n.name && *v == n.version).flat_map(|(_, _, ids)| ids.iter().cloned()).collect();
            advisories.sort();
            advisories.dedup();
            out.push(Entry { url: u.to_vec(), integrity: integrity.to_vec(), package: n.name.clone(), version: n.version.clone(),
                advisories, at: Vec::new(), reason: reason.clone(), project: project.to_vec() });
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sources::{Entry, Index};

    fn entry(url: &str, integrity: &str, package: &str, version: &str, advisories: &[&str]) -> Entry {
        Entry { url: url.into(), integrity: integrity.into(), package: package.into(), version: version.into(),
            advisories: advisories.iter().map(|a| a.as_bytes().to_vec()).collect(), at: b"2026-01-02T03:04:05Z".to_vec(),
            reason: b"owner: synthetic".to_vec(), project: b"/work/p".to_vec() }
    }

    // The watch and the audit judge coverage with a jq program
    // (SAFEDEPS_NPM_ACCEPTED_JQ in lib/npm/closure.sh), and the hook with this
    // module. One lockfile with every shape the two could read apart, judged
    // by both: which packages are covered, and with which advisories.
    #[test]
    fn coverage_matches_cli() {
        let u = "https://example.test/site/-/site-1.0.0.tgz";
        let lock = format!(r#"{{"lockfileVersion":3,"packages":{{
            "": {{"name":"p"}},
            "node_modules/@s/p": {{"version":"1.0.0","resolved":"{u}","integrity":"sha512-scoped"}},
            "node_modules/half": {{"version":"1.0.0","resolved":"{u}","integrity":"sha512-half"}},
            "node_modules/x/node_modules/half": {{"version":"1.0.0","resolved":"{u}","integrity":"sha512-other"}},
            "node_modules/both": {{"version":"1.0.0","resolved":"{u}","integrity":"sha512-both1"}},
            "node_modules/y/node_modules/both": {{"version":"1.0.0","resolved":"{u}","integrity":"sha512-both2"}},
            "node_modules/linked": {{"version":"1.0.0","resolved":"{u}","integrity":"sha512-linked"}},
            "node_modules/z/node_modules/linked": {{"version":"1.0.0","resolved":"../linked","link":true}},
            "node_modules/alias": {{"name":"real","version":"1.0.0","resolved":"{u}","integrity":"sha512-real"}},
            "node_modules/w/node_modules/": {{"version":"1.0.0","resolved":"{u}","integrity":"sha512-empty"}},
            "node_modules/numeric": {{"version":1,"resolved":"{u}","integrity":"sha512-numeric"}},
            "packages/ws": {{"name":"ws","version":"1.0.0","resolved":"{u}","integrity":"sha512-ws"}},
            "node_modules/cased": {{"version":"1.0.0","resolved":"https://EXAMPLE.test/site/-/site-1.0.0.tgz","integrity":"sha512-cased"}},
            "node_modules/bare": {{"version":"1.0.0","resolved":"{u}"}}
        }}}}"#);
        let entries = vec![
            entry(u, "sha512-scoped", "@s/p", "1.0.0", &["GHSA-a"]),
            entry(u, "sha512-half", "half", "1.0.0", &["GHSA-a"]),
            entry(u, "sha512-both1", "both", "1.0.0", &["GHSA-a", "GHSA-b"]),
            entry(u, "sha512-both2", "both", "1.0.0", &["GHSA-b", "GHSA-c"]),
            entry(u, "sha512-linked", "linked", "1.0.0", &[]),
            entry(u, "sha512-real", "real", "1.0.0", &["GHSA-r"]),
            entry(u, "sha512-empty", "w", "1.0.0", &[]),
            entry(u, "sha512-numeric", "numeric", "1", &[]),
            entry(u, "sha512-ws", "ws", "1.0.0", &[]),
            entry(u, "sha512-cased", "cased", "1.0.0", &[]),
        ];
        let dir = crate::os::scratch_dir("safedeps-accepted").unwrap();
        std::fs::write(dir.join("package-lock.json"), &lock).unwrap();
        let mut s = Sources::read(&dir.join("home"), &Records::read(&dir), None, Instant::now() + Duration::from_secs(5));
        s.ledger = Some(Ok(Index { present: true, entries: entries.clone(), broken: 0 }));
        let mut names: Vec<(W, W)> = s.nodes.iter().map(|n| (n.name.clone(), n.version.clone())).collect();
        names.sort();
        names.dedup();
        let mut core: Vec<String> = names.iter().filter_map(|(n, v)| match s.package(n, v)? {
            Allowed::Listed(ids) => Some(format!("{}@{} {:?}", String::from_utf8_lossy(n), String::from_utf8_lossy(v),
                ids.iter().map(|i| String::from_utf8_lossy(i).into_owned()).collect::<Vec<_>>())),
            Allowed::Any => panic!("no override is set"),
        }).collect();
        core.sort();
        let json = |e: &Entry| format!(r#"{{"url":"{}","integrity":"{}","package":"{}","version":"{}","advisories":[{}]}}"#,
            String::from_utf8_lossy(&e.url), String::from_utf8_lossy(&e.integrity), String::from_utf8_lossy(&e.package),
            String::from_utf8_lossy(&e.version), e.advisories.iter().map(|a| format!("\"{}\"", String::from_utf8_lossy(a))).collect::<Vec<_>>().join(","));
        let entries_json = format!("[{}]", entries.iter().map(json).collect::<Vec<_>>().join(","));
        let output = std::process::Command::new("/bin/bash")
            .env_clear().env("PATH", std::env::var_os("PATH").unwrap_or_default()).env("LC_ALL", "C")
            .current_dir(Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap())
            .args(["-c", r#"
set -euo pipefail
source lib/npm/ask.sh
source lib/npm/closure.sh
jq -r --arg root r --arg rel l --argjson entries "$1" "${SAFEDEPS_NPM_ACCEPTED_JQ}" "$2" \
  | jq -r '"\(.package)@\(.version) \(.advisories | tojson)"'
"#, "coverage-test", &entries_json, dir.join("package-lock.json").to_str().unwrap()])
            .output().expect("run the CLI coverage reader");
        let _ = std::fs::remove_dir_all(&dir);
        assert!(output.status.success(), "CLI reader failed: {}", String::from_utf8_lossy(&output.stderr));
        let mut cli: Vec<String> = String::from_utf8(output.stdout).unwrap().lines()
            .map(|l| { let (head, ids) = l.split_once(' ').unwrap();
                let ids: Vec<String> = crate::json::parse_one(ids.as_bytes()).ok().and_then(|v| match v {
                    Value::Arr(a) => Some(a.into_iter().filter_map(|x| match x { Value::Str(s) => Some(String::from_utf8_lossy(&s).into_owned()), _ => None }).collect()),
                    _ => None }).unwrap();
                format!("{head} {ids:?}") }).collect();
        cli.sort();
        assert_eq!(core, cli, "the core and the CLI cover different packages");
        assert_eq!(core, vec![
            "@s/p@1.0.0 [\"GHSA-a\"]".to_string(),
            "both@1.0.0 [\"GHSA-b\"]".to_string(),
            "linked@1.0.0 []".to_string(),
            "real@1.0.0 [\"GHSA-r\"]".to_string(),
        ]);
    }
}
