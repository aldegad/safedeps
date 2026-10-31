#!/usr/bin/env python3
"""What a sweep does to the leases it finds, in a marker root of this run's own."""
import contextlib,io,json,os,shutil,signal,subprocess,sys,tempfile,time
from pathlib import Path
from unittest import mock
import native_budget_owners as owners

# A ps line of no process running now: another start, another command.
ANOTHER='Thu Jan  1 00:00:00 2026     /gone/owner --box gone'

def dead_pid():
    p=subprocess.Popen(['true']);p.wait()
    return p.pid

def sleeper():
    return subprocess.Popen(['sleep','60'],start_new_session=True)

def lease_of(owner_pid,identity,name):
    lease=owners.MARKERS/(str(owner_pid)+'-'+name);lease.mkdir()
    (lease/'owner.json').write_text(json.dumps(dict(pid=owner_pid,identity=identity,suite=owner_pid,suite_identity=identity)))
    return lease

def check(passed,label):
    print(('ok' if passed else 'not ok')+' - '+label,flush=True)
    return passed

def until(fact):
    for _ in range(500):
        if fact():return True
        time.sleep(.01)
    return False

def killed(process):
    try:return process.wait(timeout=5)==-signal.SIGKILL
    except subprocess.TimeoutExpired:return False

def swept(*suite):
    """A sweep's receipts, or what it died of. The leases it notes here are this control's."""
    try:
        with contextlib.redirect_stderr(io.StringIO()):return owners.sweep(*suite)
    except Exception as e:return 'the sweep died: '+repr(e)

@contextlib.contextmanager
def failing_ps(tmp,times):
    """ps exits 1 the next times it runs. PATH decides what starts, so no reader is stubbed."""
    shim=Path(tmp)/'ps-shim';shim.mkdir(exist_ok=True);left=shim/'left';left.write_text(str(times)+'\n')
    (shim/'ps').write_text('#!/bin/sh\nread left < "'+str(left)+'"\nif [ "$left" -gt 0 ]; then echo $((left - 1)) > "'+str(left)+'"; exit 1; fi\n'
                           'exec '+shutil.which('ps')+' "$@"\n')
    (shim/'ps').chmod(0o755)
    with mock.patch.dict(os.environ,PATH=str(shim)+':'+os.environ['PATH']):yield

@contextlib.contextmanager
def markers(tmp,name):
    """A marker root of the row's own, so a row that fails hands the next none of its leases."""
    saved=owners.MARKERS;owners.MARKERS=Path(tmp)/name;owners.MARKERS.mkdir(mode=0o700)
    try:yield
    finally:owners.MARKERS=saved

def broken_owner_records():
    """What an owner.json can hold that does not say who owns the lease."""
    who=owners.identity(os.getpid());mine=os.getpid();plain=lambda **fields:json.dumps(fields).encode()
    return {'an empty file':b'','a torn record':b'{"pid":','bytes that are no text':b'\xff\xfe','a list':b'[]','null':b'null',
            'no identity':plain(pid=mine,suite=1),'an empty identity':plain(pid=mine,identity=''),
            'a blank identity':plain(pid=mine,identity='  '),'a null identity':plain(pid=mine,identity=None),
            'a number for an identity':plain(pid=mine,identity=7),'an identity that is no ps line':plain(pid=mine,identity='gone'),
            'a pid that is text':plain(pid=str(mine),identity=who),'a pid of a dead process':plain(pid=dead_pid(),identity=who),
            'pid 1':plain(pid=1,identity=who),'no pid':plain(identity=who)}

