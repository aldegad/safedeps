"""safedeps core-hook-differential: where a generated value may stand, and the
fact each such value has to match.

This file is the contract. A value in a hook's output is set aside from the
byte comparison only where a slot below names its place, and only after the
check of that slot finds the value equal to the fact the place refers to,
read from this side's own bundle (observe.py). Everything else is compared as
the bytes it is: a seeded value, a value of a shape the slots know that stands
somewhere they do not name, and a value whose fact this harness did not see.

An occurrence is placed by case, side, step or boundary, channel, record,
field or span, and the slot's role. Its check ends in one of three answers:

  ok          the value equals the fact; the occurrence reads as its role's
              token in the comparison, and the witness it matched is kept
  violation   the fact was seen and the value is not it; on the candidate this
              is a difference, on the reference the case is unresolved
  unresolved  the fact the slot needs was not seen (a clock read inside a
              process, a path that changed while the hook ran, two objects a
              role cannot tell apart); the case cannot be called equal

The slots:

  snapshot-seconds, snapshot-pid
      An id `<seconds>_<hash>-<pid>[-<n>]` of a snapshot that appeared on disk
      during the run (its first entry under state/snapshots/ is at boundary b,
      after hook step b-1). Where it stands: names under state/snapshots/ and
      state/pending/, the contents of state/snapshots/*, state/pending/*.json,
      state/confirmed_*, state/reorg.log and state/advisory.log, and a hook's
      stdout. The seconds have to be a clock reading of step b-1, the pid the
      pid of the process this harness started for step b-1. The hash and any
      suffix stay bytes. An id no run object has is bytes.
  snapshot-meta-time
      `timestamp` in state/snapshots/<id>_meta.json of such a snapshot: equal
      to the id's seconds, and as proven as they are.
  log-time
      The time that starts a line appended during step k: `<iso>\\t` and
      `[<iso>] ` in state/advisory.log, `[<iso>] ` in state/reorg.log. A clock
      reading of step k. Lines of the seed, and lines of a log that was not
      only appended to, are not occurrences: the first are bytes, the second
      unresolved.
  record-time
      `timestamp` in state/snapshots/verified-*_meta.json, `at` in
      state/npm-observed/*.json and in each record of state/npm-withheld/*.json:
      a clock reading of the step that wrote those bytes.
  withheld-name
      state/npm-withheld/<seconds>-<pid>-<tail>.json made by hook step k: a
      clock reading and the pid of step k, and a tail that names the one file
      of its kind step k made (two of them are unresolved).
  pending-inode
      `npm_trace.inodes.<path>` in a call record (state/pending/id-*.json,
      state/pending/*__*.json): lstat's inode of <project_dir>/<path>, where
      <project_dir> is the record's own field (compared as bytes);
      `inodes.<path>` in a backstop entry (state/pending/backstop/*.json):
      `<own>|<target>` of <cwd>/<path>, the cwd the hook input names, or the
      hook's own when it names none. Read at the boundary before the step that
      wrote the record, and unresolved where the path is not the same object
      at the boundary after it.
  pending-clock
      `clocks.<path>` in a backstop entry: `<own>|<target>` ctime of the same
      path, as stat prints it (BSD `<s>.<ns>`, GNU local date), compared to
      the nanosecond.
  impl-root
      `<root>/bin/safedeps` in a hook's stdout or stderr, where <root> is a
      tree of the implementation this harness ran for that step.
  npm-scratch
      `<TMPDIR>/safedeps-npm-ask.<tail>` in the argv or environment of a call
      to the stand-in npm during step k: a directory the stand-in saw while it
      ran and that was not there at the boundary before step k. Which calls
      share one such directory is compared.

Clock readings without an independently observed source role do not prove a
consumer field. Value membership, counts, line order and a run's time window
cannot select that field's generating event. The recording date preserves
raw readings, but it does not observe their callers' semantic roles. Such
Bash claims remain unresolved, even when both sides have identical bytes.
Native reads without the independent archive tap also remain unresolved.
A malformed time or a time outside the observed run can contradict a claim;
neither a plausible value nor another output field can establish its source.
"""
import calendar
import hashlib
import json
import os
import re
import time

TOKEN_OPEN, TOKEN_CLOSE = "⟦", "⟧"

SLOTS = ("snapshot-seconds", "snapshot-pid", "snapshot-meta-time", "log-time", "record-time", "withheld-name",
         "pending-inode", "pending-clock", "impl-root", "npm-scratch")

# The formats a clock reading is printed in, by the argv of the date call.
CLOCK_FORMATS = {
    ("+%s",): "epoch", ("-u", "+%s"): "epoch",
    ("-u", "+%Y-%m-%dT%H:%M:%SZ"): "iso",
    ("-u", "+%Y%m%dT%H%M%SZ"): "compact",
}

