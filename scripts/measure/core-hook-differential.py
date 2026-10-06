#!/usr/bin/env python3
"""safedeps: two implementations of the hooks, run on the same disk.

The facts comparison (core-facts-differential.py) holds what the Rust core
reads of a command to what the bash guard reads. This one holds everything a
hook does: what it prints, how it ends, and every file it leaves behind.

A case is a seed (files in a sandbox, a ledger, a stand-in npm) and a list of
steps. A step is a hook call (pre or post, with its payload) or an effect: the
file changes the command would have made, written by this harness, because a
harness judges commands and never runs them. The case runs twice in one
directory, once per implementation, each time on the seed restored from one
copy. The two runs therefore see the same absolute paths, so no path is masked.

After every step this harness records the exit status, stdout and stderr of a
hook, and the whole sandbox: SAFEDEPS_HOME, the project, HOME, TMPDIR and the
stand-in's call records, each entry's name, kind, mode and bytes. The two
records must be equal after the masks below, and nothing else is set aside.

The masks are a closed list (MASKS). Each has a name, each is counted, and the
summary prints the counts. A mask sets a value aside only where the value came
from this side's run, and that origin is checked, never read off the value's
shape. A value the seed holds (any name or byte of the sandbox as restored,
and the case's own steps and environment) is compared as it is written, so a
candidate that states a seeded time, pid or id wrongly is red however much its
wrong value looks like the right one. A value of no proven origin is compared
as it is written too, and the summary counts them:

  iso-utc             a UTC time `2026-10-06T13:14:53Z` that the seed does not
                      hold and that falls inside this side's run window (from
                      just before the seed was restored to just after the
                      last step, in whole seconds)
  epoch               the same, for epoch seconds in a JSON field named in
                      EPOCH_KEYS and the seconds that start an npm-withheld
                      record's name
  snapshot-id         the id of a snapshot that appeared on disk during the
                      case, as `<snap#N>`: N counts ids in the order they
                      appeared, so two snapshots are never read as one
  snapshot-id-run     an id of the same shape that never was on disk and the
                      seed does not hold, whose seconds fall in the run window
                      and whose pid is a hook this harness started (step K):
                      `<snap+:stepK>`
  pid                 a number in a pid position (after a snapshot id in a
                      journal id, a JSON `pid`, `pid N` in prose, an
                      npm-withheld record's name) that is the pid of the hook
                      this harness started for step K: `<pid:stepK>`
  mktemp              the six characters mktemp chose in a name the hooks
                      make, where the seed holds no such name
  inode               in a pending record's `inodes`, each number replaced by
                      the path that had that inode when the record was written
  clock               in a backstop entry's `clocks`, each time stat printed
  bash-diagnostic     a line bash itself wrote to stderr
                      (`<script>: line N: ...`), which no other implementation
                      can write: set aside, counted per case and listed
  stub-call-name      a stand-in npm's call record is named by its process id;
                      it is compared under a name made from its argv and cwd
  tree-root           the directory of the implementation's own tree, which a
                      hook prints when it names its `bin/safedeps`: `@TREE@`
  deadline-tmp        in a case of the `deadline` family, what is left in
                      TMPDIR is listed and not compared (the reference kills
                      its child at the deadline and the child leaves files)

Two families. A `verdict` case compares answers; one whose command is long
enough to engage the self budget runs with SAFEDEPS_BUDGET_DISABLED=1 on both
sides, because the reference is slow enough to lose such a case to its own
deadline. A case about the budget's own settings says `"budget": "on"` and
keeps the deadline. A `deadline` case gives npm a stand-in that answers late,
and both sides have to give the same undecided answer.

The environment of a hook is a closed list too: PATH (the system directories,
after the stand-in's directory when the case has one), HOME, SAFEDEPS_HOME,
TMPDIR, LANG (no LC_ALL and no LC_CTYPE), every proxy variable pointed at a
closed local port, and what the case names. A case with a post step may not
leave the advisory providers at their defaults: it names `closed` or `fixture`,
so no run of this harness asks the real OSV.

The reference is this tree's bash hooks, started as the entry shim starts
them: the script, no argument. The candidate is one of

  --core <safedeps-core>   `<core> pre` and `<core> post`; `<core> stamp
                           --check` has to print `ok` first, or no case runs
  --cand-root <tree>       the bash hooks of another tree
  (neither)                the reference again: the masks are enough exactly
                           when this is green
  --control                the reference against copies of it with one line
                           changed (MUTATIONS); each copy has to be red, in
                           the channel the mutation names

--stages names which hooks the candidate answers (default pre,post). The other
hook is the reference's on both sides, so a `post` alone is compared on the
records the bash pre-guard wrote, and a `pre` alone is followed through the
bash post hook.

Each case names what the reference has to do in it (`expect`). A reference
that does not is red whatever the candidate does: a corpus that stopped
reaching a path would otherwise compare two silences.

Usage:
  core-hook-differential.py [--core BIN | --cand-root DIR | --control]
      [--stages pre,post] [--cases FILE]... [--only ID,...] [--tags T,...]
      [--jobs N] [--report FILE] [--dump DIR] [--list] [--fixture-provider]
      [--timeout SECONDS]

Exit status: 0 green, 1 red, 2 the harness could not run.
"""
import argparse
import calendar
import difflib
import fnmatch
import hashlib
import json
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MEASURE = os.path.join(ROOT, "scripts", "measure")
DEFAULT_CASES = os.path.join(MEASURE, "core-hook-cases.json")
BOX_DIRS = ("home", "state", "project", "tmp")
CLOSED_PORT = "http://127.0.0.1:9"


def engage_bytes():
    """The size at which the pre-guard's self budget engages by default, read
    from the reference's own assignment (SAFEDEPS_BUDGET_ENGAGE_DEFAULT_BYTES)
    rather than copied here, where it would drift from the hook it describes."""
    path = os.path.join(ROOT, "scripts", "safedeps-pre-guard.sh")
    try:
        text = open(path, encoding="utf-8", errors="surrogateescape").read()
    except OSError as e:
        die("cannot read %s: %s" % (path, e.strerror))
    found = re.findall(r"^SAFEDEPS_BUDGET_ENGAGE_DEFAULT_BYTES=([0-9]+)$", text, re.M)
    if len(found) != 1:
        die("%s assigns SAFEDEPS_BUDGET_ENGAGE_DEFAULT_BYTES %d times, not once" % (path, len(found)))
    return int(found[0])


MASKS = ("iso-utc", "epoch", "snapshot-id", "snapshot-id-run", "pid", "mktemp", "inode", "clock",
         "bash-diagnostic", "stub-call-name", "tree-root", "deadline-tmp")
# Values in a masked position that no mask took: the seed holds them, or their
# origin in this run is not proven. They are compared as written.
KEPT = ("iso-utc", "epoch", "snapshot-id", "pid", "mktemp")

# JSON fields that hold epoch seconds. A field that is not here is compared.
EPOCH_KEYS = ("timestamp", "at", "verified_at", "confirmed_at")

# What a stand-in npm leaves out of the environment it records: names the
# shell that starts it sets by itself, which say nothing of what the hook
# chose to pass.
STUB_ENV_NOISE = ("_", "SHLVL")


def die(msg):
    sys.stderr.write("core-hook-differential: %s\n" % msg)
    sys.exit(2)


ENGAGE_BYTES = engage_bytes()


# --- the corpus ----------------------------------------------------------------

