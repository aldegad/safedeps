#!/usr/bin/env python3
"""The intentional stale-checkout contract, on copies only. No command from
an input is executed. --expect-difference is the old-binary control.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--core',required=True)
p.add_argument('--expect-difference',action='store_true')
a=p.parse_args()
core=Path(a.core).resolve(); root=Path(__file__).resolve().parents[2]
def run(args,**kw): return subprocess.run(args,capture_output=True,**kw)
print('start:',run(['uptime']).stdout.decode().strip(),flush=True)
bad=0; count=0
with tempfile.TemporaryDirectory(prefix='stale-core.') as tmp:
    box=Path(tmp); tree=box/'tree'; tree.mkdir(); binary=tree/'safedeps-core'; shutil.copy2(core,binary)
    shutil.copytree(root/'rust',tree/'rust',ignore=shutil.ignore_patterns('target'))
    with (tree/'rust/src/pre.rs').open('ab') as f: f.write(b'\n// stale probe\n')
    rows=[('rebuild','bash scripts/build-core.sh',False),('manager','npm ci',True),('continued-manager','n\\\npm ci',True),('manager-data','echo npm',True),('empty-command','',False)]
    for shape in ['changed','missing']:
        if shape=='missing': shutil.rmtree(tree/'rust')
        rc=run([str(binary),'stamp','--check']).returncode
        count+=1; bad+=rc!=1
        for name,command,deny in rows+[('bad-json',None,True),('missing-command',{},True),('command-number',1,True),('wrong-tool',False,False)]:
            guard=box/'state'; shutil.rmtree(guard,ignore_errors=True)
            env=dict(os.environ,SAFEDEPS_HOME=str(guard),SAFEDEPS_CORE_STAMP_KIND='publish')
            if command is None: data=b'{broken'
            elif command is False: data=json.dumps({'tool_name':'Read'}).encode()
            elif command=={}: data=json.dumps({'tool_name':'Bash','tool_input':{}}).encode()
            else: data=json.dumps({'tool_name':'Bash','tool_use_id':'stamp-case','tool_input':{'command':command},'cwd':str(box)}).encode()
            result=run([str(binary),'pre'],input=data,env=env)
            try: denied=json.loads(result.stdout)['hookSpecificOutput']['permissionDecision']=='deny'
            except (ValueError,KeyError): denied=False
            entries=sorted(str(x.relative_to(guard)) for x in guard.rglob('*'))
            ok=result.returncode==0 and denied==deny and bool(result.stderr) and entries==['advisory.log']
            if deny: ok=ok and b'UNDECIDED' in result.stdout
            count+=1; bad+=not ok
            print(('ok ' if ok else 'DIFF ')+shape+'/'+name,flush=True)
            if not ok: print(result.returncode,repr(result.stdout),repr(result.stderr),entries)
print('end:',run(['uptime']).stdout.decode().strip())
print(f'core-stale-probe: {count} checks, {bad} differ')
raise SystemExit(0 if (bad>0 if a.expect_difference else bad==0) else 1)
