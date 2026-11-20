//! The journal owner's state, read without launching ps. This exposes the
//! process state and the host's ps status modifiers, without a ps child.
use super::report::cat;
use crate::ledger;

extern "C" {fn kill(pid:i32,signal:i32)->i32;}

// proc_bsdinfo, Darwin SDK sys/proc_info.h; MAXCOMLEN is 16.
#[cfg(target_os="macos")]
#[repr(C)]
struct Bsd {flags:u32,status:u32,xstatus:u32,pid:u32,ppid:u32,uid:u32,gid:u32,ruid:u32,rgid:u32,svuid:u32,svgid:u32,reserved:u32,
    comm:[u8;16],name:[u8;32],nfiles:u32,pgid:u32,jobc:u32,tdev:u32,tpgid:u32,nice:i32,start_sec:u64,start_usec:u64}
/// The kernel's record of pid, None when it gave none or one for another pid.
#[cfg(target_os="macos")]
fn bsd(pid:i32)->Option<Bsd>{
    extern "C" {fn proc_pidinfo(pid:i32,flavor:i32,arg:u64,buffer:*mut std::ffi::c_void,size:i32)->i32;}
    let mut b: Bsd=unsafe{std::mem::zeroed()};let size=std::mem::size_of::<Bsd>() as i32;
    // PROC_PIDTBSDINFO needs nonzero arg to include zombies. xnu's
    // bsd/kern/proc_info.c sets findzomb only when this arg is nonzero.
    if unsafe{proc_pidinfo(pid,3,1,&mut b as *mut _ as *mut _,size)}!=size{return None}
    if b.pid!=pid as u32{return None}
    Some(b)
}
#[cfg(target_os="macos")]
fn info(pid:i32)->Option<(Vec<u8>,i64)>{
    let b=bsd(pid)?;
    if b.start_usec>=1_000_000 || b.start_sec>i64::MAX as u64{return None}
    let mut status=vec![match b.status{4=>b'T',5=>b'Z',_=>b'R'}];
    // ps/print.c state(), with PROC_FLAG_* from sys/proc_info.h.
    // https://github.com/apple-oss-distributions/adv_cmds/blob/main/ps/print.c
    // https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/proc_info.h
    // Verified 2026-10-06. P_NOSWAP/P_PHYSIO are zero in the Darwin SDK.
    if b.nice<0{status.push(b'<')}else if b.nice>0{status.push(b'N')}
    if b.flags&2!=0{status.push(b'X')}
    if b.flags&4!=0&&b.status!=5{status.push(b'E')}
    if b.flags&8!=0{status.push(b'V')}
    if b.flags&1!=0{status.push(b'L')}
    if b.flags&0x20!=0{status.push(b's')}
    if b.flags&0x80!=0&&b.pgid==b.tpgid{status.push(b'+')}
    Some((status,b.start_sec as i64))
}
#[cfg(target_os="linux")]
fn info(pid:i32)->Option<(Vec<u8>,i64)>{
    let stat=std::fs::read_to_string(format!("/proc/{}/stat",pid)).ok()?;
    let close=stat.rfind(')')?;let fields:Vec<_>=stat[close+1..].split_whitespace().collect();
    let state=*fields.first()?.as_bytes().first()?;
    let ticks=fields.get(19)?.parse::<u64>().ok()?;
    let boot=std::fs::read_to_string("/proc/stat").ok()?.lines().find_map(|l|l.strip_prefix("btime ").and_then(|x|x.parse::<i64>().ok()))?;
    extern "C"{fn sysconf(name:i32)->i64;}
    let hz=unsafe{sysconf(2)};if hz<=0{return None}
    // procps-ng src/ps/output.c pr_stat(), verified 2026-10-06:
    // https://gitlab.com/procps-ng/procps/-/blob/master/src/ps/output.c
    let mut status=vec![state];
    let nice=fields.get(16)?.parse::<i64>().ok()?;
    if nice<0{status.push(b'<')}else if nice>0{status.push(b'N')}
    let detail=std::fs::read_to_string(format!("/proc/{}/status",pid)).ok()?;
    if detail.lines().find_map(|l|l.strip_prefix("VmLck:").and_then(|s|s.split_whitespace().next()).and_then(|s|s.parse::<u64>().ok())).is_some_and(|v|v>0){status.push(b'L')}
    if fields.get(3)?.parse::<i32>().ok()?==pid{status.push(b's')}
    if fields.get(17)?.parse::<u64>().ok()? > 1{status.push(b'l')}
    if fields.get(2)?==fields.get(5)?{status.push(b'+')}
    Some((status,boot+(ticks/hz as u64) as i64))
}
#[cfg(not(any(target_os="macos",target_os="linux")))]
fn info(_pid:i32)->Option<(Vec<u8>,i64)>{None}

