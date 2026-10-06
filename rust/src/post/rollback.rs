//! Rollback writes only the paths it inspected. It never runs npm.
use super::{snapshot::{self,Store},trace::{self,Install},report::{self,Report,cat},sh};
use crate::{state,os};
use std::collections::HashSet;

pub struct Rollback<'a>{
    pub store:&'a Store,pub report:&'a mut Report,pub trace:&'a mut Install,
    pub pre:Vec<u8>,pub target:Vec<u8>,pub backstop:bool,
    npm_project:bool,wrote:Option<bool>,compared:Vec<Vec<u8>>,different:Vec<u8>,refused:HashSet<Vec<u8>>,stepped:HashSet<Vec<u8>>,
}
impl<'a> Rollback<'a>{
    /// Construct before restoring any file: comparisons are against the
    /// command's snapshot, even when the rollback target is an older one.
    pub fn new(store:&'a Store,report:&'a mut Report,trace:&'a mut Install,pre:Vec<u8>,target:Vec<u8>,backstop:bool)->Self{
        let npm_project=["package.json","package-lock.json","node_modules/.package-lock.json"].iter().any(|n|sh::is_file(&store.project.join(n)));
        let mut out=Self{store,report,trace,pre,target,backstop,npm_project,wrote:None,compared:Vec::new(),different:Vec::new(),refused:HashSet::new(),stepped:HashSet::new()};
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
        let line=cat(&[b"refused ",kind,b" of ",sh::bytes(path),b": ",why]);self.report.say(&line);
        state::log_advisory(&self.store.home,&cat(&[b"post-verify REORG REFUSED: ",&line,b" -- project ",sh::bytes(&self.store.project)]));
        sh::append(&self.store.home.join("reorg.log"),&cat(&[b"[",os::utc_stamp(os::now().0).as_bytes(),b"] REORG REFUSED\n  Project: ",sh::bytes(&self.store.project),b"\n  ",&line,b"\n"]));
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
        if let Some(rel)=self.trace.records.first(){return(false,vec![cat(&[sh::bytes(&self.store.project),b"/",rel,b" is newer than the baseline taken before this command or has another inode"])])}
        if pre.is_empty(){return(false,vec![b"this rollback has no snapshot from before the command".to_vec()])}
        if !sh::is_file(&meta){return(false,vec![report::path(&meta)])}
        if !self.different.is_empty(){return(false,vec![cat(&[sh::bytes(&self.store.project),b"/",&self.different,b" differed from the pre-command snapshot ",pre,b" when this rollback began"])])}
        if self.wrote!=Some(false)||self.compared.is_empty(){return(false,vec![report::path(&self.store.path(pre,b"package.json"))])}
        for f in [&packages,&bins]{if !sh::is_file(f){return(false,vec![report::path(f)])}}
        let old=snapshot::sorted_lines(&packages);let mut now=trace::package_files(&tree,true);now.sort();
        if let Some(found)=now.iter().find(|n|!old.contains(n)){return(false,vec![cat(&[sh::bytes(&tree),b" lists ",found,b", which the pre-command snapshot ",pre,b" does not"])])}
        let old=snapshot::sorted_lines(&bins);let now=trace::listing(&tree.join(".bin"));
        if let Some(found)=now.iter().find(|n|!old.contains(n)){return(false,vec![cat(&[sh::bytes(&tree),b"/.bin lists ",found,b", which the pre-command snapshot ",pre,b" does not"])])}
        for f in [tree.join(".package-lock.json"),tree.clone()]{if trace::newer(&f,&meta,false,true){return(false,vec![cat(&[sh::bytes(&f),b" is newer than the pre-command snapshot ",pre])])}}
        if !sh::present(&tree){return(true,Vec::new())}
        let mut lines=vec![cat(&[b"kept ",sh::bytes(&tree)])];if sh::is_link(&tree){lines.push(report::path(&tree));}
        lines.push(self.trace.line.clone());
        lines.push(cat(&[b"when this rollback began, none of ",&self.compared.join(b", ".as_slice()),b" in ",sh::bytes(&self.store.project),b" differed from the pre-command snapshot ",pre]));
        lines.push(cat(&[sh::bytes(&tree),b" lists no package.json the pre-command snapshot ",pre,b" lacks"]));
        lines.push(cat(&[sh::bytes(&tree),b"/.bin lists no entry the pre-command snapshot ",pre,b" lacks"]));
        let hidden=tree.join(".package-lock.json");
        lines.push(if sh::exists(&hidden){cat(&[sh::bytes(&hidden),b" is not newer than the pre-command snapshot ",pre])}else{report::path(&hidden)});
        lines.push(cat(&[sh::bytes(&tree),b" is not newer than the pre-command snapshot ",pre]));(true,lines)
    }
    pub fn node_modules(&mut self){
        if !self.npm_project{return}
        let (kept,facts)=self.node_facts();
        if kept{if !facts.is_empty(){for l in facts{self.report.say(l);}self.trace.said=true;}return}
        let tree=self.store.project.join("node_modules");if !sh::present(&tree){return}
        for l in facts{self.report.say(l);}
        if sh::is_link(&tree){self.refuse(b"removal",&tree,&report::path(&tree));return}
        if !sh::is_dir(&tree){return}
        self.report.remove(&tree);
        for n in ["package.json","package-lock.json","npm-shrinkwrap.json"]{self.report.path(&self.store.project.join(n));}
        self.report.workspaces_key(&self.store.project);
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
        sh::append(&log,&cat(&[b"[",os::utc_stamp(os::now().0).as_bytes(),b"] ",log_head,&pre,b"\n  Project: ",sh::bytes(&self.store.project),b"\n  Reasons: ",reasons,b"\n  ",&snapshot_line,b"\n",&details]));
        if !snapshot_line.ends_with(b", a confirmed snapshot")&&!self.backstop{
            let inert=if self.report.inert.is_empty(){Vec::new()}else{cat(&[b"; ",&self.report.inert])};
            state::log_advisory(&self.store.home,&cat(&[b"post-verify REORG with no confirmed snapshot in ",sh::bytes(&self.store.project),b": ",&snapshot_line,&inert,b". Reasons: ",reasons]));
        }
        Ok(cat(&[head,b"\n\nDetected problems:\n",reasons,b"\n\n",&snapshot_line,b"\nWhat the rollback did and what it found:\n",&self.report.lines.join(&b'\n'),b"\n\n",&report::file(b"Details log",&log)]))
    }
}
