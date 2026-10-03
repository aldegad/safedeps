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

# The report says what the rollback says, in the same closed set of lines
# (report-facts.sh), and names a linked node_modules by where it leads
# (safedeps_link_target).
# shellcheck source=./npm-reach.sh
source "$(dirname "${BASH_SOURCE[0]}")/npm-reach.sh"
# shellcheck source=./report-facts.sh
source "$(dirname "${BASH_SOURCE[0]}")/report-facts.sh"

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
# Exit status: 0 running, 1 gone, 2 stopped. Whatever the answer, the test
# that gave it is left in SAFEDEPS_JOURNAL_OWNER_FACT, and the report prints
# that and nothing else about the owner: "gone" is five different findings (no
# such process, a zombie, a start time ps does not give or that cannot be
# parsed, a process that started after the entry was opened), and a report that
# called all of them "not running" was false for a recycled pid.
#
# pid reuse is the trap. A recycled pid belonging to some unrelated process
# would make a genuinely interrupted rollback look alive forever, which is the
# silent direction. Process start time settles it exactly: the owner was running
# before it wrote the entry, and a pid can only be recycled after its previous
# holder died — so anything that started after the entry was opened is a
# different process, and no other check is needed to know that.
SAFEDEPS_JOURNAL_OWNER_FACT=""
safedeps_journal_owner_state() {
  local pid="$1"
  local opened_at="$2"
  local started_epoch opened_epoch

  SAFEDEPS_JOURNAL_OWNER_FACT="the journal records no pid"
  [[ "${pid}" =~ ^[0-9]+$ ]] || return 1
  SAFEDEPS_JOURNAL_OWNER_FACT="pid ${pid} is not running"
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
  # can lead). The claim a loose match rests on is narrow and is only about the
  # two letters read here: no platform uses `Z`, `T` or `t` as a trailing flag,
  # so they appear only as the state character. It is deliberately not a claim
  # that the flag set is enumerable — macOS alone adds `V X A E S W >` beyond
  # the usual `< N L s l +`, and an enumeration offered as the reason would go
  # stale the first time a platform grew one.
  local proc_stat
  proc_stat=$(ps -o stat= -p "${pid}" 2>/dev/null)
  proc_stat="${proc_stat//[[:space:]]/}"
  case "${proc_stat}" in
    *Z*)
      SAFEDEPS_JOURNAL_OWNER_FACT="pid ${pid} is a zombie (ps state ${proc_stat})"
      return 1 ;;
  esac

  # Without a start time this stays fail-loud (treated as dead), so a platform
  # that cannot answer reports rather than goes quiet.
  local lstart
  SAFEDEPS_JOURNAL_OWNER_FACT="ps gives no start time for pid ${pid}"
  lstart=$(ps -o lstart= -p "${pid}" 2>/dev/null)
  [[ -n "${lstart}" ]] || return 1
  # GNU (`date -d`) first, then BSD/macOS (`date -j -f`), matching how the state
  # lock reads mtime from either stat.
  SAFEDEPS_JOURNAL_OWNER_FACT="the start time ps gives for pid ${pid} cannot be parsed"
  started_epoch=$(date -d "${lstart}" +%s 2>/dev/null) || \
    started_epoch=$(date -j -f '%a %b %d %T %Y' "${lstart}" +%s 2>/dev/null) || return 1
  [[ -n "${started_epoch}" ]] || return 1
  SAFEDEPS_JOURNAL_OWNER_FACT="the opening time of the journal cannot be parsed"
  opened_epoch=$(safedeps_journal_epoch "${opened_at}") || return 1
  [[ -n "${opened_epoch}" ]] || return 1
  # No slack. Both timestamps come from the same system clock at second
  # resolution, and the owner necessarily started before it wrote its entry, so
  # equality is the widest this needs to be. Slack here would only buy a window
  # in which a recycled pid suppresses a real report.
  SAFEDEPS_JOURNAL_OWNER_FACT="pid ${pid} started after the journal was opened"
  (( started_epoch <= opened_epoch )) || return 1

  # Stopped is judged only AFTER the pid is confirmed to be this entry's owner.
  # Ahead of that check it answered for any process holding a recycled pid, so a
  # genuinely interrupted rollback whose pid had been taken over by some
  # unrelated stopped process was reported as "suspended — resume it", which
  # sends a signal to a bystander and defers the repair the project actually
  # needs. Measured against 001a715, which answered "gone" on the same input.
  #
  # The zombie check above stays where it is, and the asymmetry is the point:
  # a zombie keeps its own start time, so it would pass the comparison below and
  # has to be caught before it. A stopped process proves nothing about identity.
  #
  # Linux marks a debugger-stopped process `t`, macOS uses `T`; neither uses the
  # other letter as a flag, so both are matched.
  case "${proc_stat}" in
    *T*|*t*)
      SAFEDEPS_JOURNAL_OWNER_FACT="pid ${pid} is stopped (ps state ${proc_stat})"
      return 2 ;;
  esac

  SAFEDEPS_JOURNAL_OWNER_FACT="pid ${pid} is running"
  return 0
}

