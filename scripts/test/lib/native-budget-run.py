#!/usr/bin/env python3
"""Run a registered native pre entry against owned, bounded npm descendants.

No command payload is executed. A delayed npm fixture stops only the judgment
that spawned it, then resumes it after a finite delay. This makes the outer
budget observable even when npm's own eight-second question deadline expires.
The load fixture deschedules only the owned supervisor, with SIGSTOP/SIGCONT.
All timing uses monotonic clocks; raw process observations are retained.

The budget is wall clock and so is this fixture's start, so on a busy machine
the deadline can land first. That is the answer a stalled row asks for, and the
result records it (held false). npm's own eight seconds can land first too, on
a row with a longer budget: the hook then answers as it answers a slow npm, and
the run saw no stalled judgment. The fixture stops the judgment before anything
else it does, so only a start past those eight seconds loses that race, and the
result records it as well (ask_limit), from the line the hook wrote. Anything
else that leaves the judgment unheld is an error.
"""
import argparse,json,math,os,shutil,signal,subprocess,sys,time
from pathlib import Path
import native_budget_owners as owners

FIXTURE=r'''import json,os,signal,sys,time
from pathlib import Path
box=Path(__file__).resolve().parent.parent
settings=json.loads((box/'settings.json').read_text())
delay=settings['delay']
sys.path.insert(0,settings['helpers'])
import native_budget_owners as owners
lease=Path(settings['lease'])
def record(role):
    owners.register(lease,os.getpid(),role)
    line=json.dumps(dict(pid=os.getpid(),parent=os.getppid(),role=role))+'\n'
    fd=os.open(str(box/'pids.jsonl'),os.O_WRONLY|os.O_CREAT|os.O_APPEND,0o600)
    os.write(fd,line.encode());os.close(fd)
def expire(*unused):
    (box/('expired-'+str(os.getpid()))).write_text('expired')
    os._exit(125)
def questions(parent):
    # Not pgrep: on macOS it leaves out its own ancestors, and this process is one.
    return subprocess.run(['ps','-A','-o','ppid='],capture_output=True,text=True).stdout.split().count(str(parent))
def no_judgment(parent):
    (box/'no-judgment').write_text('parent '+str(parent)+' is '+(owners.command(parent) or 'gone'))
    raise SystemExit('no judgment process')
if delay:
    signal.signal(signal.SIGTERM,signal.SIG_IGN)
    signal.signal(signal.SIGALRM,expire);signal.alarm(math.ceil(delay)+8)
    if settings['all_late'] or sys.argv[1:2]==['config']:time.sleep(settings['late_question'])
    try:
        fd=os.open(str(box/'leader'),os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    except FileExistsError:fd=None
    if fd is not None:
        os.write(fd,str(os.getpid()).encode());os.close(fd)
        if settings['orphan_judgment']:
            # The deadline's TERM ends the judgment 50 ms before its KILL reaches
            # this group. A session of its own holds that window open.
            os.setsid();parent=os.getppid();os.kill(parent,signal.SIGKILL)
            while os.getppid()==parent:time.sleep(.01)
        parent=os.getppid()
        ancestor=owners.judgment(parent,settings['root'])
        if ancestor is None:no_judgment(parent)
        # npm's own eight seconds run in the judgment, so stopping it stops them.
        # That comes first: the rest of this fixture starts when the machine lets
        # it, and only the three questions have to exist, not to have answered.
        try:
            while questions(parent)<3:time.sleep(.01)
            owners.register(lease,parent,'judgment')
            owners.register(lease,ancestor,'supervisor-or-entry')
            os.kill(parent,signal.SIGSTOP)
        except (RuntimeError,ProcessLookupError):no_judgment(parent)
    record('npm')
    if os.fork()==0:
        signal.signal(signal.SIGALRM,expire);signal.alarm(math.ceil(delay)+8)
        record('descendant')
        time.sleep(delay+1)
        os._exit(0)
    if fd is not None:
        # The alarm bounds this wait: the others start when the machine lets them.
        while True:
            rows=[json.loads(line) for line in (box/'pids.jsonl').read_text().splitlines()]
            if sum(r['role']=='npm' for r in rows)>=3 and sum(r['role']=='descendant' for r in rows)>=3:break
            time.sleep(.01)
        try:
            if settings['kill_judgment']:
                (box/'judgment.tmp').write_text(json.dumps(dict(pid=parent,action='KILL',acted_at=time.monotonic())))
                os.replace(box/'judgment.tmp',box/'judgment.json')
                os.kill(parent,signal.SIGKILL)
                time.sleep(delay)
            else:
                (box/'judgment.tmp').write_text(json.dumps(dict(pid=parent,action='STOP',stopped_at=time.monotonic())))
                os.replace(box/'judgment.tmp',box/'judgment.json')
                time.sleep(delay)
                os.kill(parent,signal.SIGCONT)
        except (RuntimeError,ProcessLookupError):no_judgment(parent)
    else:time.sleep(delay)
head=sys.argv[1] if len(sys.argv)>1 else ''
project=settings['project']
if head=='prefix':print(project)
elif head=='root':print(project+'/node_modules')
elif head=='config':print(json.dumps({'registry':'https://registry.npmjs.org/','replace-registry-host':'npmjs'}))
else:raise SystemExit('unexpected npm question: '+repr(sys.argv))
'''.replace('import json,os,signal,sys,time','import json,math,os,signal,subprocess,sys,time')


