#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "${ROOT_DIR}"

pass() {
  native_fixtures_assert || fail "$1: native fixture failed; see invocation receipt/error"
  printf 'ok - %s\n' "$1"
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

# A rollback and its interrupted-rollback report give no command. The pattern
# is broad on purpose: a check for "npm ci" alone stayed green when review put
# "To reinstall, run npm install in <dir>" into both messages.
ROLLBACK_COMMAND_RE='(npm|yarn|pnpm|bun|npx)( +[a-z-]+)? +(ci|install|i|add|rebuild|prune|dedupe|update)([^a-z]|$)|reinstall (with|by)|run (npm|yarn|pnpm|bun)|safe to|by hand'
assert_gives_no_command() {
  if grep -qiE "${ROLLBACK_COMMAND_RE}" <<< "$1"; then
    fail "$2"
  fi
}
# A skipped rebuild says what safedeps did and the fact it read from disk. The
# line names the rebuild safedeps did not run, so that phrase is taken out
# before the same pattern is applied; a check for three fixed phrases stayed
# green when review appended "Finish it with npm rebuild --prefix <dir>".
assert_skipped_rebuild_states_facts() {
  local post="$1" label="$2" rest
  grep -q 'safedeps added --ignore-scripts to this install and did not run npm rebuild: ' <<< "${post}" || fail "${label}: the skipped rebuild is reported"
  rest="${post//did not run npm rebuild/}"
  assert_gives_no_command "${rest}" "${label}: the skipped rebuild names no place to run npm"
}

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-e2e.XXXXXX")

# Every post hook run in this suite goes through post_hook, and post_hook hands
# every line the hook printed to the report oracle (lib/report-oracle.sh). A
# row does not choose which of its messages are read: the phrase checks below
# say what a row is about, and the oracle says whether each line is a form
# safedeps may print and whether it is true on disk.
# shellcheck source=./lib/report-oracle.sh
source "${ROOT_DIR}/scripts/test/lib/report-oracle.sh"
oracle_init "${tmp_root}/report-oracle"
oracle_native_owner_forms
oracle_native_io_forms
source "${ROOT_DIR}/scripts/test/lib/core-post-fixtures.sh"
native_fixtures_init "${tmp_root}/native-fixtures"
post_message() { jq -r '.systemMessage // empty' <<< "$1"; }
post_hook() {
  local payload out call
  payload=$(cat)
  call=$(mktemp -d "${ORACLE_DIR}/call.XXXXXX")
  oracle_before "${call}" "${payload}"
  # The npm shim goes on PATH only where the row has an npm: on a PATH with
  # none, the shim would be the npm the hook finds, and the row would test a
  # hook that has one.
  local path="${PATH}"
  command -v npm >/dev/null 2>&1 && path="${ORACLE_DIR}/bin:${PATH}"
  out=$(printf '%s' "${payload}" | ORACLE_NPM_LOG="${call}/npm.log" ORACLE_CALL="${call}" PATH="${path}" \
    native_fixture_hook post) || fail "post hook fixture failed for this invocation"
  printf '%s' "${out}"
  oracle_message "${call}" "${payload}" "${out}" || exit 1
}
# Every pre-guard call goes through here too, so the oracle reads the rewrite
# the pre-guard printed and holds the record it wrote against it
# (oracle_pre). Output and status pass through unchanged.
pre_hook() {
  local payload out call rc=0
  payload=$(cat)
  call=$(mktemp -d "${ORACLE_DIR}/pre.XXXXXX")
  oracle_pre_before "${call}"
  out=$(printf '%s' "${payload}" | native_fixture_hook pre) || rc=$?
  native_fixtures_assert || fail "pre hook fixture failed for this invocation"
  printf '%s' "${out}"
  oracle_pre "${call}" "${out}" || exit 1
  return "${rc}"
}
# Children the owner-state tests spawn, so an exit anywhere can reap them. The
# stopped-owner test suspends a process and resumes it, and a run that dies in
# between leaves a permanently stopped orphan -- measured: four of them, up to
# 65 minutes old, and because their cwd was the plan worktree the close gate
# refused to prescribe removal at finalize. (`git worktree remove` itself exits
# 0 in that situation -- measured; it is kuma's live-cwd gate that refuses.)
# Writing code to judge stopped processes leaked stopped processes.
#
# SIGCONT before SIGKILL: a stopped process never receives SIGTERM, and SIGKILL
# is delivered regardless, so this order is what actually reaps one.
# A marker only this suite's children carry, so a sweep can name them without
# pattern-matching its way onto somebody else's process. It is the child's $0,
# which means it shows up in `ps -o args=` and nowhere else.
#
# It carries this run's pid, and the sweep reaps only the children of a run
# that is gone. The marker used to be one string shared by every run, and the
# tradeoff was argued as chosen: overlapping runs would kill each other's
# children, but loudly, and a run token would leave a SIGKILLed predecessor's
# orphans unrecognised. The pid answers both. A predecessor's orphans carry a
# pid that no longer runs this suite, so they are still reaped, and a live run's
# children are left alone. The cost of the shared string was measured, not
# hypothetical: on a machine running several suites at once, one run's sweep
# killed another's fixtures, and the victim's red read as a code defect.
#
# The name does not contain the old marker, `safedeps-e2e-child`. A checkout
# that still sweeps by that substring would otherwise match it. Orphans that
# carry the old marker are not this sweep's to reap.
E2E_CHILD_MARKER_BASE='safedeps-e2e-owned'
E2E_CHILD_MARKER="${E2E_CHILD_MARKER_BASE}:$$"
e2e_run_alive() { ps -o args= -p "$1" 2>/dev/null | grep -q 'e2e\.sh'; }

# Layer 2: SIGKILL defeats the EXIT trap, and "the runtime SIGKILLs the hook" is
# this repo's whole subject rather than a hypothetical -- measured, a suite
# killed inside the stopped-owner test leaves a suspended orphan behind. So each
# run also clears any orphan a PREVIOUS run left: a marked process whose run is
# no longer alive.
sweep_stale_children() {
  local pid args owner
  while read -r pid args; do
    [[ -n "${pid}" ]] || continue
    case "${args}" in
      *"${E2E_CHILD_MARKER_BASE}:"*) ;;
      *) continue ;;
    esac
    owner="${args#*"${E2E_CHILD_MARKER_BASE}:"}"
    owner="${owner%%[!0-9]*}"
    [[ -n "${owner}" ]] || continue
    e2e_run_alive "${owner}" && continue
    kill -CONT "${pid}" 2>/dev/null || true
    kill -9 "${pid}" 2>/dev/null || true
  done < <(ps -Ao pid=,args= 2>/dev/null)
}

owned_children=()
reap_owned_children() {
  local child
  for child in "${owned_children[@]:-}"; do
    [[ -n "${child}" ]] || continue
    kill -CONT "${child}" 2>/dev/null || true
    kill -9 "${child}" 2>/dev/null || true
  done
  owned_children=()
}

cleanup() {
  if [[ -n "${server_pid:-}" ]]; then
    kill "${server_pid}" 2>/dev/null || true
    wait "${server_pid}" 2>/dev/null || true
  fi
  reap_owned_children
  if [[ -n "${SAFEDEPS_TEST_EVIDENCE:-}" ]]; then
    mkdir -p "${SAFEDEPS_TEST_EVIDENCE}"
    cp -R "${tmp_root}/report-oracle" "${SAFEDEPS_TEST_EVIDENCE}/"
    cp "${SAFEDEPS_TEST_FAILURES}" "${SAFEDEPS_TEST_EVIDENCE}/fixture-failures.jsonl"
  fi
  rm -rf "${tmp_root}"
}
trap cleanup EXIT
sweep_stale_children

port_file="${tmp_root}/port"
state_file="${tmp_root}/state.json"
printf '%s\n' '{"vulnerable":[]}' > "${state_file}"
# The fourth site of the same shape, found in review: this server outlived its
# suite six times over, cwd in the plan worktree, and none of the three layers
# reached it -- no marker, worktree cwd, and it never exits on its own. Only the
# EXIT trap killed it, so any SIGKILL leaked one. It now spawns from tmp_root and
# carries the marker, which folds it into the sweep and the cwd layer both.
( cd "${tmp_root}" && exec -a "${E2E_CHILD_MARKER}" \
    node "${ROOT_DIR}/scripts/test/fixture-provider.mjs" "${port_file}" "${state_file}" ) &
server_pid=$!
owned_children+=("${server_pid}")

for _ in {1..50}; do
  [[ -s "${port_file}" ]] && break
  sleep 0.1
done
[[ -s "${port_file}" ]] || fail "fixture provider starts"
port=$(cat "${port_file}")

export SAFEDEPS_HOME="${tmp_root}/safe"
export SAFEDEPS_OSV_API_URL="http://127.0.0.1:${port}/osv/v1/query"
export SAFEDEPS_OSV_BATCH_API_URL="http://127.0.0.1:${port}/osv/v1/querybatch"
export SAFEDEPS_KEV_CATALOG_URL="http://127.0.0.1:${port}/kev.json"
export SAFEDEPS_GHSA_API_URL="http://127.0.0.1:${port}/advisories"
export SAFEDEPS_PROVIDER_CACHE_TTL_SECONDS=0

closure_fixture="${tmp_root}/closure-fixture.json"
cat > "${closure_fixture}" <<'EOF'
{
  "fixture-clean@1.0.0": [
    {"package":"fixture-clean","version":"1.0.0","direct":true}
  ],
  "fixture-copysafe@1.0.0": [
    {"package":"fixture-copysafe","version":"1.0.0","direct":true}
  ],
  "fixture-pad@1.0.0": [
    {"package":"fixture-pad","version":"1.0.0","direct":true}
  ],
  "fixture-vpad@1.0.0": [
    {"package":"fixture-vpad","version":"1.0.0","direct":true}
  ],
  "fixture-nl@1.0.0": [
    {"package":"fixture-nl","version":"1.0.0","direct":true}
  ],
  "fixture-vuln@1.0.0": [
    {"package":"fixture-vuln","version":"1.0.0","direct":true}
  ],
  "fixture-vuln@1.0.1": [
    {"package":"fixture-vuln","version":"1.0.1","direct":true}
  ],
  "fixture-multi-vuln@1.0.0": [
    {"package":"fixture-multi-vuln","version":"1.0.0","direct":true}
  ],
  "fixture-multi-vuln@1.0.1": [
    {"package":"fixture-multi-vuln","version":"1.0.1","direct":true}
  ],
  "fixture-multi-vuln@1.0.5": [
    {"package":"fixture-multi-vuln","version":"1.0.5","direct":true}
  ],
  "fixture-unpatched@1.0.0": [
    {"package":"fixture-unpatched","version":"1.0.0","direct":true}
  ],
  "fixture-kev@1.0.0": [
    {"package":"fixture-kev","version":"1.0.0","direct":true}
  ],
  "fixture-parent@1.0.0": [
    {"package":"fixture-parent","version":"1.0.0","direct":true},
    {"package":"fixture-child","version":"1.0.0","direct":false}
  ],
  "next@16.2.11": [
    {"package":"next","version":"16.2.11","direct":true},
    {"package":"postcss","version":"8.4.31","direct":false},
    {"package":"sharp","version":"0.34.5","direct":false}
  ]
}
EOF
export SAFEDEPS_NPM_CLOSURE_FIXTURE_JSON="${closure_fixture}"

clean_json=$(./bin/safedeps --json check npm fixture-clean@1.0.0)
[[ "$(jq -r '.result' <<< "${clean_json}")" == "clean" ]] || fail "clean fixture approved"
pass "clean advisory approval"

# A Go install names an import path, and OSV keys Go advisories by module path.
# Asked for the full path alone, a package below a vulnerable module came back
# clean and was approved, and the guard's own prescription led there
# (caught in cross-validation). Every prefix is asked now. The fixture knows
# only the module, the way OSV does.
printf '%s\n' '{"vulnerable":["example.com/mod@v1.0.0"]}' > "${state_file}"
go_sub_json=$(./bin/safedeps --json check go example.com/mod/cmd/tool@v1.0.0 2>/dev/null) || true
[[ "$(jq -r '.approved' <<< "${go_sub_json}")" == "false" ]] \
  || fail "a Go import path below a vulnerable module is not approved"
go_sub_guard=$(jq -nc --arg c "go install example.com/mod/cmd/tool@v1.0.0" --arg cwd "${tmp_root}" \
  '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}' | native_fixture_hook pre 2>/dev/null)
[[ "$(jq -r '.hookSpecificOutput.permissionDecision // "pass"' <<< "${go_sub_guard:-{\}}")" == "deny" ]] \
  || fail "after the prescribed check, the install of a package below a vulnerable module is still denied"
go_clean_json=$(./bin/safedeps --json check go example.com/other/cmd/tool@v1.0.0 2>/dev/null) || true
[[ "$(jq -r '.approved' <<< "${go_clean_json}")" == "true" ]] \
  || fail "a Go import path below a clean module is approved (the prefix walk does not flag everything)"
printf '%s\n' '{"vulnerable":[]}' > "${state_file}"
pass "a Go package is judged by every module prefix of its import path"

closure_json=$(./bin/safedeps --json check npm fixture-parent@1.0.0)
[[ "$(jq -r '.result' <<< "${closure_json}")" == "clean" ]] || fail "closure fixture approved"
[[ "$(jq -r '.transitive_count' <<< "${closure_json}")" == "1" ]] || fail "closure fixture records transitive count"
parent_hash=$(jq -r '.spec_hash' <<< "${closure_json}")
parent_file="${SAFEDEPS_HOME}/approved-specs/${parent_hash/:/-}.json"
[[ "$(jq -r '.transitive_specs[0].package' "${parent_file}")" == "fixture-child" ]] || fail "ledger transitive_specs records fixture child"
pass "closure approval records transitive_specs"

# Yarn Berry project context: root `resolutions` and Yarn's own actual locator
# graph replace the published package closure for this check. The approval is
# keyed by the exact project/resolutions/lockfile context, so it cannot be
# borrowed by a second project whose lockfile still resolves the vulnerable
# transitive version.
yarn_safe_project="${tmp_root}/yarn-safe-project"
yarn_unsafe_project="${tmp_root}/yarn-unsafe-project"
yarn_absent_project="${tmp_root}/yarn-absent-project"
mkdir -p "${yarn_safe_project}" "${yarn_unsafe_project}" "${yarn_absent_project}"
cat > "${yarn_safe_project}/package.json" <<'EOF'
{"name":"yarn-safe","private":true,"packageManager":"yarn@4.12.0","resolutions":{"postcss@npm:8.4.31":"8.5.21","sharp@npm:^0.34.5":"0.35.3"}}
EOF
cat > "${yarn_unsafe_project}/package.json" <<'EOF'
{"name":"yarn-unsafe","private":true,"packageManager":"yarn@4.12.0","resolutions":{"postcss@npm:8.4.31":"8.4.31","sharp@npm:^0.34.5":"0.34.5"}}
EOF
cat > "${yarn_absent_project}/package.json" <<'EOF'
{"name":"yarn-absent","private":true,"packageManager":"yarn@4.12.0"}
EOF
printf '__metadata:\n  version: 8\n# safe fixture\n' > "${yarn_safe_project}/yarn.lock"
printf '__metadata:\n  version: 8\n# unsafe fixture\n' > "${yarn_unsafe_project}/yarn.lock"
printf '__metadata:\n  version: 8\n# absent fixture\n' > "${yarn_absent_project}/yarn.lock"
yarn_safe_project_canonical=$(cd "${yarn_safe_project}" && pwd -P)

yarn_safe_graph="${tmp_root}/yarn-safe-info.ndjson"
yarn_unsafe_graph="${tmp_root}/yarn-unsafe-info.ndjson"
cat > "${yarn_safe_graph}" <<'EOF'
{"value":"next@npm:16.2.11","children":{"Version":"16.2.11","Dependencies":[{"descriptor":"postcss@npm:8.5.21","locator":"postcss@npm:8.5.21"},{"descriptor":"sharp@npm:0.35.3","locator":"sharp@npm:0.35.3"}]}}
{"value":"postcss@npm:8.5.21","children":{"Version":"8.5.21"}}
{"value":"sharp@npm:0.35.3","children":{"Version":"0.35.3"}}
EOF
cat > "${yarn_unsafe_graph}" <<'EOF'
{"value":"next@npm:16.2.11","children":{"Version":"16.2.11","Dependencies":[{"descriptor":"postcss@npm:8.4.31","locator":"postcss@npm:8.4.31"},{"descriptor":"sharp@npm:0.34.5","locator":"sharp@npm:0.34.5"}]}}
{"value":"postcss@npm:8.4.31","children":{"Version":"8.4.31"}}
{"value":"sharp@npm:0.34.5","children":{"Version":"0.34.5"}}
EOF
printf '%s\n' '{"vulnerable":["postcss@8.4.31","sharp@0.34.5"]}' > "${state_file}"

yarn_safe_home="${tmp_root}/safe-yarn-project"
yarn_safe_json=$(
  env -u SAFEDEPS_NPM_CLOSURE_FIXTURE_JSON \
    SAFEDEPS_HOME="${yarn_safe_home}" \
    SAFEDEPS_NPM_PROJECT_DIR="${yarn_safe_project}" \
    SAFEDEPS_YARN_INFO_FIXTURE_NDJSON="${yarn_safe_graph}" \
    ./bin/safedeps --json check npm next@16.2.11
)
[[ "$(jq -r '.result' <<< "${yarn_safe_json}")" == "clean" ]] || fail "Yarn resolved project closure is approved when patched"
[[ "$(jq -r '.closure_source.type' <<< "${yarn_safe_json}")" == "yarn-project-lockfile" ]] || fail "Yarn check reports lockfile project source"
[[ "$(jq -r '.closure_source.lockfile_path' <<< "${yarn_safe_json}")" == "${yarn_safe_project_canonical}/yarn.lock" ]] || fail "Yarn check preserves exact source lockfile path"
[[ "$(jq -r '[.resolved_closure[] | select(.package == "sharp" and .version == "0.35.3")] | length' <<< "${yarn_safe_json}")" == "1" ]] || fail "Yarn check reports patched Sharp locator"
[[ "$(jq -r '[.resolved_closure[] | select(.package == "postcss" and .version == "8.5.21")] | length' <<< "${yarn_safe_json}")" == "1" ]] || fail "Yarn check reports patched PostCSS locator"
yarn_safe_hash=$(jq -r '.spec_hash' <<< "${yarn_safe_json}")
yarn_safe_entry="${yarn_safe_home}/approved-specs/${yarn_safe_hash/:/-}.json"
[[ "$(jq -r '.project_context.context_hash' "${yarn_safe_entry}")" == "$(jq -r '.closure_source.context_hash' <<< "${yarn_safe_json}")" ]] || fail "Yarn approval ledger is bound to project context"

yarn_safe_cached=$(
  env -u SAFEDEPS_NPM_CLOSURE_FIXTURE_JSON \
    SAFEDEPS_HOME="${yarn_safe_home}" \
    SAFEDEPS_NPM_PROJECT_DIR="${yarn_safe_project}" \
    ./bin/safedeps --json check npm next@16.2.11
)
[[ "$(jq -r '.result' <<< "${yarn_safe_cached}")" == "already_approved" ]] || fail "same Yarn project context reuses scoped approval"

set +e
yarn_unsafe_json=$(
  env -u SAFEDEPS_NPM_CLOSURE_FIXTURE_JSON \
    SAFEDEPS_HOME="${yarn_safe_home}" \
    SAFEDEPS_NPM_PROJECT_DIR="${yarn_unsafe_project}" \
    SAFEDEPS_YARN_INFO_FIXTURE_NDJSON="${yarn_unsafe_graph}" \
    ./bin/safedeps --json check npm next@16.2.11
)
yarn_unsafe_status=$?
yarn_absent_json=$(
  SAFEDEPS_HOME="${tmp_root}/safe-yarn-absent" \
    SAFEDEPS_NPM_PROJECT_DIR="${yarn_absent_project}" \
    ./bin/safedeps --json check npm next@16.2.11
)
yarn_absent_status=$?
set -e
[[ "${yarn_unsafe_status}" -eq 2 ]] || fail "unsafe Yarn project closure exits 2"
[[ "$(jq -r '.result' <<< "${yarn_unsafe_json}")" == "closure_vulnerable" ]] || fail "unsafe Yarn project does not borrow safe scoped approval"
[[ "$(jq -r '[.closure_vulnerabilities[] | select(.package == "sharp" and .version == "0.34.5")] | length' <<< "${yarn_unsafe_json}")" == "1" ]] || fail "unsafe Yarn verdict names vulnerable Sharp locator"
[[ "$(jq -r '[.closure_vulnerabilities[] | select(.package == "postcss" and .version == "8.4.31")] | length' <<< "${yarn_unsafe_json}")" == "1" ]] || fail "unsafe Yarn verdict names vulnerable PostCSS locator"
[[ "${yarn_absent_status}" -eq 2 ]] || fail "project without resolutions keeps package-only deny"
[[ "$(jq -r '.closure_source.type' <<< "${yarn_absent_json}")" == "fixture" ]] || fail "absent resolutions keep published closure source"

yarn_safe_hook=$(
  SAFEDEPS_HOME="${yarn_safe_home}" pre_hook <<EOF
{"tool_name":"Bash","tool_input":{"command":"yarn add next@16.2.11"},"cwd":"${yarn_safe_project}","turn_id":"turn-yarn-safe","model":"codex-test"}
EOF
)
[[ -z "${yarn_safe_hook}" ]] || fail "Yarn command gate accepts matching project-scoped approval"
yarn_unsafe_hook=$(
  SAFEDEPS_HOME="${yarn_safe_home}" pre_hook <<EOF
{"tool_name":"Bash","tool_input":{"command":"yarn add next@16.2.11"},"cwd":"${yarn_unsafe_project}","turn_id":"turn-yarn-unsafe","model":"codex-test"}
EOF
)
[[ "$(jq -r '.hookSpecificOutput.permissionDecision' <<< "${yarn_unsafe_hook}")" == "deny" ]] || fail "Yarn command gate rejects approval from a different project context"
pass "Yarn root resolutions use actual lockfile closure with project-scoped approval isolation"
printf '%s\n' '{"vulnerable":[]}' > "${state_file}"

# Candidate locators are not present in the caller's current lockfile. The
# isolated Yarn stub is hermetic, but safedeps still invokes the actual Yarn
# contract (`install --mode=update-lockfile`) and then reads the graph from the
# generated mirror lockfile. The fixture mirrors anttime's relevant shape:
# root resolutions, a Yarn config file, and a workspace manifest.
candidate_yarn_bin="${tmp_root}/candidate-yarn-bin"
candidate_yarn_log="${tmp_root}/candidate-yarn.log"
mkdir -p "${candidate_yarn_bin}"
cat > "${candidate_yarn_bin}/yarn" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\t%s\n' "${PWD}" "$*" >> "${SAFEDEPS_YARN_STUB_LOG}"
case "$*" in
  *"install --mode=update-lockfile"*)
    [[ -f package.json && -f .yarnrc.yml && -f packages/web/package.json && ! -e packages/web/node_modules ]] || exit 64
    [[ "${SAFEDEPS_YARN_STUB_FAIL_INSTALL:-0}" != "1" ]] || exit 65
    cat "${SAFEDEPS_YARN_STUB_LOCK}" > yarn.lock
    ;;
  *"info -A -R --json"*)
    if grep -q '^# safedeps candidate materialized$' yarn.lock; then
      cat "${SAFEDEPS_YARN_STUB_GRAPH}"
    fi
    ;;
  *)
    exit 64
    ;;
esac
EOF
chmod +x "${candidate_yarn_bin}/yarn"

write_anttime_candidate_project() {
  local project_dir="$1"
  local label="$2"
  local postcss_resolution="$3"
  local sharp_resolution="$4"

  mkdir -p "${project_dir}/packages/web/node_modules/ignored-package"
  cat > "${project_dir}/package.json" <<EOF
{"name":"anttime-${label}","private":true,"packageManager":"yarn@4.12.0","workspaces":["packages/*"],"dependencies":{"react":"19.2.4"},"resolutions":{"postcss@npm:8.4.31":"${postcss_resolution}","sharp@npm:^0.34.5":"${sharp_resolution}"}}
EOF
  cat > "${project_dir}/packages/web/package.json" <<'EOF'
{"name":"@anttime/web","private":true,"version":"0.0.0","dependencies":{"@anttime/shared":"workspace:*"}}
EOF
  printf '{"name":"ignored-package","version":"1.0.0"}\n' > "${project_dir}/packages/web/node_modules/ignored-package/package.json"
  printf 'nodeLinker: node-modules\n' > "${project_dir}/.yarnrc.yml"
  printf '__metadata:\n  version: 8\n# caller lockfile stays unchanged\n' > "${project_dir}/yarn.lock"
}

hash_project_tree() {
  local project_dir="$1"

  (
    cd "${project_dir}"
    while IFS= read -r project_file; do
      printf '%s\t' "${project_file}"
      shasum -a 256 "${project_file}"
    done < <(find . -type f -print | LC_ALL=C sort)
  ) | shasum -a 256 | cut -d' ' -f1
}

candidate_safe_project="${tmp_root}/anttime-yarn-candidate-safe"
candidate_unsafe_project="${tmp_root}/anttime-yarn-candidate-unsafe"
candidate_failure_project="${tmp_root}/anttime-yarn-candidate-failure"
write_anttime_candidate_project "${candidate_safe_project}" "safe" "8.5.21" "0.35.3"
write_anttime_candidate_project "${candidate_unsafe_project}" "unsafe" "8.4.31" "0.34.5"
write_anttime_candidate_project "${candidate_failure_project}" "failure" "8.5.21" "0.35.3"

candidate_safe_lock="${tmp_root}/candidate-safe.lock"
candidate_unsafe_lock="${tmp_root}/candidate-unsafe.lock"
candidate_safe_graph="${tmp_root}/candidate-safe-info.ndjson"
candidate_unsafe_graph="${tmp_root}/candidate-unsafe-info.ndjson"
cat > "${candidate_safe_lock}" <<'EOF'
__metadata:
  version: 8
# safedeps candidate materialized
EOF
cat > "${candidate_unsafe_lock}" <<'EOF'
__metadata:
  version: 8
# safedeps candidate materialized
EOF
cat > "${candidate_safe_graph}" <<'EOF'
{"value":"next@npm:16.2.11","children":{"Version":"16.2.11","Dependencies":[{"descriptor":"postcss@npm:8.5.21","locator":"postcss@npm:8.5.21"},{"descriptor":"sharp@npm:0.35.3","locator":"sharp@npm:0.35.3"}]}}
{"value":"postcss@npm:8.5.21","children":{"Version":"8.5.21"}}
{"value":"sharp@npm:0.35.3","children":{"Version":"0.35.3"}}
EOF
cat > "${candidate_unsafe_graph}" <<'EOF'
{"value":"next@npm:16.2.11","children":{"Version":"16.2.11","Dependencies":[{"descriptor":"postcss@npm:8.4.31","locator":"postcss@npm:8.4.31"},{"descriptor":"sharp@npm:0.34.5","locator":"sharp@npm:0.34.5"}]}}
{"value":"postcss@npm:8.4.31","children":{"Version":"8.4.31"}}
{"value":"sharp@npm:0.34.5","children":{"Version":"0.34.5"}}
EOF

candidate_safe_tree_before=$(hash_project_tree "${candidate_safe_project}")
candidate_safe_lock_before=$(shasum -a 256 "${candidate_safe_project}/yarn.lock" | cut -d' ' -f1)
candidate_safe_home="${tmp_root}/safe-yarn-candidate"
candidate_safe_json=$(
  env -u SAFEDEPS_NPM_CLOSURE_FIXTURE_JSON \
    PATH="${candidate_yarn_bin}:${PATH}" \
    SAFEDEPS_HOME="${candidate_safe_home}" \
    SAFEDEPS_NPM_PROJECT_DIR="${candidate_safe_project}" \
    SAFEDEPS_YARN_STUB_LOG="${candidate_yarn_log}" \
    SAFEDEPS_YARN_STUB_LOCK="${candidate_safe_lock}" \
    SAFEDEPS_YARN_STUB_GRAPH="${candidate_safe_graph}" \
    ./bin/safedeps --json check npm next@16.2.11
)
[[ "$(jq -r '.result' <<< "${candidate_safe_json}")" == "clean" ]] || fail "absent Yarn candidate is approved from its materialized closure"
[[ "$(jq -r '.closure_source.type' <<< "${candidate_safe_json}")" == "yarn-project-materialized-lockfile" ]] || fail "candidate source identifies isolated materialization"
[[ "$(jq -r '.closure_source.materialization.command' <<< "${candidate_safe_json}")" == "yarn install --mode=update-lockfile --no-immutable" ]] || fail "candidate materialization records the Yarn update-lockfile contract"
[[ "$(jq -r '.closure_source.materialization.input_sha256' <<< "${candidate_safe_json}")" == "$(jq -r '.closure_source.input_sha256' <<< "${candidate_safe_json}")" ]] || fail "candidate materialization binds canonical input provenance"
[[ "$(jq -r '.closure_source.materialization.generated_lockfile_sha256' <<< "${candidate_safe_json}")" != "$(jq -r '.closure_source.lockfile_sha256' <<< "${candidate_safe_json}")" ]] || fail "candidate materialization records its generated lockfile provenance"
[[ "$(jq -r '[.resolved_closure[] | select(.package == "sharp" and .version == "0.35.3")] | length' <<< "${candidate_safe_json}")" == "1" ]] || fail "materialized candidate resolves patched Sharp"
[[ "$(jq -r '[.resolved_closure[] | select(.package == "postcss" and .version == "8.5.21")] | length' <<< "${candidate_safe_json}")" == "1" ]] || fail "materialized candidate resolves patched PostCSS"
[[ "$(hash_project_tree "${candidate_safe_project}")" == "${candidate_safe_tree_before}" ]] || fail "candidate materialization leaves caller tree byte-identical"
[[ "$(shasum -a 256 "${candidate_safe_project}/yarn.lock" | cut -d' ' -f1)" == "${candidate_safe_lock_before}" ]] || fail "candidate materialization leaves caller lockfile byte-identical"
# The caller project IS read in place: locator discovery runs `yarn info` there,
# which is the v2.10 project-closure path. What it must never receive is a
# mutating command. Compare physical paths -- the stub logs $PWD, so a /tmp or
# /var symlink would otherwise make this assertion match nothing and pass
# vacuously on one platform while failing on another.
candidate_safe_project_real=$(cd "${candidate_safe_project}" && pwd -P)
if awk -F'\t' -v proj="${candidate_safe_project_real}" \
    '$1 == proj && $2 ~ /install/ { found = 1 } END { exit !found }' "${candidate_yarn_log}"; then
  fail "candidate materialization never runs a mutating Yarn command in the caller project"
fi
# Positive half: the materialization really happened, and somewhere that is not
# the caller. Together these two cannot both hold unless the install was isolated.
awk -F'\t' -v proj="${candidate_safe_project_real}" \
  '$1 != proj && $2 == "install --mode=update-lockfile --no-immutable" { found = 1 } END { exit !found }' \
  "${candidate_yarn_log}" || fail "candidate materialization runs Yarn update-lockfile outside the caller project"
candidate_safe_hash=$(jq -r '.spec_hash' <<< "${candidate_safe_json}")
candidate_safe_entry="${candidate_safe_home}/approved-specs/${candidate_safe_hash/:/-}.json"
[[ "$(jq -r '.project_context.materialization.generated_lockfile_sha256' "${candidate_safe_entry}")" == "$(jq -r '.closure_source.materialization.generated_lockfile_sha256' <<< "${candidate_safe_json}")" ]] || fail "ledger stores generated-lock provenance"

candidate_materialize_count_before=$(grep -c $'install --mode=update-lockfile --no-immutable' "${candidate_yarn_log}")
candidate_safe_cached=$(env -u SAFEDEPS_NPM_CLOSURE_FIXTURE_JSON SAFEDEPS_HOME="${candidate_safe_home}" SAFEDEPS_NPM_PROJECT_DIR="${candidate_safe_project}" ./bin/safedeps --json check npm next@16.2.11)
[[ "$(jq -r '.result' <<< "${candidate_safe_cached}")" == "already_approved" ]] || fail "same candidate input context reuses materialized approval"
[[ "$(grep -c $'install --mode=update-lockfile --no-immutable' "${candidate_yarn_log}")" == "${candidate_materialize_count_before}" ]] || fail "ledger hit does not re-materialize candidate"

printf '%s\n' '{"vulnerable":["postcss@8.4.31","sharp@0.34.5"]}' > "${state_file}"
set +e
candidate_unsafe_json=$(env -u SAFEDEPS_NPM_CLOSURE_FIXTURE_JSON PATH="${candidate_yarn_bin}:${PATH}" SAFEDEPS_HOME="${tmp_root}/safe-yarn-candidate-unsafe" SAFEDEPS_NPM_PROJECT_DIR="${candidate_unsafe_project}" SAFEDEPS_YARN_STUB_LOG="${candidate_yarn_log}" SAFEDEPS_YARN_STUB_LOCK="${candidate_unsafe_lock}" SAFEDEPS_YARN_STUB_GRAPH="${candidate_unsafe_graph}" ./bin/safedeps --json check npm next@16.2.11)
candidate_unsafe_status=$?
candidate_failure_json=$(env -u SAFEDEPS_NPM_CLOSURE_FIXTURE_JSON PATH="${candidate_yarn_bin}:${PATH}" SAFEDEPS_HOME="${tmp_root}/safe-yarn-candidate-failure" SAFEDEPS_NPM_PROJECT_DIR="${candidate_failure_project}" SAFEDEPS_YARN_STUB_LOG="${candidate_yarn_log}" SAFEDEPS_YARN_STUB_LOCK="${candidate_safe_lock}" SAFEDEPS_YARN_STUB_GRAPH="${candidate_safe_graph}" SAFEDEPS_YARN_STUB_FAIL_INSTALL=1 ./bin/safedeps --json check npm next@16.2.11)
candidate_failure_status=$?
set -e
[[ "${candidate_unsafe_status}" -eq 2 ]] || fail "unsafe materialized candidate exits 2"
[[ "$(jq -r '.result' <<< "${candidate_unsafe_json}")" == "closure_vulnerable" ]] || fail "unsafe materialized candidate is denied"
[[ "$(jq -r '[.closure_vulnerabilities[] | select(.package == "sharp" and .version == "0.34.5")] | length' <<< "${candidate_unsafe_json}")" == "1" ]] || fail "unsafe materialized candidate names vulnerable Sharp"
[[ "$(jq -r '[.closure_vulnerabilities[] | select(.package == "postcss" and .version == "8.4.31")] | length' <<< "${candidate_unsafe_json}")" == "1" ]] || fail "unsafe materialized candidate names vulnerable PostCSS"
[[ "${candidate_failure_status}" -eq 4 ]] || fail "unavailable candidate materialization exits fail-closed 4"
[[ "$(jq -r '.error' <<< "${candidate_failure_json}")" == "project-candidate-materialization-unavailable" ]] || fail "unavailable candidate materialization reports its deny reason"
[[ "$(jq -r '.closure_source.type' <<< "${candidate_failure_json}")" == "yarn-project-candidate-materialization" ]] || fail "unavailable candidate does not report a published closure source"
if find "${tmp_root}/safe-yarn-candidate-failure/approved-specs" -name '*.json' -type f -print -quit 2>/dev/null | grep -q .; then
  fail "unavailable candidate materialization never writes an approval"
fi

