#!/usr/bin/env python3
"""safedeps: the Rust core's inert rewrite against the bash guard's, and the
checks the rewrite owes whatever the bash guard says.

The bash guard is the reference for the comparison. A copy of it, made in a
scratch directory and never in the tree, gets one block before
`# --- Reorg Guard Activated ---`: it runs `guard_reading_inert` in every
reading the guard reads the command in, writes each reading's value
(GUARD_INERT_<reading>) and whether the scan mark is set, and exits.
`safedeps-core inert` prints the same records for the same hook payload. A
command the guard leaves before that line (not an install, or denied by the
detection) is listed and not compared.

Every difference is classified by direction, per reading:

  +flag / -flag          a flag at a place the other side has none
  +rec:<r> / -rec:<r>    a record (downgrade, floor, unverified, unread,
                         release, asked) the other side does not write
  +undecided / -undecided  the core's reading failed where the bash guard's
                         did not, or the other way
  +deny / -deny          the readings disagree on one side only, so that side
                         denies the command as UNDECIDED

A difference whose tokens hold no `-` is in an allowed direction; it still
needs a name in scripts/measure/core-intended-inert.tsv (`name`, the tokens
it may carry, a pattern over the command, the reason). A `-` token is a
decrease and has no name; it is listed with the shells' argv as evidence.
`payload-free` marks a command whose own top level hands on no payload in any
of the three readings (`safedeps-core words`): the design allows two classes
of difference there, a `}` after a line continuation and readings that hold
different rewrites.

Four readings of a `-` row are listed apart and none of them is a name:
`decrease:argv-equal` (every shell hands npm the same install calls on both
sides), `decrease:core-dominates` and `decrease:core-exact` (in every shell
the core's side makes the install calls of the command as written with flags
added and nothing else changed, each reading true; the bash side's do not in
some shell, or do as well) and `decrease` (none of these). All four fail the
run until the plan owner names them.

`both-undecided` is a row whose readings hold different values on both sides:
no rewrite is sent on either, so the command is UNDECIDED on both, and the
values that differ run nowhere. It is counted apart, neither same nor a
difference.

With --shells, the command that would run on each side (the rewrite, or the
command as written) runs under bash, zsh and dash with a stub npm that writes
down its argv, and with stubs for the other managers and the network tools,
in a fresh directory. A side is FLAG (every npm call reads ignore-scripts
true), NOCALL (no npm call), REC (an unflagged call and a record), SILENT (an
unflagged call and no record) or DENY, per shell.

With --release-tree DIR (an extracted v2.18.1), that tree's whole pre-guard
judges the same payload, its rewrite runs the same way and its advisory.log is
read for inert records: a LOSS is a shell where v2.18.1 is not SILENT and the
core is.

With --floor, every command of scripts/test/inert-release-rewrites.json that
the core rewrites is checked against 7d66f8c's recorded rewrite: deleting
some of the core's flags gives the release's (release-floor.sh's property).

The record invariant on the core is the SILENT count of --shells: an npm call
without the flag where the core writes no record.

Commands are data: each reaches the guards and the core as a JSON payload on
standard input, and the shells as an argument.

--sets names corpora; --extra alone runs only the files it names; neither
runs every corpus. --list writes the selection and runs nothing. --reclassify
and --release-only read a saved report: the first classifies its rows again,
the second judges only the --release-tree side again. --npm-read adds a second
state per call, from the gate's own npm reader (safedeps_npm_read_args), beside
the flag words inert-record-invariant.sh reads.

Usage:
  core-inert-differential.py --core <safedeps-core> [--jobs N] [--sets a,b]
      [--extra name=FILE.jsonl ...] [--shells | --evidence] [--floor]
      [--release-tree DIR --path-prefix DIRS --approve eco:name:version ...]
      [--npm-read] [--limit N] [--report FILE] [--table FILE] [--list FILE]
      [--reclassify REPORT | --release-only REPORT [--only-commands FILE]]
      [--control]
"""
import argparse
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
GUARD = os.path.join(ROOT, "scripts", "safedeps-pre-guard.sh")
MEASURE = os.path.join(ROOT, "scripts", "measure")
TEST = os.path.join(ROOT, "scripts", "test")
FLAG = b" --ignore-scripts"
NOTES = ("asked", "unverified", "floor", "unread", "release")

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

STUB_NPM = '#!/bin/sh\n{ printf \'CALL\'; for a in "$@"; do printf \'\\t%s\' "$a"; done; printf \'\\n\'; } >> "$NPMLOG"\n'
STUB_NPX = r'''#!/bin/sh
pkg=""
while [ $# -gt 0 ]; do
  case "$1" in
    -p|--package) pkg=1; shift 2 ;;
    --) shift; break ;;
    -*) shift ;;
    *) break ;;
  esac
done
if [ -n "$pkg" ]; then
  cmd="$1"; shift
  [ "$cmd" = npm ] || exit 0
else
  shift
fi
exec "$(dirname "$0")/npm" "$@"
'''
STUB_OTHER = '#!/bin/sh\n{ printf \'OTHER\\t%s\' "$(basename "$0")"; for a in "$@"; do printf \'\\t%s\' "$a"; done; printf \'\\n\'; } >> "$NPMLOG"\n'
OTHERS = ["pnpm", "pnpx", "yarn", "bun", "bunx", "pip", "pip3", "pipx", "poetry", "uv", "uvx", "pipenv", "cargo", "go",
          "gem", "bundle", "mvn", "dotnet", "python", "python3", "curl", "wget", "brew", "git", "ssh", "scp", "nc"]
