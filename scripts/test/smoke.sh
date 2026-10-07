#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "${ROOT_DIR}"

pass() {
  hook_response_assert || fail "a hook response could not be read"
  printf 'ok - %s\n' "$1"
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-smoke.XXXXXX")
# shellcheck source=lib/hook-response.sh
source "${ROOT_DIR}/scripts/test/lib/hook-response.sh"
hook_response_init "${tmp_root}/hook-response.failures"
# shellcheck source=lib/release-floor.sh
source scripts/test/lib/release-floor.sh
RELEASE_FLOOR_FAILS="${tmp_root}/release-floor.fails"
: > "${RELEASE_FLOOR_FAILS}"
cleanup() {
  local cleanup_rc=$?
  if [[ "${cleanup_rc}" == 0 ]] && hook_response_assert; then
    rm -rf "${tmp_root}"
  else
    printf '# failed row artifacts: %s\n' "${tmp_root}" >&2
  fi
}
trap cleanup EXIT

# The reader-only entry executes exactly the migrated contracts. Other smoke
# contracts (CLI, provider and hook fault fixtures) still run in the full suite.
# shellcheck source=lib/core-smoke.sh
source "${ROOT_DIR}/scripts/test/lib/core-smoke.sh"
if [[ "${1:-}" == --reader-contracts-only ]]; then
  core_smoke_budget
  core_smoke_pending
  exit 0
fi

bash -n bin/safedeps
bash -n lib/providers/providers.sh
bash -n lib/ledger/ledger.sh
bash -n lib/npm/closure.sh
bash -n lib/npm/ask.sh
# Native hooks have no Bash body to syntax-check. The canonical shim does.
bash -n scripts/safedeps-hook-entry.sh
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

# The core's crate is the third place the version is written: `safedeps-core
# version` prints it, so a release that bumped the other two would ship a
# binary that names the old one.
crate_version=$(awk -F'"' '/^version = "/ { print $2; exit }' rust/Cargo.toml)
[[ "${crate_version}" == "${pkg_version}" ]] || fail "rust/Cargo.toml version (${crate_version}) matches package.json (${pkg_version})"
lock_version=$(awk -F'"' '/^name = "safedeps-core"$/ { hit = 1; next } hit && /^version = "/ { print $2; exit }' rust/Cargo.lock)
[[ "${lock_version}" == "${pkg_version}" ]] || fail "rust/Cargo.lock names safedeps-core ${lock_version}, package.json ${pkg_version}"
pass "crate version"

core_smoke_budget

# The manual-install docs and the installer describe the same registration, and
# they are different files — which is exactly how they drifted: the docs told
# readers to register the hook scripts directly for as long as the shim has
# existed, while AGENTS.md said the registered command is the shim. Following
# the docs still gated installs, but without the shim a broken checkout goes
# back to being a silently disabled gate, and the reader had no way to know.
# The comparison is machine-made now rather than left to whoever reads both.
installer_entry=$(grep -m1 '^const ENTRY_HOOK_NAME = ' scripts/install/install-safedeps-hooks.mjs | sed 's/.*"\(.*\)".*/\1/')
[[ -n "${installer_entry}" ]] || fail "installer entry-hook constant is readable"
# The timeout is part of the registration, so it is pinned like the command.
# Pinning only the command string is the same defect one layer in: the docs
# would keep naming the right script at a number the installer stopped writing,
# and nothing would say so. The guard already reads PRE_HOOK_TIMEOUT_SECONDS for
# its own ceiling, so this is the same constant read a third time rather than a
# new place for the truth to live.
installer_pre_timeout=$(grep -m1 '^const PRE_HOOK_TIMEOUT_SECONDS = ' scripts/install/install-safedeps-hooks.mjs | tr -dc '0-9')
installer_post_timeout=$(grep -m1 '^const POST_HOOK_TIMEOUT_SECONDS = ' scripts/install/install-safedeps-hooks.mjs | tr -dc '0-9')
[[ -n "${installer_pre_timeout}" && -n "${installer_post_timeout}" ]] \
  || fail "installer hook-timeout constants are readable"
for doc in README.md README.ko.md; do
  for target in pre post; do
    grep -q "${installer_entry} ${target}" "${doc}" \
      || fail "${doc} registers the entry shim with '${target}' (the command the installer writes)"
    # The timeout belongs to the same hook entry, so read it from the line after
    # the command rather than from anywhere in the file.
    doc_timeout=$(grep -A1 "${installer_entry} ${target}" "${doc}" | grep -m1 '"timeout"' | tr -dc '0-9')
    case "${target}" in
      pre)  want="${installer_pre_timeout}" ;;
      post) want="${installer_post_timeout}" ;;
    esac
    [[ "${doc_timeout}" == "${want}" ]] \
      || fail "${doc} states the ${target}-hook timeout the installer writes (doc=${doc_timeout:-none}, installer=${want})"
  done
  # The hook scripts must not be named as a registered command anywhere in the
  # manual block; naming them in prose or in a tree listing is fine.
  if grep -qE '"command":[^"]*"[^"]*safedeps-(pre-guard|post-verify)\.sh"' "${doc}"; then
    fail "${doc} does not register a hook script directly"
  fi
done
# SKILL.md must not carry a second registration declaration. The shape checked
# here is the legacy `- type: <event>` / `script:` block that was removed: no
# documented schema reads it, so it declared an installation that never
# happened. Claude's documented skill-frontmatter form (event-keyed, with
# `matcher` and `command:`) is deliberately NOT matched — it is a real feature,
# scoped to the skill's lifecycle and running only while the skill is active,
# which is why it cannot carry this gate and why forbidding it by grep would
# block something that works rather than remove something dead. If safedeps ever
# wants that form, that is a decision about having two registration channels,
# and AGENTS.md is where it gets made.
# The post hook is registered for PostToolUseFailure on Claude Code too, and
# the manual block says so where the installer does.
grep -q '^  claude: \["PostToolUse", "PostToolUseFailure"\],$' scripts/install/install-safedeps-hooks.mjs \
  || fail "the installer registers the claude post hook for PostToolUse and PostToolUseFailure"
for doc in README.md README.ko.md; do
  grep -A6 '"PostToolUseFailure": \[' "${doc}" | grep -q "${installer_entry} post" \
    || fail "${doc} registers the entry shim with 'post' for PostToolUseFailure"
done
if grep -qE '^\s*script:\s*scripts/safedeps-' SKILL.md; then
  fail "SKILL.md leaves registration to the installer rather than declaring its own"
fi
pass "manual-install docs register the same command the installer writes"

# The prose states the hook budget ONCE per language, and that once is pinned.
# The JSON blocks above were pinned first, and the number went on living in six
# sentences that no check read — the same drift one field over, which is how it
# was found. Enumerating the phrasings would be the wrong fix: this repo has
# been burned twice by enumerations that a new form walks past. So the number is
# removed from the restatements instead, leaving one canonical sentence per
# language, and the rule below is a proximity rule over our own corpus rather
# than a list of ways to say it.
budget_doc_en="ARCHITECTURE.md"
budget_doc_ko="ARCHITECTURE.ko.md"
grep -q "PRE_HOOK_TIMEOUT_SECONDS\`, ${installer_pre_timeout}s\|PRE_HOOK_TIMEOUT_SECONDS\` in \`scripts/install/install-safedeps-hooks.mjs\`, ${installer_pre_timeout}s" "${budget_doc_en}" \
  || fail "${budget_doc_en} states the hook budget the installer registers (${installer_pre_timeout}s)"
grep -q "PRE_HOOK_TIMEOUT_SECONDS\`, ${installer_pre_timeout}s" "${budget_doc_ko}" \
  || fail "${budget_doc_ko} states the hook budget the installer registers (${installer_pre_timeout}s)"
pass "the prose states the hook budget the installer registers"

# Anywhere else, a sentence that puts THAT figure next to a budget word is
# either a dated measurement (a fact about a day, which stays true when the
# constant moves) or a restatement that will rot. Restatements say "the budget"
# and let the canonical sentence carry the number. Only the installer's own
# figure is matched, so the self-budget ceiling, the poll steps, and every other
# measured duration are left alone — they are pinned by their own constants.
#
# What this pair does and does not cover. The canonical pin is what actually
# closes the drift: it catches the constant moving, whatever the prose looks
# like. This rule is a second-order backstop for a restatement coming back while
# the constant is unchanged, and it leaks in ways worth naming rather than
# leaving for a reader to discover — a check whose limits go unread is read as
# coverage, which is the defect this whole line of work has been about:
#   - the document list below is hardcoded, so a restatement in a new file walks past
#   - it matches one written form (`<N>s`), so `30 second budget` walks past
#   - it matches `<N>s` only mid-line, so a line starting with the figure walks past
#   - it is line-based, so a sentence split across two lines walks past
#   - the measurement exemption tests for the WORD `measured`, not for a date
# Two structural axes are outside both checks and need the documented JSON
# parsed against the installer's output to close, which is a separate decision:
# a second registration block added for the same event, and a doc that swaps the
# `pre` and `post` registrations.
for doc in SKILL.md README.md README.ko.md AGENTS.md ARCHITECTURE.md ARCHITECTURE.ko.md; do
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    grep -q 'PRE_HOOK_TIMEOUT_SECONDS' <<< "${line}" && continue
    grep -qiE 'measured|실측' <<< "${line}" && continue
    fail "${doc} restates the hook budget figure instead of naming the budget (${line:0:90})"
  done < <(grep -E "(budget|timeout|예산|타임아웃)" "${doc}" | grep -E "[^0-9]${installer_pre_timeout}s([^a-zA-Z0-9]|$)" || true)
done
pass "no doc restates the hook budget figure outside the canonical sentence"

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

# The public registry is a scheme and a host at the start of a source, not a
# name anywhere in it. A tarball under a directory named registry.npmjs.org
# passed the substring test as the registry (effect-trace-grid B1-B3); the
# https host forms have no TLS fixture to install from, so they are pinned here.
while IFS='|' read -r want url; do
  [[ -n "${url}" ]] || continue
  if bash -c 'source lib/npm/closure.sh; safedeps_npm_public_registry_url "$1"' _ "${url}"; then got=public; else got=other; fi
  [[ "${got}" == "${want}" ]] || fail "registry source ${url} reads as ${want} (got ${got})"
  # The rebuild check reads the same pattern in jq (post-verify).
  got=$(bash -c 'source lib/npm/closure.sh; jq -nr --arg re "${SAFEDEPS_NPM_PUBLIC_REGISTRY_RE}" --arg u "$1" "if (\$u | test(\$re; \"i\")) then \"public\" else \"other\" end"' _ "${url}")
  [[ "${got}" == "${want}" ]] || fail "registry source ${url} reads as ${want} in jq too (got ${got})"
