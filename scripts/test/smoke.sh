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
bash -n scripts/test/consumer-forms.sh
bash -n lib/gates/repo-profile.sh
bash -n lib/gates/scan.sh
bash -n lib/gates/audit.sh
bash -n lib/gates/hooks.sh
bash -n lib/gates/doctor.sh
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

# The guard clamps its self budget below the runtime hook budget, and it cannot
# read that budget at runtime — the payload does not carry it and any of several
# settings files may have registered the hook. So it names the number safedeps
# itself registers. These two constants are one fact in two files; pin them
# together, because an installer that raises the registered timeout while the
# guard still assumes 30s leaves the clamp computed against a stale number.
guard_runtime_budget=$(grep -m1 '^SAFEDEPS_RUNTIME_BUDGET_SECONDS=' scripts/safedeps-pre-guard.sh | cut -d= -f2)
guard_budget_ceiling=$(grep -m1 '^SAFEDEPS_SELF_BUDGET_MAX_SECONDS=' scripts/safedeps-pre-guard.sh | cut -d= -f2)
installer_pre_timeout=$(grep -m1 '^const PRE_HOOK_TIMEOUT_SECONDS = ' scripts/install/install-safedeps-hooks.mjs | tr -dc '0-9')
[[ -n "${guard_runtime_budget}" && -n "${guard_budget_ceiling}" && -n "${installer_pre_timeout}" ]] \
  || fail "budget constants are readable (guard=${guard_runtime_budget}/${guard_budget_ceiling}, installer=${installer_pre_timeout})"
[[ "${guard_runtime_budget}" == "${installer_pre_timeout}" ]] \
  || fail "guard's runtime budget matches the timeout the installer registers (guard=${guard_runtime_budget}s, installer=${installer_pre_timeout}s)"
(( guard_budget_ceiling < guard_runtime_budget )) \
  || fail "self-budget ceiling sits below the runtime budget (ceiling=${guard_budget_ceiling}s, runtime=${guard_runtime_budget}s)"
pass "self-budget ceiling is pinned below the hook timeout the installer registers"

# The manual-install docs and the installer describe the same registration, and
# they are different files — which is exactly how they drifted: the docs told
# readers to register the hook scripts directly for as long as the shim has
# existed, while AGENTS.md said the registered command is the shim. Following
# the docs still gated installs, but without the shim a broken checkout goes
# back to being a silently disabled gate, and the reader had no way to know.
# The comparison is machine-made now rather than left to whoever reads both.
installer_entry=$(grep -m1 '^const ENTRY_HOOK_NAME = ' scripts/install/install-safedeps-hooks.mjs | sed 's/.*"\(.*\)".*/\1/')
[[ -n "${installer_entry}" ]] || fail "installer entry-hook constant is readable"
for doc in README.md README.ko.md; do
  for target in pre post; do
    grep -q "${installer_entry} ${target}" "${doc}" \
      || fail "${doc} registers the entry shim with '${target}' (the command the installer writes)"
  done
  # The hook scripts must not be named as a registered command anywhere in the
  # manual block; naming them in prose or in a tree listing is fine.
  if grep -qE '"command":[^"]*"[^"]*safedeps-(pre-guard|post-verify)\.sh"' "${doc}"; then
    fail "${doc} does not register a hook script directly"
  fi
done
# SKILL.md must not carry a second registration declaration: no runtime reads it,
# and a second description of a registration is a second thing to keep in sync.
if grep -qE '^\s*script:\s*scripts/safedeps-' SKILL.md; then
  fail "SKILL.md leaves registration to the installer rather than declaring its own"
fi
pass "manual-install docs register the same command the installer writes"

# Regression: a global install must resolve its package dir through the symlink.
# npm -g (and ~/.local/bin via --link-bin) put a RELATIVE FILE symlink in
# <prefix>/bin and the package under <prefix>/lib/node_modules; without symlink
# resolution ${BASH_SOURCE[0]}/../lib points at <prefix>/lib (not the package) and
# every command dies at `source .../lib/providers/providers.sh`. Mirror that layout
# and invoke the CLI through the symlink — `version` only succeeds if all three
# bootstrap `source` lines resolved against the real repo dir.
global_prefix="${tmp_root}/global-prefix"
mkdir -p "${global_prefix}/bin" "${global_prefix}/lib/node_modules/@aldegad"
ln -s "${ROOT_DIR}" "${global_prefix}/lib/node_modules/@aldegad/safedeps"
ln -s "../lib/node_modules/@aldegad/safedeps/bin/safedeps" "${global_prefix}/bin/safedeps"
global_version=$(HOME="${tmp_root}/home-global" SAFEDEPS_HOME="${tmp_root}/safe-global" "${global_prefix}/bin/safedeps" --json version)
[[ "$(jq -r '.version' <<< "${global_version}")" == "${pkg_version}" ]] || fail "cli resolves its package dir through an npm-style global file symlink (got: ${global_version})"
pass "cli works through an npm-style global file symlink"

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

# Portability guard: safedeps_file_mtime must return a bare integer on both BSD
# (macOS, `stat -f`) and GNU (Linux, `stat -c`). A wrong-order stat leaks
# filesystem info into the value and breaks the cache-freshness arithmetic.
mtime_val=$(bash -c 'source lib/providers/providers.sh; f=$(mktemp); safedeps_file_mtime "$f"; rm -f "$f"')
[[ "${mtime_val}" =~ ^[0-9]+$ ]] || fail "safedeps_file_mtime returns a bare integer (got: ${mtime_val})"
pass "file mtime is a portable integer"

