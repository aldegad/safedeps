"""safedeps core-hook-npm-response: which child answered which npm ask, and
what the pre hook did with that answer.

The existing stand-in npm (observe.py) records the answer it chose, then
claims a record number, then prints. So its record says what it meant to
print, the number says which child got to the directory first, and neither
says which response file the hook read for which role. This module observes
that link for the pre hook's first three asks, for one implementation at a
time, without changing the collector, the comparator or the product.

What is observed, each by its own channel:

  request      the child's argv, working directory and environment, read by
               the child (self) and matched to an ask the contract declares
  descriptor   the objects the child's stdout and stderr are open on: fstat
               and the kernel's name for them, read by the child (self); the
               response file the source names for the child's role, read by
               the observer (lstat, and fstat and F_GETPATH of its own open)
  output       the bytes in each response file, read by the observer while
               the child that wrote them is held before it exits, and again
               just before the observer lets it go
  exit         that the child's process is gone or a zombie after it was let
               go, from ps, by the observer; the exit status's value is the
               child's own record and is not observed from outside
  record       the claim record the child wrote, as the existing stand-in does
  hook         the hook's status, stdout, stderr, pending record, snapshot and
               advisory log, read from the sandbox after the hook ended

The stand-in chooses its answer from argv and its working directory alone,
before it claims a number, and nothing the observer writes changes the choice.
The observer only decides when a held child goes on.

Nothing here judges while collecting. judge_launch() reads the files a
collection left, and the contract, and nothing else.
"""
import copy
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

CONTRACT = 'core-hook-npm-response-contract/1'
LAUNCH = 'core-hook-npm-response-launch/1'
OBSERVER = 'core-hook-npm-response-observer/1'
MANIFEST = 'core-hook-npm-response-manifest/1'
RESULTS = 'core-hook-npm-response-results/1'
ROLES = ('prefix', 'root', 'config')
IMPLS = ('native', 'bash')
CONF = 'npm-response.json'
NOISE = ('_', 'SHLVL')
# How long a child waits for the observer at each hold before it goes on by
# itself. Two holds stay inside the hook's own ask deadline (8s; bash counts
# whole seconds, so at least 7).
HOLD_SECONDS = 3.0
POLL = 0.002
PS_FIELDS = 'pid=,ppid=,pgid=,stat=,lstart=,command='


class HarnessError(Exception):
    """This module could not do what it was asked; the caller exits 2."""


def sha(data):
    return hashlib.sha256(data).hexdigest()


def write_json(path, doc):
    return evidence.publish(path, evidence.encoded(doc))


def read_json(path):
    with open(path, 'rb') as f:
        return evidence.strict_load(f.read().decode('utf-8', 'surrogateescape'))


# --- places ---------------------------------------------------------------------------

def places(box, system_dirs):
    return [('@PROJECT@', box + '/project'), ('@HOME@', box + '/home'), ('@STATE@', box + '/state'),
            ('@TMP@', box + '/tmp'), ('@BOX@', box), ('@SYSTEM@', ':'.join(system_dirs))]


def fill(value, where):
    if isinstance(value, str):
        for mark, text in where:
            value = value.replace(mark, text)
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


# --- the contract, before anything starts ---------------------------------------------------

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
    heads = [tuple(a.get('head', [])) for a in asks.values()]
    for i, h in enumerate(heads):
        for j, other in enumerate(heads):
            if i != j and h != other and other[:len(h)] == h:
                errors.append({'field': 'one head is a prefix of another', 'actual': [list(h), list(other)]})
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
        want(label + 'release order or swap needs the barrier', s.get('barrier') or not (s.get('release_order') or s.get('swap_slots')), s.get('barrier'))
        swap = s.get('swap_slots')
        want(label + 'swap', swap is None or (len(swap) == 2 and len(set(swap)) == 2 and set(swap) <= set(ROLES)), swap)
        emit = s.get('emit', {})
        want(label + 'emit', set(emit) <= set(ROLES) and set(emit.values()) <= set(ROLES) and sorted(emit) == sorted(emit.values()), emit)
        want(label + 'expected verdict', s.get('expect', {}).get('verdict') in ('applicable', 'rejected', 'unresolved', 'not-applicable'), s.get('expect'))
        result = s.get('expect', {}).get('result')
        want(label + 'expected result', (isinstance(result, str) and result in rec.get('results', {}))
             or (isinstance(result, dict) and bool(result.get('differs'))), result)
    forced = [s for s in rec.get('scenarios', []) if s.get('claim_order')]
    want('two forced claim orders that differ', len(forced) >= 2 and len(set(tuple(s['claim_order']) for s in forced)) == len(forced),
         [s.get('claim_order') for s in forced])
    want('two forced completion orders that differ', len(forced) >= 2 and len(set(tuple(s['release_order']) for s in forced if s.get('release_order'))) == len(forced),
         [s.get('release_order') for s in forced])
    for c in rec.get('declared', {}).get('controls', []):
        want('control %s from a scenario' % c.get('name'), c.get('from') in names, c.get('from'))
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
        return {"error": e.strerror}
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
        return {"error": e.strerror}
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


