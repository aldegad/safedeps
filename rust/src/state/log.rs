//! The rotation of advisory.log, and its one implementation. The post hook
//! runs it from provider initialization. The CLI runs it through
//! `safedeps-core advisory-log rotate`, once its own look at the size says
//! the file is at the bound.
//!
//! advisory.log is a bounded record. No verdict and no provenance is read
//! from it: the approvals store holds provenance (approvals.rs). So a
//! rotation has no line to keep live, and it never rewrites the file. Under
//! the lock it renames the whole live file to an archive name that nothing
//! holds yet. The next line any writer appends makes a new live file.
//!
//! A writer that opened the live file before the rename and writes after it
//! writes into the archive. So a new archive stays plain. Only a later
//! rotation compresses it, and only once nothing has written to it for the
//! quiet window (QUIET_SECONDS, counted from its mtime). A line is in the
//! live file or in one archive. It leaves them by retention, or when its
//! writer held the old file open for longer than the quiet window and wrote
//! after the compression read it.
//!
//! The lock is flock(2) on `advisory.log.rotate.lock`, a regular file that
//! is never removed. The kernel lets the lock go when its holder exits, by
//! any end. A rotation that finds the lock held does not wait: the holder is
//! rotating. Writers never take it.
//!
//! Earlier versions locked by making a directory at that path, and took one
//! older than 300 seconds for a lock its holder left. The file keeps them
//! from rotating at all: their mkdir fails, and so does their removal of
//! what they take for a stale lock. A directory found there is one of
//! theirs. One younger than their window is held, and this rotation does not
//! run. An older one is removed by their own rule, and the file is made in
//! its place.
use crate::{os, outcome::{Action, Form, Outcome}};
use std::{fs, collections::BTreeMap, io::{self, Write}, os::unix::{ffi::OsStrExt, fs::{MetadataExt, OpenOptionsExt}}, path::{Path, PathBuf}, process::{Command, Stdio}, sync::atomic::{AtomicBool, Ordering}, time::{Duration, SystemTime}};

/// The live file rotates once it holds this many bytes. The CLI's look at
/// the size reads the same default (`rotation_bound_matches_cli`).
const MAX_BYTES: (&str, u64) = ("SAFEDEPS_ADVISORY_LOG_MAX_BYTES", 67_108_864);
/// How many archives survive, plain and gzip counted together.
const KEEP: (&str, u64) = ("SAFEDEPS_ADVISORY_LOG_KEEP", 5);
/// The bytes all archives together may hold, plain and gzip counted together.
const ARCHIVE_TOTAL_BYTES: (&str, u64) = ("SAFEDEPS_ADVISORY_LOG_ARCHIVE_TOTAL_BYTES", 536_870_912);
/// How long a plain archive goes unwritten before a rotation compresses it.
const QUIET_SECONDS: (&str, u64) = ("SAFEDEPS_ADVISORY_LOG_QUIET_SECONDS", 3600);
/// The age at which earlier versions took their lock directory for one its
/// holder left. Their rule, so it is not a knob of this version.
const LEGACY_LOCK_SECONDS: i64 = 300;
const LOCK_SUFFIX: &[u8] = b".rotate.lock";
const GZIP_SUFFIX: &[u8] = b".gz";
/// Where a compression writes before its rename. Not an archive name.
const COMPRESS_SUFFIX: &[u8] = b".compressing";
/// open(2)'s answer for a directory opened for writing, on macOS and Linux.
const EISDIR: i32 = 21;

static CHECKED: AtomicBool = AtomicBool::new(false);

/// What one look at the bound did.
#[derive(Debug, PartialEq, Eq)]
pub enum Rotation {
    /// This process looked already.
    Checked,
    /// The live file is under the bound, or is not a regular file.
    Under,
    /// Another rotation holds the lock, or an earlier version's lock
    /// directory is younger than its window.
    Held,
    /// The live file was renamed to an archive. The line the rotation wrote
    /// to the new live file says which, and what else the rotation did.
    Rotated,
    /// The live file was not rotated. The text says why, as the ERROR line
    /// written to the live file says it.
    Failed(Vec<u8>),
}

struct Knobs { max: u64, keep: u64, total: u64, quiet: Duration }

