#!/usr/bin/env python3
"""Private ownership receipts for native budget fixtures, including SIGKILL.

A sweep ends other runs' processes, so running() is the one reader of whether a
process is gone, and it answers that only from a fact. What it does not know
ends nothing and removes nothing.
"""
import json,os,re,shutil,signal,subprocess,sys,tempfile,time
from pathlib import Path

MARKERS=Path('/tmp')/('sdepsBudgetLease3-'+str(os.getuid()))
# An identity: lstart as the C locale prints it, then the command.
IDENTITY=re.compile(r'(\w{3} \w{3} [ \d]\d \d\d:\d\d:\d\d \d{4})\s+(\S.*)',re.S)

def ps(fields,pid):
    # Exit 1 is a missing pid and a failed ps alike, so an empty answer says neither.
    try:p=subprocess.run(['ps','-o',fields,'-p',str(pid)],capture_output=True,text=True,errors='replace',env=dict(os.environ,LC_ALL='C'))
    except OSError:return ''
    return p.stdout.strip() if p.returncode==0 else ''

def identity(pid):
    who=ps('lstart=,command=',pid)
    return who if IDENTITY.fullmatch(who) else ''

def command(pid):
    return ps('command=',pid)

def stat(pid):
    return ps('stat=',pid)

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
    parent=int(ps('ppid=',pid) or 0)
    above=command(parent) if parent>1 else ''
    return parent if core in above or entry in above else None

def named(pid):
    """pid's identity, asking again while pid exists and ps gives none."""
    for attempt in range(5):
        who=identity(pid)
        if who or ended(pid):break
        time.sleep(.2)
    return who

def create(suite):
    # A sweep can read a lease the moment it exists, so a run that cannot be named
    # does not start: a failed ps is asked again, and one that stays failed refuses.
    who=named(os.getpid());above=who and named(int(suite))
    if not above:raise RuntimeError('ps gave no identity for this run or its suite '+str(suite)+', so the run does not start')
    MARKERS.mkdir(mode=0o700,exist_ok=True)
    lease=Path(tempfile.mkdtemp(prefix=str(os.getpid())+'-',dir=MARKERS))
    (lease/'owner.tmp').write_text(json.dumps(dict(pid=os.getpid(),identity=who,suite=int(suite),suite_identity=above)))
    os.replace(lease/'owner.tmp',lease/'owner.json')
    return lease

def register(lease,pid,role):
    if pid<=1:raise RuntimeError('pid '+str(pid)+' is no process a run owns')
    lease=Path(lease);who=named(pid)
    if not who:raise RuntimeError('pid '+str(pid)+' has no identity to register: it ended, or ps did not answer')
    path=lease/(str(pid)+'.json');tmp=lease/(str(pid)+'.'+str(os.getpid())+'.tmp')
    tmp.write_text(json.dumps(dict(pid=pid,identity=who,role=role)))
    os.replace(tmp,path)

def load(path):
    """The record in path, {} for a file that holds none. A missing file raises."""
    try:r=json.loads(path.read_text())
    except FileNotFoundError:raise
    except (OSError,ValueError):return {}
    return r if isinstance(r,dict) else {}

def cleanup(lease):
    lease=Path(lease);rows=[];refused=[];unknown=[]
    # Suites that start together sweep the same stale leases, and one finishes first.
    try:paths=list(lease.glob('*.json'))
    except FileNotFoundError:paths=[]
    for path in paths:
        if path.name=='owner.json':continue
        try:r=load(path)
        except FileNotFoundError:continue
        if type(r.get('pid')) is not int:unknown.append(path.name);continue
        if r['pid']<=1:refused.append(r['pid']);continue  # an older run's record of init
        now=running(r)
        if now:rows.append(r)
        elif now is None:unknown.append(r['pid'])
    # Continue stopped tasks before killing them; no group-id inference.
    for sig in (signal.SIGCONT,signal.SIGKILL):
        for r in rows:
            if r['pid'] in unknown or not running(r):continue
            try:os.kill(r['pid'],sig)
            except ProcessLookupError:pass
            except PermissionError:unknown.append(r['pid'])
    rows=[r for r in rows if r['pid'] not in unknown]
    survivors=[]
    for r in rows:
        for _ in range(100):
            if running(r) is False:break
            time.sleep(.01)
        else:survivors.append(r['pid'])
    # What is unknown stays on record for the next sweep to read.
    if not survivors and not unknown:shutil.rmtree(lease,ignore_errors=True)
    return dict(lease=str(lease),reaped=[r['pid'] for r in rows],refused=refused,survivors=survivors,unknown=unknown)

def ended(pid):
    try:os.kill(pid,0)
    except ProcessLookupError:return True
    except (PermissionError,OverflowError):pass  # a refusal is no word that the pid is gone
    return False

def running(row):
    """Whether the process a record names runs: True, False, or None when not known.

    False is a fact: the kernel has no such pid, ps shows a zombie, or ps shows
    another process under the pid. A ps that gave nothing and a record with
    nothing to compare are None.

    exec keeps a process's start, so its start answers True. Another time zone
    prints the same process with another start, so only a start and a command
    that both differ answer False.
    """
    pid=row.get('pid')
    if type(pid) is not int or pid<=1:return None
    if ended(pid) or stat(pid).startswith('Z'):return False
    then=IDENTITY.fullmatch(str(row.get('identity')));now=IDENTITY.fullmatch(identity(pid))
    if not now and ended(pid):return False  # it ended while ps was read
    if not then or not now:return None
    if then[1]==now[1]:return True
    return None if then[2]==now[2] else False

def sweep(suite=None):
    rows=[]
    if not MARKERS.exists():return rows
    above=identity(int(suite)) if suite is not None else ''
    for lease in sorted(MARKERS.iterdir()):
        recorded=True
        try:info=load(lease/'owner.json')
        except FileNotFoundError:info={};recorded=False  # cut short before its record, or its live owner finished
        # The name holds the pid that made the lease, and a broken record never reaches it.
        maker=lease.name.partition('-')[0]
        now=running(dict(pid=int(maker) if maker.isdecimal() else None,identity=info.get('identity')))
        own=bool(above) and info.get('suite')==int(suite) and info.get('suite_identity')==above
        if own or now is False:rows.append(cleanup(lease))
        elif now is None and recorded:
            print('# note - a lease stays, its owner not known to be gone: '+str(lease),file=sys.stderr,flush=True)
    return rows

if __name__=='__main__':
    rows=sweep(sys.argv[2] if len(sys.argv)>2 and sys.argv[1]=='cleanup' else None)
    print('native budget fixture sweep: '+json.dumps(rows),flush=True)
    raise SystemExit(int(any(r['survivors'] for r in rows)))
