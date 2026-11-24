#!/usr/bin/env bash
# safedeps: the test hosts' queue runner, scripts/ci/slot.sh.
#
#   scripts/test/slot-queue.sh [--script <slot.sh>]
#
# Each row installs the runner into a home of its own as a host gets it: the
# installer run by its own #! line, as scripts/ci/test-hosts.example writes it,
# and the script it prints read by bash -s. The first row is that install. A
# row then puts a ticket in the queue or holds a slot, starts a suite behind
# it and reads what the runner decided: the suite ran, the runner said the
# slots are busy, or it refused to queue. All three are things the runner
# does, so a row waits for one of them and needs no clock but a ceiling.
#
# The tickets name a live process of this battery's own, a sleep, by its pid.
# A ticket with the start the kernel holds for it is that process; one with
# another start is a process gone after a reboot whose pid came back. A slot
# is held as a runner holds it: a process of the battery's own opens the
# slot's file on fd 9, and perl takes flock(2) on that descriptor. With
# --script the rows judge another copy of slot.sh, as the red controls do.
#
# Each step a verdict of the runner rests on has a row that makes that step
# fail, by a tool found ahead of the real one on the runner's PATH. A hook on
# a step lets another run act just before it, so the order of a race is the
# row's and not the scheduler's.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
script="${ROOT_DIR}/scripts/ci/slot.sh"
if [[ "${1:-}" == --script ]]; then
  [[ -f "${2:-}" ]] || { printf 'usage: %s [--script <slot.sh>]\n' "$0" >&2; exit 2; }
  script="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
fi
failures=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1"; failures=$((failures + 1)); }

# A child this battery starts carries the marker with the battery's pid, and a
# run clears the children of a run that is gone (a SIGKILL defeats the trap).
MARK_BASE=safedeps-slot-queue-owned
MARK="${MARK_BASE}:$$"
while read -r pid args; do
  case "${args}" in *"${MARK_BASE}:"*) ;; *) continue ;; esac
  owner="${args#*"${MARK_BASE}:"}"; owner="${owner%%[!0-9]*}"
  [[ -n "${owner}" ]] || continue
  [[ "$(ps -o args= -p "${owner}" 2>/dev/null)" == *slot-queue.sh* ]] && continue
  kill -9 "${pid}" 2>/dev/null || true
done < <(ps -Ao pid=,args= 2>/dev/null)

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-slot.XXXXXX")
children=()
# stop <pid>: TERM to the process and to every process under it, read before
# the first signal, and then a wait for it. A stop that signalled only the
# process and its children left a run standing: macOS's /bin/bash 3.2 runs
# the command of a substitution, the runner's lock call, as a child of a
# child, and a runner reading the substitution's output did not end on TERM
# until that command ended. A lock call that blocks never ends.
tree() { local child; printf '%s\n' "$1"; for child in $(pgrep -P "$1" 2>/dev/null); do tree "${child}"; done; }
stop() {
  local pid
  for pid in $(tree "$1"); do kill -TERM "${pid}" 2>/dev/null || true; done
  wait "$1" 2>/dev/null || true
}
cleanup() {
  local child
  for child in "${children[@]:-}"; do [[ -z "${child}" ]] || stop "${child}"; done
  rm -rf "${tmp_root}"
}
trap cleanup EXIT

sha() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
identity() {
  python3 -c 'import sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
import native_budget_owners as owners
print(owners.identity(int(sys.argv[2])))' "${ROOT_DIR}/scripts/test/lib" "$1"
}

# A live process, and the identity the kernel holds for it.
( cd "${tmp_root}" && exec bash -c 'exec -a "$0" sleep 600' "${MARK}" ) &
witness=$!
children+=("${witness}")
witness_id=$(identity "${witness}")
[[ "${witness_id}" =~ ^[0-9]+\ . ]] || { fail "the kernel names the witness (got '${witness_id}')"; exit 1; }
other_id="$(( ${witness_id%% *} + 1 )) ${witness_id#* }"

