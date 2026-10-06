#!/usr/bin/env python3
"""Build pinned observation archives and retain plain/tapped native evidence.

Run on the authorized remote host, inside its queue. The toolchain is supplied
by PATH. --source is an extracted archive of the catalog's exact source SHA.
No checkout source is edited. --out must not exist. Raw bundles replay through
core-hook-differential.py --replay FILE, including all source/tap checks.
"""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parent))
from core_hook import observe, compare, native, evidence
from core_hook.corpus import load_cases


def save(path, doc):
    path.write_text(json.dumps(doc, indent=2, sort_keys=True) + '\n')


def build(source, out, name, tapped, control=None):
    root = out / name
    toolchain = {}
    for tool in ('cargo', 'rustc'):
        executable = str(Path(shutil.which(tool)).resolve())
        toolchain[tool] = {'path': executable, 'sha256': native.sha(Path(executable).read_bytes()),
                           'version': subprocess.check_output([executable, '--version']).decode().strip()}
    shutil.copytree(source, root, ignore=shutil.ignore_patterns('target', '.git', '__pycache__'))
    for filename in native.CATALOG['files']:
        p = root / filename
        p.write_bytes(native.transform(filename, p.read_bytes(), tapped, control))
    actual = {str(p.relative_to(root)): p.read_bytes() for p in (root / 'rust').rglob('*') if p.is_file()}
    why = native.verify_source(actual, tapped, control)
    if why:
        raise ValueError(why)
    target = root / 'rust/target'
    env = dict(os.environ, CARGO_BUILD_JOBS='1', CARGO_TARGET_DIR=str(target))
    argv = ['cargo', 'build', '--manifest-path', str(root / 'rust/Cargo.toml'), '--release', '--locked', '--offline', '-j1']
    with (out / (name + '.build.log')).open('wb') as log:
        rc = subprocess.run(argv, env=env, stdout=log, stderr=subprocess.STDOUT).returncode
    (out / (name + '.build.rc')).write_text(str(rc) + '\n')
    if rc:
        raise ValueError(name + ' build failed')
    core = target / 'release/safedeps-core'
    r = subprocess.run([str(core), 'stamp', '--check'], capture_output=True)
    (out / (name + '.stamp.log')).write_bytes(r.stdout + r.stderr)
    if r.returncode or r.stdout.strip() != b'ok':
        raise ValueError(name + ' stamp check failed')
    impl = observe.core_impl(str(core), str(root))
    receipt = native.source_receipt(root, core, tapped, control)
    for hook in impl.hooks.values():
        hook['native_receipt'] = receipt
    host = subprocess.check_output(['rustc', '-vV']).decode()
    target_name = next(line.split(': ', 1)[1] for line in host.splitlines() if line.startswith('host: '))
    relevant_env = {k: v for k, v in env.items() if k.startswith(('RUST', 'CARGO', 'SAFEDEPS_')) or
                    k in ('PATH', 'SDKROOT', 'MACOSX_DEPLOYMENT_TARGET', 'CC', 'CXX', 'AR')}
    build_doc = {'format': evidence.BUILD, 'argv': argv, 'source': native.CATALOG['source'],
                 'binary_sha256': native.sha(receipt['binary']), 'files': {p: native.sha(v) for p, v in actual.items()},
                 'tapped': tapped, 'control': control, 'catalog_sha256': receipt['catalog_sha256'],
                 'tap_sha256': native.CATALOG['tap_sha256'], 'toolchain': toolchain, 'target': target_name,
                 'env': relevant_env, 'build_rc': rc, 'build_log_sha256': native.sha((out / (name + '.build.log')).read_bytes()),
                 'stamp': {'rc': r.returncode, 'stdout': r.stdout.decode(), 'stderr': r.stderr.decode()}}
    receipt['builder'] = evidence.encoded(build_doc)
    evidence.publish(out / (name + '.build.json'), receipt['builder'])
    # The hook dictionaries hold this receipt object, completed only by the builder.

    return impl