done <<'URLS'
public|https://registry.npmjs.org/sd-approved/-/sd-approved-1.0.0.tgz
public|https://registry.yarnpkg.com/sd-approved/-/sd-approved-1.0.0.tgz
public|HTTPS://Registry.NPMJS.org/sd-approved/-/sd-approved-1.0.0.tgz
other|file:registry.npmjs.org/sd-approved-1.0.0.tgz
other|https://registry.npmjs.org.example/sd-approved/-/sd-approved-1.0.0.tgz
other|https://registry.npmjs.org@evil.example/sd-approved-1.0.0.tgz
other|https://evil.example/registry.npmjs.org/sd-approved-1.0.0.tgz
other|http://registry.npmjs.org/sd-approved/-/sd-approved-1.0.0.tgz
other|git+https://registry.npmjs.org/sd-approved.git
other|../registry.npmjs.org
URLS
pass "a source is on the public registry only when it starts with the registry's https URL"

# What an npm record holds that the earlier ones did not, entry by entry. A
# link and its target are read (the rebuild runs the target's scripts), and so
# is a directory outside node_modules; the project's own entry is not.
rec_dir=$(mktemp -d "${tmp_root}/records.XXXXXX")
jq -n '{lockfileVersion: 3, packages: {
  "": {name: "proj", version: "1.0.0"},
  "node_modules/sd-approved": {version: "1.0.0", resolved: "https://registry.npmjs.org/sd-approved/-/sd-approved-1.0.0.tgz"}}}' \
  > "${rec_dir}/before.json"
jq -n '{lockfileVersion: 3, packages: {
  "": {name: "proj", version: "1.0.1"},
  "node_modules/sd-approved": {version: "1.0.0", resolved: "https://registry.npmjs.org/sd-approved/-/sd-approved-1.0.0.tgz"},
  "node_modules/evildir": {resolved: "../evildir", link: true},
  "../evildir": {name: "evildir", version: "1.0.0"},
  "node_modules/b": {resolved: "packages/b", link: true},
  "packages/b": {name: "b", version: "1.0.0"},
  "node_modules/bare": {link: true},
  "node_modules/sd-victim": {version: "1.0.0", resolved: "file:vendor/sd-victim-1.0.0.tgz"}}}' \
  > "${rec_dir}/after.json"
rec_out=$(bash -c 'source lib/npm/closure.sh; safedeps_npm_new_records "$1" "$2"' _ "${rec_dir}/after.json" "${rec_dir}/before.json" | LC_ALL=C sort)
rec_want=$(printf '%s\n' \
  $'L\tnode_modules/b\tpackages/b' \
  $'L\tnode_modules/bare\t' \
  $'L\tnode_modules/evildir\t../evildir' \
  $'N\tnode_modules/sd-victim' \
  $'S\tfile:vendor/sd-victim-1.0.0.tgz' \
  $'T\t../evildir' \
  $'T\tpackages/b' | LC_ALL=C sort)
[[ "${rec_out}" == "${rec_want}" ]] || fail "the npm record reader reports links, their targets and fetched packages, and not the project's own entry (got: ${rec_out})"
rec_none=$(bash -c 'source lib/npm/closure.sh; safedeps_npm_new_records "$1" "$1"' _ "${rec_dir}/after.json")
[[ -z "${rec_none}" ]] || fail "a record read against itself holds nothing new (got: ${rec_none})"
pass "the npm record reader reports links, their targets and fetched packages, and not the project's own entry"

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

# A walk that stops only at `/` or a `.git` never ends on a path whose dirname
# reaches a fixed point short of `/`. A Windows drive path does (`dirname C:` is
# `C:` in Git Bash, `.` here), and so does any relative path. The hook then
# never answers, and the runtime kills it and lets the install run (GitHub #21).
# The fixture sits outside any Git repo, because a `.git` above the fixed point
# stops the walk first and hides the defect.
ov_nogit="${tmp_root}/ov-nogit"
mkdir -p "${ov_nogit}"
git -C "${ov_nogit}" rev-parse --git-dir >/dev/null 2>&1 \
  && fail "the fixed-point fixture sits outside any Git repo (${ov_nogit} is inside one)"
for ov_fixed in 'C:/tmp/probe' 'rel/dir'; do
  # `exec`, so the pid below is the walking shell itself and a KILL stops it.
  ( cd "${ov_nogit}" && SAFEDEPS_NPM_OVERRIDES_DIR="${ov_fixed}" \
      exec bash -c "source '${ROOT_DIR}/lib/npm/closure.sh'; safedeps_npm_repo_overrides_json" \
      > "${ov_nogit}/out" ) &
  ov_pid=$!
  ov_waited=0
  while kill -0 "${ov_pid}" 2>/dev/null && (( ov_waited < 100 )); do
    sleep 0.1
    ov_waited=$(( ov_waited + 1 ))
  done
  if kill -0 "${ov_pid}" 2>/dev/null; then
    kill -KILL "${ov_pid}" 2>/dev/null || true
    wait "${ov_pid}" 2>/dev/null || true
    fail "override discovery ends on a path whose dirname stops short of / (${ov_fixed} still walking after 10s)"
  fi
  wait "${ov_pid}" || fail "override discovery exits cleanly on ${ov_fixed}"
  [[ "$(cat "${ov_nogit}/out")" == "{}" ]] \
    || fail "override discovery finds nothing on ${ov_fixed} (got: $(cat "${ov_nogit}/out"))"
done
pass "npm closure override discovery ends at a dirname fixed point (drive root, relative path)"

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

# Every Claude call goes through the release floor (lib/release-floor.sh):
# wherever the hook lets a command run, deleting some of the flags it inserted
# gives the release's rewrite of that command.
run_hook_command() {
  local home_dir="$1"
  local safe_dir="$2"
  local command="$3"
  local payload out rewritten response_contract="${4:-decision}"

  payload=$(jq -nc --arg command "${command}" --arg cwd "${project_dir}" \
    '{tool_name:"Bash",tool_input:{command:$command},cwd:$cwd}')
  out=$(printf '%s' "${payload}" | HOME="${home_dir}" SAFEDEPS_HOME="${safe_dir}" \
    hook_response_capture "${home_dir}.response" scripts/safedeps-hook-entry.sh pre)
  hook_response_parse "${out}" "${response_contract}" || fail "hook response: ${command}"
  if [[ "${HOOK_QUIET}" == true || "${HOOK_DECISION}" == allow ]]; then
    rewritten="${HOOK_REWRITE}"
    release_floor_check "${payload}" "${rewritten}" "${safe_dir}" "${tmp_root}" || true
  fi
  printf '%s\n' "${out}"
}

run_codex_hook_command() {
  local home_dir="$1" safe_dir="$2" command="$3" out
  out=$(jq -nc --arg command "${command}" --arg cwd "${project_dir}" \
    '{tool_name:"Bash",tool_input:{command:$command},cwd:$cwd,turn_id:"turn-smoke",model:"codex-test"}' |
    HOME="${home_dir}" SAFEDEPS_HOME="${safe_dir}" \
      hook_response_capture "${home_dir}.response" scripts/safedeps-hook-entry.sh pre)
  hook_response_parse "${out}" "$4" || fail "Codex hook response: ${command}"
  printf '%s' "${out}"
}

deny_json=$(
  run_hook_command "${tmp_root}/home-hook" "${tmp_root}/safe-hook" "npm install left-pad@1.3.0"
)
[[ "$(hook_response_read decision "${deny_json}")" == "deny" ]] || fail "hook denies unapproved install"
pass "hook denies unapproved install"

mkdir -p "${tmp_root}/safe-hook-allow"
SAFEDEPS_HOME="${tmp_root}/safe-hook-allow" lib/ledger/ledger.sh approve npm left-pad 1.3.0 1.3.0 smoke >/dev/null
allow_output=$(
  run_hook_command "${tmp_root}/home-hook-allow" "${tmp_root}/safe-hook-allow" "npm install left-pad@1.3.0"
)
[[ "$(hook_response_read decision "${allow_output}")" == "allow" ]] || fail "hook emits Claude allow decision for approved install"
[[ "$(hook_response_read rewrite "${allow_output}")" == "npm install --ignore-scripts left-pad@1.3.0 --ignore-scripts" ]] || fail "hook injects --ignore-scripts for Claude npm install"
allow_sid=$(jq -r '.snapshot_id' "${tmp_root}/safe-hook-allow/pending/"*.json)
jq -e '.ignore_scripts_injected == true' "${tmp_root}/safe-hook-allow/snapshots/${allow_sid}_meta.json" >/dev/null || fail "hook records injected meta flag"
jq -e '.ignore_scripts_unread == false' "${tmp_root}/safe-hook-allow/snapshots/${allow_sid}_meta.json" >/dev/null || fail "hook records no unread warning for a rewrite it read"
pass "hook injects --ignore-scripts for Claude approved install"

# Global npm installs resolve into npm's global prefix and must not inherit the
# cwd project's approval context. Reusing that context denied a clean,
# unscoped approval whenever the agent session happened to start in a project
# with npm overrides. The local control below proves that only global mode is
# context-free; an ordinary project install still requires the scoped entry.
printf '{"dependencies":{},"overrides":{"left-pad":"1.3.0"}}\n' > "${project_dir}/package.json"
global_forms=(
  "npm install -g left-pad@1.3.0"
  "npm install --global left-pad@1.3.0"
  "npm -g install left-pad@1.3.0"
  "npm --global install left-pad@1.3.0"
  # npm's option parser (nopt) reads these as global too: a bundle of short
  # flags, `=value` on a boolean, a negated `--no-` with `=false`, and a unique
  # abbreviation of `--location`. Global is npm's answer (lib/npm/ask.sh), so
  # the ledger context follows npm rather than a list of spellings.
  "npm install -gf left-pad@1.3.0"
  "npm i -fg left-pad@1.3.0"
  "npm i -g=true left-pad@1.3.0"
  "npm i --locat=global left-pad@1.3.0"
  "npm i --no-global=false left-pad@1.3.0"
  # npm link installs a package the global tree lacks into the global prefix.
  "npm link left-pad@1.3.0"
)
for i in "${!global_forms[@]}"; do
  global_safe="${tmp_root}/safe-global-context-${i}"
  mkdir -p "${global_safe}"
  SAFEDEPS_HOME="${global_safe}" lib/ledger/ledger.sh approve npm left-pad 1.3.0 1.3.0 smoke >/dev/null
  global_output=$(run_hook_command "${tmp_root}/home-global-context-${i}" "${global_safe}" "${global_forms[$i]}")
  [[ "$(hook_response_read decision "${global_output}")" != "deny" ]] \
    || fail "approved global npm install ignores cwd project context: ${global_forms[$i]}"
done

global_unapproved=$(run_hook_command "${tmp_root}/home-global-unapproved" "${tmp_root}/safe-global-unapproved" "npm install -g unapproved-global@9.9.9")
[[ "$(hook_response_read decision "${global_unapproved}")" == "deny" ]] \
  || fail "unapproved global npm install remains denied"

