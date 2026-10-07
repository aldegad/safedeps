#!/usr/bin/env python3
"""Compare the pre snapshot component against the original Bash operations.

Both sides use the same absolute paths restored from one seed. Only the
returned, validated snapshot id and its meta timestamp are normalized. Seed
values and all other bytes stay literal. No payload command is executed.
"""

if __name__ == "__main__":
    import sys
    sys.stderr.write('retired: The extracted Bash snapshot comparison is retired. Synthetic seed and independent harvest helpers remain for native controls. See native-measure-disposition.json.\n')
    raise SystemExit(2)

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tempfile
import time


def reference(root):
    src = (root / 'scripts/safedeps-pre-guard.sh').read_text()

    def function(name):
        start = src.index(name + '() {\n')
        end = src.index('\n}\n', start) + 3
        return src[start:end] + '\n'

    start = src.index('PARENT_SNAPSHOT_ID=""\n', src.index('\nacquire_state_lock\n'))
    end = src.index('\n# --- Pre-flight security checks', start)
    body = src[start:end]
    pending_start=src.index('PENDING_DIR="${GUARD_DIR}/pending"',src.index('# Write the record of this install'))
    pending_end=src.index('\nif [[ -n "${UPDATED_COMMAND}" ]]',pending_start)
    pending=src[pending_start:pending_end]
    pending=pending.replace('${BASH_SOURCE[0]%/*}/..','${ROOT}')
    arrays = src[src.index('SAFEDEPS_LOCK_FILES=('):src.index('\numask 077')]
    return '''#!/bin/bash
set -euo pipefail
umask 077
ROOT="$1"
INPUT=$(cat)
PROJECT_DIR=$(jq -r .project <<< "$INPUT")
COMMAND=$(jq -r .command <<< "$INPUT")
DIR_HASH=$(jq -r .hash <<< "$INPUT")
TIMESTAMP=$(date +%s)
GUARD_DIR="$SAFEDEPS_HOME"
SNAPSHOT_DIR="$GUARD_DIR/snapshots"
STATE_LOCK_DIR="$GUARD_DIR/state.lock"
mkdir -p "$SNAPSHOT_DIR"
source "$ROOT/lib/npm/workspaces.sh"
''' + arrays + ''.join(function(name) for name in (
        'log_advisory', 'acquire_state_lock', 'release_state_lock',
        'snapshot_project_file', 'snapshot_workspace_manifests', 'compute_pending_key', 'guard_file_inode', 'write_state_file')) + '''
acquire_state_lock
trap release_state_lock EXIT
''' + body + '''
if jq -e 'has("pending")' <<< "$INPUT" >/dev/null; then
  KEY_DIR_HASH=$(jq -r '.pending.cwd_hash' <<< "$INPUT")
  PROJECT_DIR_FROM=$(jq -r '.pending.project_from' <<< "$INPUT")
  NPM_TRACE_WANTED=$(jq -r '.pending.trace' <<< "$INPUT")
  ATTRIBUTION=$(jq -r '.pending.attribution' <<< "$INPUT")
  PROJECT_FETCH=$(jq -c '.pending.fetch' <<< "$INPUT")
  PROJECT_FETCH_WHY=$(jq -r '.pending.fetch_why' <<< "$INPUT")
''' + pending + '''
fi
if jq -e 'has("rewrite")' <<< "$INPUT" >/dev/null; then
  UPDATED_COMMAND=$(jq -r .rewrite <<< "$INPUT")
  INERT_UNVERIFIED=false
  INERT_UNREAD=$(jq -r '.unread // false' <<< "$INPUT")
  INERT_RELEASE_ONLY=false
  mark_ignore_scripts_injected "$UPDATED_COMMAND"
fi
printf '%s\\n' "$SNAPSHOT_ID"
'''


def put(root, rel, data, mode=0o644):
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data if isinstance(data, bytes) else json.dumps(data).encode())
    path.chmod(mode)


