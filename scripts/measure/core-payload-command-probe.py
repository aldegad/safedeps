#!/usr/bin/env python3
"""Semantic payloads start at calls; legacy text-search views stay compatible.

The baseline is the removal control: a binary of the tree just before the
newest rule the cases hold, which must fail exactly the cases that rule is
for. It is one tree, named below by the source digest its binary prints
(`safedeps-core stamp`). A baseline built from any other source is refused
before anything is compared: beside a binary that already has the rule the
control detects nothing, and beside an older one it detects other things, and
neither is evidence for the rule. Original bash executions use a private npm
that records all arguments as hex JSON and performs no installation.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent

# The control's tree and what its binary fails. The rule it lacks: a text that
# does not close fails the structural payload reading only where the textual
# search finds a script in it. When a later rule moves the control, all three
# move together.
BASELINE = dict(
    commit='47ef6c4ce72e1a265c576e19f0cdb01edba784af',
    source_sha256='4db4df0f63997757975d95abea10f2ef96d1063986d5af8f68076b03007575a0',
    detects=['open-quote-no-script/bash'],
)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--core', required=True)
    ap.add_argument('--baseline', required=True)
    ap.add_argument('--out', required=True)
    args = ap.parse_args()
    stamp = subprocess.run([args.baseline, 'stamp'], capture_output=True, timeout=15).stdout.decode('utf-8', 'replace').split()
    if len(stamp) != 2 or stamp[1] != BASELINE['source_sha256']:
        print(f"the baseline is not the control's tree: its stamp says {' '.join(stamp) or 'nothing'}, and the control is the binary of {BASELINE['commit']} (source {BASELINE['source_sha256']}). Nothing was compared.", flush=True)
        return 2
    out = Path(args.out); out.mkdir(parents=True)
    fixture = HERE/'core-payload-command-cases.jsonl'
    cases = [json.loads(s) for s in fixture.read_text().splitlines()]
    rows = []; controls = []
    def query(core, text, reading, mode):
        p = subprocess.run([core]+mode, input=text.encode(), env=dict(os.environ, SAFEDEPS_READING=reading), capture_output=True, timeout=15)
        return dict(rc=p.returncode, stdout_hex=p.stdout.hex(), stderr_hex=p.stderr.hex())
    def check(case, axis, ok, **raw):
        rows.append(dict(id=case['id'],axis=axis,ok=ok,**raw))
    def shape(result):
        return [{k:p[k] for k in ('kind','text','origin','shell')} for p in result['payloads']]
    def maps(result, text):
        source = text.encode()
        return all(len(p['src']) == len(p['text'].encode()) and all(s is None or 0 <= s < len(source) and source[s] == p['text'].encode()[i] for i,s in enumerate(p['src'])) for p in result['payloads'])
    stub=out/'stub'; stub.mkdir()
    (stub/'npm').write_text('#!'+sys.executable+' -I\n'+'''import json,os,sys
fd=os.open(os.environ['NPMLOG'],os.O_WRONLY|os.O_APPEND|os.O_CREAT,0o600)
data=(json.dumps([os.fsencode(a).hex() for a in sys.argv[1:]])+'\\n').encode()
assert os.write(fd,data)==len(data)
os.close(fd)
''')
    (stub/'npm').chmod(0o700)
    for case in cases:
        command=case['command']
        for reading in case.get('readings',['bash','zsh','dash']):
            data={};raw={}
            for label,core in [('before',args.baseline),('after',args.core)]:
                raw[label]=query(core,command,reading,['payloads'])
                data[label]=json.loads(bytes.fromhex(raw[label]['stdout_hex']))
            expected_failed=case.get('failed',False)
            ok=shape(data['after'])==case['expected'] and data['after']['failed']==expected_failed and maps(data['after'],command)
            if not expected_failed:ok=ok and raw['after']['rc']==0
            check(case,reading+'/payload',ok,raw=raw,parsed=data)
            if case['expected'] and shape(data['before']) == case['expected']:
                check(case,reading+'/source-map-preserved',data['before']['payloads']==data['after']['payloads'])
            if shape(data['before'])!=case['expected'] or data['before']['failed']!=expected_failed:controls.append(case['id']+'/'+reading)
            for index,expected in enumerate(case.get('child_expected',[])):
                text=data['after']['payloads'][index]['text']
                got=query(args.core,text,reading,['payloads']);parsed=json.loads(bytes.fromhex(got['stdout_hex']))
                check(case,reading+'/child',got['rc']==0 and not parsed['failed'] and shape(parsed)==expected and maps(parsed,text),raw=got,parsed=parsed)
            for view in ('cscripts','substs','pieces','cmdword'):
                before=query(args.baseline,command,reading,['lex',view])
                after=query(args.core,command,reading,['lex',view])
                check(case,reading+'/legacy-'+view,before==after,before=before,after=after)
        if 'shell' in case:
            work=out/case['id'];work.mkdir()
            log=out/(case['id']+'.calls.jsonl');log.write_bytes(b'')
            env=dict(HOME=str(work),PATH=str(stub)+':/usr/bin:/bin',NPMLOG=str(log),LC_ALL='C')
            p=subprocess.run(['/bin/bash','-c',command],cwd=work,env=env,input=b'',capture_output=True,timeout=15)
            calls=[json.loads(s) for s in log.read_text().splitlines()]
            expected=case['shell']
            ok=p.returncode==expected['rc'] and calls==[[s.encode().hex() for s in call] for call in expected['argv']]
            if 'stdout' in expected:ok=ok and p.stdout==expected['stdout'].encode()
            check(case,'original-bash',ok,rc=p.returncode,calls_hex=calls,stdout_hex=p.stdout.hex(),stderr_hex=p.stderr.hex(),files={str(f.relative_to(work)):f.read_bytes().hex() for f in work.rglob('*') if f.is_file()})
    rows.append(dict(id='removal-control',axis='old-payloads-detected',ok=sorted(controls)==sorted(BASELINE['detects']),detected=controls,expected=BASELINE['detects']))
    failed=[r for r in rows if not r['ok']]
    result=dict(rows=rows,failures=failed,fixture_sha256=hashlib.sha256(fixture.read_bytes()).hexdigest(),binaries={name:dict(path=core,sha256=hashlib.sha256(Path(core).read_bytes()).hexdigest()) for name,core in [('before',args.baseline),('after',args.core)]})
    (out/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    print(f'{len(cases)} inputs, {len(rows)} checks, {len(failed)} failed; {len(controls)} prior payload failures',flush=True)
    for failure in failed:print(json.dumps(failure),flush=True)
    return int(bool(failed))


if __name__=='__main__':raise SystemExit(main())
