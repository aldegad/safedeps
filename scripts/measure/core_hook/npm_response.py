"""safedeps core-hook-npm-response: which child answered which npm ask, and
what the pre hook did with that answer.

The existing stand-in npm (observe.py) records the answer it chose, then
claims a record number, then prints. So its record says what it meant to
print, the number says which child got to the directory first, and neither
says which response file the hook read for which role. This module observes
that link for the pre hook's first three asks, for one implementation at a
time, without changing the collector, the comparator or the product.

Every primitive fact keeps one of three states: observed with its value,
absent with the basis that says so, or unavailable with the operation that
did not answer and why. A derived comparison is a match, a mismatch of two
observed values, or incomparable. None, an error string or a last status is
never the whole of a state, and an incomparable channel never erases a
mismatch another channel shows.

Who writes what:

  stand-in    each child's own files: how it was called, the objects its
              descriptors are open on, its claim record, what it wrote, its
              planned exit status (self)
  observer    one thread per launch, the only writer of that launch's
              journal (one record file per fact, each written once) and of
              its blobs: every ps query whole (argv, outcome, stdout,
              stderr), every response file read step by step, every hold it
              let go, and a terminal record that says whether it finished,
              was stopped, or failed and where
  launch      the hook's call and the observer's lifetime: it reads the
              journal only after the observer thread has ended, and writes
              launch-end.json; an observer still alive after its wait is a
              pending lifetime, never a completed launch

A ps answer is read by read_ps alone, and a missing row means no process
only under a host fact record selected by digest (host_basis). A response
file's lstat and fstat are kept apart and compared; the pending record is
read by read_pending against the shapes the product writers give.

Nothing here judges while collecting. judge_launch() reads the files a
collection left, and the contract, and nothing else.
"""
import copy
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import threading
import time
import traceback

from . import evidence, observe

CONTRACT = 'core-hook-npm-response-contract/3'
LAUNCH = 'core-hook-npm-response-launch/2'
RECORD = 'core-hook-npm-response-record/1'
PSQ = 'core-hook-npm-response-ps/1'
PSHOST = 'core-hook-npm-response-ps-host/1'
MANIFEST = 'core-hook-npm-response-manifest/2'
RESULTS = 'core-hook-npm-response-results/3'
ROLES = ('prefix', 'root', 'config')
IMPLS = ('native', 'bash')
CONF = 'npm-response.json'
NOISE = ('_', 'SHLVL')
# How long a child waits at each hold before it goes on by itself.
HOLD_SECONDS = 3.0
# The observer's budget for imposing an order, counted from the start of its
# thread, before the hook starts: children's starts, file I/O and ps calls
# all spend it. Whether it fits the hook's own ask deadline is not measured.
ORDER_BUDGET = 2.5
# After the hook returned or the launch asked it to stop, the observer has
# this long to close; every wait and ps call it makes then is bounded by it.
CLOSE_BUDGET = 4.0
# How long the launch waits for the observer to end after the hook returned.
JOIN_SECONDS = 8.0
POLL = 0.002
EXIT_POLL_EVERY = 0.01
FINAL_POLLS = 5
TREE = ('pid', 'ppid', 'pgid', 'stat', 'lstart', 'command')
EXITQ = ('pid', 'stat', 'lstart')
PURPOSE_FIELDS = {'start': TREE, 'tree': TREE, 'exit': EXITQ, 'host-alive': EXITQ, 'host-gone': EXITQ, 'host-mixed': EXITQ}
EXITED = ('gone', 'zombie', 'pid-reused')
# The cause a writer puts beside an unknown answer: rust/src/pre/targets.rs
# fetch_after and scripts/safedeps-pre-guard.sh write "sourced" or nothing.
FETCH_CAUSES = ('sourced',)


class HarnessError(Exception):
    """This module could not do what it was asked; the caller exits 2."""


class StoreError(Exception):
    """Bytes this collection read could not be kept: the collection's own failure."""


class CollectStop(Exception):
    """A launch could not be completed; the collection stops with exit 2."""

    def __init__(self, reason, detail=None):
        super().__init__(reason)
        self.detail = detail or {}


class LifetimePending(Exception):
    """The observer of a launch is still running after the launch's wait."""

    def __init__(self, name, watcher, finish, cause):
        super().__init__('the observer of %s is still running after %s seconds' % (name, JOIN_SECONDS))
        self.name, self.watcher, self.finish, self.cause = name, watcher, finish, cause


def sha(data):
    return hashlib.sha256(data).hexdigest()


def write_json(path, doc):
    return evidence.publish(path, evidence.encoded(doc))


def read_json(path):
    with open(path, 'rb') as f:
        return evidence.strict_load(f.read().decode('utf-8', 'surrogateescape'))


def observed(value):
    return {'state': 'observed', 'value': value}


def absent(basis):
    return {'state': 'absent', 'basis': basis}


def unavailable(op, why):
    return {'state': 'unavailable', 'op': op, 'why': why}


def not_attempted(after):
    return {'state': 'not-attempted', 'after': after}


def os_error(e):
    return {'type': type(e).__name__, 'errno': getattr(e, 'errno', None), 'strerror': getattr(e, 'strerror', None) or str(e)}


def text(b):
    if isinstance(b, (bytes, bytearray)):
        return bytes(b).decode('utf-8', 'surrogateescape')
    return b if isinstance(b, str) else ''


# --- places ---------------------------------------------------------------------------

def places(box, system_dirs):
    return [('@PROJECT@', box + '/project'), ('@HOME@', box + '/home'), ('@STATE@', box + '/state'),
            ('@TMP@', box + '/tmp'), ('@BOX@', box), ('@SYSTEM@', ':'.join(system_dirs))]


def fill(value, where):
    if isinstance(value, str):
        for mark, txt in where:
            value = value.replace(mark, txt)
        return value
    if isinstance(value, list):
        return [fill(v, where) for v in value]
    if isinstance(value, dict):
        return {fill(k, where): fill(v, where) for k, v in value.items()}
    return value


def expand(template, words, quiet):
    out = []
    for word in template:
        out.extend(words if word == '@W@' else quiet if word == '@Q@' else [word])
    return out


def bind_scratch(template, argv):
    """@S@ from the one place the template leaves open; None if argv is not the template."""
    if not isinstance(argv, list) or len(argv) != len(template):
        return None
    scratch = None
    for want, got in zip(template, argv):
        if want.startswith('@S@'):
            leaf = want[len('@S@'):]
            if not isinstance(got, str) or not got.endswith(leaf) or len(got) == len(leaf):
                return None
            scratch = got[:-len(leaf)]
        elif want != got:
            return None
    return scratch


def launch_names(rec):
    return ['%s-%s' % (impl, s['name']) for impl in IMPLS for s in rec['scenarios']]


# --- the contract, before anything starts ---------------------------------------------------

EDITS = {'none': (), 'declare-shared-effect': ('effect',), 'empty': (), 'drop': ('role',), 'duplicate': ('role',),
         'exchange-descriptors': ('role', 'other'), 'move-to-other-group': ('role',), 'unobserve-output': ('role',),
         'follow-into-initial-scratch': (), 'pending-bytes': ('bytes',), 'pending-null': ('fields',),
         'pending-remove': (), 'pending-fetch': ('value',)}
SHAPES = {
    'absolute-path': lambda v: isinstance(v, str) and v.startswith('/') and '\n' not in v,
    'nonempty-string': lambda v: isinstance(v, str) and bool(v),
    'md5-hex': lambda v: isinstance(v, str) and len(v) == 32 and all(c in '0123456789abcdef' for c in v),
}


def contract_errors(rec):
    """What is wrong with the record on its own. Starts nothing."""
    errors = []

    def want(label, ok, actual=None):
        if not ok:
            errors.append({'field': label, 'actual': actual})
    want('format', rec.get('format') == CONTRACT, rec.get('format'))
    asks = rec.get('asks', {})
    want('asks', sorted(asks) == ['config', 'follow-config', 'prefix', 'root'], sorted(asks))
    for name, ask in asks.items():
        argv = ask.get('argv', [])
        want(name + ' role', ask.get('role') in ROLES and (ask.get('attempt') == 'follow' or ask.get('role') == name), ask.get('role'))
        want(name + ' attempt', ask.get('attempt') in ('initial', 'follow'), ask.get('attempt'))
        want(name + ' head', argv[:len(ask.get('head', []))] == ask.get('head') and bool(ask.get('head')), argv)
        want(name + ' open places', [w for w in argv if any(m in w for m in ('@W@', '@Q@', '@S@'))] == ['@W@', '@Q@', '@S@/cache'], argv)
        want(name + ' ends with the quiet flags and the scratch cache', argv[-3:] == ['@Q@', '--cache', '@S@/cache'], argv[-3:])
    by_place = {}
    for name, ask in asks.items():
        by_place.setdefault((tuple(ask.get('head', [])), ask.get('cwd')), []).append(name)
    want('each ask has its own head and cwd', all(len(v) == 1 for v in by_place.values()), by_place)
    for impl in IMPLS:
        slot = rec.get('slots', {}).get(impl, {})
        want(impl + ' initial slots', sorted(slot.get('initial', {})) == sorted(ROLES), slot.get('initial'))
        want(impl + ' initial slot names differ', len(set(slot.get('initial', {}).values())) == len(ROLES), slot.get('initial'))
        want(impl + ' follow slot', sorted(slot.get('follow', {})) == ['config'], slot.get('follow'))
        want(impl + ' err suffix', isinstance(slot.get('err'), str) and bool(slot.get('err')), slot.get('err'))
    shape = rec.get('pending_shape', {})
    rules = list(shape.get('identity', {}).values()) + list(shape.get('fields', {}).values())
    want('pending shape rules', bool(shape.get('identity')) and all(isinstance(r, list) or r in SHAPES or r == 'fetch-facts' for r in rules), shape)
    answers = rec.get('answers', {})
    names = [s.get('name') for s in rec.get('scenarios', [])]
    want('scenario names once each', len(set(names)) == len(names), names)
    for s in rec.get('scenarios', []):
        label = 'scenario %s ' % s.get('name')
        chosen = s.get('answers', {})
        want(label + 'answers name answers', all(v in answers for v in chosen.values()), chosen)
        want(label + 'answers every initial role', all(r in chosen for r in ROLES), sorted(chosen))
        want(label + 'follow answered only with a follow group', ('follow-config' in chosen) == ('follow' in s.get('groups', ['initial'])), s.get('groups'))
        for channel in ('stdout', 'stderr'):
            values = [answers.get(chosen.get(r), {}).get(channel) for r in ROLES]
            want(label + channel + ' differs by role', len(set(values)) == len(ROLES), values)
        for key in ('claim_order', 'release_order'):
            order = s.get(key)
            want(label + key, order is None or sorted(order) == sorted(ROLES), order)
            want(label + key + ' differs from the start order', order is None or list(order) != list(ROLES), order)
        want(label + 'claim and release orders go together', bool(s.get('claim_order')) == bool(s.get('release_order')), s.get('release_order'))
        want(label + 'release order or swap needs the barrier', s.get('barrier') or not (s.get('release_order') or s.get('swap_slots')), s.get('barrier'))
        swap = s.get('swap_slots')
        want(label + 'swap', swap is None or (len(swap) == 2 and len(set(swap)) == 2 and set(swap) <= set(ROLES)), swap)
        emit = s.get('emit', {})
        want(label + 'emit', set(emit) <= set(ROLES) and set(emit.values()) <= set(ROLES) and sorted(emit) == sorted(emit.values()), emit)
        want(label + 'expected verdict', s.get('expect', {}).get('verdict') in ('applicable', 'rejected', 'unresolved', 'not-applicable'), s.get('expect'))
        result = s.get('expect', {}).get('result')
        want(label + 'expected result', (isinstance(result, str) and result in rec.get('results', {}))
             or (isinstance(result, dict) and bool(result.get('differs')) and set(result['differs']) <= set(shape.get('fields', {}))), result)
    forced = [s for s in rec.get('scenarios', []) if s.get('claim_order')]
    want('two forced claim orders that differ', len(forced) >= 2 and len(set(tuple(s['claim_order']) for s in forced)) == len(forced),
         [s.get('claim_order') for s in forced])
    want('two forced completion orders that differ', len(forced) >= 2 and len(set(tuple(s['release_order']) for s in forced)) == len(forced),
         [s.get('release_order') for s in forced])
    controls = rec.get('declared', {}).get('controls', [])
    want('declared names once each', len({c.get('name') for c in controls}) == len(controls), [c.get('name') for c in controls])
    for c in controls:
        label = 'declared %s ' % c.get('name')
        want(label + 'from a scenario', c.get('from') in names, c.get('from'))
        edits = c.get('edits')
        want(label + 'edits', isinstance(edits, list) and bool(edits), edits)
        for e in edits or []:
            want(label + 'edit', isinstance(e, dict) and e.get('edit') in EDITS and all(k in e for k in EDITS.get(e.get('edit'), ())), e)
            if isinstance(e, dict) and e.get('role') is not None:
                want(label + 'edit role', e['role'] in ROLES and e.get('other', e['role']) in ROLES, e)
        exp = c.get('expect', {})
        want(label + 'expectation', bool(exp) and set(exp) <= {'verdict', 'must', 'result'} and ('verdict' in exp) == ('must' in exp)
             and exp.get('result', 'invalid') in ('invalid', 'valid-differs', 'not-different', 'expected', 'unexpected'), exp)
    checks = rec.get('controls', {})
    for layer in ('readers', 'adapters'):
        cases = checks.get(layer, [])
        want('controls %s' % layer, isinstance(cases, list) and bool(cases), layer)
    seen = [c.get('name') for layer in ('readers', 'adapters', 'copies', 'sensitivity') for c in checks.get(layer, [])]
    want('control names once each', len(set(seen)) == len(seen), seen)
    for c in checks.get('copies', []) + checks.get('sensitivity', []):
        for e in c.get('edits', []):
            want('control %s edit' % c.get('name'), all(isinstance(e.get(k), str) and e.get(k) for k in ('file', 'old', 'new')) and e['old'] != e['new'], e)
    return errors


