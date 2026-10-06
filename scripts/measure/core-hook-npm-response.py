#!/usr/bin/env python3
"""Observe which child answered which of the pre hook's first three npm asks,
and judge that link against an expectation written before any run.

  collect   one archive's run. The contract record, selected by digest, is
            checked on its own before anything starts; then the product
            inputs against the contract (the bash hook's files in this tree,
            the observed native build reused from its selected builder);
            then every scenario for the native core and for the bash hook,
            each launch kept whole; then a completed manifest, published last.
            It judges nothing.
  judge     a completed collection, selected by its manifest's digest, read
            against the contract by core_hook.npm_response.judge_launch.

Rows are pass, fail or not-run. A row nobody judged stays not-run, and
not-run is never a pass. A relation row summarises launch rows and is never
judged from anything else. The declared rows are inputs made from a live
launch's records by a named edit; they test the oracle, not the product.

What this does not observe is in the contract's not_observed list, and the
results repeat it. Claim order and completion order are reported as observed;
neither is used to name a role.

Run in a new authorized remote archive with an externally selected observed
builder. No install command is executed and no real npm is started.

Exit 0: every row passed. 1: a row failed. 3: nothing failed and a row was
not run. 2: this runner could not do its work; what it had done is kept.
"""
import argparse
import importlib.util
import os
from pathlib import Path
import sys
import traceback
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parent))
from core_hook import evidence, observe
from core_hook import npm_response as nr

HERE = Path(__file__).resolve().parent
COLLECT = 'core-hook-npm-response-collect/1'
LAYERS = ('requests', 'records', 'process', 'exit', 'linkage', 'result')
EXIT = {'pass': 0, 'fail': 1, 'incomplete': 3}


def save(path, value):
    return evidence.publish(path, evidence.encoded(value))


def read_contract(path, pin):
    raw = Path(path).read_bytes()
    if nr.sha(raw) != pin:
        return None, [{'field': 'record sha256', 'actual': nr.sha(raw), 'expected': pin}]
    try:
        rec = evidence.strict_load(raw.decode('utf-8'))
    except ValueError as e:
        return None, [{'field': 'record', 'actual': str(e), 'expected': 'strict JSON'}]
    if type(rec) is not dict:
        return None, [{'field': 'record', 'actual': type(rec).__name__, 'expected': 'an object'}]
    return rec, nr.contract_errors(rec)


# --- collect --------------------------------------------------------------------------------