def load_cases(paths):
    cases = []
    seen = {}
    for p in paths:
        try:
            doc = json.load(open(p, encoding="utf-8"))
        except (OSError, ValueError) as e:
            die("cannot read cases from %s: %s" % (p, e))
        defaults = doc.get("defaults", {})
        for c in doc.get("cases", []):
            if not c.get("bare"):
                # A case starts from the file's defaults; what it names itself wins.
                c["files"] = dict(defaults.get("files", {}), **c.get("files", {}))
            if isinstance(c.get("npm"), str):
                c["npm"] = doc.get("npm", {}).get(c["npm"]) or die("%s: no stand-in npm named %s" % (p, c["npm"]))
            cid = c.get("id")
            if not cid or not re.match(r"^[a-z0-9][a-z0-9-]*$", cid):
                die("%s: a case needs an id of lower-case letters, digits and dashes (%r)" % (p, cid))
            if cid in seen:
                die("case id %s is in both %s and %s" % (cid, seen[cid], p))
            seen[cid] = p
            check_case(c)
            cases.append(c)
    return cases


def check_case(c):
    cid = c["id"]
    steps = c.get("steps")
    if not steps:
        die("case %s has no steps" % cid)
    has_post = False
    longest = 0
    for k, s in enumerate(steps):
        if "hook" in s:
            if s["hook"] not in ("pre", "post"):
                die("case %s step %d: hook is pre or post" % (cid, k))
            if sum(x in s for x in ("command", "payload", "payload_raw")) != 1 and "command_from_step" not in s:
                die("case %s step %d: a hook step has command, payload or payload_raw, one of them" % (cid, k))
            if s.get("engine", "claude") not in ("claude", "codex"):
                die("case %s step %d: engine is claude or codex" % (cid, k))
            has_post = has_post or s["hook"] == "post"
            cmd = s.get("command", ((s.get("payload") or {}).get("tool_input") or {}).get("command"))
            if isinstance(cmd, str):
                longest = max(longest, len(cmd.encode("utf-8")))
            src = s.get("command_from_step")
            if src is not None and not (isinstance(src, int) and 0 <= src < k and "hook" in steps[src]):
                die("case %s step %d: command_from_step names an earlier hook step" % (cid, k))
        elif "effect" not in s:
            die("case %s step %d is neither a hook nor an effect" % (cid, k))
    family = c.get("family", "verdict")
    if family not in ("verdict", "deadline"):
        die("case %s: family is verdict or deadline" % cid)
    providers = c.get("providers", "default")
    if providers not in ("default", "closed", "fixture"):
        die("case %s: providers is default, closed or fixture" % cid)
    if has_post and providers == "default":
        die("case %s has a post step and leaves the advisory providers at their defaults; name closed or fixture" % cid)
    if c.get("seed_cli") and providers == "default":
        die("case %s runs the safedeps CLI in its seed and leaves the providers at their defaults" % cid)
    c["_long"] = longest >= ENGAGE_BYTES


def inside(box, rel):
    if not isinstance(rel, str) or rel.startswith("/") or ".." in rel.split("/") or not rel:
        die("a path in a case is relative to the sandbox and stays inside it: %r" % (rel,))
    return os.path.join(box, rel)


def fill(v, box):
    if isinstance(v, str):
        return (v.replace("@BOX@", box).replace("@PROJECT@", box + "/project").replace("@HOME@", box + "/home")
                 .replace("@STATE@", box + "/state").replace("@TMP@", box + "/tmp"))
    if isinstance(v, list):
        return [fill(x, box) for x in v]
    if isinstance(v, dict):
        return {k: fill(x, box) for k, x in v.items()}
    return v


def spec_bytes(spec, box):
    if isinstance(spec, str):
        return fill(spec, box).encode("utf-8")
    if "json" in spec:
        return (json.dumps(fill(spec["json"], box), indent=2) + "\n").encode("utf-8")
    if "lines" in spec:
        return "".join(fill(l, box) + "\n" for l in spec["lines"]).encode("utf-8")
    if "base64" in spec:
        import base64
        return base64.b64decode(spec["base64"])
    return fill(spec.get("content", ""), box).encode("utf-8")


def put(box, rel, spec):
    path = inside(box, rel)
    if isinstance(spec, dict) and "symlink" in spec:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        if os.path.lexists(path):
            os.remove(path)
        os.symlink(fill(spec["symlink"], box), path)
        return
    if isinstance(spec, dict) and spec.get("dir"):
        os.makedirs(path, exist_ok=True)
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if os.path.islink(path):
        os.remove(path)
    with open(path, "wb") as f:
        f.write(spec_bytes(spec, box))


def late(box, rel, spec, now):
    """What a copy of the seed cannot carry: a mode that would stop the copy,
    an age counted from the run, and the inode a restored file got."""
    if not isinstance(spec, dict):
        return
    path = inside(box, rel)
    if "inode_of" in spec:
        text = open(path, "rb").read().decode("latin-1")

        def ino(m):
            p = inside(box, m.group(1))
            try:
                return str(os.lstat(p).st_ino)
            except OSError:
                return ""
        with open(path, "wb") as f:
            f.write(re.sub(r"@INODE\(([^)]*)\)@", ino, text).encode("latin-1"))
    if "age" in spec:
        t = now - float(spec["age"])
        os.utime(path, (t, t), follow_symlinks=False)
    if "mode" in spec and "symlink" not in spec:
        os.chmod(path, int(str(spec["mode"]), 8))


def apply_effect(box, ops):
    for op in ops:
        if "write" in op:
            put(box, op["write"], op)
            late(box, op["write"], op, time.time())
        elif "remove" in op:
            p = inside(box, op["remove"])
            if os.path.isdir(p) and not os.path.islink(p):
                rmtree(p)
            elif os.path.lexists(p):
                os.remove(p)
        elif "mkdir" in op:
            os.makedirs(inside(box, op["mkdir"]), exist_ok=True)
        elif "symlink" in op:
            put(box, op["symlink"], {"symlink": op["target"]})
        elif "touch" in op:
            p = inside(box, op["touch"])
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "ab"):
                pass
            os.utime(p, None)
        elif "rename" in op:
            os.rename(inside(box, op["rename"][0]), inside(box, op["rename"][1]))
        elif "chmod" in op:
            os.chmod(inside(box, op["chmod"][0]), int(str(op["chmod"][1]), 8))
        elif "sleep" in op:
            time.sleep(float(op["sleep"]))
        else:
            die("an effect does not know the operation %r" % (op,))


def rmtree(path):
    def onerror(func, p, _exc):
        try:
            os.chmod(os.path.dirname(p), 0o700)
            if not os.path.islink(p):
                os.chmod(p, 0o700)
            func(p)
        except OSError:
            pass
    if os.path.lexists(path):
        shutil.rmtree(path, onerror=onerror)


# --- the stand-in npm ------------------------------------------------------------

STUB_NPM = r'''#!%(python)s -I
# safedeps core-hook-differential: a stand-in npm. It records how it was
# called and prints the answer its case wrote for that call. It installs
# nothing and starts nothing.
import json, os, sys, time
here = os.path.dirname(os.path.abspath(__file__))
conf = json.load(open(os.path.join(here, "npm.answers.json")))
argv = sys.argv[1:]
record = {"argv": argv, "cwd": os.getcwd(),
          "env": {k: v for k, v in os.environ.items() if k not in conf["noise"]}}
os.makedirs(conf["calls"], exist_ok=True)
n = 0
while True:
    name = os.path.join(conf["calls"], "call.%%d.%%d" %% (os.getpid(), n))
    try:
        fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        break
    except FileExistsError:
        n += 1
with os.fdopen(fd, "w") as f:
    json.dump(record, f, sort_keys=True, indent=1)
    f.write("\n")
answer = conf["default"]
for a in conf["answers"]:
    words = a.get("argv", [])
    if argv[:len(words)] == words:
        answer = a
        break
if answer.get("sleep"):
    time.sleep(answer["sleep"])
sys.stdout.write(answer.get("stdout", ""))
sys.stderr.write(answer.get("stderr", ""))
sys.stdout.flush()
sys.exit(answer.get("exit", 0))
'''