row=0
home=""
install_rc=(none none)
# install_runner: the runner into $home the way the documents install it on a
# host (scripts/ci/test-hosts.example, and the usage line of the installer):
# scripts/ci/install-slot.sh run from the repository's root by its own #! line,
# and the script it prints read by bash -s with HOME at $home. An installer
# that cannot run prints no script, and bash -s ends 0 on an empty one, so the
# installer's own status is read, in install_rc with bash -s's, and both are 0.
install_runner() {
  set +e
  ( cd "${ROOT_DIR}" && exec scripts/ci/install-slot.sh ) 2> "${tmp_root}/install.err" \
    | HOME="${home}" bash -s > "${tmp_root}/install.out" 2>&1
  install_rc=("${PIPESTATUS[@]}")
  set -e
  [[ "${install_rc[0]}" == 0 && "${install_rc[1]}" == 0 ]]
}
fresh() { # slots: a home with the runner installed and the queue empty
  row=$((row + 1))
  home="${tmp_root}/home-${row}"
  mkdir -p "${home}"
  install_runner || {
    fail "row ${row} installs the runner (installer exit ${install_rc[0]}, bash -s exit ${install_rc[1]})"
    printf '# %d row(s) failed; no row can install the runner\n' "${failures}"
    exit 1
  }
  [[ "${script}" == "${ROOT_DIR}/scripts/ci/slot.sh" ]] || cp "${script}" "${home}/safedeps-runs/slot.sh"
  printf '%s\n' "$1" > "${home}/safedeps-runs/.slots"
  mkdir -p "${home}/safedeps-runs/.queue"
}
ticket() { # pid, then the lines it holds; $record is its path
  local pid="$1"; shift
  record="${home}/safedeps-runs/.queue/$(( $(date +%s) - 100 ))-$(printf %07d "${pid}")"
  printf '%s\n' "$@" > "${record}"
}
# slot <pid> [<identity>]: the record the runner before the kernel lock kept
# in the slot directory .slot, and slot_in <name> the same in another. The
# runner reads no such record. Only the handoff row sets them up, so that a
# copy from before the lock, run with --script, meets the slots it judged.
slot() {
  slot_in .slot "$@"
}
slot_in() {
  local L="${home}/safedeps-runs/$1"; shift
  mkdir -p "${L}"
  [[ $# -lt 2 ]] || printf '%s\n' "$2" > "${L}/identity"
  printf '%s\n' "$1" > "${L}/pid"
  printf 'other since 00:00:00\n' > "${L}/owner"
}
# A slot held as a runner holds it. lock-holder <file> <ready> <marker> opens
# file on fd 9, has perl take flock(2) on that descriptor, and lives on as a
# sleep that keeps the descriptor until it is killed.
cat > "${tmp_root}/lock-holder" <<'EOF'
#!/bin/bash
exec 9>> "$1" || exit 2
perl -MFcntl=:flock -e 'open(my $h, ">>&=", 9) or exit 2; flock($h, LOCK_EX | LOCK_NB) or exit 1' || exit 1
: > "$2"
exec -a "$3" sleep 600
EOF
chmod +x "${tmp_root}/lock-holder"
locker=""; fixture=""
# lock_held <file>: a live process of this battery's own holds the lock on
# file, and $locker is its pid.
lock_held() {
  local i
  rm -f "${tmp_root}/locked"
  ( cd "${tmp_root}" && exec "${tmp_root}/lock-holder" "$1" "${tmp_root}/locked" "${MARK}" ) 2> /dev/null &
  locker=$!
  children+=("${locker}")
  for (( i = 0; i < 600; i++ )); do
    [[ -e "${tmp_root}/locked" ]] && return 0
    kill -0 "${locker}" 2>/dev/null || return 1
    sleep 0.1
  done
  return 1
}
# held <name>: the slot <name> of the row's home is held by a process of the
# battery's own. A row whose holder never held it fails, and read_seen ends
# the holder.
held() { lock_held "${home}/safedeps-runs/$1" || fixture="the battery's holder never held $1"; }
# is_free <file>: whether a fresh open of file takes the lock now. It lets go
# at once.
is_free() {
  ( exec 9>> "$1" && exec perl -MFcntl=:flock -e 'open(my $h, ">>&=", 9) or exit 2; flock($h, LOCK_EX | LOCK_NB) or exit 1' ) 2> /dev/null
}
# A step that fails. The runner of the next row finds these tools first on its
# PATH, and a call goes to the real tool unless it is the one picked: a call
# of a tool PROBE_TOOL lists with the argument PROBE_FILE (a value ending in *
# picks any argument that starts with what is before it), or every call of
# that tool when PROBE_FILE is empty. The picked call notes itself in
# PROBE_SEEN, prints what a failure part way leaves and exits PROBE_RC, or 1:
# sed reads the file PROBE_CUT in the path's place, ls leaves out the names
# PROBE_CUT lists, sort prints only the last line of its order, and the rest
# print PROBE_CUT. date takes the format as the path. With PROBE_SKIP=n the
# first n calls it picks go to the real tool and note nothing, so a row can
# make a later call of the same step fail. With PROBE_MODE=hook the picked
# call fails nothing: it first runs the script PROBE_CUT, on the PATH the
# battery has and with none of these variables, then is the real call. So
# another run acts between two steps of the runner, in the order the row sets.
probe="${tmp_root}/probe"
mkdir -p "${probe}"
{
  printf '#!/bin/bash\n'
  for tool in cat sed ls date grep sort tail python3 dirname mkdir mv perl; do
    printf 'real_%s=%q\n' "${tool}" "$(command -v "${tool}")"
  done
  cat <<'EOF'
tool=${0##*/}; real=real_${tool}; real=${!real}
picks() {
  case "${PROBE_FILE}" in
    '') return 1 ;;
    *\*) [[ "$1" == "${PROBE_FILE%\*}"* ]] ;;
    *) [[ "$1" == "${PROBE_FILE}" ]] ;;
  esac
}
hit=""
if [[ " ${PROBE_TOOL} " == *" ${tool} "* ]]; then
  [[ -n "${PROBE_FILE}" ]] || hit=1
  for a in "$@"; do picks "${a}" && hit=1; done
fi
if [[ -n "${hit}" && -n "${PROBE_SKIP}" ]]; then
  printf x >> "${PROBE_SEEN}.calls"
  calls=$(< "${PROBE_SEEN}.calls")
  (( ${#calls} > PROBE_SKIP )) || hit=""
fi
[[ -n "${hit}" ]] || exec "${real}" "$@"
: > "${PROBE_SEEN}"
if [[ "${PROBE_MODE}" == hook ]]; then
  hook=${PROBE_CUT}
  ( unset PROBE_TOOL PROBE_FILE PROBE_CUT PROBE_SEEN PROBE_MODE PROBE_SKIP PROBE_RC; PATH=${PROBE_PATH}; "${hook}" )
  exec "${real}" "$@"
fi
case "${tool}" in
  sed) args=(); for a in "$@"; do picks "${a}" && a=${PROBE_CUT}; args+=("${a}"); done
       "${real}" "${args[@]}" ;;
  ls) "${real}" "$@" | "${real_grep}" -vxF -f "${PROBE_CUT}" ;;
  sort) "${real}" "$@" | "${real_tail}" -n 1 ;;
  *) "${real_cat}" "${PROBE_CUT}" ;;
