//! The few things the hook asks of the system that std does not offer: the
//! process's umask, a signal to a process group, and a local time with its
//! zone offset. They are libc's own functions, declared here, so the crate
//! still names no dependency.
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

pub const SIGTERM: i32 = 15;
pub const SIGKILL: i32 = 9;

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
    use std::{io::{BufRead, BufReader, Write}, process::{Child, Command, Stdio},
        time::{Duration, Instant}};

    // Own this direct child through its wait, including assertion failures.
    struct Owned(Child);
    impl Drop for Owned {
        fn drop(&mut self) { let _ = self.0.kill(); let _ = self.0.wait(); }
    }

    #[test]
    fn stopped_and_continued_children_are_not_exited() {
        const CHILD: &str = r#"import os,signal,sys
print('ready',flush=True)
for line in sys.stdin:
    if line.strip()=='exit': sys.exit(0)
    os.kill(os.getpid(),signal.SIGSTOP)
    print('continued',flush=True)
"#;
        #[cfg(target_os = "macos")]
        const CONT: i32 = 19;
        #[cfg(not(target_os = "macos"))]
        const CONT: i32 = 18;
        for ending in [0, SIGTERM, SIGKILL] {
            let mut child = Owned(Command::new("python3").args(["-u", "-c", CHILD])
                .stdin(Stdio::piped()).stdout(Stdio::piped()).spawn().unwrap());
            let pid = child.0.id();
            let mut input = child.0.stdin.take().unwrap();
            let mut output = BufReader::new(child.0.stdout.take().unwrap());
            let mut line = String::new();
            output.read_line(&mut line).unwrap();
            assert_eq!(line, "ready\n");
            assert!(!child_exited_unreaped(pid).unwrap());
            writeln!(input, "stop").unwrap();
            let until = Instant::now() + Duration::from_secs(3);
            loop {
                let state = Command::new("ps").args(["-o", "stat=", "-p", &pid.to_string()]).output().unwrap();
                if String::from_utf8_lossy(&state.stdout).trim().starts_with('T') { break }
                assert!(Instant::now() < until, "child did not stop");
                std::thread::sleep(Duration::from_millis(10));
            }
            assert!(!child_exited_unreaped(pid).unwrap(), "stopped child");
            assert_eq!(unsafe { kill(pid as i32, CONT) }, 0);
            line.clear(); output.read_line(&mut line).unwrap();
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
    StateRetention,
    StateTempName,
    PostTempName,
    BackstopTouch,
    BackstopFallback,
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
