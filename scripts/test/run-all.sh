#!/usr/bin/env bash
# safedeps: the npm test runner.
#
# Runs every battery and reports on each one. The batteries used to run as one
# `&&` chain, so a full run cost the sum of thirteen batteries and stopped at
# the first red. They do not share state: each makes its own mktemp root and
# points HOME or SAFEDEPS_HOME into it, and every fixture server listens on a
# port the kernel picks (or the closed port 9). So the batteries in one phase
# run at the same time, and the phases run one after another.
#
# Every battery runs, whatever another one answered. Each writes one log. At the
# end the runner prints every log in the order below, then one summary line per
# battery, then the tail of each failed battery's log. It exits non-zero when
# any battery exited non-zero or printed a `not ok` line, and names them.
#
# SAFEDEPS_TEST_SERIAL=1 runs the batteries one at a time, in the order below,
# which is the order of the old chain. Use it to tell a defect from contention.
# SAFEDEPS_TEST_LOG_DIR=<dir> keeps the logs there instead of a fresh mktemp
# directory. The logs are never deleted; the summary names where they are.
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "${ROOT_DIR}" || exit 2

# <name>|<phase>|<command>, in the old chain's order.
#
# The second phase holds the batteries that a busy machine turns red without a
# defect:
#
#   self-budget        times the guard's answers against budgets of one to
#                      twenty-five seconds. On its own it is nearly all sleep.
#   effect-trace-grid  needs at least one npm install, of twelve tries, to
#                      write its lockfile inside the wall-clock second the
#                      pre-guard ran in. Run in the first phase on a Mac at
#                      load 120-200, the lockfile landed 0.6-5.7s after the
#                      pre-guard in every try and the battery failed; on the
#                      8-CPU Linux VM at load 17 it landed after 0.4s.
#
# Neither loads the machine much, so they share the phase. It starts when the
# census finishes, not when the whole first phase does: the census runs a guard
# per CPU and is the load these two cannot stand, while every other battery is
# one process at a time. On the Mac the single-process batteries outlasted the
# census by six minutes.
BATTERIES=(
  "smoke|1|scripts/test/smoke.sh"
  "scan-contract|1|scripts/test/scan-contract.sh"
  "shell-reading|1|scripts/test/shell-reading.sh"
  "census|1|scripts/measure/scan-failure-census.sh --quick"
  "consumer-forms|1|scripts/test/consumer-forms.sh"
  "install-dir-differential|1|scripts/test/install-dir-differential.sh"
  "workspace-snapshot-count|1|scripts/test/workspace-snapshot-count.sh"
  "self-budget|2|scripts/test/self-budget.sh"
  "advisory-log-retention|1|scripts/test/advisory-log-retention.sh"
  "hook-entry|1|scripts/test/hook-entry.sh"
  "lockless-forms|1|scripts/test/lockless-forms.sh"
  "effect-trace-grid|2|scripts/test/effect-trace-grid.sh"
  "e2e|1|scripts/test/e2e.sh"
)
PHASE_TWO_AFTER=census
# Checked before anything starts: a second phase with nothing to wait for would
# start at once, under the very load it exists to avoid.
printf '%s\n' "${BATTERIES[@]}" | grep -qx "${PHASE_TWO_AFTER}|1|.*" || {
  printf 'run-all: the second phase waits for %s, and no first-phase battery has that name\n' "${PHASE_TWO_AFTER}" >&2
  exit 2
}

serial=false
[[ "${SAFEDEPS_TEST_SERIAL:-}" == 1 ]] && serial=true

if [[ -n "${SAFEDEPS_TEST_LOG_DIR:-}" ]]; then
  log_dir="${SAFEDEPS_TEST_LOG_DIR}"
  mkdir -p "${log_dir}" || { printf 'run-all: cannot create %s\n' "${log_dir}" >&2; exit 2; }
else
  tmp_base="${TMPDIR:-/tmp}"
  log_dir=$(mktemp -d "${tmp_base%/}/safedeps-test.XXXXXX") \
    || { printf 'run-all: cannot create a log directory\n' >&2; exit 2; }
fi

# The load averages, without the platform's framing (macOS prints "load
# averages: a b c", Linux "load average: a, b, c").
load_now() { uptime | sed -E 's/.*load averages?: *//; s/,//g'; }

# Runs one battery into its log and records rc, seconds and load.
run_one() {
  local name="$1" command="$2" start rc=0
  printf '%s\n' "$(load_now)" > "${log_dir}/${name}.load-start"
  start=$(date +%s)
  # shellcheck disable=SC2086 # the command is a script path plus fixed flags
  bash ${command} > "${log_dir}/${name}.log" 2>&1 < /dev/null || rc=$?
  printf '%s\n' "$(( $(date +%s) - start ))" > "${log_dir}/${name}.secs"
  printf '%s\n' "$(load_now)" > "${log_dir}/${name}.load-end"
  printf '%s\n' "${rc}" > "${log_dir}/${name}.rc"
  printf '# done %s rc=%s %ss\n' "${name}" "${rc}" "$(cat "${log_dir}/${name}.secs")"
}

