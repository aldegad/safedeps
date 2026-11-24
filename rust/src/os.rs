//! The few things the hook asks of the system that std does not offer: the
//! process's umask, a signal to a process group, a local time with its zone
//! offset, a file lock, and a monotonic clock every process of the host reads
//! alike. They are libc's own functions, declared here, so the crate still
//! names no dependency.
//!
//! The rest is how the bash hooks' helper commands print what they read
//! (`stat`, `ls -di`, `date`, `realpath`), because the other hook compares
//! those texts with its own.

use std::os::unix::fs::MetadataExt;
use std::path::Path;

#[repr(C)]
struct Tm {
    tm_sec: i32,
    tm_min: i32,
    tm_hour: i32,
    tm_mday: i32,
    tm_mon: i32,
    tm_year: i32,
    tm_wday: i32,
    tm_yday: i32,
    tm_isdst: i32,
    tm_gmtoff: i64,
    tm_zone: *const u8,
}

extern "C" {
    fn access(path: *const std::ffi::c_char, mode: i32) -> i32;
    fn mkdtemp(template: *mut std::ffi::c_char) -> *mut std::ffi::c_char;
    fn umask(mask: u32) -> u32;
    fn kill(pid: i32, sig: i32) -> i32;
    fn waitid(kind: i32, id: u32, info: *mut WaitInfo, options: i32) -> i32;
    fn localtime_r(t: *const i64, tm: *mut Tm) -> *mut Tm;
    fn newlocale(mask: i32, name: *const std::ffi::c_char, base: *mut std::ffi::c_void) -> *mut std::ffi::c_void;
    fn freelocale(locale: *mut std::ffi::c_void);
    fn isprint_l(c: i32, locale: *mut std::ffi::c_void) -> i32;
    #[cfg(not(target_os = "macos"))]
    fn iswprint_l(c: u32, locale: *mut std::ffi::c_void) -> i32;
    fn flock(fd: i32, operation: i32) -> i32;
    fn clock_gettime(clock: i32, tp: *mut Timespec) -> i32;
}

/// struct timespec: time_t and long, 64 bits each on the three targets
/// (Darwin arm64 and x86_64, Linux x86_64 musl).
#[repr(C)]
struct Timespec {
    tv_sec: i64,
    tv_nsec: i64,
}

/// Printable units for the hook shell's printf %q. Darwin's system bash
/// uses byte ctype, including in UTF-8 locales; the GNU bash on the Linux
/// test host uses wide characters. A private locale avoids changing the
/// process locale while other system helpers are active.
pub fn bash_quote_units(s: &[u8]) -> Vec<(usize, bool)> {
    #[cfg(target_os = "macos")]
    let (mask, widths) = (2, vec![1; s.len()]);
    #[cfg(not(target_os = "macos"))]
    let (mask, widths) = (1, bash_chars(s));
    let locale = unsafe { newlocale(mask, b"\0".as_ptr().cast(), std::ptr::null_mut()) };
    let mut at = 0;
    let mut out = Vec::with_capacity(widths.len());
    for n in widths {
        let printable = if locale.is_null() { (32..127).contains(&s[at]) }
            else {
                #[cfg(target_os = "macos")]
                { unsafe { isprint_l(s[at] as i32, locale) != 0 } }
                #[cfg(not(target_os = "macos"))]
                { if n == 1 { unsafe { isprint_l(s[at] as i32, locale) != 0 } }
                  else { let c = std::str::from_utf8(&s[at..at+n]).unwrap().chars().next().unwrap(); unsafe { iswprint_l(c as u32, locale) != 0 } } }
            };
        out.push((n, printable)); at += n;
    }
    if !locale.is_null() { unsafe { freelocale(locale) } }
    out
}

/// The hook shell's -r test, including ACLs and symlink targets.
pub fn readable(path: &Path) -> bool {
    accessible(path,4)
}
pub fn executable(path: &Path) -> bool {
    accessible(path,1)
}
fn accessible(path: &Path,mode:i32) -> bool {
    use std::os::unix::ffi::OsStrExt;
    let Ok(path)=std::ffi::CString::new(path.as_os_str().as_bytes()) else { return false };
    unsafe { access(path.as_ptr(),mode)==0 }
}

/// Exclusively claim a scratch directory using libc's mkdtemp, as the shell
/// helper does. The caller owns removal. No pid/RANDOM naming convention.
pub fn scratch_dir(prefix: &str) -> std::io::Result<std::path::PathBuf> {
    use std::os::unix::ffi::OsStringExt;
    let base = std::env::var_os("TMPDIR").filter(|v| !v.is_empty()).unwrap_or_else(|| "/tmp".into());
    let mut bytes = std::path::PathBuf::from(base).join(format!("{}.XXXXXX", prefix)).into_os_string().into_vec();
    if bytes.contains(&0) { return Err(std::io::Error::new(std::io::ErrorKind::InvalidInput, "NUL in scratch path")); }
    bytes.push(0);
    if unsafe { mkdtemp(bytes.as_mut_ptr().cast()) }.is_null() { return Err(std::io::Error::last_os_error()); }
    bytes.pop();
    Ok(std::ffi::OsString::from_vec(bytes).into())
}

