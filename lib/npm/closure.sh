#!/usr/bin/env bash
# npm dependency closure helpers for safedeps.

set -euo pipefail

safedeps_npm_require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    printf 'safedeps npm closure: jq is required\n' >&2
    return 1
  fi
}

safedeps_npm_lock_closure() {
  local lockfile="$1"
  local direct_package="${2:-}"

  safedeps_npm_require_jq || return 1
  [[ -f "${lockfile}" ]] || {
    printf 'safedeps npm closure: lockfile not found: %s\n' "${lockfile}" >&2
    return 1
  }

  jq -c --arg direct_package "${direct_package}" '
    def package_name_from_path($path):
      ($path | split("node_modules/") | last) as $tail
      | if ($tail | startswith("@")) then
          ($tail | split("/") | .[0:2] | join("/"))
        else
          ($tail | split("/") | .[0])
        end;

    if ((.packages // null) | type) == "object" then
      [
        .packages
        | to_entries[]
        | select(.key != "")
        | select((.value.version // "") != "")
        | {
            ecosystem: "npm",
            package: (.value.name // package_name_from_path(.key)),
            version: (.value.version | tostring)
          }
        | select(.package != "" and .version != "")
        | . + {direct: (.package == $direct_package)}
      ]
      | unique_by(.ecosystem + "\u0000" + .package + "\u0000" + .version)
      | sort_by(.package, .version)
    else
      []
    end
  ' "${lockfile}"
}

safedeps_npm_fixture_closure() {
  local package_name="$1"
  local version="$2"
  local fixture_file="${SAFEDEPS_NPM_CLOSURE_FIXTURE_JSON:-}"
  local key="${package_name}@${version}"

  [[ -n "${fixture_file}" && -f "${fixture_file}" ]] || return 1
  jq -e -c --arg key "${key}" --arg package "${package_name}" '
    if type == "object" and (.[$key] | type) == "array" then
      .[$key]
    elif type == "array" then
      .
    else
      empty
    end
    | map(. + {ecosystem: (.ecosystem // "npm"), direct: ((.direct // false) or (.package == $package))})
    | unique_by(.ecosystem + "\u0000" + .package + "\u0000" + (.version | tostring))
    | sort_by(.package, .version)
  ' "${fixture_file}"
}

safedeps_npm_sha256_file() {
  local file="$1"

  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${file}" | cut -d' ' -f1
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${file}" | cut -d' ' -f1
  else
    printf 'safedeps npm closure: shasum or sha256sum is required\n' >&2
    return 1
  fi
}

safedeps_npm_sha256_text() {
  local value="$1"

  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "${value}" | shasum -a 256 | cut -d' ' -f1
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "${value}" | sha256sum | cut -d' ' -f1
  else
    printf 'safedeps npm closure: shasum or sha256sum is required\n' >&2
    return 1
  fi
}

# Resolve one canonical Yarn Berry project context. The root package.json and
# yarn.lock are live project truth; the ledger key is derived from their exact
# resolution state so an approval cannot leak into another project or survive a
# lockfile/resolutions change.
#
# Returns 0 with JSON written to output_file when a usable root `resolutions`
# context exists, 1 when this is not a resolution-aware Yarn project, and 2 when
# such a context is declared but cannot be verified.
safedeps_npm_yarn_project_context() {
  local output_file="$1"
  local start_dir="${2:-${SAFEDEPS_NPM_PROJECT_DIR:-${PWD}}}"
  local dir parent manifest lockfile resolutions_json resolutions_sha lockfile_sha context_hex

  safedeps_npm_require_jq || return 2
  [[ -d "${start_dir}" ]] || {
    printf 'safedeps npm closure: project directory not found: %s\n' "${start_dir}" >&2
    return 2
  }
  dir=$(cd "${start_dir}" 2>/dev/null && pwd -P) || return 2

  while :; do
    manifest="${dir}/package.json"
    lockfile="${dir}/yarn.lock"
    if [[ -f "${manifest}" && -f "${lockfile}" ]]; then
      if jq -e '(.resolutions | type) == "object" and (.resolutions | length) > 0' "${manifest}" >/dev/null 2>&1; then
        if ! grep -q '^__metadata:' "${lockfile}"; then
          printf 'safedeps npm closure: Yarn resolutions found, but yarn.lock is not a supported Berry lockfile: %s\n' "${lockfile}" >&2
          return 2
        fi
        resolutions_json=$(jq -cS '.resolutions' "${manifest}") || return 2
        resolutions_sha=$(safedeps_npm_sha256_text "${resolutions_json}") || return 2
        lockfile_sha=$(safedeps_npm_sha256_file "${lockfile}") || return 2
        context_hex=$(safedeps_npm_sha256_text "${dir}
${resolutions_sha}
${lockfile_sha}") || return 2
        jq -cn \
          --arg type "yarn-project-lockfile" \
          --arg context_hash "sha256:${context_hex}" \
          --arg project_root "${dir}" \
          --arg manifest_path "${manifest}" \
          --arg lockfile_path "${lockfile}" \
          --arg resolutions_sha256 "sha256:${resolutions_sha}" \
          --arg lockfile_sha256 "sha256:${lockfile_sha}" \
          '{
            type: $type,
            context_hash: $context_hash,
            project_root: $project_root,
            manifest_path: $manifest_path,
            lockfile_path: $lockfile_path,
            resolutions_sha256: $resolutions_sha256,
            lockfile_sha256: $lockfile_sha256
          }' > "${output_file}"
        return 0
      fi
    fi

    # Never inherit dependency truth from outside the current Git worktree.
    # Worktree roots use a `.git` file; normal clones use a `.git` directory.
    [[ -e "${dir}/.git" ]] && break

    [[ "${dir}" == "/" ]] && break
    parent=$(dirname "${dir}")
    [[ "${parent}" == "${dir}" ]] && break
    dir="${parent}"
  done
  return 1
}

safedeps_npm_yarn_info_graph() {
  local project_root="$1"
  local fixture_file="${SAFEDEPS_YARN_INFO_FIXTURE_NDJSON:-}"

  if [[ -n "${fixture_file}" ]]; then
    [[ -f "${fixture_file}" ]] || {
      printf 'safedeps npm closure: Yarn info fixture not found: %s\n' "${fixture_file}" >&2
      return 1
    }
    cat "${fixture_file}"
    return 0
  fi

  command -v yarn >/dev/null 2>&1 || {
    printf 'safedeps npm closure: Yarn CLI is required for project closure\n' >&2
    return 1
  }
  (
    cd "${project_root}" &&
      yarn info -A -R --json
  )
}

# Yarn owns descriptor-to-locator resolution. Consume its machine-readable
# project graph and traverse from the exact requested locator; do not duplicate
# Yarn's resolution algorithm with a second lockfile parser.
safedeps_npm_yarn_project_closure() {
  local package_name="$1"
  local version="$2"
  local project_root="$3"
  local graph_file

  graph_file=$(mktemp "${TMPDIR:-/tmp}/safedeps-yarn-graph.XXXXXX") || return 1
  if ! safedeps_npm_yarn_info_graph "${project_root}" > "${graph_file}"; then
    rm -f "${graph_file}"
    return 1
  fi

  if ! jq -s -e -c --arg root "${package_name}@npm:${version}" '
    map(select((.value | type) == "string") | {
      key: .value,
      version: (.children.Version // null),
      dependencies: [(.children.Dependencies // [])[]?.locator]
    }) as $nodes
    | (reduce $nodes[] as $node ({}; .[$node.key] = $node)) as $index
    | def visit($pending; $seen):
        if ($pending | length) == 0 then $seen
        else $pending[0] as $key
          | if $seen[$key] then visit($pending[1:]; $seen)
            elif ($index[$key] // null) == null then error("missing Yarn locator: " + $key)
            else visit($pending[1:] + ($index[$key].dependencies // []); $seen + {($key): true})
            end
        end;
      def npm_name($key):
        if ($key | test("@npm:")) then ($key | capture("^(?<name>.+)@npm:").name)
        elif ($key | test("@virtual:.*#npm:")) then ($key | capture("^(?<name>.+)@virtual:").name)
        elif ($key | test("@patch:.*npm")) then ($key | capture("^(?<name>.+)@patch:").name)
        else null
        end;
      if ($index[$root] // null) == null then error("requested locator absent from Yarn project: " + $root)
      else visit([$root]; {}) as $seen
        | [
            $seen | keys[] as $key
            | $index[$key]
            | (npm_name(.key)) as $name
            | select($name != null and .version != null)
            | {
                ecosystem: "npm",
                package: $name,
                version: (.version | tostring),
                direct: (.key == $root)
              }
          ]
        | unique_by(.ecosystem + "\u0000" + .package + "\u0000" + .version)
        | sort_by(.package, .version)
      end
  ' "${graph_file}"; then
    rm -f "${graph_file}"
    return 1
  fi
  rm -f "${graph_file}"
}

safedeps_npm_write_source() {
  local output_file="$1"
  local type="$2"
  local context_file="${3:-}"
  local reason="${4:-}"

  if [[ -n "${context_file}" && -f "${context_file}" ]]; then
    jq -c --arg type "${type}" --arg reason "${reason}" '
      . + {type: $type}
      + (if $reason == "" then {} else {project_resolution_status: $reason, approval_scope: "deny-only"} end)
    ' "${context_file}" > "${output_file}"
  else
    jq -cn --arg type "${type}" --arg reason "${reason}" '
      {type: $type}
      + (if $reason == "" then {} else {project_resolution_status: $reason, approval_scope: "deny-only"} end)
    ' > "${output_file}"
  fi
}

safedeps_npm_resolve_spec_closure() {
  local package_name="$1"
  local version="$2"
  local source_file="${3:-}"
  local tmp_dir
  local lockfile
  local project_context_file
  local project_context_status=1
  local project_root=""

  safedeps_npm_require_jq || return 1

  if safedeps_npm_fixture_closure "${package_name}" "${version}"; then
    [[ -z "${source_file}" ]] || safedeps_npm_write_source "${source_file}" "fixture"
    return 0
  fi

  project_context_file=$(mktemp "${TMPDIR:-/tmp}/safedeps-yarn-context.XXXXXX") || return 1
  if safedeps_npm_yarn_project_context "${project_context_file}"; then
    project_context_status=0
    project_root=$(jq -r '.project_root' "${project_context_file}")
    if safedeps_npm_yarn_project_closure "${package_name}" "${version}" "${project_root}"; then
      [[ -z "${source_file}" ]] || safedeps_npm_write_source "${source_file}" "yarn-project-lockfile" "${project_context_file}"
      rm -f "${project_context_file}"
      return 0
    fi
    printf 'safedeps npm closure: requested package is not verifiable from Yarn project lockfile; published closure is deny-only\n' >&2
  else
    project_context_status=$?
  fi

  if ! command -v npm >/dev/null 2>&1; then
    printf 'safedeps npm closure: npm CLI is required\n' >&2
    rm -f "${project_context_file}"
    return 1
  fi

  tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-npm-closure.XXXXXX") || return 1

  printf '{"name":"safedeps-closure-probe","version":"0.0.0","private":true}\n' > "${tmp_dir}/package.json"
  if ! (
    cd "${tmp_dir}" &&
      npm install "${package_name}@${version}" \
        --package-lock-only \
        --ignore-scripts \
        --audit=false \
        --fund=false \
        --save-exact \
        >/dev/null
  ); then
    printf 'safedeps npm closure: npm lockfile resolution failed for %s@%s\n' "${package_name}" "${version}" >&2
    rm -rf "${tmp_dir}"
    return 1
  fi

  lockfile="${tmp_dir}/package-lock.json"
  safedeps_npm_lock_closure "${lockfile}" "${package_name}"
  local status=$?
  if [[ -n "${source_file}" ]]; then
    if [[ "${project_context_status}" -eq 0 ]]; then
      safedeps_npm_write_source "${source_file}" "npm-package-probe" "${project_context_file}" "project-closure-unavailable"
    elif [[ "${project_context_status}" -eq 2 ]]; then
      safedeps_npm_write_source "${source_file}" "npm-package-probe" "" "project-context-invalid"
    else
      safedeps_npm_write_source "${source_file}" "npm-package-probe"
    fi
  fi
  rm -rf "${tmp_dir}"
  rm -f "${project_context_file}"
  return "${status}"
}
