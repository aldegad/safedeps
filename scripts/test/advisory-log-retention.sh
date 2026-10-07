#!/usr/bin/env bash
# safedeps: advisory-log retention battery.
#
# The advisory log is TWO channels in one file and rotation must treat them
# differently, so the only assertions worth pinning are about that asymmetry:
# the evidence the oracle reads survives compaction byte for byte, and the trace
# nobody reads does not. A rotation that merely shrank the file would pass a
# size check and quietly break `re-check` for every package approved before it.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "${ROOT_DIR}"

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-advisory-retention.XXXXXX")
cleanup() { rm -rf "${tmp_root}"; }
trap cleanup EXIT

log="${tmp_root}/advisory.log"

write_fixture() {
  : > "${log}"
  local i
  for ((i = 0; i < 4000; i++)); do
    printf '[2026-08-01T00:00:00Z] INFO OSV batch cache hit ecosystem=npm package=p%d version=1.0.0\n' "${i}" >> "${log}"
    if (( i % 500 == 0 )); then
      printf '[2026-08-01T00:00:00Z] check approve(clean) ecosystem=npm package=e%d version=1.0.0 hash=sha256:h%d\n' "${i}" "${i}" >> "${log}"
      printf '[2026-08-01T00:00:00Z] ERROR OSV live query failed; stale cache refused package=e%d\n' "${i}" >> "${log}"
    fi
  done
}

rotate() {
  bash -c '
    set -euo pipefail
    source "'"${ROOT_DIR}"'/lib/advisory-log-rotate.sh"
    SAFEDEPS_ADVISORY_LOG_MAX_BYTES="${1}"
    SAFEDEPS_ADVISORY_LOG_KEEP="${2:-5}"
    safedeps_advisory_log_rotate_if_needed "'"${log}"'"
  ' _ "$@"
}

# ---- under the threshold: nothing happens ------------------------------------
write_fixture
before_bytes=$(wc -c < "${log}" | tr -d ' ')
rotate 999999999
[[ $(wc -c < "${log}" | tr -d ' ') == "${before_bytes}" ]] \
  || fail "a log under the size bound was rotated anyway"
compgen -G "${log}".*.gz > /dev/null \
  && fail "a log under the size bound produced an archive"
pass "under the size bound the log is left exactly alone"

# ---- over the threshold: compaction, not truncation --------------------------
write_fixture
approve_before=$(grep -c 'check approve' "${log}")
error_before=$(grep -c '] ERROR ' "${log}")
info_before=$(grep -c '] INFO ' "${log}")
bytes_before=$(wc -c < "${log}" | tr -d ' ')
(( info_before > 0 && approve_before > 0 && error_before > 0 )) || fail "fixture is not exercising both channels"

rotate 100000

bytes_after=$(wc -c < "${log}" | tr -d ' ')
(( bytes_after < bytes_before / 10 )) || fail "rotation did not meaningfully shrink the live log"
pass "rotation shrinks the live log (${bytes_before} -> ${bytes_after} bytes)"

[[ $(grep -c 'check approve' "${log}") == "${approve_before}" ]] \
  || fail "compaction dropped approval provenance the re-check oracle reads"
[[ $(grep -c '] ERROR ' "${log}") == "${error_before}" ]] \
  || fail "compaction dropped ERROR evidence"
pass "every evidence line survives compaction (${approve_before} approvals, ${error_before} errors)"

# The trace is what had to go — and only from the LIVE file.
[[ $(grep -Ec '^\[[^]]*\] INFO ' "${log}") == "0" ]] \
  || fail "INFO trace still in the live log after compaction"
archive=$(ls "${log}".*.gz)
[[ -f "${archive}" ]] || fail "no archive written"
[[ $(gzip -dc "${archive}" | grep -c '] INFO ') == "${info_before}" ]] \
  || fail "the archive does not hold the whole trace it replaced"
[[ $(gzip -dc "${archive}" | grep -c 'check approve') == "${approve_before}" ]] \
  || fail "the archive does not hold the evidence too"
pass "the dropped trace is complete in the archive, and the archive keeps evidence as well"

# The rotation says so in the file it rotated — a bound nobody can see is
# indistinguishable from data loss.
grep -q 'advisory log rotated' "${log}" || fail "rotation left no record of itself"
pass "rotation announces itself in the log"

# ---- archive retention -------------------------------------------------------
for n in 1 2 3 4 5 6 7; do
  printf 'archive %d\n' "${n}" | gzip -c > "${log}.2026080${n}T000000Z.gz"
done
write_fixture
rotate 100000 3
archive_count=$(ls "${log}".*.gz | wc -l | tr -d ' ')
[[ "${archive_count}" == "3" ]] || fail "archive keep-count not enforced (kept ${archive_count}, expected 3)"
pass "archive keep-count is enforced"

# ---- a held lock defers rather than double-rotating --------------------------
write_fixture
mkdir "${log}.rotate.lock"
bytes_locked=$(wc -c < "${log}" | tr -d ' ')
rotate 100000
[[ $(wc -c < "${log}" | tr -d ' ') == "${bytes_locked}" ]] \
  || fail "rotation ran while another holder had the lock"
rmdir "${log}.rotate.lock"
pass "a held lock defers rotation instead of racing it"

# The CLI above still uses the Bash library. Hooks must honor the same
# retention contract through their own pre/post path.
# shellcheck source=lib/core-reader.sh
source "${ROOT_DIR}/scripts/test/lib/core-reader.sh"
core_reader_init "${ROOT_DIR}"
python3 "${ROOT_DIR}/scripts/test/lib/core-advisory-retention.py" "${SAFEDEPS_TEST_CORE}"

printf 'advisory-log retention passed\n'