/// flock(2)'s exclusive lock, its flag not to block, and its unlock. The
/// numbers are the same on macOS and Linux.
const LOCK_EX: i32 = 2;
const LOCK_NB: i32 = 4;
const LOCK_UN: i32 = 8;

/// The host's monotonic clock: CLOCK_UPTIME_RAW on macOS (<time.h>: 8, the
/// value mach_absolute_time gives, clock_gettime(3)), CLOCK_MONOTONIC on
/// Linux and WSL1 (<linux/time.h>: 1, "a nonsettable system-wide clock",
/// clock_gettime(2)). Each is one clock for every process of the host, so a
/// reading one process writes down is a time another can compare with its
/// own. They are the clocks std's Instant reads on each, so a wait counted
/// on this clock is the length it was when it was counted on Instant.
#[cfg(target_os = "macos")]
const HOST_CLOCK: i32 = 8;
#[cfg(not(target_os = "macos"))]
const HOST_CLOCK: i32 = 1;

/// A reading of the host's monotonic clock, in nanoseconds since a point
/// the host fixed when it started.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd)]
pub struct HostTime(pub u64);

impl HostTime {
    /// The time `d` after this one.
    pub fn after(self, d: std::time::Duration) -> Self {
        Self(self.0.saturating_add(u64::try_from(d.as_nanos()).unwrap_or(u64::MAX)))
    }
}

/// The host's monotonic clock, now, or the error clock_gettime(2) returned.
/// It fails for a clock the system does not have. The caller answers that
/// error as its own outcome, so a clock that cannot be read refuses what
/// waited on it and does not end the process.
pub fn host_clock() -> std::io::Result<HostTime> {
    let mut t = Timespec { tv_sec: 0, tv_nsec: 0 };
    if unsafe { clock_gettime(HOST_CLOCK, &mut t) } != 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(HostTime((t.tv_sec as u64).saturating_mul(1_000_000_000).saturating_add(t.tv_nsec as u64)))
}

/// One try for flock(2)'s exclusive lock on the open file description of
/// `file`, which does not wait: true where the lock was granted, false where
/// another description holds it.
pub fn try_flock(file: &std::fs::File) -> std::io::Result<bool> {
    use std::os::unix::io::AsRawFd;
    loop {
        if unsafe { flock(file.as_raw_fd(), LOCK_EX | LOCK_NB) } == 0 {
            return Ok(true);
        }
        let e = std::io::Error::last_os_error();
        match e.kind() {
            std::io::ErrorKind::Interrupted => continue,
            std::io::ErrorKind::WouldBlock => return Ok(false),
            _ => return Err(e),
        }
    }
}

/// Whether `at` is past a wait of `wait` from `start`. The wait runs to its
/// last nanosecond: `at` exactly `wait` after `start` is within it, and a
/// nanosecond later is past it.
fn past_the_wait(start: HostTime, wait: std::time::Duration, at: HostTime) -> bool {
    at > start.after(wait)
}

/// flock(2)'s exclusive lock on the open file description of `file`, which
/// may be open for reading alone, tried until it is granted within `wait`.
/// The wait starts when this call does. After every try, refused or granted,
/// `holder` is told the time the try ended and says when the hold the wait
/// is behind began: the one that refused the try, or, for a try that was
/// granted, the last one, which just let the lock go. Where it cannot say it
/// gives nothing. A start it gives starts the wait there, if that is later
/// than this call's start, and nothing keeps the start the wait has. A try
/// that ended past the wait from that start is a deadline outcome, whether
/// the lock refused it or granted it, and a lock granted that late is let go
/// first. So a lock that changes hands is waited for however long it stays
/// taken, and one hold that keeps it for `wait` is a deadline outcome, never
/// a lock taken anyway. Answers the time read just before the try that was
/// granted: the start of this hold, never later than the lock was taken. The
/// lock goes when the file is closed, by a drop or by the end of the process,
/// so a holder that dies leaves no lock behind, as a lock directory does.
///
/// `clock` is the clock the wait is counted on: `host_clock`, or a test's. A
/// read of it that fails is the lock's outcome, with the error it returned,
/// as a try that fails is. That holds for the read at the start, the one
/// before a try and the one after it. Where the try before that read was
/// granted, the lock is let go first. So no answer but a lock taken in time
/// keeps the lock.
pub fn flock_within(file: &std::fs::File, wait: std::time::Duration, mut clock: impl FnMut() -> std::io::Result<HostTime>, mut holder: impl FnMut(HostTime) -> Option<HostTime>) -> Result<HostTime, crate::outcome::Outcome> {
    use crate::outcome::Outcome;
    use std::os::unix::io::AsRawFd;
    let returned = |e: std::io::Error| Outcome::Io(Err(e));
    let began = clock().map_err(returned)?;
    let mut start = began;
    loop {
        let tried = clock().map_err(returned)?;
        let granted = try_flock(file).map_err(returned)?;
        let judged = clock().map_err(returned).and_then(|ended| {
            if let Some(held) = holder(ended) {
                start = held.max(began);
            }
            if past_the_wait(start, wait, ended) { Err(Outcome::Deadline) } else { Ok(()) }
        });
        match judged {
            Ok(()) if granted => return Ok(tried),
            Ok(()) => std::thread::sleep(std::time::Duration::from_millis(10)),
            Err(refused) => {
                if granted && unsafe { flock(file.as_raw_fd(), LOCK_UN) } != 0 {
                    return Err(Outcome::Io(Err(std::io::Error::last_os_error())));
                }
                return Err(refused);
            }
        }
    }
}

