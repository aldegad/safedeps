//! `safedeps-core pre`: the PreToolUse hook.
//!
//! What is here is the path of a command that is not an install: reading the
//! payload, the truth-source notice, the self budget and its deadline, the
//! detection in each reading, the settlement of a failed reading, and the
//! backstop's trace baseline. A command the detection reads as an install is
//! not judged yet: this says so on stderr and exits 2, and
//! `scripts/safedeps-pre-guard.sh` stays the hook until it is.
//!
//! Each step stands for the step of the bash guard named in its comment, and
//! prints what that step prints. The differences are the ones a process
//! without a shell has, and each is stated where it stands.

use crate::core::{Core, Run};
use crate::ere::Regex;
use crate::grammar;
use crate::jq;
use crate::json::{self, Value};
use crate::lex::Reading;
use crate::{callid, md5, os, state};
use std::io::Write;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime};

type W = Vec<u8>;

const RUNTIME_BUDGET_SECONDS: u64 = 30;
const SELF_BUDGET_MAX_SECONDS: u64 = 25;
const SELF_BUDGET_DEFAULT_SECONDS: u64 = 20;
const ENGAGE_DEFAULT_BYTES: u64 = 1024;
const ENGAGE_MAX_BYTES: u64 = 4096;
const KNOB_MAX_DIGITS: usize = 9;
const KNOB_MAX_INPUT_CHARS: usize = 32;

/// What one judgment says: the hook's stdout and stderr, and its exit status.
/// A judgment under the deadline is answered for when it does not finish, so
/// it writes here and not to the process's own streams.
#[derive(Default)]
struct Out {
    stdout: W,
    stderr: W,
    code: i32,
}

impl Out {
    fn say(&mut self, line: &str) {
        self.stdout.extend_from_slice(line.as_bytes());
        self.stdout.push(b'\n');
    }
    fn warn(&mut self, line: &[u8]) {
        self.stderr.extend_from_slice(line);
        self.stderr.push(b'\n');
    }
}

fn is_space(b: u8) -> bool {
    matches!(b, b' ' | b'\t' | b'\n' | 0x0b | 0x0c | b'\r')
}

/// `$(...)`: a bash string holds no NUL, and the newlines that end the output
/// are dropped.
fn captured(mut v: W) -> W {
    v.retain(|&b| b != 0);
    while v.last() == Some(&b'\n') {
        v.pop();
    }
    v
}

fn to_jq(v: &Value) -> jq::J {
    match v {
        Value::Null => jq::J::Null,
        Value::Bool(b) => jq::J::Bool(*b),
        Value::Num(n) => jq::J::Num(n.clone()),
        Value::Str(s) => jq::arg(s),
        Value::Arr(a) => jq::J::Arr(a.iter().map(to_jq).collect()),
        Value::Obj(o) => jq::J::Obj(o.iter().map(|(k, v)| (jq::text(k), to_jq(v))).collect()),
    }
}

/// `jq -r '<path> // empty'` captured by `$(...)`: a string as its bytes,
/// null and false as nothing, anything else as jq prints it. A number is
/// printed as it was written; jq 1.7 respells one written with an exponent.
fn jq_r(v: Option<&Value>) -> W {
    match v {
        None | Some(Value::Null) | Some(Value::Bool(false)) => W::new(),
        Some(Value::Str(s)) => captured(s.clone()),
        Some(other) => captured(jq::pretty(&to_jq(other)).into_bytes()),
    }
}

/// `.name` as jq indexes it: the value, null for an object without it or for
/// null, and an error (exit 5) for anything else.
fn index<'a>(v: Option<&'a Value>, name: &str) -> Result<Option<&'a Value>, ()> {
    match v {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Obj(_)) => Ok(v.and_then(|o| o.get(name))),
        Some(_) => Err(()),
    }
}

// ---- the knobs -----------------------------------------------------------------

/// `safedeps_normalize_knob`: the digits of a knob's value, or None when it is
/// not a number. Lengths are bash's `${#s}`, characters in the hook's locale.
fn normalize_knob(raw: &[u8]) -> Option<W> {
    if os::bash_len(raw) > KNOB_MAX_INPUT_CHARS {
        return None;
    }
    let mut v: &[u8] = raw;
    while v.first().is_some_and(|&b| is_space(b)) {
        v = &v[1..];
    }
    while v.last().is_some_and(|&b| is_space(b)) {
        v = &v[..v.len() - 1];
    }
    if v.first() == Some(&b'+') {
        v = &v[1..];
    }
    // `^0*([0-9].*)$`: the zeros in front come off, one digit stays.
    let zeros = v.iter().take_while(|&&b| b == b'0').count();
    if zeros > 0 {
        let keep = if zeros < v.len() && v[zeros].is_ascii_digit() { zeros } else { zeros - 1 };
        v = &v[keep..];
    }
    if v.is_empty() || !v.iter().all(|b| b.is_ascii_digit()) {
        return None;
    }
    Some(v.to_vec())
}

