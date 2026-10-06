#!/usr/bin/env python3
"""safedeps: the Rust core's inert rewrite against the bash guard's, with what
each side's command does in the shells kept as it was observed.

The bash guard is the reference for the comparison. A copy of it, made in a
scratch directory and never in the tree, gets one block before
`# --- Reorg Guard Activated ---`: it runs `guard_reading_inert` in every
reading the guard reads the command in, writes each reading's value
(GUARD_INERT_<reading>) and whether the scan mark is set, and exits.
`safedeps-core inert` prints the same records for the same hook payload. A
command the guard leaves before that line (not an install, or denied by the
detection) is listed and not compared.

What a row is
-------------

Every row has one status, and the counts add up: total = core-error +
bash-not-reached + compared, and compared = reading-set + incomplete +
both-failed + both-undecided + same + differ.

  reading-set      the two sides read the command in different sets of readings
  incomplete       a reading of the set has no value on one side
  both-failed      the reading failed on both sides (UNDECIDED on both)
  both-undecided   the readings hold different values on both sides: no rewrite
                   is sent on either. It is neither `same` nor an agreement.
  same             every reading holds the same bytes on both sides, and neither
                   side's readings disagree among themselves
  differ           anything else; its direction tokens say how

Direction tokens of a difference, per reading: +flag / -flag (a flag at a
place the other side has none), +rec / -rec (a record where the other side
writes none; `~rec+x`, `~rec-x`, `~asked`, `~kind:a>b` say which record or
value changed), +undecided / -undecided, +deny:readings-disagree / -deny.

A difference with only `+` directions is named by a line of
scripts/measure/core-intended-inert.tsv, or it is `unclassified`. A
difference with a `-` direction has no name. What the harness says of one is
an observation for the plan owner to judge row by row, never a class and
never green:

  decrease:minus-deny       the bash side is UNDECIDED and the core is not
  decrease                  observed in a shell: a call of the command as
                            written is gone, an argument's value changed, a
                            placed flag is no option to npm, a call without
                            the flag has no record, or the core's state is
                            worse than the bash side's
  decrease:shared-loss      the same, and the bash side's npm calls are the
                            core's in every shell: what is lost is lost on
                            both sides (a floor flag that breaks a word)
  decrease:unknown          the npm calls were not observed whole (see below)
  decrease:nocall           no shell made an install call: nothing was observed
  decrease:effects-unknown  the npm calls hold, the rest was not recorded
  decrease:effects-differ   the npm calls hold, something else differs from
                            the command as written
  decrease:argv-equal, decrease:core-dominates, decrease:core-exact
                            the npm calls hold and everything recorded is the
                            command's as written; the three say how the bash
                            side compares (`label`, kept on the other
                            `decrease:` rows too)

What is observed
----------------

With --shells, the command as written, the command each side would run and,
with --release-tree, the command an extracted v2.18.1's whole pre-guard sends
run under bash, zsh, dash and the agent's zsh wrapper, each in a fresh
directory, with stand-ins for npm, npx, the other managers and the network
tools. One run gives one local value: its exit status, whether it was killed
at the deadline, its stdout and stderr (length, sha256, first bytes), every
call of a stand-in in order with its argv (NUL-separated, so a tab or a
newline in an argument is kept), and the files it left. Nothing is filled in:
a run that did not happen is absent, a log that cannot be decoded is
`undecodable`, and an axis that was not recorded is `unknown`.

What npm makes of an argv is asked twice, of two readers that share no table:
the gate's own (safedeps_npm_read_args) and npm's own parser (nopt with npm's
option definitions, from the npm on --path-prefix; npm itself is not run).
Which word is the command, and so whether a call is an install, and the last
value ignore-scripts takes, are theirs. Where the two disagree, or npm cannot
be asked, the answer is `unknown`, and a state built on it is UNKNOWN.

A side's state in a shell is FLAG (every install call reads ignore-scripts
true), NOCALL (no install call), REC (a call without the flag, and a record),
SILENT (a call without the flag, no record), or UNKNOWN; a side that sends no
command is `deny`. A run's calls are set beside the calls of the command as
written, argument for argument: the only edit that counts as kept is
`--ignore-scripts` inserted before any `--`, which npm reads as a true option
and which changes nothing else npm reads. An argument that was there, a flag
after `--` included, is never taken out to make two calls compare.

A core detail (`detail.<reading>`) sorts rows; it is the core's own account
and proves nothing about what a shell runs.

With --floor, every command of scripts/test/inert-release-rewrites.json that
the core rewrites is checked against 7d66f8c's recorded rewrite: deleting some
of the core's flags gives the release's (release-floor.sh's property).

Commands are data: each reaches the guards and the core as a JSON payload on
standard input, and the shells as an argument. No package manager runs.

--sets names corpora; --extra alone runs only the files it names; neither runs
every corpus. --list writes the selection and runs nothing. --reclassify
classifies a saved report again and runs no guard and no shell; a report of
the first schema is read with every axis it did not record as `unknown`.
--manifest writes one line for the run and one per row. --selftest checks the
observation and the statuses against cases each of which an earlier version
of this file got wrong.

Exit: 0 only when every row is `same`, or a named difference the shells show
to hold (or one where nothing runs on the core's side); 1 otherwise. A row
undecided on both sides, any `decrease:` row and any row not observed are red.
--control and --selftest have their own.

Usage:
  core-inert-differential.py --core <safedeps-core> [--jobs 1] [--sets a,b]
      [--extra name=FILE.jsonl ...] [--shells | --evidence] [--floor]
      [--release-tree DIR --approve eco:name:version ...] [--path-prefix DIRS]
      [--limit N] [--report FILE] [--table FILE] [--manifest FILE]
      [--list FILE] [--control]
  core-inert-differential.py --reclassify REPORT [--path-prefix DIRS]
      [--report FILE] [--table FILE] [--manifest FILE]
  core-inert-differential.py --selftest [--path-prefix DIRS]
"""
import argparse
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

SCHEMA = 2
UNKNOWN = "unknown"
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
GUARD = os.path.join(ROOT, "scripts", "safedeps-pre-guard.sh")
MEASURE = os.path.join(ROOT, "scripts", "measure")
TEST = os.path.join(ROOT, "scripts", "test")
FLAG = b" --ignore-scripts"
FLAGWORD = "--ignore-scripts"
NOTES = ("asked", "unverified", "floor", "unread", "release")
SHELLS = ("bash", "zsh", "dash", "zsh-agent")

DUMP = r'''
# --- core-inert-differential: the inert value of every reading, as records ---
if [[ -n "${SAFEDEPS_CORE_DUMP:-}" ]]; then
  sd_inert_put() { local LC_ALL=C; printf '%s %d\n%s\n' "$1" "${#2}" "$2" >> "${SAFEDEPS_CORE_DUMP}"; }
  for sd_inert_r in ${GUARD_READING_SET}; do
    SAFEDEPS_READING="${sd_inert_r}"
    [[ "${GUARD_IS_CODEX}" == true ]] || guard_reading_inert "${sd_inert_r}"
  done
  SAFEDEPS_READING=""
  if [[ "${GUARD_READING_SET}" == bash ]] && guard_readings_diverge; then guard_mark_reading_failed; fi
  sd_inert_put reading_set "${GUARD_READING_SET}"
  sd_inert_put any_install true
  for sd_inert_r in ${GUARD_READING_SET}; do
    sd_inert_v="GUARD_INERT_${sd_inert_r}"
    sd_inert_put "inert.${sd_inert_r}" "${!sd_inert_v}"
  done
  if guard_scan_failed; then sd_inert_put failed true; else sd_inert_put failed false; fi
  exit 0
fi
'''

ANCHOR = '# --- Reorg Guard Activated ---\n'

# The pre-guard's inert records in advisory.log (scripts/measure/inert-record-invariant.sh).
INERT_RECORD_RE = re.compile(
    r'pre-guard: (could not make every npm install in this command inert|an npm install in this command has no place where safedeps could read'
    r'|could not place --ignore-scripts by reading|an npm install in this command holds a word the shell decides'
    r'|an npm install in this command is in text safedeps could not read|text of this command that safedeps did not read as a command)')

# The stand-ins. Each call is one record of the log: the program's name, how
# many arguments it got, and each argument, every field ended by a NUL, written
# by one printf. No byte an argument can hold is a separator.
STUB_NPM = '#!/bin/sh\nprintf \'%s\\0\' npm "$#" "$@" >> "$NPMLOG"\n'
STUB_OTHER = '#!/bin/sh\nprintf \'%s\\0\' "${0##*/}" "$#" "$@" >> "$NPMLOG"\n'
# npx is written down as itself, and hands on to the stand-in npm only where
# the command it runs is npm.
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

# The gate's own reading of npm's arguments, one argv a call, every field
# ended by a NUL: `unread`, or `read`, the last value ignore-scripts takes,
# then the positional words, the other switches and the option values, each
# list behind its length. An option value is kept without the place it stood
# at, as the gate's own inert reading keeps it (INERT_READ_REST): an inserted
# flag moves every place after it, and nothing npm reads with it.
GATE_READER = r'''
set -u
source "$1/lib/install-grammar.sh" || exit 3
shift
emit() { printf '%s\0' "$#" "$@"; }
safedeps_npm_read_args "$@" || { printf 'unread\0'; exit 0; }
last=unset
sw=()
for w in "${SAFEDEPS_G_NPM_SWITCHES[@]+"${SAFEDEPS_G_NPM_SWITCHES[@]}"}"; do
  if [[ "${w}" == ignore-scripts=* ]]; then last="${w#*=}"; else sw+=("${w}"); fi
done
printf 'read\0%s\0' "${last}"
emit "${SAFEDEPS_G_NPM_WORDS[@]+"${SAFEDEPS_G_NPM_WORDS[@]}"}"
emit "${sw[@]+"${sw[@]}"}"
vals=()
for w in "${SAFEDEPS_G_NPM_VALUES[@]+"${SAFEDEPS_G_NPM_VALUES[@]}"}"; do vals+=("${w#*$'\037'}"); done
emit "${vals[@]+"${vals[@]}"}"
'''

