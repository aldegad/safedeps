//! The migration's rows. Each makes a SAFEDEPS_HOME, its ledger and its
//! advisory.log lines in a scratch directory, and runs the migration there.
//! The death rows, a run killed and run again, are the approvals-store
//! battery's (scripts/test/lib/core-approvals-store.py): they need a process
//! to kill. So are the rows of a write the kernel stops partway: they need a
//! file size limit, which binds a whole process. The rows here fail a write
//! or a read through the run's steps (`Steps`), to count what a failed write
//! left and to fail what a kernel does not fail on demand: a sync, and the
//! read after a failed write.
use super::*;
use super::super::{index, read_locked, write_locked, write_then_sync, Index, Real, Steps, SEAL};
use std::cell::Cell;

const EFBIG: i32 = 27;
const EIO: i32 = 5;

struct Dir(PathBuf);
impl Drop for Dir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// A SAFEDEPS_HOME and its ledger directory, in a scratch directory that also
/// holds the archives a row names.
struct Home {
    home: PathBuf,
    ledger: PathBuf,
    scratch: Dir,
}

fn home() -> Home {
    let scratch = Dir(os::scratch_dir("safedeps-migrate-test").expect("a scratch directory"));
    let home = scratch.0.join("home");
    let ledger = home.join("approved-specs");
    fs::create_dir_all(&ledger).unwrap();
    Home { home, ledger, scratch }
}

/// A project context hash, for an entry scoped to a project.
const CONTEXT: &str = "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";

