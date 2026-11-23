#!/usr/bin/env bash
# safedeps: advisory-log retention battery.
#
# advisory.log is a bounded record, and the core rotates it
# (rust/src/state/log.rs). Under a kernel lock it renames the whole file to an
# archive name nothing holds, and the next line any writer appends makes a new
# live file. The CLI only looks at the size, then runs the core. So the
# assertions worth pinning are the ones a rotation that lost lines would fail:
# the archive is the live file, byte for byte and inode for inode; nothing is
# rewritten; and retention removes only what its bounds name.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "${ROOT_DIR}"

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

# The CLI rows run the checkout's CLI, which runs the core beside it.
# shellcheck source=lib/core-reader.sh
source "${ROOT_DIR}/scripts/test/lib/core-reader.sh"
core_reader_init "${ROOT_DIR}"

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-advisory-retention.XXXXXX")
holder_pid=""
cleanup() {
  [[ -z "${holder_pid}" ]] || kill -9 "${holder_pid}" 2>/dev/null || true
  chmod -R u+rwx "${tmp_root}" 2>/dev/null || true
  rm -rf "${tmp_root}"
}
trap cleanup EXIT

home=""
log=""
fresh_home() {
  home=$(mktemp -d "${tmp_root}/home.XXXXXX")
  log="${home}/advisory.log"
}

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
  cp "${log}" "${home}/before"
  bytes_before=$(wc -c < "${home}/before" | tr -d ' ')
}

# The first bytes of $1 are the fixture's. A run that did not rotate left them
# in the live log, whatever it appended after them, and a later rotation
# moves the fixture and those lines together.
fixture_first() { head -c "${bytes_before}" "$1" | cmp -s - "${home}/before"; }
log_kept() { fixture_first "${log}"; }

# The CLI's own run. SAFEDEPS_ADVISORY_LOG in the environment is ignored by
# design, and saying so is a log write, so `ledger` starts the rotation at
# startup as every run that writes the log does. CLI_ENV adds NAME=VALUE
# words.
CLI_ENV=()
cli_rc=0
cli() { # MAX [KEEP] [CLI]
  local max="$1" keep="${2:-5}" bin="${3:-${ROOT_DIR}/bin/safedeps}"
  cli_rc=0
  env SAFEDEPS_HOME="${home}" SAFEDEPS_ADVISORY_LOG=/dev/null NO_COLOR=1 \
    SAFEDEPS_ADVISORY_LOG_MAX_BYTES="${max}" SAFEDEPS_ADVISORY_LOG_KEEP="${keep}" \
    ${CLI_ENV[@]+"${CLI_ENV[@]}"} bash "${bin}" ledger > "${home}/cli.out" 2> "${home}/cli.err" || cli_rc=$?
}
cli_ok() { cli "$@"; [[ "${cli_rc}" == 0 ]] || fail "the CLI exited ${cli_rc}: $(cat "${home}/cli.err")"; }

# The names of the archives in the home, one per line.
archives() {
  local path name
  for path in "${home}"/advisory.log.*; do
    name="${path##*/}"
    [[ "${name}" =~ ^advisory\.log\.[0-9]{8}T[0-9]{6}Z(\.[1-9][0-9]*)?(\.gz)?$ ]] && printf '%s\n' "${name}"
  done
  return 0
}
archive_count() { archives | wc -l | tr -d ' '; }
inode() { local number rest; read -r number rest < <(ls -di "$1") || return 1; printf '%s\n' "${number}"; }

