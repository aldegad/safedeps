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

# Rows for --shard I/M (scripts/test/lib/shard.sh): each expect_* call below is
# a row, and so is each pass of a loop that judges forms itself.
# shellcheck source=lib/shard.sh
source "${ROOT_DIR}/scripts/test/lib/shard.sh"
shard_args "$@"
(( ${#SHARD_REST[@]} == 0 )) || fail "consumer-forms.sh takes --shard I/M or --shard-list, not ${SHARD_REST[0]}"

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
  # mktemp, not $$-$RANDOM: `$$` is constant within a run, so isolation rested
  # entirely on RANDOM, and `mkdir -p` succeeds on an existing directory -- a
  # collision handed one command's sandbox to another with no way to notice. The
  # point is not that collisions were likely; it is that nothing could detect
  # one. The kernel guarantees uniqueness here.
  local safe out
  safe=$(mktemp -d "${tmp_root}/safe.XXXXXX")
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
  shard_row "expect_deny|$1|$2" || return 0
  local label="$1" command="$2" got
  got=$(gate_decision "${command}")
  [[ "${got}" == "deny" ]] || fail "command gate catches ${label} (got: ${got})"
}

expect_pass() {
  shard_row "expect_pass|$1|$2" || return 0
  local label="$1" command="$2" got
  got=$(gate_decision "${command}")
  [[ "${got}" == "pass" ]] || fail "command gate leaves ${label} unjudged as documented (got: ${got})"
}

# deny or allow or pass, then the reason, for one command.
gate_reason() {
  local safe out
  safe=$(mktemp -d "${tmp_root}/safe.XXXXXX")
  out=$(jq -nc --arg c "$1" --arg cwd "${project_dir}" \
    '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}' |
    HOME="${tmp_root}/home" SAFEDEPS_HOME="${safe}" scripts/safedeps-pre-guard.sh 2>/dev/null)
  # No answer is an empty object, set apart from the expansion: bash 3.2 keeps
  # the backslash of "${out:-{\}}" and hands jq `{\}`, which it cannot parse.
  [[ -n "${out}" ]] || out='{}'
  jq -r '(.hookSpecificOutput.permissionDecision // "pass") + " " + (.hookSpecificOutput.permissionDecisionReason // "")' <<< "${out}"
}

# An UNDECIDED deny: the gate could not finish reading the command, and says so
# rather than claiming a finding.
expect_undecided() {
  shard_row "expect_undecided|$1|$2" || return 0
  local label="$1" command="$2" got
  got=$(gate_reason "${command}")
  [[ "${got}" == "deny "*UNDECIDED* ]] || fail "${label} is UNDECIDED (got: ${got:0:120})"
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
# The lexer reads a path-qualified or env-prefixed invocation as the bare one
# (prefixes() in shell_lex); that was applied to the install text and skipped on
# the consumer, so `| /bin/sh` and `| env sh` read as a different consumer than
# `| sh`. These four are that inconsistency, not four separate carriers.
expect_deny "a pipe to an absolute-path shell"        "printf 'pip install evil==1.0.0' | /bin/sh"
expect_deny "a pipe to an absolute-path bash"         "printf 'pip install evil==1.0.0' | /usr/bin/bash"
expect_deny "a pipe to env sh"                        "printf 'pip install evil==1.0.0' | env sh"
expect_deny "a pipe to env with an assignment"        "printf 'pip install evil==1.0.0' | env FOO=1 sh"
expect_deny "a pipe to command sh"                    "printf 'pip install evil==1.0.0' | command sh"
expect_deny "a wrapped pipe to an absolute-path shell" 'bash -c "printf '"'"'pip install evil==1.0.0'"'"' | /bin/sh"'
pass "pipe consumer is normalized like the producer already was"

# The consumer ends where the shell ends a word, not only at a blank. Each of
# these passed unjudged: the check wanted whitespace or end of line after the
# shell's name, so `| sh; echo done` was not a pipe into a shell.
expect_deny "a pipe to sh ended by ;"                 "printf 'pip install evil==1.0.0' | sh; echo done"
expect_deny "a pipe to sh ended by &&"                "printf 'pip install evil==1.0.0' | sh&&echo done"
expect_deny "a pipe to sh piped on"                   "printf 'pip install evil==1.0.0' | sh|cat"
expect_deny "a pipe to sh inside a subshell"          "(printf 'pip install evil==1.0.0' | sh)"
expect_deny "a pipe to sh inside a brace group"       "{ printf 'pip install evil==1.0.0' | sh; }"
expect_deny "a pipe to a subshell running sh"         "printf 'pip install evil==1.0.0' | (sh)"
expect_deny "a pipe to a brace group running sh"      "printf 'pip install evil==1.0.0' | { sh; }"
expect_deny "a |& pipe to sh"                         "printf 'pip install evil==1.0.0' |& sh"
expect_deny "a pipe to sh after a ||"                 "false || printf 'pip install evil==1.0.0' | sh"
pass "a pipe into a shell is read through the shell's operators and groups"

# `||` is not a pipe. The shell after it runs only when the command before it
# fails, and it reads the caller's input, not that command's output. Read as a
# pipe, a shell script after `||` was denied as an install piped into a shell,
# while the same script after `;` was judged as the install it is.
for or_form in \
  'false || sh -c "npm ci \"x\""' \
  "false || sh -c 'npm ci'" \
  "printf 'pip install evil==1.0.0' || sh"
do
  shard_row "or_form: ${or_form}" || continue
  got=$(gate_reason "${or_form}")
  [[ "${got}" != *'reads like an install into a shell'* ]] \
    || fail "a shell after || is not a pipe into a shell: ${or_form} (got: ${got:0:120})"
done
[[ "$(gate_decision 'false || sh -c "npm ci \"x\""')" == "$(gate_decision 'false; sh -c "npm ci \"x\""')" ]] \
  || fail "a shell script after || is judged as it is after ;"
pass "a shell after || is not a pipe into a shell"

# A compound command that a pipe feeds hands the input to every command in it,
# so a shell anywhere a command can stand in it reads the pipe. The consumer
# pattern looked only at the first word after `|` and each of these passed
# unjudged. A keyword that is an argument (`echo fi`) closes nothing.
expect_deny "a pipe to a brace group running sh second"  "printf 'pip install evil==1.0.0' | { :; sh; }"
expect_deny "a pipe to a brace group running sh after &&" "printf 'pip install evil==1.0.0' | { true && sh; }"
expect_deny "a pipe to a subshell running sh second"     "printf 'pip install evil==1.0.0' | (cd /tmp; sh)"
expect_deny "a pipe to an if running sh"                 "printf 'pip install evil==1.0.0' | if true; then sh; fi"
expect_deny "a pipe to a while loop running bash"        "printf 'pip install evil==1.0.0' | while read -r l; do bash; done"
expect_deny "a pipe to a for loop running zsh"           "printf 'pip install evil==1.0.0' | for i in 1; do zsh; done"
expect_deny "a pipe to a case running sh"                "printf 'pip install evil==1.0.0' | case x in x) sh;; esac"
expect_deny "a pipe to a negated sh"                     "printf 'pip install evil==1.0.0' | ! sh"
expect_deny "a pipe to a timed sh"                       "printf 'pip install evil==1.0.0' | time -p sh"
expect_deny "a pipe to a group over several lines"       $'printf \'pip install evil==1.0.0\' | {\n:\nsh\n}'
expect_deny "a pipe to a group with a keyword argument"  "printf 'pip install evil==1.0.0' | { echo fi; sh; }"
expect_deny "a pipe to nested groups running sh"         "printf 'pip install evil==1.0.0' | { if true; then { :; sh; }; fi; }"
# What it must not take: a compound with no shell in it, a shell name as an
# argument, and a shell after the compound has closed.
expect_pass "a pipe to a group that writes a file"       "printf 'pip install evil==1.0.0' | { cat > notes.txt; }"
expect_pass "a shell name as an argument in an if"       "printf 'pip install evil==1.0.0' | if grep -q sh; then echo yes; fi"
expect_pass "a shell after the compound has closed"      "printf 'pip install evil==1.0.0' | { cat > notes.txt; }; sh deploy.sh"
pass "a shell inside a compound command a pipe feeds is a pipe into a shell"

# A heredoc body is stripped once, before anything reads the payloads. A reader
# that stripped again saw the `<<EOF` line with no body after it and dropped
# every following line, so an install written after a heredoc passed with no
# verdict. And only a real heredoc opens one: a herestring, an arithmetic shift
# or a quoted `<<EOF` used to open one with no terminator, which hid every
# line after it.
expect_deny "sh -c after a heredoc"                    $'cat <<EOF > notes.md\nhello\nEOF\nsh -c "pip install evil==6.6.6"'
expect_deny "bash -c after a heredoc"                  $'cat <<EOF > notes.md\nhello\nEOF\nbash -c "npm install evil@6.6.6"'
expect_deny "zsh -c after a heredoc into git"          $'git commit -F - <<EOF\nmsg\nEOF\nzsh -c "gem install evil -v 6.6.6"'
expect_deny "an install after a herestring"            $'cat <<<"hello"\npip install evil==6.6.6'
expect_deny "an install after an arithmetic shift"     $'echo $((1<<2))\npip install evil==6.6.6'
expect_deny "an install after a quoted <<EOF"          $'echo "use <<EOF here"\npip install evil==6.6.6'
expect_deny "a pipe continued past a heredoc"          $'cat <<EOF |\npip install evil==6.6.6\nEOF\nsh'
pass "heredocs are stripped once and only real ones open"

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
expect_pass "a heredoc fed straight to sh"            $'sh <<EOF\npip install evil==1.0.0\nEOF'
expect_pass "a shell built by xargs -I"               "echo 'pip install evil==1.0.0' | xargs -I{} sh -c '{}'"
expect_pass "a shell built by xargs -0"               "printf 'pip install evil==1.0.0' | xargs -0 sh -c"
expect_pass "a script written then run"               "printf 'pip install evil==1.0.0' > s.sh; sh s.sh"
expect_pass "a top-level command substitution"        '$(echo pip install evil==1.0.0)'
expect_pass "a pipe to a quoted shell name"           "printf 'pip install evil==1.0.0' | \"sh\""
pass "command gate leaves the unenumerated carriers unjudged (documented boundary)"

# Two payloads read by a grammar that is not the shell's, which this release
# does not read that way (sibling plan after statement-starts-from-the-lexer):
# `env -S STRING` splits STRING by env(1)'s own rules -- its options, `--`,
# `\_` as a blank, `#` ending it -- where the payload reader reads STRING as
# a script, and zsh runs the code in a glob qualifier `e:...:` or `e{...}`,
# which no reader reads. Every shell runs the env forms and zsh the qualifier
# forms (verdict howl-20261004-084050, W33 of the v2.18.1 plan); each passes
# here with no record, as on main. Pinned so that the change that closes them
# is loud. `env -S 'pip install x'` itself is read (consumer rows above).
for boundary in \
  "env -S '-u X pip install evil==1.0.0'" \
  "env -S '-- pip install evil==1.0.0'" \
  "env -S '-v pip install evil==1.0.0'" \
  "env -S'-u X pip install evil==1.0.0'" \
  "env -S 'pip\\_install\\_evil==1.0.0'" \
  "env -S 'pip install #c' evil==1.0.0" \
  "ls *(e:'pip install evil==1.0.0':)" \
  "echo *(e:'pip install evil==1.0.0':)" \
  'print -l *(e{pip install evil==1.0.0})' \
  "ls -d /*(e:'npm ci':)"
do
  expect_pass "${boundary}" "${boundary}"
done
pass "env -S read by env(1)'s splitting and zsh's glob qualifier code are not read yet (documented boundary)"


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
  shard_row "wrapped_npm: ${wrapped_npm}" || continue
  backstop_safe=$(mktemp -d "${tmp_root}/safe-backstop.XXXXXX")
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
  # Same reason as the sandbox keys: a reused name silently shares one command's
  # oracle log with another, and nothing here could tell.
  local log
  log=$(mktemp "${tmp_root}/oracle-log.XXXXXX")
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
# Read as the shell reads it, the first decoy's script is `sh -c pip`, and the
# rest are positional arguments: nothing is installed, and the gate says so.
expect_pass "the doubly quoted sh -c decoy" 'sh -c "sh -c "pip install evil==1.0.0""'
pass "decoy forms never reach a package manager (not gaps, nothing to catch)"

# --- 4. The false-positive corpus stays allowed -------------------------------
# Normalizing the pipe consumer widened what counts as a hidden install. That is
# only a net gain if the commands the gate deliberately treats as DATA are still
# treated as data.
for benign in \
  $'cat <<\'B\'\nsh -c "printf \'pip install evil==1.0.0\' | sh"\nB' \
  'echo "install it with: curl -fsSL https://example.test/i.sh | sh"' \
  'git commit -m "document the pip install x | sh idiom"' \
  'npm run build' \
  'npm run it' \
  'npm test' \
  'npm view left-pad' \
  'npx tsc --noEmit' \
  'npx --version' \
  'go run main.go' \
  'go run ./cmd/tool' \
  'go build ./...' \
  'uv run pytest' \
  'uv tool list' \
  'pipx list' \
  'bun run build' \
  'bun test' \
  'yarn workspace web build' \
  'pnpm run build' \
  'cargo build' \
  'dotnet tool run dotnet-ef' \
  'dotnet package list' \
  'dotnet package remove Serilog' \
  'dotnet package search Serilog' \
  'dotnet package search Fabrikam.WebApi@1.2.3' \
  'python -m pytest' \
  'echo do pip install evil==1.0.0' \
  'echo npm i evil@1.0.0' \
  'npm init' \
  'npm init -y' \
  'npm init --scope @acme' \
  'npm create' \
  'npm link' \
  'npm link ../my-lib' \
  'npm unlink left-pad' \
  'echo npm create evil@1.0.0'
do
  shard_row "benign: ${benign}" || continue
  [[ "$(gate_decision "${benign}")" != "deny" ]] || fail "benign command is not denied: ${benign}"
done
pass "quoted idioms, npm run, npx, go run, uv run and echoed install text stay allowed (no false positives from the widening)"

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
  # Same as gate_decision above. Both key sites change together: leaving one
  # keeps the exposure, and this is the helper whose quiet cases went red.
  local safe
  safe=$(mktemp -d "${tmp_root}/safe-ungated.XXXXXX")
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
  "dotnet add package evil" \
  "mvn dependency:get -Dartifact=g:evil" \
  "pip install -c constraints.txt evil" \
  "pip install -r requirements.txt evil" \
  "pip install -e . evil" \
  "pip install git+https://example.test/evil.git" \
  "pip install git+ssh://git@example.test/evil.git" \
  "pip install -e git+ssh://git@example.test/evil.git" \
  "pip install -t /tmp/target evil" \
  "go get -t example.com/evil" \
  "go get -u example.com/evil" \
  "gem install -f evil" \
  "gem install --force evil" \
  "gem install -r evil" \
  "gem install --remote evil" \
  "pip install -i https://mirror.example/simple evil" \
  "cargo install -f evil" \
  "cargo install --force evil"
do
  shard_row "named_unpinned: ${named_unpinned}" || continue
  logged_ungated "${named_unpinned}" \
    || fail "an unpinned named install is recorded as UNGATED: ${named_unpinned}"
  [[ "$(gate_decision "${named_unpinned}")" != "deny" ]] \
    || fail "the UNGATED record must not change the verdict: ${named_unpinned}"
done
# `cargo install evil --version 1.0.0` and `bundle add evil --version 1.0.0` used
# to be recorded here even though a version is present, because the extractor did
# not read those two flags and the ledger gate genuinely did not run. The record
# was true; the gap behind it was not a policy. The extractor reads both now, so
# they are gated like `cargo add --vers` (section 6).
pass "an unpinned named install is recorded, including past a source flag, a URL user, and a flag-carried coordinate"

for stays_quiet in \
  "pip install -r requirements.txt" \
  "bundle install" \
  "npm install left-pad" \
  "npm install" \
  "pip install evil==1.0.0" \
  "cargo add evil --vers 1.0.0" \
  "gem install evil -v 1.0.0" \
  "go get example.com/evil@v1.0.0" \
  "npm run build" \
  "mvn dependency:get -Dartifact=g:evil:1.0.0" \
  "pip install ." \
  "pip install ./local-pkg" \
  "pip install /tmp/evil.whl" \
  "pip install -i https://mirror.example/simple -r requirements.txt" \
  "pip install --index-url https://mirror.example/simple" \
  "pip install -i https://mirror.example/simple" \
  "pip install -e ." \
  'echo "remember to pip install evil"'
do
  shard_row "stays_quiet: ${stays_quiet}" || continue
  logged_ungated "${stays_quiet}" \
    && fail "record stays quiet on a routine or already-gated install: ${stays_quiet}"
done
pass "the record stays quiet on file-only, working-tree, bare-lockfile, npm, and already-pinned installs"

# A KNOWN spurious record, pinned rather than fixed. An option the manager's
# table does not list is read as taking no value, so a value option the table
# lacks leaks its value into the operands. The assumption is deliberate:
# guessing the other way drops the install this record exists to catch. pip's
# own value options are in its table now, from its help (`--proxy` among them),
# so the stand-in here is an option the table does not know, as an option a
# newer pip adds would be. Pinned so the line reads as a declared trade-off
# rather than a defect.
logged_ungated "pip install --unlisted-proxy https://proxy.example:8080 -r requirements.txt" \
  || fail "a value option the table does not know still leaks a spurious record (declared trade-off)"
logged_ungated "pip install --proxy https://proxy.example:8080 -r requirements.txt" \
  && fail "pip's own --proxy takes its value: no spurious record"
pass "an unknown value-taking flag still leaks a spurious record (declared, not a defect)"

# `mvn -Dartifact=… dependency:get` puts the flag BEFORE the goal. This used to
# be pinned as silent, on the reading that options before the verb are carrier
# enumeration. They are not: a carrier hands text to an interpreter, and an
# option between a manager and its verb is the install command itself, which
# the gate already allowed for npm (one option). lib/install-grammar.sh applies
# that rule to every manager, so the unpinned form is recorded and the pinned
# form is gated (section 6).
logged_ungated "mvn -Dartifact=g:evil dependency:get" \
  || fail "flag-before-goal maven is recognized and its unpinned form recorded"
pass "flag-before-goal maven is an install like any other: recorded when unpinned"

# --- 6. The install grammar: forms the command itself spells -----------------
# Not carriers. Each of these IS the install command, spelled a way the manager
# documents or the shell grammar allows, and each passed the gate with no record
# before lib/install-grammar.sh (measured 2026-10-01 against the guard that was
# live on the development machine). The scope rule is ARCHITECTURE.md's: a rule
# the gate already states, applied where it was skipped.
for grammar_form in \
  "pnpm i evil@1.0.0" \
  "pnpm upgrade evil@1.0.0" \
  "pnpm it evil@1.0.0" \
  "npm in evil@1.0.0" \
  "npm isntall evil@1.0.0" \
  "npm it evil@1.0.0" \
  "npm u evil@1.0.0" \
  "npm udpate evil@1.0.0" \
  "npm upd evil@1.0.0" \
  "npm upgra evil@1.0.0" \
  "npm install-te evil@1.0.0" \
  "npm installTest evil@1.0.0" \
  "npm si evil@1.0.0" \
  "npm exe evil@1.0.0" \
  "npm create evil@1.0.0" \
  "npm init evil@1.0.0" \
  "npm innit evil@1.0.0" \
  "npm cr evil@1.0.0" \
  "npm init @usr/foo@2.0.0" \
  "npm init -y evil@1.0.0 my-app" \
  "pnpm create evil@1.0.0" \
  "yarn create evil@1.0.0" \
  "bun create evil@1.0.0" \
  "bun c evil@1.0.0" \
  "npm link evil@1.0.0" \
  "npm ln evil@1.0.0" \
  "npm lin evil@1.0.0" \
  "yarn up evil@1.0.0" \
  "yarn global add evil@1.0.0" \
  "yarn workspace web add evil@1.0.0" \
  "bun a evil@1.0.0" \
  "npm --silent --loglevel error install evil@1.0.0" \
  "pip --quiet install evil==1.0.0" \
  "pip3.11 install evil==1.0.0" \
  "python3.11 -m pip install evil==1.0.0" \
  "py -3.11 -m pip install evil==1.0.0" \
  "cargo --locked install evil@1.0.0" \
  "cargo +nightly install evil@1.0.0" \
  "cargo install evil --version 1.0.0" \
  "gem --norc install evil -v 1.0.0" \
  "bundle add evil --version 1.0.0" \
  "dotnet add App.csproj package Evil --version 1.0.0" \
  "dotnet package add Evil --version 1.0.0" \
  "dotnet package add Evil -v 1.0.0 --project App.csproj" \
  "dotnet package update Evil@1.0.0" \
  "dotnet package update Contoso.Utilities Evil@1.0.0" \
  "dotnet package update --project App.csproj -v q Evil@1.0.0" \
  "dotnet tool install evil --version 1.0.0" \
  "mvn -Dartifact=g:evil:1.0.0 dependency:get" \
  "npx evil@1.0.0" \
  "npx -y evil@1.0.0" \
  "npx -p evil@1.0.0 evil-cli" \
  "npm exec evil@1.0.0" \
  "npm x -- evil@1.0.0" \
  "pnpx evil@1.0.0" \
  "bunx evil@1.0.0" \
  "bun x evil@1.0.0" \
  "uvx evil@1.0.0" \
  "uv tool install evil==1.0.0" \
  "pipx install evil==1.0.0" \
  "pipx run evil==1.0.0" \
  "go run example.com/evil@v1.0.0" \
  "( pip install evil==1.0.0 )" \
  "(pip install evil==1.0.0)" \
  "{ pip install evil==1.0.0; }" \
  "if true; then pip install evil==1.0.0; fi" \
  "for i in 1; do pip install evil==1.0.0; done" \
  "! pip install evil==1.0.0" \
  "time pip install evil==1.0.0" \
  "exec pip install evil==1.0.0" \
  "env -i pip install evil==1.0.0" \
  'pip install "evil==1.0.0"' \
  "pip install 'evil==1.0.0'" \
  "pip install 'evil[x]==1.0.0'" \
  "pip install evil===1.0.0" \
  "uv add 'evil[all]==1.0.0'" \
  "poetry add 'evil[x]@1.0.0'" \
  "if true; then env pip install evil==1.0.0; fi" \
  "if true; then FOO=1 pip install evil==1.0.0; fi" \
  "if true; then command pip install evil==1.0.0; fi" \
  "coproc pip install evil==1.0.0"
do
  expect_deny "the install spelled ${grammar_form}" "${grammar_form}"
done
pass "aliases, options, versioned interpreters, runners, statement positions and quoted specs are all gated"

# A function body opens a statement: `{` after `f()`, `f ()` or `function f`.
# Narrowing `{` to statement starts dropped it (caught in review); `)` alone
# still opens nothing.
for fn in \
  'f() { pip install evil==1.0.0; }; f' \
  'function f { pip install evil==1.0.0; }; f' \
  'function f() { pip install evil==1.0.0; }; f' \
  'f () { cargo add serde@1.0.0; }; f' \
  'f() { npm install evil@1.0.0; }; f' \
  'if true; then f() { pip install evil==1.0.0; }; f; fi' \
  'for i in 1; do f() { pip install evil==1.0.0; }; f; done' \
  'while f() { pip install evil==1.0.0; }; f; do break; done' \
  '{ f() { pip install evil==1.0.0; }; f; }' \
  'f() { g() { pip install evil==1.0.0; }; g; }; f' \
  'a/b() { pip install evil==1.0.0; }; a/b' \
  'f@x() { pip install evil==1.0.0; }; f@x' \
  'f ( ) { pip install evil==1.0.0; }; f' \
  '() { pip install evil==1.0.0; }' \
  'function { pip install evil==1.0.0; }' \
  'f() pip install evil==1.0.0; f'
do
  expect_deny "an install in a function body: ${fn}" "${fn}"
done
expect_pass "a parenthesized value before a command name opens no statement" 'echo $(date) pip install x'
expect_pass "a function definition echoed as text is data" 'echo "f() { pip install x; }"'
expect_pass "a function body with no install" 'f() { npm run build; }; f'
expect_pass "the word function as an argument opens nothing" 'echo function f { pip install x; }'
expect_pass "a nameless function without its brace is no function" 'function pip install x'
pass "an install in a function body is gated"

# Where a statement starts is the lexer's to say (starts() in shell_lex), and
# SAFEDEPS_G_START knows only separators. A regex chain of the words before a
# command could not see the state that puts a command at a word, and three
# review rounds each found the next form it missed. These are the forms the
# judgment that replaced it measured (safedeps/statement-starts-from-the-lexer):
# each runs its install in at least one of bash 3.2, bash 5, zsh, sh and dash,
# and each must be read as an install whose spec is checked -- "not approved",
# not a deny for some other reason, which would hide a statement start that was
# never read.
expect_not_approved() {
  shard_row "expect_not_approved|$1|$2" || return 0
  local label="$1" command="$2" got
  got=$(gate_reason "${command}")
  [[ "${got}" == "deny "*"install not approved"* ]] || fail "${label} is read as an install and its spec checked (got: ${got:0:120})"
}

# The command after the inert rewrite, or nothing when the gate did not
# rewrite it.
gate_rewrite() {
  local safe
  safe=$(mktemp -d "${tmp_root}/safe.XXXXXX")
  jq -nc --arg c "$1" --arg cwd "${project_dir}" \
    '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}' |
    HOME="${tmp_root}/home" SAFEDEPS_HOME="${safe}" scripts/safedeps-pre-guard.sh 2>/dev/null |
    jq -r '.hookSpecificOutput.updatedInput.command // ""'
}
# Where `--ignore-scripts` stands in a rewritten command, as offsets into the
# command as written, one per flag.
flag_places() {
  local rest="$1" head out="" at=0
  while [[ "${rest}" == *" --ignore-scripts"* ]]; do
    head="${rest%%" --ignore-scripts"*}"
    at=$(( at + ${#head} )); out+=" ${at}"
    rest="${rest#*" --ignore-scripts"}"
  done
  printf '%s ' "${out}"
}
# Whether the gate rewrites <form> with a flag at least where <expected> has
# one, and adds nothing but flags. Since v2.18.0 a statement gets the flag
# right after its verb (the floor) and at the place its own arguments read
# true, often after the last one (inert_flag_offsets), so a row states the
# flags it is about and the rest may stand beside them.
rewrite_holds() { # form expected
  local got p places
  got=$(gate_rewrite "$1")
  [[ -n "${got}" && "${got// --ignore-scripts/}" == "$1" && "${2// --ignore-scripts/}" == "$1" ]] || return 1
  places=$(flag_places "${got}")
  for p in $(flag_places "$2"); do [[ " ${places}" == *" ${p} "* ]] || return 1; done
}
# Each row: the form's id in the judgment grid, then whether each shell ran
# its install (1) or not (0), in the order macOS bash 3.2, zsh 5.9, macOS sh,
# dash, zsh through the agent's eval wrapper, Linux bash 5.2. Measured by
# running each form in each shell with a marker in place of the install. The verdict is the union of the readings
# (bash first, zsh and dash where it says DIVERGE), so a form only zsh runs is
# denied through the zsh reading.
start_rows=(
  'N1|111111|case x in x) { pip install evil==1.0.0; };; esac'
  'N2|111111|case x in (x) { pip install evil==1.0.0; };; esac'
  'N3|101001|time -p { pip install evil==1.0.0; }'
  'N5|010010|for i (1) { pip install evil==1.0.0; }'
  'N6|010010|repeat 1 { pip install evil==1.0.0; }'
  'N7|010010|f g() { pip install evil==1.0.0; }; f'
  'N8|010010|function f g { pip install evil==1.0.0; }; f'
  'N9|010010|{ true; } always { pip install evil==1.0.0; }'
  'U1|000001|coproc foo { pip install evil==1.0.0; }; wait'
  $'U4b|010010|foreach i (1)\npip install evil==1.0.0\nend'
  'F1|111011|for ((i=0;i<1;i++)) { pip install evil==1.0.0; }'
  'P0|111111|pip install evil==1.0.0'
  'P1|111111|f() { pip install evil==1.0.0; }; f'
  'X1|111011|for ((i=(0);i<1;i++)) { pip install evil==1.0.0; }'
  "X2|010010|repeat '1' { pip install evil==1.0.0; }"
  'X3|010010|for i ($(echo 1)) { pip install evil==1.0.0; }'
  'X4|010010|for i (1) pip install evil==1.0.0'
  'X5|010010|repeat 1 pip install evil==1.0.0'
  'X6|010010|while ((i++<1)) { pip install evil==1.0.0; }'
  'X7|010010|if [[ 1 ]] pip install evil==1.0.0'
  'X8|111111|case x in x) pip install evil==1.0.0;; esac'
  'X9|111111|case x in x) case y in y) { pip install evil==1.0.0; };; esac;; esac'
  'X10|010011|coproc { pip install evil==1.0.0; }; wait'
  'X11|010010|repeat 1 repeat 1 { pip install evil==1.0.0; }'
  'X12|010010|for i (1) for j (1) { pip install evil==1.0.0; }'
  'X15|010010|f g () pip install evil==1.0.0; f'
  'X16|010010|function f g () { pip install evil==1.0.0; }; f'
  'X17|101101|time -p pip install evil==1.0.0'
  'X18|010010|repeat $((1)) { pip install evil==1.0.0; }'
  "X20|010010|'f'() { pip install evil==1.0.0; }; f"
  $'X21|010010|for i (1) {\npip install evil==1.0.0\n}'
  $'X22|111111|case x in\nx) { pip install evil==1.0.0; };;\nesac'
  'X23|111011|for i in 1; { pip install evil==1.0.0; }'
  'X24|111111|if true; then { pip install evil==1.0.0; }; fi'
  'X25|111011|time { pip install evil==1.0.0; }'
  'X26|111111|! { pip install evil==1.0.0; }'
  # bash 5 reads `function WORD function_body` and `coproc WORD
  # shell_command`: any compound command after the name is the body. bash 3.2,
  # zsh, sh and dash fail to parse the function forms (bash 3.2 has no coproc),
  # and `function f g if` fails in bash 5 too (one name). Measured on
  # 2026-10-03 with a marker in place of the install, the bash 5 column on
  # Linux bash 5.2.21 and again on a macOS build of GNU bash 5.2.37.
  'FH1|000001|function f if pip install evil==1.0.0; then :; fi; f'
  'FH2|000001|function f while pip install evil==1.0.0; do break; done; f'
  'FH3|000001|function f until pip install evil==1.0.0; do break; done; f'
  'FH4|000001|function f for i in 1; do pip install evil==1.0.0; done; f'
  'FH5|000001|function f case x in x) pip install evil==1.0.0;; esac; f'
  'FH6|000001|function f select i in 1; do pip install evil==1.0.0; break; done <<< 1; f'
  'FH7|000001|function f ( pip install evil==1.0.0 ); f'
  'CP1|000001|coproc foo if pip install evil==1.0.0; then :; fi; wait'
  'CP2|000001|coproc foo while pip install evil==1.0.0; do break; done; wait'
  'CP3|000001|coproc foo until pip install evil==1.0.0; do :; done; wait'
  'CP4|000001|coproc foo for i in 1; do pip install evil==1.0.0; done; wait'
  'CP5|000001|coproc foo case x in x) pip install evil==1.0.0;; esac; wait'
  'CP6|000001|coproc foo ( pip install evil==1.0.0 ); wait'
  # A redirection before the command name is a prefix like an assignment.
  # Every shell runs these; the recognizers read none of them until the
  # unprefixed view dropped the redirection at each start.
  'RD1|111111|2>/dev/null pip install evil==1.0.0'
  'RD2|111111|echo a; 2>/dev/null pip install evil==1.0.0'
  'RD3|111111|f() { </dev/null pip install evil==1.0.0; }; f'
  'RD4|111011|function f { 2>/dev/null pip install evil==1.0.0; }; f'
  'RD5|111111|if 2>/dev/null pip install evil==1.0.0; then :; fi'
  'RD6|111111|case x in x) 2>/dev/null pip install evil==1.0.0;; esac'
  'RD7|111111|2>/dev/null >/dev/null </dev/null pip install evil==1.0.0'
  'RD8|111111|2>/dev/null FOO=1 pip install evil==1.0.0'
  'RD9|111111|FOO=1 2>/dev/null pip install evil==1.0.0'
  'RD10|111111|time 2>/dev/null pip install evil==1.0.0'
  'RD11|111011|&>/dev/null pip install evil==1.0.0'
  'RD12|111111|2> /dev/null pip install evil==1.0.0'
  'RD13|111111|{ >/dev/null pip install evil==1.0.0; }'
  'RD14|111111|exec 2>/dev/null pip install evil==1.0.0'
  'AS1|111011|function f { FOO=1 pip install evil==1.0.0; }; f'
  # `&>` is one redirection operator to bash and zsh. dash has none: it ends
  # the command at the `&` and starts the next one at the `>`, so each of
  # these runs its install in dash alone (also Linux dash 0.5.12, the /bin/sh
  # of Debian and Ubuntu; Linux bash 5.2.37 ran none). Measured on 2026-10-03
  # with a marker in place of the install. Every reading read `&>` as a
  # redirection, said no DIVERGE, and all of these passed.
  'AR1|000100|echo a &>/dev/null pip install evil==1.0.0'
  'AR2|000100|echo a &>>/dev/null pip install evil==1.0.0'
  'AR3|000100|echo a&>/dev/null pip install evil==1.0.0'
  'AR4|000100|echo a &> /dev/null pip install evil==1.0.0'
  'AR5|000100|true; echo a &>/dev/null pip install evil==1.0.0'
  'AR6|000100|{ echo a &>/dev/null pip install evil==1.0.0; }'
  'AR7|000100|f() { echo a &>/dev/null pip install evil==1.0.0; }; f'
  'AR8|000100|echo $(echo a &>/dev/null pip install evil==1.0.0)'
  'AR9|000100|echo a 2>&1 &>/dev/null pip install evil==1.0.0'
  'AR10|000100|if true; then echo a &>/dev/null pip install evil==1.0.0; fi'
  'AR11|000100|echo a &>|/dev/null pip install evil==1.0.0'
  'AR12|000100|echo a &>/dev/null FOO=1 pip install evil==1.0.0'
  'AR13|000100|true &>/dev/null pip install evil==1.0.0'
  'AR15|000100|echo a &>/dev/null env pip install evil==1.0.0'
  'AN1|000100|echo a &>/dev/null npm install evil@1.0.0'
  # A redirection read the way the shell reads it (measured 2026-10-03, the
  # shell-reading forms of the same ids; the bash 5 column again on a macOS
  # build of GNU bash 5.2.37). Its target is one word as the shell cuts it,
  # a process substitution whole, so the command starts after `<(true)`.
  # bash 4.1 and later read `{fd}` as a descriptor variable, zsh too after
  # exec and command; bash 3.2, sh and dash run `{fd}` as a command. Each
  # passed with no verdict.
  'W1|110011|< <(true) pip install evil==1.0.0'
  'W6|110011|> >(cat) pip install evil==1.0.0'
  'V1|000001|{fd}>/dev/null pip install evil==1.0.0'
  'V2|000001|{fd}>&2 pip install evil==1.0.0'
  'V3|000001|{a}>/dev/null {b}>/dev/null pip install evil==1.0.0'
  'V4|000001|{fd}<&0 pip install evil==1.0.0'
  'V5|000001|{fd}>>/dev/null pip install evil==1.0.0'
  'W2|000001|{fd}<<<x pip install evil==1.0.0'
  'V6|000001|echo a; {fd}>/dev/null pip install evil==1.0.0'
  'V7|000001|f() { {fd}>/dev/null pip install evil==1.0.0; }; f'
  'V31|000001|FOO=1 {fd}>/dev/null pip install evil==1.0.0'
  'V32|000001|! {fd}>/dev/null pip install evil==1.0.0'
  'V33|000001|{fd}>/dev/null npm_config_global=true pip install evil==1.0.0'
  'W12|000001|{fd}>/dev/null env pip install evil==1.0.0'
  'W9|010011|exec {fd}>/dev/null pip install evil==1.0.0'
  'W10|010011|command {fd}>/dev/null pip install evil==1.0.0'
  $'HD1|111111|0<<E pip install evil==1.0.0\nx\nE'
  $'HD2|000001|{fd}<<E pip install evil==1.0.0\nx\nE'
  'VN1|000001|{fd}>/dev/null npm install evil@1.0.0'
  'VN6|000001|echo a; {fd}>/dev/null npm install evil@1.0.0'
  # A redirection between the manager and its arguments. Every shell passes
  # the arguments unchanged (a stub that marks only the exact arguments ran
  # in each), and the recognizers read the redirection where it stood, in
  # every ecosystem. zsh alone reads `>! /dev/null` as one redirection.
  'RM1|111111|pip 2>/dev/null install evil==1.0.0'
  'RM1b|111111|pip3 2>/dev/null install evil==1.0.0'
  'RM2|010011|pip {fd}>/dev/null install evil==1.0.0'
  'RM3|111111|pip </dev/null install evil==1.0.0'
  'RM4|111111|npm >/dev/null install evil@1.0.0'
  'RM5|111111|npm 2>&1 install evil@1.0.0'
  'RM5b|111111|npm 2>/dev/null install evil@1.0.0'
  'RM2b|010011|npm {fd}>/dev/null install evil@1.0.0'
  'RM5c|111111|cargo 2>&1 add evil@1.0.0'
  'RM4b|111111|gem >/dev/null install evil -v 1.0.0'
  'RM1c|111111|pnpm 2>/dev/null add evil@1.0.0'
  'RM1d|111111|go 2>/dev/null get example.test/evil@v1.0.0'
  'ZB1|010010|pip >! /dev/null install evil==1.0.0'
  # A process substitution runs its body. The recognizer read the install
  # in it, and the spec extractor never saw it, so each of these passed with
  # no ledger check on main and on v2.18.0 (the npm form with only
  # --ignore-scripts). dash and sh have no process substitution.
  'PA1|110011|cat <(pip install evil==1.0.0)'
  'PA2|110011|tee >(pip install evil==1.0.0) </dev/null'
  'PA3|110011|diff <(cargo add evil@1.0.0) /dev/null'
  'PA4|110011|cat <(true; pip install evil==1.0.0)'
  'PA5|110011|cat <(npm install evil@1.0.0)'
  'PA6|110011|cat < <(pip install evil==1.0.0)'
  # A subshell where a command stands, with words of its statement before
  # it. No word follows the `{`, the `do` or the `then` to carry the start,
  # so the statement began at `function`, `for` or `if` and no manager was
  # read in it: each of SB1-SB6 passed on main with no verdict. The close of
  # a subshell ends a command, so `then` and `do` may follow it at once. A
  # function head may hold a blank between its parentheses (SB7, SB8), and
  # bash 5 runs a subshell glued to `coproc` (SB9); both were read until a
  # `(` glued to a word became part of that word, and are read again.
  'SB1|111011|function f { (pip install evil==1.0.0); }; f'
  'SB2|111011|function f { ( pip install evil==1.0.0 ) }; f'
  'SB3|111111|set -- a; for i do (pip install evil==1.0.0); done'
  'SB4|101101|set -- a; for i do(pip install evil==1.0.0); done'
  'SB5|111111|if (true) then (pip install evil==1.0.0) fi'
  'SB6|111111|while (true) do (pip install evil==1.0.0); break; done'
  'SB6b|101101|if(true)then(pip install evil==1.0.0)fi'
  'SB7|101101|f( ) { pip install evil==1.0.0; }; f'
  'SB8|101101|f( )( pip install evil==1.0.0 ); f'
  'SB9|000001|coproc(pip install evil==1.0.0); wait'
  # A start with no byte of its own before it: a redirection, an assignment
  # or a precommand glued to a reserved word, `!`, the close of a head, or
  # zsh's glued `{`. The walk always found these starts; the stmts view wrote
  # each start over the byte before it and had none here, and the unprefixed
  # view removed the redirection and left nothing between the reserved word
  # and the command (`then>/dev/null pip` read as `thenpip`). Each passed with
  # no record on main, v2.18.0 and every round before this one (verdict
  # howl-20261004-084050, its forms as written there; bamdori-20261004-224625
  # measured the macOS columns with a stub that marks only the exact install
  # arguments, and the agent column is the zsh one). zsh alone reads `&!` as
  # one list terminator, so a command glued after it starts there.
  'HA1|111111|if true; then>/dev/null pip install evil==1.0.0; fi'
  'HA2|111111|for i in 1; do>/dev/null pip install evil==1.0.0; done'
  'HA3|111111|while true; do</dev/null pip install evil==1.0.0; break; done'
  'HA4|111111|if false; then :; else>/dev/null X=1 pip install evil==1.0.0; fi'
  'HA5|111111|if>/dev/null pip install evil==1.0.0; then :; fi'
  'HA6|111111|!>/dev/null pip install evil==1.0.0'
  'HA7|111011|for ((i=0;i<1;i++)) {>/dev/null pip install evil==1.0.0; }'
  'HA8|010010|for i (1)>/dev/null pip install evil==1.0.0'
  'HA9|010010|if ((1))2>/dev/null pip install evil==1.0.0'
  'HA10|010010|if (true)2>&1 pip install evil==1.0.0'
  $'HA11|010010|foreach i (1)</dev/null pip install evil==1.0.0\nend'
  'HA12|010010|{X=1 pip install evil==1.0.0; }'
  'HA13|010010|{2>/dev/null pip install evil==1.0.0; }'
  'HA14|010010|{command pip install evil==1.0.0; }'
  'HA15|010010|() {2>&1 pip install evil==1.0.0; }'
  'HA16|010010|repeat 1 {X=1 pip install evil==1.0.0; }'
  'HA17|010010|{a[1]=x pip install evil==1.0.0; }'
  'HA18|010010|repeat 12>&1 pip install evil==1.0.0'
  'HB1|010010|true&!pip install evil==1.0.0'
  'HB2|010010|{ true&!pip install evil==1.0.0; }'
  'HB3|010010|if true; then true&!pip install evil==1.0.0; fi'
  'HB5|111111|true &! pip install evil==1.0.0'
)
for start_row in "${start_rows[@]}"; do
  start_ran="${start_row#*|}" start_ran="${start_ran%%|*}" start_form="${start_row#*|*|}"
  expect_not_approved "an install at a statement start (${start_row%%|*}, ran ${start_ran}): ${start_form}" "${start_form}"
done
# zsh reads `case x {` as a case; the lexer reads a case that never closes, so
# the gate cannot finish reading it and says so. Fail-closed, not a finding.
expect_undecided "a zsh brace case" 'case x { (x) { pip install evil==1.0.0; } ;; }'
expect_deny "a brace group echoed into a shell" 'echo { pip install evil\; } | sh'
# The same words where no command starts. Each is data in every shell measured.
for not_a_start in \
  'echo "f() { pip install evil==1.0.0; }"' \
  'echo $(date) pip install evil==1.0.0' \
  'function pip install x' \
  'echo { pip install x }' \
  'echo repeat 1 pip install x' \
  'echo time -p pip install x' \
  'git commit -m "case x in x) { pip install x; };; esac"' \
  'cat <(echo hi) pip install x' \
  'echo always { pip install x }' \
  "printf '%s\\n' 'for i (1) { pip install x; }'" \
  'echo then pip install x' \
  'echo function f { pip install x; }' \
  'f() { npm run build; }; f' \
  'echo ! pip install x' \
  "grep -E '(a|b) { pip install' f" \
  'echo for i in 1; do echo pip install x; done' \
  'coproc foo pip install evil==1.0.0; wait' \
  'echo 2>/dev/null pip install evil==1.0.0' \
  'echo a 2>/dev/null pip install evil==1.0.0' \
  'function f g if pip install evil==1.0.0; then :; fi; g' \
  'function f { :; }; f' \
  'echo function f if pip install evil==1.0.0' \
  'echo coproc foo if pip install evil==1.0.0' \
  'echo pip install evil==1.0.0 &>/dev/null' \
  'echo "a &>/dev/null pip install evil==1.0.0"' \
  'echo a (b) pip install evil==1.0.0' \
  $'shopt -s extglob\nls !(zz) pip install evil==1.0.0' \
  $'shopt -s extglob\nrm -rf !(node_modules) && npm run build' \
  'echo a \&>/dev/null pip install evil==1.0.0' \
  'echo a >&/dev/null pip install evil==1.0.0' \
  'ls &>/dev/null'
do
  expect_pass "words that open no statement: ${not_a_start}" "${not_a_start}"
  if shard_row "no UNGATED record: ${not_a_start}" && logged_ungated "${not_a_start}"; then
    fail "words that open no statement leave no UNGATED record: ${not_a_start}"
  fi
done
# zsh reads `echo () pip install x` as a definition of a function named echo,
# so the install words are a function body there. It is recorded, as it was
# before the lexer read statement starts.
expect_pass "a zsh function named echo" 'echo () pip install x'
logged_ungated 'echo () pip install x' || fail "a zsh function named echo is recorded"

# Four ways a statement-start reader went wrong while this was built, pinned.
# An assignment is part of its command. A start between them took the
# assignment off the install, and the record of a global install went: the
# install read as one into the project. (That record was an UNGATED line when
# the trap was found; a global npm install is now recorded as landing in the
# global prefix, and the trace check is the PostToolUse hook's.)
logged_global() {
  local safe
  safe=$(mktemp -d "${tmp_root}/safe-global.XXXXXX")
  jq -nc --arg c "$1" --arg cwd "${project_dir}" \
    '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}' |
    HOME="${tmp_root}/home-global" SAFEDEPS_HOME="${safe}" scripts/safedeps-pre-guard.sh >/dev/null 2>&1
  grep -q 'npm installs this in its global prefix' "${safe}/advisory.log" 2>/dev/null
}
logged_global 'npm_config_global=true npm install evil' || fail "control: a global npm install is recorded as landing in the global prefix"
for assigned in \
  'if true; then npm_config_global=true npm install evil; fi' \
  '{ npm_config_global=true npm install evil; }' \
  'f() { npm_config_global=true npm install evil; }; f'
do
  shard_row "assigned: ${assigned}" || continue
  logged_global "${assigned}" || fail "an assignment stays with its install at a statement start: ${assigned}"
done
# A start is written into a view of its own, never over the bytes another
# reader matches: written into the scan view, `| { sh; }` became `| {;sh; }`
# and the pipe into a shell was no longer one.
expect_deny "a pipe into a brace group in a function body" "f() { printf 'pip install evil==1.0.0' | { sh; }; }; f"
# The `{` after a function name list is the start, however many names.
expect_not_approved "a function with three names" 'function f g h { pip install evil==1.0.0; }; f'
# The first `(` of an arithmetic word is a separator to the word walk, so the
# word starts at the second one; matched as `((` the test before a body was
# read as a command, and the body opened nothing. And a separator at the top of
# the arithmetic cuts no statement.
expect_not_approved "a body after an arithmetic test" 'if ((1)) { pip install evil==1.0.0; }'
expect_not_approved "an empty arithmetic for" 'for (( ; ; )) { pip install evil==1.0.0; break; }'
# A pinned npm install behind a redirection is read and its spec checked.
expect_not_approved "an npm install behind a redirection" '2>&1 npm install evil@1.0.0'
expect_not_approved "an npm install in a loop after function NAME" 'function f while npm install evil@1.0.0; do break; done; f'
# An install with `&>` after it is one in every shell, judged as before the
# dash reading split it there.
expect_not_approved "an install with &> at its end" 'pip install evil==1.0.0 &>/dev/null'
expect_not_approved "an install after a command ended by &> and ;" 'echo a &>/dev/null; pip install evil==1.0.0'
pass "statement starts are read from the shell grammar, and the same words in an argument open nothing"

# A prefix's own options, as the manuals give them: `--` ends the options of
# `command` and `exec`, and exec clusters `-c`, `-l` and `-a NAME` the way
# getopt does, so `-aa` is the name `a`. The word after `--` was read as the
# command, and `-aa` took the command as its name: each passed with no check
# (main and 83de40c). The bits are macOS bash 3.2, zsh 5.9, sh and dash,
# measured with touch in place of the install (exec -c clears PATH, and
# command -p looks on the default path, so a stub on PATH says nothing); the
# generated grid holds every option set (scripts/measure/redirection-grid.sh,
# the RP forms).
for precmd_row in \
  '1111|command --' '1111|command -p --' '1111|command -pp' '1110|exec --' '1110|exec -aa' \
  '1110|exec -c --' '1110|exec -a x --' '1110|exec -a -- --' '1111|command -- command' \
  '1011|command -- exec' '1111|exec command --' '1110|exec -- env' '0100|exec -- noglob' \
  '0100|noglob command --' '1011|time -p command --'
do
  expect_not_approved "${precmd_row#*|} before an install (${precmd_row%%|*})" "${precmd_row#*|} pip install evil==1.0.0"
done
for inert_form in 'command -- npm ci' 'exec -- npm ci' 'exec -aa npm ci' 'command -pp npm ci'; do
  shard_row "inert_form: ${inert_form}" || continue
  rewrite_holds "${inert_form}" "${inert_form} --ignore-scripts" \
    || fail "an npm install behind ${inert_form% npm ci} gets --ignore-scripts (got: $(gate_rewrite "${inert_form}"))"
done
# `command -v` and `-V` only say what the word is (0000 measured).
for decoy in 'command -v pip install evil==1.0.0' 'command -V pip install evil==1.0.0' \
  'echo command -- pip install evil==1.0.0' 'echo exec -aa pip install evil==1.0.0'; do
  expect_pass "${decoy}" "${decoy}"
done
pass "the options of command and exec end where the manuals end them, and the command after them is read"

# What follows the `))` of an arithmetic command or a `for ((...))` header is
# a word of its own: bash and zsh read `((...))` as a token. A `{`, a `do` or
# a subshell glued to it was read as more of the header, and the install in
# the body passed with no check. zsh runs a subshell glued to the word list of
# `for NAME (WORDS)` too, which the lexer read as a glob qualifier, and bash
# and zsh run a subshell first inside a process substitution, which the lexer
# read as `((` arithmetic. All in main and 83de40c. The bits are macOS bash
# 3.2, zsh 5.9, sh and dash, measured with a marker function in place of pip;
# the generated grid holds the places (RC, RZ and RF forms).
for close_row in \
  '1110|for ((i=0;i<1;i++)){ pip install evil==1.0.0;}' \
  '1110|for ((i=0;i<1;i++))do pip install evil==1.0.0; done' \
  '1110|for ((i=0;i<1;i++)){(pip install evil==1.0.0);}' \
  '0100|for ((i=0;i<1;i++)) pip install evil==1.0.0' \
  '0100|for i (1)(pip install evil==1.0.0)' \
  '1100|cat <((pip install evil==1.0.0))'
do
  expect_not_approved "${close_row#*|} (${close_row%%|*})" "${close_row#*|}"
done
for inert_form in 'for ((i=0;i<1;i++)){(npm ci);}' 'for i (1)(npm ci)' 'cat <((npm ci))'; do
  shard_row "inert_form: ${inert_form}" || continue
  rewrite_holds "${inert_form}" "${inert_form/npm ci/npm ci --ignore-scripts}" \
    || fail "an npm install after a closed head gets --ignore-scripts: ${inert_form} (got: $(gate_rewrite "${inert_form}"))"
done
# dash reads `((` as two subshells, so it puts these installs elsewhere, and no
# one rewrite is inert for every shell: UNDECIDED, as for the other forms only
# some shells parse.
expect_undecided "an npm install after for ((...)){" 'for ((i=0;i<1;i++)){ npm ci;}'
expect_pass "an arithmetic expansion before an install's words" 'echo $((1+2)) pip install evil==1.0.0'
expect_pass "for ((...)) as an argument" 'echo for ((i=0;i<1;i++)) pip install evil==1.0.0'
pass "a word glued after a closed arithmetic head, list or process substitution is read as the body"

# The inert rewrite reaches an npm install at every new start, under the rule
# every rewrite follows: the text changes only where every reading puts the
# npm installs in the same place. Measured on the release before this: the zsh
# `for i (1)` form got no rewrite and no verdict, so its lifecycle scripts ran.
# Every reading parses these and reads the install at the same start.
for inert_form in \
  'function f { (npm install evil); }; f' \
  'time -p { npm install evil; }' \
  'case x in x) { npm install evil; };; esac' \
  'f() { npm install evil; }; f' \
  'for i in 1; { npm install evil; }' \
  'time { npm install evil; }' \
  '! { npm install evil; }' \
  '2>&1 npm install evil' \
  'function f while npm install evil; do break; done; f' \
  'npm install evil &>/dev/null'
do
  shard_row "inert_form: ${inert_form}" || continue
  rewrite_holds "${inert_form}" "${inert_form/npm install/npm install --ignore-scripts}" \
    || fail "an npm install at a statement start gets --ignore-scripts: ${inert_form} (got: $(gate_rewrite "${inert_form}"))"
done
# A verb ends where the shell ends its word, which is the lexer's to say
# (SAFEDEPS_G_END): a `;`, an operator or a parenthesis right after it ends
# it as a blank does. The recognizers ended a verb only at a blank or the end
# of the text, so each of these was no install at all: no check, no
# --ignore-scripts, no pending state (v2.17.2 to 83de40c). Each runs `npm ci`
# in macOS bash 3.2, zsh 5.9, sh and dash, measured with a function in place
# of npm that writes a marker file.
for inert_form in \
  'npm ci;' 'npm ci;echo' 'npm ci&&echo' 'npm ci||echo' 'npm ci|cat' 'npm ci&' 'npm ci&wait' \
  '(npm ci)' '{ npm ci;}' 'if true; then npm ci; fi' 'while npm ci;do break; done' \
  'npm ci>/dev/null' 'npm ci</dev/null' 'npm ci&>/dev/null' 'npm ci>&2' 'case x in x) npm ci;; esac' \
  'x=$(npm ci)' 'echo $(npm ci)'
do
  shard_row "inert_form: ${inert_form}" || continue
  rewrite_holds "${inert_form}" "${inert_form/npm ci/npm ci --ignore-scripts}" \
    || fail "an npm verb ended by what follows it gets --ignore-scripts: ${inert_form} (got: $(gate_rewrite "${inert_form}"))"
done
expect_not_approved "an npm install ended by ; is checked" 'npm install evil@1.0.0;'
expect_not_approved "an npm install ended by ) is checked" '(npm install evil@1.0.0)'
expect_not_approved "a yarn add ended by ) is checked" '(yarn add evil@1.0.0)'
for decoy in 'echo npm ci;' 'echo "npm ci;"' 'npm cix;' 'npm ci_x' "echo 'npm ci&&x'"; do
  expect_pass "${decoy}" "${decoy}"
done
# dash ends the install at the `&` of `&>`, and the rewrite lands after the
# verb in every reading, so the edit is the same one it was.
rewrite_holds 'npm ci &>/dev/null && npm run build' 'npm ci --ignore-scripts &>/dev/null && npm run build' \
  || fail "an npm ci with &> after it gets --ignore-scripts (got: $(gate_rewrite 'npm ci &>/dev/null && npm run build'))"
# Only some shells parse these, so a reading finds no install where another
# does, and no single text is inert for every shell: UNDECIDED, with the
# readings reason, never a rewrite for one shell.
for inert_form in \
  'for i (1) { npm install evil; }' \
  'repeat 1 { npm install evil; }' \
  'for ((i=0;i<1;i++)) { npm install evil; }' \
  'coproc foo { npm install evil; }; wait' \
  'coproc foo until npm install evil; do :; done; wait' \
  'echo a &>/dev/null npm install evil'
do
  shard_row "inert_form: ${inert_form}" || continue
  got=$(gate_reason "${inert_form}")
  [[ "${got}" == "deny "*UNDECIDED*"read the npm installs in this command in different places"* ]] \
    || fail "an npm install at a start only some shells read is UNDECIDED, not rewritten for one: ${inert_form} (got: ${got:0:120})"
done
# The npm forms of the starts with no byte of their own (verdict
# howl-20261004-084050): every shell runs the first two, which got no
# --ignore-scripts and no record before, and zsh alone the last two, where no
# one text is inert for every shell.
for inert_form in 'if true; then>/dev/null npm ci; fi' 'for d in a b; do>/dev/null npm ci; done'; do
  shard_row "inert_form: ${inert_form}" || continue
  rewrite_holds "${inert_form}" "${inert_form/npm ci/npm ci --ignore-scripts}" \
    || fail "an npm install glued behind a reserved word and a redirection gets --ignore-scripts: ${inert_form} (got: $(gate_rewrite "${inert_form}"))"
done
for inert_form in '{2>/dev/null npm ci; }' 'true&!npm ci'; do
  shard_row "inert_form: ${inert_form}" || continue
  got=$(gate_reason "${inert_form}")
  [[ "${got}" == "deny "*UNDECIDED*"read the npm installs in this command in different places"* ]] \
    || fail "an npm install at a start only zsh reads is UNDECIDED, not rewritten for one shell: ${inert_form} (got: ${got:0:120})"
done
pass "the inert rewrite reaches an npm install at every statement start the readings agree on, and is UNDECIDED where they do not"

# A redirection between npm and its verb, a {varname} or a process
# substitution target before it: the rewrite finds the verb in the live view,
# where the redirection is blank, and puts the flag after it in the command as
# written. Before, none of these was an install to the recognizers, and npm
# ran the lifecycle scripts. A process substitution body is code the shell
# runs, so its npm install gets the flag where it stands.
for rewrite_row in \
  'npm 2>/dev/null install evil|npm 2>/dev/null install --ignore-scripts evil' \
  'npm >/dev/null install evil|npm >/dev/null install --ignore-scripts evil' \
  'npm {fd}>/dev/null install evil|npm {fd}>/dev/null install --ignore-scripts evil' \
  '< <(true) npm install evil|< <(true) npm install --ignore-scripts evil' \
  '> >(cat) npm install evil|> >(cat) npm install --ignore-scripts evil' \
  'cat <(npm install evil)|cat <(npm install --ignore-scripts evil)' \
  'npm install evil > >(npm install other)|npm install --ignore-scripts evil > >(npm install --ignore-scripts other)'
do
  shard_row "rewrite_row: ${rewrite_row}" || continue
  rewrite_holds "${rewrite_row%%|*}" "${rewrite_row#*|}" || fail "the rewrite lands after the verb: ${rewrite_row%%|*} (got: $(gate_rewrite "${rewrite_row%%|*}"))"
done
# bash 5 runs `{fd}>/dev/null npm install x` with a descriptor in fd; zsh
# reads the `{` glued to the first word as a group opener, so the command is
# `fd}` and the install does not run (measured: zsh runs no V-row). The
# readings put the install in different places: UNDECIDED, never a rewrite
# for one shell. zsh's reading of the descriptor word used to disagree with
# its own walk and find the install anyway.
got=$(gate_reason '{fd}>/dev/null npm install evil')
[[ "${got}" == "deny "*UNDECIDED*"read the npm installs in this command in different places"* ]] \
  || fail "an npm install behind {fd} that only bash 5 runs is UNDECIDED, not rewritten for one shell (got: ${got:0:120})"
# A redirection target is no flag. `--ignore-scripts` as the file stdout goes
# to read as an install that already had the flag, so it got no rewrite and
# npm ran the lifecycle scripts (v2.18.0 and before). The flag goes in after
# the verb, and the target stays the target.
got=$(gate_rewrite 'npm install evil > --ignore-scripts')
[[ "${got}" == 'npm install --ignore-scripts evil'* && "${got}" == *' > --ignore-scripts'* ]] \
  || fail "a redirection target named --ignore-scripts is not the flag (got: ${got})"
pass "the inert rewrite finds an npm verb behind a redirection, and a redirection target is not the flag"

# A redirection whose target holds a substitution, between npm and its verb.
# The rewrite read only the live view, which keeps the body of that
# substitution because the shell runs it, so npm and its verb were not side
# by side, no verb was found, and the command passed as written: no flag, no
# record, and the lifecycle scripts ran (every shell measured runs each of
# these; main and v2.18.0 before this). The rewrite now also reads the view
# with the redirection blanked whole. An npm install inside the body still
# gets its own flag, and another manager's install there is still a payload.
for rewrite_row in \
  'npm >$(echo f) install evil|npm >$(echo f) install --ignore-scripts evil' \
  'npm >`echo f` install evil|npm >`echo f` install --ignore-scripts evil' \
  'npm >"$(echo f)" install evil|npm >"$(echo f)" install --ignore-scripts evil' \
  'npm 2>$(echo f) install evil|npm 2>$(echo f) install --ignore-scripts evil' \
  'npm >$(echo f) ci|npm >$(echo f) ci --ignore-scripts' \
  'npm 2>/dev/null install evil|npm 2>/dev/null install --ignore-scripts evil' \
  'x=$(echo f) npm >$(echo g) install evil|x=$(echo f) npm >$(echo g) install --ignore-scripts evil' \
  'npm >$(echo f) install evil && npm >$(echo g) ci|npm >$(echo f) install --ignore-scripts evil && npm >$(echo g) ci --ignore-scripts' \
  'npm >$(npm install y) install x|npm >$(npm install --ignore-scripts y) install --ignore-scripts x' \
  'npm install x >$(npm install y)|npm install --ignore-scripts x >$(npm install --ignore-scripts y)'
do
  shard_row "rewrite_row: ${rewrite_row}" || continue
  rewrite_holds "${rewrite_row%%|*}" "${rewrite_row#*|}" || fail "the rewrite finds the verb behind a redirection whose target is a substitution: ${rewrite_row%%|*} (got: $(gate_rewrite "${rewrite_row%%|*}"))"
done
expect_not_approved "a pip install behind a redirection whose target is a substitution" 'pip >$(echo f) install evil==1.0.0'
expect_not_approved "an install inside the target's substitution is still a payload" 'npm >$(pip install evil==1.0.0) install x'
for plain in 'npm >$(echo f) run build' 'echo npm >$(echo f) install evil' 'npm >$(echo f) install --ignore-scripts evil'; do
  expect_pass "no install to rewrite behind a substitution target: ${plain}" "${plain}"
  ! shard_row "no rewrite: ${plain}" || [[ -z "$(gate_rewrite "${plain}")" ]] \
    || fail "no rewrite for ${plain} (got: $(gate_rewrite "${plain}"))"
done
pass "the inert rewrite finds an npm verb behind a redirection whose target holds a substitution"

# A heredoc inside a substitution is part of that substitution's word. Read
# as a word end, the heredoc operator cut the target of a redirection between
# npm and its verb at the `<<`, and the rest of the target stood between them:
# no rewrite, no record, and the lifecycle scripts ran (every shell runs these;
# main and 83de40c).
for rewrite_row in \
  $'npm >$(cat <<E\nx\nE\n) install evil|npm >$(cat <<E\nx\nE\n) install --ignore-scripts evil' \
  $'npm >$(cat <<\'E\'\nx\nE\n) install evil|npm >$(cat <<\'E\'\nx\nE\n) install --ignore-scripts evil' \
  $'npm >"$(cat <<E\nx\nE\n)" install evil|npm >"$(cat <<E\nx\nE\n)" install --ignore-scripts evil' \
  $'npm ci >$(cat <<E\nx\nE\n)|npm ci --ignore-scripts >$(cat <<E\nx\nE\n)'
do
  shard_row "rewrite_row: ${rewrite_row}" || continue
  rewrite_holds "${rewrite_row%%|*}" "${rewrite_row#*|}" || fail "the rewrite finds the verb behind a target whose substitution holds a heredoc: ${rewrite_row%%|*} (got: $(gate_rewrite "${rewrite_row%%|*}"))"
done
expect_not_approved "a pip install behind a target whose substitution holds a heredoc" $'pip >$(cat <<E\nx\nE\n) install evil==1.0.0'
expect_not_approved "an install after an assignment whose value holds a heredoc" $'x=$(cat <<E\nx\nE\n) pip install evil==1.0.0'
expect_not_approved "an install after a top-level heredoc body" $'cat <<E\nx\nE\npip install evil==1.0.0'
expect_pass "an install written in a heredoc body inside a substitution is data" $'echo $(cat <<E\npip install evil==1.0.0\nE\n)'
pass "a heredoc inside a substitution is part of that word, and the rewrite finds the verb after it"

# A path before an executable reads as the executable, wherever the path
# points and whatever stands around the word: the lexer reads it at each
# command start. A sed read only an absolute path, after a byte of its own
# start set and before a byte of its own end set, so each of these passed with
# no check (main and 83de40c); a relative path was never read at all. Every
# one runs its install in macOS bash 3.2, zsh 5.9, sh and dash, measured with
# a stub pip in a .venv of the test directory.
for path_form in \
  '.venv/bin/pip install evil==1.0.0' '$VENV/bin/pip install evil==1.0.0' '"$VENV"/bin/pip install evil==1.0.0' \
  'case x in x)./.venv/bin/pip install evil==1.0.0;; esac' './.venv/bin/pip>/dev/null install evil==1.0.0' \
  '/usr/bin/env .venv/bin/pip install evil==1.0.0' '/usr/bin/env pip install evil==1.0.0' \
  'case x in x)/usr/bin/pip install evil==1.0.0;; esac' '/usr/bin/pip>/dev/null install evil==1.0.0' \
  '../x/npm install evil@1.0.0'
do
  expect_not_approved "a manager named by a path: ${path_form}" "${path_form}"
done
rewrite_holds 'node_modules/.bin/npm ci' 'node_modules/.bin/npm ci --ignore-scripts' \
  || fail "an npm named by a relative path gets --ignore-scripts (got: $(gate_rewrite 'node_modules/.bin/npm ci'))"
for decoy in 'echo .venv/bin/pip install evil==1.0.0' 'ls /usr/bin/pip' '/opt/pip/bin/tool install x' '.venv/bin/pipx-foo install x'; do
  expect_pass "${decoy}" "${decoy}"
done
pass "a manager named by any path is read as that manager at every command start"

# env reads its own options before the command: -u, -C and -P take a value,
# and -S (--split-string in GNU env) splits its string into the command and
# runs it with the words after it. `env -P /usr/bin pip install x` read
# /usr/bin as the command, and every -S form passed; each runs in macOS bash
# 3.2, zsh 5.9, sh and dash (measured with touch in place of the install;
# --split-string is GNU only, and the Linux columns of the grid hold it). The
# -S string is read as a script, like the words after eval; one whose value
# is decided at run time cannot be, and is a recorded failed reading.
for env_form in \
  'env -P /usr/bin pip install evil==1.0.0' "env -S 'pip install evil==1.0.0'" "env -S'pip install evil==1.0.0'" \
  "env -iS 'pip install evil==1.0.0'" "env -S 'pip install' evil==1.0.0" "/usr/bin/env -S 'pip install evil==1.0.0'" \
  "env --split-string='pip install evil==1.0.0'" 'env -u X pip install evil==1.0.0' 'env -i -- pip install evil==1.0.0' \
  '/usr/bin/env -- pip install evil==1.0.0' 'env -uS pip install evil==1.0.0'
do
  expect_not_approved "env with its options before an install: ${env_form}" "${env_form}"
done
expect_undecided "an env -S string decided at run time, beside a manager" 'env -S "$X" pip'
got=$(gate_reason 'env -S "$X"')
[[ "${got}" == "pass"* ]] || fail "an env -S string decided at run time with no manager named runs, recorded (got: ${got:0:80})"
pass "env reads its options before the command, and its -S string is read as a script"

# Whether a word is a shell is one closed list (SAFEDEPS_G_SHELLS), read by
# the `-c` script reader, the pipe check and the path in front of a shell. The
# pipe check knew bash, sh and zsh, and did not read `time`, so these passed
# while every shell measured (macOS bash 3.2, zsh 5.9, sh, dash; touch in
# place of the install) runs them; `| time -p sh` runs in all but zsh. The
# `-c` reader took any name ending in sh, ssh among them; the list keeps it
# out, and the ssh forms read as they did.
for pipe_form in \
  "printf 'pip install evil==1.0.0' | dash" "printf 'pip install evil==1.0.0' | ksh" \
  "printf 'pip install evil==1.0.0' | csh" "printf 'pip install evil==1.0.0' | /bin/dash" \
  "printf 'pip install evil==1.0.0' | time sh" "printf 'pip install evil==1.0.0' | time -p sh"
do
  shard_row "pipe_form: ${pipe_form}" || continue
  [[ "$(gate_decision "${pipe_form}")" == deny ]] || fail "install text piped into a shell is denied: ${pipe_form}"
done
for shell_c in ksh csh tcsh fish zsh /bin/dash; do
  expect_not_approved "${shell_c} -c with an install" "${shell_c} -c 'pip install evil==1.0.0'"
done
expect_not_approved "a shell -c behind ssh, read as before" "ssh host sh -c 'pip install evil==1.0.0'"
for same in "printf 'pip install evil==1.0.0' | ssh host" "printf 'pip install evil==1.0.0' | ssh host sh" \
  "ssh -c aes128-ctr host 'pip install evil==1.0.0'" "echo hello | sh"; do
  expect_pass "${same}" "${same}"
done
pass "one list of shells for the -c reader, the pipe check and a path, and time read as a prefix"
# time's options: `-p` to the reserved word, and in dash, where time is
# /usr/bin/time, its options up to `--`, with -o and -f taking a value. Read
# as a prefix that dropped only `-p`, `time -- pip install x` put `--` where
# the command stands. Bits: macOS bash 3.2, zsh -f, sh, dash.
for time_row in '0001|time --' '0001|time -p --' '0001|time -o out' '0001|time -l' '1011|time -p'; do
  expect_not_approved "${time_row#*|} before an install (${time_row%%|*})" "${time_row#*|} pip install evil==1.0.0"
done
pass "time reads its options as the walk does"
# zsh reads a `{` glued to the first word of a command as the group opener:
# `{pip install x; }` runs the install in zsh alone (0100: macOS bash 3.2,
# zsh -f, sh, dash); bash reads one word `{pip` and fails. A brace expansion
# and a `{` inside a word stay words.
for brace_form in '{pip install evil==1.0.0; }' '{pip install evil==1.0.0;}' '{{ pip install evil==1.0.0; }; }' '{! pip install evil==1.0.0; }'; do
  expect_not_approved "a zsh group glued to its first word: ${brace_form}" "${brace_form}"
done
for decoy in 'x{pip install evil==1.0.0; }' 'echo {pip,x}'; do
  expect_pass "${decoy}" "${decoy}"
done
pass "a group glued to its first word is read in the zsh reading"
# A command glued to the `)` that closes a head (zsh only, 0100: `for i
# (1)pip install x`, `for ((...))pip install x`, `if ((1))pip install x`) has
# no blank before it, so the stmts view writes the start over that `)` (each
# passed in main and 83de40c).
for glued_form in 'for i (1)pip install evil==1.0.0' 'for i j (1 2)pip install evil==1.0.0' \
  $'foreach i (1)pip install evil==1.0.0\nend' 'for ((i=0;i<1;i++))pip install evil==1.0.0' 'if ((1))pip install evil==1.0.0'; do
  expect_not_approved "a command glued to a closed head: ${glued_form}" "${glued_form}"
done
expect_not_approved "then glued to an arithmetic head is still a reserved word" 'if ((1))then pip install evil==1.0.0; fi'
expect_pass "a word glued to an arithmetic expansion" 'echo $((1))x'
pass "a command glued to a closed head is read"
# zsh reads a subshell or an arithmetic command as the condition of a short
# `if` with the body right after it, so its close is a head close too (0100):
# a subshell or a command glued there starts the body.
expect_not_approved "a subshell glued to a short if's arithmetic condition" 'if ((1))(pip install evil==1.0.0)'
expect_not_approved "a subshell glued to a short if's subshell condition" 'if (true)(pip install evil==1.0.0)'
expect_not_approved "a command glued to a short if's subshell condition" 'if (true)pip install evil==1.0.0'
expect_not_approved "then glued to a subshell condition" 'if (true)then pip install evil==1.0.0; fi'
pass "the condition of a zsh short if closes a head"
# An arithmetic command that is no head closes none: zsh closes
# `((echo "a))b") )` early and parses none of it, while bash runs the line
# after it. Failing zsh's reading there made the whole command UNDECIDED
# (shell-reading form B1 caught it).
expect_not_approved "an install after a (( only bash reads" $'((echo "a))b") )\n# it\'s\n((1<<2))\npip install evil==1.0.0\n2\n# \' ))'

# More places the review of 83de40c found: more places
# after a closed head, a subshell first in more process substitutions, more
# exec clusters, and two case arms that were UNDECIDED, now read (a subshell
# glued to a case pattern close is a start like any other). Bits: macOS bash
# 3.2, zsh 5.9 with no startup files (zsh -f), sh, dash, with a stub pip on
# PATH. Every place of this kind is in the generated grid (RL forms).
expect_not_approved 'for ((x=1;x;x--)){ pip install evil==1.0.0;} (1110)' 'for ((x=1;x;x--)){ pip install evil==1.0.0;}'
expect_not_approved 'for ((i=0;i!=1;i++)){ pip install evil==1.0.0;} (1110)' 'for ((i=0;i!=1;i++)){ pip install evil==1.0.0;}'
expect_not_approved 'for ((i=0; i<1; i++)){ pip install evil==1.0.0;} (1110)' 'for ((i=0; i<1; i++)){ pip install evil==1.0.0;}'
expect_not_approved 'for ((i=0;i<1;i++))(pip install evil==1.0.0) (0100)' 'for ((i=0;i<1;i++))(pip install evil==1.0.0)'
expect_not_approved 'foreach i (1)(pip install evil==1.0.0) NL end (0100)' $'foreach i (1)(pip install evil==1.0.0)\nend'
expect_not_approved 'for i j (1 2)(pip install evil==1.0.0) (0100)' 'for i j (1 2)(pip install evil==1.0.0)'
expect_not_approved 'for i (1){(pip install evil==1.0.0)} (0100)' 'for i (1){(pip install evil==1.0.0)}'
expect_not_approved 'diff <((pip install evil==1.0.0)) /dev/null (1100)' 'diff <((pip install evil==1.0.0)) /dev/null'
expect_not_approved 'cat < <((pip install evil==1.0.0)) (1100)' 'cat < <((pip install evil==1.0.0))'
expect_not_approved 'tee >((pip install evil==1.0.0)) </dev/null (1100)' 'tee >((pip install evil==1.0.0)) </dev/null'
expect_not_approved 'x=<((pip install evil==1.0.0)) true (1100)' 'x=<((pip install evil==1.0.0)) true'
expect_not_approved 'cat =((pip install evil==1.0.0)) (0100)' 'cat =((pip install evil==1.0.0))'
expect_not_approved 'case a in b) :;; *)(pip install evil==1.0.0);; esac (1111)' 'case a in b) :;; *)(pip install evil==1.0.0);; esac'
expect_not_approved 'case a in a) :;& b)(pip install evil==1.0.0);; esac (0100)' 'case a in a) :;& b)(pip install evil==1.0.0);; esac'
expect_not_approved 'exec -axa pip install evil==1.0.0 (1110)' 'exec -axa pip install evil==1.0.0'
expect_not_approved 'exec -ala pip install evil==1.0.0 (1110)' 'exec -ala pip install evil==1.0.0'
expect_not_approved 'exec -a x -- pip install evil==1.0.0 (1110)' 'exec -a x -- pip install evil==1.0.0'
expect_not_approved 'exec -l -- pip install evil==1.0.0 (1110)' 'exec -l -- pip install evil==1.0.0'
expect_not_approved 'builtin command -- pip install evil==1.0.0 (1110)' 'builtin command -- pip install evil==1.0.0'
pass "the places the review named are read, each in the shells that run it"

# Plain process substitutions and redirections around commands that install
# nothing stay unjudged and unrecorded, as before.
for plain in \
  'diff <(sort a) <(sort b)' \
  'while read l; do echo "$l"; done < <(ls)' \
  'tee >(wc -l) < /dev/null' \
  'cat < <(printf "%s\n" "pip install evil==1.0.0")' \
  'echo pip 2>/dev/null install evil==1.0.0' \
  'echo {fd}>/dev/null pip install evil==1.0.0' \
  'echo a2>/dev/null pip install evil==1.0.0' \
  'grep -r "npm install" . 2>/dev/null' \
  'npm run build 2>&1' \
  'pip --version 2>/dev/null' \
  'echo "2>/dev/null pip install evil==1.0.0"' \
  $'cat <<EOF\npip install evil==1.0.0\nEOF'
do
  expect_pass "a redirection or a process substitution with no install: ${plain}" "${plain}"
  if shard_row "no UNGATED record: ${plain}" && logged_ungated "${plain}"; then fail "no UNGATED record for ${plain}"; fi
done
pass "plain process substitutions and redirections stay unjudged and unrecorded"

# An assignment prefix is one word however its value is quoted or nested. The
# prefix stripper read a value as the bytes up to the first blank or quote, so
# each of these kept its prefix and the install after it was never recognized:
# a pinned install with no verdict and no record (caught in review).
for prefixed in \
  'FOO="a b" pip install evil==1.0.0' \
  "FOO='a b' pip install evil==1.0.0" \
  'FOO="a;b" pnpm add evil@1.0.0' \
  'FOO=$(printf x) pip install evil==1.0.0' \
  'FOO=`printf x` pip install evil==1.0.0' \
  'FOO=a\ b pip install evil==1.0.0' \
  'FOO=${BAR:-a b} pip install evil==1.0.0' \
  'env FOO="a b" pip install evil==1.0.0' \
  'env -u HOME FOO="a b" pip install evil==1.0.0' \
  'A="1 2" B=$(echo x y) cargo install evil --version 1.0.0' \
  'ls; FOO="a b" pip install evil==1.0.0' \
  'if true; then FOO="a b" pip install evil==1.0.0; fi' \
  'FOO="a b" pip install evil==1.0.0; echo $((1<<2))' \
  'FOO="a b" pip install evil==1.0.0 '"'"
do
  expect_deny "an install behind a whitespace-valued assignment: ${prefixed}" "${prefixed}"
done
# What the prefix reader must not invent: an install named only inside a quoted
# value is data, and an install inside a substitution in a value is still read.
expect_pass "an install named only in an assignment value" 'FOO="pip install evil==1.0.0" echo hi'
expect_deny "an install inside a substitution in an assignment value" 'FOO=$(pip install evil==1.0.0) ls'
pass "an install behind an assignment prefix is gated however the value is quoted or nested"

# Where a word ends is the lexer walk's depth and nothing else. The shell's
# grammar puts parentheses inside words -- an array value, a glob group or
# qualifier, a process substitution, zsh `=(...)` -- and the walk reads each
# as a context, so a blank or an operator inside ends nothing, and the `)` of
# a case pattern ends a word only at the top level. A reader that cut words
# by a byte set of its own cut each of these short, and what followed was a
# statement no recognizer read: `a=(x) pip install ...` ran in bash and zsh
# with `x)` as the command to the gate (denied on main, passed from the day
# the lexer read the prefixes).
#
# Each row: an id, then whether each shell ran its install (1) or not (0), in
# the order macOS bash 3.2, zsh 5.9, macOS sh, dash, the agent's wrapper as
# it is now (zsh, the shell snapshot, `setopt NO_EXTENDED_GLOB
# NO_BARE_GLOB_QUAL`, eval), that wrapper without the setopt, GNU bash 5.2.
# Measured on 2026-10-03 by running each form in each shell with a stub in
# the manager's place that marks only an argument naming the package.
word_rows=(
  # An array value, an append and an array element are assignment words
  # (bash Arrays, zsh Array Parameters). Blanks, comments, newlines, quotes and
  # substitutions among the elements end no word. dash has no arrays. A blank
  # inside a subscript is part of the word to bash alone (WA18), as are keys
  # in an array value (WA12).
  'WA1|1110111|a=(x) pip install evil==1.0.0'
  'WA2|1110111|a=(x) 2>/dev/null pip install evil==1.0.0'
  'WA3|1110111|a=(x y) b=1 pip install evil==1.0.0'
  'WA4|1110111|a=() pip install evil==1.0.0'
  'WA5|1110111|a+=(x) pip install evil==1.0.0'
  'WA6|1110111|a=(x) npm install evil@1.0.0'
  'WA7|1110111|a[1]=x pip install evil==1.0.0'
  'WA8|1110111|a[1]=x 2>/dev/null pip install evil==1.0.0'
  'WA9|1110111|a=( x y ) pip install evil==1.0.0'
  $'WA10|1110111|a=(x # c\ny) pip install evil==1.0.0'
  $'WA11|1110111|a=(\nx\n) pip install evil==1.0.0'
  'WA12|1010001|a=([0]=x [1]=y) pip install evil==1.0.0'
  'WA13|1110111|a=($(echo x)) pip install evil==1.0.0'
  $'WA14|1110111|a=("x y" \'z\') pip install evil==1.0.0'
  'WA15|1110111|a+=x pip install evil==1.0.0'
  'WA16|1110111|a[1]+=x pip install evil==1.0.0'
  'WA17|1110111|a[$(echo 1)]=x pip install evil==1.0.0'
  'WA18|1010001|a[1 + 1]=x pip install evil==1.0.0'
  'WA19|1110111|a=(x) b+=(y) c[2]=z pip install evil==1.0.0'
  'WA20|1110111|echo a; a=(x) pip install evil==1.0.0'
  'WA21|1110111|f() { a=(x) pip install evil==1.0.0; }; f'
  $'WA22|1110111|a=(x)\\\n pip install evil==1.0.0'
  'WA23|1110111|a=(x) command pip install evil==1.0.0'
  'WA24|1110111|x=(a b) pip install evil==1.0.0'
  'WA25|1110111|a=(x);pip install evil==1.0.0'
  # The `)` of a case pattern inside a substitution ends no word: the value
  # or the target runs on to the close of the substitution. bash 3.2 does
  # not parse an unparenthesized pattern there; it runs the ones that are
  # quoted, parenthesized or in backquotes.
  'WC1|0101111|echo $(case a in a) echo f;; esac); pip install evil==1.0.0'
  'WC2|0101111|x=$(case a in a) echo f;; esac) pip install evil==1.0.0'
  'WC3|0101111|>$(case a in a) echo f;; esac) pip install evil==1.0.0'
  'WC4|0101111|2>$(case a in a) echo /dev/null;; esac) pip install evil==1.0.0'
  'WC5|0101111|pip >$(case a in a) echo f;; esac) install evil==1.0.0'
  'WC6|1111111|>"$(case a in a) echo f;; esac)" pip install evil==1.0.0'
  'WC7|1111111|x="$(case a in a) echo f;; esac)" pip install evil==1.0.0'
  'WC8|1111111|>$(case a in (a) echo f;; esac) pip install evil==1.0.0'
  'WC9|0101111|echo $(case a in a) echo f;; esac) && pip install evil==1.0.0'
  'WC10|1111111|>`case a in a) echo f;; esac` pip install evil==1.0.0'
  'WC11|0100111|< <(case a in a) true;; esac) pip install evil==1.0.0'
  'WC12|0100111|cat <(case a in a) pip install evil==1.0.0;; esac)'
  'WC13|0101111|>$(case a in a) echo f;; esac) npm install evil@1.0.0'
  'WC14|0000001|{fd}>$(case a in a) echo f;; esac) pip install evil==1.0.0'
  'WC15|0101111|x=$(case a in a) echo;; esac)$(case b in b) echo;; esac) pip install evil==1.0.0'
  'WC16|1111111|x=${y:-$(case a in a) echo;; esac)} pip install evil==1.0.0'
  'WC17|0100111|<<<$(case a in a) echo;; esac) pip install evil==1.0.0'
  'WC18|1111111|x=`case a in a) echo;; esac` pip install evil==1.0.0'
  'WC19|0101111|x=$(case a in *) echo;; esac) npm install evil@1.0.0'
  # zsh `=(...)` is a process substitution through a temporary file, a word
  # wherever a word may stand, and its body runs.
  'WZ1|0100110|< =(true) pip install evil==1.0.0'
  'WZ2|0100110|cat =(pip install evil==1.0.0)'
  'WZ3|0100110|> =(true) pip install evil==1.0.0'
  'WZ4|0100110|2>/dev/null =(true) ; pip install evil==1.0.0'
  'WZ5|0100110|cat =(true; pip install evil==1.0.0)'
  'WZ6|0100110|>=(true) pip install evil==1.0.0'
  'WZ7|0100110|>>=(true) pip install evil==1.0.0'
  'WZ8|0100110|exec 3<=(true) pip install evil==1.0.0'
  'WZ9|0100110|cat =(echo x) =(echo y); pip install evil==1.0.0'
  # A glob group or qualifier glued to a redirection target is part of the
  # word in zsh. The agent wrapper turns bare qualifiers off, and then runs
  # the group form zsh without the setopt does not (WG4).
  'WG1|0100010|>/dev/null(N) pip install evil==1.0.0'
  'WG2|0100010|2>/dev/nul*(N) pip install evil==1.0.0'
  'WG3|0100010|</dev/null(N) pip install evil==1.0.0'
  'WG4|0000100|>/dev/(null) pip install evil==1.0.0'
  'WG5|0100110|2>/dev/(null|zero) pip install evil==1.0.0'
  'WG6|0100010|>/dev/null(N) npm install evil@1.0.0'
  'WG7|0100010|pip >/dev/null(N) install evil==1.0.0'
  'WG8|0100010|echo a; >/dev/null(N) pip install evil==1.0.0'
  'WG9|0100010|f() { >/dev/null(N) pip install evil==1.0.0; }; f'
  'WG10|0100110|> /dev/(nul|null) pip install evil==1.0.0'
  'WG11|0100010|2>/dev/null(N) 1>/dev/null(N) pip install evil==1.0.0'
  # bash extglob after `shopt -s extglob` on a line of its own: the group is
  # part of the word, and a `!` glued inside a word is no reserved word.
  $'WE1|1010001|shopt -s extglob\n>f@(x|y) pip install evil==1.0.0'
  $'WE2|1010001|shopt -s extglob\npip >f!(x) install evil==1.0.0'
  $'WE3|1110111|shopt -s extglob\nx=@(a) pip install evil==1.0.0'
  # zsh precommand modifiers stand before a command and are none.
  'WK1|0100110|noglob pip install evil==1.0.0'
  'WK2|0100110|nocorrect pip install evil==1.0.0'
  'WK3|0000110|- pip install evil==1.0.0'
  'WK4|0100110|echo a; noglob pip install evil==1.0.0'
  'WK5|0100110|noglob npm install evil@1.0.0'
  'WK6|0100110|noglob 2>/dev/null pip install evil==1.0.0'
  'WK7|0100110|f() { noglob pip install evil==1.0.0; }; f'
  'WK8|0100110|nocorrect command pip install evil==1.0.0'
  'WK9|0100110|noglob pip3 install evil==1.0.0'
  'WK10|0100110|noglob python3 -m pip install evil==1.0.0'
  'WK11|0000110|- noglob pip install evil==1.0.0'
  'WK12|0100110|nocorrect noglob - pip install evil==1.0.0'
  'WK13|0100110|exec - pip install evil==1.0.0'
  'WK14|0100110|builtin noglob pip install evil==1.0.0'
  # zsh reads `<N-M>` as a glob for a range of numbers: bytes of a word,
  # where bash and dash read two redirections and take `install` or the
  # manager for a target.
  'WN1|0100110|pip >/dev/fd/<1-1> install evil==1.0.0'
  'WN2|0100110|>/dev/fd/<1-1> pip install evil==1.0.0'
  'WN3|0100110|X=/dev/fd/<1-1> pip install evil==1.0.0'
  # A comment inside a substitution is nested with it and ends neither the
  # value nor the target the substitution is part of.
  $'WM1|1111111|x=$(echo f # c\n) pip install evil==1.0.0'
  $'WM2|1111111|pip >$(echo f # )\n) install evil==1.0.0'
  # A value with an escaped blank, an ANSI-C string, quoted and escaped
  # parentheses is one word, as it was.
  'WV1|1111111|a=b\ c pip install evil==1.0.0'
  $'WV2|1111111|a=$\'x y\' pip install evil==1.0.0'
  'WV3|1111111|a="(x)" pip install evil==1.0.0'
  'WV4|1111111|a=x\(y\) pip install evil==1.0.0'
)
for word_row in "${word_rows[@]}"; do
  word_ran="${word_row#*|}" word_ran="${word_ran%%|*}" word_form="${word_row#*|*|}"
  expect_not_approved "an install after a word the shell reads whole (${word_row%%|*}, ran ${word_ran}): ${word_form}" "${word_form}"
done
# The same words where they are data: no shell measured ran an install in any
# of these, and each stays unjudged and unrecorded. An array of the install
# words is a value (denied before the walk read the array as one word).
for word_data in \
  'echo "2>/dev/null pip install evil==1.0.0"' \
  "grep -r 'pip >/dev/null(N) install' ." \
  'echo >/dev/null(N) pip install evil==1.0.0' \
  'cat =(echo pip install evil==1.0.0)' \
  'echo noglob pip install evil==1.0.0' \
  'echo a=(x) pip install evil==1.0.0' \
  'echo =(true) pip install evil==1.0.0' \
  'echo >/dev/(null) pip install evil==1.0.0' \
  'ls *(N) pip install evil==1.0.0' \
  'a=(pip install evil==1.0.0)' \
  'x="$(case a in a) echo pip install evil==1.0.0;; esac)"' \
  'echo $(case a in a) echo f;; esac) pip install evil==1.0.0' \
  "printf '%s\\n' a=(x) pip install evil==1.0.0" \
  'pip a=(x) install evil==1.0.0'
do
  expect_pass "a word the shell reads whole, with the install words as data: ${word_data}" "${word_data}"
  if shard_row "no UNGATED record: ${word_data}" && logged_ungated "${word_data}"; then fail "no UNGATED record for ${word_data}"; fi
done
# Ordinary commands that hold the same words keep their verdicts.
for word_plain in \
  'files=(src/*.ts); npm run lint -- "${files[@]}"' \
  'ARGS=(--verbose); pytest "${ARGS[@]}"' \
  'for f in *.py(N); do python3 -m py_compile "$f"; done' \
  'ls -la src/*.ts(N)' \
  'arr[0]=x; echo "${arr[0]}"' \
  'os=$(case $(uname) in Darwin) echo mac;; *) echo linux;; esac) && go build ./...' \
  'builtin cd /tmp && ls' \
  "git log --format='%h (%an)' -3" \
  "find . -name '*.py' -o \\( -name x \\)" \
  'echo a (b)'
do
  expect_pass "an ordinary command with a word parenthesis: ${word_plain}" "${word_plain}"
  if shard_row "no UNGATED record: ${word_plain}" && logged_ungated "${word_plain}"; then fail "no UNGATED record for ${word_plain}"; fi
done
# Declared, not a defect: the precommand list and the glob reading are the
# manuals', not each shell's behaviour for every combination, so these are
# read as installs though no shell measured ran them.
for word_over in \
  'noglob nocorrect pip install evil==1.0.0' \
  'command noglob pip install evil==1.0.0' \
  'a=(x)(N) pip install evil==1.0.0'
do
  expect_not_approved "a form no shell measured runs is still read as an install: ${word_over}" "${word_over}"
done
# The npm forms get the inert flag where every reading puts the install in
# the same place, after the verb or at the end as for any assignment prefix.
# `a=(x) npm install x` got neither a verdict nor the flag.
for rewrite_row in \
  'a=(x) npm install evil|a=(x) npm install --ignore-scripts evil' \
  'a+=(x) npm install evil|a+=(x) npm install --ignore-scripts evil' \
  'a[1]=x npm install evil|a[1]=x npm install evil --ignore-scripts' \
  'x=$(case a in a) echo f;; esac) npm install evil|x=$(case a in a) echo f;; esac) npm install --ignore-scripts evil' \
  '>$(case a in a) echo f;; esac) npm install evil|>$(case a in a) echo f;; esac) npm install --ignore-scripts evil' \
  '< =(true) npm install evil|< =(true) npm install --ignore-scripts evil' \
  'cat =(npm install evil)|cat =(npm install --ignore-scripts evil)'
do
  shard_row "rewrite_row: ${rewrite_row}" || continue
  rewrite_holds "${rewrite_row%%|*}" "${rewrite_row#*|}" || fail "an npm install after a word the shell reads whole gets --ignore-scripts: ${rewrite_row%%|*} (got: $(gate_rewrite "${rewrite_row%%|*}"))"
done
# Where only some shells read the word that way the readings put the install
# in different places: UNDECIDED, never a rewrite for one shell.
# (`>/dev/null(N) npm install x` runs in zsh alone, `>/dev/(null) npm
# install x` in the agent's zsh wrapper alone; bash and dash fail to parse
# either, and their readings find no install there. A second lexing of the
# text with the redirection removed once read the `(N)` left at the front as
# a subshell at a command start, so dash appeared to agree with zsh and the
# command was rewritten; dash parses no such command. The text is lexed once
# now, and the answer is UNDECIDED again.)
for inert_form in \
  'a[1 + 1]=x npm install evil' \
  'noglob npm install evil' \
  '>/dev/null(N) npm install evil' \
  '>/dev/(null) npm install evil'
do
  shard_row "inert_form: ${inert_form}" || continue
  got=$(gate_reason "${inert_form}")
  [[ "${got}" == "deny "*UNDECIDED*"read the npm installs in this command in different places"* ]] \
    || fail "an npm install after a word only some shells read whole is UNDECIDED, not rewritten for one: ${inert_form} (got: ${got:0:120})"
done
# The walk checks its own answers: a `(` it reads as an operator where none
# of its three walks has a command, and a word parenthesis inside a command
# name, fail the reading. No shell measured runs the first; without the check
# it passed, with `install` behind a subshell the shell never opens. zsh runs
# the second when a file of that name is in the directory (the qualifier
# keeps the name), and it passed too.
expect_undecided "an operator parenthesis where no command stands" 'pip ((x) y) install evil==1.0.0'
expect_undecided "a word parenthesis inside the command name" 'pip(N) install evil==1.0.0'
# A reserved word is one only as a word of its own. Read by its letters, the
# `do` in a target took the glob qualifier after it for a subshell, and the
# verb went with it: zsh runs this install when the file is there.
expect_not_approved "a target that ends in a reserved word's letters" 'pip >f-do(.) install evil==1.0.0'
# And `!` is reserved only where a command may start. Read wherever it stood,
# the `!` of a bash extglob argument put a subshell after it, which the
# walk's check then failed: an ordinary `rm !(keep)` was a reading that
# "could not be fully read", and UNDECIDED when the command named a manager.
logged_scan_failure() {
  local safe
  safe=$(mktemp -d "${tmp_root}/safe-scanfail.XXXXXX")
  jq -nc --arg c "$1" --arg cwd "${project_dir}" \
    '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}' |
    HOME="${tmp_root}/home-scanfail" SAFEDEPS_HOME="${safe}" scripts/safedeps-pre-guard.sh >/dev/null 2>&1
  grep -q 'the command scanner failed' "${safe}/advisory.log" 2>/dev/null
}
logged_scan_failure 'pip ((x) y) install evil==1.0.0' || fail "control: a failed reading is recorded as a scanner failure"
for extglob_form in \
  $'shopt -s extglob\nrm -rf !(keep)' \
  $'shopt -s extglob\nrm -rf !(node_modules) && npm run build' \
  $'shopt -s extglob\ncp -r !(dist|node_modules) /tmp/out; pip --version' \
  'ls !(x) && npm test'
do
  expect_pass "an extglob argument is a word, not a negated subshell: ${extglob_form}" "${extglob_form}"
  if shard_row "no failed reading: ${extglob_form}" && logged_scan_failure "${extglob_form}"; then
    fail "an extglob argument fails no reading: ${extglob_form}"
  fi
done
pass "a word ends where the shell ends it: array values, case patterns in substitutions, zsh =(...) and glob groups, extglob, subscripts and precommand modifiers (${#word_rows[@]} forms a shell runs)"

# A word ends at an operator, as the shell ends it. `npm ci; echo x` hands npm
# the word `ci` exactly as `npm ci ; echo x` does, and so do `(npm ci)`, `npm
# ci&&x` and `npm ci>log`. The recognizers ended the last word only at a blank
# or the end of the line, so an install whose verb stood against the operator
# was no install to v2.17.2, 7d66f8c or v2.18.0: no check, no record, no
# `--ignore-scripts`. For maven, as for pip, cargo, go, gem and nuget, this gate
# is the only one, so that was a complete miss. The package stands before the
# verb here, so the verb is the word against the operator; the table for every
# manager and operator is scripts/measure/glued-verb-reading.sh.
for glued_form in \
  'mvn -Dartifact=g:evil:1.0.0 dependency:get;' \
  'mvn -Dartifact=g:evil:1.0.0 dependency:get; echo x' \
  'mvn -Dartifact=g:evil:1.0.0 dependency:get&& echo x' \
  'mvn -Dartifact=g:evil:1.0.0 dependency:get|| echo x' \
  'mvn -Dartifact=g:evil:1.0.0 dependency:get| cat' \
  'mvn -Dartifact=g:evil:1.0.0 dependency:get& wait' \
  '(mvn -Dartifact=g:evil:1.0.0 dependency:get)' \
  '{ mvn -Dartifact=g:evil:1.0.0 dependency:get;}' \
  'mvn -Dartifact=g:evil:1.0.0 dependency:get>/dev/null' \
  'mvn -Dartifact=g:evil:1.0.0 dependency:get</dev/null' \
  'echo $(mvn -Dartifact=g:evil:1.0.0 dependency:get)' \
  'x="$(mvn -Dartifact=g:evil:1.0.0 dependency:get)"' \
  'pip install evil==1.0.0;' \
  'cargo add evil@1.0.0&& echo x' \
  'gem install rake -v 13.0.0|| echo x' \
  'dotnet add package Serilog --version 3.1.1;' \
  'go get example.com/m@v1.0.0;' \
  '{ mvn -Dartifact=g:evil:1.0.0 dependency:get}' \
  '{ mvn -Dartifact=g:evil:1.0.0 dependency:get}&& echo x' \
  '{ echo a; mvn -Dartifact=g:evil:1.0.0 dependency:get}' \
  'echo `mvn -Dartifact=g:evil:1.0.0 dependency:get`'
do
  expect_deny "an install whose last word stands against an operator: ${glued_form}" "${glued_form}"
done
# The npm install with its verb against the operator gets `--ignore-scripts`
# right after the verb, before the operator, as the spaced form gets it after
# the verb.
expect_rewrite() {
  shard_row "expect_rewrite|$1|$2|$3" || return 0
  local label="$1" command="$2" want="$3" safe out got
  safe=$(mktemp -d "${tmp_root}/safe.XXXXXX")
  out=$(jq -nc --arg c "${command}" --arg cwd "${project_dir}" \
    '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}' |
    HOME="${tmp_root}/home" SAFEDEPS_HOME="${safe}" scripts/safedeps-pre-guard.sh 2>/dev/null)
  # An empty answer is no rewrite, said here rather than through a `{}`
  # default: under a mutation that emptied the answer, jq failed on that
  # default on macOS bash 3.2 and the row died without a `not ok`.
  got="(no rewrite)"
  [[ -z "${out}" ]] || got=$(jq -r '.hookSpecificOutput.updatedInput.command // "(no rewrite)"' <<< "${out}")
  [[ "${got}" == "${want}" ]] || fail "${label} is rewritten to [${want}] (got: [${got}])"
}
expect_rewrite "npm ci before ;"          'npm ci; echo x'    'npm ci --ignore-scripts; echo x'
expect_rewrite "npm ci at the end with ;" 'npm ci;'           'npm ci --ignore-scripts;'
expect_rewrite "npm ci before &&"         'npm ci&& echo x'   'npm ci --ignore-scripts&& echo x'
expect_rewrite "npm i before |"           'npm i| cat'        'npm i --ignore-scripts| cat'
expect_rewrite "npm ci in a subshell"     '(npm ci)'          '(npm ci --ignore-scripts)'
expect_rewrite "npm ci in a group"        '{ npm ci;}'        '{ npm ci --ignore-scripts;}'
expect_rewrite "npm ci before >"          'npm ci>/dev/null'  'npm ci --ignore-scripts>/dev/null'
expect_rewrite "npm ci in a substitution" 'x=$(npm ci)'       'x=$(npm ci --ignore-scripts)'

# A closing backtick ends the word too: `` echo `npm ci` `` hands npm `ci`. An
# opening one continues it: `` npm ci`echo x` `` hands npm `cix`, which
# installs nothing, and a flag after `ci` would make it `npm ci`.
expect_rewrite "npm ci before a closing backtick" 'echo `npm ci`' 'echo `npm ci --ignore-scripts`'
expect_rewrite "npm i before a closing backtick"  'x=`npm i`'     'x=`npm i --ignore-scripts`'
expect_rewrite "npm ci before an opening backtick" 'npm ci`echo x`' '(no rewrite)'

# zsh closes a `{` group at a `}` that ends a word and hands the word before it
# on (`{ npm ci}` runs `npm ci`; zsh 5.9, measured). bash and dash refuse that
# group. The flag goes before the `}`, where zsh reads it as the last word:
# after it, `{ npm ci} --ignore-scripts` is a parse error in zsh and in bash.
# The rewrites below are read by the shells themselves in
# scripts/measure/glued-verb-reading.sh (its rewrite columns).
expect_rewrite "npm ci closed by a glued }"        '{ npm ci}'          '{ npm ci --ignore-scripts}'
expect_rewrite "npm ci closed by a glued } and &&" '{ npm ci}&& echo x' '{ npm ci --ignore-scripts}&& echo x'
# In backticks or in `$(...)` the group is decided where the body is read as
# a payload, at its own top level: an install to the recognizers there. The
# rewrite reads the command, where a glued `}` nested in a body is a character
# (group_close in shell_lex), so it finds no verb, and the install is a
# recorded downgrade rather than a rewrite or a silent pass.
expect_recorded_downgrade() {
  shard_row "expect_recorded_downgrade|$1|$2" || return 0
  local label="$1" command="$2" safe out
  safe=$(mktemp -d "${tmp_root}/safe.XXXXXX")
  out=$(jq -nc --arg c "${command}" --arg cwd "${project_dir}" \
    '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}' |
    HOME="${tmp_root}/home" SAFEDEPS_HOME="${safe}" scripts/safedeps-pre-guard.sh 2>/dev/null)
  if [[ -n "${out}" ]] || ! grep -q 'could not make every npm install in this command inert' "${safe}/advisory.log" 2>/dev/null; then
    fail "${label} is a recorded downgrade (got: ${out:-pass}, advisory: $(head -3 "${safe}/advisory.log" 2>/dev/null))"
  fi
}
expect_recorded_downgrade "npm ci in backticks closed by a glued }" 'echo `{ npm ci}`'
expect_recorded_downgrade "npm ci in a substitution closed by a glued }" 'x=$( { npm ci} )'
expect_rewrite "npm ci after another statement in the group" '{ echo a; npm ci}' '{ echo a; npm ci --ignore-scripts}'
# A line read on its own has lost the `{` of the line before it.
expect_rewrite "npm ci on the line after the {" $'{\nnpm ci}' $'{\nnpm ci --ignore-scripts}'
# With no group open, zsh refuses the `}` and bash hands npm `ci}`, which npm
# refuses as a command: no install, and no rewrite that would make it one.
expect_rewrite "npm ci} outside a group" 'npm ci}'            '(no rewrite)'
expect_rewrite "npm i} outside a group"  'npm i} ; echo x'    '(no rewrite)'
# A `}` with a quote or an escape after it is inside the word (`ci}x`), even
# where the scan view blanks the quote.
expect_rewrite "npm ci} before a quote"     "npm ci}'x'"       '(no rewrite)'
expect_rewrite "npm ci} before an escape"   'npm ci}\x'        '(no rewrite)'
expect_rewrite "npm ci} before a quote in a group" "{ npm ci}'x' ;}" '(no rewrite)'
expect_pass "npm ci} outside a group, which installs nothing" 'npm ci}'
expect_pass "a maven goal with a } outside a group, which maven does not know" 'mvn -Dartifact=g:evil:1.0.0 dependency:get}'
# bash closes this group at the last `}` and runs `npm ci}`; zsh closes it at
# the glued one and refuses the last. No single rewrite is right for both, so
# it is undecided, as any command the readings rewrite differently is.
expect_undecided "a glued } that bash reads as part of the word and zsh as a closer" '{ npm ci}; }'

# zsh opens a group at every `{` its grammar reads as an opener, not only after
# a separator or a reserved word: after `function NAME`, an empty `()`, `repeat
# WORD` and the list of `for NAME (WORDS)` too, and it runs each of these
# (zsh 5.9, measured). Which `{` opens a group is the walk's answer (starts()
# in shell_lex), the one that puts a command start after it, so the glued form
# is read as the spaced form is. The `{` used to be read by a byte rule of its
# own that knew separators and reserved words: after these heads it opened no
# group, the glued `}` was a character, and the glued form alone passed with
# nothing recorded once the spaced form was read (verdict
# tookdaki-20261005-144303, N2). Each row: the glued template, then the spaced
# one, with %C% for the install.
glued_group_verdict() {
  local safe out
  safe=$(mktemp -d "${tmp_root}/safe.XXXXXX")
  out=$(jq -nc --arg c "$1" --arg cwd "${project_dir}" \
    '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}' |
    HOME="${tmp_root}/home" SAFEDEPS_HOME="${safe}" scripts/safedeps-pre-guard.sh 2>/dev/null)
  [[ -n "${out}" ]] || out='{}'
  jq -r '(.hookSpecificOutput.permissionDecision // "pass") + "|" + (if ((.hookSpecificOutput.permissionDecisionReason // "") | test("UNDECIDED")) then "undecided" else "" end) + "|" + (.hookSpecificOutput.updatedInput.command // "")' <<< "${out}"
}
glued_group_rows=(
  'function f { %C%}; f^function f { %C% ;}; f'
  'f() { %C%}; f^f() { %C% ;}; f'
  '() { %C%}^() { %C% ;}'
  'repeat 1 { %C%}^repeat 1 { %C% ;}'
  'for i (1) { %C%}^for i (1) { %C% ;}'
)
glued_close='}'
for glued_row in "${glued_group_rows[@]}"; do
  shard_row "glued_row: ${glued_row}" || continue
  for glued_install in 'npm ci' 'mvn -Dartifact=g:evil:1.0.0 dependency:get'; do
    glued_cmd="${glued_row%%^*}"; glued_cmd="${glued_cmd//%C%/${glued_install}}"
    spaced_cmd="${glued_row#*^}"; spaced_cmd="${spaced_cmd//%C%/${glued_install}}"
    glued_got=$(glued_group_verdict "${glued_cmd}")
    spaced_got=$(glued_group_verdict "${spaced_cmd}")
    # The spaced rewrite with its ` ;` before the `}` set aside, as the glued
    # form has none.
    spaced_want="${spaced_got// ;${glued_close}/${glued_close}}"
    [[ "${spaced_got}" != "pass||" ]] || fail "the spaced form is read: ${spaced_cmd}"
    [[ "${glued_got}" == "${spaced_want}" ]] || fail "a glued } closes the group the walk opened, as the spaced form does: [${glued_cmd}] answered [${glued_got}], [${spaced_cmd}] answered [${spaced_got}]"
  done
done
pass "a glued } closes the group every head the walk reads opens, read as its spaced form (${#glued_group_rows[@]} heads, npm and maven)"

# What the shell does not end there stays what it is. A `}` inside a word is
# part of it (`ci}x`), a `-`, `:` or letter after the verb makes another word,
# and an operator after text that is no install, or inside quotes, a comment
# or a heredoc body to `cat`, is data.
for glued_data in \
  'npm cit-helper; echo x' \
  'npm ci:all; echo x' \
  'npm run ci; echo x' \
  'npm view evil@1.0.0| cat' \
  'pip installer; echo x' \
  'go getter&& echo x' \
  'mvn dependency:getx; echo x' \
  'echo npm ci; echo x' \
  'echo pip install evil==1.0.0;' \
  'grep -n "npm ci;" README.md' \
  "printf '%s\\n' 'mvn -Dartifact=g:evil:1.0.0 dependency:get;'" \
  'git commit -m "run npm ci; then go get;"' \
  'ls # npm ci; pip install evil==1.0.0;' \
  $'cat <<E\nnpm ci; pip install evil==1.0.0;\nE' \
  'echo $(npm ls)| cat' \
  '{ npm ci}x; }'
do
  expect_pass "data with an operator after a manager's word: ${glued_data}" "${glued_data}"
done
pass "a word ends at an operator as the shell ends it, and what the shell does not end there stays data"

# npm takes any unique abbreviation of a command or alias, and the camelCase
# form of a dashed one (lib/utils/cmd-list.js deref). The grammar holds what
# deref accepts, measured from npm; where an npm is on PATH, that measurement is
# rerun here, so a newer npm that adds a spelling turns this red.
# An npm whose parser cannot be asked (npm 9 and older have no deref), or no
# npm at all, is a skip that says so, never a quiet pass.
if command -v npm >/dev/null 2>&1 && command -v node >/dev/null 2>&1; then
  spellings_rc=0
  spellings_out=$(scripts/measure/npm-verb-spellings.sh 2>&1) || spellings_rc=$?
  case "${spellings_rc}" in
    0) pass "the grammar's npm command words are the ones npm's parser accepts (scripts/measure/npm-verb-spellings.sh, npm $(npm --version))" ;;
    3) pass "the grammar's npm command words against npm's parser # SKIP ${spellings_out}" ;;
    *) fail "the grammar's npm verbs are what npm's own parser accepts ($(head -5 <<< "${spellings_out}" | tr '\n' ' '))" ;;
  esac
else
  pass "the grammar's npm command words against npm's parser # SKIP no npm and node on PATH to ask"
fi

# --- 7. A spec is checked as the package it names ------------------------------
# Both of these used to prescribe a `safedeps check` for the wrong package --
# one that OSV knows nothing about, so it approves, and the retry then passes.
# An agent follows the prescription on its own, so the wrong identity was a
# bypass, not a typo.
identity_reason() {
  local safe
  safe=$(mktemp -d "${tmp_root}/safe-identity.XXXXXX")
  jq -nc --arg c "$1" --arg cwd "${project_dir}" \
    '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}' |
    HOME="${tmp_root}/home-identity" SAFEDEPS_HOME="${safe}" scripts/safedeps-pre-guard.sh 2>/dev/null |
    jq -r '.hookSpecificOutput.permissionDecisionReason // ""'
}
grep -q 'check go example.com/evil@v1.0.0' <<< "$(identity_reason 'go get example.com/evil@v1.0.0')" \
  || fail "a Go module is checked by its whole path, not its last element"
grep -q 'check pypi evil@1.0.0' <<< "$(identity_reason 'npm run build && pip install evil==1.0.0')" \
  || fail "a spec is checked under the ecosystem of the statement it came from"
pass "Go modules keep their path and each spec keeps its own statement's ecosystem"

# The prescription is only half of it. Approve the wrong identity directly and
# check that it does not carry over: a Go approval of the bare name `x` must not
# pass another host's `.../x`, and an npm approval of `evil` must not pass a
# pip install of `evil`. Each is paired with its exact identity, which must
# pass, so a deny here cannot come from a seed that did not take.
identity_home="${tmp_root}/identity-approved"
mkdir -p "${identity_home}"
( export SAFEDEPS_HOME="${identity_home}"
  . lib/ledger/ledger.sh
  safedeps_ledger_write_approved_spec go x v1.0.0 >/dev/null
  safedeps_ledger_write_approved_spec npm evil 1.0.0 >/dev/null ) \
  || fail "the identity fixture approvals could be written"
approved_decision() {
  jq -nc --arg c "$1" --arg cwd "${project_dir}" \
    '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}' |
    HOME="${tmp_root}/home-identity" SAFEDEPS_HOME="${identity_home}" scripts/safedeps-pre-guard.sh 2>/dev/null |
    jq -r '.hookSpecificOutput.permissionDecision // "pass"' 2>/dev/null || printf 'pass'
}
[[ "$(approved_decision 'go get x@v1.0.0')" != "deny" ]] \
  || fail "identity fixture: the approved Go module itself passes"
[[ "$(approved_decision 'go get evil.example/attacker/x@v1.0.0')" == "deny" ]] \
  || fail "an approval of the bare Go name x does not pass another module whose path ends in x"
[[ "$(approved_decision 'npm install evil@1.0.0')" != "deny" ]] \
  || fail "identity fixture: the approved npm package itself passes"
[[ "$(approved_decision 'npm run build && pip install evil==1.0.0')" == "deny" ]] \
  || fail "an npm approval of evil does not pass a pip install of evil"
pass "an approval under one identity does not carry over to another module path or ecosystem"

# --- 8. Wrappers stay outside the boundary ----------------------------------------
# argv-passing wrappers run the install unchanged, and the gate does not know
# them. Same boundary as section 2, same reason: the list of programs that exec
# their arguments does not converge. Pinned so the boundary is measured, and so
# README can say which forms it means instead of "unusual wrappers".
for wrapper_form in \
  "sudo pip install evil==1.0.0" \
  "timeout 60 pip install evil==1.0.0" \
  "nohup pip install evil==1.0.0" \
  "nice -n 5 pip install evil==1.0.0"
do
  expect_pass "the wrapper ${wrapper_form%% *}" "${wrapper_form}"
done
pass "argv-passing wrappers (sudo, timeout, nohup, nice) stay outside the command gate (documented boundary)"

# A command word or a runner's package that the shell assembles from quotes is
# not recognized: the recognizers read the scan view, where a quoted word is
# blank. v2.17.2 behaved the same. Pinned so README can name the forms, and so
# the plan that reads them the way the shell does has rows to turn
# (safedeps/command-words-read-as-the-shell-dequotes).
for quoted_form in \
  "'pip' install evil==1.0.0" \
  'npx "evil@1.0.0"' \
  'uvx "ruff==0.1.0" --help'
do
  expect_pass "the quoted form ${quoted_form}" "${quoted_form}"
done
pass "a command word or a runner package assembled from quotes stays unrecognized (documented boundary)"

# A word between the manager and its verb that the shell removes when it runs
# the command is the same boundary: the recognizers read the word where it
# stands, and an unset variable, an empty substitution or a zsh glob that
# matches nothing with `(N)` leaves `pip install ...` behind. main behaved the
# same. Pinned as the gate answers now, so that the plan that reads which word
# is the command and which the verb has rows to turn
# (safedeps/command-words-read-as-the-shell-dequotes). Each row: whether each
# shell ran the install with the variable unset, in the columns of word_rows
# above (measured 2026-10-03 with a stub in the manager's place), then the form.
for vanishing_row in \
  '1111111|pip $x install evil==1.0.0' \
  '1111111|pip ${x} install evil==1.0.0' \
  '1111111|pip $(true) install evil==1.0.0' \
  '1111111|npm $x install evil' \
  '0100010|pip nope*(N) install evil==1.0.0'
do
  expect_pass "a word the shell removes between the manager and its verb (ran ${vanishing_row%%|*}): ${vanishing_row#*|}" "${vanishing_row#*|}"
done
[[ -z "$(gate_rewrite 'npm $x install evil')" ]] || fail "an npm install behind a word the shell removes gets no rewrite, as pinned (got: $(gate_rewrite 'npm $x install evil'))"
pass "a word the shell removes between the manager and its verb stays unrecognized (documented boundary)"

# A case arm is a statement. A grammar pattern cannot tell a pattern's `)` from
# any other `)` (`echo $(date) pip install x` would read as an install), so case
# arms were pinned outside the gate. The lexer knows where a pattern ends: it
# reads `case ... in`, and the `)` that closes each pattern is a statement
# boundary in the view the recognizers read.
for arm in \
  'case x in *) pip install evil==1.0.0;; esac' \
  'case x in (x) pip install evil==1.0.0;; esac' \
  'case x in a|b) ls;; *) pip install evil==1.0.0;; esac' \
  'case x in x) :;& y) pip install evil==1.0.0;; esac' \
  'case x in x) FOO="a b" pip install evil==1.0.0;; esac' \
  'echo "$(case x in x) pip install evil==1.0.0;; esac)"' \
  'x=$(case x in x) pip install evil==1.0.0;; esac)'
do
  expect_deny "an install in a case arm: ${arm}" "${arm}"
done
expect_pass "a case statement with no install" 'case x in *) echo hi;; esac'
expect_pass "a parenthesized value next to a command name is not a case arm" 'echo $(date) pip install x'
pass "an install in a case arm is gated, and a stray parenthesis still is not a statement start"

# Substitution bodies come from the lexer: a nested escaped backtick is a
# nested substitution, and a substitution that closes on its line drops the
# heredoc it opened, so the next line is a command.
expect_deny "an install in a nested backtick" 'echo `echo \`pip install evil==1.0.0\``'
expect_deny "an install after a heredoc whose substitution closed on its line" $'x=$(cat <<EOF)\npip install evil==1.0.0\nEOF'
pass "substitution bodies are read as the shell delimits them"

# A quote inside a comment opens nothing (a line joiner that did not know
# comments joined the next line and hid it; caught in review).
for commented in \
  $'# don\'t\npip install evil==1.0.0' \
  $'echo hi # it\'s\npip install evil==1.0.0' \
  $'echo hi # say "hi\npip install evil==1.0.0' \
  $'# it\'s fine\ncargo add serde@1.0.0' \
  $'# don\'t do this\nnpm install evil@1.0.0'
do
  expect_deny "an install after a comment holding a quote" "${commented}"
done
expect_pass "a # inside a word is no comment" $'echo a#\'b\npip install evil==1.0.0\n\''
pass "a quote inside a comment hides nothing after it"

# --- 9. UNGATED is keyed on the effect gate actually being there --------------
# The exemption used to read "the ledger ecosystem is npm", which pnpm, yarn and
# bun share without the effect gate that reads package-lock.json (GitHub #22).
for no_effect_gate in \
  "pnpm add evil" \
  "pnpm i evil" \
  "yarn add evil" \
  "bun add evil" \
  "npx evil" \
  "npm exec evil" \
  "pnpm dlx evil" \
  "pip install evil==1.0.*" \
  "pip install 'evil[x]'"
do
  shard_row "no_effect_gate: ${no_effect_gate}" || continue
  logged_ungated "${no_effect_gate}" \
    || fail "an unpinned install with no effect gate behind it is recorded: ${no_effect_gate}"
  [[ "$(gate_decision "${no_effect_gate}")" != "deny" ]] \
    || fail "the UNGATED record must not change the verdict: ${no_effect_gate}"
done
pass "unpinned pnpm/yarn/bun and runner installs are recorded"

# The pending state the pre-guard leaves for the PostToolUse hook, as JSON.
pending_of() { # command [codex]
  local command="$1" safe turn='{}'
  [[ "${2:-}" != codex ]] || turn='{turn_id:"t"}'
  safe=$(mktemp -d "${tmp_root}/safe-pending.XXXXXX")
  jq -nc --arg c "${command}" --arg cwd "${project_dir}" \
    '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd} + '"${turn}" |
    HOME="${tmp_root}/home-pending" SAFEDEPS_HOME="${safe}" scripts/safedeps-pre-guard.sh >/dev/null 2>&1
  cat "${safe}"/pending/*.json 2>/dev/null || true
}

# Whether an npm install was read is the PostToolUse hook's to say, from the
# install trace it finds where the gate looks (scripts/test/effect-trace-grid.sh
# runs these end to end). So the pre-guard records none of these, whether the
# text sends the install to npm's global prefix or somewhere it cannot name, and
# every one leaves the post hook a trace baseline. The pre-guard used to record
# them from the text, and text it read wrong was a silent pass
# (safedeps/effect-gate-blind-to-lockless-npm-installs). `sub` has a
# package.json of its own.
mkdir -p "${project_dir}/sub"
printf '{}\n' > "${project_dir}/sub/package.json"
for unread_by_text in \
  "npm install -g evil" \
  "npm_config_global=true npm install evil" \
  "NPM_CONFIG_GLOBAL=true npm install evil" \
  "export npm_config_global=true; npm install evil" \
  "npm_config_location=global npm install evil" \
  'cd "$SUBDIR" && npm install evil' \
  'cd $(dirname x)/sub && npm install evil' \
  'cd no-such-dir && npm install evil' \
  '(cd sub && npm install evil)' \
  'cd sub | npm install evil' \
  'pushd sub && popd && npm install evil' \
  'npm install evil --prefix=$HOME/x'
do
  shard_row "unread_by_text: ${unread_by_text}" || continue
  logged_ungated "${unread_by_text}" \
    && fail "the pre-guard leaves the record of an npm install to the post hook: ${unread_by_text}"
  state=$(pending_of "${unread_by_text}")
  [[ -n "$(jq -r '.npm_trace.baseline // empty' <<< "${state}")" ]] \
    || fail "the post hook gets a trace baseline: ${unread_by_text} (${state})"
  [[ "$(jq -r '.project_dir_from' <<< "${state}")" == cwd ]] \
    || fail "a directory the text cannot name falls back to the cwd, as a place to look: ${unread_by_text} ($(jq -c . <<< "${state}"))"
done
pass "an npm install the text sends elsewhere, or cannot place, is left to the post hook's trace check"

# A `cd` that may not run is followed only along the `&&` chain after it
# (validator round 3, G1: `false && cd sub; npm install x` installs in the cwd).
# `<form>|<directory the gate reads, relative to the project>`.
for carrier in \
  "false && cd sub; npm install evil|." \
  "true || cd sub; npm install evil|." \
  "if false; then cd sub; fi; npm install evil|." \
  "[ -d sub ] && cd sub; npm install evil|." \
  "x || cd sub && npm install evil|." \
  "for d in sub; do cd sub; done; npm install evil|." \
  "true && cd sub && npm install evil|sub" \
  "if true; then cd sub && npm install evil; fi|sub" \
  "cd sub || exit 1; npm install evil|sub" \
  "cd sub; npm install evil|sub" \
  "cd sub && npm install evil|sub"
do
  shard_row "carrier: ${carrier}" || continue
  form="${carrier%|*}"
  where="${project_dir}"
  [[ "${carrier##*|}" == . ]] || where="${project_dir}/${carrier##*|}"
  where=$(cd "${where}" && pwd -P)
  state=$(pending_of "${form}")
  [[ "$(jq -r '.project_dir' <<< "${state}")" == "${where}" ]] \
    || fail "a conditional cd is followed only as far as it provably ran: ${form} (reads $(jq -r '.project_dir' <<< "${state}"), expected ${where})"
done
pass "a conditional cd holds along the && chain after it and no further; cd X || exit is followed"

# Two lockfile writers credited to one trace. The post hook records the command
# UNGATED when they cannot be (the reason is in the pending state); the cases
# where they can stay quiet. `<expect>|<form>`, expect `one` or `split`.
for carrier in \
  "one|npm install evil && npm install other" \
  "one|npm ci || npm install" \
  "one|npm install evil 2>&1 | tail -3 && npm install other" \
  "one|npm install evil; echo done; npm install other" \
  "one|npm install evil && npm run build" \
  "one|npm install evil && npm install other >/dev/null 2>&1" \
  "split|npm install evil; command cd sub; npm install other" \
  "split|npm install evil && npm init -y && npm install other" \
  "split|npm prune; npm init -y; npm install other" \
  "split|cd sub && npm install evil && cd .. && npm install other" \
  "split|npm install evil && npm -C sub install other" \
  "split|npm install evil && npm_config_global=true npm install other" \
  "split|npm install evil; sh -c 'npm install other'" \
  "split|npm install evil; echo global=true > .npmrc; npm install other" \
  "split|npm install evil; npm config set global true; npm install other" \
  "split|(cd sub; npm install evil); npm install other" \
  "split|npm install evil; echo \$(rm package.json); npm install other" \
  "split|NPM install evil; command cd sub; Npm install other"
do
  shard_row "carrier: ${carrier}" || continue
  expect="${carrier%%|*}"
  form="${carrier#*|}"
  state=$(pending_of "${form}")
  reason=$(jq -r '.npm_unattributable // empty' <<< "${state}")
  if [[ "${expect}" == one ]]; then
    [[ -z "${reason}" ]] || fail "lockfile writers with nothing between them share one trace: ${form} (${reason})"
  else
    [[ -n "${reason}" ]] || fail "lockfile writers that may land apart are not credited to one trace: ${form} ($(jq -c . <<< "${state}"))"
  fi
done
pass "lockfile writers share a trace only with inert statements between them and no relocation of their own"

# npm's name in another case runs npm on a macOS volume. The ask reads it as
# npm, so npm is asked with the statement's own arguments rather than the gate
# falling back to the cwd.
for carrier in "npm --prefix sub install evil" "NPM --prefix sub install evil" "X=1 Npm --prefix sub install evil"; do
  shard_row "carrier: ${carrier}" || continue
  state=$(pending_of "${carrier}")
  [[ "$(jq -r '.project_dir' <<< "${state}")" == "$(cd "${project_dir}/sub" && pwd -P)" ]] \
    || fail "npm in any case is asked where it installs: ${carrier} ($(jq -c . <<< "${state}"))"
done
pass "npm in any case is asked where it installs"

# Where the shells read a command differently the gate judges each reading on
# its own (resolve_install_targets, A1). A statement both readings share is one
# statement, not two, so the one npm install below is one writer. That row has
# no control: with the readings joined into one text (the reading this
# replaced), the first reading's open `((` swallowed the second copy, so it was
# not counted twice either (measured on a mutated copy). The second row is the
# one that reading failed: the split only the zsh reading shows was swallowed
# with it, and no reason came through. It runs as Codex: bash reads no npm
# install there at all, zsh and dash read two, so a Claude call is UNDECIDED
# before any pending state is written (the inert rule, guard_reading_inert),
# which the row after it pins.
diverge=$'((cat <<EOF > n.txt\nit\'s here\nEOF\n) )'
state=$(pending_of "npm install evil"$'\n'"${diverge}")
[[ -n "$(jq -r '.npm_trace.baseline // empty' <<< "${state}")" ]] \
  || fail "a command the shells read two ways still leaves a trace baseline (${state})"
[[ -z "$(jq -r '.npm_unattributable // empty' <<< "${state}")" ]] \
  || fail "one npm install shared by two readings is one writer ($(jq -r .npm_unattributable <<< "${state}"))"
state=$(pending_of "${diverge}"$'\n'"npm install evil; command cd sub; npm install other" codex)
[[ -n "$(jq -r '.npm_unattributable // empty' <<< "${state}")" ]] \
  || fail "two writers with a statement between them are reported from the reading that has them ($(jq -c . <<< "${state}"))"
[[ -z "$(pending_of "${diverge}"$'\n'"npm install evil; command cd sub; npm install other")" ]] \
  || fail "a Claude call whose readings put the npm installs in different places leaves no pending state"
pass "the attribution rule counts each shell reading on its own"

# The other side: forms the effect gate does read stay quiet. `--no-save` and
# `--no-package-lock` leave package-lock.json alone but record the package in
# node_modules/.package-lock.json, which the gate reads; `cd` and `-C` are
# followed to the lockfile they write.
for followed in \
  "npm install --no-save evil" \
  "npm install evil --save=false" \
  "npm install --no-package-lock evil" \
  "npm install evil --package-lock false" \
  "npm_config_save=false npm install evil" \
  "npm_config_package_lock=false npm install evil" \
  "npm_config_prefix=sub npm install evil" \
  "cd sub && npm install evil" \
  "cd sub; npm install evil" \
  "cd ${project_dir}/sub && npm install evil" \
  "npm -C sub install evil" \
  "npm install evil -C sub" \
  "npm install --prefix sub evil" \
  "env -C sub npm install evil" \
  "npm install evil && npm install other"
do
  shard_row "followed: ${followed}" || continue
  logged_ungated "${followed}" && fail "an install the effect gate reads is not recorded UNGATED: ${followed}"
done
pass "lockless and relocated installs the effect gate reads stay unrecorded"

# Where the gate looks is read the way the shell reads the command. A quoted
# relocation value is one word: reading the quote-blanked text instead turned
# `--prefix "/tmp/x y" left-pad` into `--prefix left-pad`, so the effect gate
# verified <cwd>/left-pad while the install landed in /tmp/x y, and yarn's
# `--cwd "/tmp/a b" add x` was read as <cwd>/add and denied (caught in review).
pending_project_dir() {
  local command="$1" safe
  safe=$(mktemp -d "${tmp_root}/safe-where.XXXXXX")
  jq -nc --arg c "${command}" --arg cwd "${project_dir}" \
    '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}' |
    HOME="${tmp_root}/home-where" SAFEDEPS_HOME="${safe}" scripts/safedeps-pre-guard.sh >/dev/null 2>&1
  cat "${safe}"/pending/*.json 2>/dev/null | jq -r '.project_dir' | head -n1
}
spaced="${tmp_root}/x y"
mkdir -p "${spaced}" "${project_dir}/my dir"
printf '{}\n' > "${project_dir}/my dir/package.json"
spaced_real=$(cd "${spaced}" && pwd -P)
project_real=$(cd "${project_dir}" && pwd -P)
for form in \
  "npm install --prefix \"${spaced}\" left-pad" \
  "npm install --prefix='${spaced}' left-pad" \
  "npm install left-pad --prefix ${spaced// /\\ }" \
  "npm -C \"${spaced}\" install left-pad"
do
  shard_row "form: ${form}" || continue
  got=$(pending_project_dir "${form}")
  [[ "${got}" == "${spaced_real}" ]] || fail "a quoted relocation value is one word: ${form} (verifies ${got})"
done
for form in 'cd "my dir" && npm install left-pad' 'cd my\ dir && npm install left-pad'; do
  shard_row "form: ${form}" || continue
  got=$(pending_project_dir "${form}")
  [[ "${got}" == "${project_real}/my dir" ]] || fail "a quoted cd operand is one word: ${form} (verifies ${got})"
done
# npm installs where the nearest package.json is, not in the directory it runs
# in: from a directory without one, the effect gate reads the project above it.
mkdir -p "${project_dir}/plain"
got=$(pending_project_dir 'cd plain && npm install left-pad')
[[ "${got}" == "${project_real}" ]] || fail "an install from a directory with no package.json is read where npm walks up to (verifies ${got})"
got=$(pending_project_dir 'echo "a; cd sub" && npm install left-pad')
[[ "${got}" == "${project_real}" ]] || fail "a cd inside quotes is not a statement (verifies ${got})"
# The yarn case denies either way here, because x@1.0.0 is not approved. What
# moved is why: read as <cwd>/add, the Yarn context of a directory that does
# not exist was "invalid", and that deny said nothing about approval.
mkdir -p "${tmp_root}/a b"
printf '{"name":"ab"}\n' > "${tmp_root}/a b/package.json"
printf '__metadata:\n  version: 8\n' > "${tmp_root}/a b/yarn.lock"
yarn_reason=$(jq -nc --arg c "yarn --cwd \"${tmp_root}/a b\" add x@1.0.0" --arg cwd "${project_dir}" \
    '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}' |
  HOME="${tmp_root}/home-where" SAFEDEPS_HOME="$(mktemp -d "${tmp_root}/safe-yarn.XXXXXX")" \
    scripts/safedeps-pre-guard.sh 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecisionReason // empty')
[[ "${yarn_reason}" == *"not approved"* ]] \
  || fail "yarn --cwd with a quoted directory is judged in that directory, not in <cwd>/add (reason: ${yarn_reason})"
pass "quoted and escaped relocation values are read as one word, as the shell reads them"

# "Pinned" is asked of the extractor by name, not read off the token. A wildcard
# is not a pin, so with evil approved the second package here reaches no ledger
# check and has to be on record.
mixed_home="${tmp_root}/mixed-approved"
mkdir -p "${mixed_home}"
( export SAFEDEPS_HOME="${mixed_home}"
  . lib/ledger/ledger.sh
  safedeps_ledger_write_approved_spec pypi evil 1.0.0 >/dev/null ) \
  || fail "the mixed-command fixture approval could be written"
jq -nc --arg c "pip install evil==1.0.0 other==1.0.*" --arg cwd "${project_dir}" \
  '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}' |
  HOME="${tmp_root}/home-mixed" SAFEDEPS_HOME="${mixed_home}" scripts/safedeps-pre-guard.sh >/dev/null 2>&1
grep -q 'UNGATED' "${mixed_home}/advisory.log" 2>/dev/null \
  || fail "a command that pins one package and not another records the other"
pass "a package counts as pinned only when the extractor produced a spec for it"

# Pinned is keyed by ecosystem too: pypi `openai` and npm `openai` are
# different packages. A pin on one side of a command used to quiet the record
# for the unpinned install of the same name on the other (caught in review).
cross_ungated() {
  local approve_eco="$1" approve_pkg="$2" approve_ver="$3" command="$4" home
  home=$(mktemp -d "${tmp_root}/cross.XXXXXX")
  ( export SAFEDEPS_HOME="${home}"
    . lib/ledger/ledger.sh
    safedeps_ledger_write_approved_spec "${approve_eco}" "${approve_pkg}" "${approve_ver}" >/dev/null ) \
    || fail "the cross-ecosystem fixture approval could be written"
  jq -nc --arg c "${command}" --arg cwd "${project_dir}" \
    '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}' |
    HOME="${tmp_root}/home-cross" SAFEDEPS_HOME="${home}" scripts/safedeps-pre-guard.sh >/dev/null 2>&1
  grep -q 'UNGATED' "${home}/advisory.log" 2>/dev/null
}
cross_ungated pypi openai 1.0.0 "pip install openai==1.0.0 && pnpm add openai" \
  || fail "a pypi pin does not quiet the record for an unpinned npm install of the same name"
cross_ungated npm left-pad 1.0.0 "pnpm add left-pad@1.0.0 && pip install 'left-pad>=0'" \
  || fail "an npm pin does not quiet the record for an unpinned pypi install of the same name"
pass "a pin in one ecosystem does not quiet the record for the same name in another"

# npx runs a binary the project already has without fetching anything. Only a
# name with no local binary is a fetch.
mkdir -p "${project_dir}/node_modules/.bin"
printf '#!/bin/sh\n' > "${project_dir}/node_modules/.bin/tsc"
chmod +x "${project_dir}/node_modules/.bin/tsc"
for local_bin in "npx tsc --noEmit" "npm exec tsc" "npx --yes tsc"; do
  shard_row "local_bin: ${local_bin}" || continue
  logged_ungated "${local_bin}" && fail "a runner of a local binary is not a fetch: ${local_bin}"
done
logged_ungated "npx prettier" || fail "a runner of a name with no local binary is a fetch and is recorded"
rm -rf "${project_dir}/node_modules"
logged_ungated "npm install evil" && fail "a project npm install stays exempt: the effect gate reads its lockfile"
pass "a runner of a local binary stays quiet, a fetching runner is recorded, and a project npm install stays exempt"

# --- Backslashes are read the way the shell reads them -------------------------
# A backslash used to be judged by the one byte before a quote, and not at all
# outside quotes. Every form below executes the install after it in a real
# shell, and every one of them passed the gate with the text blanked
# (safedeps/escaped-backslash-blanks-the-rest). The controls at the top are
# the same installs without the backslash.
expect_deny "the control npm install" 'npm install evil@1.0.0'
expect_deny "the control after a closed quote" 'echo "a" ; npm install evil@1.0.0'
for escaped_form in \
  'echo "a\\" ; npm install evil@1.0.0' \
  'echo "a\\" && npm install evil@1.0.0' \
  'echo "a\\" | true ; npm install evil@1.0.0' \
  'echo "a\\" ; pip install evil==1.0.0' \
  'echo "a\\" ; cargo add evil@1.0.0' \
  'echo "a\\\\" ; pip install evil==1.0.0' \
  'echo "a\"" ; pip install evil==1.0.0' \
  'echo \" ; pip install evil==1.0.0' \
  "echo \\' ; pip install evil==1.0.0" \
  $'pip \\\ninstall evil==1.0.0' \
  $'pi\\\np install evil==1.0.0' \
  $'echo a\\\\\npip install evil==1.0.0'
do
  expect_deny "an install after $(printf '%q' "${escaped_form}")" "${escaped_form}"
done
pass "an escaped backslash closes a region, an escaped quote opens none, and a continuation joins its lines"

# The other direction, which a fix like this could get wrong: text the shell
# really treats as data stays data. An escaped backslash then an escaped quote
# leaves the region open, and `\<newline>` inside single quotes is not a
# continuation.
# The region stays open to the end of the command, which the shell refuses to
# run at all. The gate reads an input that never closes as unread and answers
# UNDECIDED for it -- a line the lexer could not finish is not a line it read.
unclosed_reason=$(jq -nc --arg c 'echo "a\\\" ; pip install evil==1.0.0' --arg cwd "${project_dir}" '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}' |
  HOME="${tmp_root}/home" SAFEDEPS_HOME="$(mktemp -d "${tmp_root}/safe.XXXXXX")" scripts/safedeps-pre-guard.sh 2>/dev/null |
  jq -r '.hookSpecificOutput.permissionDecisionReason // ""')
grep -q 'UNDECIDED' <<< "${unclosed_reason}" || fail "an install inside a region an escaped quote keeps open is undecided, not passed or claimed"
expect_pass "an install inside single quotes across a backslash-newline" $'echo \'a\\\npip install evil==1.0.0\''
pass "text the shell treats as data stays data"

# An escaped operator is a character, and `!` and `{` open a statement only
# where a statement starts. Read the other way, `echo ! pip install x | sh`
# and `echo true \; pip install x | sh` were visible unpinned installs -- a
# record and a pass -- instead of the piped installs they are, and
# `echo a \; pip install x==1` was denied for an install the shell never runs.
expect_deny "a piped install after an argument !"      "echo ! pip install evil | sh"
expect_deny "a piped install after an escaped ;"       "echo true \\; pip install evil | sh"
expect_pass "an install after an escaped ; is an echo" "echo a \\; pip install evil==1.0.0"
expect_pass "an escaped pipe is not a pipe"            "echo 'pip install evil==1.0.0' \\| sh"
expect_deny "! at a statement start still opens one"   "! pip install evil==1.0.0"
expect_deny "! after a keyword still opens one"        "if ! pip install evil==1.0.0; then :; fi"
expect_deny "{ at a statement start still opens one"   "{ pip install evil==1.0.0; }"
pass "escaped operators are characters, and ! and { open statements only where statements start"

# A newline inside quotes does not end a statement either. The line that closed
# a multi-line string used to be scanned alone, so its closing quote opened a
# region and hid what followed; and the lines inside the string were scanned as
# commands, so a commit message mentioning an install read as one.
expect_deny "an install after a multi-line double-quoted string" $'echo "line1\nline2" ; pip install evil==1.0.0'
expect_deny "an install after a multi-line single-quoted string" $'echo \'line1\nline2\' ; pip install evil==1.0.0'
expect_pass "a multi-line commit message that mentions an install" $'git commit -m "fix\npip install evil==1.0.0"'
expect_pass "a single-quoted multi-line message that mentions an install" $'git commit -m \'fix\npip install evil==1.0.0\''
pass "a newline inside quotes neither hides the next statement nor turns quoted text into one"

# --- 10. A spec names the package the manager installs ------------------------
# The deny message prescribes `safedeps check <eco> <pkg>@<spec>`, and an agent
# runs the prescription by itself. So a spec read from the wrong token is a
# bypass as soon as that token approves: `gem install --source <url> rake -v
# 13.0.0` prescribed `check rubygems <url>@13.0.0`, which approves (no advisory
# names a URL), and from then on any gem at 13.0.0 with that source passed.
# `cargo install --root <dir>`, `dotnet tool install --tool-path <dir>` and
# `poetry add 3to2@<v>` (read as `to2`) prescribed identities that approve the
# same way. Each row asserts the whole prescription; a row with an approval
# asserts that the old prescription's approval does not pass another package.
prescription() {
  local command="$1" safe out
  safe=$(mktemp -d "${tmp_root}/prescribe.XXXXXX")
  shift
  while [[ $# -ge 3 ]]; do
    ( export SAFEDEPS_HOME="${safe}"
      . lib/ledger/ledger.sh
      safedeps_ledger_write_approved_spec "$1" "$2" "$3" >/dev/null ) \
      || fail "the prescription fixture approval could be written"
    shift 3
  done
  out=$(jq -nc --arg c "${command}" --arg cwd "${project_dir}" \
    '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}' |
    HOME="${safe}/home" SAFEDEPS_HOME="${safe}" scripts/safedeps-pre-guard.sh 2>/dev/null)
  [[ "${out}" == *'"deny"'* ]] || { printf 'no-deny;'; return 0; }
  jq -r '.hookSpecificOutput.permissionDecisionReason' <<< "${out}" \
    | sed -nE 's/.*run `([^`]*)` first.*/\1/p' \
    | awk '{ gsub(/ && /, "\n"); print }' | awk 'NF { print $(NF-1), $NF }' | tr '\n' ';'
}
expect_prescription() {
  shard_row "expect_prescription|$*" || return 0
  local want="$1" got
  shift
  got=$(prescription "$@")
  [[ "${got}" == "${want}" ]] || fail "the deny for \`$1\` prescribes ${want} (got: ${got})"
}

expect_prescription 'rubygems rake@13.0.0;' 'gem install --source https://rubygems.org rake -v 13.0.0'
# The approval the old prescription produced does not pass any other gem.
expect_prescription 'rubygems evil@13.0.0;' 'gem install --source https://rubygems.org evil -v 13.0.0' \
  rubygems https://rubygems.org 13.0.0
expect_prescription 'rubygems rake@13.0.0;' 'gem install -s https://rubygems.org rake -v 13.0.0'
expect_prescription 'rubygems rake@13.0.0;' 'gem install -v 13.0.0 rake'
expect_prescription 'rubygems rake@13.0.0;' 'gem install rake --vers 13.0.0'
expect_prescription 'rubygems rails@7.1.0;' 'bundle add rails --source https://rubygems.org --version 7.1.0'
expect_prescription 'crates.io ripgrep@13.0.0;' 'cargo install --root /tmp/tools ripgrep --version 13.0.0'
expect_prescription 'crates.io evil@13.0.0;' 'cargo install --root /tmp/tools evil --version 13.0.0' \
  crates.io /tmp/tools 13.0.0
expect_prescription 'crates.io ripgrep@13.0.0;' 'cargo install ripgrep --version 13.0.0 2>&1'
# A redirection and its target are the shell's, so a version flag does not
# bind to them: these prescribed `check rubygems >/dev/null@13.0.0` beside the
# package.
expect_prescription 'rubygems rake@13.0.0;' 'gem install rake -v 13.0.0 >/dev/null'
expect_prescription 'rubygems rake@13.0.0;' 'gem install rake -v 13.0.0 2>/dev/null'
expect_prescription 'crates.io ripgrep@13.0.0;' 'cargo install ripgrep --version 13.0.0 >/dev/null'
expect_prescription 'npm left-pad@1.0.0;' 'pnpm add left-pad@1.0.0 >out@2.0.0'
# bash reads an unquoted `>` or `<` as an operator in the middle of a word too,
# so these install the pinned package and redirect. The pinned spec read as
# the operand `requests==2.19.0>/dev/null`, recorded unpinned and never checked.
expect_prescription 'pypi requests@2.19.0;' 'pip install requests==2.19.0>/dev/null'
expect_prescription 'pypi requests@2.19.0;' 'pip install requests==2.19.0 2>&1>/dev/null'
expect_prescription 'npm left-pad@1.0.0;' 'pnpm add left-pad@1.0.0>>install.log'
expect_prescription 'npm left-pad@1.0.0;' 'pnpm add left-pad@1.0.0&>/dev/null'
expect_prescription 'rubygems rake@13.0.0;' 'gem install rake -v 13.0.0>/dev/null'
expect_prescription 'npm evil@1.0.0;' 'npx evil@1.0.0</dev/null'
expect_prescription 'nuget dotnet-ef@8.0.0;' 'dotnet tool install --tool-path /tmp/tools dotnet-ef --version 8.0.0'
expect_prescription 'nuget evil@8.0.0;' 'dotnet tool install --tool-path /tmp/tools evil --version 8.0.0' \
  nuget /tmp/tools 8.0.0
expect_prescription 'nuget Serilog@3.1.1;' 'dotnet add package -s https://api.nuget.org/v3/index.json Serilog -v 3.1.1'
# .NET 10 spells it noun first, with the same options. `--project` takes the
# project as its value, so the version binds to the package, and once that is
# approved the install passes.
expect_prescription 'nuget Serilog@3.1.1;' 'dotnet package add Serilog --project App.csproj --version 3.1.1'
expect_prescription 'nuget evil@3.1.1;' 'dotnet package add evil --project App.csproj --version 3.1.1' \
  nuget App.csproj 3.1.1
expect_prescription 'no-deny;' 'dotnet package add Serilog --version 3.1.1 --project App.csproj' \
  nuget Serilog 3.1.1
expect_prescription 'no-deny;' 'dotnet package add Serilog -v 3.1.1' nuget Serilog 3.1.1
# `dotnet package update` (.NET 10) carries a version as `<id>@<version>`, and
# its `-v` is --verbosity, so the level is consumed and pins nothing.
expect_prescription 'nuget Fabrikam.WebApi@1.2.3;' 'dotnet package update Contoso.Utilities Fabrikam.WebApi@1.2.3'
expect_prescription 'no-deny;' 'dotnet package update Contoso.Utilities Fabrikam.WebApi@1.2.3' \
  nuget Fabrikam.WebApi 1.2.3
expect_prescription 'nuget Fabrikam.WebApi@1.2.3;' 'dotnet package update -v q --project src/App Fabrikam.WebApi@1.2.3' \
  nuget q 1.2.3 nuget src/App 1.2.3
# An option the table does not know leaves its value as an operand. That adds
# a check; it never replaces the package's own.
expect_prescription 'rubygems rake@13.0.0;rubygems rdoc@13.0.0;' 'gem install rake --document rdoc -v 13.0.0'
pass "a version flag pins the operands of the verb, not the value of an option in front of them"

# An npm alias installs its target. `left-pad@npm:evil-pkg` prescribed
# `check npm left-pad@npm`, which names neither package and never approves.
expect_prescription 'npm evil-pkg@1.0.0;' 'pnpm add left-pad@npm:evil-pkg@1.0.0'
expect_prescription 'npm @scope/evil@1.0.0;' 'npm install left-pad@npm:@scope/evil@1.0.0'
expect_prescription 'no-deny;' 'pnpm add left-pad@npm:evil-pkg'
# A name may start with a digit. `grep -o` read `7zip-bin@5.2.0` from its
# first letter, as `zip-bin`; the `==` reader read no spec for `3to2` at all.
expect_prescription 'npm 7zip-bin@5.2.0;' 'pnpm add 7zip-bin@5.2.0'
expect_prescription 'npm 7zip-bin@5.2.0;' 'pnpm add 7zip-bin@5.2.0' npm zip-bin 5.2.0
expect_prescription 'pypi 3to2@1.1.1;' 'pip install 3to2==1.1.1'
expect_prescription 'pypi 3to2@1.1.1;' 'poetry add 3to2@1.1.1'
expect_prescription 'pypi 3to2@1.1.1;' 'poetry add 3to2@1.1.1' pypi to2 1.1.1
pass "an alias is checked as its target, and a name that starts with a digit is read whole"

# A runner's options come before its package, and which of them take a value
# is the runner's own. One shared reading skipped every option and took the
# next token as the package, so the value was read instead and the pinned
# package was never checked: `uvx --python 3.12 ruff==0.1.0` recorded
# `pypi:3.12` and ran ruff unchecked. Each row asserts the prescription names
# the package; a row with the old misread approved asserts that it still does.
expect_prescription 'pypi ruff@0.1.0;' 'uvx --python 3.12 ruff==0.1.0'
expect_prescription 'pypi ruff@0.1.0;' 'uvx --python 3.12 ruff==0.1.0' pypi 3.12 0.1.0
expect_prescription 'pypi ruff@0.1.0;' 'uvx -p 3.12 ruff==0.1.0'
expect_prescription 'pypi ruff@0.1.0;' 'uv tool run --python 3.12 ruff==0.1.0'
expect_prescription 'npm evil@1.0.0;' 'npx --cache /tmp/c evil@1.0.0'
expect_prescription 'npm evil@1.0.0;' 'npx --cache /tmp/c evil@1.0.0' npm /tmp/c 1.0.0
expect_prescription 'npm evil@1.0.0;' 'npx --loglevel silent evil@1.0.0'
expect_prescription 'pypi evil@1.0.0;' 'pipx run --python python3.11 evil==1.0.0'
expect_prescription 'pypi evil@1.0.0;' 'pipx run --python python3.11 evil==1.0.0' pypi python3.11 1.0.0
# pipx's parser accepts a unique abbreviation of a long option.
expect_prescription 'pypi evil@1.0.0;' 'pipx run --pyth python3.11 evil==1.0.0'
expect_prescription 'npm evil@1.0.0;' 'pnpm dlx --reporter silent evil@1.0.0'
expect_prescription 'go example.com/m@v1.0.0;' 'go run -C sub example.com/m@v1.0.0'
expect_prescription 'go example.com/m@v1.0.0;' 'go run --tags x example.com/m@v1.0.0'
# `--with` adds a package beside the one that runs, so both are checked.
expect_prescription 'pypi evil@1.0.0;pypi ruff@0.1.0;' 'uvx --with evil==1.0.0 ruff==0.1.0'
expect_prescription 'pypi evil@1.0.0;pypi evil2@1.0.0;' 'pipx run --with evil==1.0.0 evil2==1.0.0'
# npm exec reads its arguments with nopt, which lets a boolean take a
# following `true` or `false` and `--color` take `always`. npx does not: its
# own first pass makes that token the package, so it is the package here too.
expect_prescription 'npm evil@1.0.0;' 'npm exec --yes false evil@1.0.0'
expect_prescription 'npm evil@1.0.0;' 'npm exec --color always evil@1.0.0'
expect_prescription 'no-deny;' 'npx --yes false evil@1.0.0'
pass "a runner's own options are read as that runner reads them, so the prescription names the package it runs"

# Outside quotes the shell drops a backslash and keeps the byte after it, so
# `ev\il==6.6.6` installs evil 6.6.6. The readers left the backslash in: the pip
# form read as an unpinned operand and was never checked, and the others
# prescribed an identity no advisory names, which approves and then lets the
# real package through. A row with the old misread approved asserts that it
# still prescribes the package.
for escaped in \
  'pip install ev\il==6.6.6' \
  'pip install evil\=\=6.6.6' \
  'uvx ev\il==6.6.6'
do
  expect_deny "the escaped install ${escaped}" "${escaped}"
done
expect_prescription 'pypi evil@6.6.6;' 'pip install ev\il==6.6.6'
expect_prescription 'npm evil@6.6.6;' 'pnpm add ev\il@6.6.6'
expect_prescription 'npm evil@6.6.6;' 'pnpm add ev\il@6.6.6' npm il 6.6.6
expect_prescription 'npm evil@6.6.6;' 'npx ev\il@6.6.6' npm il 6.6.6
expect_prescription 'rubygems rake@13.0.0;' 'gem install ra\ke -v 13.0.0'
expect_prescription 'rubygems rake@13.0.0;' 'gem install ra\ke -v 13.0.0' rubygems 'ra\ke' 13.0.0
expect_prescription 'crates.io ripgrep@13.0.0;' 'cargo install rip\grep --version 13.0.0'
# Inside quotes the shell keeps these backslashes, so the operand keeps them.
expect_prescription 'no-deny;' "pip install 'ev\\il==6.6.6'"
expect_prescription 'no-deny;' 'echo ev\il==6.6.6'
pass "a backslash outside quotes is read as the shell reads it, so the escaped name is the package checked"

# A `create` runs a package whose name the manager derives from its operand,
# and that package is the one the ledger has to judge. Approving `vite@5.0.0`
# must not pass `create-vite@5.0.0`: the prescription names the rewritten
# package, and a row with the operand itself approved still prescribes it.
# Each rewrite is the manager's own (guard_create_identity): npm's init.js,
# pnpm's convertToCreateName, Yarn 2+'s create.ts and Yarn 1's create.js, and
# bun's add_create_prefix.
expect_prescription 'npm create-evil@1.0.0;' 'npm create evil@1.0.0'
expect_prescription 'npm create-evil@1.0.0;' 'npm create evil@1.0.0' npm evil 1.0.0
expect_prescription 'npm create-evil@1.0.0;' 'npm innit evil@1.0.0' npm evil 1.0.0
expect_prescription 'npm create-evil@1.0.0;' 'npm cr evil@1.0.0'
expect_prescription 'npm @usr/create-foo@2.0.0;' 'npm init @usr/foo@2.0.0' npm @usr/foo 2.0.0
expect_prescription 'npm @usr/create@2.0.0;' 'npm init @usr@2.0.0'
expect_prescription 'npm create-create-vite@5.0.0;' 'npm init create-vite@5.0.0'
expect_prescription 'npm create-foo@1.0.0;' 'npm init --package evil@1.0.0 foo@1.0.0'
expect_prescription 'npm create-evil@1.0.0;' 'pnpm create evil@1.0.0' npm evil 1.0.0
expect_prescription 'npm create-evil@1.0.0;' 'pnpm create create-evil@1.0.0'
expect_prescription 'npm @usr/create-foo@2.0.0;' 'pnpm create @usr/foo@2.0.0'
expect_prescription 'npm create-evil@1.0.0;' 'yarn create evil@1.0.0' npm evil 1.0.0
expect_prescription 'npm create-evil@1.0.0;npm create-create-evil@1.0.0;' 'yarn create create-evil@1.0.0'
expect_prescription 'npm evil@1.0.0;' 'yarn create -p evil@1.0.0 foo'
expect_prescription 'npm create-evil@1.0.0;' 'bun create evil@1.0.0' npm evil 1.0.0
expect_prescription 'npm create-create-evil@1.0.0;' 'bun c create-evil@1.0.0'
expect_prescription 'npm @usr/create-foo@2.0.0;' 'bun create @usr/foo@2.0.0'
pass "a create is checked as the package its manager rewrites the operand into"

# --- 10b. One reader of quotes, redirections and cuts ---------------------------
# The extractor's words, the redirections it drops and the cuts between
# statements come from one lexing (the pieces view of shell_lex). Each had a
# reader of its own, and each reader had its own model of the quoting. An awk
# that knew `'...'`, `"..."` and a backslash read the `>` inside `"$(echo ">'")"`
# and `$'...\'>'` as a redirection, took the rest of the line as its target, and
# the pinned install after it passed unchecked; the sed before it read a
# redirection only at the start of a word and kept a quoted target with a real
# `2>` as operands; and the cut at `;` `|` `&` read no quotes at all, so
# `--log "a;b" evil==1.0.0` left evil in a piece that was not an install. Every
# form here is one bash and zsh run as the pinned install named in its
# prescription (measured with a stand-in printing its argv in place of the
# manager).
for row in \
  $'pypi evil@1.0.0;\tpip install --log "$(echo ">\'")" evil==1.0.0' \
  $'pypi evil@1.0.0;\tpip install --log $\'/tmp/x\\\'>\' evil==1.0.0' \
  $'pypi evil@1.0.0;\tpip install --log "`echo ">\'"`" evil==1.0.0' \
  $'npm evil@1.0.0;\tpnpm add --reporter "$(echo ">\'")" evil@1.0.0' \
  $'npm evil@1.0.0;\tnpm install --tag "$(echo ">\'")" evil@1.0.0' \
  $'pypi evil@1.0.0;\tpip install --log "$(echo ">\'")" evil==1.0.0 2>"$(echo "\'")"' \
  $'npm evil@1.0.0;\tnpm install --tag "$(echo ">\'")" evil@1.0.0 --foo "$(echo "\'")"' \
  $'pypi evil@1.0.0;\tpip install --log "$(echo "a b>\'")" evil==1.0.0' \
  $'pypi evil@1.0.0;\tpip install --log $\'\\\'\' --src \'>x\' evil==1.0.0' \
  $'pypi evil@1.0.0;\tpip install --log "x >\'" evil==1.0.0 2>"\'"' \
  $'npm evil@1.0.0;\tnpm install --tag "a >\'" evil@1.0.0 --foo "\'"' \
  $'npm evil@1.0.0;\tpnpm add --reporter "a >\'" evil@1.0.0 --filter "\'"' \
  $'pypi evil@1.0.0;\tpip install --log "a;b" evil==1.0.0' \
  $'pypi evil@1.0.0;\tpip install --log \'a|b\' evil==1.0.0' \
  $'pypi evil@1.0.0;\tpip install --log "a&b" evil==1.0.0' \
  $'pypi requests@2.19.0;\tpip install $\'requests==2.19.0\'' \
  $'pypi evil@1.0.0;\tpip install $\'ev\\x69l==1.0.0\'' \
  $'pypi evil@1.0.0;\tpip install $\'ev\\151l==1.0.0\''
do
  expect_prescription "${row%%$'\t'*}" "${row#*$'\t'}"
done
# gem reads the value of `--document` as optional, so the version also binds
# to the words of that value; the package gem installs is among them.
for gem_form in \
  $'gem install --document "$(echo ">\'")" rake -v 13.0.0' \
  $'gem install --document "a >\'" rake -v 13.0.0 --no-user-install "\'"'
do
  shard_row "gem_form: ${gem_form}" || continue
  got=$(prescription "${gem_form}")
  [[ "${got}" == *'rubygems rake@13.0.0;'* ]] || fail "the deny for \`${gem_form}\` prescribes rubygems rake@13.0.0 (got: ${got})"
done
pass "quotes, redirections and statement cuts are read by the one lexer, and each pinned install is checked as its package"

# The extractor still reads a word only as far as its quote removal goes. A
# `$'...'` escape whose value depends on the locale or is not one plain byte
# (`\u`, `\U`, `\c`, a NUL, a byte past 127) is not read as some other text: the
# reading is marked failed, and the install is UNDECIDED.
expect_undecided "an ANSI-C \\u escape in a spec" $'pip install $\'ev\\u0069l==1.0.0\''
expect_undecided "an ANSI-C NUL in a spec" $'pip install $\'evil\\0==1.0.0\''
pass "an escape the extractor cannot name is a failed reading, not another word"

# `sh -c` and `eval` scripts are read as the word the shell passes: quotes
# removed, escapes applied, words cut where the shell cuts them. The reader this
# replaced took the word up to its first matching quote, so a word that did not
# end there -- an escaped quote inside it, more quoting glued to it, an ANSI-C
# word, an unquoted word with escapes -- was read as far as it went, and the
# install the shell runs after it passed with no verdict (every form below was
# measured, with a stand-in for the manager, to run the install). A floor that
# marked such words unread made ordinary commands UNDECIDED, so each is now
# judged as the install it runs.
for payload_form in \
  'sh -c "echo \"hi\"; pip install evil==1.0.0"' \
  'eval "echo \"hi\"; pip install evil==1.0.0"' \
  $'sh -c \'echo hi\'"; pip install evil==1.0.0"' \
  $'sh -c $\'pip install evil==1.0.0\'' \
  'sh -c pip\ install\ evil==1.0.0' \
  'sh -c "pip install "evil==1.0.0' \
  $'bash -c \'echo \'\\\'\'hi\'\\\'\'; pip install evil==1.0.0\''
do
  expect_prescription 'pypi evil@1.0.0;' "${payload_form}"
done
expect_prescription 'crates.io evil@1.0.0;' 'bash -c "x=\"a\"; cargo install evil --version 1.0.0"'
# Ordinary scripts with escaped quotes are not installs: under the floor they
# were UNDECIDED (24 of 30 such commands, measured).
for ordinary in \
  'bash -c "cd \"$dir\" && npm run build"' \
  'bash -c "npm test -- --grep \"parser\""' \
  'bash -lc "nvm use 20 && npm run lint -- --fix \"src/**/*.ts\""' \
  'bash -c "cargo build --features \"a b\""' \
  'sh -c "git commit -m \"bump npm deps\""' \
  $'sh -c $\'npm run build\\n\'' \
  'bash -c npm\ run\ build' \
  'for d in a b; do bash -c "cd \"$d\" && npm test"; done'
do
  expect_pass "an ordinary script handed to a shell: ${ordinary}" "${ordinary}"
done
# A script handed to a shell is read as the word the shell passes, and the
# scripts inside it too, so a `sh -c` nested in a same-quoted one and an `eval`
# inside `sh -c` are judged as the installs they run. Both used to be outside the
# boundary: the payload reader stopped at the first matching quote.
expect_prescription 'pypi evil@1.0.0;' "sh -c 'sh -c '\\''pip install evil==1.0.0'\\'''"
expect_prescription 'pypi evil@1.0.0;' "sh -c 'eval \"pip install evil==1.0.0\"'"

# Controls: a plain payload is judged, and a head inside quoted text is data.
expect_prescription 'pypi evil@1.0.0;' 'sh -c "pip install evil==1.0.0"'
expect_pass "a sh -c head inside quoted text is data" $'echo \'sh -c "pip install evil==1.0.0"\''
expect_pass "a quoted mention of sh -c with escaped quotes" $'git commit -m \'run sh -c "npm test -- \\"x\\""\''
pass "a script handed to a shell is read as the word the shell passes"

# Any shell whose name ends in sh reads its -c script (macOS ships ksh, csh
# and tcsh), and options may come before -c. Narrowing the shell names to four
# passed `ksh -c "pip install ..."` with no verdict (caught in review).
for shell_form in \
  'ksh -c "pip install evil==1.0.0"' \
  '/bin/ksh -c "pip install evil==1.0.0"' \
  'csh -c "pip install evil==1.0.0"' \
  'tcsh -c "pip install evil==1.0.0"' \
  'fish -c "pip install evil==1.0.0"' \
  'bash -o pipefail -c "pip install evil==1.0.0"' \
  'bash -euo pipefail -c "pip install evil==1.0.0"' \
  'bash -c -- "pip install evil==1.0.0"'
do
  expect_prescription 'pypi evil@1.0.0;' "${shell_form}"
done
# A statement ends only at a top-level separator: not inside a substitution,
# an expansion or arithmetic, and not in a redirection operator. Cutting there
# left the install's words behind (`>| f`, `2<&-`, `$(pwd | sed x)`).
expect_prescription 'pypi evil@1.0.0;' 'pip install >| f evil==1.0.0'
expect_prescription 'crates.io evil@1.0.0;' 'cargo install 2<&- evil --version 1.0.0'
expect_prescription 'npm evil@1.0.0;' 'pnpm add --dir $(pwd | cat) evil@1.0.0'
expect_prescription 'pypi evil@1.0.0;' 'pip install --cache-dir $(pwd | sed s/x/y/) evil==1.0.0'
expect_prescription 'pypi evil@1.0.0;' 'pip install --retries $((1|2)) evil==1.0.0'
expect_prescription 'pypi evil@1.0.0;' 'pip install --log ${X:-a|b} evil==1.0.0'
expect_pass "a pipeline of ordinary commands" 'npm run build | tee out'
expect_pass "a pipeline with no install" 'echo hi | grep h'
pass "statement cuts and shell names are read the way the shell reads them"

# A word is cut where the shell cuts it: a blank inside quotes or an unquoted
# substitution does not split it. Split on blanks, a value option took half of
# `$(which python3)` and the rest read as the package, so the real pin went
# unchecked (caught in review).
expect_prescription 'pypi ruff@0.1.0;' 'uvx --python $(which python3) ruff==0.1.0'
expect_prescription 'pypi ruff@0.1.0;' 'uvx -p $(command -v python3) ruff==0.1.0'
expect_prescription 'pypi ruff@0.1.0;' 'uv tool run --python $(which python3) ruff==0.1.0'
expect_prescription 'pypi black@24.1.0;' 'pipx run --python $(which python3.11) black==24.1.0'
expect_prescription 'npm evil@1.0.0;' 'npx --cache $(mktemp -d /tmp/x.XXXX) evil@1.0.0'
expect_prescription 'npm evil@1.0.0;' 'pnpm dlx --dir $(git rev-parse --show-toplevel) evil@1.0.0'
expect_prescription 'npm evil@1.0.0;' 'bun add --cwd $(git rev-parse --show-toplevel) evil@1.0.0'
expect_prescription 'go example.com/m@v1.0.0;' 'go run -C $(git rev-parse --show-toplevel) example.com/m@v1.0.0'
expect_prescription 'pypi ruff@0.1.0;' 'uvx --python `which python3` ruff==0.1.0'
expect_prescription 'pypi ruff@0.1.0;' 'uvx --python "$(which python3)" ruff==0.1.0'
expect_prescription 'rubygems rake@13.0.0;' 'gem install --install-dir $(gem env gemdir) rake -v 13.0.0'
expect_pass "go run of a local package with an @ argument" 'go run ./cmd user@example.com'
# The same for a quoted or escaped blank, and for the empty word, which the
# shell passes: uv 0.10.11 reads `--python ""` as no preference and runs the
# package after it.
expect_prescription 'pypi ruff@0.1.0;' 'uvx --python "/opt/my python/bin/python3" ruff==0.1.0'
expect_prescription 'pypi evil@1.0.0;' 'uvx --python "" evil==1.0.0'
expect_prescription 'pypi evil@1.0.0;' 'pip install --log a\ b evil==1.0.0'
# A manager reads past the blanks at the ends of an argument, and pip past
# every blank in a requirement (PEP 508; pip's parser, measured), so a word
# kept whole is still the pin it names.
expect_prescription 'pypi evil@1.0.0;' 'pip install "evil==1.0.0 "'
expect_prescription 'pypi evil@1.0.0;' 'pip install "evil ==1.0.0"'
expect_prescription 'pypi requests@2.19.0;' 'pip install "requests == 2.19.0"'
expect_prescription 'npm evil@1.0.0;' 'npm install "evil@1.0.0 "'
pass "a word is cut where the shell cuts it, so a value option takes the whole value"

# `npm link` reads every argument with npm-package-arg and installs the
# registry ones into the global prefix (lib/commands/link.js:92-104); a path,
# a tarball, a git or a URL argument is linked as written. Reading only the
# first argument let a path in front hide the package after it: `npm link
# ./lib evil@1.0.0` installed evil globally and ran its scripts with no verdict
# and no record (measured against a fixture registry with a synthetic package).
for link_form in \
  'npm link ../lib evil@1.0.0' \
  'npm ln ../lib evil@1.0.0' \
  'npm link /tmp/x evil@1.0.0' \
  'npm link ~/lib evil@1.0.0' \
  'npm link ./a ./b evil@1.0.0' \
  'npm link lib/ evil@1.0.0' \
  'npm link evil@1.0.0 ../lib' \
  'npm link --save-dev ../lib evil@1.0.0' \
  'npm link evil@1.0.0' \
  'npm link ../lib npm:evil@1.0.0'
do
  expect_prescription 'npm evil@1.0.0;' "${link_form}"
done
for local_link in 'npm link ../lib' 'npm link' 'npm link .' 'npm link ../lib file:../other' 'npm link ./x.tgz'; do
  expect_pass "a link of local code: ${local_link}" "${local_link}"
done
# Which words npa reads as registry ones is npm's answer, rerun here against
# the npm on PATH like the command words above.
if command -v npm >/dev/null 2>&1 && command -v node >/dev/null 2>&1; then
  link_rc=0
  link_out=$(scripts/measure/npm-link-operands.sh 2>&1) || link_rc=$?
  case "${link_rc}" in
    0) pass "npm link arguments are read the way npm-package-arg reads them (scripts/measure/npm-link-operands.sh, npm $(npm --version))" ;;
    3) pass "npm link arguments against npm-package-arg # SKIP ${link_out}" ;;
    *) fail "npm link arguments are read the way npm-package-arg reads them ($(head -5 <<< "${link_out}" | tr '\n' ' '))" ;;
  esac
else
  pass "npm link arguments against npm-package-arg # SKIP no npm and node on PATH to ask"
fi
pass "npm link reads each argument, and a registry one is checked wherever it stands"

# --- 10c. npm's command is npm's reading of its arguments -----------------------
# The grammar's regexes try both readings of an option that may take a value.
# Where both matched they picked one, and for `npm --prefix x install
# evil@1.0.0` they picked `npm x` (exec): the pinned install was allowed with no
# ledger check, rewritten with --ignore-scripts, and recorded as the package
# `install`. main denied it, and `--prefix=x` was denied all along. npm reads
# both spellings alike, as an install into x (nopt with npm's option types), and
# so does the gate now. The directory exists so that the deny is the ledger's.
mkdir -p "${project_dir}/x"
printf '{"dependencies":{}}\n' > "${project_dir}/x/package.json"
for prefix_form in \
  'npm --prefix x install evil@1.0.0' \
  'npm --prefix=x install evil@1.0.0' \
  'npm -C x install evil@1.0.0' \
  'npm --prefix x --silent install evil@1.0.0' \
  'npm --cache x install evil@1.0.0' \
  'npm --prefi x install evil@1.0.0' \
  'npm -gC x install evil@1.0.0' \
  'npm --silent x evil@1.0.0'
do
  expect_prescription 'npm evil@1.0.0;' "${prefix_form}"
done
# The same reading names a runner's package. nopt reads an option npm does not
# define as a Boolean when it has no `=value` (nopt-lib.js parse: `typeof
# argType === 'undefined' && !hadEq`), so `x` is npm's command, and `x` is an
# alias of exec (lib/utils/cmd-list.js, `x: 'exec'`). With no --package, exec
# runs its first argument as the package (libnpmexec index.js:143,177:
# `packages.push(args[0])`), so npm fetches and runs the package `exec`, with
# evil@1.0.0 as that program's argument. The regex took `exec` for the command
# and denied evil@1.0.0, which npm never fetches; the record names `exec` (11).
# npm 11.19.0; scripts/measure/npm-option-reading.sh checks the nopt half.
expect_prescription 'no-deny;' 'npm --foo x exec evil@1.0.0'
# Which words npm takes as option values is nopt's answer, rerun here against
# the npm on PATH.
if command -v npm >/dev/null 2>&1 && command -v node >/dev/null 2>&1; then
  options_rc=0
  options_out=$(scripts/measure/npm-option-reading.sh 2>&1) || options_rc=$?
  case "${options_rc}" in
    0) pass "npm's arguments are read the way nopt reads them (scripts/measure/npm-option-reading.sh, npm $(npm --version))" ;;
    3) pass "npm's arguments against nopt # SKIP ${options_out}" ;;
    *) fail "npm's arguments are read the way nopt reads them ($(head -5 <<< "${options_out}" | tr '\n' ' '))" ;;
  esac
