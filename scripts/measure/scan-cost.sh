#!/usr/bin/env bash
# safedeps: measure the PreToolUse guard's cost against command size.
#
# The pre-guard's cost is bound by the command text, and the runtime kills the
# hook at its registered timeout and lets the tool call proceed. So the question
# this answers is not "is it fast" but "at what command size does the gate stop
# existing". Any number written into a doc or a code comment about that crossing
# comes from here, re-measured on the host that quotes it -- a crossing point
# from someone else's machine is decoration.
#
# Two things are measured separately, because they answer different questions:
#
#   scan   command_scan_text alone, extracted from the guard. This is the
#          function the size curve was about.
#   views  every view of the lexer (shell_lex) once, in the bash reading, on
#          the loud input. The scan view is one of twelve, and the readers of
#          the others build words and lines out of the bytes: the cscripts view
#          cost 12.9s at 64KB on an M1 while the scan stayed at 0.2s, so a
#          scan column alone said "linear" over a gate that was not.
#   gate   the whole hook, end to end, through the real entry path. This is
#          what the runtime's timeout actually applies to, and it includes the
#          per-call cost of everything else the guard does.
#
# Each size is measured in two shapes, because they take different paths:
#
#   quiet  no install text anywhere. The common case, and the one the old
#          quadratic loop punished for nothing.
#   loud   the same size with a real install at the end. Runs the full
#          predicate set, not just the scan.
#   split  loud, opened with `((n++))`: a place where bash, zsh and dash read
#          differently, so the guard reads the command three times instead of
#          once (gate column only).
#
# A second table measures the gate against the number of statements, not the
# bytes: statement readers ask about each statement, so a short command of many
# statements cost more than a long command of one (a 1KB `sh -c` script of
# short functions took 23s on Linux, where a 64KB install took 3s). Two shapes,
# each with an install the gate has to judge:
#
#   lines   N one-line statements (`echo line<k>`), then `npm install` on its
#           own line.
#   script  `sh -c` with a script of N short function definitions, then an
#           install. Each definition is three statements to a statement
#           reader, and the `(1)` in it is a place where the shells read
#           differently, so the guard reads the command three times.
#
# A cell that passes the cap (--cap, default 120s) reads `>CAP`, and the larger
# counts of that shape are skipped.
#
# Usage:
#   scripts/measure/scan-cost.sh [SIZE_BYTES...]        # default sweep
#   scripts/measure/scan-cost.sh --reps 5 32000 65536
#   scripts/measure/scan-cost.sh --statements 100,400,3200 --cap 60 8192
#
# Sizes are approximate command lengths in bytes.
#
# The gate column runs with SAFEDEPS_BUDGET_DISABLED, which is the guard's named
# lever for turning its own deadline off and logs every use. That is deliberate:
# with the deadline on, the gate column would report the deadline rather than
# the cost, which is the quantity this file exists to measure.
set -uo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "${REPO_DIR}"

REPS=3
CAP=120
SIZES=()
COUNTS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --reps) REPS="${2:-3}"; shift 2 ;;
    --cap) CAP="${2:-120}"; shift 2 ;;
    --statements) IFS=, read -ra COUNTS <<< "${2:-}"; shift 2 ;;
    *) SIZES+=("$1"); shift ;;
  esac