esac
exit "${PROBE_RC:-1}"
EOF
} > "${probe}/fail"
chmod +x "${probe}/fail"
for tool in cat sed ls date sort python3 dirname mkdir mv perl; do ln -s fail "${probe}/${tool}"; done
probe_tool=""; probe_file=""; probe_mode=""; probe_skip=""; probe_rc=""
cut_short() { # tool, path, bytes: the next row's runner reads path with tool to all but its last bytes, and the read fails
  probe_tool="$1"; probe_file="$2"
  head -c "$(( $(wc -c < "$2") - $3 ))" "$2" > "${tmp_root}/cut"
}
fails() { # tool, the argument that picks its call ('' for every call), then what the call gives: it fails
  probe_tool="$1"; probe_file="$2"; shift 2
  printf '%s' "$@" > "${tmp_root}/cut"
}
# hook <tool> <argument> [<skip>]: the next row's runner's picked call of tool
# first runs the script read from stdin, once, then is the real call.
hook() {
  probe_tool="$1"; probe_file="$2"; probe_mode=hook; probe_skip="${3:-}"
  { printf '#!/bin/bash\n'; printf 'mkdir %q 2>/dev/null || exit 0\n' "${tmp_root}/hooked"; cat; } > "${tmp_root}/cut"
  chmod +x "${tmp_root}/cut"
}
# runner_env: the next row's runner's environment, in $env.
runner_env() {
  env=(HOME="${home}")
  [[ -z "${probe_tool}" ]] || env+=(PATH="${probe}:${PATH}" PROBE_TOOL="${probe_tool}" PROBE_FILE="${probe_file}"
    PROBE_CUT="${tmp_root}/cut" PROBE_SEEN="${tmp_root}/seen" PROBE_MODE="${probe_mode}" PROBE_SKIP="${probe_skip}"
    PROBE_RC="${probe_rc}" PROBE_PATH="${PATH}")
}
# read_seen: a row that made a step fail holds only if the runner took that
# step, and a row whose slot the battery held holds only if it was held. It
# ends the row's holder.
read_seen() {
  [[ -z "${probe_tool}" || -e "${tmp_root}/seen" ]] || got="${got}, and it never ran the failing ${probe_tool} ${probe_file##*/}"
  [[ -z "${fixture}" ]] || got="${got}, and ${fixture}"
  [[ -z "${locker}" ]] || stop "${locker}"
  probe_tool=""; probe_file=""; probe_mode=""; probe_skip=""; probe_rc=""; fixture=""; locker=""
}

# start: a suite behind the records, in the background; $suite is its pid.
start() {
  rm -f "${tmp_root}/ran" "${tmp_root}/err" "${tmp_root}/seen" "${tmp_root}/seen.calls"
  rm -rf "${tmp_root}/hooked"
  local env; runner_env
  # Started as a host starts it, by its own #! line.
  # The marker is an argument the suite ignores, so the sweep finds the runner.
  ( cd "${tmp_root}" && exec env "${env[@]}" "${home}/safedeps-runs/slot.sh" row \
      bash -c ': > "$1"' _ "${tmp_root}/ran" "${MARK}" ) 2> "${tmp_root}/err" &
  suite=$!
  children+=("${suite}")
}
# decided: ran or waited, the first the runner shows, or none within a minute.
decided() {
  local i
  for (( i = 0; i < 600; i++ )); do
    [[ ! -e "${tmp_root}/ran" ]] || { printf 'ran'; return; }
    ! grep -q 'slots busy' "${tmp_root}/err" 2>/dev/null || { printf 'waited'; return; }
    sleep 0.1
  done
  printf 'none (%s)' "$(tr '\n' ' ' < "${tmp_root}/err" | head -c 200)"
}
expect() { # ran|waited, label
  start
  local got
  got=$(decided)
  stop "${suite}"
  read_seen
  if [[ "${got}" == "$1" ]]; then pass "$2"; else fail "$2 (the suite: ${got})"; fi
}
# judged <label>: the row started by start held when the suite waited, in $got.
judged() {
  if [[ "${got}" == waited ]]; then pass "$1"; else fail "$1 (the suite: ${got})"; fi
}
# refuses <label> [<env>...]: the runner, started with env, refuses at once. It
# exits 2, says it is not queueing and leaves the queue as it found it. With
# $refusal set, what it says holds that text. One that queues instead may never
# end, as the copy before the fix does with no ps on PATH, so it is stopped
# once it says the slots are busy, or after a minute, and the row says so.
refusal=""
refuses() {
  local label="$1" env rc i refuser got="" before; shift
  rm -f "${tmp_root}/seen" "${tmp_root}/seen.calls"
  before=$(ls "${home}/safedeps-runs/.queue")
  runner_env
  ( cd "${tmp_root}" && exec env "${env[@]}" "$@" "${home}/safedeps-runs/slot.sh" row true "${MARK}" ) \
    > /dev/null 2> "${tmp_root}/err" &
  refuser=$!
  children+=("${refuser}")
  for (( i = 0; i < 600; i++ )); do
    kill -0 "${refuser}" 2>/dev/null || break
    ! grep -q 'slots busy' "${tmp_root}/err" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "${refuser}" 2>/dev/null; then
    stop "${refuser}"
    if grep -q 'slots busy' "${tmp_root}/err"; then rc="none: it queued and waits"; else rc="none within a minute"; fi
  else
    set +e
    wait "${refuser}"
    rc=$?
    set -e
  fi
  read_seen
  [[ -z "${refusal}" ]] || grep -qF -- "${refusal}" "${tmp_root}/err" || got="${got}, and it did not say '${refusal}'"
  refusal=""
  if [[ "${rc}" == 2 && -z "${got}" ]] && grep -q 'not queueing' "${tmp_root}/err" \
    && [[ "$(ls "${home}/safedeps-runs/.queue")" == "${before}" ]]; then
    pass "${label}"
  else
    fail "${label} (exit ${rc}${got}, tickets: $(ls "${home}/safedeps-runs/.queue" | wc -l | tr -d ' '), before: $(printf '%s' "${before}" | grep -c . || true))"
  fi
}

