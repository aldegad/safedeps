#!/usr/bin/env bash
# safedeps: the npm test runner.
#
#   run-all.sh               the development set: every battery but the two
#                            that only a release needs (`npm test`)
#   run-all.sh --release     every battery (`npm run test:release`)
#   run-all.sh --list [--release]
#                            print the names of the batteries a run would
#                            start, one per line, and start nothing
#   run-all.sh --units [--release]
#                            print the units scripts/ci/run-on-hosts.sh splits
#                            that set into, one per line: a battery's name, or
#                            <name>@<I>of<M> for shard I of a battery the table
#                            splits into M
#   run-all.sh --plan [--release]
#                            the same units as `<unit> <weight> <seconds>`, for
#                            the runner's scheduler (see the table)
#   run-all.sh --unit UNIT --core-receipt FILE
#                            check the host's prepared binary, then run one
#                            unit into SAFEDEPS_TEST_LOG_DIR; never build here
#
# A whole set builds the host binary once before starting any battery. The
# host runner prepares it once for all its units and passes the receipt.
#
# The development set leaves out the census and effect-trace-grid. The census
# took 72 minutes of a 2-hour macOS CI run (v2.18.0, run 37191343467), and
# effect-trace-grid waits for it and then runs another 19 to 47. Both measure
# what a release ships, and AGENTS.md ("What to run, and where") runs them per
# release, not per change; a change that reaches the scan readings or the
# effect gate runs them by name.
#
# Runs the batteries it selects and reports on each one. The batteries used to
# run as one `&&` chain, so a full run cost the sum of thirteen batteries and
# stopped at the first red. They do not share state: each makes its own mktemp root and
# points HOME or SAFEDEPS_HOME into it, and every fixture server listens on a
# port the kernel picks (or the closed port 9). So the batteries of a phase run
# at the same time. The second phase waits for the census, not for the whole
# first phase (see below).
#
# Every battery runs, whatever another one answered. Each writes one log. At the
# end the runner prints every log in the order below, then one summary line per
# battery, then the tail of each failed battery's log. It exits non-zero when
# any battery exited non-zero, printed a `not ok` line, or (the census aside)
# printed no `ok` line, and names them.
#
# The runner never takes the whole machine by default. At most SAFEDEPS_TEST_JOBS
# batteries run at once, and the census runs that many guards; the default is
# half the CPUs, rounded up. Developer machines are shared: an uncapped run on a
# 16-CPU Mac already at load 100 took it past 300 and starved other sessions.
# SAFEDEPS_TEST_SERIAL=1 runs the batteries one at a time, in the order below,
# which is the order of the old chain. Use it to tell a defect from contention.
# SAFEDEPS_TEST_LOG_DIR=<dir> keeps the logs there instead of a fresh mktemp
# directory. The logs are never deleted; the summary names where they are.
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "${ROOT_DIR}" || exit 2

