#!/usr/bin/env python3
"""Retired comparison entry; any retained definitions are native fixture helpers."""
import sys

if __name__ == "__main__":
    sys.stderr.write('retired: Bash versus Rust rewrite channel comparison is retired. Recorded release-floor fixtures and native inert tests remain. See native-measure-disposition.json.\n')
    raise SystemExit(2)

import argparse

import base64

import copy

import hashlib

import importlib.util

import json

import os

import re

import shutil

import subprocess

import sys

import tempfile

from concurrent.futures import ThreadPoolExecutor

UNKNOWN = "unknown"

STUB_NPM = '#!/bin/sh\nprintf \'%s\\0\' npm "$#" "$@" >> "$NPMLOG"\n'

STUB_OTHER = '#!/bin/sh\nprintf \'%s\\0\' "${0##*/}" "$#" "$@" >> "$NPMLOG"\n'

STUB_NPX = r'''#!/bin/sh
printf '%s\0' npx "$#" "$@" >> "$NPMLOG"
while [ $# -gt 0 ]; do
  case "$1" in
    -p|--package) shift; [ $# -eq 0 ] || shift ;;
    --) shift; break ;;
    -*) shift ;;
    *) break ;;
  esac
done
[ "${1:-}" = npm ] || exit 0
shift
exec "$(dirname "$0")/npm" "$@"
'''

OTHERS = ["pnpm", "pnpx", "yarn", "bun", "bunx", "pip", "pip3", "pipx", "poetry", "uv", "uvx", "pipenv", "cargo", "go",
          "gem", "bundle", "mvn", "dotnet", "python", "python3", "curl", "wget", "brew", "git", "ssh", "scp", "nc"]

STUB_SUDO = '#!/bin/sh\nwhile [ $# -gt 0 ]; do case "$1" in -*) shift ;; *) break ;; esac; done\nexec "$@"\n'

STUB_SUDO_PRINT = '#!/bin/sh\nprintf \'%s\\0\' sudo "$#" "$@" >> "$NPMLOG"\nprintf \'%s\\n\' "$@"\n'

def sha256(b):
    return hashlib.sha256(b).hexdigest()

def blob(name, b):
    """What a stream held: its length, its sha256 and its first bytes."""
    return {name + "_len": len(b), name + "_sha256": sha256(b), name: b[:2000].decode("latin-1")}

def parse_log(b):
    """The records of a stand-in log, in order: (program, argv). None where
    the log is not whole records."""
    if not b:
        return []
    if not b.endswith(b"\0"):
        return None
    t = b[:-1].split(b"\0")
    out = []
    i = 0
    while i < len(t):
        if i + 1 >= len(t):
            return None
        try:
            n = int(t[i + 1])
        except ValueError:
            return None
        if n < 0 or i + 2 + n > len(t):
            return None
        out.append((t[i].decode("latin-1"), [x.decode("latin-1") for x in t[i + 2:i + 2 + n]]))
        i += 2 + n
    return out

def listing(root):
    """Every path under a run's directory: `d` for a directory, `l` and its
    target for a link, or a file's size and sha256."""
    out = {}
    for base, dirs, files in os.walk(root):
        for n in dirs + files:
            p = os.path.join(base, n)
            rel = os.path.relpath(p, root)
            try:
                if os.path.islink(p):
                    out[rel] = ["l", os.readlink(p)]
                elif os.path.isdir(p):
                    out[rel] = ["d"]
                else:
                    with open(p, "rb") as f:
                        b = f.read(1 << 20)
                    out[rel] = ["f", os.path.getsize(p), sha256(b)]
            except OSError as e:
                out[rel] = ["?", str(e)[:80]]
    return out

