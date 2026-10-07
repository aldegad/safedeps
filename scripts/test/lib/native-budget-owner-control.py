#!/usr/bin/env python3
"""SIGKILL defeats the fixture's CONT and EXIT cleanup; the next sweep reaps it."""
import argparse,json,os,signal,subprocess,sys,tempfile,time
from pathlib import Path
import native_budget_owners as owners

p=argparse.ArgumentParser();p.add_argument('--root',required=True);p.add_argument('--report',required=True);a=p.parse_args()
root=Path(a.root).resolve();run=None;lease=None;active=owners.create(os.getpid());witness=None
try:
    with tempfile.TemporaryDirectory(prefix='native-budget-sweep.') as tmp:
        box=Path(tmp);project=box/'project';project.mkdir();case=box/'case';case.mkdir()
        (project/'package.json').write_text('{"name":"fixture"}\n');(case/'command').write_text('npm ci')
        witness=subprocess.Popen([sys.executable,'-c','import time;time.sleep(30)'],cwd=project,start_new_session=True)
        owners.register(active,witness.pid,'active-witness')
        with (box/'run.log').open('wb') as log:
            run=subprocess.Popen([sys.executable,str(root/'scripts/test/lib/native-budget-run.py'),
                '--root',str(root),'--box',str(case),'--project',str(project),'--command',str(case/'command'),
                '--budget','1','--engage','1','--disabled','1','--delay','60','--suite-pid',str(os.getpid())],
                cwd=project,stdout=log,stderr=log)
            until=time.monotonic()+8
            while not (case/'judgment.json').exists() and run.poll() is None and time.monotonic()<until:time.sleep(.01)
            if not (case/'judgment.json').exists():raise RuntimeError('orphan control did not reach stopped judgment')
            judgment=json.loads((case/'judgment.json').read_text())['pid'];lease=Path((case/'lease').read_text())
            stopped=subprocess.check_output(['ps','-o','stat=','-p',str(judgment)],text=True).strip()
            leader=int((case/'leader').read_text());os.kill(leader,signal.SIGKILL)
            # Simulate the run itself being killed too, so no EXIT cleanup can
            # run and only a sweep for a disappeared owner may act.
            run.kill();run.wait()
            receipts=owners.sweep()
            passed=('T' in stopped and not owners.live(judgment) and not lease.exists()
                    and active.exists() and witness.poll() is None
                    and any(r['lease']==str(lease) and not r['survivors'] for r in receipts))
            result=dict(stopped_state=stopped,killed_npm=leader,killed_owner=run.pid,judgment=judgment,
                        sweep=receipts,active_owner_preserved=active.exists() and witness.poll() is None,passed=passed)
            Path(a.report).write_text(json.dumps(result,indent=2)+'\n')
            print(('ok' if passed else 'not ok')+' - stale-owner sweep reaps a judgment whose npm fixture could not CONT it')
            if not passed:raise SystemExit(1)
finally:
    if lease and lease.exists():owners.cleanup(lease)
    owners.cleanup(active)
    if run and run.poll() is None:run.terminate();run.wait()
    if witness:witness.wait()
