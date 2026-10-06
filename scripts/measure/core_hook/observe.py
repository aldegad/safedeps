"""safedeps core-hook-differential: what one side of a case did, kept whole.

A side is one implementation's run of a case: the seed restored, then each
step in order. What this module keeps of it is the side's raw bundle, and
nothing here reads it for a verdict:

  steps       a hook step's argv, cwd, environment, stdin, the pid of the
              process this module started, the clock of this module just
              before the start and just after the end, the status, stdout and
              stderr bytes; an effect step's operations
  boundaries  before the first step and after each step, every entry of the
              sandbox: kind, mode, bytes or link text, and what lstat (and,
              through a link, stat) answered for it: inode, device, links,
              size, mtime and ctime in nanoseconds; an entry that could not be
              read says so
  calls       what the stand-ins this module owns were asked during a step:
              the stand-in npm (argv, cwd, environment, the answer it gave,
              and lstat of each absolute path in its argv and environment at
              the time of the call) and the recording date (argv, the bytes
              the real date printed, its status)

The recording date is on PATH ahead of the system's own. It runs the date the
hooks would have found and prints what that printed, so a bash hook's clock
readings are seen where they are taken. A hook that reads the clock inside its
own process (the Rust core does) is not seen, and nothing here pretends it is.

Bytes are kept once each, by sha256, in the bundle's `blobs`.
"""
import base64
import hashlib
import json
import os
import shutil
import signal
import stat
import subprocess
import sys
import time

BOX_DIRS = ("home", "state", "project", "tmp")
CLOSED_PORT = "http://127.0.0.1:9"
SIDE_FORMAT = "safedeps-core-hook-side/1"

# What a stand-in npm leaves out of the environment it records: names the
# shell that starts it sets by itself, which say nothing of what the hook
# chose to pass.
STUB_ENV_NOISE = ("_", "SHLVL")


class HarnessError(Exception):
    """The harness could not do what it was asked; the caller exits 2."""


def fail(msg):
    raise HarnessError(msg)


# --- bytes ---------------------------------------------------------------------

class Blobs:
    """Bytes kept once each, named by their sha256."""

    def __init__(self, data=None):
        self.data = dict(data or {})

    def put(self, b):
        d = hashlib.sha256(b).hexdigest()
        self.data.setdefault(d, b)
        return d

    def get(self, d):
        if d not in self.data:
            fail("a bundle names bytes it does not hold: %s" % d)
        return self.data[d]

    def dump(self):
        return {d: base64.b64encode(b).decode("ascii") for d, b in sorted(self.data.items())}

    @classmethod
    def load(cls, doc):
        data = {}
        for digest, encoded in doc.items():
            try:
                raw = base64.b64decode(encoded, validate=True)
            except (ValueError, TypeError) as e:
                fail("invalid bundle blob %s: %s" % (digest, e))
            if hashlib.sha256(raw).hexdigest() != digest:
                fail("bundle blob digest mismatch: %s" % digest)
            data[digest] = raw
        return cls(data)


# --- the case's sandbox ------------------------------------------------------------

def inside(box, rel):
    if not isinstance(rel, str) or rel.startswith("/") or ".." in rel.split("/") or not rel:
        fail("a path in a case is relative to the sandbox and stays inside it: %r" % (rel,))
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
        import re
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
            fail("an effect does not know the operation %r" % (op,))


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


# --- the stand-ins ------------------------------------------------------------------

