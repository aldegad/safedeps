//! The rows of the sweep at the start of a run (`crate::children`) with a
//! post run as the child. Some rows leave a post run waiting on a FIFO whose
//! other end only the row opens. `tests::Reaped` ends such a child on every
//! way out of the row that the row runs, and a SIGKILL of the row runs none.
//! A child waiting to open that FIFO then waits for ever, past the next run,
//! unless the start of the next run ends it.
use super::{tests::{child, hook_child, Reaped, BOUND}, unfinished_tests::Root};
use crate::children::{ended_for, marker, me, next_start, owned, running, says_gone, shown, Stray, BASE};
use crate::post::{process, report::cat};
use std::{ffi::OsString, fs, os::unix::{ffi::OsStringExt, process::{CommandExt, ExitStatusExt}}, path::{Path, PathBuf},
    process::{Command, Stdio}, time::{Duration, Instant}};

const MODULE: &str = "post::run::children";

/// Set in a child of this test binary, it names a row's root, and the child
/// is a run that starts one post run there, writes the post run's pid and
/// start to `held`, and waits for its stdin to end. The post run waits to open
/// the FIFO `confirmed` in the home, which no process opens to write, so it
/// waits until it is ended.
const RUN: &str = "SAFEDEPS_ROW_RUN";

/// The roles a child of a row plays: the post hook (`hook_child`), RUN and
/// the start of another run (`crate::children::role`). A row runs this first,
/// and goes on only as the row itself.
fn roles(path: &str) {
    hook_child();
    crate::children::role();
    if let Some(root) = std::env::var_os(RUN) {
        let root = PathBuf::from(root);
        let post = child(path, &root, &root.join("home"), None);
        let start = process::start(post.id()).expect("the kernel's start of the post run");
        fs::write(root.join("held.tmp"), format!("{} {start}", post.id())).unwrap();
        fs::rename(root.join("held.tmp"), root.join("held")).unwrap();
        let _ = std::io::copy(&mut std::io::stdin(), &mut std::io::sink());
        std::process::exit(0)
    }
}

fn fifo(path: &Path) { assert!(Command::new("mkfifo").arg(path).status().unwrap().success()) }

/// `cat` with `name` as its argv[0], in `cwd`, waiting on its stdin, which
/// this row holds, so it ends by itself once the row is gone. Its pid and
/// start come with it.
fn spawn_marked(name: &[u8], cwd: &Path) -> (Reaped, u32, u64) {
    let spawned = Command::new("/bin/cat").arg0(OsString::from_vec(name.to_vec())).current_dir(cwd)
        .stdin(Stdio::piped()).stdout(Stdio::null()).stderr(Stdio::null()).spawn().unwrap();
    let pid = spawned.id();
    (Reaped(Some(spawned)), pid, process::start(pid).expect("the kernel's start of the marked process"))
}

