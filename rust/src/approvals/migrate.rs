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
//!   take-back  `check approve-undone` or `check approve-in-doubt`, then
//!              words, one of which, and only one, is `hash=<hash>`.
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
//! store is read once, each entry is read, and then every line goes into the
//! store in one `write_locked`: the seal of a torn last line, the lines, the
//! sync. So no commit or revoke changes an entry between its confirmation and
//! its line, and the line vouches for the entry that confirmed it. The
//! migration writes nothing else: no advisory.log line and no ledger entry. A
//! run with nothing to insert writes no byte. Its lock makes the store's file
//! where there was none, empty, as a commit's lock does.
//!
//! Twice, and after a death. A run reads the lines an earlier run wrote as
//! the store vouching for their hashes, so a second run inserts nothing and
//! the store's bytes stay as they were. A run killed before its write leaves
//! the store as it was, and the lock goes with the process. One killed inside
//! its write leaves whole lines, which the next run counts as duplicates, and
//! a torn last line, which the next write seals as one broken line. So the
//! next run ends where a whole run ends: the store vouches for the same
//! hashes.

use super::{is_hash, line, locked, outcome, path, read_locked, write_locked, Appended, Via, ADVISORY_LOG, LOCK_WAIT, RECORD_PREFIX, USAGE};
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
    if [RECORD_PREFIX, UNDONE, IN_DOUBT].iter().any(|w| holds(l, w)) {
        read_line(l).unwrap_or(Seen::Broken)
    } else {
        Seen::Other
    }
}

/// A line that names an approval or a take-back, read whole, or None.
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
            return Some(Seen::Back { epoch, hash: one_hash(words)?, by });
        }
    }
    None
}

/// What follows a line's first word ends that word.
fn word_ends(rest: &[u8]) -> bool {
    rest.first().is_none_or(|&b| b == b' ')
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

/// What a run read and what it did with each approve line: inserted,
/// duplicates, unconfirmed and taken back add up to `approve`.
#[derive(Debug, Default, Eq, PartialEq)]
pub(super) struct Report {
    pub inputs: Vec<(PathBuf, Counts)>,
    pub approve: usize,
    pub inserted: usize,
    pub duplicates: usize,
    pub unconfirmed: usize,
    pub taken_back: usize,
    pub unconfirmed_hashes: Vec<(String, Unconfirmed)>,
}

/// Why a run did not finish.
#[derive(Debug)]
pub(super) enum Failed {
    /// Inputs that could not be read, each with what its read returned.
    /// Nothing was written.
    Inputs(Vec<(PathBuf, Vec<u8>)>),
    /// A ledger entry that could not be read, and what its read returned.
    /// Nothing was written.
    Entry(PathBuf, Vec<u8>),
    /// The store could not be opened, locked or read, or it did not take the
    /// lines: none of them is in it, or a torn piece of them is, which the
    /// next write seals as one broken line.
    Store(io::Error),
    /// Every line is in the store and a reader sees it, and the sync failed.
    Unsynced(io::Error, Report),
}

impl Failed {
    fn as_str(&self) -> &'static str {
        match self {
            Self::Inputs(_) => "input_unreadable",
            Self::Entry(..) => "ledger_entry_unreadable",
            Self::Store(_) => "approvals_store_failed",
            Self::Unsynced(..) => "approvals_store_unsynced",
        }
    }
}

/// An input's text: the bytes of one read, and for an archive named `.gz`
/// those bytes through gzip. Or what failed, as its outcome says it.
fn text_of(p: &Path, archive: bool) -> Result<Vec<u8>, Vec<u8>> {
    let bytes = fs::read(p).map_err(|e| Outcome::Io(Err(e)).describe(Action::Read(p), Form::Action))?;
    if archive && p.as_os_str().as_bytes().ends_with(GZIP_SUFFIX) {
        gunzip(bytes)
    } else {
        Ok(bytes)
    }
}

