#!/usr/bin/env python3
"""Accept the generated npm executable and its actual hook consumers, by layer.

One acceptance record (core-hook-standin.contract.json) owns what this run
expects: the fixture's exact command, the statement's own words, each ask's
full argv, the environment, the answers and their counts. It is selected by
digest outside this file, read, and checked against the fixture before any
executable or hook starts. A record that does not hold is a contract failure
with nothing launched. No expectation is taken from a run's output.

Layers, each with its own rows (pass, fail or not-run):

  contract    the record against the fixture and the collector's launch input
  executable  the generated npm run by its own shebang: what it answered,
              seen from outside, and the record it wrote, read from the file
  calls       each side's original call records against the record's
              expectation; take_calls and the bundle are compared to those
              records and are never the oracle
  admission   the completed manifest selected by digest
  replay      the canonical CLI gives the verdict and status this process got
  equivalence the canonical verdict itself; it never counts toward acceptance

A baseline run stops at the first failed layer and leaves what depends on it
not-run, naming the row it waits for. --planned-negative goes on past a failed
layer so the failure path itself is observed. A row nobody judged stays
not-run, and not-run is never a pass.

Run in a new authorized remote archive, with an externally selected observed
builder. No install command is executed. Call records keep their claim order,
which is not launch order.

Exit 0: every acceptance row passed. Exit 1: a row failed. Exit 3: nothing
failed and a row was not run. Exit 2: this runner could not do its work.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import traceback
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parent))
from core_hook import compare, evidence, observe
from core_hook.corpus import load_cases

HERE = Path(__file__).resolve().parent
FORMAT = 'core-hook-standin-acceptance/1'
RESULTS = 'core-hook-standin-results/1'
# The fixed ask contract and the rows a run owes. core-hook-standin-accept.py
# states the owed rows again on its own, so a row dropped here is missed there.
ASKS = ('prefix', 'root', 'config')
DIRECT = ('ordinary', 'sleep', 'nonzero')
CONTRACT = ('record', 'fixture', 'statement', 'asks', 'answers', 'launch-env', 'direct')
CALLS = ('records', 'argv', 'env', 'answer', 'scratch', 'launch', 'take-calls', 'bundle', 'scratch-source')
SIDES = {'native-reference': 'raw-reference', 'native-candidate': 'raw-candidate', 'bash-reference': 'raw-bash'}
BUNDLES = {'native-pair': {'native-reference': 'reference', 'native-candidate': 'candidate'},
           'bash-native': {'bash-reference': 'reference'}}
# A word every shell reads as written. The statement check splits the command
# at single spaces and reads no other form: it is not a shell reader.
INERT = re.compile(r'[A-Za-z0-9._/@:+,=%-]+')
NAME = re.compile(r'[A-Za-z_][A-Za-z0-9_]*')
EXIT = {'pass': 0, 'fail': 1, 'incomplete': 3}
CLI_EXIT = {'equal': 0, 'different': 1, 'unresolved': 1, 'invalid': 2}


def save(path, value):
    evidence.publish(path, evidence.encoded(value))


def same(errors, label, actual, expected):
    if actual != expected:
        errors.append({'field': label, 'actual': actual, 'expected': expected})


def name_of(row):
    return '/'.join(part for part in (row['layer'], row['case'], row['side']) if part)


class Rows:
    """Every row this run owes. A row is not-run until its own check judges it."""

    def __init__(self):
        self.rows = {}

    def owe(self, layer, cases, sides=(None,)):
        for case in cases:
            for side in sides:
                self.rows[(layer, case, side)] = {'layer': layer, 'case': case, 'side': side, 'status': 'not-run',
                                                  'reason': 'not reached', 'errors': [], 'raw': []}

    def judge(self, layer, case, side, errors, raw=(), **more):
        row = self.rows[(layer, case, side)]
        if row['status'] != 'not-run':
            raise ValueError('row judged twice: ' + name_of(row))
        reason = 'checked'
        if errors:
            first = errors[0]
            reason = '%s: %.200r, expected %.200r' % (first['field'], first.get('actual'), first.get('expected'))
            if len(errors) > 1:
                reason += ' (and %d more)' % (len(errors) - 1)
        row.update(more, status='fail' if errors else 'pass', reason=reason, errors=errors, raw=[str(p) for p in raw])
        return not errors

    def failed(self, layer):
        return next((name_of(r) for r in self.rows.values() if r['layer'] == layer and r['status'] == 'fail'), None)


# --- contract: the record against the fixture, before anything starts -----------------

def checked(errors, label, check, *args):
    """A malformed record is a contract failure, not a crash of this runner."""
    try:
        return check(errors, *args)
    except (KeyError, TypeError, IndexError, AttributeError, ValueError, observe.HarnessError) as e:
        errors.append({'field': label, 'actual': '%s: %s' % (type(e).__name__, e), 'expected': 'a well-formed record'})
        return None


def fixture_check(errors, record, cases_raw):
    fx = record['fixture']
    doc = json.loads(cases_raw.decode('utf-8'))
    found = [c for c in doc['cases'] if c.get('id') == fx['id']]
    same(errors, 'cases with this id', len(found), 1)
    if len(found) != 1:
        return None
    case = found[0]
    same(errors, 'case sha256', evidence.digest(case), fx['case_sha256'])
    same(errors, 'stand-in npm name', case.get('npm'), fx['npm'])
    same(errors, 'stand-in npm sha256', evidence.digest(doc['npm'][fx['npm']]), fx['npm_sha256'])
    same(errors, 'defaults sha256', evidence.digest(doc.get('defaults', {})), fx['defaults_sha256'])
    same(errors, 'accepted step', [len(case['steps']), fx['steps'], fx['step'], fx['hook'], fx['engine']], [1, 1, 0, 'pre', 'codex'])
    step = case['steps'][0]
    same(errors, 'hook', step.get('hook'), fx['hook'])
    same(errors, 'engine is left to this runner', 'engine' in step, False)
    same(errors, 'command', step.get('command'), fx['command'])
    sent = observe.step_payload(dict(step, engine=fx['engine']), step.get('command', ''))
    same(errors, 'payload', json.dumps(sent, ensure_ascii=False), json.dumps(fx['payload'], ensure_ascii=False))
    return doc['npm'][fx['npm']]


def statement_check(errors, record):
    st = record['statement']
    pairs = [(name, value) for name, value in st['assignments']]
    names, words = [name for name, _ in pairs], list(st['words'])
    same(errors, 'manager', st['manager'], 'npm')
    if not words:
        errors.append({'field': 'statement words', 'actual': words, 'expected': "the statement's own words after the manager"})
    for name, value in pairs:
        if not (isinstance(name, str) and NAME.fullmatch(name) and isinstance(value, str) and INERT.fullmatch(value)):
            errors.append({'field': 'assignment', 'actual': [name, value], 'expected': 'a name and a value every shell reads as written'})
    for word in words:
        if not (isinstance(word, str) and INERT.fullmatch(word) and not word.startswith('=')):
            errors.append({'field': 'statement word', 'actual': word, 'expected': 'a word every shell reads as written'})
    spelled = ' '.join(['%s=%s' % pair for pair in pairs] + [st['manager']] + words)
    same(errors, 'the declared statement is the fixture command', spelled, record['fixture']['command'])
    same(errors, 'assignment names once each', sorted(set(names)), sorted(names))
    same(errors, 'carried and code names', sorted(list(st['carried']) + list(st['code_names'])), sorted(names))
    return True


def expand(template, words, quiet):
    out = []
    for word in template:
        out.extend(words if word == '@W@' else quiet if word == '@Q@' else [word])
    return out


def asks_check(errors, record):
    """Each ask of the fixed contract once, its template complete. Returns each full argv, @S@ left open."""
    words, quiet = list(record['statement']['words']), list(record['quiet'])
    same(errors, 'quiet flags', bool(quiet) and all(isinstance(q, str) and bool(INERT.fullmatch(q)) for q in quiet), True)
    names = [ask['name'] for ask in record['asks']]
    for name in ASKS:
        same(errors, 'declarations of ask ' + name, names.count(name), 1)
    same(errors, 'asks outside the contract', sorted(set(names) - set(ASKS)), [])
    argvs = {}
    for ask in record['asks']:
        name, argv, head = ask['name'], ask['argv'], ask['answer']['selector']
        label = 'ask %s ' % name
        same(errors, label + 'count', [type(ask['count']).__name__, ask['count']], ['int', 1])
        if not (isinstance(argv, list) and all(isinstance(w, str) and w for w in argv) and isinstance(head, list) and head):
            errors.append({'field': label + 'argv', 'actual': argv, 'expected': 'words after a head'})
            continue
        same(errors, label + 'head', [argv[:len(head)], head[:1]], [head, [name]])
        same(errors, label + "carries the statement's words after its head", argv[len(head):len(head) + 1], ['@W@'])
        same(errors, label + 'ends with the quiet flags and the cache', argv[-3:], ['@Q@', '--cache', '@S@/cache'])
        same(errors, label + 'open places', [w for w in argv if any(mark in w for mark in ('@W@', '@Q@', '@S@'))],
             ['@W@', '@Q@', '@S@/cache'])
        argvs[name] = expand(argv, words, quiet)
    return argvs


def answers_check(errors, record, npm, argvs):
    """The record's answers are the fixture's, and each full argv selects its own."""
    answers, indexes = npm['answers'], []
    for ask in record['asks']:
        name, want = ask['name'], ask['answer']
        label = 'ask %s answer ' % name
        fixture = answers[want['index']]
        same(errors, label + 'in the fixture',
             {'argv': fixture.get('argv'), 'stdout': fixture.get('stdout', ''), 'stderr': fixture.get('stderr', ''),
              'exit': fixture.get('exit', 0), 'other': sorted(set(fixture) - {'argv', 'stdout', 'stderr', 'exit'})},
             {'argv': want['selector'], 'stdout': want['stdout'], 'stderr': want['stderr'], 'exit': want['exit'], 'other': []})
        if name in argvs:
            argv = argvs[name]
            chosen = next((i for i, a in enumerate(answers) if argv[:len(a.get('argv', []))] == a.get('argv', [])), None)
            same(errors, label + 'selected by the full argv', chosen, want['index'])
        indexes.append(want['index'])
    same(errors, 'answers once each', sorted(set(indexes)), sorted(indexes))
    return True


def projection(record, argvs, box, obs, dirs):
    """The record with this run's directories written in. @S@ stays open."""
    def put(text):
        return observe.fill(text.replace('@OBS@', obs).replace('@SYSTEM@', ':'.join(dirs)), box)
    call, scratch = record['call'], record['scratch']
    asks = {}
    for ask in record['asks']:
        answer = ask['answer']
        asks[ask['name']] = {'argv': argvs[ask['name']], 'head': answer['selector'], 'count': ask['count'],
                             'answer': answer['index'], 'stdout': put(answer['stdout']), 'stderr': put(answer['stderr']),
                             'exit': answer['exit']}
    return {'asks': asks, 'cwd': put(call['cwd']), 'env': {key: put(value) for key, value in call['env'].items()},
            'absent': list(call['absent']), 'inherited': list(call['inherited']),
            'statement_names': [name for name, _ in record['statement']['assignments']],
            'status': record['hook']['status'],
            'stdin': json.dumps(observe.fill(record['fixture']['payload'], box), ensure_ascii=False),
            'scratch': {'parent': put(scratch['parent']), 'leaf_prefix': scratch['leaf_prefix'], 'kind': scratch['kind']},
            'direct': record['direct']}


