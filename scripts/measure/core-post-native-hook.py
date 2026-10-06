#!/usr/bin/env python3
"""Archive e2e adapter: inject failures where the native operations run.

Selection uses the original fixture's directory or shim name. These switches
belong to this measurement entry only; the product has no test environment.
Every injection writes a reach receipt before invoking the selected core.
"""
import argparse
import json
import os
from pathlib import Path
import stat
import subprocess
import sys

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--core',required=True)
p.add_argument('--walk-core',required=True)
p.add_argument('--owner-core',required=True)
p.add_argument('--coarse-core',required=True)
p.add_argument('--receipts',required=True)
a=p.parse_args()
raw=sys.stdin.buffer.read()
payload=json.loads(raw)
project=Path(payload.get('cwd',''))
call=Path(os.environ['ORACLE_CALL'])
(call/'native-owner-source').touch()
name=project.name
selected=a.core
restore=[]
receipt=None
if name.startswith('markread-wt.'):
    if os.geteuid()==0:raise SystemExit('native permission fixture cannot run as root')
    home=Path(os.environ['SAFEDEPS_HOME'])
    records=[]
    for path in (home/'pending').glob('*.json'):
        try:r=json.loads(path.read_text())
        except (ValueError,OSError):continue
        if isinstance(r.get('project_dir'),str) and Path(r['project_dir']).resolve()==project.resolve():records.append(r)
    if len(records)!=1:raise SystemExit('markread requires exactly one fixture pending record')
    meta=home/'snapshots'/(records[0]['snapshot_id']+'_meta.json')
    restore.append((meta,stat.S_IMODE(meta.stat().st_mode)));meta.chmod(0)
    (call/'record-unread').touch();receipt=dict(fixture='markread',operation='chmod000',path=str(meta))
elif name.startswith('twoobj-wt.'):
    (call/'record-unread').touch();receipt=dict(fixture='twoobj',operation='fixture already holds two JSON objects')
elif name in ['cpfail-wt','cpgone-wt','rmfail-wt']:
    if os.geteuid()==0:raise SystemExit('native permission fixture cannot run as root')
    target=project/'package-lock.json' if name=='cpfail-wt' else project if name=='cpgone-wt' else project/'node_modules/installed-package'
    restore.append((target,stat.S_IMODE(target.stat().st_mode)))
    target.chmod(0o444 if name=='cpfail-wt' else 0o555)
    receipt=dict(fixture=name,operation='permission fault',path=str(target))
elif name=='bs-slow-wt':
    selected=a.walk_core;receipt=dict(fixture='bs_slow',operation='archive native walk delay',core=selected)
elif name=='bs-mix-wt':
    selected=a.coarse_core;receipt=dict(fixture='bs_mix',operation='archive native node ctime rounded to seconds',core=selected)
elif any(Path(part).name=='ps-empty-bin' for part in os.environ.get('PATH','').split(os.pathsep)):
    selected=a.owner_core
    record=json.loads((Path(os.environ['SAFEDEPS_HOME'])/'rollback-journal/test-forms.json').read_text())
    (call/'native-query-failure.json').write_text(json.dumps(dict(pid=record['pid'],expected_bytes=136,returned_bytes=0)))
    receipt=dict(fixture='owner-empty',operation='archive native query returns zero',core=selected)
if receipt:
    with open(a.receipts,'a') as f:f.write(json.dumps(receipt)+'\n')
try:
    result=subprocess.run([selected,'post'],input=raw)
    raise SystemExit(result.returncode if result.returncode>=0 else 128-result.returncode)
finally:
    for path,mode in restore:
        if path.exists():path.chmod(mode)