# The stand-in npm records how it was called, in a file of this module's (not
# in the sandbox), and prints the answer its case wrote for that call. It
# installs nothing and starts nothing. Its record also holds lstat of every
# absolute path in its argv and environment, and of that path's directory,
# taken while it runs: a scratch directory the hook made for the call and
# removed after it is seen there and nowhere else.
STUB_NPM = r'''#!%(python)s -I
# safedeps core-hook-differential: a stand-in npm.
import json, os, stat, sys
here = os.path.dirname(os.path.abspath(__file__))
conf = json.load(open(os.path.join(here, "npm.answers.json")))
argv = sys.argv[1:]
env = {k: v for k, v in os.environ.items() if k not in conf["noise"]}
def fact(p):
    try:
        st = os.lstat(p)
    except OSError as e:
        return {"error": e.strerror}
    kind = "link" if stat.S_ISLNK(st.st_mode) else "dir" if stat.S_ISDIR(st.st_mode) else "file" if stat.S_ISREG(st.st_mode) else "other"
    return {"kind": kind, "ino": st.st_ino, "dev": st.st_dev}
paths = {}
for w in argv + list(env.values()) + [os.getcwd()]:
    for piece in w.split("="):
        if piece.startswith("/"):
            for p in (piece, os.path.dirname(piece)):
                paths.setdefault(p, fact(p))
answer, which = conf["default"], None
for i, a in enumerate(conf["answers"]):
    words = a.get("argv", [])
    if argv[:len(words)] == words:
        answer, which = a, i
        break
n = 0
while True:
    name = os.path.join(conf["calls"], "%%d.json" %% n)
    try:
        claim = os.open(name + ".claim", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.close(claim)
        fd = os.open(name + ".part", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        break
    except FileExistsError:
        n += 1
record = {"argv": argv, "cwd": os.getcwd(), "env": env, "paths": paths, "answer": which,
          "stdout": answer.get("stdout", ""), "stderr": answer.get("stderr", ""), "exit": answer.get("exit", 0)}
with os.fdopen(fd, "w") as f:
    json.dump(record, f, sort_keys=True)
os.rename(name + ".part", name)
if answer.get("sleep"):
    import time
    time.sleep(answer["sleep"])
sys.stdout.write(answer.get("stdout", ""))
sys.stderr.write(answer.get("stderr", ""))
sys.stdout.flush()
sys.exit(answer.get("exit", 0))
'''

# The recording date. It claims the next number in its directory (the order of
# the calls), writes the argv there with its own pid, its parent's and the
# locale and zone settings it was started with, runs the date the hooks would
# have found, keeps what it printed and its status, and prints that. A call
# whose `.rc` is missing did not end while this module was looking, and is no
# clock reading anyone can cite.
DATE_RECORDER = r'''#!/bin/sh
# safedeps core-hook-differential: a date that records each call.
d='%(dir)s'
n=0
while ! ( set -C; : > "$d/$n.argv" ) 2>/dev/null; do
  [ -e "$d/$n.argv" ] || exit 125
  n=$((n + 1))
done
for a in "$@"; do printf '%%s\000' "$a"; done > "$d/$n.argv"
printf 'pid=%%s\000ppid=%%s\000LANG=%%s\000LC_ALL=%%s\000LC_TIME=%%s\000TZ=%%s\000' "$$" "$PPID" \
  "${LANG-<unset>}" "${LC_ALL-<unset>}" "${LC_TIME-<unset>}" "${TZ-<unset>}" > "$d/$n.meta"
'%(real)s' "$@" > "$d/$n.out" 2> "$d/$n.err"
rc=$?
printf '%%s\n' "$rc" > "$d/$n.rc"
cat "$d/$n.out"
[ -s "$d/$n.err" ] && cat "$d/$n.err" >&2
exit "$rc"
'''


def write_stub(box, npm, calls_dir):
    d = os.path.join(box, "stub")
    os.makedirs(d, exist_ok=True)
    conf = {"calls": calls_dir, "noise": list(STUB_ENV_NOISE),
            "answers": fill(npm.get("answers", []), box),
            "default": fill(npm.get("default", {"exit": 1, "stderr": "stand-in npm: no answer for this call\n"}), box)}
    with open(os.path.join(d, "npm.answers.json"), "w", encoding="utf-8") as f:
        json.dump(conf, f, indent=1, sort_keys=True)
        f.write("\n")
    with open(os.path.join(d, "npm"), "w", encoding="utf-8") as f:
        f.write(STUB_NPM % {"python": sys.executable})
    os.chmod(os.path.join(d, "npm"), 0o755)


def write_date_recorder(obs, real_date):
    bindir = os.path.join(obs, "bin")
    os.makedirs(bindir, exist_ok=True)
    os.makedirs(os.path.join(obs, "date"), exist_ok=True)
    path = os.path.join(bindir, "date")
    with open(path, "w", encoding="utf-8") as f:
        f.write(DATE_RECORDER % {"dir": os.path.join(obs, "date"), "real": real_date})
    os.chmod(path, 0o755)


