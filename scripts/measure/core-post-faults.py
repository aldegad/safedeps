#!/usr/bin/env python3
"""Exercise native I/O failures with disk permissions and the report oracle.

Run remotely as an unprivileged user. These fixtures replace e2e's jq/cp/rm
PATH shims with the same failed operation on disk. Each side receives the
same synthetic pending record and snapshot at the same absolute path. The
existing independent oracle is unchanged, and the expected failure line is
required separately, so an injection that never reached the operation fails.
This is a focused supplement, not a complete e2e or form-coverage result.
The absent-lockfile fixture makes its project directory read-only: this
prevents creating the lockfile AND removing node_modules itself. The
overwrite fixture keeps a writable parent and checks that removal continues.
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
p.add_argument('--report',required=True)
p.add_argument('--only',help='Comma-separated fixture names')
p.add_argument('--side',choices=['both','bash','rust'],default='both')
p.add_argument('--expect-oracle-text',help='Require a Rust-only source mutant to fail at this oracle diagnostic')
a=p.parse_args()
if a.expect_oracle_text and (a.side!='rust' or not a.only or ',' in a.only):
    p.error('a source-mutation control requires --side rust and one --only fixture')
if os.geteuid()==0:
    p.error('permission injection needs an unprivileged user; no fixture was verified')
root=Path(__file__).resolve().parents[2]
core=str(Path(a.core).resolve(strict=True))
runner='''#!/bin/bash
set -uo pipefail
source "$ROOT/scripts/test/lib/report-oracle.sh"
oracle_init "$BOX/oracle"
payload=$(cat "$BOX/payload.json")
call="$BOX/oracle/call"
mkdir -p "$call"
oracle_before "$call" "$payload"
if [[ "$FAULT" == unread-meta ]]; then
  : > "$call/record-unread"
  chmod 000 "$SAFEDEPS_HOME/snapshots/pre_meta.json"
fi
if [[ "$SIDE" == bash ]]; then
  out=$(printf '%s' "$payload" | "$ROOT/scripts/safedeps-post-verify.sh")
  rc=$?
else
  request=$(jq -cn --arg input "$payload" '{op:"hook",input:$input}')
  out=$(printf '%s' "$request" | "$CORE" post-probe)
  rc=$?
fi
printf '%s\\n' "$out" > "$BOX/hook.out"
printf '%s\\n' "$rc" > "$BOX/hook.rc"
# Restore only the test's permissions, after the hook. The oracle's unread
# marker came from the fixture before the hook, not from the hook's output.
[[ "$FAULT" != unread-meta ]] || chmod 600 "$SAFEDEPS_HOME/snapshots/pre_meta.json"
[[ "$rc" == 0 ]] || exit "$rc"
oracle_message "$call" "$payload" "$out"
'''

def unlock(d):
    # This owns only this fixture; permissions must allow its cleanup.
    for path in [d]+list(d.rglob('*')):
        if not path.is_symlink():
            path.chmod(0o700 if path.is_dir() else 0o600)

def seed(d,kind):
    if d.exists():unlock(d);shutil.rmtree(d)
    home=d/'state';project=d/'project';snapshot=home/'snapshots'
    snapshot.mkdir(parents=True);(home/'pending').mkdir();project.mkdir()
    for name in ['advisory.log','reorg.log']:(home/name).touch()
    (project/'node_modules/.bin').mkdir(parents=True)
    (project/'node_modules/kept').mkdir()
    (project/'node_modules/kept/data').write_text('fixture bytes\n')
    (project/'node_modules/.bin/drop').write_text('#!/bin/sh\nexit 0\n')
    before={'name':'before','dependencies':{}}
    lock={'lockfileVersion':3,'packages':{}}
    (snapshot/'pre_package.json').write_text(json.dumps(before)+'\n')
    (snapshot/'pre_package-lock.json').write_text(json.dumps(lock)+'\n')
    (snapshot/'pre_monitored_files.list').write_text('package-lock.json\npackage.json\n')
    (snapshot/'pre_packages.list').touch();(snapshot/'pre_bins.list').touch()
    command='npm install fixture-item'
    record=dict(record=2,snapshot_id='pre',tool_use_id='fault-call',project_dir=str(project),
                ignore_scripts_injected=False,command=command,updated_command=command)
    (snapshot/'pre_meta.json').write_text(json.dumps(record)+'\n')
    (home/'pending/id-fault-call.json').write_text(json.dumps(record)+'\n')
    (project/'package.json').write_text(json.dumps(dict(name='after',dependencies={}))+'\n')
    (project/'package-lock.json').write_text(json.dumps(dict(lock,name='after'))+'\n')
    if kind=='restore-readonly':(project/'package-lock.json').chmod(0o444)
    if kind=='restore-absent':
        (project/'package-lock.json').unlink();project.chmod(0o555)
    if kind=='remove-readonly':(project/'node_modules/kept').chmod(0o555)
    payload=dict(tool_name='Bash',tool_input=dict(command=command),cwd=str(project),tool_use_id='fault-call')
    (d/'payload.json').write_text(json.dumps(payload))
    return home,project

rows=[]
print('start:',subprocess.check_output(['uptime'],text=True).strip(),flush=True)
with tempfile.TemporaryDirectory(prefix='core-post-faults.') as tmp:
    box=Path(tmp).resolve();script=box/'oracle-run.sh';script.write_text(runner)
    d=box/'paired'
    for kind in ['unread-meta','restore-readonly','restore-absent','remove-readonly']:
        if a.only and kind not in a.only.split(','):continue
        for side in (['bash','rust'] if a.side=='both' else [a.side]):
            home,project=seed(d,kind)
            env=dict(os.environ,ROOT=str(root),CORE=core,BOX=str(d),SAFEDEPS_HOME=str(home),LC_ALL='C',FAULT=kind,SIDE=side)
            try:
                result=subprocess.run(['bash',str(script)],env=env,capture_output=True,text=True,timeout=30)
                hook_rc=int((d/'hook.rc').read_text()) if (d/'hook.rc').exists() else None
                raw=(d/'hook.out').read_text() if (d/'hook.out').exists() else ''
                try:message=json.loads(raw)['systemMessage']
                except (ValueError,KeyError,TypeError):message=''
                log=(home/'advisory.log').read_text()
                if kind=='unread-meta':
                    reached='could not read the pre-guard\'s record of this command' in log and '--ignore-scripts' not in message
                elif kind.startswith('restore-'):
                    suffix='does not exist' if kind=='restore-absent' else 'differs from the snapshot'
                    reached=f'not restored {project}/package-lock.json: cp exit 1; {project}/package-lock.json {suffix}' in message
                else:
                    reached=f'not removed {project}/node_modules: rm exit 1; {project}/node_modules exists' in message
                journal_closed=not list((home/'rollback-journal').glob('*.json'))
                tree_exists=(project/'node_modules').exists()
                continued=True
                if kind=='restore-readonly':
                    continued=not tree_exists and f'removed {project}/node_modules' in message
                elif kind=='restore-absent':
                    continued=(tree_exists and f'not removed {project}/node_modules: rm exit 1; {project}/node_modules exists' in message)
                # The closed oracle checks the bytes/logs/disk, while this
                # assertion verifies this fixture reached its failure path.
                passed=hook_rc==0 and result.returncode==0 and reached and continued and journal_closed
                if a.expect_oracle_text:
                    passed=hook_rc==0 and result.returncode!=0 and a.expect_oracle_text in result.stderr and journal_closed
                rows.append(dict(name=kind,side=side,passed=passed,injection_reached=reached,
                                 rollback_continued=continued,journal_closed=journal_closed,node_modules_exists=tree_exists,
                                 rc=result.returncode,hook_rc=hook_rc,hook_stdout=raw,
                                 oracle_stdout=result.stdout,oracle_stderr=result.stderr))
                print(('ok' if passed else 'FAIL'),side,kind,flush=True)
            finally:
                unlock(d)
report=dict(cases=len(rows),failures=sum(not r['passed'] for r in rows),rows=rows)
Path(a.report).write_text(json.dumps(report,indent=2)+'\n')
print('end:',subprocess.check_output(['uptime'],text=True).strip(),flush=True)
raise SystemExit(0 if rows and report['failures']==0 else 1)