def launch_env_check(errors, record, argvs, cases, ctx, box, obs):
    """What an ask inherits is what the collector will launch the hook with."""
    st, call, fx = record['statement'], record['call'], record['fixture']
    case = next((c for c in load_cases([cases], 4096) if c['id'] == fx['id']), None)
    if case is None:
        errors.append({'field': 'case', 'actual': None, 'expected': fx['id']})
        return None
    case['steps'][fx['step']]['engine'] = fx['engine']
    expect = projection(record, argvs, box, obs, ctx.sysdirs)
    launch = observe.case_env(ctx, case, box, obs, case['steps'][fx['step']])
    values = dict((name, value) for name, value in st['assignments'])
    for name in st['carried']:
        same(errors, 'carried ' + name, call['env'].get(name), values[name])
    for name in st['code_names']:
        same(errors, 'code name ' + name, [name in call['env'], name in call['absent']], [False, True])
    same(errors, 'absent names', sorted(call['absent']), sorted(st['code_names']))
    same(errors, 'where each call variable comes from', sorted(call['env']),
         sorted(list(st['carried']) + list(call['inherited']) + ['PWD']))
    for name in call['inherited']:
        same(errors, 'hook launch ' + name, launch.get(name), expect['env'][name])
    for name in values:
        same(errors, 'hook launch has no ' + name, name in launch, False)
    same(errors, 'the ask runs where the command runs', [call['cwd'], call['env']['PWD']], [fx['payload']['cwd']] * 2)
    same(errors, 'hook status', record['hook']['status'], 'exit 0')
    return case, expect


