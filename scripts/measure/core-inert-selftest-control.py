#!/usr/bin/env python3
"""safedeps: the control of core-inert-differential.py's selftest.

A selftest that cannot fail says nothing. Each mutation here puts back one
thing an earlier version of the comparison got wrong, in a copy of the tree
made in a scratch directory (never in the tree this file is in), and the
selftest run on that copy must print `not ok` for the case that holds it.

  ok <mutation>: red at <case>      the selftest caught it
  not ok <mutation>: ...            the selftest stayed green, or the case
                                    named was not the one that failed

Exit 0 only when every mutation is caught at its case and the unmutated copy
is green.

--cli DIR is the control of what the CLI writes. A selftest that calls a
function is not the CLI: the summary, the table, the manifest and the report
are written after it. Each mutation of CLI_MUTATIONS damages one projection or
one count at that boundary in a copy of the tree. The copy's own CLI then
classifies a saved input from DIR again (--reclassify, with --report, --table
and --manifest, then the report it wrote fed back to it), and the check named
must turn red on what it wrote. The checks read the input's JSON and the
outputs with this file's own code and import nothing of the comparison. A run
that ends with no report, table and manifest that read is not a detection,
and no mutation is counted while the unmutated copy fails a check.

Usage: core-inert-selftest-control.py [--path-prefix DIRS]
       core-inert-selftest-control.py --cli DIR [--cli-out DIR]
"""
import argparse
import base64
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

MEASURE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(MEASURE))
NAME = "core-inert-differential.py"