SNAP_ID = re.compile(r"^([0-9]+)_([0-9a-f]+)-([0-9]+)((?:-[0-9]+)*)$")
SNAP_ENTRY = re.compile(r"^state/snapshots/\.?([0-9]+_[0-9a-f]+-[0-9]+(?:-[0-9]+)*)_")
SNAP_NAME_PLACES = ("state/snapshots/*", "state/pending/*")
SNAP_TEXT_PLACES = ("state/snapshots/*", "state/pending/*.json", "state/confirmed_*", "state/reorg.log",
                    "state/advisory.log")
ISO_RE = r"20[0-9]{2}-[01][0-9]-[0-3][0-9]T[0-2][0-9]:[0-5][0-9]:[0-6][0-9]Z"
LOG_LINE_TIME = {
    "state/advisory.log": re.compile(r"^(?:(%s)\t|\[(%s)\] )" % (ISO_RE, ISO_RE)),
    "state/reorg.log": re.compile(r"^\[(%s)\] " % ISO_RE),
}
WITHHELD_NAME = re.compile(r"^state/npm-withheld/([0-9]+)-([0-9]+)-([A-Za-z0-9]{6})\.json$")
BSD_CLOCK = re.compile(r"^([0-9]+)\.([0-9]{9})$")
GNU_CLOCK = re.compile(r"^([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2})\.([0-9]{9}) ([+-])([0-9]{2})([0-9]{2})$")


def token(role):
    return TOKEN_OPEN + role + TOKEN_CLOSE


def fnmatch_any(rel, pats):
    import fnmatch
    return any(fnmatch.fnmatchcase(rel, p) for p in pats)


# --- a raw JSON reading -----------------------------------------------------------------

class JsonError(Exception):
    pass


def json_scalars(text):
    """Every scalar of one JSON document, as (path, kind, start, end) with
    [start, end) its raw span in `text` (inside the quotes for a string).
    A key given twice gives two scalars with the same path: nothing is
    dropped. Raises JsonError for anything that is not one JSON value."""
    out = []
    n = len(text)
    ws = " \t\n\r"

    def skip(i):
        while i < n and text[i] in ws:
            i += 1
        return i

    def string(i):
        j = i + 1
        while j < n:
            c = text[j]
            if c == "\\":
                j += 2
                continue
            if c == '"':
                return j
            if ord(c) < 0x20:
                raise JsonError("a control byte in a string at %d" % j)
            j += 1
        raise JsonError("a string that does not end")

    num = re.compile(r"-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?")

    def value(i, path):
        i = skip(i)
        if i >= n:
            raise JsonError("the text ends where a value was due")
        c = text[i]
        if c == "{":
            i = skip(i + 1)
            if i < n and text[i] == "}":
                return i + 1
            while True:
                i = skip(i)
                if i >= n or text[i] != '"':
                    raise JsonError("a key was due at %d" % i)
                e = string(i)
                try:
                    key = json.loads(text[i:e + 1])
                except ValueError as err:
                    raise JsonError(str(err))
                i = skip(e + 1)
                if i >= n or text[i] != ":":
                    raise JsonError("a colon was due at %d" % i)
                i = value(i + 1, path + (key,))
                i = skip(i)
                if i < n and text[i] == ",":
                    i += 1
                    continue
                if i < n and text[i] == "}":
                    return i + 1
                raise JsonError("a comma or a brace was due at %d" % i)
        if c == "[":
            i = skip(i + 1)
            if i < n and text[i] == "]":
                return i + 1
            k = 0
            while True:
                i = value(i, path + (k,))
                k += 1
                i = skip(i)
                if i < n and text[i] == ",":
                    i += 1
                    continue
                if i < n and text[i] == "]":
                    return i + 1
                raise JsonError("a comma or a bracket was due at %d" % i)
        if c == '"':
            e = string(i)
            out.append((path, "string", i + 1, e))
            return e + 1
        m = num.match(text, i)
        if m and m.end() > i:
            out.append((path, "number", i, m.end()))
            return m.end()
        for lit in ("true", "false", "null"):
            if text.startswith(lit, i):
                out.append((path, lit, i, i + len(lit)))
                return i + len(lit)
        raise JsonError("no value at %d" % i)

    end = skip(value(0, ()))
    if end != n:
        raise JsonError("bytes after the value at %d" % end)
    return out


def json_string_value(text, start, end):
    try:
        v = json.loads('"' + text[start:end] + '"')
    except ValueError:
        return None
    return v


# --- one side's bundle, read --------------------------------------------------------------

