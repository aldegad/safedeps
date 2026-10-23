//! `safedeps-core pre`: the PreToolUse hook.
//!
//! The common entry owns payload reading, truth-source notices, the deadline
//! and scan settlement. Codex and Claude installs share the target, snapshot,
//! ledger and pending-state path, and for Claude the install driver asks the
//! inert rewrite (`inert.rs`) and sends its answer as `updatedInput`. The
//! registered hook is `scripts/safedeps-hook-entry.sh pre`, which runs this.
//!
//! Each step was carried over from the step of the Bash guard that its
//! comment names (scripts/safedeps-pre-guard.sh, deleted by the entry
//! switch), and prints what that step printed. The names stay so a step's
//! history can be followed in git. The differences are the ones a process
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
#[cfg(test)]
mod reader_tests;
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

/// `safedeps-core budget-config`: the budget numbers this hook judges with,
/// one JSON object, for a check against the timeout the installer registers.
pub fn budget_config() -> String {
    let n = |v: u64| jq::J::Num(v.to_string());
    jq::compact(&jq::obj(vec![
        ("runtime_budget_seconds", n(RUNTIME_BUDGET_SECONDS)),
        ("self_budget_max_seconds", n(SELF_BUDGET_MAX_SECONDS)),
        ("self_budget_default_seconds", n(SELF_BUDGET_DEFAULT_SECONDS)),
        ("engage_default_bytes", n(ENGAGE_DEFAULT_BYTES)),
        ("engage_max_bytes", n(ENGAGE_MAX_BYTES)),
        ("knob_max_digits", n(KNOB_MAX_DIGITS as u64)),
        ("knob_max_input_chars", n(KNOB_MAX_INPUT_CHARS as u64)),
    ]))
}

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
    out.say(&jq::deny("safedeps: UNDECIDED, not unsafe — safedeps could not finish reading this command, so it could not tell whether the command installs a dependency or what it would install. It is blocked fail-closed, and no finding is claimed."));
}

/// `guard_looks_like_install_unscanned`: whether the command's text reads as
/// an install when no reading of it finished. With no reader's answer in
/// hand, its words are taken without the lexer, in views of the text. A view
/// is the text after a sequence of the rewrites in `REWRITES`, each a step
/// the shell or a program it hands the text to takes before a manager runs:
/// line continuations joined, the escapes printf, `echo -e` and `$'...'`
/// expand, each redirection a blank (`pip>/dev/null install` installs), each
/// parenthesis group dropped (zsh runs `pip(N) install` as `pip install` when
/// a file of that name is there, and a group the walk could not place, as in
/// `pip ((x) y) install`, is a misreading, not an answer), and the quote
/// characters dropped. The views are every text the rewrites reach, in any
/// order and as often as one changes the text, so two of them that overlap
/// in one install (`$'\x70ip'>/dev/null install`) are read together. Each
/// view is read without its quote characters and backslashes: a quoted or
/// escaped name (`"npm"`, `\npm`) and the script of a `sh -c '...'` are then
/// the words the shell would run. A line of a view reads as an install where
/// a package manager's name follows no byte of a name and the grammar's
/// install body goes on from there: options, then one of that manager's
/// install verbs. So a wrapper, a heredoc or a payload around it changes
/// nothing, while a name inside another word (`pipefail`, `Google`) and a
/// manager that installs nothing (`python3 -c`, `npm run`) are not an
/// install. One more line of a view reads as one though no verb is in it: a
/// word whose value is decided at run time (`$X`, not an assignment's value)
/// and, after it in the same statement, a manager's name as a word of its
/// own, as in `env -S "$X" pip`. That word can be the script that names the
/// verb. A text with more views than `UNSCANNED_VIEWS`, or a sequence of
/// more than `UNSCANNED_DEPTH`, reads as an install: its views were not all
/// read.
fn looks_like_install_unscanned(command: &[u8]) -> bool {
    let p = grammar::patterns();
    let Ok(re) = Regex::new(&format!("(^|[^A-Za-z0-9_.-])({}){}", p.install_body, p.end), true) else { return true };
    let Ok(run_time) = Regex::new(
        &format!(
            "(^|[[:space:];&|(){{}}`])[$][^[:space:];&|]*([[:space:]]+[^[:space:];&|]+)*[[:space:]]+([^[:space:];&|()<>`]*/)?({})([[:space:];&|)<>`]|$)",
            grammar::EXECUTABLES
        ),
        true,
    ) else {
        return true;
    };
    // A text is told apart from another by two hashes under keys drawn for
    // this call, so the sets hold no text and no command can be written to
    // collide.
    use std::hash::BuildHasher;
    let keys = (std::collections::hash_map::RandomState::new(), std::collections::hash_map::RandomState::new());
    let key = |text: &[u8]| (keys.0.hash_one(text), keys.1.hash_one(text));
    let mut read = std::collections::HashSet::new();
    let mut reads = |view: &[u8]| {
        let words = unquoted(view);
        read.insert(key(&words)) && (re.grep_any(&words) || run_time.grep_any(&words))
    };
    let first = continuations_joined(command);
    if reads(&first) {
        return true;
    }
    // A depth-first walk: each entry of `path` is a view and the next
    // rewrite to take of it.
    let mut seen = std::collections::HashSet::from([key(&first)]);
    let mut path = vec![(first, 0)];
    while let Some((view, next)) = path.last_mut() {
        let Some(rewrite) = REWRITES.get(*next) else {
            path.pop();
            continue;
        };
        *next += 1;
        let text = rewrite(view);
        if text == *view || !seen.insert(key(&text)) {
            continue;
        }
        if seen.len() > UNSCANNED_VIEWS || path.len() == UNSCANNED_DEPTH || reads(&text) {
            return true;
        }
        path.push((text, 0));
    }
    false
}