# (name, the text to find, what replaces it, a case that must turn red)
MUTATIONS = [
    ("an argument is split at blanks again",
     'STUB_NPM = \'#!/bin/sh\\nprintf \\\'%s\\\\0\\\' npm "$#" "$@" >> "$NPMLOG"\\n\'',
     'STUB_NPM = \'#!/bin/sh\\nprintf \\\'%s\\\\0\\\' npm "$#" $* >> "$NPMLOG"\\n\'',
     "argv keeps a tab, a newline and an empty word"),
    ("every --ignore-scripts word is taken out before two calls compare",
     '    ins = []\n    i = 0\n    for j, a in enumerate(s):',
     '    if [x for x in w if x != FLAGWORD] == [x for x in s if x != FLAGWORD]:\n'
     '        return [j for j, x in enumerate(s) if x == FLAGWORD][:max(0, len(s) - len(w))]\n'
     '    ins = []\n    i = 0\n    for j, a in enumerate(s):',
     "a `--ignore-scripts` after `--` that is gone is an argument changed"),
    ("the first word without a dash is the command",
     '    if g is None or n is None or not g.get("read"):\n        return None\n    gw = ',
     '    for a_ in argv:\n        if a_ == "--":\n            return False\n        if a_.startswith("-"):\n            continue\n'
     '        return bool(INSTALL_VERB.match(a_))\n'
     '    if g is None or n is None or not g.get("read"):\n        return None\n    gw = ',
     "`npm --prefix d ci` is an install"),
    ("a disagreement on both sides with equal bytes is `same`",
     '        if bden and cden:\n            counts["both_undecided"] += 1',
     '        if bden and cden and toks:\n            counts["both_undecided"] += 1',
     "equal values that disagree among the readings on both sides: both-undecided"),
    ("a shell with no run reads as one that made no call",
     '    rec = side_record(s)\n    unknown = bad = eff_unknown = False',
     '    ss = {sh: ss.get(sh, {"rc": 0, "timeout": False, "log": "ok", "npm": [], "other": [], "calls": [], "files": {"d": ["d"]},\n'
     '                         "stdout_len": 0, "stdout_sha256": "x", "stderr_len": 0, "stderr_sha256": "x",\n'
     '                         "_axes": {x: "ok" for x in AXES}}) for sh in SHELLS}\n'
     '    rec = side_record(s)\n    unknown = bad = eff_unknown = False',
     "a shell with no run is unknown, not an empty call"),
    ("no install call in any shell counts as held",
     'UNKNOWN if unknown else "ok" if installs else "nocall"',
     'UNKNOWN if unknown else "ok"',
     "no install call in any shell is `nocall`, not `ok`"),
    ("a row with no direction matches any class",
     '            if not dirs:\n                if "~kind" not in ctoks:\n                    continue\n            elif not dirs <= ctoks:',
     '            if not dirs:\n                pass\n            elif not dirs <= ctoks:',
     "a text with no payload whose records differ in kind alone is named by no class"),
    ("a file a command wrote is not looked at",
     '                    out[rel] = ["f", os.path.getsize(p), sha256(b)]',
     '                    out[rel] = ["f"]',
     "npm calls alike, a file's content apart: the files differ"),
    ("the exit status is not compared",
     '    for name in EFFECTS:\n        aw, as_ = axis(w, name), axis(s, name)',
     '    out["rc"] = "same"\n    for name in EFFECTS[1:]:\n        aw, as_ = axis(w, name), axis(s, name)',
     "a flag handed to another command changes the exit status"),
    ("a state worse than the bash side's is not a decrease",
     '            elif worse is True:\n                put(res, "decrease")',
     '            elif False:\n                put(res, "decrease")',
     "the bash side reads true where the core only records: a decrease"),
    ("a record hides a second call that lost its option",
     '            if fx and not fy:\n                out["true_to_false"] += 1',
     '            if fx and not fy and not side_record(res["sides"][side]):\n                out["true_to_false"] += 1',
     "a second call that goes from true to false is counted, record or no record"),
    ("npm calls that hold cover a difference in what the command printed",
     '    v["effects"] = "differ:" + ",".join(sorted(differ)) if differ else "invalid" if eff_invalid else UNKNOWN if eff_unknown else "same"',
     '    v["effects"] = "same" if v["npm"] == "ok" else ("differ:" + ",".join(sorted(differ)) if differ else "invalid" if eff_invalid'
     ' else UNKNOWN if eff_unknown else "same")',
     "npm calls that hold do not cover a stdout that differs"),
    ("the exact env -S row is named without asking the shells",
     '            why = env_split_string_read(res, R)\n',
     '            why = None\n',
     "an argument gone from a call refuses the exact env -S row"),
    ("the intake looks at nothing: every axis of every run is evidence",
     '    return ax.get(name, UNKNOWN)\n',
     '    return "ok"\n',
     "a null exit status on both sides is no evidence"),
    ("an axis that is not evidence counts as an effect that held",
     '            elif r[axis_] == "invalid":\n                eff_invalid = True',
     '            elif False:\n                eff_invalid = True',
     "an exit status that is no evidence is no effect that held"),
    ("a row with invalid evidence is counted with the rows that ran",
     '        if why_ is not None:\n            if why_ == "its evidence is invalid":',
     '        if why_ == "the row is invalid":\n            if why_ == "its evidence is invalid":',
     "a row whose evidence is invalid is in no count of what ran"),
    ("a row whose own records do not read is counted as one that holds",
     '        if res.get("slot") != "admitted":\n            counts["invalid"] += 1\n            put(res, "invalid")',
     '        if res.get("slot") != "admitted":\n            counts["same"] += 1\n            put(res, "same")',
     "a reading named twice makes the row invalid"),
    ("a saved floor is believed",
     '            if saved_floor is not None and saved_floor != v:\n',
     '            if False:\n',
     "a saved floor its row does not hold is invalid"),
    ("the report keeps the evaluated rows in place of the source",
     '            "source": dict(src_info, sha256=sha256(src_bytes), bytes_b64=base64.b64encode(src_bytes).decode("ascii")),',
     '            "source": dict(src_info, sha256=sha256(json.dumps(dict(json.loads(src_bytes), rows=evaluation["rows"])).encode()),'
     ' bytes_b64=base64.b64encode(json.dumps(dict(json.loads(src_bytes), rows=evaluation["rows"])).encode()).decode("ascii")),',
     "a saved floor at odds with its basis is found again from the report"),
    ("a report with no run is taken as measured",
     '        return "invalid", "the report holds no run: this schema writes the run that measured it"',
     '        return "ok", None',
     "a report with no run counts nothing as held"),
    ("a missing any_install reads as an install",
     '        if schema != 1:\n            return "%s: no any_install',
     '        if False:\n            return "%s: no any_install',
     "core records with no any_install make the row invalid"),
    ("a slot that is no object is left out",
     '        slot = raw if isinstance(raw, dict) else {}\n        admit(slot, k, ctx, jtype(raw))\n',
     '        if not isinstance(raw, dict):\n            continue\n        slot = raw\n        admit(slot, k, ctx, jtype(raw))\n',
     "a null row is a slot of its own, invalid, beside the rows that read"),
    ("a core payload count at odds with A's is believed",
     '                if len(x["payloads"]) != n:\n',
     '                if False:\n',
     "a core payload count at odds with A's words makes the evidence invalid"),
    ("a saved reader value at odds with its answers is only counted",
     '                    self.problems.append("readings[%d]: it says %s %r, and its two answers give %r" % (k, f, e[f], v))',
     '                    pass',
     "a saved reader value at odds with its answers is not believed, and stays found"),
    ("calls that disagree with their npm calls are believed",
     '            put("npm", "ok" if npm_ok else "invalid", None if npm_ok else "npm is not the npm calls of calls")',
     '            put("npm", "ok")',
     "npm calls that are not the npm calls of calls are invalid"),
    ("a row with nothing run is counted with the rows that ran",
     '            if why is not None:\n                p["not_paired"][why] = p["not_paired"].get(why, 0) + 1\n                continue',
     '            if False:\n                p["not_paired"][why] = p["not_paired"].get(why, 0) + 1\n                continue',
     "a row the core blocks, one it leaves undecided and one with no run are in no count of what ran"),
]


