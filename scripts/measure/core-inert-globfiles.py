#!/usr/bin/env python3
"""safedeps: the commands of a saved witness bundle
(scripts/measure/core-inert-witness.py), run again where the shell's filename
generation has files to match.

For each record, the command as written and each side's saved command (the
rewrite it sent, or the command as written where it sent none) run under
bash, zsh, dash and the agent's zsh wrapper, with their default options, with
stand-ins for npm and the other tools, in a fresh directory that holds the
files of one set (`--set zz`, `--set --cache`, `--set zz,--cache`). Each run
is kept whole, as core-inert-differential.py observes one, and each npm call
with what the guard's own reading of npm's arguments
(the native manager query, the last value
ignore-scripts takes) makes of it. Nothing is judged again: the guards are
not run, so the rewrites are the ones the bundle saved. No package manager
runs.

Usage:
  core-inert-globfiles.py --witness FILE.jsonl --set NAMES [--set NAMES ...] --out FILE.jsonl
"""
import argparse
import importlib.util
import json
import os
import shutil
import subprocess
import tempfile

MEASURE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(MEASURE))




def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--core", required=True)
    ap.add_argument("--witness", required=True)
    ap.add_argument("--set", action="append", default=[])
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    spec = importlib.util.spec_from_file_location("core_inert_differential", os.path.join(MEASURE, "core-inert-differential.py"))
    d = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(d)
    work = tempfile.mkdtemp(prefix="safedeps-core-globfiles.")
    shells = d.Shells(work)

    def reading(argv):
        query={"op":"npm-read","words":argv}
        r = subprocess.run([os.path.abspath(a.core), "manager"], input=json.dumps(query).encode(), capture_output=True, timeout=30, check=True)
        answer=json.loads(r.stdout)
        if not answer['reads']:return 'unread'
        switches=dict(answer['switches'])
        return str(switches['ignore-scripts']).lower() if 'ignore-scripts' in switches else 'unset'


    up0 = subprocess.run(["uptime"], capture_output=True, text=True).stdout.strip()
    out = open(a.out, "w", encoding="utf-8")
    for line in open(a.witness, encoding="utf-8"):
        rec = json.loads(line)
        cmd = rec["cmd"]
        runs = [("written", cmd)]
        denied = {}
        for name, side in rec["sides"].items():
            # A side that denies runs nothing: it is listed, never run as the
            # command written.
            if str(side.get("decision", "")).startswith("deny"):
                denied[name] = side.get("decision")
                continue
            runs.append((name, side.get("rewrite") or cmd))
        for fs in a.set:
            files = [f for f in fs.split(",") if f]
            row = {"cmd": cmd, "files": files, "runs": {}, "denied": denied}
            for name, text in runs:
                box = tempfile.mkdtemp(prefix="g.", dir=work)
                obs = shells.observe(text, box, files)
                for o in obs.values():
                    o["readings"] = [reading(c) for c in o["npm"]] if isinstance(o.get("npm"), list) else d.UNKNOWN
                row["runs"][name] = {"command": text, "shells": obs}
                shutil.rmtree(box, ignore_errors=True)
            out.write(json.dumps(row, ensure_ascii=False) + "\n")
    out.close()
    up1 = subprocess.run(["uptime"], capture_output=True, text=True).stdout.strip()
    print("load start: %s\nload end:   %s" % (up0, up1))
    shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