def seed(box, name, project_hash):
    project = box / 'project'
    project.mkdir(parents=True)
    guard = box / 'state'
    (guard / 'snapshots').mkdir(parents=True, mode=0o700)
    guard.chmod(0o700)
    if name == 'empty':
        return
    put(project, 'package.json', {'name': 'example', 'version': '1.0.0'})
    put(project, 'package-lock.json', {'lockfileVersion': 3, 'packages': {}})
    if name == 'root-files':
        put(project, 'Cargo.lock', b'fixed lock bytes\n', 0o751)
        put(project, 'a.csproj', b'<Project/>\n')
        put(project, 'b.csproj', b'<Project/>\n', 0o400)
        (project / 'c.csproj').symlink_to('a.csproj')
    if name in ('hidden', 'node-link'):
        put(project, 'node_modules/.package-lock.json', b'{"packages":{}}', 0o751)
        put(project, 'node_modules/a/package.json', b'{"name":"a"}')
        put(project, 'node_modules/@x/b/package.json', b'{"name":"b"}')
        put(project, 'node_modules/a/deeper/package.json', b'{}')
        put(project, 'outside/package.json', b'{}')
        (project / 'node_modules/link').symlink_to(project / 'outside', target_is_directory=True)
        put(project, 'node_modules/.bin/a', b'#!/bin/sh\n', 0o755)
        put(project, 'node_modules/.bin/.hidden', b'x')
        if name == 'node-link':
            (project / 'node_modules').rename(project / 'tree')
            (project / 'node_modules').symlink_to('tree', target_is_directory=True)
    if name in ('workspace', 'workspace-link', 'lock-members', 'no-workspaces'):
        if name != 'no-workspaces':
            patterns = ['{unsupported}'] if name == 'lock-members' else ['packages/*']
            put(project, 'package.json', {'workspaces': patterns})
        put(project, 'packages/a/package.json', b'{"name":"a"}', 0o751)
        put(project, 'packages/b/package.json', b'{"name":"b"}\n', 0o600)
        put(project, 'hidden/c/package.json', b'{"name":"c"}')
        put(project, 'terminal/node_modules/package.json', b'{"name":"terminal"}')
        put(project, 'node_modules/dep/package.json', b'{"name":"dep"}')
        put(project, 'package-lock.json', {'packages': {
            'packages/a': {}, 'node_modules/dep': {}, '../escape': {},
            'terminal/node_modules': {}, 'packages/./b': {}}})
        put(project, 'node_modules/.package-lock.json', {'packages': {'hidden/c': {}}})
        if name == 'workspace-link':
            (project / 'packages/b').rename(project / 'b-target')
            (project / 'packages/b').symlink_to(project / 'b-target', target_is_directory=True)
    if name in ('parent', 'parent-fallback', 'parent-empty'):
        put(guard, 'snapshots/seed_meta.json', b'{"snapshot_id":"seed","timestamp":4102444800}', 0o600)
        put(guard, 'confirmed', b'seed\n', 0o600)
        own = b'seed\n' if name == 'parent' else b'missing\n' if name == 'parent-fallback' else b''
        put(guard, 'confirmed_' + project_hash, own, 0o600)


