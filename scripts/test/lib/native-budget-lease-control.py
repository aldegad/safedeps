#!/usr/bin/env python3
"""What a sweep does to the leases it finds, in a marker root of this run's own."""
import json,os,signal,subprocess,sys,tempfile,time
from pathlib import Path
import native_budget_owners as owners

def dead_pid():
    p=subprocess.Popen(['true']);p.wait()
    return p.pid

def sleeper():
    return subprocess.Popen([sys.executable,'-c','import time;time.sleep(60)'],start_new_session=True)

def lease_of(owner_pid,identity,name):
    lease=owners.MARKERS/(str(owner_pid)+'-'+name);lease.mkdir()
    (lease/'owner.json').write_text(json.dumps(dict(pid=owner_pid,identity=identity,suite=owner_pid,suite_identity=identity)))
    return lease

def check(passed,label):
    print(('ok' if passed else 'not ok')+' - '+label,flush=True)
    return passed

def main():
    root=Path(sys.argv[1]).resolve();results=[];spawned=[];real_kill=os.kill;signalled=[]
    def spy(pid,sig):
        signalled.append(pid);real_kill(pid,sig)
    with tempfile.TemporaryDirectory(prefix='native-budget-lease.') as tmp:
        owners.MARKERS=Path(tmp)/'markers';owners.MARKERS.mkdir(mode=0o700)
        os.kill=spy
        try:
            # An older run left a record of pid 1 beside a process it did own.
            child=sleeper();spawned.append(child)
            stale=lease_of(dead_pid(),'gone','stale')
            (stale/'1.json').write_text(json.dumps(dict(pid=1,identity=owners.identity(1),role='judgment')))
            owners.register(stale,child.pid,'npm')
            receipts=owners.sweep()
            results.append(check(len(receipts)==1 and not stale.exists() and child.wait(timeout=10)==-signal.SIGKILL and 1 not in signalled,
                                 "a dead owner's lease with a record of pid 1 is cleared, its own process killed, pid 1 not signalled"))
            # A live owner's lease is not the sweep's, even when ps does not answer.
            mine=owners.create(os.getpid());witness=sleeper();spawned.append(witness);owners.register(mine,witness.pid,'witness')
            owners.sweep()
            read=owners.identity;owners.identity=lambda pid:''
            try:owners.sweep()
            finally:owners.identity=read
            results.append(check(mine.exists() and witness.poll() is None,"a live owner's lease stays, also through a ps read that failed"))
            owners.cleanup(mine)
            # A lease cut short before its owner record has nothing registered in it.
            cut=owners.MARKERS/(str(dead_pid())+'-cut');cut.mkdir()
            kept=owners.MARKERS/(str(os.getpid())+'-kept');kept.mkdir()
            owners.sweep()
            results.append(check(not cut.exists() and kept.exists(),"a lease with no owner record goes when the pid in its name is gone, and only then"))
            kept.rmdir()
            # Suites that start together sweep the same stale leases.
            for i in range(20):
                stale=lease_of(dead_pid(),'gone','race'+str(i))
                (stale/'1.json').write_text(json.dumps(dict(pid=1,identity=owners.identity(1),role='judgment')))
            sweeps=[]
            for i in range(8):
                pid=os.fork()
                if pid==0:
                    try:owners.sweep();os._exit(0)
                    except BaseException:os._exit(1)
                sweeps.append(pid)
            codes=[os.waitpid(pid,0)[1] for pid in sweeps]
            results.append(check(codes==[0]*8 and not list(owners.MARKERS.iterdir()),'eight sweeps of the same stale leases all finish and leave none'))
            # Those eight may never meet. This is what the one that loses finds.
            results.append(check(owners.cleanup(owners.MARKERS/'finished')['reaped']==[],'a lease another sweep finished is nothing to clean'))
            # What getppid() answers for an orphan is init or a subreaper.
            other=sleeper();spawned.append(other)
            results.append(check(all(owners.judgment(pid,root) is None for pid in (0,1,other.pid)),
                                 'neither init nor a process of another program is named as a judgment'))
        finally:
            os.kill=real_kill
            for p in spawned:
                if p.poll() is None:p.kill();p.wait()
    return int(not all(results))

raise SystemExit(main())