# Repo-override awareness: the npm closure probe must resolve transitive deps
# through the consuming repo's `overrides`, so a transitive the repo has pinned
# to a patched version is not false-flagged. Unit-test the discovery + filter.
ov_repo="${tmp_root}/ov-repo"
mkdir -p "${ov_repo}"
git -C "${ov_repo}" init -q
cat > "${ov_repo}/package.json" <<'JSON'
{"name":"ov","version":"0.0.0","overrides":{"uuid@8.3.2":"^11.1.1","react":"$react","badnest":{"dep":"$x"},"goodnest":{"dep":"1.2.3"}}}
JSON
ov_out=$(SAFEDEPS_NPM_OVERRIDES_DIR="${ov_repo}" bash -c 'source lib/npm/closure.sh; safedeps_npm_repo_overrides_json')
[[ "$(jq -r '."uuid@8.3.2"' <<< "${ov_out}")" == "^11.1.1" ]] || fail "override discovery keeps concrete transitive pin (got: ${ov_out})"
[[ "$(jq -r 'has("react")' <<< "${ov_out}")" == "false" ]] || fail "override discovery drops \$-ref string (got: ${ov_out})"
[[ "$(jq -r 'has("badnest")' <<< "${ov_out}")" == "false" ]] || fail "override discovery drops object mentioning \$ (got: ${ov_out})"
[[ "$(jq -r '.goodnest.dep' <<< "${ov_out}")" == "1.2.3" ]] || fail "override discovery keeps concrete nested pin (got: ${ov_out})"
pass "npm closure honors repo overrides (concrete pins kept, \$-refs dropped)"

ov_none="${tmp_root}/ov-none"
mkdir -p "${ov_none}"
git -C "${ov_none}" init -q
printf '{"name":"none","version":"0.0.0"}\n' > "${ov_none}/package.json"
ov_none_out=$(SAFEDEPS_NPM_OVERRIDES_DIR="${ov_none}" bash -c 'source lib/npm/closure.sh; safedeps_npm_repo_overrides_json')
[[ "${ov_none_out}" == "{}" ]] || fail "no repo overrides yields empty object (got: ${ov_none_out})"
pass "npm closure with no repo overrides is unchanged"

# A git worktree root carries a `.git` FILE, not a directory. Testing only for a
# directory walks straight past the worktree root and picks up an ancestor's
# overrides -- which are not the overrides the real install inside that worktree
# will use. The Yarn project-context walk-up already handles this with `-e`.
ov_wt_parent="${tmp_root}/ov-wt-parent"
mkdir -p "${ov_wt_parent}/inner"
printf '{"name":"ancestor","version":"0.0.0","overrides":{"leaked":"9.9.9"}}\n' > "${ov_wt_parent}/package.json"
printf 'gitdir: /somewhere/.git/worktrees/inner\n' > "${ov_wt_parent}/inner/.git"
printf '{"name":"inner","version":"0.0.0"}\n' > "${ov_wt_parent}/inner/package.json"
ov_wt_out=$(SAFEDEPS_NPM_OVERRIDES_DIR="${ov_wt_parent}/inner" bash -c 'source lib/npm/closure.sh; safedeps_npm_repo_overrides_json')
[[ "$(jq -r 'has("leaked")' <<< "${ov_wt_out}")" == "false" ]] || fail "override discovery stops at a worktree root (.git file), got: ${ov_wt_out}"
pass "npm closure override discovery stops at a worktree root, not just a .git dir"

ov_env_out=$(SAFEDEPS_NPM_OVERRIDES_JSON='{"x":"1.0.0"}' bash -c 'source lib/npm/closure.sh; safedeps_npm_repo_overrides_json')
[[ "$(jq -r '.x' <<< "${ov_env_out}")" == "1.0.0" ]] || fail "SAFEDEPS_NPM_OVERRIDES_JSON env takes precedence (got: ${ov_env_out})"
pass "npm closure override env source precedence"

# Honoring `overrides` makes the probe closure project-specific, so the approval
# must be keyed to the override set that produced it. Without this, an approval
# earned in a repo that patched a transitive satisfies the check in a repo that
# did not -- whose real install resolves the vulnerable version.
ov_repo_a="${tmp_root}/ov-scope-a"
ov_repo_b="${tmp_root}/ov-scope-b"
mkdir -p "${ov_repo_a}" "${ov_repo_b}"
printf '{"name":"a","version":"0.0.0"}\n' > "${ov_repo_a}/package.json"
printf '{"name":"b","version":"0.0.0"}\n' > "${ov_repo_b}/package.json"
ov_ctx_a=$(mktemp "${tmp_root}/ov-ctx-a.XXXXXX")
ov_ctx_b=$(mktemp "${tmp_root}/ov-ctx-b.XXXXXX")
ov_ctx_c=$(mktemp "${tmp_root}/ov-ctx-c.XXXXXX")
bash -c 'source lib/npm/closure.sh; safedeps_npm_overrides_context "$1" "{\"minimist\":\"1.2.8\"}" "$2"' _ "${ov_ctx_a}" "${ov_repo_a}/package.json" \
  || fail "overrides context is produced when overrides apply"
bash -c 'source lib/npm/closure.sh; safedeps_npm_overrides_context "$1" "{\"minimist\":\"0.2.0\"}" "$2"' _ "${ov_ctx_b}" "${ov_repo_a}/package.json" \
  || fail "overrides context is produced for a different override set"
[[ "$(jq -r '.type // "unset"' "${ov_ctx_a}")" == "unset" ]] || fail "context type is stamped by write_source, not the context builder"
[[ "$(jq -r '.overrides_sha256' "${ov_ctx_a}")" == sha256:* ]] || fail "overrides context records an override-set hash"
[[ "$(jq -r '.context_hash' "${ov_ctx_a}")" != "$(jq -r '.context_hash' "${ov_ctx_b}")" ]] \
  || fail "a different override set must produce a different approval key"