# --- the observer ----------------------------------------------------------------------------------

def ps(args):
    argv = ['ps'] + args
    try:
        r = subprocess.run(argv, capture_output=True, timeout=10)
    except (OSError, subprocess.SubprocessError) as e:
        return {'argv': argv, 'error': str(e), 't_ns': time.time_ns()}
    return {'argv': argv, 'rc': r.returncode, 'stdout': r.stdout.decode('utf-8', 'surrogateescape'),
            'stderr': r.stderr.decode('utf-8', 'surrogateescape'), 't_ns': time.time_ns()}


def ps_rows(text, fields):
    """Rows of `ps -o <fields>` output: pid, the named columns, lstart as five words."""
    rows = {}
    for line in text.splitlines():
        parts = line.split()
        if not parts or not parts[0].isdigit():
            continue
        row, i = {}, 0
        for name in fields:
            if name == 'lstart':
                row[name] = ' '.join(parts[i:i + 5])
                i += 5
            elif name == 'command':
                row[name] = ' '.join(parts[i:])
                i = len(parts)
            else:
                row[name] = parts[i] if i < len(parts) else None
                i += 1
        rows[int(parts[0])] = row
    return rows


def kind_of(mode):
    return observe.kind_of(mode)


def slot_fact(path, blobs):
    """What a response file is, from outside the child: lstat of the path, and
    fstat, F_GETPATH and every byte of the observer's own open of it."""
    out = {'path': path, 't_ns': time.time_ns()}
    try:
        st = os.lstat(path)
        out['lstat'] = {'kind': kind_of(st.st_mode), 'dev': st.st_dev, 'ino': st.st_ino, 'size': st.st_size, 'nlink': st.st_nlink}
    except OSError as e:
        out['lstat_error'] = e.strerror
        return out
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError as e:
        out['open_error'] = e.strerror
        return out
    try:
        st = os.fstat(fd)
        try:
            name = os.fsdecode(fcntl.fcntl(fd, fcntl.F_GETPATH, bytes(1024)).split(b'\0', 1)[0])
        except (OSError, AttributeError, ValueError) as e:
            name = None
            out['getpath_error'] = str(e)
        chunks = []
        while True:
            chunk = os.read(fd, 1 << 16)
            if not chunk:
                break
            chunks.append(chunk)
        data = b''.join(chunks)
        out['read'] = {'dev': st.st_dev, 'ino': st.st_ino, 'getpath': name, 'size': len(data), 'blob': blobs.put(data)}
    except OSError as e:
        out['read_error'] = e.strerror
    finally:
        os.close(fd)
    return out