else
  pass "npm's arguments against nopt # SKIP no npm and node on PATH to ask"
fi
pass "an option's value never stands in for npm's command, in either spelling"

# --- 10d. Every manager's words are read with its own option table -------------
# The same question for the other managers, answered by safedeps_manager_read
# from each manager's table. Each row passed with no check before the tables:
# the value of a manager option before its command was read as the command or
# the package, a version attached to its option was not read as one, and an
# abbreviation or a `:` value was not read at all. scripts/test/manager-variants.sh
# holds the places a value stands by spelling; these are the spellings of the
# options themselves.
# bun takes the first word that does not start with `-` for its command, so
# this runs `bun x add evil@1.0.0` (bun 1.4.2, measured); both readings are
# judged.
expect_prescription 'npm evil@1.0.0;' 'bun --cwd x add evil@1.0.0'
expect_prescription 'npm evil@1.0.0;' 'pnpm --dir x add evil@1.0.0'
expect_prescription 'crates.io evil@1.0.0;' 'cargo --config x install evil --version 1.0.0'
expect_prescription 'rubygems rake@13.0.0;' 'gem install rake -v13.0.0'
expect_prescription 'rubygems rake@13.0.0;' 'gem install rake --vers 13.0.0'
expect_prescription 'rubygems rake@13.0.0;' 'gem install --inst x rake -v 13.0.0'
expect_prescription 'nuget dotnet-ef@8.0.0;' 'dotnet tool install dotnet-ef --version:8.0.0'
expect_prescription 'maven g:a@1.0;' 'mvn -D artifact=g:a:1.0 dependency:get'
expect_prescription 'pypi evil@1.0.0;' 'pip install --ta dir evil==1.0.0'
expect_prescription 'pypi evil@1.0.0;' 'pip --cache-dir x install evil==1.0.0'
expect_prescription 'pypi evil@1.0.0;' 'uv --directory x add evil==1.0.0'
expect_prescription 'go example.com/m@v1.0.0;' 'go run --C x example.com/m@v1.0.0'
# npm 10.8.2 does not define --min-release-age, so to it the word after the
# option is npm's command, and the install runs there (SAFEDEPS_G_NPM_OTHER).
expect_prescription 'npm evil@1.0.0;' 'npm --min-release-age install evil@1.0.0'
expect_prescription 'npm evil@1.0.0;' 'npx --min-release-age 3 evil@1.0.0'
# The table lists an option only where the manager reads a value for it. bun's
# runtime options were listed for every bun command, and bun reads them as
# switches where it installs, so the package after one was taken for its value
# and passed unchecked. `bun x -p` names the package, an entry `*` hid until a
# command's entry was looked up first. bunx reads `--cwd` as a switch. bun
# 1.4.2, measured: scripts/measure/manager-option-reading.sh.
expect_prescription 'npm evil@1.0.0;' 'bun add --print evil@1.0.0'
expect_prescription 'npm evil@1.0.0;' 'bun add -p evil@1.0.0'
expect_prescription 'npm evil@1.0.0;' 'bun i -c evil@1.0.0'
expect_prescription 'npm evil@1.0.0;' 'bun install --preload evil@1.0.0'
expect_prescription 'npm evil@1.0.0;' 'bun add -E -p evil@1.0.0 left-pad'
expect_prescription 'npm evil@1.0.0;' 'bun x -p evil@1.0.0 evil'
expect_prescription 'npm evil@1.0.0;' 'bunx --cwd evil@1.0.0 x'
expect_prescription 'no-deny;' 'bun add -F evil@1.0.0 left-pad'
# python reads one-letter options as getopt clusters them: `-Im pip` is `-I -m
# pip`, and an option that takes a value takes the rest of its word, so
# `-Impip` is too. `-c` ends python's options with a program.
expect_prescription 'pypi evil@1.0.0;' 'python3 -Im pip install evil==1.0.0'
expect_prescription 'pypi evil@1.0.0;' 'python3 -Impip install evil==1.0.0'
expect_prescription 'pypi evil@1.0.0;' 'python3 -IW ignore -m pip install evil==1.0.0'
expect_prescription 'pypi evil@1.0.0;' 'python3 -sEm pip install evil==1.0.0'
expect_prescription 'no-deny;' 'python3 -Ic pass -m pip install evil==1.0.0'
# RubyGems reads `name:version` as the name and a requirement, and a bare or
# `=` version is a pin (Gem::Command#extract_gem_name_and_version).
expect_prescription 'rubygems evil@1.0.0;' 'gem install evil:1.0.0'
expect_prescription 'rubygems evil@1.0.0;' 'gem install evil:=1.0.0'
pass "every manager's options are read with its own table: values, attached and abbreviated spellings, and both npm versions"
# Which words a manager takes as option values is the manager's answer, asked
# of every one on PATH but npm (npm is asked above). A table entry the manager
# does not read as a value fails; a manager not on PATH is skipped by name.
if shard_row "manager option reading"; then
  manager_rc=0
  manager_out=$(scripts/measure/manager-option-reading.sh 2>&1) || manager_rc=$?
  case "${manager_rc}" in
    0) pass "every manager on PATH reads its options the way the table says ($(grep -E '^asked:' <<< "${manager_out}" | cut -c1-200))" ;;
    3) pass "the managers' option reading # SKIP $(grep -E '^skipped:' <<< "${manager_out}" | cut -c1-200)" ;;
    *) fail "every manager on PATH reads its options the way the table says ($(grep -E '^OVER|forms,' <<< "${manager_out}" | head -5 | tr '\n' ' '))" ;;
  esac
