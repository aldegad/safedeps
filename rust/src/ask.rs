//! Ask the hook's npm directly. Command text is never executed. The only
//! carried environment is parsed argv, with code-selecting names removed.
//! Each group shares a clock deadline and owns all its children and scratch.
use crate::{ere::Regex, jq, json::{self, Value}, manager, os, outcome::{Outcome, Form}};
use std::{ffi::{OsStr}, fs::{self, File}, io, os::unix::{ffi::{OsStrExt, OsStringExt}, fs::PermissionsExt}, path::{Path, PathBuf}, process::{Child, Command, Stdio, ExitStatus}, time::{Duration, Instant}};

type W = Vec<u8>;
mod fetch;
pub use fetch::{fetch_known_problems, fetch_origin, fetch_origins, fetch_problems, host, registry_public, Origin};
pub const PRE_SECONDS: u64 = 8;
pub const POST_SECONDS: u64 = 10;

pub fn code_name(name: &[u8]) -> bool {
    matches!(name, b"PATH" | b"NODE_OPTIONS" | b"NODE_PATH" | b"OPENSSL_CONF" | b"OPENSSL_MODULES" | b"BASH_ENV")
        || name.starts_with(b"LD_") || name.starts_with(b"DYLD_") || name.eq_ignore_ascii_case(b"npm_config_node_options")
}
pub fn npm_on_path() -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&path) {
        let p = dir.join("npm");
        if fs::metadata(&p).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0) {
            // Resolve relative PATH components before changing the ask's cwd.
            return Some(if p.is_absolute() { p } else { std::env::current_dir().ok()?.join(p) });
        }
    }
    None
}

