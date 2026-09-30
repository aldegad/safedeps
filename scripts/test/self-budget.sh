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

# --- a judgment that does not finish, on demand ------------------------------
# Every over-budget case below needs a judgment that outlasts its budget. This
# battery used to get one from input size: 12KB of padding took ~5.5s to scan
# on the machine it was written on. That was never a property of the gate. It
# was a property of the scanner's cost curve and of the machine, and both moved:
# the linear scanner answers 12KB in 0.2s, and the ubuntu CI runner was already
# finishing the 11s "deep" case inside its budget before that.
#
# So the delay comes from the one input a test controls and the guard does not
# read: PATH. `slow_guard` puts an awk in front of the real one that sleeps once
# before it runs. awk is on the judgment's path (command_scan_text) and not on
# the parent's — the parent reads the payload with jq, keeps the deadline with
# kill and sleep, and answers with jq — so the delay lands inside the child the
# deadline watches and nowhere else. The guard gains no knob for this. A delay
# the environment could set would be one more thing an attacker could set.
#
# The sleep is a foreground external command of the child, which is the
# condition the deadline has to survive: a shell does not act on a signal while
# one runs. The shim sleeps once per guard run, not once per awk call, so a case
# costs the same however many times the judgment reaches for awk. It sleeps from
# `/`, so a sleeper that outlives a regressed kill cannot pin the worktree.
real_awk=$(command -v awk)
slow_bin="${tmp_root}/slow-bin"
slow_delay_file="${tmp_root}/slow-delay"
slow_once_dir="${tmp_root}/slow-once"
slow_pid_file="${tmp_root}/slow-pid"
mkdir -p "${slow_bin}"
cat > "${slow_bin}/awk" <<SHIM
#!/usr/bin/env bash
if mkdir '${slow_once_dir}' 2>/dev/null; then
  printf '%s' "\$\$" > '${slow_pid_file}'
  cd / && sleep "\$(cat '${slow_delay_file}')"
  cd "\${OLDPWD}" || exit 1
fi
exec '${real_awk}' "\$@"
SHIM
chmod +x "${slow_bin}/awk"

# Long enough that nothing but the deadline can answer inside the runtime's 30s.
never=60

# Runs the guard and captures decision, whether the reason is the undecided
# one, and how long the answer took.
GUARD_PATH=""
GUARD_IGNORE_TERM=""
guard() {
  local command="$1" budget="${2:-2}" engage="${3:-1024}" disabled="${4:-}" legacy_child="${5:-}"
  # mktemp for the same reason as consumer-forms.sh: `$$` is constant within a
  # run so isolation rested on RANDOM alone, and `mkdir -p` cannot report a
  # collision. Uniqueness is the kernel's job.
  local safe
  safe=$(mktemp -d "${tmp_root}/safe.XXXXXX")
  GUARD_STATE_DIR="${safe}"
  local start end rc=0
  local launch=(scripts/safedeps-pre-guard.sh)
  if [[ -n "${GUARD_IGNORE_TERM}" ]]; then
    # A signal ignored on entry stays ignored across exec, and bash cannot trap
    # or reset it, so every process in the judgment inherits a deaf TERM.
    launch=(bash -c 'trap "" TERM; exec "$@"' ignore-term scripts/safedeps-pre-guard.sh)
  fi
  start=$(date +%s)
  GUARD_OUT=$(jq -nc --arg c "${command}" --arg cwd "${project_dir}" \
    '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}' |
    PATH="${GUARD_PATH:-${PATH}}" \
    HOME="${tmp_root}/home" SAFEDEPS_HOME="${safe}" \
    SAFEDEPS_SELF_BUDGET_SECONDS="${budget}" \
    SAFEDEPS_BUDGET_ENGAGE_BYTES="${engage}" \
    SAFEDEPS_BUDGET_DISABLED="${disabled}" \
    SAFEDEPS_BUDGET_CHILD="${legacy_child}" \
    "${launch[@]}" 2>"${tmp_root}/stderr") || rc=$?
  GUARD_STDERR=$(cat "${tmp_root}/stderr" 2>/dev/null || printf '')
  end=$(date +%s)
  GUARD_ELAPSED=$(( end - start ))
  # The hook exits 0 on every designed path, so anything else means it never
  # answered. Reading that as an empty answer reads it as `pass`, and that is
  # how a Linux launch failure (E2BIG) passed for a verdict in CI.
  (( rc == 0 )) \
    || fail "the guard ran and answered (it exited ${rc}: $(printf '%s' "${GUARD_STDERR}" | head -c 120))"
  if [[ -z "${GUARD_OUT}" ]]; then
    GUARD_DECISION="pass"
  else
    GUARD_DECISION=$(jq -r '.hookSpecificOutput.permissionDecision // "pass"' <<< "${GUARD_OUT}")
  fi
  GUARD_REASON=$(jq -r '.hookSpecificOutput.permissionDecisionReason // ""' <<< "${GUARD_OUT:-{\}}" 2>/dev/null || printf '')
}

