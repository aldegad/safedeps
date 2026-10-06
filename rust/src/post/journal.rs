//! Write intent before rollback, clear only after its report is durable.
use super::{jv,sh,report::{self,cat},snapshot,process};
use crate::{json::Value,state,os,md5,ledger};
use std::{fs,path::{Path,PathBuf}};

fn configured(name:&str,default:PathBuf)->PathBuf{std::env::var_os(name).filter(|s|!s.is_empty()).map(PathBuf::from).unwrap_or(default)}
pub struct Journal{pub home:PathBuf,pub dir:PathBuf,pub incidents:PathBuf}
impl Journal{
    pub fn new(home:&Path)->Self{Self{home:home.into(),dir:configured("SAFEDEPS_JOURNAL_DIR",home.join("rollback-journal")),incidents:configured("SAFEDEPS_INCIDENT_DIR",home.join("rollback-incidents"))}}
    pub fn path(&self,id:&[u8])->PathBuf{sh::p(&cat(&[sh::bytes(&self.dir),b"/",id,b".json"]))}
    pub fn open(&self,id:&[u8],project:&Path,snap:&[u8],reasons:&[u8],stage:&[u8])->Result<(),()> {
        if !sh::mkdir_p(&self.dir){return Err(())}
        let v=jv::obj(vec![("journal_id",jv::s(id)),("project_dir",jv::s(sh::bytes(project))),("rollback_snapshot",jv::s(snap)),("reasons",jv::s(reasons)),
            ("stage",jv::s(stage)),("opened_at",jv::s(os::utc_stamp(os::now().0).as_bytes())),("pid",jv::s(std::process::id().to_string().as_bytes()))]);
        state::write_state_file(&self.path(id),&jv::dump(&v)).map_err(|_|())
    }
    pub fn stage(&self,id:&[u8],stage:&[u8])->Result<(),()> {
        let file=self.path(id);if !sh::is_file(&file){return Ok(())}
        let Some(st)=jv::read_file(&file)else{return Ok(())};if st.failed{return Ok(())}
        let mut lines=Vec::new();
        for v in st.values{
            let mut o=match v{Value::Obj(o)=>o,Value::Null=>Vec::new(),_=>return Ok(())};
            jv::set(&mut o,b"stage".to_vec(),jv::s(stage));jv::set(&mut o,b"stage_at".to_vec(),jv::s(os::utc_stamp(os::now().0).as_bytes()));lines.push(jv::dump(&Value::Obj(o)));
        }
        state::write_state_file(&file,&lines.join(&b'\n')).map_err(|_|())
    }
    pub fn close(&self,id:&[u8]){sh::rm_f(&self.path(id));}
    fn project_facts(&self,project:&Path,snap:&[u8])->Vec<Vec<u8>>{
        let mut lines=vec![report::path(&project.join("node_modules"))];
        let list=snapshot::path(&self.home,snap,b"monitored_files.list");
        if !sh::is_file(&list){lines.push(cat(&[b"the snapshot ",snap,b" has no list of monitored files"]));return lines}
        for name in snapshot::sorted_lines(&list).into_iter().filter(|n|!n.is_empty()){
            let stored=snapshot::path(&self.home,snap,&snapshot::filename(&name));let live=project.join(sh::p(&name));
            if sh::is_link(&live){lines.push(report::path(&live));}
            else if sh::is_file(&stored){
                if !sh::exists(&live){lines.push(cat(&[sh::bytes(&live),b" does not exist; the snapshot ",snap,b" has it"]));}
                else if !sh::same_bytes(&stored,&live){lines.push(cat(&[sh::bytes(&live),b" differs from the snapshot ",snap]));}
            }else if sh::is_file(&sh::p(&cat(&[sh::bytes(&stored),b".missing"])))&&sh::exists(&live){lines.push(cat(&[sh::bytes(&live),b" exists; the snapshot ",snap,b" recorded it as absent"]));}
        }lines
    }
    fn snapshot_line(&self,project:&Path,snap:&[u8])->Vec<u8>{
        let mut line=cat(&[b"Rollback snapshot: ",snap]);if !project.is_absolute(){return line}
        let confirmed=snapshot::confirmed_unlocked(&self.home,&md5::hex(sh::bytes(project)));
        line.extend_from_slice(if !confirmed.is_empty()&&confirmed==snap{b", a confirmed snapshot"}else{b"; no confirmed snapshot names it"});line
    }
    pub fn unfinished(&self)->Vec<u8>{
        let mut entries:Vec<_>=fs::read_dir(&self.dir).into_iter().flatten().filter_map(Result::ok).map(|e|e.path())
            .filter(|p|sh::is_file(p)&&sh::basename(sh::bytes(p)).ends_with(b".json")&&!sh::basename(sh::bytes(p)).starts_with(b".")).collect();
        entries.sort();let mut reports=Vec::new();let reorg=self.home.join("reorg.log");
        for entry in entries{
            let st=jv::read_file(&entry).unwrap_or(jv::Stream{values:Vec::new(),failed:true});
            let field=|key:&str,default:&[u8],on_error:bool|{
                let (mut lines,rc)=jv::each(&st,|v|{let x=jv::field(v,key)?;Ok(if jv::truthy(x){vec![jv::tostring(x)]}else if default.is_empty(){Vec::new()}else{vec![default.to_vec()]})});
                if rc!=0&&on_error{lines.push(default.to_vec());}jv::captured(&lines)
            };
            let pid=field("pid",b"",false);let opened=field("opened_at",b"",false);
            let (owner,fact)=process::owner(&pid,&opened);if owner==0{continue}
            let id=field("journal_id",b"unknown",true);let project=sh::p(&field("project_dir",b"unknown",true));
            let snap=field("rollback_snapshot",b"unknown",true);let reasons=field("reasons",b"unrecorded",true);
            let stage=field("stage",b"unknown",true);let opened=field("opened_at",b"unknown",true);let stage_at=field("stage_at",b"",false);
            let mut detail=Vec::new();
            if !stage_at.is_empty(){
                detail=cat(&[b", entered ",&stage_at]);
                if let (Some(o),Some(s))=(std::str::from_utf8(&opened).ok().and_then(ledger::epoch),std::str::from_utf8(&stage_at).ok().and_then(ledger::epoch)){
                    if s>=o{detail.extend(cat(&[" — ".as_bytes(),(s-o).to_string().as_bytes(),b"s into the rollback"]));}
                }
            }
            let incident=sh::p(&cat(&[sh::bytes(&self.incidents),b"/",&id,b".json"]));
            sh::mkdir_p(&self.incidents);if fs::rename(&entry,&incident).is_err(){sh::rm_f(&entry);}
            let journal_line=cat(&[b"Journal: ",&id,b", opened ",&opened,b"; last recorded stage ",&stage,&detail]);
            let snapshot_line=self.snapshot_line(&project,&snap);let incident_line=report::file(b"Incident record",&incident);
            let log_head=if owner==2{b"REORG STOPPED".as_slice()}else{b"REORG INTERRUPTED"};
            let log=cat(&[b"[",os::utc_stamp(os::now().0).as_bytes(),b"] ",log_head,b"\n  ",&journal_line,b"\n  Owner: ",&fact,b"\n  Project: ",sh::bytes(&project),b"\n  ",&snapshot_line,b"\n  Reasons: ",&reasons,b"\n  ",&incident_line,b"\n"]);
            sh::append(&reorg,&log);
            reports.push(cat(&[b"safedeps: a rollback of ",sh::bytes(&project),if owner==2{b" has not finished."}else{b" did not finish."},b"\n\n",
                &journal_line,b"\nOwner: ",&fact,b"\n",&snapshot_line,b"\nRecorded reasons:\n",&reasons,b"\n\nChecked at the time of this report:\n",
                &self.project_facts(&project,&snap).join(&b'\n'),b"\n\n",&incident_line,b"\n",&report::file(b"Rollback log",&reorg),b"\n"]));
        }
        jv::captured(&reports)
    }
}