#[cfg(test)]
mod lock_tests {
    use super::*;
    use crate::outcome::Outcome;
    use std::fs::{self, File};
    use std::time::Duration;

    /// A directory of the test's own, removed with its files when dropped.
    struct Scratch(std::path::PathBuf);
    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn a_lock_granted_once_the_wait_ran_out_is_a_deadline_and_is_let_go() {
        // The hold that refused the first try began as that try ended, and
        // lets the lock go then. The next try comes after ten milliseconds
        // of sleep and is granted, past the five the wait has: the wait ran
        // out before that try ended, so the answer is the deadline, and the
        // lock the try was granted is let go. A wait judged only at the tries
        // the lock refused kept the lock.
        let dir = Scratch(scratch_dir("safedeps-os-lock-test").unwrap());
        let locked = dir.0.join("locked");
        let held = File::create(&locked).unwrap();
        assert!(flock_within(&held, Duration::from_secs(10), host_clock, |_| None).is_ok(), "another held the lock");
        let mut held = Some(held);
        let mut began = None;
        let waiter = File::open(&locked).unwrap();
        let answer = flock_within(&waiter, Duration::from_millis(5), host_clock, |now| {
            held = None;
            Some(*began.get_or_insert(now))
        });
        assert!(matches!(answer, Err(Outcome::Deadline)), "{answer:?}");
        let other = File::open(&locked).unwrap();
        assert!(flock_within(&other, Duration::from_secs(10), host_clock, |_| None).is_ok(), "the waiter kept the lock it was granted");
    }

    #[test]
    fn a_granted_try_is_judged_from_the_start_the_holder_gives_for_it() {
        // The hold that refused the first try began as that try ended, and
        // lets the lock go then. Before the next try, another hold took the
        // lock and let it go: the holder says it began a millisecond before
        // that try ended. The wait counts from there, so the try is within
        // it and the lock is taken, though the wait from the first hold's
        // start ran out before the try ended. A granted try judged from the
        // start the refused tries had was refused, for a hold it never waited
        // behind.
        let dir = Scratch(scratch_dir("safedeps-os-lock-test").unwrap());
        let locked = dir.0.join("locked");
        let held = File::create(&locked).unwrap();
        assert!(flock_within(&held, Duration::from_secs(10), host_clock, |_| None).is_ok(), "another held the lock");
        let mut held = Some(held);
        let waiter = File::open(&locked).unwrap();
        let answer = flock_within(&waiter, Duration::from_millis(5), host_clock, |now| match held.take() {
            Some(_) => Some(now),
            None => Some(HostTime(now.0.saturating_sub(1_000_000))),
        });
        assert!(answer.is_ok(), "{answer:?}");
    }

    #[test]
    fn a_clock_that_cannot_be_read_is_the_locks_outcome_and_keeps_no_lock() {
        // The wait reads its clock five times here: at its start (1), before
        // the first try (2), after it (3), before the second (4) and after it
        // (5). `held` refuses the first try and lets the lock go as the
        // holder hears of it, so the second try is granted. Each read in
        // turn fails. The answer is the clock's own error as the lock's
        // outcome, the wait reads the clock no more, and another open of the
        // file takes the lock at once. Read 5 falls after a try the lock
        // granted: a wait that ended there without letting the lock go kept
        // it, and the clock read panicked before this.
        let dir = Scratch(scratch_dir("safedeps-os-lock-test").unwrap());
        let locked = dir.0.join("locked");
        File::create(&locked).unwrap();
        for failing in 1..=5 {
            let held = File::open(&locked).unwrap();
            assert!(try_flock(&held).unwrap(), "read {failing}: another held the lock");
            let mut held = Some(held);
            let mut reads = 0;
            let waiter = File::open(&locked).unwrap();
            let answer = flock_within(
                &waiter,
                Duration::from_secs(10),
                || {
                    reads += 1;
                    if reads == failing { Err(std::io::Error::from_raw_os_error(22)) } else { host_clock() }
                },
                |_| {
                    held = None;
                    None
                },
            );
            match &answer {
                Err(Outcome::Io(Err(e))) => assert_eq!(e.raw_os_error(), Some(22), "read {failing}: {answer:?}"),
                _ => panic!("read {failing}: {answer:?}"),
            }
            assert_eq!(reads, failing, "read {failing}: the wait read the clock again after a read failed");
            drop(held);
            let other = File::open(&locked).unwrap();
            assert!(try_flock(&other).unwrap(), "read {failing}: the waiter kept the lock");
        }
    }

