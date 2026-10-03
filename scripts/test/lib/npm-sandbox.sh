#!/usr/bin/env bash
# safedeps: the npm sandbox shared by the batteries that run npm itself.
#
# Sourced, not run, by scripts/test/lockless-forms.sh and
# scripts/test/effect-trace-grid.sh. Those are the batteries AGENTS.md lets run
# install commands, and this file is where the four conditions of that exception
# are enforced, so each of them holds for every battery that sources it:
#
#   - The only packages are synthetic ones packed here (sd-victim, sd-approved,
#     sd-swapped), with lifecycle scripts that only append a line to MARKS.
#   - The registry is fixture-registry.mjs on 127.0.0.1, and npm's proxies
#     point at a closed local port, so a request for anything else fails
#     instead of leaving the machine. The caller checks the request log at the
#     end (npm_sandbox_registry_was_local).
#   - Every inherited npm_config_* is unset first, and npm gets a home, user
#     and global config, cache and global prefix of its own, which `npm config
#     get` confirms before the first install.
#
# The caller defines pass and fail, sets ROOT_DIR and cds to it, and sets
# NPM_SANDBOX_NAME (the temp-directory and child-marker name) and
# NPM_SANDBOX_SCRIPT_RE (a pattern matching its own command line, which is how
# the sweep tells a live run from a dead one).

for tool in npm node jq; do
  command -v "${tool}" >/dev/null 2>&1 || fail "${tool} is required for the ${NPM_SANDBOX_NAME} battery"
done

# `cd && pwd` normalizes the path (macOS TMPDIR ends in a slash), so it compares
# equal to the paths npm reports.
tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-${NPM_SANDBOX_NAME}.XXXXXX")
tmp_root=$(cd "${tmp_root}" && pwd)
# The marker this battery's children carry, so a sweep can name them. See
# scripts/test/e2e.sh for why children are reaped three ways.
#
# The marker carries this run's pid, and the sweep reaps only the children of a
# run that is gone. A marker shared by every run let one run kill another's
# fixture registry mid-test: measured twice in one validation round, on a
# machine running several suites at once, and the victim went red with npm
# errors that looked like a code defect.
#
# The name does not contain the old shared marker, `safedeps-lockless-child`.
# A checkout that still sweeps by that substring would match a name containing
# it and kill this run's children -- measured while this marker was being
# written. Old-marker orphans are not this sweep's to reap.
CHILD_MARKER_BASE="safedeps-${NPM_SANDBOX_NAME}-owned"
CHILD_MARKER="${CHILD_MARKER_BASE}:$$"
battery_alive() { ps -o args= -p "$1" 2>/dev/null | grep -q "${NPM_SANDBOX_SCRIPT_RE}"; }
sweep_stale_children() {
  local pid args owner
  while read -r pid args; do
    [[ -n "${pid}" ]] || continue
    case "${args}" in
      *"${CHILD_MARKER_BASE}:"*) ;;
      *) continue ;;
    esac
    owner="${args#*"${CHILD_MARKER_BASE}:"}"
    owner="${owner%%[!0-9]*}"
    [[ -n "${owner}" ]] || continue
    battery_alive "${owner}" && continue
    kill -9 "${pid}" 2>/dev/null || true
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
# Every lifecycle phase appends `<package>@<version>\t<phase>\t<cwd>` to MARKS,
# so a line in it is a script that ran and says which version ran it, and where.
MARKS="${tmp_root}/marks.log"
: > "${MARKS}"
mkdir -p "${tmp_root}/tarballs"
make_package() {
  local name="$1" version="${2:-1.0.0}" src="${tmp_root}/src/$1-${2:-1.0.0}"
  mkdir -p "${src}"
  # The path lives in mark.js, not in the scripts: post-verify's install-script
  # heuristics read the script text, and a temp path under /home would read as
  # a script touching a sensitive path.
  cat > "${src}/mark.js" <<EOF
require('fs').appendFileSync('${MARKS}', '${name}@${version}\t' + process.argv[2] + '\t' + process.cwd() + '\n');
EOF
  jq -n --arg name "${name}" --arg version "${version}" '{
    name: $name,
    version: $version,
    scripts: {preinstall: "node mark.js preinstall", install: "node mark.js install", postinstall: "node mark.js postinstall"}
  }' > "${src}/package.json"
  (cd "${src}" && npm pack --pack-destination "${tmp_root}/tarballs" >/dev/null 2>&1) \
    || fail "npm pack builds the synthetic package ${name}"
  cp "${src}/package.json" "${tmp_root}/tarballs/${name}-${version}.tgz.json"
}
# sd-victim is never approved. sd-approved is approved in every sandbox.
make_package sd-victim
make_package sd-approved
# sd-swapped is approved at 1.0.0 and has an unapproved 1.0.1 from the start, so
# its section can install one version over the other without changing what
# `npm install sd-approved` resolves to anywhere else.
make_package sd-swapped 1.0.0
make_package sd-swapped 1.0.1

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
# The fixture registry is not the public registry, and the gate knows it: npm
# fetches every registry.npmjs.org URL the lockfiles record from here
# (fixture-registry.mjs), and without this the rebuild vouches for nothing:
# every install would be kept with its scripts withheld. This one
# registry, by its exact URL, is let through by name (lib/npm/ask.sh
# safedeps_npm_test_registry), and each hook run says so in advisory.log. Any
# other registry, a second one on 127.0.0.1 included, is judged as it would be
# anywhere.
export SAFEDEPS_NPM_TEST_REGISTRY="http://127.0.0.1:$(cat "${tmp_root}/registry.port")/"

