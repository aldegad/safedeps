#!/usr/bin/env bash
# Safedeps provider adapters.
# OSV is the canonical advisory truth; KEV/GHSA only add observable signals.

set -euo pipefail

SAFEDEPS_HOME="${SAFEDEPS_HOME:-${HOME}/.safedeps}"
SAFEDEPS_CACHE_DIR="${SAFEDEPS_CACHE_DIR:-${SAFEDEPS_HOME}/cache}"
SAFEDEPS_ADVISORY_LOG="${SAFEDEPS_ADVISORY_LOG:-${SAFEDEPS_HOME}/advisory.log}"
SAFEDEPS_PROVIDER_CACHE_TTL_SECONDS="${SAFEDEPS_PROVIDER_CACHE_TTL_SECONDS:-86400}"

SAFEDEPS_OSV_API_URL="${SAFEDEPS_OSV_API_URL:-https://api.osv.dev/v1/query}"
SAFEDEPS_OSV_BATCH_API_URL="${SAFEDEPS_OSV_BATCH_API_URL:-https://api.osv.dev/v1/querybatch}"
SAFEDEPS_KEV_CATALOG_URL="${SAFEDEPS_KEV_CATALOG_URL:-https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json}"
SAFEDEPS_GHSA_API_URL="${SAFEDEPS_GHSA_API_URL:-https://api.github.com/advisories}"

safedeps_providers_init() {
  umask 077
  mkdir -p \
    "${SAFEDEPS_CACHE_DIR}/osv" \
    "${SAFEDEPS_CACHE_DIR}/kev" \
    "${SAFEDEPS_CACHE_DIR}/ghsa" \
    "$(dirname "${SAFEDEPS_ADVISORY_LOG}")"
}

safedeps_provider_log() {
  local level="$1"
  local message="$2"

  safedeps_providers_init
  printf '[%s] %s %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "${level}" "${message}" >> "${SAFEDEPS_ADVISORY_LOG}"
}

safedeps_require_json_tools() {
  if ! command -v jq >/dev/null 2>&1; then
    printf 'safedeps providers: jq is required\n' >&2
    return 1
  fi
}

safedeps_require_http_client() {
  if ! command -v curl >/dev/null 2>&1; then
    printf 'safedeps providers: curl is required for provider queries\n' >&2
    return 1
  fi
}

safedeps_provider_mktemp_dir() {
  local tmp_root="${TMPDIR:-/tmp}"

  mkdir -p "${tmp_root}" || return 1
  mktemp -d "${tmp_root%/}/safedeps-providers.XXXXXX"
}

safedeps_cache_response_temp() {
  local target_path="$1"
  local target_dir
  local target_base

  target_dir=$(dirname "${target_path}")
  target_base=$(basename "${target_path}")
  mkdir -p "${target_dir}" || return 1
  mktemp "${target_dir}/.${target_base}.XXXXXX"
}

safedeps_url_host() {
  local url="$1"
  local host

  host="${url#*://}"
  host="${host%%/*}"
  host="${host%%:*}"
  printf '%s' "${host}"
}

safedeps_now_iso() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

safedeps_hash_text() {
  local input="$1"

  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "${input}" | shasum -a 256 | cut -d' ' -f1
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "${input}" | sha256sum | cut -d' ' -f1
  else
    printf 'safedeps providers: shasum or sha256sum is required\n' >&2
    return 1
  fi
}

safedeps_file_mtime() {
  local path="$1"

  stat -f %m "${path}" 2>/dev/null || stat -c %Y "${path}" 2>/dev/null
}

safedeps_cache_is_fresh() {
  local path="$1"
  local ttl="${2:-${SAFEDEPS_PROVIDER_CACHE_TTL_SECONDS}}"
  local now
  local mtime

  [[ -f "${path}" ]] || return 1
  now=$(date +%s)
  mtime=$(safedeps_file_mtime "${path}") || return 1
  [[ $(( now - mtime )) -le "${ttl}" ]]
}

safedeps_cache_key() {
  local namespace="$1"
  local ecosystem="$2"
  local package_name="$3"
  local version="$4"

  safedeps_hash_text "${namespace}
${ecosystem}
${package_name}
${version}"
}

safedeps_json_uri_escape() {
  jq -nr --arg value "$1" '$value | @uri'
}

