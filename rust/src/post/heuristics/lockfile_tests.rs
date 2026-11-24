//! The lockfile heuristic's count: package names `package-lock.json` holds
//! that it did not hold before the command, judged against the threshold of 50.
//!
//! Every lock here is synthetic and written the way npm lays one out, one
//! field per line, so a count of the lines that changed would see what a
//! count of the lines of a real lock sees.
use super::{cat, lockfile, sh, Store};
use std::{fs, path::PathBuf};

const COUNTED: &[u8] = b"Unusually large number of new dependencies added: ";
const UNCOUNTED: &[u8] = b"New dependencies could not be counted: ";

/// One entry of a `packages` map: its key, the package it declares where the
/// key is an alias, and its version.
struct Entry {
    key: String,
    name: Option<String>,
    version: String,
}

fn at(key: &str, name: Option<&str>, version: &str) -> Entry {
    Entry { key: key.into(), name: name.map(Into::into), version: version.into() }
}
fn top(name: &str, version: &str) -> Entry { at(&format!("node_modules/{name}"), None, version) }
fn names(prefix: &str, range: std::ops::Range<usize>) -> Vec<String> { range.map(|i| format!("{prefix}{i:02}")).collect() }
fn tops(names: &[String], version: &str) -> Vec<Entry> { names.iter().map(|n| top(n, version)).collect() }

/// The fields npm writes for a package fetched from the public registry.
fn fields(real: &str, version: &str, indent: &str) -> String {
    let base = real.rsplit('/').next().unwrap_or(real);
    format!("{indent}\"version\": \"{version}\",\n{indent}\"resolved\": \"https://registry.npmjs.org/{real}/-/{base}-{version}.tgz\",\n{indent}\"integrity\": \"sha512-{real}-{version}\"")
}

/// A lockfileVersion 3 lock: the `packages` map alone, in key order.
fn v3(entries: &[Entry]) -> String {
    let mut sorted: Vec<&Entry> = entries.iter().collect();
    sorted.sort_by(|a, b| a.key.cmp(&b.key));
    let mut out = String::from("{\n  \"name\": \"fixture\",\n  \"version\": \"1.0.0\",\n  \"lockfileVersion\": 3,\n  \"requires\": true,\n  \"packages\": {\n    \"\": {\n      \"name\": \"fixture\",\n      \"version\": \"1.0.0\"\n    }");
    for e in sorted {
        let real = e.name.clone().unwrap_or_else(|| e.key.rsplit("node_modules/").next().unwrap_or(&e.key).to_string());
        out.push_str(&format!(",\n    \"{}\": {{\n", e.key));
        if let Some(n) = &e.name { out.push_str(&format!("      \"name\": \"{n}\",\n")); }
        out.push_str(&fields(&real, &e.version, "      "));
        out.push_str("\n    }");
    }
    out.push_str("\n  }\n}\n");
    out
}

/// One entry of a `dependencies` tree, with the entries nested under it.
struct Dep {
    name: String,
    version: String,
    nested: Vec<Dep>,
}

fn dep(name: &str, version: &str) -> Dep { Dep { name: name.into(), version: version.into(), nested: Vec::new() } }

fn tree(deps: &[Dep], indent: usize) -> String {
    let pad = " ".repeat(indent);
    let rows: Vec<String> = deps.iter().map(|d| {
        let real = d.version.strip_prefix("npm:").map(|s| s[..s.rfind('@').filter(|i| *i > 0).unwrap_or(s.len())].to_string()).unwrap_or_else(|| d.name.clone());
        let version = d.version.strip_prefix("npm:").and_then(|s| s.rfind('@').filter(|i| *i > 0).map(|i| s[i + 1..].to_string())).unwrap_or_else(|| d.version.clone());
        let mut body = fields(&real, &version, &" ".repeat(indent + 2)).replacen(&format!("\"version\": \"{version}\""), &format!("\"version\": \"{}\"", d.version), 1);
        if !d.nested.is_empty() { body.push_str(&format!(",\n{}\"dependencies\": {{\n{}\n{}}}", " ".repeat(indent + 2), tree(&d.nested, indent + 4), " ".repeat(indent + 2))); }
        format!("{pad}\"{}\": {{\n{body}\n{pad}}}", d.name)
    }).collect();
    rows.join(",\n")
}

/// A lockfileVersion 1 lock: the `dependencies` tree alone.
fn v1(deps: &[Dep]) -> String {
    format!("{{\n  \"name\": \"fixture\",\n  \"version\": \"1.0.0\",\n  \"lockfileVersion\": 1,\n  \"requires\": true,\n  \"dependencies\": {{\n{}\n  }}\n}}\n", tree(deps, 4))
}

/// A lockfileVersion 2 lock: the `packages` map and the `dependencies` tree
/// of the same top-level packages.
fn v2(entries: &[Entry]) -> String {
    let deps: Vec<Dep> = entries.iter().map(|e| dep(e.key.trim_start_matches("node_modules/"), &e.version)).collect();
    v2_with(entries, &deps)
}
/// A lockfileVersion 2 lock whose tree is the one given, whatever its map holds.
fn v2_with(entries: &[Entry], deps: &[Dep]) -> String {
    let packages = v3(entries);
    let packages = packages.trim_end().trim_end_matches('}').trim_end().replacen("\"lockfileVersion\": 3", "\"lockfileVersion\": 2", 1);
    format!("{packages},\n  \"dependencies\": {{\n{}\n  }}\n}}\n", tree(deps, 4))
}