printf '%s\n' '# context drift' >> "${candidate_safe_project}/yarn.lock"
candidate_context_mismatch_hook=$(SAFEDEPS_HOME="${candidate_safe_home}" pre_hook <<EOF
{"tool_name":"Bash","tool_input":{"command":"yarn add next@16.2.11"},"cwd":"${candidate_safe_project}","turn_id":"turn-yarn-candidate-context-drift","model":"codex-test"}
EOF
)
[[ "$(jq -r '.hookSpecificOutput.permissionDecision' <<< "${candidate_context_mismatch_hook}")" == "deny" ]] || fail "candidate approval is rejected after canonical input context drift"
printf '__metadata:\n  version: 8\n# caller lockfile stays unchanged\n' > "${candidate_safe_project}/yarn.lock"
pass "Yarn absent candidates materialize only in an isolated mirror with bound provenance"
printf '%s\n' '{"vulnerable":[]}' > "${state_file}"

patched_json=$(./bin/safedeps --json check npm fixture-vuln@1.0.0)
[[ "$(jq -r '.result' <<< "${patched_json}")" == "patched_available" ]] || fail "patched fixture narrows"
[[ "$(jq -r '.suggested_spec' <<< "${patched_json}")" == "1.0.1" ]] || fail "patched fixture suggests fixed version"
pass "patched advisory narrowing"

multi_patched_json=$(./bin/safedeps --json check npm fixture-multi-vuln@1.0.0)
[[ "$(jq -r '.result' <<< "${multi_patched_json}")" == "patched_available" ]] || fail "multi patched fixture narrows"
[[ "$(jq -r '.suggested_spec' <<< "${multi_patched_json}")" == "1.0.5" ]] || fail "multi patched fixture tries later clean fixed version"
pass "patched advisory tries all fixed candidates"

set +e
unpatched_json=$(./bin/safedeps --json check npm fixture-unpatched@1.0.0)
unpatched_status=$?
kev_json=$(./bin/safedeps --json check npm fixture-kev@1.0.0)
kev_status=$?
set -e
[[ "${unpatched_status}" -eq 2 ]] || fail "unpatched fixture exits 2"
[[ "$(jq -r '.result' <<< "${unpatched_json}")" == "cve_unpatched" ]] || fail "unpatched fixture reports cve_unpatched"
[[ "${kev_status}" -eq 3 ]] || fail "kev fixture exits 3"
[[ "$(jq -r '.result' <<< "${kev_json}")" == "kev_hard_block" ]] || fail "kev fixture reports kev_hard_block"
pass "block classifications"

project_dir="${tmp_root}/project"
mkdir -p "${project_dir}"
printf '{"dependencies":{}}\n' > "${project_dir}/package.json"
hook_allow=$(
  pre_hook <<EOF
{"tool_name":"Bash","tool_input":{"command":"npm install fixture-vuln@1.0.1"},"cwd":"${project_dir}","turn_id":"turn-e2e","model":"codex-test"}
EOF
)
[[ -z "${hook_allow}" ]] || fail "hook allows narrowed approved spec"
pass "hook allows approved narrowed spec"

effect_project="${tmp_root}/effect-project"
mkdir -p "${effect_project}"
printf '{"dependencies":{}}\n' > "${effect_project}/package.json"

effect_clean_pre=$(
  pre_hook <<EOF
{"tool_name":"Bash","tool_input":{"command":"npm install fixture-parent@1.0.0"},"cwd":"${effect_project}","turn_id":"turn-e2e","model":"codex-test"}
EOF
)
[[ -z "${effect_clean_pre}" ]] || fail "effect clean pre hook allows closure-approved direct spec"
cat > "${effect_project}/package-lock.json" <<'EOF'
{
  "name": "effect-project",
  "lockfileVersion": 3,
  "packages": {
    "": {"dependencies": {"fixture-parent": "1.0.0"}},
    "node_modules/fixture-parent": {"version": "1.0.0", "dependencies": {"fixture-child": "1.0.0"}},
    "node_modules/fixture-child": {"version": "1.0.0"}
  }
}
EOF
effect_clean_post=$(
  post_hook <<EOF
{"tool_name":"Bash","tool_input":{"command":"npm install fixture-parent@1.0.0"},"cwd":"${effect_project}"}
EOF
)
[[ -z "${effect_clean_post}" ]] || fail "post hook passes approved full closure"
pass "post hook passes approved full closure"

inert_project="${tmp_root}/inert-project"
mkdir -p "${inert_project}"
printf '{"dependencies":{}}\n' > "${inert_project}/package.json"
inert_pre=$(
  pre_hook <<EOF
{"tool_name":"Bash","tool_input":{"command":"npm install fixture-parent@1.0.0"},"cwd":"${inert_project}"}
EOF
)
[[ "$(jq -r '.hookSpecificOutput.permissionDecision' <<< "${inert_pre}")" == "allow" ]] || fail "inert pre hook emits Claude allow"
[[ "$(jq -r '.hookSpecificOutput.updatedInput.command' <<< "${inert_pre}")" == "npm install --ignore-scripts fixture-parent@1.0.0 --ignore-scripts" ]] || fail "inert pre hook injects ignore-scripts"
cat > "${inert_project}/package-lock.json" <<'EOF'
{
  "name": "inert-project",
  "lockfileVersion": 3,
  "packages": {
    "": {"dependencies": {"fixture-parent": "1.0.0"}},
    "node_modules/fixture-parent": {"version": "1.0.0", "resolved": "https://registry.npmjs.org/fixture-parent/-/fixture-parent-1.0.0.tgz", "integrity": "sha512-fixtureParent100", "dependencies": {"fixture-child": "1.0.0"}},
    "node_modules/fixture-child": {"version": "1.0.0", "resolved": "https://registry.npmjs.org/fixture-child/-/fixture-child-1.0.0.tgz", "integrity": "sha512-fixtureChild100"}
  }
}
EOF
# npm records the tree it built in the hidden lockfile, and the rebuild runs
# only over a tree on record, every package from the public registry and
# recorded with an integrity, so its bytes can be told from withheld ones
# (lockless-forms.sh pins the case without a hidden lockfile,
# effect-trace-grid.sh section 1d the sources and the integrity).
mkdir -p "${inert_project}/node_modules"
cp "${inert_project}/package-lock.json" "${inert_project}/node_modules/.package-lock.json"
stub_bin="${tmp_root}/stub-bin"
mkdir -p "${stub_bin}"
# The rebuild runs only when npm says the tree it would rebuild is the one on
# record, so the stub answers `npm query` with the tree the lockfile records,
# and only when npm says it fetches from the public registry, so the stub
# answers `npm config ls --json` with npm's defaults.
cat > "${stub_bin}/npm" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${tmp_root}/npm-calls.log"
if [[ "\$1" == query ]]; then
  printf '%s\n' '[{"location":"","name":"inert-project"},{"location":"node_modules/fixture-parent","name":"fixture-parent","version":"1.0.0"},{"location":"node_modules/fixture-child","name":"fixture-child","version":"1.0.0"}]'
elif [[ "\$1" == config ]]; then
  printf '%s\n' '{"registry":"https://registry.npmjs.org/","replace-registry-host":"npmjs"}'
fi
exit 0
EOF
chmod +x "${stub_bin}/npm"
inert_post=$(
  PATH="${stub_bin}:${PATH}" post_hook <<EOF
{"tool_name":"Bash","tool_input":{"command":"npm install --ignore-scripts fixture-parent@1.0.0 --ignore-scripts"},"cwd":"${inert_project}"}
EOF
)
[[ -z "${inert_post}" ]] || fail "post hook keeps verified inert rebuild success quiet"
grep -qxE 'rebuild --global=false --location=project --prefix .*/inert-project' "${tmp_root}/npm-calls.log" \
  || fail "post hook runs npm rebuild, pinned to the project tree, after verified injected install"
pass "post hook rebuilds after verified inert install"

# Reorg must actually revert the on-disk lockfile, not just print the message. The
# missing-transitive test below proves the systemMessage; this proves the stronger
# claim — a tampered lockfile is restored byte-for-byte to the last confirmed safe
# snapshot on disk. Regression guard so a future change cannot break the rollback
# while keeping the message green. Stub npm keeps `npm ci` from rewriting the file.
revert_project="${tmp_root}/revert-project"
mkdir -p "${revert_project}"
printf '{"dependencies":{"fixture-parent":"1.0.0"}}\n' > "${revert_project}/package.json"
cat > "${revert_project}/package-lock.json" <<'EOF'
{
  "name": "revert-project",
  "lockfileVersion": 3,
  "packages": {
    "": {"dependencies": {"fixture-parent": "1.0.0"}},
    "node_modules/fixture-parent": {"version": "1.0.0", "dependencies": {"fixture-child": "1.0.0"}},
    "node_modules/fixture-child": {"version": "1.0.0"}
  }
}
EOF
cp "${revert_project}/package-lock.json" "${tmp_root}/revert-safe-lock.json"
pre_hook > /dev/null <<EOF
{"tool_name":"Bash","tool_input":{"command":"npm install fixture-parent@1.0.0"},"cwd":"${revert_project}"}
EOF
cat > "${revert_project}/package-lock.json" <<'EOF'
{
  "name": "revert-project",
  "lockfileVersion": 3,
  "packages": {
    "": {"dependencies": {"fixture-parent": "1.0.0"}},
    "node_modules/fixture-parent": {"version": "1.0.0", "dependencies": {"fixture-child": "1.0.0"}},
    "node_modules/fixture-child": {"version": "1.0.0"},
    "node_modules/fixture-evil": {"version": "6.6.6", "resolved": "git://evil.example.com/fixture-evil.git"}
  }
}
EOF
revert_post=$(
  PATH="${stub_bin}:${PATH}" post_hook <<EOF
{"tool_name":"Bash","tool_input":{"command":"npm install fixture-parent@1.0.0"},"cwd":"${revert_project}"}
EOF
)
grep -q 'suspicious dependency change detected' <<< "${revert_post}" || fail "reorg fires on a tampered lockfile"
cmp -s "${revert_project}/package-lock.json" "${tmp_root}/revert-safe-lock.json" || fail "reorg restores the exact safe lockfile content on disk"
if grep -qE '^(ci|install)' "${tmp_root}/npm-calls.log" 2>/dev/null; then
  fail "a rollback runs no npm: the reinstall is the next install"
fi
assert_gives_no_command "${revert_post}" "the rollback of a tampered lockfile gives no command"
pass "reorg reverts a tampered lockfile to safe content on disk"

# A rollback never acts outside the project it read. Some worktree layouts link
# node_modules to another checkout's, and `npm ci` empties whatever node_modules
# resolves to before it installs. This stub npm does what that first step of
# `npm ci` does -- it empties node_modules through any link -- so a rollback
# that follows the link shows up as a missing marker in the linked-to
# directory.
emptying_bin="${tmp_root}/emptying-npm-bin"
mkdir -p "${emptying_bin}"
cat > "${emptying_bin}/npm" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${tmp_root}/emptying-npm-calls.log"
case "\$1" in
  ci) rm -rf node_modules/* ;;
esac
exit 0
EOF
chmod +x "${emptying_bin}/npm"
tampered_lock='{
  "name": "linked-project",
  "lockfileVersion": 3,
  "packages": {
    "": {"dependencies": {"fixture-parent": "1.0.0"}},
    "node_modules/fixture-parent": {"version": "1.0.0", "dependencies": {"fixture-child": "1.0.0"}},
    "node_modules/fixture-child": {"version": "1.0.0"},
    "node_modules/fixture-evil": {"version": "6.6.6", "resolved": "git://evil.example.com/fixture-evil.git"}
  }
}'
reorg_log="${SAFEDEPS_HOME:-${HOME}/.safedeps}/reorg.log"

link_main="${tmp_root}/link-main"
link_wt="${tmp_root}/link-wt"
mkdir -p "${link_main}/node_modules/kept-package" "${link_wt}"
printf '{"name":"kept-package","version":"1.0.0"}\n' > "${link_main}/node_modules/kept-package/package.json"
ln -s "${link_main}/node_modules" "${link_wt}/node_modules"
printf '{"dependencies":{"fixture-parent":"1.0.0"}}\n' > "${link_wt}/package.json"
cp "${tmp_root}/revert-safe-lock.json" "${link_wt}/package-lock.json"
pre_hook > /dev/null <<EOF
{"tool_name":"Bash","tool_input":{"command":"npm install fixture-parent@1.0.0"},"cwd":"${link_wt}"}
EOF
printf '%s\n' "${tampered_lock}" > "${link_wt}/package-lock.json"
link_post=$(
  PATH="${emptying_bin}:${PATH}" post_hook <<EOF
{"tool_name":"Bash","tool_input":{"command":"npm install fixture-parent@1.0.0"},"cwd":"${link_wt}"}
EOF
)
grep -q 'suspicious dependency change detected' <<< "${link_post}" || fail "reorg fires in a project whose node_modules is a link"
[[ -f "${link_main}/node_modules/kept-package/package.json" ]] || fail "a rollback never empties the directory a linked node_modules points to"
grep -q "refused removal of .*/link-wt/node_modules: .*/link-wt/node_modules is a symbolic link to " <<< "${link_post}" || fail "the reorg message names the refused node_modules removal"
assert_gives_no_command "${link_post}" "the rollback next to a linked node_modules gives no command"
grep -A2 'REORG REFUSED$' "${reorg_log}" | grep -q '^  refused removal of .*/link-wt/node_modules: ' || fail "reorg.log records the refused node_modules removal"
if grep -q '^ci' "${tmp_root}/emptying-npm-calls.log" 2>/dev/null; then
  fail "npm ci never runs on a node_modules that links outside the project"
fi
cmp -s "${link_wt}/package-lock.json" "${tmp_root}/revert-safe-lock.json" || fail "the lockfile inside the project is still restored next to a linked node_modules"
pass "a rollback leaves a node_modules that links outside the project, and names it"

# The same holds for a file the rollback would write back: a package.json that
# links to another checkout's is not written through.
link_pkg_wt="${tmp_root}/link-pkg-wt"
link_pkg_outside="${tmp_root}/link-pkg-outside"
mkdir -p "${link_pkg_wt}" "${link_pkg_outside}"
printf '{"dependencies":{"fixture-parent":"1.0.0"}}\n' > "${link_pkg_outside}/package.json"
ln -s "${link_pkg_outside}/package.json" "${link_pkg_wt}/package.json"
cp "${tmp_root}/revert-safe-lock.json" "${link_pkg_wt}/package-lock.json"
pre_hook > /dev/null <<EOF
{"tool_name":"Bash","tool_input":{"command":"npm install fixture-parent@1.0.0"},"cwd":"${link_pkg_wt}"}
EOF
printf '{"dependencies":{"fixture-parent":"1.0.0","fixture-evil":"6.6.6"}}\n' > "${link_pkg_outside}/package.json"
cp "${link_pkg_outside}/package.json" "${tmp_root}/link-pkg-expected.json"
printf '%s\n' "${tampered_lock}" > "${link_pkg_wt}/package-lock.json"
link_pkg_post=$(
  PATH="${stub_bin}:${PATH}" post_hook <<EOF
{"tool_name":"Bash","tool_input":{"command":"npm install fixture-parent@1.0.0"},"cwd":"${link_pkg_wt}"}
EOF
)
grep -q 'suspicious dependency change detected' <<< "${link_pkg_post}" || fail "reorg fires in a project whose package.json is a link"
cmp -s "${link_pkg_outside}/package.json" "${tmp_root}/link-pkg-expected.json" || fail "a rollback never writes through a package.json that links outside the project"
[[ -L "${link_pkg_wt}/package.json" ]] || fail "a rollback leaves the linked package.json a link"
[[ "$(grep -o 'refused restore of [^ ]*/link-pkg-wt/package.json: ' <<< "${link_pkg_post}" | wc -l | tr -d ' ')" == 1 ]] || fail "the reorg message names the refused package.json restore once"
grep -A2 'REORG REFUSED$' "${reorg_log}" | grep -q '^  refused restore of .*/link-pkg-wt/package.json: ' || fail "reorg.log records the refused package.json restore"
assert_gives_no_command "${link_pkg_post}" "the rollback next to a linked package.json gives no command"
cmp -s "${link_pkg_wt}/package-lock.json" "${tmp_root}/revert-safe-lock.json" || fail "the lockfile inside the project is still restored next to a linked package.json"
pass "a rollback refuses to write back a file that links outside the project"

# A verified inert install still skips the rebuild through a linked node_modules:
# that would run another checkout's install scripts.
link_inert_main="${tmp_root}/link-inert-main"
link_inert_wt="${tmp_root}/link-inert-wt"
mkdir -p "${link_inert_main}/node_modules" "${link_inert_wt}"
ln -s "${link_inert_main}/node_modules" "${link_inert_wt}/node_modules"
printf '{"dependencies":{}}\n' > "${link_inert_wt}/package.json"
link_inert_pre=$(
  pre_hook <<EOF
{"tool_name":"Bash","tool_input":{"command":"npm install fixture-parent@1.0.0"},"cwd":"${link_inert_wt}"}
EOF
)
[[ "$(jq -r '.hookSpecificOutput.updatedInput.command' <<< "${link_inert_pre}")" == "npm install --ignore-scripts fixture-parent@1.0.0 --ignore-scripts" ]] || fail "linked inert pre hook injects ignore-scripts"
cat > "${link_inert_wt}/package-lock.json" <<'EOF'
{
  "name": "link-inert-wt",
  "lockfileVersion": 3,
  "packages": {
    "": {"dependencies": {"fixture-parent": "1.0.0"}},
    "node_modules/fixture-parent": {"version": "1.0.0", "dependencies": {"fixture-child": "1.0.0"}},
    "node_modules/fixture-child": {"version": "1.0.0"}
  }
}
EOF
: > "${tmp_root}/emptying-npm-calls.log"
link_inert_post=$(
  PATH="${emptying_bin}:${PATH}" post_hook <<EOF
{"tool_name":"Bash","tool_input":{"command":"npm install --ignore-scripts fixture-parent@1.0.0 --ignore-scripts"},"cwd":"${link_inert_wt}"}
EOF
)
if grep -q 'rebuild' "${tmp_root}/emptying-npm-calls.log" 2>/dev/null; then
  fail "npm rebuild never runs through a node_modules that links outside the project"
fi
assert_skipped_rebuild_states_facts "${link_inert_post}" "linked node_modules"
grep -qF "/link-inert-wt/node_modules is a symbolic link to" <<< "${link_inert_post}" || fail "the skipped rebuild names the linked node_modules"
pass "a verified inert install skips the rebuild through a linked node_modules"

# npm leads outside without any link: in a directory with no package.json and
# no node_modules it walks up to the enclosing project and works there. The
# rollback runs no npm at all; this stub, which does the same walk and empties
# the node_modules it lands on, is the trap that shows it if one ever runs.
walkup_bin="${tmp_root}/walkup-npm-bin"
mkdir -p "${walkup_bin}"
cat > "${walkup_bin}/npm" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${tmp_root}/walkup-npm-calls.log"
target="" prev=""
for a in "\$@"; do [ "\$prev" = "--prefix" ] && target="\$a"; prev="\$a"; done
if [ -z "\$target" ]; then
  target="\$PWD"
  while [ "\$target" != / ] && [ ! -e "\$target/package.json" ] && [ ! -e "\$target/node_modules" ]; do target="\${target%/*}"; [ -n "\$target" ] || target=/; done
fi
case "\$1" in
  ci|install) rm -rf "\$target"/node_modules/* ;;
esac
exit 0
EOF
chmod +x "${walkup_bin}/npm"
make_enclosing() {
  mkdir -p "$1/node_modules/kept-package"
  printf '{"name":"enclosing","version":"1.0.0"}\n' > "$1/package.json"
  printf '{"name":"kept-package","version":"1.0.0"}\n' > "$1/node_modules/kept-package/package.json"
}

# A directory with a lockfile but neither package.json nor node_modules: npm
# works in the enclosing project from here, and the gate reads where npm says
# the install lands. Nothing there shows this install, so it is recorded
# UNGATED, nothing is rolled back, and no npm runs.
walk_main="${tmp_root}/walk-main"
make_enclosing "${walk_main}"
walk_wt="${walk_main}/nested/worktree"
mkdir -p "${walk_wt}"
cp "${tmp_root}/revert-safe-lock.json" "${walk_wt}/package-lock.json"
pre_hook > /dev/null <<EOF
{"tool_name":"Bash","tool_input":{"command":"npm install fixture-parent@1.0.0"},"cwd":"${walk_wt}"}
EOF
printf '%s\n' "${tampered_lock}" > "${walk_wt}/package-lock.json"
walk_post=$(
  PATH="${walkup_bin}:${PATH}" post_hook <<EOF
{"tool_name":"Bash","tool_input":{"command":"npm install fixture-parent@1.0.0"},"cwd":"${walk_wt}"}
EOF
)
grep -q 'no install trace in .*/walk-main' <<< "${walk_post}" || fail "the gate reads the enclosing project npm works in, and records the install UNGATED"
if grep -q 'suspicious dependency change detected' <<< "${walk_post}"; then
  fail "nothing is rolled back where the gate read no install"
fi
[[ -f "${walk_main}/node_modules/kept-package/package.json" ]] || fail "the enclosing project's node_modules is left alone"
if grep -qE '^(ci|install|rebuild)' "${tmp_root}/walkup-npm-calls.log" 2>/dev/null; then
  fail "no npm ci, install or rebuild runs where npm would walk up to an enclosing project"
fi
pass "no rollback and no npm where npm would walk up to an enclosing project"

# The install path: the install created package.json and the lockfile, the
# rollback removes both, and the reinstall falls back to npm install in a
# directory left with neither.
walk2_main="${tmp_root}/walk2-main"
make_enclosing "${walk2_main}"
walk2_wt="${walk2_main}/nested/worktree"
mkdir -p "${walk2_wt}/node_modules"
pre_hook > /dev/null <<EOF
{"tool_name":"Bash","tool_input":{"command":"npm install fixture-parent@1.0.0"},"cwd":"${walk2_wt}"}
EOF
printf '{"dependencies":{"fixture-parent":"1.0.0"}}\n' > "${walk2_wt}/package.json"
printf '%s\n' "${tampered_lock}" > "${walk2_wt}/package-lock.json"
: > "${tmp_root}/walkup-npm-calls.log"
walk2_post=$(
  PATH="${walkup_bin}:${PATH}" post_hook <<EOF
{"tool_name":"Bash","tool_input":{"command":"npm install fixture-parent@1.0.0"},"cwd":"${walk2_wt}"}
EOF
)
grep -q 'suspicious dependency change detected' <<< "${walk2_post}" || fail "reorg fires in a fresh project nested inside another"
[[ -f "${walk2_main}/node_modules/kept-package/package.json" ]] || fail "a rollback's npm install never walks up to prune the enclosing project's node_modules"
if grep -q '^install' "${tmp_root}/walkup-npm-calls.log" 2>/dev/null; then
  fail "a rollback runs no npm install once it has removed the package.json the install created"
fi
[[ ! -e "${walk2_wt}/node_modules" ]] || fail "a rollback removes the project's own node_modules"
grep -q '/nested/worktree/package.json does not exist' <<< "${walk2_post}" || fail "the rollback says the restore left no package.json"
assert_gives_no_command "${walk2_post}" "the rollback gives no reinstall command"
pass "a rollback runs no npm install where npm would walk up to an enclosing project"

# A lockfile that links to another checkout's: the restore of it is refused,
# and no npm runs to save it through the link (a fallback npm install used to).
# This stub fails ci and writes the lockfile on install -- the trap.
lockwrite_bin="${tmp_root}/lockwrite-npm-bin"
mkdir -p "${lockwrite_bin}"
cat > "${lockwrite_bin}/npm" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${tmp_root}/lockwrite-npm-calls.log"
case "\$1" in
  ci) exit 1 ;;
  install) printf 'REWRITTEN\n' > package-lock.json ;;
esac
exit 0
EOF
chmod +x "${lockwrite_bin}/npm"
linklock_wt="${tmp_root}/linklock-wt"
linklock_outside="${tmp_root}/linklock-outside"
mkdir -p "${linklock_wt}" "${linklock_outside}"
printf '{"dependencies":{"fixture-parent":"1.0.0"}}\n' > "${linklock_wt}/package.json"
cp "${tmp_root}/revert-safe-lock.json" "${linklock_outside}/package-lock.json"
ln -s "${linklock_outside}/package-lock.json" "${linklock_wt}/package-lock.json"
pre_hook > /dev/null <<EOF
{"tool_name":"Bash","tool_input":{"command":"npm install fixture-parent@1.0.0"},"cwd":"${linklock_wt}"}
EOF
printf '%s\n' "${tampered_lock}" > "${linklock_outside}/package-lock.json"
cp "${linklock_outside}/package-lock.json" "${tmp_root}/linklock-expected.json"
linklock_post=$(
  PATH="${lockwrite_bin}:${PATH}" post_hook <<EOF
{"tool_name":"Bash","tool_input":{"command":"npm install fixture-parent@1.0.0"},"cwd":"${linklock_wt}"}
EOF
)
grep -q 'suspicious dependency change detected' <<< "${linklock_post}" || fail "reorg fires in a project whose lockfile is a link"
cmp -s "${linklock_outside}/package-lock.json" "${tmp_root}/linklock-expected.json" || fail "a rollback never writes the lockfile a link points to, by restore or by reinstall"
if grep -qE '^(ci|install)' "${tmp_root}/lockwrite-npm-calls.log" 2>/dev/null; then
  fail "a rollback runs no npm in a project whose lockfile is a link"
fi
grep -q 'refused restore of .*/linklock-wt/package-lock.json: ' <<< "${linklock_post}" || fail "the refused lockfile restore is named"
assert_gives_no_command "${linklock_post}" "the rollback next to a linked lockfile gives no command"
pass "a rollback writes nothing through a lockfile that links outside the project"

# A workspace may lie outside the project, and npm ci empties every
# workspace's node_modules. The rollback runs no npm and removes only the
# project's own node_modules. This stub empties the declared workspace on ci --
# the trap.
ws_bin="${tmp_root}/ws-npm-bin"
mkdir -p "${ws_bin}"
cat > "${ws_bin}/npm" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${tmp_root}/ws-npm-calls.log"
case "\$1" in
  ci) rm -rf ../ws-outside/node_modules/* ;;
esac
exit 0
EOF
chmod +x "${ws_bin}/npm"
ws_wt="${tmp_root}/ws-wt"
ws_outside="${tmp_root}/ws-outside"
mkdir -p "${ws_wt}/node_modules/installed-package" "${ws_outside}/node_modules/kept-package"
printf '{"name":"shared","version":"1.0.0"}\n' > "${ws_outside}/package.json"
printf '{"name":"kept-package","version":"1.0.0"}\n' > "${ws_outside}/node_modules/kept-package/package.json"
printf '{"name":"ws","workspaces":["../ws-outside"],"dependencies":{"fixture-parent":"1.0.0"}}\n' > "${ws_wt}/package.json"
cp "${tmp_root}/revert-safe-lock.json" "${ws_wt}/package-lock.json"
pre_hook > /dev/null <<EOF
{"tool_name":"Bash","tool_input":{"command":"npm install fixture-parent@1.0.0"},"cwd":"${ws_wt}"}
EOF
printf '%s\n' "${tampered_lock}" > "${ws_wt}/package-lock.json"
ws_post=$(
  PATH="${ws_bin}:${PATH}" post_hook <<EOF
{"tool_name":"Bash","tool_input":{"command":"npm install fixture-parent@1.0.0"},"cwd":"${ws_wt}"}
EOF
)
grep -q 'suspicious dependency change detected' <<< "${ws_post}" || fail "reorg fires in a project that declares workspaces"
[[ -f "${ws_outside}/node_modules/kept-package/package.json" ]] || fail "a rollback never empties a workspace outside the project"
if grep -q '^ci' "${tmp_root}/ws-npm-calls.log" 2>/dev/null; then
  fail "a rollback runs no npm ci in a project that declares workspaces"
fi
[[ ! -e "${ws_wt}/node_modules" ]] || fail "a rollback removes a workspace project's own node_modules"
grep -q '/ws-wt/package.json has the key workspaces' <<< "${ws_post}" || fail "the rollback says the project's package.json has the key workspaces"
grep -q 'removed .*/ws-wt/node_modules$' <<< "$(post_message "${ws_post}")" || fail "the rollback names the one node_modules it removed"
assert_gives_no_command "${ws_post}" "the rollback in a workspace project gives no command"
if grep -q 'remove them' <<< "${ws_post}"; then
  fail "the rollback in a workspace project sends no removal anywhere"
fi
cmp -s "${ws_wt}/package-lock.json" "${tmp_root}/revert-safe-lock.json" || fail "the lockfile of a workspace project is still restored"
pass "a rollback leaves a workspace outside the project alone"

# The rollback's own node_modules step: a real directory is removed, links
# inside it are removed without being followed, and the message says which
# directory was removed and what the project root holds after it.
own_wt="${tmp_root}/own-wt"
own_outside="${tmp_root}/own-outside"
mkdir -p "${own_wt}/node_modules/installed-package" "${own_outside}/kept-package"
printf '{"name":"kept-package","version":"1.0.0"}\n' > "${own_outside}/kept-package/package.json"
ln -s "${own_outside}/kept-package" "${own_wt}/node_modules/linked-package"
printf '{"dependencies":{"fixture-parent":"1.0.0"}}\n' > "${own_wt}/package.json"
cp "${tmp_root}/revert-safe-lock.json" "${own_wt}/package-lock.json"
pre_hook > /dev/null <<EOF
{"tool_name":"Bash","tool_input":{"command":"npm install fixture-parent@1.0.0"},"cwd":"${own_wt}"}
EOF
printf '%s\n' "${tampered_lock}" > "${own_wt}/package-lock.json"
: > "${tmp_root}/emptying-npm-calls.log"
own_post=$(
  PATH="${emptying_bin}:${PATH}" post_hook <<EOF
{"tool_name":"Bash","tool_input":{"command":"npm install fixture-parent@1.0.0"},"cwd":"${own_wt}"}
EOF
)
grep -q 'suspicious dependency change detected' <<< "${own_post}" || fail "reorg fires in an ordinary npm project"
[[ ! -e "${own_wt}/node_modules" ]] || fail "a rollback removes the project's own node_modules"
[[ -f "${own_outside}/kept-package/package.json" ]] || fail "removing node_modules does not follow a link inside it"
grep -q 'removed .*/own-wt/node_modules$' <<< "$(post_message "${own_post}")" || fail "the rollback says which node_modules it removed"
grep -q '/own-wt/package-lock.json exists$' <<< "$(post_message "${own_post}")" || fail "the rollback says the lockfile is there after the restore"
grep -q '/own-wt/npm-shrinkwrap.json does not exist$' <<< "$(post_message "${own_post}")" || fail "the rollback says there is no npm-shrinkwrap.json"
assert_gives_no_command "${own_post}" "the rollback gives no reinstall command in an ordinary project either"
if grep -qE '^(ci|install)' "${tmp_root}/emptying-npm-calls.log" 2>/dev/null; then
  fail "a rollback runs no npm in an ordinary project either"
fi
cmp -s "${own_wt}/package-lock.json" "${tmp_root}/revert-safe-lock.json" || fail "the lockfile is restored before node_modules is removed"
pass "a rollback removes the project's own node_modules and runs no npm"

# A command that wrote nothing. The closure on disk was never approved, and
# the gate judges the whole closure whether or not the command changed it: no
# install trace means UNGATED and no rebuild, not no judgment. So a command
# misread as an install reaches the rollback with nothing to roll back. The
# project's node_modules is not this command's and stays.
nochange_wt="${tmp_root}/nochange-wt"
mkdir -p "${nochange_wt}/node_modules/installed-package" "${nochange_wt}/node_modules/.bin"
printf '{"name":"installed-package","version":"1.0.0"}\n' > "${nochange_wt}/node_modules/installed-package/package.json"
printf '{"dependencies":{"fixture-parent":"1.0.0"}}\n' > "${nochange_wt}/package.json"
printf '%s\n' "${tampered_lock}" > "${nochange_wt}/package-lock.json"
pre_hook > /dev/null <<EOF
{"tool_name":"Bash","tool_input":{"command":"npm install fixture-parent@1.0.0"},"cwd":"${nochange_wt}"}
EOF
: > "${tmp_root}/emptying-npm-calls.log"
nochange_post=$(
  PATH="${emptying_bin}:${PATH}" post_hook <<EOF
{"tool_name":"Bash","tool_input":{"command":"npm install fixture-parent@1.0.0"},"cwd":"${nochange_wt}"}
EOF
)
grep -q 'suspicious dependency change detected' <<< "${nochange_post}" || fail "the gate still rejects an unapproved closure the command did not change"
[[ -f "${nochange_wt}/node_modules/installed-package/package.json" ]] || fail "a rollback with nothing to roll back leaves the project's node_modules in place"
grep -q 'kept .*/nochange-wt/node_modules$' <<< "$(post_message "${nochange_post}")" || fail "the rollback says node_modules was kept"
grep -q '/nochange-wt/node_modules lists no package.json the pre-command snapshot ' <<< "${nochange_post}" || fail "the rollback says what it looked at before keeping node_modules"
grep -q 'The rollback changed nothing\.' <<< "${nochange_post}" || fail "a rollback that wrote and removed nothing says so"
grep -q 'no install trace in .*/nochange-wt' <<< "${nochange_post}" || fail "the same message says the directory shows no install trace"
if grep -qE '^(ci|install)' "${tmp_root}/emptying-npm-calls.log" 2>/dev/null; then
  fail "a rollback with nothing to roll back runs no npm"
fi
assert_gives_no_command "${nochange_post}" "the rollback with nothing to roll back gives no command"
pass "a rollback with nothing to roll back leaves node_modules in place"

# The same project once the command has written into node_modules without
# touching a lockfile: the tree is no longer the one the pre-guard listed, and
# it is removed.
mkdir -p "${nochange_wt}/node_modules/written-package"
pre_hook > /dev/null <<EOF
{"tool_name":"Bash","tool_input":{"command":"npm install fixture-parent@1.0.0"},"cwd":"${nochange_wt}"}
EOF
printf '{"name":"written-later","version":"1.0.0"}\n' > "${nochange_wt}/node_modules/written-package/package.json"
written_post=$(
  PATH="${emptying_bin}:${PATH}" post_hook <<EOF
{"tool_name":"Bash","tool_input":{"command":"npm install fixture-parent@1.0.0"},"cwd":"${nochange_wt}"}
EOF
)
grep -q 'suspicious dependency change detected' <<< "${written_post}" || fail "the gate rejects the unapproved closure again"
[[ ! -e "${nochange_wt}/node_modules" ]] || fail "a node_modules the command wrote into is removed"
grep -q 'removed .*/nochange-wt/node_modules$' <<< "$(post_message "${written_post}")" || fail "the rollback says node_modules was removed"
pass "a rollback removes node_modules once the command has written into it"

