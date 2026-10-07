#!/usr/bin/env python3
"""Check native ledger output against fixed fixture expectations.
The historical filename is retained; no Bash hook or reference is executed.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--core', required=True)
a = p.parse_args()
root = Path(__file__).resolve().parents[2]
core = str(Path(a.core).resolve())
print('start:', subprocess.check_output(['uptime'], text=True).strip(), flush=True)
with tempfile.TemporaryDirectory(prefix='core-ledger.') as tmp:
    box = Path(tmp)
    ledger = box / 'ledger'
    ledger.mkdir()
    env = dict(os.environ, SAFEDEPS_HOME=str(box / 'home'), SAFEDEPS_LEDGER_DIR=str(ledger), LC_ALL='C')
    def key(eco, pkg, version, context=''):
        value = '\n'.join([eco, pkg, version] + ([context] if context else []))
        return 'sha256:' + hashlib.sha256(value.encode()).hexdigest()
    def entry(eco='npm', pkg='fixture', version='1', **fields):
        c = fields.get('project_context') or {}
        return dict(hash=key(eco, pkg, version, c.get('context_hash', '')), ecosystem=eco, package=pkg,
                    version=version, version_range=version, approved_at='2020-01-01T00:00:00Z',
                    expires_at='2099-01-01T00:00:00Z', approved_by='probe', evidence={}, **fields)
    def seed(rows):
        for f in ledger.iterdir(): f.unlink()
        for n, v in enumerate(rows):
            if isinstance(v, bytes):
                (ledger / f'broken-{n}.json').write_bytes(v)
            else:
                (ledger / (v['hash'].replace(':', '-', 1) + '.json')).write_text(json.dumps(v))
    cases = []
    def add(name, rows, command, closure=None): cases.append((name, rows, command, closure))
    add('hash', [], ['hash','npm','@scope/name','^1.2'])
    add('hash-context', [], ['hash','npm','@scope/name','^1.2','sha256:ctx'])
    add('missing', [], ['check','npm','fixture','1'])
    base = entry()
    add('hit', [base], ['check','npm','fixture','1'])
    add('expired', [dict(base, expires_at='2020-01-01T00:00:00Z')], ['check','npm','fixture','1'])
    add('bad-time', [dict(base, expires_at='not-a-time')], ['check','npm','fixture','1'])
    for field, value in [('evidence',None), ('version',1), ('transitive_specs',{}), ('project_context',{})]:
        add('invalid-'+field, [dict(base, **{field:value})], ['check','npm','fixture','1'])
    add('own-and-transitive', [entry(transitive_specs=[{'package':'child','version':2}])], ['index',''])
    add('owner-ecosystem', [entry(eco='pip', transitive_specs=[{'package':'child','version':'2'}])], ['misses','npm'], [{'package':'child','version':'2'}])
    add('revoked', [dict(base, revoked_at='2020-01-01T00:00:00Z')], ['misses','npm'], [{'package':'fixture','version':'1'}])
    add('damaged-neighbor', [base,b'{broken'], ['misses','npm'], [{'package':'fixture','version':'1'}, {'package':'miss','version':'2'}])
    add('unreadable-closure', [base], ['misses','npm'], b'{broken')
    add('null-closure', [base], ['misses','npm'], None)
    ctx = dict(type='npm-overrides-probe', context_hash='sha256:ctx', project_root='/fixture', overrides_source='/fixture/package.json', overrides_sha256='sha256:x', overrides={'child':'2'})
    contextual = entry(project_context=ctx)
    add('context-hit', [contextual], ['check','npm','fixture','1','sha256:ctx'])
    add('context-free-excludes', [contextual], ['misses','npm'], [{'package':'fixture','version':'1'}])
    add('context-index', [contextual], ['index','','sha256:ctx'])
    add('context-misses', [contextual], ['misses','npm','sha256:ctx'], [{'package':'fixture','version':'1'}])
    bad = 0
    for name, rows, command, closure in cases:
        seed(rows)
        data = closure if isinstance(closure, bytes) else json.dumps(closure).encode()
        closure_file = box / 'closure.json'
        closure_file.write_bytes(data)
        rust = subprocess.run([core,'ledger',*command], env=env, input=data, capture_output=True)
        op=command[0]; expected_rc=0; ok=False
        if op=='hash':
            ok=rust.stdout.decode()==key(*command[1:])
        elif op=='check':
            reason='hit' if name in ('hit','context-hit') else 'miss' if name=='missing' else 'expired' if name in ('expired','bad-time') else 'invalid'
            expected_rc=0 if reason=='hit' else 1
            answer=json.loads(rust.stdout)
            ok=(answer['approved']==(reason=='hit') and answer['reason']==reason
                and answer['hash']==key(*command[1:]))
        elif op=='index':
            owner=rows[0]
            wanted=[['npm','fixture','1',owner['hash'],'fixture','1']]
            if name=='own-and-transitive':wanted.append(['npm','child','2',owner['hash'],'fixture','1'])
            ok=sorted(line.split('\t') for line in rust.stdout.decode().splitlines())==sorted(wanted)
        else:
            missing={'owner-ecosystem':'child\t2\n','revoked':'fixture\t1\n',
                     'damaged-neighbor':'miss\t2\n','context-free-excludes':'fixture\t1\n'}
            wanted=missing.get(name,'')
            expected_rc=2 if name in ('unreadable-closure','null-closure') else 1 if wanted else 0
            ok=rust.stdout.decode()==wanted
            if name=='damaged-neighbor':ok=ok and b'skipping unreadable ledger entry' in rust.stderr
        ok=ok and rust.returncode==expected_rc
        bad+=not ok
        print(('ok - ' if ok else 'not ok - ')+name,flush=True)
        if not ok:print(rust.returncode,repr(rust.stdout),repr(rust.stderr),flush=True)
print('end:', subprocess.check_output(['uptime'], text=True).strip())
raise SystemExit(bool(bad))
