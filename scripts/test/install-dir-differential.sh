#!/usr/bin/env bash
# safedeps: the directory the gate reads, against the directory npm names.
#
# The effect gate reads one directory per npm install, chosen by the pre-guard
# before the command runs. If that is not where npm installs, the gate reads a
# lockfile nobody wrote and confirms it clean. Twice a copy of npm's rules in
# bash chose differently from npm: a `cd` into a directory without a
# package.json, then a workspace member reached through a symlink (validator
# rounds 1 and 2 of safedeps/effect-gate-blind-to-lockless-npm-installs). The
# pre-guard now asks npm, and this battery holds it to npm's answer.
#
# For every layout below, the real pre-guard judges `npm install sd-victim`
# with the hook's cwd in that layout, and the directory it chose (the pending
# project_dir, or `?` when no statement named one and it fell back to the cwd)
# is compared with
# `npm prefix` run in the same place. Where npm itself refuses a layout (a
# `workspaces` value it rejects), the install would fail as well, and the gate
# not placing it is the same answer.
#
# The choice is where the effect gate looks, not whether the install was read:
# the PostToolUse hook records an install that left no trace there UNGATED. A
# wrong choice here is a record rather than a silent pass, and this battery
# keeps it from being a record npm could have avoided.
#
# The layouts are the validator's differential oracle from round 2
# (diff-prefix.sh, 237 layouts): ordinary workspaces, every glob spelling npm
# reads, dot directories, node_modules, nested and distant roots, symlinked
# members and symlinked pattern parents, and package.json files npm cannot
# read. A few command forms are added on top.
#
# No install runs. The pre-guard judges the command as a payload, and
# `npm prefix` only loads npm's configuration. npm sees a sandbox of its own,
# and the advisory providers point at a closed local port.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "${ROOT_DIR}"

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

for tool in npm node jq; do
  command -v "${tool}" >/dev/null 2>&1 || fail "${tool} is required for the install-directory differential"
done

T=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-install-dir.XXXXXX")
T=$(cd "${T}" && pwd -P)
trap 'rm -rf "${T}"' EXIT

while IFS= read -r inherited; do
  unset "${inherited}"
done < <(env | awk -F= 'tolower($1) ~ /^npm_config_/ { print $1 }')
export HOME="${T}/home"
mkdir -p "${HOME}"
export npm_config_userconfig="${T}/npmrc" npm_config_globalconfig="${T}/gnpmrc" npm_config_cache="${T}/cache" \
  npm_config_update_notifier=false npm_config_logs_max=0
printf 'prefix=%s\n' "${T}/global" > "${npm_config_userconfig}"
: > "${npm_config_globalconfig}"
[[ "$(npm config get prefix 2>/dev/null)" == "${T}/global" ]] || fail "npm's global prefix is the sandbox"
export SAFEDEPS_OSV_API_URL=http://127.0.0.1:9/v1/query SAFEDEPS_OSV_BATCH_API_URL=http://127.0.0.1:9/v1/querybatch \
  SAFEDEPS_KEV_CATALOG_URL=http://127.0.0.1:9/kev.json SAFEDEPS_GHSA_API_URL=http://127.0.0.1:9/advisories