fi

# --- 11. The UNGATED record names each operand the gate did not check ---------
# The record used to be a second parser: it read each statement on its own and
# asked the extractor "was this package pinned?" by name, so a pin on one
# operand quieted another of the same name (`pnpm add x@1 && pnpm add x`), and
# a version flag's value read as an unpinned package (`gem install rails -v
# 7.1.0`, gated AND recorded). It now reads the extractor's own output for each
# statement and names what it recorded.
#
# Each row first approves every spec the gate prescribes, the loop an agent
# follows, so the record code is actually reached. The oracle is the SET of
# recorded operands: a line merely existing hides a missing operand next to a
# present one. An empty set means no line at all.
recorded_operands() {
  local command="$1" safe out reason approved eco ps iter
  safe=$(mktemp -d "${tmp_root}/operands.XXXXXX")
  for iter in 1 2 3 4 5 6; do
    out=$(jq -nc --arg c "${command}" --arg cwd "${project_dir}" \
      '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}' |
      HOME="${safe}/home" SAFEDEPS_HOME="${safe}" scripts/safedeps-pre-guard.sh 2>/dev/null) || true
    [[ -n "${out}" ]] || break
    reason=$(jq -r '.hookSpecificOutput.permissionDecisionReason // empty' <<< "${out}" 2>/dev/null) || true
    [[ "${reason}" == *"install not approved"* ]] || break
    approved=0
    while read -r eco ps; do
      [[ -n "${ps}" ]] || continue
      ( export SAFEDEPS_HOME="${safe}"
        . lib/ledger/ledger.sh
        safedeps_ledger_write_approved_spec "${eco}" "${ps%@*}" "${ps##*@}" >/dev/null ) && approved=$((approved + 1))
    done < <(printf '%s\n' "${reason}" | sed -nE 's/.*run `([^`]*)` first.*/\1/p' \
      | awk '{ gsub(/ && /, "\n"); print }' | awk 'NF { print $(NF-1), $NF }')
    [[ "${approved}" -gt 0 ]] || break
  done
  { grep 'pre-guard UNGATED' "${safe}/advisory.log" 2>/dev/null || true; } \
    | sed -e 's/.* Unpinned: //' -e 's/\. Command: .*//' | sed 's/, /\n/g' | sort -u | tr '\n' ' ' | sed 's/ $//'
}

