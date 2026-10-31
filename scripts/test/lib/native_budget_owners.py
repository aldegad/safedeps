#!/usr/bin/env python3
"""Private ownership receipts for native budget fixtures, including SIGKILL.

A process is its pid and the start the kernel stored when it forked. exec keeps
that number, and no reader's time zone, locale or PATH reaches it, so an identity
is read from the kernel, never from a line ps prints. The program stays in a
record as a label for whoever reads one, and no verdict reads it.

A sweep ends other runs' processes, so running() is the one reader of whether a
process is gone, and it answers that only from a fact. What it does not know
ends nothing and removes nothing.
"""
import json,os,re,shutil,signal,struct,subprocess,sys,tempfile,time
from pathlib import Path

MARKERS=Path('/tmp')/('sdepsBudgetLease3-'+str(os.getuid()))
# An identity: the start the kernel holds, then the program as a label.
IDENTITY=re.compile(r'([0-9]+)\s+(\S.*)',re.S)
# sizeof(struct kinfo_proc), Darwin SDK sys/sysctl.h.
KINFO=648
# A SIGKILL lands when the machine gets to it, so the wait for it is time, not reads.
REAP_SECONDS=30

def ps(fields,pid):
    # Exit 1 is a missing pid and a failed ps alike, so an empty answer says neither.
    try:p=subprocess.run(['ps','-o',fields,'-p',str(pid)],capture_output=True,text=True,errors='replace')
    except OSError:return ''
    return p.stdout.strip() if p.returncode==0 else ''

def kernel_row(pid):
    """What the kernel holds for pid, as it gives it, None when the call failed."""
    if sys.platform!='darwin':
        try:return Path('/proc/'+str(pid)+'/stat').read_bytes()
        except OSError:return None
    import ctypes  # here, because every npm question starts this module and most never read
    mib=(ctypes.c_int*4)(1,14,1,pid);size=ctypes.c_size_t(KINFO);box=ctypes.create_string_buffer(KINFO)  # CTL_KERN, KERN_PROC, KERN_PROC_PID
    if ctypes.CDLL(None).sysctl(mib,ctypes.c_uint(4),box,ctypes.byref(size),None,ctypes.c_size_t(0))!=0:return None
    return box.raw[:size.value]

def from_kinfo(raw,pid):
    # struct kinfo_proc, Darwin SDK sys/sysctl.h: p_starttime 0, p_stat 36, p_pid 40, p_comm 243.
    if len(raw)!=KINFO or struct.unpack_from('i',raw,40)[0]!=pid:return None
    sec,usec=struct.unpack_from('qi',raw,0)
    if sec<=0 or not 0<=usec<1000000:return None
    return {4:'T',5:'Z'}.get(raw[36],'R'),sec*1000000+usec,raw[243:260].split(b'\0')[0].decode('utf-8','replace')

def from_proc(raw):
    # /proc/<pid>/stat: pid (comm) state ..., the start in field 22. comm can hold anything, so the fields follow its last ')'.
    name,close,rest=raw.rpartition(b')');fields=rest.split()
    if not close or len(fields)<20 or not fields[19].isdigit() or int(fields[19])<=0:return None
    return fields[0].decode('ascii','replace'),int(fields[19]),name.partition(b'(')[2].decode('utf-8','replace')

def kernel(pid):
    """(state, start, program) as the kernel holds pid, None when it gave no record of it.

    That answer is final: a read that failed is not known, and nothing here asks ps instead.
    """
    if not 0<pid<2**31:return None  # a C int wraps a wider pid, silently, into another process
    raw=kernel_row(pid)
    if raw is None:return None
    return from_kinfo(raw,pid) if sys.platform=='darwin' else from_proc(raw)

def identity(pid):
    now=kernel(pid)
    return str(now[1])+' '+(now[2].strip() or '?') if now else ''

