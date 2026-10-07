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

# --- a loaded machine, on demand ---------------------------------------------
# The deadline used to add up the sleeps it asked for, and on a loaded machine
# a sleep takes longer than it asks for. `loaded_bin` holds a `sleep` that
# stretches every sleep by the factor in a file: 3 stands in for load, and 1
# only records. Either way it writes down what it was asked and its own pid.
# Unlike the awk shim, it sits on the PARENT's path on purpose, because the
# parent keeps the deadline with `sleep` and that is the clock under test. It
# also stretches the awk shim's sleep, which only makes the judgment longer.
# Like the awk shim it sleeps from `/`, and it execs the real sleep, so the pid
# it records is the sleeper's own.
real_sleep=$(command -v sleep)
loaded_bin="${tmp_root}/loaded-bin"
loaded_factor_file="${tmp_root}/loaded-factor"
loaded_log="${tmp_root}/loaded-log"
loaded_pids="${tmp_root}/loaded-pids"
mkdir -p "${loaded_bin}"
{
  printf '#!/usr/bin/env bash\n'
  printf "real_sleep='%s'\nfactor_file='%s'\nlog='%s'\npids='%s'\n" \
    "${real_sleep}" "${loaded_factor_file}" "${loaded_log}" "${loaded_pids}"
  cat <<'SHIM'
arg="${1:-}"
printf '%s\n' "${arg}" >> "${log}"
printf '%s\n' "$$" >> "${pids}"
factor=""
IFS= read -r factor < "${factor_file}" || true
[[ "${factor}" =~ ^[0-9]+$ ]] || factor=1
number='^([0-9]+)(\.([0-9]{1,3}))?$'
if [[ "${arg}" =~ ${number} ]]; then
  frac="${BASH_REMATCH[3]}000"
  ms=$(( (10#${BASH_REMATCH[1]} * 1000 + 10#${frac:0:3}) * factor ))
  printf -v arg '%d.%03d' $(( ms / 1000 )) $(( ms % 1000 ))
fi
cd / || exit 1
exec "${real_sleep}" "${arg}"
SHIM
} > "${loaded_bin}/sleep"
chmod +x "${loaded_bin}/sleep"

# Puts the loaded `sleep` in front of the next guard run, with every sleep
# stretched <factor> times, and starts its records fresh.
LOADED_PATH=""
load_machine() {
  printf '%s\n' "$1" > "${loaded_factor_file}"
  : > "${loaded_log}"
  : > "${loaded_pids}"
  LOADED_PATH="${loaded_bin}:"
}

# True once every sleep the loaded shim ran is gone, waiting up to two seconds
# for each to be reaped, as slow_sleeper_gone does.
loaded_sleepers_gone() {
  local pid tries
  while IFS= read -r pid; do
    [[ -n "${pid}" ]] || continue
    tries=0
    while kill -0 "${pid}" 2>/dev/null; do
      (( tries++ < 40 )) || return 1
      sleep 0.05
    done
  done < "${loaded_pids}"
}

# A millisecond clock that bash 3.2 lacks, as scripts/measure/npm-ask-cost.sh
# reads it. Only the runs that ask for it pay for the two node starts.
now_ms() { node -e 'process.stdout.write(String(Date.now()))'; }

# Long enough that nothing but the deadline can answer inside the runtime's 30s.
never=60

# Runs the guard and captures decision, whether the reason is the undecided
# one, and how long the answer took.
GUARD_PATH=""
GUARD_IGNORE_TERM=""
# A SECONDS value for the guard's environment, which bash seeds its clock from.
GUARD_SECONDS=""
# Set to also time the run in milliseconds, into GUARD_ELAPSED_MS.
GUARD_CLOCK_MS=""
guard() {
  local command="$1" budget="${2:-2}" engage="${3:-1024}" disabled="${4:-}" legacy_child="${5:-}"
  # mktemp for the same reason as consumer-forms.sh: `$$` is constant within a
  # run so isolation rested on RANDOM alone, and `mkdir -p` cannot report a
  # collision. Uniqueness is the kernel's job.
  local safe
  safe=$(mktemp -d "${tmp_root}/safe.XXXXXX")
  GUARD_STATE_DIR="${safe}"
  local start end rc=0
  local launch=(scripts/safedeps-hook-entry.sh pre)
  if [[ -n "${GUARD_IGNORE_TERM}" ]]; then
    # A signal ignored on entry stays ignored across exec, and bash cannot trap
    # or reset it, so every process in the judgment inherits a deaf TERM.
    launch=(bash -c 'trap "" TERM; exec "$@"' ignore-term scripts/safedeps-hook-entry.sh pre)
  fi
  if [[ -n "${GUARD_SECONDS}" ]]; then
    # Through env, because an assignment in front of a command would be read
    # by this shell's own SECONDS.
    launch=(env "SECONDS=${GUARD_SECONDS}" "${launch[@]}")
  fi
  local start_ms=0 end_ms=0
  start=$(date +%s)
  [[ -z "${GUARD_CLOCK_MS}" ]] || start_ms=$(now_ms)
  GUARD_OUT=$(jq -nc --arg c "${command}" --arg cwd "${project_dir}" \
    '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}' |
    PATH="${GUARD_PATH:-${PATH}}" \
    HOME="${tmp_root}/home" SAFEDEPS_HOME="${safe}" \
    SAFEDEPS_SELF_BUDGET_SECONDS="${budget}" \
    SAFEDEPS_BUDGET_ENGAGE_BYTES="${engage}" \
    SAFEDEPS_BUDGET_DISABLED="${disabled}" \
    SAFEDEPS_BUDGET_CHILD="${legacy_child}" \
    "${launch[@]}" 2>"${tmp_root}/stderr") || rc=$?
  [[ -z "${GUARD_CLOCK_MS}" ]] || end_ms=$(now_ms)
  GUARD_STDERR=$(cat "${tmp_root}/stderr" 2>/dev/null || printf '')
  end=$(date +%s)
  GUARD_ELAPSED=$(( end - start ))
  GUARD_ELAPSED_MS=$(( end_ms - start_ms ))
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
  GUARD_PATH="${slow_bin}:${LOADED_PATH}${PATH}"
  guard "$@"
  GUARD_PATH=""
  LOADED_PATH=""
}

# `guard`, on the loaded machine load_machine set up.
loaded_guard() {
  GUARD_PATH="${LOADED_PATH}${PATH}"
  guard "$@"
  GUARD_PATH=""
  LOADED_PATH=""
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

# The deadline is checked between polls on a whole-second clock that starts
# with the guard, so it fires up to a second early and at most one poll step
# late, and the longest step is 1s.
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

# --- what every Bash call pays to start ---------------------------------------
# Both hooks source these libraries on every Bash call, before they read the
# command, so their load time is added to `ls` as much as to an install. The
# install grammar once spent 0.9s here under macOS /bin/bash (bash 3.2), whose
# `${table//$'\n'/ }` is quadratic in a table's length; bash 5 did not show it,
# and neither did a measurement that timed installs instead of plain commands.
# So each file is timed by itself, under the bash on PATH and under /bin/bash
# when that is another one, as the fastest of five loads: a slow load measures
# the machine, a fast one bounds the file. A healthy load is about 10ms.
startup_libs=(lib/truth-sources.sh lib/install-grammar.sh lib/npm/ask.sh
  lib/npm/workspaces.sh lib/ledger/ledger.sh lib/providers/providers.sh
  lib/npm/closure.sh lib/gates/rollback-journal.sh)
startup_shells=(bash)
[[ ! -x /bin/bash || "$(command -v bash)" == /bin/bash ]] || startup_shells+=(/bin/bash)
startup_bound_ms=250
# The fastest of <tries> loads of <file> under <shell>, in ms, as LOAD_MS. The
# shell's own `time` reads the clock, so the figure excludes starting the shell.
load_ms() {
  local sh="$1" file="$2" tries="$3" i t ms
  LOAD_MS=""
  for (( i = 0; i < tries; i++ )); do
    # shellcheck disable=SC2016  # expanded by the shell under test
    t=$("${sh}" -c 'TIMEFORMAT=%3R; { time source "$1" >/dev/null 2>&1; } 2>&1' load-cost "${file}") || true
    [[ "${t}" =~ ^[0-9]+[.][0-9]{3}$ ]] \
      || fail "loading ${file} under ${sh} is timed (got: '${t}')"
    ms=$(( 10#${t/./} ))
    [[ -n "${LOAD_MS}" ]] && (( ms >= LOAD_MS )) || LOAD_MS=${ms}
  done
}
# The control: a file that takes 0.3s to load reads as over the bound, so a
# clean result below is the clock's answer, not a reading that cannot fail.
printf 'sleep 0.3\n' > "${tmp_root}/slow-load.sh"
load_ms bash "${tmp_root}/slow-load.sh" 1
(( LOAD_MS >= startup_bound_ms )) \
  || fail "the load clock reads a 0.3s load as over ${startup_bound_ms}ms (read ${LOAD_MS}ms)"
startup_note=""
for sh in "${startup_shells[@]}"; do
  for lib in "${startup_libs[@]}"; do
    load_ms "${sh}" "${ROOT_DIR}/${lib}" 5
    startup_note+=" ${lib##*/}=${LOAD_MS}"
    (( LOAD_MS < startup_bound_ms )) \
      || fail "${lib} loads in under ${startup_bound_ms}ms under ${sh} (fastest of 5: ${LOAD_MS}ms); every Bash call pays this, twice"
  done
  # shellcheck disable=SC2016  # expanded by the shell under test
  printf '# note - load under %s (%s), fastest of 5, ms:%s\n' "${sh}" \
    "$("${sh}" -c 'printf %s "${BASH_VERSION}"')" "${startup_note}"
  startup_note=""
done
pass "every library the hooks load on every Bash call loads in under ${startup_bound_ms}ms, under each bash here"

# --- a fast judgment is answered as fast as before ---------------------------
# The rows after this one make the deadline read the clock. Doing that must not
# cost the fast path anything: the parent still polls in steps that start at
# 50ms, so a judgment that finishes inside the first step is answered at 50ms.
# A clock-only loop that slept a whole second per check would pass every
# deadline row below and add up to a second to every engaged call.
#
# Two rows, because a time measurement alone cannot tell that apart from a slow
# machine. The schedule row reads the sleeps the parent asked for, through the
# loaded shim at factor 1, and fails on a coarse first step on any machine. The
# timing row measures it in real time, engaged against inline on the same
# command, and fails when the engaged path adds a second or more on top of the
# child it spawns. "ls -la" engages at 1 byte and reaches no package manager,
# so the judgment is as short as the guard makes one.
command -v node >/dev/null 2>&1 || fail "node is on PATH for the millisecond clock"

load_machine 1
loaded_guard "ls -la" 20 1
[[ "${GUARD_DECISION}" == "pass" ]] || fail "an engaged fast judgment passes (got: ${GUARD_DECISION})"
fast_first_step=$(head -n 1 "${loaded_log}")
[[ "${fast_first_step}" == "0.050" ]] \
  || fail "the parent's first poll is the 50ms step (asked for: '${fast_first_step}'; sleeps: $(tr '\n' ' ' < "${loaded_log}"))"
while IFS= read -r fast_step; do
  case "${fast_step}" in
    0.*|1.000) ;;
    *) fail "no poll step is longer than 1s (asked for: ${fast_step})" ;;
  esac
done < "${loaded_log}"
pass "the parent still polls from a 50ms first step, capped at 1s"

# The fastest of three runs, because a slow run measures the machine, not the
# path. Inline is the baseline: it is the same judgment without the machinery.
fastest_ms() {
  local engage="$1" _
  FASTEST_MS=""
  for _ in 1 2 3; do
    GUARD_CLOCK_MS=1
    guard "ls -la" 20 "${engage}"
    GUARD_CLOCK_MS=""
    [[ "${GUARD_DECISION}" == "pass" ]] || fail "a fast judgment passes, engage ${engage} (got: ${GUARD_DECISION})"
    if [[ -z "${FASTEST_MS}" ]] || (( GUARD_ELAPSED_MS < FASTEST_MS )); then
      FASTEST_MS=${GUARD_ELAPSED_MS}
    fi
  done
}
fastest_ms 1024
fast_inline_ms=${FASTEST_MS}
fastest_ms 1
fast_engaged_ms=${FASTEST_MS}
printf '# note - fast judgment, fastest of 3: engaged %sms, inline %sms\n' "${fast_engaged_ms}" "${fast_inline_ms}"
# The whole guard on a plain command, inline. The rows above bound each file
# it loads; this one bounds whatever else a change might add to every call.
# About 140ms on an M1 at load 20; a second more is the regression it catches.
(( fast_inline_ms < 1000 )) \
  || fail "a plain command's guard answers in under a second, inline (fastest of 3: ${fast_inline_ms}ms)"
pass "a plain command's guard answers in under a second"
(( fast_engaged_ms - fast_inline_ms < 1000 )) \
  || fail "an engaged fast judgment adds less than a second to the inline one (engaged ${fast_engaged_ms}ms, inline ${fast_inline_ms}ms)"
pass "an engaged fast judgment is answered without waiting out a whole second"

# --- the deadline is read from the clock, not added up from its sleeps -------
# The deadline used to count the time its sleeps asked for. On a loaded machine
# a sleep takes longer than it asks, so the real wait ran past the budget by
# whatever load added to every step. Against the 4s budget below, that loop
# stops once its requests add up to 4.55s, which at three times per sleep is
# about 13.7s of real time. Past the runtime's 30s the hook is killed and the
# install proceeds unjudged.
#
# The loaded shim stretches every sleep threefold, and the awk shim holds the
# judgment so nothing but the deadline answers. The margin is one stretched 1s
# step (3s), plus a second for the grace, the reap and jq. It does not grow
# with the budget, because only the last step is late.
loaded_budget=4
loaded_margin=4
load_machine 3
GUARD_CLOCK_MS=1
slow_guard "${never}" "pip install requests==2.31.0 # ${big}" "${loaded_budget}"
GUARD_CLOCK_MS=""
[[ "${GUARD_DECISION}" == "deny" ]] || fail "on a loaded machine the stuck judgment is denied (got: ${GUARD_DECISION})"
grep -q 'UNDECIDED' <<< "${GUARD_REASON}" || fail "on a loaded machine the deny is the undecided one"
printf '# note - loaded machine, sleeps x3: UNDECIDED after %sms against a %ss budget\n' "${GUARD_ELAPSED_MS}" "${loaded_budget}"
(( GUARD_ELAPSED_MS <= (loaded_budget + loaded_margin) * 1000 )) \
  || fail "on a loaded machine the answer lands within the ${loaded_budget}s budget plus ${loaded_margin}s (took ${GUARD_ELAPSED_MS}ms; a deadline that adds up its sleeps lands near three times the budget)"
pass "on a loaded machine the deadline holds in wall-clock time"

slow_sleeper_gone \
  || fail "on a loaded machine the deadline still takes the blocked command down"
loaded_sleepers_gone \
  || fail "no sleep the loaded run started outlives the answer"
pass "on a loaded machine the deadline leaves no sleeper behind"

# Bash seeds SECONDS from the environment. A deadline that compared SECONDS
# itself, rather than its distance from the guard's start, would never arrive
# under an exported SECONDS=-1000000, and only the requested-sleep bound would
# end the wait: the late answer above, through a different door.
load_machine 3
GUARD_CLOCK_MS=1
GUARD_SECONDS=-1000000
slow_guard "${never}" "pip install requests==2.31.0 # ${big}" "${loaded_budget}"
GUARD_SECONDS=""
GUARD_CLOCK_MS=""
[[ "${GUARD_DECISION}" == "deny" ]] || fail "an exported SECONDS does not turn the deadline into a pass (got: ${GUARD_DECISION})"
grep -q 'UNDECIDED' <<< "${GUARD_REASON}" || fail "an exported SECONDS still ends in the undecided deny"
(( GUARD_ELAPSED_MS <= (loaded_budget + loaded_margin) * 1000 )) \
  || fail "an exported SECONDS does not move the deadline (took ${GUARD_ELAPSED_MS}ms against the ${loaded_budget}s budget plus ${loaded_margin}s)"
pass "an exported SECONDS does not move the deadline"

# --- the budget is tunable only downward ------------------------------------
# A self budget at or above the runtime's hook budget is not a budget: the
# runtime kills the hook first and the tool call proceeds, which is the exact
# fail-open the machinery above exists to remove. The value is therefore clamped
# to a ceiling below the runtime budget. Both constants are read from the guard
# so this battery tracks them instead of restating them.
# Read the production budget values without extracting a Bash hook body.
source "${ROOT_DIR}/scripts/test/lib/core-reader.sh"
core_reader_init "${ROOT_DIR}"
budget_config=$("${SAFEDEPS_TEST_CORE}" budget-config)
runtime_budget=$(jq -r '.runtime_budget_seconds' <<< "${budget_config}")
budget_ceiling=$(jq -r '.self_budget_max_seconds' <<< "${budget_config}")
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
# payload. This is the case a naive budget breaks. The budget is 3s, not 2s,
# because the whole-second clock can end a budget up to a second early. 3s
# still leaves the judgment more than 2s, as this row always has.
guard "echo ${small}" 3 128
[[ "${GUARD_DECISION}" == "pass" ]] || fail "engaged in-budget benign command still passes (got: ${GUARD_DECISION})"
pass "engaged but in-budget benign command still passes"

guard "npm install left-pad@1.3.0" 20 16
[[ "${GUARD_DECISION}" == "deny" ]] || fail "engaged in-budget install still decides normally (got: ${GUARD_DECISION})"
if grep -q 'UNDECIDED' <<< "${GUARD_REASON}"; then fail "engaged in-budget install is judged, not timed out"; fi
pass "engaged but in-budget install is judged normally, not timed out"

# A 64KB command with an install, under the default budget, gets the verdict
# it gets at 100 bytes. On macOS (bash 3.2 and the BWK awk) the judgment used
# to cost the square of a long word: 37.5s for this shape with the deadline
# off on an M1 (v2.18.0), so the deadline answered UNDECIDED in its place.
# It is linear now; the row turns red if a quadratic step comes back on
# macOS, where the CI job runs it. On Linux it was fast either way.
guard "echo $(pad 65490) ; npm install left-pad@1.3.0" 20
[[ "${GUARD_DECISION}" == "deny" ]] || fail "a 64KB install is judged inside the default budget (got: ${GUARD_DECISION})"
if grep -q 'UNDECIDED' <<< "${GUARD_REASON}"; then fail "a 64KB install is judged, not timed out (took ${GUARD_ELAPSED}s)"; fi
printf '# note - 64KB install judged in %ss\n' "${GUARD_ELAPSED}"
pass "a 64KB install is judged inside the default budget, not answered UNDECIDED"

# The gate's cost grew with the number of statements, not the bytes: a reader
# that asked about each statement paid a dozen processes for each. On the
# project's Linux VM an `sh -c` script of 40 short functions took 49s and 400
# one-line statements with an install 68s (scan-cost's statements table,
# deadline off), so the deadline answered UNDECIDED in their place. Each of
# these shapes gets its verdict, not UNDECIDED, under the default budget, on
# both systems.
unit="f() { echo 'a b' \\\"\$x\\\" (1); }; "
script=""
for (( i = 0; i < 33; i++ )); do script+="${unit}"; done
guard "sh -c \"${script}\" ; npm install left-pad@1.3.0" 20
[[ "${GUARD_DECISION}" == "deny" ]] || fail "a 1KB sh -c script of 33 functions is judged inside the default budget (got: ${GUARD_DECISION})"
if grep -q 'UNDECIDED' <<< "${GUARD_REASON}"; then fail "a 1KB sh -c script of 33 functions is judged, not timed out (took ${GUARD_ELAPSED}s)"; fi
printf '# note - 1KB sh -c script of 33 functions judged in %ss\n' "${GUARD_ELAPSED}"
pass "a 1KB sh -c script of short functions is judged inside the default budget, not answered UNDECIDED"

lines=""
for (( i = 0; ${#lines} < 32700; i++ )); do lines+="echo line${i}"$'\n'; done
guard "${lines}npm install left-pad@1.3.0" 20
[[ "${GUARD_DECISION}" == "deny" ]] || fail "32KB of one-line statements with an install is judged inside the default budget (got: ${GUARD_DECISION})"
if grep -q 'UNDECIDED' <<< "${GUARD_REASON}"; then fail "32KB of one-line statements with an install is judged, not timed out (took ${GUARD_ELAPSED}s)"; fi
printf '# note - 32KB of one-line statements (%s) with an install judged in %ss\n' "${i}" "${GUARD_ELAPSED}"
pass "32KB of one-line statements with an install is judged inside the default budget, not answered UNDECIDED"

guard "${lines}echo done" 20
if grep -q 'UNDECIDED' <<< "${GUARD_REASON}"; then fail "32KB of one-line statements is judged, not timed out (took ${GUARD_ELAPSED}s)"; fi
printf '# note - 32KB of one-line statements with no install judged in %ss\n' "${GUARD_ELAPSED}"
pass "32KB of one-line statements with no install is judged inside the default budget, not answered UNDECIDED"

printf 'self-budget battery: all checks passed\n'
