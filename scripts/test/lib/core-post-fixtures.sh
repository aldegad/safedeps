#!/usr/bin/env bash
# Test-only native fixture selection. Product hooks never read these variables.
native_fixtures_init() {
  local out="$1" platform
  if [[ -z "${SAFEDEPS_TEST_FIXTURES:-}" ]]; then
    case "$(uname -s)-$(uname -m)" in
      Darwin-arm64) platform=darwin-arm64 ;;
      Darwin-x86_64) platform=darwin-x64 ;;
      Linux-x86_64) platform=linux-x64 ;;
      *) printf 'native fixtures: unsupported host\n' >&2; return 1 ;;
    esac
    SAFEDEPS_TEST_FIXTURES=$(python3 "${ROOT_DIR}/scripts/measure/core-post-test-fixtures.py" prepare \
      --tree "${ROOT_DIR}" --core "${ROOT_DIR}/bin/native/${platform}/safedeps-core" --output "${out}") || return
    export SAFEDEPS_TEST_FIXTURES
  fi
  NATIVE_TEST_CORE=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["core"])' "${SAFEDEPS_TEST_FIXTURES}") || return
  NATIVE_COPY_SKIP_REASON=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("copies_unavailable", ""))' "${SAFEDEPS_TEST_FIXTURES}") || return
  SAFEDEPS_TEST_FAILURES="${out}.failures.jsonl"
  : > "${SAFEDEPS_TEST_FAILURES}"
  export NATIVE_TEST_CORE SAFEDEPS_TEST_FAILURES
}
native_fixture_hook() {
  python3 "${ROOT_DIR}/scripts/measure/core-post-test-fixtures.py" checked-hook \
    --manifest "${SAFEDEPS_TEST_FIXTURES}" --stage "$1"
}
native_fixtures_assert() {
  if [[ -s "${SAFEDEPS_TEST_FAILURES:-/dev/null}" ]]; then
    cat "${SAFEDEPS_TEST_FAILURES}" >&2
    return 1
  fi
}

# These return false only for an observed missing capability. A failed probe
# remains a failed test, not a reason to skip it.
native_copies_available() {
  NATIVE_SKIP_REASON="${NATIVE_COPY_SKIP_REASON}"
  [[ -z "${NATIVE_SKIP_REASON}" ]]
}
native_permissions_available() {
  local operation reason
  NATIVE_SKIP_REASON=""
  for operation in "$@"; do
    reason=$(python3 "${ROOT_DIR}/scripts/measure/core-post-test-fixtures.py" permission-probe \
      --directory "${tmp_root}" --operation "${operation}") || fail "permission capability probe failed: ${operation}"
    [[ -z "${reason}" ]] || NATIVE_SKIP_REASON+="${NATIVE_SKIP_REASON:+; }${reason}"
  done
  [[ -z "${NATIVE_SKIP_REASON}" ]]
}