def state(pid):
    return subprocess.run(['ps','-o','stat=','-p',str(pid)],capture_output=True,text=True).stdout.strip()

def children(pid):
    return [int(c) for c in subprocess.run(['pgrep','-P',str(pid)],capture_output=True,text=True).stdout.split()]

def supervisor_of(entry,root):
    """The entry's core once it has started its judgment, so its clock is running."""
    for pid in children(entry):
        command=owners.command(pid)
        if str(root/'bin/native/') in command and '--budget-child' not in command and children(pid):return pid
    return None

def main():
    p=argparse.ArgumentParser(description=__doc__)
    for name in ['root','box','project','command','budget','engage']:p.add_argument('--'+name,required=True)
    p.add_argument('--disabled',default='');p.add_argument('--legacy-child',default='')
    p.add_argument('--suite-pid',required=True);p.add_argument('--seconds',default='');p.add_argument('--ignore-term',action='store_true')
    p.add_argument('--delay',type=float,default=0);p.add_argument('--pause-supervisor',action='store_true')
    p.add_argument('--kill-judgment',action='store_true');p.add_argument('--orphan-judgment',action='store_true')
    p.add_argument('--late-question',type=float,default=0);p.add_argument('--all-late',action='store_true')
    a=p.parse_args();box=Path(a.box);project=Path(a.project).resolve();root=Path(a.root).resolve()
    for name in ['bin','home','tmp','state']:(box/name).mkdir()
    lease=owners.create(a.suite_pid)
    (box/'lease').write_text(str(lease))
    settings=dict(delay=a.delay,kill_judgment=a.kill_judgment,orphan_judgment=a.orphan_judgment,late_question=a.late_question,all_late=a.all_late,root=str(root),project=str(project),helpers=str(Path(__file__).resolve().parent),lease=str(lease))
    (box/'settings.json').write_text(json.dumps(settings))
    npm=box/'bin/npm';npm.write_text('#!'+sys.executable+' -B\n'+FIXTURE);npm.chmod(0o755)
    env={k:v for k,v in os.environ.items() if not k.startswith('SAFEDEPS_') and not k.lower().startswith('npm_config_')}
    env.update(HOME=str(box/'home'),TMPDIR=str(box/'tmp'),PWD=str(project),LC_ALL='C',LANG='C',
               PATH=str(box/'bin')+':'+os.environ['PATH'],SAFEDEPS_HOME=str(box/'state'),
               SAFEDEPS_SELF_BUDGET_SECONDS=a.budget,SAFEDEPS_BUDGET_ENGAGE_BYTES=a.engage,
               SAFEDEPS_BUDGET_DISABLED=a.disabled,SAFEDEPS_BUDGET_CHILD=a.legacy_child)
    if a.seconds:env['SECONDS']=a.seconds
    payload=dict(tool_name='Bash',cwd=str(project),tool_use_id='budget-call',tool_input={'command':Path(a.command).read_text()})
    (box/'input.json').write_text(json.dumps(payload))
    ignore=(lambda:signal.signal(signal.SIGTERM,signal.SIG_IGN)) if a.ignore_term else None
    signal.signal(signal.SIGTERM,lambda *_:sys.exit(143))
    signal.signal(signal.SIGINT,lambda *_:sys.exit(130))
    errors=[];observed=[];supervisor=None;resumed=None;proc=None;witness=None
    start=time.monotonic()
    try:
        # The judgment asks npm and no other manager (rust/src/ask.rs). Never a real one.
        found=shutil.which('npm',path=env['PATH'])
        if found!=str(npm):raise RuntimeError('PATH check: npm is '+str(found)+', not the fixture '+str(npm))
        if a.delay:
            witness=subprocess.Popen([sys.executable,'-c','import time;time.sleep(90)'],start_new_session=True,cwd=project)
            owners.register(lease,witness.pid,'unrelated-witness')
        with (box/'input.json').open('rb') as inp,(box/'stdout').open('wb') as out,(box/'stderr').open('wb') as err:
            proc=subprocess.Popen([str(root/'scripts/safedeps-hook-entry.sh'),'pre'],stdin=inp,stdout=out,stderr=err,
                                  cwd=project,env=env,start_new_session=True,preexec_fn=ignore)
            owners.register(lease,proc.pid,'entry')
            stop_at=start+35
            if a.pause_supervisor:
                # Paused before its deadline, the supervisor has no race with the
                # fixture's start: the judgment stays unfinished either way.
                while supervisor is None and proc.poll() is None and time.monotonic()<start+float(a.budget):
                    supervisor=supervisor_of(proc.pid,root)
                    if supervisor is None:time.sleep(.01)
                try:
                    if supervisor:os.kill(supervisor,signal.SIGSTOP)
                except ProcessLookupError:supervisor=None  # it answered first
                if supervisor:
                    # Past the deadline by the same margin however late the pause began.
                    time.sleep(max(0,start+float(a.budget)+.5-time.monotonic()))
                    os.kill(supervisor,signal.SIGCONT);resumed=time.monotonic()
            while proc.poll() is None and time.monotonic()<stop_at:time.sleep(.01)
            if proc.poll() is None:errors.append('registered entry did not answer within 35s')
        elapsed=time.monotonic()-start
        raw=(box/'stdout').read_text();stderr=(box/'stderr').read_text()
        answer=json.loads(raw) if raw.strip() else {};hook=answer.get('hookSpecificOutput',{})
        log=box/'state/advisory.log'
        held=(box/'judgment.json').exists();absent=(box/'no-judgment').read_text() if (box/'no-judgment').exists() else ''
        ask_limit=log.exists() and 'npm did not finish within' in log.read_text()
        if a.delay:
            lines=(box/'pids.jsonl').read_text().splitlines() if (box/'pids.jsonl').exists() else []
            observed=[json.loads(line) for line in lines]
            reason=hook.get('permissionDecisionReason','')
            if 'could not finish judging this command within' not in reason and not ask_limit:
                if len(observed)<6:errors.append('delay did not reach three npm questions and descendants')
                if absent:errors.append('no judgment process: '+absent)
                elif not held and 'judgment process ended without' in reason:errors.append('no judgment process: it ended before the fixture reached it')
                elif not held:errors.append('fixture did not reach its judgment signal')
        states={}
        for row in observed:
            pid=row['pid'];s=''
            for attempt in range(60):
                s=state(pid)
                if not s or s.startswith('Z'):break
                time.sleep(.02)
            states[str(pid)]=s
        gone=all(not s or s.startswith('Z') for s in states.values())
        if a.delay:
            # pids.jsonl holds what the fixture got to write, and a deadline can
            # land before it writes. The process table holds the rest.
            for attempt in range(60):
                left=subprocess.run(['pgrep','-f',str(npm)],capture_output=True,text=True).stdout.split()
                if not left:break
                time.sleep(.02)
            gone=gone and not left
        if a.delay and (not witness or witness.poll() is not None):errors.append('unrelated witness stopped')
        if list(box.glob('expired-*')):errors.append('fixture expired rather than supervisor cleanup')
        if 'UNDECIDED' in hook.get('permissionDecisionReason',''):
            if 'updatedInput' in hook:errors.append('undecided judgment sent a rewrite')
            if list((box/'state/pending').rglob('*.json')):errors.append('undecided judgment wrote pending state')
            if list((box/'state/snapshots').glob('*_meta.json')):errors.append('undecided judgment wrote snapshot meta')
        result=dict(rc=proc.returncode if proc else None,stdout=raw,stderr=stderr,elapsed=elapsed,
                    elapsed_seconds=math.ceil(elapsed),elapsed_ms=round(elapsed*1000),
                    decision=hook.get('permissionDecision','pass'),reason=hook.get('permissionDecisionReason',''),
                    advisory=log.read_text() if log.exists() else '',observed=observed,states=states,
                    descendants_gone=gone,held=held,paused=resumed is not None,ask_limit=ask_limit,no_judgment=absent,npm=found,supervisor=supervisor,
                    response_after_resume=None if resumed is None else elapsed-(resumed-start),errors=errors)
        (box/'result.json').write_text(json.dumps(result,indent=2)+'\n')
        print(json.dumps(result))
        return int(bool(errors))
    finally:
        receipt=owners.cleanup(lease)
        (box/'cleanup.json').write_text(json.dumps(receipt,indent=2)+'\n')
        if proc and proc.poll() is None:proc.wait(timeout=3)
        if witness:witness.terminate();witness.wait()

if __name__=='__main__':raise SystemExit(main())
