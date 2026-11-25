//! The accepted-source ledger: the record of npm bytes from outside the
//! public registry that a person accepted, one install at a time.
//!
//! An install the effect gate would roll back because its lockfile records a
//! package from outside the public registry can be kept once, when the
//! command says so in front of the install:
//! `SAFEDEPS_ACCEPT_SOURCE='<url> <who decided and why>' npm install <url>`.
//! The kept install writes one line here, with one entry for each package it
//! brought from that URL. From then on, a package whose lock record names the
//! same URL with the same integrity, under the same name and version, is
//! judged as an approved package from the public registry: its source is no
//! reason, the ledger does not call it unapproved, and the advisories the
//! entry names do not count against it. Its install scripts are judged by
//! the same heuristics as any package's, and a KEV listing is never covered.
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
//! listing, the watch, the audit) takes `safedeps-core sources index`.
//!
//! A line is one JSON object. An accept line has exactly these fields:
//!
//!   at           the UTC time of the acceptance, `YYYY-MM-DDTHH:MM:SSZ`
//!   op           `accept`
//!   url          the lock records' `resolved`: https, off the public
//!                registry, printable ASCII with no blank (`url_acceptable`)
//!   entries      one object for each file the install accepted from that
//!                URL, at least one, each with exactly these fields:
//!     integrity    the lock record's `integrity`, as npm wrote it
//!     package      the package's name, as the effect gate reads it from the
//!                  record (its `name`, or the name its path gives)
//!     version      the record's `version`
//!     advisories   the advisory ids OSV named for that package and version
//!                  when the install was judged, an array of strings
//!   reason       the value's words after the URL: who decided and why
//!   project      the project the install ran in
//!   tool_use_id  the call's id, or null
//!
//! An accept line stands as a whole or not at all: one entry that would
//! stand for nothing makes the line stand for nothing. A revoke line has
//! exactly `at`, `op` (`revoke`) and `url`. It takes back every entry of
//! that URL written before it.
//!
//! The file only grows. Nothing in safedeps rotates, compacts, truncates or
//! rewrites it; a revoke is a line, like an acceptance.
//!
//! Isolation: flock(2)'s exclusive lock on the file itself, the one kind of
//! lock the core takes (`os::flock_within`). A writer holds it for its whole
//! write and a reader for its whole read, so a reader never sees a line half
//! written and two writers never write at once; the cost is that reads wait
//! for each other. A revoke reads and appends under one hold. The lock
//! belongs to the open file, so a process that dies holding it leaves nothing
//! to clean up. A lock another process holds past the wait is an error:
//! nothing is written or read without the lock.
//!
//! The commit. A write is one line, appended by one run of write(2) calls,
//! so one install's acceptance is one line however many files it accepted.
//! The line is committed when its last byte, the newline, is in the file:
//! the write returned with every byte in. A failure before that leaves no
//! line that stands (`Fault`): no byte, or a torn piece the next writer seals
//! as one broken line. The steps after it, the sync of the file's data, the
//! sync of the directory where this write made the file, and the close,
//! cannot take the line back. One that fails is a doubt the writer says
//! beside the commit (`Committed::doubts`), never a write that failed. What a
//! doubt leaves open is a power loss before the system writes the line,
//! which can take the line away.
//!
//! The boundary no rule of the write closes: a process killed before or
//! during its write (the runtime's kill at its timeout, SIGKILL) leaves no
//! line or a torn piece, so no entry, and no process is left to roll the
//! install back. The post hook's judgment mark answers it: the next post run
//! says the judgment did not finish (`crate::post::mark`).
//!
//! The torn-line seal, the same rule as the approvals store's. A write that
//! did not finish leaves a last line with no newline, and no later write may
//! finish that line. Where the last byte is not a newline, a writer puts one
//! NUL byte and a newline before its own line. A line that holds a NUL byte
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
    collections::HashMap,
    fs,
    hash::{Hash, Hasher},
    io::{self, Read, Write},
    os::unix::fs::{FileExt, OpenOptionsExt},
    path::{Path, PathBuf},
    time::Duration,
};

pub const FILE_NAME: &str = "accepted-sources.jsonl";
/// The shell variable that accepts the source of one npm install.
pub const ACCEPT_SOURCE: &[u8] = b"SAFEDEPS_ACCEPT_SOURCE";
const ACCEPT_FIELDS: [&str; 7] = ["at", "op", "url", "entries", "reason", "project", "tool_use_id"];
const FILE_FIELDS: [&str; 4] = ["integrity", "package", "version", "advisories"];
const REVOKE_FIELDS: [&str; 3] = ["at", "op", "url"];
const SEAL: u8 = 0;
/// How long the CLI waits for the lock. A holder writes a line or reads the
/// file. The post hook waits no longer than its own deadline allows.
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

/// A key for byte strings, each hashed with its length so that two lists
/// that join to the same bytes still have two keys. A key only narrows the
/// search: every entry it finds is compared again, byte for byte.
fn key(parts: &[&[u8]]) -> u64 {
    let mut h = std::collections::hash_map::DefaultHasher::new();
    for p in parts {
        p.hash(&mut h);
    }
    h.finish()
}

/// What the ledger holds: the entries that stand, in the order of their
/// lines, and how many lines stand for nothing. The entries are found by
/// their four values and by their URL through keys made once, so a lookup
/// does not grow with the ledger.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Index {
    pub present: bool,
    pub entries: Vec<Entry>,
    pub broken: usize,
    files: HashMap<u64, Vec<usize>>,
    urls: HashMap<u64, Vec<usize>>,
}

