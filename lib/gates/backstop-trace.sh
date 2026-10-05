#!/usr/bin/env bash
# What the pre-guard and the post hook both read to tell whether a command the
# pre-guard did not read as an install left a trace in the project's node tree
# (the backstop's trace check). The pre-guard writes an entry just before the
# command runs, and the post hook of the same call reads it. Both read files
# with these functions, so the two cannot read one file two ways.
#
# The pre-guard sources this only when it can, and without it writes no entry,
# which the post hook counts as a trace: the backstop then judges the command
# as it did before entries existed.

# The entry of one tool call is <dir>/id-<tool_use_id> (safedeps_call_base),
# without an extension. A call whose input names no tool_use_id, or names one
# that is not a plain word, gets no entry: nothing else ties the pre-guard's
# entry to this call's post hook rather than another's.
# shellcheck source=./call-id.sh
source "${BASH_SOURCE[0]%/*}/call-id.sh"

# stat prints a time at the resolution the filesystem keeps only with its own
# flags: GNU `-c %y`/`%z`, BSD `-f %Fm`/`%Fc`. GNU goes first, because on Linux
# `stat -f` means --file-system and prints something else. Decided once.
SAFEDEPS_STAT_FLAVOR=""
safedeps_stat_flavor() {
  if [[ -z "${SAFEDEPS_STAT_FLAVOR}" ]]; then
    if stat -c %y / >/dev/null 2>&1; then
      SAFEDEPS_STAT_FLAVOR=gnu
    else
      SAFEDEPS_STAT_FLAVOR=bsd
    fi
  fi
}

# safedeps_file_clock <file> <m|c> [follow]: the file's modification (m) or
# status change (c) time as stat prints it at full resolution, of the path
# itself or, with follow, of what a symbolic link names. Nothing when stat
# fails. The text is compared only with text this function printed.
safedeps_file_clock() {
  local field
  safedeps_stat_flavor
  if [[ "${SAFEDEPS_STAT_FLAVOR}" == gnu ]]; then
    [[ "$2" == m ]] && field=%y || field=%z
    if [[ "${3:-}" == follow ]]; then
      stat -L -c "${field}" -- "$1" 2>/dev/null
    else
      stat -c "${field}" -- "$1" 2>/dev/null
    fi
  else
    [[ "$2" == m ]] && field=%Fm || field=%Fc
    if [[ "${3:-}" == follow ]]; then
      stat -L -f "${field}" -- "$1" 2>/dev/null
    else
      stat -f "${field}" -- "$1" 2>/dev/null
    fi
  fi
}

# What the trace check records of an npm lockfile or node_modules, as one line
# each: the path's own value and, after a bar, the value of what it names. For
# a path that is not a symbolic link the two are the same. A link's own values
# alone said nothing of a write through it: `printf > package-lock.json` into a
# linked lockfile changes the target's status change time and not the link's
# (lumi r2 S1). The link's own values stay, so a link pointed somewhere else is
# a trace too. Nothing when the path does not exist, or when a value the path
# has cannot be read, so a failed read is never equal to a recorded one.
#
# safedeps_tree_clock <path>: status change times.
safedeps_tree_clock() {
  local own target=""
  [[ -e "$1" || -L "$1" ]] || return 0
  own=$(safedeps_file_clock "$1" c)
  [[ -n "${own}" ]] || return 0
  if [[ -e "$1" ]]; then
    target=$(safedeps_file_clock "$1" c follow)
    [[ -n "${target}" ]] || return 0
  fi
  printf '%s|%s' "${own}" "${target}"
}

# safedeps_tree_inode <path>: inodes.
safedeps_tree_inode() {
  local own="" target=""
  [[ -e "$1" || -L "$1" ]] || return 0
  read -r own _ < <(ls -di -- "$1" 2>/dev/null) || true
  [[ -n "${own}" ]] || return 0
  if [[ -e "$1" ]]; then
    read -r target _ < <(ls -diL -- "$1" 2>/dev/null) || true
    [[ -n "${target}" ]] || return 0
  fi
  printf '%s|%s' "${own}" "${target}"
}

# Whether every time in a line safedeps_file_clock or safedeps_tree_clock
# printed has a non-zero part below one second. Both spellings carry the
# fraction after the first dot (GNU's date part has none). A filesystem that
# keeps whole seconds prints zeros there, and a link's target can be on another
# filesystem than the link, so each part is read. An empty part has none.
safedeps_clock_has_subsecond() {
  local rest="$1" part
  while :; do
    part="${rest%%|*}"
    [[ "${part}" =~ \.([0-9]+) ]] && [[ "${BASH_REMATCH[1]}" =~ [1-9] ]] || return 1
    [[ "${rest}" == *"|"* ]] || return 0
    rest="${rest#*|}"
  done
}
