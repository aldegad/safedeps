#!/usr/bin/env bash
# Safedeps approved spec ledger.
# Canonical owner for approved dependency specs under ~/.safedeps/approved-specs.

set -euo pipefail

SAFEDEPS_HOME="${SAFEDEPS_HOME:-${HOME}/.safedeps}"
SAFEDEPS_LEDGER_DIR="${SAFEDEPS_LEDGER_DIR:-${SAFEDEPS_HOME}/approved-specs}"
SAFEDEPS_LEDGER_DEFAULT_TTL_DAYS="${SAFEDEPS_LEDGER_DEFAULT_TTL_DAYS:-30}"

safedeps_ledger_init() {
  umask 077
  mkdir -p "${SAFEDEPS_LEDGER_DIR}"
}

safedeps_ledger_require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    printf 'safedeps ledger: jq is required\n' >&2
    return 1
  fi
}

safedeps_ledger_now_iso() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

safedeps_ledger_add_days_iso() {
  local days="$1"
  local seconds

  seconds=$(( days * 86400 ))
  if date -u -r $(( $(date +%s) + seconds )) +"%Y-%m-%dT%H:%M:%SZ" >/dev/null 2>&1; then
    date -u -r $(( $(date +%s) + seconds )) +"%Y-%m-%dT%H:%M:%SZ"
  else
    date -u -d "@$(( $(date +%s) + seconds ))" +"%Y-%m-%dT%H:%M:%SZ"
  fi
}

safedeps_ledger_epoch() {
  local timestamp="$1"

  if date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "${timestamp}" +%s >/dev/null 2>&1; then
    date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "${timestamp}" +%s
  else
    date -u -d "${timestamp}" +%s
  fi
}

safedeps_ledger_sha256_hex() {
  local input="$1"

  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "${input}" | shasum -a 256 | cut -d' ' -f1
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "${input}" | sha256sum | cut -d' ' -f1
  else
    printf 'safedeps ledger: shasum or sha256sum is required\n' >&2
    return 1
  fi
}