def write_stub(box, npm):
    d = os.path.join(box, "stub")
    os.makedirs(d, exist_ok=True)
    conf = {"calls": os.path.join(box, "calls", "npm"), "noise": list(STUB_ENV_NOISE),
            "answers": fill(npm.get("answers", []), box),
            "default": fill(npm.get("default", {"exit": 1, "stderr": "stand-in npm: no answer for this call\n"}), box)}
    with open(os.path.join(d, "npm.answers.json"), "w", encoding="utf-8") as f:
        json.dump(conf, f, indent=1, sort_keys=True)
        f.write("\n")
    with open(os.path.join(d, "npm"), "w", encoding="utf-8") as f:
        f.write(STUB_NPM % {"python": sys.executable})
    os.chmod(os.path.join(d, "npm"), 0o755)


# --- running -----------------------------------------------------------------------

def system_path():
    dirs = [d for d in ("/usr/bin", "/bin", "/usr/sbin", "/sbin") if os.path.isdir(d)]
    for tool in ("bash", "jq", "awk", "sed", "grep", "find", "curl", "mktemp", "date", "stat"):
        if any(os.access(os.path.join(d, tool), os.X_OK) for d in dirs):
            continue
        found = shutil.which(tool)
        if not found:
            die("%s is not on PATH; the hooks need it" % tool)
        dirs.append(os.path.dirname(os.path.realpath(found)))
    return dirs


def descendants(pid):
    try:
        out = subprocess.run(["ps", "-Ao", "pid=,ppid="], capture_output=True, timeout=20).stdout.decode("latin-1")
    except (OSError, subprocess.SubprocessError):
        return []
    kids = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[0].isdigit() and parts[1].isdigit():
            kids.setdefault(int(parts[1]), []).append(int(parts[0]))
    order = []
    todo = [pid]
    while todo:
        p = todo.pop()
        for k in kids.get(p, []):
            order.append(k)
            todo.append(k)
    return order


def stop_tree(pid):
    """One pid at a time, the deepest first. Never a process group."""
    for p in reversed(descendants(pid)) + [pid]:
        try:
            os.kill(p, signal.SIGKILL)
        except OSError:
            pass


def run_hook(argv, data, env, cwd, timeout):
    t0 = time.time()
    try:
        p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, cwd=cwd)
    except OSError as e:
        return {"status": "did not start: %s" % e.strerror, "out": b"", "err": b"", "secs": 0.0, "pid": 0}
    try:
        out, err = p.communicate(data, timeout=timeout)
        status = "exit %d" % p.returncode if p.returncode >= 0 else "signal %d" % -p.returncode
    except subprocess.TimeoutExpired:
        stop_tree(p.pid)
        out, err = p.communicate()
        status = "no answer in %d seconds" % timeout
    return {"status": status, "out": out, "err": err, "secs": time.time() - t0, "pid": p.pid}


def harvest(box):
    entries = {}
    inodes = {}
    for dirpath, dirnames, filenames in os.walk(box, followlinks=False):
        for name in dirnames + filenames:
            p = os.path.join(dirpath, name)
            rel = os.path.relpath(p, box)
            try:
                st = os.lstat(p)
            except OSError:
                continue
            inodes.setdefault(st.st_ino, []).append(rel)
            mode = "%04o" % stat.S_IMODE(st.st_mode)
            if stat.S_ISLNK(st.st_mode):
                entries[rel] = ("link", "", os.readlink(p).encode("utf-8", "surrogateescape"))
            elif stat.S_ISDIR(st.st_mode):
                entries[rel] = ("dir", mode, b"")
            elif stat.S_ISREG(st.st_mode):
                try:
                    with open(p, "rb") as f:
                        entries[rel] = ("file", mode, f.read())
                except OSError as e:
                    entries[rel] = ("file", mode, ("<unreadable: %s>" % e.strerror).encode())
            else:
                entries[rel] = ("other", mode, b"")
    return entries, {k: sorted(v) for k, v in inodes.items()}


class Impl:
    def __init__(self, name, pre, post, roots):
        self.name, self.pre, self.post = name, pre, post
        # The trees its hooks live in, the longest first.
        self.roots = sorted(set(roots), key=len, reverse=True)

    def argv(self, hook):
        return self.pre if hook == "pre" else self.post


def bash_impl(name, root):
    for f in ("scripts/safedeps-pre-guard.sh", "scripts/safedeps-post-verify.sh"):
        if not os.path.isfile(os.path.join(root, f)):
            die("%s has no %s" % (root, f))
    return Impl(name, ["bash", os.path.join(root, "scripts", "safedeps-pre-guard.sh")],
                ["bash", os.path.join(root, "scripts", "safedeps-post-verify.sh")], [root, os.path.realpath(root)])


def mixed(ref, cand, stages):
    return Impl(cand.name, cand.pre if "pre" in stages else ref.pre, cand.post if "post" in stages else ref.post,
                cand.roots + ref.roots)


class Ctx:
    def __init__(self, a, work):
        self.work = work
        self.timeout = a.timeout
        self.sysdirs = system_path()
        self.lang = "en_US.UTF-8" if sys.platform == "darwin" else "C.UTF-8"
        self.provider_env = None
        self.ref_root = ROOT


def case_env(ctx, case, box, step):
    dirs = list(ctx.sysdirs)
    if case.get("npm"):
        dirs.insert(0, os.path.join(box, "stub"))
    env = {"PATH": ":".join(dirs), "HOME": box + "/home", "SAFEDEPS_HOME": box + "/state", "TMPDIR": box + "/tmp",
           "LANG": case.get("lang", ctx.lang),
           "http_proxy": CLOSED_PORT, "https_proxy": CLOSED_PORT, "HTTP_PROXY": CLOSED_PORT, "HTTPS_PROXY": CLOSED_PORT,
           "ALL_PROXY": CLOSED_PORT, "all_proxy": CLOSED_PORT, "no_proxy": "127.0.0.1,localhost", "NO_PROXY": "127.0.0.1,localhost"}
    providers = case.get("providers", "default")
    if providers == "closed":
        env.update({"SAFEDEPS_OSV_API_URL": CLOSED_PORT + "/osv/v1/query", "SAFEDEPS_OSV_BATCH_API_URL": CLOSED_PORT + "/osv/v1/querybatch",
                    "SAFEDEPS_KEV_CATALOG_URL": CLOSED_PORT + "/kev.json", "SAFEDEPS_GHSA_API_URL": CLOSED_PORT + "/advisories",
                    "SAFEDEPS_PROVIDER_CACHE_TTL_SECONDS": "0"})
    elif providers == "fixture":
        env.update(ctx.provider_env)
    if case.get("family", "verdict") == "verdict" and case["_long"] and case.get("budget") != "on":
        env["SAFEDEPS_BUDGET_DISABLED"] = "1"
    env.update(fill(case.get("env", {}), box))
    if step is not None:
        env.update(fill(step.get("env", {}), box))
    return env


def build_seed(ctx, case, box, seed):
    """The seed, made once in the sandbox and kept as a copy both runs start from."""
    rmtree(box)
    rmtree(seed)
    for d in BOX_DIRS:
        if d != "state":
            os.makedirs(os.path.join(box, d))
    for rel, spec in case.get("files", {}).items():
        put(box, rel, spec)
    if case.get("npm"):
        write_stub(box, case["npm"])
    for argv in case.get("seed_cli", []):
        env = case_env(ctx, case, box, None)
        r = subprocess.run(["bash", os.path.join(ctx.ref_root, "bin", "safedeps")] + fill(argv, box), capture_output=True,
                           env=env, cwd=box + "/project", timeout=120)
        allowed = case.get("seed_cli_exit", [0])
        if r.returncode not in allowed:
            return "the seed command safedeps %s ended with %d: %s" % (" ".join(argv), r.returncode, r.stderr.decode("latin-1")[-400:])
    shutil.copytree(box, seed, symlinks=True)
    if case.get("seed_cli"):
        # The CLI wrote times of its own into the seed. A run that started in
        # the same second could write a value the seed holds, which is then
        # compared as written while the other side wrote the next second's.
        # So the runs start in a later second than the seed was made in.
        time.sleep(1.0 - time.time() % 1.0 + 0.01)
    return None