/// The rewrites `looks_like_install_unscanned` makes its views with. None of
/// them lengthens the text, and each but `redirections_blank` shortens a text
/// it changes; that one leaves no `<` or `>`, which only an escape, and so a
/// shorter text, brings back. So every sequence of them that changes the
/// text ends.
const REWRITES: [fn(&[u8]) -> W; 6] =
    [continuations_joined, escapes_expanded, echo_escapes_expanded, redirections_blank, groups_dropped, quotes_dropped];

/// The most views `looks_like_install_unscanned` reads of one command, and
/// the most it holds at once, the views of one sequence of rewrites. The walk
/// takes the time of a pass over the command for each rewrite of each view,
/// and holds a copy of the command for each view of the sequence it is on.
const UNSCANNED_VIEWS: usize = 1024;
const UNSCANNED_DEPTH: usize = 64;

/// The text with each line continuation, a backslash and the newline after
/// it, dropped.
fn continuations_joined(text: &[u8]) -> W {
    let mut out = W::with_capacity(text.len());
    let mut i = 0;
    while i < text.len() {
        if text[i] == b'\\' && text.get(i + 1) == Some(&b'\n') {
            i += 2;
            continue;
        }
        out.push(text[i]);
        i += 1;
    }
    out
}

/// The text without each parenthesis group that closes on its line and holds
/// no other group. Taken again, it drops the groups around those, so a
/// `$(...)` around `pip(N)` is a view both with and without its script.
fn groups_dropped(text: &[u8]) -> W {
    let mut out = W::with_capacity(text.len());
    let mut i = 0;
    while i < text.len() {
        if text[i] == b'(' {
            let close = text[i + 1..].iter().position(|&b| matches!(b, b'(' | b')' | b'\n'));
            if let Some(n) = close.filter(|&n| text[i + 1 + n] == b')') {
                i += n + 2;
                continue;
            }
        }
        out.push(text[i]);
        i += 1;
    }
    out
}

/// The text without its quote characters, with the `$` that opens a `$'...'`
/// or `$"..."` taken as one of them. Its backslashes stay, so an escape the
/// quotes split (`'\''x70ip`) is whole again.
fn quotes_dropped(text: &[u8]) -> W {
    let mut out = W::with_capacity(text.len());
    for (i, &b) in text.iter().enumerate() {
        let opens = b == b'$' && matches!(text.get(i + 1), Some(b'\'' | b'"'));
        if !opens && !matches!(b, b'\'' | b'"') {
            out.push(b);
        }
    }
    out
}

/// The text without its quote characters and backslashes.
fn unquoted(text: &[u8]) -> W {
    quotes_dropped(text).into_iter().filter(|&b| b != b'\\').collect()
}

/// The text with each escape printf and `$'...'` expand replaced by the byte
/// it stands for: a letter escape, `\\`, one to three octal digits, and `\x`,
/// `\u` or `\U` with their hex digits. A byte past ASCII is no byte of a
/// name, so it stands as 0x80.
fn escapes_expanded(text: &[u8]) -> W {
    escapes(text, false)
}

