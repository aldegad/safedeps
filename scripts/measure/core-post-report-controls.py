#!/usr/bin/env python3
"""Report source controls using the existing rollback and journal fixtures.

The original oracle checks every candidate message and log. A control counts
only when its hook exits zero and the oracle rejects the named false claim.
Each needed baseline fixture runs once before its source copies are built.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--archive',required=True)
p.add_argument('--core',required=True)
p.add_argument('--cargo',required=True)
p.add_argument('--run-dir',required=True)
p.add_argument('--names',default='NoCheck,Snap,Head,Prose,LogOnly,Reasons,Silent,Cause,JOmit')
a=p.parse_args()
archive=Path(a.archive).resolve(strict=True);core=Path(a.core).resolve(strict=True);cargo=Path(a.cargo).resolve(strict=True)
root=Path(__file__).resolve().parents[2];run=Path(a.run_dir).resolve();run.mkdir(parents=True,exist_ok=False)
# kind, fixture, source, old, new, required original-oracle diagnostic
cases={
 'NoCheck':('fault','restore-readonly','report.rs',
   'pub fn path(&mut self, p: &Path) { self.say(path(p)); }',
   'pub fn path(&mut self, p: &Path) { self.say(cat(&[sh::bytes(p),b" exists"])); }',
   'the stated fact does not hold on disk'),
 'Snap':('fault','restore-readonly','rollback.rs',
   'if !self.target.is_empty()&&self.target==confirmed{','if true{',
   'the confirmed record of the project does not name this snapshot'),
 'Head':('fault','restore-readonly','run.rs',
   'b"safedeps: suspicious dependency change detected. A rollback ran.".to_vec()',
   '"safedeps: suspicious dependency change detected — rolled back to the last confirmed safe snapshot.".as_bytes().to_vec()',
   'a line before any headline'),
 'Prose':('fault','restore-readonly','rollback.rs',
   '        self.report.changed_nothing();',
   '        self.report.changed_nothing();self.report.say(cat(&[b"npm rebuild was not run: ",sh::bytes(&self.store.project)]));',
   'effect-gate prose in a block it is not said in'),
 'LogOnly':('fault','restore-readonly','rollback.rs',
   '&snapshot_line,b"\\n",&details]));',
   '&snapshot_line,b"\\n  the rejected package\'s install scripts did not run\\n",&details]));',
   'the reorg.log entries this hook appended are not the ones its message calls for'),
 'Reasons':('fault','restore-readonly','rollback.rs',
   'b"\\n\\nDetected problems:\\n",reasons,b"\\n\\n"',
   'b"\\n\\nDetected problems:\\n",reasons,b"; node_modules was restored from the confirmed snapshot\\n\\n"',
   'the reorg.log entries this hook appended are not the ones its message calls for'),
 'Silent':('fault','restore-readonly','rollback.rs',
   '        self.report.remove(&tree);','        sh::rm_rf(&tree);',
   'this entry of the project changed on disk, and no step line names it'),
 'Cause':('journal','gone-staged','journal.rs',
   '&journal_line,b"\\nOwner: ",&fact,b"\\n",&snapshot_line',
   '&journal_line,b"\\nOwner: ",&fact,b"\\nThe rollback was cut off, most likely by the runtime\'s timeout.\\n",&snapshot_line',
   'a line outside the grammar'),
 'JOmit':('journal','gone-staged','journal.rs',
   'let mut lines=vec![report::path(&project.join("node_modules"))];',
   'let mut lines=Vec::new();',
   'an unfinished-rollback report with no node_modules line'),
 'Default':('record-unstated','restore-readonly','report.rs',
   'b"unstated" => Err(2)', 'b"unstated" => Ok(NONE.to_vec())',
   "an --ignore-scripts line, and the pre-guard's record does not state it as a version 2 record"),
 'Version':('record-v1','restore-readonly','report.rs',
   'if !jv::eq(jv::field(&m, "record")?, &jv::num(2)) { b"unstated" }',
   'if false { b"unstated" }',
   "an --ignore-scripts line, and the pre-guard's record does not state it as a version 2 record"),
 'XStr2':('record-string-version','restore-readonly','report.rs',
   'if !jv::eq(jv::field(&m, "record")?, &jv::num(2)) { b"unstated" }',
   'if jv::tostring(jv::field(&m, "record")?) != b"2".to_vec() { b"unstated" }',
   "an --ignore-scripts line, and the pre-guard's record does not state it as a version 2 record"),
 'F2':('record-asked','restore-readonly','report.rs',
   'if jv::eq(jv::path(v, &["tool_input", "command"])?, jv::field(&m, "updated_command")?) { b"added" }',
   'if true { b"added" }',
   "the pre-guard's record says it rewrote the command: true; the command this hook received is the one it wrote: false"),
 'P2':('fault','confirm-link','report.rs',
   '        match inert(meta, input) {\n            Err(rc) => { inert_unsaid',
   '        let extended=cat(&[fact,b". Rebuild there yourself once the link is gone"]);let fact=extended.as_slice();\n        match inert(meta, input) {\n            Err(rc) => { inert_unsaid',
   'the reason is not a fact form that holds on disk'),
 'R3':('fault','confirm-link','report.rs',
   'b" is a symbolic link to ", &link_target(path)])',
   'b" is a symbolic link to ", &link_target(path), b", and npm follows it"])',
   'the reason is not a fact form that holds on disk'),
 'Bypass':('fault','confirm-link','npm.rs',
   'report.rebuild(home,&meta,input,&cat(&[b"did not run npm rebuild: ",&why]));',
   'report.rebuild(home,&meta,input,&cat(&[b"did not run npm rebuild: ",&why]));report.say(b"The verified packages\' install scripts have not run");',
   'a line outside the grammar'),
 'RefuseSilent':('fault','restore-link','rollback.rs',
   'let line=report::refused(kind,path,why);self.report.say(&line);', 'let line=report::refused(kind,path,why);',
   'the reorg.log entries this hook appended are not the ones its message calls for'),
 'LogSilent':('fault','confirm-clean','run.rs',
   'if report.lines.is_empty() { return Ok(None) }',
   'if report.lines.is_empty() { sh::append(&call.store.home.join("reorg.log"),b"[2001-02-03T04:05:06Z] CONFIRM warnings\\n  restored phantom\\n");return Ok(None) }',
   'reorg.log grew by '),
 'F4':('fault','backstop-rollback','rollback.rs',
   'if !self.backstop{self.report.inert(&self.store.home,&self.store.meta(),input);}',
   'self.report.inert(&self.store.home,&self.store.meta(),input);',
   'a hook whose record states no --ignore-scripts line said so in advisory.log 1 times, not 0'),
 'NoDir':('fault','pending-nodir','call.rs',
   'if !dir.is_empty() { project = sh::p(&dir); }',
   'if !dir.is_empty() { project = sh::p(&dir); } else { project = std::env::current_dir().unwrap(); }',
   'a step line names a path outside'),
 'RecordHash':('fault','pending-hash','call.rs',
   'let mut store = Store::new(home.into(), project, snapshot_id);',
   'let mut store = Store::new(home.into(), project, snapshot_id);let recorded=string(&current,"dir_hash");if !recorded.is_empty(){store.hash=String::from_utf8_lossy(&recorded).into_owned();}',
   'the confirmed record of the project does not name this snapshot'),
 'IdFallsBackToKey':('fault','pending-fallback','call.rs',
   'sh::is_file(&p).then_some(p)',
   'sh::is_file(&p).then_some(p).or_else(|| fs::read_dir(home.join("pending")).ok()?.filter_map(Result::ok).map(|e|e.path()).find(|p|sh::basename(sh::bytes(p)).starts_with(format!("{}__",key).as_bytes())))',
   "the hook consumed the record of the call '', and this call is 'fault-call'"),
 'Legacy':('fault','pending-legacy','call.rs',
   '        let mut project = cwd;\n',
   '        let mut project = cwd;\n        if pending.is_none() && sh::is_file(&home.join("current_snapshot_id")){snapshot_id=sh::cat_captured(&home.join("current_snapshot_id")).unwrap_or_default();if let Some(p)=sh::cat_captured(&home.join("current_project_dir")){project=sh::p(&p);}record=Record::Install;sh::rm_f(&home.join("current_snapshot_id"));sh::rm_f(&home.join("current_project_dir"));}\n',
   'the hook consumed a record a pre-#5 pre-guard left, which belongs to no call'),
 'CodexEverywhere':('fault','registry-claude','npm.rs',
   'if inert==report::NONE&&codex{', 'if inert==report::NONE{',
   'the warning says safedeps cannot add --ignore-scripts on Codex, of a claude call'),
 'TraceNever':('assertion','trace-lock','trace.rs',
   '    for (i,rel) in [RECORDS[0],RECORDS[1],"node_modules"].iter().enumerate() {',
   '    return(false,b"the mutant checked nothing".to_vec());\n    for (i,rel) in [RECORDS[0],RECORDS[1],"node_modules"].iter().enumerate() {',
   'an install the pre-guard did not read: the backstop rolls back'),
 'TraceAlways':('assertion','trace-untraced','trace.rs',
   'if entry.is_empty() {return (true,', 'if true {return (true,',
   'a grep right after a pull outside the gate: the backstop says nothing'),
 'WalkOff':('assertion','trace-tree','trace.rs',
   '''    let rc=walk(&tree,usize::MAX,true,Some(until),|p,m|{
        if (m.ctime(),m.ctime_nsec())>(b.mtime(),b.mtime_nsec()){found=sh::bytes(p).to_vec();true}else{false}
    });''',
   '    let rc:Result<(),WalkFailure>=Ok(());',
   'a write only into node_modules is a trace'),
 'LinkLstat':('assertion','trace-link','trace.rs',
   'os::tree_clock(&file).as_bytes()!=lines[5+i]',
   'os::file_clock(&file,b\'c\',false).as_bytes()!=lines[5+i].split(|b|*b==b\'|\').next().unwrap_or(b"")',
   'a write through a linked lockfile is a trace'),
}
# Keep these whole branch replacements tied to the checked-in source. Each
# anchor must select exactly one branch before any archive mutation is made.
call_source=(root/'rust/src/post/call.rs').read_text()
for name,shape,start,end,diagnostic in [
 ('Gone','pending-gone','        if record == Record::Install && !sh::is_file(&store.meta()) {',
  '        if matches!(record, Record::Unread',
  'a pending state whose snapshot has no meta file was consumed, and advisory.log names it 0 times, not once'),
 ('Empty','pending-empty','            if record == Record::Install && snapshot_id.is_empty() {',
  '        } else if !found',
  'a record that names no snapshot was consumed, and advisory.log names it 0 times, not once'),
]:
    if call_source.count(start)!=1 or call_source.count(end)!=1:raise SystemExit(name+': branch anchor is not unique')
    old=call_source[call_source.index(start):call_source.index(end)]
    cases[name]=('fault',shape,'call.rs',old,start+' return Ok(None); }\n',diagnostic)
not_object='''                record = Record::Unread;
                state::log_advisory(home, &cat(&[b"post-verify: the pre-guard's record ", sh::bytes(p), b" is not one JSON object; this hook set the record aside"]));'''
cases['NotObject']=('fault','pending-object','call.rs',not_object,
    '                sh::rm_f(p);return Ok(None);',
    'a record that is not one JSON object was consumed, and advisory.log names it 0 times, not once')
names=a.names.split(',')
if not names or any(n not in cases for n in names):p.error('unknown control name')

def execute(argv,name,env=None):
    with (run/(name+'.log')).open('wb') as f:r=subprocess.run(argv,stdout=f,stderr=f,env=env)
    (run/(name+'.rc')).write_text(str(r.returncode)+'\n')
    return r.returncode

def fixture(kind,shape,binary,name,diagnostic=None):
    script='core-post-oracle.py' if kind=='journal' else 'core-post-faults.py'
    argv=[sys.executable,str(root/'scripts/measure'/script),'--core',str(binary),'--only',shape,'--report',str(run/(name+'.json'))]
    if kind!='journal':argv+=['--side','rust']
    if kind.startswith('record-'):argv+=['--meta-shape',kind[len('record-'):]]
    if diagnostic:
        argv+=['--expect-assertion' if kind=='assertion' else '--expect-oracle-text',diagnostic]
        if kind=='journal':argv+=['--expect-difference']
    return execute(argv,name)

for kind,shape in sorted(set(cases[name][:2] for name in names)):
    if fixture(kind,shape,core,'baseline-'+kind+'-'+shape):
        raise SystemExit('candidate fixture failed; no mutant result claimed')
rows=[]
for name in names:
    kind,shape,relative,old,new,diagnostic=cases[name]
    target=run/name;target.mkdir();subprocess.run(['tar','xf',str(archive),'-C',str(target)],check=True)
    path=target/'rust/src/post'/relative;text=path.read_text()
    if text.count(old)!=1:raise SystemExit(name+': mutation text is not unique')
    path.write_text(text.replace(old,new))
    (run/(name+'.mutation.json')).write_text(json.dumps(dict(file='rust/src/post/'+relative,old=old,new=new),indent=2)+'\n')
    build=execute([str(cargo),'build','--manifest-path',str(target/'rust/Cargo.toml'),'--release','--locked','--offline','-j1'],name+'-build',dict(os.environ,SAFEDEPS_CORE_BUILD_KIND='checkout'))
    row=dict(name=name,fixture=shape,build_rc=build,expected_diagnostic=diagnostic,passed=False)
    if build==0:
        rc=fixture(kind,shape,target/'rust/target/release/safedeps-core',name,diagnostic)
        row.update(control_rc=rc,passed=rc==0)
    rows.append(row);print(name,'caught' if row['passed'] else 'FAIL',flush=True)
(run/'result.json').write_text(json.dumps(dict(rows=rows),indent=2)+'\n')
raise SystemExit(0 if rows and all(r['passed'] for r in rows) else 1)