# `guard`, with the judgment held up for <seconds> first.
slow_guard() {
  local delay="$1"
  shift
  printf '%s' "${delay}" > "${slow_delay_file}"
  rm -f "${slow_pid_file}"
  rmdir "${slow_once_dir}" 2>/dev/null || true
  GUARD_PATH="${slow_bin}:${PATH}"
  guard "$@"
  GUARD_PATH=""
}

# True once the process the shim ran as is gone. A killed process can sit as a
# zombie for a moment before it is reaped, so this waits up to two seconds.
slow_sleeper_gone() {
  local pid tries=0
  pid=$(cat "${slow_pid_file}" 2>/dev/null) || return 0
  while kill -0 "${pid}" 2>/dev/null; do
    (( tries++ < 40 )) || return 1
    sleep 0.05
  done
}

# The size only has to engage the deadline, including under the 4KB engage
# ceiling; the delay above is what makes it outlast the budget.
big=$(pad 12288)
# Comfortably inside any budget.
small=$(pad 256)

# The deadline is checked between polls, and the last poll is 1s, so the
# effective fire time is the budget plus up to one second.
tiny_budget=1

# --- past the budget: the gate answers instead of being killed --------------

slow_guard "${never}" "echo ${big}" "${tiny_budget}"
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
  slow_guard "${never}" "${install_cmd}" "${tiny_budget}"
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
# Both show up only when the deadline lands on a child that does not act on
# TERM. This case used to reach that state by sizing the input so the deadline
# landed deep in a long grep (12KB against an 11s budget), which made it a race
# against the machine. It is now certain rather than likely: the guard starts
# with TERM ignored, which every process in the judgment inherits and none can
# undo, and the slow judgment holds the child in a foreground command for a
# full minute. Only the KILL escalation answers on time. Without it the answer
# arrives when that minute is up, about 57s late.
#
# Measured while rewriting this: a plain TERM kills an untrapped bash at once,
# so a battery whose child still hears TERM passes with the KILL removed. It
# only looked like it pinned the escalation.
#
# The assertion is on the OVERSHOOT, not on elapsed time, because that is the
# property the runtime cares about — the guard's answer has to arrive before the
# runtime's own budget expires, and how much slack that leaves is exactly the
# budget minus the overshoot.
deep_budget=3
GUARD_IGNORE_TERM=1
slow_guard "${never}" "pip install requests==2.31.0 # ${big}" "${deep_budget}"
GUARD_IGNORE_TERM=""
[[ "${GUARD_DECISION}" == "deny" ]] \
  || fail "deadline landing while the child is blocked still denies (got: ${GUARD_DECISION})"
grep -q 'UNDECIDED' <<< "${GUARD_REASON}" \
  || fail "deadline landing while the child is blocked is reported as undecided, not as a finding"
deep_overshoot=$(( GUARD_ELAPSED - deep_budget ))
(( deep_overshoot <= 3 )) \
  || fail "deadline landing while the child is blocked is honoured promptly (overshot the ${deep_budget}s budget by ${deep_overshoot}s; a child that outlasts the deadline is how this gate fails open)"