impl Index {
    pub fn new(present: bool, entries: Vec<Entry>, broken: usize) -> Self {
        let mut ix = Index { present, entries, broken, ..Default::default() };
        for (i, e) in ix.entries.iter().enumerate() {
            ix.files.entry(key(&[&e.url, &e.integrity, &e.package, &e.version])).or_default().push(i);
            ix.urls.entry(key(&[&e.url])).or_default().push(i);
        }
        ix
    }
    /// The entries that stand for this lock record's four values, in the
    /// order of their lines.
    pub fn covering<'a>(&'a self, url: &'a [u8], integrity: &'a [u8], package: &'a [u8], version: &'a [u8]) -> impl Iterator<Item = &'a Entry> + 'a {
        self.files.get(&key(&[url, integrity, package, version])).into_iter().flatten()
            .map(|&i| &self.entries[i]).filter(move |e| e.covers(url, integrity, package, version))
    }
    pub fn find(&self, url: &[u8], integrity: &[u8], package: &[u8], version: &[u8]) -> Option<&Entry> {
        self.files.get(&key(&[url, integrity, package, version]))?.iter().map(|&i| &self.entries[i]).find(|e| e.covers(url, integrity, package, version))
    }
    pub fn with_url<'a>(&'a self, url: &'a [u8]) -> impl Iterator<Item = &'a Entry> + 'a {
        self.urls.get(&key(&[url])).into_iter().flatten().map(|&i| &self.entries[i]).filter(move |e| e.url == url)
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

/// A step after the commit, each run whatever the one before it returned.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum After {
    /// The file's data, synced: until it is, a power loss can take the line
    /// away.
    Sync,
    /// The directory that holds the file, synced, where this write made the
    /// file: until it is, a power loss can take the file away.
    SyncDir,
    /// The file, closed, with what close returned. A close is where some
    /// systems report a write they could not finish.
    Close,
}

/// A step after the commit that failed, and what it returned. The line
/// stands either way: a doubt says what may not hold.
#[derive(Debug)]
pub struct Doubt {
    pub step: After,
    pub fault: Fault,
}

impl Doubt {
    pub fn text(&self) -> Vec<u8> {
        self.fault.text()
    }
}

/// A write whose line is in the file, and the doubts of the steps after it.
#[derive(Debug, Default)]
pub struct Committed {
    pub doubts: Vec<Doubt>,
}

/// What a revoke did once it read the ledger: how many entries it took back,
/// and the doubts of its write. With none taken back, nothing was written
/// and nothing is in doubt.
#[derive(Debug, Default)]
pub struct Revoked {
    pub count: usize,
    pub doubts: Vec<Doubt>,
}

fn regular(file: &fs::File, at: &Path) -> Result<(), Fault> {
    if observed(file.metadata(), at, |p| Action::Read(p))?.is_file() {
        Ok(())
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
    Accept(Vec<Entry>),
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
            let nonempty = |v: &Value, k| text(v, k).filter(|s| !s.is_empty()).map(<[u8]>::to_vec);
            if !matches!(v.get("tool_use_id")?, Value::Str(_) | Value::Null) {
                return None;
            }
            let reason = nonempty(&v, "reason")?;
            let project = text(&v, "project")?.to_vec();
            let Value::Arr(files) = v.get("entries")? else { return None };
            if files.is_empty() {
                return None;
            }
            let file = |f: &Value| {
                let Value::Obj(fields) = f else { return None };
                if !exact(fields, &FILE_FIELDS) {
                    return None;
                }
                let Value::Arr(ids) = f.get("advisories")? else { return None };
                let advisories = ids.iter().map(|id| match id { Value::Str(s) if !s.is_empty() => Some(s.clone()), _ => None }).collect::<Option<Vec<_>>>()?;
                Some(Entry {
                    url: url.to_vec(),
                    integrity: nonempty(f, "integrity")?,
                    package: nonempty(f, "package")?,
                    version: nonempty(f, "version")?,
                    advisories,
                    at: at.as_bytes().to_vec(),
                    reason: reason.clone(),
                    project: project.clone(),
                })
            };
            files.iter().map(file).collect::<Option<Vec<_>>>().map(Line::Accept)
        }
        b"revoke" if exact(o, &REVOKE_FIELDS) => Some(Line::Revoke(url.to_vec())),
        _ => None,
    }
}

/// The file's bytes as an index. A last line with no newline is a write that
/// did not finish, and a line that holds the seal is one a later writer
/// sealed: each is broken like any other line that is not one of the two.
/// An entry stands where no revoke of its URL comes after its line, so the
/// read is one pass, however many revokes the file holds.
fn read(bytes: &[u8]) -> Index {
    let mut accepted: Vec<(usize, Entry)> = Vec::new();
    let mut revoked: HashMap<Vec<u8>, usize> = HashMap::new();
    let mut broken = 0;
    for (n, piece) in bytes.split_inclusive(|&b| b == b'\n').enumerate() {
        match piece.strip_suffix(b"\n").filter(|l| !l.contains(&SEAL)).and_then(parse) {
            Some(Line::Accept(entries)) => accepted.extend(entries.into_iter().map(|e| (n, e))),
            Some(Line::Revoke(url)) => {
                revoked.insert(url, n);
            }
            None => broken += 1,
        }
    }
    let entries = accepted.into_iter().filter(|(n, e)| revoked.get(&e.url).map_or(true, |r| n > r)).map(|(_, e)| e).collect();
    Index::new(true, entries, broken)
}

/// flock(2)'s exclusive lock on `file`, taken within `wait`, counted from
/// this call. A reader takes it too: the core's lock has one kind.
fn lock(file: &fs::File, at: &Path, wait: Duration) -> Result<(), Fault> {
    os::flock_within(file, wait, os::host_clock, |_| None)
        .map(|_| ())
        .map_err(|o| Fault::Operation { outcome: o, path: at.to_owned(), action: |p| Action::Lock(p) })
}

/// The ledger, read under the lock taken within `wait`.
pub fn index(home: &Path, wait: Duration) -> Result<Index, Fault> {
    let at = path(home);
    let file = match fs::File::open(&at) {
        Ok(f) => f,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Index::default()),
        Err(e) => return Err(Fault::Operation { outcome: Outcome::Io(Err(e)), path: at, action: |p| Action::Open(p) }),
    };
    regular(&file, &at)?;
    lock(&file, &at, wait)?;
    let mut bytes = Vec::new();
    let mut f: &fs::File = &file;
    observed(f.read_to_end(&mut bytes), &at, |p| Action::Read(p))?;
    Ok(read(&bytes))
}

