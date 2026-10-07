#!/usr/bin/env python3
"""Observe which child answered which of the pre hook's first three npm asks,
and judge that link against an expectation written before any run.

  collect          one archive's run, or the launches --only names. The
                   contract, selected by digest, is checked on its own; then
                   this collection's scope (run, host, boot, user, ps) is
                   read and the selected ps host fact must hold in exactly
                   that scope; then the product inputs; then each launch,
                   which returns only when its hook returned and its observer
                   ended. Files are written once each: collect.start.json
                   first; collect.done.json and then manifest.json when every
                   launch completed; collect.stopped.json when the collector
                   could not go on (exit 2); collect.pending.json first when
                   an observer outlived its launch's wait, and
                   collect.stopped.json once it ended; collect.refused.json
                   when the contract, the scope, the host fact or a product
                   input did not hold (exit 1). It judges nothing.
  judge            a completed full collection, selected by its manifest's
                   digest, read against the contract, with the ps and the
                   host basis of the scope the manifest seals.
  ps-fact          the ps host fact of this scope. Its process starts the
                   holders and owns each one until it is reaped. Files, each
                   written once: ps-fact.start.json; host.json and
                   ps-fact.done.json when the measurement completed (exit 0
                   when the fact holds in its scope, 3 when it does not);
                   on a failure ps-fact.partial.json, then
                   ps-fact.pending.json when a holder is still unreaped after
                   its wait, then, once every holder was reaped with no
                   signal, ps-fact.stopped.json (exit 2).
  check            the contract's literal reader and adapter controls (the
                   adapters run the slot read, the observer's own exit
                   readings and releases, and the judge's exit_fact on
                   literal inputs), every case or those --select names.
  check-controls   one bundle's step and control runs, from what they left
                   and the status their parent saw; for S0 also its flows
                   (scratch runs of the external driver) and the attempts
                   they must have left unchanged. It reads files with the
                   standard library and calls none of the readers it checks.
                   A control passes only when its copy is the declared edit
                   of this tree, it reached what it injects, and what it left
                   is its exact signature, compared as JSON values; a run
                   that left no evidence of reaching it is not demonstrated
                   (not run), never a pass.

Rows are pass, fail or not-run. A row nobody judged stays not-run, and
not-run is never a pass. A row whose only finding is that something was not
observed stays not-run with that reason; a row with two observed values that
differ fails.

Exit 0: every row passed (collect: completed; ps-fact: the fact holds). 1: a
row failed, or an input did not hold. 3: nothing failed and a row was not run
(collect: stopped after the contract, as asked; ps-fact: measured, does not
hold). 2: this runner could not do its work; what it had done is kept, and
what it did not reach is named.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import traceback
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parent))
from core_hook import evidence, observe
from core_hook import npm_response as nr

HERE = Path(__file__).resolve().parent
TREE = HERE.parents[1]
EXIT = {'pass': 0, 'fail': 1, 'incomplete': 3}


def save(path, value):
    return evidence.publish(path, evidence.encoded(value))


def save_quietly(path, value):
    """Publish a record; a record that cannot be written is said on stderr, and nothing else changes."""
    try:
        return save(path, value)
    except Exception as e:
        print('could not write %s: %s: %s' % (path, type(e).__name__, e), file=sys.stderr, flush=True)
        return None


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
    """(record, None) of the selected ps host fact, or (None, why)."""
    try:
        raw = Path(path).read_bytes()
    except OSError as e:
        return None, 'the ps host fact could not be read: %s' % e
    if nr.sha(raw) != pin:
        return None, 'the ps host fact is not the selected one: %s' % nr.sha(raw)
    try:
        return evidence.strict_load(raw.decode('utf-8')), None
    except (ValueError, UnicodeDecodeError) as e:
        return None, 'the ps host fact is not strict JSON: %s' % e


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
    save_quietly(out / 'collect.stopped.json', doc)
    print('collect: stopped: %s' % doc['reason'], flush=True)
    return 2


def pending(out, state, lp):
    """An observer outlived its launch's wait. Say so, run nothing more, and
    wait for it to end by itself: no signal is sent. If it never ends, this
    process keeps its lifetime and its final status is not reached."""
    save_quietly(out / 'collect.pending.json', {'format': 'core-hook-npm-response-collect-pending/1', 'launch': lp.name,
                                                'reason': str(lp), 'cause': None if lp.cause is None else repr(lp.cause),
                                                'completed': [c['launch'] for c in state['completed']], 't_ns': time.time_ns()})
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
    start = {'format': 'core-hook-npm-response-collect-start/2', 'planned': state['planned'], 'scope': 'all' if not a.only else 'only',
             'contract': {'path': str(Path(a.contract).resolve()), 'selected': a.contract_sha256}, 'run_id': a.run_id,
             'builder': {'root': a.build_root, 'selected': a.build_pin}, 'python': sys.executable, 'collector_pid': os.getpid(),
             'nice': os.nice(0), 'runner': nr.sha(Path(__file__).resolve().read_bytes()),
             'module': nr.sha((HERE / 'core_hook' / 'npm_response.py').read_bytes()), 'collector_sources': evidence.sources(),
             't_ns': time.time_ns()}
    if a.stop_after == 'contract':
        save(out / 'collect.start.json', start)
        save(out / 'collect.contract-only.json', {'why': 'stopped after the contract, as asked; nothing was launched and no ps was asked'})
        print('collect: stopped after the contract, as asked', flush=True)
        return 3
    need = [flag for flag, value in (('--run-id', a.run_id), ('--ps-host-fact', a.ps_host_fact), ('--ps-host-fact-sha256', a.ps_host_fact_sha256),
                                     ('--build-root', a.build_root), ('--build-pin', a.build_pin)) if not value]
    if need:
        return refused(out, 'the launches need ' + ', '.join(need), [])
    tool = nr.ps_tool()
    scope, scope_query, why = nr.collection_scope(tool, a.run_id)
    start['ps'] = {'tool': tool, 'scope': scope, 'scope_query': scope_query, 'why': why}
    if scope is None:
        save(out / 'collect.start.json', start)
        return refused(out, 'the scope of this collection was not read, so no host fact can be compared with it', [why])
    host, why = read_host_fact(a.ps_host_fact, a.ps_host_fact_sha256)
    basis = None
    if host is not None:
        basis, why = nr.host_basis(host, scope)
    start['ps'].update(host_fact={'path': a.ps_host_fact, 'selected': a.ps_host_fact_sha256}, basis=basis, basis_why=why)
    save(out / 'collect.start.json', start)
    if basis is None:
        return refused(out, 'the selected ps host fact does not hold for this collection, so a missing row could mean nothing', [why])
    basis = dict(basis, host_fact_sha256=a.ps_host_fact_sha256)
    errors = []
    bash_files = {rel: nr.sha((TREE / rel).read_bytes()) for rel in rec['sources']['bash']['files']}
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
    hooks = {'native': impl.hooks['pre'], 'bash': observe.bash_impl('bash', str(TREE)).hooks['pre']}
    ctx = SimpleNamespace(sysdirs=observe.system_path(), timeout=60,
                          hook_files={'native': dict(native_files, binary=nr.sha(receipt['binary']), builder=a.build_pin), 'bash': bash_files})
    scenarios = {'%s-%s' % (i, s['name']): (i, s) for i in nr.IMPLS for s in rec['scenarios']}
    base = out / 'launches'
    for name in state['planned']:
        state['current'] = name
        impl_name, scenario = scenarios[name]
        summary = nr.launch(ctx, rec, impl_name, hooks[impl_name], scenario, base, tool, scope, basis)
        state['completed'].append(summary)
        state['current'] = None
        print('launched %s: %s' % (name, summary['status']), flush=True)
    save(out / 'collect.done.json', {'format': 'core-hook-npm-response-collect-done/1', 'completed': state['completed'],
                                     'planned': state['planned'], 'scope': 'all' if not a.only else 'only', 'system_dirs': ctx.sysdirs,
                                     'products': {'bash': bash_files, 'native': native_files}, 't_ns': time.time_ns()})
    listing = nr.tree_listing(str(out))
    manifest = {'format': nr.MANIFEST, 'complete': True, 'scope': 'all' if not a.only else 'only', 'planned': state['planned'],
                'contract_sha256': a.contract_sha256, 'builder_sha256': a.build_pin, 'ps_host_fact_sha256': a.ps_host_fact_sha256,
                'run_id': a.run_id, 'ps_scope': scope, 'listing': listing}
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
        if row['status'] != 'not-run' or row['reason'] != 'not reached':
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
        if row['status'] != 'not-run' or row['reason'] != 'not reached':
            raise ValueError('row judged twice: %s/%s/%s' % (layer, case, side))
        row.update(more, reason=reason)

    def record(self, layer, case, side, decision, **more):
        """A decision the module made: recorded as it is."""
        if decision['status'] == 'not-run':
            self.leave(layer, case, side, decision['reason'], **dict(more, decision=decision))
        else:
            self.judge(layer, case, side, decision['errors'], **dict(more, decision=decision))

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

def scenario_layers(s):
    return list(nr.LAYERS) + (['intervention'] if s.get('intervention') else []) + (['orders'] if s.get('claim_order') else [])


def launch_rows(rows, rec, scenario, impl, view, facts):
    name = scenario['name']
    by_layer = {layer: [c for c in facts['codes'] if nr.code_layer(c) == layer] for layer in nr.LAYERS}
    for layer in ('requests', 'records', 'process', 'exit'):
        defects = [c for c in by_layer[layer] if not nr.unseen(c)]
        missing = [c for c in by_layer[layer] if nr.unseen(c)]
        if defects:
            rows.judge(layer, name, impl, [{'field': 'code', 'actual': c, 'expected': 'none'} for c in defects], unobserved=missing)
        elif missing:
            rows.leave(layer, name, impl, 'unobserved: ' + ', '.join(missing))
        else:
            rows.judge(layer, name, impl, [])
    seen = dict(verdict=facts['verdict'], codes=facts['codes'], others=facts['others'], roles=facts['roles'],
                initial_scratch=facts['initial_scratch'], intervention=facts['intervention'],
                claim='which child held which response file and bytes when it was let go; not which bytes the hook read')
    decided = nr.scenario_rows(scenario, facts)
    rows.record('linkage', name, impl, decided['linkage'], **seen)
    if decided['intervention'] is not None:
        rows.record('intervention', name, impl, decided['intervention'])
    if scenario.get('claim_order'):
        status, detail = nr.order_status(scenario, view, facts)
        if status == 'unobserved':
            rows.leave('orders', name, impl, 'unobserved: ' + detail['why'], detail=detail)
        else:
            rows.judge('orders', name, impl, [] if status == 'pass' else [{'field': 'orders', 'actual': detail, 'expected': 'the imposed orders'}],
                       detail=detail, claim='record numbers as claimed; exits as the judge read them; each release after the exit before it')
    result = scenario['expect']['result']
    hook = dict(facts['hook'], pending_raw=None if facts['hook']['pending_raw'] is None else facts['hook']['pending_raw'].decode('utf-8', 'replace'))
    if not decided['result_premise']['held']:
        rows.leave('result', name, impl, 'the result depends on a premise that did not hold: ' + decided['result_premise']['why'], hook=hook)
    elif isinstance(result, str):
        rows.judge('result', name, impl, nr.result_errors(rec, result, view, facts), hook=hook)
    else:
        errors, predicted = nr.differs_errors(rec, scenario, view, facts)
        rows.judge('result', name, impl, errors, hook=hook, predicted=predicted,
                   claim='a valid pending record whose role-linked fields differ from the positive; predicted values are reported, not counted')


def relation_rows(rows, rec, impl, observed):
    def keys_of(name):
        scenario = next(s for s in rec['scenarios'] if s['name'] == name)
        return [(layer, name, impl) for layer in scenario_layers(scenario)]

    def summary(case, names, extra=()):
        keys = [k for n in names for k in keys_of(n)]
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
    rows.owe('collection', 'host-fact')
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
                for layer in scenario_layers(s):
                    rows.owe(layer, s['name'], impl)
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
        # The ps and the host basis are the sealed scope's, never this machine's.
        scope = manifest.get('ps_scope')
        host, why = read_host_fact(a.ps_host_fact, a.ps_host_fact_sha256)
        basis = None
        if host is not None:
            basis, why = nr.host_basis(host, scope)
        doc['ps_host_basis'] = {'absent_rc': (basis or {}).get('absent_rc'), 'why': why}
        rows.judge('collection', 'host-fact', None, [] if basis else [{'field': 'the host fact in the sealed scope', 'actual': why, 'expected': 'holds'}],
                   claim='the selected host fact holds in the scope the manifest seals')
        if basis is None:
            return finish_rows(rows, out, doc, 'the host fact does not hold in the sealed scope')
        basis = dict(basis, host_fact_sha256=a.ps_host_fact_sha256)
        tool = scope['ps']
        views, judged = {}, {}
        for impl in nr.IMPLS:
            for s in rec['scenarios']:
                d = raw / 'launches' / ('%s-%s' % (impl, s['name']))
                view = nr.load_view(d)
                facts = nr.judge_launch(rec, s, view, tool, basis)
                views[(impl, s['name'])] = view
                judged[(impl, s['name'])] = facts
                doc['observed_orders'][impl][s['name']] = {'claim_order': facts['claim_order'], 'completion': facts['completion'],
                                                           'verdict': facts['verdict'], 'codes': facts['codes'],
                                                           'intervention': facts['intervention']}
                facts_doc = dict(facts, hook=dict(facts['hook'], pending_raw=None if facts['hook']['pending_raw'] is None
                                                  else facts['hook']['pending_raw'].decode('utf-8', 'replace')))
                save(out / 'facts' / ('%s-%s.json' % (impl, s['name'])), facts_doc)
                launch_rows(rows, rec, s, impl, view, facts)
            relation_rows(rows, rec, impl, doc['observed_orders'][impl])
            for c in rec['declared']['controls']:
                s = next(x for x in rec['scenarios'] if x['name'] == c['from'])
                base = judged[(impl, c['from'])]
                base_defects = sorted(code for code in base['codes'] if nr.code_layer(code) == 'linkage' and not nr.unseen(code))
                expected = sorted(s['expect']['codes'] + s['expect'].get('intervention_codes', []))
                if 'verdict' in c['expect'] and (any(nr.unseen(code) for code in base['codes']) or base_defects != expected):
                    # An edit's verdict means something only beside a base launch that is as its scenario expects.
                    rows.leave('declared', c['name'], impl, 'the base launch %s is not as its scenario expects: %s' % (c['from'], ', '.join(base['codes'])),
                               synthetic=True)
                    continue
                if 'result' in c['expect'] and s.get('intervention') and base['intervention']['state'] != 'made':
                    rows.leave('declared', c['name'], impl, 'the base launch %s did not make its intervention: %s' % (c['from'], base['intervention']['why']),
                               synthetic=True)
                    continue
                try:
                    mutated, effects = nr.mutate(rec, s, views[(impl, c['from'])], tool, basis, c)
                except (KeyError, IndexError, ValueError, nr.HarnessError) as e:
                    rows.leave('declared', c['name'], impl, 'the edit could not be built from %s: %s: %s' % (c['from'], type(e).__name__, e), synthetic=True)
                    continue
                facts = nr.judge_launch(rec, s, mutated, tool, basis, effects)
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
    out.mkdir(parents=True, exist_ok=False)
    tool = nr.ps_tool()
    scope, query, why = nr.collection_scope(tool, a.run_id)
    save(out / 'ps-fact.start.json', {'format': 'core-hook-npm-response-ps-fact-start/1', 'run_id': a.run_id, 'tool': tool, 'scope': scope,
                                      'scope_query': query, 'why': why, 'pid': os.getpid(), 'python': sys.executable,
                                      'holder': nr.holder_fixture(), 'holder_wait_seconds': nr.HOLDER_WAIT, 't_ns': time.time_ns()})
    if scope is None:
        save(out / 'ps-fact.done.json', {'format': 'core-hook-npm-response-ps-fact-done/1', 'host_sha256': None, 'basis': None,
                                         'why': why, 't_ns': time.time_ns()})
        print('ps-fact: the scope was not read: %s' % why, flush=True)
        return 3
    parent = nr.HolderParent(out)
    try:
        doc = nr.measure_ps_host(parent, tool, scope)
    except Exception as e:
        return ps_fact_stopped(out, parent, e)
    pin = save(out / 'host.json', doc)
    basis, why = nr.host_basis(doc, scope)
    save(out / 'ps-fact.done.json', {'format': 'core-hook-npm-response-ps-fact-done/1', 'host_sha256': pin,
                                     'basis': None if basis is None else {'absent_rc': basis['absent_rc']}, 'why': why, 't_ns': time.time_ns()})
    print('ps host fact: %s %s; %s' % (out / 'host.json', pin, 'holds, absent rc %d' % basis['absent_rc'] if basis else 'does not hold: ' + why), flush=True)
    return 0 if basis else 3


def ps_fact_stopped(out, parent, e):
    """The measurement failed. Publish the original failure first, then clean
    up within the holders' wait and keep that cleanup's errors apart; a holder
    still unreaped makes a pending record, and this process then waits for it
    with no bound and no signal. The stopped record comes after every holder
    was reaped; if one never ends, it never comes."""
    original = {'type': type(e).__name__, 'error': str(e), 'traceback': traceback.format_exc()}
    pids = {n: p.pid for n, p in parent.handles.items()}
    save_quietly(out / 'ps-fact.partial.json', {'format': 'core-hook-npm-response-ps-fact-partial/1', 'original': original,
                                                'started': pids, 'reaped': dict(parent.reaped), 't_ns': time.time_ns()})
    cleanup = parent.cleanup(nr.HOLDER_WAIT)
    unreaped, reap_errors = parent.unreaped(), []
    if unreaped:
        save_quietly(out / 'ps-fact.pending.json', {'format': 'core-hook-npm-response-ps-fact-pending/1', 'unreaped': unreaped,
                                                    'pids': {n: pids[n] for n in unreaped}, 'cleanup_errors': cleanup, 't_ns': time.time_ns()})
        print('ps-fact: waiting with no signal for %s' % ', '.join(unreaped), flush=True)
        reap_errors = parent.reap()
    save_quietly(out / 'ps-fact.stopped.json', {'format': 'core-hook-npm-response-ps-fact-stopped/1', 'original': original,
                                                'cleanup_errors': cleanup, 'pending': bool(unreaped), 'reap_errors': reap_errors,
                                                'reaped': dict(parent.reaped), 'unreaped': parent.unreaped(), 't_ns': time.time_ns()})
    print('ps-fact: stopped: %s: %s' % (original['type'], original['error']), flush=True)
    return 2


# --- check: the contract's literal reader and adapter controls -------------------------------------

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
        answer = nr.read_ps(case['record'], case['tool'], case.get('basis'))
        exit_ = nr.target_exit(answer, case['pid'], case.get('start'))
        return {'read': answer['state'], 'exit': exit_['value']['exit'] if exit_['state'] == 'observed' else 'unavailable'}
    if kind == 'slot':
        blobs = {nr.sha(b.encode('utf-8')): b.encode('utf-8') for b in case.get('blobs', [])}
        seen = nr.slot_reading(case['fact'], blobs)
        return {'lstat': seen['lstat'], 'identity': seen['identity'], 'bytes': seen['bytes'] is not None}
    if kind == 'pending':
        raw = None if case['raw'] is None else case['raw'].encode('utf-8')
        return {'pending': nr.read_pending(raw, rec['pending_shape'], case['fields'])['state']}
    if kind == 'host':
        basis, _ = nr.host_basis(case['doc'], case['scope'])
        return {'basis': 'established' if basis else 'none', 'absent_rc': basis['absent_rc'] if basis else None}
    if kind == 'n3':
        scenario = next(s for s in rec['scenarios'] if s['name'] == case['scenario'])
        out = nr.scenario_rows(scenario, case['facts'])
        return {'linkage': out['linkage']['status'], 'intervention': out['intervention']['status'] if out['intervention'] else None,
                'result_premise': out['result_premise']['held']}
    raise nr.HarnessError('unknown reader %r' % kind)


class LiteralObserver(nr.Observer):
    """An observer whose ps answers are a case's literal records, in order,
    and whose response-file reads are journal notes only. Everything else is
    the observer under test."""

    def __init__(self, rec, case, work):
        work = Path(work)
        for d in ('obs', 'calls'):
            (work / d).mkdir()
        scenario = {'name': 'adapter', 'claim_order': None, 'barrier': case['mode'] == 'barrier',
                    'release_order': case.get('release_order'), 'swap_slots': None}
        super().__init__(rec, scenario, 'native', [], str(work / 'obs'), str(work / 'calls'), nr.Journal(work / 'journal'),
                         nr.Store(work / 'blobs'), case['tool'], case['scope'], case.get('basis'))
        self.answers = list(case['answers'])

    def ask(self, purpose, fields, targets):
        if not self.answers:
            raise nr.HarnessError('the case has no answer left for a %s query' % purpose)
        a = self.answers.pop(0)
        pids = None if targets is None else [self.sentinel] + list(targets)
        now = time.time_ns()
        return {'format': nr.PSQ, 'purpose': purpose, 'argv': nr.ps_argv(self.tool, fields, pids), 'fields': list(fields),
                'sentinel': self.sentinel, 'targets': None if targets is None else list(targets), 'locale': 'C', 'timeout': 1.0,
                't0_ns': now, 't1_ns': now, 'outcome': {'kind': 'exit', 'rc': a['rc']},
                'stdout': a['stdout'].replace('@SENTINEL@', str(self.sentinel)), 'stderr': ''}

    def read_slots(self, child, when, trigger):
        self.journal.write('read-note', {'child': child['nonce'], 'when': when, 'trigger': trigger})


def observer_case(case, rec, workdir):
    """The observer's exit readings and releases from literal ps answers: its
    journal read back as plain JSON."""
    base = Path(workdir) / case['name']
    base.mkdir()
    obs = LiteralObserver(rec, case, base)
    roles = {}
    for c in case['children']:
        nonce = 'n-' + c['role']
        roles[nonce] = c['role']
        obs.children[nonce] = {'nonce': nonce, 'pid': c['pid'], 'ask': {'attempt': 'initial', 'role': c['role']}, 'scratch': '/scratch',
                               'start': c['start'], 'slot_paths': None, 'written': True, 'released': c['released'],
                               'exited': False, 'exited_seq': None}
    raised = None
    try:
        if case['mode'] == 'poll':
            obs.poll_exits()
        else:
            obs.order_until = time.monotonic() + case['budget']
            obs.barrier()
    except Exception as e:
        raised = type(e).__name__
    recs = [json.loads(p.read_bytes()) for p in sorted((base / 'journal').iterdir()) if p.name.endswith('.json')]
    by_seq = {r.get('seq'): r for r in recs}
    readings = []
    for r in recs:
        if r.get('kind') == 'exit-poll':
            for nonce in sorted(r.get('readings') or {}):
                v = r['readings'][nonce]
                readings.append('observed:%s' % v['value']['exit'] if v.get('state') == 'observed' else 'unavailable:%s' % v.get('op'))
    releases, pointers, previous = [], [], None
    for r in recs:
        if r.get('kind') != 'gate' or r.get('what') != 'release':
            continue
        basis = 'after-exit' if r.get('after_exit') is not None else 'after-give-up' if r.get('after_give_up') is not None else 'none'
        releases.append([roles.get(r.get('child')), r.get('why'), basis])
        if r.get('after_exit') is not None:
            target = by_seq.get(r['after_exit']) or {}
            pointers.append(target.get('kind') == 'exited' and target.get('child') == previous)
        if r.get('why') == 'the imposed completion order':
            previous = r.get('child')
    return {'exited': [roles.get(r.get('child')) for r in recs if r.get('kind') == 'exited'], 'readings': readings,
            'releases': releases, 'give-ups': sum(1 for r in recs if r.get('kind') == 'give-up'),
            'exit-pointers': all(pointers) if pointers else None, 'raised': raised}


def exit_fact_case(case):
    """The judge's exit reading of one child from literal journal records."""
    idx = {'start': {'n': case['start_record']} if case.get('start_record') else {}, 'polls': case['polls']}
    child = {'nonce': 'n', 'docs': {'started': {'pid': case['pid']}}}
    seen, _, binding = nr.exit_fact(idx, child, case['tool'], case.get('basis'))
    return {'exit': seen['how'] if seen else None, 'binding': bool(binding)}


