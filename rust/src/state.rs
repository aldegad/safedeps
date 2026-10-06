//! Where the hooks keep their state, and the advisory log.
//!
//! `advisory.log` is derived from `SAFEDEPS_HOME` and from nothing else:
//! `re-check` reads it as the record of whether an approval ever happened, so
//! the log and the ledger move together or not at all (AGENTS.md).

use std::io::Write;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

/// `GUARD_DIR="${SAFEDEPS_HOME:-${HOME}/.safedeps}"`. An empty
/// `SAFEDEPS_HOME` counts as unset, and an unset `HOME` leaves the path
/// starting at `/.safedeps`, as the shell's expansion does.
pub fn guard_dir() -> PathBuf {
    match std::env::var_os("SAFEDEPS_HOME") {
        Some(h) if !h.is_empty() => PathBuf::from(h),
        _ => {
            let mut p = std::env::var_os("HOME").unwrap_or_default();
            p.push("/.safedeps");
            PathBuf::from(p)
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
