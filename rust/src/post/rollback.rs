//! Rollback writes only the paths it inspected. It never runs npm.
use super::{jv,snapshot::{self,Store},trace::{self,Install},report::{self,Report,cat},sh};
use crate::{json::Value,state,os,outcome::{Outcome,Action,Form}};
use std::{collections::HashSet,path::Path};

/// What node_modules was before the command, as a record taken then states
/// it. A rollback keeps a tree only on such a fact: a record that states
/// none leaves the removal as it was.
pub enum Before {
    /// The pre-command snapshot says it was a directory. The rollback removes
    /// only the entries the snapshot's listing of it lacks.
    Directory,
    /// The backstop's trace entry recorded its inode before the command, and
    /// it has that inode still. The rollback removes the entries the entry's
    /// listing lacks; an entry with no listing keeps the whole tree.
    Same(Option<Vec<Vec<u8>>>),
    Unknown,
}
impl Before {
    pub fn of_snapshot(store:&Store,pre:&[u8])->Self{
        if pre.is_empty(){return Self::Unknown}
        let meta=jv::read_one_object(&store.path(pre,b"meta.json"));
        match meta.as_ref().map(|m|jv::field(m,"node_modules")) {Some(Ok(Value::Str(k))) if k==b"directory"=>Self::Directory,_=>Self::Unknown}
    }
    /// An entry taken in another directory holds that directory's inodes.
    pub fn of_entry(project:&Path,entry:&[u8],moved:bool)->Self{
        if moved||entry.is_empty(){return Self::Unknown}
        let Ok(v)=crate::json::parse_one(entry) else{return Self::Unknown};
        match jv::path(&v,&["inodes","node_modules"]) {
            Ok(Value::Str(i)) if !i.is_empty()&&os::tree_inode(&project.join("node_modules")).as_bytes()==i.as_slice()=>{
                let listed=match jv::field(&v,"entries") {
                    Ok(Value::Arr(xs))=>xs.iter().map(|x|match x {Value::Str(s)=>Some(s.clone()),_=>None}).collect::<Option<Vec<_>>>(),
                    _=>None,
                };
                Self::Same(listed)
            },
            _=>Self::Unknown,
        }
    }
}

