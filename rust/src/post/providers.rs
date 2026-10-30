//! OSV batch lookup and the KEV overlay. Requests use curl; provider init
//! delegates log retention to state. Cache and JSON reads stay in process.
use super::{jv,sh,closure::Spec,report::cat};
use crate::{json::Value,state,os,sha256,ere::Regex};
use std::{fs,path::{Path,PathBuf},process::{Command,Stdio},os::unix::fs::MetadataExt};
type W=Vec<u8>;
const CACHE_ENV: &str = "SAFEDEPS_CACHE_DIR";
const CACHE_DIR: &str = "cache";
const CACHE_TTL_ENV: &str = "SAFEDEPS_PROVIDER_CACHE_TTL_SECONDS";
const CACHE_TTL: i64 = 86400;
const CACHE_NAMESPACES: [&str; 3] = ["osv", "kev", "ghsa"];
const KEV_CACHE_PATH: &str = "kev/known_exploited_vulnerabilities.json";
fn osv_cache_path(cache: &Path, package: &[u8], version: &[u8]) -> PathBuf {
    let key = sha256::hex(&cat(&[b"osv\nnpm\n", package, b"\n", version]));
    cache.join("osv").join(format!("{}.json", key))
}
fn env(name:&str,default:&str)->String{std::env::var(name).ok().filter(|s|!s.is_empty()).unwrap_or_else(||default.into())}
fn fresh(p:&Path,ttl:i64)->bool{fs::metadata(p).is_ok_and(|m|m.is_file()&&os::wall(os::WallRole::ProviderCacheExpiry).seconds()-m.mtime()<=ttl)}
/// An OSV answer is one JSON object whose `vulns`, when it has one, is a list.
/// OSV answers `{}` for a package it has nothing on, and nothing else says so:
/// an empty file, a file this user cannot read and a `null` hold no answer, and
/// none of them reads as no advisories. The CLI reads an answer by the same rule
/// (safedeps_osv_is_answer), and `osv_answers_match_cli` holds the two together.
fn osv_answer(v:Value)->Option<Value>{(matches!(v,Value::Obj(_))&&matches!(jv::field(&v,"vulns"),Ok(Value::Arr(_)|Value::Null))).then_some(v)}
/// A KEV catalog is one JSON object whose `vulnerabilities` is a list with at
/// least one entry, and every entry is an object that names its CVE in a string
/// `cveID`. CISA's catalog is cumulative, so it is never empty: an empty file, a
/// file this user cannot read, an empty list and a list whose entries name
/// nothing say nothing about what is exploited, and none of them reads as no
/// listing. The CLI reads a catalog by the same rule (safedeps_kev_is_answer),
/// and `kev_answers_match_cli` holds the two together.
fn kev_answer(v:Value)->Option<Value>{matches!(jv::field(&v,"vulnerabilities"),Ok(Value::Arr(a)) if !a.is_empty()&&a.iter().all(|e|matches!(jv::field(e,"cveID"),Ok(Value::Str(_))))).then_some(v)}
fn tsv(s:&[u8])->W{let mut out=Vec::new();for b in s{match b{b'\\'=>out.extend(b"\\\\"),b'\t'=>out.extend(b"\\t"),b'\r'=>out.extend(b"\\r"),b'\n'=>out.extend(b"\\n"),_=>out.push(*b)}}out}
/// The advisory status one provider answer gives one package. The CLI
/// declares the same names and the same rule in lib/providers/providers.sh,
/// and `provider_statuses_match_cli` holds the two together.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Status { HardBlock, Vulnerable, Clean }
impl Status {
    /// A KEV listing outranks any number of OSV records.
    fn of(exploited: bool, records: usize) -> Self {
        if exploited { Self::HardBlock } else if records > 0 { Self::Vulnerable } else { Self::Clean }
    }
}
/// Which provider a batch could not read. Either one is a rollback; the report
/// names the one that failed.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Unanswered { Osv, Kev }
struct Scratch(PathBuf);
impl Drop for Scratch{fn drop(&mut self){sh::rm_rf(&self.0);}}