local_context_safe="${tmp_root}/safe-local-context-control"
mkdir -p "${local_context_safe}"
SAFEDEPS_HOME="${local_context_safe}" lib/ledger/ledger.sh approve npm left-pad 1.3.0 1.3.0 smoke >/dev/null
local_context_output=$(run_hook_command "${tmp_root}/home-local-context-control" "${local_context_safe}" "npm install left-pad@1.3.0")
[[ "$(hook_response_read decision "${local_context_output}")" == "deny" ]] \
  || fail "local npm install still requires its cwd project context"

global_false_output=$(run_hook_command "${tmp_root}/home-global-false-control" "${local_context_safe}" "npm install --global=false left-pad@1.3.0")
[[ "$(hook_response_read decision "${global_false_output}")" == "deny" ]] \
  || fail "--global=false remains project-scoped"

mixed_safe="${tmp_root}/safe-mixed-global-local-control"
mkdir -p "${mixed_safe}"
SAFEDEPS_HOME="${mixed_safe}" lib/ledger/ledger.sh approve npm left-pad 1.3.0 1.3.0 smoke >/dev/null
SAFEDEPS_HOME="${mixed_safe}" lib/ledger/ledger.sh approve npm other-local 2.0.0 2.0.0 smoke >/dev/null
mixed_context_output=$(run_hook_command "${tmp_root}/home-mixed-global-local-control" "${mixed_safe}" "npm install -g left-pad@1.3.0 && npm install other-local@2.0.0")
[[ "$(hook_response_read decision "${mixed_context_output}")" == "deny" ]] \
  || fail "mixed global and local npm operations stay project-scoped"
# A payload's install lands where the payload decides, which the landing does
# not read, so it keeps the project's context (declared: the direction that
# can deny an approved package, never one that drops the context).
payload_context_output=$(run_hook_command "${tmp_root}/home-payload-global-control" "${local_context_safe}" "sh -c 'npm install -g left-pad@1.3.0'")
[[ "$(hook_response_read decision "${payload_context_output}")" == "deny" ]] \
  || fail "a global npm install inside a payload stays project-scoped"
printf '{"dependencies":{}}\n' > "${project_dir}/package.json"
pass "global npm approvals are context-free while local approvals remain project-scoped"

mkdir -p "${tmp_root}/safe-hook-codex"
SAFEDEPS_HOME="${tmp_root}/safe-hook-codex" lib/ledger/ledger.sh approve npm left-pad 1.3.0 1.3.0 smoke >/dev/null
codex_allow_output=$(
  run_codex_hook_command "${tmp_root}/home-hook-codex" "${tmp_root}/safe-hook-codex" "npm install left-pad@1.3.0" quiet
)
hook_response_parse "${codex_allow_output}" quiet || fail "hook keeps Codex approved install as plain allow"
codex_sid=$(jq -r '.snapshot_id' "${tmp_root}/safe-hook-codex/pending/"*.json)
jq -e '.ignore_scripts_injected == false' "${tmp_root}/safe-hook-codex/snapshots/${codex_sid}_meta.json" >/dev/null || fail "hook does not record injected meta flag for Codex"
pass "hook keeps Codex approved install as plain allow"

for inert_skip_cmd in "npm view left-pad" "npm run build" "npm --version"; do
  inert_skip_output=$(run_hook_command "${tmp_root}/home-inert-skip" "${tmp_root}/safe-inert-skip" "${inert_skip_cmd}" quiet)
  hook_response_parse "${inert_skip_output}" quiet || fail "hook does not inject non-install command: ${inert_skip_cmd}"
done
pass "hook does not inject npm non-install commands"

mkdir -p "${tmp_root}/safe-hook-ignore-scripts"
SAFEDEPS_HOME="${tmp_root}/safe-hook-ignore-scripts" lib/ledger/ledger.sh approve npm left-pad 1.3.0 1.3.0 smoke >/dev/null
ignore_scripts_output=$(
  run_hook_command "${tmp_root}/home-hook-ignore-scripts" "${tmp_root}/safe-hook-ignore-scripts" "npm install left-pad@1.3.0 --ignore-scripts" quiet
)
hook_response_parse "${ignore_scripts_output}" quiet || fail "hook does not duplicate --ignore-scripts"
ignore_sid=$(jq -r '.snapshot_id' "${tmp_root}/safe-hook-ignore-scripts/pending/"*.json)
jq -e '.ignore_scripts_injected == false' "${tmp_root}/safe-hook-ignore-scripts/snapshots/${ignore_sid}_meta.json" >/dev/null || fail "hook does not record injected meta flag when flag already exists"
pass "hook does not duplicate --ignore-scripts"

# Finding #7: on a COMPOUND command the inert-install flag must land ON the npm
# install, not appended to the end (which would put it on the trailing statement,
# leaving the install running lifecycle scripts).
mkdir -p "${tmp_root}/safe-compound"
SAFEDEPS_HOME="${tmp_root}/safe-compound" lib/ledger/ledger.sh approve npm left-pad 1.3.0 1.3.0 smoke >/dev/null
compound_out=$(run_hook_command "${tmp_root}/home-compound" "${tmp_root}/safe-compound" "npm install left-pad@1.3.0 && npm run build")
compound_cmd=$(hook_response_read rewrite "${compound_out}")
[[ "${compound_cmd}" == "npm install --ignore-scripts left-pad@1.3.0 --ignore-scripts && npm run build" ]] || fail "compound inert-install injects --ignore-scripts on the install, not the trailing command (got: ${compound_cmd})"
pass "compound install puts --ignore-scripts on the npm install, after its last argument (finding #7)"

# The same holds for a trailing comment, a heredoc and a second line: appending
# put the flag inside the comment (the shell drops it, the lifecycle scripts run,
# and the meta says they were suppressed), after the heredoc terminator, or on
# the last line. Each must land on the install; the quoted `#` is data and stays
# on the append path.
for inert_case in \
  "npm install left-pad@1.3.0 # rebuild the lockfile|npm install --ignore-scripts left-pad@1.3.0 --ignore-scripts # rebuild the lockfile" \
  $'npm install left-pad@1.3.0\necho done|npm install --ignore-scripts left-pad@1.3.0 --ignore-scripts\necho done' \
  $'npm install left-pad@1.3.0 <<EOF\nyes\nEOF|npm install --ignore-scripts left-pad@1.3.0 --ignore-scripts <<EOF\nyes\nEOF' \
  "npm install left-pad@1.3.0 --message 'a # b'|npm install --ignore-scripts left-pad@1.3.0 --message 'a # b' --ignore-scripts" \
  'npm --userconfig "/tmp/a b/.npmrc" install left-pad@1.3.0 # then npm i later|npm --userconfig "/tmp/a b/.npmrc" install --ignore-scripts left-pad@1.3.0 --ignore-scripts # then npm i later' \
  $'cat <<EOF > notes\nnpm i left-pad\nEOF\nnpm install left-pad@1.3.0|cat <<EOF > notes\nnpm i left-pad\nEOF\nnpm install --ignore-scripts left-pad@1.3.0 --ignore-scripts'
do
  inert_in="${inert_case%%|*}"
  inert_want="${inert_case#*|}"
  inert_out=$(run_hook_command "${tmp_root}/home-compound" "${tmp_root}/safe-compound" "${inert_in}")
  inert_got=$(hook_response_read rewrite "${inert_out}")
  [[ "${inert_got}" == "${inert_want}" ]] \
    || fail "inert flag lands on the install: $(printf '%q' "${inert_in}") (got: $(printf '%q' "${inert_got}"))"
done
pass "inert flag lands on the install before a comment, a heredoc or a second line"

# A script handed to a shell runs its install too, so the flag goes inside it:
# `sh -c '...'`, `eval '...'`, a double-quoted script with no escape, and a
# substitution inside quotes. The scan view blanks all of them, and an install
# in `sh -c '...'` beside a visible one ran its lifecycle scripts while the
# visible one was made inert (caught in the release integration). Appending is
# no answer either: after `sh -c '...'` the flag becomes the script's $0. Quoted
# data stays as written.
for inert_case in \
  "sh -c 'npm install left-pad@1.3.0'|sh -c 'npm install --ignore-scripts left-pad@1.3.0 --ignore-scripts'" \
  "npm install left-pad@1.3.0; sh -c 'cd sub && npm install left-pad@1.3.0'|npm install --ignore-scripts left-pad@1.3.0 --ignore-scripts; sh -c 'cd sub && npm install --ignore-scripts left-pad@1.3.0 --ignore-scripts'" \
  'bash -lc "npm install left-pad@1.3.0"|bash -lc "npm install --ignore-scripts left-pad@1.3.0 --ignore-scripts"' \
  "eval 'npm install left-pad@1.3.0'|eval 'npm install --ignore-scripts left-pad@1.3.0 --ignore-scripts'" \
  'echo "$(npm install left-pad@1.3.0)"|echo "$(npm install --ignore-scripts left-pad@1.3.0 --ignore-scripts)"' \
  "npm install left-pad@1.3.0 && echo 'npm install left-pad@1.3.0'|npm install --ignore-scripts left-pad@1.3.0 --ignore-scripts && echo 'npm install left-pad@1.3.0'"
do
  inert_in="${inert_case%%|*}"
  inert_want="${inert_case#*|}"
  inert_out=$(run_hook_command "${tmp_root}/home-compound" "${tmp_root}/safe-compound" "${inert_in}")
  inert_got=$(hook_response_read rewrite "${inert_out}")
  [[ "${inert_got}" == "${inert_want}" ]] \
    || fail "inert flag lands inside the script a shell runs: $(printf '%q' "${inert_in}") (got: $(printf '%q' "${inert_got}"))"
done
pass "inert flag lands inside a script handed to a shell, and quoted data stays as written"

# The name `npm` is read in any case, as the recognizer reads it: macOS volumes
# ignore case, so `NPM ci` runs npm. Three readers of the rewrite matched the
# name in its case, so the recognizer called these installs and the rewrite
# found no verb in them: each was a downgrade, and the install ran its scripts
# before the closure was verified, where main had appended the flag.
for inert_case in \
  "NPM ci|NPM ci --ignore-scripts" \
  "Npm install left-pad@1.3.0|Npm install --ignore-scripts left-pad@1.3.0 --ignore-scripts" \
  "X=1 NPM ci|X=1 NPM ci --ignore-scripts" \
  "NPM install left-pad@1.3.0 && echo ok|NPM install --ignore-scripts left-pad@1.3.0 --ignore-scripts && echo ok" \
  "sh -c 'Npm install left-pad@1.3.0'|sh -c 'Npm install --ignore-scripts left-pad@1.3.0 --ignore-scripts'"
do
  inert_in="${inert_case%%|*}"
  inert_want="${inert_case#*|}"
  inert_out=$(run_hook_command "${tmp_root}/home-compound" "${tmp_root}/safe-compound" "${inert_in}")
  inert_got=$(hook_response_read rewrite "${inert_out}")
  [[ "${inert_got}" == "${inert_want}" ]] \
    || fail "inert flag lands on an install whose npm is spelled in another case: $(printf '%q' "${inert_in}") (got: $(printf '%q' "${inert_got}"))"
