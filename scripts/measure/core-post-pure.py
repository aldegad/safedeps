#!/usr/bin/env python3
"""Differential for post's file readers, report facts and whole-tree predicate.

Run on a test host, one process at a time. npm query is a recorded answer;
no install, network request, or rebuild runs. This is a component comparison,
not the complete hook/oracle/e2e result. --control alters one Rust answer to
prove the comparator rejects it. Every report action runs on twin disks.
"""
import argparse
import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--core', required=True)
p.add_argument('--report')
p.add_argument('--control', action='store_true')
a = p.parse_args()
root = Path(__file__).resolve().parents[2]
core = str(Path(a.core).resolve())
source = (root / 'scripts/safedeps-post-verify.sh').read_text()


def function(name):
    start = source.index(name + '() {')
    return source[start:source.index('\n}\n', start) + 3]


wrapper = r'''#!/bin/bash
set -uo pipefail
source "$ROOT/lib/npm/closure.sh"
source "$ROOT/lib/npm/workspaces.sh"
source "$ROOT/lib/gates/npm-reach.sh"
source "$ROOT/lib/gates/report-facts.sh"
source "$ROOT/lib/npm/ask.sh"
set +e
input=$(cat)
op=$(jq -r .op <<< "$input")
path=$(jq -r '.path // ""' <<< "$input")
PROJECT_DIR="$path"
NPM_HIDDEN_LOCKFILE=node_modules/.package-lock.json
NPM_PROJECT_SCOPE=(--global=false --location=project)
NPM_ORIGIN_TEXT_JQ='def sd_origin_text: if .unknown != null then "?" + (.unknown|tostring) elif .scope != null then "\(.registry) (npm'"'"'s \(.scope):registry)" else .registry // "a registry npm will not print" end;'
log_advisory() { printf 'TIME\t%s\n' "$1" >> "$SAFEDEPS_HOME/advisory.log"; }
'''
wrapper += '\n'.join(function(n) for n in ['npm_bundled_names', 'npm_workspace_member_dirs', 'npm_rebuild_unrecorded'])
wrapper += r'''
# A query is fixture data. Its bytes are the input to both implementations.
safedeps_npm_ask_start() { cp "$QUERY" "$1"; SAFEDEPS_NPM_ASK_RCS=(0); }
safedeps_npm_ask_wait() { return 0; }
case "$op" in
closure) safedeps_npm_lock_closure "$path" ;;
new-records)
    earlier=()
    while IFS= read -r x; do earlier+=("$x"); done < <(jq -r '.earlier[]' <<< "$input")
    safedeps_npm_new_records "$path" "${earlier[@]+"${earlier[@]}"}" ;;
workspaces) safedeps_npm_workspace_members "$path" ;;
workspace-dirs) npm_workspace_member_dirs ;;
path) fact_path "$path" ;;
outside) fact_outside "$(jq -r .project <<< "$input")" "$path" ;;
reach) safedeps_npm_reach_blocker "$path" ;;
inert) fact_inert "$path" "$(jq -r .input <<< "$input")" ;;
tree)
    QUERY=$(jq -r .query <<< "$input")
    NPM_FETCH_FACTS=$(jq -c .facts <<< "$input")
    wh=$(mktemp); jq .withheld <<< "$input" > "$wh"
    npm_rebuild_unrecorded "$path" "$wh"; rc=$?; rm -f "$wh"; exit "$rc" ;;
report)
    case "$(jq -r .action <<< "$input")" in
    restore) did_restore "$(jq -r .source <<< "$input")" "$path" ;;
    remove) did_remove "$path" ;;
    inert) report_inert "$path" "$(jq -r .input <<< "$input")" ;;
    rebuild) report_rebuild "$path" "$(jq -r .input <<< "$input")" "$(jq -r .fact <<< "$input")" ;;
    workspaces) report_workspaces_key "$path" ;;
    esac
    [[ $(jq -r .changed_nothing <<< "$input") != true ]] || report_changed_nothing
    [[ ${#ROLLBACK_WARNINGS[@]} == 0 ]] || printf '%s\n' "${ROLLBACK_WARNINGS[@]}"
    exit 0 ;;
esac
'''

