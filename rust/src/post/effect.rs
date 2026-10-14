//! One closure over npm's two records, one ledger index, and one OSV batch.
use super::{closure, jv, providers::Providers, report::cat, sh, snapshot::Store, trace};
use crate::{json::Value, ledger, os, state};
use std::io::Write;

/// What an install kept under `SAFEDEPS_ACCEPT_RISK` accepted: the problems
/// as the gate states them, and each package with the reason it was named.
/// Only a package the ledger does not approve and a package OSV reports
/// vulnerable can be here. A KEV listing, a closure that cannot be read and
/// a check that cannot run are never accepted: they stay reasons.
#[derive(Default)]
pub struct Accepted { pub problems: Vec<Vec<u8>>, pub packages: Vec<Value> }

pub fn check(store: &Store, reasons: &mut Vec<Vec<u8>>, mut accepted: Option<&mut Accepted>) {
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
    let now = os::wall(os::WallRole::PostLedgerExpiry).seconds();
    let mut index = ledger::effect_index(&ledger::directory(), "", now, &mut warnings);
    // `safedeps check` scopes an approval to the project whose npm overrides
    // or Yarn resolutions it was resolved with, and the pre-guard asks the
    // ledger with that context. This gate read only the approvals with no
    // context, so a project with overrides was rolled back for packages its
    // own approvals named. It now counts both: the approvals with no context,
    // and those of the context this project has, never another project's.
    if let Ok(index) = index.as_mut() {
        match ledger::context::project_context(&store.project) {
            Ok(Some(context)) => {
                let hash = context.get("context_hash").and_then(Value::as_str).unwrap_or("");
                if !hash.is_empty() {
                    match ledger::effect_index(&ledger::directory(), hash, now, &mut warnings) {
                        Ok(scoped) => index.merge(scoped),
                        Err(_) => state::log_advisory(&store.home, &cat(&[b"post-verify: the approvals scoped to ", sh::bytes(&store.project), b" could not be read, so only the approvals with no project context were counted."])),
                    }
                }
            }
            Ok(None) => {}
            Err(why) => {
                let why: Vec<u8> = why.iter().map(|b| if matches!(b, b'\n' | b'\r') { b' ' } else { *b }).collect();
                state::log_advisory(&store.home, &cat(&[b"post-verify: the project resolution context of ", sh::bytes(&store.project), b" could not be read (", why.trim_ascii(), b"), so only the approvals with no project context were counted."]))
            }
        }
    }
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
        let problem = cat(&[b"npm closure contains ", misses.len().to_string().as_bytes(), b" unapproved package(s): ", &summary]);
        match accepted.as_deref_mut() {
            Some(accepted) => {
                accepted.problems.push(problem);
                accepted.packages.extend(misses.iter().map(|m| jv::obj(vec![("package", jv::s(m)), ("problem", jv::s(b"unapproved"))])));
            }
            None => reasons.push(problem),
        }
    }
    let Ok(results) = Providers::new(&store.home).batch(&all) else {
        reasons.push(b"npm closure OSV batch verification failed; fail-closed".to_vec()); return
    };
    for (status, label) in [("hard_block", "KEV-blocked"), ("vulnerable", "vulnerable")] {
        let found: Vec<_> = results.iter().filter(|(_,_,s,_)| *s == status).collect();
        if found.is_empty() { continue }
        let packages: Vec<_> = found.iter().map(|(p,v,_,_)| cat(&[p,b"@",v])).collect();
        let problem = cat(&[b"npm closure contains ", label.as_bytes(), b" package(s): ", &packages.join(b", ".as_slice())]);
        match accepted.as_deref_mut().filter(|_| status == "vulnerable") {
            Some(accepted) => {
                // The ids are said where the risk is accepted, so the record
                // names what was accepted and not only a package.
                let named: Vec<_> = found.iter().map(|(p,v,_,ids)| if ids.is_empty() { cat(&[p, b"@", v]) }
                    else { cat(&[p, b"@", v, b" (", &ids.join(b", ".as_slice()), b")"]) }).collect();
                accepted.problems.push(cat(&[b"npm closure contains vulnerable package(s): ", &named.join(b", ".as_slice())]));
                accepted.packages.extend(found.iter().map(|(p,v,_,ids)| jv::obj(vec![("package", jv::s(&cat(&[p, b"@", v]))),
                    ("problem", jv::s(b"vulnerable")), ("advisories", Value::Arr(ids.iter().map(|id| jv::s(id)).collect()))])));
            }
            None => reasons.push(problem),
        }
    }
}
