//! Where the hooks keep their state, and the advisory log.
//!
//! `advisory.log` is derived from `SAFEDEPS_HOME` and from nothing else:
//! `re-check` reads it as the record of whether an approval ever happened, so
//! the log and the ledger move together or not at all (AGENTS.md).

use crate::{ere::Regex, md5, os};
use std::io::Write;
use std::time::{Duration, Instant, SystemTime};
type W = Vec<u8>;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

/// `GUARD_DIR="${SAFEDEPS_HOME:-${HOME}/.safedeps}"`. An empty
/// `SAFEDEPS_HOME` counts as unset, and an unset `HOME` leaves the path
/// starting at `/.safedeps`, as the shell's expansion does.
pub fn guard_dir() -> PathBuf {
    crate::os::path(&guard_text())
}

/// The same directory as the text the hooks build their paths from. A record
/// that names a path holds that text, so `x/` and `/pending` make `x//pending`
/// there, as the shell's expansion does.
pub fn guard_text() -> Vec<u8> {
    use std::os::unix::ffi::OsStringExt;
    match std::env::var_os("SAFEDEPS_HOME") {
        Some(h) if !h.is_empty() => h.into_vec(),
        _ => {
            let mut p = std::env::var_os("HOME").unwrap_or_default().into_vec();
            p.extend_from_slice(b"/.safedeps");
            p
        }
    }
}

/// `umask 077; mkdir -p "${GUARD_DIR}" "${SNAPSHOT_DIR}"`. The caller sets
/// the umask once (os::set_umask); the mode here says the same for the
/// directories this creates.
pub fn ensure_dirs(dir: &Path) -> std::io::Result<()> {
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(dir.join("snapshots"))
}

/// `log_advisory`: one line, `<UTC time>\t<text>\n`, appended to
/// `advisory.log`. A line that cannot be written is dropped, as the shell's
/// `|| true` drops it.
pub fn log_advisory(dir: &Path, text: &[u8]) {
    let (secs, _) = crate::os::now();
    let mut line = crate::os::utc_stamp(secs).into_bytes();
    line.push(b'\t');
    line.extend_from_slice(text);
    line.push(b'\n');
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).mode(0o600).open(dir.join("advisory.log")) {
        let _ = f.write_all(&line);
    }
}

/// The two hooks use the same mkdir lock, but answer failure differently.
/// Keep the verdict in the caller. Dropping an acquired lock releases it;
/// a failed acquisition never owns (and must never remove) the directory.
pub struct StateLock {
    path: PathBuf,
}

impl StateLock {
    pub fn acquire(path: &Path, warnings: &mut Vec<u8>, deadline: Option<Instant>) -> std::io::Result<Self> {
        use std::os::unix::fs::MetadataExt;
        let attempts = std::env::var("SAFEDEPS_LOCK_MAX_ATTEMPTS").ok()
            .and_then(|v| v.parse::<i64>().ok()).unwrap_or(100).max(1);
        let mut tried = 0;
        loop {
            if deadline.is_some_and(|d| Instant::now() >= d) {
                return Err(std::io::Error::new(std::io::ErrorKind::TimedOut, "state lock deadline"));
            }
            match std::fs::DirBuilder::new().mode(0o700).create(path) {
                Ok(()) => return Ok(Self { path: path.to_path_buf() }),
                Err(e) => {
                    if let Ok(m) = std::fs::metadata(path) {
                        let age = os::now().0 - m.mtime();
                        if m.is_dir() && age > 60 {
                            warnings.extend_from_slice(format!("safedeps: removing stale lock ({}s old).\n", age).as_bytes());
                            if std::fs::remove_dir(path).is_ok() { continue; }
                        }
                    }
                    tried += 1;
                    if tried >= attempts { return Err(e); }
                }
            }
            let delay = deadline.map(|d| d.saturating_duration_since(Instant::now()))
                .unwrap_or(Duration::from_millis(100)).min(Duration::from_millis(100));
            std::thread::sleep(delay);
        }
    }
}

impl Drop for StateLock {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir(&self.path);
    }
}