/// The file, opened to be appended to, and whether this open made it. Where
/// there is no file, the open makes one, and only where none is there
/// (O_EXCL), so a file another writer made in between is opened as it is,
/// and the answer says it was not this open's.
fn open_to_append(at: &Path) -> Result<(fs::File, bool), Fault> {
    let existing = || fs::OpenOptions::new().read(true).append(true).open(at);
    match existing() {
        Ok(f) => return Ok((f, false)),
        Err(e) if e.kind() == io::ErrorKind::NotFound => {}
        Err(e) => return Err(Fault::Operation { outcome: Outcome::Io(Err(e)), path: at.to_owned(), action: |p| Action::Open(p) }),
    }
    match fs::OpenOptions::new().read(true).append(true).create_new(true).mode(0o600).open(at) {
        Ok(f) => Ok((f, true)),
        Err(e) if e.kind() == io::ErrorKind::AlreadyExists => observed(existing(), at, |p| Action::Open(p)).map(|f| (f, false)),
        Err(e) => Err(Fault::Operation { outcome: Outcome::Io(Err(e)), path: at.to_owned(), action: |p| Action::Create(p) }),
    }
}

/// Whether the file's last byte is something other than a newline: a torn
/// line the write must seal first.
fn torn(file: &fs::File, at: &Path) -> Result<bool, Fault> {
    let len = observed(file.metadata(), at, |p| Action::Read(p))?.len();
    if len == 0 {
        return Ok(false);
    }
    let mut last = [0u8; 1];
    observed(file.read_exact_at(&mut last, len - 1), at, |p| Action::Read(p))?;
    Ok(last[0] != b'\n')
}

fn whole(file: &fs::File, at: &Path) -> Result<Vec<u8>, Fault> {
    let len = usize::try_from(observed(file.metadata(), at, |p| Action::Read(p))?.len())
        .map_err(|_| Fault::Judgment(b"the accepted-source ledger is too large to read"))?;
    let mut bytes = vec![0u8; len];
    observed(file.read_exact_at(&mut bytes, 0), at, |p| Action::Read(p))?;
    Ok(bytes)
}

/// A write's steps, each the one operation it names. `Real` runs them. A
/// test runs them through its own, to fail one and read what the write
/// answers and what the file then holds.
trait Steps {
    fn open(&self, at: &Path) -> Result<(fs::File, bool), Fault> {
        open_to_append(at)
    }
    fn regular(&self, file: &fs::File, at: &Path) -> Result<(), Fault> {
        regular(file, at)
    }
    fn lock(&self, file: &fs::File, at: &Path, wait: Duration) -> Result<(), Fault> {
        lock(file, at, wait)
    }
    /// The last byte, for an accept: is the last line torn.
    fn tail(&self, file: &fs::File, at: &Path) -> Result<bool, Fault> {
        torn(file, at)
    }
    /// The whole file, for a revoke, which judges what stands.
    fn read(&self, file: &fs::File, at: &Path) -> Result<Vec<u8>, Fault> {
        whole(file, at)
    }
    /// One write(2): how many bytes went in. The write loop is std's
    /// `write_all`, which tries again where a signal broke one off and fails
    /// where one put nothing in.
    fn write(&self, file: &fs::File, buf: &[u8]) -> io::Result<usize> {
        let mut f: &fs::File = file;
        f.write(buf)
    }
    fn sync(&self, file: &fs::File) -> io::Result<()> {
        file.sync_data()
    }
    fn sync_dir(&self, dir: &Path) -> Result<(), Fault> {
        let d = observed(fs::File::open(dir), dir, |p| Action::Open(p))?;
        observed(d.sync_all(), dir, |p| Action::Sync(p))
    }
    fn close(&self, file: fs::File) -> io::Result<()> {
        os::close_file(file)
    }
}

struct Real;

impl Steps for Real {}

/// The file through `Steps::write`, for std's `write_all`.
struct Through<'a, S> {
    steps: &'a S,
    file: &'a fs::File,
}

impl<S: Steps> Write for Through<'_, S> {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.steps.write(self.file, buf)
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

/// The write: the seal where the last line is torn, then `line`, until every
/// byte is in. Its Ok is the commit.
fn put(steps: &impl Steps, file: &fs::File, at: &Path, seal: bool, line: &[u8]) -> Result<(), Fault> {
    let mut out = Vec::with_capacity(line.len() + 2);
    if seal {
        out.extend_from_slice(&[SEAL, b'\n']);
    }
    out.extend_from_slice(line);
    observed(Through { steps, file }.write_all(&out), at, |p| Action::Write(p))
}

/// After the write. Where it did not put the whole line in, the answer is
/// its fault, and the close that follows changes nothing about it: no line
/// of this write stands. Where it did, the line is committed, and each step
/// after it runs whatever the one before returned; one that fails is a
/// doubt.
fn finish(steps: &impl Steps, file: fs::File, home: &Path, at: &Path, created: bool, written: Result<(), Fault>) -> Result<Committed, Fault> {
    if let Err(fault) = written {
        let _ = steps.close(file);
        return Err(fault);
    }
    let mut doubts = Vec::new();
    if let Err(fault) = observed(steps.sync(&file), at, |p| Action::Sync(p)) {
        doubts.push(Doubt { step: After::Sync, fault });
    }
    if created {
        if let Err(fault) = steps.sync_dir(home) {
            doubts.push(Doubt { step: After::SyncDir, fault });
        }
    }
    if let Err(fault) = observed(steps.close(file), at, |p| Action::Close(p)) {
        doubts.push(Doubt { step: After::Close, fault });
    }
    Ok(Committed { doubts })
}

