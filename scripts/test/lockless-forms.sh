#!/usr/bin/env bash
# safedeps: npm installs whose result package-lock.json does not show.
#
# The effect gate is npm's enforcement authority, and it can only enforce on
# what it reads. It used to read package-lock.json alone, in the directory the
# command started in. npm has many ways to install without touching that file,
# and each one was measured here with a real npm against a local registry:
#
#   - `--no-save`, `--save=false`, `--no-package-lock`, `--package-lock false`,
#     and the same settings from the environment or an .npmrc leave
#     package-lock.json byte-identical. The package lands in node_modules and
#     in the hidden lockfile node_modules/.package-lock.json.
#   - `npm -C <dir>`, `cd <dir> && npm install`, and `cd <dir>; npm install`
#     write <dir>/package-lock.json.
#   - A global install (`npm_config_global=true` and friends) writes no
#     lockfile at all.
#
# The gate confirmed every one of them clean. On Claude Code that confirmation
# is what triggers `npm rebuild`, so the inert install then ran the unverified
# package's preinstall, install and postinstall scripts -- the exact thing the
# inert install exists to prevent. This battery pins the repair from both
# sides: every form above is rolled back or recorded, no unverified script runs,
# and an approved install still installs, verifies and rebuilds.
#
# This battery RUNS the install commands, unlike the text batteries. The
# question it answers is what npm writes and what `npm rebuild` executes, which
# is a property of npm and not of the command text. What keeps that safe:
# the only packages are synthetic ones packed here, the registry is
# fixture-registry.mjs on 127.0.0.1, and npm's proxies point at a closed local
# port so a request for anything else fails instead of leaving the machine.
# The request log is checked at the end.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "${ROOT_DIR}"

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

# A battery that skips when a tool is missing is a battery that passes when it
# cannot look. Each of these is required, so each is a failure when absent.
for tool in npm node jq; do
  command -v "${tool}" >/dev/null 2>&1 || fail "${tool} is required for the lockless-install battery"
done

# `cd && pwd` normalizes the path (macOS TMPDIR ends in a slash), so it compares
# equal to the paths npm reports.
tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-lockless.XXXXXX")
tmp_root=$(cd "${tmp_root}" && pwd)
# The marker only this battery's children carry, so a sweep can name them. See
# scripts/test/e2e.sh for why children are reaped three ways.
CHILD_MARKER='safedeps-lockless-child'
sweep_stale_children() {
  local pid args
  while read -r pid args; do
    [[ -n "${pid}" ]] || continue
    case "${args}" in
      *"${CHILD_MARKER}"*) kill -9 "${pid}" 2>/dev/null || true ;;
    esac
  done < <(ps -Ao pid=,args= 2>/dev/null)
}
owned_children=()
cleanup() {
  local child
  for child in "${owned_children[@]:-}"; do
    [[ -n "${child}" ]] || continue
    kill "${child}" 2>/dev/null || true
    wait "${child}" 2>/dev/null || true
  done
  rm -rf "${tmp_root}"
}
trap cleanup EXIT
sweep_stale_children

# --- synthetic packages --------------------------------------------------------
# Every lifecycle phase appends `<package>\t<phase>\t<cwd>` to MARKS, so a line
# in it is a script that ran and says where.
MARKS="${tmp_root}/marks.log"
: > "${MARKS}"
mkdir -p "${tmp_root}/tarballs"
make_package() {
  local name="$1" src="${tmp_root}/src/$1"
  mkdir -p "${src}"
  # The path lives in mark.js, not in the scripts: post-verify's install-script
  # heuristics read the script text, and a temp path under /home would read as
  # a script touching a sensitive path.
  cat > "${src}/mark.js" <<EOF
require('fs').appendFileSync('${MARKS}', '${name}\t' + process.argv[2] + '\t' + process.cwd() + '\n');
EOF
  jq -n --arg name "${name}" '{
    name: $name,
    version: "1.0.0",
    scripts: {preinstall: "node mark.js preinstall", install: "node mark.js install", postinstall: "node mark.js postinstall"}
  }' > "${src}/package.json"
  (cd "${src}" && npm pack --pack-destination "${tmp_root}/tarballs" >/dev/null 2>&1) \
    || fail "npm pack builds the synthetic package ${name}"
  cp "${src}/package.json" "${tmp_root}/tarballs/${name}-1.0.0.tgz.json"
}
# sd-victim is never approved. sd-approved is approved in every sandbox.
make_package sd-victim
make_package sd-approved

