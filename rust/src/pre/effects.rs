//! Which npm writers can share one post-install trace. This records the
//! limits of attribution; it never predicts that an install was observed.
use super::{cat,W};
use crate::{core::{self,Run},ere::Regex,grammar,manager};

fn without_matches(mut text:W,re:&Regex)->W {
    while let Some((a,z))=re.find(&text){if a==z{break}text.drain(a..z);}
    text
}
fn joined(tokens:&[W])->W {
    let mut out=tokens.join(&b' ');out.push(b' ');out.retain(|b|*b!=1);out
}
pub fn trace(run:&mut Run,command:&[u8])->(bool,W) {
    let npm=Regex::new(&grammar::patterns().npm_install_re,true).expect("npm grammar");
    if !npm.grep_any(&run.candidate_texts(command)){return(false,W::new())}
    let mut payloads=0;
    for payload in run.raw_texts(command) {
        if npm.grep_any(&run.lex(&payload,"recognize").unwrap_or_default()){payloads+=1}
    }
    (true,attribution(run,command,payloads))
}
fn attribution(run:&mut Run,command:&[u8],payloads:usize)->W {
    let null=Regex::new("[0-9]*>>?[[:space:]]*/dev/null",false).unwrap();
    let fd=Regex::new("[0-9]*>&[0-9-]",false).unwrap();
    let assign=Regex::new("^[A-Za-z_][A-Za-z0-9_]*=",false).unwrap();
    let mut writers=0;let mut pending=W::new();let mut between=W::new();let mut moved=W::new();
    for line in run.statements(command).split(|b|*b==b'\n').filter(|s|!s.is_empty()) {
        let f=core::read_fields(line,&[0x1d],5);
        if f[0]==b"?"{return b"the command could not be split into statements".to_vec()}
        let toks=core::read_array(&f[3],0x1f);let Some(head)=toks.first()else{continue};
        let scan=without_matches(without_matches(f[1].clone(),&null),&fd);
        if matches!(head.as_slice(),b"echo"|b"printf"|b"tail"|b"head"|b"grep"|b"ls"|b"cat"|b"true")&&!scan.iter().any(|b|b"<>(){}`$?".contains(b))&&!f[3].contains(&1){continue}
        let mut npm_at=toks.iter().position(|t|manager::name_is(t,"npm"));
        if let Some(at)=npm_at {
            let mut sub=W::new();let mut i=at+1;
            while i<toks.len() {
                let t=&toks[i];i+=1;
                if matches!(t.as_slice(),b"-C"|b"--prefix"|b"-w"|b"--workspace"|b"--userconfig"|b"--globalconfig"|b"--cache"|b"--registry"|b"--location"|b"--loglevel"|b"--tag"|b"--otp"){i+=1;continue}
                if t.starts_with(b"-"){continue}
                if sub.is_empty(){sub=t.clone();if sub==b"audit"{continue}else{break}}
                if t==b"fix"{sub=b"audit fix".to_vec()}break
            }
            if b"|audit|run|run-script|rum|urn|test|tst|t|start|stop|restart|exec|x|init|create|innit|view|v|info|show|ls|list|ll|la|outdated|config|c|get|set|prefix|root|bin|query|explain|why|version|pack|publish|unpublish|help|help-search|doctor|ping|whoami|search|s|se|find|docs|home|repo|bugs|issues|fund|cache|completion|login|logout|adduser|add-user|token|profile|owner|team|access|deprecate|dist-tag|hook|org|star|stars|unstar|sbom|diff|pkg|set-script".split(|b|*b==b'|').any(|v|v==sub){npm_at=None}
        }
        let Some(at)=npm_at else{if writers>0&&pending.is_empty(){pending=joined(&toks)}continue};
        writers+=1;
        if !pending.is_empty()&&between.is_empty(){between=std::mem::take(&mut pending)}pending.clear();
        if !moved.is_empty(){continue}
        if f[3].contains(&1)||f[1].iter().any(|b|b"(){}`".contains(b)){moved=joined(&toks);continue}
        for (i,t) in toks.iter().enumerate() {
            if i<at {
                if matches!(t.as_slice(),b"command"|b"exec"|b"time"){continue}
                let name=t.split(|b|*b==b'=').next().unwrap_or_default();
                if assign.is_match(t)&&!name.to_ascii_lowercase().starts_with(b"npm_config_"){continue}
                moved=t.clone();break
            }
            if t.starts_with(b"-C")||matches!(t.as_slice(),b"--prefix"|b"-g"|b"--global"|b"--no-global"|b"--location"|b"--workspaces"|b"--no-workspaces"|b"--userconfig"|b"--globalconfig")||[b"--prefix=".as_slice(),b"--global=",b"--location=",b"--workspaces=",b"--userconfig=",b"--globalconfig="].iter().any(|prefix|t.starts_with(prefix)){moved=t.clone();break}
        }
    }
    if writers+payloads<2{return W::new()}
    if payloads>0{return b"an npm install runs inside a `sh -c`, `eval` or `$(...)` payload beside another npm statement that writes a lockfile".to_vec()}
    let n=writers.to_string();
    if !between.is_empty(){return cat(&[n.as_bytes(),b" npm statements write a lockfile, and `",between.strip_suffix(b" ").unwrap_or(&between),b"` runs between them"])}
    if !moved.is_empty(){return cat(&[n.as_bytes(),b" npm statements write a lockfile, and one of them moves where it installs (`",moved.strip_suffix(b" ").unwrap_or(&moved),b"`)"])}
    W::new()
}
