#!/usr/bin/env python3
"""Own npm descendants at the actual pre entry's self-budget deadline.

The hook gets JSON data. Its PATH npm is our bounded fixture, never code
chosen by that command. The witness and every fixture process belong to
this run; ps is the independent observation, not the implementation's wait.


Child status is sampled after subprocess.run returns, with retries. The stored
final states establish no descendants remained at those later checks; they do
not measure descendant exit times relative to the hook response.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

FIXTURE='''import json,os,signal,sys,time
from pathlib import Path
box=Path(__file__).resolve().parent.parent
settings=json.loads((box/'fixture.json').read_text())
def record():
 fd=os.open(str(box/'pids'),os.O_WRONLY|os.O_CREAT|os.O_APPEND,0o600)
 os.write(fd,(str(os.getpid())+'\\n').encode());os.close(fd)
def expire(*unused):
 (box/('expired-'+str(os.getpid()))).write_text('expired')
 os._exit(125)
signal.signal(signal.SIGALRM,expire);signal.alarm(12)
record()
pid=os.fork()
if pid==0:
 signal.signal(signal.SIGTERM,signal.SIG_IGN)
 signal.signal(signal.SIGALRM,expire);signal.alarm(12)
 record()
 while True:time.sleep(1)
signal.signal(signal.SIGTERM,signal.SIG_IGN)
while True:time.sleep(1)
'''


def main():
    ap=argparse.ArgumentParser();ap.add_argument('--core',required=True);ap.add_argument('--report',required=True);a=ap.parse_args()
    with tempfile.TemporaryDirectory(prefix='core-pre-budget-entry.') as tmp:
        box=Path(tmp).resolve()
        for name in ('bin','home','tmp','project','state'):(box/name).mkdir()
        (box/'fixture.json').write_text('{}')
        npm=box/'bin/npm';npm.write_text('#!'+sys.executable+' -B\n'+FIXTURE);npm.chmod(0o755)
        env=dict(os.environ,HOME=str(box/'home'),TMPDIR=str(box/'tmp'),PATH=str(box/'bin')+':'+os.environ['PATH'],PWD=str(box/'project'),LANG='C',LC_ALL='C')
        for k in list(env):
            if k.startswith('SAFEDEPS_') or k.lower().startswith('npm_config_'):env.pop(k)
        env.update(SAFEDEPS_HOME=str(box/'state'),SAFEDEPS_SELF_BUDGET_SECONDS='2',SAFEDEPS_BUDGET_ENGAGE_BYTES='1')
        payload=dict(tool_name='Bash',tool_input={'command':'npm ci'},cwd=str(box/'project'),turn_id='budget-probe',tool_use_id='budget-call')
        Path(a.report).with_suffix('.input.jsonl').write_text(json.dumps(payload)+'\n')
        witness=subprocess.Popen(['sleep','30'],start_new_session=True)
        try:
            start=time.monotonic();p=subprocess.run([a.core,'pre'],input=json.dumps(payload).encode(),cwd=box/'project',env=env,capture_output=True,timeout=8);elapsed=time.monotonic()-start
            errors=[];answer=json.loads(p.stdout);hook=answer.get('hookSpecificOutput',{})
            if p.returncode!=0 or hook.get('permissionDecision')!='deny' or 'UNDECIDED' not in hook.get('permissionDecisionReason',''):errors.append('deadline response')
            if 'updatedInput' in hook:errors.append('deadline rewrite')
            if not 1.8<=elapsed<4:errors.append('deadline elapsed')
            pids=[int(n) for n in (box/'pids').read_text().splitlines()];states={}
            if len(pids)<6:errors.append('fixture did not start all npm descendants')
            for pid in pids:
                for attempt in range(30):
                    obs=subprocess.run(['ps','-o','stat=','-p',str(pid)],capture_output=True,text=True);state=obs.stdout.strip()
                    if not state or state.startswith('Z'):break
                    time.sleep(.01)
                states[str(pid)]=state
                if state and not state.startswith('Z'):errors.append('surviving npm descendant '+str(pid))
            if witness.poll() is not None:errors.append('unrelated witness stopped')
            if list(box.glob('expired-*')):errors.append('fixture expired instead of supervisor cleanup')
            if list((box/'state/pending').rglob('*')):errors.append('unfinished judgment wrote pending state')
            result=dict(input=payload,rc=p.returncode,stdout=p.stdout.decode(errors='surrogateescape'),stderr=p.stderr.decode(errors='surrogateescape'),elapsed=elapsed,pids=pids,states=states,witness=witness.pid,errors=errors)
            Path(a.report).write_text(json.dumps(result,indent=2));print('core-pre-budget-entry: '+json.dumps(errors),flush=True)
            return int(bool(errors))
        finally:
            witness.terminate();witness.wait()

if __name__=='__main__':raise SystemExit(main())