def adapter_case(case, rec, workdir):
    kind = case.get('adapter', 'slot')
    if kind == 'slot':
        return slot_adapter_case(case, workdir)
    if kind == 'observer':
        return observer_case(case, rec, workdir)
    if kind == 'exit-fact':
        return exit_fact_case(case)
    raise nr.HarnessError('unknown adapter %r' % kind)


def slot_adapter_case(case, workdir):
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
    select = sorted(set(a.select or []))
    doc = {'format': 'core-hook-npm-response-check/3', 'select': select or None,
           'claim': "the readers and adapters against literal cases; the author's own check, not an independent verification"}
    try:
        rec, errors = read_contract(a.contract, a.contract_sha256)
        rows.owe('contract', 'record')
        rows.judge('contract', 'record', None, errors)
        if rec is None or errors:
            return finish_rows(rows, out, doc, 'the contract did not hold')
        cases = rec['controls']
        readers = [c for c in cases['readers'] if not select or c['name'] in select]
        adapters = [c for c in cases['adapters'] if not select or c['name'] in select]
        unknown = sorted(set(select) - {c['name'] for c in cases['readers'] + cases['adapters']})
        if unknown:
            rows.owe('select', 'names')
            rows.judge('select', 'names', None, [{'field': 'selected cases', 'actual': unknown, 'expected': 'cases of this contract'}])
        for c in readers:
            rows.owe('reader', c['name'])
        for c in adapters:
            rows.owe('adapter', c['name'])
        for c in readers:
            got = reader_case(c, rec)
            errors = [{'field': k, 'actual': got.get(k), 'expected': v} for k, v in c['expect'].items() if not same(got.get(k), v)]
            rows.judge('reader', c['name'], None, errors, got=got, layer_of_control=c['layer'])
        with tempfile.TemporaryDirectory(prefix='npmresp-check.') as work:
            for c in adapters:
                got = adapter_case(c, rec, work)
                errors = [{'field': k, 'actual': got.get(k), 'expected': v} for k, v in c['expect'].items() if not same(got.get(k), v)]
                rows.judge('adapter', c['name'], None, errors, got=got, layer_of_control=c['layer'])
    except Exception as e:
        traceback.print_exc()
        doc['stopped'] = '%s: %s' % (type(e).__name__, e)
        finish_rows(rows, out, doc, 'this runner stopped before the row was judged: ' + doc['stopped'])
        return 2
    return finish_rows(rows, out, doc)