def reuse(builds, out, name, tapped, control=None, expected=None):
    root = builds / name
    core = root / 'rust/target/release/safedeps-core'
    if not expected:
        raise ValueError('reuse requires externally selected builder digest: ' + name)
    receipt = evidence.accepted_build(root, core, builds / (name + '.build.json'), expected)
    if receipt['tapped'] != tapped or receipt.get('control') != control:
        raise ValueError('selected builder has a different observation/control contract')
    r = subprocess.run([str(core), 'stamp', '--check'], capture_output=True)
    if r.returncode or r.stdout.strip() != b'ok':
        raise ValueError('reused build stamp failed: ' + name)
    impl = observe.core_impl(str(core), str(root))
    for hook in impl.hooks.values():
        hook['native_receipt'] = receipt
    save(out / (name + '.reuse.json'), {'root': str(root), 'binary_sha256': native.sha(receipt['binary']),
                                       'tapped': tapped, 'control': control})
    return impl


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--reuse-builds', help='reuse completed named archives with --build-pins')
    ap.add_argument('--build-pins', help='external selection: JSON object of build name to builder digest')
    args = ap.parse_args()
    out, source = Path(args.out).resolve(), Path(args.source).resolve()
    out.mkdir(parents=True, exist_ok=False)
    toolchain = {tool: subprocess.check_output([tool, '--version']).decode().strip() for tool in ('cargo', 'rustc')}
    save(out / 'toolchain.json', toolchain)
    root = Path(__file__).resolve().parents[2]
    cases = load_cases([str(root / 'scripts/measure/core-hook-cases.json')], 4096)
    wanted = ('pre-pip-unpinned', 'post-journal-unfinished', 'npm-install-unapproved-codex')
    cases = [c for c in cases if c['id'] in wanted]
    for case in cases:
        if case['id'] == 'pre-pip-unpinned':
            case['id'] = 'native-pre-pip-codex'
            case['steps'][0]['engine'] = 'codex'
    pins = evidence.strict_load(Path(args.build_pins).read_bytes()) if args.build_pins else {}
    make = (lambda name, tapped, control=None: reuse(Path(args.reuse_builds), out, name, tapped, control, pins.get(name))) if args.reuse_builds else \
           (lambda name, tapped, control=None: build(source, out, name, tapped, control))
    plain = make('plain', False)
    tapped = make('observed', True)
    mutations = {name: make(name, True, name) for name in native.CONTROLS}
    dirs = observe.system_path()
    ctx = SimpleNamespace(work=str(out), ref_root=str(root), sysdirs=dirs,
                          real_date=observe.first_on(dirs, 'date'), timeout=90, lang='C', provider_env={})
    ctx.collection = evidence.Collection(out)
    rows, bundle_index, pending = [], [], []

    def record(name, case, left, right, expected, required=None):
        synthetic = name.startswith('synthetic-') or name in ('missing-event', 'duplicate-event', 'wrong-role', 'source-drift')
        path = out / (name + '.bundle.json')
        document = observe.bundle_doc(case, {'reference': left, 'candidate': right},
                    {'native_source': native.CATALOG['source'], 'experiment': name,
                     'collection_kind': 'synthetic' if synthetic else 'live'})
        digest = observe.write_bundle(str(path), document)
        if not synthetic:
            ctx.collection.bundle_written(path, document)
        pending.append((name, case, path, digest, expected, required, synthetic))
        bundle_index.append({'path': path.name, 'sha256': digest})

    for i, case in enumerate(cases):
        base = out / ('case%d' % i)
        base.mkdir()
        box, seed, obs = (str(base / n) for n in ('box', 'seed', 'observations'))
        error = observe.build_seed(ctx, case, box, seed, obs)
        if error:
            raise ValueError(error)
        run = lambda impl: observe.run_side(ctx, case, box, seed, obs, impl, impl.name)
        first, second, uninstrumented = run(tapped), run(tapped), run(plain)
        repeated_post = case['id'] == 'npm-install-unapproved-codex'
        record(case['id'] + '-observed', case, first, second, 'unresolved' if repeated_post else 'equal')
        record(case['id'] + '-plain-link', case, first, uninstrumented, 'unresolved')
        if case['id'] == 'native-pre-pip-codex':
            for name, impl in mutations.items():
                record(name, case, first, run(impl), 'unresolved' if name.endswith('bypass') else 'different',
                       None if name.endswith('bypass') else 'violation:snapshot-meta-time')
            # Corrupt observation streams only in synthetic copies of captured
            # evidence. These are collector controls, not product executions.
            for name in ('missing-event', 'duplicate-event', 'wrong-role', 'source-drift'):
                changed = copy.deepcopy(second)
                step = changed['steps'][0]
                raw = changed['blobs'].get(step['native_raw'])
                if name == 'source-drift':
                    filename = native.CATALOG['boundary']
                    old = changed['steps'][0]['native']['files'][filename]
                    changed['steps'][0]['native']['files'][filename] = changed['blobs'].put(changed['blobs'].get(old) + b'// drift\n')
                else:
                    if name == 'missing-event': raw = b''
                    elif name == 'duplicate-event': raw += raw
                    else: raw = raw.replace(b'PreSnapshot', b'ProviderCacheExpiry')
                    step['native_raw'] = changed['blobs'].put(raw)
                record(name, case, first, changed, 'unresolved')
            # Independent synthetic subjects and source events: two entries,
            # the first with two integrity aliases, and a distinct naming read.
            # They exercise correspondence, not additional live role coverage.
            fixture = {'id': 'native-synthetic-alias', 'steps': [{'hook': 'post', 'command': 'echo synthetic'}],
                       'native_withheld_groups': {'0': [['token-a', 'token-a-alias'], ['token-b']]}}
            def synthetic(seconds):
                side = copy.deepcopy(second)
                side['boundaries'] = [{'entries': {}, 'walk_errors': []}, {'entries': {}, 'walk_errors': []}]
                step = side['steps'][0]
                step.update(hook='post', stdout=side['blobs'].put(b''), stderr=side['blobs'].put(b''),
                            status='exit 0', npm_calls=[], date_calls=[], incomplete_calls=[])
                step['stdin'] = side['blobs'].put(b'{"tool_use_id":"synthetic"}')
                events = ''.join('wall1\t%d\t%d\t%d\t%s\tafter\t%d\t7\n' %
                    (step['pid'], step['collector_pid'], i, role, sec) for i, (role, sec) in enumerate([
                        ('NpmWithheldEntry', seconds), ('NpmWithheldEntry', seconds+1), ('NpmWithheldName', seconds+2)]))
                step['native_raw'] = side['blobs'].put(events.encode())
                step['t0_ns'], step['t1_ns'] = seconds*10**9, (seconds+3)*10**9
                filename = 'state/npm-withheld/%d-%d-ABCDEF.json' % (seconds+2, step['pid'])
                body = {'token-a': {'at': seconds}, 'token-a-alias': {'at': seconds}, 'token-b': {'at': seconds+1}}
                side['boundaries'][1]['entries'][filename] = {'kind': 'file', 'mode': '0600', 'blob': side['blobs'].put(json.dumps(body).encode())}
                return side, filename, body
            a, _, _ = synthetic(1800000000)
            b, filename, body = synthetic(1800000001)
            record('synthetic-normal-second-boundary', fixture, a, b, 'equal')
            for name in ('alias-swap', 'borrow-name-role', 'duplicate-alias'):
                changed = copy.deepcopy(b)
                data = copy.deepcopy(body)
                if name == 'alias-swap': data['token-a-alias']['at'] += 1
                elif name == 'borrow-name-role': data['token-a']['at'] += 2
                else: data['extra-alias'] = data['token-a']
                changed['boundaries'][1]['entries'][filename]['blob'] = changed['blobs'].put(json.dumps(data).encode())
                record('synthetic-' + name, fixture, a, changed, 'different')
        if repeated_post:
            record('state-and-report-day', case, first, run(mutations['snapshot-day']), 'different', 'violation:snapshot-meta-time')
        observe.rmtree(str(base))
    save(out / 'index.json', {'mode': 'native-evidence', 'bundles': bundle_index, 'skipped': []})
    manifest, pin = ctx.collection.finish()
    print('evidence manifest: %s; sha256: %s' % (manifest, pin), flush=True)
    for name, case, path, digest, expected, required, synthetic in pending:
        doc = observe.read_bundle(str(path))
        evidence.attach(doc, evidence.admit(doc, digest, manifest, pin, synthetic=synthetic))
        result = compare.compare_case(case, doc)
        row = compare.report_row(case['id'], result, str(path), digest)
        replay_doc = observe.read_bundle(str(path))
        evidence.attach(replay_doc, evidence.admit(replay_doc, digest, manifest, pin, synthetic=synthetic))
        replay = compare.report_row(case['id'], compare.compare_case(case, replay_doc))
        same = compare.verdict_digest([row]) == compare.verdict_digest([replay])
        ok = result['verdict'] == expected and same and (required is None or required in compare.red_channels(result))
        rows.append({'name': name, 'expected': expected, 'ok': ok, 'replay_same': same, 'result': row})
        if name.endswith('-plain-link'):
            invariant = not (result['different'] or result['violations']['candidate'] or result['expectations']['candidate'] or
                             [g for g in result['gaps'] if g.get('scope') != 'native-clock'])
            rows[-1].update(nonclock_invariants_match=invariant, ok=ok and invariant)
        print(('ok' if rows[-1]['ok'] else 'not ok') + ' - ' + name + ': ' + result['verdict'], flush=True)
    save(out / 'result.json', {'source': native.CATALOG['source'], 'rows': rows,
         'scope': 'Single-consumer public pre and recovery cases; public pre/post mutation with unresolved post writers; synthetic correspondence controls. Repeated/failed writers, supervised child identities and other roles remain unresolved. Plain exact time is unobserved.'})
    return 0 if all(r['ok'] for r in rows) else 1


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, OSError, observe.HarnessError, subprocess.SubprocessError) as e:
        print('core-hook-native: ' + str(e), file=sys.stderr)
        sys.exit(2)