# --- local registry and advisory provider ----------------------------------------
( cd "${tmp_root}" && exec -a "${CHILD_MARKER}" \
    node "${ROOT_DIR}/scripts/test/fixture-registry.mjs" \
    "${tmp_root}/registry.port" "${tmp_root}/tarballs" "${tmp_root}/registry.log" ) &
owned_children+=("$!")
printf '{"vulnerable":[]}\n' > "${tmp_root}/osv-state.json"
( cd "${tmp_root}" && exec -a "${CHILD_MARKER}" \
    node "${ROOT_DIR}/scripts/test/fixture-provider.mjs" "${tmp_root}/osv.port" "${tmp_root}/osv-state.json" ) &
owned_children+=("$!")
for _ in {1..50}; do
  [[ -s "${tmp_root}/registry.port" && -s "${tmp_root}/osv.port" ]] && break
  sleep 0.1
done
[[ -s "${tmp_root}/registry.port" ]] || fail "the fixture registry starts"
[[ -s "${tmp_root}/osv.port" ]] || fail "the fixture advisory provider starts"
osv="http://127.0.0.1:$(cat "${tmp_root}/osv.port")"

# npm sees only this sandbox: its own home, config, cache and global prefix.
#
# Inherited npm settings go first. `npm test` runs this file as a lifecycle
# script, and npm exports its own configuration to those: npm_config_prefix
# among them, which outranks the sandbox userconfig. Measured in the CI image,
# that sent this battery's global-install forms into the real global prefix
# (/usr/local there, /opt/homebrew on a Homebrew Mac) -- the battery that exists
# to keep an unverified package out of places it should not be put one there.
while IFS= read -r inherited; do
  unset "${inherited}"
done < <(env | awk -F= 'tolower($1) ~ /^npm_config_/ { print $1 }')
export HOME="${tmp_root}/home"
mkdir -p "${HOME}"
export npm_config_userconfig="${tmp_root}/npmrc"
printf 'registry=http://127.0.0.1:%s/\nprefix=%s\n' "$(cat "${tmp_root}/registry.port")" "${tmp_root}/global" \
  > "${npm_config_userconfig}"
export npm_config_globalconfig="${tmp_root}/global-npmrc"
: > "${npm_config_globalconfig}"
export npm_config_cache="${tmp_root}/npm-cache" npm_config_audit=false npm_config_fund=false \
  npm_config_update_notifier=false npm_config_replace_registry_host=npmjs \
  npm_config_proxy=http://127.0.0.1:9 npm_config_https_proxy=http://127.0.0.1:9 \
  npm_config_noproxy=127.0.0.1
# Checked, not assumed: nothing below runs until npm itself says every install
# location is inside the sandbox.
[[ "$(npm config get prefix 2>/dev/null)" == "${tmp_root}/global" ]] \
  || fail "npm's global prefix is the sandbox before any install runs (got $(npm config get prefix 2>&1))"
[[ "$(npm_config_global=true npm config get prefix 2>/dev/null)" == "${tmp_root}/global" ]] \
  || fail "npm's global prefix stays in the sandbox under npm_config_global=true"
[[ "$(npm config get registry 2>/dev/null)" == "http://127.0.0.1:$(cat "${tmp_root}/registry.port")/" ]] \
  || fail "npm's registry is the fixture registry before any install runs"