fn line(value: &jq::J) -> Vec<u8> {
    let mut l = jq::compact(value).into_bytes();
    l.push(b'\n');
    l
}

/// The accept line of `entries`, which share their URL, reason and project.
fn accept_line(at: &str, entries: &[Entry], tool_use_id: Option<&[u8]>) -> Vec<u8> {
    let (url, reason, project) = entries.first().map(|e| (&e.url[..], &e.reason[..], &e.project[..])).unwrap_or_default();
    let file = |e: &Entry| {
        jq::obj(vec![
            ("integrity", jq::arg(&e.integrity)),
            ("package", jq::arg(&e.package)),
            ("version", jq::arg(&e.version)),
            ("advisories", jq::J::Arr(e.advisories.iter().map(|id| jq::arg(id)).collect())),
        ])
    };
    line(&jq::obj(vec![
        ("at", jq::s(at)),
        ("op", jq::s("accept")),
        ("url", jq::arg(url)),
        ("entries", jq::J::Arr(entries.iter().map(file).collect())),
        ("reason", jq::arg(reason)),
        ("project", jq::arg(project)),
        ("tool_use_id", tool_use_id.map(jq::arg).unwrap_or(jq::J::Null)),
    ]))
}

/// Appends the one accept line of an install: `entries`, the files it
/// accepted from one URL, under one reason, in one project. The lock is
/// taken within `wait`. An acceptance that would stand for nothing (no entry,
/// entries that name more than one URL, reason or project, a URL
/// `url_acceptable` refuses, an empty value or advisory id) is refused
/// before the file is opened, and nothing is written. The answer is the
/// commit with its doubts, or the fault of a write whose line does not
/// stand.
pub fn accept(home: &Path, entries: &[Entry], tool_use_id: Option<&[u8]>, wait: Duration) -> Result<Committed, Fault> {
    accept_with(&Real, home, entries, tool_use_id, wait)
}

fn accept_with(steps: &impl Steps, home: &Path, entries: &[Entry], tool_use_id: Option<&[u8]>, wait: Duration) -> Result<Committed, Fault> {
    if !entries.windows(2).all(|w| w[0].url == w[1].url && w[0].reason == w[1].reason && w[0].project == w[1].project) {
        return Err(Fault::Judgment(b"the entries of one acceptance name more than one URL, reason or project"));
    }
    let stamp = os::utc_stamp(os::wall(os::WallRole::AcceptedSourceEntry).seconds());
    let line = accept_line(&stamp, entries, tool_use_id);
    if !matches!(line.strip_suffix(b"\n").and_then(parse), Some(Line::Accept(_))) {
        return Err(Fault::Judgment(b"an entry would stand for nothing"));
    }
    let at = path(home);
    let (file, created) = steps.open(&at)?;
    let written = steps
        .regular(&file, &at)
        .and_then(|()| steps.lock(&file, &at, wait))
        .and_then(|()| steps.tail(&file, &at))
        .and_then(|seal| put(steps, &file, &at, seal, &line));
    finish(steps, file, home, &at, created, written)
}

/// Takes back every entry of `url` under one hold of the lock: reads the
/// ledger, and where any entry of that URL stands, appends one revoke line.
/// The answer is how many entries it took back, with the doubts of its
/// write; with none, nothing is written.
pub fn revoke(home: &Path, url: &[u8], wait: Duration) -> Result<Revoked, Fault> {
    revoke_with(&Real, home, url, wait)
}

