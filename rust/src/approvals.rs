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
//! Isolation: the store lock, flock(2) on the store file itself, and LOCK_EX
//! for every hold. A writer holds it for its whole write and a reader for its
//! whole read, on the read-only file it reads, so a reader never sees a line
//! half written, two writers never write at once, and no two holds overlap.
//! Under the lock a writer first seals a torn last line (below), then appends
//! its own line in the same write and syncs it before it says the line is
//! written. The lock belongs to the open file and goes when the file is
//! closed, so a process that dies holding it leaves nothing to clean up: the
//! next writer or reader takes it at once. Reads pay for one mode: they wait
//! for each other, and a read that stalls under the lock has the reads behind
//! it refused after LOCK_WAIT, as it has a commit.
//!
//! The turn. A waiter waits while the lock changes hands, and LOCK_WAIT
//! behind one hold. Every hold of the lock, a writer's or a reader's, writes
//! its turn once it took the lock, in `approvals.turn` beside the store: when
//! the hold began and a check of that time, one line of fixed width written
//! over the last. The time is the host's monotonic clock (`os::host_clock`),
//! one clock for every process of the host, read just before the try that
//! took the lock, so a turn never says a hold began later than it did. A
//! waiter counts LOCK_WAIT from the later of two times: when it began to
//! wait, and when the hold it waits behind began, as the turn says. After
//! each try the lock refused it reads the turn and counts again. The first
//! turn it reads whole can be older than its wait, so it never counts: a
//! turn left from before the host started again can name a time the clock
//! reaches only later. Only a turn other than the first counts.
//! A turn that cannot be read, whose check is not its time's, as a line read
//! while a hold writes over it can be, or that names a time later than now,
//! counts for nothing, and the wait keeps the start it had. No two holds
//! overlap, so commits that overlap wait their turn, however many there are,
//! and none is refused for the crowd, while a waiter that waited LOCK_WAIT
//! behind one hold is refused: nothing is written or read without the lock.
//! A hold writes its turn after it took the lock, so for a moment the turn is
//! still the last hold's, longer where a hold stalls between its lock and its
//! turn, and a hold that cannot write its turn leaves the last one standing.
//! The waiter then counts from its own start or from the last hold's: it is
//! refused sooner, never later. Processes in two Linux time namespaces read
//! two such clocks (time_namespaces(7)): a turn from the other one can move a
//! wait by the namespaces' offset. The turn is no record: only a waiter reads
//! it, and it vouches for nothing.
//!
//! The same lock orders every write of a ledger entry an approval stands on:
//! a commit and a revoke of an entry each run under it from their first
//! change to their last. So no two of them overlap, whatever entry each
//! writes. In each the CLI makes the entry's bytes and validates them in a
//! staged file beside the entry's path. This module renames that file into
//! place, and a commit removes an entry the store does not vouch for (step 0,
//! below). It never builds or reads an entry's bytes, so the ledger's format
//! keeps one writer, the CLI. That is why the CLI stages and the core renames:
//! the bytes are the CLI's, and the order of the writes is the lock's.
//!
//! The commit. An approval is three records: the ledger entry the hook reads,
//! the `check approve(...)` line in advisory.log a person reads, and the line
//! here that re-check and the cache lookup read. `commit` writes all three for
//! `safedeps check`. An approval's store line, synced, and its approve line are
//! written before its entry is renamed into place, all under the store lock,
//! and the rename is the commit point. An entry at the path that the store
//! does not vouch for is removed before the store line. So when the store
//! vouches for a hash, an unrevoked entry at its path is a committed one, or
//! the one a migration confirmed under the lock before it wrote the hash's
//! line (below), and a failed approval leaves at most a store line with no
//! entry, which re-check counts as unmatched. The commit never removes the
//! staged file. The CLI does, whatever the commit answered.
//!
//! Under the lock, in this order:
//!
//!   0. Two reads, each made once: what stands at the entry's path, and
//!      whether the store vouches for the hash. An entry the store does not
//!      vouch for is removed, the removal is written to advisory.log
//!      (`check unvouched-entry-removal`), and the entry's directory is
//!      synced. Whether an entry was removed is the unlink's own answer,
//!      never a later read of the path.
//!   1. The store line, synced.
//!   2. The approve line, stamped with the store line's time.
//!   3. The rename, the commit point.
//!
//! The first step that fails stops the commit, and nothing after it is
//! written. Step 0 stops where the path or the store cannot be read, where
//! the entry cannot be removed, and where the removal's line or the sync
//! fails. A rename that fails is followed by one line, `check approve-undone`,
//! with the rename's outcome.
//!
//! Why step 0. A store line vouches for whatever stands at its hash's path.
//! An entry the store does not vouch for was there before the store, was
//! written by hand, or was left by a check of an earlier version that died
//! after its rename. Left there, it would be vouched for from step 1 on, and a
//! commit that failed after step 1 would leave an approval no check committed.
//!
//! The windows. From the removal to the rename no entry stands at the path,
//! across two syncs and two lines, and an install judged then finds no
//! approval. The window opens only where an unvouched entry stood. A commit
//! that fails after step 0 leaves no entry until the next check. The sync of
//! the directory is to put the removal on the disk before the store line, and
//! whether it does is not measured, on APFS or on WSL1. Where it does not, a
//! power loss after the store line reached the disk and before the removal
//! did brings the entry back, vouched for.
//!
//! A store write answers one of three things: Ok, and the two of `Appended`.
//! Written: the line is in the store and synced. Not written: the line is not
//! there, or only a torn piece of it is, which the next writer seals as one
//! broken line. Written, not synced: every byte of the line landed and a reader
//! sees it, but the sync failed, so nothing says it is on the disk. A commit
//! knows which of the three its own write answered. Not written stops it,
//! whatever the store vouches for. Written, not synced stops it before the
//! approve line and the rename, named `unsynced`, and the answer is in doubt:
//! the store may vouch with this line, and no entry of this check stands.
//!
//! The readers. The cache lookup reads the store first and the entry after. A
//! check's store line lands only after its step 0, so an entry read after the
//! store vouched for its hash is one the store vouched for then, or the
//! commit's own. In the other order the lookup could take for a hit an entry
//! that step 0 then removes, matched with the line of a commit that fails.
//! `re-check` reads the entry first and the store after. A committed entry's
//! store line comes before the entry, so `re-check` never calls a committed
//! entry unvouched. An entry it calls vouched that a commit removed meanwhile
//! no longer stands. The hook and the listings read the entry alone. At the
//! path stands a committed entry, a revoked one, an entry from before the
//! store or by hand that no commit of its hash has met since, or nothing.
//!
//! The revoke. A revoke rewrites an entry with the fields that revoke it. The
//! CLI reads the entry through a second name it made for it (`seen`), and
//! stages the revoked entry beside the path. `revoke` puts it in place only
//! where the entry at the path is still the file the CLI read. Where it is
//! not, a commit replaced or removed the entry between the read and the lock,
//! and the answer is `changed`: the CLI reads the entry again.
//!
//! The migration. An approval a check made before this store has no line
//! here, and its record is its approve line in advisory.log. `migrate`
//! (approvals/migrate.rs) moves those lines in: one line for each hash its
//! ledger entry confirms, `via: migrate`. A commit and the migration are the
//! two that write a store line, and they write it the same way. The migration
//! holds the store lock, LOCK_EX, from its read of the store to the end of its
//! write; it reads each entry under the lock, and it writes every line in one
//! `write_locked`, which seals a torn tail, appends the lines and syncs them.
//! It writes no ledger entry and no advisory.log line, so the lock orders it
//! against every commit and revoke, and nothing a commit or a revoke writes
//! lands between an entry's confirmation and its line.
//!
//! What this module assumes. One ledger directory belongs to one home's store.
//! Where two homes share a `SAFEDEPS_LEDGER_DIR`, a commit of a hash in one
//! removes the entry a commit of that hash in the other made, since its own
//! store does not vouch for it, and the two locks do not order each other.
//! Nothing refuses it. Two writers run outside the lock and replace whole
//! files. One is `lib/ledger/ledger.sh approve`, which only fixtures run. An
//! entry it puts in place between step 0 and a rename that fails stands,
//! vouched for by the failed commit's line. The other is the revoke of a
//! 2.21.0 runtime copy. It can put revoked bytes over a newer approval, and a
//! commit can put its entry over them.
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
    ledger, os, sha256, state,
    outcome::{Action, Form, Outcome},
};
use std::{
    collections::HashSet,
    fs,
    io::{self, Read, Write},
    os::unix::{
        ffi::OsStrExt,
        fs::{DirBuilderExt, FileExt, MetadataExt, OpenOptionsExt},
    },
    path::{Path, PathBuf},
    time::Duration,
};

mod migrate;

pub const FILE_NAME: &str = "approvals.jsonl";
/// What every record in the store starts with. advisory.log writes an
/// approval with the same words, and a record that does not start with them
/// is no approval. The parenthesis is part of it: `check approve-unsynced` and
/// `check approve-undone`, the lines a commit writes when it stopped, are no
/// approval.
pub const RECORD_PREFIX: &[u8] = b"check approve(";
const HASH_PREFIX: &str = "sha256:";
const FIELDS: [&str; 4] = ["at", "hash", "via", "record"];
/// The torn-line seal's byte. A writer ends a torn last line with it and a
/// newline, and a line that holds it vouches for nothing.
const SEAL: u8 = 0;
/// How long a writer or a reader waits for the store lock while one hold
/// keeps it. A holder writes one line or reads the file, so a hold of ten
/// seconds is taken for a holder that stopped. Each new hold starts the wait
/// again (the turn, `lock_store`).
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

/// An observed failure keeps its operation and path until a line is written.
/// Authored judgments are not operating-system errors.
#[derive(Debug)]
pub enum Fault {
    Operation { outcome: Outcome, path: PathBuf, action: for<'a> fn(&'a Path) -> Action<'a> },
    Gzip(Outcome),
    Judgment(&'static [u8]),
}

impl Fault {
    fn operation(outcome: Outcome, path: &Path, action: for<'a> fn(&'a Path) -> Action<'a>) -> Self {
        Self::Operation { outcome, path: path.to_owned(), action }
    }

    /// Machine report fields use the same describe bytes as the human line.
    fn text(&self) -> Vec<u8> {
        match self {
            Self::Operation { outcome, path, action } => outcome.describe(action(path), Form::Action),
            Self::Gzip(outcome) => outcome.describe(Action::Gzip, Form::Action),
            Self::Judgment(text) => text.to_vec(),
        }
    }

    fn report(&self, err: &mut Vec<u8>, before: &[u8], after: &[u8]) {
        match self {
            Self::Operation { outcome, path, action } =>
                say(err, &cat(&[before, &Outcome::describe(outcome, action(path), Form::Action), after])),
            Self::Gzip(outcome) =>
                say(err, &cat(&[before, &Outcome::describe(outcome, Action::Gzip, Form::Action), after])),
            Self::Judgment(text) => say(err, &cat(&[before, text, after])),
        }
    }
}

fn observed<T>(result: io::Result<T>, path: &Path, action: for<'a> fn(&'a Path) -> Action<'a>) -> Result<T, Fault> {
    result.map_err(|e| Fault::operation(Outcome::Io(Err(e)), path, action))
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

fn regular(file: fs::File, store: &Path) -> Result<fs::File, Fault> {
    if observed(file.metadata(), store, |p| Action::Read(p))?.is_file() {
        Ok(file)
    } else {
        Err(Fault::Judgment(b"the approvals store is not a regular file"))
    }
}

/// The store, opened to be appended to. Each failure keeps the operation
/// and path that returned it, without rendering the outcome.
fn open_for_append(dir: &Path) -> Result<fs::File, Fault> {
    observed(fs::DirBuilder::new().recursive(true).mode(0o700).create(dir), dir, |p| Action::Create(p))?;
    let store = path(dir);
    let file = observed(fs::OpenOptions::new().read(true).append(true).create(true).mode(0o600).open(&store), &store, |p| Action::Open(p))?;
    regular(file, &store)
}

/// Why a store write did not answer written. `NotWritten`: the line is not in
/// the store, or a torn piece of it is, which the next writer seals as one
/// broken line. `Unsynced`: the whole line is in the store and a reader sees
/// it, but the sync failed.
#[derive(Debug)]
pub enum Appended {
    NotWritten(Fault),
    Unsynced(Outcome),
}

impl From<Fault> for Appended {
    fn from(e: Fault) -> Self {
        Self::NotWritten(e)
    }
}

/// Under LOCK_EX: seals a torn last line, then appends `lines` in the same
/// write and syncs them.
fn write_locked(file: &fs::File, store: &Path, lines: &[u8]) -> Result<(), Appended> {
    write_then_sync(file, store, lines, fs::File::sync_data)
}

