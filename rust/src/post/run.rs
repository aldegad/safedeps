//! The effect hook's call ordering. File selection and facts belong to the
//! domain modules; this is where their ordering becomes a single judgment.
use super::{accepted::{self, Sources}, call::{Call, Record}, effect, heuristics, journal::Journal, jv, mark,
    npm::{self, Npm}, report::{self, Report, cat}, rollback::{Before, Rollback}, sh, snapshot,
    trace::{self, Install}};
use crate::{callid::record as rec, os, state};
use std::{fs, io::Write, time::Instant};
type W = Vec<u8>;

fn rollback(call: &mut Call, journal: &Journal, trace: &mut Install, report: &mut Report,
    target: W, reasons: &[u8], input: &[u8], backstop: bool) -> Result<W, i32> {
    let pre = if backstop { Vec::new() } else { call.store.id.clone() };
    let journal_id = cat(&[if backstop { b"backstop-" } else { b"reorg-" },
        if backstop { &target } else { &pre }, b"-", std::process::id().to_string().as_bytes()]);
    journal.open(&journal_id, &call.store.project, &target, reasons, b"restoring-files").map_err(|_| 1)?;
    // Read before any file is restored: what node_modules was before the
    // command, from the record taken then.
    let before = if backstop { Before::of_entry(&call.store.project, &call.entry, call.moved) }
        else { Before::of_snapshot(&call.store, &pre) };
    if backstop { call.store.id = target.clone(); }
    let mut rb = Rollback::new(&call.store, report, trace, pre, target.clone(), backstop, before);
    for name in call.store.monitored().iter().filter(|n| !n.is_empty()) { rb.restore(name); }
    if !backstop {
        for name in snapshot::csproj(&call.store.project) { rb.restore(&name); }
        let prefix = cat(&[&target, b"_"]);
        let mut found: Vec<_> = fs::read_dir(call.store.home.join("snapshots")).into_iter().flatten()
            .filter_map(Result::ok).filter(|e| e.file_type().is_ok_and(|t| t.is_file()))
            .map(|e| sh::basename(sh::bytes(&e.path()))).collect();
        found.sort();
        for suffix in [b".csproj".as_slice(), b".csproj.missing"] {
            for name in &found {
                if let Some(name) = name.strip_prefix(prefix.as_slice()).filter(|n| n.ends_with(suffix)) {
                    rb.restore(if suffix.ends_with(b".missing") { &name[..name.len()-8] } else { name });
                }
            }
        }
    }
    rb.package_json();
    journal.stage(&journal_id, b"removing-node-modules").map_err(|_| 1)?;
    rb.node_modules();
    if !backstop { call.store.cleanup().map_err(|_| 0)?; }
    rb.tail(input);
    let (log_head, head) = if backstop {
        (b"REORG executed (command-independent backstop)".as_slice(),
         cat(&[b"safedeps: suspicious dependency change detected; ", call.record.clause(), b". A rollback ran."]))
    } else {
        (b"REORG executed".as_slice(), b"safedeps: suspicious dependency change detected. A rollback ran.".to_vec())
    };
    let message = rb.message(log_head, &head, reasons).map_err(|_| 0)?;
    journal.close(&journal_id);
    Ok(message)
}

fn backstop(call: &mut Call, journal: &Journal, input: &[u8], until: Instant) -> Result<Option<W>, i32> {
    if !trace::RECORDS.iter().any(|rel| sh::is_file(&call.store.project.join(rel))) {
        state::log_advisory(&call.store.home, &cat(&[b"post-verify UNVERIFIED: ", call.record.subject(), b" and no package-lock.json or node_modules/.package-lock.json in ", sh::bytes(&call.store.project), " — nothing to closure-check.".as_bytes()]));
        trace::drop_baseline(&call.store.home, &call.entry);
        return Ok(None)
    }
    if !call.backstop_trace() { return Ok(None) }
    let mut reasons = Vec::new();
    let mut sources = Sources::read(&call.store.home, &call.store.project, None, until);
    effect::check(&call.store, &mut reasons, None, &mut sources, until);
    sources.reasons(&mut reasons);
    if reasons.is_empty() {
        state::log_advisory(&call.store.home, &cat(&[b"post-verify BACKSTOP clean: ", call.record.subject(), b"; the npm closure in ", sh::bytes(&call.store.project), b" passed the command-independent npm closure check."]));
        return Ok(None)
    }
    let reasons = reasons.join(b"; ".as_slice());
    let target = snapshot::confirmed(&call.store.home, &call.store.hash).map_err(|_| 0)?;
    if target.is_empty() || !sh::is_file(&call.store.path(&target, b"meta.json")) {
        state::log_advisory(&call.store.home, &cat(&[b"post-verify BACKSTOP FLAGGED (no baseline): ", call.record.subject(), b"; the npm closure in ", sh::bytes(&call.store.project), " failed the command-independent npm closure check — ".as_bytes(), &reasons, b". No confirmed snapshot to roll back to; left in place."]));
        let baseline = if target.is_empty() { cat(&[b"no confirmed snapshot is recorded for ", sh::bytes(&call.store.project)]) }
            else { cat(&[b"the confirmed snapshot ", &target, b" of ", sh::bytes(&call.store.project), b": ", &report::path(&call.store.path(&target, b"meta.json"))]) };
        return Ok(Some(cat(&[b"safedeps: suspicious dependency change detected; ", call.record.clause(), b". No rollback ran.\n\nDetected problems:\n", &reasons, b"\n\n", &baseline])))
    }
    rollback(call, journal, &mut Install::default(), &mut Report::default(), target, &reasons, input, true).map(Some)
}

