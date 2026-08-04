#!/usr/bin/env bash
# safedeps: self-budget battery.
#
# The runtime kills a command hook that overruns its budget, and the tool call
# then proceeds — so past a certain command size this gate used to disappear
# without saying anything. The guard now keeps a smaller budget of its own and
# answers DENY when its judgment does not finish, which is the one thing that
# has to stay true no matter how the scanner's cost curve moves later.
#
# Both directions are pinned here, because either one alone is a lie: the deny
# has to fire past the budget, AND everything inside the budget has to decide
# exactly as it did before. A budget that denies too eagerly is not a safer
# gate, it is a gate people switch off.
#
# The budget under test is deliberately tiny (seconds, not the 20s default) so
# this battery runs in seconds. What is being pinned is the mechanism, not the
# particular number: the default is a deployment choice, the behavior is not.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "${ROOT_DIR}"

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-budget.XXXXXX")
cleanup() { rm -rf "${tmp_root}"; }
trap cleanup EXIT

project_dir="${tmp_root}/project"
mkdir -p "${project_dir}" "${tmp_root}/home"
printf '{"dependencies":{}}\n' > "${project_dir}/package.json"

pad() { head -c "$1" < /dev/zero | tr '\0' 'x'; }

# Runs the guard and captures decision, whether the reason is the undecided
# one, and how long the answer took.
guard() {
  local command="$1" budget="${2:-2}" engage="${3:-1024}"
  local safe="${tmp_root}/safe-$$-${RANDOM}"
  mkdir -p "${safe}"
  GUARD_STATE_DIR="${safe}"
  local start end
  start=$(date +%s)
  GUARD_OUT=$(jq -nc --arg c "${command}" --arg cwd "${project_dir}" \
    '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}' |
    HOME="${tmp_root}/home" SAFEDEPS_HOME="${safe}" \
    SAFEDEPS_SELF_BUDGET_SECONDS="${budget}" \
    SAFEDEPS_BUDGET_ENGAGE_BYTES="${engage}" \
    scripts/safedeps-pre-guard.sh 2>"${tmp_root}/stderr") || true
  GUARD_STDERR=$(cat "${tmp_root}/stderr" 2>/dev/null || printf '')
  end=$(date +%s)
  GUARD_ELAPSED=$(( end - start ))
  if [[ -z "${GUARD_OUT}" ]]; then
    GUARD_DECISION="pass"
  else
    GUARD_DECISION=$(jq -r '.hookSpecificOutput.permissionDecision // "pass"' <<< "${GUARD_OUT}")
  fi
  GUARD_REASON=$(jq -r '.hookSpecificOutput.permissionDecisionReason // ""' <<< "${GUARD_OUT:-{\}}" 2>/dev/null || printf '')
}

# A command whose scan outruns the smallest budget by a wide margin while still
# returning fast enough for a test suite: 12KB measured at ~5.5s against a 1s
# budget that fires at ~1.6s. The margin is the point. Sizing this input close
# to the budget makes the battery a race, and the first draft of it was one —
# 8KB (~2.5s) against a 2s budget that fires at ~2.6s reported a false pass.
# Whatever machine runs this has to be several times faster than the one it was
# measured on before the margin closes.
big=$(pad 12288)
# Comfortably inside any budget.
small=$(pad 256)

# The deadline is checked between polls, and the last poll is 1s, so the
# effective fire time is the budget plus up to one second.
tiny_budget=1

# --- past the budget: the gate answers instead of being killed --------------

guard "echo ${big}" "${tiny_budget}"
[[ "${GUARD_DECISION}" == "deny" ]] || fail "over-budget command is denied (got: ${GUARD_DECISION})"
grep -q 'UNDECIDED' <<< "${GUARD_REASON}" || fail "over-budget deny is marked UNDECIDED"
pass "over-budget command is denied rather than silently allowed"

# The whole point is answering BEFORE the runtime's own budget expires. Allow
# generous slack for a loaded CI machine; what must not happen is the answer
# arriving at some multiple of the budget.
(( GUARD_ELAPSED <= 12 )) || fail "answer arrives close to the self-budget, not the runtime's (took ${GUARD_ELAPSED}s)"
pass "answer arrives on the guard's own budget, ahead of the runtime's"