pub struct Answer { pub status: Outcome, pub stdout: W, pub stderr: W }
impl Answer {
    pub fn error(&self) -> String {
        let re = Regex::new("npm (error|ERR!) (code )?[A-Z]", false).expect("npm error pattern");
        let lines: Vec<&[u8]> = self.stderr.split(|&b| b == b'\n').collect();
        let line = lines.iter().find(|line| re.is_match(line)).copied().or_else(|| lines.first().copied()).unwrap_or_default();
        let line = line.strip_prefix(b"npm error ").unwrap_or(line);
        let line = line.strip_prefix(b"npm ERR! ").unwrap_or(line);
        if line.is_empty() { "no output".into() } else { jq::text(line) }
    }
}
struct Job { child: Child, out: PathBuf, err: PathBuf, status: Option<ExitStatus> }
struct Group { tmp: PathBuf, jobs: Vec<Job> }
impl Group {
    fn new() -> io::Result<Self> { Ok(Self { tmp: os::scratch_dir("safedeps-npm-ask")?, jobs: Vec::new() }) }
    fn start(&mut self, npm: &Path, dir: &Path, env: &[W], args: &[W]) -> io::Result<()> {
        let out = self.tmp.join(format!("ask-{}", self.jobs.len()));
        let err = out.with_extension("err");
        let mut cmd = Command::new(npm);
        cmd.current_dir(dir).stdin(Stdio::null()).stdout(File::create(&out)?).stderr(File::create(&err)?);
        // bash's cd exports these before env applies the statement's words.
        let cwd = std::env::current_dir()?;
        cmd.env("OLDPWD", std::env::var_os("PWD").unwrap_or_else(|| cwd.as_os_str().to_owned()));
        cmd.env("PWD", if dir.is_absolute() { dir.to_path_buf() } else { cwd.join(dir) });
        let mut i = 0;
        while i < env.len() {
            let word = &env[i];
            if word == b"-u" && i + 1 < env.len() {
                i += 1;
                if !code_name(&env[i]) { cmd.env_remove(OsStr::from_bytes(&env[i])); }
            } else if word == b"-i" || word == b"--ignore-environment" { cmd.env_clear(); }
            else if !word.starts_with(b"-") && word.contains(&b'=') {
                let at = word.iter().position(|&b| b == b'=').unwrap();
                let (name, value) = (&word[..at], &word[at+1..]);
                if !code_name(name) { cmd.env(OsStr::from_bytes(name), OsStr::from_bytes(value)); }
            } else { return Err(io::Error::new(io::ErrorKind::InvalidInput, "unread env word in npm ask")); }
            i += 1;
        }
        if let Some(path) = std::env::var_os("PATH") { cmd.env("PATH", path); }
        cmd.args(args.iter().map(|v| OsStr::from_bytes(v)));
        cmd.args(["--logs-max=0", "--update-notifier=false", "--cache"]).arg(self.tmp.join("cache"));
        let child = cmd.spawn()?;
        self.jobs.push(Job { child, out, err, status: None });
        Ok(())
    }
    fn wait(&mut self, until: Instant) -> Result<Vec<Answer>, Outcome> {
        let mut step = 0;
        loop {
            let mut alive = false;
            for j in &mut self.jobs {
                if j.status.is_some() { continue; }
                match j.child.try_wait() {
                    Ok(Some(s)) => j.status = Some(s),
                    Ok(None) => alive = true,
                    Err(error) => return Err(Outcome::StatusFailure(error)),
                }
            }
            if !alive { break; }
            if Instant::now() >= until { return Err(Outcome::Deadline); }
            let delay = [20,50,100,200][step.min(3)];
            std::thread::sleep(Duration::from_millis(delay).min(until.saturating_duration_since(Instant::now())));
            step += 1;
        }
        Ok(self.jobs.iter().map(|j| Answer { status: Outcome::status(j.status.unwrap()), stdout: fs::read(&j.out).unwrap_or_default(), stderr: fs::read(&j.err).unwrap_or_default() }).collect())
    }
}
impl Drop for Group {
    fn drop(&mut self) {
        for j in &mut self.jobs {
            if j.status.is_none() { let _ = j.child.kill(); let _ = j.child.wait(); }
        }
        let _ = fs::remove_dir_all(&self.tmp);
    }
}
fn unknown(why: impl AsRef<str>) -> Value { Value::Obj(vec![(b"unknown".to_vec(), Value::Str(why.as_ref().as_bytes().to_vec()))]) }
pub fn test_registry() -> Option<String> {
    let mut s = std::env::var("SAFEDEPS_NPM_TEST_REGISTRY").ok()?;
    if !s.ends_with('/') { s.push('/'); }
    Regex::new(r"^https?://(127\.0\.0\.1|localhost|\[::1\])(:[0-9]+)?/$", false).ok()?.is_match(s.as_bytes()).then_some(s)
}
pub fn fetch_read(answer: &Answer, what: &str) -> Value {
    if !answer.status.success() { return unknown(format!("npm config failed ({}: {}), so safedeps cannot tell which registry {} fetches from", jq::text(&answer.status.describe(b"npm config",Form::Detail)), answer.error(), what)); }
    let Ok(Value::Obj(values)) = json::parse_one(&answer.stdout) else {
        return unknown(format!("npm config answered with something safedeps could not read, so it cannot tell which registry {} fetches from", what));
    };
    let value = Value::Obj(values);
    let get = |name| value.get(name).and_then(Value::as_str).map(jq::s).unwrap_or(jq::J::Null);
    let Value::Obj(ref fields) = value else { unreachable!() };
    let re = Regex::new("^@[^:/]+:registry$", false).expect("registry pattern");
    let scopes = fields.iter().filter_map(|(k,v)| {
        if re.is_match(k) { Some((jq::text(&k[..k.len()-9]), jq::s(v.as_str()?))) } else { None }
    }).collect();
    jq::into_value(jq::obj(vec![("registry", get("registry")), ("replace", get("replace-registry-host")), ("scopes", jq::J::Obj(scopes)), ("test_registry", test_registry().map(|s| jq::s(&s)).unwrap_or(jq::J::Null))]))
}