# --- the runner installed the way a host installs it -------------------------------------
# A tree whose installer is not executable fails here, and no row after it can
# install the runner, so the battery stops.
row=$((row + 1)); home="${tmp_root}/home-${row}"; mkdir -p "${home}"
got=""
if ! install_runner; then
  got="installer exit ${install_rc[0]}, bash -s exit ${install_rc[1]}: $(head -c 200 "${tmp_root}/install.err" | tr '\n' ' ')"
elif [[ ! -x "${home}/safedeps-runs/slot.sh" ]]; then
  got="it left no executable ~/safedeps-runs/slot.sh"
fi
if [[ -z "${got}" ]]; then
  pass "the installer runs by its own #! line as test-hosts.example writes it, and installs the runner"
else
  fail "the installer runs by its own #! line as test-hosts.example writes it, and installs the runner (${got})"
  printf '# %d row(s) failed; no row can install the runner\n' "${failures}"
  exit 1
fi

# --- a pid the kernel handed out again ----------------------------------------------
fresh 1; ticket "${witness}" other "${other_id}"
expect ran "a ticket ahead whose pid runs under another start is gone, and the suite behind it runs"

# --- what is not known stays ----------------------------------------------------------
fresh 1; ticket "${witness}" other "not an identity"
expect waited "a ticket ahead whose record holds no start it can read is kept"
fresh 1; ticket "${witness}" other
expect waited "a ticket ahead written before records held a start is kept while its pid runs"

# --- a read that fails part way gives nothing --------------------------------------------
# What a cut-short read printed is no part of the record, however well formed.
# The ticket's part names another start.
fresh 1; ticket "${witness}" other "${other_id}"; cut_short sed "${record}" 2
expect waited "a ticket ahead whose read fails part way is judged on its pid alone, and kept while the pid runs"
# The list cut short leaves out the live ticket ahead.
fresh 1; ticket "${witness}" other "${witness_id}"; fails ls "${home}/safedeps-runs/.queue" "${record##*/}"
expect waited "a queue whose list fails part way leaves the suite's place not known, so it waits"
fresh 1; fails date +%s
refuses "with no time from the clock for its ticket the runner refuses, and takes no ticket"
fresh 1; printf 'other\n' > "${home}/safedeps-runs/.queue/1-"
expect waited "a name in the queue that holds no pid is a ticket whose process is not known, and is kept"

# --- every other step a verdict rests on ----------------------------------------------------
# Before the runner holds a ticket, a step that fails leaves it without a value
# it queues on, so it refuses and leaves the queue as it was.
fresh 1; held .slot.lock; fails cat "${home}/safedeps-runs/.slots"
refuses "a .slots whose read fails leaves N not known, so the runner refuses rather than take a second slot"
fresh 1; held .slot.lock; fails ls "${home}/safedeps-runs"
refuses "a runs directory whose list fails leaves it not known whether .slots is there, so the runner refuses"
fresh 1; rm "${home}/safedeps-runs/.slots"; held .slot.lock
expect ran "a runs directory that holds no .slots has two slots, so the suite takes the second beside a live holder"
# What a failed dirname printed is no directory. The reader put there calls
# every process gone, so a runner that asked it would run past a live ticket.
fresh 1; ticket "${witness}" other "${witness_id}"
mkdir -p "${tmp_root}/stub/slot-lib"
printf '%s\n' 'def identity(pid): return "1 stub"' 'def running(row): return False' \
  > "${tmp_root}/stub/slot-lib/native_budget_owners.py"