# --- one install, end to end -------------------------------------------------------
# A fresh project (with a sub-project) and a fresh SAFEDEPS_HOME in which
# sd-approved is approved. Then the real sequence an agent's Bash call goes
# through: PreToolUse, the command as PreToolUse left it, PostToolUse.
#
# Sets CASE_PROJECT, CASE_HOME, CASE_POST and CASE_RAN, the scripts that ran
# after the command finished, which on Claude Code means the ones `npm rebuild`
# ran. The optional third argument runs a hook between the command and
# PostToolUse, with the project directory as its argument. The command runs in
# CASE_CWD, which is the project unless a case sets it to a subdirectory: the
# hook's cwd is wherever the agent's shell happens to be.
#
# The project has `sub`, a sub-project with a package.json of its own, and
# `src`, a plain directory without one.
#
# A fixture is made in CASE_PARENT when a battery sets it, and in the sandbox
# root otherwise.
new_project() {
  CASE_PROJECT=$(mktemp -d "${CASE_PARENT:-${tmp_root}}/project.XXXXXX")
  CASE_PROJECT=$(cd "${CASE_PROJECT}" && pwd -P)
  CASE_CWD="${CASE_PROJECT}"
  mkdir -p "${CASE_PROJECT}/sub" "${CASE_PROJECT}/src"
  printf '{"name":"proj","version":"1.0.0"}\n' > "${CASE_PROJECT}/package.json"
  printf '{"name":"sub","version":"1.0.0"}\n' > "${CASE_PROJECT}/sub/package.json"
  (cd "${CASE_PROJECT}" && npm install --ignore-scripts >/dev/null 2>&1) || fail "the fixture project installs"
  new_safedeps_home
}

new_safedeps_home() {
  CASE_HOME=$(mktemp -d "${tmp_root}/safe.XXXXXX")
  ( export SAFEDEPS_HOME="${CASE_HOME}"
    . lib/ledger/ledger.sh
    safedeps_ledger_write_approved_spec npm sd-approved 1.0.0 >/dev/null
    safedeps_ledger_write_approved_spec npm sd-swapped 1.0.0 >/dev/null ) \
    || fail "the fixture approval is written"
}