# Job control gives each battery a process group of its own, so an interrupt
# can stop a battery together with everything it started. It also keeps SIGINT
# live inside the batteries: without it a shell starts background jobs with
# SIGINT ignored, and nothing below them could ever take one.
set -m
pids=()
stop_batteries() {
  local pid
  for pid in "${pids[@]:-}"; do
    [[ -n "${pid}" ]] && kill -TERM -- "-${pid}" 2>/dev/null
  done
  wait 2>/dev/null
  printf 'run-all: interrupted; logs are in %s\n' "${log_dir}" >&2
  exit 130
}
trap stop_batteries INT TERM

suite_start=$(date +%s)
printf '# safedeps npm test: %s, logs in %s, load %s, %s CPUs\n' \
  "$([[ "${serial}" == true ]] && printf serial || printf parallel)" "${log_dir}" "$(load_now)" \
  "$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || printf '?')"

if [[ "${serial}" == true ]]; then
  for entry in "${BATTERIES[@]}"; do
    IFS='|' read -r name _ command <<< "${entry}"
    run_one "${name}" "${command}" &
    pids=("$!")
    wait "${pids[0]}"
  done
else
  gate_pid=""
  for entry in "${BATTERIES[@]}"; do
    IFS='|' read -r name battery_phase command <<< "${entry}"
    [[ "${battery_phase}" == 1 ]] || continue
    run_one "${name}" "${command}" &
    pids+=("$!")
    [[ "${name}" != "${PHASE_TWO_AFTER}" ]] || gate_pid=$!
  done
  wait "${gate_pid}"
  for entry in "${BATTERIES[@]}"; do
    IFS='|' read -r name battery_phase command <<< "${entry}"
    [[ "${battery_phase}" == 2 ]] || continue
    run_one "${name}" "${command}" &
    pids+=("$!")
  done
  wait
fi
pids=()
suite_secs=$(( $(date +%s) - suite_start ))

# --- report -----------------------------------------------------------------------
for entry in "${BATTERIES[@]}"; do
  IFS='|' read -r name _ _ <<< "${entry}"
  printf '\n# ---- %s ----\n' "${name}"
  cat "${log_dir}/${name}.log" 2>/dev/null
done

failed=()
printf '\n# summary (%s, %ss, load now %s)\n' \
  "$([[ "${serial}" == true ]] && printf serial || printf parallel)" "${suite_secs}" "$(load_now)"
printf '# %-26s %4s %5s %7s %6s  %-20s %s\n' battery rc ok 'not ok' secs 'load at start' 'load at end'
for entry in "${BATTERIES[@]}"; do
  IFS='|' read -r name _ _ <<< "${entry}"
  log="${log_dir}/${name}.log"
  rc=$(cat "${log_dir}/${name}.rc" 2>/dev/null || printf 'none')
  ok=$(grep -c '^ok' "${log}" 2>/dev/null)
  not_ok=$(grep -c '^not ok' "${log}" 2>/dev/null)
  printf '# %-26s %4s %5s %7s %6s  %-20s %s\n' "${name}" "${rc}" "${ok:-0}" "${not_ok:-0}" \
    "$(cat "${log_dir}/${name}.secs" 2>/dev/null || printf '?')" \
    "$(cat "${log_dir}/${name}.load-start" 2>/dev/null || printf '?')" \
    "$(cat "${log_dir}/${name}.load-end" 2>/dev/null || printf '?')"
  # A battery fails on a non-zero exit, and also on a `not ok` line it printed
  # and then exited 0 over: either one is a red the old chain would have shown.
  if [[ "${rc}" != 0 || "${not_ok:-0}" != 0 ]]; then
    failed+=("${name}")
  fi
done

if (( ${#failed[@]} == 0 )); then
  printf '# all %d batteries passed\n' "${#BATTERIES[@]}"
  exit 0
fi
printf '# FAILED: %s\n' "${failed[*]}"
# The tails are indented, so `ok` and `not ok` counted over the whole output
# still add up to the logs above rather than counting these lines twice.
for name in "${failed[@]}"; do
  printf '\n# ---- tail of %s (%s) ----\n' "${name}" "${log_dir}/${name}.log"
  tail -n 25 "${log_dir}/${name}.log" 2>/dev/null | sed 's/^/  | /'
done
exit 1
