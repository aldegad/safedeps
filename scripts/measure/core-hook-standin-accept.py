#!/usr/bin/env python3
"""Make core-hook-standin.py's planned negatives and judge its runs together.

  control NAME   write one planned negative's input and a note of the change:
                 a changed copy of the acceptance record or of the cases, or
                 the H1 defect put back into an extracted tree
  judge          read the runs under one directory and say, row by row, what
                 was accepted

This file reads JSON, directory listings and the files a driver keeps beside
a run. It starts no hook, imports nothing of the collector and takes no
expectation from a run: the rows a run owes and what each planned negative has
to show are written here, a second time, on purpose. A row that is absent or
not-run, or whose file is absent, is never a pass, and no rows is a failure.
A planned negative passes when its failure was detected where it was planned.
It is not-run, with the row it waits for, when the baseline it stands on did
not pass. The canonical comparison's verdict is copied into `semantic` and is
no part of acceptance.

A run is RUNS/<label>/ with out/ (the runner's --out), rc (its exit status)
and, for a planned negative, control.json (the note `control` wrote). Labels:
baseline, contract-holds (contract stage), each contract control's name, h1,
and from a fresh validator fresh-positive and fresh-record-loss.

Exit 0: every row passed. Exit 1: a row failed. Exit 3: nothing failed and a
row was not run. Exit 2: this file could not do its work.
"""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import sys
import traceback

RESULTS = 'core-hook-standin-results/1'
TABLE = 'core-hook-standin-acceptance-table/1'
# The rows a run owes, stated here as well as in core-hook-standin.py.
CONTRACT = ('record', 'fixture', 'statement', 'asks', 'answers', 'launch-env', 'direct')
DIRECT = ('ordinary', 'sleep', 'nonzero')
CALLS = ('records', 'argv', 'env', 'answer', 'scratch', 'launch', 'take-calls', 'bundle', 'scratch-source')
SIDES = ('native-reference', 'native-candidate', 'bash-reference')
BUNDLES = ('native-pair', 'bash-native')
# The contract's planned negatives: the row that has to refuse each, the file changed, the change.
REFUSED = {
    'missing-words': ('contract/statement', 'record', "the statement's own words are removed"),
    'template-without-words': ('contract/asks', 'record', "no ask template carries the statement's words"),
    'missing-ask': ('contract/asks', 'record', 'the root ask is not declared'),
    'duplicate-ask': ('contract/asks', 'record', 'the root ask is declared twice'),
    'command-changed': ('contract/fixture', 'record', 'the record names a command the fixture does not have'),
    'record-changed-after-selection': ('contract/record', 'record', 'the record gains a byte after its digest was selected'),
    'fixture-command-changed': ('contract/fixture', 'cases', "the fixture's command changes under the same id"),
}
# H1 is the defect of c021e1f, put back byte for byte: module imports inside the stand-in npm template.
OBSERVE = 'scripts/measure/core_hook/observe.py'
H1_OLD = 'if answer.get("sleep"):\n    import time\n    time.sleep(answer["sleep"])'
H1_NEW = 'if answer.get("sleep"):\n    import time\nimport uuid\n\nfrom . import evidence\n    time.sleep(answer["sleep"])'
H1_SHA256 = '5dfaf0d3235f923645e2cb3e1bda0184b477e91a5e8b4621f5fa059321a13491'
WAITS = 'the hook layers wait for the review of the contract'
FRESH = 'owed by a fresh validator other than the author'


def sha(data):
    return hashlib.sha256(data).hexdigest()


# --- control: one planned negative's input ----------------------------------------------