    #[test]
    fn the_wait_runs_to_its_last_nanosecond() {
        // The one comparison every try is judged by, refused or granted: a
        // try that ends the wait after its start is within it, and one that
        // ends a nanosecond later is past it.
        let start = HostTime(1_000_000_000);
        let wait = Duration::from_secs(10);
        assert!(!past_the_wait(start, wait, start));
        assert!(!past_the_wait(start, wait, start.after(wait)));
        assert!(past_the_wait(start, wait, HostTime(start.after(wait).0 + 1)));
    }
}

pub const SIGTERM: i32 = 15;
pub const SIGKILL: i32 = 9;

/// open(2)'s O_NONBLOCK, which `OpenOptionsExt::custom_flags` takes: an open
/// of a FIFO returns at once instead of waiting for a writer, and a read of a
/// regular file is the same with it or without. <sys/fcntl.h> on macOS,
/// asm-generic/fcntl.h on Linux.
#[cfg(target_os = "macos")]
pub const O_NONBLOCK: i32 = 0x0004;
#[cfg(not(target_os = "macos"))]
pub const O_NONBLOCK: i32 = 0o4000;

pub fn set_umask(mask: u32) {
    unsafe {
        umask(mask);
    }
}

/// A signal to every process of the group `pgid` leads.
pub fn kill_group(pgid: u32, sig: i32) {
    unsafe {
        kill(-(pgid as i32), sig);
    }
}

// siginfo_t is 104 bytes on the supported Darwin ABIs and 128 on Linux;
// both start with int si_signo, si_errno, si_code at offsets 0, 4, 8 on
// Darwin arm64/x86_64 and Linux x86_64. The remaining fields are not read.
// Sources: XNU bsd/sys/signal.h and Linux include/uapi/asm-generic/siginfo.h.
// Keep storage large/aligned enough for either ABI; zero it for WNOHANG.
#[repr(C, align(8))]
struct WaitInfo { signo: i32, errno: i32, code: i32, rest: [u8; 116] }

/// Observe one owned child's exit without consuming its status or freeing
/// its pid. POSIX waitid(WNOWAIT) lets the caller clean its process group
/// before wait() reaps the leader. No signal is sent by this function.
pub fn child_exited_unreaped(pid: u32) -> std::io::Result<bool> {
    #[cfg(target_os = "macos")]
    const WNOWAIT: i32 = 0x20;
    #[cfg(not(target_os = "macos"))]
    const WNOWAIT: i32 = 0x01000000;
    loop {
        let mut info = WaitInfo { signo: 0, errno: 0, code: 0, rest: [0; 116] };
        // P_PID = 1, WEXITED = 4, WNOHANG = 1 in sys/wait.h on both targets.
        if unsafe { waitid(1, pid, &mut info, 4 | 1 | WNOWAIT) } == 0 {
            // Both signal.h definitions: CLD_EXITED=1, CLD_KILLED=2,
            // CLD_DUMPED=3. A stop/trap/continue notification is not exit,
            // even when waitid reports it with only WEXITED requested.
            return Ok(info.signo != 0 && matches!(info.code, 1 | 2 | 3));
        }
        let err = std::io::Error::last_os_error();
        if err.kind() != std::io::ErrorKind::Interrupted { return Err(err) }
    }
}

#[cfg(test)]
mod wait_tests {
    use super::*;
    use crate::children::{self, owned};
    use std::{fs, io::{BufRead, BufReader, Write}, os::unix::process::ExitStatusExt, path::{Path, PathBuf},
        process::{Child, ChildStdin, ChildStdout, Command, Stdio}, time::{Duration, Instant}};

    // Own this direct child through its wait, including assertion failures.
    struct Owned(Child);
    impl Drop for Owned {
        fn drop(&mut self) { let _ = self.0.kill(); let _ = self.0.wait(); }
    }

    /// A row's own directory, outside the worktree, where its children run.
    /// It is removed on every way out of the row.
    struct Dir(PathBuf);
    impl Drop for Dir { fn drop(&mut self) { let _ = fs::remove_dir_all(&self.0); } }

    #[cfg(target_os = "macos")]
    const STOP: i32 = 17;
    #[cfg(not(target_os = "macos"))]
    const STOP: i32 = 19;