def direct_check(errors, record):
    spec = record['direct']
    same(errors, 'direct cases', [case['name'] for case in spec['cases']], list(DIRECT))
    same(errors, 'direct head', [spec['argv'][:len(spec['selector'])], bool(spec['selector'])], [spec['selector'], True])
    kinds = {}
    for case in spec['cases']:
        answer = case['answer']
        code = answer.get('exit', 0)
        same(errors, case['name'] + ' answer',
             [isinstance(answer.get('stdout'), str) and bool(answer['stdout']), isinstance(answer.get('stderr', ''), str),
              type(code) is int and 0 <= code < 256, sorted(set(answer) - {'stdout', 'stderr', 'exit', 'sleep'})],
             [True, True, True, []])
        same(errors, case['name'] + ' is not the default answer',
             [answer.get('stdout') == spec['default'].get('stdout', ''), code == spec['default'].get('exit', 0)], [False, False])
        kinds[case['name']] = [code == 0, 0 < answer.get('sleep', 0) <= 1]
    same(errors, 'direct kinds (exit 0, sleeps)', kinds, {'ordinary': [True, False], 'sleep': [True, True], 'nonzero': [False, False]})
    return True


def contract(rows, a, ctx, box, obs):
    """Pin and read the record and check it against the fixture. Starts nothing.

    Returns the case and what the later layers compare against, or None."""
    raw = Path(a.contract).read_bytes()
    errors, record = [], None
    same(errors, 'record sha256', evidence.sha(raw), a.contract_sha256)
    if not errors:
        try:
            record = evidence.strict_load(raw.decode('utf-8'))
        except ValueError as e:
            errors.append({'field': 'record', 'actual': str(e), 'expected': 'strict JSON'})
        else:
            same(errors, 'format', record.get('format') if type(record) is dict else None, FORMAT)
    if not rows.judge('contract', 'record', None, errors, [a.contract]):
        return None
    done = {}

    def row(case, check, *args, raw=()):
        if any(arg is None for arg in args):
            return  # It waits for the row that failed to give it; it stays not-run.
        errors = []
        done[case] = checked(errors, case, check, *args)
        rows.judge('contract', case, None, errors, raw)

    row('fixture', fixture_check, record, Path(a.cases).read_bytes(), raw=[a.cases])
    row('statement', statement_check, record)
    row('asks', asks_check, record)
    row('answers', answers_check, record, done.get('fixture'), done.get('asks'))
    row('launch-env', launch_env_check, record, done.get('asks'), a.cases, ctx, box, obs)
    row('direct', direct_check, record)
    return done.get('launch-env')


