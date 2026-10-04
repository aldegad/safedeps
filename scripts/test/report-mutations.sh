#!/usr/bin/env bash
# The control for the report oracle (scripts/test/lib/report-oracle.sh).
#
# The oracle's green is a claim that no line the post hook printed is false or
# outside the grammar. A check that cannot fail says nothing, so this script
# makes it fail thirty-six ways: each mutation below puts into the hook the kind
# of line review found by reading -- a clause behind a true fact, a claim with
# no check, a line built outside the fact functions, a guessed cause, prose in
# a rollback, a line only reorg.log carries, a line left out, a reorg.log entry
# from a call that printed nothing (LogSilent), the listing the hook and the
# oracle once read the same wrong way (F1), "added" said of a command that is
# not the one safedeps wrote (F2), an --ignore-scripts line from the backstop,
# which found no record of the command (F4), and a record of the rewrite that
# holds the command as given (MarkOrig) or is not written (MarkSkip), and a
# record the hook could not read said as "did not add" (Unread), two
# calls in one second given one snapshot id again (Same), a record that does
# not state a fact answered by a default again (Default), a record of
# another version read as this one (Version), the version read as a string
# (XStr2, bamdori r23), a pending state whose snapshot has no meta file
# ending the hook with nothing said again (Gone), a record that names no
# snapshot doing the same (Empty), a record that is not one JSON object
# set aside with nothing said (NotObject), and a record with no project_dir
# judged in the hook's own working directory with the record's hash
# (NoDir, the code before the fix), and a record's dir_hash picking the
# confirmed snapshot again (RecordHash, bamdori J), a record found by the
# directory and the command again for every call, so that one of two
# overlapping calls takes the other's (KeyRecords, bamdori r19 X1), a call
# whose own record is missing given another call's by that key
# (IdFallsBackToKey), a record a pre-#5 pre-guard left read again (Legacy),
# and the registry warning saying "(on Codex it cannot)" of a Claude Code call
# again (CodexEverywhere) -- and e2e must turn red on it, at the
# oracle, with the reason named here. Two of them (P2, R3) passed
# the whole suite while the check was a list of forbidden words; seven more
# (Prose to RefuseSilent, bamdori r16) passed the oracle before it read
# reorg.log entries, prose per block and the disk around a rollback.
#
# Each mutation runs on a copy of the tree, never in the checkout: the copy is
# made with `git archive HEAD` (or, outside a git checkout, by copying the
# files), mutated, run and thrown away. The unmutated copy runs first and must
# be green, so a red below is the mutation's and not the machine's.
#
# Eight more mutations are not lines: seven break the backstop's trace check,
# which decides whether the backstop judges a command at all, and one drops the
# advisory.log line that says a call named no tool_use_id (NoIdSilent), and e2e
# must turn red at the row named here rather than at the oracle. TraceNever finds no
# trace in any baseline, and the install the pre-guard did not read is kept;
# TraceAlways finds one in every baseline, and a grep rolls the project back;
# WalkOff drops the walk of node_modules, and a write only there (bun, pnpm, a
# file inside a package) is kept; PullAlways sets the baseline two seconds back
# on every filesystem, and a grep right after a pull rolls the project back;
# Oldest keeps entries by project and command and reads the oldest, and a
# failed call's entry makes a later grep roll the project back; LinkLstat reads
# a linked lockfile's own status change time and not its target's, and a write
# through the link is kept (lumi r2 S1); AnySubsecond keeps the baseline where
# any file of the node tree, rather than every one, keeps time below one
# second, and a node_modules that keeps whole seconds is walked from a baseline
# that is not set back (lumi r2 P3).
#
# EntryAfterRecord, which read the trace entry only where no record was found
# (the order before lumi r3 REC), is retired: since records are bound to the
# call, a call has its entry or its record and never both, so no row can tell
# the two orders apart. KeyRecords is the defect it stood for.
#
# This is forty-five e2e runs, so it is not part of `npm test`. Run it when a
# line the hook prints, a fact function, the oracle or the trace check changes.
#
#   scripts/test/report-mutations.sh            every mutation
#   scripts/test/report-mutations.sh K Snap     only those
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-report-mutations.XXXXXX")
trap 'rm -rf "${WORK}"' EXIT