/// A project and a home whose snapshot holds `before` as the copy of
/// package-lock.json taken before the command (None: there was no lockfile),
/// with `after` as the project's package-lock.json, and the reasons the
/// heuristic gives for that change.
fn judge(before: Option<&[u8]>, after: &[u8]) -> Vec<Vec<u8>> {
    let root = sh::mktemp_dir(&cat(&[sh::bytes(&std::env::temp_dir()), b"/safedeps-lockfile-names."])).unwrap();
    let (home, project): (PathBuf, PathBuf) = (root.join("home"), root.join("project"));
    for dir in [home.join("snapshots"), project.clone()] { fs::create_dir_all(dir).unwrap(); }
    let store = Store::new(home, project.clone(), b"call".to_vec());
    if let Some(before) = before { fs::write(store.path(&store.id, b"package-lock.json"), before).unwrap(); }
    fs::write(project.join("package-lock.json"), after).unwrap();
    let mut reasons = Vec::new();
    lockfile(&store, &mut reasons);
    sh::rm_rf(&root);
    reasons
}
fn counted(n: usize) -> Vec<Vec<u8>> { vec![cat(&[COUNTED, n.to_string().as_bytes()])] }
fn shown(reasons: &[Vec<u8>]) -> Vec<String> { reasons.iter().map(|r| String::from_utf8_lossy(r).into_owned()).collect() }

/// Done criterion 1: a lock change that only moves 60 packages to another
/// version brings in no name. Counted as resolved lines, it was 60.
#[test]
fn moving_sixty_packages_to_another_version_adds_no_dependency() {
    let held = names("pkg-", 0..60);
    let reasons = judge(Some(v3(&tops(&held, "1.0.0")).as_bytes()), v3(&tops(&held, "1.0.1")).as_bytes());
    assert!(reasons.is_empty(), "{:?}", shown(&reasons));
}

/// Done criterion 2: 51 names new to the lock are counted, and the number in
/// the reason is the number of names.
#[test]
fn fifty_one_new_names_are_counted_as_fifty_one() {
    let held = names("pkg-", 0..10);
    let mut after = tops(&held, "1.0.0");
    after.extend(tops(&names("new-", 0..51), "1.0.0"));
    assert_eq!(shown(&judge(Some(v3(&tops(&held, "1.0.0")).as_bytes()), v3(&after).as_bytes())), shown(&counted(51)));
}

/// Done criterion 2: 60 version moves beside 10 new names count 10.
#[test]
fn sixty_version_moves_beside_ten_new_names_count_ten() {
    let held = names("pkg-", 0..60);
    let mut after = tops(&held, "2.0.0");
    after.extend(tops(&names("new-", 0..10), "1.0.0"));
    let reasons = judge(Some(v3(&tops(&held, "1.0.0")).as_bytes()), v3(&after).as_bytes());
    assert!(reasons.is_empty(), "{:?}", shown(&reasons));
}

/// Done criterion 2: the threshold is more than 50.
#[test]
fn fifty_new_names_are_under_the_threshold_and_fifty_one_are_over_it() {
    let held = names("pkg-", 0..5);
    for (new, want) in [(50, Vec::new()), (51, counted(51))] {
        let mut after = tops(&held, "1.0.0");
        after.extend(tops(&names("new-", 0..new), "1.0.0"));
        assert_eq!(shown(&judge(Some(v3(&tops(&held, "1.0.0")).as_bytes()), v3(&after).as_bytes())), shown(&want), "{new} new names");
    }
}

/// Done criterion 3: a name the lock already held, at new places and new
/// versions, is not a new name.
#[test]
fn a_name_already_held_at_new_places_and_versions_is_not_new() {
    let hosts = names("host-", 0..60);
    let mut before = tops(&hosts, "1.0.0");
    before.push(top("shared", "1.0.0"));
    let mut after = tops(&hosts, "1.0.0");
    after.push(top("shared", "1.0.0"));
    after.extend(hosts.iter().enumerate().map(|(i, h)| at(&format!("node_modules/{h}/node_modules/shared"), None, &format!("2.{i}.0"))));
    let reasons = judge(Some(v3(&before).as_bytes()), v3(&after).as_bytes());
    assert!(reasons.is_empty(), "{:?}", shown(&reasons));
}