    /// Set in a child of this test binary, the child is the fixture: it says
    /// `ready`; for each line on its stdin it stops itself with SIGSTOP and
    /// says `continued` once it is continued; and it exits on the line `exit`
    /// or at the end of its stdin. It is this test binary, which keeps the
    /// marker of its run as its argv[0] where python3 does not
    /// (`crate::children`).
    const FIXTURE: &str = "SAFEDEPS_WAIT_FIXTURE";
    /// Set in a child of this test binary, it names a row's directory, and the
    /// child is a run that starts the fixture there, has it stop, writes its
    /// pid and start to `held`, and waits for its stdin to end.
    const RUN: &str = "SAFEDEPS_WAIT_RUN";

    /// The roles a child of a row plays: the fixture, RUN and the start of
    /// another run (`children::role`). A row runs this first, and goes on
    /// only as the row itself.
    fn roles(path: &str) {
        children::role();
        if std::env::var_os(FIXTURE).is_some() { stops_when_told() }
        if let Some(dir) = std::env::var_os(RUN) { holds_it_stopped(path, Path::new(&dir)) }
    }

    fn stops_when_told() -> ! {
        let mut out = std::io::stdout();
        // After the harness's own `test <name> ... `, on a line of its own.
        out.write_all(b"\nready\n").unwrap();
        out.flush().unwrap();
        for line in std::io::stdin().lock().lines() {
            if line.unwrap().trim() == "exit" { std::process::exit(0) }
            unsafe { kill(std::process::id() as i32, STOP); }
            out.write_all(b"continued\n").unwrap();
            out.flush().unwrap();
        }
        std::process::exit(0)
    }

    /// The fixture, as a child of this run in `cwd`, with its stdin, and its
    /// stdout once it has said `ready`.
    fn fixture(path: &str, cwd: &Path) -> (Owned, ChildStdin, BufReader<ChildStdout>) {
        let mut child = Owned(owned(path, cwd).env(FIXTURE, "1").stdin(Stdio::piped()).spawn().unwrap());
        let input = child.0.stdin.take().unwrap();
        let mut output = BufReader::new(child.0.stdout.take().unwrap());
        let mut line = String::new();
        while line != "ready\n" {
            line.clear();
            assert_ne!(output.read_line(&mut line).unwrap(), 0, "the fixture said it was ready");
        }
        (child, input, output)
    }

    fn stopped(pid: u32) -> bool {
        let state = Command::new("ps").args(["-o", "stat=", "-p", &pid.to_string()]).output().unwrap();
        String::from_utf8_lossy(&state.stdout).trim().starts_with('T')
    }

