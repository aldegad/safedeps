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
#   remote.sh hold RUN        Runs inside the host's queue (slot.sh,
#                             vm-locked.sh), so the run takes a slot like any
#                             other suite. Writes RUN/held, then waits. It ends,
#                             and frees the slot, when RUN/release appears or
#                             when the coordinator has not polled for
#                             HEARTBEAT_MINUTES (it touches RUN/heartbeat on
#                             every status call), so a coordinator that died
#                             does not keep the slot.
#   remote.sh start RUN UNIT  Starts one unit detached and returns.
#   remote.sh status RUN      Touches the heartbeat and prints one line per unit
#                             started: `unit <name> done <rc>`, `unit <name>
#                             running`, or `unit <name> lost` (its process is
#                             gone and it wrote no exit status). Then `held
#                             yes|no` and `load <1m 5m 15m>`.
#   remote.sh stop RUN [UNIT] Signals each running unit's process and its
#                             children, one pid at a time, never a process
#                             group, and releases the hold. With UNIT, stops
#                             that unit alone and keeps the hold.
#
# RUN holds tree/ (the shipped tree), path (a PATH prefix the coordinator
# writes from the host file), out/ (each unit's .log, .rc, .secs, .load-start,
# .load-end and .pid, written by run-all.sh --unit), held, heartbeat and
# release.
set -uo pipefail

HEARTBEAT_MINUTES=10
HOLD_POLL_SECONDS=2

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

case "${action}" in
  hold)
    : > "${RUN}/heartbeat"
    printf '%s %s\n' "$$" "$(date +%s)" > "${RUN}/held"
    while [[ ! -e "${RUN}/release" && -e "${RUN}/held" ]]; do
      if [[ -z "$(find "${RUN}/heartbeat" -mmin "-${HEARTBEAT_MINUTES}" 2>/dev/null)" ]]; then
        printf 'remote: no status call for %s minutes; the coordinator is gone, so the slot is freed\n' \
          "${HEARTBEAT_MINUTES}" >> "${RUN}/hold.log"
        break
      fi
      sleep "${HOLD_POLL_SECONDS}"
    done
    rm -f "${RUN}/held"
    ;;
  start)
    unit="${3:-}"
    [[ "${unit}" =~ ^[a-z][a-z0-9-]*(@[1-9][0-9]*of[1-9][0-9]*)?$ ]] || die "not a unit name: ${unit:0:60}"
    [[ ! -e "${OUT}/${unit}.pid" ]] || die "unit ${unit} was already started here"
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
    SAFEDEPS_TEST_LOG_DIR="${OUT}" bash scripts/test/run-all.sh --unit "${unit}" > "${OUT}/${unit}.runner" 2>&1
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
    if [[ -e "${RUN}/held" ]]; then printf 'held yes\n'; else printf 'held no\n'; fi
    printf 'load %s\n' "$(load_now)"
    ;;
  stop)
    only="${3:-}"
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
    [[ -n "${only}" ]] || : > "${RUN}/release"
    ;;
  *) die "unknown action ${action:0:40}" ;;
esac
exit 0