STUB_SUDO = '#!/bin/sh\nwhile [ $# -gt 0 ]; do case "$1" in -*) shift ;; *) break ;; esac; done\nexec "$@"\n'


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


def consensus(recs, cmd):
    """The value every reading agrees on, or 'deny' where they differ."""
    rs = recs.get("reading_set", b"").decode().split()
    vals = [recs.get("inert." + r) for r in rs]
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


class Shells:
    def __init__(self, work):
        self.stub = os.path.join(work, "stub")
        os.makedirs(self.stub, exist_ok=True)
        open(os.path.join(self.stub, "npm"), "w").write(STUB_NPM)
        open(os.path.join(self.stub, "npx"), "w").write(STUB_NPX)
        open(os.path.join(self.stub, "sudo"), "w").write(STUB_SUDO)
        for o in OTHERS:
            open(os.path.join(self.stub, o), "w").write(STUB_OTHER)
        for s in ("mksh", "fish", "pdksh", "yash", "posh", "ksh", "ksh93", "csh", "tcsh"):
            if not shutil.which(s):
                open(os.path.join(self.stub, s), "w").write('#!/bin/sh\nshift\nexec /bin/sh -c "$1"\n')
        for f in os.listdir(self.stub):
            os.chmod(os.path.join(self.stub, f), 0o755)
        self.shells = [s for s in ("/bin/bash", "/bin/zsh", "/bin/dash", "/usr/bin/zsh", "/usr/bin/dash") if os.access(s, os.X_OK)]
        seen = set()
        self.shells = [s for s in self.shells if not (os.path.basename(s) in seen or seen.add(os.path.basename(s)))]

    def run(self, cmd, box, files=()):
        """Per shell: the npm calls, as argv lists. `zsh-agent` is the Claude
        Code Bash tool's wrapper as scripts/measure/shell-reading-measure.sh
        reproduces it, without a session snapshot: zsh -c, its setopt line,
        then eval of the command."""
        out = {}
        self.meta = {}
        runs = [(os.path.basename(sh), [sh, "-c", cmd]) for sh in self.shells]
        zsh = next((sh for sh in self.shells if os.path.basename(sh) == "zsh"), None)
        if zsh:
            runs.append(("zsh-agent", [zsh, "-c", 'setopt NO_EXTENDED_GLOB NO_BARE_GLOB_QUAL 2>/dev/null || true && eval "$SD_INERT_CMD"']))
        for name, argv in runs:
            c = tempfile.mkdtemp(prefix="sh.", dir=box)
            os.makedirs(os.path.join(c, "d"))
            for f in files:
                open(os.path.join(c, f), "w").close()
            log = os.path.join(c, ".npmlog")
            open(log, "w").close()
            env = {"HOME": c, "ZDOTDIR": c, "PATH": self.stub + ":/usr/bin:/bin", "NPMLOG": log, "SD_INERT_CMD": cmd}
            try:
                sr = subprocess.run(["nice", "-n", "10", "perl", "-e", "alarm 10; exec @ARGV"] + argv, cwd=c, env=env,
                                    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=30)
                self.meta[name] = {"rc": sr.returncode, "stderr": sr.stderr[:300].decode("utf-8", "replace")}
            except subprocess.TimeoutExpired:
                self.meta[name] = {"rc": "timeout", "stderr": ""}
            calls = []
            for line in open(log, "rb").read().split(b"\n"):
                f = line.split(b"\t")
                if f[0] == b"CALL":
                    calls.append([x.decode("utf-8", "surrogateescape") for x in f[1:]])
            out[name] = calls
            shutil.rmtree(c, ignore_errors=True)
        return out


def _grammar_value(name):
    for line in open(os.path.join(ROOT, "lib", "install-grammar.sh"), encoding="utf-8"):
        if line.startswith(name + "='"):
            return line[len(name) + 2:line.rindex("'")]
    raise SystemExit("core-inert-differential: %s is not in lib/install-grammar.sh" % name)


INSTALL_VERB = re.compile("^(%s|%s)$" % (_grammar_value("SAFEDEPS_G_NPM_VERBS"), _grammar_value("SAFEDEPS_G_NPM_LINK_VERBS")), re.I)


def install_call(argv):
    """An npm call whose command (its first word that is not an option) is an
    install or link verb. `npm run build` beside an install, and what the npx
    stub hands npm for `npx <package>`, are calls of no install."""
    for a in argv:
        if a == "--":
            return False
        if a.startswith("-"):
            continue
        return bool(INSTALL_VERB.match(a))
    return False


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


