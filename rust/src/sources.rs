//! The accepted-source ledger: the record of npm bytes from outside the
//! public registry that a person accepted, one install at a time.
//!
//! An install the effect gate would roll back because its lockfile records a
//! package from outside the public registry can be kept once, when the
//! command says so in front of the install:
//! `SAFEDEPS_ACCEPT_SOURCE='<url> <who decided and why>' npm install <url>`.
//! The kept install writes one entry here for each package it brought from
//! that URL. From then on, a package whose lock record names the same URL
//! with the same integrity, under the same name and version, is judged as an
//! approved package from the public registry: its source is no reason, the
//! ledger does not call it unapproved, and the advisories the entry names do
//! not count against it. Its install scripts are judged by the same
//! heuristics as any package's, and a KEV listing is never covered.
//!
//! An entry is about one file, not one address. The integrity is what binds
//! it: the bytes npm checks against the lock record are the bytes the person
//! accepted, wherever npm fetched them from. The same URL with another
//! integrity, the same integrity under another URL, and the same bytes under
//! another package name are each judged as before.
//!
//! Where: `accepted-sources.jsonl` in `SAFEDEPS_HOME`, derived from it and
//! from nothing else, as advisory.log and the approvals store are. No variable
//! of its own names it, and the CLI does not name it either: it asks this
//! module (`safedeps-core sources`).
//!
//! One writer, one reader. This module is the only code that writes the file
//! or reads its lines. The post hook appends an `accept` line for an install
//! it keeps, the CLI's `safedeps sources revoke <url>` appends a `revoke` line
//! through `safedeps-core sources revoke`, and every other reader (the CLI's
//! listing, the watch) takes `safedeps-core sources index`.
//!
//! A line is one JSON object. An accept line has exactly these fields:
//!
//!   at           the UTC time of the acceptance, `YYYY-MM-DDTHH:MM:SSZ`
//!   op           `accept`
//!   url          the lock record's `resolved`: https, off the public
//!                registry, printable ASCII with no blank (`url_acceptable`)
//!   integrity    the lock record's `integrity`, as npm wrote it
//!   package      the package's name, as the effect gate reads it from the
//!                record (its `name`, or the name its path gives)
//!   version      the record's `version`
//!   advisories   the advisory ids OSV named for that package and version
//!                when the install was judged, an array of strings
//!   reason       the value's words after the URL: who decided and why
//!   project      the project the install ran in
//!   tool_use_id  the call's id, or null
//!
//! A revoke line has exactly `at`, `op` (`revoke`) and `url`. It takes back
//! every entry of that URL written before it.
//!
//! The file only grows. Nothing in safedeps rotates, compacts, truncates or
//! rewrites it; a revoke is a line, like an acceptance.
//!
//! Isolation: flock(2)'s exclusive lock on the file itself, the one kind of
//! lock the core takes (`os::flock_within`). A writer holds it for its whole
//! write and a reader for its whole read, so a reader never sees a line half
//! written and two writers never write at once; the cost is that reads wait
//! for each other. A revoke reads and appends under one hold. The lock
//! belongs to the open
//! file, so a process that dies holding it leaves nothing to clean up. A lock
//! another process holds past the wait is an error: nothing is written or
//! read without the lock.
//!
//! The torn-line seal, the same rule as the approvals store's. A write that
//! did not finish leaves a last line with no newline, and no later write may
//! finish that line. Where the last byte is not a newline, a writer puts one
//! NUL byte and a newline before its own lines. A line that holds a NUL byte
//! stands for nothing, and no line a writer makes holds one: JSON writes that
//! byte as `\u0000`. A line that is not one of the two objects above stands
//! for nothing either, and each is counted as broken in the index, so it is
//! seen. A file that cannot be read is an error, never an empty ledger. A
//! file that is not there is an answer, `present: false`, with no entry.

