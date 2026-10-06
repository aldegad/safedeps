#!/usr/bin/env bash
# safedeps: does the core binary survive the package?
#
# Packs a copy of this tree with a core binary at
# bin/native/<os>-<arch>/safedeps-core, installs the tarball into a project,
# and runs the installed binary. It answers four things the distribution plan
# rests on (ARCHITECTURE.md, "How it will ship"):
#
#   - the package still has no dependency of any kind;
#   - `npm pack` carries the binary without a change to `files` (bin/ is
#     listed), and carries nothing of rust/;
#   - the installed binary keeps its exec bit and runs on this platform;
#   - it gives the answer the binary it was copied from gives.
#
# This runs npm, so it keeps the conditions AGENTS.md sets for a battery that
# does (scripts/test/lib/npm-sandbox.sh has the long form): the one package is
# this tree, packed here and installed from the tarball; npm's registry and
# proxies point at a closed local port and npm is offline, so nothing can be
# fetched; every inherited npm_config_* is unset; and npm's home, configs,
# cache and prefix are in the sandbox, which `npm config get` confirms before
# the install.
#
# Usage: scripts/measure/core-pack-probe.sh <safedeps-core>
set -uo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CORE="${1:?usage: core-pack-probe.sh <safedeps-core>}"
CORE=$(cd "$(dirname "${CORE}")" && pwd)/$(basename "${CORE}")
fail() { printf 'not ok - %s\n' "$*"; exit 1; }
pass() { printf 'ok - %s\n' "$*"; }
for tool in npm node jq tar; do
  command -v "${tool}" >/dev/null 2>&1 || fail "${tool} is required"
done

# The platform's directory, read the way the entry shim will read it: from
# bash's own variables, with no process started.
case "${OSTYPE:-}" in darwin*) os=darwin ;; linux*) os=linux ;; *) fail "no binary directory for OSTYPE=${OSTYPE:-}" ;; esac
case "${HOSTTYPE:-}" in arm64|aarch64) arch=arm64 ;; x86_64) arch=x64 ;; *) fail "no binary directory for HOSTTYPE=${HOSTTYPE:-}" ;; esac
native="bin/native/${os}-${arch}/safedeps-core"

work=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-core-pack.XXXXXX")
work=$(cd "${work}" && pwd)
trap 'rm -rf "${work}"' EXIT
printf 'start: %s\n' "$(uptime)"

mkdir -p "${work}/stage" "${work}/home" "${work}/prefix" "${work}/cache" "${work}/app" "${work}/out"
( cd "${ROOT_DIR}" && COPYFILE_DISABLE=1 tar --exclude=./rust/target --exclude=./.git --exclude=./safedeps-core -cf - . ) | tar -C "${work}/stage" -xf - 2>/dev/null \
  || fail "could not copy the tree"
mkdir -p "${work}/stage/$(dirname "${native}")"
if ! cp "${CORE}" "${work}/stage/${native}" || ! chmod 755 "${work}/stage/${native}"; then
  fail "could not place the binary"
fi

while IFS= read -r name; do unset "${name}"; done < <(env | sed -n 's/^\(npm_config_[A-Za-z0-9_]*\)=.*/\1/p; s/^\(NPM_CONFIG_[A-Za-z0-9_]*\)=.*/\1/p')
: > "${work}/npmrc"; : > "${work}/globalrc"
export HOME="${work}/home"
export npm_config_userconfig="${work}/npmrc" npm_config_globalconfig="${work}/globalrc"
export npm_config_cache="${work}/cache" npm_config_prefix="${work}/prefix"
export npm_config_registry="http://127.0.0.1:9/" npm_config_proxy="http://127.0.0.1:9" npm_config_https_proxy="http://127.0.0.1:9"
export npm_config_offline=true npm_config_audit=false npm_config_fund=false npm_config_update_notifier=false
[[ "$(npm config get prefix 2>/dev/null)" == "${work}/prefix" ]] || fail "npm's prefix is not in the sandbox: $(npm config get prefix 2>&1)"
[[ "$(npm config get cache 2>/dev/null)" == "${work}/cache" ]] || fail "npm's cache is not in the sandbox"
pass "npm $(npm --version) reads its prefix and cache inside the sandbox, offline, registry on a closed port"

deps=$(jq '((.dependencies // {}) + (.optionalDependencies // {}) + (.peerDependencies // {}) | length)' "${work}/stage/package.json")
[[ "${deps}" == 0 ]] || fail "the package names ${deps} dependencies"
pass "the package names no dependency (dependencies, optionalDependencies, peerDependencies: 0)"

packed=$(cd "${work}/stage" && npm pack --json --pack-destination "${work}/out" 2>"${work}/pack.err") || fail "npm pack failed: $(tail -n 3 "${work}/pack.err")"
tarball="${work}/out/$(jq -r '.[0].filename' <<< "${packed}" | tr '/' '-' | sed 's/^@//')"
[[ -f "${tarball}" ]] || tarball=$(find "${work}/out" -name '*.tgz' | head -n 1)
[[ -f "${tarball}" ]] || fail "npm pack left no tarball"
jq -e --arg p "${native}" '.[0].files | map(.path) | index($p)' <<< "${packed}" >/dev/null || fail "the tarball does not carry ${native}"
if jq -e '.[0].files | map(.path) | map(select(startswith("rust/"))) | length > 0' <<< "${packed}" >/dev/null; then
  fail "the tarball carries rust/ sources"
fi
pass "npm pack carries ${native} with files unchanged, and nothing of rust/ ($(jq -r '.[0].entryCount' <<< "${packed}") entries, $(jq -r '.[0].size' <<< "${packed}") bytes packed, binary $(wc -c < "${CORE}" | tr -d ' ') bytes)"

printf '{"name":"core-pack-probe-app","version":"0.0.0","private":true}\n' > "${work}/app/package.json"
( cd "${work}/app" && npm install --ignore-scripts --no-audit --no-fund --offline "${tarball}" >"${work}/install.out" 2>"${work}/install.err" ) \
  || fail "npm install of the tarball failed: $(tail -n 5 "${work}/install.err")"
installed="${work}/app/node_modules/@aldegad/safedeps/${native}"
[[ -f "${installed}" ]] || fail "the installed package has no ${native}"
[[ -x "${installed}" ]] || fail "the installed binary lost its exec bit"
ver=$("${installed}" version 2>&1) || fail "the installed binary does not run: ${ver}"
pass "the installed binary keeps its exec bit and runs (${ver})"

n=0
while IFS= read -r cmd; do
  payload=$(jq -nc --arg c "${cmd}" --arg cwd "${work}/app" '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}')
  a=$(printf '%s' "${payload}" | "${CORE}" facts | cksum) || fail "the source binary failed on a payload"
  b=$(printf '%s' "${payload}" | "${installed}" facts | cksum) || fail "the installed binary failed on a payload"
  [[ "${a}" == "${b}" ]] || fail "the installed binary answers differently on command $((n + 1))"
  n=$((n + 1))
done < <(jq -r '.[].command | select(test("\n") | not)' "${ROOT_DIR}/scripts/measure/tuple-corpus.json" | head -n 60)
(( n >= 50 )) || fail "only ${n} payloads were compared"
cmp -s "${CORE}" "${installed}" || fail "the installed binary is not byte for byte the one packed"
pass "the installed binary is byte for byte the one packed, and answers ${n} payloads as it does"
printf 'end: %s\n' "$(uptime)"
