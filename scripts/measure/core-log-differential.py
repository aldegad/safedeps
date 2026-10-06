#!/usr/bin/env python3
"""Compare provider-init retention with its bash owner, including archive
contents and inode preservation. Each process gets a private state directory.
"""
import argparse
import gzip
import os
from pathlib import Path
import re
import subprocess
import tempfile

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--core',required=True)
p.add_argument('--control',action='store_true',help='copy reference with evidence filter inverted')
a=p.parse_args(); core=str(Path(a.core).resolve())
root=Path(__file__).resolve().parents[2]
program='''set -euo pipefail
umask 077
source "$1/lib/providers/providers.sh"
safedeps_advisory_log_rotate_once
if [[ -s "$2" ]]; then
  cat "$2" >> "$SAFEDEPS_ADVISORY_LOG"
  safedeps_advisory_log_rotate_once
fi
'''
rows=[('absent',None,{},'',None),('small',b'[t] INFO trace\n',{},'',None),
 ('mixed',b'[t] INFO trace\n[t] WARN keep\nplain check approve\n',{'SAFEDEPS_ADVISORY_LOG_MAX_BYTES':'1'},'',None),
 ('unterminated',b'[t] INFO gone\nlast evidence',{'SAFEDEPS_ADVISORY_LOG_MAX_BYTES':'1'},'',None),
 ('once',b'[t] WARN keep\n',{'SAFEDEPS_ADVISORY_LOG_MAX_BYTES':'1'},'[t] INFO append\n',None),
 ('live-lock',b'[t] INFO trace\n',{'SAFEDEPS_ADVISORY_LOG_MAX_BYTES':'1'},'','live'),
 ('stale-lock',b'[t] INFO trace\n[t] ERROR keep\n',{'SAFEDEPS_ADVISORY_LOG_MAX_BYTES':'1'},'','stale'),
 ('prune-count',b'approval\n',{'SAFEDEPS_ADVISORY_LOG_MAX_BYTES':'1','SAFEDEPS_ADVISORY_LOG_KEEP':'2'},'',None),
 ('prune-bytes',b'approval\n',{'SAFEDEPS_ADVISORY_LOG_MAX_BYTES':'1','SAFEDEPS_ADVISORY_LOG_ARCHIVE_TOTAL_BYTES':'1'},'',None)]
def normalize(value,directory):
    value=value.replace(str(directory).encode(),b'@STATE@')
    value=re.sub(rb'\[\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\]',b'[@TIME@]',value)
    return re.sub(rb'advisory\.log\.\d{8}T\d{6}Z\.gz',b'advisory.log.@TIME@.gz',value)
print('start:',subprocess.check_output(['uptime'],text=True).strip(),flush=True)
bad=0
with tempfile.TemporaryDirectory(prefix='safedeps-log-diff-') as tmp:
    tmp=Path(tmp); reference=root
    if a.control:
        import shutil
        reference=tmp/'reference'; shutil.copytree(root/'lib',reference/'lib')
        file=reference/'lib/advisory-log-rotate.sh'
        file.write_text(file.read_text().replace('grep -Ev "${SAFEDEPS_ADVISORY_LOG_TRACE_RE}"','grep -E "${SAFEDEPS_ADVISORY_LOG_TRACE_RE}"'))
    for label,initial,knobs,extra,lock in rows:
        answers=[]
        for side in ['bash','core']:
            directory=tmp/(label+'-'+side); directory.mkdir(); file=directory/'advisory.log'
            if initial is not None: file.write_bytes(initial)
            old=file.stat().st_ino if file.exists() else None
            for i in range(3):
                (directory/f'advisory.log.2000010{i+1}T000000Z.gz').write_bytes(gzip.compress(f'old{i}\n'.encode()))
            if lock:
                d=directory/'advisory.log.rotate.lock'; d.mkdir()
                if lock=='stale': os.utime(d,(1,1))
            env=dict(os.environ,SAFEDEPS_HOME=str(directory),**knobs)
            if side=='bash':
                inp=directory/'append'; inp.write_text(extra)
                proc=subprocess.run(['/bin/bash','-s','--',str(reference),str(inp)],input=program.encode(),env=env,capture_output=True)
                inp.unlink()
            else: proc=subprocess.run([core,'state-rotate'],input=extra.encode(),env=env,capture_output=True)
            contents={}
            for path in sorted(directory.iterdir()):
                name=normalize(path.name.encode(),directory)
                contents[name]=('directory' if path.is_dir() else normalize(gzip.decompress(path.read_bytes()) if path.suffix=='.gz' else path.read_bytes(),directory))
            same_inode=not file.exists() if old is None else file.stat().st_ino==old
            answers.append((proc.returncode,normalize(proc.stdout,directory),normalize(proc.stderr,directory),contents,same_inode))
        ok=answers[0]==answers[1]; bad+=not ok
        print(('ok ' if ok else 'DIFF ')+label,flush=True)
        if not ok: print(repr(answers),flush=True)
print('end:',subprocess.check_output(['uptime'],text=True).strip())
print(f'core-log-differential: {len(rows)} cases, {bad} differ')
raise SystemExit(not bad if a.control else bool(bad))
