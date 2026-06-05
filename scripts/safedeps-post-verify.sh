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

if ! command -v jq >/dev/null 2>&1; then
  echo "safedeps: jq is not installed; skipping verify hook." >&2
  exit 0
fi

SAFEDEPS_REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/ledger/ledger.sh
source "${SAFEDEPS_REPO_DIR}/lib/ledger/ledger.sh"
# shellcheck source=../lib/providers/providers.sh
source "${SAFEDEPS_REPO_DIR}/lib/providers/providers.sh"
# shellcheck source=../lib/npm/closure.sh
source "${SAFEDEPS_REPO_DIR}/lib/npm/closure.sh"

acquire_state_lock() {
  local attempts=0

  while ! mkdir "${STATE_LOCK_DIR}" 2>/dev/null; do
    # Detect stale locks left by SIGKILL/OOM (V-005)
    if [[ -d "${STATE_LOCK_DIR}" ]]; then
      local lock_mtime=""
      if lock_mtime=$(stat -f %m "${STATE_LOCK_DIR}" 2>/dev/null) || \
         lock_mtime=$(stat -c %Y "${STATE_LOCK_DIR}" 2>/dev/null); then
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
    if [[ ${attempts} -ge 100 ]]; then
      echo "safedeps: could not acquire state lock; skipping verify hook." >&2
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
  local snapshot_file="${SNAPSHOT_DIR}/${rollback_snapshot_id}_${file_name}"
  local missing_marker="${SNAPSHOT_DIR}/${rollback_snapshot_id}_${file_name}.missing"
  local current_missing_marker="${SNAPSHOT_DIR}/${SNAPSHOT_ID}_${file_name}.missing"
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

    rm -f "${SNAPSHOT_DIR}/${old_id}"_*
  done < <(ls -t "${SNAPSHOT_DIR}"/*_meta.json 2>/dev/null || true)
}

restore_node_modules() {
  if ! command -v npm >/dev/null 2>&1; then
    ROLLBACK_WARNINGS+=("npm is not installed; node_modules was not reinstalled")
    return
  fi

  if [[ -f "${PROJECT_DIR}/package-lock.json" ]]; then
    if (cd "${PROJECT_DIR}" && npm ci >/dev/null 2>&1); then
      return
    fi
    ROLLBACK_WARNINGS+=("npm ci failed during rollback; retrying with npm install")
  fi

  if (cd "${PROJECT_DIR}" && rm -rf node_modules && npm install >/dev/null 2>&1); then
    return
  fi

  ROLLBACK_WARNINGS+=("node_modules reinstall failed; review the project manually")
}

# Read tool input from stdin
INPUT=$(cat)

# Only process Bash tool results
TOOL_NAME=$(echo "${INPUT}" | jq -r '.tool_name // empty' 2>/dev/null)
if [[ "${TOOL_NAME}" != "Bash" ]]; then
  exit 0
fi

STATE_LOCK_HELD=true
acquire_state_lock
trap '[ "${STATE_LOCK_HELD:-}" = "true" ] && release_state_lock; STATE_LOCK_HELD=false' EXIT

# Check if we have a pending snapshot to verify (V-004: atomic state file)
if [[ ! -f "${GUARD_DIR}/current_state" ]]; then
  # Legacy fallback for in-flight upgrades
  if [[ ! -f "${GUARD_DIR}/current_snapshot_id" ]]; then
    exit 0
  fi
  SNAPSHOT_ID=$(cat "${GUARD_DIR}/current_snapshot_id")
  PROJECT_DIR=$(cat "${GUARD_DIR}/current_project_dir" 2>/dev/null || pwd)
  rm -f "${GUARD_DIR}/current_snapshot_id" "${GUARD_DIR}/current_project_dir"
else
  CURRENT_STATE=$(cat "${GUARD_DIR}/current_state")
  SNAPSHOT_ID=$(echo "${CURRENT_STATE}" | jq -r '.snapshot_id // empty')
  PROJECT_DIR=$(echo "${CURRENT_STATE}" | jq -r '.project_dir // empty')
  DIR_HASH=$(echo "${CURRENT_STATE}" | jq -r '.dir_hash // empty')
  rm -f "${GUARD_DIR}/current_state"
fi

if [[ -z "${SNAPSHOT_ID}" ]]; then
  exit 0
fi
if [[ -z "${PROJECT_DIR}" ]]; then
  PROJECT_DIR=$(pwd)
fi
if [[ -z "${DIR_HASH:-}" ]]; then
  DIR_HASH=$(compute_dir_hash "${PROJECT_DIR}")
fi
release_state_lock; STATE_LOCK_HELD=false

# Verify snapshot exists
META_FILE="${SNAPSHOT_DIR}/${SNAPSHOT_ID}_meta.json"
if [[ ! -f "${META_FILE}" ]]; then
  exit 0
fi

# --- Begin Reorg Verification ---

SUSPICIOUS=false
REASONS=()
ROLLBACK_WARNINGS=()

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

# Function: check for suspicious postinstall scripts in new/changed dependencies
check_postinstall_scripts() {
  local pkg_json="${PROJECT_DIR}/package.json"
  local changed_lock=false
  local lock_file

  if [[ ! -f "${pkg_json}" ]]; then
    return
  fi

  for lock_file in "${SAFEDEPS_LOCK_FILES[@]}"; do
    if files_differ "${SNAPSHOT_DIR}/${SNAPSHOT_ID}_${lock_file}" "${PROJECT_DIR}/${lock_file}"; then
      changed_lock=true
      break
    fi
  done

  if [[ "${changed_lock}" != "true" ]] && ! files_differ "${SNAPSHOT_DIR}/${SNAPSHOT_ID}_package.json" "${pkg_json}"; then
    return
  fi

  # Check node_modules for new packages with install scripts
  if [[ -d "${PROJECT_DIR}/node_modules" ]]; then
    # Find packages with postinstall/preinstall scripts
    local script_packages
    local old_pkg_listing="${SNAPSHOT_DIR}/${SNAPSHOT_ID}_packages.list"
    if [[ -f "${old_pkg_listing}" ]]; then
      script_packages=$(find "${PROJECT_DIR}/node_modules" -maxdepth 3 -name "package.json" 2>/dev/null | sort | comm -13 "${old_pkg_listing}" - | head -50)
    else
      script_packages=$(find "${PROJECT_DIR}/node_modules" -maxdepth 3 -name "package.json" 2>/dev/null | head -50)
    fi

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

    # Lock file changed — analyze the diff
    if [[ "${lock_file}" == "package-lock.json" ]]; then
      local suspicious_urls
      local insecure_urls
      local new_deps

      # Check for resolved URLs pointing to non-standard registries
      suspicious_urls=$(diff "${snapshot}" "${current}" 2>/dev/null | grep '^>' | grep '"resolved"' | grep -viE 'registry\.npmjs\.org|registry\.yarnpkg\.com' | head -5 || true)
      if [[ -n "${suspicious_urls}" ]]; then
        SUSPICIOUS=true
        REASONS+=("Lock file contains resolved URLs from non-standard registries")
      fi

      # Check for git:// or http:// (non-https) resolved URLs
      insecure_urls=$(diff "${snapshot}" "${current}" 2>/dev/null | grep '^>' | grep '"resolved"' | grep -iE '(git://|http://)' | head -5 || true)
      if [[ -n "${insecure_urls}" ]]; then
        SUSPICIOUS=true
        REASONS+=("Lock file contains insecure (non-HTTPS) resolved URLs")
      fi

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

check_npm_effect_closure() {
  local lockfile="${PROJECT_DIR}/package-lock.json"
  local closure_file
  local provider_file
  local miss_file
  local package_name
  local version
  local miss_count
  local vulnerable_summary
  local kev_summary

  [[ -f "${lockfile}" ]] || return 0

  closure_file=$(mktemp "${TMPDIR:-/tmp}/safedeps-post-closure.XXXXXX") || return
  provider_file=$(mktemp "${TMPDIR:-/tmp}/safedeps-post-provider.XXXXXX") || {
    rm -f "${closure_file}"
    return
  }
  miss_file=$(mktemp "${TMPDIR:-/tmp}/safedeps-post-miss.XXXXXX") || {
    rm -f "${closure_file}" "${provider_file}"
    return
  }
  : > "${miss_file}"

  if ! safedeps_npm_lock_closure "${lockfile}" > "${closure_file}"; then
    SUSPICIOUS=true
    REASONS+=("npm package-lock closure could not be parsed")
    rm -f "${closure_file}" "${provider_file}" "${miss_file}"
    return
  fi

  while IFS=$'\t' read -r package_name version; do
    [[ -n "${package_name}" && -n "${version}" ]] || continue
    if ! safedeps_ledger_effect_check "npm" "${package_name}" "${version}" >/dev/null 2>&1; then
      printf '%s@%s\n' "${package_name}" "${version}" >> "${miss_file}"
    fi
  done < <(jq -r '.[] | [.package, (.version | tostring)] | @tsv' "${closure_file}")

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

# Run all checks
check_npm_effect_closure
check_postinstall_scripts
check_lockfile_diff
check_binaries

# --- Reorg Decision ---

if [[ "${SUSPICIOUS}" == "true" ]]; then
  # REORG: Rollback to last confirmed safe snapshot
  ROLLBACK_SNAPSHOT_ID=$(read_confirmed_snapshot "${DIR_HASH}")
  if [[ -z "${ROLLBACK_SNAPSHOT_ID}" ]] || [[ ! -f "${SNAPSHOT_DIR}/${ROLLBACK_SNAPSHOT_ID}_meta.json" ]]; then
    ROLLBACK_SNAPSHOT_ID="${SNAPSHOT_ID}"
  fi

  ROLLED_BACK=()

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

  restore_node_modules
  cleanup_old_snapshots

  REASON_STR=$(printf '%s; ' "${REASONS[@]}")
  ROLLED_BACK_STR=$(printf '%s, ' "${ROLLED_BACK[@]}")
  WARNING_STR=""
  if [[ ${#ROLLBACK_WARNINGS[@]} -gt 0 ]]; then
    WARNING_STR=$(printf '%s; ' "${ROLLBACK_WARNINGS[@]}")
  fi

  # Log the reorg event
  cat >> "${GUARD_DIR}/reorg.log" << LOG_EOF
[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] REORG executed
  Snapshot: ${SNAPSHOT_ID}
  Rollback snapshot: ${ROLLBACK_SNAPSHOT_ID}
  Project: ${PROJECT_DIR}
  Reasons: ${REASON_STR%%; }
  Rolled back: ${ROLLED_BACK_STR%, }
  Rollback warnings: ${WARNING_STR%%; }
LOG_EOF

  jq -nc \
    --arg reasons "${REASON_STR%%; }" \
    --arg rollback_snapshot "${ROLLBACK_SNAPSHOT_ID}" \
    --arg rolled_back "${ROLLED_BACK_STR%, }" \
    --arg warnings "${WARNING_STR%%; }" \
    --arg log_path "${GUARD_DIR}/reorg.log" \
    '{
      systemMessage: (
        "safedeps: 의심스러운 패키지 변경 감지, 마지막으로 confirmed 된 안전 스냅샷으로 롤백했습니다.\n\n" +
        "감지된 문제:\n" + $reasons + "\n\n" +
        "롤백 기준 스냅샷: " + $rollback_snapshot + "\n" +
        "롤백된 파일: " + $rolled_back +
        (if $warnings == "" then "" else "\n\n추가 경고:\n" + $warnings end) +
        "\n\n상세 로그: " + $log_path
      )
    }'
  exit 0
fi

confirm_snapshot "${SNAPSHOT_ID}" "${DIR_HASH}"
cleanup_old_snapshots

exit 0