# --- the stand-in npm -------------------------------------------------------------------------

# It records how it was called (self), then the objects its descriptors are
# open on (self), chooses its answer from argv and cwd alone, waits for the
# observer's go when the run gates claims, claims a number and writes the same
# record the existing stand-in writes, writes its bytes, says it wrote them,
# waits for the observer's release, and exits with its answer's status. It
# installs nothing and starts nothing. `emit` makes a planted fault: write
# another answer's bytes under this answer's record.
STANDIN = r'''#!%(python)s -I
# safedeps core-hook-npm-response: an observed stand-in npm.
import fcntl, hashlib, json, os, stat, sys, time
here = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(here, "%(conf)s")) as f:
    conf = json.load(f)
argv = sys.argv[1:]
cwd = os.getcwd()
env = {k: v for k, v in os.environ.items() if k not in conf["noise"]}
nonce = os.urandom(12).hex()
t_start = time.time_ns()

def kind(m):
    if stat.S_ISLNK(m): return "link"
    if stat.S_ISDIR(m): return "dir"
    if stat.S_ISREG(m): return "file"
    if stat.S_ISCHR(m): return "chr"
    if stat.S_ISFIFO(m): return "fifo"
    return "other"

def fd_fact(fd):
    try:
        st = os.fstat(fd)
    except OSError as e:
        return {"error": e.strerror, "errno": e.errno}
    out = {"kind": kind(st.st_mode), "dev": st.st_dev, "ino": st.st_ino, "size": st.st_size}
    try:
        out["path"] = os.fsdecode(fcntl.fcntl(fd, fcntl.F_GETPATH, bytes(1024)).split(b"\0", 1)[0])
    except (OSError, AttributeError, ValueError) as e:
        out["path_error"] = str(e)
    try:
        out["offset"] = os.lseek(fd, 0, os.SEEK_CUR)
    except OSError as e:
        out["offset_error"] = e.strerror
    return out

def fact(p):
    try:
        st = os.lstat(p)
    except OSError as e:
        return {"error": e.strerror, "errno": e.errno}
    return {"kind": kind(st.st_mode), "ino": st.st_ino, "dev": st.st_dev}

def publish(name, doc):
    part = os.path.join(conf["obs"], name + ".part")
    with open(part, "x") as f:
        json.dump(doc, f, sort_keys=True)
    os.rename(part, os.path.join(conf["obs"], name))

def wait_for(name):
    path = os.path.join(conf["obs"], name)
    deadline = time.monotonic() + conf["hold_seconds"]
    while not os.path.exists(path):
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.002)
    return True

def write_all(fd, data):
    view = memoryview(data)
    while view:
        view = view[os.write(fd, view):]

fds = {str(fd): fd_fact(fd) for fd in (0, 1, 2)}
paths = {}
for w in argv + list(env.values()) + [cwd]:
    for piece in w.split("="):
        if piece.startswith("/"):
            for p in (piece, os.path.dirname(piece)):
                paths.setdefault(p, fact(p))
which = None
for i, a in enumerate(conf["answers"]):
    if argv[:len(a["head"])] == a["head"] and cwd == a["cwd"]:
        which = i
        break
answer = conf["answers"][which] if which is not None else conf["default"]
emitted = answer
if which is not None and str(which) in conf["emit"]:
    emitted = conf["answers"][conf["emit"][str(which)]]
publish(nonce + ".started.json", {"nonce": nonce, "pid": os.getpid(), "ppid": os.getppid(), "pgid": os.getpgrp(),
        "argv": argv, "cwd": cwd, "env": env, "fds": fds, "paths": paths, "answer": which, "t_ns": t_start})
gated = wait_for(nonce + ".claim-go") if conf["claim_gate"] else None
n = 0
while True:
    name = os.path.join(conf["calls"], "%%d.json" %% n)
    try:
        os.close(os.open(name + ".claim", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600))
        fd = os.open(name + ".part", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        break
    except FileExistsError:
        n += 1
record = {"argv": argv, "cwd": cwd, "env": env, "paths": paths, "answer": which, "nonce": nonce,
          "stdout": answer.get("stdout", ""), "stderr": answer.get("stderr", ""), "exit": answer.get("exit", 0)}
with os.fdopen(fd, "w") as f:
    json.dump(record, f, sort_keys=True)
os.rename(name + ".part", name)
out_b = emitted.get("stdout", "").encode("utf-8", "surrogateescape")
err_b = emitted.get("stderr", "").encode("utf-8", "surrogateescape")
errors = {}
for fd, data in ((1, out_b), (2, err_b)):
    try:
        write_all(fd, data)
    except OSError as e:
        errors[str(fd)] = e.strerror
publish(nonce + ".written.json", {"nonce": nonce, "claim": n, "gated": gated, "write_errors": errors,
        "wrote": {"1": {"len": len(out_b), "sha256": hashlib.sha256(out_b).hexdigest()},
                  "2": {"len": len(err_b), "sha256": hashlib.sha256(err_b).hexdigest()}},
        "fds": {"1": fd_fact(1), "2": fd_fact(2)}, "exit": answer.get("exit", 0), "t_ns": time.time_ns()})
released = wait_for(nonce + ".release")
publish(nonce + ".exiting.json", {"nonce": nonce, "released": released, "exit": answer.get("exit", 0), "t_ns": time.time_ns()})
os._exit(answer.get("exit", 0))
'''


def standin_conf(rec, scenario, where, obs, calls):
    """The stand-in's answer table for one launch: each declared ask's head and
    physical cwd, and the answer the scenario gives it."""
    answers, index = [], {}
    for name in ('prefix', 'root', 'config', 'follow-config'):
        if name not in scenario['answers']:
            continue
        ask = rec['asks'][name]
        index[name] = len(answers)
        chosen = fill(rec['answers'][scenario['answers'][name]], where)
        answers.append({'ask': name, 'role': ask['role'], 'head': ask['head'], 'cwd': os.path.realpath(fill(ask['cwd'], where)),
                        'stdout': chosen['stdout'], 'stderr': chosen['stderr'], 'exit': chosen['exit']})
    emit = {str(index[role]): index[other] for role, other in scenario.get('emit', {}).items()}
    return {'obs': obs, 'calls': calls, 'noise': list(NOISE), 'answers': answers, 'emit': emit,
            'default': {'stdout': '', 'stderr': 'stand-in npm: no answer for this call\n', 'exit': 1},
            'claim_gate': bool(scenario.get('claim_order')), 'hold_seconds': HOLD_SECONDS}


# --- ps: one query kept whole, and its one reader ---------------------------------------------------
#
# macOS ps(1) says of -p only that it displays the processes that match the
# listed process IDs, and documents no exit status. So the reader asks of a
# query record: every field there with its type; the argv the one its
# purpose's fields, its targets and the collector's own pid (the sentinel)
# make; ps exited by itself with a status; nothing on stderr; every line read
# as the fields; the sentinel's row there; no row for a pid nobody asked
# about. Rows then are rows ps printed. A missing row says the pid has no
# process only under a host basis (host_basis), and only for a query whose
# status is the one that basis measured for an answer with a missing pid.

def ps_env():
    return dict(os.environ, LC_ALL='C')


def ps_argv(fields, pids):
    o = ','.join(f + '=' for f in fields)
    if pids is None:
        return ['ps', '-A', '-ww', '-o', o]
    return ['ps', '-ww', '-o', o, '-p', ','.join(str(p) for p in pids)]


def ps_query(purpose, fields, sentinel, targets, timeout):
    """One ps call: what was asked, and what came back or why nothing did.
    A query that does not end within its timeout is stopped by subprocess.run
    itself, as every ps call in this file has been."""
    pids = None if targets is None else [sentinel] + list(targets)
    argv = ps_argv(fields, pids)
    rec = {'format': PSQ, 'purpose': purpose, 'argv': argv, 'fields': list(fields), 'sentinel': sentinel,
           'targets': None if targets is None else list(targets), 'locale': 'C', 'timeout': timeout, 't0_ns': time.time_ns()}
    try:
        r = subprocess.run(argv, capture_output=True, timeout=timeout, env=ps_env())
    except subprocess.TimeoutExpired as e:
        rec.update(outcome={'kind': 'timeout'}, stdout=text(e.stdout), stderr=text(e.stderr))
    except (OSError, subprocess.SubprocessError) as e:
        rec.update(outcome={'kind': 'exception', 'type': type(e).__name__, 'error': str(e)}, stdout='', stderr='')
    else:
        rec.update(outcome={'kind': 'exit', 'rc': r.returncode} if r.returncode >= 0 else {'kind': 'signal', 'signal': -r.returncode},
                   stdout=text(r.stdout), stderr=text(r.stderr))
    rec['t1_ns'] = time.time_ns()
    return rec


