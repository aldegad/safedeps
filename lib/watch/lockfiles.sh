#!/usr/bin/env bash
# The lockfile stage: what is installed in each root, judged per kind.
#
#   package-lock.json, npm-shrinkwrap.json
#       read with the gate's own closure reader (lib/npm/closure.sh), every
#       spec asked of OSV (querybatch), and every advisory that answers read in
#       full (safedeps_osv_vuln_detail) for its aliases, fixed versions and
#       withdrawal. KEV is the overlay. A finding is one (root, lockfile, spec,
#       advisory) with aliases folded into one id.
#   pnpm-lock.yaml, yarn.lock, bun.lock(b)
#       the existing `safedeps audit <eco>`, which is each tool's native audit
#       against the npm registry's advisory database, not OSV. It answers a
#       lockfile with severity counts and no package rows, so a finding there
#       is one `triage_needed` per lockfile, and `no_finding` is not OSV clean.
#   anything else listed in SAFEDEPS_WATCH_UNMEASURED_KINDS
#       an unmeasured row naming the kind: there is no resolver for it yet.
#
# A provider that fails leaves the lockfiles it would have judged
# `provider_unavailable`: their findings are kept, not closed.

# Directory names a walk never enters (the diagnosis' prune list, with plan
# worktrees: they are copies of a root, not roots).
SAFEDEPS_WATCH_PRUNE_NAMES="node_modules .git worktrees .venv venv target dist build Library .next vendor Pods .gradle"
SAFEDEPS_WATCH_MAX_DEPTH=4
SAFEDEPS_WATCH_OSV_CHUNK=500

# The file names the walk lists, and the kind each one is. Declared once: the
# walk's -name list and the classification are both read from here.
#   <glob>|<kind>|<class>   class: npm, native:<eco>, pin, container, unmeasured
SAFEDEPS_WATCH_FILE_KINDS="package-lock.json|npm_lock|npm
npm-shrinkwrap.json|npm_shrinkwrap|npm
pnpm-lock.yaml|pnpm_lock|native:pnpm
yarn.lock|yarn_lock|native:yarn
bun.lock|bun_lock|native:bun
bun.lockb|bun_lockb|native:bun
.sdkmanrc|sdkmanrc|pin
.java-version|java_version|pin
.tool-versions|tool_versions|pin
Dockerfile|container_image|container
Dockerfile.*|container_image|container
*.Dockerfile|container_image|container
Cargo.lock|cargo_lock|unmeasured
uv.lock|uv_lock|unmeasured
poetry.lock|poetry_lock|unmeasured
Pipfile.lock|pipfile_lock|unmeasured
requirements*.txt|requirements_txt|unmeasured
pyproject.toml|pyproject_toml|unmeasured
Gemfile.lock|gemfile_lock|unmeasured
*.csproj|csproj|unmeasured
packages.lock.json|nuget_lock|unmeasured
go.sum|go_sum|unmeasured
build.gradle|gradle_build|unmeasured
build.gradle.kts|gradle_build|unmeasured
gradle.lockfile|gradle_lockfile|unmeasured
pom.xml|maven_pom|unmeasured
Podfile.lock|podfile_lock|unmeasured
Package.resolved|package_resolved|unmeasured
composer.lock|composer_lock|unmeasured"

# What an unmeasured kind says, declared once.
safedeps_watch_unmeasured_reason() {
  case "$1" in
    gradle_build|gradle_lockfile|maven_pom) printf 'unresolved jvm dependencies' ;;
    container_image) printf 'image not scanned' ;;
    npm_lock_v1) printf 'package-lock v1 resolver not implemented' ;;
    *) printf '%s resolver not implemented' "$1" ;;
  esac
}

# The kind and class of a file name, by the first matching glob.
safedeps_watch_kind_of() {
  local name="$1" line glob
  while IFS= read -r line; do
    glob="${line%%|*}"
    # shellcheck disable=SC2053  # the glob is meant to match
    if [[ "${name}" == ${glob} ]]; then
      printf '%s' "${line#*|}"
      return 0
    fi
  done <<< "${SAFEDEPS_WATCH_FILE_KINDS}"
  return 1
}

# Lists the files of every kind under ROOT (resolved, local) into OUT, one
# NUL-terminated path relative to ROOT. Returns find's exit: a walk that met a
# directory it could not read listed what it could, and the caller records it.
safedeps_watch_list_files() {
  local root="$1" out="$2" name line prune rc=0
  local -a expr=() names=() prunes=()
  for name in ${SAFEDEPS_WATCH_PRUNE_NAMES}; do
    names+=(-o -name "${name}")
  done
  while IFS= read -r prune; do
    [[ -n "${prune}" ]] && prunes+=(-o -path "${prune}")
  done < <(safedeps_watch_prunes_under "${root}")
  while IFS= read -r line; do
    expr+=(-o -name "${line%%|*}")
  done <<< "${SAFEDEPS_WATCH_FILE_KINDS}"
  ( cd "${root}" && find . -xdev -maxdepth "${SAFEDEPS_WATCH_MAX_DEPTH}" \
      \( \( -type d \( -false "${names[@]}" \) \) "${prunes[@]+${prunes[@]/#${root}/.}}" \) -prune \
      -o -type f \( -false "${expr[@]}" \) -print0 ) > "${out}" 2>/dev/null || rc=$?
  return "${rc}"
}