# mutation <name> sets the file, what the mutation is, the reason the oracle
# must give, and the text to find and to put in its place. The text to find
# occurs exactly once in the file, or the mutation is reported as not applying.
MUTATIONS=(P2 R3 K Lie Bypass Head NoCheck Snap Cause Prose LogOnly Reasons Kept Silent JOmit RefuseSilent F1 F2 LogSilent F4 MarkOrig MarkSkip Unread Same Default Version XStr2 Gone Empty NotObject NoDir RecordHash
  KeyRecords IdFallsBackToKey Legacy CodexEverywhere
  TraceNever TraceAlways WalkOff PullAlways Oldest LinkLstat AnySubsecond NoIdSilent)

# A mutation can change a second file too (M_FILE2, M_OLD2, M_NEW2). M_AT is
# where its red must show: the oracle, or (empty) any e2e row.

mutation() {
  M_FILE2=""
  M_AT="report oracle: "
  case "$1" in
    P2)
      M_FILE=lib/gates/report-facts.sh
      M_WHY='a skipped rebuild that ends in advice'
      M_RED='the reason is not a fact form that holds on disk'
      M_OLD='did_not_rebuild() { report_rebuild "$1" "$2" "did not run npm rebuild: $3"; }'
      M_NEW='did_not_rebuild() { report_rebuild "$1" "$2" "did not run npm rebuild: $3. Rebuild there yourself once the link is gone"; }'
      ;;
    R3)
      M_FILE=lib/gates/npm-reach.sh
      M_WHY='a reason that says what npm does with the link'
      M_RED='the reason is not a fact form that holds on disk'
      M_OLD="printf '%s/%s is a symbolic link to %s' \"\${dir}\" \"\${name}\" \"\$(safedeps_link_target \"\${dir}/\${name}\")\""
      M_NEW="printf '%s/%s is a symbolic link to %s, and npm follows it' \"\${dir}\" \"\${name}\" \"\$(safedeps_link_target \"\${dir}/\${name}\")\""
      ;;
    K)
      M_FILE=lib/gates/report-facts.sh
      M_WHY='a failed removal that says what is left in the directory'
      M_RED='the path is gone, or the fact names another path'
      M_OLD='report_say "not removed $1: rm exit ${rc}; $(fact_path "$1")"'
      M_NEW='report_say "not removed $1: rm exit ${rc}; $(fact_path "$1"), with whatever this install wrote in it"'
      ;;
    Lie)
      M_FILE=lib/gates/report-facts.sh
      M_WHY='a removal reported without looking'
      M_RED='the path is still there'
      M_OLD='  if [[ -e "$1" || -L "$1" ]]; then
    report_say "not removed'
      M_NEW='  if false; then
    report_say "not removed'
      ;;
    Bypass)
      M_FILE=scripts/safedeps-post-verify.sh
      M_WHY='a line added to the message outside the fact functions'
      M_RED='a line outside the grammar'
      M_OLD='    did_not_rebuild "${META_FILE}" "${INPUT}" "${outside}"'
      M_NEW='    did_not_rebuild "${META_FILE}" "${INPUT}" "${outside}"
    ROLLBACK_WARNINGS=("${ROLLBACK_WARNINGS[@]}" "The verified packages'"'"' install scripts have not run")'
      ;;
    Head)
      M_FILE=scripts/safedeps-post-verify.sh
      M_WHY='a headline that claims a confirmed snapshot'
      M_RED='a line before any headline'
      M_OLD='    "safedeps: suspicious dependency change detected. A rollback ran." \'
      M_NEW='    "safedeps: suspicious dependency change detected — rolled back to the last confirmed safe snapshot." \'
      ;;
    NoCheck)
      M_FILE=lib/gates/report-facts.sh
      M_WHY='a state line printed without its test'
      M_RED='the stated fact does not hold on disk'
      M_OLD='report_path() { report_say "$(fact_path "$1")"; }'
      M_NEW='report_path() { report_say "$1 exists"; }'
      ;;
    Snap)
      M_FILE=scripts/safedeps-post-verify.sh
      M_WHY='a snapshot called confirmed without reading the confirmed record'
      M_RED='the confirmed record of the project does not name this snapshot'
      M_OLD='  if [[ -n "$1" && "$(read_confirmed_snapshot "${DIR_HASH}")" == "$1" ]]; then'
      M_NEW='  if true; then'
      ;;
    Cause)
      M_FILE=lib/gates/rollback-journal.sh
      M_WHY='a guessed cause in the unfinished-rollback report'
      M_RED='a line outside the grammar'
      M_OLD='${journal_line}