def ps_line(line, fields):
    """(pid, row) of one ps line, or None if it does not read as <fields>."""
    parts = line.split()
    fixed = sum(5 if f == 'lstart' else 1 for f in fields if f != 'command')
    if not parts or not parts[0].isdigit():
        return None
    if ('command' in fields and len(parts) < fixed + 1) or ('command' not in fields and len(parts) != fixed):
        return None
    row, i = {}, 0
    for name in fields:
        if name == 'lstart':
            row[name] = ' '.join(parts[i:i + 5])
            if not parts[i + 4].isdigit():
                return None
            i += 5
        elif name == 'command':
            row[name] = ' '.join(parts[i:])
            i = len(parts)
        else:
            row[name] = parts[i]
            i += 1
    if any(not row[f].isdigit() for f in ('pid', 'ppid', 'pgid') if f in row):
        return None
    return int(parts[0]), row


PS_KEYS = (('format', str), ('purpose', str), ('argv', list), ('fields', list), ('sentinel', int), ('locale', str),
           ('outcome', dict), ('stdout', str), ('stderr', str), ('t0_ns', int), ('t1_ns', int))


def read_ps(rec, basis=None):
    """{'state': 'observed', 'rows', 'absence'} for a ps record that holds a
    complete answer to the question it names; otherwise unavailable."""
    if type(rec) is not dict:
        return unavailable('ps-record', 'not a ps record')
    for key, kind in PS_KEYS:
        if type(rec.get(key)) is not kind:
            return unavailable('ps-record', 'the record has no %s of its type' % key)
    targets = rec.get('targets', 'missing')
    if not (targets is None or (type(targets) is list and all(type(p) is int for p in targets))):
        return unavailable('ps-record', 'the record has no targets of their type')
    if rec['format'] != PSQ or rec['locale'] != 'C':
        return unavailable('ps-record', 'the record is not a C-locale ps query')
    fields = PURPOSE_FIELDS.get(rec['purpose'])
    if fields is None or tuple(rec['fields']) != fields or (targets is None) != (rec['purpose'] == 'tree'):
        return unavailable('ps-request', 'the fields or targets are not the ones a %r query asks' % rec['purpose'])
    pids = None if targets is None else [rec['sentinel']] + targets
    if rec['argv'] != ps_argv(fields, pids):
        return unavailable('ps-request', 'the argv is not the one its fields, targets and sentinel make')
    outcome = rec['outcome']
    if outcome.get('kind') != 'exit' or type(outcome.get('rc')) is not int:
        return unavailable('ps', 'ps did not exit by itself with a status: %r' % (outcome,))
    if rec['stderr'] != '':
        return unavailable('ps', 'ps wrote to stderr: %r' % (rec['stderr'][:200],))
    rows = {}
    for line in rec['stdout'].splitlines():
        if not line.strip():
            continue
        got = ps_line(line, fields)
        if got is None:
            return unavailable('ps', 'a line does not read as %s: %r' % (','.join(fields), line[:200]))
        if got[0] in rows:
            return unavailable('ps', 'the pid %d is printed twice' % got[0])
        rows[got[0]] = got[1]
    if rec['sentinel'] not in rows:
        return unavailable('ps', "the collector's own row is not there")
    if pids is not None and set(rows) - set(pids):
        return unavailable('ps', 'a row for a pid nobody asked about')
    absence = None
    if basis is not None and pids is not None and outcome.get('rc') == basis.get('absent_rc'):
        absence = basis
    return {'state': 'observed', 'rows': rows, 'absence': absence}


def exit_reading(read, pid, start_lstart):
    """Whether the process that was <pid> when it started has exited, from one
    read_ps answer: observed gone, zombie, pid-reused or alive; or unavailable."""
    if read.get('state') != 'observed':
        return unavailable('ps', read.get('why'))
    row = read['rows'].get(pid)
    if row is None:
        if read.get('absence'):
            return observed({'exit': 'gone', 'basis': read['absence']})
        return unavailable('ps-absence', 'no row for the pid, and no host basis says a missing row means no process')
    if start_lstart is None:
        return unavailable('attribution', 'the start time of the child was not read when it started')
    if row['lstart'] != start_lstart:
        return observed({'exit': 'pid-reused'})
    if row['stat'].startswith('Z'):
        return observed({'exit': 'zombie'})
    return observed({'exit': 'alive'})


def start_lstart(start_record):
    """The lstart a child's start query read for its pid, or None."""
    if not isinstance(start_record, dict):
        return None
    read = read_ps(start_record.get('ps'))
    pid = start_record.get('pid')
    if read.get('state') != 'observed' or pid not in read['rows']:
        return None
    return read['rows'][pid]['lstart']


def measure_ps_host():
    """The host fact: how this host's ps answers for a pid this process has
    just reaped, beside one that is alive. Its children end by themselves when
    their input closes; nothing is signalled."""
    sentinel = os.getpid()
    holder = [sys.executable, '-I', '-c', 'import sys; sys.stdin.buffer.read()']
    first = subprocess.Popen(holder, stdin=subprocess.PIPE)
    second = None
    try:
        alive = ps_query('host-alive', EXITQ, sentinel, [first.pid], 10.0)
        first.stdin.close()
        first_rc = first.wait(timeout=30)
        reaped = time.time_ns()
        second = subprocess.Popen(holder, stdin=subprocess.PIPE)
        gone = ps_query('host-gone', EXITQ, sentinel, [first.pid], 10.0)
        mixed = ps_query('host-mixed', EXITQ, sentinel, [first.pid, second.pid], 10.0)
    finally:
        for p in (first, second):
            if p is not None and p.poll() is None:
                p.stdin.close()
                p.wait(timeout=30)
    return {'format': PSHOST, 'sentinel': sentinel, 'first': first.pid, 'second': second.pid,
            'first_wait': {'rc': first_rc, 't_ns': reaped}, 'queries': {'alive': alive, 'gone': gone, 'mixed': mixed},
            'uname': os.uname().release, 'python': sys.version.split()[0]}


def host_basis(doc):
    """({'absent_rc'}, None) when a host fact record shows what an answer with
    a missing pid looks like on its host; (None, why) otherwise."""
    if type(doc) is not dict or doc.get('format') != PSHOST:
        return None, 'not a ps host fact record'
    sentinel, first, second = doc.get('sentinel'), doc.get('first'), doc.get('second')
    if not all(type(v) is int for v in (sentinel, first, second)) or len({sentinel, first, second}) != 3:
        return None, 'the record does not name three distinct pids'
    q = doc.get('queries') if type(doc.get('queries')) is dict else {}
    wait = doc.get('first_wait') if type(doc.get('first_wait')) is dict else {}
    expect = {'alive': [first], 'gone': [first], 'mixed': [first, second]}
    reads = {}
    for name, targets in expect.items():
        rec = q.get(name)
        if type(rec) is not dict or rec.get('targets') != targets or rec.get('sentinel') != sentinel:
            return None, 'the %s query is not the one asked' % name
        reads[name] = read_ps(rec)
        if reads[name].get('state') != 'observed':
            return None, 'the %s query did not answer: %s' % (name, reads[name].get('why'))
    if not (type(wait.get('t_ns')) is int and wait['t_ns'] < q['gone'].get('t0_ns', 0)):
        return None, 'the first child was not reaped before the gone query'
    if first not in reads['alive']['rows'] or reads['alive']['rows'][first]['stat'].startswith('Z'):
        return None, 'the alive query did not show the first child alive'
    if set(reads['gone']['rows']) != {sentinel}:
        return None, 'the gone query shows more than the collector'
    if set(reads['mixed']['rows']) != {sentinel, second}:
        return None, 'the mixed query does not show exactly the collector and the second child'
    if q['gone']['outcome']['rc'] != q['mixed']['outcome']['rc']:
        return None, 'the two answers with a missing pid end with different statuses'
    return {'absent_rc': q['gone']['outcome']['rc'], 'record': 'ps host fact'}, None


# --- response files: each step kept as it went -------------------------------------------------------

def kind_of(mode):
    return observe.kind_of(mode)


class FileOps:
    """The file operations a response-file read makes; a control passes another."""

    def lstat(self, path):
        return os.lstat(path)

    def open(self, path):
        return os.open(path, os.O_RDONLY | os.O_NOFOLLOW)

    def fstat(self, fd):
        return os.fstat(fd)

    def getpath(self, fd):
        return os.fsdecode(fcntl.fcntl(fd, fcntl.F_GETPATH, bytes(1024)).split(b'\0', 1)[0])

    def read(self, fd, n):
        return os.read(fd, n)

    def close(self, fd):
        os.close(fd)


FILE_OPS = FileOps()


def slot_fact(path, ops=FILE_OPS):
    """Each step of a response file's read, kept as it went: lstat, open,
    fstat, the kernel's name for the open file, the bytes. A step that did not
    answer leaves the ones before it as they were. Returns the fact and the
    bytes read (None when nothing was read)."""
    fact = {'path': path, 't_ns': time.time_ns()}
    try:
        st = ops.lstat(path)
    except OSError as e:
        fact['lstat'] = absent({'op': 'lstat', 'errno': e.errno}) if e.errno == errno.ENOENT else unavailable('lstat', os_error(e))
        fact.update({k: not_attempted('lstat') for k in ('open', 'fstat', 'getpath', 'read')})
        return fact, None
    fact['lstat'] = observed({'kind': kind_of(st.st_mode), 'dev': st.st_dev, 'ino': st.st_ino, 'size': st.st_size, 'nlink': st.st_nlink})
    try:
        fd = ops.open(path)
    except OSError as e:
        fact['open'] = unavailable('open', os_error(e))
        fact.update({k: not_attempted('open') for k in ('fstat', 'getpath', 'read')})
        return fact, None
    fact['open'] = observed(True)
    data = None
    try:
        try:
            st = ops.fstat(fd)
            fact['fstat'] = observed({'dev': st.st_dev, 'ino': st.st_ino, 'size': st.st_size})
        except OSError as e:
            fact['fstat'] = unavailable('fstat', os_error(e))
        try:
            fact['getpath'] = observed(ops.getpath(fd))
        except (OSError, ValueError, AttributeError) as e:
            fact['getpath'] = unavailable('getpath', os_error(e))
        try:
            chunks = []
            while True:
                chunk = ops.read(fd, 1 << 16)
                if not chunk:
                    break
                chunks.append(chunk)
            data = b''.join(chunks)
            fact['read'] = observed({'size': len(data), 'sha256': sha(data)})
        except OSError as e:
            fact['read'] = unavailable('read', os_error(e))
    finally:
        try:
            ops.close(fd)
        except OSError as e:
            fact['close'] = unavailable('close', os_error(e))
    return fact, data