class Side:
    def __init__(self, case, doc):
        self.case = case
        self.doc = doc
        self.blobs = doc["blobs"]
        self.box = doc["box"]
        self.steps = doc["steps"]
        self.bounds = [b["entries"] for b in doc["boundaries"]]
        self.walk_errors = [(b, e) for b, bd in enumerate(doc["boundaries"]) for e in bd.get("walk_errors", [])]

    def text(self, digest):
        return self.blobs.get(digest).decode("latin-1")

    def content(self, b, rel):
        e = self.bounds[b].get(rel)
        if not e or "blob" not in e:
            return None
        return self.text(e["blob"])

    def raw(self, place):
        m = re.fullmatch(r'boundary ([0-9]+) (name|file) (.*)', place)
        if m:
            return m.group(3) if m.group(2) == 'name' else self.content(int(m.group(1)), m.group(3))
        m = re.fullmatch(r'step ([0-9]+) (stdout|stderr)', place)
        if m:
            return self.text(self.steps[int(m.group(1))][m.group(2)])
        m = re.fullmatch(r'step ([0-9]+) npm call ([0-9]+) (argv|env) (.*)', place)
        if m:
            calls = [c for c in self.steps[int(m.group(1))]['npm_calls'] if c['seq'] == int(m.group(2))]
            if len(calls) != 1:
                raise ValueError('ambiguous raw call: ' + place)
            return calls[0][m.group(3)][int(m.group(4)) if m.group(3) == 'argv' else m.group(4)]
        raise ValueError('unknown raw place: ' + place)

    def hook(self, k):
        s = self.steps[k] if 0 <= k < len(self.steps) else None
        return s if s and s["kind"] == "hook" else None

    def window(self, k):
        s = self.steps[k]
        return s["t0_ns"] // 1_000_000_000, -(-s["t1_ns"] // 1_000_000_000)

    def written_step(self, rel, b):
        """The step that wrote what <rel> holds at boundary b: None for the
        seed's bytes or a harness effect's."""
        e = self.bounds[b].get(rel)
        key = (e or {}).get("blob", (e or {}).get("target"))
        b0 = b
        while b0 > 0:
            prev = self.bounds[b0 - 1].get(rel)
            if not prev or prev.get("kind") != e.get("kind") or prev.get("blob", prev.get("target")) != key:
                break
            b0 -= 1
        if b0 == 0:
            return None
        return b0 - 1 if self.hook(b0 - 1) else None

    def clock_readings(self, k, fmt):
        s = self.steps[k]
        out = []
        for c in s.get("date_calls", []):
            if CLOCK_FORMATS.get(tuple(c["argv"])) == fmt and c["rc"] == 0:
                v = self.blobs.get(c["stdout"]).decode("latin-1")
                if v.endswith("\n"):
                    v = v[:-1]
                out.append((c["seq"], v))
        return out

    def incomplete_dates(self, k):
        return [c for c in self.steps[k].get("incomplete_calls", []) if "argv" in c]


def clock_seconds(fmt, v):
    try:
        if fmt == "epoch":
            return int(v) if re.match(r"^[0-9]+$", v) else None
        if fmt == "iso":
            return calendar.timegm(time.strptime(v, "%Y-%m-%dT%H:%M:%SZ"))
        if fmt == "compact":
            return calendar.timegm(time.strptime(v, "%Y%m%dT%H%M%SZ"))
    except ValueError:
        return None
    return None


def stat_clock_ns(v):
    m = BSD_CLOCK.match(v)
    if m:
        return int(m.group(1)) * 1_000_000_000 + int(m.group(2))
    m = GNU_CLOCK.match(v)
    if m:
        try:
            secs = calendar.timegm(time.strptime(m.group(1), "%Y-%m-%d %H:%M:%S"))
        except ValueError:
            return None
        off = (int(m.group(4)) * 3600 + int(m.group(5)) * 60) * (1 if m.group(3) == "+" else -1)
        return (secs - off) * 1_000_000_000 + int(m.group(2))
    return None



# --- the checks --------------------------------------------------------------------------

class Result:
    __slots__ = ("status", "token", "witness", "reason")

    def __init__(self, status, token=None, witness=None, reason=""):
        self.status, self.token, self.witness, self.reason = status, token, witness or [], reason


def ok(tok, witness, reason=""):
    return Result("ok", tok, witness, reason)


def violation(reason):
    return Result("violation", None, None, reason)


def unresolved(reason):
    return Result("unresolved", None, None, reason)


class SourceBinding:
    """A fixture/observed-object selector, never a consumer value or verdict.

    Aliases may share this selector. Each RawOccurrence supplies its own raw
    scalar to check_claim; no consumer result lives on this object.
    """
    def __init__(self, key, step, fmt, chain=None, order=None):
        self.key, self.step, self.fmt = key, step, fmt
        self.chain, self.order = chain, order
        self.role = "clock:step%d:%s" % (step, fmt)