use crate::{
    jq,
    json::{self, Value},
    ledger, os,
    outcome::{Action, Form, Outcome},
};
use std::{
    fs,
    io::{self, Read, Write},
    os::unix::fs::{FileExt, OpenOptionsExt},
    path::{Path, PathBuf},
    time::Duration,
};

pub const FILE_NAME: &str = "accepted-sources.jsonl";
/// The shell variable that accepts the source of one npm install.
pub const ACCEPT_SOURCE: &[u8] = b"SAFEDEPS_ACCEPT_SOURCE";
const ACCEPT_FIELDS: [&str; 10] = ["at", "op", "url", "integrity", "package", "version", "advisories", "reason", "project", "tool_use_id"];
const REVOKE_FIELDS: [&str; 3] = ["at", "op", "url"];
const SEAL: u8 = 0;
/// How long the CLI waits for the lock. A holder writes a few lines or reads
/// the file. The post hook waits no longer than its own deadline allows.
pub const LOCK_WAIT: Duration = Duration::from_secs(10);

pub fn path(home: &Path) -> PathBuf {
    home.join(FILE_NAME)
}

/// Whether `url` can be an entry's URL: it starts with `https://`, names a
/// host, is not on the public registry (`closure::public_registry_url`), and
/// holds only printable ASCII with no blank. A URL npm records with http, git
/// or file:, a directory link and a public registry URL are never accepted.
pub fn url_acceptable(url: &[u8]) -> Result<(), &'static str> {
    let Some(rest) = url.strip_prefix(b"https://") else { return Err("it is not an https URL") };
    if !url.iter().all(|b| b.is_ascii_graphic()) {
        return Err("it holds a blank, a control character or a byte outside ASCII");
    }
    let host = rest.split(|b| matches!(b, b'/' | b'?' | b'#')).next().unwrap_or(b"");
    if host.is_empty() || host.starts_with(b":") || host.contains(&b'@') {
        return Err("it names no host of its own");
    }
    if crate::post::public_registry_url(url) {
        return Err("it is on the public registry, which needs no acceptance");
    }
    Ok(())
}

/// One accepted file.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    pub url: Vec<u8>,
    pub integrity: Vec<u8>,
    pub package: Vec<u8>,
    pub version: Vec<u8>,
    pub advisories: Vec<Vec<u8>>,
    pub at: Vec<u8>,
    pub reason: Vec<u8>,
    pub project: Vec<u8>,
}

impl Entry {
    /// The entry stands for this lock record: the four values are the same
    /// bytes.
    pub fn covers(&self, url: &[u8], integrity: &[u8], package: &[u8], version: &[u8]) -> bool {
        self.url == url && self.integrity == integrity && self.package == package && self.version == version
    }
}

/// What the ledger holds: the entries that stand, in the order of their
/// lines, and how many lines stand for nothing.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Index {
    pub present: bool,
    pub entries: Vec<Entry>,
    pub broken: usize,
}

impl Index {
    pub fn find(&self, url: &[u8], integrity: &[u8], package: &[u8], version: &[u8]) -> Option<&Entry> {
        self.entries.iter().find(|e| e.covers(url, integrity, package, version))
    }
    pub fn with_url<'a>(&'a self, url: &'a [u8]) -> impl Iterator<Item = &'a Entry> + 'a {
        self.entries.iter().filter(move |e| e.url == url)
    }
}

/// An operation that failed, with its path, or a judgment of the file.
#[derive(Debug)]
pub enum Fault {
    Operation { outcome: Outcome, path: PathBuf, action: for<'a> fn(&'a Path) -> Action<'a> },
    Judgment(&'static [u8]),
}

impl Fault {
    pub fn text(&self) -> Vec<u8> {
        match self {
            Self::Operation { outcome, path, action } => outcome.describe(action(path), Form::Action),
            Self::Judgment(text) => text.to_vec(),
        }
    }
}

fn observed<T>(result: io::Result<T>, path: &Path, action: for<'a> fn(&'a Path) -> Action<'a>) -> Result<T, Fault> {
    result.map_err(|e| Fault::Operation { outcome: Outcome::Io(Err(e)), path: path.to_owned(), action })
}