def change(name, doc, fixture_id):
    if name == 'fixture-command-changed':
        found = [case for case in doc['cases'] if case.get('id') == fixture_id]
        if len(found) != 1:
            raise ValueError('the cases do not hold %s once' % fixture_id)
        found[0]['steps'][0]['command'] += ' left-pad'
        return
    root = [ask for ask in doc['asks'] if ask['name'] == 'root']
    if doc['statement']['words'] != ['install'] or len(root) != 1:
        raise ValueError('the record is not the one these controls change')
    if name == 'missing-words':
        doc['statement']['words'] = []
    elif name == 'template-without-words':
        for ask in doc['asks']:
            ask['argv'] = [word for word in ask['argv'] if word != '@W@']
    elif name == 'missing-ask':
        doc['asks'] = [ask for ask in doc['asks'] if ask['name'] != 'root']
    elif name == 'duplicate-ask':
        doc['asks'].append(copy.deepcopy(root[0]))
    elif name == 'command-changed':
        # A record that agrees with itself and not with the fixture.
        old = doc['fixture']['command']
        if not old.endswith(' npm install'):
            raise ValueError('the record is not the one these controls change')
        new = old[:-len('install')] + 'ci'
        doc['fixture']['command'] = doc['fixture']['payload']['tool_input']['command'] = new
        doc['statement']['words'] = ['ci']
    else:
        raise ValueError('unknown control: ' + name)


def control(a):
    name = a.name
    needs = ['tree'] if name == 'h1' else ['contract', 'out'] + (['cases'] if REFUSED[name][1] == 'cases' else [])
    missing = [arg for arg in needs if not getattr(a, arg)]
    if missing:
        raise ValueError('%s needs --%s' % (name, ', --'.join(missing)))
    if os.path.lexists(a.note):
        raise ValueError('the note is already there, so nothing was changed: ' + a.note)
    if name == 'h1':
        target = Path(a.tree) / OBSERVE
        source = target.read_bytes()
        text = source.decode('utf-8')
        if text.count(H1_OLD) != 1:
            raise ValueError('the place H1 goes back into is not in %s exactly once' % target)
        data = text.replace(H1_OLD, H1_NEW).encode('utf-8')
        if sha(data) != H1_SHA256:
            raise ValueError('the changed file is not the file c021e1f had')
        where, mode = target, 'wb'
        note = {'control': name, 'kind': 'tree', 'file': OBSERVE,
                'change': 'the import lines of c021e1f are back inside the stand-in npm template'}
    elif name in REFUSED:
        row, kind, what = REFUSED[name]
        source = Path(a.cases if kind == 'cases' else a.contract).read_bytes()
        if name == 'record-changed-after-selection':
            data, select = source + b'\n', sha(source)
        else:
            doc = json.loads(source.decode('utf-8'))
            change(name, doc, json.loads(Path(a.contract).read_bytes().decode('utf-8'))['fixture']['id'])
            data = (json.dumps(doc, indent=1, ensure_ascii=False) + '\n').encode('utf-8')
            select = sha(data) if kind == 'record' else None
        where, mode = a.out, 'xb'
        # `select` is the digest to hand the runner as the record's selection.
        note = {'control': name, 'kind': kind, 'refused_by': row, 'change': what, 'select': select}
    else:
        raise ValueError('unknown control: ' + name)
    if data == source:
        raise ValueError('the control changed nothing')
    with open(where, mode) as f:
        f.write(data)
    note.update(source_sha256=sha(source), sha256=sha(data))
    with open(a.note, 'x', encoding='utf-8') as f:
        json.dump(note, f, indent=1, sort_keys=True)
        f.write('\n')
    print(json.dumps(note, sort_keys=True), flush=True)
    return 0


# --- judge: the runs, row by row --------------------------------------------------------