impl Knobs {
    fn from_env() -> Self {
        Self { max: knob(MAX_BYTES), keep: knob(KEEP), total: knob(ARCHIVE_TOTAL_BYTES), quiet: Duration::from_secs(knob(QUIET_SECONDS)) }
    }
}

/// Rotate `file` if it is at the bound, once per process.
pub fn advisory_rotate_once(file: &Path) -> Rotation {
    if CHECKED.swap(true, Ordering::SeqCst) { return Rotation::Checked }
    rotate(file, &Knobs::from_env())
}

fn knob((name, default): (&str, u64)) -> u64 {
    std::env::var(name).ok().filter(|s| !s.is_empty()).and_then(|s| s.parse().ok()).unwrap_or(default)
}
fn suffixed(file: &Path, suffix: &[u8]) -> PathBuf {
    os::path(&[file.as_os_str().as_bytes(), suffix].concat())
}
fn name(path: &Path) -> &[u8] {
    path.file_name().map_or(path.as_os_str().as_bytes(), |n| n.as_bytes())
}
fn stamp(seconds: i64) -> String {
    os::utc_stamp(seconds).replace(['-', ':'], "")
}
/// `<live>.<UTC stamp>`, with `.<n>` after it for the n-th archive of one
/// second.
fn archive_path(file: &Path, stamp: &str, n: u32) -> PathBuf {
    let n = if n == 0 { String::new() } else { format!(".{n}") };
    suffixed(file, format!(".{stamp}{n}").as_bytes())
}

/// An archive's place in time: its stamp, then its number in that second.
type Key = (Vec<u8>, u32);

/// The key of the archive name `name` of the live file `live`, and whether
/// it is the gzip one. Only `<live>.<stamp>`, `<live>.<stamp>.<n>` and each
/// of them with `.gz` after it are archives.
fn parse(live: &[u8], name: &[u8]) -> Option<(Key, bool)> {
    let rest = name.strip_prefix(live)?.strip_prefix(b".")?;
    let (rest, gzip) = match rest.strip_suffix(GZIP_SUFFIX) { Some(rest) => (rest, true), None => (rest, false) };
    if rest.len() < 16 { return None }
    let (stamp, number) = rest.split_at(16);
    let shaped = stamp.iter().enumerate().all(|(at, b)| match at { 8 => *b == b'T', 15 => *b == b'Z', _ => b.is_ascii_digit() });
    if !shaped { return None }
    let n = match number {
        [] => 0,
        [b'.', digits @ ..] if digits.first().is_some_and(|d| (b'1'..=b'9').contains(d)) && digits.iter().all(u8::is_ascii_digit) =>
            std::str::from_utf8(digits).ok()?.parse().ok()?,
        _ => return None,
    };
    Some(((stamp.to_vec(), n), gzip))
}

/// One archive: its plain file, its gzip file, or both. Both stand after a
/// compression that did not end, or one that found the plain file written
/// while gzip read it. The plain file is then the record.
#[derive(Default)]
struct Archive { plain: Option<(PathBuf, fs::Metadata)>, gzip: Option<(PathBuf, u64)> }

impl Archive {
    fn bytes(&self) -> u64 {
        self.plain.as_ref().map_or(0, |(_, m)| m.len()).saturating_add(self.gzip.as_ref().map_or(0, |(_, len)| *len))
    }
    fn paths(&self) -> impl Iterator<Item = &PathBuf> {
        self.plain.iter().map(|(p, _)| p).chain(self.gzip.iter().map(|(p, _)| p))
    }
}

/// The archives beside `file`, oldest first. A name that is gone by the
/// time it is read is not one of them.
fn archives(file: &Path) -> io::Result<BTreeMap<Key, Archive>> {
    let dir = file.parent().filter(|d| !d.as_os_str().is_empty()).unwrap_or(Path::new("."));
    let live = name(file);
    let mut found: BTreeMap<Key, Archive> = BTreeMap::new();
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let Some((key, gzip)) = parse(live, entry.file_name().as_bytes()) else { continue };
        // DirEntry::metadata does not follow a link.
        let meta = match entry.metadata() {
            Ok(meta) => meta,
            Err(e) if e.kind() == io::ErrorKind::NotFound => continue,
            Err(e) => return Err(e),
        };
        if !meta.file_type().is_file() { continue }
        let slot = found.entry(key).or_default();
        if gzip { slot.gzip = Some((entry.path(), meta.len())) } else { slot.plain = Some((entry.path(), meta)) }
    }
    Ok(found)
}