/// The write, then `sync`. Only a write that put every byte in the store
/// reaches the sync, so a failed sync is a line a reader sees.
fn write_then_sync(file: &fs::File, store: &Path, lines: &[u8], sync: impl FnOnce(&fs::File) -> io::Result<()>) -> Result<(), Appended> {
    let len = observed(file.metadata(), store, |p| Action::Read(p))?.len();
    let mut out = Vec::with_capacity(lines.len() + 2);
    if len > 0 {
        let mut last = [0u8; 1];
        observed(file.read_exact_at(&mut last, len - 1), store, |p| Action::Read(p))?;
        if last[0] != b'\n' {
            out.extend_from_slice(&[SEAL, b'\n']);
        }
    }
    out.extend_from_slice(lines);
    let mut f: &fs::File = file;
    observed(f.write_all(&out), store, |p| Action::Write(p))?;
    sync(file).map_err(|e| Appended::Unsynced(Outcome::Io(Err(e))))
}

/// What the store vouches for: each hash once, in the order of its first
/// line, and how many lines vouch for nothing.
#[derive(Debug, PartialEq, Eq)]
pub struct Index {
    pub present: bool,
    pub hashes: Vec<String>,
    pub broken: usize,
}

pub fn index(dir: &Path) -> Result<Index, Fault> {
    index_within(dir, LOCK_WAIT)
}

fn index_within(dir: &Path, wait: Duration) -> Result<Index, Fault> {
    let Some(file) = locked_for_reading(dir, wait)? else {
        return Ok(Index { present: false, hashes: Vec::new(), broken: 0 });
    };
    let mut bytes = Vec::new();
    let mut f: &fs::File = &file;
    observed(f.read_to_end(&mut bytes), &path(dir), |p| Action::Read(p))?;
    Ok(read(&bytes))
}

/// The store, opened read-only and locked for a read, or None where there is
/// no store: a read never makes one. The lock goes with the file.
fn locked_for_reading(dir: &Path, wait: Duration) -> Result<Option<fs::File>, Fault> {
    let store = path(dir);
    let file = match fs::File::open(&store) {
        Ok(f) => regular(f, &store)?,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(Fault::operation(Outcome::Io(Err(e)), &store, |p| Action::Open(p))),
    };
    lock_store(dir, &file, wait)?;
    Ok(Some(file))
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
fn read_locked(file: &fs::File, store: &Path) -> Result<Index, Fault> {
    let len = usize::try_from(observed(file.metadata(), store, |p| Action::Read(p))?.len())
        .map_err(|_| Fault::Judgment(b"the approvals store is too large to read"))?;
    let mut bytes = vec![0u8; len];
    observed(file.read_exact_at(&mut bytes, 0), store, |p| Action::Read(p))?;
    Ok(read(&bytes))
}

const ADVISORY_LOG: &str = "advisory.log";
/// What step 0 of a commit writes to advisory.log when it removed an entry
/// the store did not vouch for. It does not hold `check approve`, so no reader
/// of approvals in advisory.log, old or new, takes it for one.
const REMOVAL: &str = "check unvouched-entry-removal";

/// What a commit that did not approve left at the ledger entry's path.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Entry {
    /// The commit removed nothing and put nothing in place.
    Untouched,
    /// Step 0 removed an entry the store did not vouch for, and nothing of
    /// this check is in place.
    Removed,
}

impl Entry {
    fn as_str(self) -> &'static str {
        match self {
            Self::Untouched => "untouched",
            Self::Removed => "removed",
        }
    }
}

/// Why a commit did not approve, in the word the check's report uses.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Failure {
    /// Step 0 could not read the entry's path, remove an entry, write the
    /// removal's line or sync the directory. Or the approve line could not be
    /// written, or the rename failed. No entry of this check stands, and the
    /// store may hold its line.
    LedgerWrite,
    /// The store could not be opened, locked or read, or it did not take the
    /// line. The store vouches with no line of this check.
    Store,
    /// The store may hold this check's line, and nothing confirms that this
    /// check's entry stands: a line written and not synced, which stops the
    /// commit before its entry, or, as the CLI answers it, a commit that ended
    /// before it answered, where the entry at the path is not this check's
    /// file.
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

/// The entry's path ends in the file name the ledger gives `hash`, so step 0
/// never removes another hash's entry, and a rename never puts one hash's
/// entry at another's path.
fn entry_for(hash: &str, entry: &Path) -> Result<(), &'static str> {
    if !is_hash(hash) {
        return Err("the hash is not sha256: and 64 lowercase hex digits");
    }
    if entry.file_name().map(OsStrExt::as_bytes) != Some(ledger::filename(hash).as_bytes()) {
        return Err("the entry's path does not end in its hash's file name");
    }
    Ok(())
}

/// A file the CLI made beside the entry: in the entry's own directory, so a
/// rename never leaves it, and not the entry itself.
fn beside(file: &Path, entry: &Path) -> bool {
    file.file_name().is_some() && file.parent() == entry.parent() && file != entry
}

/// An approval a commit acts on.
fn checked(a: &Approval) -> Result<(), &'static str> {
    entry_for(a.hash, a.entry)?;
    if !a.record.starts_with(RECORD_PREFIX) {
        return Err("the record is not an approval (it does not start with `check approve(`)");
    }
    if !beside(a.staged, a.entry) {
        return Err("the staged entry is not a file beside the entry's path");
    }
    Ok(())
}

fn cat(parts: &[&[u8]]) -> Vec<u8> {
    parts.concat()
}

fn say(err: &mut Vec<u8>, text: &[u8]) {
    err.extend_from_slice(text);
    err.push(b'\n');
}

/// One advisory.log line as the CLI writes one (`sf_advisory_log`):
/// `[<UTC time>] <text>`.
fn log_record(at: &str, text: &[u8]) -> Vec<u8> {
    let mut l = Vec::with_capacity(at.len() + text.len() + 4);
    l.push(b'[');
    l.extend_from_slice(at.as_bytes());
    l.extend_from_slice(b"] ");
    l.extend_from_slice(text);
    l.push(b'\n');
    l
}

fn log_line(log: &Path, at: &str, text: &[u8]) -> Result<(), Fault> {
    let l = log_record(at, text);
    let mut f = observed(fs::OpenOptions::new().create(true).append(true).mode(0o600).open(log), log, |p| Action::Open(p))?;
    observed(f.write_all(&l), log, |p| Action::Write(p))
}

/// The turn's file, beside the store.
const TURN: &str = "approvals.turn";

/// One hold of the store lock, as its holder wrote it once it took the lock:
/// when the hold began, on the host's monotonic clock, read just before the
/// try that took the lock, so never later than the hold began.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct Turn {
    began: os::HostTime,
}

impl Turn {
    /// The length of every turn's line: the time in 20 digits, a space, its
    /// check in 16 hex digits and a newline. A turn is written over the last
    /// whole, and nothing is truncated.
    const LEN: usize = 38;

    /// The first 16 hex digits of the SHA-256 of the time's 20 digits.
    fn check(digits: &str) -> String {
        sha256::hex(digits.as_bytes())[..16].to_string()
    }

    fn line(&self) -> String {
        let digits = format!("{:020}", self.began.0);
        format!("{digits} {}\n", Self::check(&digits))
    }

    /// A turn's line, or None for bytes that are not one: a line of another
    /// form, or one whose check is not its time's, as a line read while a
    /// hold writes over it can be.
    fn parse(line: &[u8; Self::LEN]) -> Option<Self> {
        let text = std::str::from_utf8(line).ok()?.strip_suffix('\n')?;
        let (digits, check) = text.split_once(' ')?;
        if digits.len() != 20 || !digits.bytes().all(|b| b.is_ascii_digit()) || check != Self::check(digits) {
            return None;
        }
        Some(Self { began: os::HostTime(digits.parse().ok()?) })
    }
}

/// Writes the turn of the hold that `began`, over the last, under the lock
/// it just took. The open does not wait for a FIFO's reader, and only a
/// regular file is written to.
fn write_turn(dir: &Path, began: os::HostTime) -> io::Result<()> {
    let file = fs::OpenOptions::new().write(true).create(true).mode(0o600).custom_flags(os::O_NONBLOCK).open(dir.join(TURN))?;
    if !file.metadata()?.is_file() {
        return Err(io::ErrorKind::InvalidInput.into());
    }
    file.write_all_at(Turn { began }.line().as_bytes(), 0)
}

/// The turn beside the store, or None where no turn can be read.
fn read_turn(dir: &Path) -> Option<Turn> {
    let file = fs::OpenOptions::new().read(true).custom_flags(os::O_NONBLOCK).open(dir.join(TURN)).ok()?;
    let mut line = [0u8; Turn::LEN];
    file.read_exact_at(&mut line, 0).ok()?;
    Turn::parse(&line)
}

/// The store lock on `file`, the store in `dir`, then this hold's turn. The
/// wait is counted from the later of the waiter's start and the start of the
/// hold the turn names (the module's "The turn"). A turn names that hold only
/// where it is read whole, is not the first turn this waiter read whole, and
/// began no later than now.
fn lock_store(dir: &Path, file: &fs::File, wait: Duration) -> Result<(), Fault> {
    let mut first = None;
    let began = os::flock_within(file, wait, |now| {
        let turn = read_turn(dir)?;
        let was = *first.get_or_insert(turn);
        (turn != was && turn.began <= now).then_some(turn.began)
    })
    .map_err(|o| Fault::operation(o, &path(dir), |p| Action::Lock(p)))?;
    // A turn not written leaves the last one standing: a waiter's patience,
    // never the lock.
    let _ = write_turn(dir, began);
    Ok(())
}

/// The store, opened and locked for a commit or a revoke. The lock goes with
/// the file.
fn locked(dir: &Path, wait: Duration) -> Result<fs::File, Fault> {
    let file = open_for_append(dir)?;
    lock_store(dir, &file, wait)?;
    Ok(file)
}

/// A commit's steps, each the one operation it names. `Real` runs them. A
/// test runs them through its own, to fail one and to see their order.
trait Steps {
    /// What stands at a path, the link itself where it is one.
    fn lstat(&self, p: &Path) -> io::Result<fs::Metadata> {
        fs::symlink_metadata(p)
    }
    /// The store, read under the lock `file` holds.
    fn read(&self, file: &fs::File, store: &Path) -> Result<Index, Fault> {
        read_locked(file, store)
    }
    fn unlink(&self, p: &Path) -> io::Result<()> {
        fs::remove_file(p)
    }
    /// One advisory.log line.
    fn log(&self, log: &Path, at: &str, text: &[u8]) -> Result<(), Fault> {
        log_line(log, at, text)
    }
    /// A directory's entries, synced.
    fn sync_dir(&self, dir: &Path) -> Result<(), Fault> {
        let file = observed(fs::File::open(dir), dir, |p| Action::Open(p))?;
        observed(file.sync_all(), dir, |p| Action::Sync(p))
    }
    /// The store line, under the lock `file` holds.
    fn append(&self, file: &fs::File, store: &Path, line: &[u8]) -> Result<(), Appended> {
        write_locked(file, store, line)
    }
    fn rename(&self, from: &Path, to: &Path) -> io::Result<()> {
        fs::rename(from, to)
    }
}

struct Real;

impl Steps for Real {}

/// The directory that holds `entry`, synced after a removal from it.
fn dir_of(entry: &Path) -> &Path {
    match entry.parent() {
        Some(p) if !p.as_os_str().is_empty() => p,
        _ => Path::new("."),
    }
}

/// Build the entire take-back line before its writer receives it.
fn say_undone(hash: &str, entry: &Path, outcome: &Outcome, say: impl FnOnce(&[u8])) {
    // outcome= is last: preserve describe bytes without trimming or rewriting them.
    say(&cat(&[format!("check approve-undone hash={hash} outcome=").as_bytes(),
        &outcome.describe(Action::Rename(entry), Form::Action)]));
}

/// Commits one approval for `safedeps check`: under the store lock, step 0,
/// the store line, the approve line and the rename, in that order, and the
/// first that fails stops it. What it cannot rule out it names on `err`:
/// `unsynced`.
pub fn commit(dir: &Path, a: &Approval, err: &mut Vec<u8>) -> Answer {
    commit_with(dir, a, LOCK_WAIT, &Real, err)
}