struct Knob {
    value: u64,
    invalid_from: W,
    clamped_from: W,
}

fn read_knob(name: &str, default: u64, max: u64) -> Knob {
    use std::os::unix::ffi::OsStringExt;
    let given: W = std::env::var_os(name).map(|v| v.into_vec()).unwrap_or_default();
    let mut k = Knob { value: default, invalid_from: W::new(), clamped_from: W::new() };
    if given.is_empty() {
        return k;
    }
    match normalize_knob(&given) {
        None => {
            let len = os::bash_len(&given);
            k.invalid_from = os::bash_prefix(&given, KNOB_MAX_INPUT_CHARS);
            if len > KNOB_MAX_INPUT_CHARS {
                k.invalid_from.extend_from_slice(format!("... ({} characters)", len).as_bytes());
            }
        }
        Some(digits) => {
            let n: u64 = if digits.len() > KNOB_MAX_DIGITS { u64::MAX } else { String::from_utf8_lossy(&digits).parse().unwrap_or(u64::MAX) };
            if n > max {
                k.clamped_from = digits;
                k.value = max;
            } else {
                k.value = n;
            }
        }
    }
    k
}

// ---- the truth sources (lib/truth-sources.sh) --------------------------------------

fn env_bytes(name: &str) -> W {
    use std::os::unix::ffi::OsStringExt;
    std::env::var_os(name).map(|v| v.into_vec()).unwrap_or_default()
}

