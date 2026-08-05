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

# Parse one of this file's timestamps to epoch seconds. GNU (`date -d`) first,
# then BSD/macOS (`date -j -f`), the way the state lock already reads mtime from
# either stat. One implementation because two callers now need it and a second
# copy is how the first goes stale.
safedeps_journal_epoch() {
  local stamp="$1"
  [[ -n "${stamp}" ]] || return 1
  date -u -d "${stamp}" +%s 2>/dev/null && return 0
  date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "${stamp}" +%s 2>/dev/null && return 0
  return 1
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

# Is the process that opened this entry still running its rollback?
#
# "An entry is on disk" is not "a rollback did not finish". During a rollback
# its own entry is on disk deliberately, so an unrelated Bash call landing in
# that window used to report a finished rollback as interrupted (measured:
# scripts/measure/rollback-concurrent-report.sh — REORG INTERRUPTED and REORG
# executed in the same log, plus an incident file, for a rollback that worked).
#
# The state lock cannot answer this. The post hook releases it before the
# rollback begins, so the rollback runs unlocked and a second hook would take
# the lock and read the same live entry. Liveness is the only thing that
# separates "running" from "killed", so the journal's own pid is the oracle.
#
# Two ways to be wrong, and only one of them is safe:
#   - calling a dead rollback alive suppresses a real report (silence — the
#     defect the journal exists to prevent)
#   - calling a live rollback dead produces a false report (noise)
# So this answers "running" only on positive evidence and defaults to gone.
#
# There is a third state, and folding it into the pair gets it wrong either way.
# A STOPPED owner (SIGSTOP/SIGTSTP) has not died — SIGCONT resumes it — but it
# is not progressing either. Called gone, a resumable rollback is reported as
# unfinished, which is the false-report defect again. Called running, a rollback
# that is stopped forever is never reported, which is the zombie defect again.
# The asymmetry rule does not apply: stopped is not an unresolvable owner, it is
# a resolved state that happens to be neither. So it gets its own answer, the
# way the pre-guard gave "could not judge" its own answer instead of folding it
# into safe or unsafe. The three call for three different human actions: repair
# the tree, wait, or resume-or-kill and then repair.
#
# Exit status: 0 running, 1 gone, 2 stopped.
#
# pid reuse is the trap. A recycled pid belonging to some unrelated process
# would make a genuinely interrupted rollback look alive forever, which is the
# silent direction. Process start time settles it exactly: the owner was running
# before it wrote the entry, and a pid can only be recycled after its previous
# holder died — so anything that started after the entry was opened is a
# different process, and no other check is needed to know that.
safedeps_journal_owner_state() {
  local pid="$1"
  local opened_at="$2"
  local started_epoch opened_epoch

  [[ "${pid}" =~ ^[0-9]+$ ]] || return 1
  kill -0 "${pid}" 2>/dev/null || return 1

  # A zombie is not running, but it passes every other test here: it keeps its
  # process table entry, so `kill -0` succeeds, and it keeps its own start time,
  # so the reuse check clears it too. Measured — a hook that the runtime killed
  # and its parent has not reaped yet reads as alive, which is precisely the
  # case the journal exists to report. And a zombie does not go away on its own,
  # so this would suppress that report on every later command, not just once.
  #
  # Matched anywhere in the field rather than anchored: `ps` pads the column
  # differently across platforms (macOS gives a trailing run of spaces, others
  # can lead). `Z` only ever appears as the state character — the flag suffixes
  # are `<`, `N`, `L`, `s`, `l`, `+` — so a loose match cannot collide.
  local proc_stat
  proc_stat=$(ps -o stat= -p "${pid}" 2>/dev/null)
  case "${proc_stat}" in
    *Z*) return 1 ;;
    *T*) return 2 ;;
  esac

  # Without a start time this stays fail-loud (treated as dead), so a platform
  # that cannot answer reports rather than goes quiet.
  local lstart
  lstart=$(ps -o lstart= -p "${pid}" 2>/dev/null)
  [[ -n "${lstart}" ]] || return 1
  # GNU (`date -d`) first, then BSD/macOS (`date -j -f`), matching how the state
  # lock reads mtime from either stat.
  started_epoch=$(date -d "${lstart}" +%s 2>/dev/null) || \
    started_epoch=$(date -j -f '%a %b %d %T %Y' "${lstart}" +%s 2>/dev/null) || return 1
  [[ -n "${started_epoch}" ]] || return 1
  opened_epoch=$(safedeps_journal_epoch "${opened_at}") || return 1
  [[ -n "${opened_epoch}" ]] || return 1
  # No slack. Both timestamps come from the same system clock at second
  # resolution, and the owner necessarily started before it wrote its entry, so
  # equality is the widest this needs to be. Slack here would only buy a window
  # in which a recycled pid suppresses a real report.
  (( started_epoch <= opened_epoch )) || return 1

  return 0
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

    local entry_pid entry_opened
    entry_pid=$(jq -r '.pid // empty' "${entry}" 2>/dev/null)
    entry_opened=$(jq -r '.opened_at // empty' "${entry}" 2>/dev/null)
    # A rollback still running owns its entry. Skipping it is not a silent
    # fallback: the process that owns it will either close it on success or die
    # and leave it for the next hook to report.
    #
    # `|| owner_state=$?` rather than a bare call: this file is sourced into a
    # hook that runs under `set -e`, and every answer except "running" is a
    # non-zero status.
    local owner_state=0
    safedeps_journal_owner_state "${entry_pid}" "${entry_opened}" || owner_state=$?
    if [[ ${owner_state} -eq 0 ]]; then
      continue
    fi
    local owner_stopped=0
    if [[ ${owner_state} -eq 2 ]]; then
      owner_stopped=1
    fi

    found=0

    local journal_id project_dir rollback_snapshot reasons stage opened_at stage_at
    local stage_detail=""
    journal_id=$(jq -r '.journal_id // "unknown"' "${entry}" 2>/dev/null || printf 'unknown')
    project_dir=$(jq -r '.project_dir // "unknown"' "${entry}" 2>/dev/null || printf 'unknown')
    rollback_snapshot=$(jq -r '.rollback_snapshot // "unknown"' "${entry}" 2>/dev/null || printf 'unknown')
    reasons=$(jq -r '.reasons // "unrecorded"' "${entry}" 2>/dev/null || printf 'unrecorded')
    stage=$(jq -r '.stage // "unknown"' "${entry}" 2>/dev/null || printf 'unknown')
    opened_at=$(jq -r '.opened_at // "unknown"' "${entry}" 2>/dev/null || printf 'unknown')
    stage_at=$(jq -r '.stage_at // empty' "${entry}" 2>/dev/null)

    # How far the rollback got in time before its last stage change. This is
    # deliberately not "how long it was stuck there": nothing records when the
    # process died, and the report can arrive any number of commands later, so
    # the interval to now would be mostly idle time. What is knowable is when
    # the stage was entered and how long the phases before it took, which is
    # what separates "the restores were still running" from "the reinstall had
    # been going a while" — different repairs.
    if [[ -n "${stage_at}" ]]; then
      local opened_epoch stage_epoch
      if opened_epoch=$(safedeps_journal_epoch "${opened_at}") \
         && stage_epoch=$(safedeps_journal_epoch "${stage_at}"); then
        stage_detail=$(printf ', entered %s — %ds into the rollback' \
          "${stage_at}" "$(( stage_epoch - opened_epoch ))")
      else
        stage_detail=$(printf ', entered %s' "${stage_at}")
      fi
    fi

    mkdir -p "${SAFEDEPS_INCIDENT_DIR}" 2>/dev/null
    mv -f "${entry}" "${SAFEDEPS_INCIDENT_DIR}/${journal_id}.json" 2>/dev/null || rm -f "${entry}"

    local log_headline='REORG INTERRUPTED'
    if [[ ${owner_stopped} -eq 1 ]]; then
      log_headline="REORG STOPPED (owner pid ${entry_pid} is suspended, not dead)"
    fi

    cat >> "${reorg_log}" << LOG_EOF 2>/dev/null