# The other two reasons a node_modules is removed, each as the line that says
# it: a .bin entry the pre-command listing lacks, and a node_modules modified
# after the snapshot with nothing new listed.
for reason_case in bin newer; do
  reason_wt="${tmp_root}/reason-${reason_case}-wt"
  mkdir -p "${reason_wt}/node_modules/installed-package" "${reason_wt}/node_modules/.bin"
  printf '{"name":"installed-package","version":"1.0.0"}\n' > "${reason_wt}/node_modules/installed-package/package.json"
  printf '{"dependencies":{"fixture-parent":"1.0.0"}}\n' > "${reason_wt}/package.json"
  printf '%s\n' "${tampered_lock}" > "${reason_wt}/package-lock.json"
  pre_hook > /dev/null <<EOF
{"tool_name":"Bash","tool_input":{"command":"npm install fixture-parent@1.0.0"},"cwd":"${reason_wt}"}
EOF
  case "${reason_case}" in
    bin) : > "${reason_wt}/node_modules/.bin/new-entry" ;;
    newer) sleep 1; : > "${reason_wt}/node_modules/.yarn-integrity" ;;
  esac
  reason_post=$(
    PATH="${emptying_bin}:${PATH}" post_hook <<EOF
{"tool_name":"Bash","tool_input":{"command":"npm install fixture-parent@1.0.0"},"cwd":"${reason_wt}"}
EOF
  )
  [[ ! -e "${reason_wt}/node_modules" ]] || fail "a node_modules the command wrote into is removed (${reason_case})"
  case "${reason_case}" in
    bin) grep -q '/node_modules/.bin lists new-entry, which the pre-command snapshot .* does not$' <<< "$(post_message "${reason_post}")" \
           || fail "the removal says which .bin entry the snapshot lacks (${reason_post})" ;;
    newer) grep -q '/reason-newer-wt/node_modules is newer than the pre-command snapshot ' <<< "$(post_message "${reason_post}")" \
           || fail "the removal says node_modules is newer than the snapshot (${reason_post})" ;;
  esac
done
pass "every removal of node_modules says the first check that showed the command wrote it"

# A write that lists nothing new and finishes at once: the hidden lockfile is
# rewritten in place right after the pre-guard, the way a fast `npm ci` that
# replaces a package does. The shell's -nt compares whole seconds on bash 3.2
# and called this unwritten; find compares the full timestamp.
inplace_wt="${tmp_root}/inplace-wt"
mkdir -p "${inplace_wt}/node_modules/installed-package" "${inplace_wt}/node_modules/.bin"
printf '{"name":"installed-package","version":"1.0.0"}\n' > "${inplace_wt}/node_modules/installed-package/package.json"
printf '{"name":"inplace-wt","lockfileVersion":3,"packages":{}}\n' > "${inplace_wt}/node_modules/.package-lock.json"
printf '{"dependencies":{"fixture-parent":"1.0.0"}}\n' > "${inplace_wt}/package.json"
printf '%s\n' "${tampered_lock}" > "${inplace_wt}/package-lock.json"
pre_hook > /dev/null <<EOF
{"tool_name":"Bash","tool_input":{"command":"npm ci"},"cwd":"${inplace_wt}"}
EOF
printf '{"name":"inplace-wt","lockfileVersion":3,"packages":{"node_modules/installed-package":{"version":"2.0.0"}}}\n' > "${inplace_wt}/node_modules/.package-lock.json"
inplace_post=$(
  PATH="${emptying_bin}:${PATH}" post_hook <<EOF
{"tool_name":"Bash","tool_input":{"command":"npm ci"},"cwd":"${inplace_wt}"}
EOF
)
grep -q 'suspicious dependency change detected' <<< "${inplace_post}" || fail "the gate rejects the unapproved closure after an in-place write"
[[ ! -e "${inplace_wt}/node_modules" ]] || fail "a node_modules rewritten in place within the snapshot's second is removed"
pass "a rollback sees a write that finished within the second the snapshot was taken in"

# A confirmed snapshot older than what the command found. An approved install
# is confirmed, the lockfile then changes outside the gate (a pull, a
# checkout), and a command that writes nothing is read as an install. The
# restore goes to the older snapshot, so it puts files back; the command still
# wrote none of them, and node_modules stays.
lag_wt="${tmp_root}/lag-wt"
mkdir -p "${lag_wt}/node_modules/installed-package" "${lag_wt}/node_modules/.bin"
printf '{"name":"installed-package","version":"1.0.0"}\n' > "${lag_wt}/node_modules/installed-package/package.json"
printf '{"dependencies":{"fixture-parent":"1.0.0"}}\n' > "${lag_wt}/package.json"
cp "${tmp_root}/revert-safe-lock.json" "${lag_wt}/package-lock.json"
pre_hook > /dev/null <<EOF
{"tool_name":"Bash","tool_input":{"command":"npm install fixture-parent@1.0.0"},"cwd":"${lag_wt}"}
EOF
lag_first_post=$(
  PATH="${emptying_bin}:${PATH}" post_hook <<EOF
{"tool_name":"Bash","tool_input":{"command":"npm install fixture-parent@1.0.0"},"cwd":"${lag_wt}"}
EOF
)
if grep -q 'suspicious dependency change detected' <<< "${lag_first_post}"; then
  fail "the approved install that sets the confirmed snapshot is not rolled back"
fi
printf '%s\n' "${tampered_lock}" > "${lag_wt}/package-lock.json"
pre_hook > /dev/null <<EOF
{"tool_name":"Bash","tool_input":{"command":"npm ci"},"cwd":"${lag_wt}"}
EOF
lag_post=$(
  PATH="${emptying_bin}:${PATH}" post_hook <<EOF
{"tool_name":"Bash","tool_input":{"command":"npm ci"},"cwd":"${lag_wt}"}
EOF
)
grep -q 'suspicious dependency change detected' <<< "${lag_post}" || fail "the gate rejects the closure that changed outside it"
[[ -f "${lag_wt}/node_modules/installed-package/package.json" ]] || fail "a file the restore put back from an older snapshot does not count as written by the command"
grep -q 'kept .*/lag-wt/node_modules$' <<< "$(post_message "${lag_post}")" || fail "the rollback says node_modules was kept after restoring from an older snapshot"
grep -q '^when this rollback began, none of .* in .*/lag-wt differed from the pre-command snapshot ' <<< "$(post_message "${lag_post}")" \
  || fail "the rollback says the node files matched the snapshot from before the command, not the one it restored"
grep -q '^restored .*/lag-wt/package-lock.json$' <<< "$(post_message "${lag_post}")" || fail "the rollback still restores the lockfile from the older snapshot"
pass "a rollback to an older confirmed snapshot leaves node_modules in place when the command wrote nothing"

# A project that keeps another manager's lockfile. After the restore it has a
# package.json and no npm lockfile, and the rollback says exactly that: "no
# lockfile" would be false next to a yarn.lock.
yarn_wt="${tmp_root}/yarn-wt"
mkdir -p "${yarn_wt}/node_modules/installed-package"
printf '{"dependencies":{}}\n' > "${yarn_wt}/package.json"
: > "${yarn_wt}/yarn.lock"
pre_hook > /dev/null <<EOF
{"tool_name":"Bash","tool_input":{"command":"npm install fixture-parent@1.0.0"},"cwd":"${yarn_wt}"}
EOF
printf '%s\n' "${tampered_lock}" > "${yarn_wt}/package-lock.json"
yarn_post=$(
  PATH="${emptying_bin}:${PATH}" post_hook <<EOF
{"tool_name":"Bash","tool_input":{"command":"npm install fixture-parent@1.0.0"},"cwd":"${yarn_wt}"}
EOF
)
grep -q 'suspicious dependency change detected' <<< "${yarn_post}" || fail "reorg fires in a project that keeps a yarn.lock"
[[ -f "${yarn_wt}/yarn.lock" ]] || fail "the rollback leaves the yarn.lock it found"
grep -q '/yarn-wt/package-lock.json does not exist$' <<< "$(post_message "${yarn_post}")" && grep -q '/yarn-wt/npm-shrinkwrap.json does not exist$' <<< "$(post_message "${yarn_post}")" \
  || fail "the rollback names the npm lockfiles it looked for"
if grep -q 'no lockfile' <<< "${yarn_post}"; then
  fail "the rollback does not call a yarn project lockless"
fi
assert_gives_no_command "${yarn_post}" "the rollback in a yarn project gives no command"
pass "a rollback next to another manager's lockfile says which lockfiles are missing"

# node_modules that cannot be removed: the rollback says it is still there and
# gives no command. A read-only directory stops rm for an ordinary user; root
# removes it anyway (the CI image runs as root), so the row is for the others.
# It is also only for a filesystem where a read-only directory does stop rm.
# On a Windows drive mounted in WSL1 without metadata a directory's mode is not
# kept, so `chmod 555` on it stops nothing: the rollback removed the whole
# tree, and this row's own chmod 755 failed on a path that was gone and ended
# the battery under set -e (measured in WSL1 on DrvFs, 2026-10-06). So the row
# asks the filesystem first, and a row that is not run says so as a skipped
# row, where the verdict and a reader of the log look for one.
ro_probe="${tmp_root}/ro-probe"; mkdir -p "${ro_probe}/d"; : > "${ro_probe}/d/f"
chmod 555 "${ro_probe}/d" 2>/dev/null || true
if rm -f "${ro_probe}/d/f" 2>/dev/null; then ro_stops_rm=no; else ro_stops_rm=yes; fi
chmod 755 "${ro_probe}/d" 2>/dev/null || true; rm -rf "${ro_probe}"
if [[ "$(id -u)" == 0 ]]; then
  pass "a rollback that cannot remove node_modules: SKIPPED (root removes a read-only directory)"
elif [[ "${ro_stops_rm}" != yes ]]; then
  pass "a rollback that cannot remove node_modules: SKIPPED (a read-only directory does not stop rm on this filesystem)"
fi
if [[ "$(id -u)" != 0 && "${ro_stops_rm}" == yes ]]; then
  stuck_wt="${tmp_root}/stuck-wt"
  mkdir -p "${stuck_wt}/node_modules/locked-package"
  : > "${stuck_wt}/node_modules/locked-package/index.js"
  mkdir -p "${stuck_wt}/node_modules/removable-package"
  printf '{"dependencies":{"fixture-parent":"1.0.0"}}\n' > "${stuck_wt}/package.json"
  cp "${tmp_root}/revert-safe-lock.json" "${stuck_wt}/package-lock.json"
  pre_hook > /dev/null <<EOF
{"tool_name":"Bash","tool_input":{"command":"npm install fixture-parent@1.0.0"},"cwd":"${stuck_wt}"}
EOF
  printf '%s\n' "${tampered_lock}" > "${stuck_wt}/package-lock.json"
  chmod 555 "${stuck_wt}/node_modules/locked-package"
  stuck_post=$(
    PATH="${emptying_bin}:${PATH}" post_hook <<EOF
{"tool_name":"Bash","tool_input":{"command":"npm install fixture-parent@1.0.0"},"cwd":"${stuck_wt}"}
EOF
  )
  chmod 755 "${stuck_wt}/node_modules/locked-package"
  grep -q 'suspicious dependency change detected' <<< "${stuck_post}" || fail "reorg fires where node_modules cannot be removed"
  [[ ! -e "${stuck_wt}/node_modules/removable-package" && -e "${stuck_wt}/node_modules/locked-package/index.js" ]] \
    || fail "this row removes part of node_modules and leaves part, or it does not test what the line may say"
  grep -qE 'not removed .*/stuck-wt/node_modules: removal returned OS error 13; .*/stuck-wt/node_modules exists$' <<< "$(post_message "${stuck_post}")" \
    || fail "the rollback says the node_modules it could not remove is still there"
  # rm -rf removes what it can before it fails, so the line says the path
  # exists and nothing about what is left in it.
  if grep -q 'whatever this install wrote' <<< "${stuck_post}"; then
    fail "the rollback does not say what is left in a node_modules it could not remove"
  fi
  assert_gives_no_command "${stuck_post}" "the rollback that could not remove node_modules gives no command"
  cmp -s "${stuck_wt}/package-lock.json" "${tmp_root}/revert-safe-lock.json" || fail "the lockfile is still restored where node_modules cannot be removed"
  pass "a rollback that cannot remove node_modules says so and gives no command"
fi

# `npm install --no-save <pkg>` in a directory without package.json writes
# node_modules (with npm's hidden lockfile) and nothing else. That is still an
# npm project to the rollback, and its node_modules is removed.
nosave_wt="${tmp_root}/nosave-wt"
mkdir -p "${nosave_wt}"
pre_hook > /dev/null <<EOF
{"tool_name":"Bash","tool_input":{"command":"npm install --no-save fixture-parent@1.0.0"},"cwd":"${nosave_wt}"}
EOF
mkdir -p "${nosave_wt}/node_modules/.bin" "${nosave_wt}/node_modules/fixture-parent"
printf '{"name":"nosave-wt","lockfileVersion":3,"packages":{}}\n' > "${nosave_wt}/node_modules/.package-lock.json"
printf '{"name":"fixture-parent","version":"1.0.0"}\n' > "${nosave_wt}/node_modules/fixture-parent/package.json"
cp /bin/echo "${nosave_wt}/node_modules/.bin/native-drop"
nosave_post=$(
  PATH="${emptying_bin}:${PATH}" post_hook <<EOF
{"tool_name":"Bash","tool_input":{"command":"npm install --no-save fixture-parent@1.0.0"},"cwd":"${nosave_wt}"}
EOF
)
grep -q 'suspicious dependency change detected' <<< "${nosave_post}" || fail "reorg fires on a native binary in a --no-save install"
[[ ! -e "${nosave_wt}/node_modules" ]] || fail "a rollback removes the node_modules of a --no-save install with no package.json"
grep -q '/nosave-wt/package.json does not exist$' <<< "$(post_message "${nosave_post}")" || fail "the --no-save rollback says there is no package.json"
# The restore target is the last confirmed snapshot, which can be older than
# this install, so what the project held "before this install" is not
# something the rollback knows. It states only what is there now.
if grep -q 'before this install' <<< "${nosave_post}"; then
  fail "the rollback does not infer what the project held before this install"
fi
assert_gives_no_command "${nosave_post}" "the --no-save rollback gives no command"
pass "a rollback removes the node_modules a --no-save install wrote without a package.json"

# The same --no-save install through a node_modules that links elsewhere: the
# hidden lockfile is read through the link, the project is an npm project, and
# the removal is refused and named rather than reported as nothing.
nosave_link_wt="${tmp_root}/nosave-link-wt"
nosave_link_target="${tmp_root}/nosave-link-target"
mkdir -p "${nosave_link_wt}" "${nosave_link_target}/.bin"
# A relative link: its text ("../nosave-link-target") does not resolve from
# the reader's directory, so the message names the physical path instead.
ln -s ../nosave-link-target "${nosave_link_wt}/node_modules"
nosave_link_physical=$(cd -P "${nosave_link_target}" && pwd -P)
pre_hook > /dev/null <<EOF
{"tool_name":"Bash","tool_input":{"command":"npm install --no-save fixture-parent@1.0.0"},"cwd":"${nosave_link_wt}"}
EOF
printf '{"name":"nosave-link-wt","lockfileVersion":3,"packages":{}}\n' > "${nosave_link_target}/.package-lock.json"
cp /bin/echo "${nosave_link_target}/.bin/native-drop"
nosave_link_post=$(
  PATH="${emptying_bin}:${PATH}" post_hook <<EOF
{"tool_name":"Bash","tool_input":{"command":"npm install --no-save fixture-parent@1.0.0"},"cwd":"${nosave_link_wt}"}
EOF
)
grep -q 'suspicious dependency change detected' <<< "${nosave_link_post}" || fail "reorg fires on a native binary through a linked node_modules"
grep -q 'refused removal of .*/nosave-link-wt/node_modules: ' <<< "${nosave_link_post}" || fail "the rollback names the linked node_modules it will not remove"
grep -qx "refused removal of .*/nosave-link-wt/node_modules: .*/nosave-link-wt/node_modules is a symbolic link to ${nosave_link_physical}" <<< "$(jq -r '.systemMessage' <<< "${nosave_link_post}")" || fail "a refused relative link is named by its physical path"
assert_gives_no_command "${nosave_link_post}" "the rollback through a linked node_modules gives no command"
[[ -f "${nosave_link_target}/.package-lock.json" ]] || fail "a rollback leaves the target of a linked node_modules alone"
pass "a rollback names a linked node_modules a --no-save install wrote through"

# --- The report grammar: one row per line form the rows above do not reach ----
#
# The oracle's form table fails on a form no line matched, so each form has a
# row here that makes the hook print it. A row asserts the phrase it is about;
# whether the line is true is the oracle's to say, in post_hook.
# A third argument is the call's tool_use_id, which both hooks of one call
# receive; the backstop's trace entry is kept under it.
grammar_pre() {
  local id_field=""
  [[ -z "${3:-}" ]] || id_field=",\"tool_use_id\":\"$3\""
  pre_hook <<EOF
{"tool_name":"Bash","tool_input":{"command":"$2"},"cwd":"$1"${id_field}}
EOF
}
grammar_pre_codex() {
  local id_field=""
  [[ -z "${3:-}" ]] || id_field=",\"tool_use_id\":\"$3\""
  pre_hook <<EOF
{"tool_name":"Bash","tool_input":{"command":"$2"},"cwd":"$1","turn_id":"turn-e2e","model":"codex-test"${id_field}}
EOF
}
grammar_post_codex() {
  local id_field=""
  [[ -z "${3:-}" ]] || id_field=",\"tool_use_id\":\"$3\""
  post_hook <<EOF
{"tool_name":"Bash","tool_input":{"command":"$2"},"cwd":"$1","turn_id":"turn-e2e","model":"codex-test"${id_field}}
EOF
}
grammar_post() {
  local id_field=""
  [[ -z "${3:-}" ]] || id_field=",\"tool_use_id\":\"$3\""
  post_hook <<EOF
{"tool_name":"Bash","tool_input":{"command":"$2"},"cwd":"$1"${id_field}}
EOF
}
grammar_project() {
  mkdir -p "$1"
  printf '{"dependencies":{"fixture-parent":"1.0.0"}}\n' > "$1/package.json"
  cp "${tmp_root}/revert-safe-lock.json" "$1/package-lock.json"
}
# The pending state the pre-guard left for a project.
grammar_pending() { grep -lF "\"$(cd -P "$1" && pwd -P)\"" "${SAFEDEPS_HOME}/pending"/*.json | head -1; }

# A rollback to a confirmed snapshot, after an install safedeps made inert:
# the verified install confirms its own state, and the next one is rejected.
confirmed_wt="${tmp_root}/confirmed-wt"
grammar_project "${confirmed_wt}"
grammar_pre "${confirmed_wt}" "npm install fixture-parent@1.0.0" > /dev/null
touch "${confirmed_wt}/package-lock.json"
confirmed_first=$(PATH="${stub_bin}:${PATH}" grammar_post "${confirmed_wt}" "npm install --ignore-scripts fixture-parent@1.0.0 --ignore-scripts")
[[ -z "${confirmed_first}" ]] || fail "a verified install with nothing to rebuild is confirmed quietly (${confirmed_first})"
grammar_pre "${confirmed_wt}" "npm install fixture-parent@1.0.0" > /dev/null
printf '%s\n' "${tampered_lock}" > "${confirmed_wt}/package-lock.json"
confirmed_post=$(PATH="${stub_bin}:${PATH}" grammar_post "${confirmed_wt}" "npm install --ignore-scripts fixture-parent@1.0.0 --ignore-scripts")
grep -q ', a confirmed snapshot$' <<< "$(post_message "${confirmed_post}")" || fail "a rollback to a confirmed snapshot says the snapshot is a confirmed one"
grep -q '^safedeps added --ignore-scripts to this install$' <<< "$(post_message "${confirmed_post}")" \
  || fail "a rollback after an inert install says safedeps added --ignore-scripts"
cmp -s "${confirmed_wt}/package-lock.json" "${tmp_root}/revert-safe-lock.json" || fail "the rollback restores the confirmed lockfile"
pass "a rollback to a confirmed snapshot says so, and says the install ran with --ignore-scripts"

# The same project, the same rejected lockfile, and no pre-guard: the post
# hook finds no record of the command, and the backstop rolls back to the
# confirmed snapshot. With no record it says nothing about --ignore-scripts.
printf '%s\n' "${tampered_lock}" > "${confirmed_wt}/package-lock.json"
mkdir -p "${confirmed_wt}/node_modules/installed-package"
backstop_post=$(PATH="${stub_bin}:${PATH}" grammar_post "${confirmed_wt}" "npm install fixture-parent@1.0.0")
grep -A1 -x 'this rollback has no snapshot from before the command' <<< "$(post_message "${backstop_post}")" | grep -q '^removed .*/confirmed-wt/node_modules$' \
  || fail "the backstop says why it removed node_modules, right before it says so (${backstop_post})"
grep -q 'this hook found no record of this command from before it ran. A rollback ran\.' <<< "${backstop_post}" || fail "the backstop rolls back to the confirmed snapshot"
! grep -q -- '--ignore-scripts' <<< "$(post_message "${backstop_post}")" \
  || fail "the backstop, which found no record of the command, says nothing about --ignore-scripts"
cmp -s "${confirmed_wt}/package-lock.json" "${tmp_root}/revert-safe-lock.json" || fail "the backstop restores the confirmed lockfile"
pass "the backstop's rollback speaks the same lines"

# A command the pre-guard rewrote, whose record the post hook does not find
# (bamdori r18 F4): the rewrite puts --ignore-scripts before a closing quote,
# the post hook's key for the rewritten command is not the pre-guard's key for
# the command, and the backstop rolls back. It used to say "safedeps did not
# add --ignore-scripts" there, of a command safedeps had written. These rows
# hold the line true whether or not the key is ever fixed: the backstop says
# nothing about --ignore-scripts, and the oracle reads every record.
for r18_form in "sh -c 'npm ci'" 'bash -c "npm ci"' "eval 'npm ci'"; do
  r18_wt=$(mktemp -d "${tmp_root}/r18-wt.XXXXXX")
  grammar_project "${r18_wt}"
  grammar_pre "${r18_wt}" "npm install fixture-parent@1.0.0" > /dev/null
  touch "${r18_wt}/package-lock.json"
  r18_first=$(PATH="${stub_bin}:${PATH}" grammar_post "${r18_wt}" "npm install --ignore-scripts fixture-parent@1.0.0 --ignore-scripts")
  [[ -z "${r18_first}" ]] || fail "the project of ${r18_form} has a confirmed snapshot (${r18_first})"
  r18_wrote=$(jq -nc --arg c "${r18_form}" --arg d "${r18_wt}" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}' \
    | pre_hook | jq -r '.hookSpecificOutput.updatedInput.command // empty')
  [[ -n "${r18_wrote}" ]] || fail "the pre-guard rewrites ${r18_form}"
  printf '%s\n' "${tampered_lock}" > "${r18_wt}/package-lock.json"
  r18_post=$(jq -nc --arg c "${r18_wrote}" --arg d "${r18_wt}" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}' \
    | PATH="${stub_bin}:${PATH}" post_hook)
  # Where the post hook's key finds the record (the pending key strips every
  # --ignore-scripts the rewrite put in, a quote after it included), the
  # rollback says what the record states; where it does not, the backstop
  # says nothing about the flag. Either way no line says "did not add".
  if grep -q 'this hook found no record of this command from before it ran. A rollback ran\.' <<< "${r18_post}"; then
    ! grep -q -- '--ignore-scripts' <<< "$(post_message "${r18_post}")" \
      || fail "${r18_wrote}: the backstop says nothing about --ignore-scripts (${r18_post})"
  else
    grep -qx 'safedeps added --ignore-scripts to this install' <<< "$(post_message "${r18_post}")" \
      || fail "${r18_wrote}: a rollback that found the record says safedeps added --ignore-scripts (${r18_post})"
  fi
  cmp -s "${r18_wt}/package-lock.json" "${tmp_root}/revert-safe-lock.json" || fail "${r18_wrote}: the backstop restores the confirmed lockfile"
  rm -f "$(grammar_pending "${r18_wt}")"
done
pass "a rewritten command whose record the post hook does not find gets no --ignore-scripts line"

# A rewrite whose record cannot be written is not sent. The record write used
# to fail quietly and the rewrite went out anyway, so the post hook said "did
# not add" of a command safedeps had written. An archive copy makes only the rewrite writer
# directory readonly after initial snapshot/pending creation; the real writer fails.
markfail_wt=$(mktemp -d "${tmp_root}/markfail-wt.XXXXXX")
grammar_project "${markfail_wt}"
markfail_pre=$(SAFEDEPS_TEST_FAULT=markfail grammar_pre "${markfail_wt}" "npm install fixture-parent@1.0.0")
[[ -z "$(jq -r '.hookSpecificOutput.updatedInput.command // empty' <<< "${markfail_pre:-{\}}")" ]] \
  || fail "a rewrite whose record could not be written is not sent (${markfail_pre})"
grep -q 'pre-guard: could not record the command safedeps would write in .*, so it was not rewritten' "${SAFEDEPS_HOME}/advisory.log" \
  || fail "a rewrite withheld for a failed record is said in advisory.log"
printf '%s\n' "${tampered_lock}" > "${markfail_wt}/package-lock.json"
markfail_post=$(PATH="${stub_bin}:${PATH}" grammar_post "${markfail_wt}" "npm install fixture-parent@1.0.0")
grep -qx 'safedeps did not add --ignore-scripts to this install' <<< "$(post_message "${markfail_post}")" \
  || fail "the install whose rewrite was withheld says safedeps did not add --ignore-scripts (${markfail_post})"
pass "a rewrite whose record cannot be written is not sent, and the rollback says safedeps did not add the flag"

# A record the post hook cannot read gets no --ignore-scripts line. A failed
# read used to fall through to "did not add", which was false of this command:
# safedeps had rewritten it. The fixture removes meta read permission after oracle_before, confirms
# EACCES as the same uid, and supplies record-unread independently of the hook.
markread_wt=$(mktemp -d "${tmp_root}/markread-wt.XXXXXX")
grammar_project "${markread_wt}"
markread_pre=$(grammar_pre "${markread_wt}" "npm install fixture-parent@1.0.0")
[[ "$(jq -r '.hookSpecificOutput.updatedInput.command // empty' <<< "${markread_pre:-{\}}")" == 'npm install --ignore-scripts fixture-parent@1.0.0 --ignore-scripts' ]] \
  || fail "the install whose record the post hook will not read is rewritten (${markread_pre})"
printf '%s\n' "${tampered_lock}" > "${markread_wt}/package-lock.json"
markread_post=$(SAFEDEPS_TEST_FAULT=markread PATH="${stub_bin}:${PATH}" grammar_post "${markread_wt}" "npm install fixture-parent@1.0.0")
grep -q 'A rollback ran\.' <<< "$(post_message "${markread_post}")" \
  || fail "the install whose record the post hook cannot read is rolled back (${markread_post})"
! grep -q -- '--ignore-scripts' <<< "$(post_message "${markread_post}")" \
  || fail "a record the post hook cannot read gets no --ignore-scripts line (${markread_post})"
grep -q "post-verify: could not read the pre-guard's record of this command in .*, so no --ignore-scripts line was said" "${SAFEDEPS_HOME}/advisory.log" \
  || fail "a record the post hook cannot read is said in advisory.log"
pass "a record the post hook cannot read gets no --ignore-scripts line, and advisory.log says so"

# A line is said only from a fact the record states as version 2. Each shape
# below is a record that lacks the fact a line needs, and each used to be
# answered by its missing field: a v2.17.2 record of a rewrite holds no
# updated_command and was compared with null ("asked", bamdori r22 U3); a
# v2.17.2 false does not mean no rewrite, since its write could fail and the
# rewrite went out (U3b, koon judgment); and a string "true", a null command
# and another version went to "did not add" or "asked". A version written as
# the string "2" and a command that is a number are not version 2 facts
# either; no pre-guard writes them, and these rows hold the code to that
# (bamdori r23 XStr2 passed the suite before them). The
# pre-guard writes a version 2 record and the row rewrites it into the shape,
# as an upgrade or a damaged file would leave it. The post hook receives the
# command safedeps wrote. Each says no --ignore-scripts line, and advisory.log
# names the record once.
for unstated_shape in v2172-true v2172-false string-true null-command number-command record-3 record-str2; do
  unstated_wt=$(mktemp -d "${tmp_root}/unstated-${unstated_shape}-wt.XXXXXX")
  grammar_project "${unstated_wt}"
  unstated_pre=$(grammar_pre "${unstated_wt}" "npm install fixture-parent@1.0.0")
  [[ "$(jq -r '.hookSpecificOutput.updatedInput.command // empty' <<< "${unstated_pre:-{\}}")" == 'npm install --ignore-scripts fixture-parent@1.0.0 --ignore-scripts' ]] \
    || fail "${unstated_shape}: the install is rewritten (${unstated_pre})"
  unstated_meta="${SAFEDEPS_HOME}/snapshots/$(jq -r '.snapshot_id' "$(grammar_pending "${unstated_wt}")")_meta.json"
  case "${unstated_shape}" in
    v2172-true) unstated_jq='del(.record, .updated_command)' ;;
    v2172-false) unstated_jq='del(.record, .updated_command) | .ignore_scripts_injected = false' ;;
    string-true) unstated_jq='.ignore_scripts_injected = "true"' ;;
    null-command) unstated_jq='.updated_command = null' ;;
    number-command) unstated_jq='.updated_command = 5' ;;
    record-3) unstated_jq='.record = 3' ;;
    record-str2) unstated_jq='.record = "2"' ;;
  esac
  jq "${unstated_jq}" "${unstated_meta}" > "${unstated_meta}.tmp" && mv -f "${unstated_meta}.tmp" "${unstated_meta}"
  printf '%s\n' "${tampered_lock}" > "${unstated_wt}/package-lock.json"
  unstated_post=$(PATH="${stub_bin}:${PATH}" grammar_post "${unstated_wt}" "npm install --ignore-scripts fixture-parent@1.0.0 --ignore-scripts")
  grep -q 'A rollback ran\.' <<< "$(post_message "${unstated_post}")" \
    || fail "${unstated_shape}: the install is rolled back (${unstated_post})"
  ! grep -q -- '--ignore-scripts' <<< "$(post_message "${unstated_post}")" \
    || fail "${unstated_shape}: a record that does not state the fact gets no --ignore-scripts line (${unstated_post})"
  [[ "$(grep -cF "post-verify: ${unstated_meta} is not a version 2 pre-guard record that states whether safedeps rewrote this command, so no --ignore-scripts line was said" "${SAFEDEPS_HOME}/advisory.log")" == 1 ]] \
    || fail "${unstated_shape}: advisory.log names the record once"
  rm -f "$(grammar_pending "${unstated_wt}")"
done
pass "a record that does not state, as version 2, whether safedeps rewrote the command gets no --ignore-scripts line (v2.17.2 true and false, a string, a null or number command, another version, the version as a string)"

# No record file at all says no line either; it used to be "did not add". The
# post hook sends a pending state whose meta is missing as it starts to the
# backstop, which says no --ignore-scripts line, so only a record that goes
# between that check and the report reaches the fact functions without one;
# the row calls them directly, as the unresolved directory row does.
nofile_meta="${tmp_root}/nofile-meta.json"
nofile_log="${tmp_root}/nofile-advisory.log"
nofile_input='{"tool_name":"Bash","tool_input":{"command":"npm install x --ignore-scripts"}}'
nofile_lines=$(python3 "${ROOT_DIR}/scripts/measure/core-post-direct-call.py" --core "${NATIVE_TEST_CORE}" --meta "${nofile_meta}" --input "${nofile_input}" --project "${tmp_root}/no-such-project" --kind missing --log-body "${nofile_log}")
oracle_direct "${nofile_meta}" "${nofile_input}" "${nofile_lines}" || exit 1
! grep -q -- '--ignore-scripts' <<< "${nofile_lines}" || fail "no record file gets no --ignore-scripts line (${nofile_lines})"
[[ "$(cat "${nofile_log}" 2>/dev/null)" == "post-verify: ${nofile_meta} is not a version 2 pre-guard record that states whether safedeps rewrote this command, so no --ignore-scripts line was said" ]] \
  || fail "no record file is named once in advisory.log ($(cat "${nofile_log}" 2>/dev/null))"
pass "no record file gets no --ignore-scripts line, and advisory.log names the record"

# A record that is not one JSON object is one the hook cannot read (7b8eb0e):
# here two objects, the first of which would say "did not add". The row marks
# record-unread for the oracle, as the row of a failed read does, and the jq
# that reads it is the real one.
twoobj_wt=$(mktemp -d "${tmp_root}/twoobj-wt.XXXXXX")
grammar_project "${twoobj_wt}"
twoobj_pre=$(grammar_pre "${twoobj_wt}" "npm install fixture-parent@1.0.0")
[[ -n "$(jq -r '.hookSpecificOutput.updatedInput.command // empty' <<< "${twoobj_pre:-{\}}")" ]] \
  || fail "the install whose record becomes two objects is rewritten (${twoobj_pre})"
twoobj_meta="${SAFEDEPS_HOME}/snapshots/$(jq -r '.snapshot_id' "$(grammar_pending "${twoobj_wt}")")_meta.json"
{ printf '{"record":2,"ignore_scripts_injected":false}\n'; cat "${twoobj_meta}"; } > "${twoobj_meta}.tmp" && mv -f "${twoobj_meta}.tmp" "${twoobj_meta}"
printf '%s\n' "${tampered_lock}" > "${twoobj_wt}/package-lock.json"
twoobj_post=$(SAFEDEPS_TEST_FAULT=twoobj PATH="${stub_bin}:${PATH}" grammar_post "${twoobj_wt}" "npm install --ignore-scripts fixture-parent@1.0.0 --ignore-scripts")
grep -q 'A rollback ran\.' <<< "$(post_message "${twoobj_post}")" \
  || fail "the install whose record is two objects is rolled back (${twoobj_post})"
! grep -q -- '--ignore-scripts' <<< "$(post_message "${twoobj_post}")" \
  || fail "a record that is two objects gets no --ignore-scripts line (${twoobj_post})"