def observe_slot(journal, store, record, path, ops=FILE_OPS):
    """Read one response file, write its record, then keep its bytes. Failing
    to keep the bytes is the collection's own failure: it is raised, after the
    record of what was read is written."""
    fact, data = slot_fact(path, ops)
    seq = journal.write('read', dict(record, fact=fact))
    if data is not None:
        store.put(data)
    return seq, fact


def fact_object(f):
    """(dev, ino) of an observed lstat or fstat fact, or None."""
    if isinstance(f, dict) and f.get('state') == 'observed' and isinstance(f.get('value'), dict):
        v = f['value']
        if type(v.get('dev')) is int and type(v.get('ino')) is int:
            return (v['dev'], v['ino'])
    return None


def compare(a, b):
    if a is None or b is None:
        return 'incomparable'
    return 'match' if a == b else 'mismatch'


def slot_reading(fact, blobs):
    """What one read of a response file shows: the lstat state, whether lstat
    and fstat named the same object, and the bytes, if they were read and
    kept. A mismatch stays a mismatch whatever else is missing."""
    if not isinstance(fact, dict):
        return {'lstat': 'unread', 'lstat_object': None, 'fstat_object': None, 'identity': 'incomparable', 'bytes': None}
    lst, fst = fact_object(fact.get('lstat')), fact_object(fact.get('fstat'))
    identity = compare(lst, fst)
    read = fact.get('read') if isinstance(fact.get('read'), dict) else {}
    data = None
    if read.get('state') == 'observed' and isinstance(read.get('value'), dict):
        data = blobs.get(read['value'].get('sha256'))
    return {'lstat': (fact.get('lstat') or {}).get('state', 'unread'), 'lstat_object': lst, 'fstat_object': fst,
            'identity': identity, 'bytes': data}


# --- the observer's own writers --------------------------------------------------------------------

class Store:
    """The blob writer of one launch; the observer is its only caller."""

    def __init__(self, directory):
        self.dir = Path(directory)
        self.dir.mkdir(parents=True, exist_ok=True)

    def put(self, data):
        digest = sha(data)
        path = self.dir / digest
        try:
            if path.exists():
                if sha(path.read_bytes()) != digest:
                    raise StoreError('a kept blob does not hold its digest: ' + digest)
                return digest
            evidence.publish(path, data)
        except StoreError:
            raise
        except Exception as e:
            raise StoreError('%s: %s' % (type(e).__name__, e)) from e
        return digest


class Journal:
    """The observer's records, each written once, in order. Nothing else writes here."""

    def __init__(self, directory):
        self.dir = Path(directory)
        self.dir.mkdir(parents=True)
        self.seq = 0

    def write(self, kind, doc):
        seq = self.seq
        self.seq += 1
        body = dict(doc, format=RECORD, kind=kind, seq=seq, t_ns=time.time_ns())
        evidence.publish(self.dir / ('%05d-%s.json' % (seq, kind)), evidence.encoded(body))
        return seq


# --- the observer ----------------------------------------------------------------------------------

class Observer(threading.Thread):
    """Watches one launch's stand-in children and decides when a held child
    goes on. It writes its journal and blobs and nothing else; the launch
    reads them only after this thread has ended. It is not a daemon: a
    process that started it lives until it ends."""

    def __init__(self, rec, scenario, impl, where, obs_dir, calls_dir, journal, store, basis):
        super().__init__(daemon=False, name='npm-response-observer')
        self.rec, self.scenario, self.impl, self.where = rec, scenario, impl, where
        self.obs_dir, self.calls_dir, self.journal, self.store, self.basis = obs_dir, calls_dir, journal, store, basis
        self.words, self.quiet = rec['statement']['words'], rec['quiet']
        self.sentinel = os.getpid()
        self.children = {}
        self.claims_done = not scenario.get('claim_order')
        self.barrier_done = not scenario.get('barrier')
        self.order_active = bool(scenario.get('claim_order') or scenario.get('barrier'))
        self.order_until = None
        self.close_until = None
        self.last_poll = 0.0
        self.hook_done = threading.Event()
        self.stop = threading.Event()
        self.fatal = None

    # --- time ---
    def ending(self):
        return self.hook_done.is_set() or self.stop.is_set()

    def ordering(self):
        return self.order_active

    def left(self):
        if self.close_until is not None:
            return self.close_until - time.monotonic()
        if self.ordering():
            return self.order_until - time.monotonic()
        return 10.0

    def ps_timeout(self):
        return max(0.2, min(10.0, self.left()))

    # --- reading children ---
    def identify(self, doc):
        for name, ask in self.rec['asks'].items():
            template = expand(ask['argv'], self.words, self.quiet)
            scratch = bind_scratch(template, doc.get('argv'))
            if scratch is not None and doc.get('cwd') == os.path.realpath(fill(ask['cwd'], self.where)):
                return name, ask, scratch
        return None, None, None

    def slot_paths(self, ask, scratch):
        slots = self.rec['slots'][self.impl]
        name = slots[ask['attempt']][ask['role']]
        return scratch + '/' + name, scratch + '/' + name + slots['err']

    def read_slots(self, child, when, trigger):
        for channel, path in zip(('out', 'err'), child['slot_paths']):
            observe_slot(self.journal, self.store, {'child': child['nonce'], 'when': when, 'trigger': trigger, 'channel': channel}, path)

    def touch(self, nonce, what, why):
        path = os.path.join(self.obs_dir, nonce + '.' + what)
        with open(path, 'x'):
            pass
        self.journal.write('gate', {'what': what, 'child': nonce, 'why': why})

    def initial(self, role):
        found = [c for c in self.children.values() if c['ask'] is not None and c['ask']['attempt'] == 'initial' and c['ask']['role'] == role]
        return found[0] if len(found) == 1 else None

    # --- the thread ---
    def run(self):
        phase = 'start'
        self.order_until = time.monotonic() + ORDER_BUDGET
        try:
            self.journal.write('observer-start', {'sentinel': self.sentinel, 'scenario': self.scenario['name'], 'impl': self.impl,
                                                  'order_budget_seconds': ORDER_BUDGET, 'close_budget_seconds': CLOSE_BUDGET,
                                                  'basis': self.basis})
            while not self.ending():
                phase = 'scan'
                self.scan()
                time.sleep(POLL)
            phase = 'close'
            self.close_until = time.monotonic() + CLOSE_BUDGET
            self.scan()
            self.release_all('the launch is closing')
            self.final_polls()
            self.write_terminal('stopped' if self.stop.is_set() else 'finished', phase, None, [])
        except Exception as e:
            exc = {'type': type(e).__name__, 'error': str(e), 'phase': phase, 'traceback': traceback.format_exc()}
            cleanup = []
            try:
                self.release_all('the observer failed')
            except Exception as c:
                cleanup.append({'type': type(c).__name__, 'error': str(c)})
            self.fatal = {'exception': exc, 'cleanup_errors': cleanup}
            try:
                self.write_terminal('exception', phase, exc, cleanup)
            except Exception as w:
                self.fatal['terminal_write_error'] = {'type': type(w).__name__, 'error': str(w)}

    def write_terminal(self, state, phase, exc, cleanup):
        self.journal.write('terminal', {'state': state, 'phase': phase, 'exception': exc, 'cleanup_errors': cleanup,
                                        'children': sorted(self.children), 'released': sorted(n for n, c in self.children.items() if c['released']),
                                        'exited': sorted(n for n, c in self.children.items() if c['exited'])})

    def scan(self):
        names = sorted(os.listdir(self.obs_dir))
        for name in names:
            if name.endswith('.started.json'):
                nonce = name[:-len('.started.json')]
                if nonce not in self.children:
                    self.started(nonce)
        if not self.claims_done:
            self.gate_claims()
        for name in names:
            if name.endswith('.written.json'):
                child = self.children.get(name[:-len('.written.json')])
                if child is not None and not child['written']:
                    self.written(child)
        if not self.barrier_done:
            self.barrier()
        if time.monotonic() - self.last_poll >= EXIT_POLL_EVERY:
            self.poll_exits()

    def started(self, nonce):
        with open(os.path.join(self.obs_dir, nonce + '.started.json'), encoding='utf-8', errors='surrogateescape') as f:
            doc = json.load(f)
        name, ask, scratch = self.identify(doc)
        pid = doc.get('pid')
        query = ps_query('start', TREE, self.sentinel, [pid], self.ps_timeout()) if type(pid) is int else None
        child = {'nonce': nonce, 'pid': pid if type(pid) is int else None, 'ask': ask, 'scratch': scratch,
                 'slot_paths': self.slot_paths(ask, scratch) if ask else None, 'written': False, 'released': False, 'exited': False}
        self.children[nonce] = child
        record = {'child': nonce, 'pid': pid, 'ask': name, 'scratch': scratch, 'ps': query}
        self.journal.write('start', record)
        child['start_lstart'] = start_lstart(record)
        if self.scenario.get('claim_order') and (ask is None or self.claims_done):
            self.touch(nonce, 'claim-go', 'not held at the claim')

    def gate_claims(self):
        roles = [self.initial(r) for r in self.scenario['claim_order']]
        if any(c is None for c in roles):
            if self.left() <= 0 or self.ending():
                self.give_up('not every initial role started exactly once within the order budget')
            return
        self.claims_done = True
        for child in roles:
            self.touch(child['nonce'], 'claim-go', 'the imposed claim order')
            while not self.claimed(child['nonce']):
                if self.order_until - time.monotonic() <= 0 or self.ending():
                    self.give_up('the %s child did not claim within the order budget' % child['ask']['role'])
                    return
                time.sleep(POLL)
            self.journal.write('claimed', {'child': child['nonce']})
        for c in self.children.values():
            if not os.path.exists(os.path.join(self.obs_dir, c['nonce'] + '.claim-go')):
                self.touch(c['nonce'], 'claim-go', 'after the imposed claims')

    def claimed(self, nonce):
        for name in os.listdir(self.calls_dir):
            if name.endswith('.json'):
                try:
                    with open(os.path.join(self.calls_dir, name), encoding='utf-8', errors='surrogateescape') as f:
                        if json.load(f).get('nonce') == nonce:
                            return True
                except (OSError, ValueError):
                    continue
        return False

    def written(self, child):
        child['written'] = True
        if child['slot_paths']:
            self.read_slots(child, 'written', child['nonce'])
        self.journal.write('tree', {'trigger': child['nonce'], 'ps': ps_query('tree', TREE, self.sentinel, None, self.ps_timeout())})
        held = not self.barrier_done and child['ask'] is not None and child['ask']['attempt'] == 'initial'
        if not held:
            if child['slot_paths']:
                self.read_slots(child, 'release', child['nonce'])
            self.release(child, 'written; no barrier holds it')

    def barrier(self):
        held = [self.initial(r) for r in ROLES]
        if any(c is None or not c['written'] for c in held):
            if self.left() <= 0 or self.ending():
                self.give_up('not every initial role wrote within the order budget')
            return
        self.barrier_done = True
        swap = self.scenario.get('swap_slots')
        if swap:
            a, b = (self.initial(r) for r in swap)
            for pa, pb in zip(a['slot_paths'], b['slot_paths']):
                spare = pa + '.npmresp-swap'
                for src, dst in ((pa, spare), (pb, pa), (spare, pb)):
                    os.rename(src, dst)
                    self.journal.write('swap', {'roles': list(swap), 'rename': [src, dst]})
        for child in held:
            self.read_slots(child, 'release', 'barrier')
        order = self.scenario.get('release_order')
        if not order:
            for child in held:
                self.release(child, 'the barrier')
            self.order_active = False
            return
        for role in order:
            child = self.initial(role)
            self.release(child, 'the imposed completion order')
            while not child['exited']:
                self.poll_exits(only=[child])
                if child['exited']:
                    break
                if self.order_until - time.monotonic() <= 0 or self.ending():
                    # The next child is not let go on the strength of an exit nobody read.
                    self.give_up('the exit of the %s child was not read in a ps answer within the order budget' % role)
                    return
                time.sleep(POLL)
        self.order_active = False

    def give_up(self, why):
        """Stop imposing an order: say why, and let every held child that wrote
        go. A child that has not written yet goes at its own written event,
        after its files were read, as in a launch with no order. These
        releases are no evidence that any earlier child exited."""
        self.claims_done = self.barrier_done = True
        self.order_active = False
        self.journal.write('give-up', {'why': why})
        for c in self.children.values():
            if self.scenario.get('claim_order') and not os.path.exists(os.path.join(self.obs_dir, c['nonce'] + '.claim-go')):
                self.touch(c['nonce'], 'claim-go', 'order not imposed')
            if c['written'] and not c['released']:
                if c['slot_paths']:
                    self.read_slots(c, 'release', 'give-up')
                self.release(c, 'order not imposed')

    def release(self, child, why):
        """Let a held child go. It counts as released only once its marker is written."""
        if child['released']:
            return
        self.touch(child['nonce'], 'release', why)
        child['released'] = True

    def release_all(self, why):
        for child in self.children.values():
            if not child['released']:
                self.release(child, why)

    def poll_exits(self, only=None):
        waiting = [c for c in (only or self.children.values()) if c['released'] and not c['exited'] and c['pid'] is not None]
        self.last_poll = time.monotonic()
        if not waiting:
            return
        query = ps_query('exit', EXITQ, self.sentinel, [c['pid'] for c in waiting], self.ps_timeout())
        read = read_ps(query, self.basis)
        readings = {c['nonce']: exit_reading(read, c['pid'], c['start_lstart']) for c in waiting}
        seq = self.journal.write('exit-poll', {'children': [c['nonce'] for c in waiting], 'ps': query, 'readings': readings})
        for c in waiting:
            r = readings[c['nonce']]
            if r['state'] == 'observed' and r['value']['exit'] in EXITED:
                c['exited'] = True
                self.journal.write('exited', {'child': c['nonce'], 'poll': seq, 'reading': r})

    def final_polls(self):
        for _ in range(FINAL_POLLS):
            if self.close_until - time.monotonic() <= 0:
                return
            if not [c for c in self.children.values() if c['released'] and not c['exited'] and c['pid'] is not None]:
                return
            self.poll_exits()
            time.sleep(0.05)


