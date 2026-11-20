//! The migration's rows. Each makes a SAFEDEPS_HOME, its ledger and its
//! advisory.log lines in a scratch directory, and runs the migration there.
//! The death rows, a run killed and run again, are the approvals-store
//! battery's (scripts/test/lib/core-approvals-store.py): they need a process
//! to kill.
use super::*;
use super::super::{index, Index};

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

/// Approve lines, inserted, duplicates, unconfirmed and taken back.
fn totals(r: &Report) -> [usize; 5] {
    [r.approve, r.inserted, r.duplicates, r.unconfirmed, r.taken_back]
}

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
        write_locked(&file, &line(&at(1), &a, Via::Check, &record(1, "clean", &a))).unwrap();
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
    let a = entry(&h, "a", None);
    live(&h, &[approve(1, "clean", &a)]);
    let held = locked(&h.home, LOCK_WAIT).unwrap();
    match migrate_within(&h.home, &h.ledger, &[], Duration::from_millis(200)) {
        Err(Failed::Store(e)) => assert_eq!(e.kind(), io::ErrorKind::TimedOut),
        other => panic!("not a store failure: {other:?}"),
    }
    drop(held);
    assert_eq!(store(&h), b"");
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
    // Two homes alike: one run in each, the person's lines and --json.
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
        "approvals migrate: {}\n  read {}: 2 lines: 2 approve, 0 cache, 0 undone, 0 in-doubt, 0 broken, 0 torn\n  2 approve lines: 1 inserted, 0 duplicates, 1 unconfirmed, 0 taken back\n  unconfirmed {b}: no ledger entry stands at its path\n",
        path(&h.home).display(),
        h.home.join(ADVISORY_LOG).display()
    );
    assert_eq!((code, String::from_utf8(out).unwrap(), err), (0, want, Vec::new()));
    let (h, b) = two();
    let (code, out, err) = command(&h.home, &h.ledger, &["--json"]);
    let want = format!(
        r#"{{"command":"approvals migrate","store":"{}","inputs":[{{"path":"{}","lines":2,"approve":2,"cache":0,"undone":0,"in_doubt":0,"broken":0,"torn":0}}],"approve_lines":2,"inserted":1,"duplicates":0,"unconfirmed":1,"taken_back":0,"cache":0,"broken":0,"torn":0,"unconfirmed_hashes":[{{"hash":"{b}","reason":"no_entry"}}],"error":null}}"#,
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
        r#"{{"command":"approvals migrate","store":"{}","error":"approvals_store_failed","inserted":0,"outcome":"os-error-21"}}"#,
        path(&f.home).display()
    ) + "\n";
    assert_eq!((code, String::from_utf8(out).unwrap()), (1, want));
    assert!(err.starts_with(b"safedeps-core approvals: not migrated: "));
}