safedeps_osv_ecosystem() {
  case "$1" in
    npm|NPM) printf 'npm' ;;
    pypi|PyPI|pip) printf 'PyPI' ;;
    crates.io|cargo|rust) printf 'crates.io' ;;
    go|golang|Go) printf 'Go' ;;
    rubygems|gem|ruby|RubyGems) printf 'RubyGems' ;;
    maven|Maven) printf 'Maven' ;;
    nuget|NuGet) printf 'NuGet' ;;
    *) printf '%s' "$1" ;;
  esac
}

safedeps_ghsa_ecosystem() {
  case "$1" in
    npm|NPM) printf 'npm' ;;
    pypi|PyPI|pip) printf 'pip' ;;
    crates.io|cargo|rust) printf 'rust' ;;
    go|golang|Go) printf 'go' ;;
    rubygems|gem|ruby|RubyGems) printf 'rubygems' ;;
    maven|Maven) printf 'maven' ;;
    nuget|NuGet) printf 'nuget' ;;
    *) printf '%s' "$1" ;;
  esac
}

safedeps_osv_query() {
  local ecosystem="$1"
  local package_name="$2"
  local version="$3"
  local osv_ecosystem
  local cache_key
  local cache_path
  local payload
  local response_file
  local http_status

  safedeps_require_json_tools || return 1
  safedeps_providers_init

  osv_ecosystem=$(safedeps_osv_ecosystem "${ecosystem}")
  cache_key=$(safedeps_cache_key "osv" "${osv_ecosystem}" "${package_name}" "${version}")
  cache_path="${SAFEDEPS_CACHE_DIR}/osv/${cache_key}.json"

  if safedeps_cache_is_fresh "${cache_path}"; then
    safedeps_provider_log "INFO" "OSV cache hit ecosystem=${osv_ecosystem} package=${package_name} version=${version}"
    cat "${cache_path}"
    return 0
  fi

  safedeps_require_http_client || {
    if [[ -f "${cache_path}" ]]; then
      safedeps_provider_log "ERROR" "OSV unavailable; stale cache refused ecosystem=${osv_ecosystem} package=${package_name} version=${version}"
    else
      safedeps_provider_log "ERROR" "OSV unavailable; cache miss ecosystem=${osv_ecosystem} package=${package_name} version=${version}"
    fi
    return 1
  }

  payload=$(jq -cn \
    --arg ecosystem "${osv_ecosystem}" \
    --arg package "${package_name}" \
    --arg version "${version}" \
    '{version: $version, package: {name: $package, ecosystem: $ecosystem}}')

  response_file=$(safedeps_cache_response_temp "${cache_path}") || return 1
  http_status=$(curl -fsS \
    --max-time 15 \
    -H 'Content-Type: application/json' \
    -o "${response_file}" \
    -w '%{http_code}' \
    -d "${payload}" \
    "${SAFEDEPS_OSV_API_URL}" 2>/dev/null || true)

  if [[ "${http_status}" == "200" ]] && jq -e 'type == "object"' "${response_file}" >/dev/null 2>&1; then
    mv -f "${response_file}" "${cache_path}"
    safedeps_provider_log "INFO" "OSV live query ok ecosystem=${osv_ecosystem} package=${package_name} version=${version}"
    cat "${cache_path}"
    return 0
  fi

  rm -f "${response_file}"
  if [[ -f "${cache_path}" ]]; then
    safedeps_provider_log "ERROR" "OSV live query failed; stale cache refused ecosystem=${osv_ecosystem} package=${package_name} version=${version} status=${http_status:-none}"
  else
    safedeps_provider_log "ERROR" "OSV live query failed; cache miss ecosystem=${osv_ecosystem} package=${package_name} version=${version} status=${http_status:-none}"
  fi
  return 1
}