# <name>|<phase>|<scope>|<shards>|<weight>|<seconds>|<command>, in the old chain's order.
#
# scope is `dev` for a battery `npm test` runs and `release` for one only a
# release runs.
#
# shards and weight are for scripts/ci/run-on-hosts.sh, which runs a set on
# several hosts at once and has ten minutes of wall clock for it (AGENTS.md,
# Testing). shards is how many units the battery is split into: shard I of M
# runs the battery with `--shard I/M` (scripts/test/lib/shard.sh; the census
# has its own, with `--out`). weight is how many CPUs one unit keeps busy, so
# a host is not handed more work than it has CPUs for: manager-variants judges
# eight forms at a time, install-dir-differential six, and a census shard runs
# that many guards (SAFEDEPS_TEST_JOBS, which --unit sets to the weight).
# seconds is the measured wall clock of the whole battery at its weight, from
# the plan's measurement (safedeps/suite-in-ten-minutes-on-our-hosts, 744ea16,
# alex-macbook-m1 and carenine at load 2-25; the census from one shard of
# eight); the runner starts the longest units first. A local
# run (`npm test`, --release) ignores all three and runs each battery whole.
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
ALL_BATTERIES=(
  "rust-core|1|dev|1|1|30|scripts/test/rust-core.sh"
  "smoke|1|dev|1|1|350|scripts/test/smoke.sh"
  "scan-contract|1|dev|3|1|861|scripts/test/scan-contract.sh"
  "statement-batch|1|dev|1|1|263|scripts/test/statement-batch.sh"
  "shell-reading|1|dev|1|1|295|scripts/test/shell-reading.sh"
  "census|1|release|4|2|1030|scripts/measure/scan-failure-census.sh --quick"
  "consumer-forms|1|dev|4|1|1126|scripts/test/consumer-forms.sh"
  "manager-variants|1|dev|3|4|650|scripts/test/manager-variants.sh"
  "install-dir-differential|1|dev|1|6|134|scripts/test/install-dir-differential.sh"
  "workspace-snapshot-count|1|dev|1|1|8|scripts/test/workspace-snapshot-count.sh"
  "self-budget|2|dev|1|1|140|scripts/test/self-budget.sh"
  "advisory-log-retention|1|dev|1|1|1|scripts/test/advisory-log-retention.sh"
  "hook-entry|1|dev|1|1|2|scripts/test/hook-entry.sh"
  "lockless-forms|1|dev|2|1|509|scripts/test/lockless-forms.sh"
  "effect-trace-grid|2|release|2|1|803|scripts/test/effect-trace-grid.sh"
  "e2e|1|dev|1|1|351|scripts/test/e2e.sh"
)
#
# A run without the census (the development set, one unit) has no second
# phase to wait for: the load these two cannot stand is the census's, and every
# other battery is one process at a time. So there they start in the order
# below like any other battery.
PHASE_TWO_AFTER=census
# The batteries that start first when slots are short, longest first (alone on
# the 8-CPU Linux VM: census 431s, consumer-forms 373s, lockless-forms 313s,
# effect-trace-grid 214s). The rest follow in the order above.
START_FIRST_ALL=(census consumer-forms lockless-forms effect-trace-grid)
# Checked before anything starts, on the whole table: a second phase with
# nothing to wait for would start at once, under the very load it exists to
# avoid.
# Whether an entry of a table starts with <prefix>. Asked with no pipe: under
# pipefail, `printf ... | grep -q` fails when grep leaves at its first match
# while printf is still writing (SIGPIPE, 141). On a loaded host that read as
# "not a battery" and ended a unit before it started, with no exit status
# (two of 22 units in one run, at load 46).
starts_entry() { # prefix entry...
  local prefix="$1" entry
  shift
  for entry in "$@"; do
    [[ "${entry}" != "${prefix}"* ]] || return 0
  done
  return 1
}
starts_entry "${PHASE_TWO_AFTER}|1|" "${ALL_BATTERIES[@]}" || {
  printf 'run-all: the second phase waits for %s, and no first-phase battery has that name\n' "${PHASE_TWO_AFTER}" >&2
  exit 2
}

for first in "${START_FIRST_ALL[@]}"; do
  starts_entry "${first}|" "${ALL_BATTERIES[@]}" || {
    printf 'run-all: START_FIRST_ALL names %s, which is not a battery\n' "${first}" >&2
    exit 2
  }
done

usage() {
  printf 'usage: %s [--list | --units | --plan] [--release] | --unit UNIT --core-receipt FILE\n' "$0" >&2
  exit 2
}
selection=dev list_only=false units_only=false plan_only=false unit="" core_receipt=""
while (( $# > 0 )); do
  case "$1" in
    --release) [[ "${selection}" == dev ]] || usage; selection=release; shift ;;
    --list) list_only=true; shift ;;
    --units) units_only=true; shift ;;
    --plan) units_only=true plan_only=true; shift ;;
    --unit)
      [[ "${selection}" == dev && "${2:-}" =~ ^([a-z][a-z0-9-]*)(@([1-9][0-9]*)of([1-9][0-9]*))?$ ]] || usage
      selection=unit unit="$2"; shift 2 ;;
    --core-receipt) [[ -n "${2:-}" ]] || usage; core_receipt="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[[ "${list_only}" == false || "${units_only}" == false ]] || usage