def restore(case, box, seed):
    rmtree(box)
    shutil.copytree(seed, box, symlinks=True)
    now = time.time()
    for rel, spec in case.get("files", {}).items():
        late(box, rel, spec, now)


def step_payload(s, command):
    """The hook input of a step written as a command: the fields both engines
    send, in the order they send them. Codex adds turn_id and model."""
    p = {"session_id": "core-hook-differential", "hook_event_name": "PreToolUse" if s["hook"] == "pre" else "PostToolUse",
         "tool_name": s.get("tool", "Bash"), "tool_input": {"command": command}}
    if "cwd" not in s or s["cwd"] is not None:
        p["cwd"] = s.get("cwd", "@PROJECT@")
    if s.get("id"):
        p["tool_use_id"] = s["id"]
    if s.get("engine") == "codex":
        p["turn_id"] = "turn-1"
        p["model"] = "codex-test"
    if s["hook"] == "post":
        if s.get("failed"):
            p["hook_event_name"] = "PostToolUseFailure"
            p["error"] = "Command failed with exit code 1"
        else:
            p["tool_response"] = {"stdout": "", "stderr": "", "interrupted": False}
    p.update(s.get("payload_extra", {}))
    return p


def updated_command(out):
    try:
        doc = json.loads(out.decode("utf-8"))
        cmd = doc["hookSpecificOutput"]["updatedInput"]["command"]
        return cmd if isinstance(cmd, str) else None
    except (ValueError, KeyError, TypeError):
        return None


def run_side(ctx, case, box, seed, impl):
    t_start = time.time()
    restore(case, box, seed)
    trees = [harvest(box)]
    steps = []
    sent = {}
    for k, s in enumerate(case["steps"]):
        rec = None
        if "hook" in s:
            if "payload_raw" in s:
                data = fill(s["payload_raw"], box).encode("utf-8", "surrogateescape")
            else:
                src = s.get("command_from_step")
                if "payload" in s:
                    payload = fill(s["payload"], box)
                else:
                    payload = fill(step_payload(s, s.get("command", "")), box)
                if src is not None:
                    # The command the tool ran is the one this side's pre-guard
                    # wrote, where it wrote one.
                    cmd = updated_command(steps[src]["out"])
                    if cmd is None:
                        cmd = sent[src]
                    payload.setdefault("tool_input", {})["command"] = cmd
                sent[k] = (payload.get("tool_input") or {}).get("command", "") if isinstance(payload, dict) else ""
                data = json.dumps(payload, ensure_ascii=False).encode("utf-8", "surrogateescape")
            cwd = s.get("proc_cwd")
            if cwd is None:
                cwd = s.get("cwd") or (s.get("payload") or {}).get("cwd") or "@PROJECT@"
            cwd = fill(cwd, box)
            if not os.path.isdir(cwd):
                cwd = box
            rec = run_hook(impl.argv(s["hook"]), data, case_env(ctx, case, box, s), cwd, ctx.timeout)
            rec["hook"] = s["hook"]
        else:
            apply_effect(box, s["effect"])
        steps.append(rec)
        trees.append(harvest(box))
    # The seconds this side's run could have written a time in.
    return {"steps": steps, "trees": trees, "window": (int(t_start), int(time.time()) + 1)}


# --- the masks -----------------------------------------------------------------------

SNAP_NAME = re.compile(r"^\.?([0-9]+_[0-9a-f]+-[0-9]+(?:-[0-9]+)*)_")
SNAP_SHAPE = re.compile(r"(?<![0-9A-Za-z])[0-9]{9,11}_[0-9a-f]{32}-[0-9]+(?![0-9])")
ISO = re.compile(r"(?<![0-9])20[0-9]{2}-[01][0-9]-[0-3][0-9]T[0-2][0-9]:[0-5][0-9]:[0-6][0-9]Z")
NUM = re.compile(r"(?<![0-9])[0-9]{9,11}(?![0-9])")
EPOCH_FIELD = re.compile(r'("(?:%s)"\s*:\s*"?)([0-9]{9,11})(?![0-9])' % "|".join(EPOCH_KEYS))
PID_AFTER_SNAP = re.compile(r"(<snap(?:#[0-9]+|\+:step[0-9]+)>-)([0-9]+)(?![0-9])")
PID_FIELD = re.compile(r'("pid"\s*:\s*"?)([0-9]+)(?![0-9])')
PID_PROSE = re.compile(r"(\bpid )([0-9]+)(?![0-9])")
WITHHELD_NAME = re.compile(r"(^|/)([0-9]{9,11})-([0-9]+)-([A-Za-z0-9]{6})\.json$")
MKTEMP = re.compile(r"(safedeps-[a-z-]+\.|\.compact\.)([A-Za-z0-9]{6})(?![A-Za-z0-9])")
HIDDEN_TMP_NAME = re.compile(r"(/\.[^/]*\.)([A-Za-z0-9]{6})(?=/|$)")
INODES_OBJ = re.compile(r'"inodes"\s*:\s*\{[^{}]*\}')
CLOCKS_OBJ = re.compile(r'"clocks"\s*:\s*\{[^{}]*\}')
CLOCK = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8}(?:\.[0-9]+)? [+-][0-9]{4}|[0-9]{9,11}\.[0-9]+")
BASH_DIAG = re.compile(r"^(?:\S*/)?[A-Za-z0-9_.-]+\.sh: line [0-9]+: .*$|^bash: .*$")


def iso_seconds(v):
    try:
        return calendar.timegm(time.strptime(v, "%Y-%m-%dT%H:%M:%SZ"))
    except ValueError:
        return None