def state(calls, recorded):
    calls = [c for c in calls if install_call(c)]
    if not calls:
        return "NOCALL"
    if not any(unflagged(c) for c in calls):
        return "FLAG"
    return "REC" if recorded else "SILENT"


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


def argv_equal(res):
    """Every shell hands npm the same install calls, byte for byte, on both
    sides: the difference is where a flag stands among bytes no shell passes
    on (before or after a redirection, a continuation)."""
    sides = res.get("sides", {})
    b, c = sides.get("bash", {}), sides.get("core", {})
    if not isinstance(b.get("calls"), dict) or not isinstance(c.get("calls"), dict):
        return False
    for sh, bc in b["calls"].items():
        if [x for x in bc if install_call(x)] != [x for x in c["calls"].get(sh, []) if install_call(x)]:
            return False
    return True


def _strip(calls):
    """The install calls, every `--ignore-scripts` word taken out."""
    return [[x for x in call if x != "--ignore-scripts"] for call in calls if install_call(call)]


def _states(side):
    """A side's state per shell: by the flag words, or by the gate's npm
    reader where that was asked too and reads a call as worse."""
    s, n = side.get("state"), side.get("state_npm")
    if not isinstance(s, dict) or not isinstance(n, dict):
        return s
    order = {"NOCALL": 0, "FLAG": 1, "REC": 2, "SILENT": 3}
    return {sh: (n[sh] if sh in n and order.get(n[sh], 0) > order.get(v, 0) else v) for sh, v in s.items()}


def core_exact(res):
    """In every shell the core's side makes the install calls of the command
    as written, argument for argument, with flags added and nothing else
    changed, and each of them reads ignore-scripts true."""
    sides = res.get("sides", {})
    w, c = sides.get("written", {}), sides.get("core", {})
    if not isinstance(w.get("calls"), dict) or not isinstance(c.get("calls"), dict):
        return False
    cs = _states(c)
    if not isinstance(cs, dict):
        return False
    for sh, wc in w["calls"].items():
        cc = c["calls"].get(sh, [])
        if _strip(cc) != _strip(wc):
            return False
        if _strip(cc) and cs.get(sh) != "FLAG":
            return False
    return True


def bash_worse(res):
    """In some shell where the command as written makes an install call, the
    bash side's calls do not all read true (it records instead, or denies),
    or they are not the written calls with flags added (a call lost, an
    argument value changed)."""
    sides = res.get("sides", {})
    w, b = sides.get("written", {}), sides.get("bash", {})
    if not isinstance(w.get("calls"), dict):
        return False
    bs = _states(b)
    for sh, wc in w["calls"].items():
        if not _strip(wc):
            if isinstance(b.get("calls"), dict) and _strip(b["calls"].get(sh, [])):
                return True
            continue
        if not isinstance(bs, dict) or bs.get(sh) != "FLAG":
            return True
        if isinstance(b.get("calls"), dict) and _strip(b["calls"].get(sh, [])) != _strip(wc):
            return True
    return False


def core_dominates(res):
    """core_exact, and the bash side is worse in some shell."""
    return core_exact(res) and bash_worse(res)


def unpaired_places(res):
    """Per reading, the flag places of the installs the core read that the
    bash rewrite's own search did not find: an `install` line of the core's
    detail whose `npm` no `pair` line names. None where a reading has no
    detail."""
    out = {}
    for r in res["ref"].get("reading_set", "").split():
        d = res["core"].get("detail." + r)
        if d is None:
            return None
        lines = [l.split() for l in d.split("\n") if l.strip()]
        paired = set(f[1] for f in lines if f[0] == "pair")
        places = set()
        for f in lines:
            if f[0] == "install" and len(f) >= 6 and f[2] not in paired:
                places.update(int(x) for x in (f[4], f[5]) if x != "-")
        out[r] = places
    return out


def word_value_read(res):
    """Every flag the core adds stands at the verb or the place of an install
    its reader found and the bash rewrite's search did not: None when that
    holds in every reading, else the first reason it does not."""
    cb = res["command"].encode("utf-8", "surrogateescape")
    up = unpaired_places(res)
    if up is None:
        return "a reading has no detail"
    added_any = False
    for r in res["ref"].get("reading_set", "").split():
        bo = outcome(res["ref"].get("inert." + r, "").encode("latin-1"), cb)
        co = outcome(res["core"].get("inert." + r, "").encode("latin-1"), cb)
        if bo is None or co is None or bo[3] is None or co[3] is None:
            return "a reading has no value"
        added = set(co[3]) - set(bo[3])
        if not added <= up[r]:
            return "%s: a flag at %s is at no install the bash search missed" % (r, sorted(added - up[r]))
        added_any = added_any or bool(added)
    return None if added_any else "no flag added"


ARGUMENT_SUBSTITUTION_INPUT = 'npm install left-pad@1.3.0 eval "$(echo) npm"'