# --- executable: the generated npm, by its own shebang --------------------------------

def direct(rows, out, dirs, spec, case, launches):
    name, answer = case['name'], case['answer']
    box = out / name
    for part in ('project', 'home', 'calls'):
        (box / part).mkdir(parents=True)
    npm = {'answers': [dict(answer, argv=spec['selector'])], 'default': spec['default']}
    observe.write_stub(str(box), npm, str(box / 'calls'))
    exe = box / 'stub/npm'
    code = exe.read_bytes()
    argv = [str(exe)] + spec['argv']
    env = dict(spec['env'], PATH=':'.join(dirs), HOME=str(box / 'home'), STANDIN_PROBE=name)
    cwd = str(box / 'project')
    save(box / 'launch.json', {'argv': argv, 'cwd': cwd, 'env': env, 'executable_sha256': evidence.sha(code),
                               'shebang': code.split(b'\n', 1)[0].decode('utf-8', 'replace')})
    launches['executable'] += 1
    try:
        run = subprocess.run(argv, cwd=cwd, env=env, capture_output=True, timeout=10)
        got = {'rc': run.returncode, 'stdout': run.stdout, 'stderr': run.stderr}
    except (OSError, subprocess.TimeoutExpired) as e:
        got = {'rc': None, 'stdout': b'', 'stderr': ('the executable did not answer: %s' % e).encode()}
    for ch in ('stdout', 'stderr'):
        evidence.publish(box / ch, got[ch])
    evidence.publish(box / 'rc', ('%s\n' % got['rc']).encode())
    seen = {'rc': got['rc'], 'stdout': got['stdout'].decode('utf-8', 'replace'), 'stderr': got['stderr'].decode('utf-8', 'replace')}
    # What it answered, seen from outside the executable.
    errors = []
    same(errors, 'executable mode', stat.S_IMODE(exe.stat().st_mode), 0o755)
    same(errors, 'rc', seen['rc'], answer.get('exit', 0))
    for ch in ('stdout', 'stderr'):
        same(errors, ch, seen[ch], answer.get(ch, ''))
    rows.judge('executable', 'response', name, errors, [box / 'launch.json', box / 'stdout', box / 'stderr', box / 'rc'],
               observed=seen, executable_sha256=evidence.sha(code))
    # The record it wrote, read from the file. No take_calls in this oracle.
    errors = []
    names = sorted(p.name for p in (box / 'calls').iterdir())
    same(errors, 'record files', [n for n in names if n.endswith('.json')], ['0.json'])
    same(errors, 'unfinished records', [n for n in names if n.endswith('.part')], [])
    if '0.json' in names:
        record = json.loads((box / 'calls/0.json').read_bytes())
        for key, expected in dict(argv=argv[1:], cwd=cwd, answer=0, exit=answer.get('exit', 0),
                                  stdout=answer.get('stdout', ''), stderr=answer.get('stderr', '')).items():
            same(errors, key, record.get(key), expected)
        for key, value in env.items():
            same(errors, 'env.' + key, record.get('env', {}).get(key), value)
        for path in (cwd, env['HOME']):
            st = os.stat(path)
            same(errors, 'paths.' + path, record.get('paths', {}).get(path),
                 {'kind': 'dir', 'ino': st.st_ino, 'dev': st.st_dev})
    rows.judge('executable', 'record', name, errors, [box / 'calls'])
    return evidence.sha(code)