# An npm workspace: the root declares `packages/*`, and `packages/a` is a member.
# <workspaces> replaces the declaration.
new_workspace() {
  local workspaces="${1:-[\"packages/*\"]}"
  CASE_PROJECT=$(mktemp -d "${CASE_PARENT:-${tmp_root}}/workspace.XXXXXX")
  CASE_PROJECT=$(cd "${CASE_PROJECT}" && pwd -P)
  CASE_CWD="${CASE_PROJECT}"
  mkdir -p "${CASE_PROJECT}/packages/a"
  printf '{"name":"root","version":"1.0.0","private":true,"workspaces":%s}\n' "${workspaces}" \
    > "${CASE_PROJECT}/package.json"
  printf '{"name":"a","version":"1.0.0"}\n' > "${CASE_PROJECT}/packages/a/package.json"
  (cd "${CASE_PROJECT}" && npm install --ignore-scripts >/dev/null 2>&1) || fail "the fixture workspace installs"
  new_safedeps_home
}

# A workspace whose member packages/a is a symlink to ../real/a. npm's glob
# finds packages/a and compares that path, unresolved, with the physical
# directory an install runs in, so from real/a npm installs in real/a, not at
# the root.
new_symws() {
  CASE_PROJECT=$(mktemp -d "${tmp_root}/symws.XXXXXX")
  CASE_PROJECT=$(cd "${CASE_PROJECT}" && pwd -P)
  CASE_CWD="${CASE_PROJECT}"
  mkdir -p "${CASE_PROJECT}/packages" "${CASE_PROJECT}/real/a"
  printf '{"name":"root","version":"1.0.0","private":true,"workspaces":["packages/*"]}\n' > "${CASE_PROJECT}/package.json"
  printf '{"name":"a","version":"1.0.0"}\n' > "${CASE_PROJECT}/real/a/package.json"
  ln -s ../real/a "${CASE_PROJECT}/packages/a"
  (cd "${CASE_PROJECT}" && npm install --ignore-scripts >/dev/null 2>&1) || fail "the fixture symlinked workspace installs"
  new_safedeps_home
}

# A workspace that names its members with a negated pattern, which only npm's
# own glob reads.
new_negws() { new_workspace '["packages/*","!packages/b"]'; }

# A PATH on which `npm` is a stub: <behaviour> `fail` exits 7 with an npm-style
# error, `hang` never answers. <commands> are the npm commands it stubs, `|`
# separated; anything else goes to the real npm. `missing` is a PATH with every
# tool but npm. Stubs exec, so a deadline that kills the pid kills the stub.
stub_npm_path() {
  local behaviour="$1" commands="${2:-}" dir entry real
  dir=$(mktemp -d "${tmp_root}/stub.XXXXXX")
  real=$(command -v npm)
  if [[ "${behaviour}" == missing ]]; then
    local IFS=:
    for entry in ${PATH}; do
      for real in "${entry}"/*; do
        [[ -x "${real}" && "${real##*/}" != npm && ! -e "${dir}/${real##*/}" ]] || continue
        ln -s "${real}" "${dir}/${real##*/}"
      done
    done
    printf '%s' "${dir}"
    return 0
  fi
  {
    printf '#!/usr/bin/env bash\n'
    printf 'case "$1" in\n'
    printf '  %s)\n' "${commands}"
    case "${behaviour}" in
      fail) printf "    printf 'npm error code EFAKE\\nnpm error the stub refused\\n' >&2; exit 7 ;;\n" ;;
      hang) printf "    exec sleep 60 ;;\n" ;;
    esac
    printf 'esac\n'
    printf 'exec %q "$@"\n' "${real}"
  } > "${dir}/npm"
  chmod +x "${dir}/npm"
  printf '%s:%s' "${dir}" "${PATH}"
}

