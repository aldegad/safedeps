#!/usr/bin/env bash
# One watch run: measure, merge with the last complete generation, publish the
# next one whole. The caller holds the watch lock (lib/watch/lock.sh) for the
# whole of it, so the generation it read is the one it replaces.
#
# ${SAFEDEPS_HOME}/watch/state.json is the only thing a reader consumes. It is
# written to a temporary file in the same directory, checked, flushed and
# renamed over the old one, so a reader sees the previous generation or the new
# one and never a part. A run that fails before the rename leaves the previous
# generation and its last_success_at as they were. Each run leaves a receipt in
# watch/runs/<run id>.json with its exit, whatever it published.

SAFEDEPS_WATCH_RECEIPTS_KEEP=100
SAFEDEPS_WATCH_EVENT_RETENTION_DAYS=30
# The lockfile stage keeps its provider files in a cache of its own (watch/cache).
# OSV answers are kept nowhere: every scan asks OSV live. The OSV records it reads
# are kept there under the (id, modified) the answer gave, with no TTL. What this
# bounds is the KEV catalog alone; the stage asks GHSA nothing.
SAFEDEPS_WATCH_CACHE_TTL_SECONDS=3600

safedeps_watch_state_file() {
  printf '%s/state.json' "$(safedeps_watch_dir)"
}

safedeps_watch_jq() {
  jq -L "${SAFEDEPS_REPO_DIR}/lib/watch" "$@"
}

# A pause at a named point, for the battery that interrupts a run there
# (scripts/test/watch.sh). With SAFEDEPS_WATCH_PAUSE_AT naming this point, the
# run creates SAFEDEPS_WATCH_PAUSE_FILE and waits until it is removed (60 s at
# most). It only waits: it changes nothing a run does.
safedeps_watch_pause() {
  [[ -n "${SAFEDEPS_WATCH_PAUSE_AT:-}" && "${SAFEDEPS_WATCH_PAUSE_AT}" == "$1" && -n "${SAFEDEPS_WATCH_PAUSE_FILE:-}" ]] || return 0
  : > "${SAFEDEPS_WATCH_PAUSE_FILE}"
  local n=0
  while [[ -e "${SAFEDEPS_WATCH_PAUSE_FILE}" && "${n}" -lt 600 ]]; do
    sleep 0.1
    n=$((n + 1))
  done
}

# The last complete generation, or the empty document when there is none. A
# file that is there and is not a generation is an error: the run stops rather
# than start over and drop the events nobody has delivered.
safedeps_watch_read_state() {
  local file
  file=$(safedeps_watch_state_file)
  if [[ ! -e "${file}" ]]; then
    safedeps_watch_jq -nc 'include "state"; empty_state'
    return
  fi
  safedeps_watch_jq -ce 'include "state"; if is_watch_state then . else error("not a watch state") end' "${file}" 2>/dev/null
}

# Publishes DOC (a file) as the next generation.
safedeps_watch_publish() {
  local doc="$1" dir tmp
  dir=$(safedeps_watch_dir)
  [[ ! -d "${dir}/state.json" ]] || return 1
  tmp=$(mktemp "${dir}/.state.json.XXXXXX") || return 1
  if ! cat "${doc}" > "${tmp}" \
    || ! safedeps_watch_jq -e 'include "state"; is_watch_state' "${tmp}" >/dev/null 2>&1; then
    rm -f "${tmp}"
    return 1
  fi
  chmod 600 "${tmp}" 2>/dev/null || true
  safedeps_watch_pause before_publish
  sync
  if ! mv -f "${tmp}" "${dir}/state.json"; then
    rm -f "${tmp}"
    return 1
  fi
  sync
  safedeps_watch_pause after_publish
}

# Writes a run's receipt, and keeps the newest SAFEDEPS_WATCH_RECEIPTS_KEEP.
safedeps_watch_receipt() {
  local run_id="$1" json="$2" dir tmp old
  dir="$(safedeps_watch_dir)/runs"
  ( umask 077; mkdir -p "${dir}" ) || return 1
  tmp=$(mktemp "${dir}/.receipt.XXXXXX") || return 1
  printf '%s\n' "${json}" > "${tmp}" && mv -f "${tmp}" "${dir}/${run_id}.json" || { rm -f "${tmp}"; return 1; }
  # Names sort by time: the run id starts with the UTC time.
  while IFS= read -r old; do
    [[ -n "${old}" ]] && rm -f "${dir}/${old}"
  done < <(ls -1 "${dir}" 2>/dev/null | grep '\.json$' | LC_ALL=C sort -r | tail -n +$((SAFEDEPS_WATCH_RECEIPTS_KEEP + 1)))
}