/// The same, read as `echo -e` and printf's `%b` read it: `\0` takes up to
/// three octal digits after it.
fn echo_escapes_expanded(text: &[u8]) -> W {
    escapes(text, true)
}

fn escapes(text: &[u8], echo: bool) -> W {
    let mut out = W::with_capacity(text.len());
    let mut i = 0;
    while i < text.len() {
        // The bytes the escape at `i` takes, and the value it stands for.
        let number = |from: usize, max: usize, radix: u32| {
            let n = text[from..].iter().take(max).take_while(|&&b| (b as char).is_digit(radix)).count();
            let value = text[from..from + n].iter().fold(0u32, |v, &b| v * radix + (b as char).to_digit(radix).unwrap_or(0));
            (n > 0).then_some((from + n - i, value))
        };
        let escape = match text.get(i + 1) {
            _ if text[i] != b'\\' => None,
            Some(b'\\') => Some((2, u32::from(b'\\'))),
            Some(b'a') => Some((2, 0x07)),
            Some(b'b') => Some((2, 0x08)),
            Some(b'e' | b'E') => Some((2, 0x1b)),
            Some(b'f') => Some((2, 0x0c)),
            Some(b'n') => Some((2, 0x0a)),
            Some(b'r') => Some((2, 0x0d)),
            Some(b't') => Some((2, 0x09)),
            Some(b'v') => Some((2, 0x0b)),
            Some(b'0') if echo => number(i + 2, 3, 8).or(Some((2, 0))),
            Some(b'0'..=b'7') => number(i + 1, 3, 8),
            Some(b'x') => number(i + 2, 2, 16),
            Some(b'u') => number(i + 2, 4, 16),
            Some(b'U') => number(i + 2, 8, 16),
            _ => None,
        };
        match escape {
            Some((len, value)) => {
                out.push(if value < 0x80 { value as u8 } else { 0x80 });
                i += len;
            }
            None => {
                out.push(text[i]);
                i += 1;
            }
        }
    }
    out
}

/// The text with each redirection replaced by a blank: the digits or `&` in
/// front of its operator, the operator (a run of `<` and `>`, and one `&`,
/// `|` or `-` after it), the blanks after that, and the word it names (see
/// `word_end`). A `<(` or `>(` keeps its `(`.
fn redirections_blank(text: &[u8]) -> W {
    let mut out = W::with_capacity(text.len());
    let mut i = 0;
    while i < text.len() {
        if !matches!(text[i], b'<' | b'>') {
            out.push(text[i]);
            i += 1;
            continue;
        }
        while out.last().is_some_and(|b| b.is_ascii_digit()) {
            out.pop();
        }
        if out.last() == Some(&b'&') {
            out.pop();
        }
        while i < text.len() && matches!(text[i], b'<' | b'>') {
            i += 1;
        }
        if i < text.len() && matches!(text[i], b'&' | b'|' | b'-') {
            i += 1;
        }
        while i < text.len() && matches!(text[i], b' ' | b'\t') {
            i += 1;
        }
        i = word_end(text, i);
        out.push(b' ');
    }
    out
}

/// Where the word that starts at `i` ends: at the next blank or operator
/// outside a quote, an escape, a backquote, a `$(...)` or a `${...}`. A quote
/// or a `$(`/`${` that does not close is a byte of the word, and a backquote
/// that does not close ends it.
fn word_end(text: &[u8], mut i: usize) -> usize {
    // The index after the byte that closes what opens at `at`.
    let closing = |at: usize, close: u8, escapes: bool| {
        let mut j = at + 1;
        while j < text.len() && text[j] != close {
            j += if escapes && text[j] == b'\\' { 2 } else { 1 };
        }
        (j < text.len()).then_some(j + 1)
    };
    let balanced = |at: usize, open: u8, close: u8| {
        let mut depth = 0;
        text[at..].iter().position(|&b| {
            depth += i32::from(b == open) - i32::from(b == close);
            depth == 0
        })
        .map(|n| at + n + 1)
    };
    while i < text.len() && !is_space(text[i]) && !b";&|()<>".contains(&text[i]) {
        let span = match text[i] {
            b'\\' => Some(i + 2),
            b'\'' => closing(i, b'\'', false),
            b'"' => closing(i, b'"', true),
            b'`' => match closing(i, b'`', true) {
                Some(end) => Some(end),
                None => break,
            },
            b'$' if text.get(i + 1) == Some(&b'(') => balanced(i + 1, b'(', b')'),
            b'$' if text.get(i + 1) == Some(&b'{') => balanced(i + 1, b'{', b'}'),
            _ => None,
        };
        i = span.unwrap_or(i + 1);
    }
    i.min(text.len())
}