cases = []


def add(label, request, files=None, dirs=(), links=None):
    cases.append((label, request, files or {}, dirs, links or {}))


shapes = [None, False, True, 0, 1.5, '', 'x', [], [1], {}, {'x': 1}]
for i, v in enumerate(shapes):
    add(f'closure-root-{i}', {'op': 'closure', 'path': '@ROOT@/lock'}, {'lock': json.dumps(v)})
    for field in ['version', 'name']:
        rec = {'version': '1.0.0', field: v}
        add(f'closure-{field}-{i}', {'op': 'closure', 'path': '@ROOT@/lock'}, {'lock': json.dumps({'packages': {'node_modules/a': rec}})})
for key in ['node_modules/a', 'node_modules/@s/a', 'node_modules/', 'x/node_modules/z/node_modules/a', 'packages/a', 'node_modules/@s', 'xnode_modules/a']:
    add('closure-key-' + key, {'op': 'closure', 'path': '@ROOT@/lock'}, {'lock': json.dumps({'packages': {key: {'version': '1'}}})})
for i, raw in enumerate(['', '{} {}', '[1] {}', '{} [1]', '{', '{"packages":{"node_modules/a":{"version":1.0}}}', '{"packages":[]}']):
    add(f'closure-stream-{i}', {'op': 'closure', 'path': '@ROOT@/lock'}, {'lock': raw})
records = {'packages': {'node_modules/z': {'version': '1', 'resolved': 'https://registry.npmjs.org/z'}, 'node_modules/@s/a': {'version': '2', 'link': True, 'resolved': 'packages/a'}, 'packages/a': {'name': '@s/a', 'version': '2'}}}
for before in [{}, records, {'packages': {'node_modules/z': {'version': '0', 'resolved': 'https://registry.npmjs.org/z'}}}, {'dependencies': {'z': {'version': '1'}}}]:
    add('records-' + str(len(cases)), {'op': 'new-records', 'path': '@ROOT@/now', 'earlier': ['@ROOT@/before']}, {'now': json.dumps(records), 'before': json.dumps(before)})
for i, workspace in enumerate([None, False, 0, '', True, 'x', [], ['packages/*'], {'packages': ['packages/*']}, ['packages/**'], ['packages/a', '!packages/b'], ['packages/{a,b}'], ['packages/../packages/a'], ['packages/.*'], [3]]):
    files = {'package.json': json.dumps({'workspaces': workspace}), 'packages/a/package.json': '{}', 'packages/b/package.json': '{}', 'packages/.dot/package.json': '{}', 'packages/a/node_modules/x/package.json': '{}'}
    for op in ['workspaces', 'workspace-dirs']:
        add(f'{op}-{i}', {'op': op, 'path': '@ROOT@'}, files)
input_text = json.dumps({'tool_name': 'Bash', 'tool_input': {'command': 'npm ci'}})
for i, meta in enumerate([{}, [], None, {'record': 1, 'ignore_scripts_injected': False}, {'record': 2, 'ignore_scripts_injected': False}, {'record': 2, 'ignore_scripts_injected': True}, {'record': 2, 'ignore_scripts_injected': True, 'updated_command': 'npm ci'}, {'record': 2, 'ignore_scripts_injected': True, 'updated_command': 'npm ci --ignore-scripts', 'ignore_scripts_unread': True}, {'record': 2.0, 'ignore_scripts_injected': True, 'updated_command': 5}]):
    for op in ['inert', 'report']:
        add(f'{op}-record-{i}', {'op': op, 'action': 'inert', 'path': '@ROOT@/meta', 'input': input_text}, {'meta': json.dumps(meta)})
add('missing-record', {'op': 'inert', 'path': '@ROOT@/meta', 'input': input_text})
for action in ['restore', 'remove']:
    for target in ['absent', 'file', 'directory', 'link', 'broken']:
        files = {'source': 'old'}
        if target == 'file': files['target'] = 'new'
        links = {'target': 'source' if target == 'link' else 'gone'} if target in ['link', 'broken'] else {}
        add(f'{action}-{target}', {'op': 'report', 'action': action, 'source': '@ROOT@/source', 'path': '@ROOT@/target', 'changed_nothing': True}, files, ['target'] if target == 'directory' else [], links)