# --- one launch -------------------------------------------------------------------------------------

def hook_env(rec, where):
    return fill(rec['hook']['env'], where)


def journal_records(directory):
    """Every record of an observer journal, in order."""
    out = []
    d = Path(directory)
    if d.is_dir():
        for p in sorted(d.iterdir()):
            if p.name.endswith('.json'):
                out.append(read_json(p))
    return out


def launch(ctx, rec, impl, hook, scenario, base, basis):
    """One implementation's pre hook under one scenario, kept whole under <base>.
    Returns only when the hook returned and the observer ended and its records
    were handed over; otherwise raises CollectStop or LifetimePending."""
    name = '%s-%s' % (impl, scenario['name'])
    d = base / name
    box, obs, calls = d / 'box', d / 'obs', d / 'calls'
    for p in (obs, calls, box / 'stub'):
        p.mkdir(parents=True)
    for rel in rec['sandbox']['dirs']:
        (box / rel).mkdir(parents=True, exist_ok=True)
    if os.path.realpath(str(box)) != str(box):
        raise HarnessError('the sandbox is not a physical path: %s' % box)
    where = places(str(box), ctx.sysdirs)
    for rel, txt in rec['sandbox']['files'].items():
        path = box / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(fill(txt, where).encode('utf-8'))
    conf = standin_conf(rec, scenario, where, str(obs), str(calls))
    conf_bytes = evidence.encoded(conf)
    (box / 'stub' / CONF).write_bytes(conf_bytes)
    code = STANDIN % {'python': sys.executable, 'conf': CONF}
    (box / 'stub' / 'npm').write_text(code, encoding='utf-8')
    os.chmod(box / 'stub' / 'npm', 0o755)
    env = hook_env(rec, where)
    payload = fill(rec['hook']['payload'], where)
    data = json.dumps(payload, ensure_ascii=False).encode('utf-8')
    cwd = fill(rec['hook']['cwd'], where)
    before = evidence.before_launch(hook, env, cwd)
    journal, store = Journal(d / 'observer'), Store(d / 'blobs')
    watcher = Observer(rec, scenario, impl, where, str(obs), str(calls), journal, store, basis)
    write_json(d / 'launch.json', {
        'format': LAUNCH, 'impl': impl, 'scenario': scenario['name'], 'argv': hook['argv'], 'env': env, 'cwd': cwd,
        'stdin': data.decode('utf-8'), 'box': str(box), 'system_dirs': ctx.sysdirs, 'collector_pid': os.getpid(),
        'standin_sha256': sha(code.encode('utf-8')), 'standin_python': sys.executable, 'conf_sha256': sha(conf_bytes),
        'executable_before': before, 'hook_files': ctx.hook_files[impl], 'basis': basis,
        'budgets': {'order': ORDER_BUDGET, 'close': CLOSE_BUDGET, 'join': JOIN_SECONDS, 'hold': HOLD_SECONDS}})
    result, failure = None, None
    watcher.start()
    try:
        if hook.get('native_receipt', {}).get('tapped'):
            from .native import run_observed
            result = run_observed(observe.run_hook, hook['argv'], data, env, cwd, ctx.timeout)
        else:
            result = observe.run_hook(hook['argv'], data, env, cwd, ctx.timeout)
    except BaseException as e:
        failure = e
        watcher.stop.set()
    finally:
        watcher.hook_done.set()
        watcher.join(JOIN_SECONDS)

    def finish():
        """Hand over the launch once the observer has ended: what the hook left,
        and what the observer's journal ends with."""
        end = {'format': LAUNCH, 'observer': {'ended': not watcher.is_alive(), 'fatal': watcher.fatal}, 'failure': None, 'hook': None}
        if failure is not None:
            end['failure'] = {'type': type(failure).__name__, 'error': str(failure)}
        if result is not None:
            for fname, value in (('hook.stdout', result['out']), ('hook.stderr', result['err'])):
                evidence.publish(d / fname, value)
            if 'native_raw' in result:
                evidence.publish(d / 'native.raw', result['native_raw'])
            end['hook'] = {'status': result['status'], 'pid': result['pid'], 't0_ns': result['t0_ns'], 't1_ns': result['t1_ns']}
        records = journal_records(d / 'observer')
        terminal = records[-1] if records and records[-1].get('kind') == 'terminal' else None
        end['observer']['terminal'] = None if terminal is None else {k: terminal.get(k) for k in ('state', 'phase', 'exception', 'cleanup_errors', 'seq')}
        try:
            end['executable_after'] = evidence.after_launch(hook, env, cwd, before)
        except ValueError as e:
            end['executable_after'] = {'error': str(e)}
        write_json(d / 'launch-end.json', end)
        return end, terminal

    if watcher.is_alive():
        raise LifetimePending(name, watcher, finish, failure)
    end, terminal = finish()
    if failure is not None:
        raise CollectStop('the launch %s failed while its hook ran: %s: %s' % (name, type(failure).__name__, failure),
                          {'launch': name, 'failure': end['failure']})
    if terminal is None or terminal.get('state') != 'finished':
        raise CollectStop('the observer of %s did not finish: %s' % (name, terminal.get('exception') if terminal else watcher.fatal),
                          {'launch': name, 'observer': end['observer']})
    if 'error' in end['executable_after']:
        raise CollectStop('the executable or its source changed during %s: %s' % (name, end['executable_after']['error']), {'launch': name})
    return {'launch': name, 'status': end['hook']['status'], 'terminal_seq': terminal.get('seq')}


# --- the manifest ---------------------------------------------------------------------------------

def tree_listing(root, skip=()):
    files, links, dirs = {}, {}, []
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        dirnames.sort()
        for name in dirnames + sorted(filenames):
            p = os.path.join(dirpath, name)
            rel = os.path.relpath(p, root)
            if rel in skip:
                continue
            st = os.lstat(p)
            if stat.S_ISLNK(st.st_mode):
                links[rel] = os.readlink(p)
            elif stat.S_ISDIR(st.st_mode):
                dirs.append(rel)
            elif stat.S_ISREG(st.st_mode):
                with open(p, 'rb') as f:
                    files[rel] = sha(f.read())
            else:
                links[rel] = 'not a file: mode %o' % st.st_mode
    return {'files': files, 'links': links, 'dirs': dirs}


# --- the pending record -----------------------------------------------------------------------------

def fetch_facts_problem(v):
    """None for an npm_fetch value a product writer makes, or why it is not one."""
    if not isinstance(v, dict):
        return 'npm_fetch is not an object'
    if 'unknown' in v:
        extra = sorted(set(v) - {'unknown', 'cause'})
        if extra:
            return 'an unknown answer carries other keys: %s' % extra
        if not isinstance(v['unknown'], str) or not v['unknown']:
            return 'the unknown reason is not a nonempty string'
        if 'cause' in v and v['cause'] not in FETCH_CAUSES:
            return 'the cause is not one a writer gives'
        return None
    if set(v) != {'registry', 'replace', 'scopes', 'test_registry'}:
        return 'a known answer has exactly registry, replace, scopes and test_registry'
    for key in ('registry', 'replace', 'test_registry'):
        if v[key] is not None and not isinstance(v[key], str):
            return '%s is neither a string nor null' % key
    if not isinstance(v['scopes'], dict) or any(not isinstance(k, str) or not isinstance(x, str) for k, x in v['scopes'].items()):
        return 'scopes is not an object of strings'
    return None


def shape_problem(rule, value):
    if isinstance(rule, list):
        return None if value in rule else 'not one of %r' % (rule,)
    if rule == 'fetch-facts':
        return fetch_facts_problem(value)
    return None if SHAPES[rule](value) else 'not %s' % rule