# What a project holds at report time, one line per test run here. The report
# gives no command and no cause: where a reinstall would write is npm's to
# decide -- a bare npm ci in a workspace member empties the workspace root's
# node_modules -- and why the rollback stopped is not something this hook saw.
#
# It says what node_modules is, and then only the monitored files that are not
# what the snapshot holds. A file that matches is not a line: twenty lines of
# "the same" hid the two that were not. The names come from the snapshot's own
# list of monitored files, never from the snapshot's directory, whose other
# files (the package and binary listings, the meta record) are not project
# files and read as missing ones when they were listed.
#
# safedeps_journal_project_facts <project dir> <snapshot id>
safedeps_journal_project_facts() {
  local dir="$1" snap="$2" name stored
  local snapdir="${SAFEDEPS_JOURNAL_HOME}/snapshots"
  local list="${snapdir}/${snap}_monitored_files.list"

  printf '%s\n' "$(fact_path "${dir}/node_modules")"
  if [[ ! -f "${list}" ]]; then
    printf 'the snapshot %s has no list of monitored files\n' "${snap}"
    return 0
  fi
  while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    case "${name}" in
      */*) stored="${snapdir}/${snap}_${SAFEDEPS_SNAPSHOT_MEMBERS:-members}/${name}" ;;
      *) stored="${snapdir}/${snap}_${name}" ;;
    esac
    if [[ -L "${dir}/${name}" ]]; then
      printf '%s\n' "$(fact_path "${dir}/${name}")"
    elif [[ -f "${stored}" ]]; then
      if [[ ! -e "${dir}/${name}" ]]; then
        printf '%s does not exist; the snapshot %s has it\n' "${dir}/${name}" "${snap}"
      elif ! report_same_bytes "${stored}" "${dir}/${name}"; then
        printf '%s differs from the snapshot %s\n' "${dir}/${name}" "${snap}"
      fi
    elif [[ -f "${stored}.missing" && -e "${dir}/${name}" ]]; then
      printf '%s exists; the snapshot %s recorded it as absent\n' "${dir}/${name}" "${snap}"
    fi
  done < <(sort -u "${list}")
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
    local owner_fact="${SAFEDEPS_JOURNAL_OWNER_FACT}"

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
        # A corrupt entry can carry a stage_at older than its opened_at, and
        # "-7s into the rollback" would read as a tool bug rather than as bad
        # data. Both stamps come from one process on one clock, so this is not
        # a reachable path — it is just not worth printing nonsense over.
        if (( stage_epoch >= opened_epoch )); then
          stage_detail=$(printf ', entered %s — %ds into the rollback' \
            "${stage_at}" "$(( stage_epoch - opened_epoch ))")
        else
          stage_detail=$(printf ', entered %s' "${stage_at}")
        fi
      else
        stage_detail=$(printf ', entered %s' "${stage_at}")
      fi
    fi

    mkdir -p "${SAFEDEPS_INCIDENT_DIR}" 2>/dev/null
    mv -f "${entry}" "${SAFEDEPS_INCIDENT_DIR}/${journal_id}.json" 2>/dev/null || rm -f "${entry}"

    # A stopped owner is its own headline in the log and in the report: it has
    # not died, so "did not finish" would be said of a rollback SIGCONT resumes.
    local log_headline='REORG INTERRUPTED' headline="did not finish"
    if [[ ${owner_state} -eq 2 ]]; then
      log_headline='REORG STOPPED'
      headline="has not finished"
    fi

    local journal_line incident_line
    journal_line="Journal: ${journal_id}, opened ${opened_at}; last recorded stage ${stage}${stage_detail}"
    incident_line=$(fact_file "Incident record" "${SAFEDEPS_INCIDENT_DIR}/${journal_id}.json")

    cat >> "${reorg_log}" << LOG_EOF 2>/dev/null
[$(safedeps_journal_now_iso)] ${log_headline}
  ${journal_line}
  Owner: ${owner_fact}
  Project: ${project_dir}
  Rollback snapshot: ${rollback_snapshot}
  Reasons: ${reasons}
  ${incident_line}
LOG_EOF

    report="${report}${report:+
}safedeps: a rollback of ${project_dir} ${headline}.

${journal_line}
Owner: ${owner_fact}
Rollback snapshot: ${rollback_snapshot}
Recorded reasons:
${reasons}

Checked at the time of this report:
$(safedeps_journal_project_facts "${project_dir}" "${rollback_snapshot}")

${incident_line}
$(fact_file "Rollback log" "${reorg_log}")
"
  done

  [[ ${found} -eq 0 ]] || return 1
  printf '%s' "${report}"
  return 0
}
