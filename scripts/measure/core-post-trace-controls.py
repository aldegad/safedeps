#!/usr/bin/env python3
"""Check native walk faults at their operation, with counterfactual copies.

The delayed walk must cause a rollback checked by the existing report oracle.
A second copy keeps the delay but treats deadline failure as no trace; the
same rollback assertion must reject it. Clock tests retain observed ctimes
and use a Python integer-time walk independently of Rust. These supplement
the original bs_slow/bs_mix e2e rows; they do not verify native pre's choice of
baseline, which belongs to the pre component.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--archive',required=True)
p.add_argument('--core',required=True)
p.add_argument('--cargo',required=True)
p.add_argument('--run-dir',required=True)
a=p.parse_args()
root=Path(__file__).resolve().parents[2]
archive=Path(a.archive).resolve(strict=True);core=Path(a.core).resolve(strict=True)
cargo=Path(a.cargo).resolve(strict=True);run=Path(a.run_dir).resolve()
run.mkdir(parents=True,exist_ok=False)
spec=importlib.util.spec_from_file_location('fault_edits',Path(__file__).with_name('core-post-native-injections.py'))
fault_edits=importlib.util.module_from_spec(spec);spec.loader.exec_module(fault_edits)

def execute(argv,name,env=None):
    with (run/(name+'.log')).open('wb') as out:
        result=subprocess.run(argv,stdout=out,stderr=out,env=env)
    (run/(name+'.rc')).write_text(str(result.returncode)+'\n')
    return result.returncode

cores={}
for name in ['walk','walk-control','coarse']:
    target=run/name;target.mkdir()
    subprocess.run(['tar','xf',str(archive),'-C',str(target)],check=True)
    edits=[fault_edits.EDITS['walk' if name=='walk-control' else name]]
    if name=='walk-control':
        edits.append(('rust/src/post/trace.rs','Err(124)=>(true,cat(&[b"the walk of ",',
                      'Err(124)=>(false,cat(&[b"the walk of ",'))
    for relative,old,new in edits:
        path=target/relative;text=path.read_text()
        if text.count(old)!=1:raise SystemExit(name+': source edit is not unique')
        path.write_text(text.replace(old,new))
    (run/(name+'.mutation.json')).write_text(json.dumps(edits,indent=2)+'\n')
    rc=execute([str(cargo),'build','--manifest-path',str(target/'rust/Cargo.toml'),
                '--release','--locked','--offline','-j1'],name+'-build',
               dict(os.environ,SAFEDEPS_CORE_BUILD_KIND='checkout'))
    if rc:raise SystemExit(rc)
    cores[name]=target/'rust/target/release/safedeps-core'

faults=[sys.executable,str(root/'scripts/measure/core-post-faults.py'),'--side','rust']
rows=[]
for name,binary,fixture,expected in [
    ('unchanged',core,'trace-untraced',None),
    ('deadline',cores['walk'],'trace-deadline',None),
    ('deadline-control',cores['walk-control'],'trace-deadline','a walk past its deadline: the backstop rolls back'),
]:
    argv=faults+['--core',str(binary),'--only',fixture,'--report',str(run/(name+'.json'))]
    if expected:argv+=['--expect-assertion',expected]
    rc=execute(argv,name)
    rows.append(dict(name=name,expected_harness_rc=0,actual_harness_rc=rc,passed=rc==0))
    if rc:
        (run/'result.json').write_text(json.dumps(dict(rows=rows),indent=2)+'\n')
        raise SystemExit(rc)

def trace(binary,project,entry,name):
    request=dict(op='trace',path=str(project),entry=json.dumps(entry))
    (run/(name+'.input.json')).write_text(json.dumps(request,indent=2)+'\n')
    result=subprocess.run([str(binary),'post-probe'],input=json.dumps(request).encode(),capture_output=True)
    return dict(rc=result.returncode,stdout=result.stdout.decode(),stderr=result.stderr.decode())

with tempfile.TemporaryDirectory(prefix='core-post-clock.') as tmp:
    box=Path(tmp).resolve();project=box/'project';tree=project/'node_modules'
    (tree/'fixture').mkdir(parents=True)
    lock=project/'package-lock.json';lock.write_text('{}\n')
    (tree/'.package-lock.json').write_text('{}\n')
    leaf=tree/'fixture/observed';leaf.write_text('before\n')
    script=box/'facts.sh'
    script.write_text('''#!/bin/bash
set -eu
source "$ROOT/lib/gates/backstop-trace.sh"
for rel in package-lock.json node_modules/.package-lock.json node_modules; do
 printf '%s\\t%s\\t%s\\n' "$rel" "$(safedeps_tree_inode "$1/$rel")" "$(safedeps_tree_clock "$1/$rel")"
done
''')
    raw=subprocess.check_output(['bash',str(script),str(project)],env=dict(os.environ,ROOT=str(root),LC_ALL='C'),text=True)
    inodes={};clocks={}
    for line in raw.splitlines():
        name,inode,clock=line.split('\t');inodes[name]=inode;clocks[name]=clock
    # All lockfile clocks predate even the shifted baseline. This makes the
    # leaf walk, rather than a lockfile shortcut, own the observed result.
    second=time.time_ns()//10**9+4
    baseline_ns=second*10**9+200_000_000
    time.sleep(max(0,(baseline_ns+200_000_000-time.time_ns())/10**9))
    leaf.write_text('after\n')
    leaf_ns=leaf.stat().st_ctime_ns
    if not baseline_ns<leaf_ns<(second+1)*10**9:
        raise SystemExit('clock fixture missed its same-second window; no result claimed')
    baseline=box/'baseline';baseline.touch()
    entry=dict(baseline=str(baseline),resolution='seconds',inodes=inodes,clocks=clocks)
    clocks_after=subprocess.check_output(['bash',str(script),str(project)],env=dict(os.environ,ROOT=str(root),LC_ALL='C'),text=True)
    if raw!=clocks_after:raise SystemExit('clock fixture changed an entry field; no walk result claimed')
    observed=[dict(path=str(tree),ctime_ns=tree.stat().st_ctime_ns)]
    for parent,dirs,files in os.walk(tree):
        for name in dirs+files:
            path=Path(parent)/name
            observed.append(dict(path=str(path),ctime_ns=path.lstat().st_ctime_ns))
    receipt=dict(raw_entry_fields=raw,unchanged_entry_fields=clocks_after,observed=observed,
                 leaf_ctime_ns=leaf_ns,baseline_ns=baseline_ns,shifted_baseline_ns=baseline_ns-2*10**9)
    (run/'clock-observations.json').write_text(json.dumps(receipt,indent=2)+'\n')
    for name,base in [('same-second',baseline_ns),('shifted-two-seconds',baseline_ns-2*10**9)]:
        os.utime(baseline,ns=(base,base))
        if baseline.stat().st_mtime_ns!=base:raise SystemExit('fixture baseline precision changed')
        expected=[item['path'] for item in observed if item['ctime_ns']//10**9*10**9>base]
        result=trace(cores['coarse'],project,entry,name)
        passed=result['rc']==(0 if expected else 1) and not result['stderr']
        if expected:passed=passed and result['stdout'] in [path+' changed after the baseline taken before this command' for path in expected]
        else:passed=passed and result['stdout']==('no trace in '+str(project)+': neither npm lockfile nor node_modules there has another inode, neither lockfile changed after the record taken before this command, and nothing in node_modules changed after the baseline')
        rows.append(dict(name=name,expected_trace=bool(expected),independent_newer_paths=expected,
                         actual=result,passed=passed))
        if name=='same-second':
            # Removing the sole source edit restores nanosecond observations.
            # The same independent whole-second assertion must now fail.
            control=trace(core,project,entry,'precision-control')
            caught=(not expected and control['rc']==0 and not control['stderr']
                    and control['stdout']==str(leaf)+' changed after the baseline taken before this command')
            rows.append(dict(name='precision-control',expected_difference=['rc','stdout'],actual=control,
                             raw_matches_coarse=control==result,passed=caught))
report=dict(rows=rows,passed=all(row['passed'] for row in rows),native_pre_verified=False)
(run/'result.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report))
raise SystemExit(0 if report['passed'] else 1)
