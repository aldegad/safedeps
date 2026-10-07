#!/usr/bin/env bash
# Run all Rust tests as one battery, after the runner prepared the host core.
# Cargo builds a separate libtest executable in the same target/profile cache;
# the executable used by the hooks must still match the receipt afterwards.
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
cd "${ROOT_DIR}" || exit 2
fail() { printf 'not ok - rust-core: %s\n' "$1"; }
receipt="${SAFEDEPS_TEST_CORE_RECEIPT:-}"
logs="${SAFEDEPS_TEST_LOG_DIR:-}"
[[ -n "${receipt}" && -d "${logs}" ]] || {
  fail "the runner must supply its core receipt and log directory"
  exit 1
}
bash scripts/build-core.sh --check-receipt "${receipt}" > "${logs}/rust-core.before.json" || {
  fail "the prepared core did not match its receipt before cargo test"
  exit 1
}
target=$(jq -er '.target' "${logs}/rust-core.before.json") || { fail "the receipt names no target"; exit 1; }
command -v cargo >/dev/null 2>&1 || { fail "cargo is not on PATH"; exit 1; }

raw="${logs}/rust-core.cargo.log"
cargo_rc=0
( cd rust && SAFEDEPS_CORE_BUILD_KIND=checkout CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER=rust-lld \
  cargo test --release --locked --offline -j1 --no-fail-fast --target "${target}" --color never \
    -- --test-threads=1 --format pretty --color never ) > "${raw}" 2>&1 || cargo_rc=$?
# Retain cargo's diagnostics without passing captured test output off as TAP.
sed 's/^/# cargo | /' "${raw}"
failed=0
# The stable libtest pretty output names every test. Ignored tests are red;
# zero tests, or a partial/unreadable result, must not earn a battery's ok.
awk '
  /^running [0-9]+ tests?$/ { expected += $2; runs++; next }
  /^test .* \.\.\. (ok|FAILED|ignored)( |$)/ {
    name = $0; sub(/^test /, "", name); sub(/ \.\.\. .*/, "", name)
    seen++
    if ($0 ~ / \.\.\. ok$/) print "ok - rust-core: " name
    else { print "not ok - rust-core: " name " (failed or ignored)"; bad = 1 }
  }
  /^test result: / { summaries++ }
  END {
    if (seen == 0 || seen != expected || runs != summaries) {
      printf "not ok - rust-core: read %d test results of %d announced, %d summaries of %d runs\n", seen, expected, summaries, runs
      bad = 1
    }
    exit bad
  }
' "${raw}" || failed=1
if (( cargo_rc != 0 )); then
  fail "cargo test exited ${cargo_rc}"
  failed=1
fi
# Check even after a failed build/test: preserving the prepared executable is
# a separate condition from whether the tests passed. This never rebuilds it.
if ! bash scripts/build-core.sh --check-receipt "${receipt}" > "${logs}/rust-core.after.json"; then
  fail "the prepared core did not match its receipt after cargo test"
  failed=1
elif ! cmp -s "${logs}/rust-core.before.json" "${logs}/rust-core.after.json"; then
  fail "the prepared core identity changed during cargo test"
  failed=1
fi
exit "${failed}"