def load(path):
    try:
        with open(path, encoding='utf-8') as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def read_run(runs, label):
    """A run as its files say it. What cannot be read is absent."""
    base = Path(runs) / label
    results = load(base / 'out' / 'results.json')
    if not (isinstance(results, dict) and results.get('format') == RESULTS and isinstance(results.get('rows'), list)):
        results = None
    table, twice = {}, []
    for row in (results or {}).get('rows', []):
        if not isinstance(row, dict):
            twice.append('a row that is no object')
            continue
        key = '/'.join(str(part) for part in (row.get('layer'), row.get('case'), row.get('side')) if part)
        if key in table:
            twice.append(key)
        table[key] = row
    try:
        rc = int((base / 'rc').read_text().strip())
    except (OSError, ValueError):
        rc = None
    try:
        listing = sorted(os.listdir(base / 'out'))
    except OSError:
        listing = None
    return {'label': label, 'dir': str(base), 'results': results, 'table': table, 'twice': twice, 'rc': rc,
            'listing': listing, 'note': load(base / 'control.json')}


def check(problems, label, actual, expected):
    if actual != expected:
        problems.append('%s is %.200r, not %.200r' % (label, actual, expected))


def owed(sides=SIDES, bundles=BUNDLES):
    keys = ['contract/' + case for case in CONTRACT]
    keys += ['executable/%s/%s' % (case, name) for case in ('response', 'record') for name in DIRECT]
    keys += ['calls/%s/%s' % (case, side) for side in sides for case in CALLS]
    keys += ['%s/%s' % (layer, bundle) for layer in ('admission', 'replay') for bundle in bundles]
    return keys


def consistent(run, mode, stop_after=None, skip_bash=False):
    """The run is the kind of run its label says, and its exit status is its own verdict's."""
    res, problems = run['results'], []
    status = (res.get('acceptance') or {}).get('status')
    check(problems, 'mode', res.get('mode'), mode)
    check(problems, 'stop_after', res.get('stop_after'), stop_after)
    check(problems, 'skip_bash', res.get('skip_bash'), skip_bash)
    check(problems, 'exit status of a run that says %s' % status, run['rc'], {'pass': 0, 'fail': 1, 'incomplete': 3}.get(status, 'known'))
    check(problems, 'rows named twice', run['twice'], [])
    return problems


def grade(run, keys, problems=()):
    """One acceptance row from the runner rows it stands on. No rows accept nothing."""
    if run['results'] is None:
        return 'not-run', 'no results were read from ' + run['dir']
    if not keys:
        return 'fail', 'no row was required, which accepts nothing'
    states = [(key, run['table'][key].get('status') if key in run['table'] else 'absent') for key in keys]
    notes = list(problems) + ['%s is %s' % state for state in states if state[1] != 'pass']
    if problems or any(state == 'fail' for _, state in states):
        return 'fail', '; '.join(notes)
    if notes:
        return 'not-run', '; '.join(notes)
    return 'pass', '%d of %d rows passed' % (len(states), len(keys))


def status_of(run, key):
    return run['table'].get(key, {}).get('status', 'absent')


def actual_of(run, key, field):
    """What the runner row says it saw for one field it refused."""
    for error in run['table'].get(key, {}).get('errors') or []:
        if isinstance(error, dict) and error.get('field') == field:
            return error.get('actual')
    return 'no such refusal'


def sources_of(run):
    return ((run['results'] or {}).get('inputs') or {}).get('collector_sources') or {}


def read_of(run, which):
    return (((run['results'] or {}).get('inputs') or {}).get(which) or {}).get('read')


def runner_of(run):
    return (((run['results'] or {}).get('inputs') or {}).get('runner') or {}).get('sha256')


def refused(run, name, stage):
    """A planned negative of the contract: refused at its row, with nothing launched."""
    if run['results'] is None:
        return 'not-run', 'no results were read from ' + run['dir']
    row, kind, _ = REFUSED[name]
    res, note = run['results'], run['note'] or {}
    problems = consistent(run, 'baseline', stop_after='contract' if stage == 'contract' else None)
    check(problems, 'acceptance', (res.get('acceptance') or {}).get('status'), 'fail')
    check(problems, row, status_of(run, row), 'fail')
    check(problems, 'launches', res.get('launches'), {'executable': 0, 'hook': 0})
    check(problems, 'rows after the contract',
          sorted(set(r.get('status') for key, r in run['table'].items() if not key.startswith('contract/'))), ['not-run'])
    check(problems, 'owed rows the run does not name', sorted(set(owed()) - set(run['table'])), [])
    check(problems, 'files the run left', run['listing'], ['results.json'])
    check(problems, 'control note', [note.get('control'), note.get('kind'), note.get('refused_by')], [name, kind, row])
    check(problems, 'the changed input is the one the run read', read_of(run, 'cases' if kind == 'cases' else 'contract'),
          note.get('sha256', 'a note'))
    if problems:
        return 'fail', '; '.join(problems)
    return 'pass', 'refused at %s; executable launches 0, hook launches 0; the run left results.json alone' % row


