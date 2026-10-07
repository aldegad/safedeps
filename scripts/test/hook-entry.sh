#!/usr/bin/env bash
# safedeps: registered Rust hook entry battery.
#
# Real-core rows judge hook payloads; stub rows measure only the shim's argv,
# streams and explained failure contract. Installer rows use a stub builder.
#
# Retired Bash-only fixtures (the previous battery in 7d3a6a4):
# - missing install-grammar.sh: the core embeds the reader, with no sourced file;
# - conflicted guard and MERGE_HEAD: no Bash guard is parsed, and core failure
#   messages do not infer checkout activity from git metadata;
# - missing/crashing pre and crashing post scripts: the shim runs one binary;
#   its missing/nonzero pre/post rows below now cover those boundary failures;
# - Bash-entry installer with a missing pre script, and Bash-entry install
#   without a build: registration now always requires build/probe of the core.
# Healthy decisions, the process-limit EXIT trap and broken entry syntax are
# retained below on the registered path.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "${ROOT_DIR}"

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-entry.XXXXXX")
cleanup() { rm -rf "${tmp_root}"; }
trap cleanup EXIT
mkdir -p "${tmp_root}/home" "${tmp_root}/state" "${tmp_root}/project"
project_dir="${tmp_root}/project"
printf '{"dependencies":{}}\n' > "${project_dir}/package.json"

payload() {
  jq -nc --arg c "$1" --arg cwd "${project_dir}" \
    '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}'
}

# --- shim fixtures: stub binaries only -------------------------------------
# Legacy hook sentinels detect a fallback if one is ever reintroduced. They
# are generated traps, not source copies or product entry points.
native_repo="${tmp_root}/native-repo"
mkdir -p "${native_repo}/scripts" "${native_repo}/rust"
cp scripts/safedeps-hook-entry.sh "${native_repo}/scripts/"
# A bash hook that would leave a mark if anything ran it. Every row below
# checks that the mark is not there.
bash_ran="${tmp_root}/bash-hook-ran"
for hook in safedeps-pre-guard.sh safedeps-post-verify.sh; do
  printf '#!/usr/bin/env bash\n: > %q\nexit 0\n' "${bash_ran}" > "${native_repo}/scripts/${hook}"
  chmod +x "${native_repo}/scripts/${hook}"
done

# This platform's directory, read another way than the shim reads it (the shim
# reads bash's BASH_VERSINFO; this asks uname).
case "$(uname -s)" in Darwin) native_os=darwin ;; Linux) native_os=linux ;; *) fail "this battery knows no binary directory for $(uname -s)" ;; esac
case "$(uname -m)" in arm64|aarch64) native_arch=arm64 ;; x86_64|amd64) native_arch=x64 ;; *) fail "this battery knows no binary directory for $(uname -m)" ;; esac
native_dir="${native_repo}/bin/native/${native_os}-${native_arch}"
native_core="${native_dir}/safedeps-core"
native_seen="${tmp_root}/native-seen"

# A stand-in for the binary: it writes what it was called with and what it
# read, then does what the row asks.
native_stub() {
  mkdir -p "${native_dir}"
  {
    printf '#!/bin/sh\n'
    printf 'printf "%%s\\n" "$#" "$@" > %q\n' "${native_seen}.argv"
    printf 'cat > %q\n' "${native_seen}.stdin"
    printf '%s\n' "$1"
  } > "${native_core}"
  chmod 755 "${native_core}"
}

run_native() {
  local target="${1:-pre}" input
  rm -f "${bash_ran}" "${native_seen}.argv" "${native_seen}.stdin"
  entry_rc=0
  input=$(payload "ls -la")
  native_input="${input}"
  entry_out=$(HOME="${tmp_root}/home" SAFEDEPS_HOME="${tmp_root}/state" \
    "${native_repo}/scripts/safedeps-hook-entry.sh" "${target}" <<< "${input}" 2>"${tmp_root}/err") || entry_rc=$?
  entry_err=$(cat "${tmp_root}/err")
}