/// A recorded call that only runs node packages and left no trace in either
/// npm record is not judged: no closure check, no rollback, no confirm. The
/// record says the first (`runner_only` true and `npm_install` false, never a
/// missing field) and the trace check the second, with the baseline read and
/// nothing newer or replaced. `npx <name>` is read as an install, and its
/// packages go to npm's own cache, not to the project. Judging the project's
/// closure for it rolled projects back and recorded their whole tree as
/// withheld. A statement beside the runners that the pre hook cannot vouch
/// installs nothing keeps the call judged: an install of any manager, read
/// by the recognizers or not (`yarn add` writes neither npm record), or any
/// other program. So does a command safedeps rewrote with --ignore-scripts.
fn runner_left_npm_untouched(call: &Call, trace: &Install) -> bool {
    let fact = |key: &str, want: bool| matches!(jv::path(&call.current, &[key]), Ok(crate::json::Value::Bool(v)) if *v == want);
    trace.absent && trace.read && fact(rec::RUNNER_ONLY, true) && fact(rec::NPM_INSTALL, false)
        && !npm::meta_true(&call.store.meta(), "ignore_scripts_injected")
}

/// The reason `SAFEDEPS_ACCEPT_RISK` gave for this call, from this call's
/// own pending record (`accept_risk`), where the pre-guard found that it
/// counts. A record that does not hold it as a string that is not blank
/// holds none: the override is never inferred from a missing field.
fn accept_risk(call: &Call) -> Option<W> {
    match jv::field(&call.current, rec::ACCEPT_RISK) {
        Ok(crate::json::Value::Str(reason)) if reason.iter().any(|b| *b != b' ') => Some(reason.clone()),
        _ => None,
    }
}

/// The URL and the reason `SAFEDEPS_ACCEPT_SOURCE` gave for this call, from
/// this call's own pending record (`accept_source`), where the pre-guard
/// found that it counts. As with the accepted risk, a record that does not
/// hold both as strings, the URL one an entry can name and the reason not
/// blank, holds none.
fn accept_source(call: &Call) -> Option<(W, W)> {
    let v = jv::field(&call.current, rec::ACCEPT_SOURCE).ok()?;
    let url = jv::text(jv::field(v, rec::SOURCE_URL).ok()?)?;
    let reason = jv::text(jv::field(v, rec::SOURCE_REASON).ok()?)?;
    (crate::sources::url_acceptable(url).is_ok() && reason.iter().any(|b| *b != b' ')).then(|| (url.to_vec(), reason.to_vec()))
}

const SOURCE_NOT_COVERED: &[u8] = b"SAFEDEPS_ACCEPT_SOURCE was set for this install, and it accepts a source only for an install no other check rolls back, so no entry was written";

/// The entries this call's `SAFEDEPS_ACCEPT_SOURCE` makes, written before
/// the install is kept and before anything is rebuilt over them: an install
/// whose entries cannot be written is not kept. The one line that says so is
/// said here, in the install that makes the entries, and in no later one.
fn accept_sources(call: &Call, sources: &mut Sources, report: &mut Report, until: Instant) -> Result<(), W> {
    let Some((url, reason)) = sources.bypass.clone() else { return Ok(()) };
    let home = call.store.home.clone();
    let project = sh::bytes(&call.store.project).to_vec();
    let entries = sources.to_write(&project);
    if entries.is_empty() {
        state::log_advisory(&home, &cat(&[b"post-verify: SAFEDEPS_ACCEPT_SOURCE named ", &url, b" for an install in ", &project, b", and neither npm record there holds it, so no entry was written."]));
        return Ok(())
    }
    let ledger = crate::sources::path(&home);
    let id = jv::field(&call.current, rec::TOOL_USE_ID).ok().and_then(jv::text);
    let accepts: Vec<_> = entries.iter().map(|entry| crate::sources::Accept { entry, tool_use_id: id }).collect();
    if let Err(fault) = crate::sources::accept(&home, &accepts, accepted::wait(until)) {
        return Err(cat(&[b"SAFEDEPS_ACCEPT_SOURCE was set for this install, and the accepted-source ledger ", sh::bytes(&ledger), b" could not take its entries (", &fault.text(), b"), so the install was not kept"]))
    }
    let packages: Vec<W> = entries.iter().map(|e| {
        let ids = if e.advisories.is_empty() { b"no advisory".to_vec() } else { cat(&[b"advisories accepted: ", &e.advisories.join(b", ".as_slice())]) };
        cat(&[&e.package, b"@", &e.version, b" (", &ids, b")"])
    }).collect();
    let packages = packages.join(b"; ".as_slice());
    report.say(cat(&[b"Accepted source: ", &url, b" for ", &packages, b", recorded in ", sh::bytes(&ledger)]));
    state::log_advisory(&home, &cat(&[b"post-verify ACCEPTED SOURCE in ", &project, b": ", &url, b" for ", &packages, b", under SAFEDEPS_ACCEPT_SOURCE (", &reason, b"); entries written to ", sh::bytes(&ledger), b". Command: ", &call.command]));
    sources.written = entries;
    Ok(())
}

