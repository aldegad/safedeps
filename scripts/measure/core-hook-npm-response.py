#!/usr/bin/env python3
"""Observe which child answered which of the pre hook's first three npm asks,
and judge that link against an expectation written before any run.

  collect          one archive's run, or the launches --only names. The
                   contract, selected by digest, is checked on its own; then a
                   ps host fact, if one is selected by digest; then the
                   product inputs; then each launch, which returns only when
                   its hook returned and its observer ended. Files are written
                   once each: collect.start.json first; collect.done.json and
                   then manifest.json when every launch completed;
                   collect.stopped.json when the collector could not go on
                   (exit 2); collect.pending.json first when an observer
                   outlived its launch's wait, and collect.stopped.json once
                   it ended; collect.refused.json when the contract, the host
                   fact selection or a product input did not hold (exit 1).
                   It judges nothing.
  judge            a completed full collection, selected by its manifest's
                   digest, read against the contract.
  ps-fact          the ps host fact: how this host's ps answers for a pid
                   this process has just reaped, beside a live one.
  check            the contract's reader and adapter controls, with literal
                   inputs and literal expectations.
  check-controls   the contract's copy and sensitivity controls and the
                   driver's J5 cases, from what their runs left and the
                   status their parent saw. It reads files with the standard
                   library and calls none of the readers it checks.

Rows are pass, fail or not-run. A row nobody judged stays not-run, and
not-run is never a pass. A row whose only finding is that something was not
observed stays not-run with that reason; a row with two observed values that
differ fails.

Exit 0: every row passed (collect: completed; ps-fact: written). 1: a row
failed, or an input did not hold. 3: nothing failed and a row was not run
(collect: stopped after the contract, as asked). 2: this runner could not
do its work; what it had done is kept, and what it did not reach is named.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import time
import traceback
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parent))
from core_hook import evidence, observe
from core_hook import npm_response as nr

HERE = Path(__file__).resolve().parent
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


def read_host_fact(path, pin):
    """(record, basis, why) of a selected ps host fact; (None, None, why) when none was selected."""
    if not path:
        return None, None, 'no ps host fact was selected'
    raw = Path(path).read_bytes()
    if nr.sha(raw) != pin:
        raise ValueError('the ps host fact is not the selected one: %s' % nr.sha(raw))
    doc = evidence.strict_load(raw.decode('utf-8'))
    basis, why = nr.host_basis(doc)
    return doc, basis, why


# --- collect --------------------------------------------------------------------------------

def collect(a):
    out = Path(a.out).resolve()
    out.mkdir(parents=True, exist_ok=False)
    state = {'planned': [], 'completed': [], 'current': None}
    try:
        return collect_steps(a, out, state)
    except nr.LifetimePending as lp:
        return pending(out, state, lp)
    except Exception as e:  # The collector could not do its work: not a finding about the hooks.
        traceback.print_exc()
        return stopped(out, state, e)


def stopped(out, state, e, extra=None):
    done = [c['launch'] for c in state['completed']]
    doc = {'format': 'core-hook-npm-response-collect-stopped/1', 'reason': '%s: %s' % (type(e).__name__, e),
           'detail': getattr(e, 'detail', None), 'completed': done, 'current': state['current'],
           'not_started': [n for n in state['planned'] if n not in done and n != state['current']], 't_ns': time.time_ns()}
    doc.update(extra or {})
    try:
        save(out / 'collect.stopped.json', doc)
    except Exception as w:
        print('collect: could not write collect.stopped.json: %s: %s' % (type(w).__name__, w), file=sys.stderr, flush=True)
    print('collect: stopped: %s' % doc['reason'], flush=True)
    return 2


def pending(out, state, lp):
    """An observer outlived its launch's wait. Say so, run nothing more, and
    wait for it to end by itself: no signal is sent. If it never ends, this
    process keeps its lifetime and its final status is not reached."""
    try:
        save(out / 'collect.pending.json', {'format': 'core-hook-npm-response-collect-pending/1', 'launch': lp.name,
                                            'reason': str(lp), 'cause': None if lp.cause is None else repr(lp.cause),
                                            'completed': [c['launch'] for c in state['completed']], 't_ns': time.time_ns()})
    except Exception as w:
        print('collect: could not write collect.pending.json: %s: %s' % (type(w).__name__, w), file=sys.stderr, flush=True)
    print('collect: the observer of %s is still running; waiting for it to end' % lp.name, flush=True)
    lp.watcher.join()
    secondary = None
    try:
        lp.finish()
    except Exception as w:
        secondary = '%s: %s' % (type(w).__name__, w)
    return stopped(out, state, nr.CollectStop('the observer of %s outlived the launch\'s wait and ended later' % lp.name),
                   {'pending': True, 'finish_error': secondary})


def refused(out, why, errors):
    save(out / 'collect.refused.json', {'format': 'core-hook-npm-response-collect-refused/1', 'why': why, 'errors': errors})
    print('collect: refused: %s' % why, flush=True)
    return 1


def collect_steps(a, out, state):
    rec, errors = read_contract(a.contract, a.contract_sha256)
    if errors:
        return refused(out, 'the contract did not hold, so nothing was launched', errors)
    names = nr.launch_names(rec)
    unknown = [n for n in (a.only or []) if n not in names]
    if unknown:
        return refused(out, 'an --only name is no launch of this contract', unknown)
    state['planned'] = [n for n in names if not a.only or n in a.only]
    try:
        host, basis, why = read_host_fact(a.ps_host_fact, a.ps_host_fact_sha256)
    except ValueError as e:
        return refused(out, 'the ps host fact is not the selected one', [str(e)])
    save(out / 'collect.start.json', {
        'format': 'core-hook-npm-response-collect-start/1', 'planned': state['planned'], 'scope': 'all' if not a.only else 'only',
        'contract': {'path': str(Path(a.contract).resolve()), 'selected': a.contract_sha256},
        'ps_host_fact': {'path': a.ps_host_fact, 'selected': a.ps_host_fact_sha256, 'basis': basis, 'why': why},
        'builder': {'root': a.build_root, 'selected': a.build_pin}, 'python': sys.executable, 'collector_pid': os.getpid(),
        'nice': os.nice(0), 'runner': nr.sha(Path(__file__).resolve().read_bytes()),
        'module': nr.sha((HERE / 'core_hook' / 'npm_response.py').read_bytes()), 'collector_sources': evidence.sources(),
        't_ns': time.time_ns()})
    if a.stop_after == 'contract':
        save(out / 'collect.contract-only.json', {'why': 'stopped after the contract, as asked; nothing was launched'})
        print('collect: stopped after the contract, as asked', flush=True)
        return 3
    if not (a.build_root and a.build_pin):
        return refused(out, 'the launches need --build-root and --build-pin', [])
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
        except ValueError as e:  # The selected builder does not hold; any other error is the collector's own.
            errors.append({'field': 'observed builder', 'actual': '%s: %s' % (type(e).__name__, e), 'expected': 'the selected builder, reused'})
    if impl is not None:
        receipt = impl.hooks['pre']['native_receipt']
        from core_hook import native
        native_files = {rel: nr.sha(receipt['files'][rel]) if rel in receipt['files'] else None for rel in rec['sources']['native']['files']}
        for rel, value in native_files.items():
            if value != rec['sources']['native']['files'][rel]:
                errors.append({'field': 'native ' + rel, 'actual': value, 'expected': rec['sources']['native']['files'][rel]})
        if nr.sha(receipt['binary']) != rec['sources']['native']['binary_sha256']:
            errors.append({'field': 'native binary', 'actual': nr.sha(receipt['binary']), 'expected': rec['sources']['native']['binary_sha256']})
        if native.CATALOG['source'] != rec['sources']['native']['commit']:
            errors.append({'field': 'native source commit', 'actual': native.CATALOG['source'], 'expected': rec['sources']['native']['commit']})
    if errors:
        return refused(out, 'a product input is not the one the contract names, so nothing was launched', errors)
    hooks = {'native': impl.hooks['pre'], 'bash': observe.bash_impl('bash', str(tree)).hooks['pre']}
    ctx = SimpleNamespace(sysdirs=observe.system_path(), timeout=60,
                          hook_files={'native': dict(native_files, binary=nr.sha(receipt['binary']), builder=a.build_pin), 'bash': bash_files})
    scenarios = {'%s-%s' % (i, s['name']): (i, s) for i in nr.IMPLS for s in rec['scenarios']}
    base = out / 'launches'
    for name in state['planned']:
        state['current'] = name
        impl_name, scenario = scenarios[name]
        summary = nr.launch(ctx, rec, impl_name, hooks[impl_name], scenario, base, basis)
        state['completed'].append(summary)
        state['current'] = None
        print('launched %s: %s' % (name, summary['status']), flush=True)
    save(out / 'collect.done.json', {'format': 'core-hook-npm-response-collect-done/1', 'completed': state['completed'],
                                     'planned': state['planned'], 'scope': 'all' if not a.only else 'only', 'system_dirs': ctx.sysdirs,
                                     'products': {'bash': bash_files, 'native': native_files}, 't_ns': time.time_ns()})
    listing = nr.tree_listing(str(out))
    manifest = {'format': nr.MANIFEST, 'complete': True, 'scope': 'all' if not a.only else 'only', 'planned': state['planned'],
                'contract_sha256': a.contract_sha256, 'builder_sha256': a.build_pin, 'ps_host_fact_sha256': a.ps_host_fact_sha256,
                'listing': listing}
    pin = save(out / 'manifest.json', manifest)
    print('completed manifest: %s %s' % (out / 'manifest.json', pin), flush=True)
    return 0


# --- rows --------------------------------------------------------------------------------------

class Rows:
    """Every row a run owes. A row is not-run until its own check judges it."""

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


def finish_rows(rows, out, doc, why=''):
    table = list(rows.rows.values())
    for row in table:
        if row['status'] == 'not-run' and row['reason'] == 'not reached':
            row['reason'] = why or 'not reached'
    name = lambda r: '/'.join(str(p) for p in (r['layer'], r['case'], r['side']) if p)
    failed = [name(r) for r in table if r['status'] == 'fail']
    not_run = [name(r) for r in table if r['status'] == 'not-run']
    status = 'fail' if failed or not table else 'incomplete' if not_run else 'pass'
    save(out / 'results.json', dict(doc, rows=table, acceptance={'status': status, 'rows': len(table), 'failed': failed, 'not_run': not_run}))
    for r in table:
        mark = {'pass': 'ok', 'fail': 'not ok', 'not-run': 'not run'}[r['status']]
        print('%s - %s%s' % (mark, name(r), '' if r['status'] == 'pass' else ': ' + r['reason']), flush=True)
    print('%s: %s; rows %d, failed %d, not run %d' % (doc.get('format'), status, len(table), len(failed), len(not_run)), flush=True)
    return EXIT[status]


# --- judge ------------------------------------------------------------------------------------

def layer_of(code):
    base = code[len('follow-'):] if code.startswith('follow-') else code
    head = base.split(':')[0]
    core = head[len('unobserved-'):] if head.startswith('unobserved-') else head
    if core.startswith('request') or core == 'unexpected-call':
        return 'requests'
    if core in ('record', 'record-missing', 'record-duplicate', 'exit-planned'):
        return 'records'
    if core.startswith('process') or core == 'parents-differ':
        return 'process'
    if core in ('exit', 'release', 'observer-exit-unsupported'):
        return 'exit'
    return 'linkage'


def layer_row(rows, layer, name, impl, codes, **more):
    """Defects fail the row; only unobserved codes leave it not-run."""
    defects = [c for c in codes if not nr.unseen(c)]
    missing = [c for c in codes if nr.unseen(c)]
    if defects:
        rows.judge(layer, name, impl, [{'field': 'code', 'actual': c, 'expected': 'none'} for c in defects], unobserved=missing, **more)
    elif missing:
        rows.leave(layer, name, impl, 'unobserved: ' + ', '.join(missing), **more)
    else:
        rows.judge(layer, name, impl, [], **more)


def launch_rows(rows, rec, scenario, impl, view, facts):
    name, expect = scenario['name'], scenario['expect']
    by_layer = {layer: [c for c in facts['codes'] if layer_of(c) == layer] for layer in LAYERS}
    for layer in ('requests', 'records', 'process', 'exit'):
        layer_row(rows, layer, name, impl, by_layer[layer])
    swapped = not scenario.get('swap_slots') or sum(1 for r in view['journal'] if r.get('kind') == 'swap') == 6
    seen = dict(verdict=facts['verdict'], codes=facts['codes'], others=facts['others'], roles=facts['roles'],
                initial_scratch=facts['initial_scratch'],
                claim='which child held which response file and bytes when it was let go; not which bytes the hook read')
    defects = [c for c in by_layer['linkage'] if not nr.unseen(c)]
    missing = [c for c in facts['codes'] if nr.unseen(c)]
    others = [{k: o[k] for k in ('attempt', 'roles', 'status', 'codes')} for o in facts['others']]
    errors = []
    if defects != sorted(expect['codes']):
        errors.append({'field': 'linkage defect codes', 'actual': defects, 'expected': sorted(expect['codes'])})
    if others != expect['others']:
        errors.append({'field': 'groups outside the initial one', 'actual': others, 'expected': expect['others']})
    if not swapped:
        rows.leave('linkage', name, impl, 'unobserved: the slot swap was not made', **seen)
    elif errors:
        rows.judge('linkage', name, impl, errors, **seen)
    elif missing:
        rows.leave('linkage', name, impl, 'unobserved: %s' % ', '.join(missing), **seen)
    else:
        if facts['verdict'] != expect['verdict']:
            errors.append({'field': 'verdict', 'actual': facts['verdict'], 'expected': expect['verdict']})
        rows.judge('linkage', name, impl, errors, **seen)
    if scenario.get('claim_order'):
        status, detail = nr.order_status(scenario, view, facts)
        if status == 'unobserved':
            rows.leave('orders', name, impl, 'unobserved: ' + detail['why'], detail=detail)
        else:
            rows.judge('orders', name, impl, [] if status == 'pass' else [{'field': 'orders', 'actual': detail, 'expected': 'the imposed orders'}],
                       detail=detail, claim='record numbers as claimed; exits as the judge read them; each release after the exit before it')
    result = expect['result']
    hook = dict(facts['hook'], pending_raw=None if facts['hook']['pending_raw'] is None else facts['hook']['pending_raw'].decode('utf-8', 'replace'))
    if not swapped:
        rows.leave('result', name, impl, 'unobserved: the slot swap was not made', hook=hook)
    elif isinstance(result, str):
        rows.judge('result', name, impl, nr.result_errors(rec, result, view, facts), hook=hook)
    else:
        errors, predicted = nr.differs_errors(rec, scenario, view, facts)
        rows.judge('result', name, impl, errors, hook=hook, predicted=predicted,
                   claim='a valid pending record whose role-linked fields differ from the positive; predicted values are reported, not counted')


def relation_rows(rows, rec, impl, observed):
    def layers_of(name):
        scenario = next(s for s in rec['scenarios'] if s['name'] == name)
        return [(layer, name, impl) for layer in list(LAYERS) + (['orders'] if scenario.get('claim_order') else [])]

    def summary(case, names, extra=()):
        keys = [k for n in names for k in layers_of(n)]
        states = [rows.rows[k]['status'] for k in keys]
        if 'not-run' in states and 'fail' not in states:
            return
        errors = [{'field': '/'.join(k[:2]), 'actual': rows.rows[k]['status'], 'expected': 'pass'} for k in keys if rows.rows[k]['status'] != 'pass']
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
    doc = {'format': nr.RESULTS, 'inputs': {'manifest': {'path': str(raw / 'manifest.json'), 'selected': a.manifest_sha256},
                                           'contract': {'path': str(Path(a.contract).resolve()), 'selected': a.contract_sha256},
                                           'ps_host_fact': {'path': a.ps_host_fact, 'selected': a.ps_host_fact_sha256},
                                           'runner': nr.sha(Path(__file__).resolve().read_bytes()),
                                           'module': nr.sha((HERE / 'core_hook' / 'npm_response.py').read_bytes())},
           'stopped': None, 'observed_orders': {impl: {} for impl in nr.IMPLS}, 'not_observed': None,
           'scope': 'one group, the initial attempt and its three roles, with stand-in answers; a follow-up attempt, another group and a '
                    'declared shared effect are reported apart; real npm, exit status values from outside the hook and the bytes the hook '
                    'read are not observed; declared rows are synthetic'}
    try:
        rec, errors = read_contract(a.contract, a.contract_sha256)
        rows.judge('contract', 'record', None, errors)
        if rec is None or errors:
            return finish_rows(rows, out, doc, 'the contract did not hold')
        doc['not_observed'] = rec.get('not_observed')
        for impl in nr.IMPLS:
            for s in rec['scenarios']:
                for layer in LAYERS:
                    rows.owe(layer, s['name'], impl)
                if s.get('claim_order'):
                    rows.owe('orders', s['name'], impl)
            for case in ('permutation-positive', 'actual-swap-negative', 'boundary'):
                rows.owe('relation', case, impl)
            for c in rec['declared']['controls']:
                rows.owe('declared', c['name'], impl)
        errors = []
        manifest_raw = (raw / 'manifest.json').read_bytes() if (raw / 'manifest.json').is_file() else None
        if manifest_raw is None or nr.sha(manifest_raw) != a.manifest_sha256:
            errors.append({'field': 'manifest sha256', 'actual': None if manifest_raw is None else nr.sha(manifest_raw), 'expected': a.manifest_sha256})
            manifest = {}
        else:
            manifest = evidence.strict_load(manifest_raw.decode('utf-8'))
        if manifest.get('format') != nr.MANIFEST or manifest.get('complete') is not True or manifest.get('scope') != 'all':
            errors.append({'field': 'manifest', 'actual': [manifest.get('format'), manifest.get('scope')], 'expected': 'a completed full ' + nr.MANIFEST})
        for key, want in (('contract_sha256', a.contract_sha256), ('ps_host_fact_sha256', a.ps_host_fact_sha256)):
            if manifest.get(key) != want:
                errors.append({'field': 'the collection used this ' + key, 'actual': manifest.get(key), 'expected': want})
        for marker in ('collect.stopped.json', 'collect.pending.json', 'collect.refused.json'):
            if (raw / marker).exists():
                errors.append({'field': 'a collection that ' + marker.split('.')[1], 'actual': marker, 'expected': 'absent'})
        if not (raw / 'collect.done.json').is_file():
            errors.append({'field': 'collect.done.json', 'actual': 'absent', 'expected': 'present'})
        if nr.tree_listing(str(raw), skip={'manifest.json'}) != manifest.get('listing'):
            errors.append({'field': 'the collection is the listed bytes', 'actual': 'differs', 'expected': 'the manifest listing'})
        rows.judge('collection', 'manifest', None, errors,
                   claim='the selected manifest lists exactly these bytes, after a completed collection; not that the collection is right')
        if errors:
            return finish_rows(rows, out, doc, 'the collection is not a completed, selected one')
        host, basis, why = read_host_fact(a.ps_host_fact, a.ps_host_fact_sha256)
        doc['ps_host_basis'] = {'basis': basis, 'why': why}
        views = {}
        for impl in nr.IMPLS:
            for s in rec['scenarios']:
                d = raw / 'launches' / ('%s-%s' % (impl, s['name']))
                view = nr.load_view(d)
                facts = nr.judge_launch(rec, s, view, basis)
                views[(impl, s['name'])] = view
                doc['observed_orders'][impl][s['name']] = {'claim_order': facts['claim_order'], 'completion': facts['completion'],
                                                           'verdict': facts['verdict'], 'codes': facts['codes']}
                facts_doc = dict(facts, hook=dict(facts['hook'], pending_raw=None if facts['hook']['pending_raw'] is None
                                                  else facts['hook']['pending_raw'].decode('utf-8', 'replace')))
                save(out / 'facts' / ('%s-%s.json' % (impl, s['name'])), facts_doc)
                launch_rows(rows, rec, s, impl, view, facts)
            relation_rows(rows, rec, impl, doc['observed_orders'][impl])
            for c in rec['declared']['controls']:
                s = next(x for x in rec['scenarios'] if x['name'] == c['from'])
                base_codes = doc['observed_orders'][impl][c['from']]['codes']
                base_defects = sorted(code for code in base_codes if layer_of(code) == 'linkage' and not nr.unseen(code))
                if 'verdict' in c['expect'] and (any(nr.unseen(code) for code in base_codes) or base_defects != sorted(s['expect']['codes'])):
                    # An edit's verdict means something only beside a base launch that is as its scenario expects.
                    rows.leave('declared', c['name'], impl, 'the base launch %s is not as its scenario expects: %s' % (c['from'], ', '.join(base_codes)),
                               synthetic=True)
                    continue
                try:
                    mutated, effects = nr.mutate(rec, s, views[(impl, c['from'])], basis, c)
                except (KeyError, IndexError, ValueError, nr.HarnessError) as e:
                    rows.leave('declared', c['name'], impl, 'the edit could not be built from %s: %s: %s' % (c['from'], type(e).__name__, e), synthetic=True)
                    continue
                facts = nr.judge_launch(rec, s, mutated, basis, effects)
                exp, errors = c['expect'], []
                if 'verdict' in exp:
                    if facts['verdict'] != exp['verdict']:
                        errors.append({'field': 'verdict', 'actual': facts['verdict'], 'expected': exp['verdict']})
                    if any(m not in facts['codes'] for m in exp['must']):
                        errors.append({'field': 'codes the edit must raise', 'actual': facts['codes'], 'expected': exp['must']})
                    if exp['verdict'] == 'applicable' and facts['codes']:
                        errors.append({'field': 'codes', 'actual': facts['codes'], 'expected': []})
                if 'result' in exp:
                    kind = nr.result_kind(rec, s, mutated, facts)
                    if kind != exp['result']:
                        errors.append({'field': 'result', 'actual': kind, 'expected': exp['result']})
                rows.judge('declared', c['name'], impl, errors, verdict=facts['verdict'], codes=facts['codes'], synthetic=True,
                           claim="an edit of a live launch's records, judged by the same oracle; it tests the oracle")
    except Exception as e:
        traceback.print_exc()
        doc['stopped'] = '%s: %s' % (type(e).__name__, e)
        finish_rows(rows, out, doc, 'this runner stopped before the row was judged: ' + doc['stopped'])
        return 2
    return finish_rows(rows, out, doc)


# --- ps-fact ---------------------------------------------------------------------------------------

def ps_fact(a):
    out = Path(a.out).resolve()
    if out.exists():
        print('ps-fact: %s exists' % out, file=sys.stderr)
        return 2
    try:
        doc = nr.measure_ps_host()
    except Exception:
        traceback.print_exc()
        return 2
    pin = save(out, doc)
    basis, why = nr.host_basis(doc)
    print('ps host fact: %s %s; basis %s' % (out, pin, basis if basis else 'not established: ' + why), flush=True)
    return 0


# --- check: the contract's reader and adapter controls, literal in and literal out -------------------

class ControlOps(nr.FileOps):
    """File operations that answer as a control says: a dev and inode for
    lstat or fstat, or an errno for read."""

    def __init__(self, spec):
        self.spec = spec

    def stat_with(self, st, override):
        if not override:
            return st
        values = list(st)
        values[1], values[2] = override['ino'], override['dev']
        return os.stat_result(values)

    def lstat(self, path):
        return self.stat_with(os.lstat(path), self.spec.get('lstat'))

    def fstat(self, fd):
        return self.stat_with(os.fstat(fd), self.spec.get('fstat'))

    def read(self, fd, n):
        if self.spec.get('read_errno'):
            raise OSError(self.spec['read_errno'], os.strerror(self.spec['read_errno']))
        return os.read(fd, n)


class FailingStore:
    def put(self, data):
        raise nr.StoreError('control: the bytes could not be kept')


def reader_case(case, rec):
    """What the reader under test answers for one literal case."""
    kind = case['reader']
    if kind == 'ps':
        read = nr.read_ps(case['record'], case.get('basis'))
        exit_ = nr.exit_reading(read, case['pid'], case.get('start_lstart'))
        return {'read': read['state'], 'exit': exit_['value']['exit'] if exit_['state'] == 'observed' else 'unavailable'}
    if kind == 'slot':
        blobs = {nr.sha(b.encode('utf-8')): b.encode('utf-8') for b in case.get('blobs', [])}
        seen = nr.slot_reading(case['fact'], blobs)
        return {'lstat': seen['lstat'], 'identity': seen['identity'], 'bytes': seen['bytes'] is not None}
    if kind == 'pending':
        raw = None if case['raw'] is None else case['raw'].encode('utf-8')
        return {'pending': nr.read_pending(raw, rec['pending_shape'], case['fields'])['state']}
    raise nr.HarnessError('unknown reader %r' % kind)


def adapter_case(case, workdir):
    """One slot read with the case's file operations, its record read back as
    plain JSON. Returns the facts the case names, and any exception raised."""
    base = Path(workdir) / case['name']
    base.mkdir()
    path = base / 'slot'
    if case.get('bytes') is not None:
        path.write_bytes(case['bytes'].encode('utf-8'))
    journal = nr.Journal(base / 'journal')
    store = FailingStore() if case.get('store') == 'fails' else nr.Store(base / 'blobs')
    raised = None
    try:
        nr.observe_slot(journal, store, {'child': 'control', 'when': 'written', 'trigger': 'control', 'channel': 'out'}, str(path), ControlOps(case.get('ops', {})))
    except Exception as e:
        raised = type(e).__name__
    records = sorted((base / 'journal').iterdir())
    fact = json.loads(records[0].read_bytes())['fact'] if records else None
    got = {'raised': raised, 'records': len(records)}
    for step in ('lstat', 'fstat', 'read'):
        f = (fact or {}).get(step) or {}
        got[step] = f.get('state')
        value = f.get('value') if isinstance(f.get('value'), dict) else {}
        if step in ('lstat', 'fstat') and f.get('state') == 'observed':
            got[step + '_object'] = [value.get('dev'), value.get('ino')]
        if step == 'read' and f.get('state') == 'unavailable':
            got['read_errno'] = (f.get('why') or {}).get('errno')
    got['blob_kept'] = (base / 'blobs').is_dir() and any((base / 'blobs').iterdir())
    return got


def check(a):
    out = Path(a.out).resolve()
    out.mkdir(parents=True, exist_ok=False)
    rows = Rows()
    doc = {'format': 'core-hook-npm-response-check/1', 'claim': "the readers and the slot adapter against literal cases; the author's own check, not an independent verification"}
    try:
        rec, errors = read_contract(a.contract, a.contract_sha256)
        rows.owe('contract', 'record')
        rows.judge('contract', 'record', None, errors)
        if rec is None or errors:
            return finish_rows(rows, out, doc, 'the contract did not hold')
        cases = rec['controls']
        for c in cases['readers']:
            rows.owe('reader', c['name'])
        for c in cases['adapters']:
            rows.owe('adapter', c['name'])
        for c in cases['readers']:
            got = reader_case(c, rec)
            errors = [{'field': k, 'actual': got.get(k), 'expected': v} for k, v in c['expect'].items() if got.get(k) != v]
            rows.judge('reader', c['name'], None, errors, got=got, layer_of_control=c['layer'])
        with tempfile.TemporaryDirectory(prefix='npmresp-check.') as work:
            for c in cases['adapters']:
                got = adapter_case(c, work)
                errors = [{'field': k, 'actual': got.get(k), 'expected': v} for k, v in c['expect'].items() if got.get(k) != v]
                rows.judge('adapter', c['name'], None, errors, got=got, layer_of_control=c['layer'])
    except Exception as e:
        traceback.print_exc()
        doc['stopped'] = '%s: %s' % (type(e).__name__, e)
        finish_rows(rows, out, doc, 'this runner stopped before the row was judged: ' + doc['stopped'])
        return 2
    return finish_rows(rows, out, doc)


# --- check-controls: what the control runs left, read with the standard library -------------------
#
# Nothing here calls read_ps, slot_reading, read_pending, judge_launch or
# bind_scratch. A child's role is read from its own argv's first word; a ps
# outcome, a record's kind and a file's presence are read as they are.

def jload(path):
    with open(path, 'rb') as f:
        return json.loads(f.read().decode('utf-8', 'surrogateescape'))


def step_rc(runs, step):
    p = Path(runs) / step / 'rc'
    return int(p.read_text().strip()) if p.is_file() else None


def journal_of(launch_dir):
    d = Path(launch_dir) / 'observer'
    return [jload(p) for p in sorted(d.iterdir()) if p.name.endswith('.json')] if d.is_dir() else []


def role_of(launch_dir, nonce):
    p = Path(launch_dir) / 'obs' / (nonce + '.started.json')
    if not p.is_file():
        return None
    argv = jload(p).get('argv') or []
    return argv[0] if argv else None


def j1_checks(out):
    d = Path(out) / 'launches' / 'native-P1-permuted'
    js = journal_of(d)
    polls = [r for r in js if r.get('kind') == 'exit-poll']
    exited = [r for r in js if r.get('kind') == 'exited']
    giveups = [r for r in js if r.get('kind') == 'give-up']
    releases = [r for r in js if r.get('kind') == 'gate' and r.get('what') == 'release']
    zrows = any(re.search(r'^\s*\d+\s+Z\s', (p.get('ps') or {}).get('stdout', ''), re.M) for p in polls)
    checks = {
        'done': (Path(out) / 'collect.done.json').is_file() and (Path(out) / 'manifest.json').is_file(),
        'injected': bool(polls) and all((p.get('ps') or {}).get('outcome') == {'kind': 'signal', 'signal': 9} for p in polls) and zrows,
        'no-exit-from-signal': not exited,
        'gave-up': len(giveups) == 1,
    }
    ok = False
    if len(giveups) == 1:
        t = giveups[0]['t_ns']
        before = [r for r in releases if r['t_ns'] < t]
        ok = len(before) == 1 and role_of(d, before[0].get('child')) == 'root' and all(r['t_ns'] >= t for r in releases if r not in before)
    checks['release-after-give-up'] = ok
    return checks


def j4a_checks(out):
    out = Path(out)
    d = out / 'launches' / 'native-P0-natural'
    js = journal_of(d)
    terminal = js[-1] if js and js[-1].get('kind') == 'terminal' else {}
    stopped_doc = jload(out / 'collect.stopped.json') if (out / 'collect.stopped.json').is_file() else {}
    exc = terminal.get('exception') or {}
    return {
        'stopped': 'J4 control' in json.dumps(stopped_doc.get('detail') or {}) or 'J4 control' in str(stopped_doc.get('reason')),
        'terminal-exception': terminal.get('state') == 'exception' and 'J4 control' in str(exc.get('error'))
                              and any('J4 control' in str(c.get('error')) for c in terminal.get('cleanup_errors') or []),
        'partial-before': any(r.get('kind') in ('start', 'read') and r.get('seq', 0) < terminal.get('seq', -1) for r in js),
        'not-started': not (out / 'launches' / 'native-P1-permuted').exists() and stopped_doc.get('not_started') == ['native-P1-permuted'],
        'no-manifest': not (out / 'manifest.json').exists() and not (out / 'collect.done.json').exists(),
    }


def j4b_checks(out):
    out = Path(out)
    d = out / 'launches' / 'native-P0-natural'
    js = journal_of(d)
    terminal = js[-1] if js and js[-1].get('kind') == 'terminal' else {}
    pend = jload(out / 'collect.pending.json') if (out / 'collect.pending.json').is_file() else {}
    stop = jload(out / 'collect.stopped.json') if (out / 'collect.stopped.json').is_file() else {}
    return {
        'pending': pend.get('launch') == 'native-P0-natural',
        'stopped-after-pending': bool(pend) and stop.get('pending') is True and pend.get('t_ns', 0) < stop.get('t_ns', 0),
        'terminal-after-pending': bool(pend) and terminal.get('state') == 'finished' and terminal.get('t_ns', 0) > pend.get('t_ns', 0),
        'not-started': not (out / 'launches' / 'native-P1-permuted').exists(),
        'no-manifest': not (out / 'manifest.json').exists() and not (out / 'collect.done.json').exists(),
    }


CHECKS = {'J1-acq': j1_checks, 'J4a': j4a_checks, 'J4b': j4b_checks}


def check_controls(a):
    runs, out = Path(a.runs).resolve(), Path(a.out).resolve()
    out.mkdir(parents=True, exist_ok=False)
    rows = Rows()
    doc = {'format': 'core-hook-npm-response-controls/1', 'claim': 'control runs read from their files and their parent-observed status; '
           "the author's own check, not an independent verification"}
    try:
        rec, errors = read_contract(a.contract, a.contract_sha256)
        rows.owe('contract', 'record')
        rows.judge('contract', 'record', None, errors)
        spec_raw = Path(a.control_spec).read_bytes()
        rows.owe('contract', 'control-spec')
        rows.judge('contract', 'control-spec', None, [] if nr.sha(spec_raw) == a.control_spec_sha256 else
                   [{'field': 'control spec sha256', 'actual': nr.sha(spec_raw), 'expected': a.control_spec_sha256}])
        if rec is None or errors or rows.status('contract', 'control-spec') != 'pass':
            return finish_rows(rows, out, doc, 'an input did not hold')
        spec = json.loads(spec_raw.decode('utf-8'))
        controls = rec['controls']
        rows.owe('check', 'literal')
        rows.owe('host', 'ps-fact')
        for c in controls['copies']:
            rows.owe('copy', c['name'])
        for c in controls['sensitivity']:
            rows.owe('sensitivity', c['name'])
        for c in spec['j5']['cases']:
            rows.owe('j5', c['name'])
        for c in spec['j5'].get('sensitivity', []):
            rows.owe('j5-sensitivity', c['name'])
        # The main check run: exit 0 and every row passed.
        rc = step_rc(runs, 'check')
        res = jload(runs / 'check' / 'out' / 'results.json') if (runs / 'check' / 'out' / 'results.json').is_file() else {}
        rows.judge('check', 'literal', None, [] if rc == 0 and (res.get('acceptance') or {}).get('status') == 'pass' else
                   [{'field': 'check', 'actual': [rc, (res.get('acceptance') or {}).get('failed')], 'expected': [0, []]}])
        # The ps host fact, read here on its own terms.
        host_errors, established = host_independent(runs / 'ps-fact' / 'host.json')
        if host_errors:
            rows.judge('host', 'ps-fact', None, host_errors)
        elif not established:
            rows.leave('host', 'ps-fact', None, 'not established: the record does not show an absence form; a missing row stays unobserved')
        else:
            rows.judge('host', 'ps-fact', None, [], established=established)
        for c in controls['copies']:
            rc = step_rc(runs, 'copy-' + c['name'])
            got = CHECKS[c['check']](runs / ('copy-' + c['name']) / 'out')
            errors = [{'field': k, 'actual': v, 'expected': True} for k, v in got.items() if v is not True]
            if rc != c['expect']['rc']:
                errors.insert(0, {'field': 'rc', 'actual': rc, 'expected': c['expect']['rc']})
            rows.judge('copy', c['name'], None, errors, checks=got, rc=rc)
        for c in controls['sensitivity']:
            step = 'sens-' + c['name']
            rc = step_rc(runs, step)
            if c['kind'] == 'check':
                res = jload(runs / step / 'out' / 'results.json') if (runs / step / 'out' / 'results.json').is_file() else {}
                failed = [r['case'] for r in res.get('rows', []) if r.get('status') == 'fail']
                missing = [n for n in c['expect']['failing'] if n not in failed]
                errors = ([] if rc == 1 else [{'field': 'rc', 'actual': rc, 'expected': 1}]) + \
                         ([{'field': 'cases that must fail without the boundary', 'actual': failed, 'expected': c['expect']['failing']}] if missing else [])
                rows.judge('sensitivity', c['name'], None, errors, failed=failed)
            else:
                got = CHECKS[c['check']](runs / step / 'out')
                held = [k for k in c['expect']['failing'] if got.get(k) is True]
                errors = [{'field': 'checks that must fail without the boundary', 'actual': got, 'expected': c['expect']['failing']}] if held else []
                rows.judge('sensitivity', c['name'], None, errors, checks=got, rc=rc)
        for c in spec['j5']['cases'] + spec['j5'].get('sensitivity', []):
            layer = 'j5' if c in spec['j5']['cases'] else 'j5-sensitivity'
            step = 'j5-' + c['name']
            got = j5_facts(runs, step, c)
            exp = c['expect']
            errors = [{'field': k, 'actual': got.get(k), 'expected': v} for k, v in exp.items() if got.get(k) != v]
            if layer == 'j5-sensitivity':
                errors = [] if errors else [{'field': 'the case must fail without the boundary', 'actual': got, 'expected': exp}]
            rows.judge(layer, c['name'], None, errors, got=got)
    except Exception as e:
        traceback.print_exc()
        doc['stopped'] = '%s: %s' % (type(e).__name__, e)
        finish_rows(rows, out, doc, 'this runner stopped before the row was judged: ' + doc['stopped'])
        return 2
    return finish_rows(rows, out, doc)


def j5_facts(runs, step, case):
    """What a J5 driver copy did: the status its parent saw, its driver.json, the steps it ran."""
    base = Path(runs) / 'j5' / case['name']
    dj = base / 'driver.json'
    record = jload(dj) if dj.is_file() else None
    ran = sorted(p.name for p in (base / 'runs').iterdir() if (p / 'rc').is_file()) if (base / 'runs').is_dir() else []
    return {'rc': step_rc(runs, step), 'final': (record or {}).get('final'),
            'stopped_step': ((record or {}).get('stopped') or {}).get('step'),
            'steps': [s.get('step') for s in (record or {}).get('steps', [])],
            'record': 'file' if dj.is_file() else ('directory' if dj.is_dir() else 'absent'), 'ran': ran}


def host_independent(path):
    """The ps host fact read with plain string and JSON reading: (errors, absence rc or None)."""
    if not Path(path).is_file():
        return [{'field': 'ps host fact', 'actual': 'absent', 'expected': 'present'}], None
    doc = jload(path)
    q = doc.get('queries') or {}
    sentinel, first, second = doc.get('sentinel'), doc.get('first'), doc.get('second')

    def pids(name):
        out = q.get(name) or {}
        if (out.get('outcome') or {}).get('kind') != 'exit' or out.get('stderr') != '':
            return None
        return sorted(int(line.split()[0]) for line in (out.get('stdout') or '').splitlines() if line.strip())
    alive, gone, mixed = pids('alive'), pids('gone'), pids('mixed')
    if alive is None or gone is None or mixed is None:
        return [], None
    if not (first in alive and sentinel in alive and gone == [sentinel] and mixed == sorted([sentinel, second])):
        return [], None
    if (q['gone']['outcome'].get('rc')) != (q['mixed']['outcome'].get('rc')):
        return [], None
    if not ((doc.get('first_wait') or {}).get('t_ns', 0) < q['gone'].get('t0_ns', 0)):
        return [], None
    return [], {'absent_rc': q['gone']['outcome'].get('rc')}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='command', required=True)
    c = sub.add_parser('collect')
    c.add_argument('--contract', default=str(HERE / 'core-hook-npm-response.contract.json'))
    c.add_argument('--contract-sha256', required=True, help='external selection: the digest of the reviewed record')
    c.add_argument('--build-root')
    c.add_argument('--build-pin', help='external selection: the observed builder record digest')
    c.add_argument('--ps-host-fact')
    c.add_argument('--ps-host-fact-sha256')
    c.add_argument('--only', action='append', help='a launch name; repeat for more. A collection with --only is not one judge reads')
    c.add_argument('--out', required=True)
    c.add_argument('--stop-after', choices=('contract',))
    j = sub.add_parser('judge')
    j.add_argument('--raw', required=True)
    j.add_argument('--manifest-sha256', required=True, help='external selection: the digest of the completed manifest')
    j.add_argument('--contract', default=str(HERE / 'core-hook-npm-response.contract.json'))
    j.add_argument('--contract-sha256', required=True)
    j.add_argument('--ps-host-fact')
    j.add_argument('--ps-host-fact-sha256')
    j.add_argument('--out', required=True)
    p = sub.add_parser('ps-fact')
    p.add_argument('--out', required=True)
    k = sub.add_parser('check')
    k.add_argument('--contract', default=str(HERE / 'core-hook-npm-response.contract.json'))
    k.add_argument('--contract-sha256', required=True)
    k.add_argument('--out', required=True)
    x = sub.add_parser('check-controls')
    x.add_argument('--runs', required=True)
    x.add_argument('--contract', default=str(HERE / 'core-hook-npm-response.contract.json'))
    x.add_argument('--contract-sha256', required=True)
    x.add_argument('--control-spec', required=True)
    x.add_argument('--control-spec-sha256', required=True)
    x.add_argument('--out', required=True)
    a = ap.parse_args()
    return {'collect': collect, 'judge': judge, 'ps-fact': ps_fact, 'check': check, 'check-controls': check_controls}[a.command](a)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception:  # Whatever stopped the runner is not a judgment.
        traceback.print_exc()
        sys.exit(2)