# A row that must be an explained deny: exit 2, the cause, the breadth, the
# repair, nothing on stdout, and no bash hook run in its place.
native_denies() {
  local label="$1" cause="$2"
  [[ ${entry_rc} -eq 2 ]] || fail "${label}: the entry exits 2, not ${entry_rc}"
  [[ -z "${entry_out}" ]] || fail "${label}: nothing is printed on stdout"
  grep -qF -- "${cause}" <<< "${entry_err}" || fail "${label}: the cause is named (${cause}); it said: ${entry_err}"
  grep -q "EVERY session" <<< "${entry_err}" || fail "${label}: the breadth is named"
  grep -q "Repair:" <<< "${entry_err}" || fail "${label}: the repair is named"
  [[ ! -e "${bash_ran}" ]] || fail "${label}: a bash hook ran in the binary's place"
}

native_stub 'printf "%s\n" "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"stand-in\"}}"; printf "stand-in stderr\n" >&2; exit 0'
run_native pre
[[ ${entry_rc} -eq 0 ]] || fail "native entry: a binary that exits 0 passes through (rc=${entry_rc}: ${entry_err})"
[[ "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<< "${entry_out}")" == "stand-in" ]] || fail "native entry: the binary's stdout passes through unchanged"
[[ "${entry_err}" == "stand-in stderr" ]] || fail "native entry: the binary's stderr passes through and the shim adds nothing (${entry_err})"
[[ "$(cat "${native_seen}.argv")" == $'1\npre' ]] || fail "native entry: the binary gets the one word pre ($(tr '\n' ' ' < "${native_seen}.argv"))"
[[ "$(cat "${native_seen}.stdin")" == "${native_input}" ]] || fail "native entry: the binary reads the hook input"
[[ ! -e "${bash_ran}" ]] || fail "native entry: no bash hook runs beside the binary"
pass "native entry: the binary gets pre and the hook input, and its answer passes through untouched"

run_native post
[[ ${entry_rc} -eq 0 && "$(cat "${native_seen}.argv")" == $'1\npost' ]] || fail "native entry: the post target runs the binary with post (rc=${entry_rc})"
pass "native entry: the post target runs the same binary with post"

# The platform is bash's own answer. A value of OSTYPE, HOSTTYPE or MACHTYPE
# inherited from the environment is kept by bash (measured), so a shim that
# read them would look for another machine's binary.
entry_rc=0
entry_out=$(OSTYPE=planted HOSTTYPE=planted MACHTYPE=planted-planted-planted HOME="${tmp_root}/home" SAFEDEPS_HOME="${tmp_root}/state" \
  "${native_repo}/scripts/safedeps-hook-entry.sh" pre <<< "$(payload "ls -la")" 2>"${tmp_root}/err") || entry_rc=$?
[[ ${entry_rc} -eq 0 && "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<< "${entry_out}")" == "stand-in" ]] \
  || fail "native entry: OSTYPE, HOSTTYPE and MACHTYPE from the environment do not choose the binary (rc=${entry_rc}: $(cat "${tmp_root}/err"))"
pass "native entry: the platform comes from bash itself, not from OSTYPE or HOSTTYPE in the environment"

# The shim reads nothing else from the environment either. Every variable it
# names in capitals is listed here; a new one is a switch someone has to
# explain. (BASH_VERSINFO is bash's own and read-only.)
native_names=$(grep -v '^[[:space:]]*#' scripts/safedeps-hook-entry.sh | grep -oE '\$\{?[A-Z][A-Z0-9_]*' | sed 's/^\${*//' | sort -u | tr '\n' ' ')
[[ "${native_names}" == "BASH_VERSINFO " ]] || fail "native entry: the shim reads only BASH_VERSINFO in capitals, found: ${native_names}"
pass "native entry: the shim reads no environment variable, so none can choose or switch off the binary"