safedeps_watch_new_run_id() {
  printf '%s-%s' "$(date -u +%Y%m%dT%H%M%SZ)" "$$"
}

# This machine's core as a path under a runtime or its checkout:
# bin/native/<os>-<arch>/safedeps-core, the platform read from the machine bash
# was built for, as the CLI reads it when it looks for its core beside itself
# (sf_core in lib/providers/providers.sh). Prints nothing and returns 1 for a machine no core
# is built for. The installer asks this for the core it copies and counts
# (machineCore in scripts/install/install-safedeps-recheck-agent.mjs), so the
# two digests count one file.
safedeps_watch_core_file() {
  local machine="${BASH_VERSINFO[5]:-}" os="" arch=""
  case "${machine}" in
    *-darwin*) os=darwin ;;
    *-linux*) os=linux ;;
  esac
  case "${machine%%-*}" in
    arm64|aarch64) arch=arm64 ;;
    x86_64|amd64) arch=x64 ;;
  esac
  [[ -n "${os}" && -n "${arch}" ]] || return 1
  printf 'bin/native/%s-%s/safedeps-core\n' "${os}" "${arch}"
}

# What a command returned and said, as {exit, said, lines}: EXIT, the first
# three lines of FILE (what it wrote to stderr) and how many lines that was.
# With ROOT, the root's path in the words is written as "." (<root>/ as ./,
# <root>: as .:). Words that cannot be read back are null, not none.
safedeps_watch_said_json() {
  local rc="$1" file="$2" root="${3:-}"
  jq -nc --argjson exit "${rc}" --arg root "${root}" --rawfile said "${file}" '
    ($said | split("\n") | if length > 0 and last == "" then .[:-1] else . end) as $lines
    | {exit: $exit,
       said: ($lines[:3] | if $root == "" then . else map(split($root + "/") | join("./") | split($root + ":") | join(".:")) end),
       lines: ($lines | length)}' \
    || printf '{"exit":%s,"said":null,"lines":null}\n' "${rc}"
}

