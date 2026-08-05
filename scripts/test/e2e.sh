#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "${ROOT_DIR}"

pass() {
  printf 'ok - %s\n' "$1"
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-e2e.XXXXXX")
cleanup() {
  if [[ -n "${server_pid:-}" ]]; then
    kill "${server_pid}" 2>/dev/null || true
    wait "${server_pid}" 2>/dev/null || true
  fi
  rm -rf "${tmp_root}"
}
trap cleanup EXIT

port_file="${tmp_root}/port"
state_file="${tmp_root}/state.json"
printf '%s\n' '{"vulnerable":[]}' > "${state_file}"
node scripts/test/fixture-provider.mjs "${port_file}" "${state_file}" &
server_pid=$!

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
  SAFEDEPS_HOME="${yarn_safe_home}" scripts/safedeps-pre-guard.sh <<EOF
{"tool_name":"Bash","tool_input":{"command":"yarn add next@16.2.11"},"cwd":"${yarn_safe_project}","turn_id":"turn-yarn-safe","model":"codex-test"}
EOF
)
[[ -z "${yarn_safe_hook}" ]] || fail "Yarn command gate accepts matching project-scoped approval"
yarn_unsafe_hook=$(
  SAFEDEPS_HOME="${yarn_safe_home}" scripts/safedeps-pre-guard.sh <<EOF
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
candidate_context_mismatch_hook=$(SAFEDEPS_HOME="${candidate_safe_home}" scripts/safedeps-pre-guard.sh <<EOF
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
  scripts/safedeps-pre-guard.sh <<EOF
{"tool_name":"Bash","tool_input":{"command":"npm install fixture-vuln@1.0.1"},"cwd":"${project_dir}","turn_id":"turn-e2e","model":"codex-test"}
EOF
)
[[ -z "${hook_allow}" ]] || fail "hook allows narrowed approved spec"
pass "hook allows approved narrowed spec"

effect_project="${tmp_root}/effect-project"
mkdir -p "${effect_project}"
printf '{"dependencies":{}}\n' > "${effect_project}/package.json"

effect_clean_pre=$(
  scripts/safedeps-pre-guard.sh <<EOF
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
  scripts/safedeps-post-verify.sh <<EOF
{"tool_name":"Bash","tool_input":{"command":"npm install fixture-parent@1.0.0"},"cwd":"${effect_project}"}
EOF
)
[[ -z "${effect_clean_post}" ]] || fail "post hook passes approved full closure"
pass "post hook passes approved full closure"

inert_project="${tmp_root}/inert-project"
mkdir -p "${inert_project}"
printf '{"dependencies":{}}\n' > "${inert_project}/package.json"
inert_pre=$(
  scripts/safedeps-pre-guard.sh <<EOF
{"tool_name":"Bash","tool_input":{"command":"npm install fixture-parent@1.0.0"},"cwd":"${inert_project}"}
EOF
)
[[ "$(jq -r '.hookSpecificOutput.permissionDecision' <<< "${inert_pre}")" == "allow" ]] || fail "inert pre hook emits Claude allow"
[[ "$(jq -r '.hookSpecificOutput.updatedInput.command' <<< "${inert_pre}")" == "npm install fixture-parent@1.0.0 --ignore-scripts" ]] || fail "inert pre hook injects ignore-scripts"
cat > "${inert_project}/package-lock.json" <<'EOF'
{
  "name": "inert-project",
  "lockfileVersion": 3,
  "packages": {
    "": {"dependencies": {"fixture-parent": "1.0.0"}},
    "node_modules/fixture-parent": {"version": "1.0.0", "dependencies": {"fixture-child": "1.0.0"}},
    "node_modules/fixture-child": {"version": "1.0.0"}
  }
}
EOF
stub_bin="${tmp_root}/stub-bin"
mkdir -p "${stub_bin}"
cat > "${stub_bin}/npm" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${tmp_root}/npm-calls.log"
exit 0
EOF
chmod +x "${stub_bin}/npm"
inert_post=$(
  PATH="${stub_bin}:${PATH}" scripts/safedeps-post-verify.sh <<EOF
{"tool_name":"Bash","tool_input":{"command":"npm install fixture-parent@1.0.0 --ignore-scripts"},"cwd":"${inert_project}"}
EOF
)
[[ -z "${inert_post}" ]] || fail "post hook keeps verified inert rebuild success quiet"
grep -qx 'rebuild' "${tmp_root}/npm-calls.log" || fail "post hook runs npm rebuild after verified injected install"
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
scripts/safedeps-pre-guard.sh > /dev/null <<EOF
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
  PATH="${stub_bin}:${PATH}" scripts/safedeps-post-verify.sh <<EOF
{"tool_name":"Bash","tool_input":{"command":"npm install fixture-parent@1.0.0"},"cwd":"${revert_project}"}
EOF
)
grep -q 'suspicious dependency change detected' <<< "${revert_post}" || fail "reorg fires on a tampered lockfile"
cmp -s "${revert_project}/package-lock.json" "${tmp_root}/revert-safe-lock.json" || fail "reorg restores the exact safe lockfile content on disk"
pass "reorg reverts a tampered lockfile to safe content on disk"

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
  scripts/safedeps-pre-guard.sh <<EOF
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
  scripts/safedeps-post-verify.sh <<EOF
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

