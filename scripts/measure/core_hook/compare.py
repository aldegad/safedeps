"""safedeps core-hook-differential: a case's two sides, compared.

The input is a raw bundle (observe.py) and nothing else, so the same bundle
gives the same verdict every time it is read. For each side the slots
(slots.py) find and check every occurrence. The comparison form of a channel
is its bytes with each occurrence's span written as its role's token; every
other byte, the order of the entries, their count, kind and mode stay as they
are. A role's token is the same on both sides, so two occurrences compare
equal exactly when they stand for the same role in the same place; which
objects share a role (a snapshot named in a record and in a message) is
compared through the tokens, not through the values.

The verdict:

  different   a channel differs in that form, or a candidate occurrence is a
              violation of its slot
  unresolved  nothing differs, but an occurrence on either side could not be
              checked, the reference violates a slot (the comparison has no
              footing), two entries of one side read as the same entry, or an
              observation the comparison needs is missing (an unreadable entry,
              a walk that failed, a stand-in call that had not ended)
  equal       everything compared is equal and every occurrence was checked

An exclusion is not a slot. The two the parent contract names are kept apart,
listed with their bytes' digests and counted, and a case that has any is
equal only on the channels it compared:

  deadline-tmp     in a case of the deadline family, what is left under tmp/
                   (the reference kills its child at the deadline and the
                   child leaves files)
  bash-diagnostic  a stderr line of a step a bash hook ran on that side that
                   reads as bash's own (`<script>: line N: ...`, `bash: ...`)
"""
import difflib
import fnmatch
import hashlib
import json
import re

from . import slots

BASH_DIAG = re.compile(r"^(?:\S*/)?[A-Za-z0-9_.-]+\.sh: line [0-9]+: .*$|^bash: .*$")
EXCLUSIONS = ("deadline-tmp", "bash-diagnostic")


def rendered(text, occs):
    """Typed fragments: literal bytes cannot impersonate a role token."""
    out = []
    pos = 0
    for o in sorted(occs, key=lambda o: (o.start, o.end)):
        if o.start < pos:
            raise ValueError('overlapping raw occurrence spans')
        out.append(["bytes", text[pos:o.start]])
        out.append(["slot", o.role])
        pos = o.end
    out.append(["bytes", text[pos:]])
    return json.dumps(out, ensure_ascii=True, separators=(",", ":"))


def expected(case, side):
    """Fixture assertions on raw output, independent of occurrence rewriting."""
    from .observe import fill
    errors = []
    for k, spec in enumerate(case["steps"]):
        got = side.hook(k)
        if not got:
            continue
        exp = spec.get("expect", {})
        want = exp.get("status", "exit 0")
        if got["status"] != want:
            errors.append("step %d status: %s, expected %s" % (k, got["status"], want))
        raw = {ch: side.blobs.get(got[ch]) for ch in ("stdout", "stderr")}
        if "decision" in exp:
            try:
                decision = json.loads(raw["stdout"])["hookSpecificOutput"].get("permissionDecision", "none")
            except (ValueError, KeyError, TypeError, AttributeError):
                decision = "none"
            if decision != exp["decision"]:
                errors.append("step %d decision: %s, expected %s" % (k, decision, exp["decision"]))
        for ch in ("stdout", "stderr"):
            for needle in exp.get(ch + "_has", []):
                if fill(needle, side.box).encode("utf-8") not in raw[ch]:
                    errors.append("step %d %s lacks %r" % (k, ch, needle))
        if exp.get("stdout_empty") and raw["stdout"]:
            errors.append("step %d stdout is not empty" % k)
        entries = side.bounds[k + 1]
        for pat in exp.get("tree_has", []):
            if pat.startswith("calls/npm/"):
                present = bool(got.get("npm_calls"))
            else:
                present = any(fnmatch.fnmatchcase(rel, pat) for rel in entries)
            if not present:
                errors.append("step %d has no %s" % (k, pat))
        for pat in exp.get("tree_lacks", []):
            if any(fnmatch.fnmatchcase(rel, pat) for rel in entries):
                errors.append("step %d unexpectedly has %s" % (k, pat))
        for rel, needles in exp.get("file_has", {}).items():
            entry = entries.get(rel, {})
            body = side.blobs.get(entry["blob"]) if "blob" in entry else b""
            for needle in needles:
                if fill(needle, side.box).encode("utf-8") not in body:
                    errors.append("step %d %s lacks %r" % (k, rel, needle))
    return errors


