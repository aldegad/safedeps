#!/usr/bin/env bash
# safedeps: shell-consumer form battery.
#
# The command gate decides "is this an install?" by recognizing the syntactic
# carrier that hands text to an interpreter. That recognition is a closed
# enumeration, so it has a boundary. This battery pins the boundary from both
# sides: forms inside it must stay caught, forms outside it must stay outside
# ON PURPOSE, and forms that only LOOK like bypasses must stay identified as
# decoys so nobody spends a release "fixing" a command that never installs.
#
# Whichever side a form lands on, this file is where the claim is checked. The
# prose claim it protects lives in ARCHITECTURE.md ("Where each ecosystem's
# authority lives").
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

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-forms.XXXXXX")
cleanup() {
  rm -rf "${tmp_root}"
}
trap cleanup EXIT

project_dir="${tmp_root}/project"
mkdir -p "${project_dir}"
printf '{"dependencies":{}}\n' > "${project_dir}/package.json"

# Decision of the PreToolUse command gate for one command: deny | allow | pass.
# "pass" means the gate produced no decision at all — the command was not judged
# to be an install.
gate_decision() {
  local command="$1"
  local safe="${tmp_root}/safe-$$-${RANDOM}"
  local out
  mkdir -p "${safe}"
  out=$(jq -nc --arg c "${command}" --arg cwd "${project_dir}" \
    '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}' |
    HOME="${tmp_root}/home" SAFEDEPS_HOME="${safe}" scripts/safedeps-pre-guard.sh 2>/dev/null)
  if [[ -z "${out}" ]]; then
    printf 'pass'
  else
    jq -r '.hookSpecificOutput.permissionDecision // "pass"' <<< "${out}"
  fi
}

expect_deny() {
  local label="$1" command="$2" got
  got=$(gate_decision "${command}")
  [[ "${got}" == "deny" ]] || fail "command gate catches ${label} (got: ${got})"
}

expect_pass() {
  local label="$1" command="$2" got
  got=$(gate_decision "${command}")
  [[ "${got}" == "pass" ]] || fail "command gate leaves ${label} unjudged as documented (got: ${got})"
}

# --- 1. Carrier forms the command gate catches --------------------------------
# Regression against narrowing. Tightening the gate for false positives must not
# quietly shrink this set — that would be a trade, not a net gain.

expect_deny "sh -c with a double-quoted payload"      'sh -c "pip install evil==1.0.0"'
expect_deny "sh -c with a single-quoted payload"      "sh -c 'pip install evil==1.0.0'"
expect_deny "eval with a quoted payload"              'eval "pip install evil==1.0.0"'
expect_deny "a plain pipe to sh"                      "printf 'pip install evil==1.0.0' | sh"
expect_deny "a plain pipe to bash"                    "printf 'pip install evil==1.0.0' | bash"
expect_deny "a plain pipe to zsh"                     "printf 'pip install evil==1.0.0' | zsh"
expect_deny "a pipe to a flagged shell"               "printf 'pip install evil==1.0.0' | sh -s"
expect_deny "sh -c reached through env"               "env sh -c 'pip install evil==1.0.0'"
expect_deny "sh -c reached by absolute path"          "/bin/sh -c 'pip install evil==1.0.0'"
expect_deny "sh -c nested in a single-quoted sh -c"   "sh -c 'sh -c \"pip install evil==1.0.0\"'"
pass "command gate catches the enumerated shell carriers"

# The two sides of one pipe must agree on what counts as the same invocation.
# normalize_install_text already declares that a path-qualified or env-prefixed
# invocation is the bare one; it was applied to the install text and skipped on
# the consumer, so `| /bin/sh` and `| env sh` read as a different consumer than
# `| sh`. These four are that inconsistency, not four separate carriers.
expect_deny "a pipe to an absolute-path shell"        "printf 'pip install evil==1.0.0' | /bin/sh"
expect_deny "a pipe to an absolute-path bash"         "printf 'pip install evil==1.0.0' | /usr/bin/bash"
expect_deny "a pipe to env sh"                        "printf 'pip install evil==1.0.0' | env sh"
expect_deny "a pipe to env with an assignment"        "printf 'pip install evil==1.0.0' | env FOO=1 sh"
expect_deny "a pipe to command sh"                    "printf 'pip install evil==1.0.0' | command sh"
expect_deny "a wrapped pipe to an absolute-path shell" 'bash -c "printf '"'"'pip install evil==1.0.0'"'"' | /bin/sh"'
pass "pipe consumer is normalized like the producer already was"

# --- 2. Carrier forms the command gate does NOT catch -------------------------
# Deliberate. The gate recognizes carriers by enumeration, and the shell has
# unbounded ways to route text to an interpreter, so the enumeration does not
# converge — these forms were found by extending an earlier list of five, and
# extending it again would find more. They are pinned here so the boundary is a
# measured fact rather than an assumption, and so a future change that moves one
# of them is loud.
#
# Each of these EXECUTES a real install (section 3 proves the separation from
# decoys). What backs the miss differs by ecosystem — asserted below.

