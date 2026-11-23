//! The migration: approvals a check made before this store, moved into it
//! from advisory.log (`safedeps-core approvals migrate`).
//!
//! An approval made before the store has no line in it, so re-check calls
//! its ledger entry unvouched and the cache lookup checks it again. Its
//! record is its approve line in advisory.log, in the live file or in an
//! archive a rotation left. The migration reads those lines and gives the
//! store one line for each hash a ledger entry confirms: `via` is `migrate`,
//! and `at` and `record` are the approve line's own.
//!
//! The inputs: advisory.log in SAFEDEPS_HOME, then each archive named. Each
//! is read once, before the store lock is taken. An archive whose name ends
//! in `.gz` is read through `gzip -dc`, fed the bytes of that one read, and
//! its text is gzip's output only where gzip exited 0. Any other archive is
//! read as text. An input that cannot be read ends the run before the lock:
//! each one is named with what its read returned, and nothing is written.
//!
//! The lines. A finished line is `[<UTC time>] <text>`, as the CLI and the
//! core write advisory.log.
//!
//!   approve    `check approve(<kind>)` of a kind a check writes when it
//!              approved (clean, patched, clean closure, patched closure),
//!              then words, one of which, and only one, is `hash=<hash>`.
//!   cache      `check approve(cache)`. A check wrote it for an entry it met
//!              and did not check, so it is no approval: an entry no check
//!              approved gets one as easily as any. Counted, never moved.
//!   take-back  `check approve-undone` or `check approve-in-doubt`.
//!              Take-back lines read only the `hash=<valid hash>` word
//!              immediately following the keyword. Any remaining bytes on
//!              the line are left unread.
//!   broken     a line that holds `check approve(`, `check approve-undone`
//!              or `check approve-in-doubt` and is none of the three above.
//!              Counted, never moved.
//!   torn       an input's last line with no newline: a write that had not
//!              finished, or one that died, so its bytes can be anything.
//!              Counted, never moved, whatever it holds.
//!
//! Every other line is no concern of the migration.
//!
//! A take-back takes back each approve line of its hash that comes before
//! it: earlier in the same input, or stamped no later than it in any input.
//! The live file and an archive can hold the same lines, so only the times
//! order lines across inputs. A time has one-second grain, so a take-back
//! stamped in the second of an approve line takes it back.
//!
//! The judgment, one hash at a time, over its approve lines that nothing
//! took back:
//!
//!   - the store vouches for the hash: each line is a duplicate.
//!   - the ledger entry at the hash's path confirms it: the first of its
//!     lines by time is inserted, and the rest are duplicates.
//!   - otherwise each line is unconfirmed, and the hash is named with why:
//!     no entry at its path, what stands there is not one ledger entry, or
//!     the entry's fields give another hash.
//!
//! An entry confirms a hash when it is a regular file that holds one entry
//! `ledger::valid` reads, its own `hash` is that hash, and its fields give
//! that hash again (`ledger::recomputed`, as re-check recomputes it). An
//! entry that cannot be read ends the run, and nothing is written.
//!
//! The lock and the write are a commit's. From its read of the store to the
//! end of its write the migration holds the store lock, LOCK_EX, which every
//! commit and every revoke of an entry hold for their whole run. Under it the
//! store is read, each entry is read, and then every line goes into the store
//! in one `write_locked`: the seal of a torn last line, the lines, the sync.
//! So no commit or revoke changes an entry between its confirmation and its
//! line, and the line vouches for the entry that confirmed it. The migration
//! writes nothing else: no advisory.log line and no ledger entry. A run with
//! nothing to insert writes no byte. Its lock makes the store's file where
//! there was none, empty, as a commit's lock does.
//!
//! A run that fails. One that ends before its write wrote nothing, and says
//! so: an input that cannot be read, an entry that cannot be read, and a store
//! that cannot be opened, locked or read. Its write answers as a commit's
//! does, and for many lines the answers mean this:
//!
//!   written      every line is in the store, synced.
//!   unsynced     every line is in the store and a reader sees it, and the
//!                sync failed. All of them are inserted, none is left out,
//!                and nothing says they are on the disk.
//!   not written  the write stopped somewhere in its bytes. The lines before
//!                the stop are in the store whole, and a torn piece of the
//!                next can follow them, which the next write seals as one
//!                broken line. The answer does not say where it stopped, so
//!                the run reads the store again, under the same lock and
//!                through the same descriptor, and counts the hashes of its
//!                own lines the store vouches for. Those lines are inserted
//!                and the rest are not. The read before the write found none
//!                of those hashes vouched for, and every writer of the store
//!                holds the lock, so what the count finds is this run's lines.
//!                Where that read fails too, the run gives no count: inserted
//!                and not inserted are `unknown`, and the read's outcome is
//!                named.
//!
//! Why a read and not a sync for each line: a sync waits for the disk, and a
//! run moves a thousand lines or more while every commit waits for the lock,
//! for at most LOCK_WAIT while no line lands. One write and one sync keep the
//! lock as short as a run can.
//!
//! The counts. Every report that gives the approve lines gives the same five
//! counts, and they add up to the approve lines: inserted, not inserted,
//! duplicates, unconfirmed and taken back. A finished run gives its lines not
//! inserted too, 0, so a reader knows one sum, and a failed write brings it no
//! field a finished run did not. A run after a failed write inserts the lines
//! that were not inserted and counts the inserted ones as duplicates. The exit
//! of a failed write is 1 whatever it inserted: a run that inserted some of
//! its lines did not finish.
//!
//! Twice, and after a death. A run reads the lines an earlier run wrote as
//! the store vouching for their hashes, so a second run inserts nothing and
//! the store's bytes stay as they were. A run killed before its write leaves
//! the store as it was, and the lock goes with the process. One killed inside
//! its write leaves whole lines, which the next run counts as duplicates, and
//! a torn last line, which the next write seals as one broken line. So the
//! next run ends where a whole run ends: the store vouches for the same
//! hashes.

