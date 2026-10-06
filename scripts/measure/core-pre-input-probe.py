#!/usr/bin/env python3
"""Exercise the public pre hook's JSON stream caller, not another parser.

Inputs are JSONL data and are never shell code. Both hooks use the same
restored absolute fixture. Field/status errors and early exits compare all
bytes literally. Installs reuse the snapshot/call-record oracle; its bounded
time checks are component evidence, not the independent clock-role proof.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import time

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('install_probe', HERE / 'core-pre-install-probe.py')
install = importlib.util.module_from_spec(spec)
spec.loader.exec_module(install)


def cases(project):
    base = dict(tool_name='Bash', tool_input={'command': 'npm ci'}, cwd=str(project),
                tool_use_id='call-1', turn_id='synthetic-turn')
    def mod(**fields):
        return dict(base, **fields)
    rows = []
    def add(name, values, *, snapshot=True, rc=0, no_id=False, tail=b''):
        raw = b'\n'.join(json.dumps(v, ensure_ascii=True).encode() for v in values) + tail
        rows.append(dict(id=name, raw=raw, snapshot=snapshot, rc=rc, no_id=no_id))
    add('one', [base])
    add('null-first', [None, base])
    add('array-error-first', [[], base])
    add('string-error-first', ['not an object', base])
    add('array-error-last', [base, []], snapshot=False, rc=5)
    add('split-fields', [{'tool_name': 'Bash'}, {k:v for k,v in base.items() if k!='tool_name'}])
    add('two-tools', [base, base], snapshot=False)
    add('two-ids', [{'tool_use_id':'first'}, base], no_id=True)
    add('id-before-null', [dict(tool_use_id='call-1'), mod(tool_use_id=None)])
    add('id-trailing-newlines', [{'tool_use_id':'call-1\n\n'}, mod(tool_use_id=None)])
    add('id-interior-newline', [{'tool_use_id':'\n'}, base], no_id=True)
    add('nul-id', [mod(tool_use_id='ca\u0000ll-1')])
    add('tool-newline', [mod(tool_name='Bash\n')])
    add('split-command-newline', [mod(tool_input={'command':'npm ci\n'}),
                                {'tool_input':{'command':'echo ok'},'turn_id':'x'}])
    add('command-error-first', [{'tool_input':5}, base])
    add('command-error-last', [base, {'tool_input':5}], snapshot=False, rc=5)
    add('nonbash-command-error', [{'tool_name':'Read','tool_input':5}], snapshot=False, rc=5)
    add('empty', [], snapshot=False)
    add('only-null', [None], snapshot=False)
    add('nonbash', [{'tool_name':'Read'}], snapshot=False)
    add('trailing-junk', [base], snapshot=False, rc=5, tail=b'!')
    return rows


def literal_tree(box):
    out = {}
    for p in sorted(box.rglob('*')):
        mode = stat.S_IMODE(p.lstat().st_mode)
        out[str(p.relative_to(box))] = ('link',mode,os.readlink(p)) if p.is_symlink() else \
            ('dir',mode) if p.is_dir() else ('file',mode,p.read_bytes().hex())
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--core', required=True)
    ap.add_argument('--report', required=True)
    ap.add_argument('--only')
    ap.add_argument('--expect-difference', action='store_true')
    a = ap.parse_args()
    results = []
    with tempfile.TemporaryDirectory(prefix='core-pre-input.') as tmp:
        box = Path(tmp).resolve()/'box'
        rows = cases(box/'project')
        if a.only:
            rows = [r for r in rows if r['id'] in a.only.split(',')]
        assert rows
        for row in rows:
            pair=[]
            for side in ('bash','core'):
                if box.exists(): shutil.rmtree(box)
                digest=hashlib.md5(str(box/'project').encode()).hexdigest()
                install.snapshot.seed(box,'hidden',digest)
                for rel in ('home','tmp','calls','state/pending'):
                    (box/rel).mkdir(parents=True,exist_ok=True)
                (box/'state/pending/other.json').write_bytes(b'{"snapshot_id":"seed","timestamp":4102444800}')
                install.target.stub(box)
                (box/'answer.json').write_text('{}')
                env=dict(os.environ,HOME=str(box/'home'),TMPDIR=str(box/'tmp'),SAFEDEPS_HOME=str(box/'state'),
                         PATH=str(box/'bin')+':'+os.environ['PATH'],PWD=str(box/'project'),LANG='C',LC_ALL='C')
                for key in list(env):
                    if key.lower().startswith('npm_config_') or key.startswith('SAFEDEPS_') and key!='SAFEDEPS_HOME':env.pop(key)
                argv=['/bin/bash',str(install.target.ROOT/'scripts/safedeps-pre-guard.sh')] if side=='bash' else [a.core,'pre']
                start=time.time()
                proc=subprocess.Popen(argv,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,cwd=box/'project')
                stdout,stderr=proc.communicate(row['raw'],timeout=30)
                end=time.time();error='';files={};calls=[]
                try:
                    assert proc.returncode==row['rc'],('rc',proc.returncode,row['rc'])
                    assert stdout==b'',('unexpected response',stdout)
                    if row['snapshot']:
                        files,calls=install.observe(box,proc,start,end,row)
                    else:
                        assert not list((box/'state/snapshots').iterdir()),'early exit wrote snapshot'
                        assert not list((box/'calls').iterdir()),'early exit asked npm'
                        files=literal_tree(box)
                except (AssertionError,ValueError,OSError,KeyError) as exc:
                    error=repr(exc)
                pair.append(dict(rc=proc.returncode,stdout=stdout.hex(),stderr=stderr.hex(),oracle=error,files=files,calls=calls))
            left,right=pair
            channels=[key for key in left if left[key]!=right[key]]
            if left['oracle']:channels.append('reference-oracle')
            if right['oracle']:channels.append('candidate-oracle')
            results.append(dict(id=row['id'],input_hex=row['raw'].hex(),channels=channels,expected=left,actual=right))
            print(('DIFF' if channels else 'ok')+' '+row['id']+' '+','.join(channels),flush=True)
    Path(a.report).write_text(json.dumps(results,indent=2)+'\n')
    bad=sum(bool(row['channels']) for row in results)
    print(f'core-pre-input: {len(results)} cases, {bad} differ',flush=True)
    reference_ok=all(not row['expected']['oracle'] for row in results)
    return int(not (reference_ok and bad) if a.expect_difference else bool(bad))


if __name__=='__main__':raise SystemExit(main())
