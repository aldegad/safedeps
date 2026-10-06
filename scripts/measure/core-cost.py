#!/usr/bin/env python3
"""safedeps: what a judgment costs, the bash guard beside the Rust core.

For each command of a fixed set this times, from one Python process:

  guard     the whole PreToolUse hook as the engines run it, through the
            entry shim (`bash scripts/safedeps-hook-entry.sh pre`), from the
            payload on stdin to the answer on stdout
  core      `safedeps-core facts` on the same payload: the lexer in every
            reading the command needs, the recognizers, the pipe checks, the
            statements' kinds and the spec extractor -- the part stage 1
            ported, which is not the whole hook
  start     process starts, for scale: `safedeps-core version`, `bash -c :`
            and `awk 'BEGIN{}'`

Each command runs in a fresh sandbox (HOME, SAFEDEPS_HOME, a project with a
package.json). The PATH holds no npm, so the guard's landing asks npm nothing
(an npm install's directory reads `?`); the times of npm's own answers are
npm's, a Rust guard would ask them too, and they are left out of both sides.
`uptime` is printed at the start and the end.

Usage: core-cost.py --core <safedeps-core> [--reps N] [--bash PATH] [--json FILE]
"""
import argparse
import json
import os
import shutil
import statistics
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SHIM = os.path.join(ROOT, "scripts", "safedeps-hook-entry.sh")


def commands():
    lorem = "lorem ipsum dolor sit amet, consectetur adipiscing elit. " * 290
    pins = " ".join("pkg%d==1.0.%d" % (i, i) for i in range(400))
    return [
        ("plain", "ls -la"),
        ("plain-compound", "git status --short && git log --oneline -5 | head -3"),
        ("npm-install", "npm install left-pad@1.3.0"),
        ("pip-install", "pip install requests==2.0.0"),
        ("compound-install", "cd sub && npm ci && npm run build"),
        ("payload-install", "bash -c 'pip install requests==2.0.0'"),
        ("big-plain-16k", "cat > notes.txt <<'EOF'\n" + lorem + "\nEOF"),
        ("big-install-5k", "pip install " + pins),
    ]


def sandbox():
    box = tempfile.mkdtemp(prefix="safedeps-core-cost.")
    proj = os.path.join(box, "project")
    os.makedirs(os.path.join(proj, "sub"))
    for d in (proj, os.path.join(proj, "sub")):
        open(os.path.join(d, "package.json"), "w").write('{"dependencies":{}}\n')
    os.makedirs(os.path.join(box, "home"))
    return box, proj


def timed(argv, data, env, cwd):
    t = time.perf_counter()
    r = subprocess.run(argv, input=data, capture_output=True, env=env, cwd=cwd)
    return (time.perf_counter() - t) * 1000.0, r


def stats(xs):
    xs = sorted(xs)
    p90 = xs[min(len(xs) - 1, int(round(0.9 * (len(xs) - 1))))]
    return {"median": statistics.median(xs), "p90": p90, "min": xs[0]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--core", required=True)
    ap.add_argument("--reps", type=int, default=10)
    ap.add_argument("--bash", default="bash")
    ap.add_argument("--json", default="")
    a = ap.parse_args()
    core = os.path.abspath(a.core)
    path = ":".join(d for d in ("/usr/bin", "/bin", "/usr/sbin", "/sbin") if os.path.isdir(d))
    up0 = subprocess.run(["uptime"], capture_output=True, text=True).stdout.strip()
    print("start: %s" % up0)
    bash_ver = subprocess.run([a.bash, "--version"], capture_output=True, text=True).stdout.splitlines()[0]
    print("bash: %s (%s)" % (a.bash, bash_ver))
    out = {"uptime_start": up0, "bash": bash_ver, "rows": []}

    starts = {"core version": [], "bash -c :": [], "awk BEGIN": []}
    env0 = {"PATH": path, "HOME": tempfile.mkdtemp()}
    for _ in range(a.reps * 3):
        starts["core version"].append(timed([core, "version"], b"", env0, None)[0])
        starts["bash -c :"].append(timed([a.bash, "-c", ":"], b"", env0, None)[0])
        starts["awk BEGIN"].append(timed(["awk", "BEGIN{}"], b"", env0, None)[0])
    for k, v in starts.items():
        s = stats(v)
        print("start %-14s median %7.1f ms  p90 %7.1f  min %7.1f" % (k, s["median"], s["p90"], s["min"]))
        out["rows"].append({"name": "start " + k, **s})

    for name, cmd in commands():
        gt, ct = [], []
        answer = ""
        for i in range(a.reps + 1):
            box, proj = sandbox()
            env = {"PATH": path, "HOME": os.path.join(box, "home"), "SAFEDEPS_HOME": os.path.join(box, "sd"),
                   "TMPDIR": box, "LANG": "en_US.UTF-8"}
            data = json.dumps({"tool_name": "Bash", "tool_input": {"command": cmd}, "cwd": proj}).encode()
            g, gr = timed([a.bash, SHIM, "pre"], data, env, proj)
            c, cr = timed([core, "facts"], data, env, proj)
            if cr.returncode != 0:
                sys.exit("core-cost: safedeps-core facts failed on %s" % name)
            if i > 0:
                gt.append(g)
                ct.append(c)
            else:
                try:
                    hs = json.loads(gr.stdout or b"{}").get("hookSpecificOutput", {})
                    answer = hs.get("permissionDecision", "allow")
                    if "UNDECIDED" in hs.get("permissionDecisionReason", ""):
                        answer = "deny (UNDECIDED)"
                except ValueError:
                    answer = "?"
            shutil.rmtree(box, ignore_errors=True)
        gs, cs = stats(gt), stats(ct)
        print("%-17s %6d B  guard median %8.1f ms p90 %8.1f | core median %6.1f ms p90 %6.1f | guard/core %5.0fx  (guard said %s)" % (
            name, len(cmd.encode()), gs["median"], gs["p90"], cs["median"], cs["p90"], gs["median"] / max(cs["median"], 0.01), answer))
        out["rows"].append({"name": name, "bytes": len(cmd.encode()), "guard": gs, "core": cs, "answer": answer})
    up1 = subprocess.run(["uptime"], capture_output=True, text=True).stdout.strip()
    print("end: %s" % up1)
    out["uptime_end"] = up1
    if a.json:
        json.dump(out, open(a.json, "w"), indent=1)


if __name__ == "__main__":
    main()
