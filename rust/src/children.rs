//! The children of this test binary, and the sweep that ends the ones a run
//! that is gone left behind. A row's child is this test binary run again in
//! a role (`owned`), or a program the row starts as this run's own (`mark`).
//! A row ends its children on every way out of the row that the row runs,
//! and a SIGKILL of the row runs none. A child that waits on what only the
//! row would do, that is stopped, or that ignores SIGTERM then outlives its
//! run, past the next run.
//!
//! So every child carries, as its argv[0], a marker that names its run by the
//! pid and the start the kernel stored for it (AGENTS.md, Verification
//! hygiene). Before a run starts its first child, it reads every process the
//! kernel lists and ends each one whose marker names a run that is gone. The
//! marker is what the process runs, read from the kernel: KERN_PROCARGS2 on
//! macOS, /proc/<pid>/cmdline on Linux and WSL1. Nothing here asks ps, and no
//! process is named by the pid a spawn returned. A run is gone on one of the
//! facts `post::holder` gives. A marker that names no run, and a run the
//! kernel gives no answer for, are not known, and the process stays.
//!
//! A program that runs another in its place does not keep the argv[0] it was
//! given. The python3 of Xcode hands its arguments to the framework's Python
//! with that binary's path as argv[0] (measured 2026-11-20 on Darwin 25.2.0).
//! So a fixture a row needs is this test binary in a role, which keeps it.
use crate::post::{holder, Holder};
use std::{ffi::OsString, io::Write, os::unix::{ffi::{OsStrExt, OsStringExt}, process::CommandExt}, path::Path,
    process::{Command, Stdio}, sync::OnceLock, time::{Duration, Instant}};

/// The head of the marker, which `<pid>-<start>` of the run follows. It holds
/// neither marker an older sweep matches by substring, `safedeps-e2e-child`
/// and `safedeps-e2e-owned` (scripts/test/e2e.sh).
pub(crate) const BASE: &[u8] = b"sdeps-row-owner:";

/// How long the sweep waits for a process it sent SIGKILL to be gone, and a
/// row for its children to do what they were started to do. Each takes
/// milliseconds; the bound only ends a row that would wait for ever.
pub(crate) const BOUND: Duration = Duration::from_secs(20);

#[cfg(target_os = "macos")]
const SIGCONT: i32 = 19;
#[cfg(not(target_os = "macos"))]
const SIGCONT: i32 = 18;

extern "C" { fn kill(pid: i32, signal: i32) -> i32; }

fn cat(parts: &[&[u8]]) -> Vec<u8> { parts.concat() }

/// This test process as a run: its pid and the start the kernel stored for
/// it. A run the kernel cannot name starts no child.
pub(crate) fn me() -> (u32, u64) {
    let pid = std::process::id();
    (pid, crate::post::start(pid).expect("the kernel gave no start for this run, so it starts no child"))
}

/// The marker of the run with `pid` and `start`.
pub(crate) fn marker(pid: u32, start: u64) -> Vec<u8> { cat(&[BASE, format!("{pid}-{start}").as_bytes()]) }

/// `command` as a child of this run: its argv[0] is the marker of this run.
/// The sweep of this run's start runs before its first child.
pub(crate) fn mark(command: &mut Command) -> &mut Command {
    swept();
    let (pid, start) = me();
    command.arg0(OsString::from_vec(marker(pid, start)))
}

/// This test binary, to run the test at `path` again as a child of this run,
/// in `cwd`, a row's scratch directory outside the worktree. Its argv[0] is
/// the marker of this run (`mark`), its environment holds PATH alone, and its
/// output goes to pipes.
pub(crate) fn owned(path: &str, cwd: &Path) -> Command {
    let mut command = this_binary(path, cwd);
    mark(&mut command);
    command
}

/// As `owned`, from a fixture that stands in for a fork of itself: the
/// child's argv[0] is this process's own, so the child names the run this
/// process names. A fixture that carries no marker starts no child.
pub(crate) fn forked(path: &str, cwd: &Path) -> Command {
    let name = std::env::args_os().next().filter(|name| name.as_bytes().starts_with(BASE))
        .expect("a fixture that carries no marker starts no child");
    let mut command = this_binary(path, cwd);
    command.arg0(name);
    command
}