/// A ledger entry as `safedeps check` writes one: its own `hash`, and a
/// project context where `context` is a context hash.
fn entry_text(hash: &str, package: &str, version: &str, context: Option<&str>) -> String {
    let context = context.map_or(String::new(), |c| {
        format!(r#","project_context":{{"type":"npm-overrides-probe","context_hash":"{c}","project_root":"/fixture","overrides_source":"package.json","overrides_sha256":"{c}","overrides":{{"left-pad":"1.3.0"}}}}"#)
    });
    format!(
        r#"{{"hash":"{hash}","ecosystem":"npm","package":"{package}","version":"{version}","version_range":"{version}","approved_at":"2026-11-01T00:00:00Z","expires_at":"2027-11-01T00:00:00Z","approved_by":"safedeps check","evidence":{{"osv":[]}}{context}}}"#
    ) + "\n"
}

fn put(h: &Home, hash: &str, bytes: &[u8]) {
    fs::write(h.ledger.join(ledger::filename(hash)), bytes).unwrap();
}

/// The hash of `package` 1.0.0 in `context`, its entry put at its path.
fn entry(h: &Home, package: &str, context: Option<&str>) -> String {
    let hash = ledger::hash("npm", package, "1.0.0", context.unwrap_or(""));
    put(h, &hash, entry_text(&hash, package, "1.0.0", context).as_bytes());
    hash
}

/// The hash of `package` 1.0.0, with nothing put at its path.
fn no_entry(package: &str) -> String {
    ledger::hash("npm", package, "1.0.0", "")
}

/// The time `s` seconds after the rows' first second.
fn at(s: i64) -> String {
    os::utc_stamp(ledger::epoch("2026-11-01T00:00:00Z").unwrap() + s)
}

/// The text of an approve line of `kind`, as a check writes it.
fn record(s: i64, kind: &str, hash: &str) -> Vec<u8> {
    let line = approve(s, kind, hash);
    line.as_bytes()[TEXT_AT..line.len() - 1].to_vec()
}

fn approve(s: i64, kind: &str, hash: &str) -> String {
    format!("[{}] check approve({kind}) ecosystem=npm package=p version=1.0.0 hash={hash}\n", at(s))
}

fn undone(s: i64, hash: &str) -> String {
    format!("[{}] check approve-undone hash={hash} outcome=os-error-28\n", at(s))
}

#[test]
fn old_and_described_undone_outcomes_in_one_archive_both_take_back() {
    let h = home();
    let [a, b, c] = ["a", "b", "c"].map(|p| entry(&h, p, None));
    live(&h, &[]);
    let archive = archive(&h, "mixed.log", &[
        approve(1, "clean", &a), approve(1, "clean", &b), approve(1, "clean", &c),
        undone(2, &a),
        format!("[{}] check approve-undone hash={b} outcome=the rename to /fixture/entry with spaces returned OS error 18\n", at(2)),
    ]);
    assert_eq!(totals(&run(&h, &[archive])), [3, 1, 0, 0, 2]);
    assert_eq!(ix(&h).hashes, vec![c]);
}

fn in_doubt(s: i64, hash: &str) -> String {
    format!("[{}] check approve-in-doubt hash={hash}\n", at(s))
}

fn live(h: &Home, lines: &[String]) {
    fs::write(h.home.join(ADVISORY_LOG), lines.concat()).unwrap();
}

/// An archive read as text.
fn archive(h: &Home, name: &str, lines: &[String]) -> PathBuf {
    let p = h.scratch.0.join(name);
    fs::write(&p, lines.concat()).unwrap();
    p
}

/// `text` through `gzip -c`, as a rotation compresses an archive.
fn gzipped(text: &[u8]) -> Vec<u8> {
    let mut child = Command::new("gzip").arg("-c").stdin(Stdio::piped()).stdout(Stdio::piped()).spawn().unwrap();
    let mut stdin = child.stdin.take().unwrap();
    let text = text.to_vec();
    let feed = std::thread::spawn(move || stdin.write_all(&text));
    let out = child.wait_with_output().unwrap();
    feed.join().unwrap().unwrap();
    assert!(out.status.success());
    out.stdout
}

/// An archive a rotation compressed.
fn gz_archive(h: &Home, name: &str, lines: &[String]) -> PathBuf {
    let p = h.scratch.0.join(name);
    fs::write(&p, gzipped(lines.concat().as_bytes())).unwrap();
    p
}

fn run(h: &Home, archives: &[PathBuf]) -> Report {
    migrate(&h.home, &h.ledger, archives).expect("the migration finished")
}

/// A run of the live file through `steps`.
fn run_with(h: &Home, steps: &dyn Steps) -> Result<Report, Failed> {
    migrate_within(&h.home, &h.ledger, &[], LOCK_WAIT, steps)
}

/// What the command gives for `result`: exit status, stdout and stderr.
fn said(h: &Home, json: bool, result: &Result<Report, Failed>) -> (i32, String, String) {
    let (code, out, err) = answer(&path(&h.home), json, result);
    (code, String::from_utf8(out).unwrap(), String::from_utf8(err).unwrap())
}

/// Approve lines, inserted, duplicates, unconfirmed and taken back, of a run
/// that knows how many of its lines the store holds and left none out.
fn totals(r: &Report) -> [usize; 5] {
    let (inserted, not_inserted) = r.inserted().expect("a count of the lines in the store");
    assert_eq!(not_inserted, 0, "a run that left lines out");
    [r.approve, inserted, r.duplicates, r.unconfirmed, r.taken_back]
}

/// Approve lines, inserted, not inserted, duplicates, unconfirmed and taken
/// back, of a run whose write failed. The five after the first add up to it.
fn failed_totals(r: &Report) -> [usize; 6] {
    let (inserted, not_inserted) = r.inserted().expect("a count of the lines in the store");
    let t = [r.approve, inserted, not_inserted, r.duplicates, r.unconfirmed, r.taken_back];
    assert_eq!(t[1..].iter().sum::<usize>(), t[0], "the counts do not add up to the approve lines: {t:?}");
    t
}

/// How many of `hashes` the store vouches for.
fn in_store(h: &Home, hashes: &[&String]) -> usize {
    ix(h).hashes.iter().filter(|x| hashes.contains(x)).count()
}

/// A check's store line for `hash`, written under the store lock.
fn committed(h: &Home, s: i64, hash: &str) {
    let file = locked(&h.home, LOCK_WAIT).unwrap();
    write_locked(&file, &path(&h.home), &line(&at(s), hash, Via::Check, &record(s, "clean", hash))).unwrap();
}

/// Bytes at the end of the store, as a writer that died left them.
fn left_by_a_death(h: &Home, bytes: &[u8]) {
    fs::OpenOptions::new().append(true).open(path(&h.home)).unwrap().write_all(bytes).unwrap();
}

/// The store line a migration writes for the approve line of `hash` at `s`.
fn mine(s: i64, hash: &str) -> Vec<u8> {
    line(&at(s), hash, Via::Migrate, &record(s, "clean", hash))
}

/// A run's store steps where the write lands the first `keep` bytes of its
/// lines, through the commit's own write, so a torn tail is sealed before
/// them, and then answers not written with EFBIG, as a write the kernel
/// stops partway does. Read number `fail_read`, counted from 1, answers EIO.
struct Partway {
    keep: usize,
    fail_read: Option<usize>,
    reads: Cell<usize>,
}

impl Partway {
    fn new(keep: usize, fail_read: Option<usize>) -> Self {
        Self { keep, fail_read, reads: Cell::new(0) }
    }
}

impl Steps for Partway {
    fn read(&self, file: &fs::File, store: &Path) -> Result<Index, Vec<u8>> {
        self.reads.set(self.reads.get() + 1);
        if Some(self.reads.get()) == self.fail_read {
            return Err(Outcome::Io(Err(io::Error::from_raw_os_error(EIO))).describe(Action::Read(store), Form::Action));
        }
        read_locked(file, store)
    }
    fn append(&self, file: &fs::File, store: &Path, lines: &[u8]) -> Result<(), Appended> {
        write_locked(file, store, &lines[..self.keep]).expect("the bytes that land");
        Err(Appended::NotWritten(Outcome::Io(Err(io::Error::from_raw_os_error(EFBIG))).describe(Action::Write(store), Form::Action)))
    }
}

/// A run's store steps where the write lands every byte and the sync
/// answers EIO.
struct SyncFails;

impl Steps for SyncFails {
    fn append(&self, file: &fs::File, store: &Path, lines: &[u8]) -> Result<(), Appended> {
        write_then_sync(file, store, lines, |_| Err(io::Error::from_raw_os_error(EIO)))
    }
}

/// What the rerun line says, the last line of a failed write's stderr.
const AGAIN: &str = "safedeps-core approvals: run it again: it inserts the lines that are not in the store and counts the lines that are as duplicates\n";

fn store(h: &Home) -> Vec<u8> {
    fs::read(path(&h.home)).unwrap_or_default()
}

fn ix(h: &Home) -> Index {
    index(&h.home).unwrap()
}

/// Each store line's at, hash, via and record.
fn lines(h: &Home) -> Vec<(String, String, String, Vec<u8>)> {
    store(h)
        .split(|&b| b == b'\n')
        .filter(|l| !l.is_empty())
        .map(|l| {
            let v = json::parse_one(l).unwrap();
            let s = |k: &str| v.get(k).and_then(json::Value::as_str).unwrap().to_string();
            (s("at"), s("hash"), s("via"), v.get("record").unwrap().as_bytes().unwrap())
        })
        .collect()
}

fn migrated(s: i64, kind: &str, hash: &str) -> (String, String, String, Vec<u8>) {
    (at(s), hash.to_string(), "migrate".to_string(), record(s, kind, hash))
}

#[test]
fn only_a_hash_its_ledger_entry_confirms_is_inserted() {
    let h = home();
    let plain = entry(&h, "a", None);
    let scoped = entry(&h, "c", Some(CONTEXT));
    let missing = no_entry("b");
    // At the path of `d` 1.0.0 an entry of `d` 2.0.0 that names the path's
    // hash as its own: its fields give another hash.
    let other_version = no_entry("d");
    put(&h, &other_version, entry_text(&other_version, "d", "2.0.0", None).as_bytes());
    // An entry whose fields give the path's hash and whose own hash is
    // another.
    let other_own = no_entry("e");
    put(&h, &other_own, entry_text(&plain, "e", "1.0.0", None).as_bytes());
    let not_json = no_entry("f");
    put(&h, &not_json, b"{\"hash\":");
    let a_dir = no_entry("g");
    fs::create_dir(h.ledger.join(ledger::filename(&a_dir))).unwrap();
    // An entry `ledger::valid` does not read as one: it has no evidence.
    let invalid = no_entry("i");
    put(&h, &invalid, entry_text(&invalid, "i", "1.0.0", None).replace(r#","evidence":{"osv":[]}"#, "").as_bytes());
    let fifo = no_entry("j");
    assert!(Command::new("mkfifo").arg(h.ledger.join(ledger::filename(&fifo))).status().unwrap().success());
    let order = [&plain, &missing, &other_version, &other_own, &not_json, &a_dir, &invalid, &fifo, &scoped];
    live(&h, &order.iter().enumerate().map(|(s, hash)| approve(s as i64, "clean", hash)).collect::<Vec<_>>());
    let r = run(&h, &[]);
    assert_eq!(totals(&r), [9, 2, 0, 7, 0]);
    assert_eq!(
        r.unconfirmed_hashes,
        vec![
            (missing, Unconfirmed::NoEntry),
            (other_version, Unconfirmed::OtherHash),
            (other_own, Unconfirmed::OtherHash),
            (not_json, Unconfirmed::NotAnEntry),
            (a_dir, Unconfirmed::NotAnEntry),
            (invalid, Unconfirmed::NotAnEntry),
            (fifo, Unconfirmed::NotAnEntry),
        ]
    );
    assert_eq!(ix(&h), Index { present: true, hashes: vec![plain.clone(), scoped.clone()], broken: 0 });
    assert_eq!(lines(&h), vec![migrated(0, "clean", &plain), migrated(8, "clean", &scoped)]);
}

/// Approve lines a take-back made by `back` comes after, each in one way:
/// later in the file in the same second; later in the file with an earlier
/// stamp; stamped later in the live file, for a line an archive holds and the
/// live file holds too. The control: an approval after its take-back stands.
fn takes_back_the_lines_before_it(back: fn(i64, &str) -> String) {
    let h = home();
    let [same_second, earlier_stamp, archived, again] = ["a", "b", "c", "d"].map(|p| entry(&h, p, None));
    let rotated = gz_archive(&h, "advisory.log.20261101T000100Z.gz", &[approve(10, "clean", &archived)]);
    live(
        &h,
        &[
            approve(10, "clean", &archived),
            approve(20, "clean", &same_second),
            back(20, &same_second),
            approve(30, "patched", &earlier_stamp),
            back(29, &earlier_stamp),
            back(40, &archived),
            approve(50, "clean", &again),
            back(51, &again),
            approve(52, "clean closure", &again),
        ],
    );
    let r = run(&h, &[rotated]);
    assert_eq!(totals(&r), [6, 1, 0, 0, 5]);
    assert_eq!(ix(&h), Index { present: true, hashes: vec![again.clone()], broken: 0 });
    assert_eq!(lines(&h), vec![migrated(52, "clean closure", &again)]);
}

#[test]
fn an_undone_line_takes_back_the_approve_lines_before_it() {
    takes_back_the_lines_before_it(undone);
}

#[test]
fn an_in_doubt_line_takes_back_the_approve_lines_before_it() {
    takes_back_the_lines_before_it(in_doubt);
}

#[test]
fn the_lines_of_one_hash_insert_one_store_line_and_the_rest_are_duplicates() {
    let h = home();
    let [a, b] = ["a", "b"].map(|p| entry(&h, p, None));
    // An archive that holds lines the live file holds too, and a second
    // approval of `a`.
    let kept = archive(&h, "advisory.log.old", &[approve(5, "clean", &a), approve(6, "clean", &b)]);
    live(&h, &[approve(5, "clean", &a), approve(6, "clean", &b), approve(9, "patched", &a)]);
    let r = run(&h, &[kept]);
    assert_eq!(totals(&r), [5, 2, 3, 0, 0]);
    assert_eq!(lines(&h), vec![migrated(5, "clean", &a), migrated(6, "clean", &b)]);
}

#[test]
fn a_second_run_inserts_nothing_and_leaves_the_store_as_it_was() {
    let h = home();
    let [a, b, c] = ["a", "b", "c"].map(|p| entry(&h, p, None));
    // The store vouches for `a` already: a check committed it.
    {
        let file = locked(&h.home, LOCK_WAIT).unwrap();
        write_locked(&file, &path(&h.home), &line(&at(1), &a, Via::Check, &record(1, "clean", &a))).unwrap();
    }
    live(&h, &[approve(1, "clean", &a), approve(2, "clean", &b), approve(3, "patched", &c)]);
    let first = run(&h, &[]);
    assert_eq!(totals(&first), [3, 2, 1, 0, 0]);
    let after_first = store(&h);
    let second = run(&h, &[]);
    assert_eq!(totals(&second), [3, 0, 3, 0, 0]);
    assert_eq!(store(&h), after_first);
    assert_eq!(ix(&h), Index { present: true, hashes: vec![a, b, c], broken: 0 });
}

#[test]
fn broken_lines_are_counted_and_never_moved() {
    let h = home();
    let [a, b] = ["a", "b"].map(|p| entry(&h, p, None));
    let text = |s: i64, t: String| format!("[{}] {t}\n", at(s));
    live(
        &h,
        &[
            // A time that is not one, and no time.
            format!("[2026-13-01T00:00:00Z] check approve(clean) hash={b}\n"),
            format!("check approve(clean) hash={b}\n"),
            // A kind no check writes, a kind not closed, a word on the kind.
            text(1, format!("check approve(clean-ish) hash={b}")),
            text(2, format!("check approve(clean hash={b}")),
            text(3, format!("check approve(clean)hash={b}")),
            // Two hashes, no hash, and a hash that is not one.
            text(4, format!("check approve(clean) hash={b} hash={a}")),
            text(5, "check approve(patched) package=b version=1.0.0".to_string()),
            text(6, format!("check approve(clean) hash={}", b.to_uppercase())),
            // A take-back with no hash, and an approval's words inside
            // another line.
            text(7, "check approve-undone outcome=os-error-28".to_string()),
            text(8, format!("note check approve(clean) hash={b}")),
            approve(9, "clean", &a),
        ],
    );
    let r = run(&h, &[]);
    assert_eq!(r.inputs[0].1, Counts { lines: 11, approve: 1, broken: 10, ..Counts::default() });
    assert_eq!(totals(&r), [1, 1, 0, 0, 0]);
    assert_eq!(ix(&h), Index { present: true, hashes: vec![a], broken: 0 });
}

#[test]
fn a_cache_line_is_counted_and_never_moved() {
    let h = home();
    let a = entry(&h, "a", None);
    live(&h, &[approve(1, "cache", &a)]);
    let r = run(&h, &[]);
    assert_eq!(r.inputs[0].1, Counts { lines: 1, cache: 1, ..Counts::default() });
    assert_eq!(totals(&r), [0, 0, 0, 0, 0]);
    assert_eq!(ix(&h).hashes, Vec::<String>::new());
}

#[test]
fn a_torn_last_line_is_counted_and_never_moved() {
    let h = home();
    let [a, b] = ["a", "b"].map(|p| entry(&h, p, None));
    let whole = [approve(1, "clean", &a), approve(2, "clean", &b)].concat();
    // b's line whole but its newline.
    fs::write(h.home.join(ADVISORY_LOG), whole.strip_suffix('\n').unwrap()).unwrap();
    let r = run(&h, &[]);
    assert_eq!(r.inputs[0].1, Counts { lines: 1, approve: 1, torn: 1, ..Counts::default() });
    assert_eq!(totals(&r), [1, 1, 0, 0, 0]);
    assert_eq!(ix(&h).hashes, vec![a.clone()]);
    // The control: the same bytes with the newline move both.
    let c = home();
    let [a, b] = ["a", "b"].map(|p| entry(&c, p, None));
    fs::write(c.home.join(ADVISORY_LOG), &whole).unwrap();
    assert_eq!(totals(&run(&c, &[])), [2, 2, 0, 0, 0]);
    assert_eq!(ix(&c).hashes, vec![a, b]);
}

#[test]
fn an_input_that_cannot_be_read_is_named_and_nothing_is_written() {
    let h = home();
    let a = entry(&h, "a", None);
    live(&h, &[approve(1, "clean", &a)]);
    let missing = h.scratch.0.join("advisory.log.1.gz");
    // Text named as gzip, and gzip cut short.
    let not_gzip = archive(&h, "advisory.log.2.gz", &[approve(2, "clean", &a)]);
    let cut = h.scratch.0.join("advisory.log.3.gz");
    let gz = gzipped(approve(3, "clean", &a).repeat(50).as_bytes());
    fs::write(&cut, &gz[..gz.len() / 2]).unwrap();
    let good = gz_archive(&h, "advisory.log.4.gz", &[approve(4, "clean", &a)]);
    let names = [&missing, &not_gzip, &cut, &good].map(|p| p.to_str().unwrap().to_string());
    let (code, out, err) = command(&h.home, &h.ledger, &names.iter().map(String::as_str).collect::<Vec<_>>());
    assert_eq!((code, out), (1, Vec::new()));
    let err = String::from_utf8(err).unwrap();
    let said: Vec<&str> = err.lines().collect();
    assert_eq!(said.len(), 4, "{err}");
    let not = "safedeps-core approvals: not migrated: ";
    assert_eq!(said[0], format!("{not}{} could not be read: the read of {} returned OS error 2", names[0], names[0]));
    for (l, name) in said[1..3].iter().zip(&names[1..3]) {
        let gzip = format!("{not}{name} could not be read: ran gzip: exit ");
        assert!(l.starts_with(&gzip) && !l.ends_with(": exit 0"), "{l}");
    }
    assert_eq!(said[3], format!("{not}3 inputs could not be read, so nothing was written"));
    assert!(!path(&h.home).exists());
    // With --json: the failure, and each input with what its read returned.
    let (code, out, _) = command(&h.home, &h.ledger, &["--json", names[0].as_str()]);
    assert_eq!(code, 1);
    let want = format!(
        r#"{{"command":"approvals migrate","store":"{}","error":"input_unreadable","inserted":0,"unreadable":[{{"path":"{}","outcome":"the read of {} returned OS error 2"}}]}}"#,
        path(&h.home).display(),
        names[0],
        names[0]
    ) + "\n";
    assert_eq!(String::from_utf8(out).unwrap(), want);
    assert!(!path(&h.home).exists());
    // The live file is an input too.
    let empty = home();
    match migrate(&empty.home, &empty.ledger, &[]) {
        Err(Failed::Inputs(list)) => assert_eq!(list.iter().map(|(p, _)| p.clone()).collect::<Vec<_>>(), vec![empty.home.join(ADVISORY_LOG)]),
        other => panic!("not an unreadable input: {other:?}"),
    }
    assert!(!path(&empty.home).exists());
}

#[test]
fn a_store_lock_another_holds_ends_the_run_and_nothing_is_written() {
    let h = home();
    let [a, b] = ["a", "b"].map(|p| entry(&h, p, None));
    committed(&h, 1, &a);
    live(&h, &[approve(1, "clean", &a), approve(2, "clean", &b)]);
    let before = store(&h);
    let held = locked(&h.home, LOCK_WAIT).unwrap();
    let result = migrate_within(&h.home, &h.ledger, &[], Duration::from_millis(200), &Real);
    match &result {
        Err(Failed::Store(e)) => assert_eq!(e, format!("the lock of {} did not finish before the deadline", path(&h.home).display()).as_bytes()),
        other => panic!("not a store failure: {other:?}"),
    }
    drop(held);
    assert_eq!(store(&h), before);
    let (code, out, err) = said(&h, false, &result);
    assert_eq!((code, out.as_str()), (1, ""));
    let not = format!("safedeps-core approvals: not migrated: {} could not be opened, locked or read (", path(&h.home).display());
    assert!(err.starts_with(&not) && err.ends_with("), so nothing was written\n") && err.lines().count() == 1, "{err}");
}

#[test]
fn a_store_read_that_fails_before_the_write_ends_the_run_and_nothing_is_written() {
    let h = home();
    let [a, b] = ["a", "b"].map(|p| entry(&h, p, None));
    committed(&h, 1, &a);
    live(&h, &[approve(1, "clean", &a), approve(2, "clean", &b)]);
    let before = store(&h);
    // The read before the write fails: the run has no store to judge by.
    let result = run_with(&h, &Partway::new(0, Some(1)));
    match &result {
        Err(Failed::Store(e)) => assert_eq!(e, format!("the read of {} returned OS error 5", path(&h.home).display()).as_bytes()),
        other => panic!("not a store failure: {other:?}"),
    }
    assert_eq!(store(&h), before);
    let (code, out, _) = said(&h, true, &result);
    let want = format!(r#"{{"command":"approvals migrate","store":"{}","error":"approvals_store_failed","inserted":0,"outcome":"the read of {0} returned OS error 5"}}"#, path(&h.home).display()) + "\n";
    assert_eq!((code, out), (1, want));
    let (_, _, err) = said(&h, false, &result);
    assert!(err.ends_with("), so nothing was written\n") && err.lines().count() == 1, "{err}");
}

#[test]
fn an_entry_that_cannot_be_read_ends_the_run_and_nothing_is_written() {
    let h = home();
    let [a, b] = ["a", "b"].map(|p| entry(&h, p, None));
    // At c's path a link to itself: its open fails, with what the kernel
    // answers for a loop of links, measured here.
    let c = no_entry("c");
    let at_c = h.ledger.join(ledger::filename(&c));
    std::os::unix::fs::symlink(&at_c, &at_c).unwrap();
    let code = fs::File::open(&at_c).unwrap_err().raw_os_error().expect("an OS error");
    committed(&h, 1, &a);
    live(&h, &[approve(1, "clean", &a), approve(2, "clean", &b), approve(3, "clean", &c)]);
    let before = store(&h);
    let why = format!("the read of {} returned OS error {code}", at_c.display());
    let (rc, out, err) = command(&h.home, &h.ledger, &["--json"]);
    let want = format!(
        r#"{{"command":"approvals migrate","store":"{}","error":"ledger_entry_unreadable","inserted":0,"entry":{{"path":"{}","outcome":"{why}"}}}}"#,
        path(&h.home).display(),
        at_c.display()
    ) + "\n";
    assert_eq!((rc, String::from_utf8(out).unwrap()), (1, want));
    let want = format!("safedeps-core approvals: not migrated: the ledger entry {} could not be read ({why}), so nothing was written\n", at_c.display());
    assert_eq!(String::from_utf8(err).unwrap(), want);
    // b was confirmed before c ended the run, and its line is not written.
    assert_eq!(store(&h), before);
}

#[test]
fn a_write_that_fails_partway_counts_the_lines_of_the_run_the_store_holds() {
    let h = home();
    let [a, b, c, d, e] = ["a", "b", "c", "d", "e"].map(|p| entry(&h, p, None));
    // The store before the run: a check's line for `a`, then a torn tail, a
    // record of another hash whole but its newline.
    committed(&h, 1, &a);
    let other = no_entry("z");
    let tail = line(&at(0), &other, Via::Check, &record(0, "clean", &other));
    left_by_a_death(&h, tail.strip_suffix(b"\n").unwrap());
    let before = store(&h);
    live(
        &h,
        &[approve(1, "clean", &a), approve(2, "clean", &b), approve(3, "clean", &c), approve(4, "clean", &d), approve(5, "clean", &e), approve(6, "patched", &d)],
    );
    // The write lands the lines of b and c and half of d's.
    let piece = mine(4, &d)[..mine(4, &d).len() / 2].to_vec();
    let keep = mine(2, &b).len() + mine(3, &c).len() + piece.len();
    let result = run_with(&h, &Partway::new(keep, None));
    // The condition, read from the bytes: the seal of the tail, two whole
    // lines and a piece of the third.
    assert_eq!(store(&h), [before, vec![SEAL, b'\n'], mine(2, &b), mine(3, &c), piece].concat());
    assert_eq!(ix(&h), Index { present: true, hashes: vec![a.clone(), b.clone(), c.clone()], broken: 2 });
    let r = match &result {
        Err(Failed::Write(e, r)) => {
            assert_eq!(e, format!("the write to {} returned OS error 27", path(&h.home).display()).as_bytes());
            r
        }
        other => panic!("not a failed write: {other:?}"),
    };
    // Inserted is what the store holds of this run's lines, not of the lines
    // before it: b and c. d and e are not inserted. a's line and d's second
    // are duplicates.
    assert_eq!(failed_totals(r), [6, 2, 2, 2, 0, 0]);
    assert_eq!(r.inserted().unwrap().0, in_store(&h, &[&b, &c, &d, &e]));
    let store_path = path(&h.home);
    let live_path = h.home.join(ADVISORY_LOG);
    let (code, out, err) = said(&h, true, &result);
    let want = format!(
        r#"{{"command":"approvals migrate","store":"{}","inputs":[{{"path":"{}","lines":6,"approve":6,"cache":0,"undone":0,"in_doubt":0,"broken":0,"torn":0}}],"approve_lines":6,"inserted":2,"not_inserted":2,"duplicates":2,"unconfirmed":0,"taken_back":0,"cache":0,"broken":0,"torn":0,"unconfirmed_hashes":[],"error":"approvals_store_write_failed","outcome":"the write to {0} returned OS error 27"}}"#,
        store_path.display(),
        live_path.display()
    ) + "\n";
    assert_eq!((code, out), (1, want));
    let failed = format!("safedeps-core approvals: not migrated in full: the write to {} failed (the write to {0} returned OS error 27)\n", store_path.display());
    let counted = "safedeps-core approvals: 2 of the run's 4 store lines are in the store and 2 are not\n";
    assert_eq!(err, [failed.as_str(), counted, AGAIN].concat());
    let (code, out, err2) = said(&h, false, &result);
    let want = format!(
        "approvals migrate: {}\n  read {}: 6 lines: 6 approve, 0 cache, 0 undone, 0 in-doubt, 0 broken, 0 torn\n  6 approve lines: 2 inserted, 2 not inserted, 2 duplicates, 0 unconfirmed, 0 taken back\n",
        store_path.display(),
        live_path.display()
    );
    assert_eq!((code, out, err2), (1, want, err));
    // Run again: the lines not inserted go in, and the lines the failed run
    // left are duplicates. A third run inserts nothing and leaves the bytes.
    assert_eq!(totals(&run(&h, &[])), [6, 2, 4, 0, 0]);
    assert_eq!(ix(&h), Index { present: true, hashes: vec![a, b, c, d, e], broken: 2 });
    let after_again = store(&h);
    assert_eq!(totals(&run(&h, &[])), [6, 0, 6, 0, 0]);
    assert_eq!(store(&h), after_again);
}

#[test]
fn a_write_that_fails_and_a_read_after_it_that_fails_give_no_count() {
    let h = home();
    let [a, b, c] = ["a", "b", "c"].map(|p| entry(&h, p, None));
    live(&h, &[approve(1, "clean", &a), approve(2, "clean", &b), approve(3, "clean", &c)]);
    // The write lands a's line and half of b's, and the read after it fails.
    let keep = mine(1, &a).len() + mine(2, &b).len() / 2;
    let result = run_with(&h, &Partway::new(keep, Some(2)));
    // What a read would have found: one line of the run. The run did not see
    // it, so it gives no number.
    assert_eq!(ix(&h), Index { present: true, hashes: vec![a.clone()], broken: 1 });
    let r = match &result {
        Err(Failed::Write(_, r)) => r,
        other => panic!("not a failed write: {other:?}"),
    };
    assert!(r.inserted().is_none(), "a count nobody read: {:?}", r.inserted());
    assert!(matches!(&r.landed, Landed::Unknown(e) if e == format!("the read of {} returned OS error 5", path(&h.home).display()).as_bytes()), "{:?}", r.landed);
    let store_path = path(&h.home);
    let live_path = h.home.join(ADVISORY_LOG);
    let (code, out, err) = said(&h, true, &result);
    let want = format!(
        r#"{{"command":"approvals migrate","store":"{}","inputs":[{{"path":"{}","lines":3,"approve":3,"cache":0,"undone":0,"in_doubt":0,"broken":0,"torn":0}}],"approve_lines":3,"inserted":"unknown","not_inserted":"unknown","duplicates":0,"unconfirmed":0,"taken_back":0,"cache":0,"broken":0,"torn":0,"unconfirmed_hashes":[],"error":"approvals_store_write_failed","outcome":"the write to {0} returned OS error 27","reread_outcome":"the read of {0} returned OS error 5"}}"#,
        store_path.display(),
        live_path.display()
    ) + "\n";
    assert_eq!((code, out), (1, want));
    let failed = format!("safedeps-core approvals: not migrated in full: the write to {} failed (the write to {0} returned OS error 27)\n", store_path.display());
    let unknown = format!(
        "safedeps-core approvals: how many of the run's 3 store lines are in the store is not known: the read of {} returned OS error 5\n",
        store_path.display()
    );
    assert_eq!(err, [failed.as_str(), unknown.as_str(), AGAIN].concat());
    let (code, out, err2) = said(&h, false, &result);
    let want = format!(
        "approvals migrate: {}\n  read {}: 3 lines: 3 approve, 0 cache, 0 undone, 0 in-doubt, 0 broken, 0 torn\n  3 approve lines: inserted unknown, not inserted unknown, 0 duplicates, 0 unconfirmed, 0 taken back\n",
        store_path.display(),
        live_path.display()
    );
    assert_eq!((code, out, err2), (1, want, err));
    // A run after it ends where a whole run ends.
    assert_eq!(totals(&run(&h, &[])), [3, 2, 1, 0, 0]);
    assert_eq!(ix(&h), Index { present: true, hashes: vec![a, b, c], broken: 1 });
}

#[test]
fn a_sync_that_fails_says_every_line_of_the_run_is_in_the_store() {
    let h = home();
    let [a, b] = ["a", "b"].map(|p| entry(&h, p, None));
    live(&h, &[approve(1, "clean", &a), approve(2, "clean", &b), approve(3, "patched", &a)]);
    let result = run_with(&h, &SyncFails);
    let r = match &result {
        Err(Failed::Unsynced(e, r)) => {
            assert_eq!(e, format!("the sync of {} returned OS error 5", path(&h.home).display()).as_bytes());
            r
        }
        other => panic!("not an unsynced write: {other:?}"),
    };
    assert_eq!(failed_totals(r), [3, 2, 0, 1, 0, 0]);
    assert_eq!(r.inserted().unwrap().0, in_store(&h, &[&a, &b]));
    assert_eq!(ix(&h), Index { present: true, hashes: vec![a.clone(), b.clone()], broken: 0 });
    let store_path = path(&h.home);
    let live_path = h.home.join(ADVISORY_LOG);
    let (code, out, err) = said(&h, true, &result);
    let want = format!(
        r#"{{"command":"approvals migrate","store":"{}","inputs":[{{"path":"{}","lines":3,"approve":3,"cache":0,"undone":0,"in_doubt":0,"broken":0,"torn":0}}],"approve_lines":3,"inserted":2,"not_inserted":0,"duplicates":1,"unconfirmed":0,"taken_back":0,"cache":0,"broken":0,"torn":0,"unconfirmed_hashes":[],"error":"approvals_store_unsynced","outcome":"the sync of {0} returned OS error 5"}}"#,
        store_path.display(),
        live_path.display()
    ) + "\n";
    assert_eq!((code, out), (1, want));
    let unsynced = format!(
        "safedeps: unsynced: all 2 store lines of the run are in {}, none is left out, and the sync failed (the sync of {0} returned OS error 5). A reader sees them, and nothing says they are on the disk.\n",
        store_path.display()
    );
    assert_eq!(err, [unsynced.as_str(), AGAIN].concat());
    let (code, out, err2) = said(&h, false, &result);
    let want = format!(
        "approvals migrate: {}\n  read {}: 3 lines: 3 approve, 0 cache, 0 undone, 0 in-doubt, 0 broken, 0 torn\n  3 approve lines: 2 inserted, 0 not inserted, 1 duplicates, 0 unconfirmed, 0 taken back\n",
        store_path.display(),
        live_path.display()
    );
    assert_eq!((code, out, err2), (1, want, err));
    // A run after it reads the lines as the store vouching, and writes nothing.
    let before = store(&h);
    assert_eq!(totals(&run(&h, &[])), [3, 0, 3, 0, 0]);
    assert_eq!(store(&h), before);
}

#[test]
fn an_entry_is_confirmed_under_the_store_lock() {
    let h = home();
    let a = entry(&h, "a", None);
    live(&h, &[approve(1, "clean", &a)]);
    // A revoke holds the store lock, and the run waits for it.
    let held = locked(&h.home, LOCK_WAIT).unwrap();
    let (at_home, at_ledger) = (h.home.clone(), h.ledger.clone());
    let waiting = std::thread::spawn(move || migrate(&at_home, &at_ledger, &[]));
    std::thread::sleep(Duration::from_millis(300));
    // Under the lock the entry goes, and then the lock is let go.
    fs::remove_file(h.ledger.join(ledger::filename(&a))).unwrap();
    drop(held);
    let r = waiting.join().unwrap().expect("the migration finished");
    assert_eq!(totals(&r), [1, 0, 0, 1, 0]);
    assert_eq!(r.unconfirmed_hashes, vec![(a, Unconfirmed::NoEntry)]);
    assert_eq!(store(&h), b"");
}

#[test]
fn the_command_reads_its_options_and_prints_its_report() {
    assert_eq!(options(&["--json", "--", "--json"]), Some((true, &["--json"][..])));
    assert_eq!(options(&["a.gz", "--json"]), Some((false, &["a.gz", "--json"][..])));
    assert_eq!(options(&[]), Some((false, &[][..])));
    assert_eq!(options(&["--bogus"]), None);
    assert!(USAGE.contains("| migrate [--json] [--] [<archive>...]"));
    // Two homes alike: one run in each, the person's lines and --json. A
    // finished run gives its lines not inserted, 0, as every report that
    // gives the approve lines does, so the same five add up to them.
    let two = || {
        let h = home();
        let (a, b) = (entry(&h, "a", None), no_entry("b"));
        live(&h, &[approve(1, "clean", &a), approve(2, "clean", &b)]);
        (h, b)
    };
    let (h, b) = two();
    assert_eq!(command(&h.home, &h.ledger, &["--bogus"]), (2, Vec::new(), USAGE.as_bytes().to_vec()));
    assert!(!path(&h.home).exists());
    let (code, out, err) = command(&h.home, &h.ledger, &[]);
    let want = format!(
        "approvals migrate: {}\n  read {}: 2 lines: 2 approve, 0 cache, 0 undone, 0 in-doubt, 0 broken, 0 torn\n  2 approve lines: 1 inserted, 0 not inserted, 0 duplicates, 1 unconfirmed, 0 taken back\n  unconfirmed {b}: no ledger entry stands at its path\n",
        path(&h.home).display(),
        h.home.join(ADVISORY_LOG).display()
    );
    assert_eq!((code, String::from_utf8(out).unwrap(), err), (0, want, Vec::new()));
    let (h, b) = two();
    let (code, out, err) = command(&h.home, &h.ledger, &["--json"]);
    let want = format!(
        r#"{{"command":"approvals migrate","store":"{}","inputs":[{{"path":"{}","lines":2,"approve":2,"cache":0,"undone":0,"in_doubt":0,"broken":0,"torn":0}}],"approve_lines":2,"inserted":1,"not_inserted":0,"duplicates":0,"unconfirmed":1,"taken_back":0,"cache":0,"broken":0,"torn":0,"unconfirmed_hashes":[{{"hash":"{b}","reason":"no_entry"}}],"error":null}}"#,
        path(&h.home).display(),
        h.home.join(ADVISORY_LOG).display()
    ) + "\n";
    assert_eq!((code, String::from_utf8(out).unwrap(), err), (0, want, Vec::new()));
    // A store that cannot be opened: the failure, with --json, through the
    // approvals command.
    let (f, _) = two();
    fs::create_dir(path(&f.home)).unwrap();
    let (code, out, err) = super::super::run(&f.home, &["migrate".to_string(), "--json".to_string()], b"");
    let want = format!(
        r#"{{"command":"approvals migrate","store":"{}","error":"approvals_store_failed","inserted":0,"outcome":"the open of {0} returned OS error 21"}}"#,
        path(&f.home).display()
    ) + "\n";
    assert_eq!((code, String::from_utf8(out).unwrap()), (1, want));
    assert!(err.starts_with(b"safedeps-core approvals: not migrated: "));
}