/// What the kernel holds under a pid, read once: no process; a process, a
/// zombie or not, with the start the kernel stored for it (None where it gave
/// no usable start, which is not known and never a start of 0); or no answer.
enum Kernel { Nothing, Process { zombie: bool, start: Option<u64> }, Unread }

/// The kernel holds no process under pid: kill(pid, 0) returned ESRCH, which
/// is 3 on macOS and on Linux. Any other answer, a process of another user
/// included, is not that fact.
fn no_such(pid:i32)->bool{
    unsafe{kill(pid,0)}!=0 && std::io::Error::last_os_error().raw_os_error()==Some(3)
}

/// The start is p_starttime, in microseconds since the epoch (the field sysctl
/// KERN_PROC_PID also gives). A zombie is process status 5 (SZOMB).
#[cfg(target_os="macos")]
fn kernel(pid:i32)->Kernel{
    let Some(b)=bsd(pid) else {return if no_such(pid){Kernel::Nothing}else{Kernel::Unread}};
    let start=if b.start_sec==0 || b.start_usec>=1_000_000{None}else{b.start_sec.checked_mul(1_000_000).and_then(|s|s.checked_add(b.start_usec))};
    Kernel::Process{zombie:b.status==5,start}
}
/// The start is field 22 of /proc/<pid>/stat, in clock ticks since boot, and
/// the state is field 3, read from the same read of the file.
#[cfg(target_os="linux")]
fn kernel(pid:i32)->Kernel{
    let Ok(stat)=std::fs::read(format!("/proc/{}/stat",pid)) else {return if no_such(pid){Kernel::Nothing}else{Kernel::Unread}};
    // comm can hold anything, so the fields follow its last ')'.
    let Some(close)=stat.iter().rposition(|b|*b==b')') else {return Kernel::Unread};
    let fields:Vec<&[u8]>=stat[close+1..].split(|b|b.is_ascii_whitespace()).filter(|f|!f.is_empty()).collect();
    let Some(&state)=fields.first().and_then(|f|f.first()) else {return Kernel::Unread};
    let start=fields.get(19).filter(|f|f.iter().all(u8::is_ascii_digit)).and_then(|f|std::str::from_utf8(f).ok()?.parse::<u64>().ok()).filter(|n|*n>0);
    Kernel::Process{zombie:matches!(state,b'Z'|b'X'|b'x'),start}
}
#[cfg(not(any(target_os="macos",target_os="linux")))]
fn kernel(_pid:i32)->Kernel{Kernel::Unread}

/// The start the kernel stored for pid, as the one number it keeps: on macOS
/// p_starttime in microseconds since the epoch, on Linux and WSL1 field 22 of
/// /proc/<pid>/stat, in clock ticks since boot (`kernel`). Exec, a time zone,
/// a locale and PATH do not move it, and no wall clock is read to make it.
/// None when the kernel gave no usable record, which is not known and never a
/// start of 0.
pub fn start(pid:u32)->Option<u64>{
    match kernel(i32::try_from(pid).ok()?){Kernel::Process{start,..}=>start,_=>None}
}

/// Whether the process a record names by its pid and the start the kernel
/// stored for it still runs. Gone is one of three facts, each said as it was
/// read: the kernel holds no process under the pid, it holds a zombie, or it
/// holds a process with another start, which is a pid it handed out again. A
/// read that gives no answer or no start is not known, and never gone.
pub enum Holder { Running, Gone(Vec<u8>), Unknown }