# The control of what the CLI writes (--cli): (name, the saved input it is
# run on, the text to find, what replaces it, the check that must turn red).
CLI_MUTATIONS = [
    ("a rejected slot is left out of what the run writes, its counts kept", "null-row.json",
     '    head = {"contract": CONTRACT, "source": dict(src_info, sha256=sha256(src_bytes)),\n',
     '    results = [r for r in results if r.get("slot") == "admitted"]\n'
     '    head = {"contract": CONTRACT, "source": dict(src_info, sha256=sha256(src_bytes)),\n',
     "slots"),
    ("a row whose evidence is invalid counts as one that held", "mixed-slots.json",
     '    if ev.get("invalid"):\n        return "its evidence is invalid"\n',
     '    if False:\n        return "its evidence is invalid"\n',
     "held"),
    ("the report keeps a source made to agree with its evaluation, under that source's own sha256", "floor-conflict.json",
     '            "source": dict(src_info, sha256=sha256(src_bytes), bytes_b64=base64.b64encode(src_bytes).decode("ascii")),',
     '            "source": (lambda b: dict(src_info, sha256=sha256(b), bytes_b64=base64.b64encode(b).decode("ascii")))(json.dumps(dict(\n'
     '                json.loads(src_bytes), rows=[dict(r, floor=e["floor"]) if isinstance(r, dict) and e.get("floor") else r\n'
     '                                             for r, e in zip(json.loads(src_bytes)["rows"], evaluation["rows"])])).encode("ascii")),',
     "source"),
]
# The keys a rejected slot may hold: what it shows, and nothing of the row.
REJECTED_KEYS = {"slot", "raw_type", "set", "command", "evidence", "status"}


def sha(b):
    return hashlib.sha256(b).hexdigest()


def cli_tree(work):
    """A copy of what the CLI reads: the grammar, the pre-guard it hashes, and
    the comparison's own files."""
    tree = os.path.join(work, "tree")
    os.makedirs(os.path.join(tree, "scripts", "measure"))
    shutil.copytree(os.path.join(ROOT, "lib"), os.path.join(tree, "lib"))
    shutil.copy(os.path.join(ROOT, "scripts", "safedeps-pre-guard.sh"), os.path.join(tree, "scripts"))
    for f in os.listdir(MEASURE):
        if f.startswith("core-inert-") or f == "core-intended-inert.tsv":
            shutil.copy(os.path.join(MEASURE, f), os.path.join(tree, "scripts", "measure", f))
    return tree