class Canon:
    """One side's record of a case, in the form the two sides are compared in."""

    def __init__(self, case, box, run, roots):
        self.case, self.box, self.run, self.roots = case, box, run, roots
        self.counts = dict.fromkeys(MASKS, 0)
        self.kept = dict.fromkeys(KEPT, 0)
        self.diag = []
        self.noted = []
        trees = run["trees"]
        self.window = run["window"]
        # What the seed holds: every name and byte of the sandbox as restored,
        # and what the case itself hands the hooks. These values are compared
        # as they are written.
        seed = trees[0][0]
        self.seed_names = set(seed)
        parts = list(seed) + [data.decode("latin-1") for _kind, _mode, data in seed.values()]
        parts.append(json.dumps(fill(case.get("steps", []), box)))
        parts.append(json.dumps(fill(case.get("env", {}), box)))
        seed_text = "\n".join(parts)
        self.seed_isos = set(ISO.findall(seed_text))
        self.seed_nums = set(NUM.findall(seed_text))
        self.seed_snaps = set(SNAP_SHAPE.findall(seed_text))
        self.seed_tmps = set(m.group(0) for m in MKTEMP.finditer(seed_text))
        self.seed_tmps |= set(m.group(0) for rel in seed for m in HIDDEN_TMP_NAME.finditer(rel))
        self.snaps = {}
        seeded = self.snapshot_ids(seed)
        for b in range(1, len(trees)):
            for sid in sorted(self.snapshot_ids(trees[b][0]) - seeded - set(self.snaps)):
                self.snaps[sid] = len(self.snaps) + 1
        self.snap_re = None
        if self.snaps:
            self.snap_re = re.compile("(?:%s)(?![0-9])" % "|".join(re.escape(s) for s in sorted(self.snaps, key=len, reverse=True)))
        self.pids = {}
        for k, s in enumerate(run["steps"]):
            if s and s["pid"]:
                self.pids[str(s["pid"])] = k

    @staticmethod
    def snapshot_ids(entries):
        ids = set()
        for rel in entries:
            if rel.startswith("state/snapshots/") and rel.count("/") == 2:
                m = SNAP_NAME.match(rel.rsplit("/", 1)[1])
                if m:
                    ids.add(m.group(1))
        return ids

    def bump(self, name, n=1):
        self.counts[name] += n

    def keep(self, name, value):
        self.kept[name] += 1
        return value

    def in_window(self, seconds):
        return seconds is not None and self.window[0] <= seconds <= self.window[1]

    # Each of these returns the token for a value whose origin in this run is
    # proven, and the value itself otherwise.
    def pid_value(self, v):
        if v in self.pids:
            self.bump("pid")
            return "<pid:step%d>" % self.pids[v]
        return self.keep("pid", v)

    def epoch_value(self, v):
        if v not in self.seed_nums and self.in_window(int(v)):
            self.bump("epoch")
            return "<epoch>"
        return self.keep("epoch", v)

    def iso_value(self, v):
        if v not in self.seed_isos and self.in_window(iso_seconds(v)):
            self.bump("iso-utc")
            return "<iso>"
        return self.keep("iso-utc", v)

    def snap_value(self, v):
        if v not in self.seed_snaps:
            seconds, pid = v.split("_", 1)[0], v.rsplit("-", 1)[1]
            if self.in_window(int(seconds)) and pid in self.pids:
                self.bump("snapshot-id-run")
                return "<snap+:step%d>" % self.pids[pid]
        return self.keep("snapshot-id", v)

    def tmp_value(self, whole, head):
        if whole not in self.seed_tmps:
            self.bump("mktemp")
            return head + "<tmp>"
        return self.keep("mktemp", whole)

    def text(self, t):
        if self.snap_re:
            def snap(m):
                self.bump("snapshot-id")
                return "<snap#%d>" % self.snaps[m.group(0)]
            t = self.snap_re.sub(snap, t)
        t = SNAP_SHAPE.sub(lambda m: self.snap_value(m.group(0)), t)
        for rx in (PID_AFTER_SNAP, PID_FIELD, PID_PROSE):
            t = rx.sub(lambda m: m.group(1) + self.pid_value(m.group(2)), t)
        t = EPOCH_FIELD.sub(lambda m: m.group(1) + self.epoch_value(m.group(2)), t)
        t = ISO.sub(lambda m: self.iso_value(m.group(0)), t)
        t = MKTEMP.sub(lambda m: self.tmp_value(m.group(0), m.group(1)), t)
        t = t.replace(self.box, "@BOX@")
        for root in self.roots:
            if root in t:
                self.bump("tree-root", t.count(root))
                t = t.replace(root, "@TREE@")
        return t

    def name(self, rel):
        def withheld(m):
            return "%s%s-%s-%s.json" % (m.group(1), self.epoch_value(m.group(2)), self.pid_value(m.group(3)),
                                        self.tmp_value(m.group(0), ""))
        if rel.startswith("state/npm-withheld/") and rel not in self.seed_names:
            rel = WITHHELD_NAME.sub(withheld, rel)
        rel = self.text(rel)
        if rel.startswith("state/"):
            rel = HIDDEN_TMP_NAME.sub(lambda m: self.tmp_value(m.group(0), m.group(1)), rel)
        return rel

    def written_at(self, rel, b):
        """The first boundary since which this entry holds the bytes it holds at b."""
        trees = self.run["trees"]
        while b > 0 and trees[b - 1][0].get(rel) == trees[b][0][rel]:
            b -= 1
        return b

    def inode_text(self, rel, b, t):
        b0 = self.written_at(rel, b)
        spec = self.case.get("files", {}).get(rel)
        if b0 == 0 and not (isinstance(spec, dict) and "inode_of" in spec):
            return t  # as seeded: the same bytes on both sides, and no file's inode
        tables = [self.run["trees"][x][1] for x in ([b0 - 1, b0] if b0 > 0 else [0])]

        def one(m):
            for table in tables:
                if int(m.group(0)) in table:
                    self.bump("inode")
                    return "<ino:%s>" % table[int(m.group(0))][0]
            return m.group(0)
        return INODES_OBJ.sub(lambda m: re.sub(r'(?<=[":|])[0-9]+(?=["|])', one, m.group(0)), t)

    def clock_text(self, t):
        def one(_m):
            self.bump("clock")
            return "<clock>"
        return CLOCKS_OBJ.sub(lambda m: CLOCK.sub(one, m.group(0)), t)

    def stderr(self, k, raw):
        kept = []
        for line in raw.decode("latin-1").split("\n"):
            if BASH_DIAG.match(line):
                self.bump("bash-diagnostic")
                self.diag.append("step %d: %s" % (k, self.text(line)))
            else:
                kept.append(line)
        return self.text("\n".join(kept))

    def tree(self, b):
        entries = self.run["trees"][b][0]
        deadline = self.case.get("family") == "deadline"
        rows = []
        for rel, (kind, mode, data) in entries.items():
            if deadline and rel.startswith("tmp/"):
                self.bump("deadline-tmp")
                self.noted.append("left in TMPDIR, not compared: %s" % self.name(rel))
                continue
            body = data.decode("latin-1")
            if kind == "file" and rel.startswith("state/pending/") and rel.endswith(".json"):
                body = self.clock_text(self.inode_text(rel, b, body))
            body = self.text(body)
            name = self.name(rel)
            if rel.startswith("calls/") and kind == "file":
                self.bump("stub-call-name")
                try:
                    rec = json.loads(body)
                    key = json.dumps([rec.get("argv"), rec.get("cwd")], sort_keys=True)
                except ValueError:
                    key = body
                name = "%s/%s" % (rel.rsplit("/", 1)[0], hashlib.sha1(key.encode("latin-1", "replace")).hexdigest()[:12])
            head = {"dir": "dir %s" % mode, "file": "file %s" % mode, "link": "link", "other": "other %s" % mode}[kind]
            rows.append((name, self.written_at(rel, b), body, rel, head))
        rows.sort()
        out = []
        seen = {}
        for name, _since, body, _rel, head in rows:
            seen[name] = seen.get(name, 0) + 1
            key = name if seen[name] == 1 else "%s #%d" % (name, seen[name])
            out.append((key, head + ("\n" + body if head.startswith(("file", "link")) else "")))
        return out

    def document(self):
        doc = []
        for k, s in enumerate(self.run["steps"]):
            if s is None:
                continue
            p = "step %d %s" % (k, s["hook"])
            doc.append((p + " status", s["status"]))
            doc.append((p + " stdout", self.text(s["out"].decode("latin-1"))))
            doc.append((p + " stderr", self.stderr(k, s["err"])))
            for key, body in self.tree(k + 1):
                doc.append(("%s tree %s" % (p, key), body))
        return doc


def compare(a_doc, b_doc):
    a, b = dict(a_doc), dict(b_doc)
    diffs = []
    for key in list(dict.fromkeys([k for k, _ in a_doc] + [k for k, _ in b_doc])):
        if a.get(key) != b.get(key):
            diffs.append(key)
    return diffs


def channel(key):
    m = re.match(r"step [0-9]+ (?:pre|post) (status|stdout|stderr|tree (.*))$", key)
    if not m:
        return key
    return m.group(1) if not m.group(2) else "tree:" + re.sub(r" #[0-9]+$", "", m.group(2))


def show_diff(key, a, b, limit=24):
    if a is None or b is None:
        return ["  %s: only in the %s" % (key, "reference" if b is None else "candidate")]
    lines = list(difflib.unified_diff(a.split("\n"), b.split("\n"), "reference", "candidate", lineterm="", n=1))
    out = ["  %s:" % key] + ["    " + l[:400] for l in lines[2:limit + 2]]
    if len(lines) > limit + 2:
        out.append("    ... %d more lines" % (len(lines) - limit - 2))
    return out


# --- what the reference has to do in a case -----------------------------------------------

def decision_of(out):
    try:
        doc = json.loads(out.decode("utf-8"))
        return doc.get("hookSpecificOutput", {}).get("permissionDecision") or "none"
    except (ValueError, AttributeError):
        return "none"