/// `kev_reads` counts the parses of the KEV catalog: one `batch` reads the
/// catalog at most once, whatever the number of packages. Read per package,
/// the whole catalog was parsed again for every package of the closure.
pub struct Providers{home:PathBuf,cache:PathBuf,ttl:i64,announced:bool,kev_reads:usize}
impl Providers{
    pub fn new(home:&Path)->Self{
        let cache=std::env::var_os(CACHE_ENV).filter(|p|!p.is_empty()).map(PathBuf::from).unwrap_or_else(||home.join(CACHE_DIR));
        Self{home:home.into(),cache,ttl:env(CACHE_TTL_ENV,&CACHE_TTL.to_string()).parse().unwrap_or(CACHE_TTL),announced:false,kev_reads:0}
    }
    fn init(&self){for sub in CACHE_NAMESPACES{sh::mkdir_p(&self.cache.join(sub));}sh::mkdir_p(&self.home);state::advisory_rotate_once(&self.home.join("advisory.log"));}
    fn raw_log(&self,level:&[u8],line:&[u8]){sh::append(&self.home.join("advisory.log"),&cat(&[b"[",os::utc_stamp(os::wall(os::WallRole::ProviderHeader).seconds()).as_bytes(),b"] ",level,b" ",line,b"\n"]));}
    fn log(&mut self,level:&[u8],line:&[u8]){
        self.init();
        if !self.announced{
            self.announced=true;let moved=state::truth_sources_moved();
            if !moved.is_empty(){self.raw_log(b"WARN",&cat(&[b"advisory truth source moved: ",&moved," — this run did not answer from the canonical sources.".as_bytes()]));}
            let ignored=env("SAFEDEPS_ADVISORY_LOG_ENV_IGNORED",&env("SAFEDEPS_ADVISORY_LOG",""));
            if !ignored.is_empty(){self.raw_log(b"WARN",&cat(&[b"SAFEDEPS_ADVISORY_LOG=",ignored.as_bytes()," ignored — the record and the ledger it vouches for stay in one place (move SAFEDEPS_HOME instead).".as_bytes()]));}
        }self.raw_log(level,line);
    }
    fn curl(url:&str,response:&Path,payload:Option<&Path>,seconds:&str)->W{
        let mut c=Command::new("curl");c.args(["-fsS","--max-time",seconds]);
        if payload.is_some(){c.args(["-H","Content-Type: application/json"]);}
        c.arg("-o").arg(response).args(["-w","%{http_code}"]);
        if let Some(p)=payload{let mut data=b"@".to_vec();data.extend(sh::bytes(p));c.arg("-d").arg(sh::p(&data));}
        c.arg(url).stdin(Stdio::null()).stderr(Stdio::null());
        c.output().map(|o|jv::captured(&[o.stdout])).unwrap_or_default()
    }
    fn catalog(&mut self,path:&Path)->Option<Value>{self.kev_reads+=1;jv::read_one_object(path).and_then(kev_answer)}
    /// A catalog that can be read. A fresh file that holds none is a miss with a
    /// line in the record. A download that fails falls back on the local file,
    /// stale or not, when that file holds a catalog. With none to read this is
    /// None, and no caller reads that as no listing.
    fn kev(&mut self)->Option<Value>{
        let cache=self.cache.join(KEV_CACHE_PATH);
        if fresh(&cache,self.ttl){
            let held=self.catalog(&cache);
            if held.is_some(){return held}
            self.log(b"WARN",b"CISA KEV cache unreadable; asking again");
        }
        let mut status=Vec::new();
        if sh::command_exists("curl"){
            let Some(tmp)=sh::mktemp(&cat(&[sh::bytes(&self.cache),b"/kev/.known_exploited_vulnerabilities.json."]))else{return None};
            status=Self::curl(&env("SAFEDEPS_KEV_CATALOG_URL",state::DEFAULT_KEV_CATALOG_URL),&tmp,None,"15");
            let answer=jv::read_one_object(&tmp).and_then(kev_answer);
            if status==b"200"&&answer.is_some(){
                if fs::rename(&tmp,&cache).is_err(){sh::rm_f(&tmp);return None}
                self.log(b"INFO",b"CISA KEV catalog refresh ok");
                // The bytes just checked are the catalog now in place: they
                // are the one read, not a second parse of the same file.
                self.kev_reads+=1;
                return answer;
            }
            sh::rm_f(&tmp);
        }else{eprintln!("safedeps providers: curl is required for provider queries");}
        let status=if status.is_empty(){b"none".as_slice()}else{&status};
        let held=self.catalog(&cache);
        if held.is_some(){self.log(b"WARN",&cat(&[b"CISA KEV refresh failed; using stale local catalog status=",status]));}
        else{self.log(b"WARN",&cat(&[b"CISA KEV unavailable and no readable local catalog status=",status]));}
        held
    }
    /// Status per package, with the ids of the OSV records it has; post uses
    /// the hard_block and vulnerable summaries, and the ids name what an
    /// install kept under SAFEDEPS_ACCEPT_RISK accepted.
    pub fn batch(&mut self,specs:&[Spec])->Result<Vec<(W,W,Status,Vec<W>)>,Unanswered>{
        let items=self.osv_answers(specs).map_err(|()|Unanswered::Osv)?;
        if items.is_empty(){return Ok(Vec::new())}
        // Asked once for the closure: a refresh, its log line and the parse
        // happen once.
        let Some(catalog)=self.kev()else{self.log(b"ERROR",b"CISA KEV catalog unavailable; fail-closed");return Err(Unanswered::Kev)};
        let Ok(Value::Arr(listed))=jv::field(&catalog,"vulnerabilities")else{return Err(Unanswered::Kev)};
        let cve=Regex::new("^CVE-[0-9]{4}-[0-9]+$",false).unwrap();let mut output=Vec::new();
        for (package,version,osv) in items{
            let vulns=match jv::field(&osv,"vulns"){Ok(Value::Arr(a))=>a.as_slice(),_=>&[]};
            let mut cves=Vec::new();let mut ids=Vec::new();
            for v in vulns{
                if let Ok(Value::Str(s))=jv::field(v,"id"){ids.push(s.clone());if cve.is_match(s){cves.push(s.clone());}}
                if let Ok(Value::Arr(a))=jv::field(v,"aliases"){for x in a{if let Value::Str(s)=x{if cve.is_match(s){cves.push(s.clone());}}}}
            }
            let exploited=listed.iter().any(|v|matches!(jv::field(v,"cveID"),Ok(Value::Str(s)) if cves.contains(s)));
            output.push((package,version,Status::of(exploited,vulns.len()),ids));
        }Ok(output)
    }
    /// The OSV answer of each package, from the cache or from one batch query.
    fn osv_answers(&mut self,specs:&[Spec])->Result<Vec<(W,W,Value)>,()>{
        self.init();let temp=sh::mktemp_dir(&sh::tmp_prefix("safedeps-providers")).ok_or(())?;let scratch=Scratch(temp);
        let mut items:Vec<(W,W,PathBuf,Option<Value>)>=Vec::new();
        for spec in specs{
            let package=match &spec.package{Value::Str(s)=>tsv(s),Value::Null=>Vec::new(),_=>return Err(())};let version=tsv(&spec.version);
            if package.is_empty()||version.is_empty(){continue}
            let path=osv_cache_path(&self.cache,&package,&version);
            // A fresh file that holds no answer is a miss with a line in the
            // record: the query is asked again and its answer replaces the file.
            let value=if fresh(&path,self.ttl){
                let cached=jv::read_one_object(&path).and_then(osv_answer);
                if cached.is_some(){self.log(b"INFO",&cat(&[b"OSV batch cache hit ecosystem=npm package=",&package,b" version=",&version]));}
                else{self.log(b"WARN",&cat(&[b"OSV cache unreadable; asking again ecosystem=npm package=",&package,b" version=",&version]));}
                cached
            }else{None};items.push((package,version,path,value));
        }
        let missing:Vec<_>=items.iter().enumerate().filter(|(_,i)|i.3.is_none()).map(|(n,_)|n).collect();
        if !missing.is_empty(){
            if !sh::command_exists("curl"){
                eprintln!("safedeps providers: curl is required for provider queries");self.log(b"ERROR",b"OSV batch unavailable; cache miss ecosystem=npm");return Err(());
            }
            let queries=Value::Arr(missing.iter().map(|i|{let (p,v,_,_)=&items[*i];jv::obj(vec![("version",jv::s(v)),("package",jv::obj(vec![("name",jv::s(p)),("ecosystem",jv::s(b"npm"))]))])}).collect());
            let payload=scratch.0.join("payload.json");let response=scratch.0.join("response.json");
            fs::write(&payload,cat(&[&jv::dump(&jv::obj(vec![("queries",queries)])),b"\n"])).map_err(|_|())?;
            let status=Self::curl(&env("SAFEDEPS_OSV_BATCH_API_URL",state::DEFAULT_OSV_BATCH_API_URL),&response,Some(&payload),"20");
            let st=jv::read_file(&response);
            if status!=b"200"||!st.as_ref().is_some_and(|s|!s.failed&&s.values.last().is_some_and(|v|matches!(jv::field(v,"results"),Ok(Value::Arr(_))))){
                self.log(b"ERROR",&cat(&[b"OSV batch query failed status=",if status.is_empty(){b"none"}else{&status}]));return Err(());
            }
            let st=st.unwrap();if st.values.len()!=1{return Err(())}
            let Value::Arr(results)=jv::field(&st.values[0],"results")?else{return Err(())};
            if results.len()!=missing.len(){self.log(b"ERROR",&cat(&[b"OSV batch result count mismatch misses=",missing.len().to_string().as_bytes(),b" results=",results.len().to_string().as_bytes()]));return Err(())}
            for (n,(i,r)) in missing.iter().zip(results).enumerate(){
                let Some(v)=osv_answer(r.clone())else{self.log(b"ERROR",&cat(&[b"OSV batch result is not an answer ecosystem=npm index=",n.to_string().as_bytes()]));return Err(())};
                let (package,version,path,stored)=&mut items[*i];state::write_state_file(path,&jv::dump(&v)).map_err(|_|())?;
                self.log(b"INFO",&cat(&[b"OSV batch live query ok ecosystem=npm package=",package,b" version=",version]));*stored=Some(v);
            }
        }
        items.into_iter().map(|(package,version,_,value)|value.map(|osv|(package,version,osv)).ok_or(())).collect()
    }
}

