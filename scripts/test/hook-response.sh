#!/usr/bin/env bash
# The response reader's byte and type contract, independent of any real hook.
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
source "${ROOT_DIR}/scripts/test/lib/hook-response.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/hook-response.XXXXXX")
trap 'rm -rf "${tmp}"' EXIT

check() {
  local label="$1" body="$2" quiet="$3" decision="$4" mode want got
  printf '%s' "${body}" > "${tmp}/stdout"
  for mode in quiet decision; do
    hook_response_init "${tmp}/failures"
    case "${mode}" in quiet) want="${quiet}" ;; decision) want="${decision}" ;; esac
    got=red
    if hook_response_parse "${tmp}/stdout" "${mode}" 2> "${tmp}/diagnostic"; then got=green; fi
    if [[ "${got}" != "${want}" ]]; then
      printf 'not ok - %s / %s: expected %s, got %s\n' "${label}" "${mode}" "${want}" "${got}"
      exit 1
    fi
    printf 'ok - %s / %s: %s\n' "${label}" "${mode}" "${got}"
  done
}
check empty '' green red
check newline $'\n' red red
check whitespace '   ' red red
check non-json 'not JSON' red red
check array '[]' red red
check two-objects '{}{}' red red
check trailing-junk '{"hookSpecificOutput":{"permissionDecision":"allow"}} junk' red red
check invalid-decision '{"hookSpecificOutput":{"permissionDecision":"pass"}}' red red
check non-string-rewrite '{"hookSpecificOutput":{"permissionDecision":"allow","updatedInput":{"command":3}}}' red red
check non-string-reason '{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":[]}}' red red
check missing-decision '{}' red red
for decision in allow deny ask; do
  check "${decision}" "{\"hookSpecificOutput\":{\"permissionDecision\":\"${decision}\"}}" red green
done
check rewrite '{"hookSpecificOutput":{"permissionDecision":"allow","updatedInput":{"command":"npm ci --ignore-scripts"}}}' red green

stub() { printf '\n'; printf 'diagnostic\n' >&2; return 7; }
rc=0
response=$(hook_response_capture "${tmp}/capture" stub) || rc=$?
[[ "${rc}" == 7 && "$(hook_response_status "${tmp}/capture")" == 7 ]] || exit 1
[[ -s "${response}" && "$(hook_response_stderr "${tmp}/capture")" == diagnostic ]] || exit 1
printf 'ok - capture keeps newline bytes, stderr and exit status\n'
