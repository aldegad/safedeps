#!/usr/bin/env bash
# safedeps: the host side of scripts/ci/run-on-hosts.sh.
#
# The coordinator ships a tree into RUN, a directory of its own on the host, and
# drives it through this script with short ssh calls. No unit lives inside an
# ssh session. A link to one of our hosts once dropped for fifteen minutes while
# its jobs ran on, and a unit tied to its session would have died with it. So a
# unit starts detached and writes its result to files, and the coordinator
# reads the files.
#
#   remote.sh hold RUN [K]    Runs inside the host's queue (slot.sh,
#                             vm-locked.sh), so the run takes a slot like any
#                             other suite; K numbers the slot when the run
#                             takes more than one. Writes RUN/held-K, then
#                             waits. It ends, and frees the slot, when
#                             RUN/release appears or when the coordinator has
#                             not polled for HEARTBEAT_MINUTES (it touches
#                             RUN/heartbeat on every status call), so a
#                             coordinator that died does not keep the slot.
#                             In that case it first stops the run's units and
#                             waits for them, so none runs on outside the
#                             queue.
#   remote.sh prepare RUN JOBS
#                             Starts one detached build after the coordinator
#                             has acquired the queue slots. Never retries a
#                             build in this run. Picks the run's locale first
#                             and writes it to out/locale, and how it was
#                             picked to out/locale.pick; the build and every
#                             unit run under it. Writes out/core-prepare's
#                             build.log, build.locale, receipt.json and exit
#                             before units.
#   remote.sh start RUN UNIT  Requires successful preparation, then starts one
#                             unit detached and returns. The unit
#                             writes RUN's name into out/<unit>.run, and stops
#                             itself when the coordinator has not polled for
#                             HEARTBEAT_MINUTES: a coordinator killed outright,
#                             or one that gave this host up as dead, no longer
#                             polls, and nothing else would stop the unit.
#   remote.sh status RUN      Touches the heartbeat and prints one line per unit
#                             started: `unit <name> done <rc>`, `unit <name>
#                             running`, or `unit <name> lost` (its process is
#                             gone and it wrote no exit status). Then `held
#                             <how many slots are held>` and `load <1m 5m 15m>`.
#   remote.sh stop RUN [UNIT] Signals each running unit's process and its
#                             children, one pid at a time, never a process
#                             group, and releases the hold: each queue waiter
#                             (RUN/queue-K.pid) is signalled the same way, so a
#                             slot still waited for is given up at once. With
#                             UNIT, stops that unit alone and keeps the hold.
#
# RUN holds tree/ (the shipped tree), path (a PATH prefix the coordinator
# writes from the host file), out/ (each unit's .log, .rc, .secs, .load-start
# and .load-end, written by run-all.sh --unit, and its .pid and .run, written
# here, the LANG and LC_* it started under in .locale, the run's locale in
# locale, and how it was picked in locale.pick), held-K, queue-K.pid, heartbeat
# and release.
set -uo pipefail

HEARTBEAT_MINUTES=10
HOLD_POLL_SECONDS=2
WATCH_SECONDS=10
# How long a hold whose coordinator is gone waits for the units it stopped.
STOP_WAIT_SECONDS=60

die() { printf 'remote: %s\n' "$1" >&2; exit 2; }

action="${1:-}"
RUN="${2:-}"
[[ -n "${RUN}" && -d "${RUN}/tree" ]] || die "usage: remote.sh hold|prepare|start|status|stop RUN [UNIT]; RUN must hold the shipped tree"
# Absolute from here on: `run` changes directory, and a unit's process is
# recognized by the path in its arguments.
RUN=$(cd "${RUN}" && pwd) || die "cannot enter ${RUN}"
OUT="${RUN}/out"
mkdir -p "${OUT}" || die "cannot create ${OUT}"
PREP="${OUT}/core-prepare"

host_path() {
  local prefix=""
  [[ ! -f "${RUN}/path" ]] || prefix=$(cat "${RUN}/path")
  prefix="${prefix//\$HOME/${HOME}}"
  [[ -z "${prefix}" ]] || PATH="${prefix}:${PATH}"
  export PATH
}

