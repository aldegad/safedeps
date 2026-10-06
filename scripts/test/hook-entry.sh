#!/usr/bin/env bash
# safedeps: hook entry shim battery.
#
# The entry shim's contract: a healthy hook passes through untouched; a broken
# hook source (parse error, missing file, crash) becomes an EXPLAINED
# fail-closed deny (exit 2 + cause + recovery on stderr) instead of an
# accidental exit code. This battery pins every branch of that contract, plus
# the shim's own failure mode: a broken shim must degrade to the pre-shim
# status quo (blocking with a raw parse error), never to something wider.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "${ROOT_DIR}"

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-entry.XXXXXX")
cleanup() { rm -rf "${tmp_root}"; }
trap cleanup EXIT

# A fake repo layout the shim resolves itself into: <repo>/scripts/<hooks>.
repo="${tmp_root}/repo"
mkdir -p "${repo}/scripts" "${repo}/lib" "${repo}/.git" "${tmp_root}/home" "${tmp_root}/state"
cp scripts/safedeps-hook-entry.sh "${repo}/scripts/"
cp scripts/safedeps-pre-guard.sh "${repo}/scripts/"
cp scripts/safedeps-post-verify.sh "${repo}/scripts/"
# The install grammar is part of a healthy install: without it the guard cannot
# tell an install from `ls`, and says so (pinned below).
cp lib/install-grammar.sh "${repo}/lib/"

project_dir="${tmp_root}/project"
mkdir -p "${project_dir}"
printf '{"dependencies":{}}\n' > "${project_dir}/package.json"

payload() {
  jq -nc --arg c "$1" --arg cwd "${project_dir}" \
    '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}'
}

run_entry() {
  local command="$1" target="${2:-pre}" input
  entry_rc=0
  # The payload is built first and handed over whole, not piped from jq. Some
  # rows answer without reading stdin (a missing install grammar denies before
  # the payload is read), and under pipefail a jq still writing then dies of
  # SIGPIPE and its 141 becomes the row's exit status. A slow jq reproduces it
  # every time; a loaded machine reproduced it in npm test.
  input=$(payload "${command}")
  entry_out=$(HOME="${tmp_root}/home" SAFEDEPS_HOME="${tmp_root}/state" \
    bash "${repo}/scripts/safedeps-hook-entry.sh" "${target}" <<< "${input}" 2>"${tmp_root}/err") || entry_rc=$?
  entry_err=$(cat "${tmp_root}/err")
}

# --- healthy source: the shim is invisible ---------------------------------

run_entry "ls -la"
[[ ${entry_rc} -eq 0 && -z "${entry_out}" ]] \
  || fail "healthy guard + benign command passes through (rc=${entry_rc})"
pass "healthy guard: benign command passes through untouched"

run_entry "npm install left-pad"
decision=$(jq -r '.hookSpecificOutput.permissionDecision // "none"' <<< "${entry_out}")
rewritten=$(jq -r '.hookSpecificOutput.updatedInput.command // ""' <<< "${entry_out}")
[[ ${entry_rc} -eq 0 && "${decision}" == "allow" && "${rewritten}" == *"--ignore-scripts"* ]] \
  || fail "healthy guard: npm inert-install rewrite passes through the shim (rc=${entry_rc}, decision=${decision})"
pass "healthy guard: npm inert-install rewrite passes through unchanged"

# --- the install grammar is missing: an explained fail-closed deny ------------
# Every recognizer reads lib/install-grammar.sh. Without it the guard cannot
# tell an install from any other command, so it blocks everything and names the
# file -- the outcome the shim gives a hook that will not load, said by the hook.
mv "${repo}/lib/install-grammar.sh" "${repo}/lib/install-grammar.sh.away"
run_entry "ls -la"
decision=$(jq -r '.hookSpecificOutput.permissionDecision // "none"' <<< "${entry_out}")
reason=$(jq -r '.hookSpecificOutput.permissionDecisionReason // ""' <<< "${entry_out}")
[[ ${entry_rc} -eq 0 && "${decision}" == "deny" ]] \
  || fail "a missing install grammar blocks fail-closed (rc=${entry_rc}, decision=${decision})"
grep -q 'install-grammar.sh' <<< "${reason}" || fail "a missing install grammar is named in the deny"
grep -q 'install-grammar.sh' "${tmp_root}/state/advisory.log" || fail "a missing install grammar is recorded in advisory.log"
mv "${repo}/lib/install-grammar.sh.away" "${repo}/lib/install-grammar.sh"
pass "a missing install grammar is an explained fail-closed deny, recorded"