#[cfg(test)]
#[test]
fn provider_endpoints_match_cli() {
    let truth = include_str!("../../../lib/truth-sources.sh");
    let cli = include_str!("../../../lib/providers/providers.sh");
    for (name, value) in [("OSV_BATCH_API_URL", state::DEFAULT_OSV_BATCH_API_URL),
                          ("KEV_CATALOG_URL", state::DEFAULT_KEV_CATALOG_URL)] {
        let default = format!("SAFEDEPS_DEFAULT_{name}=\"{value}\"");
        assert!(truth.lines().any(|line| line == default), "CLI default {name}");
        let assignment = format!("SAFEDEPS_{name}=\"${{SAFEDEPS_{name}:-${{SAFEDEPS_DEFAULT_{name}}}}}\"");
        assert!(cli.lines().any(|line| line == assignment), "CLI request default {name}");
        assert!(cli.contains(&format!("\"${{SAFEDEPS_{name}}}\" 2>/dev/null")), "CLI request uses {name}");
    }
}

#[cfg(test)]
#[test]
fn provider_statuses_match_cli() {
    let cli = include_str!("../../../lib/providers/providers.sh");
    let named = [(Status::HardBlock, "HARD_BLOCK", "hard_block"), (Status::Vulnerable, "VULNERABLE", "vulnerable"), (Status::Clean, "CLEAN", "clean")];
    let name = |status: Status| named.iter().find(|(s, _, _)| *s == status).unwrap().2;
    for (_, constant, value) in named {
        assert!(cli.lines().any(|line| line == format!("SAFEDEPS_STATUS_{constant}=\"{value}\"")), "CLI declares status {value}");
    }
    // Every status the CLI writes is one of its declarations; a status a
    // writer spells out again is a second truth the compiler never sees. A
    // status word stands in the CLI files (cli_text::CLI_FILES) only in its
    // declaration, in the check result declaration SAFEDEPS_CHECK_CLEAN (a
    // word of its own) and as prose: anywhere else it is a spelling, whatever
    // its form. Each declared name stands only in its declaration and as a
    // whole read, so no assignment of any form follows it: one after
    // SAFEDEPS_STATUS_JQ would part the shell's names from jq's. Each jq
    // function the declaration defines is defined there and nowhere else.
    use crate::cli_text::{bare_uses, code_lines, definitions, word, CLI_FILES};
    let declarations: Vec<&str> = cli.lines().filter(|line| line.starts_with("SAFEDEPS_STATUS_")).collect();
    for line in &declarations {
        let name = line.split_once('=').unwrap().0;
        let uses: Vec<&str> = CLI_FILES.iter().flat_map(|(_, text)| bare_uses(text, name)).collect();
        assert_eq!(uses, [*line], "{name} stands only in its declaration and as a whole read");
    }
    let jq_line = declarations.iter().find(|line| line.starts_with("SAFEDEPS_STATUS_JQ=")).unwrap();
    for def in jq_line.split("def ").skip(1).map(|rest| rest.split(|c: char| !(c.is_ascii_alphanumeric() || c == '_')).next().unwrap()) {
        let defined: Vec<&str> = CLI_FILES.iter().flat_map(|(_, text)| definitions(text, def)).collect();
        assert_eq!(defined, [*jq_line], "jq's {def} is defined once, in SAFEDEPS_STATUS_JQ");
    }
    for line in declarations.iter().filter(|line| !line.starts_with("SAFEDEPS_STATUS_JQ=")) {
        let value = line.split_once('=').unwrap().1;
        assert!(value.len() > 2 && value.starts_with('"') && value.ends_with('"') && !value.contains('$'), "a status is a plain literal: {line}");
        let status = value.trim_matches('"');
        for (file, text) in CLI_FILES {
            let spelled: Vec<&str> = code_lines(text, status, word).into_iter()
                .filter(|other| !declarations.contains(other) && !(file == "bin/safedeps" && *other == "SAFEDEPS_CHECK_CLEAN=\"clean\"")).collect();
            assert!(spelled.is_empty(), "{file} spells status {value} outside its declaration: {spelled:?}");
        }
    }
    // The jq reading of the same declarations gives the rule the core gives.
    let script = format!("{}\njq -nc \"$SAFEDEPS_STATUS_JQ\"'[status_of(true; []), status_of(true; [1]), status_of(false; [1]), status_of(false; [])]'", declarations.join("\n"));
    let out = std::process::Command::new("/bin/bash").env_clear().env("PATH", std::env::var_os("PATH").unwrap_or_default())
        .args(["-c", &script, "status-contract"]).output().unwrap();
    assert!(out.status.success(), "CLI status rule: {}", String::from_utf8_lossy(&out.stderr));
    let core: Vec<String> = [(true, 0), (true, 1), (false, 1), (false, 0)].iter().map(|(e, n)| format!("\"{}\"", name(Status::of(*e, *n)))).collect();
    assert_eq!(String::from_utf8(out.stdout).unwrap(), format!("[{}]\n", core.join(",")));
    // A reader takes the core's three statuses and no other word.
    let script = format!("{}\njq -nc \"$SAFEDEPS_STATUS_JQ\"'[(\"{}\", \"{}\", \"{}\", \"blocked\", \"\", \"CLEAN\", \"clean \", null, 1) | status_known]'",
        declarations.join("\n"), name(Status::HardBlock), name(Status::Vulnerable), name(Status::Clean));
    let out = std::process::Command::new("/bin/bash").env_clear().env("PATH", std::env::var_os("PATH").unwrap_or_default())
        .args(["-c", &script, "status-contract"]).output().unwrap();
    assert!(out.status.success(), "CLI status list: {}", String::from_utf8_lossy(&out.stderr));
    assert_eq!(String::from_utf8(out.stdout).unwrap(), "[true,true,true,false,false,false,false,false,false]\n", "status_known is the core's statuses");
}