pub struct Rollback<'a>{
    pub store:&'a Store,pub report:&'a mut Report,pub trace:&'a mut Install,
    pub pre:Vec<u8>,pub target:Vec<u8>,pub backstop:bool,before:Before,
    npm_project:bool,wrote:Option<bool>,compared:Vec<Vec<u8>>,different:Vec<u8>,refused:HashSet<Vec<u8>>,stepped:HashSet<Vec<u8>>,
}
impl<'a> Rollback<'a>{
    /// Construct before restoring any file: comparisons are against the
    /// command's snapshot, even when the rollback target is an older one.
    pub fn new(store:&'a Store,report:&'a mut Report,trace:&'a mut Install,pre:Vec<u8>,target:Vec<u8>,backstop:bool,before:Before)->Self{
        let npm_project=["package.json","package-lock.json","node_modules/.package-lock.json"].iter().any(|n|sh::is_file(&store.project.join(n)));
        let mut out=Self{store,report,trace,pre,target,backstop,before,npm_project,wrote:None,compared:Vec::new(),different:Vec::new(),refused:HashSet::new(),stepped:HashSet::new()};
        if out.pre.is_empty()||!sh::is_file(&store.path(&out.pre,b"meta.json")){return out}
        if !out.trace.records.is_empty(){out.wrote=Some(true);return out}
        out.wrote=Some(false);
        for name in snapshot::NODE_FILES{
            let copy=store.path(&out.pre,name.as_bytes());let live=store.project.join(name);
            let changed=if sh::is_file(&copy){out.compared.push(name.as_bytes().to_vec());snapshot::differs(&copy,&live)}
                else if sh::is_file(&sh::p(&cat(&[sh::bytes(&copy),b".missing"]))){out.compared.push(name.as_bytes().to_vec());sh::present(&live)}else{false};
            if changed{out.wrote=Some(true);out.different=name.as_bytes().to_vec();break}
        }out
    }
    fn refuse(&mut self,kind:&[u8],path:&std::path::Path,why:&[u8]){
        if !self.refused.insert(cat(&[kind,b" of ",sh::bytes(path)])){return}
        let line=report::refused(kind,path,why);self.report.say(&line);
        state::log_advisory(&self.store.home,&cat(&[b"post-verify REORG REFUSED: ",&line,b" -- project ",sh::bytes(&self.store.project)]));
        sh::append(&self.store.home.join("reorg.log"),&cat(&[b"[",os::utc_stamp(os::wall(os::WallRole::ReorgRefusedHeader).seconds()).as_bytes(),b"] REORG REFUSED\n  Project: ",sh::bytes(&self.store.project),b"\n  ",&line,b"\n"]));
    }
    pub fn restore(&mut self,name:&[u8]){
        let saved=self.store.copy(&self.target,name);let live=self.store.project.join(sh::p(name));
        let missing=sh::p(&cat(&[sh::bytes(&saved),b".missing"]));
        let current_missing=sh::p(&cat(&[sh::bytes(&self.store.copy(&self.store.id,name)),b".missing"]));
        let recorded_missing=sh::is_file(&missing)||sh::is_file(&current_missing);
        if let Some(why)=report::outside(&self.store.project,&live){
            if sh::is_file(&saved)&&snapshot::differs(&saved,&live){self.stepped.insert(name.to_vec());self.refuse(b"restore",&live,&why);}
            else if !sh::is_file(&saved)&&recorded_missing&&sh::present(&live){self.stepped.insert(name.to_vec());self.refuse(b"removal",&live,&why);}
            return;
        }
        if sh::is_file(&saved){if snapshot::differs(&saved,&live){self.stepped.insert(name.to_vec());self.report.restore(&saved,&live);}return}
        if recorded_missing&&sh::is_file(&live){self.stepped.insert(name.to_vec());self.report.remove(&live);}
    }
    pub fn package_json(&mut self){
        if self.stepped.contains(b"package.json".as_slice()){return}
        let saved=self.store.path(&self.target,b"package.json");let live=self.store.project.join("package.json");
        if !sh::is_file(&saved)||!snapshot::differs(&saved,&live){return}
        self.stepped.insert(b"package.json".to_vec());
        if let Some(why)=report::outside(&self.store.project,&live){self.refuse(b"restore",&live,&why);}else{self.report.restore(&saved,&live);}
    }
    fn node_facts(&self)->(bool,Vec<Vec<u8>>){
        let tree=self.store.project.join("node_modules");let pre=&self.pre;
        let meta=self.store.path(pre,b"meta.json");let packages=self.store.path(pre,b"packages.list");let bins=self.store.path(pre,b"bins.list");
        let links=self.store.path(pre,b"links.list");
        if let Some(rel)=self.trace.records.first(){return(false,vec![cat(&[sh::bytes(&self.store.project),b"/",rel,b" is newer than the baseline taken before this command or has another inode"])])}
        if pre.is_empty(){return(false,vec![b"this rollback has no snapshot from before the command".to_vec()])}
        if !sh::is_file(&meta){return(false,vec![report::path(&meta)])}
        if !self.different.is_empty(){return(false,vec![cat(&[sh::bytes(&self.store.project),b"/",&self.different,b" differed from the pre-command snapshot ",pre,b" when this rollback began"])])}
        if self.wrote!=Some(false)||self.compared.is_empty(){return(false,vec![report::path(&self.store.path(pre,b"package.json"))])}
        for f in [&packages,&bins,&links]{if !sh::is_file(f){return(false,vec![report::path(f)])}}
        let old=snapshot::sorted_lines(&packages);let mut now=trace::package_files(&tree,true);now.sort();
        if let Some(found)=now.iter().find(|n|!old.contains(n)){return(false,vec![cat(&[sh::bytes(&tree),b" lists ",found,b", which the pre-command snapshot ",pre,b" does not"])])}
        let old=snapshot::sorted_lines(&bins);let now=trace::listing(&tree.join(".bin"));
        if let Some(found)=now.iter().find(|n|!old.contains(n)){return(false,vec![cat(&[sh::bytes(&tree),b"/.bin lists ",found,b", which the pre-command snapshot ",pre,b" does not"])])}
        let old=snapshot::sorted_lines(&links);let now=trace::package_links(&tree);
        if let Some(found)=now.iter().find(|n|!old.contains(n)){return(false,vec![cat(&[sh::bytes(&tree),b" lists the link ",found,b", which the pre-command snapshot ",pre,b" does not"])])}
        // node_modules' own time is not a write: a tool the command ran makes
        // a cache directory under it (`.vite`), and the whole tree went with
        // it. A package manager's write shows as one of the checks above or
        // below.
        let hidden=tree.join(".package-lock.json");
        if trace::newer(&hidden,&meta,false,true){return(false,vec![cat(&[sh::bytes(&hidden),b" is newer than the pre-command snapshot ",pre])])}
        if !sh::present(&tree){return(true,Vec::new())}
        let mut lines=vec![cat(&[b"kept ",sh::bytes(&tree)])];if sh::is_link(&tree){lines.push(report::path(&tree));}
        lines.push(self.trace.line.clone());
        lines.push(cat(&[b"when this rollback began, none of ",&self.compared.join(b", ".as_slice()),b" in ",sh::bytes(&self.store.project),b" differed from the pre-command snapshot ",pre]));
        lines.push(cat(&[sh::bytes(&tree),b" lists no package.json the pre-command snapshot ",pre,b" lacks"]));
        lines.push(cat(&[sh::bytes(&tree),b"/.bin lists no entry the pre-command snapshot ",pre,b" lacks"]));
        lines.push(cat(&[sh::bytes(&tree),b" lists no link the pre-command snapshot ",pre,b" lacks"]));
        lines.push(if sh::exists(&hidden){cat(&[sh::bytes(&hidden),b" is not newer than the pre-command snapshot ",pre])}else{report::path(&hidden)});
        lines.push(if trace::newer(&tree,&meta,false,true){cat(&[sh::bytes(&tree),b" itself is newer than the pre-command snapshot ",pre])}
            else{cat(&[sh::bytes(&tree),b" is not newer than the pre-command snapshot ",pre])});(true,lines)
    }
    pub fn node_modules(&mut self){
        if !self.npm_project{return}
        let (kept,facts)=self.node_facts();
        if kept{if !facts.is_empty(){for l in facts{self.report.say(l);}self.trace.said=true;}return}
        let tree=self.store.project.join("node_modules");if !sh::present(&tree){return}
        for l in facts{self.report.say(l);}
        if sh::is_link(&tree){self.refuse(b"removal",&tree,&report::path(&tree));return}
        if !sh::is_dir(&tree){return}
        match std::mem::replace(&mut self.before,Before::Unknown) {
            Before::Directory=>{
                let pre=self.pre.clone();
                let list=self.store.path(&pre,b"entries.list");
                match sh::is_file(&list).then(||std::fs::read(&list).ok()).flatten() {
                    Some(raw)=>{
                        let listed:Vec<Vec<u8>>=raw.split(|b|*b==0).filter(|e|!e.is_empty()).map(Vec::from).collect();
                        self.added(&tree,&listed,&cat(&[b", which the pre-command snapshot ",&pre,b" does not"]));
                    },
                    None=>self.report.path(&list),
                }
                self.report.say(cat(&[b"kept ",sh::bytes(&tree),b", which was a directory when the pre-command snapshot ",&pre,b" was taken"]));
            },
            Before::Same(listed)=>{
                if let Some(listed)=listed {self.added(&tree,&listed,b", which the trace entry for this call did not list before this command");}
                self.report.say(cat(&[b"kept ",sh::bytes(&tree),b": it has the inode the trace entry for this call recorded before this command"]));
            },
            Before::Unknown=>{
                self.report.remove(&tree);
            },
        }
        for n in ["package.json","package-lock.json","npm-shrinkwrap.json"]{self.report.path(&self.store.project.join(n));}
        self.report.workspaces_key(&self.store.project);
    }
    /// A node_modules that was a directory before the command stays. What
    /// the listing from then lacks is what the command added, and only that
    /// is removed, each entry after the fact that names it. What the command
    /// changed in place keeps the command's bytes: the listing names entries
    /// and holds none of their files.
    fn added(&mut self,tree:&Path,before:&[Vec<u8>],source:&[u8]){
        let (now,failed)=trace::tree_entries(tree);
        for entry in trace::added_entries(before,&now) {
            let path=tree.join(sh::p(&entry));
            self.report.say(cat(&[sh::bytes(tree),b" lists the entry ",sh::bytes(&path),source]));
            if let Some(why)=report::outside(&self.store.project,tree){self.refuse(b"removal",&path,&why);}else{self.report.remove(&path);}
        }
        if let Some(error)=failed {self.report.say(Outcome::Io(Err(error)).describe(Action::Walk(tree),Form::Action));}
    }
    pub fn tail(&mut self,input:&[u8]){
        self.report.changed_nothing();
        if self.trace.absent&&!self.trace.said{self.report.say(&self.trace.line);self.trace.said=true;}
        if !self.backstop{self.report.inert(&self.store.home,&self.store.meta(),input);}
    }
    pub fn message(&self,log_head:&[u8],head:&[u8],reasons:&[u8])->Result<Vec<u8>,()>{
        let confirmed=snapshot::confirmed(&self.store.home,&self.store.hash)?;
        let snapshot_line=cat(&[b"Rollback snapshot: ",&self.target,if !self.target.is_empty()&&self.target==confirmed{b", a confirmed snapshot"}
            else if !self.target.is_empty()&&self.target==self.pre{b", taken before this command; no confirmed snapshot names it"}else{b""}]);
        let pre=if self.pre.is_empty(){Vec::new()}else{cat(&[b"\n  Snapshot: ",&self.pre])};
        let mut details=Vec::new();for l in &self.report.lines{details.extend(cat(&[b"  ",l,b"\n"]));}
        let log=self.store.home.join("reorg.log");
        sh::append(&log,&cat(&[b"[",os::utc_stamp(os::wall(os::WallRole::ReorgRollbackHeader).seconds()).as_bytes(),b"] ",log_head,&pre,b"\n  Project: ",sh::bytes(&self.store.project),b"\n  Reasons: ",reasons,b"\n  ",&snapshot_line,b"\n",&details]));
        if !snapshot_line.ends_with(b", a confirmed snapshot")&&!self.backstop{
            let inert=if self.report.inert.is_empty(){Vec::new()}else{cat(&[b"; ",&self.report.inert])};
            state::log_advisory(&self.store.home,&cat(&[b"post-verify REORG with no confirmed snapshot in ",sh::bytes(&self.store.project),b": ",&snapshot_line,&inert,b". Reasons: ",reasons]));
        }
        Ok(cat(&[head,b"\n\nDetected problems:\n",reasons,b"\n\n",&snapshot_line,b"\nWhat the rollback did and what it found:\n",&self.report.lines.join(&b'\n'),b"\n\n",&report::file(b"Details log",&log)]))
    }
}