bash -c 'source lib/npm/closure.sh; safedeps_npm_overrides_context "$1" "{}" "$2"' _ "${ov_ctx_c}" "${ov_repo_a}/package.json" \
  && fail "no overrides must yield no context (the global approval stays correct)"
pass "npm overrides approvals are keyed to their override set"

# Key equality must mean "the probe resolves the same way", so a reordered but
# equivalent override object has to land on the same key rather than forcing a
# needless re-resolve.
ov_ctx_ord=$(mktemp "${tmp_root}/ov-ctx-ord.XXXXXX")
bash -c 'source lib/npm/closure.sh; safedeps_npm_overrides_context "$1" "{\"b\":\"2\",\"a\":\"1\"}" "$2"' _ "${ov_ctx_a}" "${ov_repo_a}/package.json" \
  || fail "overrides context builds for a multi-key set"
bash -c 'source lib/npm/closure.sh; safedeps_npm_overrides_context "$1" "{\"a\":\"1\",\"b\":\"2\"}" "$2"' _ "${ov_ctx_ord}" "${ov_repo_a}/package.json" \
  || fail "overrides context builds for the reordered set"
[[ "$(jq -r '.context_hash' "${ov_ctx_a}")" == "$(jq -r '.context_hash' "${ov_ctx_ord}")" ]] \
  || fail "equivalent override sets must share one approval key regardless of key order"
pass "npm overrides approval key is order-independent"

# The ledger must require the new context to carry its provenance, exactly like
# the Yarn contexts do -- a partial context is a rejected entry, not a default.
ov_entry=$(mktemp "${tmp_root}/ov-entry.XXXXXX")
ov_ledger_entry() {
  jq -cn --argjson pc "$1" '{ecosystem:"npm",package:"p",version:"1.0.0",version_range:"1.0.0",
    hash:"sha256:x",approved_at:"t",expires_at:"t",approved_by:"b",evidence:{},transitive_specs:[],project_context:$pc}'
}
ov_ledger_entry '{"type":"npm-overrides-probe","context_hash":"sha256:a","project_root":"/r","overrides_source":"/r/package.json","overrides_sha256":"sha256:b","overrides":{"x":"1"}}' > "${ov_entry}"
bash -c 'source lib/ledger/ledger.sh; safedeps_ledger_validate_json "$1"' _ "${ov_entry}" >/dev/null 2>&1 \
  || fail "ledger accepts a complete npm-overrides-probe context"
ov_ledger_entry '{"type":"npm-overrides-probe","context_hash":"sha256:a","project_root":"/r","overrides_source":"/r/package.json","overrides":{"x":"1"}}' > "${ov_entry}"
bash -c 'source lib/ledger/ledger.sh; safedeps_ledger_validate_json "$1"' _ "${ov_entry}" >/dev/null 2>&1 \
  && fail "ledger rejects an npm-overrides-probe context with no override-set hash"
ov_ledger_entry '{"type":"npm-overrides-probe","context_hash":"sha256:a","project_root":"/r","overrides_source":"/r/package.json","overrides_sha256":"sha256:b","overrides":{}}' > "${ov_entry}"
bash -c 'source lib/ledger/ledger.sh; safedeps_ledger_validate_json "$1"' _ "${ov_entry}" >/dev/null 2>&1 \
  && fail "ledger rejects an npm-overrides-probe context with an empty override set"
pass "ledger requires npm overrides provenance like it does for Yarn"

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