def h1(run, baseline):
    """H1 back in the generated executable: no answer, no record, on both native sides."""
    if run['results'] is None:
        return 'not-run', 'no results were read from ' + run['dir']
    res, note = run['results'], run['note'] or {}
    problems = consistent(run, 'planned-negative:h1', skip_bash=True)
    check(problems, 'contract rows', sorted(set(status_of(run, 'contract/' + case) for case in CONTRACT)), ['pass'])
    for name in DIRECT:
        seen = run['table'].get('executable/response/' + name, {}).get('observed') or {}
        check(problems, name + ' answer (status, stdout, the syntax failure on stderr)',
              [status_of(run, 'executable/response/' + name), seen.get('stdout'), 'IndentationError' in str(seen.get('stderr'))],
              ['fail', '', True])
        check(problems, name + ' record (status, record files)',
              [status_of(run, 'executable/record/' + name), actual_of(run, 'executable/record/' + name, 'record files')], ['fail', []])
    for side in SIDES[:2]:
        check(problems, side + ' call records (status, record files)',
              [status_of(run, 'calls/records/' + side), actual_of(run, 'calls/records/' + side, 'record files')], ['fail', []])
    check(problems, 'launches', res.get('launches'), {'executable': 3, 'hook': 2})
    check(problems, 'control note', [note.get('control'), note.get('sha256')], ['h1', H1_SHA256])
    mine, base = sources_of(run), sources_of(baseline)
    check(problems, 'collector sources that differ from the baseline', sorted(k for k in set(mine) | set(base) if mine.get(k) != base.get(k)),
          ['core_hook/observe.py'])
    check(problems, 'the stand-in source the run used', mine.get('core_hook/observe.py'), H1_SHA256)
    check(problems, 'the runner is read and is the one the baseline ran',
          [runner_of(run) is not None, runner_of(run) == runner_of(baseline)], [True, True])
    # The failure is seen in a collection that was itself admitted, not in a refused one.
    said = run['table'].get('equivalence/native-pair', {}).get('expectations') or {}
    check(problems, 'admission of the new collection', status_of(run, 'admission/native-pair'), 'pass')
    check(problems, 'the canonical expectations name the missing calls on both sides',
          [any('has no calls/npm/' in line for line in said.get(side) or []) for side in ('reference', 'candidate')], [True, True])
    if problems:
        return 'fail', '; '.join(problems)
    return 'pass', ('detected: three direct runs gave no answer and a syntax failure and wrote no record; both native sides '
                    'left no call record in an admitted collection, and the canonical expectations name the missing calls')


def fresh_positive(run, baseline):
    if run['results'] is None:
        return 'not-run', '%s; no results were read from %s' % (FRESH, run['dir'])
    stop = run['results'].get('stop_after')
    problems = consistent(run, 'baseline', stop_after=stop)
    check(problems, 'stop_after is none or executable', stop in (None, 'executable'), True)
    check(problems, "its record is read, the author's is read, and they differ",
          [read_of(run, 'contract') is not None, read_of(baseline, 'contract') is not None,
           read_of(run, 'contract') != read_of(baseline, 'contract')], [True, True, True])
    return grade(run, ['contract/' + case for case in CONTRACT] +
                 ['executable/%s/%s' % (case, name) for case in ('response', 'record') for name in DIRECT], problems)


