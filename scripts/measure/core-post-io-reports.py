#!/usr/bin/env python3
"""Exercise native I/O reports and the existing oracle on permission fixtures.

The full e2e suite checks the rollback journal, continuation, and the separate
no-write source copy. This small suite retains the raw operation/report and
changes one reported fact at a time against the same independent readings.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--core', required=True)
p.add_argument('--output', required=True)
a = p.parse_args()
core = Path(a.core).resolve(strict=True)
out = Path(a.output).resolve()
out.mkdir(parents=True, exist_ok=False)
if os.geteuid() == 0:
    raise RuntimeError('permission cases require a non-root uid')
reader = ROOT/'scripts/test/lib/report-oracle-read.py'
rows = []

def save(path, value):
    path.write_text(json.dumps(value, indent=2)+'\n')

def oracle(case, line, label, expected):
    (case/(label+'.line')).write_text(line)
    shell = '''set -u
source "$1/scripts/test/lib/report-oracle.sh"
oracle_init "$2/oracle"
oracle_native_io_forms
oracle_reset
O_HOME="$2/home" O_CALL="$2" O_PROJECT="$2/project" O_SNAP=snapshot O_DIRECT=1 O_BLOCK=confirm
oracle_line "$(cat "$2/$3.line")"
[[ "$ORACLE_FAILED" == 0 ]]
'''
    r = subprocess.run(['bash', '-c', shell, 'oracle', str(ROOT), str(case), label], capture_output=True)
    (case/(label+'.stdout')).write_bytes(r.stdout)
    (case/(label+'.stderr')).write_bytes(r.stderr)
    (case/(label+'.rc')).write_text(str(r.returncode)+'\n')
    rows.append(dict(case=case.name, variant=label, rc=r.returncode, expected=expected))
    save(out/'results.json', rows)
    if r.returncode != expected:
        raise RuntimeError(str(rows[-1]))

for name in ['copy-differs', 'copy-absent', 'removal']:
    case = out/name; project = case/'project'; home = case/'home'
    project.mkdir(parents=True); (home/'snapshots').mkdir(parents=True)
    source = home/'snapshots/snapshot_package-lock.json'; source.write_bytes(b'snapshot bytes\n')
    target = project/'package-lock.json'
    restore = []
    if name == 'copy-differs':
        target.write_bytes(b'changed bytes\n'); target.chmod(0o444)
        restore.append((target, 0o644))
    elif name == 'copy-absent':
        project.chmod(0o555); restore.append((project, 0o755))
    else:
        target = project/'tree'; (target/'held-dir').mkdir(parents=True)
        (target/'held-dir/file').write_bytes(b'held\n')
        (target/'removable').write_bytes(b'removable\n')
        (target/'held-dir').chmod(0o555); restore.append((target/'held-dir', 0o755))
    try:
        subprocess.run([sys.executable, str(reader), 'native-io-before', str(project), str(case/'native-io.json')], check=True)
        request = dict(op='report', action='remove' if name=='removal' else 'restore', source=str(source), path=str(target))
        save(case/'request.json', request)
        r = subprocess.run([str(core), 'post-probe'], input=json.dumps(request).encode(), capture_output=True,
                           env=dict(os.environ, SAFEDEPS_HOME=str(home)))
        (case/'core.stdout').write_bytes(r.stdout); (case/'core.stderr').write_bytes(r.stderr)
        (case/'core.rc').write_text(str(r.returncode)+'\n')
        line = r.stdout.decode().rstrip('\n')
        if name=='removal':
            expected = f'not removed {target}: removal returned OS error 13; {target} exists'
            assert (target/'held-dir/file').read_bytes()==b'held\n' and not (target/'removable').exists()
        else:
            suffix = 'does not exist' if name=='copy-absent' else 'differs from the snapshot'
            expected = f'not restored {target}: copy returned OS error 13; {target} {suffix}'
            assert not target.exists() if name=='copy-absent' else target.read_bytes()==b'changed bytes\n'
        assert r.returncode==0 and not r.stderr and line==expected,(r.returncode,line,expected)
        facts=json.loads((case/'native-io.json').read_text())
        assert any(f['errno']==13 for f in facts['errors']), facts
        with (out/'reached.jsonl').open('a') as f:
            f.write(json.dumps(dict(case=name,core=str(core),core_sha256=hashlib.sha256(core.read_bytes()).hexdigest(),request=request,facts=facts,rc=r.returncode))+'\n')
        oracle(case,line,'baseline',0)
        oracle(case,line.replace('OS error 13','OS error 2'),'wrong-error',1)
        oracle(case,line.replace('returned OS error 13','returned without error'),'invented-success',1)
        old = line.replace('removal returned OS error 13','rm exit 1').replace('copy returned OS error 13','cp exit 1')
        oracle(case,old,'subprocess-status',1)
        evidence=(case/'native-io.json').read_bytes();(case/'native-io.json').unlink()
        oracle(case,line,'missing-evidence',1)
        (case/'native-io.json').write_bytes(evidence)
    finally:
        for path,mode in restore:
            if path.exists():path.chmod(mode)
print(json.dumps(dict(cases=3,checks=len(rows),failures=sum(r['rc']!=r['expected'] for r in rows))))
