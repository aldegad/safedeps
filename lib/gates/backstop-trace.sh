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

# The entry of one tool call: <dir>/id-<tool_use_id>, without an extension.
# The tool_use_id is the one field both hooks of a call receive and no other
# call does (Claude Code and Codex both send it top-level in PreToolUse and
# PostToolUse). A call whose input names none, or names one that is not a plain
# word, gets no entry: nothing else ties the pre-guard's entry to this call's
# post hook rather than another's.
safedeps_backstop_entry_base() {
  local dir="$1" id="$2"
  [[ "${id}" =~ ^[A-Za-z0-9_-]{1,128}$ ]] || return 1
  printf '%s/id-%s' "${dir}" "${id}"
}

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

# safedeps_file_clock <file> <m|c>: the file's modification (m) or status
# change (c) time as stat prints it at full resolution. Nothing when stat
# fails. The text is compared only with text this function printed.
safedeps_file_clock() {
  safedeps_stat_flavor
  if [[ "${SAFEDEPS_STAT_FLAVOR}" == gnu ]]; then
    if [[ "$2" == m ]]; then stat -c %y -- "$1" 2>/dev/null; else stat -c %z -- "$1" 2>/dev/null; fi
  else
    if [[ "$2" == m ]]; then stat -f %Fm -- "$1" 2>/dev/null; else stat -f %Fc -- "$1" 2>/dev/null; fi
  fi
}

# Whether a time safedeps_file_clock printed has a non-zero part below one
# second. Both spellings carry the fraction after the first dot (GNU's date part
# has none). A filesystem that keeps whole seconds prints zeros there.
safedeps_clock_has_subsecond() {
  [[ "$1" =~ \.([0-9]+) ]] && [[ "${BASH_REMATCH[1]}" =~ [1-9] ]]
}
