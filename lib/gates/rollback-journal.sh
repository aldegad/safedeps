#!/usr/bin/env bash
# safedeps rollback journal.
#
# The PostToolUse effect gate cannot deny — the install already ran — so its
# answer to a suspicious closure is to roll the project back. That rollback is a
# sequence: restore the lock and manifest files, then delete and rebuild
# node_modules. Only after all of it did the gate write its reorg.log entry and
# its systemMessage.
#
# Measured (scripts/measure/rollback-kill-state.sh): kill the post hook anywhere
# inside that sequence and reorg.log is zero lines. The project had been
# reverted and nothing anywhere said so — the user sees their install silently
# undone, which is worse for trust than the gate not running at all.
#
# The fix is not to make the rollback atomic; we do not own the atomicity of an
# npm tree rebuild. It is to write the intent BEFORE acting and clear it after,
# so an interrupted rollback leaves a record instead of a silence. A journal
# entry that outlives its run is an unfinished rollback, and the next hook that
# starts says so, loudly and once.
#
# This is deliberately cheap: opening the journal is one small atomic write, and
# checking for a stale one is a directory test. Both hooks are on a budget, and
# a record that costs time is a record that gets skipped.

set -uo pipefail

SAFEDEPS_JOURNAL_HOME="${SAFEDEPS_HOME:-${HOME}/.safedeps}"
SAFEDEPS_JOURNAL_DIR="${SAFEDEPS_JOURNAL_DIR:-${SAFEDEPS_JOURNAL_HOME}/rollback-journal}"
SAFEDEPS_INCIDENT_DIR="${SAFEDEPS_INCIDENT_DIR:-${SAFEDEPS_JOURNAL_HOME}/rollback-incidents}"

safedeps_journal_now_iso() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

safedeps_journal_path() {
  printf '%s/%s.json' "${SAFEDEPS_JOURNAL_DIR}" "$1"
}

# Write (or overwrite) the journal entry for a rollback in progress. Atomic, so
# a kill during the write cannot leave a half-written entry that reads as
# corrupt when someone needs it most.
safedeps_journal_open() {
  local journal_id="$1"
  local project_dir="$2"
  local rollback_snapshot="$3"
  local reasons="$4"
  local stage="${5:-starting}"
  local target
  local temp_path

  command -v jq >/dev/null 2>&1 || return 1
  umask 077
  mkdir -p "${SAFEDEPS_JOURNAL_DIR}" || return 1
  target=$(safedeps_journal_path "${journal_id}")
  temp_path=$(mktemp "${SAFEDEPS_JOURNAL_DIR}/.journal.XXXXXX") || return 1

  jq -nc \
    --arg journal_id "${journal_id}" \
    --arg project_dir "${project_dir}" \
    --arg rollback_snapshot "${rollback_snapshot}" \
    --arg reasons "${reasons}" \
    --arg stage "${stage}" \
    --arg opened_at "$(safedeps_journal_now_iso)" \
    --arg pid "$$" \
    '{journal_id:$journal_id, project_dir:$project_dir,
      rollback_snapshot:$rollback_snapshot, reasons:$reasons,
      stage:$stage, opened_at:$opened_at, pid:$pid}' > "${temp_path}" || {
    rm -f "${temp_path}"
    return 1
  }
  mv -f "${temp_path}" "${target}"
}

# Record which step the rollback reached. What was already done matters to
# whoever reads an interrupted entry: "files restored, reinstall not finished"
# and "nothing restored yet" call for different repairs.
safedeps_journal_stage() {
  local journal_id="$1"
  local stage="$2"
  local target
  local temp_path

  target=$(safedeps_journal_path "${journal_id}")
  [[ -f "${target}" ]] || return 0
  temp_path=$(mktemp "${SAFEDEPS_JOURNAL_DIR}/.journal.XXXXXX") || return 1
  if jq -c --arg stage "${stage}" --arg at "$(safedeps_journal_now_iso)" \
    '. + {stage:$stage, stage_at:$at}' "${target}" > "${temp_path}" 2>/dev/null; then
    mv -f "${temp_path}" "${target}"
  else
    rm -f "${temp_path}"
  fi
}

# The rollback finished and reported itself. Nothing left to warn about.
safedeps_journal_close() {
  local journal_id="$1"
  rm -f "$(safedeps_journal_path "${journal_id}")"
}

# Any journal entry still on disk belongs to a rollback that did not finish.
# Move each one to the incident directory (so it is reported once, not on every
# command from here on), append a line to the same reorg.log the finished
# rollbacks write to, and print a human-readable report on stdout.
#
# Prints nothing and returns 1 when there is nothing to report, so a caller can
# use it as a condition.
safedeps_journal_report_unfinished() {
  local reorg_log="${1:-${SAFEDEPS_JOURNAL_HOME}/reorg.log}"
  local entry
  local found=1
  local report=""

  [[ -d "${SAFEDEPS_JOURNAL_DIR}" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1

  for entry in "${SAFEDEPS_JOURNAL_DIR}"/*.json; do
    [[ -f "${entry}" ]] || continue
    found=0

    local journal_id project_dir rollback_snapshot reasons stage opened_at
    journal_id=$(jq -r '.journal_id // "unknown"' "${entry}" 2>/dev/null || printf 'unknown')
    project_dir=$(jq -r '.project_dir // "unknown"' "${entry}" 2>/dev/null || printf 'unknown')
    rollback_snapshot=$(jq -r '.rollback_snapshot // "unknown"' "${entry}" 2>/dev/null || printf 'unknown')
    reasons=$(jq -r '.reasons // "unrecorded"' "${entry}" 2>/dev/null || printf 'unrecorded')
    stage=$(jq -r '.stage // "unknown"' "${entry}" 2>/dev/null || printf 'unknown')
    opened_at=$(jq -r '.opened_at // "unknown"' "${entry}" 2>/dev/null || printf 'unknown')

    mkdir -p "${SAFEDEPS_INCIDENT_DIR}" 2>/dev/null
    mv -f "${entry}" "${SAFEDEPS_INCIDENT_DIR}/${journal_id}.json" 2>/dev/null || rm -f "${entry}"

    cat >> "${reorg_log}" << LOG_EOF 2>/dev/null
[$(safedeps_journal_now_iso)] REORG INTERRUPTED
  Journal: ${journal_id} (opened ${opened_at}, reached stage: ${stage})
  Project: ${project_dir}
  Rollback snapshot: ${rollback_snapshot}
  Reasons: ${reasons}
  Incident record: ${SAFEDEPS_INCIDENT_DIR}/${journal_id}.json
LOG_EOF

    report="${report}A safedeps rollback of ${project_dir} did not finish.

safedeps found a suspicious dependency closure and started rolling the project
back to snapshot ${rollback_snapshot}. The rollback was cut off at stage
'${stage}' (started ${opened_at}) — most likely the hook hit the runtime's
timeout mid-rollback.

Why it was rolled back:
${reasons}

What this means for the project: the dependency files and node_modules may be
in a mixed state — partly the rejected install, partly the snapshot. Run
\`npm ci\` in ${project_dir} to rebuild the tree from whichever lockfile is
there now, and check that the lockfile is the one you expect before you trust
it.

Incident record: ${SAFEDEPS_INCIDENT_DIR}/${journal_id}.json
Rollback log: ${reorg_log}
"
  done

  [[ ${found} -eq 0 ]] || return 1
  printf '%s' "${report}"
  return 0
}