class SideDoc:
    """One side of a case in the form the two sides are compared in."""

    def __init__(self, case, side_doc):
        self.case = case
        self.side = slots.Side(case, side_doc)
        self.occ = slots.find(case, self.side)
        self.by_place = {}
        for o in self.occ:
            self.by_place.setdefault(o.place, []).append(o)
        self.gaps = []
        self.native_gaps = []
        if any(s.get('impl') == 'core' for s in self.side.steps):
            from .native import gaps
            self.native_gaps = gaps(self.side, self.occ)
        self.excluded = []
        self.collisions = []
        for place, occurrences in self.by_place.items():
            end = -1
            for o in sorted(occurrences, key=lambda o: (o.start, o.end)):
                if o.start < end:
                    raise ValueError("overlapping occurrence attribution at %s" % place)
                end = max(end, o.end)
        self.rows = self.build()

    def place(self, p, text):
        return rendered(text, self.by_place.get(p, []))

    def build(self):
        side = self.side
        rows = [("step kinds", json.dumps([s["kind"] for s in side.steps]))]
        deadline = self.case.get("family") == "deadline"
        rows.extend(self.tree(0, 'seed', False))
        for b, err in side.walk_errors:
            self.gaps.append("boundary %d: the walk of the sandbox failed at %s" % (b, err))
        for k, s in enumerate(side.steps):
            if s["kind"] != "hook":
                p = "step %d effect" % k
                rows.append((p + " operations", json.dumps(s["ops"], sort_keys=True)))
                rows.extend(self.tree(k + 1, p, deadline))
                continue
            p = "step %d %s" % (k, s["hook"])
            rows.append((p + " stdin", side.text(s["stdin"])))
            rows.append((p + " cwd", s["cwd"]))
            rows.append((p + " env", json.dumps(s['env'], sort_keys=True)))
            rows.append((p + " status", s["status"]))
            rows.append((p + " stdout", self.place(slots.place_out(k, "stdout"), side.text(s["stdout"]))))
            rows.append((p + " stderr", self.stderr(k, s)))
            rows.extend(self.npm(k, s, p))
            rows.extend(self.tree(k + 1, p, deadline))
        return rows

    def stderr(self, k, s):
        raw = self.side.text(s["stderr"])
        if s["impl"] != "bash":
            return self.place(slots.place_out(k, "stderr"), raw)
        # Exclusions use raw line spans; no canonical value creates a diagnostic.
        kept = []
        pos = 0
        all_occ = self.by_place.get(slots.place_out(k, "stderr"), [])
        for line in raw.splitlines(keepends=True):
            if BASH_DIAG.fullmatch(line.rstrip("\n")):
                self.excluded.append({"exclusion": "bash-diagnostic", "step": k, "line": line,
                                      "sha256": hashlib.sha256(line.encode("latin-1")).hexdigest()})
            else:
                offsets = []
                for o in all_occ:
                    if pos <= o.start and o.end <= pos + len(line):
                        from copy import copy
                        shifted = copy(o)
                        shifted.start -= pos
                        shifted.end -= pos
                        offsets.append(shifted)
                kept.append(rendered(line, offsets))
            pos += len(line)
        # Same fragment representation for core and bash, including line breaks.
        fragments = [part for line in kept for part in json.loads(line)]
        merged = []
        for part in fragments:
            if merged and part[0] == merged[-1][0] == "bytes":
                merged[-1][1] += part[1]
            else:
                merged.append(part)
        if not merged:
            merged = [["bytes", ""]]
        return json.dumps(merged, ensure_ascii=True, separators=(",", ":"))

    def npm(self, k, s, p):
        calls = []
        groups = {}
        for c in s.get("npm_calls", []):
            rec = {}
            for name in ("cwd", "stdout", "stderr", "exit", "answer"):
                rec[name] = c.get(name)
            rec["argv"] = [self.place(slots.place_npm(k, c["seq"], "argv %d" % i), w) for i, w in enumerate(c["argv"])]
            rec["env"] = {n: self.place(slots.place_npm(k, c["seq"], "env %s" % n), v) for n, v in sorted(c["env"].items())}
            line = json.dumps(rec, sort_keys=True, ensure_ascii=False)
            calls.append(line)
            for o in self.occ:
                if o.slot == "npm-scratch" and o.place.startswith("step %d npm call %d " % (k, c["seq"])) and o.result.status == "ok":
                    obj = o.result.witness[0].rsplit(":", 2)[-2:]
                    groups.setdefault(tuple(obj), set()).add(line)
        for inc in s.get("incomplete_calls", []):
            if "npm" in inc:
                self.gaps.append("step %d: the stand-in npm call %s had not ended when the harness looked" % (k, inc["npm"]))
        if not calls:
            return []
        shared = sorted(json.dumps(sorted(g), ensure_ascii=False) for g in groups.values())
        return [(p + " npm calls", "\n".join(calls)), (p + " npm scratch", "\n".join(shared))]

    def tree(self, b, p, deadline):
        side = self.side
        entries = side.bounds[b]
        rows = {}
        for rel, e in sorted(entries.items()):
            if deadline and rel.startswith("tmp/"):
                self.excluded.append({"exclusion": "deadline-tmp", "boundary": b, "name": rel, "kind": e.get("kind"),
                                      "size": e.get("size"), "blob": e.get("blob")})
                continue
            name = self.place(slots.place_name(b, rel), rel)
            kind = e.get("kind")
            if kind == "gone" or "read_error" in e:
                self.gaps.append("boundary %d: %s could not be read (%s)" % (b, rel, e.get("read_error") or e.get("lstat_error")))
                body = "%s %s\n%s" % (kind, e.get("mode", ""), slots.token("unread"))
            elif kind == "file":
                body = "file %s\n%s" % (e["mode"], self.place(slots.place_file(b, rel), side.text(e["blob"])))
            elif kind == "link":
                body = "link\n%s" % e.get("target", "")
            else:
                body = "%s %s" % (kind, e.get("mode", ""))
            key = "%s tree %s" % (p, name)
            if key in rows:
                self.collisions.append("boundary %d: %s and another entry both read as %s" % (b, rel, name))
                continue
            rows[key] = body
        return sorted(rows.items())


