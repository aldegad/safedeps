#!/usr/bin/env python3
"""Run the existing independent report oracle on the Rust hook probe.

This small journal set precedes the complete binary-hook e2e run; it does
not satisfy the oracle's full form-coverage table. No command payload runs.
"""
import argparse
import datetime
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--core',required=True)
p.add_argument('--report',required=True)
p.add_argument('--only')
p.add_argument('--implementation',choices=['rust'],default='rust')
p.add_argument('--entry',choices=['probe','post'],default='probe')
p.add_argument('--no-reorg',action='store_true',help='Leave reorg.log absent before the existing fixture')
p.add_argument('--expect-difference',action='store_true')
p.add_argument('--expect-oracle-text',help='Required diagnostic substring for a source-mutation run')
a=p.parse_args()
if a.expect_difference and (not a.only or not a.expect_oracle_text):
    p.error('--expect-difference requires --only and --expect-oracle-text')
root=Path(__file__).resolve().parents[2]
core=str(Path(a.core).resolve())
runner='''#!/bin/bash
set -uo pipefail
source "$ROOT/scripts/test/lib/report-oracle.sh"
oracle_init "$BOX/oracle"
payload=$(cat "$BOX/payload.json")
call="$BOX/oracle/call"
mkdir -p "$call"
[[ "$IMPLEMENTATION" != rust ]] || : > "$call/native-owner-source"
oracle_before "$call" "$payload"
if [[ "$ENTRY" == post ]]; then
  out=$(printf '%s' "$payload" | "$CORE" post)
else
  request=$(jq -cn --arg input "$payload" '{op:"hook",input:$input}')
  out=$(printf '%s' "$request" | "$CORE" post-probe)
fi
rc=$?
printf '%s\\n' "$out" > "$BOX/hook.out"
printf '%s\\n' "$rc" > "$BOX/hook.rc"
if [[ "$rc" != 0 ]]; then exit "$rc"; fi
oracle_message "$call" "$payload" "$out"
'''
rows=[]
print('start:',subprocess.check_output(['uptime'],text=True).strip(),flush=True)
with tempfile.TemporaryDirectory(prefix='core-post-oracle.') as tmp:
    box=Path(tmp)
    script=box/'oracle-run.sh';script.write_text(runner)
    for shape in ['empty','no-pid','gone-staged','live','snapshot-differs','snapshot-missing','snapshot-extra','snapshot-link']:
        if a.only and a.only!=shape: continue
        d=box/'case';shutil.rmtree(d,ignore_errors=True)
        home=d/'state';project=d/'project'
        (home/'rollback-journal').mkdir(parents=True);(home/'snapshots').mkdir();project.mkdir()
        (home/'advisory.log').touch()
        if not a.no_reorg:(home/'reorg.log').touch()
        if shape!='empty':
            entry=dict(journal_id='j',project_dir=str(project),rollback_snapshot='seed-snapshot',reasons='fixture',stage='removing-node-modules',opened_at='2001-02-03T04:05:06Z',stage_at='2001-02-03T04:05:17Z')
            if shape!='no-pid': entry['pid']='2147483647'
            if shape=='live':
                entry['pid']=str(os.getpid())
                entry['opened_at']=datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
                entry.pop('stage_at')
            (home/'rollback-journal/j.json').write_text(json.dumps(entry))
        if shape.startswith('snapshot-'):
            (home/'snapshots/seed-snapshot_monitored_files.list').write_text('package.json\n')
            saved=home/'snapshots/seed-snapshot_package.json'
            target=project/'package.json'
            if shape=='snapshot-extra':
                saved.with_name(saved.name+'.missing').touch();target.write_text('{}')
            else:
                saved.write_text('{"before":true}')
                if shape=='snapshot-differs':target.write_text('{"after":true}')
                if shape=='snapshot-link':
                    (project/'target.json').write_text('{}');target.symlink_to('target.json')
        (d/'payload.json').write_text(json.dumps(dict(tool_name='Bash',tool_input=dict(command='true'),cwd=str(project),tool_use_id='oracle-call')))
        env=dict(os.environ,ROOT=str(root),CORE=core,BOX=str(d),SAFEDEPS_HOME=str(home),LC_ALL='C',IMPLEMENTATION=a.implementation,ENTRY=a.entry)
        result=subprocess.run(['bash',str(script)],env=env,capture_output=True,text=True,timeout=30)
        rows.append(dict(name=shape,implementation=a.implementation,reorg_exists_after=(home/'reorg.log').exists(),rc=result.returncode,oracle_stdout=result.stdout,oracle_stderr=result.stderr,
                         hook_rc=int((d/'hook.rc').read_text()) if (d/'hook.rc').exists() else None,
                         hook_stdout=(d/'hook.out').read_text() if (d/'hook.out').exists() else None))
        print(('ok' if result.returncode==0 else 'FAIL'),shape,flush=True)
report=dict(cases=len(rows),failures=sum(r['rc']!=0 for r in rows),rows=rows)
Path(a.report).write_text(json.dumps(report,indent=2)+'\n')
print('end:',subprocess.check_output(['uptime'],text=True).strip(),flush=True)
if a.expect_difference:
    expected=len(rows)==1 and rows[0]['rc']!=0 and rows[0]['hook_rc']==0 and a.expect_oracle_text in rows[0]['oracle_stderr']
else:
    expected=bool(rows) and report['failures']==0
raise SystemExit(0 if expected else 1)