class Observer(threading.Thread):
    """Watches one launch's stand-in children and decides when a held child
    goes on. Every fact it keeps is raw: what a file held, what ps printed.
    Its own reading of a child's role only chooses which file to look at and
    when to let it go; judge_launch() reads the role again from the records."""

    def __init__(self, rec, scenario, impl, where, obs, calls, blobs):
        super().__init__(daemon=True)
        self.rec, self.scenario, self.impl, self.where = rec, scenario, impl, where
        self.obs, self.calls, self.blobs = obs, calls, blobs
        self.words, self.quiet = rec['statement']['words'], rec['quiet']
        self.children = {}
        self.order = []
        self.reads = []
        self.events = []
        self.errors = []
        self.trees = []
        self.swaps = []
        self.claims_done = not scenario.get('claim_order')
        self.barrier_done = not scenario.get('barrier')
        self.first_start = None
        self.first_written = None
        self.hook_done = threading.Event()
        self.finished = False

    # The observer's own identification: which declared ask a child's request is.
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

    def event(self, what, **more):
        self.events.append(dict(more, what=what, t_ns=time.time_ns()))

    def read_slots(self, child, when, trigger):
        for channel, path in zip(('out', 'err'), child['slot_paths']):
            self.reads.append({'when': when, 'trigger': trigger, 'channel': channel, 'fact': slot_fact(path, self.blobs)})

    def touch(self, nonce, what):
        path = os.path.join(self.obs, nonce + '.' + what)
        with open(path, 'x'):
            pass
        self.event(what, nonce=nonce)

    def initial(self, role):
        found = [c for c in self.children.values() if c['ask'] is not None and c['ask']['attempt'] == 'initial' and c['ask']['role'] == role]
        return found[0] if len(found) == 1 else None

    def run(self):
        try:
            deadline = time.monotonic() + 60
            while True:
                self.scan()
                if self.hook_done.is_set():
                    self.scan()
                    self.release_all('the hook ended')
                    self.poll_exits(final=True)
                    break
                if time.monotonic() > deadline:
                    self.errors.append('the observer gave up after 60 seconds')
                    break
                time.sleep(POLL)
        except Exception:
            self.errors.append(traceback.format_exc())
        finally:
            self.release_all('the observer stopped')
            self.finished = True

    def scan(self):
        names = sorted(os.listdir(self.obs))
        for name in names:
            if name.endswith('.started.json'):
                nonce = name[:-len('.started.json')]
                if nonce not in self.children:
                    self.started(nonce)
        if not self.claims_done:
            self.gate_claims()
        for name in names:
            if name.endswith('.written.json'):
                nonce = name[:-len('.written.json')]
                child = self.children.get(nonce)
                if child is not None and not child['written']:
                    self.written(child)
        if not self.barrier_done:
            self.barrier()
        self.poll_exits()

    def started(self, nonce):
        doc = observe_json(os.path.join(self.obs, nonce + '.started.json'))
        name, ask, scratch = self.identify(doc)
        child = {'nonce': nonce, 'pid': doc.get('pid'), 'ask_name': name, 'ask': ask, 'scratch': scratch,
                 'slot_paths': self.slot_paths(ask, scratch) if ask else None, 'written': False,
                 'released': False, 'exited': False, 'ps_started': ps(['-ww', '-o', PS_FIELDS, '-p', str(doc.get('pid'))])}
        self.children[nonce] = child
        self.order.append(nonce)
        if self.first_start is None:
            self.first_start = time.monotonic()
        self.event('started', nonce=nonce, ask=name)
        if ask is None:
            self.errors.append('a call matched no declared ask: %r' % (doc.get('argv'),))
        # A call outside the gated order, or one that starts after it was
        # imposed, is not held at the claim.
        if self.scenario.get('claim_order') and (ask is None or self.claims_done):
            self.touch(nonce, 'claim-go')

    def gate_claims(self):
        roles = [self.initial(r) for r in self.scenario['claim_order']]
        if any(c is None for c in roles):
            if self.first_start is not None and time.monotonic() - self.first_start > HOLD_SECONDS / 2:
                self.errors.append('the claim order was not imposed: not every initial role started exactly once in time')
                self.claims_done = True
                for c in self.children.values():
                    if not os.path.exists(os.path.join(self.obs, c['nonce'] + '.claim-go')):
                        self.touch(c['nonce'], 'claim-go')
            return
        self.claims_done = True
        for child in roles:
            self.touch(child['nonce'], 'claim-go')
            until = time.monotonic() + HOLD_SECONDS / 2
            while not self.claimed(child['nonce']):
                if time.monotonic() > until:
                    self.errors.append('the child %s did not claim in time' % child['nonce'])
                    break
                time.sleep(POLL)
            self.event('claimed', nonce=child['nonce'])
        for c in self.children.values():
            if not os.path.exists(os.path.join(self.obs, c['nonce'] + '.claim-go')):
                self.touch(c['nonce'], 'claim-go')

    def claimed(self, nonce):
        for name in os.listdir(self.calls):
            if name.endswith('.json'):
                try:
                    if observe_json(os.path.join(self.calls, name)).get('nonce') == nonce:
                        return True
                except (OSError, ValueError):
                    continue
        return False

    def written(self, child):
        child['written'] = True
        if self.first_written is None:
            self.first_written = time.monotonic()
        self.event('written', nonce=child['nonce'])
        if child['slot_paths']:
            self.read_slots(child, 'written', child['nonce'])
        self.trees.append({'trigger': child['nonce'], 'ps': ps(['-A', '-ww', '-o', PS_FIELDS])})
        held = self.scenario.get('barrier') and child['ask'] is not None and child['ask']['attempt'] == 'initial'
        if not held:
            if child['slot_paths']:
                self.read_slots(child, 'release', child['nonce'])
            self.release(child)

    def barrier(self):
        held = [self.initial(r) for r in ROLES]
        if any(c is None or not c['written'] for c in held):
            if self.first_written is not None and time.monotonic() - self.first_written > HOLD_SECONDS / 2:
                self.errors.append('the barrier was not reached: not every initial role wrote in time')
                self.barrier_done = True
                self.release_all('the barrier was not reached')
            return
        self.barrier_done = True
        swap = self.scenario.get('swap_slots')
        if swap:
            a, b = (self.initial(r) for r in swap)
            for pa, pb in zip(a['slot_paths'], b['slot_paths']):
                spare = pa + '.npmresp-swap'
                for src, dst in ((pa, spare), (pb, pa), (spare, pb)):
                    os.rename(src, dst)
                    self.swaps.append({'rename': [src, dst], 't_ns': time.time_ns()})
        for child in held:
            self.read_slots(child, 'release', 'barrier')
        order = self.scenario.get('release_order')
        if not order:
            for child in held:
                self.release(child)
            return
        for role in order:
            child = self.initial(role)
            self.release(child)
            until = time.monotonic() + HOLD_SECONDS
            while not child['exited']:
                self.poll_exits(only=[child])
                if child['exited']:
                    break
                if time.monotonic() > until:
                    self.errors.append('no exit seen for the released child %s in time' % child['nonce'])
                    break
                time.sleep(POLL)

    def release(self, child):
        if child['released']:
            return
        child['released'] = True
        self.touch(child['nonce'], 'release')

    def release_all(self, why):
        for child in self.children.values():
            if not child['released']:
                self.event('release-all', nonce=child['nonce'], why=why)
                self.release(child)

    def poll_exits(self, only=None, final=False):
        waiting = [c for c in (only or self.children.values()) if c['released'] and not c['exited']]
        if not waiting:
            return
        rounds = 50 if final else 1
        for _ in range(rounds):
            out = ps(['-o', 'pid=,stat=,lstart=', '-p', ','.join(str(c['pid']) for c in waiting)])
            rows = ps_rows(out.get('stdout', ''), ('pid', 'stat', 'lstart'))
            for child in waiting:
                started = ps_rows(child['ps_started'].get('stdout', ''), ('pid', 'ppid', 'pgid', 'stat', 'lstart', 'command')).get(child['pid'])
                row = rows.get(child['pid'])
                how = None
                if out.get('error'):
                    how = None
                elif row is None:
                    how = 'gone'
                elif row['stat'] and row['stat'].startswith('Z'):
                    how = 'zombie'
                elif started is not None and row['lstart'] != started['lstart']:
                    how = 'pid-reused'
                if how:
                    child['exited'] = True
                    child['exit_seen'] = {'how': how, 'ps': out}
                    self.event('exited', nonce=child['nonce'], how=how)
            waiting = [c for c in waiting if not c['exited']]
            if not waiting:
                return
            if final:
                time.sleep(0.05)

    def dump(self):
        keep = ('nonce', 'pid', 'ask_name', 'scratch', 'slot_paths', 'released', 'exited', 'ps_started', 'exit_seen')
        return {'format': OBSERVER, 'impl': self.impl, 'scenario': self.scenario['name'], 'order': self.order,
                'children': {n: {k: c.get(k) for k in keep} for n, c in self.children.items()},
                'reads': self.reads, 'events': self.events, 'trees': self.trees, 'swaps': self.swaps,
                'errors': self.errors, 'finished': self.finished}


