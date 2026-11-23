#!/usr/bin/env bash
# safedeps: the test hosts' queue runner, scripts/ci/slot.sh.
#
#   scripts/test/slot-queue.sh [--script <slot.sh>]
#
# Each row installs the runner as a host gets it (scripts/ci/install-slot.sh)
# into a home of its own, puts one record in the queue or in a slot, starts a
# suite behind it and reads what the runner decided: the suite ran, or the
# runner said the slots are busy. Both are things the runner does, so a row
# waits for one of them and needs no clock but a ceiling.
#
# The records name a live process of this battery's own, a sleep, by its pid.
# A record with the start the kernel holds for it is that process; one with
# another start is a process gone after a reboot whose pid came back. With
# --script the rows judge another copy of slot.sh, as the red controls do: the
# copy before the fix waits behind both records.
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
stop() { pkill -TERM -P "$1" 2>/dev/null || true; kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }
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
fresh() { # slots: a home with the runner installed and the queue empty
  row=$((row + 1))
  home="${tmp_root}/home-${row}"
  mkdir -p "${home}"
  bash "${ROOT_DIR}/scripts/ci/install-slot.sh" | HOME="${home}" bash -s > "${tmp_root}/install.out"
  [[ "${script}" == "${ROOT_DIR}/scripts/ci/slot.sh" ]] || cp "${script}" "${home}/safedeps-runs/slot.sh"
  printf '%s\n' "$1" > "${home}/safedeps-runs/.slots"
  mkdir -p "${home}/safedeps-runs/.queue"
}
ticket() { # pid, then the lines it holds; $record is its path
  local pid="$1"; shift
  record="${home}/safedeps-runs/.queue/$(( $(date +%s) - 100 ))-$(printf %07d "${pid}")"
  printf '%s\n' "$@" > "${record}"
}
slot() { # pid, then the identity it holds or nothing
  mkdir -p "${home}/safedeps-runs/.slot"
  [[ $# -lt 2 ]] || printf '%s\n' "$2" > "${home}/safedeps-runs/.slot/identity"
  printf '%s\n' "$1" > "${home}/safedeps-runs/.slot/pid"
  printf 'other since 00:00:00\n' > "${home}/safedeps-runs/.slot/owner"
}
# A read cut short. The runner of the next row finds these tools first on its
# PATH. Given the path in PROBE_FILE, one prints what an I/O error part way
# through the read leaves, the bytes in PROBE_CUT (sed reads that file in the
# path's place), notes the read in PROBE_SEEN and exits 1. Every other call is
# the real tool's.
probe="${tmp_root}/probe"
mkdir -p "${probe}"
{
  printf '#!/bin/bash\n'
  printf 'real_cat=%q real_sed=%q\n' "$(command -v cat)" "$(command -v sed)"
  cat <<'EOF'
tool=${0##*/}; real=real_${tool}; real=${!real}
hit=""
for a in "$@"; do [[ -n "${PROBE_FILE:-}" && "${a}" == "${PROBE_FILE}" ]] && hit=1; done
[[ -n "${hit}" ]] || exec "${real}" "$@"
case "${tool}" in
  sed) args=(); for a in "$@"; do [[ "${a}" == "${PROBE_FILE}" ]] && a=${PROBE_CUT}; args+=("${a}"); done
       "${real}" "${args[@]}" ;;
  *) "${real_cat}" "${PROBE_CUT}" ;;
esac
: > "${PROBE_SEEN}"
exit 1
EOF
} > "${probe}/cut-short"
chmod +x "${probe}/cut-short"
for tool in cat sed; do ln -s cut-short "${probe}/${tool}"; done
probe_file=""
cut_short() { # path, bytes: the next row's runner reads path to all but its last bytes, and the read fails
  probe_file="$1"
  head -c "$(( $(wc -c < "$1") - $2 ))" "$1" > "${tmp_root}/cut"
}

# start: a suite behind the records, in the background; $suite is its pid.
start() {
  rm -f "${tmp_root}/ran" "${tmp_root}/err" "${tmp_root}/seen"
  local env=(HOME="${home}")
  [[ -z "${probe_file}" ]] || env+=(PATH="${probe}:${PATH}" PROBE_FILE="${probe_file}" PROBE_CUT="${tmp_root}/cut" PROBE_SEEN="${tmp_root}/seen")
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
  # A row with a read cut short holds only if the runner read that record.
  [[ -z "${probe_file}" || -e "${tmp_root}/seen" ]] || got="${got}, and it never read ${probe_file##*/}"
  probe_file=""
  if [[ "${got}" == "$1" ]]; then pass "$2"; else fail "$2 (the suite: ${got})"; fi
}

# --- a pid the kernel handed out again ----------------------------------------------
fresh 1; ticket "${witness}" other "${other_id}"
expect ran "a ticket ahead whose pid runs under another start is gone, and the suite behind it runs"
fresh 1; slot "${witness}" "${other_id}"
expect ran "a slot whose pid runs under another start is gone, and the suite takes it"

# --- what is not known stays ----------------------------------------------------------
fresh 1; ticket "${witness}" other "not an identity"
expect waited "a ticket ahead whose record holds no start it can read is kept"
fresh 1; ticket "${witness}" other
expect waited "a ticket ahead written before records held a start is kept while its pid runs"
fresh 1; slot "${witness}"
expect waited "a slot written before records held a start is kept while its pid runs"

# --- a read that fails part way gives nothing --------------------------------------------
# What a cut-short read printed is no part of the record, however well formed.
# The ticket's part names another start; the slot's part is the pid's first
# digits, another pid.
fresh 1; ticket "${witness}" other "${other_id}"; cut_short "${record}" 2
expect waited "a ticket ahead whose read fails part way is judged on its pid alone, and kept while the pid runs"
if (( witness >= 20 )); then
  fresh 1; slot "${witness}" "${witness_id}"; cut_short "${home}/safedeps-runs/.slot/pid" 2
  expect waited "a slot whose pid read fails after its first digits is not taken"
else
  fail "a slot whose pid read fails after its first digits (the witness pid ${witness} has no first digits that are a pid)"
fi

# --- as before --------------------------------------------------------------------------
fresh 1; ticket "${witness}" other "${witness_id}"
expect waited "a ticket ahead whose process runs keeps the suite behind it waiting"
fresh 1; slot "${witness}" "${witness_id}"
expect waited "a slot whose process runs is not taken"

( cd "${tmp_root}" && exec sleep 0 ) &
ended=$!
wait "${ended}" || true
if kill -0 "${ended}" 2>/dev/null; then
  fail "a pid the kernel no longer has (pid ${ended} came back at once)"
else
  fresh 1; ticket "${ended}" other "${witness_id}"
  expect ran "a ticket ahead whose pid the kernel no longer has is gone"
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
( cd "${tmp_root}" && HOME="${home}" exec "${home}/safedeps-runs/slot.sh" holder \
    bash -c 'while [ ! -e "$1" ]; do sleep 0.1; done' _ "${tmp_root}/release" "${MARK}" ) 2> /dev/null &
holder=$!
children+=("${holder}")
for (( i = 0; i < 600; i++ )); do [[ -e "${home}/safedeps-runs/.slot/owner" ]] && break; sleep 0.1; done
start
got=$(decided)
if [[ "${got}" == waited ]]; then
  : > "${tmp_root}/release"
  # The waiter looks again every 10 seconds.
  for (( i = 0; i < 600; i++ )); do [[ -e "${tmp_root}/ran" ]] && break; sleep 0.1; done
  wait "${holder}" 2>/dev/null || true
  wait "${suite}" 2>/dev/null || true
  if [[ -e "${tmp_root}/ran" && ! -e "${home}/safedeps-runs/.slot" && -z "$(ls "${home}/safedeps-runs/.queue")" ]]; then
    pass "a suite behind a holder waits, then runs once the holder gives the slot back, and leaves nothing"
  else
    fail "a suite behind a holder runs once the holder is done (ran: $([[ -e "${tmp_root}/ran" ]] && echo yes || echo no), slot left: $([[ -e "${home}/safedeps-runs/.slot" ]] && echo yes || echo no), queue: $(ls "${home}/safedeps-runs/.queue" | wc -l | tr -d ' '))"
  fi
else
  stop "${suite}"
  fail "a suite behind a holder waits (the suite: ${got})"
fi
: > "${tmp_root}/release"
stop "${holder}"

# --- a run the kernel cannot name does not queue ------------------------------------------
fresh 1
bin="${tmp_root}/bin-${row}"
mkdir -p "${bin}"
for tool in bash cat date dirname ls mkdir mv rm sed sleep sort tr wc; do
  ln -s "$(command -v "${tool}")" "${bin}/${tool}"
done
# The runner refuses at once. One that queues instead never ends, as the copy
# before the fix does (with no ps on PATH it drops its own ticket and waits),
# so it is stopped after a minute and the row says so.
( cd "${tmp_root}" && HOME="${home}" PATH="${bin}" exec "${home}/safedeps-runs/slot.sh" row true "${MARK}" ) \
  > /dev/null 2> "${tmp_root}/err" &
refuser=$!
children+=("${refuser}")
for (( i = 0; i < 600; i++ )); do kill -0 "${refuser}" 2>/dev/null || break; sleep 0.1; done
if kill -0 "${refuser}" 2>/dev/null; then
  stop "${refuser}"
  rc="none within a minute"
else
  set +e
  wait "${refuser}"
  rc=$?
  set -e
fi
if [[ "${rc}" == 2 ]] && grep -q 'not queueing' "${tmp_root}/err" && [[ -z "$(ls "${home}/safedeps-runs/.queue")" ]]; then
  pass "with no reader for its own start the runner refuses, and takes no ticket"
else
  fail "with no reader for its own start the runner refuses (exit ${rc}, tickets: $(ls "${home}/safedeps-runs/.queue" | wc -l | tr -d ' '))"
fi

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
