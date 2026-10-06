#!/usr/bin/env python3
"""Check public pre's collision response and call-bound file effects.

--cases is a frozen JSONL manifest, supplied before execution. Commands remain
data: this probe invokes only the public hook and a fixed npm-stub preflight.
It does not execute a rewritten command or claim npm option/argv equivalence.
Unresolved rows stay outside the contract-pass denominator. Raw clock values
are retained, but exact native clock provenance remains unobserved.
The output directory must be new; a failed run is never overwritten.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
SEED = b'{"snapshot_id":"seed","timestamp":4102444800}'
REASON = ('safedeps: UNDECIDED - required --ignore-scripts flags could not be '
          'placed while preserving command data and how npm reads its options. '
          'This command is blocked and no rewritten command was sent. '
          'This is not a finding about the packages.')


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, HERE / file)
    obj = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(obj)
    return obj


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=True) + '\n')


def read_json(raw):
    def unique(pairs):
        obj = {}
        for key, value in pairs:
            if key in obj:
                raise ValueError('duplicate JSON field: ' + key)
            obj[key] = value
        return obj
    return json.loads(raw, object_pairs_hook=unique)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def tree(root):
    """Walk without following links; preserve bytes, identity and raw clocks."""
    rows = {}
    for path in sorted(root.rglob('*')):
        st = path.lstat()
        row = dict(mode=stat.S_IMODE(st.st_mode), inode=st.st_ino,
                   mtime_ns=st.st_mtime_ns, ctime_ns=st.st_ctime_ns)
        if path.is_symlink():
            row.update(kind='link', target=os.readlink(path))
        elif path.is_dir():
            row.update(kind='dir')
        elif path.is_file():
            row.update(kind='file', hex=path.read_bytes().hex())
        else:
            row.update(kind='other')
        rows[str(path.relative_to(root))] = row
    return rows


def nonclock(rows):
    return {k: {f: v for f, v in row.items()
                if f not in ('mtime_ns', 'ctime_ns')} for k, row in rows.items()}


def run(argv, payload, env, cwd, dest):
    """Preserve partial output on timeout and act only on this owned child."""
    started = time.time_ns()
    proc = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, cwd=cwd, env=env)
    expired = False
    try:
        stdout, stderr = proc.communicate(payload, timeout=35)
    except subprocess.TimeoutExpired:
        expired = True
        proc.kill()
        stdout, stderr = proc.communicate()
    (dest / 'stdout').write_bytes(stdout)
    (dest / 'stderr').write_bytes(stderr)
    result = dict(argv=argv, pid=proc.pid, rc=proc.returncode, timeout=expired,
                  started_ns=started, ended_ns=time.time_ns())
    write_json(dest / 'process.json', result)
    return result, stdout, stderr


def prepare(box, row, snapshot, target):
    digest = hashlib.md5(str(box / 'project').encode()).hexdigest()
    snapshot.seed(box, 'hidden', digest)
    for name in ('home', 'tmp', 'calls', 'state/pending'):
        (box / name).mkdir(parents=True, exist_ok=True)
    (box / 'state/pending/other.json').write_bytes(SEED)
    target.stub(box)
    (box / 'answer.json').write_text('{}')
    cli = box / 'bin/safedeps'
    cli.write_text('#!/bin/sh\nexit 99\n')
    cli.chmod(0o755)
    # These two environments differ in what sudo would do. Neither is called
    # by a pre hook. A sentinel records an erroneous invocation of either.
    if 'sudo' in row:
        sudo = box / 'bin/sudo'
        behavior = 'os.execvp(sys.argv[1],sys.argv[1:])' if row['sudo'] == 'exec' else 'print(" ".join(sys.argv[1:]))'
        sudo.write_text('#!' + sys.executable + ' -B\nimport os,sys\nfrom pathlib import Path\n'
                        + 'Path(' + repr(str(box / 'SUDO_EXECUTED')) + ').write_bytes(b"called")\n'
                        + behavior + '\n')
        sudo.chmod(0o755)
    env = dict(PATH=str(box / 'bin') + ':' + os.environ['PATH'],
               HOME=str(box / 'home'), TMPDIR=str(box / 'tmp'),
               SAFEDEPS_HOME=str(box / 'state'), PWD=str(box / 'project'),
               LANG='C', LC_ALL='C', X='x')
    # macOS Python initializes this platform entry. Seed its inherited value
    # explicitly before fixing the expected environment, without dropping it
    # from either the expectation or the captured record.
    if '__CF_USER_TEXT_ENCODING' in os.environ:
        env['__CF_USER_TEXT_ENCODING'] = os.environ['__CF_USER_TEXT_ENCODING']
    return env, digest


def preflight(box, env, dest):
    cache = box / 'tmp/preflight/cache'
    cache.parent.mkdir()
    argv = [str(box / 'bin/npm'), 'prefix', '--cache', str(cache)]
    expected = dict(argv=['prefix', '--cache', '@PRIVATE_CACHE@'],
                    cwd=str(box / 'project'), env=env)
    write_json(dest / 'expected.json', dict(argv=argv, record=expected))
    proc, stdout, stderr = run(argv, b'', env, box / 'project', dest)
    paths = list((box / 'calls').iterdir())
    records = [read_json(p.read_bytes()) for p in paths]
    write_json(dest / 'records.json', records)
    if proc['rc'] != 0 or proc['timeout'] or stderr or stdout != (str(box / 'project') + '\n').encode() or records != [expected]:
        raise ValueError('npm stub preflight did not match fixed argv/output/one record')
    (box / 'calls').rename(dest / 'calls')
    (box / 'calls').mkdir()


def inspect(row, box, process, stdout, stderr, before):
    checks = {}
    def check(name, value):
        checks[name] = bool(value)
    check('project-unchanged', nonclock(tree(box / 'project')) == nonclock(before))
    check('no-command-code', not (box / 'EXECUTED').exists() and not (box / 'SUDO_EXECUTED').exists())
    check('other-call-unchanged', (box / 'state/pending/other.json').read_bytes() == SEED)
    calls = [read_json(p.read_bytes()) for p in sorted((box / 'calls').iterdir())]
    allowed = lambda a: bool(a) and (a[0] in ('prefix', 'root') or a[:2] == ['config', 'ls']) and a[-2:] == ['--cache', '@PRIVATE_CACHE@']
    check('only-own-npm-queries', all(allowed(c['argv']) and c['cwd'] == str(box / 'project') for c in calls))
    answer = read_json(stdout) if stdout else {}
    hook = answer.get('hookSpecificOutput', {})
    metas = [(p.name, read_json(p.read_bytes())) for p in sorted((box / 'state/snapshots').glob('*_meta.json'))]
    log = box / 'state/advisory.log'
    advisory = log.read_bytes() if log.exists() else b''
    pending = sorted(p.name for p in (box / 'state/pending').iterdir() if p.name != 'other.json')
    detail = dict(answer=answer, metas=metas, pending=pending, advisory_hex=advisory.hex(), calls=calls)
    if row['expect'] == 'unresolved':
        return checks, detail
    check('hook-rc', process['rc'] == 0 and not process['timeout'])
    check('hook-stderr', not stderr)
    check('one-snapshot', len(metas) == 1)
    if len(metas) != 1:
        return checks, detail
    filename, meta = metas[0]
    sid = filename.removesuffix('_meta.json')
    digest = hashlib.md5(str(box / 'project').encode()).hexdigest()
    check('snapshot-binding', meta.get('record') == 2 and meta.get('snapshot_id') == sid
          and meta.get('project_dir') == str(box / 'project') and meta.get('command') == row['command']
          and bool(re.fullmatch(r'[0-9]+_' + digest + '-' + str(process['pid']) + r'(?:-[0-9]+)?', sid)))
    check('snapshot-time-alias', meta.get('timestamp') == int(sid.split('_')[0]))
    if row['expect'] == 'collision':
        expected = dict(hookSpecificOutput=dict(hookEventName='PreToolUse', permissionDecision='deny', permissionDecisionReason=REASON))
        check('collision-deny', answer == expected)
        check('no-updated-input', 'updatedInput' not in hook)
        check('no-own-pending-or-trace', not pending)
        check('no-backstop-entry', not list((box / 'state/pending/backstop').glob('*')))
        check('initial-meta', meta.get('ignore_scripts_injected') is False
              and meta.get('ignore_scripts_unread') is False and 'updated_command' not in meta)
        prefix = b'pre-guard DENY: inert rewrite obligations conflict ('
        expected_line = prefix + row['kind'].encode() + b'); UNDECIDED, no rewrite was sent. Command: ' + row['command'].encode()
        bodies = [line.partition(b'\t')[2] for line in advisory.splitlines()]
        check('one-collision-advisory', bodies.count(expected_line) == 1
              and sum(body.startswith(prefix) for body in bodies) == 1)
        check('no-readings-disagreement', not any(body.startswith(b'pre-guard DENY: the readings (') for body in bodies))
    else:
        path = box / 'state/pending/id-call-1.json'
        check('own-record', path.is_file())
        if path.is_file():
            record = read_json(path.read_bytes())
            check('record-binding', record.get('tool_use_id') == 'call-1' and record.get('snapshot_id') == sid
                  and record.get('project_dir') == str(box / 'project') and record.get('dir_hash') == digest)
        if row['expect'] == 'rewrite':
            check('fixed-rewrite', answer == dict(hookSpecificOutput=dict(hookEventName='PreToolUse', permissionDecision='allow', updatedInput=dict(command=row['rewritten']))))
            check('rewrite-meta', meta.get('ignore_scripts_injected') is True
                  and meta.get('updated_command') == row['rewritten'] and meta.get('ignore_scripts_unread') is row.get('unread', False))
        else:
            check('unchanged-response', stdout == b'')
            check('unchanged-meta', meta.get('ignore_scripts_injected') is False and 'updated_command' not in meta)
    return checks, detail


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--core', required=True)
    ap.add_argument('--cases', required=True)
    ap.add_argument('--bundles', required=True)
    ap.add_argument('--only')
    args = ap.parse_args()
    core = Path(args.core).resolve()
    corpus = Path(args.cases).read_bytes()
    rows = [read_json(line) for line in corpus.splitlines() if line]
    if args.only:
        selected = args.only.split(',')
        rows = [row for row in rows if row['id'] in selected]
        if set(selected) != {row['id'] for row in rows}:
            raise ValueError('unknown selected id')
    if not rows or len({row['id'] for row in rows}) != len(rows):
        raise ValueError('empty or duplicate case ids')
    for row in rows:
        if not re.fullmatch(r'[a-zA-Z0-9_-]+', row['id']) or row['expect'] not in ('collision', 'rewrite', 'unchanged-codex', 'unchanged-nonnpm', 'unresolved'):
            raise ValueError('invalid case declaration')
    dest = Path(args.bundles).resolve()
    dest.mkdir(parents=True, exist_ok=False)
    (dest / 'cases.jsonl').write_bytes(corpus)
    write_json(dest / 'declaration.json', dict(core=str(core), binary_sha256=sha(core),
        cases_sha256=hashlib.sha256(corpus).hexdigest(), selected=[r['id'] for r in rows],
        sources={name: sha(HERE / name) for name in (Path(__file__).name, 'core-pre-snapshot-probe.py', 'core-pre-targets-probe.py')},
        exact_native_clock_source='unobserved', input_commands_executed=False,
        query_cache_argv='validated private cache placeholder'))
    snapshot = module('claude_snapshot_seed', 'core-pre-snapshot-probe.py')
    target = module('claude_query_stub', 'core-pre-targets-probe.py')
    results = []
    for row in rows:
        case = dest / row['id']; case.mkdir()
        box = case / 'box'
        result = dict(id=row['id'], expectation=row['expect'], checks={}, error=None)
        try:
            env, _ = prepare(box, row, snapshot, target)
            setup = case / 'stub-preflight'; setup.mkdir()
            preflight(box, env, setup)
            payload = dict(tool_name='Bash', tool_use_id='call-1', cwd=str(box / 'project'), tool_input=dict(command=row['command']))
            if 'turn_id' in row:
                payload['turn_id'] = row['turn_id']
            data = (json.dumps(payload) + '\n').encode()
            (case / 'input.json').write_bytes(data)
            write_json(case / 'environment.json', env)
            before = tree(box / 'project')
            write_json(case / 'project-before.json', before)
            hook = case / 'hook'; hook.mkdir()
            process, stdout, stderr = run([str(core), 'pre'], data, env, box / 'project', hook)
            result['checks'], result['observed'] = inspect(row, box, process, stdout, stderr, before)
        except (ValueError, OSError, KeyError, TypeError) as error:
            result['error'] = repr(error)
        result['failures'] = [name for name, ok in result['checks'].items() if not ok]
        result['status'] = 'collection-error' if result['error'] else 'fail' if result['failures'] else 'unresolved' if row['expect'] == 'unresolved' else 'contract-pass'
        write_json(case / 'tree.json', tree(box) if box.exists() else {})
        write_json(case / 'result.json', result)
        results.append(result)
        print(row['id'] + ': ' + result['status'] + ' ' + ','.join(result['failures']), flush=True)
    summary = dict(rows=results, exact_native_clock_source='unobserved',
                   counts={status: sum(row['status'] == status for row in results) for status in ('contract-pass', 'unresolved', 'fail', 'collection-error')})
    write_json(dest / 'result.json', summary)
    return 2 if summary['counts']['collection-error'] else int(bool(summary['counts']['fail']))


if __name__ == '__main__':
    raise SystemExit(main())