# --- calls: each side's original records ----------------------------------------------

def captured_side(ctx, case, box, seed, obs, impl, side, out, launches):
    """Copy original record bytes before take_calls consumes them.

    This test-only reader leaves the collector and the records untouched.
    The original JSON is what calls_check reads; every hook start is counted.
    """
    original, start = observe.take_calls, observe.run_hook
    drains = []

    def capture(where, blobs):
        directory = out / ('drain-%d' % len(drains))
        directory.mkdir(parents=True)
        raw, names = {}, []
        for p in (Path(where) / 'npm').iterdir():
            evidence.publish(directory / p.name, p.read_bytes())
            names.append(p.name)
            if p.suffix == '.json':
                raw[int(p.stem)] = json.loads(p.read_bytes())
        drains.append({'records': raw, 'names': sorted(names)})
        return original(where, blobs)

    def counted(*args, **kwargs):
        launches['hook'] += 1
        return start(*args, **kwargs)

    try:
        observe.take_calls, observe.run_hook = capture, counted
        result = observe.run_side(ctx, case, box, seed, obs, impl, side)
    finally:
        observe.take_calls, observe.run_hook = original, start
    return result, drains


def part(record, key, kind):
    value = record.get(key)
    return value if isinstance(value, kind) else kind()


def bind_scratch(expected, actual):
    """@S@ from the one place the template leaves open; None if argv is not the template."""
    if len(actual) != len(expected):
        return None
    scratch = None
    for want, got in zip(expected, actual):
        if want.startswith('@S@'):
            leaf = want[len('@S@'):]
            if not isinstance(got, str) or not got.endswith(leaf) or len(got) == len(leaf):
                return None
            scratch = got[:-len(leaf)]
        elif want != got:
            return None
    return scratch


def unstamped(calls):
    return {call['seq']: {key: value for key, value in call.items() if key != 'seq'} for call in calls}