run_codex_hook_command() {
  local home_dir="$1"
  local safe_dir="$2"
  local command="$3"

  jq -nc --arg command "${command}" --arg cwd "${project_dir}" \
    '{tool_name:"Bash",tool_input:{command:$command},cwd:$cwd,turn_id:"turn-smoke",model:"codex-test"}' |
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
[[ "$(jq -r '.hookSpecificOutput.permissionDecision' <<< "${allow_output}")" == "allow" ]] || fail "hook emits Claude allow decision for approved install"
[[ "$(jq -r '.hookSpecificOutput.updatedInput.command' <<< "${allow_output}")" == "npm install left-pad@1.3.0 --ignore-scripts" ]] || fail "hook injects --ignore-scripts for Claude npm install"
allow_sid=$(jq -r '.snapshot_id' "${tmp_root}/safe-hook-allow/pending/"*.json)
jq -e '.ignore_scripts_injected == true' "${tmp_root}/safe-hook-allow/snapshots/${allow_sid}_meta.json" >/dev/null || fail "hook records injected meta flag"
pass "hook injects --ignore-scripts for Claude approved install"

mkdir -p "${tmp_root}/safe-hook-codex"
SAFEDEPS_HOME="${tmp_root}/safe-hook-codex" lib/ledger/ledger.sh approve npm left-pad 1.3.0 1.3.0 smoke >/dev/null
codex_allow_output=$(
  run_codex_hook_command "${tmp_root}/home-hook-codex" "${tmp_root}/safe-hook-codex" "npm install left-pad@1.3.0"
)
[[ -z "${codex_allow_output}" ]] || fail "hook keeps Codex approved install as plain allow"
codex_sid=$(jq -r '.snapshot_id' "${tmp_root}/safe-hook-codex/pending/"*.json)
jq -e '.ignore_scripts_injected == false' "${tmp_root}/safe-hook-codex/snapshots/${codex_sid}_meta.json" >/dev/null || fail "hook does not record injected meta flag for Codex"
pass "hook keeps Codex approved install as plain allow"

for inert_skip_cmd in "npm view left-pad" "npm run build" "npm --version"; do
  inert_skip_output=$(run_hook_command "${tmp_root}/home-inert-skip" "${tmp_root}/safe-inert-skip" "${inert_skip_cmd}")
  [[ -z "${inert_skip_output}" ]] || fail "hook does not inject non-install command: ${inert_skip_cmd}"
done
pass "hook does not inject npm non-install commands"

mkdir -p "${tmp_root}/safe-hook-ignore-scripts"
SAFEDEPS_HOME="${tmp_root}/safe-hook-ignore-scripts" lib/ledger/ledger.sh approve npm left-pad 1.3.0 1.3.0 smoke >/dev/null
ignore_scripts_output=$(
  run_hook_command "${tmp_root}/home-hook-ignore-scripts" "${tmp_root}/safe-hook-ignore-scripts" "npm install left-pad@1.3.0 --ignore-scripts"
)
[[ -z "${ignore_scripts_output}" ]] || fail "hook does not duplicate --ignore-scripts"
ignore_sid=$(jq -r '.snapshot_id' "${tmp_root}/safe-hook-ignore-scripts/pending/"*.json)
jq -e '.ignore_scripts_injected == false' "${tmp_root}/safe-hook-ignore-scripts/snapshots/${ignore_sid}_meta.json" >/dev/null || fail "hook does not record injected meta flag when flag already exists"
pass "hook does not duplicate --ignore-scripts"

# Finding #7: on a COMPOUND command the inert-install flag must land ON the npm
# install, not appended to the end (which would put it on the trailing statement,
# leaving the install running lifecycle scripts).
mkdir -p "${tmp_root}/safe-compound"
SAFEDEPS_HOME="${tmp_root}/safe-compound" lib/ledger/ledger.sh approve npm left-pad 1.3.0 1.3.0 smoke >/dev/null
compound_out=$(run_hook_command "${tmp_root}/home-compound" "${tmp_root}/safe-compound" "npm install left-pad@1.3.0 && npm run build")
compound_cmd=$(jq -r '.hookSpecificOutput.updatedInput.command' <<< "${compound_out}")
[[ "${compound_cmd}" == "npm install --ignore-scripts left-pad@1.3.0 && npm run build" ]] || fail "compound inert-install injects --ignore-scripts on the install, not the trailing command (got: ${compound_cmd})"
pass "compound install injects --ignore-scripts in-place on the npm install (finding #7)"

# Finding #3: an `--prefix <dir>` install must be snapshotted/effect-gated against
# the OVERRIDE dir, not cwd. The pending state's project_dir must be the prefix dir.
prefix_safe="${tmp_root}/safe-prefix"
prefix_proj=$(cd "$(mktemp -d "${tmp_root}/prefix-target.XXXXXX")" && pwd -P)
mkdir -p "${prefix_safe}"
printf '{"dependencies":{}}\n' > "${prefix_proj}/package.json"
SAFEDEPS_HOME="${prefix_safe}" lib/ledger/ledger.sh approve npm left-pad 1.3.0 1.3.0 smoke >/dev/null
jq -nc --arg c "npm install --prefix ${prefix_proj} left-pad@1.3.0" --arg cwd "${project_dir}" \
  '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}' |
  HOME="${tmp_root}/home-prefix" SAFEDEPS_HOME="${prefix_safe}" scripts/safedeps-pre-guard.sh >/dev/null
prefix_pending_dir=$(jq -r '.project_dir' "${prefix_safe}/pending/"*.json | head -1)
[[ "${prefix_pending_dir}" == "${prefix_proj}" ]] || fail "--prefix install snapshots the override dir, not cwd (got: ${prefix_pending_dir}, want ${prefix_proj})"
pass "--prefix install targets the override dir for snapshot/effect-gate (finding #3)"

# Regression: `npx <tool> <args>` runs an already-installed binary. Arguments to
# the tool (e.g. an email) must NOT be misread as a pkg@spec install and denied.
npx_runner_output=$(
  run_hook_command "${tmp_root}/home-npx-run" "${tmp_root}/safe-npx-run" "npx wrangler secret put EXAMPLE_SHARED_SECRET --name example-gateway ops@example.test"
)
[[ -z "${npx_runner_output}" ]] || fail "hook allows npx tool run with @-bearing args"
pass "hook allows npx tool run with @-bearing args"

# Regression: a genuine install chained with an npx tool run must STILL be gated
# on the real package — and must not be polluted by the npx arg email.
mixed_output=$(
  run_hook_command "${tmp_root}/home-mixed" "${tmp_root}/safe-mixed" "npm install evil-pkg@9.9.9 && npx wrangler secret put X ops@example.test"
)
[[ "$(jq -r '.hookSpecificOutput.permissionDecision' <<< "${mixed_output}")" == "deny" ]] || fail "hook gates real install chained with npx run"
reason=$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<< "${mixed_output}")
grep -q 'evil-pkg@9.9.9' <<< "${reason}" || fail "deny reason names the real package"
[[ "${reason}" != *"ops@example.test"* ]] || fail "deny reason must not name the email arg"
pass "hook gates real install chained with npx run (email not polluted)"

