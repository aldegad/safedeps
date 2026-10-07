#!/usr/bin/env python3
"""Compare the shared Yarn pattern expander with Bash's nullglob loop.

Only listing is tested here: the A-owned reader validates patterns and hashes
manifests. Compare physical paths as that reader does, retaining raw outputs
for review. Also exercise ordinary membership's node_modules exclusion.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--core',required=True)
p.add_argument('--report',required=True)
p.add_argument('--only',action='append',help='Repeat for a small set of exact patterns')
a=p.parse_args()
core=str(Path(a.core).resolve(strict=True))
root=Path(__file__).resolve().parents[2]
patterns=['packages/*','packages/a','missing/*','packages/[ab]','packages/?',
          'packages/.*','packages/*/','./packages/*','node_modules/*','*/item',
          'packages/{a,b}',r'packages/a\*',r'packages/\?',r'packages/a\b',
          r'packages/esc\*/*','linked/*','packages/[!a]','packages/[[:alpha:]]',
          r'packages/esc\*/item',r'packages/a\*?',r'packages/a\\?',
          r'packages/\.*',r'packages/[\?]',r'packages/[a\-c]',
          r'packages/[',r'packages/\[/*',r'packages/ab\/*',r'packages/ab\\/*']
shell='''#!/bin/bash
shopt -s nullglob
for dir in "$PROJECT"/${PATTERN}; do
  [[ -d "$dir" && -f "$dir/package.json" ]] || continue
  printf '%s\\0' "$dir"
done
'''
rows=[]
with tempfile.TemporaryDirectory(prefix='core-post-workspace-glob.') as temp:
    box=Path(temp).resolve();project=box/'project';project.mkdir()
    (project/'package.json').write_text('{}')
    for name in ['a','b','c','-','.hidden','{a,b}','a*','?',r'a\b','ab','ab/item','esc*/item','[/item',r'ab\/item']:
        path=project/'packages'/name;path.mkdir(parents=True,exist_ok=True)
        (path/'package.json').write_text('{}')
    (project/'packages/package.json').write_text('{}')
    for name in ['node_modules/item','ordinary/item','packages/no-manifest']:
        path=project/name;path.mkdir(parents=True)
        if name!='packages/no-manifest':(path/'package.json').write_text('{}')
    (project/'linked').symlink_to('packages')
    script=box/'nullglob.sh';script.write_text(shell)
    for pattern in patterns:
        if a.only and pattern not in a.only:continue
        env=dict(os.environ,PROJECT=str(project),PATTERN=pattern,LC_ALL='C')
        left=subprocess.run(['bash',str(script)],env=env,capture_output=True)
        request=dict(op='workspace-glob',path=str(project),pattern=pattern)
        right=subprocess.run([core,'post-probe'],input=json.dumps(request).encode(),env=env,capture_output=True)
        raw_left=[os.fsdecode(x) for x in left.stdout.split(b'\0') if x]
        try:raw_right=json.loads(right.stdout)
        except ValueError:raw_right=[]
        physical=lambda xs:sorted(os.path.realpath(x) for x in xs)
        same=left.returncode==right.returncode==0 and physical(raw_left)==physical(raw_right)
        rows.append(dict(pattern=pattern,same=same,reference=raw_left,core=raw_right,
                         reference_rc=left.returncode,core_rc=right.returncode,
                         reference_stderr=left.stderr.decode(),core_stderr=right.stderr.decode()))
        print('same' if same else 'DIFF',repr(pattern),flush=True)
    if not a.only:
        (project/'package.json').write_text(json.dumps(dict(workspaces=['*/item','node_modules/*'])))
        right=subprocess.run([core,'post-probe'],input=json.dumps(dict(op='workspaces',path=str(project))).encode(),capture_output=True)
        expected='ok\n'+str(project/'ordinary/item')+'\n'
        rows.append(dict(pattern='ordinary-members-exclusion',same=right.returncode==0 and right.stdout.decode()==expected,
                         expected=expected,core=right.stdout.decode(),core_rc=right.returncode))
report=dict(cases=len(rows),differences=sum(not r['same'] for r in rows),rows=rows)
Path(a.report).write_text(json.dumps(report,indent=2)+'\n')
raise SystemExit(0 if rows and report['differences']==0 else 1)