def harvest(box, sid, digest, started, ended):
    if not re.fullmatch(r'[0-9]+_' + digest + r'-[0-9]+(?:-[0-9]+)?', sid):
        raise AssertionError('snapshot id shape/hash: ' + repr(sid))
    meta_path = box / 'state/snapshots' / (sid + '_meta.json')
    meta = json.loads(meta_path.read_bytes())
    if meta['snapshot_id'] != sid or meta['timestamp'] != int(sid.split('_')[0]):
        raise AssertionError('snapshot meta does not match this call id')
    if not int(started) <= meta['timestamp'] <= int(ended):
        raise AssertionError('snapshot timestamp is outside this invocation')
    out = {}
    for path in sorted(box.rglob('*')):
        rel = str(path.relative_to(box))
        mode = stat.S_IMODE(path.lstat().st_mode)
        key = rel.replace('state/snapshots/' + sid + '_', 'state/snapshots/@SNAPSHOT@_')
        if path.is_symlink():
            value = ('link', mode, os.readlink(path))
        elif path.is_dir():
            value = ('dir', mode)
        else:
            data = path.read_bytes()
            if path == meta_path:
                # Preserve all formatting and other JSON fields. Only these
                # two values were validated as this invocation's values.
                data = data.replace(json.dumps(sid).encode(), b'"@SNAPSHOT@"', 1)
                data = re.sub(rb'("timestamp"\s*:\s*)' + str(meta['timestamp']).encode() + rb'(?=\s*[,}])',
                              rb'\g<1>0', data, count=1)
            value = ('file', mode, data.hex())
        out[key] = value
    return out


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--core', required=True)
    p.add_argument('--only')
    p.add_argument('--expect-difference', action='store_true')
    a = p.parse_args()
    root = Path(__file__).resolve().parents[2]
    core = Path(a.core).resolve()
    names = ['empty', 'root-files', 'hidden', 'node-link', 'workspace', 'workspace-link',
             'lock-members', 'no-workspaces', 'parent', 'parent-fallback', 'parent-empty', 'rewrite']
    if a.only:
        names = [name for name in names if name in a.only.split(',')]
    if not names:
        raise RuntimeError('no cases')
    bad = 0
    detected = 0
    with tempfile.TemporaryDirectory(prefix='core-pre-snapshot.') as tmp:
        outer = Path(tmp).resolve()
        ref = outer / 'reference.sh'
        ref.write_text(reference(root))
        box = outer / 'box'
        for name in names:
            digest = hashlib.md5(str(box / 'project').encode()).hexdigest()
            row = dict(project=str(box / 'project'), hash=digest, command='npm ci')
            if name == 'rewrite':
                row.update(rewrite='npm ci --ignore-scripts\nprintf "%s" "line\\next"', unread=True)
            observed = []
            for side in ('bash', 'core'):
                if box.exists():
                    shutil.rmtree(box)
                seed(box, name, digest)
                env = dict(os.environ, SAFEDEPS_HOME=str(box / 'state'), LC_ALL='C', LANG='C')
                cmd = ['bash', str(ref), str(root)] if side == 'bash' else [str(core), 'pre-probe']
                start = time.time()
                result = subprocess.run(cmd, input=json.dumps(row).encode() + b'\n', cwd=box / 'project',
                                        env=env, capture_output=True, timeout=15)
                end = time.time()
                sid = result.stdout.decode().strip()
                try:
                    files = harvest(box, sid, digest, start, end)
                    error = ''
                except (ValueError, AssertionError, OSError, KeyError) as exc:
                    files, error = {}, str(exc)
                observed.append((result.returncode, result.stderr.decode(errors='replace'), error, files))
            left, right = observed
            paths = sorted(k for k in left[3].keys() | right[3].keys() if left[3].get(k) != right[3].get(k))
            same = left[:3] == right[:3] and left[0] == 0 and not left[2] and not paths
            detected += left[0] == right[0] == 0 and not left[2] and not right[2] and bool(paths)
            bad += not same
            print(json.dumps(dict(case=name, same=same, reference=left[:3], candidate=right[:3], paths=paths)), flush=True)
            if not same:
                for path in paths[:12]:
                    print(json.dumps(dict(path=path, reference=left[3].get(path), candidate=right[3].get(path))), flush=True)
    print(json.dumps(dict(summary='core-pre-snapshot-probe', cases=len(names), differ=bad)), flush=True)
    return 0 if (detected > 0 if a.expect_difference else bad == 0) else 1


if __name__ == '__main__':
    raise SystemExit(main())
