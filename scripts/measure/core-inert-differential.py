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

Every row has one status, and the counts add up: total = invalid +
core-error + bash-not-reached + compared, and compared = reading-set +
incomplete + both-failed + blocked + blocked+failed + both-undecided + same +
differ.

  invalid          the row's own records are not what this file writes (see
                   The intake); it gets no other status, and the run is red
  reading-set      the two sides read the command in different sets of readings
  incomplete       a reading of the set has no value on one side
  both-failed      the reading failed on both sides (UNDECIDED on both)
  blocked:<kind>   a reading of the core holds `collision <kind>`: the duties of
                   the rewrite (the release's bytes, the arguments and data of
                   the command as written, a flag npm reads as the option)
                   cannot be met together, so the core sends no rewrite and the
                   command is UNDECIDED. This is the core's own reason, whether
                   its readings agree or not and whatever the bash side does.
                   A blocked row is no agreement and no success: it is in no
                   count of `same`, of a floor kept, or of a call that kept its
                   flag, and it is listed with what the bash side's command did.
  blocked+failed   the same where a reading of the core failed too: a failed
                   reading is another reason, so the row is red
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
scripts/measure/core-intended-inert.tsv, or it is `unclassified`. One exact
input, `npm i y && env -S'npm ci x'`, is named script-payload-read by its
conditions (env_split_string_read: the flag's one place, the core's own
account of where it read the string, the floor, the record, and in every shell
the two calls, what npm reads of them and everything else the run left), never
by that class's pattern, which is not widened; `class_basis` says so on the
row. A
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
of the core's flags gives the release's (release-floor.sh's property). With
--floor-tree, an extracted 7d66f8c's whole pre-guard is asked of every row and
the rewrite it sends is that row's floor, where the recorded file has none;
what its command does under the shells is kept like any side's. A rewrite the
core sends with no floor to hold it to is `unmeasured`, never `ok`.

The report
----------

What --report writes is a report of contract `core-inert-report/3` (the
field table is in the evidence of the plan that made it). It holds two
things apart:

- `source`: the bytes of the one input that holds the observations, as they
  were read, once, base64, with their sha256 and schema. For a live run that
  is the snapshot the run wrote of what it observed, before anything was
  evaluated: its run, its rows, the readers' answers it asked for, and the
  head guard's answers for the rows found SILENT. For --reclassify it is the
  file given, or, given a v3 report, that report's own source. `attachments`
  are the other inputs, bytes and sha256 each: A's words records (`words`,
  with the sha256 of the core that produced them) and the recorded release
  rewrites a row's floor is held to (`floor-rewrites`).
- `evaluation`: everything this classification derived, and `emitted_by`, the
  classifier that derived it.

Nothing of the source is ever rewritten. A replay of a v3 report reads its
source and attachments and nothing else, and derives everything again: a
contradiction in the source (a saved floor at odds with its basis, a reader
entry that is malformed) is found again every time, and no earlier verdict is
read as a fact. The same source, attachments, contract and classifier give
the same rows, issues and denominators however often they are replayed and
wherever the output is written. An output that is the same file as an input
or an attachment (by device and inode) is refused.

The run that measured a source is its own `run`. A first-schema report kept
none, and a schema 2 report a classification wrote (`run.reclassified_from`)
names the report it classified, not a measurement: both are `unknown`
provenance, and no row of them counts as held. A schema 2 report without a
run, or with one this file does not write, is invalid. The classifier's own
record never stands in for the measurement.

The intake
----------

Every row passes one admission before anything classifies or counts it,
whether it was measured in this run or read from a saved report; nothing after
it reads a field the admission did not look at. It works on a copy of the
source's row; derived values an older classification wrote into a source
(statuses, observations, states, labels) are left out of the evaluation and
computed again. It binds the row to where it came from (the source's sha256,
the row's ordinal, the sha256 of the command's bytes, the schema). And it
sorts every field into evidence, `unknown` (not recorded, or not observable:
a run killed at its deadline, a log that does not decode, a file that could
not be read, an axis the first schema did not keep) and `invalid` (recorded,
and not what this file writes, or at odds with another record of the same
row).

- The admission makes one slot per row of the source, in its order, bound to
  the source's sha256, the row's ordinal and its place in the source (a JSON
  pointer). A slot is `admitted` or `rejected`, and nothing after the
  admission reads anything but slots: the statuses, the accounting, the
  summary, the table, the manifest and the report are projections of them.
- A row whose own records are invalid is `invalid` and nothing else: a slot
  that is not an object, a reading set with a name twice or a name this file
  does not know, a value for a reading outside the set, no `any_install`, no
  payload counts or a `sides` that is not an object in this schema. Its slot
  is `rejected`: it keeps its ordinal, the row's JSON type, its set and its
  command where they are strings, and where and why it was rejected, and no
  other field of the row. The values are in the source, at the pointer named.
- Inside an admitted row, what is not what this file writes is rejected the
  same way, with its pointer and why, and the rest of the row keeps its
  evidence: a side (it stands in its place as `decision` invalid), a side's
  runs, a shell's run that is not an object (it stands in its place as a
  rejected run, invalid on every axis and never read as a shell that did not
  run, and the other shells keep theirs), A's words that do not read,
  `stand_ins` and `expect`. A side this file does not write and a shell it
  does not run are left out, and so is any field it does not read.
- `any_install` is decoded once per side and every consumer reads that
  decoding. The core's payload count of a reading, A's words of the same text,
  reading and core, and the row's stored count are records of one fact, each
  pair compared where both are there (the core's only where the text it read
  is the text A read).
- A side that ran names the bytes it ran: the command itself for the command
  as written, what its readings agree on for the bash and core sides, and for
  a tree's pre-guard bytes whose insertions are its `flags`. A side that sends
  nothing (blocked, undecided) has no runs, and needs none.
- A run's axes are its npm calls, the order of every stand-in call, the other
  calls, the exit status, stdout, stderr and the files. Its `calls` are the
  record, in order; its npm calls and its other calls are that list cut in
  two, and where the three disagree they are invalid. An exit status that is
  not 0, an empty argument and an empty stream are evidence like any other.
- Two runs compare on an axis only where both hold it as evidence: a null is
  never equal to a null. A row with any invalid evidence is listed, is in no
  count of what held, and makes the run red.
- The floor is computed again from the basis the row declares: the recorded
  release rewrites (attached), or the 7d66f8c side's run. A saved floor that
  is not that is invalid; one saved with no basis, or held to rewrites not
  attached, is unknown. A --floor request is not a basis.
- A side's record that the run did not keep is computed from its value and
  kept apart (`_record`), never written as one the run kept.

The readers' answers are part of what a run keeps, each bound to its argv.
--reclassify reads the saved answers and asks no reader: an argv with no
saved answer is unknown and is not asked, and an argv answered twice is
believed in neither answer. --reread asks the readers on this host's PATH
again, as a separate observation the report names as such.

A's words records of a command (`safedeps-core words`: its payloads and their
source maps, per reading) are read from the row when the run kept them, or
from a file named with --words PATH=SHA256:PRODUCER, whose bytes must hash to
the sha256 named and which binds only to a source measured with the core whose
sha256 is PRODUCER. Such a file holds, per command, a line `== <the command
as JSON>`, and per reading a line `-- <reading> rc <n>` followed by that
reading's output. --floor-rewrites PATH=SHA256 attaches the recorded release
rewrites. Nothing else is read for them: no manifest, no copy of a value, and
no file of the current tree.

A report of a schema this file does not read, and an attachment that does not
hash or does not read, end the run with exit 2 before anything is classified.

The accounting
--------------

After the statuses the run prints what it observed, axis by axis, each number
with the rows it is over:

  the core, row by row     sent, as-written, blocked, undecided, unobserved
  the rows that ran        by their npm calls and by their effects beside the
                           command as written; a rewrite the core sends whose
                           calls or effects do not hold is red, whatever its
                           status and whatever the bash side does
  beside the bash side, v2.18.1 and 7d66f8c
                           rows and shell runs paired, install calls paired by
                           their order, calls that go from a true
                           ignore-scripts to a false one (red beside the bash
                           side and v2.18.1, recorded or not), calls lost,
                           added or changed, what was unknown, and the rows
                           that were not paired with why
  new SILENT               the rows and shell runs where the core's state is
                           SILENT and the other side's is not, over the pairs
                           whose states are both known; `LOSS against v2.18.1`
                           is this number and nothing wider. No state is
                           compared beside 7d66f8c: its record lines are not
                           the ones this file reads

A row of an --extra file may carry "expect" (`sent`, `as-written`, `blocked`,
`blocked:<kind>`, `undecided`): a row that is not what its line says is red.
It may carry "stand_ins": "sudo-print", which runs every side of that row
with a sudo that writes its arguments down, prints them and runs nothing,
where the default one runs them.

Commands are data: each reaches the guards and the core as a JSON payload on
standard input, and the shells as an argument. No package manager runs.

--sets names corpora; --extra alone runs only the files it names; neither runs
every corpus. --list writes the selection and runs nothing. --reclassify
classifies a saved report again and runs no guard, no shell and no reader; a
report of the first schema is read with every axis it did not record as
`unknown`.
--manifest writes one line for the run and one per row. --selftest checks the
observation and the statuses against cases each of which an earlier version
of this file got wrong.