# The locale of the run's build and units is the host's to give. The
# coordinator sends none (scripts/ci/run-on-hosts.sh). ssh used to carry the
# caller's LANG, and on a host that did not have that locale perl (shasum)
# printed a warning ahead of the output a row read. The session's own default
# is no better, since nothing says the host has it either. So the host's list
# decides.
#
# Every name `locale -a` lists is judged by what `locale charmap` answers with
# the name as LC_ALL, not by its spelling: a UTF-8 locale may be listed as
# sr_RS.UTF-8@latin, de_DE.utf8 or en_IN. An answer is clean when it is one
# line that is not empty, with nothing on standard error and exit status 0.
# Its codeset is the line up to an @. A name is taken when its answer is clean,
# the codeset is UTF-8 and the run can carry the name (LOCALE_NAME, below).
# macOS answers with what follows the dot in the name: UTF-8@latin for
# sr_RS.UTF-8@latin, and an empty line for en_NZ. It answers US-ASCII, with no
# warning, for a name it cannot load.
#
# en_US.UTF-8 and C.UTF-8 come first when the host lists them (en_US.utf8 and
# C.utf8 are glibc's spellings): every macOS has en_US.UTF-8 and only recent
# ones have C.UTF-8, so the hosts of one platform run one locale. The other
# names follow in the order `locale -a` gives them. A `locale -a` that fails is
# not an empty list, and the preparation fails with it.
LOCALE_PREFERRED=(en_US.UTF-8 en_US.utf8 C.UTF-8 C.utf8)

# The characters of a locale name the run carries. The name goes into
# out/locale, into LANG and into run.txt, and use_locale reads it back.
LOCALE_NAME='^[A-Za-z0-9_.@-]+$'

# Whether a codeset is UTF-8: UTF-8 or utf8 in any case, up to an @.
utf8_codeset() {
  case "${1%%@*}" in
    [Uu][Tt][Ff]-8 | [Uu][Tt][Ff]8) return 0 ;;
    *) return 1 ;;
  esac
}

# pick_locale ERR: prints the run's locale, then one line that says how it was
# picked, in one of three forms (N names listed, K of them examined):
#
#   picked NAME (locale charmap: ANSWER), after examining K of the N names locale -a lists
#   C, since no name is UTF-8: all N names locale -a lists were examined, each
#     answered another charmap, and none says UTF-8
#   C, since none fit: all N names locale -a lists were examined and none was
#     taken; S say UTF-8 but answered another charmap, U gave no single clean
#     answer, X answered UTF-8 but have a name the run does not carry
#
# The last form is for a host that may have a UTF-8 locale the run did not
# take, so that C is not read as a host without one. A name says UTF-8 when
# the part after its dot is a UTF-8 codeset. That reading picks nothing. It
# only keeps a name that says UTF-8 and was answered with US-ASCII, as macOS
# answers a name it cannot load, from being counted as no UTF-8. ERR is a file
# for each answer's standard error.
pick_locale() {
  local err="$1" listed name answer seen=$'\n' total=0 examined=0 says=0 unclear=0 uncarried=0
  listed=$(locale -a) || return 1
  while IFS= read -r name; do
    [[ -n "${name}" && "${seen}" != *$'\n'"${name}"$'\n'* ]] || continue
    seen+="${name}"$'\n'
    total=$(( total + 1 ))
  done <<< "${listed}"
  seen=$'\n'
  while IFS= read -r name; do
    [[ -n "${name}" && "${seen}" != *$'\n'"${name}"$'\n'* ]] || continue
    seen+="${name}"$'\n'
    examined=$(( examined + 1 ))
    if ! answer=$(LC_ALL="${name}" locale charmap 2>"${err}") \
      || [[ -s "${err}" || -z "${answer}" || "${answer}" == *$'\n'* ]]; then
      unclear=$(( unclear + 1 ))
    elif ! utf8_codeset "${answer}"; then
      if [[ "${name}" == *.* ]] && utf8_codeset "${name#*.}"; then
        says=$(( says + 1 ))
      fi
    elif [[ "${name}" =~ ${LOCALE_NAME} ]]; then
      printf '%s\npicked %s (locale charmap: %s), after examining %s of the %s names locale -a lists\n' \
        "${name}" "${name}" "${answer}" "${examined}" "${total}"
      return 0
    else
      uncarried=$(( uncarried + 1 ))
    fi
  done < <(for name in "${LOCALE_PREFERRED[@]}"; do
             grep -qxF -- "${name}" <<< "${listed}" && printf '%s\n' "${name}"
           done
           printf '%s\n' "${listed}")
  if (( says + unclear + uncarried == 0 )); then
    printf 'C\nC, since no name is UTF-8: all %s names locale -a lists were examined, each answered another charmap, and none says UTF-8\n' \
      "${total}"
  else
    printf 'C\nC, since none fit: all %s names locale -a lists were examined and none was taken; %s say UTF-8 but answered another charmap, %s gave no single clean answer, %s answered UTF-8 but have a name the run does not carry\n' \
      "${total}" "${says}" "${unclear}" "${uncarried}"
  fi
}

