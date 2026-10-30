#!/usr/bin/env python3
"""Private ownership receipts for native budget fixtures, including SIGKILL."""
import json,os,shutil,signal,subprocess,sys,tempfile,time
from pathlib import Path

MARKERS=Path('/tmp')/('sdepsBudgetLease3-'+str(os.getuid()))

def identity(pid):
    p=subprocess.run(['ps','-o','lstart=,command=','-p',str(pid)],capture_output=True,text=True)
    return p.stdout.strip() if p.returncode==0 else ''

def command(pid):
    p=subprocess.run(['ps','-o','command=','-p',str(pid)],capture_output=True,text=True)
    return p.stdout.strip() if p.returncode==0 else ''

def stat(pid):
    return subprocess.run(['ps','-o','stat=','-p',str(pid)],capture_output=True,text=True).stdout.strip()

def live(pid):
    s=stat(pid)
    return bool(s) and not s.startswith('Z')

def judgment(pid,root):
    """The parent of pid when pid runs this tree's core, else None.

    getppid() of an orphan answers init or a subreaper, so a pid alone never
    says whose it is. What a process runs does.
    """
    core=str(Path(root)/'bin/native/');entry=str(Path(root)/'scripts/safedeps-hook-entry.sh')
    if pid<=1 or core not in command(pid):return None
    p=subprocess.run(['ps','-o','ppid=','-p',str(pid)],capture_output=True,text=True)
    parent=int(p.stdout.strip() or 0)
    above=command(parent) if parent>1 else ''
    return parent if core in above or entry in above else None

def create(suite):
    MARKERS.mkdir(mode=0o700,exist_ok=True)
    lease=Path(tempfile.mkdtemp(prefix=str(os.getpid())+'-',dir=MARKERS))
    (lease/'owner.tmp').write_text(json.dumps(dict(pid=os.getpid(),identity=identity(os.getpid()),
        suite=int(suite),suite_identity=identity(int(suite)))))
    os.replace(lease/'owner.tmp',lease/'owner.json')
    return lease

def register(lease,pid,role):
    if pid<=1:raise RuntimeError('pid '+str(pid)+' is no process a run owns')
    lease=Path(lease);who=identity(pid)
    if not who:raise RuntimeError('owned process disappeared before registration')
    path=lease/(str(pid)+'.json');tmp=lease/(str(pid)+'.'+str(os.getpid())+'.tmp')
    tmp.write_text(json.dumps(dict(pid=pid,identity=who,role=role)))
    os.replace(tmp,path)

def cleanup(lease):
    lease=Path(lease);rows=[];refused=[]
    # Suites that start together sweep the same stale leases, and one finishes first.
    try:paths=list(lease.glob('*.json'))
    except FileNotFoundError:paths=[]
    for path in paths:
        if path.name=='owner.json':continue
        try:r=json.loads(path.read_text())
        except FileNotFoundError:continue
        if r['pid']<=1:refused.append(r['pid'])  # an older run's record of init
        elif identity(r['pid'])==r['identity']:rows.append(r)
    # Continue stopped tasks before killing them; no group-id inference.
    for sig in (signal.SIGCONT,signal.SIGKILL):
        for r in rows:
            if r['pid'] in refused or identity(r['pid'])!=r['identity']:continue
            try:os.kill(r['pid'],sig)
            except ProcessLookupError:pass
            except PermissionError:refused.append(r['pid'])
    rows=[r for r in rows if r['pid'] not in refused]
    survivors=[]
    for r in rows:
        for _ in range(100):
            if identity(r['pid'])!=r['identity'] or not live(r['pid']):break
            time.sleep(.01)
        else:survivors.append(r['pid'])
    if not survivors:shutil.rmtree(lease,ignore_errors=True)
    return dict(lease=str(lease),reaped=[r['pid'] for r in rows],refused=refused,survivors=survivors)

def ended(pid):
    try:os.kill(pid,0)
    except (ProcessLookupError,PermissionError):return True
    return False

def owner_gone(info):
    # A ps that did not answer says nothing, so it never ends a live owner.
    if ended(info['pid']):return True
    who=identity(info['pid'])
    return bool(who) and who!=info['identity'] or stat(info['pid']).startswith('Z')

def sweep(suite=None):
    rows=[]
    if not MARKERS.exists():return rows
    for lease in sorted(MARKERS.iterdir()):
        owner=lease/'owner.json'
        if not owner.exists():
            # Cut short before its owner record, so nothing was registered in it.
            if ended(int(lease.name.partition('-')[0])):shutil.rmtree(lease,ignore_errors=True)
            continue
        try:info=json.loads(owner.read_text())
        except FileNotFoundError:continue  # the live owner completed cleanup
        own=(suite is not None and info['suite']==int(suite)
             and info.get('suite_identity')==identity(int(suite)))
        if own or owner_gone(info):rows.append(cleanup(lease))
    return rows

if __name__=='__main__':
    rows=sweep(sys.argv[2] if len(sys.argv)>2 and sys.argv[1]=='cleanup' else None)
    print('native budget fixture sweep: '+json.dumps(rows),flush=True)
    raise SystemExit(int(any(r['survivors'] for r in rows)))