fn commit_with(dir: &Path, a: &Approval, wait: Duration, steps: &dyn Steps, err: &mut Vec<u8>) -> Answer {
    let file = match locked(dir, wait) {
        Ok(f) => f,
        Err(e) => {
            e.report(err, format!("safedeps-core approvals: not committed: {} could not be opened and locked: ", path(dir).display()).as_bytes(), b"");
            return Answer::NotApproved(Failure::Store, Entry::Untouched);
        }
    };
    // From here to the answer the store lock is held. It goes with `file`.
    let log = dir.join(ADVISORY_LOG);
    let say = |text: &[u8]| {
        let at = os::utc_stamp(os::wall(os::WallRole::AdvisoryHeader).seconds());
        steps.log(&log, &at, text)
    };
    // Step 0: what stands at the path, and whether the store vouches for the
    // hash, each read once.
    let stands = match steps.lstat(a.entry) {
        Ok(_) => true,
        Err(e) if e.kind() == io::ErrorKind::NotFound => false,
        Err(e) => {
            self::say(err, &cat(&[b"safedeps-core approvals: not committed: ", &Outcome::Io(Err(e)).describe(Action::Read(a.entry), Form::Action)]));
            return Answer::NotApproved(Failure::LedgerWrite, Entry::Untouched);
        }
    };
    let vouched = match steps.read(&file, &path(dir)) {
        Ok(ix) => ix.hashes.iter().any(|h| h == a.hash),
        Err(e) => {
            e.report(err, format!("safedeps-core approvals: not committed: {} could not be read: ", path(dir).display()).as_bytes(), b"");
            return Answer::NotApproved(Failure::Store, Entry::Untouched);
        }
    };
    let mut touched = Entry::Untouched;
    if stands && !vouched {
        // Whether an entry was removed is the unlink's own answer.
        let removed = steps.unlink(a.entry);
        match removed {
            Err(e) if e.kind() == io::ErrorKind::NotFound => {}
            Err(e) => {
                self::say(err, &cat(&[format!("safedeps-core approvals: not committed: the ledger entry {} is not one the approvals store vouches for, and it could not be removed: ", a.entry.display()).as_bytes(), &Outcome::Io(Err(e)).describe(Action::Removal, Form::Action)]));
                return Answer::NotApproved(Failure::LedgerWrite, Entry::Untouched);
            }
            Ok(()) => {
                touched = Entry::Removed;
                // outcome= is last: its value is the exact describe bytes and may contain spaces and paths.
                let removed: Outcome = Outcome::Io(Ok(()));
                let said = say(&cat(&[format!("{} hash={} entry={} outcome=", REMOVAL, a.hash, a.entry.display()).as_bytes(), &removed.describe(Action::Removal, Form::Action)]));
                if let Err(e) = said {
                    e.report(err, format!("safedeps-core approvals: not committed: the ledger entry {} was removed, as the approvals store does not vouch for it, and the line that says so could not be written to {}: ", a.entry.display(), log.display()).as_bytes(), b"");
                    return Answer::NotApproved(Failure::LedgerWrite, touched);
                }
                if let Err(e) = steps.sync_dir(dir_of(a.entry)) {
                    e.report(err, format!("safedeps-core approvals: not committed: the ledger entry {} was removed, as the approvals store does not vouch for it, and its directory could not be synced: ", a.entry.display()).as_bytes(), b"");
                    return Answer::NotApproved(Failure::LedgerWrite, touched);
                }
            }
        }
    }
    // Step 1: the store line, synced.
    let at = os::utc_stamp(os::wall(os::WallRole::ApprovalRecord).seconds());
    match steps.append(&file, &path(dir), &line(&at, a.hash, Via::Check, a.record)) {
        Ok(()) => {}
        Err(Appended::NotWritten(e)) => {
            e.report(err, format!("safedeps-core approvals: not written to {}: ", path(dir).display()).as_bytes(), b"");
            return Answer::NotApproved(Failure::Store, touched);
        }
        Err(Appended::Unsynced(e)) => {
            let how: Outcome = e;
            self::say(err, &cat(&[format!("safedeps: unsynced: the approvals store line of {} was written and not synced (", a.hash).as_bytes(), &how.describe(Action::Sync(&path(dir)), Form::Action), b"). The commit stopped before its approve line and its entry, so no entry of this check stands, and the store may vouch for it."]));
            // outcome= is last; preserve the describe bytes without trimming or rewriting them.
            let _ = say(&cat(&[format!("check approve-unsynced hash={} outcome=", a.hash).as_bytes(), &how.describe(Action::Sync(&path(dir)), Form::Action)]));
            return Answer::NotApproved(Failure::InDoubt, touched);
        }
    }
    // Step 2: the approve line, stamped with the store line's time.
    if let Err(e) = steps.log(&log, &at, a.record) {
        e.report(err, format!("safedeps-core approvals: not committed: the approve line could not be written to {}: ", log.display()).as_bytes(), b"");
        return Answer::NotApproved(Failure::LedgerWrite, touched);
    }
    // Step 3: the rename, the commit point.
    if let Err(e) = steps.rename(a.staged, a.entry) {
        let how = Outcome::Io(Err(e));
        self::say(err, &cat(&[format!("safedeps-core approvals: not committed: the ledger entry {} could not be put in place: ", a.entry.display()).as_bytes(), &how.describe(Action::Rename(a.entry), Form::Action)]));
        say_undone(a.hash, a.entry, &how, |text| { let _ = say(text); });
        return Answer::NotApproved(Failure::LedgerWrite, touched);
    }
    Answer::Approved
}

/// One revoke to put in place: the entry's `hash`, the `staged` revoked entry
/// the CLI made, the entry's path `entry`, and `seen`, the second name the CLI
/// made for the entry it read. All three files sit in the entry's directory.
pub struct Revoke<'a> {
    pub hash: &'a str,
    pub staged: &'a Path,
    pub entry: &'a Path,
    pub seen: &'a Path,
}

#[derive(Debug, Eq, PartialEq)]
pub enum Revoked {
    /// The revoked entry is in place.
    Revoked,
    /// The entry at the path is not the file the CLI read, or no entry is
    /// there: nothing was put in place.
    Changed,
    /// The store could not be locked, or the rename failed: nothing was put
    /// in place.
    NotRevoked,
}

impl Revoked {
    fn as_str(&self) -> &'static str {
        match self {
            Self::Revoked => "revoked",
            Self::Changed => "changed",
            Self::NotRevoked => "not-revoked",
        }
    }
}

fn checked_revoke(r: &Revoke) -> Result<(), &'static str> {
    entry_for(r.hash, r.entry)?;
    if !beside(r.staged, r.entry) || !beside(r.seen, r.entry) || r.staged == r.seen {
        return Err("the staged entry and the entry read are not two files beside the entry's path");
    }
    Ok(())
}

/// One file under two names: the same device and inode.
fn same_file(a: &Path, b: &Path) -> bool {
    match (fs::metadata(a), fs::metadata(b)) {
        (Ok(x), Ok(y)) => x.dev() == y.dev() && x.ino() == y.ino(),
        _ => false,
    }
}

/// Puts a revoked entry in place for the CLI: under the store lock, and only
/// where the entry at the path is still the file the CLI read. It removes
/// neither the staged file nor the entry read: both are the CLI's.
pub fn revoke(dir: &Path, r: &Revoke, err: &mut Vec<u8>) -> Revoked {
    revoke_with(dir, r, LOCK_WAIT, |from, to| fs::rename(from, to), err)
}

fn revoke_with(dir: &Path, r: &Revoke, wait: Duration, rename: impl FnOnce(&Path, &Path) -> io::Result<()>, err: &mut Vec<u8>) -> Revoked {
    let _file = match locked(dir, wait) {
        Ok(f) => f,
        Err(e) => {
            e.report(err, format!("safedeps-core approvals: not revoked: {} could not be opened and locked: ", path(dir).display()).as_bytes(), b"");
            return Revoked::NotRevoked;
        }
    };
    // From here to the answer the store lock is held. It goes with `_file`.
    if !same_file(r.entry, r.seen) {
        return Revoked::Changed;
    }
    if let Err(e) = rename(r.staged, r.entry) {
        say(err, &cat(&[format!("safedeps-core approvals: not revoked: the revoked entry {} could not be put in place: ", r.entry.display()).as_bytes(), &Outcome::Io(Err(e)).describe(Action::Rename(r.entry), Form::Action)]));
        return Revoked::NotRevoked;
    }
    Revoked::Revoked
}

/// A commit's answer as the command gives it: `approved` and exit 0, or
/// `not-approved <failure> <entry>` and exit 1.
fn answer_line(answer: &Answer) -> (i32, Vec<u8>) {
    match answer {
        Answer::Approved => (0, b"approved\n".to_vec()),
        Answer::NotApproved(f, e) => (1, format!("not-approved {} {}\n", f.as_str(), e.as_str()).into_bytes()),
    }
}

const USAGE: &str = "usage: safedeps-core approvals commit <hash> <staged> <entry> (the record on stdin) | revoke <hash> <staged> <entry> <seen> | index | migrate [--json] [--] [<archive>...]\n";