use super::{cat, is_hash, line, locked, observed, path, say, Appended, Fault, Real, Steps, Via, ADVISORY_LOG, LOCK_WAIT, RECORD_PREFIX, USAGE};
use crate::{
    jq, json, ledger, os,
    outcome::{Action, Form, Outcome},
};
use std::{
    collections::{HashMap, HashSet},
    fs,
    io::{self, Read, Write},
    os::unix::{ffi::OsStrExt, fs::OpenOptionsExt},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::Duration,
};

/// The kinds of approve line a check writes when it approved.
const APPROVED: [&[u8]; 4] = [b"clean", b"patched", b"clean closure", b"patched closure"];
/// The kind of a cache hit's approve line, which is no approval.
const CACHE: &[u8] = b"cache";
const UNDONE: &[u8] = b"check approve-undone";
const IN_DOUBT: &[u8] = b"check approve-in-doubt";
/// The name of an archive read through gzip ends in it.
const GZIP_SUFFIX: &[u8] = b".gz";
/// Where a line's text starts: after `[`, the 20 bytes of a time and `] `.
const TEXT_AT: usize = 23;

/// The two take-backs.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Back {
    Undone,
    InDoubt,
}

/// What one finished line is to the migration.
#[derive(Debug, Eq, PartialEq)]
enum Seen<'a> {
    Approve { at: &'a str, epoch: i64, hash: &'a str, record: &'a [u8] },
    Cache,
    Back { epoch: i64, hash: &'a str, by: Back },
    Broken,
    Other,
}

fn holds(text: &[u8], word: &[u8]) -> bool {
    text.windows(word.len()).any(|w| w == word)
}

/// A finished line, its newline taken off.
fn seen(l: &[u8]) -> Seen<'_> {
    if let Some(seen) = read_line(l) {
        seen
    } else if [RECORD_PREFIX, UNDONE, IN_DOUBT].iter().any(|w| holds(l, w)) {
        Seen::Broken
    } else {
        Seen::Other
    }
}