#[cfg(test)]
#[test]
fn osv_answers_match_cli() {
    let cli = include_str!("../../../lib/providers/providers.sh");
    let head = "safedeps_osv_is_answer() {";
    let body = cli.split_once(head).unwrap().1.split_once("\n}").unwrap().0;
    let script = format!("{head}{body}\n}}\nsafedeps_osv_is_answer \"$1\"");
    let dir = std::env::temp_dir().join(format!("safedeps-osv-answer-{}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    let file = dir.join("answer.json");
    let answers = ["{}", "  {}\n", r#"{"vulns":[]}"#, r#"{"vulns":null}"#, r#"{"vulns":[{"id":"X"}]}"#,
        r#"{"vulns":[1],"next_page_token":"t"}"#, r#"{"vulns":false,"vulns":[]}"#];
    let none = ["", " ", "\n", "null", "false", "true", "[]", "[{}]", "1", r#""x""#, "not json", "{", "{}{}", "{} {}",
        "null {}", "{} null", "{} not json", r#"{"vulns":false}"#, r#"{"vulns":true}"#, r#"{"vulns":""}"#, r#"{"vulns":"x"}"#,
        r#"{"vulns":{}}"#, r#"{"vulns":{"a":1}}"#, r#"{"vulns":1}"#, r#"{"vulns":[],"vulns":false}"#];
    for (bodies, answer) in [(answers.as_slice(), true), (none.as_slice(), false)] {
        for body in bodies {
            fs::write(&file, body).unwrap();
            assert_eq!(jv::read_one_object(&file).and_then(osv_answer).is_some(), answer, "the core on {body:?}");
            let cli = Command::new("/bin/bash").env_clear().env("PATH", std::env::var_os("PATH").unwrap_or_default())
                .args(["-c", &script, "answer-contract"]).arg(&file).status().unwrap();
            assert_eq!(cli.success(), answer, "the CLI on {body:?}");
        }
    }
    let _ = fs::remove_dir_all(&dir);
}

#[cfg(test)]
#[test]
fn kev_answers_match_cli() {
    let cli = include_str!("../../../lib/providers/providers.sh");
    let head = "safedeps_kev_is_answer() {";
    let body = cli.split_once(head).unwrap().1.split_once("\n}").unwrap().0;
    let script = format!("{head}{body}\n}}\nsafedeps_kev_is_answer \"$1\"");
    let dir = std::env::temp_dir().join(format!("safedeps-kev-answer-{}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    let file = dir.join("catalog.json");
    let one = r#"{"vulnerabilities":[{"cveID":"CVE-2026-1"}]}"#;
    let answers = [one.to_string(), format!("  {one}\n\n"),
        r#"{"title":"t","count":2,"vulnerabilities":[{"cveID":"CVE-2026-1","notes":""},{"cveID":"CVE-2026-2","cwes":[]}]}"#.to_string(),
        r#"{"vulnerabilities":false,"vulnerabilities":[{"cveID":"CVE-2026-1"}]}"#.to_string(),
        r#"{"vulnerabilities":[{"cveID":1,"cveID":"CVE-2026-1"}]}"#.to_string()];
    let none = ["", " ", "\n", "null", "false", "true", "[]", "[{}]", "1", r#""x""#, "not json", "{", "{}", "{}{}", "{} {}", "null {}",
        r#"{"vulnerabilities":null}"#, r#"{"vulnerabilities":false}"#, r#"{"vulnerabilities":true}"#, r#"{"vulnerabilities":""}"#,
        r#"{"vulnerabilities":"x"}"#, r#"{"vulnerabilities":1}"#, r#"{"vulnerabilities":{}}"#, r#"{"vulnerabilities":{"a":{"cveID":"CVE-2026-1"}}}"#,
        r#"{"vulnerabilities":[]}"#, r#"{"vulnerabilities":[1]}"#, r#"{"vulnerabilities":[null]}"#, r#"{"vulnerabilities":[""]}"#, r#"{"vulnerabilities":[[]]}"#,
        r#"{"vulnerabilities":[{}]}"#, r#"{"vulnerabilities":[{"cveID":null}]}"#, r#"{"vulnerabilities":[{"cveID":1}]}"#, r#"{"vulnerabilities":[{"cveID":[]}]}"#,
        r#"{"vulnerabilities":[{"cve_id":"CVE-2026-1"}]}"#, r#"{"VULNERABILITIES":[{"cveID":"CVE-2026-1"}]}"#,
        r#"{"vulnerabilities":[{"cveID":"CVE-2026-1"},{}]}"#, r#"{"vulnerabilities":[{"cveID":"CVE-2026-1"},1]}"#, r#"{"vulnerabilities":[{"cveID":"CVE-2026-1"},{"cveID":1}]}"#,
        r#"{"vulnerabilities":[{"cveID":"CVE-2026-1"}],"vulnerabilities":false}"#, r#"{"vulnerabilities":[{"cveID":"CVE-2026-1"}"#,
        r#"{"vulnerabilities":[{"cveID":"CVE-2026-1"}]} null"#, r#"{"vulnerabilities":[{"cveID":"CVE-2026-1"}]} {}"#, r#"{"vulnerabilities":[{"cveID":"CVE-2026-1"}]} not json"#];
    let answers: Vec<&str> = answers.iter().map(String::as_str).collect();
    for (bodies, answer) in [(answers.as_slice(), true), (none.as_slice(), false)] {
        for body in bodies {
            fs::write(&file, body).unwrap();
            assert_eq!(jv::read_one_object(&file).and_then(kev_answer).is_some(), answer, "the core on {body:?}");
            let cli = Command::new("/bin/bash").env_clear().env("PATH", std::env::var_os("PATH").unwrap_or_default())
                .args(["-c", &script, "answer-contract"]).arg(&file).status().unwrap();
            assert_eq!(cli.success(), answer, "the CLI on {body:?}");
        }
    }
    let _ = fs::remove_dir_all(&dir);
}

#[cfg(test)]
#[test]
fn provider_cache_constants_match_cli() {
    let cli = include_str!("../../../lib/providers/providers.sh");
    for (name, default) in [(CACHE_ENV, format!("${{SAFEDEPS_HOME}}/{CACHE_DIR}")),
                            (CACHE_TTL_ENV, CACHE_TTL.to_string())] {
        assert!(cli.lines().any(|line| line == format!("{name}=\"${{{name}:-{default}}}\"")), "CLI cache default {name}");
    }
    for namespace in CACHE_NAMESPACES {
        assert!(cli.contains(&format!("\"${{SAFEDEPS_CACHE_DIR}}/{namespace}\"")), "CLI namespace {namespace}");
    }
    assert!(cli.contains(&format!("printf '%s/{KEV_CACHE_PATH}' \"${{SAFEDEPS_CACHE_DIR}}\"")), "CLI KEV filename");
    assert!(cli.contains("\"${SAFEDEPS_CACHE_DIR}/osv/${cache_key}.json\""), "CLI OSV filename");
    let function = |name: &str| -> String {
        let head = format!("{name}() {{");
        let body = cli.split_once(&head).unwrap().1.split_once("\n}").unwrap().0;
        format!("{head}{body}\n}}\n")
    };
    let script = format!("{}{}safedeps_cache_key osv npm \"$1\" \"$2\"", function("safedeps_hash_text"), function("safedeps_cache_key"));
    for (package, version) in [("@scope/pkg", "1.2.3"), ("Case sensitive", "v1+meta"), ("line\nnext", "tab\tvalue")] {
        let out = std::process::Command::new("/bin/bash").env_clear().env("PATH", "/usr/bin:/bin")
            .args(["-c", &script, "cache-contract", package, version]).output().unwrap();
        assert!(out.status.success(), "CLI cache hash: {}", String::from_utf8_lossy(&out.stderr));
        let key = String::from_utf8(out.stdout).unwrap();
        assert_eq!(osv_cache_path(Path::new("cache root"), package.as_bytes(), version.as_bytes()),
            Path::new("cache root/osv").join(format!("{}.json", key.trim_end_matches('\n'))));
    }
}

#[cfg(test)]
mod catalog_tests {
    use super::*;

    struct Fixture { root: PathBuf, providers: Providers }
    impl Drop for Fixture { fn drop(&mut self) { let _ = fs::remove_dir_all(&self.root); } }
    /// A home whose OSV answers and KEV catalog are all in the cache and fresh,
    /// so a batch starts no curl.
    fn fixture(name: &str, osv: &[(&str, &str)], kev: &[&str]) -> Fixture {
        let root = std::env::temp_dir().join(format!("safedeps-kev-{}-{}", name, std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let cache = root.join("cache");
        for sub in CACHE_NAMESPACES { fs::create_dir_all(cache.join(sub)).unwrap(); }
        for (spec, body) in osv {
            let (package, version) = spec.split_once('@').unwrap();
            fs::write(osv_cache_path(&cache, package.as_bytes(), version.as_bytes()), body).unwrap();
        }
        let entries: Vec<String> = kev.iter().map(|id| format!("{{\"cveID\":\"{}\"}}", id)).collect();
        fs::write(cache.join(KEV_CACHE_PATH), format!("{{\"vulnerabilities\":[{}]}}", entries.join(","))).unwrap();
        let providers = Providers { home: root.join("home"), cache, ttl: CACHE_TTL, announced: false, kev_reads: 0 };
        Fixture { root, providers }
    }
    fn specs(names: &[String]) -> Vec<Spec> {
        names.iter().map(|spec| {
            let (package, version) = spec.split_once('@').unwrap();
            Spec { package: Value::Str(package.as_bytes().to_vec()), version: version.as_bytes().to_vec() }
        }).collect()
    }

    #[test]
    fn one_batch_reads_the_kev_catalog_once() {
        let names: Vec<String> = (0..60).map(|n| format!("fixture-{}@1.0.{}", n, n)).collect();
        let osv: Vec<(&str, &str)> = names.iter().map(|n| (n.as_str(), "{}")).collect();
        let mut f = fixture("once", &osv, &["CVE-2026-9999"]);
        let out = f.providers.batch(&specs(&names)).unwrap();
        assert_eq!(out.len(), 60);
        assert_eq!(f.providers.kev_reads, 1, "the KEV catalog is read once for 60 packages");
        let mut empty = fixture("none", &[], &["CVE-2026-9999"]);
        empty.providers.batch(&[]).unwrap();
        assert_eq!(empty.providers.kev_reads, 0, "a batch with no package does not read the catalog");
    }

    /// One package of each state. Holds without the read counter, so it reads
    /// the same against the per-package reading this replaced.
    #[test]
    fn batch_states_are_hard_block_vulnerable_and_clean() {
        let osv = [
            ("fixture-kev@1.0.0", r#"{"vulns":[{"id":"GHSA-xxxx","aliases":["CVE-2026-0001"]}]}"#),
            ("fixture-vuln@1.0.0", r#"{"vulns":[{"id":"CVE-2026-0002"}]}"#),
            ("fixture-clean@1.0.0", "{}"),
        ];
        let names: Vec<String> = osv.iter().map(|(n, _)| n.to_string()).collect();
        let mut f = fixture("states", &osv, &["CVE-2026-0001"]);
        let out = f.providers.batch(&specs(&names)).unwrap();
        let states: Vec<(String, Status)> = out.iter().map(|(p, v, s, _)| (format!("{}@{}", String::from_utf8_lossy(p), String::from_utf8_lossy(v)), *s)).collect();
        assert_eq!(states, vec![
            ("fixture-kev@1.0.0".to_string(), Status::HardBlock),
            ("fixture-vuln@1.0.0".to_string(), Status::Vulnerable),
            ("fixture-clean@1.0.0".to_string(), Status::Clean),
        ]);
        let ids: Vec<Vec<W>> = out.iter().map(|(_, _, _, ids)| ids.clone()).collect();
        assert_eq!(ids, vec![vec![b"GHSA-xxxx".to_vec()], vec![b"CVE-2026-0002".to_vec()], vec![]], "each package keeps the ids of its OSV records");
    }
}