Owner: ${owner_fact}
${snapshot_line}
Recorded reasons:'
      M_NEW='${journal_line}
Owner: ${owner_fact}
The rollback was cut off, most likely by the runtime'"'"'s timeout.
${snapshot_line}
Recorded reasons:'
      ;;
    Prose)
      M_FILE=scripts/safedeps-post-verify.sh
      M_WHY='effect-gate prose appended to every rollback'
      M_RED='effect-gate prose in a block it is not said in'
      M_OLD='report_rollback_tail() {
  report_changed_nothing
'
      M_NEW='report_rollback_tail() {
  report_changed_nothing
  report_say "npm rebuild was not run: ${PROJECT_DIR}"
'
      ;;
    LogOnly)
      M_FILE=scripts/safedeps-post-verify.sh
      M_WHY='a line only the reorg.log entry carries'
      M_RED='the reorg.log entries this hook appended are not the ones its message calls for'
      M_OLD='  Reasons: $4
  ${snapshot_line}
'
      M_NEW='  Reasons: $4
  ${snapshot_line}
  the rejected package'"'"'s install scripts did not run
'
      ;;
    Reasons)
      M_FILE=scripts/safedeps-post-verify.sh
      M_WHY='a clause added to the reasons of the message only'
      M_RED='the reorg.log entries this hook appended are not the ones its message calls for'
      M_OLD='Detected problems:
$4
'
      M_NEW='Detected problems:
$4; node_modules was restored from the confirmed snapshot
'
      ;;
    Kept)
      M_FILE=lib/gates/report-facts.sh
      M_WHY='a failed removal reported as kept'
      M_RED='kept, right after a reason to remove it'
      M_OLD='report_say "not removed $1: rm exit ${rc}; $(fact_path "$1")"'
      M_NEW='report_say "kept $1"'
      ;;
    Silent)
      M_FILE=scripts/safedeps-post-verify.sh
      M_WHY='node_modules removed outside the fact functions, with no line'
      M_RED='this entry of the project changed on disk, and no step line names it'
      M_OLD='  [[ -d "${node_modules}" ]] || return 0
  did_remove "${node_modules}"
'
      M_NEW='  [[ -d "${node_modules}" ]] || return 0
  rm -rf "${node_modules}"
'
      ;;
    JOmit)
      M_FILE=lib/gates/rollback-journal.sh
      M_WHY='the unfinished-rollback report leaves out what node_modules is'
      M_RED='an unfinished-rollback report with no node_modules line'
      M_OLD='  printf '"'"'%s\n'"'"' "$(fact_path "${dir}/node_modules")"
'
      M_NEW=''
      ;;
    RefuseSilent)
      M_FILE=scripts/safedeps-post-verify.sh
      M_WHY='a refusal left out of the message, kept in reorg.log'
      M_RED='the reorg.log entries this hook appended are not the ones its message calls for'
      M_OLD='  line=$(did_refuse "${kind}" "${path}" "${why}")
  report_say "${line}"
'
      M_NEW='  line=$(did_refuse "${kind}" "${path}" "${why}")