def cli_run(tree, args, out):
    """One run of the copy's CLI, its three outputs in `out`: its rc, or None
    where it did not end in time."""
    os.makedirs(out)
    cmd = ["nice", "-n", "10", sys.executable, os.path.join(tree, "scripts", "measure", NAME)] + args + [
        "--report", os.path.join(out, "report.json"), "--table", os.path.join(out, "table.tsv"),
        "--manifest", os.path.join(out, "manifest.jsonl")]
    try:
        r = subprocess.run(cmd, capture_output=True, timeout=600)
        rc, so, se = r.returncode, r.stdout, r.stderr
    except subprocess.TimeoutExpired as e:
        rc, so, se = None, e.stdout or b"", (e.stderr or b"") + b"\n(timeout)"
    open(os.path.join(out, "stdout"), "wb").write(so)
    open(os.path.join(out, "stderr"), "wb").write(se)
    open(os.path.join(out, "rc"), "w").write("%s\n" % rc)
    return rc


def cli_read(out):
    """What a run wrote: (report, table lines, manifest lines), or the reason
    it does not read."""
    try:
        rep = json.load(open(os.path.join(out, "report.json"), encoding="utf-8"))
        table = open(os.path.join(out, "table.tsv"), encoding="utf-8").read().split("\n")
        man = [json.loads(l) for l in open(os.path.join(out, "manifest.jsonl"), encoding="utf-8")]
    except (OSError, ValueError) as e:
        return "no report, table and manifest that read (%s)" % e
    if table[-1] != "" or not (isinstance(rep, dict) and rep.get("schema") == 3 and isinstance(rep.get("evaluation"), dict)
                               and isinstance(rep["evaluation"].get("rows"), list) and isinstance(rep.get("source"), dict)):
        return "a report that is not a v3 report, or a table with no line end"
    return rep, table[:-1], man


def chk_slots(inp, src, rep, table, man):
    """Every row of the source has its slot, in order, in the report, the
    table and the manifest; a row that is not an object is a rejected slot
    that holds nothing of a row."""
    n = len(src["rows"])
    rows = rep["evaluation"]["rows"]
    if not (len(rows) == n and len(table) == n and len(man) == n + 1):
        return False
    if [r["evidence"]["from"]["row"] for r in rows] != list(range(1, n + 1)) or [m["row"] for m in man[1:]] != list(range(1, n + 1)):
        return False
    for raw, r, m in zip(src["rows"], rows, man[1:]):
        if not isinstance(raw, dict) and (r["slot"] != "rejected" or not set(r) <= REJECTED_KEYS or m["slot"] != "rejected"):
            return False
    return True


def chk_source(inp, src, rep, table, man):
    """The report's source is the input's bytes, under their own sha256."""
    s = rep["source"]
    return s["sha256"] == sha(inp) and base64.b64decode(s["bytes_b64"]) == inp


def chk_invalid(inp, src, rep, table, man):
    """null-row.json: of its two rows the second, a null, is the one invalid
    row, and it shows no command."""
    c, r = rep["evaluation"]["summary"]["counts"], rep["evaluation"]["rows"][1]
    return [c["total"], c["invalid"], r["status"], r["raw_type"], r["command"]] == [2, 1, "invalid", "null", None]


def chk_held(inp, src, rep, table, man):
    """mixed-slots.json: only its second row, the one whose records all
    read, is in a count of what held (1 row, 4 shell runs and 8 calls paired
    beside the bash side); the third, whose core run in bash is no object, is
    listed as invalid evidence."""
    acc = rep["evaluation"]["summary"]["accounting"]
    b = acc["pairs"]["bash"]
    return acc["evidence_invalid"] == [2] and acc["ran_observed"] == 1 and [b["rows"], b["shells"], b["calls"]] == [1, 4, 8]


def chk_floor(inp, src, rep, table, man):
    """floor-conflict.json: its saved floor NOT is found again, and nothing
    of the row is in a count of what ran."""
    r = rep["evaluation"]["rows"][0]
    return (any(x.startswith("floor: saved 'NOT'") for x in r["evidence"]["invalid"])
            and rep["evaluation"]["summary"]["accounting"]["ran_observed"] == 0)


CLI_CHECKS = {"slots": chk_slots, "source": chk_source, "invalid": chk_invalid, "held": chk_held, "floor": chk_floor}
CLI_INPUTS = {"null-row.json": ("slots", "source", "invalid"), "mixed-slots.json": ("slots", "source", "held"),
              "floor-conflict.json": ("slots", "source", "floor")}