safedeps_ledger_hash() {
  local ecosystem="$1"
  local package_name="$2"
  local version="$3"
  local hex

  hex=$(safedeps_ledger_sha256_hex "${ecosystem}
${package_name}
${version}")
  printf 'sha256:%s' "${hex}"
}

safedeps_ledger_hash_to_filename() {
  local hash="$1"

  printf '%s.json' "${hash/:/-}"
}

safedeps_ledger_path_for_hash() {
  local hash="$1"

  safedeps_ledger_init
  printf '%s/%s' "${SAFEDEPS_LEDGER_DIR}" "$(safedeps_ledger_hash_to_filename "${hash}")"
}

safedeps_ledger_path() {
  local ecosystem="$1"
  local package_name="$2"
  local version="$3"
  local hash

  hash=$(safedeps_ledger_hash "${ecosystem}" "${package_name}" "${version}")
  safedeps_ledger_path_for_hash "${hash}"
}

safedeps_ledger_validate_json() {
  local ledger_file="$1"

  safedeps_ledger_require_jq || return 1
  jq -e '
    type == "object"
    and (.hash | type == "string" and startswith("sha256:"))
    and (.ecosystem | type == "string" and length > 0)
    and (.package | type == "string" and length > 0)
    and (.version | type == "string" and length > 0)
    and (.version_range | type == "string")
    and (.approved_at | type == "string" and length > 0)
    and (.expires_at | type == "string" and length > 0)
    and (.approved_by | type == "string")
    and (.evidence | type == "object")
    and ((.transitive_specs // []) | type == "array")
  ' "${ledger_file}" >/dev/null
}

safedeps_ledger_is_expired_file() {
  local ledger_file="$1"
  local expires_at
  local expires_epoch
  local now_epoch

  [[ -f "${ledger_file}" ]] || return 0
  expires_at=$(jq -r '.expires_at // empty' "${ledger_file}" 2>/dev/null || true)
  [[ -n "${expires_at}" ]] || return 0

  if ! expires_epoch=$(safedeps_ledger_epoch "${expires_at}" 2>/dev/null); then
    return 0
  fi

  now_epoch=$(date +%s)
  [[ "${expires_epoch}" -le "${now_epoch}" ]]
}

safedeps_ledger_read() {
  local ecosystem="$1"
  local package_name="$2"
  local version="$3"
  local ledger_file

  ledger_file=$(safedeps_ledger_path "${ecosystem}" "${package_name}" "${version}")
  [[ -f "${ledger_file}" ]] || return 1
  safedeps_ledger_validate_json "${ledger_file}" || return 1
  cat "${ledger_file}"
}

safedeps_ledger_check() {
  local ecosystem="$1"
  local package_name="$2"
  local version="$3"
  local ledger_file
  local expected_hash
  local stored_hash

  ledger_file=$(safedeps_ledger_path "${ecosystem}" "${package_name}" "${version}")
  expected_hash=$(safedeps_ledger_hash "${ecosystem}" "${package_name}" "${version}")

  if [[ ! -f "${ledger_file}" ]]; then
    jq -cn --arg hash "${expected_hash}" '{approved: false, reason: "miss", hash: $hash}'
    return 1
  fi

  if ! safedeps_ledger_validate_json "${ledger_file}"; then
    jq -cn --arg hash "${expected_hash}" '{approved: false, reason: "invalid", hash: $hash}'
    return 1
  fi

  stored_hash=$(jq -r '.hash' "${ledger_file}")
  if [[ "${stored_hash}" != "${expected_hash}" ]]; then
    jq -cn --arg hash "${expected_hash}" --arg stored_hash "${stored_hash}" \
      '{approved: false, reason: "hash_mismatch", hash: $hash, stored_hash: $stored_hash}'
    return 1
  fi

  if safedeps_ledger_is_expired_file "${ledger_file}"; then
    jq -cn --arg hash "${expected_hash}" --slurpfile spec "${ledger_file}" \
      '{approved: false, reason: "expired", hash: $hash, spec: $spec[0]}'
    return 1
  fi

  jq -cn --arg hash "${expected_hash}" --slurpfile spec "${ledger_file}" \
    '{approved: true, reason: "hit", hash: $hash, spec: $spec[0]}'
}

safedeps_ledger_atomic_write() {
  local target_path="$1"
  local target_dir
  local target_base
  local temp_path

  safedeps_ledger_init
  target_dir=$(dirname "${target_path}")
  target_base=$(basename "${target_path}")
  mkdir -p "${target_dir}" || return 1
  temp_path=$(mktemp "${target_dir}/.${target_base}.XXXXXX") || return 1

  cat > "${temp_path}"
  chmod 600 "${temp_path}" 2>/dev/null || true
  safedeps_ledger_validate_json "${temp_path}" || {
    rm -f "${temp_path}"
    return 1
  }
  mv -f "${temp_path}" "${target_path}"
}

safedeps_ledger_write_approved_spec() {
  local ecosystem="$1"
  local package_name="$2"
  local version="$3"
  local version_range="${4:-$3}"
  local approved_by="${5:-local}"
  local evidence_file="${6:-}"
  local ttl_days="${7:-${SAFEDEPS_LEDGER_DEFAULT_TTL_DAYS}}"
  local transitive_specs_file="${8:-}"
  local approved_at
  local expires_at
  local hash
  local target_path
  local evidence_arg=()
  local transitive_arg=()

  safedeps_ledger_require_jq || return 1
  safedeps_ledger_init

  approved_at=$(safedeps_ledger_now_iso)
  expires_at=$(safedeps_ledger_add_days_iso "${ttl_days}")
  hash=$(safedeps_ledger_hash "${ecosystem}" "${package_name}" "${version}")
  target_path=$(safedeps_ledger_path_for_hash "${hash}")

  if [[ -n "${evidence_file}" ]]; then
    [[ -f "${evidence_file}" ]] || {
      printf 'safedeps ledger: evidence file not found: %s\n' "${evidence_file}" >&2
      return 1
    }
    evidence_arg=(--slurpfile evidence "${evidence_file}")
  else
    evidence_arg=(--argjson evidence '{}')
  fi

  if [[ -n "${transitive_specs_file}" ]]; then
    [[ -f "${transitive_specs_file}" ]] || {
      printf 'safedeps ledger: transitive specs file not found: %s\n' "${transitive_specs_file}" >&2
      return 1
    }
    jq -e 'type == "array"' "${transitive_specs_file}" >/dev/null || {
      printf 'safedeps ledger: transitive specs file must be a JSON array: %s\n' "${transitive_specs_file}" >&2
      return 1
    }
    transitive_arg=(--slurpfile transitive_specs "${transitive_specs_file}")
  else
    transitive_arg=(--argjson transitive_specs '[]')
  fi

  if [[ -n "${evidence_file}" ]]; then
    jq -cn \
      --arg hash "${hash}" \
      --arg ecosystem "${ecosystem}" \
      --arg package "${package_name}" \
      --arg version "${version}" \
      --arg version_range "${version_range}" \
      --arg approved_at "${approved_at}" \
      --arg expires_at "${expires_at}" \
      --arg approved_by "${approved_by}" \
      "${evidence_arg[@]}" \
      "${transitive_arg[@]}" \
      '{
        hash: $hash,
        ecosystem: $ecosystem,
        package: $package,
        version: $version,
        version_range: $version_range,
        approved_at: $approved_at,
        expires_at: $expires_at,
        approved_by: $approved_by,
        evidence: ($evidence[0] // {}),
        transitive_specs: (($transitive_specs[0] // $transitive_specs) | map({
          ecosystem: (.ecosystem // $ecosystem),
          package: .package,
          version: (.version | tostring)
        }) | unique_by(.ecosystem + "\u0000" + .package + "\u0000" + .version))
      }' | safedeps_ledger_atomic_write "${target_path}"
  else
    jq -cn \
      --arg hash "${hash}" \
      --arg ecosystem "${ecosystem}" \
      --arg package "${package_name}" \
      --arg version "${version}" \
      --arg version_range "${version_range}" \
      --arg approved_at "${approved_at}" \
      --arg expires_at "${expires_at}" \
      --arg approved_by "${approved_by}" \
      "${evidence_arg[@]}" \
      "${transitive_arg[@]}" \
      '{
        hash: $hash,
        ecosystem: $ecosystem,
        package: $package,
        version: $version,
        version_range: $version_range,
        approved_at: $approved_at,
        expires_at: $expires_at,
        approved_by: $approved_by,
        evidence: $evidence,
        transitive_specs: (($transitive_specs[0] // $transitive_specs) | map({
          ecosystem: (.ecosystem // $ecosystem),
          package: .package,
          version: (.version | tostring)
        }) | unique_by(.ecosystem + "\u0000" + .package + "\u0000" + .version))
      }' | safedeps_ledger_atomic_write "${target_path}"
  fi

  cat "${target_path}"
}

safedeps_ledger_effect_check() {
  local ecosystem="$1"
  local package_name="$2"
  local version="$3"
  local ledger_file
  local now_iso

  safedeps_ledger_require_jq || return 1
  safedeps_ledger_init
  now_iso=$(safedeps_ledger_now_iso)

  while IFS= read -r -d '' ledger_file; do
    safedeps_ledger_validate_json "${ledger_file}" || continue
    safedeps_ledger_is_expired_file "${ledger_file}" && continue
    if jq -e \
      --arg ecosystem "${ecosystem}" \
      --arg package "${package_name}" \
      --arg version "${version}" \
      '
      (.revoked_at // "") == ""
      and (
        (.ecosystem == $ecosystem and .package == $package and .version == $version)
        or (((.transitive_specs // []) | map(select(
          (.ecosystem // $ecosystem) == $ecosystem
          and .package == $package
          and (.version | tostring) == $version
        )) | length) > 0)
      )
    ' \
      "${ledger_file}" >/dev/null; then
      jq -cn \
        --arg owner_hash "$(jq -r '.hash' "${ledger_file}")" \
        --arg owner_package "$(jq -r '.package' "${ledger_file}")" \
        --arg owner_version "$(jq -r '.version' "${ledger_file}")" \
        --arg checked_at "${now_iso}" \
        '{approved:true, reason:"hit", owner_hash:$owner_hash, owner_package:$owner_package, owner_version:$owner_version, checked_at:$checked_at}'
      return 0
    fi
  done < <(find "${SAFEDEPS_LEDGER_DIR}" -maxdepth 1 -name '*.json' -type f -print0 2>/dev/null)

  jq -cn \
    --arg ecosystem "${ecosystem}" \
    --arg package "${package_name}" \
    --arg version "${version}" \
    --arg checked_at "${now_iso}" \
    '{approved:false, reason:"miss", ecosystem:$ecosystem, package:$package, version:$version, checked_at:$checked_at}'
  return 1
}

safedeps_ledger_revoke() {
  local ecosystem="$1"
  local package_name="$2"
  local version="$3"
  local reason="${4:-revoked}"
  local ledger_file
  local revoked_at

  ledger_file=$(safedeps_ledger_path "${ecosystem}" "${package_name}" "${version}")
  [[ -f "${ledger_file}" ]] || return 1
  safedeps_ledger_validate_json "${ledger_file}" || return 1

  revoked_at=$(safedeps_ledger_now_iso)
  jq \
    --arg revoked_at "${revoked_at}" \
    --arg reason "${reason}" \
    '. + {revoked_at: $revoked_at, revoked_reason: $reason, expires_at: $revoked_at}' \
    "${ledger_file}" | safedeps_ledger_atomic_write "${ledger_file}"
  cat "${ledger_file}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  command_name="${1:-}"
  shift || true

  case "${command_name}" in
    hash)
      [[ "$#" -eq 3 ]] || { printf 'usage: %s hash <ecosystem> <package> <version>\n' "$0" >&2; exit 2; }
      safedeps_ledger_hash "$@"
      ;;
    path)
      [[ "$#" -eq 3 ]] || { printf 'usage: %s path <ecosystem> <package> <version>\n' "$0" >&2; exit 2; }
      safedeps_ledger_path "$@"
      ;;
    check)
      [[ "$#" -eq 3 ]] || { printf 'usage: %s check <ecosystem> <package> <version>\n' "$0" >&2; exit 2; }
      safedeps_ledger_check "$@"
      ;;
    approve)
      if [[ "$#" -lt 3 || "$#" -gt 8 ]]; then
        printf 'usage: %s approve <ecosystem> <package> <version> [version_range] [approved_by] [evidence_file] [ttl_days] [transitive_specs_file]\n' "$0" >&2
        exit 2
      fi
      safedeps_ledger_write_approved_spec "$@"
      ;;
    effect-check)
      [[ "$#" -eq 3 ]] || { printf 'usage: %s effect-check <ecosystem> <package> <version>\n' "$0" >&2; exit 2; }
      safedeps_ledger_effect_check "$@"
      ;;
    revoke)
      if [[ "$#" -lt 3 || "$#" -gt 4 ]]; then
        printf 'usage: %s revoke <ecosystem> <package> <version> [reason]\n' "$0" >&2
        exit 2
      fi
      safedeps_ledger_revoke "$@"
      ;;
    *)
      printf 'usage: %s {hash|path|check|effect-check|approve|revoke} ...\n' "$0" >&2
      exit 2
      ;;
  esac
fi
