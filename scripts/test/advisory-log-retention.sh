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
# The text of the live file or an archive, by name, gzip read through.
text() {
  if [[ "$1" == *.gz ]]; then gzip -dc "${home}/$1"; else cat "${home}/$1"; fi
}
# How many lines of the live file and the archives together are $1.
recorded() {
  local name
  {
    cat "${log}"
    for name in $(archives); do
      text "${name}" || fail "${name} is not whole"
    done
  } > "${home}/record"
  grep -cxF -- "$1" "${home}/record" || true
}

# How many lines of every regular file in the home are $1, a file named .gz
# or .GZ read through gzip. Unlike recorded, it reads every name: an entry
# whose name is not an archive name holds a record too.
held() {
  local path body count n=0
  for path in "${home}"/*; do
    [[ -f "${path}" && ! -L "${path}" ]] || continue
    case "${path}" in
      *.gz|*.GZ) body=$(gzip -dc "${path}") || fail "${path##*/} is not whole" ;;
      *) body=$(cat "${path}") ;;
    esac
    count=$(printf '%s\n' "${body}" | grep -cxF -- "$1" || true)
    n=$((n + count))
  done
  printf '%s\n' "${n}"
}

# The condition of a held-name row, recorded on each run: whether the volume
# takes the name $2 in the home for the entry $1. A listing reads names by
# their bytes, so it does not read $1 as $2. Where the volume keeps the two
# apart, the row says so and checks the records alone.
condition=0
takes() { # ENTRY NAME
  if [[ -e "${home}/$2" && "$(inode "${home}/$2")" == "$(inode "${home}/$1")" ]]; then
    condition=1
    printf '# condition: the volume takes %s for %s\n' "$2" "$1"
  else
    condition=0
    printf '# note: the volume keeps %s and %s apart; the row checks the records alone\n' "$1" "$2"
  fi
}

# The archive names of the held-name rows: a second later than any clock
# reads, so the rotation takes the name after the newest one there.
stem=advisory.log.21000101T000000Z

# A held-name row of the archive name: ENTRY holds a record beside the archive
# .8, and the rotation takes the name after .8. The volume may take ENTRY for
# that name; then the rotation passes over the name and takes .10.
held_archive_row() { # ENTRY WHAT
  fresh_home
  printf 'an older record\n' > "${home}/${stem}.8"
  printf 'an existing record\n' > "${home}/$1"
  printf 'the current record\n' > "${log}"
  takes "$1" "${stem}.9"
  core_rotate 1 10
  [[ "$(held 'an existing record')" == 1 && "$(held 'the current record')" == 1 && "$(held 'an older record')" == 1 ]] \
    || fail "beside $2, the existing record is kept $(held 'an existing record') times and the current one $(held 'the current record') times"
  if (( condition )); then
    [[ "$(cat "${home}/${stem}.10")" == 'the current record' ]] || fail "the live file did not become ${stem}.10"
    head -n 1 "${log}" | grep -qF "moved to ${stem}.10; ${stem}.9 passed over: the creation of " \
      || fail "the rotation's line does not say it passed over ${stem}.9: $(head -n 1 "${log}")"
    head -n 1 "${log}" | grep -qF "/${stem}.9 returned OS error 17" || fail "the rotation's line: $(head -n 1 "${log}")"
  fi
  pass "a rotation passes over an archive name held by $2, and keeps both records"
}

# The core's own rotation, as the CLI runs it once its look at the size says
# the log is at the bound, with an hour's quiet window.
core_rotate() { # MAX KEEP
  local rc=0
  env SAFEDEPS_HOME="${home}" SAFEDEPS_ADVISORY_LOG_MAX_BYTES="$1" SAFEDEPS_ADVISORY_LOG_KEEP="$2" \
    SAFEDEPS_ADVISORY_LOG_QUIET_SECONDS=3600 \
    "${SAFEDEPS_TEST_CORE}" advisory-log rotate 2> "${home}/core.err" || rc=$?
  [[ "${rc}" == 0 ]] || fail "the core's rotation exited ${rc}: $(cat "${home}/core.err")"
}

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

