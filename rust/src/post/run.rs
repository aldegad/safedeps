//! The effect hook's call ordering. File selection and facts belong to the
//! domain modules; this is where their ordering becomes a single judgment.
use super::{call::{Call, Record}, effect, heuristics, journal::Journal, jv,
    npm::{self, Npm}, report::{self, Report, cat}, rollback::Rollback, sh, snapshot,
    trace::{self, Install}};
use crate::{os, state};
use std::{fs, io::Write, time::Instant};
type W = Vec<u8>;

fn rollback(call: &mut Call, journal: &Journal, trace: &mut Install, report: &mut Report,
    target: W, reasons: &[u8], input: &[u8], backstop: bool) -> Result<W, i32> {
    let pre = if backstop { Vec::new() } else { call.store.id.clone() };
    let journal_id = cat(&[if backstop { b"backstop-" } else { b"reorg-" },
        if backstop { &target } else { &pre }, b"-", std::process::id().to_string().as_bytes()]);
    journal.open(&journal_id, &call.store.project, &target, reasons, b"restoring-files").map_err(|_| 1)?;
    if backstop { call.store.id = target.clone(); }
    let mut rb = Rollback::new(&call.store, report, trace, pre, target.clone(), backstop);
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

fn backstop(call: &mut Call, journal: &Journal, input: &[u8]) -> Result<Option<W>, i32> {
    if !trace::RECORDS.iter().any(|rel| sh::is_file(&call.store.project.join(rel))) {
        state::log_advisory(&call.store.home, &cat(&[b"post-verify UNVERIFIED: ", call.record.subject(), b" and no package-lock.json or node_modules/.package-lock.json in ", sh::bytes(&call.store.project), " — nothing to closure-check.".as_bytes()]));
        trace::drop_baseline(&call.store.home, &call.entry);
        return Ok(None)
    }
    if !call.backstop_trace() { return Ok(None) }
    let mut reasons = Vec::new();
    effect::check(&call.store, &mut reasons, None);
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
    trace.absent && trace.read && fact("runner_only", true) && fact("npm_install", false)
        && !npm::meta_true(&call.store.meta(), "ignore_scripts_injected")
}

/// The reason `SAFEDEPS_ACCEPT_RISK` gave for this call, from this call's
/// own pending record (`accept_risk`), where the pre-guard found that it
/// counts. A record that does not hold it as a string that is not blank
/// holds none: the override is never inferred from a missing field.
fn accept_risk(call: &Call) -> Option<W> {
    match jv::field(&call.current, "accept_risk") {
        Ok(crate::json::Value::Str(reason)) if reason.iter().any(|b| *b != b' ') => Some(reason.clone()),
        _ => None,
    }
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
        ("tool_use_id", jv::field(&call.current, "tool_use_id").ok().filter(|v| matches!(v, crate::json::Value::Str(_))).cloned().unwrap_or(crate::json::Value::Null)),
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
    if call.record != Record::Install { return backstop(call, journal, input) }
    let mut trace = Install::settle(&call.store.project, &call.store.home, &call.current, &call.command);
    if runner_left_npm_untouched(call, &trace) { call.store.remove(); return Ok(None) }
    call.store.stage();
    let mut npm = Npm::default();
    let mut reasons = Vec::new();
    let mut report = Report::default();
    let mut confirm = Vec::new();
    let accept = accept_risk(call);
    let mut accepted = effect::Accepted::default();
    npm.collect(&call.store, &mut reasons);
    effect::check(&call.store, &mut reasons, accept.as_ref().map(|_| &mut accepted));
    heuristics::scripts(&call.store, &npm.nodes, &mut reasons)?;
    heuristics::lockfile(&call.store, &mut reasons);
    npm.record(&call.store, &call.current, &trace, &mut report);
    npm.sources(&call.store, &call.current, input, call.codex, &mut reasons, &mut confirm);
    if reasons.is_empty() { heuristics::binaries(&call.store, &mut reasons, post_started); }
    let mut unrecorded = false;
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
        call.store.discard();
        let mut target = snapshot::confirmed(&call.store.home, &call.store.hash).map_err(|_| 0)?;
        if target.is_empty() || !sh::is_file(&call.store.path(&target, b"meta.json")) { target = call.store.id.clone(); }
        return rollback(call, journal, &mut trace, &mut report, target, &reasons.join(b"; ".as_slice()), input, false).map(Some)
    }
    report.lines.extend(confirm);
    npm.rebuild(&call.store, &call.current, &mut trace, input, &mut report);
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
    let journal = Journal::new(&home);
    let unfinished = journal.unfinished();
    let result = Call::take(&home, input).and_then(|call| match call {
        Some(mut call) => judge(&mut call, &journal, input, post_started), None => Ok(None),
    });
    let (rc, message) = match result { Ok(m) => (0,m), Err(rc) => (rc,None) };
    let message = match (unfinished.is_empty(), message) {
        (true, message) => message,
        (false, Some(message)) => Some(cat(&[&unfinished, b"\n\n", &message])),
        (false, None) => Some(unfinished),
    };
    if let Some(message) = message {
        let out = cat(&[&jv::dump(&jv::obj(vec![("systemMessage", jv::s(&message))])), b"\n"]);
        if std::io::stdout().write_all(&out).is_err() { return 1 }
    }
    rc
}
