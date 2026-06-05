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

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-smoke.XXXXXX")
cleanup() {
  rm -rf "${tmp_root}"
}
trap cleanup EXIT

bash -n bin/safedeps
bash -n lib/providers/providers.sh
bash -n lib/ledger/ledger.sh
bash -n lib/npm/closure.sh
bash -n scripts/safedeps-pre-guard.sh
bash -n scripts/safedeps-post-verify.sh
bash -n scripts/safedeps-recheck-alert.sh
bash -n scripts/release-gates.sh
bash -n lib/gates/repo-profile.sh
bash -n lib/gates/scan.sh
bash -n lib/gates/audit.sh
bash -n lib/gates/hooks.sh
pass "bash syntax"

node --check scripts/install/install-safedeps-hooks.mjs >/dev/null
node --check scripts/install/install-safedeps-recheck-agent.mjs >/dev/null
node --check scripts/install/migrate-safedeps-state.mjs >/dev/null
node --check scripts/test/fixture-provider.mjs >/dev/null
node scripts/install/install-safedeps-recheck-agent.mjs --help >/dev/null
pass "node syntax"

version_json=$(HOME="${tmp_root}/home-version" SAFEDEPS_HOME="${tmp_root}/safe-version" ./bin/safedeps --json version)
pkg_version=$(jq -r '.version' package.json)
[[ "$(jq -r '.version' <<< "${version_json}")" == "${pkg_version}" ]] || fail "cli version matches package.json (${pkg_version})"
pass "cli version"

ledger_json=$(HOME="${tmp_root}/home-ledger" SAFEDEPS_HOME="${tmp_root}/safe-ledger" ./bin/safedeps --json ledger)
[[ "$(jq -r '.count' <<< "${ledger_json}")" == "0" ]] || fail "isolated ledger starts empty"
pass "isolated ledger"

provider_tmp="${tmp_root}/missing/provider/tmp"
provider_created=$(
  TMPDIR="${provider_tmp}" \
  SAFEDEPS_HOME="${tmp_root}/safe-provider" \
  bash -c 'source lib/providers/providers.sh; d=$(safedeps_provider_mktemp_dir); test -d "$d"; printf "%s" "$d"'
)
[[ "${provider_created}" == "${provider_tmp%/}/safedeps-providers."* ]] || fail "provider tmp helper uses requested TMPDIR"
pass "provider temp dir"

project_dir="${tmp_root}/project"
mkdir -p "${project_dir}"
printf '{"dependencies":{}}\n' > "${project_dir}/package.json"

run_hook_command() {
  local home_dir="$1"
  local safe_dir="$2"
  local command="$3"

  jq -nc --arg command "${command}" --arg cwd "${project_dir}" \
    '{tool_name:"Bash",tool_input:{command:$command},cwd:$cwd}' |
    HOME="${home_dir}" SAFEDEPS_HOME="${safe_dir}" scripts/safedeps-pre-guard.sh
}

deny_json=$(
  run_hook_command "${tmp_root}/home-hook" "${tmp_root}/safe-hook" "npm install left-pad@1.3.0"
)
[[ "$(jq -r '.hookSpecificOutput.permissionDecision' <<< "${deny_json}")" == "deny" ]] || fail "hook denies unapproved install"
pass "hook denies unapproved install"

mkdir -p "${tmp_root}/safe-hook-allow"
SAFEDEPS_HOME="${tmp_root}/safe-hook-allow" lib/ledger/ledger.sh approve npm left-pad 1.3.0 1.3.0 smoke >/dev/null
allow_output=$(
  run_hook_command "${tmp_root}/home-hook-allow" "${tmp_root}/safe-hook-allow" "npm install left-pad@1.3.0"
)
[[ -z "${allow_output}" ]] || fail "hook allows approved install"
pass "hook allows approved install"

# Regression: `npx <tool> <args>` runs an already-installed binary. Arguments to
# the tool (e.g. an email) must NOT be misread as a pkg@spec install and denied.
npx_runner_output=$(
  run_hook_command "${tmp_root}/home-npx-run" "${tmp_root}/safe-npx-run" "npx wrangler secret put ORIGIN_SHARED_SECRET --name pqc-auth-gateway dev1@block-s.io"
)
[[ -z "${npx_runner_output}" ]] || fail "hook allows npx tool run with @-bearing args"
pass "hook allows npx tool run with @-bearing args"

# Regression: a genuine install chained with an npx tool run must STILL be gated
# on the real package — and must not be polluted by the npx arg email.
mixed_output=$(
  run_hook_command "${tmp_root}/home-mixed" "${tmp_root}/safe-mixed" "npm install evil-pkg@9.9.9 && npx wrangler secret put X dev1@block-s.io"
)
[[ "$(jq -r '.hookSpecificOutput.permissionDecision' <<< "${mixed_output}")" == "deny" ]] || fail "hook gates real install chained with npx run"
reason=$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<< "${mixed_output}")
grep -q 'evil-pkg@9.9.9' <<< "${reason}" || fail "deny reason names the real package"
[[ "${reason}" != *"dev1@block-s.io"* ]] || fail "deny reason must not name the email arg"
pass "hook gates real install chained with npx run (email not polluted)"