fails dirname "${home}/safedeps-runs/slot.sh" "${tmp_root}/stub"
refuses "a dirname that fails gives no directory, so the runner refuses rather than ask a reader in what it printed"
rm -rf "${tmp_root}/stub"
fresh 1; rm "${home}/safedeps-runs/slot-lib/native_budget_owners.py"
refuses "with no reader beside it the runner refuses, and takes no ticket"
fresh 1; fails python3 identity "1 slot.sh"
refuses "a read of this run's start that fails gives no start, whatever it printed, so the runner refuses"
fresh 1; fails mkdir "${home}/safedeps-runs/.queue"
refuses "a queue whose mkdir fails is not known to be there, so the runner refuses"
fresh 1; fails mv "${home}/safedeps-runs/.queue/*"
refuses "a ticket that cannot be put in the queue leaves no place to wait for, so the runner refuses"
# Once it holds a ticket, a step that fails leaves its place not known or
# takes no slot, so the suite waits.
fresh 1; ticket "${witness}" other "${witness_id}"; fails sort ''
expect waited "a sort of the queue that fails gives no order, even when it printed the tickets behind, so the suite waits"
# The ticket ahead names the witness's pid plus 2^64, which an arithmetic read
# wraps onto the witness, and holds another start.
fresh 1
big=$(python3 -c 'import sys; print(2**64 + int(sys.argv[1]))' "${witness}")
printf '%s\n' other "${other_id}" > "${home}/safedeps-runs/.queue/$(( $(date +%s) - 100 ))-${big}"
expect waited "a name with more digits than a pid holds names no process, not the pid they wrap onto, and is kept"
fresh 1; ticket "${witness}" other "${witness_id}"; fails python3 "${witness}" gone
expect waited "a kernel answer that fails is no answer, even when it printed gone, so a live ticket ahead is kept"
# The lock call is the one step that takes a slot. One that fails for any
# reason but a holder takes nothing, and the runner says why; 1 is a holder.
fresh 1; fails perl '' "No locks available"; probe_rc=2
start; got=$(decided); stop "${suite}"
grep -qF "the lock call on ${home}/safedeps-runs/.slot.lock ended 2: No locks available" "${tmp_root}/err" \
  || got="${got}, and it did not say why"
read_seen
judged "a lock call that fails takes no slot, says why, and the suite waits"
# A directory where the slot's file goes cannot be opened for writing.
fresh 1; mkdir "${home}/safedeps-runs/.slot.lock"
start; got=$(decided); stop "${suite}"
grep -qF "${home}/safedeps-runs/.slot.lock could not be opened" "${tmp_root}/err" || got="${got}, and it did not say why"
read_seen
judged "a slot whose file cannot be opened is not taken, the runner says so, and the suite waits"

# --- as before --------------------------------------------------------------------------
fresh 1; ticket "${witness}" other "${witness_id}"
expect waited "a ticket ahead whose process runs keeps the suite behind it waiting"
fresh 1; held .slot.lock
expect waited "a slot whose process runs is not taken"

( cd "${tmp_root}" && exec sleep 0 ) &
ended=$!
wait "${ended}" || true
if kill -0 "${ended}" 2>/dev/null; then
  fail "a pid the kernel no longer has (pid ${ended} came back at once)"
else
  fresh 1; ticket "${ended}" other "${witness_id}"
  expect ran "a ticket ahead whose pid the kernel no longer has is gone"
  fresh 1; ticket "${ended}" other "${other_id}"; cut_short sed "${record}" 2
  expect ran "a ticket ahead whose read fails part way is still gone when the kernel has no such pid"
  # No run removes a ticket but its own, so a gone one stays where it is, and
  # the look that passed it over says how many it passed.
  fresh 1; ticket "${ended}" other "${witness_id}"
  start; got=$(decided); stop "${suite}"; read_seen
  [[ -e "${record}" ]] || got="${got}, and the gone ticket was removed"
  grep -qF "passed over in ${home}/safedeps-runs/.queue: 1 " "${tmp_root}/err" || got="${got}, and it did not say it passed over 1"
  label="a gone ticket ahead is passed over, left where it is and counted in what the runner says, and the suite behind it runs"
  if [[ "${got}" == ran ]]; then pass "${label}"; else fail "${label} (the suite: ${got})"; fi
fi

# A zombie: a child that ends after its parent became a sleep, which never
# reaps it. A child that ended before the exec could be reaped by bash.
( cd "${tmp_root}" && exec bash -c 'sleep 1 & printf "%s\n" "$!" > "$1"; exec -a "$2" sleep 600' _ "${tmp_root}/zombie" "${MARK}" ) &
children+=("$!")
zombie=""
for (( i = 0; i < 100; i++ )); do
  zombie=$(cat "${tmp_root}/zombie" 2>/dev/null || true)
  [[ -n "${zombie}" ]] && [[ "$(ps -o stat= -p "${zombie}" 2>/dev/null)" == Z* ]] && break
  sleep 0.1
done
if [[ -n "${zombie}" ]] && [[ "$(ps -o stat= -p "${zombie}" 2>/dev/null)" == Z* ]]; then
  fresh 1; ticket "${zombie}" other "${witness_id}"
  expect ran "a ticket ahead whose process is a zombie is gone"
else
  fail "the zombie fixture (pid '${zombie}' is not a zombie)"
fi