# Regression: a pkg@version that merely APPEARS in a non-install segment (an echo /
# log line) must not be attached to a real install elsewhere in the command. Specs
# are extracted only from segments that are themselves install commands.
echo_mention_output=$(
  run_hook_command "${tmp_root}/home-echo-mention" "${tmp_root}/safe-echo-mention" 'npm install evil-pkg@9.9.9; echo "bumped other-pkg@2.0.0"'
)
[[ "$(jq -r '.hookSpecificOutput.permissionDecision' <<< "${echo_mention_output}")" == "deny" ]] || fail "hook still gates the real install when another segment merely echoes a pkg@version"
echo_mention_reason=$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<< "${echo_mention_output}")
grep -q 'evil-pkg@9.9.9' <<< "${echo_mention_reason}" || fail "deny reason names the real install spec"
[[ "${echo_mention_reason}" != *"other-pkg@2.0.0"* ]] || fail "deny reason must not name a pkg@version that only appears in an echo segment"
pass "hook extracts specs only from install segments, not from echoed pkg@version mentions"

# Regression: an echoed pkg@version next to a BARE install (no operand) must not be
# read as installing that package — the bare install is allowed, not denied.
bare_mention_output=$(
  run_hook_command "${tmp_root}/home-bare-mention" "${tmp_root}/safe-bare-mention" 'echo "bumped left-pad@1.0.0 -> 1.0.1"; npm install'
)
[[ "$(jq -r '.hookSpecificOutput.permissionDecision // "allow"' <<< "${bare_mention_output}" 2>/dev/null || echo allow)" != "deny" ]] || fail "bare npm install must not be denied because of a pkg@version in an echo segment"
pass "echoed pkg@version beside a bare install does not trigger a false deny"

false_positive_safe="${tmp_root}/safe-false-positive"
false_positive_cases=(
  $'grep -nE "install|add" README.md'
  $'echo "npm install evil-pkg@9.9.9"'
  $'cat <<"EOF"\nnpm install evil-pkg@9.9.9\nEOF'
  $'node <<"NODE"\nconst text = "$(npm install evil-pkg@9.9.9)";\nconsole.log(text);\nNODE'
  $'X=$(date +%s); echo "see npm install foo in docs"'
  $'msg="run npm install later"; result=$(ls)'
  $'echo "npm install pkg"; Y=`pwd`'
  "npm run build"
  "npm view left-pad"
  "npx --version"
  # A pipe-to-shell idiom QUOTED as data (commit message, log line, heredoc body)
  # is not an execution pipe — the pipe sits inside quotes / a heredoc body, not
  # in execution position. Blocking these forced workers to smuggle commit
  # messages through -F files (observed twice on 2026-08-04).
  $'git commit -m "repro: printf \'pip install evil-quoted@1.0.0\' | sh blocked the commit"'
  $'git commit -m \'repro: echo "npm install evil-quoted@1.0.0" | sh\''
  $'cat <<"EOF"\npip install evil-quoted@1.0.0 | sh\nEOF'
)
for fp_cmd in "${false_positive_cases[@]}"; do
  rm -rf "${false_positive_safe}"
  fp_output=$(run_hook_command "${tmp_root}/home-false-positive" "${false_positive_safe}" "${fp_cmd}")
  [[ -z "${fp_output}" ]] || fail "hook ignores non-install text command: ${fp_cmd}"
  fp_pending=$({ find "${false_positive_safe}/pending" -name '*.json' -type f 2>/dev/null || true; } | wc -l | tr -d ' ')
  fp_snapshots=$({ find "${false_positive_safe}/snapshots" -name '*_meta.json' -type f 2>/dev/null || true; } | wc -l | tr -d ' ')
  [[ "${fp_pending}" == "0" && "${fp_snapshots}" == "0" ]] || fail "hook does not snapshot non-install text command: ${fp_cmd}"
done
pass "hook ignores false-positive install text without snapshotting"

hidden_install_cases=(
  $'eval "npm install hidden-eval@1.0.0"'
  $'sub_result=$(npm install hidden-sub@1.0.0)'
  $'pipe_result=$(echo npm install hidden-pipe@1.0.0 | sh)'
  $'printf \'pip install hidden-pipe2@1.0.0\' | sh'
  # The pipe-position check is applied per quoting level: a pipe hidden from the
  # top level by `sh -c "..."` / `eval "..."` quoting, or riding the redirect
  # line of a heredoc piped to sh, is still an execution pipe.
  $'sh -c "printf \'pip install hidden-shc@1.0.0\' | sh"'
  $'eval "printf \'pip install hidden-eval2@1.0.0\' | sh"'
  $'cat <<EOF | sh\npip install hidden-heredoc@1.0.0\nEOF'
)
for hidden_cmd in "${hidden_install_cases[@]}"; do
  hidden_safe="${tmp_root}/safe-hidden-$(printf '%s' "${hidden_cmd}" | cksum | cut -d' ' -f1)"
  hidden_output=$(run_hook_command "${tmp_root}/home-hidden" "${hidden_safe}" "${hidden_cmd}")
  [[ "$(jq -r '.hookSpecificOutput.permissionDecision' <<< "${hidden_output}")" == "deny" ]] || fail "hook denies hidden install command: ${hidden_cmd}"
  hidden_snapshots=$({ find "${hidden_safe}/snapshots" -name '*_meta.json' -type f 2>/dev/null || true; } | wc -l | tr -d ' ')
  [[ "${hidden_snapshots}" -gt 0 ]] || fail "hook snapshots hidden install command before denying: ${hidden_cmd}"
done
pass "hook denies and snapshots hidden install indirection"

