//! Install verdict order: target evidence, snapshot, command/ledger checks,
//! per-reading effects, final scan settlement, then the call's record.
//! The rewrite callback is B's reading_inert contract. It is called only
//! after the direct-spec gate, and never for Codex.
use super::{cat, effects, pending, readings::{self,Readings}, snapshot::{self,Snapshot}, Call, Out, W};
use crate::{ask, core::{self,Run}, ere::Regex, jq, json::Value, ledger, lex::Reading, os, stamp, state};
use std::os::unix::ffi::OsStrExt;

mod notices;

fn deny(out:&mut Out,reason:&[u8]) {
    out.say(&jq::compact(&jq::obj(vec![("hookSpecificOutput",jq::obj(vec![
        ("hookEventName",jq::s("PreToolUse")),("permissionDecision",jq::s("deny")),
        ("permissionDecisionReason",jq::arg(reason))]))])));
}
fn log(call:&Call,text:&[u8]) {state::log_advisory(&call.guard_dir,text)}
fn log_command(call:&Call,text:&[u8]) {log(call,&cat(&[text,b" Command: ",&call.command]))}
fn undecided(call:&Call,run:&Run,out:&mut Out)->bool {
    if !run.failed{return false}
    super::deny_undecided_scan(call,out,"a finding was read from a failed scan");true
}

