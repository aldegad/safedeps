#!/usr/bin/env bash
# safedeps: the gate reads a command the way the shell does.
#
# Every form in scripts/measure/shell-reading-forms.json carries the values a
# real shell produced for it (scripts/measure/shell-reading-measure.sh
# re-measures them): whether bash, zsh, or the agent's own zsh wrapper ran the
# form's last line. Here that line is an unapproved pinned install, and the
# form is handed to the guard as a payload -- never run. If any shell runs the
# line, the guard must not let the command through unjudged.
#
# This is the class the one-pass lexer closed. A line-based heredoc regex, a
# line joiner and a quote scanner ran one after another and disagreed; each
# disagreement hid the lines after it from the gate (a comment apostrophe, a
# herestring, a heredoc with a digit delimiter, a multi-line string closing on
# the line that opens a heredoc, a substitution in an unquoted heredoc body).
# A form marked `gate: pass` is data the shell never runs, and must stay data.
set -euo pipefail

# `--count` tallies the decisions instead of stopping at the first miss, and
# exits 0. It is how a tree without the lexer is measured against the same
# forms: copy this file and the forms into a checkout of that tree, then run
# `bash scripts/test/shell-reading.sh --count` there.
COUNT=false
[[ "${1:-}" == "--count" ]] && COUNT=true

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "${ROOT_DIR}"
FORMS="scripts/measure/shell-reading-forms.json"

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-shell-reading.XXXXXX")
trap 'rm -rf "${tmp_root}"' EXIT
mkdir -p "${tmp_root}/project"
printf '{"dependencies":{}}\n' > "${tmp_root}/project/package.json"

# deny (a finding), undecided (an UNDECIDED deny), allow or pass. The two
# denies are kept apart on purpose: a lexer that misreads a heredoc runs it to
# the end of the input, the unterminated backstop then answers UNDECIDED, and a
# battery that accepted any deny passed five of ten lexer mutants (measured).
# The tail must be read, not merely refused.
decision_of() { # text file -> deny | undecided | allow | pass
  local safe out decision
  safe=$(mktemp -d "${tmp_root}/safe.XXXXXX")
  out=$(jq -nc --rawfile c "$1" --arg cwd "${tmp_root}/project" '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}' |
    HOME="${safe}/home" SAFEDEPS_HOME="${safe}/state" scripts/safedeps-pre-guard.sh 2>/dev/null)
  if [[ -z "${out}" ]]; then printf 'pass'; return; fi
  decision=$(jq -r '.hookSpecificOutput.permissionDecision // "pass"' <<< "${out}")
  if [[ "${decision}" == "deny" ]] && jq -r '.hookSpecificOutput.permissionDecisionReason // ""' <<< "${out}" | grep -q 'UNDECIDED'; then
    decision=undecided
  fi
  printf '%s' "${decision}"
}

# Control: the harness tells a judged install from data.
printf 'pip install evil==6.6.6' > "${tmp_root}/k.cmd"
[[ "$(decision_of "${tmp_root}/k.cmd")" == "deny" ]] || fail "control: the bare install is denied"
printf "echo 'pip install evil==6.6.6'" > "${tmp_root}/k.cmd"
[[ "$(decision_of "${tmp_root}/k.cmd")" == "pass" ]] || fail "control: the quoted install is data"
pass "control: the harness separates a judged install from data"

n=$(jq length "${FORMS}")
ran=0 judged=0 data=0
declare -a missed=()
for ((i = 0; i < n; i++)); do
  id=$(jq -r ".[${i}].id" "${FORMS}")
  label=$(jq -r ".[${i}].label" "${FORMS}")
  jq -j ".[${i}].text" "${FORMS}" \
    | sed -e 's/@@TAIL@@/pip install evil==6.6.6/' -e 's/@@TAIL_SPLIT@@/pi\\\
p install evil==6.6.6/' > "${tmp_root}/${id}.cmd"
  shells=$(jq -r ".[${i}].measured | \"\(.bash) \(.zsh) \(.agent)\"" "${FORMS}")
  want=$(jq -r ".[${i}].gate // empty" "${FORMS}")
  got=$(decision_of "${tmp_root}/${id}.cmd")
  if [[ "${shells}" == *R* ]]; then
    ran=$((ran + 1))
    if [[ "${got}" == "deny" ]]; then
      judged=$((judged + 1))
    elif [[ "${COUNT}" == "true" ]]; then
      missed+=("${id}:${got}")
    else
      fail "${id} (${label}): a shell runs the last line [${shells}], and the gate answered ${got} rather than reading it"
    fi
  fi
  if [[ -n "${want}" ]]; then
    if [[ "${got}" == "${want}" ]]; then
      data=$((data + 1))
    elif [[ "${COUNT}" == "true" ]]; then
      missed+=("${id}:${got}(want ${want})")
    else
      fail "${id} (${label}): expected ${want}, got ${got}"
    fi
  fi
done
if [[ "${COUNT}" == "true" ]]; then
  printf 'shell-reading count: %d of %d shell-run forms judged; data forms kept %d\n' "${judged}" "${ran}" "${data}"
  printf 'not judged:'
  printf ' %s' "${missed[@]+"${missed[@]}"}"
  printf '\n'
  exit 0
fi
pass "every form a shell runs to its last line is judged (${judged}/${ran} of ${n} forms)"
pass "forms the shell reads as data stay data (${data})"
printf 'shell-reading passed\n'