# The classes matched by their conditions here, never by their line's tokens
# and pattern.
CODE_CHECKED = ("argument-substitution-preserved", "word-value-read")


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
    None with the first that does not."""
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
    sides = res.get("sides", {})
    w, c, v = sides.get("written", {}), sides.get("core", {}), sides.get("v2.18.1", {})
    if not isinstance(w.get("calls"), dict) or not isinstance(c.get("calls"), dict):
        return "no shell evidence (run with --evidence or --shells)"
    strip = lambda calls: [[x for x in call if x != "--ignore-scripts"] for call in calls]
    for s, calls in c["calls"].items():
        if strip(calls) != strip(w["calls"].get(s, [])):
            return "%s: the npm calls or their argument values differ from the command as written" % s
    if not isinstance(v.get("calls"), dict) or v.get("flags") is None:
        return "no v2.18.1 side that runs (run with --release-tree, --path-prefix and --approve)"
    co_flags = set(outcome(res["core"].get("inert." + res["ref"]["reading_set"].split()[0], "").encode("latin-1"), cb)[3])
    if not set(v["flags"]) <= co_flags:
        return "a v2.18.1 flag is missing in the core's rewrite"
    if v.get("record") and not any(records_of(outcome(res["core"].get("inert." + r, "").encode("latin-1"), cb))
                                   for r in res["ref"]["reading_set"].split()):
        return "v2.18.1 records and the core does not"
    for s, st in c.get("state", {}).items():
        if st == "SILENT":
            return "%s: an npm call without the flag and no record" % s
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--core", required=True)
    ap.add_argument("--jobs", type=int, default=2)
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
    ap.add_argument("--reclassify", default="", help="a saved --report: classify its rows again, running nothing")
    ap.add_argument("--list", default="", help="write the selected commands (set, sha256 of the command, command) to this file and run nothing")
    ap.add_argument("--table", default="", help="write one line per row: set, status, tokens, command")
    ap.add_argument("--path-prefix", default="", help="directories put before the system PATH of the guards, where npm is (the guards ask it; nothing installs)")
    ap.add_argument("--release-only", default="", help="a saved --report: judge only the --release-tree side of its rows again")
    ap.add_argument("--only-commands", default="", help="with --release-only: the rows to judge again, a JSONL of `cmd`")
    ap.add_argument("--npm-read", action="store_true",
                    help="also read each saved npm call with the gate's own npm reader (safedeps_npm_read_args) for a stricter state")
    ap.add_argument("--approve", action="append", default=[],
                    help="eco:name:version approved in the release tree's sandbox ledger first, as the batteries do")
    a = ap.parse_args()
    a.core = os.path.abspath(a.core)
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
    if a.reclassify or a.release_only:
        names = ["-"]
        a.extra = []
    # No --sets reads every corpus, unless --extra names the commands: then
    # only those.
    want = lambda n: (not names and not a.extra) or n in names
    if any(want(n) for n in ("tuple-corpus", "scan-corpus", "scan-failure", "shell-reading", "word-reading", "inert-record",
                             "inert-variants", "release-rewrites", "inert-gen", "redirection-grid", "random")):
        for k, v in load_facts_corpora()(a.random, a.seed).items():
            if want(k):
                sets[k] = v
    if want("downgrade-grid"):
        sets["downgrade-grid"] = grid_forms(work)
    for e in a.extra:
        name, path = e.split("=", 1)
        path = os.path.expanduser(path)
        rows = []
        for line in open(path, encoding="utf-8"):
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
        import hashlib
        with open(a.list, "w", encoding="utf-8") as f:
            for name, t in rows:
                f.write("%s\t%s\t%s\n" % (name, hashlib.sha256(t.encode("utf-8", "surrogateescape")).hexdigest(), json.dumps(t, ensure_ascii=False)))
        print("core-inert-differential --list: %d commands (%s)" % (len(rows), ", ".join("%s %d" % (k, len(set(v))) for k, v in sets.items())))
        shutil.rmtree(work, ignore_errors=True)
        return
    if not (a.reclassify or a.release_only):
      print("core-inert-differential: %d commands (%s), jobs %d" % (
        len(rows), ", ".join("%s %d" % (k, len(set(v))) for k, v in sets.items()), jobs), flush=True)

    path = ":".join(d for d in ("/usr/bin", "/bin", "/usr/sbin", "/sbin") if os.path.isdir(d))
    # The release tree's whole pre-guard asks npm (where an install lands,
    # which registry it fetches from) and denies where it cannot: its PATH
    # gets --path-prefix. The patched head guard writes its records before it
    # asks anything, and the core asks nothing.
    rpath = path
    if a.path_prefix:
        rpath = ":".join(os.path.expanduser(x) for x in a.path_prefix.split(":") if x) + ":" + path
    shells = Shells(work) if (a.shells or a.release_tree or a.evidence or a.release_only) else None
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
            return {"state": "DENY", "reason": (hso.get("permissionDecisionReason") or "")[:200], "rc": r.returncode}
        run = hso.get("updatedInput", {}).get("command") or cmd
        calls = shells.run(run, box)
        return {"run": run, "calls": calls, "record": rec, "rc": r.returncode,
                "flags": flag_positions(cmd.encode("utf-8", "surrogateescape"), run.encode("utf-8", "surrogateescape")),
                "state": {s: state(v, rec) for s, v in calls.items()}}

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
        # the three readings (`safedeps-core words`, its Y records).
        p3 = {}
        for rd in ("bash", "zsh", "dash"):
            w = subprocess.run(["nice", "-n", "10", a.core, "words"], input=cmd.encode("utf-8", "surrogateescape"), capture_output=True,
                               env=box_env(box, {"SAFEDEPS_READING": rd}), cwd=proj, timeout=60)
            p3[rd] = sum(1 for line in w.stdout.split(b"\n") if line.startswith(b"Y ")) if w.returncode == 0 else None
        res["payloads3"] = p3
        res["ref"] = {k: v.decode("latin-1") for k, v in ref.items()}
        res["core"] = {k: v.decode("latin-1") for k, v in got.items()}
        cb = cmd.encode("utf-8", "surrogateescape")
        differs = ref and got and any(ref.get(k) != got.get(k) for k in set(ref) | set(got) if k.startswith("inert.") or k == "failed")
        if a.shells or rel_guard or (a.evidence and differs):
            sides = {}
            calls = shells.run(cmd, box)
            sides["written"] = {"calls": calls, "shells": dict(shells.meta)}
            for side, recs in (("bash", ref), ("core", got)):
                if not recs or recs.get("any_install") != b"true":
                    continue
                o = consensus(recs, cb)
                if o is None:
                    continue
                if o == "deny" or recs.get("failed") == b"true":
                    sides[side] = {"state": "DENY"}
                    continue
                calls = shells.run(o[2].decode("utf-8", "surrogateescape"), box)
                rec = bool(records_of(o))
                sides[side] = {"run": o[2].decode("latin-1"), "calls": calls,
                               "state": {s: state(v, rec) for s, v in calls.items()}}
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
                res["floor"] = "ok" if subseq(o[2], rel.encode("utf-8", "surrogateescape"), cb) else "NOT"
        shutil.rmtree(box, ignore_errors=True)
        return idx, res

    if a.release_only:
        saved = json.load(open(a.release_only, encoding="utf-8"))
        results = saved["rows"]
        up0 = subprocess.run(["uptime"], capture_output=True, text=True).stdout.strip()

        only = None
        if a.only_commands:
            only = set(json.loads(l)["cmd"] for l in open(os.path.expanduser(a.only_commands), encoding="utf-8") if l.strip())

        def again(idx_res):
            idx, res = idx_res
            if only is not None and res["command"] not in only:
                return idx, res
            if "sides" in res and res["core"].get("any_install") == "true":
                box = tempfile.mkdtemp(prefix="c.", dir=work)
                res["sides"]["v2.18.1"] = release_side(res["command"], idx, box)
                shutil.rmtree(box, ignore_errors=True)
            return idx, res
        with ThreadPoolExecutor(max_workers=jobs) as ex:
            for idx, res in ex.map(again, list(enumerate(results))):
                results[idx] = res
        for res in results:
            for k in ("status", "tokens", "payload_free"):
                res.pop(k, None)
        up1 = subprocess.run(["uptime"], capture_output=True, text=True).stdout.strip()
    elif a.reclassify:
        saved = json.load(open(a.reclassify, encoding="utf-8"))
        results = saved["rows"]
        up0, up1 = saved.get("load", ["", ""])
        for res in results:
            for k in ("status", "tokens", "payload_free"):
                res.pop(k, None)
    else:
        up0 = subprocess.run(["uptime"], capture_output=True, text=True).stdout.strip()
        results = [None] * len(rows)
        with ThreadPoolExecutor(max_workers=jobs) as ex:
            for idx, res in ex.map(one, list(enumerate(rows))):
                results[idx] = res
        up1 = subprocess.run(["uptime"], capture_output=True, text=True).stdout.strip()

    if a.reclassify or a.release_only:
        # Rows saved before the three-reading payload count get it now.
        for res in results:
            if "payloads3" in res or res.get("core_rc") != 0:
                continue
            p3 = {}
            for rd in ("bash", "zsh", "dash"):
                w = subprocess.run([a.core, "words"], input=res["command"].encode("utf-8", "surrogateescape"), capture_output=True,
                                   env={"PATH": path, "SAFEDEPS_READING": rd, "HOME": work, "TMPDIR": work}, cwd=work, timeout=60)
                p3[rd] = sum(1 for line in w.stdout.split(b"\n") if line.startswith(b"Y ")) if w.returncode == 0 else None
            res["payloads3"] = p3
    if a.reclassify or a.release_only:
        # States come from the saved calls with this classifier's rules.
        for res in results:
            cb = res["command"].encode("utf-8", "surrogateescape")
            for side, v in res.get("sides", {}).items():
                calls = v.get("calls")
                if not isinstance(calls, dict) or side == "written":
                    continue
                if side in ("bash", "core"):
                    recs = {k: x.encode("latin-1") for k, x in res["ref" if side == "bash" else "core"].items()}
                    o = consensus(recs, cb)
                    rec = bool(records_of(o)) if o not in (None, "deny") else False
                else:
                    rec = bool(v.get("record"))
                v["state"] = {sh: state(cs, rec) for sh, cs in calls.items()}
    if a.npm_read:
        # What the gate's npm reader makes of each npm call: the last value
        # ignore-scripts takes, an option that takes the next word as its
        # value included. The record invariant's own check
        # (inert-record-invariant.sh) reads the flag words alone; both are kept.
        reader = os.path.join(work, "npm-read.sh")
        open(reader, "w").write('set -u\nsource "$1/lib/install-grammar.sh" || exit 3\nshift\n'
                                'safedeps_npm_read_args "$@" || { echo unread; exit 0; }\nlast=unset\n'
                                'for w in "${SAFEDEPS_G_NPM_SWITCHES[@]+"${SAFEDEPS_G_NPM_SWITCHES[@]}"}"; do\n'
                                '  [[ "${w}" != ignore-scripts=* ]] || last="${w#*=}"\ndone\necho "${last}"\n')
        cache = {}

        def npm_reads(argv):
            k = tuple(argv)
            if k not in cache:
                r = subprocess.run(["bash", reader, ROOT] + list(argv), capture_output=True, text=True, timeout=30)
                cache[k] = r.stdout.strip() if r.returncode == 0 else "failed"
            return cache[k]
        for res in results:
            for side, v in res.get("sides", {}).items():
                calls = v.get("calls")
                if not isinstance(calls, dict) or side == "written":
                    continue
                o = None
                if side in ("bash", "core"):
                    recs = {k: x.encode("latin-1") for k, x in res["ref" if side == "bash" else "core"].items()}
                    o = consensus(recs, res["command"].encode("utf-8", "surrogateescape"))
                rec = bool(records_of(o)) if o not in (None, "deny") else bool(v.get("record"))
                v["state_npm"] = {}
                for sh, cs in calls.items():
                    cs = [c for c in cs if install_call(c)]
                    if not cs:
                        v["state_npm"][sh] = "NOCALL"
                    elif all(npm_reads(c) == "true" for c in cs):
                        v["state_npm"][sh] = "FLAG"
                    else:
                        v["state_npm"][sh] = "REC" if rec else "SILENT"

    classes = []
    cpath = os.path.join(MEASURE, "core-intended-inert.tsv")
    if os.path.exists(cpath):
        for line in open(cpath, encoding="utf-8"):
            if not line.strip() or line.startswith("#"):
                continue
            cname, toks, free, pat, reason = line.rstrip("\n").split("\t")[:5]
            classes.append((cname, set(toks.split(",")), free == "yes", re.compile(pat, re.S), reason))

    counts = {"compared": 0, "same": 0, "both_undecided": 0, "differ": 0, "unclassified": 0, "decrease": 0, "payload_free_differ": 0,
              "not_reached": 0, "core_error": 0, "reading_set": 0}
    per_class = {}
    for res in results:
        cmd = res["command"]
        cb = cmd.encode("utf-8", "surrogateescape")
        ref = {k: v.encode("latin-1") for k, v in res["ref"].items()}
        got = {k: v.encode("latin-1") for k, v in res["core"].items()}
        if res["core_rc"] != 0:
            counts["core_error"] += 1
            res["status"] = "core-error"
            continue
        if not ref:
            res["status"] = "bash-not-reached"
            counts["not_reached"] += 1
            continue
        counts["compared"] += 1
        if ref.get("reading_set") != got.get("reading_set"):
            res["status"] = "reading-set"
            counts["reading_set"] += 1
            continue
        toks = set()
        bden = cden = False
        bfail, cfail = ref.get("failed") == b"true", got.get("failed") == b"true"
        if bfail and cfail:
            toks = set()
        elif cfail and not bfail:
            toks.add("+undecided")
        elif bfail and not cfail:
            toks.add("-undecided")
        if not (bfail and cfail):
            rs = ref.get("reading_set", b"").decode().split()
            bvals = [ref.get("inert." + r) for r in rs]
            cvals = [got.get("inert." + r) for r in rs]
            bden = len(set(bvals)) > 1
            cden = len(set(cvals)) > 1
            res["readings_differ"] = {"bash": bden, "core": cden}
            if cden and not bden:
                # The core's readings put the flags in different places (their
                # values differ byte for byte), so no rewrite is sent and the
                # command is UNDECIDED: nothing runs on the core's side.
                toks.add("+deny:readings-disagree")
                res["core_readings"] = {r: (v or b"").decode("latin-1") for r, v in zip(rs, cvals)}
            else:
                if bden and not cden:
                    toks.add("-deny")
                for r, bv, cv in zip(rs, bvals, cvals):
                    if bv == cv:
                        continue
                    toks |= tokens(outcome(bv, cb), outcome(cv, cb))
        if not toks:
            res["status"] = "same"
            counts["same"] += 1
            continue
        if not (bfail and cfail) and bden and cden:
            # The readings disagree on both sides: no rewrite is sent on
            # either, and the command is UNDECIDED on both. The values the
            # readings hold differ, which changes nothing that runs.
            res["status"] = "both-undecided"
            res["tokens"] = sorted(toks)
            counts["both_undecided"] += 1
            continue
        counts["differ"] += 1
        res["tokens"] = sorted(toks)
        p3 = res.get("payloads3")
        if p3:
            free = all(v == 0 for v in p3.values())
            res["payload_free_basis"] = "three readings"
        else:
            free = got.get("payloads.bash") == b"0"
            res["payload_free_basis"] = "bash reading only (a report from before the three-reading count)"
        res["payload_free"] = free
        if free:
            counts["payload_free_differ"] += 1
        if cmd == ARGUMENT_SUBSTITUTION_INPUT:
            why = argument_substitution_preserved(res)
            if why is None:
                res["status"] = "class:argument-substitution-preserved"
                per_class["argument-substitution-preserved"] = per_class.get("argument-substitution-preserved", 0) + 1
                continue
            res["class_refused"] = why
        if any(t.startswith("-") or t.startswith("?") for t in toks):
            # Two mechanical readings of a decrease, listed apart for the plan
            # owner's decision and not counted as named: the same npm calls in
            # every shell, or the core's calls all true where the bash side's
            # are not.
            if not any(t.startswith("-rec") or t.startswith("-deny") or t.startswith("-undecided") for t in toks) and argv_equal(res):
                res["status"] = "decrease:argv-equal"
            elif core_exact(res):
                res["status"] = "decrease:core-dominates" if bash_worse(res) else "decrease:core-exact"
            else:
                res["status"] = "decrease"
            counts[res["status"]] = counts.get(res["status"], 0) + 1
            continue
        cls = None
        dirs = set(t for t in toks if not t.startswith("~"))
        for (cname, ctoks, cfree, pat, reason) in classes:
            if cname in CODE_CHECKED:
                continue
            if dirs <= ctoks and (cfree or not free) and pat.search(cmd):
                cls = cname
                break
        if cls is None and dirs <= {"+flag", "+rec"}:
            why = word_value_read(res)
            if why is None:
                cls = "word-value-read"
            else:
                res["class_refused"] = why
        if cls is None:
            res["status"] = "unclassified"
            counts["unclassified"] += 1
        else:
            res["status"] = "class:" + cls
            per_class[cls] = per_class.get(cls, 0) + 1

    loss = []
    silent_core = []
    silent_core_npm = []
    # Core-only: SILENT in a shell where the bash side is not.
    only_silent = {"flag words": [], "npm reader": []}
    loss_npm = []
    for res in results:
        sides = res.get("sides", {})
        sn = sides.get("core", {}).get("state_npm")
        if isinstance(sn, dict) and any(v == "SILENT" for v in sn.values()):
            silent_core_npm.append(res)
        for key, field in (("flag words", "state"), ("npm reader", "state_npm")):
            c = sides.get("core", {}).get(field)
            b = sides.get("bash", {}).get(field)
            if isinstance(c, dict) and any(v == "SILENT" and (not isinstance(b, dict) or b.get(sh) != "SILENT") for sh, v in c.items()):
                only_silent[key].append(res)
        rn = sides.get("v2.18.1", {}).get("state_npm")
        if isinstance(sn, dict) and isinstance(rn, dict):
            for sh, v in sn.items():
                if v == "SILENT" and rn.get(sh, "SILENT") != "SILENT":
                    loss_npm.append((res, sh, rn.get(sh), v))
                    break
        cs = sides.get("core", {}).get("state")
        if isinstance(cs, dict):
            if any(v == "SILENT" for v in cs.values()):
                silent_core.append(res)
            rs = sides.get("v2.18.1", {}).get("state")
            if rs == "DENY":
                continue
            if isinstance(rs, dict):
                for s, v in cs.items():
                    if v == "SILENT" and rs.get(s, "SILENT") != "SILENT":
                        loss.append((res, s, rs.get(s), v))
                        break
    # The record invariant's reach (inert-record-invariant.sh): a form that
    # makes fewer npm calls on the core's side, in bash or zsh, than
    # inert-record-reach.tsv names never reached its npm and cannot fail.
    reach = {}
    rpath = os.path.join(MEASURE, "inert-record-reach.tsv")
    if os.path.exists(rpath):
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
        for line in open(rpath, encoding="utf-8"):
            fid, n = line.rstrip("\n").split("\t")
            if fid in ids:
                reach[ids[fid]] = (fid, int(n))
    short = []
    for res in results:
        if res["command"] not in reach:
            continue
        calls = res.get("sides", {}).get("core", {}).get("calls")
        if not isinstance(calls, dict):
            continue
        made = max(len(calls.get("bash", [])), len(calls.get("zsh", [])))
        fid, need = reach[res["command"]]
        res["reach"] = "%s %d/%d" % (fid, made, need)
        if made < need:
            short.append(res)
    floor = {}
    for res in results:
        if "floor" in res:
            floor[res["floor"]] = floor.get(res["floor"], 0) + 1

    print("load start: %s" % up0)
    print("load end:   %s" % up1)
    for k, v in counts.items():
        print("%-22s %d" % (k, v))
    for k in sorted(per_class):
        print("  class %-30s %d" % (k, per_class[k]))
    if a.floor:
        print("release floor: %s" % ", ".join("%s %d" % (k, v) for k, v in sorted(floor.items())))
    if shells is not None or a.reclassify:
        print("core SILENT (an npm call without the flag, no record): %d" % len(silent_core))
    if a.npm_read:
        print("core SILENT by the gate's npm reader: %d" % len(silent_core_npm))
        for res in silent_core_npm[:20]:
            print("SILENT-npm %s %r %s" % (res["set"], res["command"], res["sides"]["core"].get("state_npm")))
    for key, rows_ in only_silent.items():
        print("core-only SILENT (%s): %d" % (key, len(rows_)))
        for res in rows_[:10]:
            print("CORE-ONLY-SILENT %s %s %r" % (key, res["set"], res["command"]))
    if rel_guard or a.reclassify:
        print("LOSS against v2.18.1 (flag words): %d" % len(loss))
        if a.npm_read:
            print("LOSS against v2.18.1 (npm reader): %d" % len(loss_npm))
            for res, sh, rv, cv in loss_npm[:20]:
                print("LOSS-npm %s %r shell=%s v2.18.1=%s core=%s" % (res["set"], res["command"], sh, rv, cv))
    if reach:
        print("reach: %d forms with a reach number judged, SHORT %d" % (sum(1 for r in results if "reach" in r), len(short)))
        for res in short[:20]:
            print("SHORT %s %r" % (res["reach"], res["command"]))
    shown = 0
    for res in results:
        if res.get("status") in ("unclassified", "decrease", "decrease:core-dominates", "reading-set", "core-error") or str(res.get("floor", "")).startswith("NOT"):
            shown += 1
            if shown > 40:
                break
            print("%s %s %r tokens=%s free=%s%s" % (res.get("status"), res["set"], res["command"], res.get("tokens"), res.get("payload_free"),
                                                   (" refused: " + res["class_refused"]) if res.get("class_refused") else ""))
            for r in res["ref"].get("reading_set", "").split():
                print("   bash %-5s %r" % (r, res["ref"].get("inert." + r)))
                print("   core %-5s %r" % (r, res["core"].get("inert." + r)))
            for side, v in res.get("sides", {}).items():
                print("   argv %-7s %s %s" % (side, v.get("state"), json.dumps(v.get("calls"), ensure_ascii=False)[:400]))
    for res, s, rv, cv in loss[:20]:
        print("LOSS %s %r shell=%s v2.18.1=%s core=%s" % (res["set"], res["command"], s, rv, cv))
    for res in silent_core[:20]:
        print("SILENT %s %r %s" % (res["set"], res["command"], res["sides"]["core"].get("state")))
    if a.table:
        with open(a.table, "w", encoding="utf-8") as f:
            for res in results:
                f.write("%s\t%s\t%s\t%s\t%s\n" % (res["set"], res.get("status", ""), ",".join(res.get("tokens") or []),
                                                    res.get("bash_exit", ""), json.dumps(res["command"], ensure_ascii=False)))
    if a.report and a.reclassify:
        json.dump({"counts": counts, "classes": per_class, "floor": floor, "loss": len(loss), "silent_core": len(silent_core),
                   "silent_core_npm": len(silent_core_npm), "load": [up0, up1], "reclassified_from": a.reclassify, "rows": results},
                  open(a.report, "w"), ensure_ascii=False, indent=1)
    if a.report and not a.reclassify:
        # A --release-only pass writes its own report beside the one it read.
        json.dump({"counts": counts, "classes": per_class, "floor": floor, "loss": len(loss), "silent_core": len(silent_core),
                   "load": [up0, up1], "rows": results}, open(a.report, "w"), ensure_ascii=False, indent=1)
    shutil.rmtree(work, ignore_errors=True)
    if a.control:
        print("control: the damaged reference differs on %d commands" % counts["differ"])
        sys.exit(0 if counts["differ"] else 1)
    # A decrease is red whichever of its three readings it has, and so is a
    # floor row of any NOT kind, a reading set that differs, and either check
    # of LOSS and SILENT.
    bad = (counts["unclassified"] + sum(v for k, v in counts.items() if k.startswith("decrease")) + counts["core_error"] + counts["reading_set"]
           + len(loss) + len(loss_npm) + len(silent_core) + len(silent_core_npm)
           + sum(v for k, v in floor.items() if k.startswith("NOT")) + len(short))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
