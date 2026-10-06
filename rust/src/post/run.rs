//! The effect hook's call ordering. File selection and facts belong to the
//! domain modules; this is where their ordering becomes a single judgment.
use super::{call::{Call, Record}, effect, heuristics, journal::Journal, jv,
    npm::Npm, report::{self, Report, cat}, rollback::Rollback, sh, snapshot,
    trace::{self, Install}};
use crate::{os, state};
use std::{fs, io::Write};
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
    effect::check(&call.store, &mut reasons);
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

fn judge(call: &mut Call, journal: &Journal, input: &[u8]) -> Result<Option<W>, i32> {
    if call.record != Record::Install { return backstop(call, journal, input) }
    call.store.stage();
    let mut trace = Install::settle(&call.store.project, &call.store.home, &call.current, &call.command);
    let mut npm = Npm::default();
    let mut reasons = Vec::new();
    let mut report = Report::default();
    let mut confirm = Vec::new();
    npm.collect(&call.store, &mut reasons);
    effect::check(&call.store, &mut reasons);
    heuristics::scripts(&call.store, &npm.nodes, &mut reasons)?;
    heuristics::lockfile(&call.store, &mut reasons);
    npm.record(&call.store, &call.current, &trace, &mut report);
    npm.sources(&call.store, &call.current, input, call.codex, &mut reasons, &mut confirm);
    heuristics::binaries(&call.store, &mut reasons);
    if !reasons.is_empty() {
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

pub fn main(input: &[u8]) -> i32 {
    os::set_umask(0o077);
    let home = state::guard_dir();
    if state::ensure_dirs(&home).is_err() { return 1 }
    let journal = Journal::new(&home);
    let unfinished = journal.unfinished();
    let result = Call::take(&home, input).and_then(|call| match call {
        Some(mut call) => judge(&mut call, &journal, input), None => Ok(None),
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