[[ "$(grep -cF "post-verify: could not read the pre-guard's record of this command in ${twoobj_meta}, so no --ignore-scripts line was said" "${SAFEDEPS_HOME}/advisory.log")" == 1 ]] \
  || fail "a record that is two objects is said in advisory.log once"
rm -f "$(grammar_pending "${twoobj_wt}")"
pass "a record that is not one JSON object gets no --ignore-scripts line, and advisory.log says it could not be read"

# A command reaches the backstop through a record only when its call has no
# trace entry (the post hook reads the entry before any record), and a call
# with no entry counts as traced. advisory.log says both.
record_traced_count() {
  { grep -cF "post-verify BACKSTOP traced: the command reached the backstop through a pre-guard record, and " "${SAFEDEPS_HOME}/advisory.log" || true; }
}
bs_entry() { printf '%s/pending/backstop/id-%s.json' "${2:-${SAFEDEPS_HOME}}" "$1"; }

# A pending state whose snapshot has no meta file. The post hook used to exit
# there with nothing said, so the install was never judged (bamdori r23, as
# old as e315244): an unapproved lockfile passed with exit 0, no output and no
# advisory.log line. Pending files last 24 hours and the snapshot cleanup
# prunes metas past the ten newest, so the shape is a real one. Now
# advisory.log names the record, the record is set aside, and the backstop
# judges the command, with a head that says the record was found and its
# snapshot has no meta file. The oracle holds the advisory line once per such
# call and each head to the record it claims.
gone_meta_of() { printf '%s/snapshots/%s_meta.json' "${SAFEDEPS_HOME}" "$(jq -r '.snapshot_id' "$1")"; }
gone_line_of() {
  printf "post-verify: the pre-guard's record %s names the snapshot %s, and %s is not a file; this hook set the record aside, and the command goes to the command-independent backstop" \
    "$1" "$(jq -r '.snapshot_id' "$1")" "$(gone_meta_of "$1")"
}

# A: the meta goes after the pre-guard, and the install changed nothing the
# backstop rejects. It is judged clean, and advisory.log says both.
gone_a_wt=$(mktemp -d "${tmp_root}/gone-a-wt.XXXXXX")
grammar_project "${gone_a_wt}"
grammar_pre "${gone_a_wt}" "npm install fixture-parent@1.0.0" > /dev/null
gone_a_pending=$(grammar_pending "${gone_a_wt}")
rm -f "$(gone_meta_of "${gone_a_pending}")"
gone_a_line=$(gone_line_of "${gone_a_pending}")
gone_a_post=$(PATH="${stub_bin}:${PATH}" grammar_post "${gone_a_wt}" "npm install fixture-parent@1.0.0 --ignore-scripts")
[[ "$(grep -cF "${gone_a_line}" "${SAFEDEPS_HOME}/advisory.log")" == 1 ]] \
  || fail "A: advisory.log names the record whose snapshot has no meta file once"
grep -qF "post-verify BACKSTOP clean: a command whose pre-guard record names a snapshot with no meta file; the npm closure in $(cd -P "${gone_a_wt}" && pwd -P) passed" "${SAFEDEPS_HOME}/advisory.log" \
  || fail "A: the backstop judges the install and says it passed (${gone_a_post})"
[[ ! -e "${gone_a_pending}" ]] || fail "A: the record is set aside"
pass "a record whose snapshot has no meta file is named in advisory.log, and the backstop judges the install"

# B: two pre-guard calls of the same command in one project, the first
# record's meta gone, and an unapproved lockfile. The post hook consumes the
# first record, as the glob orders it. With no confirmed snapshot the backstop
# flags the install and rolls nothing back; it used to pass with nothing said.
gone_b_wt=$(mktemp -d "${tmp_root}/gone-b-wt.XXXXXX")
grammar_project "${gone_b_wt}"
grammar_pre "${gone_b_wt}" "npm install fixture-parent@1.0.0" > /dev/null
grammar_pre "${gone_b_wt}" "npm install fixture-parent@1.0.0" > /dev/null
gone_b_pending=$(grammar_pending "${gone_b_wt}")
[[ "$(grep -lF "\"$(cd -P "${gone_b_wt}" && pwd -P)\"" "${SAFEDEPS_HOME}/pending"/*.json | wc -l | tr -d ' ')" == 2 ]] \
  || fail "B: the two pre-guard calls leave a record each"
rm -f "$(gone_meta_of "${gone_b_pending}")"
gone_b_line=$(gone_line_of "${gone_b_pending}")
printf '%s\n' "${tampered_lock}" > "${gone_b_wt}/package-lock.json"
gone_b_post=$(PATH="${stub_bin}:${PATH}" grammar_post "${gone_b_wt}" "npm install fixture-parent@1.0.0 --ignore-scripts")
grep -qx 'safedeps: suspicious dependency change detected; this hook found a pre-guard record, and the snapshot it names has no meta file. No rollback ran.' <<< "$(post_message "${gone_b_post}")" \
  || fail "B: the backstop flags the unapproved lockfile, and says the record was found and its snapshot has no meta file (${gone_b_post})"
[[ "$(grep -cF "${gone_b_line}" "${SAFEDEPS_HOME}/advisory.log")" == 1 ]] \
  || fail "B: advisory.log names the record whose snapshot has no meta file once"
grep -qF "post-verify BACKSTOP FLAGGED (no baseline): a command whose pre-guard record names a snapshot with no meta file; the npm closure in $(cd -P "${gone_b_wt}" && pwd -P) failed" "${SAFEDEPS_HOME}/advisory.log" \
  || fail "B: advisory.log says the backstop flagged the install"
[[ ! -e "${gone_b_pending}" ]] || fail "B: the record is set aside"
for gone_b_left in $(grep -lF "\"$(cd -P "${gone_b_wt}" && pwd -P)\"" "${SAFEDEPS_HOME}/pending"/*.json); do rm -f "${gone_b_left}"; done
pass "a record whose snapshot has no meta file goes to the backstop, which flags an unapproved lockfile"

# B with a confirmed snapshot: the backstop rolls back to it, under the same head.
gone_c_wt=$(mktemp -d "${tmp_root}/gone-c-wt.XXXXXX")
grammar_project "${gone_c_wt}"
grammar_pre "${gone_c_wt}" "npm install fixture-parent@1.0.0" > /dev/null
touch "${gone_c_wt}/package-lock.json"
gone_c_first=$(PATH="${stub_bin}:${PATH}" grammar_post "${gone_c_wt}" "npm install fixture-parent@1.0.0 --ignore-scripts")
[[ -z "${gone_c_first}" ]] || fail "C: the project has a confirmed snapshot (${gone_c_first})"
grammar_pre "${gone_c_wt}" "npm install fixture-parent@1.0.0" toolu_gone_c > /dev/null
gone_c_pending=$(grammar_pending "${gone_c_wt}")
rm -f "$(gone_meta_of "${gone_c_pending}")"
printf '%s\n' "${tampered_lock}" > "${gone_c_wt}/package-lock.json"
record_traced_before=$(record_traced_count)
gone_c_post=$(PATH="${stub_bin}:${PATH}" grammar_post "${gone_c_wt}" "npm install fixture-parent@1.0.0 --ignore-scripts" toolu_gone_c)
grep -qx 'safedeps: suspicious dependency change detected; this hook found a pre-guard record, and the snapshot it names has no meta file. A rollback ran.' <<< "$(post_message "${gone_c_post}")" \
  || fail "C: the backstop rolls back, and says the record was found and its snapshot has no meta file (${gone_c_post})"
! grep -q -- '--ignore-scripts' <<< "$(post_message "${gone_c_post}")" \
  || fail "C: the backstop says nothing about --ignore-scripts (${gone_c_post})"
cmp -s "${gone_c_wt}/package-lock.json" "${tmp_root}/revert-safe-lock.json" || fail "C: the backstop restores the confirmed lockfile"
[[ "$(record_traced_count)" == "$(( record_traced_before + 1 ))" && ! -e "$(bs_entry toolu_gone_c)" ]] \
  || fail "C: this call has no trace entry, and the backstop counts the command as traced for the record"
pass "a record whose snapshot has no meta file goes to the backstop, which rolls back to a confirmed snapshot"

# A record that names no snapshot. The pre-guard always writes one, so an empty
# id is a damaged pending state. The post hook used to exit there with nothing said, as it did for a missing meta.
# Now advisory.log names the record, the record is set aside, and the backstop
# judges the command, with a head that says the record was found and names no
# snapshot. The oracle holds the advisory line once per such call and each
# head to the record it claims.
empty_line_of() {
  printf "post-verify: the pre-guard's record %s names no snapshot; this hook set the record aside, and the command goes to the command-independent backstop" "$1"
}

# D: a pending state whose snapshot_id is "", an unapproved lockfile, and a
# confirmed snapshot. The backstop rolls back to it.
empty_wt=$(mktemp -d "${tmp_root}/empty-wt.XXXXXX")
grammar_project "${empty_wt}"
grammar_pre "${empty_wt}" "npm install fixture-parent@1.0.0" > /dev/null
touch "${empty_wt}/package-lock.json"
empty_first=$(PATH="${stub_bin}:${PATH}" grammar_post "${empty_wt}" "npm install fixture-parent@1.0.0 --ignore-scripts")
[[ -z "${empty_first}" ]] || fail "D: the project has a confirmed snapshot (${empty_first})"
grammar_pre "${empty_wt}" "npm install fixture-parent@1.0.0" toolu_empty_d > /dev/null
empty_pending=$(grammar_pending "${empty_wt}")
jq '.snapshot_id = ""' "${empty_pending}" > "${empty_pending}.edit" && mv "${empty_pending}.edit" "${empty_pending}"
empty_line=$(empty_line_of "${empty_pending}")
printf '%s\n' "${tampered_lock}" > "${empty_wt}/package-lock.json"
record_traced_before=$(record_traced_count)
empty_post=$(PATH="${stub_bin}:${PATH}" grammar_post "${empty_wt}" "npm install fixture-parent@1.0.0 --ignore-scripts" toolu_empty_d)
grep -qx 'safedeps: suspicious dependency change detected; this hook found a pre-guard record, and the record names no snapshot. A rollback ran.' <<< "$(post_message "${empty_post}")" \
  || fail "D: the backstop rolls back, and says the record was found and names no snapshot (${empty_post})"
[[ "$(grep -cF "${empty_line}" "${SAFEDEPS_HOME}/advisory.log")" == 1 ]] \
  || fail "D: advisory.log names the record that names no snapshot once"
[[ ! -e "${empty_pending}" ]] || fail "D: the record is set aside"
cmp -s "${empty_wt}/package-lock.json" "${tmp_root}/revert-safe-lock.json" || fail "D: the backstop restores the confirmed lockfile"
[[ "$(record_traced_count)" == "$(( record_traced_before + 1 ))" ]] \
  || fail "D: the backstop counts the command as traced for the record"
pass "a pending state that names no snapshot goes to the backstop, which rolls back to a confirmed snapshot"

# E: a record a pre-#5 pre-guard left, an empty current_snapshot_id for this
# project, with an unapproved lockfile and no confirmed snapshot. No current
# pre-guard writes it, and it names no call. It was read as this command's
# record, and a call it did not match ended the hook with no judgment ("SKIP
# ... bounded no-op"). It is not read now: the backstop judges the install as
# one with no record, and the file stays.
legacy_wt=$(mktemp -d "${tmp_root}/legacy-wt.XXXXXX")
grammar_project "${legacy_wt}"
: > "${SAFEDEPS_HOME}/current_snapshot_id"
printf '%s\n' "$(cd -P "${legacy_wt}" && pwd -P)" > "${SAFEDEPS_HOME}/current_project_dir"
printf '%s\n' "${tampered_lock}" > "${legacy_wt}/package-lock.json"
legacy_post=$(PATH="${stub_bin}:${PATH}" grammar_post "${legacy_wt}" "npm install fixture-parent@1.0.0")
grep -qx 'safedeps: suspicious dependency change detected; this hook found no record of this command from before it ran. No rollback ran.' <<< "$(post_message "${legacy_post}")" \
  || fail "E: the backstop flags the unapproved lockfile, and says it found no record (${legacy_post})"
[[ -e "${SAFEDEPS_HOME}/current_snapshot_id" && -e "${SAFEDEPS_HOME}/current_project_dir" ]] || fail "E: the legacy record stays"
rm -f "${SAFEDEPS_HOME}/current_snapshot_id" "${SAFEDEPS_HOME}/current_project_dir"
pass "a record a pre-#5 pre-guard left is not read, and the backstop judges the install"

# F: a record with no project_dir, and a hook whose own working directory is
# another project with an unapproved lockfile. The hook judged and rolled back
# its working directory (`PROJECT_DIR=$(pwd)`), which is wherever the runtime
# started it. It judges and rolls back the directory the payload names.
nodir_wt=$(mktemp -d "${tmp_root}/nodir-wt.XXXXXX")
nodir_other=$(mktemp -d "${tmp_root}/nodir-other.XXXXXX")
grammar_project "${nodir_wt}"
grammar_project "${nodir_other}"
grammar_pre "${nodir_wt}" "npm install fixture-parent@1.0.0" > /dev/null
nodir_pending=$(grammar_pending "${nodir_wt}")
jq '.project_dir = ""' "${nodir_pending}" > "${nodir_pending}.edit" && mv "${nodir_pending}.edit" "${nodir_pending}"
printf '%s\n' "${tampered_lock}" > "${nodir_wt}/package-lock.json"
printf '%s\n' "${tampered_lock}" > "${nodir_other}/package-lock.json"
mkdir -p "${nodir_other}/node_modules/keep-me"
nodir_post=$(cd "${nodir_other}" && PATH="${stub_bin}:${PATH}" grammar_post "${nodir_wt}" "npm install fixture-parent@1.0.0 --ignore-scripts")
grep -qx 'safedeps: suspicious dependency change detected. A rollback ran.' <<< "$(post_message "${nodir_post}")" \
  || fail "F: the install in the payload's directory is rolled back (${nodir_post})"
grep -q "^Project: $(cd -P "${nodir_wt}" && pwd -P)\$" <<< "$(tail -n 20 "${SAFEDEPS_HOME}/reorg.log" | sed 's/^  //')" \
  || fail "F: reorg.log names the payload's directory as the project"
cmp -s "${nodir_wt}/package-lock.json" "${tmp_root}/revert-safe-lock.json" || fail "F: the payload's directory gets its lockfile from before the command back"
[[ "$(cat "${nodir_other}/package-lock.json")" == "${tampered_lock}" && -d "${nodir_other}/node_modules/keep-me" ]] \
  || fail "F: the hook's working directory is not touched"
pass "a record with no project_dir is judged and rolled back in the payload's directory, not the hook's"

# F2: the same through the backstop, with the record's hash naming the other
# project. A record that names no snapshot and no project_dir, whose dir_hash
# is that of Y, the hook's working directory; X and Y each have a confirmed
# snapshot, and Y an unapproved lockfile and a node_modules. The project and
# the hash that picks its confirmed snapshot come from one directory, the
# payload's: X is rolled back to X's confirmed snapshot, and Y is not judged,
# restored or emptied. Before, the hook judged Y with the record's hash, and a
# hash taken from the record beside the payload's directory would have
# restored Y's snapshot into X.
nodir2_x=$(mktemp -d "${tmp_root}/nodir2-x.XXXXXX")
nodir2_y=$(mktemp -d "${tmp_root}/nodir2-y.XXXXXX")
for nodir2_p in "${nodir2_x}" "${nodir2_y}"; do
  grammar_project "${nodir2_p}"
  grammar_pre "${nodir2_p}" "npm install fixture-parent@1.0.0" > /dev/null
  [[ "${nodir2_p}" != "${nodir2_y}" ]] || nodir2_y_hash=$(jq -r '.dir_hash' "$(grammar_pending "${nodir2_y}")")
  touch "${nodir2_p}/package-lock.json"
  nodir2_first=$(PATH="${stub_bin}:${PATH}" grammar_post "${nodir2_p}" "npm install fixture-parent@1.0.0 --ignore-scripts")
  [[ -z "${nodir2_first}" ]] || fail "F2: ${nodir2_p} has a confirmed snapshot (${nodir2_first})"
done
grammar_pre "${nodir2_x}" "npm install fixture-parent@1.0.0" > /dev/null
nodir2_pending=$(grammar_pending "${nodir2_x}")
nodir2_x_hash=$(jq -r '.dir_hash' "${nodir2_pending}")
[[ "${nodir2_x_hash}" != "${nodir2_y_hash}" ]] || fail "F2: X and Y have different hashes"
jq --arg h "${nodir2_y_hash}" '.snapshot_id = "" | .project_dir = "" | .dir_hash = $h' "${nodir2_pending}" > "${nodir2_pending}.edit" \
  && mv "${nodir2_pending}.edit" "${nodir2_pending}"
printf '%s\n' "${tampered_lock}" > "${nodir2_x}/package-lock.json"
printf '%s\n' "${tampered_lock}" > "${nodir2_y}/package-lock.json"
mkdir -p "${nodir2_y}/node_modules/keep-me"
nodir2_post=$(cd "${nodir2_y}" && PATH="${stub_bin}:${PATH}" grammar_post "${nodir2_x}" "npm install fixture-parent@1.0.0 --ignore-scripts")
grep -qx 'safedeps: suspicious dependency change detected; this hook found a pre-guard record, and the record names no snapshot. A rollback ran.' <<< "$(post_message "${nodir2_post}")" \
  || fail "F2: the backstop rolls back the payload's directory (${nodir2_post})"
grep -qx "Rollback snapshot: $(cat "${SAFEDEPS_HOME}/confirmed_${nodir2_x_hash}"), a confirmed snapshot" <<< "$(post_message "${nodir2_post}")" \
  || fail "F2: the rollback restores X's confirmed snapshot, not Y's (${nodir2_post})"
cmp -s "${nodir2_x}/package-lock.json" "${tmp_root}/revert-safe-lock.json" || fail "F2: the payload's directory gets its confirmed lockfile back"
[[ "$(cat "${nodir2_y}/package-lock.json")" == "${tampered_lock}" && -d "${nodir2_y}/node_modules/keep-me" ]] \
  || fail "F2: the hook's working directory is not judged, restored or emptied"
pass "a record with no project_dir and another project's hash is judged with the payload directory's own hash"

# J: a record that names its project X and the dir_hash of another project Z,
# and no snapshot; X and Z each have a confirmed snapshot, and Z's package.json
# carries a marker. The hash that picks the confirmed snapshot is computed from
# the project, never taken from the record: X is rolled back to X's confirmed
# snapshot. With the record's hash, Z's snapshot was restored into X, and X's
# package.json became Z's (bamdori J, measured on 5e77ced).
hashj_x=$(mktemp -d "${tmp_root}/hashj-x.XXXXXX")
hashj_z=$(mktemp -d "${tmp_root}/hashj-z.XXXXXX")
for hashj_p in "${hashj_x}" "${hashj_z}"; do
  grammar_project "${hashj_p}"
  [[ "${hashj_p}" != "${hashj_z}" ]] || printf '{"name":"z-marker","dependencies":{"fixture-parent":"1.0.0"}}\n' > "${hashj_z}/package.json"
  grammar_pre "${hashj_p}" "npm install fixture-parent@1.0.0" > /dev/null
  [[ "${hashj_p}" != "${hashj_z}" ]] || hashj_z_hash=$(jq -r '.dir_hash' "$(grammar_pending "${hashj_z}")")
  touch "${hashj_p}/package-lock.json"
  hashj_first=$(PATH="${stub_bin}:${PATH}" grammar_post "${hashj_p}" "npm install fixture-parent@1.0.0 --ignore-scripts")
  [[ -z "${hashj_first}" ]] || fail "J: ${hashj_p} has a confirmed snapshot (${hashj_first})"
done
cp "${hashj_x}/package.json" "${tmp_root}/hashj-x-package.json"
grammar_pre "${hashj_x}" "npm install fixture-parent@1.0.0" > /dev/null
hashj_pending=$(grammar_pending "${hashj_x}")
hashj_x_hash=$(jq -r '.dir_hash' "${hashj_pending}")
[[ "${hashj_x_hash}" != "${hashj_z_hash}" ]] || fail "J: X and Z have different hashes"
jq --arg h "${hashj_z_hash}" '.snapshot_id = "" | .dir_hash = $h' "${hashj_pending}" > "${hashj_pending}.edit" \
  && mv "${hashj_pending}.edit" "${hashj_pending}"
printf '%s\n' "${tampered_lock}" > "${hashj_x}/package-lock.json"
hashj_post=$(PATH="${stub_bin}:${PATH}" grammar_post "${hashj_x}" "npm install fixture-parent@1.0.0 --ignore-scripts")
grep -qx "Rollback snapshot: $(cat "${SAFEDEPS_HOME}/confirmed_${hashj_x_hash}"), a confirmed snapshot" <<< "$(post_message "${hashj_post}")" \
  || fail "J: the rollback restores X's confirmed snapshot, not Z's (${hashj_post})"
cmp -s "${hashj_x}/package.json" "${tmp_root}/hashj-x-package.json" || fail "J: X's package.json is X's, not Z's"
cmp -s "${hashj_x}/package-lock.json" "${tmp_root}/revert-safe-lock.json" || fail "J: X gets its confirmed lockfile back"
pass "a record's dir_hash does not pick the confirmed snapshot: the project's own hash does"

# A record that is not one JSON object. Its fields were read with jq under
# set -e, so the post hook died there, and the record, left in place, killed it
# again for the same command for 24 hours while the entry shim blamed the
# checkout. Now advisory.log names the record, the record is set aside, and the
# backstop judges the command in the directory the payload names, with a head
# that says a record was found and is not one JSON object. The oracle holds the
# advisory line once per such call and each head to the record it claims.
unread_line_of() {
  printf "post-verify: the pre-guard's record %s is not one JSON object; this hook set the record aside" "$1"
}
# unread_row <label> <record contents> <confirmed: yes|no> <lockfile: tampered|safe>
unread_row() {
  local wt pending post first
  wt=$(mktemp -d "${tmp_root}/unread-$1-wt.XXXXXX")
  grammar_project "${wt}"
  if [[ "$3" == yes ]]; then
    grammar_pre "${wt}" "npm install fixture-parent@1.0.0" > /dev/null
    touch "${wt}/package-lock.json"
    first=$(PATH="${stub_bin}:${PATH}" grammar_post "${wt}" "npm install fixture-parent@1.0.0 --ignore-scripts")
    [[ -z "${first}" ]] || fail "$1: the project has a confirmed snapshot (${first})"
  fi
  grammar_pre "${wt}" "npm install fixture-parent@1.0.0" > /dev/null
  pending=$(grammar_pending "${wt}")
  printf '%s' "$2" > "${pending}"
  [[ "$4" != tampered ]] || printf '%s\n' "${tampered_lock}" > "${wt}/package-lock.json"
  post=$(PATH="${stub_bin}:${PATH}" grammar_post "${wt}" "npm install fixture-parent@1.0.0 --ignore-scripts")
  [[ "$(grep -cF "$(unread_line_of "${pending}")" "${SAFEDEPS_HOME}/advisory.log")" == 1 ]] \
    || fail "$1: advisory.log names the record that is not one JSON object once"
  [[ ! -e "${pending}" ]] || fail "$1: the record is set aside"
  UNREAD_WT=$(cd -P "${wt}" && pwd -P) UNREAD_POST="${post}"
}

# U1: garbage, an unapproved lockfile and a confirmed snapshot. The backstop
# rolls back to it.
record_traced_before=$(record_traced_count)
unread_row U1 'not json {' yes tampered
[[ "$(record_traced_count)" == "$(( record_traced_before + 1 ))" ]] \
  || fail "U1: the backstop counts the command as traced for the record"
grep -qx 'safedeps: suspicious dependency change detected; this hook found a pre-guard record, and the record is not one JSON object. A rollback ran.' <<< "$(post_message "${UNREAD_POST}")" \
  || fail "U1: the backstop rolls back, and says the record was found and is not one JSON object (${UNREAD_POST})"
cmp -s "${UNREAD_WT}/package-lock.json" "${tmp_root}/revert-safe-lock.json" || fail "U1: the backstop restores the confirmed lockfile"
pass "a pending state that is not JSON goes to the backstop, which rolls back to a confirmed snapshot"

# U2: an array, an unapproved lockfile and no confirmed snapshot. The backstop
# flags the install.
unread_row U2 '[{"snapshot_id":"x"}]' no tampered
grep -qx 'safedeps: suspicious dependency change detected; this hook found a pre-guard record, and the record is not one JSON object. No rollback ran.' <<< "$(post_message "${UNREAD_POST}")" \
  || fail "U2: the backstop flags the unapproved lockfile, and says the record is not one JSON object (${UNREAD_POST})"
grep -qF "post-verify BACKSTOP FLAGGED (no baseline): a command with a pre-guard record that is not one JSON object; the npm closure in ${UNREAD_WT} failed" "${SAFEDEPS_HOME}/advisory.log" \
  || fail "U2: advisory.log says the backstop flagged the install, and why it ran"
pass "a pending state that is a JSON array goes to the backstop, which flags an unapproved lockfile"

# U3: a JSON string and an approved lockfile. The backstop judges it clean,
# and the next call of the same command is not killed by the same record.
unread_row U3 '"a string"' no safe
[[ -z "${UNREAD_POST}" ]] || fail "U3: the backstop passes an approved lockfile quietly (${UNREAD_POST})"
grep -qF "post-verify BACKSTOP clean: a command with a pre-guard record that is not one JSON object; the npm closure in ${UNREAD_WT} passed" "${SAFEDEPS_HOME}/advisory.log" \
  || fail "U3: advisory.log says the backstop judged the install clean, and why it ran"
pass "a pending state that is a JSON string goes to the backstop, which judges an approved lockfile clean"

# G: a record whose snapshot_id is the number 5. The hook read it as "5" and
# looked for 5_meta.json, while the oracle reads a non-string as no snapshot.
# Both read the record's fields only as strings, so it names no snapshot.
num_wt=$(mktemp -d "${tmp_root}/num-wt.XXXXXX")
grammar_project "${num_wt}"
grammar_pre "${num_wt}" "npm install fixture-parent@1.0.0" > /dev/null
num_pending=$(grammar_pending "${num_wt}")
jq '.snapshot_id = 5' "${num_pending}" > "${num_pending}.edit" && mv "${num_pending}.edit" "${num_pending}"
printf '%s\n' "${tampered_lock}" > "${num_wt}/package-lock.json"
num_post=$(PATH="${stub_bin}:${PATH}" grammar_post "${num_wt}" "npm install fixture-parent@1.0.0 --ignore-scripts")
grep -qx 'safedeps: suspicious dependency change detected; this hook found a pre-guard record, and the record names no snapshot. No rollback ran.' <<< "$(post_message "${num_post}")" \
  || fail "G: a snapshot_id that is a number names no snapshot (${num_post})"
[[ "$(grep -cF "$(empty_line_of "${num_pending}")" "${SAFEDEPS_HOME}/advisory.log")" == 1 ]] \
  || fail "G: advisory.log names the record that names no snapshot once"
pass "a pending state whose snapshot_id is a number names no snapshot, for the hook and the oracle alike"

# Two pre-guard calls in one project within one second have a snapshot each.
# The id was `${TIMESTAMP}_${DIR_HASH}`, the same for both, so the second call
# wrote its record and its copy of the lockfile over the first's: the first
# call's post hook spoke from the second call's record, and its rollback
# restored the second call's files (bamdori r19, SAME). A `date` that answers
# one second for `+%s` puts both calls in it every time; the lockfile changes
# between them, as an install in progress would change it.
same_wt=$(mktemp -d "${tmp_root}/same-wt.XXXXXX")
grammar_project "${same_wt}"
same_first=$(SAFEDEPS_TEST_FAULT=same grammar_pre "${same_wt}" "npm install fixture-parent@1.0.0")
cp "${same_wt}/package-lock.json" "${tmp_root}/same-first-lock.json"
jq -c . "${tmp_root}/same-first-lock.json" > "${same_wt}/package-lock.json"
cmp -s "${same_wt}/package-lock.json" "${tmp_root}/same-first-lock.json" && fail "the second call sees a lockfile with other bytes"
cp "${same_wt}/package-lock.json" "${tmp_root}/same-second-lock.json"
same_second=$(SAFEDEPS_TEST_FAULT=same grammar_pre "${same_wt}" "npm ci")
same_first_cmd=$(jq -r '.hookSpecificOutput.updatedInput.command // empty' <<< "${same_first:-{\}}")
same_second_cmd=$(jq -r '.hookSpecificOutput.updatedInput.command // empty' <<< "${same_second:-{\}}")
[[ "${same_first_cmd}" == 'npm install --ignore-scripts fixture-parent@1.0.0 --ignore-scripts' && "${same_second_cmd}" == 'npm ci --ignore-scripts' ]] \
  || fail "both calls in one second are rewritten (${same_first}; ${same_second})"
same_ids=$(for f in $(grep -lF "\"$(cd -P "${same_wt}" && pwd -P)\"" "${SAFEDEPS_HOME}/pending"/*.json); do jq -r .snapshot_id "${f}"; done | sort -u)
[[ "$(grep -c . <<< "${same_ids}")" == 2 ]] || fail "two calls in one project within one second have a snapshot id each (${same_ids})"
for same_id in ${same_ids}; do
  [[ -f "${SAFEDEPS_HOME}/snapshots/${same_id}_meta.json" ]] || fail "each call in one second keeps its own record (${same_id})"
done
printf '%s\n' "${tampered_lock}" > "${same_wt}/package-lock.json"
same_first_post=$(PATH="${stub_bin}:${PATH}" grammar_post "${same_wt}" "${same_first_cmd}")
grep -qx 'safedeps added --ignore-scripts to this install' <<< "$(post_message "${same_first_post}")" \
  || fail "the first call in one second speaks from its own record (${same_first_post})"
cmp -s "${same_wt}/package-lock.json" "${tmp_root}/same-first-lock.json" \
  || fail "the first call in one second is rolled back to its own snapshot"
printf '%s\n' "${tampered_lock}" > "${same_wt}/package-lock.json"
same_second_post=$(PATH="${stub_bin}:${PATH}" grammar_post "${same_wt}" "${same_second_cmd}")
grep -qx 'safedeps added --ignore-scripts to this install' <<< "$(post_message "${same_second_post}")" \
  || fail "the second call in one second speaks from its own record (${same_second_post})"
cmp -s "${same_wt}/package-lock.json" "${tmp_root}/same-second-lock.json" \
  || fail "the second call in one second is rolled back to its own snapshot"
pass "two pre-guard calls in one project within one second keep a record and a snapshot each"

# The backstop with nothing to roll back to: no confirmed record, and a
# confirmed record that names a snapshot with no meta file.
backstop_none_wt="${tmp_root}/backstop-none-wt"
mkdir -p "${backstop_none_wt}"
printf '{"dependencies":{"fixture-parent":"1.0.0"}}\n' > "${backstop_none_wt}/package.json"
printf '%s\n' "${tampered_lock}" > "${backstop_none_wt}/package-lock.json"
backstop_none_post=$(PATH="${stub_bin}:${PATH}" grammar_post "${backstop_none_wt}" "npm install fixture-parent@1.0.0")
grep -q 'No rollback ran\.' <<< "${backstop_none_post}" || fail "the backstop says no rollback ran where there is no confirmed snapshot"
grep -q "no confirmed snapshot is recorded for .*/backstop-none-wt$" <<< "$(post_message "${backstop_none_post}")" || fail "the backstop says no confirmed snapshot is recorded"
grep -q "fixture-evil" "${backstop_none_wt}/package-lock.json" || fail "the backstop changes nothing where it rolls nothing back"
assert_gives_no_command "${backstop_none_post}" "the backstop that rolls nothing back gives no command"
printf 'ghost-snapshot\n' > "${SAFEDEPS_HOME}/confirmed_$(oracle_dir_hash "$(cd -P "${backstop_none_wt}" && pwd -P)")"
backstop_ghost_post=$(PATH="${stub_bin}:${PATH}" grammar_post "${backstop_none_wt}" "npm install fixture-parent@1.0.0")
grep -q "the confirmed snapshot ghost-snapshot of .*/backstop-none-wt: .*/snapshots/ghost-snapshot_meta.json does not exist$" <<< "$(post_message "${backstop_ghost_post}")" \
  || fail "the backstop names the confirmed snapshot whose meta file is missing"
pass "the backstop that rolls nothing back says which record it looked for"

# --- The backstop rolls back only a command that left a trace ----------------
#
# The backstop judges commands the pre-guard did not read as an install, and
# its pattern also matches commands that install nothing. Each project below
# was confirmed by a verified install, and then something outside the gate made
# its closure unapproved: its lockfile changed (a pull, a checkout), or the
# ledger entries that approved it expired. A grep the pattern matched then
# rolled the project back and removed its node_modules.
#
# No row waits. The pre-guard used to set its baseline two seconds back, and
# these rows passed only because they waited three seconds after the change
# outside the gate; a pull 0.3 seconds before the grep was counted as the
# grep's, and two Bash calls in one message are 0.16 seconds apart (lumi r1 R1).
bs_project() {
  grammar_project "$1"
  grammar_pre "$1" "npm install fixture-parent@1.0.0" > /dev/null
  touch "$1/package-lock.json"
  [[ -z "$(PATH="${stub_bin}:${PATH}" grammar_post "$1" "npm install fixture-parent@1.0.0 --ignore-scripts")" ]] \
    || fail "the backstop fixture ${1##*/} is confirmed quietly"
  mkdir -p "$1/node_modules/installed-package"
  printf '{"name":"installed-package","version":"1.0.0"}\n' > "$1/node_modules/installed-package/package.json"
}
# A pull: the lockfile replaced by a new file, the way git writes one.
bs_pull() {
  printf '%s\n' "${tampered_lock}" > "$1/.package-lock.json.pull"
  mv -f "$1/.package-lock.json.pull" "$1/package-lock.json"
}
# A backstop row that rolled nothing back: no message, the project as it was,
# and the check that found no trace in advisory.log.
bs_assert_untraced() {
  local dir="$1" post="$2" label="$3" home="${4:-${SAFEDEPS_HOME}}"
  [[ -z "${post}" ]] || fail "${label}: the backstop says nothing (${post})"
  [[ -f "${dir}/node_modules/installed-package/package.json" ]] || fail "${label}: node_modules is left in place"
  cmp -s "${dir}/package-lock.json" <(printf '%s\n' "${tampered_lock}") || fail "${label}: the lockfile is left as it was"
  grep -qF "post-verify BACKSTOP UNTRACED: no trace in $(cd -P "${dir}" && pwd -P): " "${home}/advisory.log" \
    || fail "${label}: advisory.log says which check found no trace"
}
bs_assert_rollback() {
  local dir="$1" post="$2" label="$3" trace="$4" home="${5:-${SAFEDEPS_HOME}}"
  grep -q 'A rollback ran\.' <<< "${post}" || fail "${label}: the backstop rolls back (${post})"
  [[ ! -e "${dir}/node_modules" ]] || fail "${label}: the rollback removes node_modules"
  cmp -s "${dir}/package-lock.json" "${tmp_root}/revert-safe-lock.json" || fail "${label}: the rollback restores the confirmed lockfile"
  grep -qF "post-verify BACKSTOP traced: ${trace}" "${home}/advisory.log" || fail "${label}: advisory.log says what the trace was"
}
bs_grep='grep -n \"npm install\" README.md'
bs_entries() { { find "$1/pending/backstop" -type f 2>/dev/null || true; } | wc -l | tr -d ' '; }
bs_untraced_count() {
  { grep -cF "post-verify BACKSTOP UNTRACED: no trace in $(cd -P "$1" && pwd -P): " "${SAFEDEPS_HOME}/advisory.log" || true; }
}

# A pull, and the grep right after it (R1).
bs_lock_wt="${tmp_root}/bs-lock-wt"
bs_project "${bs_lock_wt}"
bs_pull "${bs_lock_wt}"
bs_entries_before=$(bs_entries "${SAFEDEPS_HOME}")
bs_lock_pre=$(grammar_pre "${bs_lock_wt}" "${bs_grep}" toolu_bs_lock)
[[ -z "${bs_lock_pre}" ]] || fail "the pre-guard lets a grep run (${bs_lock_pre})"
[[ "$(bs_entries "${SAFEDEPS_HOME}")" == "$(( bs_entries_before + 2 ))" ]] \
  || fail "the pre-guard leaves a trace entry and its baseline for a grep the backstop pattern matches"
# The entry the pre-guard just wrote, read before the post hook removes it and
# checked after the row's own assertion, so a mutation is red at the row first.
bs_lock_entry=$(cat "$(ls -t "${SAFEDEPS_HOME}/pending/backstop/"*.json | head -n 1)" 2>/dev/null || true)
bs_lock_post=$(PATH="${stub_bin}:${PATH}" grammar_post "${bs_lock_wt}" "${bs_grep}" toolu_bs_lock)
bs_assert_untraced "${bs_lock_wt}" "${bs_lock_post}" "a grep right after a pull outside the gate"
[[ "$(jq -r .resolution <<< "${bs_lock_entry:-null}")" == subsecond ]] \
  || fail "on a filesystem that keeps time below one second the baseline is not set back (${bs_lock_entry})"
[[ "$(bs_entries "${SAFEDEPS_HOME}")" == "${bs_entries_before}" ]] || fail "the backstop removes the trace entry and its baseline it read"
# The same, with the lockfile written in place rather than replaced.
printf '%s\n' "${tampered_lock}" > "${bs_lock_wt}/package-lock.json"
grammar_pre "${bs_lock_wt}" "${bs_grep}" toolu_bs_lock_inplace > /dev/null
bs_lock_post=$(PATH="${stub_bin}:${PATH}" grammar_post "${bs_lock_wt}" "${bs_grep}" toolu_bs_lock_inplace)
bs_assert_untraced "${bs_lock_wt}" "${bs_lock_post}" "a grep right after the lockfile was written in place"
grammar_pre "${bs_lock_wt}" "ls -la" toolu_bs_ls > /dev/null
[[ "$(bs_entries "${SAFEDEPS_HOME}")" == "${bs_entries_before}" ]] || fail "the pre-guard leaves no trace entry for a command the backstop pattern does not match"
pass "a grep right after a lockfile change outside the gate rolls nothing back"

# An install the pre-guard did not read (`npm run deps:install` running an
# install), and a write it did not make itself.
bs_t4_wt="${tmp_root}/bs-t4-wt"
bs_project "${bs_t4_wt}"
grammar_pre "${bs_t4_wt}" "npm run deps:install" toolu_bs_t4 > /dev/null
printf '%s\n' "${tampered_lock}" > "${bs_t4_wt}/package-lock.json"
mkdir -p "${bs_t4_wt}/node_modules/fixture-evil"
bs_t4_post=$(PATH="${stub_bin}:${PATH}" grammar_post "${bs_t4_wt}" "npm run deps:install" toolu_bs_t4)
bs_assert_rollback "${bs_t4_wt}" "${bs_t4_post}" "an install the pre-guard did not read" \
  "$(cd -P "${bs_t4_wt}" && pwd -P)/package-lock.json has another status change time than the one recorded before this command"
pass "an install the pre-guard did not read is rolled back"

# A lockfile that is a symbolic link (lumi r2 S1). A write through the link
# changes the target's status change time and not the link's, so the entry
# holds both, and a write through the link is a trace. The row writes only the
# lockfile, as `npm install --package-lock-only` does, so the walk of
# node_modules finds nothing and the lockfile's time is the only trace. A link
# pointed at another file is a trace too: the link is a new one.
bs_s1_wt="${tmp_root}/bs-s1-wt"
bs_project "${bs_s1_wt}"
mv "${bs_s1_wt}/package-lock.json" "${bs_s1_wt}/real-lock.json"
ln -s real-lock.json "${bs_s1_wt}/package-lock.json"
grammar_pre "${bs_s1_wt}" "npm run deps:install" toolu_bs_s1 > /dev/null
printf '%s\n' "${tampered_lock}" > "${bs_s1_wt}/package-lock.json"
bs_s1_post=$(PATH="${stub_bin}:${PATH}" grammar_post "${bs_s1_wt}" "npm run deps:install" toolu_bs_s1)
grep -q 'A rollback ran\.' <<< "${bs_s1_post}" || fail "a write through a linked lockfile is a trace (${bs_s1_post})"
grep -qF "post-verify BACKSTOP traced: $(cd -P "${bs_s1_wt}" && pwd -P)/package-lock.json has another status change time than the one recorded before this command" "${SAFEDEPS_HOME}/advisory.log" \
  || fail "a write through a linked lockfile: advisory.log names the lockfile's status change time"
[[ -L "${bs_s1_wt}/package-lock.json" ]] || fail "a write through a linked lockfile: the rollback leaves the link a link"
bs_s1b_wt="${tmp_root}/bs-s1b-wt"
bs_project "${bs_s1b_wt}"
mv "${bs_s1b_wt}/package-lock.json" "${bs_s1b_wt}/real-lock.json"
ln -s real-lock.json "${bs_s1b_wt}/package-lock.json"
printf '%s\n' "${tampered_lock}" > "${bs_s1b_wt}/other-lock.json"
grammar_pre "${bs_s1b_wt}" "npm run deps:install" toolu_bs_s1b > /dev/null
ln -sfn other-lock.json "${bs_s1b_wt}/package-lock.json"
bs_s1b_post=$(PATH="${stub_bin}:${PATH}" grammar_post "${bs_s1b_wt}" "npm run deps:install" toolu_bs_s1b)
grep -q 'A rollback ran\.' <<< "${bs_s1b_post}" || fail "a lockfile link pointed at another file is a trace (${bs_s1b_post})"
grep -qF "post-verify BACKSTOP traced: $(cd -P "${bs_s1b_wt}" && pwd -P)/package-lock.json has another inode than before this command" "${SAFEDEPS_HOME}/advisory.log" \
  || fail "a lockfile link pointed at another file: advisory.log names the inode"
pass "a write through a linked lockfile, and a lockfile link pointed elsewhere, are traces"

# The ledger entries that approved the closure expired. The ledger is this
# suite's, so the row reads a copy of it.
bs_ttl_wt="${tmp_root}/bs-ttl-wt"
bs_project "${bs_ttl_wt}"
bs_ttl_home="${tmp_root}/bs-ttl-home"
cp -R "${SAFEDEPS_HOME}" "${bs_ttl_home}"
for bs_spec in "${bs_ttl_home}/approved-specs"/*.json; do
  jq '.expires_at = "2020-01-01T00:00:00Z"' "${bs_spec}" > "${bs_spec}.new" && mv "${bs_spec}.new" "${bs_spec}"
done
bs_ttl_cmd='git log --grep=\"npm install\"'
SAFEDEPS_HOME="${bs_ttl_home}" grammar_pre "${bs_ttl_wt}" "${bs_ttl_cmd}" toolu_bs_ttl > /dev/null
bs_ttl_post=$(PATH="${stub_bin}:${PATH}" SAFEDEPS_HOME="${bs_ttl_home}" grammar_post "${bs_ttl_wt}" "${bs_ttl_cmd}" toolu_bs_ttl)
cmp -s "${bs_ttl_wt}/package-lock.json" "${tmp_root}/revert-safe-lock.json" || fail "the ledger row leaves the confirmed lockfile"
[[ -z "${bs_ttl_post}" && -f "${bs_ttl_wt}/node_modules/installed-package/package.json" ]] \
  || fail "a git log after the ledger expired rolls nothing back (${bs_ttl_post})"
grep -qF "post-verify BACKSTOP UNTRACED: no trace in $(cd -P "${bs_ttl_wt}" && pwd -P): " "${bs_ttl_home}/advisory.log" \
  || fail "a git log after the ledger expired is recorded as untraced"
# The same project, a command that writes only into node_modules (a manager
# that writes no npm lockfile): the walk finds it, and the expired ledger is
# why the closure check rejects it.
SAFEDEPS_HOME="${bs_ttl_home}" grammar_pre "${bs_ttl_wt}" "npm run deps:add" toolu_bs_tree > /dev/null
printf 'x\n' > "${bs_ttl_wt}/node_modules/installed-package/added.js"
bs_tree_post=$(PATH="${stub_bin}:${PATH}" SAFEDEPS_HOME="${bs_ttl_home}" grammar_post "${bs_ttl_wt}" "npm run deps:add" toolu_bs_tree)
grep -q 'A rollback ran\.' <<< "${bs_tree_post}" || fail "a write only into node_modules is a trace (${bs_tree_post})"
[[ ! -e "${bs_ttl_wt}/node_modules" ]] || fail "the rollback after a write only into node_modules removes node_modules"
grep -qF "post-verify BACKSTOP traced: $(cd -P "${bs_ttl_wt}" && pwd -P)/node_modules" "${bs_ttl_home}/advisory.log" \
  || fail "advisory.log names what the walk found"
pass "after the ledger expired, a git log rolls nothing back and a write into node_modules rolls back"

# A call whose post hook never ran: Claude Code runs no PostToolUse for a Bash
# call that ended in an error, and runs nothing at all where PostToolUseFailure
# is not registered or for a call the user denied, so its entry stays (lumi r1
# P1). It is that
# call's, and the next call reads only its own: a pull and a grep after it is
# untraced, and the failed call's entry is still there for the age sweep.
bs_p1_wt="${tmp_root}/bs-p1-wt"
bs_project "${bs_p1_wt}"
grammar_pre "${bs_p1_wt}" "${bs_grep}" toolu_bs_p1_failed > /dev/null
bs_pull "${bs_p1_wt}"
grammar_pre "${bs_p1_wt}" "${bs_grep}" toolu_bs_p1 > /dev/null
bs_p1_post=$(PATH="${stub_bin}:${PATH}" grammar_post "${bs_p1_wt}" "${bs_grep}" toolu_bs_p1)
bs_assert_untraced "${bs_p1_wt}" "${bs_p1_post}" "a grep after a failed grep and a pull"
[[ -f "$(bs_entry toolu_bs_p1_failed)" && ! -e "$(bs_entry toolu_bs_p1)" ]] \
  || fail "the failed call's entry stays and the read one is gone"
pass "an entry a failed call left is not read by the next call"

# And it stays that way (P1b): once a failed call left an entry, a clean call
# used to read that one and leave its own, so every later call of the command
# was judged from the call before it.
bs_p1b_wt="${tmp_root}/bs-p1b-wt"
bs_project "${bs_p1b_wt}"
grammar_pre "${bs_p1b_wt}" "${bs_grep}" toolu_bs_p1b_failed > /dev/null
grammar_pre "${bs_p1b_wt}" "${bs_grep}" toolu_bs_p1b_clean > /dev/null
bs_p1b_post=$(PATH="${stub_bin}:${PATH}" grammar_post "${bs_p1b_wt}" "${bs_grep}" toolu_bs_p1b_clean)
[[ -z "${bs_p1b_post}" && "$(bs_untraced_count "${bs_p1b_wt}")" == 1 ]] \
  || fail "a grep after a failed grep, with nothing changed: the backstop says nothing (${bs_p1b_post})"
bs_pull "${bs_p1b_wt}"
grammar_pre "${bs_p1b_wt}" "${bs_grep}" toolu_bs_p1b > /dev/null
bs_p1b_post=$(PATH="${stub_bin}:${PATH}" grammar_post "${bs_p1b_wt}" "${bs_grep}" toolu_bs_p1b)
bs_assert_untraced "${bs_p1b_wt}" "${bs_p1b_post}" "a grep after a failed grep, a clean grep and a pull"
[[ "$(bs_untraced_count "${bs_p1b_wt}")" == 2 ]] || fail "each grep after the failed one is recorded as untraced"
pass "a failed call's entry moves no later call's baseline"

# A call with a trace entry is judged by its entry, and no record is read for
# it (lumi r3 REC). The pre-guard writes a record or an entry for a call, never
# both, so a record found by the directory and the command is another call's.
# REC-K: an install A writes a record and fails, so no post hook takes it
# (Claude Code), and its snapshot's meta file is pruned. B has A's key (the key
# folds spacing) and is no install: `FOO=a\ npm install ...` runs BSD install
# with FOO="a npm". A pull comes in between. B was judged by A's record and
# rolled the project back.
bs_reck_wt="${tmp_root}/bs-reck-wt"
bs_project "${bs_reck_wt}"
grammar_pre "${bs_reck_wt}" 'FOO=a\\  npm install fixture-parent@1.0.0' toolu_bs_reck_a > /dev/null
bs_reck_record=$(grammar_pending "${bs_reck_wt}")
[[ -f "${bs_reck_record}" ]] || fail "REC-K: the install A leaves a record"
rm -f "$(gone_meta_of "${bs_reck_record}")"
bs_pull "${bs_reck_wt}"
bs_reck_pre=$(grammar_pre "${bs_reck_wt}" 'FOO=a\\ npm install fixture-parent@1.0.0' toolu_bs_reck_b)
[[ -z "${bs_reck_pre}" && -f "$(bs_entry toolu_bs_reck_b)" ]] \
  || fail "REC-K: the pre-guard lets B run and leaves B a trace entry (${bs_reck_pre})"
bs_reck_post=$(PATH="${stub_bin}:${PATH}" grammar_post "${bs_reck_wt}" 'FOO=a\\ npm install fixture-parent@1.0.0' toolu_bs_reck_b)
bs_assert_untraced "${bs_reck_wt}" "${bs_reck_post}" "REC-K: a call with a trace entry and the key of another call's record whose snapshot is gone"
[[ -f "${bs_reck_record}" && ! -e "$(bs_entry toolu_bs_reck_b)" ]] \
  || fail "REC-K: the other call's record stays, and B's entry is read"
rm -f "${bs_reck_record}"
pass "a call with a trace entry is not judged by another call's record whose snapshot is gone"

# REC-L: an empty legacy current_snapshot_id for the project, which no current
# pre-guard writes, a pull, and a grep. The grep was judged by the legacy file
# and rolled the project back.
bs_recl_wt="${tmp_root}/bs-recl-wt"
bs_project "${bs_recl_wt}"
: > "${SAFEDEPS_HOME}/current_snapshot_id"
printf '%s\n' "$(cd -P "${bs_recl_wt}" && pwd -P)" > "${SAFEDEPS_HOME}/current_project_dir"
bs_pull "${bs_recl_wt}"
grammar_pre "${bs_recl_wt}" "${bs_grep}" toolu_bs_recl > /dev/null
bs_recl_post=$(PATH="${stub_bin}:${PATH}" grammar_post "${bs_recl_wt}" "${bs_grep}" toolu_bs_recl)
bs_assert_untraced "${bs_recl_wt}" "${bs_recl_post}" "REC-L: a call with a trace entry and an empty legacy record for its project"
[[ -e "${SAFEDEPS_HOME}/current_snapshot_id" && -e "${SAFEDEPS_HOME}/current_project_dir" ]] \
  || fail "REC-L: the legacy record stays"
rm -f "${SAFEDEPS_HOME}/current_snapshot_id" "${SAFEDEPS_HOME}/current_project_dir"
pass "a call with a trace entry is not judged by a legacy record"

# X1, the record whole: A's record and its snapshot are both there. B used to
# take A's record and go through the effect gate as A.
bs_x1_wt="${tmp_root}/bs-x1-wt"
bs_project "${bs_x1_wt}"
grammar_pre "${bs_x1_wt}" 'FOO=a\\  npm install fixture-parent@1.0.0' toolu_bs_x1_a > /dev/null
bs_x1_record=$(grammar_pending "${bs_x1_wt}")
[[ -f "${bs_x1_record}" && -f "$(gone_meta_of "${bs_x1_record}")" ]] || fail "X1: the install A leaves a record and its snapshot"
bs_pull "${bs_x1_wt}"
grammar_pre "${bs_x1_wt}" 'FOO=a\\ npm install fixture-parent@1.0.0' toolu_bs_x1_b > /dev/null
bs_x1_post=$(PATH="${stub_bin}:${PATH}" grammar_post "${bs_x1_wt}" 'FOO=a\\ npm install fixture-parent@1.0.0' toolu_bs_x1_b)
bs_assert_untraced "${bs_x1_wt}" "${bs_x1_post}" "X1: a call with a trace entry and the key of another call's whole record"
[[ -f "${bs_x1_record}" ]] || fail "X1: the other call's record stays"
rm -f "${bs_x1_record}"
pass "a call with a trace entry is not judged by another call's record"

# A payload with no tool_use_id: no entry is written or read, so the command
# counts as traced, which is what the backstop did before it asked.
bs_noid_wt="${tmp_root}/bs-noid-wt"
bs_project "${bs_noid_wt}"
bs_pull "${bs_noid_wt}"
bs_entries_before=$(bs_entries "${SAFEDEPS_HOME}")
grammar_pre "${bs_noid_wt}" "${bs_grep}" > /dev/null
[[ "$(bs_entries "${SAFEDEPS_HOME}")" == "${bs_entries_before}" ]] || fail "the pre-guard writes no trace entry for a call with no tool_use_id"
bs_noid_post=$(PATH="${stub_bin}:${PATH}" grammar_post "${bs_noid_wt}" "${bs_grep}")
bs_assert_rollback "${bs_noid_wt}" "${bs_noid_post}" "a grep with no tool_use_id" \
  "this hook's input names no tool_use_id, so no trace entry belongs to this call"
pass "a call with no tool_use_id is judged as before: a trace"

# --- Records bound to the call ---------------------------------------------
#
# The pre-guard keeps the record of an install under the call's tool_use_id,
# which both hooks of one call receive and no other call does, and the post
# hook of a call that names one reads that record and no other. Records used to
# be found by the directory and the command (issue #5), so a call could speak
# from another call's record. A search by that key takes the first record in
# name order, and a record's name starts with its second, so where a row needs
# the other call's record to be the one a search by key finds first, that call
# runs a second earlier.
call_rewrite() { jq -r '.hookSpecificOutput.updatedInput.command // empty' <<< "${1:-{\}}"; }
call_record() { printf '%s/pending/id-%s.json' "${2:-${SAFEDEPS_HOME}}" "$1"; }
call_records_of() { { grep -lF "\"$(cd -P "$1" && pwd -P)\"" "${SAFEDEPS_HOME}/pending"/*.json 2>/dev/null || true; } | wc -l | tr -d ' '; }

# OV1 (bamdori r19 X1): two overlapping calls of one install in one project.
# A is a Claude Code call that safedeps rewrote; B is a Codex call that sends
# the command A was rewritten to, so both have one key. B's post hook runs
# first. Found by the key, B took A's record and said "added" of a Codex
# install, and A then took B's and said "did not add" of the command safedeps
# wrote.
ov1_wt="${tmp_root}/ov1-wt"
grammar_project "${ov1_wt}"
ov1_pre=$(grammar_pre "${ov1_wt}" "npm install fixture-parent@1.0.0" toolu_ov1_a)
ov1_cmd=$(call_rewrite "${ov1_pre}")
[[ "${ov1_cmd}" == *--ignore-scripts* ]] || fail "OV1: the pre-guard rewrites A (${ov1_pre})"
sleep 1
grammar_pre_codex "${ov1_wt}" "${ov1_cmd}" exec-ov1-b > /dev/null
[[ "$(call_records_of "${ov1_wt}")" == 2 ]] || fail "OV1: the two calls leave a record each"
printf '%s\n' "${tampered_lock}" > "${ov1_wt}/package-lock.json"
ov1_b_post=$(PATH="${stub_bin}:${PATH}" grammar_post_codex "${ov1_wt}" "${ov1_cmd}" exec-ov1-b)
grep -qx 'safedeps did not add --ignore-scripts to this install' <<< "$(post_message "${ov1_b_post}")" \
  || fail "OV1: the Codex call B speaks from its own record: safedeps did not add the flag (${ov1_b_post})"
[[ ! -e "$(call_record exec-ov1-b)" && -f "$(call_record toolu_ov1_a)" ]] \
  || fail "OV1: B's post hook takes B's record and leaves A's"
printf '%s\n' "${tampered_lock}" > "${ov1_wt}/package-lock.json"
ov1_a_post=$(PATH="${stub_bin}:${PATH}" grammar_post "${ov1_wt}" "${ov1_cmd}" toolu_ov1_a)
grep -qx 'safedeps added --ignore-scripts to this install' <<< "$(post_message "${ov1_a_post}")" \
  || fail "OV1: the Claude Code call A speaks from its own record: safedeps added the flag (${ov1_a_post})"
[[ ! -e "$(call_record toolu_ov1_a)" ]] || fail "OV1: A's post hook takes A's record"
pass "two overlapping calls of one install each speak from their own record"

# OV2: a call that names a tool_use_id and has no record of its own (its
# pre-guard did not run, as when the hooks were registered mid-call) does not
# take the record of a call that named none. It goes to the backstop, as a
# command with no record does.
ov2_wt="${tmp_root}/ov2-wt"
grammar_project "${ov2_wt}"
grammar_pre "${ov2_wt}" "npm install fixture-parent@1.0.0" > /dev/null
ov2_record=$(grammar_pending "${ov2_wt}")
printf '%s\n' "${tampered_lock}" > "${ov2_wt}/package-lock.json"
ov2_post=$(PATH="${stub_bin}:${PATH}" grammar_post "${ov2_wt}" "npm install fixture-parent@1.0.0" toolu_ov2_b)
grep -q 'this hook found no record of this command from before it ran\.' <<< "$(post_message "${ov2_post}")" \
  || fail "OV2: a call with no record of its own goes to the backstop (${ov2_post})"
[[ -n "${ov2_record}" && -f "${ov2_record}" ]] || fail "OV2: the other call's record stays"
rm -f "${ov2_record}" "${ov2_record%.json}.trace"
pass "a call that names a tool_use_id does not take the record of a call that named none"

# O2 (bamdori r18): a call whose post hook never ran (a tool call the user
# rejected after its pre-guard ran) leaves its record. The user edits
# package.json, and the next call of the same command is rolled back. Found by
# the key, that call took the old record and restored the snapshot from before
# the edit, so the edit was lost.
o2_wt="${tmp_root}/o2-wt"
grammar_project "${o2_wt}"
grammar_pre "${o2_wt}" "npm install fixture-parent@1.0.0" toolu_o2_rejected > /dev/null
sleep 1
jq '.description = "edited by the user"' "${o2_wt}/package.json" > "${o2_wt}/package.json.edit" \
  && mv "${o2_wt}/package.json.edit" "${o2_wt}/package.json"
o2_cmd=$(call_rewrite "$(grammar_pre "${o2_wt}" "npm install fixture-parent@1.0.0" toolu_o2)")
printf '%s\n' "${tampered_lock}" > "${o2_wt}/package-lock.json"
o2_post=$(PATH="${stub_bin}:${PATH}" grammar_post "${o2_wt}" "${o2_cmd}" toolu_o2)
grep -q 'A rollback ran\.' <<< "${o2_post}" || fail "O2: the unapproved lockfile is rolled back (${o2_post})"
[[ "$(jq -r '.description // empty' "${o2_wt}/package.json")" == 'edited by the user' ]] \
  || fail "O2: the rollback keeps the edit made after the rejected call ($(cat "${o2_wt}/package.json"))"
[[ -f "$(call_record toolu_o2_rejected)" ]] || fail "O2: the rejected call's record stays for the age sweep"
rm -f "$(call_record toolu_o2_rejected)" "${SAFEDEPS_HOME}/pending/id-toolu_o2_rejected.trace"
pass "a call is not judged by the record of a call whose post hook never ran"

# MM (lumi r4): this call's own trace entry, taken in another directory than
# the one its post hook is given, and in that directory the record of an
# install with the same key (from a call that named no tool_use_id) whose
# snapshot is gone. The entry was set aside and the call went on to the
# records, where that record judged it. A call with an entry reads no record:
# it counts as traced, and the backstop judges it with no record.
mm_parent="${tmp_root}/mm-wt"
mm_wt="${mm_parent}/sub"
bs_project "${mm_parent}"
grammar_project "${mm_wt}"
grammar_pre "${mm_wt}" 'FOO=a\\  npm install fixture-parent@1.0.0' > /dev/null
mm_record=$(grammar_pending "${mm_wt}")
rm -f "$(gone_meta_of "${mm_record}")"
grammar_pre "${mm_parent}" 'FOO=a\\ npm install fixture-parent@1.0.0' toolu_mm > /dev/null
[[ -f "$(bs_entry toolu_mm)" ]] || fail "MM: the pre-guard leaves the call a trace entry"
mm_post=$(PATH="${stub_bin}:${PATH}" grammar_post "${mm_wt}" 'FOO=a\\ npm install fixture-parent@1.0.0' toolu_mm)
! grep -q 'this hook found a pre-guard record' <<< "${mm_post}" \
  || fail "MM: a call with a trace entry is not judged by another call's record (${mm_post})"
[[ -f "${mm_record}" ]] || fail "MM: the other call's record stays"
grep -qF "the trace entry for this call was taken for another directory or command" "${SAFEDEPS_HOME}/advisory.log" \
  || fail "MM: advisory.log says the entry was taken for another directory"
rm -f "${mm_record}" "${mm_record%.json}.trace"
pass "a call whose trace entry was taken in another directory reads no record"

# A call that names no tool_use_id keeps the key from before, and both hooks
# say so in advisory.log: two overlapping calls of its command can still use
# each other's record.
noid_wt="${tmp_root}/noid-wt"
grammar_project "${noid_wt}"
noid_cmd=$(call_rewrite "$(grammar_pre "${noid_wt}" "npm install fixture-parent@1.0.0")")
noid_record=$(grammar_pending "${noid_wt}")
[[ "${noid_record##*/}" == *__*.json ]] || fail "a call with no tool_use_id keeps its record under the directory and the command (${noid_record})"
grep -qF "pre-guard: this hook's input names no tool_use_id, so the record of this install is kept under its directory and command" "${SAFEDEPS_HOME}/advisory.log" \
  || fail "the pre-guard records that a call names no tool_use_id"
touch "${noid_wt}/package-lock.json"
noid_post=$(PATH="${stub_bin}:${PATH}" grammar_post "${noid_wt}" "${noid_cmd}")
[[ -z "${noid_post}" && ! -e "${noid_record}" ]] || fail "a call with no tool_use_id is judged from the record found by the key (${noid_post})"
grep -qF "post-verify: this hook's input names no tool_use_id, so it took the record ${noid_record} by the directory and the command" "${SAFEDEPS_HOME}/advisory.log" \
  || fail "the post hook records that it took a record by the key"
pass "a call with no tool_use_id is judged as before, and both hooks record it"

# A failed install. Claude Code runs PostToolUseFailure for a Bash call that ran
# and failed, with the call's tool_use_id and an `error` where a success has
# `tool_response`; Codex runs PostToolUse, with its turn_id. An install that
# fails can still have written the project's tree, and before
# PostToolUseFailure was registered Claude Code ran no post hook for it: the
# install was not judged, and its record stayed for the next call of the
# command. Here each failed install wrote an unapproved lockfile, is judged
# and rolled back, and leaves no record.
fail_post_claude() {
  post_hook <<EOF
{"session_id":"e2e","hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_input":{"command":"$2"},"cwd":"$1","tool_use_id":"$3","error":"Exit code 1\\nnpm error code E404","is_interrupt":false}
EOF
}
fail_post_codex() {
  post_hook <<EOF
{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"$2"},"cwd":"$1","tool_use_id":"$3","turn_id":"turn-e2e","model":"codex-test","tool_response":"npm error code E404\\nExit code: 1"}
EOF
}
fa_claude_wt="${tmp_root}/fa-claude-wt"
grammar_project "${fa_claude_wt}"
fa_claude_cmd=$(call_rewrite "$(grammar_pre "${fa_claude_wt}" "npm install fixture-parent@1.0.0" toolu_fa_claude)")
[[ -f "$(call_record toolu_fa_claude)" ]] || fail "a failed install on Claude Code: the pre-guard leaves its record"
printf '%s\n' "${tampered_lock}" > "${fa_claude_wt}/package-lock.json"
fa_claude_post=$(PATH="${stub_bin}:${PATH}" fail_post_claude "${fa_claude_wt}" "${fa_claude_cmd}" toolu_fa_claude)
grep -q 'A rollback ran\.' <<< "${fa_claude_post}" || fail "a failed install on Claude Code is judged and rolled back (${fa_claude_post})"
grep -qx 'safedeps added --ignore-scripts to this install' <<< "$(post_message "${fa_claude_post}")" \
  || fail "a failed install on Claude Code speaks from its own record"
[[ ! -e "$(call_record toolu_fa_claude)" && "$(call_records_of "${fa_claude_wt}")" == 0 ]] \
  || fail "a failed install on Claude Code leaves no record"
fa_codex_wt="${tmp_root}/fa-codex-wt"
grammar_project "${fa_codex_wt}"
grammar_pre_codex "${fa_codex_wt}" "npm install fixture-parent@1.0.0" exec-fa-codex > /dev/null
printf '%s\n' "${tampered_lock}" > "${fa_codex_wt}/package-lock.json"
fa_codex_post=$(PATH="${stub_bin}:${PATH}" fail_post_codex "${fa_codex_wt}" "npm install fixture-parent@1.0.0" exec-fa-codex)
grep -q 'A rollback ran\.' <<< "${fa_codex_post}" || fail "a failed install on Codex is judged and rolled back (${fa_codex_post})"
grep -qx 'safedeps did not add --ignore-scripts to this install' <<< "$(post_message "${fa_codex_post}")" \
  || fail "a failed install on Codex speaks from its own record"
[[ "$(call_records_of "${fa_codex_wt}")" == 0 ]] || fail "a failed install on Codex leaves no record"
pass "a failed install is judged and leaves no record, on both engines"

# A filesystem that keeps whole seconds, simulated in an archive copy by
# writing the actual baseline with integer-second FileTimes. A write in the second the baseline is touched in would not
# be newer than it, so there the baseline is set two seconds back, and a pull
# just before the grep is counted as the grep's.
bs_sec_wt="${tmp_root}/bs-sec-wt"
bs_project "${bs_sec_wt}"
printf '%s\n' "${tampered_lock}" > "${bs_sec_wt}/package-lock.json"
SAFEDEPS_TEST_FAULT=bs_sec grammar_pre "${bs_sec_wt}" "${bs_grep}" toolu_bs_sec > /dev/null
[[ "$(jq -r .resolution "$(bs_entry toolu_bs_sec)")" == seconds ]] \
  || fail "a baseline with no part below the second is set back ($(cat "$(bs_entry toolu_bs_sec)"))"
bs_sec_post=$(PATH="${stub_bin}:${PATH}" grammar_post "${bs_sec_wt}" "${bs_grep}" toolu_bs_sec)
bs_assert_rollback "${bs_sec_wt}" "${bs_sec_post}" "a grep on a whole-second filesystem" \
  "$(cd -P "${bs_sec_wt}" && pwd -P)/package-lock.json changed after the baseline taken before this command"
pass "on a filesystem that keeps whole seconds the baseline is set two seconds back"

# A node tree on two filesystems (lumi r2 P3): the lockfile keeps nanoseconds
# and node_modules is on a mount that keeps whole seconds, simulated by an
# archive copy that quantizes native observations and a native walk that reads
# each time there as the start of its second. A write into node_modules in the
# second the baseline was touched in is then not newer than a baseline that is
# not set back. Where one part with a time below the second was enough, the
# tree was read as subsecond and the walk missed such a write (2 of 5 on a real
# HFS+ mount). Every part has to show one now, so the baseline is set back.
bs_mix_wt="${tmp_root}/bs-mix-wt"
bs_project "${bs_mix_wt}"
# Isolate the mixed-clock walk: an older lockfile must not satisfy the
# preceding lockfile test against the baseline backdated by two seconds.
# Other backstop rows above deliberately do not wait after their writes.
sleep 3
bs_mix_bin="${tmp_root}/bs-mix-bin"
mkdir -p "${bs_mix_bin}"
cat > "${bs_mix_bin}/whole-second-walk.py" <<'EOF'
import os, sys
# find -cnewer compares a status change time with the reference's modification time.
root, base = sys.argv[1], os.stat(sys.argv[2]).st_mtime_ns
def newer(path, follow):
    st = os.stat(path) if follow else os.lstat(path)
    return st.st_ctime_ns // 10**9 * 10**9 > base
if newer(root, True):
    print(root); sys.exit(0)
for parent, dirs, files in os.walk(root):
    for name in dirs + files:
        if newer(os.path.join(parent, name), False):
            print(os.path.join(parent, name)); sys.exit(0)
EOF
SAFEDEPS_TEST_FAULT=bs_mix grammar_pre "${bs_mix_wt}" "npm run deps:add" toolu_bs_mix > /dev/null
bs_mix_entry=$(cat "$(bs_entry toolu_bs_mix)" 2>/dev/null || true)
printf 'x\n' > "${bs_mix_wt}/node_modules/installed-package/added.js"
# The walk from this entry's baseline, on a copy of it with the same times. The
# post hook must now reach the node walk; its source receipt is mandatory.
bs_mix_base="${tmp_root}/bs-mix-baseline"
touch -r "$(jq -r .baseline <<< "${bs_mix_entry:-null}")" "${bs_mix_base}" 2>/dev/null || : > "${bs_mix_base}"
bs_mix_walk=$(python3 "${bs_mix_bin}/whole-second-walk.py" "${bs_mix_wt}/node_modules" "${bs_mix_base}")
bs_mix_post=$(SAFEDEPS_TEST_FAULT=bs_mix PATH="${stub_bin}:${PATH}" grammar_post "${bs_mix_wt}" "npm run deps:add" toolu_bs_mix)
[[ "$(jq -r .resolution <<< "${bs_mix_entry:-null}")" == seconds ]] \
  || fail "a write into node_modules on a whole-second mount beside a subsecond lockfile: the baseline is set back (${bs_mix_entry})"
[[ "${bs_mix_walk}" == "${bs_mix_wt}/node_modules"* ]] \
  || fail "a write into node_modules on a whole-second mount beside a subsecond lockfile: the walk from the entry's baseline finds it (${bs_mix_walk})"
grep -qF "post-verify BACKSTOP traced: $(cd -P "${bs_mix_wt}" && pwd -P)/node_modules" "${SAFEDEPS_HOME}/advisory.log" \
  || fail "a write into node_modules on a whole-second mount beside a subsecond lockfile: the backstop counts it as traced (${bs_mix_post})"
pass "a tree with one part on a whole-second filesystem sets the baseline back"

# A source copy delays the actual native walk past its deadline.
bs_slow_wt="${tmp_root}/bs-slow-wt"
bs_project "${bs_slow_wt}"
bs_pull "${bs_slow_wt}"
grammar_pre "${bs_slow_wt}" "${bs_grep}" toolu_bs_slow > /dev/null
bs_slow_post=$(SAFEDEPS_TEST_FAULT=bs_slow PATH="${stub_bin}:${PATH}" SAFEDEPS_BACKSTOP_WALK_SECONDS=1 grammar_post "${bs_slow_wt}" "${bs_grep}" toolu_bs_slow)
bs_assert_rollback "${bs_slow_wt}" "${bs_slow_post}" "a walk past its deadline" \
  "the walk of $(cd -P "${bs_slow_wt}" && pwd -P)/node_modules did not finish within 1s"
pass "a walk that does not finish within its deadline counts as a trace"

# The --ignore-scripts line reads no command. It is the pre-guard's record of
# the command it wrote, and whether the command this hook received is that
# command, byte for byte. On Codex there is no such record, whatever the command
# carries: its own flag, `=false` (F2), a flag of another statement, a quoted
# word, an assignment of npm_config_ignore_scripts (F3). On Claude the command
# the pre-guard wrote is "added" with a quoted word in it too, and a command that
# carries the flag somewhere else is not the one safedeps wrote.
#
# Fields: engine | name | command | the command the post hook receives ("" for
# the same command, "=" for the one the pre-guard wrote) | the line.
inert_none='safedeps did not add --ignore-scripts to this install'
inert_asked='safedeps asked for --ignore-scripts on this install; the command this hook received is not the one safedeps wrote'
inert_added='safedeps added --ignore-scripts to this install'
for inert_case in \
  "codex|carried|npm install fixture-parent@1.0.0 --ignore-scripts||${inert_none}" \
  "codex|false|npm install fixture-parent@1.0.0 --ignore-scripts=false||${inert_none}" \
  "codex|echo|npm install fixture-parent@1.0.0 && echo --ignore-scripts||${inert_none}" \
  "codex|quoted|npm install 'fixture-parent@1.0.0' --ignore-scripts||${inert_none}" \
  "codex|assigned|npm_config_ignore_scripts=true npm install fixture-parent@1.0.0||${inert_none}" \
  "claude|quoted|npm install 'fixture-parent@1.0.0'|=|${inert_added}" \
  "claude|moved|npm install fixture-parent@1.0.0|npm install --ignore-scripts fixture-parent@1.0.0|${inert_asked}"; do
  IFS='|' read -r inert_engine inert_name inert_cmd inert_received inert_said <<< "${inert_case}"
  inert_wt="${tmp_root}/inert-${inert_engine}-${inert_name}-wt"
  grammar_project "${inert_wt}"
  if [[ "${inert_engine}" == codex ]]; then
    inert_pre=$(grammar_pre_codex "${inert_wt}" "${inert_cmd}")
  else
    inert_pre=$(grammar_pre "${inert_wt}" "${inert_cmd}")
  fi
  case "${inert_received}" in
    '') inert_received="${inert_cmd}" ;;
    =) inert_received=$(jq -r '.hookSpecificOutput.updatedInput.command // empty' <<< "${inert_pre:-{\}}")
       [[ "${inert_received}" == *--ignore-scripts* ]] || fail "${inert_name}: the pre-guard rewrites the command on Claude (${inert_pre})" ;;
  esac
  printf '%s\n' "${tampered_lock}" > "${inert_wt}/package-lock.json"
  if [[ "${inert_engine}" == codex ]]; then
    inert_post=$(PATH="${stub_bin}:${PATH}" grammar_post_codex "${inert_wt}" "${inert_received}")
  else
    inert_post=$(PATH="${stub_bin}:${PATH}" grammar_post "${inert_wt}" "${inert_received}")
  fi
  grep -qxF "${inert_said}" <<< "$(post_message "${inert_post}")" \
    || fail "${inert_engine} ${inert_name}: the --ignore-scripts line says '${inert_said}' (${inert_post})"
