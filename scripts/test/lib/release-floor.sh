#!/usr/bin/env bash
# The floor under the inert rewrite, checked on every rewrite a battery sees:
# deleting from this tree's rewrite some of the `--ignore-scripts` flags it
# inserted gives 7d66f8c's rewrite of the same command (the tree, during the
# v2.18.0 cycle, before the rewrite read the install's words; it is not the
# published v2.17.2, bb0787d). So npm receives at least the words 7d66f8c
# gave it, whatever the shell does to the command,
# and the flags placed by reading only add to them. Whether npm keeps the flag
# is decided by shell state the command does not hold (a function or alias in
# the agent's shell snapshot, .zshenv, BASH_ENV), so no reading can promise
# it; this property is what can be promised, and it holds by construction
# (inert_rewrite_in_place), not form by form.
#
# 7d66f8c's rewrites are measured, not derived: scripts/test/inert-release-
# rewrites.json holds, for each command a battery rewrites, what 7d66f8c's
# own pre-guard printed for it (null: it printed no rewrite), with the
# battery's temporary root written as <tmp>. A command missing from it fails,
# so a new row is recorded before it is checked. To record, run the battery
# with SAFEDEPS_RELEASE_HOOK=<a 7d66f8c checkout>/scripts/safedeps-pre-guard.sh
# and SAFEDEPS_RELEASE_RECORD=<file>: each rewrite then runs that hook
# on the same payload, in a copy of the project and the safedeps home, and
# appends the pair; merge the file into the JSON (scripts/test/lib/
# release-floor-merge.py).
#
# Needs fail(), jq and python3. The check usually runs inside a command
# substitution, where fail() would end only that subshell, so a violation is
# written to RELEASE_FLOOR_FAILS and release_floor_settle fails the battery
# with every one of them.

release_floor_fail() {
  printf 'not ok - %s\n' "$1" >&2
  printf '%s\n' "$1" >> "${RELEASE_FLOOR_FAILS:?}"
  return 1
}

# release_floor_settle: fails the battery with the violations seen, and says
# how many rewrites were checked.
release_floor_settle() {
  if [[ -s "${RELEASE_FLOOR_FAILS:?}" ]]; then
    fail "deleting flags this tree inserted gives the release's rewrite, for every rewrite: $(wc -l < "${RELEASE_FLOOR_FAILS}" | tr -d ' ') did not ($(head -3 "${RELEASE_FLOOR_FAILS}" | paste -sd'|' -))"
  fi
}

RELEASE_FLOOR_CORPUS="${RELEASE_FLOOR_CORPUS:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/inert-release-rewrites.json}"

# release_floor_key <text> <tmp root>: the text with the battery's temporary
# root written as <tmp>, so a row records the same across runs.
release_floor_key() {
  local text="$1" root="$2" alt
  [[ -n "${root}" ]] || { printf '%s' "${text}"; return; }
  text="${text//${root}/<tmp>}"
  # macOS hands out /var/... and resolves it to /private/var/...
  alt="${root#/private}"
  [[ "${alt}" == "${root}" ]] || text="${text//${alt}/<tmp>}"
  printf '%s' "${text}"
}

# release_floor_record <payload json> <safedeps home> <tmp root>: recording
# mode, runs the release's hook on <payload> in copies and appends the pair.
release_floor_record() {
  local payload="$1" home="$2" root="$3" scratch cwd out release
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/release-floor.XXXXXX")
  cwd=$(jq -r '.cwd' <<< "${payload}")
  mkdir -p "${scratch}/home" "${scratch}/project"
  [[ ! -d "${home}" ]] || cp -R "${home}/." "${scratch}/safedeps" 2>/dev/null || true
  rm -rf "${scratch}/safedeps/pending"
  [[ ! -d "${cwd}" ]] || cp -R "${cwd}/." "${scratch}/project" 2>/dev/null || true
  out=$(jq -c --arg cwd "${scratch}/project" '.cwd = $cwd' <<< "${payload}" \
    | HOME="${scratch}/home" SAFEDEPS_HOME="${scratch}/safedeps" "${SAFEDEPS_RELEASE_HOOK}" 2>/dev/null) || true
  release=$(jq -r '.hookSpecificOutput.updatedInput.command // empty' <<< "${out:-{\}}" 2>/dev/null) || release=""
  if [[ -n "${release}" ]]; then
    release=$(jq -n --arg r "$(release_floor_key "${release}" "${root}")" '$r')
  else
    release=null
  fi
  jq -nc --arg command "$(release_floor_key "$(jq -r '.tool_input.command' <<< "${payload}")" "${root}")" \
    --argjson release "${release}" '{command: $command, release: $release}' >> "${SAFEDEPS_RELEASE_RECORD}"
  rm -rf "${scratch}"
}

# release_floor_check <payload json> <this tree's rewrite, empty for none>
# <safedeps home> <tmp root>
release_floor_check() {
  local payload="$1" head="$2" home="$3" root="$4" command key release verdict
  if [[ -n "${SAFEDEPS_RELEASE_RECORD:-}" ]]; then
    release_floor_record "${payload}" "${home}" "${root}"
    return 0
  fi
  command=$(jq -r '.tool_input.command' <<< "${payload}")
  key=$(release_floor_key "${command}" "${root}")
  release=$(jq -c --arg k "${key}" 'map(select(.command == $k)) | if length == 0 then "missing" else .[0].release end' "${RELEASE_FLOOR_CORPUS}") \
    || { release_floor_fail "the release floor corpus is read (${RELEASE_FLOOR_CORPUS})"; return 1; }
  [[ "${release}" != '"missing"' ]] \
    || { release_floor_fail "the release's rewrite of this command is recorded (scripts/test/lib/release-floor.sh says how): $(printf '%q' "${key}")"; return 1; }
  [[ "${release}" != null ]] || return 0
  [[ -z "${head}" ]] || head=$(release_floor_key "${head}" "${root}")
  verdict=$(python3 - "${key}" "${head}" "$(jq -r '.' <<< "${release}")" <<'PY'
import sys
from functools import lru_cache
command, head, release = sys.argv[1:4]
FLAG = " --ignore-scripts"
sys.setrecursionlimit(100000)

def subseq(head, release, command):
    # Can head and release both be read as command with FLAG inserted at
    # places, where the release's inserts are some of the head's?
    @lru_cache(maxsize=None)
    def go(i, j, k):
        if i == len(head) and j == len(release) and k == len(command):
            return True
        if head.startswith(FLAG, i):
            if release.startswith(FLAG, j) and go(i + len(FLAG), j + len(FLAG), k):
                return True
            if go(i + len(FLAG), j, k):
                return True
        if (i < len(head) and j < len(release) and k < len(command)
                and head[i] == release[j] == command[k] and go(i + 1, j + 1, k + 1)):
            return True
        return False
    return go(0, 0, 0)

if not head:
    print("none")
elif subseq(head, release, command):
    print("ok")
else:
    print("not")
PY
) || { release_floor_fail "the release floor check ran: $(printf '%q' "${key}")"; return 1; }
  case "${verdict}" in
    ok) ;;
    none) release_floor_fail "an install the release rewrote is rewritten here too: $(printf '%q' "${key}") (release: ${release})" ;;
    *) release_floor_fail "deleting flags this tree inserted gives the release's rewrite: $(printf '%q' "${key}") (here: $(printf '%q' "${head}"); release: ${release})" ;;
  esac
}
