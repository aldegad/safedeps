//! Own the judgment process and its descendants until they answer or the
//! clock expires. The child marker is an argv word, never environment state.
use super::Out;
use crate::os;
use std::{fs, io, os::unix::process::CommandExt, path::PathBuf, process::{Child, Command, ExitStatus}, time::{Duration, Instant}};

pub enum Failure {
    Deadline { child: Option<io::Result<ExitStatus>> },
    Exited(ExitStatus),
    Supervision { step: &'static str, error: io::Error },
}
fn failure(step: &'static str) -> impl FnOnce(io::Error) -> Failure {
    move |error| Failure::Supervision { step, error }
}

struct Scratch(PathBuf);
impl Drop for Scratch { fn drop(&mut self) { let _ = fs::remove_dir_all(&self.0); } }
struct Judgment { child: Child, reaped: bool }
impl Judgment {
    fn reap_group(&mut self) -> io::Result<ExitStatus> {
        // The caller has observed exit with WNOWAIT, or owns the still-live
        // leader at the deadline. The pid remains reserved until wait below.
        os::kill_group(self.child.id(), os::SIGKILL);
        let status = self.child.wait();
        self.reaped = true;
        status
    }
    fn stop(&mut self) -> io::Result<ExitStatus> {
        // Do not reap the leader before the final group signal. Its unreaped
        // pid prevents group-id reuse while the last signal is being sent.
        os::kill_group(self.child.id(), os::SIGTERM);
        std::thread::sleep(Duration::from_millis(50));
        self.reap_group()
    }
}
impl Drop for Judgment { fn drop(&mut self) { if !self.reaped { let _ = self.stop(); } } }

pub fn run(input: &[u8], until: Instant) -> Result<Out, Failure> {
    let exe = std::env::current_exe().map_err(failure("locate judgment executable"))?;
    let mut command = Command::new(exe);
    command.args(["pre", "--budget-child"]);
    execute(command, input, until)
}

fn execute(command: Command, input: &[u8], until: Instant) -> Result<Out, Failure> {
    if Instant::now() >= until { return Err(Failure::Deadline { child: None }) }
    fn prepare(mut command: Command, input: &[u8]) -> io::Result<(Scratch, Judgment)> {
        let tmp = Scratch(os::scratch_dir("safedeps-budget")?);
        let inp = tmp.0.join("input"); fs::write(&inp, input)?;
        let child = command.stdin(fs::File::open(&inp)?).stdout(fs::File::create(tmp.0.join("out"))?)
            .stderr(fs::File::create(tmp.0.join("err"))?).process_group(0).spawn()?;
        Ok((tmp, Judgment { child, reaped: false }))
    }
    let (tmp, mut judgment) = prepare(command, input).map_err(failure("start judgment process"))?;
    loop {
        if Instant::now() >= until {
            return Err(Failure::Deadline { child: Some(judgment.stop()) });
        }
        match os::child_exited_unreaped(judgment.child.id()) {
            Ok(true) => {
                let status = judgment.reap_group();
                if Instant::now() >= until {
                    return Err(Failure::Deadline { child: Some(status) });
                }
                let status = status.map_err(failure("wait for judgment process"))?;
                if !status.success() { return Err(Failure::Exited(status)) }
                return Ok(Out { stdout: fs::read(tmp.0.join("out")).map_err(failure("read judgment stdout"))?,
                    stderr: fs::read(tmp.0.join("err")).map_err(failure("read judgment stderr"))?, code: 0 });
            }
            Err(e) => {
                // ECHILD means this process no longer owns the waitable pid.
                // Never send a signal using that now-unprotected identifier.
                if e.raw_os_error() == Some(10) { judgment.reaped = true; }
                return Err(Failure::Supervision { step: "observe judgment process", error: e })
            }
            Ok(false) => {}
        }
        std::thread::sleep(Duration::from_millis(20).min(until.saturating_duration_since(Instant::now())));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::children::{self, forked, owned};
    use std::{io::{BufRead, BufReader, Write}, os::unix::process::ExitStatusExt, path::Path, process::Stdio};
    // Data rows choose the fixture's own behavior; no command payload is
    // executed. The fixture is this test binary run again in a role, which
    // keeps the marker of its run as its argv[0] where python3 does not
    // (`crate::children`). The unrelated witness is also this test's child.

    /// Set in a child of this test binary, it names the pid file, and the
    /// child is the leader of the judgment's group. It reads its row from
    /// stdin: a mode, then the grandchild's expiry in seconds, 10 without one.
    /// It starts the grandchild and waits until the grandchild is ready, and
    /// in mode `stopped` until it has stopped. It writes its own pid to
    /// `<pid file>.leader`, then the grandchild's to the pid file. Then it
    /// exits 0 (`normal`) or 7 (`failed`), kills itself (`killed`), or ignores
    /// SIGTERM and runs on (`timeout`) or stops (`stopped`).
    const LEADER: &str = "SAFEDEPS_BUDGET_LEADER";
    /// Set in a child of the leader, it names the pid file, and the child is
    /// the grandchild, in the leader's group and in the leader's mode.
    const GRANDCHILD: &str = "SAFEDEPS_BUDGET_GRANDCHILD";
    const MODE: &str = "SAFEDEPS_BUDGET_MODE";
    const EXPIRY: &str = "SAFEDEPS_BUDGET_EXPIRY";
    /// Set in a child of this test binary, it names a pid file, and the child
    /// is a run that judges with the fixture in mode `timeout` and waits for
    /// the judgment's deadline (`judges_on`).
    const RUN: &str = "SAFEDEPS_BUDGET_RUN";
    /// How long a row's run holds its group: the judgment's deadline, and the
    /// grandchild's expiry. It is far past what the row waits for.
    const HELD: Duration = Duration::from_secs(60);

    #[cfg(target_os = "macos")]
    const SIGSTOP: i32 = 17;
    #[cfg(not(target_os = "macos"))]
    const SIGSTOP: i32 = 19;
    /// WUNTRACED, in sys/wait.h on both targets.
    const WUNTRACED: i32 = 2;
    /// SIG_IGN, as signal(3) takes it.
    const IGNORE: usize = 1;
    extern "C" {
        fn kill(pid: i32, sig: i32) -> i32;
        fn signal(sig: i32, handler: usize) -> usize;
        fn waitpid(pid: i32, status: *mut i32, options: i32) -> i32;
    }

    /// The roles a child of a row plays: the leader, the grandchild, RUN and
    /// the start of another run (`children::role`). A row runs this first,
    /// and goes on only as the row itself.
    fn roles(path: &str) {
        children::role();
        if let Some(pidfile) = std::env::var_os(GRANDCHILD) { grandchild(Path::new(&pidfile)) }
        if let Some(pidfile) = std::env::var_os(LEADER) { leader(path, Path::new(&pidfile)) }
        if let Some(pidfile) = std::env::var_os(RUN) { judges_on(path, Path::new(&pidfile)) }
    }

    fn ignore_sigterm() { unsafe { signal(os::SIGTERM, IGNORE); } }
    fn stop_self() { unsafe { kill(std::process::id() as i32, SIGSTOP); } }
    fn runs_on() -> ! { loop { std::thread::sleep(Duration::from_secs(1)) } }

    /// `text` in `path`, which no reader sees half written.
    fn put(path: &Path, text: &str) {
        let mut tmp = path.as_os_str().to_owned();
        tmp.push(".tmp");
        fs::write(&tmp, text).unwrap();
        fs::rename(&tmp, path).unwrap();
    }

    /// A deliberately broken supervisor must not leave a permanent orphan, so
    /// the grandchild expires: once its expiry has passed, it writes
    /// `<pid file>.expired` and exits 125, and this limit cannot masquerade as
    /// supervisor cleanup.
    fn grandchild(pidfile: &Path) -> ! {
        ignore_sigterm();
        let expiry = Duration::from_secs(std::env::var(EXPIRY).unwrap().parse().unwrap());
        let expired = pidfile.with_extension("expired");
        std::thread::spawn(move || {
            std::thread::sleep(expiry);
            let _ = fs::write(&expired, "expired\n");
            std::process::exit(125)
        });
        let mut out = std::io::stdout();
        // After the harness's own `test <name> ... `, on a line of its own.
        out.write_all(b"\nready\n").unwrap();
        out.flush().unwrap();
        if std::env::var(MODE).unwrap() == "stopped" { stop_self() }
        runs_on()
    }

    fn leader(path: &str, pidfile: &Path) -> ! {
        let mut row = String::new();
        std::io::stdin().read_line(&mut row).unwrap();
        let mut words = row.split_whitespace();
        let mode = words.next().expect("a row names its mode").to_owned();
        let expiry = words.next().unwrap_or("10").to_owned();
        let mut child = forked(path, pidfile.parent().unwrap()).env(GRANDCHILD, pidfile).env(MODE, &mode).env(EXPIRY, &expiry)
            .stdin(Stdio::null()).stderr(Stdio::inherit()).spawn().unwrap();
        let pid = child.id();
        let mut said = BufReader::new(child.stdout.take().unwrap());
        let mut line = String::new();
        while line != "ready\n" {
            line.clear();
            assert_ne!(said.read_line(&mut line).unwrap(), 0, "the grandchild said it was ready");
        }
        if mode == "stopped" {
            let mut status = 0;
            assert_eq!(unsafe { waitpid(pid as i32, &mut status, WUNTRACED) }, pid as i32);
            assert_eq!(status & 0xff, 0x7f, "the grandchild stopped");
        }
        put(&pidfile.with_extension("leader"), &std::process::id().to_string());
        put(pidfile, &pid.to_string());
        match mode.as_str() {
            "normal" => std::process::exit(0),
            "failed" => std::process::exit(7),
            "killed" => { unsafe { kill(std::process::id() as i32, os::SIGKILL); } }
            _ => {}
        }
        ignore_sigterm();
        if mode == "stopped" { stop_self() }
        runs_on()
    }

    /// A run that judges with the fixture in mode `timeout`, its grandchild's
    /// expiry and the judgment's deadline HELD away, and then exits. Its
    /// directory is the pid file's, which is also its TMPDIR, so the scratch
    /// directory the judgment makes goes with the row's even when the run is
    /// killed.
    fn judges_on(path: &str, pidfile: &Path) -> ! {
        let mut command = owned(path, pidfile.parent().unwrap());
        command.env(LEADER, pidfile);
        let _ = execute(command, format!("timeout {}\n", HELD.as_secs()).as_bytes(), Instant::now() + HELD);
        std::process::exit(0)
    }

    /// A row's run, killed and reaped on every way out of the row.
    struct Run(std::process::Child);
    impl Drop for Run { fn drop(&mut self) { let _ = self.0.kill(); let _ = self.0.wait(); } }

    #[test]
    fn owns_group_until_after_exit() {
        const PATH: &str = "pre::budget::tests::owns_group_until_after_exit";
        roles(PATH);
        let scratch=Scratch(os::scratch_dir("safedeps-budget-probe").unwrap());
        let mut witness=Command::new("sleep");
        children::mark(&mut witness).arg("30").current_dir(&scratch.0).process_group(0);
        let mut witness=Judgment{child:witness.spawn().unwrap(),reaped:false};
        for (mode,expected) in [("normal",0),("failed",7),("killed",137),("timeout",137),("stopped",137)] {
            let pidfile=scratch.0.join(mode);
            let mut cmd=owned(PATH,&scratch.0);cmd.env(LEADER,&pidfile);
            let input=format!("{mode}\n");
            let deadline_case=matches!(mode,"timeout"|"stopped");
            let duration=if deadline_case{Duration::from_millis(800)}else{Duration::from_secs(5)};
            let start=Instant::now();
            let result=execute(cmd,input.as_bytes(),start+duration);
            let (code, timed_out)=match result {
                Ok(out)=>(out.code,false),
                Err(Failure::Exited(status))=>(status.code().unwrap_or(128+status.signal().unwrap_or(0)),false),
                Err(Failure::Deadline{child:Some(Ok(status))})=>(status.code().unwrap_or(128+status.signal().unwrap_or(0)),true),
                _=>panic!("supervision failed: {mode}"),
            };
            assert_eq!(code,expected,"leader {mode}");
            assert_eq!(timed_out,deadline_case,"deadline classification: {mode}");
            if deadline_case {
                assert!(start.elapsed()>=duration,"answered before the deadline: {mode}");
            }
            assert!(start.elapsed()<duration+Duration::from_secs(1),"deadline {mode}");
            let pid=fs::read_to_string(&pidfile).unwrap();
            // Independent observation: ps says absent or zombie, not running.
            // A zombie may wait briefly for the host's init to reap it.
            let mut gone=false;
            for _ in 0..20 {
                let obs=Command::new("ps").args(["-o","stat=","-p",pid.trim()]).output().unwrap();
                let status=String::from_utf8_lossy(&obs.stdout);
                if status.trim().is_empty() || status.trim().starts_with('Z'){gone=true;break}
                std::thread::sleep(Duration::from_millis(10));
            }
            assert!(gone,"grandchild survived {mode}: {pid}");
            assert!(!pidfile.with_extension("expired").exists(),"fixture expired before observation {mode}");
            assert!(!os::child_exited_unreaped(witness.child.id()).unwrap(),"unrelated witness {mode}");
        }
        witness.stop().unwrap();
    }

    /// A run killed while its judgment's leader and grandchild ignore SIGTERM
    /// (mode `timeout`) leaves both running, past the next run: no way out of
    /// the run runs, and the leader never ends by itself. Each carries the
    /// marker of the run as its argv[0] (`owned`, `forked`), so the start of
    /// another run leaves them while their run is alive, and the start of the
    /// next run, once their run is killed, ends both. The run here is a child
    /// of this row in the role RUN, and the row kills it with SIGKILL.
    ///
    /// The row holds no stopped group. A group with a stopped process that
    /// the death of its run leaves orphaned is sent SIGHUP, then SIGCONT, by
    /// the kernel (POSIX, _exit(), Consequences of Process Termination).
    #[test]
    fn a_group_a_killed_run_left_is_ended_at_the_next_runs_start() {
        const PATH: &str = "pre::budget::tests::a_group_a_killed_run_left_is_ended_at_the_next_runs_start";
        roles(PATH);
        let scratch = Scratch(os::scratch_dir("safedeps-budget-run").unwrap());
        let pidfile = scratch.0.join("timeout");
        let mut run = Run(owned(PATH, &scratch.0).env(RUN, &pidfile).env("TMPDIR", &scratch.0).stdin(Stdio::null()).spawn().unwrap());
        let until = Instant::now() + children::BOUND;
        while !pidfile.exists() {
            assert!(run.0.try_wait().unwrap().is_none() && Instant::now() < until, "the run's group was ready within {:?}", children::BOUND);
            std::thread::sleep(Duration::from_millis(20));
        }
        let held = |path: &Path| -> (u32, u64) {
            let pid = fs::read_to_string(path).unwrap().parse::<u32>().unwrap();
            (pid, crate::post::start(pid).expect("the kernel's start of a process of the group"))
        };
        let group = [("the leader", held(&pidfile.with_extension("leader"))), ("the grandchild", held(&pidfile))];
        let _strays = group.map(|(_, (pid, start))| children::Stray(pid, start));
        let (ended, _) = children::next_start(PATH, &scratch.0);
        for (who, (pid, start)) in group {
            assert!(children::ended_for(&ended, pid, start).is_none(), "another run's start left {who} of a run that is alive: {}", children::shown(&ended));
            assert!(children::running(pid, start), "{who} still runs, as it was");
        }
        let run_pid = run.0.id();
        run.0.kill().unwrap();
        assert_eq!(run.0.wait().unwrap().signal(), Some(9), "the row killed the run");
        for (who, (pid, start)) in group { assert!(children::running(pid, start), "{who} outlived its run"); }
        let (ended, _) = children::next_start(PATH, &scratch.0);
        for (who, (pid, start)) in group {
            let fact = children::ended_for(&ended, pid, start)
                .unwrap_or_else(|| panic!("the next run's start ended {who}, which its killed run left: {}", children::shown(&ended)));
            assert!(children::says_gone(&fact, run_pid), "the fact that its run is gone: {}", String::from_utf8_lossy(&fact));
            assert!(!children::running(pid, start), "{who} is gone");
        }
        assert!(!pidfile.with_extension("expired").exists(), "the grandchild did not expire first");
    }
}
