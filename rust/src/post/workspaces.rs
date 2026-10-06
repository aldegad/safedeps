//! Workspace membership for post's directory judgment. This is a file list,
//! never a prediction of where npm installs or what npm rebuild visits.
use super::{jv, sh, report::cat};
use crate::{json::Value, state};
use std::{fs, path::{Path, PathBuf}};

fn patterns(root: &Path) -> Vec<u8> {
    let file = root.join("package.json");
    if !sh::exists(&file) { return b"none".to_vec() }
    if !sh::readable(&file) { return cat(&[b"?\t", sh::bytes(&file), b" cannot be read"]) }
    let invalid = || cat(&[b"?\t", sh::bytes(&file), b" is not valid JSON"]);
    let Some(st) = jv::read_file(&file) else { return invalid() };
    let (lines, rc) = jv::each(&st, |v| {
        let w = jv::field(v, "workspaces")?;
        if !jv::truthy(w) || matches!(w, Value::Str(s) if s.is_empty()) || jv::eq(w, &jv::num(0)) {
            return Ok(vec![b"none".to_vec()]);
        }
        let w = if matches!(w, Value::Obj(_)) && matches!(jv::field(w, "packages")?, Value::Arr(_)) { jv::field(w, "packages")? } else { w };
        let Value::Arr(items) = w else { return Ok(vec![b"bad".to_vec()]) };
        if items.iter().any(|x| !matches!(x, Value::Str(s) if !String::from_utf8_lossy(s).chars().any(char::is_control))) {
            return Ok(vec![b"bad".to_vec()]);
        }
        let mut out = vec![b"ok".to_vec()];
        out.extend(items.iter().map(jv::tostring));
        Ok(out)
    });
    if rc != 0 { return invalid() }
    let out = jv::captured(&lines);
    if out == b"bad" { cat(&[b"?\t", sh::bytes(&file), b" declares workspaces npm would reject"]) } else { out }
}

fn children(base: &Path, dots: bool) -> Vec<PathBuf> {
    let Ok(entries) = fs::read_dir(base) else { return Vec::new() };
    let mut paths: Vec<_> = entries.filter_map(Result::ok).map(|e| e.path()).filter(|p| {
        let name = sh::basename(sh::bytes(p));
        (dots || !name.starts_with(b".")) && name != b"node_modules" && sh::is_dir(p)
    }).collect();
    paths.sort_by(|a,b| sh::bytes(a).cmp(sh::bytes(b)));
    paths
}

fn expand(base: &Path, segments: &[&[u8]], out: &mut Vec<Vec<u8>>) {
    let Some((&seg, rest)) = segments.split_first() else {
        if sh::is_file(&base.join("package.json")) { out.push(sh::bytes(base).to_vec()); }
        return;
    };
    match seg {
        b"" | b"." => expand(base, rest, out),
        b"**" => {
            expand(base, rest, out);
            for p in children(base, false) { if !sh::is_link(&p) { expand(&p, segments, out); } }
        }
        b"node_modules" => {}
        _ if seg.iter().any(|b| b"*?[".contains(b)) => {
            for p in children(base, true) {
                let name = sh::basename(sh::bytes(&p));
                if name.starts_with(b".") && !seg.starts_with(b".") { continue }
                if sh::fnmatch(seg, &name) { expand(&p, rest, out); }
            }
        }
        _ => {
            let p = sh::p(&cat(&[sh::bytes(base), b"/", seg]));
            if sh::is_dir(&p) { expand(&p, rest, out); }
        }
    }
}

pub fn members(root: &Path) -> Vec<u8> {
    let patterns = patterns(root);
    if patterns == b"none" || patterns.starts_with(b"?") { return patterns }
    let mut out = Vec::new();
    for mut pat in patterns.split(|b| *b == b'\n').skip(1) {
        let bangs = pat.iter().take_while(|b| **b == b'!').count();
        pat = &pat[bangs..];
        if bangs % 2 == 1 {
            out.push(cat(&[b"?\t", sh::bytes(root), b"/package.json excludes workspaces with a negated pattern"])); continue;
        }
        if pat.iter().any(|b| b"{}()!\\".contains(b)) {
            out.push(cat(&[b"?\t", sh::bytes(root), b"/package.json names workspaces with a glob this gate does not read (", pat, b")"])); continue;
        }
        while pat.starts_with(b"/") || pat.starts_with(b"./") {
            if pat.starts_with(b".") { pat = &pat[1..]; }
            if pat.starts_with(b"/") { pat = &pat[1..]; }
        }
        let mut segs: Vec<_> = pat.split(|b| *b == b'/').collect();
        if pat.is_empty() { segs.clear(); } else if segs.last() == Some(&b"".as_slice()) { segs.pop(); }
        expand(root, &segs, &mut out);
    }
    // The shell pipeline sorts lines, so a path containing a newline produces
    // two records just as it does there.
    let mut lines: Vec<Vec<u8>> = out.iter().flat_map(|s| s.split(|b| *b == b'\n').map(Vec::from)).collect();
    lines.sort(); lines.dedup();
    lines.insert(0, b"ok".to_vec());
    jv::captured(&lines)
}

pub fn physical_members(root: &Path, home: &Path) -> Vec<Vec<u8>> {
    let listing = members(root);
    let lines: Vec<_> = listing.split(|b| *b == b'\n').collect();
    if lines.first() != Some(&b"ok".as_slice()) { return Vec::new() }
    if let Some(why) = lines.iter().find(|l| l.starts_with(b"?")) {
        state::log_advisory(home, &cat(&[b"post-verify: the workspace patterns in ", sh::bytes(root), b"/package.json cannot be read in full (",
            sh::cut_field(why, 2), b"), so no directory this install linked there counts as a workspace member."]));
        return Vec::new();
    }
    let mut out = Vec::new();
    let mut cwd = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    for member in lines.into_iter().skip(1).filter(|s| !s.is_empty()) {
        let relative = member.strip_prefix(sh::bytes(root)).unwrap_or(member);
        if relative.split(|b| *b == b'/').any(|s| s == b"..") { continue }
        if let Some(p) = sh::cd_physical(&cwd, &sh::p(member)) { out.push(sh::bytes(&p).to_vec()); cwd = p; }
    }
    out
}