pub fn fetch_facts(dir: &Path, until: Instant, env: &[W], args: &[W]) -> Value {
    let Some(npm) = npm_on_path() else { return unknown("npm is not on the PATH this hook runs with, so safedeps cannot ask npm which registry it fetches from"); };
    let Ok(mut group) = Group::new() else { return unknown("safedeps could not make a scratch directory to ask npm which registry it fetches from"); };
    let mut words = vec![b"config".to_vec(), b"ls".to_vec()];
    words.extend_from_slice(args); words.push(b"--json".to_vec());
    if let Err(e) = group.start(&npm, dir, env, &words) { return unknown(jq::text(&Outcome::StartFailure(e).describe(b"npm config",Form::Action))); }
    match group.wait(until) {
        Ok(a) => fetch_read(&a[0], "this install"),
        Err(outcome) => unknown(format!("{}, so safedeps cannot tell which registry this install fetches from",jq::text(&outcome.describe(b"npm",Form::Action)))),
    }
}

/// npm query '*' for post, with the same deadline and safe environment path.
/// The caller owns the lockfile comparison and its closed report vocabulary.
pub fn query(dir: &Path, until: Instant) -> Result<Answer, String> {
    let npm = npm_on_path().ok_or("npm is not on the PATH this hook runs with")?;
    let mut group = Group::new().map_err(|_| "safedeps could not make a scratch directory to ask npm")?;
    let args = vec![b"query".to_vec(), b"*".to_vec(), b"--global=false".to_vec(), b"--location=project".to_vec(), b"--prefix".to_vec(), dir.as_os_str().as_bytes().to_vec()];
    group.start(&npm, dir, &[], &args).map_err(|e| jq::text(&Outcome::StartFailure(e).describe(b"npm query",Form::Action)))?;
    let answers = group.wait(until).map_err(|outcome| jq::text(&outcome.describe(b"npm query",Form::Within(POST_SECONDS))))?;
    let a = answers.into_iter().next().unwrap();
    if !a.status.success() { return Err(format!("npm query failed ({}: {})", jq::text(&a.status.describe(b"npm query",Form::Detail)), a.error())); }
    Ok(a)
}

#[derive(Clone)]
pub struct Target { pub location: W, pub fetch: Value }
fn no_target(why: &str, fetch: Value) -> Target { Target { location: format!("?\t{}", why).into_bytes(), fetch } }
fn last_line(b: &[u8]) -> W {
    let b = b.strip_suffix(b"\n").unwrap_or(b);
    b.rsplit(|&v| v == b'\n').next().unwrap_or_default().iter().copied().filter(|&v| v != 0).collect()
}
/// Only *** is special, and it stands for a nonempty part of one segment.
fn masked_match(mask: &[u8], path: &[u8]) -> bool {
    if mask.starts_with(b"***") {
        for n in 1..=path.iter().position(|&b| b == b'/').unwrap_or(path.len()) {
            if masked_match(&mask[3..], &path[n..]) { return true; }
        }
        false
    } else if mask.is_empty() { path.is_empty() }
    else { path.first() == mask.first() && masked_match(&mask[1..], &path[1..]) }
}
pub fn unmask(mask: &[u8], dir: &Path) -> Option<W> {
    let mut path = fs::canonicalize(dir).ok()?;
    let mut found = None;
    loop {
        if masked_match(mask, path.as_os_str().as_bytes()) {
            if found.is_some() { return None; }
            found = Some(path.as_os_str().as_bytes().to_vec());
        }
        if !path.pop() { break; }
    }
    found
}

