#!/usr/bin/env bash
# safedeps: PostToolUse hook
# Verifies dependency file changes after install commands and performs reorg (rollback) if suspicious

set -euo pipefail

GUARD_DIR="${SAFEDEPS_HOME:-${HOME}/.safedeps}"
SNAPSHOT_DIR="${GUARD_DIR}/snapshots"
STATE_LOCK_DIR="${GUARD_DIR}/state.lock"

SAFEDEPS_LOCK_FILES=(
  "package-lock.json"
  "pnpm-lock.yaml"
  "yarn.lock"
  "bun.lock"
  "bun.lockb"
  "poetry.lock"
  "uv.lock"
  "Pipfile.lock"
  "requirements.txt"
  "Cargo.lock"
  "go.sum"
  "Gemfile.lock"
  "packages.lock.json"
)

SAFEDEPS_MANIFEST_FILES=(
  "package.json"
  "pyproject.toml"
  "Pipfile"
  "Cargo.toml"
  "go.mod"
  "Gemfile"
  "pom.xml"
)

umask 077
mkdir -p "${GUARD_DIR}" "${SNAPSHOT_DIR}"

# Observable record when the effect gate cannot run (AGENTS.md: no silent fallback).
# The install already happened by PostToolUse, so we cannot block it; what we can
# guarantee is that an un-runnable gate is recorded as UNVERIFIED, never a silent pass.
log_advisory() {
  printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "${GUARD_DIR}/advisory.log" 2>/dev/null || true
}

if ! command -v jq >/dev/null 2>&1; then
  log_advisory "post-verify UNVERIFIED: jq missing — could not verify the install closure. Install jq to restore the effect gate."
  echo "safedeps: jq is not installed — the post-install effect gate could not run; this install is UNVERIFIED (logged to advisory.log)." >&2
  exit 0
fi

SAFEDEPS_REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/ledger/ledger.sh
source "${SAFEDEPS_REPO_DIR}/lib/ledger/ledger.sh"
# shellcheck source=../lib/providers/providers.sh
source "${SAFEDEPS_REPO_DIR}/lib/providers/providers.sh"
# shellcheck source=../lib/npm/closure.sh
source "${SAFEDEPS_REPO_DIR}/lib/npm/closure.sh"
# shellcheck source=../lib/gates/rollback-journal.sh
source "${SAFEDEPS_REPO_DIR}/lib/gates/rollback-journal.sh"
# shellcheck source=../lib/npm/workspaces.sh
source "${SAFEDEPS_REPO_DIR}/lib/npm/workspaces.sh"
# shellcheck source=../lib/npm/ask.sh
source "${SAFEDEPS_REPO_DIR}/lib/npm/ask.sh"

acquire_state_lock() {
  local attempts=0

  while ! mkdir "${STATE_LOCK_DIR}" 2>/dev/null; do
    # Detect stale locks left by SIGKILL/OOM (V-005)
    if [[ -d "${STATE_LOCK_DIR}" ]]; then
      local lock_mtime=""
      # GNU (`-c %Y`, Linux) first, then BSD/macOS (`-f %m`): on Linux `stat -f`
      # means --file-system and would not yield an mtime.
      if lock_mtime=$(stat -c %Y "${STATE_LOCK_DIR}" 2>/dev/null) || \
         lock_mtime=$(stat -f %m "${STATE_LOCK_DIR}" 2>/dev/null); then
        local now
        now=$(date +%s)
        if [[ $(( now - lock_mtime )) -gt 60 ]]; then
          echo "safedeps: removing stale lock ($(( now - lock_mtime ))s old)." >&2
          rmdir "${STATE_LOCK_DIR}" 2>/dev/null || true
          continue
        fi
      fi
    fi

    attempts=$((attempts + 1))
    if [[ ${attempts} -ge ${SAFEDEPS_LOCK_MAX_ATTEMPTS:-100} ]]; then
      # Install already ran; another safedeps run holds the lock. Record UNVERIFIED
      # rather than silently passing — the other run, or a re-check, owns verification.
      log_advisory "post-verify UNVERIFIED: state lock unavailable (another safedeps run active) — install not verified by this run."
      echo "safedeps: could not acquire state lock; this install is UNVERIFIED by this run (logged to advisory.log)." >&2
      exit 0
    fi
    sleep 0.1
  done
}

release_state_lock() {
  rmdir "${STATE_LOCK_DIR}" 2>/dev/null || true
}

write_state_file() {
  local target_path="$1"
  local value="$2"
  local target_dir
  local target_base
  local temp_path

  target_dir=$(dirname "${target_path}")
  target_base=$(basename "${target_path}")
  mkdir -p "${target_dir}" || return 1
  temp_path=$(mktemp "${target_dir}/.${target_base}.XXXXXX") || return 1
  printf '%s\n' "${value}" > "${temp_path}"
  mv -f "${temp_path}" "${target_path}"
}

compute_dir_hash() {
  local input_dir="$1"

  if command -v md5sum >/dev/null 2>&1; then
    printf '%s' "${input_dir}" | md5sum | cut -d' ' -f1
  elif command -v md5 >/dev/null 2>&1; then
    md5 -q -s "${input_dir}"
  else
    printf '%s' "${input_dir}" | cksum | cut -d' ' -f1
  fi
}

# Per-install pending-state key (issue #5) — must match the PreToolUse derivation:
# dir hash + a hash of the command with the inert-install rewrite normalized out.
compute_pending_key() {
  local dir_hash="$1" command="$2" norm cmd_hash
  norm=$(printf '%s' "${command}" | sed -E 's/[[:space:]]+--ignore-scripts([[:space:]]|$)/ /g; s/[[:space:]]+/ /g; s/^ //; s/ $//')
  if command -v md5sum >/dev/null 2>&1; then
    cmd_hash=$(printf '%s' "${norm}" | md5sum | cut -d' ' -f1)
  elif command -v md5 >/dev/null 2>&1; then
    cmd_hash=$(md5 -q -s "${norm}")
  else
    cmd_hash=$(printf '%s' "${norm}" | cksum | cut -d' ' -f1)
  fi
  printf '%s_%s' "${dir_hash}" "${cmd_hash}"
}

hash_file() {
  local file_path="$1"

  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${file_path}" | cut -d' ' -f1
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${file_path}" | cut -d' ' -f1
  else
    echo ""
  fi
}

files_differ() {
  local left_path="$1"
  local right_path="$2"
  local left_hash
  local right_hash

  if [[ ! -f "${left_path}" ]] && [[ ! -f "${right_path}" ]]; then
    return 1
  fi

  if [[ ! -f "${left_path}" ]] || [[ ! -f "${right_path}" ]]; then
    return 0
  fi

  if command -v cmp >/dev/null 2>&1; then
    ! cmp -s "${left_path}" "${right_path}"
    return
  fi

  left_hash=$(hash_file "${left_path}")
  right_hash=$(hash_file "${right_path}")

  if [[ -n "${left_hash}" ]] && [[ -n "${right_hash}" ]]; then
    [[ "${left_hash}" != "${right_hash}" ]]
    return
  fi

  ! diff -q "${left_path}" "${right_path}" >/dev/null 2>&1
}

monitored_files() {
  local monitored_list="${SNAPSHOT_DIR}/${SNAPSHOT_ID}_monitored_files.list"
  local file_name

  if [[ -f "${monitored_list}" ]]; then
    sort -u "${monitored_list}"
    return
  fi

  for file_name in "${SAFEDEPS_LOCK_FILES[@]}" "${SAFEDEPS_MANIFEST_FILES[@]}"; do
    printf '%s\n' "${file_name}"
  done
}

restore_monitored_file() {
  local file_name="$1"
  local rollback_snapshot_id="$2"
  local snapshot_name
  snapshot_name=$(safedeps_snapshot_file_name "${file_name}")
  local snapshot_file="${SNAPSHOT_DIR}/${rollback_snapshot_id}_${snapshot_name}"
  local missing_marker="${SNAPSHOT_DIR}/${rollback_snapshot_id}_${snapshot_name}.missing"
  local current_missing_marker="${SNAPSHOT_DIR}/${SNAPSHOT_ID}_${snapshot_name}.missing"
  local current_file="${PROJECT_DIR}/${file_name}"

  if [[ -f "${snapshot_file}" ]]; then
    if files_differ "${snapshot_file}" "${current_file}"; then
      cp "${snapshot_file}" "${current_file}"
      ROLLED_BACK+=("${file_name}")
    fi
    return
  fi

  if { [[ -f "${missing_marker}" ]] || [[ -f "${current_missing_marker}" ]]; } && [[ -f "${current_file}" ]]; then
    rm -f "${current_file}"
    ROLLED_BACK+=("${file_name}")
  fi
}

read_confirmed_snapshot() {
  local confirmed_snapshot=""
  local dir_hash="${1:-}"

  acquire_state_lock
  # Project-scoped confirmed file
  if [[ -n "${dir_hash}" ]] && [[ -f "${GUARD_DIR}/confirmed_${dir_hash}" ]]; then
    confirmed_snapshot=$(cat "${GUARD_DIR}/confirmed_${dir_hash}" 2>/dev/null || true)
  elif [[ -f "${GUARD_DIR}/confirmed" ]]; then
    # Legacy fallback
    confirmed_snapshot=$(cat "${GUARD_DIR}/confirmed" 2>/dev/null || true)
  fi
  release_state_lock; STATE_LOCK_HELD=false

  printf '%s' "${confirmed_snapshot}"
}

confirm_snapshot() {
  local snapshot_id="$1"
  local dir_hash="${2:-}"

  acquire_state_lock; STATE_LOCK_HELD=true
  if [[ -n "${dir_hash}" ]]; then
    write_state_file "${GUARD_DIR}/confirmed_${dir_hash}" "${snapshot_id}"
  else
    write_state_file "${GUARD_DIR}/confirmed" "${snapshot_id}"
  fi
  release_state_lock; STATE_LOCK_HELD=false
}

# The state this install left behind, recorded as a snapshot of its own so it
# can be confirmed. The pre-install snapshot is the state before the verified
# install, and confirming that one put the baseline one install behind:
# measured, an approved `npm install a` followed by an unapproved
# `npm install b` rolled back to a project without `a` in package.json, the
# lockfile or node_modules (safedeps/confirmed-snapshot-lags-one-install).
#
# The record is copied before the checks read the project, and sealed after
# they finish only if the project still holds the same bytes. Copying after the
# checks recorded whatever was there by then: measured, an unapproved install
# that finished between the closure check and the copy went into the baseline,
# a later rollback could not remove it, and the rollback's `npm ci` ran its
# install scripts (scripts/test/lockless-forms.sh, section 7). Equal bytes at
# both ends is what is compared; a change undone to the same bytes in between is
# not seen, and the bytes recorded are still the ones at both ends.
#
# The id must not start with `${SNAPSHOT_ID}_`, because cleanup_old_snapshots
# removes a snapshot with `rm ${id}_*` and would take this one with it.
VERIFIED_ID=""
VERIFIED_STAGED=false

verified_state_file_names() {
  {
    monitored_files
    find "${PROJECT_DIR}" -maxdepth 1 -type f -name "*.csproj" -exec basename {} \; 2>/dev/null
  } | sed '/^$/d' | sort -u
}

# Where the verified state keeps <file>: under the name every snapshot reader
# uses (safedeps_snapshot_file_name), so a workspace member's
# `packages/a/package.json` goes in the members tree that restore_monitored_file
# reads. Copied to `<id>_packages/a/package.json` it failed for want of the
# directory, and every verified install in a workspace left the baseline where
# it was (measured, scripts/test/lockless-forms.sh section 6, once the
# workspace snapshot and this record met in one tree).
verified_state_path() {
  printf '%s/%s_%s' "${SNAPSHOT_DIR}" "${VERIFIED_ID}" "$(safedeps_snapshot_file_name "$1")"
}