def cli_view(rep):
    """What an evaluation says, without where or when it was written."""
    ev = rep["evaluation"]
    acc = ev["summary"]["accounting"]
    return {"source": rep["source"]["sha256"], "provenance": ev["provenance"], "reader_problems": ev["reader_problems"],
            "rows": [(r.get("slot"), r.get("status"), r["evidence"]) for r in ev["rows"]], "counts": ev["summary"]["counts"],
            "red": ev["summary"]["red"], "accounting": {k: acc[k] for k in ("core", "ran_observed", "evidence_invalid",
                                                                               "provenance_unknown", "pairs")}}


def cli_case(tree, d, name, out):
    """One input, run and then replayed: {"rc", "rc_replay", "first",
    "replay", "same"}, each check True, False or why it could not be read."""
    path = os.path.join(d, name)
    inp = open(path, "rb").read()
    src = json.loads(inp)
    words = os.path.join(d, "words.log")
    att = ["--words", "%s=%s:%s" % (words, sha(open(words, "rb").read()), src["run"]["core_sha256"])]
    got = {"rc": cli_run(tree, ["--reclassify", path] + att, os.path.join(out, "first"))}
    first = cli_read(os.path.join(out, "first"))
    got["rc_replay"] = cli_run(tree, ["--reclassify", os.path.join(out, "first", "report.json")], os.path.join(out, "replay")) \
        if not isinstance(first, str) else None
    replay = cli_read(os.path.join(out, "replay")) if got["rc_replay"] is not None else "not replayed"
    for which, w in (("first", first), ("replay", replay)):
        if isinstance(w, str):
            got[which] = w
            continue
        got[which] = {}
        for c in CLI_INPUTS[name]:
            try:
                got[which][c] = bool(CLI_CHECKS[c](inp, src, *w))
            except (KeyError, IndexError, TypeError, ValueError) as e:
                got[which][c] = "the check could not read the output (%r)" % (e,)
    try:
        got["same"] = not isinstance(first, str) and not isinstance(replay, str) and cli_view(first[0]) == cli_view(replay[0])
    except (KeyError, IndexError, TypeError) as e:
        got["same"] = "could not be compared (%r)" % (e,)
    return got


def cli_holds(got):
    """Every check holds on both runs, both end 1, and the replay says what
    the first run said."""
    return (got["rc"] == 1 and got["rc_replay"] == 1 and got["same"] is True
            and all(isinstance(got[w], dict) and all(v is True for v in got[w].values()) for w in ("first", "replay")))


def cli_main(d, keep):
    work = tempfile.mkdtemp(prefix="safedeps-core-inert-cli-control.")
    out = keep or os.path.join(work, "out")
    os.makedirs(out, exist_ok=True)
    tree = cli_tree(work)
    target = os.path.join(tree, "scripts", "measure", NAME)
    source = open(target, encoding="utf-8").read()
    record = {"comparison_sha256": sha(source.encode("utf-8")), "baseline": {}, "mutations": []}
    bad = 0
    for name in CLI_INPUTS:
        got = cli_case(tree, d, name, os.path.join(out, "baseline", name))
        record["baseline"][name] = got
        print("%s the copy as it is, %s: %s" % ("ok" if cli_holds(got) else "not ok", name, json.dumps(got, sort_keys=True)))
        bad += 0 if cli_holds(got) else 1
    if bad:
        print("cli control: the copy as it is fails a check; no mutation is counted")
    else:
        for name, inp, old, new, check in CLI_MUTATIONS:
            m = {"name": name, "input": inp, "old": old, "new": new, "check": check}
            record["mutations"].append(m)
            if source.count(old) != 1:
                m["result"] = "its site is in the comparison %d times, not once" % source.count(old)
                print("not ok %s: %s" % (name, m["result"]))
                bad += 1
                continue
            mutated = source.replace(old, new)
            m["sha256_before"], m["sha256_after"] = sha(source.encode("utf-8")), sha(mutated.encode("utf-8"))
            open(target, "w", encoding="utf-8").write(mutated)
            got = cli_case(tree, d, inp, os.path.join(out, "mutation-%d" % len(record["mutations"]), inp))
            open(target, "w", encoding="utf-8").write(source)
            m["got"] = got
            if isinstance(got["first"], str):
                m["result"] = "not ok: the run wrote nothing that reads (%s); an exception is not a detection" % got["first"]
            elif got["first"].get(check) is False or (isinstance(got["replay"], dict) and got["replay"].get(check) is False):
                m["result"] = "ok"
            else:
                m["result"] = "not ok: `%s` stayed %r" % (check, got["first"].get(check))
            ok = m["result"] == "ok"
            bad += 0 if ok else 1
            print("%s %s: %s at `%s` on %s (rc %s, replay rc %s; the comparison %s -> %s)" % (
                "ok" if ok else "not ok", name, "red" if ok else m["result"], check, inp, got["rc"], got["rc_replay"],
                m["sha256_before"][:12], m["sha256_after"][:12]))
    json.dump(record, open(os.path.join(out, "cli-control.json"), "w"), indent=1, sort_keys=True)
    # The copy of the tree goes whatever is kept: what --cli-out keeps is
    # the runs' outputs, outside it.
    shutil.rmtree(work, ignore_errors=True)
    print("cli control: %d mutations, %d not ok" % (len(CLI_MUTATIONS), bad))
    sys.exit(1 if bad else 0)