pass "deadline landing while the child is blocked is honoured promptly, not whenever the child notices"

# Answering on time is the guarantee; leaving nothing behind is the other half.
# Killing only the child shell answers just as fast, and orphans the command it
# was blocked in to finish on its own, burning a core for as long as it runs.
slow_sleeper_gone \
  || fail "the deadline takes the whole judgment down, not just the shell (the blocked command outlived the answer)"
pass "the deadline takes the blocked command down with the shell, leaving no orphan"

# The same property stated from the other side: the answer tracks OUR budget,
# not the judgment's natural length.
slow_guard "${never}" "echo ${big}" 2
budget_two=${GUARD_ELAPSED}
slow_guard "${never}" "echo ${big}" 6
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

# The judgment is held up for a minute, so nothing but the ceiling can bring the
# answer back under the runtime budget. If the clamp ever regresses this case
# does not fail fast — it sits for that minute and then fails. That wait IS the
# defect: it is the window in which the runtime kills the hook and the install
# proceeds unjudged.
slow_guard "${never}" "pip install requests==2.31.0 # ${big}" 600
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

# --- the clamp must read the value the same way the deadline does ------------
# The first version of this clamp validated with `^[0-9]+$` and then let the
# deadline consume the RAW string in `$(( ))`. Bash arithmetic accepts a wider
# grammar than that regex, so `+40`, ` 40` and `0x28` failed validation, skipped
# the clamp, and then evaluated to 40 as the budget — above the runtime's, which
# is the fail-open this whole file exists to prevent. Measured before the fix: a
# 64KB command under `+40` produced no answer for 41s. Two grammars for one
# value is the defect, so these cases pin that there is only one.
#
# One expensive case proves the property end to end; the cheap ones below prove
# the parse, which is where the defect actually lived.
slow_guard "${never}" "pip install requests==2.31.0 # ${big}" " 40"
[[ "${GUARD_DECISION}" == "deny" ]] \
  || fail "a whitespace-padded over-ceiling budget still denies (got: ${GUARD_DECISION})"
(( GUARD_ELAPSED < runtime_budget )) \
  || fail "a whitespace-padded over-ceiling budget is clamped like a bare one (took ${GUARD_ELAPSED}s against the ${runtime_budget}s runtime budget)"
pass "a budget the regex used to miss but arithmetic accepted is clamped too"

# Cheap parse checks. A small command inside the engage size answers in
# milliseconds, so what these read is the announcement and the budget figure the
# guard reports — which is exactly what the raw value used to corrupt.
guard "echo ${small}" "+40" 128
grep -q 'clamped' <<< "${GUARD_STDERR}" || fail "a leading + is parsed, then clamped (got: $(printf '%s' "${GUARD_STDERR}" | head -c 80))"
grep -q '40' <<< "${GUARD_STDERR}" || fail "the clamp names the value the user set, normalized"
pass "a leading + is normalized rather than skipping the clamp"

# Not a number at all: there is no budget to honour, so the default is in force
# — inside the ceiling, and said out loud, because a value nobody asked for must
# not arrive silently.
for bad_budget in "0x28" "abc" "-5" "4.5"; do
  guard "echo ${small}" "${bad_budget}" 128
  [[ "${GUARD_DECISION}" == "pass" ]] \
    || fail "a non-numeric budget (${bad_budget}) falls back to the default rather than breaking the gate (got: ${GUARD_DECISION})"
  grep -q 'not a whole number' <<< "${GUARD_STDERR}" \
    || fail "a non-numeric budget (${bad_budget}) is announced (got: $(printf '%s' "${GUARD_STDERR}" | head -c 80))"
done
pass "a non-numeric budget falls back to the default and says so, instead of reaching arithmetic"

