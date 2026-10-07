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