pub fn holder(pid:u32,start:u64)->Holder{
    match i32::try_from(pid){Ok(n) if n>0=>holder_of(pid,start,kernel(n)),_=>Holder::Unknown}
}

fn holder_of(pid:u32,start:u64,kernel:Kernel)->Holder{
    let pid=pid.to_string();
    match kernel{
        Kernel::Nothing=>Holder::Gone(cat(&[b"pid ",pid.as_bytes(),b" is not running"])),
        Kernel::Process{zombie:true,..}=>Holder::Gone(cat(&[b"pid ",pid.as_bytes(),b" is a zombie"])),
        Kernel::Process{start:Some(now),..} if now==start=>Holder::Running,
        Kernel::Process{start:Some(now),..}=>Holder::Gone(cat(&[b"pid ",pid.as_bytes(),b" is another process now: the kernel stored the start ",now.to_string().as_bytes(),b" for it"])),
        Kernel::Process{start:None,..}|Kernel::Unread=>Holder::Unknown,
    }
}

/// 0 running, 1 gone/unresolved, 2 stopped. Start-time comparison precedes
/// the stopped answer so a reused stopped pid cannot own an older journal.
pub fn owner(pid:&[u8],opened:&[u8])->(i32,Vec<u8>){
    if pid.is_empty() || !pid.iter().all(u8::is_ascii_digit){return(1,b"the journal records no pid".to_vec())}
    let n=std::str::from_utf8(pid).ok().and_then(|p|p.parse::<i32>().ok());
    if n.is_none_or(|n|unsafe{kill(n,0)}!=0){return(1,cat(&[b"pid ",pid,b" is not running"]))}
    let Some((st,start))=info(n.unwrap())else{return(1,cat(&[b"native process query supplied no usable owner data for pid ",pid]))};
    if st.first()==Some(&b'Z'){return(1,cat(&[b"pid ",pid,b" is a zombie (process state ",&st,b")"]))}
    let Some(at)=std::str::from_utf8(opened).ok().and_then(ledger::epoch)else{return(1,b"the opening time of the journal cannot be parsed".to_vec())};
    if start>at{return(1,cat(&[b"pid ",pid,b" started after the journal was opened"]))}
    if matches!(st.first(),Some(&b'T')|Some(&b't')){return(2,cat(&[b"pid ",pid,b" is stopped (process state ",&st,b")"]))}
    (0,cat(&[b"pid ",pid,b" is running"]))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn said(holder: Holder) -> String {
        match holder { Holder::Running => "running".into(), Holder::Gone(fact) => String::from_utf8(fact).unwrap(), Holder::Unknown => "not known".into() }
    }

    /// A run is gone on one of three facts the kernel gave, alive where the
    /// kernel holds its pid with its start, and not known where the kernel
    /// gave no answer or no start: what is not known is never gone.
    #[test]
    fn a_holder_is_gone_on_a_fact_and_not_known_without_one() {
        let process = |zombie, start| Kernel::Process { zombie, start };
        assert_eq!(said(holder_of(7, 100, Kernel::Nothing)), "pid 7 is not running");
        assert_eq!(said(holder_of(7, 100, process(true, Some(100)))), "pid 7 is a zombie");
        assert_eq!(said(holder_of(7, 100, process(true, None))), "pid 7 is a zombie");
        assert_eq!(said(holder_of(7, 100, process(false, Some(100)))), "running");
        assert_eq!(said(holder_of(7, 100, process(false, Some(101)))), "pid 7 is another process now: the kernel stored the start 101 for it");
        assert_eq!(said(holder_of(7, 100, process(false, None))), "not known");
        assert_eq!(said(holder_of(7, 100, Kernel::Unread)), "not known");
        let me = std::process::id();
        let start = start(me).expect("the kernel's start of this process");
        assert_eq!(said(holder(me, start)), "running");
        assert_eq!(said(holder(me, start + 1)), format!("pid {me} is another process now: the kernel stored the start {start} for it"));
        assert_eq!(said(holder(0, start)), "not known", "pid 0 names no process");
        assert_eq!(said(holder(u32::MAX, start)), "not known", "a pid the kernel never hands out");
    }
}
