#!/usr/bin/env python3
"""Run each selected native mutation with its positive and negative control.

Usage: report-mutations.sh --archive SOURCE.tar --core CORE --cargo CARGO
       --run-dir NEW_DIRECTORY [K Snap ...]
A missing anchor, failed build, failed baseline or wrong diagnostic is red.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

p=argparse.ArgumentParser(description=__doc__)
for arg in ('archive','core','cargo','run-dir'):p.add_argument('--'+arg,required=True)
p.add_argument('names',nargs='*')
a=p.parse_args()
root=Path(__file__).resolve().parents[3]
manifest=json.loads(Path(__file__).with_name('report-mutations.json').read_bytes())
by_name={r['name']:r for r in manifest['mutations']}
names=a.names or list(by_name)
if any(n not in by_name for n in names) or len(names)!=len(set(names)):p.error('unknown or repeated mutation')
run=Path(a.run_dir).resolve();run.mkdir(parents=True,exist_ok=False)
archive,core,cargo=[Path(x).resolve(strict=True) for x in (a.archive,a.core,a.cargo)]
rows=[]
receipt=dict(archive_sha256=hashlib.sha256(archive.read_bytes()).hexdigest(),
             core_sha256=hashlib.sha256(core.read_bytes()).hexdigest(),
             load_start=os.getloadavg(),nice=os.getpriority(os.PRIO_PROCESS,0),rows=rows)
for name in names:
    row=by_name[name]
    with (run/(name+'.log')).open('wb') as log:
        r=subprocess.run([sys.executable,str(root/row['harness']),'--archive',str(archive),
                          '--core',str(core),'--cargo',str(cargo),'--run-dir',str(run/name),
                          '--names',row['selector']],stdout=log,stderr=log)
    (run/(name+'.rc')).write_text(str(r.returncode)+'\n')
    rows.append(dict(name=name,rc=r.returncode,passed=r.returncode==0))
    receipt['load_end']=os.getloadavg()
    (run/'result.json').write_text(json.dumps(receipt,indent=2)+'\n')
    print(('ok - ' if r.returncode==0 else 'not ok - ')+name+': native source control',flush=True)
table=['mutation\tharness_rc\texpected_rejection_observed']
table += [str(r['name'])+'\t'+str(r['rc'])+'\t'+str(r['passed']).lower() for r in rows]
(run/'results.tsv').write_text('\n'.join(table)+'\n')
print('\n'.join(table),flush=True)
raise SystemExit(int(any(not r['passed'] for r in rows)))