done
pass "the --ignore-scripts line is the pre-guard's record and a comparison of bytes, and reads no command"

# The warning for packages npm fetched from a registry that is not the public
# one says why safedeps did not add --ignore-scripts. "(on Codex it cannot)"
# was said on either engine; it is said of a Codex call only. Each row's install
# brings in the approved closure with a public `resolved` URL, and npm (the
# stub) says it fetches from another registry, so the install is kept and the
# warning is said. On Claude Code the command keeps ignore-scripts true itself,
# so safedeps did not add the flag. The integrity values are this row's own: a
# recorded integrity withholds a rebuild of those bytes in every later row.
fetched_bin="${tmp_root}/fetched-bin"
mkdir -p "${fetched_bin}"
cat > "${fetched_bin}/npm" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == query ]]; then
  printf '%s\n' '[{"location":"","name":"fetched-project"},{"location":"node_modules/fixture-parent","name":"fixture-parent","version":"1.0.0"},{"location":"node_modules/fixture-child","name":"fixture-child","version":"1.0.0"}]'
elif [[ "$1" == config ]]; then
  printf '%s\n' '{"registry":"http://127.0.0.1:9/elsewhere/","replace-registry-host":"npmjs"}'
fi
exit 0
EOF
chmod +x "${fetched_bin}/npm"
for fetched_engine in claude codex; do
  fetched_wt="${tmp_root}/fetched-${fetched_engine}-wt"
  grammar_project "${fetched_wt}"
  printf '%s\n' '{"name":"fetched-project","lockfileVersion":3,"packages":{"":{"dependencies":{"fixture-parent":"1.0.0"}}}}' > "${fetched_wt}/package-lock.json"
  if [[ "${fetched_engine}" == codex ]]; then
    fetched_cmd="npm install fixture-parent@1.0.0"
    grammar_pre_codex "${fetched_wt}" "${fetched_cmd}" "exec-fetched-${fetched_engine}" > /dev/null
  else
    fetched_cmd="npm install --ignore-scripts fixture-parent@1.0.0"
    [[ -z "$(call_rewrite "$(grammar_pre "${fetched_wt}" "${fetched_cmd}" "toolu_fetched_${fetched_engine}")")" ]] \
      || fail "fetched (${fetched_engine}): safedeps leaves a command that keeps ignore-scripts true as written"
  fi
  cat > "${fetched_wt}/package-lock.json" <<EOF
{
  "name": "fetched-project",
  "lockfileVersion": 3,
  "packages": {
    "": {"dependencies": {"fixture-parent": "1.0.0"}},
    "node_modules/fixture-parent": {"version": "1.0.0", "resolved": "https://registry.npmjs.org/fixture-parent/-/fixture-parent-1.0.0.tgz", "integrity": "sha512-fetched${fetched_engine}parent", "dependencies": {"fixture-child": "1.0.0"}},
    "node_modules/fixture-child": {"version": "1.0.0", "resolved": "https://registry.npmjs.org/fixture-child/-/fixture-child-1.0.0.tgz", "integrity": "sha512-fetched${fetched_engine}child"}
  }
}
EOF
  if [[ "${fetched_engine}" == codex ]]; then
    fetched_post=$(PATH="${fetched_bin}:${PATH}" grammar_post_codex "${fetched_wt}" "${fetched_cmd}" "exec-fetched-${fetched_engine}")
    fetched_said='. safedeps did not add --ignore-scripts to this install (on Codex it cannot), so their install scripts may already have run. '
  else
    fetched_post=$(PATH="${fetched_bin}:${PATH}" grammar_post "${fetched_wt}" "${fetched_cmd}" "toolu_fetched_${fetched_engine}")
    fetched_said='. safedeps did not add --ignore-scripts to this install, so their install scripts may already have run. '
  fi
  ! grep -q 'A rollback ran\.' <<< "${fetched_post}" || fail "fetched (${fetched_engine}): the install is kept (${fetched_post})"
  grep -q '^this install fetched packages from a registry that is not the public npm registry (' <<< "$(post_message "${fetched_post}")" \
    || fail "fetched (${fetched_engine}): the warning names the registry (${fetched_post})"
  grep -qF "${fetched_said}" <<< "$(post_message "${fetched_post}")" \
    || fail "fetched (${fetched_engine}): the warning says why safedeps did not add --ignore-scripts for this engine (${fetched_post})"