'
      ;;
    F1)
      M_FILE=scripts/safedeps-post-verify.sh
      M_WHY='both listings of node_modules stop at a link again'
      M_RED='kept, but before the hook ran node_modules showed a write'
      M_OLD='  found=$(find -H "${node_modules}" -maxdepth 3'
      M_NEW='  found=$(find "${node_modules}" -maxdepth 3'
      M_FILE2=scripts/safedeps-pre-guard.sh
      M_OLD2='  find -H "${PROJECT_DIR}/node_modules" -maxdepth 3'
      M_NEW2='  find "${PROJECT_DIR}/node_modules" -maxdepth 3'
      ;;
    F2)
      M_FILE=lib/gates/report-facts.sh
      M_WHY='"added" said where the command this hook received is not the one safedeps wrote'
      M_RED="the pre-guard's record says it rewrote the command: true; the command this hook received is the one it wrote: false"
      M_OLD='          (if .tool_input.command == $m.updated_command then "added"'
      M_NEW='          (if true then "added"'
      ;;
    LogSilent)
      M_FILE=scripts/safedeps-post-verify.sh
      M_WHY='a reorg.log entry from a call that confirmed the install and printed nothing'
      M_RED='reorg.log grew by '
      M_OLD='  [[ ${#ROLLBACK_WARNINGS[@]} -gt 0 ]] || return 0'
      M_NEW='  [[ ${#ROLLBACK_WARNINGS[@]} -gt 0 ]] || { printf '"'"'[%s] CONFIRM warnings\n  restored %s/package-lock.json\n'"'"' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${PROJECT_DIR}" >> "${GUARD_DIR}/reorg.log"; return 0; }'
      ;;
    F4)
      M_FILE=scripts/safedeps-post-verify.sh
      # Since the version 2 rule the backstop's missing record says no line by
      # itself, so this mutant is caught by the advisory.log line it writes
      # from a message that carries no --ignore-scripts line.
      M_WHY='the backstop, which found no record of the command, reads one for an --ignore-scripts line'
      M_RED='a hook whose record states no --ignore-scripts line said so in advisory.log 1 times, not 0'
      M_OLD='  [[ "${BACKSTOP_INSTALL:-false}" == true ]] || report_inert "${META_FILE}" "${INPUT}"'
      M_NEW='  report_inert "${META_FILE}" "${INPUT}"'
      ;;
    MarkOrig)
      M_FILE=scripts/safedeps-pre-guard.sh
      M_WHY='the record of the rewrite holds the command as given, not the one safedeps wrote'
      M_RED='the command a record says safedeps wrote is not the rewrite the pre-guard printed'
      M_OLD='  if jq --arg command "$1" --argjson unread "${unread}" \'
      M_NEW='  if jq --arg command "${COMMAND}" --argjson unread "${unread}" \'
      ;;
    MarkSkip)
      M_FILE=scripts/safedeps-pre-guard.sh
      M_WHY='a rewrite printed with no record of it'
      M_RED='the pre-guard printed a rewrite and no single record says it wrote one'
      M_OLD='  [[ -f "${meta_file}" ]] || return 1
'
      M_NEW='  return 0