# --- check-controls: what the bundle's runs left, read with the standard library ---------------------
#
# Nothing here calls read_ps, target_exit, host_basis, slot_reading,
# read_pending, scenario_rows, judge_launch or bind_scratch. Expectations
# come from the contract and the control spec as literals. A child's role is
# read from its own argv's first word; a ps line is split on blanks; a
# record's kind and a file's presence are read as they are.

def jload(path):
    with open(path, 'rb') as f:
        return json.loads(f.read().decode('utf-8', 'surrogateescape'))


def jmaybe(path):
    p = Path(path)
    return jload(p) if p.is_file() else None


def step_rc(runs, step):
    p = Path(runs) / step / 'rc'
    return int(p.read_text().strip()) if p.is_file() else None


def records_in(directory):
    d = Path(directory)
    return [jload(p) for p in sorted(d.iterdir()) if p.name.endswith('.json')] if d.is_dir() else []


def role_of(launch_dir, nonce):
    p = Path(launch_dir) / 'obs' / (nonce + '.started.json')
    if not p.is_file():
        return None
    argv = jload(p).get('argv') or []
    return argv[0] if argv else None


def applied(runs, step, edits):
    """True when the copy a step ran is this tree with exactly the declared
    edits, by the driver's before and after digests recomputed here; False
    when they differ; None when the driver left no record of them."""
    notes = jmaybe(Path(runs) / step / 'edits.json')
    if notes is None:
        return None
    files, want = {}, []
    for e in edits:
        if e['file'] not in files:
            files[e['file']] = (TREE / e['file']).read_bytes()
        before = files[e['file']]
        if before.count(e['old'].encode('utf-8')) != 1:
            return False
        files[e['file']] = before.replace(e['old'].encode('utf-8'), e['new'].encode('utf-8'))
        want.append({'file': e['file'], 'before_sha256': hashlib.sha256(before).hexdigest(),
                     'after_sha256': hashlib.sha256(files[e['file']]).hexdigest()})
    return notes == want