done
pass "inert flag lands on an install whose npm is spelled in another case"

# Each adopted native conflict has an explicit reason supplied by its row.
# A fresh approval/state home keeps earlier installs from hiding new records.
expect_inert_conflict() {
  local command="$1" reason="$2" safe out state_dir advisory expected extra
  shift 2
  safe=$(mktemp -d "${tmp_root}/safe-conflict.XXXXXX")
  SAFEDEPS_HOME="${safe}" lib/ledger/ledger.sh approve npm left-pad 1.3.0 1.3.0 smoke >/dev/null
  out=$(run_hook_command "${tmp_root}/home-compound" "${safe}" "${command}")
  hook_response_parse "${out}" decision || fail "conflict response: ${command}"
  [[ "${HOOK_DECISION}" == deny && "${HOOK_REASON}" == *UNDECIDED* && "${HOOK_HAS_REWRITE}" == false ]] \
    || fail "expected ${reason} undecided without a rewrite: ${command} (got ${out})"
  if [[ "${reason}" == readings-place-apart ]]; then
    [[ "${HOOK_REASON}" == *"read the npm installs in this command in different places"* ]] \
      || fail "the decision names the readings that disagree: ${command}"
    expected="pre-guard DENY: the readings (bash zsh dash) put this command's npm installs in different places, so no single --ignore-scripts rewrite is inert for every shell — undecided, fail-closed. Command: ${command}"
  else
    expected="pre-guard DENY: inert rewrite obligations conflict (${reason}); UNDECIDED, no rewrite was sent. Command: ${command}"
  fi
  advisory=$(cut -f2- "${safe}/advisory.log")
  [[ $'\n'"${advisory}"$'\n' == *$'\n'"${expected}"$'\n'* ]] \
    || fail "the exact ${reason} conflict is recorded: ${command}"
  for extra in "$@"; do
    expected="${extra} Command: ${command}"
    [[ $'\n'"${advisory}"$'\n' == *$'\n'"${expected}"$'\n'* ]] \
      || fail "the conflict retains its accompanying advisory: ${expected}"
  done
  for state_dir in pending snapshots; do
    if [[ -d "${safe}/${state_dir}" ]]; then
      [[ -z "$(find "${safe}/${state_dir}" -mindepth 1 -print)" ]] \
        || fail "${reason} leaves no pending record, snapshot or meta (${state_dir}): ${command}"
    fi
  done
  pass "${reason}: UNDECIDED with no rewrite or state: $(printf '%q' "${command}")"
}

# A floor flag in piped heredoc data is outside the words of a command.
for inert_in in \
  $'npm install left-pad@1.3.0 && cat <<E | wc -l\nnpm install left-pad@1.3.0\nE' \
  $'npm install left-pad@1.3.0 && cat <<E | wc -l\nNpm install left-pad@1.3.0\nE' \
  $'npm install evil && cat <<E | wc -l\nNPM install evil\nE'
do
  expect_inert_conflict "${inert_in}" floor-outside-command
done

# A one-statement end flag would be the last option's value. These commands
# send no rewrite; the compound --cache row below owes no such end flag.
ask_option_advisories=(
  "pre-guard: the install's last option takes the next word as its value, or its words end npm's options, so npm cannot be asked with them without reading the ask's own flags as the install's."
  "pre-guard: the install's last option takes the next word as its value, or its words end npm's options, so npm cannot be asked which registry it fetches from with them."
)
for inert_in in \
  'npm install left-pad@1.3.0 --cache' \
  'npm install left-pad@1.3.0 -C' \
  'npm install --no-ignore-scripts left-pad@1.3.0 --reg' \
  "npm install left-pad@1.3.0 --message 'a b' --fetch-retries" \
  'npm ci -- x' \
  "npm ci --no-ignore-scripts '--' x"
do
  expect_inert_conflict "${inert_in}" end-flag-not-an-option "${ask_option_advisories[@]}"
done

# A floor flag must preserve npm's operands and be an option in every reading.
expect_inert_conflict 'npm install true' floor-not-an-option
expect_inert_conflict "alias -g left-pad@1.3.0='left-pad@1.3.0 --cache'; eval 'npm install true left-pad@1.3.0'" floor-not-an-option \
  'pre-guard UNGATED: npm install names a package with no version spec, so the ledger gate did not run. No effect gate reads the result of this install, so it is unverified. Unpinned: npm:true.'
expect_inert_conflict 'npm -- ci -- x' floor-not-an-option "${ask_option_advisories[@]}"
expect_inert_conflict 'npm install x\ y -- "$HOME" sh -c "x\y npm"' end-flag-not-an-option \
  'pre-guard: this npm install depends on $HOME, which the shell decides at run time or this gate does not reproduce, so safedeps cannot ask npm where it lands.'
expect_inert_conflict 'npm i left-pad@1.3.0 && sh -c npm\ ci' floor-outside-command

# Shell-specific grouping can put install words at different offsets.
for inert_in in \
  'npm install left-pad@1.3.0 --ignore-scripts } --no-ignore-scripts' \
  'npm install left-pad@1.3.0 --message x(.)' \
  'npm install left-pad@1.3.0 (--cache|zz)' \
  $'shopt -s extglob\nnpm install left-pad@1.3.0 @(--cache)'
do
  expect_inert_conflict "${inert_in}" readings-place-apart
done

# npm keeps the last value an option is given. These readable installs get
# the floor flag and the flag after the last argument; quoted data stays data.
# The explicit conflict rows above cover positions where an owed floor flag
# would change npm's operands or be read as a value instead of an option.
for inert_case in \
  "npm install left-pad@1.3.0 --ignore-scripts=false|npm install --ignore-scripts left-pad@1.3.0 --ignore-scripts=false --ignore-scripts" \
  "npm install left-pad@1.3.0 --no-ignore-scripts|npm install --ignore-scripts left-pad@1.3.0 --no-ignore-scripts --ignore-scripts" \
  "npm install left-pad@1.3.0 --ignore-scripts false|npm install --ignore-scripts left-pad@1.3.0 --ignore-scripts false --ignore-scripts" \
  "npm install left-pad@1.3.0 --no-ignore|npm install --ignore-scripts left-pad@1.3.0 --no-ignore --ignore-scripts" \
  "npm install left-pad@1.3.0 -no-ignore-scripts|npm install --ignore-scripts left-pad@1.3.0 -no-ignore-scripts --ignore-scripts" \
  "npm install --ignore-scripts left-pad@1.3.0 --ign=false|npm install --ignore-scripts --ignore-scripts left-pad@1.3.0 --ign=false --ignore-scripts" \
  "npm install left-pad@1.3.0 && echo --ignore-scripts|npm install --ignore-scripts left-pad@1.3.0 --ignore-scripts && echo --ignore-scripts" \
  "X=--ignore-scripts npm install left-pad@1.3.0|X=--ignore-scripts npm install --ignore-scripts left-pad@1.3.0 --ignore-scripts" \
  "npm ci --ignore-scripts && npm install left-pad@1.3.0|npm ci --ignore-scripts && npm install --ignore-scripts left-pad@1.3.0 --ignore-scripts" \
  "npm install left-pad@1.3.0 --cache --ignore-scripts|npm install --ignore-scripts left-pad@1.3.0 --cache --ignore-scripts --ignore-scripts" \
  "npm install left-pad@1.3.0 \$FLAGS|npm install --ignore-scripts left-pad@1.3.0 \$FLAGS --ignore-scripts" \
  "npm install left-pad@1.3.0 --cache && echo ok|npm install --ignore-scripts left-pad@1.3.0 --ignore-scripts --cache && echo ok" \
  "npm ci \$(printf -- --)|npm ci --ignore-scripts \$(printf -- --) --ignore-scripts" \
  "npm install left-pad@1.3.0>install.log|npm install --ignore-scripts left-pad@1.3.0 --ignore-scripts>install.log --ignore-scripts" \
  "npm install left-pad@1.3.0 --ignore-scripts=false > log 2>&1|npm install --ignore-scripts left-pad@1.3.0 --ignore-scripts=false --ignore-scripts > log 2>&1" \
  "sh -c 'npm install left-pad@1.3.0 --ignore-scripts=false'|sh -c 'npm install --ignore-scripts left-pad@1.3.0 --ignore-scripts=false --ignore-scripts'" \
  'echo "$(npm install left-pad@1.3.0 --no-ignore-scripts)"|echo "$(npm install --ignore-scripts left-pad@1.3.0 --no-ignore-scripts --ignore-scripts)"' \
  "(npm install left-pad@1.3.0 --ignore-scripts=false) && echo ok|(npm install --ignore-scripts left-pad@1.3.0 --ignore-scripts=false --ignore-scripts) && echo ok" \
  $'npm install left-pad@1.3.0 --message "a\n--ignore-scripts"|npm install --ignore-scripts left-pad@1.3.0 --message "a\n--ignore-scripts" --ignore-scripts'
do
  inert_in="${inert_case%%|*}"
  inert_want="${inert_case#*|}"
  inert_out=$(run_hook_command "${tmp_root}/home-compound" "${tmp_root}/safe-compound" "${inert_in}")
  inert_got=$(hook_response_read rewrite "${inert_out}")
  [[ "${inert_got}" == "${inert_want}" ]] \
    || fail "the inert flag goes after the install's last argument, wherever --ignore-scripts appears otherwise: $(printf '%q' "${inert_in}") (got: $(printf '%q' "${inert_got}"))"
done
# An install whose own arguments already leave the option true runs as written,
# where the release left it as written too: it did wherever the text
# `--ignore-scripts` stood unquoted. Where it did not (a quoted flag,
# `--no-no-ignore-scripts`), the release rewrote it, and so does the floor.
for inert_case in \
  "npm install left-pad@1.3.0 \"--ignore-scripts\"|npm install --ignore-scripts left-pad@1.3.0 \"--ignore-scripts\" --ignore-scripts" \
  "npm install left-pad@1.3.0 --no-no-ignore-scripts|npm install --ignore-scripts left-pad@1.3.0 --no-no-ignore-scripts --ignore-scripts"
do
  inert_in="${inert_case%%|*}"
  inert_want="${inert_case#*|}"
  inert_out=$(run_hook_command "${tmp_root}/home-compound" "${tmp_root}/safe-compound" "${inert_in}")
  inert_got=$(hook_response_read rewrite "${inert_out}")
  [[ "${inert_got}" == "${inert_want}" ]] \
    || fail "an install already true that the release rewrote keeps the release's rewrite: $(printf '%q' "${inert_in}") (got: $(printf '%q' "${inert_got}"))"