native_stub 'exit 3'
run_native pre
native_denies "a binary that exits 3" "ended with exit 3"
grep -q "defect in safedeps" <<< "${entry_err}" || fail "a non-zero exit is called a defect, not a finding"
grep -q "stay blocked fail-closed" <<< "${entry_err}" || fail "a non-zero exit on pre: the consequence is the blocked Bash call"
pass "native entry: a binary that exits non-zero is an explained deny"

run_native post
native_denies "a binary that exits 3 on post" "ended with exit 3"
grep -q "unverified" <<< "${entry_err}" || fail "a non-zero exit on post: the consequence is the unverified install"
pass "native entry: on post the same failure is a loud report that the install is unverified"

native_stub 'kill -ABRT $$'
run_native pre
native_denies "a binary that aborts" "aborted (signal 6, exit 134)"
grep -q "panic" <<< "${entry_err}" || fail "an abort is named as a panic in the core"
pass "native entry: an abort (the core's panic) is an explained deny"

native_stub 'kill -KILL $$'
run_native pre
native_denies "a binary that is killed" "stopped by signal 9"
pass "native entry: a binary stopped by another signal is an explained deny"

chmod 644 "${native_core}"
run_native pre
native_denies "a binary without its exec bit" "is not an executable file"
pass "native entry: a binary that lost its exec bit is an explained deny"

# A file the system will not execute. Bytes with a NUL in the first line: bash
# takes them for a binary it cannot run and answers 126. (A text file with no
# program header would be run as a shell script, which is another row's case.)
printf '\0\0\0\0not a program for any machine\n' > "${native_core}"
chmod 755 "${native_core}"
run_native pre
native_denies "a binary the system refuses" "the system refused to execute"
pass "native entry: a binary the system refuses to execute (exit 126) is an explained deny"

native_stub 'exit 127'
run_native pre
native_denies "a binary that exits 127" "went missing or is not a program (exit 127)"
pass "native entry: exit 127 is an explained deny"

rm -f "${native_core}"
run_native pre
native_denies "a platform directory with no binary" "binary is missing"
grep -qF "scripts/build-core.sh" <<< "${entry_err}" || fail "in a checkout the repair is to build the binary"
pass "native entry: a missing binary is an explained deny, and a checkout is told to build it"

rmdir "${native_dir}"
mkdir -p "${native_repo}/bin/native/plan9-mips"
printf '#!/bin/sh\nexit 0\n' > "${native_repo}/bin/native/plan9-mips/safedeps-core"
chmod 755 "${native_repo}/bin/native/plan9-mips/safedeps-core"
run_native pre
native_denies "a platform this install carries no binary for" "no safedeps-core binary for this platform"
grep -qF "this install carries: plan9-mips" <<< "${entry_err}" || fail "the platforms the install does carry are listed"
pass "native entry: a platform with no binary is an explained deny that names the platform and what the install carries"

rm -rf "${native_repo:?}/bin"
run_native pre
native_denies "an install with no binaries" "no safedeps-core binary at all"
pass "native entry: an install with no bin/native is an explained deny"

# An installed package has no rust/ directory, so it cannot build: it is told
# to reinstall.
rmdir "${native_repo}/rust"
run_native pre
native_denies "a package install with no binaries" "no safedeps-core binary at all"
grep -q "reinstall the package" <<< "${entry_err}" || fail "an installed package is told to reinstall, not to build"
if grep -qF "build-core.sh" <<< "${entry_err}"; then
  fail "an installed package is not told to run a build script it does not have"
fi
mkdir "${native_repo}/rust"
pass "native entry: an installed package with no binary is told to reinstall"

entry_rc=0
"${native_repo}/scripts/safedeps-hook-entry.sh" 2>"${tmp_root}/err" < /dev/null || entry_rc=$?
[[ ${entry_rc} -eq 2 ]] && grep -q "usage" "${tmp_root}/err" || fail "native entry: no target is a usage error with exit 2 (rc=${entry_rc})"
pass "native entry: a call with no target is refused"