run_entry "pip install requests==2.31.0"
decision=$(jq -r '.hookSpecificOutput.permissionDecision // "none"' <<< "${entry_out}")
[[ ${entry_rc} -eq 0 && "${decision}" == "deny" ]] \
  || fail "healthy guard: unapproved pip install still denies through the shim (rc=${entry_rc}, decision=${decision})"
pass "healthy guard: command-gate deny decision passes through unchanged"

# --- broken source: explained fail-closed deny ------------------------------

awk 'NR==147{print "<<<<<<< HEAD"} {print} NR==150{print "======="; print ">>>>>>> other-branch"}' \
  scripts/safedeps-pre-guard.sh > "${repo}/scripts/safedeps-pre-guard.sh"
run_entry "ls -la"
[[ ${entry_rc} -eq 2 ]] || fail "conflicted guard blocks (rc=${entry_rc})"
grep -q "does not parse" <<< "${entry_err}" || fail "conflicted guard: cause is named"
grep -q "EVERY session" <<< "${entry_err}" || fail "conflicted guard: machine-wide breadth is named"
grep -q "Recovery:" <<< "${entry_err}" || fail "conflicted guard: recovery path is named"
pass "conflicted guard: explained fail-closed deny (cause + breadth + recovery)"

touch "${repo}/.git/MERGE_HEAD"
run_entry "ls -la"
grep -q "merge is in progress" <<< "${entry_err}" \
  || fail "mid-merge checkout is detected and named"
rm -f "${repo}/.git/MERGE_HEAD"
pass "conflicted guard: in-progress merge is detected and named"

rm "${repo}/scripts/safedeps-pre-guard.sh"
run_entry "ls -la"
[[ ${entry_rc} -eq 2 ]] || fail "missing guard blocks instead of silent fail-open (rc=${entry_rc})"
grep -q "missing" <<< "${entry_err}" || fail "missing guard: cause is named"
pass "missing guard: silent fail-open (127) becomes explained fail-closed deny"

printf '#!/usr/bin/env bash\nexit 1\n' > "${repo}/scripts/safedeps-pre-guard.sh"
run_entry "ls -la"
[[ ${entry_rc} -eq 2 ]] || fail "crashing guard blocks instead of silent fail-open (rc=${entry_rc})"
grep -q "crashed with exit 1" <<< "${entry_err}" || fail "crashing guard: cause is named"
pass "crashing guard: silent fail-open (rc=1) becomes explained fail-closed deny"

cp scripts/safedeps-pre-guard.sh "${repo}/scripts/"

# --- post target: same contract, post wording -------------------------------

printf '#!/usr/bin/env bash\nexit 1\n' > "${repo}/scripts/safedeps-post-verify.sh"
run_entry "ls -la" post
[[ ${entry_rc} -eq 2 ]] || fail "broken post hook reports loudly (rc=${entry_rc})"
grep -q "unverified" <<< "${entry_err}" || fail "broken post hook: consequence is named"
pass "broken post hook: silent fail-open becomes a loud, explained report"
cp scripts/safedeps-post-verify.sh "${repo}/scripts/"

# --- out of processes: an explained deny, not a non-blocking exit ----------
# bash ends a script at the first process it cannot start -- 3.2 at once with
# exit 128, 5 after about 15 seconds of retries with exit 254 -- and both
# engines read either as a non-blocking hook failure: the call would run with
# no gate. A process limit of 1 reproduces it for real, because this user
# already runs more than one process, so every fork inside the shim fails. Root
# is exempt from that limit, so the row says so when the limit does not bind.
probe_rc=0
bash -c 'ulimit -Su 1 2>/dev/null || exit 3; ( exit 0 )' 2>/dev/null || probe_rc=$?
if [[ ${probe_rc} -eq 0 || ${probe_rc} -eq 3 ]]; then
  printf 'ok - out-of-processes row SKIPPED (the process limit does not bind this user)\n'
else
  entry_rc=0
  entry_out=$(payload "ls -la" |
    HOME="${tmp_root}/home" SAFEDEPS_HOME="${tmp_root}/state" \
    bash -c 'ulimit -Su 1; exec bash "$0" pre' "${repo}/scripts/safedeps-hook-entry.sh" 2>"${tmp_root}/err") || entry_rc=$?
  entry_err=$(cat "${tmp_root}/err")
  [[ ${entry_rc} -eq 2 ]] || fail "out of processes: the entry denies instead of exiting ${entry_rc}, which is non-blocking"
  grep -q "could not start a process" <<< "${entry_err}" || fail "out of processes: the cause is named"
  if grep -q "missing" <<< "${entry_err}"; then
    fail "out of processes: not misreported as a missing hook"
  fi
  pass "out of processes: an explained deny, not a non-blocking 128 or a missing hook"
