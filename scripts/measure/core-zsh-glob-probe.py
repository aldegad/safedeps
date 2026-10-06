#!/usr/bin/env python3
"""A zsh pattern's complete source span must be one word of one statement.

Inputs remain JSONL data. The old core is the removal control. Bash/dash
views are compared byte for byte to it; the corrected zsh boundary is held
to original offsets and the existing shell-argv witness, not old awk output.
"""
import argparse
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess

HERE=Path(__file__).resolve().parent

def words(core,command,reading):
    p=subprocess.run([core,'words'],input=command.encode(),env=dict(os.environ,SAFEDEPS_READING=reading),capture_output=True)
    f=io.BytesIO(p.stdout);pieces=[]
    unterm=f.readline();unreadable=f.readline()
    while True:
        line=f.readline()
        if not line.startswith(b'P '):break
        _,number,start,end,count=line.split()
        item=dict(start=int(start),end=int(end),words=[])
        for _ in range(int(count)):
            tag,a,z,size=f.readline().split();assert tag==b'W'
            value=f.read(int(size));assert f.read(1)==b'\n'
            item['words'].append(dict(start=int(a),end=int(z),value=value.decode()))
        pieces.append(item)
    return dict(rc=p.returncode,unterm=unterm.decode().strip(),unreadable=unreadable.decode().strip(),pieces=pieces,stderr=p.stderr.decode()),p.stdout

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--core',required=True);ap.add_argument('--baseline',required=True);ap.add_argument('--inputs',required=True);ap.add_argument('--witness',required=True);ap.add_argument('--report',required=True);a=ap.parse_args()
    spec=importlib.util.spec_from_file_location('lex_diff',HERE/'core-lex-differential.py');lex=importlib.util.module_from_spec(spec);spec.loader.exec_module(lex)
    inputs=[json.loads(s) for s in Path(a.inputs).read_text().splitlines() if s];rows=[]
    witnesses=[json.loads(s) for s in Path(a.witness).read_text().splitlines() if s]
    assert len(witnesses)==3 and all(w['cmd']==inputs[0]['command'] for w in witnesses)
    for w in witnesses:
        for shell in ('zsh','zsh-agent'):
            original=w['runs']['written']['shells'][shell]
            assert original['rc']==0 and len(original['calls'])==1
            assert original['calls'][0]['argv'][2:]==sorted(w['files'])
    old_failed=0
    for row in inputs:
        raw=row['command'].encode();glob=row['glob'].encode();start=raw.index(glob);end=start+len(glob)
        pair={}
        for side,core in [('baseline',a.baseline),('candidate',a.core)]:
            data,_=words(core,row['command'],'zsh')
            matches=[(p,w) for p in data['pieces'] for w in p['words'] if w['start']==start and w['end']==end]
            ok=data['rc']==0 and data['unterm']=='unterm 0' and len(matches)==1 and matches[0][0]['end']>=end
            pair[side]=dict(contract=ok,data=data)
        if not pair['baseline']['contract']:old_failed+=1
        rows.append(dict(stage='word',id=row['id'],same=pair['candidate']['contract'],**pair))
        for reading in ('bash','dash'):
            query=[(raw,v,reading) for v in lex.VIEWS]
            before=lex.run_core_batch(a.baseline,query);after=lex.run_core_batch(a.core,query)
            for view,old,new in zip(lex.VIEWS,before,after):
                rows.append(dict(stage='unchanged-reading',id=row['id'],reading=reading,view=view,same=old==new))
    rows.append(dict(stage='baseline-detection',same=old_failed>0,failed_contracts=old_failed))
    bad=[r for r in rows if not r['same']]
    Path(a.report).write_text(json.dumps(rows,indent=2))
    print(f'core-zsh-glob: {len(rows)} checks, {len(bad)} failed; baseline lacks {old_failed} word spans')
    for row in bad:print(json.dumps(row))
    return int(bool(bad))

if __name__=='__main__':raise SystemExit(main())