fn this_binary(path: &str, cwd: &Path) -> Command {
    let mut command = Command::new(std::env::current_exe().unwrap());
    command.args(["--exact", path, "--nocapture", "--test-threads=1"])
        .env_clear().env("PATH", "/usr/bin:/bin").current_dir(cwd).stdout(Stdio::piped()).stderr(Stdio::piped());
    command
}

/// What the sweep of a run's start did: the marked processes it ended, each
/// with its pid, its start and the fact that its run is gone, and a sentence
/// for each marked process it left because what it read of it is not known.
#[derive(Default)]
struct Swept { ended: Vec<(u32, u64, Vec<u8>)>, left: Vec<Vec<u8>> }

static SWEPT: OnceLock<Swept> = OnceLock::new();

/// The sweep of this run's start. It runs once, before the run's first child.
fn swept() -> &'static Swept { SWEPT.get_or_init(sweep) }

/// A marked process can be the run another one names, and that run is gone
/// only once it is ended, so a pass that ends something is followed by
/// another.
const PASSES: usize = 4;

fn sweep() -> Swept {
    let mut swept = Swept::default();
    for _ in 0..PASSES {
        let Some(pids) = pids() else { swept.left = vec![b"no process was read: the kernel listed none".to_vec()]; break };
        let mut left = Vec::new();
        let found: Vec<(u32, u64, Vec<u8>)> = pids.into_iter().filter_map(|pid| judge(pid, &mut left)).collect();
        swept.left = left;
        if found.is_empty() { break }
        for (pid, start, _) in &found { end(*pid, *start) }
        let until = Instant::now() + BOUND;
        while let Some((pid, ..)) = found.iter().find(|(pid, start, _)| !matches!(holder(*pid, *start), Holder::Gone(_))) {
            assert!(Instant::now() < until, "the sweep sent SIGKILL to pid {pid}, and it was not gone within {BOUND:?}");
            std::thread::sleep(Duration::from_millis(20));
        }
        swept.ended.extend(found);
    }
    for (pid, start, fact) in &swept.ended {
        eprintln!("# note - this run's start ended pid {pid} (start {start}), a marked process whose run is gone: {}", String::from_utf8_lossy(fact))
    }
    for why in &swept.left { eprintln!("# note - {}", String::from_utf8_lossy(why)) }
    swept
}

/// What the sweep makes of the run a marker names after BASE.
enum Run { Live, Gone(Vec<u8>), NotKnown(Vec<u8>) }

fn run_of(rest: &[u8]) -> Run {
    let Some((pid, start)) = run_named(rest) else { return Run::NotKnown(b"its marker names no run".to_vec()) };
    match holder(pid, start) {
        Holder::Running => Run::Live,
        Holder::Gone(fact) => Run::Gone(fact),
        Holder::Unknown => Run::NotKnown(format!("the kernel gave no answer for its run, pid {pid} with the start {start}").into_bytes()),
    }
}

/// The run a marker names after BASE: `<pid>-<start>`, each in decimal with no
/// leading zero, the pid a u32 and the start not 0, which is never a start the
/// kernel stored.
fn run_named(rest: &[u8]) -> Option<(u32, u64)> {
    let (pid, start) = rest.split_at(rest.iter().position(|b| *b == b'-')?);
    let number = |digits: &[u8]| -> Option<u64> {
        if digits.first().is_none_or(|b| *b == b'0') || !digits.iter().all(u8::is_ascii_digit) { return None }
        std::str::from_utf8(digits).ok()?.parse().ok()
    };
    Some((u32::try_from(number(pid)?).ok()?, number(&start[1..])?))
}

/// The marked process `pid`, with its start and the fact that its run is
/// gone, when the sweep ends it. A process whose argv[0] cannot be read is not
/// known to carry the marker (another user's process answers so), and it
/// stays with nothing said. A marked process that stays because what was read
/// of it is not known goes to `left`, with what that is.
fn judge(pid: u32, left: &mut Vec<Vec<u8>>) -> Option<(u32, u64, Vec<u8>)> {
    if pid == std::process::id() { return None }
    let before = crate::post::start(pid);
    let name = arg0(pid)?;
    let rest = name.strip_prefix(BASE)?;
    let stays = |why: &[u8]| cat(&[b"pid ", pid.to_string().as_bytes(), b", whose argv[0] is ", &name, b", stays: ", why]);
    let Some(start) = before.filter(|start| crate::post::start(pid) == Some(*start)) else {
        left.push(stays(b"the kernel gave it no one start while its argv[0] was read"));
        return None
    };
    match run_of(rest) {
        Run::Live => None,
        Run::Gone(fact) => Some((pid, start, fact)),
        Run::NotKnown(why) => { left.push(stays(&why)); None }
    }
}