def fresh_record_loss(run, baseline):
    if run['results'] is None:
        return 'not-run', '%s; no results were read from %s' % (FRESH, run['dir'])
    res = run['results']
    problems = consistent(run, 'planned-negative:record-loss', stop_after=res.get('stop_after'), skip_bash=res.get('skip_bash'))
    check(problems, 'stop_after is none or executable', res.get('stop_after') in (None, 'executable'), True)
    mine, base = sources_of(run), sources_of(baseline)
    check(problems, 'both collector sources are read and the stand-in source differs from the baseline',
          [bool(mine), bool(base), mine.get('core_hook/observe.py') != base.get('core_hook/observe.py')], [True, True, True])
    for name in DIRECT:
        check(problems, name + ' (answer, record)',
              [status_of(run, 'executable/response/' + name), status_of(run, 'executable/record/' + name)], ['pass', 'fail'])
    if problems:
        return 'fail', '; '.join(problems)
    return 'pass', 'detected: each direct run answered as its fixture says and its missing record was refused'


def assess(data, stage):
    """Every acceptance row but the self-controls, from what was read."""
    rows = []

    def add(ident, run, verdict, after=None):
        rows.append({'id': ident, 'status': verdict[0], 'reason': verdict[1], 'run': run['dir'] if run else None, 'after': after})

    full = stage == 'full'
    base = data['baseline']
    holds = base if full else data['contract-holds']
    problems = []
    if holds['results'] is not None:
        problems = consistent(holds, 'baseline', stop_after=None if full else 'contract')
        if not full:
            check(problems, 'launches', holds['results'].get('launches'), {'executable': 0, 'hook': 0})
            check(problems, 'files the run left', holds['listing'], ['expectation.json', 'results.json'])
    add('A0/contract-holds', holds, grade(holds, ['contract/' + case for case in CONTRACT], problems))
    for name in REFUSED:
        add('A0/' + name, data[name], refused(data[name], name, stage))
    if not full:
        for ident in ('A1', 'A2', 'A3', 'A4', 'A5', 'A6'):
            add(ident, None, ('not-run', WAITS))
        return rows
    launched = (base['results'] or {}).get('launches') or {}
    ran = list(problems)
    check(ran, 'executable launches', launched.get('executable'), 3)
    for case in ('response', 'record'):
        for name in DIRECT:
            add('A1/%s/%s' % (case, name), base, grade(base, ['executable/%s/%s' % (case, name)], ran))
    ran = list(problems)
    check(ran, 'hook launches', launched.get('hook'), 3)
    for side in SIDES:
        add('A2/' + side, base, grade(base, ['calls/%s/%s' % (case, side) for case in CALLS], ran))
    for layer in ('admission', 'replay'):
        for bundle in BUNDLES:
            add('A3/%s/%s' % (layer, bundle), base, grade(base, ['%s/%s' % (layer, bundle)], problems))
    blocked = next((row['id'] for row in rows if row['status'] != 'pass' and not row['id'].startswith('A0/') or
                    row['id'] == 'A0/contract-holds' and row['status'] != 'pass'), None)
    if blocked:
        add('A4/h1', data['h1'], ('not-run', 'the baseline did not pass, so its planned negative was not judged'), blocked)
    else:
        add('A4/h1', data['h1'], h1(data['h1'], base))
    add('A5/fresh-positive', data['fresh-positive'], fresh_positive(data['fresh-positive'], base))
    add('A5/fresh-record-loss', data['fresh-record-loss'], fresh_record_loss(data['fresh-record-loss'], base))
    return rows


# The same judgment over damaged copies of the baseline it read. Each has to
# come out not accepted, or a missing row could have passed unnoticed.
DAMAGE = {
    'row-absent': ('A2/native-candidate', lambda run: run['table'].pop('calls/argv/native-candidate')),
    'row-not-run': ('A1/record/nonzero', lambda run: run['table']['executable/record/nonzero'].update(status='not-run')),
    'rows-empty': ('A3/replay/native-pair', lambda run: run['table'].clear()),
    'results-absent': ('A1/response/ordinary', lambda run: run.update(results=None, table={})),
}