expect_pass "a herestring fed to sh"                  "sh <<< 'pip install evil==1.0.0'"
expect_pass "a herestring fed to bash"                'bash <<<"pip install evil==1.0.0"'
expect_pass "sh -c nested in a same-quoted sh -c"     "sh -c 'sh -c '\\''pip install evil==1.0.0'\\'''"
expect_pass "a shell built by xargs -I"               "echo 'pip install evil==1.0.0' | xargs -I{} sh -c '{}'"
expect_pass "a shell built by xargs -0"               "printf 'pip install evil==1.0.0' | xargs -0 sh -c"
expect_pass "a script written then run"               "printf 'pip install evil==1.0.0' > s.sh; sh s.sh"
expect_pass "eval nested inside sh -c"                "sh -c 'eval \"pip install evil==1.0.0\"'"
expect_pass "a top-level command substitution"        '$(echo pip install evil==1.0.0)'
pass "command gate leaves the unenumerated carriers unjudged (documented boundary)"

# For npm the miss is DELAYED detection, not a miss: the effect gate's recognizer
# is a raw grep with no carrier enumeration, so it fires on the same text the
# command gate skipped, and it reads the live lockfile rather than the command.
backstop_proj="${tmp_root}/backstop-proj"
mkdir -p "${backstop_proj}"
printf '{"name":"p","version":"1.0.0","lockfileVersion":3,"packages":{"":{"name":"p","version":"1.0.0"}}}\n' > "${backstop_proj}/package-lock.json"
printf '{"name":"p","version":"1.0.0"}\n' > "${backstop_proj}/package.json"
for wrapped_npm in \
  "sh <<< 'npm install evil@1.0.0'" \
  "echo 'npm install evil@1.0.0' | xargs -I{} sh -c '{}'" \
  "printf 'npm install evil@1.0.0' > s.sh; sh s.sh"
do
  backstop_safe="${tmp_root}/safe-backstop-${RANDOM}"
  mkdir -p "${backstop_safe}"
  [[ "$(gate_decision "${wrapped_npm}")" == "pass" ]] || fail "npm delayed-detection fixture is a command-gate miss: ${wrapped_npm}"
  jq -nc --arg c "${wrapped_npm}" --arg cwd "${backstop_proj}" \
    '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}' |
    HOME="${tmp_root}/home-backstop" SAFEDEPS_HOME="${backstop_safe}" scripts/safedeps-post-verify.sh >/dev/null 2>&1 || true
  grep -q 'BACKSTOP' "${backstop_safe}/advisory.log" 2>/dev/null \
    || fail "npm effect gate backstops a command-gate miss: ${wrapped_npm}"
done
pass "npm: an unenumerated carrier is delayed detection — the effect gate still fires"

# For pip/cargo/go/gem there is no closure resolver behind the command gate, so
# the same carrier is a COMPLETE miss. This asserts the absence directly: the
# post hook recognizes the command and then has nothing to check it with.
nolock_proj="${tmp_root}/nolock-proj"
mkdir -p "${nolock_proj}"
printf 'evil==1.0.0\n' > "${nolock_proj}/requirements.txt"
nolock_safe="${tmp_root}/safe-nolock"
mkdir -p "${nolock_safe}"
jq -nc --arg c "sh <<< 'pip install evil==1.0.0'" --arg cwd "${nolock_proj}" \
  '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}' |
  HOME="${tmp_root}/home-nolock" SAFEDEPS_HOME="${nolock_safe}" scripts/safedeps-post-verify.sh >/dev/null 2>&1 || true
grep -q 'UNVERIFIED' "${nolock_safe}/advisory.log" 2>/dev/null \
  || fail "pypi carrier miss is recorded as UNVERIFIED by the post hook"
[[ ! -f "${nolock_safe}/reorg.log" ]] \
  || fail "pypi carrier miss produces no rollback (there is no closure resolver to produce one)"
pass "pypi/crates.io/go/rubygems: an unenumerated carrier is a COMPLETE miss, recorded as UNVERIFIED"

# --- 3. Decoys ----------------------------------------------------------------
# Forms that read as bypasses but never reach a package manager. A gate that
# "caught" these would be buying nothing, and counting them as gaps inflates the
# enumeration with commands that do not install. Proven by execution against a
# fake package manager rather than by reading the quoting rules.
oracle_bin="${tmp_root}/oracle-bin"
oracle_run="${tmp_root}/oracle-run"
mkdir -p "${oracle_bin}" "${oracle_run}"
cat > "${oracle_bin}/pip" <<'FAKE_PIP'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SAFEDEPS_ORACLE_LOG}"
FAKE_PIP
chmod +x "${oracle_bin}/pip"