# And when the library genuinely cannot be read, that is an unavailability, said
# out loud like every other one rather than swallowed by a quiet return.
guard_nolib_repo="${tmp_root}/guard-nolib-repo"
mkdir -p "${guard_nolib_repo}/scripts" "${guard_nolib_repo}/lib"
cp -R lib/. "${guard_nolib_repo}/lib/"
cp scripts/safedeps-pre-guard.sh "${guard_nolib_repo}/scripts/"
rm -f "${guard_nolib_repo}/lib/truth-sources.sh"
guard_nolib_home="${tmp_root}/safe-guard-nolib"
guard_nolib_err="${tmp_root}/guard-nolib.err"
mkdir -p "${guard_nolib_home}"
SAFEDEPS_HOME="${guard_nolib_home}" SAFEDEPS_OSV_API_URL="http://mirror.invalid/osv" \
  "${guard_nolib_repo}/scripts/safedeps-pre-guard.sh" <<< "${guard_moved_payload}" >/dev/null 2>"${guard_nolib_err}" || true
grep -q 'truth-sources.sh is unreadable' "${guard_nolib_home}/advisory.log" \
  || fail "an unreadable truth-source library is recorded as an unavailability"
grep -q 'truth-sources.sh is unreadable' "${guard_nolib_err}" \
  || fail "an unreadable truth-source library is reported on stderr"
pass "an unreadable truth-source library is an announced unavailability, not a quiet skip"

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
  SAFEDEPS_HOME="${legacy_skip_safe}" scripts/safedeps-post-verify.sh <<EOF
{"tool_name":"Bash","tool_input":{"command":"echo done"},"cwd":"${legacy_post_project}"}
EOF
)
[[ -z "${legacy_skip_out}" ]] || fail "post hook keeps unrelated legacy-pending Bash quiet"
grep -q 'post-verify SKIP: legacy current_state' "${legacy_skip_safe}/advisory.log" || fail "post hook logs legacy pending bounded skip"
[[ -f "${legacy_skip_safe}/current_state" ]] || fail "post hook does not consume mismatched legacy pending"
pass "post hook bounds unrelated Bash with stale legacy pending"

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
HOME="${tmp_root}/doc-home" "${ROOT_DIR}/bin/safedeps" doctor --fix --root "${secret_repo}" >/dev/null
[[ -f "${secret_repo}/.gitleaks.toml" ]] || fail "doctor --fix scaffolds .gitleaks.toml"
[[ -x "${secret_repo}/.githooks/pre-commit" ]] || fail "doctor --fix scaffolds executable pre-commit"
[[ "$(git -C "${secret_repo}" config --get core.hooksPath)" == ".githooks" ]] || fail "doctor --fix activates core.hooksPath"
[[ ! -d "${secret_repo}/.github/workflows" ]] || fail "doctor --fix does not create remote CI workflows"
remote_json=$(HOME="${tmp_root}/doc-home" "${ROOT_DIR}/bin/safedeps" --json doctor --root "${secret_repo}")
[[ "$(jq -r '.ok' <<< "${remote_json}")" == "true" ]] || fail "doctor remains OK after local lane fix even when remote is opt-in"
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
        PATH="${ov_npm_bin}:${PATH}" "${ROOT_DIR}/scripts/safedeps-pre-guard.sh" 2>/dev/null ) \
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
mkdir -p "${journal_home}" "${journal_project}"

# An unfinished rollback, written the way the gate writes it before it starts
# restoring files.
( export SAFEDEPS_HOME="${journal_home}"
  . "${ROOT_DIR}/lib/gates/rollback-journal.sh"
  safedeps_journal_open 'test-interrupted' "${journal_project}" 'snap-baseline' \
    'npm closure contains 1 unapproved package(s): fixture-evil@9.9.9' \
    'reinstalling-node-modules' )