def unmet(case, box, run):
    out = []
    for k, s in enumerate(case["steps"]):
        got = run["steps"][k]
        if got is None:
            continue
        exp = s.get("expect", {})
        entries = run["trees"][k + 1][0]
        want_status = exp.get("status", "exit 0")
        if got["status"] != want_status:
            out.append("step %d: the reference ended with %s, the case says %s" % (k, got["status"], want_status))
        if "decision" in exp and decision_of(got["out"]) != exp["decision"]:
            out.append("step %d: the reference decided %s, the case says %s" % (k, decision_of(got["out"]), exp["decision"]))
        for field, raw in (("stdout_has", got["out"]), ("stderr_has", got["err"])):
            for needle in exp.get(field, []):
                if fill(needle, box) not in raw.decode("utf-8", "replace"):
                    out.append("step %d: the reference's %s lacks %r" % (k, field[:-4], needle))
        if exp.get("stdout_empty") and got["out"]:
            out.append("step %d: the reference printed to stdout, the case says it prints nothing" % k)
        for pat in exp.get("tree_has", []):
            if not any(fnmatch.fnmatchcase(rel, pat) for rel in entries):
                out.append("step %d: the reference left nothing named %s" % (k, pat))
        for pat in exp.get("tree_lacks", []):
            hit = [rel for rel in entries if fnmatch.fnmatchcase(rel, pat)]
            if hit:
                out.append("step %d: the reference left %s, the case says nothing is named %s" % (k, hit[0], pat))
        for rel, needles in exp.get("file_has", {}).items():
            body = entries.get(rel, ("", "", b""))[2].decode("utf-8", "replace")
            for needle in needles:
                if fill(needle, box) not in body:
                    out.append("step %d: the reference's %s lacks %r" % (k, rel, needle))
    return out


def reach(run):
    """What a case's reference run touched, for the summary."""
    got = set()
    for k, s in enumerate(run["steps"]):
        if s is None:
            continue
        got.add("%s %s" % (s["hook"], decision_of(s["out"]) if s["hook"] == "pre" else ("message" if s["out"].strip() else "silent")))
        if updated_command(s["out"]) is not None:
            got.add("pre rewrite")
        if s["err"].strip():
            got.add("%s stderr" % s["hook"])
    last = run["trees"][-1][0]
    seen = set()
    for entries, _ in run["trees"][1:]:
        seen.update(entries)
    for label, pat in (("snapshot", "state/snapshots/*_meta.json"), ("call record", "state/pending/id-*.json"),
                       ("keyed record", "state/pending/*__*.json"), ("backstop entry", "state/pending/backstop/*.json"),
                       ("reorg.log", "state/reorg.log"), ("advisory.log", "state/advisory.log"),
                       ("confirmed snapshot", "state/confirmed_*"), ("rollback incident", "state/rollback-incidents/*"),
                       ("npm-withheld record", "state/npm-withheld/*"), ("npm-observed record", "state/npm-observed/*"),
                       ("stand-in npm call", "calls/npm/*"), ("ledger entry", "state/approved-specs/*")):
        if any(fnmatch.fnmatchcase(rel, pat) for rel in seen):
            got.add(label)
    first = run["trees"][0][0]
    if any(rel.startswith("project/") and last.get(rel) != first.get(rel) for rel in set(first) | set(last)):
        got.add("project changed")
    return got


# --- the controls ------------------------------------------------------------------------

# One line of the reference changed per copy. `channel` is where the copy has
# to turn red: a control that is red somewhere else has not shown that its
# channel is compared. `cases` are the cases that reach the line; a control
# runs those and no others.
MUTATIONS = [
    {"name": "exit-status", "cases": ["pre-npm-install-codex"], "file": "scripts/safedeps-pre-guard.sh", "channel": "status",
     "old": "# Allow the command to proceed — PostToolUse will verify the result\nexit 0\n",
     "new": "# Allow the command to proceed — PostToolUse will verify the result\nexit 3\n"},
    {"name": "stdout-bytes", "cases": ["pre-npm-install", "pre-npm-ci-tree"], "file": "scripts/safedeps-pre-guard.sh", "channel": "stdout",
     "old": """      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",updatedInput:{command:$command}}}'\n    exit 0\n""",
     "new": """      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",updatedInput:{command:($command + " ")}}}'\n    exit 0\n"""},
    {"name": "advisory-to-stderr", "cases": ["pre-npm-install"], "file": "scripts/safedeps-pre-guard.sh", "channel": "stderr",
     "old": """  printf '%s\\t%s\\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "${GUARD_DIR}/advisory.log" 2>/dev/null || true\n""",
     "new": """  printf '%s\\t%s\\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >&2 || true\n"""},
    {"name": "advisory-wording", "cases": ["pre-npm-install-no-call-id"], "file": "scripts/safedeps-pre-guard.sh", "channel": "tree:state/advisory.log",
     "old": """  CALL_ID_WHY="this hook's input names no tool_use_id"\n""",
     "new": """  CALL_ID_WHY="this hook's input names no tool use id"\n"""},
    {"name": "time-format", "cases": ["pre-npm-install"], "file": "scripts/safedeps-pre-guard.sh", "channel": "tree:state/advisory.log",
     "old": """  printf '%s\\t%s\\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "${GUARD_DIR}/advisory.log" 2>/dev/null || true\n""",
     "new": """  printf '%s\\t%s\\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "$1" >> "${GUARD_DIR}/advisory.log" 2>/dev/null || true\n"""},
    {"name": "record-field", "cases": ["pre-npm-install"], "file": "scripts/safedeps-pre-guard.sh", "channel": "tree:state/snapshots/<snap#1>_meta.json",
     "old": '  "record": 2,\n', "new": '  "record": 3,\n'},
    {"name": "file-mode", "cases": ["pre-npm-install"], "file": "scripts/safedeps-pre-guard.sh", "channel": "tree:state/advisory.log",
     "old": 'umask 077\nmkdir -p "${GUARD_DIR}" "${SNAPSHOT_DIR}"\n', "new": 'umask 022\nmkdir -p "${GUARD_DIR}" "${SNAPSHOT_DIR}"\n'},
    {"name": "wrong-inode", "cases": ["pre-npm-ci-tree"], "file": "scripts/safedeps-pre-guard.sh", "channel": "tree:state/pending/id-*.json",
     "old": """    --arg lock "$(guard_file_inode "${PROJECT_DIR}/package-lock.json")" \\\n""",
     "new": """    --arg lock "$(guard_file_inode "${PROJECT_DIR}/package.json")" \\\n"""},
    {"name": "snapshot-named", "cases": ["pre-npm-install"], "file": "scripts/safedeps-pre-guard.sh", "channel": "tree:state/pending/id-*.json",
     "old": """  '{snapshot_id: $sid, project_dir: $pdir, dir_hash: $dhash, project_dir_from: $from,\n""",
     "new": """  '{snapshot_id: ($sid + "-1"), project_dir: $pdir, dir_hash: $dhash, project_dir_from: $from,\n"""},
    {"name": "tmp-left-behind", "cases": ["pre-npm-install"], "file": "scripts/safedeps-pre-guard.sh", "channel": "tree:tmp/safedeps-lex.<tmp>",
     "old": """trap 'release_state_lock; rm -f "${SAFEDEPS_SCAN_MARK:-}"; rm -rf "${SAFEDEPS_LEX_CACHE:-}"' EXIT\n""",
     "new": """trap 'release_state_lock; rm -f "${SAFEDEPS_SCAN_MARK:-}"' EXIT\n"""},
    {"name": "post-log-entry", "cases": ["npm-install-no-trace"], "file": "scripts/safedeps-post-verify.sh", "channel": "tree:state/advisory.log",
     "old": """  printf '%s\\t%s\\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "${GUARD_DIR}/advisory.log" 2>/dev/null || true\n""",
     "new": """  printf '%s\\t%s\\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1 " >> "${GUARD_DIR}/advisory.log" 2>/dev/null || true\n"""},
    # A seeded value stated wrongly, in the shape of the right one: each is a
    # value a mask would take by its shape alone. They have to be red, so the
    # masks are shown to take only what this run wrote.
    {"name": "seed-iso", "cases": ["post-journal-unfinished"], "file": "lib/gates/rollback-journal.sh", "channel": "stdout",
     "old": """    journal_line="Journal: ${journal_id}, opened ${opened_at}; last recorded stage ${stage}${stage_detail}"\n""",
     "new": """    journal_line="Journal: ${journal_id}, opened ${stage_at:-${opened_at}}; last recorded stage ${stage}${stage_detail}"\n"""},
    {"name": "seed-pid", "cases": ["post-journal-unfinished"], "file": "lib/gates/rollback-journal.sh", "channel": "stdout",
     "old": """  SAFEDEPS_JOURNAL_OWNER_FACT="pid ${pid} is not running"\n""",
     "new": """  SAFEDEPS_JOURNAL_OWNER_FACT="pid ${pid%?}8 is not running"\n"""},
    {"name": "seed-snapshot-id", "cases": ["post-journal-unfinished"], "file": "lib/gates/rollback-journal.sh", "channel": "stdout",
     "old": """    printf 'Rollback snapshot: %s; no confirmed snapshot names it' "${snap}"\n""",
     "new": """    printf 'Rollback snapshot: %s; no confirmed snapshot names it' "${snap%?}3"\n"""},
    # The incident record is the journal entry, moved. The copy changes the
    # seeded epoch's last digit and keeps the entry's inode, mode and other bytes.
    {"name": "seed-epoch", "cases": ["post-journal-unfinished"], "file": "lib/gates/rollback-journal.sh", "channel": "tree:state/rollback-incidents/*",
     "old": """    mv -f "${entry}" "${SAFEDEPS_INCIDENT_DIR}/${journal_id}.json" 2>/dev/null || rm -f "${entry}"\n""",
     "new": """    { sed 's/"at": 1767225600/"at": 1767225601/' "${entry}" > "${entry}.m" && cat "${entry}.m" > "${entry}"; rm -f "${entry}.m"; }; mv -f "${entry}" "${SAFEDEPS_INCIDENT_DIR}/${journal_id}.json" 2>/dev/null || rm -f "${entry}"\n"""},
]