echo_output=$(
  run_hook_command "${tmp_root}/home-echo" "${tmp_root}/safe-echo" "echo \"npm install evil-pkg@9.9.9\""
)
[[ -z "${echo_output}" ]] || fail "hook ignores quoted echo text"
heredoc_output=$(
  run_hook_command "${tmp_root}/home-heredoc" "${tmp_root}/safe-heredoc" $'cat <<'\''EOF'\''\nnpm install evil-pkg@9.9.9\nEOF'
)
[[ -z "${heredoc_output}" ]] || fail "hook ignores heredoc body text"
pass "hook ignores echo/heredoc text"

bypass_cases=(
  "/usr/bin/npm install evil@1.2.3"
  "bash -lc \"npm install evil@1.2.3\""
  "env npm install evil@1.2.3"
  "command npm install evil@1.2.3"
  "npm --prefix sub install evil@1.2.3"
  "pip install requests==2.31.0"
  "gem install rails -v 7.1.0"
  "cargo add serde --vers 1.0.0"
  "dotnet add package X --version 1.0.0"
)
for bypass_cmd in "${bypass_cases[@]}"; do
  bypass_output=$(run_hook_command "${tmp_root}/home-bypass" "${tmp_root}/safe-bypass" "${bypass_cmd}")
  [[ "$(jq -r '.hookSpecificOutput.permissionDecision' <<< "${bypass_output}")" == "deny" ]] || fail "hook denies bypass: ${bypass_cmd}"
done
pass "hook denies install bypass forms"

tamper_safe="${tmp_root}/safe-tamper"
tamper_home="${tmp_root}/home-tamper"
SAFEDEPS_HOME="${tamper_safe}" lib/ledger/ledger.sh approve npm ledger-tamper 1.0.0 1.0.0 smoke >/dev/null
tamper_pre=$(run_hook_command "${tamper_home}" "${tamper_safe}" "npm install ledger-tamper@1.0.0")
[[ -z "${tamper_pre}" ]] || fail "tamper fixture pre hook allows approved install"
mkdir -p "${project_dir}/node_modules/ledger-tamper"
jq '.dependencies["ledger-tamper"]="1.0.0"' "${project_dir}/package.json" > "${project_dir}/package.json.tmp"
mv "${project_dir}/package.json.tmp" "${project_dir}/package.json"
cat > "${project_dir}/node_modules/ledger-tamper/package.json" <<'EOF'
{"name":"ledger-tamper","version":"1.0.0","scripts":{"postinstall":"node -e \"require('fs').writeFileSync(process.env.HOME + '/.safedeps/approved-specs/evil.json', '{}')\""}}
EOF
tamper_post=$(
  jq -nc '{tool_name:"Bash",tool_input:{command:"npm install ledger-tamper@1.0.0"}}' |
    HOME="${tamper_home}" SAFEDEPS_HOME="${tamper_safe}" scripts/safedeps-post-verify.sh
)
grep -q '의심스러운 패키지 변경 감지' <<< "${tamper_post}" || fail "post hook reorgs safedeps ledger tamper script"
pass "post hook reorgs safedeps ledger tamper script"

fixture_json="${tmp_root}/recheck-fixture.json"
printf '%s\n' '{"command":"re-check","checked":2,"still_clean":1,"newly_vulnerable":[],"kev_hit":[],"revoked":[]}' > "${fixture_json}"
SAFEDEPS_NOTIFY=0 \
  HOME="${tmp_root}/home-recheck" \
  SAFEDEPS_HOME="${tmp_root}/safe-recheck" \
  SAFEDEPS_RECHECK_FIXTURE_JSON="${fixture_json}" \
  scripts/safedeps-recheck-alert.sh
grep -q '"checked":2' "${tmp_root}/safe-recheck/recheck.log" || fail "re-check wrapper writes log"
grep -q '"provider_skipped":1' "${tmp_root}/safe-recheck/recheck-alerts.jsonl" || fail "re-check wrapper alerts on skipped provider checks"
pass "re-check alert wrapper"

# Release-time lane (absorbed from security-release-gates): commands must be
# registered and resolve their gate scripts.
gates_help=$(HOME="${tmp_root}/home-gates" SAFEDEPS_HOME="${tmp_root}/safe-gates" ./bin/safedeps help)
for gate_cmd in "gates" "scan secrets" "audit" "hooks"; do
  grep -q "${gate_cmd}" <<< "${gates_help}" || fail "release-time command listed in help: ${gate_cmd}"
done
for gate_script in scripts/release-gates.sh lib/gates/repo-profile.sh lib/gates/scan.sh lib/gates/audit.sh lib/gates/hooks.sh; do
  [[ -f "${gate_script}" ]] || fail "release-time gate script present: ${gate_script}"
done
pass "release-time gate commands registered"

printf 'smoke passed\n'
