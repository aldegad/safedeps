#!/usr/bin/env bash
# Run safedeps re-check and notify only when attention is needed.

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
cleanup() {
  rm -f "${tmp_json}" "${tmp_err}"
}
trap cleanup EXIT

run_at=$(now_utc)
status=0

if [[ -n "${SAFEDEPS_RECHECK_FIXTURE_JSON:-}" ]]; then
  cat "${SAFEDEPS_RECHECK_FIXTURE_JSON}" > "${tmp_json}"
else
  "${SAFEDEPS_BIN}" re-check --json > "${tmp_json}" 2> "${tmp_err}" || status=$?
fi

{
  printf '[%s] safedeps re-check status=%s\n' "${run_at}" "${status}"
  cat "${tmp_json}" 2>/dev/null || true
  printf '\n'
} >> "${SAFEDEPS_RECHECK_LOG}"

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

if ! jq -e '.command == "re-check"' "${tmp_json}" >/dev/null 2>&1; then
  alert=$(jq -cn \
    --arg at "${run_at}" \
    --rawfile output "${tmp_json}" \
    '{kind:"recheck_invalid_output", at:$at, output:$output}')
  append_alert "${alert}"
  notify "safedeps re-check failed" "Daily re-check returned invalid JSON. See ~/.safedeps/recheck.log"
  exit 1
fi

checked=$(jq -r '.checked // 0' "${tmp_json}")
still_clean=$(jq -r '.still_clean // 0' "${tmp_json}")
newly_vulnerable=$(jq -r '(.newly_vulnerable // []) | length' "${tmp_json}")
kev_hit=$(jq -r '(.kev_hit // []) | length' "${tmp_json}")
revoked=$(jq -r '(.revoked // []) | length' "${tmp_json}")
suspected_forgery=$(jq -r '(.suspected_forgery // []) | length' "${tmp_json}")
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