/// An approval's words or a take-back's header, or None.
fn read_line(l: &[u8]) -> Option<Seen<'_>> {
    if l.len() < TEXT_AT || l[0] != b'[' || &l[TEXT_AT - 2..TEXT_AT] != b"] " {
        return None;
    }
    let at = std::str::from_utf8(&l[1..TEXT_AT - 2]).ok()?;
    let epoch = ledger::epoch(at)?;
    let text = &l[TEXT_AT..];
    if let Some(rest) = text.strip_prefix(RECORD_PREFIX) {
        let close = rest.iter().position(|&b| b == b')')?;
        let (kind, words) = (&rest[..close], &rest[close + 1..]);
        if !word_ends(words) {
            return None;
        }
        if kind == CACHE {
            return Some(Seen::Cache);
        }
        if !APPROVED.contains(&kind) {
            return None;
        }
        return Some(Seen::Approve { at, epoch, hash: one_hash(words)?, record: text });
    }
    for (word, by) in [(UNDONE, Back::Undone), (IN_DOUBT, Back::InDoubt)] {
        if let Some(words) = text.strip_prefix(word) {
            if !word_ends(words) {
                return None;
            }
            return Some(Seen::Back { epoch, hash: first_hash(words)?, by });
        }
    }
    None
}

/// What follows a line's first word ends that word.
fn word_ends(rest: &[u8]) -> bool {
    rest.first().is_none_or(|&b| b == b' ')
}

/// The first word must be `hash=<hash>`; nothing after it is interpreted.
fn first_hash(words: &[u8]) -> Option<&str> {
    let word = words.split(|&b| b == b' ').find(|w| !w.is_empty())?;
    let hash = std::str::from_utf8(word.strip_prefix(b"hash=")?).ok()?;
    is_hash(hash).then_some(hash)
}

/// The one `hash=` word among `words`, where it is a hash.
fn one_hash(words: &[u8]) -> Option<&str> {
    let mut hashes = words.split(|&b| b == b' ').filter_map(|w| w.strip_prefix(b"hash="));
    let (Some(one), None) = (hashes.next(), hashes.next()) else {
        return None;
    };
    let hash = std::str::from_utf8(one).ok()?;
    is_hash(hash).then_some(hash)
}

/// One input's lines, counted by what they are.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(super) struct Counts {
    pub lines: usize,
    pub approve: usize,
    pub cache: usize,
    pub undone: usize,
    pub in_doubt: usize,
    pub broken: usize,
    pub torn: usize,
}

/// An approve line, and where it was read: the input and the line's place.
#[derive(Debug)]
struct Approve {
    at: String,
    epoch: i64,
    hash: String,
    record: Vec<u8>,
    input: usize,
    index: usize,
}

/// A take-back line, and where it was read.
#[derive(Debug)]
struct TakeBack {
    epoch: i64,
    hash: String,
    by: Back,
    input: usize,
    index: usize,
}

/// The lines of input `input`, its text read whole: counted, and its approve
/// and take-back lines kept.
fn take(input: usize, text: &[u8], approves: &mut Vec<Approve>, backs: &mut Vec<TakeBack>) -> Counts {
    let mut c = Counts::default();
    for (index, piece) in text.split_inclusive(|&b| b == b'\n').enumerate() {
        // Only the last piece can lack its newline.
        let Some(l) = piece.strip_suffix(b"\n") else {
            c.torn += 1;
            continue;
        };
        c.lines += 1;
        match seen(l) {
            Seen::Approve { at, epoch, hash, record } => {
                c.approve += 1;
                approves.push(Approve { at: at.to_string(), epoch, hash: hash.to_string(), record: record.to_vec(), input, index });
            }
            Seen::Back { epoch, hash, by } => {
                match by {
                    Back::Undone => c.undone += 1,
                    Back::InDoubt => c.in_doubt += 1,
                }
                backs.push(TakeBack { epoch, hash: hash.to_string(), by, input, index });
            }
            Seen::Cache => c.cache += 1,
            Seen::Broken => c.broken += 1,
            Seen::Other => {}
        }
    }
    c
}

/// Whether take-back `b` comes after approve line `a` of its hash: later in
/// the same input, or stamped no earlier in any input.
fn takes_back(b: &TakeBack, a: &Approve) -> bool {
    (b.input == a.input && b.index > a.index) || b.epoch >= a.epoch
}