pub const ACCEPTED_FACT: &[u8] = b"SAFEDEPS_ACCEPT_RISK kept this install, which no check verified";
const ACCEPTED_HEAD: &[u8] = b"safedeps: WARNING: SAFEDEPS_ACCEPT_RISK kept this install. Its checks found problems that would have rolled it back, and no rollback ran.";
const NOT_COVERED: &[u8] = b"SAFEDEPS_ACCEPT_RISK was set for this install, and it keeps an install only where every problem is an unapproved or vulnerable package";

/// An install kept under `SAFEDEPS_ACCEPT_RISK`: every problem the checks
/// found is one the override covers (`effect::Accepted`). The audit record is
/// written first, and an install whose record cannot be written is not kept.
/// The verified baseline does not move, because nothing verified this state,
/// and no rebuild runs, because the closure did not verify.
fn keep(call: &mut Call, trace: &mut Install, report: &mut Report, confirm: Vec<W>, reason: &[u8],
    accepted: &effect::Accepted, input: &[u8]) -> Result<W, W> {
    let home = call.store.home.clone();
    let problems = accepted.problems.join(b"; ".as_slice());
    let audit = state::accepted_risk_path(&home);
    let entry = jv::obj(vec![
        ("at", jv::s(os::utc_stamp(os::wall(os::WallRole::AcceptedRiskEntry).seconds()).as_bytes())),
        ("tool_use_id", jv::field(&call.current, rec::TOOL_USE_ID).ok().filter(|v| matches!(v, crate::json::Value::Str(_))).cloned().unwrap_or(crate::json::Value::Null)),
        ("project", jv::s(sh::bytes(&call.store.project))), ("command", jv::s(&call.command)), ("reason", jv::s(reason)),
        ("snapshot", jv::s(&call.store.id)), ("problems", crate::json::Value::Arr(accepted.problems.iter().map(|p| jv::s(p)).collect())),
        ("packages", crate::json::Value::Arr(accepted.packages.clone())),
    ]);
    if let Err(error) = state::append_accepted_risk(&home, &jv::dump(&entry)) {
        return Err(cat(&[b"SAFEDEPS_ACCEPT_RISK was set for this install, and its audit record ", sh::bytes(&audit), b" could not be written (", error.to_string().as_bytes(), b"), so the install was not kept"]));
    }
    call.store.discard();
    report.lines.extend(confirm);
    let meta = call.store.meta();
    let fact = if trace.absent { trace.said = true; trace.line.clone() } else { ACCEPTED_FACT.to_vec() };
    if npm::meta_true(&meta, "ignore_scripts_injected") {
        report.rebuild(&home, &meta, input, &cat(&[b"did not run npm rebuild: ", &fact]));
    } else {
        report.inert(&home, &meta, input);
        if trace.absent { report.say(&trace.line); }
    }
    report.say(report::file(b"Audit record", &audit));
    let mut lines = Vec::new();
    for line in &report.lines { lines.extend(cat(&[b"  ", line, b"\n"])); }
    let log = home.join("reorg.log");
    sh::append(&log, &cat(&[b"[", os::utc_stamp(os::wall(os::WallRole::AcceptedRiskHeader).seconds()).as_bytes(), b"] ACCEPTED RISK\n  Snapshot: ", &call.store.id,
        b"\n  Project: ", sh::bytes(&call.store.project), b"\n  Accepted risk: ", reason, b"\n  Accepted problems: ", &problems, b"\n", &lines]));
    state::log_advisory(&home, &cat(&[b"post-verify ACCEPTED RISK in ", sh::bytes(&call.store.project), b": kept under SAFEDEPS_ACCEPT_RISK (", reason, b"), not rolled back. Problems: ", &problems, b". Command: ", &call.command]));
    let _ = call.store.cleanup();
    Ok(cat(&[ACCEPTED_HEAD, b"\nAccepted risk: ", reason, b"\n\nAccepted problems:\n", &problems, b"\n\n", &report.lines.join(&b'\n'), b"\n\n", &report::file(b"Details log", &log)]))
}