# --- digits, but more than arithmetic can hold -------------------------------
# The clamp compares numbers, and bash integers are 64-bit and wrap silently. A
# value that wraps NEGATIVE is not `> ceiling`, so it walks straight past the
# clamp, and `budget * 1000` then wraps again into a deadline that never
# arrives: measured before this check, a 30-digit budget produced no answer for
# over 600s. Which direction a value wraps depends on the value, so "long
# numbers are safe because they wrap" is not a property — the length is decided
# in the string domain, before any arithmetic can wrap, which is.
overflow_budget=123456789012345678901234567890
slow_guard "${never}" "pip install requests==2.31.0 # ${big}" "${overflow_budget}"
[[ "${GUARD_DECISION}" == "deny" ]] \
  || fail "a budget too long for arithmetic still denies (got: ${GUARD_DECISION})"
(( GUARD_ELAPSED < runtime_budget )) \
  || fail "a budget too long for arithmetic is clamped rather than wrapping past the clamp (took ${GUARD_ELAPSED}s against the ${runtime_budget}s runtime budget)"
grep -q 'clamped' <<< "${GUARD_STDERR}" || fail "an over-long budget is announced as clamped"
pass "a budget with more digits than arithmetic can hold is clamped, not wrapped"

# The other side of the wrap: this one lands on the negative bound exactly, and
# used to reach the user as a `-9223372036854775808s budget` in the deny reason
# — a number that was never true, from the same class of defect.
guard "echo ${small}" "9223372036854775808" 128
[[ "${GUARD_DECISION}" == "pass" ]] \
  || fail "a budget at the 64-bit bound is clamped rather than deciding by accident (got: ${GUARD_DECISION})"
grep -q 'clamped' <<< "${GUARD_STDERR}" || fail "a budget at the 64-bit bound is announced as clamped"
pass "a budget at the 64-bit bound is clamped, and says so"

# Leading zeros are not magnitude, so the digit count must not read them as
# length. This one is five seconds, honoured as given and unannounced.
guard "echo ${small}" "0000000005" 128
[[ "${GUARD_DECISION}" == "pass" ]] || fail "a zero-padded short budget is honoured (got: ${GUARD_DECISION})"
if [[ -n "${GUARD_STDERR}" ]]; then fail "a zero-padded short budget is neither clamped nor rejected (got: $(printf '%s' "${GUARD_STDERR}" | head -c 80))"; fi
pass "leading zeros are stripped before the value is judged by its length"

# The same value written the long way is still the same number: `08` must not be
# read as octal, which is an arithmetic error rather than eight.
guard "echo ${small}" "08" 128
[[ "${GUARD_DECISION}" == "pass" ]] || fail "a zero-padded budget is base 10 (got: ${GUARD_DECISION})"
if grep -q 'not a whole number' <<< "${GUARD_STDERR}"; then fail "a zero-padded budget is a number, not a rejection"; fi
pass "a zero-padded budget is read in base 10"

# Lowering stays free: a shorter budget only denies earlier, and it must not be
# reported as clamped. The deadline has to actually fire here, or there is no
# deny reason and no record for a stray clamp note to appear in.
slow_guard "${never}" "echo ${big}" "${tiny_budget}"
grep -q 'UNDECIDED' <<< "${GUARD_REASON}" || fail "a budget under the ceiling still fires (got: ${GUARD_DECISION})"
if grep -q 'clamped' <<< "${GUARD_STDERR}"; then fail "a budget under the ceiling is left alone"; fi
if grep -q 'clamped' <<< "${GUARD_REASON}"; then fail "a budget under the ceiling is not described as clamped"; fi
if grep -q 'clamped' "${GUARD_STATE_DIR}/advisory.log"; then fail "a budget under the ceiling is not logged as clamped"; fi
pass "a budget under the ceiling is honoured as given, silently"

# --- the engage size tunes the machinery, it does not switch it off ----------
# The engage size is the only condition on the whole deadline, so raising it far
# enough removes the deadline for everything below it — the same fail-open as an
# over-large budget, through the knob someone reaches for next. It is clamped,
# and clamped loudly, for the same reasons.
slow_guard "${never}" "pip install requests==2.31.0 # ${big}" "${tiny_budget}" 99999999
[[ "${GUARD_DECISION}" == "deny" ]] \
  || fail "an engage size past the ceiling still engages the deadline (got: ${GUARD_DECISION})"