# A suite that holds the slot, and one behind it that runs once it is given back.
fresh 1
rm -f "${tmp_root}/holding" "${tmp_root}/release"
( cd "${tmp_root}" && HOME="${home}" exec "${home}/safedeps-runs/slot.sh" holder \
    bash -c ': > "$1"; while [ ! -e "$2" ]; do sleep 0.1; done' _ "${tmp_root}/holding" "${tmp_root}/release" "${MARK}" ) 2> /dev/null &
holder=$!
children+=("${holder}")
for (( i = 0; i < 600; i++ )); do [[ -e "${tmp_root}/holding" ]] && break; sleep 0.1; done
start
got=$(decided)
L="${home}/safedeps-runs/.slot.lock"
if [[ "${got}" == waited ]]; then
  : > "${tmp_root}/release"
  # The waiter looks again every 10 seconds.
  for (( i = 0; i < 600; i++ )); do [[ -e "${tmp_root}/ran" ]] && break; sleep 0.1; done
  wait "${holder}" 2>/dev/null || true
  wait "${suite}" 2>/dev/null || true
  if [[ -e "${tmp_root}/ran" && ! -s "${L}" && -z "$(ls "${home}/safedeps-runs/.queue")" ]] && is_free "${L}"; then
    pass "a suite behind a holder waits, then runs once the holder gives the slot back, and leaves the slot free, its label empty and no ticket"
  else
    fail "a suite behind a holder runs once the holder is done (ran: $([[ -e "${tmp_root}/ran" ]] && echo yes || echo no), free: $(is_free "${L}" && echo yes || echo no), label: '$(cat "${L}" 2>/dev/null || true)', queue: $(ls "${home}/safedeps-runs/.queue" | wc -l | tr -d ' '))"
  fi
else
  stop "${suite}"
  fail "a suite behind a holder waits (the suite: ${got})"
fi
: > "${tmp_root}/release"
stop "${holder}"

# --- the kernel holds the slots ---------------------------------------------------------
# A runner and its suite killed by SIGKILL run no trap, and leave their label
# and their ticket. The kernel lets go of the lock all the same, once the last
# open of the file is gone.
fresh 1
rm -f "${tmp_root}/killed.pid"
( cd "${tmp_root}" && HOME="${home}" exec "${home}/safedeps-runs/slot.sh" killed \
    bash -c 'printf "%s\n" "$$" > "$1.t" && mv "$1.t" "$1"; exec -a "$2" sleep 600' _ "${tmp_root}/killed.pid" "${MARK}" ) 2> /dev/null &
runner=$!
children+=("${runner}")
for (( i = 0; i < 600; i++ )); do [[ -e "${tmp_root}/killed.pid" ]] && break; sleep 0.1; done
killed=$(cat "${tmp_root}/killed.pid" 2>/dev/null || true)
label="a slot whose runner was killed with its suite is taken: the kernel let go of its lock, and the label left behind decides nothing"
if [[ -z "${killed}" ]]; then
  fail "${label} (the killed runner's suite never started)"
else
  children+=("${killed}")
  kill -9 "${killed}" "${runner}" 2>/dev/null || true
  wait "${runner}" 2>/dev/null || true
  for (( i = 0; i < 600; i++ )); do kill -0 "${killed}" 2>/dev/null || break; sleep 0.1; done
  expect ran "${label}"
fi
# What a slot's file holds is a label, and a label is no holder.
fresh 1; printf 'other since 00:00:00\n' > "${home}/safedeps-runs/.slot.lock"
expect ran "a slot whose file holds the label of a run that is gone, and whose lock no process holds, is taken"
# Two runs ask for one free slot at once. The other one, a runner of its own,
# takes it just before this suite's lock call: a hook on that call starts the
# other runner and waits until its suite runs. The second slot is held
# throughout, so the first is the one both want. The failure is two runs on
# one slot.
fresh 2; held .slot2.lock
rm -f "${tmp_root}/other-ran" "${tmp_root}/other.pid" "${tmp_root}/other-release" "${tmp_root}/other.err"
hook perl '' < <(
  printf '( cd %q && HOME=%q exec %q other bash -c %q _ %q %q %q ) < /dev/null > /dev/null 2> %q &\n' \
    "${tmp_root}" "${home}" "${home}/safedeps-runs/slot.sh" ': > "$1"; while [ ! -e "$2" ]; do sleep 0.1; done' \
    "${tmp_root}/other-ran" "${tmp_root}/other-release" "${MARK}" "${tmp_root}/other.err"
  printf 'printf "%%s\\n" "$!" > %q\n' "${tmp_root}/other.pid"
  printf 'for (( i = 0; i < 600; i++ )); do [[ -e %q ]] && break; sleep 0.1; done\n' "${tmp_root}/other-ran")
start
got=$(decided)
other=$(cat "${tmp_root}/other.pid" 2>/dev/null || true)
[[ -z "${other}" ]] || children+=("${other}")
if [[ ! -e "${tmp_root}/other-ran" ]]; then
  got="${got}, and the other run never took the slot: $(head -c 200 "${tmp_root}/other.err" 2>/dev/null | tr '\n' ' ' || true)"
else
  [[ "${got}" != ran ]] || got="${got} while the other run held .slot.lock, so two runs held one slot"
  ! is_free "${home}/safedeps-runs/.slot.lock" || got="${got}, and the slot the other run took was free"