safedeps_osv_query_batch() {
  local ecosystem="$1"
  local closure_file="$2"
  local osv_ecosystem
  local temp_dir
  local all_items_file
  local miss_items_file
  local payload_file
  local response_file
  local results_file
  local http_status
  local index=0
  local package_name
  local version
  local direct

  safedeps_require_json_tools || return 1
  safedeps_providers_init
  [[ -f "${closure_file}" ]] || return 1

  osv_ecosystem=$(safedeps_osv_ecosystem "${ecosystem}")
  temp_dir=$(safedeps_provider_mktemp_dir) || return 1
  all_items_file="${temp_dir}/items.jsonl"
  miss_items_file="${temp_dir}/misses.jsonl"
  payload_file="${temp_dir}/payload.json"
  response_file="${temp_dir}/response.json"
  results_file="${temp_dir}/results.json"
  : > "${all_items_file}"
  : > "${miss_items_file}"

  while IFS=$'\t' read -r package_name version direct; do
    [[ -n "${package_name}" && -n "${version}" ]] || continue
    local cache_key
    local cache_path
    cache_key=$(safedeps_cache_key "osv" "${osv_ecosystem}" "${package_name}" "${version}")
    cache_path="${SAFEDEPS_CACHE_DIR}/osv/${cache_key}.json"

    if safedeps_cache_is_fresh "${cache_path}"; then
      safedeps_provider_log "INFO" "OSV batch cache hit ecosystem=${osv_ecosystem} package=${package_name} version=${version}"
      jq -cn \
        --argjson index "${index}" \
        --arg ecosystem "${ecosystem}" \
        --arg package "${package_name}" \
        --arg version "${version}" \
        --argjson direct "${direct}" \
        --slurpfile osv "${cache_path}" \
        '{index:$index, ecosystem:$ecosystem, package:$package, version:$version, direct:$direct, osv:($osv[0] // {vulns:[]})}' >> "${all_items_file}"
    else
      jq -cn \
        --argjson index "${index}" \
        --arg ecosystem "${ecosystem}" \
        --arg package "${package_name}" \
        --arg version "${version}" \
        --argjson direct "${direct}" \
        --arg cache_path "${cache_path}" \
        '{index:$index, ecosystem:$ecosystem, package:$package, version:$version, direct:$direct, cache_path:$cache_path}' >> "${miss_items_file}"
    fi
    index=$((index + 1))
  done < <(jq -r '.[] | [.package, (.version | tostring), ((.direct // false) | tostring)] | @tsv' "${closure_file}")

  if [[ -s "${miss_items_file}" ]]; then
    safedeps_require_http_client || {
      safedeps_provider_log "ERROR" "OSV batch unavailable; cache miss ecosystem=${osv_ecosystem}"
      rm -rf "${temp_dir}"
      return 1
    }

    jq -cn --arg ecosystem "${osv_ecosystem}" --slurpfile misses "${miss_items_file}" '
      {
        queries: [
          $misses[]
          | {version: .version, package: {name: .package, ecosystem: $ecosystem}}
        ]
      }
    ' > "${payload_file}"

    http_status=$(curl -fsS \
      --max-time 20 \
      -H 'Content-Type: application/json' \
      -o "${response_file}" \
      -w '%{http_code}' \
      -d @"${payload_file}" \
      "${SAFEDEPS_OSV_BATCH_API_URL}" 2>/dev/null || true)

    if [[ "${http_status}" != "200" ]] || ! jq -e '.results | type == "array"' "${response_file}" >/dev/null 2>&1; then
      safedeps_provider_log "ERROR" "OSV batch query failed status=${http_status:-none}"
      rm -rf "${temp_dir}"
      return 1
    fi

    local miss_count
    local result_count
    miss_count=$(jq -s 'length' "${miss_items_file}")
    result_count=$(jq '.results | length' "${response_file}")
    if [[ "${miss_count}" != "${result_count}" ]]; then
      safedeps_provider_log "ERROR" "OSV batch result count mismatch misses=${miss_count} results=${result_count}"
      rm -rf "${temp_dir}"
      return 1
    fi

    local miss_i=0
    while IFS= read -r miss_item; do
      local cache_path
      local response_item_file
      cache_path=$(jq -r '.cache_path' <<< "${miss_item}")
      response_item_file=$(safedeps_cache_response_temp "${cache_path}") || {
        rm -rf "${temp_dir}"
        return 1
      }
      jq -c --argjson i "${miss_i}" '.results[$i] // {vulns: []}' "${response_file}" > "${response_item_file}"
      if ! jq -e 'type == "object"' "${response_item_file}" >/dev/null 2>&1; then
        rm -f "${response_item_file}"
        rm -rf "${temp_dir}"
        return 1
      fi
      mv -f "${response_item_file}" "${cache_path}"
      safedeps_provider_log "INFO" "OSV batch live query ok ecosystem=${osv_ecosystem} package=$(jq -r '.package' <<< "${miss_item}") version=$(jq -r '.version' <<< "${miss_item}")"
      jq -cn --argjson miss "${miss_item}" --slurpfile osv "${cache_path}" \
        '$miss | del(.cache_path) | . + {osv: ($osv[0] // {vulns: []})}' >> "${all_items_file}"
      miss_i=$((miss_i + 1))
    done < "${miss_items_file}"
  fi

  jq -s 'sort_by(.index)' "${all_items_file}" > "${results_file}"
  cat "${results_file}"
  rm -rf "${temp_dir}"
}