public = {'registry': 'https://registry.npmjs.org/', 'replace': 'npmjs', 'scopes': {}}
base_rec = {'version': '1.0.0', 'resolved': 'https://registry.npmjs.org/a/-/a-1.0.0.tgz', 'integrity': 'sha512-a'}
for i, changes in enumerate([{}, {'version': '2'}, {'version': 'v1.0.0'}, {'name': 'other'}, {'link': True}, {'resolved': None}, {'resolved': 'http://elsewhere/a'}, {'integrity': ''}, {'integrity': 'sha512-a sha1-b'}]):
    rec = dict(base_rec, **changes)
    for held in [{}, {'sha512-a': {'project': '/first', 'origins': ['http://other/'], 'at': 1}}]:
        for facts in [[public, public], [dict(public, registry='https://private/'), public], [{'unknown': 'no answer'}]]:
            add(f'tree-{i}-{len(cases)}', {'op': 'tree', 'path': '@ROOT@', 'query': '@ROOT@/query', 'facts': facts, 'withheld': held}, {'package-lock.json': json.dumps({'packages': {'node_modules/a': rec}}), 'query': json.dumps([{'location': 'node_modules/a', 'name': 'a', 'version': '1.0.0'}])})


def substitute(value, directory):
    if isinstance(value, str): return value.replace('@ROOT@', str(directory))
    if isinstance(value, list): return [substitute(v, directory) for v in value]
    if isinstance(value, dict): return {k: substitute(v, directory) for k, v in value.items()}
    return value


def disk(directory):
    return {str(p.relative_to(directory)): ('link', os.readlink(p)) if p.is_symlink() else ('file', p.read_bytes().hex()) if p.is_file() else ('dir', '') for p in directory.rglob('*') if p.name != 'advisory.log'}


rows = []
print('start:', subprocess.check_output(['uptime'], text=True).strip(), flush=True)
with tempfile.TemporaryDirectory(prefix='core-post-pure.') as tmp:
    box = Path(tmp)
    script = box / 'reference.sh'; script.write_text(wrapper)
    for label, request, files, dirs, links in cases:
        results = []
        for side in ['bash', 'rust']:
            d = box / side
            if d.exists(): shutil.rmtree(d)
            d.mkdir(); (d / 'home').mkdir()
            for directory in dirs: (d / directory).mkdir(parents=True, exist_ok=True)
            for name, content in files.items():
                path = d / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_text(content)
            for name, target in links.items():
                path = d / name; path.parent.mkdir(parents=True, exist_ok=True); path.symlink_to(target)
            env = dict(os.environ, ROOT=str(root), SAFEDEPS_HOME=str(d / 'home'), LC_ALL='C')
            cmd = ['bash', str(script)] if side == 'bash' else [core, 'post-probe']
            proc = subprocess.run(cmd, input=json.dumps(substitute(request, d)).encode(), capture_output=True, env=env, timeout=15)
            # Callers consume failures as an unavailable reading, regardless
            # of jq's particular nonzero exit code. Partial stdout on a failed
            # closure is discarded by its caller too.
            out = proc.stdout.replace(str(d).encode(), b'@ROOT@')
            failed = proc.returncode != 0
            if failed and request['op'] == 'closure': out = b''
            if a.control and side == 'rust' and label == 'closure-root-0': out += b'mutant'
            results.append((failed if request['op'] == 'closure' else proc.returncode, out.decode(errors='replace'), disk(d)))
        same = results[0] == results[1]
        rows.append(dict(name=label, same=same, reference=results[0], core=results[1]))
        if not same: print('DIFF', label, repr(results[0][:2]), repr(results[1][:2]), flush=True)
if a.report: Path(a.report).write_text(json.dumps(rows, ensure_ascii=False, indent=2) + '\n')
bad = sum(not r['same'] for r in rows)
print('end:', subprocess.check_output(['uptime'], text=True).strip())
print(f'core-post-pure: {len(rows)} cases, {bad} differ')
raise SystemExit(0 if (bad > 0 if a.control else bad == 0) else 1)
