#!/usr/bin/env python3
"""Run e2e's two original direct fact rows and their native adapters.

The row bodies, assertions and oracle come from e2e.sh. Only the calls into
Bash product fact functions are replaced on the native side.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--core',required=True)
p.add_argument('--report',required=True)
a=p.parse_args()
root=Path(__file__).resolve().parents[2];source=(root/'scripts/test/e2e.sh').read_text()
spec=importlib.util.spec_from_file_location('adapter',Path(__file__).with_name('core-post-suite-adapt.py'))
adapter=importlib.util.module_from_spec(spec);spec.loader.exec_module(adapter)
blocks=[]
for start,end in [('nofile_meta=', 'pass "no record file gets no --ignore-scripts line, and advisory.log names the record"'),
                  ('unresolved_dir=', 'pass "a project directory that does not resolve is the reason, in the same words"')]:
    begin=source.index('\n'+start)+1;finish=source.index(end,begin)+len(end)
    blocks.append(source[begin:finish])
body='\n'.join(blocks)+'\n'
prefix='''#!/bin/bash
set -euo pipefail
ROOT_DIR="$ROOT"
tmp_root="$BOX"
source "$ROOT/scripts/test/lib/report-oracle.sh"
oracle_init "$BOX/oracle"
pass(){ printf 'ok - %s\\n' "$1"; }
fail(){ printf 'not ok - %s\\n' "$1" >&2; exit 1; }
'''
rows=[]
with tempfile.TemporaryDirectory(prefix='core-post-direct.') as temporary:
    box=Path(temporary).resolve();paired=box/'paired'
    for side in ['bash','rust']:
        if paired.exists():shutil.rmtree(paired)
        paired.mkdir();(paired/'state').mkdir()
        script=box/(side+'.sh')
        script.write_text(prefix+(adapter.direct_calls(body,Path(a.core).resolve()) if side=='rust' else body))
        result=subprocess.run(['bash',str(script)],env=dict(os.environ,ROOT=str(root),BOX=str(paired),SAFEDEPS_HOME=str(paired/'state')),capture_output=True,text=True)
        raw=paired/'nofile-advisory.log.raw'
        rows.append(dict(side=side,rc=result.returncode,stdout=result.stdout,stderr=result.stderr,
                         native_raw_advisory=raw.read_text() if raw.exists() else None))
report=dict(rows=rows,passed=all(r['rc']==0 for r in rows) and rows[0]['stdout']==rows[1]['stdout'] and rows[0]['stderr']==rows[1]['stderr'])
Path(a.report).write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report))
raise SystemExit(0 if report['passed'] else 1)
