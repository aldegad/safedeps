//! State carried by preceding shell statements to the hook's npm question.
//! Words already come from the core's lexer; nothing here evaluates code.
use crate::{ask, ere::Regex};
type W=Vec<u8>;

pub fn name(word:&[u8])->bool {
    word.first().is_some_and(|b|b.is_ascii_alphabetic()||*b==b'_')
        && word.iter().all(|b|b.is_ascii_alphanumeric()||*b==b'_')
}
pub fn assignment(word:&[u8],append:bool)->bool {
    let Some(eq)=word.iter().position(|b|*b==b'=')else{return false};
    let key=&word[..eq];
    name(if append{key.strip_suffix(b"+").unwrap_or(key)}else{key})
}
fn key(word:&[u8])->&[u8]{word.split(|b|*b==b'=').next().unwrap_or(word)}
pub fn unmark(word:&[u8])->&[u8]{word.strip_suffix(&[1]).unwrap_or(word)}
pub fn literal(word:&[u8])->bool {
    let value=word.splitn(2,|b|*b==b'=').nth(1).unwrap_or(word);
    !word.contains(&1)&&!value.starts_with(b"~")&&!value.windows(2).any(|w|w==b":~")
}

pub struct Question { pub env:Vec<W>, pub args:Vec<W>, pub word:W, pub code:W, pub unknown:W }
impl Settings {
    pub fn question(&self,toks:&[W],here:&[u8])->Question {
        use crate::manager::name_is;
        let mut q=Question{env:Vec::new(),args:Vec::new(),word:W::new(),code:W::new(),unknown:self.unknown.clone()};
        let mut opts=Vec::new();let mut inherit=self.exports.clone();let mut after=Vec::new();
        let mut unsets=Vec::new();let mut ignore=false;let mut in_env=false;let mut skip=false;let mut unset=false;
        for tok in toks {
            if !q.word.is_empty(){q.args.push(tok.clone());if tok.contains(&1){q.unknown=unmark(tok).to_vec()}continue}
            if skip {skip=false;if unset{opts.extend([b"-u".to_vec(),tok.clone()]);unsets.push(tok.clone());if ask::code_name(tok){q.code=[b"env -u ".as_slice(),tok].concat()}}unset=false;continue}
            if assignment(tok,true)&&ask::code_name(key(tok).strip_suffix(b"+").unwrap_or(key(tok))) {
                q.code=[key(tok).strip_suffix(b"+").unwrap_or(key(tok)),b"="].concat();continue
            }
            if tok.contains(&1){q.unknown=unmark(tok).to_vec();continue}
            if name_is(tok,"npm") {
                q.word=tok.clone();
                if tok.contains(&b'/')&&!super::npm_word_is_hooks(tok,here){q.code=tok.clone()}continue
            }
            if !tok.contains(&b'/')&&name_is(tok,"env"){in_env=true;continue}
            if tok==b"exec"||(!tok.contains(&b'/')&&name_is(tok,"command")){continue}
            if in_env {
                match tok.as_slice(){
                    b"-C"|b"--chdir"=>{skip=true;continue},
                    b"-u"|b"--unset"=>{skip=true;unset=true;continue},
                    b"-i"|b"--ignore-environment"=>{opts.push(b"-i".to_vec());ignore=true;q.code=[b"env ".as_slice(),tok].concat();continue},
                    _=>{}
                }
                if tok.starts_with(b"--chdir="){continue}
                if let Some(name)=tok.strip_prefix(b"--unset="){
                    opts.extend([b"-u".to_vec(),name.to_vec()]);unsets.push(name.to_vec());
                    if ask::code_name(name){q.code=[b"env ".as_slice(),tok].concat()}continue
                }
                if tok.starts_with(b"-"){q.unknown=[b"env ".as_slice(),tok].concat();continue}
            }
            if assignment(tok,false) {
                if !literal(tok){q.unknown=tok.clone();continue}
                if in_env{after.push(tok.clone())}else{inherit.push(tok.clone())}continue
            }
            q.unknown=tok.clone();
        }
        if !ignore{for name in &self.unsets{q.env.extend([b"-u".to_vec(),name.clone()])}}
        q.env.extend(opts);
        if !ignore{q.env.extend(inherit.into_iter().filter(|t|!unsets.iter().any(|n|n==key(t))))}
        q.env.extend(after);q
    }
}