def observe_json(path):
    with open(path, encoding='utf-8', errors='surrogateescape') as f:
        return json.load(f)


# --- one launch -------------------------------------------------------------------------------------

def hook_env(rec, where):
    return fill(rec['hook']['env'], where)


def launch(ctx, rec, impl, hook, scenario, base):
    """One implementation's pre hook under one scenario, kept whole under <base>."""
    d = base / ('%s-%s' % (impl, scenario['name']))
    box, obs, calls = d / 'box', d / 'obs', d / 'calls'
    for p in (obs, calls, box / 'stub'):
        p.mkdir(parents=True)
    for rel in rec['sandbox']['dirs']:
        (box / rel).mkdir(parents=True, exist_ok=True)
    if os.path.realpath(str(box)) != str(box):
        raise HarnessError('the sandbox is not a physical path: %s' % box)
    where = places(str(box), ctx.sysdirs)
    for rel, text in rec['sandbox']['files'].items():
        path = box / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(fill(text, where).encode('utf-8'))
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
    blobs = observe.Blobs()
    watcher = Observer(rec, scenario, impl, where, str(obs), str(calls), blobs)
    write_json(d / 'launch.json', {
        'format': LAUNCH, 'impl': impl, 'scenario': scenario['name'], 'argv': hook['argv'], 'env': env, 'cwd': cwd,
        'stdin': data.decode('utf-8'), 'box': str(box), 'system_dirs': ctx.sysdirs, 'collector_pid': os.getpid(),
        'standin_sha256': sha(code.encode('utf-8')), 'standin_python': sys.executable, 'conf_sha256': sha(conf_bytes),
        'executable_before': before, 'hook_files': ctx.hook_files[impl]})
    watcher.start()
    try:
        if hook.get('native_receipt', {}).get('tapped'):
            from .native import run_observed
            r = run_observed(observe.run_hook, hook['argv'], data, env, cwd, ctx.timeout)
        else:
            r = observe.run_hook(hook['argv'], data, env, cwd, ctx.timeout)
    finally:
        watcher.hook_done.set()
        watcher.join(timeout=90)
    after = evidence.after_launch(hook, env, cwd, before)
    for name, value in (('hook.stdout', r['out']), ('hook.stderr', r['err'])):
        evidence.publish(d / name, value)
    if 'native_raw' in r:
        evidence.publish(d / 'native.raw', r['native_raw'])
    write_json(d / 'hook.json', {'status': r['status'], 'pid': r['pid'], 't0_ns': r['t0_ns'], 't1_ns': r['t1_ns'],
                                 'executable_after': after, 'observer_alive': watcher.is_alive()})
    blob_dir = d / 'blobs'
    blob_dir.mkdir()
    for digest, value in sorted(blobs.data.items()):
        evidence.publish(blob_dir / digest, value)
    write_json(d / 'observer.json', watcher.dump())
    return {'launch': d.name, 'status': r['status'], 'observer_errors': len(watcher.errors)}


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


# --- the oracle ---------------------------------------------------------------------------------------
#
# judge_launch() reads one launch directory and the contract, and returns what
# each role's child was, which response file held which child's object and
# bytes when it was let go, and what the hook left. It reads the stand-in's and
# the observer's files; it does not take the observer's identification of a
# child or its order of events as a fact about roles.

DEFECT_FREE = ('shared-effect-declared',)