# A real process limit exercises the EXIT trap. Root or a host that refuses
# the limit reports the existing allowed skip explicitly.
probe_rc=0
bash -c 'ulimit -Su 1 2>/dev/null || exit 3; ( exit 0 )' 2>/dev/null || probe_rc=$?
if [[ ${probe_rc} -eq 0 || ${probe_rc} -eq 3 ]]; then
  printf 'ok - native out-of-processes row SKIPPED (the process limit does not bind this user)\n'
else
  native_stub 'exit 0'
  entry_rc=0
  entry_out=$(payload "ls -la" |
    HOME="${tmp_root}/home" SAFEDEPS_HOME="${tmp_root}/state" \
    bash -c 'ulimit -Su 1; exec bash "$0" pre' "${native_repo}/scripts/safedeps-hook-entry.sh" 2>"${tmp_root}/err") || entry_rc=$?
  entry_err=$(cat "${tmp_root}/err")
  [[ ${entry_rc} -eq 2 ]] || fail "native entry, out of processes: the entry denies instead of exiting ${entry_rc}, which is non-blocking"
  grep -q "could not start a process" <<< "${entry_err}" || fail "native entry, out of processes: the cause is named (${entry_err})"
  pass "native entry: out of processes is an explained deny, not a non-blocking 128"
fi

# The shim's own parse failure still exits 2. Inject before the first
# executable statement, rather than relying on a numbered comment line.
awk '/^set -u$/ { print "<<<<<<< HEAD" } { print }' \
  scripts/safedeps-hook-entry.sh > "${native_repo}/scripts/safedeps-hook-entry.sh"
run_native pre
[[ ${entry_rc} -eq 2 ]] || fail "broken entry syntax blocks (rc=${entry_rc})"
grep -q "syntax error" <<< "${entry_err}" || fail "broken entry: bash parse error surfaces"
pass "native entry: broken shim syntax blocks with exit 2"
cp scripts/safedeps-hook-entry.sh "${native_repo}/scripts/"

# --- real core: hook judgments through the registered executable -----------
# The host runner prepared this tree's core before the battery. Do not build
# in a row and do not count a stand-in as a judgment from the Rust core.
real_core="${ROOT_DIR}/bin/native/${native_os}-${native_arch}/safedeps-core"
[[ -x "${real_core}" ]] || fail "real core was not prepared: ${real_core}"
[[ "$("${real_core}" stamp --check)" == ok ]] || fail "real core stamp matches this source"
pass "real core: prepared binary matches this checkout's source"

core_entry="${ROOT_DIR}/scripts/safedeps-hook-entry.sh"
run_core() {
  local command="$1" target="${2:-pre}" input
  input=$(payload "${command}")
  entry_rc=0
  entry_out=$(HOME="${tmp_root}/home" SAFEDEPS_HOME="${tmp_root}/core-state" \
    "${core_entry}" "${target}" <<< "${input}" 2>"${tmp_root}/err") || entry_rc=$?
  entry_err=$(cat "${tmp_root}/err")
}
run_core "ls -la"
[[ ${entry_rc} -eq 0 && -z "${entry_out}" && -z "${entry_err}" ]] \
  || fail "real core: benign pre passes through (rc=${entry_rc}: ${entry_out} ${entry_err})"
pass "real core: benign pre passes through untouched"

run_core "npm install left-pad"
jq -e '.hookSpecificOutput | .permissionDecision == "allow" and (.updatedInput.command | contains("--ignore-scripts"))' \
  <<< "${entry_out}" >/dev/null \
  && [[ ${entry_rc} -eq 0 ]] || fail "real core: npm rewrite passes through (rc=${entry_rc}: ${entry_out} ${entry_err})"
pass "real core: npm inert-install rewrite passes through"

run_core "pip install requests==2.31.0"
jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<< "${entry_out}" >/dev/null \
  && [[ ${entry_rc} -eq 0 ]] || fail "real core: unapproved pip denies (rc=${entry_rc}: ${entry_out} ${entry_err})"
pass "real core: command-gate deny passes through"