[[ "${selection}" != unit || ( "${list_only}" == false && "${units_only}" == false ) ]] || usage
[[ -z "${core_receipt}" || "${selection}" == unit ]] || usage

# The units of a set, as the runner on several hosts runs them.
if [[ "${units_only}" == true ]]; then
  for entry in "${ALL_BATTERIES[@]}"; do
    IFS='|' read -r name _ scope shards weight secs _ <<< "${entry}"
    [[ "${selection}" == release || "${scope}" == dev ]] || continue
    each=""
    [[ "${plan_only}" == false ]] || each=" ${weight} $(( (secs + shards - 1) / shards ))"
    if (( shards == 1 )); then
      printf '%s%s\n' "${name}" "${each}"
    else
      for (( i = 1; i <= shards; i++ )); do printf '%s@%dof%d%s\n' "${name}" "${i}" "${shards}" "${each}"; done
    fi
  done
  exit 0
fi

# The batteries of this run, as <name>|<phase>|<command>, in the table's order.
# A unit is one battery, under its unit's name, with its shard's arguments.
BATTERIES=()
unit_weight=""
for entry in "${ALL_BATTERIES[@]}"; do
  IFS='|' read -r name phase scope shards weight _ command <<< "${entry}"
  case "${selection}" in
    dev) [[ "${scope}" == dev ]] || continue ;;
    unit)
      [[ "${name}" == "${unit%%@*}" ]] || continue
      if [[ "${unit}" == *@* ]]; then
        shard="${unit#*@}"
        [[ "${shard%%of*}" -le "${shard#*of}" && "${shard#*of}" == "${shards}" ]] || {
          printf 'run-all: %s is not a unit; the table splits %s into %s\n' "${unit}" "${name}" "${shards}" >&2
          exit 2
        }
        command="${command} --shard ${shard%%of*}/${shard#*of}"
      elif (( shards != 1 )); then
        printf 'run-all: the table splits %s into %s, so its units are %s@1of%s and on\n' "${name}" "${shards}" "${name}" "${shards}" >&2
        exit 2
      fi
      # The census prints no `ok` lines; ci-verdict.sh judges a census unit,
      # a shard or the whole census, from this directory.
      [[ "${name}" != census ]] || command="${command} --out ${SAFEDEPS_TEST_LOG_DIR:-}/${unit}.out"
      name="${unit}" phase=1 unit_weight="${weight}"
      ;;
  esac
  BATTERIES+=("${name}|${phase}|${command}")
done
(( ${#BATTERIES[@]} > 0 )) || {
  printf 'run-all: no battery is named %s\n' "${unit%%@*}" >&2
  exit 2
}
if [[ "${selection}" == unit ]]; then
  # A unit's files are what the runner collects, so they go where it says.
  [[ -n "${SAFEDEPS_TEST_LOG_DIR:-}" && "${SAFEDEPS_TEST_LOG_DIR}" != *" "* ]] || {
    printf 'run-all: --unit needs SAFEDEPS_TEST_LOG_DIR, a directory with no blank in its path\n' >&2
    exit 2
  }
fi
if [[ "${list_only}" == true ]]; then
  for entry in "${BATTERIES[@]}"; do printf '%s\n' "${entry%%|*}"; done
  exit 0
fi
case "${selection}" in
  dev) run_label="development set" ;;
  release) run_label="release set" ;;
  unit) run_label="unit ${unit}" ;;
esac
selected() { starts_entry "$1|" "${BATTERIES[@]}"; }
START_FIRST=()
for first in "${START_FIRST_ALL[@]}"; do
  ! selected "${first}" || START_FIRST+=("${first}")