bypass_cases=(
  "/usr/bin/npm install evil@1.2.3"
  "bash -lc \"npm install evil@1.2.3\""
  "env npm install evil@1.2.3"
  "command npm install evil@1.2.3"
  "npm --prefix sub install evil@1.2.3"
  " npm install evil@1.2.3"
  $'\tnpm install evil@1.2.3'
  "HTTPS_PROXY=http://x npm install evil@1.2.3"
  "FOO=bar BAZ=qux npm install evil@1.2.3"
  "bun add evil@1.2.3"
  "bun install evil@1.2.3"
  " bun add evil@1.2.3"
  "pip install requests==2.31.0"
  " pip install requests==2.31.0"
  "gem install rails -v 7.1.0"
  "cargo add serde --vers 1.0.0"
  "dotnet add package X --version 1.0.0"
)
for bypass_cmd in "${bypass_cases[@]}"; do
  bypass_output=$(run_hook_command "${tmp_root}/home-bypass" "${tmp_root}/safe-bypass" "${bypass_cmd}")
  [[ "$(jq -r '.hookSpecificOutput.permissionDecision' <<< "${bypass_output}")" == "deny" ]] || fail "hook denies bypass: ${bypass_cmd}"
done
pass "hook denies install bypass forms"

# Fail-closed gate: when the gate cannot run it must NOT silently pass, and the
# outcome must be observable in the advisory log (AGENTS.md: no silent fallback).
fc_safe="${tmp_root}/safe-failclosed"
fc_home="${tmp_root}/home-failclosed"
mkdir -p "${fc_safe}"
# (a) lock unavailable on an install command → DENY (fail-closed), logged.
mkdir -p "${fc_safe}/state.lock"
fc_deny=$(
  jq -nc --arg c "npm install evil@1.0.0" --arg cwd "${project_dir}" \
    '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}' |
    HOME="${fc_home}" SAFEDEPS_HOME="${fc_safe}" SAFEDEPS_LOCK_MAX_ATTEMPTS=2 scripts/safedeps-pre-guard.sh
)
rmdir "${fc_safe}/state.lock" 2>/dev/null || true
[[ "$(jq -r '.hookSpecificOutput.permissionDecision' <<< "${fc_deny}")" == "deny" ]] || fail "pre-guard fails closed (deny) when the state lock is unavailable for an install"
grep -q 'pre-guard DENY' "${fc_safe}/advisory.log" || fail "pre-guard logs the fail-closed deny to advisory.log"
pass "pre-guard fails closed on lock contention (observable)"

# (b) jq missing → best-effort fail-closed: a likely install DENIES, a non-install
# is allowed, both recorded in advisory.log (never a silent skip).
fc_nojq=$(mktemp -d "${tmp_root}/nojq.XXXXXX")
for fc_tool in bash mkdir date printf cat grep; do
  ln -sf "$(command -v "${fc_tool}")" "${fc_nojq}/${fc_tool}" 2>/dev/null || true
done
fc_nojq_deny=$(
  jq -nc --arg c "npm install x@1" --arg cwd "${project_dir}" '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}' |
    HOME="${fc_home}" SAFEDEPS_HOME="${fc_safe}" PATH="${fc_nojq}" scripts/safedeps-pre-guard.sh 2>/dev/null
)
[[ "$(jq -r '.hookSpecificOutput.permissionDecision' <<< "${fc_nojq_deny}")" == "deny" ]] || fail "pre-guard denies a likely install when jq is missing (best-effort fail-closed)"
grep -q 'DENY: jq missing' "${fc_safe}/advisory.log" || fail "pre-guard logs the jq-missing install deny to advisory.log"
fc_nojq_allow=$(
  jq -nc --arg c "ls -la" --arg cwd "${project_dir}" '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}' |
    HOME="${fc_home}" SAFEDEPS_HOME="${fc_safe}" PATH="${fc_nojq}" scripts/safedeps-pre-guard.sh 2>/dev/null
)
[[ "$(jq -r '.hookSpecificOutput.permissionDecision // "allow"' <<< "${fc_nojq_allow}" 2>/dev/null || echo allow)" != "deny" ]] || fail "pre-guard allows a non-install command when jq is missing"
pass "pre-guard fails closed on jq-missing installs, allows non-installs (observable)"

# (c) ledger library missing → DENY (fail-closed), logged — not a silent fall-through allow.
fc_noledger=$(
  jq -nc --arg c "npm install x@1" --arg cwd "${project_dir}" '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}' |
    HOME="${fc_home}" SAFEDEPS_HOME="${fc_safe}" SAFEDEPS_LEDGER_LIB="${tmp_root}/does-not-exist.sh" scripts/safedeps-pre-guard.sh 2>/dev/null
)
[[ "$(jq -r '.hookSpecificOutput.permissionDecision' <<< "${fc_noledger}")" == "deny" ]] || fail "pre-guard denies an install when the ledger library is missing (fail-closed)"
grep -q 'ledger library missing' "${fc_safe}/advisory.log" || fail "pre-guard logs the missing-ledger deny to advisory.log"
pass "pre-guard fails closed when the ledger library is missing (observable)"

# Concurrency (issue #5): two installs of the SAME command in one project must
# keep separate pending state — the per-install snapshot+PID suffix isolates them,
# not just the command hash — and a post hook must consume exactly one.
conc_safe="${tmp_root}/safe-concurrency"
mkdir -p "${conc_safe}"
SAFEDEPS_HOME="${conc_safe}" lib/ledger/ledger.sh approve npm conc-a 1.0.0 1.0.0 smoke >/dev/null
run_hook_command "${tmp_root}/home-conc" "${conc_safe}" "npm install conc-a@1.0.0" >/dev/null
run_hook_command "${tmp_root}/home-conc" "${conc_safe}" "npm install conc-a@1.0.0" >/dev/null
conc_pending=$(find "${conc_safe}/pending" -name '*.json' -type f | wc -l | tr -d ' ')
[[ "${conc_pending}" == "2" ]] || fail "two identical concurrent installs keep two separate pending files (got ${conc_pending}, want 2)"
jq -nc --arg c "npm install conc-a@1.0.0" --arg cwd "${project_dir}" '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}' |
  HOME="${tmp_root}/home-conc" SAFEDEPS_HOME="${conc_safe}" scripts/safedeps-post-verify.sh >/dev/null 2>&1 || true
