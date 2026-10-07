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

mod log;
pub use log::advisory_rotate_once;

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
    let secs = os::wall(os::WallRole::AdvisoryHeader).seconds();
    let mut line = crate::os::utc_stamp(secs).into_bytes();
    line.push(b'\t');
    line.extend_from_slice(text);
    line.push(b'\n');
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).mode(0o600).open(dir.join("advisory.log")) {
        let _ = f.write_all(&line);
    }
}

pub const DEFAULT_OSV_BATCH_API_URL: &str = "https://api.osv.dev/v1/querybatch";
pub const DEFAULT_KEV_CATALOG_URL: &str = "https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json";

/// `safedeps_truth_sources_moved_list`, joined with blanks. Empty when the run
/// uses the canonical sources.
pub fn truth_sources_moved() -> W {
    fn env_bytes(name: &str) -> W {
        use std::os::unix::ffi::OsStringExt;
        std::env::var_os(name).map(|v| v.into_vec()).unwrap_or_default()
    }
    fn put(moved: &mut Vec<W>, label: &str, value: &[u8]) {
        let mut m = format!("{}=", label).into_bytes();
        m.extend_from_slice(value);
        moved.push(m);
    }
    fn url(moved: &mut Vec<W>, name: &str, default: &str, label: &str) {
        let v = env_bytes(name);
        if !v.is_empty() && v != default.as_bytes() {
            put(moved, label, &v);
        }
    }
    fn named(moved: &mut Vec<W>, name: &str, label: &str) {
        let v = env_bytes(name);
        if !v.is_empty() {
            put(moved, label, &v);
        }
    }
    let mut moved: Vec<W> = Vec::new();
    url(&mut moved, "SAFEDEPS_OSV_API_URL", "https://api.osv.dev/v1/query", "osv");
    url(&mut moved, "SAFEDEPS_OSV_BATCH_API_URL", DEFAULT_OSV_BATCH_API_URL, "osv-batch");
    url(&mut moved, "SAFEDEPS_KEV_CATALOG_URL", DEFAULT_KEV_CATALOG_URL, "kev");
    url(&mut moved, "SAFEDEPS_GHSA_API_URL", "https://api.github.com/advisories", "ghsa");
    named(&mut moved, "SAFEDEPS_NPM_CLOSURE_FIXTURE_JSON", "npm-closure-fixture");
    named(&mut moved, "SAFEDEPS_YARN_INFO_FIXTURE_NDJSON", "yarn-info-fixture");
    if !env_bytes("SAFEDEPS_NPM_OVERRIDES_JSON").is_empty() {
        put(&mut moved, "npm-overrides", b"set");
    }
    named(&mut moved, "SAFEDEPS_RECHECK_FIXTURE_JSON", "recheck-fixture");
    url(&mut moved, "SAFEDEPS_LEDGER_DEFAULT_TTL_DAYS", "30", "ledger-ttl-days");
    named(&mut moved, "SAFEDEPS_NPM_TEST_REGISTRY", "npm-test-registry");
    moved.join(&b' ')
}