done

serial=false
[[ "${SAFEDEPS_TEST_SERIAL:-}" == 1 ]] && serial=true

cpus=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || printf '2')
[[ "${cpus}" =~ ^[1-9][0-9]*$ ]] || cpus=2
if [[ -n "${SAFEDEPS_TEST_JOBS:-}" ]]; then
  [[ "${SAFEDEPS_TEST_JOBS}" =~ ^[1-9][0-9]*$ ]] || {
    printf 'run-all: SAFEDEPS_TEST_JOBS must be a whole number of at least 1 (got %s)\n' "${SAFEDEPS_TEST_JOBS:0:40}" >&2
    exit 2
  }
  jobs="${SAFEDEPS_TEST_JOBS}"
else
  jobs=$(( (cpus + 1) / 2 ))
fi
# A unit runs at its weight, capped by an explicit host/user jobs limit.
if [[ -n "${unit_weight}" ]]; then
  if [[ -z "${SAFEDEPS_TEST_JOBS:-}" ]] || (( unit_weight < jobs )); then jobs="${unit_weight}"; fi
fi
# The census reads the same value, so one variable sets both.
export SAFEDEPS_TEST_JOBS="${jobs}"

if [[ -n "${SAFEDEPS_TEST_LOG_DIR:-}" ]]; then
  log_dir="${SAFEDEPS_TEST_LOG_DIR}"
  mkdir -p "${log_dir}" || { printf 'run-all: cannot create %s\n' "${log_dir}" >&2; exit 2; }
else
  tmp_base="${TMPDIR:-/tmp}"
  log_dir=$(mktemp -d "${tmp_base%/}/safedeps-test.XXXXXX") \
    || { printf 'run-all: cannot create a log directory\n' >&2; exit 2; }
fi

# A reused log directory must not hand a battery the exit status of an earlier
# run: the scheduler reads a battery's .rc file as "this one is done".
for entry in "${BATTERIES[@]}"; do
  IFS='|' read -r name _ _ <<< "${entry}"
  rm -f "${log_dir}/${name}.log" "${log_dir}/${name}.rc" "${log_dir}/${name}.secs" \
    "${log_dir}/${name}.load-start" "${log_dir}/${name}.load-end" \
    "${log_dir}/${name}.core.json" "${log_dir}/${name}.prepare.log"
done

# Preparation owns the build; units only check its receipt against the live
# binary and source. Keep preparation's exit under a different suffix from
# unit .rc files, which ci-verdict.sh counts as members of the set.
if [[ "${selection}" == unit ]]; then
  prepare_log="${log_dir}/${unit}.prepare.log"
  prepare_rc=0
  if [[ -z "${core_receipt}" ]]; then
    printf 'run-all: --unit requires --core-receipt from the host preparation\n' > "${prepare_log}"
    prepare_rc=1
  else
    bash scripts/build-core.sh --check-receipt "${core_receipt}" > "${prepare_log}" 2>&1 || prepare_rc=$?
  fi
else
  mkdir -p "${log_dir}/core-prepare" || exit 2
  core_receipt="${log_dir}/core-prepare/receipt.json"
  prepare_log="${log_dir}/core-prepare/build.log"
  prepare_rc=0
  bash scripts/build-core.sh --receipt "${core_receipt}" > "${prepare_log}" 2>&1 || prepare_rc=$?
  printf '%s\n' "${prepare_rc}" > "${log_dir}/core-prepare/exit"
fi
if (( prepare_rc != 0 )); then
  cat "${prepare_log}" >&2
  printf 'run-all: core preparation failed (exit %s); no battery started\n' "${prepare_rc}" >&2
  if [[ "${selection}" == unit ]]; then
    cp "${prepare_log}" "${log_dir}/${unit}.log"
    printf '%s\n' "${prepare_rc}" > "${log_dir}/${unit}.rc"
  fi
  exit 1