def read_pending(raw, shape, fields):
    """The pending record the hook wrote, if it has the identity and the named
    fields in the shapes the product writers give: {'state': 'valid',
    'record'}; otherwise {'state': 'invalid', 'why'}. A record that is not
    there, is not JSON or is not an object is invalid, never a value."""
    if raw is None:
        return {'state': 'invalid', 'why': ['the hook wrote no pending record']}
    try:
        doc = json.loads(raw.decode('utf-8'))
    except (ValueError, UnicodeDecodeError):
        return {'state': 'invalid', 'why': ['the pending record is not JSON']}
    if not isinstance(doc, dict):
        return {'state': 'invalid', 'why': ['the pending record is not an object']}
    why = []
    for key, rule in shape['identity'].items():
        problem = shape_problem(rule, doc.get(key))
        if problem:
            why.append('identity %s: %s' % (key, problem))
    for key in fields:
        if key not in doc:
            why.append('%s is not there' % key)
            continue
        problem = shape_problem(shape['fields'][key], doc[key])
        if problem:
            why.append('%s: %s' % (key, problem))
    return {'state': 'invalid', 'why': why} if why else {'state': 'valid', 'record': doc}


# --- the oracle ---------------------------------------------------------------------------------------
#
# judge_launch() reads one launch directory and the contract. It reads the
# stand-in's files and the observer's journal, and every ps answer and file
# read again with read_ps and slot_reading. It does not take the observer's
# identification of a child, its reading of an exit or its order of events
# as a fact about roles; an 'exited' record the judge's own reading does not
# support is a defect. A value that was not read raises an unobserved-*
# code; two values that were both read and differ raise a defect code.

DEFECT_FREE = ('shared-effect-declared',)


def unseen(code):
    base = code[len('follow-'):] if code.startswith('follow-') else code
    return base.startswith('unobserved-') or base == 'no-observations'


def load_view(d):
    """Everything a completed launch left, as plain data. Declared controls edit a copy of this."""
    d = Path(d)
    view = {'dir': str(d), 'launch': read_json(d / 'launch.json'), 'end': read_json(d / 'launch-end.json'),
            'stdout': (d / 'hook.stdout').read_bytes(), 'stderr': (d / 'hook.stderr').read_bytes(),
            'journal': journal_records(d / 'observer'), 'children': {}, 'calls': [],
            'conf': read_json(d / 'box' / 'stub' / CONF), 'blobs': {}}
    for p in sorted((d / 'obs').iterdir()):
        for suffix, key in (('.started.json', 'started'), ('.written.json', 'written'), ('.exiting.json', 'exiting')):
            if p.name.endswith(suffix):
                view['children'].setdefault(p.name[:-len(suffix)], {})[key] = read_json(p)
    for p in sorted((d / 'calls').iterdir(), key=lambda p: (len(p.name), p.name)):
        if p.name.endswith('.json'):
            doc = read_json(p)
            doc['_claim'] = int(p.name.split('.')[0])
            view['calls'].append(doc)
    for p in sorted((d / 'blobs').iterdir()):
        view['blobs'][p.name] = p.read_bytes()
    state = d / 'box' / 'state'
    view['state'] = {}
    if state.is_dir():
        for p in sorted(state.rglob('*')):
            if p.is_file() and not p.is_symlink():
                view['state'][str(p.relative_to(state))] = p.read_bytes()
    view['project'] = {}
    for p in sorted((d / 'box' / 'project').rglob('*')):
        if p.is_file() and not p.is_symlink():
            view['project'][str(p.relative_to(d / 'box' / 'project'))] = p.read_bytes()
    return view


def journal_index(view):
    idx = {'start': {}, 'reads': [], 'trees': {}, 'gates': [], 'polls': [], 'exited': [], 'swaps': [], 'giveups': [], 'terminal': None}
    for r in view['journal']:
        kind = r.get('kind')
        if kind == 'start':
            idx['start'][r.get('child')] = r
        elif kind == 'read':
            idx['reads'].append(r)
        elif kind == 'tree':
            idx['trees'][r.get('trigger')] = r
        elif kind == 'gate':
            idx['gates'].append(r)
        elif kind == 'exit-poll':
            idx['polls'].append(r)
        elif kind == 'exited':
            idx['exited'].append(r)
        elif kind == 'swap':
            idx['swaps'].append(r)
        elif kind == 'give-up':
            idx['giveups'].append(r)
        elif kind == 'terminal':
            idx['terminal'] = r
    return idx


def judge_launch(rec, scenario, view, basis, shared_effects=()):
    """The facts of one launch and the codes they raise. Each code names a
    role and what was wrong; the verdict is a function of the codes alone."""
    launch_doc = view['launch']
    impl = launch_doc['impl']
    where = places(launch_doc['box'], launch_doc['system_dirs'])
    words, quiet = rec['statement']['words'], rec['quiet']
    slots = rec['slots'][impl]
    idx = journal_index(view)
    codes = ['shared-effect-declared'] if shared_effects else []
    children = {}
    for nonce, docs in view['children'].items():
        started = docs.get('started')
        if not isinstance(started, dict):
            codes.append('unobserved-start:%s' % nonce)
            continue
        found = None
        for name, ask in rec['asks'].items():
            if name not in scenario['answers']:
                continue
            scratch = bind_scratch(expand(ask['argv'], words, quiet), started.get('argv'))
            if scratch is not None and started.get('cwd') == os.path.realpath(fill(ask['cwd'], where)):
                found = (name, ask, scratch)
                break
        if found is None:
            codes.append('unexpected-call')
            continue
        name, ask, scratch = found
        slot = scratch + '/' + slots[ask['attempt']][ask['role']]
        children[nonce] = {'nonce': nonce, 'ask_name': name, 'ask': ask, 'role': ask['role'], 'attempt': ask['attempt'],
                           'scratch': scratch, 'slot': {'out': slot, 'err': slot + slots['err']}, 'docs': docs}
    if not view['children']:
        codes.append('no-observations')
        return {'codes': sorted(set(codes)), 'verdict': verdict(codes), 'others': [], 'roles': {}, 'claim_order': [],
                'completion': [], 'initial_scratch': None, 'hook': hook_facts(rec, view, where)}
    groups = {}
    for c in children.values():
        groups.setdefault(c['scratch'], []).append(c)
    g1 = None
    for role in ROLES:
        holders = [c['scratch'] for c in children.values() if c['attempt'] == 'initial' and c['role'] == role]
        if holders:
            g1 = holders[0]
            break
    initial = groups.get(g1, [])
    if len({c['attempt'] for c in initial}) > 1:
        codes.append('group-mixed-attempt')
    by_role = {}
    for c in initial:
        if c['attempt'] == 'initial':
            by_role.setdefault(c['role'], []).append(c)
    for role in ROLES:
        n = len(by_role.get(role, []))
        if n == 0:
            codes.append('missing-role:%s' % role)
        elif n > 1:
            codes.append('duplicate-role:%s' % role)
    others = []
    declared = scenario.get('groups', ['initial'])
    for scratch, members in sorted(groups.items()):
        if scratch == g1:
            continue
        attempts = sorted({c['attempt'] for c in members})
        status = 'outside' if attempts == ['follow'] and 'follow' in declared else 'undeclared'
        if status == 'undeclared':
            codes.append('undeclared-group')
        others.append({'scratch': scratch, 'attempt': attempts[0] if len(attempts) == 1 else attempts,
                       'roles': sorted(c['role'] for c in members), 'status': status, 'members': [c['nonce'] for c in members]})
    exits = {n: exit_fact(idx, c, basis) for n, c in children.items()}
    expected = {name: fill(rec['answers'][answer], where) for name, answer in scenario['answers'].items()}
    roles = {}
    for scratch, members in groups.items():
        lone = {}
        for c in members:
            lone.setdefault((c['attempt'], c['role']), []).append(c)
        for c in members:
            if len(lone[(c['attempt'], c['role'])]) != 1:
                continue  # A duplicate is already a code; which copy is which is not read.
            facts, found = child_facts(c, members, expected, idx, view, exits[c['nonce']])
            for code in found:
                codes.append(code if c['attempt'] == 'initial' or scratch == g1 else 'follow-' + code)
            key = c['role'] if c['attempt'] == 'initial' and scratch == g1 else '%s@%s' % (c['ask_name'], c['nonce'][:8])
            roles[key] = facts
    for o in others:
        o['codes'] = sorted({code for m in o['members'] for code in roles.get('%s@%s' % (children[m]['ask_name'], m[:8]), {}).get('codes', [])})
        if o['status'] == 'outside' and o['codes']:
            o['status'] = 'rejected' if any(not unseen(c) for c in o['codes']) else 'unresolved'
            codes.append('follow-group-defect' if o['status'] == 'rejected' else 'follow-unobserved-group')
        del o['members']
    codes += request_checks(rec, children, view, where) + process_checks(children, view, idx, g1)
    codes = sorted(set(codes))
    claim = [c.get('nonce') for c in sorted(view['calls'], key=lambda r: r['_claim'])]
    return {'codes': codes, 'verdict': verdict(codes), 'others': others, 'roles': roles,
            'claim_order': [children[n]['role'] if n in children else '?' for n in claim],
            'completion': exit_order(children, exits, g1), 'initial_scratch': g1, 'hook': hook_facts(rec, view, where)}


def verdict(codes):
    """applicable: no code. rejected: any defect. unresolved: only what was not
    observed. not-applicable: only a declared shared effect."""
    if not codes:
        return 'applicable'
    base = [c[len('follow-'):] if c.startswith('follow-') else c for c in codes]
    missing = [c for c in codes if unseen(c)]
    defects = [c for c, b in zip(codes, base) if not unseen(c) and b not in DEFECT_FREE]
    if defects:
        return 'rejected'
    if missing:
        return 'unresolved'
    return 'not-applicable'


def own_object(started, fd):
    """(dev, ino) the child read for its own descriptor, or None."""
    f = (started.get('fds') or {}).get(fd) if isinstance(started, dict) else None
    if not isinstance(f, dict) or f.get('error') is not None or type(f.get('dev')) is not int or type(f.get('ino')) is not int:
        return None
    return (f['dev'], f['ino'])


def exit_fact(idx, c, basis):
    """The first exit the judge reads in the observer's polls for this child:
    ({'how', 't_ns', 'poll'}, None), or (None, why). Read again here."""
    nonce = c['nonce']
    pid = c['docs'].get('started', {}).get('pid')
    lstart = start_lstart(idx['start'].get(nonce))
    last = 'the observer kept no poll for this child'
    for poll in idx['polls']:
        if nonce not in (poll.get('children') or []):
            continue
        reading = exit_reading(read_ps(poll.get('ps'), basis), pid, lstart)
        if reading['state'] == 'observed' and reading['value']['exit'] in EXITED:
            return {'how': reading['value']['exit'], 't_ns': poll['ps'].get('t1_ns'), 'poll': poll.get('seq')}, None
        last = reading.get('why') if reading['state'] != 'observed' else 'the process was still there'
    return None, last


