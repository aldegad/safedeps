#!/usr/bin/env bash
# safedeps: `safedeps check` on a package whose optional peers lead back to it,
# through a real npm.
#
# npm before 11.6.0 ends `npm install vitest@4.1.11 --package-lock-only` with
# `Cannot read properties of null (reading 'edgesOut')` (Arborist #loadPeerSet),
# with or without overrides, so the check's closure probe could not resolve it.
# The probe now resolves once more with the package pinned to its own version
# and judges that lockfile only when npm, reading it without the pin, changes
# nothing (lib/npm/closure.sh, safedeps_npm_probe_self_pinned).
#
# This builds the same shape from synthetic packages, so it does not depend on
# what the public registry's `latest` is:
#
#   sdc-t@1.0.0  depends on sdc-v; optional peers sdc-b@1.0.0, sdc-z
#   sdc-t@2.0.0  (latest) optional peers sdc-b@2.0.0, sdc-z
#   sdc-v        optional peer sdc-d; sdc-d optional peer sdc-dv;
#   sdc-dv       optional peer sdc-t@*
#   sdc-b@N      peer sdc-t@N
#
# and a second family, sdx, that is the same with one more dependency,
# sdx-n@1.0.0, which depends on sdx-t@^2.0.0. A correct resolution nests
# sdx-t@2.0.0 under sdx-n; the pin bends that edge to 1.0.0 and leaves 2.0.0
# out, so the pinned lockfile must not be judged.
#
# Rows, on any npm:
#   - sdc-t@1.0.0 is judged clean, and its closure is sdc-t@1.0.0 and sdc-v@1.0.0.
#   - sdx-t@1.0.0 is never judged on a closure without sdx-t@2.0.0: it is
#     judged with it, or its resolution fails.
#   - every request went to the fixture registry, for these packages only.
# Each row also prints whether the probe pinned, which is what tells the npm
# apart: measured on 2026-10-14, npm 10.9.4 pins sdc-t and fails sdx-t, and
# npm 11.19.0 resolves both on the first run.
#
# usage: scripts/measure/npm-peer-cycle.sh [--npm-bin DIR]
#   --npm-bin DIR  put DIR first on PATH, to measure the npm (and node) in it.
#
# It runs npm, so it runs inside the npm sandbox (scripts/test/lib/npm-sandbox.sh)
# and holds the four conditions AGENTS.md names for that: synthetic packages
# only, a fixture registry on 127.0.0.1 with npm's proxies on a closed port,
# a check of the request log, and npm's own home, config, cache and prefix.

set -euo pipefail

while (( $# )); do
  case "$1" in
    --npm-bin) PATH="$2:${PATH}"; export PATH; shift 2 ;;
    *) printf 'usage: %s [--npm-bin DIR]\n' "$0" >&2; exit 2 ;;
  esac
done

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "${ROOT_DIR}"
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
NPM_SANDBOX_NAME="npm-peer-cycle"
NPM_SANDBOX_SCRIPT_RE='npm-peer-cycle\.sh'
# shellcheck source=../test/lib/npm-sandbox.sh
source "${ROOT_DIR}/scripts/test/lib/npm-sandbox.sh"

printf '# npm %s, node %s\n' "$(npm -v)" "$(node -v)"