pub fn judge(call:&Call,run:&mut Run,cwd:&[u8],read:&Readings,mut inert:impl FnMut(&mut Run,&[u8])->W)->Out {
    let mut out=Out::default();
    let (project,from,fetch,fetch_why)=read.project(cwd);
    for why in read.reasons(){log_command(call,&cat(&[b"pre-guard: ",&why,b"."]))}
    if project!=cwd {
        log(call,&cat(&["pre-guard: the install lands outside cwd — snapshotting/verifying ".as_bytes(),&project,b" instead of cwd (",cwd,b")."]));
    }
    let project=os::realpath(&project);let cwd=os::realpath(cwd);
    let (ungated_eco,ungated)=read.ungated(&project);
    let lock=state::StateLock::acquire(&call.guard_dir.join("state.lock"),&mut out.stderr,None);
    let Ok(_lock)=lock else{
        log(call,"pre-guard DENY: state lock unavailable for an install command — fail-closed.".as_bytes());
        deny(&mut out,"safedeps: could not acquire the state lock (another safedeps run may be active). Install blocked fail-closed — retry in a moment.".as_bytes());return out
    };
    let snap=match Snapshot::create(call,&project) {
        Ok(snap)=>snap,
        Err(snapshot::Error::Workspace(why))=>{
            let mut why:W=why.into_iter().map(|b|if b==b'\n'{b' '}else{b}).collect();
            if why.last()==Some(&b' '){why.pop();}
            log_command(call,&cat(&[b"pre-guard: could not snapshot the workspace members' package.json files in ",&project,b" (",&why,b")."]));
            deny(&mut out,&cat(&["safedeps: undecided — safedeps could not keep a copy of the workspace members' package.json files in ".as_bytes(),&project,b" (",&why,b"), so it could not roll this install back. This is not a finding about the packages. Make the members' package.json files readable and retry."]));return out
        }
        Err(snapshot::Error::Io(error))=>{out.warn(format!("safedeps: could not keep the pre-install snapshot: {}",error).as_bytes());out.code=1;return out}
    };
    let reasons=suspicious(&call.command);
    registry_notice(call,read);
    if !reasons.is_empty() {
        if !undecided(call,run,&mut out){deny(&mut out,&cat(&[b"safedeps: ",&reasons.join(&b"; "[..])]))}
        return out
    }
    if !approved(call,run,read,&project,&mut out){return out}
    if !ungated.is_empty(){log_command(call,&cat(&[b"pre-guard UNGATED: ",&ungated_eco,b" install names a package with no version spec, so the ledger gate did not run. No effect gate reads the result of this install, so it is unverified. Unpinned: ",&ungated,b"."]))}
    if read.yes("piped") {
        if undecided(call,run,&mut out){return out}
        log_command(call,"pre-guard DENY: install text piped into a shell beside a visible install could not be reduced to an approved spec — fail-closed.".as_bytes());
        deny(&mut out,notices::PIPED.as_bytes());return out
    }
    if read.yes("hidden_unreduced") {
        if undecided(call,run,&mut out){return out}
        log(call,"pre-guard DENY: hidden dependency install could not be reduced to an approved spec — fail-closed.".as_bytes());
        deny(&mut out,"safedeps: hidden dependency install detected, but no package spec could be extracted for ledger approval — install blocked fail-closed.".as_bytes());return out
    }
    let codex=jq::stream_has(&call.input,"turn_id");
    let mut rewrites=Vec::new();let mut trace=false;let mut attribution=W::new();
    for &reading in &read.set {
        run.reading=Some(reading);
        if !codex{rewrites.push(inert(run,&call.command))}
        let (wanted,why)=effects::trace(run,&call.command);trace|=wanted;
        if attribution.is_empty(){attribution=why}
        run.reading=None;
    }
    if read.set==[Reading::Bash]&&run.diverge {
        log_command(call,b"pre-guard: a place where the shells read differently was first met while deciding the inert rewrite; the zsh and dash readings were not judged.");run.failed=true;
    }
    if rewrites.windows(2).any(|w|w[0]!=w[1]) {
        let names=read.set.iter().map(|&r|readings::name(r)).collect::<Vec<_>>().join(" ");
        log_command(call,&cat(&[b"pre-guard DENY: the readings (",names.as_bytes(),") put this command's npm installs in different places, so no single --ignore-scripts rewrite is inert for every shell — undecided, fail-closed.".as_bytes()]));
        deny(&mut out,notices::READINGS.as_bytes());return out
    }
    if super::settle_scan_failure(call,run.failed,&mut out){return out}
    let rewrite=rewrites.first().map(Vec::as_slice).unwrap_or(b"none");
    let (flags,command)=rewrite.split_once_byte(b'\n');
    for (flag,message) in notices::INERT {
        if if *flag=="downgrade"{flags==b"downgrade"}else{flags.split(|b|*b==b' ').any(|s|s==flag.as_bytes())}{log_command(call,message.as_bytes())}
    }
    let record=pending::Record{cwd:&cwd,project_from:from,trace,attribution:&attribution,fetch:fetch.as_ref(),fetch_why:&fetch_why};
    if let Err(error)=pending::write(call,&snap,&record){out.warn(format!("safedeps: could not write this install's pending state: {}",error).as_bytes());out.code=1;return out}
    if flags.starts_with(b"rewrite")&&!command.is_empty() {
        let unread=flags.split(|b|*b==b' ').any(|s|matches!(s,b"unverified"|b"unread"|b"release"));
        if snap.mark_rewrite(command,unread).is_ok() {
            out.say(&jq::compact(&jq::obj(vec![("hookSpecificOutput",jq::obj(vec![
                ("hookEventName",jq::s("PreToolUse")),("permissionDecision",jq::s("allow")),
                ("updatedInput",jq::obj(vec![("command",jq::arg(command))]))]))])));
        }else{log_command(call,&cat(&[b"pre-guard: could not record the command safedeps would write in ",snap.path(b"meta.json").as_os_str().as_bytes(),b", so it was not rewritten: the install runs as given, without --ignore-scripts, and the effect gate falls back to detect-and-rollback."]))}
    }
    out
}

trait SplitByte { fn split_once_byte(&self,byte:u8)->(&[u8],&[u8]); }
impl SplitByte for [u8] {fn split_once_byte(&self,byte:u8)->(&[u8],&[u8]) {self.iter().position(|b|*b==byte).map(|i|(&self[..i],&self[i+1..])).unwrap_or((self,&[]))}}