pub fn install_target(dir: &Path, until: Instant, env: &[W], args: &[W]) -> Target {
    let mut words = Vec::new(); let mut i = 0;
    while i < args.len() {
        let w = &args[i]; i += 1;
        if matches!(w.as_slice(), b"-w" | b"--workspace") { i = (i+1).min(args.len()); continue; }
        if w.starts_with(b"--workspace=") || (w.starts_with(b"-w") && w.len()>2) || w == b"--include-workspace-root" || w.starts_with(b"--include-workspace-root=") { continue; }
        if matches!(w.as_slice(), b"--workspaces" | b"--workspaces=true") {
            if w == b"--workspaces" && i < args.len() {
                if args[i] == b"false" { words.push(b"--workspaces=false".to_vec()); i+=1; }
                else if args[i] == b"true" { i+=1; }
            }
            continue;
        }
        words.push(w.clone());
    }
    let rx = manager::Regexes::new();
    if !manager::Reader::new(&rx).npm_ask_words_end(&words) {
        return no_target("the install's last option takes the next word as its value, or its words end npm's options, so npm cannot be asked with them without reading the ask's own flags as the install's",
            unknown("the install's last option takes the next word as its value, or its words end npm's options, so npm cannot be asked which registry it fetches from with them"));
    }
    let Some(npm) = npm_on_path() else { return no_target("npm is not on the PATH this hook runs with, so safedeps cannot ask npm where this install lands", unknown("npm is not on the PATH this hook runs with, so safedeps cannot ask npm which registry this install fetches from")); };
    let Ok(mut group) = Group::new() else { return no_target("safedeps could not make a scratch directory to ask npm where this install lands", unknown("safedeps could not make a scratch directory to ask npm which registry this install fetches from")); };
    for (head, tail) in [(vec![b"prefix".to_vec()], vec![b"--global=false".to_vec(), b"--location=project".to_vec()]), (vec![b"root".to_vec()], vec![]), (vec![b"config".to_vec(), b"ls".to_vec()], vec![b"--json".to_vec()])] {
        let mut a = head; a.extend_from_slice(&words); a.extend(tail);
        if let Err(e) = group.start(&npm, dir, env, &a) { let why=jq::text(&Outcome::StartFailure(e).describe(b"npm",Form::Action)); return no_target(&why, unknown(&why)); }
    }
    let a = match group.wait(until) { Ok(a)=>a, Err(outcome)=>{let why=jq::text(&outcome.describe(b"npm",Form::Within(PRE_SECONDS)));return no_target(&why,unknown(&why))} };
    let mut fetch = fetch_read(&a[2], "this install");
    for n in 0..2 {
        if !a[n].status.success() { return no_target(&format!("npm {} failed ({}: {}), so safedeps cannot tell where this install lands", ["prefix", "root"][n], jq::text(&a[n].status.describe(b"npm",Form::Detail)), a[n].error()), fetch); }
    }
    let mut prefix = last_line(&a[0].stdout); let root = last_line(&a[1].stdout);
    if !prefix.starts_with(b"/") || !root.starts_with(b"/") {
        let show = |b: &[u8]| if b.is_empty() { "<empty>".into() } else { jq::text(b) };
        return no_target(&format!("npm did not answer with a path (prefix {}, root {}), so safedeps cannot tell where this install lands", show(&prefix), show(&root)), fetch);
    }
    let masked = prefix.windows(3).any(|w| w == b"***").then(|| prefix.clone());
    if let Some(ref m) = masked { prefix = unmask(m, dir).unwrap_or_default(); }
    let base = masked.as_deref().unwrap_or_else(|| prefix.strip_suffix(b"/").unwrap_or(&prefix));
    let mut local = base.to_vec(); local.extend_from_slice(b"/node_modules");
    if root != local { let mut location = b"global\t".to_vec(); location.extend_from_slice(&prefix); return Target { location, fetch }; }
    if masked.is_some() && prefix.is_empty() { return no_target(&format!("npm masked part of the directory it named ({}), the way it masks anything shaped like a UUID or a token, and no directory from {} up reads the same, so safedeps cannot tell where this install lands", jq::text(masked.as_ref().unwrap()), dir.display()), fetch); }
    if !a[2].status.success() && a[2].stderr.windows(13).any(|w| w == b"ENOWORKSPACES") { fetch = fetch_facts(&os::path(&prefix), until, env, &words); }
    let location = fs::canonicalize(os::path(&prefix)).map(|p| p.into_os_string().into_vec()).unwrap_or(prefix);
    Target { location, fetch }
}

