#!/usr/bin/env bash
# safedeps: what it costs to ask npm instead of reimplementing it.
#
# Two answers come from npm itself on the hook path. The pre-guard asks
# `npm prefix` where an npm install lands, and the post-verify hook asks
# `npm query '*'` which packages `npm rebuild` would run over. Each starts node
# once, so the cost is a property of the machine and of the tree, not of the
# command text. This prints both, per size, so a claim about the hook budget
# can quote a measured number from the machine it was made on.
#
# Usage:
#   scripts/measure/npm-ask-cost.sh [--runs R] [--query-only] [N...]
#
# N is the size of the synthetic tree: N packages in node_modules (a tenth of
# them with a nested package of their own) for `npm query`, and N workspace
# members for `npm prefix`, asked from the last member. Default 100 1000 5000.
#
# The last column is the whole PreToolUse hook judging `npm install x` from
# that member: the command scan, the two npm asks, the snapshot. It is the
# number to hold against the hook's budgets. A command under the engage size
# (1KB) is judged inline with no deadline of its own, so this is what the
# runtime's 30s has to cover; a larger one runs under the self budget (20s by
# default). The asks alone stop at 8s (lib/npm/ask.sh).
# R runs per cell, the slowest and the median printed. --query-only skips the
# workspace columns. The pre-guard snapshots every member's package.json, in
# one copy and one hash whatever the member count
# (scripts/test/workspace-snapshot-count.sh counts the processes); what still
# grows with members is reading them, and npm's own walk. The tree is written by
# hand: no install, no registry, no network.
#
# The query is timed twice. npm trusts node_modules/.package-lock.json when it
# is newer than every package folder, and reads each package.json when it is
# not, so `hidden` and `walk` bracket the two ways npm loads the same tree.
#
# Load matters more than size at small N: record `uptime` beside any number
# taken from here, and say which machine it came from.

set -uo pipefail

RUNS=3
QUERY_ONLY=false
SIZES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --runs) RUNS="${2:-3}"; shift 2 ;;
    --query-only) QUERY_ONLY=true; shift ;;
    *) SIZES+=("$1"); shift ;;
  esac