# ---- npm: OSV --------------------------------------------------------------------

# jq definitions the npm judgment uses: version order, and one advisory id for
# a record and its aliases (the smallest CVE, else the smallest GHSA, else the
# record's own id).
# shellcheck disable=SC2016  # jq text
SAFEDEPS_WATCH_NPM_JQ='
def semver_key: (split("+")[0]) as $v | ($v | index("-")) as $i
  | (if $i == null then $v else $v[0:$i] end) as $core
  | (if $i == null then "" else $v[$i+1:] end) as $pre
  | {n: (($core | split(".") | map(tonumber? // 0)) + [0,0,0] | .[0:3]), pre: $pre};
def semver_gt($a; $b): ($a | semver_key) as $x | ($b | semver_key) as $y
  | if $x.n != $y.n then $x.n > $y.n
    elif $x.pre == $y.pre then false
    elif $x.pre == "" then true elif $y.pre == "" then false
    else $x.pre > $y.pre end;
def canonical_id: ([.id] + (.aliases // [])) as $all
  | ([$all[] | select(test("^CVE-[0-9]{4}-[0-9]+$"))] | sort | first)
    // ([$all[] | select(test("^GHSA-"))] | sort | first) // .id;
def fixed_for($pkg): [.affected[]? | select((.package.ecosystem // "") == "npm" and (.package.name // "") == $pkg)
  | .ranges[]?.events[]? | .fixed // empty] | unique;
'

# Judges every npm lockfile in LIST (lines: root<TAB>rel), writing findings to
# FINDINGS (JSON lines), lockfile statuses to STATUS (JSON lines) and error rows
# to ERRORS. TMP is a private directory.
safedeps_watch_measure_npm() {
  local list="$1" findings="$2" status="$3" errors="$4" tmp="$5" now="$6"
  local root rel file id specs unique chunk_dir chunk items ok=1 catalog kev_ok=1
  : > "${tmp}/npm-rows.jsonl"
  : > "${tmp}/npm-measured.txt"
  while IFS=$'\t' read -r root rel; do
    [[ -n "${root}" ]] || continue
    file="${root}/${rel#./}"
    if ! jq -e 'type == "object"' "${file}" >/dev/null 2>&1; then
      jq -nc --arg root "${root}" --arg rel "${rel}" '{root:$root, path:$rel, kind:"npm", status:"unreadable", reason:"not a JSON lockfile"}' >> "${status}"
      jq -nc --arg root "${root}" --arg rel "${rel}" '{kind:"lockfile_unreadable", root:$root, path:$rel}' >> "${errors}"
      continue
    fi
    if ! jq -e '(.packages | type) == "object"' "${file}" >/dev/null 2>&1; then
      jq -nc --arg root "${root}" --arg rel "${rel}" --arg reason "$(safedeps_watch_unmeasured_reason npm_lock_v1)" \
        '{root:$root, path:$rel, kind:"npm", status:"unmeasured", unmeasured_kind:"npm_lock_v1", reason:$reason}' >> "${status}"
      continue
    fi
    if ! specs=$(safedeps_npm_lock_closure "${file}" 2>/dev/null) \
      || ! jq -c --arg root "${root}" --arg rel "${rel}" '.[] | {root:$root, rel:$rel, package, version, direct}' <<< "${specs}" >> "${tmp}/npm-rows.jsonl"; then
      jq -nc --arg root "${root}" --arg rel "${rel}" '{root:$root, path:$rel, kind:"npm", status:"unreadable", reason:"closure not read"}' >> "${status}"
      jq -nc --arg root "${root}" --arg rel "${rel}" '{kind:"lockfile_unreadable", root:$root, path:$rel}' >> "${errors}"
      continue
    fi
    printf '%s\t%s\n' "${root}" "${rel}" >> "${tmp}/npm-measured.txt"
  done < "${list}"
  [[ -s "${tmp}/npm-measured.txt" ]] || return 0

  # Every distinct spec once, in chunks OSV takes in one request.
  unique="${tmp}/npm-unique.json"
  jq -s -c 'map({ecosystem:"npm", package, version, direct:false}) | unique_by([.package, .version])' "${tmp}/npm-rows.jsonl" > "${unique}" || ok=0
  chunk_dir="${tmp}/npm-chunks"
  mkdir -p "${chunk_dir}"
  : > "${tmp}/npm-answers.jsonl"
  if [[ "${ok}" -eq 1 ]]; then
    local n i=0
    n=$(jq 'length' "${unique}") || ok=0
    while [[ "${ok}" -eq 1 && "${i}" -lt "${n}" ]]; do
      chunk="${chunk_dir}/chunk-${i}.json"
      items="${chunk_dir}/items-${i}.json"
      if ! jq -c --argjson from "${i}" --argjson size "${SAFEDEPS_WATCH_OSV_CHUNK}" '.[$from:$from+$size]' "${unique}" > "${chunk}" \
        || ! safedeps_osv_query_batch npm "${chunk}" > "${items}" 2>/dev/null \
        || ! jq -c '.[] | {package, version, vulns: [(.osv.vulns // [])[] | {id, modified: (.modified // "")}]}' "${items}" >> "${tmp}/npm-answers.jsonl"; then
        ok=0
      fi
      i=$((i + SAFEDEPS_WATCH_OSV_CHUNK))
    done
  fi

  # Every advisory that answered, read in full once.
  : > "${tmp}/npm-details.jsonl"
  if [[ "${ok}" -eq 1 ]]; then
    local modified detail
    while IFS=$'\t' read -r id modified; do
      [[ -n "${id}" ]] || continue
      if ! detail=$(safedeps_osv_vuln_detail "${id}" "${modified}" 2>/dev/null) \
        || ! printf '%s\n' "${detail}" >> "${tmp}/npm-details.jsonl"; then
        ok=0
        break
      fi
    done < <(jq -r -s '[.[].vulns[]] | unique_by(.id) | .[] | [.id, .modified] | @tsv' "${tmp}/npm-answers.jsonl")
  fi

  if [[ "${ok}" -ne 1 ]]; then
    while IFS=$'\t' read -r root rel; do
      jq -nc --arg root "${root}" --arg rel "${rel}" '{root:$root, path:$rel, kind:"npm", status:"provider_unavailable", reason:"OSV did not answer"}' >> "${status}"
    done < "${tmp}/npm-measured.txt"
    jq -nc '{kind:"provider_unavailable", provider:"osv"}' >> "${errors}"
    return 0
  fi

  # KEV, once for the run. A catalog that cannot be read leaves kev unknown
  # (null) on every finding and says so; it never reads as "not exploited".
  catalog="${tmp}/kev.json"
  local kev_ids='null'
  if [[ -s "${tmp}/npm-details.jsonl" ]]; then
    if safedeps_kev_refresh_catalog "${catalog}" 2>/dev/null \
      && kev_ids=$(jq -c "${SAFEDEPS_KEV_JQ}"'if ([.] | kev_answer) then (.vulnerabilities | map({key: .cveID, value: true}) | from_entries) else error("no catalog") end' "${catalog}" 2>/dev/null); then
      :
    else
      kev_ids='null'
      kev_ok=0
      jq -nc '{kind:"kev_unavailable", provider:"kev"}' >> "${errors}"
    fi
  fi

  if ! jq -n -c \
      --slurpfile rows "${tmp}/npm-rows.jsonl" \
      --slurpfile answers "${tmp}/npm-answers.jsonl" \
      --slurpfile details "${tmp}/npm-details.jsonl" \
      --argjson kev "${kev_ids}" \
      "${SAFEDEPS_WATCH_NPM_JQ}"'
      ($answers | map({key: (.package + "@" + .version), value: [.vulns[].id]}) | from_entries) as $hits
      | ($details | map({key: .id, value: .}) | from_entries) as $rec
      | $rows[]
      | . as $row
      | ($hits[$row.package + "@" + $row.version] // []) as $ids
      | select(($ids | length) > 0)
      | [$ids[] | $rec[.]] | group_by(canonical_id)[]
      | . as $group
      | ($group | map([.id] + (.aliases // [])) | add | unique) as $names
      | ($group | map(fixed_for($row.package)) | add | unique | map(select(semver_gt(.; $row.version))) | sort_by(semver_key)) as $fixed
      | ($group | all(.[]; (.withdrawn // null) != null)) as $withdrawn
      | ($group[0] | canonical_id) as $adv
      | {key: ($row.root + "|" + $row.rel + "|npm|" + $row.package + "|" + $row.version + "|" + $adv),
         root: $row.root, scope: $row.rel, lockfile: $row.rel, ecosystem: "npm",
         package: $row.package, version: $row.version, direct: ($row.direct // false),
         advisory: $adv, ids: ($group | map(.id)), aliases: $names,
         summary: ($group | map(.summary // empty) | first // null),
         fixed: $fixed,
         kev: (if $kev == null then null else any($names[]; $kev[.] == true) end),
         state: (if $withdrawn then "closed" elif ($fixed | length) > 0 then "open" else "no_fix_available" end),
         closed_reason: (if $withdrawn then "advisory_withdrawn" else null end)}' >> "${findings}"; then
    while IFS=$'\t' read -r root rel; do
      jq -nc --arg root "${root}" --arg rel "${rel}" '{root:$root, path:$rel, kind:"npm", status:"provider_unavailable", reason:"answers not joined"}' >> "${status}"
    done < "${tmp}/npm-measured.txt"
    jq -nc '{kind:"judgment_failed", stage:"npm"}' >> "${errors}"
    return 0
  fi
  while IFS=$'\t' read -r root rel; do
    jq -nc --arg root "${root}" --arg rel "${rel}" --argjson kev_ok "${kev_ok}" \
      '{root:$root, path:$rel, kind:"npm", status:"measured", kev:($kev_ok == 1)}' >> "${status}"
  done < "${tmp}/npm-measured.txt"
}

# ---- pnpm / yarn / bun: native audit ---------------------------------------------

# PATH for a tool the installer recorded (config `tool_path`), then the system's.
safedeps_watch_tool_path() {
  local dirs
  dirs=$(safedeps_watch_config_get tool_path 2>/dev/null) || dirs=null
  if [[ "${dirs}" != "null" ]] && jq -e 'type == "array" and all(.[]; type == "string")' <<< "${dirs}" >/dev/null 2>&1; then
    printf '%s:/usr/bin:/bin:/usr/sbin:/sbin' "$(jq -r 'join(":")' <<< "${dirs}")"
  else
    printf '/usr/bin:/bin:/usr/sbin:/sbin'
  fi
}

# Judges one pnpm/yarn/bun lockfile with `safedeps audit <eco>`. Writes its
# status and, when the audit found something, one triage finding.
safedeps_watch_measure_native() {
  local root="$1" rel="$2" eco="$3" findings="$4" status="$5" tmp="$6"
  local dir rc=0 err counts reason tool_path
  dir="${root}/${rel#./}"
  dir="${dir%/*}"
  err="${tmp}/native.err"
  tool_path=$(safedeps_watch_tool_path)
  if ! PATH="${tool_path}" command -v "${eco}" >/dev/null 2>&1; then
    jq -nc --arg root "${root}" --arg rel "${rel}" --arg eco "${eco}" \
      '{root:$root, path:$rel, kind:"native", eco:$eco, status:"unavailable", reason:"tool_not_found"}' >> "${status}"
    return 0
  fi
  PATH="${tool_path}" COREPACK_ENABLE_NETWORK=0 COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
    safedeps_watch_run_limited 300 "${tmp}/native.out" "${err}" \
    bash "${SAFEDEPS_REPO_DIR}/lib/gates/audit.sh" "${eco}" --root "${dir}" --level low || rc=$?
  case "${rc}" in
    0)
      jq -nc --arg root "${root}" --arg rel "${rel}" --arg eco "${eco}" \
        '{root:$root, path:$rel, kind:"native", eco:$eco, status:"measured", native_audit:"no_finding", note:"npm registry advisory database, not OSV"}' >> "${status}"
      ;;
    1)
      counts=$(sed -n 's/^  severities: //p' "${err}" | head -1)
      jq -nc --arg root "${root}" --arg rel "${rel}" --arg eco "${eco}" --arg counts "${counts}" \
        '{root:$root, path:$rel, kind:"native", eco:$eco, status:"measured", native_audit:"vulnerable", severities:$counts}' >> "${status}"
      jq -nc --arg root "${root}" --arg rel "${rel}" --arg eco "${eco}" --arg counts "${counts}" \
        '{key: ($root + "|" + $rel + "|" + $eco + "|*|*|native_audit"), root:$root, scope:$rel, lockfile:$rel,
          ecosystem:$eco, package:"*", version:"*", advisory:"native_audit", severities:$counts,
          fixed:[], kev:null, state:"triage_needed", closed_reason:null,
          summary:"native audit found advisories; list them with the tool'"'"'s JSON audit and confirm each with OSV"}' >> "${findings}"
      ;;
    *)
      if [[ "${rc}" -eq 124 ]]; then
        reason="timeout"
      elif grep -q 'not found' "${err}" 2>/dev/null; then
        reason="tool_not_found"
      else
        reason="advisory_database_unreachable"
      fi
      jq -nc --arg root "${root}" --arg rel "${rel}" --arg eco "${eco}" --arg reason "${reason}" \
        '{root:$root, path:$rel, kind:"native", eco:$eco, status:"unavailable", reason:$reason}' >> "${status}"
      ;;
  esac
}