def ps_rows(query):
    """{pid: stat} of a ps query's stdout split on blanks, or None when ps did not exit cleanly."""
    if not isinstance(query, dict) or (query.get('outcome') or {}).get('kind') != 'exit' or query.get('stderr') != '':
        return None
    rows = {}
    for line in (query.get('stdout') or '').splitlines():
        parts = line.split()
        if not parts:
            continue
        if not parts[0].isascii() or not parts[0].isdigit() or len(parts) < 2 or int(parts[0]) in rows:
            return None
        rows[int(parts[0])] = parts[1]
    return rows


def facts_check_run(runs, entry, rec, ctx):
    res = jmaybe(Path(runs) / entry['step'] / 'out' / 'results.json') or {}
    acc = res.get('acceptance') or {}
    return {'rc': step_rc(runs, entry['step']), 'results': bool(res), 'stopped': res.get('stopped'),
            'acceptance': acc.get('status'), 'failed': acc.get('failed')}


def facts_check_sensitivity(runs, entry, rec, ctx):
    step = entry['step']
    res = jmaybe(Path(runs) / step / 'out' / 'results.json') or {}
    declared = entry['expect']['signature'].get('failing', {})
    failing = {}
    for r in res.get('rows', []):
        if r.get('status') == 'fail':
            got = r.get('got') or {}
            keys = declared.get(r.get('case'), got)
            failing[r.get('case')] = {k: got.get(k) for k in keys}
    return {'applied': applied(runs, step, entry['edits']), 'rc': step_rc(runs, step), 'results': bool(res),
            'stopped': res.get('stopped'), 'failing': failing}


