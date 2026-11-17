#!/usr/bin/env bash
# The watch lock: one exclusive lock per state root, held for the life of the
# process that took it.
#
# Every writer of the watch state takes it: the scheduled scan, a scan run by
# hand, a scan of one root after a repair, the consumer's claim and ack, and the
# ledger re-check, which revokes approvals (lib/watch/watch.sh `locked`). A writer that finds it held does not
# wait and does not touch the state: it answers busy and exits
# SAFEDEPS_WATCH_BUSY_EXIT, which a caller can retry.
#
# The primitive is flock(2) on fd 9, opened in append mode on
# ${SAFEDEPS_HOME}/watch/lock. The file is never removed or replaced, so every
# writer locks the same inode. The lock belongs to the open file description:
# it ends when the last process holding fd 9 exits, however it exits, and
# nothing else ends it. No age, no pid and no lease takes it from a live
# holder. A child that inherits fd 9 holds the lock as long as it lives, so a
# command this process starts that may outlive it runs with `9>&-`.
#
#   macOS  /usr/bin/perl, flock(2) on the inherited fd 9 (LOCK_EX|LOCK_NB).
#          lockf(1) takes an fd only on some macOS releases and is missing
#          from others, so every macOS takes the one path perl gives.
#   Linux  flock -n -E 75 9           (util-linux flock(1))
#
# Any other system, or one without the tool, is an error, not a run without the
# lock.

SAFEDEPS_WATCH_BUSY_EXIT=75
SAFEDEPS_WATCH_LOCK_ERROR_EXIT=70
SAFEDEPS_WATCH_LOCK_TAKEN=""

safedeps_watch_dir() {
  printf '%s/watch' "${SAFEDEPS_HOME}"
}

# Takes the lock or says why not. 0 held, SAFEDEPS_WATCH_BUSY_EXIT busy,
# SAFEDEPS_WATCH_LOCK_ERROR_EXIT no lock to take. A process that holds it
# already holds it.
safedeps_watch_lock_acquire() {
  [[ -n "${SAFEDEPS_WATCH_LOCK_TAKEN}" ]] && return 0
  local dir rc=0
  dir=$(safedeps_watch_dir)
  ( umask 077; mkdir -p "${dir}" ) || return "${SAFEDEPS_WATCH_LOCK_ERROR_EXIT}"
  exec 9>>"${dir}/lock" || return "${SAFEDEPS_WATCH_LOCK_ERROR_EXIT}"
  case "$(uname -s)" in
    Darwin)
      # The lock belongs to the open file description perl shares with this
      # shell, so it outlives perl and ends when this process's fd 9 closes.
      if [[ -x /usr/bin/perl ]]; then
        /usr/bin/perl -MFcntl=:flock -e '
          open(my $fd, ">>&=", 9) or exit $ARGV[1];
          exit 0 if flock($fd, LOCK_EX | LOCK_NB);
          exit($!{EWOULDBLOCK} ? $ARGV[0] : $ARGV[1]);' \
          "${SAFEDEPS_WATCH_BUSY_EXIT}" "${SAFEDEPS_WATCH_LOCK_ERROR_EXIT}" || rc=$?
      else
        rc=127
      fi
      ;;
    Linux)
      if command -v flock >/dev/null 2>&1; then
        flock -n -E "${SAFEDEPS_WATCH_BUSY_EXIT}" 9 || rc=$?
      else
        rc=127
      fi
      ;;
    *) rc=127 ;;
  esac
  case "${rc}" in
    0) SAFEDEPS_WATCH_LOCK_TAKEN=1; return 0 ;;
    "${SAFEDEPS_WATCH_BUSY_EXIT}") exec 9>&-; return "${SAFEDEPS_WATCH_BUSY_EXIT}" ;;
    *) exec 9>&-; return "${SAFEDEPS_WATCH_LOCK_ERROR_EXIT}" ;;
  esac
}

# What a writer that could not take the lock prints. busy is no result: not a
# check that passed and not a finding.
safedeps_watch_lock_refusal_json() {
  local command="$1" rc="$2"
  local reason="busy"
  [[ "${rc}" == "${SAFEDEPS_WATCH_BUSY_EXIT}" ]] || reason="lock_unavailable"
  jq -nc --arg command "${command}" --arg reason "${reason}" --arg lock "$(safedeps_watch_dir)/lock" \
    '{command:$command, busy:($reason == "busy"), error:$reason, lock:$lock}'
}