def child_facts(c, members, expected, idx, view, exit_seen):
    """One child, by its own records and by what the observer read."""
    docs, role, nonce = c['docs'], c['role'], c['nonce']
    codes, facts = [], {'nonce': nonce, 'ask': c['ask_name'], 'scratch': c['scratch'], 'slot': c['slot']}
    started, written = docs.get('started', {}), docs.get('written')
    mine = expected[c['ask_name']]
    group_answers = {m['role']: expected[m['ask_name']] for m in members}
    reads = idx['reads']
    for ch, fd in (('out', '1'), ('err', '2')):
        own = own_object(started, fd)
        facts[ch + '_object'] = own
        if own is None:
            codes.append('unobserved-desc-self:%s' % role)
        if isinstance(written, dict):
            later = own_object(written, fd)
            if later is None:
                codes.append('unobserved-desc-self:%s' % role)
            elif own is not None and later != own:
                codes.append('desc-changed:%s' % role)
        at_written = [r for r in reads if r.get('when') == 'written' and r.get('child') == nonce and r.get('channel') == ch]
        if not at_written:
            codes.append('unobserved-desc-object:%s' % role)
        else:
            fact = at_written[-1].get('fact')
            seen = slot_reading(fact, view['blobs'])
            facts[ch + '_at_written'] = {k: seen[k] for k in ('lstat', 'lstat_object', 'fstat_object', 'identity')}
            if seen['identity'] == 'mismatch':
                codes.append('slot-object-mismatch:%s' % role)
            if seen['lstat'] == 'absent':
                if own is not None:
                    codes.append('desc-object:%s' % role)
            elif compare(own, seen['lstat_object']) == 'mismatch':
                codes.append('desc-object:%s' % role)
            elif compare(own, seen['lstat_object']) == 'incomparable':
                codes.append('unobserved-desc-object:%s' % role)
            self_path = (started.get('fds', {}).get(fd) or {}).get('path')
            getpath = (fact or {}).get('getpath') if isinstance(fact, dict) else None
            seen_path = getpath.get('value') if isinstance(getpath, dict) and getpath.get('state') == 'observed' else None
            if not isinstance(self_path, str) or not isinstance(seen_path, str):
                codes.append('unobserved-desc-path:%s' % role)
            elif self_path != seen_path:
                codes.append('desc-path:%s' % role)
        released = [r for r in reads if r.get('when') == 'release' and isinstance(r.get('fact'), dict) and r['fact'].get('path') == c['slot'][ch]]
        if not released:
            codes.append('unobserved-output:%s' % role)
            continue
        seen = slot_reading(released[-1]['fact'], view['blobs'])
        facts[ch + '_at_release'] = {k: seen[k] for k in ('lstat', 'lstat_object', 'fstat_object', 'identity')}
        if seen['lstat'] == 'absent':
            codes.append('slot-absent:%s' % role)
            continue
        if seen['identity'] == 'mismatch':
            codes.append('slot-object-mismatch:%s' % role)
        elif seen['identity'] == 'incomparable':
            codes.append('unobserved-slot-object:%s' % role)
        known = [(m['role'], own_object(m['docs'].get('started', {}), fd)) for m in members]
        obj = seen['fstat_object']
        if obj is None:
            codes.append('unobserved-slot-holder:%s' % role)
        else:
            holder = [r for r, o in known if o is not None and o == obj]
            facts[ch + '_slot_holds'] = holder
            if holder == [role]:
                pass
            elif len(holder) == 1:
                codes.append('slot-holds:%s:%s' % (role, holder[0]))
            elif len(holder) > 1:
                codes.append('slot-shared-object:%s' % role)
            elif any(o is None for _, o in known):
                codes.append('unobserved-slot-holder:%s' % role)
            else:
                codes.append('slot-unknown-object:%s' % role)
        data = seen['bytes']
        if data is None:
            codes.append('unobserved-output:%s' % role)
            continue
        key = 'stdout' if ch == 'out' else 'stderr'
        txt = data.decode('utf-8', 'surrogateescape')
        facts[ch + '_content_sha256'] = sha(data)
        match = [r for r, a in sorted(group_answers.items()) if a[key] == txt]
        facts[ch + '_content_is'] = match
        prefix = 'content' if ch == 'out' else 'stderr-content'
        if match != [role]:
            codes.append('%s:%s:%s' % (prefix, role, match[0]) if len(match) == 1 else '%s-unexpected:%s' % (prefix, role))
    # The child's own output objects, wherever they ended up, against its
    # record: each channel on its own, so one that was not read cannot hide the other.
    records = [r for r in view['calls'] if r.get('nonce') == nonce]
    facts['claims'] = [r['_claim'] for r in records]
    if len(records) != 1:
        codes.append('record-missing:%s' % role if not records else 'record-duplicate:%s' % role)
    else:
        record = records[0]
        conf = view['conf']['answers']
        index = next((i for i, a in enumerate(conf) if a['ask'] == c['ask_name']), None)
        wanted = {'argv': started.get('argv'), 'cwd': started.get('cwd'), 'answer': index,
                  'stdout': mine['stdout'], 'stderr': mine['stderr'], 'exit': mine['exit']}
        bad = [k for k, v in wanted.items() if record.get(k) != v]
        if bad or index is None or conf[index]['stdout'] != mine['stdout'] or conf[index]['stderr'] != mine['stderr'] or conf[index]['exit'] != mine['exit']:
            codes.append('record:%s' % role)
            facts['record_fields_differ'] = bad
        differs = False
        for ch, fd, key in (('out', '1', 'stdout'), ('err', '2', 'stderr')):
            own = own_object(started, fd)
            if own is None:
                continue  # unobserved-desc-self says so
            hits = []
            for r in reads:
                if r.get('when') != 'release':
                    continue
                seen = slot_reading(r.get('fact'), view['blobs'])
                if seen['fstat_object'] == own and seen['bytes'] is not None:
                    hits.append((r['fact'].get('t_ns', 0), seen['bytes']))
            if not hits:
                codes.append('unobserved-output:%s' % role)
                continue
            if max(hits)[1] != record.get(key, '').encode('utf-8', 'surrogateescape'):
                differs = True
        if differs:
            codes.append('record-not-actual:%s' % role)
    # Its planned exit status, and an exit the judge reads in the observer's polls.
    seen_exit, why = exit_seen
    facts['exit_seen'] = seen_exit if seen_exit else {'unobserved': why}
    facts['exit_value_from_outside'] = 'not observed: only the parent receives an exit status'
    if seen_exit is None:
        codes.append('unobserved-exit:%s' % role)
    for r in idx['exited']:
        if r.get('child') == nonce and (seen_exit is None or r.get('poll') != seen_exit['poll']):
            if seen_exit is None or (isinstance(r.get('poll'), int) and r['poll'] < seen_exit['poll']):
                codes.append('observer-exit-unsupported:%s' % role)
    if not isinstance(written, dict):
        codes.append('unobserved-exit-planned:%s' % role)
    elif written.get('exit') != mine['exit']:
        codes.append('exit-planned:%s' % role)
    exiting = docs.get('exiting')
    facts['released_by_observer'] = bool(isinstance(exiting, dict) and exiting.get('released'))
    if not facts['released_by_observer']:
        codes.append('unobserved-release:%s' % role)
    facts['codes'] = sorted(set(codes))
    return facts, codes


def exit_order(children, exits, g1):
    """The initial children's exits as the judge read them, grouped by the
    poll that showed them: one poll that shows two exits does not order them."""
    seen = []
    for n, c in children.items():
        if c['scratch'] != g1 or c['attempt'] != 'initial':
            continue
        e, _ = exits[n]
        if e is not None:
            seen.append((e['poll'], e['t_ns'] or 0, c['role']))
    seen.sort()
    out, last = [], None
    for poll, _, role in seen:
        if poll == last:
            out[-1].append(role)
        else:
            out.append([role])
        last = poll
    return out


def order_status(scenario, view, facts):
    """A forced scenario's orders: ('pass' | 'fail' | 'unobserved', detail).
    The claim order is the records' numbers. The completion order is the exits
    the judge read, and it is the planned one only if each child after the
    first was let go after the exit before it was read."""
    plan_claim, plan_end = scenario['claim_order'], scenario['release_order']
    idx = journal_index(view)
    detail = {'claim_order': facts['claim_order'], 'completion': facts['completion'],
              'give_up': [g.get('why') for g in idx['giveups']]}
    roles = facts['roles']
    if any(r not in roles for r in ROLES):
        return 'unobserved', dict(detail, why='not every role has exactly one identified child')
    claimed = [r for r in facts['claim_order'] if r in ROLES]
    exits, released, polls = {}, {}, {}
    for r in ROLES:
        e = roles[r].get('exit_seen') or {}
        exits[r] = e.get('t_ns') if 'how' in e else None
        polls[r] = e.get('poll') if 'how' in e else None
        times = [g['t_ns'] for g in idx['gates'] if g.get('what') == 'release' and g.get('child') == roles[r]['nonce']]
        released[r] = min(times) if times else None
    detail.update(exits=exits, released=released)
    if claimed != plan_claim:
        if detail['give_up']:
            return 'unobserved', dict(detail, why='the claim order was not imposed')
        return 'fail', dict(detail, why='the claims came in another order than the one imposed')
    missing = [r for r in plan_end if exits[r] is None or released[r] is None]
    if missing:
        return 'unobserved', dict(detail, why='no exit or release read for %s' % ', '.join(missing))
    if len({polls[r] for r in ROLES}) != len(ROLES):
        return 'unobserved', dict(detail, why='one poll showed more than one exit, which orders nothing')
    for before, after in zip(plan_end, plan_end[1:]):
        if released[after] < exits[before]:
            return 'unobserved', dict(detail, why='%s was let go before the exit of %s was read' % (after, before))
    if sorted(plan_end, key=lambda r: exits[r]) != list(plan_end):
        return 'fail', dict(detail, why='the exits were read in another order than the releases')
    return 'pass', detail


def request_checks(rec, children, view, where):
    codes = []
    env = view['launch']['env']
    spec = rec['ask_env']
    rule = fill(rec['scratch'], where)
    for c in children.values():
        started, role = c['docs'].get('started', {}), c['role']
        got = started.get('env', {})
        for key in spec['inherited']:
            if got.get(key) != env.get(key):
                codes.append('request-env:%s:%s' % (role, key))
        if got.get('PWD') != fill(c['ask']['cwd'], where):
            codes.append('request-env:%s:PWD' % role)
        for key in spec['absent']:
            if key in got:
                codes.append('request-env:%s:%s' % (role, key))
        scratch = c['scratch']
        leaf = os.path.basename(scratch)
        if os.path.dirname(scratch) != rule['parent'] or not leaf.startswith(rule['leaf_prefix']) or len(leaf) <= len(rule['leaf_prefix']):
            codes.append('request-scratch:%s' % role)
        fact = started.get('paths', {}).get(scratch)
        if not isinstance(fact, dict) or fact.get('error') is not None:
            codes.append('unobserved-request-scratch-object:%s' % role)
        elif fact.get('kind') != 'dir':
            codes.append('request-scratch-object:%s' % role)
    return codes