fi
printf '# core receipt %s\n' "${core_receipt}"
export SAFEDEPS_TEST_CORE_RECEIPT="${core_receipt}" SAFEDEPS_TEST_LOG_DIR="${log_dir}"

# The load averages, without the platform's framing (macOS prints "load
# averages: a b c", Linux "load average: a, b, c").
load_now() { uptime | sed -E 's/.*load averages?: *//; s/,//g'; }

# Runs one battery into its log and records rc, seconds and load.
run_one() {
  local name="$1" command="$2" start rc=0
  printf '%s\n' "$(load_now)" > "${log_dir}/${name}.load-start"
  start=$(date +%s)
  # This is the checked identity every battery of the run was handed.
  if ! cp "${core_receipt}" "${log_dir}/${name}.core.json"; then
    printf 'run-all: cannot record the prepared core identity\n' > "${log_dir}/${name}.log"
    printf '1\n' > "${log_dir}/${name}.rc"
    return
  fi
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
printf '# safedeps tests, %s (%d batteries): %s, logs in %s, load %s, %s CPUs, %s jobs\n' \
  "${run_label}" "${#BATTERIES[@]}" \
  "$([[ "${serial}" == true ]] && printf serial || printf parallel)" "${log_dir}" "$(load_now)" \
  "${cpus}" "${jobs}"

if [[ "${serial}" == true ]]; then
  for entry in "${BATTERIES[@]}"; do
    IFS='|' read -r name _ command <<< "${entry}"
    run_one "${name}" "${command}" &
    pids=("$!")
    wait "${pids[0]}"
  done
else
  # Start order: START_FIRST, then the rest in the order of BATTERIES.
  pending=(${START_FIRST[@]+"${START_FIRST[@]}"})
  for entry in "${BATTERIES[@]}"; do
    IFS='|' read -r name _ _ <<< "${entry}"
    case " ${START_FIRST[*]-} " in *" ${name} "*) ;; *) pending+=("${name}") ;; esac
  done
  # A battery is done when its .rc file exists: run_one writes it last. bash
  # 3.2 (macOS) has no `wait -n`, so the slots are polled once a second.
  running=()
  gate_open=false
  selected "${PHASE_TWO_AFTER}" || gate_open=true
  while (( ${#pending[@]} > 0 || ${#running[@]} > 0 )); do
    still=()
    for name in ${running[@]+"${running[@]}"}; do
      if [[ -e "${log_dir}/${name}.rc" ]]; then
        [[ "${name}" != "${PHASE_TWO_AFTER}" ]] || gate_open=true
      else
        still+=("${name}")
      fi
    done
    running=(${still[@]+"${still[@]}"})
    while (( ${#running[@]} < jobs )); do
      pick=""
      left=()
      for name in ${pending[@]+"${pending[@]}"}; do
        entry=$(printf '%s\n' "${BATTERIES[@]}" | grep "^${name}|")
        IFS='|' read -r _ battery_phase command <<< "${entry}"
        if [[ -z "${pick}" ]] && { [[ "${battery_phase}" == 1 ]] || [[ "${gate_open}" == true ]]; }; then
          pick="${name}"
          pick_command="${command}"
        else
          left+=("${name}")
        fi
      done
      [[ -n "${pick}" ]] || break
      pending=(${left[@]+"${left[@]}"})
      run_one "${pick}" "${pick_command}" &
      pids+=("$!")
      running+=("${pick}")
    done
    (( ${#pending[@]} > 0 || ${#running[@]} > 0 )) || break
    sleep 1
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
  # It also fails when it printed no `ok` line: an empty log with exit status 0
  # passed both. Every battery prints `ok` lines but the census, which judges
  # itself in its exit status (ci-verdict.sh holds the host runner's units to
  # the same floor).
  if [[ "${rc}" != 0 || "${not_ok:-0}" != 0 ]] || [[ "${name%%@*}" != census && ! "${ok:-0}" =~ ^[1-9] ]]; then
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