fn judge(call: &mut Call, journal: &Journal, input: &[u8], post_started: Instant) -> Result<Option<W>, i32> {
    // One deadline for the run, fixed at its start: the provider requests, the
    // native inspection and npm's registry answer end by it (post::LIMIT says
    // what it does not bound), so no wait on another process runs past it.
    let until = post_started + super::LIMIT;
    if call.record != Record::Install { return backstop(call, journal, input, until) }
    let mut trace = Install::settle(&call.store.project, &call.store.home, &call.current, &call.command);
    if runner_left_npm_untouched(call, &trace) { call.store.remove(); return Ok(None) }
    call.store.stage();
    let mut npm = Npm::default();
    let mut reasons = Vec::new();
    let mut report = Report::default();
    let mut confirm = Vec::new();
    let accept = accept_risk(call);
    let mut accepted = effect::Accepted::default();
    let mut sources = Sources::read(&call.store.home, &call.store.project, accept_source(call), until);
    npm.collect(&call.store, &mut reasons);
    effect::check(&call.store, &mut reasons, accept.as_ref().map(|_| &mut accepted), &mut sources, until);
    sources.reasons(&mut reasons);
    heuristics::scripts(&call.store, &npm.nodes, &mut reasons)?;
    heuristics::lockfile(&call.store, &mut reasons);
    npm.record(&call.store, &call.current, &trace, &mut report, until, &sources);
    npm.sources(&call.store, &call.current, input, call.codex, &mut reasons, &mut confirm, until, &sources);
    if reasons.is_empty() { heuristics::binaries(&call.store, &mut reasons, post_started); }
    let mut unrecorded = false;
    let mut unwritten = false;
    if reasons.is_empty() {
        if let Err(why) = accept_sources(call, &mut sources, &mut report, until) {
            state::log_advisory(&call.store.home, &cat(&[b"post-verify: ", &why, b"."])); reasons.push(why); unwritten = true;
        }
    }
    if reasons.is_empty() && !accepted.problems.is_empty() {
        let reason = accept.clone().unwrap_or_default();
        match keep(call, &mut trace, &mut report, std::mem::take(&mut confirm), &reason, &accepted, input) {
            Ok(message) => return Ok(Some(message)),
            Err(why) => { state::log_advisory(&call.store.home, &cat(&[b"post-verify: ", &why, b"."])); reasons.push(why); unrecorded = true; }
        }
    }
    if !reasons.is_empty() {
        // The problems an override would cover are reasons again where it
        // does not keep the install, beside the ones it never covers.
        if accept.is_some() {
            reasons.extend(std::mem::take(&mut accepted.problems));
            if !unrecorded { reasons.push(NOT_COVERED.to_vec()); }
        }
        if sources.bypass.is_some() && sources.written.is_empty() && !unwritten {
            match sources.bypass_unmatched() {
                Some(url) => reasons.push(cat(&[b"SAFEDEPS_ACCEPT_SOURCE was set for this install and names ", url, b", which neither npm record holds, so it accepted nothing"])),
                None => reasons.push(SOURCE_NOT_COVERED.to_vec()),
            }
        }
        call.store.discard();
        let mut target = snapshot::confirmed(&call.store.home, &call.store.hash).map_err(|_| 0)?;
        if target.is_empty() || !sh::is_file(&call.store.path(&target, b"meta.json")) { target = call.store.id.clone(); }
        return rollback(call, journal, &mut trace, &mut report, target, &reasons.join(b"; ".as_slice()), input, false).map(Some)
    }
    report.lines.extend(confirm);
    npm.rebuild(&call.store, &call.current, &mut trace, input, &mut report, until, &sources);
    call.store.confirm(&mut report).map_err(|_| 0)?;
    call.store.cleanup().map_err(|_| 0)?;
    if report.lines.is_empty() { return Ok(None) }
    let mut lines = Vec::new();
    for line in &report.lines { lines.extend(cat(&[b"  ", line, b"\n"])); }
    sh::append(&call.store.home.join("reorg.log"), &cat(&[b"[", os::utc_stamp(os::wall(os::WallRole::ConfirmWarningsHeader).seconds()).as_bytes(), b"] CONFIRM warnings\n  Snapshot: ", &call.store.id, b"\n  Project: ", sh::bytes(&call.store.project), b"\n", &lines]));
    Ok(Some(cat(&[b"safedeps: this install was not rolled back.\n", &report.lines.join(&b'\n')])))
}

