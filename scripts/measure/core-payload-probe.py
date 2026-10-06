#!/usr/bin/env python3
"""Assert payload source-map and origin contracts. Shell probes use printf
in place of a package manager; the dependency forms are lexer input only.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--core',required=True)
p.add_argument('--loss',help='saemi loss-IC.jsonl, read only as lexer input')
a=p.parse_args(); core=str(Path(a.core).resolve())
rows=[
 ('eval-short','eval npm ci x','npm ci x','eval',None),
 ('env-short',"env -S'npm ci' x",'npm ci x','env-split',None),
 ('shell',"bash -c 'npm ci'",'npm ci','shell-c','bash'),
 ('unsupported-shell',"/bin/ksh -c 'npm ci'",'npm ci','shell-c','/bin/ksh'),
 ('ansi-c',"eval $'n\\x70m ci'",'npm ci','eval',None),
 ('arithmetic-dollar','echo $(( $(npm ci) ))','npm ci','command-substitution',None),
 ('arithmetic-command','(( $(npm ci) ))','npm ci','command-substitution',None),
 ('arithmetic-backtick','echo $(( `npm ci` ))','npm ci','backquote',None),
 ('process','cat <(npm ci)','npm ci','process-substitution',None),
 ('heredoc','cat <<EOF\n$(npm ci)\nEOF\n','npm ci','command-substitution',None),
]
print('start:',subprocess.check_output(['uptime'],text=True).strip(),flush=True)
bad=0; count=0
for reading in ['bash','zsh','dash']:
    for label,command,text,origin,shell in rows:
        if reading=='dash' and label in ['arithmetic-command','process']: continue
        raw=command.encode(); env=dict(os.environ,SAFEDEPS_READING=reading)
        proc=subprocess.run([core,'payloads'],input=raw,env=env,capture_output=True)
        data=json.loads(proc.stdout)
        candidates=[p for p in data['payloads'] if p['text']==text and p['origin']==origin and p['shell']==shell]
        ok=bool(candidates) and not data['failed']
        for payload in data['payloads']:
            value=payload['text'].encode()
            ok=ok and len(value)==len(payload['src'])
            for i,src in enumerate(payload['src']):
                if src is not None: ok=ok and 0<=src<len(raw) and value[i]==raw[src]
        if label=='eval-short' and candidates:
            ok=ok and candidates[0]['src']==[5,6,7,None,9,10,None,12]
        count+=1; bad+=not ok
        print(('ok ' if ok else 'DIFF ')+reading+'/'+label,flush=True)
        if not ok: print(data)
    shell_path=subprocess.run(['which',reading],capture_output=True,text=True).stdout.strip()
    if not shell_path: raise SystemExit('required shell missing: '+reading)
    # The shells decide whether printf runs inside arithmetic. No npm is run.
    for command in ['echo $(( $(printf 2) + 1 ))','echo $(( `printf 2` + 1 ))']:
        actual=subprocess.run([shell_path,'-c',command],capture_output=True)
        count+=1; ok=actual.returncode==0 and actual.stdout==b'3\n'; bad+=not ok
        print(('ok ' if ok else 'DIFF ')+reading+'/arithmetic-shell',flush=True)
if a.loss:
    for line in Path(a.loss).read_text().splitlines():
        row=json.loads(line)
        for reading in ['bash','zsh','dash']:
            proc=subprocess.run([core,'payloads'],input=row['text'].encode(),env=dict(os.environ,SAFEDEPS_READING=reading),capture_output=True)
            data=json.loads(proc.stdout)
            print('loss-input',row['id'],reading,json.dumps(data,ensure_ascii=False),flush=True)
print('end:',subprocess.check_output(['uptime'],text=True).strip())
print(f'core-payload-probe: {count} checks, {bad} differ')
raise SystemExit(bool(bad))