/// One line, `[<UTC time>] <level> <message>`, in one write.
fn append(file: &Path, level: &str, message: &[u8]) {
    let mut line = format!("[{}] {} ", os::utc_stamp(os::wall(os::WallRole::AdvisoryRotationHeader).seconds()), level).into_bytes();
    line.extend_from_slice(message);
    line.push(b'\n');
    if let Ok(mut f) = fs::OpenOptions::new().create(true).append(true).mode(0o600).open(file) {
        let _ = f.write_all(&line);
    }
}

fn failed(file: &Path, why: Vec<u8>) -> Rotation {
    let line = [b"advisory log not rotated: ".as_slice(), why.as_slice()].concat();
    append(file, "ERROR", &line);
    Rotation::Failed(line)
}

fn io_said(e: io::Error, action: Action<'_>) -> Vec<u8> {
    Outcome::Io(Err(e)).describe(action, Form::Action)
}
fn removal_said(path: &Path, e: io::Error) -> Vec<u8> {
    [b"could not remove ".as_slice(), path.as_os_str().as_bytes(), b": ", io_said(e, Action::Removal).as_slice()].concat()
}

/// What stands at `path`, the link itself where it is one; None where
/// nothing does.
fn lstat(path: &Path) -> io::Result<Option<fs::Metadata>> {
    match fs::symlink_metadata(path) {
        Ok(meta) => Ok(Some(meta)),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e),
    }
}

/// The live file is a regular file of at least `max` bytes.
fn over(meta: &fs::Metadata, max: u64) -> bool {
    meta.file_type().is_file() && meta.len() >= max
}

fn rotate(file: &Path, knobs: &Knobs) -> Rotation {
    // The look without the lock, so a file under the bound costs one stat.
    if !lstat(file).is_ok_and(|m| m.is_some_and(|m| over(&m, knobs.max))) { return Rotation::Under }
    let lock = suffixed(file, LOCK_SUFFIX);
    let _held = match take(&lock) {
        Ok(Some(held)) => held,
        Ok(None) => return Rotation::Held,
        Err(why) => return failed(file, why),
    };
    // The look again under the lock: the rotation that held it before this
    // one may have rotated already.
    let bytes = match lstat(file) {
        Ok(Some(meta)) if over(&meta, knobs.max) => meta.len(),
        Ok(_) => return Rotation::Under,
        Err(e) => return failed(file, io_said(e, Action::Read(file))),
    };
    let (archive, made) = match free(file, os::wall(os::WallRole::AdvisoryRotationName).seconds()) {
        Ok(free) => free,
        Err(why) => return failed(file, why),
    };
    if let Err(e) = fs::rename(file, &archive) { return failed(file, io_said(e, Action::Rename(&archive))) }
    let mut said = [format!("advisory log rotated: {bytes} bytes moved to ").as_bytes(), name(&archive)].concat();
    match archives(file) {
        Ok(found) => compress_one(file, &found, &made, knobs.quiet, &mut said),
        Err(e) => said.extend_from_slice(&[b"; no archive compressed: ".as_slice(), io_said(e, Action::Walk(file.parent().unwrap_or(file))).as_slice()].concat()),
    }
    // The listing again: a compression changed what the archives hold.
    match archives(file) {
        Ok(found) => prune(&found, &made, knobs, &mut said),
        Err(e) => said.extend_from_slice(&[b"; no archive removed: ".as_slice(), io_said(e, Action::Walk(file.parent().unwrap_or(file))).as_slice()].concat()),
    }
    append(file, "WARN", &said);
    Rotation::Rotated
}