safedeps_extract_cves_from_osv() {
  local osv_json="$1"

  jq -r '
    [
      .vulns[]? |
      (.id // empty),
      (.aliases[]? // empty)
    ]
    | map(select(test("^CVE-[0-9]{4}-[0-9]+$")))
    | unique
    | .[]
  ' "${osv_json}"
}

safedeps_kev_catalog_path() {
  printf '%s/kev/known_exploited_vulnerabilities.json' "${SAFEDEPS_CACHE_DIR}"
}

safedeps_kev_refresh_catalog() {
  local cache_path
  local response_path
  local http_status

  safedeps_require_json_tools || return 1
  safedeps_providers_init
  cache_path=$(safedeps_kev_catalog_path)

  if safedeps_cache_is_fresh "${cache_path}"; then
    printf '%s' "${cache_path}"
    return 0
  fi

  if ! safedeps_require_http_client; then
    [[ -f "${cache_path}" ]] && printf '%s' "${cache_path}" && return 0
    return 1
  fi

  response_path=$(safedeps_cache_response_temp "${cache_path}") || return 1
  http_status=$(curl -fsS --max-time 15 -o "${response_path}" -w '%{http_code}' "${SAFEDEPS_KEV_CATALOG_URL}" 2>/dev/null || true)

  if [[ "${http_status}" == "200" ]] && jq -e '.vulnerabilities | type == "array"' "${response_path}" >/dev/null 2>&1; then
    mv -f "${response_path}" "${cache_path}"
    safedeps_provider_log "INFO" "CISA KEV catalog refresh ok"
    printf '%s' "${cache_path}"
    return 0
  fi

  rm -f "${response_path}"
  if [[ -f "${cache_path}" ]]; then
    safedeps_provider_log "WARN" "CISA KEV refresh failed; using stale local catalog status=${http_status:-none}"
    printf '%s' "${cache_path}"
    return 0
  fi

  safedeps_provider_log "WARN" "CISA KEV unavailable and no local catalog status=${http_status:-none}"
  return 1
}

safedeps_kev_overlay() {
  local osv_json="$1"
  local queried_at="$2"
  local catalog_path
  local cve_array
  local status="ok"
  local warning=""

  cve_array=$(safedeps_extract_cves_from_osv "${osv_json}" | jq -R . | jq -s .)

  if ! catalog_path=$(safedeps_kev_refresh_catalog); then
    jq -cn --arg queried_at "${queried_at}" --argjson cves "${cve_array}" \
      '{queried_at: $queried_at, status: "unavailable", warning: "CISA KEV catalog unavailable", cves_checked: $cves, exploited: false, matches: []}'
    return 0
  fi

  if ! safedeps_cache_is_fresh "${catalog_path}"; then
    status="stale"
    warning="CISA KEV catalog is older than provider TTL"
  fi

  jq -cn \
    --arg queried_at "${queried_at}" \
    --arg status "${status}" \
    --arg warning "${warning}" \
    --argjson cves "${cve_array}" \
    --slurpfile catalog "${catalog_path}" '
      ($catalog[0].vulnerabilities // []) as $items
      | ($items | map(select(.cveID as $id | $cves | index($id)))) as $matches
      | {
          queried_at: $queried_at,
          status: $status,
          warning: (if $warning == "" then null else $warning end),
          cves_checked: $cves,
          exploited: (($matches | length) > 0),
          matches: $matches
        }'
}

safedeps_ghsa_query() {
  local ecosystem="$1"
  local package_name="$2"
  local queried_at="$3"
  local ghsa_ecosystem
  local encoded_ecosystem
  local encoded_package
  local cache_key
  local cache_path
  local response_file
  local http_status
  local ghsa_host
  local curl_args

  safedeps_require_json_tools || return 1
  safedeps_providers_init

  ghsa_ecosystem=$(safedeps_ghsa_ecosystem "${ecosystem}")
  cache_key=$(safedeps_cache_key "ghsa" "${ghsa_ecosystem}" "${package_name}" "all")
  cache_path="${SAFEDEPS_CACHE_DIR}/ghsa/${cache_key}.json"

  if safedeps_cache_is_fresh "${cache_path}"; then
    jq -cn --arg queried_at "${queried_at}" --slurpfile advisories "${cache_path}" \
      '{queried_at: $queried_at, status: "cache_hit", advisories: $advisories[0]}'
    return 0
  fi

  if ! safedeps_require_http_client; then
    safedeps_provider_log "WARN" "GHSA skipped; curl unavailable ecosystem=${ghsa_ecosystem} package=${package_name}"
    jq -cn --arg queried_at "${queried_at}" \
      '{queried_at: $queried_at, status: "skipped", warning: "curl unavailable", advisories: []}'
    return 0
  fi

  encoded_ecosystem=$(safedeps_json_uri_escape "${ghsa_ecosystem}")
  encoded_package=$(safedeps_json_uri_escape "${package_name}")
  response_file=$(safedeps_cache_response_temp "${cache_path}") || return 1
  ghsa_host=$(safedeps_url_host "${SAFEDEPS_GHSA_API_URL}")

  curl_args=(
    -fsS
    --max-time 15
    -H 'Accept: application/vnd.github+json'
    -H 'X-GitHub-Api-Version: 2022-11-28'
    -o "${response_file}"
    -w '%{http_code}'
  )

  if [[ -n "${GITHUB_TOKEN:-}" && "${ghsa_host}" == "api.github.com" ]]; then
    curl_args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
    safedeps_provider_log "WARN" "GHSA token withheld for non-GitHub host host=${ghsa_host}"
  fi

  http_status=$(curl "${curl_args[@]}" \
    "${SAFEDEPS_GHSA_API_URL}?ecosystem=${encoded_ecosystem}&affects=${encoded_package}&per_page=100" 2>/dev/null || true)

  if [[ "${http_status}" == "200" ]] && jq -e 'type == "array"' "${response_file}" >/dev/null 2>&1; then
    mv -f "${response_file}" "${cache_path}"
    safedeps_provider_log "INFO" "GHSA live query ok ecosystem=${ghsa_ecosystem} package=${package_name}"
    jq -cn --arg queried_at "${queried_at}" --slurpfile advisories "${cache_path}" \
      '{queried_at: $queried_at, status: "live", advisories: $advisories[0]}'
    return 0
  fi

  rm -f "${response_file}"
  safedeps_provider_log "WARN" "GHSA cross-check skipped ecosystem=${ghsa_ecosystem} package=${package_name} status=${http_status:-none}"
  jq -cn --arg queried_at "${queried_at}" --arg status "${http_status:-none}" \
    '{queried_at: $queried_at, status: "skipped", warning: ("GHSA cross-check skipped; HTTP status " + $status), advisories: []}'
}

safedeps_providers_query() {
  local ecosystem="$1"
  local package_name="$2"
  local version="$3"
  local queried_at
  local osv_file
  local temp_dir
  local kev_file
  local ghsa_file

  safedeps_require_json_tools || return 1
  queried_at=$(safedeps_now_iso)
  if ! temp_dir=$(safedeps_provider_mktemp_dir); then
    safedeps_provider_log "ERROR" "provider temp dir creation failed tmpdir=${TMPDIR:-/tmp}"
    jq -cn \
      --arg ecosystem "${ecosystem}" \
      --arg package "${package_name}" \
      --arg version "${version}" \
      --arg queried_at "${queried_at}" \
      '{
        ecosystem: $ecosystem,
        package: $package,
        version: $version,
        queried_at: $queried_at,
        status: "blocked",
        reason: "provider temp dir creation failed",
        vulnerabilities: [],
        kev: {queried_at: $queried_at, status: "not_queried", exploited: false, matches: []},
        advisories: [],
        provider_status: {
          osv: {status: "failed_closed"},
          kev: {status: "not_queried"},
          ghsa: {status: "not_queried"}
        }
      }'
    return 1
  fi

  osv_file="${temp_dir}/osv.json"
  kev_file="${temp_dir}/kev.json"
  ghsa_file="${temp_dir}/ghsa.json"

  if ! safedeps_osv_query "${ecosystem}" "${package_name}" "${version}" > "${osv_file}"; then
    jq -cn \
      --arg ecosystem "${ecosystem}" \
      --arg package "${package_name}" \
      --arg version "${version}" \
      --arg queried_at "${queried_at}" \
      '{
        ecosystem: $ecosystem,
        package: $package,
        version: $version,
        queried_at: $queried_at,
        status: "blocked",
        reason: "OSV primary provider unavailable and no fresh cache",
        vulnerabilities: [],
        kev: {queried_at: $queried_at, status: "not_queried", exploited: false, matches: []},
        advisories: [],
        provider_status: {
          osv: {status: "failed_closed"},
          kev: {status: "not_queried"},
          ghsa: {status: "not_queried"}
        }
      }'
    rm -rf "${temp_dir}"
    return 1
  fi

  safedeps_kev_overlay "${osv_file}" "${queried_at}" > "${kev_file}"
  safedeps_ghsa_query "${ecosystem}" "${package_name}" "${queried_at}" > "${ghsa_file}"

  jq -cn \
    --arg ecosystem "${ecosystem}" \
    --arg package "${package_name}" \
    --arg version "${version}" \
    --arg queried_at "${queried_at}" \
    --slurpfile osv "${osv_file}" \
    --slurpfile kev "${kev_file}" \
    --slurpfile ghsa "${ghsa_file}" '
      ($osv[0].vulns // []) as $vulns
      | ($kev[0]) as $kev_result
      | ($ghsa[0]) as $ghsa_result
      | {
          ecosystem: $ecosystem,
          package: $package,
          version: $version,
          queried_at: $queried_at,
          status: (if $kev_result.exploited then "hard_block" elif ($vulns | length) > 0 then "vulnerable" else "clean" end),
          vulnerabilities: $vulns,
          kev: $kev_result,
          advisories: ($ghsa_result.advisories // []),
          provider_status: {
            osv: {status: "ok", canonical: true},
            kev: {status: ($kev_result.status // "ok"), overlay: true},
            ghsa: {status: ($ghsa_result.status // "ok"), enrichment: true}
          }
        }'
  rm -rf "${temp_dir}"
}

safedeps_providers_query_batch() {
  local ecosystem="$1"
  local closure_file="$2"
  local queried_at
  local temp_dir
  local osv_batch_file
  local results_file

  safedeps_require_json_tools || return 1
  queried_at=$(safedeps_now_iso)
  temp_dir=$(safedeps_provider_mktemp_dir) || return 1
  osv_batch_file="${temp_dir}/osv-batch.json"
  results_file="${temp_dir}/results.jsonl"
  : > "${results_file}"

  if ! safedeps_osv_query_batch "${ecosystem}" "${closure_file}" > "${osv_batch_file}"; then
    rm -rf "${temp_dir}"
    return 1
  fi

  while IFS= read -r item; do
    local osv_file
    local kev_json
    local status
    osv_file="${temp_dir}/osv-item.json"
    jq -c '.osv' <<< "${item}" > "${osv_file}"
    kev_json=$(safedeps_kev_overlay "${osv_file}" "${queried_at}")
    status=$(jq -r --argjson kev "${kev_json}" '
      if $kev.exploited then "hard_block"
      elif ((.osv.vulns // []) | length) > 0 then "vulnerable"
      else "clean"
      end
    ' <<< "${item}")
    jq -cn \
      --argjson item "${item}" \
      --arg queried_at "${queried_at}" \
      --arg status "${status}" \
      --argjson kev "${kev_json}" \
      '{
        index: $item.index,
        ecosystem: $item.ecosystem,
        package: $item.package,
        version: $item.version,
        direct: ($item.direct // false),
        queried_at: $queried_at,
        status: $status,
        vulnerabilities: ($item.osv.vulns // []),
        kev: $kev,
        provider_status: {
          osv: {status: "ok", canonical: true, batch: true},
          kev: {status: ($kev.status // "ok"), overlay: true},
          ghsa: {status: "skipped", enrichment: true, reason: "closure batch omits GHSA enrichment"}
        }
      }' >> "${results_file}"
  done < <(jq -c '.[]' "${osv_batch_file}")

  jq -s 'sort_by(.index)' "${results_file}"
  rm -rf "${temp_dir}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  command_name="${1:-}"
  shift || true

  case "${command_name}" in
    query)
      if [[ "$#" -ne 3 ]]; then
        printf 'usage: %s query <ecosystem> <package> <version>\n' "$0" >&2
        exit 2
      fi
      safedeps_providers_query "$@"
      ;;
    query-batch)
      if [[ "$#" -ne 2 ]]; then
        printf 'usage: %s query-batch <ecosystem> <closure-json-file>\n' "$0" >&2
        exit 2
      fi
      safedeps_providers_query_batch "$@"
      ;;
    *)
      printf 'usage: %s {query|query-batch} ...\n' "$0" >&2
      exit 2
      ;;
  esac
fi