done
[[ ${#SIZES[@]} -eq 0 ]] && SIZES=(1000 4000 8000 16000 32000 65536)
[[ ${#COUNTS[@]} -eq 0 ]] && COUNTS=(40 100 400 1600 3200)

command -v python3 > /dev/null || { printf 'scan-cost: python3 is required for timing and input generation\n' >&2; exit 2; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-scan-cost.XXXXXX")
trap 'rm -rf "${WORK}"' EXIT
PROJECT="${WORK}/project"
mkdir -p "${PROJECT}"
printf '{"dependencies":{}}\n' > "${PROJECT}/package.json"

# The scan is extracted rather than sourced: the guard is an executable hook
# with no source guard, so sourcing it would run the whole judgment.
scan_src=$(sed -n '/^shell_lex() {/,/^}/p; /^command_scan_text() {/,/^}/p' scripts/safedeps-pre-guard.sh)
[[ -n "${scan_src}" ]] || { printf 'scan-cost: command_scan_text not found in the guard\n' >&2; exit 2; }
eval "${scan_src}"
# The scan column times one reading, the bash one: the guard's first, and the
# only one a command reaches unless it passes a place where the shells differ.
SAFEDEPS_READING=bash

now() { python3 -c 'import time; print(time.time())'; }
elapsed() { python3 -c "print(f'{$2 - $1:.3f}')"; }

# Report the load average alongside the numbers. A timing batch whose machine
# condition was not recorded cannot be compared with another batch, and
# inferring "the machine was quiet" from who was working is how this repo
# previously mismeasured exactly this kind of sweep.
load_now() { uptime | sed -E 's/.*load averages?: *//' | awk '{print $1}'; }

make_input() {
  local size="$1" shape="$2"
  case "${shape}" in
    quiet) python3 -c "print('echo ' + 'x' * max(0, ${size} - 5), end='')" ;;
    loud)  python3 -c "print('echo ' + 'x' * max(0, ${size} - 40) + ' ; npm install left-pad@1.0.0', end='')" ;;
    split) python3 -c "print('((n++)); echo ' + 'x' * max(0, ${size} - 50) + ' ; npm install left-pad@1.0.0', end='')" ;;
  esac
}

# The statements shapes, N statements each (see the header).
make_statements() {
  python3 -c '
import sys
count, shape = int(sys.argv[1]), sys.argv[2]
if shape == "lines":
    sys.stdout.write("".join("echo line%d\n" % k for k in range(count)) + "npm install left-pad@1.0.0")
else:
    unit = "f() { echo \x27a b\x27 \\\"$x\\\" (1); }; "
    sys.stdout.write("sh -c \"" + unit * count + "\" ; npm install left-pad@1.0.0")
' "$1" "$2"
}

time_scan() {
  local input="$1" s e best="" i t
  for ((i = 0; i < REPS; i++)); do
    s=$(now); command_scan_text "${input}" > /dev/null; e=$(now)
    t=$(elapsed "${s}" "${e}")
    if [[ -z "${best}" ]] || python3 -c "import sys; sys.exit(0 if ${t} < ${best} else 1)"; then best="${t}"; fi
  done
  printf '%s' "${best}"
}

LEX_VIEWS="scan code live flat noredir pieces cscripts stmts recognize stmtcuts stmtraw substs unprefixed shell-bodies"
time_views() {
  local input="$1" s e best="" i t v
  for ((i = 0; i < REPS; i++)); do
    s=$(now)
    for v in ${LEX_VIEWS}; do shell_lex "${input}" "${v}" "safedeps:scan-cost" > /dev/null; done
    e=$(now)
    t=$(elapsed "${s}" "${e}")
    if [[ -z "${best}" ]] || python3 -c "import sys; sys.exit(0 if ${t} < ${best} else 1)"; then best="${t}"; fi
  done
  printf '%s' "${best}"
}

time_gate() {
  local input="$1" s e best="" i t safe payload
  payload="${WORK}/payload.json"
  # From a file: one argument over 128KB is E2BIG on Linux.
  printf '%s' "${input}" > "${WORK}/command"
  jq -nc --rawfile c "${WORK}/command" --arg cwd "${PROJECT}" \
    '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}' > "${payload}"
  for ((i = 0; i < REPS; i++)); do
    safe=$(mktemp -d "${WORK}/safe.XXXXXX")
    s=$(now)
    HOME="${WORK}/home" SAFEDEPS_HOME="${safe}" SAFEDEPS_BUDGET_DISABLED=1 \
      bash scripts/safedeps-pre-guard.sh < "${payload}" > /dev/null 2>&1
    e=$(now)
    t=$(elapsed "${s}" "${e}")
    if [[ -z "${best}" ]] || python3 -c "import sys; sys.exit(0 if ${t} < ${best} else 1)"; then best="${t}"; fi
  done
  printf '%s' "${best}"
}

printf 'safedeps scan cost — best of %s reps per cell, load average %s at start\n' "${REPS}" "$(load_now)"
printf 'READ THIS BEFORE QUOTING THE GATE COLUMNS: they run with the guard'"'"'s own\n'
printf 'deadline DISABLED, so they are the UNBOUNDED cost, not the latency a user\n'
printf 'sees. With the deadline on, an over-budget command is denied UNDECIDED in\n'
printf 'about the budget. Quoting a gate number as "how long the hook takes" is\n'
printf 'wrong, and it was misread that way within an hour of this file existing.\n'
printf 'bash %s, awk %s\n\n' "${BASH_VERSION}" "$(awk --version 2>/dev/null | head -1 || echo 'BWK awk (no --version)')"
printf '%-10s %-12s %-12s %-12s %-12s %-12s %-12s\n' 'size' 'scan quiet' 'scan loud' 'views loud' 'gate quiet' 'gate loud' 'gate split'

for size in "${SIZES[@]}"; do
  quiet=$(make_input "${size}" quiet)
  loud=$(make_input "${size}" loud)
  split=$(make_input "${size}" split)
  printf '%-10s %-12s %-12s %-12s %-12s %-12s %-12s\n' \
    "${size}B" \
    "$(time_scan "${quiet}")s" \
    "$(time_scan "${loud}")s" \
    "$(time_views "${loud}")s" \
    "$(time_gate "${quiet}")s" \
    "$(time_gate "${loud}")s" \
    "$(time_gate "${split}")s"
done

# The whole gate on one input, with the deadline off and the cap above: the
# run and every process under it are stopped one by one past the cap, never
# by process group (on the project's VM every process shares one).
descendants() { local c; for c in $(pgrep -P "$1" 2>/dev/null); do descendants "${c}"; printf '%s\n' "${c}"; done; }
time_gate_capped() {
  local input="$1" s e best="" i t safe payload pid kids over
  payload="${WORK}/payload.json"
  # From a file: one argument over 128KB is E2BIG on Linux.
  printf '%s' "${input}" > "${WORK}/command"
  jq -nc --rawfile c "${WORK}/command" --arg cwd "${PROJECT}" \
    '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}' > "${payload}"
  for ((i = 0; i < REPS; i++)); do
    safe=$(mktemp -d "${WORK}/safe.XXXXXX")
    s=$(now)
    HOME="${WORK}/home" SAFEDEPS_HOME="${safe}" SAFEDEPS_BUDGET_DISABLED=1 \
      bash scripts/safedeps-pre-guard.sh < "${payload}" > /dev/null 2>&1 &
    pid=$! over=""
    while kill -0 "${pid}" 2>/dev/null; do
      sleep 0.2
      if python3 -c "import time, sys; sys.exit(0 if time.time() - ${s} > ${CAP} else 1)"; then
        kids=$(descendants "${pid}")
        kill "${pid}" 2>/dev/null || true
        for t in ${kids}; do kill "${t}" 2>/dev/null || true; done
        over=1
        break
      fi
    done
    wait "${pid}" 2>/dev/null || true
    e=$(now)
    if [[ -n "${over}" ]]; then printf '>%s' "${CAP}"; return; fi
    t=$(elapsed "${s}" "${e}")
    if [[ -z "${best}" ]] || python3 -c "import sys; sys.exit(0 if ${t} < ${best} else 1)"; then best="${t}"; fi
  done
  printf '%s' "${best}"
}

printf '\n%-10s %-12s %-12s %-12s %-12s\n' 'statements' 'lines bytes' 'gate lines' 'script bytes' 'gate script'
capped=" "
for count in "${COUNTS[@]}"; do
  lines=$(make_statements "${count}" lines)
  script=$(make_statements "${count}" script)
  cell_lines="-" cell_script="-"
  if [[ "${capped}" != *" lines "* ]]; then
    cell_lines="$(time_gate_capped "${lines}")s"
    [[ "${cell_lines}" != ">"* ]] || capped+="lines "
  fi
  if [[ "${capped}" != *" script "* ]]; then
    cell_script="$(time_gate_capped "${script}")s"
    [[ "${cell_script}" != ">"* ]] || capped+="script "
  fi
  printf '%-10s %-12s %-12s %-12s %-12s\n' "${count}" "${#lines}B" "${cell_lines}" "${#script}B" "${cell_script}"
done

printf '\nload average %s at finish\n' "$(load_now)"
printf 'The registered PreToolUse timeout is the number to compare against; the\n'
printf 'guard reads it as PRE_HOOK_TIMEOUT_SECONDS and the installer registers it.\n'
printf 'Past that, the runtime kills the hook and the command runs unjudged.\n'