def load_view(d):
    """Everything a launch left, as plain data. Mutations for the declared
    controls edit a copy of this."""
    d = Path(d)
    view = {'dir': str(d), 'launch': read_json(d / 'launch.json'), 'hook': read_json(d / 'hook.json'),
            'stdout': (d / 'hook.stdout').read_bytes(), 'stderr': (d / 'hook.stderr').read_bytes(),
            'observer': read_json(d / 'observer.json'), 'children': {}, 'records': [],
            'conf': read_json(d / 'box' / 'stub' / CONF), 'blobs': {}}
    for p in sorted((d / 'obs').iterdir()):
        for suffix, key in (('.started.json', 'started'), ('.written.json', 'written'), ('.exiting.json', 'exiting')):
            if p.name.endswith(suffix):
                nonce = p.name[:-len(suffix)]
                view['children'].setdefault(nonce, {})[key] = read_json(p)
    for p in sorted((d / 'calls').iterdir(), key=lambda p: (len(p.name), p.name)):
        if p.name.endswith('.json'):
            doc = read_json(p)
            doc['_claim'] = int(p.name.split('.')[0])
            view['records'].append(doc)
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


def judge_launch(rec, scenario, view, shared_effects=()):
    """The facts of one launch and the codes they raise. Each code names a
    role and what was wrong; the verdict is a function of the codes alone."""
    launch = view['launch']
    impl = launch['impl']
    box = launch['box']
    where = places(box, launch['system_dirs'])
    words, quiet = rec['statement']['words'], rec['quiet']
    slots = rec['slots'][impl]
    codes, notes = [], []
    if shared_effects:
        codes.append('shared-effect-declared')
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
        return {'codes': ['no-observations'], 'verdict': 'unresolved', 'others': [], 'roles': {}, 'notes': notes,
                'claim_order': [], 'claim_nonces': [], 'completion': [], 'initial_scratch': None,
                'hook': hook_facts(rec, view, where)}
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
    reads = reads_by_path(view)
    roles = {}
    expected = {name: fill(rec['answers'][answer], where) for name, answer in scenario['answers'].items()}
    for scratch, members in groups.items():
        lone = {}
        for c in members:
            lone.setdefault((c['attempt'], c['role']), []).append(c)
        for c in members:
            if len(lone[(c['attempt'], c['role'])]) != 1:
                continue  # A duplicate is already a code; which copy is which is not read.
            facts, found = child_facts(rec, c, members, expected, reads, view, where)
            for code in found:
                codes.append(code if c['attempt'] == 'initial' or scratch == g1 else 'follow-' + code)
            key = c['role'] if c['attempt'] == 'initial' and scratch == g1 else '%s@%s' % (c['ask_name'], c['nonce'][:8])
            roles[key] = facts
    for o in others:
        o['codes'] = sorted({code for m in o['members'] for code in roles.get('%s@%s' % (children[m]['ask_name'], m[:8]), {}).get('codes', [])})
        if o['status'] == 'outside' and o['codes']:
            o['status'] = 'rejected'
            codes.append('follow-group-defect')
        del o['members']
    request_codes, process = request_checks(rec, children, view, where), process_checks(children, view, g1)
    codes += request_codes + process
    codes = sorted(set(codes))
    claim = [c.get('nonce') for c in sorted(view['records'], key=lambda r: r['_claim'])]
    claim_roles = [children[n]['role'] if n in children else '?' for n in claim]
    completion = exit_order(children, view, g1)
    return {'codes': codes, 'verdict': verdict(codes), 'others': others, 'roles': roles, 'notes': notes,
            'claim_order': claim_roles, 'claim_nonces': claim, 'completion': completion, 'initial_scratch': g1,
            'hook': hook_facts(rec, view, where)}


def verdict(codes):
    """applicable: no code. rejected: any defect. unresolved: only what was not
    observed. not-applicable: only a declared shared effect."""
    if not codes:
        return 'applicable'
    base = [c[len('follow-'):] if c.startswith('follow-') else c for c in codes]
    unseen = [c for c in base if c.startswith('unobserved-') or c == 'no-observations']
    defects = [c for c in base if c not in DEFECT_FREE and c not in unseen]
    if defects:
        return 'rejected'
    if unseen:
        return 'unresolved'
    return 'not-applicable'


def reads_by_path(view):
    out = {}
    for r in view['observer'].get('reads', []):
        fact = r.get('fact', {})
        out.setdefault(fact.get('path'), []).append(r)
    return out


def object_of(fd):
    if not isinstance(fd, dict) or 'ino' not in fd or 'dev' not in fd:
        return None
    return (fd['dev'], fd['ino'])


def read_object(fact):
    rd = fact.get('read') if isinstance(fact, dict) else None
    lst = fact.get('lstat') if isinstance(fact, dict) else None
    if not isinstance(rd, dict) or not isinstance(lst, dict):
        return None
    if (rd.get('dev'), rd.get('ino')) != (lst.get('dev'), lst.get('ino')):
        return None
    return (rd['dev'], rd['ino'])


