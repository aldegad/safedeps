#!/usr/bin/env bash
# Run the daily safedeps watch scan (`safedeps watch scan`: the ledger re-check,
# then every project root and runtime) and notify only when attention is needed.
#
# Each run appends one line to recheck.log with its status and the runtime it
# ran (`runtime_version`, from the .safedeps-runtime.json the installer wrote),
# then the scan's report. Exit 75 is a scan that found the watch lock held: no
# result, retried by the next schedule, and the consumer's watchdog sees the age.

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SAFEDEPS_BIN="${SAFEDEPS_BIN:-${ROOT_DIR}/bin/safedeps}"
SAFEDEPS_HOME="${SAFEDEPS_HOME:-${HOME}/.safedeps}"
SAFEDEPS_RECHECK_LOG="${SAFEDEPS_RECHECK_LOG:-${SAFEDEPS_HOME}/recheck.log}"
SAFEDEPS_RECHECK_ERR_LOG="${SAFEDEPS_RECHECK_ERR_LOG:-${SAFEDEPS_HOME}/recheck.err.log}"
SAFEDEPS_RECHECK_ALERTS="${SAFEDEPS_RECHECK_ALERTS:-${SAFEDEPS_HOME}/recheck-alerts.jsonl}"
SAFEDEPS_NOTIFY="${SAFEDEPS_NOTIFY:-1}"

mkdir -p "${SAFEDEPS_HOME}" "$(dirname "${SAFEDEPS_RECHECK_LOG}")" "$(dirname "${SAFEDEPS_RECHECK_ALERTS}")"

now_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

notify() {
  local title="$1"
  local message="$2"

  [[ "${SAFEDEPS_NOTIFY}" == "1" ]] || return 0
  command -v osascript >/dev/null 2>&1 || return 0

  osascript - "${title}" "${message}" <<'OSA' >/dev/null 2>&1 || true
on run argv
  display notification (item 2 of argv) with title (item 1 of argv)
end run
OSA
}

append_alert() {
  local alert_json="$1"
  printf '%s\n' "${alert_json}" >> "${SAFEDEPS_RECHECK_ALERTS}"
}

tmp_root="${TMPDIR:-/tmp}"
mkdir -p "${tmp_root}"
tmp_json=$(mktemp "${tmp_root%/}/safedeps-recheck.XXXXXX")
tmp_err=$(mktemp "${tmp_root%/}/safedeps-recheck-err.XXXXXX")
tmp_scan=$(mktemp "${tmp_root%/}/safedeps-watch.XXXXXX")
cleanup() {
  rm -f "${tmp_json}" "${tmp_err}" "${tmp_scan}"
}
trap cleanup EXIT

run_at=$(now_utc)
status=0
runtime_version=$(jq -r '.version // empty' "${ROOT_DIR}/.safedeps-runtime.json" 2>/dev/null) \
  || runtime_version=""
[[ -n "${runtime_version}" ]] || runtime_version="checkout"

# The scan's report carries the ledger re-check's report as `.ledger`; the
# fixture is a ledger report, put where the scan would put it.
if [[ -n "${SAFEDEPS_RECHECK_FIXTURE_JSON:-}" ]]; then
  jq -c '{command:"watch scan", exit:0, ledger:., errors:[], new_events:0, population:null, summary:null}' \
    "${SAFEDEPS_RECHECK_FIXTURE_JSON}" > "${tmp_scan}"
else
  "${SAFEDEPS_BIN}" --json watch scan > "${tmp_scan}" 2> "${tmp_err}" || status=$?
fi
jq -c '.ledger // empty' "${tmp_scan}" > "${tmp_json}" 2>/dev/null || : > "${tmp_json}"

{
  printf '[%s] safedeps re-check status=%s runtime_version=%s\n' "${run_at}" "${status}" "${runtime_version}"
  cat "${tmp_scan}" 2>/dev/null || true
  printf '\n'
} >> "${SAFEDEPS_RECHECK_LOG}"

