//! Rows for the marks an earlier post run left in its home. The next post run
//! reports each mark whose run is gone in advisory.log, once, as a NOT JUDGED
//! line, and leaves every other file in `judging/` as it is. Each row runs the
//! post hook as a child of this test binary (`tests::hook_child`), in a root
//! of its own outside the worktree, and reads what the runs left on disk.
//!
//! A run is known by its pid and the start the kernel stored for it. A mark
//! named with this test process's pid and another start is the mark of a run
//! whose pid the kernel handed out again, so a row makes the mark of a run
//! that is gone without waiting for a pid to be free.
use super::tests::{answers, child, digits_between, hook_child, reader_came, Reaped, BOUND};
use crate::post::{jv, process, report::cat, sh};
use std::{fs, os::unix::fs::PermissionsExt, path::{Path, PathBuf}, process::{Command, Output}, time::{Duration, Instant}};

const MODULE: &str = "post::run::unfinished_tests";

/// A row's own root: `home`, the SAFEDEPS_HOME of its runs, with `judging/`
/// made, and `project`, whose package-lock.json cannot be read. It is removed
/// on every way out of the row.
struct Root { root: PathBuf, home: PathBuf }
impl Root {
    fn new() -> Self {
        let root = crate::os::scratch_dir("safedeps-mark-left").unwrap();
        let home = root.join("home");
        fs::create_dir_all(home.join("judging")).unwrap();
        fs::create_dir(root.join("project")).unwrap();
        fs::write(root.join("project/package-lock.json"), b"{broken").unwrap();
        Self { root, home }
    }
    fn judging(&self) -> PathBuf { self.home.join("judging") }
    /// The project as the post hook names it.
    fn project(&self) -> Vec<u8> { crate::os::realpath(sh::bytes(&self.root.join("project"))) }
}
impl Drop for Root {
    fn drop(&mut self) {
        let _ = fs::set_permissions(self.judging(), fs::Permissions::from_mode(0o700));
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn mode(dir: &Path, mode: u32) { fs::set_permissions(dir, fs::Permissions::from_mode(mode)).unwrap(); }

/// The next post run in `home`, on `true`, a command the hook takes no call
/// for, so the run writes no mark of its own. It ends by itself, and its
/// answer is empty: what it reports goes to advisory.log.
fn next_run(test: &str, root: &Root, home: &Path) {
    let out = child(&format!("{MODULE}::{test}"), &root.root, home, Some("true")).wait_with_output().unwrap();
    ran_quietly(&out);
}

fn ran_quietly(out: &Output) {
    assert!(out.status.success(), "{:?}\n{}", out.status, String::from_utf8_lossy(&out.stderr));
    assert!(answers(&out.stdout).is_empty(), "the run's answer is empty\n{}", String::from_utf8_lossy(&out.stdout));
}

/// A post run on `npm install mark-fixture`, held in the middle of its
/// judgment: the command-independent backstop finds the project's
/// package-lock.json unreadable and next reads the confirmed record,
/// `confirmed` in the home. That is a FIFO whose writer the row holds, so the
/// run waits there until the row lets it go or kills it.
struct Held { run: Reaped, pid: u32, writer: Option<fs::File> }

fn hold(test: &str, root: &Root) -> Held {
    let fifo = root.home.join("confirmed");
    assert!(Command::new("mkfifo").arg(&fifo).status().unwrap().success());
    let mut run = Reaped(Some(child(&format!("{MODULE}::{test}"), &root.root, &root.home, None)));
    let pid = run.0.as_ref().unwrap().id();
    let until = Instant::now() + BOUND;
    while !run.ended() && Instant::now() < until {
        if let Some(writer) = reader_came(&fifo).unwrap() { return Held { run, pid, writer: Some(writer) } }
        std::thread::sleep(Duration::from_millis(20));
    }
    panic!("the run did not reach the confirmed record within {BOUND:?}")
}

impl Held {
    /// SIGKILL, as the runtime kills a hook, and the reaping of the run.
    fn kill(&mut self) {
        let mut run = self.run.0.take().unwrap();
        run.kill().unwrap();
        run.wait().unwrap();
    }
    /// The writer closes: the record reads empty, and the judgment goes on to
    /// its end.
    fn let_go(&mut self) -> Output {
        drop(self.writer.take());
        let until = Instant::now() + BOUND;
        while !self.run.ended() && Instant::now() < until { std::thread::sleep(Duration::from_millis(20)); }
        let mut run = self.run.0.take().unwrap();
        if run.try_wait().unwrap().is_none() { run.kill().unwrap(); }
        run.wait_with_output().unwrap()
    }
}

/// The names in `dir`, sorted.
fn names(dir: &Path) -> Vec<String> {
    let mut names: Vec<String> = fs::read_dir(dir).unwrap().map(|e| e.unwrap().file_name().to_string_lossy().into_owned()).collect();
    names.sort();
    names
}

fn name(path: &Path) -> String { path.file_name().unwrap().to_string_lossy().into_owned() }

/// The text of the string `key` in the JSON object at `path`.
fn field(path: &Path, key: &str) -> Vec<u8> {
    let value = jv::read_one_object(path).expect("one JSON object");
    jv::field(&value, key).ok().and_then(jv::text).expect("a string").to_vec()
}

fn log(home: &Path) -> String { String::from_utf8_lossy(&fs::read(home.join("advisory.log")).unwrap_or_default()).into_owned() }

const HEAD: &[u8] = b"post-verify NOT JUDGED: ";

/// The texts of advisory.log's NOT JUDGED lines, in the order written.
fn not_judged(home: &Path) -> Vec<Vec<u8>> {
    fs::read(home.join("advisory.log")).unwrap_or_default().split(|b| *b == b'\n')
        .filter_map(|line| line.iter().position(|b| *b == b'\t').map(|tab| line[tab + 1..].to_vec()))
        .filter(|text| text.starts_with(HEAD)).collect()
}

/// The line for the mark of a run that is gone, where the mark names its call.
/// `unclaimed` is empty, or the sentence that this run could not claim it.
fn line(mark: &Path, opened: &[u8], fact: &[u8], unclaimed: &[u8], tool: &[u8], project: &[u8], command: &[u8]) -> Vec<u8> {
    cat(&[HEAD, b"the post run that took this call at ", opened, b" did not finish judging it: its judgment mark ", sh::bytes(mark),
        b" is still there, and ", fact, b".", unclaimed, b" Tool use: ", tool, b". Project: ", project, b". Command: ", command])
}

/// The line for the mark of a run that is gone, where the mark does not name
/// its call: `reason` says what is wrong with it.
fn unnamed(mark: &Path, fact: &[u8], reason: &[u8]) -> Vec<u8> {
    cat(&[HEAD, b"a post run did not finish judging a call: its judgment mark ", sh::bytes(mark), b" is still there, and ", fact,
        b". The mark ", reason, b", so the call is not known."])
}

/// The sentence of a line whose mark this run could not claim, in a
/// `judging/` at mode 0500.
fn unclaimed(mark: &Path) -> Vec<u8> {
    cat(&[b" This run could not claim the mark: the rename of ", sh::bytes(mark), b" returned OS error 13."])
}

/// The fact about a run whose pid the kernel handed to another process.
fn reused(pid: u32, start: u64) -> Vec<u8> {
    format!("pid {pid} is another process now: the kernel stored the start {start} for it").into_bytes()
}

/// `said` is `expected` with the fact that the run with `pid` is gone where
/// `expected` holds a NUL: the kernel holds no process under the pid, or
/// another one (a pid the kernel can hand out again by the time a row reads).
fn with_gone_fact(said: &[u8], expected: &[u8], pid: u32) -> bool {
    let at = expected.iter().position(|b| *b == 0).unwrap();
    let (head, tail) = (&expected[..at], &expected[at + 1..]);
    if said.len() < head.len() + tail.len() || !said.starts_with(head) || !said.ends_with(tail) { return false }
    let fact = &said[head.len()..said.len() - tail.len()];
    fact == format!("pid {pid} is not running").as_bytes()
        || digits_between(fact, format!("pid {pid} is another process now: the kernel stored the start ").as_bytes(), b" for it")
}

/// This test process: its pid and the start the kernel stored for it.
fn me() -> (u32, u64) {
    let pid = std::process::id();
    (pid, process::start(pid).expect("the kernel's start of this process"))
}

const OPENED: &[u8] = b"2026-11-20T01:02:03Z";

/// The JSON of a mark as `Mark::open` writes one, for a run with `pid` and
/// `start`. Its call is `npm install planted-<start>` in `/planted/<start>`,
/// with the tool use `toolu_<start>`, taken at OPENED.
fn mark_json(pid: u32, start: u64) -> Vec<u8> {
    let value = jv::obj(vec![
        ("pid", jv::s(pid.to_string().as_bytes())), ("start", jv::s(start.to_string().as_bytes())), ("opened_at", jv::s(OPENED)),
        ("tool_use_id", jv::s(format!("toolu_{start}").as_bytes())), ("project", jv::s(format!("/planted/{start}").as_bytes())),
        ("command", jv::s(format!("npm install planted-{start}").as_bytes())),
    ]);
    cat(&[&jv::dump(&value), b"\n"])
}

/// Puts the mark of a run with `pid` and `start` straight into `home`'s
/// judging/, and returns its path.
fn plant(home: &Path, pid: u32, start: u64) -> PathBuf {
    let path = home.join("judging").join(format!("{pid}-{start}.json"));
    fs::write(&path, mark_json(pid, start)).unwrap();
    path
}

/// The line for a planted mark.
fn planted(mark: &Path, start: u64, fact: &[u8], unclaimed: &[u8]) -> Vec<u8> {
    line(mark, OPENED, fact, unclaimed, format!("toolu_{start}").as_bytes(), format!("/planted/{start}").as_bytes(),
        format!("npm install planted-{start}").as_bytes())
}

/// Done Criteria (2): a post run SIGKILLed in the middle of its judgment
/// leaves its mark, and the next run writes one NOT JUDGED line with the
/// call's command, its project and the time its judgment started. The run
/// after that writes none.
#[test]
fn a_judgment_the_runtime_killed_is_reported_once_by_the_next_run() {
    hook_child();
    const TEST: &str = "a_judgment_the_runtime_killed_is_reported_once_by_the_next_run";
    let root = Root::new();
    let mut held = hold(TEST, &root);
    let start = process::start(held.pid).expect("the kernel's start of the run");
    let mark_name = format!("{}-{}.json", held.pid, start);
    assert_eq!(names(&root.judging()), vec![mark_name.clone()], "the run's own mark, while it judges");
    let mark = root.judging().join(&mark_name);
    let opened = field(&mark, "opened_at");
    held.kill();
    assert_eq!(names(&root.judging()), vec![mark_name], "a killed run leaves its mark");
    next_run(TEST, &root, &root.home);
    let said = not_judged(&root.home);
    let [said] = said.as_slice() else { panic!("one NOT JUDGED line\n{}", log(&root.home)) };
    let expected = line(&mark, &opened, b"\0", b"", b"toolu_mark", &root.project(), b"npm install mark-fixture");
    assert!(with_gone_fact(said, &expected, held.pid), "{}", String::from_utf8_lossy(said));
    assert!(names(&root.judging()).is_empty(), "the mark went, and no claim is left: {:?}", names(&root.judging()));
    next_run(TEST, &root, &root.home);
    assert_eq!(not_judged(&root.home).len(), 1, "the mark is reported once\n{}", log(&root.home));
}

/// A killed run the kernel still holds as a zombie, not yet reaped, is gone:
/// its judgment cannot go on.
#[test]
fn a_killed_run_the_kernel_holds_as_a_zombie_is_gone() {
    hook_child();
    const TEST: &str = "a_killed_run_the_kernel_holds_as_a_zombie_is_gone";
    let root = Root::new();
    let mut held = hold(TEST, &root);
    let start = process::start(held.pid).expect("the kernel's start of the run");
    let mark = root.judging().join(format!("{}-{}.json", held.pid, start));
    let opened = field(&mark, "opened_at");
    held.run.0.as_mut().unwrap().kill().unwrap();
    let (pid, zombie) = (held.pid.to_string(), format!("pid {} is a zombie", held.pid));
    let until = Instant::now() + BOUND;
    while !process::owner(pid.as_bytes(), b"").1.starts_with(zombie.as_bytes()) {
        assert!(Instant::now() < until, "the killed run was not a zombie within {BOUND:?}");
        std::thread::sleep(Duration::from_millis(20));
    }
    next_run(TEST, &root, &root.home);
    let expected = line(&mark, &opened, zombie.as_bytes(), b"", b"toolu_mark", &root.project(), b"npm install mark-fixture");
    assert_eq!(not_judged(&root.home), vec![expected], "{}", log(&root.home));
    assert!(names(&root.judging()).is_empty(), "{:?}", names(&root.judging()));
}

/// Done Criteria (3): a run is alive while the kernel holds its pid with the
/// start it stored. A mark with this process's pid and start stays, as it was,
/// and nothing is said of it. A mark with the same pid and another start is
/// the mark of a run whose pid was handed out again, and it is reported.
#[test]
fn a_mark_is_live_by_its_pid_and_start_and_gone_by_another_start() {
    hook_child();
    const TEST: &str = "a_mark_is_live_by_its_pid_and_start_and_gone_by_another_start";
    let root = Root::new();
    let (pid, start) = me();
    let live = plant(&root.home, pid, start);
    let live_bytes = fs::read(&live).unwrap();
    let reused_mark = plant(&root.home, pid, start + 1);
    next_run(TEST, &root, &root.home);
    assert_eq!(not_judged(&root.home), vec![planted(&reused_mark, start + 1, &reused(pid, start), b"")], "{}", log(&root.home));
    assert_eq!(names(&root.judging()), vec![name(&live)]);
    assert_eq!(fs::read(&live).unwrap(), live_bytes, "a live run's mark is left as it is");
    next_run(TEST, &root, &root.home);
    assert_eq!(not_judged(&root.home).len(), 1, "{}", log(&root.home));
}

/// Done Criteria (3) and (5): two post runs judge in one home at once. A run
/// that reads the home meanwhile reports neither mark. One of the two is
/// killed; the other ends by itself and removes its own mark and not the
/// other's. The next run reports the killed run's mark alone.
#[test]
fn two_runs_at_once_neither_report_nor_remove_each_others_mark() {
    hook_child();
    const TEST: &str = "two_runs_at_once_neither_report_nor_remove_each_others_mark";
    let root = Root::new();
    let mut first = hold(TEST, &root);
    let mut second = Reaped(Some(child(&format!("{MODULE}::{TEST}"), &root.root, &root.home, None)));
    let second_pid = second.0.as_ref().unwrap().id();
    let until = Instant::now() + BOUND;
    while names(&root.judging()).len() < 2 {
        assert!(!second.ended() && Instant::now() < until, "the second run wrote its mark within {BOUND:?}");
        std::thread::sleep(Duration::from_millis(20));
    }
    let first_name = format!("{}-{}.json", first.pid, process::start(first.pid).expect("the first run's start"));
    let second_name = format!("{}-{}.json", second_pid, process::start(second_pid).expect("the second run's start"));
    let mut both = vec![first_name, second_name.clone()];
    both.sort();
    assert_eq!(names(&root.judging()), both, "each run's own mark");
    let second_mark = root.judging().join(&second_name);
    let opened = field(&second_mark, "opened_at");
    next_run(TEST, &root, &root.home);
    assert!(not_judged(&root.home).is_empty(), "a live run's mark is not reported\n{}", log(&root.home));
    assert_eq!(names(&root.judging()), both);
    let mut killed = second.0.take().unwrap();
    killed.kill().unwrap();
    killed.wait().unwrap();
    let out = first.let_go();
    assert!(out.status.success(), "the first run ended by itself: {:?}", out.status);
    assert_eq!(names(&root.judging()), vec![second_name], "the first run removed its own mark and not the other's");
    next_run(TEST, &root, &root.home);
    let said = not_judged(&root.home);
    let [said] = said.as_slice() else { panic!("one NOT JUDGED line\n{}", log(&root.home)) };
    let expected = line(&second_mark, &opened, b"\0", b"", b"toolu_mark", &root.project(), b"npm install mark-fixture");
    assert!(with_gone_fact(said, &expected, second_pid), "{}", String::from_utf8_lossy(said));
    assert!(names(&root.judging()).is_empty(), "{:?}", names(&root.judging()));
}

/// Runs that read one home at once report each mark once: the run that
/// claims a mark says it, and the others find it gone.
#[test]
fn runs_that_read_one_home_at_once_report_each_mark_once() {
    hook_child();
    const TEST: &str = "runs_that_read_one_home_at_once_report_each_mark_once";
    let root = Root::new();
    let (pid, start) = me();
    let marks: Vec<(PathBuf, u64)> = (1..=20).map(|k| (plant(&root.home, pid, start + k), start + k)).collect();
    let mut runs: Vec<Reaped> = (0..16).map(|_| Reaped(Some(child(&format!("{MODULE}::{TEST}"), &root.root, &root.home, Some("true"))))).collect();
    for run in &mut runs { ran_quietly(&run.0.take().unwrap().wait_with_output().unwrap()); }
    let mut said = not_judged(&root.home);
    said.sort();
    let mut expected: Vec<Vec<u8>> = marks.iter().map(|(mark, start_k)| planted(mark, *start_k, &reused(pid, start), b"")).collect();
    expected.sort();
    assert!(said == expected, "each mark once, and nothing else\n{}", log(&root.home));
    assert!(names(&root.judging()).is_empty(), "{:?}", names(&root.judging()));
}

/// A mark that is not its call's whole record is still the mark of a run that
/// is gone. Its line names the mark, the fact about its run and what is wrong
/// with the mark, and no call. Files in `judging/` that are not marks (a
/// temporary file, a name with a pid of 0, a leading zero, a start of 0 or a
/// pid the kernel never hands out, a directory) stay as they are, and nothing
/// is said of them.
#[test]
fn a_mark_that_does_not_name_its_call_is_reported_by_its_file_name() {
    hook_child();
    const TEST: &str = "a_mark_that_does_not_name_its_call_is_reported_by_its_file_name";
    let root = Root::new();
    let (pid, start) = me();
    let at = |k: u64| root.judging().join(format!("{pid}-{}.json", start + k));
    fs::write(at(1), b"").unwrap();
    fs::write(at(2), b"{\"pid\":\"").unwrap();
    let other = jv::dump(&jv::obj(vec![("pid", jv::s(b"1")), ("start", jv::s((start + 3).to_string().as_bytes())),
        ("opened_at", jv::s(OPENED)), ("tool_use_id", crate::json::Value::Null), ("project", jv::s(b"/p")), ("command", jv::s(b"npm ci"))]));
    fs::write(at(3), other).unwrap();
    let commandless = jv::dump(&jv::obj(vec![("pid", jv::s(pid.to_string().as_bytes())), ("start", jv::s((start + 4).to_string().as_bytes())),
        ("opened_at", jv::s(OPENED)), ("tool_use_id", crate::json::Value::Null), ("project", jv::s(b"/p"))]));
    fs::write(at(4), commandless).unwrap();
    let left = [format!(".{pid}-{}.json.0a1b2c", start + 5), "notes.txt".into(), "0-5.json".into(), format!("0{pid}-{start}.json"),
        format!("{pid}-0.json"), "2147483648-5.json".into()];
    for other in &left { fs::write(root.judging().join(other), mark_json(pid, start + 9)).unwrap(); }
    fs::create_dir(at(6)).unwrap();
    let mut kept: Vec<String> = left.to_vec();
    kept.push(name(&at(6)));
    kept.sort();
    next_run(TEST, &root, &root.home);
    let fact = reused(pid, start);
    let mut said = not_judged(&root.home);
    said.sort();
    let mut expected = vec![unnamed(&at(1), &fact, b"is not one JSON object"), unnamed(&at(2), &fact, b"is not one JSON object"),
        unnamed(&at(3), &fact, b"does not name the pid and start in its file name"), unnamed(&at(4), &fact, b"has no string field command")];
    expected.sort();
    assert!(said == expected, "{}", log(&root.home));
    assert_eq!(names(&root.judging()), kept, "what is not a mark stays");
    next_run(TEST, &root, &root.home);
    assert_eq!(not_judged(&root.home).len(), 4, "{}", log(&root.home));
}

/// A mark lives with the advisory.log of its home. A run under another
/// SAFEDEPS_HOME neither reports nor touches it; the next run under its own
/// home reports it there.
#[test]
fn a_mark_is_reported_in_its_own_home_and_nowhere_else() {
    hook_child();
    const TEST: &str = "a_mark_is_reported_in_its_own_home_and_nowhere_else";
    let root = Root::new();
    let other = root.root.join("other-home");
    fs::create_dir_all(other.join("judging")).unwrap();
    let (pid, start) = me();
    let mark = plant(&root.home, pid, start + 1);
    let bytes = fs::read(&mark).unwrap();
    next_run(TEST, &root, &other);
    assert!(not_judged(&other).is_empty(), "{}", log(&other));
    assert!(!root.home.join("advisory.log").exists(), "a run under another home writes nothing here");
    assert_eq!(fs::read(&mark).unwrap(), bytes, "nor touches the mark");
    next_run(TEST, &root, &root.home);
    assert_eq!(not_judged(&root.home), vec![planted(&mark, start + 1, &reused(pid, start), b"")], "{}", log(&root.home));
    assert!(names(&root.judging()).is_empty());
    assert!(not_judged(&other).is_empty());
}

/// A mark no run can claim, in a `judging/` that takes no change, is reported
/// by every run while that lasts, and each line says that the claim failed
/// and what the rename returned. Once the directory takes the claim, the next
/// run reports the mark once more, without that sentence, and removes it.
#[test]
fn a_mark_no_run_can_claim_is_reported_by_each_run_until_one_can() {
    hook_child();
    const TEST: &str = "a_mark_no_run_can_claim_is_reported_by_each_run_until_one_can";
    let root = Root::new();
    let (pid, start) = me();
    let mark = plant(&root.home, pid, start + 1);
    mode(&root.judging(), 0o500);
    next_run(TEST, &root, &root.home);
    next_run(TEST, &root, &root.home);
    let stuck = planted(&mark, start + 1, &reused(pid, start), &unclaimed(&mark));
    assert_eq!(not_judged(&root.home), vec![stuck.clone(), stuck.clone()], "{}", log(&root.home));
    assert_eq!(names(&root.judging()), vec![name(&mark)], "the mark stays");
    mode(&root.judging(), 0o700);
    next_run(TEST, &root, &root.home);
    assert_eq!(not_judged(&root.home), vec![stuck.clone(), stuck, planted(&mark, start + 1, &reused(pid, start), b"")], "{}", log(&root.home));
    assert!(names(&root.judging()).is_empty());
    next_run(TEST, &root, &root.home);
    assert_eq!(not_judged(&root.home).len(), 3, "{}", log(&root.home));
}

/// A claimed mark whose line advisory.log did not take stays claimed by the
/// run that claimed it. Once that run is gone, a later run claims it again and
/// says it, so a log that could not be written loses no mark.
#[test]
fn a_mark_whose_line_was_not_written_is_reported_by_a_later_run() {
    hook_child();
    const TEST: &str = "a_mark_whose_line_was_not_written_is_reported_by_a_later_run";
    let root = Root::new();
    let (pid, start) = me();
    let mark = plant(&root.home, pid, start + 1);
    fs::create_dir(root.home.join("advisory.log")).unwrap();
    let run = child(&format!("{MODULE}::{TEST}"), &root.root, &root.home, Some("true"));
    let run_pid = run.id();
    ran_quietly(&run.wait_with_output().unwrap());
    let left = names(&root.judging());
    let [claim] = left.as_slice() else { panic!("one file in judging/: {left:?}") };
    assert!(digits_between(claim.as_bytes(), format!("{}.{run_pid}-", name(&mark)).as_bytes(), b".claim"),
        "the mark, claimed by the run that could not say it: {claim}");
    fs::remove_dir(root.home.join("advisory.log")).unwrap();
    next_run(TEST, &root, &root.home);
    assert_eq!(not_judged(&root.home), vec![planted(&mark, start + 1, &reused(pid, start), b"")], "{}", log(&root.home));
    assert!(names(&root.judging()).is_empty(), "{:?}", names(&root.judging()));
}

/// A claim names the mark it took and the run that took it. A claim whose run
/// is gone is reported as the mark it was; a claim whose run is alive stays
/// as it is.
#[test]
fn a_claim_is_reported_once_its_run_is_gone_and_left_while_it_lives() {
    hook_child();
    const TEST: &str = "a_claim_is_reported_once_its_run_is_gone_and_left_while_it_lives";
    let root = Root::new();
    let (pid, start) = me();
    let dropped = plant(&root.home, pid, start + 1);
    fs::rename(&dropped, root.judging().join(format!("{}.{pid}-{}.claim", name(&dropped), start + 2))).unwrap();
    let taken = plant(&root.home, pid, start + 3);
    let live_claim = root.judging().join(format!("{}.{pid}-{start}.claim", name(&taken)));
    fs::rename(&taken, &live_claim).unwrap();
    let bytes = fs::read(&live_claim).unwrap();
    next_run(TEST, &root, &root.home);
    assert_eq!(not_judged(&root.home), vec![planted(&dropped, start + 1, &reused(pid, start), b"")], "{}", log(&root.home));
    assert_eq!(names(&root.judging()), vec![name(&live_claim)]);
    assert_eq!(fs::read(&live_claim).unwrap(), bytes);
    next_run(TEST, &root, &root.home);
    assert_eq!(not_judged(&root.home).len(), 1, "{}", log(&root.home));
}

/// A judgment that returned while `judging/` took no change could not remove
/// its mark. It adds to the mark the record that it returned, and advisory.log
/// says the mark was not removed. No run reports that mark as not judged, and
/// the first run that can claim it removes it.
#[test]
fn a_mark_whose_judgment_returned_is_not_reported() {
    hook_child();
    const TEST: &str = "a_mark_whose_judgment_returned_is_not_reported";
    let root = Root::new();
    let mut held = hold(TEST, &root);
    let mark = root.judging().join(format!("{}-{}.json", held.pid, process::start(held.pid).expect("the kernel's start of the run")));
    assert!(sh::present(&mark), "the run's own mark, while it judges");
    mode(&root.judging(), 0o500);
    let out = held.let_go();
    assert!(out.status.success(), "the run ended by itself: {:?}", out.status);
    let read = jv::read(&fs::read(&mark).unwrap());
    let [_, returned] = read.values.as_slice() else { panic!("the mark and the record that its judgment returned: {:?}", read.values.len()) };
    assert!(!read.failed);
    let crate::json::Value::Obj(fields) = returned else { panic!("an object") };
    let [(key, at)] = fields.as_slice() else { panic!("one field") };
    assert_eq!(key.as_slice(), b"returned_at");
    assert!(jv::text(at).is_some_and(|t| t.len() == 20 && t.ends_with(b"Z")), "a UTC time");
    let unremoved = String::from_utf8(cat(&[b"post-verify: the judgment of this call returned, and its judgment mark ", sh::bytes(&mark),
        b" was not removed: removal returned OS error 13. Command: npm install mark-fixture"])).unwrap();
    assert_eq!(log(&root.home).matches(unremoved.as_str()).count(), 1, "{}", log(&root.home));
    next_run(TEST, &root, &root.home);
    assert!(not_judged(&root.home).is_empty(), "{}", log(&root.home));
    assert_eq!(names(&root.judging()), vec![name(&mark)]);
    mode(&root.judging(), 0o700);
    next_run(TEST, &root, &root.home);
    assert!(not_judged(&root.home).is_empty(), "{}", log(&root.home));
    assert!(names(&root.judging()).is_empty(), "the first run that could claim the mark removed it: {:?}", names(&root.judging()));
}