pub fn main(input: &[u8], post_started: Instant) -> i32 {
    os::set_umask(0o077);
    let home = state::guard_dir();
    if state::ensure_dirs(&home).is_err() { return 1 }
    // A mark an earlier run left, whose run is gone, is the record of a
    // judgment that run did not finish. Each is said in advisory.log once,
    // before this run takes a call and writes a mark of its own. It comes
    // before the journal, so the journal owner's process query stays the
    // last one a run that takes no call makes; e2e's owner-fault rows read
    // the receipt of the last query (scripts/measure/core-post-test-fixtures.py).
    mark::report_gone(&home);
    let journal = Journal::new(&home);
    let unfinished = journal.unfinished();
    // Every way out of judge comes back here, so this is where the mark goes.
    // A run that never comes back (the runtime's kill, a panic, which aborts)
    // leaves it.
    let mut unwritten = None;
    let result = Call::take(&home, input).and_then(|call| match call {
        Some(mut call) => {
            // A run that wrote neither its mark nor the advisory.log line for
            // it starts no judgment, because nothing it leaves would say that
            // a kill cut one. Its answer says so instead (decision 6).
            if let Some(unjudged) = call.mark.unjudged() { return Ok(Some(unjudged)) }
            let judged = judge(&mut call, &journal, input, post_started);
            call.mark.close(&home, &call.command);
            unwritten = call.mark.unwritten();
            judged
        }
        None => Ok(None),
    });
    let (rc, message) = match result { Ok(m) => (0,m), Err(rc) => (rc,None) };
    // The answer says, in this order: the rollbacks an earlier run left
    // unfinished, the judgment's own message or the report that none started
    // (mark::Mark::unjudged), and the mark this run could not write
    // (mark::Mark::unwritten).
    let parts: Vec<W> = [Some(unfinished).filter(|u| !u.is_empty()), message, unwritten].into_iter().flatten().collect();
    if !parts.is_empty() {
        let out = cat(&[crate::jq::system_message(&parts.join(b"\n\n".as_slice())).as_bytes(), b"\n"]);
        if std::io::stdout().write_all(&out).is_err() { return 1 }
    }
    rc
}

#[cfg(test)]
mod tests {
    use super::{cat, jv, sh};
    use std::{fs, io::Write, os::unix::{ffi::OsStringExt, fs::{OpenOptionsExt, PermissionsExt}, process::ExitStatusExt}, path::Path,
        process::{Child, Command, ExitStatus}, time::{Duration, Instant}};

    /// Set in a child of this test binary, it names the directory the parent
    /// made, and the child is the post hook: it runs `main` on one call there
    /// and exits with what `main` returned.
    const HOOK: &str = "SAFEDEPS_MARK_TEST_HOOK";
    /// Set beside HOOK, the command of that call. Without it the command is
    /// `npm install mark-fixture`.
    const COMMAND: &str = "SAFEDEPS_MARK_TEST_COMMAND";

    pub(super) fn hook_child() {
        let Some(root) = std::env::var_os(HOOK) else { return };
        let project = Path::new(&root).join("project");
        let command = std::env::var_os(COMMAND).map(|c| c.into_vec()).unwrap_or_else(|| b"npm install mark-fixture".to_vec());
        let input = jv::dump(&jv::obj(vec![
            ("tool_name", jv::s(b"Bash")),
            ("tool_input", jv::obj(vec![("command", jv::s(&command))])),
            ("tool_use_id", jv::s(b"toolu_mark")),
            ("cwd", jv::s(sh::bytes(&project))),
        ]));
        let rc = super::main(&input, Instant::now());
        let _ = std::io::stdout().flush();
        std::process::exit(rc)
    }

    /// The post hook in a child of this test binary that runs the test at
    /// `path` (its module path under the crate), with `home` as its
    /// SAFEDEPS_HOME and `command` as its call's command, or `npm install
    /// mark-fixture` without one. Its working directory is the row's own
    /// scratch directory, outside the worktree. Its argv[0] names this run,
    /// so the start of a later run ends it if this run is killed while it
    /// waits (`crate::children::owned`).
    pub(super) fn child(path: &str, root: &Path, home: &Path, command: Option<&str>) -> Child {
        let mut child = crate::children::owned(path, root);
        child.env("SAFEDEPS_HOME", home).env(HOOK, root);
        if let Some(command) = command { child.env(COMMAND, command); }
        child.spawn().unwrap()
    }

    /// The post hook on `npm install mark-fixture`, in a child of this test
    /// binary that runs `test` of this module.
    fn spawn(test: &str, root: &Path, home: &Path) -> Child {
        child(&format!("post::run::tests::{test}"), root, home, None)
    }

    /// The hook's answers, among the test harness's own lines. Their key is
    /// spelled in jq.rs alone, so it is read off an empty answer.
    pub(super) fn answers(stdout: &[u8]) -> Vec<Vec<u8>> {
        let empty = crate::jq::system_message(b"");
        let key = empty.strip_suffix("\"\"}").expect("an answer ends with its message").as_bytes();
        (0..stdout.len()).filter(|&i| stdout[i..].starts_with(key)).map(|i| {
            let line = &stdout[i..];
            let line = &line[..line.iter().position(|b| *b == b'\n').unwrap_or(line.len())];
            let read = jv::read(line);
            let [crate::json::Value::Obj(fields)] = read.values.as_slice() else { panic!("one object: {:?}", String::from_utf8_lossy(line)) };
            let [(_, message)] = fields.as_slice() else { panic!("one field: {:?}", String::from_utf8_lossy(line)) };
            let message = jv::text(message).expect("a string").to_vec();
            assert_eq!(crate::jq::system_message(&message).as_bytes(), line, "the answer is one message object");
            message
        }).collect()
    }