def collect(a):
    out = Path(a.out).resolve()
    out.mkdir(parents=True, exist_ok=False)
    report = {'format': COLLECT, 'stop_after': a.stop_after, 'launches': [], 'stopped': None,
              'inputs': {'contract': {'path': str(Path(a.contract).resolve()), 'selected': a.contract_sha256,
                                      'read': nr.sha(Path(a.contract).read_bytes())},
                         'runner': nr.sha(Path(__file__).resolve().read_bytes()),
                         'module': nr.sha((HERE / 'core_hook' / 'npm_response.py').read_bytes()),
                         'collector_sources': evidence.sources(), 'python': sys.executable, 'nice': os.nice(0),
                         'collector_pid': os.getpid(), 'builder': {'root': a.build_root, 'selected': a.build_pin}}}

    def done(status, why=''):
        report['status'], report['why'] = status, why
        save(out / 'collect.json', report)
        print('collect: %s%s' % (status, ': ' + why if why else ''), flush=True)
        return EXIT[status]

    rec, errors = read_contract(a.contract, a.contract_sha256)
    report['contract'] = {'status': 'fail' if errors else 'pass', 'errors': errors}
    if errors:
        return done('fail', 'the contract did not hold, so nothing was launched')
    if a.stop_after == 'contract':
        return done('incomplete', 'stopped after the contract, as asked; nothing was launched')
    if not (a.build_root and a.build_pin):
        return done('fail', 'the launches need --build-root and --build-pin')
    tree = HERE.parents[1]
    errors = []
    bash_files = {rel: nr.sha((tree / rel).read_bytes()) for rel in rec['sources']['bash']['files']}
    for rel, value in bash_files.items():
        if value != rec['sources']['bash']['files'][rel]:
            errors.append({'field': 'bash ' + rel, 'actual': value, 'expected': rec['sources']['bash']['files'][rel]})
    if a.build_pin != rec['sources']['native']['builder_sha256']:
        errors.append({'field': 'builder selection', 'actual': a.build_pin, 'expected': rec['sources']['native']['builder_sha256']})
    native_files, impl = {}, None
    if not errors:
        spec = importlib.util.spec_from_file_location('npm_response_builder', HERE / 'core-hook-native.py')
        builder = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(builder)
        try:
            impl = builder.reuse(Path(a.build_root), out, 'observed', True, expected=a.build_pin)
        except (OSError, ValueError) as e:
            errors.append({'field': 'observed builder', 'actual': '%s: %s' % (type(e).__name__, e), 'expected': 'the selected builder, reused'})
    if impl is not None:
        receipt = impl.hooks['pre']['native_receipt']
        from core_hook import native
        native_files = {rel: nr.sha(receipt['files'][rel]) if rel in receipt['files'] else None
                        for rel in rec['sources']['native']['files']}
        for rel, value in native_files.items():
            if value != rec['sources']['native']['files'][rel]:
                errors.append({'field': 'native ' + rel, 'actual': value, 'expected': rec['sources']['native']['files'][rel]})
        if nr.sha(receipt['binary']) != rec['sources']['native']['binary_sha256']:
            errors.append({'field': 'native binary', 'actual': nr.sha(receipt['binary']), 'expected': rec['sources']['native']['binary_sha256']})
        if native.CATALOG['source'] != rec['sources']['native']['commit']:
            errors.append({'field': 'native source commit', 'actual': native.CATALOG['source'], 'expected': rec['sources']['native']['commit']})
    report['products'] = {'status': 'fail' if errors else 'pass', 'errors': errors, 'bash': bash_files, 'native': native_files}
    if errors:
        return done('fail', 'a product input is not the one the contract names, so nothing was launched')
    hooks = {'native': impl.hooks['pre'], 'bash': observe.bash_impl('bash', str(tree)).hooks['pre']}
    ctx = SimpleNamespace(sysdirs=observe.system_path(), timeout=60,
                          hook_files={'native': dict(native_files, binary=nr.sha(receipt['binary']), builder=a.build_pin),
                                      'bash': bash_files})
    report['system_dirs'] = ctx.sysdirs
    base = out / 'launches'
    try:
        for impl_name in nr.IMPLS:
            for scenario in rec['scenarios']:
                summary = nr.launch(ctx, rec, impl_name, hooks[impl_name], scenario, base)
                report['launches'].append(summary)
                print('launched %s: %s, observer errors %d' % (summary['launch'], summary['status'], summary['observer_errors']), flush=True)
    except Exception as e:
        traceback.print_exc()
        report['stopped'] = '%s: %s' % (type(e).__name__, e)
        return done('fail', 'a launch stopped the collection: ' + report['stopped'])
    report['status'], report['why'] = 'complete', ''
    save(out / 'collect.json', report)
    listing = nr.tree_listing(str(out))
    manifest = {'format': nr.MANIFEST, 'complete': True, 'collect_sha256': nr.sha((out / 'collect.json').read_bytes()),
                'contract_sha256': a.contract_sha256, 'builder_sha256': a.build_pin, 'listing': listing}
    pin = save(out / 'manifest.json', manifest)
    print('completed manifest: %s %s' % (out / 'manifest.json', pin), flush=True)
    return 0


# --- judge ------------------------------------------------------------------------------------

class Rows:
    """Every row this run owes. A row is not-run until its own check judges it."""

    def __init__(self):
        self.rows = {}

    def owe(self, layer, case, side=None):
        self.rows[(layer, case, side)] = {'layer': layer, 'case': case, 'side': side, 'status': 'not-run',
                                          'reason': 'not reached', 'errors': []}

    def judge(self, layer, case, side, errors, **more):
        row = self.rows[(layer, case, side)]
        if row['status'] != 'not-run':
            raise ValueError('row judged twice: %s/%s/%s' % (layer, case, side))
        reason = 'checked'
        if errors:
            first = errors[0]
            reason = '%s: %.240r, expected %.240r' % (first.get('field'), first.get('actual'), first.get('expected'))
            if len(errors) > 1:
                reason += ' (and %d more)' % (len(errors) - 1)
        row.update(more, status='fail' if errors else 'pass', reason=reason, errors=errors)

    def leave(self, layer, case, side, reason, **more):
        """The row stays not-run, with the reason and what was seen."""
        row = self.rows[(layer, case, side)]
        if row['status'] != 'not-run':
            raise ValueError('row judged twice: %s/%s/%s' % (layer, case, side))
        row.update(more, reason=reason)

    def status(self, layer, case, side=None):
        return self.rows[(layer, case, side)]['status']