fn suspicious(command:&[u8])->Vec<W> {
    let has=|pattern|Regex::new(pattern,true).expect("preflight expression").grep_any(command);
    let mut why=Vec::new();
    if has("curl.*\\|[[:space:]]*(bash|sh|node)"){why.push(b"Command pipes remote content to shell execution".to_vec())}
    if has("npm[[:space:]]+config[[:space:]]+set[[:space:]]+ignore-scripts[[:space:]]+false"){why.push(b"Command explicitly enables install scripts".to_vec())}
    if has("--registry([=[:space:]]+)")&&!has("--registry([=[:space:]]+)https?://(registry\\.npmjs\\.org|registry\\.yarnpkg\\.com)(/|[[:space:]]|$)"){why.push(b"Command uses non-standard npm registry".to_vec())}
    if has(notices::TYPOSQUATS){why.push(b"Package name matches known typosquatting patterns".to_vec())}
    why
}

fn registry_notice(call:&Call,read:&Readings) {
    let mut registries=Vec::new();
    for target in &read.targets {
        if !target.kind.starts_with("npm"){continue}
        let Some(v @ Value::Obj(_))=&target.fetch else{continue};
        if v.get("unknown").is_some_and(|v|!matches!(v,Value::Null)){continue}
        if ask::registry_public(v.get("registry"),v){continue}
        let registry=match v.get("registry") {None|Some(Value::Null|Value::Bool(false))=>b"a value npm will not print".to_vec(),Some(Value::Str(v))=>v.clone(),Some(v)=>jq::compact(&jq::from_value(v)).into_bytes()};
        registries.push(cat(&[b"registry=",&registry]));
    }
    registries.sort();registries.dedup();
    if !registries.is_empty(){log_command(call,&cat(&[b"pre-guard: npm reads ",&registries.join(&b", "[..]),b" for this install from its configuration (an .npmrc or the environment), which is not the public npm registry. That alone does not deny the install; safedeps will not rebuild what npm fetched from there (on Codex the install runs its own scripts before any hook can withhold them)."]))}
}

fn approved(call:&Call,run:&Run,read:&Readings,project:&[u8],out:&mut Out)->bool {
    let specs:Vec<_>=read.field("ledger_specs").split(|b|*b==b'\n').filter(|s|!s.is_empty()).collect();
    if specs.is_empty(){return true}
    let npm=specs.iter().any(|s|s.starts_with(b"npm\t"));
    let context=if npm&&!(read.npm_seen&&read.npm_all_global) {
        match ledger::context::project_context(&os::path(project)) {
            Ok(v)=>v,
            Err(why)=>{
                out.stderr.extend_from_slice(&why);
                log(call,&cat(&[b"pre-guard DENY: Yarn project resolution context is invalid in ",project,b"; scoped approval cannot be verified."]));
                deny(out,b"safedeps: Yarn project resolutions are present, but their lockfile context could not be verified. Install blocked fail-closed; repair the root package.json/yarn.lock context and run `safedeps check` again.");return false
            }
        }
    }else{None};
    let context=context.as_ref().and_then(|v|v.get("context_hash")).and_then(Value::as_str).unwrap_or("");
    let invoke=if std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default()).any(|p|{let p=p.join("safedeps");p.is_file()&&os::executable(&p)}) {b"safedeps".to_vec()}
        else{match stamp::package_root(){Ok(root)=>quote(root.join("bin/safedeps").as_os_str().as_bytes()),Err(why)=>{deny(out,format!("safedeps: {}. Install blocked fail-closed.",why).as_bytes());return false}}};
    let mut blocked=Vec::new();let mut ecos=Vec::new();
    for line in specs {
        let fields=core::read_fields(line,b"\t",3);let eco=jq::text(&fields[0]);let pkg=jq::text(&fields[1]);let spec=jq::text(&fields[2]);
        if eco.is_empty()||pkg.is_empty()||spec.is_empty(){continue}
        if ledger::check(&ledger::directory(),&eco,&pkg,&spec,if eco=="npm"{context}else{""},os::wall(os::WallRole::PreLedgerExpiry).seconds()).is_ok_and(|v|v.approved){continue}
        let show=|s:&str|s.as_bytes().iter().map(|b|if *b==2{b' '}else{*b}).collect::<W>();
        blocked.push(cat(&[&invoke,b" check ",eco.as_bytes(),b" ",&show(&pkg),b"@",&show(&spec)]));
        if !ecos.contains(&eco){ecos.push(eco)}
    }
    if blocked.is_empty(){return true}
    if !undecided(call,run,out){deny(out,&cat(&[b"safedeps: install not approved (ecosystem=",ecos.join(",").as_bytes(),") — run `".as_bytes(),&blocked.join(&b" && "[..]),b"` first, then retry the install using the approved version (see install_hint in the check output)."]));}
    false
}

