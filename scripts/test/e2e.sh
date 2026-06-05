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
{"tool_name":"Bash","tool_input":{"command":"npm install fixture-vuln@1.0.1"},"cwd":"${project_dir}"}
EOF
)
[[ -z "${hook_allow}" ]] || fail "hook allows narrowed approved spec"
pass "hook allows approved narrowed spec"

effect_project="${tmp_root}/effect-project"
mkdir -p "${effect_project}"
printf '{"dependencies":{}}\n' > "${effect_project}/package.json"

effect_clean_pre=$(
  scripts/safedeps-pre-guard.sh <<EOF
{"tool_name":"Bash","tool_input":{"command":"npm install fixture-parent@1.0.0"},"cwd":"${effect_project}"}
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
{"tool_name":"Bash","tool_input":{"command":"npm install fixture-parent@1.0.0"}}
EOF
)
[[ -z "${effect_clean_post}" ]] || fail "post hook passes approved full closure"
pass "post hook passes approved full closure"

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
{"tool_name":"Bash","tool_input":{"command":"npm install fixture-parent@1.0.0"},"cwd":"${missing_project}"}
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
{"tool_name":"Bash","tool_input":{"command":"npm install fixture-parent@1.0.0"}}
EOF
)
grep -q '의심스러운 패키지 변경 감지' <<< "${missing_post}" || fail "post hook reorgs unapproved transitive package"
grep -q 'fixture-child@1.0.0' <<< "${missing_post}" || fail "post hook names unapproved transitive package"
pass "post hook reorgs unapproved transitive package"

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
jq -e --arg pre "~/.claude/skills/safedeps/scripts/safedeps-pre-guard.sh" '
  [.hooks.PreToolUse[]? | select(.matcher == "Bash") | .hooks[]?.command] | index($pre)
' "${installer_home}/.claude/settings.json" >/dev/null || fail "installer writes new pre hook"
jq -e --arg post "~/.claude/skills/safedeps/scripts/safedeps-post-verify.sh" '
  [.hooks.PostToolUse[]?.hooks[]?.command] | index($post)
' "${installer_home}/.claude/settings.json" >/dev/null || fail "installer writes new post hook"
jq -e --arg pre "~/.codex/skills/safedeps/scripts/safedeps-pre-guard.sh" '
  [.hooks.PreToolUse[]?.hooks[]?.command] | index($pre)
' "${installer_home}/.codex/hooks.json" >/dev/null || fail "installer writes codex pre hook"
jq -e --arg post "~/.codex/skills/safedeps/scripts/safedeps-post-verify.sh" '
  [.hooks.PostToolUse[]?.hooks[]?.command] | index($post)
' "${installer_home}/.codex/hooks.json" >/dev/null || fail "installer writes codex post hook"
if jq -e '[.. | strings] | any(contains("npm-reorg-guard"))' "${installer_home}/.claude/settings.json" >/dev/null; then
  fail "installer removes legacy hook"
fi
pass "installer legacy hook cleanup"

printf 'e2e passed\n'