if [[ "${status}" -eq 75 ]]; then
  append_alert "$(jq -cn --arg at "${run_at}" '{kind:"recheck_busy", at:$at, exit_status:75}')"
  exit 75
fi

# A scan that published with errors (exit 1) still has a report: it is read
# below, and the run then exits 1. No report is the failure it always was.
if [[ "${status}" -eq 1 ]] && jq -e '.command == "watch scan" and (.generation | type) == "number"' "${tmp_scan}" >/dev/null 2>&1; then
  scan_errors=1
  status=0
else
  scan_errors=0
fi

if [[ -s "${tmp_err}" ]]; then
  {
    printf '[%s] safedeps re-check stderr\n' "${run_at}"
    cat "${tmp_err}"
    printf '\n'
  } >> "${SAFEDEPS_RECHECK_ERR_LOG}"
fi

if [[ "${status}" -ne 0 ]]; then
  alert=$(jq -cn \
    --arg at "${run_at}" \
    --argjson status "${status}" \
    --rawfile stderr "${tmp_err}" \
    '{kind:"recheck_failed", at:$at, exit_status:$status, stderr:$stderr}')
  append_alert "${alert}"
  notify "safedeps re-check failed" "Daily dependency approval re-check exited ${status}. See ~/.safedeps/recheck.err.log"
  exit "${status}"
fi