/// Done criterion 4: a lock that cannot be read by name is not counted as
/// none. Each of these, after the command, is a reason.
#[test]
fn a_lock_after_the_command_that_cannot_be_read_is_a_reason() {
    let before = v3(&tops(&names("pkg-", 0..3), "1.0.0"));
    for (label, after) in [
        ("not JSON", b"{\n  \"packages\": {\n".to_vec()),
        ("no JSON text", Vec::new()),
        ("two JSON texts", b"{}\n{}\n".to_vec()),
        ("an array", b"[]\n".to_vec()),
        ("packages not a map", b"{\"lockfileVersion\": 3, \"packages\": []}\n".to_vec()),
        ("dependencies not a map", b"{\"lockfileVersion\": 1, \"dependencies\": \"x\"}\n".to_vec()),
        ("an entry not a map", b"{\"lockfileVersion\": 3, \"packages\": {\"node_modules/a\": 1}}\n".to_vec()),
        ("a name not a string", b"{\"lockfileVersion\": 3, \"packages\": {\"node_modules/a\": {\"name\": 7}}}\n".to_vec()),
        ("a NUL byte", b"{\"packages\": {\"node_modules/a\x00\": {}}}\n".to_vec()),
    ] {
        let reasons = judge(Some(before.as_bytes()), &after);
        assert_eq!(shown(&reasons), vec![format!("{}package-lock.json could not be read as a lockfile", String::from_utf8_lossy(UNCOUNTED))], "{label}");
    }
}

/// Done criterion 4: so is the copy from before the command, when it holds a
/// JSON text that is not a lockfile.
#[test]
fn a_lock_before_the_command_that_cannot_be_read_is_a_reason() {
    let after = v3(&tops(&names("pkg-", 0..3), "1.0.0"));
    for (label, before) in [("not JSON", b"<<<<<<< ours\n".to_vec()), ("an array", b"[1]\n".to_vec())] {
        let reasons = judge(Some(before.as_slice()), after.as_bytes());
        assert_eq!(shown(&reasons), vec![format!("{}package-lock.json from before the command could not be read as a lockfile", String::from_utf8_lossy(UNCOUNTED))], "{label}");
    }
}

/// A copy from before the command that holds no JSON text held no names:
/// npm reads an empty lockfile as none. Every name after it is new.
#[test]
fn an_empty_lock_before_the_command_held_no_names() {
    let after = v3(&tops(&names("new-", 0..51), "1.0.0"));
    for before in [&b""[..], &b"\n  \n"[..], &b"{}\n"[..]] {
        assert_eq!(shown(&judge(Some(before), after.as_bytes())), shown(&counted(51)), "{:?}", String::from_utf8_lossy(before));
    }
}

/// Where there was no lockfile before the command, the heuristic does not
/// count (ARCHITECTURE.md: the count would cross 50 on the first install of
/// any project with more than 50 dependencies). It did not before this
/// change either. The approvals ledger judges every package of such an
/// install, since each one is in the closure.
#[test]
fn a_first_install_is_not_counted() {
    let reasons = judge(None, v3(&tops(&names("new-", 0..60), "1.0.0")).as_bytes());
    assert!(reasons.is_empty(), "{:?}", shown(&reasons));
}

/// Names are bytes: a scope, or case alone, makes another name.
#[test]
fn a_name_another_scope_or_case_makes_is_new() {
    let held = names("pkg-", 0..51);
    let before = v3(&tops(&held, "1.0.0"));
    let scoped: Vec<String> = held.iter().map(|n| format!("@other/{n}")).collect();
    let upper: Vec<String> = held.iter().map(|n| n.to_uppercase()).collect();
    for new in [scoped, upper] {
        let mut after = tops(&held, "1.0.0");
        after.extend(tops(&new, "1.0.0"));
        assert_eq!(shown(&judge(Some(before.as_bytes()), v3(&after).as_bytes())), shown(&counted(51)), "{}", new[0]);
    }
}

/// An alias puts one package under another name. Either name new to the
/// lock is counted, so an alias cannot pass a new package as one already held.
#[test]
fn an_alias_is_counted_by_either_name() {
    let held = names("pkg-", 0..51);
    let before = v3(&tops(&held, "1.0.0"));
    // An old folder name over a new package, nested under a package held.
    let mut after = tops(&held, "1.0.0");
    after.extend(held.iter().enumerate().map(|(i, h)| at(&format!("node_modules/pkg-00/node_modules/{h}"), Some(format!("new-{i:02}").as_str()), "1.0.0")));
    assert_eq!(shown(&judge(Some(before.as_bytes()), v3(&after).as_bytes())), shown(&counted(51)), "new packages under held names");
    // A new folder name over a package held.
    let mut after = tops(&held, "1.0.0");
    after.extend(held.iter().enumerate().map(|(i, h)| at(&format!("node_modules/alias-{i:02}"), Some(h.as_str()), "1.0.0")));
    assert_eq!(shown(&judge(Some(before.as_bytes()), v3(&after).as_bytes())), shown(&counted(51)), "held packages under new names");
    // The dependencies tree spells an alias as an npm: version.
    let mut deps: Vec<Dep> = held.iter().map(|h| dep(h, "1.0.0")).collect();
    let before = v1(&deps);
    deps[0].nested = held.iter().enumerate().map(|(i, h)| dep(h, &format!("npm:new-{i:02}@1.0.0"))).collect();
    assert_eq!(shown(&judge(Some(before.as_bytes()), v1(&deps).as_bytes())), shown(&counted(51)), "npm: versions in the dependencies tree");
}