export SAFEDEPS_OSV_API_URL="${osv}/osv/v1/query" SAFEDEPS_OSV_BATCH_API_URL="${osv}/osv/v1/querybatch" \
  SAFEDEPS_KEV_CATALOG_URL="${osv}/kev.json" SAFEDEPS_GHSA_API_URL="${osv}/advisories" \
  SAFEDEPS_PROVIDER_CACHE_TTL_SECONDS=0

# --- one install, end to end -------------------------------------------------------
# A fresh project (with a sub-project) and a fresh SAFEDEPS_HOME in which
# sd-approved is approved. Then the real sequence an agent's Bash call goes
# through: PreToolUse, the command as PreToolUse left it, PostToolUse.
#
# Sets CASE_PROJECT, CASE_HOME, CASE_POST and CASE_RAN, the scripts that ran
# after the command finished, which on Claude Code means the ones `npm rebuild`
# ran. The optional third argument runs a hook between the command and
# PostToolUse, with the project directory as its argument.
new_project() {
  CASE_PROJECT=$(mktemp -d "${tmp_root}/project.XXXXXX")
  mkdir -p "${CASE_PROJECT}/sub"
  printf '{"name":"proj","version":"1.0.0"}\n' > "${CASE_PROJECT}/package.json"
  printf '{"name":"sub","version":"1.0.0"}\n' > "${CASE_PROJECT}/sub/package.json"
  (cd "${CASE_PROJECT}" && npm install --ignore-scripts >/dev/null 2>&1) || fail "the fixture project installs"
  CASE_HOME=$(mktemp -d "${tmp_root}/safe.XXXXXX")
  ( export SAFEDEPS_HOME="${CASE_HOME}"
    . lib/ledger/ledger.sh
    safedeps_ledger_write_approved_spec npm sd-approved 1.0.0 >/dev/null ) \
    || fail "the fixture approval is written"
}

run_install() {
  local command="$1" engine="${2:-claude}" between="${3:-}" payload pre exec_command marks_before
  rm -rf "${tmp_root}/global"
  if [[ "${engine}" == codex ]]; then
    payload=$(jq -nc --arg c "${command}" --arg d "${CASE_PROJECT}" \
      '{tool_name:"Bash",tool_input:{command:$c},cwd:$d,turn_id:"turn-lockless",model:"codex-test"}')
  else
    payload=$(jq -nc --arg c "${command}" --arg d "${CASE_PROJECT}" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}')
  fi
  pre=$(printf '%s' "${payload}" | SAFEDEPS_HOME="${CASE_HOME}" scripts/safedeps-hook-entry.sh pre 2>/dev/null)
  if [[ -n "${pre}" && "$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<< "${pre}")" == deny ]]; then
    fail "the gate lets the install through to the effect gate: ${command}"
  fi
  exec_command=""
  [[ -z "${pre}" ]] || exec_command=$(jq -r '.hookSpecificOutput.updatedInput.command // empty' <<< "${pre}")
  [[ -n "${exec_command}" ]] || exec_command="${command}"
  if [[ "${engine}" == claude && "${exec_command}" != *--ignore-scripts* ]]; then
    fail "the install runs inert on Claude Code: ${command}"
  fi

  (cd "${CASE_PROJECT}" && bash -c "${exec_command}" >"${tmp_root}/last-install.log" 2>&1) \
    || fail "the install itself succeeds: ${exec_command} ($(tail -3 "${tmp_root}/last-install.log"))"
  [[ -z "${between}" ]] || "${between}" "${CASE_PROJECT}"

  marks_before=$(wc -l < "${MARKS}" | tr -d ' ')
  payload=$(jq -nc --arg c "${exec_command}" --arg d "${CASE_PROJECT}" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}')
  CASE_POST=$(printf '%s' "${payload}" | SAFEDEPS_HOME="${CASE_HOME}" scripts/safedeps-hook-entry.sh post 2>/dev/null)
  CASE_RAN=$(tail -n +"$((marks_before + 1))" "${MARKS}")
}

