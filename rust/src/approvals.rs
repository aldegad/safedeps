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
//!   record  the approval's line as advisory.log has it, `check approve...`
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
//! write at once. Under the lock a writer first ends a torn last line, which
//! a process that died mid-write leaves behind, so its own line starts a line
//! and the torn one stays one broken line. It then appends its line in one
//! write and syncs it before it says the line is written. The lock belongs to
//! the open file and goes when the file is closed, so a process that dies
//! holding it leaves nothing to clean up. A lock another process holds past
//! LOCK_WAIT is an error: nothing is written or read without the lock.
//!
//! A line that is not one such object vouches for nothing: a torn line, a
//! broken one, one written by hand. Each is counted as broken in the answer,
//! so it is seen. A store that cannot be read is an error, never an empty
//! store. A store that is not there is an answer, `present: false`, and
//! vouches for nothing.

use crate::{
    jq,
    json::{self, Value},
    ledger, os, state,
};
use std::{
    collections::HashSet,
    fs,
    io::{self, Read, Write},
    os::unix::fs::{DirBuilderExt, FileExt, OpenOptionsExt},
    path::{Path, PathBuf},
    time::Duration,
};

pub const FILE_NAME: &str = "approvals.jsonl";
/// What every record in the store starts with. advisory.log writes an
/// approval with the same words, and a record that does not start with them
/// is no approval.
pub const RECORD_PREFIX: &[u8] = b"check approve";
const HASH_PREFIX: &str = "sha256:";
const FIELDS: [&str; 4] = ["at", "hash", "via", "record"];
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

/// Under LOCK_EX: ends a torn last line, then appends `lines` in one write
/// and syncs them.
fn write_locked(file: &fs::File, lines: &[u8]) -> io::Result<()> {
    let len = file.metadata()?.len();
    let mut out = Vec::with_capacity(lines.len() + 1);
    if len > 0 {
        let mut last = [0u8; 1];
        file.read_exact_at(&mut last, len - 1)?;
        if last[0] != b'\n' {
            out.push(b'\n');
        }
    }
    out.extend_from_slice(lines);
    let mut f: &fs::File = file;
    f.write_all(&out)?;
    file.sync_data()
}

/// Records one approval `safedeps check` made: the ledger entry `hash`, and
/// `record`, its approve line as advisory.log gets it. Ok only once the line
/// is in the store and synced.
pub fn append(dir: &Path, hash: &str, record: &[u8]) -> io::Result<()> {
    append_within(dir, hash, record, LOCK_WAIT)
}