/// A new package nested under a package held is named by its own place.
#[test]
fn a_new_package_nested_under_a_held_one_is_counted() {
    let before = v3(&[top("host", "1.0.0")]);
    let new = names("new-", 0..51);
    for (label, place) in [("in its node_modules", "node_modules/host/node_modules/"), ("in its folder", "node_modules/host/")] {
        let mut after = vec![top("host", "1.0.0")];
        after.extend(new.iter().map(|n| at(&format!("{place}{n}"), None, "1.0.0")));
        assert_eq!(shown(&judge(Some(before.as_bytes()), v3(&after).as_bytes())), shown(&counted(51)), "{label}");
    }
    // The dependencies tree nests by entry.
    let mut host = dep("host", "1.0.0");
    let before = v1(&[dep("host", "1.0.0")]);
    host.nested = new.iter().map(|n| dep(n, "1.0.0")).collect();
    assert_eq!(shown(&judge(Some(before.as_bytes()), v1(&[host]).as_bytes())), shown(&counted(51)), "in the dependencies tree");
}

/// A lock written in another layout holds the same names: npm moving a
/// lockfileVersion 1 lock to 3 brings in none. Names it adds on the way are
/// counted.
#[test]
fn a_lock_moved_to_another_lockfile_version_is_counted_by_name() {
    let held = names("pkg-", 0..60);
    let deps: Vec<Dep> = held.iter().map(|h| dep(h, "1.0.0")).collect();
    let reasons = judge(Some(v1(&deps).as_bytes()), v3(&tops(&held, "1.0.0")).as_bytes());
    assert!(reasons.is_empty(), "version 1 to 3: {:?}", shown(&reasons));
    let mut after = tops(&held, "1.0.0");
    after.extend(tops(&names("new-", 0..51), "1.0.0"));
    assert_eq!(shown(&judge(Some(v1(&deps).as_bytes()), v3(&after).as_bytes())), shown(&counted(51)), "version 1 to 3, with 51 new names");
    let more: Vec<Dep> = held.iter().chain(names("new-", 0..51).iter()).map(|n| dep(n, "1.0.0")).collect();
    assert_eq!(shown(&judge(Some(v3(&tops(&held, "1.0.0")).as_bytes()), v1(&more).as_bytes())), shown(&counted(51)), "version 3 to 1, with 51 new names");
}

/// A lockfileVersion 2 lock records each package twice, in its map and in
/// its tree. A package is still one name.
#[test]
fn a_package_recorded_in_both_maps_of_a_version_2_lock_is_one_name() {
    let held = names("pkg-", 0..5);
    let mut after = tops(&held, "1.0.0");
    after.extend(tops(&names("new-", 0..30), "1.0.0"));
    let reasons = judge(Some(v2(&tops(&held, "1.0.0")).as_bytes()), v2(&after).as_bytes());
    assert!(reasons.is_empty(), "30 new names: {:?}", shown(&reasons));
    after.extend(tops(&names("more-", 0..21), "1.0.0"));
    assert_eq!(shown(&judge(Some(v2(&tops(&held, "1.0.0")).as_bytes()), v2(&after).as_bytes())), shown(&counted(51)), "51 new names");
}

/// The copy from before the command holds what npm reads of it: its
/// `packages` map where it has one, as the effect gate reads a record. A
/// name only its `dependencies` tree lists is not held there. After the
/// command, a name either map lists counts.
#[test]
fn a_name_only_the_unread_tree_of_the_copy_lists_is_not_held() {
    let held = names("pkg-", 0..5);
    let new = names("new-", 0..51);
    let both: Vec<Dep> = held.iter().chain(new.iter()).map(|n| dep(n, "1.0.0")).collect();
    let mut after = tops(&held, "1.0.0");
    after.extend(tops(&new, "1.0.0"));
    assert_eq!(shown(&judge(Some(v2_with(&tops(&held, "1.0.0"), &both).as_bytes()), v3(&after).as_bytes())), shown(&counted(51)), "names only the copy's tree lists");
    assert_eq!(shown(&judge(Some(v3(&tops(&held, "1.0.0")).as_bytes()), v2_with(&tops(&held, "1.0.0"), &both).as_bytes())), shown(&counted(51)), "names only the tree after the command lists");
}