run_core "ls -la" post
[[ ${entry_rc} -eq 0 && -z "${entry_out}" && -z "${entry_err}" ]] \
  || fail "real core: benign post passes through (rc=${entry_rc}: ${entry_out} ${entry_err})"
pass "real core: benign post passes through untouched"

# A copied core first answers beside the matching source, then refuses the
# same payload after that source changes. Only the isolated copy is mutated.
stale_repo="${tmp_root}/stale-core"
mkdir -p "${stale_repo}/scripts" "${stale_repo}/rust" "${stale_repo}/bin/native/${native_os}-${native_arch}"
cp scripts/safedeps-hook-entry.sh "${stale_repo}/scripts/"
cp rust/Cargo.toml rust/Cargo.lock rust/build.rs "${stale_repo}/rust/"
cp -R rust/src "${stale_repo}/rust/"
cp "${real_core}" "${stale_repo}/bin/native/${native_os}-${native_arch}/safedeps-core"
core_entry="${stale_repo}/scripts/safedeps-hook-entry.sh"
run_core "ls -la"
[[ ${entry_rc} -eq 0 && -z "${entry_out}" && -z "${entry_err}" ]] \
  || fail "real core: copied source and binary answer before mutation (${entry_out} ${entry_err})"
printf '\n// entry battery source mutation\n' >> "${stale_repo}/rust/src/main.rs"
run_core "ls -la"
jq -e '.hookSpecificOutput | .permissionDecision == "deny" and (.permissionDecisionReason | contains("built from another source"))' \
  <<< "${entry_out}" >/dev/null \
  && [[ ${entry_rc} -eq 0 ]] || fail "real core: source mismatch denies with its reason (${entry_out} ${entry_err})"
pass "real core: a source mismatch is a deny passed through the entry"

run_core "ls -la" post
[[ ${entry_rc} -eq 0 && -z "${entry_out}" && "${entry_err}" == *"UNVERIFIED"* && "${entry_err}" == *"built from another source"* ]] \
  || fail "real core: post names the source mismatch as unverified (${entry_out} ${entry_err})"
pass "real core: post reports a source mismatch as unverified"

# The no-binary control uses the same copy that just ran the real core.
rm "${stale_repo}/bin/native/${native_os}-${native_arch}/safedeps-core"
run_core "ls -la"
native_denies "real-core copy with its binary removed" "binary is missing"
pass "real core: removing the binary makes the registered entry deny with an explanation"

# --- installer fixtures: stub builder and stub binaries, no core judgment ---
# These rows measure preparation before registration, not Rust decisions.
marker='# safedeps-entry: runs bin/native/<os>-<arch>/safedeps-core'
grep -qxF "${marker}" scripts/safedeps-hook-entry.sh || fail "the registered entry carries the core identity line"
[[ -x scripts/safedeps-hook-entry.sh ]] || fail "the registered entry is executable"
pass "installer: the registered entry identifies the core and is executable"

installer_repo() { # <dir> <build stub body or "">
  local dir="$1"
  mkdir -p "${dir}/scripts/install" "${dir}/bin"
  cp scripts/install/install-safedeps-hooks.mjs "${dir}/scripts/install/"
  cp scripts/safedeps-hook-entry.sh "${dir}/scripts/"
  printf '#!/usr/bin/env bash\n' > "${dir}/bin/safedeps"
  if [[ -n "$2" ]]; then
    mkdir -p "${dir}/rust"
    printf '[package]\nname = "safedeps-core"\n' > "${dir}/rust/Cargo.toml"
    printf '#!/usr/bin/env bash\n: > %q\n%s\n' "${dir}/build-ran" "$2" > "${dir}/scripts/build-core.sh"
    chmod +x "${dir}/scripts/build-core.sh"
  fi
}
run_installer() { # <repo> <home>
  local rc=0
  mkdir -p "$2/.claude" "$2/.codex"
  HOME="$2" node "$1/scripts/install/install-safedeps-hooks.mjs" > "${tmp_root}/inst.out" 2>&1 || rc=$?
  installer_rc=${rc}
  installer_out=$(cat "${tmp_root}/inst.out")
}