def facts_host(runs, entry, rec, ctx):
    """The ps host fact read with plain JSON and string reading against the contract's sequence."""
    out = Path(runs) / entry['step'] / 'out'
    doc, done = jmaybe(out / 'host.json'), jmaybe(out / 'ps-fact.done.json')
    facts = {'rc': step_rc(runs, entry['step']), 'host': doc is not None, 'done': done is not None,
             'pending': (out / 'ps-fact.pending.json').exists(), 'stopped': (out / 'ps-fact.stopped.json').exists(),
             'run-id': None, 'sequence': None, 'live': None, 'reaped': None, 'rows': None, 'order': None, 'absent-rc-same': None}
    if not isinstance(doc, dict):
        return facts
    want = rec['ps']['host_fact']
    scope = doc.get('scope') or {}
    facts['run-id'] = scope.get('run_id') == ctx['run_id']
    events = doc.get('events') or []
    facts['sequence'] = [[e.get('kind'), e.get('name') if e.get('kind') == 'ps' else e.get('holder'), e.get('when')] for e in events] == \
        [[k, n, w] for k, n, w in want['sequence']] and [e.get('seq') for e in events] == list(range(len(events)))
    if not facts['sequence']:
        return facts
    facts['live'] = all('poll' in events[i] and events[i]['poll'] is None for i in (1, 3, 8, 10))
    facts['reaped'] = [events[i].get('rc') if events[i].get('returned') is True else None for i in (5, 12)] == [want['holder']['exit']] * 2
    sentinel, first, second = doc.get('sentinel'), events[0].get('pid'), events[6].get('pid')
    ps_path = (scope.get('ps') or {}).get('path')
    queries = {name: events[i].get('query') or {} for i, name in ((2, 'alive'), (7, 'gone'), (9, 'mixed'))}
    rows = {name: ps_rows(q) if (q.get('argv') or [None])[0] == ps_path else None for name, q in queries.items()}
    facts['rows'] = (rows['alive'] is not None and set(rows['alive']) == {sentinel, first} and not rows['alive'][first].startswith('Z')
                     and rows['gone'] is not None and set(rows['gone']) == {sentinel}
                     and rows['mixed'] is not None and set(rows['mixed']) == {sentinel, second} and not rows['mixed'][second].startswith('Z'))
    t = lambda i: events[i].get('t_ns', 0)
    facts['order'] = (t(1) <= queries['alive'].get('t0_ns', -1) and queries['alive'].get('t1_ns', 1 << 62) <= t(3)
                      and t(5) < queries['gone'].get('t0_ns', -1)
                      and t(8) <= queries['mixed'].get('t0_ns', -1) and queries['mixed'].get('t1_ns', 1 << 62) <= t(10))
    facts['absent-rc-same'] = (queries['gone'].get('outcome') or {}).get('rc') == (queries['mixed'].get('outcome') or {}).get('rc') \
        and type((queries['gone'].get('outcome') or {}).get('rc')) is int
    return facts