/// The approve lines no take-back took back, one group a hash: the groups in
/// the order of their first line by time, and each group's lines in that
/// order. The lines taken back are counted in `report`.
fn standing(approves: Vec<Approve>, backs: &[TakeBack], report: &mut Report) -> Vec<(String, Vec<Approve>)> {
    let mut of: HashMap<&str, Vec<&TakeBack>> = HashMap::new();
    for b in backs {
        of.entry(b.hash.as_str()).or_default().push(b);
    }
    let mut groups: HashMap<String, Vec<Approve>> = HashMap::new();
    for a in approves {
        let taken = |by: Back| of.get(a.hash.as_str()).is_some_and(|bs| bs.iter().any(|b| b.by == by && takes_back(b, &a)));
        let gone = taken(Back::Undone) || taken(Back::InDoubt);
        if gone {
            report.taken_back += 1;
        } else {
            groups.entry(a.hash.clone()).or_default().push(a);
        }
    }
    let mut groups: Vec<(String, Vec<Approve>)> = groups.into_iter().collect();
    for (_, lines) in &mut groups {
        lines.sort_by(|x, y| (x.epoch, &x.record, x.input, x.index).cmp(&(y.epoch, &y.record, y.input, y.index)));
    }
    groups.sort_by(|(hx, x), (hy, y)| (x[0].epoch, hx).cmp(&(y[0].epoch, hy)));
    groups
}

/// Why an entry does not confirm a hash.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum Unconfirmed {
    /// Nothing stands at the hash's path.
    NoEntry,
    /// What stands there is not a regular file holding one ledger entry.
    NotAnEntry,
    /// The entry's fields, or its own `hash`, give another hash.
    OtherHash,
}

impl Unconfirmed {
    fn as_str(self) -> &'static str {
        match self {
            Self::NoEntry => "no_entry",
            Self::NotAnEntry => "not_an_entry",
            Self::OtherHash => "hash_mismatch",
        }
    }
    fn says(self) -> &'static str {
        match self {
            Self::NoEntry => "no ledger entry stands at its path",
            Self::NotAnEntry => "what stands at its path is not one ledger entry",
            Self::OtherHash => "the entry at its path gives another hash",
        }
    }
}

/// Whether the entry at `p` confirms `hash`: None where it does, or why it
/// does not. An entry that cannot be read is the error.
fn confirm(p: &Path, hash: &str) -> io::Result<Option<Unconfirmed>> {
    // A FIFO at the path is no entry, and an open of one must not wait for a
    // writer while the store lock is held.
    let mut file = match fs::OpenOptions::new().read(true).custom_flags(os::O_NONBLOCK).open(p) {
        Ok(f) => f,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Some(Unconfirmed::NoEntry)),
        Err(e) => return Err(e),
    };
    if !file.metadata()?.is_file() {
        return Ok(Some(Unconfirmed::NotAnEntry));
    }
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes)?;
    let Ok(v) = json::parse_one(&bytes) else {
        return Ok(Some(Unconfirmed::NotAnEntry));
    };
    Ok(match ledger::recomputed(&v) {
        None => Some(Unconfirmed::NotAnEntry),
        Some(h) if h == hash && v.get("hash").and_then(json::Value::as_str) == Some(hash) => None,
        Some(_) => Some(Unconfirmed::OtherHash),
    })
}

/// What a run read and what it did with each approve line. The first line of
/// a hash its entry confirmed is a line of the run's write, which the store
/// holds or does not (`inserted`). Each other approve line is a duplicate,
/// unconfirmed or taken back. Together they add up to `approve`.
#[derive(Debug, Default)]
pub(super) struct Report {
    pub inputs: Vec<(PathBuf, Counts)>,
    pub approve: usize,
    /// The lines of the run's write: one a hash its entry confirmed.
    pub batch: usize,
    /// How many of them the store holds.
    pub landed: Landed,
    pub duplicates: usize,
    pub unconfirmed: usize,
    pub taken_back: usize,
    pub unconfirmed_hashes: Vec<(String, Unconfirmed)>,
}

impl Report {
    /// The lines of the run's write the store holds, and those it does not.
    /// None where nobody counted them: there is no number to give.
    pub fn inserted(&self) -> Option<(usize, usize)> {
        match self.landed {
            Landed::All => Some((self.batch, 0)),
            Landed::Found(n) => Some((n, self.batch - n)),
            Landed::Unknown(_) => None,
        }
    }
}