def take_calls(obs, blobs):
    """The stand-ins' records since the last time, and clear them."""
    dates, incomplete = [], []
    ddir = os.path.join(obs, "date")
    names = os.listdir(ddir) if os.path.isdir(ddir) else []
    nums = sorted(int(n.split(".")[0]) for n in names if n.endswith(".argv") and n.split(".")[0].isdigit())
    for n in nums:
        base = os.path.join(ddir, str(n))
        argv = open(base + ".argv", "rb").read().split(b"\0")[:-1]
        argv = [a.decode("utf-8", "surrogateescape") for a in argv]
        if not os.path.exists(base + ".rc"):
            incomplete.append({"seq": n, "argv": argv})
            continue
        rc = open(base + ".rc").read().strip()
        meta = dict(p.split("=", 1) for p in read_or_empty(base + ".meta").decode("utf-8", "surrogateescape").split("\0") if "=" in p)
        dates.append({"seq": n, "argv": argv, "stdout": blobs.put(read_or_empty(base + ".out")),
                      "stderr": blobs.put(read_or_empty(base + ".err")), "rc": int(rc) if rc.lstrip("-").isdigit() else rc,
                      "process": meta})
    npms = []
    ndir = os.path.join(obs, "npm")
    names = os.listdir(ndir) if os.path.isdir(ndir) else []
    for name in sorted(names, key=lambda n: (len(n), n)):
        p = os.path.join(ndir, name)
        if name.endswith(".claim"):
            continue
        if name.endswith(".part"):
            incomplete.append({"npm": name})
            continue
        rec = json.load(open(p, encoding="utf-8", errors="surrogateescape"))
        rec["seq"] = int(name.split(".")[0])
        npms.append(rec)
    for d in (ddir, ndir):
        rmtree(d)
        os.makedirs(d)
    return dates, npms, incomplete


def read_or_empty(p):
    try:
        with open(p, "rb") as f:
            return f.read()
    except OSError:
        return b""


# --- what the disk holds ------------------------------------------------------------

def kind_of(m):
    if stat.S_ISLNK(m):
        return "link"
    if stat.S_ISDIR(m):
        return "dir"
    if stat.S_ISREG(m):
        return "file"
    return "other"


def harvest(box, blobs):
    """Every entry under <box>, with what lstat said of it. Nothing is
    skipped: an entry that cannot be read is an entry with its error."""
    entries = {}
    walk_errors = []

    def onerror(e):
        walk_errors.append("%s: %s" % (os.path.relpath(e.filename, box) if e.filename else "?", e.strerror))
    for dirpath, dirnames, filenames in os.walk(box, followlinks=False, onerror=onerror):
        for name in dirnames + filenames:
            p = os.path.join(dirpath, name)
            rel = os.path.relpath(p, box)
            try:
                st = os.lstat(p)
            except OSError as e:
                entries[rel] = {"kind": "gone", "lstat_error": e.strerror}
                continue
            e = {"kind": kind_of(st.st_mode), "mode": "%04o" % stat.S_IMODE(st.st_mode), "ino": st.st_ino,
                 "dev": st.st_dev, "nlink": st.st_nlink, "size": st.st_size, "mtime_ns": st.st_mtime_ns,
                 "ctime_ns": st.st_ctime_ns}
            if e["kind"] == "link":
                try:
                    e["target"] = os.readlink(p)
                except OSError as err:
                    e["read_error"] = err.strerror
                try:
                    t = os.stat(p)
                    e["follow"] = {"kind": kind_of(t.st_mode), "ino": t.st_ino, "dev": t.st_dev,
                                   "mtime_ns": t.st_mtime_ns, "ctime_ns": t.st_ctime_ns}
                except OSError as err:
                    e["follow"] = {"error": err.strerror}
            elif e["kind"] == "file":
                try:
                    with open(p, "rb") as f:
                        e["blob"] = blobs.put(f.read())
                except OSError as err:
                    e["read_error"] = err.strerror
            entries[rel] = e
    return {"entries": entries, "walk_errors": walk_errors}


# --- running a hook -------------------------------------------------------------------

def system_path():
    dirs = [d for d in ("/usr/bin", "/bin", "/usr/sbin", "/sbin") if os.path.isdir(d)]
    for tool in ("bash", "jq", "awk", "sed", "grep", "find", "curl", "mktemp", "date", "stat"):
        if any(os.access(os.path.join(d, tool), os.X_OK) for d in dirs):
            continue
        found = shutil.which(tool)
        if not found:
            fail("%s is not on PATH; the hooks need it" % tool)
        dirs.append(os.path.dirname(os.path.realpath(found)))
    return dirs


def first_on(dirs, tool):
    for d in dirs:
        p = os.path.join(d, tool)
        if os.access(p, os.X_OK) and not os.path.isdir(p):
            return p
    fail("%s is not in %s" % (tool, ":".join(dirs)))


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
    for p in list(reversed(descendants(pid))) + [pid]:
        try:
            os.kill(p, signal.SIGKILL)
        except OSError:
            pass


