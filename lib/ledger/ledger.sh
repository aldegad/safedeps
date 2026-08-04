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
  local context_hash="${4:-}"
  local hex

  if [[ -n "${context_hash}" ]]; then
    hex=$(safedeps_ledger_sha256_hex "${ecosystem}
${package_name}
${version}
${context_hash}")
  else
    hex=$(safedeps_ledger_sha256_hex "${ecosystem}
${package_name}
${version}")
  fi
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
  local context_hash="${4:-}"
  local hash

  hash=$(safedeps_ledger_hash "${ecosystem}" "${package_name}" "${version}" "${context_hash}")
  safedeps_ledger_path_for_hash "${hash}"
}

# The approval predicate, written once.
#
# `safedeps_ledger_validate_json` applies it to a single file; the effect index
# below applies the same text to a whole directory in one pass. Two copies of
# this would be two answers to "is this spec approved", which is exactly the
# split the ledger exists to prevent — so it lives here as jq source that both
# callers embed rather than as two hand-kept expressions.
SAFEDEPS_LEDGER_JQ_PREDICATE='
def ledger_is_valid:
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
    and ((.project_context // null) == null or (
      (.project_context | type) == "object"
      and (.project_context.context_hash | type == "string" and startswith("sha256:"))
      and (.project_context.project_root | type == "string" and length > 0)
      and (
        if .project_context.type == "npm-overrides-probe" then
          # The probe honored the consuming repo overrides, so the closure is
          # project-specific and the approval is keyed to that override set.
          (.project_context.overrides_source | type == "string" and length > 0)
          and (.project_context.overrides_sha256 | type == "string" and startswith("sha256:"))
          and ((.project_context.overrides // {}) | type == "object" and length > 0)
        else true
        end
      )
    ))
    and ((.project_context // null) == null
      or .project_context.type == "npm-overrides-probe"
      or (
      (
        .project_context.type == "yarn-project-lockfile"
        or .project_context.type == "yarn-project-materialized-lockfile"
      )
      and (.project_context.manifest_path | type == "string" and length > 0)
      and (.project_context.lockfile_path | type == "string" and length > 0)
      and (.project_context.input_sha256 | type == "string" and startswith("sha256:"))
      and ((.project_context.input_files // []) | type == "array" and length > 0)
      and (
        if .project_context.type == "yarn-project-materialized-lockfile" then
          (.project_context.materialization | type) == "object"
          and (.project_context.materialization.candidate | type == "string" and length > 0)
          and (.project_context.materialization.input_sha256 == .project_context.input_sha256)
          and (.project_context.materialization.generated_lockfile_sha256 | type == "string" and startswith("sha256:"))
          and (.project_context.materialization.command == "yarn install --mode=update-lockfile --no-immutable")
          and (.project_context.materialization.isolation == "private-project-mirror")
        else true
        end
      )
    ));

# Live = not revoked and not past its TTL. An expires_at that is missing or does
# not parse counts as expired, which is what the per-file reader has always done
# (safedeps_ledger_is_expired_file returns "expired" for both).
def ledger_is_live($now_epoch):
    (.revoked_at // "") == ""
    and ((try (.expires_at | fromdateiso8601) catch -1) > $now_epoch);

# An approval with no project_context answers only context-free questions, and
# one carrying a context answers only that context.
def ledger_matches_context($context_hash):
    if $context_hash == "" then (.project_context // null) == null
    else (.project_context.context_hash // "") == $context_hash
    end;

# Every (ecosystem, package, version) this ledger entry approves: the entry own
# spec, plus each spec in the closure that was verified with it.
#
# A transitive spec with no ecosystem of its own inherits the owner ecosystem.
# safedeps_ledger_approve always writes one, so this default is a floor rather
# than a live path -- but it must be the OWNER ecosystem, not the ecosystem
# being asked about, or a pip entry would answer an npm question.
def ledger_approved_specs:
    .ecosystem as $owner_ecosystem
    | [{ecosystem: $owner_ecosystem, package: .package, version: (.version | tostring)}]
      + ((.transitive_specs // []) | map({
          ecosystem: (.ecosystem // $owner_ecosystem),
          package: .package,
          version: (.version | tostring)
        }));
'

safedeps_ledger_validate_json() {
  local ledger_file="$1"

  safedeps_ledger_require_jq || return 1
  jq -e "${SAFEDEPS_LEDGER_JQ_PREDICATE} ledger_is_valid" "${ledger_file}" >/dev/null
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
  local context_hash="${4:-}"
  local ledger_file

  ledger_file=$(safedeps_ledger_path "${ecosystem}" "${package_name}" "${version}" "${context_hash}")
  [[ -f "${ledger_file}" ]] || return 1
  safedeps_ledger_validate_json "${ledger_file}" || return 1
  cat "${ledger_file}"
}

safedeps_ledger_check() {
  local ecosystem="$1"
  local package_name="$2"
  local version="$3"
  local context_hash="${4:-}"
  local ledger_file
  local expected_hash
  local stored_hash

  ledger_file=$(safedeps_ledger_path "${ecosystem}" "${package_name}" "${version}" "${context_hash}")
  expected_hash=$(safedeps_ledger_hash "${ecosystem}" "${package_name}" "${version}" "${context_hash}")

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

  local stored_context_hash
  stored_context_hash=$(jq -r '.project_context.context_hash // ""' "${ledger_file}")
  if [[ "${stored_context_hash}" != "${context_hash}" ]]; then
    jq -cn --arg hash "${expected_hash}" --arg context_hash "${context_hash}" --arg stored_context_hash "${stored_context_hash}" \
      '{approved: false, reason: "context_mismatch", hash: $hash, context_hash: $context_hash, stored_context_hash: $stored_context_hash}'
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
  local project_context_file="${9:-}"
  local approved_at
  local expires_at
  local hash
  local target_path
  local evidence_arg=()
  local transitive_arg=()
  local project_context_arg=()
  local context_hash=""

  safedeps_ledger_require_jq || return 1
  safedeps_ledger_init

  approved_at=$(safedeps_ledger_now_iso)
  expires_at=$(safedeps_ledger_add_days_iso "${ttl_days}")
  if [[ -n "${project_context_file}" ]]; then
    [[ -f "${project_context_file}" ]] || {
      printf 'safedeps ledger: project context file not found: %s\n' "${project_context_file}" >&2
      return 1
    }
    context_hash=$(jq -r '
      select(
        .type == "yarn-project-lockfile"
        or .type == "yarn-project-materialized-lockfile"
        or .type == "npm-overrides-probe"
      )
      | .context_hash // empty
    ' "${project_context_file}")
    [[ -n "${context_hash}" ]] || {
      printf 'safedeps ledger: invalid project context: %s\n' "${project_context_file}" >&2
      return 1
    }
    project_context_arg=(--slurpfile project_context "${project_context_file}")
  else
    project_context_arg=(--argjson project_context 'null')
  fi

  hash=$(safedeps_ledger_hash "${ecosystem}" "${package_name}" "${version}" "${context_hash}")
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
      "${project_context_arg[@]}" \
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
        project_context: (($project_context[0] // $project_context) // null),
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
      "${project_context_arg[@]}" \
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
        project_context: (($project_context[0] // $project_context) // null),
        transitive_specs: (($transitive_specs[0] // $transitive_specs) | map({
          ecosystem: (.ecosystem // $ecosystem),
          package: .package,
          version: (.version | tostring)
        }) | unique_by(.ecosystem + "\u0000" + .package + "\u0000" + .version))
      }' | safedeps_ledger_atomic_write "${target_path}"
  fi

  cat "${target_path}"
}

# Read the whole ledger once and write every spec it approves as TSV:
#
#   ecosystem <TAB> package <TAB> version <TAB> owner_hash <TAB> owner_package <TAB> owner_version
#
# This exists because of a measurement. The per-package reader this replaced
# walked the entire ledger directory for every closure entry, spawning two or
# three jq processes per ledger file per package -- O(closure x ledger). On a
# machine with 738 approved specs the effect gate crossed its 30s hook budget at
# a closure of FOUR packages (scripts/measure/effect-gate-cost.sh). Reading the
# ledger once turns that into O(closure + ledger).
#
# jq stops at the first file it cannot parse, so files are handed over in
# chunks, and a chunk that fails is retried one file at a time. That keeps a
# single corrupt ledger entry from emptying the index -- an empty index means
# every package reads as unapproved, which means a rollback of a clean install.
# The retry is not a quiet fallback: the file that broke is named on stderr.
safedeps_ledger_effect_index() {
  local context_hash="${1:-}"
  local now_epoch
  local chunk=()
  local ledger_file
  local program

  safedeps_ledger_require_jq || return 1
  safedeps_ledger_init
  now_epoch=$(date -u +%s)

  program="${SAFEDEPS_LEDGER_JQ_PREDICATE}"'
    select(ledger_is_valid)
    | select(ledger_is_live($now_epoch))
    | select(ledger_matches_context($context_hash))
    | . as $entry
    | ledger_approved_specs[]
    | [.ecosystem, .package, .version,
       $entry.hash, $entry.package, ($entry.version | tostring)]
    | @tsv
  '

  emit_chunk() {
    local files=("$@")
    [[ ${#files[@]} -gt 0 ]] || return 0
    if jq -r --argjson now_epoch "${now_epoch}" --arg context_hash "${context_hash}" \
      "${program}" "${files[@]}" 2>/dev/null; then
      return 0
    fi
    # One of these did not parse. Take them one at a time so the rest survive,
    # and say which one broke.
    local one
    for one in "${files[@]}"; do
      if ! jq -r --argjson now_epoch "${now_epoch}" --arg context_hash "${context_hash}" \
        "${program}" "${one}" 2>/dev/null; then
        printf 'safedeps ledger: skipping unreadable ledger entry %s\n' "${one}" >&2
      fi
    done
  }

  while IFS= read -r -d '' ledger_file; do
    chunk+=("${ledger_file}")
    if [[ ${#chunk[@]} -ge 100 ]]; then
      emit_chunk "${chunk[@]}"
      chunk=()
    fi
  done < <(find "${SAFEDEPS_LEDGER_DIR}" -maxdepth 1 -name '*.json' -type f -print0 2>/dev/null)
  emit_chunk "${chunk[@]+${chunk[@]}}"

  unset -f emit_chunk
}

# Print the specs in a closure that a prebuilt index does NOT approve, one
# `package<TAB>version` per line. Returns 0 when every spec is approved.
safedeps_ledger_effect_misses() {
  local index_file="$1"
  local ecosystem="$2"
  local closure_file="$3"
  local miss_file
  local status

  miss_file=$(mktemp "${TMPDIR:-/tmp}/safedeps-ledger-miss.XXXXXX") || return 1
  jq -r --arg ecosystem "${ecosystem}" \
    '.[] | [$ecosystem, .package, (.version | tostring)] | @tsv' "${closure_file}" \
  | awk -F'\t' -v idx="${index_file}" '
      BEGIN {
        while ((getline line < idx) > 0) {
          split(line, field, "\t")
          approved[field[1] SUBSEP field[2] SUBSEP field[3]] = 1
        }
        close(idx)
      }
      !(($1 SUBSEP $2 SUBSEP $3) in approved) { print $2 "\t" $3 }
    ' > "${miss_file}"

  status=0
  [[ -s "${miss_file}" ]] && status=1
  cat "${miss_file}"
  rm -f "${miss_file}"
  return "${status}"
}

# Check a whole closure against the ledger in one pass. This is the form the
# effect gate uses: one ledger read for the whole closure instead of one per
# package. Input is the closure JSON safedeps_npm_lock_closure produces.
safedeps_ledger_effect_check_batch() {
  local ecosystem="$1"
  local closure_file="$2"
  local context_hash="${3:-}"
  local index_file
  local status

  safedeps_ledger_require_jq || return 1
  [[ -f "${closure_file}" ]] || return 1

  index_file=$(mktemp "${TMPDIR:-/tmp}/safedeps-ledger-index.XXXXXX") || return 1
  safedeps_ledger_effect_index "${context_hash}" > "${index_file}"
  safedeps_ledger_effect_misses "${index_file}" "${ecosystem}" "${closure_file}"
  status=$?
  rm -f "${index_file}"
  return "${status}"
}

# Single-spec form, kept as the published contract. It reads the same index, so
# there is exactly one implementation of "does the ledger approve this spec".
safedeps_ledger_effect_check() {
  local ecosystem="$1"
  local package_name="$2"
  local version="$3"
  local context_hash="${4:-}"
  local now_iso
  local index_file
  local owner_line

  safedeps_ledger_require_jq || return 1
  safedeps_ledger_init
  now_iso=$(safedeps_ledger_now_iso)

  index_file=$(mktemp "${TMPDIR:-/tmp}/safedeps-ledger-index.XXXXXX") || return 1
  safedeps_ledger_effect_index "${context_hash}" > "${index_file}"
  owner_line=$(awk -F'\t' -v e="${ecosystem}" -v p="${package_name}" -v v="${version}" \
    '$1 == e && $2 == p && $3 == v { print; exit }' "${index_file}")
  rm -f "${index_file}"

  if [[ -n "${owner_line}" ]]; then
    jq -cn \
      --arg owner_hash "$(printf '%s' "${owner_line}" | cut -f4)" \
      --arg owner_package "$(printf '%s' "${owner_line}" | cut -f5)" \
      --arg owner_version "$(printf '%s' "${owner_line}" | cut -f6)" \
      --arg checked_at "${now_iso}" \
      '{approved:true, reason:"hit", owner_hash:$owner_hash, owner_package:$owner_package, owner_version:$owner_version, checked_at:$checked_at}'
    return 0
  fi

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
  local context_hash="${5:-}"
  local ledger_file
  local revoked_at

  ledger_file=$(safedeps_ledger_path "${ecosystem}" "${package_name}" "${version}" "${context_hash}")
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
      [[ "$#" -ge 3 && "$#" -le 4 ]] || { printf 'usage: %s hash <ecosystem> <package> <version> [context_hash]\n' "$0" >&2; exit 2; }
      safedeps_ledger_hash "$@"
      ;;
    path)
      [[ "$#" -ge 3 && "$#" -le 4 ]] || { printf 'usage: %s path <ecosystem> <package> <version> [context_hash]\n' "$0" >&2; exit 2; }
      safedeps_ledger_path "$@"
      ;;
    check)
      [[ "$#" -ge 3 && "$#" -le 4 ]] || { printf 'usage: %s check <ecosystem> <package> <version> [context_hash]\n' "$0" >&2; exit 2; }
      safedeps_ledger_check "$@"
      ;;
    approve)
      if [[ "$#" -lt 3 || "$#" -gt 9 ]]; then
        printf 'usage: %s approve <ecosystem> <package> <version> [version_range] [approved_by] [evidence_file] [ttl_days] [transitive_specs_file] [project_context_file]\n' "$0" >&2
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