# The files a runtime is built from, hashed the way the installer hashes them
# (scripts/install/install-safedeps-recheck-agent.mjs runtimeDigest): one
# "<sha256>  <path>" line per file, paths in byte order, and the hash of that.
#
# Each step keeps its own exit and its own words (RECORD.<step>), and the exit
# alone says whether it failed: what a step that ended 0 wrote is no reason.
# The first step that fails, in the order they run, ends the digest. It prints
# no digest, returns 1 and writes RECORD as {step, exit, said, lines}, with the
# words of that step alone. A hash of what could be read is not the tree's,
# and the installer has none for such a tree either. RECORD is a file the
# caller names; the words of each step are removed before it returns.
#   find    cd to ROOT and list the files (cd's words when cd fails)
#   sort    put the paths in byte order
#   shasum  hash each file
#   digest  hash the "<sha256>  <path>" lines
safedeps_watch_tree_digest() {
  local root="$1" record="${2:-}" step="" rc=0 list="" sorted="" p sums="" digest="" core
  local -a files=()
  [[ -n "${record}" ]] || { printf 'safedeps_watch_tree_digest: no RECORD file named\n' >&2; return 1; }
  [[ "${record}" == /* ]] || record="${PWD}/${record}"
  core=$(safedeps_watch_core_file) || core=""
  list=$( { cd "${root}" && find bin/safedeps lib scripts/safedeps-recheck-alert.sh ${core:+"${core}"} -type f; } 2> "${record}.find" ) \
    || { rc=$?; step=find; }
  if [[ -z "${step}" ]]; then
    sorted=$(LC_ALL=C sort 2> "${record}.sort" <<< "${list}") || { rc=$?; step=sort; }
  fi
  if [[ -z "${step}" ]]; then
    while IFS= read -r p; do
      if [[ -n "${p}" ]]; then files+=("${p}"); fi
    done <<< "${sorted}"
    if [[ "${#files[@]}" -gt 0 ]]; then
      sums=$( { cd "${root}" && shasum -a 256 "${files[@]}"; } 2> "${record}.shasum" ) || { rc=$?; step=shasum; }
    fi
  fi
  # The lines end with one newline each, as shasum wrote them; a here-string
  # gives back the one the substitution took. No file, no line: empty input.
  if [[ -z "${step}" ]]; then
    if [[ "${#files[@]}" -gt 0 ]]; then
      digest=$(shasum -a 256 2> "${record}.digest" <<< "${sums}") || { rc=$?; step=digest; }
    else
      digest=$(shasum -a 256 2> "${record}.digest" < /dev/null) || { rc=$?; step=digest; }
    fi
  fi
  if [[ -n "${step}" ]]; then
    jq -c --arg step "${step}" '{step: $step} + .' <<< "$(safedeps_watch_said_json "${rc}" "${record}.${step}")" > "${record}" \
      || printf '{"step":"%s","exit":%s,"said":null,"lines":null}\n' "${step}" "${rc}" > "${record}"
  fi
  rm -f "${record}.find" "${record}.sort" "${record}.shasum" "${record}.digest"
  [[ -z "${step}" ]] || return 1
  printf '%s\n' "${digest%% *}"
}

# What this run is: {version, digest, source_repo, built_at, stale}. A runtime
# the installer built carries .safedeps-runtime.json; a checkout carries none
# and answers with its own version and digest. stale is true when the checkout
# the runtime was built from has moved on, null when that cannot be told. A
# checkout that could not be read is one that cannot be told: stale is null,
# source_unreadable is the record of the step that failed ({step, exit, said,
# lines}) and error carries the first line that step said. RECORD is a file
# for that record.
safedeps_watch_runtime_info() {
  local record="$1" meta="${SAFEDEPS_REPO_DIR}/.safedeps-runtime.json" digest_now="" repo unreadable='null'
  if [[ ! -f "${meta}" ]]; then
    jq -nc --arg version "${SAFEDEPS_VERSION}" '{version:$version, built:false, digest:null, source_repo:null, built_at:null, stale:null}'
    return 0
  fi
  repo=$(jq -r '.source_repo // ""' "${meta}" 2>/dev/null)
  if [[ -n "${repo}" && -f "${repo}/bin/safedeps" ]]; then
    : > "${record}"
    if ! digest_now=$(safedeps_watch_tree_digest "${repo}" "${record}"); then
      digest_now=""
      unreadable=$(jq -ce 'select(type == "object" and (.step | type) == "string")' "${record}" 2>/dev/null) \
        || unreadable='{"step":null,"exit":null,"said":null,"lines":null}'
    fi
  fi
  jq -c --arg now "${digest_now}" --argjson unreadable "${unreadable}" '
    {version, built:true, digest, source_repo, built_at,
     source_digest_now: (if $now == "" then null else $now end),
     stale: (if $now == "" then null else ($now != .digest) end)}
    + (if $unreadable == null then {} else
        {source_unreadable: $unreadable,
         error: ("source checkout unreadable: "
                 + (if ($unreadable.said | type) == "array" and ($unreadable.said | length) > 0 then $unreadable.said[0]
                    elif $unreadable.said == [] then "exit \($unreadable.exit), nothing said"
                    elif $unreadable.step == null then "the read left no record"
                    else "exit \($unreadable.exit), words not read" end))} end)' "${meta}" 2>/dev/null \
    || jq -nc --arg version "${SAFEDEPS_VERSION}" '{version:$version, built:true, digest:null, stale:null, error:"runtime metadata unreadable"}'
}

# Reads ${SAFEDEPS_HOME}/watch/retired: `<root path><TAB><evidence>` a line,
# written by `safedeps watch retire`. Prints a JSON array.
safedeps_watch_retired() {
  local file
  file="$(safedeps_watch_dir)/retired"
  if [[ ! -f "${file}" ]]; then
    printf '[]\n'
    return 0
  fi
  jq -R -s -c 'split("\n") | map(select(test("\t")) | {root: (split("\t")[0]), evidence: (split("\t")[1:] | join("\t"))})' "${file}"
}

# The scan. KIND is full or root; ROOT is the root of a root run. Prints the
# run's report. Returns 0, 1 when it published with errors, 3 when it could not
# publish.
safedeps_watch_scan() {
  local kind="$1" only="${2:-}"
  local run_id now started tmp prior population roots_json runtime_info rc=0
  local dir excluded_count=0 root_count
  run_id=$(safedeps_watch_new_run_id)
  started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  now="${started}"
  dir=$(safedeps_watch_dir)
  tmp=$(safedeps_provider_mktemp_dir) || return 3
  safedeps_watch_pause after_lock

  # A temporary file left by a run that died before its rename is no writer's
  # now: this run holds the lock.
  find "${dir}" -maxdepth 1 -name '.state.json.*' -type f -exec rm -f {} + 2>/dev/null || true

  if ! prior=$(safedeps_watch_read_state); then
    safedeps_watch_receipt "${run_id}" "$(jq -nc --arg id "${run_id}" --arg at "${started}" --arg kind "${kind}" \
      '{run_id:$id, kind:$kind, started_at:$at, finished_at:$at, exit:3, published:false, error:"state_unreadable"}')" || true
    jq -nc --arg file "$(safedeps_watch_state_file)" '{command:"watch scan", exit:3, error:"state_unreadable", state_file:$file}'
    rm -rf "${tmp}"
    return 3
  fi
  printf '%s\n' "${prior}" > "${tmp}/prior.json"
  runtime_info=$(safedeps_watch_runtime_info "${tmp}/digest-step.json")

  : > "${tmp}/roots.jsonl"
  : > "${tmp}/findings.jsonl"
  : > "${tmp}/status.jsonl"
  : > "${tmp}/errors.jsonl"
  : > "${tmp}/unmeasured.jsonl"
  : > "${tmp}/scopes.txt"
  : > "${tmp}/unmeasured-scopes.jsonl"
  : > "${tmp}/unmeasured-prefixes.jsonl"
  : > "${tmp}/skipped.jsonl"
  : > "${tmp}/npm-list.tsv"
  : > "${tmp}/jdks.jsonl"

  # ---- the ledger stage (full runs) -------------------------------------------
  local ledger='null' ledger_rc=0
  # The CLI's own re-check, as this process's child: it inherits the lock and
  # knows it from SAFEDEPS_WATCH_LOCK_HELD. Exit 0 or 1 comes with its report;
  # anything else (4, a ledger it could not list) is a stage that failed.
  if [[ "${kind}" == "full" ]]; then
    SAFEDEPS_WATCH_LOCK_HELD=$$ "${SAFEDEPS_REPO_DIR}/bin/safedeps" --json re-check \
      > "${tmp}/ledger.json" 2> "${tmp}/ledger.err" || ledger_rc=$?
    if [[ "${ledger_rc}" -le 1 ]] && jq -e '.command == "re-check" and (.checked | type) == "number"' "${tmp}/ledger.json" > /dev/null 2>&1; then
      ledger=$(jq -c . "${tmp}/ledger.json")
      jq -c '.errors[]? | . + {kind: ("ledger_" + .kind)}' <<< "${ledger}" >> "${tmp}/errors.jsonl"
    else
      jq -nc --argjson rc "${ledger_rc}" --arg said "$(jq -r '.error? // empty' "${tmp}/ledger.json" 2>/dev/null | head -1)" \
        '{kind:"ledger_stage_failed", exit:$rc, error:(if $said == "" then null else $said end)}' >> "${tmp}/errors.jsonl"
    fi
  fi

  # ---- the population -----------------------------------------------------------
  if [[ "${kind}" == "full" ]]; then
    population=$(safedeps_watch_population_measure "$(jq -c '.population' <<< "${prior}")" "${now}" "${tmp}")
    roots_json=$(jq -c '.roots' <<< "${population}")
    if [[ "$(jq -r '.state' <<< "${population}")" != "fresh" ]]; then
      jq -c '{kind:("population_" + .state), reason}' <<< "${population}" >> "${tmp}/errors.jsonl"
      jq -c '{kind:("population_" + .state), root:null, path:null,
              reason:(if .state == "stale" then "provider failed (" + .reason + "); the list of " + (.generated_at // "?") + " was used, and projects registered since may be missing"
                      else "no population list (" + .reason + "); the population stage is unmeasured" end)}' \
        <<< "${population}" >> "${tmp}/unmeasured.jsonl"
    fi
  else
    population='null'
    roots_json=$(jq -c --arg only "${only}" '[(.population.roots // [])[] | select(.path == $only)] | if length == 0 then [{name: ($only | split("/") | last), path: $only}] else . end' <<< "${prior}")
  fi

  local mounts_ok=1
  safedeps_watch_mounts_load || mounts_ok=0
  if ! safedeps_watch_excludes_load; then
    mounts_ok=0
    jq -nc '{kind:"exclude_file_unreadable"}' >> "${tmp}/errors.jsonl"
  fi
  [[ "${mounts_ok}" -eq 1 ]] || jq -nc '{kind:"mount_table_unreadable"}' >> "${tmp}/errors.jsonl"

  # ---- each root -----------------------------------------------------------------
  local name path class_line class detail resolved list_rc walk rel base kc fkind fclass since
  local skip_class skip_path skip_fs skip_rel
  while IFS= read -r -d '' name && IFS= read -r -d '' path; do
    if [[ "${mounts_ok}" -ne 1 ]]; then
      class="unreachable"; detail="mount_table_unreadable"
    else
      class_line=$(safedeps_watch_classify_root "${path}")
      class="${class_line%%$'\t'*}"
      detail="${class_line#*$'\t'}"
    fi
    case "${class}" in
      ok)
        resolved="${detail}"
        list_rc=0
        # Emptied first, so a root never reads as what the last one said.
        : > "${tmp}/walk.said"
        safedeps_watch_list_files "${resolved}" "${tmp}/files.bin" "${tmp}/walk.said" || list_rc=$?
        # What the walk returned and said: find's exit, its first three lines
        # with the root written as ".", and how many lines it said. The exit
        # alone decides whether the walk was whole; the words are recorded
        # either way, and safedeps names no reason of its own. Words that
        # cannot be read back are null, not none.
        walk=$(safedeps_watch_said_json "${list_rc}" "${tmp}/walk.said" "${resolved}")
        jq -nc --arg name "${name}" --arg path "${path}" --arg resolved "${resolved}" --argjson partial "$([[ "${list_rc}" -eq 0 ]] && echo false || echo true)" \
          --argjson walk "${walk}" \
          '{name:$name, path:$path, resolved:$resolved, class:"ok", partial:$partial, walk:$walk}' >> "${tmp}/roots.jsonl"
        # A walk that did not finish did not look everywhere, so a lockfile it
        # did not list is not missing: a finding of this root that the run
        # does not see again keeps root_walk_incomplete as its reason.
        if [[ "${list_rc}" -ne 0 ]]; then
          jq -nc --arg root "${path}" --argjson walk "${walk}" '{kind:"root_walk_incomplete", root:$root} + $walk' >> "${tmp}/errors.jsonl"
          jq -nc --arg root "${path}" '{scope:($root + "|*"), reason:"root_walk_incomplete"}' >> "${tmp}/unmeasured-scopes.jsonl"
        fi
        # What the walk left out is said, not only skipped. A network mount
        # inside the root is unmeasured like a root that is one, with its
        # follow-up; an excluded prefix is named on the root. Either way a
        # finding under it that is not seen again keeps its reason.
        while IFS=$'\t' read -r skip_class skip_path skip_fs; do
          [[ -n "${skip_class}" ]] || continue
          skip_rel="./${skip_path#"${resolved}"/}"
          jq -nc --arg root "${path}" --arg rel "${skip_rel}" --arg class "${skip_class}" --arg fs "${skip_fs}" \
            '{root:$root, path:$rel, class:$class, fs:(if $fs == "-" then null else $fs end)}' >> "${tmp}/skipped.jsonl"
          jq -nc --arg root "${path}" --arg prefix "${skip_rel}/" --arg reason "${skip_class}" \
            '{root:$root, prefix:$prefix, reason:$reason}' >> "${tmp}/unmeasured-prefixes.jsonl"
          if [[ "${skip_class}" == remote_mount ]]; then
            jq -nc --arg root "${path}" --arg rel "${skip_rel}" --arg fs "${skip_fs}" --arg mp "${skip_path}" \
              '{kind:"remote_mount", root:$root, path:$rel, reason:("network or unlisted filesystem " + $fs + " mounted at " + $mp + " inside the root; not read on this host")}' \
              >> "${tmp}/unmeasured.jsonl"
          fi
        done < <(safedeps_watch_skipped_under "${resolved}")
        while IFS= read -r -d '' rel; do
          base="${rel##*/}"
          kc=$(safedeps_watch_kind_of "${base}") || continue
          fkind="${kc%%|*}"
          fclass="${kc#*|}"
          case "${fclass}" in
            npm)
              printf '%s\t%s\n' "${path}" "${rel}" >> "${tmp}/npm-list.tsv"
              ;;
            native:*)
              safedeps_watch_measure_native "${path}" "${rel}" "${fclass#native:}" "${tmp}/findings.jsonl" "${tmp}/status.jsonl" "${tmp}"
              ;;
            pin)
              safedeps_watch_pin_jdk "${path}" "${rel}" "${fkind}" >> "${tmp}/jdks.jsonl" 3>> "${tmp}/unmeasured.jsonl"
              ;;
            container)
              jq -nc --arg root "${path}" --arg rel "${rel}" --arg reason "$(safedeps_watch_unmeasured_reason container_image)" \
                --arg from "$(sed -n 's/^[[:space:]]*[Ff][Rr][Oo][Mm][[:space:]][[:space:]]*\([^[:space:]]*\).*/\1/p' "${path}/${rel#./}" 2>/dev/null | head -5 | paste -sd ' ' -)" \
                '{kind:"container_image", root:$root, path:$rel, reason:$reason, from:($from | split(" ") | map(select(length > 0)))}' >> "${tmp}/unmeasured.jsonl"
              ;;
            unmeasured)
              jq -nc --arg kind "${fkind}" --arg root "${path}" --arg rel "${rel}" --arg reason "$(safedeps_watch_unmeasured_reason "${fkind}")" \
                '{kind:$kind, root:$root, path:$rel, reason:$reason}' >> "${tmp}/unmeasured.jsonl"
              ;;
          esac
        done < "${tmp}/files.bin"
        ;;
      remote_mount)
        jq -nc --arg name "${name}" --arg path "${path}" --arg detail "${detail}" \
          '{name:$name, path:$path, class:"remote_mount", mount:($detail | split("\t")[0]), fs:($detail | split("\t")[1])}' >> "${tmp}/roots.jsonl"
        jq -nc --arg root "${path}" --arg detail "${detail}" \
          '{kind:"remote_mount", root:$root, path:null, reason:("network or unlisted filesystem " + ($detail | split("\t")[1]) + " mounted at " + ($detail | split("\t")[0]) + "; not read on this host")}' >> "${tmp}/unmeasured.jsonl"
        jq -nc --arg root "${path}" '{scope:($root + "|*"), reason:"remote_mount"}' >> "${tmp}/unmeasured-scopes.jsonl"
        ;;
      excluded)
        excluded_count=$((excluded_count + 1))
        jq -nc --arg name "${name}" --arg path "${path}" '{name:$name, path:$path, class:"excluded"}' >> "${tmp}/roots.jsonl"
        jq -nc --arg root "${path}" '{scope:($root + "|*"), reason:"excluded"}' >> "${tmp}/unmeasured-scopes.jsonl"
        ;;
      *)
        since=$(jq -r --arg p "${path}" --arg now "${now}" '(.roots[$p] | select(.class == "unreachable") | .since) // $now' <<< "${prior}")
        jq -nc --arg name "${name}" --arg path "${path}" --arg reason "${detail}" --arg since "${since}" \
          '{name:$name, path:$path, class:"unreachable", reason:$reason, since:$since}' >> "${tmp}/roots.jsonl"
        jq -nc --arg root "${path}" --arg reason "${detail}" --arg since "${since}" \
          '{kind:"root_unreachable", root:$root, path:null, reason:("root_unreachable(" + $reason + ", since " + $since + ")")}' >> "${tmp}/unmeasured.jsonl"
        jq -nc --arg root "${path}" '{scope:($root + "|*"), reason:"root_unreachable"}' >> "${tmp}/unmeasured-scopes.jsonl"
        ;;
    esac
  done < <(jq -j '.[] | .name + "\u0000" + .path + "\u0000"' <<< "${roots_json}")

  # ---- npm lockfiles, in one pass over every root -------------------------------
  if [[ -s "${tmp}/npm-list.tsv" ]]; then
    local saved_cache="${SAFEDEPS_CACHE_DIR}" saved_ttl="${SAFEDEPS_PROVIDER_CACHE_TTL_SECONDS}"
    SAFEDEPS_CACHE_DIR="${dir}/cache"
    # The shorter of the watch's TTL and the provider's, so a run told to ask
    # live (a TTL below zero) asks live here too.
    if [[ "${saved_ttl}" =~ ^-?[0-9]+$ && "${saved_ttl}" -lt "${SAFEDEPS_WATCH_CACHE_TTL_SECONDS}" ]]; then
      SAFEDEPS_PROVIDER_CACHE_TTL_SECONDS="${saved_ttl}"
    else
      SAFEDEPS_PROVIDER_CACHE_TTL_SECONDS="${SAFEDEPS_WATCH_CACHE_TTL_SECONDS}"
    fi
    mkdir -p "${tmp}/npm"
    safedeps_watch_measure_npm "${tmp}/npm-list.tsv" "${tmp}/findings.jsonl" "${tmp}/status.jsonl" "${tmp}/errors.jsonl" "${tmp}/npm" "${now}"
    SAFEDEPS_CACHE_DIR="${saved_cache}"
    SAFEDEPS_PROVIDER_CACHE_TTL_SECONDS="${saved_ttl}"
  fi

  # Lockfile statuses become measured scopes or unmeasured rows.
  jq -r 'select(.status == "measured") | .root + "|" + .path' "${tmp}/status.jsonl" >> "${tmp}/scopes.txt"
  jq -c 'select(.status != "measured")
         | {kind: (if .status == "unmeasured" then .unmeasured_kind
                   elif .kind == "native" then "native_audit_unavailable"
                   elif .status == "unreadable" then "lockfile_unreadable"
                   else "provider_unavailable" end),
            root, path, reason: (.reason // .status)}' "${tmp}/status.jsonl" >> "${tmp}/unmeasured.jsonl"
  jq -c 'select(.status != "measured") | {scope: (.root + "|" + .path), reason: (if .status == "unmeasured" then .unmeasured_kind elif .kind == "native" then "native_audit_unavailable" else .status end)}' \
    "${tmp}/status.jsonl" >> "${tmp}/unmeasured-scopes.jsonl"

  # ---- runtimes --------------------------------------------------------------------
  local runtime='null'
  if [[ "${kind}" == "full" ]]; then
    safedeps_watch_host_jdks >> "${tmp}/jdks.jsonl" 3>> "${tmp}/unmeasured.jsonl"
  fi
  if [[ -s "${tmp}/jdks.jsonl" ]]; then
    mkdir -p "${tmp}/feeds"
    safedeps_watch_runtime_feeds "${tmp}/jdks.jsonl" "${tmp}/feeds"
    if safedeps_watch_runtime_judge "${tmp}/jdks.jsonl" "${tmp}/feeds/feeds.json" "${now}" > "${tmp}/jdk-states.jsonl"; then
      runtime=$(jq -s -c --arg moved "$(safedeps_watch_runtime_feeds_moved)" --slurpfile feeds "${tmp}/feeds/feeds.json" \
        '{jdks: ., feeds: {openjdk: ($feeds[0].openjdk | del(.advisories) + {advisories: ($feeds[0].openjdk.advisories | length)}),
                           adoptium: ($feeds[0].adoptium | map_values({ok, release_name, timestamp, error}))},
          feeds_moved: (if $moved == "" then null else $moved end)}' "${tmp}/jdk-states.jsonl")
      jq -c 'select(.state == "update_available" or .state == "pre_announced")
             | {key: (.root + "|" + .scope + "|runtime|" + .location + "|" + .runtime_version),
                root, scope, lockfile: null, ecosystem: "runtime", package: ("java:" + .vendor), version: .runtime_version,
                location, advisory: (.advisory.date // .latest_release // null), advisory_url: (.advisory_url // .source // null),
                advisory_date: (.advisory_date // .date // null), fixed: (if .state == "update_available" then [.latest] else [] end),
                latest: .latest, kev: null, state, closed_reason: null, reason: (.reason // null)}' \
        "${tmp}/jdk-states.jsonl" >> "${tmp}/findings.jsonl"
      jq -c 'select(.state == "feed_unavailable" or .state == "vendor_feed_missing")
             | {kind: (if .state == "feed_unavailable" then "runtime_feed_unavailable" else "jdk_vendor_feed_missing" end),
                root, path: .location, reason: (.reason // ("no feed for " + (.vendor // "this vendor")))}' \
        "${tmp}/jdk-states.jsonl" >> "${tmp}/unmeasured.jsonl"
      # A host scope is measured when every host JDK was judged; a pin's when it was.
      jq -r -s '[.[] | select(.root == "@host")] as $h
                | (if ($h | length) > 0 and all($h[]; .state != "feed_unavailable") then "@host|jdk" else empty end),
                  (.[] | select(.root != "@host" and .state != "feed_unavailable") | .root + "|" + .scope)' "${tmp}/jdk-states.jsonl" >> "${tmp}/scopes.txt"
      jq -c 'select(.state == "feed_unavailable") | {scope: (.root + "|" + .scope), reason: "runtime_feed_unavailable"}' \
        "${tmp}/jdk-states.jsonl" >> "${tmp}/unmeasured-scopes.jsonl"
    else
      jq -nc '{kind:"judgment_failed", stage:"runtime"}' >> "${tmp}/errors.jsonl"
    fi
  elif [[ "${kind}" == "full" ]]; then
    printf '@host|jdk\n' >> "${tmp}/scopes.txt"
    runtime=$(jq -nc --arg moved "$(safedeps_watch_runtime_feeds_moved)" '{jdks: [], feeds: null, feeds_moved: (if $moved == "" then null else $moved end)}')
  fi

  # This host is the only host a scan measures.
  if [[ "${kind}" == "full" ]]; then
    jq -nc --arg host "$(hostname -s 2>/dev/null || hostname)" \
      '{kind:"other_hosts", root:null, path:null, reason:("this scan measures " + $host + " only")}' >> "${tmp}/unmeasured.jsonl"
  fi

  # ---- merge and publish -----------------------------------------------------------
  local followups retired finished doc
  followups=$(safedeps_watch_config_get followups 2>/dev/null) || followups=null
  [[ "${followups}" != "null" ]] || followups='{}'
  retired=$(safedeps_watch_retired) || retired='[]'
  finished=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  doc="${tmp}/next.json"
  if ! jq -n -c \
      --arg now "${now}" --arg kind "${kind}" --arg only "${only}" --arg run_id "${run_id}" \
      --arg started "${started}" --arg finished "${finished}" \
      --argjson population "${population}" --argjson ledger "${ledger}" --argjson runtime "${runtime}" \
      --argjson runtime_info "${runtime_info}" --argjson excluded "${excluded_count}" \
      --argjson followups "${followups}" --argjson retired "${retired}" \
      --arg floor "$(date -u -v-"${SAFEDEPS_WATCH_EVENT_RETENTION_DAYS}"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "-${SAFEDEPS_WATCH_EVENT_RETENTION_DAYS} days" +%Y-%m-%dT%H:%M:%SZ)" \
      --slurpfile roots "${tmp}/roots.jsonl" --slurpfile status "${tmp}/status.jsonl" --slurpfile findings "${tmp}/findings.jsonl" \
      --slurpfile errors "${tmp}/errors.jsonl" --slurpfile unmeasured "${tmp}/unmeasured.jsonl" \
      --slurpfile uscopes "${tmp}/unmeasured-scopes.jsonl" --slurpfile uprefixes "${tmp}/unmeasured-prefixes.jsonl" \
      --slurpfile skipped "${tmp}/skipped.jsonl" \
      --rawfile scopes "${tmp}/scopes.txt" \
      '{now: $now, scope: {kind: $kind, root: (if $kind == "root" then $only else null end)},
        scan: {run_id: $run_id, kind: $kind, root: (if $kind == "root" then $only else null end),
               started_at: $started, finished_at: $finished, runtime: $runtime_info},
        population: $population, ledger: $ledger, runtime: $runtime, excluded_count: $excluded,
        roots: ($roots | map(. as $r
          | . + {lockfiles: [$status[] | select(.root == $r.path) | del(.root)]}
          | if .class == "ok" then . + {skipped: [$skipped[] | select(.root == $r.path) | del(.root)]}
                                   | . + {whole: ((.partial | not) and ([.skipped[] | select(.class == "remote_mount")] | length) == 0)}
            else . end)),
        findings: $findings, errors: $errors,
        unmeasured: ($unmeasured | map(. + {followup: ($followups[.kind] // null)})),
        unmeasured_scopes: $uscopes, unmeasured_prefixes: $uprefixes,
        measured_scopes: ($scopes | split("\n") | map(select(length > 0)) | unique),
        retired: $retired, followups: $followups,
        retention_floor: $floor, streak_floor: ($floor | .[0:10])}' > "${tmp}/measurement.json" \
    || ! safedeps_watch_jq -c --slurpfile prior "${tmp}/prior.json" '
        include "state";
        merge_scan($prior[0]; .) as $next
        | $next + {generation: (($prior[0].generation // 0) + 1)}
        | . + {summary: summary}' "${tmp}/measurement.json" > "${doc}"; then
    safedeps_watch_receipt "${run_id}" "$(jq -nc --arg id "${run_id}" --arg kind "${kind}" --arg at "${started}" --arg fin "${finished}" \
      '{run_id:$id, kind:$kind, started_at:$at, finished_at:$fin, exit:3, published:false, error:"merge_failed"}')" || true
    jq -nc '{command:"watch scan", exit:3, error:"merge_failed"}'
    rm -rf "${tmp}"
    return 3
  fi

  if ! safedeps_watch_publish "${doc}"; then
    safedeps_watch_receipt "${run_id}" "$(jq -nc --arg id "${run_id}" --arg kind "${kind}" --arg at "${started}" --arg fin "${finished}" \
      '{run_id:$id, kind:$kind, started_at:$at, finished_at:$fin, exit:3, published:false, error:"publish_failed"}')" || true
    jq -nc '{command:"watch scan", exit:3, error:"publish_failed"}'
    rm -rf "${tmp}"
    return 3
  fi

  # agent_runtime_stale is the summary's (lib/watch/state.jq): true, false, or
  # null when the runtime's checkout could not be read and nobody can tell.
  local error_count report
  error_count=$(jq '.errors | length' "${doc}")
  [[ "${error_count}" -eq 0 ]] || rc=1
  report=$(jq -c --arg run_id "${run_id}" --argjson exit "${rc}" --arg file "$(safedeps_watch_state_file)" '
    {command: "watch scan", run_id: $run_id, exit: $exit, kind: .last_scan.kind, root: .last_scan.root,
     generation, scan_generation, state_file: $file,
     population: (.population | if . == null then null else {state, count, excluded, generated_at, reason} end),
     summary, diff: {new: (.diff.new | length), closed: (.diff.closed | length), changed: (.diff.changed | length)},
     new_events: (.last_scan.started_at as $at | [.events[] | select(.created_at == $at)] | length),
     runtime: .last_scan.runtime, agent_runtime_stale: .summary.agent_runtime_stale, errors, ledger}' "${doc}")
  safedeps_watch_receipt "${run_id}" "$(jq -c --arg at "${started}" --arg fin "${finished}" \
    '{run_id, kind, started_at: $at, finished_at: $fin, exit, generation, published: true,
      summary: .summary.line, errors: (.errors | length), runtime}' <<< "${report}")" || true
  printf '%s\n' "${report}"
  rm -rf "${tmp}"
  return "${rc}"
}
