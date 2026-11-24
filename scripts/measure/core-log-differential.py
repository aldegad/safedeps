#!/usr/bin/env python3
"""Check native provider-init rotation against fixed log fixtures: the archive
is the live file renamed (its bytes and its inode), the new live file starts
with the rotation's line, the lock is a regular file, and retention removes
what its bounds name. Each process gets a private state directory.
"""
import argparse
import fcntl
import gzip
import os
from pathlib import Path
import re
import subprocess
import tempfile

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--core',required=True)
a=p.parse_args(); core=str(Path(a.core).resolve())
root=Path(__file__).resolve().parents[2]
rows=[('absent',None,{},'',None),('small',b'[t] INFO trace\n',{},'',None),
 ('mixed',b'[t] INFO trace\n[t] WARN keep\nplain check approve\n',{'SAFEDEPS_ADVISORY_LOG_MAX_BYTES':'1'},'',None),
 ('unterminated',b'[t] INFO gone\nlast evidence',{'SAFEDEPS_ADVISORY_LOG_MAX_BYTES':'1'},'',None),
 ('once',b'[t] WARN keep\n',{'SAFEDEPS_ADVISORY_LOG_MAX_BYTES':'1'},'[t] INFO append\n',None),
 ('live-lock',b'[t] INFO trace\n',{'SAFEDEPS_ADVISORY_LOG_MAX_BYTES':'1'},'','live'),
 ('stale-lock',b'[t] INFO trace\n[t] ERROR keep\n',{'SAFEDEPS_ADVISORY_LOG_MAX_BYTES':'1'},'','stale'),
 ('held-lock',b'[t] INFO trace\n',{'SAFEDEPS_ADVISORY_LOG_MAX_BYTES':'1'},'','held'),
 ('prune-count',b'approval\n',{'SAFEDEPS_ADVISORY_LOG_MAX_BYTES':'1','SAFEDEPS_ADVISORY_LOG_KEEP':'2'},'',None),
 ('prune-bytes',b'approval\n',{'SAFEDEPS_ADVISORY_LOG_MAX_BYTES':'1','SAFEDEPS_ADVISORY_LOG_ARCHIVE_TOTAL_BYTES':'1'},'',None)]
ARCHIVE=re.compile(r'^advisory\.log\.\d{8}T\d{6}Z(?:\.[1-9]\d*)?(?:\.gz)?$')
def normalize(value,directory):
    value=value.replace(str(directory).encode(),b'@STATE@')
    value=re.sub(rb'\[\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\]',b'[@TIME@]',value)
    return re.sub(rb'advisory\.log\.\d{8}T\d{6}Z',b'advisory.log.@TIME@',value)
print('start:',subprocess.check_output(['uptime'],text=True).strip(),flush=True)
bad=0
with tempfile.TemporaryDirectory(prefix='safedeps-log-diff-') as tmp:
    tmp=Path(tmp)
    for label,initial,knobs,extra,lock in rows:
        directory=tmp/label; directory.mkdir(); file=directory/'advisory.log'
        if initial is not None: file.write_bytes(initial)
        old=file.stat().st_ino if file.exists() else None
        for i in range(3):
            (directory/f'advisory.log.2000010{i+1}T000000Z.gz').write_bytes(gzip.compress(f'old{i}\n'.encode()))
        lock_path=directory/'advisory.log.rotate.lock'; held=None
        if lock in ('live','stale'):
            lock_path.mkdir()
            if lock=='stale': os.utime(lock_path,(1,1))
        if lock=='held':
            held=open(lock_path,'a'); fcntl.flock(held,fcntl.LOCK_EX)
        env=dict(os.environ,SAFEDEPS_HOME=str(directory),**knobs)
        proc=subprocess.run([core,'state-rotate'],input=extra.encode(),env=env,capture_output=True)
        if held: held.close()
        contents={}
        for path in sorted(directory.iterdir()):
            name=normalize(path.name.encode(),directory)
            contents[name]=('directory' if path.is_dir() else normalize(gzip.decompress(path.read_bytes()) if path.suffix=='.gz' else path.read_bytes(),directory))
        answer=(proc.returncode,normalize(proc.stdout,directory),normalize(proc.stderr,directory),contents)
        actual=file.read_bytes() if file.exists() else None
        rotate=label not in ('absent','small','live-lock','held-lock')
        archives=sorted(x for x in directory.iterdir() if ARCHIVE.match(x.name))
        fresh=[x for x in archives if not x.name.startswith('advisory.log.200001')]
        ok=proc.returncode==0 and not proc.stdout and not proc.stderr
        if rotate:
            # The archive is the live file renamed, plain; the new live file
            # holds the rotation's line, then what was appended after it.
            ok=ok and len(fresh)==1 and not fresh[0].name.endswith('.gz')
            ok=ok and fresh[0].read_bytes()==initial and fresh[0].stat().st_ino==old
            lines=actual.splitlines(keepends=True)
            ok=ok and len(lines)==1+extra.count('\n') and b'] WARN advisory log rotated: ' in lines[0]
            ok=ok and actual.endswith(extra.encode()) if extra else ok
            ok=ok and lock_path.is_file()
            if label=='prune-count':ok=ok and len(archives)==2
            if label=='prune-bytes':ok=ok and len(archives)==1
        else:
            ok=ok and actual==initial and not fresh
            ok=ok and (old is None or file.stat().st_ino==old)
            if lock=='live':ok=ok and lock_path.is_dir()
        bad+=not ok
        print(('ok - ' if ok else 'not ok - ')+label,flush=True)
        if not ok:print(repr(answer),flush=True)
print('end:',subprocess.check_output(['uptime'],text=True).strip())
raise SystemExit(bool(bad))