'
      ;;
    Unread)
      M_FILE=lib/gates/report-facts.sh
      M_WHY='a record the hook could not read said as "did not add"'
      M_RED="an --ignore-scripts line from a hook whose read of the pre-guard's record failed"
      M_OLD="        else \"unstated\" end' 2>/dev/null) || return 1"
      M_NEW="        else \"unstated\" end' 2>/dev/null) || said=none"
      ;;
    TraceNever)
      M_FILE=scripts/safedeps-post-verify.sh
      M_WHY='a trace check that finds no trace in any baseline'
      M_AT=""
      M_RED='an install the pre-guard did not read: the backstop rolls back'
      M_OLD='    printf '"'"'the trace baseline %s does not exist'"'"' "${baseline}"
    return 0
  fi'
      M_NEW='    printf '"'"'the trace baseline %s does not exist'"'"' "${baseline}"
    return 0
  fi
  printf '"'"'no trace in %s: the mutant checked nothing'"'"' "${PROJECT_DIR}"; return 1'
      ;;
    TraceAlways)
      M_FILE=scripts/safedeps-post-verify.sh
      M_WHY='a trace check that finds a trace in every baseline'
      M_AT=""
      M_RED='a grep right after a pull outside the gate: the backstop says nothing'
      M_OLD='  if [[ -z "${BACKSTOP_TRACE_ENTRY}" ]]; then
    printf '"'"'%s'"'"' "${BACKSTOP_TRACE_NONE:-the pre-guard left no trace entry for this call}"'
      M_NEW='  if true; then
    printf '"'"'%s'"'"' "${BACKSTOP_TRACE_NONE:-the pre-guard left no trace entry for this call}"'
      ;;
    PullAlways)
      M_FILE=scripts/safedeps-pre-guard.sh
      M_WHY='a baseline set two seconds back on every filesystem, the rule before it was measured'
      M_AT=""
      M_RED='a grep right after a pull outside the gate: the backstop says nothing'
      M_OLD='  if (( present > 0 && subsecond == present )) \'
      M_NEW='  if false && (( present > 0 && subsecond == present )) \'
      ;;
    Oldest)
      M_FILE=scripts/safedeps-pre-guard.sh
      M_WHY='entries kept by project and command and the oldest one read, the rule before entries belonged to a call'
      M_AT=""
      M_RED='a grep after a failed grep and a pull: the backstop says nothing'
      M_OLD='  base=$(safedeps_call_base "${entry_dir}" "${id}") || return 0'
      M_NEW='  base=$(safedeps_call_base "${entry_dir}" "$(compute_pending_key "${dir_hash}" "${COMMAND}")_$$") || return 0'
      M_FILE2=scripts/safedeps-post-verify.sh
      M_OLD2='  if [[ -z "${CALL_ID}" ]] || ! base=$(safedeps_call_base "${GUARD_DIR}/pending/backstop" "${CALL_ID}"); then'
      M_NEW2='  if ! base=$(ls -tr "${GUARD_DIR}/pending/backstop/id-$(compute_pending_key "${POST_DIR_HASH}" "${COMMAND}")_"*.json 2>/dev/null | head -n 1 | sed '"'"'s/\.json$//'"'"' | grep .); then'
      ;;
    LinkLstat)
      M_FILE=lib/gates/backstop-trace.sh
      M_WHY='a linked lockfile read by its own status change time and not its target'"'"'s, the rule before lumi r2 S1'
      M_AT=""
      M_RED='a write through a linked lockfile is a trace'
      M_OLD='      stat -L -c "${field}" -- "$1" 2>/dev/null'
      M_NEW='      stat -c "${field}" -- "$1" 2>/dev/null'
      M_FILE2=lib/gates/backstop-trace.sh
      M_OLD2='      stat -L -f "${field}" -- "$1" 2>/dev/null'
      M_NEW2='      stat -f "${field}" -- "$1" 2>/dev/null'
      ;;
    AnySubsecond)
      M_FILE=scripts/safedeps-pre-guard.sh
      M_WHY='a node tree read as subsecond where any part, rather than every one, keeps time below one second, the rule before lumi r2 P3'
      M_AT=""
      M_RED='a write into node_modules on a whole-second mount beside a subsecond lockfile'
      M_OLD='  if (( present > 0 && subsecond == present )) \'
      M_NEW='  if (( subsecond > 0 )) \'
      ;;
    WalkOff)
      M_FILE=scripts/safedeps-post-verify.sh
      M_WHY='a trace check that does not walk node_modules'
      M_AT=""
      M_RED='a write only into node_modules is a trace'
      M_OLD='  find -H "${PROJECT_DIR}/node_modules" -cnewer "${baseline}" -print -quit > "${walk}" 2>/dev/null &'
      M_NEW='  true > "${walk}" 2>/dev/null &'
      ;;
    Same)
      M_FILE=scripts/safedeps-pre-guard.sh
      M_WHY='two pre-guard calls in one project within one second given one snapshot id, the format before it was claimed per call'
      M_RED='a pre-guard call wrote over a record that was there before it ran'
      M_OLD='SNAPSHOT_ID=$(claim_snapshot_id)'
      M_NEW='SNAPSHOT_ID="${TIMESTAMP}_${DIR_HASH}"; : > "${SNAPSHOT_DIR}/${SNAPSHOT_ID}_monitored_files.list"'
      M_FILE2=scripts/safedeps-pre-guard.sh
      M_OLD2='PENDING_BASE="${PENDING_DIR}/${PENDING_KEY}__${SNAPSHOT_ID}"'
      M_NEW2='PENDING_BASE="${PENDING_DIR}/${PENDING_KEY}__${SNAPSHOT_ID}_$$"'
      ;;
    Default)
      M_FILE=lib/gates/report-facts.sh
      M_WHY='a record that does not state whether safedeps rewrote the command, and no record file, said as "did not add" by default'
      M_RED="an --ignore-scripts line, and the pre-guard's record does not state it as a version 2 record"
      M_OLD='  [[ -e "$1" || -L "$1" ]] || return 2