class Shells:
    """The shells and the stand-ins. `observe` keeps nothing on the object:
    what a run did is the value it returns, so two runs at once cannot read
    each other's."""

    def __init__(self, work):
        self.stub = os.path.join(work, "stub")
        os.makedirs(self.stub, exist_ok=True)
        texts = {"npm": STUB_NPM, "npx": STUB_NPX, "sudo": STUB_SUDO}
        for o in OTHERS:
            texts[o] = STUB_OTHER
        for s in ("mksh", "fish", "pdksh", "yash", "posh", "ksh", "ksh93", "csh", "tcsh"):
            if not shutil.which(s):
                texts[s] = '#!/bin/sh\nshift\nexec /bin/sh -c "$1"\n'
        for n, t in texts.items():
            open(os.path.join(self.stub, n), "w").write(t)
            os.chmod(os.path.join(self.stub, n), 0o755)
        # The same stand-ins with the other sudo, for the rows that name it.
        self.variants = {"": self.stub, "sudo-print": os.path.join(work, "stub-sudo-print")}
        os.makedirs(self.variants["sudo-print"], exist_ok=True)
        for n, t in texts.items():
            p = os.path.join(self.variants["sudo-print"], n)
            open(p, "w").write(STUB_SUDO_PRINT if n == "sudo" else t)
            os.chmod(p, 0o755)
        self.shells = [s for s in ("/bin/bash", "/bin/zsh", "/bin/dash", "/usr/bin/zsh", "/usr/bin/dash") if os.access(s, os.X_OK)]
        seen = set()
        self.shells = [s for s in self.shells if not (os.path.basename(s) in seen or seen.add(os.path.basename(s)))]
        self.info = {"stubs": {n: sha256(t.encode()) for n, t in sorted(texts.items())}, "shells": {},
                     "stand_ins": {"sudo-print": {"sudo": sha256(STUB_SUDO_PRINT.encode())}},
                     "env": {"HOME": "<the run's directory>", "ZDOTDIR": "<the run's directory>", "PATH": "<stubs>:/usr/bin:/bin",
                             "NPMLOG": "<a file beside the run's directory>", "SD_INERT_CMD": "<the command>"},
                     "initial_files": ["d/"], "deadline_seconds": 10}
        for s in self.shells:
            try:
                v = subprocess.run([s, "--version"], capture_output=True, timeout=20).stdout.split(b"\n")[0].decode("latin-1")
            except (OSError, subprocess.SubprocessError):
                v = ""
            self.info["shells"][os.path.basename(s)] = {"path": s, "sha256": sha256(open(s, "rb").read()), "version": v}

    def runs(self, cmd):
        """`zsh-agent` is the Claude Code Bash tool's wrapper as
        scripts/measure/shell-reading-measure.sh reproduces it, without a
        session snapshot: zsh -c, its setopt line, then eval of the command."""
        out = [(os.path.basename(sh), [sh, "-c", cmd]) for sh in self.shells]
        zsh = next((sh for sh in self.shells if os.path.basename(sh) == "zsh"), None)
        if zsh:
            out.append(("zsh-agent", [zsh, "-c", 'setopt NO_EXTENDED_GLOB NO_BARE_GLOB_QUAL 2>/dev/null || true && eval "$SD_INERT_CMD"']))
        return out

    def observe(self, cmd, box, files=(), stand_ins=""):
        """One run of `cmd` per shell, each in a fresh directory that holds an
        empty `d/` and the files named, with the stand-ins named (the default
        ones, or a variant). Per shell: the exit status, whether the
        run was killed at its deadline, stdout and stderr, every stand-in call
        in order (`calls`: program and argv), the npm calls among them
        (`npm`), the others (`other`), and the files left."""
        out = {}
        for name, argv in self.runs(cmd):
            c = tempfile.mkdtemp(prefix="sh.", dir=box)
            os.makedirs(os.path.join(c, "d"))
            for f in files:
                open(os.path.join(c, f), "w").close()
            log = c + ".log"
            open(log, "w").close()
            env = {"HOME": c, "ZDOTDIR": c, "PATH": self.variants[stand_ins] + ":/usr/bin:/bin", "NPMLOG": log, "SD_INERT_CMD": cmd}
            obs = {"rc": UNKNOWN, "timeout": False}
            try:
                sr = subprocess.run(["nice", "-n", "10", "perl", "-e", "alarm 10; exec @ARGV"] + argv, cwd=c, env=env,
                                    stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
                obs["rc"] = sr.returncode
                obs["timeout"] = sr.returncode == -14
                obs.update(blob("stdout", sr.stdout))
                obs.update(blob("stderr", sr.stderr))
            except subprocess.TimeoutExpired as e:
                obs["rc"] = "timeout"
                obs["timeout"] = True
                obs.update(blob("stdout", e.stdout or b""))
                obs.update(blob("stderr", e.stderr or b""))
            recs = parse_log(open(log, "rb").read())
            if recs is None:
                obs["log"] = "undecodable"
                obs["calls"] = obs["npm"] = obs["other"] = UNKNOWN
            else:
                obs["log"] = "ok"
                obs["calls"] = [[n] + a for n, a in recs]
                obs["npm"] = [a for n, a in recs if n == "npm"]
                obs["other"] = [[n] + a for n, a in recs if n != "npm"]
            obs["files"] = listing(c)
            out[name] = obs
            shutil.rmtree(c, ignore_errors=True)
            try:
                os.unlink(log)
            except OSError:
                pass
        return out