/// The rotation lock, held; None where another holds it.
fn take(lock: &Path) -> Result<Option<fs::File>, Vec<u8>> {
    match lstat(lock) {
        Ok(Some(meta)) if meta.file_type().is_dir() => {
            let age = os::wall(os::WallRole::AdvisoryRotationLockAge).seconds().saturating_sub(meta.mtime());
            if age <= LEGACY_LOCK_SECONDS { return Ok(None) }
            match fs::remove_dir(lock) {
                Ok(()) => {}
                Err(e) if e.kind() == io::ErrorKind::NotFound => {}
                Err(e) => return Err([b"the lock directory an earlier version left: ".as_slice(), removal_said(lock, e).as_slice()].concat()),
            }
        }
        Ok(_) => {}
        Err(e) => return Err(io_said(e, Action::Read(lock))),
    }
    let file = match fs::OpenOptions::new().read(true).write(true).create(true).truncate(false).mode(0o600).open(lock) {
        Ok(file) => file,
        // An earlier version made its directory there since the look above,
        // and holds it.
        Err(e) if e.raw_os_error() == Some(EISDIR) => return Ok(None),
        Err(e) => return Err(io_said(e, Action::Open(lock))),
    };
    match os::flock_within(&file, os::FileLock::Exclusive, Duration::ZERO) {
        Ok(()) => Ok(Some(file)),
        Err(Outcome::Deadline) => Ok(None),
        Err(outcome) => Err(outcome.describe(Action::Lock(lock), Form::Action)),
    }
}

/// The first archive name of second `seconds` that no file holds, plain or
/// gzip. Under the lock no other rotation names one, so the name is still
/// free at the rename.
fn free(file: &Path, seconds: i64) -> Result<(PathBuf, Key), Vec<u8>> {
    let stamp = stamp(seconds);
    for n in 0..1000 {
        let plain = archive_path(file, &stamp, n);
        let gzip = suffixed(&plain, GZIP_SUFFIX);
        match (lstat(&plain), lstat(&gzip)) {
            (Ok(None), Ok(None)) => return Ok((plain, (stamp.into_bytes(), n))),
            (Err(e), _) => return Err(io_said(e, Action::Read(&plain))),
            (_, Err(e)) => return Err(io_said(e, Action::Read(&gzip))),
            _ => {}
        }
    }
    Err([b"every archive name of ".as_slice(), stamp.as_bytes(), b" is taken"].concat())
}

/// Nothing has written to `meta`'s file for longer than `window`.
fn quiet(meta: &fs::Metadata, now: SystemTime, window: Duration) -> bool {
    meta.modified().ok().and_then(|written| now.duration_since(written).ok()).is_some_and(|age| age > window)
}

/// Compress the oldest plain archive that has been quiet for the window,
/// other than the one this rotation made. One per rotation, since a
/// rotation runs inside a hook.
fn compress_one(file: &Path, found: &BTreeMap<Key, Archive>, made: &Key, window: Duration, said: &mut Vec<u8>) {
    let now = os::wall(os::WallRole::AdvisoryArchiveQuiet).system_time();
    let Some((plain, _)) = found.iter().filter(|(key, _)| *key != made)
        .filter_map(|(_, archive)| archive.plain.as_ref()).find(|(_, meta)| quiet(meta, now, window)) else { return };
    let gzip = suffixed(plain, GZIP_SUFFIX);
    let what = match compress(file, plain, &gzip) {
        Ok(true) => [b"; ".as_slice(), name(plain), b" compressed to ", name(&gzip)].concat(),
        Ok(false) => [b"; ".as_slice(), name(plain), b" compressed to ", name(&gzip), b" and left plain too: it was written while gzip read it"].concat(),
        Err(why) => [b"; ".as_slice(), name(plain), b" left plain: ", why.as_slice()].concat(),
    };
    said.extend_from_slice(&what);
}

