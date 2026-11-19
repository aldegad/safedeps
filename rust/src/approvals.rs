//! The approvals store: the record `re-check` reads to tell an approval that
//! `safedeps check` made from a ledger entry nobody approved.
//!
//! advisory.log is not that record. It is rotated and compacted, so what it
//! holds depends on which rotation read it last. The store is a file of its
//! own, and nothing in safedeps rotates, compacts, truncates, renames or
//! rewrites it: it only grows, by one line per approval.
//!
//! Where: `approvals.jsonl` in `SAFEDEPS_HOME`, derived from it and from
//! nothing else, as advisory.log is. No variable of its own names it, and the
//! CLI does not name it either: it asks this module (`safedeps-core
//! approvals`).
//!
//! A line is one JSON object with these four string fields, in this order:
//!
//!   at      the UTC time of the approval, `YYYY-MM-DDTHH:MM:SSZ`
//!   hash    the approved ledger entry's hash, `sha256:` and 64 hex digits
//!   via     `check` for an approval `safedeps check` wrote here, `migrate`
//!           for one moved in from advisory.log after its hash was checked
//!   record  the approval's line as advisory.log has it, `check approve(...`
//!
//! A line vouches for a ledger entry by its hash alone, compared whole with
//! the hash recomputed from the entry's own fields. The hash covers the
//! ecosystem, the package, the version and the project context. A match on
//! ecosystem, package and version would vouch for an entry of another
//! context, which no check approved.
//!
//! Isolation: the store lock, flock(2) on the store file itself. A writer
//! holds LOCK_EX for its whole write and a reader holds LOCK_SH for its whole
//! read, so a reader never sees a line half written and two writers never
//! write at once. Under the lock a writer first seals a torn last line (below),
//! then appends its own line in the same write and syncs it before it says
//! the line is written. The lock belongs to the open file and goes when the
//! file is closed, so a process that dies holding it leaves nothing to clean
//! up: the next writer or reader takes it at once. A lock another process
//! holds past LOCK_WAIT is an error: nothing is written or read without the
//! lock.
//!
//! The commit. An approval is three records: the ledger entry the hook reads,
//! the `check approve(...)` line in advisory.log a person reads, and the line
//! here that re-check and the cache lookup read. `commit` writes all three for
//! `safedeps check`, and it holds the store lock from before the first until
//! after the last, take-back included. So two commits never overlap, whatever
//! hash each approves, and a reader never sees an entry whose store line is
//! still to come. The CLI makes the entry and validates it in a staged file
//! beside the entry's path; the commit only renames that file into place and,
//! on a take-back, removes it. It never builds or reads an entry's bytes, so
//! the ledger's format keeps one writer, the CLI.
//!
//! Under the lock, in this order: the entry already at the path, if there is
//! one, kept aside under a second name; the rename; the approve line; the
//! store line. The store line is the commit point. A rename that fails puts
//! nothing in place, so it takes nothing back. A failure after the rename
//! takes the entry back, and the store read under the same lock decides how.
//! Where the store vouches for the hash, whoever's line it is, the entry that
//! stood at the path before this commit is put back, the same file, so a
//! failed check never takes away or rewrites an approval another check made
//! and reported, a revoked entry included. Where nothing stood there, this
//! commit's entry stays: no entry the store vouches for is removed (`kept`).
//! Where the store does not vouch, the entry is removed. Where the store
//! cannot be read, the entry is removed and the answer is `in-doubt`: it lets
//! no entry stand that nothing may vouch for.
//!
//! An append answers one of three things: Ok, and the two of `Appended`.
//! Written: the line is in the store and synced. Not written: the line is not
//! there, or only a torn piece of it is, which the next writer seals as one
//! broken line. Written, not synced: every byte of the line landed and a reader
//! sees it, but the sync failed, so nothing says it is on the disk. A commit
//! knows which of the three its own append answered. So it never takes a line
//! another check wrote for its own: not written is a failure, whatever the
//! store vouches for. Written, not synced is an approval that stands, named
//! `unsynced`.
//!
//! A commit whose process ended before it answered took its lock with it, and
//! the CLI settles it (`settle`): under the lock, the same take-back, with
//! advisory.log told how the commit ended. A store that vouches for the hash
//! then may vouch with the commit's own line or another's, and nothing tells
//! which, so the check answers that it is in doubt and the entry stays.
//!
//! The torn-line seal. A write that did not finish leaves a last line with no
//! newline: its process died, or the write failed after some of its bytes
//! landed. Those bytes can be anything, a whole record but for its newline
//! among them, and the write said its line was not written. So no later write
//! may finish that line. Where the last byte is not a newline, a writer puts
//! the seal, one NUL byte and a newline, before its own line. A line that
//! holds a NUL byte vouches for nothing, whatever else it holds, and no line a
//! writer makes holds one: JSON writes that byte as `\u0000`. So a sealed tail
//! is one broken line, whatever its bytes are. A seal that does not land whole
//! leaves a last line that still has no newline, and the next writer seals it
//! again. The seal is appended like any line: nothing is truncated or
//! rewritten.
//!
//! A line that is not one such object vouches for nothing: a torn line, a
//! sealed one, a broken one, one written by hand. Each is counted as broken in
//! the answer, so it is seen. A store that cannot be read is an error, never
//! an empty store. A store that is not there is an answer, `present: false`,
//! and vouches for nothing.

use crate::{
    jq,
    json::{self, Value},
    ledger, os, state,
};
use std::{
    collections::HashSet,
    fs,
    io::{self, Read, Write},
    os::unix::{
        ffi::OsStrExt,
        fs::{DirBuilderExt, FileExt, OpenOptionsExt},
    },
    path::{Path, PathBuf},
    time::Duration,
};

pub const FILE_NAME: &str = "approvals.jsonl";
/// What every record in the store starts with. advisory.log writes an
/// approval with the same words, and a record that does not start with them
/// is no approval. The parenthesis is part of it: `check approve-undone`, the
/// line that takes an approval back, is no approval.
pub const RECORD_PREFIX: &[u8] = b"check approve(";
const HASH_PREFIX: &str = "sha256:";
const FIELDS: [&str; 4] = ["at", "hash", "via", "record"];
/// The torn-line seal's byte. A writer ends a torn last line with it and a
/// newline, and a line that holds it vouches for nothing.
const SEAL: u8 = 0;
/// How long a writer or a reader waits for the store lock. A holder writes
/// one line or reads the file, so ten seconds is far past any honest holder.
const LOCK_WAIT: Duration = Duration::from_secs(10);

/// Who wrote a line.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Via {
    Check,
    Migrate,
}

impl Via {
    const ALL: [Self; 2] = [Self::Check, Self::Migrate];
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Check => "check",
            Self::Migrate => "migrate",
        }
    }
    fn parse(s: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|v| v.as_str() == s)
    }
}

pub fn path(dir: &Path) -> PathBuf {
    dir.join(FILE_NAME)
}

/// `sha256:` and 64 lowercase hex digits, the form ledger::hash writes.
pub fn is_hash(s: &str) -> bool {
    s.len() == HASH_PREFIX.len() + 64
        && s.starts_with(HASH_PREFIX)
        && s.bytes().skip(HASH_PREFIX.len()).all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

fn invalid(why: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, why.to_string())
}

/// One line of the store, with its newline.
fn line(at: &str, hash: &str, via: Via, record: &[u8]) -> Vec<u8> {
    let mut l = jq::compact(&jq::obj(vec![
        (FIELDS[0], jq::s(at)),
        (FIELDS[1], jq::s(hash)),
        (FIELDS[2], jq::s(via.as_str())),
        (FIELDS[3], jq::arg(record)),
    ]))
    .into_bytes();
    l.push(b'\n');
    l
}

/// The hash a line vouches for, or None for a line that is not one record.
fn approved_hash(line: &[u8]) -> Option<String> {
    fn text<'a>(v: &'a Value, key: &str) -> Option<&'a str> {
        v.get(key).and_then(Value::as_str)
    }
    let v = json::parse_one(line).ok()?;
    let Value::Obj(o) = &v else { return None };
    if o.len() != FIELDS.len() || !o.iter().all(|(k, _)| FIELDS.iter().any(|f| f.as_bytes() == k.as_slice())) {
        return None;
    }
    ledger::epoch(text(&v, "at")?)?;
    Via::parse(text(&v, "via")?)?;
    if !v.get("record")?.as_bytes()?.starts_with(RECORD_PREFIX) {
        return None;
    }
    let hash = text(&v, "hash")?;
    is_hash(hash).then(|| hash.to_string())
}

fn regular(file: fs::File) -> io::Result<fs::File> {
    if file.metadata()?.is_file() {
        Ok(file)
    } else {
        Err(io::Error::new(io::ErrorKind::InvalidData, "the approvals store is not a regular file"))
    }
}

/// The store, opened to be appended to. The directory and the file are made
/// where they are not there yet.
fn open_for_append(dir: &Path) -> io::Result<fs::File> {
    fs::DirBuilder::new().recursive(true).mode(0o700).create(dir)?;
    regular(fs::OpenOptions::new().read(true).append(true).create(true).mode(0o600).open(path(dir))?)
}

/// Why an append did not answer written. `NotWritten`: the line is not in the
/// store, or a torn piece of it is, which the next writer seals as one broken
/// line. `Unsynced`: the whole line is in the store and a reader sees it, but
/// the sync failed.
#[derive(Debug)]
pub enum Appended {
    NotWritten(io::Error),
    Unsynced(io::Error),
}

impl From<io::Error> for Appended {
    fn from(e: io::Error) -> Self {
        Self::NotWritten(e)
    }
}

/// Under LOCK_EX: seals a torn last line, then appends `lines` in the same
/// write and syncs them.
fn write_locked(file: &fs::File, lines: &[u8]) -> Result<(), Appended> {
    write_then_sync(file, lines, fs::File::sync_data)
}

/// The write, then `sync`. Only a write that put every byte in the store
/// reaches the sync, so a failed sync is a line a reader sees.
fn write_then_sync(file: &fs::File, lines: &[u8], sync: impl FnOnce(&fs::File) -> io::Result<()>) -> Result<(), Appended> {
    let len = file.metadata()?.len();
    let mut out = Vec::with_capacity(lines.len() + 2);
    if len > 0 {
        let mut last = [0u8; 1];
        file.read_exact_at(&mut last, len - 1)?;
        if last[0] != b'\n' {
            out.extend_from_slice(&[SEAL, b'\n']);
        }
    }
    out.extend_from_slice(lines);
    let mut f: &fs::File = file;
    f.write_all(&out)?;
    sync(file).map_err(Appended::Unsynced)
}

/// Records one approval `safedeps check` made: the ledger entry `hash`, and
/// `record`, its approve line as advisory.log gets it. Ok only once the line
/// is in the store and synced.
pub fn append(dir: &Path, hash: &str, record: &[u8]) -> Result<(), Appended> {
    append_within(dir, hash, record, LOCK_WAIT)
}