/// `gzip -dc` fed `bytes`: its output, where it exited 0.
fn gunzip(bytes: Vec<u8>) -> Result<Vec<u8>, Vec<u8>> {
    let said = |o: Outcome| o.describe(Action::Gzip, Form::Action);
    let mut child = Command::new("gzip")
        .arg("-dc")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| said(Outcome::StartFailure(e)))?;
    let (Some(mut stdin), Some(mut stdout)) = (child.stdin.take(), child.stdout.take()) else {
        let _ = child.kill();
        let _ = child.wait();
        return Err(said(Outcome::Io(Err(io::Error::other("gzip's pipes were not made")))));
    };
    // The feed runs beside the read, so neither waits on a full pipe.
    let feed = std::thread::spawn(move || stdin.write_all(&bytes));
    let mut out = Vec::new();
    let read = stdout.read_to_end(&mut out);
    drop(stdout);
    let status = child.wait();
    let fed = feed.join().unwrap_or_else(|_| Err(io::Error::other("the feed of gzip ended without an answer")));
    let status = status.map_err(|e| said(Outcome::StatusFailure(e)))?;
    if !status.success() {
        return Err(said(Outcome::status(status)));
    }
    read.and(fed).map_err(|e| said(Outcome::Io(Err(e))))?;
    Ok(out)
}

/// Moves into the store in `home` the approvals of advisory.log there and of
/// `archives` that the entries in `ledger_dir` confirm.
pub(super) fn migrate(home: &Path, ledger_dir: &Path, archives: &[PathBuf]) -> Result<Report, Failed> {
    migrate_within(home, ledger_dir, archives, LOCK_WAIT)
}

