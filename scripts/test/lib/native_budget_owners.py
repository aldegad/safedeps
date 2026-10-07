#!/usr/bin/env python3
"""Private ownership receipts for native budget fixtures, including SIGKILL."""
import json,os,shutil,signal,subprocess,sys,tempfile,time
from pathlib import Path

MARKERS=Path('/tmp')/('sdepsBudgetLease3-'+str(os.getuid()))

def identity(pid):
    p=subprocess.run(['ps','-o','lstart=,command=','-p',str(pid)],capture_output=True,text=True)
    return p.stdout.strip() if p.returncode==0 else ''

def live(pid):
    p=subprocess.run(['ps','-o','stat=','-p',str(pid)],capture_output=True,text=True)
    s=p.stdout.strip()
    return bool(s) and not s.startswith('Z')

def create(suite):
    MARKERS.mkdir(mode=0o700,exist_ok=True)
    lease=Path(tempfile.mkdtemp(prefix=str(os.getpid())+'-',dir=MARKERS))
    (lease/'owner.tmp').write_text(json.dumps(dict(pid=os.getpid(),identity=identity(os.getpid()),
        suite=int(suite),suite_identity=identity(int(suite)))))
    os.replace(lease/'owner.tmp',lease/'owner.json')
    return lease

def register(lease,pid,role):
    lease=Path(lease);who=identity(pid)
    if not who:raise RuntimeError('owned process disappeared before registration')
    path=lease/(str(pid)+'.json');tmp=lease/(str(pid)+'.'+str(os.getpid())+'.tmp')
    tmp.write_text(json.dumps(dict(pid=pid,identity=who,role=role)))
    os.replace(tmp,path)

def cleanup(lease):
    lease=Path(lease);rows=[]
    for path in lease.glob('*.json'):
        if path.name=='owner.json':continue
        r=json.loads(path.read_text())
        if identity(r['pid'])==r['identity']:rows.append(r)
    # Continue stopped tasks before killing them; no group-id inference.
    for sig in (signal.SIGCONT,signal.SIGKILL):
        for r in rows:
            if identity(r['pid'])!=r['identity']:continue
            try:os.kill(r['pid'],sig)
            except ProcessLookupError:pass
    survivors=[]
    for r in rows:
        for _ in range(100):
            if identity(r['pid'])!=r['identity'] or not live(r['pid']):break
            time.sleep(.01)
        else:survivors.append(r['pid'])
    if not survivors:shutil.rmtree(lease)
    return dict(lease=str(lease),reaped=[r['pid'] for r in rows],survivors=survivors)

def sweep(suite=None):
    rows=[]
    if not MARKERS.exists():return rows
    for lease in sorted(MARKERS.iterdir()):
        owner=lease/'owner.json'
        if not owner.exists():continue
        try:info=json.loads(owner.read_text())
        except FileNotFoundError:continue  # the live owner completed cleanup
        own=(suite is not None and info['suite']==int(suite)
             and info.get('suite_identity')==identity(int(suite)))
        gone=identity(info['pid'])!=info['identity'] or not live(info['pid'])
        if own or gone:rows.append(cleanup(lease))
    return rows

if __name__=='__main__':
    rows=sweep(sys.argv[2] if len(sys.argv)>2 and sys.argv[1]=='cleanup' else None)
    print('native budget fixture sweep: '+json.dumps(rows),flush=True)
    raise SystemExit(int(any(r['survivors'] for r in rows)))