fn regular(file: fs::File, at: &Path) -> Result<fs::File, Fault> {
    if observed(file.metadata(), at, |p| Action::Read(p))?.is_file() {
        Ok(file)
    } else {
        Err(Fault::Judgment(b"the accepted-source ledger is not a regular file"))
    }
}

fn text<'a>(v: &'a Value, key: &str) -> Option<&'a [u8]> {
    match v.get(key)? {
        Value::Str(s) => Some(s),
        _ => None,
    }
}

fn exact(o: &[(Vec<u8>, Value)], fields: &[&str]) -> bool {
    o.len() == fields.len() && fields.iter().all(|f| o.iter().filter(|(k, _)| k.as_slice() == f.as_bytes()).count() == 1)
}

enum Line {
    Accept(Entry),
    Revoke(Vec<u8>),
}

/// One finished line as an acceptance or a revoke, or None for a line that
/// stands for nothing.
fn parse(line: &[u8]) -> Option<Line> {
    let v = json::parse_one(line).ok()?;
    let Value::Obj(o) = &v else { return None };
    let at = std::str::from_utf8(text(&v, "at")?).ok()?;
    ledger::epoch(at)?;
    let url = text(&v, "url")?;
    url_acceptable(url).ok()?;
    match text(&v, "op")? {
        b"accept" if exact(o, &ACCEPT_FIELDS) => {
            let nonempty = |k| text(&v, k).filter(|s| !s.is_empty()).map(<[u8]>::to_vec);
            let Value::Arr(ids) = v.get("advisories")? else { return None };
            let advisories = ids.iter().map(|id| match id { Value::Str(s) if !s.is_empty() => Some(s.clone()), _ => None }).collect::<Option<Vec<_>>>()?;
            if !matches!(v.get("tool_use_id")?, Value::Str(_) | Value::Null) {
                return None;
            }
            Some(Line::Accept(Entry {
                url: url.to_vec(),
                integrity: nonempty("integrity")?,
                package: nonempty("package")?,
                version: nonempty("version")?,
                advisories,
                at: at.as_bytes().to_vec(),
                reason: nonempty("reason")?,
                project: text(&v, "project")?.to_vec(),
            }))
        }
        b"revoke" if exact(o, &REVOKE_FIELDS) => Some(Line::Revoke(url.to_vec())),
        _ => None,
    }
}

/// The file's bytes as an index. A last line with no newline is a write that
/// did not finish, and a line that holds the seal is one a later writer
/// sealed: each is broken like any other line that is not one of the two.
fn read(bytes: &[u8]) -> Index {
    let mut entries: Vec<Entry> = Vec::new();
    let mut broken = 0;
    for piece in bytes.split_inclusive(|&b| b == b'\n') {
        match piece.strip_suffix(b"\n").filter(|l| !l.contains(&SEAL)).and_then(parse) {
            Some(Line::Accept(e)) => entries.push(e),
            Some(Line::Revoke(url)) => entries.retain(|e| e.url != url),
            None => broken += 1,
        }
    }
    Index { present: true, entries, broken }
}

/// The ledger, read under the lock taken within `wait`.
pub fn index(home: &Path, wait: Duration) -> Result<Index, Fault> {
    let at = path(home);
    let file = match fs::File::open(&at) {
        Ok(f) => regular(f, &at)?,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Index::default()),
        Err(e) => return Err(Fault::Operation { outcome: Outcome::Io(Err(e)), path: at, action: |p| Action::Open(p) }),
    };
    lock(&file, &at, wait)?;
    let mut bytes = Vec::new();
    let mut f: &fs::File = &file;
    observed(f.read_to_end(&mut bytes), &at, |p| Action::Read(p))?;
    Ok(read(&bytes))
}