/// Measurement-only entry. Hook callers use the typed functions above; this
/// entry accepts data, never a shell program, and calls the same implementation.
pub fn probe(input: &[u8]) -> i32 {
    let Ok(v) = json::parse_one(input) else { return 5; };
    let get = |k| v.get(k).and_then(Value::as_str).unwrap_or("");
    let words = |k| -> Option<Vec<W>> {
        match v.get(k) {
            None => Some(Vec::new()),
            Some(Value::Arr(a)) => a.iter().map(Value::as_bytes).collect(),
            _ => None,
        }
    };
    let Some(env) = words("env") else { return 2; };
    let Some(args) = words("args") else { return 2; };
    let millis = v.get("milliseconds").and_then(|v| match v { Value::Num(n) => n.parse::<u64>().ok(), _ => None }).unwrap_or(8000).min(10_000);
    let until = Instant::now() + Duration::from_millis(millis);
    let dir = Path::new(get("dir"));
    let result = match get("op") {
        "target" => {
            let answer = install_target(dir, until, &env, &args);
            println!("{}\n{}", jq::text(&answer.location), jq::compact(&jq::from_value(&answer.fetch)));
            return 0;
        }
        "fetch" => fetch_facts(dir, until, &env, &args),
        "query" => match query(dir, until) {
            Ok(answer) => { use std::io::Write; let _ = std::io::stdout().write_all(&answer.stdout); return 0; }
            Err(why) => { println!("{}", why); return 1; }
        },
        "host" => Value::Str(host(get("url")).into_bytes()),
        "public" => Value::Bool(registry_public(v.get("registry"), v.get("facts").unwrap_or(&Value::Null))),
        "origins" => match fetch_origins(v.get("facts").unwrap_or(&Value::Null), get("url")) {
            Ok(origins) => Value::Arr(origins.iter().map(Origin::value).collect()), Err(()) => return 5,
        },
        "problems" | "known-problems" => {
            let facts = v.get("facts").unwrap_or(&Value::Null);
            let answer = if get("op") == "problems" { fetch_problems(facts,get("url")) } else { fetch_known_problems(facts,get("url")) };
            match answer { Ok(problems) => Value::Arr(problems.into_iter().map(|s| Value::Str(s.into_bytes())).collect()), Err(()) => return 5 }
        }
        _ => return 2,
    };
    println!("{}", jq::compact(&jq::from_value(&result))); 0
}

#[cfg(test)]
mod outcome_tests {
    use super::*;
    #[test]
    fn wait_failure_is_not_a_deadline() {
        let mut group=Group::new().unwrap();
        group.start(Path::new("/bin/sh"),Path::new("/"),&[],&[b"-c".to_vec(),b"exit 0".to_vec()]).unwrap();
        // Reap this test's own child through an independent interface. The
        // next real try_wait gets ECHILD; no product fault selector is used.
        extern "C" { fn waitpid(pid:i32,status:*mut i32,options:i32)->i32; }
        let pid=group.jobs[0].child.id() as i32;let mut status=0;
        assert_eq!(unsafe{waitpid(pid,&mut status,0)},pid);
        let result=group.wait(Instant::now()+Duration::from_secs(2));
        // Ownership was deliberately removed above; never signal that pid.
        group.jobs.clear();
        let Err(Outcome::StatusFailure(error))=result else {panic!("wait I/O error must stay distinct")};
        assert_eq!(error.raw_os_error(),Some(10));
        assert_eq!(Outcome::StatusFailure(error).describe(b"npm",Form::Within(8)),b"could not read npm process status: OS error 10");

        let mut group=Group::new().unwrap();
        group.start(Path::new("/bin/sh"),Path::new("/"),&[],&[b"-c".to_vec(),b"while :; do :; done".to_vec()]).unwrap();
        assert!(matches!(group.wait(Instant::now()),Err(Outcome::Deadline)));
        let error=group.start(&group.tmp.join("missing"),Path::new("/"),&[],&[]).unwrap_err();
        assert_eq!(error.raw_os_error(),Some(2));
        assert_eq!(Outcome::StartFailure(error).describe(b"npm",Form::Action),b"could not start npm: OS error 2");
    }
}