done
for inert_in in \
  "npm install left-pad@1.3.0 --ignore-scripts" \
  "npm install left-pad@1.3.0 --ignore-scripts=true" \
  "npm install left-pad@1.3.0 --ignore-scripts true" \
  "npm install --ignore-scripts left-pad@1.3.0 --save" \
  "npm --ignore-scripts install left-pad@1.3.0" \
  "npm install left-pad@1.3.0 --message --ignore-scripts" \
  "npm install left-pad@1.3.0 --ignore-scripts && npm run build" \
  $'npm install left-pad@1.3.0 --ignore-scripts --message "a\nb"'
do
  inert_out=$(run_hook_command "${tmp_root}/home-compound" "${tmp_root}/safe-compound" "${inert_in}" quiet)
  hook_response_parse "${inert_out}" quiet || fail "an install that already carries the flag is not rewritten: $(printf '%q' "${inert_in}") (got: ${inert_out:0:200})"
done
# An install that asked for its scripts is made inert, and the override is
# recorded rather than silent.
asked_before=$(grep -c 'sets ignore-scripts false; safedeps put --ignore-scripts after it' "${tmp_root}/safe-compound/advisory.log" 2>/dev/null || true)
run_hook_command "${tmp_root}/home-compound" "${tmp_root}/safe-compound" "npm install left-pad@1.3.0 --ignore-scripts=false" >/dev/null
asked_after=$(grep -c 'sets ignore-scripts false; safedeps put --ignore-scripts after it' "${tmp_root}/safe-compound/advisory.log" 2>/dev/null || true)
(( ${asked_after:-0} > ${asked_before:-0} )) || fail "an install that asked for its scripts is recorded when the flag overrides it"
# An install whose flag nobody could read is recorded rather than reported
# inert in silence.
unverified_before=$(grep -c 'holds a word the shell decides at run time' "${tmp_root}/safe-compound/advisory.log" 2>/dev/null || true)
run_hook_command "${tmp_root}/home-compound" "${tmp_root}/safe-compound" 'npm ci $(printf -- --)' >/dev/null
unverified_after=$(grep -c 'holds a word the shell decides at run time' "${tmp_root}/safe-compound/advisory.log" 2>/dev/null || true)
(( ${unverified_after:-0} > ${unverified_before:-0} )) || fail "an install holding a run-time word is recorded as one whose flag nobody read"
# Which words the shell decides at run time is read from its expansions, step
# by step, not from a list of characters: the list knew `$`, backquotes and
# globs and not the tilde, so `HOME=--cache; npm install x ~` read `~` as
# written, put the flag after it alone, and the shell handed npm `--cache`
# there, which took the flag as its value. One row per step: brace, tilde (at a
# word's start, after `=`, after `:`, and zsh's `=cmd`), parameter, command,
# arithmetic, process substitution and pathname, each with the flag after the
# verb and after the last argument, and recorded. The same characters inside
# quotes expand nothing (a `$` in double quotes does), and those installs are
# read as written.
for inert_in in \
  'HOME=--cache; npm install left-pad@1.3.0 ~' \
  'OLDPWD=--cache; npm install left-pad@1.3.0 ~-' \
  'npm install left-pad@1.3.0 ~+' \
  'npm install left-pad@1.3.0 ~root' \
  'npm install left-pad@1.3.0 --message a=~' \
  'npm install left-pad@1.3.0 --message a=x:~' \
  "npm install left-pad@1.3.0 --message a='x':~" \
  'npm install left-pad@1.3.0 {x,--cache}' \
  'npm install left-pad@1.3.0 --message {1..2}' \
  'npm install left-pad@1.3.0 --message =npm' \
  'npm install left-pad@1.3.0 "$FLAGS"' \
  'npm install left-pad@1.3.0 `printf -- --cache`' \
  'npm install left-pad@1.3.0 --message $((1))' \
  'npm install left-pad@1.3.0 --message <(true)' \
  'npm install left-pad@1.3.0 --c?che' \
  'npm install left-pad@1.3.0 --[c]ache' \
  'npm install left-pad@1.3.0 {--cache,}' \
  'hash -d c=--cache; npm install left-pad@1.3.0 ~c' \
  'npm install left-pad@1.3.0 --message x~y' \
  'npm install left-pad@1.3.0 --message a^b' \
  'npm install left-pad@1.3.0 --message a#b' \
  'npm install left-pad@1.3.0 \~'
do
  inert_want="${inert_in/install /install --ignore-scripts }"" --ignore-scripts"
  unverified_before=$(grep -c 'holds a word the shell decides at run time' "${tmp_root}/safe-compound/advisory.log" 2>/dev/null || true)
  inert_out=$(run_hook_command "${tmp_root}/home-compound" "${tmp_root}/safe-compound" "${inert_in}")
  unverified_after=$(grep -c 'holds a word the shell decides at run time' "${tmp_root}/safe-compound/advisory.log" 2>/dev/null || true)
  inert_got=$(hook_response_read rewrite "${inert_out}")
  [[ "${inert_got}" == "${inert_want}" ]] \
    || fail "an install holding a word the shell expands gets the flag after the verb and after its last argument: $(printf '%q' "${inert_in}") (got: $(printf '%q' "${inert_got}"))"
  (( ${unverified_after:-0} > ${unverified_before:-0} )) \
    || fail "an install holding a word the shell expands is recorded as one whose flag nobody read: ${inert_in}"
done
for inert_in in \
  "npm install left-pad@1.3.0 --message '~ {a,b} (c) * ? [d] =e'" \
  'npm install left-pad@1.3.0 --message "~ {a,b} (c) * ? [d] =e"' \
  'npm install left-pad@1.3.0 --message a%b+c,d:e/f@g=h_i.j-k' \
  'npm install left-pad@1.3.0 > install.log 2>&1' \
  'npm install left-pad@1.3.0 # ~ {a,b} *'
do
  inert_want="${inert_in/install /install --ignore-scripts }"
  case "${inert_want}" in
    *' > '*) inert_want="${inert_want/ > / --ignore-scripts > }" ;;
    *' # '*) inert_want="${inert_want/ # / --ignore-scripts # }" ;;
    *) inert_want+=" --ignore-scripts" ;;
  esac
  unverified_before=$(grep -c 'holds a word the shell decides at run time' "${tmp_root}/safe-compound/advisory.log" 2>/dev/null || true)
  inert_out=$(run_hook_command "${tmp_root}/home-compound" "${tmp_root}/safe-compound" "${inert_in}")
  unverified_after=$(grep -c 'holds a word the shell decides at run time' "${tmp_root}/safe-compound/advisory.log" 2>/dev/null || true)
  inert_got=$(hook_response_read rewrite "${inert_out}")
  [[ "${inert_got}" == "${inert_want}" ]] \
    || fail "an install whose words the shell leaves as written is read, and gets the flag after the verb and after its last argument: $(printf '%q' "${inert_in}") (got: $(printf '%q' "${inert_got}"))"
  (( ${unverified_after:-0} == ${unverified_before:-0} )) \
    || fail "an install whose words the shell leaves as written is not recorded as unread: ${inert_in}"
done
# The rows above are judged by the hook; this is what bash itself makes of the
# words, with an echo in place of npm and a file named `--cache` where a glob
# can find it. Each one hands npm `--cache`, which the text never shows. (zsh's
# `~c` after `hash -d c=--cache` and `(--cache|zz)` do the same in zsh 5.9,
# measured the same way; the batteries do not require zsh.)
echo_dir=$(mktemp -d "${tmp_root}/echo.XXXXXX")
: > "${echo_dir}/--cache"
for echo_form in \
  'HOME=--cache; npm install x ~' \
  'OLDPWD=--cache; npm install x ~-' \
  'npm install x {--cache,}' \
  $'shopt -s extglob\nnpm install x @(--cache)' \
  'npm install x --cach?'
do
  echo_argv=$(cd "${echo_dir}" && bash -c "npm() { printf '%s\\n' \"\$@\"; }; ${echo_form}" 2>&1) || true
  grep -qx -- '--cache' <<< "${echo_argv}" \
    || fail "bash hands npm a word the text does not show: $(printf '%q' "${echo_form}") (argv: $(paste -sd' ' - <<< "${echo_argv}"))"
done
# An install whose flag nobody read says so in the meta, so the post hook adds
# the warning that safedeps did not read all of the command it wrote.
dyn_safe=$(mktemp -d "${tmp_root}/safe-dyn.XXXXXX")
SAFEDEPS_HOME="${dyn_safe}" lib/ledger/ledger.sh approve npm left-pad 1.3.0 1.3.0 smoke >/dev/null
run_hook_command "${tmp_root}/home-dyn" "${dyn_safe}" 'HOME=--cache; npm install left-pad@1.3.0 ~' >/dev/null
dyn_sid=$(jq -r '.snapshot_id' "${dyn_safe}/pending/"*.json)
jq -e '.ignore_scripts_injected == true and .ignore_scripts_unread == true' "${dyn_safe}/snapshots/${dyn_sid}_meta.json" >/dev/null \
  || fail "an install whose flag nobody read is recorded with the unread warning"
pass "a word the shell expands at any of its steps makes the install unread and recorded, and quoted text does not"
# Asking npm where an install lands puts the ask's own flags after the
# install's words. After a trailing `--cache` npm took the first as the cache
# directory and created it in the project; npm is not asked then.
run_hook_command "${tmp_root}/home-compound" "${tmp_root}/safe-compound" "npm install left-pad@1.3.0 --cache" >/dev/null
[[ -z "$(find "${project_dir}" -maxdepth 1 -name '-*' -print -quit)" ]] \
  || fail "asking npm about an install with a trailing value option makes nothing in the project ($(find "${project_dir}" -maxdepth 1 -name '-*' | paste -sd, -))"
grep -q "the install's last option takes the next word as its value" "${tmp_root}/safe-compound/advisory.log" \
  || fail "an install npm is not asked about records why"
# For a call that names no tool_use_id (these payloads name none), the
# PostToolUse hook finds the pending state by a key with the flag stripped
# from the command it receives, which is the rewritten one. The flag can now
# follow one the command already carried, and a strip that took the blank
# between them with the first left the second, so the keys differed: the post
# hook found no pending state and the verified install was never rebuilt. A
# strip that listed the bytes allowed after the flag missed `>` and `<`, so
# `x>log` keyed apart from `x --ignore-scripts>log`, and an unapproved lockfile
# was flagged but not rolled back.
core_smoke_pending

pass "the inert flag is read from each install's own arguments and goes where npm reads it last; one already true is left as written"