/// flock(2)'s exclusive lock on `file`, taken within `wait`, counted from
/// this call. A reader takes it too: the core's lock has one kind.
fn lock(file: &fs::File, at: &Path, wait: Duration) -> Result<(), Fault> {
    os::flock_within(file, wait, os::host_clock, |_| None)
        .map(|_| ())
        .map_err(|o| Fault::Operation { outcome: o, path: at.to_owned(), action: |p| Action::Lock(p) })
}

/// The file, opened to be appended to and locked within `wait`.
fn locked(home: &Path, wait: Duration) -> Result<(fs::File, PathBuf), Fault> {
    let at = path(home);
    let file = observed(fs::OpenOptions::new().read(true).append(true).create(true).mode(0o600).open(&at), &at, |p| Action::Open(p))?;
    let file = regular(file, &at)?;
    lock(&file, &at, wait)?;
    Ok((file, at))
}

fn whole(file: &fs::File, at: &Path) -> Result<Vec<u8>, Fault> {
    let len = usize::try_from(observed(file.metadata(), at, |p| Action::Read(p))?.len())
        .map_err(|_| Fault::Judgment(b"the accepted-source ledger is too large to read"))?;
    let mut bytes = vec![0u8; len];
    observed(file.read_exact_at(&mut bytes, 0), at, |p| Action::Read(p))?;
    Ok(bytes)
}

/// Under the lock: seals a torn last line, appends `lines` in the same write,
/// and syncs them. A failed sync is a line a reader sees, and it is said as
/// the sync's outcome.
fn append(file: &fs::File, at: &Path, lines: &[u8]) -> Result<(), Fault> {
    let len = observed(file.metadata(), at, |p| Action::Read(p))?.len();
    let mut out = Vec::with_capacity(lines.len() + 2);
    if len > 0 {
        let mut last = [0u8; 1];
        observed(file.read_exact_at(&mut last, len - 1), at, |p| Action::Read(p))?;
        if last[0] != b'\n' {
            out.extend_from_slice(&[SEAL, b'\n']);
        }
    }
    out.extend_from_slice(lines);
    let mut f: &fs::File = file;
    observed(f.write_all(&out), at, |p| Action::Write(p))?;
    observed(file.sync_data(), at, |p| Action::Sync(p))
}

fn line(value: &jq::J) -> Vec<u8> {
    let mut l = jq::compact(value).into_bytes();
    l.push(b'\n');
    l
}

/// One acceptance, as the post hook writes it.
pub struct Accept<'a> {
    pub entry: &'a Entry,
    pub tool_use_id: Option<&'a [u8]>,
}

fn accept_line(at: &str, a: &Accept) -> Vec<u8> {
    let e = a.entry;
    line(&jq::obj(vec![
        ("at", jq::s(at)),
        ("op", jq::s("accept")),
        ("url", jq::arg(&e.url)),
        ("integrity", jq::arg(&e.integrity)),
        ("package", jq::arg(&e.package)),
        ("version", jq::arg(&e.version)),
        ("advisories", jq::J::Arr(e.advisories.iter().map(|id| jq::arg(id)).collect())),
        ("reason", jq::arg(&e.reason)),
        ("project", jq::arg(&e.project)),
        ("tool_use_id", a.tool_use_id.map(jq::arg).unwrap_or(jq::J::Null)),
    ]))
}

/// Appends one accept line for each of `accepts`, in one write, under the
/// lock taken within `wait`. An entry that would stand for nothing (a URL
/// `url_acceptable` refuses, an empty value or advisory id) is refused before
/// the file is opened, and nothing is written.
pub fn accept(home: &Path, accepts: &[Accept], wait: Duration) -> Result<(), Fault> {
    let at = os::utc_stamp(os::wall(os::WallRole::AcceptedSourceEntry).seconds());
    let mut lines = Vec::new();
    for a in accepts {
        let l = accept_line(&at, a);
        if !matches!(l.strip_suffix(b"\n").and_then(parse), Some(Line::Accept(_))) {
            return Err(Fault::Judgment(b"an entry would stand for nothing"));
        }
        lines.extend(l);
    }
    if lines.is_empty() {
        return Ok(());
    }
    let (file, at_path) = locked(home, wait)?;
    append(&file, &at_path, &lines)
}