done
pass "the registry warning says safedeps cannot add --ignore-scripts on Codex only of a Codex call"

# A node_modules that is a link is listed through the link, before the command
# and in the rollback (F1, bamdori r16 LK1). The command writes a package into
# the directory the link leads to and leaves both lockfiles alone: the listing
# shows it, and the removal of the link is refused. Without the write,
# node_modules is kept, and the kept line says it is a link.
for lk_case in write keep; do
  lk_target="${tmp_root}/lk-${lk_case}-target"
  lk_wt="${tmp_root}/lk-${lk_case}-wt"
  mkdir -p "${lk_target}/node_modules/@s/a" "${lk_wt}"
  printf '{"name":"@s/a","version":"1.0.0"}\n' > "${lk_target}/node_modules/@s/a/package.json"
  ln -s "${lk_target}/node_modules" "${lk_wt}/node_modules"
  printf '{"dependencies":{"fixture-parent":"1.0.0"}}\n' > "${lk_wt}/package.json"
  printf '%s\n' "${tampered_lock}" > "${lk_wt}/package-lock.json"
  grammar_pre "${lk_wt}" "npm install fixture-parent@1.0.0" > /dev/null
  if [[ "${lk_case}" == write ]]; then
    mkdir -p "${lk_target}/node_modules/@s/evil"
    printf '{"name":"@s/evil","version":"1.0.0"}\n' > "${lk_target}/node_modules/@s/evil/package.json"
  fi
  lk_post=$(PATH="${emptying_bin}:${PATH}" grammar_post "${lk_wt}" "npm install --ignore-scripts fixture-parent@1.0.0 --ignore-scripts")
  lk_message=$(post_message "${lk_post}")
  if [[ "${lk_case}" == write ]]; then
    grep -qx ".*/lk-write-wt/node_modules lists .*/lk-write-wt/node_modules/@s/evil/package.json, which the pre-command snapshot .* does not" <<< "${lk_message}" \
      || fail "a package written through a linked node_modules is the reason line (${lk_post})"
    grep -q '^refused removal of .*/lk-write-wt/node_modules: ' <<< "${lk_message}" || fail "the removal of the linked node_modules is refused"
    [[ -f "${lk_target}/node_modules/@s/evil/package.json" ]] || fail "a rollback leaves the target of a linked node_modules alone"
  else
    grep -A1 -x 'kept .*/lk-keep-wt/node_modules' <<< "${lk_message}" | grep -q '/lk-keep-wt/node_modules is a symbolic link to ' \
      || fail "a kept node_modules that is a link is said as one, right after the kept line (${lk_post})"
    [[ -f "${lk_target}/node_modules/@s/a/package.json" ]] || fail "a kept linked node_modules keeps what it holds"
  fi
done
pass "a linked node_modules is listed through the link, and a kept one is said as a link"

# A restore over a target that is not a regular file is not attempted: cp into
# a directory writes a file inside it and exits 0 (CP2, bamdori r16).
cpdir_wt="${tmp_root}/cpdir-wt"
grammar_project "${cpdir_wt}"
mkdir -p "${cpdir_wt}/node_modules/installed-package"
grammar_pre "${cpdir_wt}" "npm install fixture-parent@1.0.0" > /dev/null
rm -f "${cpdir_wt}/package-lock.json"
mkdir "${cpdir_wt}/package-lock.json" "${cpdir_wt}/node_modules/.bin"
# A native binary is what rejects this install; the lockfile is a directory.
cp /bin/echo "${cpdir_wt}/node_modules/.bin/native-drop"
cpdir_post=$(PATH="${emptying_bin}:${PATH}" grammar_post "${cpdir_wt}" "npm install --ignore-scripts fixture-parent@1.0.0 --ignore-scripts")
grep -qx 'not restored .*/cpdir-wt/package-lock.json: .*/cpdir-wt/package-lock.json exists and is not a regular file' <<< "$(post_message "${cpdir_post}")" \
  || fail "a restore target that is a directory is said as one (${cpdir_post})"
[[ -z "$(ls -A "${cpdir_wt}/package-lock.json")" ]] || fail "the rollback writes nothing inside a directory where the lockfile was"
pass "a restore target that is not a regular file is named and left alone"

# A permission error is a line, and rollback continues through node_modules
# and journal close. The fixture reaches the native destination open; a
# separate Python open records the OS error before the mode is restored.
cpfail_wt="${tmp_root}/cpfail-wt"
grammar_project "${cpfail_wt}"
mkdir -p "${cpfail_wt}/node_modules/installed-package"
grammar_pre "${cpfail_wt}" "npm install fixture-parent@1.0.0" > /dev/null
printf '%s\n' "${tampered_lock}" > "${cpfail_wt}/package-lock.json"
cpfail_post=$(SAFEDEPS_TEST_FAULT=cpfail PATH="${emptying_bin}:${PATH}" grammar_post "${cpfail_wt}" "npm install fixture-parent@1.0.0")
grep -qE '^not restored .*/cpfail-wt/package-lock.json: copy returned OS error 13; .*/cpfail-wt/package-lock.json differs from the snapshot$' <<< "$(post_message "${cpfail_post}")" \
  || fail "a restore whose copy failed is reported with the copy's OS error"
[[ ! -e "${cpfail_wt}/node_modules" ]] || fail "the rollback goes on to node_modules after a restore that failed"
[[ -z "$(find "${SAFEDEPS_HOME}/rollback-journal" -maxdepth 1 -name '*.json' 2>/dev/null)" ]] \
  || fail "a rollback that reported a failed restore closes its journal entry"
# A source copy returns Ok without writing this lockfile. This is a separate
# operation/result observation, not a nonzero error recast as success.
copy_noop_wt="${tmp_root}/copy-noop-wt"
grammar_project "${copy_noop_wt}"
mkdir -p "${copy_noop_wt}/node_modules/installed-package"
grammar_pre "${copy_noop_wt}" "npm install fixture-parent@1.0.0" > /dev/null
printf '%s\n' "${tampered_lock}" > "${copy_noop_wt}/package-lock.json"
copy_noop_post=$(SAFEDEPS_TEST_FAULT=copy-noop PATH="${emptying_bin}:${PATH}" grammar_post "${copy_noop_wt}" "npm install fixture-parent@1.0.0")
grep -qE '^not restored .*/copy-noop-wt/package-lock.json: copy returned without error; .*/copy-noop-wt/package-lock.json differs from the snapshot$' <<< "$(post_message "${copy_noop_post}")" \
  || fail "a copy returning without error still reports the differing bytes"
[[ ! -e "${copy_noop_wt}/node_modules" ]] || fail "rollback continues after a copy returned without restoring bytes"
[[ -z "$(find "${SAFEDEPS_HOME}/rollback-journal" -maxdepth 1 -name '*.json' 2>/dev/null)" ]] \
  || fail "rollback closes the journal after a copy returned without restoring bytes"
pass "a no-error copy with differing bytes has its own checked report form"

# The same with the file gone: the command removed the lockfile, and the copy
# that would put it back fails.
cpgone_wt="${tmp_root}/cpgone-wt"
grammar_project "${cpgone_wt}"
grammar_pre "${cpgone_wt}" "npm install fixture-parent@1.0.0" > /dev/null
rm -f "${cpgone_wt}/package-lock.json"
mkdir -p "${cpgone_wt}/node_modules/.bin" "${cpgone_wt}/node_modules/fixture-parent"
printf '{"name":"fixture-parent","version":"1.0.0"}\n' > "${cpgone_wt}/node_modules/fixture-parent/package.json"
cp /bin/echo "${cpgone_wt}/node_modules/.bin/native-drop"
cpgone_post=$(SAFEDEPS_TEST_FAULT=cpgone PATH="${emptying_bin}:${PATH}" grammar_post "${cpgone_wt}" "npm install fixture-parent@1.0.0")
grep -qE '^not restored .*/cpgone-wt/package-lock.json: copy returned OS error 13; .*/cpgone-wt/package-lock.json does not exist$' <<< "$(post_message "${cpgone_post}")" \
  || fail "a restore that failed over a missing file says the file does not exist (${cpgone_post})"
if [[ "$(id -u)" != 0 ]]; then
  readonly_wt="${tmp_root}/readonly-wt"
  grammar_project "${readonly_wt}"
  mkdir -p "${readonly_wt}/node_modules/installed-package"
  grammar_pre "${readonly_wt}" "npm install fixture-parent@1.0.0" > /dev/null
  printf '%s\n' "${tampered_lock}" > "${readonly_wt}/package-lock.json"
  chmod 444 "${readonly_wt}/package-lock.json"
  readonly_post=$(PATH="${emptying_bin}:${PATH}" grammar_post "${readonly_wt}" "npm install fixture-parent@1.0.0")
  chmod 644 "${readonly_wt}/package-lock.json"
  grep -qE '^not restored .*/readonly-wt/package-lock.json: copy returned OS error 13; ' <<< "$(post_message "${readonly_post}")" \
    || fail "a read-only lockfile is reported as not restored (${readonly_post})"
  [[ ! -e "${readonly_wt}/node_modules" ]] || fail "the rollback goes on to node_modules past a read-only lockfile"
fi
pass "a restore that fails is a line of the rollback, not the end of the hook"

# A nonempty readonly child refuses unlink for this uid. Root or a filesystem
# that ignores chmod fails the fixture instead of counting an unexercised fault.
rmfail_wt="${tmp_root}/rmfail-wt"
grammar_project "${rmfail_wt}"
mkdir -p "${rmfail_wt}/node_modules/installed-package"
grammar_pre "${rmfail_wt}" "npm install fixture-parent@1.0.0" > /dev/null
printf '%s\n' "${tampered_lock}" > "${rmfail_wt}/package-lock.json"
rmfail_post=$(SAFEDEPS_TEST_FAULT=rmfail PATH="${emptying_bin}:${PATH}" grammar_post "${rmfail_wt}" "npm install fixture-parent@1.0.0")
grep -qE '^not removed .*/rmfail-wt/node_modules: removal returned OS error 13; .*/rmfail-wt/node_modules exists$' <<< "$(post_message "${rmfail_post}")" \
  || fail "a removal that failed is reported with the removal's OS error and what a test of the path returned"
pass "a removal that fails says the OS error and that the path exists"

# The install trace, where the baseline file the pre-guard touched is gone, and
# where the pending state names none.
gone_wt="${tmp_root}/baseline-gone-wt"
mkdir -p "${gone_wt}/node_modules"
printf '{"dependencies":{}}\n' > "${gone_wt}/package.json"
grammar_pre "${gone_wt}" "npm install fixture-parent@1.0.0" > /dev/null
rm -f "$(jq -r '.npm_trace.baseline' "$(grammar_pending "${gone_wt}")")"
cp "${tmp_root}/revert-safe-lock.json" "${gone_wt}/package-lock.json"
gone_post=$(PATH="${stub_bin}:${PATH}" grammar_post "${gone_wt}" "npm install --ignore-scripts fixture-parent@1.0.0 --ignore-scripts")
grep -q 'did not run npm rebuild: no install trace in .*/baseline-gone-wt: the baseline file .* does not exist$' <<< "$(post_message "${gone_post}")" \
  || fail "an install whose trace baseline is gone is reported as that, not as an install that changed nothing (${gone_post})"
unset_wt="${tmp_root}/baseline-unset-wt"
mkdir -p "${unset_wt}/node_modules/installed-package"
printf '{"dependencies":{"fixture-parent":"1.0.0"}}\n' > "${unset_wt}/package.json"
printf '%s\n' "${tampered_lock}" > "${unset_wt}/package-lock.json"
grammar_pre "${unset_wt}" "npm install fixture-parent@1.0.0" > /dev/null
unset_pending=$(grammar_pending "${unset_wt}")
jq -c 'del(.npm_trace)' "${unset_pending}" > "${unset_pending}.tmp" && mv "${unset_pending}.tmp" "${unset_pending}"
unset_post=$(PATH="${emptying_bin}:${PATH}" grammar_post "${unset_wt}" "npm install fixture-parent@1.0.0")
grep -q '^the pending state of this command names no install-trace baseline$' <<< "$(post_message "${unset_post}")" \
  || fail "a node_modules kept without a trace baseline says there was none to read (${unset_post})"
[[ -d "${unset_wt}/node_modules/installed-package" ]] || fail "node_modules is kept where no check shows the command wrote it"
pass "a missing install trace is said as the check that found none"

# A rebuild that fails says its exit status. Where the command this hook
# received is the one the pre-guard wrote, safedeps added the flag; where it is
# not (a runtime that does not apply the rewrite), safedeps asked for it.
rebuildfail_bin="${tmp_root}/rebuildfail-bin"
mkdir -p "${rebuildfail_bin}"
cat > "${rebuildfail_bin}/npm" <<EOF
#!/usr/bin/env bash
[[ "\$1" != rebuild ]] || exit 3
exec "${stub_bin}/npm" "\$@"
EOF
chmod +x "${rebuildfail_bin}/npm"
for rebuildfail_case in "added|npm install --ignore-scripts fixture-parent@1.0.0 --ignore-scripts" "asked|npm install fixture-parent@1.0.0"; do
  rebuildfail_wt="${tmp_root}/rebuildfail-${rebuildfail_case%%|*}-wt"
  mkdir -p "${rebuildfail_wt}/node_modules"
  printf '{"dependencies":{}}\n' > "${rebuildfail_wt}/package.json"
  grammar_pre "${rebuildfail_wt}" "npm install fixture-parent@1.0.0" > /dev/null
  cp "${inert_project}/package-lock.json" "${rebuildfail_wt}/package-lock.json"
  cp "${inert_project}/package-lock.json" "${rebuildfail_wt}/node_modules/.package-lock.json"
  rebuildfail_post=$(PATH="${rebuildfail_bin}:${PATH}" grammar_post "${rebuildfail_wt}" "${rebuildfail_case#*|}")
  if [[ "${rebuildfail_case%%|*}" == added ]]; then
    grep -q '^safedeps added --ignore-scripts to this install and ran npm rebuild: exit 3$' <<< "$(post_message "${rebuildfail_post}")" \
      || fail "a failed rebuild says its exit status (${rebuildfail_post})"
  else
    grep -q '^safedeps ran npm rebuild: exit 3$' <<< "$(post_message "${rebuildfail_post}")" \
      || fail "a failed rebuild says its exit status where the command did not carry the flag (${rebuildfail_post})"
    grep -q '^safedeps asked for --ignore-scripts on this install; the command this hook received is not the one safedeps wrote$' <<< "$(post_message "${rebuildfail_post}")" \
      || fail "safedeps does not say it added a flag to a command this hook did not receive"
  fi
done
# The same with a quoted word, where the command this hook received is the one
# the pre-guard wrote: added. A reader of the command used to say it could not
# tell here, on the path safedeps rewrites most.
rebuildquoted_wt="${tmp_root}/rebuildfail-quoted-wt"
mkdir -p "${rebuildquoted_wt}/node_modules"
printf '{"dependencies":{}}\n' > "${rebuildquoted_wt}/package.json"
rebuildquoted_pre=$(grammar_pre "${rebuildquoted_wt}" "npm install 'fixture-parent@1.0.0'")
rebuildquoted_cmd=$(jq -r '.hookSpecificOutput.updatedInput.command // empty' <<< "${rebuildquoted_pre:-{\}}")
[[ "${rebuildquoted_cmd}" == *--ignore-scripts* ]] || fail "the pre-guard rewrites a quoted install on Claude (${rebuildquoted_pre})"
cp "${inert_project}/package-lock.json" "${rebuildquoted_wt}/package-lock.json"
cp "${inert_project}/package-lock.json" "${rebuildquoted_wt}/node_modules/.package-lock.json"
rebuildquoted_post=$(PATH="${rebuildfail_bin}:${PATH}" grammar_post "${rebuildquoted_wt}" "${rebuildquoted_cmd}")
grep -qx 'safedeps added --ignore-scripts to this install and ran npm rebuild: exit 3' <<< "$(post_message "${rebuildquoted_post}")" \
  || fail "the command the pre-guard wrote is said as added, quoted words and all (${rebuildquoted_post})"
pass "a rebuild that fails says its exit status, and 'added' only where the command this hook received is the one safedeps wrote"

# The command's own second segment rebuilds: whether install scripts ran is not
# something this hook saw, so the skipped rebuild says what safedeps did and
# nothing about the scripts.
segment_main="${tmp_root}/segment-main"
segment_wt="${tmp_root}/segment-wt"
mkdir -p "${segment_main}/node_modules" "${segment_wt}"
ln -s "${segment_main}/node_modules" "${segment_wt}/node_modules"
printf '{"dependencies":{}}\n' > "${segment_wt}/package.json"
segment_pre=$(grammar_pre "${segment_wt}" "npm install fixture-parent@1.0.0 && npm rebuild")
segment_command=$(jq -r '.hookSpecificOutput.updatedInput.command // empty' <<< "${segment_pre:-{\}}")
[[ "${segment_command}" == *--ignore-scripts* ]] || fail "the pre-guard makes an install inert when the command rebuilds after it (${segment_pre})"
cp "${tmp_root}/revert-safe-lock.json" "${segment_wt}/package-lock.json"
: > "${segment_main}/node_modules/script-ran.txt"
segment_post=$(PATH="${stub_bin}:${PATH}" grammar_post "${segment_wt}" "${segment_command}")
grep -q 'safedeps added --ignore-scripts to this install and did not run npm rebuild: ' <<< "${segment_post}" || fail "the skipped rebuild is reported (${segment_post})"
if grep -qi 'scripts have not run' <<< "${segment_post}"; then
  fail "a skipped rebuild does not say install scripts have not run: the command's own rebuild may have run them"
fi
pass "a skipped rebuild says what safedeps did, not whether install scripts ran"

# The two facts no hook run here reaches, a project directory that does not
# resolve, are read from the functions that print them.
unresolved_dir="${tmp_root}/no-such-project"
unresolved_meta="${tmp_root}/unresolved-meta.json"
printf '{"record":2,"ignore_scripts_injected":true,"updated_command":"npm install x --ignore-scripts"}\n' > "${unresolved_meta}"
unresolved_input='{"tool_name":"Bash","tool_input":{"command":"npm install x --ignore-scripts"}}'
unresolved_lines=$(python3 "${ROOT_DIR}/scripts/measure/core-post-direct-call.py" --core "${NATIVE_TEST_CORE}" --meta "${unresolved_meta}" --input "${unresolved_input}" --project "${unresolved_dir}" --kind unresolved)
oracle_direct "${unresolved_meta}" "${unresolved_input}" "${unresolved_lines}" || exit 1
grep -q "^refused restore of ${unresolved_dir}/package-lock.json: the project directory ${unresolved_dir} cannot be resolved$" <<< "${unresolved_lines}" \
  || fail "a restore in a directory that does not resolve is refused with that as the reason"
pass "a project directory that does not resolve is the reason, in the same words"

export SAFEDEPS_HOME="${tmp_root}/safe-missing-transitive"
export SAFEDEPS_OSV_API_URL="http://127.0.0.1:${port}/osv/v1/query"
export SAFEDEPS_OSV_BATCH_API_URL="http://127.0.0.1:${port}/osv/v1/querybatch"
export SAFEDEPS_KEV_CATALOG_URL="http://127.0.0.1:${port}/kev.json"
export SAFEDEPS_GHSA_API_URL="http://127.0.0.1:${port}/advisories"
export SAFEDEPS_PROVIDER_CACHE_TTL_SECONDS=0
export SAFEDEPS_NPM_CLOSURE_FIXTURE_JSON="${closure_fixture}"
missing_project="${tmp_root}/missing-project"
mkdir -p "${missing_project}"
printf '{"dependencies":{}}\n' > "${missing_project}/package.json"
SAFEDEPS_HOME="${SAFEDEPS_HOME}" lib/ledger/ledger.sh approve npm fixture-parent 1.0.0 1.0.0 direct-only >/dev/null
missing_pre=$(
  pre_hook <<EOF
{"tool_name":"Bash","tool_input":{"command":"npm install fixture-parent@1.0.0"},"cwd":"${missing_project}","turn_id":"turn-e2e","model":"codex-test"}
EOF
)
[[ -z "${missing_pre}" ]] || fail "missing-transitive pre hook allows direct-only approved spec"
cat > "${missing_project}/package-lock.json" <<'EOF'
{
  "name": "missing-project",
  "lockfileVersion": 3,
  "packages": {
    "": {"dependencies": {"fixture-parent": "1.0.0"}},
    "node_modules/fixture-parent": {"version": "1.0.0", "dependencies": {"fixture-child": "1.0.0"}},
    "node_modules/fixture-child": {"version": "1.0.0"}
  }
}
EOF
missing_post=$(
  post_hook <<EOF
{"tool_name":"Bash","tool_input":{"command":"npm install fixture-parent@1.0.0"},"cwd":"${missing_project}"}
EOF
)
grep -q 'suspicious dependency change detected' <<< "${missing_post}" || fail "post hook reorgs unapproved transitive package"
grep -q 'fixture-child@1.0.0' <<< "${missing_post}" || fail "post hook names unapproved transitive package"
# Not just the message — the unapproved transitive must be gone from the on-disk
# lockfile. (Reorg removes the tampered lockfile; a no-network reinstall may recreate
# an empty one, so assert fixture-child is absent rather than the file itself.)
if grep -q 'fixture-child' "${missing_project}/package-lock.json" 2>/dev/null; then
  fail "post hook reorg leaves the unapproved transitive in the on-disk lockfile"
fi
pass "post hook reorgs unapproved transitive package (verified on disk)"

export SAFEDEPS_HOME="${tmp_root}/safe"
export SAFEDEPS_OSV_API_URL="http://127.0.0.1:${port}/osv/v1/query"
export SAFEDEPS_OSV_BATCH_API_URL="http://127.0.0.1:${port}/osv/v1/querybatch"
export SAFEDEPS_KEV_CATALOG_URL="http://127.0.0.1:${port}/kev.json"
export SAFEDEPS_GHSA_API_URL="http://127.0.0.1:${port}/advisories"
export SAFEDEPS_PROVIDER_CACHE_TTL_SECONDS=0
export SAFEDEPS_NPM_CLOSURE_FIXTURE_JSON="${closure_fixture}"

printf '%s\n' '{"vulnerable":["fixture-clean@1.0.0"]}' > "${state_file}"
recheck_json=$(./bin/safedeps --json re-check)
[[ "$(jq -r '.revoked | length' <<< "${recheck_json}")" == "1" ]] || fail "re-check revokes newly vulnerable spec"
[[ "$(jq -r '.revoked[0].package' <<< "${recheck_json}")" == "fixture-clean" ]] || fail "re-check revoked expected package"
pass "re-check revocation"

SAFEDEPS_HOME="${SAFEDEPS_HOME}" lib/ledger/ledger.sh approve npm fixture-forged 1.0.0 1.0.0 forged-test >/dev/null
forgery_json=$(./bin/safedeps --json re-check)
[[ "$(jq -r '.suspected_forgery | length' <<< "${forgery_json}")" == "1" ]] || fail "re-check flags direct ledger write without approval provenance"
[[ "$(jq -r '.suspected_forgery[0].package' <<< "${forgery_json}")" == "fixture-forged" ]] || fail "re-check flags expected forged package"
pass "re-check flags ledger approval provenance mismatch"

# The forgery check reads advisory.log as its oracle, so whoever can move that
# file can hand the check its own evidence. Measured before this was closed: the
# same forged entry stopped being flagged when SAFEDEPS_ADVISORY_LOG pointed at
# a caller-written file saying the approval happened. The log location is
# derived from SAFEDEPS_HOME now — the record and the ledger it vouches for move
# together or not at all — and the ignored variable says so on both channels.
moved_log="${tmp_root}/attacker-authored.log"
printf '[2026-01-01T00:00:00Z] check approve(patched closure) ecosystem=npm package=fixture-forged version=1.0.0 hash=deadbeef\n' > "${moved_log}"
moved_err="${tmp_root}/moved-log.err"
moved_json=$(SAFEDEPS_ADVISORY_LOG="${moved_log}" ./bin/safedeps --json re-check 2>"${moved_err}")
[[ "$(jq -r '.suspected_forgery | length' <<< "${moved_json}")" == "1" ]] \
  || fail "a relocated advisory log cannot supply provenance for a forged ledger entry"
grep -q 'SAFEDEPS_ADVISORY_LOG' "${moved_err}" \
  || fail "the ignored advisory-log variable is reported on stderr"
grep -q 'SAFEDEPS_ADVISORY_LOG' "${SAFEDEPS_HOME}/advisory.log" \
  || fail "the ignored advisory-log variable is recorded in the canonical log"
pass "the forgery oracle cannot be relocated by the environment it polices"

# A run that answers from a moved advisory source must not read like a run that
# answered from OSV. These knobs are legitimate — this very suite is using them —
# so they are recorded rather than refused.
grep -q 'advisory truth source moved' "${SAFEDEPS_HOME}/advisory.log" \
  || fail "a moved advisory truth source is recorded in advisory.log"
grep -q 'osv=' "${SAFEDEPS_HOME}/advisory.log" \
  || fail "the moved-truth record names which source moved"
pass "a run judged against a moved advisory source says so in the record"

# The notice has to exist on the hook path too, not only in the CLI. It used to
# live in the provider stack, which the PreToolUse guard does not source, so a
# guard run under a moved source said nothing — harmless only because the guard
# does not currently reach a provider or a fixture, which is a reason that
# disappears when the code changes.
guard_moved_home="${tmp_root}/safe-guard-moved"
mkdir -p "${guard_moved_home}" "${tmp_root}/guard-moved-project"
printf '{"dependencies":{}}\n' > "${tmp_root}/guard-moved-project/package.json"
guard_moved_payload=$(jq -nc --arg cwd "${tmp_root}/guard-moved-project" \
  '{tool_name:"Bash",tool_input:{command:"ls -la"},cwd:$cwd}')
SAFEDEPS_HOME="${guard_moved_home}" SAFEDEPS_OSV_API_URL="http://mirror.invalid/osv" \
  SAFEDEPS_NPM_OVERRIDES_JSON='{"minimist":"1.2.8"}' \
  scripts/safedeps-pre-guard.sh <<< "${guard_moved_payload}" >/dev/null 2>&1 || true
grep -q 'advisory truth source moved' "${guard_moved_home}/advisory.log" \
  || fail "the guard records a moved advisory source on its own path"
grep -q 'npm-overrides=set' "${guard_moved_home}/advisory.log" \
  || fail "the guard names the overrides knob, which the closure verdict reads"
pass "the guard has its own channel for a moved advisory source"

# And the common case stays silent, on the hook that runs for every Bash call.
guard_clean_home="${tmp_root}/safe-guard-clean"
mkdir -p "${guard_clean_home}"
# The suite itself runs under moved sources, so the unmoved case has to be
# built by removing them — which is also the honest control: this asserts the
# notice tracks the environment rather than always firing.
env -u SAFEDEPS_OSV_API_URL -u SAFEDEPS_OSV_BATCH_API_URL -u SAFEDEPS_KEV_CATALOG_URL \
  -u SAFEDEPS_GHSA_API_URL -u SAFEDEPS_NPM_CLOSURE_FIXTURE_JSON -u SAFEDEPS_YARN_INFO_FIXTURE_NDJSON \
  -u SAFEDEPS_NPM_OVERRIDES_JSON -u SAFEDEPS_RECHECK_FIXTURE_JSON -u SAFEDEPS_LEDGER_DEFAULT_TTL_DAYS \
  -u SAFEDEPS_ADVISORY_LOG \
  env SAFEDEPS_HOME="${guard_clean_home}" scripts/safedeps-pre-guard.sh <<< "${guard_moved_payload}" >/dev/null 2>&1 || true
if [[ -f "${guard_clean_home}/advisory.log" ]] && grep -q 'truth source moved' "${guard_clean_home}/advisory.log"; then
  fail "an unmoved run leaves no moved-source line"
fi
pass "an unmoved run says nothing on the hook path"

# The first version of the guard's notice took its library path from an
# environment variable and returned quietly when the file could not be read —
# an unnamed off switch for the notice, built beside the invariant that forbids
# unnamed off switches. The path comes from the script's own location now, so
# nothing in the environment can silence it.
guard_override_home="${tmp_root}/safe-guard-override"
mkdir -p "${guard_override_home}"
SAFEDEPS_HOME="${guard_override_home}" SAFEDEPS_OSV_API_URL="http://mirror.invalid/osv" \
  SAFEDEPS_TRUTH_SOURCES_LIB=/dev/null \
  scripts/safedeps-pre-guard.sh <<< "${guard_moved_payload}" >/dev/null 2>&1 || true
grep -q 'advisory truth source moved' "${guard_override_home}/advisory.log" \
  || fail "no environment variable can silence the moved-source notice"
pass "the moved-source notice cannot be switched off from the environment"

# Retired: deleting lib/truth-sources.sh cannot damage the native hook, whose
# notice is compiled in. The moved-source and override assertions above remain.
# Broken native entry is covered by hook-entry.sh's native_denies cases:
# nonzero exit/abort, non-executable or missing binary, and missing platform or
# bin/native directory all require exit 2 plus cause and recovery on stderr.

# A forged ledger entry must be flagged even when advisory.log does not exist at
# all — file absence is missing provenance, not proof of approval. (Previously
# the [[ -f advisory.log ]] precondition silently skipped the check.)
nolog_home="${tmp_root}/safe-nolog"
SAFEDEPS_HOME="${nolog_home}" lib/ledger/ledger.sh approve npm fixture-forged 1.0.0 1.0.0 forged-test >/dev/null
rm -f "${nolog_home}/advisory.log"
nolog_json=$(SAFEDEPS_HOME="${nolog_home}" ./bin/safedeps --json re-check)
[[ "$(jq -r '.suspected_forgery | length' <<< "${nolog_json}")" == "1" ]] || fail "re-check flags forged ledger entry when advisory.log is missing entirely"
[[ "$(jq -r '.suspected_forgery[0].package' <<< "${nolog_json}")" == "fixture-forged" ]] || fail "missing-log forgery flag names the forged package"
pass "re-check flags forged entry with no advisory.log (missing log = missing provenance)"