# A strict battery (the default) fails on a denied, non-inert or failed install.
# With NPM_SANDBOX_TOLERANT=true those are outcomes instead: CASE_PRE_DENY holds
# the deny reason, CASE_NOT_INERT is true, CASE_INSTALL_RC the exit status.
# CASE_CMD_ENV is an array of NAME=value the command runs with and the hooks do
# not see, as an agent's shell can carry state its hooks were not given.
run_install() {
  local command="$1" engine="${2:-claude}" between="${3:-}" payload pre exec_command marks_before
  CASE_PRE_DENY="" CASE_NOT_INERT=false CASE_INSTALL_RC=0 CASE_POST="" CASE_RAN="" CASE_EXEC=""
  rm -rf "${tmp_root}/global"
  if [[ "${engine}" == codex ]]; then
    payload=$(jq -nc --arg c "${command}" --arg d "${CASE_CWD}" \
      '{tool_name:"Bash",tool_input:{command:$c},cwd:$d,turn_id:"turn-lockless",model:"codex-test"}')
  else
    payload=$(jq -nc --arg c "${command}" --arg d "${CASE_CWD}" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}')
  fi
  pre=$(printf '%s' "${payload}" | PATH="${CASE_PRE_PATH:-${PATH}}" SAFEDEPS_HOME="${CASE_HOME}" scripts/safedeps-hook-entry.sh pre 2>/dev/null)
  if [[ -n "${pre}" && "$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<< "${pre}")" == deny ]]; then
    [[ "${NPM_SANDBOX_TOLERANT:-false}" == true ]] || fail "the gate lets the install through to the effect gate: ${command}"
    CASE_PRE_DENY=$(jq -r '.hookSpecificOutput.permissionDecisionReason // ""' <<< "${pre}")
    return 0
  fi
  exec_command=""
  [[ -z "${pre}" ]] || exec_command=$(jq -r '.hookSpecificOutput.updatedInput.command // empty' <<< "${pre}")
  [[ -n "${exec_command}" ]] || exec_command="${command}"
  CASE_EXEC="${exec_command}"
  if [[ "${engine}" == claude && "${exec_command}" != *--ignore-scripts* ]]; then
    [[ "${NPM_SANDBOX_TOLERANT:-false}" == true ]] || fail "the install runs inert on Claude Code: ${command}"
    CASE_NOT_INERT=true
  fi

  (cd "${CASE_CWD}" && env "${CASE_CMD_ENV[@]+"${CASE_CMD_ENV[@]}"}" bash -c "${exec_command}" >"${tmp_root}/last-install.log" 2>&1) \
    || CASE_INSTALL_RC=$?
  if [[ "${CASE_INSTALL_RC}" != 0 && "${NPM_SANDBOX_TOLERANT:-false}" != true ]]; then
    fail "the install itself succeeds: ${exec_command} ($(tail -3 "${tmp_root}/last-install.log"))"
  fi
  [[ -z "${between}" ]] || "${between}" "${CASE_PROJECT}"

  marks_before=$(wc -l < "${MARKS}" | tr -d ' ')
  payload=$(jq -nc --arg c "${exec_command}" --arg d "${CASE_CWD}" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}')
  CASE_POST=$(printf '%s' "${payload}" | PATH="${CASE_POST_PATH:-${PATH}}" SAFEDEPS_HOME="${CASE_HOME}" scripts/safedeps-hook-entry.sh post 2>/dev/null)
  CASE_RAN=$(tail -n +"$((marks_before + 1))" "${MARKS}")
}

rolled_back() { grep -q 'A rollback ran\.' <<< "${CASE_POST}"; }
ungated() { grep -q 'UNGATED' "${CASE_HOME}/advisory.log" 2>/dev/null; }
victim_ran() { grep -q '^sd-victim' "${MARKS}"; }

# Every request went to the local fixture registry, for the synthetic packages
# only. sd-nope is the name a battery asks for to see an install fail; the
# registry has no such package. sd-fetchy, sd-bundler, sd-bundlert, sd-nester,
# sd-evilsrc and sd-evilswap are packed by effect-trace-grid.sh, the last two
# fetched only by their tarball URL.
npm_sandbox_registry_was_local() {
  [[ -s "${tmp_root}/registry.log" ]] || fail "the installs went through the fixture registry"
  if grep -vE '^GET /sd-(victim|approved|approved-too|swapped|fetchy|bundler|bundlert|nester|nope)(/-/sd-(victim|approved|approved-too|swapped|fetchy|bundler|bundlert|nester)-1\.0\.[01]\.tgz)?$' "${tmp_root}/registry.log" \
      | grep -vE '^GET /sd-evil(src|swap)/-/sd-evil(src|swap)-1\.0\.0\.tgz$' | grep -q .; then
    fail "the fixture registry saw only the synthetic packages ($(sort -u "${tmp_root}/registry.log" | paste -sd, -))"
  fi
  pass "every request went to the local fixture registry, for the synthetic packages only"
}
