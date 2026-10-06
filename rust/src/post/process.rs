//! The journal owner's state, read without launching ps. This exposes the
//! process state and the host's ps status modifiers, without a ps child.
use super::report::cat;
use crate::ledger;

extern "C" {fn kill(pid:i32,signal:i32)->i32;}

#[cfg(target_os="macos")]
fn info(pid:i32)->Option<(Vec<u8>,i64)>{
    // proc_bsdinfo, Darwin SDK sys/proc_info.h; MAXCOMLEN is 16.
    #[repr(C)]
    struct Bsd {flags:u32,status:u32,xstatus:u32,pid:u32,ppid:u32,uid:u32,gid:u32,ruid:u32,rgid:u32,svuid:u32,svgid:u32,reserved:u32,
        comm:[u8;16],name:[u8;32],nfiles:u32,pgid:u32,jobc:u32,tdev:u32,tpgid:u32,nice:i32,start_sec:u64,start_usec:u64}
    extern "C" {fn proc_pidinfo(pid:i32,flavor:i32,arg:u64,buffer:*mut std::ffi::c_void,size:i32)->i32;}
    let mut b: Bsd=unsafe{std::mem::zeroed()};let size=std::mem::size_of::<Bsd>() as i32;
    if unsafe{proc_pidinfo(pid,3,0,&mut b as *mut _ as *mut _,size)}!=size{return None}
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

/// 0 running, 1 gone/unresolved, 2 stopped. Start-time comparison precedes
/// the stopped answer so a reused stopped pid cannot own an older journal.
pub fn owner(pid:&[u8],opened:&[u8])->(i32,Vec<u8>){
    if pid.is_empty() || !pid.iter().all(u8::is_ascii_digit){return(1,b"the journal records no pid".to_vec())}
    let n=std::str::from_utf8(pid).ok().and_then(|p|p.parse::<i32>().ok());
    if n.is_none_or(|n|unsafe{kill(n,0)}!=0){return(1,cat(&[b"pid ",pid,b" is not running"]))}
    let Some((st,start))=info(n.unwrap())else{return(1,cat(&[b"ps gives no start time for pid ",pid]))};
    if st.first()==Some(&b'Z'){return(1,cat(&[b"pid ",pid,b" is a zombie (ps state ",&st,b")"]))}
    let Some(at)=std::str::from_utf8(opened).ok().and_then(ledger::epoch)else{return(1,b"the opening time of the journal cannot be parsed".to_vec())};
    if start>at{return(1,cat(&[b"pid ",pid,b" started after the journal was opened"]))}
    if matches!(st.first(),Some(&b'T')|Some(&b't')){return(2,cat(&[b"pid ",pid,b" is stopped (ps state ",&st,b")"]))}
    (0,cat(&[b"pid ",pid,b" is running"]))
}