def compare_case(case, bundle):
    """The verdict of one case from its bundle's two sides."""
    admission = bundle.get('_evidence', {'status': 'unresolved', 'reason': 'no evidence admission',
                                          'collection_kind': bundle.get('meta', {}).get('collection_kind')})
    if admission['status'] != 'accepted':
        return {"verdict": 'invalid' if admission['status'] == 'invalid' else 'unresolved',
                'evidence': admission, 'different': [], 'violations': {'reference': [], 'candidate': []},
                'unresolved': [], 'gaps': [{'side': 'evidence', 'gap': admission['reason']}],
                'collisions': [], 'excluded': [], 'expectations': {'reference': [], 'candidate': []},
                'receipts': {'reference': [], 'candidate': []}, 'occurrences': {'reference': {}, 'candidate': {}},
                '_docs': ({}, {}), '_occ': ([], [])}
    ref = SideDoc(case, bundle["sides"]["reference"])
    cand = SideDoc(case, bundle["sides"]["candidate"])
    a, b = dict(ref.rows), dict(cand.rows)
    keys = list(dict.fromkeys([k for k, _ in ref.rows] + [k for k, _ in cand.rows]))
    different = [k for k in keys if a.get(k) != b.get(k)]
    viol = {"reference": [o.describe() for o in ref.occ if o.result.status == "violation"],
            "candidate": [o.describe() for o in cand.occ if o.result.status == "violation"]}
    unres = [dict(o.describe(), side=name) for name, sd in (("reference", ref), ("candidate", cand))
             for o in sd.occ if o.result.status == "unresolved"]
    gaps = [{"side": name, "gap": g} for name, sd in (("reference", ref), ("candidate", cand)) for g in sd.gaps]
    gaps.extend({'side': name, 'gap': g, 'scope': 'native-clock'}
                for name, sd in (('reference', ref), ('candidate', cand)) for g in sd.native_gaps)
    collisions = [{"side": name, "collision": c} for name, sd in (("reference", ref), ("candidate", cand)) for c in sd.collisions]
    expectations = {"reference": expected(case, ref.side), "candidate": expected(case, cand.side)}
    if different or viol["candidate"] or expectations["candidate"]:
        verdict = "different"
    elif viol["reference"] or unres or gaps or collisions or expectations["reference"]:
        verdict = "unresolved"
    else:
        verdict = "equal"
    excluded = [dict(x, side="reference") for x in ref.excluded] + [dict(x, side="candidate") for x in cand.excluded]
    return {"verdict": verdict, "evidence": admission, "different": different, "violations": viol, "unresolved": unres, "gaps": gaps,
            "collisions": collisions, "excluded": excluded, "expectations": expectations,
            "receipts": {"reference": [o.describe() for o in ref.occ], "candidate": [o.describe() for o in cand.occ]},
            "occurrences": {"reference": count_occ(ref.occ), "candidate": count_occ(cand.occ)},
            "_docs": (a, b), "_occ": (ref.occ, cand.occ)}


