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
#   remote.sh start RUN UNIT  Starts one unit detached and returns. The unit
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
# here), held-K, queue-K.pid, heartbeat and release.
set -uo pipefail

HEARTBEAT_MINUTES=10
HOLD_POLL_SECONDS=2
WATCH_SECONDS=10
# How long a hold whose coordinator is gone waits for the units it stopped.
STOP_WAIT_SECONDS=60

die() { printf 'remote: %s\n' "$1" >&2; exit 2; }

action="${1:-}"
RUN="${2:-}"
[[ -n "${RUN}" && -d "${RUN}/tree" ]] || die "usage: remote.sh hold|start|status|stop RUN [UNIT]; RUN must hold the shipped tree"
# Absolute from here on: `run` changes directory, and a unit's process is
# recognized by the path in its arguments.
RUN=$(cd "${RUN}" && pwd) || die "cannot enter ${RUN}"
OUT="${RUN}/out"
mkdir -p "${OUT}" || die "cannot create ${OUT}"

load_now() { uptime | sed -E 's/.*load averages?: *//; s/,//g'; }

# A unit's pid is alive and still this run's unit: a pid the system handed to
# another process since does not count.
unit_alive() {
  local pid="$1"
  [[ "${pid}" =~ ^[0-9]+$ ]] || return 1
  ps -o args= -p "${pid}" 2>/dev/null | grep -qF -- "${RUN}/tree/scripts/ci/remote.sh run"
}

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
  for pid_file in "${OUT}"/*.pid; do
    [[ -e "${pid_file}" ]] || continue
    unit_alive "$(cat "${pid_file}")" && return 0
  done
  return 1
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
  start)
    unit="${3:-}"
    [[ "${unit}" =~ ^[a-z][a-z0-9-]*(@[1-9][0-9]*of[1-9][0-9]*)?$ ]] || die "not a unit name: ${unit:0:60}"
    [[ ! -e "${OUT}/${unit}.pid" ]] || die "unit ${unit} was already started here"
    # The run directory's name, which the coordinator created exclusively on
    # this host: ci-verdict.sh takes a unit's files as this run's only when
    # they name it.
    printf '%s\n' "${RUN##*/}" > "${OUT}/${unit}.run" || die "cannot write ${OUT}/${unit}.run"
    nohup bash "${RUN}/tree/scripts/ci/remote.sh" run "${RUN}" "${unit}" </dev/null >/dev/null 2>&1 &
    printf '%s\n' "$!" > "${OUT}/${unit}.pid"
    ;;
  run)
    # The detached unit itself (started by `start`, never by the coordinator).
    unit="${3:-}"
    prefix=""
    [[ ! -f "${RUN}/path" ]] || prefix=$(cat "${RUN}/path")
    # The host file writes the prefix for any host, so it may say $HOME.
    prefix="${prefix//\$HOME/${HOME}}"
    [[ -z "${prefix}" ]] || PATH="${prefix}:${PATH}"
    export PATH
    cd "${RUN}/tree" || exit 2
    # Appended, not truncated: the watch below writes to the same file, and
    # run-all.sh writing at its own offset overwrote that line (measured).
    SAFEDEPS_TEST_LOG_DIR="${OUT}" bash scripts/test/run-all.sh --unit "${unit}" >> "${OUT}/${unit}.runner" 2>&1 &
    child=$!
    # The unit watches the heartbeat itself. A coordinator killed outright
    # (SIGKILL runs no trap) or one that gave this host up as dead sends no
    # stop and no longer polls; the hold would stop the unit, but the hold may
    # be gone, and then nothing else would.
    while kill -0 "${child}" 2>/dev/null; do
      if heartbeat_stale; then
        printf 'remote: no status call for %s minutes; the coordinator is gone, so the unit stops itself\n' \
          "${HEARTBEAT_MINUTES}" >> "${OUT}/${unit}.runner"
        signal_tree TERM "${child}"
        break
      fi
      sleep "${WATCH_SECONDS}"
    done
    wait "${child}"
    ;;
  status)
    : > "${RUN}/heartbeat"
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
        [[ "${pid}" =~ ^[0-9]+$ ]] && ps -o args= -p "${pid}" 2>/dev/null | grep -qF -- "${RUN}/tree/scripts/ci/remote.sh hold" \
          && signal_tree TERM "${pid}"
      done
    fi
    ;;
  *) die "unknown action ${action:0:40}" ;;
esac
exit 0