def child_facts(rec, c, members, expected, reads, view, where):
    """One child, by its own records and by what the observer read."""
    docs, role, nonce = c['docs'], c['role'], c['nonce']
    codes, facts = [], {'nonce': nonce, 'ask': c['ask_name'], 'scratch': c['scratch'], 'slot': c['slot']}
    started, written = docs.get('started', {}), docs.get('written')
    mine = expected[c['ask_name']]
    group_answers = {m['role']: expected[m['ask_name']] for m in members}
    for ch, fd in (('out', '1'), ('err', '2')):
        own = object_of(started.get('fds', {}).get(fd))
        facts[ch + '_object'] = own
        at_written = [r for r in reads.get(c['slot'][ch], []) if r['when'] == 'written' and r['trigger'] == nonce]
        if not at_written:
            codes.append('unobserved-desc-object:%s' % role)
        else:
            fact = at_written[-1]['fact']
            obj = (fact.get('lstat') or {}).get('dev'), (fact.get('lstat') or {}).get('ino')
            facts[ch + '_slot_at_written'] = list(obj)
            if own is None or obj != own:
                codes.append('desc-object:%s' % role)
            name = (fact.get('read') or {}).get('getpath')
            if name is None or started.get('fds', {}).get(fd, {}).get('path') != name:
                codes.append('desc-path:%s' % role)
        if isinstance(written, dict) and object_of(written.get('fds', {}).get(fd)) != own:
            codes.append('desc-changed:%s' % role)
        released = [r for r in reads.get(c['slot'][ch], []) if r['when'] == 'release']
        if not released:
            codes.append('unobserved-output:%s' % role)
            continue
        fact = released[-1]['fact']
        obj = read_object(fact)
        data = view['blobs'].get((fact.get('read') or {}).get('blob'))
        if obj is None or data is None:
            codes.append('unobserved-output:%s' % role)
            continue
        holder = [m['role'] for m in members if object_of(m['docs'].get('started', {}).get('fds', {}).get(fd)) == obj]
        facts[ch + '_slot_holds'] = holder
        if holder != [role]:
            codes.append('slot-holds:%s:%s' % (role, holder[0]) if len(holder) == 1 else 'slot-unknown-object:%s' % role)
        key = 'stdout' if ch == 'out' else 'stderr'
        text = data.decode('utf-8', 'surrogateescape')
        facts[ch + '_content_sha256'] = sha(data)
        match = [r for r, a in sorted(group_answers.items()) if a[key] == text]
        facts[ch + '_content_is'] = match
        prefix = 'content' if ch == 'out' else 'stderr-content'
        if match != [role]:
            codes.append('%s:%s:%s' % (prefix, role, match[0]) if len(match) == 1 else '%s-unexpected:%s' % (prefix, role))
    # The child's own output object, wherever it ended up, against its record.
    records = [r for r in view['records'] if r.get('nonce') == nonce]
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
        actual = {}
        for ch, fd in (('out', '1'), ('err', '2')):
            own = object_of(started.get('fds', {}).get(fd))
            hits = [r['fact'] for path, rs in reads.items() for r in rs if r['when'] == 'release' and read_object(r['fact']) == own]
            if own is None or not hits:
                actual[ch] = None
                continue
            last = max(hits, key=lambda f: f.get('t_ns', 0))
            actual[ch] = view['blobs'].get(last['read']['blob'])
        if actual['out'] is None or actual['err'] is None:
            codes.append('unobserved-output:%s' % role)
        elif actual['out'] != record.get('stdout', '').encode('utf-8', 'surrogateescape') or \
                actual['err'] != record.get('stderr', '').encode('utf-8', 'surrogateescape'):
            codes.append('record-not-actual:%s' % role)
    # Its planned exit status, and the observer's sight of its exit.
    seen = view['observer'].get('children', {}).get(nonce, {})
    exit_seen = seen.get('exit_seen') if isinstance(seen, dict) else None
    facts['exit_planned'] = written.get('exit') if isinstance(written, dict) else None
    facts['exit_value_from_outside'] = 'not observed: only the parent receives an exit status'
    if not exit_confirmed(exit_seen, c, view):
        codes.append('unobserved-exit:%s' % role)
    if facts['exit_planned'] != mine['exit']:
        codes.append('exit-planned:%s' % role)
    exiting = docs.get('exiting')
    facts['released_by_observer'] = bool(isinstance(exiting, dict) and exiting.get('released'))
    if not facts['released_by_observer']:
        codes.append('unobserved-release:%s' % role)
    facts['codes'] = sorted(set(codes))
    return facts, codes


def exit_confirmed(exit_seen, c, view):
    """Re-read the ps output the observer kept: the pid gone, a zombie, or another process's start time."""
    if not isinstance(exit_seen, dict) or not isinstance(exit_seen.get('ps'), dict):
        return False
    out = exit_seen['ps']
    if out.get('error'):
        return False
    pid = c['docs'].get('started', {}).get('pid')
    row = ps_rows(out.get('stdout', ''), ('pid', 'stat', 'lstart')).get(pid)
    if row is None:
        return True
    if row['stat'] and row['stat'].startswith('Z'):
        return True
    first = view['observer'].get('children', {}).get(c['nonce'], {}).get('ps_started', {})
    then = ps_rows(first.get('stdout', ''), ('pid', 'ppid', 'pgid', 'stat', 'lstart', 'command')).get(pid)
    return then is not None and then['lstart'] != row['lstart']