def self_controls(data, rows):
    out = []
    was = {row['id']: row['status'] for row in rows}
    for name, (target, damage) in DAMAGE.items():
        if was.get(target) != 'pass':
            verdict = ('not-run', '%s was not a pass, so damaging it shows nothing' % target)
        else:
            damaged = copy.deepcopy(data)
            damage(damaged['baseline'])
            now = {row['id']: row['status'] for row in assess(damaged, 'full')}
            verdict = ('pass', '%s became %s' % (target, now.get(target))) if now.get(target) in ('fail', 'not-run') else \
                      ('fail', '%s stayed %s over a damaged baseline' % (target, now.get(target)))
        out.append({'id': 'A6/' + name, 'status': verdict[0], 'reason': verdict[1], 'run': data['baseline']['dir'], 'after': None})
    return out


def judge(a):
    labels = ['baseline', 'contract-holds', 'h1', 'fresh-positive', 'fresh-record-loss'] + list(REFUSED)
    data = {label: read_run(a.runs, label) for label in labels}
    rows = assess(data, a.stage)
    if a.stage == 'full':
        rows += self_controls(data, rows)
    states = [row['status'] for row in rows]
    status = 'fail' if 'fail' in states or not rows else 'incomplete' if 'not-run' in states else 'pass'
    semantic = [{'bundle': row.get('case'), 'status': row.get('status'), 'verdict': row.get('verdict'), 'rc': row.get('rc'),
                 'red_channels': row.get('red_channels'), 'unresolved': row.get('unresolved')}
                for key, row in sorted(data['baseline']['table'].items()) if key.startswith('equivalence/')]
    doc = {'format': TABLE, 'stage': a.stage, 'runs': str(Path(a.runs).resolve()), 'status': status, 'rows': rows,
           'counts': {state: states.count(state) for state in ('pass', 'fail', 'not-run')}, 'semantic': semantic,
           'scope': 'the acceptance tool for one fixture: its contract, the generated executable, the call records, admission '
                    'and faithful replay, and its planned negatives. Not equivalence of the two implementations, and not the '
                    "parent plan's completion."}
    with open(a.out, 'x', encoding='utf-8') as f:
        json.dump(doc, f, indent=1, sort_keys=True)
        f.write('\n')
    for row in rows:
        mark = {'pass': 'ok', 'fail': 'not ok', 'not-run': 'not run'}[row['status']]
        print('%s - %s: %s' % (mark, row['id'], row['reason']), flush=True)
    for item in semantic:
        print('semantic (not an acceptance row) - %s: %s, exit %s' % (item['bundle'], item['verdict'], item['rc']), flush=True)
    print('acceptance table: %s; %s' % (status, doc['counts']), flush=True)
    return {'pass': 0, 'fail': 1, 'incomplete': 3}[status]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='command', required=True)
    c = sub.add_parser('control')
    c.add_argument('name', choices=sorted(list(REFUSED) + ['h1']))
    c.add_argument('--note', required=True, help='where the note of the change is written')
    c.add_argument('--contract', help='the acceptance record to change, or to read the fixture id from')
    c.add_argument('--cases', help='the cases to change')
    c.add_argument('--out', help='where the changed copy is written')
    c.add_argument('--tree', help='an extracted tree to put H1 back into')
    j = sub.add_parser('judge')
    j.add_argument('--runs', required=True)
    j.add_argument('--stage', required=True, choices=('contract', 'full'))
    j.add_argument('--out', required=True)
    a = ap.parse_args()
    return control(a) if a.command == 'control' else judge(a)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception:  # Whatever stopped this file is not a judgment.
        traceback.print_exc()
        sys.exit(2)