# The deny must not read as a finding. "I could not finish" and "I found
# something" are different claims and a reader who confuses them learns to work
# around the gate.
grep -qi 'not unsafe' <<< "${GUARD_REASON}" || fail "undecided deny says it is not a finding"
grep -qi 'Nothing was detected' <<< "${GUARD_REASON}" || fail "undecided deny states nothing was detected"
pass "undecided deny reads as undecided, not as a detection"

# The shell announces a signalled background job by itself, and that lands on
# the hook's stderr where the engine shows it. Beside a security deny, a line
# reading "Terminated: 15" says something went wrong when nothing did.
if [[ -n "${GUARD_STDERR}" ]]; then
  fail "undecided deny leaves stderr clean (got: $(printf '%s' "${GUARD_STDERR}" | head -c 80))"
fi
pass "undecided deny leaves the hook's stderr clean"

# Every bypass or unavailability is observable (AGENTS.md invariant).
grep -q 'unfinished' "${GUARD_STATE_DIR}/advisory.log" || fail "undecided deny is recorded in advisory.log"
pass "undecided deny is recorded in advisory.log"

# The install carriers the command gate is the AUTHORITY for — padding one of
# these past the budget was the actual bypass.
for install_cmd in \
  "pip install requests==2.31.0 # ${big}" \
  "cargo add serde@1.0.0 # ${big}" \
  "go get example.com/x@v1.0.0 # ${big}" \
  "gem install rails -v 7.0.0 # ${big}"; do
  guard "${install_cmd}" "${tiny_budget}"
  [[ "${GUARD_DECISION}" == "deny" ]] \
    || fail "padded install past the budget is denied: ${install_cmd:0:24}… (got: ${GUARD_DECISION})"
done
pass "padded installs past the budget are denied across command-gate-authority ecosystems"

# --- without the budget the same input walks through -----------------------
# Mutation check in the honest direction: disable the machinery (engage size
# above the input) and the over-budget command is judged clean and allowed.
# That is the shape the runtime kill turned into a silent pass.
guard "echo ${big}" "${tiny_budget}" 99999999
[[ "${GUARD_DECISION}" == "pass" ]] \
  || fail "with the budget disengaged the same command is allowed (got: ${GUARD_DECISION})"
pass "battery is meaningful: with the budget disengaged the same command walks through"

# --- inside the budget nothing changes --------------------------------------

guard "ls -la" 2
[[ "${GUARD_DECISION}" == "pass" ]] || fail "benign command still passes (got: ${GUARD_DECISION})"
pass "benign command still passes"

guard "npm run build" 2
[[ "${GUARD_DECISION}" == "pass" ]] || fail "npm run still passes (got: ${GUARD_DECISION})"
pass "npm run still passes"

guard "pip install requests==2.31.0" 2
[[ "${GUARD_DECISION}" == "deny" ]] || fail "unapproved install still denies (got: ${GUARD_DECISION})"
# `if !`, not `grep && fail`: under `set -e` a grep that finds nothing makes the
# whole && list fail, so the good case would kill the battery.
if grep -q 'UNDECIDED' <<< "${GUARD_REASON}"; then fail "unapproved-install deny is a finding, not an undecided"; fi
pass "unapproved install still denies, and as a finding rather than an undecided"

guard "npm install left-pad@1.3.0" 2
[[ "${GUARD_DECISION}" == "deny" ]] || fail "unapproved npm install still denies (got: ${GUARD_DECISION})"
pass "unapproved npm install still denies"

# Engaged but comfortably inside the budget: the machinery must be transparent,
# including the Claude-only inert-install rewrite that travels in the same
# payload. This is the case a naive budget breaks.
guard "echo ${small}" 2 128
[[ "${GUARD_DECISION}" == "pass" ]] || fail "engaged in-budget benign command still passes (got: ${GUARD_DECISION})"
pass "engaged but in-budget benign command still passes"

guard "npm install left-pad@1.3.0" 20 16
[[ "${GUARD_DECISION}" == "deny" ]] || fail "engaged in-budget install still decides normally (got: ${GUARD_DECISION})"
if grep -q 'UNDECIDED' <<< "${GUARD_REASON}"; then fail "engaged in-budget install is judged, not timed out"; fi
pass "engaged but in-budget install is judged normally, not timed out"

printf 'self-budget battery: all checks passed\n'