# A forged entry that copies a *valid* 64-char hash from a legitimate approval
# must not borrow that approval's provenance: the canonical hash is recomputed
# from the entry's own spec, and a stored-vs-recomputed mismatch is itself
# flagged. The legitimately approved entry in the same home must stay clean.
copyhash_home="${tmp_root}/safe-copyhash"
SAFEDEPS_HOME="${copyhash_home}" ./bin/safedeps --json check npm fixture-copysafe@1.0.0 >/dev/null
legit_entry=$(find "${copyhash_home}/approved-specs" -name '*.json' -type f | head -1)
[[ -n "${legit_entry}" ]] || fail "precondition: legit approval entry exists in copyhash home"
jq '.package = "fixture-evil" | .version = "9.9.9"' "${legit_entry}" > "${copyhash_home}/approved-specs/forged-copyhash.json"
copyhash_json=$(SAFEDEPS_HOME="${copyhash_home}" ./bin/safedeps --json re-check)
[[ "$(jq -r '.suspected_forgery | length' <<< "${copyhash_json}")" == "1" ]] || fail "re-check flags forged entry carrying a copied valid hash"
[[ "$(jq -r '.suspected_forgery[0].package' <<< "${copyhash_json}")" == "fixture-evil" ]] || fail "copied-hash forgery flag names the forged package"
[[ "$(jq -r '.suspected_forgery[0].reason' <<< "${copyhash_json}")" == "hash_spec_mismatch" ]] || fail "copied-hash forgery is flagged as hash_spec_mismatch"
pass "re-check flags copied-valid-hash forgery, keeps the legit approval clean"

# A forged entry whose package/version is a *prefix* of a legitimate approval
# (fixture-copysaf vs fixture-copysafe) must not borrow its provenance line:
# advisory.log comparison is whole-field, not substring.
SAFEDEPS_HOME="${copyhash_home}" lib/ledger/ledger.sh approve npm fixture-copysaf 1.0 1.0 prefix-forge >/dev/null
prefix_json=$(SAFEDEPS_HOME="${copyhash_home}" ./bin/safedeps --json re-check)
[[ "$(jq -r '[.suspected_forgery[] | select(.package == "fixture-copysaf")] | length' <<< "${prefix_json}")" == "1" ]] || fail "prefix-named forged entry does not borrow provenance (whole-field match)"
[[ "$(jq -r '[.suspected_forgery[] | select(.package == "fixture-copysafe")] | length' <<< "${prefix_json}")" == "0" ]] || fail "legit approval stays clean beside prefix-named forgery"
pass "re-check flags prefix-named forged entry (whole-field provenance match)"

# A forged package name carrying a backslash-octal escape (fixture-p\141d,
# where \141 is 'a') must not normalize to a legitimate name (fixture-pad) and
# borrow its provenance. The provenance match is pure-bash literal comparison,
# so the escape is never interpreted. The forged entry's own hash is honest
# (so it is not caught by hash_spec_mismatch) — only the whole-field literal
# log match keeps it flagged.
escape_home="${tmp_root}/safe-escape"
SAFEDEPS_HOME="${escape_home}" ./bin/safedeps --json check npm fixture-pad@1.0.0 >/dev/null
SAFEDEPS_HOME="${escape_home}" lib/ledger/ledger.sh approve npm 'fixture-p\141d' 1.0.0 1.0.0 escape-forge >/dev/null
escape_json=$(SAFEDEPS_HOME="${escape_home}" ./bin/safedeps --json re-check)
[[ "$(jq -r '.suspected_forgery | length' <<< "${escape_json}")" == "1" ]] || fail "backslash-escape forged name does not borrow provenance"
[[ "$(jq -r '[.suspected_forgery[] | select(.package == "fixture-pad")] | length' <<< "${escape_json}")" == "0" ]] || fail "legit fixture-pad stays clean beside escape-named forgery"
[[ "$(jq -r '.suspected_forgery[0].reason' <<< "${escape_json}")" == "missing_advisory_log_approval" ]] || fail "escape forgery flagged as missing provenance (honest hash, no log match)"
pass "re-check flags backslash-escape forged name (literal provenance match)"

# The same escape hazard applies to the version field: a forged entry with
# version 1.\060.0 (\060 is '0') must not normalize to 1.0.0 and borrow the
# legit fixture-vpad@1.0.0 approval. Its hash is honest for the literal spec,
# so only the literal log comparison keeps it flagged.
verescape_home="${tmp_root}/safe-verescape"
SAFEDEPS_HOME="${verescape_home}" ./bin/safedeps --json check npm fixture-vpad@1.0.0 >/dev/null
SAFEDEPS_HOME="${verescape_home}" lib/ledger/ledger.sh approve npm fixture-vpad '1.\060.0' '1.\060.0' verescape-forge >/dev/null
verescape_json=$(SAFEDEPS_HOME="${verescape_home}" ./bin/safedeps --json re-check)
[[ "$(jq -r '.suspected_forgery | length' <<< "${verescape_json}")" == "1" ]] || fail "backslash-escape forged version does not borrow provenance"
[[ "$(jq -r '[.suspected_forgery[] | select(.version == "1.0.0")] | length' <<< "${verescape_json}")" == "0" ]] || fail "legit fixture-vpad@1.0.0 stays clean beside escape-version forgery"
[[ "$(jq -r '.suspected_forgery[0].reason' <<< "${verescape_json}")" == "missing_advisory_log_approval" ]] || fail "escape-version forgery flagged as missing provenance"
pass "re-check flags backslash-escape forged version (literal provenance match)"

# Hash-delimiter injection: the canonical hash joins fields with newlines, so a
# real newline in package/version could shift the boundary and let a different
# tuple collide onto a legit approval's hash. A spec carrying a control char is
# rejected as malformed before any hash/provenance comparison runs.
malformed_home="${tmp_root}/safe-malformed"
SAFEDEPS_HOME="${malformed_home}" ./bin/safedeps --json check npm fixture-nl@1.0.0 >/dev/null
SAFEDEPS_HOME="${malformed_home}" lib/ledger/ledger.sh approve npm "$(printf 'fixture-x\ninjected')" 1.0.0 1.0.0 nl-forge >/dev/null
malformed_json=$(SAFEDEPS_HOME="${malformed_home}" ./bin/safedeps --json re-check)
[[ "$(jq -r '[.suspected_forgery[] | select(.reason == "malformed_spec")] | length' <<< "${malformed_json}")" == "1" ]] || fail "newline-injected ledger spec flagged as malformed_spec"
[[ "$(jq -r '[.suspected_forgery[] | select(.package == "fixture-nl")] | length' <<< "${malformed_json}")" == "0" ]] || fail "legit fixture-nl stays clean beside newline-injected forgery"
pass "re-check flags control-char (newline) injected ledger spec (hash-delimiter injection)"

legacy_home="${tmp_root}/legacy"
target_home="${tmp_root}/migrated"
mkdir -p "${legacy_home}/approved-specs"
printf 'legacy\n' > "${legacy_home}/approved-specs/example.json"
migrate_json=$(SAFEDEPS_LEGACY_HOME="${legacy_home}" SAFEDEPS_HOME="${target_home}" ./bin/safedeps --json migrate)
[[ "$(jq -r '.migrated' <<< "${migrate_json}")" == "true" ]] || fail "legacy state migrated"
[[ -f "${target_home}/approved-specs/example.json" ]] || fail "legacy state copied"
[[ ! -e "${legacy_home}" ]] || fail "legacy root archived"
pass "legacy state migration"

installer_home="${tmp_root}/installer-home"
mkdir -p "${installer_home}/.claude" "${installer_home}/.codex"
cat > "${installer_home}/.claude/settings.json" <<EOF
{"hooks":{"PreToolUse":[{"matcher":"Other","hooks":[{"type":"command","command":"~/.claude/skills/safedeps/scripts/safedeps-pre-guard.sh"}]},{"matcher":"Bash","hooks":[{"type":"command","command":"${installer_home}/.claude/skills/npm-reorg-guard/scripts/guard.sh"}]}],"PostToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"${installer_home}/.claude/skills/npm-reorg-guard/scripts/verify.sh"}]}]}}
EOF
HOME="${installer_home}" node scripts/install/install-safedeps-hooks.mjs >/dev/null
jq -e --arg pre "~/.claude/skills/safedeps/scripts/safedeps-hook-entry.sh pre" '
  [.hooks.PreToolUse[]? | select(.matcher == "Bash") | .hooks[]?.command] | index($pre)
' "${installer_home}/.claude/settings.json" >/dev/null || fail "installer writes new pre hook"
jq -e --arg post "~/.claude/skills/safedeps/scripts/safedeps-hook-entry.sh post" '
  [.hooks.PostToolUse[]?.hooks[]?.command] | index($post)
' "${installer_home}/.claude/settings.json" >/dev/null || fail "installer writes new post hook"
jq -e --arg pre "~/.codex/skills/safedeps/scripts/safedeps-hook-entry.sh pre" '
  [.hooks.PreToolUse[]?.hooks[]?.command] | index($pre)
' "${installer_home}/.codex/hooks.json" >/dev/null || fail "installer writes codex pre hook"
jq -e --arg post "~/.codex/skills/safedeps/scripts/safedeps-hook-entry.sh post" '
  [.hooks.PostToolUse[]?.hooks[]?.command] | index($post)
' "${installer_home}/.codex/hooks.json" >/dev/null || fail "installer writes codex post hook"
# Claude Code runs PostToolUseFailure, not PostToolUse, after a Bash call that
# ran and failed, so the post hook is registered there too; Codex runs
# PostToolUse after a failed Bash call and documents no PostToolUseFailure.
jq -e --arg post "~/.claude/skills/safedeps/scripts/safedeps-hook-entry.sh post" '
  [.hooks.PostToolUseFailure[]? | select(.matcher == "Bash") | .hooks[]? | select(.command == $post and .timeout == 30)] | length == 1
' "${installer_home}/.claude/settings.json" >/dev/null || fail "installer writes the claude post hook for PostToolUseFailure"
jq -e '.hooks | has("PostToolUseFailure") | not' "${installer_home}/.codex/hooks.json" >/dev/null \
  || fail "installer writes no PostToolUseFailure hook for codex"
jq -e '
  [.hooks.PreToolUse[]?, .hooks.PostToolUse[]? | select(.matcher == "Bash") | .hooks[]? | select(.command | contains("/safedeps/")) | .timeout] | all(. == 30)
' "${installer_home}/.claude/settings.json" >/dev/null || fail "installer writes claude safedeps hook timeouts"
jq -e '
  [.hooks.PreToolUse[]?, .hooks.PostToolUse[]? | select(.matcher == "Bash") | .hooks[]? | select(.command | contains("/safedeps/")) | .timeout] | all(. == 30)
' "${installer_home}/.codex/hooks.json" >/dev/null || fail "installer writes codex safedeps hook timeouts"
if jq -e '[.. | strings] | any(contains("npm-reorg-guard"))' "${installer_home}/.claude/settings.json" >/dev/null; then
  fail "installer removes legacy hook"
fi
installer_backfill_home="${tmp_root}/installer-backfill-home"
mkdir -p "${installer_backfill_home}/.claude" "${installer_backfill_home}/.codex"
cat > "${installer_backfill_home}/.codex/hooks.json" <<'EOF'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"~/.codex/skills/safedeps/scripts/safedeps-pre-guard.sh"}]}],"PostToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"~/.codex/skills/safedeps/scripts/safedeps-post-verify.sh","timeout":10}]}]}}
EOF
HOME="${installer_backfill_home}" node scripts/install/install-safedeps-hooks.mjs >/dev/null
jq -e '
  [.hooks.PreToolUse[]?, .hooks.PostToolUse[]? | select(.matcher == "Bash") | .hooks[]? | select(.command | contains("/safedeps/")) | .timeout] | length == 2 and all(. == 30)
' "${installer_backfill_home}/.codex/hooks.json" >/dev/null || fail "installer backfills existing codex safedeps hook timeouts"
pass "installer legacy cleanup and hook timeout backfill"

# The installer twice registers each hook once, and --uninstall removes the
# post hook from every event it was registered for, PostToolUseFailure too.
# A safedeps PostToolUseFailure hook in Codex's config is one nothing
# documents, and the installer removes it.
installer_twice_home="${tmp_root}/installer-twice-home"
mkdir -p "${installer_twice_home}/.claude" "${installer_twice_home}/.codex"
cat > "${installer_twice_home}/.codex/hooks.json" <<'EOF'
{"hooks":{"PostToolUseFailure":[{"matcher":"Bash","hooks":[{"type":"command","command":"~/.codex/skills/safedeps/scripts/safedeps-hook-entry.sh post","timeout":30}]}]}}
EOF
HOME="${installer_twice_home}" node scripts/install/install-safedeps-hooks.mjs >/dev/null
HOME="${installer_twice_home}" node scripts/install/install-safedeps-hooks.mjs >/dev/null
jq -e '[.hooks[]?[]? | .hooks[]? | select(.command | contains("/safedeps/"))] | length == 3' "${installer_twice_home}/.claude/settings.json" >/dev/null \
  || fail "the installer run twice registers the claude pre hook and the post hook for two events, once each"
jq -e '[.hooks[]?[]? | .hooks[]? | select(.command | contains("/safedeps/"))] | length == 2' "${installer_twice_home}/.codex/hooks.json" >/dev/null \
  || fail "the installer leaves codex with one pre and one post hook, and no PostToolUseFailure hook"
HOME="${installer_twice_home}" node scripts/install/install-safedeps-hooks.mjs --uninstall >/dev/null
for installer_cfg in "${installer_twice_home}/.claude/settings.json" "${installer_twice_home}/.codex/hooks.json"; do
  jq -e '[.hooks[]?[]? | .hooks[]? | select(.command | contains("/safedeps/"))] | length == 0' "${installer_cfg}" >/dev/null \
    || fail "--uninstall removes every safedeps hook from ${installer_cfg##*/}"
done
pass "the installer registers the claude post hook for PostToolUseFailure once, and uninstalls it"

legacy_skip_safe="${tmp_root}/safe-legacy-skip"
legacy_pending_project="${tmp_root}/legacy-pending-project"
legacy_post_project="${tmp_root}/legacy-post-project"
mkdir -p "${legacy_skip_safe}/snapshots" "${legacy_pending_project}" "${legacy_post_project}"
legacy_sid="legacy-snapshot"
legacy_pending_hash=$(printf '%s' "${legacy_pending_project}" | md5 -q 2>/dev/null || printf '%s' "${legacy_pending_project}" | md5sum | cut -d' ' -f1)
cat > "${legacy_skip_safe}/current_state" <<EOF
{"snapshot_id":"${legacy_sid}","project_dir":"${legacy_pending_project}","dir_hash":"${legacy_pending_hash}"}
EOF
cat > "${legacy_skip_safe}/snapshots/${legacy_sid}_meta.json" <<EOF
{"snapshot_id":"${legacy_sid}","project_dir":"${legacy_pending_project}"}
EOF
legacy_skip_out=$(
  SAFEDEPS_HOME="${legacy_skip_safe}" post_hook <<EOF
{"tool_name":"Bash","tool_input":{"command":"echo done"},"cwd":"${legacy_post_project}"}
EOF
)
[[ -z "${legacy_skip_out}" ]] || fail "post hook keeps unrelated Bash quiet beside a pre-#5 record"
! grep -q 'post-verify SKIP: legacy' "${legacy_skip_safe}/advisory.log" 2>/dev/null || fail "post hook reads no pre-#5 record, so it skips nothing for one"
[[ -f "${legacy_skip_safe}/current_state" ]] || fail "post hook does not consume a pre-#5 record"
pass "post hook leaves a pre-#5 record alone"

# --- Secret-leak lane: pre-commit gate must DENY a secret, PASS clean/example -
# The real bypass harness for the secret lane. Needs a scanner (gitleaks or
# docker) and openssl for a synthetic high-entropy secret; skip explicitly
# (not silently) when either is missing.
secret_repo="${tmp_root}/secret-repo"
mkdir -p "${secret_repo}"
git -C "${secret_repo}" init -q
git -C "${secret_repo}" config user.email t@safedeps.test
git -C "${secret_repo}" config user.name safedeps-e2e

# doctor flags gaps on the bare repo, then --fix scaffolds + activates the lane.
if HOME="${tmp_root}/doc-home" "${ROOT_DIR}/bin/safedeps" doctor --root "${secret_repo}" >/dev/null 2>&1; then
  fail "doctor flags gaps on an unconfigured repo"
fi
# Without a scanner (gitleaks or docker) the lane has a gap that --fix cannot
# close, and doctor exits non-zero for it. Under set -e that exit ended this
# suite in silence, with no `not ok` line, on a machine without gitleaks; the
# scaffold is still checked there, and the posture check says it was skipped.
scanner_present=false
if command -v gitleaks >/dev/null 2>&1 || command -v docker >/dev/null 2>&1; then
  scanner_present=true
fi
fix_rc=0
HOME="${tmp_root}/doc-home" "${ROOT_DIR}/bin/safedeps" doctor --fix --root "${secret_repo}" >/dev/null || fix_rc=$?
if [[ "${scanner_present}" == true ]]; then
  [[ ${fix_rc} -eq 0 ]] || fail "doctor --fix closes the secret lane when a scanner is present (rc=${fix_rc})"
fi
[[ -f "${secret_repo}/.gitleaks.toml" ]] || fail "doctor --fix scaffolds .gitleaks.toml"
[[ -x "${secret_repo}/.githooks/pre-commit" ]] || fail "doctor --fix scaffolds executable pre-commit"
[[ "$(git -C "${secret_repo}" config --get core.hooksPath)" == ".githooks" ]] || fail "doctor --fix activates core.hooksPath"
[[ ! -d "${secret_repo}/.github/workflows" ]] || fail "doctor --fix does not create remote CI workflows"
remote_json=$(HOME="${tmp_root}/doc-home" "${ROOT_DIR}/bin/safedeps" --json doctor --root "${secret_repo}") || true
if [[ "${scanner_present}" == true ]]; then
  [[ "$(jq -r '.ok' <<< "${remote_json}")" == "true" ]] || fail "doctor remains OK after local lane fix even when remote is opt-in"
else
  printf 'ok - doctor posture after --fix SKIPPED (needs gitleaks or docker)\n'
fi
remote_gap_count=$(jq -r '[.checks[] | select(.lane == "remote" and .status == "gap")] | length' <<< "${remote_json}")
[[ "${remote_gap_count}" -ge 1 ]] || fail "doctor reports missing remote workflow as opt-in gap"
pass "doctor --fix scaffolds + activates the secret lane"

# The scaffolded pre-commit resolves `safedeps` via PATH, then SAFEDEPS_BIN, then
# the skill install paths. In CI none of those exist, so point it at this repo's
# binary; the git commit subprocess inherits the env and the hook resolves it.
export SAFEDEPS_BIN="${ROOT_DIR}/bin/safedeps"

if command -v gitleaks >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1; then
  # Regression: a clean file commits cleanly.
  echo "hello" > "${secret_repo}/readme.txt"
  git -C "${secret_repo}" add readme.txt
  git -C "${secret_repo}" commit -q -m "clean" || fail "pre-commit allows a clean commit"

  # Threat: a literal .env with an assigned (synthetic) secret must be blocked.
  printf 'API_KEY=%s\n' "$(openssl rand -hex 20)" > "${secret_repo}/.env"
  git -C "${secret_repo}" add .env
  if git -C "${secret_repo}" commit -q -m "leak" 2>/dev/null; then
    fail "pre-commit blocks a committed .env secret"
  fi
  git -C "${secret_repo}" reset -q HEAD .env >/dev/null 2>&1 || true

  # Regression: the .env.example placeholder is allowlisted and commits.
  printf 'API_KEY=your_api_key_here\n' > "${secret_repo}/.env.example"
  git -C "${secret_repo}" add .env.example
  git -C "${secret_repo}" commit -q -m "example" || fail "pre-commit allows the .env.example placeholder"
  pass "pre-commit gate denies a secret, passes clean and example commits"
else
  printf 'ok - pre-commit gate behavior SKIPPED (needs gitleaks + openssl)\n'
fi

# --- Dependency audit gate (npm/pnpm/yarn/bun) — v2.5.0, multi-eco v2.9 ------
# Fake audit tools make the crucial distinction deterministic and offline: a
# vulnerable verdict (block) must never be confused with an unreachable advisory
# DB (warn + allow). If those two collapsed, an offline failover would silently
# let real vulnerabilities through. Each fake emits its tool's REAL report shape
# (npm/pnpm: .metadata.vulnerabilities; yarn: NDJSON auditSummary; bun: object
# keyed by package), switched by a per-tool MODE env (default clean).
fakebin="${tmp_root}/fakebin"
mkdir -p "${fakebin}"
cat > "${fakebin}/npm" <<'FAKE'
#!/bin/bash
[ "${1:-}" = "audit" ] || exit 0
case "${FAKE_NPM_MODE:-clean}" in
  clean)   printf '%s\n' '{"auditReportVersion":2,"vulnerabilities":{},"metadata":{"vulnerabilities":{"info":0,"low":0,"moderate":0,"high":0,"critical":0,"total":0}}}'; exit 0 ;;
  vuln)    printf '%s\n' '{"auditReportVersion":2,"vulnerabilities":{"hono":{"name":"hono","severity":"moderate","via":[{"title":"JWT"}]}},"metadata":{"vulnerabilities":{"info":0,"low":0,"moderate":4,"high":0,"critical":0,"total":4}}}'; exit 1 ;;
  offline) printf '%s\n' '{"error":{"code":"ENOTFOUND","summary":"registry unreachable"}}'; exit 1 ;;
esac
FAKE
cat > "${fakebin}/pnpm" <<'FAKE'
#!/bin/bash
[ "${1:-}" = "audit" ] || exit 0
case "${FAKE_PNPM_MODE:-clean}" in
  clean)   printf '%s\n' '{"actions":[],"advisories":{},"metadata":{"vulnerabilities":{"info":0,"low":0,"moderate":0,"high":0,"critical":0}}}'; exit 0 ;;
  vuln)    printf '%s\n' '{"advisories":{"x":{}},"metadata":{"vulnerabilities":{"info":0,"low":0,"moderate":1,"high":0,"critical":1}}}'; exit 1 ;;
  offline) printf '%s\n' '{"error":{"code":"ECONNREFUSED","message":"request failed"}}'; exit 1 ;;
esac
FAKE
cat > "${fakebin}/yarn" <<'FAKE'
#!/bin/bash
# FAKE_YARN_BERRY=1 emulates Yarn Berry (2+): `yarn --version` is 4.x and audit
# lives under `yarn npm audit` (NDJSON advisory lines). Default is Classic 1.x.
if [ "${FAKE_YARN_BERRY:-0}" = "1" ]; then
  [ "${1:-}" = "--version" ] && { printf '4.5.0\n'; exit 0; }
  if [ "${1:-}" = "npm" ] && [ "${2:-}" = "audit" ]; then
    case " $* " in *' --all '*) ;; *) exit 90 ;; esac
    case " $* " in *' --recursive '*) ;; *) exit 91 ;; esac
    case "${FAKE_YARN_MODE:-clean}" in
      clean)   exit 0 ;;
      vuln)    printf '%s\n' '{"value":"minimist","children":{"ID":1,"Severity":"high"}}'; printf '%s\n' '{"value":"x","children":{"ID":2,"Severity":"moderate"}}'; exit 1 ;;
      weirdsev) printf '%s\n' '{"value":"minimist","children":{"ID":1,"Severity":"Critical"}}'; exit 1 ;;
      offline) exit 1 ;;
    esac
  fi
  exit 0
fi
[ "${1:-}" = "--version" ] && { printf '1.22.22\n'; exit 0; }
[ "${1:-}" = "audit" ] || exit 0
case "${FAKE_YARN_MODE:-clean}" in
  clean)   printf '%s\n' '{"type":"auditSummary","data":{"vulnerabilities":{"info":0,"low":0,"moderate":0,"high":0,"critical":0}}}'; exit 0 ;;
  vuln)    printf '%s\n' '{"type":"auditAdvisory","data":{}}'; printf '%s\n' '{"type":"auditSummary","data":{"vulnerabilities":{"info":0,"low":0,"moderate":0,"high":2,"critical":0}}}'; exit 8 ;;
  offline) printf '%s\n' '{"type":"info","data":"Visit https://yarnpkg.com/en/docs/cli/audit"}'; exit 1 ;;
esac
FAKE
cat > "${fakebin}/bun" <<'FAKE'
#!/bin/bash
[ "${1:-}" = "audit" ] || exit 0
case "${FAKE_BUN_MODE:-clean}" in
  clean)     printf '%s\n' '{}'; exit 0 ;;
  vuln)      printf '%s\n' '{"minimist":[{"id":1,"severity":"critical"},{"id":2,"severity":"moderate"}]}'; exit 1 ;;
  offline)   printf ''; exit 1 ;;
  # Fail-closed edges (bun re-tallies raw severities; these must NOT read as clean):
  malformed) printf '%s\n' '{"meta":{"x":1},"minimist":[{"id":1,"severity":"high"}]}'; exit 1 ;;
  capital)   printf '%s\n' '{"minimist":[{"id":1,"severity":"CRITICAL"}]}'; exit 1 ;;
  nosev)     printf '%s\n' '{"minimist":[{"id":1}]}'; exit 1 ;;
  # Could-not-run shapes (registry/error object, non-advisory junk): availability
  # failure -> must be exit 2, never a silent clean, matching the npm path.
  errobj)    printf '%s\n' '{"error":{"code":"ENOTFOUND","message":"registry unreachable"}}'; exit 1 ;;
  junkobj)   printf '%s\n' '{"some":"object","not":"advisories"}'; exit 1 ;;
esac
FAKE
chmod +x "${fakebin}/npm" "${fakebin}/pnpm" "${fakebin}/yarn" "${fakebin}/bun"

if command -v jq >/dev/null 2>&1; then
  # Explicit-ecosystem path (back-compat): `safedeps audit npm`.
  audit_repo="${tmp_root}/audit-repo"
  mkdir -p "${audit_repo}"
  printf '{"name":"a","lockfileVersion":3}\n' > "${audit_repo}/package-lock.json"
  run_audit() {
    PATH="${fakebin}:${PATH}" FAKE_NPM_MODE="$1" \
      "${ROOT_DIR}/bin/safedeps" audit npm --root "${audit_repo}" >/dev/null 2>&1
  }
  run_audit clean   && rc=0 || rc=$?; [ "${rc}" = "0" ] || fail "audit exit 0 on a clean lockfile (got ${rc})"
  run_audit vuln    && rc=0 || rc=$?; [ "${rc}" = "1" ] || fail "audit exit 1 on a vulnerable lockfile (got ${rc})"
  run_audit offline && rc=0 || rc=$?; [ "${rc}" = "2" ] || fail "audit exit 2 when the advisory DB is unreachable (got ${rc})"
  pass "audit npm exit-code contract: clean=0 / vulnerable=1 / unreachable=2"

  # Auto-detect path across every ecosystem: a single lockfile in the dir routes
  # `safedeps audit` (no arg) to the right tool, and each must honor 0/1/2.
  for spec in "npm:package-lock.json:FAKE_NPM_MODE" \
              "pnpm:pnpm-lock.yaml:FAKE_PNPM_MODE" \
              "yarn:yarn.lock:FAKE_YARN_MODE" \
              "bun:bun.lock:FAKE_BUN_MODE"; do
    eco="${spec%%:*}"; rest="${spec#*:}"; lf="${rest%%:*}"; modevar="${rest##*:}"
    eco_dir="${tmp_root}/audit-${eco}"; mkdir -p "${eco_dir}"; : > "${eco_dir}/${lf}"
    for pair in "clean:0" "vuln:1" "offline:2"; do
      mode="${pair%%:*}"; want="${pair#*:}"
      PATH="${fakebin}:${PATH}" env "${modevar}=${mode}" \
        "${ROOT_DIR}/bin/safedeps" audit --root "${eco_dir}" >/dev/null 2>&1 && rc=0 || rc=$?
      [ "${rc}" = "${want}" ] || fail "audit auto-detect ${eco} ${mode}: expected ${want}, got ${rc}"
    done
  done
  pass "audit exit-code contract across npm/pnpm/yarn/bun (auto-detect; clean=0/vuln=1/offline=2)"

  # Aggregate across coexisting lockfiles: a real finding in ANY ecosystem
  # dominates (1); else an availability failure anywhere surfaces as 2; no
  # ecosystem is skipped silently.
  agg_dir="${tmp_root}/audit-agg"; mkdir -p "${agg_dir}"
  : > "${agg_dir}/package-lock.json"; : > "${agg_dir}/pnpm-lock.yaml"
  PATH="${fakebin}:${PATH}" FAKE_NPM_MODE=clean FAKE_PNPM_MODE=vuln \
    "${ROOT_DIR}/bin/safedeps" audit --root "${agg_dir}" >/dev/null 2>&1 && rc=0 || rc=$?
  [ "${rc}" = "1" ] || fail "aggregate audit: a vuln in any ecosystem blocks (npm clean + pnpm vuln, got ${rc})"
  PATH="${fakebin}:${PATH}" FAKE_NPM_MODE=clean FAKE_PNPM_MODE=offline \
    "${ROOT_DIR}/bin/safedeps" audit --root "${agg_dir}" >/dev/null 2>&1 && rc=0 || rc=$?
  [ "${rc}" = "2" ] || fail "aggregate audit: availability failure surfaces as 2 when nothing is vulnerable (got ${rc})"
  pass "aggregate audit across coexisting lockfiles (vuln dominates; else availability)"

  # bun re-tallies raw per-advisory severities (npm/pnpm/yarn report pre-aggregated
  # counts). The tally must be total (an unexpected shape must not crash and read as
  # CLEAN) and fail-closed (a missing/unrecognized severity counts, never dropped).
  # Each of these carries a real advisory, so audit must BLOCK (1), never exit 0.
  bun_dir="${tmp_root}/audit-bun-edge"; mkdir -p "${bun_dir}"; : > "${bun_dir}/bun.lock"
  for bmode in malformed capital nosev; do
    PATH="${fakebin}:${PATH}" FAKE_BUN_MODE="${bmode}" \
      "${ROOT_DIR}/bin/safedeps" audit --root "${bun_dir}" >/dev/null 2>&1 && rc=0 || rc=$?
    [ "${rc}" = "1" ] || fail "bun audit fail-closed on ${bmode} advisory (expected block=1, got ${rc} — silent clean is a no-silent-fallback violation)"
  done
  # A registry/error object or non-advisory junk is an availability failure: it must
  # surface as could-not-run (2), never a silent clean (0) — parity with the npm path.
  for bmode in errobj junkobj; do
    PATH="${fakebin}:${PATH}" FAKE_BUN_MODE="${bmode}" \
      "${ROOT_DIR}/bin/safedeps" audit --root "${bun_dir}" >/dev/null 2>&1 && rc=0 || rc=$?
    [ "${rc}" = "2" ] || fail "bun audit maps a ${bmode} (non-advisory) response to could-not-run=2 (got ${rc}; exit 0 would be a silent clean)"
  done
  pass "bun audit is total + fail-closed (vuln shapes block; error/junk shapes -> could-not-run, never silent clean)"

  # --level validation: an unrecognized level must be a usage error (64), not
  # silently snapped to moderate (which would let a deliberately-strict typo pass).
  PATH="${fakebin}:${PATH}" "${ROOT_DIR}/bin/safedeps" audit npm --root "${audit_repo}" --level garbage >/dev/null 2>&1 && rc=0 || rc=$?
  [ "${rc}" = "64" ] || fail "audit rejects an invalid --level with usage error 64 (got ${rc})"
  pass "audit --level validates the threshold (invalid -> 64, not a silent moderate fallback)"

  # Yarn Berry (2+) has no `yarn audit`; the dispatcher must detect the major
  # version and route to `yarn npm audit` (NDJSON), honoring the same 0/1/2.
  berry_dir="${tmp_root}/audit-yarn-berry"; mkdir -p "${berry_dir}"; : > "${berry_dir}/yarn.lock"
  for pair in "clean:0" "vuln:1" "offline:2"; do
    mode="${pair%%:*}"; want="${pair#*:}"
    PATH="${fakebin}:${PATH}" FAKE_YARN_BERRY=1 FAKE_YARN_MODE="${mode}" \
      "${ROOT_DIR}/bin/safedeps" audit --root "${berry_dir}" >/dev/null 2>&1 && rc=0 || rc=$?
    [ "${rc}" = "${want}" ] || fail "yarn Berry audit ${mode}: expected ${want}, got ${rc}"
  done
  # Berry re-tallies raw severities too, so a non-canonical value must fail-closed
  # (count as critical -> block), never be dropped to a clean verdict.
  PATH="${fakebin}:${PATH}" FAKE_YARN_BERRY=1 FAKE_YARN_MODE=weirdsev \
    "${ROOT_DIR}/bin/safedeps" audit --root "${berry_dir}" >/dev/null 2>&1 && rc=0 || rc=$?
  [ "${rc}" = "1" ] || fail "yarn Berry fail-closed on a non-canonical severity (expected block=1, got ${rc})"
  pass "yarn Berry (2+) uses '--all --recursive', honors 0/1/2, fail-closed on odd severities"

  # no-jq fallback must ALSO version-route yarn: running 'yarn audit' (which Berry
  # removed) unconditionally would block every clean Berry repo. With jq absent, a
  # clean Berry project must still return 0.
  nojq_bin="${tmp_root}/nojq-bin"; mkdir -p "${nojq_bin}"
  for t in bash env dirname mktemp cat grep sed; do
    src="$(command -v "${t}" 2>/dev/null)" && ln -sf "${src}" "${nojq_bin}/${t}"
  done
  ln -sf "${fakebin}/yarn" "${nojq_bin}/yarn"   # Berry fake (clean -> 'yarn npm audit' exit 0)
  PATH="${nojq_bin}" FAKE_YARN_BERRY=1 FAKE_YARN_MODE=clean \
    bash "${ROOT_DIR}/lib/gates/audit.sh" --root "${berry_dir}" >/dev/null 2>&1 && rc=0 || rc=$?
  [ "${rc}" = "0" ] || fail "no-jq fallback routes Yarn Berry to 'yarn npm audit'; a clean Berry repo must return 0 (got ${rc})"
  pass "no-jq fallback version-routes yarn with '--all --recursive' (clean Berry not falsely blocked)"
else
  printf 'ok - audit exit-code contract SKIPPED (needs jq)\n'
fi

if command -v gitleaks >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  dep_repo="${tmp_root}/dep-repo"
  mkdir -p "${dep_repo}"
  git -C "${dep_repo}" init -q
  git -C "${dep_repo}" config user.email t@safedeps.test
  git -C "${dep_repo}" config user.name safedeps-e2e
  HOME="${tmp_root}/doc-home" "${ROOT_DIR}/bin/safedeps" doctor --fix --root "${dep_repo}" >/dev/null
  printf '{"name":"a","lockfileVersion":3}\n' > "${dep_repo}/package-lock.json"
  git -C "${dep_repo}" add package-lock.json

  # Threat: a vulnerable dependency must BLOCK the commit (fail-closed verdict).
  if PATH="${fakebin}:${PATH}" FAKE_NPM_MODE=vuln SAFEDEPS_BIN="${ROOT_DIR}/bin/safedeps" \
       git -C "${dep_repo}" commit -q -m "vuln" 2>/dev/null; then
    fail "pre-commit blocks a commit carrying a vulnerable dependency"
  fi

  # Availability failover: an unreachable advisory DB must WARN and ALLOW.
  offline_out="$(PATH="${fakebin}:${PATH}" FAKE_NPM_MODE=offline SAFEDEPS_BIN="${ROOT_DIR}/bin/safedeps" \
       git -C "${dep_repo}" commit -m "offline" 2>&1)" \
    || fail "pre-commit allows the commit when the advisory DB is unreachable (offline failover)"
  grep -q "offline failover" <<< "${offline_out}" || fail "offline failover prints an observable warning"

  # Multi-ecosystem: the scaffolded hook detects a non-npm lockfile too and
  # routes `safedeps audit` (auto-detect) to it. A pnpm-lock.yaml with a
  # vulnerable verdict must BLOCK exactly like npm.
  pnpm_repo="${tmp_root}/dep-repo-pnpm"
  mkdir -p "${pnpm_repo}"
  git -C "${pnpm_repo}" init -q
  git -C "${pnpm_repo}" config user.email t@safedeps.test
  git -C "${pnpm_repo}" config user.name safedeps-e2e
  HOME="${tmp_root}/doc-home" "${ROOT_DIR}/bin/safedeps" doctor --fix --root "${pnpm_repo}" >/dev/null
  printf 'lockfileVersion: "9.0"\n' > "${pnpm_repo}/pnpm-lock.yaml"
  git -C "${pnpm_repo}" add pnpm-lock.yaml
  if PATH="${fakebin}:${PATH}" FAKE_PNPM_MODE=vuln SAFEDEPS_BIN="${ROOT_DIR}/bin/safedeps" \
       git -C "${pnpm_repo}" commit -q -m "pnpm vuln" 2>/dev/null; then
    fail "pre-commit blocks a commit carrying a vulnerable pnpm dependency"
  fi
  pass "pre-commit dep gate: blocks on vuln, warns+allows when offline (npm + pnpm)"