/// How many of the lines of a run's write the store holds.
#[derive(Debug, Default)]
pub(super) enum Landed {
    /// All of them: the write answered written, or unsynced, which says every
    /// byte landed. A run that had no line to write made no write.
    #[default]
    All,
    /// The write answered not written, and the read of the store after it,
    /// under the same lock, found this many of them.
    Found(usize),
    /// The write answered not written, and the read after it failed as this
    /// says.
    Unknown(Fault),
}

/// Why a run did not finish.
#[derive(Debug)]
pub(super) enum Failed {
    /// Inputs that could not be read, each with what its read returned.
    /// Nothing was written.
    Inputs(Vec<(PathBuf, Fault)>),
    /// A ledger entry that could not be read, and what its read returned.
    /// Nothing was written.
    Entry(PathBuf, Fault),
    /// The store could not be opened, locked or read, before the write.
    /// Nothing was written.
    Store(Fault),
    /// The write answered not written. The lines before the byte where it
    /// stopped are in the store, and the report's `landed` says how many, or
    /// that the read that would count them failed.
    Write(Fault, Report),
    /// Every line is in the store and a reader sees it, and the sync failed.
    Unsynced(Outcome, Report),
}

impl Failed {
    fn as_str(&self) -> &'static str {
        match self {
            Self::Inputs(_) => "input_unreadable",
            Self::Entry(..) => "ledger_entry_unreadable",
            Self::Store(_) => "approvals_store_failed",
            Self::Write(..) => "approvals_store_write_failed",
            Self::Unsynced(..) => "approvals_store_unsynced",
        }
    }
}

/// An input's text: the bytes of one read, and for an archive named `.gz`
/// those bytes through gzip. Or what failed, as its outcome says it.
fn text_of(p: &Path, archive: bool) -> Result<Vec<u8>, Fault> {
    let bytes = observed(fs::read(p), p, |p| Action::Read(p))?;
    if archive && p.as_os_str().as_bytes().ends_with(GZIP_SUFFIX) {
        gunzip(bytes)
    } else {
        Ok(bytes)
    }
}

/// `gzip -dc` fed `bytes`: its output, where it exited 0.
fn gunzip(bytes: Vec<u8>) -> Result<Vec<u8>, Fault> {
    let failed = Fault::Gzip;
    let mut child = Command::new("gzip")
        .arg("-dc")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| failed(Outcome::StartFailure(e)))?;
    let (Some(mut stdin), Some(mut stdout)) = (child.stdin.take(), child.stdout.take()) else {
        let _ = child.kill();
        let _ = child.wait();
        return Err(Fault::Judgment(b"gzip's pipes were not made"));
    };
    // The feed runs beside the read, so neither waits on a full pipe.
    let feed = std::thread::spawn(move || stdin.write_all(&bytes));
    let mut out = Vec::new();
    let read = stdout.read_to_end(&mut out);
    drop(stdout);
    let status = child.wait();
    let fed = feed.join();
    let status = status.map_err(|e| failed(Outcome::StatusFailure(e)))?;
    if !status.success() {
        return Err(failed(Outcome::status(status)));
    }
    let fed = fed.map_err(|_| Fault::Judgment(b"the feed of gzip ended without an answer"))?;
    read.and(fed).map_err(|e| failed(Outcome::Io(Err(e))))?;
    Ok(out)
}

/// Moves into the store in `home` the approvals of advisory.log there and of
/// `archives` that the entries in `ledger_dir` confirm.
pub(super) fn migrate(home: &Path, ledger_dir: &Path, archives: &[PathBuf]) -> Result<Report, Failed> {
    migrate_within(home, ledger_dir, archives, LOCK_WAIT, &Real)
}