def check_claim(side, claim, actual, claims):
    hook = side.hook(claim.step)
    impl = hook['impl'] if hook else 'unknown'
    if impl == 'core':
        from . import native
        if claim.key.startswith('snapshot '):
            return native.snapshot_role(side, claim, actual)
        if claim.chain:
            return native.log_role(side, claim, actual, claims)
        if getattr(claim, 'native_binding', None):
            return native.claim_result(side, claim, actual, *claim.native_binding)
    lo, hi = side.window(claim.step)
    secs = clock_seconds(claim.fmt, actual)
    if secs is None:
        return violation("%r is not a %s time" % (actual, claim.fmt))
    if not lo <= secs <= hi:
        return violation("%s is outside step %d's run (%d..%d)" % (actual, claim.step, lo, hi))
    return unresolved("step %d %s clock claim %s needs an independently observed source role "
                      "and consumer occurrence; date value/count/order does not prove that relationship"
                      % (claim.step, impl, claim.key))


def check_pid(side, k, value):
    role = "pid:step%d" % k
    hook = side.hook(k)
    if not hook or not hook["pid"]:
        return role, unresolved("step %d started no process the harness saw" % k)
    if value == str(hook["pid"]):
        return role, ok(token(role), ["process:step%d" % k])
    return role, violation("%s is not the pid of step %d's hook (%d)" % (value, k, hook["pid"]))


class RawOccurrence:
    """A byte occurrence. The raw slice owns both the check and its receipt."""
    def __init__(self, finder, place, start, end, slot, role, result=None, claim=None):
        self.finder, self.place, self.start, self.end = finder, place, start, end
        self.slot, self.role, self._result, self.claim = slot, role, result, claim

    def read(self):
        text = self.finder.side.raw(self.place)
        if not 0 <= self.start < self.end <= len(text):
            raise ValueError('occurrence outside raw bytes: ' + self.place)
        return text[self.start:self.end]

    @property
    def value(self):
        return self.read()

    @property
    def result(self):
        actual = self.read()
        if self.claim is not None:
            return check_claim(self.finder.side, self.claim, actual, self.finder.claims)
        return self._result

    def describe(self):
        raw = self.read()
        r = self.result
        # A parsed whole JSON scalar is retained as well as its exact bytes.
        kind = self.identity['scalar_type']
        actual = json.loads(raw) if kind == 'number' else (json.loads('"' + raw + '"') if kind == 'string' else raw)
        return {**self.identity, "place": self.place, "span": [self.start, self.end],
                "raw": raw, "value": raw, "actual": actual, "slot": self.slot,
                "role": self.role, "event": self.claim.key if self.claim else None, "status": r.status,
                "witness": r.witness, "reason": r.reason}


def place_name(b, rel):
    return "boundary %d name %s" % (b, rel)


def place_file(b, rel):
    return "boundary %d file %s" % (b, rel)


def place_out(k, ch):
    return "step %d %s" % (k, ch)


def place_npm(k, seq, field):
    return "step %d npm call %d %s" % (k, seq, field)


# --- finding the occurrences of one side ----------------------------------------------------

def snapshot_objects(side):
    """Each snapshot that appeared during the run: id -> creating step."""
    born = {}
    for b, entries in enumerate(side.bounds):
        for rel in entries:
            m = SNAP_ENTRY.match(rel)
            if m and m.group(1) not in born:
                born[m.group(1)] = b
    objs = {}
    for sid, b in born.items():
        if b > 0 and side.hook(b - 1) and SNAP_ID.match(sid):
            objs[sid] = b - 1
    return objs