def run_hook(argv, data, env, cwd, timeout, pass_fds=()):
    t0 = time.time_ns()
    try:
        p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, cwd=cwd, pass_fds=pass_fds)
    except OSError as e:
        return {"status": "did not start: %s" % e.strerror, "out": b"", "err": b"", "pid": 0, "t0_ns": t0, "t1_ns": time.time_ns()}
    try:
        out, err = p.communicate(data, timeout=timeout)
        status = "exit %d" % p.returncode if p.returncode >= 0 else "signal %d" % -p.returncode
    except subprocess.TimeoutExpired:
        stop_tree(p.pid)
        out, err = p.communicate()
        status = "no answer in %d seconds" % timeout
    return {"status": status, "out": out, "err": err, "pid": p.pid, "t0_ns": t0, "t1_ns": time.time_ns()}


class Impl:
    """One implementation of the two hooks: for each, its argv, its kind
    (bash or core) and the trees it lives in."""

    def __init__(self, name, hooks):
        self.name = name
        self.hooks = hooks  # {"pre": {"argv", "kind", "roots"}, "post": {...}}

    def describe(self):
        return {"name": self.name, "hooks": {name: {k: v for k, v in hook.items() if k != 'native_receipt'}
                                             for name, hook in self.hooks.items()}}


def bash_impl(name, root):
    for f in ("scripts/safedeps-pre-guard.sh", "scripts/safedeps-post-verify.sh"):
        if not os.path.isfile(os.path.join(root, f)):
            fail("%s has no %s" % (root, f))
    roots = sorted(set([root, os.path.realpath(root)]), key=len, reverse=True)
    return Impl(name, {
        "pre": {"argv": ["bash", os.path.join(root, "scripts", "safedeps-pre-guard.sh")], "kind": "bash", "roots": roots},
        "post": {"argv": ["bash", os.path.join(root, "scripts", "safedeps-post-verify.sh")], "kind": "bash", "roots": roots}})


def core_impl(core, tree):
    roots = sorted(set([tree, os.path.realpath(tree)]), key=len, reverse=True)
    return Impl("core", {h: {"argv": [core, h], "kind": "core", "roots": roots} for h in ("pre", "post")})


def mixed(ref, cand, stages):
    return Impl(cand.name, {h: (cand.hooks[h] if h in stages else ref.hooks[h]) for h in ("pre", "post")})


def case_env(ctx, case, box, obs, step):
    dirs = list(ctx.sysdirs)
    dirs.insert(0, os.path.join(obs, "bin"))
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


def build_seed(ctx, case, box, seed, obs):
    """The seed, made once in the sandbox and kept as a copy both runs start from."""
    rmtree(box)
    rmtree(seed)
    rmtree(obs)
    for d in BOX_DIRS:
        if d != "state":
            os.makedirs(os.path.join(box, d))
    write_date_recorder(obs, ctx.real_date)
    os.makedirs(os.path.join(obs, "npm"))
    for rel, spec in case.get("files", {}).items():
        put(box, rel, spec)
    if case.get("npm"):
        write_stub(box, case["npm"], os.path.join(obs, "npm"))
    for argv in case.get("seed_cli", []):
        env = case_env(ctx, case, box, obs, None)
        r = subprocess.run(["bash", os.path.join(ctx.ref_root, "bin", "safedeps")] + fill(argv, box), capture_output=True,
                           env=env, cwd=box + "/project", timeout=120)
        allowed = case.get("seed_cli_exit", [0])
        if r.returncode not in allowed:
            return "the seed command safedeps %s ended with %d: %s" % (" ".join(argv), r.returncode, r.stderr.decode("latin-1")[-400:])
    shutil.copytree(box, seed, symlinks=True)
    if case.get("seed_cli"):
        # The CLI wrote times of its own into the seed. A run that started in
        # the same second could write a value the seed holds, so the runs
        # start in a later second than the seed was made in.
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