/// `safedeps_truth_sources_moved_list`, joined with blanks. Empty when the run
/// uses the canonical sources.
fn truth_sources_moved() -> W {
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
    url(&mut moved, "SAFEDEPS_OSV_BATCH_API_URL", "https://api.osv.dev/v1/querybatch", "osv-batch");
    url(&mut moved, "SAFEDEPS_KEV_CATALOG_URL", "https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json", "kev");
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

// ---- the judgment ------------------------------------------------------------------

struct Call {
    input: Value,
    command: W,
    /// `GUARD_DIR` as the text the guard builds its paths from.
    guard: W,
    guard_dir: PathBuf,
}

fn cat(parts: &[&[u8]]) -> W {
    parts.concat()
}

/// `guard_deny_undecided_scan`.
fn deny_undecided_scan(call: &Call, out: &mut Out, which: &str) {
    state::log_advisory(
        &call.guard_dir,
        &cat(&[
            format!("pre-guard DENY: the command scanner failed ({}) — undecided, fail-closed. Command: ", which).as_bytes(),
            &call.command,
        ]),
    );
    out.say(&jq::deny("safedeps: UNDECIDED, not unsafe — safedeps could not finish reading this command: a scanner step (awk, grep or sed) failed, or the command does not close (an open quote, a heredoc without its terminator). So it could not tell whether the command installs a dependency or what it would install. It is blocked fail-closed, and no finding is claimed. Close the command, or check that `echo x | awk 1` works, then retry."));
}

/// `guard_looks_like_install_unscanned`: the command names a package manager's
/// executable anywhere, in any case, once its line continuations are out.
fn looks_like_install_unscanned(command: &[u8]) -> bool {
    let mut joined = W::with_capacity(command.len());
    let mut i = 0;
    while i < command.len() {
        if command[i] == b'\\' && command.get(i + 1) == Some(&b'\n') {
            i += 2;
            continue;
        }
        joined.push(command[i]);
        i += 1;
    }
    Regex::new(&format!("({})", grammar::EXECUTABLES), true).map(|re| re.is_match(&joined)).unwrap_or(true)
}

/// `guard_settle_scan_failure`. True when the command is denied.
fn settle_scan_failure(call: &Call, failed: bool, out: &mut Out) -> bool {
    if !failed {
        return false;
    }
    if looks_like_install_unscanned(&call.command) {
        deny_undecided_scan(call, out, "the command names a package manager");
        return true;
    }
    state::log_advisory(
        &call.guard_dir,
        &cat(&[b"pre-guard: the command scanner failed; the command names no package manager and was allowed. Command: ", &call.command]),
    );
    out.warn(b"safedeps: this command could not be fully read (a scanner step failed, or the command does not close). It names no package manager, so it was allowed. The failure is recorded in advisory.log.");
    false
}

/// `compute_pending_key`'s normal form of a command, as its sed writes it: on
/// each line, every ` --ignore-scripts` that is a whole word is taken out,
/// each run of blanks becomes one blank, and a blank at either end goes.
fn pending_norm(command: &[u8]) -> W {
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
            if is_space(b) {
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
    captured(lines.join(&b'\n'))
}

/// `compute_pending_key <dir hash> <command>`.
fn pending_key(dir_hash: &str, command: &[u8]) -> String {
    format!("{}_{}", dir_hash, md5::hex(&pending_norm(command)))
}

/// `write_state_file`: the value and a newline, through a temporary name in
/// the same directory.
fn write_state_file(target: &Path, value: &[u8]) -> std::io::Result<()> {
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
fn sweep_day_old(dir: &Path) {
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

/// `guard_backstop_trace_baseline`: the record the PostToolUse backstop reads
/// to tell whether this command left a trace in the cwd's node tree. It
/// decides no verdict; anything that fails leaves no entry, which the
/// backstop counts as a trace.
fn backstop_trace_baseline(call: &Call, cwd: &[u8]) {
    let p = grammar::patterns();
    let Ok(re) = Regex::new(&p.backstop_re, true) else { return };
    // `printf '%s' "$COMMAND" | grep -qiE`: grep reads lines.
    if !call.command.split(|&b| b == b'\n').any(|line| re.is_match(line)) {
        return;
    }
    let Some(id) = callid::call_id(&call.input) else { return };
    let dir = os::realpath(cwd);
    let dir_hash = md5::hex(&dir);
    let entry_text = cat(&[&call.guard, b"/pending/backstop"]);
    let entry_dir = os::path(&entry_text);
    if callid::call_base("", &id).is_none() {
        return;
    }
    let base = cat(&[&entry_text, b"/id-", id.as_bytes()]);
    if std::fs::DirBuilder::new().recursive(true).mode(0o700).create(&entry_dir).is_err() {
        return;
    }
    sweep_day_old(&entry_dir);
    let d = os::path(&dir);
    let lock = os::tree_inode(&d.join("package-lock.json"));
    let hidden = os::tree_inode(&d.join("node_modules/.package-lock.json"));
    let tree = os::tree_inode(&d.join("node_modules"));
    let mut present = 0;
    let mut subsecond = 0;
    for rel in ["package-lock.json", "node_modules/.package-lock.json", "node_modules"] {
        let path = d.join(rel);
        if std::fs::symlink_metadata(&path).is_err() {
            continue;
        }
        present += 1;
        if os::clock_has_subsecond(&os::tree_clock(&path)) {
            subsecond += 1;
        }
    }
    let trace_text = cat(&[&base, b".trace"]);
    let trace = os::path(&trace_text);
    // `touch`: made when it is not there, and its times set to now either way.
    let touched = std::fs::OpenOptions::new().create(true).append(true).mode(0o600).open(&trace).and_then(|f| {
        let now = SystemTime::now();
        f.set_times(std::fs::FileTimes::new().set_accessed(now).set_modified(now))
    });
    if touched.is_err() {
        return;
    }
    let mut resolution = "seconds";
    if present > 0 && subsecond == present && os::clock_has_subsecond(&os::file_clock(&trace, b'm', false)) {
        resolution = "subsecond";
    } else {
        let (now, _) = os::now();
        let at = SystemTime::UNIX_EPOCH + Duration::from_secs((now - 2).max(0) as u64);
        let set = std::fs::OpenOptions::new().append(true).open(&trace).and_then(|f| f.set_times(std::fs::FileTimes::new().set_accessed(at).set_modified(at)));
        if set.is_err() {
            let _ = std::fs::remove_file(&trace);
            return;
        }
    }
    let entry = jq::obj(vec![
        ("key", jq::s(&pending_key(&dir_hash, &call.command))),
        ("baseline", jq::arg(&trace_text)),
        ("resolution", jq::s(resolution)),
        (
            "inodes",
            jq::obj(vec![("package-lock.json", jq::s(&lock)), ("node_modules/.package-lock.json", jq::s(&hidden)), ("node_modules", jq::s(&tree))]),
        ),
        (
            "clocks",
            jq::obj(vec![
                ("package-lock.json", jq::s(&os::tree_clock(&d.join("package-lock.json")))),
                ("node_modules/.package-lock.json", jq::s(&os::tree_clock(&d.join("node_modules/.package-lock.json")))),
            ]),
        ),
    ]);
    if write_state_file(&os::path(&cat(&[&base, b".json"])), jq::compact(&entry).as_bytes()).is_err() {
        let _ = std::fs::remove_file(&trace);
    }
}

/// `pwd`: the directory in `PWD` when that names where the process is, the
/// kernel's answer otherwise.
fn shell_pwd() -> W {
    use std::os::unix::ffi::OsStringExt;
    use std::os::unix::fs::MetadataExt;
    if let Some(pwd) = std::env::var_os("PWD") {
        let p = Path::new(&pwd);
        if p.is_absolute() {
            if let (Ok(a), Ok(b)) = (std::fs::metadata(p), std::fs::metadata(".")) {
                if a.dev() == b.dev() && a.ino() == b.ino() {
                    return pwd.into_vec();
                }
            }
        }
    }
    std::env::current_dir().map(|p| p.into_os_string().into_vec()).unwrap_or_default()
}

/// The judgment of one command, from the detection on. `Err(())` is an
/// install: the part of the hook that judges one is not written.
fn judge(call: &Call) -> Result<Out, ()> {
    let mut out = Out::default();
    let core = Core::new();
    let mut run = Run::new(&core);
    let mut cwd = jq_r(index(Some(&call.input), "cwd").ok().flatten());
    if cwd.is_empty() {
        cwd = shell_pwd();
    }
    let mut closed = false;
    let mut any_install = false;
    let mut detect = |run: &mut Run, r: Reading| {
        run.reading = Some(r);
        if run.command_reads(&call.command) {
            closed = true;
        }
        if run.is_install(&call.command) {
            any_install = true;
            let _ = run.pipes_install_to_shell(&call.command);
        } else if run.hides_install(&call.command) {
            any_install = true;
        }
        run.reading = None;
    };
    detect(&mut run, Reading::Bash);
    if run.diverge {
        detect(&mut run, Reading::Zsh);
        detect(&mut run, Reading::Dash);
    }
    if !closed {
        run.failed = true;
    }
    if any_install {
        return Err(());
    }
    if settle_scan_failure(call, run.failed, &mut out) {
        return Ok(out);
    }
    backstop_trace_baseline(call, &cwd);
    Ok(out)
}

fn emit(out: &Out) -> i32 {
    let _ = std::io::stderr().lock().write_all(&out.stderr);
    let mut so = std::io::stdout().lock();
    let _ = so.write_all(&out.stdout);
    let _ = so.flush();
    out.code
}

const NOT_WRITTEN: &str = "safedeps-core pre: this command reads as a dependency install, and the part of the hook that judges one is not written yet. scripts/safedeps-pre-guard.sh is the PreToolUse hook.";

pub fn main(input: &[u8]) -> i32 {
    let started = Instant::now();
    // `umask 077; mkdir -p "$GUARD_DIR" "$SNAPSHOT_DIR"`, before anything is read.
    os::set_umask(0o077);
    let guard_dir = state::guard_dir();
    if state::ensure_dirs(&guard_dir).is_err() {
        return 1;
    }
    if let Some(why) = crate::stamp::refusal() {
        state::log_advisory(&guard_dir, format!("pre-guard DENY: {}", why).as_bytes());
        println!("{}", jq::deny(&why));
        return 0;
    }

    // `INPUT=$(cat)`, then jq twice. jq ends with 5 on text that is not JSON
    // and on a value it cannot index, and the guard ends with it (measured,
    // jq 1.7 and 1.7.1). jq reads every JSON text of its input; the engines
    // send one, and more than one is refused here the same way.
    let input = captured(input.to_vec());
    if input.iter().all(|&b| is_space(b)) {
        return 0;
    }
    let Ok(payload) = json::parse_one(&input) else { return 5 };
    let Ok(tool) = index(Some(&payload), "tool_name") else { return 5 };
    let tool = jq_r(tool);
    let Ok(tool_input) = index(Some(&payload), "tool_input") else { return 5 };
    let Ok(command) = index(tool_input, "command") else { return 5 };
    let command = jq_r(command);
    if tool != b"Bash" || command.is_empty() {
        return 0;
    }

    // `safedeps_guard_announce_truth_sources`
    let moved = truth_sources_moved();
    if !moved.is_empty() {
        state::log_advisory(
            &guard_dir,
            &cat(&[b"pre-guard: advisory truth source moved: ", &moved, " — this run did not judge against the canonical sources.".as_bytes()]),
        );
    }

    // The self budget.
    let budget = read_knob("SAFEDEPS_SELF_BUDGET_SECONDS", SELF_BUDGET_DEFAULT_SECONDS, SELF_BUDGET_MAX_SECONDS);
    let engage = read_knob("SAFEDEPS_BUDGET_ENGAGE_BYTES", ENGAGE_DEFAULT_BYTES, ENGAGE_MAX_BYTES);
    let disabled = !env_bytes("SAFEDEPS_BUDGET_DISABLED").is_empty();
    let size = os::bash_len(&command) as u64;
    let call = Call { input: payload, command, guard: state::guard_text(), guard_dir: guard_dir.clone() };
    let mut err = std::io::stderr().lock();

    if size < engage.value || disabled {
        if disabled && size >= engage.value {
            state::log_advisory(&guard_dir, format!("pre-guard: SAFEDEPS_BUDGET_DISABLED is set — the self-budget deadline is OFF for this command ({} bytes). Past the {}s runtime hook budget this gate is killed and the install proceeds unjudged.", size, RUNTIME_BUDGET_SECONDS).as_bytes());
            let _ = writeln!(err, "safedeps: SAFEDEPS_BUDGET_DISABLED is set, so the self-budget deadline is OFF for this command. The judgment now runs with no deadline of its own, and past the {}s runtime hook budget the runtime kills this gate and the install proceeds unjudged. Unset it to restore the gate.", RUNTIME_BUDGET_SECONDS);
        }
        drop(err);
        return match judge(&call) {
            Ok(out) => emit(&out),
            Err(()) => {
                eprintln!("{}", NOT_WRITTEN);
                2
            }
        };
    }

    // The deadline is in play: say what the knobs came to, as the guard does
    // before it starts the judgment.
    let b = |v: &[u8]| String::from_utf8_lossy(v).into_owned();
    let note = |dir: &Path, log: W, line: W, err: &mut std::io::StderrLock| {
        state::log_advisory(dir, &log);
        let _ = err.write_all(&line);
        let _ = err.write_all(b"\n");
    };
    if !budget.clamped_from.is_empty() {
        note(
            &guard_dir,
            format!("pre-guard: SAFEDEPS_SELF_BUDGET_SECONDS={} exceeds the {}s ceiling — clamped to {}s. Above the ceiling the {}s runtime hook budget kills this gate first and the install proceeds unjudged.", b(&budget.clamped_from), SELF_BUDGET_MAX_SECONDS, budget.value, RUNTIME_BUDGET_SECONDS).into_bytes(),
            format!("safedeps: SAFEDEPS_SELF_BUDGET_SECONDS={}s exceeds the {}s ceiling and was clamped to {}s. The ceiling sits below the runtime hook budget ({}s); above it the runtime kills this gate mid-judgment and the install runs unjudged, so raising the value removes the check rather than extending it. Lower values are honoured as given.", b(&budget.clamped_from), SELF_BUDGET_MAX_SECONDS, budget.value, RUNTIME_BUDGET_SECONDS).into_bytes(),
            &mut err,
        );
    }
    if !env_bytes("SAFEDEPS_BUDGET_CHILD").is_empty() {
        note(
            &guard_dir,
            "pre-guard: SAFEDEPS_BUDGET_CHILD is set in the environment and is ignored — the parent/child marker moved to argv, where it cannot be injected. The deadline is running normally.".as_bytes().to_vec(),
            b"safedeps: SAFEDEPS_BUDGET_CHILD is set in the environment and has no effect. The parent/child marker moved into argv so it cannot be set from outside; the deadline is running normally. To turn the deadline off deliberately, set SAFEDEPS_BUDGET_DISABLED.".to_vec(),
            &mut err,
        );
    }
    if !engage.clamped_from.is_empty() {
        note(
            &guard_dir,
            format!("pre-guard: SAFEDEPS_BUDGET_ENGAGE_BYTES={} exceeds the {}-byte ceiling — clamped to {}. Above the ceiling the deadline never engages and the judgment runs unbounded.", b(&engage.clamped_from), ENGAGE_MAX_BYTES, engage.value).into_bytes(),
            format!("safedeps: SAFEDEPS_BUDGET_ENGAGE_BYTES={} exceeds the {}-byte ceiling and was clamped to {}. The engage size decides when the deadline runs at all, so raising it past the ceiling would disable the deadline rather than tune it. To turn the deadline off deliberately, set SAFEDEPS_BUDGET_DISABLED.", b(&engage.clamped_from), ENGAGE_MAX_BYTES, engage.value).into_bytes(),
            &mut err,
        );
    }
    if !engage.invalid_from.is_empty() {
        note(
            &guard_dir,
            cat(&[b"pre-guard: SAFEDEPS_BUDGET_ENGAGE_BYTES='", &engage.invalid_from, format!("' is not a whole number of bytes — using the {}-byte default instead.", engage.value).as_bytes()]),
            cat(&[b"safedeps: SAFEDEPS_BUDGET_ENGAGE_BYTES='", &engage.invalid_from, format!("' is not a whole number of bytes, so the {}-byte default is in force.", engage.value).as_bytes()]),
            &mut err,
        );
    }
    if !budget.invalid_from.is_empty() {
        note(
            &guard_dir,
            cat(&[b"pre-guard: SAFEDEPS_SELF_BUDGET_SECONDS='", &budget.invalid_from, format!("' is not a whole number of seconds — using the {}s default instead.", budget.value).as_bytes()]),
            cat(&[b"safedeps: SAFEDEPS_SELF_BUDGET_SECONDS='", &budget.invalid_from, format!("' is not a whole number of seconds, so the {}s default is in force. Set a plain integer at or below the {}s ceiling.", budget.value, SELF_BUDGET_MAX_SECONDS).as_bytes()]),
            &mut err,
        );
    }
    drop(err);

    // The judgment runs beside the deadline, and the deadline is read from
    // the clock, from when this process started. The bash guard spawns itself
    // as a child for this and kills the child's tree; here the judgment is a
    // thread, and the process ending is what stops it. Nothing the judgment
    // has to say is written until it has finished.
    let (tx, rx) = std::sync::mpsc::channel::<Result<Out, ()>>();
    let deadline = Duration::from_secs(budget.value);
    let left = deadline.saturating_sub(started.elapsed());
    // With no time left there is no judgment to start: the guard's first
    // look at the clock ends its child.
    let worker = if left.is_zero() {
        drop(tx);
        None
    } else {
        Some(std::thread::spawn(move || {
            let r = judge(&call);
            let _ = tx.send(r);
        }))
    };
    match rx.recv_timeout(left) {
        Ok(Ok(out)) => {
            if let Some(w) = worker {
                let _ = w.join();
            }
            emit(&out)
        }
        Ok(Err(())) => {
            eprintln!("{}", NOT_WRITTEN);
            2
        }
        Err(_) => {
            // 143 is what the guard records for a judgment it stopped: the
            // status of a child ended by its TERM.
            state::log_advisory(&guard_dir, format!("pre-guard DENY: judgment unfinished within the {}s self-budget (command {} bytes, child rc=143) — fail-closed, not a detection.", budget.value, size).as_bytes());
            let mut clamp = W::new();
            if !budget.clamped_from.is_empty() {
                clamp = format!(" Your SAFEDEPS_SELF_BUDGET_SECONDS={} was clamped to the {}s ceiling: above it the {}s runtime hook budget kills this gate mid-judgment and the install runs unjudged, so raising it removes the check rather than extending it.", b(&budget.clamped_from), SELF_BUDGET_MAX_SECONDS, RUNTIME_BUDGET_SECONDS).into_bytes();
            } else if !budget.invalid_from.is_empty() {
                clamp = cat(&[b" Your SAFEDEPS_SELF_BUDGET_SECONDS='", &budget.invalid_from, format!("' is not a whole number of seconds, so the {}s default is in force.", budget.value).as_bytes()]);
            }
            let reason = cat(&[
                format!("safedeps: UNDECIDED, not unsafe — safedeps could not finish judging this command within its {}s budget ({} bytes of command text), so it is blocked fail-closed. Nothing was detected in it; the gate simply did not get to an answer, and an install it cannot judge must not run. Scan cost grows with command length. Split the command, or write long content with a file-writing tool instead of one very large shell command, and retry.", budget.value, size).as_bytes(),
                &clamp,
            ]);
            let answer = jq::compact(&jq::obj(vec![(
                "hookSpecificOutput",
                jq::obj(vec![("hookEventName", jq::s("PreToolUse")), ("permissionDecision", jq::s("deny")), ("permissionDecisionReason", jq::arg(&reason))]),
            )]));
            println!("{}", answer);
            // The judgment is still running; leaving ends it.
            let _ = std::io::stdout().flush();
            std::process::exit(0);
        }
    }
}