def count_occ(occ):
    out = {}
    for o in occ:
        k = "%s %s" % (o.slot, o.result.status)
        out[k] = out.get(k, 0) + 1
    return out


def channel(key):
    m = re.match(r"step [0-9]+ (?:pre|post) (status|stdout|stderr|npm calls|npm scratch|tree (.*))$", key)
    if not m:
        return key
    if m.group(2) is not None:
        try:
            parts = json.loads(m.group(2))
            name = "".join(v if kind == "bytes" else "<" + v + ">" for kind, v in parts)
        except ValueError:
            name = m.group(2)
        return "tree:" + name
    return m.group(1).replace(" ", "-")


def red_channels(result):
    """The channels a different case is red in, violations as `violation:<slot>`."""
    chans = set(channel(k) for k in result["different"])
    chans |= set("violation:" + v["slot"] for v in result["violations"]["candidate"])
    return sorted(chans)


def show(result, limit=24):
    """Lines a person reads: what differs, what could not be checked."""
    out = []
    a, b = result["_docs"]
    shown = set()
    for k in result["different"]:
        ch = channel(k)
        if ch in shown:
            continue
        shown.add(ch)
        if len(shown) > 8:
            out.append("  ... more channels differ; see --report")
            break
        if a.get(k) is None or b.get(k) is None:
            out.append("  %s: only in the %s" % (k, "reference" if b.get(k) is None else "candidate"))
            continue
        lines = list(difflib.unified_diff(a[k].split("\n"), b[k].split("\n"), "reference", "candidate", lineterm="", n=1))
        out.append("  %s:" % k)
        out.extend("    " + l[:400] for l in lines[2:limit + 2])
        if len(lines) > limit + 2:
            out.append("    ... %d more lines" % (len(lines) - limit - 2))
    for side in ("candidate", "reference"):
        for v in result["violations"][side][:8]:
            out.append("  %s violates %s at %s %s: %s" % (side, v["slot"], v["place"], v["span"], v["reason"]))
    for u in result["unresolved"][:8]:
        out.append("  unresolved on the %s: %s at %s: %s" % (u["side"], u["slot"], u["place"], u["reason"]))
    if len(result["unresolved"]) > 8:
        out.append("  ... %d more unresolved occurrences; see --report" % (len(result["unresolved"]) - 8))
    for g in result["gaps"][:8]:
        out.append("  missing on the %s: %s" % (g["side"], g["gap"]))
    for c in result["collisions"][:8]:
        out.append("  ambiguous on the %s: %s" % (c["side"], c["collision"]))
    return out


def report_row(case_id, result, bundle_path=None, bundle_sha=None):
    row = {k: v for k, v in result.items() if not k.startswith("_")}
    row["id"] = case_id
    if bundle_path:
        row["bundle"] = {"path": bundle_path, "sha256": bundle_sha}
    return row


def verdict_digest(rows):
    """A digest of the verdicts alone, which a replay of the same bundles has
    to reproduce."""
    keep = []
    for r in sorted(rows, key=lambda r: r["id"]):
        keep.append({k: r.get(k) for k in ("id", "verdict", "different", "violations", "unresolved", "gaps",
                                            "collisions", "excluded", "occurrences", "expectations", "receipts", "control", "evidence")})
    return hashlib.sha256(json.dumps(keep, sort_keys=True, ensure_ascii=True).encode()).hexdigest()