/// Takes back every entry of `url` under one hold of the lock: reads the
/// ledger, and where any entry of that URL stands, appends one revoke line. The answer is
/// how many entries it took back; with none, nothing is written.
pub fn revoke(home: &Path, url: &[u8], wait: Duration) -> Result<usize, Fault> {
    url_acceptable(url).map_err(|_| Fault::Judgment(b"the URL is not one an entry can name"))?;
    let (file, at) = locked(home, wait)?;
    let standing = read(&whole(&file, &at)?).with_url(url).count();
    if standing == 0 {
        return Ok(0);
    }
    let stamp = os::utc_stamp(os::wall(os::WallRole::AcceptedSourceEntry).seconds());
    append(&file, &at, &line(&jq::obj(vec![("at", jq::s(&stamp)), ("op", jq::s("revoke")), ("url", jq::arg(url))])))?;
    Ok(standing)
}

fn index_json(ix: &Index) -> String {
    let entry = |e: &Entry| {
        jq::obj(vec![
            ("url", jq::arg(&e.url)),
            ("integrity", jq::arg(&e.integrity)),
            ("package", jq::arg(&e.package)),
            ("version", jq::arg(&e.version)),
            ("advisories", jq::J::Arr(e.advisories.iter().map(|id| jq::arg(id)).collect())),
            ("at", jq::arg(&e.at)),
            ("reason", jq::arg(&e.reason)),
            ("project", jq::arg(&e.project)),
        ])
    };
    jq::compact(&jq::obj(vec![
        ("present", jq::J::Bool(ix.present)),
        ("entries", jq::J::Arr(ix.entries.iter().map(entry).collect())),
        ("broken", jq::J::Num(ix.broken.to_string())),
    ]))
}