def layer_of(code):
    base = code[len('follow-'):] if code.startswith('follow-') else code
    head = base.split(':')[0]
    if head.startswith('request-') or head == 'unexpected-call':
        return 'requests'
    if head in ('record', 'record-missing', 'record-duplicate', 'exit-planned'):
        return 'records'
    if head.startswith('process-') or head in ('parents-differ', 'unobserved-process'):
        return 'process'
    if head in ('unobserved-exit', 'unobserved-release'):
        return 'exit'
    return 'linkage'


def launch_rows(rows, rec, scenario, impl, view, facts):
    name, expect = scenario['name'], scenario['expect']
    by_layer = {layer: [c for c in facts['codes'] if layer_of(c) == layer] for layer in LAYERS}
    for layer in ('requests', 'records', 'process', 'exit'):
        errors = [{'field': 'code', 'actual': c, 'expected': 'none'} for c in by_layer[layer]]
        rows.judge(layer, name, impl, errors)
    errors = []
    if by_layer['linkage'] != sorted(expect['codes']):
        errors.append({'field': 'linkage codes', 'actual': by_layer['linkage'], 'expected': sorted(expect['codes'])})
    if facts['verdict'] != expect['verdict']:
        errors.append({'field': 'verdict', 'actual': facts['verdict'], 'expected': expect['verdict']})
    others = [{k: o[k] for k in ('attempt', 'roles', 'status', 'codes')} for o in facts['others']]
    if others != expect['others']:
        errors.append({'field': 'groups outside the initial one', 'actual': others, 'expected': expect['others']})
    seen = dict(verdict=facts['verdict'], codes=facts['codes'], others=facts['others'], roles=facts['roles'],
                initial_scratch=facts['initial_scratch'], observer_errors=view['observer'].get('errors', []),
                claim='which child held which response file and bytes when it was let go; not which bytes the hook read')
    if facts['verdict'] == 'unresolved' and expect['verdict'] != 'unresolved':
        rows.leave('linkage', name, impl, 'unobserved: only what was not observed stands between this launch and its '
                   'expectation: %s' % ', '.join(facts['codes']), **seen)
    else:
        rows.judge('linkage', name, impl, errors, **seen)
    if scenario.get('claim_order'):
        errors = []
        if facts['claim_order'] != scenario['claim_order']:
            errors.append({'field': 'claim order', 'actual': facts['claim_order'], 'expected': scenario['claim_order']})
        want = [[r] for r in scenario['release_order']]
        if facts['completion'] != want:
            errors.append({'field': 'completion order', 'actual': facts['completion'], 'expected': want})
        missed = [e for e in view['observer'].get('errors', [])
                  if e.startswith(('the claim order was not imposed', 'the barrier was not reached', 'no exit seen', 'the child '))]
        seen = dict(claim_order=facts['claim_order'], completion=facts['completion'],
                    claim='observed: record numbers as claimed, exits as ps saw them after each release')
        if missed:
            # The observer could not produce the order; that is not observed, not a failure of the hooks.
            rows.leave('orders', name, impl, 'unobserved: ' + '; '.join(missed), **seen)
        else:
            rows.judge('orders', name, impl, errors, **seen)
    result = expect['result']
    if isinstance(result, str):
        errors = nr.result_errors(rec, result, view, facts)
        rows.judge('result', name, impl, errors, hook=facts['hook'])
    else:
        errors, predicted = nr.differs_errors(rec, scenario, view, facts)
        rows.judge('result', name, impl, errors, hook=facts['hook'], predicted=predicted,
                   claim='the role-linked fields differ from the positive; predicted values are reported, not counted')


