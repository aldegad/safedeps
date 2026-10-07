#!/usr/bin/env bash
# safedeps: run the test suite on our own hosts, and judge the run as one.
#
#   scripts/ci/run-on-hosts.sh [--release] [--hosts NAME,...] [--hosts-file FILE]
#                              [--rev REV] [--logs DIR] [--only UNIT,...]
#
#   --release      the release set (`npm run test:release`); without it, the
#                  development set (`npm test`)
#   --hosts        the hosts to use, by name; default every host in the file
#   --hosts-file   default ${XDG_CONFIG_HOME:-~/.config}/safedeps/test-hosts
#   --rev          the commit to test; default HEAD. Uncommitted changes are
#                  not tested, and the run says so.
#   --logs         where the logs land, a directory that does not exist yet or
#                  is empty; default a new directory under TMPDIR
#   --only         run these units alone (a comma-separated list), to try the
#                  runner itself. Such a run is red by construction: the verdict
#                  judges the whole set, and names the units that did not run.
#
# Our CI is our own hosts (owner, 2026-10-06). The release set took 46 to 62
# minutes on the largest of them alone. So this splits a set into units
# (scripts/test/run-all.sh --units: whole batteries, battery shards and census
# shards), runs them on several hosts at once, collects every log, and judges
# the logs together with scripts/test/ci-verdict.sh.
#
# The commit goes to each host as `git archive` output, into a directory of
# this run's own, which mktemp creates there: two runs never share one, and
# each unit's files name it, so the verdict can tell this run's files from
# another's. On each host the run takes one slot of the host's queue (the
# queue command in the host file, e.g. slot.sh) and keeps it until the last
# unit there ends, so it waits for the suites ahead of it and is counted by the
# ones behind it. Units start detached and report through files
# (scripts/ci/remote.sh), because a link to a host can drop for minutes while
# its work runs on. The longest units start first, each on a host with enough
# free CPUs for its weight, so a slow host takes fewer of them.
#
# A run is red when any unit failed, printed `not ok`, skipped a row the
# verdict does not allow, or never ran; when the shards of a battery or of the
# census do not add up to the whole; and when a host failed. A host fails when
# the run cannot reach it at the start, when it stops answering for
# HOST_TIMEOUT seconds, or when a unit's process there is gone without its
# exit status. Its running units fail with it; the run does not move them
# elsewhere and call the result green. A host that is reachable but never
# gets its queue slot runs nothing, and the run says so.
#
# A host given up as failed is sent a stop at once, and again at the end if it
# did not answer then; one that answers at the end has its logs collected like
# any other. A run that is interrupted (INT, TERM, HUP) stops its units on
# every host first. A coordinator killed outright stops nothing, so the units
# watch the run's heartbeat themselves (scripts/ci/remote.sh).
#
# A run prints its wall clock from the first queue slot it gets, and beside
# it the wait for the suites ahead in the queues. A run has no time budget.
#
# Exit status: 0 green, 1 red, 2 a usage or setup error.
#
# The host file has one host per line, fields separated by `|`, `#` comments:
#
#   name|ssh destination|ssh options|cpus|queue|PATH prefix|runs directory[|holds]
#
# cpus is how many CPUs of the host the run may keep busy; queue is the
# command that takes the host's slot, given an owner name and a command, or
# `-` for none; the PATH prefix may use $HOME and is put before the host's PATH
# for every unit; the runs directory is relative to the remote home; holds is
# how many slots of the queue the run takes, 1 when it is left out. A queue
# with two slots lets one other suite share the host with a run that holds
# one; a run that holds both has the host to itself, and starts its units
# there only once it holds both. See scripts/ci/test-hosts.example. The file stays outside the repository: host
# addresses are not for a public tree.
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "${ROOT_DIR}" || exit 2

POLL_SECONDS=5
HOST_TIMEOUT=180
UNIT_TIMEOUT=1500