# npm's own reading of the same argvs: nopt with npm's option definitions,
# resolved from npm's install as scripts/measure/npm-option-reading.sh does,
# and npm's own command table for the canonical command. npm does not run.
NPM_READER = r'''
const path = require("path")
const fs = require("fs")
const from = { paths: [path.resolve(".")] }
let defs, nopt
try {
  defs = require(require.resolve("@npmcli/config/lib/definitions", from))
  nopt = require(require.resolve("nopt", from))
} catch (e) { process.exit(3) }
const { definitions, shorthands } = defs
if (!definitions || !shorthands) process.exit(3)
const types = {}
for (const [k, d] of Object.entries(definitions)) types[k] = d.type
let deref = null
try { deref = require(path.resolve("lib/utils/cmd-list.js")).deref } catch (e) {}
const rows = JSON.parse(fs.readFileSync(process.argv[1], "utf8"))
const out = rows.map(a => {
  const r = nopt(types, shorthands, ["node", "npm", ...a], 2)
  const cmd = r.argv.remain.length ? r.argv.remain[0] : null
  let canon = null
  try { if (deref && cmd !== null) canon = deref(cmd) || null } catch (e) {}
  const v = r["ignore-scripts"]
  return { remain: r.argv.remain, ignore: v === undefined ? "unset" : String(v), canon }
})
fs.writeFileSync(process.argv[2], JSON.stringify(out))
'''
# The commands npm's own table names for the gate's install and link verbs.
CANON_INSTALL = ("install", "ci", "install-test", "install-ci-test", "update", "link")


def sha256(b):
    return hashlib.sha256(b).hexdigest()


def cmd_bytes(cmd):
    return cmd.encode("utf-8", "surrogateescape")