def calls_check(rows, label, expect, side, drains, raw_dir, shas):
    """One side's original records against the record's expectation.

    Three concurrently started asks may claim their records in any order, so
    each named ask is found by its head and checked once; the observed claim
    order is kept in the row and in the unmodified canonical comparison.
    """
    step, box = side['steps'][0], side['box']
    before = side['boundaries'][0]['entries']
    last = drains[-1] if drains else {'records': {}, 'names': []}
    raw, names = last['records'], last['names']
    pointer = [raw_dir / ('drain-%d' % (len(drains) - 1))] if drains else []

    def seen(path):
        entry = before.get(os.path.relpath(path, box), {})
        return {key: entry.get(key) for key in ('kind', 'ino', 'dev')}

    errors = []
    same(errors, 'record files', [n for n in names if n.endswith('.json')], ['%d.json' % n for n in range(len(ASKS))])
    same(errors, 'unfinished records', [n for n in names if n.endswith('.part')], [])
    same(errors, 'drains', len(drains), 2)
    same(errors, 'records before the hook', drains[0]['records'] if drains else None, {})
    picked = {name: [seq for seq in sorted(raw) if part(raw[seq], 'argv', list)[:len(ask['head'])] == ask['head']]
              for name, ask in expect['asks'].items()}
    same(errors, 'records per ask', {name: len(seqs) for name, seqs in picked.items()},
         {name: ask['count'] for name, ask in expect['asks'].items()})
    same(errors, 'records of no declared ask', [seq for seq in sorted(raw) if not any(seq in seqs for seqs in picked.values())], [])
    rows.judge('calls', 'records', label, errors, pointer, claim_order=[part(raw[seq], 'argv', list)[:1] for seq in sorted(raw)],
               launch_order='not independently observed')

    def one(errors, name):
        if len(picked[name]) != 1:
            errors.append({'field': name + ' records', 'actual': len(picked[name]), 'expected': 1})
            return None
        return raw[picked[name][0]]

    errors, bound = [], {}
    for name, ask in expect['asks'].items():
        record = one(errors, name)
        if record is None:
            continue
        scratch = bind_scratch(ask['argv'], part(record, 'argv', list))
        if scratch is None:
            errors.append({'field': name + ' argv', 'actual': record.get('argv'), 'expected': ask['argv']})
        else:
            bound[name] = scratch
    rows.judge('calls', 'argv', label, errors, pointer)

    errors = []
    for name in expect['asks']:
        record = one(errors, name)
        if record is None:
            continue
        env = part(record, 'env', dict)
        same(errors, name + ' cwd', record.get('cwd'), expect['cwd'])
        for key, value in expect['env'].items():
            same(errors, '%s env %s' % (name, key), env.get(key), value)
        for key in expect['absent']:
            same(errors, '%s env has no %s' % (name, key), key in env, False)
        same(errors, name + ' cwd object', part(record, 'paths', dict).get(expect['cwd']), seen(expect['cwd']))
    rows.judge('calls', 'env', label, errors, pointer)

    errors = []
    for name, ask in expect['asks'].items():
        record = one(errors, name)
        if record is None:
            continue
        for key in ('answer', 'stdout', 'stderr', 'exit'):
            same(errors, '%s %s' % (name, key), record.get(key), ask[key])
    rows.judge('calls', 'answer', label, errors, pointer,
               claim='the answer the stand-in recorded as selected; what the hook received from its child is not observed here')

    # @S@ was bound from the records, so these relations are what is checked of it.
    errors, facts, rule = [], {}, expect['scratch']
    for name in expect['asks']:
        if name not in bound:
            errors.append({'field': name + ' scratch', 'actual': None, 'expected': 'bound by the argv row'})
            continue
        scratch, paths = bound[name], part(raw[picked[name][0]], 'paths', dict)
        leaf, fact = os.path.basename(scratch), paths.get(scratch)
        fact = fact if isinstance(fact, dict) else {}
        same(errors, name + ' scratch parent', os.path.dirname(scratch), rule['parent'])
        same(errors, name + ' scratch parent object', paths.get(rule['parent']), seen(rule['parent']))
        same(errors, name + ' scratch leaf', [leaf.startswith(rule['leaf_prefix']), len(leaf) > len(rule['leaf_prefix'])], [True, True])
        same(errors, name + ' scratch object', [fact.get('kind'), type(fact.get('ino')) is int and fact['ino'] > 0, type(fact.get('dev')) is int],
             [rule['kind'], True, True])
        same(errors, name + ' scratch is new in this run', os.path.relpath(scratch, box) in before, False)
        facts[name] = [scratch, fact]
    if len(facts) == len(expect['asks']):
        same(errors, 'one scratch for every ask', list(facts.values()), [next(iter(facts.values()))] * len(facts))
    rows.judge('calls', 'scratch', label, errors, pointer, scratch=sorted(set(bound.values())))

    errors = []
    stub = before.get('stub/npm', {})
    same(errors, 'hook status', step['status'], expect['status'])
    same(errors, 'hook stdin', side['blobs'].get(step['stdin']).decode('utf-8', 'replace'), expect['stdin'])
    same(errors, 'hook cwd', step['cwd'], expect['cwd'])
    for key in expect['inherited']:
        same(errors, 'hook env ' + key, step['env'].get(key), expect['env'][key])
    for key in expect['statement_names']:
        same(errors, 'hook env has no ' + key, key in step['env'], False)
    same(errors, 'hook npm is the executable run directly', [stub.get('kind'), stub.get('mode'), [stub.get('blob')]],
         ['file', '0755', sorted(set(shas))])
    rows.judge('calls', 'launch', label, errors, [], hook_pid=step['pid'])

    errors = []
    if not raw:
        errors.append({'field': 'original records', 'actual': 0, 'expected': 'at least one to compare'})
    same(errors, 'take_calls records', unstamped(step['npm_calls']), raw)
    same(errors, 'take_calls order', [call['seq'] for call in step['npm_calls']], sorted(raw))
    same(errors, 'take_calls unfinished', step['incomplete_calls'], [])
    rows.judge('calls', 'take-calls', label, errors, pointer, date_calls=len(step['date_calls']))
    return {'raw': raw, 'picked': picked, 'bound': bound}


def scratch_source(result, side_name, expect, found):
    """The canonical consumer's own receipt for each call's scratch, against the original record."""
    errors = []
    receipts = [r for r in result['receipts'][side_name] if r['slot'] == 'npm-scratch']
    for name, ask in expect['asks'].items():
        if name not in found['bound']:
            errors.append({'field': name + ' scratch', 'actual': None, 'expected': 'bound by the argv row'})
            continue
        seq = found['picked'][name][0]
        fact = part(found['raw'][seq], 'paths', dict).get(found['bound'][name])
        fact = fact if isinstance(fact, dict) else {}
        place = 'step 0 npm call %d argv %d' % (seq, [w.startswith('@S@') for w in ask['argv']].index(True))
        same(errors, name + ' scratch receipt', [[r['status'], r['witness']] for r in receipts if r['place'] == place],
             [['ok', ['npm-call:step0#%d:%s:%s' % (seq, fact.get('dev'), fact.get('ino'))]]])
    return errors


# --- admission and replay --------------------------------------------------------------

