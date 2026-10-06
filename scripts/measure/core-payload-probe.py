#!/usr/bin/env python3
"""Assert payload source-map and origin contracts. Shell probes use printf
in place of a package manager; the dependency forms are lexer input only.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
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
        if reading=='dash' and label=='ansi-c': text='$n\\x70m ci'
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
    nested='echo $(printf %s "$(npm ci)")'
    data=json.loads(subprocess.run([core,'payloads'],input=nested.encode(),env=env,capture_output=True).stdout)
    first=data['payloads']
    ok=len(first)==1 and first[0]['text']=='printf %s "$(npm ci)"'
    if ok:
        inner=json.loads(subprocess.run([core,'payloads'],input=first[0]['text'].encode(),env=env,capture_output=True).stdout)['payloads']
        ok=len(inner)==1 and inner[0]['text']=='npm ci'
        if ok:
            composed=[first[0]['src'][pos] if pos is not None else None for pos in inner[0]['src']]
            ok=composed==list(range(nested.index('npm'),nested.index('npm')+6))
    count+=1; bad+=not ok
    print(('ok ' if ok else 'DIFF ')+reading+'/one-level',flush=True)
    data=json.loads(subprocess.run([core,'payloads'],input=b"env -S'npm $V'",env=env,capture_output=True).stdout)
    count+=1; ok=data['failed']; bad+=not ok
    print(('ok ' if ok else 'DIFF ')+reading+'/unread-env-split',flush=True)
    # The shell calls a private executable named npm. Its argv is the witness;
    # it only writes that argv and a number, and never invokes a package manager.
    with tempfile.TemporaryDirectory(prefix='safedeps-payload-') as tmp:
        stub=Path(tmp,'npm'); trace=Path(tmp,'argv')
        stub.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$PAYLOAD_ARGV"\nprintf 2\n'); stub.chmod(0o700)
        shell_env=dict(os.environ,PATH=tmp+os.pathsep+os.environ['PATH'],PAYLOAD_ARGV=str(trace))
        for command in ['echo $(( $(npm ci) + 1 ))','echo $(( `npm ci` + 1 ))']:
            if trace.exists(): trace.unlink()
            actual=subprocess.run([shell_path],input=command.encode(),env=shell_env,capture_output=True)
            count+=1; ok=actual.returncode==0 and actual.stdout==b'3\n' and trace.exists() and trace.read_bytes()==b'ci\n'; bad+=not ok
            print(('ok ' if ok else 'DIFF ')+reading+'/arithmetic-shell-argv',flush=True)
        # The exact shell-reading corpus row whose old lexer gave a quote
        # inside arithmetic the outer reading's treatment. The private pip
        # records whether that reading exposes the following install.
        pip=Path(tmp,'pip'); pip.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$PAYLOAD_ARGV"\n'); pip.chmod(0o700)
        quoted='(( x = $(echo ")" | wc -c) <<2 ))\npip install evil==6.6.6\n2\n'
        if trace.exists(): trace.unlink()
        actual=subprocess.run([shell_path],input=quoted.encode(),env=shell_env,capture_output=True)
        got=trace.read_bytes() if trace.exists() else None
        expected=None if reading=='dash' else b'install\nevil==6.6.6\n'
        count+=1; ok=got==expected; bad+=not ok
        print(('ok ' if ok else 'DIFF ')+reading+'/quoted-arithmetic-shell-argv',flush=True)
    actual=subprocess.run([shell_path],input=b"printf '%s\\n' $'n\\x70m ci'",capture_output=True)
    expected=b'$n\\x70m ci\n' if reading=='dash' else b'npm ci\n'
    count+=1; ok=actual.returncode==0 and actual.stdout==expected; bad+=not ok
    print(('ok ' if ok else 'DIFF ')+reading+'/ansi-c-shell',flush=True)
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