rolled_back() { grep -q 'rolled back' <<< "${CASE_POST}"; }
ungated() { grep -q 'UNGATED' "${CASE_HOME}/advisory.log" 2>/dev/null; }
victim_ran() { grep -q '^sd-victim' "${MARKS}"; }

# --- 1. Installs the effect gate now reads ------------------------------------
# Each lands in the directory the gate reads, and each leaves package-lock.json
# of that directory unchanged or absent. Before the repair every one of them was
# confirmed clean, and the ones that reached node_modules then had their scripts
# run by `npm rebuild`.
for form in \
  "npm install sd-victim --no-save" \
  "npm install --no-save sd-victim" \
  "npm install sd-victim --save=false" \
  "npm_config_save=false npm install sd-victim" \
  "NPM_CONFIG_SAVE=false npm install sd-victim" \
  "npm install sd-victim --package-lock false" \
  "npm install sd-victim --package-lock=false" \
  "npm install sd-victim --no-package-lock" \
  "npm_config_package_lock=false npm install sd-victim" \
  "printf 'save=false\\n' > .npmrc && npm install sd-victim" \
  "npm install sd-victim --no-save && npm run build --if-present" \
  "npm -C sub install sd-victim" \
  "npm --prefix=sub install sd-victim --no-save" \
  "cd sub && npm install sd-victim" \
  "cd sub; npm install sd-victim" \
  "env -C sub npm install sd-victim"
do
  if [[ "${form}" == env\ -C* ]] && ! env -C / true 2>/dev/null; then
    continue  # this platform's env has no -C (BSD); the form cannot run here
  fi
  new_project
  : > "${MARKS}"
  run_install "${form}"
  rolled_back || fail "the effect gate rolls back an unapproved install it reads: ${form} (post: ${CASE_POST:-<quiet>})"
  victim_ran && fail "no script of the unverified package runs: ${form} ($(cut -f1,2 "${MARKS}" | paste -sd, -))"
  [[ ! -e "${CASE_PROJECT}/node_modules/sd-victim" && ! -e "${CASE_PROJECT}/sub/node_modules/sd-victim" ]] \
    || fail "the rollback removes the unapproved package from disk: ${form}"
done
pass "installs that leave package-lock.json unchanged, or land in a sub-project, are read and rolled back"

# --- 2. Installs no effect gate reads are recorded -----------------------------------
# A global install writes no lockfile anywhere, so there is nothing to read.
# The gate says so in advisory.log. Nothing runs its scripts either: the rebuild
# stays in the project, and the package is not in the project.
for form in \
  "npm_config_global=true npm install sd-victim" \
  "export npm_config_global=true; npm install sd-victim" \
  "npm_config_location=global npm install sd-victim" \
  "npm install -g sd-victim" \
  "npm install sd-victim --location=global"
do
  new_project
  : > "${MARKS}"
  run_install "${form}"
  [[ -e "${tmp_root}/global/lib/node_modules/sd-victim" ]] || fail "the fixture global install lands in the sandbox prefix: ${form}"
  ungated || fail "an unpinned install the effect gate cannot read is recorded UNGATED: ${form}"
  victim_ran && fail "no script of the unverified global package runs: ${form}"
done
pass "global installs, however spelled in the command, are recorded as UNGATED and run no script"

# --- 3. Codex: detect and rollback ------------------------------------------------------
# Codex has no updatedInput, so the install is not inert and its scripts run
# during the install (documented asymmetry). The gate still reads the result
# and rolls it back.
new_project
: > "${MARKS}"
run_install "npm install sd-victim --no-save" codex
rolled_back || fail "on Codex, a --no-save install of an unapproved package is rolled back"
pass "on Codex, a --no-save install is detected and rolled back after its scripts ran (no inert install there)"