# Puts the run's locale in place for the build or a unit: LANG alone, so a row
# that sets a category of its own still gets it, and no LC_* the session had.
use_locale() {
  local value
  value=$(cat "${OUT}/locale") || die "cannot read the run's locale"
  [[ "${value}" =~ ${LOCALE_NAME} ]] || die "not a locale name: ${value:0:60}"
  unset "${!LC_@}"
  export LANG="${value}"
}

# The LANG and LC_* a process has, one per line. The build and each unit write
# theirs as they start, so run.txt says what they ran under, not only what the
# host picked.
locale_env() { env | grep -E '^(LANG|LC_[A-Za-z_]*)=' | LC_ALL=C sort; }

load_now() { uptime | sed -E 's/.*load averages?: *//; s/,//g'; }

# A pid is alive and still this run's `remote.sh ACTION`: a pid the system
# handed to another process since does not count. The run directory is named
# by its last component, which mktemp made unique on this host, because the
# coordinator starts the queue waiters with a path relative to the home
# directory and the units are started here with an absolute one. Matched on
# the absolute path, a waiter that never got its slot was never signalled, and
# it took its turn in the queue after the run had ended (measured).
run_process() { # pid action
  [[ "$1" =~ ^[0-9]+$ ]] || return 1
  ps -o args= -p "$1" 2>/dev/null | grep -qF -- "/${RUN##*/}/tree/scripts/ci/remote.sh $2"
}
unit_alive() { run_process "$1" run; }

# Signals a process and every process below it, children first, by pid.
signal_tree() {
  local signal="$1" pid="$2" child
  for child in $(pgrep -P "${pid}" 2>/dev/null); do
    signal_tree "${signal}" "${child}"
  done
  kill "-${signal}" "${pid}" 2>/dev/null || true
}

# The coordinator touches RUN/heartbeat on every status call. A heartbeat
# that is older than HEARTBEAT_MINUTES, or gone, means nothing polls this run.
heartbeat_stale() {
  [[ -z "$(find "${RUN}/heartbeat" -mmin "-${HEARTBEAT_MINUTES}" 2>/dev/null)" ]]
}

