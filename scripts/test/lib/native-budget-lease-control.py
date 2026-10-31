#!/usr/bin/env python3
"""What a sweep does to the leases it finds, in a marker root of this run's own."""
import contextlib,io,json,os,signal,struct,subprocess,sys,tempfile,threading,time
from pathlib import Path
from unittest import mock
import native_budget_owners as owners

# What an older run's record holds: the line ps printed.
PS_LINE='Sat Oct 31 01:55:36 2026     /bin/sleep 60'

def dead_pid():
    p=subprocess.Popen(['true']);p.wait()
    return p.pid

def sleeper():
    return subprocess.Popen(['sleep','60'],start_new_session=True)

def turning():
    """A child that turns into sleep when it is given a line."""
    return subprocess.Popen(['/bin/sh','-c','read line; exec sleep 60'],stdin=subprocess.PIPE,start_new_session=True)

def program(pid):
    who=owners.IDENTITY.fullmatch(owners.identity(pid))
    return who[2] if who else ''

def earlier(pid):
    """pid's identity with another start: the record of an earlier process of the same program under this pid."""
    who=owners.IDENTITY.fullmatch(owners.identity(pid))
    return str(int(who[1])-1)+' '+who[2]

def printed(pid,zone):
    """The start ps prints for pid in a zone: the text no record rests on."""
    return subprocess.run(['ps','-o','lstart=','-p',str(pid)],capture_output=True,text=True,env=dict(os.environ,TZ=zone)).stdout.strip()

def stat_line(comm=b'sleep',state=b'S',start=b'4242'):
    return b'77 ('+comm+b') '+state+b' 1 77 77 0 -1 4194304 0 0 0 0 0 0 0 0 20 0 1 0 '+start+b' 0 0\n'

def kinfo(pid=77,sec=1793411278,usec=20139,state=2,comm=b'sleep'):
    raw=bytearray(owners.KINFO);struct.pack_into('qi',raw,0,sec,usec);raw[36]=state
    struct.pack_into('i',raw,40,pid);raw[243:243+len(comm)]=comm
    return bytes(raw)

def lease_of(owner_pid,identity,name):
    lease=owners.MARKERS/(str(owner_pid)+'-'+name);lease.mkdir()
    (lease/'owner.json').write_text(json.dumps(dict(pid=owner_pid,identity=identity,suite=owner_pid,suite_identity=identity)))
    return lease

def check(passed,label):
    print(('ok' if passed else 'not ok')+' - '+label,flush=True)
    return passed

def until(fact):
    end=time.monotonic()+owners.REAP_SECONDS
    while time.monotonic()<end:
        if fact():return True
        time.sleep(.01)
    return False

def killed(process):
    try:return process.wait(timeout=5)==-signal.SIGKILL
    except subprocess.TimeoutExpired:return False

def swept(*suite,note=None):
    """A sweep's receipts, or what it died of. The leases it notes here are this control's."""
    try:
        with contextlib.redirect_stderr(note or io.StringIO()):return owners.sweep(*suite)
    except Exception as e:return 'the sweep died: '+repr(e)

