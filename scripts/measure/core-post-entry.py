#!/usr/bin/env python3
"""Check the public post entry and stale-source record preservation on a copy.

The core must be built in the supplied archive tree. This changes one source
comment and restores its exact bytes in finally; never run on a worktree.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--tree',required=True)
p.add_argument('--report',required=True)
a=p.parse_args()
tree=Path(a.tree).resolve(strict=True)
if (tree/'.git').exists():p.error('requires an archive, never a git worktree')
core=tree/'rust/target/release/safedeps-core'
source=tree/'rust/src/post.rs'
rows=[]
with tempfile.TemporaryDirectory(prefix='core-post-entry.') as tmp:
    box=Path(tmp)
    for shape in ['empty','gone-staged']:
        out=box/(shape+'.json')
        r=subprocess.run([sys.executable,str(tree/'scripts/measure/core-post-oracle.py'),
                          '--core',str(core),'--entry','post','--only',shape,'--report',str(out)],capture_output=True,text=True)
        rows.append(dict(name=shape,passed=r.returncode==0,rc=r.returncode,
                         stdout=r.stdout,stderr=r.stderr,oracle=json.loads(out.read_text()) if out.exists() else None))
    home=box/'state';home.mkdir()
    for name in ['pending/id-seeded.json','pending/backstop/id-seeded.trace','rollback-journal/seeded.json','snapshots/seeded_meta.json']:
        path=home/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(b'{"seed":"2001-02-03T04:05:06Z","pid":"123","id":"seeded"}\n')
    def listing():
        return {str(x.relative_to(home)):x.read_bytes() for x in home.rglob('*') if x.is_file() and x.name!='advisory.log'}
    before=listing();saved=source.read_bytes()
    try:
        source.write_bytes(saved+b'\n// archive-only stale-source fixture\n')
        env=dict(os.environ,SAFEDEPS_HOME=str(home))
        r=subprocess.run([str(core),'post'],input=b'{"tool_name":"Bash","tool_input":{"command":"true"},"tool_use_id":"seeded"}',env=env,capture_output=True)
        log=(home/'advisory.log').read_text() if (home/'advisory.log').exists() else ''
        passed=r.returncode==0 and not r.stdout and b'post-verify UNVERIFIED:' in r.stderr and 'no dependency judgment was made' in log and listing()==before
        rows.append(dict(name='stale-preserves-records',passed=passed,rc=r.returncode,stdout=r.stdout.decode(),stderr=r.stderr.decode(),advisory=log,records_preserved=listing()==before))
    finally:source.write_bytes(saved)
report=dict(cases=len(rows),failures=sum(not row['passed'] for row in rows),rows=rows)
Path(a.report).write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(dict(cases=report['cases'],failures=report['failures'])),flush=True)
raise SystemExit(0 if report['failures']==0 else 1)
