#!/usr/bin/env bash
# Which tool call a hook input belongs to. Both hooks read it with this, so
# the pre-guard and the post hook of one call name its files the same way.
#
# The tool_use_id is the one field both hooks of a call receive and no other
# call does. Claude Code and Codex both send it top-level in PreToolUse and
# PostToolUse, and Claude Code in PostToolUseFailure too (source:
# https://code.claude.com/docs/en/hooks, https://learn.chatgpt.com/docs/hooks,
# verified 2026-10-04). Measured, the same value reaches both hooks of a call:
# Claude Code 2.1.288 and 2.1.289 `toolu_...`, Codex CLI 0.160.0 `exec-<uuid>`.
#
# safedeps_call_id <hook input>: prints the id, or returns 1 when the input
# names none or one that is not a plain word. A file is named after it, so a
# word with a slash or a dot in it would name a file somewhere else.
safedeps_call_id() {
  local id
  id=$(jq -r 'if (.tool_use_id | type) == "string" then .tool_use_id else empty end' <<< "$1" 2>/dev/null) || return 1
  [[ "${id}" =~ ^[A-Za-z0-9_-]{1,128}$ ]] || return 1
  printf '%s' "${id}"
}

# safedeps_call_base <dir> <id>: the files of one call in <dir>, without an
# extension. Returns 1, printing nothing, for an id safedeps_call_id would not
# print.
safedeps_call_base() {
  [[ "$2" =~ ^[A-Za-z0-9_-]{1,128}$ ]] || return 1
  printf '%s/id-%s' "$1" "$2"
}