def process_checks(children, view, idx, g1):
    """Each child's process in the ps tree the observer read when it wrote: its
    parent is the one it reported, and the hook's process is above it."""
    codes = []
    hook_pid = (view['end'].get('hook') or {}).get('pid')
    parents = {}
    for nonce, c in children.items():
        started, role = c['docs'].get('started', {}), c['role']
        tree = idx['trees'].get(nonce)
        read = read_ps(tree.get('ps')) if isinstance(tree, dict) else unavailable('tree', 'no tree was read')
        if read.get('state') != 'observed':
            codes.append('unobserved-process:%s' % role)
            continue
        rows = read['rows']
        row = rows.get(started.get('pid'))
        if row is None:
            exiting = c['docs'].get('exiting')
            held = isinstance(exiting, dict) and exiting.get('released')
            # A child whose own hold ran out may be gone already; then its absence is not a finding.
            codes.append('process-unseen:%s' % role if held else 'unobserved-process:%s' % role)
            continue
        if row['ppid'] != str(started.get('ppid')):
            codes.append('process-parent:%s' % role)
        if not row['command'].endswith(' ' + ' '.join(started.get('argv', []))):
            codes.append('process-command:%s' % role)
        chain, p, hops = [], row['ppid'], 0
        while p and p.isdigit() and int(p) in rows and hops < 64:
            chain.append(int(p))
            if int(p) == hook_pid:
                break
            p, hops = rows[int(p)]['ppid'], hops + 1
        if hook_pid not in chain:
            codes.append('process-not-under-hook:%s' % role)
        if c['scratch'] == g1 and c['attempt'] == 'initial':
            parents.setdefault(row['ppid'], []).append(role)
    if len(parents) > 1:
        codes.append('parents-differ')
    return codes


def pending_key(rec, view, where):
    return os.path.relpath(fill(rec['results']['positive']['pending']['path'], where), view['launch']['box'] + '/state')


def hook_facts(rec, view, where):
    state = view['state']
    hook = view['end'].get('hook') or {}
    out = {'status': hook.get('status'), 'stdout': view['stdout'].decode('utf-8', 'surrogateescape'),
           'stderr': view['stderr'].decode('utf-8', 'surrogateescape'), 'pending_raw': state.get(pending_key(rec, view, where)),
           'snapshot_meta': None, 'snapshot_package_json_sha256': None, 'advisory': None}
    pending = None
    if out['pending_raw'] is not None:
        try:
            pending = json.loads(out['pending_raw'].decode('utf-8'))
        except (ValueError, UnicodeDecodeError):
            pending = None
    sid = pending.get('snapshot_id') if isinstance(pending, dict) else None
    if isinstance(sid, str):
        meta = state.get('snapshots/%s_meta.json' % sid)
        if meta is not None:
            try:
                out['snapshot_meta'] = json.loads(meta.decode('utf-8'))
            except (ValueError, UnicodeDecodeError):
                out['snapshot_meta'] = {'unreadable': True}
        copy_ = state.get('snapshots/%s_package.json' % sid)
        out['snapshot_package_json_sha256'] = sha(copy_) if copy_ is not None else None
    log = state.get('advisory.log')
    if log is not None:
        out['advisory'] = [line.split('\t', 1)[1] if '\t' in line else line
                           for line in log.decode('utf-8', 'surrogateescape').splitlines()]
    return out


def result_errors(rec, name, view, facts):
    """The hook's result against a named expected result, read by read_pending first."""
    where = places(view['launch']['box'], view['launch']['system_dirs'])
    want = fill(rec['results'][name], where)
    got = facts['hook']
    errors = []

    def same(label, actual, expected):
        if actual != expected:
            errors.append({'field': label, 'actual': actual, 'expected': expected})
    same('hook status', got['status'], rec['hook']['status'])
    same('hook stdout', got['stdout'], rec['hook']['stdout'])
    same('hook stderr', got['stderr'], rec['hook']['stderr'])
    pending = read_pending(got['pending_raw'], rec['pending_shape'], sorted(rec['pending_shape']['fields']))
    if pending['state'] != 'valid':
        errors.append({'field': 'valid pending record', 'actual': pending['why'], 'expected': 'the shapes the writers give'})
        record = {}
    else:
        record = pending['record']
    for key, value in want['pending']['fields'].items():
        same('pending ' + key, record.get(key), value)
    same('pending dir_hash', record.get('dir_hash'), hashlib.md5(want['pending']['dir_hash_md5_of'].encode('utf-8')).hexdigest())
    meta = got['snapshot_meta'] if isinstance(got['snapshot_meta'], dict) else {}
    same('snapshot project_dir', meta.get('project_dir'), want['snapshot']['project_dir'])
    same('snapshot command', meta.get('command'), want['snapshot']['command'])
    source = view['project'].get(os.path.relpath(want['snapshot']['package_json_copy_of'], 'project'))
    same('snapshot package.json copy', got['snapshot_package_json_sha256'], sha(source) if source is not None else 'no source file')
    same('advisory lines', got['advisory'], want['advisory'])
    return errors


def differs_errors(rec, scenario, view, facts):
    """A negative's result: a pending record whose identity and judged fields
    have the writers' shapes, whose role-linked fields differ from the
    positive's, from a hook that still answered."""
    where = places(view['launch']['box'], view['launch']['system_dirs'])
    positive = fill(rec['results']['positive'], where)['pending']['fields']
    spec = fill(scenario['expect']['result'], where)
    got = facts['hook']
    errors = []
    if got['status'] != rec['hook']['status'] or got['stdout'] != rec['hook']['stdout']:
        errors.append({'field': 'the hook answered as in the positive', 'actual': [got['status'], got['stdout']],
                       'expected': [rec['hook']['status'], rec['hook']['stdout']]})
    pending = read_pending(got['pending_raw'], rec['pending_shape'], spec['differs'])
    if pending['state'] != 'valid':
        return errors + [{'field': 'valid pending record', 'actual': pending['why'], 'expected': 'the shapes the writers give'}], {}
    record = pending['record']
    for key in spec['differs']:
        if record[key] == positive.get(key):
            errors.append({'field': 'pending %s differs from the positive' % key, 'actual': record[key],
                           'expected': 'not %r' % (positive.get(key),)})
    predicted = {key: {'predicted': value, 'actual': record.get(key), 'held': record.get(key) == value}
                 for key, value in spec.get('predicted', {}).items()}
    return errors, predicted


def result_kind(rec, scenario, view, facts):
    """How a launch's hook result reads against its scenario's expected result."""
    result = scenario['expect']['result']
    if isinstance(result, str):
        return 'expected' if not result_errors(rec, result, view, facts) else 'unexpected'
    errors, _ = differs_errors(rec, scenario, view, facts)
    if any(e['field'] == 'valid pending record' for e in errors):
        return 'invalid'
    return 'valid-differs' if not errors else 'not-different'


# --- declared controls ------------------------------------------------------------------------------

def replace_text(value, old, new):
    if isinstance(value, str):
        return value.replace(old, new)
    if isinstance(value, list):
        return [replace_text(v, old, new) for v in value]
    if isinstance(value, dict):
        return {replace_text(k, old, new): replace_text(v, old, new) for k, v in value.items()}
    return value


def role_nonce(rec, scenario, view, basis, role, attempt='initial'):
    facts = judge_launch(rec, scenario, view, basis)
    if attempt == 'initial':
        return facts['roles'][role]['nonce'], facts['initial_scratch']
    for key, f in facts['roles'].items():
        if key.startswith('follow-config@'):
            return f['nonce'], f['scratch']
    raise HarnessError('no %s child of role %s' % (attempt, role))


def apply_edit(rec, scenario, v, basis, e):
    """One named edit of a launch's records, in place. Returns declared shared effects."""
    edit = e['edit']
    if edit == 'none':
        return []
    if edit == 'declare-shared-effect':
        return [e['effect']]
    if edit == 'empty':
        v['children'], v['calls'] = {}, []
        v['journal'] = [r for r in v['journal'] if r.get('kind') in ('observer-start', 'terminal')]
        return []
    where = places(v['launch']['box'], v['launch']['system_dirs'])
    if edit.startswith('pending-'):
        key = pending_key(rec, v, where)
        if edit == 'pending-remove':
            v['state'].pop(key, None)
        elif edit == 'pending-bytes':
            v['state'][key] = e['bytes'].encode('utf-8')
        else:
            doc = json.loads(v['state'][key].decode('utf-8'))
            if edit == 'pending-null':
                for name in e['fields']:
                    doc[name] = None
            else:
                doc['npm_fetch'] = e['value']
            v['state'][key] = json.dumps(doc).encode('utf-8')
        return []
    if edit == 'follow-into-initial-scratch':
        nonce, follow = role_nonce(rec, scenario, v, basis, 'config', attempt='follow')
        _, initial = role_nonce(rec, scenario, v, basis, 'prefix')
        v['children'][nonce] = replace_text(v['children'][nonce], follow, initial)
        v['calls'] = [replace_text(r, follow, initial) if r.get('nonce') == nonce else r for r in v['calls']]
        v['journal'] = [replace_text(r, follow, initial) if r.get('child') == nonce else r for r in v['journal']]
        return []
    nonce, scratch = role_nonce(rec, scenario, v, basis, e['role'])
    slot = scratch + '/' + rec['slots'][v['launch']['impl']]['initial'][e['role']]
    if edit == 'drop':
        v['children'].pop(nonce, None)
        v['calls'] = [r for r in v['calls'] if r.get('nonce') != nonce]
        v['journal'] = [r for r in v['journal'] if not (r.get('kind') == 'start' and r.get('child') == nonce)]
    elif edit == 'duplicate':
        twin = nonce + '-twin'
        v['children'][twin] = replace_text(v['children'][nonce], nonce, twin)
        record = [r for r in v['calls'] if r.get('nonce') == nonce][0]
        v['calls'].append(dict(replace_text(record, nonce, twin), _claim=max(r['_claim'] for r in v['calls']) + 1))
        extra = []
        for r in v['journal']:
            if r.get('child') == nonce or r.get('trigger') == nonce:
                extra.append(replace_text(r, nonce, twin))
            elif r.get('kind') == 'exit-poll' and nonce in (r.get('children') or []):
                r['children'] = r['children'] + [twin]
                r['readings'][twin] = r['readings'].get(nonce)
        v['journal'] += extra
    elif edit == 'exchange-descriptors':
        other, _ = role_nonce(rec, scenario, v, basis, e['other'])
        for key in ('started', 'written'):
            da, db = v['children'][nonce][key], v['children'][other][key]
            for fd in ('1', '2'):
                da['fds'][fd], db['fds'][fd] = db['fds'][fd], da['fds'][fd]
    elif edit == 'move-to-other-group':
        moved = scratch + '-other'
        v['children'][nonce] = replace_text(v['children'][nonce], scratch, moved)
        v['calls'] = [replace_text(r, scratch, moved) if r.get('nonce') == nonce else r for r in v['calls']]
        v['journal'] = [replace_text(r, scratch, moved) if (r.get('child') == nonce or
                        (r.get('kind') == 'read' and str((r.get('fact') or {}).get('path', '')).startswith(slot))) else r
                        for r in v['journal']]
    elif edit == 'unobserve-output':
        v['journal'] = [r for r in v['journal'] if not (r.get('kind') == 'read' and str((r.get('fact') or {}).get('path', '')).startswith(slot))]
    else:
        raise HarnessError('unknown declared edit %r' % edit)
    return []


def mutate(rec, scenario, view, basis, control):
    """A copy of <view> with the control's edits, in order. Returns (view, shared effects)."""
    v = copy.deepcopy(view)
    effects = []
    for e in control['edits']:
        effects += apply_edit(rec, scenario, v, basis, e)
    return v, tuple(effects)