/// (가) A run killed while its child waits leaves that child, and the start of
/// the next run ends it. Here the run is a child of this row that starts a
/// post run through `tests::child`, as every row does, and the post run waits
/// to open a FIFO only its run would ever open. The row kills the run with
/// SIGKILL, so no way out of the run runs. A marked process whose run's pid
/// the kernel handed out again is ended too: its marker names this row's pid
/// with another start.
#[test]
fn a_child_a_killed_run_left_is_ended_at_the_next_runs_start() {
    const TEST: &str = "a_child_a_killed_run_left_is_ended_at_the_next_runs_start";
    let path = format!("{MODULE}::{TEST}");
    roles(&path);
    let root = Root::new();
    fifo(&root.home.join("confirmed"));
    let mut run = Reaped(Some(owned(&path, &root.root).env(RUN, &root.root).stdin(Stdio::piped()).spawn().unwrap()));
    let held = root.root.join("held");
    let until = Instant::now() + BOUND;
    while !held.exists() {
        assert!(!run.ended() && Instant::now() < until, "the run started its post run within {BOUND:?}");
        std::thread::sleep(Duration::from_millis(20));
    }
    let text = fs::read_to_string(&held).unwrap();
    let (pid, start) = text.split_once(' ').map(|(pid, start)| (pid.parse::<u32>().unwrap(), start.parse::<u64>().unwrap())).unwrap();
    let _stray = Stray(pid, start);
    let mut killed = run.0.take().unwrap();
    let run_pid = killed.id();
    killed.kill().unwrap();
    assert_eq!(killed.wait().unwrap().signal(), Some(9), "the row killed the run");
    assert!(running(pid, start), "the post run outlived its run");
    let (row, row_start) = me();
    let (mut reused, reused_pid, reused_start) = spawn_marked(&marker(row, row_start + 1), &root.root);
    let (ended, _) = next_start(&path, &root.root);
    let fact = ended_for(&ended, pid, start)
        .unwrap_or_else(|| panic!("the next run's start ended the post run its killed run left: {}", shown(&ended)));
    assert!(says_gone(&fact, run_pid), "the fact that its run is gone: {}", String::from_utf8_lossy(&fact));
    assert!(!running(pid, start), "the post run is gone");
    assert_eq!(ended_for(&ended, reused_pid, reused_start),
        Some(format!("pid {row} is another process now: the kernel stored the start {row_start} for it").into_bytes()),
        "the next run's start ended the marked process of a run whose pid is this row's now: {}", shown(&ended));
    assert_eq!(reused.0.take().unwrap().wait().unwrap().signal(), Some(9), "by SIGKILL");
}

/// (나) The start of another run leaves the children of a run that is alive,
/// since a suite of another checkout can run beside this one on the same
/// machine. Here the run that is alive is this row, its child is a post run
/// waiting to open the FIFO, and the other run's start is a child of this row.
#[test]
fn a_child_of_a_run_that_is_alive_is_left_by_another_runs_start() {
    const TEST: &str = "a_child_of_a_run_that_is_alive_is_left_by_another_runs_start";
    let path = format!("{MODULE}::{TEST}");
    roles(&path);
    let root = Root::new();
    fifo(&root.home.join("confirmed"));
    let live = Reaped(Some(child(&path, &root.root, &root.home, None)));
    let pid = live.0.as_ref().unwrap().id();
    let start = process::start(pid).expect("the kernel's start of the post run");
    let (ended, _) = next_start(&path, &root.root);
    assert!(!ended.iter().any(|(p, ..)| *p == pid), "the other run's start ended this run's child: {}", shown(&ended));
    assert!(running(pid, start), "it still waits, as it was");
}

/// (다) A marked process whose marker names no run, or names a run the kernel
/// gives no answer for, is not known to be the child of a run that is gone,
/// and the start of another run leaves it. Each one here is `cat` waiting on
/// its stdin, which this row holds.
#[test]
fn a_marked_process_whose_run_is_not_known_is_left() {
    const TEST: &str = "a_marked_process_whose_run_is_not_known_is_left";
    let path = format!("{MODULE}::{TEST}");
    roles(&path);
    let root = Root::new();
    let (row, row_start) = me();
    let runs: [String; 12] = ["".into(), "x-1".into(), "0-5".into(), "5".into(), "5-".into(), "-5".into(), format!("{row}-0"),
        format!("0{row}-{row_start}"), format!("{row}-{row_start}-1"), format!("{row}-{row_start}x"), "4294967296-5".into(),
        // A pid the kernel never hands out, for which `process::holder` gives no answer.
        "2147483648-5".into()];
    let names: Vec<Vec<u8>> = runs.iter().map(|run| cat(&[BASE, run.as_bytes()])).collect();
    let marked: Vec<(Reaped, u32, u64)> = names.iter().map(|name| spawn_marked(name, &root.root)).collect();
    let (ended, _) = next_start(&path, &root.root);
    for (name, (_, pid, start)) in names.iter().zip(&marked) {
        assert!(!ended.iter().any(|(p, ..)| p == pid), "{} was ended: {}", String::from_utf8_lossy(name), shown(&ended));
        assert!(running(*pid, *start), "{} still runs, as it was", String::from_utf8_lossy(name));
    }
}
