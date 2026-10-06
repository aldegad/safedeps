//! `safedeps-core pre`: the PreToolUse hook.
//!
//! The common entry owns payload reading, truth-source notices, the deadline
//! and scan settlement. Codex installs use the shared target, snapshot,
//! ledger and pending-state path. The Claude install path still awaits B's
//! verified rewrite implementation and exits 2. The installed hook remains
//! `scripts/safedeps-pre-guard.sh` until integration is complete.
//!
//! Each step stands for the step of the bash guard named in its comment, and
//! prints what that step prints. The differences are the ones a process
//! without a shell has, and each is stated where it stands.

use crate::core::{Core, Run};
use crate::ere::Regex;
use crate::grammar;
use crate::jq;
use crate::json::{self, Value};
use crate::{callid, md5, os, state};
use std::io::Write;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime};

type W = Vec<u8>;
mod budget;
mod snapshot;
mod targets;
mod pending;
mod readings;
mod effects;
mod install;
pub fn probe(input:&[u8])->i32 {
    match json::parse_one(input).ok().and_then(|v|v.get("op").and_then(Value::as_str).map(str::to_string)).as_deref() {
        Some("targets"|"target-statements")=>targets::probe(input),
        Some("readings")=>readings::probe(input),
        Some("install-codex")=>install::probe(input),
        Some("invoke-quote")=>install::quote_probe(input),
        _=>snapshot::probe(input),
    }
}

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