grep -q 'UNDECIDED' <<< "${GUARD_REASON}" \
  || fail "an engage size past the ceiling still answers on the budget"
grep -q 'ENGAGE_BYTES' <<< "${GUARD_STDERR}" \
  || fail "the engage clamp is announced (got: $(printf '%s' "${GUARD_STDERR}" | head -c 80))"
grep -q 'ENGAGE_BYTES' "${GUARD_STATE_DIR}/advisory.log" \
  || fail "the engage clamp is recorded in advisory.log"
pass "an engage size raised past the ceiling is clamped, so the deadline still engages"

# Tuning inside the ceiling is what the knob is for, and it stays silent.
guard "echo ${small}" 2 2048
[[ "${GUARD_DECISION}" == "pass" ]] || fail "an engage size inside the ceiling is honoured (got: ${GUARD_DECISION})"
if [[ -n "${GUARD_STDERR}" ]]; then fail "an engage size inside the ceiling is silent (got: $(printf '%s' "${GUARD_STDERR}" | head -c 80))"; fi
pass "an engage size inside the ceiling is honoured as given, silently"

# Same reader, same rules: a non-numeric engage size is not a size.
guard "pip install requests==2.31.0 # ${big}" "${tiny_budget}" "0x10000"
[[ "${GUARD_DECISION}" == "deny" ]] || fail "a non-numeric engage size falls back to the default (got: ${GUARD_DECISION})"
grep -q 'not a whole number of bytes' <<< "${GUARD_STDERR}" \
  || fail "a non-numeric engage size is announced (got: $(printf '%s' "${GUARD_STDERR}" | head -c 80))"
pass "a non-numeric engage size falls back to the default and says so"

# --- turning the deadline off is a separate, named act -----------------------
# Mutation check in the honest direction: with the deadline off, the over-budget
# command is judged clean and allowed. That is the shape the runtime kill turned
# into a silent pass, and a battery that cannot produce it only knows that it
# passes, not that it catches anything.
#
# It runs through SAFEDEPS_BUDGET_DISABLED rather than through the engage size,
# because the tuning knob and the off switch being one variable is what let a
# friction adjustment disable a security boundary without saying so.
#
# The delay is short here because this case has to wait it out, and it is still
# longer than the budget: the elapsed check is what proves the deny above came
# from the deadline and not from something the delay did to the judgment.
mutation_delay=4
slow_guard "${mutation_delay}" "echo ${big}" "${tiny_budget}" 1024 1
[[ "${GUARD_DECISION}" == "pass" ]] \
  || fail "with the deadline disabled the same command is allowed (got: ${GUARD_DECISION})"
(( GUARD_ELAPSED >= mutation_delay )) \
  || fail "with the deadline disabled the judgment runs past the budget instead of being cut (took ${GUARD_ELAPSED}s)"
pass "battery is meaningful: with the deadline disabled the same command walks through"

# A disabled deadline is a bypass, and every bypass in this tool is observable.
grep -q 'DISABLED' <<< "${GUARD_STDERR}" \
  || fail "the disabled deadline is announced on stderr (got: $(printf '%s' "${GUARD_STDERR}" | head -c 80))"
grep -q 'deadline is OFF' "${GUARD_STATE_DIR}/advisory.log" \
  || fail "the disabled deadline is recorded in advisory.log"
pass "a disabled deadline announces itself every time it is used"

# --- the parent/child marker cannot be set from outside ----------------------
# The marker that tells this script it is the spawned child used to be an
# environment variable, so exporting it made the parent believe it was already
# the child and skip the deadline entirely — an unnamed off switch beside the
# named one, measured at 32s on an input that answers in 3s. It travels in argv
# now, and the engines invoke the hook through a shim that passes no arguments,
# so there is no route from the environment into it.
slow_guard "${never}" "pip install requests==2.31.0 # ${big}" "${tiny_budget}" 1024 "" 1
[[ "${GUARD_DECISION}" == "deny" ]] \
  || fail "the deadline runs even with the old marker exported (got: ${GUARD_DECISION})"