/// The migration, its store reads and its write made through `steps`, a
/// commit's steps: `Real`, or a test's that fails one.
fn migrate_within(home: &Path, ledger_dir: &Path, archives: &[PathBuf], wait: Duration, steps: &dyn Steps) -> Result<Report, Failed> {
    let mut report = Report::default();
    let (mut approves, mut backs, mut unreadable) = (Vec::new(), Vec::new(), Vec::new());
    // The inputs, each read once, before the lock.
    let inputs = std::iter::once((home.join(ADVISORY_LOG), false)).chain(archives.iter().map(|a| (a.clone(), true)));
    for (i, (p, archive)) in inputs.enumerate() {
        match text_of(&p, archive) {
            Ok(text) => {
                let counts = take(i, &text, &mut approves, &mut backs);
                report.inputs.push((p, counts));
            }
            Err(why) => unreadable.push((p, why)),
        }
    }
    if !unreadable.is_empty() {
        return Err(Failed::Inputs(unreadable));
    }
    report.approve = approves.len();
    let standing = standing(approves, &backs, &mut report);
    // From here to the end the store lock is held. It goes with `file`.
    let file = locked(home, wait).map_err(Failed::Store)?;
    let vouched: HashSet<String> = steps.read(&file, &path(home)).map_err(Failed::Store)?.hashes.into_iter().collect();
    let mut batch = Vec::new();
    // The hashes of the lines in `batch`, none of which the store vouches for.
    let mut ours = HashSet::new();
    for (hash, lines) in &standing {
        if vouched.contains(hash) {
            report.duplicates += lines.len();
            continue;
        }
        let entry = ledger_dir.join(ledger::filename(hash));
        match confirm(&entry, hash) {
            Err(e) => {
                let why = Fault::operation(Outcome::Io(Err(e)), &entry, |p| Action::Read(p));
                return Err(Failed::Entry(entry, why));
            }
            Ok(Some(why)) => {
                report.unconfirmed += lines.len();
                report.unconfirmed_hashes.push((hash.clone(), why));
            }
            Ok(None) => {
                let first = &lines[0];
                batch.extend(line(&first.at, hash, Via::Migrate, &first.record));
                ours.insert(hash.as_str());
                report.batch += 1;
                report.duplicates += lines.len() - 1;
            }
        }
    }
    if !batch.is_empty() {
        match steps.append(&file, &path(home), &batch) {
            Ok(()) => {}
            Err(Appended::Unsynced(e)) => return Err(Failed::Unsynced(e, report)),
            Err(Appended::NotWritten(e)) => {
                // Where the write stopped is not in its answer. A read of the
                // store under the same lock, through the same descriptor,
                // says which of the run's lines landed whole.
                report.landed = match steps.read(&file, &path(home)) {
                    Ok(ix) => Landed::Found(ix.hashes.iter().filter(|h| ours.contains(h.as_str())).count()),
                    Err(r) => Landed::Unknown(r),
                };
                return Err(Failed::Write(e, report));
            }
        }
    }
    Ok(report)
}

fn count(n: usize) -> jq::J {
    jq::J::Num(n.to_string())
}

fn named(p: &Path) -> jq::J {
    jq::arg(p.as_os_str().as_bytes())
}

/// The word a count gives where nobody counted.
const UNKNOWN: &str = "unknown";

/// A run's report as one JSON object. `failed` is None for a finished run, or
/// the failure of its write and what the write returned. Every report gives
/// `not_inserted` beside `inserted`, 0 for a finished run, and a count nobody
/// made is `unknown`.
fn report_json(store: &Path, r: &Report, failed: Option<(&Failed, &[u8])>) -> jq::J {
    let total = |f: fn(&Counts) -> usize| count(r.inputs.iter().map(|(_, c)| f(c)).sum());
    let inputs = r.inputs.iter().map(|(p, c)| {
        jq::obj(vec![
            ("path", named(p)),
            ("lines", count(c.lines)),
            ("approve", count(c.approve)),
            ("cache", count(c.cache)),
            ("undone", count(c.undone)),
            ("in_doubt", count(c.in_doubt)),
            ("broken", count(c.broken)),
            ("torn", count(c.torn)),
        ])
    });
    let unconfirmed = r.unconfirmed_hashes.iter().map(|(h, why)| jq::obj(vec![("hash", jq::s(h)), ("reason", jq::s(why.as_str()))]));
    let mut fields = vec![
        ("command", jq::s("approvals migrate")),
        ("store", named(store)),
        ("inputs", jq::J::Arr(inputs.collect())),
        ("approve_lines", count(r.approve)),
    ];
    match r.inserted() {
        Some((n, left)) => fields.extend([("inserted", count(n)), ("not_inserted", count(left))]),
        None => fields.extend([("inserted", jq::s(UNKNOWN)), ("not_inserted", jq::s(UNKNOWN))]),
    }
    fields.extend([
        ("duplicates", count(r.duplicates)),
        ("unconfirmed", count(r.unconfirmed)),
        ("taken_back", count(r.taken_back)),
        ("cache", total(|c| c.cache)),
        ("broken", total(|c| c.broken)),
        ("torn", total(|c| c.torn)),
        ("unconfirmed_hashes", jq::J::Arr(unconfirmed.collect())),
    ]);
    match failed {
        None => fields.push(("error", jq::J::Null)),
        Some((f, e)) => {
            fields.extend([("error", jq::s(f.as_str())), ("outcome", jq::arg(e))]);
            if let Landed::Unknown(read) = &r.landed {
                fields.push(("reread_outcome", jq::arg(&read.text())));
            }
        }
    }
    jq::obj(fields)
}