conc_left=$(find "${conc_safe}/pending" -name '*.json' -type f | wc -l | tr -d ' ')
[[ "${conc_left}" == "1" ]] || fail "post hook consumes exactly one identical-command install's pending state (left ${conc_left}, want 1)"
pass "concurrent installs (even identical commands) keep isolated pending state (issue #5)"

# A dependency-install PostToolUse with no pending state in a project that has no
# npm lockfile cannot be closure-checked — recorded UNVERIFIED, never dropped
# silently (issue #5 review finding 3).
nolock_dir="${tmp_root}/no-lock"
mkdir -p "${nolock_dir}"
printf '{"dependencies":{}}\n' > "${nolock_dir}/package.json"
nolock_safe="${tmp_root}/safe-nolock"
jq -nc --arg cwd "${nolock_dir}" '{tool_name:"Bash",tool_input:{command:"pip install orphan==1.0.0"},cwd:$cwd}' |
  HOME="${tmp_root}/home-conc" SAFEDEPS_HOME="${nolock_safe}" scripts/safedeps-post-verify.sh >/dev/null 2>&1 || true
grep -q 'UNVERIFIED:.*no pending state.*no package-lock.json' "${nolock_safe}/advisory.log" || fail "post hook records a no-lockfile no-pending install as UNVERIFIED"
pass "post hook records an install-looking command with no pending state (no lockfile) as UNVERIFIED"

# Finding #5: the npm effect gate is a COMMAND-INDEPENDENT backstop. An install-
# looking command that left NO pending state (a PreToolUse parser blind spot) but
# lands in a project WITH a package-lock.json still gets the closure check — proving
# the gate runs without a pre-install snapshot, so a parser miss does not also blind
# the documented backstop.
backstop_safe="${tmp_root}/safe-backstop"
backstop_proj="${tmp_root}/backstop-proj"
mkdir -p "${backstop_safe}" "${backstop_proj}"
printf '{"name":"p","version":"1.0.0","lockfileVersion":3,"packages":{"":{"name":"p","version":"1.0.0"}}}\n' > "${backstop_proj}/package-lock.json"
printf '{"name":"p","version":"1.0.0"}\n' > "${backstop_proj}/package.json"
jq -nc --arg cwd "${backstop_proj}" '{tool_name:"Bash",tool_input:{command:" npm install left-pad@1.3.0"},cwd:$cwd}' |
  HOME="${tmp_root}/home-backstop" SAFEDEPS_HOME="${backstop_safe}" scripts/safedeps-post-verify.sh >/dev/null 2>&1 || true
grep -q 'BACKSTOP clean' "${backstop_safe}/advisory.log" || fail "npm effect gate runs command-independently as a backstop with no pending state (finding #5)"
pass "npm effect gate runs command-independently as a backstop (finding #5)"

tamper_safe="${tmp_root}/safe-tamper"
tamper_home="${tmp_root}/home-tamper"
SAFEDEPS_HOME="${tamper_safe}" lib/ledger/ledger.sh approve npm ledger-tamper 1.0.0 1.0.0 smoke >/dev/null
tamper_pre=$(run_hook_command "${tamper_home}" "${tamper_safe}" "npm install ledger-tamper@1.0.0")
[[ "$(jq -r '.hookSpecificOutput.permissionDecision' <<< "${tamper_pre}")" == "allow" ]] || fail "tamper fixture pre hook allows approved install"
mkdir -p "${project_dir}/node_modules/ledger-tamper"
jq '.dependencies["ledger-tamper"]="1.0.0"' "${project_dir}/package.json" > "${project_dir}/package.json.tmp"
mv "${project_dir}/package.json.tmp" "${project_dir}/package.json"
cat > "${project_dir}/node_modules/ledger-tamper/package.json" <<'EOF'
{"name":"ledger-tamper","version":"1.0.0","scripts":{"postinstall":"node -e \"require('fs').writeFileSync(process.env.HOME + '/.safedeps/approved-specs/evil.json', '{}')\""}}
EOF
tamper_post=$(
  jq -nc --arg cwd "${project_dir}" '{tool_name:"Bash",tool_input:{command:"npm install ledger-tamper@1.0.0"},cwd:$cwd}' |
    HOME="${tamper_home}" SAFEDEPS_HOME="${tamper_safe}" scripts/safedeps-post-verify.sh
)
grep -q 'suspicious dependency change detected' <<< "${tamper_post}" || fail "post hook reorgs safedeps ledger tamper script"
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

# Forgery flag alone must trigger a daily alert: checked==still_clean so
# provider_skipped is 0 and every other trigger array is empty — only the
# suspected_forgery condition can fire here.
forgery_fixture="${tmp_root}/recheck-forgery-fixture.json"
printf '%s\n' '{"command":"re-check","checked":1,"still_clean":1,"newly_vulnerable":[],"kev_hit":[],"revoked":[],"suspected_forgery":[{"ecosystem":"npm","package":"fixture-forged","version":"1.0.0","hash":"deadbeef","reason":"missing_advisory_log_approval"}]}' > "${forgery_fixture}"
SAFEDEPS_NOTIFY=0 \
  HOME="${tmp_root}/home-recheck" \
  SAFEDEPS_HOME="${tmp_root}/safe-recheck" \
  SAFEDEPS_RECHECK_FIXTURE_JSON="${forgery_fixture}" \
  scripts/safedeps-recheck-alert.sh