/// `safedeps-core sources index`: `{"present":…,"entries":[…],"broken":…}`
/// on stdout. `safedeps-core sources revoke <url>`: `{"revoked":N}`. A fault
/// is one line on stderr and exit 1; a usage error is exit 2. Both read
/// SAFEDEPS_HOME, and no hook runs them.
pub fn cli(args: &[String]) -> i32 {
    os::set_umask(0o077);
    let home = crate::state::guard_dir();
    let (out, said) = match args {
        [cmd] if cmd == "index" => (index(&home, LOCK_WAIT).map(|ix| index_json(&ix)), "the accepted-source ledger could not be read: "),
        [cmd, url] if cmd == "revoke" => (
            revoke(&home, url.as_bytes(), LOCK_WAIT).map(|n| jq::compact(&jq::obj(vec![("revoked", jq::J::Num(n.to_string()))]))),
            "the accepted-source ledger could not take the revoke: ",
        ),
        _ => {
            eprintln!("usage: safedeps-core sources index | sources revoke <url>");
            return 2;
        }
    };
    match out {
        Ok(text) => {
            println!("{text}");
            0
        }
        Err(fault) => {
            let mut err = said.as_bytes().to_vec();
            err.extend(fault.text());
            err.push(b'\n');
            let _ = io::stderr().write_all(&err);
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Dir(PathBuf);
    impl Drop for Dir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    fn dir() -> Dir {
        Dir(os::scratch_dir("safedeps-sources").unwrap())
    }
    fn entry(url: &str, integrity: &str) -> Entry {
        Entry {
            url: url.into(),
            integrity: integrity.into(),
            package: b"x".to_vec(),
            version: b"1.0.1".to_vec(),
            advisories: vec![b"GHSA-aaaa-bbbb-cccc".to_vec()],
            at: Vec::new(),
            reason: b"owner: the fixed release is on the maker's site only".to_vec(),
            project: b"/p".to_vec(),
        }
    }
    const URL: &str = "https://example.test/x/-/x-1.0.1.tgz";

    #[test]
    fn a_url_is_accepted_only_over_https_off_the_public_registry() {
        for good in [URL, "https://example.test/x.tgz?sig=1", "https://example.test:8443/x.tgz"] {
            assert_eq!(url_acceptable(good.as_bytes()), Ok(()), "{good}");
        }
        for bad in ["http://example.test/x.tgz", "git+https://example.test/x.git", "git://example.test/x.git", "file:vendor/x.tgz",
            "../evildir", "HTTPS://example.test/x.tgz", "https://", "https:///x.tgz", "https://user@example.test/x.tgz",
            "https://example.test/a b.tgz", "https://example.test/\u{e9}.tgz", "https://registry.npmjs.org/x/-/x-1.0.1.tgz",
            "https://REGISTRY.yarnpkg.com/x/-/x-1.0.1.tgz"] {
            assert!(url_acceptable(bad.as_bytes()).is_err(), "{bad}");
        }
    }

    #[test]
    fn an_absent_ledger_is_an_answer_and_an_accepted_entry_stands_until_revoked() {
        let d = dir();
        assert_eq!(index(&d.0, LOCK_WAIT).unwrap(), Index::default());
        let (a, b) = (entry(URL, "sha512-one"), entry(URL, "sha512-two"));
        accept(&d.0, &[Accept { entry: &a, tool_use_id: Some(b"toolu_1") }, Accept { entry: &b, tool_use_id: None }], LOCK_WAIT).unwrap();
        let ix = index(&d.0, LOCK_WAIT).unwrap();
        assert!(ix.present && ix.broken == 0 && ix.entries.len() == 2);
        assert!(ix.find(URL.as_bytes(), b"sha512-one", b"x", b"1.0.1").is_some());
        for (url, integrity, package, version) in [(URL, "sha512-three", "x", "1.0.1"), (URL, "sha512-one", "y", "1.0.1"),
            (URL, "sha512-one", "x", "1.0.2"), ("https://example.test/x/-/x-1.0.1.tgz?", "sha512-one", "x", "1.0.1"),
            ("https://Example.test/x/-/x-1.0.1.tgz", "sha512-one", "x", "1.0.1")] {
            assert!(ix.find(url.as_bytes(), integrity.as_bytes(), package.as_bytes(), version.as_bytes()).is_none(), "{url} {integrity} {package}@{version}");
        }
        assert_eq!(revoke(&d.0, b"https://example.test/other.tgz", LOCK_WAIT).unwrap(), 0);
        assert_eq!(revoke(&d.0, URL.as_bytes(), LOCK_WAIT).unwrap(), 2);
        let ix = index(&d.0, LOCK_WAIT).unwrap();
        assert!(ix.entries.is_empty() && ix.broken == 0, "{ix:?}");
        assert_eq!(revoke(&d.0, URL.as_bytes(), LOCK_WAIT).unwrap(), 0, "nothing stands, so nothing is written");
        let lines = fs::read(path(&d.0)).unwrap().iter().filter(|b| **b == b'\n').count();
        assert_eq!(lines, 3, "two accept lines and one revoke line");
        accept(&d.0, &[Accept { entry: &a, tool_use_id: None }], LOCK_WAIT).unwrap();
        assert_eq!(index(&d.0, LOCK_WAIT).unwrap().entries.len(), 1, "an acceptance after a revoke stands");
    }

    #[test]
    fn an_entry_that_would_stand_for_nothing_is_not_written() {
        let d = dir();
        let mut bad = entry("http://example.test/x.tgz", "sha512-one");
        assert!(accept(&d.0, &[Accept { entry: &bad, tool_use_id: None }], LOCK_WAIT).is_err());
        bad = entry(URL, "");
        assert!(accept(&d.0, &[Accept { entry: &bad, tool_use_id: None }], LOCK_WAIT).is_err());
        bad = entry(URL, "sha512-one");
        bad.advisories = vec![Vec::new()];
        assert!(accept(&d.0, &[Accept { entry: &bad, tool_use_id: None }], LOCK_WAIT).is_err());
        assert!(!path(&d.0).exists(), "no file was made");
    }

    #[test]
    fn a_line_that_is_not_one_of_the_two_stands_for_nothing_and_a_torn_tail_is_sealed() {
        let d = dir();
        let good = String::from_utf8(accept_line("2001-01-01T00:00:00Z", &Accept { entry: &entry(URL, "sha512-one"), tool_use_id: None })).unwrap();
        let mut extra: Value = json::parse_one(good.trim_end().as_bytes()).unwrap();
        if let Value::Obj(o) = &mut extra { o.push((b"more".to_vec(), Value::Null)); }
        let bad = [
            good.replace("\"op\":\"accept\"", "\"op\":\"approve\""),
            good.replace("2001-01-01T00:00:00Z", "yesterday"),
            good.replace("https://example.test", "http://example.test"),
            good.replace("\"advisories\":[\"GHSA-aaaa-bbbb-cccc\"]", "\"advisories\":\"GHSA-aaaa-bbbb-cccc\""),
            good.replace("\"tool_use_id\":null", "\"tool_use_id\":1"),
            format!("{}\n", jq::compact(&jq::from_value(&extra))),
            "{\"at\":\"2001-01-01T00:00:00Z\",\"op\":\"revoke\",\"url\":\"https://example.test/x/-/x-1.0.1.tgz\",\"why\":\"\"}\n".to_string(),
            format!("{}\u{0}\n", good.trim_end()),
            "not json\n".to_string(),
        ];
        let mut bytes = good.clone().into_bytes();
        for b in &bad { bytes.extend(b.as_bytes()); }
        bytes.extend(&good.as_bytes()[..good.len() / 2]);
        fs::write(path(&d.0), &bytes).unwrap();
        let ix = index(&d.0, LOCK_WAIT).unwrap();
        assert_eq!((ix.entries.len(), ix.broken), (1, bad.len() + 1), "{ix:?}");
        accept(&d.0, &[Accept { entry: &entry(URL, "sha512-two"), tool_use_id: None }], LOCK_WAIT).unwrap();
        let ix = index(&d.0, LOCK_WAIT).unwrap();
        assert_eq!((ix.entries.len(), ix.broken), (2, bad.len() + 1), "the torn tail is one broken line and the new line stands: {ix:?}");
    }

    #[test]
    fn a_ledger_that_is_not_a_regular_file_or_is_held_is_an_error() {
        let d = dir();
        fs::create_dir(path(&d.0)).unwrap();
        assert!(index(&d.0, LOCK_WAIT).is_err());
        assert!(accept(&d.0, &[Accept { entry: &entry(URL, "sha512-one"), tool_use_id: None }], LOCK_WAIT).is_err());
        fs::remove_dir(path(&d.0)).unwrap();
        fs::write(path(&d.0), b"").unwrap();
        let holder = fs::OpenOptions::new().read(true).open(path(&d.0)).unwrap();
        assert!(os::try_flock(&holder).unwrap(), "the row holds the lock");
        let short = Duration::from_millis(50);
        assert!(matches!(index(&d.0, short), Err(Fault::Operation { outcome: Outcome::Deadline, .. })));
        assert!(matches!(accept(&d.0, &[Accept { entry: &entry(URL, "sha512-one"), tool_use_id: None }], short), Err(Fault::Operation { outcome: Outcome::Deadline, .. })));
        drop(holder);
        assert!(index(&d.0, short).unwrap().present);
    }
}