#[derive(Default)]
pub struct Settings {
    pub exports:Vec<W>,
    pub unsets:Vec<W>,
    pub unknown:W,
    pub changer:W,
    pub setting:W,
    pub code:W,
    assigned:Vec<W>,
    exported:Vec<W>,
}
impl Settings {
    fn carry(&mut self,word:&[u8],grouped:bool)->bool {
        if grouped||!literal(word){return false}
        self.exports.retain(|entry|key(entry)!=key(word));
        self.exports.push(word.to_vec());
        self.unsets.retain(|entry|entry!=key(word));true
    }
    fn unset(&mut self,name:&[u8],grouped:bool)->bool {
        if grouped{return false}
        self.exports.retain(|word|key(word)!=name);
        self.assigned.retain(|word|key(word)!=name);
        self.exported.retain(|word|word!=name);
        if !self.unsets.iter().any(|word|word==name){self.unsets.push(name.to_vec());}true
    }
    fn shell_assignment(&mut self,word:&[u8],exporting:bool,is_literal:bool,grouped:bool) {
        let name=key(word).to_vec();
        if ask::code_name(&name) {
            if word.contains(&b'='){self.code=[name,b"=".to_vec()].concat();}return
        }
        let mut word=word.to_vec();
        if !is_literal{word=unmark(&word).to_vec();word.push(1);}
        if !word.contains(&b'=') {
            if !exporting{return}
            self.exported.push(name.clone());
            let Some(found)=self.assigned.iter().rev().find(|w|key(w)==name)else{return};
            word=found.clone();
        }else{
            self.assigned.push(word.clone());
            if exporting{self.exported.push(name.clone());}
        }
        if self.exported.iter().any(|v|v==&name) {
            if !self.carry(&word,grouped){self.unknown=unmark(&word).to_vec();}return
        }
        if !self.carry(&word,grouped)&&std::env::var_os(crate::os::path(&name)).is_some() {
            self.changer=[name.clone(),b"=".to_vec()].concat();self.setting=self.changer.clone();
        }
        if name.to_ascii_lowercase().starts_with(b"npm_config_") {
            self.changer=[name,b"=".to_vec()].concat();self.setting=self.changer.clone();
        }
    }

    /// Consume a shell environment statement. False means the caller should
    /// proceed to the existing install recognizer and manager grammar.
    pub fn statement(&mut self,toks:&[W],text:&[u8],grouped:bool)->bool {
        let Some(head)=toks.first()else{return true};
        match head.as_slice(){
            b"export"|b"declare"|b"typeset"|b"local"|b"readonly"=>{
                let mut opts=W::new();let mut i=1;
                while let Some(tok)=toks.get(i){
                    if tok==b"--"{i+=1;break}
                    if tok.len()>1&&matches!(tok[0],b'-'|b'+'){opts.extend_from_slice(unmark(tok));i+=1}else{break}
                }
                let mut exporting=head==b"export";let mut is_literal=true;
                if (exporting&&(opts.is_empty()||opts==b"-p"))||matches!(opts.as_slice(),b"-x"|b"-xr"|b"-rx"|b"-x-r"|b"-r-x"){
                    exporting=true;
                }else if exporting||opts.contains(&b'+')||opts.contains(&b'x') {
                    self.changer=[head.as_slice(),b" ",&opts].concat();self.setting=self.changer.clone();return true
                }else if !matches!(opts.as_slice(),b""|b"-r"|b"-g"|b"-rg"|b"-gr"|b"-r-g"|b"-g-r"){
                    is_literal=false;
                }
                for tok in &toks[i..]{
                    let tok_key=key(tok);
                    if assignment(tok,true)&&tok_key.ends_with(b"+")&&ask::code_name(&tok_key[..tok_key.len()-1]) {
                        self.code=[&tok_key[..tok_key.len()-1],b"+="].concat();continue
                    }
                    if !(assignment(tok,false)||name(tok)) {
                        if exporting{self.unknown=unmark(tok).to_vec()}
                        else{self.changer=[head.as_slice(),b" ",unmark(tok)].concat();self.setting=self.changer.clone();}
                        continue
                    }
                    self.shell_assignment(tok,exporting,is_literal,grouped);
                }true
            }
            b"unset"=>{
                let mut opts=W::new();let mut i=1;
                while let Some(tok)=toks.get(i){
                    if tok==b"--"{i+=1;break}
                    if tok.len()>1&&tok[0]==b'-'{opts.extend_from_slice(unmark(tok));i+=1}else{break}
                }
                if opts.contains(&b'f'){return true}
                for tok in &toks[i..]{
                    if !name(tok){self.unknown=[b"unset ",unmark(tok)].concat()}
                    else if ask::code_name(tok){self.code=[b"unset ",tok.as_slice()].concat()}
                    else if !self.unset(tok,grouped){self.unknown=[b"unset ",tok.as_slice()].concat()}
                }true
            }
            b"source"|b"."|b"eval"=>{
                self.changer=head.clone();
                let raw=[text,b" ",&toks.join(&b' ')].concat();
                let flat:W=raw.into_iter().filter(|b|!matches!(b,b'"'|b'\''|b'\\')).collect();
                let re=Regex::new("npm_config_[A-Za-z0-9_]*",true).expect("npm setting name");
                if let Some((start,end))=re.find(&flat){self.setting=[head.as_slice(),b" ",&flat[start..end]].concat();}true
            }
            b"set"=>{
                if let Some(tok)=toks[1..].iter().find(|t|(t.starts_with(b"-")&&t.contains(&b'a'))||*t==b"allexport") {
                    self.changer=[head.as_slice(),b" ",tok].concat();self.setting=self.changer.clone();
                }true
            }
            _=>{
                if !toks.iter().all(|t|assignment(t,true)){return false}
                for tok in toks {
                    if let Some(k)=key(tok).strip_suffix(b"+") {
                        let value=unmark(&tok[k.len()+2..]);
                        let word=[k,b"=",value,&[1]].concat();self.shell_assignment(&word,false,true,grouped);
                    }else{self.shell_assignment(tok,false,true,grouped)}
                }true
            }
        }
    }
}
