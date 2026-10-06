#!/usr/bin/env python3
"""Exercise the generated npm executable and its actual hook consumers.

Run in a new authorized remote archive, with an externally selected observed
builder. No install command is executed. Parallel call claim order is retained;
the replay verdict is reported separately from the fixture's call contract.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parent))
from core_hook import compare, evidence, observe
from core_hook.corpus import load_cases

HERE = Path(__file__).resolve().parent


def save(path, value):
    evidence.publish(path, evidence.encoded(value))


def same(errors, label, actual, expected):
    if actual != expected:
        errors.append({'field': label, 'actual': actual, 'expected': expected})


def direct(out, dirs, name, answer):
    box = out / name
    for part in ('project', 'home', 'calls'):
        (box / part).mkdir(parents=True)
    npm = {'answers': [dict(answer, argv=['prefix'])],
           'default': {'stdout': 'WRONG ANSWER\n', 'exit': 99}}
    observe.write_stub(str(box), npm, str(box / 'calls'))
    argv = [str(box / 'stub/npm'), 'prefix', '--json']
    env = {'PATH': ':'.join(dirs), 'HOME': str(box / 'home'),
           'LANG': 'en_US.UTF-8', 'STANDIN_PROBE': name}
    cwd = str(box / 'project')
    save(box / 'launch.json', {'argv': argv, 'cwd': cwd, 'env': env})
    run = subprocess.run(argv, cwd=cwd, env=env, capture_output=True, timeout=10)
    for ch in ('stdout', 'stderr'):
        evidence.publish(box / ch, getattr(run, ch))
    evidence.publish(box / 'rc', ('%d\n' % run.returncode).encode())
    errors = []
    same(errors, 'executable mode', stat.S_IMODE(Path(argv[0]).stat().st_mode), 0o755)
    same(errors, 'rc', run.returncode, answer.get('exit', 0))
    for ch in ('stdout', 'stderr'):
        same(errors, ch, getattr(run, ch).decode(), answer.get(ch, ''))
    files = list((box / 'calls').glob('*.json'))
    same(errors, 'record files', [p.name for p in files], ['0.json'])
    same(errors, 'partial files', [p.name for p in (box / 'calls').glob('*.part')], [])
    if len(files) == 1:
        record = json.loads(files[0].read_bytes())  # No take_calls in this oracle.
        for key, expected in dict(argv=argv[1:], cwd=cwd, answer=0, exit=answer.get('exit', 0),
                                  stdout=answer.get('stdout', ''), stderr=answer.get('stderr', '')).items():
            same(errors, key, record.get(key), expected)
        for key, value in env.items():
            same(errors, 'env.' + key, record['env'].get(key), value)
        for path in (cwd, env['HOME']):
            st = os.stat(path)
            same(errors, 'paths.' + path, record['paths'].get(path),
                 {'kind': 'dir', 'ino': st.st_ino, 'dev': st.st_dev})
    return {'name': 'direct-' + name, 'ok': not errors, 'errors': errors}


def captured_side(ctx, case, box, seed, obs, impl, side, out):
    """Copy original record bytes before take_calls consumes them.

    This test-only reader leaves the collector and the records untouched.
    The original JSON and the bundle's parsed calls are compared below.
    """
    original = observe.take_calls
    drains = []

    def capture(where, blobs):
        directory = out / ('drain-%d' % len(drains))
        directory.mkdir(parents=True)
        raw = {}
        for p in (Path(where) / 'npm').iterdir():
            evidence.publish(directory / p.name, p.read_bytes())
            if p.suffix == '.json':
                raw[int(p.stem)] = json.loads(p.read_bytes())
        drains.append(raw)
        return original(where, blobs)

    try:
        observe.take_calls = capture
        result = observe.run_side(ctx, case, box, seed, obs, impl, side)
    finally:
        observe.take_calls = original
    return result, drains


def calls_check(case, side, drains):
    errors = []
    step, box = side['steps'][0], side['box']
    calls = step['npm_calls']
    same(errors, 'drains', len(drains), 2)
    same(errors, 'seed calls', drains[0], {})
    same(errors, 'call count', len(calls), 3)
    same(errors, 'incomplete calls', step['incomplete_calls'], [])
    same(errors, 'claim sequence', [r['seq'] for r in calls], [0, 1, 2])
    same(errors, 'hook status', step['status'], 'exit 0')
    # Three concurrently started asks may claim their records in any order.
    # Check each named ask once, and preserve the observed order in the result
    # and in the unmodified canonical comparison. This is not launch order.
    counts = {name: sum(r['argv'][0] == name for r in calls) for name in ('prefix', 'root', 'config')}
    same(errors, 'ask multiplicity', counts, {'prefix': 1, 'root': 1, 'config': 1})
    heads = {'prefix': ['prefix', '--global=false', '--location=project'],
             'root': ['root'], 'config': ['config', 'ls', '--json']}
    answers = observe.fill(case['npm']['answers'], box)
    scratch_facts = []
    for call in calls:
        seq, argv = call['seq'], call['argv']
        record = {k: v for k, v in call.items() if k != 'seq'}
        same(errors, 'raw record %d' % seq, record, drains[-1].get(seq))
        name = argv[0]
        if name not in heads:
            errors.append({'field': 'unexpected ask', 'actual': argv})
            continue
        cache = argv[-1]
        same(errors, 'argv %d' % seq, argv, heads[name] + ['--logs-max=0', '--update-notifier=false', '--cache', cache])
        scratch = Path(cache).parent
        same(errors, 'cache leaf', Path(cache).name, 'cache')
        same(errors, 'scratch parent', str(scratch.parent), box + '/tmp')
        same(errors, 'scratch name', scratch.name.startswith('safedeps-npm-ask.'), True)
        fact = call['paths'].get(str(scratch), {})
        same(errors, 'scratch kind', fact.get('kind'), 'dir')
        same(errors, 'scratch inode present', type(fact.get('ino')) is int and fact['ino'] > 0, True)
        scratch_facts.append((str(scratch), fact))
        which = {'prefix': 0, 'root': 1, 'config': 2}[name]
        for key, expected in dict(cwd=box + '/project', answer=which, stdout=answers[which]['stdout'], stderr='', exit=0).items():
            same(errors, '%d.%s' % (seq, key), call.get(key), expected)
        for key, value in dict(FOO='1', npm_config_registry='https://registry.npmjs.org/',
                              PATH=step['env']['PATH'], HOME=box + '/home', SAFEDEPS_HOME=box + '/state',
                              TMPDIR=box + '/tmp', PWD=box + '/project').items():
            same(errors, '%d.env.%s' % (seq, key), call['env'].get(key), value)
        same(errors, 'NODE_OPTIONS absent', 'NODE_OPTIONS' in call['env'], False)
        same(errors, 'hook npm selected', call['env']['PATH'].split(':')[0], box + '/stub')
        st = os.stat(box + '/project')
        same(errors, 'cwd path fact', call['paths'].get(box + '/project'),
             {'kind': 'dir', 'ino': st.st_ino, 'dev': st.st_dev})
    if scratch_facts:
        same(errors, 'shared scratch', scratch_facts, [scratch_facts[0]] * 3)
    return {'name': side['impl']['name'] + '-' + side['side'] + '-calls', 'ok': not errors,
            'errors': errors, 'claim_order': [c['argv'][0] for c in calls],
            'launch_order': 'not independently observed', 'date_calls': len(step['date_calls'])}


def replay(path, manifest, pin, out):
    doc = observe.read_bundle(str(path))
    admission = evidence.admit(doc, evidence.sha(path.read_bytes()), manifest, pin)
    evidence.attach(doc, admission)
    result = compare.compare_case(doc['case'], doc)
    row = compare.report_row(doc['case']['id'], result)
    save(out / (path.stem + '.in-process.json'), row)
    report = out / (path.stem + '.replay.json')
    argv = [sys.executable, '-I', str(HERE / 'core-hook-differential.py'), '--replay', str(path),
            '--evidence-manifest', str(manifest), '--evidence-sha256', pin, '--report', str(report)]
    save(out / (path.stem + '.argv.json'), argv)
    run = subprocess.run(argv, capture_output=True, timeout=60)
    evidence.publish(out / (path.stem + '.stdout'), run.stdout)
    evidence.publish(out / (path.stem + '.stderr'), run.stderr)
    evidence.publish(out / (path.stem + '.rc'), ('%d\n' % run.returncode).encode())
    replayed = json.loads(report.read_bytes())
    same_verdict = replayed['verdict_sha256'] == compare.verdict_digest([row])
    return {'name': path.stem + '-replay', 'ok': admission['status'] == 'accepted' and same_verdict and
            run.returncode == {'equal': 0, 'different': 1, 'unresolved': 1, 'invalid': 2}[result['verdict']],
            'admission': admission, 'verdict': result['verdict'], 'rc': run.returncode,
            'same_verdict': same_verdict, 'red_channels': compare.red_channels(result),
            'unresolved': len(result['unresolved']), 'expectations': result['expectations']}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--build-root', required=True)
    ap.add_argument('--build-pin', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--skip-bash', action='store_true', help='mutation control needs only the native pair')
    a = ap.parse_args()
    out = Path(a.out).resolve()
    out.mkdir(parents=True, exist_ok=False)
    dirs = observe.system_path()
    rows = [direct(out, dirs, name, answer) for name, answer in (
        ('ordinary', {'stdout': 'ordinary-answer\n', 'stderr': 'ordinary-diagnostic\n'}),
        ('sleep', {'stdout': 'sleep-answer\n', 'stderr': 'sleep-diagnostic\n', 'sleep': 0.05}),
        ('nonzero', {'stdout': 'nonzero-answer\n', 'stderr': 'fixture refusal\n', 'exit': 23}))]
    spec = importlib.util.spec_from_file_location('standin_builder', HERE / 'core-hook-native.py')
    builder = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(builder)
    impl = builder.reuse(Path(a.build_root), out, 'observed', True, expected=a.build_pin)
    save(out / 'builder-selection.json', {'observed': a.build_pin})
    collection = evidence.Collection(out / 'live')
    ctx = SimpleNamespace(work=str(out), ref_root=str(HERE.parents[1]), sysdirs=dirs,
                          real_date=observe.first_on(dirs, 'date'), timeout=90, lang='C', provider_env={}, collection=collection)
    case = next(c for c in load_cases([str(HERE / 'core-hook-cases.json')], 4096) if c['id'] == 'pre-npm-asked-env')
    case['steps'][0]['engine'] = 'codex'
    sandbox = out / 'sandbox'
    sandbox.mkdir()
    box, seed, obs = (str(sandbox / name) for name in ('box', 'seed', 'observations'))
    error = observe.build_seed(ctx, case, box, seed, obs)
    if error:
        raise ValueError(error)
    sides = {}
    for name in ('reference', 'candidate'):
        side, drains = captured_side(ctx, case, box, seed, obs, impl, name, out / ('raw-' + name))
        rows.append(calls_check(case, side, drains))
        sides[name] = side
    paths = []

    def bundle(name, pair):
        doc = observe.bundle_doc(case, pair, {'collection_kind': 'live'})
        path = collection.out / (name + '.bundle.json')
        observe.write_bundle(str(path), doc)
        collection.bundle_written(path, doc)
        paths.append(path)

    bundle('native-pair', sides)
    if not a.skip_bash:
        bash = observe.bash_impl('bash', str(HERE.parents[1]))
        side, drains = captured_side(ctx, case, box, seed, obs, bash, 'reference', out / 'raw-bash')
        rows.append(calls_check(case, side, drains))
        bundle('bash-native', {'reference': side, 'candidate': sides['candidate']})
    manifest, pin = collection.finish()
    save(out / 'consumer-selection.json', {'manifest': str(manifest), 'sha256': pin})
    rows.extend(replay(path, manifest, pin, out) for path in paths)
    save(out / 'results.json', {'rows': rows, 'all_expected': all(r['ok'] for r in rows),
                               'scope': 'stand-in executable/calls and faithful replay, not whole-channel equivalence'})
    for row in rows:
        print(('ok' if row['ok'] else 'not ok') + ' - ' + row['name'], flush=True)
    print('completed manifest: %s %s' % (manifest, pin), flush=True)
    return 0 if all(r['ok'] for r in rows) else 1


if __name__ == '__main__':
    sys.exit(main())