def exit_order(children, view, g1):
    seen = []
    for nonce, c in children.items():
        if c['scratch'] != g1 or c['attempt'] != 'initial':
            continue
        e = view['observer'].get('children', {}).get(nonce, {}).get('exit_seen')
        if isinstance(e, dict) and isinstance(e.get('ps'), dict) and exit_confirmed(e, c, view):
            seen.append((e['ps'].get('t_ns', 0), c['role']))
    seen.sort()
    out, last = [], None
    for t, role in seen:
        if t == last:
            out[-1].append(role)
        else:
            out.append([role])
        last = t
    return out


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
        if (started.get('paths', {}).get(scratch) or {}).get('kind') != 'dir':
            codes.append('request-scratch-object:%s' % role)
    return codes


def process_checks(children, view, g1):
    """Each child's process in the ps tree the observer kept when it wrote: its
    parent is the one it reported, and the hook's process is above it."""
    codes = []
    hook_pid = view['hook'].get('pid')
    parents = {}
    trees = {t['trigger']: t['ps'] for t in view['observer'].get('trees', [])}
    for nonce, c in children.items():
        started, role = c['docs'].get('started', {}), c['role']
        tree = trees.get(nonce)
        if not isinstance(tree, dict) or tree.get('error'):
            codes.append('unobserved-process:%s' % role)
            continue
        rows = ps_rows(tree.get('stdout', ''), ('pid', 'ppid', 'pgid', 'stat', 'lstart', 'command'))
        row = rows.get(started.get('pid'))
        if row is None:
            codes.append('process-unseen:%s' % role)
            continue
        if row['ppid'] != str(started.get('ppid')):
            codes.append('process-parent:%s' % role)
        tail = ' '.join(started.get('argv', []))
        if not row['command'].endswith(' ' + tail):
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


def hook_facts(rec, view, where):
    state = view['state']
    pending_rel = os.path.relpath(fill(rec['results']['positive']['pending']['path'], where), view['launch']['box'] + '/state')
    out = {'status': view['hook'].get('status'), 'stdout': view['stdout'].decode('utf-8', 'surrogateescape'),
           'stderr': view['stderr'].decode('utf-8', 'surrogateescape'), 'pending': None, 'snapshot_meta': None,
           'snapshot_package_json_sha256': None, 'advisory': None}
    raw = state.get(pending_rel)
    if raw is not None:
        try:
            out['pending'] = json.loads(raw.decode('utf-8'))
        except ValueError:
            out['pending'] = {'unreadable': True}
    pending = out['pending'] if isinstance(out['pending'], dict) else {}
    sid = pending.get('snapshot_id')
    if isinstance(sid, str):
        meta = state.get('snapshots/%s_meta.json' % sid)
        if meta is not None:
            try:
                out['snapshot_meta'] = json.loads(meta.decode('utf-8'))
            except ValueError:
                out['snapshot_meta'] = {'unreadable': True}
        copy_ = state.get('snapshots/%s_package.json' % sid)
        out['snapshot_package_json_sha256'] = sha(copy_) if copy_ is not None else None
    log = state.get('advisory.log')
    if log is not None:
        out['advisory'] = [line.split('\t', 1)[1] if '\t' in line else line
                           for line in log.decode('utf-8', 'surrogateescape').splitlines()]
    return out


def result_errors(rec, name, view, facts):
    """The hook's result against a named expected result."""
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
    pending = got['pending'] if isinstance(got['pending'], dict) else {}
    same('pending record present', isinstance(got['pending'], dict), True)
    for key, value in want['pending']['fields'].items():
        same('pending ' + key, pending.get(key), value)
    same('pending dir_hash', pending.get('dir_hash'), hashlib.md5(want['pending']['dir_hash_md5_of'].encode('utf-8')).hexdigest())
    meta = got['snapshot_meta'] if isinstance(got['snapshot_meta'], dict) else {}
    same('snapshot project_dir', meta.get('project_dir'), want['snapshot']['project_dir'])
    same('snapshot command', meta.get('command'), want['snapshot']['command'])
    source = view['project'].get(os.path.relpath(want['snapshot']['package_json_copy_of'], 'project'))
    same('snapshot package.json copy', got['snapshot_package_json_sha256'], sha(source) if source is not None else 'no source file')
    same('advisory lines', got['advisory'], want['advisory'])
    return errors


def differs_errors(rec, scenario, view, facts):
    """A negative's result: the positive's role-linked fields must differ, from
    a hook that still answered and wrote its record."""
    where = places(view['launch']['box'], view['launch']['system_dirs'])
    positive = fill(rec['results']['positive'], where)['pending']['fields']
    spec = fill(scenario['expect']['result'], where)
    got = facts['hook']
    errors = []
    if got['status'] != rec['hook']['status'] or got['stdout'] != rec['hook']['stdout']:
        errors.append({'field': 'the hook answered as in the positive', 'actual': [got['status'], got['stdout']],
                       'expected': [rec['hook']['status'], rec['hook']['stdout']]})
    pending = got['pending']
    if not isinstance(pending, dict) or pending.get('unreadable'):
        errors.append({'field': 'pending record present', 'actual': pending, 'expected': 'a record'})
        return errors, {}
    for key in spec['differs']:
        if pending.get(key) == positive.get(key):
            errors.append({'field': 'pending %s differs from the positive' % key, 'actual': pending.get(key),
                           'expected': 'not %r' % (positive.get(key),)})
    predicted = {key: {'predicted': value, 'actual': pending.get(key), 'held': pending.get(key) == value}
                 for key, value in spec.get('predicted', {}).items()}
    return errors, predicted


