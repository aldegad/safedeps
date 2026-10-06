//! Provider initialization's once-per-process advisory retention. The hook's
//! ordinary advisory writer does not call this. The archive is made first;
//! compaction preserves the live inode and every line outside the INFO channel.
use crate::os;
use std::{fs, io::Write, os::unix::{ffi::OsStrExt, fs::{MetadataExt, OpenOptionsExt}}, path::{Path, PathBuf}, process::{Command, Stdio}, sync::Once};

static CHECKED: Once = Once::new();

pub fn advisory_rotate_once(file: &Path) { CHECKED.call_once(|| rotate(file)); }

fn knob(name: &str, default: u64) -> u64 {
    std::env::var(name).ok().filter(|s| !s.is_empty()).and_then(|s| s.parse().ok()).unwrap_or(default)
}
fn suffixed(file: &Path, suffix: &[u8]) -> PathBuf {
    os::path(&[file.as_os_str().as_bytes(), suffix].concat())
}
fn append(file: &Path, level: &str, message: &[u8]) {
    if let Ok(mut f) = fs::OpenOptions::new().create(true).append(true).mode(0o600).open(file) {
        let _ = write!(f, "[{}] {} ", os::utc_stamp(os::now().0), level);
        let _ = f.write_all(message); let _ = f.write_all(b"\n");
    }
}
struct Lock(PathBuf);
impl Drop for Lock { fn drop(&mut self) { let _ = fs::remove_dir(&self.0); } }

fn rotate(file: &Path) {
    let Ok(meta) = fs::metadata(file) else { return };
    if !meta.is_file() || meta.len() < knob("SAFEDEPS_ADVISORY_LOG_MAX_BYTES", 67_108_864) { return }
    let lock = suffixed(file, b".rotate.lock");
    if fs::create_dir(&lock).is_err() {
        let stale = fs::metadata(&lock).ok().is_some_and(|m| m.mtime() >= 0 &&
            os::now().0.saturating_sub(m.mtime()) > knob("SAFEDEPS_ADVISORY_LOG_LOCK_STALE_SECONDS", 300) as i64);
        if !stale { return }
        let _ = fs::remove_dir(&lock);
        if fs::create_dir(&lock).is_err() { return }
    }
    let _lock = Lock(lock);
    let stamp = os::utc_stamp(os::now().0).replace(['-', ':'], "");
    let archive = suffixed(file, format!(".{}.gz", stamp).as_bytes());
    // gzip is the archive format's existing tool. No shell or command payload
    // is involved; stderr belongs to the refusal line below.
    let archived = fs::OpenOptions::new().create(true).truncate(true).write(true).mode(0o600).open(&archive)
        .ok().and_then(|out| Command::new("gzip").arg("-c").arg(file).stdout(out).stderr(Stdio::null()).status().ok())
        .is_some_and(|s| s.success());
    if !archived {
        let _ = fs::remove_file(&archive);
        append(file, "ERROR", &[b"advisory log rotation failed: could not write ", archive.as_os_str().as_bytes(), b"; the log stays whole and unbounded."].concat());
        return
    }
    let mut temp = None;
    for n in 0..64 {
        let path = suffixed(file, format!(".compact.{:x}{:x}", std::process::id(), n).as_bytes());
        match fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&path) {
            Ok(f) => { temp = Some((path, f)); break }
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(_) => break,
        }
    }
    let Some((tmp, mut target)) = temp else {
        append(file, "ERROR", &[b"advisory log rotation incomplete: archived to ", archive.as_os_str().as_bytes(), b" but could not open a temp file to compact; the live log still holds every line."].concat()); return
    };
    let compact = (|| -> std::io::Result<u64> {
        let bytes = fs::read(file)?;
        let mut kept = 0;
        for line in bytes.split_inclusive(|b| *b == b'\n') {
            let trace = line.first() == Some(&b'[') && line.iter().position(|b| *b == b']')
                .is_some_and(|end| line[end..].starts_with(b"] INFO "));
            if !trace {
                target.write_all(line)?;
                // grep emits a newline after an unterminated final record.
                if !line.ends_with(b"\n") { target.write_all(b"\n")?; }
                kept += 1;
            }
        }
        target.flush()?;
        drop(target);
        let mut from = fs::File::open(&tmp)?;
        let mut live = fs::OpenOptions::new().write(true).truncate(true).open(file)?;
        std::io::copy(&mut from, &mut live)?;
        Ok(kept)
    })();
    let _ = fs::remove_file(&tmp);
    match compact {
        Ok(kept) => {
            append(file, "WARN", &[format!("advisory log rotated: {} bytes archived to ", meta.len()).as_bytes(),
                archive.file_name().unwrap().as_bytes(), format!("; {} evidence line(s) kept live, INFO trace dropped from the live file (still in the archive).", kept).as_bytes()].concat());
            prune(file);
        }
        Err(_) => append(file, "ERROR", &[b"advisory log rotation incomplete: archived to ", archive.as_os_str().as_bytes(), b" but could not compact the live log."].concat()),
    }
}

fn prune(file: &Path) {
    let dir = file.parent().unwrap_or(Path::new("."));
    let prefix = [file.file_name().unwrap_or_default().as_bytes(), b"."].concat();
    let Ok(entries) = fs::read_dir(dir) else { return };
    let mut archives: Vec<_> = entries.filter_map(Result::ok).filter(|e| {
        let name = e.file_name(); let name = name.as_bytes();
        e.file_type().is_ok_and(|t| t.is_file()) && name.starts_with(&prefix) && name.ends_with(b".gz")
    }).map(|e| e.path()).collect();
    archives.sort_by(|a,b| b.cmp(a));
    let mut bytes: u64 = 0;
    for (index, path) in archives.iter().enumerate() {
        bytes = bytes.saturating_add(fs::metadata(path).map(|m| m.len()).unwrap_or(0));
        if index as u64 >= knob("SAFEDEPS_ADVISORY_LOG_KEEP", 5) ||
            index > 0 && bytes > knob("SAFEDEPS_ADVISORY_LOG_ARCHIVE_TOTAL_BYTES", 536_870_912) {
            let _ = fs::remove_file(path);
        }
    }
}
