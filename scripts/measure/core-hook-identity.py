#!/usr/bin/env python3
"""Focused launch and retained-occurrence identity control; remote archives only."""
import argparse
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parent))
from core_hook import evidence, native, observe, slots
from core_hook.corpus import load_cases

HERE = Path(__file__).resolve().parent


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def retained_errors(report):
    errors, count = [], 0
    for side_name, receipts in report['cases'][0]['receipts'].items():
        for receipt in receipts:
            if receipt['slot'] == 'snapshot-pid' and receipt['place'].startswith('boundary 2 '):
                count += 1
                if receipt['step'] != 0 or receipt['call'] != 'proof-call':
                    errors.append({'side': side_name, 'place': receipt['place'],
                                   'step': receipt['step'], 'call': receipt['call']})
    return count, errors


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--build-root', required=True)
    ap.add_argument('--build-pins', required=True)
    ap.add_argument('--previous-tree', required=True)
    ap.add_argument('--previous-report', required=True)
    ap.add_argument('--out', required=True)
    a = ap.parse_args()
    out = Path(a.out).resolve(); out.mkdir(parents=True, exist_ok=False)
    builder = module('identity_builder', HERE / 'core-hook-native.py')
    pins = evidence.strict_load(Path(a.build_pins).read_bytes())
    impl = builder.reuse(Path(a.build_root), out, 'observed', True, expected=pins['observed'])
    collection = evidence.Collection(out)
    dirs = observe.system_path()
    ctx = SimpleNamespace(work=str(out), ref_root=str(HERE.parents[1]), sysdirs=dirs,
                          real_date=observe.first_on(dirs, 'date'), timeout=90, lang='C', provider_env={}, collection=collection)
    case = next(c for c in load_cases([str(HERE / 'core-hook-cases.json')], 4096) if c['id'] == 'pre-pip-unpinned')
    case['id'] = 'identity-retained-snapshot'
    case['steps'][0].update(engine='codex', command='pip install proof-example-package', id='proof-call')
    case['steps'].append({'hook': 'post', 'command': 'echo identity', 'id': 'proof-post', 'engine': 'codex'})
    sandbox = out / 'sandbox'; sandbox.mkdir()
    box, seed, obs = (str(sandbox / name) for name in ('box', 'seed', 'observations'))
    error = observe.build_seed(ctx, case, box, seed, obs)
    if error:
        raise ValueError(error)
    sides = {name: observe.run_side(ctx, case, box, seed, obs, impl, name) for name in ('reference', 'candidate')}
    doc = observe.bundle_doc(case, sides, {'collection_kind': 'live'})
    path = out / 'identity.bundle.json'; observe.write_bundle(str(path), doc)
    collection.bundle_written(path, doc)
    manifest, pin = collection.finish()
    evidence.publish(out / 'consumer-selection.json', evidence.encoded({'manifest': str(manifest), 'sha256': pin}))
    argv = [sys.executable, '-I', str(HERE / 'core-hook-differential.py'), '--replay', str(path),
            '--evidence-manifest', str(manifest), '--evidence-sha256', pin, '--report', str(out / 'report.json')]
    evidence.publish(out / 'replay.argv.json', evidence.encoded(argv))
    run = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    evidence.publish(out / 'replay.log', run.stdout)
    evidence.publish(out / 'replay.rc', ('%d\n' % run.returncode).encode())
    report = evidence.strict_load((out / 'report.json').read_bytes())
    count, errors = retained_errors(report)
    previous = evidence.strict_load(Path(a.previous_report).read_bytes())
    old_count, old_errors = retained_errors(previous)
    # Synthetic same-byte stream at two different launch positions. The
    # stream does not supply a new identity just because the bytes are equal.
    synthetic = copy.deepcopy(sides['candidate'])
    synthetic['_evidence'] = evidence.state('accepted', 'explicit identity fixture', 'synthetic')
    synthetic['steps'][1]['native_raw'] = synthetic['steps'][0]['native_raw']
    synthetic['steps'][1]['pid'] = synthetic['steps'][0]['pid']
    side = slots.Side(case, synthetic)
    events0, why0 = native.events(side, 0); events1, why1 = native.events(side, 1)
    old_native = module('core_hook.identity_previous_native', Path(a.previous_tree) / 'scripts/measure/core_hook/native.py')
    old0, oldwhy0 = old_native.events(side, 0); old1, oldwhy1 = old_native.events(side, 1)
    isolated = bool(events0 and events1 and not why0 and not why1 and
                    not ({e['id'] for e in events0} & {e['id'] for e in events1}))
    collision = bool(old0 and old1 and not oldwhy0 and not oldwhy1 and
                     ({e['id'] for e in old0} & {e['id'] for e in old1}))
    rows = [{'name': 'fresh-final-live', 'ok': run.returncode == 0 and report['cases'][0]['verdict'] == 'equal'},
            {'name': 'retained-occurrence-call', 'ok': count > 0 and not errors, 'count': count, 'errors': errors},
            {'name': 'previous-retained-receipt-control', 'ok': old_count > 0 and bool(old_errors),
             'count': old_count, 'errors': old_errors},
            {'name': 'same-stream-distinct-launch', 'ok': isolated, 'synthetic': True},
            {'name': 'previous-launch-id-control', 'ok': collision, 'synthetic': True}]
    evidence.publish(out / 'results.json', evidence.encoded({'rows': rows, 'all_expected': all(r['ok'] for r in rows)}))
    for row in rows:
        print(('ok' if row['ok'] else 'not ok') + ' - ' + row['name'], flush=True)
    print('completed manifest: %s %s' % (manifest, pin), flush=True)
    return 0 if all(r['ok'] for r in rows) else 1


if __name__ == '__main__':
    sys.exit(main())