# One check: <label> <cwd> <command>, and the directory npm names for it,
# computed by the caller. Writes `same|DIFF|UNDEC <label> ...` to <out>.
check_one() {
  local out="$1" label="$2" cwd="$3" command="$4" theirs="$5" home ours
  home=$(mktemp -d "${T}/safe.XXXXXX")
  jq -nc --arg c "${command}" --arg d "${cwd}" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}' \
    | SAFEDEPS_HOME="${home}" scripts/safedeps-hook-entry.sh pre >/dev/null 2>&1 || true
  if [[ "$(jq -r '.project_dir_from // empty' "${home}"/pending/*.json 2>/dev/null | head -n 1)" == cwd ]]; then
    ours="?"
  else
    ours=$(cat "${home}"/pending/*.json 2>/dev/null | jq -r '.project_dir // empty' | head -n 1)
    ours="${ours:-<none>}"
  fi
  if [[ "${ours}" == "${theirs}" ]]; then
    printf 'same  %s\n' "${label}" > "${out}"
  elif [[ "${ours}" == "?" && "${theirs}" == "<npm failed>" ]]; then
    # npm refuses the layout (a `workspaces` value it rejects), so the install
    # would fail too. The gate saying it cannot place it is the same answer.
    printf 'both  %s\n' "${label}" > "${out}"
  elif [[ "${ours}" == "?" ]]; then
    printf 'UNDEC %s npm=%s (%s)\n' "${label}" "${theirs#"${T}"/}" \
      "$(grep 'pre-guard:' "${home}/advisory.log" | grep -v 'truth source' | tail -n 1 | cut -f2)" > "${out}"
  else
    printf 'DIFF  %s ours=%s npm=%s\n' "${label}" "${ours#"${T}"/}" "${theirs#"${T}"/}" > "${out}"
  fi
  rm -rf "${home}"
}

# npm's own answer for <dir> with <flags>, as a physical path.
npm_names() {
  local dir="$1" theirs
  shift
  theirs=$(cd "${dir}" && npm prefix "$@" 2>/dev/null | tail -n 1) || theirs=""
  if [[ -d "${theirs}" ]]; then
    (cd "${theirs}" && pwd -P)
  else
    printf '%s' "${theirs:-<npm failed>}"
  fi
}

CHECKS="${T}/checks.tsv"
: > "${CHECKS}"
# <label> <root> <cwd relative to root> [npm flags...]: the hook's cwd is the
# directory itself, and the command is a plain install with the flags.
add() {
  local label="$1" root="$2" rel="$3"
  shift 3
  printf '%s\t%s\t%s\t%s\n' "${label}" "${root}/${rel}" "npm install sd-victim${*:+ $*}" \
    "$(npm_names "${root}/${rel}" "$@")" >> "${CHECKS}"
}
# <label> <root> <cd target relative to root>: the hook's cwd is the root, and
# the command enters the directory first.
add_cd() {
  local label="$1" root="$2" rel="$3"
  printf '%s\t%s\t%s\t%s\n' "${label}" "${root}" "cd ${rel} && npm install sd-victim" \
    "$(npm_names "${root}/${rel}")" >> "${CHECKS}"
}

n=0
mkws() {
  local r="${T}/$1" m
  mkdir -p "${r}/packages/a/src" "${r}/packages/b" "${r}/packages/.h" "${r}/packages/a/deep" "${r}/extra/c" \
    "${r}/packages/nopkg/src" "${r}/packages/node_modules/x"
  printf '{"name":"root","version":"1.0.0","private":true,"workspaces":%s}\n' "$2" > "${r}/package.json"
  for m in packages/a packages/b packages/.h packages/a/deep extra/c packages/node_modules/x; do
    printf '{"name":"%s","version":"1.0.0"}\n' "$(printf '%s' "${m}" | tr '/.' '__')" > "${r}/${m}/package.json"
  done
  printf '%s' "${r}"
}
for spec in \
  '["packages/*"]' '["./packages/*"]' '["/packages/*"]' '["packages/*/"]' '["packages/**"]' '["**"]' '["*"]' \
  '["packages/a"]' '["packages/a/"]' '["packages/[ab]"]' '["packages/?"]' '["packages/.*"]' '["packages/*","extra/*"]' \
  '{"packages":["packages/*"]}' '{"nohoist":["x"]}' '[]' '"packages/*"' '["packages/a","packages/a"]' \
  '["packages/*/deep"]' '["packages/**/deep"]' '["packages/*/"]' '["./packages/a/../b"]' '["packages//a"]' \
  '["packages/a/*"]' '["**/deep"]' '["packages/*","!packages/b"]' 'true' '{"packages":[]}'; do
  r=$(mkws "ws${n}" "${spec}")
  n=$((n + 1))
  for rel in packages/a packages/a/src packages/b packages/.h packages/a/deep extra/c packages/nopkg/src packages/node_modules/x; do
    add "${spec} @ ${rel}" "${r}" "${rel}"
  done
done
r=$(mkws nwf '["packages/*"]')
add 'no-workspaces @ packages/a' "${r}" packages/a --no-workspaces
mkdir -p "${T}/outer/inner/packages/a"
printf '{"name":"outer"}\n' > "${T}/outer/package.json"
printf '{"name":"inner","workspaces":["packages/*"]}\n' > "${T}/outer/inner/package.json"
printf '{"name":"ia"}\n' > "${T}/outer/inner/packages/a/package.json"
add 'outer>inner ws @ inner/packages/a' "${T}/outer" inner/packages/a
mkdir -p "${T}/far/mid/pk/a"
printf '{"name":"far","workspaces":["mid/pk/*"]}\n' > "${T}/far/package.json"
printf '{"name":"mid","workspaces":["other/*"]}\n' > "${T}/far/mid/package.json"
printf '{"name":"fa"}\n' > "${T}/far/mid/pk/a/package.json"
add 'far root includes, mid does not @ mid/pk/a' "${T}/far" mid/pk/a
mkdir -p "${T}/nmws/packages/q/node_modules"
printf '{"name":"r","workspaces":["packages/*"]}\n' > "${T}/nmws/package.json"
add 'member with node_modules but no package.json' "${T}/nmws" packages/q
mkdir -p "${T}/symws/real/a" "${T}/symws/packages"
printf '{"name":"r","workspaces":["packages/*"]}\n' > "${T}/symws/package.json"
printf '{"name":"sa"}\n' > "${T}/symws/real/a/package.json"
ln -s ../real/a "${T}/symws/packages/a"
add 'symlinked member via real path' "${T}/symws" real/a
add 'symlinked member via link path' "${T}/symws" packages/a
mkdir -p "${T}/symp/realpk/a"
printf '{"name":"r","workspaces":["pk/*"]}\n' > "${T}/symp/package.json"
printf '{"name":"spa"}\n' > "${T}/symp/realpk/a/package.json"
ln -s realpk "${T}/symp/pk"
add 'symlinked pattern parent @ realpk/a' "${T}/symp" realpk/a
mkdir -p "${T}/badabove/proj"
printf '{bad\n' > "${T}/badabove/package.json"
printf '{"name":"p"}\n' > "${T}/badabove/proj/package.json"
add 'invalid package.json above a project' "${T}/badabove" proj
for w in null false 0 '""' '{}'; do
  mkdir -p "${T}/wv${n}/packages/a"
  printf '{"name":"r","workspaces":%s}\n' "${w}" > "${T}/wv${n}/package.json"
  printf '{"name":"a"}\n' > "${T}/wv${n}/packages/a/package.json"
  add "workspaces=${w} @ packages/a" "${T}/wv${n}" packages/a
  n=$((n + 1))
done
layouts=$(wc -l < "${CHECKS}" | tr -d ' ')

# Command forms on top of the layouts: the directory is entered by the command,
# workspaces are turned off on the command line, and the prefix is named.
r=$(mkws forms '["packages/*"]')
add_cd 'cd into a member' "${r}" packages/a
add_cd 'cd into a member subdirectory' "${r}" packages/a/src
add_cd 'cd into a symlinked member by its link' "${T}/symws" packages/a
add_cd 'cd into a symlinked member by its target' "${T}/symws" real/a
add_cd 'cd into a symlinked pattern parent' "${T}/symp" pk/a
add 'workspaces=false @ packages/a' "${r}" packages/a --workspaces=false
add 'workspaces false @ packages/a' "${r}" packages/a --workspaces false
add 'no-workspaces @ symlinked member' "${T}/symws" packages/a --no-workspaces
add 'prefix named @ root' "${r}" . --prefix packages/b
add '-C named @ root' "${r}" . -C packages/b
total=$(wc -l < "${CHECKS}" | tr -d ' ')

# The checks are independent, so they run a few at a time.
mkdir -p "${T}/out"
i=0
while IFS=$'\t' read -r label cwd command theirs; do
  i=$((i + 1))
  check_one "${T}/out/${i}" "${label}" "${cwd}" "${command}" "${theirs}" &
  if (( i % 6 == 0 )); then wait; fi
done < "${CHECKS}"
wait

same=$(cat "${T}"/out/* | grep -c '^same' || true)
both=$(cat "${T}"/out/* | grep -c '^both' || true)
diffs=$(cat "${T}"/out/* | grep '^DIFF' || true)
undecided=$(cat "${T}"/out/* | grep '^UNDEC' || true)
[[ $(ls "${T}/out" | wc -l | tr -d ' ') -eq "${total}" ]] || fail "every check answered ($(ls "${T}/out" | wc -l | tr -d ' ') of ${total})"
(( layouts >= 237 )) || fail "the differential covers the validator's 237 layouts (${layouts})"
[[ -z "${diffs}" ]] || fail "the gate reads the directory npm names, in every layout (${diffs//$'\n'/; })"
[[ -z "${undecided}" ]] || fail "npm answered for every layout, so the gate decided every one (${undecided//$'\n'/; })"
pass "the gate reads the directory npm names: ${same} of ${total} checks the same and ${both} refused by npm and not placed by the gate (${layouts} layouts, $((total - layouts)) command forms), DIFF 0"