fi

# --- the shim's own failure mode: degrade to status quo, never wider --------

awk 'NR==30{print "<<<<<<< HEAD"} {print} NR==33{print "======="; print ">>>>>>> other-branch"}' \
  scripts/safedeps-hook-entry.sh > "${repo}/scripts/safedeps-hook-entry.sh"
run_entry "ls -la"
[[ ${entry_rc} -eq 2 ]] \
  || fail "broken shim itself still blocks fail-closed like the pre-shim status quo (rc=${entry_rc})"
grep -q "syntax error" <<< "${entry_err}" || fail "broken shim: bash parse error surfaces"
pass "broken shim degrades to status-quo blocking (fail-closed direction preserved, no wider)"

# --- the shim that runs the Rust core (scripts/safedeps-hook-entry-native.sh) ---
#
# Not registered yet: it takes the entry's name in the change that moves the
# hooks to the core. Its contract is held here first, with stand-in binaries,
# because the shim never looks inside the binary: it finds one for this
# platform, runs it with `pre` or `post`, passes an exit 0 through, and turns
# every way of not answering into an explained exit 2. None of those ways runs
# the bash hooks, and nothing in the environment chooses.

native_repo="${tmp_root}/native-repo"
mkdir -p "${native_repo}/scripts" "${native_repo}/rust"
cp scripts/safedeps-hook-entry-native.sh "${native_repo}/scripts/"
# A bash hook that would leave a mark if anything ran it. Every row below
# checks that the mark is not there.
bash_ran="${tmp_root}/bash-hook-ran"
for hook in safedeps-pre-guard.sh safedeps-post-verify.sh; do
  printf '#!/usr/bin/env bash\n: > %q\nexit 0\n' "${bash_ran}" > "${native_repo}/scripts/${hook}"
  chmod +x "${native_repo}/scripts/${hook}"
done
cp "${native_repo}/scripts/safedeps-pre-guard.sh" "${native_repo}/scripts/safedeps-hook-entry.sh"

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
    bash "${native_repo}/scripts/safedeps-hook-entry-native.sh" "${target}" <<< "${input}" 2>"${tmp_root}/err") || entry_rc=$?
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
  bash "${native_repo}/scripts/safedeps-hook-entry-native.sh" pre <<< "$(payload "ls -la")" 2>"${tmp_root}/err") || entry_rc=$?
[[ ${entry_rc} -eq 0 && "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<< "${entry_out}")" == "stand-in" ]] \
  || fail "native entry: OSTYPE, HOSTTYPE and MACHTYPE from the environment do not choose the binary (rc=${entry_rc}: $(cat "${tmp_root}/err"))"
pass "native entry: the platform comes from bash itself, not from OSTYPE or HOSTTYPE in the environment"

# The shim reads nothing else from the environment either. Every variable it
# names in capitals is listed here; a new one is a switch someone has to
# explain. (BASH_VERSINFO is bash's own and read-only.)
native_names=$(grep -v '^[[:space:]]*#' scripts/safedeps-hook-entry-native.sh | grep -oE '\$\{?[A-Z][A-Z0-9_]*' | sed 's/^\${*//' | sort -u | tr '\n' ' ')
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
bash "${native_repo}/scripts/safedeps-hook-entry-native.sh" 2>"${tmp_root}/err" < /dev/null || entry_rc=$?
[[ ${entry_rc} -eq 2 ]] && grep -q "usage" "${tmp_root}/err" || fail "native entry: no target is a usage error with exit 2 (rc=${entry_rc})"
pass "native entry: a call with no target is refused"

if [[ ${probe_rc} -eq 0 || ${probe_rc} -eq 3 ]]; then
  printf 'ok - native out-of-processes row SKIPPED (the process limit does not bind this user)\n'
else
  native_stub 'exit 0'
  entry_rc=0
  entry_out=$(payload "ls -la" |
    HOME="${tmp_root}/home" SAFEDEPS_HOME="${tmp_root}/state" \
    bash -c 'ulimit -Su 1; exec bash "$0" pre' "${native_repo}/scripts/safedeps-hook-entry-native.sh" 2>"${tmp_root}/err") || entry_rc=$?
  entry_err=$(cat "${tmp_root}/err")
  [[ ${entry_rc} -eq 2 ]] || fail "native entry, out of processes: the entry denies instead of exiting ${entry_rc}, which is non-blocking"
  grep -q "could not start a process" <<< "${entry_err}" || fail "native entry, out of processes: the cause is named (${entry_err})"
  pass "native entry: out of processes is an explained deny, not a non-blocking 128"
fi

printf 'entry battery: all checks passed\n'