    /// Tells the fixture to stop, and waits until it has.
    fn stop(pid: u32, input: &mut ChildStdin) {
        writeln!(input, "stop").unwrap();
        let until = Instant::now() + Duration::from_secs(3);
        while !stopped(pid) {
            assert!(Instant::now() < until, "child did not stop");
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    fn holds_it_stopped(path: &str, dir: &Path) -> ! {
        let (child, mut input, _output) = fixture(path, dir);
        let pid = child.0.id();
        stop(pid, &mut input);
        let start = crate::post::start(pid).expect("the kernel's start of the fixture");
        fs::write(dir.join("held.tmp"), format!("{pid} {start}")).unwrap();
        fs::rename(dir.join("held.tmp"), dir.join("held")).unwrap();
        let _ = std::io::copy(&mut std::io::stdin(), &mut std::io::sink());
        drop(child);
        std::process::exit(0)
    }

    #[test]
    fn stopped_and_continued_children_are_not_exited() {
        const PATH: &str = "os::wait_tests::stopped_and_continued_children_are_not_exited";
        roles(PATH);
        #[cfg(target_os = "macos")]
        const CONT: i32 = 19;
        #[cfg(not(target_os = "macos"))]
        const CONT: i32 = 18;
        let dir = Dir(scratch_dir("safedeps-wait").unwrap());
        for ending in [0, SIGTERM, SIGKILL] {
            let (mut child, mut input, mut output) = fixture(PATH, &dir.0);
            let pid = child.0.id();
            assert!(!child_exited_unreaped(pid).unwrap());
            stop(pid, &mut input);
            assert!(!child_exited_unreaped(pid).unwrap(), "stopped child");
            assert_eq!(unsafe { kill(pid as i32, CONT) }, 0);
            let mut line = String::new();
            output.read_line(&mut line).unwrap();
            assert_eq!(line, "continued\n");
            assert!(!child_exited_unreaped(pid).unwrap(), "continued child");
            if ending == 0 { writeln!(input, "exit").unwrap(); }
            else { assert_eq!(unsafe { kill(pid as i32, ending) }, 0); }
            let until = Instant::now() + Duration::from_secs(3);
            while !child_exited_unreaped(pid).unwrap() {
                assert!(Instant::now() < until, "child did not exit: {ending}");
                std::thread::sleep(Duration::from_millis(10));
            }
            // Observation must not consume the status or release the pid.
            assert!(child_exited_unreaped(pid).unwrap());
            let status = child.0.wait().unwrap();
            assert_eq!(status.success(), ending == 0);
        }
    }

    /// A run killed while its fixture is stopped leaves the fixture stopped,
    /// past the next run: no way out of the run runs, and nothing continues
    /// the fixture. Its argv[0] names its run (`crate::children`), so the
    /// start of another run leaves it while its run is alive, and the start
    /// of the next run, once its run is killed, ends it. The run here is a
    /// child of this row in the role RUN, and the row kills it with SIGKILL.
    #[test]
    fn a_stopped_child_a_killed_run_left_is_ended_at_the_next_runs_start() {
        const PATH: &str = "os::wait_tests::a_stopped_child_a_killed_run_left_is_ended_at_the_next_runs_start";
        roles(PATH);
        let dir = Dir(scratch_dir("safedeps-wait-run").unwrap());
        let mut run = Owned(owned(PATH, &dir.0).env(RUN, &dir.0).stdin(Stdio::piped()).spawn().unwrap());
        let held = dir.0.join("held");
        let until = Instant::now() + children::BOUND;
        while !held.exists() {
            assert!(run.0.try_wait().unwrap().is_none() && Instant::now() < until, "the run had its fixture stopped within {:?}", children::BOUND);
            std::thread::sleep(Duration::from_millis(20));
        }
        let text = fs::read_to_string(&held).unwrap();
        let (pid, start) = text.split_once(' ').map(|(pid, start)| (pid.parse::<u32>().unwrap(), start.parse::<u64>().unwrap())).unwrap();
        let _stray = children::Stray(pid, start);
        let (ended, _) = children::next_start(PATH, &dir.0);
        assert!(children::ended_for(&ended, pid, start).is_none(), "another run's start left the fixture of a run that is alive: {}", children::shown(&ended));
        assert!(children::running(pid, start) && stopped(pid), "the fixture is still stopped, as it was");
        let run_pid = run.0.id();
        run.0.kill().unwrap();
        assert_eq!(run.0.wait().unwrap().signal(), Some(9), "the row killed the run");
        assert!(children::running(pid, start) && stopped(pid), "the fixture outlived its run, stopped");
        let (ended, _) = children::next_start(PATH, &dir.0);
        let fact = children::ended_for(&ended, pid, start)
            .unwrap_or_else(|| panic!("the next run's start ended the stopped fixture its killed run left: {}", children::shown(&ended)));
        assert!(children::says_gone(&fact, run_pid), "the fact that its run is gone: {}", String::from_utf8_lossy(&fact));
        assert!(!children::running(pid, start), "the fixture is gone");
    }
}

/// A closed source role identifies the consumer of one wall-clock read.
/// Roles never choose a clock or alter its value. Artifact roles cannot stand
/// in for internal expiry, retention, baseline or temporary-name readings.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WallRole {
    PreSnapshot,
    AdvisoryHeader,
    AdvisoryRotationHeader,
    AdvisoryRotationName,
    ProviderHeader,
    ReorgRefusedHeader,
    ReorgRollbackHeader,
    ConfirmWarningsHeader,
    AcceptedRiskHeader,
    AcceptedRiskEntry,
    ApprovalRecord,
    JournalOpened,
    JournalStage,
    JournalRecoveryHeader,
    VerifiedMeta,
    NpmObserved,
    NpmWithheldEntry,
    NpmWithheldName,
    PreLedgerExpiry,
    PostLedgerExpiry,
    LedgerCliExpiry,
    ProviderCacheExpiry,
    StateLockAge,
    AdvisoryRotationLockAge,
    AdvisoryArchiveMade,
    AdvisoryArchiveQuiet,
    StateRetention,
    StateTempName,
    PostTempName,
    BackstopTouch,
    BackstopFallback,
    JudgmentMarkOpened,
    JudgmentMarkReturned,
    JudgmentMarkSaid,
}

/// One raw reading. Every accessor is pure; retaining this value retains the
/// original event, including its subsecond precision and pre-epoch status.
#[derive(Clone, Copy, Debug)]
pub struct WallTime(std::time::SystemTime);

impl WallTime {
    fn epoch_parts(self) -> (i64, u32) {
        match self.0.duration_since(std::time::UNIX_EPOCH) {
            Ok(d) => (d.as_secs() as i64, d.subsec_nanos()),
            Err(_) => (0, 0),
        }
    }
    pub fn seconds(self) -> i64 { self.epoch_parts().0 }
    pub fn nanos(self) -> u32 { self.epoch_parts().1 }
    pub fn system_time(self) -> std::time::SystemTime { self.0 }
}

/// The only wall-clock generator. An independently reviewed measurement
/// archive can observe `raw` here, before epoch conversion or consumer math.
/// Production builds have no observer, counter, I/O or selection switch.
pub fn wall(_role: WallRole) -> WallTime {
    let raw = std::time::SystemTime::now();
    WallTime(raw)
}

#[cfg(test)]
mod wall_tests {
    use super::WallTime;
    use std::time::{Duration, UNIX_EPOCH};