'
      M_NEW='  [[ -e "$1" || -L "$1" ]] || { printf '"'"'safedeps did not add --ignore-scripts to this install'"'"'; return 0; }
'
      M_FILE2=lib/gates/report-facts.sh
      M_OLD2='    unstated) return 2 ;;'
      M_NEW2='    unstated) printf '"'"'safedeps did not add --ignore-scripts to this install'"'"' ;;'
      ;;
    Version)
      M_FILE=lib/gates/report-facts.sh
      M_WHY='a record of another version, or of none, read as a version 2 record'
      M_RED="an --ignore-scripts line, and the pre-guard's record does not state it as a version 2 record"
      M_OLD='      | if $m.record != 2 then "unstated"'
      M_NEW='      | if false then "unstated"'
      ;;
    XStr2)
      M_FILE=lib/gates/report-facts.sh
      M_WHY='a record whose version is the string "2" read as a version 2 record'
      M_RED="an --ignore-scripts line, and the pre-guard's record does not state it as a version 2 record"
      M_OLD='      | if $m.record != 2 then "unstated"'
      M_NEW='      | if ($m.record | tostring) != "2" then "unstated"'
      ;;
    Gone)
      M_FILE=scripts/safedeps-post-verify.sh
      M_WHY='a pending state whose snapshot has no meta file ends the hook with nothing said, as it did from e315244'
      M_RED='a pending state whose snapshot has no meta file was consumed, and advisory.log names it 0 times, not once'
      M_OLD='  BACKSTOP_INSTALL=true
  BACKSTOP_RECORD_GONE=true
'
      M_NEW='  exit 0
'
      M_FILE2=scripts/safedeps-post-verify.sh
      M_OLD2='  log_advisory "post-verify: the pre-guard'"'"'s record ${RECORD_PATH} names the snapshot'
      M_NEW2='  : "post-verify: the pre-guard'"'"'s record ${RECORD_PATH} names the snapshot'
      ;;
    Empty)
      M_FILE=scripts/safedeps-post-verify.sh
      M_WHY='a record that names no snapshot ends the hook with nothing said again'
      M_RED='a record that names no snapshot was consumed, and advisory.log names it 0 times, not once'
      M_OLD='  log_advisory "post-verify: the pre-guard'"'"'s record ${RECORD_PATH} names no snapshot; this hook set the record aside, and the command goes to the command-independent backstop"
  BACKSTOP_INSTALL=true
  BACKSTOP_RECORD_EMPTY=true
'
      M_NEW='  exit 0
'
      ;;
    NotObject)
      M_FILE=scripts/safedeps-post-verify.sh
      M_WHY='a record that is not one JSON object is set aside with nothing said'
      M_RED='a record that is not one JSON object was consumed, and advisory.log names it 0 times, not once'
      M_OLD='  if ! read_record_object "${PENDING_FILE}"; then
    set_unread_record_aside
  fi
'
      M_NEW='  if ! read_record_object "${PENDING_FILE}"; then
    rm -f "${PENDING_FILE}"; exit 0
  fi