# --- 4. The rebuild stays in the project it verified -----------------------------------
# The project's .npmrc says global=true, so this install lands in the global
# prefix. The project itself has a verified tree, so the gate rebuilds it. A
# plain `npm rebuild` reads the same .npmrc and rebuilt the global tree
# instead, running sd-victim's scripts. A project .npmrc is a carrier the
# command text does not show, so the pre-guard cannot record this install as
# UNGATED; that boundary is documented. What is pinned here is that the
# rebuild does not turn it into script execution.
new_project
run_install "npm install sd-approved"
[[ -z "${CASE_POST}" ]] || fail "an approved install stays quiet before the .npmrc case (post: ${CASE_POST})"
printf 'global=true\n' > "${CASE_PROJECT}/.npmrc"
: > "${MARKS}"
run_install "npm install sd-victim"
[[ -e "${tmp_root}/global/lib/node_modules/sd-victim" ]] || fail "the .npmrc case lands the package in the global prefix"
victim_ran && fail "npm rebuild does not follow the project .npmrc into the global tree ($(cut -f1,2 "${MARKS}" | paste -sd, -))"
grep -q '^sd-approved	install' <<< "${CASE_RAN}" || fail "npm rebuild still rebuilds the verified project tree"
pass "npm rebuild stays in the verified project tree when the project .npmrc says global=true"

# --- 5. A tree nobody recorded is not rebuilt ---------------------------------------------
drop_hidden_lockfile() { rm -f "$1/node_modules/.package-lock.json"; }
new_project
: > "${MARKS}"
run_install "npm install sd-approved" claude drop_hidden_lockfile
[[ -z "${CASE_RAN}" ]] || fail "npm rebuild does not run over a node_modules with no hidden lockfile (${CASE_RAN})"
grep -q 'npm rebuild was not run' <<< "${CASE_POST}" || fail "the skipped rebuild is reported (post: ${CASE_POST:-<quiet>})"
pass "a node_modules with no hidden lockfile is not rebuilt, and the user is told"

# --- 6. Regression: approved installs still install, verify and rebuild -------------------
for form in \
  "npm install sd-approved" \
  "npm install sd-approved@1.0.0" \
  "npm install sd-approved --no-save" \
  "cd sub && npm install sd-approved" \
  "npm -C sub install sd-approved"
do
  new_project
  : > "${MARKS}"
  run_install "${form}"
  [[ -z "${CASE_POST}" ]] || fail "an approved install is confirmed quietly: ${form} (post: ${CASE_POST})"
  ungated && fail "an install the effect gate reads is not recorded UNGATED: ${form}"
  grep -q '^sd-approved	install' <<< "${CASE_RAN}" || fail "the verified inert install is rebuilt, so its scripts run: ${form}"
  case "${form}" in
    *sub*) where="${CASE_PROJECT}/sub" ;;
    *) where="${CASE_PROJECT}" ;;
  esac
  where=$(cd "${where}" && pwd -P)
  grep -q "	${where}/node_modules/sd-approved\$" <<< "${CASE_RAN}" \
    || fail "the rebuild runs where the install landed: ${form} (${CASE_RAN})"
done
pass "approved installs, including --no-save and sub-project forms, confirm quietly and rebuild where they landed"

# --- the fixture never left the machine ---------------------------------------------------
[[ -s "${tmp_root}/registry.log" ]] || fail "the installs went through the fixture registry"
if grep -vE '^GET /sd-(victim|approved)(/-/sd-(victim|approved)-1\.0\.0\.tgz)?$' "${tmp_root}/registry.log" | grep -q .; then
  fail "the fixture registry saw only the synthetic packages ($(sort -u "${tmp_root}/registry.log" | paste -sd, -))"
fi
pass "every request went to the local fixture registry, for the synthetic packages only"

printf 'lockless-forms passed\n'
