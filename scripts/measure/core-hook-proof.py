#!/usr/bin/env python3
"""Focused proof-boundary controls. Run once in a new authorized remote archive.

No dependency install is executed: the live inputs are hook payloads. Synthetic
consumer controls and storage corruption controls are reported separately from
new live source mutations. --source is the catalog's extracted native source.
"""
import argparse
import base64
import copy
import importlib.util
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parent))
from core_hook import observe, evidence, native
from core_hook.corpus import load_cases

HERE = Path(__file__).resolve().parent
CLI = HERE / 'core-hook-differential.py'
spec = importlib.util.spec_from_file_location('native_builder', HERE / 'core-hook-native.py')
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


def save(path, value):
    evidence.publish(path, evidence.encoded(value))


def raw_receipt_errors(bundle, report):
    """Independent raw regex + source line reader, no slots/Claim/token oracle.

    The synthetic fixture fixes the field sequence to a,a,alias,b. Check the
    actual bytes at each receipt span, and check each status against the event
    selected by that independent fixture sequence. In particular two equal
    paths cannot borrow the first field's check.
    """
    errors = []
    doc = evidence.strict_load(Path(bundle).read_bytes())
    blobs = {k: base64.b64decode(v) for k, v in doc['blobs'].items()}
    row = report['cases'][0]
    for side_name, side in doc['sides'].items():
        entries = side['boundaries'][1]['entries']
        rel, entry = next(iter(entries.items()))
        raw = blobs[entry['blob']]
        source = blobs[side['steps'][0]['native_raw']].decode().splitlines()
        values = [int(line.split('\t')[6]) for line in source if line.split('\t')[4] == 'NpmWithheldEntry']
        fields = list(re.finditer(rb'"at"\s*:\s*([0-9]+)', raw))
        receipts = [r for r in row['receipts'][side_name] if r['slot'] == 'record-time']
        if len(fields) != len(receipts):
            errors.append('receipt count differs from raw fields')
        for i, (field, receipt) in enumerate(zip(fields, receipts)):
            actual = int(field.group(1))
            expected = values[0 if i < 3 else 1]
            if receipt['span'] != list(field.span(1)) or receipt['actual'] != actual or receipt['value'].encode() != field.group(1):
                errors.append('%s:%d receipt does not read its raw scalar' % (side_name, i))
            if receipt['status'] != ('ok' if actual == expected else 'violation'):
                errors.append('%s:%d reused/wrong consumer check' % (side_name, i))
    return errors


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--reuse-builds')
    ap.add_argument('--build-pins')
    ap.add_argument('--boundary-only', action='store_true', help='only the newly changed evidence boundary; reuse prior occurrence/source controls')
    a = ap.parse_args()
    out = Path(a.out).resolve()
    out.mkdir(parents=True, exist_ok=False)
    builds = out / 'builds'
    builds.mkdir()
    names = ('observed', 'plain') if a.boundary_only else ('observed', 'plain', 'snapshot-day', 'snapshot-borrow')
    if a.reuse_builds:
        pins = evidence.strict_load(Path(a.build_pins).read_bytes())
        impls = {name: builder.reuse(Path(a.reuse_builds), builds, name, name != 'plain',
                                   name if name.startswith('snapshot-') else None, pins[name]) for name in names}
    else:
        impls = {name: builder.build(Path(a.source).resolve(), builds, name, name != 'plain',
                                   name if name.startswith('snapshot-') else None) for name in names}
        pins = {name: evidence.sha((builds / (name + '.build.json')).read_bytes()) for name in impls}
    save(out / 'build-selection.json', pins)
    dirs = observe.system_path()
    collection_dir = out / 'live'
    collection = evidence.Collection(collection_dir)
    ctx = SimpleNamespace(work=str(out), ref_root=str(HERE.parents[1]), sysdirs=dirs,
                          real_date=observe.first_on(dirs, 'date'), timeout=90, lang='C', provider_env={}, collection=collection)
    cases = load_cases([str(HERE / 'core-hook-cases.json')], 4096)
    case = copy.deepcopy(next(c for c in cases if c['id'] == 'pre-pip-unpinned'))
    case['id'] = 'proof-pre'
    case['steps'][0].update(engine='codex', command='pip install proof-example-package', id='proof-call')
    work = out / 'sandbox'
    work.mkdir()
    box, seed, obs = (str(work / n) for n in ('box', 'seed', 'observations'))
    error = observe.build_seed(ctx, case, box, seed, obs)
    if error:
        raise ValueError(error)
    first = observe.run_side(ctx, case, box, seed, obs, impls['observed'], 'reference')
    collected = {}
    for name in impls:
        candidate = observe.run_side(ctx, case, box, seed, obs, impls[name], 'candidate')
        doc = observe.bundle_doc(case, {'reference': first, 'candidate': candidate},
                                 {'collection_kind': 'live', 'control': None, 'experiment': name})
        path = collection_dir / (name + '.bundle.json')
        observe.write_bundle(str(path), doc)
        collection.bundle_written(path, doc)
        collected[name] = (path, candidate)
    # Two stages in one side deliberately select different native builds.
    mixed_case = copy.deepcopy(case)
    mixed_case['id'] = 'proof-mixed'
    mixed_case['steps'].append({'hook': 'post', 'command': 'echo proof', 'id': 'proof-post', 'engine': 'codex'})
    mixed_impl = observe.mixed(impls['plain'], impls['observed'], ['pre'])
    left = observe.run_side(ctx, mixed_case, box, seed, obs, mixed_impl, 'reference')
    right = observe.run_side(ctx, mixed_case, box, seed, obs, mixed_impl, 'candidate')
    mixed_doc = observe.bundle_doc(mixed_case, {'reference': left, 'candidate': right}, {'collection_kind': 'live'})
    mixed_path = collection_dir / 'mixed.bundle.json'
    observe.write_bundle(str(mixed_path), mixed_doc)
    collection.bundle_written(mixed_path, mixed_doc)
    manifest, pin = collection.finish()
    save(out / 'consumer-selection.json', {'manifest': str(manifest), 'sha256': pin})
    print('completed manifest: %s %s' % (manifest, pin), flush=True)
    rows = []
    reports = out / 'reports'
    reports.mkdir()

    def cli(name, path, want, rc, kind='storage', manifest_file=manifest, expected_pin=pin, synthetic=False, cli_path=CLI):
        report = reports / (name + '.json')
        argv = [sys.executable, '-I', str(cli_path), '--replay', str(path), '--report', str(report)]
        if manifest_file is not None:
            argv += ['--evidence-manifest', str(manifest_file)]
        if expected_pin is not None:
            argv += ['--evidence-sha256', expected_pin]
        if synthetic:
            argv.append('--synthetic')
        save(reports / (name + '.argv.json'), argv)
        run = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        evidence.publish(reports / (name + '.log'), run.stdout)
        evidence.publish(reports / (name + '.rc'), ('%d\n' % run.returncode).encode())
        result = evidence.strict_load(report.read_bytes()) if report.exists() else None
        got = result['cases'][0]['verdict'] if result else ('invalid' if run.returncode == 2 else None)
        row = {'name': name, 'kind': kind, 'expected': want, 'got': got, 'rc': run.returncode,
               'ok': run.returncode == rc and got == want}
        rows.append(row)
        print(('ok' if row['ok'] else 'not ok') + ' - ' + name + ': ' + str(got), flush=True)
        return result

    baseline = cli('schema-live-baseline' if a.boundary_only else 'live-normal', collected['observed'][0], 'equal', 0, 'live')
    for name in [n for n in impls if n.startswith('snapshot-')]:
        r = cli('live-' + name, collected[name][0], 'different', 1, 'live-source-mutation')
        rows[-1]['ok'] &= bool(r and r['cases'][0]['violations']['candidate'])
    if not a.boundary_only:
        cli('live-plain', collected['plain'][0], 'unresolved', 1, 'live')
        cli('live-mixed-per-step', mixed_path, 'equal', 0, 'live')
        cli('no-pin', collected['observed'][0], 'unresolved', 1, manifest_file=manifest, expected_pin=None)
        cli('missing-manifest', collected['observed'][0], 'unresolved', 1, manifest_file=out / 'absent.json')
        incomplete = evidence.strict_load(manifest.read_bytes()); incomplete['complete'] = False
        incomplete_path = out / 'incomplete.manifest.json'; save(incomplete_path, incomplete)
        cli('incomplete-manifest', collected['observed'][0], 'unresolved', 1,
            manifest_file=incomplete_path, expected_pin=evidence.sha(incomplete_path.read_bytes()))

    original = evidence.strict_load(collected['observed'][0].read_bytes())
    altered = out / 'altered'; altered.mkdir()
    def changed(name, mutate, relation=False, source_doc=original):
        doc = copy.deepcopy(source_doc)
        mutate(doc)
        path = altered / (name + '.bundle.json'); save(path, doc)
        if not a.boundary_only:
            cli(name, path, 'invalid', 2)
        if relation:
            # A deliberately faulty collector record with a freshly selected
            # pin still has to pass the inner build/launch relation checks.
            fresh = copy.deepcopy(evidence.strict_load(manifest.read_bytes()))
            item = copy.deepcopy(next(b for b in fresh['bundles'] if b['sha256'] == evidence.sha(collected['observed'][0].read_bytes())))
            item['sha256'] = evidence.sha(path.read_bytes())
            if name == 'plain-binary-tapped-source':
                item['executions'] = {n: [evidence.execution_record(side, k) for k, step in enumerate(side['steps']) if step['kind'] == 'hook']
                                      for n, side in doc['sides'].items()}
            fresh['bundles'] = [item]
            mp = altered / (name + '.manifest.json'); save(mp, fresh)
            if not a.boundary_only or name == 'plain-binary-tapped-source':
                cli(name + '-fully-bound-relation' if name == 'plain-binary-tapped-source' else name + '-inner-relation',
                    path, 'invalid', 2, manifest_file=mp, expected_pin=evidence.sha(mp.read_bytes()))
        return path

    plain_doc = evidence.strict_load(collected['plain'][0].read_bytes())
    def f2(doc):
        pside = plain_doc['sides']['candidate']
        binary = pside['steps'][0]['native']['binary']
        doc['blobs'][binary] = plain_doc['blobs'][binary]
        doc['sides']['candidate']['steps'][0]['native']['binary'] = binary
    damaged = changed('plain-binary-tapped-source', f2, relation=True)
    def swap_sides(doc):
        ref, cand = doc['sides']['reference']['steps'][0], doc['sides']['candidate']['steps'][0]
        ref['native_raw'], cand['native_raw'] = cand['native_raw'], ref['native_raw']
    changed('same-hash-set-side-stream-swap', swap_sides, relation=True)
    def swap_steps(doc):
        steps = doc['sides']['candidate']['steps']
        steps[0]['stdin'], steps[1]['stdin'] = steps[1]['stdin'], steps[0]['stdin']
    changed('same-hash-set-step-input-swap', swap_steps, source_doc=mixed_doc)
    def swap_run(doc):
        doc['sides']['candidate']['run_id'] = 'other-run'
    changed('run-identity-substitution', swap_run, relation=True)
    def f2_launch(doc):
        doc['sides']['candidate']['steps'][0]['launch']['executable_before']['sha256'] = plain_doc['sides']['candidate']['steps'][0]['native']['binary']
        doc['sides']['candidate']['steps'][0]['launch']['executable_after'] = copy.deepcopy(doc['sides']['candidate']['steps'][0]['launch']['executable_before'])
    changed('launch-artifact-substitution', f2_launch, relation=True)
    def missing_builder(doc):
        del doc['sides']['candidate']['steps'][0]['native']['builder']
    changed('missing-builder', missing_builder)
    if not a.boundary_only:
        self_manifest = evidence.strict_load(manifest.read_bytes())
        self_manifest['bundles'][0]['sha256'] = evidence.sha(damaged.read_bytes())
        mp = altered / 'self-updated.manifest.json'; save(mp, self_manifest)
        cli('self-updated-manifest', damaged, 'invalid', 2, manifest_file=mp)
        # Relocate only saved evidence; no original execution paths are consulted.
        replay_dir = out / 'relocated'; replay_dir.mkdir()
        shutil.copyfile(collected['observed'][0], replay_dir / 'different-name.bundle.json')
        shutil.copyfile(manifest, replay_dir / 'different-name.manifest.json')
        moved = cli('relocated', replay_dir / 'different-name.bundle.json', 'equal', 0,
                    manifest_file=replay_dir / 'different-name.manifest.json')
        rows[-1]['ok'] &= bool(baseline and moved and baseline['verdict_sha256'] == moved['verdict_sha256'])
    # Corrupt metadata cannot enter value comparison, including types that
    # Python's equality would otherwise equate (False == 0).
    bad_type = copy.deepcopy(original)
    bad_type['sides']['candidate']['steps'][0]['env']['LANG'] = ['C']
    bad_path = altered / 'wrong-metadata-type.bundle.json'; save(bad_path, bad_type)
    cli('wrong-metadata-type', bad_path, 'invalid', 2)
    duplicate_path = altered / 'duplicate-metadata.bundle.json'
    raw = collected['observed'][0].read_bytes()
    evidence.publish(duplicate_path, raw.replace(b'{', b'{"format":"duplicate",', 1))
    cli('duplicate-metadata', duplicate_path, 'invalid', 2)
    completion_type = evidence.strict_load(manifest.read_bytes()); completion_type['complete'] = 1
    completion_path = altered / 'completion-type.manifest.json'; save(completion_path, completion_type)
    cli('completion-type', collected['observed'][0], 'invalid', 2,
        manifest_file=completion_path, expected_pin=evidence.sha(completion_path.read_bytes()))

    def incomplete_relation(name, edit):
        doc = copy.deepcopy(original); edit(doc)
        path = altered / (name + '.bundle.json'); save(path, doc)
        m = evidence.strict_load(manifest.read_bytes())
        item = copy.deepcopy(next(b for b in m['bundles'] if b['sha256'] == evidence.sha(collected['observed'][0].read_bytes())))
        item['sha256'] = evidence.sha(path.read_bytes())
        m['bundles'] = [item]
        mp = altered / (name + '.manifest.json'); save(mp, m)
        cli(name, path, 'unresolved', 1, manifest_file=mp, expected_pin=evidence.sha(mp.read_bytes()))
    incomplete_relation('selected-missing-builder', lambda d: d['sides']['candidate']['steps'][0]['native'].pop('builder'))
    incomplete_relation('selected-missing-launch', lambda d: d['sides']['candidate']['steps'][0].pop('launch'))
    historical = copy.deepcopy(original); historical['meta'].pop('collection_kind')
    for side in historical['sides'].values():
        for step in side['steps']:
            step.pop('launch', None)
    historical_path = altered / 'unsealed-historical.bundle.json'; save(historical_path, historical)
    cli('unsealed-historical', historical_path, 'unresolved', 1, manifest_file=None, expected_pin=None)

    # Second prospective run: both stages tapped, and unused retained blobs
    # from the first run. Swaps below preserve the entire blob hash set.
    peer_collection = evidence.Collection(out / 'peer-live')
    ctx.collection = peer_collection
    peer_left = observe.run_side(ctx, mixed_case, box, seed, obs, impls['observed'], 'reference')
    peer_right = observe.run_side(ctx, mixed_case, box, seed, obs, impls['observed'], 'candidate')
    peer_right['blobs'].data.update(first['blobs'].data)
    peer_doc = observe.bundle_doc(mixed_case, {'reference': peer_left, 'candidate': peer_right}, {'collection_kind': 'live'})
    peer_path = peer_collection.out / 'peer.bundle.json'
    observe.write_bundle(str(peer_path), peer_doc); peer_collection.bundle_written(peer_path, peer_doc)
    peer_manifest, peer_pin = peer_collection.finish()
    cli('peer-run-normal', peer_path, 'equal', 0, 'live', manifest_file=peer_manifest, expected_pin=peer_pin)
    for swap in ('run-stream', 'step-stream'):
        doc = copy.deepcopy(peer_doc)
        steps = doc['sides']['candidate']['steps']
        if swap == 'run-stream':
            steps[0]['native_raw'] = first['steps'][0]['native_raw']
        else:
            steps[0]['native_raw'], steps[1]['native_raw'] = steps[1]['native_raw'], steps[0]['native_raw']
        assert set(doc['blobs']) == set(peer_doc['blobs'])
        path = altered / (swap + '.bundle.json'); save(path, doc)
        cli('same-hash-set-' + swap, path, 'invalid', 2, manifest_file=peer_manifest, expected_pin=peer_pin)

    # Restore the old artifact-presence-only acceptance on a private copy.
    # The intentionally synchronized manifest makes the inner relation, not
    # merely a storage hash mismatch, the discriminating check.
    relation_mutant = out / 'artifact-presence-mutant'
    shutil.copytree(HERE, relation_mutant, ignore=shutil.ignore_patterns('__pycache__'))
    module = relation_mutant / 'core_hook/evidence.py'
    source = module.read_text()
    old_check = "                    builder_relation(receipt, side['blobs'])"
    weak_check = "                    side['blobs'].get(receipt['binary'])"
    old_launch = "                    if launch['builder'] != receipt['builder'] or launch['executable_before']['sha256'] != receipt['binary']:"
    assert source.count(old_check) == source.count(old_launch) == 1
    module.write_text(source.replace(old_check, weak_check).replace(old_launch, '                    if False:'))
    mutated_manifest = evidence.strict_load((altered / 'plain-binary-tapped-source.manifest.json').read_bytes())
    mutated_manifest['collector_sources']['core_hook/evidence.py'] = evidence.sha(module.read_bytes())
    mutated_mp = altered / 'artifact-presence-mutant.manifest.json'; save(mutated_mp, mutated_manifest)
    weak_result = cli('artifact-presence-mutant', damaged, 'equal', 0, 'comparator-mutation',
                     manifest_file=mutated_mp, expected_pin=evidence.sha(mutated_mp.read_bytes()), cli_path=relation_mutant / CLI.name)
    candidate = evidence.strict_load(damaged.read_bytes())['sides']['candidate']['steps'][0]['native']
    independent_builder = evidence.strict_load((Path(a.reuse_builds) if a.reuse_builds else builds).joinpath('observed.build.json').read_bytes())
    rows[-1]['independent_builder_mismatch'] = candidate['binary'] != independent_builder['binary_sha256']
    rows[-1]['ok'] &= rows[-1]['independent_builder_mismatch']
    if a.boundary_only:
        save(out / 'results.json', {'rows': rows, 'all_expected': all(r['ok'] for r in rows),
             'scope': 'Changed evidence schema, relation controls and new admitted live captures. Earlier occurrence/source controls retained separately.'})
        return 0 if all(r['ok'] for r in rows) else 1
    # Explicit synthetic fixture owns alias/event mapping and supports duplicates.
    fixture = {'id': 'proof-synthetic', 'steps': [{'hook': 'post', 'command': 'echo synthetic'}],
               'native_withheld_groups': {'0': [['token-a', 'token-a-alias'], ['token-b']]}}
    def synthetic(seconds, corrupt=False):
        side = copy.deepcopy(collected['observed'][1])
        side.update(run_id='synthetic', execution_id='synthetic-%s' % seconds)
        side['boundaries'] = [{'entries': {}, 'walk_errors': []}, {'entries': {}, 'walk_errors': []}]
        step = side['steps'][0]
        step.update(hook='post', stdout=side['blobs'].put(b''), stderr=side['blobs'].put(b''),
                    status='exit 0', npm_calls=[], date_calls=[], incomplete_calls=[])
        step['stdin'] = side['blobs'].put(b'{"tool_use_id":"synthetic"}')
        stream = ''.join('wall1\t%d\t%d\t%d\t%s\tafter\t%d\t7\n' %
            (step['pid'], step['collector_pid'], i, role, sec) for i, (role, sec) in enumerate([
                ('NpmWithheldEntry', seconds), ('NpmWithheldEntry', seconds+1), ('NpmWithheldName', seconds+2)]))
        step['native_raw'] = side['blobs'].put(stream.encode())
        step['t0_ns'], step['t1_ns'] = seconds*10**9, (seconds+3)*10**9
        filename = 'state/npm-withheld/%d-%d-ABCDEF.json' % (seconds+2, step['pid'])
        body = '{"token-a":{"at":%d,"at":%d},"token-a-alias":{"at":%d},"token-b":{"at":%d}}' % (
                seconds, seconds+86400 if corrupt else seconds, seconds, seconds+1)
        side['boundaries'][1]['entries'][filename] = {'kind': 'file', 'mode': '0600', 'blob': side['blobs'].put(body.encode())}
        return side
    fixture_dir = out / 'synthetic'; fixture_dir.mkdir()
    synthetic_paths = {}
    for name, a_seconds, b_seconds, corrupt in [('duplicate-normal', 1800000000, 1800000001, False),
                                               ('duplicate-corrupt', 1800000000, 1800000001, True),
                                               ('different-lengths', 999999999, 1000000000, False)]:
        path = fixture_dir / (name + '.bundle.json')
        doc = observe.bundle_doc(fixture, {'reference': synthetic(a_seconds), 'candidate': synthetic(b_seconds, corrupt)},
                                 {'collection_kind': 'synthetic'})
        observe.write_bundle(str(path), doc)
        report = cli(name, path, 'different' if corrupt else 'equal', 1 if corrupt else 0,
                     'synthetic', manifest_file=None, expected_pin=None, synthetic=True)
        errors = raw_receipt_errors(path, report) if report else ['no report']
        rows[-1].update(raw_receipt_errors=errors, ok=rows[-1]['ok'] and not errors)
        synthetic_paths[name] = path
    cli('synthetic-not-live', synthetic_paths['duplicate-normal'], 'unresolved', 1,
        manifest_file=None, expected_pin=None)
    # Reintroduce F1 in a private comparator copy. The independent raw oracle
    # must reject the result even if the mutated comparator reports equal.
    mutant = out / 'reused-consumer-mutant'
    shutil.copytree(HERE, mutant, ignore=shutil.ignore_patterns('__pycache__'))
    slots_path = mutant / 'core_hook/slots.py'
    slots_text = slots_path.read_text()
    old = 'actual = self.read()\n        if self.claim is not None:'
    new = "actual = next((o.read() for o in self.finder.occ if o.claim is self.claim), self.read())\n        if self.claim is not None:"
    if slots_text.count(old) != 1:
        raise ValueError('consumer mutation anchor drift')
    slots_path.write_text(slots_text.replace(old, new))
    bad_report = cli('reused-consumer-mutant', synthetic_paths['duplicate-corrupt'], 'equal', 0,
                     'comparator-mutation', manifest_file=None, expected_pin=None, synthetic=True,
                     cli_path=mutant / CLI.name)
    errors = raw_receipt_errors(synthetic_paths['duplicate-corrupt'], bad_report) if bad_report else []
    rows[-1].update(raw_receipt_errors=errors, ok=rows[-1]['ok'] and bool(errors))
    save(out / 'results.json', {'rows': rows, 'all_expected': all(r['ok'] for r in rows),
         'scope': 'Focused occurrence, build/launch, completion and replay boundary controls; no full product/platform suite.',
         'unobserved': ['Bash roles', 'plain exact clocks', 'repeated/failed/intermediate writes', 'supervised children', 'all 14 role coverage']})
    return 0 if all(r['ok'] for r in rows) else 1


if __name__ == '__main__':
    sys.exit(main())