def forms_failing(tmp,prefix,maker,holds):
    """Each broken owner record alone in a marker root: the ones holds() is false for."""
    failed=[]
    for i,(name,text) in enumerate(broken_owner_records().items()):
        with markers(tmp,prefix+str(i)):
            child=sleeper();lease=owners.MARKERS/(str(maker())+'-form');lease.mkdir()
            (lease/'owner.json').write_bytes(text);owners.register(lease,child.pid,'witness')
            if isinstance(swept(),str) or not holds(lease,child):failed.append(name)
            if child.poll() is None:child.kill()
            child.wait()
    return failed

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
            try:swept()
            finally:owners.identity=read
            results.append(check(mine.exists() and witness.poll() is None,"a live owner's lease stays, also through a ps read that failed"))
            owners.cleanup(mine)
            # The record a later sweep reads is made here, so a failed ps must not reach it.
            with markers(tmp,'made'):
                with failing_ps(tmp,1):mine=owners.create(os.getpid())
                witness=sleeper();spawned.append(witness)
                try:
                    with failing_ps(tmp,1):owners.register(mine,witness.pid,'witness')
                    registered=True
                except RuntimeError:
                    registered=False;owners.register(mine,witness.pid,'witness')
                recorded=json.loads((mine/'owner.json').read_text());receipts=swept()
                results.append(check(registered and bool(recorded['identity']) and receipts==[] and mine.exists() and witness.poll() is None,
                                     "one failed ps while a lease is made: the record names its owner, and the lease and its child stay"))
                owners.cleanup(mine)
            with markers(tmp,'never'):
                with failing_ps(tmp,999):
                    try:lease=owners.create(os.getpid())
                    except RuntimeError:lease=None
                results.append(check(lease is None and not list(owners.MARKERS.iterdir()),"a run ps never names does not start, and makes no lease"))
            # A record that does not say who owns a lease is no word that the owner is gone.
            failed=forms_failing(tmp,'live',os.getpid,lambda lease,child:lease.exists() and child.poll() is None)
            results.append(check(not failed,"a live owner's lease stays whatever its record holds"+(': '+str(failed) if failed else '')))
            failed=forms_failing(tmp,'dead',dead_pid,lambda lease,child:killed(child) and not lease.exists())
            results.append(check(not failed,"the pid in a lease's name is enough: with it gone a broken record goes, and its process"+(': '+str(failed) if failed else '')))
            with markers(tmp,'said'):
                lease=owners.MARKERS/(str(os.getpid())+'-said');lease.mkdir();(lease/'owner.json').write_text('{"pid":')
                note=io.StringIO()
                with contextlib.redirect_stderr(note):owners.sweep()
                results.append(check(str(lease) in note.getvalue(),"a lease left because its owner is not known is named"))
            # A reader in another zone or locale prints the same process another way.
            with markers(tmp,'zone'):
                mine=owners.create(os.getpid());witness=sleeper();spawned.append(witness);owners.register(mine,witness.pid,'witness')
                recorded=json.loads((mine/'owner.json').read_text())['identity']
                with mock.patch.dict(os.environ,TZ='SDT-13'):
                    differs=owners.identity(os.getpid())!=recorded;zone=swept()
                with mock.patch.dict(os.environ,LC_ALL='ko_KR.UTF-8'):
                    same=owners.identity(os.getpid())==recorded;spoken=swept()
                results.append(check(differs and same and zone==[] and spoken==[] and mine.exists() and witness.poll() is None,
                                     "a sweep in another time zone or locale leaves a live owner's lease"))
                owners.cleanup(mine)
            # The kernel refusing to say is not the kernel saying the pid is gone.
            with markers(tmp,'refused'):
                mine=owners.create(os.getpid());witness=sleeper();spawned.append(witness);owners.register(mine,witness.pid,'witness')
                def refusing(pid,sig):
                    if pid==os.getpid():raise PermissionError(1,'not permitted')
                    spy(pid,sig)
                os.kill=refusing
                try:receipts=swept()
                finally:os.kill=spy
                results.append(check(receipts==[] and mine.exists() and witness.poll() is None,"a pid the kernel will not let this user signal is no gone owner"))
                owners.cleanup(mine)
            # Two empty strings match, and neither names a suite.
            with markers(tmp,'suite'):
                witness=sleeper();spawned.append(witness);lease=owners.MARKERS/(str(os.getpid())+'-suite');lease.mkdir()
                (lease/'owner.json').write_text(json.dumps(dict(pid=os.getpid(),identity=owners.identity(os.getpid()),suite=os.getpid(),suite_identity='')))
                owners.register(lease,witness.pid,'witness')
                with failing_ps(tmp,1):swept(os.getpid())
                results.append(check(lease.exists() and witness.poll() is None,"an empty suite identity claims no lease, also when ps gives none either"))
                owners.cleanup(lease)
            # What a sweep does know still ends a lease.
            with markers(tmp,'other'):
                holder=sleeper();spawned.append(holder);child=sleeper();spawned.append(child);late=sleeper();spawned.append(late)
                lease=lease_of(holder.pid,ANOTHER,'other');owners.register(lease,child.pid,'npm')
                (lease/(str(late.pid)+'.json')).write_text(json.dumps(dict(pid=late.pid,identity=ANOTHER,role='npm')))
                swept()
                results.append(check(not lease.exists() and killed(child) and holder.poll() is None and late.poll() is None,
                                     "another process under an owner's pid ends the lease, and one under a child's pid is not signalled"))
            with markers(tmp,'zombie'):
                zombie=subprocess.Popen(['true']);child=sleeper();spawned.append(child)
                dead=until(lambda:owners.stat(zombie.pid).startswith('Z'))
                lease=lease_of(zombie.pid,owners.identity(zombie.pid),'zombie');owners.register(lease,child.pid,'npm')
                swept();zombie.wait()
                results.append(check(dead and not lease.exists() and killed(child),"a zombie owner is gone"))
            # exec keeps a process's pid and start, and the entry starts through env.
            with markers(tmp,'exec'):
                turned=subprocess.Popen(['/bin/sh','-c','read line; exec sleep 60'],stdin=subprocess.PIPE,start_new_session=True);spawned.append(turned)
                mine=owners.create(os.getpid());owners.register(mine,turned.pid,'entry');before=owners.identity(turned.pid)
                turned.stdin.write(b'\n');turned.stdin.close()
                moved=until(lambda:owners.identity(turned.pid) not in ('',before))
                owners.cleanup(mine)
                results.append(check(moved and killed(turned) and not mine.exists(),"a process that exec'd after its registration is still the one registered"))
            # Cleanup answers the same way: what it does not know it keeps, and says so.
            with markers(tmp,'silent'):
                mine=owners.create(os.getpid());witness=sleeper();spawned.append(witness);owners.register(mine,witness.pid,'witness')
                with failing_ps(tmp,999):first=owners.cleanup(mine)
                stayed=mine.exists() and witness.poll() is None and first.get('unknown')==[witness.pid]
                second=owners.cleanup(mine)
                results.append(check(stayed and killed(witness) and not mine.exists() and second.get('unknown')==[],
                                     "cleanup keeps a lease while ps gives no word of its process, and finishes once ps answers"))
            with markers(tmp,'torn'):
                child=sleeper();spawned.append(child);bare=sleeper();spawned.append(bare)
                lease=lease_of(dead_pid(),'gone','torn');owners.register(lease,child.pid,'npm');(lease/'77.json').write_text('{"pid":')
                (lease/(str(bare.pid)+'.json')).write_text(json.dumps(dict(pid=bare.pid,identity='',role='npm')))
                receipts=swept()
                named=not isinstance(receipts,str) and len(receipts)==1 and sorted(map(str,receipts[0].get('unknown',[])))==sorted([str(bare.pid),'77.json'])
                results.append(check(named and lease.exists() and killed(child) and bare.poll() is None,
                                     "a dead owner's lease keeps the records that say nothing, names them, and cleans the rest"))
                with failing_ps(tmp,999):silent=swept()
                results.append(check(lease.exists() and bare.poll() is None and not isinstance(silent,str),
                                     "a record with no identity signals nothing, also when ps gives none to compare it with"))
                (lease/'77.json').unlink();bare.kill();bare.wait();swept()
                results.append(check(not lease.exists(),"the next sweep finishes that lease once nothing in it is unknown"))
            with markers(tmp,'unsignalled'):
                mine=owners.create(os.getpid());witness=sleeper();spawned.append(witness);owners.register(mine,witness.pid,'witness')
                def deny(pid,sig):
                    if pid==witness.pid and sig:raise PermissionError(1,'not permitted')
                    spy(pid,sig)
                os.kill=deny
                try:receipt=owners.cleanup(mine)
                finally:os.kill=spy
                results.append(check(mine.exists() and witness.poll() is None and witness.pid in receipt.get('unknown',[]),"cleanup keeps a lease whose process refused the signal"))
                owners.cleanup(mine)
            with markers(tmp,'strays'):
                (owners.MARKERS/'stray').write_text('x');(owners.MARKERS/'no-pid').mkdir()
                shut=owners.MARKERS/(str(os.getpid())+'-shut');shut.mkdir()
                closed=owners.MARKERS/(str(os.getpid())+'-closed');closed.mkdir();(closed/'owner.json').write_text('{}');(closed/'owner.json').chmod(0)
                shut.chmod(0);receipts=swept();shut.chmod(0o700)
                results.append(check(receipts==[] and all(p.exists() for p in ((owners.MARKERS/'stray'),(owners.MARKERS/'no-pid'),shut,closed)),"what else a marker root holds, or does not let this user read, ends no sweep"))
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
            # Those eight may never meet, so the loser's error is raised here. A
            # directory already gone lists as empty: only one that goes during the
            # listing raises, and no order of calls reaches that.
            def lost(path,pattern):raise FileNotFoundError(str(path))
            listing=Path.glob;Path.glob=lost
            try:receipt=owners.cleanup(owners.MARKERS/'finished')
            finally:Path.glob=listing
            results.append(check(receipt['reaped']==[],'a lease another sweep finished during the listing is nothing to clean'))
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