def replay(doc, path, manifest, pin, out):
    """The canonical comparison here and through the CLI, from the same selected manifest."""
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
    replayed = json.loads(report.read_bytes()) if report.is_file() else {}
    return result, {'rc': run.returncode, 'report_exit': replayed.get('exit'),
                    'same_verdict': replayed.get('verdict_sha256') == compare.verdict_digest([row])}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--contract', default=str(HERE / 'core-hook-standin.contract.json'))
    ap.add_argument('--contract-sha256', required=True, help='external selection: the digest of the reviewed record')
    ap.add_argument('--cases', default=str(HERE / 'core-hook-cases.json'))
    ap.add_argument('--build-root')
    ap.add_argument('--build-pin')
    ap.add_argument('--out', required=True)
    ap.add_argument('--skip-bash', action='store_true', help='a planned negative needs only the native pair')
    ap.add_argument('--stop-after', choices=('contract', 'executable'), help='leave the later layers not-run')
    ap.add_argument('--planned-negative', metavar='NAME', help='go on past a failed layer; the failure path is the subject')
    a = ap.parse_args()
    if not a.stop_after and not (a.build_root and a.build_pin):
        ap.error('the hook layers need --build-root and --build-pin')
    out = Path(a.out).resolve()
    out.mkdir(parents=True, exist_ok=False)
    dirs = observe.system_path()
    ctx = SimpleNamespace(work=str(out), ref_root=str(HERE.parents[1]), sysdirs=dirs,
                          real_date=observe.first_on(dirs, 'date'), timeout=90, lang='C', provider_env={})
    sandbox = out / 'sandbox'
    box, seed, obs = (str(sandbox / name) for name in ('box', 'seed', 'observations'))
    sides = [label for label in SIDES if not (a.skip_bash and label == 'bash-reference')]
    bundles = [name for name in BUNDLES if not (a.skip_bash and name == 'bash-native')]
    rows = Rows()
    rows.owe('contract', CONTRACT)
    rows.owe('executable', ('response', 'record'), DIRECT)
    rows.owe('calls', CALLS, sides)
    for layer in ('admission', 'replay', 'equivalence'):
        rows.owe(layer, bundles)
    launches = {'executable': 0, 'hook': 0}
    inputs = {'contract': {'path': str(Path(a.contract).resolve()), 'selected': a.contract_sha256,
                           'read': evidence.sha(Path(a.contract).read_bytes())},
              'cases': {'path': str(Path(a.cases).resolve()), 'read': evidence.sha(Path(a.cases).read_bytes())},
              'runner': {'path': str(Path(__file__).resolve()), 'sha256': evidence.sha(Path(__file__).resolve().read_bytes())},
              'collector_sources': evidence.sources(), 'builder': a.build_pin, 'expectation_sha256': None, 'manifest': None}

    def finish(why='', after=None):
        stamp = evidence.digest(inputs)
        table = list(rows.rows.values())
        for row in table:
            if row['status'] == 'not-run':
                row.update(reason=why or 'not reached', after=after)
            row['inputs'] = stamp
        owed = [row for row in table if row['layer'] != 'equivalence']
        failed = [name_of(row) for row in owed if row['status'] == 'fail']
        not_run = [name_of(row) for row in owed if row['status'] == 'not-run']
        status = 'fail' if failed or not owed else 'incomplete' if not_run else 'pass'
        save(out / 'results.json', {
            'format': RESULTS, 'mode': 'planned-negative:' + a.planned_negative if a.planned_negative else 'baseline',
            'stop_after': a.stop_after, 'skip_bash': a.skip_bash, 'inputs': inputs, 'inputs_sha256': stamp,
            'launches': launches, 'rows': table,
            'acceptance': {'status': status, 'rows': len(owed), 'failed': failed, 'not_run': not_run},
            'semantic': [{key: row.get(key) for key in ('case', 'status', 'verdict', 'rc', 'red_channels', 'unresolved')}
                         for row in table if row['layer'] == 'equivalence'],
            'scope': 'stand-in executable, call records and faithful replay of one fixture; equivalence rows report the '
                     'canonical verdict and are not acceptance; launch order and what a hook received from its child are not observed'})
        for row in table:
            mark = {'pass': 'ok', 'fail': 'not ok', 'not-run': 'not run'}[row['status']]
            if row['layer'] == 'equivalence':
                mark = 'semantic (%s, not an acceptance row)' % row.get('verdict', 'not-run')
            print('%s - %s%s' % (mark, name_of(row), '' if row['status'] == 'pass' else ': ' + row['reason']), flush=True)
        print('acceptance: %s; executable launches %d, hook launches %d' % (status, launches['executable'], launches['hook']), flush=True)
        return EXIT[status]

    def stops(layer):
        return None if a.planned_negative else rows.failed(layer)

    accepted = contract(rows, a, ctx, box, obs)
    hit = rows.failed('contract')
    if hit or accepted is None:
        return finish('the contract did not hold, so nothing was launched', hit)
    case, expect = accepted
    inputs['expectation_sha256'] = evidence.publish(out / 'expectation.json', evidence.encoded(expect))
    if a.stop_after == 'contract':
        return finish('stopped after the contract layer, as asked')

    shas = [direct(rows, out, dirs, expect['direct'], item, launches) for item in expect['direct']['cases']]
    hit = stops('executable')
    if hit:
        return finish('a baseline row failed, so what depends on it was not run', hit)
    if a.stop_after == 'executable':
        return finish('stopped after the executable layer, as asked')

    spec = importlib.util.spec_from_file_location('standin_builder', HERE / 'core-hook-native.py')
    builder = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(builder)
    impl = builder.reuse(Path(a.build_root), out, 'observed', True, expected=a.build_pin)
    save(out / 'builder-selection.json', {'observed': a.build_pin})
    ctx.collection = collection = evidence.Collection(out / 'live')
    sandbox.mkdir()
    error = observe.build_seed(ctx, case, box, seed, obs)
    if error:
        raise ValueError(error)
    plan = [('native-reference', impl, 'reference'), ('native-candidate', impl, 'candidate')]
    if not a.skip_bash:
        plan.append(('bash-reference', observe.bash_impl('bash', str(HERE.parents[1])), 'reference'))
    taken, found = {}, {}
    for label, implementation, side_name in plan:
        taken[label], drains = captured_side(ctx, case, box, seed, obs, implementation, side_name, out / SIDES[label], launches)
        found[label] = calls_check(rows, label, expect, taken[label], drains, out / SIDES[label], shas)
    hit = stops('calls')
    if hit:
        return finish('a baseline row failed, so what depends on it was not run', hit)

    paths = {}
    for name in bundles:
        pair = {'reference': taken['bash-reference' if name == 'bash-native' else 'native-reference'],
                'candidate': taken['native-candidate']}
        doc = observe.bundle_doc(case, pair, {'collection_kind': 'live'})
        paths[name] = collection.out / (name + '.bundle.json')
        observe.write_bundle(str(paths[name]), doc)
        collection.bundle_written(paths[name], doc)
    manifest, pin = collection.finish()
    inputs['manifest'] = {'path': str(manifest), 'sha256': pin}
    save(out / 'consumer-selection.json', {'manifest': str(manifest), 'sha256': pin})
    print('completed manifest: %s %s' % (manifest, pin), flush=True)
    docs = {name: observe.read_bundle(str(paths[name])) for name in bundles}
    for name in bundles:
        for label, side_name in BUNDLES[name].items():
            errors = []
            if not found[label]['raw']:
                errors.append({'field': 'original records', 'actual': 0, 'expected': 'at least one to compare'})
            same(errors, 'bundle records', unstamped(docs[name]['sides'][side_name]['steps'][0]['npm_calls']), found[label]['raw'])
            rows.judge('calls', 'bundle', label, errors, [paths[name]])
    hit = stops('calls')
    if hit:
        return finish('a baseline row failed, so what depends on it was not run', hit)

    for name in bundles:
        admission = evidence.admit(docs[name], evidence.sha(paths[name].read_bytes()), manifest, pin)
        evidence.attach(docs[name], admission)
        errors = []
        same(errors, 'admission', admission['status'], 'accepted')
        rows.judge('admission', name, None, errors, [paths[name], manifest], admission=admission,
                   claim='the collected bytes and their launch relations are the selected run; not that the executable is healthy')
    hit = stops('admission')
    if hit:
        return finish('a baseline row failed, so what depends on it was not run', hit)

    for name in bundles:
        result, cli = replay(docs[name], paths[name], manifest, pin, out)
        for label, side_name in BUNDLES[name].items():
            rows.judge('calls', 'scratch-source', label, scratch_source(result, side_name, expect, found[label]),
                       [out / (paths[name].stem + '.in-process.json')])
        verdict = result['verdict']
        errors = []
        same(errors, 'CLI verdict is this process verdict', cli['same_verdict'], True)
        same(errors, 'CLI status', [cli['rc'], cli['report_exit']], [CLI_EXIT[verdict]] * 2)
        rows.judge('replay', name, None, errors, [out / (paths[name].stem + '.replay.json'), out / (paths[name].stem + '.rc')],
                   verdict=verdict, rc=cli['rc'], claim='the same verdict and status were replayed; a replayed different is not equal')
        errors = []
        same(errors, 'verdict', verdict, 'equal')
        rows.judge('equivalence', name, None, errors, [out / (paths[name].stem + '.in-process.json')], verdict=verdict,
                   rc=cli['rc'], red_channels=compare.red_channels(result), unresolved=len(result['unresolved']),
                   expectations=result['expectations'], acceptance=False)
    return finish()


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception:  # Whatever stopped the runner is not an acceptance failure.
        traceback.print_exc()
        sys.exit(2)
