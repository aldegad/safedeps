//! OSV batch lookup and the KEV overlay. Requests use curl, each within the
//! deadline post fixed when it started; provider init delegates log retention
//! to state. JSON reads stay in process.
use super::{jv,sh,closure::Spec,report::cat};
use crate::{json::Value,state,os,sha256,ere::Regex,outcome::{Outcome,Action,Form}};
use std::{fs,path::{Path,PathBuf},process::{Command,Stdio},os::unix::fs::MetadataExt,time::{Duration,Instant}};
type W=Vec<u8>;
const CACHE_ENV: &str = "SAFEDEPS_CACHE_DIR";
const CACHE_DIR: &str = "cache";
const CACHE_TTL_ENV: &str = "SAFEDEPS_PROVIDER_CACHE_TTL_SECONDS";
const CACHE_TTL: i64 = 86400;
const CACHE_NAMESPACES: [&str; 3] = ["osv-vuln", "kev", "ghsa"];
const KEV_CACHE_PATH: &str = "kev/known_exploited_vulnerabilities.json";
/// The pages one OSV query may take, the CLI's SAFEDEPS_OSV_PAGE_LIMIT. An
/// answer that has not ended by this page is no answer.
const OSV_PAGES: usize = 20;
/// The longest one request may take, the CLI's own `--max-time` for each: an
/// OSV batch page, an OSV record, the KEV catalog. No request runs past the
/// deadline either (`Providers::curl`).
const BATCH_SECONDS: u64 = 20;
const RECORD_SECONDS: u64 = 15;
const KEV_SECONDS: u64 = 15;
/// Where the OSV record an answer named by its id and `modified` is kept. OSV
/// changes `modified` whenever it changes a record, so the pair names one
/// record. The CLI keeps it at the same path (safedeps_osv_vuln_detail), and
/// `provider_cache_constants_match_cli` holds the two together.
fn osv_record_path(cache: &Path, id: &[u8], modified: &[u8]) -> PathBuf {
    let key = sha256::hex(&cat(&[b"osv-vuln\n", id, b"\n", modified, b"\n"]));
    cache.join("osv-vuln").join(format!("{}.json", key))
}
fn env(name:&str,default:&str)->String{std::env::var(name).ok().filter(|s|!s.is_empty()).unwrap_or_else(||default.into())}
fn fresh(p:&Path,ttl:i64)->bool{fs::metadata(p).is_ok_and(|m|m.is_file()&&os::wall(os::WallRole::ProviderCacheExpiry).seconds()-m.mtime()<=ttl)}
/// An OSV answer is one JSON object whose `vulns`, when it has one, is a list.
/// OSV answers `{}` for a package it has nothing on, and nothing else says so:
/// an empty file, a file this user cannot read and a `null` hold no answer, and
/// none of them reads as no advisories. The CLI reads an answer by the same rule
/// (osv_answer in SAFEDEPS_OSV_JQ), and `osv_answers_match_cli` holds the two
/// together.
fn osv_answer(v:Value)->Option<Value>{(matches!(v,Value::Obj(_))&&matches!(jv::field(&v,"vulns"),Ok(Value::Arr(_)|Value::Null))).then_some(v)}
/// The token of the next page of an answer: None when the answer has ended (no
/// `next_page_token`, or a null one), the token when it goes on, and Err for
/// anything else. A page with a token is part of an answer, never the whole of
/// one. The CLI reads it by the same rule (osv_page_token).
fn page_token(v:&Value)->Result<Option<W>,()>{
    match jv::field(v,"next_page_token"){Ok(Value::Null)=>Ok(None),Ok(Value::Str(t)) if !t.is_empty()=>Ok(Some(t.clone())),_=>Err(())}
}
/// A `modified` as OSV writes one, split into its second and its fraction: an
/// RFC 3339 date-time, `YYYY-MM-DDTHH:MM:SS` with each field in its range and
/// the day within its month, then at most nine fraction digits, then `Z`.
/// OSV's schema writes every time in UTC, ending in `Z`. So an offset, a
/// lower-case `t` or `z`, a space for the `T` and a tenth digit are not OSV's
/// form, and none of them is a time here, even where an offset names the same
/// instant. A second of 60 is a time only at 23:59:60 on the last day of its
/// month. That is where RFC 3339 (section 5.7) puts a leap second: at the end
/// of a month in which one occurs, in UTC. At any other place the second ends
/// at 59, so `08:12:60`, `23:58:60` and `23:59:60` in mid-month are not times.
/// The rule does not narrow the month to June and December. Those are the only
/// month ends a leap second has used so far, but the standard allows any, and
/// which month ends get one later is announced weeks ahead, so code cannot
/// know it. For the same reason it keeps 59 at every month end, where a
/// subtracted leap second would remove it. The CLI reads a time by the same
/// rule (osv_time).
fn osv_time(s:&[u8])->Option<(&[u8],&[u8])>{
    let num=|a:usize,b:usize|s.get(a..b).filter(|d|d.iter().all(u8::is_ascii_digit)).map(|d|d.iter().fold(0u32,|n,c|n*10+u32::from(c-b'0')));
    let (year,month,day,hour,minute,second)=(num(0,4)?,num(5,7)?,num(8,10)?,num(11,13)?,num(14,16)?,num(17,19)?);
    let at=|i:usize,c:u8|s.get(i)==Some(&c);
    if !(1..=12).contains(&month){return None}
    let leap_year=year%4==0&&(year%100!=0||year%400==0);
    let last=[31,if leap_year{29}else{28},31,30,31,30,31,31,30,31,30,31][month as usize-1];
    let leap_second=hour==23&&minute==59&&day==last;
    let fields=(1..=last).contains(&day)&&hour<24&&minute<60&&(second<60||(second==60&&leap_second));
    if !(fields&&at(4,b'-')&&at(7,b'-')&&at(10,b'T')&&at(13,b':')&&at(16,b':')){return None}
    let (z,rest)=s[19..].split_last()?;
    let fraction=match rest{[]=>rest,[b'.',f@..] if (1..=9).contains(&f.len())&&f.iter().all(u8::is_ascii_digit)=>f,_=>return None};
    (*z==b'Z').then_some((&s[..19],fraction))
}
/// The microsecond rule: a record's `modified` is the one the batch gave when
/// it is the same time to the microsecond. querybatch gives a `modified` with
/// six fraction digits, and /v1/vulns/<id> gives the same time with nine.
/// Measured on 2026-11-19 over the 29 advisories of lodash 4.17.20, minimist
/// 1.2.5 and axios 0.21.1, 27 records carried the batch's six digits and three
/// more, and the other two the batch's own string; the two of nanoid 3.3.12
/// were like the 27. So both values must be times (osv_time) with the same
/// date and second, and their fractions must agree in the first six digits,
/// each read with zeros after the digits it gives. A batch that gives more
/// than six digits is held to all of them. No batch has been seen to give
/// fewer: one that ended in 0 kept it (`…04.440180Z`). Reading a shorter one
/// as the same microsecond with zeros is the stricter of the two readings, so
/// `…03Z` is not `…03.191256883Z`. Anything else is another time and another
/// version of the advisory: a value that is not a time, another second,
/// another digit. The CLI reads by the same rule (osv_same_time).
fn osv_same_time(record:&[u8],batch:&[u8])->bool{
    let (Some((second,given)),Some((record_second,fraction)))=(osv_time(batch),osv_time(record))else{return false};
    let digits=given.len().max(6);
    let pad=|f:&[u8]|->Vec<u8>{(0..digits).map(|i|f.get(i).copied().unwrap_or(b'0')).collect()};
    second==record_second&&pad(given)==pad(fraction)
}
/// The record GET /v1/vulns/<id> answers: an object that names that id and,
/// when the answer that named it gave a `modified`, carries that time by the
/// microsecond rule (osv_same_time). A record at another time is another
/// version of the advisory, not the one the answer named. The CLI reads it by
/// the same rule (osv_record).
fn osv_record(v:Value,id:&[u8],modified:&[u8])->Option<Value>{
    let named=matches!(jv::field(&v,"id"),Ok(Value::Str(s)) if s.as_slice()==id);
    let current=modified.is_empty()||matches!(jv::field(&v,"modified"),Ok(Value::Str(s)) if osv_same_time(s,modified));
    (named&&current).then_some(v)
}
/// jq's @uri, which the CLI puts an id in its record URL with.
fn uri(s:&[u8])->String{
    let mut out=String::new();
    for b in s{if b.is_ascii_alphanumeric()||matches!(b,b'-'|b'_'|b'.'|b'~'){out.push(*b as char)}else{out.push_str(&format!("%{:02X}",b))}}
    out
}
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
/// One package of a batch while its answer is read: the advisories its pages
/// named so far, and the token of its next page.
struct Asked{package:W,version:W,vulns:Vec<Value>,token:Option<W>,ended:bool,pages:usize}

