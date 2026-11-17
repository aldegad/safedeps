#!/usr/bin/env bash
# safedeps watch: the daily scan of the ledger, the registered projects and the
# host's JDKs, its state and its hand-off to a consumer (`safedeps watch ...`),
# and the lock every re-check runs under (`locked re-check`).
#
# bin/safedeps runs this file with exec, as it runs the release-time gates, and
# passes the two things it cannot read for itself: SAFEDEPS_VERSION and
# SAFEDEPS_JSON_MODE. The CLI sources none of lib/watch/, so the files the core's
# tests read as the CLI (rust/src/cli_text.rs) stay what the CLI sources. The
# ledger stage of a scan is the CLI's own `re-check`, run as a child under the
# lock this process holds.
set -euo pipefail

SAFEDEPS_REPO_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SAFEDEPS_VERSION="${SAFEDEPS_VERSION:-unknown}"
SAFEDEPS_JSON_MODE="${SAFEDEPS_JSON_MODE:-0}"
SAFEDEPS_HOME="${SAFEDEPS_HOME:-${HOME}/.safedeps}"
SAFEDEPS_SD="${SAFEDEPS_REPO_DIR}/bin/safedeps"

watch_say() { printf 'safedeps watch: %s\n' "$*" >&2; }

# shellcheck source=lock.sh
source "${SAFEDEPS_REPO_DIR}/lib/watch/lock.sh"

# Takes the watch lock for COMMAND, or says why not and returns its code.
watch_lock_or_refuse() {
  local lock_rc=0
  safedeps_watch_lock_acquire || lock_rc=$?
  [[ "${lock_rc}" -eq 0 ]] && return 0
  watch_say "another watch writer holds $(safedeps_watch_dir)/lock"
  [[ "${SAFEDEPS_JSON_MODE}" != 1 ]] || safedeps_watch_lock_refusal_json "$1" "${lock_rc}"
  return "${lock_rc}"
}