'
      ;;
    NoDir)
      M_FILE=scripts/safedeps-post-verify.sh
      M_WHY='a record with no project_dir is judged and rolled back in the hook'"'"'s own working directory'
      M_RED='a step line names a path outside'
      M_OLD='  PROJECT_DIR="${POST_CWD}"
fi
DIR_HASH=$(compute_dir_hash "${PROJECT_DIR}")
'
      M_NEW='  PROJECT_DIR=$(pwd)
fi
[[ -n "${DIR_HASH:-}" ]] || DIR_HASH=$(compute_dir_hash "${PROJECT_DIR}")
'
      ;;
    RecordHash)
      M_FILE=scripts/safedeps-post-verify.sh
      M_WHY='the record'"'"'s dir_hash picks the confirmed snapshot again'
      M_RED='the confirmed record of the project does not name this snapshot'
      M_OLD='fi
DIR_HASH=$(compute_dir_hash "${PROJECT_DIR}")
'
      M_NEW='fi
[[ -n "${DIR_HASH:-}" ]] || DIR_HASH=$(compute_dir_hash "${PROJECT_DIR}")
'
      ;;
    KeyRecords)
      M_FILE=scripts/safedeps-pre-guard.sh
      M_WHY='records kept and found by the directory and the command for every call, the rule before they were bound to the call'
      M_RED="the hook consumed the record of the call 'toolu_ov1_a', and this call is 'exec-ov1-b'"
      M_OLD='if [[ -n "${CALL_ID}" ]]; then
  PENDING_BASE=$(safedeps_call_base'
      M_NEW='if false; then
  PENDING_BASE=$(safedeps_call_base'
      M_FILE2=scripts/safedeps-post-verify.sh
      M_OLD2='  if [[ -n "${CALL_ID}" ]]; then
    PENDING_FILE='
      M_NEW2='  if false; then
    PENDING_FILE='
      ;;
    IdFallsBackToKey)
      M_FILE=scripts/safedeps-post-verify.sh
      M_WHY='a call whose own record is missing given the record found by the directory and the command'
      M_RED="the hook consumed the record of the call '', and this call is 'toolu_ov2_b'"
      M_OLD='    [[ -f "${PENDING_FILE}" ]] || PENDING_FILE=""'
      M_NEW='    [[ -f "${PENDING_FILE}" ]] || PENDING_FILE=$(ls "${GUARD_DIR}/pending/$(compute_pending_key "${POST_DIR_HASH}" "${COMMAND}")__"*.json 2>/dev/null | head -n 1)'
      ;;
    Legacy)
      M_FILE=scripts/safedeps-post-verify.sh
      M_WHY='a record a pre-#5 pre-guard left read as this command'"'"'s again'
      M_RED='the hook consumed a record a pre-#5 pre-guard left, which belongs to no call'
      M_OLD='else
  # No record for this call (PreToolUse never recognized it'
      M_NEW='elif [[ -f "${GUARD_DIR}/current_snapshot_id" ]]; then
  SNAPSHOT_ID=$(cat "${GUARD_DIR}/current_snapshot_id")
  PROJECT_DIR=$(cat "${GUARD_DIR}/current_project_dir" 2>/dev/null || pwd)
  RECORD_PATH="${GUARD_DIR}/current_snapshot_id"
  rm -f "${GUARD_DIR}/current_snapshot_id" "${GUARD_DIR}/current_project_dir"
else
  # No record for this call (PreToolUse never recognized it'
      ;;
    CodexEverywhere)
      M_FILE=scripts/safedeps-post-verify.sh
      M_WHY='the registry warning says safedeps cannot add --ignore-scripts on Codex of a call from either engine, as it did in v2.18.0'
      M_RED='the warning says safedeps cannot add --ignore-scripts on Codex, of a claude call'
      M_OLD='            [[ "${POST_IS_CODEX}" != true ]] || inert_said+=" (on Codex it cannot)" ;;'
      M_NEW='            inert_said+=" (on Codex it cannot)" ;;'
      ;;
    NoIdSilent)
      M_FILE=scripts/safedeps-pre-guard.sh
      M_WHY='a call that names no tool_use_id given the record kept by the directory and the command, with nothing said'
      M_AT=""
      M_RED='the pre-guard records that a call names no tool_use_id'
      M_OLD='  log_advisory "pre-guard: ${CALL_ID_WHY}, so the record'
      M_NEW='  : "pre-guard: ${CALL_ID_WHY}, so the record'
      ;;
    *) return 1 ;;
  esac
}