fn append_within(dir: &Path, hash: &str, record: &[u8], wait: Duration) -> io::Result<()> {
    if !is_hash(hash) {
        return Err(invalid("the hash is not sha256: and 64 lowercase hex digits"));
    }
    if !record.starts_with(RECORD_PREFIX) {
        return Err(invalid("the record is not an approval (it does not start with `check approve`)"));
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
/// did not finish, and is broken like any other line that is not a record.
fn read(bytes: &[u8]) -> Index {
    let mut seen = HashSet::new();
    let mut hashes = Vec::new();
    let mut broken = 0;
    for piece in bytes.split_inclusive(|&b| b == b'\n') {
        match piece.strip_suffix(b"\n").and_then(approved_hash) {
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

const USAGE: &str = "usage: safedeps-core approvals append <hash> (the record on stdin) | index\n";

/// `safedeps-core approvals append <hash>`, the record on stdin (one
/// trailing newline is not part of it): exit 0 when the line is written, 1
/// when it is not, 2 for a hash or a record that is not one.
/// `safedeps-core approvals index`: the index on stdout and exit 0, or exit 1
/// when the store cannot be read.
pub fn cli(args: &[String]) -> i32 {
    os::set_umask(0o077);
    let mut stdin = Vec::new();
    if args.first().map(String::as_str) == Some("append") && io::stdin().read_to_end(&mut stdin).is_err() {
        eprintln!("safedeps-core approvals: not written: the record could not be read from stdin");
        return 1;
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
            match append(dir, hash, record) {
                Ok(()) => (0, Vec::new(), Vec::new()),
                Err(e) if e.kind() == io::ErrorKind::InvalidInput => {
                    (2, Vec::new(), format!("safedeps-core approvals: not written: {}\n", e).into_bytes())
                }
                Err(e) => (1, Vec::new(), format!("safedeps-core approvals: not written to {}: {}\n", store.display(), e).into_bytes()),
            }
        }
        ["index"] => match index(dir) {
            Ok(ix) => (0, format!("{}\n", index_json(&ix)).into_bytes(), Vec::new()),
            Err(e) => (1, Vec::new(), format!("safedeps-core approvals: {} could not be read: {}\n", store.display(), e).into_bytes()),
        },
        _ => (2, Vec::new(), USAGE.as_bytes().to_vec()),
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
    fn scratch() -> Dir {
        Dir(os::scratch_dir("safedeps-approvals-test").expect("a scratch directory"))
    }
    fn h(n: u8) -> String {
        format!("{}{}", HASH_PREFIX, format!("{:02x}", n).repeat(32))
    }
    fn rec(n: u8) -> Vec<u8> {
        format!("check approve(clean) ecosystem=npm package=p{} version=1.0.0 hash={}", n, h(n)).into_bytes()
    }
    fn holder(dir: &Path, lock: os::FileLock) -> fs::File {
        let f = fs::OpenOptions::new().read(true).append(true).create(true).mode(0o600).open(path(dir)).unwrap();
        os::flock_within(&f, lock, Duration::from_secs(1)).unwrap();
        f
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
        assert!(append(&d.0, &h(1), &rec(1)).is_err());
    }

    #[test]
    fn what_is_no_hash_or_no_approval_is_refused_and_writes_nothing() {
        let d = scratch();
        for (hash, record) in [
            ("sha256:".to_string() + &"A".repeat(64), rec(1)),
            ("sha256:".to_string() + &"0".repeat(63), rec(1)),
            ("md5:".to_string() + &"0".repeat(64), rec(1)),
            (String::new(), rec(1)),
            (h(1), b"check block ecosystem=npm package=p version=1".to_vec()),
            (h(1), Vec::new()),
        ] {
            let e = append(&d.0, &hash, &record).unwrap_err();
            assert_eq!(e.kind(), io::ErrorKind::InvalidInput, "{hash:?}");
        }
        assert!(!path(&d.0).exists());
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
        bytes.extend(ok(5, Via::Check));
        bytes.extend(&ok(14, Via::Check)[..20]);
        fs::write(path(&d.0), &bytes).unwrap();
        let ix = index(&d.0).unwrap();
        // Nine lines vouch for nothing: garbage, an empty line, an extra
        // field, a missing field, an uppercase hash, an unknown via, a time
        // that is no time, a record that is no approval and a torn tail. The
        // repeated h(5) is a record and counts once.
        assert_eq!(ix.hashes, vec![h(5), h(6), h(10)]);
        assert_eq!(ix.broken, 9);
        assert!(ix.present);
    }

    #[test]
    fn a_torn_last_line_stays_one_broken_line_and_the_next_append_starts_its_own() {
        let d = scratch();
        let whole = line("2026-11-19T08:00:00Z", &h(4), Via::Check, &rec(4));
        fs::write(path(&d.0), &whole[..30]).unwrap();
        assert_eq!(index(&d.0).unwrap(), Index { present: true, hashes: Vec::new(), broken: 1 });
        append(&d.0, &h(3), &rec(3)).unwrap();
        let bytes = fs::read(path(&d.0)).unwrap();
        assert_eq!(&bytes[..31], [&whole[..30], &b"\n"[..]].concat().as_slice());
        assert_eq!(index(&d.0).unwrap(), Index { present: true, hashes: vec![h(3)], broken: 1 });
    }

    #[test]
    fn concurrent_appends_each_land_as_one_whole_line() {
        let d = scratch();
        let threads: Vec<_> = (0..8u8)
            .map(|t| {
                let dir = d.0.clone();
                std::thread::spawn(move || {
                    for k in 0..25u8 {
                        let n = t * 25 + k;
                        append(&dir, &h(n), &rec(n)).unwrap();
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
    }

    #[test]
    fn a_writer_waits_for_the_store_lock() {
        let d = scratch();
        let held = holder(&d.0, os::FileLock::Exclusive);
        let dir = d.0.clone();
        let writer = std::thread::spawn(move || append(&dir, &h(1), &rec(1)));
        std::thread::sleep(Duration::from_millis(300));
        assert_eq!(fs::metadata(path(&d.0)).unwrap().len(), 0, "the writer wrote while another held the lock");
        assert!(!writer.is_finished());
        drop(held);
        writer.join().unwrap().unwrap();
        assert_eq!(index(&d.0).unwrap().hashes, vec![h(1)]);
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
        let e = append_within(&d.0, &h(1), &rec(1), Duration::from_millis(100)).unwrap_err();
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
    fn the_command_line() {
        let d = scratch();
        fn args(a: &[&str]) -> Vec<String> {
            a.iter().map(|s| s.to_string()).collect()
        }
        let mut input = rec(1);
        input.push(b'\n');
        assert_eq!(run(&d.0, &args(&["append", h(1).as_str()]), &input), (0, Vec::new(), Vec::new()));
        assert_eq!(index(&d.0).unwrap().hashes, vec![h(1)]);
        let stored = fs::read(path(&d.0)).unwrap();
        assert_eq!(json::parse_one(&stored[..stored.len() - 1]).unwrap().get("record").unwrap().as_bytes(), Some(rec(1)));
        let (code, out, err) = run(&d.0, &args(&["append", "sha256:x"]), &input);
        assert_eq!((code, out.is_empty(), err.starts_with(b"safedeps-core approvals: not written: ")), (2, true, true));
        let bads: [&[&str]; 5] = [&["append"], &["append", "a", "b"], &["index", "x"], &["nothing"], &[]];
        for bad in bads {
            assert_eq!(run(&d.0, &args(bad), b""), (2, Vec::new(), USAGE.as_bytes().to_vec()), "{bad:?}");
        }
        let (code, out, err) = run(&d.0, &args(&["index"]), b"");
        assert_eq!((code, err), (0, Vec::new()));
        assert_eq!(String::from_utf8(out).unwrap(), format!("{{\"present\":true,\"hashes\":{{\"{}\":true}},\"broken\":0}}\n", h(1)));
        let (code, out, _) = run(&d.0.join("none"), &args(&["index"]), b"");
        assert_eq!((code, String::from_utf8(out).unwrap()), (0, "{\"present\":false,\"hashes\":{},\"broken\":0}\n".to_string()));
        fs::create_dir_all(path(&d.0.join("dir"))).unwrap();
        let (code, out, err) = run(&d.0.join("dir"), &args(&["index"]), b"");
        assert_eq!((code, out.is_empty()), (1, true));
        assert!(String::from_utf8(err).unwrap().contains("could not be read"));
    }
}