fi
stop "${suite}"
read_seen
: > "${tmp_root}/other-release"
[[ -z "${other}" ]] || stop "${other}"
judged "two runs that ask for one free slot: the one whose lock call comes first keeps it, and the other waits"
# The suite shares the runner's open of the slot's file. A runner killed while
# its suite runs leaves the slot to the suite until the suite ends.
fresh 1
rm -f "${tmp_root}/kept.pid" "${tmp_root}/kept-end"
( cd "${tmp_root}" && HOME="${home}" exec "${home}/safedeps-runs/slot.sh" kept \
    bash -c 'printf "%s\n" "$$" > "$1.t" && mv "$1.t" "$1"; while [ ! -e "$2" ]; do sleep 0.1; done' \
    _ "${tmp_root}/kept.pid" "${tmp_root}/kept-end" "${MARK}" ) 2> /dev/null &
runner=$!
children+=("${runner}")
for (( i = 0; i < 600; i++ )); do [[ -e "${tmp_root}/kept.pid" ]] && break; sleep 0.1; done
kept=$(cat "${tmp_root}/kept.pid" 2>/dev/null || true)
if [[ -z "${kept}" ]]; then
  got="none: the holder's suite never started"
else
  children+=("${kept}")
  kill -9 "${runner}" 2>/dev/null || true
  wait "${runner}" 2>/dev/null || true
  start; got=$(decided); stop "${suite}"; read_seen
  kill -0 "${kept}" 2>/dev/null || got="${got}, and the holder's suite was not running"
  : > "${tmp_root}/kept-end"
  for (( i = 0; i < 600; i++ )); do kill -0 "${kept}" 2>/dev/null || break; sleep 0.1; done
  is_free "${home}/safedeps-runs/.slot.lock" || got="${got}, and the slot was still held once that suite ended"
fi
: > "${tmp_root}/kept-end"
judged "a runner killed while its suite runs leaves the slot to the suite until it ends, and a suite behind it waits"

# moongchi's handoff (the checkpoint of slot-stale-lock-race-1124) as a row.
# The first slot is free to take, and the second is held by a live process
# throughout, so one run at a time can run. B looks at the first slot and is
# held at the step where it acts on that look. A takes the slot, runs and ends
# normally. C passes a gone ticket and takes the slot. Then B acts on its look.
# The failure is B running beside C.
#
# B's PATH holds a pause at each step where a runner acts on its look. A
# runner that judges a slot's record pauses at its claim of the record (mv of
# the pid) and at its kernel question about the pid it claimed. A runner whose
# slot is a kernel lock pauses at its lock call (perl with LOCK_). Each pause
# holds once, until the row releases it, so the order is the row's and not
# the scheduler's. The slots are set up both ways, and a runner reads the form
# it knows: the first a directory with a gone record and no lock file, the
# second a directory with a live record and a lock file a live process holds.
H="${tmp_root}/handoff"
pause="${tmp_root}/pause"
mkdir -p "${pause}"
for tool in mv python3 perl; do
  {
    printf '#!/bin/bash\nreal=%q\n' "$(command -v "${tool}" || true)"
    case "${tool}" in
      mv) printf '%s\n' 'point=claim; [[ "$1" == "$HOME/safedeps-runs/.slot/pid" ]] || exec "${real}" "$@"' ;;
      python3) printf '%s\n' 'point=check' \
        '[[ "$4" == running && "$5" == "$(cat "${PAUSE_AT}/A.pid" 2>/dev/null)" ]] || exec "${real}" "$@"' \
        '[[ -e "$HOME/safedeps-runs/.slot/.reap-$(cat "${PAUSE_AT}/B.pid" 2>/dev/null)" ]] || exec "${real}" "$@"' ;;
      perl) printf '%s\n' 'point=lock; [[ "$*" == *LOCK_* ]] || exec "${real}" "$@"' ;;
    esac
    cat <<'EOF'
mkdir "${PAUSE_AT}/at-${point}" 2>/dev/null || exec "${real}" "$@"
for (( i = 0; i < 3000; i++ )); do [[ -e "${PAUSE_AT}/go-${point}" ]] && break; sleep 0.1; done
exec "${real}" "$@"
EOF
  } > "${pause}/${tool}"
  chmod +x "${pause}/${tool}"