    #[test]
    fn wall_time_accessors_preserve_raw() {
        for (secs, nanos) in [(0, 0), (0, 1), (1_791_291_940, 999_999_999)] {
            let raw = UNIX_EPOCH + Duration::new(secs, nanos);
            let read = WallTime(raw);
            assert_eq!(read.system_time(), raw);
            assert_eq!(read.seconds(), secs as i64);
            assert_eq!(read.nanos(), nanos);
            assert_eq!(read.system_time(), raw);
        }
        // The old seconds/nanos API returned zero before the epoch. The raw
        // accessor must still preserve the error, not replace it with epoch.
        let raw = UNIX_EPOCH - Duration::from_nanos(1);
        let read = WallTime(raw);
        assert_eq!((read.seconds(), read.nanos()), (0, 0));
        assert_eq!(read.system_time(), raw);
        assert!(read.system_time().duration_since(UNIX_EPOCH).is_err());
    }
}

fn civil(days: i64) -> (i64, u32, u32) {
    // Howard Hinnant's days-to-civil.
    let z = days + 719468;
    let era = z.div_euclid(146097);
    let doe = z.rem_euclid(146097);
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = (if mp < 10 { mp + 3 } else { mp - 9 }) as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

/// `date -u +%Y-%m-%dT%H:%M:%SZ`
pub fn utc_stamp(secs: i64) -> String {
    let (y, m, d) = civil(secs.div_euclid(86400));
    let r = secs.rem_euclid(86400);
    format!("{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z", y, m, d, r / 3600, (r % 3600) / 60, r % 60)
}

/// A time as `stat` prints it at full resolution on this platform: BSD
/// `%Fc`/`%Fm` (seconds, a dot, nine digits) or GNU `%z`/`%y` (local date and
/// time, nine digits, the zone offset).
pub fn stat_clock(secs: i64, nsec: i64) -> String {
    if cfg!(target_os = "macos") {
        return format!("{}.{:09}", secs, nsec);
    }
    let mut tm = Tm {
        tm_sec: 0,
        tm_min: 0,
        tm_hour: 0,
        tm_mday: 0,
        tm_mon: 0,
        tm_year: 0,
        tm_wday: 0,
        tm_yday: 0,
        tm_isdst: 0,
        tm_gmtoff: 0,
        tm_zone: std::ptr::null(),
    };
    let ok = unsafe { !localtime_r(&secs, &mut tm).is_null() };
    if !ok {
        return String::new();
    }
    let off = tm.tm_gmtoff;
    let (sign, a) = if off < 0 { ('-', -off) } else { ('+', off) };
    format!(
        "{:04}-{:02}-{:02} {:02}:{:02}:{:02}.{:09} {}{:02}{:02}",
        tm.tm_year as i64 + 1900,
        tm.tm_mon + 1,
        tm.tm_mday,
        tm.tm_hour,
        tm.tm_min,
        tm.tm_sec,
        nsec,
        sign,
        a / 3600,
        (a % 3600) / 60
    )
}

/// `safedeps_file_clock <file> <m|c> [follow]`: empty when stat fails.
///
/// With follow, a link whose target is missing differs by platform, as the
/// two `stat -L` do: BSD's falls back to the link itself, GNU's fails.
pub fn file_clock(path: &Path, field: u8, follow: bool) -> String {
    let md = if follow {
        match std::fs::metadata(path) {
            Err(_) if cfg!(target_os = "macos") => std::fs::symlink_metadata(path),
            other => other,
        }
    } else {
        std::fs::symlink_metadata(path)
    };
    match md {
        Ok(m) => {
            if field == b'm' {
                stat_clock(m.mtime(), m.mtime_nsec())
            } else {
                stat_clock(m.ctime(), m.ctime_nsec())
            }
        }
        Err(_) => String::new(),
    }
}

fn present(path: &Path) -> bool {
    // `[[ -e p || -L p ]]`
    std::fs::symlink_metadata(path).is_ok()
}

/// `safedeps_tree_clock <path>`: the path's own status change time and, after
/// a bar, that of what it names.
pub fn tree_clock(path: &Path) -> String {
    if !present(path) {
        return String::new();
    }
    let own = file_clock(path, b'c', false);
    if own.is_empty() {
        return String::new();
    }
    let mut target = String::new();
    if path.exists() {
        target = file_clock(path, b'c', true);
        if target.is_empty() {
            return String::new();
        }
    }
    format!("{}|{}", own, target)
}

/// `safedeps_tree_inode <path>`.
pub fn tree_inode(path: &Path) -> String {
    let Ok(own) = std::fs::symlink_metadata(path) else { return String::new() };
    let mut target = String::new();
    if path.exists() {
        match std::fs::metadata(path) {
            Ok(m) => target = m.ino().to_string(),
            Err(_) => return String::new(),
        }
    }
    format!("{}|{}", own.ino(), target)
}

/// `safedeps_clock_has_subsecond`: every part of the line shows a non-zero
/// fraction after its first dot.
pub fn clock_has_subsecond(line: &str) -> bool {
    for part in line.split('|') {
        let Some(dot) = part.find('.') else { return false };
        let digits: String = part[dot + 1..].chars().take_while(|c| c.is_ascii_digit()).collect();
        // `\.([0-9]+)`: the first dot that digits follow.
        let digits = if digits.is_empty() {
            let mut found = String::new();
            let b = part.as_bytes();
            let mut i = dot + 1;
            while i < b.len() {
                if b[i] == b'.' && i + 1 < b.len() && b[i + 1].is_ascii_digit() {
                    found = part[i + 1..].chars().take_while(|c| c.is_ascii_digit()).collect();
                    break;
                }
                i += 1;
            }
            found
        } else {
            digits
        };
        if digits.is_empty() || !digits.chars().any(|c| ('1'..='9').contains(&c)) {
            return false;
        }
    }
    true
}

/// The directory as the hooks canonicalize it: `realpath <dir>`, or the text
/// unchanged where realpath fails. BSD realpath fails on a path that is not
/// there. GNU realpath needs every part but the last to be there: it follows
/// a link in the last part, and what the link names may be missing.
pub fn realpath(dir: &[u8]) -> Vec<u8> {
    use std::os::unix::ffi::{OsStrExt, OsStringExt};
    let given = Path::new(std::ffi::OsStr::from_bytes(dir));
    if let Ok(p) = std::fs::canonicalize(given) {
        return p.into_os_string().into_vec();
    }
    if cfg!(target_os = "linux") {
        let mut path = given.to_path_buf();
        for _ in 0..40 {
            if let Ok(p) = std::fs::canonicalize(&path) {
                return p.into_os_string().into_vec();
            }
            let parent = match path.parent() {
                Some(p) if !p.as_os_str().is_empty() => p.to_path_buf(),
                Some(_) => std::path::PathBuf::from("."),
                None => break,
            };
            match std::fs::read_link(&path) {
                Ok(target) => path = if target.is_absolute() { target } else { parent.join(target) },
                Err(_) => {
                    if let (Ok(pp), Some(name)) = (std::fs::canonicalize(&parent), path.file_name()) {
                        return pp.join(name).into_os_string().into_vec();
                    }
                    break;
                }
            }
        }
    }
    dir.to_vec()
}

/// A path from the bytes a shell string holds.
pub fn path(bytes: &[u8]) -> std::path::PathBuf {
    use std::os::unix::ffi::OsStrExt;
    std::path::PathBuf::from(std::ffi::OsStr::from_bytes(bytes))
}

/// Whether the hook's locale reads text as UTF-8: the first of `LC_ALL`,
/// `LC_CTYPE` and `LANG` that is set names the codeset.
fn locale_is_utf8() -> bool {
    let loc = ["LC_ALL", "LC_CTYPE", "LANG"]
        .iter()
        .filter_map(|k| std::env::var(k).ok())
        .find(|v| !v.is_empty())
        .unwrap_or_default()
        .to_ascii_lowercase();
    loc.contains("utf-8") || loc.contains("utf8")
}

/// The length in bytes of each character of `s` as bash counts characters in
/// the hook's locale: under a UTF-8 locale a well-formed sequence is one
/// character and a byte that starts none is one; otherwise every byte is one.
pub fn bash_chars(s: &[u8]) -> Vec<usize> {
    if !locale_is_utf8() {
        return vec![1; s.len()];
    }
    let mut out = Vec::with_capacity(s.len());
    let mut i = 0;
    while i < s.len() {
        let end = (i + 4).min(s.len());
        let w = match std::str::from_utf8(&s[i..end]) {
            Ok(t) => t.chars().next().map(|c| c.len_utf8()).unwrap_or(1),
            Err(e) if e.valid_up_to() > 0 => {
                std::str::from_utf8(&s[i..i + e.valid_up_to()]).ok().and_then(|t| t.chars().next()).map(|c| c.len_utf8()).unwrap_or(1)
            }
            Err(_) => 1,
        };
        out.push(w);
        i += w;
    }
    out
}

/// `${#s}`.
pub fn bash_len(s: &[u8]) -> usize {
    bash_chars(s).len()
}

/// `${s:0:n}`.
pub fn bash_prefix(s: &[u8], n: usize) -> Vec<u8> {
    let bytes: usize = bash_chars(s).iter().take(n).sum();
    s[..bytes].to_vec()
}