# Reuse the release-floor relation with the previous row expectation as a
# second floor. It proves both that only flags were inserted into the input
# and that every flag the old expectation contained is still present. The
# normal run_hook_command check still uses the measured 7d66f8c corpus.
assert_script_payload_additions() {
  local command="$1" previous="$2" out="$3" safe="$4" payload got corpus
  hook_response_parse "${out}" decision || fail "script-payload response: ${command}"
  [[ "${HOOK_DECISION}" == allow && "${HOOK_HAS_REWRITE}" == true ]] \
    || fail "a script-payload row allows with a rewrite: ${command}"
  got="${HOOK_REWRITE}"
  payload=$(jq -nc --arg command "${command}" '{tool_input:{command:$command}}')
  corpus=$(mktemp "${tmp_root}/previous-rewrite.XXXXXX")
  jq -nc --arg command "${command}" --arg previous "${previous}" \
    '[{command:$command,release:$previous}]' > "${corpus}"
  RELEASE_FLOOR_CORPUS="${corpus}" release_floor_check "${payload}" "${got}" "${safe}" "${tmp_root}" \
    || fail "the script-payload rewrite only adds flags to the previous expectation: ${command}"
  release_floor_settle
}

# Native payload reading adds flags inside scripts that the Bash rewrite
# left to its floor. Keep both expectations: the old one is the insertion
# floor, and the native one pins the measured bytes. The unread record stays.
# The cat heredoc bodies piped to wc are covered by the explicit
# floor-outside-command conflict rows above, not by this rewrite loop.
unread_case_in=(
  'npm install left-pad@1.3.0; sh -c "echo $(date); npm install left-pad@1.3.0"'
  'npm install left-pad@1.3.0; sh -c "echo \"hi\"; npm install left-pad@1.3.0"'
  'true; sh -c "npm install left-pad@1.3.0 \"--loglevel=warn\""'
  'sh -c "npm install left-pad@1.3.0 \"--loglevel=warn\""'
  'eval "npm install left-pad@1.3.0 \"--loglevel=warn\""'
  'true; bash -lc "npm install left-pad@1.3.0 `printf -- --loglevel=warn`"'
  'true; zsh -c "npm install left-pad@1.3.0 --fetch-retries $((1))"'
  "true; ksh -c 'npm install left-pad@1.3.0'"
  'npm install left-pad@1.3.0; sh -c "npm install\"\" left-pad@1.3.0"'
  $'npm i left-pad@1.3.0 && sh <<E | tee log\nnpm ci&&true\nE'
  'true; sh -c "npm install\"\" left-pad@1.3.0"'
  'npm i left-pad@1.3.0 --ignore-scripts=true; sh -c "cd \"d\" && npm ci"'
  'npm i left-pad@1.3.0 --ignore-scripts && ksh -c "npm ci"'
)
unread_case_want=(
  'npm install --ignore-scripts left-pad@1.3.0 --ignore-scripts; sh -c "echo $(date); npm install --ignore-scripts left-pad@1.3.0"'
  'npm install --ignore-scripts left-pad@1.3.0 --ignore-scripts; sh -c "echo \"hi\"; npm install --ignore-scripts left-pad@1.3.0"'
  'true; sh -c "npm install --ignore-scripts left-pad@1.3.0 \"--loglevel=warn\""'
  'sh -c "npm install --ignore-scripts left-pad@1.3.0 \"--loglevel=warn\""'
  'eval "npm install --ignore-scripts left-pad@1.3.0 \"--loglevel=warn\""'
  'true; bash -lc "npm install --ignore-scripts left-pad@1.3.0 `printf -- --loglevel=warn`"'
  'true; zsh -c "npm install --ignore-scripts left-pad@1.3.0 --fetch-retries $((1))"'
  "true; ksh -c 'npm install --ignore-scripts left-pad@1.3.0'"
  'npm install --ignore-scripts left-pad@1.3.0 --ignore-scripts; sh -c "npm install\"\" left-pad@1.3.0"'
  $'npm i --ignore-scripts left-pad@1.3.0 --ignore-scripts && sh <<E | tee log\nnpm ci&&true\nE'
  'true; sh -c "npm install\"\" left-pad@1.3.0"'
  'npm i left-pad@1.3.0 --ignore-scripts=true; sh -c "cd \"d\" && npm ci"'
  'npm i left-pad@1.3.0 --ignore-scripts && ksh -c "npm ci"'
)
unread_case_native=(
  'npm install --ignore-scripts left-pad@1.3.0 --ignore-scripts; sh -c "echo $(date); npm install --ignore-scripts left-pad@1.3.0 --ignore-scripts"'
  'npm install --ignore-scripts left-pad@1.3.0 --ignore-scripts; sh -c "echo \"hi\"; npm install --ignore-scripts left-pad@1.3.0 --ignore-scripts"'
  'true; sh -c "npm install --ignore-scripts left-pad@1.3.0 \"--loglevel=warn\" --ignore-scripts"'
  'sh -c "npm install --ignore-scripts left-pad@1.3.0 \"--loglevel=warn\" --ignore-scripts"'
  'eval "npm install --ignore-scripts left-pad@1.3.0 \"--loglevel=warn\" --ignore-scripts"'
  'true; bash -lc "npm install --ignore-scripts left-pad@1.3.0 `printf -- --loglevel=warn` --ignore-scripts"'
  'true; zsh -c "npm install --ignore-scripts left-pad@1.3.0 --fetch-retries $((1)) --ignore-scripts"'
  "true; ksh -c 'npm install --ignore-scripts left-pad@1.3.0 --ignore-scripts'"
  'npm install --ignore-scripts left-pad@1.3.0 --ignore-scripts; sh -c "npm install\"\" left-pad@1.3.0 --ignore-scripts"'
  $'npm i --ignore-scripts left-pad@1.3.0 --ignore-scripts && sh <<E | tee log\nnpm ci&&true\nE'
  'true; sh -c "npm install\"\" left-pad@1.3.0 --ignore-scripts"'
  'npm i left-pad@1.3.0 --ignore-scripts=true; sh -c "cd \"d\" && npm ci --ignore-scripts"'
  'npm i left-pad@1.3.0 --ignore-scripts && ksh -c "npm ci --ignore-scripts"'
)
for unread_i in "${!unread_case_in[@]}"; do
  inert_in="${unread_case_in[${unread_i}]}"
  inert_want="${unread_case_native[${unread_i}]}"
  unread_safe=$(mktemp -d "${tmp_root}/safe-unread.XXXXXX")
  SAFEDEPS_HOME="${unread_safe}" lib/ledger/ledger.sh approve npm left-pad 1.3.0 1.3.0 smoke >/dev/null
  inert_out=$(run_hook_command "${tmp_root}/home-unread" "${unread_safe}" "${inert_in}")
  inert_got=$(hook_response_read rewrite "${inert_out}")
  [[ "${inert_got}" == "${inert_want}" ]] \
    || fail "a script-payload install gets the measured native rewrite: $(printf '%q' "${inert_in}") (got: $(printf '%q' "${inert_got}"); ${inert_out:0:200})"
  assert_script_payload_additions "${inert_in}" "${unread_case_want[${unread_i}]}" "${inert_out}" "${unread_safe}"
  grep -q 'safedeps did not read as a command holds an npm install verb' "${unread_safe}/advisory.log" 2>/dev/null \
    || fail "an install in text the rewrite cannot read is recorded as one whose flag nobody read: $(printf '%q' "${inert_in}")"
  unread_sid=$(jq -r '.snapshot_id' "${unread_safe}/pending/"*.json 2>/dev/null) || unread_sid=""
  jq -e '.ignore_scripts_injected == true and .ignore_scripts_unread == true' "${unread_safe}/snapshots/${unread_sid}_meta.json" >/dev/null 2>&1 \
    || fail "an install in text the rewrite cannot read is recorded with the unread warning: $(printf '%q' "${inert_in}")"
done
# This piped heredoc still has no rewrite and remains a recorded downgrade.
# Its stdout must be empty; the advisory and false meta facts are mandatory.
settled_unread_bad=""
for inert_in in \
  $'npm i left-pad@1.3.0 --ignore-scripts && sh <<E | tee log\nnpm ci&&true\nE'
do
  settled_safe=$(mktemp -d "${tmp_root}/safe-settled-unread.XXXXXX")
  SAFEDEPS_HOME="${settled_safe}" lib/ledger/ledger.sh approve npm left-pad 1.3.0 1.3.0 smoke >/dev/null
  inert_out=$(run_hook_command "${tmp_root}/home-settled-unread" "${settled_safe}" "${inert_in}" quiet)
  hook_response_parse "${inert_out}" quiet \
    || settled_unread_bad+=" [a rewrite: $(printf '%q' "${inert_in}") (got: ${inert_out:0:200})]"
  grep -q 'could not make every npm install in this command inert' "${settled_safe}/advisory.log" 2>/dev/null \
    || settled_unread_bad+=" [no downgrade line in advisory.log: $(printf '%q' "${inert_in}")]"
  settled_sid=$(jq -r '.snapshot_id' "${settled_safe}/pending/"*.json 2>/dev/null) || settled_sid=""
  jq -e '.record == 2 and .ignore_scripts_injected == false and .ignore_scripts_unread == false and (has("updated_command") | not)' "${settled_safe}/snapshots/${settled_sid}_meta.json" >/dev/null 2>&1 \
    || settled_unread_bad+=" [the meta does not report nothing inert: $(printf '%q' "${inert_in}")]"
done
[[ -z "${settled_unread_bad}" ]] \
  || fail "an install already true beside one no verb placement reaches gets no rewrite and is a recorded downgrade:${settled_unread_bad}"
pass "script payload additions preserve both rewrite floors and unread records; the piped heredoc remains a recorded downgrade"