# The report's fields are declared in lib/ledger/recheck-report.sh, beside the
# real file of this script, and are read only now. A runtime without lib/ fails
# the run above, and that is the recheck_failed alert it has always been.
report_source="${BASH_SOURCE[0]}"
while [[ -h "${report_source}" ]]; do
  report_dir=$(cd -P -- "$(dirname "${report_source}")" >/dev/null && pwd)
  report_source=$(readlink "${report_source}")
  [[ "${report_source}" != /* ]] && report_source="${report_dir}/${report_source}"
done
report_declaration="$(cd -P -- "$(dirname "${report_source}")/.." >/dev/null && pwd)/lib/ledger/recheck-report.sh"
# The declaration is tried in a subshell first: under bash 3.2 a source that
# cannot read or parse its file ends this script, alert unwritten.
# shellcheck source=../lib/ledger/recheck-report.sh
if ! ( source "${report_declaration}" && [[ -n "${SAFEDEPS_RECHECK_REPORT_JQ:-}" ]] ) >/dev/null 2>&1; then
  alert=$(jq -cn \
    --arg at "${run_at}" \
    --arg stderr "cannot read ${report_declaration}" \
    '{kind:"recheck_failed", at:$at, exit_status:1, stderr:$stderr}')
  append_alert "${alert}"
  notify "safedeps re-check failed" "The re-check wrapper cannot read its report declaration. See ~/.safedeps/recheck-alerts.jsonl"
  exit 1
fi
# shellcheck source=../lib/ledger/recheck-report.sh
source "${report_declaration}"

if ! jq -e "${SAFEDEPS_RECHECK_REPORT_JQ}"'recheck_is_report' "${tmp_json}" >/dev/null 2>&1; then
  alert=$(jq -cn \
    --arg at "${run_at}" \
    --rawfile output "${tmp_json}" \
    '{kind:"recheck_invalid_output", at:$at, output:$output}')
  append_alert "${alert}"
  notify "safedeps re-check failed" "Daily re-check returned invalid JSON. See ~/.safedeps/recheck.log"
  exit 1
fi

checked=$(jq -r "${SAFEDEPS_RECHECK_REPORT_JQ}"'recheck_checked' "${tmp_json}")
still_clean=$(jq -r "${SAFEDEPS_RECHECK_REPORT_JQ}"'recheck_still_clean' "${tmp_json}")
newly_vulnerable=$(jq -r "${SAFEDEPS_RECHECK_REPORT_JQ}"'recheck_newly_vulnerable | length' "${tmp_json}")
kev_hit=$(jq -r "${SAFEDEPS_RECHECK_REPORT_JQ}"'recheck_kev_hit | length' "${tmp_json}")
revoked=$(jq -r "${SAFEDEPS_RECHECK_REPORT_JQ}"'recheck_revoked | length' "${tmp_json}")
suspected_forgery=$(jq -r "${SAFEDEPS_RECHECK_REPORT_JQ}"'recheck_suspected_forgery | length' "${tmp_json}")
skipped=$(( checked - still_clean - revoked ))
if [[ "${skipped}" -lt 0 ]]; then
  skipped=0
fi

if [[ "${newly_vulnerable}" -gt 0 || "${kev_hit}" -gt 0 || "${revoked}" -gt 0 || "${skipped}" -gt 0 || "${suspected_forgery}" -gt 0 ]]; then
  alert=$(jq -c \
    --arg at "${run_at}" \
    --argjson skipped "${skipped}" \
    '. + {kind:"recheck_attention", at:$at, provider_skipped:$skipped}' \
    "${tmp_json}")
  append_alert "${alert}"

  message="${revoked} revoked, ${newly_vulnerable} new CVE, ${kev_hit} KEV"
  if [[ "${skipped}" -gt 0 ]]; then
    message="${message}, ${skipped} provider skipped"
  fi
  if [[ "${suspected_forgery}" -gt 0 ]]; then
    message="${message}, ${suspected_forgery} suspected ledger forgery"
  fi
  notify "safedeps attention needed" "${message}. See ~/.safedeps/recheck-alerts.jsonl"
fi

# The watch's own news: new findings or transitions, a population that is not
# fresh, errors the scan published with, a runtime that no longer matches its
# checkout. A runtime whose checkout could not be read is neither stale nor
# fresh: the report says null, the record keeps null and the sentence says
# unknown. Each says itself once; the consumer delivers the events. Roots the
# walk did not finish come first, with what find said about the first of
# them: a run that read none of them otherwise reads as one that found
# nothing. The record keeps the sentence the notification showed.
if [[ -z "${SAFEDEPS_RECHECK_FIXTURE_JSON:-}" ]]; then
  watch_alert=$(jq -c --arg at "${run_at}" '
    select((.new_events // 0) > 0 or ((.population.state // "fresh") != "fresh") or ((.errors // []) | length) > 0
           or (.agent_runtime_stale == true))
    | ([(.errors // [])[] | select(.kind == "root_walk_incomplete")]) as $walk
    | ((.summary.roots_walked // 0) + (.summary.roots_walk_incomplete // 0)) as $roots
    | {kind:"watch_attention", at:$at, new_events, population:.population.state, errors:(.errors | length),
       agent_runtime_stale, summary:.summary.line,
       walk_incomplete:($walk | length), roots:$roots,
       first_walk_incomplete:($walk | first | if . == null then null else {root, exit, said} end)}
    | . + {message: ((if .walk_incomplete > 0 then
                        "\(.walk_incomplete) of \(.roots) roots not read in full ("
                        + (.first_walk_incomplete.said[0]? // "exit \(.first_walk_incomplete.exit), nothing said")
                        + "); what find could not read in them was not checked. "
                      else "" end)
                     + "\(.new_events) new, population \(.population), \(.errors) errors"
                     + (if .agent_runtime_stale == true then ", agent runtime stale"
                        elif .agent_runtime_stale == null then ", agent runtime stale unknown" else "" end))}' "${tmp_scan}" 2>/dev/null) || watch_alert=""
  if [[ -n "${watch_alert}" ]]; then
    append_alert "${watch_alert}"
    notify "safedeps watch" "$(jq -r '.message' <<< "${watch_alert}")"
  fi
fi

[[ "${scan_errors}" -eq 0 ]] || exit 1
