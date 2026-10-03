#!/usr/bin/env bash
# The control for the report oracle (scripts/test/lib/report-oracle.sh).
#
# The oracle's green is a claim that no line the post hook printed is false or
# outside the grammar. A check that cannot fail says nothing, so this script
# makes it fail nine ways: each mutation below puts into the hook the kind of
# line three review rounds found by reading -- a clause behind a true fact, a
# claim with no check, a line built outside the fact functions, a guessed
# cause -- and e2e must turn red on it, at the oracle, with the reason named
# here. Two of them (P2, R3) passed the whole suite while the check was a list
# of forbidden words.
#
# Each mutation runs on a copy of the tree, never in the checkout: the copy is
# made with `git archive HEAD` (or, outside a git checkout, by copying the
# files), mutated, run and thrown away. The unmutated copy runs first and must
# be green, so a red below is the mutation's and not the machine's.
#
# This is ten e2e runs, so it is not part of `npm test`. Run it when a line the
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
MUTATIONS=(P2 R3 K Lie Bypass Head NoCheck Snap Cause)

mutation() {
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
      M_OLD='    did_not_rebuild "${META_FILE}" "${COMMAND}" "${outside}"'
      M_NEW='    did_not_rebuild "${META_FILE}" "${COMMAND}" "${outside}"
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
Rollback snapshot: ${rollback_snapshot}
Recorded reasons:'
      M_NEW='${journal_line}
Owner: ${owner_fact}
The rollback was cut off, most likely by the runtime'"'"'s timeout.
Rollback snapshot: ${rollback_snapshot}
Recorded reasons:'
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
  if ! replace_once "${WORK}/m${name}/${M_FILE}" "${M_OLD}" "${M_NEW}" 2> "${WORK}/m${name}.mutate"; then
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