fn append_within(dir: &Path, hash: &str, record: &[u8], wait: Duration) -> Result<(), Appended> {
    if !is_hash(hash) {
        return Err(invalid("the hash is not sha256: and 64 lowercase hex digits").into());
    }
    if !record.starts_with(RECORD_PREFIX) {
        return Err(invalid("the record is not an approval (it does not start with `check approve(`)").into());
    }
    let at = os::utc_stamp(os::wall(os::WallRole::ApprovalRecord).seconds());
    let file = open_for_append(dir)?;
    os::flock_within(&file, os::FileLock::Exclusive, wait)?;
    write_locked(&file, &line(&at, hash, Via::Check, record))
}

/// What the store vouches for: each hash once, in the order of its first
/// line, and how many lines vouch for nothing.
#[derive(Debug, PartialEq, Eq)]
pub struct Index {
    pub present: bool,
    pub hashes: Vec<String>,
    pub broken: usize,
}

pub fn index(dir: &Path) -> io::Result<Index> {
    index_within(dir, LOCK_WAIT)
}

fn index_within(dir: &Path, wait: Duration) -> io::Result<Index> {
    let file = match fs::File::open(path(dir)) {
        Ok(f) => regular(f)?,
        Err(e) if e.kind() == io::ErrorKind::NotFound => {
            return Ok(Index { present: false, hashes: Vec::new(), broken: 0 });
        }
        Err(e) => return Err(e),
    };
    os::flock_within(&file, os::FileLock::Shared, wait)?;
    let mut bytes = Vec::new();
    let mut f: &fs::File = &file;
    f.read_to_end(&mut bytes)?;
    Ok(read(&bytes))
}

/// The store's bytes as an index. A last line with no newline is a write that
/// did not finish, and a line that holds the seal is one a later writer
/// sealed: each is broken like any other line that is not a record, whatever
/// else its bytes are.
fn read(bytes: &[u8]) -> Index {
    let mut seen = HashSet::new();
    let mut hashes = Vec::new();
    let mut broken = 0;
    for piece in bytes.split_inclusive(|&b| b == b'\n') {
        let finished = piece.strip_suffix(b"\n").filter(|l| !l.contains(&SEAL));
        match finished.and_then(approved_hash) {
            Some(h) => {
                if seen.insert(h.clone()) {
                    hashes.push(h);
                }
            }
            None => broken += 1,
        }
    }
    Index { present: true, hashes, broken }
}

/// `{"present":…,"hashes":{"sha256:…":true,…},"broken":…}`: an object keyed
/// by hash, so a jq reader looks an entry up in one step.
fn index_json(ix: &Index) -> String {
    jq::compact(&jq::obj(vec![
        ("present", jq::J::Bool(ix.present)),
        ("hashes", jq::J::Obj(ix.hashes.iter().map(|h| (h.clone(), jq::J::Bool(true))).collect())),
        ("broken", jq::J::Num(ix.broken.to_string())),
    ]))
}

/// The store, read through `file`, a descriptor that already holds the store
/// lock. A second open of the store would wait on that lock.
fn read_locked(file: &fs::File) -> io::Result<Index> {
    let len = usize::try_from(file.metadata()?.len()).map_err(|_| invalid("the approvals store is too large to read"))?;
    let mut bytes = vec![0u8; len];
    file.read_exact_at(&mut bytes, 0)?;
    Ok(read(&bytes))
}

const ADVISORY_LOG: &str = "advisory.log";
/// What remove(2) answers where a directory on the path is not a directory,
/// the same number on macOS and Linux: no entry can stand there.
const ENOTDIR: i32 = 20;

/// What a commit that did not approve left at the ledger entry's path.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Entry {
    /// The commit put nothing in place, and it removed nothing.
    Untouched,
    /// No entry is at the path after the take-back.
    Removed,
    /// An entry is at the path and stays, because the store vouches for the
    /// hash.
    Kept,
    /// An entry was to go and is still at the path: undo-failed.
    Left,
}

impl Entry {
    fn as_str(self) -> &'static str {
        match self {
            Self::Untouched => "untouched",
            Self::Removed => "removed",
            Self::Kept => "kept",
            Self::Left => "left",
        }
    }
}

/// Why a commit did not approve, in the word the check's report uses.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Failure {
    /// The entry could not be put in place, or its approve line could not be
    /// written. No store line was written.
    LedgerWrite,
    /// The store could not be opened and locked, and nothing was written; or
    /// the store did not take the line, and a read of it decided the
    /// take-back.
    Store,
    /// Whether the store holds the approval is not known: the store could not
    /// be read to decide the take-back, or a commit that ended before it
    /// answered left a hash the store vouches for.
    InDoubt,
}

impl Failure {
    fn as_str(self) -> &'static str {
        match self {
            Self::LedgerWrite => "ledger_write_failed",
            Self::Store => "approvals_store_failed",
            Self::InDoubt => "approvals_store_in_doubt",
        }
    }
}

#[derive(Debug, Eq, PartialEq)]
pub enum Answer {
    Approved,
    NotApproved(Failure, Entry),
}

/// One approval to commit: the entry's `hash`, the `staged` file the CLI made
/// and validated beside the entry's path `entry`, and `record`, its approve
/// line.
pub struct Approval<'a> {
    pub hash: &'a str,
    pub staged: &'a Path,
    pub entry: &'a Path,
    pub record: &'a [u8],
}

/// The entry's path ends in the file name the ledger gives `hash`, so a
/// take-back never removes another hash's entry.
fn entry_for(hash: &str, entry: &Path) -> io::Result<()> {
    if !is_hash(hash) {
        return Err(invalid("the hash is not sha256: and 64 lowercase hex digits"));
    }
    if entry.file_name().map(OsStrExt::as_bytes) != Some(ledger::filename(hash).as_bytes()) {
        return Err(invalid("the entry's path does not end in its hash's file name"));
    }
    Ok(())
}

/// An approval a commit acts on. The staged file sits in the entry's own
/// directory, so the rename never leaves it.
fn checked(a: &Approval) -> io::Result<()> {
    entry_for(a.hash, a.entry)?;
    if !a.record.starts_with(RECORD_PREFIX) {
        return Err(invalid("the record is not an approval (it does not start with `check approve(`)"));
    }
    if a.staged.file_name().is_none() || a.staged.parent() != a.entry.parent() || a.staged == a.entry {
        return Err(invalid("the staged entry is not a file beside the entry's path"));
    }
    Ok(())
}

fn note(err: &mut Vec<u8>, line: String) {
    err.extend_from_slice(line.as_bytes());
    err.push(b'\n');
}

/// How a failed I/O operation ended, in an advisory line's `outcome=`: the
/// error the kernel returned.
fn outcome(e: &io::Error) -> String {
    match e.raw_os_error() {
        Some(code) => format!("os-error-{code}"),
        None => "no-os-code".to_string(),
    }
}

/// How a commit process ended, as the CLI read its status: `exit-N` or
/// `signal-N`.
fn is_ended(s: &str) -> bool {
    s.split_once('-').is_some_and(|(how, n)| {
        matches!(how, "exit" | "signal") && (1..=3).contains(&n.len()) && n.bytes().all(|b| b.is_ascii_digit())
    })
}

/// One advisory.log line as the CLI writes one (`sf_advisory_log`):
/// `[<UTC time>] <text>`.
fn log_line(log: &Path, at: &str, text: &[u8]) -> io::Result<()> {
    let mut l = Vec::with_capacity(at.len() + text.len() + 4);
    l.push(b'[');
    l.extend_from_slice(at.as_bytes());
    l.extend_from_slice(b"] ");
    l.extend_from_slice(text);
    l.push(b'\n');
    let mut f = fs::OpenOptions::new().create(true).append(true).mode(0o600).open(log)?;
    f.write_all(&l)
}

fn log_now(log: &Path, text: String) {
    let at = os::utc_stamp(os::wall(os::WallRole::AdvisoryHeader).seconds());
    let _ = log_line(log, &at, text.as_bytes());
}

/// The store, opened and locked for a commit or a settle. The lock goes with
/// the file.
fn locked(dir: &Path, wait: Duration) -> io::Result<fs::File> {
    let file = open_for_append(dir)?;
    os::flock_within(&file, os::FileLock::Exclusive, wait)?;
    Ok(file)
}

/// The second name a commit keeps the entry already at the path under, in the
/// entry's own directory: it starts with a dot and does not end in `.json`, so
/// no ledger reader lists it.
fn prev_of(entry: &Path) -> PathBuf {
    let mut name = std::ffi::OsString::from(".");
    name.push(entry.file_name().unwrap_or_default());
    name.push(".prev");
    entry.with_file_name(name)
}

/// Under the lock, before the rename: the entry at the path, if there is one,
/// kept aside as a second name for the same file, so a take-back can put it
/// back as it was. A second name a commit that ended left is removed first.
fn keep_prev(entry: &Path, prev: &Path) -> io::Result<()> {
    match fs::remove_file(prev) {
        Err(e) if e.kind() != io::ErrorKind::NotFound => return Err(e),
        _ => {}
    }
    match fs::hard_link(entry, prev) {
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
        r => r,
    }
}

/// The take-back of `entry`, under the store lock `file` holds. The store,
/// read through `file`, decides. It vouches for `hash`: the entry kept aside
/// at `prev` is put back, or, where none was, the entry at the path stays
/// (`Kept`). It does not, or it cannot be read: the entry is removed, and the
/// one kept aside goes with it, as the rename already took it from the path.
/// `ended` says how the commit ended where advisory.log holds its approve line
/// or may: the take-back then says there what it did. Returns what is left at
/// the path, and whether the store could be read.
fn take_back(
    file: &fs::File,
    hash: &str,
    entry: &Path,
    read: impl FnOnce(&fs::File) -> io::Result<Index>,
    ended: Option<&str>,
    log: &Path,
    err: &mut Vec<u8>,
) -> (Entry, bool) {
    let prev = prev_of(entry);
    let vouched = read(file).map(|ix| ix.hashes.iter().any(|h| h == hash));
    match &vouched {
        Ok(true) => {
            let put_back = fs::symlink_metadata(&prev).is_ok() && fs::rename(&prev, entry).is_ok();
            if !put_back && fs::symlink_metadata(entry).is_err() {
                return (Entry::Removed, true);
            }
            let which = if put_back { "the one that stood there before this check is back" } else { "this check's stays" };
            note(err, format!("safedeps: kept: the approvals store vouches for {hash}, so the ledger entry {} is not removed: {which}. This check does not report it as its approval.", entry.display()));
            if let Some(how) = ended {
                log_now(log, format!("check approve-kept hash={hash} outcome={how}"));
            }
            return (Entry::Kept, true);
        }
        Ok(false) => {
            if let Some(how) = ended {
                log_now(log, format!("check approve-undone hash={hash} outcome={how}"));
            }
        }
        Err(e) => {
            note(err, format!("safedeps: in-doubt: the approvals store could not be read back ({e}). The approval of {hash} is taken back, and the store may vouch for it."));
            if let Some(how) = ended {
                log_now(log, format!("check approve-in-doubt hash={hash} outcome={how}"));
            }
        }
    }
    let _ = fs::remove_file(entry);
    let _ = fs::remove_file(&prev);
    match fs::symlink_metadata(entry) {
        Err(e) if e.kind() == io::ErrorKind::NotFound || e.raw_os_error() == Some(ENOTDIR) => (Entry::Removed, vouched.is_ok()),
        _ => {
            note(err, format!("safedeps: undo-failed: the ledger entry {} could not be removed. Whatever it holds stays where the hook reads it, and no approval stands behind it.", entry.display()));
            log_now(log, format!("check approve-undo-failed hash={hash} entry={}", entry.display()));
            (Entry::Left, vouched.is_ok())
        }
    }
}