    /// `line` is `head`, one run of digits (a start the kernel stored), and
    /// `tail`.
    pub(super) fn digits_between(line: &[u8], head: &[u8], tail: &[u8]) -> bool {
        line.len() > head.len() + tail.len() && line.starts_with(head) && line.ends_with(tail)
            && line[head.len()..line.len() - tail.len()].iter().all(u8::is_ascii_digit)
    }

    /// What a post run left when its mark could not be written.
    struct Run { status: ExitStatus, pid: u32, stdout: Vec<u8>, said: Vec<Vec<u8>>, log: Option<Vec<u8>>, marks: usize, judging: Vec<u8> }

    /// Runs the post hook in a child of this test binary, in a project with no
    /// record and no lockfile: the command-independent backstop takes the
    /// call, opens its mark, and finds nothing to judge. `judging/` is mode
    /// 0500, so the mark cannot be written, and advisory.log takes the line.
    fn unwritable_mark(test: &str) -> Run {
        let root = crate::os::scratch_dir("safedeps-mark-run").unwrap();
        let home = root.join("home");
        let judging = home.join("judging");
        fs::create_dir_all(&judging).unwrap();
        fs::create_dir(root.join("project")).unwrap();
        fs::set_permissions(&judging, fs::Permissions::from_mode(0o500)).unwrap();
        let child = spawn(test, &root, &home);
        let pid = child.id();
        let out = child.wait_with_output().unwrap();
        let marks = fs::read_dir(&judging).unwrap().count();
        let log = fs::read(home.join("advisory.log")).ok();
        let judging_text = sh::bytes(&judging).to_vec();
        fs::set_permissions(&judging, fs::Permissions::from_mode(0o700)).unwrap();
        fs::remove_dir_all(&root).unwrap();
        Run { status: out.status, pid, said: answers(&out.stdout), stdout: out.stdout, log, marks, judging: judging_text }
    }

    /// The hook's answer is one message, and it is the line for a mark the
    /// write could not make: this backstop call has nothing else to say.
    fn says_the_mark_was_not_written(run: &Run) -> bool {
        let head = cat(&[b"safedeps: this run wrote no judgment mark: the write of ", &run.judging, b"/", run.pid.to_string().as_bytes(), b"-"]);
        let tail = b".json returned OS error 13. Without that mark, a judgment the runtime kills before it returns leaves no record.";
        let [said] = run.said.as_slice() else { return false };
        digits_between(said, &head, tail)
    }

    /// The control: advisory.log takes the line, and the hook's answer says it
    /// too.
    #[test]
    fn a_mark_that_cannot_be_written_is_said_in_the_log_and_in_the_hook_answer() {
        hook_child();
        let run = unwritable_mark("a_mark_that_cannot_be_written_is_said_in_the_log_and_in_the_hook_answer");
        assert!(run.status.success(), "{:?}", run.status);
        assert_eq!(run.marks, 0, "no mark and no temporary file");
        let log = run.log.as_deref().expect("advisory.log is a file");
        let logged = cat(&[b"\tpost-verify: this run wrote no judgment mark: the write of ", &run.judging, b"/", run.pid.to_string().as_bytes(), b"-"]);
        assert!(log.windows(logged.len()).any(|w| w == logged.as_slice()), "the write failed, and advisory.log says so\n{}", String::from_utf8_lossy(log));
        assert!(says_the_mark_was_not_written(&run), "the hook's answer says it too\n{:?}", String::from_utf8_lossy(&run.stdout));
    }

    #[cfg(target_os = "macos")]
    pub(super) const O_NONBLOCK: i32 = 0x0004;
    #[cfg(not(target_os = "macos"))]
    pub(super) const O_NONBLOCK: i32 = 0o4000;
    /// What an open of a FIFO for writing, without blocking, returns while no
    /// process has it open for reading.
    const ENXIO: i32 = 6;
    /// How long a row waits for its run to open `confirmed`, or to end. A run
    /// that answers at once ends in milliseconds; the bound only ends a row
    /// whose run would wait on the FIFO for ever.
    pub(super) const BOUND: Duration = Duration::from_secs(20);

    /// The writer of `fifo`, once a process has it open for reading.
    pub(super) fn reader_came(fifo: &Path) -> std::io::Result<Option<fs::File>> {
        match fs::OpenOptions::new().write(true).custom_flags(O_NONBLOCK).open(fifo) {
            Ok(writer) => Ok(Some(writer)),
            Err(error) if error.raw_os_error() == Some(ENXIO) => Ok(None),
            Err(error) => Err(error),
        }
    }

