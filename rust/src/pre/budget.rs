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
    // Data rows choose the fixture's own behavior; no command payload is
    // executed. The unrelated witness is also this test's child.
    const FIXTURE: &str = r#"import json,os,signal,sys,time
row=json.loads(sys.stdin.buffer.readline())
ready_r,ready_w=os.pipe()
pid=os.fork()
if pid==0:
    os.close(ready_r)
    signal.signal(signal.SIGTERM,signal.SIG_IGN)
    # A deliberately broken supervisor must not leave a permanent orphan.
    # Record expiry so this limit cannot masquerade as supervisor cleanup.
    def expire(signum,frame):
        with open(sys.argv[1]+'.expired','w') as f: f.write('expired\n')
        os._exit(125)
    signal.signal(signal.SIGALRM,expire)
    signal.alarm(10)
    os.write(ready_w,b'1')
    os.close(ready_w)
    if row['mode']=='stopped': os.kill(os.getpid(),signal.SIGSTOP)
    while True: time.sleep(1)
os.close(ready_w)
assert os.read(ready_r,1)==b'1'
os.close(ready_r)
if row['mode']=='stopped':
    _,status=os.waitpid(pid,os.WUNTRACED)
    assert os.WIFSTOPPED(status)
with open(sys.argv[1],'w') as f: f.write(str(pid))
mode=row['mode']
if mode=='normal': os._exit(0)
if mode=='failed': os._exit(7)
if mode=='killed': os.kill(os.getpid(),signal.SIGKILL)
signal.signal(signal.SIGTERM,signal.SIG_IGN)
if mode=='stopped': os.kill(os.getpid(),signal.SIGSTOP)
while True: time.sleep(1)
"#;

    #[test]
    fn owns_group_until_after_exit() {
        let scratch=Scratch(os::scratch_dir("safedeps-budget-probe").unwrap());
        let fixture=scratch.0.join("child.py");fs::write(&fixture,FIXTURE).unwrap();
        let witness=Command::new("sleep").arg("30").process_group(0).spawn().unwrap();
        let mut witness=Judgment{child:witness,reaped:false};
        for (mode,expected) in [("normal",0),("failed",7),("killed",137),("timeout",137),("stopped",137)] {
            let pidfile=scratch.0.join(mode);
            let mut cmd=Command::new("python3");cmd.arg(&fixture).arg(&pidfile);
            let input=format!("{{\"mode\":\"{}\"}}\n",mode);
            let deadline_case=matches!(mode,"timeout"|"stopped");
            let duration=if deadline_case{Duration::from_millis(800)}else{Duration::from_secs(5)};
            let start=Instant::now();
            let result=execute(cmd,input.as_bytes(),start+duration);
            use std::os::unix::process::ExitStatusExt;
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
}
