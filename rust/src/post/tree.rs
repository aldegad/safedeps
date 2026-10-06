//! The whole-tree predicate behind npm_rebuild_unrecorded. npm supplies the
//! visited nodes; both lockfiles supply records. Neither substitutes for the
//! other. The shared fetch reader supplies the origin and problem operations.
use super::{jv, sh, workspaces, closure, report::cat};
use crate::json::Value;
use std::{collections::BTreeMap, path::Path};
type W = Vec<u8>;
type Records = BTreeMap<W, Vec<Value>>;
type Nodes = BTreeMap<W, Value>;
type Bundles = BTreeMap<W, Vec<W>>;
pub type Fetch<'a> = &'a dyn Fn(&Value) -> Result<Vec<Value>, ()>;

fn alt(v: &Value, default: &Value) -> Value { if jv::truthy(v) { v.clone() } else { default.clone() } }
fn f<'a>(v: &'a Value, key: &str) -> Result<&'a Value, ()> { jv::field(v, key) }
fn text_default(v: &Value, default: &[u8]) -> W { jv::tostring(&alt(v, &jv::s(default))) }
fn name(key: &[u8], entry: &Value) -> Result<Value, ()> {
    let n = f(entry, "name")?;
    Ok(if jv::truthy(n) { n.clone() } else if jv::in_tree(key) { jv::s(jv::after_last_node_modules(key).unwrap_or(b"")) } else { Value::Null })
}
fn join_unique(values: Vec<Value>, sep: &[u8]) -> W {
    let words: Vec<W> = jv::unique(values).iter().map(jv::tostring).collect();
    words.join(sep)
}
pub fn origin_text(v: &Value) -> Result<W, ()> {
    if !matches!(f(v, "unknown")?, Value::Null) { Ok(cat(&[b"?", &jv::tostring(f(v, "unknown")?)])) }
    else if !matches!(f(v, "scope")?, Value::Null) { Ok(cat(&[&jv::tostring(f(v, "registry")?), b" (npm's ", &jv::tostring(f(v, "scope")?), b":registry)"])) }
    else { Ok(text_default(f(v, "registry")?, b"a registry npm will not print")) }
}
fn public(rec: &Value) -> Result<bool, ()> { Ok(matches!(f(rec,"resolved")?, Value::Str(s) if closure::public_registry_url(s))) }