# Copies the files, without meta.json. Every reader requires meta.json, so
# until it is written this is not a snapshot anything can roll back to.
stage_verified_state() {
  local file_name dest
  local list_file="${SNAPSHOT_DIR}/${VERIFIED_ID}_monitored_files.list"

  verified_state_file_names > "${list_file}" || return 1
  while IFS= read -r file_name; do
    dest=$(verified_state_path "${file_name}")
    [[ "${file_name}" != */* ]] || mkdir -p "${dest%/*}" || return 1
    if [[ -f "${PROJECT_DIR}/${file_name}" ]]; then
      cp "${PROJECT_DIR}/${file_name}" "${dest}" || return 1
    else
      touch "${dest}.missing" || return 1
    fi
  done < "${list_file}"
}

# True when the project holds exactly the files that were staged.
staged_state_matches_project() {
  local file_name
  local list_file="${SNAPSHOT_DIR}/${VERIFIED_ID}_monitored_files.list"

  [[ "$(cat "${list_file}")" == "$(verified_state_file_names)" ]] || return 1
  while IFS= read -r file_name; do
    if [[ -f "$(verified_state_path "${file_name}")" ]]; then
      files_differ "$(verified_state_path "${file_name}")" "${PROJECT_DIR}/${file_name}" && return 1
    elif [[ -e "${PROJECT_DIR}/${file_name}" ]]; then
      return 1
    fi
  done < "${list_file}"
}

# meta.json last, through a rename, so the snapshot appears whole or not at all.
seal_verified_state() {
  local parent_id="$1"
  local temp_meta

  temp_meta=$(mktemp "${SNAPSHOT_DIR}/.${VERIFIED_ID}_meta.XXXXXX") || return 1
  if ! jq -n --arg id "${VERIFIED_ID}" --arg parent "${parent_id}" --arg from "${SNAPSHOT_ID}" \
      --arg dir "${PROJECT_DIR}" --argjson ts "$(date +%s)" \
      '{snapshot_id: $id, parent_snapshot_id: (if $parent == "" then null else $parent end),
        verified_from: $from, timestamp: $ts, project_dir: $dir}' > "${temp_meta}"; then
    rm -f "${temp_meta}"
    return 1
  fi
  mv -f "${temp_meta}" "${SNAPSHOT_DIR}/${VERIFIED_ID}_meta.json"
}

discard_staged_state() {
  rm -rf "${SNAPSHOT_DIR}/${VERIFIED_ID}_${SAFEDEPS_SNAPSHOT_MEMBERS:-members}" 2>/dev/null || true
  rm -f "${SNAPSHOT_DIR}/${VERIFIED_ID}"_* 2>/dev/null || true
}

# Confirm what this install verified. If the post-install state cannot be
# recorded, the baseline stays where it was and the user is told: an older
# baseline rolls back too much, a partial or unread one would restore files
# nobody verified.
confirm_verified_state() {
  local parent_id
  local why=""

  parent_id=$(read_confirmed_snapshot "${DIR_HASH}")
  if [[ -n "${parent_id}" ]] && [[ ! -f "${SNAPSHOT_DIR}/${parent_id}_meta.json" ]]; then
    parent_id=""
  fi

  if [[ "${VERIFIED_STAGED}" != "true" ]]; then
    why="its files could not be copied"
  elif ! staged_state_matches_project; then
    why="the dependency files changed while they were being verified, so what they hold now was not read by this check"
  elif ! seal_verified_state "${parent_id}"; then
    why="its record could not be written"
  fi

  if [[ -n "${why}" ]]; then
    discard_staged_state
    log_advisory "post-verify: the verified state of ${PROJECT_DIR} could not be recorded (${why}), so the rollback baseline was not moved (still ${parent_id:-none})."
    ROLLBACK_WARNINGS+=("safedeps verified this install but could not record the result as the new rollback baseline (${why}), so a later rollback in ${PROJECT_DIR} returns to the baseline before it (${parent_id:-none}) and would undo this install too")
    return 0
  fi

  confirm_snapshot "${VERIFIED_ID}" "${DIR_HASH}"
}

collect_protected_snapshot_ids() {
  local dir_hash="${1:-}"
  local snapshot_id
  local parent_snapshot_id
  local meta_file
  local seen=()

  snapshot_id=$(read_confirmed_snapshot "${dir_hash}")

  while [[ -n "${snapshot_id}" ]]; do
    local already_seen="false"
    local seen_id

    for seen_id in "${seen[@]+${seen[@]}}"; do
      if [[ "${seen_id}" == "${snapshot_id}" ]]; then
        already_seen="true"
        break
      fi
    done

    if [[ "${already_seen}" == "true" ]]; then
      break
    fi

    seen+=("${snapshot_id}")
    printf '%s\n' "${snapshot_id}"

    meta_file="${SNAPSHOT_DIR}/${snapshot_id}_meta.json"
    if [[ ! -f "${meta_file}" ]]; then
      break
    fi

    parent_snapshot_id=$(jq -r '.parent_snapshot_id // empty' "${meta_file}" 2>/dev/null || true)
    snapshot_id="${parent_snapshot_id}"
  done
}

snapshot_is_protected() {
  local target_snapshot_id="$1"
  shift

  local protected_snapshot_id
  for protected_snapshot_id in "$@"; do
    if [[ "${protected_snapshot_id}" == "${target_snapshot_id}" ]]; then
      return 0
    fi
  done

  return 1
}

# Lists snapshots by meta.json only. Files without one are left alone: a run in
# progress holds exactly that while its checks run, nothing on disk tells it
# from a killed run's leftovers, and pruning it would let its meta.json land
# over missing files. A killed run costs disk, never a baseline.
cleanup_old_snapshots() {
  local protected_snapshot_ids=()
  local protected_snapshot_id
  local old_meta
  local old_id
  local removable_seen=0

  while IFS= read -r protected_snapshot_id; do
    if [[ -n "${protected_snapshot_id}" ]]; then
      protected_snapshot_ids+=("${protected_snapshot_id}")
    fi
  done < <(collect_protected_snapshot_ids "${DIR_HASH:-}")

  while IFS= read -r old_meta; do
    old_id=$(jq -r '.snapshot_id // empty' "${old_meta}" 2>/dev/null || true)

    if [[ -z "${old_id}" ]]; then
      continue
    fi

    if [[ ${#protected_snapshot_ids[@]} -gt 0 ]] && snapshot_is_protected "${old_id}" "${protected_snapshot_ids[@]}"; then
      continue
    fi

    removable_seen=$((removable_seen + 1))
    if [[ ${removable_seen} -le 10 ]]; then
      continue
    fi

    # The workspace members' manifests are a directory, which `rm -f` leaves.
    [[ "${old_id}" != */* ]] && rm -rf "${SNAPSHOT_DIR}/${old_id}_${SAFEDEPS_SNAPSHOT_MEMBERS}"
    rm -f "${SNAPSHOT_DIR}/${old_id}"_*
  done < <(ls -t "${SNAPSHOT_DIR}"/*_meta.json 2>/dev/null || true)
}

# Every npm command safedeps runs itself stays in the project it read. `npm
# rebuild` and the rollback's reinstall both read the project's own .npmrc, and
# with `global=true` there both went to npm's global tree instead: the rebuild
# ran the scripts of a globally installed package nobody had verified, and the
# reinstall installed the project into the global prefix and left its own
# node_modules empty (measured, scripts/test/lockless-forms.sh). `--global=false`
# alone did not hold against `location=global`, and `--location=project` alone
# did not hold against `global=true`; the pair held against both.
#
# Each of them also carries `--prefix "${PROJECT_DIR}"`, so npm works in the
# directory the gate read and nowhere else. Without it npm walks up from there
# the way an install does: measured, after `npm install x --no-workspaces` in a
# workspace member, the gate read the member's lockfiles while `npm rebuild` in
# the member would have run over the workspace root's tree.
NPM_PROJECT_SCOPE=(--global=false --location=project)

# The rollback's reinstall of node_modules. The reinstall itself never runs an
# install script; a rebuild after it may.
#
# With a package-lock.json, `npm ci --ignore-scripts` installs exactly the tree
# the restored lockfile records. That tree is one the gate confirmed only when
# the rollback restored a confirmed snapshot (ROLLBACK_TARGET_CONFIRMED). With
# none, the rollback restores the state from before the command, which nothing
# verified and which can hold the very package the gate rejected. Measured: a
# fresh clone whose committed lockfile held an unapproved package was rolled
# back to that lockfile, and a plain `npm ci` ran the package's install
# scripts. So the scripts run only toward a confirmed snapshot, and then only
# through the rebuild an install gets (npm_rebuild_vouched), which asks about
# the whole tree rather than about what this command changed.
#
# Without a lockfile, npm resolves package.json's ranges again, and what it
# resolves has not been read by anyone: measured, a range `^1.0.0` came back as
# a 1.0.1 published after the approval, and the reinstall ran its install
# scripts. So that reinstall is not rebuilt, and the user is told to review and
# rebuild. The same holds for the `npm install` retry after a failed `npm ci`,
# which also resolves again.
restore_node_modules() {
  if ! command -v npm >/dev/null 2>&1; then
    ROLLBACK_WARNINGS+=("npm is not installed; node_modules was not reinstalled")
    return
  fi

  local why="there is no package-lock.json to install from"
  if [[ -f "${PROJECT_DIR}/package-lock.json" ]]; then
    if (cd "${PROJECT_DIR}" && npm ci --ignore-scripts "${NPM_PROJECT_SCOPE[@]}" --prefix "${PROJECT_DIR}" >/dev/null 2>&1); then
      [[ "${ROLLBACK_TARGET_CONFIRMED}" != true ]] || npm_rebuild_vouched "after the rollback"
      return
    fi
    ROLLBACK_WARNINGS+=("npm ci failed during rollback; retrying with npm install")
    why="npm ci failed"
  fi

  if (cd "${PROJECT_DIR}" && rm -rf node_modules \
      && npm install --ignore-scripts "${NPM_PROJECT_SCOPE[@]}" --prefix "${PROJECT_DIR}" >/dev/null 2>&1); then
    log_advisory "post-verify: node_modules in ${PROJECT_DIR} was reinstalled with --ignore-scripts — ${why}, so npm resolved package.json again and nothing verified what it resolved."
    ROLLBACK_WARNINGS+=("node_modules was reinstalled but its install scripts were not run: ${why}, so npm resolved package.json again and safedeps did not verify what it resolved. Review node_modules, then run \`npm rebuild\` yourself if it is what you expect")
    return
  fi

  ROLLBACK_WARNINGS+=("node_modules reinstall failed; review the project manually")
}

# Reads, for each nested package key on stdin, what every package above it
# under node_modules bundles, from that package's own package.json on disk.
# Prints one JSON object, key -> names, the way npm reads the field
# (@npmcli/package-json normalize): bundleDependencies, or
# bundledDependencies when the first is absent; `true` is every name in
# dependencies; an object is its keys; anything else is nothing. A package.json
# that is missing bundles nothing, and one jq cannot read makes the whole
# answer `{}`: nothing is bundled, and the rebuild is skipped with the nested
# packages named.
npm_bundled_names() {
  local dir="$1" key rest
  local -a files=()
  while IFS= read -r key; do
    rest="${key}"
    while [[ "${rest}" == */node_modules/* ]]; do
      rest="${rest%/node_modules/*}"
      [[ "${rest}" == *node_modules/* ]] || break
      [[ -f "${dir}/${rest}/package.json" ]] && files+=("${dir}/${rest}/package.json")
    done
  done
  if [[ ${#files[@]} -eq 0 ]]; then
    printf '{}\n'
    return 0
  fi
  jq -cn --arg dir "${dir}/" '
      reduce inputs as $pkg ({};
        .[input_filename | ltrimstr($dir) | rtrimstr("/package.json")] =
          ((if ($pkg | has("bundleDependencies")) then $pkg.bundleDependencies else $pkg.bundledDependencies end) as $bd
           | if $bd == true then ($pkg.dependencies | if type == "object" then keys else [] end)
             elif ($bd | type) == "array" then [$bd[] | strings]
             elif ($bd | type) == "object" then ($bd | keys)
             else [] end))
    ' "${files[@]}" < /dev/null 2>/dev/null || printf '{}\n'
}

# Which registry the tree's bytes came from, as npm answers it: a JSON array of
# two fetch facts (lib/npm/ask.sh). The first is the pre-guard's, asked with the
# install's own arguments and environment before the command ran (the pending
# state's npm_fetch). The second is asked here, of the directory the gate read,
# after the command: an .npmrc the command itself wrote is not there for the
# first ask, and the rollback's reinstall runs with this hook's environment, not
# the command's. A source is vouched for only when both answers say the bytes
# came from the public registry (sd_fetch_problems); a missing answer is a
# reason of its own, never a default. A configuration that held only while the
# command ran, written and removed inside it, is in neither: ARCHITECTURE.md
# lists it among the boundaries.
#
# Asked once per run, in this shell, so the callers that read it from a
# command substitution see it: the rebuild's predicate and the source check.
NPM_FETCH_FACTS=""
npm_fetch_facts_load() {
  local pre post
  [[ -z "${NPM_FETCH_FACTS}" ]] || return 0
  pre=$(jq -ce '.npm_fetch | select(type == "object")' <<< "${CURRENT_STATE:-}" 2>/dev/null) \
    || pre='{"unknown":"the pre-guard left no answer about which registry this install fetches from"}'
  # Asked in PROJECT_DIR, which is the local prefix npm named for the install,
  # so its project .npmrc is the one the install read. `--workspaces=false`
  # keeps npm there: without it npm counts a workspace member as an implicit
  # `--workspace` and refuses `config` (ENOWORKSPACES), which happens when the
  # install itself said `--no-workspaces` and stayed in the member. Not
  # `--prefix`: on the command line that also moves the global config file.
  post=$(safedeps_npm_fetch_facts "${PROJECT_DIR}" $(( SECONDS + SAFEDEPS_NPM_ASK_POST_SECONDS )) npm -- \
    --workspaces=false)
  NPM_FETCH_FACTS=$(jq -cn --argjson pre "${pre}" --argjson post "${post}" '[$pre, $post]' 2>/dev/null) \
    || NPM_FETCH_FACTS='[{"unknown":"safedeps could not read npm'"'"'s answers about which registry this install fetches from"}]'
}

# `npm rebuild` runs the lifecycle scripts of every package in the tree it
# rebuilds, and so did the rollback's `npm ci`. Both run over the whole tree.
# What allowed them used to be a judgment of the change: nothing this command
# brought in was rejected. Every hole in that judgment then became a script
# that ran. Three in a row did: a reader that missed the hidden lockfile, one
# that dropped links, and a rollback whose baseline nobody had verified
# (safedeps/effect-gate-blind-to-lockless-npm-installs, judgment C). So the
# permission is a predicate on the whole tree the scripts run over, and the
# change is not asked. Three things decide it, all measured:
#
#   - Every package the rebuild runs over has to be on record, at the version
#     and under the name that is on disk. The closure above is read from
#     package-lock.json and the hidden lockfile, so a package neither lockfile
#     lists, or a version written over a recorded one, is something the gate
#     never looked at.
#   - Every package under node_modules has to come from the public registry:
#     each record of it names an https URL there
#     (SAFEDEPS_NPM_PUBLIC_REGISTRY_RE) that npm fetches from there, or it is
#     bundled by the package it is nested under (below). A committed lockfile
#     names its sources and nothing verified them: an approved name and
#     version pointed at another tarball installed as recorded, and the
#     rebuild ran that tarball's scripts. A record with no source, as
#     `omit-lockfile-registry-resolved` writes, does not pass. Nor does a
#     public URL alone: npm's default `replace-registry-host=npmjs` fetches a
#     registry.npmjs.org URL from whatever registry it is configured with and
#     records the URL unchanged, so an .npmrc or `npm_config_registry` sent
#     the approved name and version to another tarball under a record that
#     read as public (RH1-RH3). Where npm fetched from is npm's answer, asked
#     before the command with the install's own words and again after it
#     (npm_fetch_facts_load); a record is vouched for only when both say the
#     bytes came from the public registry, and not when either is missing.
#   - Every directory outside node_modules (a link's target) has to be a
#     member the project's package.json declares as a workspace. Any other
#     directory is code nobody approved: a `file:` dependency, or one an
#     earlier unrecorded install linked.
#
# A bundled package has no source of its own: it came inside its parent's
# tarball. Which packages are bundled is read from the tree, never from a
# lockfile's `inBundle`. A committed lockfile sets that field as it likes, and
# npm writes it into the hidden lockfile for whatever the root project's own
# bundleDependencies names. Either way an approved name and version from an
# http tarball passed as bundled and the rebuild ran its scripts (measured,
# npm 10.8.2). So a package nested under another, at
# <parent>/node_modules/<name>, is bundled when three things hold: the parent
# is under node_modules and passes this check itself, the parent's own
# package.json on disk names <name> in bundleDependencies (or
# bundledDependencies, or `true` with <name> in its dependencies, as npm
# reads them), and no record of the nested package names a source other than
# the public registry. The root project and its workspace members bundle
# nothing here: what they bundle is installed like any other dependency. A
# package nested inside a bundled one that its own parent does not name is not
# bundled here, though npm counts it; its rebuild is skipped with a warning.
#
# When any of them fails, the whole rebuild is skipped and the user is told
# which package and why. Nothing is rolled back: the install itself passed,
# and a skipped rebuild is the answer an install already gets for a package
# off the record.
#
# Which packages the rebuild runs over is npm's to say. safedeps used to walk
# the tree in bash, and twice it walked less than npm rebuilds: it took a key on
# record for the package under it (`global=0` in an .npmrc put 1.0.1 over a
# recorded 1.0.0), and it did not follow a `file:` link into its target, where
# `npm rebuild` ran a package no lockfile records. So npm is asked: `npm query
# '*'` loads the tree the way `npm rebuild` does, links followed into their
# targets, and names every package by location, name and version. Each is
# compared with what the two lockfiles record under its location. A link is not
# a node of its own there; its target is. The rebuild also has to stay in the
# project (NPM_PROJECT_SCOPE above).
#
# Prints what fails, one per line as `<kind><TAB><what>`: `unrecorded`,
# `source`, `fetched` (recorded on the public registry, but npm fetches it from
# somewhere else, or could not say) or `directory`. Returns 0. Returns 1 with the reason when npm could
# not be asked or did not answer: then the tree is not known, and the caller
# must not rebuild it. It starts one npm and one jq, plus two more jq when a
# nested package has no public source of its own (to read what its parents
# bundle, and to judge again with that), and one subshell and the workspace
# reader when the tree holds a directory outside node_modules.
npm_rebuild_unrecorded() {
  local dir="$1" tmp lockfile rc
  local -a lockfiles=()
  if [[ -z "${NPM_FETCH_FACTS}" ]]; then
    printf 'safedeps did not ask npm which registry this tree came from\n'
    return 1
  fi
  if ! command -v npm >/dev/null 2>&1; then
    printf 'npm is not on the PATH this hook runs with\n'
    return 1
  fi
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-post-query.XXXXXX") || {
    printf 'safedeps could not make a scratch directory to ask npm\n'
    return 1
  }
  safedeps_npm_ask_start "${tmp}/query" "${dir}" npm -- query '*' "${NPM_PROJECT_SCOPE[@]}" --prefix "${dir}"
  if ! safedeps_npm_ask_wait $(( SECONDS + SAFEDEPS_NPM_ASK_POST_SECONDS )); then
    printf 'npm query did not answer within %ss\n' "${SAFEDEPS_NPM_ASK_POST_SECONDS}"
    rm -rf "${tmp}"
    return 1
  fi
  rc="${SAFEDEPS_NPM_ASK_RCS[0]}"
  if [[ "${rc}" != 0 ]]; then
    printf 'npm query failed (exit %s: %s)\n' "${rc}" "$(safedeps_npm_ask_error "${tmp}/query")"
    rm -rf "${tmp}"
    return 1
  fi

  for lockfile in "${dir}/package-lock.json" "${dir}/${NPM_HIDDEN_LOCKFILE}"; do
    [[ -f "${lockfile}" ]] && lockfiles+=("${lockfile}")
  done
  # The name a key records: its own `name`, or the last segment under
  # node_modules. A key outside node_modules (a workspace member, a link
  # target) is named by its package, which the lockfile may leave out; then
  # there is no recorded name to compare.
  #
  # A directory is printed as `candidate<TAB><key><TAB><what>`, and the loop
  # below keeps the ones that are not workspace members: which directories are
  # members is read from package.json, outside jq.
  # The judgment, run once with no bundle declarations read ($bundles null):
  # a nested package with no public source is then printed as
  # `nested<TAB><key>` instead of judged. When there are any, the package.json
  # of each package above them is read and the judgment runs again with what
  # they bundle (npm_bundled_names).
  # shellcheck disable=SC2016 # a jq program: jq expands its $names
  local judge='
      def clean: tostring | sub("^[=v[:space:]]+"; "");
      def recorded_name($key; $entry):
        $entry.name // (if ($key | test("(^|/)node_modules/")) then $key | split("node_modules/") | last else null end);
      def public_url: (.resolved | type) == "string" and (.resolved | test($public; "i"));
      def fetch_problems: if public_url then sd_fetch_problems($facts; .resolved) else [] end;
      def public_source: public_url and (fetch_problems | length) == 0;
      ([inputs | (.packages // {}) | to_entries[] | select(.key != "")]
        | group_by(.key) | map({key: .[0].key, value: map(.value)}) | from_entries) as $records
      | if ($query | length) != 1 or ($query[0] | type) != "array" then error("npm query did not answer with a list") else . end
      | ([$query[0][] | select(type == "object" and (.location // "") != "") | {key: .location, value: .}] | from_entries) as $nodes
      | ($bundles[0]) as $bundled
      # What fails at <key>, as one line, or null when it passes.
      | def verdict($key):
          $nodes[$key] as $node
          | ($records[$key] // []) as $recs
          | "\($node.name // "?")@\($node.version // "?")" as $here
          | if $node == null then
              "unrecorded\t\($key) (npm did not name it)"
            elif ($recs | length) == 0 then
              "unrecorded\t\($key) (\($here), not in either lockfile)"
            elif any($recs[]; .link == true) then
              "unrecorded\t\($key) (\($here) on disk, the lockfile records a link)"
            elif any($recs[]; ((.version // "") | clean) == (($node.version // "") | clean)
                              and (recorded_name($key; .) as $n | $n == null or $n == $node.name)) | not then
              "unrecorded\t\($key) (\($here) on disk, the lockfile records \([$recs[] | "\(recorded_name($key; .) // "?")@\(.version // "?")"] | unique | join(" or ")))"
            elif ($key | test("(^|/)node_modules/") | not) then
              "candidate\t\($key)\t\($key) (\($here))"
            elif all($recs[]; public_source) then null
            else
              ([$key | capture("^(?<parent>.*node_modules/.+)/node_modules/(?<name>(@[^/]+/)?[^/]+)$")] | first) as $at
              | if $at != null and $bundled == null then
                  "nested\t\($key)"
                elif $at != null
                     and all($recs[]; .resolved == null or public_source)
                     and any(($bundled[$at.parent] // [])[]; . == $at.name)
                     and verdict($at.parent) == null then null
                elif all($recs[]; public_url) then
                  "fetched\t\($key) (\($here) recorded at \([$recs[] | .resolved] | unique | join(" or ")), but \([$recs[] | fetch_problems[]] | unique | join("; ")))"
                else
                  "source\t\($key) (\($here) from \([$recs[] | .resolved // "no recorded source" | tostring] | unique | join(" or ")))"
                end
            end;
        $query[0][] | select(type == "object" and (.location // "") != "") | verdict(.location) | select(. != null)
    '
  printf 'null\n' > "${tmp}/bundles"
  judge="${SAFEDEPS_NPM_FETCH_JQ}${judge}"
  if ! jq -rn --slurpfile query "${tmp}/query" --slurpfile bundles "${tmp}/bundles" \
      --arg public "${SAFEDEPS_NPM_PUBLIC_REGISTRY_RE}" --argjson facts "${NPM_FETCH_FACTS}" "${judge}" \
      "${lockfiles[@]+"${lockfiles[@]}"}" < /dev/null > "${tmp}/found" 2>/dev/null; then
    printf 'npm query answered with something safedeps could not compare with the lockfiles\n'
    rm -rf "${tmp}"
    return 1
  fi
  if grep -q '^nested' "${tmp}/found"; then
    grep '^nested' "${tmp}/found" | cut -f2 | npm_bundled_names "${dir}" > "${tmp}/bundles"
    if ! jq -rn --slurpfile query "${tmp}/query" --slurpfile bundles "${tmp}/bundles" \
        --arg public "${SAFEDEPS_NPM_PUBLIC_REGISTRY_RE}" --argjson facts "${NPM_FETCH_FACTS}" "${judge}" \
        "${lockfiles[@]+"${lockfiles[@]}"}" < /dev/null > "${tmp}/found" 2>/dev/null; then
      printf 'npm query answered with something safedeps could not compare with the lockfiles\n'
      rm -rf "${tmp}"
      return 1
    fi
  fi

  if grep -q '^candidate' "${tmp}/found"; then
    # One subshell for all of them, however many members a workspace has, and
    # `cd -P` inside it to compare physical directories, as the member list is
    # (npm_workspace_member_dirs).
    PROJECT_DIR="${dir}" npm_workspace_member_dirs > "${tmp}/members" 2>/dev/null || : > "${tmp}/members"
    (
      local members kind key what
      members=$'\n'"$(cat "${tmp}/members")"$'\n'
      while IFS=$'\t' read -r kind key what; do
        if [[ "${kind}" != candidate ]]; then
          printf '%s\t%s\n' "${kind}" "${key}"
          continue
        fi
        if cd -P "${dir}/${key}" 2>/dev/null; then
          case "${members}" in
            *$'\n'"${PWD}"$'\n'*) continue ;;
          esac
        fi
        printf 'directory\t%s\n' "${what}"
      done < "${tmp}/found"
    )
  else
    cat "${tmp}/found"
  fi
  rm -rf "${tmp}"
}

# What npm_rebuild_unrecorded found, as one clause per kind for a warning.
describe_rebuild_blockers() {
  local kind clauses="" list
  for kind in unrecorded source fetched directory; do
    list=$(grep "^${kind}"$'\t' <<< "$1" | cut -f2- | paste -sd';' - | sed 's/;/; /g') || true
    [[ -n "${list}" ]] || continue
    case "${kind}" in
      unrecorded) list="a package, or a version of one, that neither lockfile records (${list})" ;;
      source) list="a package not recorded as coming from the public registry (${list})" ;;
      fetched) list="a package recorded on the public registry that safedeps cannot tell npm fetched from there (${list})" ;;
      directory) list="a directory that is not a declared workspace member (${list})" ;;
    esac
    clauses+="${clauses:+, and }${list}"
  done
  printf '%s' "${clauses}"
}

# Runs `npm rebuild` in PROJECT_DIR when npm_rebuild_unrecorded finds nothing in
# the tree, and tells the user why not otherwise. <when> names the rebuild in
# what is recorded: after an install, or after a rollback.
npm_rebuild_vouched() {
  local when="$1" blockers clauses
  npm_fetch_facts_load
  if ! blockers=$(npm_rebuild_unrecorded "${PROJECT_DIR}"); then
    log_advisory "post-verify: npm rebuild ${when} skipped in ${PROJECT_DIR} — safedeps asked npm which packages a rebuild would run over and got no answer (${blockers}), so it cannot tell that tree is one it can vouch for."
    ROLLBACK_WARNINGS+=("npm rebuild was not run: safedeps asked npm which packages it would rebuild and got no answer (${blockers}), so it could not tell they are the ones it read. Install scripts have not run; review node_modules, then run \`npm rebuild\` yourself if it is what you expect")
    return 0
  fi
  if [[ -n "${blockers}" ]]; then
    clauses=$(describe_rebuild_blockers "${blockers}")
    log_advisory "post-verify: npm rebuild ${when} skipped in ${PROJECT_DIR} — the tree npm would rebuild holds ${clauses}."
    ROLLBACK_WARNINGS+=("npm rebuild was not run: the tree npm would rebuild in ${PROJECT_DIR} holds ${clauses}. safedeps runs install scripts only over a tree whose every package is on record and comes from the public registry or a declared workspace member. Install scripts have not run; review it, then run \`npm rebuild\` yourself if it is what you expect")
    return 0
  fi

  if (cd "${PROJECT_DIR}" && npm rebuild "${NPM_PROJECT_SCOPE[@]}" --prefix "${PROJECT_DIR}" >/dev/null 2>&1); then
    return 0
  fi
  ROLLBACK_WARNINGS+=("npm rebuild failed ${when}; lifecycle scripts may need manual review")
}

run_verified_npm_rebuild_if_injected() {
  local injected

  injected=$(jq -r '.ignore_scripts_injected == true' "${META_FILE}" 2>/dev/null || printf 'false')
  [[ "${injected}" == "true" ]] || return 0

  # The install left no trace here, so this tree is not the one it built, and
  # its scripts are not this install's to run (settle_npm_trace).
  [[ "${NPM_TRACE_ABSENT}" != true ]] || return 0

  # Nothing was installed into the project, so there is nothing to rebuild.
  [[ -d "${PROJECT_DIR}/node_modules" ]] || return 0

  if [[ ! -f "${PROJECT_DIR}/${NPM_HIDDEN_LOCKFILE}" ]]; then
    log_advisory "post-verify: npm rebuild skipped in ${PROJECT_DIR} — node_modules has no .package-lock.json, so the tree it would rebuild is not the tree the effect gate read."
    ROLLBACK_WARNINGS+=("npm rebuild was not run: ${PROJECT_DIR}/node_modules has no .package-lock.json, so safedeps could not read the tree it would rebuild. Install scripts have not run; review node_modules, then run \`npm rebuild\` yourself if it is what you expect")
    return 0
  fi

  # The lockfiles are on record, but the tree can hold more than they record,
  # and what they record can come from anywhere. Measured: `global=0` in the
  # project .npmrc, and `location=global` there with `--location=project` on
  # the command, put the package in node_modules and wrote it to neither
  # lockfile, or wrote a new version over a recorded one and left the record
  # saying the old one. A `file:` dependency's own node_modules is rebuilt with
  # the project's, though no lockfile of the project records it. And a
  # committed lockfile's sources were never checked. The gate confirmed the
  # records clean each time, and `npm rebuild` then ran the scripts.
  npm_rebuild_vouched "after the install"
}

emit_confirm_warnings_if_any() {
  local warning_str injected

  # On Claude Code the install ran inert, so an install that landed elsewhere
  # has had no scripts run and nobody will rebuild it: the user is told. On
  # Codex its scripts ran during the install, and the record is all there is.
  if [[ -n "${TRACE_NOTE}" ]]; then
    injected=$(jq -r '.ignore_scripts_injected == true' "${META_FILE}" 2>/dev/null || printf 'false')
    if [[ "${injected}" == "true" ]]; then
      warning_str=""
      [[ ${#ROLLBACK_WARNINGS[@]} -eq 0 ]] || warning_str=$(printf '%s; ' "${ROLLBACK_WARNINGS[@]}")
      emit_system_message "safedeps: ${TRACE_NOTE}${warning_str:+

Additional warnings:
${warning_str%%; }}"
      return 0
    fi
  fi

  [[ ${#ROLLBACK_WARNINGS[@]} -gt 0 ]] || return 0

  warning_str=$(printf '%s; ' "${ROLLBACK_WARNINGS[@]}")
  cat >> "${GUARD_DIR}/reorg.log" << LOG_EOF
[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] CONFIRM warnings
  Snapshot: ${SNAPSHOT_ID}
  Project: ${PROJECT_DIR}
  Warnings: ${warning_str%%; }
LOG_EOF

  emit_system_message "safedeps: verified install completed, with warning(s):
${warning_str%%; }"
}

# The loose install recognizer from lib/install-grammar.sh: this backstop runs
# on commands PreToolUse did not recognize, so its false positives cost one
# closure diff and it is kept wide on purpose. If the grammar cannot be read,
# every command counts as install-looking and the failure is recorded -- this
# hook cannot block, so the direction to fail is toward checking more.
SAFEDEPS_INSTALL_GRAMMAR_LIB="${BASH_SOURCE[0]%/*}/../lib/install-grammar.sh"
if [[ -r "${SAFEDEPS_INSTALL_GRAMMAR_LIB}" ]]; then
  # shellcheck source=../lib/install-grammar.sh
  source "${SAFEDEPS_INSTALL_GRAMMAR_LIB}"
fi

post_command_looks_like_install() {
  local command="$1"

  if [[ -z "${SAFEDEPS_G_RAW_INSTALL_RE:-}" ]]; then
    log_advisory "post-verify: lib/install-grammar.sh is unreadable — treating the command as install-looking so the backstop still runs."
    return 0
  fi
  printf '%s' "${command}" | grep -qiE "${SAFEDEPS_G_RAW_INSTALL_RE}|(^|[^a-zA-Z0-9_-])npx[[:space:]]+(@?[A-Za-z0-9._-])"
}

legacy_pending_matches_post_context() {
  local pending_project_dir="${1:-}"
  local pending_dir_hash="${2:-}"

  [[ -n "${pending_project_dir}" ]] || return 1
  if command -v realpath >/dev/null 2>&1; then
    pending_project_dir=$(realpath "${pending_project_dir}" 2>/dev/null || echo "${pending_project_dir}")
  elif command -v readlink >/dev/null 2>&1; then
    pending_project_dir=$(readlink -f "${pending_project_dir}" 2>/dev/null || echo "${pending_project_dir}")
  fi

  [[ "${pending_project_dir}" == "${POST_CWD}" ]] || return 1
  if [[ -n "${pending_dir_hash}" && "${pending_dir_hash}" != "${POST_DIR_HASH}" ]]; then
    return 1
  fi
  post_command_looks_like_install "${COMMAND}"
}

# An unfinished rollback from an earlier run is the loudest thing this hook can
# have to say, so it is collected before anything else and before any of the
# early exits below. PostToolUse fires on every Bash call, so the report reaches
# the user on the very next command rather than on the next install.
#
# It is emitted through a single channel: engines parse this hook's stdout as
# one JSON object, so a second object would be a lost message, not an extra one.
UNFINISHED_REPORT=$(safedeps_journal_report_unfinished "${GUARD_DIR}/reorg.log" 2>/dev/null || true)

emit_system_message() {
  local body="$1"

  if [[ -n "${UNFINISHED_REPORT}" ]]; then
    body="${UNFINISHED_REPORT}
${body}"
    UNFINISHED_REPORT=""
  fi
  jq -nc --arg message "${body}" '{systemMessage: $message}'
}

# If this run has nothing else to say, the report still has to get out.
emit_unfinished_report_if_unsent() {
  [[ -n "${UNFINISHED_REPORT}" ]] || return 0
  jq -nc --arg message "${UNFINISHED_REPORT}" '{systemMessage: $message}'
  UNFINISHED_REPORT=""
}
trap 'emit_unfinished_report_if_unsent' EXIT

# Read tool input from stdin
INPUT=$(cat)

# Only process Bash tool results
TOOL_NAME=$(echo "${INPUT}" | jq -r '.tool_name // empty' 2>/dev/null)
if [[ "${TOOL_NAME}" != "Bash" ]]; then
  exit 0
fi

# The command + cwd identify which pending install this PostToolUse belongs to
# (issue #5), so concurrent installs do not consume each other's state.
COMMAND=$(echo "${INPUT}" | jq -r '.tool_input.command // empty' 2>/dev/null)
POST_CWD=$(echo "${INPUT}" | jq -r '.cwd // empty' 2>/dev/null)
[[ -z "${POST_CWD}" ]] && POST_CWD=$(pwd)
if command -v realpath >/dev/null 2>&1; then
  POST_CWD=$(realpath "${POST_CWD}" 2>/dev/null || echo "${POST_CWD}")
elif command -v readlink >/dev/null 2>&1; then
  POST_CWD=$(readlink -f "${POST_CWD}" 2>/dev/null || echo "${POST_CWD}")
fi
POST_DIR_HASH=$(compute_dir_hash "${POST_CWD}")

STATE_LOCK_HELD=true
acquire_state_lock
# Keeps the unfinished-rollback report on the exit path it was registered on
# above; replacing that trap rather than extending it would drop the report on
# every run that reaches this far.
trap '[ "${STATE_LOCK_HELD:-}" = "true" ] && release_state_lock; STATE_LOCK_HELD=false; emit_unfinished_report_if_unsent' EXIT

# Resolve THIS install's pending state by its per-install key (issue #5). The
# filename also carries a snapshot id, so identical concurrent commands produce
# several files; consume exactly one (they verify the same closure), leaving the
# rest for their own post hooks. Fall back to the legacy global files for in-flight
# upgrades from a pre-#5 PreToolUse.
PENDING_PREFIX="${GUARD_DIR}/pending/$(compute_pending_key "${POST_DIR_HASH}" "${COMMAND}")__"
PENDING_FILE=""
for pending_candidate in "${PENDING_PREFIX}"*.json; do
  [[ -f "${pending_candidate}" ]] && { PENDING_FILE="${pending_candidate}"; break; }
done
if [[ -n "${PENDING_FILE}" ]]; then
  CURRENT_STATE=$(cat "${PENDING_FILE}")
  SNAPSHOT_ID=$(echo "${CURRENT_STATE}" | jq -r '.snapshot_id // empty')
  PROJECT_DIR=$(echo "${CURRENT_STATE}" | jq -r '.project_dir // empty')
  DIR_HASH=$(echo "${CURRENT_STATE}" | jq -r '.dir_hash // empty')
  rm -f "${PENDING_FILE}"
elif [[ -f "${GUARD_DIR}/current_state" ]]; then
  CURRENT_STATE=$(cat "${GUARD_DIR}/current_state")
  SNAPSHOT_ID=$(echo "${CURRENT_STATE}" | jq -r '.snapshot_id // empty')
  PROJECT_DIR=$(echo "${CURRENT_STATE}" | jq -r '.project_dir // empty')
  DIR_HASH=$(echo "${CURRENT_STATE}" | jq -r '.dir_hash // empty')
  if ! legacy_pending_matches_post_context "${PROJECT_DIR}" "${DIR_HASH}"; then
    log_advisory "post-verify SKIP: legacy current_state did not match this Bash command/cwd (post_cwd=${POST_CWD}, pending_project=${PROJECT_DIR:-unknown}) — bounded no-op."
    exit 0
  fi
  rm -f "${GUARD_DIR}/current_state"
elif [[ -f "${GUARD_DIR}/current_snapshot_id" ]]; then
  SNAPSHOT_ID=$(cat "${GUARD_DIR}/current_snapshot_id")
  PROJECT_DIR=$(cat "${GUARD_DIR}/current_project_dir" 2>/dev/null || pwd)
  DIR_HASH=$(compute_dir_hash "${PROJECT_DIR}")
  if ! legacy_pending_matches_post_context "${PROJECT_DIR}" "${DIR_HASH}"; then
    log_advisory "post-verify SKIP: legacy current_snapshot_id did not match this Bash command/cwd (post_cwd=${POST_CWD}, pending_project=${PROJECT_DIR:-unknown}) — bounded no-op."
    exit 0
  fi
  rm -f "${GUARD_DIR}/current_snapshot_id" "${GUARD_DIR}/current_project_dir"
else
  # No pending state for this command (PreToolUse never recognized it — a parser
  # blind spot, a payload with no `cwd`, or a genuinely novel install form). If it
  # nonetheless looks like an install, the documented effect gate must NOT inherit
  # the parser's blind spot: run a command-independent closure backstop instead of
  # only logging UNVERIFIED (finding #5). The backstop machinery lives past the
  # function definitions below, so flag it here and fall through.
  if post_command_looks_like_install "${COMMAND}"; then
    BACKSTOP_INSTALL=true
    SNAPSHOT_ID=""
    PROJECT_DIR="${POST_CWD}"
    DIR_HASH="${POST_DIR_HASH}"
  else
    exit 0
  fi
fi

if [[ "${BACKSTOP_INSTALL:-false}" != "true" && -z "${SNAPSHOT_ID}" ]]; then
  exit 0
fi
if [[ -z "${PROJECT_DIR}" ]]; then
  PROJECT_DIR=$(pwd)
fi
if [[ -z "${DIR_HASH:-}" ]]; then
  DIR_HASH=$(compute_dir_hash "${PROJECT_DIR}")
fi
release_state_lock; STATE_LOCK_HELD=false

# Verify snapshot exists (skipped in command-independent backstop mode, which has
# no pre-install snapshot — it diffs the live closure against the confirmed baseline).
META_FILE="${SNAPSHOT_DIR}/${SNAPSHOT_ID}_meta.json"
if [[ "${BACKSTOP_INSTALL:-false}" != "true" && ! -f "${META_FILE}" ]]; then
  exit 0
fi

# --- Begin Reorg Verification ---

SUSPICIOUS=false
REASONS=()
ROLLBACK_WARNINGS=()
# Whether a rollback restores a confirmed snapshot, which is the only target
# whose install scripts it may run (restore_node_modules). Each rollback says
# so; until one does, it does not.
ROLLBACK_TARGET_CONFIRMED=false

# Whether this command's npm install was read: the directory the gate reads has
# to show this command's install trace. The pre-guard picked the directory and,
# just before the command ran, touched a baseline file and noted the inode of
# both npm lockfiles there. A lockfile `find -newer` than the baseline, or one
# with another inode, is a trace.
#
# The pre-guard's choice is a prediction from the command text, and three
# rounds of validation found text it read wrong: a `cd` that never ran, a `cd`
# spelled `command cd`, a symlinked workspace member. Each time the gate read a
# directory the install never touched, confirmed it clean, and passed the
# install unread. So the directory is a place to look, and this decides what the
# looking found (safedeps/effect-gate-blind-to-lockless-npm-installs).
#
# No trace means the install landed somewhere else or installed nothing, and
# this cannot tell which: a `--dry-run` and an install that failed leave none
# either. It is recorded UNGATED in those words, and nothing is rebuilt here.
# Nothing below runs npm.
#
# The trace is the directory's, not the command's. A second npm in the same
# directory during the command, or the command touching a lockfile itself,
# leaves one too; ARCHITECTURE.md states that boundary.
NPM_TRACE_ABSENT=false
TRACE_NOTE=""
npm_install_trace() {
  local baseline="$1" rel file recorded inode newer
  [[ -f "${baseline}" ]] || { printf 'its baseline file %s is gone' "${baseline}"; return 1; }
  for rel in package-lock.json node_modules/.package-lock.json; do
    file="${PROJECT_DIR}/${rel}"
    [[ -e "${file}" ]] || continue
    recorded=$(jq -r --arg rel "${rel}" '.npm_trace.inodes[$rel] // ""' <<< "${CURRENT_STATE}" 2>/dev/null) || recorded="?"
    inode=""
    read -r inode _ < <(ls -di -- "${file}" 2>/dev/null) || true
    if [[ -n "${inode}" && "${inode}" != "${recorded}" ]]; then
      printf '%s' "${rel}"
      return 0
    fi
    if newer=$(find -H "${file}" -newer "${baseline}" -print 2>/dev/null) && [[ -n "${newer}" ]]; then
      printf '%s' "${rel}"
      return 0
    fi
  done
  return 1
}

settle_npm_trace() {
  local baseline unattributable why
  baseline=$(jq -r '.npm_trace.baseline // empty' <<< "${CURRENT_STATE:-}" 2>/dev/null) || baseline=""
  unattributable=$(jq -r '.npm_unattributable // empty' <<< "${CURRENT_STATE:-}" 2>/dev/null) || unattributable=""
  [[ -n "${baseline}" ]] || return 0

  if why=$(npm_install_trace "${baseline}"); then
    if [[ -n "${unattributable}" ]]; then
      log_advisory "post-verify UNGATED: the install trace in ${PROJECT_DIR} cannot answer for every npm install in this command: ${unattributable}, so one of them may have landed elsewhere unread. Command: ${COMMAND}"
    fi
  else
    NPM_TRACE_ABSENT=true
    log_advisory "post-verify UNGATED: no install trace in ${PROJECT_DIR}: the install landed elsewhere or installed nothing. Neither npm lockfile there changed during this command${why:+ (${why})}, so the effect gate verified nothing this install wrote, and npm rebuild was not run. Command: ${COMMAND}"
    TRACE_NOTE="no install trace in ${PROJECT_DIR}: the install landed elsewhere or installed nothing. safedeps verified nothing this install wrote and did not run npm rebuild; if it installed packages somewhere else, their install scripts have not run there. Recorded as UNGATED in ${GUARD_DIR}/advisory.log"
  fi
  rm -f "${baseline}"
}

redact_install_script_content() {
  local script_content="$1"
  local flattened
  local byte_count
  local digest
  local suffix=""

  flattened=$(printf '%s' "${script_content}" | tr '\r\n\t' '   ' | cut -c 1-160)
  byte_count=$(printf '%s' "${script_content}" | wc -c | tr -d ' ')
  if command -v shasum >/dev/null 2>&1; then
    digest=$(printf '%s' "${script_content}" | shasum -a 256 | cut -d' ' -f1)
  elif command -v sha256sum >/dev/null 2>&1; then
    digest=$(printf '%s' "${script_content}" | sha256sum | cut -d' ' -f1)
  else
    digest="unavailable"
  fi
  if [[ "${byte_count}" -gt 160 ]]; then
    suffix="..."
  fi
  printf '[redacted install script sha256=%s bytes=%s preview=%s%s]' \
    "${digest}" \
    "${byte_count}" \
    "${flattened}" \
    "${suffix}"
}

# The package.json files, among <files>, that declare a preinstall, install or
# postinstall script. One jq reads them all; most packages declare none, and a
# jq per package cost seconds on an install of a few hundred. A file jq cannot
# parse stops that one run, so then every file is handed on and the per-package
# reading below decides, as it did before.
packages_with_install_scripts() {
  local listed
  [[ $# -gt 0 ]] || return 0
  if listed=$(printf '%s\0' "$@" | xargs -0 jq -r '
      select(type == "object")
      | select(((.scripts? // {}) | if type == "object" then [.preinstall, .install, .postinstall] else [] end
          | map(select(. != null and . != false and . != "")) | length) > 0)
      | input_filename' 2>/dev/null); then
    [[ -z "${listed}" ]] || printf '%s\n' "${listed}"
  else
    printf '%s\n' "$@"
  fi
}

# Function: check for suspicious postinstall scripts in new/changed dependencies
#
# Two lists of packages are read. The first is the old one: when a lockfile or
# package.json changed, the package.json files in node_modules that were not
# there before. The second is what npm's records say this install brought in
# (collect_npm_new_records), whether or not any of those files changed. An
# install that saves nothing changes neither, so before the second list the
# heuristics never ran on it, and the inert install's rebuild then ran the
# scripts they exist to catch.
check_postinstall_scripts() {
  local pkg_json="${PROJECT_DIR}/package.json"
  local changed_lock=false
  local lock_file
  local key
  local script_packages=""
  local -a candidates=()

  if [[ -f "${pkg_json}" ]]; then
    for lock_file in "${SAFEDEPS_LOCK_FILES[@]}"; do
      if files_differ "${SNAPSHOT_DIR}/${SNAPSHOT_ID}_${lock_file}" "${PROJECT_DIR}/${lock_file}"; then
        changed_lock=true
        break
      fi
    done

    # Check node_modules for new packages with install scripts
    if [[ -d "${PROJECT_DIR}/node_modules" ]] \
        && { [[ "${changed_lock}" == "true" ]] || files_differ "${SNAPSHOT_DIR}/${SNAPSHOT_ID}_package.json" "${pkg_json}"; }; then
      local old_pkg_listing="${SNAPSHOT_DIR}/${SNAPSHOT_ID}_packages.list"
      if [[ -f "${old_pkg_listing}" ]]; then
        script_packages=$(find "${PROJECT_DIR}/node_modules" -maxdepth 3 -name "package.json" 2>/dev/null | sort | comm -13 "${old_pkg_listing}" - | head -50)
      else
        script_packages=$(find "${PROJECT_DIR}/node_modules" -maxdepth 3 -name "package.json" 2>/dev/null | head -50)
      fi
    fi
  fi

  while IFS= read -r key; do
    [[ -n "${key}" ]] && candidates+=("${key}")
  done <<< "${script_packages}"
  for key in ${NPM_NEW_NODES[@]+"${NPM_NEW_NODES[@]}"}; do
    [[ -f "${PROJECT_DIR}/${key}/package.json" ]] && candidates+=("${PROJECT_DIR}/${key}/package.json")
  done
  [[ ${#candidates[@]} -gt 0 ]] || return 0
  script_packages=$(packages_with_install_scripts "${candidates[@]}" | LC_ALL=C sort -u)

  if [[ -n "${script_packages}" ]]; then
    while IFS= read -r pkg; do
      [[ -z "${pkg}" ]] && continue
      # Check for suspicious install hooks
      local has_preinstall
      local has_postinstall
      local has_install
      local pkg_name

      has_preinstall=$(jq -r '.scripts.preinstall // empty' "${pkg}" 2>/dev/null)
      has_postinstall=$(jq -r '.scripts.postinstall // empty' "${pkg}" 2>/dev/null)
      has_install=$(jq -r '.scripts.install // empty' "${pkg}" 2>/dev/null)
      pkg_name=$(jq -r '.name // "unknown"' "${pkg}" 2>/dev/null)

      for script_content in "${has_preinstall}" "${has_postinstall}" "${has_install}"; do
        if [[ -z "${script_content}" ]]; then
          continue
        fi

        # Check for network calls in install scripts
        if echo "${script_content}" | grep -qEi '(curl|wget|fetch|http|https|net\.|socket|dns)'; then
          SUSPICIOUS=true
          REASONS+=("Package '${pkg_name}' has install script with network access: $(redact_install_script_content "${script_content}")")
        fi

        # Check for eval/exec in install scripts
        if echo "${script_content}" | grep -qEi '(eval|exec|spawn|child_process|Function\()'; then
          SUSPICIOUS=true
          REASONS+=("Package '${pkg_name}' has install script with code execution: $(redact_install_script_content "${script_content}")")
        fi

        # Check for filesystem access outside project
        if echo "${script_content}" | grep -qEi '(\/etc\/|\/home\/|~\/|\$HOME|\.ssh|\.env|\.aws|credentials|~\/\.safedeps|\$HOME\/\.safedeps|\.safedeps\/|SAFEDEPS_HOME)'; then
          SUSPICIOUS=true
          REASONS+=("Package '${pkg_name}' has install script accessing sensitive paths")
        fi

        # Check for encoded/obfuscated content
        if echo "${script_content}" | grep -qEi '(base64|atob|Buffer\.from|\\x[0-9a-f]{2}|\\u[0-9a-f]{4})'; then
          SUSPICIOUS=true
          REASONS+=("Package '${pkg_name}' has install script with obfuscated content")
        fi
      done
    done <<< "${script_packages}"
  fi
}

# Function: check lock file diff for suspicious changes
check_lockfile_diff() {
  local lock_file

  for lock_file in "${SAFEDEPS_LOCK_FILES[@]}"; do
    local current="${PROJECT_DIR}/${lock_file}"
    local snapshot="${SNAPSHOT_DIR}/${SNAPSHOT_ID}_${lock_file}"

    if [[ ! -f "${current}" ]] || [[ ! -f "${snapshot}" ]]; then
      continue
    fi

    # Compare content directly so mtime manipulation cannot bypass verification.
    if ! files_differ "${snapshot}" "${current}"; then
      continue
    fi

    # Lock file changed — analyze the diff. The resolved URLs of both npm
    # records are read by check_npm_new_sources, whether or not this file
    # changed.
    if [[ "${lock_file}" == "package-lock.json" ]]; then
      local new_deps

      # Check for a very large number of new dependencies (potential dependency confusion)
      new_deps=$(diff "${snapshot}" "${current}" 2>/dev/null | grep '^>' | grep -c '"resolved"' || true)
      new_deps="${new_deps:-0}"
      if [[ ${new_deps} -gt 50 ]]; then
        SUSPICIOUS=true
        REASONS+=("Unusually large number of new dependencies added: ${new_deps}")
      fi
    fi
  done
}

# Function: check for suspicious binaries
check_binaries() {
  if [[ -d "${PROJECT_DIR}/node_modules/.bin" ]]; then
    # Check for newly added binaries that are actual compiled binaries (not scripts)
    local new_bins
    local old_bin_listing="${SNAPSHOT_DIR}/${SNAPSHOT_ID}_bins.list"
    if [[ -f "${old_bin_listing}" ]]; then
      new_bins=$(ls "${PROJECT_DIR}/node_modules/.bin/" 2>/dev/null | sort | comm -13 "${old_bin_listing}" - | head -20)
    else
      new_bins=$(ls "${PROJECT_DIR}/node_modules/.bin/" 2>/dev/null | head -20)
    fi

    for bin in ${new_bins}; do
      # Check if it's a binary file (not a script) — use full path (V-010)
      local bin_path="${PROJECT_DIR}/node_modules/.bin/${bin}"
      if [[ -f "${bin_path}" ]] && file "${bin_path}" 2>/dev/null | grep -qiE '(executable|shared object|Mach-O|ELF)'; then
        SUSPICIOUS=true
        REASONS+=("Native binary '${bin}' found in node_modules/.bin")
      fi
    done
  fi
}

# The npm CLI's two records of what a project install put on disk:
# package-lock.json, and the hidden lockfile it writes into node_modules on
# every install. They differ exactly when the install asked npm not to save:
# `--no-save`, `--save=false`, `--no-package-lock`, `--package-lock=false`, the
# same settings from the environment or an .npmrc. Measured with npm 11.19.0
# against a local registry, each of those left package-lock.json byte-identical
# and recorded the package in the hidden lockfile. Reading only
# package-lock.json, this gate confirmed all of them clean, and the inert
# rebuild below then ran the unverified package's install scripts
# (safedeps/effect-gate-blind-to-lockless-npm-installs).
NPM_HIDDEN_LOCKFILE="node_modules/.package-lock.json"

# What this install brought in, as npm recorded it: the sources and the
# installed packages that npm's two records now hold and that neither record
# held before the command. The closure check reads both records, but the
# source and install-script checks used to run only when package-lock.json or
# package.json changed. An install that saves nothing changes neither, so a
# tarball with an approved name and version, fetched from anywhere, passed both
# and the rebuild ran its scripts (validator round 4).
#
# The earlier records are the copies the pre-guard kept of package-lock.json
# and of the tree record, read together (safedeps_npm_new_records). Where
# neither existed, everything recorded now is new. A source the committed
# package-lock.json already named is not new, so `npm ci` installs it as
# recorded; that is a boundary, documented as one.
#
# A new link is a new source, its target directory is a new package for the
# install-script heuristics, and so is any other directory outside node_modules
# whose record changed. The exception is a workspace member, which is part of
# the project (collect_npm_new_directories).
NPM_NEW_SOURCES=()
NPM_NEW_NODES=()
collect_npm_new_records() {
  local record kind value target new directories=""
  local -a earlier=()

  for record in "package-lock.json" "${SAFEDEPS_SNAPSHOT_NPM_TREE}"; do
    [[ -f "${SNAPSHOT_DIR}/${SNAPSHOT_ID}_${record}" ]] && earlier+=("${SNAPSHOT_DIR}/${SNAPSHOT_ID}_${record}")
  done

  for record in "package-lock.json" "${NPM_HIDDEN_LOCKFILE}"; do
    [[ -f "${PROJECT_DIR}/${record}" ]] || continue
    if ! new=$(safedeps_npm_new_records "${PROJECT_DIR}/${record}" ${earlier[@]+"${earlier[@]}"}); then
      SUSPICIOUS=true
      REASONS+=("npm record ${record} could not be compared with the records before the command; fail-closed")
      continue
    fi
    while IFS=$'\t' read -r kind value target; do
      case "${kind}" in
        S) NPM_NEW_SOURCES+=("${record}: ${value}") ;;
        N) NPM_NEW_NODES+=("${value}") ;;
        L) directories+="L"$'\t'"${record}"$'\t'"${value}"$'\t'"${target}"$'\n' ;;
        T) directories+="T"$'\t'"${record}"$'\t'"${value}"$'\t'"${value}"$'\n' ;;
      esac
    done <<< "${new}"
  done

  [[ -z "${directories}" ]] || collect_npm_new_directories "${directories}"
}

# <directories>: the new links and the new directories outside node_modules
# that collect_npm_new_records found, one per line as
# `L|T<TAB><record><TAB><key><TAB><directory npm keyed>`.
#
# A workspace member is the one directory left out. npm links each member the
# root's package.json declares, in the same shape as a `file:` dependency, and
# the rebuild runs the member's scripts as `npm install` would. They are the
# project's own, so a member added to a workspace is not rolled back (W1, W2).
# Any other link is a directory this install brought in, inside the project or
# not. It is a source outside the public registries, so it is rolled back
# (A1-A4), as it was when the lockfile diff was read. Its directory, and any
# other directory whose record changed, goes to the install-script heuristics.
#
# A member is a directory the declared patterns find inside the project, the
# way npm's glob finds it. It is compared with the link's target as a directory
# on disk, so a member reached through a symlink matches the target npm keys by
# where it resolves (W2). A pattern that leaves the project names no member
# (A5). Where the patterns cannot be read in full (a negation, a glob this gate
# does not read), no directory counts as a member, and advisory.log says so: a
# member list longer than npm's would pass a directory npm did not treat as one
# (W3).
#
# A fresh workspace links every member at once, so this runs a fixed number of
# processes, never one per directory.
collect_npm_new_directories() {
  local members="" kept kind record key dir

  if [[ -f "${PROJECT_DIR}/package.json" ]]; then
    members=$(npm_workspace_member_dirs) || members=""
  fi
  if ! kept=$(printf '%s' "$1" | npm_with_physical_dirs | jq -nRr --arg members "${members}" '
      ($members | split("\n") | map(select(. != "") | {key: ., value: true}) | from_entries) as $m
      | inputs | split("\t") | select((.[4] // "") == "" or ($m[.[4]] | not)) | .[0:4] | join("\t")'); then
    SUSPICIOUS=true
    REASONS+=("npm records: the directories this install linked could not be compared with the workspace members; fail-closed")
    return 0
  fi

  while IFS=$'\t' read -r kind record key dir; do
    case "${kind}" in
      L)
        if [[ -z "${dir}" ]]; then
          NPM_NEW_SOURCES+=("${record}: ${key} (a link that records no target)")
        else
          NPM_NEW_SOURCES+=("${record}: ${dir}")
          NPM_NEW_NODES+=("${dir}")
        fi
        ;;
      T) NPM_NEW_NODES+=("${dir}") ;;
    esac
  done <<< "${kept}"
}

# Each line on stdin, with a tab and its fourth field as a directory on disk
# appended: empty when it is not one. The field is a path npm keyed relative to
# the project's real directory, so `..` is resolved after the symlinks in front
# of it (`cd -P`, which also leaves PWD physical). One subshell for every line.
npm_with_physical_dirs() {
  (
    local line kind record key dir physical
    while IFS= read -r line; do
      [[ -n "${line}" ]] || continue
      IFS=$'\t' read -r kind record key dir <<< "${line}"
      physical=""
      if [[ -n "${dir}" ]] && cd -P "${PROJECT_DIR}/${dir}" 2>/dev/null; then
        physical="${PWD}"
      fi
      printf '%s\t%s\n' "${line}" "${physical}"
    done
  )
}

# The workspace members of PROJECT_DIR, one directory on disk per line, or
# nothing when it declares none or its patterns cannot be read in full.
npm_workspace_member_dirs() {
  local listing
  listing=$(safedeps_npm_workspace_members "${PROJECT_DIR}") || return 1
  [[ "${listing%%$'\n'*}" == ok ]] || return 0
  if grep -q '^?' <<< "${listing}"; then
    log_advisory "post-verify: the workspace patterns in ${PROJECT_DIR}/package.json cannot be read in full ($(grep '^?' <<< "${listing}" | head -1 | cut -f2)), so no directory this install linked there counts as a workspace member."
    return 0
  fi
  (
    local member
    while IFS= read -r member; do
      [[ -n "${member}" ]] || continue
      case "/${member#"${PROJECT_DIR}"}/" in
        */../*) continue ;;
      esac
      cd -P "${member}" 2>/dev/null && printf '%s\n' "${PWD}"
    done
    return 0
  ) <<< "${listing#ok}"
}

# Function: check the sources this install brought in, from either npm record
check_npm_new_sources() {
  local nonstandard insecure
  [[ ${#NPM_NEW_SOURCES[@]} -gt 0 ]] || return 0

  # Check for resolved URLs pointing to non-standard registries. Each entry is
  # `<record>: <resolved>`, and the value is read from its start
  # (safedeps_npm_public_registry_url).
  local entry fetched=""
  nonstandard=""
  for entry in "${NPM_NEW_SOURCES[@]}"; do
    if safedeps_npm_public_registry_url "${entry#*: }"; then
      fetched+="${entry}"$'\n'
    else
      nonstandard+="${entry}"$'\n'
    fi
  done
  # A URL on the public registry is the public registry's only where npm
  # fetched it from there (npm_fetch_facts_load). One npm says it fetched from
  # another registry is a source outside the public registries like any other:
  # a new project's first install of an approved name and version through an
  # .npmrc the command wrote is rolled back here. Where npm could not be asked,
  # nothing is rolled back for it: the rebuild check withholds the scripts, and
  # a rollback for an answer that never came would undo ordinary installs.
  if [[ -n "${fetched}" ]]; then
    npm_fetch_facts_load
    if ! fetched=$(jq -nrR --arg public "${SAFEDEPS_NPM_PUBLIC_REGISTRY_RE}" --argjson facts "${NPM_FETCH_FACTS}" \
        "${SAFEDEPS_NPM_FETCH_JQ}"'
        inputs | select(. != "") | . as $entry | ($entry | sub("^[^:]*: "; "")) as $url
        | sd_fetch_known_problems($facts; $url) | select(length > 0)
        | "\($entry), but \(join("; "))"' <<< "${fetched}" 2>/dev/null); then
      fetched="npm records: the sources on the public registry could not be judged against npm's answer about where it fetched them"
    fi
    [[ -z "${fetched}" ]] || nonstandard+="${fetched}"$'\n'
  fi
  nonstandard="${nonstandard%$'\n'}"
  if [[ -n "${nonstandard}" ]]; then
    SUSPICIOUS=true
    REASONS+=("Lock file contains resolved URLs from non-standard registries ($(name_sources "${nonstandard}"))")
  fi

  # Check for git:// or http:// (non-https) resolved URLs
  insecure=$(printf '%s\n' "${NPM_NEW_SOURCES[@]}" | grep -iE '(git://|http://)' || true)
  if [[ -n "${insecure}" ]]; then
    SUSPICIOUS=true
    REASONS+=("Lock file contains insecure (non-HTTPS) resolved URLs ($(name_sources "${insecure}"))")
  fi
}

# The first three of <lines>, `;`-separated, and how many more there were. A
# rollback has to say which source caused it, and a cut list says so too.
name_sources() {
  local count
  count=$(grep -c . <<< "$1")
  printf '%s' "$(head -3 <<< "$1" | paste -sd ';' -)"
  [[ ${count} -le 3 ]] || printf '; and %s more' "$((count - 3))"
}

check_npm_effect_closure() {
  local closure_file
  local provider_file
  local miss_file
  local package_name
  local version
  local miss_count
  local vulnerable_summary
  local kev_summary
  local lockfile
  local part_file
  local -a lockfiles=()

  for lockfile in "${PROJECT_DIR}/package-lock.json" "${PROJECT_DIR}/${NPM_HIDDEN_LOCKFILE}"; do
    [[ -f "${lockfile}" ]] && lockfiles+=("${lockfile}")
  done
  [[ ${#lockfiles[@]} -gt 0 ]] || return 0

  # A tree with no hidden lockfile was not recorded by the npm that built it
  # (npm 6 and older, or a tree built by hand). Its closure is read from
  # package-lock.json alone, and that is on record rather than assumed.
  if [[ -d "${PROJECT_DIR}/node_modules" && ! -f "${PROJECT_DIR}/${NPM_HIDDEN_LOCKFILE}" ]]; then
    log_advisory "post-verify: ${PROJECT_DIR}/node_modules has no .package-lock.json, so the installed tree was read from package-lock.json only."
  fi

  closure_file=$(mktemp "${TMPDIR:-/tmp}/safedeps-post-closure.XXXXXX") || return
  provider_file=$(mktemp "${TMPDIR:-/tmp}/safedeps-post-provider.XXXXXX") || {
    rm -f "${closure_file}"
    return
  }
  miss_file=$(mktemp "${TMPDIR:-/tmp}/safedeps-post-miss.XXXXXX") || {
    rm -f "${closure_file}" "${provider_file}"
    return
  }
  part_file=$(mktemp "${TMPDIR:-/tmp}/safedeps-post-part.XXXXXX") || {
    rm -f "${closure_file}" "${provider_file}" "${miss_file}"
    return
  }
  : > "${miss_file}"

  # One closure over both records, each entry once.
  printf '[]' > "${closure_file}"
  for lockfile in "${lockfiles[@]}"; do
    if ! safedeps_npm_lock_closure "${lockfile}" > "${part_file}" \
        || ! jq -s 'add | unique_by(.ecosystem + "\u0000" + .package + "\u0000" + .version) | sort_by(.package, .version)' \
          "${closure_file}" "${part_file}" > "${part_file}.merged" 2>/dev/null; then
      SUSPICIOUS=true
      REASONS+=("npm closure could not be parsed from ${lockfile#"${PROJECT_DIR}"/}")
      rm -f "${closure_file}" "${provider_file}" "${miss_file}" "${part_file}" "${part_file}.merged"
      return
    fi
    mv -f "${part_file}.merged" "${closure_file}"
  done
  rm -f "${part_file}"

  # One ledger read for the whole closure. The per-package form walked the whole
  # ledger directory for every package, which put the gate past its own hook
  # budget at a closure of four packages on a 738-entry ledger
  # (scripts/measure/effect-gate-cost.sh).
  #
  # The status is read, not discarded. Through a process substitution it was
  # invisible, so a batch that could not run at all delivered no rows and no
  # rows meant no misses — the closure read as fully approved. The per-package
  # form it replaced failed closed in the same conditions.
  local ledger_batch_file
  local ledger_batch_status
  ledger_batch_file=$(mktemp "${TMPDIR:-/tmp}/safedeps-ledger-batch.XXXXXX") || {
    SUSPICIOUS=true
    REASONS+=("npm ledger closure check could not run; fail-closed")
    rm -f "${closure_file}" "${provider_file}" "${miss_file}"
    return
  }
  # `set -e` is on and status 1 (misses found) is the ordinary rejected-install
  # path, so the call has to be a tested condition. Left bare it would abort the
  # hook exactly when it has something to say, and a hook that exits non-zero is
  # a broken hook to the entry shim.
  if safedeps_ledger_effect_check_batch "npm" "${closure_file}" > "${ledger_batch_file}"; then
    ledger_batch_status=0
  else
    ledger_batch_status=$?
  fi
  if [[ "${ledger_batch_status}" -gt 1 ]]; then
    SUSPICIOUS=true
    REASONS+=("npm ledger closure check could not run; fail-closed")
    rm -f "${closure_file}" "${provider_file}" "${miss_file}" "${ledger_batch_file}"
    return
  fi
  while IFS=$'\t' read -r package_name version; do
    [[ -n "${package_name}" && -n "${version}" ]] || continue
    printf '%s@%s\n' "${package_name}" "${version}" >> "${miss_file}"
  done < "${ledger_batch_file}"
  rm -f "${ledger_batch_file}"

  miss_count=$(wc -l < "${miss_file}" | tr -d ' ')
  if [[ "${miss_count}" -gt 0 ]]; then
    SUSPICIOUS=true
    REASONS+=("npm closure contains ${miss_count} unapproved package(s): $(head -20 "${miss_file}" | paste -sd ', ' -)")
  fi

  if ! safedeps_providers_query_batch "npm" "${closure_file}" > "${provider_file}"; then
    SUSPICIOUS=true
    REASONS+=("npm closure OSV batch verification failed; fail-closed")
    rm -f "${closure_file}" "${provider_file}" "${miss_file}"
    return
  fi

  kev_summary=$(jq -r '[.[] | select(.status == "hard_block") | "\(.package)@\(.version)"] | join(", ")' "${provider_file}")
  if [[ -n "${kev_summary}" ]]; then
    SUSPICIOUS=true
    REASONS+=("npm closure contains KEV-blocked package(s): ${kev_summary}")
  fi

  vulnerable_summary=$(jq -r '[.[] | select(.status == "vulnerable") | "\(.package)@\(.version)"] | join(", ")' "${provider_file}")
  if [[ -n "${vulnerable_summary}" ]]; then
    SUSPICIOUS=true
    REASONS+=("npm closure contains vulnerable package(s): ${vulnerable_summary}")
  fi

  rm -f "${closure_file}" "${provider_file}" "${miss_file}"
}

run_command_independent_backstop() {
  # Reached when PreToolUse left no pending state for an install-looking command.
  # Detection is command-independent (the npm closure check reads the live
  # package-lock.json, not the command text); automatic rollback still needs a
  # prior confirmed-safe snapshot to restore from. Never silent — every path logs.
  if [[ ! -f "${PROJECT_DIR}/package-lock.json" && ! -f "${PROJECT_DIR}/${NPM_HIDDEN_LOCKFILE}" ]]; then
    log_advisory "post-verify UNVERIFIED: install-looking command with no pending state and no package-lock.json or ${NPM_HIDDEN_LOCKFILE} in ${PROJECT_DIR} — nothing to closure-check."
    return 0
  fi

  check_npm_effect_closure

  if [[ "${SUSPICIOUS}" != "true" ]]; then
    log_advisory "post-verify BACKSTOP clean: a parser-missed install in ${PROJECT_DIR} passed the command-independent npm closure check."
    return 0
  fi

  local reason_str
  reason_str=$(printf '%s; ' "${REASONS[@]}")

  local rollback_id
  rollback_id=$(read_confirmed_snapshot "${DIR_HASH}")
  if [[ -z "${rollback_id}" ]] || [[ ! -f "${SNAPSHOT_DIR}/${rollback_id}_meta.json" ]]; then
    # Detected, but no known-good baseline to restore — fail LOUD, never silent.
    log_advisory "post-verify BACKSTOP FLAGGED (no baseline): parser-missed install in ${PROJECT_DIR} — ${reason_str%%; }. No confirmed snapshot to roll back to; left in place."
    emit_system_message "safedeps: an install the command gate did not recognize produced a suspicious closure:
${reason_str%%; }

There is no confirmed-safe snapshot for ${PROJECT_DIR} yet, so safedeps could NOT roll it back automatically. Review and revert manually, then run \`safedeps check\` for the intended versions."
    return 0
  fi

  # Roll back to the confirmed baseline using the existing reorg helpers.
  # The journal opens before the first file is touched: everything below is
  # destructive, and a kill anywhere in it used to leave no trace at all.
  local journal_id="backstop-${rollback_id}-$$"
  safedeps_journal_open "${journal_id}" "${PROJECT_DIR}" "${rollback_id}" \
    "${reason_str%%; }" "restoring-files"

  SNAPSHOT_ID="${rollback_id}"   # so monitored_files() reads the baseline's list
  ROLLBACK_TARGET_CONFIRMED=true
  ROLLED_BACK=()
  local monitored_file
  while IFS= read -r monitored_file; do
    [[ -z "${monitored_file}" ]] && continue
    restore_monitored_file "${monitored_file}" "${rollback_id}"
  done < <(monitored_files)

  local rb_pkg="${SNAPSHOT_DIR}/${rollback_id}_package.json"
  if [[ -f "${rb_pkg}" ]] && files_differ "${rb_pkg}" "${PROJECT_DIR}/package.json"; then
    cp "${rb_pkg}" "${PROJECT_DIR}/package.json"
    ROLLED_BACK+=("package.json")
  fi

  safedeps_journal_stage "${journal_id}" "reinstalling-node-modules"
  restore_node_modules

  local rolled_str="" warning_str=""
  [[ ${#ROLLED_BACK[@]} -gt 0 ]] && rolled_str=$(printf '%s, ' "${ROLLED_BACK[@]}")
  [[ ${#ROLLBACK_WARNINGS[@]} -gt 0 ]] && warning_str=$(printf '%s; ' "${ROLLBACK_WARNINGS[@]}")
  cat >> "${GUARD_DIR}/reorg.log" << LOG_EOF
[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] REORG executed (command-independent backstop)
  Rollback snapshot: ${rollback_id}
  Project: ${PROJECT_DIR}
  Reasons: ${reason_str%%; }
  Rolled back: ${rolled_str%, }
  Rollback warnings: ${warning_str%%; }
LOG_EOF

  # The rollback finished and is about to report itself, so there is nothing
  # unfinished left to warn about.
  safedeps_journal_close "${journal_id}"

  emit_system_message "safedeps: a dependency install the command gate did not recognize introduced a suspicious closure — rolled back to the last confirmed safe snapshot.

Detected:
${reason_str%%; }

Rollback snapshot: ${rollback_id}
Rolled-back files: ${rolled_str%, }${warning_str:+

Additional warnings:
${warning_str%%; }}"
  return 0
}

if [[ "${BACKSTOP_INSTALL:-false}" == "true" ]]; then
  run_command_independent_backstop
  exit 0
fi

# Stage the record before anything reads the project (see stage_verified_state).
VERIFIED_ID="verified-${SNAPSHOT_ID}"
if stage_verified_state; then
  VERIFIED_STAGED=true
else
  discard_staged_state
fi

# Whether the npm installs in this command were read at all is settled before
# what was read is judged: a closure of a directory the install never touched
# is clean and says nothing about the install. It reads only file metadata.
settle_npm_trace

# Run all checks
collect_npm_new_records
check_npm_effect_closure
check_postinstall_scripts
check_lockfile_diff
check_npm_new_sources
check_binaries

# --- Reorg Decision ---

if [[ "${SUSPICIOUS}" == "true" ]]; then
  # REORG: Rollback to last confirmed safe snapshot
  discard_staged_state
  # With no confirmed snapshot the rollback restores the state from before this
  # command. Nothing verified that state, and it can hold the very package the
  # gate rejected: a fresh clone's committed lockfile, or a lockfile that held
  # the package before this install. So it is restored without install scripts,
  # and every record says that is what happened (ROLLBACK_TARGET_CONFIRMED).
  ROLLBACK_SNAPSHOT_ID=$(read_confirmed_snapshot "${DIR_HASH}")
  if [[ -z "${ROLLBACK_SNAPSHOT_ID}" ]] || [[ ! -f "${SNAPSHOT_DIR}/${ROLLBACK_SNAPSHOT_ID}_meta.json" ]]; then
    ROLLBACK_SNAPSHOT_ID="${SNAPSHOT_ID}"
    ROLLBACK_TARGET_CONFIRMED=false
  else
    ROLLBACK_TARGET_CONFIRMED=true
  fi

  ROLLED_BACK=()

  # Everything from here to the reorg.log write below is destructive. The
  # journal records the intent first so an interrupted rollback leaves a record
  # instead of a silently half-reverted project (measured:
  # scripts/measure/rollback-kill-state.sh).
  REASON_STR_FOR_JOURNAL=$(printf '%s; ' "${REASONS[@]}")
  JOURNAL_ID="reorg-${SNAPSHOT_ID}-$$"
  safedeps_journal_open "${JOURNAL_ID}" "${PROJECT_DIR}" "${ROLLBACK_SNAPSHOT_ID}" \
    "${REASON_STR_FOR_JOURNAL%%; }" "restoring-files"

  while IFS= read -r monitored_file; do
    [[ -z "${monitored_file}" ]] && continue
    restore_monitored_file "${monitored_file}" "${ROLLBACK_SNAPSHOT_ID}"
  done < <(monitored_files)

  while IFS= read -r csproj_file; do
    [[ -z "${csproj_file}" ]] && continue
    restore_monitored_file "${csproj_file}" "${ROLLBACK_SNAPSHOT_ID}"
  done < <(find "${PROJECT_DIR}" -maxdepth 1 -type f -name "*.csproj" -exec basename {} \; 2>/dev/null | sort)

  while IFS= read -r snap_csproj; do
    [[ -z "${snap_csproj}" ]] && continue
    restore_monitored_file "${snap_csproj}" "${ROLLBACK_SNAPSHOT_ID}"
  done < <(find "${SNAPSHOT_DIR}" -maxdepth 1 -type f -name "${ROLLBACK_SNAPSHOT_ID}_*.csproj" -exec basename {} \; 2>/dev/null | sed "s/^${ROLLBACK_SNAPSHOT_ID}_//" | sort)

  while IFS= read -r missing_csproj; do
    [[ -z "${missing_csproj}" ]] && continue
    restore_monitored_file "${missing_csproj}" "${ROLLBACK_SNAPSHOT_ID}"
  done < <(find "${SNAPSHOT_DIR}" -maxdepth 1 -type f -name "${ROLLBACK_SNAPSHOT_ID}_*.csproj.missing" -exec basename {} \; 2>/dev/null | sed "s/^${ROLLBACK_SNAPSHOT_ID}_//; s/\\.missing$//" | sort)

  # Restore package.json if it was modified
  rollback_package_json="${SNAPSHOT_DIR}/${ROLLBACK_SNAPSHOT_ID}_package.json"
  current_package_json="${PROJECT_DIR}/package.json"
  if [[ -f "${rollback_package_json}" ]] && files_differ "${rollback_package_json}" "${current_package_json}"; then
    cp "${rollback_package_json}" "${current_package_json}"
    ROLLED_BACK+=("package.json")
  fi

  safedeps_journal_stage "${JOURNAL_ID}" "reinstalling-node-modules"
  restore_node_modules
  cleanup_old_snapshots
  [[ -z "${TRACE_NOTE}" ]] || ROLLBACK_WARNINGS+=("${TRACE_NOTE}")

  REASON_STR=""
  [[ ${#REASONS[@]} -gt 0 ]] && REASON_STR=$(printf '%s; ' "${REASONS[@]}")
  ROLLED_BACK_STR=""
  [[ ${#ROLLED_BACK[@]} -gt 0 ]] && ROLLED_BACK_STR=$(printf '%s, ' "${ROLLED_BACK[@]}")
  WARNING_STR=""
  if [[ ${#ROLLBACK_WARNINGS[@]} -gt 0 ]]; then
    WARNING_STR=$(printf '%s; ' "${ROLLBACK_WARNINGS[@]}")
  fi

  # Where the rollback went, said the same way in all three records. Without a
  # confirmed snapshot it is not "the last confirmed safe snapshot", and saying
  # so was the record of a rollback that had just run the rejected package.
  #
  # The rollback runs no install script either way, but whether any ran is a
  # question about the install too. On Claude Code safedeps made it inert; on
  # Codex it cannot rewrite the command, so the install ran its scripts, the
  # rejected package's among them, before this hook saw anything. Saying "no
  # install script was run" there told a Codex user the rejected package never
  # ran.
  ROLLBACK_TARGET_LINE="the last confirmed safe snapshot"
  if [[ "${ROLLBACK_TARGET_CONFIRMED}" != true ]]; then
    if [[ "$(jq -r '.ignore_scripts_injected == true' "${META_FILE}" 2>/dev/null || printf 'false')" == true ]]; then
      scripts_line="no install script was run"
      scripts_log="install scripts were not run"
    else
      scripts_line="the rollback ran no install script. safedeps did not make the install itself inert (on Codex it cannot), so unless the command said --ignore-scripts, the install's own scripts already ran, the rejected package's included"
      scripts_log="the rollback ran no install script; the install was not made inert, so its own scripts ran unless the command said --ignore-scripts"
    fi
    ROLLBACK_TARGET_LINE="the state before this command, because there is no confirmed snapshot for ${PROJECT_DIR} yet. That state may still hold what was rejected, named below, and ${scripts_line}. Review node_modules, then run \`npm rebuild\` yourself if it is what you expect"
    log_advisory "post-verify REORG with no confirmed snapshot in ${PROJECT_DIR}: restored the state before this command, which may still hold what was rejected (${REASON_STR%%; }); ${scripts_log}."
  fi

  # Log the reorg event
  cat >> "${GUARD_DIR}/reorg.log" << LOG_EOF
[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] REORG executed
  Snapshot: ${SNAPSHOT_ID}
  Rollback snapshot: ${ROLLBACK_SNAPSHOT_ID}
  Rolled back to: ${ROLLBACK_TARGET_LINE}
  Project: ${PROJECT_DIR}
  Reasons: ${REASON_STR%%; }
  Rolled back: ${ROLLED_BACK_STR%, }
  Rollback warnings: ${WARNING_STR%%; }
LOG_EOF

  # Recorded and about to be reported — nothing unfinished remains.
  safedeps_journal_close "${JOURNAL_ID}"

  ROLLBACK_MESSAGE="safedeps: suspicious dependency change detected — rolled back to ${ROLLBACK_TARGET_LINE}.

Detected problems:
${REASON_STR%%; }

Rollback snapshot: ${ROLLBACK_SNAPSHOT_ID}
Rolled-back files: ${ROLLED_BACK_STR%, }"
  if [[ -n "${WARNING_STR%%; }" ]]; then
    ROLLBACK_MESSAGE="${ROLLBACK_MESSAGE}

Additional warnings:
${WARNING_STR%%; }"
  fi
  emit_system_message "${ROLLBACK_MESSAGE}

Details log: ${GUARD_DIR}/reorg.log"
  exit 0
fi

run_verified_npm_rebuild_if_injected
confirm_verified_state
cleanup_old_snapshots
emit_confirm_warnings_if_any

exit 0