@contextlib.contextmanager
def failing_read(times,first=None):
    """The kernel call gives nothing the next times it runs, after first().

    Only that call changes, so every reader above it runs. It yields the pids it
    failed for, because a row whose failure never fired has seen nothing.
    """
    fired=[];real=owners.kernel_row
    def row(pid):
        if len(fired)>=times:return real(pid)
        if first:first()
        fired.append(pid)
        return None
    with mock.patch.object(owners,'kernel_row',row):yield fired

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
            'a number for an identity':plain(pid=mine,identity=7),'an identity with no start':plain(pid=mine,identity='gone'),
            'the line ps printed for an older run':plain(pid=mine,identity=PS_LINE),'a start with no label':plain(pid=mine,identity='12345'),
            'a start in digits the kernel does not write':plain(pid=mine,identity='١٢٣ sleep'),
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
        if sig:signalled.append(pid)
        real_kill(pid,sig)
    with tempfile.TemporaryDirectory(prefix='native-budget-lease.') as tmp:
        owners.MARKERS=Path(tmp)/'markers';owners.MARKERS.mkdir(mode=0o700)
        os.kill=spy
        try:
            # Each run holds the read to processes it knows, so an offset that moved or a start that is one constant is red here.
            older=owners.kernel(os.getpid());later=sleeper();spawned.append(later);now=owners.kernel(later.pid)
            results.append(check(older and now and older[1]<now[1] and now[2]=='sleep' and owners.kernel(dead_pid()) is None,
                                 "the kernel read names a live process, a later one by a later start, and no gone one"))
            with mock.patch.object(owners,'kernel',lambda pid:('R',5,' \n')):blank=owners.identity(9)
            results.append(check(owners.start(blank)=='5',"a program with no name to print still makes an identity with a start"))
            # /proc is not there on macOS, so what reads its line runs apart from the file, on every host.
            parse=owners.from_proc;broken=[b'',stat_line()[:30],stat_line(start=b'x'),stat_line(start=b'0'),stat_line().translate(None,b'()')]
            results.append(check(parse(stat_line())==('S',4242,'sleep') and parse(stat_line(comm=b'a) Z 9 (b c'))==('S',4242,'a) Z 9 (b c')
                                 and parse(stat_line(state=b'Z'))[0]=='Z' and all(parse(raw) is None for raw in broken),
                                 "a /proc stat line gives its state, start and program, whatever comm holds, and a broken one gives none"))
            parse=owners.from_kinfo;broken=[b'',kinfo()[:-1],kinfo(pid=78),kinfo(usec=1000000),kinfo(sec=0)]
            results.append(check(parse(kinfo(),77)==('R',1793411278020139,'sleep') and parse(kinfo(state=4),77)[0]=='T' and parse(kinfo(state=5),77)[0]=='Z'
                                 and all(parse(raw,77) is None for raw in broken),"a kinfo_proc gives its state, start and program, and a broken one gives none"))
            # Below the injection: the call itself, each platform's on every host. A call that
            # failed gives nothing, whatever it left in the buffer.
            class Failed:
                def __init__(self,name):pass
                def sysctl(self,mib,length,box,size,new,new_length):
                    box.raw=kinfo();return -1
            with mock.patch.object(owners.sys,'platform','darwin'),mock.patch('ctypes.CDLL',Failed):failed_call=owners.kernel_row(77)
            with mock.patch.object(owners.sys,'platform','linux'),mock.patch.object(Path,'read_bytes',side_effect=OSError(5,'no')):failed_file=owners.kernel_row(77)
            with mock.patch.object(owners.sys,'platform','linux'),mock.patch.object(Path,'read_bytes',lambda path:str(path).encode()):file_read=owners.kernel_row(77)
            results.append(check(failed_call is None and failed_file is None and file_read==b'/proc/77/stat',"a kernel call that failed gives nothing, and the file is the pid's stat"))
            # ctypes wraps 2^32+1 to 1 without a word.
            asked=[]
            with mock.patch.object(owners,'kernel_row',asked.append):
                wide=all(owners.kernel(pid) is None for pid in (0,-1,2**31,2**32+1))
            results.append(check(wide and not asked and owners.running(dict(pid=2**32+1,identity=owners.identity(os.getpid()))) is None,
                                 "a pid no C int holds never reaches the kernel call, and reads as not known"))
            # What a run counts as gone: not known is not gone, whichever reader gave no word.
            marked='sleep 60.'+str(os.getpid());holder=subprocess.Popen(marked.split(),start_new_session=True);spawned.append(holder)
            shim=Path(tmp)/'pgrep-shim';shim.mkdir();(shim/'pgrep').write_text('#!/bin/sh\nexit 3\n');(shim/'pgrep').chmod(0o755)
            record=dict(pid=holder.pid,identity=owners.identity(holder.pid))
            with mock.patch.object(owners,'REAP_SECONDS',.1):
                held=owners.nothing_holds(marked)
                with mock.patch.dict(os.environ,PATH=str(shim)+':'+os.environ['PATH']):unsaid=owners.nothing_holds(marked+'0')
                with failing_read(999) as fired:kept=owners.left([record])
                holder.kill();holder.wait()
                results.append(check(held is False and unsaid is False and fired and kept==[record] and owners.left([record])==[] and owners.nothing_holds(marked) is True,
                                     "a process is counted gone on a fact, and neither a failed read nor a failed pgrep is one"))
            # An older run left a record of pid 1 beside a process it did own.
            child=sleeper();spawned.append(child)
            stale=lease_of(dead_pid(),'gone','stale')
            (stale/'1.json').write_text(json.dumps(dict(pid=1,identity=owners.identity(1),role='judgment')))
            owners.register(stale,child.pid,'npm')
            receipts=owners.sweep()
            results.append(check(len(receipts)==1 and not stale.exists() and child.wait(timeout=10)==-signal.SIGKILL and 1 not in signalled,
                                 "a dead owner's lease with a record of pid 1 is cleared, its own process killed, pid 1 not signalled"))
            # A live owner's lease is not the sweep's, even when the kernel does not answer.
            mine=owners.create(os.getpid());witness=sleeper();spawned.append(witness);owners.register(mine,witness.pid,'witness')
            owners.sweep()
            with failing_read(999) as fired:swept()
            results.append(check(fired and mine.exists() and witness.poll() is None,"a live owner's lease stays, also through a kernel read that failed"))
            owners.cleanup(mine)
            # The record a later sweep reads is made here, so a failed read must not reach it.
            with markers(tmp,'made'):
                with failing_read(1) as at_create:mine=owners.create(os.getpid())
                witness=sleeper();spawned.append(witness)
                try:
                    with failing_read(1) as at_register:owners.register(mine,witness.pid,'witness')
                    registered=True
                except RuntimeError:
                    registered=False;owners.register(mine,witness.pid,'witness')
                recorded=json.loads((mine/'owner.json').read_text());receipts=swept()
                results.append(check(at_create and at_register and registered and bool(recorded['identity']) and receipts==[] and mine.exists() and witness.poll() is None,
                                     "one failed read while a lease is made: the record names its owner, and the lease and its child stay"))
                owners.cleanup(mine)
            with markers(tmp,'never'):
                with failing_read(999) as fired:
                    try:lease=owners.create(os.getpid())
                    except RuntimeError:lease=None
                results.append(check(fired and lease is None and not list(owners.MARKERS.iterdir()),"a run the kernel never names does not start, and makes no lease"))
            # A record that does not say who owns a lease is no word that the owner is gone.
            failed=forms_failing(tmp,'live',os.getpid,lambda lease,child:lease.exists() and child.poll() is None)
            results.append(check(not failed,"a live owner's lease stays whatever its record holds"+(': '+str(failed) if failed else '')))
            failed=forms_failing(tmp,'dead',dead_pid,lambda lease,child:killed(child) and not lease.exists())
            results.append(check(not failed,"the pid in a lease's name is enough: with it gone a broken record goes, and its process"+(': '+str(failed) if failed else '')))
            with markers(tmp,'said'):
                lease=owners.MARKERS/(str(os.getpid())+'-said');lease.mkdir();(lease/'owner.json').write_text('{"pid":')
                note=io.StringIO();swept(note=note)
                results.append(check(str(lease) in note.getvalue(),"a lease left because its owner is not known is named"))
            # ps prints the same process another way in another zone, and the number does not move.
            with markers(tmp,'zone'):
                mine=owners.create(os.getpid());witness=sleeper();spawned.append(witness);owners.register(mine,witness.pid,'witness')
                recorded=json.loads((mine/'owner.json').read_text())['identity'];moved=printed(os.getpid(),'UTC0')!=printed(os.getpid(),'SDT-13')
                with mock.patch.dict(os.environ,TZ='SDT-13'):
                    same=owners.identity(os.getpid())==recorded;zone=swept()
                with mock.patch.dict(os.environ,LC_ALL='ko_KR.UTF-8'):
                    same=same and owners.identity(os.getpid())==recorded;spoken=swept()
                results.append(check(moved and same and zone==[] and spoken==[] and mine.exists() and witness.poll() is None,
                                     "a sweep in another time zone or locale leaves a live owner's lease"))
                owners.cleanup(mine)
            # A process stays itself whatever it runs now and wherever it is read from.
            for i,(name,turn,env) in enumerate((('as it was',False,{}),('after an exec',True,{}),('from another zone',False,dict(TZ='SDT-13')),
                                                ('from another locale',False,dict(LC_ALL='ko_KR.UTF-8')),('after an exec, from another zone',True,dict(TZ='SDT-13')),
                                                ('after an exec, from another zone and locale',True,dict(TZ='SDT-13',LC_ALL='ko_KR.UTF-8')))):
                with markers(tmp,'cell'+str(i)):
                    child=turning();spawned.append(child);lease=lease_of(dead_pid(),'gone','cell');owners.register(lease,child.pid,'entry')
                    record=json.loads((lease/(str(child.pid)+'.json')).read_text())
                    if turn:child.stdin.write(b'\n');child.stdin.close()
                    turned=not turn or until(lambda:program(child.pid)=='sleep')
                    with mock.patch.dict(os.environ,env):reading=owners.running(record);swept()
                    results.append(check(turned and reading is True and killed(child) and not lease.exists(),"a dead owner's child "+name+" is the one registered, and a sweep ends it"))
            with markers(tmp,'turned owner'):
                holder=turning();spawned.append(holder);child=sleeper();spawned.append(child)
                lease=lease_of(holder.pid,owners.identity(holder.pid),'turned');owners.register(lease,child.pid,'npm')
                holder.stdin.write(b'\n');holder.stdin.close();turned=until(lambda:program(holder.pid)=='sleep')
                with mock.patch.dict(os.environ,TZ='SDT-13'):receipts=swept()
                results.append(check(turned and receipts==[] and lease.exists() and child.poll() is None,"an owner that exec'd, read from another zone, keeps its lease"))
                with mock.patch.dict(os.environ,TZ='SDT-13'):swept(holder.pid)
                results.append(check(killed(child) and not lease.exists(),"a suite that exec'd, read from another zone, still owns its lease"))
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
                with failing_read(1) as fired:swept(os.getpid())
                results.append(check(fired and lease.exists() and witness.poll() is None,"an empty suite identity claims no lease, also when the kernel gives none either"))
                owners.cleanup(lease)
            # What a sweep does know still ends a lease. The label is the same on purpose: only the start says.
            with markers(tmp,'other'):
                holder=sleeper();spawned.append(holder);child=sleeper();spawned.append(child);late=sleeper();spawned.append(late)
                lease=lease_of(holder.pid,earlier(holder.pid),'other');owners.register(lease,child.pid,'npm')
                record=dict(pid=late.pid,identity=earlier(late.pid),role='npm');(lease/(str(late.pid)+'.json')).write_text(json.dumps(record))
                reading=owners.running(record);swept()
                results.append(check(reading is False and not lease.exists() and killed(child) and holder.poll() is None and late.poll() is None and not {holder.pid,late.pid}&set(signalled),
                                     "another process of the same program under an owner's pid ends the lease, and one under a child's pid is not signalled"))
            with markers(tmp,'zombie'):
                zombie=subprocess.Popen(['true']);child=sleeper();spawned.append(child)
                dead=until(lambda:owners.stat(zombie.pid).startswith('Z'))
                lease=lease_of(zombie.pid,owners.identity(zombie.pid),'zombie');owners.register(lease,child.pid,'npm')
                swept();zombie.wait()
                results.append(check(dead and not lease.exists() and killed(child),"a zombie owner is gone"))
            with markers(tmp,'stopped'):
                child=sleeper();spawned.append(child);lease=lease_of(dead_pid(),'gone','stopped');owners.register(lease,child.pid,'npm')
                os.kill(child.pid,signal.SIGSTOP);stopped=until(lambda:owners.stat(child.pid)=='T')
                swept()
                results.append(check(stopped and killed(child) and not lease.exists(),"a stopped process is still the one registered, and a sweep ends it"))
            # exec keeps a process's pid and start, and the entry starts through env.
            with markers(tmp,'exec'):
                turned=turning();spawned.append(turned)
                mine=owners.create(os.getpid());owners.register(mine,turned.pid,'entry')
                turned.stdin.write(b'\n');turned.stdin.close()
                moved=until(lambda:program(turned.pid)=='sleep')
                owners.cleanup(mine)
                results.append(check(moved and killed(turned) and not mine.exists(),"a process that exec'd after its registration is still the one registered"))
            # Cleanup answers the same way: what it does not know it keeps, and says so.
            with markers(tmp,'silent'):
                mine=owners.create(os.getpid());witness=sleeper();spawned.append(witness);owners.register(mine,witness.pid,'witness')
                with failing_read(999) as fired:first=owners.cleanup(mine)
                stayed=fired and mine.exists() and witness.poll() is None and first.get('unknown')==[witness.pid]
                second=owners.cleanup(mine)
                results.append(check(stayed and killed(witness) and not mine.exists() and second.get('unknown')==[],
                                     "cleanup keeps a lease while the kernel gives no word of its process, and finishes once it answers"))
            # An orphan, so nothing is left of it once it dies: no zombie for the kernel to hold.
            with markers(tmp,'ending'):
                mine=owners.create(os.getpid())
                pid=int(subprocess.run(['/bin/sh','-c','sleep 60 >/dev/null 2>&1 & echo $!'],capture_output=True,text=True).stdout)
                owners.register(mine,pid,'npm')
                def ending():
                    real_kill(pid,signal.SIGKILL);until(lambda:owners.ended(pid))
                with failing_read(1,ending) as fired:receipt=owners.cleanup(mine)
                results.append(check(fired and receipt.get('unknown')==[] and not mine.exists(),"a process that ends while the kernel is read is gone, not unknown"))
            with markers(tmp,'torn'):
                child=sleeper();spawned.append(child);bare=sleeper();spawned.append(bare);printing=sleeper();spawned.append(printing)
                lease=lease_of(dead_pid(),'gone','torn');owners.register(lease,child.pid,'npm');(lease/'77.json').write_text('{"pid":')
                (lease/(str(bare.pid)+'.json')).write_text(json.dumps(dict(pid=bare.pid,identity='',role='npm')))
                (lease/(str(printing.pid)+'.json')).write_text(json.dumps(dict(pid=printing.pid,identity=PS_LINE,role='npm')))
                receipts=swept()
                named=not isinstance(receipts,str) and len(receipts)==1 and sorted(map(str,receipts[0].get('unknown',[])))==sorted([str(bare.pid),str(printing.pid),'77.json'])
                results.append(check(named and lease.exists() and killed(child) and bare.poll() is None and printing.poll() is None,
                                     "a dead owner's lease keeps the records that say nothing, an older run's line among them, names them, and cleans the rest"))
                with failing_read(999) as fired:silent=swept()
                results.append(check(fired and lease.exists() and bare.poll() is None and not isinstance(silent,str),
                                     "a record with no identity signals nothing, also when the kernel gives none to compare it with"))
                (lease/'77.json').unlink();bare.kill();bare.wait();printing.kill();printing.wait();swept()
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
            # A kill lands when the machine gets to it, and the reads cost no time of their own.
            with markers(tmp,'late kill'):
                mine=owners.create(os.getpid());witness=sleeper();spawned.append(witness);owners.register(mine,witness.pid,'witness')
                def landing(pid,sig):
                    if pid==witness.pid and sig==signal.SIGKILL:threading.Timer(2,spy,(pid,sig)).start()
                    else:spy(pid,sig)
                os.kill=landing
                try:receipt=owners.cleanup(mine)
                finally:os.kill=spy
                results.append(check(receipt.get('survivors')==[] and not mine.exists() and killed(witness),"a kill that lands seconds later is waited for, and names no survivor"))
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
