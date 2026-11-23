#!/usr/bin/env bash
# safedeps: what the watch found, told to the agent when a session starts.
#
# The Claude Code SessionStart hook that `install-safedeps-hooks.mjs
# --watch-notice` registers (opt-in; `--no-watch-notice` removes it). Claude
# Code adds a SessionStart hook's plain stdout to the session's context (source:
# https://code.claude.com/docs/en/hooks, "SessionStart ... Claude Code adds
# plain-text stdout as context that Claude can see and act on", verified
# 2026-11-23).
#
# It reads `safedeps --json watch status`, which takes no lock and reads one
# generation, and prints only what the agent has to act on:
#
#   - events a scan raised that no consumer has claimed yet;
#   - roots the last scan could not read in full: what it could not read was
#     not checked, so no new events does not mean nothing was found there;
#   - that no scan has been published yet;
#   - that the status could not be read, with what the read said.
#
# Otherwise it prints nothing. An event is told until it is claimed, so a
# claimed event is not told again. It exits 0 on every path: a SessionStart
# hook does not block, and what it says is what it printed.
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SAFEDEPS_BIN="${ROOT_DIR}/bin/safedeps"
SECTION='"Re-checking what is already installed" in the safedeps skill (SKILL.md)'

say() { printf 'safedeps watch: %s\n' "$*"; }

work=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-watch-notice.XXXXXX") || { say "the status was not read: mktemp failed"; exit 0; }
trap 'rm -rf "${work}"' EXIT

rc=0
"${SAFEDEPS_BIN}" --json watch status > "${work}/out" 2> "${work}/err" || rc=$?
if (( rc != 0 )); then
  said=$(head -n 1 "${work}/err")
  [[ -n "${said}" ]] || said=$(head -c 300 "${work}/out")
  say "the status could not be read (safedeps watch status exited ${rc}: ${said:-nothing said}). Nothing about the watch is known in this session; tell the user."
  exit 0
fi

lines=$(jq -r --arg section "${SECTION}" '
  def plural($n; $one; $many): if $n == 1 then "\($n) \($one)" else "\($n) \($many)" end;
  if .summary == null then
    "no watch scan has been published yet, so nothing already installed has been checked again. Tell the user, and see \($section) to schedule the scan."
  else
    (.summary.pending_events // 0) as $new
    | (.summary.roots_walk_incomplete // 0) as $partial
    | ((.summary.roots_walked // 0) + $partial) as $roots
    | (.last_full_scan.finished_at // null) as $at
    | (if $new > 0 then
         plural($new; "new event"; "new events") + " not yet claimed"
         + (if $at == null then "" else " (last full scan \($at), \(.full_age_hours) h ago)" end) + "."
       else empty end),
      (if $partial > 0 then
         "\($partial) of \($roots) roots" + (if $partial == 1 then " was" else " were" end)
         + " not read in full on the last scan, so what could not be read there was not checked. Tell the user. On macOS, one cause is a protected folder, such as ~/Documents, that the scheduled job may not read. See \($section)."
       else empty end),
      (if $new > 0 then
         "Tell the user what you found, then follow \($section): claim the events, fix on a branch, run the tests, ask before merging, and ack each event."
       else empty end)
  end' "${work}/out" 2> "${work}/jq.err") || {
  say "the status could not be read (jq: $(head -n 1 "${work}/jq.err")). Nothing about the watch is known in this session; tell the user."
  exit 0
}

while IFS= read -r line; do
  [[ -n "${line}" ]] && say "${line}"
done <<< "${lines}"
exit 0
