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
    fn umask(mask: u32) -> u32;
    fn kill(pid: i32, sig: i32) -> i32;
    fn localtime_r(t: *const i64, tm: *mut Tm) -> *mut Tm;
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

pub fn now() -> (i64, u32) {
    match std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH) {
        Ok(d) => (d.as_secs() as i64, d.subsec_nanos()),
        Err(_) => (0, 0),
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
