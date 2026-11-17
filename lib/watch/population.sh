#!/usr/bin/env bash
# The population: which project roots a scan measures, asked at scan time.
#
# safedeps knows a command, not who answers it. The installer records the
# command in ${SAFEDEPS_HOME}/watch/config.json (`population_command`, an argv
# array with an absolute path first). Each line it prints is `name<TAB>path` or
# a bare absolute path. The scan runs it under the watch lock, with a time
# limit, right before it measures, so a project registered yesterday is in
# today's scan.
#
#   fresh    the command exited 0 and printed at least one root
#   stale    no command, or it failed, timed out or printed nothing: the
#            previous scan's list is used, with its own generated_at, and the
#            report says projects registered since may be missing
#   missing  no list at all: the population stage is unmeasured
#
# Only `fresh` can back a claim that every project was measured.

SAFEDEPS_WATCH_POPULATION_TIMEOUT_DEFAULT=120

safedeps_watch_config_file() {
  printf '%s/config.json' "$(safedeps_watch_dir)"
}

# One field of the config as JSON, or `null` when the file or field is absent.
# A config that is not a JSON object is an error, not an empty config.
safedeps_watch_config_get() {
  local file
  file=$(safedeps_watch_config_file)
  if [[ ! -f "${file}" ]]; then
    printf 'null\n'
    return 0
  fi
  jq -c --arg key "$1" 'if type == "object" then (.[$key] // null) else error("config is not an object") end' "${file}" 2>/dev/null
}

# Runs ARGV with stdout to OUT and stderr to ERR, ending it after SECONDS.
# Returns its exit, or 124 when the time ran out. The child does not inherit
# the watch lock (9>&-), so a child that outlives the run does not hold it.
safedeps_watch_run_limited() {
  local seconds="$1" out="$2" err="$3" pid ticks=0 limit rc=0
  shift 3
  ( exec 9>&-; exec "$@" ) > "${out}" 2> "${err}" < /dev/null &
  pid=$!
  limit=$((seconds * 10))
  while kill -0 "${pid}" 2>/dev/null; do
    if [[ "${ticks}" -ge "${limit}" ]]; then
      kill -TERM "${pid}" 2>/dev/null || true
      sleep 1
      kill -KILL "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
      return 124
    fi
    sleep 0.1
    ticks=$((ticks + 1))
  done
  wait "${pid}" || rc=$?
  return "${rc}"
}

# Prints the population block for a full scan:
#   {state, generated_at, source, exit, reason, roots:[{name,path}]}
# PRIOR is the previous state's population block (or null).
safedeps_watch_population_measure() {
  local prior="$1" now="$2" tmp="$3"
  local command_json timeout source rc=0 reason="" roots_json arg
  local -a argv=()

  local config_ok=1
  command_json=$(safedeps_watch_config_get population_command) || { command_json=null; config_ok=0; }
  timeout=$(safedeps_watch_config_get population_timeout_seconds) || timeout=null
  [[ "${timeout}" =~ ^[0-9]+$ ]] || timeout="${SAFEDEPS_WATCH_POPULATION_TIMEOUT_DEFAULT}"

  if [[ "${config_ok}" -eq 0 ]]; then
    reason="config_unreadable"
    source=""
  elif [[ "${command_json}" == "null" ]] || ! jq -e 'type == "array" and length > 0 and all(.[]; type == "string") and (.[0] | startswith("/"))' <<< "${command_json}" >/dev/null 2>&1; then
    reason="no_population_command"
    source=""
  else
    source=$(jq -r 'join(" ")' <<< "${command_json}")
    while IFS= read -r -d '' arg; do argv+=("${arg}"); done < <(jq -j '.[] | . + "\u0000"' <<< "${command_json}")
    if [[ ! -x "${argv[0]}" ]]; then
      reason="command_not_executable"
    else
      safedeps_watch_run_limited "${timeout}" "${tmp}/population.out" "${tmp}/population.err" "${argv[@]}" || rc=$?
      if [[ "${rc}" -eq 124 ]]; then
        reason="timeout_${timeout}s"
      elif [[ "${rc}" -ne 0 ]]; then
        reason="exit_${rc}"
      fi
    fi
  fi

  if [[ -z "${reason}" ]]; then
    if ! roots_json=$(jq -R -s -c '
        split("\n")
        | map(select(length > 0))
        | map(if test("\t") then {name: (split("\t")[0]), path: (split("\t")[1:] | join("\t"))} else {name: (split("/") | last), path: .} end)
        | map(select(.path | startswith("/")))
        | unique_by(.path)' "${tmp}/population.out"); then
      reason="unreadable_output"
    elif [[ "$(jq 'length' <<< "${roots_json}")" -eq 0 ]]; then
      reason="empty_output"
    fi
  fi

  if [[ -z "${reason}" ]]; then
    jq -nc --arg at "${now}" --arg source "${source}" --argjson roots "${roots_json}" \
      '{state:"fresh", generated_at:$at, source:$source, exit:0, reason:null, roots:$roots}'
    return 0
  fi

  if [[ "${prior}" != "null" ]] && jq -e '(.roots // []) | length > 0' <<< "${prior}" >/dev/null 2>&1; then
    jq -c --arg source "${source}" --arg reason "${reason}" --argjson exit "${rc}" \
      '{state:"stale", generated_at:.generated_at, source:$source, exit:$exit, reason:$reason, roots:.roots}' <<< "${prior}"
    return 0
  fi
  jq -nc --arg source "${source}" --arg reason "${reason}" --argjson exit "${rc}" \
    '{state:"missing", generated_at:null, source:$source, exit:$exit, reason:$reason, roots:[]}'
}
