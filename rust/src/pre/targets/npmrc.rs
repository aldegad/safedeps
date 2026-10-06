//! Whether npm's own answer names a directory whose records npm will write.
//! These settings can withhold coverage; they never choose another directory.
use super::{cat, os, W};

fn value(file:&[u8],key:&[u8],failed:&mut bool)->W {
    let path=os::path(file);
    if !path.is_file()||!os::readable(&path){return W::new()}
    let bytes=match std::fs::read(&path){Ok(v)=>v,Err(_)=>{*failed=true;return b"?".to_vec()}};
    let trim=|v:&[u8]|v.iter().position(|b|!b.is_ascii_whitespace()).unwrap_or(v.len());
    let mut found=W::new();
    for line in bytes.split(|b|*b==b'\n') {
        let line=&line[trim(line)..];
        if line.starts_with(b"["){break}
        if line.is_empty()||matches!(line[0],b';'|b'#'){continue}
        let (k,v)=match line.iter().position(|b|*b==b'='){Some(i)=>(&line[..i],&line[i+1..]),None=>(line,b"true".as_slice())};
        let end=k.iter().rposition(|b|!b.is_ascii_whitespace()).map_or(0,|i|i+1);
        if &k[..end]!=key{continue}
        let v=&v[trim(v)..];
        let quoted=v.first().filter(|b|matches!(b,b'\''|b'"')).and_then(|q|v[1..].iter().position(|b|b==q));
        let v=if let Some(i)=quoted{&v[1..1+i]}else{
            let v=&v[..v.iter().position(|b|matches!(b,b';'|b'#')).unwrap_or(v.len())];
            &v[..v.iter().rposition(|b|!b.is_ascii_whitespace()).map_or(0,|i|i+1)]
        };
        found=cat(&[b"=",v]);
    }super::super::captured(found)
}

pub fn unrecorded(dir:&[u8],user:&[u8],global_off:bool,failed:&mut bool)->W {
    let project=cat(&[dir,b"/.npmrc"]);let mut undecided=false;
    for key in [b"location".as_slice(),b"global"] {
        let mut source=project.as_slice();let mut v=value(source,key,failed);
        if v.is_empty(){
            if user==b"?"{undecided=true;continue}
            source=user;v=value(source,key,failed);
        }
        if v==b"?"{return cat(&[source,b" could not be read, so safedeps cannot tell whether npm records this install where the effect gate reads it"])}
        if v.is_empty(){continue}
        let v=&v[1..];
        if (key==b"location"&&matches!(v,b"user"|b"project"))||(key==b"global"&&(global_off||matches!(v,b"false"|b"null"))){continue}
        return cat(&[source,b" sets ",key,b"=",v,b", so npm does not record this install where the effect gate reads it"])
    }
    if undecided{b"the user .npmrc is named by a value the shell decides at run time, so safedeps cannot tell whether npm records this install where the effect gate reads it".to_vec()}else{W::new()}
}
