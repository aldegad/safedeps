#!/usr/bin/env bash
# safedeps: measure what a CONCURRENT PostToolUse says while a rollback is
# still running.
#
# The journal exists so an interrupted rollback is not silent. It is read at the
# top of every post hook, because PostToolUse fires on every Bash call and that
# is what makes the report prompt. But "there is a journal entry on disk" is not
# the same claim as "a rollback did not finish": while a rollback is running,
# its own entry is on disk by design — that is the whole point of writing the
# intent before acting.
#
# So an unrelated Bash call landing inside the rollback window reads a live
# entry and reports a finished rollback as interrupted. The user gets a
# REORG INTERRUPTED line, an incident file, and instructions to repair a tree
# that is about to be fine — next to the rollback's own success message.
#
# This harness reproduces that. It runs the real hooks in a sandbox, waits for
# the rollback's first visible act, fires a second post hook with an unrelated
# command (`echo`) while the first is still working, and reports what each one
# said. The state lock does not prevent this: the post hook releases it long
# before the rollback begins.
#
# Usage:
#   scripts/measure/rollback-concurrent-report.sh [delta]
#
# `delta` is seconds to wait after the rollback's first visible act before
# firing the concurrent hook (default 0.5 — inside the node_modules reinstall).

set -uo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
DELTA="${1:-0.5}"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-race.XXXXXX")
trap 'rm -rf "${WORK}"' EXIT

BASELINE_DEP='ms'
BASELINE_VER='2.1.3'
BAD_DEP="${SAFEDEPS_ROLLBACK_BAD_DEP:-express}"
BAD_VER="${SAFEDEPS_ROLLBACK_BAD_VER:-4.21.2}"

hook_payload() {
  local command="$1" cwd="$2"
  jq -nc --arg c "${command}" --arg d "${cwd}" \
    '{tool_name:"Bash", tool_input:{command:$c}, cwd:$d}'
}

project="${WORK}/project"
sd_home="${WORK}/safedeps-home"
mkdir -p "${project}" "${sd_home}"
export SAFEDEPS_HOME="${sd_home}"
export SAFEDEPS_LEDGER_DIR="${sd_home}/approved-specs"
export SAFEDEPS_CACHE_DIR="${sd_home}/cache"

cat > "${project}/package.json" <<JSON
{ "name": "safedeps-race-sandbox", "version": "1.0.0",
  "dependencies": { "${BASELINE_DEP}": "${BASELINE_VER}" } }
JSON
(cd "${project}" && npm install --ignore-scripts --silent >/dev/null 2>&1)
"${REPO_DIR}/bin/safedeps" check npm "${BASELINE_DEP}@${BASELINE_VER}" --json >/dev/null 2>&1

cmd_baseline="npm install ${BASELINE_DEP}@${BASELINE_VER}"
hook_payload "${cmd_baseline}" "${project}" \
  | bash "${REPO_DIR}/scripts/safedeps-pre-guard.sh" >/dev/null 2>&1
hook_payload "${cmd_baseline}" "${project}" \
  | bash "${REPO_DIR}/scripts/safedeps-post-verify.sh" >/dev/null 2>&1

if [[ $(find "${sd_home}" -maxdepth 1 -name 'confirmed_*' | wc -l | tr -d ' ') -eq 0 ]]; then
  echo "SETUP FAILED: no confirmed baseline snapshot" >&2
  exit 1
fi

cmd_bad="npm install ${BAD_DEP}@${BAD_VER}"
hook_payload "${cmd_bad}" "${project}" \
  | bash "${REPO_DIR}/scripts/safedeps-pre-guard.sh" >/dev/null 2>&1
(cd "${project}" && npm install --ignore-scripts --silent "${BAD_DEP}@${BAD_VER}" >/dev/null 2>&1)

pre_pkg_hash=$(shasum -a 256 "${project}/package.json" | cut -d' ' -f1)

# --- the rollback run ---
hook_payload "${cmd_bad}" "${project}" \
  | bash "${REPO_DIR}/scripts/safedeps-post-verify.sh" > "${WORK}/rollback.out" 2>&1 &
rollback_pid=$!

# Wait for the rollback's first visible act, exactly as the kill harness does.
waited=0
while kill -0 "${rollback_pid}" 2>/dev/null; do
  live_hash=$(shasum -a 256 "${project}/package.json" 2>/dev/null | cut -d' ' -f1)
  [[ "${live_hash}" != "${pre_pkg_hash}" ]] && break
  sleep 0.05
  waited=$((waited + 1))
  (( waited > 2000 )) && break
done
sleep "${DELTA}"

journal_live=$(find "${sd_home}/rollback-journal" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
rollback_alive='no'
kill -0 "${rollback_pid}" 2>/dev/null && rollback_alive='yes'

# --- the innocent bystander: an unrelated Bash call during the rollback ---
hook_payload "echo hello" "${project}" \
  | bash "${REPO_DIR}/scripts/safedeps-post-verify.sh" > "${WORK}/bystander.out" 2>&1

wait "${rollback_pid}" 2>/dev/null

interrupted_lines=$(grep -c 'REORG INTERRUPTED' "${sd_home}/reorg.log" 2>/dev/null); interrupted_lines=${interrupted_lines:-0}
executed_lines=$(grep -c 'REORG executed' "${sd_home}/reorg.log" 2>/dev/null); executed_lines=${executed_lines:-0}
incidents=$(find "${sd_home}/rollback-incidents" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
journal_left=$(find "${sd_home}/rollback-journal" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
bystander_claims_interrupted='no'
grep -q 'did not finish' "${WORK}/bystander.out" 2>/dev/null && bystander_claims_interrupted='yes'

printf 'rollback still running when bystander fired : %s\n' "${rollback_alive}"
printf 'journal entries live at that moment        : %s\n' "${journal_live}"
printf 'bystander reported an unfinished rollback  : %s\n' "${bystander_claims_interrupted}"
printf 'reorg.log REORG INTERRUPTED lines          : %s\n' "${interrupted_lines}"
printf 'reorg.log REORG executed lines             : %s\n' "${executed_lines}"
printf 'incident files                             : %s\n' "${incidents}"
printf 'journal entries left at the end            : %s\n' "${journal_left}"
printf '\n'
# A bystander that fired after the rollback had already finished proves nothing:
# there was no live entry for it to misread. That run and a genuine pass produce
# the same silence, so it must not print the same verdict — a later reader
# citing this harness would be citing a run that never entered the window.
if [[ "${executed_lines}" == '0' ]]; then
  printf 'VERDICT: INCONCLUSIVE — the rollback did not complete; rerun.\n'
elif [[ "${bystander_claims_interrupted}" == 'yes' ]]; then
  printf 'VERDICT: FALSE REPORT — the rollback completed (REORG executed) and an\n'
  printf '         unrelated command was told it was interrupted.\n'
elif [[ "${rollback_alive}" != 'yes' || "${journal_live}" == '0' ]]; then
  printf 'VERDICT: WINDOW MISSED — the bystander fired after the rollback finished,\n'
  printf '         so its silence is not evidence. Rerun with a smaller delta\n'
  printf '         (0 lands inside the node_modules reinstall).\n'
else
  printf 'VERDICT: CLEAN — the bystander fired while the rollback was still running\n'
  printf '         with a live journal entry, and stayed quiet.\n'
fi