/// `guard_settle_scan_failure`. True when the command is denied. `found` says
/// a reading found an install: that answer stands, and the text is asked
/// only where no reading found one.
fn settle_scan_failure(call: &Call, failed: bool, found: bool, out: &mut Out) -> bool {
    if !failed {
        return false;
    }
    if found {
        deny_undecided_scan(call, out, "a reading found an install");
        return true;
    }
    if looks_like_install_unscanned(&call.command) {
        deny_undecided_scan(call, out, "the command reads as an install");
        return true;
    }
    state::log_advisory(
        &call.guard_dir,
        &cat(&[b"pre-guard: the command scanner failed; the command does not read as an install and was allowed. Command: ", &call.command]),
    );
    out.warn(b"safedeps: this command could not be fully read. It does not read as a dependency install, so it was allowed. The failure is recorded in advisory.log.");
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
    // The entries of a node_modules directory a rollback compares (the same
    // listing the install snapshot keeps), for the backstop to remove only
    // what the command added. Written only when every read succeeded and
    // every name is text JSON holds as it is: a name it would alter, or one a
    // failed read left out, would read as one the command added.
    let mut listed = None;
    if std::fs::symlink_metadata(d.join("node_modules")).is_ok_and(|m| m.is_dir()) {
        let (entries, failed) = crate::post::tree_entries(&d.join("node_modules"));
        if failed.is_none() && entries.iter().all(|e| std::str::from_utf8(e).is_ok()) {
            listed = Some(jq::J::Arr(entries.iter().map(|e| jq::arg(e)).collect()));
        }
    }
    let mut fields = vec![
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
    ];
    if let Some(listed) = listed {
        fields.push(("entries", listed));
    }
    let entry = jq::obj(fields);
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
/// install. The install driver invokes the rewrite only for Claude.
fn judge(call: &Call) -> Out {
    let mut out = Out::default();
    let core = Core::new();
    let mut run = Run::new(&core);
    let mut cwd = match jq::capture_field(&call.input, &["cwd"]) {
        Ok(cwd) => cwd,
        Err(code) => return Out { code, ..Out::default() },
    };
    if cwd.is_empty() {
        cwd = shell_pwd();
    }
    let read = readings::Readings::collect(&mut run, &call.command, &cwd);
    if read.yes("any_install") {
        return install::judge(call, &mut run, &cwd, &read, crate::inert::reading_inert);
    }
    if settle_scan_failure(call, run.failed, false, &mut out) {
        return out;
    }
    backstop_trace_baseline(call, &cwd);
    out
}

fn emit(out: &Out) -> i32 {
    let _ = std::io::stderr().lock().write_all(&out.stderr);
    let mut so = std::io::stdout().lock();
    let _ = so.write_all(&out.stdout);
    let _ = so.flush();
    out.code
}

/// A stale checkout can settle only the unscanned-install question.
/// It never calls the old judgment or creates a snapshot, pending record or
/// trace baseline. An unreadable payload is not evidence of an absent install.
fn stale(input: &[u8], why: &str, guard: &Path) -> i32 {
    let _ = std::fs::DirBuilder::new().recursive(true).mode(0o700).create(guard);
    let payload = json::parse_one(input).ok();
    let tool = payload.as_ref().and_then(|p| p.get("tool_name")).and_then(Value::as_str);
    let command = payload.as_ref().and_then(|p| p.get("tool_input")).and_then(|p| p.get("command"));
    let disposition = match (tool, command) {
        (Some("Bash"), Some(Value::Str(command))) => {
            if looks_like_install_unscanned(command) { "the command reads as an install" }
            else {
                let message = format!("{} The command does not read as an install and was allowed without a judgment.", why);
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

fn unfinished_text(failure: &budget::Failure, seconds: u64, size: u64) -> (String, String) {
    use crate::outcome::{Outcome, Action, Form};
    let status_text = |status: &std::process::ExitStatus| jq::text(&Outcome::status(*status).describe(Action::Judgment,Form::Judgment));
    if let budget::Failure::Deadline { child } = failure {
        let child = match child {
            Some(Ok(status)) => format!(", child {}", status_text(status)),
            Some(Err(error)) => format!(", waiting for child failed: {}", error),
            None => String::new(),
        };
        return (
            format!("pre-guard DENY: judgment unfinished within the {}s self-budget (command {} bytes{}) — fail-closed, not a detection.", seconds, size, child),
            format!("safedeps: UNDECIDED, not unsafe — safedeps could not finish judging this command within its {}s budget ({} bytes of command text), so it is blocked fail-closed. Nothing was detected in it; the gate simply did not get to an answer, and an install it cannot judge must not run. Scan cost grows with command length. Split the command, or write long content with a file-writing tool instead of one very large shell command, and retry.", seconds, size),
        );
    }
    let fact = match failure {
        budget::Failure::Exited(status) => format!("the judgment process ended without a usable answer ({})", status_text(status)),
        budget::Failure::Supervision { step, error } => format!("safedeps could not {}: {}", step, error),
        budget::Failure::Deadline { .. } => unreachable!(),
    };
    (
        format!("pre-guard DENY: {} (command {} bytes) — fail-closed, not a detection.", fact, size),
        format!("safedeps: UNDECIDED, not unsafe — {}. No dependency judgment was made; nothing was detected in this command. It is blocked fail-closed.", fact),
    )
}

#[cfg(test)]
mod budget_reply_tests {
    use super::*;
    use std::{os::unix::process::ExitStatusExt, process::ExitStatus};

    #[test]
    fn only_a_deadline_claims_the_budget_elapsed() {
        let (log, reason) = unfinished_text(&budget::Failure::Deadline { child: None }, 2, 40);
        assert!(reason.contains("within its 2s budget"));
        assert!(log.contains("within the 2s self-budget"));
        assert!(!reason.contains("process ended"));
        for (raw, fact) in [(7 << 8, "exit code 7"), (9, "signal 9")] {
            let (log, reason) = unfinished_text(&budget::Failure::Exited(ExitStatus::from_raw(raw)), 2, 40);
            for text in [&log, &reason] {
                assert!(text.contains(fact), "{}", text);
                assert!(text.contains("without a usable answer"));
                assert!(!text.contains("budget"), "{}", text);
                assert!(!text.contains("within"), "{}", text);
            }
            assert!(reason.contains("UNDECIDED, not unsafe"));
            assert!(reason.contains("nothing was detected"));
        }
        let failure = budget::Failure::Supervision { step: "start judgment process",
            error: std::io::Error::from_raw_os_error(2) };
        let (log, reason) = unfinished_text(&failure, 2, 40);
        for text in [&log, &reason] {
            assert!(text.contains("could not start judgment process"));
            assert!(!text.contains("budget"));
            assert!(!text.contains("process ended"));
        }
    }
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
        return emit(&judge(&call));
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
        Err(failure) => {
            let (log, reason) = unfinished_text(&failure, budget.value, size);
            state::log_advisory(&guard_dir, log.as_bytes());
            let mut clamp = W::new();
            if matches!(failure, budget::Failure::Deadline { .. }) && !budget.clamped_from.is_empty() {
                clamp = format!(" Your SAFEDEPS_SELF_BUDGET_SECONDS={} was clamped to the {}s ceiling: above it the {}s runtime hook budget kills this gate mid-judgment and the install runs unjudged, so raising it removes the check rather than extending it.", b(&budget.clamped_from), SELF_BUDGET_MAX_SECONDS, RUNTIME_BUDGET_SECONDS).into_bytes();
            } else if matches!(failure, budget::Failure::Deadline { .. }) && !budget.invalid_from.is_empty() {
                clamp = cat(&[b" Your SAFEDEPS_SELF_BUDGET_SECONDS='", &budget.invalid_from, format!("' is not a whole number of seconds, so the {}s default is in force.", budget.value).as_bytes()]);
            }
            let reason = cat(&[reason.as_bytes(), &clamp]);
            let answer = jq::compact(&jq::obj(vec![(
                "hookSpecificOutput",
                jq::obj(vec![("hookEventName", jq::s("PreToolUse")), ("permissionDecision", jq::s("deny")), ("permissionDecisionReason", jq::arg(&reason))]),
            )]));
            println!("{}", answer);
            0
        }
    }
}
