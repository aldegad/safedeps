#!/usr/bin/env python3
"""safedeps: one evidence record per form, for a difference the inert
comparison cannot name (scripts/measure/core-inert-differential.py).

For each form (JSONL, `cmd`), every tree named with --tree judges it with its
own whole pre-guard, as a PreToolUse payload: the decision, the command it
sends, its exit status, and the advisory.log lines it wrote. The Rust core
(`safedeps-core inert`) gives its value per reading and the command its
readings agree on. Then the command as written, and the command each side
would run, run under bash, zsh, dash and the agent's zsh wrapper with
stand-ins for npm and the other tools: each run is kept whole, as
core-inert-differential.py observes one (exit status, stdout, stderr, every
stand-in call with its argv, the files left). The flags are split by where
they come from: the ones 7d66f8c placed (the floor, from its recorded rewrite
in scripts/test/inert-release-rewrites.json and from its own run), and the
ones each later side added. Each npm call is set beside the call the command
as written makes: where it is that call with `--ignore-scripts` words
inserted, the inserted places are listed, and where it is not, both argvs are
listed whole. No argument is taken out to make two calls compare. --saved
adds what a saved comparison report held for the same command.

Commands are data: they reach the guards as payloads and the shells as an
argument; no package manager runs.

Usage:
  core-inert-witness.py --core <safedeps-core> --tree NAME=DIR ... --forms FILE.jsonl
      --out FILE.jsonl [--saved REPORT.json ...]
"""
import argparse
import importlib.util
import json
import os
import re
import shutil
import subprocess
import tempfile

MEASURE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(MEASURE))
FLAG = b" --ignore-scripts"


