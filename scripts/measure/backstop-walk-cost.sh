#!/usr/bin/env bash
# safedeps: what the backstop's trace check costs.
#
# The PostToolUse backstop asks whether a command it did not see as an install
# wrote the project's node tree. One of the checks walks node_modules for an
# entry whose status changed after the baseline the pre-guard touched. A
# command that wrote nothing is the worst case: the walk finds nothing, so it
# visits every entry. The walk has a deadline (SAFEDEPS_BACKSTOP_WALK_SECONDS in
# the post hook), and a walk that does not finish counts as a trace. Any number
# quoted for that deadline comes from here, measured on the host that quotes it.
#
# Two things are measured:
#
#   walk   `find -H node_modules -cnewer <baseline> -print -quit` over a
#          synthetic tree in which nothing is newer than the baseline. The
#          tree is packages of 116 entries each (a package.json, three more
#          files, a lib directory of ten directories of ten files), copied
#          side by side until the tree holds about the asked number of
#          entries. The page cache is warm: the tree was just written, and the
#          host is not asked to drop it.
#   pre    the whole pre-guard, through the entry shim, on a command that names
#          no install (`ls -la`) and on one the backstop pattern matches but
#          the lexer does not read as an install (`grep -n "npm install"
#          README.md`). Run it once in a tree before the change and once after
#          to read what the trace entry costs.
#
# Usage:
#   scripts/measure/backstop-walk-cost.sh [--reps N] [walk|pre] [ENTRIES...]
#
# The default is both, with 3 reps, at 10000 50000 100000 250000 500000 entries.
set -uo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "${REPO_DIR}"

REPS=3
WHAT="walk pre"
SIZES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --reps) REPS="${2:-3}"; shift 2 ;;
    walk|pre) WHAT="$1"; shift ;;
    *) SIZES+=("$1"); shift ;;
  esac
done
[[ ${#SIZES[@]} -eq 0 ]] && SIZES=(10000 50000 100000 250000 500000)

WORK=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-walk-cost.XXXXXX")
trap 'rm -rf "${WORK}"' EXIT

printf '# host %s, %s, bash %s, find %s\n' "$(uname -n)" "$(uname -sr)" "${BASH_VERSION}" "$(command -v find)"
printf '# load at start: %s\n' "$(uptime | sed 's/.*load averages*: //')"

# Seconds of one command, with millisecond digits.
seconds_of() {
  local TIMEFORMAT=%3R
  { time "$@" > /dev/null 2>&1; } 2>&1
}
# min / median / max of the numbers on stdin.
spread() { sort -n | awk '{ v[NR] = $1 } END { printf "%s / %s / %s", v[1], v[int((NR + 1) / 2)], v[NR] }'; }

if [[ " ${WHAT} " == *" walk "* ]]; then
  template="${WORK}/template/pkg"
  mkdir -p "${template}/lib"
  for f in package.json index.js README.md LICENSE; do printf 'x\n' > "${template}/${f}"; done
  for d in 0 1 2 3 4 5 6 7 8 9; do
    mkdir -p "${template}/lib/d${d}"
    for f in 0 1 2 3 4 5 6 7 8 9; do printf 'x\n' > "${template}/lib/d${d}/f${f}.js"; done
  done
  per_package=$(find "${template}" | wc -l | tr -d ' ')
  printf '# walk: entries, packages, build seconds, walk seconds min / median / max over %s reps\n' "${REPS}"
  for size in "${SIZES[@]}"; do
    tree="${WORK}/tree-${size}"
    mkdir -p "${tree}/node_modules"
    packages=$(( size / per_package ))
    build_start=${SECONDS}
    i=0
    while (( i < packages )); do
      cp -R "${template}" "${tree}/node_modules/p${i}"
      i=$(( i + 1 ))
    done
    build=$(( SECONDS - build_start ))
    entries=$(find "${tree}/node_modules" | wc -l | tr -d ' ')
    sleep 2
    touch "${tree}/baseline"
    found=$(find -H "${tree}/node_modules" -cnewer "${tree}/baseline" -print -quit 2>/dev/null)
    [[ -z "${found}" ]] || { printf 'walk-cost: %s is newer than the baseline; the walk would stop early\n' "${found}" >&2; exit 1; }
    times=$(for _ in $(seq 1 "${REPS}"); do
      seconds_of find -H "${tree}/node_modules" -cnewer "${tree}/baseline" -print -quit
    done)
    printf '%s\t%s\t%ss\t%s\n' "${entries}" "${packages}" "${build}" "$(spread <<< "${times}")"
    rm -rf "${tree}"
  done
fi

if [[ " ${WHAT} " == *" pre "* ]]; then
  project="${WORK}/project"
  mkdir -p "${project}/node_modules"
  printf '{"name":"walk-cost","version":"1.0.0"}\n' > "${project}/package.json"
  printf 'run npm install to set up\n' > "${project}/README.md"
  export SAFEDEPS_HOME="${WORK}/home"
  mkdir -p "${SAFEDEPS_HOME}"
  printf '# pre (%s): command, seconds min / median / max over %s reps\n' "$(git -C "${REPO_DIR}" rev-parse --short HEAD 2>/dev/null || printf 'no git')" "${REPS}"
  for command in 'ls -la' 'grep -n \"npm install\" README.md'; do
    payload=$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"cwd":"%s"}' "${command}" "${project}")
    times=$(for _ in $(seq 1 "${REPS}"); do
      seconds_of sh -c 'printf "%s" "$1" | "$2" pre' sh "${payload}" "${REPO_DIR}/scripts/safedeps-hook-entry.sh"
    done)
    printf '%s\t%s\n' "${command}" "$(spread <<< "${times}")"
  done
fi
printf '# load at end: %s\n' "$(uptime | sed 's/.*load averages*: //')"