# --- declared controls ------------------------------------------------------------------------------

def replace_text(value, old, new):
    if isinstance(value, str):
        return value.replace(old, new)
    if isinstance(value, list):
        return [replace_text(v, old, new) for v in value]
    if isinstance(value, dict):
        return {replace_text(k, old, new): replace_text(v, old, new) for k, v in value.items()}
    return value


def role_nonce(rec, scenario, view, role, attempt='initial'):
    facts = judge_launch(rec, scenario, view)
    if attempt == 'initial':
        return facts['roles'][role]['nonce'], facts['initial_scratch']
    for key, f in facts['roles'].items():
        if key.startswith('follow-config@'):
            return f['nonce'], f['scratch']
    raise HarnessError('no %s child of role %s' % (attempt, role))


def drop_child(view, nonce):
    """The child's own records go; what the observer read of its file stays,
    as it would if the child's records were lost."""
    view['children'].pop(nonce, None)
    view['records'] = [r for r in view['records'] if r.get('nonce') != nonce]
    view['observer']['children'].pop(nonce, None)


def mutate(rec, scenario, view, control):
    """A copy of <view> with the control's edit. Returns (view, shared effects)."""
    v = copy.deepcopy(view)
    edit = control['edit']
    if edit == 'none':
        return v, ()
    if edit == 'declare-shared-effect':
        return v, (control['effect'],)
    if edit == 'empty':
        v['children'], v['records'] = {}, []
        v['observer']['children'], v['observer']['reads'] = {}, []
        return v, ()
    if edit in ('drop', 'duplicate', 'duplicate-and-drop', 'unobserve-output', 'move-to-other-group'):
        nonce, scratch = role_nonce(rec, scenario, v, control['role'])
    if edit == 'drop':
        drop_child(v, nonce)
    elif edit in ('duplicate', 'duplicate-and-drop'):
        twin = nonce + '-twin'
        docs = replace_text(v['children'][nonce], nonce, twin)
        v['children'][twin] = docs
        record = [r for r in v['records'] if r.get('nonce') == nonce][0]
        v['records'].append(dict(replace_text(record, nonce, twin), _claim=max(r['_claim'] for r in v['records']) + 1))
        v['observer']['children'][twin] = replace_text(v['observer']['children'][nonce], nonce, twin)
        v['observer']['reads'] += [replace_text(r, nonce, twin) for r in v['observer']['reads'] if r['trigger'] == nonce]
        v['observer']['trees'] += [dict(t, trigger=twin) for t in v['observer']['trees'] if t['trigger'] == nonce]
        if edit == 'duplicate-and-drop':
            other, _ = role_nonce(rec, scenario, view, control['other'])
            drop_child(v, other)
    elif edit == 'exchange-descriptors':
        a, _ = role_nonce(rec, scenario, v, control['role'])
        b, _ = role_nonce(rec, scenario, v, control['other'])
        for key in ('started', 'written'):
            da, db = v['children'][a][key], v['children'][b][key]
            for fd in ('1', '2'):
                da['fds'][fd], db['fds'][fd] = db['fds'][fd], da['fds'][fd]
    elif edit == 'move-to-other-group':
        moved = scratch + '-other'
        v['children'][nonce] = replace_text(v['children'][nonce], scratch, moved)
        v['records'] = [replace_text(r, scratch, moved) if r.get('nonce') == nonce else r for r in v['records']]
        slot = rec['slots'][v['launch']['impl']]['initial'][control['role']]
        v['observer']['reads'] = [replace_text(r, scratch, moved) if r['fact'].get('path', '').startswith(scratch + '/' + slot) else r
                                  for r in v['observer']['reads']]
    elif edit == 'unobserve-output':
        slot = rec['slots'][v['launch']['impl']]['initial'][control['role']]
        v['observer']['reads'] = [r for r in v['observer']['reads'] if not r['fact'].get('path', '').startswith(scratch + '/' + slot)]
    elif edit == 'follow-into-initial-scratch':
        nonce, follow = role_nonce(rec, scenario, v, 'config', attempt='follow')
        _, initial = role_nonce(rec, scenario, v, 'prefix')
        v['children'][nonce] = replace_text(v['children'][nonce], follow, initial)
        v['records'] = [replace_text(r, follow, initial) if r.get('nonce') == nonce else r for r in v['records']]
        v['observer']['reads'] = [replace_text(r, follow, initial) if r['trigger'] == nonce else r for r in v['observer']['reads']]
    else:
        raise HarnessError('unknown control edit %r' % edit)
    return v, ()