def run(tree, prefix):
    cmd = [sys.executable, os.path.join(tree, "scripts", "measure", NAME), "--selftest"]
    if prefix:
        cmd += ["--path-prefix", prefix]
    r = subprocess.run(["nice", "-n", "10"] + cmd, capture_output=True, text=True, timeout=1200)
    red = [l[len("not ok "):] for l in r.stdout.split("\n") if l.startswith("not ok ")]
    return r.returncode, red, r.stdout + r.stderr


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--path-prefix", default="")
    ap.add_argument("--cli", default="", help="a directory of saved inputs: the control of what the CLI writes")
    ap.add_argument("--cli-out", default="", help="keep every run of --cli here")
    a = ap.parse_args()
    if a.cli:
        cli_main(os.path.abspath(a.cli), os.path.abspath(a.cli_out) if a.cli_out else "")
    work = tempfile.mkdtemp(prefix="safedeps-core-inert-control.")
    tree = os.path.join(work, "tree")
    # What the selftest reads: the grammar and the comparison's own files.
    os.makedirs(os.path.join(tree, "scripts", "measure"))
    shutil.copytree(os.path.join(ROOT, "lib"), os.path.join(tree, "lib"))
    for f in os.listdir(MEASURE):
        if f.startswith("core-inert-") or f == "core-intended-inert.tsv":
            shutil.copy(os.path.join(MEASURE, f), os.path.join(tree, "scripts", "measure", f))
    target = os.path.join(tree, "scripts", "measure", NAME)
    source = open(target, encoding="utf-8").read()
    bad = 0
    rc, red, text = run(tree, a.path_prefix)
    if rc != 0 or red:
        print("not ok the copy as it is: the selftest is red before any mutation (%s)" % (red or text[-300:]))
        bad += 1
    else:
        print("ok the copy as it is: the selftest is green")
    for name, old, new, case in MUTATIONS:
        if source.count(old) != 1:
            print("not ok %s: its site is in the comparison %d times, not once" % (name, source.count(old)))
            bad += 1
            continue
        open(target, "w", encoding="utf-8").write(source.replace(old, new))
        rc, red, text = run(tree, a.path_prefix)
        if any(l.startswith(case) for l in red):
            print("ok %s: red at `%s`%s" % (name, case, (" and %d more" % (len(red) - 1)) if len(red) > 1 else ""))
        elif rc != 0 and not red:
            print("not ok %s: the selftest ended %d without a case (%s)" % (name, rc, text.strip().split("\n")[-1][:200]))
            bad += 1
        else:
            print("not ok %s: `%s` stayed green (red: %s)" % (name, case, red))
            bad += 1
    open(target, "w", encoding="utf-8").write(source)
    shutil.rmtree(work, ignore_errors=True)
    print("control: %d mutations, %d not ok" % (len(MUTATIONS), bad))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