def launch_parts(out, name):
    d = Path(out) / 'launches' / name
    js = records_in(d / 'observer')
    terminal = js[-1] if js and js[-1].get('kind') == 'terminal' else {}
    return d, js, terminal


def facts_j1(runs, entry, rec, ctx):
    step = entry['step']
    out = Path(runs) / step / 'out'
    d, js, terminal = launch_parts(out, 'native-P1-permuted')
    polls = [r for r in js if r.get('kind') == 'exit-poll']
    exited = [r for r in js if r.get('kind') == 'exited']
    giveups = [r for r in js if r.get('kind') == 'give-up']
    releases = [r for r in js if r.get('kind') == 'gate' and r.get('what') == 'release']

    def injected(p):
        q = p.get('ps') or {}
        lines = [line.split() for line in (q.get('stdout') or '').splitlines() if line.strip()]
        return q.get('outcome') == {'kind': 'signal', 'signal': 9} and bool(lines) and \
            all(parts[1] == 'Z' for parts in lines if parts and parts[0] != str(q.get('sentinel')))
    signal_polls = {p.get('seq') for p in polls if injected(p)}
    ok = False
    if len(giveups) == 1:
        t = giveups[0].get('t_ns', 0)
        before = [r for r in releases if r.get('t_ns', 0) < t]
        ok = len(before) == 1 and role_of(d, before[0].get('child')) == 'root' and all(r.get('t_ns', 0) >= t for r in releases if r not in before)
    return {'applied': applied(runs, step, entry['edits']), 'rc': step_rc(runs, step), 'launch': d.is_dir(),
            'injected': bool(polls) and len(signal_polls) == len(polls), 'terminal': terminal.get('state'),
            'ordered-release': any(r.get('why') == 'the imposed completion order' and role_of(d, r.get('child')) == 'root' for r in releases),
            'done': (out / 'collect.done.json').is_file() and (out / 'manifest.json').is_file(),
            'exited': len(exited), 'exit-from-signal': any(e.get('poll') in signal_polls for e in exited),
            'give-ups': [g.get('why') for g in giveups],
            'gave-up-on-root-exit': len(giveups) == 1 and 'exit of the root child' in str(giveups[0].get('why')),
            'release-after-give-up': ok}


def facts_j4(runs, entry, rec, ctx):
    step = entry['step']
    out = Path(runs) / step / 'out'
    d, js, terminal = launch_parts(out, 'native-P0-natural')
    p1, _, p1_terminal = launch_parts(out, 'native-P1-permuted')
    stop, pend, end = jmaybe(out / 'collect.stopped.json') or {}, jmaybe(out / 'collect.pending.json') or {}, jmaybe(d / 'launch-end.json')
    exc = terminal.get('exception') or {}
    end_observer = (end or {}).get('observer') or {}
    return {'applied': applied(runs, step, entry['edits']), 'rc': step_rc(runs, step), 'launch': d.is_dir(),
            'reached': any(r.get('kind') == 'control-reach' and r.get('control') == entry['reach_control'] and r.get('run_id') == ctx['run_id'] for r in js)
            if entry.get('reach_control') else None,
            'injected': terminal.get('state') == 'exception' and 'J4 control' in str(exc.get('error')),
            'cleanup-error': any('J4 control' in str(c.get('error')) for c in terminal.get('cleanup_errors') or []),
            'partial-before': any(r.get('kind') in ('start', 'read') and r.get('seq', 0) < terminal.get('seq', -1) for r in js),
            'terminal': terminal.get('state'),
            'end-written': end is not None, 'end-ended': end_observer.get('ended'),
            'end-terminal': (end_observer.get('terminal') or {}).get('state') if end is not None else None,
            'pending': pend.get('launch'),
            'stopped-unfinished': 'did not finish' in str(stop.get('reason')) and (stop.get('detail') or {}).get('launch') == 'native-P0-natural',
            'stopped-after-pending': bool(pend) and stop.get('pending') is True and pend.get('t_ns', 0) < stop.get('t_ns', 0),
            'terminal-after-pending': bool(pend) and terminal.get('t_ns', 0) > pend.get('t_ns', 0),
            'terminal-after-stopped': bool(stop) and terminal.get('t_ns', 0) > stop.get('t_ns', 0),
            'not-started': stop.get('not_started') == ['native-P1-permuted'] and not p1.exists(),
            'p1-launched': p1.is_dir(), 'p1-terminal': p1_terminal.get('state'),
            'done': (out / 'collect.done.json').is_file(), 'manifest': (out / 'manifest.json').is_file()}


