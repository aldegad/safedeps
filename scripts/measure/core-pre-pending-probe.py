#!/usr/bin/env python3
"""Pending component comparison with independent call/trace checks.

Uses the original Bash write operations, no install command evaluation.
Generated ids, log times and inode values are checked against the invocation
and disk before normalization. Seed records and dates are never normalized.
"""
import argparse
from datetime import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tempfile
import time

spec=importlib.util.spec_from_file_location('snapshot_probe',Path(__file__).with_name('core-pre-snapshot-probe.py'))
snapshot=importlib.util.module_from_spec(spec);spec.loader.exec_module(snapshot)


def observe(box,sid,digest,start,end,row):
    files=snapshot.harvest(box,sid,digest,start,end)
    pending=box/'state/pending'
    owned=[]
    for p in pending.glob('*.json'):
        try:v=json.loads(p.read_bytes())
        except ValueError:continue
        if v.get('snapshot_id')==sid:owned.append((p,v))
    assert len(owned)==1, ('own record count',len(owned))
    path,v=owned[0]
    raw_id=row.get('tool_use_id')
    call=raw_id.replace('\0','').rstrip('\n') if isinstance(raw_id,str) else ''
    if not re.fullmatch('[A-Za-z0-9_-]{1,128}',call):call=''
    assert v['tool_use_id']==(call or None),'call binding'
    if call:assert path.name=='id-'+call+'.json','call filename'
    else:
        norm=re.sub(r'\s+',' ',row['command']).strip()
        key=row['pending']['cwd_hash']+'_'+hashlib.md5(norm.encode()).hexdigest()
        assert path.name==key+'__'+sid+'.json','legacy filename'
    assert v['project_dir']==str(box/'project'),'project directory'
    assert v['dir_hash']==digest,'project hash'
    trace_path=path.with_suffix('.trace')
    raw=path.read_bytes()
    if row['pending']['trace']:
        trace=v['npm_trace']
        assert trace['baseline']==str(trace_path),'baseline belongs to this call'
        assert start<=trace_path.stat().st_mtime<=end,'baseline invocation interval'
        for rel in ('package-lock.json','node_modules/.package-lock.json'):
            p=box/'project'/rel
            expected=str(p.lstat().st_ino) if p.exists() else ''
            assert trace['inodes'][rel]==expected,('inode',rel,trace['inodes'][rel],expected)
            raw=re.sub(rb'('+re.escape(json.dumps(rel).encode())+rb'\s*:\s*)'+re.escape(json.dumps(expected).encode()),rb'\g<1>"@INODE@"',raw,count=1)
        assert trace_path.read_bytes()==b'','baseline bytes'
    else:assert v['npm_trace'] is None and not trace_path.exists(),'non-npm trace'
    raw=raw.replace(sid.encode(),b'@SNAPSHOT@')
    key=str(path.relative_to(box)).replace(sid,'@SNAPSHOT@')
    files.pop(str(path.relative_to(box)))
    files[key]=('file',stat.S_IMODE(path.stat().st_mode),raw.hex())
    if trace_path.exists():
        old=str(trace_path.relative_to(box));files[old.replace(sid,'@SNAPSHOT@')]=files.pop(old)
    log=box/'state/advisory.log'
    if log.exists():
        data=log.read_bytes();lines=[]
        for line in data.splitlines(keepends=True):
            stamp,tab,message=line.partition(b'\t')
            when=datetime.strptime(stamp.decode(),'%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=__import__('datetime').timezone.utc).timestamp()
            assert int(start)<=when<=int(end),'advisory invocation interval'
            lines.append(b'@TIME@'+tab+message)
        files['state/advisory.log']=('file',stat.S_IMODE(log.stat().st_mode),b''.join(lines).hex())
    assert (pending/'other.json').read_bytes()==b'{"snapshot_id":"seed","tool_use_id":"other","timestamp":4102444800}', 'other call modified'
    assert (pending/'old.keep').exists() and (pending/'old.link.json').is_symlink(),'sweep scope'
    assert not (pending/'old.json').exists() and not (pending/'old.trace').exists() and not (pending/'.json').exists(),'old regular records not swept'
    return files


def main():
    ap=argparse.ArgumentParser();ap.add_argument('--core',required=True);ap.add_argument('--only');ap.add_argument('--expect-difference',action='store_true');a=ap.parse_args()
    names=['id','no-id','invalid-id','newline-id','non-npm','no-fetch','linked-lock','dangling-lock','rewrite']
    if a.only:names=[n for n in names if n in a.only.split(',')]
    assert names
    bad=0
    with tempfile.TemporaryDirectory(prefix='core-pre-pending.') as temp:
        outer=Path(temp).resolve();box=outer/'box';ref=outer/'reference.sh'
        ref.write_text(snapshot.reference(Path(__file__).resolve().parents[2]))
        for name in names:
            digest=hashlib.md5(str(box/'project').encode()).hexdigest()
            cwd=str(box/'elsewhere');cwd_hash=hashlib.md5(cwd.encode()).hexdigest()
            row=dict(project=str(box/'project'),hash=digest,command='npm ci',tool_use_id='call-1',pending=dict(cwd=cwd,cwd_hash=cwd_hash,project_from='target',trace=True,attribution='synthetic attribution',fetch={'registry':'https://registry.npmjs.org/'},fetch_why='synthetic reason'))
            if name=='no-id':row.pop('tool_use_id')
            if name=='invalid-id':row['tool_use_id']='../other'
            if name=='newline-id':row['tool_use_id']='call-1\n'
            if name=='non-npm':row['pending']['trace']=False
            if name=='no-fetch':row['pending']['fetch']=None
            if name=='rewrite':row.update(rewrite='npm ci --ignore-scripts',unread=True)
            results=[]
            for side in ('bash','core'):
                if box.exists():shutil.rmtree(box)
                snapshot.seed(box,'hidden',digest)
                pending=box/'state/pending';pending.mkdir(mode=0o700)
                for rel in ('old.json','old.trace','.json','old.keep'):
                    p=pending/rel;p.write_bytes(b'old bytes');os.utime(p,(time.time()-172800,)*2)
                (pending/'old.link.json').symlink_to('old.keep')
                (pending/'other.json').write_bytes(b'{"snapshot_id":"seed","tool_use_id":"other","timestamp":4102444800}')
                if name in ('linked-lock','dangling-lock'):
                    lock=box/'project/package-lock.json';lock.rename(box/'project/lock-target')
                    lock.symlink_to('lock-target' if name=='linked-lock' else 'not-there')
                env=dict(os.environ,SAFEDEPS_HOME=str(box/'state'),LC_ALL='C',LANG='C')
                cmd=['/bin/bash',str(ref),str(Path(__file__).resolve().parents[2])] if side=='bash' else [str(Path(a.core).resolve()),'pre-probe']
                start=time.time();p=subprocess.run(cmd,input=json.dumps(row).encode(),cwd=box/'project',env=env,capture_output=True,timeout=15);end=time.time()
                error=''
                try:files=observe(box,p.stdout.decode().strip(),digest,start,end,row)
                except (AssertionError,ValueError,KeyError,OSError) as e:files={};error=str(e)
                results.append((p.returncode,p.stderr.decode(errors='replace'),error,files))
            left,right=results
            paths=[k for k in left[3].keys()|right[3].keys() if left[3].get(k)!=right[3].get(k)]
            same=left[:3]==right[:3] and left[0]==0 and not left[2] and not paths
            bad+=not same
            print(json.dumps(dict(case=name,same=same,reference=left[:3],candidate=right[:3],paths=paths)),flush=True)
            for path in paths[:5]:print(json.dumps(dict(path=path,reference=left[3].get(path),candidate=right[3].get(path))),flush=True)
    print(f'core-pre-pending: {len(names)} cases, {bad} differ',flush=True)
    return int(not bad if a.expect_difference else bool(bad))

if __name__=='__main__':raise SystemExit(main())