/// SIGCONT, so that a stopped process takes what follows, then SIGKILL, each
/// sent only while the kernel holds `pid` with `start`.
fn end(pid: u32, start: u64) {
    let Ok(target) = i32::try_from(pid) else { return };
    for signal in [SIGCONT, crate::os::SIGKILL] {
        if !matches!(holder(pid, start), Holder::Running) { return }
        unsafe { kill(target, signal); }
    }
}

/// Every pid the kernel lists. With no buffer, proc_listallpids answers how
/// many there are, give or take (measured 2026-11-20 on Darwin 25.2.0: 788,
/// then 769 listed). A list that fills its buffer may have been cut short, so
/// it is read again into a larger one.
#[cfg(target_os = "macos")]
fn pids() -> Option<Vec<u32>> {
    extern "C" { fn proc_listallpids(buffer: *mut std::ffi::c_void, size: i32) -> i32; }
    let mut room = usize::try_from(unsafe { proc_listallpids(std::ptr::null_mut(), 0) }).ok()?;
    for _ in 0..4 {
        room += 256;
        let mut pids = vec![0i32; room];
        let listed = usize::try_from(unsafe { proc_listallpids(pids.as_mut_ptr().cast(), i32::try_from(room * 4).ok()?) }).ok()?;
        if listed < room {
            pids.truncate(listed);
            return Some(pids.into_iter().filter_map(|pid| u32::try_from(pid).ok()).collect())
        }
        room *= 2;
    }
    None
}

#[cfg(not(target_os = "macos"))]
fn pids() -> Option<Vec<u32>> {
    Some(std::fs::read_dir("/proc").ok()?.filter_map(|entry| entry.ok()?.file_name().to_str()?.parse().ok()).collect())
}

/// The argv[0] of `pid`, as the kernel holds it. KERN_PROCARGS2 gives argc,
/// the path exec was given and the NULs after it, then argv: xnu
/// bsd/kern/kern_sysctl.c, sysctl_procargsx, and measured 2026-11-20 on Darwin
/// 25.2.0. It answers EINVAL for a pid that holds no process and for another
/// user's process alike, so a failed read says neither.
#[cfg(target_os = "macos")]
fn arg0(pid: u32) -> Option<Vec<u8>> {
    use std::ffi::c_void;
    extern "C" { fn sysctl(name: *mut i32, length: u32, old: *mut c_void, size: *mut usize, new: *mut c_void, new_size: usize) -> i32; }
    // CTL_KERN 1, KERN_ARGMAX 8 and KERN_PROCARGS2 49, sys/sysctl.h in the Darwin SDK.
    let (mut max, mut size) = (0i32, std::mem::size_of::<i32>());
    let mut name = [1, 8];
    if unsafe { sysctl(name.as_mut_ptr(), 2, (&mut max as *mut i32).cast(), &mut size, std::ptr::null_mut(), 0) } != 0 { return None }
    let mut area = vec![0u8; usize::try_from(max).ok()?];
    let mut size = area.len();
    let mut name = [1, 49, i32::try_from(pid).ok()?];
    if unsafe { sysctl(name.as_mut_ptr(), 3, area.as_mut_ptr().cast(), &mut size, std::ptr::null_mut(), 0) } != 0 { return None }
    let area = area.get(..size)?;
    if i32::from_ne_bytes(area.get(..4)?.try_into().ok()?) < 1 { return None }
    let rest = &area[4..];
    let rest = &rest[rest.iter().position(|b| *b == 0)?..];
    let rest = &rest[rest.iter().position(|b| *b != 0)?..];
    Some(rest[..rest.iter().position(|b| *b == 0).unwrap_or(rest.len())].to_vec())
}

