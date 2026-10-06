#!/usr/bin/env python3
"""Compare the Rust shared ledger reader with lib/ledger/ledger.sh.
Run on a test host, with --core. --control replaces the bash hash on a copy
of the wrapper; it must produce differences. No installs or network calls.
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
p.add_argument('--control', action='store_true')
a = p.parse_args()
root = Path(__file__).resolve().parents[2]
core = str(Path(a.core).resolve())
print('start:', subprocess.check_output(['uptime'], text=True).strip(), flush=True)
with tempfile.TemporaryDirectory(prefix='core-ledger.') as tmp:
    box = Path(tmp)
    ledger = box / 'ledger'
    ledger.mkdir()
    env = dict(os.environ, SAFEDEPS_HOME=str(box / 'home'), SAFEDEPS_LEDGER_DIR=str(ledger), LC_ALL='C')
    wrapper = box / 'reference.sh'
    wrapper.write_text('''#!/bin/bash
set -euo pipefail
source "$1/lib/ledger/ledger.sh"
shift
''' + ('''safedeps_ledger_hash() { printf 'sha256:control'; }
''' if a.control else '') + '''case "$1" in
hash) shift; safedeps_ledger_hash "$@" ;;
check) shift; safedeps_ledger_check "$@" ;;
index) safedeps_ledger_effect_index "${3:-}" ;;
misses) safedeps_ledger_effect_check_batch "$2" "$4" "${3:-}" ;;
esac
''')
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
        refargs = list(command)
        if command[0] == 'misses': refargs += [''] * (3-len(refargs)) + [str(closure_file)]
        ref = subprocess.run(['bash', str(wrapper), str(root), *refargs], env=env, input=data, capture_output=True)
        rust = subprocess.run([core,'ledger',*command], env=env, input=data, capture_output=True)
        # index follows the filesystem's enumeration; its order is not a verdict.
        left, right = ref.stdout, rust.stdout
        if command[0] == 'index': left, right = sorted(left.splitlines()), sorted(right.splitlines())
        # jq's parse diagnostics are implementation-specific; retain named skips.
        def warnings(s): return [l for l in s.splitlines() if b'skipping unreadable ledger entry' in l]
        same = (ref.returncode,left,warnings(ref.stderr)) == (rust.returncode,right,warnings(rust.stderr))
        print(('ok ' if same else 'DIFF ') + name, flush=True)
        if not same:
            bad += 1
            print('  bash', ref.returncode, repr(ref.stdout), repr(ref.stderr))
            print('  core', rust.returncode, repr(rust.stdout), repr(rust.stderr))
print('end:', subprocess.check_output(['uptime'], text=True).strip())
print(f'core-ledger-differential: {len(cases)} cases, {bad} differ, control={a.control}')
raise SystemExit(0 if (bad > 0 if a.control else bad == 0) else 1)