# The record does not depend on the kind of text. An npm install the rewrite
# did not read, beside one it flagged, is recorded as one whose flag nobody
# read and changes nothing in the rewrite, whatever kept the reading from it:
# a shell option cluster its head does not take, a script word glued to more
# quoting, a glued word whose rest turns the flag off, an unquoted script
# word, a heredoc body handed to a shell with no pipe, and a verb an operator
# follows at once in a script word the rewrite cannot read, where a flag goes
# only after a blank, as v2.17.2 put it. Each of these ran its `npm ci`
# with no flag and no record. At the top level the rewrite now reads a verb an
# operator follows (`npm ci;true` gets its flag, SAFEDEPS_G_END), so that row
# carries it inside such a script. The third and fourth script words keep the flags the
# rewrite placed before (one inside the quoted segment, one on the outer
# statement), and neither reaches npm as true.
# scripts/measure/inert-record-invariant.sh holds every form of its corpus to
# the same rule.
left_case_in=(
  'npm i left-pad@1.3.0 && sh -ce "npm ci \"x\""'
  "npm i left-pad@1.3.0 && sh -c 'npm 'ci"
  'npm i left-pad@1.3.0 && sh -c "npm ci "--ignore-scripts=false'
  $'npm i left-pad@1.3.0 && sh <<E\nnpm ci\nE'
  'npm i left-pad@1.3.0 && sh -c "cd \"d\" && npm ci;true"'
)
left_case_tail=(
  ' && sh -ce "npm ci \"x\""'
  " && sh -c 'npm 'ci"
  ' && sh -c "npm ci --ignore-scripts "--ignore-scripts=false'
  $' && sh <<E\nnpm ci\nE'
  ' && sh -c "cd \"d\" && npm ci;true"'
)
left_case_native=(
  'npm i --ignore-scripts left-pad@1.3.0 --ignore-scripts && sh -ce "npm ci \"x\" --ignore-scripts"'
  "npm i --ignore-scripts left-pad@1.3.0 --ignore-scripts && sh -c 'npm 'ci"
  'npm i --ignore-scripts left-pad@1.3.0 --ignore-scripts && sh -c "npm ci --ignore-scripts "--ignore-scripts=false'
  $'npm i --ignore-scripts left-pad@1.3.0 --ignore-scripts && sh <<E\nnpm ci\nE'
  'npm i --ignore-scripts left-pad@1.3.0 --ignore-scripts && sh -c "cd \"d\" && npm ci --ignore-scripts;true"'
)
left_bad=""
for left_i in "${!left_case_in[@]}"; do
  inert_in="${left_case_in[${left_i}]}"
  left_safe=$(mktemp -d "${tmp_root}/safe-left-unread.XXXXXX")
  SAFEDEPS_HOME="${left_safe}" lib/ledger/ledger.sh approve npm left-pad 1.3.0 1.3.0 smoke >/dev/null
  inert_out=$(run_hook_command "${tmp_root}/home-left-unread" "${left_safe}" "${inert_in}")
  inert_got=$(hook_response_read rewrite "${inert_out}")
  assert_script_payload_additions "${inert_in}" "npm i --ignore-scripts left-pad@1.3.0 --ignore-scripts${left_case_tail[${left_i}]}" "${inert_out}" "${left_safe}"
  [[ "${inert_got}" == "${left_case_native[${left_i}]}" ]] \
    || left_bad+=" [the rewrite changed: $(printf '%q' "${inert_in}") (got: $(printf '%q' "${inert_got}"); ${inert_out:0:160})]"
  grep -q 'safedeps did not read as a command holds an npm install verb' "${left_safe}/advisory.log" 2>/dev/null \
    || left_bad+=" [no unread line in advisory.log: $(printf '%q' "${inert_in}")]"
  left_sid=$(jq -r '.snapshot_id' "${left_safe}/pending/"*.json 2>/dev/null) || left_sid=""
  jq -e '.ignore_scripts_injected == true and .ignore_scripts_unread == true' "${left_safe}/snapshots/${left_sid}_meta.json" >/dev/null 2>&1 \
    || left_bad+=" [the meta has no unread warning: $(printf '%q' "${inert_in}")]"
done
[[ -z "${left_bad}" ]] \
  || fail "an npm install the rewrite did not read beside one it flagged is recorded as unread, and the rewrite is unchanged:${left_bad}"
pass "an npm install the rewrite did not read is recorded as unread, whatever kind of text kept the reading from it (${#left_case_in[@]} kinds)"

# The floor holds where no place can be read. Each of these holds an install
# in front of a double-quoted word with an escape or a substitution in it after
# `eval` or `sh -c`, which the rewrite reads as a script it cannot read. They
# got no rewrite at all, and `npm ci eval "\npm"` ran its postinstall where the
# release's rewrite ran none (validator round 4: six forms, and two from its
# seeded fuzz). Each now keeps the release's rewrite, the flag at the end,
# with the flags read for the visible install. The release floor check in
# run_hook_command judges each against the release's own rewrite.
#
# Each is one npm install whose operands spell `eval` or `sh -c`: the shell
# runs no eval and no sh there. Each keeps its rewrite, the flags read for it
# and the release's end flag. It is recorded where a rule input applies: a
# command word the shell computes in a script the command hands on (`$(echo)
# npm`), or a word the shell decides at run time (`"$HOME"`). The others were
# recorded while the record listed text that names npm after an `eval` or a
# `sh -c`; with no npm install verb left in text the rewrite did not read as a
# command, they are not, and npm reads the flag in every one.
release_only_safe=$(mktemp -d "${tmp_root}/safe-release-only.XXXXXX")
SAFEDEPS_HOME="${release_only_safe}" lib/ledger/ledger.sh approve npm left-pad 1.3.0 1.3.0 smoke >/dev/null
for row in \
  '0|npm ci eval "\npm"' \
  '0|npm install left-pad@1.3.0 eval "a\b npm"' \
  '0|npm install left-pad@1.3.0 eval "npm\ x"' \
  '1|npm install left-pad@1.3.0 eval "$(echo) npm"' \
  '0|npm install left-pad@1.3.0 sh -c "\npm"' \
  '0|npm install left-pad@1.3.0 --userconfig=eval "x\y npm"' \
  '1|npm ci left-pad@1.3.0 sh -c "x\y npm" false "$HOME"'
do
  release_only_want="${row%%|*}" inert_in="${row#*|}"
  rm -rf "${release_only_safe}/pending"
  inert_out=$(run_hook_command "${tmp_root}/home-release-only" "${release_only_safe}" "${inert_in}")
  release_only_got=$(hook_response_read rewrite "${inert_out}")
  [[ "${release_only_got}" == *" --ignore-scripts" && "${release_only_got}" != "${inert_in}" ]] \
    || fail "an npm install whose operands spell eval or sh -c keeps its rewrite: $(printf '%q' "${inert_in}") (got: ${inert_out:0:240})"
  release_only_sid=$(jq -r '.snapshot_id' "${release_only_safe}/pending/"*.json 2>/dev/null) || release_only_sid=""
  release_only_unread=$(jq -r '.ignore_scripts_unread' "${release_only_safe}/snapshots/${release_only_sid}_meta.json" 2>/dev/null) || release_only_unread=""
  if [[ "${release_only_want}" == 1 ]]; then
    [[ "${release_only_unread}" == true ]] \
      || fail "an npm install with a computed or run-time word is recorded with the unread warning: $(printf '%q' "${inert_in}") (meta: ${release_only_unread:-none})"
  else
    [[ "${release_only_unread}" == false ]] \
      || fail "an npm install whose operands spell eval or sh -c and npm, with nothing the shell decides, is not recorded as unread: $(printf '%q' "${inert_in}") (meta: ${release_only_unread:-none})"
  fi
done
pass "an npm install whose operands spell eval or sh -c keeps its rewrite, and is recorded only where a word is computed or decided at run time"

# The rewrite changes the text every shell reads, so it is made only where
# bash, zsh and dash agree where the npm installs are. In I2 and I3 the
# apostrophe in "${x:-'}" opens a quote for bash and is a character for zsh and
# dash, so zsh runs an `npm ci` that bash reads as quoted text. Before the
# readings were shells, the rewrite followed bash alone: zsh ran that install
# with no flag and no downgrade record while the meta said inert (verdict
# bogeuli-20261001-234308). Now the command is UNDECIDED, with its own reason,
# and the meta never says inert.
mkdir -p "${project_dir}/sub"
for readings_case in \
  $'npm install left-pad@1.3.0\necho "${x:-\'}"\ncd sub && npm ci\necho "\'}"' \
  $'npm ci\necho "${x:-\'}"\ncd sub && npm ci\necho "\'}"'
do
  readings_safe=$(mktemp -d "${tmp_root}/safe-readings.XXXXXX")
  SAFEDEPS_HOME="${readings_safe}" lib/ledger/ledger.sh approve npm left-pad 1.3.0 1.3.0 smoke >/dev/null
  readings_out=$(run_hook_command "${tmp_root}/home-readings" "${readings_safe}" "${readings_case}")
  [[ "$(hook_response_read decision "${readings_out}")" == deny ]] \
    && hook_response_read reason "${readings_out}" | grep -q 'UNDECIDED.*read the npm installs in this command in different places' \
    || fail "readings that put the npm installs in different places are UNDECIDED: $(printf '%q' "${readings_case}") (got: ${readings_out:0:200})"
  ! grep -qs '"ignore_scripts_injected": true' "${readings_safe}/snapshots/"*_meta.json \
    || fail "the meta never says inert when nothing was injected: $(printf '%q' "${readings_case}")"
  [[ -z "$(ls "${readings_safe}/pending" 2>/dev/null)" ]] \
    || fail "an UNDECIDED command leaves no pending state: $(printf '%q' "${readings_case}")"
done
pass "a rewrite the readings disagree on is UNDECIDED with its own reason, and the meta never says inert"

# Where they agree, the rewrite is checked by running it. A stub stands in for
# npm and prints its arguments (the one thing run here is that stub), and the
# rewritten command runs under bash, zsh and dash: every npm install any of them
# runs must carry the flag, and the meta must say inert. K2 is the effect-gate
# grid's M6, where an install in `sh -c` ran its lifecycle scripts.
readings_stub="${tmp_root}/readings-stub"
mkdir -p "${readings_stub}"
printf '#!/bin/sh\nprintf "NPM: %%s\\n" "$*"\n' > "${readings_stub}/npm"
chmod +x "${readings_stub}/npm"
readings_shells=()
for readings_shell in /bin/bash /bin/zsh /bin/dash /usr/bin/dash; do
  [[ -x "${readings_shell}" ]] && readings_shells+=("${readings_shell}")
done
for readings_case in \
  'npm install left-pad@1.3.0; ((count++)); echo "$((count+1))"' \
  "npm install left-pad@1.3.0; sh -c 'cd sub && npm install left-pad@1.3.0'" \
  $'npm ci\necho "${x:-hi}"' \
  'npm ci # then npm i later' \
  $'i=0; ((i++)); npm ci && echo "${x:-\'}" && echo "\'}"' \
  'for ((i=0;i<1;i++)); do npm install left-pad@1.3.0; done'
do
  readings_safe=$(mktemp -d "${tmp_root}/safe-readings.XXXXXX")
  SAFEDEPS_HOME="${readings_safe}" lib/ledger/ledger.sh approve npm left-pad 1.3.0 1.3.0 smoke >/dev/null
  readings_out=$(run_hook_command "${tmp_root}/home-readings" "${readings_safe}" "${readings_case}")
  readings_cmd=$(hook_response_read rewrite "${readings_out}")
  [[ -n "${readings_cmd}" ]] || fail "readings that agree get the rewrite: $(printf '%q' "${readings_case}") (got: ${readings_out:0:200})"
  grep -qs '"ignore_scripts_injected": true' "${readings_safe}/snapshots/"*_meta.json \
    || fail "the meta says inert when the rewrite was injected: $(printf '%q' "${readings_case}")"
  # A shell that refuses the command runs none of it (dash has no `for ((`),
  # so each shell is held only to the installs it runs, and one must run them.
  readings_any=false
  for readings_shell in "${readings_shells[@]}"; do
    readings_ran=$(cd "${project_dir}" && PATH="${readings_stub}:${PATH}" "${readings_shell}" -c "${readings_cmd}" 2>/dev/null | grep '^NPM: ' || true)
    [[ -n "${readings_ran}" ]] || continue
    readings_any=true
    ! grep -vq -- '--ignore-scripts' <<< "${readings_ran}" \
      || fail "every npm install ${readings_shell} runs carries the flag: $(printf '%q' "${readings_cmd}") ran ${readings_ran}"
  done
  [[ "${readings_any}" == true ]] || fail "the stub ran under some shell: $(printf '%q' "${readings_cmd}")"