struct Judge<'a> {
    records: &'a Records, nodes: &'a Nodes, bundles: Option<&'a Bundles>, withheld: &'a Value,
    problems: Fetch<'a>, memo: BTreeMap<W, Option<W>>,
}
impl Judge<'_> {
    fn problems(&self, rec: &Value) -> Result<Vec<Value>, ()> {
        if public(rec)? { (self.problems)(f(rec, "resolved")?) } else { Ok(Vec::new()) }
    }
    fn source(&self, rec: &Value) -> Result<bool, ()> { Ok(public(rec)? && self.problems(rec)?.is_empty()) }
    fn verdict(&mut self, key: &[u8]) -> Result<Option<W>, ()> {
        if let Some(v) = self.memo.get(key) { return Ok(v.clone()) }
        let v = self.compute(key)?; self.memo.insert(key.to_vec(), v.clone()); Ok(v)
    }
    fn compute(&mut self, key: &[u8]) -> Result<Option<W>, ()> {
        let Some(node) = self.nodes.get(key) else { return Ok(Some(cat(&[b"unrecorded\t", key, b" (npm did not name it)"]))) };
        let recs = self.records.get(key).map(Vec::as_slice).unwrap_or(&[]);
        let here = cat(&[&text_default(f(node,"name")?,b"?"), b"@", &text_default(f(node,"version")?,b"?")]);
        let unrecorded = |why: &[u8]| Some(cat(&[b"unrecorded\t", key, b" (", &here, why, b")"]));
        if recs.is_empty() { return Ok(unrecorded(b", not in either lockfile")) }
        let mut linked = false;
        for r in recs { linked |= matches!(f(r,"link")?, Value::Bool(true)); }
        if linked { return Ok(unrecorded(b" on disk, the lockfile records a link")) }
        let mut matched = false;
        for r in recs {
            let n = name(key, r)?;
            matched |= jv::clean(&alt(f(r,"version")?,&jv::s(b""))) == jv::clean(&alt(f(node,"version")?,&jv::s(b"")))
                && (matches!(n, Value::Null) || jv::eq(&n, f(node,"name")?));
        }
        if !matched {
            let mut names = Vec::new();
            for r in recs { names.push(jv::s(&cat(&[&text_default(&name(key,r)?,b"?"),b"@",&text_default(f(r,"version")?,b"?")]))); }
            return Ok(unrecorded(&cat(&[b" on disk, the lockfile records ",&join_unique(names,b" or ")])));
        }
        if !jv::in_tree(key) { return Ok(Some(cat(&[b"candidate\t",key,b"\t",key,b" (",&here,b")"]))) }
        let mut all_source = true;
        for r in recs { all_source &= self.source(r)?; }
        if all_source {
            let mut held = false;
            let mut missing = false;
            for r in recs {
                let tokens = jv::tokens(r); missing |= tokens.is_empty();
                for t in tokens { held |= !matches!(jv::field_bytes(self.withheld,&t)?,Value::Null); }
            }
            let kind: &[u8] = if held { b"withheld" } else if missing { b"nointegrity" } else { return Ok(None) };
            return Ok(Some(cat(&[kind,b"\t",key,b" (",&here,b")"])));
        }
        if let Some((parent, package)) = jv::nested(key) {
            let Some(bundles) = self.bundles else { return Ok(Some(cat(&[b"nested\t",key]))) };
            let mut possible = true;
            for r in recs { possible &= matches!(f(r,"resolved")?,Value::Null) || self.source(r)?; }
            if possible && bundles.get(parent).is_some_and(|ns| ns.iter().any(|n| n == package)) && self.verdict(parent)?.is_none() {
                return Ok(None);
            }
        }
        let mut all_public = true;
        for r in recs { all_public &= public(r)?; }
        if all_public {
            let mut urls=Vec::new(); let mut probs=Vec::new();
            for r in recs { urls.push(f(r,"resolved")?.clone()); probs.extend(self.problems(r)?); }
            Ok(Some(cat(&[b"fetched\t",key,b" (",&here,b" recorded at ",&join_unique(urls,b" or "),b", but ",&join_unique(probs,b"; "),b")"])))
        } else {
            let mut urls=Vec::new();
            for r in recs { urls.push(jv::s(&text_default(f(r,"resolved")?,b"no recorded source"))); }
            Ok(Some(cat(&[b"source\t",key,b" (",&here,b" from ",&join_unique(urls,b" or "),b")"])))
        }
    }
}

fn read_bundles(dir: &Path, keys: &[W]) -> Result<Bundles, ()> {
    let mut bundles=Bundles::new();
    for key in keys {
        let mut rest=key.as_slice();
        while let Some(i)=rest.windows(14).rposition(|w| w == b"/node_modules/") {
            rest=&rest[..i];
            if !rest.windows(13).any(|w| w == b"node_modules/") { break }
            let file=dir.join(sh::p(rest)).join("package.json");
            if !sh::is_file(&file) { continue }
            let st=jv::read_file(&file).ok_or(())?;
            if st.failed { return Err(()) }
            for v in st.values {
                let Value::Obj(o)=&v else { return Err(()) };
                let bd=f(&v,if o.iter().any(|(k,_)| k == b"bundleDependencies") { "bundleDependencies" } else { "bundledDependencies" })?;
                let mut names=match bd {
                    Value::Bool(true) => match f(&v,"dependencies")? { Value::Obj(o) => o.iter().map(|(k,_)| k.clone()).collect(), _=>Vec::new() },
                    Value::Obj(o) => o.iter().map(|(k,_)| k.clone()).collect(),
                    Value::Arr(a) => a.iter().filter_map(jv::text).map(Vec::from).collect(),
                    _ => Vec::new(),
                };
                if !matches!(bd,Value::Arr(_)) { names.sort(); }
                bundles.insert(rest.to_vec(),names);
            }
        }
    }
    Ok(bundles)
}

