#!/usr/bin/env python3
"""safedeps: native pre judgment and its command-facts query.

For each command of a fixed set this times, from one Python process:

  pre       the whole native PreToolUse hook, through the registered
            entry shim (`bash scripts/safedeps-hook-entry.sh pre`), from the
            payload on stdin to the answer on stdout
  facts     the same binary's `facts` query on the same payload: the lexer in every
            reading the command needs, the recognizers, the pipe checks, the
            statements' kinds and the spec extractor. This excludes the
            pre hook's state, target, ledger and rewrite work.
  start     process starts, for scale: `safedeps-core version`, `bash -c :`
            and `awk 'BEGIN{}'`

Each command runs in a fresh sandbox (HOME, SAFEDEPS_HOME, a project with a
package.json). The restricted system PATH must hold no npm (checked before
measurement), so an npm install's directory reads `?`. These timings exclude
npm's answers. The pre/facts ratio compares different operations in the same
native implementation; it is not a Bash-to-Rust speedup. A failed process or
malformed pre answer aborts the measurement instead of becoming a timing.
`uptime` is printed at the start and the end.

Usage: core-cost.py --core <safedeps-core> [--reps N] [--bash PATH] [--json FILE]
"""
import argparse
import hashlib
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
    if r.returncode:
        sys.exit("core-cost: %r exited %s: %s" % (argv, r.returncode, r.stderr.decode(errors="replace")))
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
    if a.reps < 1:
        ap.error("--reps must be positive")
    core = os.path.abspath(a.core)
    path = ":".join(d for d in ("/usr/bin", "/bin", "/usr/sbin", "/sbin") if os.path.isdir(d))
    if shutil.which("npm", path=path):
        sys.exit("core-cost: the restricted system PATH contains npm; no npm-free timing claimed")
    machine = subprocess.check_output([a.bash, "-c", 'printf "%s" "${BASH_VERSINFO[5]}"'], text=True)
    cpu = {"arm64": "arm64", "aarch64": "arm64", "x86_64": "x64", "amd64": "x64"}.get(machine.split("-")[0])
    system = "darwin" if "-darwin" in machine else "linux" if "-linux" in machine else None
    if not cpu or not system:
        sys.exit("core-cost: unsupported entry platform: " + machine)
    entry_core = os.path.join(ROOT, "bin", "native", system + "-" + cpu, "safedeps-core")
    digest = lambda file: hashlib.sha256(open(file, "rb").read()).hexdigest()
    if digest(core) != digest(entry_core):
        sys.exit("core-cost: --core differs from the binary the registered entry uses")
    subprocess.run([core, "stamp", "--check"], check=True)
    up0 = subprocess.run(["uptime"], capture_output=True, text=True).stdout.strip()
    print("start: %s" % up0)
    bash_ver = subprocess.run([a.bash, "--version"], capture_output=True, text=True).stdout.splitlines()[0]
    print("bash: %s (%s)" % (a.bash, bash_ver))
    out = {"uptime_start": up0, "bash": bash_ver, "binary_sha256": digest(core), "rows": []}

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
    shutil.rmtree(env0["HOME"])

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
            try:
                response = json.loads(gr.stdout) if gr.stdout else {}
                if not isinstance(response, dict):
                    raise ValueError("pre answer is not an object")
                hs = response.get("hookSpecificOutput", {})
                if not isinstance(hs, dict):
                    raise ValueError("hookSpecificOutput is not an object")
            except ValueError as error:
                sys.exit("core-cost: malformed pre answer on %s: %s" % (name, error))
            if i > 0:
                gt.append(g)
                ct.append(c)
            else:
                answer = hs.get("permissionDecision", "allow")
                if "UNDECIDED" in hs.get("permissionDecisionReason", ""):
                    answer = "deny (UNDECIDED)"
            shutil.rmtree(box, ignore_errors=True)
        gs, cs = stats(gt), stats(ct)
        print("%-17s %6d B  pre median %8.1f ms p90 %8.1f | facts median %6.1f ms p90 %6.1f | pre/facts %5.0fx  (pre said %s)" % (
            name, len(cmd.encode()), gs["median"], gs["p90"], cs["median"], cs["p90"], gs["median"] / max(cs["median"], 0.01), answer))
        out["rows"].append({"name": name, "bytes": len(cmd.encode()), "pre": gs, "facts": cs, "answer": answer})
    up1 = subprocess.run(["uptime"], capture_output=True, text=True).stdout.strip()
    print("end: %s" % up1)
    out["uptime_end"] = up1
    if a.json:
        json.dump(out, open(a.json, "w"), indent=1)


if __name__ == "__main__":
    main()
