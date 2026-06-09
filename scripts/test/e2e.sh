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

# --- Dependency audit gate (npm) — v2.5.0 -----------------------------------
# A fake `npm` makes the crucial distinction deterministic and offline: a
# vulnerable verdict (block) must never be confused with an unreachable advisory
# DB (warn + allow). If those two collapsed, an offline failover would silently
# let real vulnerabilities through.
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
chmod +x "${fakebin}/npm"

if command -v jq >/dev/null 2>&1; then
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
  pass "pre-commit dep gate: blocks on vuln, warns+allows when offline"
else
  printf 'ok - pre-commit dep gate SKIPPED (needs gitleaks + jq)\n'
fi

printf 'e2e passed\n'