    /// The post run of a row, killed and reaped on every way out of the row,
    /// a panic included. A SIGKILL of the row runs no way out of it, and the
    /// start of the next run ends what it left (`crate::children`).
    pub(super) struct Reaped(pub(super) Option<Child>);
    impl Drop for Reaped {
        fn drop(&mut self) {
            if let Some(child) = self.0.as_mut() { let _ = child.kill(); let _ = child.wait(); }
        }
    }
    impl Reaped {
        pub(super) fn ended(&mut self) -> bool { self.0.as_mut().unwrap().try_wait().unwrap().is_some() }
    }

    /// What the row does once its run has opened `confirmed`.
    #[derive(Clone, Copy, PartialEq)]
    enum Then {
        /// SIGKILL, in the middle of the judgment.
        Kill,
        /// Close the writer: the record reads empty, and the judgment goes on.
        LetGo,
    }

    /// A post run the backstop judges, and what the row saw while it ran.
    struct Judged {
        run: Run,
        /// The run opened `confirmed` for reading.
        reached: bool,
        /// The names in `judging/`, and the kernel's start of the run, when
        /// the run had `confirmed` open.
        marks_then: Vec<String>,
        start_then: Option<u64>,
        home: Vec<u8>,
        project: Vec<u8>,
    }

    /// Runs the post hook in a child of this test binary on `npm install
    /// mark-fixture`, in a project whose package-lock.json cannot be read. The
    /// command-independent backstop takes the call, opens its mark, finds the
    /// closure unreadable, and next reads the confirmed record. That record,
    /// `confirmed` in the home, is a FIFO, so the row sees whether the run
    /// opens it, and the run waits there until the row does what `then` says.
    /// Without `mark`, `judging/` is mode 0500. With `log_takes_nothing`,
    /// advisory.log is a directory.
    fn judged(test: &str, mark: bool, log_takes_nothing: bool, then: Then) -> Judged {
        let root = crate::os::scratch_dir("safedeps-mark-run").unwrap();
        let (home, project) = (root.join("home"), root.join("project"));
        let judging = home.join("judging");
        fs::create_dir_all(&judging).unwrap();
        fs::create_dir(&project).unwrap();
        fs::write(project.join("package-lock.json"), b"{broken").unwrap();
        let fifo = home.join("confirmed");
        assert!(Command::new("mkfifo").arg(&fifo).status().unwrap().success());
        if log_takes_nothing { fs::create_dir(home.join("advisory.log")).unwrap(); }
        if !mark { fs::set_permissions(&judging, fs::Permissions::from_mode(0o500)).unwrap(); }
        let mut child = Reaped(Some(spawn(test, &root, &home)));
        let pid = child.0.as_ref().unwrap().id();
        let until = Instant::now() + BOUND;
        let mut writer = None;
        let mut failed = None;
        while !child.ended() && Instant::now() < until {
            match reader_came(&fifo) {
                Ok(Some(opened)) => { writer = Some(opened); break }
                Ok(None) => std::thread::sleep(Duration::from_millis(20)),
                Err(error) => { failed = Some(error); break }
            }
        }
        let reached = writer.is_some();
        let (marks_then, start_then) = if reached {
            let mut names: Vec<String> = fs::read_dir(&judging).unwrap().map(|e| e.unwrap().file_name().to_string_lossy().into_owned()).collect();
            names.sort();
            (names, crate::post::process::start(pid))
        } else { (Vec::new(), None) };
        if reached && then == Then::LetGo {
            drop(writer.take());
            let until = Instant::now() + BOUND;
            while !child.ended() && Instant::now() < until { std::thread::sleep(Duration::from_millis(20)); }
        }
        let mut process = child.0.take().unwrap();
        if process.try_wait().unwrap().is_none() { process.kill().unwrap(); }
        let out = process.wait_with_output().unwrap();
        drop(writer);
        let marks = fs::read_dir(&judging).unwrap().count();
        let log = fs::read(home.join("advisory.log")).ok();
        let run = Run { status: out.status, pid, said: answers(&out.stdout), stdout: out.stdout, log, marks, judging: sh::bytes(&judging).to_vec() };
        let (home_text, project_text) = (sh::bytes(&home).to_vec(), crate::os::realpath(sh::bytes(&project)));
        fs::set_permissions(&judging, fs::Permissions::from_mode(0o700)).unwrap();
        fs::remove_dir_all(&root).unwrap();
        if let Some(error) = failed { panic!("{}: {error}", fifo.display()) }
        Judged { run, reached, marks_then, start_then, home: home_text, project: project_text }
    }