grep -q 'UNDECIDED' <<< "${GUARD_REASON}" \
  || fail "the old marker cannot turn the deadline into a silent pass"
(( GUARD_ELAPSED <= 12 )) \
  || fail "the old marker does not lift the deadline (took ${GUARD_ELAPSED}s)"
pass "the parent/child marker cannot be injected from the environment"

# A signal that used to switch the deadline off and now does nothing must not
# fail silently in either direction: whoever exports it should learn that it
# stopped meaning anything, rather than keep believing the deadline is off.
grep -q 'BUDGET_CHILD' <<< "${GUARD_STDERR}" \
  || fail "the ignored marker is announced on stderr (got: $(printf '%s' "${GUARD_STDERR}" | head -c 80))"
grep -q 'BUDGET_CHILD' "${GUARD_STATE_DIR}/advisory.log" \
  || fail "the ignored marker is recorded in advisory.log"
pass "the ignored marker says it is ignored, on both channels"

# --- the knob reader itself must not become the slow path --------------------
# Both knobs go through one reader, and that reader runs BEFORE the child spawn
# — outside the deadline it exists to serve, where nothing can interrupt it. It
# has been the slow path twice: a per-zero strip loop (28.9s on 40000 leading
# zeros, 63.2s on 60000), then the regex that replaced it, which cut the
# constant about a hundredfold and left the quadratic class alone — the reader
# still quadrupled its time for every doubling (50k 0.34s, 400k 20.2s, 800k
# 88.0s), so 500000 zeros burned 224s end to end.
#
# What bounds it is a length ceiling on the INPUT, decided before any pattern
# touches the string. So the case here is sized past that ceiling by four orders
# of magnitude: whatever the parse costs per character, the answer must not
# depend on it. A regression that only reinstated the old constant would still
# pass a 60000-zero case, which is why this one is 500000.
#
# Where the platform allows it. Linux refuses any single environment string
# over 128KB (MAX_ARG_STRLEN), so `exec` fails with E2BIG before the guard
# starts. Measured on ubuntu:24.04: 131000 zeros launch, 131100 do not. That
# failure used to read as an empty answer, and so as `pass`, which kept ubuntu
# CI red for a reason that had nothing to do with the knob reader. On such a
# platform the case runs at the largest value the kernel will carry, and says
# so. That is also the largest value an attacker there can set, so the case
# still covers the whole reachable range.
knob_padding=500000
zeros=$(head -c "${knob_padding}" < /dev/zero | tr '\0' '0')
if ! SAFEDEPS_SELF_BUDGET_SECONDS="${zeros}3" env true 2>/dev/null; then
  knob_padding=131000
  zeros=$(head -c "${knob_padding}" < /dev/zero | tr '\0' '0')
  SAFEDEPS_SELF_BUDGET_SECONDS="${zeros}3" env true 2>/dev/null \
    || fail "this platform can carry a ${knob_padding}-character budget to the guard"
  printf '# note - this platform refuses a 500000-character environment string; the padded budget runs at %s characters\n' "${knob_padding}"
fi
guard "pip install requests==2.31.0 # ${big}" "${zeros}3"
[[ "${GUARD_DECISION}" == "deny" ]] || fail "an absurdly padded budget still decides (got: ${GUARD_DECISION})"
(( GUARD_ELAPSED < runtime_budget )) \
  || fail "reading an absurdly padded budget stays inside the runtime budget (took ${GUARD_ELAPSED}s; the parse runs where the deadline cannot reach it)"
grep -q 'characters' <<< "${GUARD_STDERR}" \
  || fail "a refused over-long value is reported by length rather than quoted whole"
(( ${#GUARD_STDERR} < 4096 )) \
  || fail "a refused over-long value is truncated in the message (${#GUARD_STDERR} bytes on stderr)"
pass "the knob reader refuses over-long input before parsing it, so padding cannot burn the runtime budget"

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
