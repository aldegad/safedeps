#!/usr/bin/env bash
# Test transport only. No command parsing or dependency judgment lives here.
# SAFEDEPS_TEST_CORE selects a built artifact for controls, only in batteries.
core_reader_init() {
  local root="$1" platform
  CORE_READER_ADAPTER="${root}/scripts/test/lib/core-reader-adapter.py"
  if [[ -z "${SAFEDEPS_TEST_CORE:-}" ]]; then
    case "${BASH_VERSINFO[5]}" in
      *aarch64*darwin*|*arm64*darwin*) platform=darwin-arm64 ;;
      *x86_64*darwin*) platform=darwin-x64 ;;
      *x86_64*linux*) platform=linux-x64 ;;
      *) printf 'core reader: unsupported host %s\n' "${BASH_VERSINFO[5]}" >&2; return 2 ;;
    esac
    SAFEDEPS_TEST_CORE="${root}/bin/native/${platform}/safedeps-core"
  fi
  [[ -x "${SAFEDEPS_TEST_CORE}" ]] || {
    printf 'core reader: build the native core first: %s\n' "${SAFEDEPS_TEST_CORE}" >&2
    return 2
  }
  export SAFEDEPS_TEST_CORE
}

core_grammar_load() {
  local data key value
  data=$("${SAFEDEPS_TEST_CORE}" grammar) || return
  while IFS='=' read -r key value; do
    [[ "${key}" == SAFEDEPS_G_* && "${key}" != *[!A-Z_0-9]* ]] || return 2
    printf -v "${key}" '%s' "${value}"
  done <<< "${data}"
}

shell_lex() {
  printf '%s' "$1" | SAFEDEPS_READING="${SAFEDEPS_READING:?reading is required}" \
    "${SAFEDEPS_TEST_CORE}" lex "$2"
}
command_scan_text() { shell_lex "$1" scan; }

command_statements() {
  printf '%s' "$1" | python3 "${CORE_READER_ADAPTER}" \
    "${SAFEDEPS_TEST_CORE}" "${SAFEDEPS_READING:?reading is required}" statements
}

lex_payloads() {
  local records kind payload
  LEX_PAYLOADS=() LEX_PAYLOAD_KINDS=()
  records=$(mktemp "${TMPDIR:-/tmp}/safedeps-reader-records.XXXXXX") || return
  if ! printf '%s' "$1" | python3 "${CORE_READER_ADAPTER}" \
      "${SAFEDEPS_TEST_CORE}" "${SAFEDEPS_READING:?reading is required}" lex-payloads "$2" > "${records}"; then
    rm -f "${records}"
    return 1
  fi
  while IFS= read -r -d '' kind && IFS= read -r -d '' payload; do
    LEX_PAYLOAD_KINDS+=("${kind}")
    LEX_PAYLOADS+=("${payload}")
  done < "${records}"
  rm -f "${records}"
}