def relation_rows(rows, rec, impl, observed):
    def layers_of(name):
        scenario = next(s for s in rec['scenarios'] if s['name'] == name)
        owed = list(LAYERS) + (['orders'] if scenario.get('claim_order') else [])
        return [(layer, name, impl) for layer in owed]

    def summary(case, names, extra=()):
        keys = [k for n in names for k in layers_of(n)]
        states = [rows.rows[k]['status'] for k in keys]
        if 'not-run' in states and 'fail' not in states:
            return
        errors = [{'field': '/'.join(k[:2]), 'actual': rows.rows[k]['status'], 'expected': 'pass'}
                  for k in keys if rows.rows[k]['status'] != 'pass']
        rows.judge('relation', case, impl, errors + list(extra))
    positives = [s['name'] for s in rec['scenarios'] if s['kind'] == 'positive']
    forced = [s['name'] for s in rec['scenarios'] if s['kind'] == 'positive' and s.get('claim_order')]
    extra = []
    if all(n in observed for n in forced):
        claims = [tuple(observed[n]['claim_order']) for n in forced]
        ends = [tuple(tuple(x) for x in observed[n]['completion']) for n in forced]
        if len(set(claims)) != len(claims):
            extra.append({'field': 'observed claim orders differ', 'actual': claims, 'expected': 'all different'})
        if len(set(ends)) != len(ends):
            extra.append({'field': 'observed completion orders differ', 'actual': ends, 'expected': 'all different'})
    summary('permutation-positive', positives, extra)
    summary('actual-swap-negative', [s['name'] for s in rec['scenarios'] if s['kind'] == 'negative'])
    summary('boundary', [s['name'] for s in rec['scenarios'] if s['kind'] == 'boundary'])


def judge(a):
    raw, out = Path(a.raw).resolve(), Path(a.out).resolve()
    out.mkdir(parents=True, exist_ok=False)
    rows = Rows()
    rows.owe('collection', 'manifest')
    rows.owe('contract', 'record')
    scenarios = []
    inputs = {'manifest': {'path': str(raw / 'manifest.json'), 'selected': a.manifest_sha256},
              'contract': {'path': str(Path(a.contract).resolve()), 'selected': a.contract_sha256},
              'runner': nr.sha(Path(__file__).resolve().read_bytes()),
              'module': nr.sha((HERE / 'core_hook' / 'npm_response.py').read_bytes())}
    stopped = []
    observed = {impl: {} for impl in nr.IMPLS}
    rec = None
    try:
        rec, errors = read_contract(a.contract, a.contract_sha256)
        rows.judge('contract', 'record', None, errors)
        if rec is not None and not errors:
            scenarios = rec['scenarios']
            for impl in nr.IMPLS:
                for s in scenarios:
                    for layer in LAYERS:
                        rows.owe(layer, s['name'], impl)
                    if s.get('claim_order'):
                        rows.owe('orders', s['name'], impl)
                for case in ('permutation-positive', 'actual-swap-negative', 'boundary'):
                    rows.owe('relation', case, impl)
                for c in rec['declared']['controls']:
                    rows.owe('declared', c['name'], impl)
        manifest_raw = (raw / 'manifest.json').read_bytes()
        errors = []
        if nr.sha(manifest_raw) != a.manifest_sha256:
            errors.append({'field': 'manifest sha256', 'actual': nr.sha(manifest_raw), 'expected': a.manifest_sha256})
        manifest = evidence.strict_load(manifest_raw.decode('utf-8'))
        if manifest.get('format') != nr.MANIFEST or manifest.get('complete') is not True:
            errors.append({'field': 'manifest', 'actual': manifest.get('format'), 'expected': 'a completed ' + nr.MANIFEST})
        if manifest.get('contract_sha256') != a.contract_sha256:
            errors.append({'field': 'the collection used this contract', 'actual': manifest.get('contract_sha256'), 'expected': a.contract_sha256})
        listing = nr.tree_listing(str(raw), skip={'manifest.json'})
        if listing != manifest.get('listing'):
            errors.append({'field': 'the collection is the listed bytes', 'actual': 'differs', 'expected': 'the manifest listing'})
        rows.judge('collection', 'manifest', None, errors,
                   claim='the files read are the ones the selected manifest lists, byte for byte; not that the collection is right')
        if errors or rec is None or rows.status('contract', 'record') != 'pass':
            return finish(rows, out, inputs, rec, observed, stopped, 'the manifest or the contract did not hold')
        views = {}
        for impl in nr.IMPLS:
            for s in scenarios:
                d = raw / 'launches' / ('%s-%s' % (impl, s['name']))
                if not (d / 'launch.json').is_file():
                    continue
                view = nr.load_view(d)
                facts = nr.judge_launch(rec, s, view)
                views[(impl, s['name'])] = view
                observed[impl][s['name']] = {'claim_order': facts['claim_order'], 'completion': facts['completion'],
                                             'verdict': facts['verdict'], 'codes': facts['codes']}
                save(out / 'facts' / ('%s-%s.json' % (impl, s['name'])), facts)
                launch_rows(rows, rec, s, impl, view, facts)
            relation_rows(rows, rec, impl, observed[impl])
            for c in rec['declared']['controls']:
                base = views.get((impl, c['from']))
                if base is None:
                    continue
                s = next(x for x in scenarios if x['name'] == c['from'])
                try:
                    mutated, effects = nr.mutate(rec, s, base, c)
                except (KeyError, IndexError, nr.HarnessError) as e:
                    rows.leave('declared', c['name'], impl, 'the edit could not be built from %s: %s: %s'
                               % (c['from'], type(e).__name__, e), synthetic=True)
                    continue
                facts = nr.judge_launch(rec, s, mutated, effects)
                errors = []
                if facts['verdict'] != c['expect']['verdict']:
                    errors.append({'field': 'verdict', 'actual': facts['verdict'], 'expected': c['expect']['verdict']})
                missing = [m for m in c['expect']['must'] if m not in facts['codes']]
                if missing:
                    errors.append({'field': 'codes the edit must raise', 'actual': facts['codes'], 'expected': c['expect']['must']})
                if c['expect']['verdict'] == 'applicable' and facts['codes']:
                    errors.append({'field': 'codes', 'actual': facts['codes'], 'expected': []})
                rows.judge('declared', c['name'], impl, errors, verdict=facts['verdict'], codes=facts['codes'],
                           synthetic=True, claim='an edit of a live launch\'s records, judged by the same oracle; it tests the oracle')
    except Exception as e:
        traceback.print_exc()
        stopped.append('%s: %s' % (type(e).__name__, e))
        finish(rows, out, inputs, rec, observed, stopped, 'this runner stopped before the row was judged: ' + stopped[0])
        return 2
    return finish(rows, out, inputs, rec, observed, stopped)