/// `compute_pending_key`'s normal form of a command, as its sed writes it: on
/// each line, every ` --ignore-scripts` that is a whole word is taken out,
/// each run of blanks becomes one blank, and a blank at either end goes.
pub fn pending_norm(command: &[u8]) -> W {
    let flag = Regex::new("[[:space:]]+--ignore-scripts([^=[:alnum:]_-]|$)", false).expect("the flag pattern");
    let mut lines: Vec<W> = Vec::new();
    for line in command.split(|&b| b == b'\n') {
        let mut line = line.to_vec();
        while let Some((s, e)) = flag.find(&line) {
            // `\1` is the byte after the flag; there is none where the flag
            // ends the line.
            let cut = if line[..e].ends_with(b"--ignore-scripts") { e } else { e - 1 };
            line.drain(s..cut);
        }
        let mut norm = W::with_capacity(line.len());
        let mut blank = false;
        for &b in &line {
            if matches!(b, b' ' | b'\t' | b'\n' | 0x0b | 0x0c | b'\r') {
                if !blank {
                    norm.push(b' ');
                }
                blank = true;
            } else {
                norm.push(b);
                blank = false;
            }
        }
        if norm.first() == Some(&b' ') {
            norm.remove(0);
        }
        if norm.last() == Some(&b' ') {
            norm.pop();
        }
        lines.push(norm);
    }
    {
        let mut norm = lines.join(&b'\n');
        norm.retain(|&b| b != 0);
        while norm.last() == Some(&b'\n') { norm.pop(); }
        norm
    }
}

/// `compute_pending_key <dir hash> <command>`.
pub fn pending_key(dir_hash: &str, command: &[u8]) -> String {
    format!("{}_{}", dir_hash, md5::hex(&pending_norm(command)))
}

/// `write_state_file`: the value and a newline, through a temporary name in
/// the same directory.
pub fn write_state_file(target: &Path, value: &[u8]) -> std::io::Result<()> {
    let dir = target.parent().unwrap_or(Path::new("."));
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(dir)?;
    let base = target.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let (secs, nanos) = os::now();
    let seed = (nanos ^ (secs as u32).rotate_left(11)).wrapping_add(std::process::id().wrapping_mul(2_654_435_761));
    for n in 0..64u32 {
        let temp = dir.join(format!(".{}.{:06x}", base, seed.wrapping_add(n) & 0xff_ffff));
        match std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&temp) {
            Ok(mut f) => {
                let wrote = f.write_all(value).and_then(|_| f.write_all(b"\n"));
                drop(f);
                if let Err(e) = wrote.and_then(|_| std::fs::rename(&temp, target)) {
                    let _ = std::fs::remove_file(&temp);
                    return Err(e);
                }
                return Ok(());
            }
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(e),
        }
    }
    Err(std::io::Error::new(std::io::ErrorKind::AlreadyExists, "no temporary name was free"))
}

/// `find <dir> -type f -mmin +1440 -delete`: the files under `dir` last
/// modified more than a day ago. BSD find counts whole minutes, rounded up,
/// from whole seconds; GNU find compares the times as they are (measured on
/// macOS and in WSL1: a file 86,400 seconds old goes on GNU and stays on BSD).
pub fn sweep_day_old(dir: &Path) {
    let now = SystemTime::now();
    let mut dirs = vec![dir.to_path_buf()];
    while let Some(d) = dirs.pop() {
        let Ok(entries) = std::fs::read_dir(&d) else { continue };
        for entry in entries.flatten() {
            let Ok(kind) = entry.file_type() else { continue };
            if kind.is_dir() {
                dirs.push(entry.path());
                continue;
            }
            if !kind.is_file() {
                continue;
            }
            let Ok(modified) = entry.metadata().and_then(|m| m.modified()) else { continue };
            let old = if cfg!(target_os = "macos") {
                let secs = |t: SystemTime| t.duration_since(SystemTime::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0);
                (secs(now) - secs(modified) + 59) / 60 > 1440
            } else {
                now.duration_since(modified).map(|d| d > Duration::from_secs(86_400)).unwrap_or(false)
            };
            if old {
                let _ = std::fs::remove_file(entry.path());
            }
        }
    }
}