# ---- a line written into an archive after the next rotation ----------------
# A writer that opened the live file before the rename writes into the
# archive. Here the file had gone unwritten for longer than the quiet window
# before the rename, and a rename keeps a file's mtime. The window must count
# from the rename all the same: the next rotation, a moment later, leaves the
# archive plain, and the line the writer writes after it is kept.
fresh_home
printf 'a line written long ago\n' > "${log}"
touch -t 202001010000 "${log}"
inode_before=$(inode "${log}")
exec 7>>"${log}"
core_rotate 1 5
first=$(archives)
[[ "$(archive_count)" == 1 && "$(inode "${home}/${first}")" == "${inode_before}" ]] \
  || fail "the first rotation did not rename the file the writer holds: $(archives)"
# The first rotation's line made a new live file at the bound of one byte.
core_rotate 1 5
[[ "$(archive_count)" == 2 ]] || fail "the second rotation did not rename the new live file: $(archives)"
printf 'a line written after the next rotation\n' >&7
exec 7>&-
seed=$(recorded 'a line written long ago')
late=$(recorded 'a line written after the next rotation')
[[ -f "${home}/${first}" ]] || fail "the archive the writer holds was compressed a moment after its rename: $(archives)"
[[ "${seed}" == 1 && "${late}" == 1 ]] \
  || fail "the record holds the first line ${seed} times and the late one ${late} times: $(archives)"
pass "a writer that opened the log before its rename keeps a line it writes after the next rotation, though the file was last written long before"

# ---- three rotations in one second -----------------------------------------
# Retention removes the oldest names first, so archive names must sort in the
# order the archives were made. With KEEP=1 each rotation removes the archive
# the one before it made. The next rotation in that second must not take the
# name the removal freed: that name sorts first, and retention would keep the
# archive it took for the oldest. The row reads the three names' second from
# the names themselves, and a try whose rotations straddled a second runs
# again.
tries=0
while :; do
  fresh_home
  # Start just after a second turns, so three runs of the core fit in it.
  sleep "$(python3 -c 'import time; print("%.3f" % (1.02 - time.time() % 1))')"
  counts=()
  seconds=()
  for n in 1 2 3; do
    printf 'run %d\n' "${n}" > "${log}"
    core_rotate 1 1
    counts+=("$(archive_count)")
    made=""
    for name in $(archives); do
      if [[ "$(text "${name}")" == "run ${n}" ]]; then made="${name}"; fi
    done
    [[ -n "${made}" ]] || fail "no archive holds run ${n}: $(archives)"
    made="${made#advisory.log.}"
    seconds+=("${made%%.*}")
  done
  [[ "${seconds[0]}" == "${seconds[1]}" && "${seconds[1]}" == "${seconds[2]}" ]] && break
  tries=$((tries + 1))
  (( tries < 5 )) || fail "three rotations straddled a second in five tries: ${seconds[*]}"
  printf '# note: the three rotations straddled a second (%s); the row runs again\n' "${seconds[*]}"
done
[[ "${counts[*]}" == "1 1 1" ]] \
  || fail "with KEEP=1, three rotations in ${seconds[0]} left ${counts[*]} archives: $(archives | tr '\n' ' ')"
[[ "$(text "$(archives)")" == "run 3" ]] || fail "the archive that stands is not the one just made: $(archives)"
pass "three rotations in one second with KEEP=1 leave one archive each time, the one just made"

# ---- a held name: the stamp in lower case ----------------------------------
# Whether a name is free is the volume's answer, by its own rules of case and
# form, and the listing reads names by their bytes. A rotation that took the
# listing's answer replaced the entry the volume found under the name.
held_archive_row advisory.log.21000101t000000z.9 'an entry whose stamp is in lower case'

# ---- a held name: the live name in upper case -------------------------------
held_archive_row ADVISORY.LOG.21000101T000000Z.9 'an entry whose live name is in upper case'