def load_diff():
    spec = importlib.util.spec_from_file_location("core_inert_differential", os.path.join(MEASURE, "core-inert-differential.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def compare_calls(d, orig, now):
    """Each npm call of a run beside the same call of the command as written
    (two observations of one shell): the indices of the `--ignore-scripts`
    words inserted, or both argvs where the call is no such edit."""
    if not d.calls_known(orig) or not d.calls_known(now):
        return [{"note": "a run's npm calls are not known"}]
    out = []
    for i, call in enumerate(now["npm"]):
        if i >= len(orig["npm"]):
            out.append({"call": i, "note": "no such call in the command as written", "argv": call})
            continue
        ins = d.flag_edit(orig["npm"][i], call)
        if ins is None:
            out.append({"call": i, "note": "not the written call with flags inserted", "written": orig["npm"][i], "now": call})
        elif ins:
            out.append({"call": i, "inserted": ins})
    if len(orig["npm"]) > len(now["npm"]):
        out.append({"note": "the command as written makes %d npm calls, this one %d" % (len(orig["npm"]), len(now["npm"]))})
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--core", required=True)
    ap.add_argument("--tree", action="append", default=[])
    ap.add_argument("--forms", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--saved", action="append", default=[])
    ap.add_argument("--path-prefix", default="", help="directories put before the system PATH of the guards, where npm is")
    ap.add_argument("--approve", action="append", default=[],
                    help="eco:name:version approved in each tree's sandbox ledger first, as the batteries do (lib/ledger/ledger.sh approve)")
    a = ap.parse_args()
    d = load_diff()
    work = tempfile.mkdtemp(prefix="safedeps-core-witness.")
    shells = d.Shells(work)
    trees = [(n, os.path.abspath(os.path.expanduser(t))) for n, t in (x.split("=", 1) for x in a.tree)]
    release = {}
    for r in json.load(open(os.path.join(ROOT, "scripts", "test", "inert-release-rewrites.json"), encoding="utf-8")):
        release[r["command"]] = r["release"]
    saved = {}
    for path in a.saved:
        for r in json.load(open(os.path.expanduser(path), encoding="utf-8"))["rows"]:
            saved.setdefault(r["command"], []).append({"report": path, "status": r.get("status"), "tokens": r.get("tokens"),
                                                       "bash": r.get("ref"), "core": r.get("core"), "sides": r.get("sides")})
    path = ":".join(x for x in ("/usr/bin", "/bin", "/usr/sbin", "/sbin") if os.path.isdir(x))
    if a.path_prefix:
        path = ":".join(os.path.expanduser(x) for x in a.path_prefix.split(":") if x) + ":" + path
    up0 = subprocess.run(["uptime"], capture_output=True, text=True).stdout.strip()
    out = open(a.out, "w", encoding="utf-8")
    for line in open(a.forms, encoding="utf-8"):
        if not line.strip():
            continue
        cmd = json.loads(line)["cmd"]
        cb = cmd.encode("utf-8", "surrogateescape")
        rec = {"cmd": cmd, "sides": {}}
        box = tempfile.mkdtemp(prefix="w.", dir=work)
        written = shells.observe(cmd, box)
        rec["written"] = {"shells": written}
        if cmd in release:
            r = release[cmd]
            rec["release_recorded"] = {"rewrite": r, "flags": d.flag_positions(cb, r.encode("utf-8", "surrogateescape")) if r else []}
        for name, tree in trees:
            tbox = tempfile.mkdtemp(prefix="t.", dir=box)
            proj = os.path.join(tbox, "project")
            os.makedirs(proj)
            open(os.path.join(proj, "package.json"), "w").write('{"name":"p","version":"1.0.0","dependencies":{}}\n')
            env = {"PATH": path, "HOME": os.path.join(tbox, "home"), "SAFEDEPS_HOME": os.path.join(tbox, "sd"), "LANG": "en_US.UTF-8", "TMPDIR": tbox}
            os.makedirs(env["HOME"])
            for ap_ in a.approve:
                eco, name_, ver = ap_.split(":")
                subprocess.run(["bash", os.path.join(tree, "lib", "ledger", "ledger.sh"), "approve", eco, name_, ver, ver, "witness"],
                               env=env, capture_output=True, timeout=60)
            guard = os.path.join(tree, "scripts", "safedeps-pre-guard.sh")
            if not os.path.isfile(guard):
                raise SystemExit("core-inert-witness: no pre-guard at %s" % guard)
            g = subprocess.run(["nice", "-n", "10", "bash", guard],
                               input=d.payload(cmd, proj, "toolu_witness"), capture_output=True, env=env, cwd=proj, timeout=180)
            try:
                hso = json.loads(g.stdout or b"{}").get("hookSpecificOutput", {})
            except ValueError:
                hso = {}
            adv = os.path.join(env["SAFEDEPS_HOME"], "advisory.log")
            lines = [l for l in open(adv, encoding="utf-8", errors="replace").read().split("\n") if "pre-guard" in l] if os.path.exists(adv) else []
            side = {"tree": tree, "rc": g.returncode, "decision": hso.get("permissionDecision", "allow"),
                    "reason": (hso.get("permissionDecisionReason") or "")[:300], "advisory": lines,
                    "inert_record": any(d.INERT_RECORD_RE.search(l) for l in lines)}
            run = hso.get("updatedInput", {}).get("command")
            side["rewrite"] = run
            side["flags"] = d.flag_positions(cb, run.encode("utf-8", "surrogateescape")) if run else []
            if side["decision"] != "deny":
                obs = shells.observe(run or cmd, box)
                side["shells"] = obs
                side["argv_changes"] = {s: compare_calls(d, written.get(s), v) for s, v in obs.items()}
            rec["sides"][name] = side
        c = subprocess.run(["nice", "-n", "10", a.core, "inert"], input=d.payload(cmd, "/tmp"), capture_output=True, timeout=120)
        recs = d.parse_records(c.stdout) if c.returncode == 0 else {}
        side = {"rc": c.returncode, "records": {k: v.decode("latin-1") for k, v in recs.items()}}
        o = d.consensus(recs, cb) if recs else None
        if o == "deny":
            side["decision"] = "deny (the readings disagree)"
        elif o is not None:
            side["value"] = [o[0], sorted(o[1])]
            side["rewrite"] = o[2].decode("utf-8", "surrogateescape") if o[0] == "rewrite" else None
            side["flags"] = o[3]
            side["inert_record"] = bool(d.records_of(o))
            obs = shells.observe(o[2].decode("utf-8", "surrogateescape"), box)
            side["shells"] = obs
            side["argv_changes"] = {s: compare_calls(d, written.get(s), v) for s, v in obs.items()}
        rec["sides"]["core"] = side
        floor = set(rec.get("release_recorded", {}).get("flags") or [])
        if "7d66f8c" in rec["sides"]:
            floor |= set(rec["sides"]["7d66f8c"].get("flags") or [])
        for name, side in rec["sides"].items():
            f = side.get("flags")
            if f is None:
                continue
            side["flags_floor"] = sorted(set(f) & floor)
            side["flags_added"] = sorted(set(f) - floor)
            side["floor_missing"] = sorted(floor - set(f))
        if cmd in saved:
            rec["saved"] = saved[cmd]
        out.write(json.dumps(rec, ensure_ascii=False) + "\n")
        shutil.rmtree(box, ignore_errors=True)
    out.close()
    up1 = subprocess.run(["uptime"], capture_output=True, text=True).stdout.strip()
    print("load start: %s\nload end:   %s" % (up0, up1))
    shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