def start(who):
    """The start in an identity, '' when it holds none."""
    known=IDENTITY.fullmatch(str(who))
    return known[1] if known else ''

def command(pid):
    return ps('command=',pid)

def stat(pid):
    now=kernel(pid)
    return now[0] if now else ''

def live(pid):
    s=stat(pid)
    return bool(s) and not s.startswith('Z')

def nothing_holds(text):
    """True once pgrep says no command holds text. It exits 1 for none, and a failure is no word."""
    until=time.monotonic()+REAP_SECONDS
    while True:
        if subprocess.run(['pgrep','-f',text],capture_output=True).returncode==1:return True
        if time.monotonic()>=until:return False
        time.sleep(.02)

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
    """pid's identity, asking again while pid exists and the kernel gives none."""
    for attempt in range(5):
        who=identity(pid)
        if who or ended(pid):break
        time.sleep(.2)
    return who

def create(suite):
    # A sweep can read a lease the moment it exists, so a run that cannot be named
    # does not start: a failed read is asked again, and one that stays failed refuses.
    who=named(os.getpid());above=who and named(int(suite))
    if not above:raise RuntimeError('the kernel gave no identity for this run or its suite '+str(suite)+', so the run does not start')
    MARKERS.mkdir(mode=0o700,exist_ok=True)
    lease=Path(tempfile.mkdtemp(prefix=str(os.getpid())+'-',dir=MARKERS))
    (lease/'owner.tmp').write_text(json.dumps(dict(pid=os.getpid(),identity=who,suite=int(suite),suite_identity=above)))
    os.replace(lease/'owner.tmp',lease/'owner.json')
    return lease

def register(lease,pid,role):
    if pid<=1:raise RuntimeError('pid '+str(pid)+' is no process a run owns')
    lease=Path(lease);who=named(pid)
    if not who:raise RuntimeError('pid '+str(pid)+' has no identity to register: it ended, or the kernel did not answer')
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
    survivors=[r['pid'] for r in left(rows)]
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

    False is a fact: the kernel has no such pid, it holds a zombie, or it holds
    another start under the pid. A read that gave nothing and a record with no
    start to compare are None.
    """
    pid=row.get('pid')
    if type(pid) is not int or pid<=1:return None
    if ended(pid):return False
    now=kernel(pid)
    if now is None:return False if ended(pid) else None  # it ended while it was read
    if now[0]=='Z':return False
    then=start(row.get('identity'))
    return then==str(now[1]) if then else None

def left(rows):
    """The records whose process is not known to be gone once REAP_SECONDS have passed."""
    until=time.monotonic()+REAP_SECONDS
    while True:
        rows=[r for r in rows if running(r) is not False]
        if not rows or time.monotonic()>=until:return rows
        time.sleep(.01)

def sweep(suite=None):
    rows=[]
    if not MARKERS.exists():return rows
    above=start(identity(int(suite))) if suite is not None else ''
    for lease in sorted(MARKERS.iterdir()):
        recorded=True
        try:info=load(lease/'owner.json')
        except FileNotFoundError:info={};recorded=False  # cut short before its record, or its live owner finished
        # The name holds the pid that made the lease, and a broken record never reaches it.
        maker=lease.name.partition('-')[0]
        now=running(dict(pid=int(maker) if maker.isdecimal() else None,identity=info.get('identity')))
        own=bool(above) and info.get('suite')==int(suite) and start(info.get('suite_identity'))==above
        if own or now is False:rows.append(cleanup(lease))
        elif now is None and recorded:
            print('# note - a lease stays, its owner not known to be gone: '+str(lease),file=sys.stderr,flush=True)
    return rows

if __name__=='__main__':
    rows=sweep(sys.argv[2] if len(sys.argv)>2 and sys.argv[1]=='cleanup' else None)
    print('native budget fixture sweep: '+json.dumps(rows),flush=True)
    raise SystemExit(int(any(r['survivors'] for r in rows)))