fn revoke_with(steps: &impl Steps, home: &Path, url: &[u8], wait: Duration) -> Result<Revoked, Fault> {
    url_acceptable(url).map_err(|_| Fault::Judgment(b"the URL is not one an entry can name"))?;
    let stamp = os::utc_stamp(os::wall(os::WallRole::AcceptedSourceEntry).seconds());
    let revoke = line(&jq::obj(vec![("at", jq::s(&stamp)), ("op", jq::s("revoke")), ("url", jq::arg(url))]));
    let at = path(home);
    let (file, created) = steps.open(&at)?;
    let mut count = 0;
    let written = steps.regular(&file, &at).and_then(|()| steps.lock(&file, &at, wait)).and_then(|()| steps.read(&file, &at)).and_then(|bytes| {
        count = read(&bytes).with_url(url).count();
        if count == 0 {
            return Ok(false);
        }
        put(steps, &file, &at, bytes.last().is_some_and(|&b| b != b'\n'), &revoke).map(|()| true)
    });
    match written {
        // Nothing stands, so nothing was written: the close of a file this
        // call only read changes no answer.
        Ok(false) => {
            let _ = steps.close(file);
            Ok(Revoked::default())
        }
        Ok(true) => finish(steps, file, home, &at, created, Ok(())).map(|c| Revoked { count, doubts: c.doubts }),
        Err(fault) => finish(steps, file, home, &at, created, Err(fault)).map(|_| Revoked::default()),
    }
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

fn revoked_json(r: &Revoked) -> String {
    jq::compact(&jq::obj(vec![
        ("revoked", jq::J::Num(r.count.to_string())),
        ("doubts", jq::J::Arr(r.doubts.iter().map(|d| jq::arg(&d.text())).collect())),
    ]))
}

/// `safedeps-core sources index`: `{"present":…,"entries":[…],"broken":…}`
/// on stdout. `safedeps-core sources revoke <url>`: `{"revoked":N,"doubts":
/// […]}`, each doubt what a step after the revoke line's commit returned;
/// the revoke stands with them. A fault is one line on stderr and exit 1; a
/// usage error is exit 2. Both read SAFEDEPS_HOME, and no hook runs them.
pub fn cli(args: &[String]) -> i32 {
    os::set_umask(0o077);
    let home = crate::state::guard_dir();
    let (out, said) = match args {
        [cmd] if cmd == "index" => (index(&home, LOCK_WAIT).map(|ix| index_json(&ix)), "the accepted-source ledger could not be read: "),
        [cmd, url] if cmd == "revoke" => (revoke(&home, url.as_bytes(), LOCK_WAIT).map(|r| revoked_json(&r)), "the accepted-source ledger could not take the revoke: "),
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
    use std::cell::{Cell, RefCell};

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

    fn lines(home: &Path) -> usize {
        fs::read(path(home)).unwrap_or_default().iter().filter(|b| **b == b'\n').count()
    }

    #[test]
    fn an_absent_ledger_is_an_answer_and_an_accepted_entry_stands_until_revoked() {
        let d = dir();
        assert_eq!(index(&d.0, LOCK_WAIT).unwrap(), Index::default());
        let (a, b) = (entry(URL, "sha512-one"), entry(URL, "sha512-two"));
        let committed = accept(&d.0, &[a.clone(), b], Some(b"toolu_1"), LOCK_WAIT).unwrap();
        assert!(committed.doubts.is_empty(), "{committed:?}");
        assert_eq!(lines(&d.0), 1, "one install, one line");
        let ix = index(&d.0, LOCK_WAIT).unwrap();
        assert!(ix.present && ix.broken == 0 && ix.entries.len() == 2);
        assert!(ix.find(URL.as_bytes(), b"sha512-one", b"x", b"1.0.1").is_some());
        assert_eq!(ix.with_url(URL.as_bytes()).count(), 2);
        for (url, integrity, package, version) in [(URL, "sha512-three", "x", "1.0.1"), (URL, "sha512-one", "y", "1.0.1"),
            (URL, "sha512-one", "x", "1.0.2"), ("https://example.test/x/-/x-1.0.1.tgz?", "sha512-one", "x", "1.0.1"),
            ("https://Example.test/x/-/x-1.0.1.tgz", "sha512-one", "x", "1.0.1")] {
            assert!(ix.find(url.as_bytes(), integrity.as_bytes(), package.as_bytes(), version.as_bytes()).is_none(), "{url} {integrity} {package}@{version}");
        }
        assert_eq!(revoke(&d.0, b"https://example.test/other.tgz", LOCK_WAIT).unwrap().count, 0);
        let revoked = revoke(&d.0, URL.as_bytes(), LOCK_WAIT).unwrap();
        assert_eq!((revoked.count, revoked.doubts.len()), (2, 0));
        let ix = index(&d.0, LOCK_WAIT).unwrap();
        assert!(ix.entries.is_empty() && ix.broken == 0, "{ix:?}");
        assert_eq!(revoke(&d.0, URL.as_bytes(), LOCK_WAIT).unwrap().count, 0, "nothing stands, so nothing is written");
        assert_eq!(lines(&d.0), 2, "one accept line and one revoke line");
        accept(&d.0, &[a], None, LOCK_WAIT).unwrap();
        assert_eq!(index(&d.0, LOCK_WAIT).unwrap().entries.len(), 1, "an acceptance after a revoke stands");
    }

    #[test]
    fn an_acceptance_that_would_stand_for_nothing_is_not_written() {
        let d = dir();
        let mut bad = entry("http://example.test/x.tgz", "sha512-one");
        assert!(accept(&d.0, &[bad], None, LOCK_WAIT).is_err());
        bad = entry(URL, "");
        assert!(accept(&d.0, &[bad], None, LOCK_WAIT).is_err());
        bad = entry(URL, "sha512-one");
        bad.advisories = vec![Vec::new()];
        assert!(accept(&d.0, &[entry(URL, "sha512-two"), bad], None, LOCK_WAIT).is_err(), "one entry that stands for nothing refuses the line");
        assert!(accept(&d.0, &[], None, LOCK_WAIT).is_err(), "no entry");
        assert!(accept(&d.0, &[entry(URL, "sha512-one"), entry("https://example.test/y.tgz", "sha512-two")], None, LOCK_WAIT).is_err(), "two URLs");
        let mut other = entry(URL, "sha512-two");
        other.reason = b"someone else".to_vec();
        assert!(accept(&d.0, &[entry(URL, "sha512-one"), other], None, LOCK_WAIT).is_err(), "two reasons");
        assert!(!path(&d.0).exists(), "no file was made");
    }

    #[test]
    fn a_line_that_is_not_one_of_the_two_stands_for_nothing_and_a_torn_tail_is_sealed() {
        let d = dir();
        let good = String::from_utf8(accept_line("2001-01-01T00:00:00Z", &[entry(URL, "sha512-one")], None)).unwrap();
        let mut extra: Value = json::parse_one(good.trim_end().as_bytes()).unwrap();
        if let Value::Obj(o) = &mut extra { o.push((b"more".to_vec(), Value::Null)); }
        let file = "{\"integrity\":\"sha512-one\",\"package\":\"x\",\"version\":\"1.0.1\",\"advisories\":[\"GHSA-aaaa-bbbb-cccc\"]}";
        let bad = [
            good.replace("\"op\":\"accept\"", "\"op\":\"approve\""),
            good.replace("2001-01-01T00:00:00Z", "yesterday"),
            good.replace("https://example.test", "http://example.test"),
            good.replace("\"advisories\":[\"GHSA-aaaa-bbbb-cccc\"]", "\"advisories\":\"GHSA-aaaa-bbbb-cccc\""),
            good.replace("\"tool_use_id\":null", "\"tool_use_id\":1"),
            good.replace(file, ""),
            good.replace(&format!("[{file}]"), file),
            good.replace(file, &file.replace(",\"version\":\"1.0.1\"", "")),
            good.replace(file, &file.replace("}", ",\"more\":null}")),
            good.replace(file, &format!("{file},{}", file.replace("\"package\":\"x\"", "\"package\":\"\""))),
            format!("{}\n", jq::compact(&jq::from_value(&extra))),
            "{\"at\":\"2001-01-01T00:00:00Z\",\"op\":\"accept\",\"url\":\"https://example.test/x/-/x-1.0.1.tgz\",\"integrity\":\"sha512-one\",\"package\":\"x\",\"version\":\"1.0.1\",\"advisories\":[],\"reason\":\"r\",\"project\":\"/p\",\"tool_use_id\":null}\n".to_string(),
            "{\"at\":\"2001-01-01T00:00:00Z\",\"op\":\"revoke\",\"url\":\"https://example.test/x/-/x-1.0.1.tgz\",\"why\":\"\"}\n".to_string(),
            format!("{}\u{0}\n", good.trim_end()),
            "not json\n".to_string(),
        ];
        for b in &bad { assert_ne!(b, &good, "each broken line differs from the good one"); }
        let mut bytes = good.clone().into_bytes();
        for b in &bad { bytes.extend(b.as_bytes()); }
        bytes.extend(&good.as_bytes()[..good.len() / 2]);
        fs::write(path(&d.0), &bytes).unwrap();
        let ix = index(&d.0, LOCK_WAIT).unwrap();
        assert_eq!((ix.entries.len(), ix.broken), (1, bad.len() + 1), "{ix:?}");
        accept(&d.0, &[entry(URL, "sha512-two")], None, LOCK_WAIT).unwrap();
        let ix = index(&d.0, LOCK_WAIT).unwrap();
        assert_eq!((ix.entries.len(), ix.broken), (2, bad.len() + 1), "the torn tail is one broken line and the new line stands: {ix:?}");
    }

    #[test]
    fn a_ledger_that_is_not_a_regular_file_or_is_held_is_an_error() {
        let d = dir();
        fs::create_dir(path(&d.0)).unwrap();
        assert!(index(&d.0, LOCK_WAIT).is_err());
        assert!(accept(&d.0, &[entry(URL, "sha512-one")], None, LOCK_WAIT).is_err());
        fs::remove_dir(path(&d.0)).unwrap();
        fs::write(path(&d.0), b"").unwrap();
        let holder = fs::OpenOptions::new().read(true).open(path(&d.0)).unwrap();
        assert!(os::try_flock(&holder).unwrap(), "the row holds the lock");
        let short = Duration::from_millis(50);
        assert!(matches!(index(&d.0, short), Err(Fault::Operation { outcome: Outcome::Deadline, .. })));
        assert!(matches!(accept(&d.0, &[entry(URL, "sha512-one")], None, short), Err(Fault::Operation { outcome: Outcome::Deadline, .. })));
        drop(holder);
        assert!(index(&d.0, short).unwrap().present);
    }

    /// How a driven write(2) goes.
    #[derive(Clone, Copy, PartialEq)]
    enum Put {
        /// As the system does it.
        Real,
        /// The first call returns `code` and puts nothing in.
        Fail,
        /// The first call puts this many bytes in, the next returns `code`.
        Short(usize),
        /// The first call returns 0.
        Zero,
        /// The first call is broken off by a signal, the rest are real.
        Interrupted,
    }

    /// The steps, each real unless it is `fail` (then it returns `code`), and
    /// the write as `put` says. It records the order of the steps it ran.
    struct Driven {
        fail: &'static str,
        code: i32,
        put: Put,
        puts: Cell<usize>,
        calls: RefCell<Vec<&'static str>>,
    }

    fn driven(fail: &'static str, code: i32, put: Put) -> Driven {
        Driven { fail, code, put, puts: Cell::new(0), calls: RefCell::new(Vec::new()) }
    }

    impl Driven {
        fn step(&self, name: &'static str) -> io::Result<()> {
            self.calls.borrow_mut().push(name);
            if self.fail == name { Err(io::Error::from_raw_os_error(self.code)) } else { Ok(()) }
        }
        fn calls(&self) -> Vec<&'static str> {
            self.calls.borrow().clone()
        }
    }

    impl Steps for Driven {
        fn open(&self, at: &Path) -> Result<(fs::File, bool), Fault> {
            observed(self.step("open"), at, |p| Action::Open(p))?;
            open_to_append(at)
        }
        fn regular(&self, file: &fs::File, at: &Path) -> Result<(), Fault> {
            observed(self.step("regular"), at, |p| Action::Read(p))?;
            regular(file, at)
        }
        fn lock(&self, file: &fs::File, at: &Path, wait: Duration) -> Result<(), Fault> {
            observed(self.step("lock"), at, |p| Action::Lock(p))?;
            lock(file, at, wait)
        }
        fn tail(&self, file: &fs::File, at: &Path) -> Result<bool, Fault> {
            observed(self.step("tail"), at, |p| Action::Read(p))?;
            torn(file, at)
        }
        fn read(&self, file: &fs::File, at: &Path) -> Result<Vec<u8>, Fault> {
            observed(self.step("read"), at, |p| Action::Read(p))?;
            whole(file, at)
        }
        fn write(&self, file: &fs::File, buf: &[u8]) -> io::Result<usize> {
            let n = self.puts.get();
            self.puts.set(n + 1);
            if n == 0 { self.calls.borrow_mut().push("write"); }
            let mut f: &fs::File = file;
            match (self.put, n) {
                (Put::Fail, 0) | (Put::Short(_), 1) => Err(io::Error::from_raw_os_error(self.code)),
                (Put::Short(k), 0) => f.write(&buf[..k.min(buf.len())]),
                (Put::Zero, 0) => Ok(0),
                (Put::Interrupted, 0) => Err(io::Error::from(io::ErrorKind::Interrupted)),
                _ => f.write(buf),
            }
        }
        fn sync(&self, file: &fs::File) -> io::Result<()> {
            self.step("sync")?;
            file.sync_data()
        }
        fn sync_dir(&self, dir: &Path) -> Result<(), Fault> {
            observed(self.step("sync-dir"), dir, |p| Action::Sync(p))?;
            Real.sync_dir(dir)
        }
        fn close(&self, file: fs::File) -> io::Result<()> {
            self.step("close")?;
            os::close_file(file)
        }
    }

    const EIO: i32 = 5;
    const ENOSPC: i32 = 28;

    fn stands(home: &Path, integrity: &str) -> bool {
        index(home, LOCK_WAIT).unwrap().find(URL.as_bytes(), integrity.as_bytes(), b"x", b"1.0.1").is_some()
    }

    /// The rule of the commit, step by step: an acceptance whose write did not
    /// put its whole line in answers a fault, and none of its entries stands;
    /// one whose line is in answers committed, and every entry stands, with a
    /// doubt for each step after the write that failed. Never an entry that
    /// stands beside a fault, which is what rolled an install back while its
    /// entry stood.
    #[test]
    fn an_entry_stands_exactly_when_the_write_answers_committed() {
        let rows: [(&str, &'static str, Put, bool, &[After]); 13] = [
            ("open fails", "open", Put::Real, false, &[]),
            ("not checked as a regular file", "regular", Put::Real, false, &[]),
            ("no lock", "lock", Put::Real, false, &[]),
            ("the last byte not read", "tail", Put::Real, false, &[]),
            ("the first write puts nothing in", "", Put::Fail, false, &[]),
            ("a short write", "", Put::Short(40), false, &[]),
            ("all but the newline", "", Put::Short(usize::MAX), false, &[]),
            ("a write that puts in nothing and says so", "", Put::Zero, false, &[]),
            ("a write a signal broke off", "", Put::Interrupted, true, &[]),
            ("as the system does it", "", Put::Real, true, &[]),
            ("the sync fails", "sync", Put::Real, true, &[After::Sync]),
            ("the directory's sync fails", "sync-dir", Put::Real, true, &[After::SyncDir]),
            ("the close fails", "close", Put::Real, true, &[After::Close]),
        ];
        for (what, fail, put, committed, doubts) in rows {
            let d = dir();
            let both = [entry(URL, "sha512-one"), entry(URL, "sha512-two")];
            // "all but the newline": the line less one byte.
            let put = match put { Put::Short(usize::MAX) => Put::Short(accept_line("2001-01-01T00:00:00Z", &both, None).len() - 1), p => p };
            let steps = driven(fail, if fail == "sync" { EIO } else { ENOSPC }, put);
            let answer = accept_with(&steps, &d.0, &both, None, LOCK_WAIT);
            let (one, two) = (stands(&d.0, "sha512-one"), stands(&d.0, "sha512-two"));
            assert_eq!((answer.is_ok(), one, two), (committed, committed, committed), "{what}: {answer:?}, calls {:?}", steps.calls());
            if let Ok(c) = answer {
                assert_eq!(c.doubts.iter().map(|d| d.step).collect::<Vec<_>>(), doubts, "{what}");
            }
            let ix = index(&d.0, LOCK_WAIT).unwrap();
            let torn = matches!(put, Put::Short(_)) && fail.is_empty();
            assert_eq!(ix.broken, usize::from(torn), "{what}: a torn piece is one broken line, and only a short write leaves one: {ix:?}");
            // The next write seals what this one left and stands.
            accept(&d.0, &[entry(URL, "sha512-three")], None, LOCK_WAIT).unwrap();
            assert!(stands(&d.0, "sha512-three"), "{what}: the next acceptance stands");
            assert_eq!((stands(&d.0, "sha512-one"), index(&d.0, LOCK_WAIT).unwrap().broken), (committed, usize::from(torn)), "{what}");
        }
    }

    #[test]
    fn a_failed_step_is_said_with_its_path_and_what_it_returned() {
        let d = dir();
        let at = path(&d.0);
        let e = [entry(URL, "sha512-one")];
        for (fail, put, said) in [
            ("open", Put::Real, format!("the open of {} returned OS error 28", at.display())),
            ("lock", Put::Real, format!("the lock of {} returned OS error 28", at.display())),
            ("", Put::Fail, format!("the write to {} returned OS error 28", at.display())),
            ("", Put::Short(10), format!("the write to {} returned OS error 28", at.display())),
            ("", Put::Zero, format!("the write to {} returned an error without an OS code", at.display())),
        ] {
            let fault = accept_with(&driven(fail, ENOSPC, put), &d.0, &e, None, LOCK_WAIT).unwrap_err();
            assert_eq!(String::from_utf8_lossy(&fault.text()), said);
        }
        let _ = fs::remove_file(&at);
        let c = accept_with(&driven("sync", EIO, Put::Real), &d.0, &e, None, LOCK_WAIT).unwrap();
        let said: Vec<String> = c.doubts.iter().map(|d| String::from_utf8_lossy(&d.text()).into_owned()).collect();
        assert_eq!(said, vec![format!("the sync of {} returned OS error 5", at.display())]);
    }

    #[test]
    fn the_steps_after_the_write_each_run_and_the_directory_is_synced_only_where_the_write_made_the_file() {
        let d = dir();
        let e = [entry(URL, "sha512-one")];
        let first = driven("", 0, Put::Real);
        accept_with(&first, &d.0, &e, None, LOCK_WAIT).unwrap();
        assert_eq!(first.calls(), ["open", "regular", "lock", "tail", "write", "sync", "sync-dir", "close"], "this write made the file");
        let next = driven("", 0, Put::Real);
        accept_with(&next, &d.0, &e, None, LOCK_WAIT).unwrap();
        assert_eq!(next.calls(), ["open", "regular", "lock", "tail", "write", "sync", "close"], "the file was there");
        let _ = fs::remove_file(path(&d.0));
        // Every step after the write fails: each is a doubt, in order, and the
        // entry stands.
        struct AllAfter(Driven);
        impl Steps for AllAfter {
            fn write(&self, file: &fs::File, buf: &[u8]) -> io::Result<usize> { self.0.write(file, buf) }
            fn sync(&self, _: &fs::File) -> io::Result<()> { Err(io::Error::from_raw_os_error(EIO)) }
            fn sync_dir(&self, dir: &Path) -> Result<(), Fault> { observed(Err(io::Error::from_raw_os_error(EIO)), dir, |p| Action::Sync(p)) }
            fn close(&self, file: fs::File) -> io::Result<()> { drop(file); Err(io::Error::from_raw_os_error(EIO)) }
        }
        let c = accept_with(&AllAfter(driven("", 0, Put::Real)), &d.0, &e, None, LOCK_WAIT).unwrap();
        assert_eq!(c.doubts.iter().map(|d| d.step).collect::<Vec<_>>(), [After::Sync, After::SyncDir, After::Close]);
        assert!(stands(&d.0, "sha512-one"));
        // A failed write runs no step after it but the close.
        let failed = driven("", ENOSPC, Put::Fail);
        assert!(accept_with(&failed, &d.0, &e, None, LOCK_WAIT).is_err());
        assert_eq!(failed.calls(), ["open", "regular", "lock", "tail", "write", "close"]);
    }

    #[test]
    fn a_seal_cut_short_is_sealed_again_by_the_next_write() {
        let d = dir();
        let good = accept_line("2001-01-01T00:00:00Z", &[entry(URL, "sha512-one")], None);
        fs::write(path(&d.0), &good[..good.len() - 1]).unwrap();
        // Only the NUL of the seal goes in.
        assert!(accept_with(&driven("", ENOSPC, Put::Short(1)), &d.0, &[entry(URL, "sha512-two")], None, LOCK_WAIT).is_err());
        let ix = index(&d.0, LOCK_WAIT).unwrap();
        assert_eq!((ix.entries.len(), ix.broken), (0, 1), "the old torn line, now with a NUL, is still one broken line: {ix:?}");
        accept(&d.0, &[entry(URL, "sha512-three")], None, LOCK_WAIT).unwrap();
        let ix = index(&d.0, LOCK_WAIT).unwrap();
        assert_eq!((ix.entries.len(), ix.broken), (1, 1), "{ix:?}");
    }

    /// A revoke whose line is in has taken the entries back, whatever the
    /// steps after it returned: it answers how many, with its doubts, never
    /// that it could not take the revoke. One whose line is not in answers a
    /// fault, and the entries stand.
    #[test]
    fn a_revoke_stands_exactly_when_its_write_answers_committed() {
        for (what, fail, put, committed) in [
            ("no lock", "lock", Put::Real, false),
            ("the file not read", "read", Put::Real, false),
            ("a short write", "", Put::Short(20), false),
            ("the sync fails", "sync", Put::Real, true),
            ("the close fails", "close", Put::Real, true),
            ("as the system does it", "", Put::Real, true),
        ] {
            let d = dir();
            accept(&d.0, &[entry(URL, "sha512-one"), entry(URL, "sha512-two")], None, LOCK_WAIT).unwrap();
            let answer = revoke_with(&driven(fail, EIO, put), &d.0, URL.as_bytes(), LOCK_WAIT);
            let standing = index(&d.0, LOCK_WAIT).unwrap().entries.len();
            assert_eq!((answer.is_ok(), standing), (committed, if committed { 0 } else { 2 }), "{what}: {answer:?}");
            if let Ok(r) = answer {
                assert_eq!(r.count, 2, "{what}");
                assert_eq!(r.doubts.len(), usize::from(!fail.is_empty()), "{what}");
            }
        }
    }

    #[test]
    fn the_revoke_answer_carries_its_doubts() {
        let d = dir();
        accept(&d.0, &[entry(URL, "sha512-one")], None, LOCK_WAIT).unwrap();
        let r = revoke_with(&driven("sync", EIO, Put::Real), &d.0, URL.as_bytes(), LOCK_WAIT).unwrap();
        assert_eq!(revoked_json(&r), format!("{{\"revoked\":1,\"doubts\":[\"the sync of {} returned OS error 5\"]}}", path(&d.0).display()));
        assert_eq!(revoked_json(&Revoked::default()), "{\"revoked\":0,\"doubts\":[]}");
    }

    /// The keys only narrow the search: entries whose keys are the same are
    /// still told apart byte for byte, and parts that join to the same bytes
    /// have two keys.
    #[test]
    fn a_lookup_compares_every_entry_it_finds() {
        assert_ne!(key(&[b"ab", b"c"]), key(&[b"a", b"bc"]));
        let mut ix = Index::new(true, vec![entry(URL, "sha512-one"), entry(URL, "sha512-two")], 0);
        // Every entry under one key, as a collision would put them.
        let k = key(&[URL.as_bytes(), b"sha512-one", b"x", b"1.0.1"]);
        ix.files = HashMap::from([(k, vec![0, 1])]);
        assert_eq!(ix.covering(URL.as_bytes(), b"sha512-one", b"x", b"1.0.1").count(), 1);
        assert_eq!(ix.with_url(URL.as_bytes()).count(), 2);
        assert_eq!(ix.with_url(b"https://example.test/other.tgz").count(), 0);
    }

    /// An entry stands where no revoke of its URL comes after its line, the
    /// same answer as taking the entries back line by line.
    #[test]
    fn revokes_and_acceptances_in_any_order_read_as_written() {
        let other = "https://example.test/y.tgz";
        let acc = |url: &str, integrity: &str| String::from_utf8(accept_line("2001-01-01T00:00:00Z", &[entry(url, integrity)], None)).unwrap();
        let rev = |url: &str| format!("{{\"at\":\"2001-01-01T00:00:00Z\",\"op\":\"revoke\",\"url\":\"{url}\"}}\n");
        let text = [acc(URL, "sha512-1"), acc(other, "sha512-2"), rev(URL), acc(URL, "sha512-3"), rev(other), rev(other), acc(URL, "sha512-4"), acc(other, "sha512-5")].concat();
        let ix = read(text.as_bytes());
        let left: Vec<&[u8]> = ix.entries.iter().map(|e| e.integrity.as_slice()).collect();
        assert_eq!(left, [b"sha512-3".as_slice(), b"sha512-4", b"sha512-5"]);
        assert_eq!(ix.broken, 0);
    }
}