/// gzip `plain` into `gzip` by way of the temp file, then remove `plain`
/// unless it grew while gzip read it. True where `plain` was removed. A
/// compression that fails leaves `plain` as it was.
fn compress(file: &Path, plain: &Path, gzip: &Path) -> Result<bool, Vec<u8>> {
    let temp = suffixed(file, COMPRESS_SUFFIX);
    // What a compression that did not end left.
    match fs::remove_file(&temp) {
        Ok(()) => {}
        Err(e) if e.kind() == io::ErrorKind::NotFound => {}
        Err(e) => return Err(removal_said(&temp, e)),
    }
    let out = fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&temp).map_err(|e| io_said(e, Action::Create(&temp)))?;
    let synced = out.try_clone().map_err(|e| io_said(e, Action::Open(&temp)))?;
    let before = fs::symlink_metadata(plain).map_err(|e| io_said(e, Action::Read(plain)))?.len();
    // gzip is the archive format's tool. No shell runs, and stderr has no
    // reader: the outcome says how it ended.
    let ran = match Command::new("gzip").arg("-c").arg(plain).stdin(Stdio::null()).stdout(out).stderr(Stdio::null()).status() {
        Ok(status) => Outcome::status(status),
        Err(e) => Outcome::StartFailure(e),
    };
    let done = if !ran.success() { Err(ran.describe(Action::Gzip, Form::Action)) }
        else if let Err(e) = synced.sync_all() { Err(io_said(e, Action::Sync(&temp))) }
        else if let Err(e) = fs::rename(&temp, gzip) { Err(io_said(e, Action::Rename(gzip))) }
        else { Ok(()) };
    if let Err(why) = done {
        let _ = fs::remove_file(&temp);
        return Err(why);
    }
    // A write gzip did not read is in the plain file only, and the plain
    // file is the record while it stands: the next rotation compresses it
    // again.
    match fs::symlink_metadata(plain) {
        Ok(meta) if meta.len() == before => fs::remove_file(plain).map(|()| true).map_err(|e| removal_said(plain, e)),
        Ok(_) => Ok(false),
        Err(e) => Err(io_said(e, Action::Read(plain))),
    }
}