def mutant_tree(ctx, m):
    src = os.path.join(ctx.ref_root, m["file"])
    with open(src, "rb") as f:
        text = f.read()
    old, new = m["old"].encode("utf-8"), m["new"].encode("utf-8")
    if text.count(old) != 1:
        die("control %s: its line is not in %s exactly once (found %d times)" % (m["name"], m["file"], text.count(old)))
    root = os.path.join(ctx.work, "mutant-" + m["name"])
    os.makedirs(root)
    for d in ("scripts", "lib", "bin"):
        shutil.copytree(os.path.join(ctx.ref_root, d), os.path.join(root, d), symlinks=True,
                        ignore=shutil.ignore_patterns("measure", "test", "ci", "native"))
    with open(os.path.join(root, m["file"]), "wb") as f:
        f.write(text.replace(old, new))
    return root


# --- the fixture provider ------------------------------------------------------------------

def start_provider(ctx):
    node = shutil.which("node")
    if not node:
        die("--fixture-provider needs node on PATH")
    d = os.path.join(ctx.work, "provider")
    os.makedirs(d)
    port_file, state_file = os.path.join(d, "port"), os.path.join(d, "state.json")
    with open(state_file, "w") as f:
        f.write('{"vulnerable":[]}\n')
    p = subprocess.Popen([node, os.path.join(ROOT, "scripts", "test", "fixture-provider.mjs"), port_file, state_file],
                         cwd=d, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(100):
        if os.path.exists(port_file) and os.path.getsize(port_file):
            break
        time.sleep(0.1)
    else:
        p.kill()
        die("the fixture provider did not start")
    base = "http://127.0.0.1:%s" % open(port_file).read().strip()
    ctx.provider_env = {"SAFEDEPS_OSV_API_URL": base + "/osv/v1/query", "SAFEDEPS_OSV_BATCH_API_URL": base + "/osv/v1/querybatch",
                        "SAFEDEPS_KEV_CATALOG_URL": base + "/kev.json", "SAFEDEPS_GHSA_API_URL": base + "/advisories",
                        "SAFEDEPS_PROVIDER_CACHE_TTL_SECONDS": "0"}
    ctx.provider_state = state_file
    return p


# --- one case ---------------------------------------------------------------------------

class CaseRun:
    """A case's seed and its reference run, kept for every comparison of the case."""

    def __init__(self, ctx, case, index):
        self.ctx, self.case = ctx, case
        self.dir = os.path.join(ctx.work, "c%04d" % index)
        os.makedirs(self.dir)
        self.box = os.path.join(self.dir, "box")
        self.seed = os.path.join(self.dir, "seed")
        self.error = build_seed(ctx, case, self.box, self.seed)
        self.ref = None
        self.ref_canon = None
        self.ref_doc = None
        self.unmet = []
        self.reach = set()

    def reference(self, impl):
        if self.error:
            return
        self.ref = run_side(self.ctx, self.case, self.box, self.seed, impl)
        self.ref_canon = Canon(self.case, self.box, self.ref, impl.roots)
        self.ref_doc = self.ref_canon.document()
        self.unmet = unmet(self.case, self.box, self.ref)
        self.reach = reach(self.ref)

    def against(self, impl):
        run = run_side(self.ctx, self.case, self.box, self.seed, impl)
        canon = Canon(self.case, self.box, run, impl.roots)
        doc = canon.document()
        return compare(self.ref_doc, doc), doc, canon, run

    def close(self):
        rmtree(self.box)
        rmtree(self.seed)


def uptime():
    try:
        return subprocess.run(["uptime"], capture_output=True, timeout=10).stdout.decode("latin-1").strip()
    except (OSError, subprocess.SubprocessError):
        return "uptime did not answer"


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--core", default="")
    ap.add_argument("--cand-root", default="")
    ap.add_argument("--control", action="store_true")
    ap.add_argument("--stages", default="pre,post")
    ap.add_argument("--cases", action="append", default=[])
    ap.add_argument("--only", default="")
    ap.add_argument("--tags", default="")
    ap.add_argument("--jobs", type=int, default=1)
    ap.add_argument("--report", default="")
    ap.add_argument("--dump", default="")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--fixture-provider", action="store_true")
    ap.add_argument("--timeout", type=int, default=90)
    a = ap.parse_args()
    if sum(bool(x) for x in (a.core, a.cand_root, a.control)) > 1:
        die("--core, --cand-root and --control are one at a time")
    stages = [s for s in a.stages.split(",") if s]
    if not stages or any(s not in ("pre", "post") for s in stages):
        die("--stages names pre, post or both")
    jobs = max(1, min(a.jobs, 2))

    cases = load_cases(a.cases or [DEFAULT_CASES])
    if a.only:
        want = a.only.split(",")
        missing = [w for w in want if w not in [c["id"] for c in cases]]
        if missing:
            die("no case named %s" % ", ".join(missing))
        cases = [c for c in cases if c["id"] in want]
    if a.tags:
        want = set(a.tags.split(","))
        cases = [c for c in cases if want & set(c.get("tags", []))]
    if a.list:
        for c in cases:
            print("%s\t%s\t%s" % (c["id"], ",".join(c.get("tags", [])), c.get("note", "")))
        return 0
    if a.control:
        named = set(c for m in MUTATIONS for c in m.get("cases", []))
        missing = sorted(named - set(c["id"] for c in cases))
        if missing:
            die("a control names a case that is not in the corpus: %s" % ", ".join(missing))
        cases = [c for c in cases if c["id"] in named]
    skipped = []
    if not a.fixture_provider:
        skipped = [c["id"] for c in cases if c.get("providers") == "fixture"]
        cases = [c for c in cases if c.get("providers") != "fixture"]
    if not cases:
        die("no case to run")

    work = os.path.realpath(tempfile.mkdtemp(prefix="safedeps-core-hook."))
    ctx = Ctx(a, work)
    provider = start_provider(ctx) if a.fixture_provider else None
    ref = bash_impl("reference", ROOT)
    mode = "the reference again"
    cand = ref
    if a.core:
        core = os.path.abspath(a.core)
        if not os.access(core, os.X_OK):
            die("%s is not an executable file" % core)
        try:
            r = subprocess.run([core, "stamp", "--check"], capture_output=True, timeout=60)
        except (OSError, subprocess.SubprocessError) as e:
            die("%s stamp --check did not run: %s" % (core, e))
        if r.returncode != 0 or r.stdout.decode("latin-1").strip() != "ok":
            die("%s stamp --check did not print ok (exit %d): %s %s\nno case was run: every hook of this binary would deny for the same reason"
                % (core, r.returncode, r.stdout.decode("latin-1").strip(), r.stderr.decode("latin-1").strip()))
        # The binary's tree is three directories up: <tree>/bin/native/<os>-<arch>/safedeps-core.
        core_tree = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(core))))
        cand = mixed(ref, Impl("core", [core, "pre"], [core, "post"], [core_tree, os.path.realpath(core_tree)]), stages)
        mode = "%s, stages %s" % (core, ",".join(stages))
    elif a.cand_root:
        cand = mixed(ref, bash_impl("candidate", os.path.abspath(a.cand_root)), stages)
        mode = "the bash hooks of %s, stages %s" % (os.path.abspath(a.cand_root), ",".join(stages))
    elif a.control:
        mode = "controls"

    print("core-hook-differential: %d cases against %s, jobs %d" % (len(cases), mode, jobs), flush=True)
    print("start: %s" % uptime(), flush=True)
    if skipped:
        print("not run, %d cases that need --fixture-provider: %s" % (len(skipped), ", ".join(skipped)), flush=True)

    lock = threading.Lock()
    report = {"mode": mode, "cases": [], "controls": []}
    red = []
    totals = dict.fromkeys(MASKS, 0)
    kept = dict.fromkeys(KEPT, 0)
    reached = {}
    hook_steps = [0]
    diag_cases = [0]

    def one(ix_case):
        ix, case = ix_case
        cr = CaseRun(ctx, case, ix)
        row = {"id": case["id"], "different": [], "unmet": [], "error": cr.error, "diagnostics": [], "noted": []}
        lines = []
        mutant_rows = []
        if cr.error:
            lines.append("not ok - %s: %s" % (case["id"], cr.error))
        else:
            cr.reference(ref)
            row["unmet"] = cr.unmet
            row["secs"] = [round(s["secs"], 2) for s in cr.ref["steps"] if s]
            row["status"] = [s["status"] for s in cr.ref["steps"] if s]
            for u in cr.unmet:
                lines.append("not ok - %s: %s" % (case["id"], u))
            if a.control:
                for m, root in mutants:
                    if m.get("cases") and case["id"] not in m["cases"]:
                        continue
                    diffs, _doc, _canon, _run = cr.against(bash_impl(m["name"], root))
                    mutant_rows.append((m["name"], sorted(set(channel(d) for d in diffs))))
            else:
                diffs, doc, canon, run = cr.against(cand)
                row["different"] = diffs
                row["diagnostics"] = cr.ref_canon.diag + canon.diag
                row["noted"] = cr.ref_canon.noted + canon.noted
                if diffs:
                    a_map, b_map = dict(cr.ref_doc), dict(doc)
                    lines.append("not ok - %s: %d entries differ (%s)" % (
                        case["id"], len(diffs), ", ".join(sorted(set(channel(d) for d in diffs))[:6])))
                    shown = set()
                    for d in diffs:
                        if channel(d) in shown:
                            continue
                        shown.add(channel(d))
                        if len(shown) > 8:
                            lines.append("  ... more channels differ; see --report")
                            break
                        lines.extend(show_diff(d, a_map.get(d), b_map.get(d)))
                    row["diff"] = {d: {"reference": a_map.get(d), "candidate": b_map.get(d)} for d in diffs[:200]}
                    row["candidate_secs"] = [round(s["secs"], 2) for s in run["steps"] if s]
            if a.dump:
                with open(os.path.join(a.dump, case["id"] + ".txt"), "w", encoding="latin-1") as f:
                    for key, body in cr.ref_doc:
                        f.write("=== %s ===\n%s\n" % (key, body))
        with lock:
            if lines:
                print("\n".join(lines), flush=True)
            if cr.error or cr.unmet or row["different"]:
                red.append(case["id"])
            report["cases"].append(row)
            if cr.ref:
                hook_steps[0] += len([s for s in cr.ref["steps"] if s])
                for k, v in cr.ref_canon.counts.items():
                    totals[k] += v
                for k, v in cr.ref_canon.kept.items():
                    kept[k] += v
                for r in cr.reach:
                    reached[r] = reached.get(r, 0) + 1
                if cr.ref_canon.diag:
                    diag_cases[0] += 1
            for name, chans in mutant_rows:
                control_hits.setdefault(name, {})[case["id"]] = chans
        cr.close()

    mutants = []
    control_hits = {}
    if a.control:
        mutants = [(m, mutant_tree(ctx, m)) for m in MUTATIONS]
    if a.dump:
        os.makedirs(a.dump, exist_ok=True)
    try:
        with ThreadPoolExecutor(max_workers=jobs) as ex:
            list(ex.map(one, list(enumerate(cases))))
    finally:
        if provider:
            provider.kill()
            provider.wait()

    status = 0
    print("cases %d, hook calls per side %d, red %d%s" % (len(cases), hook_steps[0], len(red), (": " + ", ".join(sorted(red))) if red else ""))
    print("masks applied on the reference side: %s" % ", ".join("%s %d" % (k, totals[k]) for k in MASKS))
    print("compared as written on the reference side (seeded, or no proven origin in this run): %s"
          % ", ".join("%s %d" % (k, kept[k]) for k in KEPT))
    print("bash diagnostics set aside in %d cases" % diag_cases[0])
    print("reached by the reference: %s" % ", ".join("%s %d" % (k, reached[k]) for k in sorted(reached)))
    if red:
        status = 1
    if a.control:
        for m in MUTATIONS:
            hits = control_hits.get(m["name"], {})
            red_cases = sorted(c for c, chans in hits.items() if chans)
            want = m["channel"]
            in_channel = sorted(c for c, chans in hits.items() if any(fnmatch.fnmatchcase(ch, want) for ch in chans))
            ok = bool(in_channel)
            print("%s - control %s: red in %d of %d cases, %d of them in %s" % (
                "ok" if ok else "not ok", m["name"], len(red_cases), len(hits), len(in_channel), want))
            if not ok:
                status = 1
                seen = sorted(set(ch for chans in hits.values() for ch in chans))
                print("  it was red in: %s" % (", ".join(seen[:12]) or "nothing"))
            report["controls"].append({"name": m["name"], "channel": want, "red_cases": red_cases, "in_channel": in_channel})
    elif not red:
        print("ok - %d cases: the two sides are equal after the masks" % len(cases))
    if skipped:
        print("not run: %d cases need --fixture-provider" % len(skipped))
    print("end: %s" % uptime(), flush=True)
    if a.report:
        report["masks"] = totals
        report["kept"] = kept
        report["reached"] = reached
        report["skipped"] = skipped
        with open(a.report, "w", encoding="utf-8") as f:
            json.dump(report, f, ensure_ascii=False, indent=1)
    rmtree(work)
    return status


if __name__ == "__main__":
    sys.exit(main())