done
pass "a rewrite the readings agree on puts the flag on every npm install bash, zsh and dash run (${#readings_shells[@]} shells)"

# Finding #3: an `--prefix <dir>` install must be snapshotted/effect-gated against
# the OVERRIDE dir, not cwd. The pending state's project_dir must be the prefix dir.
prefix_safe="${tmp_root}/safe-prefix"
prefix_proj=$(cd "$(mktemp -d "${tmp_root}/prefix-target.XXXXXX")" && pwd -P)
mkdir -p "${prefix_safe}"
printf '{"dependencies":{}}\n' > "${prefix_proj}/package.json"
SAFEDEPS_HOME="${prefix_safe}" lib/ledger/ledger.sh approve npm left-pad 1.3.0 1.3.0 smoke >/dev/null
jq -nc --arg c "npm install --prefix ${prefix_proj} left-pad@1.3.0" --arg cwd "${project_dir}" \
  '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}' |
  HOME="${tmp_root}/home-prefix" SAFEDEPS_HOME="${prefix_safe}" hook_response_capture "${tmp_root}/prefix-response" scripts/safedeps-hook-entry.sh pre >/dev/null
prefix_pending_dir=$(jq -r '.project_dir' "${prefix_safe}/pending/"*.json | head -1)
[[ "${prefix_pending_dir}" == "${prefix_proj}" ]] || fail "--prefix install snapshots the override dir, not cwd (got: ${prefix_pending_dir}, want ${prefix_proj})"
pass "--prefix install targets the override dir for snapshot/effect-gate (finding #3)"

# Regression: `npx <tool> <args>` runs an already-installed binary. Arguments to
# the tool (e.g. an email) must NOT be misread as a pkg@spec install and denied.
npx_runner_output=$(
  run_hook_command "${tmp_root}/home-npx-run" "${tmp_root}/safe-npx-run" "npx wrangler secret put EXAMPLE_SHARED_SECRET --name example-gateway ops@example.test" quiet
)
hook_response_parse "${npx_runner_output}" quiet || fail "hook allows npx tool run with @-bearing args"
pass "hook allows npx tool run with @-bearing args"

# Regression: a genuine install chained with an npx tool run must STILL be gated
# on the real package — and must not be polluted by the npx arg email.
mixed_output=$(
  run_hook_command "${tmp_root}/home-mixed" "${tmp_root}/safe-mixed" "npm install evil-pkg@9.9.9 && npx wrangler secret put X ops@example.test"
)
[[ "$(hook_response_read decision "${mixed_output}")" == "deny" ]] || fail "hook gates real install chained with npx run"
reason=$(hook_response_read reason "${mixed_output}")
grep -q 'evil-pkg@9.9.9' <<< "${reason}" || fail "deny reason names the real package"
[[ "${reason}" != *"ops@example.test"* ]] || fail "deny reason must not name the email arg"
pass "hook gates real install chained with npx run (email not polluted)"

# Regression: a pkg@version that merely APPEARS in a non-install segment (an echo /
# log line) must not be attached to a real install elsewhere in the command. Specs
# are extracted only from segments that are themselves install commands.
echo_mention_output=$(
  run_hook_command "${tmp_root}/home-echo-mention" "${tmp_root}/safe-echo-mention" 'npm install evil-pkg@9.9.9; echo "bumped other-pkg@2.0.0"'
)
[[ "$(hook_response_read decision "${echo_mention_output}")" == "deny" ]] || fail "hook still gates the real install when another segment merely echoes a pkg@version"
echo_mention_reason=$(hook_response_read reason "${echo_mention_output}")
grep -q 'evil-pkg@9.9.9' <<< "${echo_mention_reason}" || fail "deny reason names the real install spec"
[[ "${echo_mention_reason}" != *"other-pkg@2.0.0"* ]] || fail "deny reason must not name a pkg@version that only appears in an echo segment"
pass "hook extracts specs only from install segments, not from echoed pkg@version mentions"

# Regression: an echoed pkg@version next to a BARE install (no operand) must not be
# read as installing that package — the bare install is allowed, not denied.
bare_mention_output=$(
  run_hook_command "${tmp_root}/home-bare-mention" "${tmp_root}/safe-bare-mention" 'echo "bumped left-pad@1.0.0 -> 1.0.1"; npm install'
)
[[ "$(hook_response_read decision "${bare_mention_output}")" != "deny" ]] || fail "bare npm install must not be denied because of a pkg@version in an echo segment"
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
  fp_output=$(run_hook_command "${tmp_root}/home-false-positive" "${false_positive_safe}" "${fp_cmd}" quiet)
  hook_response_parse "${fp_output}" quiet || fail "hook ignores non-install text command: ${fp_cmd}"
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
  hidden_safe=$(mktemp -d "${tmp_root}/safe-hidden.XXXXXX")
  hidden_output=$(run_hook_command "${tmp_root}/home-hidden" "${hidden_safe}" "${hidden_cmd}")
  [[ "$(hook_response_read decision "${hidden_output}")" == "deny" ]] || fail "hook denies hidden install command: ${hidden_cmd}"
  for hidden_state_dir in pending snapshots; do
    if [[ -e "${hidden_safe}/${hidden_state_dir}" ]]; then
      [[ -d "${hidden_safe}/${hidden_state_dir}" && -z "$(find "${hidden_safe}/${hidden_state_dir}" -mindepth 1 -print)" ]] \
        || fail "a denied hidden install leaves no pending record, snapshot or meta (${hidden_state_dir}): ${hidden_cmd}"
    fi
  done
done
pass "hook denies hidden install indirection without pending records, snapshots or meta"

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
  # A manager's name in another case runs the manager on a macOS volume, and
  # the recognizers read it ignoring case. The word reader matched case, so
  # these were installs with no spec to check (safedeps_manager_name).
  "PIP install requests==2.31.0"
  "Pip3 install requests==2.31.0"
  "python3 -m PIP install requests==2.31.0"
  "PYTHON -m pip install requests==2.31.0"
  "/usr/local/bin/PIP install requests==2.31.0"
  "TIME pip install requests==2.31.0"
  "Cargo add serde --vers 1.0.0"
  "NPM install evil@1.2.3"
  "X=1 Npm install evil@1.2.3"
  "Npx evil@1.2.3"
  "Gem install rails -v 7.1.0"
  "GO install example.com/evil@v1.2.3"
)
for bypass_cmd in "${bypass_cases[@]}"; do
  bypass_output=$(run_hook_command "${tmp_root}/home-bypass" "${tmp_root}/safe-bypass" "${bypass_cmd}")
  [[ "$(hook_response_read decision "${bypass_output}")" == "deny" ]] || fail "hook denies bypass: ${bypass_cmd}"
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
    HOME="${fc_home}" SAFEDEPS_HOME="${fc_safe}" SAFEDEPS_LOCK_MAX_ATTEMPTS=2 hook_response_capture "${tmp_root}/lock-response" scripts/safedeps-hook-entry.sh pre
)
rmdir "${fc_safe}/state.lock" 2>/dev/null || true
[[ "$(hook_response_read decision "${fc_deny}")" == "deny" ]] || fail "pre-guard fails closed (deny) when the state lock is unavailable for an install"
grep -q 'pre-guard DENY' "${fc_safe}/advisory.log" || fail "pre-guard logs the fail-closed deny to advisory.log"
pass "pre-guard fails closed on lock contention (observable)"

# Retired dependency-fault rows at the native entry cutover:
# - jq missing: rust/src/jq.rs reads/writes JSON in-process; no jq subprocess.
# - SAFEDEPS_LEDGER_LIB missing: pre/install.rs calls ledger::check directly;
#   the core does not source the Bash ledger reader or read that override.
# Their unavailable-dependency contract is covered in hook-entry.sh by the
# real-core copy with its binary removed (explained deny), and the shim's
# non-executable/126/127 rows. A stale source has separate real-core rows:
# installs deny; benign calls allow and warn on stderr and in advisory.log.

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
  HOME="${tmp_root}/home-conc" SAFEDEPS_HOME="${conc_safe}" hook_response_capture "${tmp_root}/concurrent-response" scripts/safedeps-hook-entry.sh post >/dev/null || true
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
  HOME="${tmp_root}/home-conc" SAFEDEPS_HOME="${nolock_safe}" hook_response_capture "${tmp_root}/no-lock-response" scripts/safedeps-hook-entry.sh post >/dev/null || true
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
  HOME="${tmp_root}/home-backstop" SAFEDEPS_HOME="${backstop_safe}" hook_response_capture "${tmp_root}/backstop-response" scripts/safedeps-hook-entry.sh post >/dev/null || true
grep -q 'BACKSTOP clean' "${backstop_safe}/advisory.log" || fail "npm effect gate runs command-independently as a backstop with no pending state (finding #5)"
pass "npm effect gate runs command-independently as a backstop (finding #5)"

tamper_safe="${tmp_root}/safe-tamper"
tamper_home="${tmp_root}/home-tamper"
SAFEDEPS_HOME="${tamper_safe}" lib/ledger/ledger.sh approve npm ledger-tamper 1.0.0 1.0.0 smoke >/dev/null
tamper_pre=$(run_hook_command "${tamper_home}" "${tamper_safe}" "npm install ledger-tamper@1.0.0")
[[ "$(hook_response_read decision "${tamper_pre}")" == "allow" ]] || fail "tamper fixture pre hook allows approved install"
mkdir -p "${project_dir}/node_modules/ledger-tamper"
jq '.dependencies["ledger-tamper"]="1.0.0"' "${project_dir}/package.json" > "${project_dir}/package.json.tmp"
mv "${project_dir}/package.json.tmp" "${project_dir}/package.json"
cat > "${project_dir}/node_modules/ledger-tamper/package.json" <<'EOF'
{"name":"ledger-tamper","version":"1.0.0","scripts":{"postinstall":"node -e \"require('fs').writeFileSync(process.env.HOME + '/.safedeps/approved-specs/evil.json', '{}')\""}}
EOF
tamper_post=$(
  jq -nc --arg cwd "${project_dir}" '{tool_name:"Bash",tool_input:{command:"npm install ledger-tamper@1.0.0"},cwd:$cwd}' |
    HOME="${tamper_home}" SAFEDEPS_HOME="${tamper_safe}" hook_response_capture "${tmp_root}/tamper-response" scripts/safedeps-hook-entry.sh post
)
grep -q 'suspicious dependency change detected' < "${tamper_post}" || fail "post hook reorgs safedeps ledger tamper script"
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

release_floor_settle
pass "deleting flags the hook inserted gives the release's rewrite, for every command smoke lets run"

printf 'smoke passed\n'
