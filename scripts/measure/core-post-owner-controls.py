#!/usr/bin/env python3
"""Build native owner failure fixtures and false-report controls on copies.

Darwin only: incomplete API responses (zero/short) and a wrong returned pid
exercise the real decoder checks. The fixture owns that response evidence.
False ps wording, false status, and an altered incident then must fail in the
single original report oracle. Hook/build failure is never an oracle pass.
"""
import argparse
import json
import os
from pathlib import Path
import platform
import subprocess
import sys

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--archive',required=True)
p.add_argument('--core',required=True)
p.add_argument('--cargo',required=True)
p.add_argument('--run-dir',required=True)
a=p.parse_args()
if platform.system()!='Darwin':p.error('these source injections target the Darwin native query')
archive=Path(a.archive).resolve(strict=True);core=Path(a.core).resolve(strict=True);cargo=Path(a.cargo).resolve(strict=True)
run=Path(a.run_dir).resolve();run.mkdir(parents=True,exist_ok=False)
root=Path(__file__).resolve().parents[2];harness=root/'scripts/measure/core-post-owner-oracle.py'

def execute(argv,stem,env=None):
    with (run/(stem+'.log')).open('wb') as out:result=subprocess.run(argv,env=env,stdout=out,stderr=out)
    (run/(stem+'.rc')).write_text(str(result.returncode)+'\n')
    return result.returncode

native_call='unsafe{proc_pidinfo(pid,3,1,&mut b as *mut _ as *mut _,size)}'
process='rust/src/post/process.rs';journal='rust/src/post/journal.rs'
zero=(process,native_call,'0')
short=(process,native_call,'(size-8)')
wrong_pid=(process,'    if b.pid!=pid as u32','    b.pid=b.pid.wrapping_add(1);\n    if b.pid!=pid as u32')
cases=[
    ('zero','query-zero',[zero],None),
    ('short','query-short',[short],None),
    ('wrong-pid','wrong-owner',[wrong_pid],None),
    ('false-ps','query-zero',[zero,(process,'native process query supplied no usable owner data for pid ',
          'ps gives no start time for pid ')],'a native owner report claims a ps observation'),
    ('false-status','stopped',[(process,'b" is stopped (process state ",','b" is stopped (process state X",')],
          'the native owner status differs from the independent process observation'),
    ('false-incident','query-zero',[zero,(journal,'            let journal_line=cat(',
          '            if let Some(Value::Obj(mut record))=jv::read_one_object(&incident){jv::set(&mut record,b"pid".to_vec(),jv::s(b"1"));let _=fs::write(&incident,jv::dump(&Value::Obj(record)));}\n            let journal_line=cat(')],
          'the native owner incident differs from the recorded journal'),
]
print('start:',subprocess.check_output(['uptime'],text=True).strip(),flush=True)
baseline=execute([sys.executable,str(harness),'--core',str(core),'--report',str(run/'baseline.json')],'baseline')
if baseline:raise SystemExit('unmodified native owner fixtures failed; no source copies built')
rows=[]
for name,fixture,edits,diagnostic in cases:
    target=run/name;target.mkdir();subprocess.run(['tar','xf',str(archive),'-C',str(target)],check=True)
    for relative,old,new in edits:
        path=target/relative;text=path.read_text()
        if text.count(old)!=1:raise SystemExit(name+': source edit does not occur exactly once')
        path.write_text(text.replace(old,new))
    (run/(name+'.mutation.json')).write_text(json.dumps(edits,indent=2)+'\n')
    build=execute([str(cargo),'build','--manifest-path',str(target/'rust/Cargo.toml'),'--release','--locked','--offline','-j1'],
                  name+'-build',dict(os.environ,SAFEDEPS_CORE_BUILD_KIND='checkout'))
    row=dict(name=name,fixture=fixture,build_rc=build,expected_diagnostic=diagnostic,passed=False)
    if build==0:
        argv=[sys.executable,str(harness),'--core',str(target/'rust/target/release/safedeps-core'),
              '--only',fixture,'--report',str(run/(name+'.json'))]
        if diagnostic:argv+=['--expect-oracle-text',diagnostic]
        rc=execute(argv,name);row.update(control_rc=rc,passed=rc==0)
    rows.append(row);print(name,'ok' if row['passed'] else 'FAIL',flush=True)
(run/'result.json').write_text(json.dumps(dict(baseline_rc=baseline,rows=rows),indent=2)+'\n')
print('end:',subprocess.check_output(['uptime'],text=True).strip(),flush=True)
raise SystemExit(0 if rows and all(r['passed'] for r in rows) else 1)