#[cfg(test)]
#[test]
fn truth_sources_match_cli() {
    use std::{collections::BTreeSet, process::Command};
    if let Ok(expected) = std::env::var("SAFEDEPS_TRUTH_TEST_EXPECTED") {
        assert_eq!(truth_sources_moved(), expected.as_bytes(), "native truth-source notice");
        return;
    }
    let cli = include_str!("../../lib/truth-sources.sh");
    let native = include_str!("state.rs").split_once("pub fn truth_sources_moved() -> W {").unwrap().1
        .split_once("\n}\n").unwrap().0;
    let moved = cli.split_once("safedeps_truth_sources_moved_list() {").unwrap().1
        .split_once("\n}\n").unwrap().0;
    let names = |source: &str| -> BTreeSet<String> {
        source.split("SAFEDEPS_").skip(1).map(|tail| {
            let end = tail.find(|c: char| !c.is_ascii_uppercase() && c != '_' && !c.is_ascii_digit())
                .unwrap_or(tail.len());
            format!("SAFEDEPS_{}", &tail[..end])
        }).filter(|name| !name.starts_with("SAFEDEPS_DEFAULT_")).collect()
    };
    let sources = [
        ("SAFEDEPS_OSV_API_URL", "osv", Some("https://api.osv.dev/v1/query")),
        ("SAFEDEPS_OSV_BATCH_API_URL", "osv-batch", Some("https://api.osv.dev/v1/querybatch")),
        ("SAFEDEPS_KEV_CATALOG_URL", "kev", Some("https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json")),
        ("SAFEDEPS_GHSA_API_URL", "ghsa", Some("https://api.github.com/advisories")),
        ("SAFEDEPS_NPM_CLOSURE_FIXTURE_JSON", "npm-closure-fixture", None),
        ("SAFEDEPS_YARN_INFO_FIXTURE_NDJSON", "yarn-info-fixture", None),
        ("SAFEDEPS_NPM_OVERRIDES_JSON", "npm-overrides", None),
        ("SAFEDEPS_RECHECK_FIXTURE_JSON", "recheck-fixture", None),
        ("SAFEDEPS_LEDGER_DEFAULT_TTL_DAYS", "ledger-ttl-days", Some("30")),
        ("SAFEDEPS_NPM_TEST_REGISTRY", "npm-test-registry", None),
    ];
    let expected_names: BTreeSet<_> = sources.iter().map(|(name, _, _)| name.to_string()).collect();
    assert_eq!(names(native), expected_names, "native truth-source inputs");
    assert_eq!(names(moved), expected_names, "CLI truth-source inputs");
    let possible = cli.split_once("safedeps_truth_sources_possibly_moved() {").unwrap().1
        .split_once("\n}\n").unwrap().0;
    let mut possible_names = expected_names.clone();
    possible_names.insert("SAFEDEPS_ADVISORY_LOG".into());
    assert_eq!(names(possible), possible_names, "CLI prefilter also observes the retired log override");

    let check = |env: &[(&str, String)], expected: &str, possibly: bool| {
        let mut shell = Command::new("/bin/bash");
        shell.env_clear().env("PATH", "/usr/bin:/bin").env("LC_ALL", "C");
        shell.args(["-c", &format!("{cli}\nsafedeps_truth_sources_moved_list\nprintf '\\0'\nif safedeps_truth_sources_possibly_moved; then printf true; else printf false; fi")]);
        for (name, value) in env { shell.env(name, value); }
        let result = shell.output().expect("run CLI truth-source reader");
        assert!(result.status.success(), "CLI reader failed: {:?}", result);
        let fields: Vec<_> = result.stdout.split(|b| *b == 0).collect();
        assert_eq!(fields, [expected.as_bytes(), if possibly { b"true" } else { b"false" }], "CLI environment: {env:?}");
        // A child owns the environment; other Rust unit tests keep theirs.
        let mut child = Command::new(std::env::current_exe().unwrap());
        child.env_clear().env("PATH", "/usr/bin:/bin").env("LC_ALL", "C")
            .env("SAFEDEPS_TRUTH_TEST_EXPECTED", expected)
            .args(["--exact", "state::truth_sources_match_cli", "--nocapture"]);
        for (name, value) in env { child.env(name, value); }
        let result = child.output().expect("run native truth-source reader in isolation");
        assert!(result.status.success(), "native environment {env:?}: {}{}",
            String::from_utf8_lossy(&result.stdout), String::from_utf8_lossy(&result.stderr));
    };
    check(&[], "", false);
    for (name, label, default) in sources {
        check(&[(name, String::new())], "", false);
        if let Some(default) = default {
            check(&[(name, default.into())], "", true);
            for changed in [format!("{default}/"), format!(" {default}"), default.to_ascii_uppercase()] {
                if changed != default { check(&[(name, changed.clone())], &format!("{label}={changed}"), true); }
            }
        }
        let value = "fixture with spaces\t한글\nend";
        let shown = if name == "SAFEDEPS_NPM_OVERRIDES_JSON" { "set" } else { value };
        check(&[(name, value.into())], &format!("{label}={shown}"), true);
    }
    let all: Vec<_> = sources.iter().map(|(name, _, _)| (*name, "changed".to_string())).collect();
    let notice = sources.iter().map(|(name, label, _)| format!("{label}={}",
        if *name == "SAFEDEPS_NPM_OVERRIDES_JSON" { "set" } else { "changed" })).collect::<Vec<_>>().join(" ");
    check(&all, &notice, true);
    check(&[("SAFEDEPS_ADVISORY_LOG", "ignored.log".into())], "", true);
    check(&[("SAFEDEPS_UNLISTED_SOURCE", "ignored".into())], "", false);
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
                        let age = os::wall(os::WallRole::StateLockAge).seconds() - m.mtime();
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
    renamed_file(target, |f| f.write_all(value).and_then(|_| f.write_all(b"\n")))
}

/// Keep the source's bytes, through the same private temporary file and
/// rename as a state record. Unlike write_state_file, this adds no newline.
pub fn copy_state_file(source: &Path, target: &Path) -> std::io::Result<()> {
    let mut from = std::fs::File::open(source)?;
    renamed_file(target, |to| std::io::copy(&mut from, to).map(|_| ()))
}

fn renamed_file(target: &Path, write: impl FnOnce(&mut std::fs::File) -> std::io::Result<()>) -> std::io::Result<()> {
    let dir = target.parent().unwrap_or(Path::new("."));
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(dir)?;
    let base = target.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let stamp = os::wall(os::WallRole::StateTempName);
    let (secs, nanos) = (stamp.seconds(), stamp.nanos());
    let seed = (nanos ^ (secs as u32).rotate_left(11)).wrapping_add(std::process::id().wrapping_mul(2_654_435_761));
    for n in 0..64u32 {
        let temp = dir.join(format!(".{}.{:06x}", base, seed.wrapping_add(n) & 0xff_ffff));
        match std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&temp) {
            Ok(mut f) => {
                let wrote = write(&mut f);
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
    sweep_old(dir, |_| true)
}

/// Install pending records share their directory with other bookkeeping.
/// Match the hook's find expression: only regular *.json and *.trace files.
pub fn sweep_pending(dir: &Path) {
    sweep_old(dir, |p| {
        use std::os::unix::ffi::OsStrExt;
        p.file_name().is_some_and(|n| { let n=n.as_bytes(); n.ends_with(b".json")||n.ends_with(b".trace") })
    })
}

fn sweep_old(dir: &Path, selected: impl Fn(&Path)->bool) {
    let now = os::wall(os::WallRole::StateRetention).system_time();
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
            if !selected(&entry.path()) { continue; }
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
