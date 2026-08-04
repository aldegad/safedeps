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
mkdir -p "${repo}/scripts" "${repo}/.git" "${tmp_root}/home" "${tmp_root}/state"
cp scripts/safedeps-hook-entry.sh "${repo}/scripts/"
cp scripts/safedeps-pre-guard.sh "${repo}/scripts/"
cp scripts/safedeps-post-verify.sh "${repo}/scripts/"

project_dir="${tmp_root}/project"
mkdir -p "${project_dir}"
printf '{"dependencies":{}}\n' > "${project_dir}/package.json"

payload() {
  jq -nc --arg c "$1" --arg cwd "${project_dir}" \
    '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}'
}

run_entry() {
  local command="$1" target="${2:-pre}"
  entry_rc=0
  entry_out=$(payload "${command}" |
    HOME="${tmp_root}/home" SAFEDEPS_HOME="${tmp_root}/state" \
    bash "${repo}/scripts/safedeps-hook-entry.sh" "${target}" 2>"${tmp_root}/err") || entry_rc=$?
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

# --- the shim's own failure mode: degrade to status quo, never wider --------

awk 'NR==30{print "<<<<<<< HEAD"} {print} NR==33{print "======="; print ">>>>>>> other-branch"}' \
  scripts/safedeps-hook-entry.sh > "${repo}/scripts/safedeps-hook-entry.sh"
run_entry "ls -la"
[[ ${entry_rc} -eq 2 ]] \
  || fail "broken shim itself still blocks fail-closed like the pre-shim status quo (rc=${entry_rc})"
grep -q "syntax error" <<< "${entry_err}" || fail "broken shim: bash parse error surfaces"
pass "broken shim degrades to status-quo blocking (fail-closed direction preserved, no wider)"

printf 'entry battery: all checks passed\n'