# expected<TAB>command. Newlines inside a command are written as $'\n'.
operand_rows=(
  # Recorded: an unpinned operand next to a pinned one of the same name.
  $'npm:left-pad\tpnpm add left-pad@1.0.0 && pnpm add left-pad'
  $'npm:left-pad\tyarn add left-pad@1.0.0 && yarn add left-pad'
  $'npm:left-pad\tbun add left-pad@1.0.0 && bun add left-pad'
  # (`npm i -g left-pad@1.0.0 && npm i -g left-pad` is an npm CLI install, so
  # its record is the PostToolUse hook's, below.)
  $'npm:left-pad\tyarn add left-pad@1.0.0 && yarn up left-pad'
  $'npm:left-pad\tpnpm add left-pad@1.0.0 && pnpm update left-pad --latest'
  $'npm:@scope/pkg\tpnpm add @scope/pkg@1.0.0 && pnpm add @scope/pkg'
  $'pypi:requests\tpip install requests==2.0.0 && pip install -U requests'
  $'pypi:requests>=3\tpip install requests==2.0.0 && pip install \'requests>=3\''
  $'pypi:requests==3.*\tpip install requests==2.0.0 && pip install \'requests==3.*\''
  $'pypi:requests\tpip install \'requests[socks]==2.0.0\' && pip install -U \'requests[socks]\''
  $'pypi:requests\tpip install requests==2.0.0 && pip install --force-reinstall requests'
  $'pypi:requests\tpip install requests==2.0.0 && uv add requests'
  $'pypi:requests\tpip install requests==2.0.0 && uv pip install -U requests'
  $'pypi:ruff\tpipx install ruff==0.1.0 && pipx install --force ruff'
  $'go:example.com/m\tgo get example.com/m@v1.0.0 && go get -u example.com/m'
  $'go:example.com/m\tgo get example.com/m@v1.0.0 && go get example.com/m'
  $'rubygems:rake\tgem install rake -v 13.0.0 && gem install rake'
  $'crates.io:ripgrep\tcargo install ripgrep@13.0.0 && cargo install --force ripgrep'
  $'crates.io:ripgrep\tcargo install ripgrep --version 13.0.0 && cargo install --force ripgrep'
  $'nuget:Newtonsoft.Json\tdotnet add package Newtonsoft.Json --version 13.0.1 && dotnet add package Newtonsoft.Json'
  $'nuget:dotnet-ef\tdotnet tool install -g dotnet-ef --version 7.0.0 && dotnet tool update -g dotnet-ef'
  $'nuget:Newtonsoft.Json\tdotnet package add Newtonsoft.Json --version 13.0.1 && dotnet package add Newtonsoft.Json'
  $'nuget:Serilog\tdotnet package add Serilog --project App.csproj'
  $'nuget:Contoso.Utilities\tdotnet package update Contoso.Utilities Fabrikam.WebApi@1.2.3'
  $'nuget:Fabrikam.WebApi\tdotnet package update Fabrikam.WebApi@1.2.3 && dotnet package update Fabrikam.WebApi'
  $'nuget:Contoso.Utilities\tdotnet package update --project src/App -v q Contoso.Utilities'
  $'nuget:Evil\tdotnet package update Evil -v 1.0.0'
  # The same across every way statements relate.
  $'npm:left-pad\tpnpm add left-pad@1.0.0 || pnpm add left-pad'
  $'npm:left-pad\tpnpm add left-pad@1.0.0; pnpm add left-pad'
  $'npm:left-pad\tpnpm add left-pad@1.0.0\npnpm add left-pad'
  $'npm:left-pad\tpnpm add left-pad@1.0.0 & pnpm add left-pad'
  $'npm:left-pad\t(pnpm add left-pad@1.0.0) && (pnpm add left-pad)'
  $'npm:left-pad\tif true; then pnpm add left-pad@1.0.0; fi; pnpm add left-pad'
  $'npm:left-pad\tpnpm add left-pad@1.0.0 && bash -c \'pnpm add left-pad\''
  $'npm:left-pad\tbash -c \'pnpm add left-pad@1.0.0\' && pnpm add left-pad'
  $'npm:left-pad\tpnpm add left-pad@1.0.0 && eval \'pnpm add left-pad\''
  $'npm:left-pad\tpnpm add left-pad@1.0.0 && echo "$(pnpm add left-pad)"'
  # And inside one statement.
  $'npm:left-pad\tpnpm add left-pad@1.0.0 left-pad'
  $'go:example.com/m\tgo get example.com/m@v1.0.0 example.com/m'
  $'crates.io:ripgrep\tcargo install ripgrep@13.0.0 ripgrep'
  # Runners.
  $'npm:cowsay\tnpx cowsay@1.0.0 && npx cowsay'
  $'npm:create-vite\tnpm create vite my-app'
  $'npm:create-vite\tnpm init vite -- --template react'
  $'npm:@usr/create\tnpm init @usr'
  $'npm:create-vite\tpnpm create vite my-app'
  $'npm:create-vite\tyarn create vite my-app'
  $'npm:create-create-vite npm:create-vite\tyarn create create-vite my-app'
  $'npm:create-vite\tbun create vite my-app'
  $'npm:@bun-examples/elysia\tbun create elysia my-app'
  # Quiet: a create that fetches nothing. npm init with no initializer writes a
  # package.json; a path is a local template.
  $'\tnpm init'
  $'\tnpm init -y'
  $'\tnpm init --scope @acme'
  $'\tbun create ./Component.tsx'
  $'pypi:evil\tuvx --with evil ruff==0.1.0'
  $'pypi:evil\tpipx run --with evil evil2==1.0.0'
  $'npm:false\tnpx --yes false evil@1.0.0'
  # Quiet: a runner option's value is not an operand, once the package it runs
  # is approved.
  $'\tuvx --python 3.12 ruff==0.1.0'
  $'\tnpx --cache /tmp/c evil@1.0.0'
  $'\tpipx run --python python3.11 evil==1.0.0'
  $'\tnpm exec --yes false evil@1.0.0'
  $'npm:cowsay\tnpx -p cowsay@1.0.0 -p cowsay cowsay'
  $'npm:cowsay\tnpx --package=cowsay@1.0.0 cowsay && npx --package=cowsay cowsay'
  $'pypi:ruff\tuvx ruff==0.1.0 && uvx ruff'
  $'pypi:ruff\tuvx --from ruff==0.1.0 ruff && uvx --from ruff ruff'
  # An alias is its target; a coordinate with no version is unpinned.
  $'npm:evil-pkg\tpnpm add left-pad@npm:evil-pkg'
  $'maven:-Dartifact=g:evil:\tmvn dependency:get -Dartifact=g:evil:'
  $'maven:-Dartifact=g:evil::jar\tmvn dependency:get -Dartifact=g:evil::jar'
  # Forms the previous release recorded, which a name join quieted.
  $'pypi:requests\tpip install requests===2.0.0 && pip install -U requests'
  $'pypi:requests\tpip3.11 install requests==2.0.0 && python3 -m pip install -U requests'
  $'go:example.com/m\tgo run example.com/m@v1.0.0 && go get example.com/m'
  # Quiet: routine pinned installs, once approved. A version flag's value is
  # not an operand, and an option's value is not either.
  $'\tgem install rails -v 7.1.0'
  $'\tgem install rails --version 7.1.0'
  $'\tgem install rails --version=7.1.0'
  $'\tbundle add rails --version 7.1.0'
  $'\tbundle add rails --version 7.1.0 --source https://rubygems.org'
  $'\tcargo install ripgrep --version 13.0.0'
  $'\tcargo install ripgrep --version=13.0.0'
  $'\tcargo add serde@1.0.0 --features derive'
  $'\tdotnet add package Serilog --version 3.1.1'
  $'\tdotnet add App.csproj package Serilog --version 3.1.1'
  $'\tdotnet package add Serilog --version 3.1.1'
  $'\tdotnet package add Serilog -v 3.1.1 --project App.csproj'
  $'\tdotnet package update Fabrikam.WebApi@1.2.3'
  $'\tdotnet package update --verbosity minimal --project src/App Fabrikam.WebApi@1.2.3'
  $'\tdotnet tool install --global dotnet-ef --version 8.0.0'
  $'\tgem install --source https://rubygems.org rake -v 13.0.0'
  $'\tpip install 3to2==1.1.1'
  $'\tpnpm add left-pad@npm:evil-pkg@1.0.0'
  # Quiet: an update with no operand moves every referenced package, and names
  # none. The record's unit is the operand, so it is outside, as `pnpm update`
  # and `yarn up` are.
  $'\tdotnet package update'
  $'\tdotnet package update --vulnerable'
  # Quiet: a pinned install inside a payload. The outer statement's payload is
  # blank to the extractor, so it is not read there either.
  $'\tbash -c \'pip install requests==2.31.0\''
  $'\teval \'pip install requests==2.31.0\''
  $'\techo "$(pip install requests==2.31.0)"'
  # Quiet: the exemption is the statement's. The npm CLI install is read by the
  # effect gate; the pnpm one is pinned.
  $'\tnpm install left-pad && pnpm add right-pad@1.0.0'
  # Quiet: npm leaves package-lock.json alone for these and records the
  # package in node_modules/.package-lock.json, which the effect gate reads
  # (measured with a real npm: scripts/test/lockless-forms.sh, section 1b). The
  # exemption is where the install lands, not a list of flags, so none of them
  # is spelled out in the guard.
  $'\tnpm install --no-save left-pad'
  $'\tnpm i --save=false left-pad'
  $'\tnpm install --no-package-lock left-pad'
  $'\tnpm install --package-lock=false left-pad'
  # Recorded: the statement is the unit of the exemption.
  $'npm:right-pad\tnpm install --no-save left-pad && pnpm add right-pad'
  # Quiet here: an npm CLI install, wherever the text sends it. Whether it was
  # read is the PostToolUse hook's record, from the install trace it finds where
  # the gate looked (scripts/test/effect-trace-grid.sh; the attribution of two
  # writers is pinned in section 9). Landing used to decide the exemption, and a
  # landing read wrong was a silent pass.
  $'\tnpm install left-pad && cd sub && npm install right-pad'
  $'\tnpm install left-pad && npm install -g right-pad'
  $'\tnpm install -gf left-pad'
  $'\tnpm i -g left-pad --global=false'
  # Recorded: `npm link <pkg>` installs a package the global tree lacks into
  # npm's global prefix from the registry (lib/commands/link.js linkInstall),
  # whatever the flags say, and only the link lands in the project, so a trace
  # there says nothing about the package. A path or no argument links local
  # code, quiet.
  $'npm:left-pad\tnpm link left-pad'
  $'npm:@scope/pkg\tnpm ln @scope/pkg'
  $'npm:left-pad\tnpm link --save left-pad'
  $'npm:left-pad\tnpm run build && npm link left-pad'
  $'\tnpm link'
  $'\tnpm link ../my-lib'
  # A path in front no longer hides the package; a path names none. A git or a
  # URL argument is fetched and installed like a registry one, and carries no
  # version the ledger can check, so it is recorded.
  $'npm:left-pad\tnpm link ../lib left-pad'
  $'npm:left-pad\tnpm link ~/lib left-pad'
  $'npm:left-pad npm:user/repo\tnpm link ../lib user/repo left-pad'
  $'npm:user/repo\tnpm link ../lib user/repo'
  $'npm:user/repo\tnpm link user/repo'
  $'npm:github:u/r\tnpm link github:u/r'
  $'npm:https://example.test/x.tgz\tnpm link ../lib https://example.test/x.tgz'
  # Recorded: a payload's npm install. Where it lands is decided inside the
  # payload, and the landing does not read inside it.
  $'npm:left-pad\tsh -c \'npm install left-pad\''
  $'npm:right-pad\tnpm install left-pad && bash -c \'npm install right-pad\''
  # Declared: recorded, and harmless. pip resolves both operands to the pin;
  # the second install is a no-op at runtime; the local binary does not exist
  # yet when the gate reads the command.
  $'pypi:requests\tpip install requests==2.0.0 requests'
  $'pypi:requests\tpip install requests==2.0.0 && pip install requests'
  $'npm:cowsay\tpnpm add cowsay@1.0.0 && npx cowsay'
  # `--no-binary` takes a value (pip's help: `--no-binary <format_control>`),
  # and it is in pip's table now, so its value is no operand. This row used
  # to record `pypi:requests` as a declared trade-off of a table that did not
  # know the option.
  $'\tpip install requests==2.0.0 --no-binary requests'
  # A redirection and its target are the shell's, not operands. The record
  # used to name `npm:>/dev/null` beside the package.
  $'npm:left-pad\tpnpm add left-pad >/dev/null'
  $'npm:left-pad\tpnpm add left-pad 2>err.log >out.log'
  $'npm:left-pad\tpnpm add left-pad > /dev/null'
  $'npm:left-pad\tpnpm add left-pad >>install.log'
  $'npm:left-pad\tpnpm add left-pad <input.txt'
  $'npm:left-pad\tpnpm add >/dev/null left-pad'
  $'npm:left-pad\tpnpm add left-pad >out@1.0.0'
  $'pypi:requests\tpip install requests >/dev/null'
  $'npm:cowsay\tnpx >/dev/null cowsay'
  $'\tpnpm add left-pad@1.0.0 >/dev/null'
  # An escaped byte is a plain byte; an escaped name is the name.
  $'npm:left-pad\tpnpm add left\\-pad'
  $'\tpip install ev\\il==6.6.6'
  # A quoted specifier starts with a quote, so it is not a redirection.
  $'pypi:requests>=3\tpip install \'requests>=3\''
  # Inside quotes, or escaped, `>` is a character; outside them it is an
  # operator wherever it stands, so unquoted `requests>=2.0` installs requests
  # and writes a file named `=2.0`. A digit is a file descriptor only as a
  # whole word: `x2>f` is the operand x2.
  $'pypi:requests>=3\tpip install "requests>=3"'
  $'pypi:requests>=3\tpip install requests\\>=3'
  $'pypi:requests\tpip install requests>=2.0'
  $'npm:left-pad\tpnpm add left-pad>/dev/null'
  $'npm:left-pad\tpnpm add left-pad 2>/dev/null'
  $'npm:x2\tpnpm add x2>/dev/null'
  $'npm:left-pad\tpnpm add left-pad&>/dev/null'
  # Controls: another name, and the npm CLI statement exempt on its own.
  $'npm:right-pad\tpnpm add left-pad@1.0.0 && pnpm add right-pad'
  $'npm:right-pad\tnpm install left-pad && pnpm add right-pad'
  # npm's command and operands are npm's reading of its arguments (10c): an
  # option's value is neither. The regex read `--prefix x` as `npm x` and
  # recorded `install`; the old operand walk recorded the value `x`.
  $'\tnpm --prefix x install left-pad'
  $'\tnpm --prefix x install evil@1.0.0'
  $'\tnpm --prefix=x install evil@1.0.0'
  # A global npm install's record is the PostToolUse hook's (below), so the
  # pre-guard names no operand for these; it named `install` and `x`.
  $'\tnpm -g --prefix x install left-pad'
  $'\tnpm install -g --prefix x left-pad'
  $'npm:exec\tnpm --foo x exec evil@1.0.0'
  # go run fetches by name only a package with a version suffix; anything else
  # is local code and the words after it are its arguments, so these name no
  # module. Each was recorded as its local package (`go:./cmd`).
  $'\tgo run ./cmd user@example.com'
  $'\tgo run . deploy@prod'
  $'\tgo run main.go --email admin@example.com'
  $'\tgo run ./cmd/migrate -database postgres://user:pass@localhost:5432/app up'
  $'\tgo run ./cmd/clone git@github.com:org/repo.git'
  $'\tgo run ./scripts/notify ops@example.com'
  $'\tgo run ./cmd example.com/m@v1.0.0'
  $'\tgo run -race ./cmd/api --db postgres://u@db/app'
  # An empty word names nothing; it was recorded as the lexer's blank mark.
  $'npm:left-pad\tpnpm add "" left-pad'
  $'\tnpx "" evil@1.0.0'
  $'\tuvx --python "" "" evil==1.0.0'
  # A version after `:` pins a gem.
  $'\tgem install evil:1.0.0'
  # Every operand of a cluster that ends in python's -m.
  $'pypi:left-pad\tpython3 -Im pip install left-pad'
  # The runtime option before bun's package takes no value, so the package is
  # the record (it passed with none).
  $'npm:left-pad\tbun add --print left-pad'
)