def facts_j4h(runs, entry, rec, ctx):
    step = entry['step']
    out = Path(runs) / step / 'out'
    events = records_in(out / 'events')
    partial, pend, stop = jmaybe(out / 'ps-fact.partial.json') or {}, jmaybe(out / 'ps-fact.pending.json') or {}, jmaybe(out / 'ps-fact.stopped.json') or {}
    final = [e for e in events if e.get('kind') == 'holder-wait' and e.get('holder') == 'first' and e.get('timeout') is None and e.get('returned') is True]
    original = partial.get('original') or {}
    return {'applied': applied(runs, step, entry['edits']), 'rc': step_rc(runs, step),
            'reached': any(e.get('kind') == 'control-reach' and e.get('control') == 'J4h' and e.get('run_id') == ctx['run_id'] for e in events),
            'partial-original': original.get('type') == 'RuntimeError' and 'J4h control' in str(original.get('error')),
            'cleanup-errors': [[c.get('holder'), c.get('type')] for c in pend.get('cleanup_errors') or []],
            'pending-unreaped': pend.get('unreaped'),
            'reap-after-pending': len(final) == 1 and final[0].get('rc') == rec['ps']['host_fact']['holder']['exit'] and final[0].get('t_ns', 0) > pend.get('t_ns', 1 << 62),
            'stopped-unreaped': stop.get('unreaped'), 'stopped-reaped': stop.get('reaped'),
            'stopped-after-reap': len(final) == 1 and stop.get('t_ns', 0) > final[0].get('t_ns', 1 << 62),
            'host': (out / 'host.json').exists(), 'done': (out / 'ps-fact.done.json').exists()}


def same(a, b):
    """Equal as JSON values: false is not 0, and 1.0 is not 1."""
    return json.dumps(a, sort_keys=True) == json.dumps(b, sort_keys=True)


def listing(base, skip=('completion.json', 'completion.json.part', 'complete.log')):
    """The files, links and directories under <base>, as the driver's completion
    record lists them, read here with the standard library."""
    files, links, dirs = {}, {}, []
    for dirpath, dirnames, filenames in os.walk(str(base), followlinks=False):
        dirnames.sort()
        for name in dirnames + sorted(filenames):
            p = os.path.join(dirpath, name)
            rel = os.path.relpath(p, str(base))
            if rel in skip:
                continue
            st = os.lstat(p)
            if os.path.islink(p):
                links[rel] = os.readlink(p)
            elif os.path.isdir(p):
                dirs.append(rel)
            elif os.path.isfile(p):
                with open(p, 'rb') as f:
                    files[rel] = hashlib.sha256(f.read()).hexdigest()
            else:
                links[rel] = 'not a file: mode %o' % st.st_mode
    return {'files': files, 'links': links, 'dirs': dirs}


def attempt_parts(scratch, bundle, attempt):
    base = Path(scratch) / 'attempts' / bundle / attempt
    dj_path = base / 'driver.json'
    dj = jmaybe(dj_path) if dj_path.is_file() else None
    comp = jmaybe(base / 'completion.json')
    rc_text = (base / 'driver.rc').read_text() if (base / 'driver.rc').is_file() else None
    ran, injected = [], True
    if (base / 'runs').is_dir():
        for p in sorted((base / 'runs').iterdir()):
            if (p / 'rc').is_file():
                ran.append(p.name)
                injected = injected and (p / 'injected').is_file()
    return base, dj, dj_path, comp, rc_text, ran, injected and bool(ran)


def stopped_parts(dj):
    """(kind, detail) of a driver record's stop: a protocol or gate stop's
    step, an exception's type, or a prerequisite's reason class."""
    st = (dj or {}).get('stopped')
    if not isinstance(st, dict):
        return None, None
    if st.get('kind') == 'exception':
        head, _, rest = str(st.get('exception')).partition(': ')
        return 'exception', rest.split(':')[0] if head == 'PrerequisiteError' else head
    return st.get('kind'), st.get('step')


def unchanged(scratch, bundle, attempt):
    """True when an attempt's files are still the ones its completion record lists."""
    base = Path(scratch) / 'attempts' / bundle / attempt
    comp = jmaybe(base / 'completion.json')
    return isinstance(comp, dict) and same(listing(base), comp.get('outputs'))


def scratch_applied(ctx, root_name):
    """True when a scratch root's driver is the staged driver with exactly the
    spec's injected edits and the root's own edits, recomputed here."""
    spec, staged = ctx['spec'], ctx['staged']
    if staged is None:
        return None
    data = (Path(staged) / 'run.py').read_bytes()
    inj = spec['injected']
    edits = [(inj['execute_old'], inj['execute_new'].replace('@TABLES@', json.dumps(spec['tables'], sort_keys=True))),
             (inj['kind_old'], inj['kind_new'])] + [(e['old'], e['new']) for e in spec['roots'][root_name].get('edits', [])]
    for old, new in edits:
        if data.count(old.encode('utf-8')) != 1:
            return False
        data = data.replace(old.encode('utf-8'), new.encode('utf-8'))
    target = Path(ctx['runs']) / 'flows' / root_name / 'run.py'
    return target.is_file() and hashlib.sha256(target.read_bytes()).hexdigest() == hashlib.sha256(data).hexdigest()


def facts_flow(runs, entry, rec, ctx):
    """One S0 flow step: the status its parent saw and what its scratch run left."""
    scratch = Path(runs) / 'flows' / entry['root']
    facts = {'rc': step_rc(runs, entry['name'])}
    if entry['action'] == 'stage':
        doc = jmaybe(scratch / 'RUN.json')
        facts.update({'run-json': doc is not None, 'kind': (doc or {}).get('kind'), 'applied': scratch_applied(ctx, entry['root'])})
        return facts
    base, dj, dj_path, comp, rc_text, ran, injected = attempt_parts(scratch, entry['bundle'], entry['attempt'])
    kind, detail = stopped_parts(dj)
    facts.update({'attempt': base.is_dir(), 'driver-rc': rc_text,
                  'driver-json': 'file' if dj_path.is_file() else 'directory' if dj_path.is_dir() else 'absent',
                  'completion': comp is not None, 'completion-rc': (comp or {}).get('driver_rc', 'absent'),
                  'final': (dj or {}).get('final'), 'stopped-kind': kind, 'stopped-detail': detail,
                  'runs-dir': (base / 'runs').is_dir(), 'ran': ran, 'injected': injected,
                  'prerequisites': [[q.get('bundle'), q.get('origin_attempt_id'), q.get('mode')] for q in (dj or {}).get('prerequisites') or []]})
    if entry.get('target'):
        facts['target-unchanged'] = unchanged(scratch, entry['bundle'], entry['target'])
    if entry.get('sensitivity'):
        facts['applied'] = scratch_applied(ctx, entry['root'])
    return facts


