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
fn obj0(path:&Path)->Result<Value,()>{let s=jv::read_file(path).ok_or(())?;if s.failed{return Err(())}Ok(s.values.into_iter().next().filter(jv::truthy).unwrap_or_else(||jv::obj(vec![("vulns",Value::Arr(Vec::new()))])))}
fn tsv(s:&[u8])->W{let mut out=Vec::new();for b in s{match b{b'\\'=>out.extend(b"\\\\"),b'\t'=>out.extend(b"\\t"),b'\r'=>out.extend(b"\\r"),b'\n'=>out.extend(b"\\n"),_=>out.push(*b)}}out}
struct Scratch(PathBuf);
impl Drop for Scratch{fn drop(&mut self){sh::rm_rf(&self.0);}}

pub struct Providers{home:PathBuf,cache:PathBuf,ttl:i64,announced:bool}
impl Providers{
    pub fn new(home:&Path)->Self{
        let cache=std::env::var_os(CACHE_ENV).filter(|p|!p.is_empty()).map(PathBuf::from).unwrap_or_else(||home.join(CACHE_DIR));
        Self{home:home.into(),cache,ttl:env(CACHE_TTL_ENV,&CACHE_TTL.to_string()).parse().unwrap_or(CACHE_TTL),announced:false}
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
    fn kev(&mut self)->Option<Value>{
        let cache=self.cache.join(KEV_CACHE_PATH);
        if !fresh(&cache,self.ttl){
            if !sh::command_exists("curl"){
                eprintln!("safedeps providers: curl is required for provider queries");
                return if sh::is_file(&cache){obj0(&cache).ok()}else{None};
            }
            let Some(tmp)=sh::mktemp(&cat(&[sh::bytes(&self.cache),b"/kev/.known_exploited_vulnerabilities.json."]))else{return None};
            let status=Self::curl(&env("SAFEDEPS_KEV_CATALOG_URL",state::DEFAULT_KEV_CATALOG_URL),&tmp,None,"15");
            let st=jv::read_file(&tmp);
            let valid=st.as_ref().is_some_and(|s|!s.failed&&s.values.last().is_some_and(|v|matches!(jv::field(v,"vulnerabilities"),Ok(Value::Arr(_)))));
            if status==b"200"&&valid{
                if fs::rename(&tmp,&cache).is_err(){sh::rm_f(&tmp);return None}
                self.log(b"INFO",b"CISA KEV catalog refresh ok");
            }else{
                sh::rm_f(&tmp);let status=if status.is_empty(){b"none".as_slice()}else{&status};
                if sh::is_file(&cache){self.log(b"WARN",&cat(&[b"CISA KEV refresh failed; using stale local catalog status=",status]));}
                else{self.log(b"WARN",&cat(&[b"CISA KEV unavailable and no local catalog status=",status]));return None}
            }
        }obj0(&cache).ok()
    }
    /// Status per package; post uses only hard_block and vulnerable summaries.
    pub fn batch(&mut self,specs:&[Spec])->Result<Vec<(W,W,&'static str)>,()>{
        self.init();let temp=sh::mktemp_dir(&sh::tmp_prefix("safedeps-providers")).ok_or(())?;let scratch=Scratch(temp);
        let mut items:Vec<(W,W,PathBuf,Option<Value>)>=Vec::new();
        for spec in specs{
            let package=match &spec.package{Value::Str(s)=>tsv(s),Value::Null=>Vec::new(),_=>return Err(())};let version=tsv(&spec.version);
            if package.is_empty()||version.is_empty(){continue}
            let path=osv_cache_path(&self.cache,&package,&version);
            let value=if fresh(&path,self.ttl){
                self.log(b"INFO",&cat(&[b"OSV batch cache hit ecosystem=npm package=",&package,b" version=",&version]));Some(obj0(&path)?)
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
            for (i,r) in missing.iter().zip(results){
                let v=if jv::truthy(r){r.clone()}else{jv::obj(vec![("vulns",Value::Arr(Vec::new()))])};if !matches!(v,Value::Obj(_)){return Err(())}
                let (package,version,path,stored)=&mut items[*i];state::write_state_file(path,&jv::dump(&v)).map_err(|_|())?;
                self.log(b"INFO",&cat(&[b"OSV batch live query ok ecosystem=npm package=",package,b" version=",version]));*stored=Some(v);
            }
        }
        let cve=Regex::new("^CVE-[0-9]{4}-[0-9]+$",false).unwrap();let mut output=Vec::new();
        for (package,version,_,value) in items{
            let osv=value.ok_or(())?;let vulns=jv::field(&osv,"vulns")?;
            let mut cves=Vec::new();
            let values:Vec<&Value>=match vulns{Value::Arr(a)=>a.iter().collect(),Value::Obj(o)=>o.iter().map(|(_,v)|v).collect(),_=>Vec::new()};
            for v in &values{
                if let Ok(Value::Str(s))=jv::field(v,"id"){if cve.is_match(s){cves.push(s.clone());}}
                if let Ok(Value::Arr(a))=jv::field(v,"aliases"){for x in a{if let Value::Str(s)=x{if cve.is_match(s){cves.push(s.clone());}}}}
            }
            let catalog=self.kev();let mut exploited=false;
            if let Some(c)=catalog{if let Ok(Value::Arr(a))=jv::field(&c,"vulnerabilities"){exploited=a.iter().any(|v|matches!(jv::field(v,"cveID"),Ok(Value::Str(s)) if cves.contains(s)));}}
            let count=match vulns{Value::Arr(a)=>a.len(),Value::Obj(o)=>o.len(),Value::Str(s)=>String::from_utf8_lossy(s).chars().count(),Value::Null|Value::Bool(false)=>0,_=>return Err(())};
            output.push((package,version,if exploited{"hard_block"}else if count>0{"vulnerable"}else{"clean"}));
        }Ok(output)
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