def run_side(ctx, case, box, seed, obs, impl, side):
    """One implementation's run of a case, kept as it happened."""
    blobs = Blobs()
    take_calls(obs, Blobs())  # whatever the seed's own commands left
    restore(case, box, seed)
    boundaries = [dict(harvest(box, blobs), t_ns=time.time_ns())]
    steps = []
    sent = {}
    outs = {}
    for k, s in enumerate(case["steps"]):
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
                    cmd = updated_command(outs[src])
                    if cmd is None:
                        cmd = sent[src]
                    payload.setdefault("tool_input", {})["command"] = cmd
                ti = payload.get("tool_input") if isinstance(payload, dict) else None
                sent[k] = ti.get("command", "") if isinstance(ti, dict) else ""
                data = json.dumps(payload, ensure_ascii=False).encode("utf-8", "surrogateescape")
            cwd = s.get("proc_cwd")
            if cwd is None:
                supplied = s.get("payload")
                cwd = s.get("cwd") or (supplied.get("cwd") if isinstance(supplied, dict) else None) or "@PROJECT@"
            cwd = fill(cwd, box)
            if not os.path.isdir(cwd):
                cwd = box
            input_cwd = cwd
            try:
                input_doc = json.loads(data)
                if isinstance(input_doc, dict) and isinstance(input_doc.get("cwd"), str) and input_doc["cwd"]:
                    input_cwd = input_doc["cwd"]
            except (ValueError, UnicodeDecodeError):
                pass
            resolved_input_cwd = os.path.realpath(input_cwd)
            hook = impl.hooks[s["hook"]]
            env = case_env(ctx, case, box, obs, s)
            if hook.get("native_receipt", {}).get("tapped"):
                from .native import run_observed
                r = run_observed(run_hook, hook["argv"], data, env, cwd, ctx.timeout)
            else:
                r = run_hook(hook["argv"], data, env, cwd, ctx.timeout)
            outs[k] = r["out"]
            dates, npms, incomplete = take_calls(obs, blobs)
            steps.append({"kind": "hook", "hook": s["hook"], "impl": hook["kind"], "argv": hook["argv"],
                          "roots": hook["roots"], "cwd": cwd, "input_cwd_resolved": resolved_input_cwd, "env": env, "stdin": blobs.put(data), "pid": r["pid"],
                          "t0_ns": r["t0_ns"], "t1_ns": r["t1_ns"], "status": r["status"], "stdout": blobs.put(r["out"]),
                          "stderr": blobs.put(r["err"]), "date_calls": dates, "npm_calls": npms, "incomplete_calls": incomplete})
            if "native_raw" in r:
                steps[-1].update(native_raw=blobs.put(r['native_raw']), collector_pid=r['collector_pid'])
        else:
            t0 = time.time_ns()
            apply_effect(box, s["effect"])
            dates, npms, incomplete = take_calls(obs, blobs)
            steps.append({"kind": "effect", "ops": fill(s["effect"], box), "t0_ns": t0, "t1_ns": time.time_ns(),
                          "date_calls": dates, "npm_calls": npms, "incomplete_calls": incomplete})
        boundaries.append(dict(harvest(box, blobs), t_ns=time.time_ns()))
    doc = {"format": SIDE_FORMAT, "side": side, "impl": impl.describe(), "box": box, "steps": steps,
           "boundaries": boundaries, "blobs": blobs}
    native_receipts = [h['native_receipt'] for h in impl.hooks.values() if 'native_receipt' in h]
    if native_receipts:
        from .native import pack_receipt
        doc['native'] = pack_receipt(native_receipts[0], blobs)
    return doc


# --- the bundle on disk ------------------------------------------------------------------

def bundle_doc(case, sides, meta):
    """A case's raw bundle: the case as run, each side's record, and their
    bytes. The verdict is not in it: it is computed from it."""
    blobs = Blobs()
    out = {"format": "safedeps-core-hook-bundle/1", "case": case, "meta": meta, "sides": {}}
    for name, side in sides.items():
        blobs.data.update(side["blobs"].data)
        out["sides"][name] = dict({k: v for k, v in side.items() if k != "blobs"}, side=name)
    out["blobs"] = blobs.dump()
    return out


def write_bundle(path, doc):
    tmp = path + ".part"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(doc, f, sort_keys=True, ensure_ascii=True)
        f.write("\n")
    os.rename(tmp, path)
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def read_bundle(path):
    try:
        with open(path, encoding="utf-8") as f:
            doc = json.load(f)
    except (OSError, ValueError) as e:
        fail("cannot read the bundle %s: %s" % (path, e))
    if doc.get("format") != "safedeps-core-hook-bundle/1":
        fail("%s is not a core-hook bundle" % path)
    blobs = Blobs.load(doc["blobs"])
    for side in doc["sides"].values():
        side["blobs"] = blobs
    return doc