Exit: 0 only when every row is `same`, a named difference the shells show
to hold (or one where nothing runs on the core's side), or `blocked`, and
nothing in the accounting or the intake is red; 1 otherwise; 2 when a report
or an attachment cannot be read. A row undecided on both sides, any
`decrease:` row, any row not observed, an invalid row, a row with invalid
evidence and a reader answer that is not believed are red. A blocked row is
not red and not green: it is counted apart.
A named row whose npm calls are lost on both sides alike is listed as
`shared-loss` and is not the core's red.
--control and --selftest have their own.

Usage:
  core-inert-differential.py --core <safedeps-core> [--jobs 1] [--sets a,b]
      [--extra name=FILE.jsonl ...] [--shells | --evidence] [--floor]
      [--floor-tree DIR]
      [--release-tree DIR --approve eco:name:version ...] [--path-prefix DIRS]
      [--limit N] [--report FILE] [--table FILE] [--manifest FILE]
      [--list FILE] [--control]
  core-inert-differential.py --reclassify REPORT [--reread --path-prefix DIRS]
      [--words PATH=SHA256:PRODUCER ...] [--floor-rewrites PATH=SHA256]
      [--report FILE] [--table FILE] [--manifest FILE]
  core-inert-differential.py --selftest [--path-prefix DIRS]
"""
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

SCHEMA = 2
# What --report writes: the source kept as bytes and the evaluation apart
# (see The report).
CONTRACT = "core-inert-report/3"
UNKNOWN = "unknown"
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
GUARD = os.path.join(ROOT, "scripts", "safedeps-pre-guard.sh")
MEASURE = os.path.join(ROOT, "scripts", "measure")
TEST = os.path.join(ROOT, "scripts", "test")
FLAG = b" --ignore-scripts"
FLAGWORD = "--ignore-scripts"
NOTES = ("asked", "unverified", "floor", "unread", "release")
SHELLS = ("bash", "zsh", "dash", "zsh-agent")
COLLISION = b"collision "
READING_NAMES = ("bash", "zsh", "dash")
HEX64 = re.compile("^[0-9a-f]{64}$")
FLOOR_FILE = "scripts/test/inert-release-rewrites.json"
FLOOR_TREE = "the --floor-tree pre-guard's own answer"
# A run's axes as the intake sorts them; EFFECTS are those beside the npm
# calls, compared between two runs as they are. The exit status comes first.
AXES = ("npm", "order", "other", "rc", "stdout", "stderr", "files")
EFFECTS = ("rc", "stdout", "stderr", "other", "order", "files")

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
# Another sudo, for a row that names it ("stand_ins": "sudo-print"): it writes
# its call down, prints its arguments and runs nothing. Which of the two a
# real sudo is like is not the comparison's to say; a rewrite that holds under
# one and changes what the other prints has put a flag into data.
STUB_SUDO_PRINT = '#!/bin/sh\nprintf \'%s\\0\' sudo "$#" "$@" >> "$NPMLOG"\nprintf \'%s\\n\' "$@"\n'
STAND_INS = ("", "sudo-print")
# Every program a stand-in writes a call for: a call of any other name in a
# saved log was not written by this file.
PROGRAMS = frozenset(["npm", "npx", "sudo"] + OTHERS)

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


def blocked_kinds(recs):
    """The collision kinds the readings hold (`collision <kind>`): the duties
    of the rewrite cannot be met together there, so no rewrite is sent and the
    command is UNDECIDED, whether the readings agree or not."""
    _, vals = readings(recs)
    return sorted(set(v[len(COLLISION):].decode("latin-1") for v in vals if v is not None and v.startswith(COLLISION)))


def consensus(recs, cmd):
    """The value every reading agrees on, 'blocked' where a reading holds a
    collision, 'deny' where they differ, None where a reading has none."""
    rs, vals = readings(recs)
    if not vals or any(v is None for v in vals):
        return None
    if blocked_kinds(recs):
        return "blocked"
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


def _grammar_value(name):
    for line in open(os.path.join(ROOT, "lib", "install-grammar.sh"), encoding="utf-8"):
        if line.startswith(name + "='"):
            return line[len(name) + 2:line.rindex("'")]
    raise SystemExit("core-inert-differential: %s is not in lib/install-grammar.sh" % name)


INSTALL_VERB = re.compile("^(%s|%s)$" % (_grammar_value("SAFEDEPS_G_NPM_VERBS"), _grammar_value("SAFEDEPS_G_NPM_LINK_VERBS")), re.I)


def reader_install(argv, g, n):
    """Whether a call's command is an install or link verb, from the two
    readers' answers for its argv: True or False where both say so, None
    where one could not answer or the two disagree."""
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


def reader_flagged(g, n):
    """Whether ignore-scripts ends true: both readers' answer, or None."""
    if g is None or n is None or not g.get("read"):
        return None
    gt, nt = g["ignore"] == "true", n["ignore"] == "true"
    return gt if gt == nt else None


def reader_rest(g, n):
    """Everything the readers found but ignore-scripts: two argvs with the
    same rest differ at most in that option. None where a reader did not
    answer."""
    if g is None or n is None or not g.get("read"):
        return None
    return (tuple(g["words"]), tuple(g["switches"]), tuple(g["values"]), tuple(n["remain"]))


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
        return reader_install(argv, self.gate.get(tuple(argv)), self.npm.get(tuple(argv)))

    def flagged(self, argv):
        return reader_flagged(self.gate.get(tuple(argv)), self.npm.get(tuple(argv)))

    def rest(self, argv):
        return reader_rest(self.gate.get(tuple(argv)), self.npm.get(tuple(argv)))

    def answers(self):
        """Every argv asked, with what each reader said, for the report."""
        return [{"argv": list(a), "gate": self.gate.get(a), "npm": self.npm.get(a),
                 "install": self.install(list(a)), "flagged": self.flagged(list(a))} for a in sorted(self.gate)]


# ---------------------------------------------------------------------------
# The intake (see the header): one admission of every row's evidence.
# ---------------------------------------------------------------------------

class Unsupported(Exception):
    """A report or an attachment this file cannot read: the run ends with
    exit 2 before anything is classified."""


MISSING = object()


def _is_int(x):
    return isinstance(x, int) and not isinstance(x, bool)


def _strs(x):
    return isinstance(x, list) and all(isinstance(y, str) for y in x)


def _argvs(x):
    return isinstance(x, list) and all(_strs(y) for y in x)


def enc(recs):
    """A side's records as the bytes they were read as."""
    return {k: v.encode("latin-1") for k, v in recs.items()}


def reader_entry_problem(e):
    """What is wrong with one saved reader answer, or None. An answer is the
    argv it is for and what each reader said: null where a reader could not
    be asked, else exactly the fields GATE_READER and NPM_READER give."""
    if not isinstance(e, dict):
        return "not an object"
    if not _strs(e.get("argv")):
        return "argv is not a list of strings"
    if "gate" not in e or "npm" not in e:
        return "a reader's answer is not there (null stands for one not asked)"
    g, n = e["gate"], e["npm"]
    if g is not None:
        if not isinstance(g, dict) or not isinstance(g.get("read"), bool):
            return "the gate reader's answer is not one it gives"
        if g["read"]:
            if (set(g) != {"read", "ignore", "words", "switches", "values"} or g["ignore"] not in ("true", "false", "unset")
                    or not all(_strs(g[f]) for f in ("words", "switches", "values"))):
                return "the gate reader's answer is not one it gives"
        elif set(g) != {"read"}:
            return "the gate reader's answer is not one it gives"
    if n is not None:
        if (not isinstance(n, dict) or set(n) != {"remain", "ignore", "canon"} or not _strs(n["remain"])
                or n["ignore"] not in ("true", "false", "unset") or not (n["canon"] is None or isinstance(n["canon"], str))):
            return "npm's own parser's answer is not one it gives"
    return None


class SavedReaders:
    """The readers' answers a run kept, admitted once, each bound to the exact
    argv it is for. Nothing is asked: an argv with no admitted answer is
    unknown, one answered twice is believed in neither answer, and no gap is
    filled by asking again. `source` says where the answers come from. What
    an entry says it derived (`install`, `flagged`) is not read: it is
    computed again from the two answers, and an entry where the two differ is
    counted in `rederived`."""

    def __init__(self, entries, source):
        self.source = dict(source)
        self.gate, self.npm, self.problems, self.rederived = {}, {}, [], 0
        twice = set()
        if entries is not None and not isinstance(entries, list):
            self.problems.append("readings: not a list")
            entries = []
        for k, e in enumerate(entries or []):
            why = reader_entry_problem(e)
            if why:
                self.problems.append("readings[%d]: %s" % (k, why))
                continue
            key = tuple(e["argv"])
            if key in self.gate or key in twice:
                self.problems.append("readings[%d]: %s is answered twice" % (k, json.dumps(e["argv"])))
                twice.add(key)
                self.gate.pop(key, None)
                self.npm.pop(key, None)
                continue
            self.gate[key], self.npm[key] = e["gate"], e["npm"]
            for f, v in (("install", reader_install(e["argv"], e["gate"], e["npm"])), ("flagged", reader_flagged(e["gate"], e["npm"]))):
                if f in e and e[f] != v:
                    self.rederived += 1
                    self.problems.append("readings[%d]: it says %s %r, and its two answers give %r" % (k, f, e[f], v))
        self.npm_asked = any(n is not None for n in self.npm.values())
        self.npm_version = self.source.get("npm_version") or ""
        self.npm_error = self.source.get("npm_error") or ("" if self.npm_asked else "no answer of npm's own parser is held")

    def install(self, argv):
        return reader_install(argv, self.gate.get(tuple(argv)), self.npm.get(tuple(argv)))

    def flagged(self, argv):
        return reader_flagged(self.gate.get(tuple(argv)), self.npm.get(tuple(argv)))

    def rest(self, argv):
        return reader_rest(self.gate.get(tuple(argv)), self.npm.get(tuple(argv)))

    def answers(self):
        """Every admitted answer, for the report: what a later replay reads."""
        return [{"argv": list(a), "gate": self.gate[a], "npm": self.npm[a], "install": self.install(list(a)),
                 "flagged": self.flagged(list(a))} for a in sorted(self.gate)]


def _stream(o, name):
    n, h, t = o.get(name + "_len"), o.get(name + "_sha256"), o.get(name)
    if not (_is_int(n) and n >= 0 and isinstance(h, str) and HEX64.match(h) and isinstance(t, str) and len(t) == min(n, 2000)):
        return "invalid", "not a length, a sha256 and the first bytes"
    if n <= 2000 and sha256(t.encode("latin-1", "replace")) != h:
        return "invalid", "the bytes kept are not the sha256's"
    return "ok", None


def _files(f):
    if not isinstance(f, dict):
        return "invalid", "not a listing"
    unreadable = False
    for k, v in f.items():
        if not isinstance(v, list) or not v:
            return "invalid", "%s is not an entry" % k
        t = v[0]
        if t == "d" and len(v) == 1:
            continue
        if t == "l" and len(v) == 2 and isinstance(v[1], str):
            continue
        if t == "f" and len(v) == 3 and _is_int(v[1]) and v[1] >= 0 and isinstance(v[2], str) and HEX64.match(v[2]):
            continue
        if t == "?" and len(v) == 2 and isinstance(v[1], str):
            unreadable = True
            continue
        return "invalid", "%s is not an entry" % k
    return ("unknown", "a file could not be read") if unreadable else ("ok", None)


def admit_obs(o, schema):
    """Sorts one shell's run into its axes (AXES): `ok`, `unknown` or
    `invalid`, each with why where it is not ok. Sets `_axes` and `_why` on
    the run and returns (axis, kind, why) for each axis that is not ok."""
    ax, why = {}, {}

    def put(axis_, val, reason=None):
        ax[axis_] = val
        if reason:
            why[axis_] = reason

    if not isinstance(o, dict):
        return [(x, "invalid", "the run is not an object") for x in AXES]
    for k in [k for k in o if k.startswith("_")]:
        del o[k]
    if schema == 1:
        if o.get("lossy"):
            put("npm", UNKNOWN, "the first schema split its arguments at tabs and newlines")
        elif o.get("log") == "ok" and _argvs(o.get("npm")):
            put("npm", "ok")
        else:
            put("npm", UNKNOWN, "the first schema kept no npm calls that read")
        for x in AXES[1:]:
            put(x, UNKNOWN, "the first schema did not keep it")
    else:
        rc, to = o.get("rc", MISSING), o.get("timeout", MISSING)
        timed = to is True
        if not isinstance(to, bool):
            put("rc", "invalid", "timeout is not true or false")
            timed = True
        elif rc == "timeout" or (_is_int(rc) and rc == -14):
            if to:
                put("rc", UNKNOWN, "killed at its deadline")
            else:
                put("rc", "invalid", "a deadline's exit status, and timeout false")
        elif _is_int(rc):
            if to:
                put("rc", "invalid", "timeout true, and an exit status of its own")
            else:
                put("rc", "ok")
        else:
            put("rc", "invalid", "not an exit status")
        log, calls = o.get("log"), o.get("calls", MISSING)
        if log == "undecodable":
            if all(o.get(k) == UNKNOWN for k in ("calls", "npm", "other")):
                for x in ("npm", "order", "other"):
                    put(x, UNKNOWN, "its log does not decode")
            else:
                for x in ("npm", "order", "other"):
                    put(x, "invalid", "calls held for a log that does not decode")
        elif log == "ok" and isinstance(calls, list) and all(_strs(y) and y and y[0] in PROGRAMS for y in calls):
            npm_ok = o.get("npm") == [y[1:] for y in calls if y[0] == "npm"]
            other_ok = o.get("other") == [y for y in calls if y[0] != "npm"]
            put("npm", "ok" if npm_ok else "invalid", None if npm_ok else "npm is not the npm calls of calls")
            put("other", "ok" if other_ok else "invalid", None if other_ok else "other is not the other calls of calls")
            put("order", "ok")
            if timed:
                for x in ("npm", "order", "other"):
                    if ax[x] == "ok":
                        put(x, UNKNOWN, "killed at its deadline: its calls may stop short")
        else:
            for x in ("npm", "order", "other"):
                put(x, "invalid", "no calls of stand-ins in the order they ran" if log == "ok" else "log is neither ok nor undecodable")
        for x in ("stdout", "stderr"):
            put(x, *_stream(o, x))
        put("files", *_files(o.get("files", MISSING)))
        if "lossy" in o:
            for x in ("npm", "order", "other"):
                put(x, "invalid", "a run of this schema is never split at blanks")
    o["_axes"], o["_why"] = ax, why
    return [(x, ax[x], why.get(x, "")) for x in AXES if ax[x] != "ok"]


def side_record(v):
    """A side's record: as its run kept it, else as its value carries it
    (`_record`, computed by the intake and never written as one kept)."""
    if not isinstance(v, dict):
        return False
    r = v.get("record", MISSING)
    if isinstance(r, bool):
        return r
    return bool(v.get("_record"))


def axis(o, name):
    """An admitted run's axis: `ok`, `unknown` or `invalid`. A run the intake
    did not see is evidence of nothing."""
    ax = o.get("_axes") if isinstance(o, dict) else None
    if not isinstance(ax, dict):
        return UNKNOWN
    return ax.get(name, UNKNOWN)


def jtype(x):
    """The JSON type of a value, as a rejection names it."""
    if x is MISSING:
        return "missing"
    if x is None:
        return "null"
    if isinstance(x, bool):
        return "boolean"
    if isinstance(x, (int, float)):
        return "number"
    return {str: "string", list: "array", dict: "object"}.get(type(x), type(x).__name__)


def pointer(*parts):
    """A JSON pointer (RFC 6901) into the source."""
    return "".join("/" + str(p).replace("~", "~0").replace("/", "~1") for p in parts)


def rejected_run(at):
    """A shell's run that is not an object, in its place: invalid on every
    axis, so that it is never read as a shell that did not run. Its value is
    in the source at `at`."""
    return {"rejected": at, "_axes": {x: "invalid" for x in AXES}, "_why": {x: "the run is not an object" for x in AXES}}


def admitted(results):
    """The slots the intake admitted: the only ones whose facts are read."""
    return [res for res in results if res.get("slot") == "admitted"]


def records_problem(recs, who, schema=SCHEMA):
    """What is wrong with one side's inert records, or None. A reading with
    no value is not this: it is the status `incomplete`."""
    if not isinstance(recs, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in recs.items()):
        return "%s: the records are not names and values" % who
    try:
        enc(recs)
    except UnicodeEncodeError:
        return "%s: a value is not the bytes it was read as" % who
    if not recs:
        return None
    raw = recs.get("reading_set")
    if not isinstance(raw, str):
        return "%s: no reading set" % who
    rs = raw.split()
    inst = recs.get("any_install")
    if inst is None:
        if schema != 1:
            return "%s: no any_install: this schema writes it for every command" % who
    elif inst not in ("true", "false"):
        return "%s: any_install is neither true nor false" % who
    if recs.get("failed") not in ("true", "false"):
        return "%s: failed is neither true nor false" % who
    if raw != " ".join(rs):
        return "%s: the reading set is not names one blank apart" % who
    strange = [r for r in rs if r not in READING_NAMES]
    if strange:
        return "%s: a reading this file does not know (%s)" % (who, strange[0])
    if len(set(rs)) != len(rs):
        return "%s: a reading named twice" % who
    outside = [k for k in recs if "." in k and k.split(".", 1)[0] in ("inert", "payloads", "detail") and k.split(".", 1)[1] not in rs]
    if outside:
        return "%s: a value for a reading outside the set (%s)" % (who, outside[0])
    if inst == "false" and any(k.startswith("inert.") for k in recs):
        return "%s: a reading's value for a command it reads no install in" % who
    if inst != "false" and not rs:
        return "%s: an install read in no reading" % who
    return None


SIDE_DECISIONS = {"written": ("run",), "bash": ("run", "deny", "blocked"), "core": ("run", "deny", "blocked"),
                  "v2.18.1": ("run", "deny"), "7d66f8c": ("run", "deny"), "head": ("allow", "deny")}
# The fields of a row the intake reads. Any other field (a value an older
# classification derived, or one this file does not write) is not carried.
ROW_FIELDS = ("set", "command", "core_rc", "bash_rc", "bash_exit", "bash_timeout", "ref", "core", "payloads3", "sides",
              "stand_ins", "expect", "words", "words_rewrite", "floor", "floor_basis")
DERIVED_SIDE = ("state", "state_words", "state_npm")


def admit_side(res, name, v, schema, cb, at=()):
    """The intake of one side of the row whose place in the source is `at`:
    (its problems as (where, kind, why), what it rejected as {pointer, type,
    why}, and the side the slot keeps: the side admitted, a rejected side
    (`decision` invalid) in its place, or None for a side this file does not
    write)."""
    out, rej = [], []
    where = "side %s" % name
    here = at + ("sides", name)

    def bad(why, kind="invalid"):
        out.append((where, kind, why))

    def reject(why, path=(), value=v):
        rej.append({"pointer": pointer(*(here + path)), "type": jtype(value), "why": why})

    def instead(why):
        bad(why)
        reject(why)
        return out, rej, {"decision": "invalid", "rejected": pointer(*here)}

    if name not in SIDE_DECISIONS:
        bad("a side this file does not write")
        reject("a side this file does not write")
        return out, rej, None
    if not isinstance(v, dict):
        return instead("not an object")
    for k in DERIVED_SIDE:
        v.pop(k, None)
    d = v.get("decision")
    if d not in SIDE_DECISIONS[name]:
        return instead("decision %r" % (d,))
    if name == "head":
        if not isinstance(v.get("reason", ""), str) or not _is_int(v.get("guard_rc", 0)):
            return instead("the pre-guard's answer is not one this file writes")
        return out, rej, v
    o = None
    if name in ("bash", "core"):
        recs = res.get("ref" if name == "bash" else "core") or {}
        o = consensus(enc(recs), cb) if recs else None
        want = None if o is None else "blocked" if o == "blocked" else "deny" if (o == "deny" or recs.get("failed") == "true") else "run"
        if d != want:
            return instead("decision %s where its readings say %s" % (d, want))
    if d != "run":
        if "shells" in v:
            return instead("a side that sends nothing has runs")
        return out, rej, v
    run = v.get("run", MISSING)
    if not isinstance(run, str):
        if run is MISSING and schema == 1:
            bad("the first schema kept no run bytes for it", UNKNOWN)
        else:
            bad("no run bytes")
    else:
        rb = cmd_bytes(run)
        if name == "written" and rb != cb:
            bad("the command as written is not what it ran")
        if name in ("bash", "core"):
            if o[2] != rb:
                bad("it ran bytes that are not what its readings agree on")
            rec = v.get("record", MISSING)
            if rec is MISSING:
                v["_record"] = bool(records_of(o))
            elif rec is not bool(records_of(o)):
                bad("record is not what its value carries")
        if name in ("v2.18.1", "7d66f8c"):
            fl = v.get("flags", MISSING)
            if fl is MISSING and schema == 1:
                bad("the first schema kept no flags for it", UNKNOWN)
            elif fl != flag_positions(cb, rb):
                bad("flags are not where its run inserts them")
            if not isinstance(v.get("record"), bool):
                bad("record is not true or false")
    sh = v.get("shells", MISSING)
    if not isinstance(sh, dict):
        if sh is MISSING and schema == 1:
            bad("the first schema kept no runs for it", UNKNOWN)
        else:
            bad("a side that ran has no runs")
            if sh is not MISSING:
                reject("a side that ran has no runs", ("shells",), sh)
                del v["shells"]
        return out, rej, v
    for s_, ob in list(sh.items()):
        if s_ not in SHELLS:
            bad("a shell this file does not run (%s)" % s_)
            reject("a shell this file does not run", ("shells", s_), ob)
            del sh[s_]
            continue
        for x, kind, why in admit_obs(ob, schema):
            out.append(("%s shell %s %s" % (where, s_, x), kind, why))
        if not isinstance(ob, dict):
            reject("the run is not an object", ("shells", s_), ob)
            sh[s_] = rejected_run(pointer(*(here + ("shells", s_))))
    return out, rej, v


def words_records(b, p=0):
    """The records of one `safedeps-core words` output in `b` from offset
    `p`: ({"payloads": [(kind, text, src)], "failed": n}, the offset after its
    `failed` line), or None where the bytes are not that program's records.
    Every record that carries bytes says how many, and is read by that."""
    ys = []
    while True:
        nl = b.find(b"\n", p)
        if nl < 0:
            return None
        parts = b[p:nl].split(b" ")
        p = nl + 1
        tag = parts[0]
        try:
            if tag in (b"unterm", b"unreadable") and len(parts) == 2:
                int(parts[1])
            elif tag == b"P" and len(parts) == 5:
                [int(x) for x in parts[1:]]
            elif tag in (b"W", b"V") and len(parts) == (4 if tag == b"W" else 2):
                n = int(parts[-1])
                if n < 0 or b[p + n:p + n + 1] != b"\n":
                    return None
                p += n + 1
            elif tag == b"Y" and len(parts) == 3 and len(parts[1]) == 1:
                n = int(parts[2])
                text = b[p:p + n]
                if n < 0 or len(text) != n or b[p + n:p + n + 2] != b"\nS":
                    return None
                q = b.find(b"\n", p + n + 2)
                if q < 0:
                    return None
                src = [None if t == b"-" else int(t) for t in b[p + n + 2:q].split()]
                if len(src) != n or any(x is not None and x < 0 for x in src):
                    return None
                ys.append((parts[1].decode("latin-1"), text, src))
                p = q + 1
            elif tag == b"failed" and len(parts) == 2:
                return {"payloads": ys, "failed": int(parts[1])}, p
            else:
                return None
        except ValueError:
            return None


def parse_words_file(raw):
    """A words file (see The intake): {command: {reading: {"rc", "payloads",
    "failed"}}}. Raises Unsupported where the bytes are not that format."""
    try:
        b = raw.decode("utf-8").encode("latin-1")
    except (UnicodeDecodeError, UnicodeEncodeError):
        raise Unsupported("not the bytes a words file holds")
    out, cur, p = {}, None, 0
    while p < len(b):
        nl = b.find(b"\n", p)
        if nl < 0:
            raise Unsupported("a line with no end at byte %d" % p)
        line, at = b[p:nl], p
        p = nl + 1
        if line.startswith(b"== "):
            try:
                text = json.loads(line[3:].decode("latin-1"))
            except ValueError:
                raise Unsupported("a command that is not JSON at byte %d" % at)
            if not isinstance(text, str) or text in out:
                raise Unsupported("a command named twice, or not a string, at byte %d" % at)
            cur = out[text] = {}
            continue
        m = re.match(rb"^-- ([a-z]+) rc (-?[0-9]+)$", line)
        if cur is None or not m:
            raise Unsupported("not a words file at byte %d" % at)
        rd, rc = m.group(1).decode(), int(m.group(2))
        if rd not in READING_NAMES or rd in cur:
            raise Unsupported("a reading this file does not know, or named twice, at byte %d" % at)
        if rc != 0:
            cur[rd] = {"rc": rc, "payloads": None, "failed": None}
            continue
        got = words_records(b, p)
        if got is None:
            raise Unsupported("the words records of %s at byte %d do not read" % (rd, at))
        rec, p = got
        cur[rd] = dict(rec, rc=0)
    return out


def core_run(res):
    """The bytes the core's readings agree to run, or None."""
    recs = res.get("core") or {}
    try:
        o = consensus(enc(recs), cmd_bytes(res["command"])) if recs else None
    except (UnicodeEncodeError, KeyError, AttributeError):
        return None
    return o[2].decode("utf-8", "surrogateescape") if isinstance(o, tuple) else None


def admit_words(res, key, text, p3, note):
    """A's words records a run kept for `text` (`words` for the command,
    `words_rewrite` for the core's rewrite): {reading: records}, or None where
    the row holds none that are evidence."""
    w = res.get(key, MISSING)
    if w is MISSING:
        return None
    if not isinstance(w, dict) or not isinstance(w.get("readings"), dict) or w.get("text") != text:
        note(key, "invalid", "not A's words records of %s" % ("the command" if key == "words" else "the core's rewrite"))
        return None
    out = {}
    for rd, x in w["readings"].items():
        if rd not in READING_NAMES or not isinstance(x, dict) or not _is_int(x.get("rc")) or not isinstance(x.get("stdout"), str):
            note(key, "invalid", "a reading's record is not one this file writes")
            return None
        try:
            raw = x["stdout"].encode("latin-1")
        except UnicodeEncodeError:
            note(key, "invalid", "%s: the output is not the bytes it was read as" % rd)
            return None
        if sha256(raw) != x.get("stdout_sha256"):
            note(key, "invalid", "%s: the output is not its sha256's" % rd)
            return None
        if x["rc"] != 0:
            out[rd] = {"rc": x["rc"], "payloads": None, "failed": None}
            continue
        got = words_records(raw)
        if got is None or got[1] != len(raw):
            note(key, "invalid", "%s: the output is not words records" % rd)
            return None
        out[rd] = dict(got[0], rc=0)
        if key == "words" and isinstance(p3, dict) and p3.get(rd) != len(got[0]["payloads"]):
            note(key, "invalid", "%s: the row's payload count is not A's" % rd)
            return None
    return out


def floor_of(res, floor_rows, basis):
    """The release floor of a row, from what the row holds: (value, basis), or
    (None, None) where it holds nothing to hold the core's rewrite to."""
    cmd = res["command"]
    cb = cmd_bytes(cmd)
    got = enc(res.get("core") or {})
    o = consensus(got, cb) if got else None
    if basis == FLOOR_FILE:
        if cmd not in floor_rows:
            return None, None
        if floor_rows[cmd] is None:
            return "release-none", basis
        target = cmd_bytes(floor_rows[cmd])
    elif basis == FLOOR_TREE:
        f7 = (res.get("sides") or {}).get("7d66f8c")
        if not isinstance(f7, dict) or "rejected" in f7:
            return None, None
        if f7.get("decision") != "run":
            return "release-deny", basis
        if not isinstance(f7.get("run"), str):
            return None, None
        if f7["run"] == cmd:
            return "release-none", basis
        target = cmd_bytes(f7["run"])
    else:
        return None, None
    if o is None or o in ("deny", "blocked"):
        return {"deny": "core-deny", "blocked": "core-blocked"}.get(o, "core-none"), basis
    if o[0] != "rewrite":
        return "NOT: the core writes no rewrite", basis
    return ("ok" if subseq(o[2], target, cb) else "NOT"), basis


def admit(res, k, ctx, raw_type="object"):
    """The intake of the source's row `k` (see The intake) on its slot `res`,
    in place: a copy of the row, or an empty slot for a row that is not an
    object, whose JSON type is `raw_type`. The slot becomes `admitted` or
    `rejected` and gets `evidence`. `ctx` holds what the source says of all
    its rows: its schema and sha256, the provenance of the run that measured
    it, A's words records bound to it, and the recorded release rewrites
    attached. An admitted slot keeps what it decodes once for every consumer
    in `_facts` (whether each side reads an install) and A's words that are
    evidence for this row (its own, or attached) in `_words`."""
    for key in [x for x in res if x not in ROW_FIELDS]:
        del res[key]
    at = ("rows", k)
    schema = ctx["schema"]
    prov, prov_why = ctx["provenance"]
    ev = {"schema": schema, "from": {"source_sha256": ctx["source_sha256"], "row": k + 1, "pointer": pointer(*at)},
          "provenance": prov, "invalid": [], "unknown": [], "rejected": []}
    res["evidence"] = ev

    def note(where, kind, why):
        ev["invalid" if kind == "invalid" else "unknown"].append("%s: %s" % (where, why))

    def reject(path, why, type_):
        ev["rejected"].append({"pointer": pointer(*(at + path)), "type": type_, "why": why})

    def row_invalid(why, path, type_):
        note("row", "invalid", why)
        reject(path, why, type_)
        shown = {f: res.get(f) if isinstance(res.get(f), str) else None for f in ("set", "command")}
        if shown["command"] is not None:
            ev["from"]["command_sha256"] = sha256(cmd_bytes(shown["command"]))
        res.clear()
        res.update(slot="rejected", raw_type=raw_type, set=shown["set"], command=shown["command"], evidence=ev)

    def drop(key, why):
        note(key, "invalid", why)
        reject((key,), why, jtype(res[key]))
        del res[key]

    if prov != "ok":
        note("source", prov, prov_why)
    if raw_type != "object":
        return row_invalid("row %d is not an object (%s)" % (k + 1, raw_type), (), raw_type)
    for key in ("command", "set"):
        if not isinstance(res.get(key), str):
            return row_invalid("no command or no set", (key,), jtype(res.get(key, MISSING)))
    cmd = res["command"]
    cb = cmd_bytes(cmd)
    ev["from"]["command_sha256"] = sha256(cb)
    if not _is_int(res.get("core_rc")):
        return row_invalid("the core's exit status is not one", ("core_rc",), jtype(res.get("core_rc", MISSING)))
    for key, who in (("ref", "the bash guard"), ("core", "the core")):
        why = records_problem(res[key], who, schema) if key in res else "%s: no records" % who
        if why:
            return row_invalid(why, (key,), jtype(res.get(key, MISSING)))
    sides = res.get("sides", MISSING)
    if sides is not MISSING and not isinstance(sides, dict):
        return row_invalid("sides is not an object (%s)" % type(sides).__name__, ("sides",), jtype(sides))
    facts = {}
    for key, name in (("ref", "bash_install"), ("core", "core_install")):
        v = res[key].get("any_install") if res[key] else None
        facts[name] = True if v == "true" else False if v == "false" else None
        if res[key] and v is None:
            note(key + ".any_install", UNKNOWN, "the first schema did not keep it")
    res["_facts"] = facts
    p3 = res.get("payloads3", MISSING)
    if p3 is MISSING:
        if schema != 1:
            return row_invalid("no payload counts", ("payloads3",), "missing")
        note("payloads3", UNKNOWN, "the first schema did not keep them")
        p3 = None
    elif not (isinstance(p3, dict) and set(p3) == set(READING_NAMES)
              and all(p3[r] is None or (_is_int(p3[r]) and p3[r] >= 0) for r in READING_NAMES)):
        return row_invalid("the payload counts are not three counts", ("payloads3",), jtype(p3))
    if "stand_ins" in res and res["stand_ins"] not in STAND_INS:
        drop("stand_ins", "stand-ins this file does not have")
    if "expect" in res and not isinstance(res["expect"], str):
        drop("expect", "not a word")

    def words_of(key, text):
        """A's words the row kept for `text`; ones that are not evidence are
        rejected and not kept."""
        got = admit_words(res, key, text, p3, note)
        if got is None and key in res:
            reject((key,), ev["invalid"][-1].split(": ", 1)[1], jtype(res[key]))
            del res[key]
        return got

    # A's words: the row's own, else attached from the source's own core.
    own = words_of("words", cmd)
    wc = own if own is not None else ctx["words"].get(cmd)
    if own is None and wc is not None and isinstance(p3, dict):
        for rd, x in sorted(wc.items()):
            if x.get("rc") == 0 and _is_int(p3.get(rd)) and p3[rd] != len(x["payloads"]):
                note("words", "invalid", "%s: the row's payload count is not A's attached" % rd)
    run = core_run(res)
    wr = None
    if run is not None:
        wr = words_of("words_rewrite", run)
        if wr is None:
            wr = ctx["words"].get(run)
    elif "words_rewrite" in res:
        drop("words_rewrite", "words of a rewrite the core does not send")
    res["_words"] = {"words": wc, "words_rewrite": wr}
    # The core's own payload counts, beside A's and the row's.
    if facts["core_install"]:
        same_text = cb.replace(b"\0", b"").rstrip(b"\n") == cb
        for r in res["core"]["reading_set"].split():
            w_ = res["core"].get("payloads." + r)
            if w_ is None:
                note("core.payloads." + r, "invalid" if schema != 1 else UNKNOWN,
                     "the core writes a payload count for every reading, and this one is not there")
                continue
            if not re.match(r"^(0|[1-9][0-9]*)$", w_):
                note("core.payloads." + r, "invalid", "%r is not a count" % w_)
                continue
            n = int(w_)
            if not same_text:
                continue
            x = (wc or {}).get(r)
            if x and x.get("rc") == 0:
                if len(x["payloads"]) != n:
                    note("core.payloads." + r, "invalid", "the core counts %d payloads, A's words of the same text %d" % (n, len(x["payloads"])))
            elif isinstance(p3, dict) and _is_int(p3.get(r)) and p3[r] != n:
                note("core.payloads." + r, "invalid", "the core counts %d payloads, the row's payload count %d" % (n, p3[r]))
    # The sides, each in its place, before anything compares them.
    if sides is not MISSING:
        for name, v in list(sides.items()):
            problems, rej, keep = admit_side(res, name, v, schema, cb, at)
            for where, kind, why in problems:
                note(where, kind, why)
            ev["rejected"].extend(rej)
            if keep is None:
                del sides[name]
            else:
                sides[name] = keep
    # The floor, computed again from the basis the row declares.
    saved_floor, basis = res.pop("floor", None), res.pop("floor_basis", None)
    if saved_floor is not None or basis is not None:
        res["floor_declared"] = {"floor": saved_floor, "basis": basis}
    if basis is None:
        if saved_floor is not None:
            note("floor", UNKNOWN, "the floor %r was kept with no basis: what it was held to is not recorded, and a --floor request "
                 "is not that" % (saved_floor,))
    elif basis not in (FLOOR_FILE, FLOOR_TREE):
        note("floor", "invalid", "a basis this file does not write (%r)" % (basis,))
    elif basis == FLOOR_FILE and ctx["floor_rows"] is None:
        note("floor", UNKNOWN, "held to the recorded release rewrites, which are not attached")
    else:
        v, b = floor_of(res, ctx["floor_rows"] or {}, basis)
        if v is None:
            note("floor", "invalid", "its basis holds nothing for this row")
        else:
            if saved_floor is not None and saved_floor != v:
                note("floor", "invalid", "saved %r, computed again from the row %r" % (saved_floor, v))
            res["floor"], res["floor_basis"] = v, b
    res["slot"] = "admitted"


def _hex(x):
    return isinstance(x, str) and bool(HEX64.match(x))


RUN_FIELDS = (("argv", _strs), ("harness_sha256", _hex), ("guard_sha256", _hex), ("classes_sha256", _hex), ("jobs", _is_int))


def provenance_of(saved, schema):
    """Whether a source names the run that measured it: (`ok`, None),
    (`unknown`, why) where its schema did not keep one or it is a
    classification of another report, or (`invalid`, why) where this schema
    writes one and it is not there or not one this file writes. Nothing of
    the classification running now stands in for it."""
    if schema == 1:
        return UNKNOWN, "the first schema kept no record of the run that measured it"
    run = saved.get("run", MISSING)
    if not isinstance(run, dict):
        return "invalid", "the report holds no run: this schema writes the run that measured it"
    if "reclassified_from" in run:
        return UNKNOWN, ("a classification of another report (sha256 %s): what measured its rows is that report's run, and this "
                         "file is not that report" % (run.get("reclassified_from_sha256"),))
    bad = [f for f, ok in RUN_FIELDS if not ok(run.get(f))]
    if run.get("schema") != SCHEMA:
        bad.append("schema")
    if not (run.get("core_sha256") is None or _hex(run.get("core_sha256"))):
        bad.append("core_sha256")
    if bad:
        return "invalid", "the run is not one this file writes (%s)" % ", ".join(bad)
    return "ok", None


def ineligible(res):
    """Why a row can be in no count of what held, or None: it is invalid, its
    evidence is, or what measured it is not recorded."""
    if res.get("slot") != "admitted" or res.get("status") == "invalid":
        return "the row is invalid"
    ev = res.get("evidence") or {}
    if ev.get("invalid"):
        return "its evidence is invalid"
    if ev.get("provenance") != "ok":
        return "the run that measured it is not recorded"
    return None


def make_attachment(kind, b, path, producer):
    """An attachment: its bytes read as their kind says. Raises Unsupported."""
    if kind == "words":
        if not _hex(producer):
            raise Unsupported("a words attachment names no producer (the sha256 of the core that wrote it)")
        parsed = parse_words_file(b)
    elif kind == "floor-rewrites":
        try:
            rows = json.loads(b)
        except ValueError:
            raise Unsupported("recorded release rewrites that are not JSON")
        if not isinstance(rows, list) or not all(isinstance(r, dict) and isinstance(r.get("command"), str)
                                                 and (r.get("release") is None or isinstance(r.get("release"), str)) for r in rows):
            raise Unsupported("recorded release rewrites that are not commands and their release rewrites")
        parsed = {r["command"]: r["release"] for r in rows}
    else:
        raise Unsupported("an attachment of a kind this file does not read (%r)" % (kind,))
    return {"kind": kind, "bytes": b, "sha256": sha256(b), "path": path, "producer": producer, "parsed": parsed}


def merge_attachments(atts):
    """The attachments, once each. Two words files of one producer that hold
    the same text, or two different recorded rewrites, are refused."""
    out, seen, texts, floors = [], set(), {}, set()
    for at in atts:
        key = (at["kind"], at["sha256"], at["producer"])
        if key in seen:
            continue
        seen.add(key)
        if at["kind"] == "words":
            for text in at["parsed"]:
                if texts.setdefault((at["producer"], text), at["sha256"]) != at["sha256"]:
                    raise Unsupported("two words attachments of one producer hold the same command")
        else:
            floors.add(at["sha256"])
            if len(floors) > 1:
                raise Unsupported("two different recorded release rewrites")
        out.append(at)
    return out


def _b64(d, what):
    if not isinstance(d, dict) or not isinstance(d.get("bytes_b64"), str) or not _hex(d.get("sha256")):
        raise Unsupported("%s is not bytes and a sha256" % what)
    try:
        b = base64.b64decode(d["bytes_b64"], validate=True)
    except ValueError:
        raise Unsupported("%s is not base64" % what)
    if sha256(b) != d["sha256"]:
        raise Unsupported("%s does not hash to the sha256 it names" % what)
    return b


def load_input(raw):
    """What a file given to --reclassify holds: (the source's bytes, the
    source's record, the attachments it carries, the v3 report it is or
    None). A v3 report gives back its own source and attachments, each
    checked against its sha256; any other file is a source itself. Raises
    Unsupported."""
    try:
        doc = json.loads(raw)
    except ValueError as e:
        raise Unsupported("not JSON (%s)" % e)
    if not (isinstance(doc, dict) and doc.get("schema") == 3):
        return raw, None, [], None
    if doc.get("contract") != CONTRACT:
        raise Unsupported("a v3 report of another contract (%r)" % (doc.get("contract"),))
    src = doc.get("source")
    b = _b64(src, "its source")
    atts = []
    for i, at in enumerate(doc.get("attachments") or []):
        if not isinstance(at, dict):
            raise Unsupported("attachment %d is not an object" % i)
        atts.append(make_attachment(at.get("kind"), _b64(at, "attachment %d" % i), at.get("path"), at.get("producer")))
    info = {"kind": src.get("kind"), "path": src.get("path")}
    prior = {"sha256": sha256(raw), "emitted_by": (doc.get("evaluation") or {}).get("emitted_by")}
    return b, info, atts, prior


def evaluate(src_bytes, atts, readers=None):
    """The one evaluation of a source (see The report): its rows read from the
    source's bytes, each admitted with the attachments bound to it, and
    classified. `readers` replaces the source's saved answers only for an
    explicit new observation (--reread). Raises Unsupported where the bytes
    are no source this file reads."""
    try:
        saved = json.loads(src_bytes)
    except ValueError as e:
        raise Unsupported("not JSON (%s)" % e)
    if isinstance(saved, dict) and saved.get("schema") == 3:
        raise Unsupported("a v3 report is no source: given to --reclassify, its own source is read")
    schema, rows = decode_report(copy.deepcopy(saved))
    prov = provenance_of(saved, schema)
    run = saved["run"] if isinstance(saved.get("run"), dict) else {}
    core_ref = run.get("core_sha256") if prov[0] == "ok" else None
    words, floor_rows, bound = {}, None, []
    for at in atts:
        if at["kind"] == "words":
            if core_ref is not None and at["producer"] == core_ref:
                words.update(at["parsed"])
                bound.append(at["sha256"])
        elif at["kind"] == "floor-rewrites":
            floor_rows = at["parsed"]
            bound.append(at["sha256"])
    ctx = {"schema": schema, "source_sha256": sha256(src_bytes), "provenance": prov, "words": words, "floor_rows": floor_rows}
    slots = []
    for k, raw in enumerate(rows):
        slot = raw if isinstance(raw, dict) else {}
        admit(slot, k, ctx, jtype(raw))
        slots.append(slot)
    R = readers or SavedReaders(saved.get("readings"), {"source": "the source's saved answers",
                                                        "npm_version": (run.get("npm_parser") or {}).get("version") or ""})
    counts = classify(slots, load_classes(), R)
    return {"rows": slots, "counts": counts, "readers": R, "provenance": prov, "schema": schema, "bound": bound,
            "load": saved.get("load") if isinstance(saved.get("load"), list) else None}


def v3_report(src_bytes, src_info, atts, evaluation):
    """The report this file writes (see The report)."""
    return {"schema": 3, "contract": CONTRACT,
            "source": dict(src_info, sha256=sha256(src_bytes), bytes_b64=base64.b64encode(src_bytes).decode("ascii")),
            "attachments": [{"kind": at["kind"], "path": at["path"], "producer": at["producer"], "sha256": at["sha256"],
                             "bytes_b64": base64.b64encode(at["bytes"]).decode("ascii")} for at in atts],
            "evaluation": evaluation}


def overwrites(outputs, inputs):
    """The first output that is the same file as an input, whatever the two
    paths say (device and inode), or None."""
    for o in outputs:
        if not o or not os.path.exists(o):
            continue
        for i in inputs:
            try:
                if i and os.path.samefile(o, i):
                    return o, i
            except OSError:
                continue
    return None


def decode_report(saved):
    """The schema a saved report was written in, and its rows read as this
    file's. The first schema (no `schema` field, each side's npm calls under
    `calls`) is read with what it did not keep left out; a report this file
    wrote from one carries `upgraded_from_schema` 1 and is read the same.
    Raises Unsupported for anything else: it is not guessed at."""
    if not isinstance(saved, dict) or not isinstance(saved.get("rows"), list):
        raise Unsupported("no rows")
    if "schema" in saved:
        if saved["schema"] != SCHEMA:
            raise Unsupported("schema %r" % (saved["schema"],))
        up = saved.get("upgraded_from_schema", MISSING)
        if up is MISSING:
            return 2, saved["rows"]
        if up != 1:
            raise Unsupported("upgraded from schema %r" % (up,))
        return 1, saved["rows"]
    for k, res in enumerate(saved["rows"]):
        sides = res.get("sides", {}) if isinstance(res, dict) else None
        if not isinstance(sides, dict) or any(not isinstance(v, dict) or ("calls" not in v and v.get("state") != "DENY")
                                              for v in sides.values()):
            raise Unsupported("row %d is in neither schema" % (k + 1))
    # The first schema kept each side's npm calls split at tabs and newlines
    # and, for the bash and core sides, nothing else; its `shells` beside the
    # command as written came from one object two jobs shared, so no exit
    # status in it belongs to a row for certain. A command that can hand npm a
    # tab or a newline has its calls marked lossy.
    risky = re.compile(r"[\t\n]|\\[tn]|\$'")
    for res in saved["rows"]:
        lossy = bool(risky.search(res.get("command", "")))
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
    return 1, saved["rows"]


def whole(obs):
    """A run observed whole: its npm calls and its exit status are evidence
    (it ended by itself, its log decoded, and its records are what this file
    writes)."""
    return calls_known(obs) and axis(obs, "rc") == "ok"


def calls_known(obs):
    """The npm calls of a run are evidence (see The intake)."""
    return axis(obs, "npm") == "ok"


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


def effect_value(o, name):
    """An admitted run's value on one of EFFECTS. It is read only where the
    intake held the axis as evidence, and reads nothing it does not find."""
    if name in ("stdout", "stderr"):
        return (o.get(name + "_len"), o.get(name + "_sha256"))
    if name == "order":
        calls = o.get("calls")
        return [x[0] if isinstance(x, list) and x else None for x in calls] if isinstance(calls, list) else calls
    return o.get(name)


def relate(w, s, R):
    """How a side's run relates to the run of the command as written, in one
    shell. `npm` is `unknown` (a run's npm calls are not evidence), `invalid`,
    `identical`, `flags-added`, `call-lost`, `call-added`,
    `argument-changed`, `flag-unconsumed` (an inserted flag stands after a
    `--`, or npm does not read it as a true option, or it changes something
    else npm reads) or `reading-unknown` (a reader did not answer). Each of
    EFFECTS is `same`, `differ`, `unknown` or `invalid`: two runs compare only
    where both hold the axis as evidence."""
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
    elif "invalid" in (axis(w, "npm"), axis(s, "npm")):
        out["npm"] = "invalid"
    for name in EFFECTS:
        aw, as_ = axis(w, name), axis(s, name)
        if aw == "ok" and as_ == "ok":
            out[name] = "same" if effect_value(w, name) == effect_value(s, name) else "differ"
        else:
            out[name] = "invalid" if "invalid" in (aw, as_) else UNKNOWN
    return out


def side_verdict(res, side, R):
    """What the shells show of a side beside the command as written:

      npm      `deny` or `blocked` (the side sends no command: its readings
               disagree or one failed, or its duties collide), `loss` (a call
               gone or added, an argument changed, a flag that is no option
               to npm, or a SILENT state: a loss seen in one shell is not
               hidden by another shell that cannot be read), `invalid` (a run
               holds a record that is not what this file writes), `unknown`,
               `nocall` (no shell made an install call), or `ok`
      effects  `same`, `differ:<axes>`, `invalid` or `unknown`, over the exit
               status, stdout, stderr, the other stand-ins' calls, the order
               of every call and the files left
      shells   per shell, the relation and the states
    """
    sides = res.get("sides", {})
    w, s = sides.get("written", {}), sides.get(side, {})
    v = {"npm": UNKNOWN, "effects": UNKNOWN, "shells": {}}
    if s.get("decision") in ("deny", "blocked"):
        v["npm"] = v["effects"] = s["decision"]
        return v
    ws, ss = w.get("shells"), s.get("shells")
    if not isinstance(ws, dict) or not isinstance(ss, dict):
        return v
    rec = side_record(s)
    unknown = bad = eff_unknown = False
    has_invalid = eff_invalid = False
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
        if r["npm"] == "invalid":
            has_invalid = True
        if r["npm"] in (UNKNOWN, "reading-unknown", "invalid") or r["state"] == "UNKNOWN" or r["written_state"] == "UNKNOWN":
            unknown = True
        if r["npm"] in ("call-lost", "call-added", "argument-changed", "flag-unconsumed") or r["state"] == "SILENT":
            bad = True
        if r["state"] in ("FLAG", "REC", "SILENT"):
            installs += 1
        for axis_ in EFFECTS:
            if r[axis_] == "differ":
                differ.add(axis_)
            elif r[axis_] == "invalid":
                eff_invalid = True
            elif r[axis_] == UNKNOWN:
                eff_unknown = True
    v["npm"] = "loss" if bad else "invalid" if has_invalid else UNKNOWN if unknown else "ok" if installs else "nocall"
    v["effects"] = "differ:" + ",".join(sorted(differ)) if differ else "invalid" if eff_invalid else UNKNOWN if eff_unknown else "same"
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
    if not c or not b or b["npm"] in ("deny", "blocked") or c["npm"] in ("deny", "blocked"):
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


PAIR_KEYS = ("shells", "calls", "true_to_false", "false_to_true", "lost", "added", "changed", "unknown_shells", "unknown_calls")


def call_changes(res, base, side, R):
    """The install calls of `side` beside those of `base`, shell by shell and
    call by call: the calls pair by their order, in a shell where both runs
    made the same number of npm calls. Counted: calls that go from a true
    ignore-scripts to a false one and the other way, calls lost and added,
    calls that are an install on one side only, and what cannot be compared.
    A record on `side` takes nothing away: a call that lost the option is
    counted, recorded or not, and a first call that kept it does not stand
    for a second that did not. None where a side has no runs."""
    sb = res.get("sides", {}).get(base, {}).get("shells")
    ss = res.get("sides", {}).get(side, {}).get("shells")
    if not isinstance(sb, dict) or not isinstance(ss, dict):
        return None
    out = dict({k: 0 for k in PAIR_KEYS}, where=[])
    for sh in SHELLS:
        b, s = sb.get(sh), ss.get(sh)
        if not calls_known(b) or not calls_known(s):
            out["unknown_shells"] += 1
            continue
        out["shells"] += 1
        bn, sn = b["npm"], s["npm"]
        if len(sn) != len(bn):
            out["lost" if len(sn) < len(bn) else "added"] += abs(len(bn) - len(sn))
            continue
        for k, (x, y) in enumerate(zip(bn, sn)):
            ix, iy = R.install(x), R.install(y)
            if ix is None or iy is None:
                out["unknown_calls"] += 1
                continue
            if ix != iy:
                out["changed"] += 1
                continue
            if not ix:
                continue
            fx, fy = R.flagged(x), R.flagged(y)
            if fx is None or fy is None:
                out["unknown_calls"] += 1
                continue
            out["calls"] += 1
            if fx and not fy:
                out["true_to_false"] += 1
                out["where"].append([sh, k])
            elif fy and not fx:
                out["false_to_true"] += 1
    return out


def core_decision(res):
    """What the core does with a row: `sent` (a rewrite every reading agrees
    on), `as-written` (none: the command runs as given), `blocked` (a reading
    holds a collision), `undecided` (its readings disagree or one failed),
    `no-install` (it reads no install), `unobserved` (it ended non-zero, or
    a reading has no value) or `invalid` (the row's records do not read)."""
    if res.get("slot") != "admitted" or res.get("status") == "invalid":
        return "invalid"
    if res.get("core_rc") != 0 or not res.get("core"):
        return "unobserved"
    got = enc(res["core"])
    inst = (res.get("_facts") or {}).get("core_install")
    if inst is None:
        return "unobserved"
    if not inst:
        return "no-install"
    cb = cmd_bytes(res["command"])
    o = consensus(got, cb)
    if o is None:
        return "unobserved"
    if o == "blocked":
        return "blocked"
    if o == "deny" or got.get("failed") == b"true":
        return "undecided"
    return "sent" if o[0] == "rewrite" and o[2] != cb else "as-written"


def meets(expect, res):
    """Whether a row is what its line of the selection said it would be:
    `sent`, `as-written`, `blocked`, `blocked:<kind>` or `undecided`."""
    d = core_decision(res)
    if expect.startswith("blocked:"):
        return d == "blocked" and res.get("status") == expect
    return d == expect


def accounting(results, R):
    """What the run shows, axis by axis, each number with the rows it is over.
    A row is in a number only where the thing counted was observed. A row the
    core blocks or leaves UNDECIDED runs nothing on the core's side: it is in
    no count of what ran, of a floor kept or of a call that kept its flag, and
    a row with no run observed is `not observed`, never held. An invalid row,
    and a row with any invalid evidence, holds nothing: it is listed apart
    and is in no other count."""
    acc = {"rows": len(results), "core": {}, "ran_observed": 0, "ran_unobserved": 0, "npm_rows": {}, "effects_rows": {},
           "relations": {}, "effects_shells": {}, "floor_of_sent": {}, "sent_notes": {}, "sent_not_held": [], "pairs": {},
           "evidence_invalid": [], "provenance_unknown": []}
    bases = [b for b in ("bash", "v2.18.1", "7d66f8c") if any(b in res.get("sides", {}) for res in admitted(results))]

    def pair(base):
        return acc["pairs"].setdefault(base, dict({x: 0 for x in PAIR_KEYS}, rows=0, true_to_false_rows=0, state_pairs=0,
                                                  state_unknown=0, new_silent_rows=0, new_silent_shells=0, not_paired={}))

    for k, res in enumerate(results):
        res.pop("true_to_false", None)
        d = core_decision(res)
        acc["core"][d] = acc["core"].get(d, 0) + 1
        why_ = ineligible(res)
        if why_ is not None:
            if why_ == "its evidence is invalid":
                acc["evidence_invalid"].append(k)
            elif why_ != "the row is invalid":
                acc["provenance_unknown"].append(k)
            for base in bases:
                p = pair(base)
                p["not_paired"][why_] = p["not_paired"].get(why_, 0) + 1
            continue
        sides = res.get("sides", {})
        c = sides.get("core")
        if d == "sent":
            f = str(res.get("floor", "unmeasured")).split(":")[0]
            acc["floor_of_sent"][f] = acc["floor_of_sent"].get(f, 0) + 1
            # What the rewrite says of itself. `unverified` is a word the
            # shell decides at run time: npm was not asked about it, so such a
            # row is never one where the option was read as true.
            o = consensus(enc(res["core"]), cmd_bytes(res["command"]))
            for note in sorted(o[1] & set(NOTES)) or ["no note"]:
                acc["sent_notes"][note] = acc["sent_notes"].get(note, 0) + 1
        if d in ("sent", "as-written"):
            cv = res.get("obs", {}).get("core")
            if cv is None or not isinstance((c or {}).get("shells"), dict):
                acc["ran_unobserved"] += 1
            else:
                acc["ran_observed"] += 1
                acc["npm_rows"][cv["npm"]] = acc["npm_rows"].get(cv["npm"], 0) + 1
                e = cv["effects"].split(":")[0]
                acc["effects_rows"][e] = acc["effects_rows"].get(e, 0) + 1
                for sh, r in cv["shells"].items():
                    acc["relations"][r.get("npm")] = acc["relations"].get(r.get("npm"), 0) + 1
                    for axis_ in EFFECTS:
                        if r.get(axis_) in ("differ", UNKNOWN, "invalid"):
                            key = "%s %s" % (axis_, r[axis_])
                            acc["effects_shells"][key] = acc["effects_shells"].get(key, 0) + 1
                # A rewrite the core sends is held to the command as written,
                # whatever the bash side does with the same bytes.
                if d == "sent" and (cv["npm"] in ("loss", UNKNOWN, "invalid") or e != "same"):
                    acc["sent_not_held"].append(k)
        for base in bases:
            p = pair(base)
            b = sides.get(base)
            cs_, bs_ = (c or {}).get("shells"), (b or {}).get("shells")
            why = None
            if d in ("blocked", "undecided"):
                why = "the core is " + d
            elif b is not None and b.get("decision") != "run":
                why = "%s sends nothing (%s)" % (base, b.get("decision"))
            elif not isinstance(cs_, dict) or not isinstance(bs_, dict):
                why = "not observed"
            if why is not None:
                p["not_paired"][why] = p["not_paired"].get(why, 0) + 1
                continue
            p["rows"] += 1
            ch = call_changes(res, base, "core", R) or {}
            for x in PAIR_KEYS:
                p[x] += ch.get(x, 0)
            if ch.get("true_to_false"):
                p["true_to_false_rows"] += 1
                res.setdefault("true_to_false", {})[base] = ch["where"]
            # A state needs the side's record. The 7d66f8c tree's record
            # lines are not the ones this file knows (INERT_RECORD_RE is this
            # release's), so no state is compared beside it: its calls are.
            if base == "7d66f8c":
                p["states"] = "not compared: the record lines of that tree are not read"
                continue
            rec, brec = side_record(c), side_record(b)
            new = 0
            for sh in SHELLS:
                x, y = state((cs_ or {}).get(sh), rec, R), state((bs_ or {}).get(sh), brec, R)
                if x == "UNKNOWN" or y == "UNKNOWN":
                    p["state_unknown"] += 1
                    continue
                p["state_pairs"] += 1
                if x == "SILENT" and y != "SILENT":
                    new += 1
            p["new_silent_shells"] += new
            p["new_silent_rows"] += 1 if new else 0
    return acc


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

# One exact input adopted as a positive of the payload contract
# script-payload-read already names (plan safedeps/guard-core-inert,
# 2026-10-07 05:40), by the conditions of env_split_string_read and by nothing
# else: no pattern for `env -S` is added and that class's pattern is as it was.
# Where the payload stands and where its last byte is are A's to say (its words
# records, held by the row or attached); this file holds no offset of its own.
ENV_SPLIT_INPUT = "npm i y && env -S'npm ci x'"
ENV_SPLIT_CLASS = "script-payload-read"


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
    why = ineligible(res)
    if why:
        return why
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


def env_split_string_read(res, R):
    """The one input adopted under script-payload-read by its conditions:
    every condition holds, or the first that does not. Nothing is read but
    what the intake admitted, and A's words records of the command and of the
    core's rewrite (the row's own, or attached). What is asked:

      the exact bytes, and no invalid evidence in the row;
      A's words of the command in all three readings, each one payload whose
      every byte has a source, the row's payload counts being A's;
      in every reading of the set: both sides rewrite, the core's flags are
      the bash rewrite's and one more right after the payload's last byte,
      the core's detail names an install read in the payload at the payload's
      first byte with its place there, the unread record and the bash
      rewrite's records are kept, and A's words of the core's rewrite hold
      one payload, the same with the flag at its end, every byte of it from
      one run of the rewrite (the flag read back inside the string);
      the release floor computed again from the row is kept;
      in every shell, the command as written, the bash side and the core all
      ran whole; each core call is the call as written with flags that npm
      reads as a true option and as nothing else; the core's calls are the
      bash side's with one flag appended to one call; and every effect,
      the order of the calls included, is the command's as written;
      beside v2.18.1 no call is lost, changed, gone from true to false or
      not known."""
    cmd = res["command"]
    if cmd != ENV_SPLIT_INPUT:
        return "not the input"
    why = ineligible(res)
    if why:
        return why
    cb = cmd_bytes(cmd)
    rs = res["ref"].get("reading_set", "").split()
    if not rs or res["core"].get("reading_set", "").split() != rs:
        return "the two sides do not read the command in the same readings"
    p3 = res.get("payloads3")
    if not (isinstance(p3, dict) and all(_is_int(p3.get(r)) for r in READING_NAMES)):
        return "the payload counts of the three readings are not known"
    wc, wr = (res.get("_words") or {}).get("words"), (res.get("_words") or {}).get("words_rewrite")
    if wc is None or wr is None:
        return "A's words of the command and of the core's rewrite are not held or attached"
    for r in READING_NAMES:
        x = wc.get(r)
        if not x or x["rc"] != 0 or x["failed"] != 0:
            return "%s: A's words of the command are missing or failed" % r
        if len(x["payloads"]) != p3[r]:
            return "%s: the row's payload count is not A's" % r
        if len(x["payloads"]) != 1 or not x["payloads"][0][2] or any(y is None for y in x["payloads"][0][2]):
            return "%s: A names no single payload every byte of which has a source" % r
    for r in rs:
        bv, cv_ = res["ref"].get("inert." + r), res["core"].get("inert." + r)
        if bv is None or cv_ is None:
            return "%s: a reading has no value" % r
        bo, co = outcome(bv.encode("latin-1"), cb), outcome(cv_.encode("latin-1"), cb)
        if bo[0] != "rewrite" or co[0] != "rewrite" or bo[3] is None or co[3] is None:
            return "%s: a side has no rewrite that is the command with flags inserted" % r
        kind, text, src = wc[r]["payloads"][0]
        npm_at, place = src[0], src[-1] + 1
        if set(co[3]) - set(bo[3]) != {place} or set(bo[3]) - set(co[3]):
            return "%s: the core's flags are not the bash rewrite's and one more after the payload's last byte (%d)" % (r, place)
        if "unread" not in records_of(co) or not records_of(co) >= records_of(bo):
            return "%s: the unread record, or a record of the bash rewrite, is missing" % r
        lines = [l.split() for l in (res["core"].get("detail." + r) or "").split("\n") if l.strip()]
        if not any(f[0] == "install" and len(f) >= 6 and f[1] != "0" and f[2] == str(npm_at) and f[5] == str(place) for f in lines):
            return "%s: the core's detail names no install read in the payload at A's offsets (%d, %d)" % (r, npm_at, place)
        y = wr.get(r)
        if not y or y["rc"] != 0 or y["failed"] != 0 or len(y["payloads"]) != 1:
            return "%s: A's words of the core's rewrite do not hold one payload" % r
        k2, t2, s2 = y["payloads"][0]
        if k2 != kind or t2 != text + FLAG:
            return "%s: the rewrite's payload is not the payload with the flag at its end" % r
        if any(z is None for z in s2) or any(s2[i + 1] != s2[i] + 1 for i in range(len(s2) - 1)):
            return "%s: the rewrite's payload is not one run of its bytes: the flag does not read back inside it" % r
    if res.get("floor") != "ok":
        return "the release floor computed again from the row is not kept"
    sides = res.get("sides", {})
    ws, bs, cs = (sides.get(n, {}).get("shells") for n in ("written", "bash", "core"))
    if sides.get("core", {}).get("decision") != "run" or not all(isinstance(x, dict) for x in (ws, bs, cs)):
        return "the shells did not run the command as written, the bash side's and the core's"
    for sh in SHELLS:
        a, bb, b = ws.get(sh), bs.get(sh), cs.get(sh)
        if not whole(a) or not whole(bb) or not whole(b):
            return "%s: a run is missing or was not observed whole" % sh
        if not a["npm"] or len(b["npm"]) != len(a["npm"]) or len(bb["npm"]) != len(a["npm"]):
            return "%s: the three runs do not make the same number of npm calls" % sh
        for x, z in zip(a["npm"], b["npm"]):
            if not flag_edit(x, z):
                return "%s: a call is not the call as written with a flag added" % sh
            if R.rest(x) is None or R.rest(x) != R.rest(z) or R.flagged(z) is not True:
                return "%s: npm does not read a call as before with ignore-scripts true" % sh
        apart = [i for i, (z, q) in enumerate(zip(b["npm"], bb["npm"])) if z != q]
        if len(apart) != 1 or b["npm"][apart[0]] != bb["npm"][apart[0]] + [FLAGWORD]:
            return "%s: the core's calls are not the bash side's with one flag appended to one call" % sh
        rel = relate(a, b, R)
        for axis_ in EFFECTS:
            if rel[axis_] != "same":
                return "%s: %s is not the command's as written (%s)" % (sh, axis_, rel[axis_])
    v = sides.get("v2.18.1", {})
    if v.get("decision") != "run" or not isinstance(v.get("shells"), dict):
        return "no v2.18.1 side that runs (run with --release-tree, --path-prefix and --approve)"
    ch = call_changes(res, "v2.18.1", "core", R)
    if ch is None or ch["true_to_false"] or ch["lost"] or ch["changed"] or ch["unknown_shells"] or ch["unknown_calls"]:
        return "beside v2.18.1 a call is lost, changed, gone from true to false, or not known"
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
    """Gives every row its one status, from what the intake admitted (a row
    it did not see is invalid). Returns the counts."""
    counts = {"total": len(results), "invalid": 0, "core_error": 0, "not_reached": 0, "compared": 0, "reading_set": 0, "incomplete": 0,
              "both_failed": 0, "blocked": 0, "blocked_failed": 0, "both_undecided": 0, "same": 0, "differ": 0,
              "payload_free_differ": 0}
    per = {}

    def put(res, status):
        res["status"] = status
        per[status] = per.get(status, 0) + 1

    for res in results:
        for k in ("status", "tokens", "payload_free", "class_refused", "obs", "label", "readings_differ", "blocked", "expect_failed", "class_basis"):
            res.pop(k, None)
        # A slot the intake rejected, or one it did not see, holds no facts.
        if res.get("slot") != "admitted":
            counts["invalid"] += 1
            put(res, "invalid")
            continue
        cmd = res["command"]
        cb = cmd_bytes(cmd)
        ref = enc(res["ref"])
        got = enc(res["core"])
        if res["core_rc"] != 0:
            counts["core_error"] += 1
            put(res, "core-error")
            continue
        # What the shells show of each side that ran, whether or not the
        # bash guard reached its rewrite: a row it left before that is still
        # one whose core command ran, and the accounting reads this.
        res["obs"] = {s: side_verdict(res, s, R) for s in ("bash", "core", "v2.18.1") if s in res.get("sides", {})}
        if not ref:
            counts["not_reached"] += 1
            put(res, "bash-not-reached")
            continue
        counts["compared"] += 1
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
        cblk = blocked_kinds(got)
        if cblk and not (bfail and cfail):
            # The core's own reason to send nothing: its duties collide. It
            # is no agreement and no disagreement of the readings, whatever
            # the bash side does, and it is in no count of what holds.
            bv = res["obs"].get("bash")
            res["blocked"] = {"kinds": cblk, "core_failed": cfail,
                              "readings": {r: (v[len(COLLISION):].decode("latin-1") if v.startswith(COLLISION) else None)
                                           for r, v in zip(rs, cvals)},
                              "bash": "failed" if bfail else "readings-disagree" if bden else "sends",
                              "bash_observed": {"npm": bv["npm"], "effects": bv["effects"]} if bv else None}
            counts["blocked_failed" if cfail else "blocked"] += 1
            put(res, ("blocked+failed:" if cfail else "blocked:") + "+".join(cblk))
            continue
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
        if cmd == ENV_SPLIT_INPUT:
            why = env_split_string_read(res, R)
            if why is None:
                res["class_basis"] = "this exact input, by its conditions (env_split_string_read), not by the class's pattern"
                put(res, "class:" + ENV_SPLIT_CLASS)
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
            elif cv is None or cv["npm"] in (UNKNOWN, "invalid"):
                put(res, "decrease:" + ("invalid" if cv and cv["npm"] == "invalid" else "unknown"))
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
    for res in admitted(results):
        st = {}
        for side, v in res.get("sides", {}).items():
            if side == "written" or not isinstance(v.get("shells"), dict):
                continue
            rec = side_record(v)
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
    for res in admitted(results):
        if res.get("command") not in reach:
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
    for res in admitted(results):
        if "floor" in res:
            floor[res["floor"]] = floor.get(res["floor"], 0) + 1
    acc = accounting(results, R)
    unmet = []
    for res in admitted(results):
        if res.get("expect") and not meets(res["expect"], res):
            res["expect_failed"] = "expected %s, the core: %s (%s)" % (res["expect"], core_decision(res), res.get("status"))
            unmet.append(res)
    expected = sum(1 for res in admitted(results) if res.get("expect"))
    blocked = [res for res in admitted(results) if str(res.get("status", "")).startswith("blocked")]
    blocked_by = {}
    for res in blocked:
        bo = res["blocked"].get("bash_observed")
        k = "%s | the bash side %s%s" % (res["status"], res["blocked"]["bash"],
                                         (": npm %s, effects %s" % (bo["npm"], bo["effects"].split(":")[0])) if bo else "")
        blocked_by[k] = blocked_by.get(k, 0) + 1
    # A named difference holds only where the shells show the core's npm calls
    # to be the command's as written with flags added, or where nothing runs
    # on the core's side (its readings disagree).
    class_obs = {}
    for res in admitted(results):
        s = res.get("status", "")
        if s.startswith("class:"):
            cv = res.get("obs", {}).get("core")
            k = cv["npm"] + "/" + cv["effects"].split(":")[0] if cv else "not-observed"
            # A loss the bash side has, call for call, is the reference's own
            # (a floor flag that breaks a word): listed apart, and not the
            # core's.
            if cv and cv["npm"] == "loss" and npm_calls_identical(res, "bash", "core"):
                k = "shared-loss/" + cv["effects"].split(":")[0]
            why_ = ineligible(res)
            if why_:
                k = "invalid" if why_ != "the run that measured it is not recorded" else "provenance-unknown"
            class_obs.setdefault(s, {})
            class_obs[s][k] = class_obs[s].get(k, 0) + 1
    labels = {}
    for res in admitted(results):
        if res.get("label"):
            k = "%s (%s)" % (res["label"], res.get("status"))
            labels[k] = labels.get(k, 0) + 1
    out.update({"reach_judged": judged, "reach_short": len(short), "floor": floor, "class_observation": class_obs, "labels": labels,
                "accounting": acc, "blocked": blocked_by, "expected": expected, "expect_unmet": len(unmet)})
    per = counts["status"]
    red = (counts["invalid"] + counts["core_error"] + counts["reading_set"] + counts["incomplete"] + counts["both_failed"]
           + counts["both_undecided"] + counts["blocked_failed"] + len(acc["evidence_invalid"]) + len(acc["provenance_unknown"])
           + len(getattr(R, "problems", []))
           + sum(v for k, v in per.items() if k == "unclassified" or k.startswith("decrease"))
           + len(silent_run) + len(silent_words_run) + len(loss) + len(loss_words) + len(short)
           + sum(v for k, v in floor.items() if k.startswith("NOT")))
    for s, ks in class_obs.items():
        # A named row holds where the shells show its calls and its effects to
        # be the command's own, or where nothing runs on the core's side.
        for k, v in ks.items():
            head, _, tail = k.partition("/")
            if (k in ("not-observed", "invalid", "provenance-unknown") or head in ("loss", UNKNOWN, "invalid")
                    or tail in ("differ", UNKNOWN, "invalid")):
                red += v
    # A call that went from a true option to a false one beside the bash side
    # or v2.18.1, a rewrite sent whose calls or effects do not hold, and a row
    # that is not what its line said are red. A blocked row is neither.
    red += sum(p["true_to_false"] for b, p in acc["pairs"].items() if b in ("bash", "v2.18.1"))
    red += len(acc["sent_not_held"]) + len(unmet)
    out["red"] = red

    print("load start: %s" % extra.get("up0", ""))
    print("load end:   %s" % extra.get("up1", ""))
    for k in ("total", "invalid", "core_error", "not_reached", "compared", "reading_set", "incomplete", "both_failed", "blocked",
              "blocked_failed", "both_undecided", "same", "differ", "payload_free_differ"):
        print("%-22s %d" % (k, counts[k]))
    ev_rows = [res for res in admitted(results) if res["evidence"]["invalid"]]
    unk_rows = [res for res in results if res["evidence"]["unknown"]]
    prov = extra.get("provenance") or ("?", None)
    print("source: provenance %s%s; rows not counted for it %d" % (prov[0], (" (%s)" % prov[1]) if prov[1] else "", len(acc["provenance_unknown"])))
    print("intake: %d rows; invalid rows %d; rows with invalid evidence %d; rows with an axis not recorded or not observable %d"
          % (len(results), counts["invalid"], len(ev_rows), len(unk_rows)))
    print("  readers: %s; answers held %d, not believed %d, derived values the saved report says otherwise %d"
          % (getattr(R, "source", {}).get("source", "?"), len(getattr(R, "gate", {})), len(getattr(R, "problems", [])),
             getattr(R, "rederived", 0)))
    for res in [r for r in results if r.get("status") == "invalid"][:40] + ev_rows[:40]:
        print("INVALID %s %r %s" % (res.get("set"), res.get("command"), "; ".join(res["evidence"]["invalid"][:3])))
    for p_ in getattr(R, "problems", [])[:20]:
        print("READER %s" % p_)
    for k in sorted(per):
        print("  status %-34s %d" % (k, per[k]))
    for s in sorted(class_obs):
        print("  observed %-40s %s" % (s, ", ".join("%s %d" % kv for kv in sorted(class_obs[s].items()))))
    for k in sorted(labels):
        print("  label %-50s %d" % (k, labels[k]))
    for res in admitted(results):
        if res.get("class_basis"):
            print("  named %s for %r: %s" % (res.get("status"), res["command"], res["class_basis"]))
    if floor:
        print("release floor: %s" % ", ".join("%s %d" % (k, v) for k, v in sorted(floor.items())))

    def kv(d):
        return ", ".join("%s %d" % (k, v) for k, v in sorted(d.items(), key=lambda x: str(x[0]))) or "none"

    print("blocked (the core's inert value: it sends nothing, its duties collide; in no count of what holds, and not the "
          "public pre-guard's answer, which is not asked here): %d rows" % len(blocked))
    for k in sorted(blocked_by):
        print("  %s: %d" % (k, blocked_by[k]))
    print("the core, row by row: %s" % kv(acc["core"]))
    print("  rows whose command runs on the core's side (sent or as written): observed %d, not observed %d"
          % (acc["ran_observed"], acc["ran_unobserved"]))
    print("  observed rows by their npm calls: %s; by their effects beside the command as written: %s"
          % (kv(acc["npm_rows"]), kv(acc["effects_rows"])))
    print("  shell runs by how the npm calls relate: %s" % kv(acc["relations"]))
    print("  effect axes that differ or are unknown, in shell runs: %s" % kv(acc["effects_shells"]))
    print("  floor of the rewrites the core sends: %s" % kv(acc["floor_of_sent"]))
    print("  the rewrites the core sends, by their notes (a row may carry several; `unverified` is never a reading of the option "
          "as true): %s" % kv(acc["sent_notes"]))
    print("  rewrites sent whose calls or effects are not shown to hold: %d" % len(acc["sent_not_held"]))
    for base in sorted(acc["pairs"]):
        p = acc["pairs"][base]
        print("  beside %s: %d rows and %d shell runs paired, %d install calls paired by order; true to false %d calls in %d rows, "
              "false to true %d; calls lost %d, added %d, an install on one side only %d; unknown: %d shell runs, %d calls"
              % (base, p["rows"], p["shells"], p["calls"], p["true_to_false"], p["true_to_false_rows"], p["false_to_true"],
                 p["lost"], p["added"], p["changed"], p["unknown_shells"], p["unknown_calls"]))
        if p.get("states"):
            print("    states beside %s: %s; not paired: %s" % (base, p["states"], kv(p["not_paired"])))
        else:
            print("    new SILENT beside %s: %d rows, %d of %d shell-run states (states unknown: %d); not paired: %s"
                  % (base, p["new_silent_rows"], p["new_silent_shells"], p["state_pairs"], p["state_unknown"], kv(p["not_paired"])))
    if expected:
        print("expectations: %d rows carry one, %d not met" % (expected, len(unmet)))
    for res in unmet[:40]:
        print("UNMET %s %r %s" % (res["set"], res["command"], res["expect_failed"]))
    for res in blocked[:80]:
        print("BLOCKED %s %r %s%s" % (res["set"], res["command"], res["status"],
                                      (" stand-ins=" + res["stand_ins"]) if res.get("stand_ins") else ""))
    for k in acc["sent_not_held"][:40]:
        res = results[k]
        cv = res.get("obs", {}).get("core") or {}
        print("SENT-NOT-HELD %s %r status=%s npm %s, effects %s" % (res["set"], res["command"], res.get("status"), cv.get("npm"), cv.get("effects")))
    for res in admitted(results):
        for base, where in sorted((res.get("true_to_false") or {}).items()):
            print("TRUE-TO-FALSE beside %s %s %r status=%s calls=%s" % (base, res["set"], res["command"], res.get("status"), json.dumps(where)))
    print("npm's own parser: %s" % ("asked (npm %s)" % R.npm_version if R.npm_asked else "not asked: %s" % R.npm_error))
    print("core SILENT (both readers): %d, of which the head's whole pre-guard denies %d and lets through or was not asked %d; "
          "by the flag words: %d; core-only SILENT: %d; core states UNKNOWN: %d rows"
          % (len(silent), len(denied), len(silent_run), len(silent_words), len(only_silent), state_unknown))
    print("LOSS against v2.18.1 (new SILENT rows, both readers): %d; by the flag words: %d; not decidable (a state UNKNOWN): %d rows"
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
    for res in admitted(results):
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


def manifest(path, results, head):
    """One JSON line for the report (`head`: the source, its provenance and
    the classifier) and one per slot, in the source's order: a projection of
    the slot. A rejected slot shows what it keeps (its display, where and why
    it was rejected) and nothing of the row's fields; a rejected side or run
    shows where it is in the source."""
    with open(path, "w", encoding="utf-8") as f:
        f.write(json.dumps(head, ensure_ascii=False) + "\n")
        for res in results:
            ev = res["evidence"]
            row = {"row": ev["from"]["row"], "slot": res.get("slot"), "set": res.get("set"),
                   "command_sha256": ev["from"].get("command_sha256"), "command": res.get("command"), "status": res.get("status"),
                   "core": core_decision(res), "evidence": ev}
            if res.get("slot") != "admitted":
                row["raw_type"] = res.get("raw_type")
                f.write(json.dumps(row, ensure_ascii=False) + "\n")
                continue
            row.update({"label": res.get("label"), "tokens": res.get("tokens"), "reading_set": res["ref"].get("reading_set"),
                        "readings_differ": res.get("readings_differ"), "payloads3": res.get("payloads3"),
                        "payload_free": res.get("payload_free"), "floor": res.get("floor"), "floor_basis": res.get("floor_basis"),
                        "blocked": res.get("blocked"), "stand_ins": res.get("stand_ins"), "expect": res.get("expect"),
                        "expect_failed": res.get("expect_failed"), "true_to_false": res.get("true_to_false"),
                        "class_basis": res.get("class_basis"), "class_refused": res.get("class_refused"), "sides": {}})
            for side, v in res.get("sides", {}).items():
                if "rejected" in v:
                    row["sides"][side] = {"decision": v["decision"], "rejected": v["rejected"]}
                    continue
                s = {"decision": v.get("decision"), "record": v.get("record"), "record_computed": v.get("_record"), "state": v.get("state"),
                     "state_words": v.get("state_words")}
                if isinstance(v.get("shells"), dict):
                    s["shells"] = {sh: {"rejected": o["rejected"], "axes": o["_axes"]} if "rejected" in o else
                                   {"rc": o.get("rc"), "timeout": o.get("timeout"), "log": o.get("log"),
                                    "npm_calls": len(o["npm"]) if isinstance(o.get("npm"), list) else UNKNOWN,
                                    "other_calls": len(o["other"]) if isinstance(o.get("other"), list) else UNKNOWN,
                                    "files": len(o["files"]) if isinstance(o.get("files"), dict) else UNKNOWN,
                                    "axes": o.get("_axes")}
                                   for sh, o in v["shells"].items()}
                row["sides"][side] = s
            if res.get("obs"):
                row["observed"] = {s: {"npm": v["npm"], "effects": v["effects"]} for s, v in res["obs"].items()}
            f.write(json.dumps(row, ensure_ascii=False) + "\n")


def selftest(a):
    """Each case is one an earlier version of this file got wrong. Prints
    `ok` or `not ok` per case; exit 1 on any `not ok`. Every row and run a
    case builds passes the intake first, as a run's would."""
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

    def saved():
        """The readers' answers so far, as a run keeps them."""
        return SavedReaders(R.answers(), {"source": "selftest"})

    def adm(o):
        admit_obs(o, SCHEMA)
        return o

    def obs(npm, other=(), rc=0, stdout="", stderr=""):
        """A run whose every record is one observe() writes."""
        o = {"rc": rc, "timeout": False, "log": "ok", "calls": [["npm"] + list(x) for x in npm] + [list(x) for x in other],
             "npm": [list(x) for x in npm], "other": [list(x) for x in other], "files": {"d": ["d"]}}
        o.update(blob("stdout", stdout.encode("latin-1")))
        o.update(blob("stderr", stderr.encode("latin-1")))
        return o

    def four(o):
        return {sh: json.loads(json.dumps(o)) for sh in SHELLS}

    def recs(rs, value, failed, payloads=None):
        r = {"reading_set": rs, "any_install": "true", "failed": failed}
        r.update({"inert." + x: (value[x] if isinstance(value, dict) else value) for x in rs.split()})
        if payloads is not None:
            r.update({"payloads." + x: str(payloads) for x in rs.split()})
        return r

    def mkrow(command, ref_value, core_value, sides, rs="bash", payloads=1, failed=("false", "false"), **extra):
        """A row as a run writes it: its records, its payload counts, and each
        side's run bytes as its records say."""
        res = {"set": "selftest", "command": command, "core_rc": 0, "payloads3": {x: payloads for x in READING_NAMES},
               "ref": recs(rs, ref_value, failed[0]), "core": recs(rs, core_value, failed[1], payloads), "sides": sides}
        res.update(extra)
        cb = cmd_bytes(command)
        for name, v in sides.items():
            if v.get("decision") != "run" or "run" in v:
                continue
            if name == "written":
                v["run"] = command
            elif name in ("bash", "core"):
                v["run"] = consensus(enc(res["ref" if name == "bash" else "core"]), cb)[2].decode("utf-8", "surrogateescape")
        return res

    def prep(*rows, words=None):
        ctx = {"schema": SCHEMA, "source_sha256": "0" * 64, "provenance": ("ok", None), "words": words or {}, "floor_rows": None}
        for k, res in enumerate(rows):
            admit(res, k, ctx)
        return rows

    def row(written, core, bash=None):
        sides = {"written": {"decision": "run", "shells": written}, "core": {"decision": "run", "shells": core}}
        if bash is not None:
            sides["bash"] = {"decision": "run", "shells": bash}
        return prep(mkrow("selftest", "rewrite\nselftest --ignore-scripts", "none", sides))[0]

    # 1. A tab and a newline in an argument are one argument each.
    box = tempfile.mkdtemp(prefix="b.", dir=work)
    o = shells.observe("npm ci 'a\tb' 'c\nd' ''; pip install 'x\ty'", box)
    check("argv keeps a tab, a newline and an empty word", o["bash"]["npm"], [["ci", "a\tb", "c\nd", ""]])
    check("another stand-in's call is kept, in order", o["bash"]["calls"], [["npm", "ci", "a\tb", "c\nd", ""], ["pip", "install", "x\ty"]])
    check("every shell has its own run", sorted(o), sorted(SHELLS))
    check("a run observe() writes is evidence on every axis", admit_obs(o["bash"], SCHEMA), [])
    # 2. What a command writes to a file and to its streams is observed.
    o1 = shells.observe("npm ci; printf '%s' x > f; exit 3", box)
    o2 = shells.observe("npm ci; printf '%s' 'x --ignore-scripts' > f; exit 3", box)
    R.ask([["ci"]])
    check("the exit status is the run's own", o1["dash"]["rc"], 3)
    adm(o1["bash"])
    adm(o2["bash"])
    check("npm calls alike, a file's content apart: the files differ", relate(o1["bash"], o2["bash"], saved())["files"], "differ")
    check("...and the npm calls are identical", relate(o1["bash"], o2["bash"], saved())["npm"], "identical")
    o3 = shells.observe("npm ci; test x", box)
    o4 = shells.observe("npm ci; test x --ignore-scripts", box)
    adm(o3["bash"])
    adm(o4["bash"])
    check("a flag handed to another command changes the exit status", relate(o3["bash"], o4["bash"], saved())["rc"], "differ")
    n1, n2 = adm(obs([["ci"]], rc=None)), adm(obs([["ci"]], rc=None))
    check("a null exit status on both sides is no evidence", relate(n1, n2, saved())["rc"], "invalid")
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
    check("...and the row is a loss", side_verdict(row(four(w), four(c)), "core", saved())["npm"], "loss")
    w, c = obs([["ci", "--"]]), obs([["ci", "--", "--ignore-scripts"]])
    check("a flag placed after `--` is no option: a loss", side_verdict(row(four(w), four(c)), "core", saved())["npm"], "loss")
    w, c = obs([["ci", "--cache"]]), obs([["ci", "--cache", "--ignore-scripts"]])
    if R.npm_asked:
        check("a flag an option takes as its value is no option: a loss", side_verdict(row(four(w), four(c)), "core", saved())["npm"], "loss")
    # 6. No call is no agreement, and a missing run is not an empty one.
    e = obs([])
    check("no install call in any shell is `nocall`, not `ok`", side_verdict(row(four(e), four(e)), "core", saved())["npm"], "nocall")
    three = {sh: obs([]) for sh in SHELLS[:3]}
    check("a shell with no run is unknown, not an empty call", side_verdict(row(four(e), three), "core", saved())["npm"], UNKNOWN)
    undec = dict(obs([]), log="undecodable", calls=UNKNOWN, npm=UNKNOWN, other=UNKNOWN)
    check("an undecodable log is unknown", side_verdict(row(four(e), four(undec)), "core", saved())["npm"], UNKNOWN)
    w, c = obs([["ci"]]), obs([])
    check("a call of the command as written that is gone is a loss", side_verdict(row(four(w), four(c)), "core", saved())["npm"], "loss")
    kl = row({"bash": obs([["ci"]]), "zsh": obs([["ci"]])}, {"bash": obs([])})
    check("a loss seen in one shell is not hidden by a shell that did not run", side_verdict(kl, "core", saved())["npm"], "loss")
    # 7. The statuses: disagreement on both sides comes before `same`.
    apart = {"bash": "none", "zsh": "rewrite\nselftest --ignore-scripts", "dash": "none"}
    both = mkrow("selftest", apart, apart, {}, rs="bash zsh dash")
    failed = mkrow("selftest", "none", "none", {}, failed=("true", "true"))
    kind_only = mkrow("selftest x", "rewrite unread\nselftest --ignore-scripts x", "rewrite unverified unread\nselftest --ignore-scripts x", {},
                      payloads=0)
    R.ask([["ci"], ["ci", "--ignore-scripts"]])
    minus = row(four(obs([["ci"]])), four(obs([["ci", "--ignore-scripts"]])), four(obs([["ci", "--ignore-scripts"]])))
    empty = row(four(e), four(e), four(e))
    worse = mkrow("selftest", "rewrite\nselftest --ignore-scripts", "downgrade",
                  {"written": {"decision": "run", "shells": four(obs([["ci"]]))}, "core": {"decision": "run", "shells": four(obs([["ci"]]))},
                   "bash": {"decision": "run", "shells": four(obs([["ci", "--ignore-scripts"]]))}})
    prep(both, failed, kind_only, worse)
    classify([both, failed, kind_only, minus, empty, worse], load_classes(), saved())
    check("equal values that disagree among the readings on both sides: both-undecided", both["status"], "both-undecided")
    check("a reading failed on both sides: both-failed", failed["status"], "both-failed")
    check("a text with no payload whose records differ in kind alone is named by no class", kind_only["status"], "unclassified")
    check("a `-` row is an observation under `decrease:`, never a class", minus["status"].startswith("decrease"), True)
    check("a `-` row with no install call in any shell is `decrease:nocall`", empty["status"], "decrease:nocall")
    if R.npm_asked:
        check("a `-` row whose calls hold and whose effects are the command's own: its label", minus["status"], "decrease:argv-equal")
        check("the bash side reads true where the core only records: a decrease", worse["status"], "decrease")
    # 8. The duty collision. A row the core blocks is no agreement and no
    # success; a call that lost its option is counted whatever is recorded and
    # whatever the call before it kept; npm calls that hold do not cover data
    # that changed; and a row with nothing run is in no count of what ran.
    lost_arg = ["ci", "--ignore-scripts", "x", "--ignore-scripts=false"]
    kept_arg = lost_arg + ["--ignore-scripts"]
    first = ["i", "--ignore-scripts", "y", "--ignore-scripts"]
    R.ask([["i", "y"], ["ci", "x", "--ignore-scripts=false"], first, lost_arg, kept_arg])
    w2 = obs([["i", "y"], ["ci", "x", "--ignore-scripts=false"]])
    b2 = obs([first, kept_arg])
    c2 = obs([first, lost_arg])

    def crow(value, core_side, core_failed="false"):
        sides = {"written": {"decision": "run", "shells": four(w2)}, "bash": {"decision": "run", "shells": four(b2)}}
        if core_side is not None:
            sides["core"] = core_side
        return mkrow("selftest", "rewrite unread\nselftest --ignore-scripts", value, sides, payloads=0, failed=("false", core_failed))

    sent = crow("rewrite unread\nselftest --ignore-scripts", {"decision": "run", "shells": four(c2)})
    blk = crow("collision floor-outside-command", {"decision": "blocked", "why": "selftest"})
    und = crow("none", {"decision": "deny", "why": "its reading failed"}, core_failed="true")
    gone = crow("rewrite unread\nselftest --ignore-scripts", None)
    eight = list(prep(sent, blk, und, gone))
    cnt = classify(eight, load_classes(), saved())
    acc = accounting(eight, saved())
    check("a row the core blocks has its own status", blk["status"], "blocked:floor-outside-command")
    check("...and is counted apart, not as `same`", [cnt["blocked"], blk["status"] == "same"], [1, False])
    check("a row the core blocks is admitted with no runs", blk["evidence"]["invalid"], [])
    check("a row expected to be blocked that the core sends does not meet its line", meets("blocked", sent), False)
    check("a blocked row meets the kind its line names, and no other", [meets("blocked:floor-outside-command", blk), meets("blocked:end-flag-not-an-option", blk)],
          [True, False])
    check("a row the core blocks, one it leaves undecided and one with no run are in no count of what ran",
          [acc["pairs"]["bash"]["rows"], acc["core"].get("blocked"), acc["core"].get("undecided"), acc["ran_unobserved"]], [1, 1, 1, 1])
    if R.npm_asked:
        ch = call_changes(sent, "bash", "core", saved())
        check("a second call that goes from true to false is counted, record or no record", [ch["true_to_false"], ch["calls"]], [4, 8])
        check("...and the run's accounting holds it beside the bash side", acc["pairs"]["bash"]["true_to_false_rows"], 1)
        wa, ca = obs([["ci"]], stdout="a"), obs([["ci", "--ignore-scripts"]], stdout="b")
        check("npm calls that hold do not cover a stdout that differs", side_verdict(row(four(wa), four(ca)), "core", saved())["effects"], "differ:stdout")
    # 9. The other sudo runs nothing and prints what it was handed.
    box9 = tempfile.mkdtemp(prefix="b.", dir=work)
    oe = shells.observe("sudo npm ci x", box9)
    op = shells.observe("sudo npm ci x", box9, stand_ins="sudo-print")
    check("the default sudo runs its arguments", oe["bash"]["npm"], [["ci", "x"]])
    check("the other sudo runs nothing, writes its call down and prints its arguments",
          [op["bash"]["npm"], op["bash"]["other"], op["bash"]["stdout"]], [[], [["sudo", "npm", "ci", "x"]], "npm\nci\nx\n"])
    # 10. The one exact env -S input is named by its conditions, never by its
    # bytes alone, and A's words of it are the row's own or attached by their
    # bytes: an argument gone from a call, a stdout that differs, a shell with
    # no run, words held nowhere, and each record the stage review
    # (shuksshuki-20261007-054915) took out or emptied leave it unnamed.
    brw = "npm i --ignore-scripts y --ignore-scripts && env -S'npm ci x'"
    crw = "npm i --ignore-scripts y --ignore-scripts && env -S'npm ci x --ignore-scripts'"
    frw = "npm i --ignore-scripts y && env -S'npm ci x'"
    w10, b10, f10 = obs([["i", "y"], ["ci", "x"]]), obs([first, ["ci", "x"]]), obs([["i", FLAGWORD, "y"], ["ci", "x"]])
    c10 = obs([first, ["ci", "x", FLAGWORD]])

    def words_out(payload, src):
        return "unterm 0\nunreadable 0\nV 0\n\nY E %d\n%s\nS%s\nfailed 0\n" % (len(payload), payload, "".join(" %d" % x for x in src))

    def words_rec(text, payload, src):
        t = words_out(payload, src)
        return {"text": text, "readings": {r: {"rc": 0, "stdout": t, "stdout_sha256": sha256(t.encode("latin-1"))} for r in READING_NAMES}}

    def erow(core_shells, **kw):
        cb = cmd_bytes(ENV_SPLIT_INPUT)
        sides = {"written": {"decision": "run", "shells": four(w10)}, "bash": {"decision": "run", "shells": four(b10)},
                 "core": {"decision": "run", "shells": core_shells},
                 "v2.18.1": {"decision": "run", "run": brw, "flags": flag_positions(cb, cmd_bytes(brw)), "record": False, "shells": four(b10)},
                 "7d66f8c": {"decision": "run", "run": frw, "flags": flag_positions(cb, cmd_bytes(frw)), "record": False, "shells": four(f10)}}
        res = mkrow(ENV_SPLIT_INPUT, "rewrite unread\n" + brw, "rewrite unread\n" + crw, sides,
                    words=words_rec(ENV_SPLIT_INPUT, "npm ci x", range(18, 26)),
                    words_rewrite=words_rec(crw, "npm ci x --ignore-scripts", range(52, 77)), floor_basis=FLOOR_TREE)
        res["core"]["detail.bash"] = "pair 0 5 1\ninstall 0 0 plain 5 7 1 0\ninstall 1 18 plain 24 26 1 -\ntexts 2 release 1 unread 1\n"
        res.update(kw)
        return res

    lie = erow(four(c10), floor="NOT")
    prep(lie)
    check("a saved floor its row does not hold is invalid", any(x.startswith("floor") for x in lie["evidence"]["invalid"]), True)
    if R.npm_asked:
        R.ask([["i", "y"], ["ci", "x"], ["ci", "x", FLAGWORD], ["ci", FLAGWORD], ["i", FLAGWORD, "y"], first])
        pos = erow(four(c10))
        gone_arg = erow(four(obs([first, ["ci", FLAGWORD]])))
        other_out = erow(four(obs([first, ["ci", "x", FLAGWORD]], stdout="z")))
        no_run = erow({sh: obs([first, ["ci", "x", FLAGWORD]]) for sh in SHELLS[:3]})
        no_words = erow(four(c10))
        del no_words["words"], no_words["words_rewrite"]
        no_runs = erow(four(c10))
        del no_runs["sides"]["written"]["run"], no_runs["sides"]["core"]["run"]
        no_counts = erow(four(c10))
        del no_counts["payloads3"]
        twice, invented, nulls, no_calls = erow(four(c10)), erow(four(c10)), erow(four(c10)), erow(four(c10))
        for key in ("ref", "core"):
            twice[key]["reading_set"] = "bash bash"
            for k_ in [k_ for k_ in invented[key] if k_.endswith(".bash")]:
                invented[key][k_.replace(".bash", ".invented")] = invented[key].pop(k_)
            invented[key]["reading_set"] = "invented"
        for side in ("written", "core"):
            for o_ in nulls["sides"][side]["shells"].values():
                o_.update(rc=None, stdout_sha256=None, stderr_sha256=None, other=None, files=None)
            for o_ in no_calls["sides"][side]["shells"].values():
                del o_["calls"]
        ten = list(prep(pos, gone_arg, other_out, no_run, no_words, no_runs, no_counts, twice, invented, nulls, no_calls))
        cnt10 = classify(ten, load_classes(), saved())
        check("the exact env -S row whose calls and effects hold is named by its conditions", [pos["status"], bool(pos.get("class_basis"))],
              ["class:script-payload-read", True])
        check("an argument gone from a call refuses the exact env -S row", gone_arg["status"], "unclassified")
        check("a stdout that differs refuses the exact env -S row", other_out["status"], "unclassified")
        check("a shell with no run refuses the exact env -S row", no_run["status"], "unclassified")
        check("A's words held nowhere refuse the exact env -S row", no_words["status"], "unclassified")
        check("runs that name no bytes refuse the exact env -S row, and their evidence is invalid",
              [no_runs["status"], bool(no_runs["evidence"]["invalid"])], ["unclassified", True])
        check("a row with no payload counts is invalid", no_counts["status"], "invalid")
        check("a reading named twice makes the row invalid", twice["status"], "invalid")
        check("a reading this file does not know makes the row invalid", invented["status"], "invalid")
        check("...and the three are counted apart", cnt10["invalid"], 3)
        check("null exit statuses, streams, other calls and files refuse the exact env -S row",
              [nulls["status"], bool(nulls["evidence"]["invalid"])], ["unclassified", True])
        check("runs with no calls refuse the exact env -S row", [no_calls["status"], bool(no_calls["evidence"]["invalid"])], ["unclassified", True])
        wfile = ""
        for text, payload, src in ((ENV_SPLIT_INPUT, "npm ci x", range(18, 26)), (crw, "npm ci x --ignore-scripts", range(52, 77))):
            wfile += "== %s\n" % json.dumps(text) + "".join("-- %s rc 0\n%s" % (r, words_out(payload, src)) for r in READING_NAMES)
        attached = erow(four(c10))
        del attached["words"], attached["words_rewrite"]
        prep(attached, words=parse_words_file(wfile.encode("utf-8")))
        classify([attached], load_classes(), saved())
        check("A's words attached name the exact env -S row as the row's own do", attached["status"], "class:script-payload-read")
    # 11. The intake: what is not evidence is never equal to anything, and is
    # in no count of what held; a reader's answer is read as it was kept and
    # never asked for again; a schema this file does not read is not guessed.
    nr = row(four(obs([["ci"]], rc=None)), four(obs([["ci"]], rc=None)))
    check("an exit status that is no evidence is no effect that held", side_verdict(nr, "core", saved())["effects"], "invalid")
    z1, z2 = adm(obs([["ci", ""]], rc=3)), adm(obs([["ci", ""]], rc=3))
    check("an exit status that is not 0, an empty argument and an empty stream are evidence",
          [axis(z1, "rc"), axis(z1, "npm"), axis(z1, "stdout"), relate(z1, z2, saved())["rc"]], ["ok", "ok", "ok", "same"])
    m = obs([["ci", "x"]])
    m["npm"] = [["ci", "y"]]
    check("npm calls that are not the npm calls of calls are invalid", axis(adm(m), "npm"), "invalid")
    o_a = adm(obs([["ci"]], other=[["pip", "install", "x"]]))
    o_b = obs([["ci"]], other=[["pip", "install", "x"]])
    o_b["calls"] = [["pip", "install", "x"], ["npm", "ci"]]
    check("npm and another stand-in that ran in another order differ in order", relate(o_a, adm(o_b), saved())["order"], "differ")
    inv = crow("rewrite unread\nselftest --ignore-scripts", {"decision": "run", "shells": four(obs([first, kept_arg], rc=None))})
    prep(inv)
    classify([inv], load_classes(), saved())
    acc11 = accounting([inv], saved())
    check("a row whose evidence is invalid is in no count of what ran",
          [len(acc11["evidence_invalid"]), acc11["ran_observed"], acc11["pairs"]["bash"]["rows"]], [1, 0, 0])
    sr0 = SavedReaders([{"argv": ["ci"], "gate": {"read": True, "ignore": "unset", "words": ["ci"], "switches": [], "values": []},
                         "npm": {"remain": ["ci"], "ignore": "unset", "canon": "ci"}}], {"source": "selftest"})
    check("a saved answer is read, and an argv with none is unknown and nothing asks",
          [sr0.install(["ci"]), sr0.install(["ci", "x"]), hasattr(sr0, "ask")], [True, None, False])
    dup = SavedReaders(sr0.answers() + sr0.answers(), {"source": "selftest"})
    check("an argv answered twice is believed in neither answer", [dup.install(["ci"]), len(dup.problems)], [None, 1])
    try:
        decode_report({"schema": 3, "rows": []})
        refused = False
    except Unsupported:
        refused = True
    check("a report of a schema this file does not read is not read", refused, True)
    sch, rows1 = decode_report({"rows": [{"set": "s", "command": "npm ci", "core_rc": 0, "ref": {}, "core": {}, "floor": "ok",
                                          "sides": {"written": {"calls": {sh: [["ci"]] for sh in SHELLS}}}}]})
    admit(rows1[0], 0, {"schema": sch, "source_sha256": "0" * 64, "provenance": provenance_of({}, sch), "words": {}, "floor_rows": None})
    w1 = rows1[0]["sides"]["written"]["shells"]["bash"]
    check("the first schema's npm calls are read, and what it did not keep (its floor's basis among it) is unknown",
          [sch, axis(w1, "npm"), axis(w1, "rc"), rows1[0]["evidence"]["invalid"], ineligible(rows1[0])],
          [1, "ok", UNKNOWN, [], "the run that measured it is not recorded"])
    # 12. The report: the source is kept as it was read, every evaluation
    # derives from it and its attachments again, and nothing derived is read
    # back as observed. A run that measured the source is its own record.
    run_ok = {"schema": SCHEMA, "argv": ["--selftest"], "harness_sha256": "0" * 64, "guard_sha256": "0" * 64,
              "classes_sha256": "0" * 64, "core_sha256": "1" * 64, "jobs": 1}

    def source(rows_, run=run_ok, readings=None):
        doc = {"schema": SCHEMA, "rows": rows_, "readings": R.answers() if readings is None else readings}
        if run is not None:
            doc["run"] = run
        return json.dumps(doc).encode("ascii")

    def again(src_bytes, atts=()):
        """One evaluation, the report written from it, that report read back
        as --reclassify reads it, and evaluated again."""
        ev1 = evaluate(src_bytes, list(atts))
        evaluation = {"rows": [{k: v for k, v in r.items() if not k.startswith("_")} for r in ev1["rows"]]}
        written = json.dumps(v3_report(src_bytes, {"kind": "report", "path": None}, list(atts), evaluation)).encode("ascii")
        b2, _, atts2, _ = load_input(written)
        return ev1, evaluate(b2, atts2), b2

    floor_lie = erow(four(c10), floor="NOT")
    ev1, ev2, b2 = again(source([floor_lie]))
    f1 = [x for x in ev1["rows"][0]["evidence"]["invalid"] if x.startswith("floor")]
    f2 = [x for x in ev2["rows"][0]["evidence"]["invalid"] if x.startswith("floor")]
    check("a saved floor at odds with its basis is found again from the report", [bool(f1), f1 == f2, b2 == source([floor_lie])],
          [True, True, True])
    ev_nr = evaluate(source([erow(four(c10))], run=None), [])
    check("a report with no run counts nothing as held", [ev_nr["provenance"][0], ineligible(ev_nr["rows"][0]) is not None], ["invalid", True])
    no_inst = erow(four(c10))
    del no_inst["core"]["any_install"]
    check("core records with no any_install make the row invalid", evaluate(source([no_inst]), [])["rows"][0]["status"], "invalid")
    ev_null = evaluate(source([erow(four(c10)), None]), [])
    check("a null row is a slot of its own, invalid, beside the rows that read",
          [len(ev_null["rows"]), ev_null["counts"]["invalid"], ev_null["rows"][1]["status"] if len(ev_null["rows"]) > 1 else None],
          [2, 1, "invalid"])
    ls_ = erow(four(c10))
    ls_["sides"] = []
    ev_ls = evaluate(source([ls_]), [])
    check("a list of sides makes its row invalid, and the row stays", [len(ev_ls["rows"]), ev_ls["rows"][0]["status"]], [1, "invalid"])
    rj = erow(four(c10))
    rj["ref"] = []
    s1_ = evaluate(source([erow(four(c10)), rj]), [])["rows"][1]
    check("a rejected slot keeps its ordinal, its display and where it was rejected, and none of the row's fields",
          [s1_["slot"], s1_["set"], s1_["command"], [(x["pointer"], x["type"]) for x in s1_["evidence"]["rejected"]],
           s1_["evidence"]["from"]["row"], "ref" in s1_, "sides" in s1_],
          ["rejected", "selftest", ENV_SPLIT_INPUT, [("/rows/1/ref", "array")], 2, False, False])
    ro = erow(four(c10))
    ro["sides"]["core"]["shells"]["bash"] = []
    r0_ = evaluate(source([ro]), [])["rows"][0]
    sh_ = r0_["sides"]["core"]["shells"]
    check("a shell's run that is no object is rejected in its place, invalid and not missing, and the other shells keep theirs",
          [r0_["slot"], sh_["bash"].get("rejected"), axis(sh_["bash"], "npm"), axis(sh_["zsh"], "npm")],
          ["admitted", "/rows/0/sides/core/shells/bash", "invalid", "ok"])
    pc = erow(four(c10))
    pc["core"]["payloads.bash"] = "99"
    prep(pc)
    check("a core payload count at odds with A's words makes the evidence invalid",
          any(x.startswith("core.payloads.bash") for x in pc["evidence"]["invalid"]), True)
    rec_ = erow(four(c10))
    prep(rec_)
    check("a record the run did not keep is computed apart, never written as kept",
          ["record" in rec_["sides"]["core"], rec_["sides"]["core"].get("_record")], [False, True])
    flipped = [dict(e_, install=not e_["install"]) if e_["argv"] == ["ci"] else e_ for e_ in R.answers()]
    rr = SavedReaders(flipped, {"source": "selftest"})
    check("a saved reader value at odds with its answers is not believed, and stays found",
          [any("install" in p_ for p_ in rr.problems), rr.install(["ci"])], [True, True])
    tmpd = tempfile.mkdtemp(prefix="o.", dir=work)
    src_f, link = os.path.join(tmpd, "in.json"), os.path.join(tmpd, "out.json")
    open(src_f, "w").write("{}")
    os.symlink(src_f, link)
    check("an output that is an input by another path is refused", overwrites([link], [src_f]), (link, src_f))
    try:
        evaluate(json.dumps({"schema": 3}).encode("ascii"), [])
        v3_src = False
    except Unsupported:
        v3_src = True
    check("a v3 report is never a source", v3_src, True)
    if R.npm_asked:
        wtext = "".join("== %s\n" % json.dumps(t_) + "".join("-- %s rc 0\n%s" % (r, words_out(p_, s_)) for r in READING_NAMES)
                        for t_, p_, s_ in ((ENV_SPLIT_INPUT, "npm ci x", range(18, 26)), (crw, "npm ci x --ignore-scripts", range(52, 77))))
        bare = erow(four(c10))
        del bare["words"], bare["words_rewrite"]
        mine = make_attachment("words", wtext.encode("utf-8"), None, "1" * 64)
        other = make_attachment("words", wtext.encode("utf-8"), None, "2" * 64)
        st_mine = evaluate(source([bare]), [mine])["rows"][0]["status"]
        st_other = evaluate(source([bare]), [other])["rows"][0]["status"]
        check("words of the core that measured the source are bound, and words of another core are not",
              [st_mine, st_other], ["class:script-payload-read", "unclassified"])
        e1, e2, _ = again(source([bare]), [mine])
        check("a replay of the report gives the same rows, issues and counts",
              [[(r.get("status"), r["evidence"]) for r in e1["rows"]] == [(r.get("status"), r["evidence"]) for r in e2["rows"]],
               e1["counts"] == e2["counts"]], [True, True])
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
    ap.add_argument("--floor-tree", default="", help="an extracted 7d66f8c: its whole pre-guard is asked of every row, and the rewrite "
                                                     "it sends is that row's floor where the recorded file has none")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--random", type=int, default=0)
    ap.add_argument("--seed", type=int, default=20261006)
    ap.add_argument("--report", default="")
    ap.add_argument("--control", action="store_true", help="damage the reference: drop the floor flag after every verb")
    ap.add_argument("--reclassify", default="", help="a saved --report: classify its rows again, running no guard, no shell and no reader")
    ap.add_argument("--reread", action="store_true", help="with --reclassify: ask the readers on this PATH again, as a new observation")
    ap.add_argument("--words", action="append", default=[], help="PATH=SHA256:PRODUCER of a words file (see The intake)")
    ap.add_argument("--floor-rewrites", default="", help="PATH=SHA256 of the recorded release rewrites a row's floor is held to")
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
    def stop(why):
        print("core-inert-differential: %s" % why, file=sys.stderr)
        sys.exit(2)

    atts, in_paths = [], [a.reclassify] + [e.split("=", 1)[1] for e in a.extra if "=" in e]
    for kind, spec in [("words", x) for x in a.words] + ([("floor-rewrites", a.floor_rewrites)] if a.floor_rewrites else []):
        path_, _, rest = spec.rpartition("=")
        want_, _, producer = rest.partition(":")
        try:
            if not path_ or not _hex(want_) or (kind == "words") != bool(producer):
                raise Unsupported("not PATH=SHA256" + (":PRODUCER" if kind == "words" else ""))
            raw = open(os.path.expanduser(path_), "rb").read()
            if sha256(raw) != want_:
                raise Unsupported("its bytes hash to %s" % sha256(raw))
            atts.append(make_attachment(kind, raw, path_, producer or None))
        except (OSError, Unsupported) as e:
            stop("the attachment %s does not read: %s" % (spec, e))
        in_paths.append(os.path.expanduser(path_))
    clash = overwrites([a.report, a.table, a.manifest], in_paths)
    if clash:
        stop("the output %s is the same file as the input %s: an input is never written over" % clash)
    if not a.core and not a.reclassify:
        stop("--core is required")
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
    row_opts = {}
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
                    if isinstance(r, dict) and (r.get("expect") or r.get("stand_ins")):
                        if r.get("stand_ins", "") not in STAND_INS:
                            sys.exit("core-inert-differential: %s names stand-ins this file does not have: %r" % (path_, r.get("stand_ins")))
                        if (name, c) in row_opts:
                            sys.exit("core-inert-differential: %s holds a command twice: %r" % (path_, c))
                        row_opts[(name, c)] = {"expect": r.get("expect"), "stand_ins": r.get("stand_ins", "")}
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
    observing = bool(a.shells or a.release_tree or a.floor_tree or a.evidence)
    shells = Shells(work) if observing else None
    rel_guard = os.path.join(os.path.abspath(os.path.expanduser(a.release_tree)), "scripts", "safedeps-pre-guard.sh") if a.release_tree else ""
    floor_guard = os.path.join(os.path.abspath(os.path.expanduser(a.floor_tree)), "scripts", "safedeps-pre-guard.sh") if a.floor_tree else ""
    for g in (rel_guard, floor_guard):
        if g and not os.path.isfile(g) and not a.reclassify:
            sys.exit("core-inert-differential: no pre-guard at %s" % g)
    floor_rows = {}
    if a.floor and not a.reclassify:
        # The recorded release rewrites this run holds its rows to: read once,
        # and attached to the report, bytes and sha256.
        fpath = os.path.join(ROOT, FLOOR_FILE)
        fraw = open(fpath, "rb").read()
        try:
            at = make_attachment("floor-rewrites", fraw, FLOOR_FILE, None)
        except Unsupported as e:
            stop("%s does not read: %s" % (fpath, e))
        floor_rows = at["parsed"]
        atts.append(at)

    def box_env(box, extra=None, release=False):
        env = {"PATH": rpath if release else path, "HOME": os.path.join(box, "home"), "SAFEDEPS_HOME": os.path.join(box, "sd"), "LANG": "en_US.UTF-8", "TMPDIR": box}
        os.makedirs(env["HOME"], exist_ok=True)
        if extra:
            env.update(extra)
        return env

    def release_side(cmd, idx, box, guard=None, var=""):
        """A tree's whole pre-guard's answer (the --release-tree's, or the
        one named), and what its command does under the shells."""
        tree_guard = guard or rel_guard
        rbox = tempfile.mkdtemp(prefix="r.", dir=box)
        rproj = os.path.join(rbox, "project")
        os.makedirs(rproj)
        open(os.path.join(rproj, "package.json"), "w").write('{"name":"p","version":"1.0.0","dependencies":{}}\n')
        env = box_env(rbox, release=True)
        for ap_ in a.approve:
            eco, name_, ver = ap_.split(":")
            subprocess.run(["bash", os.path.join(os.path.dirname(os.path.dirname(tree_guard)), "lib", "ledger", "ledger.sh"),
                            "approve", eco, name_, ver, ver, "inert-differential"], env=env, capture_output=True, timeout=60)
        r = subprocess.run(["nice", "-n", "10", "bash", tree_guard], input=payload(cmd, rproj, "toolu_inert%d" % idx),
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
        return {"decision": "run", "run": run, "shells": shells.observe(run, box, stand_ins=var), "record": rec, "guard_rc": r.returncode,
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
        opts = row_opts.get((name, cmd), {})
        var = opts.get("stand_ins", "")
        if var:
            res["stand_ins"] = var
        if opts.get("expect"):
            res["expect"] = opts["expect"]
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
        # A's words records of the command in each of the three readings
        # (`safedeps-core words`), kept whole, and how many payloads the
        # command's own top level hands on there, read from those records by
        # their lengths. A reading that could not be asked is None, never 0.
        def words(text):
            out = {"text": text.decode("utf-8", "surrogateescape"), "readings": {}}
            counts_ = {}
            for rd in READING_NAMES:
                w = subprocess.run(["nice", "-n", "10", a.core, "words"], input=text, capture_output=True,
                                   env=box_env(box, {"SAFEDEPS_READING": rd}), cwd=proj, timeout=60)
                out["readings"][rd] = {"rc": w.returncode, "stdout": w.stdout.decode("latin-1"), "stdout_sha256": sha256(w.stdout)}
                got_w = words_records(w.stdout) if w.returncode == 0 else None
                counts_[rd] = len(got_w[0]["payloads"]) if got_w and got_w[1] == len(w.stdout) else None
            return out, counts_

        cb = cmd_bytes(cmd)
        res["words"], res["payloads3"] = words(cb)
        res["ref"] = {k: v.decode("latin-1") for k, v in ref.items()}
        res["core"] = {k: v.decode("latin-1") for k, v in got.items()}
        o_core = consensus(got, cb) if got else None
        if isinstance(o_core, tuple) and o_core[0] == "rewrite" and o_core[2] != cb:
            res["words_rewrite"], _ = words(o_core[2])
        differs = ref and got and any(ref.get(k) != got.get(k) for k in set(ref) | set(got) if k.startswith("inert.") or k == "failed")
        if a.shells or rel_guard or floor_guard or (a.evidence and differs):
            sides = {"written": {"decision": "run", "run": cmd, "shells": shells.observe(cmd, box, stand_ins=var)}}
            for side, recs in (("bash", ref), ("core", got)):
                if not recs or recs.get("any_install") != b"true":
                    continue
                o = consensus(recs, cb)
                if o is None:
                    continue
                if o == "blocked":
                    sides[side] = {"decision": "blocked", "why": "its duties collide: " + ", ".join(blocked_kinds(recs))}
                    continue
                if o == "deny" or recs.get("failed") == b"true":
                    sides[side] = {"decision": "deny", "why": "its readings disagree" if o == "deny" else "its reading failed"}
                    continue
                run = o[2].decode("utf-8", "surrogateescape")
                sides[side] = {"decision": "run", "run": run, "record": bool(records_of(o)), "shells": shells.observe(run, box, stand_ins=var)}
            if rel_guard:
                sides["v2.18.1"] = release_side(cmd, idx, box, rel_guard, var)
            if floor_guard:
                sides["7d66f8c"] = release_side(cmd, idx, box, floor_guard, var)
            res["sides"] = sides
        # What this row's floor is held to, as the run measured it; its value
        # is the evaluation's.
        if a.floor and cmd in floor_rows:
            res["floor_basis"] = FLOOR_FILE
        elif "7d66f8c" in res.get("sides", {}):
            res["floor_basis"] = FLOOR_TREE
        shutil.rmtree(box, ignore_errors=True)
        return idx, res

    run_info = {"schema": SCHEMA, "argv": sys.argv[1:], "harness_sha256": sha256(open(os.path.abspath(__file__), "rb").read()),
                "classes_sha256": sha256(open(os.path.join(MEASURE, "core-intended-inert.tsv"), "rb").read()),
                "guard_sha256": sha256(open(GUARD, "rb").read()), "core": a.core or None,
                "core_sha256": sha256(open(a.core, "rb").read()) if a.core and os.path.isfile(a.core) else None,
                "release_guard_sha256": sha256(open(rel_guard, "rb").read()) if rel_guard and os.path.isfile(rel_guard) else None,
                "floor_guard_sha256": sha256(open(floor_guard, "rb").read()) if floor_guard and os.path.isfile(floor_guard) else None,
                "shells": shells.info if shells else None, "jobs": jobs}
    commit = os.path.join(os.path.dirname(ROOT), "commit")
    if os.path.isfile(commit):
        run_info["tree_commit"] = open(commit).read().strip()
    prior, in_sha = None, None
    if a.reclassify:
        try:
            raw = open(a.reclassify, "rb").read()
            src_bytes, src_info, carried, prior = load_input(raw)
            atts = merge_attachments(carried + atts)
        except (OSError, Unsupported) as e:
            stop("%s is not a report this file reads: %s" % (a.reclassify, e))
        in_sha = sha256(raw)
        src_info = src_info or {"kind": "report", "path": a.reclassify}
        up0 = up1 = ""
    else:
        up0 = subprocess.run(["uptime"], capture_output=True, text=True).stdout.strip()
        raw_rows = [None] * len(rows)
        with ThreadPoolExecutor(max_workers=jobs) as ex:
            for idx, res in ex.map(one, list(enumerate(rows))):
                raw_rows[idx] = res
        up1 = subprocess.run(["uptime"], capture_output=True, text=True).stdout.strip()
        # The readers, asked in this run of every npm argv a run made. Their
        # answers are part of what this run observed.
        argvs = [x for res in raw_rows for v in (res.get("sides") or {}).values() if isinstance(v, dict) and isinstance(v.get("shells"), dict)
                 for o in v["shells"].values() if isinstance(o, dict) and _argvs(o.get("npm")) for x in o["npm"]]
        live = Readers(work, rpath)
        live.ask(argvs)
        run_info["npm_parser"] = {"asked": live.npm_asked, "version": live.npm_version, "error": live.npm_error}
        snapshot = {"schema": SCHEMA, "run": run_info, "load": [up0, up1], "readings": live.answers(), "rows": raw_rows}
        # A row whose core side makes a call without the flag and writes no
        # record: what the head's whole pre-guard answers for that command,
        # asked now and kept with the rest of what this run observed. The
        # inert rewrite is one step of the guard; a command it denies runs
        # nothing.
        if observing:
            try:
                pre = evaluate(json.dumps(snapshot).encode("ascii"), atts)
            except Unsupported as e:
                stop("this run's own observations do not read: %s" % e)
            for k, res in enumerate(pre["rows"]):
                if res.get("slot") != "admitted":
                    continue
                cs_ = res.get("sides", {}).get("core", {})
                if isinstance(cs_.get("shells"), dict) and any(state(o, side_record(cs_), pre["readers"]) == "SILENT"
                                                               for o in cs_["shells"].values()):
                    box = tempfile.mkdtemp(prefix="h.", dir=work)
                    raw_rows[k].setdefault("sides", {})["head"] = whole_guard(GUARD, res["command"], "toolu_head%d" % k, box)
                    shutil.rmtree(box, ignore_errors=True)
        src_bytes = json.dumps(snapshot).encode("ascii")
        src_info = {"kind": "live", "path": None}

    try:
        ev = evaluate(src_bytes, atts)
        if a.reclassify and a.reread:
            # A new observation: the readers on this PATH asked again of every
            # npm argv that is evidence. The saved answers stay in the source.
            argvs = [x for res in admitted(ev["rows"]) for v in res.get("sides", {}).values()
                     if isinstance(v.get("shells"), dict) for o in v["shells"].values() if calls_known(o) for x in o["npm"]]
            live = Readers(work, rpath)
            live.ask(argvs)
            ev = evaluate(src_bytes, atts, SavedReaders(live.answers(), {"source": "asked again on this PATH (--reread): a new observation",
                                                                          "path": rpath, "npm_version": live.npm_version,
                                                                          "npm_error": live.npm_error}))
    except Unsupported as e:
        stop("%s does not read as a source: %s" % (a.reclassify or "this run's snapshot", e))
    results, R = ev["rows"], ev["readers"]
    src_info = dict(src_info, schema=ev["schema"])
    if a.reclassify and ev["load"]:
        up0, up1 = (ev["load"] + ["", ""])[:2]

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

    counts = ev["counts"]
    summary, red = summarize(results, counts, R, a, {"up0": up0, "up1": up1, "reach": reach, "provenance": ev["provenance"]})
    emitted = {"contract": CONTRACT, "harness_sha256": run_info["harness_sha256"], "classes_sha256": run_info["classes_sha256"],
               "tree_commit": run_info.get("tree_commit"), "argv": sys.argv[1:],
               "input": {"path": a.reclassify or None, "sha256": in_sha}, "replayed_from": prior,
               "readers": dict(R.source, held=len(R.gate), problem_count=len(R.problems), rederived=R.rederived),
               "attachments": [{"kind": at["kind"], "path": at["path"], "sha256": at["sha256"], "producer": at["producer"],
                                "bound": at["sha256"] in ev["bound"]} for at in atts],
               "load": [up0, up1]}
    head = {"contract": CONTRACT, "source": dict(src_info, sha256=sha256(src_bytes)),
            "provenance": {"state": ev["provenance"][0], "why": ev["provenance"][1]}, "emitted_by": emitted}
    if a.table:
        with open(a.table, "w", encoding="utf-8") as f:
            for res in results:
                cv = res.get("obs", {}).get("core")
                f.write("%s\t%s\t%s\t%s\t%s\t%s\t%s\n" % (res.get("set"), res.get("status", ""), res.get("label", ""), ",".join(res.get("tokens") or []),
                                                          ("npm %s, effects %s" % (cv["npm"], cv["effects"])) if cv else "",
                                                          res.get("bash_exit", ""), json.dumps(res.get("command"), ensure_ascii=False)))
    if a.manifest:
        manifest(a.manifest, results, head)
    if a.report:
        evaluation = {"emitted_by": emitted, "provenance": head["provenance"], "source_schema": ev["schema"],
                      "readings": R.answers(), "reader_problems": R.problems, "summary": summary,
                      "rows": [{k: v for k, v in res.items() if not k.startswith("_")} for res in results]}
        json.dump(v3_report(src_bytes, src_info, atts, evaluation), open(a.report, "w"), ensure_ascii=False, indent=1)
    shutil.rmtree(work, ignore_errors=True)
    if a.control:
        print("control: the damaged reference differs on %d commands" % counts["differ"])
        sys.exit(0 if counts["differ"] else 1)
    sys.exit(1 if red else 0)


if __name__ == "__main__":
    main()