die() { printf 'run-on-hosts: %s\n' "$1" >&2; exit 2; }
usage() {
  printf 'usage: %s [--release] [--hosts NAME,...] [--hosts-file FILE] [--rev REV] [--logs DIR] [--only UNIT,...]\n' "$0" >&2
  exit 2
}

set_flag="" pick="" only="" hosts_file="${XDG_CONFIG_HOME:-${HOME}/.config}/safedeps/test-hosts" rev=HEAD logs=""
while (( $# > 0 )); do
  case "$1" in
    --release) set_flag=--release; shift ;;
    --hosts) [[ -n "${2:-}" ]] || usage; pick="$2"; shift 2 ;;
    --hosts-file) [[ -n "${2:-}" ]] || usage; hosts_file="$2"; shift 2 ;;
    --rev) [[ -n "${2:-}" ]] || usage; rev="$2"; shift 2 ;;
    --logs) [[ -n "${2:-}" ]] || usage; logs="$2"; shift 2 ;;
    --only) [[ -n "${2:-}" ]] || usage; only="$2"; shift 2 ;;
    *) usage ;;
  esac
done

# --- hosts ------------------------------------------------------------------------
[[ -r "${hosts_file}" ]] || die "no host file at ${hosts_file} (see scripts/ci/test-hosts.example)"
H_NAME=() H_DEST=() H_OPTS=() H_CPUS=() H_QUEUE=() H_PATH=() H_DIR=() H_HOLDS=()
while IFS='|' read -r name dest opts cpus queue path dir holds extra; do
  [[ -n "${name}" && "${name}" != \#* ]] || continue
  [[ -z "${extra}" && -n "${dir}" ]] || die "host ${name}: a line has seven fields, or eight with holds"
  holds="${holds:-1}"
  [[ "${holds}" =~ ^[1-9]$ ]] || die "host ${name}: holds is a number of queue slots, 1 to 9"
  [[ "${queue}" != - || "${holds}" == 1 ]] || die "host ${name}: a host with no queue has no slots to hold"
  [[ "${name}" =~ ^[a-z][a-z0-9-]*$ ]] || die "host name ${name}: lower-case letters, digits and dashes"
  [[ "${cpus}" =~ ^[1-9][0-9]*$ ]] || die "host ${name}: cpus must be a whole number"
  [[ "${dir}" =~ ^[A-Za-z0-9._/-]+$ && "${dir}" != /* && "${dir}" != *..* ]] \
    || die "host ${name}: the runs directory is a plain path under the remote home"
  if [[ -n "${pick}" ]]; then
    case ",${pick}," in *",${name},"*) ;; *) continue ;; esac
  fi
  H_NAME+=("${name}") H_DEST+=("${dest}") H_OPTS+=("${opts}") H_CPUS+=("${cpus}")
  H_QUEUE+=("${queue}") H_PATH+=("${path}") H_DIR+=("${dir}") H_HOLDS+=("${holds}")
done < "${hosts_file}"
(( ${#H_NAME[@]} > 0 )) || die "no host named in ${hosts_file}${pick:+ matches ${pick}}"
if [[ -n "${pick}" ]]; then
  IFS=',' read -r -a wanted <<< "${pick}"
  for name in "${wanted[@]}"; do
    case " ${H_NAME[*]} " in *" ${name} "*) ;; *) die "--hosts names ${name}, which ${hosts_file} does not" ;; esac
  done
fi

# --- the commit -------------------------------------------------------------------
sha=$(git rev-parse --verify "${rev}^{commit}" 2>/dev/null) || die "${rev} is not a commit"
dirty=""
[[ "${rev}" != HEAD ]] || [[ -z "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]] \
  || dirty=" (the working tree has uncommitted changes; they are not tested)"
run_id="$(date +%Y%m%d-%H%M%S)-${sha:0:7}-$$"

if [[ -z "${logs}" ]]; then
  logs=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-hosts.XXXXXX") || die "cannot create a log directory"
elif [[ -d "${logs}" && -n "$(ls -A "${logs}")" ]]; then
  # The verdict reads every unit's files under the directory.
  die "--logs ${logs} is not empty; another run's files there would be judged with this run's"
fi
mkdir -p "${logs}/hosts" "${logs}/coordinator" || die "cannot create ${logs}"
logs=$(cd "${logs}" && pwd)
# The ssh control sockets go in a short directory of their own: a socket path
# has a length limit (104 bytes on macOS) that a TMPDIR path can pass.
sock=$(mktemp -d /tmp/sdci.XXXXXX) || die "cannot create a socket directory"
work="${logs}/coordinator"
archive="${work}/tree.tar"
git archive --format=tar "${sha}" > "${archive}" || die "git archive ${sha} failed"
tree="${work}/tree"
mkdir -p "${tree}" || die "cannot create ${tree}"
tar -xf "${archive}" -C "${tree}" || die "cannot unpack the archive"

# --- units ------------------------------------------------------------------------
# <unit> <weight> <seconds>, the most CPU-seconds (weight times seconds) first.
# Ordered by seconds alone, the units that fill a whole host waited behind the
# single-CPU ones and ran last, alone, after the hosts had emptied.
bash "${tree}/scripts/test/run-all.sh" --plan ${set_flag} > "${work}/plan" 2>"${work}/plan.err" \
  || die "run-all.sh --plan failed: $(head -c 200 "${work}/plan.err")"
awk '{ print $1, $2, $3, $2 * $3 }' "${work}/plan" | sort -k4,4nr -k1,1 > "${work}/plan.sorted"
U_NAME=() U_WEIGHT=() U_STATE=() U_HOST=() U_START=()
while read -r unit weight _; do
  if [[ -n "${only}" ]]; then
    case ",${only}," in *",${unit},"*) ;; *) continue ;; esac
  fi
  U_NAME+=("${unit}") U_WEIGHT+=("${weight}") U_STATE+=(pending) U_HOST+=("") U_START+=(0)
done < "${work}/plan.sorted"
(( ${#U_NAME[@]} > 0 )) || die "the plan has no units"

now() { date +%s; }
stamp() { date +%H:%M:%S; }
event() { printf '%s %s\n' "$(stamp)" "$1" | tee -a "${work}/events.log"; }
fail_unit() { # index reason
  U_STATE[$1]=failed
  printf '%s\n' "$2" > "${work}/${U_NAME[$1]}.failed"
  event "FAIL ${U_NAME[$1]}: $2"
}

# ssh_host INDEX COMMAND: one short command on a host, through a shared
# connection. The command is built here from names this script checked.
ssh_host() {
  local h="$1" opts=() word
  # shellcheck disable=SC2206 # the host file's ssh options are words
  local given=(${H_OPTS[h]})
  for word in ${given[@]+"${given[@]}"}; do
    # A word of the host file that starts with ~/ names a local file.
    # shellcheck disable=SC2088 # the literal ~/ is what is matched
    [[ "${word}" != "~/"* ]] || word="${HOME}/${word#\~/}"
    opts+=("${word}")
  done
  ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 \
    -o ControlMaster=auto -o "ControlPath=${sock}/%C" -o ControlPersist=120 \
    ${opts[@]+"${opts[@]}"} "${H_DEST[h]}" "$2"
}

# Loads: when the tree was shipped (H_LOAD0), when the run took the host's
# slots and its work began there (H_LOADH), and at the end (H_LOAD1). H_RUN is
# the run's directory on the host, empty until the host has created it, and
# H_STOPPED says the host answered a stop.
H_STATE=() H_SEEN=() H_RUN=() H_STOPPED=() H_LOAD0=() H_LOADH=() H_LOAD1=()
for (( h = 0; h < ${#H_NAME[@]}; h++ )); do
  H_STATE+=(new) H_SEEN+=(0) H_RUN+=("") H_STOPPED+=(0) H_LOAD0+=("") H_LOADH+=("") H_LOAD1+=("")
done

# The run directory a host created, from what the ship command printed: a
# `run <path>` line naming a directory mktemp made under the host's runs
# directory for this run, or nothing.
shipped_run() { # index
  local run leaf
  run=$(sed -n 's/^run //p' "${work}/ship-${H_NAME[$1]}.out" 2>/dev/null | head -n 1)
  leaf="${run#"${H_DIR[$1]}/${run_id}."}"
  [[ "${run}" == "${H_DIR[$1]}/${run_id}."* && "${leaf}" =~ ^[A-Za-z0-9]+$ ]] || return 1
  printf '%s' "${run}"
}

# Stops the run's units on a host and releases its queue slots. Succeeds when
# the host answered.
stop_host() { # index
  [[ -n "${H_RUN[$1]}" ]] || return 1
  ssh_host "$1" "bash ${H_RUN[$1]}/tree/scripts/ci/remote.sh stop ${H_RUN[$1]}" \
    >> "${work}/stop-${H_NAME[$1]}.out" 2>&1 || return 1
  H_STOPPED[$1]=1
}

host_dead() { # index reason
  H_STATE[$1]=dead
  printf '%s\n' "$2" > "${work}/host-${H_NAME[$1]}.dead"
  event "HOST ${H_NAME[$1]} FAILED: $2"
  local u
  for (( u = 0; u < ${#U_NAME[@]}; u++ )); do
    [[ "${U_STATE[u]}" == running && "${U_HOST[u]}" == "$1" ]] || continue
    fail_unit "${u}" "its host ${H_NAME[$1]} failed: $2"
  done
  # A failed host may still be running the run's units: one that gave up its
  # queue slot answers, and one that stopped answering may come back. Neither
  # is polled again, so the units would run on, outside the queue once the
  # hold lets the slot go.
  if [[ -n "${H_RUN[$1]}" ]]; then
    if stop_host "$1"; then
      event "${H_NAME[$1]}: its units are stopped"
    else
      event "${H_NAME[$1]}: the stop did not reach it; it is tried again at the end"
    fi
  fi
}

interrupted() {
  local h
  event "interrupted: stopping every unit"
  for (( h = 0; h < ${#H_NAME[@]}; h++ )); do
    # Interrupted while shipping, a host may have created its directory and
    # started a queue waiter before the coordinator read the name back.
    [[ -n "${H_RUN[h]}" ]] || H_RUN[h]=$(shipped_run "${h}") || continue
    stop_host "${h}" \
      || event "${H_NAME[h]}: the stop did not reach it; its units stop themselves once nothing polls them (scripts/ci/remote.sh)"
    event "${H_NAME[h]}: the run's directory stays there: ${H_RUN[h]}"
  done
  exit 130
}
cleanup() { rm -rf "${sock}"; }
trap cleanup EXIT
# HUP too: a coordinator in a terminal that closes gets HUP, and with no trap
# for it the run's units went on with nothing to stop them.
trap interrupted INT TERM HUP

suite_start=$(now)
first_held=""
{
  printf 'commit %s%s\n' "${sha}" "${dirty}"
  printf 'set %s\n' "$([[ -n "${set_flag}" ]] && printf release || printf development)"
  printf 'hosts %s (from %s)\n' "${H_NAME[*]}" "${hosts_file}"
  printf 'units %d%s\n' "${#U_NAME[@]}" "${only:+ (--only ${only}: the verdict judges the whole set, so this run is red)}"
  printf 'start %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
} > "${work}/run.txt"
event "safedeps tests on our hosts: $(sed -n 2p "${work}/run.txt" | cut -d' ' -f2) set, ${#U_NAME[@]} units, commit ${sha:0:12}${dirty}, hosts ${H_NAME[*]}, logs ${logs}"

# --- ship and take the queue ----------------------------------------------------------
for (( h = 0; h < ${#H_NAME[@]}; h++ )); do
  (
    # mktemp, not `mkdir -p`: a directory another run left under the same
    # name would be taken as this run's, its units' exit status read as
    # theirs. The name is printed before anything else, so a ship that fails
    # half way still names what it left there. \$run is the remote shell's.
    ssh_host "${h}" "mkdir -p ${H_DIR[h]} && run=\$(mktemp -d ${H_DIR[h]}/${run_id}.XXXXXX) && printf 'run %s\n' \"\$run\" && mkdir \"\$run/tree\" \"\$run/out\" && tar -x -C \"\$run/tree\"" \
      < "${archive}" > "${work}/ship-${H_NAME[h]}.out" 2>&1 || exit 1
    run=$(shipped_run "${h}") || { printf 'the host named no run directory of this run\n' >> "${work}/ship-${H_NAME[h]}.out"; exit 1; }
    printf '%s\n' "${H_PATH[h]}" | ssh_host "${h}" "cat > ${run}/path" >> "${work}/ship-${H_NAME[h]}.out" 2>&1 || exit 1
    holders=""
    for (( k = 1; k <= H_HOLDS[h]; k++ )); do
      if [[ "${H_QUEUE[h]}" == - ]]; then
        holder="bash ${run}/tree/scripts/ci/remote.sh hold ${run} ${k}"
      else
        holder="${H_QUEUE[h]} safedeps-ci-${run_id}-${k} bash ${run}/tree/scripts/ci/remote.sh hold ${run} ${k}"
      fi
      holders+="nohup ${holder} > ${run}/hold-${k}.log 2>&1 < /dev/null & echo \$! > ${run}/queue-${k}.pid; "
    done
    ssh_host "${h}" "${holders}uptime" >> "${work}/ship-${H_NAME[h]}.out" 2>&1 || exit 1
  ) &
  ship_pid[h]=$!
done
for (( h = 0; h < ${#H_NAME[@]}; h++ )); do
  wait "${ship_pid[h]}"
  ship_rc=$?
  # Read back whether the ship worked or not: a ship that failed after the
  # host created the directory leaves it, and maybe a queue waiter, there.
  if H_RUN[h]=$(shipped_run "${h}"); then
    # The verdict takes a unit's files as this run's only when they name this.
    printf '%s\n' "${H_RUN[h]##*/}" > "${work}/host-${H_NAME[h]}.run"
  fi
  if (( ship_rc == 0 )); then
    H_STATE[h]=queued H_SEEN[h]=$(now)
    H_LOAD0[h]=$(sed -E -n 's/.*load averages?: *//p' "${work}/ship-${H_NAME[h]}.out" | tr -d ',' | tail -n 1)
    event "${H_NAME[h]}: shipped, waiting for ${H_HOLDS[h]} queue slot(s) (load ${H_LOAD0[h]})"
  else
    host_dead "${h}" "could not ship the tree or take the queue: $(tail -n 2 "${work}/ship-${H_NAME[h]}.out" 2>/dev/null | tr '\n' ' ' | head -c 200)"
  fi
done

# --- schedule ---------------------------------------------------------------------
pending_count() { local u n=0; for (( u = 0; u < ${#U_NAME[@]}; u++ )); do [[ "${U_STATE[u]}" != pending ]] || n=$((n + 1)); done; printf '%s' "${n}"; }
running_count() { local u n=0; for (( u = 0; u < ${#U_NAME[@]}; u++ )); do [[ "${U_STATE[u]}" != running ]] || n=$((n + 1)); done; printf '%s' "${n}"; }
unit_index() { local u; for (( u = 0; u < ${#U_NAME[@]}; u++ )); do [[ "${U_NAME[u]}" != "$1" ]] || { printf '%s' "${u}"; return 0; }; done; return 1; }
live_hosts() { local h n=0; for (( h = 0; h < ${#H_NAME[@]}; h++ )); do [[ "${H_STATE[h]}" == dead ]] || n=$((n + 1)); done; printf '%s' "${n}"; }

while (( $(pending_count) > 0 || $(running_count) > 0 )); do
  if (( $(live_hosts) == 0 )); then
    for (( u = 0; u < ${#U_NAME[@]}; u++ )); do
      [[ "${U_STATE[u]}" != pending ]] || fail_unit "${u}" "no host was left to run it"
    done
    break
  fi
  # Poll every live host at once.
  for (( h = 0; h < ${#H_NAME[@]}; h++ )); do
    [[ "${H_STATE[h]}" != dead ]] || continue
    ( ssh_host "${h}" "bash ${H_RUN[h]}/tree/scripts/ci/remote.sh status ${H_RUN[h]}" \
        > "${work}/poll-${H_NAME[h]}" 2>&1; printf '%s\n' "$?" > "${work}/poll-${H_NAME[h]}.exit" ) &
  done
  wait
  for (( h = 0; h < ${#H_NAME[@]}; h++ )); do
    [[ "${H_STATE[h]}" != dead ]] || continue
    poll="${work}/poll-${H_NAME[h]}"
    if [[ "$(cat "${poll}.exit" 2>/dev/null)" != 0 ]] || ! grep -q '^load ' "${poll}"; then
      if (( $(now) - H_SEEN[h] >= HOST_TIMEOUT )); then
        host_dead "${h}" "no answer for ${HOST_TIMEOUT}s ($(tail -n 1 "${poll}" 2>/dev/null | head -c 160))"
      fi
      continue
    fi
    H_SEEN[h]=$(now)
    H_LOAD1[h]=$(sed -n 's/^load //p' "${poll}")
    held_now=$(sed -n 's/^held //p' "${poll}")
    if [[ "${H_STATE[h]}" == queued ]] && (( ${held_now:-0} >= H_HOLDS[h] )); then
      H_STATE[h]=held H_LOADH[h]="${H_LOAD1[h]} at $(stamp)"
      [[ -n "${first_held}" ]] || first_held=$(now)
      event "${H_NAME[h]}: holds ${H_HOLDS[h]} queue slot(s) (load ${H_LOAD1[h]})"
    elif [[ "${H_STATE[h]}" == held ]] && (( ${held_now:-0} < H_HOLDS[h] )); then
      host_dead "${h}" "it gave up its queue slot while the run still had work"
      continue
    fi
    while read -r _ unit state rc; do
      u=$(unit_index "${unit}") || continue
      [[ "${U_STATE[u]}" == running && "${U_HOST[u]}" == "${h}" ]] || continue
      case "${state}" in
        done)
          U_STATE[u]="done"
          event "${H_NAME[h]}: ${unit} done rc=${rc} in $(( $(now) - U_START[u] ))s" ;;
        lost) fail_unit "${u}" "its process on ${H_NAME[h]} is gone and left no exit status" ;;
        running)
          if (( $(now) - U_START[u] > UNIT_TIMEOUT )); then
            ssh_host "${h}" "bash ${H_RUN[h]}/tree/scripts/ci/remote.sh stop ${H_RUN[h]} ${unit}" >/dev/null 2>&1 || true
            fail_unit "${u}" "it ran past ${UNIT_TIMEOUT}s on ${H_NAME[h]} and was stopped"
          fi ;;
      esac
    done < <(grep '^unit ' "${poll}")
  done
  # Start the longest pending units on hosts with room for them. A unit
  # heavier than a whole host runs there alone.
  for (( h = 0; h < ${#H_NAME[@]}; h++ )); do
    [[ "${H_STATE[h]}" == held ]] || continue
    used=0
    for (( u = 0; u < ${#U_NAME[@]}; u++ )); do
      [[ "${U_STATE[u]}" == running && "${U_HOST[u]}" == "${h}" ]] && used=$(( used + U_WEIGHT[u] ))
    done
    for (( u = 0; u < ${#U_NAME[@]}; u++ )); do
      [[ "${U_STATE[u]}" == pending ]] || continue
      (( used + U_WEIGHT[u] <= H_CPUS[h] || used == 0 )) || continue
      if out=$(ssh_host "${h}" "bash ${H_RUN[h]}/tree/scripts/ci/remote.sh start ${H_RUN[h]} ${U_NAME[u]}" 2>&1) \
        || [[ "${out}" == *"already started"* ]]; then
        U_STATE[u]=running U_HOST[u]="${h}" U_START[u]=$(now)
        used=$(( used + U_WEIGHT[u] ))
        event "${H_NAME[h]}: start ${U_NAME[u]} (weight ${U_WEIGHT[u]}, ${used}/${H_CPUS[h]} CPUs)"
      else
        event "${H_NAME[h]}: could not start ${U_NAME[u]} (${out:0:160}); trying again"
        break
      fi
    done
  done
  (( $(pending_count) > 0 || $(running_count) > 0 )) || break
  sleep "${POLL_SECONDS}"
done
suite_end=$(now)

# --- collect ------------------------------------------------------------------------
for (( h = 0; h < ${#H_NAME[@]}; h++ )); do
  run="${H_RUN[h]}"
  # A host that never created its run directory has nothing there.
  [[ -n "${run}" ]] || continue
  if [[ "${H_STATE[h]}" == dead ]]; then
    # A failed host the stop did not reach is tried once more. One that
    # answers now has its units stopped and its logs collected like any other;
    # the run is red for its failure either way.
    if (( H_STOPPED[h] == 0 )); then
      if ! stop_host "${h}"; then
        event "${H_NAME[h]}: still does not answer; ${run} stays there, and its units stop themselves once nothing polls them (scripts/ci/remote.sh)"
        continue
      fi
      event "${H_NAME[h]}: answers again, and its units are stopped"
    fi
  else
    stop_host "${h}" || true
    [[ "${H_STATE[h]}" == held ]] || event "${H_NAME[h]}: never got its ${H_HOLDS[h]} queue slot(s), so it ran nothing"
  fi
  mkdir -p "${logs}/hosts/${H_NAME[h]}"
  if ssh_host "${h}" "uptime; tar -C ${run}/out -cf - . > ${run}/out.tar" > "${work}/end-${H_NAME[h]}.out" 2>&1 \
    && ssh_host "${h}" "cat ${run}/out.tar" | tar -xf - -C "${logs}/hosts/${H_NAME[h]}"; then
    H_LOAD1[h]=$(sed -E -n 's/.*load averages?: *//p' "${work}/end-${H_NAME[h]}.out" | tr -d ',' | tail -n 1)
    ssh_host "${h}" "rm -rf ${run}" >/dev/null 2>&1 || event "${H_NAME[h]}: could not remove ${run}; remove it by hand"
  elif [[ "${H_STATE[h]}" == dead ]]; then
    event "${H_NAME[h]}: its logs could not be collected; they stay in ${run} there"
  else
    host_dead "${h}" "its logs could not be collected; they stay in ${run} there"
  fi
done

# The run's own time starts at the first queue slot; before it the run waited
# for other suites. A run that never got a slot ran nothing and is red anyway.
[[ -n "${first_held}" ]] || first_held="${suite_end}"
secs=$(( suite_end - first_held ))
waited=$(( first_held - suite_start ))
{
  printf 'end %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
  printf 'wall %ss from the first queue slot, after %ss waiting for the queues\n' "${secs}" "${waited}"
  for (( h = 0; h < ${#H_NAME[@]}; h++ )); do
    printf 'host %s %s cpus %s holds %s load when shipped %s, when its slots were held %s, at end %s\n' \
      "${H_NAME[h]}" "${H_STATE[h]}" "${H_CPUS[h]}" "${H_HOLDS[h]}" "${H_LOAD0[h]:-?}" "${H_LOADH[h]:-never}" "${H_LOAD1[h]:-?}"
  done
} >> "${work}/run.txt"

# --- verdict ------------------------------------------------------------------------
cat "${work}/run.txt"
bash "${tree}/scripts/test/ci-verdict.sh" ${set_flag} "${logs}" 2>&1 | tee "${work}/verdict.txt"
verdict_rc=${PIPESTATUS[0]}
# The tree and its archive are what the run shipped; the logs are what it made.
rm -rf "${tree}" "${archive}"
if (( verdict_rc != 0 )); then
  printf '# RED: see %s\n' "${logs}"
  exit 1
fi
printf '# green in %ss\n' "${secs}"
exit 0
