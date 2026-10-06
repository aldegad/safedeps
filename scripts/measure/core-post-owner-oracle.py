#!/usr/bin/env python3
"""Exercise native owner diagnostics through the original report oracle.

Failures are supplied by an archive-only source mutation, never by a product
environment switch. The fixture records the chosen native response before
the hook, as record-unread does for the I/O fixture. ps independently records
the real owner's state before the hook; all processes here belong to this run.
"""
import argparse
import datetime
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--core',required=True)
p.add_argument('--report',required=True)
p.add_argument('--only',choices=['running','stopped','zombie','query-zero','query-short','wrong-owner'])
p.add_argument('--expect-oracle-text')
a=p.parse_args()
if a.expect_oracle_text and not a.only:p.error('an oracle control requires --only')
root=Path(__file__).resolve().parents[2];core=str(Path(a.core).resolve(strict=True))
runner='''#!/bin/bash
set -uo pipefail
source "$ROOT/scripts/test/lib/report-oracle.sh"
oracle_init "$BOX/oracle"
call="$BOX/oracle/call"
mkdir -p "$call"
: > "$call/native-owner-source"
[[ ! -f "$BOX/native-query-failure.json" ]] || cp "$BOX/native-query-failure.json" "$call/native-query-failure.json"
payload=$(cat "$BOX/payload.json")
oracle_before "$call" "$payload"
request=$(jq -cn --arg input "$payload" '{op:"hook",input:$input}')
out=$(printf '%s' "$request" | "$CORE" post-probe)
rc=$?
printf '%s\\n' "$out" > "$BOX/hook.out"
printf '%s\\n' "$rc" > "$BOX/hook.rc"
[[ "$rc" == 0 ]] || exit "$rc"
oracle_message "$call" "$payload" "$out"
'''
rows=[]
print('start:',subprocess.check_output(['uptime'],text=True).strip(),flush=True)
with tempfile.TemporaryDirectory(prefix='core-post-owner-oracle.') as temp:
    box=Path(temp).resolve();script=box/'oracle.sh';script.write_text(runner)
    for kind in ([a.only] if a.only else ['running','stopped','zombie']):
        d=box/kind;home=d/'state';project=d/'project'
        (home/'rollback-journal').mkdir(parents=True);project.mkdir()
        for name in ['advisory.log','reorg.log']:(home/name).touch()
        child=None;pid=None
        try:
            if kind=='zombie':
                pid=os.fork()
                if pid==0:os._exit(0)
                deadline=time.monotonic()+5
                while time.monotonic()<deadline:
                    state=subprocess.check_output(['ps','-o','stat=','-p',str(pid)],text=True).strip()
                    if state.startswith('Z'):break
                    time.sleep(.02)
                else:raise RuntimeError('fixture child did not become a zombie')
            else:
                child=subprocess.Popen(['sleep','60']);pid=child.pid
                if kind=='stopped':
                    child.send_signal(signal.SIGSTOP)
                    waited,status=os.waitpid(pid,os.WUNTRACED)
                    if waited!=pid or not os.WIFSTOPPED(status):raise RuntimeError('fixture did not stop')
            opened=datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
            record=dict(journal_id='native-owner',project_dir=str(project),rollback_snapshot='seed',
                        reasons='synthetic fixture',stage='removing-node-modules',opened_at=opened,pid=str(pid))
            original=json.dumps(record)+'\n';entry=home/'rollback-journal/native-owner.json';entry.write_text(original)
            if kind.startswith('query-') or kind=='wrong-owner':
                # Darwin proc_bsdinfo is 136 bytes. The mutation artifact
                # names this response; it is not learned from the hook.
                evidence=dict(pid=str(pid),expected_bytes=136,
                              returned_bytes=0 if kind=='query-zero' else 128 if kind=='query-short' else 136)
                if kind=='wrong-owner':evidence['returned_pid']=str(pid+1)
                (d/'native-query-failure.json').write_text(json.dumps(evidence))
            (d/'payload.json').write_text(json.dumps(dict(tool_name='Bash',tool_input=dict(command='true'),cwd=str(project))))
            env=dict(os.environ,ROOT=str(root),CORE=core,BOX=str(d),SAFEDEPS_HOME=str(home),LC_ALL='C')
            result=subprocess.run(['bash',str(script)],env=env,capture_output=True,text=True,timeout=30)
            hook_rc=int((d/'hook.rc').read_text()) if (d/'hook.rc').exists() else None
            output=(d/'hook.out').read_text() if (d/'hook.out').exists() else ''
            try:message=json.loads(output)['systemMessage']
            except (ValueError,KeyError,TypeError):message=''
            incident=home/'rollback-incidents/native-owner.json'
            incident_raw=incident.read_text() if incident.exists() else None
            if kind=='running':reached=not message and entry.exists() and incident_raw is None
            else:
                needle='is stopped (process state ' if kind=='stopped' else 'is a zombie (process state ' if kind=='zombie' else 'native process query supplied no usable owner data for pid '+str(pid)
                reached=needle in message and not entry.exists() and incident_raw==original
            passed=hook_rc==0 and result.returncode==0 and reached
            if a.expect_oracle_text:passed=hook_rc==0 and result.returncode!=0 and a.expect_oracle_text in result.stderr
            observed=(d/'oracle/call/journal/native-owner.process-stat').read_text()
            rows.append(dict(name=kind,passed=passed,injection_reached=reached,hook_rc=hook_rc,rc=result.returncode,
                             independent_process_stat=observed,journal_before=original,incident_after=incident_raw,
                             hook_stdout=output,oracle_stdout=result.stdout,oracle_stderr=result.stderr))
            print(kind,'ok' if passed else 'FAIL',flush=True)
        finally:
            if child:
                if child.poll() is None:
                    child.send_signal(signal.SIGCONT);child.terminate();child.wait()
            elif pid:os.waitpid(pid,0)
report=dict(cases=len(rows),failures=sum(not row['passed'] for row in rows),rows=rows)
Path(a.report).write_text(json.dumps(report,indent=2)+'\n')
print('end:',subprocess.check_output(['uptime'],text=True).strip(),flush=True)
raise SystemExit(0 if rows and report['failures']==0 else 1)
