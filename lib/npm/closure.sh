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

# The candidate mirror intentionally contains only the project inputs that
# affect Yarn's resolution. Package manifests cover workspaces, while the
# selected .yarn files cover the configured Yarn runtime, plugins, and patches.
# Caches, unplugged packages, install state, node_modules, and VCS data are
# never copied. They are neither canonical resolution input nor safe to share
# with a temporary resolver.
safedeps_npm_yarn_materialization_inputs() {
  local project_root="$1"
  local output_file="$2"
  local input_list
  local workspace_patterns
  local workspace_manifests
  local input_json
  local input_sha
  local source_file
  local relative_path
  local source_sha
  local workspace_pattern
  local workspace_dir
  local workspace_root
  local nullglob_was_enabled=0
  local workspace_error=0

  project_root=$(cd "${project_root}" 2>/dev/null && pwd -P) || return 1
  input_list=$(mktemp "${TMPDIR:-/tmp}/safedeps-yarn-inputs.XXXXXX") || return 1
  workspace_patterns=$(mktemp "${TMPDIR:-/tmp}/safedeps-yarn-workspace-patterns.XXXXXX") || {
    rm -f "${input_list}"
    return 1
  }
  workspace_manifests=$(mktemp "${TMPDIR:-/tmp}/safedeps-yarn-workspace-manifests.XXXXXX") || {
    rm -f "${input_list}" "${workspace_patterns}"
    return 1
  }
  : > "${input_list}"
  printf '%s\n' "${project_root}/package.json" > "${workspace_manifests}"

  if ! jq -r '
    if (.workspaces | type) == "array" then .workspaces[]
    elif (.workspaces | type) == "object" then .workspaces.packages[]?
    else empty
    end
  ' "${project_root}/package.json" > "${workspace_patterns}"; then
    rm -f "${input_list}" "${workspace_patterns}" "${workspace_manifests}"
    return 1
  fi

  shopt -q nullglob && nullglob_was_enabled=1
  shopt -s nullglob
  while IFS= read -r workspace_pattern; do
    [[ -n "${workspace_pattern}" ]] || continue
    if [[ "${workspace_pattern}" == *$'\n'* || "${workspace_pattern}" == *$'\r'* || \
          "${workspace_pattern}" == *[[:space:]]* || "${workspace_pattern}" == /* || \
          "${workspace_pattern}" == *..* || "${workspace_pattern}" == *'**'* || \
          "${workspace_pattern}" == '!'* ]]; then
      printf 'safedeps npm closure: unsupported Yarn workspace pattern: %s\n' "${workspace_pattern}" >&2
      workspace_error=1
      break
    fi
    for workspace_dir in "${project_root}"/${workspace_pattern}; do
      [[ -d "${workspace_dir}" && -f "${workspace_dir}/package.json" ]] || continue
      workspace_root=$(cd "${workspace_dir}" 2>/dev/null && pwd -P) || {
        workspace_error=1
        break
      }
      if [[ "${workspace_root}" != "${project_root}"/* ]]; then
        printf 'safedeps npm closure: Yarn workspace escapes project root: %s\n' "${workspace_pattern}" >&2
        workspace_error=1
        break
      fi
      printf '%s\n' "${workspace_root}/package.json" >> "${workspace_manifests}"
    done
    [[ "${workspace_error}" -eq 0 ]] || break
  done < "${workspace_patterns}"
  [[ "${nullglob_was_enabled}" -eq 1 ]] || shopt -u nullglob

  if [[ "${workspace_error}" -ne 0 ]]; then
    rm -f "${input_list}" "${workspace_patterns}" "${workspace_manifests}"
    return 1
  fi

  while IFS= read -r source_file; do
    [[ -f "${source_file}" ]] || continue
    relative_path="${source_file#${project_root}/}"
    if [[ "${relative_path}" == "${source_file}" || -z "${relative_path}" || \
          "${relative_path}" == *$'\n'* || "${relative_path}" == *$'\r'* || \
          "${relative_path}" == *$'\t'* ]]; then
      printf 'safedeps npm closure: unsafe Yarn project input path\n' >&2
      rm -f "${input_list}" "${workspace_patterns}" "${workspace_manifests}"
      return 1
    fi
    source_sha=$(safedeps_npm_sha256_file "${source_file}") || {
      rm -f "${input_list}" "${workspace_patterns}" "${workspace_manifests}"
      return 1
    }
    printf '%s\tsha256:%s\n' "${relative_path}" "${source_sha}" >> "${input_list}"
  done < <(
    {
      cat "${workspace_manifests}"
      [[ -f "${project_root}/yarn.lock" ]] && printf '%s\n' "${project_root}/yarn.lock"
      [[ -f "${project_root}/.yarnrc.yml" ]] && printf '%s\n' "${project_root}/.yarnrc.yml"
      for source_file in "${project_root}/.yarn/releases" "${project_root}/.yarn/plugins" "${project_root}/.yarn/patches"; do
        [[ -d "${source_file}" ]] && find "${source_file}" -type f -print
      done
    } | LC_ALL=C sort -u
  )

  [[ -s "${input_list}" ]] || {
    printf 'safedeps npm closure: Yarn materialization has no canonical inputs\n' >&2
    rm -f "${input_list}" "${workspace_patterns}" "${workspace_manifests}"
    return 1
  }
  input_json=$(jq -Rsc '
    split("\n")
    | map(select(length > 0) | split("\t") | {path: .[0], sha256: .[1]})
  ' "${input_list}") || {
    rm -f "${input_list}" "${workspace_patterns}" "${workspace_manifests}"
    return 1
  }
  input_sha=$(safedeps_npm_sha256_file "${input_list}") || {
    rm -f "${input_list}" "${workspace_patterns}" "${workspace_manifests}"
    return 1
  }
  jq -cn \
    --arg input_sha256 "sha256:${input_sha}" \
    --argjson input_files "${input_json}" \
    '{input_sha256: $input_sha256, input_files: $input_files}' > "${output_file}"
  rm -f "${input_list}" "${workspace_patterns}" "${workspace_manifests}"
}

# Copy the canonical materialization inputs into a new, private mirror. The
# caller's tree is read-only throughout this operation. The root manifest is
# changed only after the copy has completed, and only inside the mirror.
safedeps_npm_yarn_copy_materialization_inputs() {
  local project_root="$1"
  local mirror_root="$2"
  local inputs_file="$3"
  local relative_path
  local source_file
  local destination_file

  while IFS= read -r relative_path; do
    [[ -n "${relative_path}" ]] || continue
    source_file="${project_root}/${relative_path}"
    destination_file="${mirror_root}/${relative_path}"
    [[ -f "${source_file}" ]] || {
      printf 'safedeps npm closure: canonical input disappeared: %s\n' "${relative_path}" >&2
      return 1
    }
    mkdir -p "$(dirname "${destination_file}")" || return 1
    cp -p "${source_file}" "${destination_file}" || return 1
  done < <(jq -r '.input_files[]?.path' "${inputs_file}")
}

# Construct an isolated candidate lockfile. This calls Yarn exactly once for
# the materialization and then queries the graph from that generated lockfile.
# A source-input recheck before and after Yarn closes the read/copy race: a
# concurrent manifest, config, resolution, or lockfile change invalidates the
# candidate instead of producing an approval for a mixed project state.
safedeps_npm_yarn_materialize_candidate_closure() {
  local package_name="$1"
  local version="$2"
  local project_context_file="$3"
  local source_file="$4"
  local project_root
  local expected_context_hash
  local expected_input_sha
  local mirror_root
  local mirror_manifest
  local mirror_manifest_tmp
  local generated_lockfile
  local generated_lockfile_sha
  local verify_context_file
  local mirror_inputs_file
  local closure_file
  local verify_context_hash
  local verify_input_sha

  project_root=$(jq -r '.project_root' "${project_context_file}") || return 1
  expected_context_hash=$(jq -r '.context_hash' "${project_context_file}") || return 1
  expected_input_sha=$(jq -r '.input_sha256' "${project_context_file}") || return 1
  [[ -d "${project_root}" && -n "${expected_context_hash}" && -n "${expected_input_sha}" ]] || return 1

  mirror_root=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-yarn-candidate.XXXXXX") || return 1
  verify_context_file=$(mktemp "${TMPDIR:-/tmp}/safedeps-yarn-context-verify.XXXXXX") || {
    rm -rf "${mirror_root}"
    return 1
  }
  mirror_inputs_file=$(mktemp "${TMPDIR:-/tmp}/safedeps-yarn-mirror-inputs.XXXXXX") || {
    rm -rf "${mirror_root}"
    rm -f "${verify_context_file}"
    return 1
  }
  closure_file=$(mktemp "${TMPDIR:-/tmp}/safedeps-yarn-candidate-closure.XXXXXX") || {
    rm -rf "${mirror_root}"
    rm -f "${verify_context_file}" "${mirror_inputs_file}"
    return 1
  }

  if ! safedeps_npm_yarn_copy_materialization_inputs "${project_root}" "${mirror_root}" "${project_context_file}"; then
    rm -rf "${mirror_root}"
    rm -f "${verify_context_file}" "${mirror_inputs_file}" "${closure_file}"
    return 1
  fi

  if ! safedeps_npm_yarn_materialization_inputs "${mirror_root}" "${mirror_inputs_file}" || \
      ! verify_input_sha=$(jq -r '.input_sha256' "${mirror_inputs_file}") || \
      [[ "${verify_input_sha}" != "${expected_input_sha}" ]]; then
    printf 'safedeps npm closure: isolated Yarn mirror does not match canonical inputs\n' >&2
    rm -rf "${mirror_root}"
    rm -f "${verify_context_file}" "${mirror_inputs_file}" "${closure_file}"
    return 1
  fi

  if ! safedeps_npm_yarn_project_context "${verify_context_file}" "${project_root}" || \
      ! verify_context_hash=$(jq -r '.context_hash' "${verify_context_file}") || \
      ! verify_input_sha=$(jq -r '.input_sha256' "${verify_context_file}") || \
      [[ "${verify_context_hash}" != "${expected_context_hash}" || "${verify_input_sha}" != "${expected_input_sha}" ]]; then
    printf 'safedeps npm closure: Yarn project inputs changed while candidate mirror was prepared\n' >&2
    rm -rf "${mirror_root}"
    rm -f "${verify_context_file}" "${mirror_inputs_file}" "${closure_file}"
    return 1
  fi

  mirror_manifest="${mirror_root}/package.json"
  mirror_manifest_tmp=$(mktemp "${mirror_root}/.safedeps-package.XXXXXX") || {
    rm -rf "${mirror_root}"
    rm -f "${verify_context_file}" "${mirror_inputs_file}" "${closure_file}"
    return 1
  }
  if ! jq --arg package "${package_name}" --arg version "${version}" '
    .dependencies = (.dependencies // {})
    | .dependencies[$package] = $version
  ' "${mirror_manifest}" > "${mirror_manifest_tmp}"; then
    rm -f "${mirror_manifest_tmp}"
    rm -rf "${mirror_root}"
    rm -f "${verify_context_file}" "${mirror_inputs_file}" "${closure_file}"
    return 1
  fi
  mv -f "${mirror_manifest_tmp}" "${mirror_manifest}"

  if ! (
    cd "${mirror_root}" &&
      YARN_CACHE_FOLDER="${mirror_root}/.safedeps-yarn-cache" \
      YARN_ENABLE_GLOBAL_CACHE=false \
      yarn install --mode=update-lockfile --no-immutable >/dev/null
  ); then
    printf 'safedeps npm closure: isolated Yarn candidate materialization failed for %s@%s\n' "${package_name}" "${version}" >&2
    rm -rf "${mirror_root}"
    rm -f "${verify_context_file}" "${mirror_inputs_file}" "${closure_file}"
    return 1
  fi

  generated_lockfile="${mirror_root}/yarn.lock"
  if [[ ! -f "${generated_lockfile}" ]] || ! generated_lockfile_sha=$(safedeps_npm_sha256_file "${generated_lockfile}"); then
    printf 'safedeps npm closure: isolated Yarn candidate lockfile is unavailable\n' >&2
    rm -rf "${mirror_root}"
    rm -f "${verify_context_file}" "${mirror_inputs_file}" "${closure_file}"
    return 1
  fi

  if ! safedeps_npm_yarn_project_context "${verify_context_file}" "${project_root}" || \
      ! verify_context_hash=$(jq -r '.context_hash' "${verify_context_file}") || \
      ! verify_input_sha=$(jq -r '.input_sha256' "${verify_context_file}") || \
      [[ "${verify_context_hash}" != "${expected_context_hash}" || "${verify_input_sha}" != "${expected_input_sha}" ]]; then
    printf 'safedeps npm closure: Yarn project inputs changed during candidate materialization\n' >&2
    rm -rf "${mirror_root}"
    rm -f "${verify_context_file}" "${mirror_inputs_file}" "${closure_file}"
    return 1
  fi

  if ! safedeps_npm_yarn_project_closure "${package_name}" "${version}" "${mirror_root}" > "${closure_file}"; then
    printf 'safedeps npm closure: generated Yarn candidate lockfile does not resolve %s@%s\n' "${package_name}" "${version}" >&2
    rm -rf "${mirror_root}"
    rm -f "${verify_context_file}" "${mirror_inputs_file}" "${closure_file}"
    return 1
  fi

  jq -c \
    --arg type "yarn-project-materialized-lockfile" \
    --arg candidate "${package_name}@npm:${version}" \
    --arg generated_lockfile_sha256 "sha256:${generated_lockfile_sha}" \
    '
      . + {
        type: $type,
        materialization: {
          candidate: $candidate,
          input_sha256: .input_sha256,
          generated_lockfile_sha256: $generated_lockfile_sha256,
          command: "yarn install --mode=update-lockfile --no-immutable",
          isolation: "private-project-mirror"
        }
      }
    ' "${project_context_file}" > "${source_file}" || {
      rm -rf "${mirror_root}"
      rm -f "${verify_context_file}" "${mirror_inputs_file}" "${closure_file}"
      return 1
    }
  cat "${closure_file}"
  rm -rf "${mirror_root}"
  rm -f "${verify_context_file}" "${mirror_inputs_file}" "${closure_file}"
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
  local inputs_file input_sha input_files

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
        inputs_file=$(mktemp "${TMPDIR:-/tmp}/safedeps-yarn-context-inputs.XXXXXX") || return 2
        if ! safedeps_npm_yarn_materialization_inputs "${dir}" "${inputs_file}"; then
          rm -f "${inputs_file}"
          return 2
        fi
        resolutions_json=$(jq -cS '.resolutions' "${manifest}") || { rm -f "${inputs_file}"; return 2; }
        resolutions_sha=$(safedeps_npm_sha256_text "${resolutions_json}") || { rm -f "${inputs_file}"; return 2; }
        lockfile_sha=$(safedeps_npm_sha256_file "${lockfile}") || { rm -f "${inputs_file}"; return 2; }
        input_sha=$(jq -r '.input_sha256' "${inputs_file}") || { rm -f "${inputs_file}"; return 2; }
        input_files=$(jq -c '.input_files' "${inputs_file}") || { rm -f "${inputs_file}"; return 2; }
        context_hex=$(safedeps_npm_sha256_text "${dir}
${resolutions_sha}
${lockfile_sha}
${input_sha}") || { rm -f "${inputs_file}"; return 2; }
        jq -cn \
          --arg type "yarn-project-lockfile" \
          --arg context_hash "sha256:${context_hex}" \
          --arg project_root "${dir}" \
          --arg manifest_path "${manifest}" \
          --arg lockfile_path "${lockfile}" \
          --arg resolutions_sha256 "sha256:${resolutions_sha}" \
          --arg lockfile_sha256 "sha256:${lockfile_sha}" \
          --arg input_sha256 "${input_sha}" \
          --argjson input_files "${input_files}" \
          '{
            type: $type,
            context_hash: $context_hash,
            project_root: $project_root,
            manifest_path: $manifest_path,
            lockfile_path: $lockfile_path,
            resolutions_sha256: $resolutions_sha256,
            lockfile_sha256: $lockfile_sha256,
            input_sha256: $input_sha256,
            input_files: $input_files
          }' > "${output_file}"
        rm -f "${inputs_file}"
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

  if ! jq -s -e --arg root "${package_name}@npm:${version}" '
    [ .[] | select((.value | type) == "string") | .value ] | index($root) != null
  ' "${graph_file}" >/dev/null; then
    printf 'safedeps npm closure: requested locator absent from Yarn project: %s@npm:%s\n' "${package_name}" "${version}" >&2
    rm -f "${graph_file}"
    return 2
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
      visit([$root]; {}) as $seen
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

# Discover the consuming repo's npm `overrides` so the closure probe resolves
# transitive deps the way the real install will. Without this, safedeps probes
# the *published* closure (no overrides) and false-positives on a transitive the
# repo has already pinned to a patched version via `overrides`.
#
# Honoring overrides cannot hide a real vuln: the probe still resolves each
# override to a concrete version and OSV is queried for THAT version — exactly
# the version that will be installed. An override pointing at a still-vulnerable
# version is therefore flagged like any other.
#
# Source precedence:
#   1. SAFEDEPS_NPM_OVERRIDES_JSON env (explicit JSON; testing / non-cwd callers).
#   2. Nearest package.json walking up from SAFEDEPS_NPM_OVERRIDES_DIR (default
#      $PWD = the consuming repo) with a non-empty `.overrides`, bounded by the
#      git repo root.
#
# Only concrete version pins are honored: string values starting with `$`
# (direct-dep refs like "$react") and nested objects mentioning `$` are dropped,
# because they have no meaning in the standalone probe and would break the
# `npm install` resolution.
# An optional second argument names a file that receives where the overrides
# came from (`env`, or the manifest path). The approval context is keyed on that
# origin, so it has to come from the same walk that found them — a second,
# independent walk could disagree with the one that fed the probe.
safedeps_npm_repo_overrides_json() {
  local source_out="${1:-}"

  [[ -z "${source_out}" ]] || : > "${source_out}"
  if [[ -n "${SAFEDEPS_NPM_OVERRIDES_JSON:-}" ]]; then
    [[ -z "${source_out}" ]] || printf 'env' > "${source_out}"
    printf '%s' "${SAFEDEPS_NPM_OVERRIDES_JSON}"
    return 0
  fi
  command -v jq >/dev/null 2>&1 || { printf '{}'; return 0; }

  local filter='
    (.overrides // {})
    | if type == "object" then . else {} end
    | to_entries
    | map(select(
        ((.value | type) == "string" and (.value | startswith("$") | not))
        or
        ((.value | type) == "object" and ((.value | tostring | contains("$")) | not))
      ))
    | from_entries
  '

  local dir="${SAFEDEPS_NPM_OVERRIDES_DIR:-${PWD}}"
  while [[ -n "${dir}" && "${dir}" != "/" ]]; do
    local pkg="${dir}/package.json"
    if [[ -f "${pkg}" ]]; then
      local raw
      raw=$(jq -c 'if (.overrides | type) == "object" and (.overrides | length) > 0 then 1 else empty end' "${pkg}" 2>/dev/null) || raw=""
      if [[ -n "${raw}" ]]; then
        [[ -z "${source_out}" ]] || printf '%s' "${pkg}" > "${source_out}"
        jq -c "${filter}" "${pkg}" 2>/dev/null || printf '{}'
        return 0
      fi
    fi
    # Worktree roots use a `.git` file; normal clones use a `.git` directory.
    # Testing only for a directory walks straight past a worktree root and
    # picks up an ancestor's overrides, which are not the ones the real install
    # will use. Matches the Yarn project-context walk-up above.
    [[ -e "${dir}/.git" ]] && break
    dir=$(dirname "${dir}")
  done
  printf '{}'
}

# Honoring `overrides` makes the probe's closure a function of the consuming
# project, not of the published package alone. A published-closure approval is
# global because it is project-independent; an overridden one is not, so it must
# be keyed like the Yarn project closure is. Without this, an approval earned in
# a repo that pins a transitive to a patched version satisfies the same check in
# a repo that does not, whose real install resolves the vulnerable version.
#
# Writes the approval context and returns 0 when overrides apply. Returns 1 when
# there are none — then the closure is project-independent and the ordinary
# global approval is correct.
safedeps_npm_overrides_context() {
  local output_file="$1"
  local overrides_json="$2"
  local overrides_source="$3"
  local project_root
  local overrides_sha
  local context_hex

  [[ -n "${overrides_json}" && "${overrides_json}" != '{}' ]] || return 1
  [[ -n "${overrides_source}" ]] || return 1

  if [[ "${overrides_source}" == "env" ]]; then
    project_root="env"
  else
    project_root=$(cd "$(dirname "${overrides_source}")" 2>/dev/null && pwd -P) || return 1
  fi

  # Hash the canonical (sorted) override set, so key equality means the probe
  # resolves the same way, not merely that the manifest bytes matched.
  local canonical_overrides
  canonical_overrides=$(jq -cS '.' <<< "${overrides_json}" 2>/dev/null) || return 1
  [[ -n "${canonical_overrides}" ]] || return 1
  overrides_sha=$(safedeps_npm_sha256_text "${canonical_overrides}") || return 1
  context_hex=$(safedeps_npm_sha256_text "${project_root}
${overrides_sha}") || return 1

  jq -cn \
    --arg context_hash "sha256:${context_hex}" \
    --arg project_root "${project_root}" \
    --arg overrides_source "${overrides_source}" \
    --arg overrides_sha256 "sha256:${overrides_sha}" \
    --argjson overrides "${overrides_json}" \
    '{
      context_hash: $context_hash,
      project_root: $project_root,
      overrides_source: $overrides_source,
      overrides_sha256: $overrides_sha256,
      overrides: $overrides
    }' > "${output_file}"
}

safedeps_npm_resolve_spec_closure() {
  local package_name="$1"
  local version="$2"
  local source_file="${3:-}"
  local tmp_dir
  local lockfile
  local project_context_file
  local project_context_status=1
  local project_closure_status=1
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
    else
      project_closure_status=$?
    fi
    if [[ "${project_closure_status}" -eq 2 ]] && safedeps_npm_yarn_materialize_candidate_closure "${package_name}" "${version}" "${project_context_file}" "${source_file}"; then
      rm -f "${project_context_file}"
      return 0
    fi
    if [[ -n "${source_file}" ]]; then
      if [[ "${project_closure_status}" -eq 2 ]]; then
        safedeps_npm_write_source "${source_file}" "yarn-project-candidate-materialization" "${project_context_file}" "project-candidate-materialization-unavailable"
      else
        safedeps_npm_write_source "${source_file}" "yarn-project-lockfile" "${project_context_file}" "project-closure-unavailable"
      fi
    fi
    printf 'safedeps npm closure: Yarn project candidate is not verifiable; published closure is not used\n' >&2
    rm -f "${project_context_file}"
    return 1
  else
    project_context_status=$?
  fi

  if ! command -v npm >/dev/null 2>&1; then
    printf 'safedeps npm closure: npm CLI is required\n' >&2
    rm -f "${project_context_file}"
    return 1
  fi

  tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-npm-closure.XXXXXX") || return 1

  local overrides_json
  local overrides_source_file
  local overrides_source=""
  overrides_source_file=$(mktemp "${TMPDIR:-/tmp}/safedeps-npm-overrides-src.XXXXXX") || return 1
  overrides_json=$(safedeps_npm_repo_overrides_json "${overrides_source_file}")
  [[ -n "${overrides_json}" ]] || overrides_json='{}'
  overrides_source=$(cat "${overrides_source_file}" 2>/dev/null)
  rm -f "${overrides_source_file}"
  if ! jq -n --argjson overrides "${overrides_json}" \
    '{name:"safedeps-closure-probe",version:"0.0.0",private:true}
     + (if ($overrides | length) > 0 then {overrides: $overrides} else {} end)' \
    > "${tmp_dir}/package.json" 2>/dev/null; then
    # Dropping the overrides only makes the probe stricter, but a silent drop
    # would surface as an unexplained denial. Every bypass stays observable.
    printf 'safedeps npm closure: could not apply repo overrides to the probe manifest; continuing without them (the check stays fail-closed)\n' >&2
    printf '{"name":"safedeps-closure-probe","version":"0.0.0","private":true}\n' > "${tmp_dir}/package.json"
    overrides_json='{}'
    overrides_source=""
  fi
  if [[ "${overrides_json}" != '{}' ]]; then
    printf 'safedeps npm closure: applied %s repo override(s) to closure probe\n' \
      "$(jq 'length' <<<"${overrides_json}" 2>/dev/null || printf '?')" >&2
  fi
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
  local overrides_context_file=""
  if [[ -n "${source_file}" ]]; then
    if [[ "${project_context_status}" -eq 0 ]]; then
      safedeps_npm_write_source "${source_file}" "npm-package-probe" "${project_context_file}" "project-closure-unavailable"
    elif [[ "${project_context_status}" -eq 2 ]]; then
      safedeps_npm_write_source "${source_file}" "npm-package-probe" "" "project-context-invalid"
    else
      overrides_context_file=$(mktemp "${TMPDIR:-/tmp}/safedeps-npm-overrides-ctx.XXXXXX") || overrides_context_file=""
      if [[ -n "${overrides_context_file}" ]] && \
          safedeps_npm_overrides_context "${overrides_context_file}" "${overrides_json}" "${overrides_source}"; then
        safedeps_npm_write_source "${source_file}" "npm-overrides-probe" "${overrides_context_file}"
      else
        safedeps_npm_write_source "${source_file}" "npm-package-probe"
      fi
      rm -f "${overrides_context_file}"
    fi
  fi
  rm -rf "${tmp_dir}"
  rm -f "${project_context_file}"
  return "${status}"
}