# ...and its owner has to be genuinely gone, because "interrupted" now means
# "the process that opened this is not running". `safedeps_journal_open` stamps
# `$$`, which inside `( … )` is this script's pid, not the subshell's — so the
# fixture above describes a rollback owned by a live process. That went unnoticed
# while nothing read the field. Substitute a pid that is really dead.
# The redirect is load-bearing: a background job inheriting the command
# substitution's stdout keeps that pipe open, so `$( … )` would block until the
# sleep exited rather than returning its pid.
journal_dead_owner_probe() { sleep 60 >/dev/null 2>&1 & echo $!; }
journal_dead_pid=$(journal_dead_owner_probe)
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
  SAFEDEPS_HOME="${journal_home}" scripts/safedeps-post-verify.sh <<EOF
{"tool_name":"Bash","tool_input":{"command":"echo unrelated"},"cwd":"${journal_project}"}
EOF
)
grep -q 'did not finish' <<< "${journal_report}" \
  || fail "an unfinished rollback is reported on the next Bash call"
grep -q 'reinstalling-node-modules' <<< "${journal_report}" \
  || fail "the unfinished-rollback report names the stage it was cut off at"
grep -q 'fixture-evil@9.9.9' <<< "${journal_report}" \
  || fail "the unfinished-rollback report says why the rollback was started"
grep -q 'REORG INTERRUPTED' "${journal_home}/reorg.log" \
  || fail "an interrupted rollback lands in the same log the finished ones use"
[[ -f "${journal_home}/rollback-incidents/test-interrupted.json" ]] \
  || fail "the interrupted rollback is kept as a durable incident record"
[[ -z "$(find "${journal_home}/rollback-journal" -maxdepth 1 -name '*.json' 2>/dev/null)" ]] \
  || fail "a reported journal entry is cleared from the open-journal directory"

# Reported once, not on every command from here on.
journal_repeat=$(
  SAFEDEPS_HOME="${journal_home}" scripts/safedeps-post-verify.sh <<EOF
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
bash -c 'sleep 120' >/dev/null 2>&1 &
race_owner_pid=$!

race_write_entry() {
  local pid="$1" opened_at="$2"
  mkdir -p "${race_home}/rollback-journal"
  jq -nc --arg pid "${pid}" --arg opened_at "${opened_at}" \
    '{journal_id:"test-race", project_dir:"'"${race_project}"'",
      rollback_snapshot:"snap-baseline", reasons:"npm closure contains 1 unapproved package(s): fixture-evil@9.9.9",
      stage:"reinstalling-node-modules", opened_at:$opened_at, pid:$pid}' \
    > "${race_home}/rollback-journal/test-race.json"
}

race_report() {
  SAFEDEPS_HOME="${race_home}" scripts/safedeps-post-verify.sh <<EOF
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
#    zombie defect). So it is its own answer, and the report says so, because
#    the human's first move is different — resume or kill, then repair.
bash -c 'sleep 120' >/dev/null 2>&1 &
race_stopped_pid=$!
sleep 0.3
kill -STOP "${race_stopped_pid}" 2>/dev/null
sleep 0.3
if [[ "$(ps -o stat= -p "${race_stopped_pid}" 2>/dev/null)" == *T* ]]; then
  race_write_entry "${race_stopped_pid}" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  race_stopped_out=$(race_report)
  grep -q 'is stopped, not finished' <<< "${race_stopped_out}" \
    || fail "a stopped owner is reported as stopped, not as an unfinished rollback"
  grep -q 'kill -CONT' <<< "${race_stopped_out}" \
    || fail "the stopped report names the move that resumes the rollback"
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
stage_at_dead_probe() { sleep 60 >/dev/null 2>&1 & echo $!; }
stage_at_pid=$(stage_at_dead_probe)
kill -9 "${stage_at_pid}" 2>/dev/null
stage_at_reap=0
while kill -0 "${stage_at_pid}" 2>/dev/null && (( stage_at_reap < 100 )); do
  sleep 0.05; stage_at_reap=$((stage_at_reap + 1))
done

mkdir -p "${race_home}/rollback-journal"
jq -nc --arg pid "${stage_at_pid}" \
  '{journal_id:"test-race", project_dir:"'"${race_project}"'",
    rollback_snapshot:"snap-baseline", reasons:"npm closure contains 1 unapproved package(s): fixture-evil@9.9.9",
    stage:"reinstalling-node-modules",
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

printf 'e2e passed\n'