/// A validator's two probes, kept as the validator wrote them: 51 workspace
/// members whose folders move while their names stay, and the control where
/// the names change in the same folders. Each lock is one line here.
fn workspace_lock(names: &[String], directory_prefix: &str) -> String {
    let mut entries = vec![r#""":{"name":"fixture","workspaces":["packages/*"]}"#.to_owned()];
    for (i, name) in names.iter().enumerate() {
        let place = format!("packages/{directory_prefix}-{i:02}");
        entries.push(format!(r#""node_modules/{name}":{{"resolved":"{place}","link":true}}"#));
        entries.push(format!(r#""{place}":{{"name":"{name}","version":"1.0.0"}}"#));
    }
    format!(r#"{{"name":"fixture","lockfileVersion":3,"packages":{{{}}}}}"#, entries.join(","))
}

#[test]
fn validator_workspace_directory_renames_add_no_packages() {
    let members = names("@fixture/member-", 0..51);
    let before = workspace_lock(&members, "old-folder");
    let after = workspace_lock(&members, "new-folder");
    let reasons = judge(Some(before.as_bytes()), after.as_bytes());
    assert!(reasons.is_empty(), "51 directory renames, zero new package names: {:?}", shown(&reasons));
}

#[test]
fn validator_workspace_name_change_control_counts_51_packages() {
    let before = workspace_lock(&names("@fixture/old-", 0..51), "same-folder");
    let after = workspace_lock(&names("@fixture/new-", 0..51), "same-folder");
    let reasons = judge(Some(before.as_bytes()), after.as_bytes());
    assert_eq!(shown(&reasons), shown(&counted(51)));
}

// Every shape of key and entry the two maps hold, and where the count reads a
// name in each. A shape has two rows where both can be written: a name that
// stays while its place changes, which adds no name, and a place that stays
// while its name changes, which adds one. Each row changes 51 entries, so a
// reading that takes a place for a name, or misses a name, lands on the wrong
// side of the threshold. Where npm's own writing decides a row (the folders
// it writes no `name` for, what it installs), the row is written as npm
// writes it; the shapes are synthetic.

/// The fields of one lock entry: each field's name and its JSON text.
type Fields = Vec<(&'static str, String)>;
type Entries = Vec<(String, Fields)>;

fn q(s: &str) -> String { format!("\"{s}\"") }
fn last(key: &str) -> &str { key.rsplit('/').next().unwrap_or(key) }
fn each(f: impl Fn(&str) -> Entries) -> Entries { (0..51).flat_map(|i| f(&format!("{i:02}"))).collect() }

/// An entry at `key`, with the `name` npm writes where the package's own name
/// is not the one its folder gives, and these fields.
fn entry(key: &str, name: Option<&str>, rest: Fields) -> Entries {
    let mut fields: Fields = name.map(|n| vec![("name", q(n))]).unwrap_or_default();
    fields.extend(rest);
    vec![(key.to_owned(), fields)]
}
fn registry(key: &str, name: Option<&str>) -> Entries {
    let real = name.unwrap_or(last(key));
    entry(key, name, vec![("version", q("1.0.0")), ("resolved", q(&format!("https://registry.npmjs.org/{real}/-/{}-1.0.0.tgz", last(real)))), ("integrity", q(&format!("sha512-{real}")))])
}
fn git(key: &str, name: Option<&str>) -> Entries {
    entry(key, name, vec![("version", q("1.0.0")), ("resolved", q(&format!("git+ssh://git@example.com/{}.git#0123456789abcdef0123456789abcdef01234567", last(key))))])
}
fn remote(key: &str, name: Option<&str>) -> Entries {
    entry(key, name, vec![("version", q("1.0.0")), ("resolved", q(&format!("https://example.com/{}-1.0.0.tgz", last(key)))), ("integrity", q(&format!("sha512-{key}")))])
}
fn local(key: &str, name: Option<&str>) -> Entries {
    entry(key, name, vec![("version", q("1.0.0")), ("resolved", q(&format!("file:tgz/{}-1.0.0.tgz", last(key)))), ("integrity", q(&format!("sha512-{key}")))])
}
/// A package another package's tarball carries: npm writes no source for it.
fn bundled(key: &str, name: Option<&str>) -> Entries { entry(key, name, vec![("version", q("1.0.0")), ("inBundle", "true".into())]) }
/// A link npm writes for a workspace member or a directory dependency.
fn link(key: &str, dir: &str) -> Entries { entry(key, None, vec![("resolved", q(dir)), ("link", "true".into())]) }
/// The folder a link points at.
fn directory(dir: &str, name: Option<&str>) -> Entries { entry(dir, name, vec![("version", q("1.0.0"))]) }

/// A lockfileVersion 3 lock: the project and these entries, in key order,
/// one field per line.
fn lock3(entries: &Entries) -> String {
    let mut sorted: Vec<&(String, Fields)> = entries.iter().collect();
    sorted.sort_by(|a, b| a.0.cmp(&b.0));
    let mut out = String::from("{\n  \"name\": \"fixture\",\n  \"version\": \"1.0.0\",\n  \"lockfileVersion\": 3,\n  \"requires\": true,\n  \"packages\": {\n    \"\": {\n      \"name\": \"fixture\",\n      \"version\": \"1.0.0\"\n    }");
    for (key, fields) in sorted {
        let body: Vec<String> = fields.iter().map(|(k, v)| format!("      \"{k}\": {v}")).collect();
        out.push_str(&format!(",\n    \"{key}\": {{\n{}\n    }}", body.join(",\n")));
    }
    out.push_str("\n  }\n}\n");
    out
}

/// One entry of a `dependencies` tree: its name, its fields, and the entries
/// nested under it.
struct Node1 {
    name: String,
    fields: Fields,
    nested: Vec<Node1>,
}

fn node1(name: &str, version: &str, more: Fields) -> Node1 {
    let mut fields = vec![("version", q(version))];
    fields.extend(more);
    Node1 { name: name.into(), fields, nested: Vec::new() }
}
fn tree1(nodes: &[Node1], indent: usize) -> String {
    let pad = " ".repeat(indent);
    let rows: Vec<String> = nodes.iter().map(|n| {
        let mut body: Vec<String> = n.fields.iter().map(|(k, v)| format!("{pad}  \"{k}\": {v}")).collect();
        if !n.nested.is_empty() { body.push(format!("{pad}  \"dependencies\": {{\n{}\n{pad}  }}", tree1(&n.nested, indent + 4))); }
        format!("{pad}\"{}\": {{\n{}\n{pad}}}", n.name, body.join(",\n"))
    }).collect();
    rows.join(",\n")
}
/// A lockfileVersion 1 lock: the `dependencies` tree of these entries.
fn lock1(nodes: &[Node1]) -> String {
    format!("{{\n  \"name\": \"fixture\",\n  \"version\": \"1.0.0\",\n  \"lockfileVersion\": 1,\n  \"requires\": true,\n  \"dependencies\": {{\n{}\n  }}\n}}\n", tree1(nodes, 4))
}

/// A row of the table: the shape, the change, the locks before and after the
/// command, and how many names the change adds.
struct Shape {
    shape: &'static str,
    change: &'static str,
    before: String,
    after: String,
    adds: usize,
}

/// Packages held before and after: two packages others nest under, and two
/// workspace members with their links.
fn held() -> Entries {
    [registry("node_modules/host", None), registry("node_modules/host-b", None), link("node_modules/ws-a", "packages/a"), directory("packages/a", Some("ws-a")), link("node_modules/ws-b", "packages/b"), directory("packages/b", Some("ws-b"))].concat()
}
fn map_row(shape: &'static str, change: &'static str, before: Entries, after: Entries, adds: usize) -> Shape {
    Shape { shape, change, before: lock3(&[held(), before].concat()), after: lock3(&[held(), after].concat()), adds }
}
fn tree_row(shape: &'static str, change: &'static str, before: Vec<Node1>, after: Vec<Node1>, adds: usize) -> Shape {
    let with_hosts = |mut nodes: Vec<Node1>| {
        let (mut host, mut host_b) = (node1("host", "1.0.0", vec![]), node1("host-b", "1.0.0", vec![]));
        let (under_host, under_b): (Vec<Node1>, Vec<Node1>) = nodes.drain(..).partition(|n| !n.name.starts_with("host-b/"));
        let (under_host, top): (Vec<Node1>, Vec<Node1>) = under_host.into_iter().partition(|n| n.name.starts_with("host/"));
        host.nested = under_host.into_iter().map(|mut n| { n.name = n.name["host/".len()..].into(); n }).collect();
        host_b.nested = under_b.into_iter().map(|mut n| { n.name = n.name["host-b/".len()..].into(); n }).collect();
        let mut all = vec![host, host_b];
        all.extend(top);
        lock1(&all)
    };
    Shape { shape, change, before: with_hosts(before), after: with_hosts(after), adds }
}

fn shapes() -> Vec<Shape> {
    let mut rows = Vec::new();
    type Make = fn(&str, Option<&str>) -> Entries;
    for (shape, make) in [
        ("packages: a registry package at node_modules/<name>", registry as Make),
        ("packages: a git dependency", git as Make),
        ("packages: a remote tarball", remote as Make),
        ("packages: a local tarball", local as Make),
    ] {
        rows.push(map_row(shape, "the same name nested under another package", each(|i| make(&format!("node_modules/pkg-{i}"), None)), each(|i| make(&format!("node_modules/host/node_modules/pkg-{i}"), None)), 0));
        rows.push(map_row(shape, "the same place holds another package (an alias)", each(|i| make(&format!("node_modules/pkg-{i}"), None)), each(|i| make(&format!("node_modules/pkg-{i}"), Some(format!("new-{i}").as_str()))), 51));
    }
    rows.push(map_row("packages: a scoped package", "the same name nested under another package", each(|i| registry(&format!("node_modules/@scope/pkg-{i}"), None)), each(|i| registry(&format!("node_modules/host/node_modules/@scope/pkg-{i}"), None)), 0));
    rows.push(map_row("packages: a scoped package", "the same place holds another package (an alias)", each(|i| registry(&format!("node_modules/@scope/pkg-{i}"), None)), each(|i| registry(&format!("node_modules/@scope/pkg-{i}"), Some(format!("@scope/new-{i}").as_str()))), 51));
    rows.push(map_row("packages: a nested package", "the same name under another package", each(|i| registry(&format!("node_modules/host/node_modules/pkg-{i}"), None)), each(|i| registry(&format!("node_modules/host-b/node_modules/pkg-{i}"), None)), 0));
    rows.push(map_row("packages: a nested package", "the same place holds another package", each(|i| registry(&format!("node_modules/host/node_modules/pkg-{i}"), None)), each(|i| registry(&format!("node_modules/host/node_modules/pkg-{i}"), Some(format!("new-{i}").as_str()))), 51));
    rows.push(map_row("packages: an alias (a place name and the package's name)", "both names move under another package", each(|i| registry(&format!("node_modules/al-{i}"), Some(format!("pkg-{i}").as_str()))), each(|i| registry(&format!("node_modules/host/node_modules/al-{i}"), Some(format!("pkg-{i}").as_str()))), 0));
    rows.push(map_row("packages: an alias (a place name and the package's name)", "the same place aliases another package", each(|i| registry(&format!("node_modules/al-{i}"), Some(format!("pkg-{i}").as_str()))), each(|i| registry(&format!("node_modules/al-{i}"), Some(format!("new-{i}").as_str()))), 51));
    rows.push(map_row("packages: a bundled package (inBundle)", "the same name bundled by another package", each(|i| bundled(&format!("node_modules/host/node_modules/pkg-{i}"), None)), each(|i| bundled(&format!("node_modules/host-b/node_modules/pkg-{i}"), None)), 0));
    rows.push(map_row("packages: a bundled package (inBundle)", "the same place holds another package", each(|i| bundled(&format!("node_modules/host/node_modules/pkg-{i}"), None)), each(|i| bundled(&format!("node_modules/host/node_modules/pkg-{i}"), Some(format!("new-{i}").as_str()))), 51));
    rows.push(map_row("packages: a workspace member's own dependency", "the same name under another member", each(|i| registry(&format!("packages/a/node_modules/pkg-{i}"), None)), each(|i| registry(&format!("packages/b/node_modules/pkg-{i}"), None)), 0));
    rows.push(map_row("packages: a workspace member's own dependency", "the same place holds another package", each(|i| registry(&format!("packages/a/node_modules/pkg-{i}"), None)), each(|i| registry(&format!("packages/a/node_modules/pkg-{i}"), Some(format!("new-{i}").as_str()))), 51));
    rows.push(map_row("packages: a link and the directory it points at", "the directory moves; npm writes its name there", each(|i| [link(&format!("node_modules/dd-{i}"), &format!("vendor/dd-{i}")), directory(&format!("vendor/dd-{i}"), None)].concat()), each(|i| [link(&format!("node_modules/dd-{i}"), &format!("vendor/moved-{i}")), directory(&format!("vendor/moved-{i}"), Some(format!("dd-{i}").as_str()))].concat()), 0));
    rows.push(map_row("packages: a link and the directory it points at", "the package in the same directory takes another name", each(|i| [link(&format!("node_modules/dd-{i}"), &format!("vendor/dd-{i}")), directory(&format!("vendor/dd-{i}"), None)].concat()), each(|i| [link(&format!("node_modules/new-{i}"), &format!("vendor/dd-{i}")), directory(&format!("vendor/dd-{i}"), Some(format!("new-{i}").as_str()))].concat()), 51));
    rows.push(map_row("packages: a directory whose entry gives its name", "the folder moves", each(|i| directory(&format!("packages/dir-{i}"), Some(format!("@fixture/m-{i}").as_str()))), each(|i| directory(&format!("packages/moved-{i}"), Some(format!("@fixture/m-{i}").as_str()))), 0));
    rows.push(map_row("packages: a directory whose entry gives its name", "the same folder, another name", each(|i| directory(&format!("packages/dir-{i}"), Some(format!("@fixture/m-{i}").as_str()))), each(|i| directory(&format!("packages/dir-{i}"), Some(format!("@fixture/new-{i}").as_str()))), 51));
    rows.push(map_row("packages: a directory named as its folder (npm writes no name)", "the folder moves; npm writes its name there", each(|i| directory(&format!("packages/m-{i}"), None)), each(|i| directory(&format!("packages/moved-{i}"), Some(format!("m-{i}").as_str()))), 0));
    rows.push(map_row("packages: a directory named as its folder (npm writes no name)", "the folder moves under a folder of the same name", each(|i| directory(&format!("vendor/m-{i}"), None)), each(|i| directory(&format!("elsewhere/m-{i}"), None)), 0));
    rows.push(map_row("packages: a directory named as its folder (npm writes no name)", "the same folder, another name", each(|i| directory(&format!("packages/m-{i}"), None)), each(|i| directory(&format!("packages/m-{i}"), Some(format!("new-{i}").as_str()))), 51));
    rows.push(map_row("packages: a directory named as its scope and folder", "the folder moves; npm writes its name there", each(|i| directory(&format!("packages/@fixture/m-{i}"), None)), each(|i| directory(&format!("packages/@fixture/moved-{i}"), Some(format!("@fixture/m-{i}").as_str()))), 0));
    rows.push(map_row("packages: a directory named as its scope and folder", "the same folder, another name", each(|i| directory(&format!("packages/@fixture/m-{i}"), None)), each(|i| directory(&format!("packages/@fixture/m-{i}"), Some(format!("@fixture/new-{i}").as_str()))), 51));
    rows.push(map_row("packages: a package with no name of its own (npm names it by its folder)", "the folder moves, and npm renames the package and its link", each(|i| [link(&format!("node_modules/m-{i}"), &format!("packages/m-{i}")), directory(&format!("packages/m-{i}"), None)].concat()), each(|i| [link(&format!("node_modules/moved-{i}"), &format!("packages/moved-{i}")), directory(&format!("packages/moved-{i}"), None)].concat()), 51));
    rows.push(map_row("packages: a package with no name of its own (npm names it by its folder)", "the same folder, and the package takes a name", each(|i| [link(&format!("node_modules/m-{i}"), &format!("packages/m-{i}")), directory(&format!("packages/m-{i}"), None)].concat()), each(|i| [link(&format!("node_modules/new-{i}"), &format!("packages/m-{i}")), directory(&format!("packages/m-{i}"), Some(format!("new-{i}").as_str()))].concat()), 51));
    rows.push(map_row("packages: a folder inside a package (npm installs nothing there)", "the folder moves; its name is written", each(|i| registry(&format!("node_modules/host/sub-{i}"), None)), each(|i| registry(&format!("node_modules/host/lib/other-{i}"), Some(format!("sub-{i}").as_str()))), 0));
    rows.push(map_row("packages: a folder inside a package (npm installs nothing there)", "the same folder, another name", each(|i| registry(&format!("node_modules/host/sub-{i}"), None)), each(|i| registry(&format!("node_modules/host/sub-{i}"), Some(format!("new-{i}").as_str()))), 51));
    rows.push(map_row("packages: a key with an empty, . or .. folder (read as npm resolves it)", "the same place, spelled another way", each(|i| registry(&format!("node_modules/pkg-{i}"), None)), each(|i| registry(&format!("{}{i}", ["node_modules//pkg-", "node_modules/./pkg-", "node_modules/host/../pkg-"][i.parse::<usize>().unwrap() % 3]), None)), 0));
    rows.push(map_row("packages: a key with an empty, . or .. folder (read as npm resolves it)", "the same place holds another package", each(|i| registry(&format!("node_modules/pkg-{i}"), None)), each(|i| registry(&format!("node_modules/host/../pkg-{i}"), Some(format!("pkg-{i}-new").as_str()))), 51));
    rows.push(map_row("packages: a key with an empty, . or .. folder (read as npm resolves it)", "a new place behind .. holds a package already there", each(|i| registry(&format!("node_modules/pkg-{i}"), None)), [each(|i| registry(&format!("node_modules/pkg-{i}"), None)), each(|i| registry(&format!("node_modules/host/../al-{i}"), Some(format!("pkg-{i}").as_str())))].concat(), 51));
    rows.push(tree_row("dependencies: a package (its key is its name)", "the same name nested under another package", (0..51).map(|i| node1(&format!("pkg-{i:02}"), "1.0.0", vec![])).collect(), (0..51).map(|i| node1(&format!("host/pkg-{i:02}"), "1.0.0", vec![])).collect(), 0));
    rows.push(tree_row("dependencies: an alias (npm: version)", "the same alias nested under another package", (0..51).map(|i| node1(&format!("al-{i:02}"), &format!("npm:pkg-{i:02}@1.0.0"), vec![])).collect(), (0..51).map(|i| node1(&format!("host/al-{i:02}"), &format!("npm:pkg-{i:02}@1.0.0"), vec![])).collect(), 0));
    rows.push(tree_row("dependencies: an alias (npm: version)", "the same alias, another package", (0..51).map(|i| node1(&format!("al-{i:02}"), &format!("npm:pkg-{i:02}@1.0.0"), vec![])).collect(), (0..51).map(|i| node1(&format!("al-{i:02}"), &format!("npm:new-{i:02}@1.0.0"), vec![])).collect(), 51));
    rows.push(tree_row("dependencies: a directory (file: version, as npm writes a link)", "the directory moves", (0..51).map(|i| node1(&format!("dd-{i:02}"), &format!("file:vendor/dd-{i:02}"), vec![])).collect(), (0..51).map(|i| node1(&format!("dd-{i:02}"), &format!("file:elsewhere/moved-{i:02}"), vec![])).collect(), 0));
    rows.push(tree_row("dependencies: a git dependency", "the same name nested under another package", (0..51).map(|i| node1(&format!("pkg-{i:02}"), "git+ssh://git@example.com/x.git#0123456789abcdef0123456789abcdef01234567", vec![("from", q("git+ssh://git@example.com/x.git"))])).collect(), (0..51).map(|i| node1(&format!("host/pkg-{i:02}"), "git+ssh://git@example.com/x.git#0123456789abcdef0123456789abcdef01234567", vec![("from", q("git+ssh://git@example.com/x.git"))])).collect(), 0));
    rows.push(tree_row("dependencies: a bundled package", "the same name bundled by another package", (0..51).map(|i| node1(&format!("host/pkg-{i:02}"), "1.0.0", vec![("bundled", "true".into())])).collect(), (0..51).map(|i| node1(&format!("host-b/pkg-{i:02}"), "1.0.0", vec![("bundled", "true".into())])).collect(), 0));
    rows
}

/// Each shape counts names, not places: a name that only moves adds none,
/// and a name that changes in its place adds one.
#[test]
fn each_shape_of_key_and_entry_counts_names_not_places() {
    let rows = shapes();
    let wrong: Vec<String> = rows.iter().filter_map(|row| {
        let got = shown(&judge(Some(row.before.as_bytes()), row.after.as_bytes()));
        let want = if row.adds > 50 { shown(&counted(row.adds)) } else { Vec::new() };
        (got != want).then(|| format!("{} / {}: {:?}, want {:?}", row.shape, row.change, got, want))
    }).collect();
    assert!(wrong.is_empty(), "{} of {} rows:\n{}", wrong.len(), rows.len(), wrong.join("\n"));
}