# A synthetic package with no scripts: name, version, and the manifest fields
# to add, as a JSON object.
make_meta_package() {
  local name="$1" version="$2" fields="$3" src="${tmp_root}/src/$1-$2"
  mkdir -p "${src}"
  jq -n --arg name "${name}" --arg version "${version}" --argjson fields "${fields}" \
    '{name: $name, version: $version} + $fields' > "${src}/package.json"
  (cd "${src}" && npm pack --pack-destination "${tmp_root}/tarballs" >/dev/null 2>&1) \
    || fail "npm pack builds the synthetic package ${name}@${version}"
  cp "${src}/package.json" "${tmp_root}/tarballs/${name}-${version}.tgz.json"
}
optional() { jq -nc '[$ARGS.positional[] | {(.): {optional: true}}] | add' --args "$@"; }
# make_family PREFIX [DEPENDENCIES]: the shape above, with PREFIX for sdc.
make_family() {
  local p="$1" deps="${2:-}"
  [[ -n "${deps}" ]] || deps="{\"${p}-v\":\"^1.0.0\"}"
  make_meta_package "${p}-t" 1.0.0 "{\"dependencies\":${deps},\"peerDependencies\":{\"${p}-b\":\"1.0.0\",\"${p}-z\":\"*\"},\"peerDependenciesMeta\":$(optional "${p}-b" "${p}-z")}"
  make_meta_package "${p}-t" 2.0.0 "{\"peerDependencies\":{\"${p}-b\":\"2.0.0\",\"${p}-z\":\"*\"},\"peerDependenciesMeta\":$(optional "${p}-b" "${p}-z")}"
  make_meta_package "${p}-v" 1.0.0 "{\"peerDependencies\":{\"${p}-d\":\"^1.0.0\"},\"peerDependenciesMeta\":$(optional "${p}-d")}"
  make_meta_package "${p}-d" 1.0.0 "{\"peerDependencies\":{\"${p}-dv\":\"^1.0.0\"},\"peerDependenciesMeta\":$(optional "${p}-dv")}"
  make_meta_package "${p}-dv" 1.0.0 "{\"peerDependencies\":{\"${p}-t\":\"*\"},\"peerDependenciesMeta\":$(optional "${p}-t")}"
  make_meta_package "${p}-b" 1.0.0 "{\"peerDependencies\":{\"${p}-t\":\"1.0.0\"}}"
  make_meta_package "${p}-b" 2.0.0 "{\"peerDependencies\":{\"${p}-t\":\"2.0.0\"}}"
  make_meta_package "${p}-z" 1.0.0 '{}'
}
make_family sdc
make_family sdx '{"sdx-v":"^1.0.0","sdx-n":"1.0.0"}'
make_meta_package sdx-n 1.0.0 '{"dependencies":{"sdx-t":"^2.0.0"}}'

# check SPEC: runs `safedeps --json check npm SPEC` in a fresh repository and
# a fresh SAFEDEPS_HOME. Sets check_json, check_err and check_closure.
check() {
  local project
  project=$(mktemp -d "${tmp_root}/project.XXXXXX")
  git -C "${project}" init -q
  printf '{"name":"proj","version":"1.0.0","private":true}\n' > "${project}/package.json"
  check_err="${project}.stderr"
  check_json=$(cd "${project}" && SAFEDEPS_HOME="$(mktemp -d "${tmp_root}/home.XXXXXX")" \
    "${ROOT_DIR}/bin/safedeps" --json check npm "$1" 2>"${check_err}") || true
  check_closure=$(jq -r '(.resolved_closure // []) | map(.package + "@" + .version) | sort | join(" ")' <<< "${check_json}")
  printf '# %s: result=%s error=%s pinned=%s closure=[%s]\n' "$1" \
    "$(jq -r '.result' <<< "${check_json}")" "$(jq -r '.error // "-"' <<< "${check_json}")" \
    "$(grep -qF 'again with' "${check_err}" && printf yes || printf no)" "${check_closure}"
}

check sdc-t@1.0.0
[[ "$(jq -r '.result' <<< "${check_json}")" == "clean" && "${check_closure}" == "sdc-t@1.0.0 sdc-v@1.0.0" ]] \
  || fail "sdc-t@1.0.0 is judged on its closure ($(cat "${check_err}"))"
pass "sdc-t@1.0.0, whose optional peers lead back to it, is judged on sdc-t@1.0.0 and sdc-v@1.0.0"

check sdx-t@1.0.0
if [[ "$(jq -r '.approved' <<< "${check_json}")" == "true" ]]; then
  [[ " ${check_closure} " == *" sdx-t@2.0.0 "* ]] \
    || fail "sdx-t@1.0.0 is not approved on a closure without the sdx-t@2.0.0 that sdx-n needs (closure: ${check_closure})"
else
  [[ "$(jq -r '.error' <<< "${check_json}")" == "npm_closure_resolution_failed" ]] \
    || fail "sdx-t@1.0.0 is judged, or its resolution fails ($(cat "${check_err}"))"
fi
pass "sdx-t@1.0.0 is never judged on a closure without sdx-t@2.0.0"

[[ -s "${tmp_root}/registry.log" ]] || fail "the resolutions went through the fixture registry"
if grep -vE '^GET /sd[cx]-(t|v|d|dv|b|z|n)(/-/sd[cx]-(t|v|d|dv|b|z|n)-[12]\.0\.0\.tgz)?$' "${tmp_root}/registry.log" | grep . >/dev/null; then
  fail "the fixture registry saw only the synthetic packages ($(sort -u "${tmp_root}/registry.log" | paste -sd, -))"
fi
pass "every request went to the local fixture registry, for the synthetic packages only"
