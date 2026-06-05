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

safedeps_npm_resolve_spec_closure() {
  local package_name="$1"
  local version="$2"
  local tmp_dir
  local lockfile

  safedeps_npm_require_jq || return 1

  if safedeps_npm_fixture_closure "${package_name}" "${version}"; then
    return 0
  fi

  if ! command -v npm >/dev/null 2>&1; then
    printf 'safedeps npm closure: npm CLI is required\n' >&2
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
  rm -rf "${tmp_dir}"
  return "${status}"
}