copy_tree() {
  mkdir -p "$1"
  if git -C "${ROOT_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1 && [[ -z "${SAFEDEPS_MUTATIONS_FROM_FILES:-}" ]]; then
    git -C "${ROOT_DIR}" archive HEAD | tar -x -C "$1"
  else
    (cd "${ROOT_DIR}" && tar -cf - --exclude .git --exclude node_modules .) | tar -x -C "$1"
  fi
}

replace_once() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys
path, old, new = sys.argv[1:4]
text = open(path).read()
if text.count(old) != 1:
    sys.exit("the text to mutate occurs %d times in %s, not once" % (text.count(old), path))
open(path, "w").write(text.replace(old, new))
PY
}

names=("$@")
[[ ${#names[@]} -gt 0 ]] || names=("${MUTATIONS[@]}")
failures=0

printf '# report-mutations: %s; bash %s; %s\n' "$(uname -sm)" "${BASH_VERSION}" "$(uptime | sed 's/.*load/load/')"

copy_tree "${WORK}/control"
if (cd "${WORK}/control" && bash scripts/test/e2e.sh > "${WORK}/control.log" 2>&1); then
  printf 'ok - control: the unmutated tree passes e2e (%s)\n' "$(grep -c '^ok' "${WORK}/control.log") ok lines"
else
  printf 'not ok - control: the unmutated tree fails e2e, so a red below would prove nothing\n'
  tail -5 "${WORK}/control.log" | sed 's/^/#   /'
  exit 1
fi
rm -rf "${WORK}/control"

for name in "${names[@]}"; do
  if ! mutation "${name}"; then
    printf 'not ok - m%s: no such mutation\n' "${name}"
    failures=$((failures + 1))
    continue
  fi
  copy_tree "${WORK}/m${name}"
  if ! replace_once "${WORK}/m${name}/${M_FILE}" "${M_OLD}" "${M_NEW}" 2> "${WORK}/m${name}.mutate" \
    || { [[ -n "${M_FILE2}" ]] && ! replace_once "${WORK}/m${name}/${M_FILE2}" "${M_OLD2}" "${M_NEW2}" 2> "${WORK}/m${name}.mutate"; }; then
    printf 'not ok - m%s: the mutation does not apply (%s)\n' "${name}" "$(cat "${WORK}/m${name}.mutate")"
    failures=$((failures + 1))
    continue
  fi
  rc=0
  (cd "${WORK}/m${name}" && bash scripts/test/e2e.sh > "${WORK}/m${name}.log" 2>&1) || rc=$?
  reds=$(grep -c '^not ok - report oracle: ' "${WORK}/m${name}.log" || true)
  if [[ ${rc} -ne 0 ]] && grep -qF "not ok - ${M_AT}${M_RED}" "${WORK}/m${name}.log"; then
    printf 'ok - m%s is red %s: %s (%s; %s oracle line(s), e2e exit %s)\n' "${name}" "$([[ -n "${M_AT}" ]] && printf 'at the oracle' || printf 'at its row')" "${M_RED}" "${M_WHY}" "${reds}" "${rc}"
  else
    printf 'not ok - m%s: %s was not caught as "%s" (e2e exit %s, %s oracle line(s))\n' "${name}" "${M_WHY}" "${M_RED}" "${rc}" "${reds}"
    grep '^not ok' "${WORK}/m${name}.log" | head -3 | cut -c1-300 | sed 's/^/#   /'
    failures=$((failures + 1))
  fi
  rm -rf "${WORK}/m${name}"
done

printf '# end: %s\n' "$(uptime | sed 's/.*load/load/')"
[[ ${failures} -eq 0 ]]
