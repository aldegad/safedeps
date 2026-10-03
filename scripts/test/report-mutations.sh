#!/usr/bin/env bash
# The control for the report oracle (scripts/test/lib/report-oracle.sh).
#
# The oracle's green is a claim that no line the post hook printed is false or
# outside the grammar. A check that cannot fail says nothing, so this script
# makes it fail twenty-eight ways: each mutation below puts into the hook the kind
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
# (XStr2, bamdori r23), and a pending state whose snapshot has no meta file
# ending the hook with nothing said again (Gone) -- and
# e2e must turn red on it, at the
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
# This is twenty-nine e2e runs, so it is not part of `npm test`. Run it when a line the
# hook prints, a fact function or the oracle changes.
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
MUTATIONS=(P2 R3 K Lie Bypass Head NoCheck Snap Cause Prose LogOnly Reasons Kept Silent JOmit RefuseSilent F1 F2 LogSilent F4 MarkOrig MarkSkip Unread Same Default Version XStr2 Gone)

# A mutation can change a second file too (M_FILE2, M_OLD2, M_NEW2).

mutation() {
  M_FILE2=""
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
  report_say "install scripts were not run in ${PROJECT_DIR}"
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
      M_OLD='  if jq --arg command "$1" '"'"'.ignore_scripts_injected = true'
      M_NEW='  if jq --arg command "${COMMAND}" '"'"'.ignore_scripts_injected = true'
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
  if [[ ${rc} -ne 0 ]] && grep -qF "not ok - report oracle: ${M_RED}" "${WORK}/m${name}.log"; then
    printf 'ok - m%s is red at the oracle: %s (%s; %s oracle line(s), e2e exit %s)\n' "${name}" "${M_RED}" "${M_WHY}" "${reds}" "${rc}"
  else
    printf 'not ok - m%s: %s was not caught as "%s" (e2e exit %s, %s oracle line(s))\n' "${name}" "${M_WHY}" "${M_RED}" "${rc}" "${reds}"
    grep '^not ok' "${WORK}/m${name}.log" | head -3 | cut -c1-300 | sed 's/^/#   /'
    failures=$((failures + 1))
  fi
  rm -rf "${WORK}/m${name}"
done

printf '# end: %s\n' "$(uptime | sed 's/.*load/load/')"
[[ ${failures} -eq 0 ]]