inst="${tmp_root}/inst-checkout"
installer_repo "${inst}" \
  "mkdir -p $(printf '%q' "${inst}/bin/native/${native_os}-${native_arch}") && printf '#!/bin/sh\nexit 0\n' > $(printf '%q' "${inst}/bin/native/${native_os}-${native_arch}/safedeps-core") && chmod 755 $(printf '%q' "${inst}/bin/native/${native_os}-${native_arch}/safedeps-core")"
run_installer "${inst}" "${tmp_root}/inst-home-1"
[[ ${installer_rc} -eq 0 ]] || fail "installer, checkout, native entry: exits 0 (${installer_rc}: ${installer_out})"
[[ -e "${inst}/build-ran" ]] || fail "installer, checkout, native entry: scripts/build-core.sh ran"
jq -e '[.hooks.PreToolUse[]?.hooks[]?.command] | any(endswith("safedeps-hook-entry.sh pre"))' "${tmp_root}/inst-home-1/.claude/settings.json" >/dev/null \
  || fail "installer, checkout, native entry: the hooks are registered after the build"
pass "installer: in a checkout, an entry that runs the core builds it, then registers"

inst="${tmp_root}/inst-nocargo"
installer_repo "${inst}" "echo 'build-core: cargo is not on PATH, so the core cannot be built from this checkout.' >&2; exit 1"
run_installer "${inst}" "${tmp_root}/inst-home-2"
[[ ${installer_rc} -ne 0 ]] || fail "installer, checkout, build fails: the installer does not exit 0"
grep -q "cargo is not on PATH" <<< "${installer_out}" || fail "installer, build fails: the build's reason reaches the user (${installer_out})"
grep -q "Nothing was registered" <<< "${installer_out}" || fail "installer, build fails: it says nothing was registered"
[[ ! -e "${tmp_root}/inst-home-2/.claude/settings.json" ]] || fail "installer, build fails: no engine config is written"
[[ ! -e "${tmp_root}/inst-home-2/.claude/skills/safedeps" ]] || fail "installer, build fails: the skill is not linked"
pass "installer: a checkout that cannot build the core stops with the reason and registers nothing"

inst="${tmp_root}/inst-package"
installer_repo "${inst}" ""
run_installer "${inst}" "${tmp_root}/inst-home-3"
[[ ${installer_rc} -ne 0 ]] || fail "installer, package with no binary: the installer does not exit 0"
grep -q "has no safedeps-core binary at all" <<< "${installer_out}" || fail "installer, package with no binary: the entry's own reason is named (${installer_out})"
grep -q "Nothing was registered" <<< "${installer_out}" || fail "installer, package with no binary: it says nothing was registered"
[[ ! -e "${tmp_root}/inst-home-3/.claude/settings.json" ]] || fail "installer, package with no binary: no engine config is written"
mkdir -p "${inst}/bin/native/${native_os}-${native_arch}"
printf '#!/bin/sh\nexit 0\n' > "${inst}/bin/native/${native_os}-${native_arch}/safedeps-core"
chmod 644 "${inst}/bin/native/${native_os}-${native_arch}/safedeps-core"
run_installer "${inst}" "${tmp_root}/inst-home-3"
[[ ${installer_rc} -ne 0 ]] || fail "installer, package with a binary that is not executable: the installer does not exit 0"
chmod 755 "${inst}/bin/native/${native_os}-${native_arch}/safedeps-core"
run_installer "${inst}" "${tmp_root}/inst-home-3"
[[ ${installer_rc} -eq 0 ]] || fail "installer, package with its binary: exits 0 (${installer_out})"
[[ ! -e "${inst}/build-ran" ]] || fail "installer, package: nothing is built"
pass "installer: a package must carry a runnable binary for this platform, and builds nothing"