/// Commits one approval for `safedeps check`: under the store lock, the
/// rename of the staged entry, the approve line in advisory.log and the store
/// line, and the take-back when one of them fails. What it cannot rule out it
/// names on `err`: `unsynced`, `kept`, `in-doubt`, `undo-failed`.
pub fn commit(dir: &Path, a: &Approval, err: &mut Vec<u8>) -> Answer {
    commit_with(dir, a, LOCK_WAIT, write_locked, read_locked, err)
}

fn commit_with(
    dir: &Path,
    a: &Approval,
    wait: Duration,
    write: impl FnOnce(&fs::File, &[u8]) -> Result<(), Appended>,
    read: impl FnOnce(&fs::File) -> io::Result<Index>,
    err: &mut Vec<u8>,
) -> Answer {
    let file = match locked(dir, wait) {
        Ok(f) => f,
        Err(e) => {
            note(err, format!("safedeps-core approvals: not committed: {} could not be opened and locked: {e}", path(dir).display()));
            return Answer::NotApproved(Failure::Store, Entry::Untouched);
        }
    };
    // From here to the answer the store lock is held. It goes with `file`.
    let prev = prev_of(a.entry);
    if let Err(e) = keep_prev(a.entry, &prev) {
        note(err, format!("safedeps-core approvals: not committed: the ledger entry {} could not be kept aside at {}: {e}", a.entry.display(), prev.display()));
        return Answer::NotApproved(Failure::LedgerWrite, Entry::Untouched);
    }
    if let Err(e) = fs::rename(a.staged, a.entry) {
        let _ = fs::remove_file(&prev);
        note(err, format!("safedeps-core approvals: not committed: the ledger entry {} could not be put in place: {e}", a.entry.display()));
        return Answer::NotApproved(Failure::LedgerWrite, Entry::Untouched);
    }
    let at = os::utc_stamp(os::wall(os::WallRole::ApprovalRecord).seconds());
    let log = dir.join(ADVISORY_LOG);
    if let Err(e) = log_line(&log, &at, a.record) {
        note(err, format!("safedeps-core approvals: not committed: the approve line could not be written to {}: {e}", log.display()));
        let (entry, _) = take_back(&file, a.hash, a.entry, read, None, &log, err);
        return Answer::NotApproved(Failure::LedgerWrite, entry);
    }
    match write(&file, &line(&at, a.hash, Via::Check, a.record)) {
        Ok(()) => {
            let _ = fs::remove_file(&prev);
            Answer::Approved
        }
        Err(Appended::Unsynced(e)) => {
            let _ = fs::remove_file(&prev);
            let how = outcome(&e);
            note(err, format!("safedeps: unsynced: the approvals store line of {} was written and not synced ({how}). The approval stands, and nothing confirms that its line is on the disk.", a.hash));
            log_now(&log, format!("check approve-unsynced hash={} outcome={how}", a.hash));
            Answer::Approved
        }
        Err(Appended::NotWritten(e)) => {
            note(err, format!("safedeps-core approvals: not written to {}: {e}", path(dir).display()));
            let how = outcome(&e);
            let (entry, read) = take_back(&file, a.hash, a.entry, read, Some(how.as_str()), &log, err);
            Answer::NotApproved(if read { Failure::Store } else { Failure::InDoubt }, entry)
        }
    }
}

/// Settles a commit whose process ended (`ended`, `exit-N` or `signal-N`)
/// after it renamed its entry into place and before it answered: under the
/// store lock, the commit's take-back. The CLI asks only where the staged file
/// is gone, so the rename happened. A store that vouches for the hash may
/// vouch with the commit's own line, so that answer is in doubt, and the
/// entry is not removed.
pub fn settle(dir: &Path, hash: &str, entry: &Path, ended: &str, err: &mut Vec<u8>) -> Answer {
    settle_with(dir, hash, entry, ended, LOCK_WAIT, read_locked, err)
}

fn settle_with(
    dir: &Path,
    hash: &str,
    entry: &Path,
    ended: &str,
    wait: Duration,
    read: impl FnOnce(&fs::File) -> io::Result<Index>,
    err: &mut Vec<u8>,
) -> Answer {
    let file = match locked(dir, wait) {
        Ok(f) => f,
        Err(e) => {
            note(err, format!("safedeps: in-doubt: the commit of {hash} ended with {ended}, and {} could not be opened and locked to settle it: {e}", path(dir).display()));
            return Answer::NotApproved(Failure::InDoubt, Entry::Untouched);
        }
    };
    let (left, read) = take_back(&file, hash, entry, read, Some(ended), &dir.join(ADVISORY_LOG), err);
    let failure = if read && left != Entry::Kept { Failure::Store } else { Failure::InDoubt };
    Answer::NotApproved(failure, left)
}

/// A commit's or a settle's answer as the command gives it: `approved` and
/// exit 0, or `not-approved <failure> <entry>` and exit 1.
fn answer_line(answer: &Answer) -> (i32, Vec<u8>) {
    match answer {
        Answer::Approved => (0, b"approved\n".to_vec()),
        Answer::NotApproved(f, e) => (1, format!("not-approved {} {}\n", f.as_str(), e.as_str()).into_bytes()),
    }
}

const USAGE: &str = "usage: safedeps-core approvals append <hash> (the record on stdin) | commit <hash> <staged> <entry> (the record on stdin) | settle <hash> <entry> <exit-N|signal-N> | index\n";

/// `safedeps-core approvals commit <hash> <staged> <entry>`, the record on
/// stdin (one trailing newline is not part of it): the approval committed
/// (`commit`), and its answer on stdout, `approved` and exit 0 or
/// `not-approved <failure> <entry>` and exit 1. Exit 2 for an argument that is
/// not one, and nothing is written.
/// `safedeps-core approvals settle <hash> <entry> <exit-N|signal-N>`: a commit
/// whose process ended before it answered, settled (`settle`), and the same
/// answer, always exit 1.
/// `safedeps-core approvals append <hash>`, the record on stdin: the store
/// line alone, under the store lock. Exit 0 when the line is written, 1 when
/// it is not, 3 when it is written and not synced, 2 for a hash or a record
/// that is not one. No check calls it: it is the store's own write, which the
/// approvals-store battery cuts with a file size limit.
/// `safedeps-core approvals index`: the index on stdout and exit 0, or exit 1
/// when the store cannot be read.
pub fn cli(args: &[String]) -> i32 {
    os::set_umask(0o077);
    let mut stdin = Vec::new();
    match args.first().map(String::as_str) {
        Some("append") if io::stdin().read_to_end(&mut stdin).is_err() => {
            eprintln!("safedeps-core approvals: not written: the record could not be read from stdin");
            return 1;
        }
        Some("commit") if io::stdin().read_to_end(&mut stdin).is_err() => {
            eprintln!("safedeps-core approvals: not committed: the record could not be read from stdin");
            println!("not-approved {} {}", Failure::LedgerWrite.as_str(), Entry::Untouched.as_str());
            return 1;
        }
        _ => {}
    }
    let (code, out, err) = run(&state::guard_dir(), args, &stdin);
    let _ = io::stderr().write_all(&err);
    let mut so = io::stdout().lock();
    if so.write_all(&out).is_err() || so.flush().is_err() {
        return 1;
    }
    code
}

/// The command against the store in `dir`: exit status, stdout, stderr.
fn run(dir: &Path, args: &[String], stdin: &[u8]) -> (i32, Vec<u8>, Vec<u8>) {
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    let store = path(dir);
    match args.as_slice() {
        ["append", hash] => {
            let record = stdin.strip_suffix(b"\n").unwrap_or(stdin);
            answer(append(dir, hash, record), &store)
        }
        ["commit", hash, staged, entry] => {
            let a = Approval {
                hash,
                staged: Path::new(staged),
                entry: Path::new(entry),
                record: stdin.strip_suffix(b"\n").unwrap_or(stdin),
            };
            if let Err(e) = checked(&a) {
                return (2, Vec::new(), format!("safedeps-core approvals: not committed: {e}\n").into_bytes());
            }
            let mut err = Vec::new();
            let (code, out) = answer_line(&commit(dir, &a, &mut err));
            (code, out, err)
        }
        ["settle", hash, entry, ended] => {
            if let Err(e) = entry_for(hash, Path::new(entry)) {
                return (2, Vec::new(), format!("safedeps-core approvals: not settled: {e}\n").into_bytes());
            }
            if !is_ended(ended) {
                return (2, Vec::new(), b"safedeps-core approvals: not settled: how the commit ended is not exit-N or signal-N\n".to_vec());
            }
            let mut err = Vec::new();
            let (code, out) = answer_line(&settle(dir, hash, Path::new(entry), ended, &mut err));
            (code, out, err)
        }
        ["index"] => match index(dir) {
            Ok(ix) => (0, format!("{}\n", index_json(&ix)).into_bytes(), Vec::new()),
            Err(e) => (1, Vec::new(), format!("safedeps-core approvals: {} could not be read: {}\n", store.display(), e).into_bytes()),
        },
        _ => (2, Vec::new(), USAGE.as_bytes().to_vec()),
    }
}

