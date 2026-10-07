#!/usr/bin/env bash
# safedeps: random forms against real shells, read by every reading of the lexer.
#
# The forms come from scripts/measure/shell-reading-fuzz.mjs (seeded). Each runs
# under the shells this platform has, with `echo REACHED` as its tail, the way
# scripts/measure/shell-reading-measure.sh runs the recorded corpus: nothing in
# a form installs anything. The same text with an install as its tail is then
# lexed under each reading -- bash, zsh, dash -- and a reading "shows" the tail
# when its live view (every byte the shell runs at the top level), its scripts
# handed to `sh -c` or `eval`, or the heredoc bodies piped to a shell hold it.
#
# Two counts come out, per platform:
#
#   missed     a shell ran the tail and no reading shows it. The gate judges
#              the union of the readings, so this is the lexer-level hole, and
#              it must be 0.
#   unfaithful a shell ran the tail and its own reading does not show it,
#              though another does. Not a hole (the union covers it); a
#              reading that is not yet its shell.
#
# With --gate each form a shell ran also goes through the guard, and the
# decisions are counted: a form the gate passes is a miss, UNDECIDED is not a
# finding.
#
# Usage: scripts/measure/shell-reading-fuzz.sh [--seed N] [--count N] [--gate]
#        (defaults: seed 20261001, count 400)
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "${ROOT_DIR}" || exit 2
SEED=20261001
COUNT=400
GATE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --seed) SEED="$2"; shift 2 ;;
    --count) COUNT="$2"; shift 2 ;;
    --gate) GATE=true; shift ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

source "${ROOT_DIR}/scripts/test/lib/native-measure-core.sh"
GUARD="${ROOT_DIR}/scripts/safedeps-hook-entry.sh"
lex_view_text() { # reading text view; the core query owns payload boundaries
  if [[ "$3" == cscripts || "$3" == substs ]]; then
    printf '%s' "$2" | SAFEDEPS_READING="$1" "${MEASURE_CORE}" payloads |
      jq -r --arg view "$3" '.payloads[] | select(if $view == "cscripts" then (.kind == "B" or .kind == "S") else .kind == "E" end) | .text'
  else
    printf '%s' "$2" | SAFEDEPS_READING="$1" "${MEASURE_CORE}" lex "$3"
  fi
}

work=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-fuzz.XXXXXX")
trap 'rm -rf "${work}"' EXIT
forms="${work}/forms.json"
node scripts/measure/shell-reading-fuzz.mjs "${SEED}" "${COUNT}" > "${forms}" || exit 2

# shell column -> the reading that stands for it
if [[ "$(uname -s)" == Linux ]]; then
  shells=("bash:bash:$(command -v bash)" "dash:dash:$(command -v dash)")
else
  shells=("bash:bash:/bin/bash" "zsh:zsh:/bin/zsh" "dash:dash:/bin/dash")
fi

runs() { # shell-binary file -> R or -
  local d out
  d=$(mktemp -d "${work}/cwd.XXXXXX")
  # zsh with no startup files (-f): a ~/.zshenv runs in every `zsh -c` and can
  # change what a form runs.
  if [[ "$1" == */zsh ]]; then
    out=$(cd "${d}" && "$1" -f -c "$(cat "$2")" 2>/dev/null </dev/null)
  else
    out=$(cd "${d}" && "$1" -c "$(cat "$2")" 2>/dev/null </dev/null)
  fi
  printf '%s\n' "${out}" | grep -qx REACHED && printf 'R' || printf '%s' '-'
}
shows() { # reading text -> 0 when that reading shows the tail
  local reading="$1" text="$2" v
  for v in live cscripts shell-bodies; do
    lex_view_text "${reading}" "${text}" "${v}" | tr -d ' \t\n' \
      | grep -q 'pipinstallevil==6\.6\.6' && return 0
  done
  return 1
}
decision_of() { # text -> deny | undecided | allow | pass
  local safe out decision
  safe=$(mktemp -d "${work}/safe.XXXXXX")
  mkdir -p "${safe}/project"
  printf '{"dependencies":{}}\n' > "${safe}/project/package.json"
  out=$(jq -nc --arg c "$1" --arg cwd "${safe}/project" '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}' |
    HOME="${safe}/home" SAFEDEPS_HOME="${safe}/state" "${GUARD}" pre 2>/dev/null)
  [[ -n "${out}" ]] || { printf 'pass'; return; }
  decision=$(jq -r '.hookSpecificOutput.permissionDecision // "pass"' <<< "${out}")
  if [[ "${decision}" == deny ]] && jq -r '.hookSpecificOutput.permissionDecisionReason // ""' <<< "${out}" | grep -q UNDECIDED; then
    decision=undecided
  fi
  printf '%s' "${decision}"
}

n=$(jq length "${forms}")
ran=0 missed=0 unfaithful=0
declare -a missed_ids=() unfaithful_ids=() gate_counts=()
printf 'id'; for s in "${shells[@]}"; do printf '\t%s' "${s%%:*}"; done
printf '\tshown-in'; [[ "${GATE}" == true ]] && printf '\tgate'; printf '\n'
for ((i = 0; i < n; i++)); do
  id=$(jq -r ".[${i}].id" "${forms}")
  jq -j ".[${i}].text" "${forms}" | sed 's/@@TAIL@@/echo REACHED/' > "${work}/f.sh"
  text=$(jq -j ".[${i}].text" "${forms}"; printf 'X'); text="${text%X}"
  text="${text//@@TAIL@@/pip install evil==6.6.6}"
  any=false
  row="${id}"
  shown=""
  for reading in bash zsh dash; do
    shows "${reading}" "${text}" && shown+="${reading},"
  done
  for s in "${shells[@]}"; do
    col="${s%%:*}"; rest="${s#*:}"; reading="${rest%%:*}"; bin="${rest#*:}"
    r=$(runs "${bin}" "${work}/f.sh")
    row+=$'\t'"${r}"
    if [[ "${r}" == R ]]; then
      any=true
      [[ ",${shown}" == *",${reading},"* ]] || { unfaithful=$((unfaithful + 1)); unfaithful_ids+=("${id}:${col}"); }
    fi
  done
  row+=$'\t'"${shown:-none}"
  if [[ "${any}" == true ]]; then
    ran=$((ran + 1))
    if [[ -z "${shown}" ]]; then missed=$((missed + 1)); missed_ids+=("${id}"); fi
    if [[ "${GATE}" == true ]]; then
      g=$(decision_of "${text}")
      row+=$'\t'"${g}"
      gate_counts+=("${g}")
    fi
  fi
  printf '%s\n' "${row}"
done
printf '# seed %s, %s forms, platform %s, load %s\n' "${SEED}" "${n}" "$(uname -s)" "$(uptime | sed 's/.*load averages*: //')"
printf '# a shell ran the tail: %d; missed by every reading: %d%s\n' "${ran}" "${missed}" "${missed_ids[*]+ (${missed_ids[*]})}"
printf '# not shown by the reading of the shell that ran it: %d%s\n' "${unfaithful}" "${unfaithful_ids[*]+ (${unfaithful_ids[*]})}"
if [[ "${GATE}" == true ]]; then
  printf '# gate on forms a shell ran:'
  printf '%s\n' "${gate_counts[@]+"${gate_counts[@]}"}" | sort | uniq -c | tr '\n' ' '
  printf '\n'
fi
[[ ${missed} -eq 0 ]]