# The rows are independent sandboxes; run them eight at a time.
operand_out="${tmp_root}/operand-rows"
mkdir -p "${operand_out}"
row_index=0
# Each row is decided here, in the battery's own shell, before its background
# judgment starts; the check below reads only the rows this run judged.
operand_own=()
for row in "${operand_rows[@]}"; do
  if shard_row "operands: ${row}"; then
    operand_own[row_index]=1
    ( recorded_operands "${row#*$'\t'}" > "${operand_out}/${row_index}" ) &
  fi
  row_index=$((row_index + 1))
  (( row_index % 8 == 0 )) && wait
done
wait
row_index=0
for row in "${operand_rows[@]}"; do
  [[ -n "${operand_own[row_index]:-}" ]] || { row_index=$((row_index + 1)); continue; }
  want="${row%%$'\t'*}"
  got=$(cat "${operand_out}/${row_index}")
  [[ "${got}" == "${want}" ]] \
    || fail "the record names [${want}] for $(printf '%q' "${row#*$'\t'}") (got: [${got}])"
  row_index=$((row_index + 1))
done
pass "the UNGATED record names each unchecked operand, and only those (${#operand_rows[@]} rows)"

# Global however npm's option parser (nopt) spells it -- a short flag bundle,
# `=value` on a boolean, a negated `--no-` set to false, a unique abbreviation
# of `--location`. npm answers where each lands (`npm root`), so no spelling is
# listed in the guard; these read as project installs while a regex decided it.
# The answer picks where the gate looks and is written down; the record of the
# install is the PostToolUse hook's, which finds no trace in the project.
# `<global|project>|<command>`.
for carrier in \
  "global|npm install -gf left-pad" \
  "global|npm i -fg left-pad" \
  "global|npm i -g=true left-pad" \
  "global|npm i --locat=global left-pad" \
  "global|npm i --no-global=false left-pad" \
  "global|npm -g --prefix x install left-pad" \
  "global|npm install -g --prefix x left-pad" \
  "project|npm i -g left-pad --global=false"
do
  shard_row "carrier: ${carrier}" || continue
  where="${carrier%%|*}"
  form="${carrier#*|}"
  safe=$(mktemp -d "${tmp_root}/global-answer.XXXXXX")
  jq -nc --arg c "${form}" --arg cwd "${project_dir}" '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}' |
    HOME="${safe}/home" SAFEDEPS_HOME="${safe}" scripts/safedeps-pre-guard.sh >/dev/null 2>&1 || true
  if [[ "${where}" == global ]]; then
    grep -q 'npm installs this in its global prefix' "${safe}/advisory.log" 2>/dev/null \
      || fail "npm answers that this install is global: ${form}"
  else
    grep -q 'npm installs this in its global prefix' "${safe}/advisory.log" 2>/dev/null \
      && fail "the last value nopt reads wins, so this is a project install: ${form}"
  fi
  [[ -n "$(jq -r '.npm_trace.baseline // empty' "${safe}"/pending/*.json 2>/dev/null)" ]] \
    || fail "the post hook gets a trace baseline for it: ${form}"
done
pass "every spelling npm's option parser reads as global is global to the gate, and left to the post hook's trace check"


# --- A visible install does not switch the pipe check off ---------------------
# The hidden-install check ran only when the command held no visible install, so
# a piped install beside one passed with no lookup and no record. Every form
# here pins an approved spec on the visible side, and each is checked for the
# pipe rule's own reason: a deny from anywhere else (an unapproved spec, say)
# would pass a decision-only check with the rule removed. That is not
# hypothetical -- blanking the whole install match instead of its manager word
# hid the echoed install in the runner row, and a decision-only check stayed
# green because echo-cli was not approved.
beside_home="${tmp_root}/beside-approved"
mkdir -p "${beside_home}"
( export SAFEDEPS_HOME="${beside_home}"
  . lib/ledger/ledger.sh
  safedeps_ledger_write_approved_spec pypi requests 2.0.0 >/dev/null
  safedeps_ledger_write_approved_spec npm left-pad 1.3.0 >/dev/null
  safedeps_ledger_write_approved_spec npm echo-cli 1.0.0 >/dev/null
  safedeps_ledger_write_approved_spec pypi pip 24.0 >/dev/null
  # `pip install'evil==1'` is one word to the shell, `installevil==1`, and the
  # extractor reads it the same way. Approving that identity lets the row reach
  # the pipe rule. The row was written for a pass that set the visible install's
  # words aside (a quote glued to the verb must not be set aside, or everything
  # after it re-quotes), not for what pip would make of it.
  safedeps_ledger_write_approved_spec pypi installevil 1 >/dev/null
  safedeps_ledger_write_approved_spec npm mongoose 8.0.0 >/dev/null ) \
  || fail "the beside-visible fixture approvals could be written"
# No output is "pass", as in gate_decision: jq reads empty input as no value
# and prints nothing. beside_reason prints the deny reason, or nothing.
beside_guard() {
  jq -nc --arg c "$1" --arg cwd "${project_dir}" \
    '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}' |
    HOME="${tmp_root}/home-beside" SAFEDEPS_HOME="${beside_home}" scripts/safedeps-pre-guard.sh 2>/dev/null
}
beside_decision() {
  local out
  out=$(beside_guard "$1")
  if [[ -z "${out}" ]]; then
    printf 'pass'
  else
    jq -r '.hookSpecificOutput.permissionDecision // "pass"' <<< "${out}"
  fi
}
beside_reason() {
  local out
  out=$(beside_guard "$1")
  [[ -z "${out}" ]] || jq -r '.hookSpecificOutput.permissionDecisionReason // ""' <<< "${out}"
}
[[ "$(beside_decision 'pip install requests==2.0.0')" == "pass" ]] \
  || fail "beside-visible fixture: the approved pip install itself passes"
[[ "$(beside_decision 'npm install left-pad@1.3.0')" == "allow" ]] \
  || fail "beside-visible fixture: the approved npm install itself is allowed"
[[ "$(beside_decision 'npx -y echo-cli@1.0.0 hello')" != "deny" ]] \
  || fail "beside-visible fixture: the approved runner itself is not denied"

# Every form beside a visible install is written with @V@ just before the
# visible install's first word. beside_expect drops the marker and checks the
# row; the S1 loop at the end of this part puts `true ` there instead, which
# makes the visible install an argument and leaves every other byte as it was.
# The pipe question is the standalone one, asked of the same text, so the two
# must be denied or not denied together. Three rounds set the visible install's
# words aside first, and each left a row where they were not: a whole-word
# search (`\npip`), a word-start search (`%spip`, `cut -c2-`), and the install's
# own words, which the shell hands a producer through `$_` (W06-W08 below).
beside_rows=()
beside_expect() { # want label marked-form; want is pipe, deny, allow or pass
  local want="$1" label="$2" form="${3//@V@/}" got
  [[ "$3" == *@V@* ]] || fail "beside-visible row has no @V@ marker: ${label}"
  beside_rows+=("$3")
  # After the append: the S1 loop below reads beside_rows in every shard.
  shard_row "beside_expect|$1|$2|$3" || return 0
  if [[ "${want}" == pipe ]]; then
    grep -q 'reads like an install into a shell' <<< "$(beside_reason "${form}")" \
      || fail "${label}: denied by the pipe rule: $(printf '%q' "${form}")"
  else
    got=$(beside_decision "${form}")
    [[ "${got}" == "${want}" ]] || fail "${label} (want ${want}, got ${got}): $(printf '%q' "${form}")"
  fi
}

for piped in \
  "@V@pip install requests==2.0.0 && printf 'pip install evil==6.6.6' | sh" \
  "@V@pip install -r requirements.txt; printf 'pip install evil==6.6.6' | sh" \
  "@V@npm ci && printf 'cargo install evil@6.6.6' | sh" \
  "@V@npm install left-pad@1.3.0 && printf 'npm install -g evil@6.6.6' | sh" \
  "@V@pip install requests==2.0.0; echo pip install evil==6.6.6 | sh" \
  "@V@pip install requests==2.0.0 && sh -c \"printf 'pip install evil==6.6.6' | sh\"" \
  "@V@pip install requests==2.0.0 && x=\$(printf 'pip install evil==6.6.6' | sh)" \
  "@V@pip install requests==2.0.0 && printf 'pip install evil==6.6.6' | cat | /bin/sh" \
  "@V@pip install requests==2.0.0 && printf 'pip install evil==6.6.6' | env FOO=1 sh -s" \
  $'@V@pip install requests==2.0.0\ncat <<EOF | sh\npip install evil==6.6.6\nEOF' \
  "@V@pip install requests==2.0.0; c='pip install evil==6.6.6'; echo \"\$c\" | sh" \
  "@V@pip install requests==2.0.0; (printf 'pip install evil==6.6.6'; :) | sh" \
  "@V@npx -y echo-cli@1.0.0 pip install evil==6.6.6 | sh" \
  "@V@pip install'evil==1' ; printf 'pip install evil==6.6.6' | sh" \
  "@V@pip install requests==2.0.0 && printf 'pip\\tinstall evil==6.6.6' | sh" \
  "@V@pip install requests==2.0.0 && echo pip\\ install evil==6.6.6 | sh" \
  "@V@pip install requests==2.0.0 && printf pip' install evil==6.6.6' | sh" \
  "@V@pip install requests==2.0.0 && echo 'pipXinstall evil==6.6.6' | tr X ' ' | sh" \
  "@V@npm install left-pad@1.3.0 && printf 'pip%sinstall evil==6.6.6' ' ' | sh" \
  "PIP_INDEX_URL=x @V@pip install requests==2.0.0 && printf 'pip install evil==6.6.6' | sh" \
  "@V@pip install requests==2.0.0 && printf '\\npip install evil==6.6.6' | sh" \
  "@V@pip install requests==2.0.0 && printf '\\tpip install evil==6.6.6' | sh" \
  "@V@pip install requests==2.0.0 && printf '%spip install evil==6.6.6' '' | sh" \
  "@V@pip install requests==2.0.0 && printf 'xpip install evil==6.6.6' | cut -c2- | sh" \
  "@V@npm install left-pad@1.3.0 && printf '\\ncargo install evil@6.6.6' | sh" \
  "@V@pip install requests==2.0.0 && printf 'set -e\\npip install evil==6.6.6\\n' | sh" \
  "@V@pip install requests==2.0.0; echo -e '\\npip install evil==6.6.6' | bash" \
  "@V@npm install mongoose@8.0.0 && printf '\\npip install evil==6.6.6' | sh" \
  "@V@npm install \"mongoose@8.0.0\" && printf '\\npip install evil==6.6.6' | sh" \
  "@V@npx -y echo-cli@1.0.0 'pip' install evil==6.6.6 | sh" \
  "@V@pip install requests==2.0.0 && printf 'pip install evil==6.6.6' | { :; sh; }" \
  "@V@npm install left-pad@1.3.0 && printf 'cargo install evil@6.6.6' | if true; then sh; fi"
do
  beside_expect pipe "a piped install beside a visible one" "${piped}"
done
pass "an install piped into a shell is denied beside a visible install, even an approved one"

# The cost of asking the standalone question: a command that mixes an install
# with a pipe into a shell is denied, even when the pipe carries nothing to
# install, and the two have to run as separate commands. These ten kept the
# visible install's verdict while its words were set aside (68cc2f8 and
# before). Each line says why the text cannot clear its row.
beside_expect pipe "a file piped into sh: the gate cannot read the file, and H01 below writes it in the same command" \
  '@V@npm install left-pad@1.3.0 && cat setup.sh | sh'
beside_expect pipe "a harmless printf piped into sh: \$_ and the exec string read as plainly (W01, W06-W08)" \
  "@V@pip install requests==2.0.0 && printf 'echo hi' | sh"
beside_expect pipe "a heredoc with no install piped into sh: its body is a producer like printf, read beside install text" \
  $'@V@npm install left-pad@1.3.0\ncat <<EOF | sh\necho hi\nEOF'
beside_expect pipe "an assignment prefix and a harmless pipe into zsh: the prefix is the install's word, and the install's words are install text" \
  "PIP_INDEX_URL=x @V@pip install requests==2.0.0 && printf 'hi' | zsh -s"
beside_expect pipe "an npm_config_ prefix and a file piped into sh: the prefix does not change what the producer reads" \
  'npm_config_loglevel=warn @V@npm install left-pad@1.3.0 && cat setup.sh | sh'
beside_expect pipe "a package named mongoose and a file piped into sh: its words are no longer set aside, and \$_ hands them on" \
  '@V@npm install mongoose@8.0.0 && cat setup.sh | sh'
beside_expect pipe "a quoted package named mongoose and a file piped into sh: quoting does not keep \$_ from it" \
  '@V@npm install "mongoose@8.0.0" && cat setup.sh | sh'
beside_expect pipe "an option naming a manager and a file piped into sh: the option is install text, and the exec string hands it to the producer (W07, W08)" \
  '@V@npm install --save-bundle left-pad@1.3.0 && cat setup.sh | sh'
beside_expect pipe "an escape in a producer with no install: harmless only by its producer, which the text cannot vouch for" \
  "@V@npm install mongoose@8.0.0 && printf 'set -e\\necho built\\n' | sh"
beside_expect pipe "a heredoc written to a file, then a file piped into sh: the shape of H01, and the text cannot tell them apart" \
  $'@V@npm install left-pad@1.3.0 && cat <<EOF > notes.md\npip install x\nEOF\ncat s.sh | sh'
pass "an install and an unrelated pipe into a shell in one command are denied by the pipe rule"

# What does not go: no pipe into a shell, or a pipe that is data.
beside_expect allow "a visible install piped into a non-shell keeps its verdict" \
  '@V@npm install left-pad@1.3.0 2>&1 | tee log'
beside_expect pass "a quoted pipe idiom beside a visible install stays data" \
  '@V@pip install requests==2.0.0 && git commit -m "document the pip install x | sh idiom"'
beside_expect pass "the same producer piped into a non-shell keeps the visible install's verdict" \
  "@V@pip install requests==2.0.0 && printf '\\npip install evil==6.6.6' | cat"
beside_expect allow "a heredoc written to a file and not run keeps the visible install's verdict" \
  $'@V@npm install left-pad@1.3.0 && cat <<EOF > notes.md\npip install x\nEOF'
beside_expect deny "a heredoc piped into a shell beside a visible install is still read" \
  $'@V@npm install left-pad@1.3.0 && cat <<EOF | sh\npip install evil==6.6.6\nEOF'
beside_expect deny "an eval install after a heredoc beside a visible install is still read" \
  $'cat <<EOF > notes.md\nhello\nEOF\n@V@pip install requests==2.0.0 && eval "pip install evil==6.6.6"'
pass "a visible install with no pipe into a shell keeps its verdict"

# The verdict grid's cells (jetbi-20261005-062855) where the path beside a
# visible install passed what the standalone path denies. G1 carries the
# install in a heredoc that reaches the shell another way than a piped body:
# through a file, a descriptor, a group, a subshell, a variable or tee. G2
# carries it in a comment the producer reads back. G3 carries the visible
# install's own words: through the exec string, a function's text, or `$_`,
# which holds the last word of the visible install (W06-W08 passed with no
# record while those words were set aside).
for h in \
  $'@V@pip install requests==2.0.0\ncat <<EOF > s.sh\npip install evil==6.6.6\nEOF\ncat s.sh | sh' \
  $'@V@npm install left-pad@1.3.0 && cat <<\'EOF\' > s.sh\npip install evil==6.6.6\nEOF\ncat s.sh | sh' \
  $'exec 3<<EOF\npip install evil==6.6.6\nEOF\ncat <&3 | sh\n@V@pip install requests==2.0.0' \
  $'@V@pip install requests==2.0.0\n{ cat <<EOF\npip install evil==6.6.6\nEOF\n} | sh' \
  $'@V@npm install left-pad@1.3.0 && (cat <<EOF\npip install evil==6.6.6\nEOF\n) | sh' \
  $'x=$(cat <<EOF\npip install evil==6.6.6\nEOF\n); echo "$x" | sh\n@V@pip install requests==2.0.0' \
  $'@V@pip install requests==2.0.0\ntee s.sh >/dev/null <<EOF\npip install evil==6.6.6\nEOF\ncat s.sh | sh' \
  $'@V@npm install left-pad@1.3.0 && cat <<EOF > s.sh\nprintf \'\\npip install evil==6.6.6\'\nEOF\nsh s.sh | sh' \
  $'cat <<EOF > s.sh\ncargo install evil@6.6.6\nEOF\ncat s.sh | sh\n@V@pip install requests==2.0.0'
do
  beside_expect pipe "an install a heredoc carries to a shell (G1 H01-H07 H10 H14)" "${h}"
done
for c in \
  "@V@pip install requests==2.0.0 && echo \"\$BASH_EXECUTION_STRING\" | sed -n 's/.*#://p' | sh #:pip install evil==6.6.6" \
  "@V@npm install left-pad@1.3.0; echo \"\$ZSH_EXECUTION_STRING\" | sed -n 's/.*#://p' | sh #:pip install evil==6.6.6" \
  "@V@pip install requests==2.0.0 && ps -o args= -p \$\$ | sed -n 's/.*#://p' | sh #:pip install evil==6.6.6" \
  $'@V@npm install left-pad@1.3.0; echo "$BASH_EXECUTION_STRING" | sed -n \'s/^#://p\' | sh\n#:pip install evil==6.6.6'
do
  beside_expect pipe "an install a comment carries to a shell (G2 C02-C05)" "${c}"
done
for w in \
  "@V@pip install requests==2.0.0 && echo \"\$BASH_EXECUTION_STRING\" | sed -n 's/ &&.*//; s/requests==2.0.0/evil==6.6.6/p' | sh" \
  "@V@pip install requests==2.0.0 && echo \"\$ZSH_EXECUTION_STRING\" | sed -n 's/ &&.*//; s/requests==2.0.0/evil==6.6.6/p' | sh" \
  "@V@pip install pip==24.0 && echo \"\${_%%=*} install evil==6.6.6\" | sh" \
  "@V@npm install left-pad@1.3.0 --cache pip && echo \"\$_ install evil==6.6.6\" | sh" \
  "@V@pip install requests==2.0.0 --src pip && echo \"\$_ install evil==6.6.6\" | sh"
do
  beside_expect pipe "the visible install's own words carried to a shell (G3 W01 W02 W06-W08)" "${w}"
done
# A function's text is not read as a visible install, so these are denied as
# a hidden install either way; they are here for the loop below.
for w in \
  "f() { @V@pip install requests==2.0.0; }; declare -f f | sed -n 's/requests==2.0.0/evil==6.6.6/p' | sh" \
  "f() { @V@pip install requests==2.0.0; }; functions f | sed -n 's/requests==2.0.0/evil==6.6.6/p' | sh" \
  "f() { @V@pip install requests==2.0.0; }; type f | sed -n 's/requests==2.0.0/evil==6.6.6/p' | sh"
do
  beside_expect deny "a function's text carried to a shell (G3 W03-W05)" "${w}"
done
pass "installs a heredoc, a comment or the visible install's own words carry to a shell are denied beside a visible install"

# S1: every row above, with the visible install switched off by `true `, is
# denied exactly when the row is.
for row in "${beside_rows[@]}"; do
  shard_row "row: ${row}" || continue
  b=$(beside_decision "${row//@V@/}")
  s=$(beside_decision "${row//@V@/true }")
  [[ "${b}" == deny && "${s}" == deny || "${b}" != deny && "${s}" != deny ]] \
    || fail "beside a visible install the verdict is the standalone verdict (S1): ${b} beside, ${s} with it switched off: $(printf '%q' "${row//@V@/}")"
done
pass "beside a visible install every row gets the verdict it gets with the install switched off (${#beside_rows[@]} rows)"

# --- Ordinary commands that pass where the shells differ --------------------
# The gate reads a command as bash, as zsh and as dash, and the zsh and dash
# readings run only when the bash reading passes a place where the three
# differ: `((`, `$((`, a quote in arithmetic, `$[`, an apostrophe in "${...}",
# `$'...'`. Everyday commands pass such places all the time. Each of these
# keeps the verdict it had when the gate read one fixed reading -- measured
# against the release head before the readings were shells, with left-pad
# approved: six allows, nineteen unjudged, nothing moved. A reading that made
# them UNDECIDED, or an inert rewrite the readings disagree on, would show here.
for ordinary in \
  'pass|for ((i=0;i<3;i++)); do echo $i; done' \
  'pass|n=$((n+1)); echo "count: ${n:-0}"' \
  'allow|echo "${HOME:-/tmp}/x"; npm install left-pad@1.3.0' \
  'allow|((count++)); npm ci' \
  'allow|npm install left-pad@1.3.0 && echo "done $((1+2))"' \
  "pass|echo \"\${x:-it's}\"" \
  "pass|git commit -m \"fix: handle \${x:-'default'}\"" \
  'pass|x=$(( $(wc -l < /etc/hosts) + 1 )); echo $x' \
  'pass|echo $(( 1 << 4 ))' \
  $'pass|cat <<EOF\n$((1+2))\nEOF' \
  'pass|if (( $# > 0 )); then echo args; fi' \
  'allow|while ((i < 3)); do ((i++)); done; npm install left-pad@1.3.0' \
  "pass|echo \"\${PATH//:/ }\" | tr ' ' '\\n' | head" \
  "pass|printf '%s\\n' \"\${arr[@]:-none}\"" \
  'pass|x=${y:-$((2*3))}; echo $x' \
  'allow|echo "${name#prefix}" && npm install left-pad@1.3.0' \
  'pass|((1<<2)); echo shift' \
  'pass|echo "$((x<<2))"; ls' \
  'pass|case $x in (a) ((n++));; esac' \
  'pass|time ((x=5)); echo $x' \
  "pass|echo \"\${msg:-'quoted default'}\" > out.txt" \
  'pass|for f in *.js; do echo "${f%.js}"; done' \
  "allow|npm install left-pad@1.3.0; echo \"\${x:-'}\"" \
  'pass|arr=(a b c); echo "${#arr[@]}"' \
  'pass|echo $[1+1]'
do
  shard_row "ordinary: ${ordinary}" || continue
  [[ "$(beside_decision "${ordinary#*|}")" == "${ordinary%%|*}" ]] \
    || fail "an ordinary command where the shells differ keeps its verdict (${ordinary%%|*}): ${ordinary#*|} (got: $(beside_decision "${ordinary#*|}"))"
done
pass "ordinary commands where bash, zsh and dash read differently keep their verdicts (25)"

# A reader that lexed the joined lines again read them out of the context of
# the first lexing. Here an arithmetic expansion left open in an unquoted
# heredoc body (the `$((` on the second line, inside the body that `<<2`
# opens) used to land on one joined line with the install after the body, and
# lexed again at the top level its apostrophe opened a quote that never closed.
# bash and zsh run the install (fuzz form F19, seed 20261001, on macOS and
# Linux); the gate passed it. A context left open at the end of a body is body
# data now, so the install is read and checked, and no reader lexes a joined
# text any more (the rows below).
joined_reread=$'((echo $(echo ")") <<2) )\nx=$((cat <<EOF\nit\'s\nEOF\n) )\n2\npip install evil==6.6.6\n'
got=$(gate_reason "${joined_reread}")
[[ "${got}" == "deny "*"install not approved"* ]] || fail "an install after a heredoc body that leaves an arithmetic open is read and checked (got: ${got:0:120})"
pass "an install after a heredoc body that leaves a context open is read, not hidden by a reading of the body out of it"

# Live code in an unquoted heredoc body (`$(date)`, `${HOME}`, a backquote,
# `$((1+1))`) and the install on the line after the terminator. The
# recognizers, the landing, the extractor and the inert reading each lexed
# the joined view of the command again: that view blanked the body and its
# terminator line but kept the live code, so lexed again, `$(date)` stood where
# the next command did and took `pip install` for its arguments. The install
# passed with no verdict and no record, and an npm install ran unrewritten, in
# every shell measured (macOS bash 3.2, GNU bash 5.2, zsh -f, sh and dash;
# Linux bash 5.2 and dash; verdict buri-20261005-145152, which found it on
# v2.18.1 too). Each reader now lexes the command as written, once, and a
# payload on its own; scan-contract traces every lexing of a guard run and
# holds each to that. A plain body, `$HOME`, a quoted delimiter and a
# separator before the install were denied before: they are rows here too, as
# the controls the same bytes give.
heredoc_body_rows=(
  $'Q01|pip|cat <<E\n$(date)\nE\npip install evil==6.6.6\n'
  $'Q02|pip|cat > notes.txt <<EOF\nbuilt at $(date)\nEOF\npip install evil==6.6.6\n'
  $'Q03|npm|cat > notes.txt <<EOF\nbuilt at $(date)\nEOF\nnpm install evil\n'
  $'Q04|pip|cat <<E\n${HOME}\nE\npip install evil==6.6.6\n'
  $'Q05|pip|cat <<E\n`date`\nE\npip install evil==6.6.6\n'
  $'Q06|pip|cat <<E\n$((1+1))\nE\npip install evil==6.6.6\n'
  $'Q07|pip|cat <<-E\n\t$(date)\n\tE\npip install evil==6.6.6\n'
  $'Q08|pip|cat <<E\n$(date)\nE\necho ok && pip install evil==6.6.6\n'
  $'Q09|pip|cat <<E\n$(echo a\nb)\nE\npip install evil==6.6.6\n'
  $'Q10|pip|cat <<\'E\'\n$(date)\nE\npip install evil==6.6.6\n'
  $'Q11|pip|cat <<E\n$HOME\nE\npip install evil==6.6.6\n'
  $'Q12|pip|x=$(cat <<E\n$(date)\nE\n)\npip install evil==6.6.6\n'
  $'Q13|pip|cat <<E | wc -l\n$(date)\nE\npip install evil==6.6.6\n'
  $'Q14|npm|git commit -F - <<EOF\nfix $(date)\nEOF\nnpm ci\n'
  $'Q15|data|cat <<E\n$(date)\npip install evil==6.6.6\nE\n'
)
for row in "${heredoc_body_rows[@]}"; do
  id="${row%%|*}"; rest="${row#*|}"; kind="${rest%%|*}"; form="${rest#*|}"
  case "${kind}" in
    pip) expect_not_approved "${id}, an install after a heredoc body with live code in it," "${form}" ;;
    npm)
      shard_row "heredoc body rewrite: ${id}" || continue
      # Each form ends in a newline, and every rewrite drops a command's
      # trailing newlines (main 9017f9c does too, measured), so the rewrite
      # is compared with the form without its last newline.
      got=$(gate_rewrite "${form}")
      [[ -n "${got}" && "${got}" == *" --ignore-scripts"* && "${got// --ignore-scripts/}" == "${form%$'\n'}" ]] \
        || fail "${id}: an npm install after a heredoc body with live code in it is rewritten with --ignore-scripts (got: ${got:-no rewrite})"
      ;;
    data) expect_pass "${id}, an install that is a line of a heredoc body," "${form}" ;;
  esac
done
pass "an install on the line after a heredoc body with live code in it is read: pip denied, npm rewritten, and the body itself data (Q01-Q15)"

# --- A payload is read whole, whatever bytes it holds -------------------------
# The lexer hands the readers the scripts a command passes to `sh -c` and
# `eval` and the bodies of its substitutions. It used to print their bytes,
# each payload ending in \035, and the readers cut at that byte: a \035 the
# command wrote in a body or a script split one payload into two, each lexed
# alone, and the install after it passed with nothing recorded (verdict
# buri-20261005-181919, GS01-GS12; GS02, GS04-GS07 and GS12 were denied by
# v2.18.1). The records are numbers now, and the reader cuts the text it holds.
# The same rows hold two other payload paths that passed with nothing
# recorded on every tree to v2.18.1: a substitution inside a script, which no
# reader followed (C06, X03, X05, X15, Y08, Y09), and a $'...' escape the
# script reader did not decode, since its table was loaded for one view
# (X09-X12, Y03). Forms from scripts/measure/payload-boundary-forms.py and
# Buri's verdict.
gs=$'\035'
payload_rows=(
  "GS01|pip|sh -c 'echo \"${gs}\"; pip install evil==6.6.6'"
  "GS02|pip|x=\$(echo \"${gs}\"; pip install evil==6.6.6)"
  "GS03|pip|eval 'echo \"${gs}\"; pip install evil==6.6.6'"
  "GS04|pip|x=\`echo \"${gs}\"; pip install evil==6.6.6\`"
  "GS05|pip|cat <(echo \"${gs}\"; pip install evil==6.6.6)"
  "GS06|pip|echo \"\$(echo '${gs}'; pip install evil==6.6.6)\""
  "GS07|npm|x=\$(echo \"${gs}\"; npm install evil@6.6.6)"
  "GS08|npm|sh -c 'echo \"${gs}\"; npm install evil@6.6.6'"
  "GS09|pip|x=\$(echo \"a\"; pip install evil==6.6.6)"
  "GS10|pip|echo \"${gs}\"; pip install evil==6.6.6"
  "GS11|pip|bash -c 'printf \"%s\" \"${gs}\" && pip install evil==6.6.6'"
  "GS12|pip|git log --format=\"\$(echo '${gs}'; pip install evil==6.6.6)\""
  "C04|pip|sh -c \$'echo \"\\x1d\"; pip install evil==6.6.6'"
  "C05|npm|eval \$'echo \\x1d; npm install evil@6.6.6'"
  "C09|pip|sh -c \"sh -c 'echo ${gs}; pip install evil==6.6.6'\""
  "S11|npm|x=\$(echo \"a${gs}b\" && npm install evil@6.6.6)"
  "S13|pip|echo \`echo '${gs}'\` \$(pip install evil==6.6.6)"
  "C06|pip|sh -c 'x=\$(echo \"${gs}\"; pip install evil==6.6.6)'"
  "C06a|pip|sh -c 'x=\$(echo \"a\"; pip install evil==6.6.6)'"
  "X03|pip|sh -c 'x=\$(pip install evil==6.6.6)'"
  "X05|pip|sh -c 'echo \$(pip install evil==6.6.6)'"
  "X09|pip|sh -c \$'echo a\\npip install evil==6.6.6'"
  "X10|pip|eval \$'echo a\\npip install evil==6.6.6'"
  "X11|pip|sh -c \$'pip\\tinstall evil==6.6.6'"
  "X12|npm|sh -c \$'echo a\\nnpm install evil@6.6.6'"
  "X15|npm|sh -c 'x=\$(npm install evil@6.6.6)'"
  "Y09|pip|sh -c 'sh -c \"x=\\\$(pip install evil==6.6.6)\"'"
)
for row in "${payload_rows[@]}"; do
  id="${row%%|*}"; rest="${row#*|}"; form="${rest#*|}"
  expect_not_approved "${id}, an install in a payload the shell runs," "${form}"
done
# npm ci names no package, so the gate lets it through and the inert rewrite
# reads the payload: the flag goes inside it, where npm reads it.
rewrite_holds "x=\$(echo \"${gs}\"; npm ci)" "x=\$(echo \"${gs}\"; npm ci --ignore-scripts)" \
  || fail "Y04: an npm ci beside a \\035 in a substitution body is rewritten inside it (got: $(gate_rewrite "x=\$(echo \"${gs}\"; npm ci)"))"
rewrite_holds "sh -c 'echo \"${gs}\"; npm ci'" "sh -c 'echo \"${gs}\"; npm ci --ignore-scripts'" \
  || fail "Y05: an npm ci beside a \\035 in a script is rewritten inside it (got: $(gate_rewrite "sh -c 'echo \"${gs}\"; npm ci'"))"
rewrite_holds "sh -c 'x=\$(npm ci)'" "sh -c 'x=\$(npm ci --ignore-scripts)'" \
  || fail "Y08: an npm ci in a substitution inside a script is rewritten inside it (got: $(gate_rewrite "sh -c 'x=\$(npm ci)'"))"
# The rewrite cannot place a flag inside a $'...' script, so it says so: a
# recorded downgrade, never a command reported inert (inert_payload_spans).
y03_safe=$(mktemp -d "${tmp_root}/safe.XXXXXX")
y03_out=$(jq -nc --arg c $'bash -c $\'echo a\\nnpm ci\'' --arg cwd "${project_dir}" \
  '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}' |
  HOME="${tmp_root}/home" SAFEDEPS_HOME="${y03_safe}" scripts/safedeps-pre-guard.sh 2>/dev/null)
if [[ -n "${y03_out}" ]] || ! grep -qiE 'downgrade|unread|could not read|could not make' "${y03_safe}/advisory.log" 2>/dev/null; then
  fail "Y03: an npm ci in a \$'...' script is a recorded downgrade (got: ${y03_out:-pass}, advisory: $(head -3 "${y03_safe}/advisory.log" 2>/dev/null))"
fi
expect_pass "DT04, install text inside quotes beside a \\035, is data" "echo \"${gs} pip install evil==6.6.6\""
pass "a payload is read whole, whatever bytes it holds: ${#payload_rows[@]} forms denied as installs, three npm ci rewritten inside their payload, one recorded downgrade"

shard_end
printf 'consumer-forms passed\n'
