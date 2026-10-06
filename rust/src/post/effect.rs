//! One closure over npm's two records, one ledger index, and one OSV batch.
use super::{closure, providers::Providers, report::cat, sh, snapshot::Store, trace};
use crate::{json::Value, ledger, os, state};
use std::io::Write;

pub fn check(store: &Store, reasons: &mut Vec<Vec<u8>>) {
    let lockfiles: Vec<_> = trace::RECORDS.iter().filter(|rel| sh::is_file(&store.project.join(rel))).collect();
    if lockfiles.is_empty() { return }
    if sh::is_dir(&store.project.join("node_modules")) && !sh::is_file(&store.project.join(trace::RECORDS[1])) {
        state::log_advisory(&store.home, &cat(&[b"post-verify: ", sh::bytes(&store.project), b"/node_modules has no .package-lock.json, so the installed tree was read from package-lock.json only."]));
    }
    let mut all = Vec::new();
    for rel in lockfiles {
        match closure::lock_closure(&store.project.join(rel)) {
            Ok(parts) => all.extend(parts.into_iter().flatten()),
            Err(_) => { reasons.push(cat(&[b"npm closure could not be parsed from ", rel.as_bytes()])); return }
        }
    }
    let all = closure::unique_sorted(all);
    let value = Value::Arr(all.iter().map(closure::Spec::to_value).collect());
    let mut warnings = Vec::new();
    let index = ledger::effect_index(&ledger::directory(), "", os::wall(os::WallRole::PostLedgerExpiry).seconds(), &mut warnings);
    let _ = std::io::stderr().write_all(&warnings);
    let misses = index.map_err(|_| ()).and_then(|index| index.misses("npm", &value));
    let Ok(misses) = misses else {
        reasons.push(b"npm ledger closure check could not run; fail-closed".to_vec()); return
    };
    let misses: Vec<_> = misses.into_iter().filter(|(p,v)| !p.is_empty() && !v.is_empty())
        .map(|(p,v)| cat(&[p.as_bytes(), b"@", v.as_bytes()])).collect();
    if !misses.is_empty() {
        // paste -sd ', ' cycles its two delimiters; it does not use ", ".
        let mut summary = Vec::new();
        for (i, m) in misses.iter().take(20).enumerate() {
            if i > 0 { summary.push(if i % 2 == 1 { b',' } else { b' ' }); }
            summary.extend(m);
        }
        reasons.push(cat(&[b"npm closure contains ", misses.len().to_string().as_bytes(), b" unapproved package(s): ", &summary]));
    }
    let Ok(results) = Providers::new(&store.home).batch(&all) else {
        reasons.push(b"npm closure OSV batch verification failed; fail-closed".to_vec()); return
    };
    for (status, label) in [("hard_block", "KEV-blocked"), ("vulnerable", "vulnerable")] {
        let packages: Vec<_> = results.iter().filter(|(_,_,s)| *s == status)
            .map(|(p,v,_)| cat(&[p,b"@",v])).collect();
        if !packages.is_empty() {
            reasons.push(cat(&[b"npm closure contains ", label.as_bytes(), b" package(s): ", &packages.join(b", ".as_slice())]));
        }
    }
}