/// The argv[0] of `pid`: /proc/<pid>/cmdline holds argv, each ending in NUL.
#[cfg(not(target_os = "macos"))]
fn arg0(pid: u32) -> Option<Vec<u8>> {
    let line = std::fs::read(format!("/proc/{pid}/cmdline")).ok()?;
    Some(line[..line.iter().position(|b| *b == 0)?].to_vec())
}

/// Set in a child of this test binary, the child is the start of another run:
/// it sweeps, writes what the sweep did, and exits.
const START: &str = "SAFEDEPS_ROW_START";

/// The role of the start of another run (`next_start`). A row whose test
/// `next_start` runs calls this first, and goes on only as the row itself.
pub(crate) fn role() {
    if std::env::var_os(START).is_none() { return }
    let swept = swept();
    // After the harness's own `test <name> ... `, on lines of their own.
    let mut said = b"\n".to_vec();
    for (pid, start, fact) in &swept.ended {
        said.extend(cat(&[b"swept\tended\t", pid.to_string().as_bytes(), b"\t", start.to_string().as_bytes(), b"\t", fact, b"\n"]));
    }
    for why in &swept.left { said.extend(cat(&[b"swept\tleft\t", why, b"\n"])) }
    let mut out = std::io::stdout();
    out.write_all(&said).unwrap();
    out.flush().unwrap();
    std::process::exit(0)
}

/// The start of another run, as a child of this row that runs the test at
/// `path`, which calls `role` first: the processes its sweep ended, each with
/// its pid, its start and the fact that its run is gone, and what it left.
pub(crate) fn next_start(path: &str, cwd: &Path) -> (Vec<(u32, u64, Vec<u8>)>, Vec<Vec<u8>>) {
    let out = owned(path, cwd).env(START, "1").stdin(Stdio::null()).output().unwrap();
    assert!(out.status.success(), "the other run's start ended by itself: {:?}\n{}", out.status, String::from_utf8_lossy(&out.stderr));
    let (mut ended, mut left) = (Vec::new(), Vec::new());
    for line in out.stdout.split(|b| *b == b'\n') {
        if let Some(rest) = line.strip_prefix(b"swept\tended\t") {
            let fields: Vec<&[u8]> = rest.splitn(3, |b| *b == b'\t').collect();
            let [pid, start, fact] = fields.as_slice() else { panic!("{}", String::from_utf8_lossy(line)) };
            let number = |digits: &[u8]| std::str::from_utf8(digits).unwrap().parse::<u64>().unwrap();
            ended.push((u32::try_from(number(*pid)).unwrap(), number(*start), fact.to_vec()));
        } else if let Some(why) = line.strip_prefix(b"swept\tleft\t") {
            left.push(why.to_vec());
        }
    }
    (ended, left)
}

/// What a sweep ended, for a row's message.
pub(crate) fn shown(ended: &[(u32, u64, Vec<u8>)]) -> String {
    ended.iter().map(|(pid, start, fact)| format!("{pid}-{start}: {}", String::from_utf8_lossy(fact))).collect::<Vec<_>>().join("; ")
}

/// The fact that a sweep ended `pid` with `start` for, if it ended it.
pub(crate) fn ended_for(ended: &[(u32, u64, Vec<u8>)], pid: u32, start: u64) -> Option<Vec<u8>> {
    ended.iter().find(|(p, s, _)| *p == pid && *s == start).map(|(_, _, fact)| fact.clone())
}

/// `fact` says that the run with pid `run`, which this row killed and reaped,
/// is gone: the kernel holds no process under its pid, or holds another one
/// it handed the pid to since.
pub(crate) fn says_gone(fact: &[u8], run: u32) -> bool {
    let reused = format!("pid {run} is another process now: the kernel stored the start ");
    fact == format!("pid {run} is not running").as_bytes()
        || fact.strip_prefix(reused.as_bytes()).and_then(|rest| rest.strip_suffix(b" for it"))
            .is_some_and(|digits| !digits.is_empty() && digits.iter().all(u8::is_ascii_digit))
}

pub(crate) fn running(pid: u32, start: u64) -> bool { matches!(holder(pid, start), Holder::Running) }

/// A process a killed run left, which is no child of this row. On every way
/// out of the row it is ended, by its pid and start, if it still runs.
pub(crate) struct Stray(pub(crate) u32, pub(crate) u64);
impl Drop for Stray { fn drop(&mut self) { end(self.0, self.1) } }