else
  printf 'ok - pre-commit dep gate SKIPPED (needs gitleaks + jq)\n'
fi


# --- npm `overrides` verdict path -------------------------------------------
# The closure fixture short-circuits before the probe, so it cannot cover the
# overrides path. Stub `npm` instead: the stub emits a lockfile whose resolved
# transitive depends on whether the probe manifest carried `overrides`. That
# makes the whole chain deterministic -- discovery, probe manifest, resolved
# closure, OSV verdict -- with no registry access.
ov_npm_bin="${tmp_root}/ov-npm-bin"
mkdir -p "${ov_npm_bin}"
cat > "${ov_npm_bin}/npm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# Only the closure probe is stubbed; anything else is not part of this test.
[[ "${1:-}" == "install" ]] || exit 64
pinned=$(jq -r '.overrides.minimist // "0.0.8"' package.json 2>/dev/null || printf '0.0.8')
cat > package-lock.json <<JSON
{"lockfileVersion":3,"packages":{
  "":{"name":"safedeps-closure-probe","version":"0.0.0"},
  "node_modules/mkdirp":{"name":"mkdirp","version":"0.5.1"},
  "node_modules/minimist":{"name":"minimist","version":"${pinned}"}
}}
JSON
EOF
chmod +x "${ov_npm_bin}/npm"

printf '%s\n' '{"vulnerable":["minimist@0.0.8","minimist@0.2.0"]}' > "${state_file}"

ov_patched_repo="${tmp_root}/ov-verdict-patched"
mkdir -p "${ov_patched_repo}"; git -C "${ov_patched_repo}" init -q
printf '{"name":"p","version":"0.0.0","private":true,"overrides":{"minimist":"1.2.8"}}\n' > "${ov_patched_repo}/package.json"

ov_vuln_repo="${tmp_root}/ov-verdict-vuln"
mkdir -p "${ov_vuln_repo}"; git -C "${ov_vuln_repo}" init -q
printf '{"name":"v","version":"0.0.0","private":true,"overrides":{"minimist":"0.2.0"}}\n' > "${ov_vuln_repo}/package.json"

ov_bare_repo="${tmp_root}/ov-verdict-bare"
mkdir -p "${ov_bare_repo}"; git -C "${ov_bare_repo}" init -q
printf '{"name":"b","version":"0.0.0","private":true}\n' > "${ov_bare_repo}/package.json"

ov_run() {
  local dir="$1" home="$2"
  ( cd "${dir}" && env -u SAFEDEPS_NPM_CLOSURE_FIXTURE_JSON \
      PATH="${ov_npm_bin}:${PATH}" SAFEDEPS_HOME="${home}" \
      "${ROOT_DIR}/bin/safedeps" --json check npm mkdirp@0.5.1 2>/dev/null )
}

ov_home="${tmp_root}/ov-verdict-home"
ov_patched_json=$(ov_run "${ov_patched_repo}" "${ov_home}") || true
[[ "$(jq -r '.result' <<< "${ov_patched_json}")" == "clean" ]] \
  || fail "a patched override yields a clean verdict (got: $(jq -rc '.result' <<< "${ov_patched_json}"))"
[[ "$(jq -r '.closure_source.type' <<< "${ov_patched_json}")" == "npm-overrides-probe" ]] \
  || fail "an overrides-derived approval records its overrides context"

ov_vuln_json=$(ov_run "${ov_vuln_repo}" "${tmp_root}/ov-verdict-home-vuln") || true
[[ "$(jq -r '.approved' <<< "${ov_vuln_json}")" == "false" ]] \
  || fail "an override pointing at a still-vulnerable version is not hidden"

# The approval above was earned under one override set; a repo without it must
# not inherit that approval, because its real install resolves the vulnerable
# transitive.
ov_bare_json=$(ov_run "${ov_bare_repo}" "${ov_home}") || true
[[ "$(jq -r '.approved' <<< "${ov_bare_json}")" == "false" ]] \
  || fail "an overrides-scoped approval does not leak into a repo without those overrides"
ov_reuse_json=$(ov_run "${ov_patched_repo}" "${ov_home}") || true
[[ "$(jq -r '.result' <<< "${ov_reuse_json}")" == "already_approved" ]] \
  || fail "the same override set reuses its own approval (got: $(jq -rc '.result' <<< "${ov_reuse_json}"))"
printf 'ok - npm overrides drive the verdict and their approval stays scoped\n'

# The guard has to derive the same key the approval was stored under, or a
# legitimately approved install looks unapproved at the gate.
ov_guard_decision() {
  local dir="$1"
  jq -nc --arg c 'npm install mkdirp@0.5.1' --arg cwd "${dir}" \
    '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}' \
    | ( cd "${dir}" && HOME="${ov_home}" SAFEDEPS_HOME="${ov_home}" \
        PATH="${ov_npm_bin}:${PATH}" native_fixture_hook pre 2>/dev/null ) \
    | jq -r '.hookSpecificOutput.permissionDecision // "allow"'
}
[[ "$(ov_guard_decision "${ov_patched_repo}")" == "allow" ]] \
  || fail "the guard reproduces the overrides approval key for the repo that earned it"
[[ "$(ov_guard_decision "${ov_bare_repo}")" == "deny" ]] \
  || fail "the guard does not accept an overrides-scoped approval in a repo without those overrides"
printf 'ok - pre-guard derives the same overrides approval key as the check\n'

# --- rollback journal: an interrupted rollback must not vanish ---------------
#
# Measured before this existed (scripts/measure/rollback-kill-state.sh): kill the
# post hook anywhere inside its rollback and reorg.log was zero lines. The
# project had been reverted and nothing said so. These two checks pin both
# directions: an unfinished rollback is reported, and a finished one is not.

journal_home="${tmp_root}/journal-home"
journal_project="${tmp_root}/journal-project"
mkdir -p "${journal_home}" "${journal_project}" "${tmp_root}/journal-linked-modules"
# The project's node_modules links to another checkout's, so the report's
# advice must not send npm ci there (npm ci empties what node_modules resolves to).
printf '{"name":"journal-project","version":"1.0.0"}\n' > "${journal_project}/package.json"
ln -s "${tmp_root}/journal-linked-modules" "${journal_project}/node_modules"
# A yarn project: it has a lockfile, just not npm's, so "no lockfile" is false.
: > "${journal_project}/yarn.lock"

# An unfinished rollback, written the way the gate writes it before it starts
# restoring files.
( export SAFEDEPS_HOME="${journal_home}"
  . "${ROOT_DIR}/lib/gates/rollback-journal.sh"
  safedeps_journal_open 'test-interrupted' "${journal_project}" 'snap-baseline' \
    'npm closure contains 1 unapproved package(s): fixture-evil@9.9.9' \
    'removing-node-modules' )

# ...and its owner has to be genuinely gone, because "interrupted" now means
# "the process that opened this is not running". `safedeps_journal_open` stamps
# `$$`, which inside `( … )` is this script's pid, not the subshell's — so the
# fixture above describes a rollback owned by a live process. That went unnoticed
# while nothing read the field. Substitute a pid that is really dead.
# The redirect is load-bearing: a background job inheriting the command
# substitution's stdout keeps that pipe open, so `$( … )` would block until the
# sleep exited rather than returning its pid.
journal_dead_owner_probe() { ( cd "${tmp_root}" && exec bash -c 'exec -a "$0" sleep 60' "${E2E_CHILD_MARKER}" ) >/dev/null 2>&1 & echo $!; }
journal_dead_pid=$(journal_dead_owner_probe)
owned_children+=("${journal_dead_pid}")
kill -9 "${journal_dead_pid}" 2>/dev/null
# Not a child of this shell — it was spawned inside the command substitution —
# so `wait` would return 127 and `set -e` would end the run. Poll instead.
journal_reap=0
while kill -0 "${journal_dead_pid}" 2>/dev/null && (( journal_reap < 100 )); do
  sleep 0.05; journal_reap=$((journal_reap + 1))
done
journal_entry_file="${journal_home}/rollback-journal/test-interrupted.json"
jq -c --arg pid "${journal_dead_pid}" '.pid = $pid' "${journal_entry_file}" \
  > "${journal_entry_file}.tmp" && mv "${journal_entry_file}.tmp" "${journal_entry_file}"

journal_report=$(
  SAFEDEPS_HOME="${journal_home}" post_hook <<EOF
{"tool_name":"Bash","tool_input":{"command":"echo unrelated"},"cwd":"${journal_project}"}
EOF
)
grep -q 'did not finish' <<< "${journal_report}" \
  || fail "an unfinished rollback is reported on the next Bash call"
grep -q 'removing-node-modules' <<< "${journal_report}" \
  || fail "the unfinished-rollback report names the stage it was cut off at"
grep -q 'fixture-evil@9.9.9' <<< "${journal_report}" \
  || fail "the unfinished-rollback report says why the rollback was started"
grep -q 'node_modules is a symbolic link to' <<< "${journal_report}" \
  || fail "the unfinished-rollback report says the node_modules is a link"
assert_gives_no_command "${journal_report}" "the unfinished-rollback report gives no reinstall command"
if grep -q 'no lockfile' <<< "${journal_report}"; then
  fail "the unfinished-rollback report does not call a yarn project lockless"
fi
grep -q 'the snapshot snap-baseline has no list of monitored files' <<< "${journal_report}" \
  || fail "the unfinished-rollback report says the snapshot it names has no list to compare against"
if grep -qiE 'most likely|may be in a mixed state|timeout' <<< "${journal_report}"; then
  fail "the unfinished-rollback report gives no cause and no guess about the tree"
fi
grep -q 'REORG INTERRUPTED' "${journal_home}/reorg.log" \
  || fail "an interrupted rollback lands in the same log the finished ones use"
[[ -f "${journal_home}/rollback-incidents/test-interrupted.json" ]] \
  || fail "the interrupted rollback is kept as a durable incident record"
[[ -z "$(find "${journal_home}/rollback-journal" -maxdepth 1 -name '*.json' 2>/dev/null)" ]] \
  || fail "a reported journal entry is cleared from the open-journal directory"

# Reported once, not on every command from here on.
journal_repeat=$(
  SAFEDEPS_HOME="${journal_home}" post_hook <<EOF
{"tool_name":"Bash","tool_input":{"command":"echo unrelated"},"cwd":"${journal_project}"}
EOF
)
grep -q 'did not finish' <<< "${journal_repeat}" \
  && fail "an already-reported rollback is reported again on every later command"
printf 'ok - an interrupted rollback is reported, logged, and kept as an incident\n'

# The other direction: the rollback that DID finish must leave no journal entry,
# or every clean run would cry interrupted on the next command.
[[ -z "$(find "${SAFEDEPS_HOME}/rollback-journal" -maxdepth 1 -name '*.json' 2>/dev/null)" ]] \
  || fail "a completed rollback leaves an open journal entry behind"
printf 'ok - a completed rollback leaves no journal entry\n'

# --- rollback journal: a rollback still RUNNING is not "interrupted" ---------
#
# The journal is read at the top of every post hook, and PostToolUse fires on
# every Bash call. So an unrelated command landing inside a rollback used to
# read that rollback's own live entry and report it as interrupted — measured in
# scripts/measure/rollback-concurrent-report.sh, which produced REORG INTERRUPTED
# and REORG executed in one log plus an incident file, for a rollback that
# worked. The state lock cannot fix this: the post hook releases it before the
# rollback starts, so the rollback runs unlocked.
#
# Liveness of the journal's own pid is the discriminator, and these pin all
# three ways it has to answer.

race_home="${tmp_root}/journal-race-home"
race_project="${tmp_root}/journal-race-project"
mkdir -p "${race_home}" "${race_project}"

# A stand-in for a rollback that is still working. It has to be a bash process,
# because that is what the owner check accepts and what a hook actually is —
# a `sleep` here would pass the test for the wrong reason.
# Spawned with cwd outside the plan worktree. An orphan that survives anyway
# then holds a directory nobody is trying to delete, so it cannot make the
# close gate refuse removal at finalize -- that is what actually bit, not the
# process itself.
( cd "${tmp_root}" && exec bash -c 'exec -a "$0" sleep 120' "${E2E_CHILD_MARKER}" ) >/dev/null 2>&1 &
race_owner_pid=$!
owned_children+=("${race_owner_pid}")

race_write_entry() {
  local pid="$1" opened_at="$2"
  mkdir -p "${race_home}/rollback-journal"
  jq -nc --arg pid "${pid}" --arg opened_at "${opened_at}" \
    '{journal_id:"test-race", project_dir:"'"${race_project}"'",
      rollback_snapshot:"snap-baseline", reasons:"npm closure contains 1 unapproved package(s): fixture-evil@9.9.9",
      stage:"removing-node-modules", opened_at:$opened_at, pid:$pid}' \
    > "${race_home}/rollback-journal/test-race.json"
}

race_report() {
  SAFEDEPS_HOME="${race_home}" post_hook <<EOF
{"tool_name":"Bash","tool_input":{"command":"echo unrelated"},"cwd":"${race_project}"}
EOF
}

# 1. The owner is alive and started before the entry — a rollback in progress.
race_write_entry "${race_owner_pid}" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
race_live=$(race_report)
grep -q 'did not finish' <<< "${race_live}" \
  && fail "a rollback that is still running is reported as interrupted"
[[ -f "${race_home}/rollback-journal/test-race.json" ]] \
  || fail "a running rollback's journal entry is consumed by an unrelated command"
[[ ! -f "${race_home}/reorg.log" ]] || ! grep -q 'REORG INTERRUPTED' "${race_home}/reorg.log" \
  || fail "a running rollback puts a REORG INTERRUPTED line in the log"

# 2. pid reuse must not buy silence. An entry whose pid belongs to a process
#    that started AFTER the entry was opened cannot be that rollback, and the
#    silent direction is the dangerous one: a recycled pid would hide a real
#    interrupted rollback forever.
race_write_entry "${race_owner_pid}" "1999-01-01T00:00:00Z"
race_reused=$(race_report)
grep -q 'did not finish' <<< "${race_reused}" \
  || fail "an entry whose pid was recycled by a later process is reported"

#    ...and the same crossing while that recycled pid happens to be STOPPED. The
#    stopped answer is about a rollback that can resume; it must not apply to a
#    process that was never this rollback. Ordered wrong, this reported a
#    genuinely interrupted rollback as "suspended — resume it", which signals a
#    bystander and defers the repair the project needs.
kill -STOP "${race_owner_pid}" 2>/dev/null
sleep 0.3
race_write_entry "${race_owner_pid}" "1999-01-01T00:00:00Z"
race_reused_stopped=$(race_report)
kill -CONT "${race_owner_pid}" 2>/dev/null
grep -q 'did not finish' <<< "${race_reused_stopped}" \
  || fail "a recycled pid that is stopped is still reported as an unfinished rollback"
grep -q 'has not finished' <<< "${race_reused_stopped}" \
  && fail "a recycled pid that is stopped must not be reported as a stopped rollback"
grep -q "Owner: pid ${race_owner_pid} started after the journal was opened" <<< "${race_reused_stopped}" \
  || fail "a recycled pid is reported as the process it is: one that started after the journal was opened"

# 3. The owner dies mid-rollback — the case the journal exists for.
kill -9 "${race_owner_pid}" 2>/dev/null
# `wait` on a SIGKILLed child returns 137 and `set -e` would end the run here.
race_reap=0
while kill -0 "${race_owner_pid}" 2>/dev/null && (( race_reap < 100 )); do
  sleep 0.05; race_reap=$((race_reap + 1))
done
race_write_entry "${race_owner_pid}" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
race_dead=$(race_report)
grep -q 'did not finish' <<< "${race_dead}" \
  || fail "a rollback whose process died is still reported as interrupted"
printf 'ok - a running rollback is not reported as interrupted (dead and recycled pids still are)\n'

# 4. An unreaped (zombie) owner is not running, and it clears every other test
#    here: it keeps its process table entry so `kill -0` succeeds, and it keeps
#    its own start time so the reuse check passes. A hook the runtime killed and
#    whose parent has not reaped yet is exactly that — the case the journal
#    exists to report. Worse than a single miss: a zombie does not go away, so
#    every later command would answer the same and the report is lost for good.
#
#    bash reaps its own children promptly, so the zombie needs a parent that
#    does not wait.
python3 -c '
import os, sys, time
pid = os.fork()
if pid == 0:
    os._exit(0)
open("'"${tmp_root}"'/zombie-pid", "w").write(str(pid))
time.sleep(30)
' >/dev/null 2>&1 &
race_zombie_parent=$!
race_zwait=0
while [[ ! -s "${tmp_root}/zombie-pid" ]] && (( race_zwait < 100 )); do
  sleep 0.05; race_zwait=$((race_zwait + 1))
done
race_zombie_pid=$(cat "${tmp_root}/zombie-pid" 2>/dev/null)
if [[ -n "${race_zombie_pid}" ]] && [[ "$(ps -o stat= -p "${race_zombie_pid}" 2>/dev/null)" == Z* ]]; then
  race_write_entry "${race_zombie_pid}" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  race_zombie_out=$(race_report)
  grep -q 'did not finish' <<< "${race_zombie_out}" \
    || fail "a rollback whose owner is an unreaped zombie is reported, not suppressed"
  printf 'ok - an unreaped (zombie) owner does not suppress the report\n'

# 5. A STOPPED owner is neither. It has not died — SIGCONT resumes it — and it
#    is not progressing. Folding it into the pair is wrong both ways: called
#    gone, a resumable rollback is reported as unfinished (the false-report
#    defect); called running, a rollback stopped forever is never reported (the
#    zombie defect). So it is its own answer, and the report says the owner pid
#    is stopped. It gives no command: what to do with that process is the
#    reader's call, and the README says how to read the line.
( cd "${tmp_root}" && exec bash -c 'exec -a "$0" sleep 120' "${E2E_CHILD_MARKER}" ) >/dev/null 2>&1 &
race_stopped_pid=$!
owned_children+=("${race_stopped_pid}")
sleep 0.3
kill -STOP "${race_stopped_pid}" 2>/dev/null
sleep 0.3
if [[ "$(ps -o stat= -p "${race_stopped_pid}" 2>/dev/null)" == *T* ]]; then
  race_write_entry "${race_stopped_pid}" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  race_stopped_out=$(race_report)
  grep -q 'has not finished' <<< "${race_stopped_out}" \
    || fail "a stopped owner is reported as a rollback that has not finished, not as one that did not"
  # The bash hook asks ps and says `ps state`; the core reads the process
  # table itself and says `process state`, since it ran no ps. The report
  # oracle takes both spellings, and so does this row.
  grep -qE "Owner: pid ${race_stopped_pid} is stopped \((ps|process) state " <<< "${race_stopped_out}" \
    || fail "the stopped report says the owner pid is stopped"
  if grep -qE 'kill -|SIGCONT|resume' <<< "${race_stopped_out}"; then
    fail "the stopped report gives no command"
  fi
  grep -q 'REORG STOPPED' "${race_home}/reorg.log" \
    || fail "a stopped rollback is logged as stopped rather than interrupted"
  printf 'ok - a stopped owner gets its own answer, not dead and not running\n'

# 6. `stage_at` records when the last stage was entered. Until now nothing read
#    it, and a field with no reader has no verification: `pid` was written and
#    unread for a release, and it carried two defects that only surfaced when
#    something finally read it.
#
#    What the report may claim is bounded. Nothing records when the process
#    died, and the report can arrive many commands later, so the interval to now
#    would be mostly idle time. What is knowable is when the stage was entered
#    and how long the phases before it took — which separates "the restores were
#    still going" from "the reinstall had been running a while".
stage_at_dead_probe() { ( cd "${tmp_root}" && exec bash -c 'exec -a "$0" sleep 60' "${E2E_CHILD_MARKER}" ) >/dev/null 2>&1 & echo $!; }
stage_at_pid=$(stage_at_dead_probe)
owned_children+=("${stage_at_pid}")
kill -9 "${stage_at_pid}" 2>/dev/null
stage_at_reap=0
while kill -0 "${stage_at_pid}" 2>/dev/null && (( stage_at_reap < 100 )); do
  sleep 0.05; stage_at_reap=$((stage_at_reap + 1))
done

mkdir -p "${race_home}/rollback-journal"
jq -nc --arg pid "${stage_at_pid}" \
  '{journal_id:"test-race", project_dir:"'"${race_project}"'",
    rollback_snapshot:"snap-baseline", reasons:"npm closure contains 1 unapproved package(s): fixture-evil@9.9.9",
    stage:"removing-node-modules",
    opened_at:"2026-08-05T00:00:00Z", stage_at:"2026-08-05T00:00:07Z", pid:$pid}' \
  > "${race_home}/rollback-journal/test-race.json"
stage_at_out=$(race_report)
grep -q 'entered 2026-08-05T00:00:07Z' <<< "${stage_at_out}" \
  || fail "the report says when the interrupted rollback entered its last stage"
grep -q '7s into the rollback' <<< "${stage_at_out}" \
  || fail "the report says how far into the rollback that stage was entered"

# An entry that never reached a stage change has no stage_at, and the report
# must not invent one or print an empty interval.
race_write_entry "${stage_at_pid}" "2026-08-05T00:00:00Z"
stage_at_absent=$(race_report)
grep -q 'did not finish' <<< "${stage_at_absent}" \
  || fail "an entry with no stage_at is still reported"
grep -q 'entered ' <<< "${stage_at_absent}" \
  && fail "an entry with no stage_at does not claim a stage-entry time"
printf 'ok - the report reads stage_at, and says nothing when it is absent\n'
else
  fail "could not stop a process to test with (ps stat was not T)"
fi
kill -CONT "${race_stopped_pid}" 2>/dev/null
kill -9 "${race_stopped_pid}" 2>/dev/null
race_sreap=0
while kill -0 "${race_stopped_pid}" 2>/dev/null && (( race_sreap < 100 )); do
  sleep 0.05; race_sreap=$((race_sreap + 1))
done
else
  fail "could not produce a zombie to test with (ps stat was not Z)"
fi
kill "${race_zombie_parent}" 2>/dev/null
race_zreap=0
while kill -0 "${race_zombie_parent}" 2>/dev/null && (( race_zreap < 100 )); do
  sleep 0.05; race_zreap=$((race_zreap + 1))
done

# --- the unfinished-rollback report: the rest of its line forms ---------------
#
# What the owner is comes from the test that answered, and a monitored file is
# a line only when it is not what the snapshot holds.
forms_home="${tmp_root}/journal-forms-home"
forms_project="${tmp_root}/journal-forms-project"
mkdir -p "${forms_home}/snapshots" "${forms_home}/rollback-journal" "${forms_project}/node_modules"
forms_entry() {
  jq -nc --arg pid "$1" --arg opened_at "$2" \
    '{journal_id:"test-forms", project_dir:"'"${forms_project}"'",
      rollback_snapshot:"snap-forms", reasons:"npm closure contains 1 unapproved package(s): fixture-evil@9.9.9",
      stage:"restoring-files", opened_at:$opened_at, pid:$pid}' \
    > "${forms_home}/rollback-journal/test-forms.json"
}
forms_report() {
  SAFEDEPS_HOME="${forms_home}" post_hook <<EOF
{"tool_name":"Bash","tool_input":{"command":"echo unrelated"},"cwd":"${forms_project}"}
EOF
}
# The snapshot holds package.json, package-lock.json and pnpm-lock.yaml, and
# recorded yarn.lock as absent. The project has another package.json, no
# package-lock.json, the same pnpm-lock.yaml and a yarn.lock.
printf '%s\n' package.json package-lock.json pnpm-lock.yaml yarn.lock > "${forms_home}/snapshots/snap-forms_monitored_files.list"
printf '{"name":"before"}\n' > "${forms_home}/snapshots/snap-forms_package.json"
printf '{"lockfileVersion":3}\n' > "${forms_home}/snapshots/snap-forms_package-lock.json"
printf 'lockfileVersion: 9\n' > "${forms_home}/snapshots/snap-forms_pnpm-lock.yaml"
: > "${forms_home}/snapshots/snap-forms_yarn.lock.missing"
: > "${forms_home}/snapshots/snap-forms_bins.list"
: > "${forms_home}/snapshots/snap-forms_packages.list"
printf '{"record":2,"snapshot_id":"snap-forms"}\n' > "${forms_home}/snapshots/snap-forms_meta.json"
printf '{"name":"after"}\n' > "${forms_project}/package.json"
printf 'lockfileVersion: 9\n' > "${forms_project}/pnpm-lock.yaml"
: > "${forms_project}/yarn.lock"

forms_entry "" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
forms_out=$(post_message "$(forms_report)")
grep -q '^Owner: the journal records no pid$' <<< "${forms_out}" || fail "an entry with no pid is reported as that"
grep -q "^${forms_project}/package.json differs from the snapshot snap-forms$" <<< "${forms_out}" || fail "a monitored file that differs from the snapshot is a line"
grep -q "^${forms_project}/package-lock.json does not exist; the snapshot snap-forms has it$" <<< "${forms_out}" || fail "a monitored file that is gone is a line"
grep -q "^${forms_project}/yarn.lock exists; the snapshot snap-forms recorded it as absent$" <<< "${forms_out}" || fail "a file the snapshot recorded as absent is a line"
grep -q "^${forms_project}/node_modules exists$" <<< "${forms_out}" || fail "the report says what node_modules is"
if grep -q 'pnpm-lock.yaml' <<< "${forms_out}"; then
  fail "a monitored file that matches the snapshot is not a line"
fi
if grep -qE 'bins\.list|packages\.list|meta\.json|monitored_files' <<< "${forms_out}"; then
  fail "the snapshot's own files are not reported as project files"
fi
printf 'ok - the unfinished-rollback report lists only the monitored files that are not what the snapshot holds\n'
grep -q '^Rollback snapshot: snap-forms; no confirmed snapshot names it$' <<< "${forms_out}" \
  || fail "the report says no confirmed snapshot names the rollback snapshot"
# The same entry where the project's confirmed record names the snapshot.
printf 'snap-forms\n' > "${forms_home}/confirmed_$(oracle_dir_hash "${forms_project}")"
forms_entry "" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
grep -q '^Rollback snapshot: snap-forms, a confirmed snapshot$' <<< "$(post_message "$(forms_report)")" \
  || fail "the report says the rollback snapshot is a confirmed one where the project's record names it"
rm -f "${forms_home}/confirmed_$(oracle_dir_hash "${forms_project}")"
printf 'ok - the unfinished-rollback report says whether a confirmed record names the rollback snapshot\n'

# An owner that is alive, where a later test cannot place it: the journal's
# opening time does not parse, ps gives no start time, ps gives one that does
# not parse. Each is reported as the test that answered.
( cd "${tmp_root}" && exec bash -c 'exec -a "$0" sleep 120' "${E2E_CHILD_MARKER}" ) >/dev/null 2>&1 &
forms_owner_pid=$!
owned_children+=("${forms_owner_pid}")
sleep 0.3
forms_entry "${forms_owner_pid}" "not-a-date"
grep -q '^Owner: the opening time of the journal cannot be parsed$' <<< "$(post_message "$(forms_report)")" \
  || fail "an entry whose opening time does not parse is reported as that"
# ps lstart garbage-date parsing has no native equivalent. Integer API
# zero/short/wrong-owner responses replace that parser coverage; the malformed
# journal opening-time assertion above remains independent and unchanged.
for forms_query_case in owner-empty owner-short owner-wrong-pid; do
  forms_entry "${forms_owner_pid}" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  grep -q "^Owner: native process query supplied no usable owner data for pid ${forms_owner_pid}\$" <<< "$(post_message "$(SAFEDEPS_TEST_FAULT="${forms_query_case}" forms_report)")" \
    || fail "a native owner query failure is reported as the test that answered (${forms_query_case})"
done
kill -9 "${forms_owner_pid}" 2>/dev/null
forms_reap=0
while kill -0 "${forms_owner_pid}" 2>/dev/null && (( forms_reap < 100 )); do
  sleep 0.05; forms_reap=$((forms_reap + 1))
done
printf 'ok - an owner that cannot be placed is reported as the test that could not place it\n'

# An incident record that could not be written is said as that: the report
# names the file only after looking for it.
: > "${tmp_root}/not-a-directory"
forms_entry "${forms_owner_pid}" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
forms_noincident=$(post_message "$(SAFEDEPS_INCIDENT_DIR="${tmp_root}/not-a-directory/incidents" forms_report)")
grep -q "^Incident record: ${tmp_root}/not-a-directory/incidents/test-forms.json is not a file$" <<< "${forms_noincident}" \
  || fail "an incident record that was not written is reported as not a file (${forms_noincident})"
printf 'ok - the report names a record file only after looking for it\n'

# --- ledger batch: could-not-run is not "nothing is unapproved" --------------
#
# The batch form writes its misses to stdout and the caller turns them into the
# unapproved list. So an empty result means "everything is approved", and any
# early return that produces no output means the same thing to the caller. The
# per-package form this replaced failed closed in those conditions — every
# package counted as a miss. Statuses: 0 no misses, 1 misses, 2 could not run.

batch_home="${tmp_root}/ledger-batch-home"
mkdir -p "${batch_home}"
batch_closure="${tmp_root}/ledger-batch-closure.json"
printf '[{"package":"fixture-unapproved","version":"9.9.9"}]\n' > "${batch_closure}"

batch_status() {
  ( export SAFEDEPS_HOME="${batch_home}"
    export SAFEDEPS_LEDGER_DIR="${batch_home}/approved-specs"
    . "${ROOT_DIR}/lib/ledger/ledger.sh"
    # Sourcing the library turns on `set -e`, and the whole point here is to
    # read a non-zero status rather than be killed by it.
    set +e
    safedeps_ledger_effect_check_batch "npm" "$1" >/dev/null 2>&1
    echo $? )
}

# A closure nothing approves is a verdict, not an error.
[[ "$(batch_status "${batch_closure}")" == "1" ]] \
  || fail "an unapproved closure reports misses (status 1)"

# A closure file that is not there cannot be judged, and must not read as clean.
[[ "$(batch_status "${tmp_root}/does-not-exist.json")" == "2" ]] \
  || fail "a missing closure file is could-not-run (status 2), not zero misses"

# Unparseable closure JSON: jq fails, produces no rows, and the rows are the
# whole answer.
printf 'not json at all\n' > "${tmp_root}/ledger-batch-broken.json"
[[ "$(batch_status "${tmp_root}/ledger-batch-broken.json")" == "2" ]] \
  || fail "an unparseable closure is could-not-run (status 2), not zero misses"
printf 'ok - the ledger batch separates could-not-run from no-misses (fail-closed)\n'

# --- ledger effect index: same verdicts, one read ----------------------------
#
# The index replaced a per-package walk of the whole ledger directory. It must
# answer exactly what that walk answered, including the cases that are supposed
# to be misses, and one unreadable entry must not empty it (an empty index reads
# as "nothing is approved", which is a rollback of a clean install).

idx_home="${tmp_root}/ledger-index-home"
idx_ledger="${idx_home}/approved-specs"
mkdir -p "${idx_ledger}"

idx_entry() {
  local name="$1" package="$2" version="$3" expires="$4" revoked="$5" transitive="$6"
  jq -nc \
    --arg package "${package}" --arg version "${version}" \
    --arg expires "${expires}" --arg revoked "${revoked}" \
    --argjson transitive "${transitive}" \
    '{hash:"sha256:0000000000000000000000000000000000000000000000000000000000000000",
      ecosystem:"npm", package:$package, version:$version, version_range:$version,
      approved_at:"2020-01-01T00:00:00Z", expires_at:$expires,
      approved_by:"e2e", evidence:{}, transitive_specs:$transitive}
     + (if $revoked == "" then {} else {revoked_at:$revoked} end)' \
    > "${idx_ledger}/${name}.json"
}

idx_entry 'live'    'idx-live'    '1.0.0' '2099-01-01T00:00:00Z' '' \
  '[{"ecosystem":"npm","package":"idx-child","version":"2.0.0"}]'
idx_entry 'expired' 'idx-expired' '1.0.0' '2020-01-01T00:00:00Z' '' '[]'
idx_entry 'revoked' 'idx-revoked' '1.0.0' '2099-01-01T00:00:00Z' '2021-01-01T00:00:00Z' '[]'
printf '{ this is not json\n' > "${idx_ledger}/corrupt.json"

idx_check() {
  ( export SAFEDEPS_HOME="${idx_home}" SAFEDEPS_LEDGER_DIR="${idx_ledger}"
    # Assigned as statements, not as a `VAR=x . file` prefix: a prefix
    # assignment on `.` lasts only for the source itself, so the library
    # functions would run afterwards with the variable already gone.
    . "${ROOT_DIR}/lib/ledger/ledger.sh"
    if safedeps_ledger_effect_check npm "$1" "$2" >/dev/null 2>&1; then
      printf 'approved\n'
    else
      printf 'miss\n'
    fi )
}

[[ "$(idx_check idx-live 1.0.0)" == "approved" ]]     || fail "ledger index approves a live owner spec"
[[ "$(idx_check idx-child 2.0.0)" == "approved" ]]    || fail "ledger index approves a live transitive spec"
[[ "$(idx_check idx-live 9.9.9)" == "miss" ]]         || fail "ledger index does not approve an unlisted version"
[[ "$(idx_check idx-expired 1.0.0)" == "miss" ]]      || fail "ledger index does not approve an expired spec"
[[ "$(idx_check idx-revoked 1.0.0)" == "miss" ]]      || fail "ledger index does not approve a revoked spec"
[[ "$(idx_check idx-absent 1.0.0)" == "miss" ]]       || fail "ledger index does not approve an absent spec"
printf 'ok - ledger effect index verdicts (owner, transitive, expired, revoked, absent)\n'

# The corrupt entry sitting alongside the others above is the point: assert the
# index still carries every spec it should, rather than inferring it from one
# lookup. jq stops at the first file it cannot parse, so a single bad entry
# emptying the index would read as "nothing is approved" — a rollback of a clean
# install, from a typo in a ledger file.
idx_lines=$(
  ( export SAFEDEPS_HOME="${idx_home}" SAFEDEPS_LEDGER_DIR="${idx_ledger}"
    . "${ROOT_DIR}/lib/ledger/ledger.sh"
    safedeps_ledger_effect_index '' 2>/dev/null | wc -l | tr -d ' ' )
)
[[ "${idx_lines}" == "2" ]] \
  || fail "one unreadable ledger entry emptied the index (expected 2 live specs, got ${idx_lines})"
printf 'ok - one unreadable ledger entry does not empty the index\n'

printf '%s\n' '{"vulnerable":[]}' > "${state_file}"

# Every form the report grammar has was read at least once above, or the
# oracle's green says nothing about that form.
oracle_table || exit 1
printf 'ok - every line the post hook printed is a known form whose claim held on disk, and every form appeared\n'

printf 'e2e passed\n'