# Holds an exclusive flock(2) on $1 until killed.
hold() {
  local ready i
  ready=$(mktemp "${tmp_root}/held.XXXXXX")
  (cd "${tmp_root}" && exec python3 -c 'import fcntl, sys, time
held = open(sys.argv[1], "a")
fcntl.flock(held, fcntl.LOCK_EX)
with open(sys.argv[2], "w") as ready:
    ready.write("held\n")
time.sleep(60)' "$1" "${ready}") &
  holder_pid=$!
  for ((i = 0; i < 200; i++)); do
    [[ -s "${ready}" ]] && return 0
    sleep 0.05
  done
  fail "the lock holder did not take the lock"
}

# ---- under the bound: nothing moves ----------------------------------------
fresh_home
write_fixture
cli_ok 999999999
log_kept || fail "a log under the size bound was rotated anyway"
[[ "$(archive_count)" == 0 ]] || fail "a log under the size bound produced an archive: $(archives)"
[[ ! -e "${log}.rotate.lock" ]] || fail "a log under the size bound made the lock file"
pass "under the size bound the log is left where it was, and no lock file is made"

# ---- at the bound: the whole file is renamed --------------------------------
fresh_home
write_fixture
inode_before=$(inode "${log}")
cli_ok 100000
[[ "$(archive_count)" == 1 ]] || fail "one rotation made $(archive_count) archives: $(archives)"
archive=$(archives)
[[ "${archive}" != *.gz ]] || fail "the new archive is compressed: ${archive}"
cmp -s "${home}/${archive}" "${home}/before" || fail "the archive is not the live file byte for byte"
[[ "$(inode "${home}/${archive}")" == "${inode_before}" ]] || fail "the archive is not the live file renamed"
pass "rotation renames the whole log to a plain archive: every INFO and evidence line, byte for byte, one inode"

grep -qE 'check approve|INFO OSV batch' "${log}" && fail "a line of the rotated file is still live"
head -n 1 "${log}" | grep -qF "WARN advisory log rotated: ${bytes_before} bytes moved to ${archive}" \
  || fail "the new live file does not start with the rotation's line: $(head -n 1 "${log}")"
pass "the new live file starts with the rotation's line, which names the archive"

[[ -f "${log}.rotate.lock" && ! -L "${log}.rotate.lock" ]] || fail "the lock is not a regular file at the old lock path"
cli_ok 100000
[[ "$(archive_count)" == 1 ]] || fail "the next run rotated a file under the bound: $(archives)"
[[ -f "${log}.rotate.lock" ]] || fail "the lock file was removed"
pass "the lock file stays, and the next run leaves the new file under the bound alone"

# ---- the CLI with no core does not rotate, and says so ----------------------
fresh_home
write_fixture
tree=$(mktemp -d "${tmp_root}/no-core.XXXXXX")
# The CLI names its own directory as `pwd -P` reads it, and on macOS the
# temporary directory is under a link (/var -> /private/var).
tree=$(cd -P "${tree}" && pwd -P)
mkdir -p "${tree}/bin"
cp bin/safedeps "${tree}/bin/safedeps"
cp -R lib "${tree}/lib"
cli_ok 100000 5 "${tree}/bin/safedeps"
log_kept || fail "a CLI with no core rotated the log"
[[ "$(archive_count)" == 0 ]] || fail "a CLI with no core made an archive: $(archives)"
said=$(grep -F "safedeps: ${log} is not rotated: the safedeps-core binary is missing: ${tree}/bin/native/" "${home}/cli.err") \
  || fail "stderr does not say the log is not rotated: $(cat "${home}/cli.err")"
[[ "${said}" == *"/safedeps-core is not an executable file. Repair: reinstall the package. It holds ${bytes_before} bytes, and it rotates at 100000." ]] \
  || fail "stderr: ${said}"
grep -q 'rotat' "${log}" && fail "the log took a line about its rotation"
pass "with no core the log is not rotated, stderr says why and how big it is, and the log takes no line about it"

# ---- a held lock leaves the file to its holder ------------------------------
fresh_home
write_fixture
hold "${log}.rotate.lock"
cli_ok 100000
log_kept || fail "a run rotated the log while another held the lock"
[[ "$(archive_count)" == 0 ]] || fail "a run made an archive while another held the lock: $(archives)"
pass "a held lock leaves the log to its holder"
kill -9 "${holder_pid}"
wait "${holder_pid}" 2>/dev/null || true
holder_pid=""
inode_before=$(inode "${log}")
cli_ok 100000
[[ "$(archive_count)" == 1 ]] || fail "the run after the holder was killed did not rotate: $(archives)"
[[ "$(inode "${home}/$(archives)")" == "${inode_before}" ]] || fail "the archive is not the live file, renamed"
fixture_first "${home}/$(archives)" || fail "the archive does not start with the live file's lines"
pass "a holder killed with SIGKILL leaves no lock behind: the next run rotates"

# ---- an earlier version's lock directory ------------------------------------
fresh_home
write_fixture
mkdir "${log}.rotate.lock"
cli_ok 100000
log_kept || fail "a run rotated the log inside an earlier version's lock window"
[[ -d "${log}.rotate.lock" ]] || fail "the young lock directory was removed"
pass "an earlier version's lock directory younger than its 300-second window defers rotation"
touch -t 202001010000 "${log}.rotate.lock"
cli_ok 100000
[[ "$(archive_count)" == 1 ]] || fail "an old lock directory still deferred rotation: $(archives)"
fixture_first "${home}/$(archives)" || fail "the archive does not start with the live file's lines"
[[ -f "${log}.rotate.lock" && ! -d "${log}.rotate.lock" ]] || fail "the lock file does not stand where the directory stood"
pass "one older than the window is removed by that version's rule, and the lock file stands in its place"

# ---- compression waits for the quiet window --------------------------------
fresh_home
write_fixture
old="${log}.20260801T000000Z"
printf 'an old line\n' > "${old}"
touch -t 202608010000 "${old}"
fresh="${log}.20260802T000000Z"
printf 'a line written just now\n' > "${fresh}"
CLI_ENV=(SAFEDEPS_ADVISORY_LOG_QUIET_SECONDS=60)
cli_ok 100000
CLI_ENV=()
[[ ! -e "${old}" && "$(gzip -dc "${old}.gz")" == 'an old line' ]] || fail "the quiet plain archive was not compressed whole: $(archives)"
[[ -f "${fresh}" && ! -e "${fresh}.gz" ]] || fail "a plain archive written inside the window was compressed"
[[ "$(archives | grep -cv '\.gz$')" == 2 ]] || fail "the new archive is not plain: $(archives)"
[[ ! -e "${log}.compressing" ]] || fail "the compression left its temp file"
grep -qF "; ${old##*/} compressed to ${old##*/}.gz" "${log}" || fail "the rotation's line does not say what it compressed: $(head -n 1 "${log}")"
pass "a later rotation compresses a plain archive nobody wrote for the quiet window, and leaves the new one and a fresh one plain"

# ---- retention -------------------------------------------------------------
fresh_home
for n in 1 2 3 4 5 6 7; do
  if (( n % 2 )); then
    printf 'archive %d\n' "${n}" | gzip -c > "${log}.2026080${n}T000000Z.gz"
  else
    printf 'archive %d\n' "${n}" > "${log}.2026080${n}T000000Z"
  fi
done
write_fixture
cli_ok 100000 3
kept=$(archives | tr '\n' ' ')
[[ "$(archive_count)" == 3 ]] || fail "archive keep-count not enforced (kept ${kept}, expected 3)"
[[ -f "${log}.20260807T000000Z.gz" && -f "${log}.20260806T000000Z" ]] || fail "retention did not keep the newest archives: ${kept}"
cmp -s "${home}/$(archives | grep -v '^advisory\.log\.2026080')" "${home}/before" || fail "retention removed the archive just made: ${kept}"
grep -qF '; removed beyond the retention bounds: ' "${log}" || fail "the rotation's line does not say what retention removed"
pass "retention keeps three archives, plain and gzip counted together, and the rotation's line names what it removed"

# ---- a rotation that cannot rename says so ---------------------------------
fresh_home
write_fixture
mkdir -p "${home}/cache/osv-vuln" "${home}/cache/kev" "${home}/cache/ghsa" "${home}/approved-specs"
: > "${log}.rotate.lock"
chmod 500 "${home}"
cli 100000
chmod 700 "${home}"
log_kept || fail "a rotation that could not rename changed the log"
[[ "$(archive_count)" == 0 ]] || fail "a rotation that could not rename made an archive: $(archives)"
grep -q '^safedeps-core advisory-log: advisory log not rotated: the rename to .* returned OS error ' "${home}/cli.err" \
  || fail "stderr does not say the rotation failed: $(cat "${home}/cli.err")"
grep -q '\] ERROR advisory log not rotated: the rename to .* returned OS error ' "${log}" \
  || fail "the log does not say the rotation failed"
pass "a rotation that cannot rename leaves the log whole, and says why on stderr and in the log"

# The hooks rotate through the same core, from the post hook's provider
# initialization.
python3 "${ROOT_DIR}/scripts/test/lib/core-advisory-retention.py" "${SAFEDEPS_TEST_CORE}"

printf 'advisory-log retention passed\n'