def load_facts_corpora():
    spec = importlib.util.spec_from_file_location("core_facts_differential", os.path.join(MEASURE, "core-facts-differential.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.corpora


def grid_forms(work):
    d = os.path.join(work, "grid-forms")
    r = subprocess.run(["bash", os.path.join(MEASURE, "inert-downgrade-grid.sh"), "--forms-only", d], capture_output=True)
    if r.returncode != 0 or not os.path.isdir(d):
        return []
    out = []
    for f in sorted(os.listdir(d)):
        if f.endswith(".cmd"):
            out.append(open(os.path.join(d, f), "rb").read().decode("utf-8", "surrogateescape"))
    return out


def parse_records(b):
    recs = {}
    p = 0
    while p < len(b):
        nl = b.index(b"\n", p)
        k, n = b[p:nl].decode("latin-1").rsplit(" ", 1)
        n = int(n)
        recs[k] = b[nl + 1:nl + 1 + n]
        p = nl + 1 + n + 1
    return recs


def payload(cmd, cwd, tid=None):
    d = {"tool_name": "Bash", "tool_input": {"command": cmd}, "cwd": cwd}
    if tid:
        d.update({"tool_use_id": tid, "session_id": "inert-diff", "hook_event_name": "PreToolUse"})
    return json.dumps(d).encode()


def flag_positions(cmd, rw):
    """The offsets after which FLAG was inserted into cmd to give rw, the
    command's own bytes taken first where both read the same; None when rw
    is no such insertion."""
    L = len(FLAG)
    n = len(cmd)
    if len(rw) < n or (len(rw) - n) % L:
        return None
    left = (len(rw) - n) // L
    i = j = 0
    pos = []
    while j < len(rw):
        if left and rw.startswith(FLAG, j) and not (i < n and cmd.startswith(FLAG, i)):
            pos.append(i)
            j += L
            left -= 1
            continue
        if i < n and rw[j] == cmd[i]:
            i += 1
            j += 1
            continue
        if left and rw.startswith(FLAG, j):
            pos.append(i)
            j += L
            left -= 1
            continue
        return None
    return pos if i == n and left == 0 else None


def outcome(v, cmd):
    """(kind, notes, command that runs, flag positions) of a GUARD_INERT value."""
    if v is None:
        return None
    head, _, rest = v.partition(b"\n")
    words = head.decode("latin-1").split()
    kind = words[0] if words else ""
    notes = set(words[1:])
    if kind == "rewrite":
        return kind, notes, rest, flag_positions(cmd, rest)
    return kind, notes, cmd, []


def records_of(o):
    """The inert records a value writes: what advisory.log says of an npm
    install that may run without the flag. `asked` is not one (the flag was
    placed after it)."""
    kind, notes, _, _ = o
    r = set(n for n in notes if n in NOTES and n != "asked")
    if kind == "downgrade":
        r.add("downgrade")
    return r


def readings(recs):
    """The reading set and each reading's value, as the records hold them."""
    rs = recs.get("reading_set", b"").decode().split()
    return rs, [recs.get("inert." + r) for r in rs]


def consensus(recs, cmd):
    """The value every reading agrees on, 'deny' where they differ, None where
    a reading has none."""
    rs, vals = readings(recs)
    if not vals or any(v is None for v in vals):
        return None
    if any(v != vals[0] for v in vals):
        return "deny"
    return outcome(vals[0], cmd)


def tokens(bo, co):
    """Direction tokens of one reading's difference."""
    t = set()
    bf = set(bo[3]) if bo[3] is not None else None
    cf = set(co[3]) if co[3] is not None else None
    if bf is None or cf is None:
        t.add("?flag")
    else:
        if cf - bf:
            t.add("+flag")
        if bf - cf:
            t.add("-flag")
    br, cr = records_of(bo), records_of(co)
    # A record is lost only where the bash guard writes one and the core none;
    # which record stands is listed beside it.
    if br and not cr:
        t.add("-rec")
    elif cr and not br:
        t.add("+rec")
    for r in cr - br:
        t.add("~rec+" + r)
    for r in br - cr:
        t.add("~rec-" + r)
    if ("asked" in bo[1]) != ("asked" in co[1]):
        t.add("~asked")
    if bo[0] != co[0]:
        t.add("~kind:%s>%s" % (bo[0], co[0]))
    return t


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
        self.shells = [s for s in ("/bin/bash", "/bin/zsh", "/bin/dash", "/usr/bin/zsh", "/usr/bin/dash") if os.access(s, os.X_OK)]
        seen = set()
        self.shells = [s for s in self.shells if not (os.path.basename(s) in seen or seen.add(os.path.basename(s)))]
        self.info = {"stubs": {n: sha256(t.encode()) for n, t in sorted(texts.items())}, "shells": {},
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

    def observe(self, cmd, box, files=()):
        """One run of `cmd` per shell, each in a fresh directory that holds an
        empty `d/` and the files named. Per shell: the exit status, whether the
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
            env = {"HOME": c, "ZDOTDIR": c, "PATH": self.stub + ":/usr/bin:/bin", "NPMLOG": log, "SD_INERT_CMD": cmd}
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


def _grammar_value(name):
    for line in open(os.path.join(ROOT, "lib", "install-grammar.sh"), encoding="utf-8"):
        if line.startswith(name + "='"):
            return line[len(name) + 2:line.rindex("'")]
    raise SystemExit("core-inert-differential: %s is not in lib/install-grammar.sh" % name)


INSTALL_VERB = re.compile("^(%s|%s)$" % (_grammar_value("SAFEDEPS_G_NPM_VERBS"), _grammar_value("SAFEDEPS_G_NPM_LINK_VERBS")), re.I)


class Readers:
    """What npm makes of an argv, asked of the gate's reader and of npm's own
    parser. Each answer is kept per argv; `None` is a reader that could not
    be asked or did not answer."""

    def __init__(self, work, path):
        self.work = work
        self.path = path
        self.gate = {}
        self.npm = {}
        self.script = os.path.join(work, "gate-read.sh")
        open(self.script, "w").write(GATE_READER)
        self.node = shutil.which("node", path=path)
        npm = shutil.which("npm", path=path)
        self.npm_root = os.path.dirname(os.path.dirname(os.path.realpath(npm))) if npm else None
        self.npm_version = ""
        self.npm_asked = False
        self.npm_error = "" if (self.node and self.npm_root) else "no node or no npm on the PATH given"
        if self.npm_root:
            try:
                self.npm_version = json.load(open(os.path.join(self.npm_root, "package.json"), encoding="utf-8")).get("version", "")
            except (OSError, ValueError):
                self.npm_version = ""

    def _gate(self, argv):
        try:
            r = subprocess.run(["bash", self.script, ROOT] + [a.encode("latin-1") for a in argv], capture_output=True, timeout=30)
        except (OSError, subprocess.SubprocessError, ValueError):
            return None
        if r.returncode != 0 or not r.stdout.endswith(b"\0"):
            return None
        t = [x.decode("latin-1") for x in r.stdout[:-1].split(b"\0")]
        if t == ["unread"]:
            return {"read": False}
        try:
            if t[0] != "read":
                return None
            last, i, lists = t[1], 2, []
            for _ in range(3):
                n = int(t[i])
                lists.append(t[i + 1:i + 1 + n])
                i += 1 + n
            if i != len(t):
                return None
        except (IndexError, ValueError):
            return None
        return {"read": True, "ignore": last, "words": lists[0], "switches": lists[1], "values": lists[2]}

    def ask(self, argvs):
        """Reads every argv not yet read."""
        distinct = set(tuple(x) for x in argvs)
        for a in sorted(distinct):
            if a not in self.gate:
                self.gate[a] = self._gate(list(a))
        todo = sorted(a for a in distinct if a not in self.npm)
        if not todo:
            return
        answers = None
        if self.node and self.npm_root:
            fin = os.path.join(self.work, "npm-read.in.json")
            fout = os.path.join(self.work, "npm-read.out.json")
            json.dump([list(a) for a in todo], open(fin, "w"))
            try:
                if os.path.exists(fout):
                    os.unlink(fout)
                r = subprocess.run([self.node, "-e", NPM_READER, fin, fout], cwd=self.npm_root, capture_output=True, timeout=600,
                                   env={"PATH": self.path, "HOME": self.work})
                if r.returncode == 0 and os.path.exists(fout):
                    answers = json.load(open(fout))
                    self.npm_asked = True
                else:
                    self.npm_error = "node exited %s: %s" % (r.returncode, r.stderr[:200].decode("latin-1"))
            except (OSError, subprocess.SubprocessError, ValueError) as e:
                self.npm_error = str(e)[:200]
        for k, a in enumerate(todo):
            self.npm[a] = answers[k] if answers is not None and k < len(answers) else None

    def install(self, argv):
        """Whether the call's command is an install or link verb: True or
        False where both readers say so, None where one could not answer or
        the two disagree."""
        g, n = self.gate.get(tuple(argv)), self.npm.get(tuple(argv))
        if g is None or n is None or not g.get("read"):
            return None
        gw = g["words"][0] if g["words"] else None
        gi = bool(gw is not None and INSTALL_VERB.match(gw))
        nw = n["remain"][0] if n.get("remain") else None
        if n.get("canon") is not None:
            ni = n["canon"] in CANON_INSTALL
        else:
            ni = bool(nw is not None and INSTALL_VERB.match(nw))
        if gw != nw or gi != ni:
            return None
        return gi

    def flagged(self, argv):
        """Whether ignore-scripts ends true: both readers' answer, or None."""
        g, n = self.gate.get(tuple(argv)), self.npm.get(tuple(argv))
        if g is None or n is None or not g.get("read"):
            return None
        gt, nt = g["ignore"] == "true", n["ignore"] == "true"
        return gt if gt == nt else None

    def rest(self, argv):
        """Everything the readers found but ignore-scripts: two argvs with the
        same rest differ at most in that option. None where a reader did not
        answer."""
        g, n = self.gate.get(tuple(argv)), self.npm.get(tuple(argv))
        if g is None or n is None or not g.get("read"):
            return None
        return (tuple(g["words"]), tuple(g["switches"]), tuple(g["values"]), tuple(n["remain"]))

    def answers(self):
        """Every argv asked, with what each reader said, for the report."""
        return [{"argv": list(a), "gate": self.gate.get(a), "npm": self.npm.get(a),
                 "install": self.install(list(a)), "flagged": self.flagged(list(a))} for a in sorted(self.gate)]


class NoReaders:
    """Stands where no reader was asked: every answer is unknown."""
    npm_asked = False
    npm_error = "no reader asked"
    npm_version = ""

    def ask(self, argvs):
        pass

    def install(self, argv):
        return None

    def flagged(self, argv):
        return None

    def rest(self, argv):
        return None

    def answers(self):
        return []


def whole(obs):
    """A run observed whole: it ended by itself, its log decodes, and its
    exit status is its own."""
    return calls_known(obs) and obs.get("rc") not in (UNKNOWN, "timeout")


def calls_known(obs):
    """The npm calls of a run are known: its log decodes and it ended by
    itself, whatever else of it was recorded."""
    return (isinstance(obs, dict) and obs.get("log") == "ok" and isinstance(obs.get("npm"), list)
            and not obs.get("timeout") and obs.get("rc") != "timeout" and not obs.get("lossy"))


def install_calls(obs, R):
    """The install calls of a run, or None where a call's command is not
    known."""
    inst = []
    for c in obs["npm"]:
        i = R.install(c)
        if i is None:
            return None
        if i:
            inst.append(c)
    return inst


def state(obs, recorded, R):
    """A side's state in one shell."""
    if not calls_known(obs):
        return "UNKNOWN"
    inst = install_calls(obs, R)
    if inst is None:
        return "UNKNOWN"
    if not inst:
        return "NOCALL"
    fl = [R.flagged(c) for c in inst]
    if any(f is None for f in fl):
        return "UNKNOWN"
    if all(fl):
        return "FLAG"
    return "REC" if recorded else "SILENT"


def state_words(obs, recorded, R):
    """The same by the flag words alone, as inert-record-invariant.sh reads a
    call: `--ignore-scripts` or `=true` sets it, `=false` or `--no-` clears
    it, and a `--` ends the options."""
    if not calls_known(obs):
        return "UNKNOWN"
    inst = install_calls(obs, R)
    if inst is None:
        return "UNKNOWN"
    if not inst:
        return "NOCALL"

    def unflagged(argv):
        v = False
        for a in argv:
            if a == "--":
                break
            if a in ("--ignore-scripts", "--ignore-scripts=true"):
                v = True
            elif a in ("--ignore-scripts=false", "--no-ignore-scripts"):
                v = False
        return not v
    if not any(unflagged(c) for c in inst):
        return "FLAG"
    return "REC" if recorded else "SILENT"


def flag_edit(w, s):
    """How argv `s` comes from argv `w` by inserting `--ignore-scripts` words
    and nothing else: the indices in `s` of the inserted words, or None when
    `s` is no such edit. An argument of `w`, a `--ignore-scripts` of its own
    included, is never dropped to make the two compare."""
    ins = []
    i = 0
    for j, a in enumerate(s):
        if i < len(w) and a == w[i]:
            i += 1
        elif a == FLAGWORD:
            ins.append(j)
        else:
            return None
    return ins if i == len(w) else None


def relate(w, s, R):
    """How a side's run relates to the run of the command as written, in one
    shell. `npm` is `unknown` (a run's calls are not known), `identical`,
    `flags-added`, `call-lost`, `call-added`, `argument-changed`,
    `flag-unconsumed` (an inserted flag stands after a `--`, or npm does not
    read it as a true option, or it changes something else npm reads) or
    `reading-unknown` (a reader did not answer). The other axes are `same`,
    `differ` or `unknown`."""
    out = {"npm": UNKNOWN}
    if calls_known(w) and calls_known(s):
        wn, sn = w["npm"], s["npm"]
        if len(sn) < len(wn):
            out["npm"] = "call-lost"
        elif len(sn) > len(wn):
            out["npm"] = "call-added"
        else:
            kind = "identical"
            for a, b in zip(wn, sn):
                ins = flag_edit(a, b)
                if ins is None:
                    kind = "argument-changed"
                    break
                if not ins:
                    continue
                if kind == "identical":
                    kind = "flags-added"
                dashes = b.index("--") if "--" in b else len(b)
                if any(k > dashes for k in ins):
                    kind = "flag-unconsumed"
                    break
                ra, rb, fb = R.rest(a), R.rest(b), R.flagged(b)
                if ra is None or rb is None or fb is None:
                    kind = "reading-unknown"
                elif ra != rb or not fb:
                    kind = "flag-unconsumed"
                    break
            out["npm"] = kind
    for axis in ("rc", "stdout_sha256", "stderr_sha256", "other", "files"):
        a = w.get(axis, UNKNOWN) if isinstance(w, dict) else UNKNOWN
        b = s.get(axis, UNKNOWN) if isinstance(s, dict) else UNKNOWN
        name = axis.replace("_sha256", "")
        if a == UNKNOWN or b == UNKNOWN or a == "timeout" or b == "timeout":
            out[name] = UNKNOWN
        else:
            out[name] = "same" if a == b else "differ"
    return out


def side_verdict(res, side, R):
    """What the shells show of a side beside the command as written:

      npm      `deny` (the side sends no command), `unknown`, `loss` (a call
               gone or added, an argument changed, a flag that is no option
               to npm, or a SILENT state), `nocall` (no shell made an install
               call), or `ok`
      effects  `same`, `differ:<axes>` or `unknown`, over the exit status,
               stdout, stderr, the other stand-ins' calls and the files left
      shells   per shell, the relation and the states
    """
    sides = res.get("sides", {})
    w, s = sides.get("written", {}), sides.get(side, {})
    v = {"npm": UNKNOWN, "effects": UNKNOWN, "shells": {}}
    if s.get("decision") == "deny":
        v["npm"] = v["effects"] = "deny"
        return v
    ws, ss = w.get("shells"), s.get("shells")
    if not isinstance(ws, dict) or not isinstance(ss, dict):
        return v
    rec = bool(s.get("record"))
    unknown = bad = eff_unknown = False
    installs = 0
    differ = set()
    for sh in SHELLS:
        if sh not in ws or sh not in ss:
            v["shells"][sh] = {"npm": "missing", "state": "UNKNOWN"}
            unknown = True
            continue
        r = relate(ws[sh], ss[sh], R)
        r["state"] = state(ss[sh], rec, R)
        r["written_state"] = state(ws[sh], False, R)
        v["shells"][sh] = r
        if r["npm"] in (UNKNOWN, "reading-unknown") or r["state"] == "UNKNOWN" or r["written_state"] == "UNKNOWN":
            unknown = True
        if r["npm"] in ("call-lost", "call-added", "argument-changed", "flag-unconsumed") or r["state"] == "SILENT":
            bad = True
        if r["state"] in ("FLAG", "REC", "SILENT"):
            installs += 1
        for axis in ("rc", "stdout", "stderr", "other", "files"):
            if r[axis] == "differ":
                differ.add(axis)
            elif r[axis] == UNKNOWN:
                eff_unknown = True
    v["npm"] = "loss" if bad else UNKNOWN if unknown else "ok" if installs else "nocall"
    v["effects"] = "differ:" + ",".join(sorted(differ)) if differ else UNKNOWN if eff_unknown else "same"
    return v


def npm_calls_identical(res, a, b):
    """The two sides make the same npm calls in every shell, argv for argv.
    None where a run's calls are not known."""
    sa, sb = res.get("sides", {}).get(a, {}).get("shells"), res.get("sides", {}).get(b, {}).get("shells")
    if not isinstance(sa, dict) or not isinstance(sb, dict):
        return None
    for sh in SHELLS:
        if sh not in sa or sh not in sb or not calls_known(sa[sh]) or not calls_known(sb[sh]):
            return None
    return all(sa[sh]["npm"] == sb[sh]["npm"] for sh in SHELLS)


def worse_than_bash(res):
    """In some shell the core's state is worse than the bash side's (a call
    without the flag where the bash side's reads true, or no record where it
    has one): True, False, or None where a state is not known."""
    obs = res.get("obs", {})
    c, b = obs.get("core"), obs.get("bash")
    if not c or not b or b["npm"] == "deny" or c["npm"] == "deny":
        return None
    rank = {"NOCALL": 0, "FLAG": 0, "REC": 1, "SILENT": 2}
    worse = False
    for sh in SHELLS:
        cs, bs = c["shells"].get(sh, {}).get("state", "UNKNOWN"), b["shells"].get(sh, {}).get("state", "UNKNOWN")
        if cs not in rank or bs not in rank:
            return None
        if rank[cs] > rank[bs]:
            worse = True
    return worse


def subseq(head, release, command):
    """release-floor.sh: head and release are command with FLAG inserted at
    places, the release's inserts some of the head's."""
    sys.setrecursionlimit(100000)
    from functools import lru_cache

    @lru_cache(maxsize=None)
    def go(i, j, k):
        if i == len(head) and j == len(release) and k == len(command):
            return True
        if head.startswith(FLAG, i):
            if release.startswith(FLAG, j) and go(i + len(FLAG), j + len(FLAG), k):
                return True
            if go(i + len(FLAG), j, k):
                return True
        if i < len(head) and j < len(release) and k < len(command) and head[i] == release[j] == command[k] and go(i + 1, j + 1, k + 1):
            return True
        return False
    return go(0, 0, 0)


ARGUMENT_SUBSTITUTION_INPUT = 'npm install left-pad@1.3.0 eval "$(echo) npm"'

# Matched by their conditions here, never by their line's tokens and pattern.
CODE_CHECKED = ("argument-substitution-preserved",)


def substitution_bodies(cmd):
    """The (start, end) offsets of each `$(...)` body of a command, by
    counting parentheses: a check of the classifier, not a reader."""
    out = []
    i = 0
    while i < len(cmd):
        if cmd.startswith("$(", i) and not cmd.startswith("$((", i):
            depth, j = 1, i + 2
            while j < len(cmd) and depth:
                depth += {"(": 1, ")": -1}.get(cmd[j], 0)
                j += 1
            out.append((i + 2, j - 1))
            i += 2
            continue
        i += 1
    return out


def argument_substitution_preserved(res):
    """The one difference adopted as argument-substitution-preserved
    (plan safedeps/guard-core-inert, 2026-10-07): every condition holds, or
    the first that does not."""
    cmd = res["command"]
    if cmd != ARGUMENT_SUBSTITUTION_INPUT:
        return "not the input"
    if res.get("floor") != "ok":
        return "the release floor is not shown kept (run with --floor)"
    cb = cmd.encode()
    bodies = substitution_bodies(cmd)
    for r in res["ref"].get("reading_set", "").split():
        bo = outcome(res["ref"].get("inert." + r, "").encode("latin-1"), cb)
        co = outcome(res["core"].get("inert." + r, "").encode("latin-1"), cb)
        if bo is None or co is None or bo[3] is None or co[3] is None:
            return "a reading has no value"
        missing = set(bo[3]) - set(co[3])
        if len(missing) != 1:
            return "%s: %d bash flags are missing, not one" % (r, len(missing))
        p = missing.pop()
        body = [(a, z) for (a, z) in bodies if a <= p <= z]
        if not body or "npm" in cmd[body[0][0]:body[0][1]].lower():
            return "%s: the missing flag is not in a substitution body without npm" % r
        if not records_of(co) >= (records_of(bo) & {"unread", "unverified"}):
            return "%s: a record of the bash rewrite is missing" % r
    cv = res.get("obs", {}).get("core")
    if not cv or cv["npm"] != "ok":
        return "the shells do not show the core's npm calls to be the command's as written with flags added (%s)" % (cv["npm"] if cv else "not observed")
    v = res.get("sides", {}).get("v2.18.1", {})
    if v.get("flags") is None:
        return "no v2.18.1 side that runs (run with --release-tree, --path-prefix and --approve)"
    co_flags = set(outcome(res["core"].get("inert." + res["ref"]["reading_set"].split()[0], "").encode("latin-1"), cb)[3])
    if not set(v["flags"]) <= co_flags:
        return "a v2.18.1 flag is missing in the core's rewrite"
    if v.get("record") and not any(records_of(outcome(res["core"].get("inert." + r, "").encode("latin-1"), cb))
                                   for r in res["ref"]["reading_set"].split()):
        return "v2.18.1 records and the core does not"
    return None


def word_value_label(res):
    """An observation, not a class: every flag the core adds stands at the
    verb or the place of an install its reader found (a statement whose
    command word is npm) that the bash rewrite's search did not find (no
    `pair` line of the detail names its `npm`), and the shells show the
    core's npm calls to hold. True where all of that holds. The detail is the
    core's own account; the shells are what makes this an observation."""
    cb = cmd_bytes(res["command"])
    cv = res.get("obs", {}).get("core")
    if not cv or cv["npm"] != "ok":
        return False
    added_any = False
    for r in res["ref"].get("reading_set", "").split():
        d = res["core"].get("detail." + r)
        bo = outcome(res["ref"].get("inert." + r, "").encode("latin-1"), cb)
        co = outcome(res["core"].get("inert." + r, "").encode("latin-1"), cb)
        if d is None or bo is None or co is None or bo[3] is None or co[3] is None:
            return False
        lines = [l.split() for l in d.split("\n") if l.strip()]
        paired = set(f[1] for f in lines if f[0] == "pair")
        places = set()
        for f in lines:
            if f[0] == "install" and len(f) >= 6 and f[2] not in paired:
                places.update(int(x) for x in (f[4], f[5]) if x != "-")
        added = set(co[3]) - set(bo[3])
        if not added <= places:
            return False
        added_any = added_any or bool(added)
    return added_any


def fill_records(res):
    """Whether each of the two sides records, from its own value: a side that
    runs a command records where its value carries a record."""
    cb = cmd_bytes(res["command"])
    for side, key in (("bash", "ref"), ("core", "core")):
        v = res.get("sides", {}).get(side)
        if not isinstance(v, dict) or v.get("decision") == "deny" or "record" in v:
            continue
        o = consensus({k: x.encode("latin-1") for k, x in res[key].items()}, cb)
        if o not in (None, "deny"):
            v["record"] = bool(records_of(o))


def upgrade(saved):
    """A report of the first schema, read as this one. It kept each side's npm
    calls split at tabs and newlines and, for the bash and core sides, nothing
    else; its `shells` beside the command as written came from one object two
    jobs shared, so no exit status in it belongs to a row for certain. Every
    such axis is `unknown` here, and a command that can hand npm a tab or a
    newline has its calls marked lossy."""
    if saved.get("schema") == SCHEMA:
        return saved
    risky = re.compile(r"[\t\n]|\\[tn]|\$'")
    for res in saved["rows"]:
        lossy = bool(risky.search(res["command"]))
        for k in ("status", "tokens", "payload_free", "payload_free_basis", "class_refused", "core_readings", "readings_differ", "reach"):
            res.pop(k, None)
        for side, v in res.get("sides", {}).items():
            calls = v.pop("calls", None)
            old_state = v.pop("state", None)
            v.pop("state_npm", None)
            meta = v.pop("shells", None)
            if old_state == "DENY":
                v["decision"] = "deny"
                continue
            v["decision"] = "run"
            if meta is not None:
                v["schema1_shells"] = meta
            if isinstance(calls, dict):
                v["shells"] = {sh: {"rc": UNKNOWN, "timeout": False, "log": "ok", "npm": cs, "calls": UNKNOWN, "other": UNKNOWN,
                                    "files": UNKNOWN, "stdout_sha256": UNKNOWN, "stderr_sha256": UNKNOWN, "lossy": lossy}
                               for sh, cs in calls.items()}
    saved["schema"] = SCHEMA
    saved["upgraded_from_schema"] = 1
    return saved


def load_classes():
    classes = []
    cpath = os.path.join(MEASURE, "core-intended-inert.tsv")
    if os.path.exists(cpath):
        for line in open(cpath, encoding="utf-8"):
            if not line.strip() or line.startswith("#"):
                continue
            cname, toks, free, pat, reason = line.rstrip("\n").split("\t")[:5]
            classes.append((cname, set(toks.split(",")), free == "yes", re.compile(pat, re.S), reason))
    return classes


def classify(results, classes, R):
    """Gives every row its one status. Returns the counts."""
    counts = {"total": len(results), "core_error": 0, "not_reached": 0, "compared": 0, "reading_set": 0, "incomplete": 0,
              "both_failed": 0, "both_undecided": 0, "same": 0, "differ": 0, "payload_free_differ": 0}
    per = {}

    def put(res, status):
        res["status"] = status
        per[status] = per.get(status, 0) + 1

    for res in results:
        cmd = res["command"]
        cb = cmd_bytes(cmd)
        ref = {k: v.encode("latin-1") for k, v in res["ref"].items()}
        got = {k: v.encode("latin-1") for k, v in res["core"].items()}
        for k in ("status", "tokens", "payload_free", "class_refused", "obs", "label", "readings_differ"):
            res.pop(k, None)
        if res["core_rc"] != 0:
            counts["core_error"] += 1
            put(res, "core-error")
            continue
        if not ref:
            counts["not_reached"] += 1
            put(res, "bash-not-reached")
            continue
        counts["compared"] += 1
        fill_records(res)
        res["obs"] = {s: side_verdict(res, s, R) for s in ("bash", "core", "v2.18.1") if s in res.get("sides", {})}
        if ref.get("reading_set") != got.get("reading_set"):
            counts["reading_set"] += 1
            put(res, "reading-set")
            continue
        rs, bvals = readings(ref)
        _, cvals = readings(got)
        if not rs or any(v is None for v in bvals) or any(v is None for v in cvals):
            counts["incomplete"] += 1
            put(res, "incomplete")
            continue
        bfail, cfail = ref.get("failed") == b"true", got.get("failed") == b"true"
        bden, cden = len(set(bvals)) > 1, len(set(cvals)) > 1
        res["readings_differ"] = {"bash": bden, "core": cden, "values_equal": bvals == cvals}
        toks = set()
        if cfail and not bfail:
            toks.add("+undecided")
        elif bfail and not cfail:
            toks.add("-undecided")
        if not (bfail and cfail):
            if cden and not bden:
                toks.add("+deny:readings-disagree")
            elif bden and not cden:
                toks.add("-deny")
            if not (cden and not bden):
                for r, bv, cv_ in zip(rs, bvals, cvals):
                    if bv != cv_:
                        toks |= tokens(outcome(bv, cb), outcome(cv_, cb))
        if toks:
            res["tokens"] = sorted(toks)
        # The failures and the disagreements come first: a row whose readings
        # fail or disagree on both sides is no agreement, whatever its bytes.
        if bfail and cfail:
            counts["both_failed"] += 1
            put(res, "both-failed")
            continue
        if bden and cden:
            counts["both_undecided"] += 1
            put(res, "both-undecided")
            continue
        if not toks:
            counts["same"] += 1
            put(res, "same")
            continue
        counts["differ"] += 1
        p3 = res.get("payloads3")
        p3_known = isinstance(p3, dict) and set(p3) == {"bash", "zsh", "dash"} and None not in p3.values()
        free = p3_known and all(v == 0 for v in p3.values())
        res["payload_free"] = free if p3_known else UNKNOWN
        if free:
            counts["payload_free_differ"] += 1
        cv = res["obs"].get("core")
        if cmd == ARGUMENT_SUBSTITUTION_INPUT:
            why = argument_substitution_preserved(res)
            if why is None:
                put(res, "class:argument-substitution-preserved")
                continue
            res["class_refused"] = why
        if any(t.startswith("-") or t.startswith("?") for t in toks):
            if cv is not None and cv["npm"] == "ok":
                # How the bash side compares, kept beside whatever status the
                # row gets: an observation, not a name.
                bv = res["obs"].get("bash")
                if npm_calls_identical(res, "bash", "core") and not any(t.startswith(("-rec", "-undecided")) for t in toks):
                    res["label"] = "argv-equal"
                elif bv is not None and bv["npm"] in ("loss", "nocall", "deny"):
                    res["label"] = "core-dominates"
                else:
                    res["label"] = "core-exact"
            worse = worse_than_bash(res)
            if "-deny" in toks:
                put(res, "decrease:minus-deny")
            elif cv is None or cv["npm"] == UNKNOWN:
                put(res, "decrease:unknown")
            elif worse is True:
                put(res, "decrease")
            elif cv["npm"] == "loss":
                put(res, "decrease:shared-loss" if npm_calls_identical(res, "bash", "core") else "decrease")
            elif cv["npm"] == "nocall":
                put(res, "decrease:nocall")
            elif worse is None:
                put(res, "decrease:unknown")
            elif cv["effects"] == UNKNOWN:
                put(res, "decrease:effects-unknown")
            elif cv["effects"] != "same":
                put(res, "decrease:effects-differ")
            else:
                put(res, "decrease:" + res["label"])
            continue
        cls = None
        dirs = set(t for t in toks if not t.startswith("~"))
        for (cname, ctoks, cfree, pat, reason) in classes:
            if cname in CODE_CHECKED:
                continue
            # A row with no direction (its records differ in kind alone) is
            # named only by a class that lists `~kind`: an empty set of
            # directions is a subset of every class's, and a pattern that
            # matches every command then named such a row.
            if not dirs:
                if "~kind" not in ctoks:
                    continue
            elif not dirs <= ctoks:
                continue
            # A class that may not stand on a text with no payload needs the
            # three readings' payload counts, each known and not all zero.
            if not cfree and (free or not p3_known):
                continue
            if pat.search(cmd):
                cls = cname
                break
        if cls is None and dirs and dirs <= {"+flag", "+rec"} and word_value_label(res):
            res["label"] = "word-value-read"
        put(res, "unclassified" if cls is None else "class:" + cls)
    counts["status"] = per
    return counts


def summarize(results, counts, R, a, extra):
    """The states, the losses and the checks beside the statuses. Returns the
    summary and whether the run is red."""
    out = {"counts": counts}
    silent, silent_words, only_silent, loss, loss_words, loss_unknown, state_unknown = [], [], [], [], [], [], 0
    for res in results:
        st = {}
        for side, v in res.get("sides", {}).items():
            if side == "written" or not isinstance(v.get("shells"), dict):
                continue
            rec = bool(v.get("record"))
            v["state"] = {sh: state(o, rec, R) for sh, o in v["shells"].items()}
            v["state_words"] = {sh: state_words(o, rec, R) for sh, o in v["shells"].items()}
            st[side] = v
        c, b, rel = st.get("core"), st.get("bash"), st.get("v2.18.1")
        if not c:
            continue
        if any(x == "UNKNOWN" for x in c["state"].values()):
            state_unknown += 1
        if any(x == "SILENT" for x in c["state"].values()):
            silent.append(res)
        if any(x == "SILENT" for x in c["state_words"].values()):
            silent_words.append(res)
        if any(x == "SILENT" and (not b or b["state"].get(sh) != "SILENT") for sh, x in c["state"].items()):
            only_silent.append(res)
        if rel:
            for key, bucket in (("state", loss), ("state_words", loss_words)):
                for sh, x in c[key].items():
                    if x == "SILENT" and rel[key].get(sh, "UNKNOWN") not in ("SILENT", "UNKNOWN"):
                        bucket.append((res, sh, rel[key].get(sh)))
                        break
            if any(x == "UNKNOWN" or rel["state"].get(sh, "UNKNOWN") == "UNKNOWN" for sh, x in c["state"].items()):
                loss_unknown.append(res)
    # A SILENT row the head's whole pre-guard denies runs nothing: it is
    # listed, and it is not the invariant's failure. One it lets through, or
    # one it was not asked about, is.
    denied = [res for res in silent if res.get("sides", {}).get("head", {}).get("decision") == "deny"]
    silent_run = [res for res in silent if res not in denied]
    silent_words_run = [res for res in silent_words if res.get("sides", {}).get("head", {}).get("decision") != "deny"]
    out.update({"core_silent_denied_by_head": len(denied), "core_silent_let_through": len(silent_run)})
    out.update({"core_silent": len(silent), "core_silent_words": len(silent_words), "core_only_silent": len(only_silent),
                "loss": len(loss), "loss_words": len(loss_words), "loss_unknown": len(loss_unknown), "core_state_unknown": state_unknown})
    # The record invariant's reach (inert-record-invariant.sh): a form that
    # makes fewer npm calls on the core's side, in bash or zsh, than
    # inert-record-reach.tsv names never reached its npm and cannot fail.
    short, judged = [], 0
    reach = extra.get("reach") or {}
    for res in results:
        if res["command"] not in reach:
            continue
        sh = res.get("sides", {}).get("core", {}).get("shells")
        if not isinstance(sh, dict) or not all(calls_known(sh.get(x)) for x in ("bash", "zsh")):
            continue
        made = max(len(sh["bash"]["npm"]), len(sh["zsh"]["npm"]))
        fid, need = reach[res["command"]]
        res["reach"] = "%s %d/%d" % (fid, made, need)
        judged += 1
        if made < need:
            short.append(res)
    floor = {}
    for res in results:
        if "floor" in res:
            floor[res["floor"]] = floor.get(res["floor"], 0) + 1
    # A named difference holds only where the shells show the core's npm calls
    # to be the command's as written with flags added, or where nothing runs
    # on the core's side (its readings disagree).
    class_obs = {}
    for res in results:
        s = res.get("status", "")
        if s.startswith("class:"):
            cv = res.get("obs", {}).get("core")
            k = cv["npm"] + "/" + cv["effects"].split(":")[0] if cv else "not-observed"
            class_obs.setdefault(s, {})
            class_obs[s][k] = class_obs[s].get(k, 0) + 1
    labels = {}
    for res in results:
        if res.get("label"):
            k = "%s (%s)" % (res["label"], res.get("status"))
            labels[k] = labels.get(k, 0) + 1
    out.update({"reach_judged": judged, "reach_short": len(short), "floor": floor, "class_observation": class_obs, "labels": labels})
    per = counts["status"]
    red = (counts["core_error"] + counts["reading_set"] + counts["incomplete"] + counts["both_failed"] + counts["both_undecided"]
           + sum(v for k, v in per.items() if k == "unclassified" or k.startswith("decrease"))
           + len(silent_run) + len(silent_words_run) + len(loss) + len(loss_words) + len(short)
           + sum(v for k, v in floor.items() if k.startswith("NOT")))
    for s, ks in class_obs.items():
        red += sum(v for k, v in ks.items() if k == "not-observed" or k.split("/")[0] in ("loss", UNKNOWN))
    out["red"] = red

    print("load start: %s" % extra.get("up0", ""))
    print("load end:   %s" % extra.get("up1", ""))
    for k in ("total", "core_error", "not_reached", "compared", "reading_set", "incomplete", "both_failed", "both_undecided", "same", "differ",
              "payload_free_differ"):
        print("%-22s %d" % (k, counts[k]))
    for k in sorted(per):
        print("  status %-34s %d" % (k, per[k]))
    for s in sorted(class_obs):
        print("  observed %-40s %s" % (s, ", ".join("%s %d" % kv for kv in sorted(class_obs[s].items()))))
    for k in sorted(labels):
        print("  label %-50s %d" % (k, labels[k]))
    if a.floor:
        print("release floor: %s" % ", ".join("%s %d" % (k, v) for k, v in sorted(floor.items())))
    print("npm's own parser: %s" % ("asked (npm %s)" % R.npm_version if R.npm_asked else "not asked: %s" % R.npm_error))
    print("core SILENT (both readers): %d, of which the head's whole pre-guard denies %d and lets through or was not asked %d; "
          "by the flag words: %d; core-only SILENT: %d; core states UNKNOWN: %d rows"
          % (len(silent), len(denied), len(silent_run), len(silent_words), len(only_silent), state_unknown))
    print("LOSS against v2.18.1 (both readers): %d; by the flag words: %d; not decidable (a state UNKNOWN): %d rows"
          % (len(loss), len(loss_words), len(loss_unknown)))
    if reach:
        print("reach: %d forms with a reach number judged, SHORT %d" % (judged, len(short)))
    for res in short[:20]:
        print("SHORT %s %r" % (res["reach"], res["command"]))
    for res, sh, rv in loss[:20]:
        print("LOSS %s %r shell=%s v2.18.1=%s" % (res["set"], res["command"], sh, rv))
    for res in silent[:20]:
        h = res["sides"].get("head", {})
        print("SILENT %s %r %s head: %s %s" % (res["set"], res["command"], res["sides"]["core"].get("state"), h.get("decision", "not asked"),
                                              h.get("reason", "")[:120]))
    shown = 0
    for res in results:
        s = res.get("status", "")
        if s in ("unclassified", "decrease", "decrease:unknown", "reading-set", "incomplete", "core-error") or str(res.get("floor", "")).startswith("NOT"):
            shown += 1
            if shown > 40:
                break
            print("%s %s %r tokens=%s free=%s%s%s" % (s, res["set"], res["command"], res.get("tokens"), res.get("payload_free"),
                                                     (" label=" + res["label"]) if res.get("label") else "",
                                                     (" refused: " + res["class_refused"]) if res.get("class_refused") else ""))
            for r in res["ref"].get("reading_set", "").split():
                print("   bash %-5s %r" % (r, res["ref"].get("inert." + r)))
                print("   core %-5s %r" % (r, res["core"].get("inert." + r)))
            cv = res.get("obs", {}).get("core")
            if cv:
                print("   core observed: npm %s, effects %s, %s" % (cv["npm"], cv["effects"], json.dumps(
                    {sh: [x.get("npm"), x.get("state")] for sh, x in cv["shells"].items()})))
    return out, bool(red)


def manifest(path, results, run):
    with open(path, "w", encoding="utf-8") as f:
        f.write(json.dumps({"run": run}, ensure_ascii=False) + "\n")
        for k, res in enumerate(results):
            row = {"row": k + 1, "set": res["set"], "command_sha256": sha256(cmd_bytes(res["command"])), "command": res["command"],
                   "status": res.get("status"), "label": res.get("label"), "tokens": res.get("tokens"),
                   "reading_set": res.get("ref", {}).get("reading_set"), "readings_differ": res.get("readings_differ"),
                   "payloads3": res.get("payloads3"), "payload_free": res.get("payload_free"), "floor": res.get("floor"),
                   "sides": {}}
            for side, v in res.get("sides", {}).items():
                s = {"decision": v.get("decision"), "record": v.get("record"), "state": v.get("state"), "state_words": v.get("state_words")}
                if isinstance(v.get("shells"), dict):
                    s["shells"] = {sh: {"rc": o.get("rc"), "timeout": o.get("timeout"), "log": o.get("log"),
                                        "npm_calls": len(o["npm"]) if isinstance(o.get("npm"), list) else UNKNOWN,
                                        "other_calls": len(o["other"]) if isinstance(o.get("other"), list) else UNKNOWN,
                                        "files": len(o["files"]) if isinstance(o.get("files"), dict) else UNKNOWN}
                                   for sh, o in v["shells"].items()}
                row["sides"][side] = s
            if res.get("obs"):
                row["observed"] = {s: {"npm": v["npm"], "effects": v["effects"]} for s, v in res["obs"].items()}
            f.write(json.dumps(row, ensure_ascii=False) + "\n")


def selftest(a):
    """Each case is one an earlier version of this file got wrong. Prints
    `ok` or `not ok` per case; exit 1 on any `not ok`."""
    work = tempfile.mkdtemp(prefix="safedeps-core-inert-selftest.")
    bad = 0

    def check(name, got, want):
        nonlocal bad
        ok = got == want
        bad += 0 if ok else 1
        print("%s %s%s" % ("ok" if ok else "not ok", name, "" if ok else " (got %r, want %r)" % (got, want)))

    path = ":".join(d for d in ("/usr/bin", "/bin", "/usr/sbin", "/sbin") if os.path.isdir(d))
    if a.path_prefix:
        path = ":".join(os.path.expanduser(x) for x in a.path_prefix.split(":") if x) + ":" + path
    shells = Shells(work)
    R = Readers(work, path)

    def obs(npm, **kw):
        o = {"rc": 0, "timeout": False, "log": "ok", "npm": npm, "calls": [["npm"] + c for c in npm], "other": [], "files": {"d": ["d"]},
             "stdout_sha256": "x", "stderr_sha256": "x"}
        o.update(kw)
        return o

    def row(written, core, bash=None):
        res = {"set": "selftest", "command": "selftest", "core_rc": 0, "payloads3": {"bash": 1, "zsh": 1, "dash": 1},
               "ref": {"reading_set": "bash", "inert.bash": "rewrite\nselftest --ignore-scripts", "failed": "false"},
               "core": {"reading_set": "bash", "inert.bash": "none", "failed": "false"},
               "sides": {"written": {"decision": "run", "shells": written}, "core": {"decision": "run", "shells": core}}}
        if bash is not None:
            res["sides"]["bash"] = {"decision": "run", "shells": bash}
        return res

    def four(o):
        return {sh: dict(o) for sh in SHELLS}

    # 1. A tab and a newline in an argument are one argument each.
    box = tempfile.mkdtemp(prefix="b.", dir=work)
    o = shells.observe("npm ci 'a\tb' 'c\nd' ''; pip install 'x\ty'", box)
    check("argv keeps a tab, a newline and an empty word", o["bash"]["npm"], [["ci", "a\tb", "c\nd", ""]])
    check("another stand-in's call is kept, in order", o["bash"]["calls"], [["npm", "ci", "a\tb", "c\nd", ""], ["pip", "install", "x\ty"]])
    check("every shell has its own run", sorted(o), sorted(SHELLS))
    # 2. What a command writes to a file and to its streams is observed.
    o1 = shells.observe("npm ci; printf '%s' x > f; exit 3", box)
    o2 = shells.observe("npm ci; printf '%s' 'x --ignore-scripts' > f; exit 3", box)
    R.ask([["ci"]])
    check("the exit status is the run's own", o1["dash"]["rc"], 3)
    check("npm calls alike, a file's content apart: the files differ", relate(o1["bash"], o2["bash"], R)["files"], "differ")
    check("...and the npm calls are identical", relate(o1["bash"], o2["bash"], R)["npm"], "identical")
    o3 = shells.observe("npm ci; test x", box)
    o4 = shells.observe("npm ci; test x --ignore-scripts", box)
    check("a flag handed to another command changes the exit status", relate(o3["bash"], o4["bash"], R)["rc"], "differ")
    # 3. Two runs at once each get their own result.
    with ThreadPoolExecutor(max_workers=2) as ex:
        fa = ex.submit(shells.observe, "npm ci a; exit 5", tempfile.mkdtemp(prefix="b.", dir=work))
        fb = ex.submit(shells.observe, "npm ci b; exit 6", tempfile.mkdtemp(prefix="b.", dir=work))
        ra, rb = fa.result(), fb.result()
    check("two runs at once: each keeps its own exit status and calls",
          [ra["bash"]["rc"], ra["bash"]["npm"], rb["bash"]["rc"], rb["bash"]["npm"]], [5, [["ci", "a"]], 6, [["ci", "b"]]])
    # 4. The command is the word npm's options leave, not the first word without a dash.
    R.ask([["--prefix", "d", "ci"], ["ci", "--ignore-scripts", "--", "--ignore-scripts"], ["ci", "--ignore-scripts", "--"],
           ["ci", "--ignore-scripts"], ["run", "build"], ["ci", "--", "--ignore-scripts"], ["ci", "--"], ["ci", "--cache", "--ignore-scripts"],
           ["ci", "--cache"], []])
    if R.npm_asked:
        check("`npm --prefix d ci` is an install", R.install(["--prefix", "d", "ci"]), True)
        check("`npm run build` is none", R.install(["run", "build"]), False)
        check("a flag after `--` does not set the option", R.flagged(["ci", "--", "--ignore-scripts"]), False)
    else:
        print("not ok npm's own parser could not be asked: %s" % R.npm_error)
        bad += 1
    # 5. An argument that was there is never dropped to make two calls compare.
    check("a `--ignore-scripts` after `--` that is gone is an argument changed",
          flag_edit(["ci", "--ignore-scripts", "--", "--ignore-scripts"], ["ci", "--ignore-scripts", "--"]), None)
    check("an inserted flag is found", flag_edit(["ci", "x"], ["ci", "--ignore-scripts", "x", "--ignore-scripts"]), [1, 3])
    w = obs([["ci", "--ignore-scripts", "--", "--ignore-scripts"]])
    c = obs([["ci", "--ignore-scripts", "--"]])
    check("...and the row is a loss", side_verdict(row(four(w), four(c)), "core", R)["npm"], "loss")
    w, c = obs([["ci", "--"]]), obs([["ci", "--", "--ignore-scripts"]])
    check("a flag placed after `--` is no option: a loss", side_verdict(row(four(w), four(c)), "core", R)["npm"], "loss")
    w, c = obs([["ci", "--cache"]]), obs([["ci", "--cache", "--ignore-scripts"]])
    if R.npm_asked:
        check("a flag an option takes as its value is no option: a loss", side_verdict(row(four(w), four(c)), "core", R)["npm"], "loss")
    # 6. No call is no agreement, and a missing run is not an empty one.
    e = obs([])
    check("no install call in any shell is `nocall`, not `ok`", side_verdict(row(four(e), four(e)), "core", R)["npm"], "nocall")
    three = {sh: dict(e) for sh in SHELLS[:3]}
    check("a shell with no run is unknown, not an empty call", side_verdict(row(four(e), three), "core", R)["npm"], UNKNOWN)
    check("an undecodable log is unknown", side_verdict(row(four(e), four(dict(e, log="undecodable", npm=UNKNOWN))), "core", R)["npm"], UNKNOWN)
    w, c = obs([["ci"]]), obs([])
    check("a call of the command as written that is gone is a loss", side_verdict(row(four(w), four(c)), "core", R)["npm"], "loss")
    # 7. The statuses: disagreement on both sides comes before `same`.
    both = {"set": "selftest", "command": "selftest", "core_rc": 0, "sides": {},
            "ref": {"reading_set": "bash zsh dash", "inert.bash": "none", "inert.zsh": "rewrite\nselftest --ignore-scripts", "inert.dash": "none", "failed": "false"},
            "core": {"reading_set": "bash zsh dash", "inert.bash": "none", "inert.zsh": "rewrite\nselftest --ignore-scripts", "inert.dash": "none", "failed": "false"}}
    failed = {"set": "selftest", "command": "selftest", "core_rc": 0, "sides": {},
              "ref": {"reading_set": "bash", "inert.bash": "none", "failed": "true"}, "core": {"reading_set": "bash", "inert.bash": "none", "failed": "true"}}
    kind_only = {"set": "selftest", "command": "selftest x", "core_rc": 0, "sides": {}, "payloads3": {"bash": 0, "zsh": 0, "dash": 0},
                 "ref": {"reading_set": "bash", "inert.bash": "rewrite unread\nselftest --ignore-scripts x", "failed": "false"},
                 "core": {"reading_set": "bash", "inert.bash": "rewrite unverified unread\nselftest --ignore-scripts x", "failed": "false"}}
    R.ask([["ci"], ["ci", "--ignore-scripts"]])
    minus = row(four(obs([["ci"]])), four(obs([["ci", "--ignore-scripts"]])), four(obs([["ci", "--ignore-scripts"]])))
    empty = row(four(e), four(e), four(e))
    worse = row(four(obs([["ci"]])), four(obs([["ci"]])), four(obs([["ci", "--ignore-scripts"]])))
    worse["core"]["inert.bash"] = "downgrade"
    classify([both, failed, kind_only, minus, empty, worse], load_classes(), R)
    check("equal values that disagree among the readings on both sides: both-undecided", both["status"], "both-undecided")
    check("a reading failed on both sides: both-failed", failed["status"], "both-failed")
    check("a text with no payload whose records differ in kind alone is named by no class", kind_only["status"], "unclassified")
    check("a `-` row is an observation under `decrease:`, never a class", minus["status"].startswith("decrease"), True)
    check("a `-` row with no install call in any shell is `decrease:nocall`", empty["status"], "decrease:nocall")
    if R.npm_asked:
        check("a `-` row whose calls hold and whose effects are the command's own: its label", minus["status"], "decrease:argv-equal")
        check("the bash side reads true where the core only records: a decrease", worse["status"], "decrease")
    shutil.rmtree(work, ignore_errors=True)
    print("selftest: %d not ok" % bad)
    return 1 if bad else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--core", default="")
    ap.add_argument("--jobs", type=int, default=1)
    ap.add_argument("--sets", default="")
    ap.add_argument("--extra", action="append", default=[])
    ap.add_argument("--shells", action="store_true")
    ap.add_argument("--evidence", action="store_true", help="run the shells on the rows that differ")
    ap.add_argument("--release-tree", default="")
    ap.add_argument("--floor", action="store_true")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--random", type=int, default=0)
    ap.add_argument("--seed", type=int, default=20261006)
    ap.add_argument("--report", default="")
    ap.add_argument("--control", action="store_true", help="damage the reference: drop the floor flag after every verb")
    ap.add_argument("--reclassify", default="", help="a saved --report: classify its rows again, running no guard and no shell")
    ap.add_argument("--list", default="", help="write the selected commands (set, sha256 of the command, command) to this file and run nothing")
    ap.add_argument("--table", default="", help="write one line per row: set, status, label, tokens, what the shells show of the core, command")
    ap.add_argument("--manifest", default="", help="write one JSON line for the run and one per row")
    ap.add_argument("--path-prefix", default="", help="directories put before the system PATH where the guards and the readers find npm and node (nothing installs)")
    ap.add_argument("--approve", action="append", default=[],
                    help="eco:name:version approved in the release tree's sandbox ledger first, as the batteries do")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        sys.exit(selftest(a))
    if not a.core and not a.reclassify:
        sys.exit("core-inert-differential: --core is required")
    # A saved report is classified again without a core: none runs, and the
    # run's record must not name one that did not measure these rows.
    a.core = os.path.abspath(a.core) if a.core else ""
    jobs = max(1, min(a.jobs, 2))

    work = tempfile.mkdtemp(prefix="safedeps-core-inert.")
    oracle_dir = os.path.join(work, "oracle")
    os.makedirs(os.path.join(oracle_dir, "scripts"))
    os.symlink(os.path.join(ROOT, "lib"), os.path.join(oracle_dir, "lib"))
    os.symlink(os.path.join(ROOT, "bin"), os.path.join(oracle_dir, "bin"))
    src = open(GUARD, encoding="latin-1").read()
    if src.count(ANCHOR) != 1:
        sys.exit("core-inert-differential: the anchor is not in the guard once")
    src = src.replace(ANCHOR, DUMP + ANCHOR)
    if a.control:
        needle = '    (( placed == verb )) || printf \'%s%s\\n\' "${verb}" "${note}"\n'
        if src.count(needle) != 1:
            sys.exit("core-inert-differential: the control's mutation site is gone from the guard")
        src = src.replace(needle, '    :\n')
    oracle = os.path.join(oracle_dir, "scripts", "safedeps-pre-guard.sh")
    open(oracle, "w", encoding="latin-1").write(src)

    sets = {}
    names = [s for s in a.sets.split(",") if s]
    if a.reclassify:
        names = ["-"]
        a.extra = []

    # No --sets reads every corpus, unless --extra names the commands: then
    # only those.
    def want(n):
        return (not names and not a.extra) or n in names

    if any(want(n) for n in ("tuple-corpus", "scan-corpus", "scan-failure", "shell-reading", "word-reading", "inert-record",
                             "inert-variants", "release-rewrites", "inert-gen", "redirection-grid", "random")):
        for k, v in load_facts_corpora()(a.random, a.seed).items():
            if want(k):
                sets[k] = v
    if want("downgrade-grid"):
        sets["downgrade-grid"] = grid_forms(work)
    for e in a.extra:
        name, path_ = e.split("=", 1)
        path_ = os.path.expanduser(path_)
        rows = []
        for line in open(path_, encoding="utf-8"):
            if line.strip():
                r = json.loads(line)
                c = r.get("cmd", r.get("text", r.get("command"))) if isinstance(r, dict) else r
                if isinstance(c, str):
                    rows.append(c)
        sets[name] = rows
    rows = []
    for name, texts in sets.items():
        seen = set()
        for t in texts:
            if t in seen or not t.strip():
                continue
            seen.add(t)
            if a.limit and len(seen) > a.limit:
                break
            rows.append((name, t))
    if a.list:
        with open(a.list, "w", encoding="utf-8") as f:
            for name, t in rows:
                f.write("%s\t%s\t%s\n" % (name, sha256(cmd_bytes(t)), json.dumps(t, ensure_ascii=False)))
        print("core-inert-differential --list: %d commands (%s)" % (len(rows), ", ".join("%s %d" % (k, len(set(v))) for k, v in sets.items())))
        shutil.rmtree(work, ignore_errors=True)
        return
    if not a.reclassify:
        print("core-inert-differential: %d commands (%s), jobs %d" % (
            len(rows), ", ".join("%s %d" % (k, len(set(v))) for k, v in sets.items()), jobs), flush=True)

    path = ":".join(d for d in ("/usr/bin", "/bin", "/usr/sbin", "/sbin") if os.path.isdir(d))
    # The release tree's whole pre-guard asks npm (where an install lands,
    # which registry it fetches from) and denies where it cannot: its PATH
    # gets --path-prefix, and so does the reader that asks npm's own parser.
    # The patched head guard writes its records before it asks anything, and
    # the core asks nothing.
    rpath = path
    if a.path_prefix:
        rpath = ":".join(os.path.expanduser(x) for x in a.path_prefix.split(":") if x) + ":" + path
    observing = bool(a.shells or a.release_tree or a.evidence)
    shells = Shells(work) if observing else None
    rel_guard = os.path.join(os.path.abspath(os.path.expanduser(a.release_tree)), "scripts", "safedeps-pre-guard.sh") if a.release_tree else ""
    floor_rows = {}
    if a.floor:
        for r in json.load(open(os.path.join(TEST, "inert-release-rewrites.json"), encoding="utf-8")):
            floor_rows[r["command"]] = r["release"]

    def box_env(box, extra=None, release=False):
        env = {"PATH": rpath if release else path, "HOME": os.path.join(box, "home"), "SAFEDEPS_HOME": os.path.join(box, "sd"), "LANG": "en_US.UTF-8", "TMPDIR": box}
        os.makedirs(env["HOME"], exist_ok=True)
        if extra:
            env.update(extra)
        return env

    def release_side(cmd, idx, box):
        """The --release-tree pre-guard's answer, and what its command does
        under the shells."""
        rbox = tempfile.mkdtemp(prefix="r.", dir=box)
        rproj = os.path.join(rbox, "project")
        os.makedirs(rproj)
        open(os.path.join(rproj, "package.json"), "w").write('{"name":"p","version":"1.0.0","dependencies":{}}\n')
        env = box_env(rbox, release=True)
        for ap_ in a.approve:
            eco, name_, ver = ap_.split(":")
            subprocess.run(["bash", os.path.join(os.path.dirname(os.path.dirname(rel_guard)), "lib", "ledger", "ledger.sh"),
                            "approve", eco, name_, ver, ver, "inert-differential"], env=env, capture_output=True, timeout=60)
        r = subprocess.run(["nice", "-n", "10", "bash", rel_guard], input=payload(cmd, rproj, "toolu_inert%d" % idx),
                           capture_output=True, env=env, cwd=rproj, timeout=180)
        try:
            hso = json.loads(r.stdout or b"{}").get("hookSpecificOutput", {})
        except ValueError:
            hso = {}
        adv = os.path.join(env["SAFEDEPS_HOME"], "advisory.log")
        rec = bool(INERT_RECORD_RE.search(open(adv, encoding="latin-1").read())) if os.path.exists(adv) else False
        if hso.get("permissionDecision") == "deny":
            return {"decision": "deny", "reason": (hso.get("permissionDecisionReason") or "")[:200], "guard_rc": r.returncode}
        run = hso.get("updatedInput", {}).get("command") or cmd
        return {"decision": "run", "run": run, "shells": shells.observe(run, box), "record": rec, "guard_rc": r.returncode,
                "flags": flag_positions(cmd_bytes(cmd), cmd_bytes(run))}

    def whole_guard(guard, cmd, tid, box):
        """A tree's whole pre-guard, asked as the hook is: its decision and
        its reason. The sandbox ledger holds the --approve specs."""
        gbox = tempfile.mkdtemp(prefix="g.", dir=box)
        proj = os.path.join(gbox, "project")
        os.makedirs(proj)
        open(os.path.join(proj, "package.json"), "w").write('{"name":"p","version":"1.0.0","dependencies":{}}\n')
        env = box_env(gbox, release=True)
        for ap_ in a.approve:
            eco, name_, ver = ap_.split(":")
            subprocess.run(["bash", os.path.join(os.path.dirname(os.path.dirname(guard)), "lib", "ledger", "ledger.sh"),
                            "approve", eco, name_, ver, ver, "inert-differential"], env=env, capture_output=True, timeout=60)
        r = subprocess.run(["nice", "-n", "10", "bash", guard], input=payload(cmd, proj, tid), capture_output=True, env=env, cwd=proj, timeout=180)
        try:
            hso = json.loads(r.stdout or b"{}").get("hookSpecificOutput", {})
        except ValueError:
            hso = {}
        return {"decision": "deny" if hso.get("permissionDecision") == "deny" else "allow",
                "reason": (hso.get("permissionDecisionReason") or "")[:300], "guard_rc": r.returncode,
                "rewrite": hso.get("updatedInput", {}).get("command")}

    def one(idx_row):
        idx, (name, cmd) = idx_row
        box = tempfile.mkdtemp(prefix="c.", dir=work)
        proj = os.path.join(box, "project")
        os.makedirs(os.path.join(proj, "x"))
        os.makedirs(os.path.join(proj, "sub"))
        for d in (proj, os.path.join(proj, "x"), os.path.join(proj, "sub")):
            open(os.path.join(d, "package.json"), "w").write('{"dependencies":{}}\n')
        dump = os.path.join(box, "dump")
        res = {"set": name, "command": cmd}
        try:
            br = subprocess.run(["nice", "-n", "10", "bash", oracle], input=payload(cmd, proj), capture_output=True,
                                env=box_env(box, {"SAFEDEPS_CORE_DUMP": dump}), cwd=proj, timeout=180)
            res["bash_rc"] = br.returncode
            if not os.path.exists(dump):
                try:
                    hso = json.loads(br.stdout or b"{}").get("hookSpecificOutput", {})
                except ValueError:
                    hso = {}
                res["bash_exit"] = hso.get("permissionDecision", "allow") + ": " + (hso.get("permissionDecisionReason") or "")[:160]
        except subprocess.TimeoutExpired:
            res["bash_timeout"] = True
        ref = parse_records(open(dump, "rb").read()) if os.path.exists(dump) else {}
        c = subprocess.run(["nice", "-n", "10", a.core, "inert"], input=payload(cmd, proj), capture_output=True, env=box_env(box), cwd=proj, timeout=120)
        got = parse_records(c.stdout) if c.returncode == 0 else {}
        res["core_rc"] = c.returncode
        # How many payloads the command's own top level hands on, in each of
        # the three readings (`safedeps-core words`, its Y records). A reading
        # that could not be asked is None, never 0.
        p3 = {}
        for rd in ("bash", "zsh", "dash"):
            w = subprocess.run(["nice", "-n", "10", a.core, "words"], input=cmd_bytes(cmd), capture_output=True,
                               env=box_env(box, {"SAFEDEPS_READING": rd}), cwd=proj, timeout=60)
            p3[rd] = sum(1 for line in w.stdout.split(b"\n") if line.startswith(b"Y ")) if w.returncode == 0 else None
        res["payloads3"] = p3
        res["ref"] = {k: v.decode("latin-1") for k, v in ref.items()}
        res["core"] = {k: v.decode("latin-1") for k, v in got.items()}
        cb = cmd_bytes(cmd)
        differs = ref and got and any(ref.get(k) != got.get(k) for k in set(ref) | set(got) if k.startswith("inert.") or k == "failed")
        if a.shells or rel_guard or (a.evidence and differs):
            sides = {"written": {"decision": "run", "run": cmd, "shells": shells.observe(cmd, box)}}
            for side, recs in (("bash", ref), ("core", got)):
                if not recs or recs.get("any_install") != b"true":
                    continue
                o = consensus(recs, cb)
                if o is None:
                    continue
                if o == "deny" or recs.get("failed") == b"true":
                    sides[side] = {"decision": "deny", "why": "its readings disagree" if o == "deny" else "its reading failed"}
                    continue
                run = o[2].decode("utf-8", "surrogateescape")
                sides[side] = {"decision": "run", "run": run, "record": bool(records_of(o)), "shells": shells.observe(run, box)}
            if rel_guard:
                sides["v2.18.1"] = release_side(cmd, idx, box)
            res["sides"] = sides
        if a.floor and cmd in floor_rows:
            o = consensus(got, cb) if got else None
            rel = floor_rows[cmd]
            if rel is None:
                res["floor"] = "release-none"
            elif o is None or o == "deny":
                res["floor"] = "core-deny" if o == "deny" else "core-none"
            elif o[0] != "rewrite":
                res["floor"] = "NOT: the core writes no rewrite"
            else:
                res["floor"] = "ok" if subseq(o[2], cmd_bytes(rel), cb) else "NOT"
        shutil.rmtree(box, ignore_errors=True)
        return idx, res

    run_info = {"schema": SCHEMA, "argv": sys.argv[1:], "harness_sha256": sha256(open(os.path.abspath(__file__), "rb").read()),
                "classes_sha256": sha256(open(os.path.join(MEASURE, "core-intended-inert.tsv"), "rb").read()),
                "guard_sha256": sha256(open(GUARD, "rb").read()), "core": a.core or None,
                "core_sha256": sha256(open(a.core, "rb").read()) if a.core and os.path.isfile(a.core) else None,
                "release_guard_sha256": sha256(open(rel_guard, "rb").read()) if rel_guard and os.path.isfile(rel_guard) else None,
                "shells": shells.info if shells else None, "jobs": jobs}
    commit = os.path.join(os.path.dirname(ROOT), "commit")
    if os.path.isfile(commit):
        run_info["tree_commit"] = open(commit).read().strip()
    if a.reclassify:
        saved = upgrade(json.load(open(a.reclassify, encoding="utf-8")))
        results = saved["rows"]
        up0, up1 = (saved.get("load") or ["", ""])[:2]
        run_info["reclassified_from"] = a.reclassify
        run_info["reclassified_from_sha256"] = sha256(open(a.reclassify, "rb").read())
        run_info["measured_by"] = saved.get("run")
        if saved.get("upgraded_from_schema"):
            run_info["upgraded_from_schema"] = saved["upgraded_from_schema"]
    else:
        up0 = subprocess.run(["uptime"], capture_output=True, text=True).stdout.strip()
        results = [None] * len(rows)
        with ThreadPoolExecutor(max_workers=jobs) as ex:
            for idx, res in ex.map(one, list(enumerate(rows))):
                results[idx] = res
        up1 = subprocess.run(["uptime"], capture_output=True, text=True).stdout.strip()

    # The readers, asked of every npm argv any run made.
    argvs = []
    for res in results:
        for v in res.get("sides", {}).values():
            if isinstance(v.get("shells"), dict):
                for o in v["shells"].values():
                    if isinstance(o, dict) and isinstance(o.get("npm"), list):
                        argvs.extend(o["npm"])
    R = Readers(work, rpath) if argvs else NoReaders()
    R.ask(argvs)
    run_info["npm_parser"] = {"asked": R.npm_asked, "version": R.npm_version, "error": R.npm_error}

    reach = {}
    rp = os.path.join(MEASURE, "inert-record-reach.tsv")
    if os.path.exists(rp) and observing and not a.reclassify:
        ids = {}
        ir = json.load(open(os.path.join(MEASURE, "inert-record-forms.json"), encoding="utf-8"))
        for k, key in (("forms", "ext"), ("probes", "probe")):
            for r in ir[k]:
                ids["%s-%s" % (key, r["id"])] = r["cmd"]
        for line in open(os.path.join(MEASURE, "inert-record-variants.jsonl"), encoding="utf-8"):
            if line.strip():
                r = json.loads(line)
                ids["var-" + r["id"]] = r["cmd"]
        gdir = os.path.join(work, "grid-forms")
        if not os.path.isdir(gdir):
            grid_forms(work)
        if os.path.isdir(gdir):
            for f in os.listdir(gdir):
                if f.endswith(".cmd"):
                    ids["grid-" + f[:-4]] = open(os.path.join(gdir, f), "rb").read().decode("utf-8", "surrogateescape")
        for line in open(rp, encoding="utf-8"):
            fid, n = line.rstrip("\n").split("\t")
            if fid in ids:
                reach[ids[fid]] = (fid, int(n))

    counts = classify(results, load_classes(), R)
    # A row where the core's side makes a call without the flag and writes no
    # record: what the head's whole pre-guard answers for that command. The
    # inert rewrite is one step of the guard, and a command the guard denies
    # runs nothing.
    if observing and not a.reclassify:
        for k, res in enumerate(results):
            c = res.get("sides", {}).get("core", {})
            if isinstance(c.get("shells"), dict) and any(state(o, bool(c.get("record")), R) == "SILENT" for o in c["shells"].values()):
                box = tempfile.mkdtemp(prefix="h.", dir=work)
                res["sides"]["head"] = whole_guard(GUARD, res["command"], "toolu_head%d" % k, box)
                shutil.rmtree(box, ignore_errors=True)
    summary, red = summarize(results, counts, R, a, {"up0": up0, "up1": up1, "reach": reach})
    if a.table:
        with open(a.table, "w", encoding="utf-8") as f:
            for res in results:
                cv = res.get("obs", {}).get("core")
                f.write("%s\t%s\t%s\t%s\t%s\t%s\t%s\n" % (res["set"], res.get("status", ""), res.get("label", ""), ",".join(res.get("tokens") or []),
                                                          ("npm %s, effects %s" % (cv["npm"], cv["effects"])) if cv else "",
                                                          res.get("bash_exit", ""), json.dumps(res["command"], ensure_ascii=False)))
    if a.manifest:
        manifest(a.manifest, results, run_info)
    if a.report:
        json.dump({"schema": SCHEMA, "run": run_info, "summary": summary, "load": [up0, up1], "readings": R.answers(), "rows": results},
                  open(a.report, "w"), ensure_ascii=False, indent=1)
    shutil.rmtree(work, ignore_errors=True)
    if a.control:
        print("control: the damaged reference differs on %d commands" % counts["differ"])
        sys.exit(0 if counts["differ"] else 1)
    sys.exit(1 if red else 0)


if __name__ == "__main__":
    main()