for engine in claude codex; do
  case "${engine}" in claude) config="${tmp_root}/inst-home-3/.claude/settings.json"; events='["PostToolUse","PostToolUseFailure","PreToolUse"]' ;;
    codex) config="${tmp_root}/inst-home-3/.codex/hooks.json"; events='["PostToolUse","PreToolUse"]' ;; esac
  jq -e --argjson events "${events}" '
    (.hooks | keys | sort) == $events and
    ([.hooks[] | .[] | .matcher] | all(. == "Bash")) and
    ([.hooks[] | .[] | .hooks | length] | all(. == 1)) and
    ([.hooks[] | .[] | .hooks[] | .timeout] | all(. == 30)) and
    ([.hooks.PreToolUse[]?.hooks[]?.command] | all(endswith("safedeps-hook-entry.sh pre"))) and
    ([.hooks.PostToolUse[]?.hooks[]?.command, .hooks.PostToolUseFailure[]?.hooks[]?.command] | all(endswith("safedeps-hook-entry.sh post")))
  ' "${config}" >/dev/null || fail "installer: ${engine} registers only its events, canonical targets and timeout 30"
  cp "${config}" "${tmp_root}/${engine}-before.json"
done
run_installer "${inst}" "${tmp_root}/inst-home-3"
[[ ${installer_rc} -eq 0 ]] || fail "installer: second install succeeds (${installer_out})"
cmp -s "${tmp_root}/claude-before.json" "${tmp_root}/inst-home-3/.claude/settings.json" \
  && cmp -s "${tmp_root}/codex-before.json" "${tmp_root}/inst-home-3/.codex/hooks.json" \
  || fail "installer: second install changes neither engine's config"
pass "installer: engine events and timeout 30 are preserved, and registration is idempotent"

# The platform is the entry's reading, not the installer's: a package whose
# one binary is another platform's is refused with the entry's sentence.
case "${native_os}-${native_arch}" in darwin-arm64) other=linux-x64 ;; *) other=darwin-arm64 ;; esac
inst="${tmp_root}/inst-other-platform"
installer_repo "${inst}" ""
mkdir -p "${inst}/bin/native/${other}"
printf '#!/bin/sh\nexit 0\n' > "${inst}/bin/native/${other}/safedeps-core"
chmod 755 "${inst}/bin/native/${other}/safedeps-core"
run_installer "${inst}" "${tmp_root}/inst-home-5"
[[ ${installer_rc} -ne 0 ]] || fail "installer, package with another platform's binary: the installer does not exit 0"
grep -q "no safedeps-core binary for this platform" <<< "${installer_out}" || fail "installer, another platform's binary: the entry's platform sentence is named (${installer_out})"
[[ ! -e "${tmp_root}/inst-home-5/.claude/settings.json" ]] || fail "installer, another platform's binary: no engine config is written"
pass "installer: the binary's platform is the one the entry reads, and another platform's is refused"

# No fixture has either old Bash hook. Uninstall must also work after an
# incomplete installation has lost the entry and the core.
inst="${tmp_root}/inst-package"
rm -f "${inst}/scripts/safedeps-hook-entry.sh" "${inst}/bin/native/${native_os}-${native_arch}/safedeps-core"
installer_rc=0
HOME="${tmp_root}/inst-home-3" node "${inst}/scripts/install/install-safedeps-hooks.mjs" --uninstall \
  > "${tmp_root}/inst.out" 2>&1 || installer_rc=$?
[[ ${installer_rc} -eq 0 ]] || fail "uninstall needs neither the entry nor the binary ($(cat "${tmp_root}/inst.out"))"
for config in "${tmp_root}/inst-home-3/.claude/settings.json" "${tmp_root}/inst-home-3/.codex/hooks.json"; do
  jq -e '[.hooks[]?[]?.hooks[]? | select(.command | contains("/safedeps/"))] | length == 0' "${config}" >/dev/null \
    || fail "uninstall removes all registered safedeps hooks (${config})"
done
pass "installer: uninstall removes registrations even with no entry or core"

printf 'entry battery: all checks passed\n'