/// `kev_reads` counts the parses of the KEV catalog: one `batch` reads the
/// catalog at most once, whatever the number of packages. Read per package,
/// the whole catalog was parsed again for every package of the closure.
/// `until` is the deadline post fixed when it started (post::LIMIT): no
/// request runs past it.
pub struct Providers{home:PathBuf,cache:PathBuf,ttl:i64,announced:bool,kev_reads:usize,until:Instant}
impl Providers{
    pub fn new(home:&Path,until:Instant)->Self{
        let cache=std::env::var_os(CACHE_ENV).filter(|p|!p.is_empty()).map(PathBuf::from).unwrap_or_else(||home.join(CACHE_DIR));
        Self{home:home.into(),cache,ttl:env(CACHE_TTL_ENV,&CACHE_TTL.to_string()).parse().unwrap_or(CACHE_TTL),announced:false,kev_reads:0,until}
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
    /// The HTTP code curl printed, which each caller compares to 200. curl
    /// prints the code of a response it did not finish reading, so a curl that
    /// failed adds how it ended, as the CLI's requests do: no failed request
    /// reads as 200, and the record says both. A request takes at most `cap`
    /// seconds and never runs past `until`: its --max-time is the shorter of
    /// the two, and a request the deadline leaves no time for is not started.
    fn curl(url:&str,response:&Path,payload:Option<&Path>,cap:u64,until:Instant)->W{
        let left=until.saturating_duration_since(Instant::now()).min(Duration::from_secs(cap));
        if left<super::LEAST_REQUEST{return Outcome::Deadline.describe(Action::Curl,Form::Action)}
        let seconds=format!("{}.{:03}",left.as_secs(),left.subsec_millis());
        let mut c=Command::new("curl");c.args(["-fsS","--max-time",seconds.as_str()]);
        if payload.is_some(){c.args(["-H","Content-Type: application/json"]);}
        c.arg("-o").arg(response).args(["-w","%{http_code}"]);
        if let Some(p)=payload{let mut data=b"@".to_vec();data.extend(sh::bytes(p));c.arg("-d").arg(sh::p(&data));}
        c.arg(url).stdin(Stdio::null()).stderr(Stdio::null());
        match c.output(){
            Err(error)=>Outcome::StartFailure(error).describe(Action::Curl,Form::Action),
            Ok(o) if o.status.success()=>jv::captured(&[o.stdout]),
            Ok(o)=>{
                let code=jv::captured(&[o.stdout]);
                cat(&[if code.is_empty(){b"none"}else{&code},b" ",&Outcome::status(o.status).describe(Action::Curl,Form::Detail)])
            },
        }
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
            status=Self::curl(&env("SAFEDEPS_KEV_CATALOG_URL",state::DEFAULT_KEV_CATALOG_URL),&tmp,None,KEV_SECONDS,self.until);
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
        self.judge(items)
    }
    /// The status of each answer this run was given. The KEV catalog is asked
    /// once for the closure: a refresh, its log line and the parse happen
    /// once. A listing is found by an advisory's id and the CVE aliases of its
    /// record.
    fn judge(&mut self,items:Vec<(W,W,Value)>)->Result<Vec<(W,W,Status,Vec<W>)>,Unanswered>{
        if items.is_empty(){return Ok(Vec::new())}
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
    /// The whole OSV answer of each package, asked of OSV by this run as the
    /// CLI asks it (safedeps_osv_query_batch): one querybatch, page by page,
    /// then the record of every advisory that answered, which stands in the
    /// answer in place of its name. querybatch names an advisory by its id and
    /// `modified` only, and a KEV listing is found by the CVE aliases of the
    /// record. No answer of an earlier run is read: it says what OSV knew then,
    /// and an advisory published since is not in it. A result that is not an
    /// answer, a token that is not one, an answer that has not ended within
    /// OSV_PAGES pages, an advisory named without an id, a record that cannot be
    /// read and a request the deadline cut are no answer, and the batch has
    /// none.
    fn osv_answers(&mut self,specs:&[Spec])->Result<Vec<(W,W,Value)>,()>{
        self.init();let temp=sh::mktemp_dir(&sh::tmp_prefix("safedeps-providers")).ok_or(())?;let scratch=Scratch(temp);
        let mut items:Vec<Asked>=Vec::new();
        for spec in specs{
            let package=match &spec.package{Value::Str(s)=>tsv(s),Value::Null=>Vec::new(),_=>return Err(())};let version=tsv(&spec.version);
            if package.is_empty()||version.is_empty(){continue}
            items.push(Asked{package,version,vulns:Vec::new(),token:None,ended:false,pages:0});
        }
        if items.is_empty(){return Ok(Vec::new())}
        if !sh::command_exists("curl"){
            eprintln!("safedeps providers: curl is required for provider queries");self.log(b"ERROR",b"OSV batch unavailable; no answer ecosystem=npm");return Err(());
        }
        let url=env("SAFEDEPS_OSV_BATCH_API_URL",state::DEFAULT_OSV_BATCH_API_URL);
        let payload=scratch.0.join("payload.json");let response=scratch.0.join("response.json");
        // Every page: the queries whose answer has not ended, each with the
        // token its last page gave. OSV keeps the order of the queries, so the
        // k-th result answers the k-th package still asked.
        let mut page=0usize;
        loop{
            let asked:Vec<usize>=(0..items.len()).filter(|n|!items[*n].ended).collect();
            if asked.is_empty(){break}
            page+=1;
            if page>OSV_PAGES{
                self.log(b"ERROR",&cat(&[b"OSV batch answer did not end within ",OSV_PAGES.to_string().as_bytes(),b" pages ecosystem=npm queries=",asked.len().to_string().as_bytes()]));return Err(())
            }
            let queries=Value::Arr(asked.iter().map(|n|{
                let item=&items[*n];
                let mut query=vec![("version",jv::s(&item.version)),("package",jv::obj(vec![("name",jv::s(&item.package)),("ecosystem",jv::s(b"npm"))]))];
                if let Some(token)=&item.token{query.push(("page_token",jv::s(token)));}
                jv::obj(query)
            }).collect());
            fs::write(&payload,cat(&[&jv::dump(&jv::obj(vec![("queries",queries)])),b"\n"])).map_err(|_|())?;
            let status=Self::curl(&url,&response,Some(&payload),BATCH_SECONDS,self.until);
            let st=jv::read_file(&response);
            if status!=b"200"||!st.as_ref().is_some_and(|s|!s.failed&&s.values.last().is_some_and(|v|matches!(jv::field(v,"results"),Ok(Value::Arr(_))))){
                self.log(b"ERROR",&cat(&[b"OSV batch query failed status=",if status.is_empty(){b"none"}else{&status},b" page=",page.to_string().as_bytes()]));return Err(())
            }
            let st=st.unwrap();if st.values.len()!=1{return Err(())}
            let Value::Arr(results)=jv::field(&st.values[0],"results")?else{return Err(())};
            if results.len()!=asked.len(){self.log(b"ERROR",&cat(&[b"OSV batch result count mismatch queries=",asked.len().to_string().as_bytes(),b" results=",results.len().to_string().as_bytes()]));return Err(())}
            for (n,result) in asked.iter().zip(results){
                let Some((answer,token))=osv_answer(result.clone()).and_then(|a|page_token(&a).ok().map(|t|(a,t)))else{
                    self.log(b"ERROR",&cat(&[b"OSV batch result is not an answer ecosystem=npm page=",page.to_string().as_bytes()]));return Err(())
                };
                let item=&mut items[*n];
                if let Ok(Value::Arr(vulns))=jv::field(&answer,"vulns"){item.vulns.extend(vulns.iter().cloned());}
                item.ended=token.is_none();item.token=token;item.pages+=1;
            }
        }
        // Every advisory that answered, read whole once.
        let mut records:Vec<(W,Value)>=Vec::new();
        for item in &items{
            for vuln in &item.vulns{
                let named=match (jv::field(vuln,"id"),jv::field(vuln,"modified")){
                    (Ok(Value::Str(id)),Ok(Value::Null|Value::Bool(false))) if !id.is_empty()=>Some((id.clone(),Vec::new())),
                    (Ok(Value::Str(id)),Ok(Value::Str(modified))) if !id.is_empty()=>Some((id.clone(),modified.clone())),
                    _=>None,
                };
                let Some((id,modified))=named else{
                    self.log(b"ERROR",b"OSV batch answer names an advisory it does not identify ecosystem=npm");return Err(())
                };
                if records.iter().any(|(known,_)|*known==id){continue}
                let Some(record)=self.record(&url,&id,&modified)else{return Err(())};
                records.push((id,record));
            }
        }
        // One line per package OSV answered, with the pages its answer took,
        // as the CLI writes it.
        for item in &items{
            self.log(b"INFO",&cat(&[b"OSV batch live query ok ecosystem=npm package=",&item.package,b" version=",&item.version,b" pages=",item.pages.to_string().as_bytes()]));
        }
        let mut out=Vec::new();
        for item in items{
            let mut vulns:Vec<Value>=Vec::new();
            for vuln in &item.vulns{
                let Ok(Value::Str(id))=jv::field(vuln,"id")else{return Err(())};
                let Some((_,record))=records.iter().find(|(known,_)|known==id)else{return Err(())};
                if !vulns.iter().any(|v|matches!(jv::field(v,"id"),Ok(Value::Str(s)) if s==id)){vulns.push(record.clone());}
            }
            out.push((item.package,item.version,jv::obj(vec![("vulns",Value::Arr(vulns))])));
        }
        Ok(out)
    }
    /// One advisory record, as the CLI reads it (safedeps_osv_vuln_detail):
    /// GET the batch URL with `querybatch` replaced by `vulns/<id>`, so the
    /// record comes from the source whose answer named it. A record is the one
    /// the answer named only when it carries the id and the time of the
    /// `modified` the answer gave, by the microsecond rule (osv_record); a
    /// record OSV serves at another time is not used and not kept, and the
    /// read fails. A record kept under that pair is read again under it, by the
    /// same rule, so a kept record with nine digits answers for the six the
    /// batch gave; a kept file that is not that record is no answer, OSV is
    /// asked again, and the record it gives replaces the file.
    /// With no `modified` nothing names one record, so it is asked and not
    /// kept.
    fn record(&mut self,url:&str,id:&[u8],modified:&[u8])->Option<Value>{
        let path=osv_record_path(&self.cache,id,modified);
        if !modified.is_empty(){
            if let Some(record)=jv::read_one_object(&path).and_then(|v|osv_record(v,id,modified)){return Some(record)}
            if path.exists(){
                self.log(b"WARN",&cat(&[b"OSV record kept for id=",id,b" modified=",modified,b" is not that record; asking OSV again"]));
            }
        }
        let Some(base)=url.strip_suffix("/querybatch")else{
            self.log(b"ERROR",&cat(&[b"OSV record URL cannot be derived from ",url.as_bytes(),b" id=",id]));return None
        };
        let Some(tmp)=sh::mktemp(&cat(&[sh::bytes(&self.cache),b"/osv-vuln/.record."]))else{return None};
        let status=Self::curl(&format!("{}/vulns/{}",base,uri(id)),&tmp,None,RECORD_SECONDS,self.until);
        let record=if status==b"200"{jv::read_one_object(&tmp).and_then(|v|osv_record(v,id,modified))}else{None};
        let kept=match &record{
            Some(_) if !modified.is_empty()=>fs::rename(&tmp,&path).is_ok(),
            _=>{sh::rm_f(&tmp);true},
        };
        if !kept{sh::rm_f(&tmp);}
        match record{
            Some(record) if kept=>Some(record),
            _=>{self.log(b"ERROR",&cat(&[b"OSV record read failed id=",id,b" status=",if status.is_empty(){b"none"}else{&status}]));None},
        }
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
    let rule = cli.lines().find(|line| line.starts_with("SAFEDEPS_OSV_JQ=")).expect("the CLI declares the OSV rules");
    let head = "safedeps_osv_answer() {";
    let body = cli.split_once(head).unwrap().1.split_once("\n}").unwrap().0;
    let script = format!("{rule}\n{head}{body}\n}}\nsafedeps_osv_answer \"$1\" >/dev/null");
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
    // The token of the next page: an answer with none, or a null one, has
    // ended; a string that is not empty goes on; anything else is no answer.
    let token_script = format!("{rule}\njq -j \"$SAFEDEPS_OSV_JQ\"'osv_page_token // \"\"' \"$1\"");
    let tokens: [(&str, Result<Option<&str>, ()>); 10] = [("{}", Ok(None)), (r#"{"vulns":[]}"#, Ok(None)), (r#"{"next_page_token":null}"#, Ok(None)),
        (r#"{"next_page_token":"t"}"#, Ok(Some("t"))), (r#"{"vulns":[1],"next_page_token":"t"}"#, Ok(Some("t"))),
        (r#"{"next_page_token":""}"#, Err(())), (r#"{"next_page_token":1}"#, Err(())), (r#"{"next_page_token":false}"#, Err(())),
        (r#"{"next_page_token":["t"]}"#, Err(())), (r#"{"next_page_token":{}}"#, Err(()))];
    for (body, want) in tokens {
        fs::write(&file, body).unwrap();
        let core = page_token(&jv::read_one_object(&file).unwrap());
        assert_eq!(core, want.map(|t| t.map(|t| t.as_bytes().to_vec())), "the core's token on {body:?}");
        let out = Command::new("/bin/bash").env_clear().env("PATH", std::env::var_os("PATH").unwrap_or_default())
            .args(["-c", &token_script, "token-contract"]).arg(&file).output().unwrap();
        match want {
            Ok(token) => { assert!(out.status.success(), "the CLI's token on {body:?}"); assert_eq!(out.stdout, token.unwrap_or("").as_bytes(), "the CLI's token on {body:?}"); }
            Err(()) => assert!(!out.status.success(), "the CLI refuses the token on {body:?}"),
        }
    }
    // The record of one id: one object that names it, and nothing else.
    let record_head = "safedeps_osv_vuln_answer() {";
    let record_body = cli.split_once(record_head).unwrap().1.split_once("\n}").unwrap().0;
    // With a `modified` from the answer, the record must carry the same time by
    // the microsecond rule: another time, none, or one that is not a time is
    // another version of it.
    let record_script = format!("{rule}\n{record_head}{record_body}\n}}\nsafedeps_osv_vuln_answer \"$1\" GHSA-x \"$2\" >/dev/null");
    let mut records: Vec<(String, &str, bool)> = [(r#"{"id":"GHSA-x"}"#, "", true), (r#"{"id":"GHSA-x","aliases":["CVE-2026-1"],"modified":"m"}"#, "", true), ("  {\"id\":\"GHSA-x\"}\n", "", true),
        (r#"{"id":"GHSA-y"}"#, "", false), (r#"{"id":"ghsa-x"}"#, "", false), (r#"{"id":1}"#, "", false), (r#"{"id":null}"#, "", false), ("{}", "", false), ("[]", "", false),
        (r#"[{"id":"GHSA-x"}]"#, "", false), ("null", "", false), ("", "", false), ("not json", "", false), (r#"{"id":"GHSA-x"} {"id":"GHSA-x"}"#, "", false), (r#"{"id":"GHSA-x"} null"#, "", false),
        (r#"{"id":"GHSA-x","modified":"2026-11-17T16:00:03Z"}"#, "2026-11-17T16:00:03Z", true),
        (r#"{"id":"GHSA-x","aliases":["CVE-2026-1"],"modified":"m"}"#, "m", false),
        (r#"{"id":"GHSA-x","modified":"2026-11-10T00:00:00Z"}"#, "2026-11-17T16:00:03Z", false),
        (r#"{"id":"GHSA-x","modified":"2026-11-17T16:00:03.000Z"}"#, "2026-11-17T16:00:03Z", true),
        (r#"{"id":"GHSA-x"}"#, "2026-11-17T16:00:03Z", false), (r#"{"id":"GHSA-x","modified":null}"#, "2026-11-17T16:00:03Z", false), (r#"{"id":"GHSA-x","modified":1}"#, "1", false),
        (r#"{"id":"GHSA-x","modified":"M"}"#, "m", false), (r#"{"id":"GHSA-y","modified":"2026-11-17T16:00:03Z"}"#, "2026-11-17T16:00:03Z", false), (r#"{"id":"GHSA-x","modified":"n"}"#, "", true)]
        .iter().map(|(body, modified, record)| (body.to_string(), *modified, *record)).collect();
    // The microsecond rule, row by row: the record's `modified`, the batch's,
    // and whether they are the same time.
    let times = [
        // The measured pair, six digits from the batch and nine from the
        // record, and the same time written with more or fewer zeros.
        ("2026-09-10T03:50:51.191256883Z", "2026-09-10T03:50:51.191256Z", true), ("2026-09-10T03:50:51.191256Z", "2026-09-10T03:50:51.191256Z", true),
        ("2026-09-10T03:50:51.191256Z", "2026-09-10T03:50:51.191256000Z", true), ("2026-09-10T03:50:51.191256883Z", "2026-09-10T03:50:51.191256883Z", true),
        ("2026-11-17T16:00:03Z", "2026-11-17T16:00:03.000000Z", true), ("2026-11-17T16:00:03.000000999Z", "2026-11-17T16:00:03Z", true),
        ("2026-09-10T03:50:51.191000883Z", "2026-09-10T03:50:51.191Z", true), ("2028-02-29T00:00:00.5Z", "2028-02-29T00:00:00.500000Z", true),
        ("2000-02-29T23:59:59Z", "2000-02-29T23:59:59Z", true), ("2016-12-31T23:59:60.5Z", "2016-12-31T23:59:60.500000Z", true),
        // Another time: a later or an earlier microsecond, the same six digits
        // in another second or day, a batch with no digits or three against
        // a record past them, a batch with nine held to all nine, a record
        // with fewer digits than the batch's.
        ("2026-09-10T03:50:51.191257883Z", "2026-09-10T03:50:51.191256Z", false), ("2026-09-10T03:50:51.191255999Z", "2026-09-10T03:50:51.191256Z", false),
        ("2026-09-10T03:50:52.191256883Z", "2026-09-10T03:50:51.191256Z", false), ("2026-09-11T03:50:51.191256883Z", "2026-09-10T03:50:51.191256Z", false),
        ("2026-11-17T16:00:03.191256883Z", "2026-11-17T16:00:03Z", false), ("2026-09-10T03:50:51.191256883Z", "2026-09-10T03:50:51.191Z", false),
        ("2026-09-10T03:50:51.191256884Z", "2026-09-10T03:50:51.191256883Z", false), ("2026-09-10T03:50:51.191Z", "2026-09-10T03:50:51.191256Z", false),
        // Not OSV's form on either side, even for the same instant or the
        // same bytes: an offset, a lower-case `t` and `z`, a space, no `Z`, an
        // empty or comma fraction, a tenth digit, a newline after the `Z`, a
        // space before the date, a day or a field out of its range, no time.
        ("2026-09-10T12:50:51.191256883+09:00", "2026-09-10T03:50:51.191256Z", false), ("2026-09-10T03:50:51.191256883Z", "2026-09-10T03:50:51.191256+00:00", false),
        ("2026-09-10T03:50:51.191256+00:00", "2026-09-10T03:50:51.191256+00:00", false), ("2026-11-17t16:00:03z", "2026-11-17t16:00:03z", false),
        ("2026-11-17 16:00:03Z", "2026-11-17 16:00:03Z", false), ("2026-11-17T16:00:03", "2026-11-17T16:00:03Z", false), ("2026-11-17T16:00:03Z", "2026-11-17T16:00:03", false),
        ("2026-11-17T16:00:03.Z", "2026-11-17T16:00:03.Z", false), ("2026-11-17T16:00:03,5Z", "2026-11-17T16:00:03,5Z", false),
        ("2026-11-17T16:00:03.1234567890Z", "2026-11-17T16:00:03.1234567890Z", false), ("2026-11-17T16:00:03Z\n", "2026-11-17T16:00:03Z\n", false),
        (" 2026-11-17T16:00:03Z", " 2026-11-17T16:00:03Z", false), ("2026-02-30T00:00:00Z", "2026-02-30T00:00:00Z", false),
        ("2027-02-29T00:00:00Z", "2027-02-29T00:00:00Z", false), ("1900-02-29T00:00:00Z", "1900-02-29T00:00:00Z", false),
        ("2026-04-31T00:00:00Z", "2026-04-31T00:00:00Z", false), ("2026-13-01T00:00:00Z", "2026-13-01T00:00:00Z", false),
        ("2026-00-01T00:00:00Z", "2026-00-01T00:00:00Z", false), ("2026-11-00T00:00:00Z", "2026-11-00T00:00:00Z", false),
        ("2026-11-17T24:00:00Z", "2026-11-17T24:00:00Z", false), ("2026-11-17T16:60:00Z", "2026-11-17T16:60:00Z", false),
        ("2026-11-17T16:00:61Z", "2026-11-17T16:00:61Z", false),
        // A second of 60 is a time only at 23:59:60 on the last day of its
        // month: in any month, not only June and December, and on February's
        // last day by the leap-year rule. Anywhere else it is not a time: at
        // midday, in mid-month, at another minute or hour, on a 30th that is
        // not the month's last day, on February 28th of a leap year, on a
        // February 29th that does not exist. A leap second is not the second
        // before it either.
        ("1990-12-31T23:59:60.987654321Z", "1990-12-31T23:59:60.987654Z", true), ("2015-06-30T23:59:60Z", "2015-06-30T23:59:60Z", true),
        ("2026-04-30T23:59:60.987654321Z", "2026-04-30T23:59:60.987654Z", true), ("2026-11-30T23:59:60.987654321Z", "2026-11-30T23:59:60.987654Z", true),
        ("2024-02-29T23:59:60.987654321Z", "2024-02-29T23:59:60.987654Z", true), ("2023-02-28T23:59:60.987654321Z", "2023-02-28T23:59:60.987654Z", true),
        ("2026-04-17T08:12:60.987654321Z", "2026-04-17T08:12:60.987654Z", false), ("2016-12-15T23:59:60.987654321Z", "2016-12-15T23:59:60.987654Z", false),
        ("2016-12-31T23:58:60.987654321Z", "2016-12-31T23:58:60.987654Z", false), ("2016-12-31T22:59:60.987654321Z", "2016-12-31T22:59:60.987654Z", false),
        ("2026-12-30T23:59:60.987654321Z", "2026-12-30T23:59:60.987654Z", false), ("2026-01-30T23:59:60.987654321Z", "2026-01-30T23:59:60.987654Z", false),
        ("2024-02-28T23:59:60.987654321Z", "2024-02-28T23:59:60.987654Z", false), ("2023-02-29T23:59:60.987654321Z", "2023-02-29T23:59:60.987654Z", false),
        ("2016-12-31T23:59:60.987654321Z", "2016-12-31T23:59:59.987654Z", false)];
    records.extend(times.iter().map(|(at, given, same)| (format!("{{\"id\":\"GHSA-x\",\"modified\":\"{}\"}}", at.replace('\n', "\\n")), *given, *same)));
    for (body, modified, record) in records {
        fs::write(&file, &body).unwrap();
        assert_eq!(jv::read_one_object(&file).and_then(|v| osv_record(v, b"GHSA-x", modified.as_bytes())).is_some(), record, "the core's record on {body:?} under {modified:?}");
        let cli = Command::new("/bin/bash").env_clear().env("PATH", std::env::var_os("PATH").unwrap_or_default())
            .args(["-c", &record_script, "record-contract"]).arg(&file).arg(modified).status().unwrap();
        assert_eq!(cli.success(), record, "the CLI's record on {body:?} under {modified:?}");
    }
    let _ = fs::remove_dir_all(&dir);
}

#[cfg(test)]
#[test]
fn kev_answers_match_cli() {
    let cli = include_str!("../../../lib/providers/providers.sh");
    let rule = cli.lines().find(|line| line.starts_with("SAFEDEPS_KEV_JQ=")).expect("the CLI declares the catalog rule");
    let head = "safedeps_kev_is_answer() {";
    let body = cli.split_once(head).unwrap().1.split_once("\n}").unwrap().0;
    let script = format!("{rule}\n{head}{body}\n}}\nsafedeps_kev_is_answer \"$1\"");
    // The lookup answers by the rule too: bytes the rule refuses reach no listing,
    // whoever named the file. Every answer below lists the CVE this OSV answer names.
    let overlay = "source \"$3\" && safedeps_kev_overlay \"$2\" 2026-01-01T00:00:00Z \"$1\"";
    let lib = concat!(env!("CARGO_MANIFEST_DIR"), "/../lib/providers/providers.sh");
    let dir = std::env::temp_dir().join(format!("safedeps-kev-answer-{}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    let file = dir.join("catalog.json");
    let osv = dir.join("osv.json");
    fs::write(&osv, r#"{"vulns":[{"id":"GHSA-x","aliases":["CVE-2026-1"]}]}"#).unwrap();
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
            let listed = Command::new("/bin/bash").env_clear().env("PATH", std::env::var_os("PATH").unwrap_or_default())
                .env("SAFEDEPS_HOME", dir.join("home")).args(["-c", overlay, "overlay-contract"]).arg(&file).arg(&osv).arg(lib).output().unwrap();
            assert_eq!(listed.status.success(), answer, "the CLI lookup on {body:?}");
            assert_eq!(listed.stdout.windows(16).any(|w| w == b"\"exploited\":true"), answer, "the CLI listing on {body:?}");
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
    assert!(cli.contains("cache_path=\"${SAFEDEPS_CACHE_DIR}/osv-vuln/${cache_key}.json\""), "CLI OSV record filename");
    assert!(cli.lines().any(|line| line == format!("SAFEDEPS_OSV_PAGE_LIMIT={OSV_PAGES}")), "CLI OSV page limit");
    // No OSV answer is kept: the CLI writes no cache/osv path at all.
    assert!(!cli.contains("${SAFEDEPS_CACHE_DIR}/osv/"), "the CLI keeps no OSV answer");
    let function = |name: &str| -> String {
        let head = format!("{name}() {{");
        let body = cli.split_once(&head).unwrap().1.split_once("\n}").unwrap().0;
        format!("{head}{body}\n}}\n")
    };
    let script = format!("{}{}safedeps_cache_key osv-vuln \"$1\" \"$2\" \"\"", function("safedeps_hash_text"), function("safedeps_cache_key"));
    for (id, modified) in [("GHSA-xxxx-yyyy-zzzz", "2026-11-17T16:00:03Z"), ("CVE-2026-1", "v1+meta"), ("line\nnext", "tab\tvalue")] {
        let out = std::process::Command::new("/bin/bash").env_clear().env("PATH", "/usr/bin:/bin")
            .args(["-c", &script, "cache-contract", id, modified]).output().unwrap();
        assert!(out.status.success(), "CLI cache hash: {}", String::from_utf8_lossy(&out.stderr));
        let key = String::from_utf8(out.stdout).unwrap();
        assert_eq!(osv_record_path(Path::new("cache root"), id.as_bytes(), modified.as_bytes()),
            Path::new("cache root/osv-vuln").join(format!("{}.json", key.trim_end_matches('\n'))));
    }
}

#[cfg(test)]
mod catalog_tests {
    use super::*;

    struct Fixture { root: PathBuf, providers: Providers }
    impl Drop for Fixture { fn drop(&mut self) { let _ = fs::remove_dir_all(&self.root); } }
    /// A home whose KEV catalog is in the cache and fresh, so judging the
    /// answers starts no curl. OSV answers are never kept: a test hands the
    /// judgment the answers a run was given.
    fn fixture(name: &str, kev: &[&str]) -> Fixture {
        let root = std::env::temp_dir().join(format!("safedeps-kev-{}-{}", name, std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let cache = root.join("cache");
        for sub in CACHE_NAMESPACES { fs::create_dir_all(cache.join(sub)).unwrap(); }
        let entries: Vec<String> = kev.iter().map(|id| format!("{{\"cveID\":\"{}\"}}", id)).collect();
        fs::write(cache.join(KEV_CACHE_PATH), format!("{{\"vulnerabilities\":[{}]}}", entries.join(","))).unwrap();
        let providers = Providers { home: root.join("home"), cache, ttl: CACHE_TTL, announced: false, kev_reads: 0,
            until: Instant::now() + Duration::from_secs(25) };
        Fixture { root, providers }
    }
    fn answers(osv: &[(&str, &str)]) -> Vec<(W, W, Value)> {
        osv.iter().map(|(spec, body)| {
            let (package, version) = spec.split_once('@').unwrap();
            (package.as_bytes().to_vec(), version.as_bytes().to_vec(), crate::json::parse_one(body.as_bytes()).unwrap())
        }).collect()
    }

    #[test]
    fn one_batch_reads_the_kev_catalog_once() {
        let names: Vec<String> = (0..60).map(|n| format!("fixture-{}@1.0.{}", n, n)).collect();
        let osv: Vec<(&str, &str)> = names.iter().map(|n| (n.as_str(), "{}")).collect();
        let mut f = fixture("once", &["CVE-2026-9999"]);
        let out = f.providers.judge(answers(&osv)).unwrap();
        assert_eq!(out.len(), 60);
        assert_eq!(f.providers.kev_reads, 1, "the KEV catalog is read once for 60 packages");
        let mut empty = fixture("none", &["CVE-2026-9999"]);
        empty.providers.batch(&[]).unwrap();
        assert_eq!(empty.providers.kev_reads, 0, "a batch with no package does not read the catalog");
    }

    /// One package of each state. Holds without the read counter, so it reads
    /// the same against the per-package reading this replaced. The KEV-listed
    /// package names its CVE only in the aliases of a GHSA record, as a record
    /// a batch reads whole does.
    #[test]
    fn batch_states_are_hard_block_vulnerable_and_clean() {
        let osv = [
            ("fixture-kev@1.0.0", r#"{"vulns":[{"id":"GHSA-xxxx","aliases":["CVE-2026-0001"]}]}"#),
            ("fixture-vuln@1.0.0", r#"{"vulns":[{"id":"CVE-2026-0002"}]}"#),
            ("fixture-clean@1.0.0", "{}"),
        ];
        let mut f = fixture("states", &["CVE-2026-0001"]);
        let out = f.providers.judge(answers(&osv)).unwrap();
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
