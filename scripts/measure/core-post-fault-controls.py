#!/usr/bin/env python3
"""Four report-mutations controls at real I/O failures, on archive copies.

The unmodified core must pass the permission fixtures first. Each
source mutant then must build, run its hook successfully, and fail at its
specific existing report-oracle diagnostic. A build failure or missed
injection never counts as a caught mutation. Run on a remote build host.
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
p.add_argument('--names',default='Unread,K,Lie,Kept')
a=p.parse_args()
archive=Path(a.archive).resolve(strict=True)
core=Path(a.core).resolve(strict=True)
cargo=Path(a.cargo).resolve(strict=True)
run=Path(a.run_dir).resolve();run.mkdir(parents=True,exist_ok=False)
root=Path(__file__).resolve().parents[2]
harness=root/'scripts/measure/core-post-faults.py'
mutation={
    'Unread':('unread-meta',
        'let m = jv::read_one_object(meta).ok_or(1)?;',
        'let Some(m) = jv::read_one_object(meta) else { return Ok(NONE.to_vec()) };',
        "an --ignore-scripts line from a hook whose read of the pre-guard's record failed"),
    'K':('remove-readonly',
        'b"; ", &path(p)]));',
        'b"; ", &path(p), b", with whatever this install wrote in it"]));',
        'the path is gone, or the fact names another path'),
    'Lie':('remove-readonly',
        'if sh::present(p) { self.say(cat(&[b"not removed ",',
        'if false { self.say(cat(&[b"not removed ",',
        'the path is still there'),
    'Kept':('remove-readonly',
        'self.say(cat(&[b"not removed ", sh::bytes(p), b": ", &Outcome::Io(result).describe(Action::Removal,Form::Action), b"; ", &path(p)]));',
        'self.say(cat(&[b"kept ", sh::bytes(p)]));',
        'kept, right after a reason to remove it'),
}
names=a.names.split(',')
if not names or any(n not in mutation for n in names):p.error('unknown mutation name')

def execute(argv,stem,env=None):
    with (run/(stem+'.log')).open('wb') as log:
        result=subprocess.run(argv,env=env,stdout=log,stderr=log)
    (run/(stem+'.rc')).write_text(str(result.returncode)+'\n')
    return result.returncode

print('start:',subprocess.check_output(['uptime'],text=True).strip(),flush=True)
baseline=execute([sys.executable,str(harness),'--core',str(core),'--report',str(run/'baseline.json')],'baseline')
if baseline:
    raise SystemExit('unmodified fixture run failed; no mutants were built')
rows=[]
env=dict(os.environ,SAFEDEPS_CORE_BUILD_KIND='checkout')
for name in names:
    target=run/name;target.mkdir()
    subprocess.run(['tar','xf',str(archive),'-C',str(target)],check=True)
    fixture,old,new,diagnostic=mutation[name]
    source=target/'rust/src/post/report.rs';text=source.read_text()
    if text.count(old)!=1:raise SystemExit(name+': mutation source does not occur exactly once')
    source.write_text(text.replace(old,new))
    (run/(name+'.mutation.json')).write_text(json.dumps(dict(file='rust/src/post/report.rs',old=old,new=new),indent=2)+'\n')
    build=execute([str(cargo),'build','--manifest-path',str(target/'rust/Cargo.toml'),
                   '--release','--locked','--offline','-j1'],name+'-build',env)
    row=dict(name=name,fixture=fixture,build_rc=build,expected_diagnostic=diagnostic,passed=False)
    if build==0:
        rc=execute([sys.executable,str(harness),'--core',str(target/'rust/target/release/safedeps-core'),
                    '--only',fixture,'--side','rust','--expect-oracle-text',diagnostic,
                    '--report',str(run/(name+'.json'))],name)
        row.update(control_rc=rc,passed=rc==0)
    rows.append(row)
    print(name,'caught' if row['passed'] else 'FAIL',flush=True)
report=dict(baseline_rc=baseline,mutations=rows,failures=sum(not row['passed'] for row in rows))
(run/'result.json').write_text(json.dumps(report,indent=2)+'\n')
print('end:',subprocess.check_output(['uptime'],text=True).strip(),flush=True)
raise SystemExit(0 if rows and report['failures']==0 else 1)