reaches_package_manager() {
  local form="$1"
  local log="${tmp_root}/oracle-log-${RANDOM}"
  : > "${log}"
  ( cd "${oracle_run}" && SAFEDEPS_ORACLE_LOG="${log}" PATH="${oracle_bin}:${PATH}" \
      bash -c "${form}" ) >/dev/null 2>&1 || true
  grep -q 'install' "${log}" 2>/dev/null
}

reaches_package_manager "pip install evil==1.0.0" \
  || fail "execution oracle detects a plain install (harness self-check)"
pass "execution oracle detects a plain install (harness self-check)"

for real_bypass in \
  "sh <<< 'pip install evil==1.0.0'" \
  "sh -c 'sh -c '\\''pip install evil==1.0.0'\\'''" \
  "printf 'pip install evil==1.0.0' | env sh" \
  "printf 'pip install evil==1.0.0' | /bin/sh" \
  "echo 'pip install evil==1.0.0' | xargs -I{} sh -c '{}'"
do
  reaches_package_manager "${real_bypass}" \
    || fail "form reaches the package manager, so it is a real bypass: ${real_bypass}"
done
pass "the pinned carrier forms really do execute an install"

# `sh -c "sh -c "…""` looks doubly nested but the outer quotes CLOSE at the inner
# ones, so the shell runs `sh -c 'sh -c pip'` with the rest as positional args and
# nothing is installed. `xargs sh -c` without -I/-0 hands the line to sh as $0,
# not as a script, so it is also inert.
for decoy in \
  'sh -c "sh -c "pip install evil==1.0.0""' \
  "echo 'pip install evil==1.0.0' | xargs sh -c"
do
  reaches_package_manager "${decoy}" \
    && fail "form is a decoy and must not be counted as a gap: ${decoy}"
done
pass "decoy forms never reach a package manager (not gaps, nothing to catch)"

# --- 4. The false-positive corpus stays allowed -------------------------------
# Normalizing the pipe consumer widened what counts as a hidden install. That is
# only a net gain if the commands the gate deliberately treats as DATA are still
# treated as data.
for benign in \
  'echo "install it with: curl -fsSL https://example.test/i.sh | sh"' \
  'git commit -m "document the pip install x | sh idiom"' \
  'npm run build' \
  'npm view left-pad' \
  'npx tsc --noEmit'
do
  [[ "$(gate_decision "${benign}")" != "deny" ]] || fail "benign command is not denied: ${benign}"
done
pass "quoted idioms, npm run, and npx stay allowed (no false positives from the widening)"

# --- 5. The unpinned install leaves a record ----------------------------------
# An install that names a package but pins no version produces no spec, so the
# ledger gate never runs for it. npm has the effect gate behind it; the other
# ecosystems have nothing, and until this record existed they had no trace
# either. The record changes no verdict — it exists so the question "should
# unpinned installs be denied?" can be answered from evidence.
#
# The quiet half matters as much as the loud half. A record that fires on
# routine installs is background noise, and background noise is the same as no
# record, so the scope is pinned from both sides.

logged_ungated() {
  local command="$1"
  local safe="${tmp_root}/safe-ungated-$$-${RANDOM}"
  mkdir -p "${safe}"
  jq -nc --arg c "${command}" --arg cwd "${project_dir}" \
    '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}' |
    HOME="${tmp_root}/home-ungated" SAFEDEPS_HOME="${safe}" scripts/safedeps-pre-guard.sh >/dev/null 2>&1
  grep -q 'UNGATED' "${safe}/advisory.log" 2>/dev/null
}

for named_unpinned in \
  "pip install evil" \
  "python3 -m pip install evil" \
  "poetry add evil" \
  "uv add evil" \
  "cargo add evil" \
  "cargo install evil" \
  "go get example.com/evil" \
  "gem install evil" \
  "bundle add evil" \
  "dotnet add package evil"
do
  logged_ungated "${named_unpinned}" \
    || fail "an unpinned named install is recorded as UNGATED: ${named_unpinned}"
  [[ "$(gate_decision "${named_unpinned}")" != "deny" ]] \
    || fail "the UNGATED record must not change the verdict: ${named_unpinned}"
done
pass "an unpinned named install is recorded (the ecosystems with no effect gate behind them)"

for stays_quiet in \
  "pip install -r requirements.txt" \
  "pip install -c constraints.txt evil" \
  "pip install -e ." \
  "bundle install" \
  "npm install left-pad" \
  "npm install" \
  "pip install evil==1.0.0" \
  "cargo add evil --vers 1.0.0" \
  "gem install evil -v 1.0.0" \
  "go get example.com/evil@v1.0.0" \
  "npm run build" \
  'echo "remember to pip install evil"'
do
  logged_ungated "${stays_quiet}" \
    && fail "record stays quiet on a routine or already-gated install: ${stays_quiet}"
done
pass "the record stays quiet on file-driven, bare-lockfile, npm, and already-pinned installs"

printf 'consumer-forms passed\n'