class Finder:
    def __init__(self, case, side):
        self.case, self.side = case, side
        self.occ = []
        self.claims = {}
        self.objs = snapshot_objects(side)
        for sid, k in self.objs.items():
            sec, _hash, pid, _suffix = SNAP_ID.match(sid).groups()
            self.claim("snapshot %s" % sid, k, "epoch", sec)
        self.obj_re = None
        if self.objs:
            alts = "|".join(re.escape(s) for s in sorted(self.objs, key=len, reverse=True))
            self.obj_re = re.compile("(?<![0-9A-Za-z])(?:%s)(?![0-9])" % alts)

    def claim(self, key, step, fmt, value, chain=None, order=None):
        if key not in self.claims:
            self.claims[key] = SourceBinding(key, step, fmt, chain, order)
        return self.claims[key]

    def add(self, place, start, end, value, slot, role, result=None, claim=None):
        occurrence = RawOccurrence(self, place, start, end, slot, role, result, claim)
        m = re.match(r'(step|boundary) ([0-9]+) (.*)', place)
        step = claim.step if claim else (int(m.group(2)) - (m.group(1) == 'boundary') if m else None)
        call = None
        hook = self.side.hook(step) if step is not None else None
        if hook:
            try:
                payload = json.loads(self.side.text(hook['stdin']))
                if isinstance(payload, dict):
                    call = payload.get('tool_use_id')
            except ValueError:
                pass
        text = self.side.raw(place)
        raw = occurrence.read()
        if claim is None and raw != value:
            raise ValueError('occurrence check value differs from raw slice: ' + place)
        kind, scalar_ordinal, field = 'fragment', None, None
        if m and m.group(3).startswith('file ') and m.group(3).endswith('.json'):
            try:
                for ordinal, (path, scalar_kind, s0, s1) in enumerate(json_scalars(text)):
                    if s0 <= start and end <= s1:
                        scalar_ordinal, field = ordinal, list(path)
                        if (s0, s1) == (start, end):
                            kind = scalar_kind
                        break
            except JsonError:
                pass
        generation = int(m.group(2)) if m else None
        occurrence.identity = {'run': self.side.doc.get('run_id'), 'case': self.case['id'],
                               'side': self.side.doc.get('side'), 'execution': self.side.doc.get('execution_id'),
                               'step': step, 'call': call, 'channel_record': m.group(3) if m else place,
                               'generation': generation, 'blob': hashlib.sha256(text.encode('latin-1')).hexdigest(),
                               'scalar_type': kind, 'scalar_ordinal': scalar_ordinal, 'field': field,
                               'occurrence_ordinal': sum(o.place == place for o in self.occ)}
        self.occ.append(occurrence)

    def add_claim(self, place, start, end, slot, claim):
        self.add(place, start, end, None, slot, claim.role, claim=claim)

    def snapshots_in(self, place, text, spans=None):
        if not self.obj_re:
            return
        for m in self.obj_re.finditer(text):
            if spans is not None and not any(start <= m.start() and m.end() <= end for start, end in spans):
                continue
            sid = m.group(0)
            sm = SNAP_ID.match(sid)
            s0 = m.start()
            self.add_claim(place, s0 + sm.start(1), s0 + sm.end(1), "snapshot-seconds", self.claims["snapshot %s" % sid])
            prole, pres = check_pid(self.side, self.objs[sid], sm.group(3))
            self.add(place, s0 + sm.start(3), s0 + sm.end(3), sm.group(3), "snapshot-pid", prole, pres)

    def run(self):
        side = self.side
        for k, s in enumerate(side.steps):
            if s["kind"] != "hook":
                continue
            raw = side.text(s["stdout"])
            self.snapshots_in(place_out(k, "stdout"), raw, self.report_snapshot_spans(raw))
            for ch in ("stdout", "stderr"):
                self.roots_in(k, ch, side.text(s[ch]))
            self.npm_calls(k, s)
        for rel in LOG_LINE_TIME:
            self.log_lines(rel)
        for b in range(1, len(side.bounds)):
            for rel in side.bounds[b]:
                if fnmatch_any(rel, SNAP_NAME_PLACES):
                    self.snapshots_in(place_name(b, rel), rel)
                self.withheld_name(b, rel)
                text = side.content(b, rel)
                if text is None:
                    continue
                if fnmatch_any(rel, SNAP_TEXT_PLACES):
                    self.snapshots_in(place_file(b, rel), text, self.snapshot_spans(rel, text))
                self.json_slots(b, rel, text)
        return self.occ

    @staticmethod
    def report_snapshot_spans(text):
        return [(m.start(1), m.end(1)) for m in re.finditer(
            r'(?:Rollback snapshot: |Snapshot: |snapshot )((?:verified-)?[0-9]+_[0-9a-f]+-[0-9]+(?:-[0-9]+)*)', text)]

    def snapshot_spans(self, rel, text):
        if rel in ('state/reorg.log', 'state/advisory.log'):
            spans = self.report_snapshot_spans(text)
            # The no-id compatibility report names the record actually present
            # at a preceding boundary. It grants no authority to arbitrary paths.
            for entries in self.side.bounds:
                for record in entries:
                    if record.startswith('state/pending/') and '__' in record and record.endswith('.json'):
                        name = self.side.box + '/' + record
                        for m in re.finditer(r'it took the record (' + re.escape(name) + r') by the directory and the command', text):
                            spans.append((m.start(1), m.end(1)))
            return sorted(set(spans))
        if rel.startswith('state/confirmed_'):
            return [(0, len(text))] if re.fullmatch(r'(?:verified-)?[0-9]+_[0-9a-f]+-[0-9]+(?:-[0-9]+)*\n?', text) else []
        if not (rel.endswith('_meta.json') or rel.startswith('state/pending/')):
            return []
        try:
            out = []
            for path, kind, start, end in json_scalars(text):
                if kind != 'string':
                    continue
                if path in (('snapshot_id',), ('parent_snapshot_id',), ('verified_from',)):
                    out.append((start, end))
                elif path == ('npm_trace', 'baseline') and rel.startswith('state/pending/'):
                    expected = self.side.box + '/' + rel.removesuffix('.json') + '.trace'
                    if json_string_value(text, start, end) == expected:
                        out.append((start, end))
            return out
        except JsonError:
            return []

    def roots_in(self, k, ch, text):
        s = self.side.steps[k]
        alts = "|".join(re.escape(r) for r in sorted(s["roots"], key=len, reverse=True))
        for m in re.finditer("(%s)/bin/safedeps(?![A-Za-z0-9_.-])" % alts, text):
            self.add(place_out(k, ch), m.start(1), m.end(1), m.group(1), "impl-root", "root:step%d" % k,
                     ok(token("root"), ["impl:step%d" % k]))

    def withheld_name(self, b, rel):
        """A record of withheld bytes made by hook step b-1: the event of its
        naming, the step's pid, and a tail that names it among the step's own."""
        m = WITHHELD_NAME.match(rel)
        side = self.side
        first = next((x for x in range(len(side.bounds)) if rel in side.bounds[x]), None)
        if not m or first is None or first == 0 or not side.hook(first - 1):
            return
        k = first - 1
        made = [r for r in side.bounds[first] if WITHHELD_NAME.match(r) and r not in side.bounds[first - 1]]
        place = place_name(b, rel)
        claim = self.claim("name %s" % rel, k, "epoch", m.group(1))
        if len(made) == 1 and side.hook(k)['impl'] == 'core':
            claim.native_binding = ('NpmWithheldName', 0, 1)
        self.add_claim(place, m.start(1), m.end(1), "withheld-name", claim)
        role, res = check_pid(side, k, m.group(2))
        self.add(place, m.start(2), m.end(2), m.group(2), "withheld-name", role, res)
        role = "withheld:step%d" % k
        if len(made) == 1:
            res = ok(token(role), ["entry:boundary%d:%s" % (first, rel)])
        else:
            res = unresolved("step %d made %d npm-withheld records, and a tail does not say which is which" % (k, len(made)))
        self.add(place, m.start(3), m.end(3), m.group(3), "withheld-name", role, res)

    def log_lines(self, rel):
        """Each line of <rel> at each boundary, placed in the step that
        appended it. A log that is not the log before it with lines added has
        lines no step can be named for."""
        side = self.side
        lines = []  # per line of the current content: a Claim, "seed", None, or why it cannot be placed
        before = None  # the content at the boundary before; None where there was no file
        unreadable = False
        for b in range(len(side.bounds)):
            now = side.content(b, rel) if rel in side.bounds[b] else None
            if now is None:
                # Not there, or there and unreadable: the next boundary cannot
                # tell what was appended to what.
                unreadable = rel in side.bounds[b]
                lines, before = [], None
                continue
            parts = now.split("\n")
            if b == 0:
                lines = ["seed"] * len(parts)
            elif unreadable:
                lines = ["%s could not be read at boundary %d, so its lines at boundary %d cannot be placed in a step"
                         % (rel, b - 1, b)] * len(parts)
            elif before is not None and now == before:
                pass
            elif before is not None and now.startswith(before) and (before == "" or before.endswith("\n")):
                old = before.split("\n")[:-1] if before else []
                lines = (lines or [])[:len(old)]
                k = b - 1
                for i in range(len(old), len(parts)):
                    m = LOG_LINE_TIME[rel].match(parts[i])
                    if not m:
                        lines.append(None)
                    elif side.hook(k):
                        lines.append(self.claim("log %s@%d:%d" % (rel, b, i), k, "iso", m.group(1) or m.group(2),
                                                chain="%s@step%d" % (rel, k), order=i))
                    else:
                        lines.append("seed")
            elif before is None and b > 0:
                k = b - 1
                lines = []
                for i, line in enumerate(parts):
                    m = LOG_LINE_TIME[rel].match(line)
                    if not m:
                        lines.append(None)
                    elif side.hook(k):
                        lines.append(self.claim("log %s@%d:%d" % (rel, b, i), k, "iso", m.group(1) or m.group(2),
                                                chain="%s@step%d" % (rel, k), order=i))
                    else:
                        lines.append("seed")
            else:
                lines = ["%s at boundary %d is not the log of boundary %d with lines added, so its lines cannot be "
                         "placed in a step" % (rel, b, b - 1)] * len(parts)
            before, unreadable = now, False
            if b == 0:
                continue
            pos = 0
            place = place_file(b, rel)
            for i, line in enumerate(parts):
                m = LOG_LINE_TIME[rel].match(line)
                what = lines[i] if lines and i < len(lines) else None
                if m and what not in (None, "seed"):
                    g = 1 if m.group(1) else 2
                    if isinstance(what, SourceBinding):
                        self.add_claim(place, pos + m.start(g), pos + m.end(g), "log-time", what)
                    else:
                        self.add(place, pos + m.start(g), pos + m.end(g), m.group(g), "log-time", "clock:?:iso",
                                 unresolved(what))
                pos += len(line) + 1

    def json_slots(self, b, rel, text):
        side = self.side
        is_meta = re.match(r"^state/snapshots/([0-9]+_[0-9a-f]+-[0-9]+(?:-[0-9]+)*)_meta\.json$", rel)
        is_verified = re.match(r"^state/snapshots/verified-[^/]*_meta\.json$", rel)
        is_observed = re.match(r"^state/npm-observed/[^/]*\.json$", rel)
        is_withheld = re.match(r"^state/npm-withheld/[^/]*\.json$", rel)
        is_call = re.match(r"^state/pending/(id-[^/]*|[^/]*__[^/]*)\.json$", rel)
        is_backstop = re.match(r"^state/pending/backstop/[^/]*\.json$", rel)
        if not (is_meta or is_verified or is_observed or is_withheld or is_call or is_backstop):
            return
        k = side.written_step(rel, b)
        if k is None:
            return
        wrote = b
        while wrote > 0 and side.bounds[wrote - 1].get(rel, {}).get("blob") == side.bounds[b][rel].get("blob"):
            wrote -= 1
        try:
            scalars = json_scalars(text)
        except JsonError:
            return
        place = place_file(b, rel)
        if is_meta and is_meta.group(1) in self.objs:
            sid = is_meta.group(1)
            c = self.claims["snapshot %s" % sid]
            for path, kind, s0, s1 in scalars:
                if path == ("timestamp",) and kind == "number":
                    v = text[s0:s1]
                    if v == SNAP_ID.match(sid).group(1):
                        self.add_claim(place, s0, s1, "snapshot-meta-time", c)
                    else:
                        self.add(place, s0, s1, v, "snapshot-meta-time", c.role,
                                 violation("timestamp %s is not the seconds of the snapshot id %s" % (v, sid)))
        if is_verified or is_observed or is_withheld:
            for path, kind, s0, s1 in scalars:
                hit = (is_verified and path == ("timestamp",)) or (is_observed and path == ("at",)) or \
                      (is_withheld and len(path) == 2 and path[1] == "at")
                if hit and kind == "number":
                    v = text[s0:s1]
                    c = self.claim("record %s@%d:%s" % (rel, wrote, json.dumps(path)), k, "epoch", v)
                    if is_withheld:
                        # Explicit fixture groups identify entry subjects before
                        # execution. Values in the output cannot choose a group.
                        groups = self.case.get('native_withheld_groups', {}).get(str(k), [])
                        matches = [i for i, group in enumerate(groups) if path[0] in group]
                        if len(matches) == 1:
                            index = matches[0]
                            c.native_binding = ('NpmWithheldEntry', index, len(groups))
                            c.role = 'clock:step%d:NpmWithheldEntry:%d' % (k, index)
                    self.add_claim(place, s0, s1, "record-time", c)
        if is_call:
            pdir = [json_string_value(text, s0, s1) for path, kind, s0, s1 in scalars if path == ("project_dir",) and kind == "string"]
            for path, kind, s0, s1 in scalars:
                if len(path) == 3 and path[:2] == ("npm_trace", "inodes") and kind == "string" and s1 > s0:
                    v = json_string_value(text, s0, s1)
                    if len(pdir) != 1 or pdir[0] is None:
                        self.add(place, s0, s1, v, "pending-inode", "ino:%s:own" % path[2],
                                 unresolved("the record does not name one project_dir to read %s in" % path[2]))
                        continue
                    if v != text[s0:s1]:
                        self.add(place, s0, s1, text[s0:s1], 'pending-inode', 'escaped-inode',
                                 unresolved('escaped scalar has no byte-to-component attribution'))
                    else:
                        self.inode_parts(place, s0, v, k, pdir[0], path[2], single=True)
        if is_backstop:
            cwd = self.hook_cwd(k)
            for path, kind, s0, s1 in scalars:
                if len(path) == 2 and path[0] in ("inodes", "clocks") and kind == "string" and s1 > s0:
                    v = json_string_value(text, s0, s1)
                    if v != text[s0:s1]:
                        self.add(place, s0, s1, text[s0:s1], 'pending-' + path[0], 'escaped-stat',
                                 unresolved('escaped scalar has no byte-to-component attribution'))
                        continue
                    if path[0] == "inodes":
                        self.inode_parts(place, s0, v, k, cwd, path[1], single=False)
                    else:
                        self.clock_parts(place, s0, v, k, cwd, path[1])

    def hook_cwd(self, k):
        """The directory the hook input names, or the hook's own where it
        names none, as realpath resolves it."""
        s = self.side.steps[k]
        return s.get("input_cwd_resolved", s["cwd"])

    def path_fact(self, k, d, rel):
        """lstat (and, through a link, stat) of <d>/<rel> at boundary k, where
        it is the same object at boundary k+1. Returns (own, follow, why): own
        or follow None where there is nothing there; why set when the fact
        cannot be read."""
        p = os.path.normpath(os.path.join(d, rel))
        box = self.side.box
        if not (p + "/").startswith(box + "/"):
            return None, None, "%s is outside the sandbox" % p
        r = os.path.relpath(p, box)
        before, after = self.side.bounds[k].get(r), self.side.bounds[k + 1].get(r)

        def ident(e):
            return e and (e.get("kind"), e.get("ino"), e.get("ctime_ns"), json.dumps(e.get("follow"), sort_keys=True))
        if ident(before) != ident(after):
            return None, None, "%s is not the same object before and after step %d" % (r, k)
        if not before:
            return None, None, None
        follow = before.get("follow") if before["kind"] == "link" else before
        if follow is not None and "error" in follow:
            follow = None
        return before, follow, None

    def inode_parts(self, place, s0, v, k, d, rel, single):
        own, follow, why = self.path_fact(k, d, rel)
        parts = [v] if single else v.split("|")
        if not single and len(parts) != 2:
            self.add(place, s0, s0 + len(v), v, "pending-inode", "ino:%s" % rel, violation("%r is not <own>|<target>" % v))
            return
        names = ["own"] if single else ["own", "target"]
        pos = s0
        for name, part in zip(names, parts):
            role = "ino:%s:%s" % (rel, name)
            if part:
                fact = own if name == "own" else follow
                if why:
                    res = unresolved(why)
                elif fact is None:
                    res = violation("%s has no %s inode at boundary %d" % (rel, name, k))
                elif part == str(fact["ino"]):
                    res = ok(token(role), ["lstat:boundary%d:%s" % (k, rel)])
                else:
                    res = violation("%s is not the %s inode of %s at boundary %d (%s)" % (part, name, rel, k, fact["ino"]))
                self.add(place, pos, pos + len(part), part, "pending-inode", role, res)
            pos += len(part) + 1

    def clock_parts(self, place, s0, v, k, d, rel):
        own, follow, why = self.path_fact(k, d, rel)
        parts = v.split("|")
        if len(parts) != 2:
            self.add(place, s0, s0 + len(v), v, "pending-clock", "ctime:%s" % rel, violation("%r is not <own>|<target>" % v))
            return
        pos = s0
        for name, part in zip(("own", "target"), parts):
            role = "ctime:%s:%s" % (rel, name)
            if part:
                ns = stat_clock_ns(part)
                fact = own if name == "own" else follow
                if why:
                    res = unresolved(why)
                elif ns is None:
                    res = violation("%r is not a time stat prints" % part)
                elif fact is None:
                    res = violation("%s has no %s ctime at boundary %d" % (rel, name, k))
                elif ns == fact["ctime_ns"]:
                    res = ok(token(role), ["lstat:boundary%d:%s" % (k, rel)])
                else:
                    res = violation("%s is not the %s ctime of %s at boundary %d (%d ns)" % (part, name, rel, k, fact["ctime_ns"]))
                self.add(place, pos, pos + len(part), part, "pending-clock", role, res)
            pos += len(part) + 1

    def npm_calls(self, k, s):
        tmp = s["env"].get("TMPDIR", "")
        if not tmp:
            return
        rx = re.compile(re.escape(tmp) + r"/safedeps-npm-ask\.([A-Za-z0-9]{6})(?=/|$)")
        before = self.side.bounds[k]
        for c in s.get("npm_calls", []):
            for field, w in npm_fields(c):
                for m in rx.finditer(w):
                    d = w[:m.end()]
                    seen = c.get("paths", {}).get(d)
                    rel = os.path.relpath(d, self.side.box)
                    if not seen or seen.get("kind") != "dir":
                        res = unresolved("the stand-in npm did not see %s as a directory while it ran" % d)
                    elif rel in before:
                        res = violation("%s was there before step %d" % (rel, k))
                    else:
                        res = ok(token("scratch"), ["npm-call:step%d#%d:%s:%s" % (k, c["seq"], seen["dev"], seen["ino"])])
                    self.add(place_npm(k, c["seq"], field), m.start(1), m.end(1), m.group(1), "npm-scratch", "scratch", res)


def npm_fields(call):
    """The strings of a stand-in npm call record a slot can stand in, by name."""
    return [("argv %d" % i, w) for i, w in enumerate(call["argv"])] + \
           [("env %s" % n, v) for n, v in sorted(call["env"].items())]


def find(case, side):
    """Every occurrence of a slot on one side, checked."""
    occ = Finder(case, side).run()
    return occ