# `locked COMMAND...`: the CLI's COMMAND, run as this process's child while it
# holds the lock. The child inherits fd 9, so the lock is held until both are
# done, and it knows the lock is held because SAFEDEPS_WATCH_LOCK_HELD names
# its parent.
if [[ "${1:-}" == locked ]]; then
  shift
  [[ $# -gt 0 ]] || { watch_say "locked needs a command"; exit 4; }
  watch_lock_or_refuse "$1" || exit $?
  locked_json=()
  [[ "${SAFEDEPS_JSON_MODE}" != 1 ]] || locked_json=(--json)
  locked_rc=0
  SAFEDEPS_WATCH_LOCK_HELD=$$ "${SAFEDEPS_SD}" "${locked_json[@]+"${locked_json[@]}"}" "$@" || locked_rc=$?
  exit "${locked_rc}"
fi

# shellcheck source=../providers/providers.sh
source "${SAFEDEPS_REPO_DIR}/lib/providers/providers.sh"
# shellcheck source=../ledger/ledger.sh
source "${SAFEDEPS_REPO_DIR}/lib/ledger/ledger.sh"
# shellcheck source=../npm/closure.sh
source "${SAFEDEPS_REPO_DIR}/lib/npm/closure.sh"
SAFEDEPS_LEDGER_DIR="${SAFEDEPS_LEDGER_DIR:-${SAFEDEPS_HOME}/approved-specs}"
SAFEDEPS_ADVISORY_LOG="${SAFEDEPS_HOME}/advisory.log"
for watch_lib in mounts population lockfiles runtime scan; do
  # shellcheck source=/dev/null
  source "${SAFEDEPS_REPO_DIR}/lib/watch/${watch_lib}.sh"
done

# Publishes the current document transformed by a state.jq FILTER, under the
# lock the caller holds. ARGS go to jq before the filter.
watch_transform() {
  local filter="$1" doc prior tmp
  shift
  prior=$(safedeps_watch_read_state) || { watch_say "state unreadable"; return 3; }
  tmp=$(safedeps_provider_mktemp_dir) || return 3
  doc="${tmp}/next.json"
  if ! safedeps_watch_jq -c "$@" 'include "state"; '"${filter}"' | .generation += 1 | . + {summary: summary}' <<< "${prior}" > "${doc}"; then
    rm -rf "${tmp}"
    return 1
  fi
  safedeps_watch_publish "${doc}" || { rm -rf "${tmp}"; return 3; }
  cat "${doc}"
  rm -rf "${tmp}"
}

watch_main() {
  local sub="${1:-}" root="" consumer="" limit=20 event="" task="" outcome="" finding="" state="" detail="" evidence=""
  [[ $# -gt 0 ]] && shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --root) root="${2:-}"; shift 2 ;;
      --consumer) consumer="${2:-}"; shift 2 ;;
      --limit) limit="${2:-}"; shift 2 ;;
      --event) event="${2:-}"; shift 2 ;;
      --task) task="${2:-}"; outcome="dispatched"; shift 2 ;;
      --unknown) outcome="unknown"; shift ;;
      --finding) finding="${2:-}"; shift 2 ;;
      --state) state="${2:-}"; shift 2 ;;
      --detail) detail="${2:-}"; shift 2 ;;
      --evidence) evidence="${2:-}"; shift 2 ;;
      -h|--help) exec "${SAFEDEPS_SD}" help watch ;;
      *) watch_say "unexpected arg for watch ${sub}: $1"; return 4 ;;
    esac
  done
  command -v jq >/dev/null 2>&1 || { watch_say "jq is required"; return 4; }
  local now rc=0
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  case "${sub}" in
    scan)
      if [[ -n "${root}" ]]; then
        [[ "${root}" == /* ]] || { watch_say "scan --root needs an absolute path"; return 4; }
        while [[ "${root}" == */ && "${root}" != / ]]; do root="${root%/}"; done
      fi
      safedeps_watch_pause before_lock
      watch_lock_or_refuse "watch scan" || return $?
      safedeps_watch_scan "$([[ -n "${root}" ]] && echo root || echo full)" "${root}" || rc=$?
      return "${rc}"
      ;;
    status)
      local doc
      doc=$(safedeps_watch_read_state) || { jq -nc '{command:"watch status", error:"state_unreadable"}'; return 3; }
      # One reading of one generation. last_full_scan and awaiting_owner are
      # state.jq's definitions; a reader takes them by name.
      safedeps_watch_jq -c --arg now "${now}" --arg runs "$(safedeps_watch_dir)/runs" --arg last_receipt "$(ls -1 "$(safedeps_watch_dir)/runs" 2>/dev/null | grep '\.json$' | LC_ALL=C sort | tail -1)" 'include "state";
        def hours_since($ts): if $ts == null then null else ((($now | fromdateiso8601) - ($ts | fromdateiso8601)) / 3600 | floor) end;
        {command: "watch status", generation, scan_generation, last_scan, last_success_at,
         age_hours: hours_since(.last_scan.finished_at),
         success_age_hours: hours_since(.last_success_at),
         last_full_scan: (.last_full_scan // null),
         full_age_hours: hours_since(.last_full_scan.finished_at),
         population: (.population | if . == null then null else {state, count, excluded, generated_at, reason} end),
         summary, errors, awaiting_owner: awaiting_owner,
         last_receipt: (if $last_receipt == "" then null else ($runs + "/" + $last_receipt) end)}' <<< "${doc}"
      ;;
    claim)
      [[ -n "${consumer}" && "${limit}" =~ ^[0-9]+$ ]] || { watch_say "usage: safedeps watch claim --consumer ID [--limit N]"; return 4; }
      watch_lock_or_refuse "watch claim" || return $?
      local next
      local token="${now}-$$-${RANDOM}"
      next=$(watch_transform 'claim_events($consumer; $limit; $now; $token)' --arg consumer "${consumer}" --argjson limit "${limit}" \
        --arg now "${now}" --arg token "${token}") || return $?
      safedeps_watch_jq -c --arg consumer "${consumer}" --arg token "${token}" 'include "state";
        . as $d | {command: "watch claim", consumer: $consumer, generation,
                   claimed: [claimed_by($consumer)[] | select(.claim.token == $token) | . + {finding_record: $d.findings[.finding]}]}' <<< "${next}"
      ;;
    claimed)
      [[ -n "${consumer}" ]] || { watch_say "usage: safedeps watch claimed --consumer ID"; return 4; }
      safedeps_watch_read_state | safedeps_watch_jq -c --arg consumer "${consumer}" 'include "state";
        . as $d | {command: "watch claimed", consumer: $consumer, claimed: [claimed_by($consumer)[] | . + {finding_record: $d.findings[.finding]}]}'
      ;;
    ack)
      [[ -n "${event}" && -n "${consumer}" && -n "${outcome}" ]] || { watch_say "usage: safedeps watch ack --event ID --consumer ID (--task TASK | --unknown)"; return 4; }
      watch_lock_or_refuse "watch ack" || return $?
      watch_transform 'ack_event($id; $consumer; $outcome; (if $task == "" then null else $task end); $now)' \
        --arg id "${event}" --arg consumer "${consumer}" --arg outcome "${outcome}" --arg task "${task}" --arg now "${now}" > /dev/null || return $?
      jq -nc --arg id "${event}" --arg outcome "${outcome}" --arg task "${task}" '{command:"watch ack", event:$id, status:$outcome, task:(if $task == "" then null else $task end)}'
      ;;
    remediation)
      [[ -n "${finding}" && -n "${state}" ]] || { watch_say "usage: safedeps watch remediation --finding KEY --state STATE [--detail TEXT] [--task TASK]"; return 4; }
      watch_lock_or_refuse "watch remediation" || return $?
      watch_transform 'set_remediation($key; $state; $detail; (if $task == "" then null else $task end); $now)' \
        --arg key "${finding}" --arg state "${state}" --arg detail "${detail}" --arg task "${task}" --arg now "${now}" > /dev/null || return $?
      jq -nc --arg key "${finding}" --arg state "${state}" '{command:"watch remediation", finding:$key, state:$state}'
      ;;
    retire)
      [[ "${root}" == /* && -n "${evidence}" ]] || { watch_say "usage: safedeps watch retire --root DIR --evidence TEXT"; return 4; }
      [[ "${root}${evidence}" != *$'\n'* && "${root}" != *$'\t'* ]] || { watch_say "retire takes one line"; return 4; }
      watch_lock_or_refuse "watch retire" || return $?
      printf '%s\t%s\n' "${root}" "${evidence}" >> "$(safedeps_watch_dir)/retired" || return 1
      jq -nc --arg root "${root}" --arg evidence "${evidence}" '{command:"watch retire", root:$root, evidence:$evidence, note:"closed as root_retired by the next scan"}'
      ;;
    *)
      watch_say "usage: safedeps watch <scan|status|claim|claimed|ack|remediation|retire> (safedeps help watch)"
      return 4
      ;;
  esac
}

watch_rc=0
watch_main "$@" || watch_rc=$?
exit "${watch_rc}"