[$(safedeps_journal_now_iso)] ${log_headline}
  Journal: ${journal_id} (opened ${opened_at}, reached stage: ${stage}${stage_detail})
  Project: ${project_dir}
  Rollback snapshot: ${rollback_snapshot}
  Reasons: ${reasons}
  Incident record: ${SAFEDEPS_INCIDENT_DIR}/${journal_id}.json
LOG_EOF

    local headline body_cause body_first_move
    if [[ ${owner_stopped} -eq 1 ]]; then
      headline="A safedeps rollback of ${project_dir} is stopped, not finished."
      body_cause="The process running it (pid ${entry_pid}) is suspended — it has not died, and
it is not progressing. Something sent it SIGSTOP or SIGTSTP, or it was stopped
from a shell job control."
      body_first_move="First decide what to do with that process. \`kill -CONT ${entry_pid}\` lets the
rollback finish on its own; killing it leaves the tree mixed and you repair it
as below. Until one of those happens, nothing about this project is settled."
    else
      headline="A safedeps rollback of ${project_dir} did not finish."
      body_cause="The rollback was cut off — most likely the hook hit the runtime's timeout
mid-rollback."
      body_first_move="Run \`npm ci\` in ${project_dir} to rebuild the tree from whichever lockfile is
there now, and check that the lockfile is the one you expect before you trust
it."
    fi

    report="${report}${headline}

safedeps found a suspicious dependency closure and started rolling the project
back to snapshot ${rollback_snapshot}, reaching stage '${stage}'
(started ${opened_at}${stage_detail}). ${body_cause}

Why it was rolled back:
${reasons}

What this means for the project: the dependency files and node_modules may be
in a mixed state — partly the rejected install, partly the snapshot.
${body_first_move}

Incident record: ${SAFEDEPS_INCIDENT_DIR}/${journal_id}.json
Rollback log: ${reorg_log}
"
  done

  [[ ${found} -eq 0 ]] || return 1
  printf '%s' "${report}"
  return 0
}