def facts_immutable(runs, entry, rec, ctx):
    """An attempt the S0 flows referred to, read at the end: its files are its
    completion's, and it ran its steps once."""
    scratch = Path(runs) / 'flows' / entry['root']
    base, dj, _, comp, rc_text, ran, _ = attempt_parts(scratch, entry['bundle'], entry['attempt'])
    return {'completion': comp is not None, 'unchanged': unchanged(scratch, entry['bundle'], entry['attempt']),
            'driver-rc': rc_text, 'ran': ran, 'executed': [s.get('step') for s in (dj or {}).get('steps') or []]}


FACTS = {'check-run': facts_check_run, 'check-sensitivity': facts_check_sensitivity, 'host-fact': facts_host,
         'J1': facts_j1, 'J4': facts_j4, 'J4h': facts_j4h, 'flow': facts_flow, 'immutable': facts_immutable}


def owed_controls(rec, spec, bundle):
    """(layer, name, entry) for every row this bundle's check-controls owes, in the contract's and spec's order."""
    owed = []
    for entry in rec['controls']['steps']:
        if entry['bundle'] == bundle:
            owed.append((entry['layer'], entry['name'], entry))
    for entry in rec['controls']['copies']:
        if entry['bundle'] == bundle:
            owed.append(('copy', entry['name'], entry))
    for entry in rec['controls']['sensitivity']:
        if entry['bundle'] == bundle:
            owed.append(('sensitivity', entry['name'], entry))
    if bundle == 'S0':
        for entry in spec['flows']:
            owed.append(('flow-sensitivity' if entry.get('sensitivity') else 'flow', entry['name'], dict(entry, check='flow')))
        for entry in spec['immutable']:
            owed.append(('immutable', entry['name'], dict(entry, check='immutable')))
    return owed


def control_row(rows, layer, name, expect, facts):
    """Reached means every reach fact holds; then the row is its signature,
    exactly, compared as JSON values."""
    unmet = {k: facts.get(k) for k, v in expect['reach'].items() if not same(facts.get(k), v)}
    if unmet:
        rows.leave(layer, name, None, 'not demonstrated: %r' % (unmet,), facts=facts, expected=expect)
        return
    errors = [{'field': k, 'actual': facts.get(k), 'expected': v} for k, v in expect['signature'].items() if not same(facts.get(k), v)]
    rows.judge(layer, name, None, errors, facts=facts, expected=expect)


def check_controls(a):
    runs, out = Path(a.runs).resolve(), Path(a.out).resolve()
    out.mkdir(parents=True, exist_ok=False)
    rows = Rows()
    doc = {'format': 'core-hook-npm-response-controls/3', 'bundle': a.bundle, 'only': a.only, 'run_id': a.run_id, 'staged_root': a.staged_root,
           'claim': "a bundle's runs read from their files and their parent-observed status; the author's own check, not an independent verification"}
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
        owed = owed_controls(rec, spec, a.bundle)
        if a.only:
            owed = [o for o in owed if o[1] == a.only]
            if not owed:
                rows.owe('control', a.only)
                rows.judge('control', a.only, None, [{'field': 'control', 'actual': a.only, 'expected': 'a control of bundle %s' % a.bundle}])
                return finish_rows(rows, out, doc)
        ctx = {'run_id': a.run_id, 'spec': spec, 'staged': a.staged_root, 'runs': runs}
        for layer, name, _ in owed:
            rows.owe(layer, name)
        for layer, name, entry in owed:
            facts = FACTS[entry['check']](runs, entry, rec, ctx)
            control_row(rows, layer, name, entry['expect'], facts)
    except Exception as e:
        traceback.print_exc()
        doc['stopped'] = '%s: %s' % (type(e).__name__, e)
        finish_rows(rows, out, doc, 'this runner stopped before the row was judged: ' + doc['stopped'])
        return 2
    return finish_rows(rows, out, doc)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='command', required=True)
    c = sub.add_parser('collect')
    c.add_argument('--contract', default=str(HERE / 'core-hook-npm-response.contract.json'))
    c.add_argument('--contract-sha256', required=True, help='external selection: the digest of the reviewed record')
    c.add_argument('--build-root')
    c.add_argument('--build-pin', help='external selection: the observed builder record digest')
    c.add_argument('--run-id', help="the driver's run: 32 lowercase hex digits")
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
    j.add_argument('--ps-host-fact', required=True)
    j.add_argument('--ps-host-fact-sha256', required=True)
    j.add_argument('--out', required=True)
    p = sub.add_parser('ps-fact')
    p.add_argument('--run-id', required=True)
    p.add_argument('--out', required=True)
    k = sub.add_parser('check')
    k.add_argument('--contract', default=str(HERE / 'core-hook-npm-response.contract.json'))
    k.add_argument('--contract-sha256', required=True)
    k.add_argument('--select', action='append', help='a reader or adapter case name; repeat for more. Without it every case runs')
    k.add_argument('--out', required=True)
    x = sub.add_parser('check-controls')
    x.add_argument('--runs', required=True)
    x.add_argument('--bundle', required=True, choices=nr.BUNDLES)
    x.add_argument('--only')
    x.add_argument('--run-id', required=True)
    x.add_argument('--contract', default=str(HERE / 'core-hook-npm-response.contract.json'))
    x.add_argument('--contract-sha256', required=True)
    x.add_argument('--control-spec', required=True)
    x.add_argument('--control-spec-sha256', required=True)
    x.add_argument('--staged-root', help="the staged run root whose driver the S0 scratch drivers are edited from")
    x.add_argument('--out', required=True)
    a = ap.parse_args()
    return {'collect': collect, 'judge': judge, 'ps-fact': ps_fact, 'check': check, 'check-controls': check_controls}[a.command](a)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception:  # Whatever stopped the runner is not a judgment.
        traceback.print_exc()
        sys.exit(2)