# Stops each running unit of the run, or UNIT alone, and prints what it stopped.
stop_units() {
  local only="${1:-}" pid_file unit pid
  if [[ -z "${only}" && -f "${RUN}/prepare.pid" && ! -f "${PREP}/exit" ]]; then
    pid=$(cat "${RUN}/prepare.pid")
    if run_process "${pid}" prepare-run; then
      signal_tree TERM "${pid}"
      printf 'stopped core preparation (pid %s)\n' "${pid}"
    fi
  fi
  for pid_file in "${OUT}"/*.pid; do
    [[ -e "${pid_file}" ]] || continue
    unit=$(basename "${pid_file}" .pid)
    [[ -z "${only}" || "${unit}" == "${only}" ]] || continue
    [[ ! -f "${OUT}/${unit}.rc" ]] || continue
    pid=$(cat "${pid_file}")
    unit_alive "${pid}" || continue
    signal_tree TERM "${pid}"
    printf 'stopped %s (pid %s)\n' "${unit}" "${pid}"
  done
}

# True while any unit of the run is alive.
units_alive() {
  local pid_file
  if [[ -f "${RUN}/prepare.pid" ]]; then
    run_process "$(cat "${RUN}/prepare.pid")" prepare-run && return 0
  fi
  for pid_file in "${OUT}"/*.pid; do
    [[ -e "${pid_file}" ]] || continue
    unit_alive "$(cat "${pid_file}")" && return 0
  done
  return 1
}

# Both detached jobs retain their heartbeat watch while their child runs.
watch_child() { # pid log
  local child="$1" log="$2"
  while kill -0 "${child}" 2>/dev/null; do
    if heartbeat_stale; then
      printf 'remote: no status call for %s minutes; stopping the child\n' "${HEARTBEAT_MINUTES}" >> "${log}"
      signal_tree TERM "${child}"
      wait "${child}" 2>/dev/null
      return 1
    fi
    sleep "${WATCH_SECONDS}"
  done
  wait "${child}"
}

case "${action}" in
  hold)
    k="${3:-1}"
    [[ "${k}" =~ ^[1-9]$ ]] || die "a hold is numbered 1 to 9 (got ${k:0:20})"
    : > "${RUN}/heartbeat"
    printf '%s %s\n' "$$" "$(date +%s)" > "${RUN}/held-${k}"
    while [[ ! -e "${RUN}/release" && -e "${RUN}/held-${k}" ]]; do
      if heartbeat_stale; then
        {
          printf 'remote: no status call for %s minutes; the coordinator is gone, so the units are stopped and the slot is freed\n' \
            "${HEARTBEAT_MINUTES}"
          stop_units
        } >> "${RUN}/hold.log"
        # The slot is freed once the units are gone, so none of them runs on
        # outside the queue; a unit that outlives the wait is named.
        waited=0
        while units_alive && (( waited < STOP_WAIT_SECONDS )); do
          sleep "${HOLD_POLL_SECONDS}"
          waited=$(( waited + HOLD_POLL_SECONDS ))
        done
        ! units_alive || printf 'remote: a unit was still running %ss after it was stopped; the slot is freed anyway\n' \
          "${STOP_WAIT_SECONDS}" >> "${RUN}/hold.log"
        break
      fi
      sleep "${HOLD_POLL_SECONDS}"
    done
    rm -f "${RUN}/held-${k}"
    ;;
  prepare)
    jobs="${3:-}"
    [[ "${jobs}" =~ ^[1-9][0-9]*$ ]] || die "prepare needs the host's jobs limit"
    [[ ! -e "${RUN}/release" ]] || die "this run has been released"
    # The directory is the single attempt claim. A repeated request observes
    # this attempt, including a failed/lost one, and never rebuilds underneath
    # units. The status call reports the result or a missing process.
    if ! mkdir "${PREP}" 2>/dev/null; then
      [[ -d "${PREP}" ]] || die "cannot claim core preparation"
      printf 'preparation already requested\n'
      exit 0
    fi
    printf '%s\n' "${jobs}" > "${RUN}/jobs" || die "cannot record the jobs limit"
    # Picked once, here, before the build; the build and the units read it.
    pick=$(pick_locale "${PREP}/charmap.err") || die "cannot list the host's locales: locale -a failed"
    rm -f "${PREP}/charmap.err"
    printf '%s\n' "${pick%%$'\n'*}" > "${OUT}/locale" || die "cannot record the run's locale"
    printf '%s\n' "${pick#*$'\n'}" > "${OUT}/locale.pick" || die "cannot record how the run's locale was picked"
    nohup nice -n 10 bash "${RUN}/tree/scripts/ci/remote.sh" prepare-run "${RUN}" \
      </dev/null >"${PREP}/runner.log" 2>&1 &
    printf '%s\n' "$!" > "${RUN}/prepare.pid"
    ;;
  prepare-run)
    host_path
    use_locale
    cd "${RUN}/tree" || exit 2
    locale_env > "${PREP}/build.locale"
    load_now > "${PREP}/load-start"
    ps -o ni= -p "$$" > "${PREP}/nice"
    start=$(date +%s)
    bash scripts/build-core.sh --receipt "${PREP}/receipt.json" >> "${PREP}/build.log" 2>&1 &
    rc=0
    watch_child "$!" "${PREP}/build.log" || rc=$?
    printf '%s\n' "$(( $(date +%s) - start ))" > "${PREP}/secs"
    load_now > "${PREP}/load-end"
    # `exit` is published last; it is not a unit .rc file.
    printf '%s\n' "${rc}" > "${PREP}/exit"
    ;;
  start)
    unit="${3:-}"
    [[ "${unit}" =~ ^[a-z][a-z0-9-]*(@[1-9][0-9]*of[1-9][0-9]*)?$ ]] || die "not a unit name: ${unit:0:60}"
    [[ "$(cat "${PREP}/exit" 2>/dev/null)" == 0 && -f "${PREP}/receipt.json" ]] \
      || die "core preparation did not succeed; no unit started"
    [[ ! -e "${RUN}/release" ]] || die "this run has been released"
    [[ ! -e "${OUT}/${unit}.pid" ]] || die "unit ${unit} was already started here"
    # The run directory's name, which the coordinator created exclusively on
    # this host: ci-verdict.sh takes a unit's files as this run's only when
    # they name it.
    printf '%s\n' "${RUN##*/}" > "${OUT}/${unit}.run" || die "cannot write ${OUT}/${unit}.run"
    nohup nice -n 10 bash "${RUN}/tree/scripts/ci/remote.sh" run "${RUN}" "${unit}" </dev/null >/dev/null 2>&1 &
    printf '%s\n' "$!" > "${OUT}/${unit}.pid"
    ;;
  run)
    # The detached unit itself (started by `start`, never by the coordinator).
    unit="${3:-}"
    jobs=$(cat "${RUN}/jobs") || die "cannot read the host's jobs limit"
    [[ "${jobs}" =~ ^[1-9][0-9]*$ ]] || die "invalid host jobs limit"
    host_path
    use_locale
    cd "${RUN}/tree" || exit 2
    locale_env > "${OUT}/${unit}.locale"
    # Appended, not truncated: the watch below writes to the same file, and
    # run-all.sh writing at its own offset overwrote that line (measured).
    ps -o ni= -p "$$" > "${OUT}/${unit}.nice"
    SAFEDEPS_TEST_JOBS="${jobs}" SAFEDEPS_TEST_LOG_DIR="${OUT}" \
      bash scripts/test/run-all.sh --unit "${unit}" --core-receipt "${PREP}/receipt.json" >> "${OUT}/${unit}.runner" 2>&1 &
    child=$!
    # The unit watches the heartbeat itself. A coordinator killed outright
    # (SIGKILL runs no trap) or one that gave this host up as dead sends no
    # stop and no longer polls; the hold would stop the unit, but the hold may
    # be gone, and then nothing else would.
    watch_child "${child}" "${OUT}/${unit}.runner"
    ;;
  status)
    : > "${RUN}/heartbeat"
    if [[ -f "${PREP}/exit" ]]; then
      printf 'prepare done %s\n' "$(cat "${PREP}/exit")"
    elif [[ -d "${PREP}" ]]; then
      if run_process "$(cat "${RUN}/prepare.pid" 2>/dev/null)" prepare-run; then
        printf 'prepare running\n'
      else
        printf 'prepare lost\n'
      fi
    else
      printf 'prepare pending\n'
    fi
    for pid_file in "${OUT}"/*.pid; do
      [[ -e "${pid_file}" ]] || continue
      unit=$(basename "${pid_file}" .pid)
      if [[ -f "${OUT}/${unit}.rc" ]]; then
        printf 'unit %s done %s\n' "${unit}" "$(cat "${OUT}/${unit}.rc")"
      elif unit_alive "$(cat "${pid_file}")"; then
        printf 'unit %s running\n' "${unit}"
      else
        printf 'unit %s lost\n' "${unit}"
      fi
    done
    held=0
    for f in "${RUN}"/held-*; do [[ -e "${f}" ]] && held=$((held + 1)); done
    printf 'held %s\n' "${held}"
    printf 'load %s\n' "$(load_now)"
    ;;
  stop)
    only="${3:-}"
    stop_units "${only}"
    if [[ -z "${only}" ]]; then
      : > "${RUN}/release"
      for pid_file in "${RUN}"/queue-*.pid; do
        [[ -e "${pid_file}" ]] || continue
        pid=$(cat "${pid_file}")
        run_process "${pid}" hold && signal_tree TERM "${pid}"
      done
    fi
    ;;
  *) die "unknown action ${action:0:40}" ;;
esac
exit 0