/// A failed run as one JSON object. A failed write gives its report with the
/// failure. A run that failed before its write made no write, so it inserted
/// no line: it gives its failure, `inserted` 0, and what failed.
fn failed_json(store: &Path, f: &Failed) -> jq::J {
    let before = |what: (&'static str, jq::J)| {
        jq::obj(vec![("command", jq::s("approvals migrate")), ("store", named(store)), ("error", jq::s(f.as_str())), ("inserted", count(0)), what])
    };
    match f {
        Failed::Write(e, r) => report_json(store, r, Some((f, &e.text()))),
        Failed::Unsynced(e, r) => report_json(store, r, Some((f, &e.describe(Action::Sync(store), Form::Action)))),
        Failed::Inputs(list) => {
            let list = list.iter().map(|(p, why)| jq::obj(vec![("path", named(p)), ("outcome", jq::arg(&why.text()))]));
            before(("unreadable", jq::J::Arr(list.collect())))
        }
        Failed::Entry(p, why) => before(("entry", jq::obj(vec![("path", named(p)), ("outcome", jq::arg(&why.text()))]))),
        Failed::Store(e) => before(("outcome", jq::arg(&e.text()))),
    }
}

/// A run's report as the lines a person reads. Its counts are the five the
/// JSON gives, the lines not inserted among them, 0 for a finished run.
fn report_text(store: &Path, r: &Report) -> Vec<u8> {
    let mut out = Vec::new();
    let mut say = |parts: &[&[u8]]| {
        for p in parts {
            out.extend_from_slice(p);
        }
        out.push(b'\n');
    };
    say(&[b"approvals migrate: ", store.as_os_str().as_bytes()]);
    for (p, c) in &r.inputs {
        let counts = format!(
            ": {} lines: {} approve, {} cache, {} undone, {} in-doubt, {} broken, {} torn",
            c.lines, c.approve, c.cache, c.undone, c.in_doubt, c.broken, c.torn
        );
        say(&[b"  read ", p.as_os_str().as_bytes(), counts.as_bytes()]);
    }
    let inserted = match r.inserted() {
        Some((n, left)) => format!("{n} inserted, {left} not inserted"),
        None => format!("inserted {UNKNOWN}, not inserted {UNKNOWN}"),
    };
    let lines = format!(
        "  {} approve lines: {inserted}, {} duplicates, {} unconfirmed, {} taken back",
        r.approve, r.duplicates, r.unconfirmed, r.taken_back
    );
    say(&[lines.as_bytes()]);
    for (h, why) in &r.unconfirmed_hashes {
        say(&[format!("  unconfirmed {h}: {}", why.says()).as_bytes()]);
    }
    out
}

