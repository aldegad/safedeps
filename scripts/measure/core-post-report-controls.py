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
}
names=a.names.split(',')
if not names or any(n not in cases for n in names):p.error('unknown control name')

def execute(argv,name,env=None):
    with (run/(name+'.log')).open('wb') as f:r=subprocess.run(argv,stdout=f,stderr=f,env=env)
    (run/(name+'.rc')).write_text(str(r.returncode)+'\n')
    return r.returncode

def fixture(kind,shape,binary,name,diagnostic=None):
    script='core-post-faults.py' if kind=='fault' else 'core-post-oracle.py'
    argv=[sys.executable,str(root/'scripts/measure'/script),'--core',str(binary),'--only',shape,'--report',str(run/(name+'.json'))]
    if kind=='fault':argv+=['--side','rust']
    if diagnostic:
        argv+=['--expect-oracle-text',diagnostic]
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