/// An append's answer as the command gives it: exit status, stdout, stderr.
fn answer(appended: Result<(), Appended>, store: &Path) -> (i32, Vec<u8>, Vec<u8>) {
    match appended {
        Ok(()) => (0, Vec::new(), Vec::new()),
        Err(Appended::NotWritten(e)) if e.kind() == io::ErrorKind::InvalidInput => {
            (2, Vec::new(), format!("safedeps-core approvals: not written: {}\n", e).into_bytes())
        }
        Err(Appended::NotWritten(e)) => {
            (1, Vec::new(), format!("safedeps-core approvals: not written to {}: {}\n", store.display(), e).into_bytes())
        }
        Err(Appended::Unsynced(e)) => (
            3,
            Vec::new(),
            format!("safedeps-core approvals: written to {} and not synced: {}\n", store.display(), e).into_bytes(),
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::MetadataExt;

    struct Dir(PathBuf);
    impl Drop for Dir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    fn scratch() -> Dir {
        Dir(os::scratch_dir("safedeps-approvals-test").expect("a scratch directory"))
    }
    fn h(n: u8) -> String {
        format!("{}{}", HASH_PREFIX, format!("{:02x}", n).repeat(32))
    }
    fn rec(n: u8) -> Vec<u8> {
        format!("check approve(clean) ecosystem=npm package=p{} version=1.0.0 hash={}", n, h(n)).into_bytes()
    }
    /// A store line another check wrote: the store's own write, under its
    /// lock, with no entry and no approve line. No command writes a line
    /// alone; a test uses it to make a store that vouches.
    fn append(dir: &Path, hash: &str, record: &[u8]) -> Result<(), Appended> {
        append_within(dir, hash, record, LOCK_WAIT)
    }
    fn append_within(dir: &Path, hash: &str, record: &[u8], wait: Duration) -> Result<(), Appended> {
        let at = os::utc_stamp(os::wall(os::WallRole::ApprovalRecord).seconds());
        let file = locked(dir, wait)?;
        write_locked(&file, &line(&at, hash, Via::Check, record))
    }
    fn not_written(r: Result<(), Appended>) -> io::Error {
        match r {
            Err(Appended::NotWritten(e)) => e,
            other => panic!("not a not-written answer: {other:?}"),
        }
    }
    fn holder(dir: &Path, lock: os::FileLock) -> fs::File {
        let f = fs::OpenOptions::new().read(true).append(true).create(true).mode(0o600).open(path(dir)).unwrap();
        os::flock_within(&f, lock, Duration::from_secs(1)).unwrap();
        f
    }
    fn ino(p: &Path) -> u64 {
        fs::metadata(p).unwrap().ino()
    }

    #[test]
    fn an_append_is_one_record_line_the_index_reads() {
        let d = scratch();
        let home = d.0.join("home");
        append(&home, &h(1), &rec(1)).unwrap();
        let bytes = fs::read(path(&home)).unwrap();
        assert_eq!(bytes.iter().filter(|&&b| b == b'\n').count(), 1);
        assert!(bytes.ends_with(b"\n"));
        let v = json::parse_one(&bytes[..bytes.len() - 1]).unwrap();
        let Value::Obj(o) = &v else { panic!("a line is an object") };
        let keys: Vec<&[u8]> = o.iter().map(|(k, _)| k.as_slice()).collect();
        assert_eq!(keys, FIELDS.iter().map(|f| f.as_bytes()).collect::<Vec<_>>());
        assert!(ledger::epoch(v.get("at").unwrap().as_str().unwrap()).is_some());
        assert_eq!(v.get("hash").unwrap().as_str(), Some(h(1).as_str()));
        assert_eq!(v.get("via").unwrap().as_str(), Some("check"));
        assert_eq!(v.get("record").unwrap().as_bytes(), Some(rec(1)));
        assert_eq!(index(&home).unwrap(), Index { present: true, hashes: vec![h(1)], broken: 0 });
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(fs::metadata(path(&home)).unwrap().permissions().mode() & 0o777, 0o600);
        assert_eq!(fs::metadata(&home).unwrap().permissions().mode() & 0o777, 0o700);
    }

    #[test]
    fn a_missing_store_vouches_for_nothing_and_is_not_made_by_a_read() {
        let d = scratch();
        let home = d.0.join("home");
        assert_eq!(index(&home).unwrap(), Index { present: false, hashes: Vec::new(), broken: 0 });
        assert!(!home.exists());
    }

    #[test]
    fn a_store_that_is_not_a_regular_file_is_an_error() {
        let d = scratch();
        fs::create_dir_all(path(&d.0)).unwrap();
        assert!(index(&d.0).is_err());
        let (staged, entry) = stage(&d.0, 1, "entry of 1");
        let (hash, r) = (h(1), rec(1));
        let answer = commit(&d.0, &approval(1, &staged, &entry, &r, &hash), &mut Vec::new());
        assert_eq!(answer, Answer::NotApproved(Failure::Store, Entry::Untouched));
        assert!(staged.exists() && !entry.exists());
    }

    #[test]
    fn a_line_that_is_not_a_record_vouches_for_nothing_and_is_counted() {
        let d = scratch();
        let ok = |n: u8, via: Via| line("2026-11-19T08:00:00Z", &h(n), via, &rec(n));
        let mut bytes = Vec::new();
        bytes.extend(ok(5, Via::Check));
        bytes.extend(ok(6, Via::Migrate));
        bytes.extend(b"garbage\n");
        bytes.extend(b"\n");
        bytes.extend(br#"{"at":"2026-11-19T08:00:00Z","hash":"sha256:0707070707070707070707070707070707070707070707070707070707070707","via":"check","record":"check approve x","extra":"1"}"#);
        bytes.push(b'\n');
        bytes.extend(br#"{"at":"2026-11-19T08:00:00Z","hash":"sha256:0808080808080808080808080808080808080808080808080808080808080808","via":"check"}"#);
        bytes.push(b'\n');
        bytes.extend(line("2026-11-19T08:00:00Z", &format!("{}{}", HASH_PREFIX, "AB".repeat(32)), Via::Check, &rec(9)));
        bytes.extend(ok(10, Via::Check));
        bytes.extend(String::from_utf8(ok(11, Via::Check)).unwrap().replace("\"check\"", "\"manual\"").into_bytes());
        bytes.extend(String::from_utf8(ok(12, Via::Check)).unwrap().replace("2026-11-19T08:00:00Z", "yesterday").into_bytes());
        bytes.extend(line("2026-11-19T08:00:00Z", &h(13), Via::Check, b"check block ecosystem=npm package=p version=1"));
        bytes.extend(line("2026-11-19T08:00:00Z", &h(16), Via::Check, format!("check approve-undone hash={}", h(16)).as_bytes()));
        bytes.extend(ok(5, Via::Check));
        let whole15 = ok(15, Via::Check);
        bytes.extend(sealed(&whole15[..whole15.len() - 1]));
        bytes.extend(&ok(14, Via::Check)[..20]);
        fs::write(path(&d.0), &bytes).unwrap();
        let ix = index(&d.0).unwrap();
        // Eleven lines vouch for nothing: garbage, an empty line, an extra
        // field, a missing field, an uppercase hash, an unknown via, a time
        // that is no time, a record that is no approval, the line that takes
        // an approval back, a whole record a writer sealed and a torn tail.
        // The repeated h(5) is a record and counts once.
        assert_eq!(ix.hashes, vec![h(5), h(6), h(10)]);
        assert_eq!(ix.broken, 11);
        assert!(ix.present);
    }

    /// A torn tail as the next writer leaves it: the tail, then the seal.
    fn sealed(tail: &[u8]) -> Vec<u8> {
        [tail, &[SEAL, b'\n'][..]].concat()
    }

    /// What the next append left in `dir` after `before`: the seal, then one
    /// line, a record of `n`. Nothing before it was rewritten.
    fn sealed_then_record(dir: &Path, before: &[u8], n: u8) {
        let bytes = fs::read(path(dir)).unwrap();
        let kept = sealed(before);
        assert!(bytes.starts_with(&kept), "the next append rewrote what was there or did not seal it");
        let new = &bytes[kept.len()..];
        assert_eq!(new.iter().filter(|&&b| b == b'\n').count(), 1);
        assert_eq!(new.strip_suffix(b"\n").and_then(approved_hash), Some(h(n)));
    }

    fn unended(l: &[u8]) -> Vec<u8> {
        l[..l.len() - 1].to_vec()
    }

    #[test]
    fn a_whole_record_that_lost_only_its_newline_vouches_for_nothing_after_the_next_append() {
        // A failed append can land every byte of its line but the newline
        // (a file size limit one byte short), and it says the line was not
        // written. The next append must not finish that line.
        let d = scratch();
        let whole = line("2026-11-19T08:00:00Z", &h(1), Via::Check, &rec(1));
        let tail = unended(&whole);
        assert_eq!(approved_hash(&tail), Some(h(1)), "the tail is a whole record but for its newline");
        fs::write(path(&d.0), &tail).unwrap();
        assert_eq!(index(&d.0).unwrap(), Index { present: true, hashes: Vec::new(), broken: 1 });
        append(&d.0, &h(2), &rec(2)).unwrap();
        assert_eq!(index(&d.0).unwrap(), Index { present: true, hashes: vec![h(2)], broken: 1 });
        sealed_then_record(&d.0, &tail, 2);
    }

    #[test]
    fn a_torn_tail_is_sealed_as_one_broken_line_whatever_its_bytes() {
        let d = scratch();
        let first = line("2026-11-19T08:00:00Z", &h(1), Via::Check, &rec(1));
        let whole = line("2026-11-19T08:00:00Z", &h(4), Via::Check, &rec(4));
        let other = line("2026-11-19T08:00:00Z", &h(5), Via::Migrate, &rec(5));
        // Every prefix of a record, the last of them the whole record but its
        // newline; a seal that lost its own newline, once and twice; and
        // tails that hold a whole record of another hash beside a NUL.
        let mut tails: Vec<Vec<u8>> = (1..whole.len()).map(|k| whole[..k].to_vec()).collect();
        tails.push([unended(&whole), vec![SEAL]].concat());
        tails.push([unended(&whole), vec![SEAL, SEAL]].concat());
        tails.push([vec![SEAL], unended(&other)].concat());
        tails.push([unended(&whole), vec![SEAL], unended(&other)].concat());
        for (i, tail) in tails.iter().enumerate() {
            assert!(!tail.contains(&b'\n'), "tail {i} holds a newline");
            let dir = d.0.join(i.to_string());
            fs::create_dir_all(&dir).unwrap();
            let before = [&first[..], &tail[..]].concat();
            fs::write(path(&dir), &before).unwrap();
            assert_eq!(index(&dir).unwrap(), Index { present: true, hashes: vec![h(1)], broken: 1 }, "tail {i} before");
            append(&dir, &h(2), &rec(2)).unwrap();
            assert_eq!(index(&dir).unwrap(), Index { present: true, hashes: vec![h(1), h(2)], broken: 1 }, "tail {i} after");
            sealed_then_record(&dir, &before, 2);
            let ended = fs::read(path(&dir)).unwrap();
            append(&dir, &h(3), &rec(3)).unwrap();
            let bytes = fs::read(path(&dir)).unwrap();
            assert!(bytes.starts_with(&ended) && !bytes[ended.len()..].contains(&SEAL), "tail {i}: an ended line was sealed again");
            assert_eq!(index(&dir).unwrap(), Index { present: true, hashes: vec![h(1), h(2), h(3)], broken: 1 }, "tail {i} later");
        }
    }

    #[test]
    fn no_line_a_writer_makes_holds_the_seal() {
        let d = scratch();
        let mut record = rec(1);
        record.extend((0u8..0x20).chain([0x7f]));
        append(&d.0, &h(1), &record).unwrap();
        let bytes = fs::read(path(&d.0)).unwrap();
        assert!(!bytes.contains(&SEAL));
        assert_eq!(bytes.iter().filter(|&&b| b == b'\n').count(), 1);
        assert_eq!(index(&d.0).unwrap(), Index { present: true, hashes: vec![h(1)], broken: 0 });
        let stored = json::parse_one(&bytes[..bytes.len() - 1]).unwrap();
        assert_eq!(stored.get("record").unwrap().as_bytes(), Some(record));
    }

    #[test]
    fn concurrent_commits_each_land_as_one_whole_line() {
        let d = scratch();
        let threads: Vec<_> = (0..8u8)
            .map(|t| {
                let dir = d.0.clone();
                std::thread::spawn(move || {
                    for k in 0..25u8 {
                        let n = t * 25 + k;
                        let (staged, entry) = stage(&dir, n, &format!("entry of {n}"));
                        let (hash, r) = (h(n), rec(n));
                        assert_eq!(commit(&dir, &approval(n, &staged, &entry, &r, &hash), &mut Vec::new()), Answer::Approved);
                    }
                })
            })
            .collect();
        for t in threads {
            t.join().unwrap();
        }
        let ix = index(&d.0).unwrap();
        assert_eq!(ix.broken, 0);
        let mut got = ix.hashes.clone();
        got.sort();
        let mut want: Vec<String> = (0..200u8).map(h).collect();
        want.sort();
        assert_eq!(got, want);
        assert_eq!(fs::read(path(&d.0)).unwrap().iter().filter(|&&b| b == b'\n').count(), 200);
        assert_eq!(logged(&d.0).len(), 200);
    }

    #[test]
    fn a_reader_waits_for_a_line_being_written() {
        let d = scratch();
        let whole = line("2026-11-19T08:00:00Z", &h(2), Via::Check, &rec(2));
        let held = holder(&d.0, os::FileLock::Exclusive);
        let mut w: &fs::File = &held;
        w.write_all(&whole[..25]).unwrap();
        let dir = d.0.clone();
        let reader = std::thread::spawn(move || index(&dir));
        std::thread::sleep(Duration::from_millis(300));
        assert!(!reader.is_finished(), "the reader read while a writer held the lock");
        w.write_all(&whole[25..]).unwrap();
        drop(held);
        assert_eq!(reader.join().unwrap().unwrap(), Index { present: true, hashes: vec![h(2)], broken: 0 });
    }

    #[test]
    fn a_lock_held_past_the_wait_is_an_error_and_nothing_is_written() {
        let d = scratch();
        let held = holder(&d.0, os::FileLock::Exclusive);
        let e = not_written(append_within(&d.0, &h(1), &rec(1), Duration::from_millis(100)));
        assert_eq!(e.kind(), io::ErrorKind::TimedOut);
        assert_eq!(index_within(&d.0, Duration::from_millis(100)).unwrap_err().kind(), io::ErrorKind::TimedOut);
        drop(held);
        assert_eq!(fs::metadata(path(&d.0)).unwrap().len(), 0);
    }

    #[test]
    fn readers_share_the_lock() {
        let d = scratch();
        append(&d.0, &h(1), &rec(1)).unwrap();
        let _held = holder(&d.0, os::FileLock::Shared);
        assert_eq!(index_within(&d.0, Duration::from_millis(100)).unwrap().hashes, vec![h(1)]);
    }

    #[test]
    fn a_sync_that_fails_after_a_whole_write_is_unsynced_and_the_line_is_seen() {
        // No file system here fails a sync on demand, so the sync is the one
        // part a test puts in: the write and the store are the real ones.
        let d = scratch();
        let file = open_for_append(&d.0).unwrap();
        let whole = line("2026-11-19T08:00:00Z", &h(1), Via::Check, &rec(1));
        match write_then_sync(&file, &whole, |_| Err(io::Error::from_raw_os_error(5))) {
            Err(Appended::Unsynced(e)) => assert_eq!(e.raw_os_error(), Some(5)),
            other => panic!("a failed sync answered {other:?}"),
        }
        drop(file);
        assert_eq!(fs::read(path(&d.0)).unwrap(), whole);
        assert_eq!(index(&d.0).unwrap(), Index { present: true, hashes: vec![h(1)], broken: 0 });
    }

    #[test]
    fn a_write_that_fails_never_reaches_the_sync_and_is_not_written() {
        let d = scratch();
        drop(open_for_append(&d.0).unwrap());
        let read_only = fs::File::open(path(&d.0)).unwrap();
        let whole = line("2026-11-19T08:00:00Z", &h(1), Via::Check, &rec(1));
        let r = write_then_sync(&read_only, &whole, |_| panic!("a failed write reached the sync"));
        assert!(matches!(r, Err(Appended::NotWritten(_))), "{r:?}");
        assert_eq!(index(&d.0).unwrap(), Index { present: true, hashes: Vec::new(), broken: 0 });
    }

    // ---- the commit ----------------------------------------------------------

    /// A staged entry of `n` holding `body`, beside its path in the ledger
    /// under `home`. Returns the staged file and the entry's path.
    fn stage(home: &Path, n: u8, body: &str) -> (PathBuf, PathBuf) {
        let dir = home.join("approved-specs");
        fs::create_dir_all(&dir).unwrap();
        let entry = dir.join(ledger::filename(&h(n)));
        let mut k = 0;
        let staged = loop {
            let s = dir.join(format!(".{}.staged{k}", ledger::filename(&h(n))));
            if fs::OpenOptions::new().write(true).create_new(true).open(&s).is_ok() {
                break s;
            }
            k += 1;
        };
        fs::write(&staged, body).unwrap();
        (staged, entry)
    }
    /// An entry of `n` holding `body` at its path, as an earlier check left it.
    /// Returns the path.
    fn stand(home: &Path, n: u8, body: &str) -> PathBuf {
        let (staged, entry) = stage(home, n, body);
        fs::rename(&staged, &entry).unwrap();
        entry
    }
    /// advisory.log in `home`, each line without its time.
    fn logged(home: &Path) -> Vec<String> {
        fs::read_to_string(home.join(ADVISORY_LOG))
            .unwrap_or_default()
            .lines()
            .map(|l| {
                assert!(l.starts_with('[') && l.as_bytes().get(21..23) == Some(b"] ".as_slice()), "not a CLI line: {l}");
                assert!(ledger::epoch(&l[1..21]).is_some(), "no time: {l}");
                l[23..].to_string()
            })
            .collect()
    }
    fn record(n: u8) -> String {
        String::from_utf8(rec(n)).unwrap()
    }
    fn approval<'a>(n: u8, staged: &'a Path, entry: &'a Path, record: &'a [u8], hash: &'a str) -> Approval<'a> {
        assert_eq!(hash, h(n));
        Approval { hash, staged, entry, record }
    }
    fn held_elsewhere(home: &Path) -> bool {
        let other = fs::File::open(path(home)).unwrap();
        match os::flock_within(&other, os::FileLock::Exclusive, Duration::ZERO) {
            Ok(()) => false,
            Err(e) if e.kind() == io::ErrorKind::TimedOut => true,
            Err(e) => panic!("the lock check failed: {e}"),
        }
    }
    fn not_now(_: &fs::File, _: &[u8]) -> Result<(), Appended> {
        panic!("the store line was written after an earlier step failed")
    }
    fn efbig(_: &fs::File, _: &[u8]) -> Result<(), Appended> {
        Err(Appended::NotWritten(io::Error::from_raw_os_error(27)))
    }
    fn eio(_: &fs::File) -> io::Result<Index> {
        Err(io::Error::from_raw_os_error(5))
    }
    /// Neither of a commit's two second names is beside the entry.
    fn nothing_beside(entry: &Path) -> bool {
        !prev_of(entry).exists() && fs::symlink_metadata(none_of(entry)).is_err()
    }

    #[test]
    fn a_commit_writes_the_three_records_with_the_store_lock_held_throughout() {
        let d = scratch();
        let (staged, entry) = stage(&d.0, 1, "entry of 1");
        let (hash, r) = (h(1), rec(1));
        let a = approval(1, &staged, &entry, &r, &hash);
        let mut err = Vec::new();
        let answer = commit_with(
            &d.0,
            &a,
            LOCK_WAIT,
            |file, l| {
                // The rename and the approve line came first, and the lock
                // has been held since before them. Nothing stood at the path,
                // and a second name says so.
                assert!(held_elsewhere(&d.0), "the store lock is not held while the commit writes");
                assert_eq!(fs::read_to_string(&entry).unwrap(), "entry of 1");
                assert_eq!(logged(&d.0), vec![record(1)]);
                assert!(none_of(&entry).exists() && !prev_of(&entry).exists(), "no second name says that nothing stood at the path");
                write_locked(file, l)
            },
            read_locked,
            &mut err,
        );
        assert_eq!(answer, Answer::Approved);
        assert!(err.is_empty(), "{}", String::from_utf8_lossy(&err));
        assert!(!staged.exists());
        assert!(nothing_beside(&entry), "a second name outlived the commit");
        assert_eq!(fs::read_to_string(&entry).unwrap(), "entry of 1");
        assert_eq!(logged(&d.0), vec![record(1)]);
        assert_eq!(index(&d.0).unwrap(), Index { present: true, hashes: vec![h(1)], broken: 0 });
        let stored = fs::read(path(&d.0)).unwrap();
        let v = json::parse_one(&stored[..stored.len() - 1]).unwrap();
        // One reading of the clock stamps the store line and the approve line.
        let line = fs::read_to_string(d.0.join(ADVISORY_LOG)).unwrap();
        assert_eq!(v.get("at").unwrap().as_str(), Some(&line[1..21]));
        assert!(!held_elsewhere(&d.0), "the lock outlived the commit");
    }

    #[test]
    fn a_commit_takes_the_lock_before_it_puts_anything_in_place() {
        let d = scratch();
        let (staged, entry) = stage(&d.0, 1, "entry of 1");
        let (hash, r) = (h(1), rec(1));
        let held = holder(&d.0, os::FileLock::Exclusive);
        let mut err = Vec::new();
        let answer = commit_with(&d.0, &approval(1, &staged, &entry, &r, &hash), Duration::from_millis(100), not_now, read_locked, &mut err);
        drop(held);
        assert_eq!(answer, Answer::NotApproved(Failure::Store, Entry::Untouched));
        assert!(staged.exists() && !entry.exists(), "the entry was put in place without the lock");
        assert!(nothing_beside(&entry));
        assert!(!d.0.join(ADVISORY_LOG).exists());
        assert_eq!(fs::metadata(path(&d.0)).unwrap().len(), 0);
        assert!(String::from_utf8(err).unwrap().starts_with("safedeps-core approvals: not committed: "));
    }

    #[test]
    fn commits_of_one_hash_never_overlap_and_a_failed_one_leaves_the_next_whole() {
        // A holds the lock and fails at its store line; B commits the same
        // hash meanwhile. B waits, puts nothing in place until A is done, and
        // its records stand at the end.
        let d = scratch();
        let (staged_a, entry) = stage(&d.0, 1, "entry of A");
        let (staged_b, _) = stage(&d.0, 1, "entry of B");
        let (hash, r) = (h(1), rec(1));
        let (in_a, a_done) = (std::sync::Barrier::new(2), std::sync::atomic::AtomicBool::new(false));
        std::thread::scope(|s| {
            let b = s.spawn(|| {
                in_a.wait();
                let mut err = Vec::new();
                let answer = commit(&d.0, &approval(1, &staged_b, &entry, &r, &hash), &mut err);
                assert!(a_done.load(std::sync::atomic::Ordering::SeqCst), "B committed while A held the lock");
                answer
            });
            let mut err = Vec::new();
            let answer = commit_with(
                &d.0,
                &approval(1, &staged_a, &entry, &r, &hash),
                LOCK_WAIT,
                |file, l| {
                    in_a.wait();
                    std::thread::sleep(Duration::from_millis(300));
                    assert!(staged_b.exists(), "B put its entry in place inside A's commit");
                    a_done.store(true, std::sync::atomic::Ordering::SeqCst);
                    efbig(file, l)
                },
                read_locked,
                &mut err,
            );
            assert_eq!(answer, Answer::NotApproved(Failure::Store, Entry::Removed));
            assert_eq!(b.join().unwrap(), Answer::Approved);
        });
        assert_eq!(fs::read_to_string(&entry).unwrap(), "entry of B");
        assert!(nothing_beside(&entry));
        assert_eq!(index(&d.0).unwrap().hashes, vec![h(1)]);
        let undone = format!("check approve-undone hash={} outcome=os-error-27", h(1));
        assert_eq!(logged(&d.0), vec![record(1), undone, record(1)]);
    }

    #[test]
    fn a_rename_that_fails_puts_nothing_in_place_and_takes_nothing_back() {
        for stood in [true, false] {
            let d = scratch();
            let (staged, entry) = stage(&d.0, 1, "entry of 1");
            if stood {
                fs::write(&entry, "an entry that was there").unwrap();
            }
            fs::remove_file(&staged).unwrap();
            let (hash, r) = (h(1), rec(1));
            let mut err = Vec::new();
            let answer = commit_with(&d.0, &approval(1, &staged, &entry, &r, &hash), LOCK_WAIT, not_now, read_locked, &mut err);
            assert_eq!(answer, Answer::NotApproved(Failure::LedgerWrite, Entry::Untouched));
            if stood {
                assert_eq!(fs::read_to_string(&entry).unwrap(), "an entry that was there");
            } else {
                assert!(!entry.exists());
            }
            assert!(nothing_beside(&entry), "a second name stayed after a rename that failed");
            assert!(logged(&d.0).is_empty());
            assert!(String::from_utf8(err).unwrap().contains("could not be put in place"));
        }
    }

    #[test]
    fn an_approve_line_that_fails_takes_this_checks_entry_away_whoever_vouches() {
        // Where nothing stood at the path, nothing stands there after, even
        // where the store vouches for the hash with another check's line: an
        // entry of a check that answered failure is no approval to find.
        for vouched in [false, true] {
            let d = scratch();
            if vouched {
                append(&d.0, &h(1), &rec(1)).unwrap();
            }
            fs::create_dir_all(d.0.join(ADVISORY_LOG)).unwrap();
            let (staged, entry) = stage(&d.0, 1, "entry of 1");
            let (hash, r) = (h(1), rec(1));
            let mut err = Vec::new();
            let answer = commit_with(&d.0, &approval(1, &staged, &entry, &r, &hash), LOCK_WAIT, not_now, read_locked, &mut err);
            let err = String::from_utf8(err).unwrap();
            assert!(err.contains("the approve line could not be written"), "{err}");
            assert_eq!(answer, Answer::NotApproved(Failure::LedgerWrite, Entry::Removed), "vouched={vouched}");
            assert!(!entry.exists(), "vouched={vouched}: this check's entry stands");
            assert!(!staged.exists() && nothing_beside(&entry));
            assert_eq!(index(&d.0).unwrap().hashes, if vouched { vec![h(1)] } else { Vec::new() });
        }
    }

    #[test]
    fn a_take_back_puts_back_the_entry_that_stood_there_unless_the_store_says_it_is_no_approval() {
        // (where the commit fails, the store vouches) -> what stands at the end
        for (at_store, vouched) in [(false, true), (true, true), (false, false), (true, false)] {
            let d = scratch();
            if vouched {
                append(&d.0, &h(1), &rec(1)).unwrap();
            }
            let entry = stand(&d.0, 1, "the entry A approved");
            let before = ino(&entry);
            // A commit that ended left its second names, holding other bytes.
            fs::write(prev_of(&entry), "left by a commit that ended").unwrap();
            fs::write(none_of(&entry), "").unwrap();
            if !at_store {
                fs::create_dir_all(d.0.join(ADVISORY_LOG)).unwrap();
            }
            let (staged, _) = stage(&d.0, 1, "the entry B wrote");
            let (hash, r) = (h(1), rec(1));
            let mut err = Vec::new();
            let answer = commit_with(&d.0, &approval(1, &staged, &entry, &r, &hash), LOCK_WAIT, efbig, read_locked, &mut err);
            let failure = if at_store { Failure::Store } else { Failure::LedgerWrite };
            if vouched {
                assert_eq!(answer, Answer::NotApproved(failure, Entry::Restored), "at_store={at_store}");
                assert_eq!(fs::read_to_string(&entry).unwrap(), "the entry A approved");
                assert_eq!(ino(&entry), before, "the entry put back is not the file that stood there");
            } else {
                assert_eq!(answer, Answer::NotApproved(failure, Entry::Removed), "at_store={at_store}");
                assert!(!entry.exists());
            }
            assert!(!staged.exists() && nothing_beside(&entry), "the commit left a file behind");
        }
        // A commit that approves replaces the entry, and keeps nothing aside.
        let d = scratch();
        let entry = stand(&d.0, 1, "the entry A approved");
        let (staged, _) = stage(&d.0, 1, "the entry B wrote");
        let (hash, r) = (h(1), rec(1));
        let answer = commit(&d.0, &approval(1, &staged, &entry, &r, &hash), &mut Vec::new());
        assert_eq!(answer, Answer::Approved);
        assert_eq!(fs::read_to_string(&entry).unwrap(), "the entry B wrote");
        assert!(nothing_beside(&entry));
        assert_eq!(prev_of(&entry).file_name().unwrap().to_str().unwrap(), format!(".{}.prev", ledger::filename(&h(1))));
        assert_eq!(none_of(&entry).file_name().unwrap().to_str().unwrap(), format!(".{}.none", ledger::filename(&h(1))));
    }

    #[test]
    fn a_store_line_not_written_is_no_approval_whoever_vouches() {
        // vouched: the store already vouches for the hash with another line.
        // torn: the failed write left a piece of its own line.
        for (vouched, torn) in [(false, false), (false, true), (true, false)] {
            let d = scratch();
            if vouched {
                append(&d.0, &h(1), &rec(1)).unwrap();
            }
            let (staged, entry) = stage(&d.0, 1, "entry of 1");
            let (hash, r) = (h(1), rec(1));
            let mut err = Vec::new();
            let answer = commit_with(
                &d.0,
                &approval(1, &staged, &entry, &r, &hash),
                LOCK_WAIT,
                |file, l| {
                    if torn {
                        let mut w: &fs::File = file;
                        w.write_all(&l[..l.len() / 2]).unwrap();
                    }
                    efbig(file, l)
                },
                read_locked,
                &mut err,
            );
            let err = String::from_utf8(err).unwrap();
            assert!(err.starts_with(&format!("safedeps-core approvals: not written to {}: ", path(&d.0).display())), "{err}");
            assert_eq!(answer, Answer::NotApproved(Failure::Store, Entry::Removed), "vouched={vouched}");
            assert!(!entry.exists() && nothing_beside(&entry));
            assert_eq!(logged(&d.0), vec![record(1), format!("check approve-undone hash={} outcome=os-error-27", h(1))]);
            let ix = index(&d.0).unwrap();
            assert_eq!(ix.hashes, if vouched { vec![h(1)] } else { Vec::new() });
            assert_eq!(ix.broken, usize::from(torn));
        }
    }

    #[test]
    fn a_take_back_the_store_cannot_be_read_for_puts_back_the_entry_that_stood_there() {
        // The store could not be read, so nothing says the entry that stood
        // at the path is no approval: it comes back, the same file. This
        // check's entry goes.
        for (at_store, stood) in [(true, true), (true, false), (false, true), (false, false)] {
            let d = scratch();
            let entry = if stood { stand(&d.0, 1, "the entry A approved") } else { d.0.join("approved-specs").join(ledger::filename(&h(1))) };
            let before = stood.then(|| ino(&entry));
            if !at_store {
                fs::create_dir_all(d.0.join(ADVISORY_LOG)).unwrap();
            }
            let (staged, _) = stage(&d.0, 1, "the entry B wrote");
            let (hash, r) = (h(1), rec(1));
            let mut err = Vec::new();
            let answer = commit_with(&d.0, &approval(1, &staged, &entry, &r, &hash), LOCK_WAIT, efbig, eio, &mut err);
            let failure = if at_store { Failure::InDoubt } else { Failure::LedgerWrite };
            if stood {
                assert_eq!(answer, Answer::NotApproved(failure, Entry::Restored), "at_store={at_store}");
                assert_eq!(fs::read_to_string(&entry).unwrap(), "the entry A approved");
                assert_eq!(Some(ino(&entry)), before, "the entry that stood there is not back");
            } else {
                assert_eq!(answer, Answer::NotApproved(failure, Entry::Removed), "at_store={at_store}");
                assert!(!entry.exists());
            }
            assert!(!staged.exists() && nothing_beside(&entry), "the take-back left a file behind");
            assert!(String::from_utf8(err).unwrap().contains("safedeps: in-doubt: the approvals store could not be read back"));
            if at_store {
                assert_eq!(logged(&d.0), vec![record(1), format!("check approve-in-doubt hash={} outcome=os-error-27", h(1))]);
            }
        }
    }

    #[test]
    fn a_store_line_written_and_not_synced_is_an_approval_named_unsynced() {
        let d = scratch();
        let (staged, entry) = stage(&d.0, 1, "entry of 1");
        let (hash, r) = (h(1), rec(1));
        let mut err = Vec::new();
        let answer = commit_with(
            &d.0,
            &approval(1, &staged, &entry, &r, &hash),
            LOCK_WAIT,
            |file, l| write_then_sync(file, l, |_| Err(io::Error::from_raw_os_error(5))),
            |_| panic!("an approval read the store back"),
            &mut err,
        );
        assert_eq!(answer, Answer::Approved);
        assert!(String::from_utf8(err).unwrap().starts_with(&format!("safedeps: unsynced: the approvals store line of {} was written and not synced (os-error-5).", h(1))));
        assert_eq!(logged(&d.0), vec![record(1), format!("check approve-unsynced hash={} outcome=os-error-5", h(1))]);
        assert_eq!(fs::read_to_string(&entry).unwrap(), "entry of 1");
        assert!(nothing_beside(&entry));
        assert_eq!(index(&d.0).unwrap().hashes, vec![h(1)]);
    }

    #[test]
    fn a_take_back_the_ledger_refuses_is_left_and_named() {
        use std::os::unix::fs::PermissionsExt;
        let d = scratch();
        let (staged, entry) = stage(&d.0, 1, "entry of 1");
        let dir = entry.parent().unwrap().to_path_buf();
        let (hash, r) = (h(1), rec(1));
        let mut err = Vec::new();
        let answer = commit_with(
            &d.0,
            &approval(1, &staged, &entry, &r, &hash),
            LOCK_WAIT,
            |file, l| {
                fs::set_permissions(&dir, fs::Permissions::from_mode(0o500)).unwrap();
                efbig(file, l)
            },
            read_locked,
            &mut err,
        );
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
        assert_eq!(answer, Answer::NotApproved(Failure::Store, Entry::Left));
        assert!(entry.exists());
        assert!(String::from_utf8(err).unwrap().contains(&format!("safedeps: undo-failed: the ledger entry {} could not be removed.", entry.display())));
        assert_eq!(
            logged(&d.0),
            vec![
                record(1),
                format!("check approve-undone hash={} outcome=os-error-27", h(1)),
                format!("check approve-undo-failed hash={} entry={}", h(1), entry.display()),
            ]
        );
    }

    // ---- the settle ------------------------------------------------------------

    /// What stood at the path before a commit that ended, as its second names
    /// say. `Stood`: an entry, kept at `.prev`. `Nothing`: `.none`. `Neither`:
    /// no second name, as after a later commit or revoke of the same entry.
    #[derive(Clone, Copy, Debug)]
    enum Mark {
        Stood,
        Nothing,
        Neither,
    }

    #[test]
    fn a_settle_takes_back_what_the_ended_commit_put_in_place_and_nothing_else() {
        // (mark, store vouches) -> answer, what is at the path, line
        use Mark::*;
        for (mark, vouched) in [(Stood, false), (Stood, true), (Nothing, false), (Nothing, true), (Neither, false), (Neither, true)] {
            let d = scratch();
            if vouched {
                append(&d.0, &h(1), &rec(1)).unwrap();
            }
            let (earlier, entry) = stage(&d.0, 1, "the entry A approved");
            let earlier_ino = ino(&earlier);
            match mark {
                Stood => fs::hard_link(&earlier, prev_of(&entry)).unwrap(),
                Nothing => fs::write(none_of(&entry), "").unwrap(),
                Neither => {}
            }
            fs::remove_file(&earlier).unwrap();
            // The commit that ended put its entry in place; under Neither it
            // is the entry a later commit left.
            fs::write(&entry, "the entry at the path").unwrap();
            let mut err = Vec::new();
            let answer = settle(&d.0, &h(1), &entry, "signal-9", &mut err);
            let line = |word: &str| vec![format!("check approve-{word} hash={} outcome=signal-9", h(1))];
            let failure = if vouched { Failure::InDoubt } else { Failure::Store };
            match (mark, vouched) {
                (Stood, true) => {
                    assert_eq!(answer, Answer::NotApproved(failure, Entry::Restored));
                    assert_eq!(fs::read_to_string(&entry).unwrap(), "the entry A approved");
                    assert_eq!(ino(&entry), earlier_ino);
                }
                (Stood, false) | (Nothing, _) => {
                    assert_eq!(answer, Answer::NotApproved(failure, Entry::Removed), "{mark:?} vouched={vouched}");
                    assert!(!entry.exists(), "{mark:?} vouched={vouched}: the ended commit's entry stands");
                }
                (Neither, _) => {
                    assert_eq!(answer, Answer::NotApproved(failure, Entry::Untouched), "vouched={vouched}");
                    assert_eq!(fs::read_to_string(&entry).unwrap(), "the entry at the path", "a settle took back an entry another commit left");
                }
            }
            assert!(nothing_beside(&entry), "{mark:?} vouched={vouched}: a second name stayed");
            assert_eq!(logged(&d.0), line(if vouched { "in-doubt" } else { "undone" }), "{mark:?} vouched={vouched}");
            assert!(!held_elsewhere(&d.0));
        }
        // A settle that cannot take the lock takes nothing back.
        let d = scratch();
        let held = holder(&d.0, os::FileLock::Exclusive);
        let (_, entry) = stage(&d.0, 1, "entry of 1");
        let mut err = Vec::new();
        let answer = settle_with(&d.0, &h(1), &entry, "exit-1", Duration::from_millis(100), read_locked, &mut err);
        drop(held);
        assert_eq!(answer, Answer::NotApproved(Failure::InDoubt, Entry::Unsettled));
        assert!(String::from_utf8(err).unwrap().starts_with(&format!("safedeps: in-doubt: the commit of {} ended with exit-1", h(1))));
        // A settle that cannot read the store puts back the entry that stood
        // there, as a commit does.
        let d = scratch();
        let (earlier, entry) = stage(&d.0, 1, "the entry A approved");
        fs::hard_link(&earlier, prev_of(&entry)).unwrap();
        fs::remove_file(&earlier).unwrap();
        fs::write(&entry, "the entry the ended commit wrote").unwrap();
        let answer = settle_with(&d.0, &h(1), &entry, "signal-9", LOCK_WAIT, eio, &mut Vec::new());
        assert_eq!(answer, Answer::NotApproved(Failure::InDoubt, Entry::Restored));
        assert_eq!(fs::read_to_string(&entry).unwrap(), "the entry A approved");
        assert!(nothing_beside(&entry));
    }

    // ---- the revoke ------------------------------------------------------------

    /// A revoke of the entry at `entry` as the CLI makes it: a second name for
    /// the file it read (`seen`), and the revoked entry staged beside.
    fn seen_and_staged(home: &Path, n: u8, entry: &Path, body: &str) -> (PathBuf, PathBuf) {
        let seen = entry.with_file_name(format!(".{}.seen", ledger::filename(&h(n))));
        fs::hard_link(entry, &seen).unwrap();
        let (staged, _) = stage(home, n, body);
        (seen, staged)
    }
    fn revocation<'a>(n: u8, hash: &'a str, staged: &'a Path, entry: &'a Path, seen: &'a Path) -> Revoke<'a> {
        assert_eq!(hash, h(n));
        Revoke { hash, staged, entry, seen }
    }

    #[test]
    fn a_revoke_puts_its_entry_in_place_only_where_the_entry_is_the_file_it_read() {
        // The entry the revoke read stands: it is replaced.
        let d = scratch();
        let entry = stand(&d.0, 1, "the entry A approved");
        let (seen, staged) = seen_and_staged(&d.0, 1, &entry, "the entry A approved, revoked");
        let staged_ino = ino(&staged);
        let hash = h(1);
        let mut err = Vec::new();
        assert_eq!(revoke(&d.0, &revocation(1, &hash, &staged, &entry, &seen), &mut err), Revoked::Revoked);
        assert!(err.is_empty(), "{}", String::from_utf8_lossy(&err));
        assert_eq!(fs::read_to_string(&entry).unwrap(), "the entry A approved, revoked");
        assert_eq!(ino(&entry), staged_ino);
        assert!(!staged.exists() && seen.exists(), "the revoke removed a file the CLI owns");
        assert!(!held_elsewhere(&d.0));
        // Another file stands at the path, or none does: nothing is put in
        // place, and the answer is that the entry changed.
        for replaced in [true, false] {
            let d = scratch();
            let entry = stand(&d.0, 1, "the entry A approved");
            let (seen, staged) = seen_and_staged(&d.0, 1, &entry, "the entry A approved, revoked");
            if replaced {
                stand(&d.0, 1, "the entry B approved");
            } else {
                fs::remove_file(&entry).unwrap();
            }
            let mut err = Vec::new();
            assert_eq!(revoke(&d.0, &revocation(1, &hash, &staged, &entry, &seen), &mut err), Revoked::Changed, "replaced={replaced}");
            if replaced {
                assert_eq!(fs::read_to_string(&entry).unwrap(), "the entry B approved");
            } else {
                assert!(!entry.exists());
            }
            assert!(staged.exists(), "the revoke removed a file the CLI owns");
        }
    }

    #[test]
    fn a_revoke_that_cannot_lock_or_rename_puts_nothing_in_place() {
        let d = scratch();
        let entry = stand(&d.0, 1, "the entry A approved");
        let (seen, staged) = seen_and_staged(&d.0, 1, &entry, "the entry A approved, revoked");
        let hash = h(1);
        let held = holder(&d.0, os::FileLock::Exclusive);
        let mut err = Vec::new();
        let r = revocation(1, &hash, &staged, &entry, &seen);
        let answer = revoke_with(&d.0, &r, Duration::from_millis(100), |_, _| panic!("a revoke renamed without the lock"), &mut err);
        drop(held);
        assert_eq!(answer, Revoked::NotRevoked);
        assert!(String::from_utf8(err).unwrap().starts_with("safedeps-core approvals: not revoked: "));
        let mut err = Vec::new();
        let answer = revoke_with(&d.0, &r, LOCK_WAIT, |_, _| Err(io::Error::from_raw_os_error(13)), &mut err);
        assert_eq!(answer, Revoked::NotRevoked);
        assert!(String::from_utf8(err).unwrap().contains("could not be put in place"));
        assert_eq!(fs::read_to_string(&entry).unwrap(), "the entry A approved");
        assert!(staged.exists());
    }

    #[test]
    fn a_revoke_waits_for_a_commit_that_holds_the_lock() {
        // B holds the lock inside its commit, after its rename. A revoke of
        // the same entry waits; B then fails, and its take-back puts back the
        // entry A approved. The revoke finds that the entry is not the file
        // it read, and puts nothing in place.
        let d = scratch();
        append(&d.0, &h(1), &rec(1)).unwrap();
        let entry = stand(&d.0, 1, "the entry A approved");
        let (staged_b, _) = stage(&d.0, 1, "the entry B wrote");
        let (hash, r) = (h(1), rec(1));
        let (in_b, b_done) = (std::sync::Barrier::new(2), std::sync::atomic::AtomicBool::new(false));
        std::thread::scope(|s| {
            let revoker = s.spawn(|| {
                in_b.wait();
                // B's entry is in place: the revoke reads it.
                let (seen, staged) = seen_and_staged(&d.0, 1, &entry, "the entry B wrote, revoked");
                let answer = revoke(&d.0, &revocation(1, &hash, &staged, &entry, &seen), &mut Vec::new());
                assert!(b_done.load(std::sync::atomic::Ordering::SeqCst), "the revoke ran while B held the lock");
                answer
            });
            let answer = commit_with(
                &d.0,
                &approval(1, &staged_b, &entry, &r, &hash),
                LOCK_WAIT,
                |file, l| {
                    in_b.wait();
                    std::thread::sleep(Duration::from_millis(300));
                    assert_eq!(fs::read_to_string(&entry).unwrap(), "the entry B wrote", "the revoke put its entry in place inside B's commit");
                    b_done.store(true, std::sync::atomic::Ordering::SeqCst);
                    efbig(file, l)
                },
                read_locked,
                &mut Vec::new(),
            );
            assert_eq!(answer, Answer::NotApproved(Failure::Store, Entry::Restored));
            assert_eq!(revoker.join().unwrap(), Revoked::Changed);
        });
        assert_eq!(fs::read_to_string(&entry).unwrap(), "the entry A approved");
        assert!(nothing_beside(&entry));
    }

    #[test]
    fn a_commit_waits_for_a_revoke_and_its_take_back_puts_the_revoked_entry_back() {
        // A revoke holds the lock and is about to put its entry in place. B
        // commits the same entry meanwhile: B waits, then fails at its store
        // line, and its take-back puts back the entry that stood there before
        // it, which is the revoked one.
        let d = scratch();
        append(&d.0, &h(1), &rec(1)).unwrap();
        let entry = stand(&d.0, 1, "the entry A approved");
        let (seen, staged) = seen_and_staged(&d.0, 1, &entry, "the entry A approved, revoked");
        let revoked_ino = ino(&staged);
        let (staged_b, _) = stage(&d.0, 1, "the entry B wrote");
        let (hash, r) = (h(1), rec(1));
        let in_revoke = std::sync::Barrier::new(2);
        std::thread::scope(|s| {
            let b = s.spawn(|| {
                in_revoke.wait();
                commit_with(&d.0, &approval(1, &staged_b, &entry, &r, &hash), LOCK_WAIT, efbig, read_locked, &mut Vec::new())
            });
            let answer = revoke_with(
                &d.0,
                &revocation(1, &hash, &staged, &entry, &seen),
                LOCK_WAIT,
                |from, to| {
                    in_revoke.wait();
                    let end = std::time::Instant::now() + Duration::from_secs(1);
                    while !b.is_finished() && std::time::Instant::now() < end {
                        std::thread::sleep(Duration::from_millis(20));
                    }
                    assert!(!b.is_finished() && staged_b.exists(), "B committed while the revoke held the lock");
                    fs::rename(from, to)
                },
                &mut Vec::new(),
            );
            assert_eq!(answer, Revoked::Revoked);
            assert_eq!(b.join().unwrap(), Answer::NotApproved(Failure::Store, Entry::Restored));
        });
        assert_eq!(fs::read_to_string(&entry).unwrap(), "the entry A approved, revoked");
        assert_eq!(ino(&entry), revoked_ino, "the entry at the end is not the file the revoke put in place");
        assert!(nothing_beside(&entry));
    }

    #[test]
    fn a_revoke_of_what_an_ended_commit_left_stands_and_its_settle_takes_nothing_back() {
        // A commit ended after its rename: the entry A approved is kept
        // aside, the ended commit's entry is at the path. A revoke of that
        // entry puts its own in place, so the settle that follows takes
        // nothing back and the revoked entry stays.
        let d = scratch();
        append(&d.0, &h(1), &rec(1)).unwrap();
        let (earlier, entry) = stage(&d.0, 1, "the entry A approved");
        fs::hard_link(&earlier, prev_of(&entry)).unwrap();
        fs::remove_file(&earlier).unwrap();
        fs::write(&entry, "the entry the ended commit wrote").unwrap();
        let (seen, staged) = seen_and_staged(&d.0, 1, &entry, "the entry the ended commit wrote, revoked");
        let hash = h(1);
        assert_eq!(revoke(&d.0, &revocation(1, &hash, &staged, &entry, &seen), &mut Vec::new()), Revoked::Revoked);
        assert!(nothing_beside(&entry), "the ended commit's second name outlived the revoke");
        let answer = settle(&d.0, &h(1), &entry, "signal-9", &mut Vec::new());
        assert_eq!(answer, Answer::NotApproved(Failure::InDoubt, Entry::Untouched));
        assert_eq!(fs::read_to_string(&entry).unwrap(), "the entry the ended commit wrote, revoked");
    }

    // ---- the command lines -----------------------------------------------------

    fn args(a: &[&str]) -> Vec<String> {
        a.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn the_commit_and_settle_command_lines() {
        let d = scratch();
        let (staged, entry) = stage(&d.0, 1, "entry of 1");
        let (s, e) = (staged.to_str().unwrap(), entry.to_str().unwrap());
        let (one, two) = (h(1), h(2));
        let (h1, h2) = (one.as_str(), two.as_str());
        let mut input = rec(1);
        input.push(b'\n');
        let other = d.0.join(ledger::filename(h1));
        let elsewhere = d.0.join(".staged");
        let refused: [(&[&str], &[u8]); 6] = [
            (&["commit", "sha256:x", s, e], &input),
            (&["commit", h2, s, e], &input),
            (&["commit", h1, s, e], b"check approve-undone hash=x\n"),
            (&["commit", h1, elsewhere.to_str().unwrap(), e], &input),
            (&["commit", h1, s, other.to_str().unwrap()], &input),
            (&["commit", h1, e, e], &input),
        ];
        for (a, input) in refused {
            let (code, out, err) = run(&d.0, &args(a), input);
            assert_eq!((code, out.is_empty()), (2, true), "{a:?}");
            assert!(err.starts_with(b"safedeps-core approvals: not committed: "), "{a:?}");
        }
        assert!(!path(&d.0).exists() && !d.0.join(ADVISORY_LOG).exists() && staged.exists() && !entry.exists());
        assert_eq!(run(&d.0, &args(&["commit", h1, s, e]), &input), (0, b"approved\n".to_vec(), Vec::new()));
        assert_eq!(logged(&d.0), vec![record(1)]);
        for ended in ["exit-", "signal-1234", "kill-9", "exit-x", "exit9", ""] {
            let (code, out, _) = run(&d.0, &args(&["settle", h1, e, ended]), b"");
            assert_eq!((code, out.is_empty()), (2, true), "{ended:?}");
        }
        assert_eq!(run(&d.0, &args(&["settle", h2, e, "signal-9"]), b"").0, 2);
        // The commit answered, so no second name is left: the settle takes
        // nothing back, and the store vouches.
        let (code, out, _) = run(&d.0, &args(&["settle", h1, e, "signal-9"]), b"");
        assert_eq!((code, String::from_utf8(out).unwrap()), (1, "not-approved approvals_store_in_doubt untouched\n".to_string()));
        assert!(entry.exists());
        fs::write(none_of(&entry), "").unwrap();
        let (code, out, _) = run(&d.0, &args(&["settle", h1, e, "signal-9"]), b"");
        assert_eq!((code, String::from_utf8(out).unwrap()), (1, "not-approved approvals_store_in_doubt removed\n".to_string()));
        assert!(!entry.exists());
        for bad in [&["commit", h1, s][..], &["settle", h1, e][..]] {
            assert_eq!(run(&d.0, &args(bad), b""), (2, Vec::new(), USAGE.as_bytes().to_vec()), "{bad:?}");
        }
    }

    #[test]
    fn the_revoke_command_line() {
        let d = scratch();
        let entry = stand(&d.0, 1, "the entry A approved");
        let (seen, staged) = seen_and_staged(&d.0, 1, &entry, "the entry A approved, revoked");
        let (s, e, v) = (staged.to_str().unwrap(), entry.to_str().unwrap(), seen.to_str().unwrap());
        let (one, two) = (h(1), h(2));
        let (h1, h2) = (one.as_str(), two.as_str());
        let other = d.0.join(ledger::filename(h1));
        let elsewhere = d.0.join(".elsewhere");
        let refused: [&[&str]; 8] = [
            &["revoke", "sha256:x", s, e, v],
            &["revoke", h2, s, e, v],
            &["revoke", h1, elsewhere.to_str().unwrap(), e, v],
            &["revoke", h1, s, other.to_str().unwrap(), v],
            &["revoke", h1, s, e, elsewhere.to_str().unwrap()],
            &["revoke", h1, e, e, v],
            &["revoke", h1, s, e, s],
            &["revoke", h1, s, e, e],
        ];
        for a in refused {
            let (code, out, err) = run(&d.0, &args(a), b"");
            assert_eq!((code, out.is_empty()), (2, true), "{a:?}");
            assert!(err.starts_with(b"safedeps-core approvals: not revoked: "), "{a:?}");
        }
        assert!(!path(&d.0).exists() && staged.exists());
        assert_eq!(fs::read_to_string(&entry).unwrap(), "the entry A approved");
        let replaced = stand(&d.0, 1, "the entry B approved");
        assert_eq!(run(&d.0, &args(&["revoke", h1, s, e, v]), b""), (1, b"changed\n".to_vec(), Vec::new()));
        fs::remove_file(&seen).unwrap();
        fs::hard_link(&replaced, &seen).unwrap();
        assert_eq!(run(&d.0, &args(&["revoke", h1, s, e, v]), b""), (0, b"revoked\n".to_vec(), Vec::new()));
        assert_eq!(fs::read_to_string(&entry).unwrap(), "the entry A approved, revoked");
        assert_eq!(run(&d.0, &args(&["revoke", h1, s, e]), b""), (2, Vec::new(), USAGE.as_bytes().to_vec()));
    }

    #[test]
    fn the_index_command_line_and_no_line_written_alone() {
        let d = scratch();
        append(&d.0, &h(1), &rec(1)).unwrap();
        let mut input = rec(2);
        input.push(b'\n');
        let two = h(2);
        // No command writes a store line apart from a commit.
        let bads: [&[&str]; 5] = [&["append", two.as_str()], &["append"], &["index", "x"], &["nothing"], &[]];
        for bad in bads {
            assert_eq!(run(&d.0, &args(bad), &input), (2, Vec::new(), USAGE.as_bytes().to_vec()), "{bad:?}");
        }
        assert_eq!(index(&d.0).unwrap().hashes, vec![h(1)]);
        let (code, out, err) = run(&d.0, &args(&["index"]), b"");
        assert_eq!((code, err), (0, Vec::new()));
        assert_eq!(String::from_utf8(out).unwrap(), format!("{{\"present\":true,\"hashes\":{{\"{}\":true}},\"broken\":0}}\n", h(1)));
        let (code, out, _) = run(&d.0.join("none"), &args(&["index"]), b"");
        assert_eq!((code, String::from_utf8(out).unwrap()), (0, "{\"present\":false,\"hashes\":{},\"broken\":0}\n".to_string()));
        fs::create_dir_all(path(&d.0.join("dir"))).unwrap();
        let (code, out, err) = run(&d.0.join("dir"), &args(&["index"]), b"");
        assert_eq!((code, out.is_empty()), (1, true));
        assert!(String::from_utf8(err).unwrap().contains("could not be read"));
        assert!(!USAGE.contains("append"));
    }
}