# ---- a held name: a long s ---------------------------------------------------
# U+017F, which a case-insensitive volume of macOS folds to s. The archive
# names are ASCII, and this is how a name that is not ASCII reaches them.
held_archive_row $'advi\xc5\xbfory.log.21000101T000000Z.9' 'an entry with a long s for the s'

# ---- a held name: the gzip name in upper case -------------------------------
# A compression publishes its gzip file under the plain archive's name and
# .gz. An entry the volume takes for that name holds another record.
fresh_home
printf 'an older record\n' > "${home}/${stem}.9"
touch -t 202001010000 "${home}/${stem}.9"
printf 'an existing record\n' | gzip -c > "${home}/${stem}.9.GZ"
printf 'the current record\n' > "${log}"
takes "${stem}.9.GZ" "${stem}.9.gz"
core_rotate 1 10
[[ "$(held 'an existing record')" == 1 && "$(held 'an older record')" == 1 && "$(held 'the current record')" == 1 ]] \
  || fail "beside ${stem}.9.GZ, the existing record is kept $(held 'an existing record') times and the archive's own $(held 'an older record') times"
if (( condition )); then
  [[ -f "${home}/${stem}.9" ]] || fail "the archive whose gzip name is held is not left plain"
  head -n 1 "${log}" | grep -qF "; ${stem}.9 left plain: the link to " \
    || fail "the rotation's line does not say the archive was left plain: $(head -n 1 "${log}")"
  head -n 1 "${log}" | grep -qF "/${stem}.9.gz returned OS error 17" || fail "the rotation's line: $(head -n 1 "${log}")"
fi
pass "a compression whose gzip name is held leaves the archive plain, and keeps both records"

# ---- a held name: the temp name in upper case -------------------------------
# A compression removes the temp file a compression that did not end left,
# and writes its own there. An entry the volume takes for that name is not
# such a file.
fresh_home
printf 'an older record\n' > "${home}/${stem}.8"
touch -t 202001010000 "${home}/${stem}.8"
printf 'an existing record\n' > "${home}/ADVISORY.LOG.COMPRESSING"
printf 'the current record\n' > "${log}"
takes ADVISORY.LOG.COMPRESSING advisory.log.compressing
core_rotate 1 10
[[ "$(held 'an existing record')" == 1 && "$(held 'an older record')" == 1 && "$(held 'the current record')" == 1 ]] \
  || fail "beside ADVISORY.LOG.COMPRESSING, the existing record is kept $(held 'an existing record') times and the archive's own $(held 'an older record') times"
if (( condition )); then
  [[ -f "${home}/${stem}.8" ]] || fail "the archive is not left plain while the temp name is held"
  head -n 1 "${log}" | grep -qF "; ${stem}.8 left plain: the creation of " \
    || fail "the rotation's line does not say the archive was left plain: $(head -n 1 "${log}")"
  head -n 1 "${log}" | grep -qF "/advisory.log.compressing returned OS error 17" || fail "the rotation's line: $(head -n 1 "${log}")"
fi
pass "a compression whose temp name is held leaves the archive plain, and keeps both records"

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
# The CLI's output files exist first: in a home it cannot write to, the
# redirect would fail and the CLI would not run at all.
: > "${home}/cli.out"
: > "${home}/cli.err"
chmod 500 "${home}"
cli 100000
chmod 700 "${home}"
grep -q '^safedeps-core advisory-log: advisory log not rotated: the rename to .* returned OS error ' "${home}/cli.err" \
  || fail "stderr does not say the rotation failed: $(cat "${home}/cli.err")"
log_kept || fail "a rotation that could not rename changed the log"
[[ "$(archive_count)" == 0 ]] || fail "a rotation that could not rename made an archive: $(archives)"
grep -q '\] ERROR advisory log not rotated: the rename to .* returned OS error ' "${log}" \
  || fail "the log does not say the rotation failed"
pass "a rotation that cannot rename leaves the log whole, and says why on stderr and in the log"

# The hooks rotate through the same core, from the post hook's provider
# initialization.
python3 "${ROOT_DIR}/scripts/test/lib/core-advisory-retention.py" "${SAFEDEPS_TEST_CORE}"

printf 'advisory-log retention passed\n'