fn migrate_within(home: &Path, ledger_dir: &Path, archives: &[PathBuf], wait: Duration) -> Result<Report, Failed> {
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
    let vouched: HashSet<String> = read_locked(&file).map_err(Failed::Store)?.hashes.into_iter().collect();
    let mut batch = Vec::new();
    for (hash, lines) in &standing {
        if vouched.contains(hash) {
            report.duplicates += lines.len();
            continue;
        }
        let entry = ledger_dir.join(ledger::filename(hash));
        match confirm(&entry, hash) {
            Err(e) => {
                let why = Outcome::Io(Err(e)).describe(Action::Read(&entry), Form::Action);
                return Err(Failed::Entry(entry, why));
            }
            Ok(Some(why)) => {
                report.unconfirmed += lines.len();
                report.unconfirmed_hashes.push((hash.clone(), why));
            }
            Ok(None) => {
                let first = &lines[0];
                batch.extend(line(&first.at, hash, Via::Migrate, &first.record));
                report.inserted += 1;
                report.duplicates += lines.len() - 1;
            }
        }
    }
    if !batch.is_empty() {
        match write_locked(&file, &batch) {
            Ok(()) => {}
            Err(Appended::NotWritten(e)) => return Err(Failed::Store(e)),
            Err(Appended::Unsynced(e)) => return Err(Failed::Unsynced(e, report)),
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

/// A finished run as one JSON object. `error` is null, or the run's failure
/// where it wrote its lines and did not sync them.
fn report_json(store: &Path, r: &Report, error: Option<&Failed>) -> jq::J {
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
    jq::obj(vec![
        ("command", jq::s("approvals migrate")),
        ("store", named(store)),
        ("inputs", jq::J::Arr(inputs.collect())),
        ("approve_lines", count(r.approve)),
        ("inserted", count(r.inserted)),
        ("duplicates", count(r.duplicates)),
        ("unconfirmed", count(r.unconfirmed)),
        ("taken_back", count(r.taken_back)),
        ("cache", total(|c| c.cache)),
        ("broken", total(|c| c.broken)),
        ("torn", total(|c| c.torn)),
        ("unconfirmed_hashes", jq::J::Arr(unconfirmed.collect())),
        ("error", error.map_or(jq::J::Null, |f| jq::s(f.as_str()))),
    ])
}

/// A run that wrote nothing, as one JSON object: its failure and what failed.
fn failed_json(store: &Path, f: &Failed) -> jq::J {
    let mut fields = vec![("command", jq::s("approvals migrate")), ("store", named(store)), ("error", jq::s(f.as_str())), ("inserted", count(0))];
    match f {
        Failed::Inputs(list) => {
            let list = list.iter().map(|(p, why)| jq::obj(vec![("path", named(p)), ("outcome", jq::arg(why))]));
            fields.push(("unreadable", jq::J::Arr(list.collect())));
        }
        Failed::Entry(p, why) => fields.push(("entry", jq::obj(vec![("path", named(p)), ("outcome", jq::arg(why))]))),
        Failed::Store(e) => fields.push(("outcome", jq::s(&outcome(Err(e))))),
        Failed::Unsynced(..) => {}
    }
    jq::obj(fields)
}

/// A finished run as the lines a person reads.
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
    let lines = format!(
        "  {} approve lines: {} inserted, {} duplicates, {} unconfirmed, {} taken back",
        r.approve, r.inserted, r.duplicates, r.unconfirmed, r.taken_back
    );
    say(&[lines.as_bytes()]);
    for (h, why) in &r.unconfirmed_hashes {
        say(&[format!("  unconfirmed {h}: {}", why.says()).as_bytes()]);
    }
    out
}

/// What failed, as the lines a person reads on stderr.
fn failed_text(store: &Path, f: &Failed) -> Vec<u8> {
    let mut err = Vec::new();
    let mut say = |parts: &[&[u8]]| {
        for p in parts {
            err.extend_from_slice(p);
        }
        err.push(b'\n');
    };
    const NOT: &[u8] = b"safedeps-core approvals: not migrated: ";
    match f {
        Failed::Inputs(list) => {
            for (p, why) in list {
                say(&[NOT, p.as_os_str().as_bytes(), b" could not be read: ", why]);
            }
            let n = list.len();
            say(&[NOT, format!("{n} input{} could not be read, so nothing was written", if n == 1 { "" } else { "s" }).as_bytes()]);
        }
        Failed::Entry(p, why) => say(&[NOT, b"the ledger entry ", p.as_os_str().as_bytes(), b" could not be read (", why, b"), so nothing was written"]),
        Failed::Store(e) => say(&[NOT, store.as_os_str().as_bytes(), format!(" could not be opened, locked, read or written: {e}").as_bytes()]),
        Failed::Unsynced(e, r) => say(&[
            format!("safedeps: unsynced: {} lines were written to ", r.inserted).as_bytes(),
            store.as_os_str().as_bytes(),
            format!(" and not synced ({}). A reader sees them, and nothing says they are on the disk.", outcome(Err(e))).as_bytes(),
        ]),
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
/// report where the lines were written and not synced, or with `--json` the
/// failure; exit 2 for an argument that is not one, and nothing is read.
pub(super) fn command(home: &Path, ledger_dir: &Path, args: &[&str]) -> (i32, Vec<u8>, Vec<u8>) {
    let Some((json, archives)) = options(args) else {
        return (2, Vec::new(), USAGE.as_bytes().to_vec());
    };
    let archives: Vec<PathBuf> = archives.iter().map(PathBuf::from).collect();
    let store = path(home);
    let shown = |j: jq::J| {
        let mut o = jq::compact(&j).into_bytes();
        o.push(b'\n');
        o
    };
    match migrate(home, ledger_dir, &archives) {
        Ok(r) => (0, if json { shown(report_json(&store, &r, None)) } else { report_text(&store, &r) }, Vec::new()),
        Err(f) => {
            let out = match (&f, json) {
                (Failed::Unsynced(_, r), true) => shown(report_json(&store, r, Some(&f))),
                (Failed::Unsynced(_, r), false) => report_text(&store, r),
                (_, true) => shown(failed_json(&store, &f)),
                (_, false) => Vec::new(),
            };
            (1, out, failed_text(&store, &f))
        }
    }
}

#[cfg(test)]
mod tests;
