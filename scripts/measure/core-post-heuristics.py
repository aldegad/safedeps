#!/usr/bin/env python3
"""Same-host comparison of post's file classifier, scripts, and lock diff.

Uses synthetic files and the original Bash functions. No package install,
registry request, or command from a hook payload is executed. Run remotely.
"""
import argparse
import json
import os
from pathlib import Path
import random
import shutil
import subprocess
import tempfile

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--core', required=True)
p.add_argument('--report', required=True)
p.add_argument('--only')
p.add_argument('--expect-difference', action='store_true')
a = p.parse_args()
root = Path(__file__).resolve().parents[2]
core = str(Path(a.core).resolve())
source = (root / 'scripts/safedeps-post-verify.sh').read_text()
def function(name):
    start = source.index(name + '() {')
    return source[start:source.index('\n}\n', start)+3]
wrapper = '''#!/bin/bash
set -euo pipefail
GUARD_DIR="$SAFEDEPS_HOME"
SNAPSHOT_DIR="$GUARD_DIR/snapshots"
PROJECT_DIR="$BOX/project"
SNAPSHOT_ID=pre
REASONS=()
NPM_NEW_NODES=()
SAFEDEPS_LOCK_FILES=(package-lock.json)
'''
for name in ['files_differ', 'redact_install_script_content', 'packages_with_install_scripts', 'check_postinstall_scripts', 'check_lockfile_diff', 'check_binaries']:
    wrapper += function(name) + '\n'
wrapper += '''case "$1" in
binaries) check_binaries ;;
scripts) NPM_NEW_NODES=(node_modules/item); check_postinstall_scripts ;;
lockfile) check_lockfile_diff ;;
esac
if [[ ${#REASONS[@]} -gt 0 ]]; then
    result=$(printf '%s\\n' "${REASONS[@]}"); printf '%s' "$result"
fi
'''
rows = []
print('start:', subprocess.check_output(['uptime'], text=True).strip(), flush=True)
with tempfile.TemporaryDirectory(prefix='core-post-heuristics.') as tmp:
    box = Path(tmp)
    ref = box / 'reference.sh'
    ref.write_text(wrapper)
    project = box / 'project'
    home = box / 'state'
    def reset():
        for d in [project, home]:
            shutil.rmtree(d, ignore_errors=True)
        (project / 'node_modules/.bin').mkdir(parents=True)
        (home / 'snapshots').mkdir(parents=True)
    env = dict(os.environ, SAFEDEPS_HOME=str(home), BOX=str(box), LC_ALL='C')
    def compare(label, action, setup):
        if a.only and label != a.only:
            return
        reset()
        setup()
        req = dict(op='heuristics', action=action, path=str(project), id='pre', nodes=['node_modules/item'])
        bash = subprocess.run(['bash', str(ref), action], env=env, capture_output=True, timeout=20)
        rust = subprocess.run([core, 'post-probe'], env=env, input=json.dumps(req).encode(), capture_output=True, timeout=20)
        left, right = (bash.returncode, bash.stdout.decode()), (rust.returncode, rust.stdout.decode())
        same = left == right
        rows.append(dict(name=label, same=same, reference=left, core=right,
                         reference_stderr=bash.stderr.decode(), core_stderr=rust.stderr.decode()))
        if not same:
            print('DIFF', label, repr(left), repr(right), flush=True)
    bins = project / 'node_modules/.bin'
    def write_bin(name, content, mode=0o644):
        (bins/name).write_bytes(content)
        (bins/name).chmod(mode)
    compare('bin-shell', 'binaries', lambda: write_bin('script', b'#!/bin/sh\nexit 0\n', 0o755))
    compare('bin-script-no-mode', 'binaries', lambda: write_bin('script', b'#!/bin/sh\nexit 0\n'))
    compare('bin-text', 'binaries', lambda: write_bin('note', b'plain text\n', 0o755))
    compare('bin-native', 'binaries', lambda: shutil.copyfile('/usr/bin/true', bins/'native'))
    compare('bin-name-executable', 'binaries', lambda: write_bin('executable-note', b'plain text\n'))
    def link_fixture(broken=False):
        if not broken:
            (project/'target').write_bytes(b'#!/bin/sh\nexit 0\n')
        (bins/'linked').symlink_to('../../target')
    compare('bin-link', 'binaries', link_fixture)
    compare('bin-broken-link', 'binaries', lambda: link_fixture(True))
    compare('bin-directory', 'binaries', lambda: (bins/'directory').mkdir())
    def cap_fixture(old=False):
        for i in range(23):
            write_bin('script-%02d' % i, b'#!/bin/sh\nexit 0\n', 0o755)
        if old:
            (home/'snapshots/pre_bins.list').write_text('script-00\nscript-01\n')
    compare('bin-cap20', 'binaries', cap_fixture)
    compare('bin-old-cap20', 'binaries', lambda: cap_fixture(True))
    for label, content in [('network', 'curl https://example.invalid/'), ('exec', 'node -e "eval(1)"'), ('paths', 'cat $HOME/.ssh/config'), ('encoded', 'echo \\x61'), ('plain', 'node build.js'), ('long', 'curl '+('x'*180))]:
        def setup(content=content):
            package = project/'node_modules/item'
            package.mkdir()
            (package/'package.json').write_text(json.dumps(dict(name='item', scripts=dict(postinstall=content))))
        compare('script-'+label, 'scripts', setup)
    def lock_setup(before, after):
        (home/'snapshots/pre_package-lock.json').write_text(before)
        (project/'package-lock.json').write_text(after)
    for count in [0, 1, 50, 51, 90]:
        after = ''.join('  "resolved": "https://example.invalid/%d",\n' % i for i in range(count))
        compare('lock-added-%d' % count, 'lockfile', lambda after=after: lock_setup('{}\n', after))
    rng = random.Random(20261006)
    for i in range(60):
        before = ''.join(rng.choice(['  "resolved": "a",\n', '  "resolved": "b",\n', 'other\n', '}\n']) for _ in range(rng.randrange(1,70)))
        after = ''.join(rng.choice(['  "resolved": "a",\n', '  "resolved": "b",\n', 'other\n', '}\n']) for _ in range(rng.randrange(1,70)))
        label = 'diff-%02d' % i
        if a.only and label != a.only:
            continue
        reset(); lock_setup(before, after)
        diff = subprocess.run(['diff', str(home/'snapshots/pre_package-lock.json'), str(project/'package-lock.json')], capture_output=True, timeout=20)
        expected = sum(line.startswith(b'>') and b'"resolved"' in line for line in diff.stdout.splitlines())
        rust = subprocess.run([core, 'post-probe'], input=json.dumps(dict(op='resolved-diff', before=before, after=after)).encode(), env=env, capture_output=True, timeout=20)
        same = rust.returncode == 0 and rust.stdout == str(expected).encode()
        rows.append(dict(name=label, same=same, reference=expected, core=rust.stdout.decode(), rc=rust.returncode))
        if not same:
            print('DIFF', label, expected, rust.stdout.decode(), flush=True)
report = dict(cases=len(rows), differences=sum(not row['same'] for row in rows), rows=rows)
Path(a.report).write_text(json.dumps(report, indent=2)+'\n')
print(json.dumps({k:v for k,v in report.items() if k != 'rows'}), flush=True)
print('end:', subprocess.check_output(['uptime'], text=True).strip(), flush=True)
raise SystemExit(0 if rows and bool(report['differences']) == a.expect_difference else 1)