    /// The hook's answer is one message: the report that this install was not
    /// judged, with what each of the two writes returned, the command and the
    /// project.
    fn says_not_judged(judged: &Judged) -> bool {
        let run = &judged.run;
        let head = cat(&[b"safedeps: this install was not judged.\n\nThis run wrote no judgment mark: the write of ", &run.judging, b"/",
            run.pid.to_string().as_bytes(), b"-"]);
        let tail = cat(&[b".json returned OS error 13.\nIt wrote no line to advisory.log either: the write of ", &judged.home,
            b"/advisory.log returned OS error 21.\nWith neither, a judgment the runtime killed would leave no record, so this run did not start one.\n",
            b"No closure check ran, and nothing was rolled back.\nCommand: npm install mark-fixture\nProject: ", &judged.project]);
        let [said] = run.said.as_slice() else { return false };
        digits_between(said, &head, &tail)
    }

    /// Decision 6: a run that wrote neither its mark nor the advisory.log line
    /// for it starts no judgment. It answers at once that this install was not
    /// judged, and it never opens the confirmed record, which no writer here
    /// would ever fill.
    #[test]
    fn a_run_that_can_leave_no_record_answers_before_it_judges() {
        hook_child();
        let judged = judged("a_run_that_can_leave_no_record_answers_before_it_judges", false, true, Then::Kill);
        assert!(!judged.reached, "the run opened the confirmed record\n{:?}", String::from_utf8_lossy(&judged.run.stdout));
        assert!(judged.run.status.success(), "the run ended by itself within {BOUND:?}: {:?}", judged.run.status);
        assert_eq!(judged.run.marks, 0, "no mark and no temporary file");
        assert!(judged.run.log.is_none(), "advisory.log is a directory");
        assert!(says_not_judged(&judged), "the hook's answer is the report that this install was not judged\n{:?}", String::from_utf8_lossy(&judged.run.stdout));
    }

    /// A run that wrote no mark but wrote the advisory.log line judges as
    /// before, and a kill in the middle of its judgment leaves that line.
    #[test]
    fn a_run_whose_log_took_the_line_judges_and_a_kill_leaves_the_line() {
        hook_child();
        let judged = judged("a_run_whose_log_took_the_line_judges_and_a_kill_leaves_the_line", false, false, Then::Kill);
        assert!(judged.reached, "the run judged as far as the confirmed record\n{:?}", String::from_utf8_lossy(&judged.run.stdout));
        assert_eq!(judged.run.status.signal(), Some(9), "the row killed the run: {:?}", judged.run.status);
        assert_eq!(judged.run.marks, 0, "no mark and no temporary file");
        assert!(judged.run.said.is_empty(), "a killed run gives no answer");
        let log = judged.run.log.as_deref().expect("advisory.log is a file");
        let head = cat(&[b"post-verify: this run wrote no judgment mark: the write of ", &judged.run.judging, b"/", judged.run.pid.to_string().as_bytes(), b"-"]);
        let said = log.split(|b| *b == b'\n').filter_map(|line| line.iter().position(|b| *b == b'\t').map(|tab| &line[tab + 1..]))
            .filter(|text| text.starts_with(&head)).collect::<Vec<_>>();
        let [line] = said.as_slice() else { panic!("one line outlived the kill\n{}", String::from_utf8_lossy(log)) };
        assert!(digits_between(line, &head, b".json returned OS error 13. Command: npm install mark-fixture"), "{}", String::from_utf8_lossy(line));
    }

    /// A run that wrote its mark judges as before: the mark is on disk while
    /// the judgment reads the confirmed record, the judgment returns its own
    /// message, and the mark goes.
    #[test]
    fn a_run_that_wrote_its_mark_judges_as_before() {
        hook_child();
        let judged = judged("a_run_that_wrote_its_mark_judges_as_before", true, false, Then::LetGo);
        assert!(judged.reached, "the run judged as far as the confirmed record\n{:?}", String::from_utf8_lossy(&judged.run.stdout));
        let start = judged.start_then.expect("the kernel's start of the run");
        assert_eq!(judged.marks_then, vec![format!("{}-{}.json", judged.run.pid, start)], "the run's own mark, while it judged");
        assert!(judged.run.status.success(), "the run ended by itself: {:?}", judged.run.status);
        assert_eq!(judged.run.marks, 0, "the mark went when the judgment returned");
        let log = judged.run.log.as_deref().expect("advisory.log is a file");
        assert!(!log.windows(b"judgment mark".len()).any(|w| w == b"judgment mark"), "{}", String::from_utf8_lossy(log));
        let [said] = judged.run.said.as_slice() else { panic!("one answer\n{:?}", String::from_utf8_lossy(&judged.run.stdout)) };
        let head = b"safedeps: suspicious dependency change detected; this hook found no record of this command from before it ran. No rollback ran.\n\nDetected problems:\n";
        let tail = cat(&[b"\n\nno confirmed snapshot is recorded for ", &judged.project]);
        assert!(said.starts_with(head) && said.ends_with(&tail), "the backstop's own message, and nothing after it\n{}", String::from_utf8_lossy(said));
    }
}

#[cfg(test)]
mod unfinished_tests;
#[cfg(test)]
mod children;