/// Remove the archives beyond the bounds, newest kept first: past `keep`
/// archives, or once all of them together pass `total` bytes. The newest
/// one is kept whatever its size, and so is the one this rotation made.
fn prune(found: &BTreeMap<Key, Archive>, made: &Key, knobs: &Knobs, said: &mut Vec<u8>) {
    let mut bytes: u64 = 0;
    let mut removed: Vec<&[u8]> = Vec::new();
    let mut kept: Vec<Vec<u8>> = Vec::new();
    for (index, (key, archive)) in found.iter().rev().enumerate() {
        bytes = bytes.saturating_add(archive.bytes());
        if key == made { continue }
        if index as u64 >= knobs.keep || index > 0 && bytes > knobs.total {
            for path in archive.paths() {
                match fs::remove_file(path) {
                    Ok(()) => removed.push(name(path)),
                    Err(e) if e.kind() == io::ErrorKind::NotFound => {}
                    Err(e) => kept.push(removal_said(path, e)),
                }
            }
        }
    }
    if !removed.is_empty() {
        said.extend_from_slice(b"; removed beyond the retention bounds: ");
        said.extend_from_slice(&removed.join(b", ".as_slice()));
    }
    for why in kept {
        said.extend_from_slice(b"; ");
        said.extend_from_slice(&why);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    struct Dir(PathBuf);
    impl Drop for Dir { fn drop(&mut self) { let _ = fs::remove_dir_all(&self.0); } }
    fn dir() -> (Dir, PathBuf) {
        let dir = Dir(os::scratch_dir("safedeps-rotation-test").expect("a scratch directory"));
        let log = dir.0.join("advisory.log");
        (dir, log)
    }
    fn knobs(max: u64) -> Knobs { Knobs { max, keep: 5, total: u64::MAX, quiet: Duration::from_secs(3600) } }
    fn listing(dir: &Path) -> Vec<String> {
        let mut names: Vec<String> = fs::read_dir(dir).unwrap().map(|e| e.unwrap().file_name().to_string_lossy().into_owned()).collect();
        names.sort();
        names
    }
    fn aged(path: &Path, seconds: u64) {
        fs::File::open(path).unwrap().set_modified(SystemTime::now() - Duration::from_secs(seconds)).unwrap();
    }
    fn plain_archives(dir: &Path) -> Vec<PathBuf> {
        archives(&dir.join("advisory.log")).unwrap().into_values().filter_map(|a| a.plain.map(|(p, _)| p)).collect()
    }
    fn gunzip(path: &Path) -> Vec<u8> {
        let out = Command::new("gzip").arg("-dc").arg(path).output().unwrap();
        assert!(out.status.success(), "{} is whole gzip", path.display());
        out.stdout
    }

    #[test]
    fn archive_names_are_the_stamp_and_a_number_in_its_second() {
        let live = Path::new("fixture/advisory.log");
        assert_eq!(archive_path(live, &stamp(0), 0).as_os_str(), "fixture/advisory.log.19700101T000000Z");
        assert_eq!(archive_path(live, &stamp(0), 2).as_os_str(), "fixture/advisory.log.19700101T000000Z.2");
        assert_eq!(suffixed(live, LOCK_SUFFIX).as_os_str(), "fixture/advisory.log.rotate.lock");
        let key = |n| (b"20261123T221357Z".to_vec(), n);
        for (name, read) in [
            ("advisory.log.20261123T221357Z", Some((key(0), false))),
            ("advisory.log.20261123T221357Z.gz", Some((key(0), true))),
            ("advisory.log.20261123T221357Z.12", Some((key(12), false))),
            ("advisory.log.20261123T221357Z.12.gz", Some((key(12), true))),
            ("advisory.log.20261123T221357Z.0", None),
            ("advisory.log.20261123T221357Z.01", None),
            ("advisory.log.20261123T221357Z.", None),
            ("advisory.log.20261123T221357Z.x", None),
            ("advisory.log.2026112T221357Z", None),
            ("advisory.log.rotate.lock", None),
            ("advisory.log.compressing", None),
            ("advisory.log", None),
            ("other.log.20261123T221357Z", None),
        ] {
            assert_eq!(parse(b"advisory.log", name.as_bytes()), read, "{name}");
        }
        // Oldest first, a number after its second's first archive.
        let mut keys = vec![key(10), key(2), key(0), (b"20261123T221356Z".to_vec(), 3)];
        keys.sort();
        assert_eq!(keys, [(b"20261123T221356Z".to_vec(), 3), key(0), key(2), key(10)]);
    }

    #[test]
    fn under_the_bound_nothing_moves() {
        let (d, log) = dir();
        fs::write(&log, b"[t] INFO a\n").unwrap();
        assert_eq!(rotate(&log, &knobs(1000)), Rotation::Under);
        assert_eq!(listing(&d.0), ["advisory.log"]);
        assert_eq!(fs::read(&log).unwrap(), b"[t] INFO a\n");
    }

    #[test]
    fn a_rotation_renames_the_whole_file_and_says_so_in_the_next() {
        let (d, log) = dir();
        let body = b"[t] INFO trace\n[t] check approve(clean) x\nno stamp at all\n".repeat(50);
        fs::write(&log, &body).unwrap();
        let inode = fs::metadata(&log).unwrap().ino();
        // The bound is above the rotation's own line, about 100 bytes, so the
        // last look below asks whether the new file is left alone.
        assert_eq!(rotate(&log, &knobs(1000)), Rotation::Rotated);
        let plain = plain_archives(&d.0);
        assert_eq!(plain.len(), 1, "{:?}", listing(&d.0));
        assert_eq!(fs::metadata(&plain[0]).unwrap().ino(), inode, "the archive is the live file, renamed");
        assert_eq!(fs::read(&plain[0]).unwrap(), body, "every line, INFO or not, is in the archive");
        let live = fs::read(&log).unwrap();
        assert_eq!(live.iter().filter(|b| **b == b'\n').count(), 1, "the new live file holds the rotation's line: {}", String::from_utf8_lossy(&live));
        let said = format!("] WARN advisory log rotated: {} bytes moved to {}\n", body.len(), plain[0].file_name().unwrap().to_string_lossy());
        assert!(String::from_utf8_lossy(&live).ends_with(&said), "{}", String::from_utf8_lossy(&live));
        let lock = fs::symlink_metadata(d.0.join("advisory.log.rotate.lock")).unwrap();
        assert!(lock.file_type().is_file(), "the lock is a regular file, and it stays");
        assert_eq!(lock.permissions().mode() & 0o777, 0o600);
        // The new file is under the bound: the next look does not rotate it.
        assert_eq!(rotate(&log, &knobs(1000)), Rotation::Under);
    }

    #[test]
    fn a_name_of_this_second_that_a_file_holds_is_not_taken() {
        let (_d, log) = dir();
        let first = archive_path(&log, &stamp(1_800_000_000), 0);
        fs::write(&first, b"a").unwrap();
        fs::write(suffixed(&archive_path(&log, &stamp(1_800_000_000), 1), GZIP_SUFFIX), b"b").unwrap();
        let (free, key) = free(&log, 1_800_000_000).unwrap();
        assert_eq!(free, archive_path(&log, &stamp(1_800_000_000), 2));
        assert_eq!(key, (stamp(1_800_000_000).into_bytes(), 2));
    }

    #[test]
    fn a_held_lock_leaves_the_file_to_its_holder() {
        let (d, log) = dir();
        fs::write(&log, vec![b'x'; 200]).unwrap();
        let held = fs::OpenOptions::new().read(true).write(true).create(true).truncate(false).open(d.0.join("advisory.log.rotate.lock")).unwrap();
        os::flock_within(&held, os::FileLock::Exclusive, Duration::ZERO).unwrap();
        assert_eq!(rotate(&log, &knobs(100)), Rotation::Held);
        assert_eq!(listing(&d.0), ["advisory.log", "advisory.log.rotate.lock"]);
        drop(held);
        assert_eq!(rotate(&log, &knobs(100)), Rotation::Rotated, "the lock went with its holder's file");
    }

    #[test]
    fn an_earlier_versions_lock_directory_is_held_inside_its_window_and_removed_past_it() {
        let (d, log) = dir();
        fs::write(&log, vec![b'x'; 200]).unwrap();
        let lock = d.0.join("advisory.log.rotate.lock");
        fs::create_dir(&lock).unwrap();
        aged(&lock, 200);
        assert_eq!(rotate(&log, &knobs(100)), Rotation::Held);
        assert!(fs::symlink_metadata(&lock).unwrap().is_dir(), "a young directory is left as it is");
        assert_eq!(fs::read(&log).unwrap(), vec![b'x'; 200]);
        aged(&lock, 400);
        assert_eq!(rotate(&log, &knobs(100)), Rotation::Rotated);
        assert!(fs::symlink_metadata(&lock).unwrap().file_type().is_file(), "the file stands where the directory stood");
    }

    #[test]
    fn a_new_archive_stays_plain_and_a_later_rotation_compresses_one_quiet_one() {
        let (d, log) = dir();
        let quiet = Knobs { quiet: Duration::from_secs(60), ..knobs(100) };
        let old = archive_path(&log, &stamp(1_700_000_000), 0);
        let older = archive_path(&log, &stamp(1_600_000_000), 0);
        fs::write(&old, b"old line\n").unwrap();
        fs::write(&older, b"older line\n").unwrap();
        aged(&old, 120);
        aged(&older, 120);
        fs::write(suffixed(&log, COMPRESS_SUFFIX), b"a compression that did not end").unwrap();
        fs::write(&log, vec![b'x'; 200]).unwrap();
        // The live file has not been written for longer than the window,
        // and still the archive it becomes is not compressed.
        aged(&log, 120);
        assert_eq!(rotate(&log, &quiet), Rotation::Rotated);
        assert!(!older.exists(), "the oldest quiet archive was compressed");
        assert_eq!(gunzip(&suffixed(&older, GZIP_SUFFIX)), b"older line\n");
        assert_eq!(fs::read(&old).unwrap(), b"old line\n", "one compression per rotation");
        assert!(!suffixed(&log, COMPRESS_SUFFIX).exists(), "the temp file is gone");
        let made = plain_archives(&d.0).into_iter().find(|p| *p != old).expect("the new archive is plain");
        assert_eq!(fs::read(&made).unwrap(), vec![b'x'; 200]);
        let older_name = older.file_name().unwrap().to_string_lossy().into_owned();
        assert!(String::from_utf8_lossy(&fs::read(&log).unwrap()).contains(&format!("; {older_name} compressed to {older_name}.gz")));
        // Quiet is read from the last write, not from the name: the archive
        // the last rotation made has not been written for the window, and
        // the older one was written just now.
        fs::write(&log, vec![b'y'; 200]).unwrap();
        fs::OpenOptions::new().append(true).open(&old).unwrap().write_all(b"a late line\n").unwrap();
        assert_eq!(rotate(&log, &quiet), Rotation::Rotated);
        assert_eq!(fs::read(&old).unwrap(), b"old line\na late line\n", "an archive written inside the window stays plain");
        assert!(!made.exists());
        assert_eq!(gunzip(&suffixed(&made, GZIP_SUFFIX)), vec![b'x'; 200]);
    }

    #[test]
    fn a_plain_archive_beside_its_gzip_is_the_record_and_is_compressed_again() {
        let (_d, log) = dir();
        let plain = archive_path(&log, &stamp(1_700_000_000), 0);
        let gzip = suffixed(&plain, GZIP_SUFFIX);
        fs::write(&plain, b"first\nlate\n").unwrap();
        fs::write(&gzip, b"not what the plain file holds").unwrap();
        aged(&plain, 120);
        fs::write(&log, vec![b'x'; 200]).unwrap();
        assert_eq!(rotate(&log, &Knobs { quiet: Duration::from_secs(60), ..knobs(100) }), Rotation::Rotated);
        assert!(!plain.exists());
        assert_eq!(gunzip(&gzip), b"first\nlate\n");
    }

    #[test]
    fn a_gzip_that_fails_leaves_the_plain_archive() {
        let (_d, log) = dir();
        let plain = archive_path(&log, &stamp(1_700_000_000), 0);
        fs::write(&plain, b"kept\n").unwrap();
        aged(&plain, 120);
        // gzip cannot read it, so it fails.
        fs::set_permissions(&plain, fs::Permissions::from_mode(0o000)).unwrap();
        fs::write(&log, vec![b'x'; 200]).unwrap();
        assert_eq!(rotate(&log, &Knobs { quiet: Duration::from_secs(60), ..knobs(100) }), Rotation::Rotated);
        fs::set_permissions(&plain, fs::Permissions::from_mode(0o600)).unwrap();
        assert_eq!(fs::read(&plain).unwrap(), b"kept\n");
        assert!(!suffixed(&plain, GZIP_SUFFIX).exists());
        assert!(!suffixed(&log, COMPRESS_SUFFIX).exists());
        let live = String::from_utf8_lossy(&fs::read(&log).unwrap()).into_owned();
        assert!(live.contains(&format!("; {} left plain: ran gzip: exit ", plain.file_name().unwrap().to_string_lossy())), "{live}");
    }

    #[test]
    fn retention_counts_plain_and_gzip_archives_and_keeps_the_one_just_made() {
        let (d, log) = dir();
        for (seconds, gzip) in [(1_600_000_000, true), (1_600_000_001, false), (1_600_000_002, true), (1_600_000_003, false)] {
            let path = archive_path(&log, &stamp(seconds), 0);
            fs::write(if gzip { suffixed(&path, GZIP_SUFFIX) } else { path }, vec![b'a'; 10]).unwrap();
        }
        fs::write(&log, vec![b'x'; 200]).unwrap();
        assert_eq!(rotate(&log, &Knobs { keep: 2, ..knobs(100) }), Rotation::Rotated);
        let names = listing(&d.0);
        assert_eq!(names.len(), 4, "{names:?}");
        assert!(names.contains(&format!("advisory.log.{}", stamp(1_600_000_003))), "{names:?}");
        let live = String::from_utf8_lossy(&fs::read(&log).unwrap()).into_owned();
        assert!(live.contains("; removed beyond the retention bounds: "), "{live}");
        // The archive just made is kept whatever the total, and the newest.
        fs::write(&log, vec![b'y'; 300]).unwrap();
        assert_eq!(rotate(&log, &Knobs { total: 1, ..knobs(100) }), Rotation::Rotated);
        let plain = plain_archives(&d.0);
        assert_eq!(plain.len(), 1, "{:?}", listing(&d.0));
        assert_eq!(fs::read(&plain[0]).unwrap(), vec![b'y'; 300]);
    }
}

#[cfg(test)]
#[test]
fn rotation_bound_matches_cli() {
    let cli = include_str!("../../../lib/providers/providers.sh");
    let (name, default) = MAX_BYTES;
    let line = format!("{name}=\"${{{name}:-{default}}}\"");
    assert_eq!(cli.lines().filter(|l| *l == line).count(), 1, "the CLI looks at the size against the core's default bound");
}
