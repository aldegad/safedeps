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
#
# Usage:
#   scripts/measure/scan-cost.sh [SIZE_BYTES...]        # default sweep
#   scripts/measure/scan-cost.sh --reps 5 32000 65536
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
SIZES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --reps) REPS="${2:-3}"; shift 2 ;;
    *) SIZES+=("$1"); shift ;;
  esac
done
[[ ${#SIZES[@]} -eq 0 ]] && SIZES=(1000 4000 8000 16000 32000 65536)

command -v python3 > /dev/null || { printf 'scan-cost: python3 is required for timing and input generation\n' >&2; exit 2; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-scan-cost.XXXXXX")
trap 'rm -rf "${WORK}"' EXIT
PROJECT="${WORK}/project"
mkdir -p "${PROJECT}"
printf '{"dependencies":{}}\n' > "${PROJECT}/package.json"

# The scan is extracted rather than sourced: the guard is an executable hook
# with no source guard, so sourcing it would run the whole judgment.
scan_src=$(sed -n '/^command_scan_text() {/,/^}/p' scripts/safedeps-pre-guard.sh)
[[ -n "${scan_src}" ]] || { printf 'scan-cost: command_scan_text not found in the guard\n' >&2; exit 2; }
eval "${scan_src}"

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
  esac
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

time_gate() {
  local input="$1" s e best="" i t safe payload
  payload="${WORK}/payload.json"
  jq -nc --arg c "${input}" --arg cwd "${PROJECT}" \
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
printf 'bash %s, awk %s\n\n' "${BASH_VERSION}" "$(awk --version 2>/dev/null | head -1 || echo 'BWK awk (no --version)')"
printf '%-10s %-12s %-12s %-12s %-12s\n' 'size' 'scan quiet' 'scan loud' 'gate quiet' 'gate loud'

for size in "${SIZES[@]}"; do
  quiet=$(make_input "${size}" quiet)
  loud=$(make_input "${size}" loud)
  printf '%-10s %-12s %-12s %-12s %-12s\n' \
    "${size}B" \
    "$(time_scan "${quiet}")s" \
    "$(time_scan "${loud}")s" \
    "$(time_gate "${quiet}")s" \
    "$(time_gate "${loud}")s"
done

printf '\nload average %s at finish\n' "$(load_now)"
printf 'The registered PreToolUse timeout is the number to compare against; the\n'
printf 'guard reads it as PRE_HOOK_TIMEOUT_SECONDS and the installer registers it.\n'
printf 'Past that, the runtime kills the hook and the command runs unjudged.\n'