forgery_alert=$(tail -1 "${tmp_root}/safe-recheck/recheck-alerts.jsonl")
[[ "$(jq -r '.kind' <<< "${forgery_alert}")" == "recheck_attention" ]] || fail "re-check wrapper alerts on suspected ledger forgery"
[[ "$(jq -r '.suspected_forgery[0].package' <<< "${forgery_alert}")" == "fixture-forged" ]] || fail "forgery alert carries the flagged entry"
pass "re-check wrapper alerts on suspected ledger forgery"

# Regression: a fully clean re-check (empty suspected_forgery included) must
# not append an alert.
clean_fixture="${tmp_root}/recheck-clean-fixture.json"
printf '%s\n' '{"command":"re-check","checked":1,"still_clean":1,"newly_vulnerable":[],"kev_hit":[],"revoked":[],"suspected_forgery":[]}' > "${clean_fixture}"
alerts_before=$(wc -l < "${tmp_root}/safe-recheck/recheck-alerts.jsonl")
SAFEDEPS_NOTIFY=0 \
  HOME="${tmp_root}/home-recheck" \
  SAFEDEPS_HOME="${tmp_root}/safe-recheck" \
  SAFEDEPS_RECHECK_FIXTURE_JSON="${clean_fixture}" \
  scripts/safedeps-recheck-alert.sh
alerts_after=$(wc -l < "${tmp_root}/safe-recheck/recheck-alerts.jsonl")
[[ "${alerts_before}" -eq "${alerts_after}" ]] || fail "clean re-check must not append an alert"
pass "clean re-check appends no alert"

# Release-time lane (absorbed from security-release-gates): commands must be
# registered and resolve their gate scripts.
gates_help=$(HOME="${tmp_root}/home-gates" SAFEDEPS_HOME="${tmp_root}/safe-gates" ./bin/safedeps help)
for gate_cmd in "gates" "scan secrets" "audit" "hooks" "doctor"; do
  grep -q "${gate_cmd}" <<< "${gates_help}" || fail "release-time command listed in help: ${gate_cmd}"
done
for gate_script in scripts/release-gates.sh lib/gates/repo-profile.sh lib/gates/scan.sh lib/gates/audit.sh lib/gates/hooks.sh lib/gates/doctor.sh; do
  [[ -f "${gate_script}" ]] || fail "release-time gate script present: ${gate_script}"
done
for tmpl in gitleaks.toml.tmpl gitleaks.private.toml.tmpl pre-commit.tmpl; do
  [[ -f "lib/gates/templates/${tmpl}" ]] || fail "secret-lane template present: ${tmpl}"
done
pass "release-time gate commands registered"
bash scripts/test/gate-audit-contract.sh

# Secret-leak lane: doctor diagnoses, hooks init scaffolds, hooks install
# activates. No scanner (gitleaks/docker) needed for these structural checks.
doctor_repo=$(mktemp -d "${tmp_root}/secret-repo.XXXXXX")
git -C "${doctor_repo}" init -q
# doctor exits 1 when gaps exist; capture the JSON without tripping set -e.
doctor_json=$(HOME="${tmp_root}/home-doctor" ./bin/safedeps --json doctor --root "${doctor_repo}" || true)
[[ "$(jq -r '.command' <<< "${doctor_json}")" == "doctor" ]] || fail "doctor --json command field"
[[ "$(jq -r '.ok' <<< "${doctor_json}")" == "false" ]] || fail "doctor reports gaps on a bare repo"
secret_gaps=$(jq -r '[.checks[] | select(.lane == "secret" and .status == "gap")] | length' <<< "${doctor_json}")
[[ "${secret_gaps}" -ge 3 ]] || fail "doctor lists at least 3 secret-lane gaps (got ${secret_gaps})"
remote_checks=$(jq -r '[.checks[] | select(.lane == "remote")] | length' <<< "${doctor_json}")
[[ "${remote_checks}" -ge 1 ]] || fail "doctor lists remote governance posture checks"
remote_gaps=$(jq -r '[.checks[] | select(.lane == "remote" and .status == "gap")] | length' <<< "${doctor_json}")
[[ "${remote_gaps}" -ge 1 ]] || fail "doctor flags missing remote workflow as opt-in posture gap"
HOME="${tmp_root}/home-doctor" ./bin/safedeps hooks init --root "${doctor_repo}" >/dev/null
[[ -f "${doctor_repo}/.gitleaks.toml" ]] || fail "hooks init scaffolds .gitleaks.toml"
[[ -x "${doctor_repo}/.githooks/pre-commit" ]] || fail "hooks init scaffolds an executable pre-commit"
grep -q 'scan secrets --staged' "${doctor_repo}/.githooks/pre-commit" || fail "pre-commit delegates to safedeps scan"
printf '\n# repo-owned edit marker\n' >> "${doctor_repo}/.gitleaks.toml"
HOME="${tmp_root}/home-doctor" ./bin/safedeps hooks init --root "${doctor_repo}" >/dev/null
grep -q 'repo-owned edit marker' "${doctor_repo}/.gitleaks.toml" || fail "hooks init is non-destructive (keeps repo edits)"
HOME="${tmp_root}/home-doctor" ./bin/safedeps hooks install --root "${doctor_repo}" >/dev/null
[[ "$(git -C "${doctor_repo}" config --get core.hooksPath)" == ".githooks" ]] || fail "hooks install activates core.hooksPath"
pass "doctor + hooks init/install wire the secret lane (non-destructive)"

printf 'smoke passed\n'