done
[[ ${#SIZES[@]} -gt 0 ]] || SIZES=(100 1000 5000)

command -v npm >/dev/null 2>&1 || { printf 'npm is required\n' >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { printf 'jq is required\n' >&2; exit 2; }

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-npm-ask.XXXXXX")
T=$(cd "${T}" && pwd -P)
trap 'rm -rf "${T}"' EXIT

# npm sees only this sandbox, and never reaches a network.
while IFS= read -r inherited; do
  unset "${inherited}"
done < <(env | awk -F= 'tolower($1) ~ /^npm_config_/ { print $1 }')
export HOME="${T}/home" npm_config_userconfig="${T}/npmrc" npm_config_globalconfig="${T}/gnpmrc" \
  npm_config_cache="${T}/cache" npm_config_offline=true npm_config_update_notifier=false \
  npm_config_logs_max=0
mkdir -p "${HOME}"
export SAFEDEPS_OSV_API_URL=http://127.0.0.1:9/v1/query SAFEDEPS_OSV_BATCH_API_URL=http://127.0.0.1:9/v1/querybatch \
  SAFEDEPS_KEV_CATALOG_URL=http://127.0.0.1:9/kev.json SAFEDEPS_GHSA_API_URL=http://127.0.0.1:9/advisories
: > "${npm_config_userconfig}"
: > "${npm_config_globalconfig}"

now_ms() { node -e 'process.stdout.write(String(Date.now()))'; }

# `<slowest> <median>` of R runs of the command, in milliseconds.
time_runs() {
  local i start end
  local -a samples=()
  for (( i = 0; i < RUNS; i++ )); do
    start=$(now_ms)
    "$@" >/dev/null 2>&1
    end=$(now_ms)
    samples+=($(( end - start )))
  done
  printf '%s\n' "${samples[@]}" | sort -n | awk '{ a[NR] = $1 } END { printf "%d %d", a[NR], a[int((NR + 1) / 2)] }'
}

make_tree() {
  local n="$1" dir="$2" i
  mkdir -p "${dir}/node_modules"
  node - "${n}" "${dir}" <<'EOF'
const fs = require('fs');
const [n, dir] = [Number(process.argv[2]), process.argv[3]];
const packages = { '': { name: 'proj', version: '1.0.0', dependencies: {} } };
for (let i = 0; i < n; i++) {
  const name = `p${i}`;
  const key = `node_modules/${name}`;
  fs.mkdirSync(`${dir}/${key}`, { recursive: true });
  fs.writeFileSync(`${dir}/${key}/package.json`, JSON.stringify({ name, version: '1.0.0' }));
  packages[''].dependencies[name] = '1.0.0';
  packages[key] = { version: '1.0.0' };
  if (i % 10 === 0) {
    const nested = `${key}/node_modules/q${i}`;
    fs.mkdirSync(`${dir}/${nested}`, { recursive: true });
    fs.writeFileSync(`${dir}/${nested}/package.json`, JSON.stringify({ name: `q${i}`, version: '2.0.0' }));
    packages[nested] = { version: '2.0.0' };
  }
}
fs.writeFileSync(`${dir}/package.json`, JSON.stringify({ name: 'proj', version: '1.0.0', dependencies: packages[''].dependencies }));
const lock = { name: 'proj', version: '1.0.0', lockfileVersion: 3, requires: true, packages };
fs.writeFileSync(`${dir}/package-lock.json`, JSON.stringify(lock));
fs.writeFileSync(`${dir}/node_modules/.package-lock.json`, JSON.stringify(lock));
EOF
}

# The PreToolUse hook judging `npm install sd-victim` in <dir>, nothing installed.
pre_hook() {
  local dir="$1" home
  home=$(mktemp -d "${T}/safe.XXXXXX")
  jq -nc --arg d "${dir}" '{tool_name:"Bash",tool_input:{command:"npm install sd-victim"},cwd:$d}' \
    | SAFEDEPS_HOME="${home}" "${REPO_DIR}/scripts/safedeps-hook-entry.sh" pre >/dev/null 2>&1
  rm -rf "${home}"
}

make_workspace() {
  local n="$1" dir="$2"
  node - "${n}" "${dir}" <<'EOF'
const fs = require('fs');
const [n, dir] = [Number(process.argv[2]), process.argv[3]];
fs.mkdirSync(dir, { recursive: true });
fs.writeFileSync(`${dir}/package.json`, JSON.stringify({ name: 'root', private: true, workspaces: ['packages/*'] }));
for (let i = 0; i < n; i++) {
  fs.mkdirSync(`${dir}/packages/m${i}`, { recursive: true });
  fs.writeFileSync(`${dir}/packages/m${i}/package.json`, JSON.stringify({ name: `m${i}`, version: '1.0.0' }));
}
EOF
}

printf '# npm %s, node %s, %s\n' "$(npm --version)" "$(node --version)" "$(uname -sm)"
printf '# uptime: %s\n' "$(uptime)"
printf '# runs per cell: %s, times in ms as slowest/median\n' "${RUNS}"
printf '%-7s %-9s %-14s %-14s %-14s %-14s\n' N nodes 'query hidden' 'query walk' 'prefix member' 'pre-guard hook'
for n in "${SIZES[@]}"; do
  tree="${T}/tree-${n}"
  make_tree "${n}" "${tree}"
  nodes=$(cd "${tree}" && npm query '*' 2>/dev/null | jq 'length')
  # Newer than every folder: npm reads the hidden lockfile.
  touch "${tree}/node_modules/.package-lock.json"
  hidden=$(cd "${tree}" && time_runs npm query '*')
  # Older than the folders: npm reads every package.json.
  touch -t 200001010000 "${tree}/node_modules/.package-lock.json"
  walk=$(cd "${tree}" && time_runs npm query '*')
  ws="${T}/ws-${n}"
  member=- hook=-
  if [[ "${QUERY_ONLY}" == false ]]; then
    make_workspace "${n}" "${ws}"
    member=$(cd "${ws}/packages/m$(( n - 1 ))" && time_runs npm prefix)
    hook=$(time_runs pre_hook "${ws}/packages/m$(( n - 1 ))")
  fi
  printf '%-7s %-9s %-14s %-14s %-14s %-14s\n' "${n}" "${nodes}" "${hidden/ //}" "${walk/ //}" "${member/ //}" "${hook/ //}"
  rm -rf "${tree}" "${ws}"
done
printf '# uptime: %s\n' "$(uptime)"