done
# launch <name> [<dir>]: a runner named name in the background, with dir
# first on its PATH when given. Its suite marks $H/entered-<name> and runs
# until $H/end-<name> appears. $launched is the runner's pid, and what it
# says goes to $H/<name>.err.
launch() {
  local path="${PATH}"
  [[ -z "${2:-}" ]] || path="$2:${PATH}"
  ( cd "${tmp_root}" && exec env HOME="${home}" PATH="${path}" PAUSE_AT="${H}" "${home}/safedeps-runs/slot.sh" "$1" \
      bash -c ': > "$1"; while [ ! -e "$2" ]; do sleep 0.1; done' _ "${H}/entered-$1" "${H}/end-$1" "${MARK}" ) \
    < /dev/null > /dev/null 2> "${H}/$1.err" &
  launched=$!
  children+=("${launched}")
}
# appeared <path>...: whether one of the paths appeared within a minute.
appeared() {
  local i p
  for (( i = 0; i < 600; i++ )); do
    for p in "$@"; do [[ -e "${p}" ]] && return 0; done
    sleep 0.1
  done
  return 1
}
said() { tr '\n' ' ' < "${H}/$1.err" 2>/dev/null | head -c 200 || true; }
# handoff: the order above. It stops at the first step that did not come, and
# what went wrong goes into $got.
handoff() {
  local i rc
  lock_held "${home}/safedeps-runs/.slot2.lock" || { got="the second slot's lock was never held"; return; }
  launch B "${pause}"; B=${launched}; printf '%s\n' "${B}" > "${H}/B.pid"
  appeared "${H}/at-claim" "${H}/at-lock" || { got="B never came to its claim or its lock call: $(said B)"; return; }
  launch A; A=${launched}
  appeared "${H}/entered-A" || { got="A never ran: $(said A)"; return; }
  printf '%s\n' "${A}" > "${H}/A.pid"
  if [[ -e "${H}/at-claim" ]]; then
    : > "${H}/go-claim"
    appeared "${H}/at-check" || { got="B never asked the kernel about A after its claim: $(said B)"; return; }
  fi
  : > "${H}/end-A"
  for (( i = 0; i < 600; i++ )); do kill -0 "${A}" 2>/dev/null || break; sleep 0.1; done
  ! kill -0 "${A}" 2>/dev/null || { got="A did not end"; return; }
  rc=0; wait "${A}" || rc=$?; A=""
  [[ "${rc}" == 0 ]] || { got="A ended ${rc}, not 0: $(said A)"; return; }
  ticket "${witness}" other "${other_id}"
  launch C; C=${launched}
  appeared "${H}/entered-C" || { got="C never ran: $(said C)"; return; }
  : > "${H}/go-check"; : > "${H}/go-lock"
  for (( i = 0; i < 600; i++ )); do
    [[ ! -e "${H}/entered-B" ]] || break
    ! grep -q 'slots busy' "${H}/B.err" 2>/dev/null || break
    sleep 0.1
  done
  if [[ -e "${H}/entered-B" ]]; then
    got="B ran beside C, so two runs held one slot"
  elif ! grep -q 'slots busy' "${H}/B.err" 2>/dev/null; then
    got="B decided nothing within a minute: $(said B)"
  fi
  kill -0 "${C}" 2>/dev/null || got="${got:+${got}, and }C is not running"
}
fresh 2; slot "${witness}" "${other_id}"; slot_in .slot2 "${witness}" "${witness_id}"
rm -rf "${H}"; mkdir -p "${H}"
got=""; A=""; B=""; C=""; locker=""
handoff
for f in go-claim go-check go-lock end-A end-B end-C; do : > "${H}/${f}"; done
for p in "${B}" "${C}" "${A}" "${locker}"; do [[ -z "${p}" ]] || stop "${p}"; done
locker=""
label="a waiter that acts on its look after A took the slot, ran and ended, and C took it, does not run beside C"
if [[ -z "${got}" ]]; then pass "${label}"; else fail "${label} (${got})"; fi

# --- a run that cannot name itself or take a lock does not queue ---------------------------
fresh 1
bin="${tmp_root}/bin-${row}"
mkdir -p "${bin}"
for tool in bash cat date dirname ls mkdir mv rm sed sleep sort tr wc; do
  ln -s "$(command -v "${tool}")" "${bin}/${tool}"
done
# The copy before the fix, with no ps on PATH, drops its own ticket and waits.
refuses "with no reader for its own start the runner refuses, and takes no ticket" PATH="${bin}"
fresh 1
bin="${tmp_root}/bin-${row}"
mkdir -p "${bin}"
for tool in bash cat date dirname ls mkdir mv python3 rm sed sleep sort tr wc; do
  ln -s "$(command -v "${tool}")" "${bin}/${tool}"
done
refusal="no perl"
refuses "with no perl to take a slot's lock the runner refuses, and takes no ticket" PATH="${bin}"

# --- the installed copy names its source ---------------------------------------------------
want_slot="# installed from scripts/ci/slot.sh sha256 $(sha "${ROOT_DIR}/scripts/ci/slot.sh")"
want_lib="# installed from scripts/test/lib/native_budget_owners.py sha256 $(sha "${ROOT_DIR}/scripts/test/lib/native_budget_owners.py")"
fresh 1
if [[ "$(sed -n 2p "${home}/safedeps-runs/slot-lib/native_budget_owners.py")" == "${want_lib}" ]] \
  && { [[ "${script}" != "${ROOT_DIR}/scripts/ci/slot.sh" ]] \
       || { [[ "$(sed -n 2p "${home}/safedeps-runs/slot.sh")" == "${want_slot}" ]] \
            && cmp -s <(sed 2d "${home}/safedeps-runs/slot.sh") "${ROOT_DIR}/scripts/ci/slot.sh"; }; } \
  && cmp -s <(sed 2d "${home}/safedeps-runs/slot-lib/native_budget_owners.py") "${ROOT_DIR}/scripts/test/lib/native_budget_owners.py" \
  && [[ -x "${home}/safedeps-runs/slot.sh" ]] && [[ -z "$(ls -A "${home}/safedeps-runs" | grep '\.new\.' || true)" ]]; then
  pass "an installed copy holds its source's path and sha256 on line 2, and the source's bytes around it"
else
  fail "an installed copy holds its source's path and sha256 on line 2"
fi

(( failures == 0 )) || { printf '# %d row(s) failed\n' "${failures}"; exit 1; }