/// `safedeps-core approvals commit <hash> <staged> <entry>`, the record on
/// stdin (one trailing newline is not part of it): the approval committed
/// (`commit`), and its answer on stdout, `approved` and exit 0 or
/// `not-approved <failure> <entry>` and exit 1. Exit 2 for an argument that is
/// not one, and nothing is written. A commit and a migration are the two
/// commands that write a store line, each under the store lock and through
/// `write_locked`.
/// `safedeps-core approvals revoke <hash> <staged> <entry> <seen>`: the revoked
/// entry put in place (`revoke`), and its answer on stdout: `revoked` and exit
/// 0, or `changed` or `not-revoked` and exit 1. Exit 2 for an argument that is
/// not one, and nothing is put in place.
/// `safedeps-core approvals index`: the index on stdout and exit 0, or exit 1
/// when the store cannot be read.
/// `safedeps-core approvals migrate [--json] [--] [<archive>...]`: the
/// approvals of advisory.log and of each archive that their ledger entries
/// confirm, moved into the store (approvals/migrate.rs). Exit 0 and its report
/// on stdout, exit 1 and what failed on stderr, exit 2 for an argument that
/// is not one.
pub fn cli(args: &[String]) -> i32 {
    os::set_umask(0o077);
    let mut stdin = Vec::new();
    if args.first().map(String::as_str) == Some("commit") {
        if let Err(e) = io::stdin().read_to_end(&mut stdin) {
            let how = Outcome::Io(Err(e));
            let _ = io::stderr().write_all(&cat(&[b"safedeps-core approvals: not committed: ", &how.describe(Action::Read(Path::new("stdin")), Form::Action), b"\n"]));
            println!("not-approved {} {}", Failure::LedgerWrite.as_str(), Entry::Untouched.as_str());
            return 1;
        }
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
        ["revoke", hash, staged, entry, seen] => {
            let r = Revoke { hash, staged: Path::new(staged), entry: Path::new(entry), seen: Path::new(seen) };
            if let Err(e) = checked_revoke(&r) {
                return (2, Vec::new(), format!("safedeps-core approvals: not revoked: {e}\n").into_bytes());
            }
            let mut err = Vec::new();
            let answer = revoke(dir, &r, &mut err);
            let code = if answer == Revoked::Revoked { 0 } else { 1 };
            (code, format!("{}\n", answer.as_str()).into_bytes(), err)
        }
        ["migrate", rest @ ..] => migrate::command(dir, &ledger::directory_in(dir), rest),
        ["index"] => match index(dir) {
            Ok(ix) => (0, format!("{}\n", index_json(&ix)).into_bytes(), Vec::new()),
            Err(e) => {
                let mut err = Vec::new();
                e.report(&mut err, format!("safedeps-core approvals: {} could not be read: ", store.display()).as_bytes(), b"");
                (1, Vec::new(), err)
            }
        },
        _ => (2, Vec::new(), USAGE.as_bytes().to_vec()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::{Cell, RefCell};
    use std::os::unix::fs::MetadataExt;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{mpsc, Arc, Barrier};
    use std::time::Instant;

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
    /// lock, with no entry and no approve line. A commit writes its line with
    /// its entry and its approve line, a migration writes one for an entry
    /// that stands already, and no command writes a line from its arguments
    /// alone; a test uses it to make a store that vouches.
    fn append(dir: &Path, hash: &str, record: &[u8]) -> Result<(), Appended> {
        append_within(dir, hash, record, LOCK_WAIT)
    }
    fn append_within(dir: &Path, hash: &str, record: &[u8], wait: Duration) -> Result<(), Appended> {
        let at = os::utc_stamp(os::wall(os::WallRole::ApprovalRecord).seconds());
        let file = locked(dir, wait)?;
        write_locked(&file, &path(dir), &line(&at, hash, Via::Check, record))
    }
    fn not_written(r: Result<(), Appended>) -> Vec<u8> {
        match r {
            Err(Appended::NotWritten(e)) => e.text(),
            other => panic!("not a not-written answer: {other:?}"),
        }
    }
    /// A hold of the store lock, taken as a writer or a reader takes it.
    fn holder(dir: &Path) -> fs::File {
        let f = fs::OpenOptions::new().read(true).append(true).create(true).mode(0o600).open(path(dir)).unwrap();
        lock_store(dir, &f, Duration::from_secs(1)).unwrap();
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
        // that is no time, a record that is no approval, the line a commit
        // writes when its rename failed, a whole record a writer sealed and a
        // torn tail.
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
                        let mut err = Vec::new();
                        let answer = commit(&dir, &approval(n, &staged, &entry, &r, &hash), &mut err);
                        assert_eq!(answer, Answer::Approved, "{}", String::from_utf8_lossy(&err));
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
        let held = holder(&d.0);
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
        let held = holder(&d.0);
        let e = not_written(append_within(&d.0, &h(1), &rec(1), Duration::from_millis(100)));
        assert_eq!(e, format!("the lock of {} did not finish before the deadline", path(&d.0).display()).as_bytes());
        assert_eq!(index_within(&d.0, Duration::from_millis(100)).unwrap_err().text(), e);
        drop(held);
        assert_eq!(fs::metadata(path(&d.0)).unwrap().len(), 0);
    }

    /// Exclusive holds of the store lock, one after another: `holds` of them,
    /// one every `each`, the last kept `quiet` longer. No line lands. Each
    /// next hold's file is open before the last hold goes, so the lock is free
    /// only between that close and the next lock. Returns once the first is
    /// held, with the thread, which ends when the lock goes and answers
    /// whether another took the lock between two holds.
    fn relay(dir: &Path, holds: u32, each: Duration, quiet: Duration) -> std::thread::JoinHandle<bool> {
        let dir = dir.to_owned();
        let mut held = holder(&dir);
        std::thread::spawn(move || {
            let mut gap = false;
            for _ in 1..holds {
                std::thread::sleep(each);
                let next = fs::OpenOptions::new().read(true).append(true).open(path(&dir)).unwrap();
                drop(held);
                // One try first: a refusal is another holder, which took the
                // lock between the two holds.
                if lock_store(&dir, &next, Duration::ZERO).is_err() {
                    gap = true;
                    lock_store(&dir, &next, LOCK_WAIT).unwrap();
                }
                held = next;
            }
            std::thread::sleep(each + quiet);
            drop(held);
            gap
        })
    }

    #[test]
    fn a_commit_waits_while_the_lock_changes_hands_however_long_it_stays_held() {
        // Commits that overlap hand the lock on: a commit whose wait ran out
        // while the lock went from one holder to the next answered
        // NotApproved(Store, Untouched). Here the lock changes hands every
        // twentieth of the wait for twice the wait, and no line lands. A run
        // where the commit took the lock between two holds does not count.
        let wait = Duration::from_secs(2);
        until_met(|| {
            let d = scratch();
            let relay = relay(&d.0, 40, Duration::from_millis(100), Duration::ZERO);
            let (staged, entry) = stage(&d.0, 1, "entry of 1");
            let (hash, r) = (h(1), rec(1));
            let started = Instant::now();
            let mut err = Vec::new();
            let answer = commit_with(&d.0, &approval(1, &staged, &entry, &r, &hash), wait, &Real, &mut err);
            let waited = started.elapsed();
            if relay.join().unwrap() {
                println!("# note: the commit took the lock between two holds, so this run does not count");
                return None;
            }
            assert_eq!(answer, Answer::Approved, "{}", String::from_utf8_lossy(&err));
            assert!(waited > wait, "the commit answered within the wait, {waited:?}, so the lock was not held that long");
            assert_eq!(index(&d.0).unwrap(), Index { present: true, hashes: vec![h(1)], broken: 0 });
            assert_eq!(fs::read_to_string(&entry).unwrap(), "entry of 1");
            assert_eq!(logged(&d.0), vec![record(1)]);
            Some(())
        });
    }

    #[test]
    fn a_lock_held_past_the_wait_after_its_last_handoff_is_an_error_and_nothing_is_written() {
        // The control. The wait counts from the start of the hold the commit
        // waits behind: a holder that took the lock and keeps it is waited
        // for the wait from its start, then the commit is refused, as a lock
        // held past the wait always was. A run where the commit took the lock
        // between two holds does not count.
        let wait = Duration::from_millis(500);
        until_met(|| {
            let d = scratch();
            let relay = relay(&d.0, 5, Duration::from_millis(100), Duration::from_secs(4));
            let (staged, entry) = stage(&d.0, 1, "entry of 1");
            let (hash, r) = (h(1), rec(1));
            let mut err = Vec::new();
            let answer = commit_with(&d.0, &approval(1, &staged, &entry, &r, &hash), wait, &Real, &mut err);
            let holding = !relay.is_finished();
            if relay.join().unwrap() {
                println!("# note: the commit took the lock between two holds, so this run does not count");
                return None;
            }
            assert_eq!(answer, Answer::NotApproved(Failure::Store, Entry::Untouched));
            assert!(holding, "the commit answered only once the holder let the lock go");
            assert_eq!(
                String::from_utf8_lossy(&err),
                format!("safedeps-core approvals: not committed: {0} could not be opened and locked: the lock of {0} did not finish before the deadline\n", path(&d.0).display())
            );
            assert_eq!(index(&d.0).unwrap(), Index { present: true, hashes: Vec::new(), broken: 0 });
            assert!(staged.exists() && !entry.exists());
            assert!(logged(&d.0).is_empty());
            Some(())
        });
    }

    #[test]
    fn a_commit_behind_a_read_held_past_the_wait_is_refused_while_other_reads_keep_trying() {
        // A validator's counterexample, kept as a row. A read keeps the store
        // lock past the wait, and two more reads, each in a thread of its own,
        // keep trying to read meanwhile. The lock never changes hands, so the
        // commit is refused at the wait, while the read still holds the lock,
        // and nothing is written.
        let d = scratch();
        let wait = Duration::from_millis(500);
        fs::OpenOptions::new().append(true).create(true).mode(0o600).open(path(&d.0)).unwrap();
        let (staged, entry) = stage(&d.0, 1, "entry of 1");
        // The read's hold, taken as a read takes it. It goes once the commit
        // answered, or after ten waits; the thread answers whether it went
        // first.
        let held = locked_for_reading(&d.0, LOCK_WAIT).unwrap().expect("the store");
        let (answered, told) = mpsc::channel::<()>();
        let reading = std::thread::spawn(move || {
            let first = told.recv_timeout(wait * 10).is_err();
            drop(held);
            first
        });
        let stop = Arc::new(AtomicBool::new(false));
        let readers: Vec<_> = (0..2)
            .map(|_| {
                let (dir, stop) = (d.0.clone(), Arc::clone(&stop));
                std::thread::spawn(move || {
                    while !stop.load(Ordering::SeqCst) {
                        let _ = index_within(&dir, wait);
                        std::thread::sleep(wait / 10);
                    }
                })
            })
            .collect();
        let mut err = Vec::new();
        let answer = commit_with(&d.0, &approval(1, &staged, &entry, &rec(1), &h(1)), wait, &Real, &mut err);
        let _ = answered.send(());
        let let_go_first = reading.join().unwrap();
        stop.store(true, Ordering::SeqCst);
        for r in readers {
            r.join().unwrap();
        }
        assert_eq!(answer, Answer::NotApproved(Failure::Store, Entry::Untouched), "{}", String::from_utf8_lossy(&err));
        assert!(!let_go_first, "the commit answered only once the read let the lock go");
        assert_eq!(
            String::from_utf8_lossy(&err),
            format!("safedeps-core approvals: not committed: {0} could not be opened and locked: the lock of {0} did not finish before the deadline\n", path(&d.0).display())
        );
        assert_eq!(index(&d.0).unwrap(), Index { present: true, hashes: Vec::new(), broken: 0 });
        assert!(staged.exists() && !entry.exists());
        assert!(logged(&d.0).is_empty());
    }

    #[test]
    fn a_turn_that_cannot_be_read_is_no_handoff() {
        // A turn a waiter cannot read counts for nothing, however often it
        // looks: a holder that keeps the lock is waited for the wait and no
        // longer.
        let d = scratch();
        let held = holder(&d.0);
        fs::remove_file(d.0.join(TURN)).unwrap();
        fs::create_dir(d.0.join(TURN)).unwrap();
        let (staged, entry) = stage(&d.0, 1, "entry of 1");
        let dir = d.0.clone();
        let waiter = std::thread::spawn(move || {
            let mut err = Vec::new();
            commit_with(&dir, &approval(1, &staged, &entry, &rec(1), &h(1)), Duration::from_millis(300), &Real, &mut err)
        });
        std::thread::sleep(Duration::from_secs(2));
        let answered = waiter.is_finished();
        drop(held);
        let answer = waiter.join().unwrap();
        assert!(answered, "the commit still waited when the holder let the lock go");
        assert_eq!(answer, Answer::NotApproved(Failure::Store, Entry::Untouched));
    }

    /// A hold of the store lock that has not written its turn: the lock
    /// taken and nothing else, as a holder has it between its lock and its
    /// turn.
    fn bare_hold(dir: &Path) -> fs::File {
        let f = fs::OpenOptions::new().read(true).append(true).create(true).mode(0o600).open(path(dir)).unwrap();
        assert!(os::flock_within(&f, Duration::ZERO, |_| None).is_ok(), "another held the lock");
        f
    }
    /// The turn's bytes, as the last hold that wrote one left them.
    fn turn_bytes(dir: &Path) -> Vec<u8> {
        fs::read(dir.join(TURN)).unwrap()
    }
    /// `bytes` over the turn's, in place, as a hold writes its turn.
    fn put_turn(dir: &Path, bytes: &[u8]) {
        fs::OpenOptions::new().write(true).open(dir.join(TURN)).unwrap().write_all_at(bytes, 0).unwrap();
    }

    #[test]
    fn a_commit_behind_one_hold_that_wrote_its_turn_late_is_refused_at_the_wait() {
        // A validator's counterexample, kept as a row. A read takes the lock,
        // and its turn lands six seconds later: until then the turn is the
        // last hold's. The read keeps the lock thirteen seconds. The lock
        // never changes hands while the commit waits, so the commit is
        // refused at the wait, while the read still holds the lock, and
        // nothing is written. A wait counted again from the moment the
        // waiter saw the turn change ran past the read's thirteen seconds,
        // and the commit was approved once the read let the lock go.
        let d = scratch();
        drop(holder(&d.0));
        let last = turn_bytes(&d.0);
        let (staged, entry) = stage(&d.0, 1, "entry of 1");
        let held = locked_for_reading(&d.0, LOCK_WAIT).unwrap().expect("the store");
        let began = Instant::now();
        let its_turn = turn_bytes(&d.0);
        assert_ne!(its_turn, last, "the read wrote no turn of its own");
        put_turn(&d.0, &last);
        let (dir, s, e) = (d.0.clone(), staged.clone(), entry.clone());
        let waiter = std::thread::spawn(move || {
            let mut err = Vec::new();
            let answer = commit(&dir, &approval(1, &s, &e, &rec(1), &h(1)), &mut err);
            (answer, err)
        });
        std::thread::sleep(Duration::from_secs(6));
        put_turn(&d.0, &its_turn);
        std::thread::sleep(Duration::from_secs(13).saturating_sub(began.elapsed()));
        let answered = waiter.is_finished();
        drop(held);
        let (answer, err) = waiter.join().unwrap();
        assert!(answered, "the commit answered only once the read let the lock go: {answer:?}");
        assert_eq!(answer, Answer::NotApproved(Failure::Store, Entry::Untouched), "{}", String::from_utf8_lossy(&err));
        assert_eq!(index(&d.0).unwrap(), Index { present: true, hashes: Vec::new(), broken: 0 });
        assert!(staged.exists() && !entry.exists());
        assert!(logged(&d.0).is_empty());
    }

    #[test]
    fn a_waiter_behind_a_hold_that_has_not_written_its_turn_over_an_old_one_waits_the_wait() {
        // The turn is a hold's that let the lock go twice the wait ago, and a
        // new hold took the lock and has not written its turn yet. A waiter
        // that counted from the start that old turn names would be refused at
        // its first try, for a hold that only began. It waits the wait from
        // its own start.
        let wait = Duration::from_secs(1);
        let d = scratch();
        drop(holder(&d.0));
        std::thread::sleep(wait * 2);
        let held = bare_hold(&d.0);
        let (staged, entry) = stage(&d.0, 1, "entry of 1");
        let started = Instant::now();
        let mut err = Vec::new();
        let answer = commit_with(&d.0, &approval(1, &staged, &entry, &rec(1), &h(1)), wait, &Real, &mut err);
        let waited = started.elapsed();
        drop(held);
        assert_eq!(answer, Answer::NotApproved(Failure::Store, Entry::Untouched), "{}", String::from_utf8_lossy(&err));
        assert!(waited >= wait, "refused after {waited:?}, before the wait: the old turn was counted for the new hold");
    }

    #[test]
    fn a_waiter_that_comes_in_the_middle_of_a_hold_waits_the_wait_from_its_own_start() {
        // A hold wrote its turn as it took the lock, and a commit comes three
        // quarters of the wait later. The commit is refused the wait after it
        // began to wait, not the wait after the hold began: the wait is the
        // waiter's.
        let wait = Duration::from_secs(1);
        let d = scratch();
        let held = holder(&d.0);
        std::thread::sleep(wait * 3 / 4);
        let (staged, entry) = stage(&d.0, 1, "entry of 1");
        let started = Instant::now();
        let mut err = Vec::new();
        let answer = commit_with(&d.0, &approval(1, &staged, &entry, &rec(1), &h(1)), wait, &Real, &mut err);
        let waited = started.elapsed();
        drop(held);
        assert_eq!(answer, Answer::NotApproved(Failure::Store, Entry::Untouched), "{}", String::from_utf8_lossy(&err));
        assert!(waited >= wait, "refused after {waited:?}: the wait was counted from the hold's start");
    }

    #[test]
    fn a_torn_turn_is_no_new_hold() {
        // A waiter can read the turn while a hold writes it, and get the
        // first bytes of one line with the last of another. Such a line is no
        // hold's. Here the turn goes back and forth between two such lines,
        // made of the turns two holds wrote, while the second hold keeps the
        // lock. The lock never changes hands, so the commit is refused at the
        // wait, while the hold keeps the lock.
        let wait = Duration::from_millis(300);
        let d = scratch();
        drop(holder(&d.0));
        let old = turn_bytes(&d.0);
        let held = holder(&d.0);
        let new = turn_bytes(&d.0);
        let k = old.iter().zip(&new).position(|(a, b)| a != b).expect("two holds wrote one turn") + 1;
        let torn = [[&new[..k], &old[k..]].concat(), [&old[..k], &new[k..]].concat()];
        for t in &torn {
            assert!(t != &old && t != &new, "a torn line that is one of the two");
        }
        let stop = Arc::new(AtomicBool::new(false));
        let flipper = {
            let (dir, stop) = (d.0.clone(), Arc::clone(&stop));
            std::thread::spawn(move || {
                for t in torn.iter().cycle() {
                    if stop.load(Ordering::SeqCst) {
                        break;
                    }
                    put_turn(&dir, t);
                    std::thread::sleep(Duration::from_millis(20));
                }
            })
        };
        let (staged, entry) = stage(&d.0, 1, "entry of 1");
        let dir = d.0.clone();
        let waiter = std::thread::spawn(move || {
            let mut err = Vec::new();
            commit_with(&dir, &approval(1, &staged, &entry, &rec(1), &h(1)), wait, &Real, &mut err)
        });
        std::thread::sleep(Duration::from_secs(2));
        let answered = waiter.is_finished();
        stop.store(true, Ordering::SeqCst);
        flipper.join().unwrap();
        drop(held);
        let answer = waiter.join().unwrap();
        assert!(answered, "the commit still waited when the hold let the lock go: a torn turn was taken for a new hold");
        assert_eq!(answer, Answer::NotApproved(Failure::Store, Entry::Untouched));
    }

    /// A waiter's commit of 1 under `dir`, in a thread, behind a hold kept
    /// `held_for`; `meanwhile` runs once the commit started. Answers whether
    /// the commit answered while the hold kept the lock, and what.
    fn commit_behind(dir: &Path, held: fs::File, wait: Duration, held_for: Duration, meanwhile: impl FnOnce()) -> (bool, Answer) {
        let (staged, entry) = stage(dir, 1, "entry of 1");
        let home = dir.to_owned();
        let began = Instant::now();
        let waiter = std::thread::spawn(move || {
            let mut err = Vec::new();
            commit_with(&home, &approval(1, &staged, &entry, &rec(1), &h(1)), wait, &Real, &mut err)
        });
        meanwhile();
        std::thread::sleep(held_for.saturating_sub(began.elapsed()));
        let answered = waiter.is_finished();
        drop(held);
        (answered, waiter.join().unwrap())
    }

    #[test]
    fn a_turn_that_was_there_when_the_wait_began_never_counts() {
        // A turn written before the host's clock started again can name a
        // time the clock reaches only later, and a hold that has not written
        // its own turn leaves it standing. Here it names a time just short of
        // the wait. Counted once the clock reached it, it would have the wait
        // start there and run past the hold. It was the first turn the waiter
        // read, so it counts for nothing, and the commit is refused at the
        // wait while the hold keeps the lock.
        let wait = Duration::from_secs(2);
        let d = scratch();
        drop(holder(&d.0));
        let held = bare_hold(&d.0);
        put_turn(&d.0, Turn { began: os::host_clock().after(wait * 9 / 10) }.line().as_bytes());
        let (answered, answer) = commit_behind(&d.0, held, wait, wait * 3 / 2, || ());
        assert!(answered, "the commit answered only once the hold let the lock go: {answer:?}");
        assert_eq!(answer, Answer::NotApproved(Failure::Store, Entry::Untouched));
    }

    #[test]
    fn a_turn_that_names_a_time_later_than_now_counts_for_nothing() {
        // A turn that names a time the clock has not reached is no hold of
        // this host. Here one an hour ahead lands while a hold keeps the lock,
        // after the waiter read the hold's own: the commit is refused at the
        // wait while the hold keeps the lock.
        let wait = Duration::from_millis(500);
        let d = scratch();
        let held = holder(&d.0);
        let (answered, answer) = commit_behind(&d.0, held, wait, Duration::from_secs(2), || {
            std::thread::sleep(wait / 5);
            put_turn(&d.0, Turn { began: os::host_clock().after(Duration::from_secs(3600)) }.line().as_bytes());
        });
        assert!(answered, "the commit answered only once the hold let the lock go: {answer:?}");
        assert_eq!(answer, Answer::NotApproved(Failure::Store, Entry::Untouched));
    }

    #[test]
    fn a_turn_is_a_time_on_the_host_clock_and_its_check() {
        // The line a hold writes: its time read just before the lock, and the
        // check that a line read while a hold writes over it fails.
        let d = scratch();
        let before = os::host_clock();
        drop(holder(&d.0));
        let after = os::host_clock();
        let bytes = turn_bytes(&d.0);
        assert_eq!(bytes.len(), Turn::LEN);
        let turn = Turn::parse(bytes.as_slice().try_into().unwrap()).expect("a whole turn");
        assert!(before <= turn.began && turn.began <= after, "{before:?} {turn:?} {after:?}");
        assert_eq!(bytes[20], b' ');
        assert_eq!(&bytes[21..37], sha256::hex(&bytes[..20])[..16].as_bytes());
        let mut wrong = bytes.clone();
        wrong[19] = if wrong[19] == b'0' { b'1' } else { b'0' };
        assert_eq!(Turn::parse(wrong.as_slice().try_into().unwrap()), None, "a time whose check is another's");
    }

    /// A commit's steps as `Real` runs them, but paced: the lock kept
    /// `before_line` before the store is read, and `after_line` once the line
    /// landed, which `landed` is told. `began` and `ended` are the hold's first
    /// step and its last.
    struct Paced {
        before_line: Duration,
        after_line: Duration,
        landed: Option<mpsc::Sender<()>>,
        began: Cell<Option<Instant>>,
        ended: Cell<Option<Instant>>,
    }

    impl Steps for Paced {
        fn lstat(&self, p: &Path) -> io::Result<fs::Metadata> {
            self.began.set(Some(Instant::now()));
            fs::symlink_metadata(p)
        }
        fn read(&self, file: &fs::File, store: &Path) -> Result<Index, Fault> {
            std::thread::sleep(self.before_line);
            read_locked(file, store)
        }
        fn log(&self, log: &Path, at: &str, text: &[u8]) -> Result<(), Fault> {
            if let Some(landed) = &self.landed {
                landed.send(()).unwrap();
            }
            std::thread::sleep(self.after_line);
            log_line(log, at, text)
        }
        fn rename(&self, from: &Path, to: &Path) -> io::Result<()> {
            self.ended.set(Some(Instant::now()));
            fs::rename(from, to)
        }
    }

    /// What `waiter` answered behind two commits of 1 and 2 under `dir`, one
    /// after the other in a thread of their own. The first keeps the lock
    /// `hold` once its line landed, the second `hold` before its line, and
    /// `waiter` starts when the first line landed, so it waits through the
    /// lock going from one to the other: each hold is shorter than `wait`, the
    /// two together longer. `waiter` answers what it answered and whether it
    /// took the lock. A run where it took the lock between the two holds, or
    /// where a hold reached `wait`, did not meet that condition: it says so,
    /// and its answer is None.
    fn behind_two_commits<T>(dir: &Path, hold: Duration, wait: Duration, waiter: impl FnOnce() -> (T, bool)) -> Option<T> {
        let (landed, first_line) = mpsc::channel();
        let home = dir.to_owned();
        let pair = std::thread::spawn(move || {
            let paced = |before_line, after_line, landed| Paced { before_line, after_line, landed, began: Cell::new(None), ended: Cell::new(None) };
            [(1, paced(Duration::ZERO, hold, Some(landed))), (2, paced(hold, Duration::ZERO, None))].map(|(n, steps)| {
                let (staged, entry) = stage(&home, n, &format!("entry of {n}"));
                let mut err = Vec::new();
                let answer = commit_with(&home, &approval(n, &staged, &entry, &rec(n), &h(n)), LOCK_WAIT, &steps, &mut err);
                assert_eq!(answer, Answer::Approved, "commit {n}: {}", String::from_utf8_lossy(&err));
                (steps.began.get().unwrap(), steps.ended.get().unwrap())
            })
        });
        first_line.recv().unwrap();
        let (answer, took) = waiter();
        let answered = Instant::now();
        let [first, second] = pair.join().unwrap();
        let held = |(began, ended): (Instant, Instant)| ended - began;
        if held(first) >= wait || held(second) >= wait {
            println!("# note: a hold reached the wait ({:?}, {:?}), so this run does not count", held(first), held(second));
            return None;
        }
        if took && answered < second.1 {
            println!("# note: the waiter took the lock between the two holds, so this run does not count");
            return None;
        }
        Some(answer)
    }

    /// The answer of the first of three runs that met its condition. A row
    /// where none did is red.
    fn until_met<T>(run: impl FnMut() -> Option<T>) -> T {
        std::iter::repeat_with(run).take(3).flatten().next().expect("no run of three met its condition")
    }

    #[test]
    fn a_commit_behind_two_commits_waits_for_both_when_each_holds_less_than_the_wait() {
        // Two commits each keep the lock less than the wait, and a commit
        // that waits through both waits longer than the wait. It is approved:
        // the lock changed hands. Two seconds a hold is the control, where
        // the two together are shorter than the wait too.
        for seconds in [2, 6] {
            let ((answer, err), ix) = until_met(|| {
                let d = scratch();
                let (staged, entry) = stage(&d.0, 3, "entry of 3");
                let met = behind_two_commits(&d.0, Duration::from_secs(seconds), LOCK_WAIT, || {
                    let mut err = Vec::new();
                    let answer = commit(&d.0, &approval(3, &staged, &entry, &rec(3), &h(3)), &mut err);
                    let took = answer == Answer::Approved;
                    ((answer, err), took)
                })?;
                Some((met, index(&d.0).unwrap()))
            });
            assert_eq!(answer, Answer::Approved, "{seconds} s a hold: {}", String::from_utf8_lossy(&err));
            assert_eq!(ix, Index { present: true, hashes: vec![h(1), h(2), h(3)], broken: 0 }, "{seconds} s a hold");
        }
    }

    #[test]
    fn a_reader_behind_two_commits_waits_for_both_when_each_holds_less_than_the_wait() {
        let wait = Duration::from_secs(5);
        let ix = until_met(|| {
            let d = scratch();
            behind_two_commits(&d.0, Duration::from_secs(3), wait, || {
                let ix = index_within(&d.0, wait).map_err(|e| String::from_utf8_lossy(&e.text()).into_owned());
                let took = ix.is_ok();
                (ix, took)
            })
        });
        assert_eq!(ix, Ok(Index { present: true, hashes: vec![h(1), h(2)], broken: 0 }));
    }

    /// A commit of 1 under `dir`, in a thread, behind one hold: a hold that
    /// took the lock from the last one while the commit waited, and keeps it
    /// `held_for` from the start its turn names. Answers what the commit
    /// answered and said, the hold's turn, and when the commit answered; or
    /// None, saying so, for a run where the commit did not wait for that hold
    /// to let the lock go. It began only after the hold began, or it answered
    /// while the hold still kept the lock: it took the lock between the two
    /// holds, or it was refused at a try the lock refused.
    fn behind_one_hold(dir: &Path, held_for: Duration) -> Option<(Answer, Vec<u8>, Turn, os::HostTime)> {
        let last = holder(dir);
        let (staged, entry) = stage(dir, 1, "entry of 1");
        let home = dir.to_owned();
        let waiter = std::thread::spawn(move || {
            let called = os::host_clock();
            let mut err = Vec::new();
            let answer = commit(&home, &approval(1, &staged, &entry, &rec(1), &h(1)), &mut err);
            (called, answer, err, os::host_clock())
        });
        std::thread::sleep(Duration::from_secs(1));
        let next = fs::OpenOptions::new().read(true).append(true).open(path(dir)).unwrap();
        drop(last);
        lock_store(dir, &next, LOCK_WAIT).unwrap();
        let turn = read_turn(dir).expect("the hold's turn");
        let until = turn.began.after(held_for);
        std::thread::sleep(Duration::from_nanos(until.0.saturating_sub(os::host_clock().0)).saturating_sub(Duration::from_millis(40)));
        while os::host_clock() < until {
            std::hint::spin_loop();
        }
        let answered = waiter.is_finished();
        drop(next);
        let (called, answer, err, at) = waiter.join().unwrap();
        if called > turn.began {
            println!("# note: the commit began only after the hold took the lock, so this run does not count");
            return None;
        }
        if answered {
            println!("# note: the commit answered while the hold kept the lock ({answer:?}), so this run does not count");
            return None;
        }
        Some((answer, err, turn, at))
    }

    #[test]
    fn a_commit_granted_the_lock_after_the_wait_ran_out_is_refused_and_writes_nothing() {
        // A validator's counterexample, kept as a row. One hold keeps the
        // lock a tenth of a millisecond past the wait from its start, and the
        // commit behind it is granted the lock at its next try, after the
        // wait ran out. So the commit is refused, and it lets the lock go
        // before it writes anything: the store keeps its torn tail unsealed,
        // the turn is still the hold's, and the entry no check approved
        // stands. A wait judged only at the tries the lock refused let the
        // commit through once the hold let the lock go.
        const TORN: &[u8] = b"{\"at\":\"2020-01-01T";
        let (d, entry, turn, answer, err) = until_met(|| {
            let d = scratch();
            fs::write(path(&d.0), TORN).unwrap();
            let entry = stand(&d.0, 1, "an entry no check approved");
            let (answer, err, turn, _) = behind_one_hold(&d.0, LOCK_WAIT + Duration::from_micros(100))?;
            Some((d, entry, turn, answer, err))
        });
        assert_eq!(answer, Answer::NotApproved(Failure::Store, Entry::Untouched), "{}", String::from_utf8_lossy(&err));
        assert_eq!(
            String::from_utf8_lossy(&err),
            format!("safedeps-core approvals: not committed: {0} could not be opened and locked: the lock of {0} did not finish before the deadline\n", path(&d.0).display())
        );
        assert_eq!(fs::read(path(&d.0)).unwrap(), TORN, "the store's bytes changed");
        assert_eq!(turn_bytes(&d.0), turn.line().as_bytes(), "the turn is not the hold's");
        assert_eq!(fs::read_to_string(&entry).unwrap(), "an entry no check approved");
        assert!(logged(&d.0).is_empty());
    }

    #[test]
    fn a_commit_granted_the_lock_before_the_wait_ran_out_behind_one_hold_is_approved() {
        // The control. The hold keeps the lock 9.7 seconds from its start,
        // and the commit behind it is granted the lock at its next try,
        // within the wait: it is approved. A run where it answered otherwise
        // only past the wait, as a machine too busy to try again in time can
        // make it, does not count.
        let (d, answer, err) = until_met(|| {
            let d = scratch();
            let (answer, err, turn, at) = behind_one_hold(&d.0, Duration::from_millis(9700))?;
            if answer != Answer::Approved && at > turn.began.after(LOCK_WAIT) {
                println!("# note: the commit answered {answer:?} only past the wait, so this run does not count");
                return None;
            }
            Some((d, answer, err))
        });
        assert_eq!(answer, Answer::Approved, "{}", String::from_utf8_lossy(&err));
        assert_eq!(index(&d.0).unwrap(), Index { present: true, hashes: vec![h(1)], broken: 0 });
    }

    #[test]
    fn a_sync_that_fails_after_a_whole_write_is_unsynced_and_the_line_is_seen() {
        // No file system here fails a sync on demand, so the sync is the one
        // part a test puts in: the write and the store are the real ones.
        let d = scratch();
        let file = open_for_append(&d.0).unwrap();
        let whole = line("2026-11-19T08:00:00Z", &h(1), Via::Check, &rec(1));
        match write_then_sync(&file, &path(&d.0), &whole, |_| Err(io::Error::from_raw_os_error(5))) {
            Err(Appended::Unsynced(e)) => assert_eq!(e.describe(Action::Sync(&path(&d.0)), Form::Action), format!("the sync of {} returned OS error 5", path(&d.0).display()).as_bytes()),
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
        let r = write_then_sync(&read_only, &path(&d.0), &whole, |_| panic!("a failed write reached the sync"));
        assert!(matches!(r, Err(Appended::NotWritten(_))), "{r:?}");
        assert_eq!(index(&d.0).unwrap(), Index { present: true, hashes: Vec::new(), broken: 0 });
    }

    #[test]
    fn store_creation_open_and_authored_rejection_stay_distinct() {
        let d = scratch();
        let blocker = d.0.join("file");
        fs::write(&blocker, b"not a directory").unwrap();
        let create = open_for_append(&blocker).unwrap_err();
        assert!(create.text().starts_with(format!("the creation of {} returned OS error ", blocker.display()).as_bytes()));
        let store = path(&d.0);
        fs::create_dir(&store).unwrap();
        let open = open_for_append(&d.0).unwrap_err();
        assert!(open.text().starts_with(format!("the open of {} returned OS error ", store.display()).as_bytes()));
        assert_eq!(regular(fs::File::open(&store).unwrap(), &store).unwrap_err().text(), b"the approvals store is not a regular file");
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
        match os::flock_within(&other, Duration::ZERO, |_| None) {
            Ok(_) => false,
            Err(Outcome::Deadline) => true,
            Err(e) => panic!("the lock check failed: {e:?}"),
        }
    }

    /// The kind of advisory.log line `text` is to a commit: its approve line,
    /// the line step 0 writes when it removed an entry, or another
    /// (`approve-unsynced`, `approve-undone`).
    fn line_kind(text: &[u8]) -> &'static str {
        if text.starts_with(RECORD_PREFIX) {
            "approve-line"
        } else if text.starts_with(REMOVAL.as_bytes()) {
            "removal-line"
        } else {
            "other-line"
        }
    }

    /// A commit's steps as `Real` runs them, each named in `calls` as it
    /// starts: `lstat`, `read`, `unlink`, `sync-dir`, `append`, `rename`, and
    /// an advisory.log line by its kind (`line_kind`). `fail` names the one
    /// step that fails, with the error `code`; or it is `unsynced`, the store
    /// line written whole and its sync failed, or `torn`, half the store line
    /// written and the write failed. `before` runs before each step, with its
    /// name. `gone_after_unlink`: a read of the path after an unlink finds
    /// nothing there, whatever the unlink answered.
    struct Driven<'a> {
        fail: &'static str,
        code: i32,
        gone_after_unlink: bool,
        before: Option<&'a dyn Fn(&'static str)>,
        calls: RefCell<Vec<&'static str>>,
    }

    fn driven<'a>(fail: &'static str, code: i32) -> Driven<'a> {
        Driven { fail, code, gone_after_unlink: false, before: None, calls: RefCell::new(Vec::new()) }
    }

    impl Driven<'_> {
        fn step(&self, name: &'static str) -> io::Result<()> {
            if let Some(before) = self.before {
                before(name);
            }
            self.calls.borrow_mut().push(name);
            if self.fail == name {
                Err(io::Error::from_raw_os_error(self.code))
            } else {
                Ok(())
            }
        }
        fn calls(&self) -> Vec<&'static str> {
            self.calls.borrow().clone()
        }
    }

    impl Steps for Driven<'_> {
        fn lstat(&self, p: &Path) -> io::Result<fs::Metadata> {
            self.step("lstat")?;
            if self.gone_after_unlink && self.calls.borrow().contains(&"unlink") {
                return Err(io::Error::from(io::ErrorKind::NotFound));
            }
            fs::symlink_metadata(p)
        }
        fn read(&self, file: &fs::File, store: &Path) -> Result<Index, Fault> {
            observed(self.step("read"), store, |p| Action::Read(p))?;
            read_locked(file, store)
        }
        fn unlink(&self, p: &Path) -> io::Result<()> {
            self.step("unlink")?;
            fs::remove_file(p)
        }
        fn log(&self, log: &Path, at: &str, text: &[u8]) -> Result<(), Fault> {
            observed(self.step(line_kind(text)), log, |p| Action::Write(p))?;
            log_line(log, at, text)
        }
        fn sync_dir(&self, dir: &Path) -> Result<(), Fault> {
            observed(self.step("sync-dir"), dir, |p| Action::Sync(p))?;
            Real.sync_dir(dir)
        }
        fn append(&self, file: &fs::File, store: &Path, line: &[u8]) -> Result<(), Appended> {
            observed(self.step("append"), store, |p| Action::Write(p))?;
            let code = self.code;
            match self.fail {
                "unsynced" => write_then_sync(file, store, line, |_| Err(io::Error::from_raw_os_error(code))),
                "torn" => {
                    let mut w: &fs::File = file;
                    observed(w.write_all(&line[..line.len() / 2]), store, |p| Action::Write(p))?;
                    Err(Appended::NotWritten(Fault::operation(Outcome::Io(Err(io::Error::from_raw_os_error(code))), store, |p| Action::Write(p))))
                }
                _ => write_locked(file, store, line),
            }
        }
        fn rename(&self, from: &Path, to: &Path) -> io::Result<()> {
            self.step("rename")?;
            fs::rename(from, to)
        }
    }

    /// How many lines the store in `home` holds, sealed and broken ones
    /// included.
    fn store_lines(home: &Path) -> usize {
        fs::read(path(home)).unwrap_or_default().iter().filter(|&&b| b == b'\n').count()
    }
    fn nothing_at(p: &Path) -> bool {
        matches!(fs::symlink_metadata(p), Err(e) if e.kind() == io::ErrorKind::NotFound)
    }
    /// The line step 0 writes when it removed the entry of 1 at `entry`.
    fn removal(entry: &Path) -> String {
        format!("{} hash={} entry={} outcome=removal returned without error", REMOVAL, h(1), entry.display())
    }

    #[test]
    fn a_failed_commit_reports_the_observed_operation_and_its_path() {
        for step in ["lstat", "read", "unlink", "removal-line", "sync-dir", "append", "unsynced", "approve-line", "rename"] {
            let d = scratch();
            let entry = stand(&d.0, 1, "unvouched");
            let (staged, _) = stage(&d.0, 1, "new entry");
            let (hash, record) = (h(1), rec(1));
            let expected = match step {
                "lstat" => format!("the read of {}", entry.display()),
                "read" => format!("the read of {}", path(&d.0).display()),
                "unlink" => "removal".to_string(),
                "removal-line" | "approve-line" => format!("the write to {}", d.0.join(ADVISORY_LOG).display()),
                "sync-dir" => format!("the sync of {}", dir_of(&entry).display()),
                "append" => format!("the write to {}", path(&d.0).display()),
                "unsynced" => format!("the sync of {}", path(&d.0).display()),
                "rename" => format!("the rename to {}", entry.display()),
                _ => unreachable!(),
            } + " returned OS error 5";
            let mut err = Vec::new();
            let answer = commit_with(&d.0, &approval(1, &staged, &entry, &record, &hash), LOCK_WAIT, &driven(step, 5), &mut err);
            assert_ne!(answer, Answer::Approved, "{step}");
            let err = String::from_utf8(err).unwrap();
            assert!(err.contains(&expected), "{step}: expected {expected:?}, got {err:?}");
            if matches!(step, "unsynced" | "rename") {
                assert!(logged(&d.0).last().unwrap().ends_with(&format!(" outcome={expected}")));
            }
        }
    }

    #[test]
    fn the_whole_take_back_line_keeps_non_utf8_path_bytes_without_a_file() {
        let entry = Path::new(std::ffi::OsStr::from_bytes(b"/fixture/with spaces-\xff/entry.json"));
        let outcome = Outcome::Io(Err(io::Error::from_raw_os_error(18)));
        let hash = h(1);
        let mut line = Vec::new();
        say_undone(&hash, entry, &outcome, |bytes| line = log_record("2026-01-01T00:00:00Z", bytes));
        assert_eq!(line, [format!("[2026-01-01T00:00:00Z] check approve-undone hash={hash} outcome=the rename to ").as_bytes(),
            entry.as_os_str().as_bytes(), b" returned OS error 18\n"].concat());
    }

    #[test]
    fn the_rename_outcome_reaches_the_last_field_as_its_original_bytes() {
        let d = scratch();
        let home = d.0.join("with spaces-é");
        fs::create_dir(&home).unwrap();
        let (staged, entry) = stage(&home, 1, "new entry");
        let (hash, record) = (h(1), rec(1));
        let mut err = Vec::new();
        let answer = commit_with(&home, &approval(1, &staged, &entry, &record, &hash), LOCK_WAIT, &driven("rename", 18), &mut err);
        assert_eq!(answer, Answer::NotApproved(Failure::LedgerWrite, Entry::Untouched));
        let expected = [b"the rename to ".as_slice(), entry.as_os_str().as_bytes(), b" returned OS error 18"].concat();
        assert!(err.ends_with(&[expected.as_slice(), b"\n"].concat()));
        assert!(fs::read(home.join(ADVISORY_LOG)).unwrap().ends_with(
            &[format!("check approve-undone hash={hash} outcome=").as_bytes(), &expected, b"\n"].concat()));
    }
    /// The path of the entry of 1 in `home`; and where `stood`, the entry A
    /// approved standing there, a store line that vouches for it, and its
    /// inode.
    fn start(home: &Path, stood: bool) -> (PathBuf, Option<u64>) {
        if stood {
            append(home, &h(1), &rec(1)).unwrap();
            let entry = stand(home, 1, "the entry A approved");
            let was = ino(&entry);
            (entry, Some(was))
        } else {
            (home.join("approved-specs").join(ledger::filename(&h(1))), None)
        }
    }
    /// What `start` left at the path is there still: the same file with the
    /// same bytes, or nothing.
    fn as_it_was(entry: &Path, was: Option<u64>) -> bool {
        match was {
            Some(i) => {
                fs::metadata(entry).is_ok_and(|m| m.ino() == i) && fs::read_to_string(entry).is_ok_and(|s| s == "the entry A approved")
            }
            None => nothing_at(entry),
        }
    }

    #[test]
    fn a_commit_writes_its_store_line_then_its_approve_line_then_renames_with_the_lock_held() {
        let d = scratch();
        let (staged, entry) = stage(&d.0, 1, "entry of 1");
        let (hash, r) = (h(1), rec(1));
        let stored = || read(&fs::read(path(&d.0)).unwrap_or_default()).hashes;
        let check = |step: &'static str| {
            assert!(held_elsewhere(&d.0), "the store lock is not held at {step}");
            if matches!(step, "append" | "approve-line" | "rename") {
                assert!(staged.exists() && nothing_at(&entry), "an entry was in place before {step}");
            }
            match step {
                "append" => assert!(stored().is_empty() && logged(&d.0).is_empty(), "a record was written before the store line"),
                "approve-line" => {
                    assert_eq!(stored(), vec![h(1)], "the approve line came before the store line");
                    assert!(logged(&d.0).is_empty());
                }
                "rename" => {
                    assert_eq!(stored(), vec![h(1)]);
                    assert_eq!(logged(&d.0), vec![record(1)], "the rename came before the approve line");
                }
                _ => {}
            }
        };
        let mut steps = driven("", 0);
        steps.before = Some(&check as &dyn Fn(&'static str));
        let mut err = Vec::new();
        let answer = commit_with(&d.0, &approval(1, &staged, &entry, &r, &hash), LOCK_WAIT, &steps, &mut err);
        assert_eq!(answer, Answer::Approved);
        assert!(err.is_empty(), "{}", String::from_utf8_lossy(&err));
        let writes: Vec<&str> = steps.calls().into_iter().filter(|s| matches!(*s, "append" | "approve-line" | "rename")).collect();
        assert_eq!(writes, vec!["append", "approve-line", "rename"]);
        assert!(!staged.exists());
        assert_eq!(fs::read_to_string(&entry).unwrap(), "entry of 1");
        assert_eq!(logged(&d.0), vec![record(1)]);
        assert_eq!(index(&d.0).unwrap(), Index { present: true, hashes: vec![h(1)], broken: 0 });
        let stored_bytes = fs::read(path(&d.0)).unwrap();
        let v = json::parse_one(&stored_bytes[..stored_bytes.len() - 1]).unwrap();
        // One reading of the clock stamps the store line and the approve line.
        let logged_line = fs::read_to_string(d.0.join(ADVISORY_LOG)).unwrap();
        assert_eq!(v.get("at").unwrap().as_str(), Some(&logged_line[1..21]));
        assert!(!held_elsewhere(&d.0), "the lock outlived the commit");
    }

    #[test]
    fn a_commit_takes_the_lock_before_it_reads_or_writes_anything() {
        let d = scratch();
        let entry = stand(&d.0, 1, "an entry the store does not vouch for");
        let before = ino(&entry);
        let (staged, _) = stage(&d.0, 1, "entry of 1");
        let (hash, r) = (h(1), rec(1));
        let held = holder(&d.0);
        let steps = driven("", 0);
        let mut err = Vec::new();
        let answer = commit_with(&d.0, &approval(1, &staged, &entry, &r, &hash), Duration::from_millis(100), &steps, &mut err);
        drop(held);
        assert_eq!(answer, Answer::NotApproved(Failure::Store, Entry::Untouched));
        assert!(steps.calls().is_empty(), "the commit ran {:?} without the lock", steps.calls());
        assert_eq!(ino(&entry), before, "the entry was removed or replaced without the lock");
        assert!(staged.exists());
        assert!(!d.0.join(ADVISORY_LOG).exists());
        assert_eq!(fs::metadata(path(&d.0)).unwrap().len(), 0);
        assert!(String::from_utf8(err).unwrap().starts_with("safedeps-core approvals: not committed: "));
    }

    #[test]
    fn a_commit_that_fails_at_a_step_writes_nothing_after_it_and_leaves_the_path_as_it_was() {
        // (the step that fails, its error, the failure, the store lines the
        // commit adds, advisory.log), each where nothing stood at the path and
        // where an entry the store vouches for stood there.
        let undone = format!("check approve-undone hash={} outcome=the rename to {{entry}} returned OS error 18", h(1));
        let cases: [(&'static str, i32, Failure, usize, Vec<String>); 3] = [
            ("append", 27, Failure::Store, 0, Vec::new()),
            ("approve-line", 13, Failure::LedgerWrite, 1, Vec::new()),
            ("rename", 18, Failure::LedgerWrite, 1, vec![record(1), undone]),
        ];
        for (step, code, failure, lines, log) in cases {
            for stood in [false, true] {
                let d = scratch();
                let (entry, was) = start(&d.0, stood);
                let (staged, _) = stage(&d.0, 1, "the entry B wrote");
                let (hash, r) = (h(1), rec(1));
                let steps = driven(step, code);
                let mut err = Vec::new();
                let answer = commit_with(&d.0, &approval(1, &staged, &entry, &r, &hash), LOCK_WAIT, &steps, &mut err);
                assert_eq!(answer, Answer::NotApproved(failure, Entry::Untouched), "{step} stood={stood}");
                // A rename that fails is followed by its own line, and by
                // nothing else.
                let last: &'static str = if step == "rename" { "other-line" } else { step };
                assert_eq!(steps.calls().last(), Some(&last), "{step} stood={stood}: a step ran after the one that failed");
                assert!(as_it_was(&entry, was), "{step} stood={stood}: the path does not hold what it held");
                assert!(staged.exists(), "{step} stood={stood}: the commit removed the staged entry");
                assert_eq!(store_lines(&d.0), usize::from(stood) + lines, "{step} stood={stood}");
                assert_eq!(logged(&d.0), log.iter().map(|l| l.replace("{entry}", &entry.display().to_string())).collect::<Vec<_>>(), "{step} stood={stood}");
            }
        }
    }

    /// F1: an entry no check approved stands at the path, and the commit fails
    /// after its store line, so the store vouches for the hash. Step 0 removed
    /// the entry, so no entry stands for that line to vouch for.
    fn fails_over_an_entry_no_check_approved(step: &'static str, code: i32, failure: Failure) {
        let d = scratch();
        let entry = stand(&d.0, 1, "an entry no check approved");
        let (staged, _) = stage(&d.0, 1, "the entry B wrote");
        let (hash, r) = (h(1), rec(1));
        let steps = driven(step, code);
        let mut err = Vec::new();
        let answer = commit_with(&d.0, &approval(1, &staged, &entry, &r, &hash), LOCK_WAIT, &steps, &mut err);
        assert_eq!(index(&d.0).unwrap().hashes, vec![h(1)], "{step}: the store does not vouch for the hash, so the row shows nothing");
        assert_eq!(answer, Answer::NotApproved(failure, Entry::Removed), "{step}");
        assert!(nothing_at(&entry), "{step}: an entry no check approved stands, and the store vouches for its hash");
        assert!(staged.exists(), "{step}: the commit removed the staged entry");
        assert_eq!(logged(&d.0).first(), Some(&removal(&entry)), "{step}");
    }

    #[test]
    fn a_rename_that_fails_over_an_entry_no_check_approved_leaves_no_entry() {
        fails_over_an_entry_no_check_approved("rename", 1, Failure::LedgerWrite);
    }

    #[test]
    fn an_approve_line_that_fails_over_an_entry_no_check_approved_leaves_no_entry() {
        fails_over_an_entry_no_check_approved("approve-line", 13, Failure::LedgerWrite);
    }

    #[test]
    fn a_store_line_not_synced_over_an_entry_no_check_approved_leaves_no_entry() {
        fails_over_an_entry_no_check_approved("unsynced", 5, Failure::InDoubt);
    }

    #[test]
    fn a_store_line_written_and_not_synced_stops_the_commit_before_the_rename() {
        for stood in [false, true] {
            let d = scratch();
            let (entry, was) = start(&d.0, stood);
            let (staged, _) = stage(&d.0, 1, "the entry B wrote");
            let (hash, r) = (h(1), rec(1));
            let steps = driven("unsynced", 5);
            let mut err = Vec::new();
            let answer = commit_with(&d.0, &approval(1, &staged, &entry, &r, &hash), LOCK_WAIT, &steps, &mut err);
            assert_eq!(answer, Answer::NotApproved(Failure::InDoubt, Entry::Untouched), "stood={stood}");
            let calls = steps.calls();
            assert!(!calls.contains(&"approve-line") && !calls.contains(&"rename"), "stood={stood}: {calls:?}");
            assert!(as_it_was(&entry, was), "stood={stood}: the path does not hold what it held");
            assert!(staged.exists(), "stood={stood}");
            let err = String::from_utf8(err).unwrap();
            assert!(err.starts_with(&format!("safedeps: unsynced: the approvals store line of {} was written and not synced (the sync of {} returned OS error 5).", h(1), path(&d.0).display())), "{err}");
            assert_eq!(logged(&d.0), vec![format!("check approve-unsynced hash={} outcome=the sync of {} returned OS error 5", h(1), path(&d.0).display())], "stood={stood}");
            assert_eq!(index(&d.0).unwrap().hashes, vec![h(1)]);
            assert_eq!(store_lines(&d.0), usize::from(stood) + 1, "stood={stood}");
        }
    }

    /// A commit whose step 0 stops: an entry stands at the path, one the store
    /// vouches for or not, and `steps` fails a read or the removal. Nothing is
    /// written, and the entry, the staged file and the store are as they were.
    fn step_0_stops_at(steps: &Driven, vouched: bool, failure: Failure) {
        let d = scratch();
        if vouched {
            append(&d.0, &h(1), &rec(1)).unwrap();
        }
        let entry = stand(&d.0, 1, "the entry at the path");
        let before = ino(&entry);
        let (staged, _) = stage(&d.0, 1, "the entry B wrote");
        let (hash, r) = (h(1), rec(1));
        let mut err = Vec::new();
        let answer = commit_with(&d.0, &approval(1, &staged, &entry, &r, &hash), LOCK_WAIT, steps, &mut err);
        assert_eq!(answer, Answer::NotApproved(failure, Entry::Untouched), "vouched={vouched}");
        let calls = steps.calls();
        for write in ["removal-line", "sync-dir", "append", "approve-line", "rename", "other-line"] {
            assert!(!calls.contains(&write), "vouched={vouched}: {write} ran after step 0 stopped: {calls:?}");
        }
        assert_eq!(ino(&entry), before, "vouched={vouched}: the entry at the path changed");
        assert!(staged.exists(), "vouched={vouched}");
        assert_eq!(store_lines(&d.0), usize::from(vouched), "vouched={vouched}");
        assert!(logged(&d.0).is_empty(), "vouched={vouched}");
        assert!(!err.is_empty(), "vouched={vouched}: the commit did not say why it stopped");
    }

    #[test]
    fn a_path_that_cannot_be_read_stops_the_commit_before_it_writes() {
        for vouched in [false, true] {
            step_0_stops_at(&driven("lstat", 13), vouched, Failure::LedgerWrite);
        }
    }

    #[test]
    fn a_store_that_cannot_be_read_stops_the_commit_before_it_writes() {
        for vouched in [false, true] {
            step_0_stops_at(&driven("read", 5), vouched, Failure::Store);
        }
    }

    #[test]
    fn an_entry_the_store_does_not_vouch_for_that_cannot_be_removed_stops_the_commit() {
        step_0_stops_at(&driven("unlink", 1), false, Failure::LedgerWrite);
    }

    #[test]
    fn an_unlink_that_failed_stops_the_commit_whatever_a_later_read_of_the_path_says() {
        // The unlink fails, and a read of the path after it finds nothing, as
        // where another writer removed the entry meanwhile. Only the unlink's
        // own answer says whether this commit removed an entry.
        let steps = Driven { gone_after_unlink: true, ..driven("unlink", 5) };
        step_0_stops_at(&steps, false, Failure::LedgerWrite);
        assert_eq!(steps.calls(), vec!["lstat", "read", "unlink"]);
    }

    #[test]
    fn a_removal_whose_line_or_sync_fails_stops_the_commit_and_answers_removed() {
        for (step, code) in [("removal-line", 13), ("sync-dir", 5)] {
            let d = scratch();
            let entry = stand(&d.0, 1, "an entry no check approved");
            let (staged, _) = stage(&d.0, 1, "the entry B wrote");
            let (hash, r) = (h(1), rec(1));
            let steps = driven(step, code);
            let mut err = Vec::new();
            let answer = commit_with(&d.0, &approval(1, &staged, &entry, &r, &hash), LOCK_WAIT, &steps, &mut err);
            assert_eq!(answer, Answer::NotApproved(Failure::LedgerWrite, Entry::Removed), "{step}");
            assert_eq!(steps.calls().last(), Some(&step), "{step}: a step ran after the one that failed");
            assert!(nothing_at(&entry) && staged.exists(), "{step}");
            assert_eq!(store_lines(&d.0), 0, "{step}");
            let removed = if step == "sync-dir" { vec![removal(&entry)] } else { Vec::new() };
            assert_eq!(logged(&d.0), removed, "{step}");
            assert!(String::from_utf8(err).unwrap().contains("was removed"), "{step}");
        }
    }

    #[test]
    fn a_commit_over_an_entry_the_store_vouches_for_replaces_it_and_removes_nothing() {
        let d = scratch();
        let (entry, _) = start(&d.0, true);
        let (staged, _) = stage(&d.0, 1, "the entry B wrote");
        let staged_ino = ino(&staged);
        let (hash, r) = (h(1), rec(1));
        let steps = driven("", 0);
        let mut err = Vec::new();
        assert_eq!(commit_with(&d.0, &approval(1, &staged, &entry, &r, &hash), LOCK_WAIT, &steps, &mut err), Answer::Approved);
        assert!(!steps.calls().contains(&"unlink"), "the commit removed an entry the store vouches for");
        assert_eq!(ino(&entry), staged_ino);
        assert_eq!(fs::read_to_string(&entry).unwrap(), "the entry B wrote");
        assert_eq!(logged(&d.0), vec![record(1)]);
        assert_eq!(store_lines(&d.0), 2);
    }

    #[test]
    fn a_commit_over_an_entry_the_store_does_not_vouch_for_removes_it_says_so_and_commits() {
        // The real steps, the sync of the ledger directory among them, on the
        // file system this test runs on.
        let d = scratch();
        let entry = stand(&d.0, 1, "an entry no check approved");
        let (staged, _) = stage(&d.0, 1, "the entry B wrote");
        let staged_ino = ino(&staged);
        let (hash, r) = (h(1), rec(1));
        let mut err = Vec::new();
        assert_eq!(commit(&d.0, &approval(1, &staged, &entry, &r, &hash), &mut err), Answer::Approved);
        assert!(err.is_empty(), "{}", String::from_utf8_lossy(&err));
        assert_eq!(ino(&entry), staged_ino);
        assert_eq!(logged(&d.0), vec![removal(&entry), record(1)]);
        assert_eq!(index(&d.0).unwrap().hashes, vec![h(1)]);
    }

    #[test]
    fn commits_of_one_hash_never_overlap_and_a_failed_one_leaves_the_next_whole() {
        // A holds the lock and fails at its store line; B commits the same
        // hash meanwhile. B waits, writes nothing until A is done, and its
        // records stand at the end.
        let d = scratch();
        let (staged_a, entry) = stage(&d.0, 1, "entry of A");
        let (staged_b, _) = stage(&d.0, 1, "entry of B");
        let (hash, r) = (h(1), rec(1));
        let (in_a, a_done) = (Barrier::new(2), AtomicBool::new(false));
        let hold = |step: &'static str| {
            if step == "append" {
                in_a.wait();
                std::thread::sleep(Duration::from_millis(300));
                assert!(staged_b.exists() && nothing_at(&entry), "B put its entry in place inside A's commit");
                assert!(logged(&d.0).is_empty(), "B wrote its approve line inside A's commit");
                a_done.store(true, Ordering::SeqCst);
            }
        };
        std::thread::scope(|s| {
            let b = s.spawn(|| {
                in_a.wait();
                let answer = commit(&d.0, &approval(1, &staged_b, &entry, &r, &hash), &mut Vec::new());
                assert!(a_done.load(Ordering::SeqCst), "B committed while A held the lock");
                answer
            });
            let mut steps = driven("append", 27);
            steps.before = Some(&hold as &dyn Fn(&'static str));
            let answer = commit_with(&d.0, &approval(1, &staged_a, &entry, &r, &hash), LOCK_WAIT, &steps, &mut Vec::new());
            assert_eq!(answer, Answer::NotApproved(Failure::Store, Entry::Untouched));
            assert_eq!(b.join().unwrap(), Answer::Approved);
        });
        assert_eq!(fs::read_to_string(&entry).unwrap(), "entry of B");
        assert!(staged_a.exists(), "A's commit removed its staged entry");
        assert_eq!(index(&d.0).unwrap().hashes, vec![h(1)]);
        assert_eq!(store_lines(&d.0), 1);
        assert_eq!(logged(&d.0), vec![record(1)]);
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
            let steps = driven(if torn { "torn" } else { "append" }, 27);
            let mut err = Vec::new();
            let answer = commit_with(&d.0, &approval(1, &staged, &entry, &r, &hash), LOCK_WAIT, &steps, &mut err);
            let err = String::from_utf8(err).unwrap();
            assert!(err.starts_with(&format!("safedeps-core approvals: not written to {}: ", path(&d.0).display())), "{err}");
            assert_eq!(answer, Answer::NotApproved(Failure::Store, Entry::Untouched), "vouched={vouched} torn={torn}");
            assert!(nothing_at(&entry) && staged.exists(), "vouched={vouched} torn={torn}");
            assert!(logged(&d.0).is_empty(), "vouched={vouched} torn={torn}: a line was written after the store line failed");
            let ix = index(&d.0).unwrap();
            assert_eq!(ix.hashes, if vouched { vec![h(1)] } else { Vec::new() });
            assert_eq!(ix.broken, usize::from(torn));
        }
    }

    #[test]
    fn a_rename_that_fails_puts_nothing_in_place_after_the_store_line_and_the_approve_line() {
        for stood in [false, true] {
            let d = scratch();
            let (entry, was) = start(&d.0, stood);
            let (staged, _) = stage(&d.0, 1, "the entry B wrote");
            fs::remove_file(&staged).unwrap();
            let (hash, r) = (h(1), rec(1));
            let mut err = Vec::new();
            let answer = commit(&d.0, &approval(1, &staged, &entry, &r, &hash), &mut err);
            assert_eq!(answer, Answer::NotApproved(Failure::LedgerWrite, Entry::Untouched), "stood={stood}");
            assert!(as_it_was(&entry, was), "stood={stood}: the path does not hold what it held");
            assert_eq!(logged(&d.0), vec![record(1), format!("check approve-undone hash={} outcome=the rename to {} returned OS error 2", h(1), entry.display())], "stood={stood}");
            assert_eq!(store_lines(&d.0), usize::from(stood) + 1, "stood={stood}");
            assert!(String::from_utf8(err).unwrap().contains("could not be put in place"), "stood={stood}");
        }
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
        let held = holder(&d.0);
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
        // B holds the lock inside its commit, its store line written, and
        // fails at its approve line. A revoke of the entry A approved waits
        // for B, then puts its entry in place: B put nothing there.
        let d = scratch();
        let (entry, _) = start(&d.0, true);
        let (staged_b, _) = stage(&d.0, 1, "the entry B wrote");
        let (hash, r) = (h(1), rec(1));
        let (in_b, b_done) = (Barrier::new(2), AtomicBool::new(false));
        let hold = |step: &'static str| {
            if step == "approve-line" {
                in_b.wait();
                std::thread::sleep(Duration::from_millis(300));
                assert_eq!(fs::read_to_string(&entry).unwrap(), "the entry A approved", "the revoke put its entry in place inside B's commit");
                b_done.store(true, Ordering::SeqCst);
            }
        };
        std::thread::scope(|s| {
            let revoker = s.spawn(|| {
                in_b.wait();
                let (seen, staged) = seen_and_staged(&d.0, 1, &entry, "the entry A approved, revoked");
                let answer = revoke(&d.0, &revocation(1, &hash, &staged, &entry, &seen), &mut Vec::new());
                assert!(b_done.load(Ordering::SeqCst), "the revoke ran while B held the lock");
                answer
            });
            let mut steps = driven("approve-line", 13);
            steps.before = Some(&hold as &dyn Fn(&'static str));
            let answer = commit_with(&d.0, &approval(1, &staged_b, &entry, &r, &hash), LOCK_WAIT, &steps, &mut Vec::new());
            assert_eq!(answer, Answer::NotApproved(Failure::LedgerWrite, Entry::Untouched));
            assert_eq!(revoker.join().unwrap(), Revoked::Revoked);
        });
        assert_eq!(fs::read_to_string(&entry).unwrap(), "the entry A approved, revoked");
        assert!(staged_b.exists(), "B's commit removed its staged entry");
    }

    #[test]
    fn a_commit_waits_for_a_revoke_and_a_failed_one_leaves_the_revoked_entry_as_it_is() {
        // A revoke holds the lock and is about to put its entry in place. B
        // commits the same entry meanwhile: B waits, then fails at its store
        // line, and the revoked entry stays as the revoke left it.
        let d = scratch();
        let (entry, _) = start(&d.0, true);
        let (seen, staged) = seen_and_staged(&d.0, 1, &entry, "the entry A approved, revoked");
        let revoked_ino = ino(&staged);
        let (staged_b, _) = stage(&d.0, 1, "the entry B wrote");
        let (hash, r) = (h(1), rec(1));
        let in_revoke = Barrier::new(2);
        std::thread::scope(|s| {
            let b = s.spawn(|| {
                in_revoke.wait();
                let steps = driven("append", 27);
                let answer = commit_with(&d.0, &approval(1, &staged_b, &entry, &r, &hash), LOCK_WAIT, &steps, &mut Vec::new());
                (answer, steps.calls())
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
            let (answer, calls) = b.join().unwrap();
            assert_eq!(answer, Answer::NotApproved(Failure::Store, Entry::Untouched));
            assert!(!calls.contains(&"unlink"), "B removed the revoked entry, which the store vouches for: {calls:?}");
        });
        assert_eq!(fs::read_to_string(&entry).unwrap(), "the entry A approved, revoked");
        assert_eq!(ino(&entry), revoked_ino, "the entry at the end is not the file the revoke put in place");
        assert!(staged_b.exists(), "B's commit removed its staged entry");
    }

    // ---- the command lines -----------------------------------------------------

    fn args(a: &[&str]) -> Vec<String> {
        a.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn the_commit_command_line() {
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
        // A store that cannot be opened: the answer names the store, nothing
        // is put in place, and the staged entry is left to the CLI.
        let d2 = scratch();
        fs::create_dir_all(path(&d2.0)).unwrap();
        let (staged2, entry2) = stage(&d2.0, 1, "entry of 1");
        let (code, out, _) = run(&d2.0, &args(&["commit", h1, staged2.to_str().unwrap(), entry2.to_str().unwrap()]), &input);
        assert_eq!((code, String::from_utf8(out).unwrap()), (1, "not-approved approvals_store_failed untouched\n".to_string()));
        assert!(staged2.exists() && !entry2.exists());
        // No command settles a commit: one that ended before it answered is
        // the CLI's to report.
        assert_eq!(run(&d.0, &args(&["settle", h1, e, "signal-9"]), b""), (2, Vec::new(), USAGE.as_bytes().to_vec()));
        assert!(!USAGE.contains("settle"));
        for bad in [&["commit", h1, s][..], &["commit"][..]] {
            assert_eq!(run(&d.0, &args(bad), b""), (2, Vec::new(), USAGE.as_bytes().to_vec()), "{bad:?}");
        }
    }

    #[test]
    fn the_commit_command_line_answers_removed() {
        // Step 0 removed an entry the store did not vouch for, and the line
        // that says so could not be written: the answer says the entry went.
        let d = scratch();
        let entry = stand(&d.0, 1, "an entry no check approved");
        let (staged, _) = stage(&d.0, 1, "the entry B wrote");
        fs::create_dir_all(d.0.join(ADVISORY_LOG)).unwrap();
        let mut input = rec(1);
        input.push(b'\n');
        let one = h(1);
        let (code, out, err) = run(&d.0, &args(&["commit", one.as_str(), staged.to_str().unwrap(), entry.to_str().unwrap()]), &input);
        assert_eq!((code, String::from_utf8(out).unwrap()), (1, "not-approved ledger_write_failed removed\n".to_string()));
        assert!(nothing_at(&entry) && staged.exists());
        assert_eq!(store_lines(&d.0), 0);
        assert!(String::from_utf8(err).unwrap().contains("was removed"));
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
        // No command writes a store line apart from a commit and a migration,
        // and neither takes the line from its arguments.
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