fn records(dir: &Path) -> Result<Records, ()> {
    let mut out=Records::new();
    for name in ["package-lock.json","node_modules/.package-lock.json"] {
        let file=dir.join(name); if !sh::is_file(&file) { continue }
        let st=jv::read_file(&file).ok_or(())?; if st.failed { return Err(()) }
        for v in st.values {
            match f(&v,"packages")? {
                Value::Null | Value::Bool(false) => {}
                Value::Obj(o) => for (k,v) in o { if !k.is_empty() { out.entry(k.clone()).or_default().push(v.clone()); } },
                Value::Arr(a) if a.is_empty() => {}
                _=>return Err(()),
            }
        }
    }
    Ok(out)
}

/// Every line of the bash tree judgment, before shell command substitution.
pub fn judge(dir: &Path, home: &Path, query: &jv::Stream, withheld: &Value, problems: Fetch<'_>, origins: Fetch<'_>) -> Result<Vec<W>, ()> {
    if query.failed || query.values.len()!=1 { return Err(()) }
    let Value::Arr(items)=&query.values[0] else { return Err(()) };
    let mut locations=Vec::new(); let mut nodes=Nodes::new();
    for node in items {
        if !matches!(node,Value::Obj(_)) { continue }
        let loc=f(node,"location")?;
        if !jv::truthy(loc) || matches!(loc,Value::Str(s) if s.is_empty()) { continue }
        let Value::Str(k)=loc else { return Err(()) };
        locations.push(k.clone()); nodes.insert(k.clone(),node.clone());
    }
    let records=records(dir)?;
    let mut j=Judge{records:&records,nodes:&nodes,bundles:None,withheld,problems,memo:BTreeMap::new()};
    let mut nested=Vec::new();
    for loc in &locations { if j.verdict(loc)?.is_some_and(|l| l.starts_with(b"nested\t")) { nested.push(loc.clone()); } }
    let bundles=read_bundles(dir,&nested).unwrap_or_default();
    if !nested.is_empty() { j.bundles=Some(&bundles); j.memo.clear(); }
    let mut lines=Vec::new();
    let mut has_candidates=false;
    for loc in &locations {
        let Some(line)=j.verdict(loc)? else { continue };
        let is_fetched=line.starts_with(b"fetched\t");
        let is_held=line.starts_with(b"withheld\t");
        has_candidates |= line.starts_with(b"candidate\t"); lines.push(line);
        if !(is_fetched || is_held) { continue }
        let package=text_default(f(nodes.get(loc).ok_or(())?,"name")?,b"?");
        let recs=records.get(loc).map(Vec::as_slice).unwrap_or(&[]);
        let mut values=Vec::new();
        for r in recs {
            if is_fetched { values.extend(origins(f(r,"resolved")?)?); }
            else {
                for token in jv::tokens(r) {
                    let wh=jv::field_bytes(withheld,&token)?;
                    if !jv::truthy(wh) { continue }
                    let project=text_default(f(wh,"project")?,b"?");
                    let from=alt(f(wh,"origins")?,&Value::Arr(vec![jv::s(b"?the record does not say")]));
                    let from=match from { Value::Arr(a)=>a, v=>vec![v] };
                    for origin in from { values.push(jv::obj(vec![("project",jv::s(&project)),("origin",jv::s(&jv::tostring(&origin)))])); }
                }
            }
        }
        for v in jv::unique(values) {
            if is_fetched { lines.push(cat(&[b"origin\t",&package,b"\t",&origin_text(&v)?])); }
            else { lines.push(cat(&[b"held\t",&package,b"\t",&jv::tostring(f(&v,"origin")?),b"\t",&jv::tostring(f(&v,"project")?)])); }
        }
    }
    if has_candidates {
        let members=workspaces::physical_members(dir,home);
        let mut converted=Vec::new();
        // read -r consumes lines, including newlines a JSON string supplied.
        for raw in lines.iter().flat_map(|l| l.split(|b| *b==b'\n')) {
            if !raw.starts_with(b"candidate\t") { converted.push(raw.to_vec()); continue }
            let fields=sh::read_tab(raw,3);
            let target=sh::p(&cat(&[sh::bytes(dir),b"/",&fields[1]]));
            if sh::cd_physical(Path::new("."),&target).is_some_and(|p| members.iter().any(|m| m==sh::bytes(&p))) { continue }
            converted.push(cat(&[b"directory\t",&fields[2]]));
        }
        lines=converted;
    }
    Ok(lines)
}