def finish(rows, out, inputs, rec, observed, stopped, why=''):
    table = list(rows.rows.values())
    for row in table:
        if row['status'] == 'not-run' and row['reason'] == 'not reached':
            row['reason'] = why or 'not reached'
    failed = ['/'.join(str(p) for p in (r['layer'], r['case'], r['side']) if p) for r in table if r['status'] == 'fail']
    not_run = ['/'.join(str(p) for p in (r['layer'], r['case'], r['side']) if p) for r in table if r['status'] == 'not-run']
    status = 'fail' if failed or not table else 'incomplete' if not_run else 'pass'
    save(out / 'results.json', {
        'format': nr.RESULTS, 'inputs': inputs, 'rows': table, 'stopped': stopped[0] if stopped else None,
        'observed_orders': observed, 'not_observed': rec.get('not_observed') if isinstance(rec, dict) else None,
        'acceptance': {'status': status, 'rows': len(table), 'failed': failed, 'not_run': not_run},
        'scope': 'one group, the initial attempt and its three roles, with stand-in answers; a follow-up attempt, another '
                 'group and a declared shared effect are reported apart; real npm, exit status values from outside the '
                 'hook and the bytes the hook read are not observed'})
    for r in table:
        mark = {'pass': 'ok', 'fail': 'not ok', 'not-run': 'not run'}[r['status']]
        print('%s - %s%s' % (mark, '/'.join(str(p) for p in (r['layer'], r['case'], r['side']) if p),
                             '' if r['status'] == 'pass' else ': ' + r['reason']), flush=True)
    print('judgment: %s; rows %d, failed %d, not run %d' % (status, len(table), len(failed), len(not_run)), flush=True)
    return EXIT[status]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='command', required=True)
    c = sub.add_parser('collect')
    c.add_argument('--contract', default=str(HERE / 'core-hook-npm-response.contract.json'))
    c.add_argument('--contract-sha256', required=True, help='external selection: the digest of the reviewed record')
    c.add_argument('--build-root')
    c.add_argument('--build-pin', help='external selection: the observed builder record digest')
    c.add_argument('--out', required=True)
    c.add_argument('--stop-after', choices=('contract',))
    j = sub.add_parser('judge')
    j.add_argument('--raw', required=True)
    j.add_argument('--manifest-sha256', required=True, help='external selection: the digest of the completed manifest')
    j.add_argument('--contract', default=str(HERE / 'core-hook-npm-response.contract.json'))
    j.add_argument('--contract-sha256', required=True)
    j.add_argument('--out', required=True)
    a = ap.parse_args()
    return collect(a) if a.command == 'collect' else judge(a)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception:  # Whatever stopped the runner is not a judgment.
        traceback.print_exc()
        sys.exit(2)
