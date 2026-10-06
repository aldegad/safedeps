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

Usage: core-inert-selftest-control.py [--path-prefix DIRS]
"""
import argparse
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
     '            if fx and not fy and not res["sides"][side].get("record"):\n                out["true_to_false"] += 1',
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
    ("a row whose own records do not read is classified all the same",
     '        if res.get("_invalid_row"):\n            counts["invalid"] += 1',
     '        if False:\n            counts["invalid"] += 1',
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
     '        slot = raw if isinstance(raw, dict) else {"_raw_type": type(raw).__name__}\n',
     '        if not isinstance(raw, dict):\n            continue\n        slot = raw\n',
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
    a = ap.parse_args()
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
