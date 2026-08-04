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

# --- the deadline must survive a child that is not listening ---------------
# The first version of this battery put every over-budget case on a 1s budget,
# so the deadline always landed early in the scan, where the child happens to be
# between external commands and takes a signal immediately. That corpus stayed
# green while a padded install answered at 38.9s against a 30s runtime budget —
# the exact fail-open this file exists to prevent. Two things were invisible: a
# TERM trap on the child (which replaces the default disposition, so the child
# survived the deadline and ran to completion), and the plain fact that a shell
# does not act on a signal while a foreground external command is running.
#
# Both show up only when the deadline lands deep in the scan, inside one of the
# long greps. This case is sized to do that: 12KB against an 11s budget answers
# at ~12s when the deadline is enforced on the whole child tree, and at ~17s
# when it is only sent to the child shell.
#
# The assertion is on the OVERSHOOT, not on elapsed time, because that is the
# property the runtime cares about — the guard's answer has to arrive before the
# runtime's own budget expires, and how much slack that leaves is exactly the
# budget minus the overshoot.
deep_budget=11
guard "pip install requests==2.31.0 # ${big}" "${deep_budget}"
[[ "${GUARD_DECISION}" == "deny" ]] \
  || fail "deadline deep in the scan still denies (got: ${GUARD_DECISION})"
grep -q 'UNDECIDED' <<< "${GUARD_REASON}" \
  || fail "deadline deep in the scan is reported as undecided, not as a finding"
deep_overshoot=$(( GUARD_ELAPSED - deep_budget ))
(( deep_overshoot <= 3 )) \
  || fail "deadline deep in the scan is honoured promptly (overshot the ${deep_budget}s budget by ${deep_overshoot}s; a child that outlasts the deadline is how this gate fails open)"
pass "deadline landing deep in the scan is honoured promptly, not whenever the child notices"

# The same property stated from the other side: the answer tracks OUR budget,
# not the judgment's natural length.
guard "echo ${big}" 2
budget_two=${GUARD_ELAPSED}
guard "echo ${big}" 6
budget_six=${GUARD_ELAPSED}
(( budget_six > budget_two )) \
  || fail "answer time tracks the configured budget (2s->${budget_two}s, 6s->${budget_six}s)"
(( budget_six <= 9 )) \
  || fail "a longer budget is still honoured rather than overrun (6s->${budget_six}s)"
pass "answer time tracks the configured budget, not the judgment's natural length"

# --- the budget is tunable only downward ------------------------------------
# A self budget at or above the runtime's hook budget is not a budget: the
# runtime kills the hook first and the tool call proceeds, which is the exact
# fail-open the machinery above exists to remove. The value is therefore clamped
# to a ceiling below the runtime budget. Both constants are read from the guard
# so this battery tracks them instead of restating them.
runtime_budget=$(grep -m1 '^SAFEDEPS_RUNTIME_BUDGET_SECONDS=' scripts/safedeps-pre-guard.sh | cut -d= -f2)
budget_ceiling=$(grep -m1 '^SAFEDEPS_SELF_BUDGET_MAX_SECONDS=' scripts/safedeps-pre-guard.sh | cut -d= -f2)
[[ -n "${runtime_budget}" && -n "${budget_ceiling}" ]] || fail "budget constants are readable from the guard"

# 64KB, because the clamp has to be the reason the answer arrives: this input's
# natural scan runs past 300s on the machine this was measured on (2026-08-04),
# so nothing but the ceiling can bring the answer back under the runtime budget.
# If the clamp ever regresses this case does not fail fast — it sits for minutes
# and then fails. That wait IS the defect: it is the window in which the runtime
# kills the hook and the install proceeds unjudged.
huge=$(pad 65536)
guard "pip install requests==2.31.0 # ${huge}" 600
[[ "${GUARD_DECISION}" == "deny" ]] \
  || fail "an over-ceiling budget still denies (got: ${GUARD_DECISION})"
grep -q 'UNDECIDED' <<< "${GUARD_REASON}" \
  || fail "an over-ceiling budget still answers as undecided rather than being killed"
(( GUARD_ELAPSED < runtime_budget )) \
  || fail "an over-ceiling budget answers inside the ${runtime_budget}s runtime budget (took ${GUARD_ELAPSED}s; past it the runtime kills the hook and the install proceeds)"
pass "a budget raised above the ceiling is clamped, so the answer still beats the runtime's kill"

# Clamping silently would be its own defect: the user would believe the value
# they set is the one running, and debug the next surprise against a number that
# was never true.
grep -q 'clamped' <<< "${GUARD_STDERR}" \
  || fail "the clamp is announced on stderr (got: $(printf '%s' "${GUARD_STDERR}" | head -c 80))"
grep -q '600' <<< "${GUARD_STDERR}" \
  || fail "the clamp names the value the user actually set"
grep -q 'clamped' "${GUARD_STATE_DIR}/advisory.log" \
  || fail "the clamp is recorded in advisory.log"
grep -q 'clamped' <<< "${GUARD_REASON}" \
  || fail "the undecided deny says the budget was clamped, so its figure is not read as the setting being ignored"
pass "the clamp is observable — stderr, advisory.log, and the deny reason all say it happened"

# Lowering stays free: a shorter budget only denies earlier, and it must not be
# reported as clamped.
guard "echo ${big}" "${tiny_budget}"
if grep -q 'clamped' <<< "${GUARD_STDERR}"; then fail "a budget under the ceiling is left alone"; fi
if grep -q 'clamped' "${GUARD_STATE_DIR}/advisory.log"; then fail "a budget under the ceiling is not logged as clamped"; fi
pass "a budget under the ceiling is honoured as given, silently"

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