/// `jq -r '<path> // empty'` captured by `$(...)`: a string as its bytes,
/// null and false as nothing, anything else as jq prints it. A number is
/// printed as it was written; jq 1.7 respells one written with an exponent.
fn jq_r(v: Option<&Value>) -> W {
    match v {
        None | Some(Value::Null) | Some(Value::Bool(false)) => W::new(),
        Some(Value::Str(s)) => captured(s.clone()),
        Some(other) => captured(jq::pretty(&jq::from_value(other)).into_bytes()),
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

// ---- the judgment ------------------------------------------------------------------

struct Call {
    input: json::Stream,
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
    let Some(id) = callid::from_stream(&call.input) else { return };
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
    state::sweep_day_old(&entry_dir);
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
        let now = os::wall(os::WallRole::BackstopTouch).system_time();
        f.set_times(std::fs::FileTimes::new().set_accessed(now).set_modified(now))
    });
    if touched.is_err() {
        return;
    }
    let mut resolution = "seconds";
    if present > 0 && subsecond == present && os::clock_has_subsecond(&os::file_clock(&trace, b'm', false)) {
        resolution = "subsecond";
    } else {
        let now = os::wall(os::WallRole::BackstopFallback).seconds();
        let at = SystemTime::UNIX_EPOCH + Duration::from_secs((now - 2).max(0) as u64);
        let set = std::fs::OpenOptions::new().append(true).open(&trace).and_then(|f| f.set_times(std::fs::FileTimes::new().set_accessed(at).set_modified(at)));
        if set.is_err() {
            let _ = std::fs::remove_file(&trace);
            return;
        }
    }
    let entry = jq::obj(vec![
        ("key", jq::s(&state::pending_key(&dir_hash, &call.command))),
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
    if state::write_state_file(&os::path(&cat(&[&base, b".json"])), jq::compact(&entry).as_bytes()).is_err() {
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

/// The shared reading driver detects once and obtains facts only for an
/// install. Err marks the still-unintegrated Claude rewrite path.
fn judge(call: &Call) -> Result<Out, ()> {
    let mut out = Out::default();
    let core = Core::new();
    let mut run = Run::new(&core);
    let mut cwd = match jq::capture_field(&call.input, &["cwd"]) {
        Ok(cwd) => cwd,
        Err(code) => return Ok(Out { code, ..Out::default() }),
    };
    if cwd.is_empty() {
        cwd = shell_pwd();
    }
    let read = readings::Readings::collect(&mut run, &call.command, &cwd);
    if read.yes("any_install") {
        if !jq::stream_has(&call.input, "turn_id") { return Err(()) }
        return Ok(install::judge(call, &mut run, &cwd, &read,
            |_,_| unreachable!("Codex must not ask for a rewrite")));
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

const NOT_WRITTEN: &str = "safedeps-core pre: this Claude install needs the inert rewrite implementation, which is not integrated yet. scripts/safedeps-pre-guard.sh is the PreToolUse hook.";

/// A stale checkout can settle only the existing unscanned-manager question.
/// It never calls the old judgment or creates a snapshot, pending record or
/// trace baseline. An unreadable payload is not evidence of an absent name.
fn stale(input: &[u8], why: &str, guard: &Path) -> i32 {
    let _ = std::fs::DirBuilder::new().recursive(true).mode(0o700).create(guard);
    let payload = json::parse_one(input).ok();
    let tool = payload.as_ref().and_then(|p| p.get("tool_name")).and_then(Value::as_str);
    let command = payload.as_ref().and_then(|p| p.get("tool_input")).and_then(|p| p.get("command"));
    let disposition = match (tool, command) {
        (Some("Bash"), Some(Value::Str(command))) => {
            if looks_like_install_unscanned(command) { "the command names a package manager" }
            else {
                let message = format!("{} The command names no package manager and was allowed without a judgment.", why);
                state::log_advisory(guard, format!("pre-guard: {}", message).as_bytes());
                eprintln!("{}", message);
                return 0;
            }
        }
        (Some(tool), _) if tool != "Bash" => {
            let message = format!("{} This is not a Bash tool call.", why);
            state::log_advisory(guard, format!("pre-guard: {}", message).as_bytes());
            eprintln!("{}", message);
            return 0;
        }
        _ => "the Bash command could not be read from the payload",
    };
    let reason = format!("safedeps: UNDECIDED — {} {}; no dependency judgment was made.", why, disposition);
    state::log_advisory(guard, format!("pre-guard DENY: {}", reason).as_bytes());
    eprintln!("{}", reason);
    println!("{}", jq::deny(&reason));
    0
}

pub fn main(input: &[u8], budget_child: bool) -> i32 {
    let started = Instant::now();
    // `umask 077; mkdir -p "$GUARD_DIR" "$SNAPSHOT_DIR"`, before anything is read.
    os::set_umask(0o077);
    let guard_dir = state::guard_dir();
    if let Some(why) = crate::stamp::refusal() {
        return stale(input, &why, &guard_dir);
    }
    if state::ensure_dirs(&guard_dir).is_err() {
        return 1;
    }

    // `INPUT=$(cat)`, then jq twice. Both invocations read the complete
    // stream before the tool/command branch, even for a non-Bash tool.
    let input = captured(input.to_vec());
    let payload = json::read(&input);
    let tool = match jq::capture_field(&payload, &["tool_name"]) {
        Ok(v) => v, Err(code) => return code,
    };
    let command = match jq::capture_field(&payload, &["tool_input", "command"]) {
        Ok(v) => v, Err(code) => return code,
    };
    if tool != b"Bash" || command.is_empty() {
        return 0;
    }

    // `safedeps_guard_announce_truth_sources`
    let moved = state::truth_sources_moved();
    if !budget_child && !moved.is_empty() {
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

    if size < engage.value || disabled || budget_child {
        if disabled && size >= engage.value && !budget_child {
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

    // The parent owns the deadline and the child's process group. A thread
    // cannot clean up npm's children when this process exits at the deadline.
    match budget::run(&input, started + Duration::from_secs(budget.value)) {
        Ok(out) => emit(&out),
        Err(code) => {
            state::log_advisory(&guard_dir, format!("pre-guard DENY: judgment unfinished within the {}s self-budget (command {} bytes, child rc={}) — fail-closed, not a detection.", budget.value, size, code).as_bytes());
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
            0
        }
    }
}