/// Bash's %q for the absolute CLI path used in the prescription. Paths with
/// control bytes use ANSI quoting; ordinary metacharacters are backslashed.
fn quote(path:&[u8])->W {
    if path.is_empty(){return b"''".to_vec()}
    let units=os::bash_quote_units(path);
    if units.iter().any(|(_,printable)|!*printable) {
        let mut out=b"$'".to_vec();let mut at=0;
        for (n,printable) in units {for &b in &path[at..at+n]{match b {
            b'\n'=>out.extend_from_slice(b"\\n"),b'\r'=>out.extend_from_slice(b"\\r"),b'\t'=>out.extend_from_slice(b"\\t"),
            7=>out.extend_from_slice(b"\\a"),8=>out.extend_from_slice(b"\\b"),11=>out.extend_from_slice(b"\\v"),12=>out.extend_from_slice(b"\\f"),27=>out.extend_from_slice(b"\\E"),
            b'\\'|b'\''=>{out.push(b'\\');out.push(b)},_ if !printable=>out.extend_from_slice(format!("\\{:03o}",b).as_bytes()),_=>out.push(b)
        }}at+=n;}out.push(b'\'');return out
    }
    let mut out=Vec::new();for (i,&b) in path.iter().enumerate(){if br#" \"'`$&();<>|*?[]{}!^"#.contains(&b)||(i==0&&matches!(b,b'#'|b'~')){out.push(b'\\')}out.push(b)}out
}

/// Compare the actual prescription quoting against bash printf %q. Hex
/// input preserves non-UTF8 pathname bytes without passing them as code.
pub fn quote_probe(input:&[u8])->i32 {
    use std::io::Write;
    let Ok(v)=crate::json::parse_one(input)else{return 2};
    let Some(hex)=v.get("hex").and_then(Value::as_str)else{return 2};
    if hex.len()%2!=0||!hex.is_ascii(){return 2}
    let Ok(bytes)=hex.as_bytes().chunks(2).map(|s|u8::from_str_radix(std::str::from_utf8(s).unwrap(),16)).collect::<Result<Vec<_>,_>>()else{return 2};
    if bytes.contains(&0){return 2}
    if std::io::stdout().write_all(&quote(&bytes)).is_err(){return 1}0
}

/// The Codex install path can be compared before B's implementation is
/// integrated. This is a component entry, never the installed hook. Reject
/// other engine inputs rather than substituting a rewrite implementation.
pub fn probe(input:&[u8])->i32 {
    let Ok(value)=crate::json::parse_one(input)else{return 2};
    if value.get("turn_id").is_none(){return 2}
    let Some(command)=value.get("tool_input").and_then(|v|v.get("command")).and_then(Value::as_bytes)else{return 2};
    let cwd=super::jq_r(value.get("cwd"));if cwd.is_empty(){return 2}
    os::set_umask(0o077);let guard_dir=state::guard_dir();if state::ensure_dirs(&guard_dir).is_err(){return 1}
    let call=Call{input:crate::json::Stream{values:vec![value.clone()],failed:false},command,guard:state::guard_text(),guard_dir};
    let core=crate::core::Core::new();let mut run=Run::new(&core);
    let read=Readings::collect(&mut run,&call.command,&cwd);
    if !read.yes("any_install"){return 2}
    let out=judge(&call,&mut run,&cwd,&read,|_,_|unreachable!("Codex must not ask for a rewrite"));
    super::emit(&out)
}