/// What failed, as the lines a person reads on stderr. A run that failed
/// before its write says nothing was written. A failed write says how many of
/// its lines are in the store and how many are not, and that a run after it
/// puts the rest in.
fn failed_text(store: &Path, f: &Failed) -> Vec<u8> {
    let mut err = Vec::new();
    const SAYS: &[u8] = b"safedeps-core approvals: ";
    const NOT: &[u8] = b"safedeps-core approvals: not migrated: ";
    const AGAIN: &[u8] = b"safedeps-core approvals: run it again: it inserts the lines that are not in the store and counts the lines that are as duplicates";
    let s = store.as_os_str().as_bytes();
    match f {
        Failed::Inputs(list) => {
            for (p, why) in list {
                why.report(&mut err, &cat(&[NOT, p.as_os_str().as_bytes(), b" could not be read: "]), b"");
            }
            let n = list.len();
            say(&mut err, &cat(&[NOT, format!("{n} input{} could not be read, so nothing was written", if n == 1 { "" } else { "s" }).as_bytes()]));
        }
        Failed::Entry(p, why) => why.report(&mut err,
            &cat(&[NOT, b"the ledger entry ", p.as_os_str().as_bytes(), b" could not be read ("]), b"), so nothing was written"),
        Failed::Store(e) => e.report(&mut err,
            &cat(&[NOT, s, b" could not be opened, locked or read ("]), b"), so nothing was written"),
        Failed::Write(e, r) => {
            e.report(&mut err, &cat(&[SAYS, b"not migrated in full: the write to ", s, b" failed ("]), b")");
            if let Landed::Unknown(read) = &r.landed {
                read.report(&mut err, &cat(&[SAYS,
                    format!("how many of the run's {} store lines are in the store is not known: ", r.batch).as_bytes()]), b"");
            } else if let Some((n, left)) = r.inserted() {
                say(&mut err, &cat(&[SAYS, format!("{n} of the run's {} store lines are in the store and {left} are not", r.batch).as_bytes()]));
            }
            say(&mut err, AGAIN);
        }
        Failed::Unsynced(e, r) => {
            say(&mut err, &cat(&[
                format!("safedeps: unsynced: all {} store lines of the run are in ", r.batch).as_bytes(),
                s, b", none is left out, and the sync failed (",
                &Outcome::describe(e, Action::Sync(store), Form::Action),
                b"). A reader sees them, and nothing says they are on the disk.",
            ]));
            say(&mut err, AGAIN);
        }
    }
    err
}

/// The command's arguments: whether `--json` came before the archives, and
/// the archives. `--` ends the options, and so does the first word that is
/// not one. None for an option that is not one.
fn options<'a, 'b>(args: &'a [&'b str]) -> Option<(bool, &'a [&'b str])> {
    let mut json = false;
    for (at, &a) in args.iter().enumerate() {
        match a {
            "--json" => json = true,
            "--" => return Some((json, &args[at + 1..])),
            _ if a.starts_with('-') => return None,
            _ => return Some((json, &args[at..])),
        }
    }
    Some((json, &[]))
}

/// `safedeps-core approvals migrate [--json] [--] [<archive>...]`: exit 0 and
/// the report on stdout; exit 1 and what failed on stderr, and on stdout the
/// report where the run wrote, or with `--json` the failure; exit 2 for an
/// argument that is not one, and nothing is read.
pub(super) fn command(home: &Path, ledger_dir: &Path, args: &[&str]) -> (i32, Vec<u8>, Vec<u8>) {
    let Some((json, archives)) = options(args) else {
        return (2, Vec::new(), USAGE.as_bytes().to_vec());
    };
    let archives: Vec<PathBuf> = archives.iter().map(PathBuf::from).collect();
    answer(&path(home), json, &migrate(home, ledger_dir, &archives))
}

/// A run's result as the command gives it: exit status, stdout and stderr.
/// A failed write is a failure, exit 1, whatever it inserted.
fn answer(store: &Path, json: bool, result: &Result<Report, Failed>) -> (i32, Vec<u8>, Vec<u8>) {
    let shown = |j: jq::J| {
        let mut o = jq::compact(&j).into_bytes();
        o.push(b'\n');
        o
    };
    match result {
        Ok(r) => (0, if json { shown(report_json(store, r, None)) } else { report_text(store, r) }, Vec::new()),
        Err(f) => {
            let out = match (f, json) {
                (_, true) => shown(failed_json(store, f)),
                (Failed::Write(_, r) | Failed::Unsynced(_, r), false) => report_text(store, r),
                (_, false) => Vec::new(),
            };
            (1, out, failed_text(store, f))
        }
    }
}

#[cfg(test)]
mod tests;
