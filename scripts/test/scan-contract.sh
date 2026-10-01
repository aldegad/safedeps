#!/usr/bin/env bash
# safedeps: command_scan_text contract battery.
#
# command_scan_text is the guard's quoting model. Every detection predicate on
# the PreToolUse path reads its output rather than the raw command, so what this
# function blanks decides what the gate can see. The predicates are:
#
#   command_is_dependency_install    is this an install command
#   command_is_injectable_npm_install  may --ignore-scripts be injected
#   command_has_ignore_scripts_flag  is the flag already there
#   command_is_compound              may the flag be appended
#   resolve_install_targets          where does each install land
#   guard_detect_ecosystem           which ecosystem
#   payload_pipes_install_text_to_shell  is the pipe in execution position
#   guard_extract_specs (line loop)  which pkg@spec tokens are named
#
# Each consumes the output through `grep -qE` or `read -ra`, so runs of blanks
# are interchangeable with single blanks for every one of them. What is NOT
# interchangeable is WHICH characters survive: a character the scan blanks is a
# character no predicate above can match.
#
# The contract, as measured (not as intended):
#
#   1. Length is preserved in bytes. One input byte produces exactly one output
#      byte. This used to read "in characters", and the change is the whole
#      observable difference the awk rewrite made: a multibyte character inside
#      a quoted region blanked to one space and now blanks to one space per
#      byte. An earlier version of this note said byte orientation is what made
#      the scan linear. It is not: `substr($0, i, 1)` over bytes was still
#      quadratic in BSD awk, because each call re-measures the string (1MB on
#      one line took 28.5s, caught in review). Splitting the record once is what
#      made it linear; bytes are only what LC_ALL=C hands the split.
#   2. Outside quotes, bytes pass through unchanged, except a backslash. A
#      backslash is blanked and escapes the byte after it: that byte passes
#      through as data and never opens a region (`\"` is a quote character,
#      `\pip` is `pip`), and an escaped newline -- a line continuation, which
#      the shell removes -- is blanked, so the two lines read as one.
#   3. A quote character that opens or closes a region is itself blanked.
#   4. Every byte inside a quoted region is blanked, newlines included.
#   5. A single-quoted region ends at the next single quote, unconditionally.
#      There are no escapes inside single quotes.
#   6. Inside a double-quoted region a backslash escapes the byte after it, so
#      backslashes are consumed in pairs: `"a\\"` closes (an escaped backslash,
#      then the quote) and `"a\\\"` does not (an escaped backslash, then an
#      escaped quote).
#   7. An unterminated region blanks the rest of the input.
#
# Rules 2 and 6 used to read a backslash by looking only at the byte before a
# quote, and outside quotes not at all. Each reading blanked text the shell
# executes, and blanked text is invisible to every predicate: measured against
# the gate that was live on the development machine, all of these passed with
# an unapproved pip install after them:
#
#   echo "a\\" ; pip install ...      one escaped backslash, then the close
#   echo \" ; pip install ...         an escaped quote read as an opening one
#   \pip install ...                  the alias-bypass idiom
#   pip \<newline>install ...         a line continuation split in two
#
# The linearization plan pinned the first as a defect so that a refactor could
# prove no verdict moved. This fix moves verdicts on purpose;
# safedeps/escaped-backslash-blanks-the-rest records the replay and the
# direction of every move.
#
# HOW THIS FILE CHECKS. It carries a reference implementation of the rules
# above and asserts the shipped one agrees with it, on a case table and on
# randomized input. The reference is a spec, not a second code path -- the guard
# has one implementation and nothing sources this file. A rule stated in prose
# drifts silently; a rule stated as a runnable oracle cannot.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "${ROOT_DIR}"

GUARD="scripts/safedeps-pre-guard.sh"

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

# --- load the shipped implementation ------------------------------------------
# Extracted by name from the guard rather than sourced: the guard is an
# executable hook with no source guard, and sourcing it would run the whole
# judgment. An empty extraction is a hard failure, never a skipped battery --
# a rename must break this file loudly rather than quietly stop checking.
shipped_src=$(sed -n '/^command_scan_text() {/,/^}/p' "${GUARD}")
[[ -n "${shipped_src}" ]] || fail "command_scan_text not found in ${GUARD} (renamed? then update this battery)"
eval "${shipped_src}"
declare -F command_scan_text > /dev/null || fail "extracted command_scan_text did not define the function"

# --- the spec -----------------------------------------------------------------
# Deliberately the slowest, most obvious statement of the seven rules. It is
# read by this battery only, so its cost is irrelevant and its clarity is not.
reference_scan_text() {
  local LC_ALL=C
  local input="$1" output="" quote="" escaped="" char i
  for ((i = 0; i < ${#input}; i++)); do
    char="${input:i:1}"
    if [[ -n "${escaped}" ]]; then
      escaped=""
      if [[ -z "${quote}" && "${char}" != $'\n' ]]; then
        output="${output}${char}"
      else
        output="${output} "
      fi
    elif [[ -z "${quote}" ]]; then
      case "${char}" in
        "\\") escaped=1; output="${output} " ;;
        "'") quote="single"; output="${output} " ;;
        '"') quote="double"; output="${output} " ;;
        *)   output="${output}${char}" ;;
      esac
    elif [[ "${quote}" == "single" ]]; then
      [[ "${char}" == "'" ]] && quote=""
      output="${output} "
    else
      if [[ "${char}" == "\\" ]]; then
        escaped=1
      elif [[ "${char}" == '"' ]]; then
        quote=""
      fi
      output="${output} "
    fi
  done
  printf '%s' "${output}"
}

# Command substitution eats trailing newlines, and rule 4 turns a quoted newline
# into a blank while rule 2 keeps an unquoted one -- so the trailing edge is the
# one place the two rules visibly disagree. Guard it with a sentinel.
capture() {
  local out
  out=$("$1" "$2"; printf 'X')
  printf '%s' "${out%X}"
}

sp() { printf '%*s' "$1" ''; }
byte_len() { local LC_ALL=C; printf '%s' "${#1}"; }

checks=0

# Assert the shipped output equals a literal expectation AND the spec's output.
# The literal is what a reader checks by eye; the spec is what catches a case
# the table forgot.
check() {
  local label="$1" input="$2" expected="$3" got ref
  got=$(capture command_scan_text "${input}")
  ref=$(capture reference_scan_text "${input}")
  [[ "${got}" == "${expected}" ]] || fail "${label}: shipped [${got}] != expected [${expected}]"
  [[ "${ref}" == "${expected}" ]] || fail "${label}: reference [${ref}] != expected [${expected}] (the table and the spec disagree)"
  local in_bytes out_bytes
  in_bytes=$(byte_len "${input}")
  out_bytes=$(byte_len "${got}")
  [[ ${out_bytes} -eq ${in_bytes} ]] || fail "${label}: length not preserved (${in_bytes} bytes in, ${out_bytes} out)"
  checks=$((checks + 1))
  pass "${label}"
}

# rule 2: nothing quoted, nothing blanked
check "unquoted text passes through" \
  'npm install left-pad' \
  'npm install left-pad'

# rules 3+4: the region and its delimiters go
check "single-quoted region is blanked with its delimiters" \
  "echo 'npm install evil'" \
  "echo$(sp 19)"

check "double-quoted region is blanked with its delimiters" \
  'echo "npm install evil"' \
  "echo$(sp 19)"

# rule 5/6: the other quote character is inert inside a region
check "single quote inside a double-quoted region does not close it" \
  "echo \"it's fine\"" \
  "echo$(sp 12)"

check "double quote inside a single-quoted region does not close it" \
  "echo 'say \"hi\"'" \
  "echo$(sp 11)"

# rule 6: an escaped quote does not close, and text after the region survives
check "escaped double quote does not close the region" \
  'echo "a\"b" c' \
  "echo$(sp 8)c"

# rule 6: backslashes pair up, so an escaped backslash does not escape the quote
check "escaped backslash before the closing quote closes the region" \
  'echo "a\\" ; npm i x' \
  "echo$(sp 6) ; npm i x"

check "two escaped backslashes before the closing quote close the region" \
  'echo "a\\\\" ; npm i x' \
  "echo$(sp 8) ; npm i x"

check "an escaped backslash then an escaped quote keeps the region open" \
  'echo "a\\\" ; npm i x' \
  "echo$(sp 17)"

# rule 2: outside a region a backslash escapes the byte after it
check "an escaped quote outside a region is data, not an opening quote" \
  'echo \"npm install evil\"' \
  'echo  "npm install evil "'

check "an escaped single quote outside a region is data too" \
  "echo \' ; npm i x" \
  "echo  ' ; npm i x"

check "a backslash before a command name is blanked" \
  '\pip install evil' \
  ' pip install evil'

check "an escaped space outside a region passes through" \
  'echo a\ b' \
  'echo a  b'

check "a line continuation joins the two lines" \
  $'pip \\\ninstall evil' \
  'pip   install evil'

# rule 7
check "unterminated single quote blanks the rest" \
  "echo 'npm install evil" \
  "echo$(sp 18)"

check "unterminated double quote blanks the rest" \
  'echo "npm install evil' \
  "echo$(sp 18)"

# rules 2+4 at the newline: unquoted newlines are structure, quoted ones are not
check "newline outside a region survives" \
  $'npm i a\nnpm i b' \
  $'npm i a\nnpm i b'

check "newline inside a region is blanked" \
  $'echo \'a\nb\'' \
  "echo$(sp 6)"

# rule 1 is in bytes: a 3-byte character inside a region blanks to THREE blanks,
# and the byte AFTER the region still lands where it did.
check "a multibyte character inside a region blanks per byte" \
  "echo '한글' x" \
  "echo$(sp 10)x"

check "empty input" '' ''

pass "case table: ${checks} cases"

# --- randomized differential --------------------------------------------------
# The table states the rules; this states that nothing outside the table diverges.
# The alphabet is weighted toward the characters the rules are about, because
# uniform ASCII almost never produces a nested or escaped quote.
fuzz_seed="${SAFEDEPS_SCAN_FUZZ_SEED:-20260805}"
fuzz_cases="${SAFEDEPS_SCAN_FUZZ_CASES:-400}"
RANDOM="${fuzz_seed}"
alphabet=(\' \" \\ ' ' a b n p m i s t l 1 . @ - / \; \& \| $'\n' '=' '(' ')' '$' '한')

fuzz_divergences=0
for ((c = 0; c < fuzz_cases; c++)); do
  len=$((RANDOM % 40))
  input=""
  for ((k = 0; k < len; k++)); do
    input+="${alphabet[RANDOM % ${#alphabet[@]}]}"
  done
  got=$(capture command_scan_text "${input}")
  ref=$(capture reference_scan_text "${input}")
  if [[ "${got}" != "${ref}" ]]; then
    printf 'diverged on [%q]\n  shipped   [%q]\n  reference [%q]\n' "${input}" "${got}" "${ref}" >&2
    fuzz_divergences=$((fuzz_divergences + 1))
  fi
done
[[ ${fuzz_divergences} -eq 0 ]] || fail "randomized differential: ${fuzz_divergences}/${fuzz_cases} diverged (seed ${fuzz_seed})"
pass "randomized differential: ${fuzz_cases} inputs, seed ${fuzz_seed}, no divergence"

# A fuzz run that cannot fail proves nothing, so prove it can. The control
# mutates the spec (single quotes stop closing) and asserts the differential
# sees it. Without this, a broken harness and a clean run look identical.
control_hit=0
reference_scan_text() {
  local LC_ALL=C
  local input="$1" output="" quote="" escaped="" char i
  for ((i = 0; i < ${#input}; i++)); do
    char="${input:i:1}"
    if [[ -n "${escaped}" ]]; then
      escaped=""
      if [[ -z "${quote}" && "${char}" != $'\n' ]]; then
        output="${output}${char}"
      else
        output="${output} "
      fi
    elif [[ -z "${quote}" ]]; then
      case "${char}" in
        "\\") escaped=1; output="${output} " ;;
        "'") quote="single"; output="${output} " ;;
        '"') quote="double"; output="${output} " ;;
        *)   output="${output}${char}" ;;
      esac
    elif [[ "${quote}" == "single" ]]; then
      output="${output} "
    else
      if [[ "${char}" == "\\" ]]; then
        escaped=1
      elif [[ "${char}" == '"' ]]; then
        quote=""
      fi
      output="${output} "
    fi
  done
  printf '%s' "${output}"
}
RANDOM="${fuzz_seed}"
for ((c = 0; c < fuzz_cases; c++)); do
  len=$((RANDOM % 40))
  input=""
  for ((k = 0; k < len; k++)); do
    input+="${alphabet[RANDOM % ${#alphabet[@]}]}"
  done
  [[ "$(capture command_scan_text "${input}")" == "$(capture reference_scan_text "${input}")" ]] || control_hit=$((control_hit + 1))
done
[[ ${control_hit} -gt 0 ]] || fail "control: a mutated spec produced no divergence, so the differential above measures nothing"
pass "control: mutated spec diverges on ${control_hit}/${fuzz_cases} inputs, so the differential can fail"

# --- when the scanner itself fails ----------------------------------------------
# Every predicate reads this function's output inside a condition or a command
# substitution, where `set -e` is off. A scan that fails therefore returns empty
# text, and empty text reads as "no install": a scanner failure became a silent
# pass (caught in review, measured through the entry shim). These cases fail
# awk on purpose and require the guard to say UNDECIDED instead of nothing.
#
# The shim keys on the marker line inside the scanner's awk program, so it can
# fail the scanner alone and leave every other awk call on the path working.
real_awk=$(command -v awk)
fail_tmp=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-scanfail.XXXXXX")
trap 'rm -rf "${fail_tmp}"' EXIT
mkdir -p "${fail_tmp}/scanner-only" "${fail_tmp}/all-awk" "${fail_tmp}/scanner-later" "${fail_tmp}/project"
printf '{"dependencies":{}}\n' > "${fail_tmp}/project/package.json"
cat > "${fail_tmp}/scanner-only/awk" <<SHIM
#!/usr/bin/env bash
case "\$*" in *"safedeps:command_scan_text"*) exit 2 ;; esac
exec '${real_awk}' "\$@"
SHIM
printf '#!/usr/bin/env bash\nexit 127\n' > "${fail_tmp}/all-awk/awk"
# The scanner works for its first call and fails after that. The first call is
# the one that recognizes the install, so this is the path that reaches the
# LAST settle point, just before pending state is written; the other shims
# fail the recognition itself and never get that far (caught in review: the
# last settle could be deleted and every case above still passed).
cat > "${fail_tmp}/scanner-later/awk" <<SHIM
#!/usr/bin/env bash
case "\$*" in
  *"safedeps:command_scan_text"*)
    count=\$(( \$(cat '${fail_tmp}/scanner-later/count' 2>/dev/null || echo 0) + 1 ))
    printf '%s' "\${count}" > '${fail_tmp}/scanner-later/count'
    (( count <= 1 )) || exit 2
    ;;
esac
exec '${real_awk}' "\$@"
SHIM
chmod +x "${fail_tmp}/scanner-only/awk" "${fail_tmp}/all-awk/awk" "${fail_tmp}/scanner-later/awk"

# Runs the guard through the entry shim, the way the engines do.
scanfail_guard() {
  local bin="$1" command="$2" home
  home=$(mktemp -d "${fail_tmp}/home.XXXXXX")
  SCANFAIL_OUT=$(jq -nc --arg c "${command}" --arg cwd "${fail_tmp}/project" \
    '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}' |
    PATH="${bin:+${bin}:}${PATH}" HOME="${home}" SAFEDEPS_HOME="${home}/safe" \
    scripts/safedeps-hook-entry.sh pre 2>"${home}/stderr") || fail "the hook exited non-zero for: ${command}"
  SCANFAIL_ERR=$(cat "${home}/stderr")
  SCANFAIL_LOG=$(cat "${home}/safe/advisory.log" 2>/dev/null || printf '')
  SCANFAIL_DECISION=$(jq -r '.hookSpecificOutput.permissionDecision // "pass"' <<< "${SCANFAIL_OUT:-{\}}" 2>/dev/null || printf 'pass')
  SCANFAIL_REASON=$(jq -r '.hookSpecificOutput.permissionDecisionReason // ""' <<< "${SCANFAIL_OUT:-{\}}" 2>/dev/null || printf '')
}

# Control: with a working scanner the same command is denied as a finding. This
# is what the failing cases would silently lose.
scanfail_guard "" "pip install requests==2.0.0"
[[ "${SCANFAIL_DECISION}" == "deny" ]] || fail "control: a working scanner denies an unapproved pip install (got: ${SCANFAIL_DECISION})"
if grep -q 'UNDECIDED' <<< "${SCANFAIL_REASON}"; then fail "control: a working scanner answers with a finding, not UNDECIDED"; fi
pass "control: with a working scanner the install is denied as a finding"

# npm's short verbs are here because the loose raw pattern alone missed them
# (caught in review): `npm i x` then passed both hooks, since the PostToolUse
# backstop reads the same kind of pattern.
for failing_command in \
  "pip install requests==2.0.0" \
  "echo hi; pip install requests==2.0.0" \
  "bash -c \"pip install requests==2.0.0\"" \
  "npm install left-pad@1.3.0" \
  "npm i left-pad@1.3.0" \
  "bun i left-pad@1.3.0" \
  "npm ci" \
  "npm update left-pad"; do
  scanfail_guard "${fail_tmp}/scanner-only" "${failing_command}"
  [[ "${SCANFAIL_DECISION}" == "deny" ]] \
    || fail "a failed scanner does not turn an install into a pass: ${failing_command} (got: ${SCANFAIL_DECISION})"
  grep -q 'UNDECIDED' <<< "${SCANFAIL_REASON}" \
    || fail "a failed scanner is reported as undecided, not as a finding: ${failing_command}"
  grep -q 'scanner failed' <<< "${SCANFAIL_LOG}" \
    || fail "a failed scanner is recorded in advisory.log: ${failing_command}"
done
pass "a scanner-only awk failure denies install-looking commands as UNDECIDED, including npm (no inert rewrite on an unread command)"

scanfail_guard "${fail_tmp}/scanner-only" "ls -la"
[[ "${SCANFAIL_DECISION}" == "pass" ]] || fail "a failed scanner does not block a command that does not look like an install (got: ${SCANFAIL_DECISION})"
grep -q 'scanner' <<< "${SCANFAIL_ERR}" || fail "a failed scanner is announced even when the command is allowed"
grep -q 'scanner failed' <<< "${SCANFAIL_LOG}" || fail "a failed scanner is recorded even when the command is allowed"
pass "a failed scanner lets a non-install through, and says so on stderr and in advisory.log"

rm -f "${fail_tmp}/scanner-later/count"
scanfail_guard "${fail_tmp}/scanner-later" "pip install requests==2.0.0"
[[ "$(cat "${fail_tmp}/scanner-later/count" 2>/dev/null || echo 0)" -gt 1 ]] \
  || fail "the later-failure shim reached a second scan (otherwise this case tests nothing)"
[[ "${SCANFAIL_DECISION}" == "deny" ]] || fail "a scanner that fails after recognizing the install still denies (got: ${SCANFAIL_DECISION})"
grep -q 'UNDECIDED' <<< "${SCANFAIL_REASON}" || fail "a scanner that fails after recognizing the install answers UNDECIDED"
grep -q 'scanner failed' <<< "${SCANFAIL_LOG}" || fail "a scanner that fails after recognizing the install is recorded"
pass "a scanner that fails after the install was recognized is settled before pending state is written"

scanfail_guard "${fail_tmp}/all-awk" "pip install requests==2.0.0"
[[ "${SCANFAIL_DECISION}" == "deny" ]] || fail "with awk failing everywhere an install is still denied (got: ${SCANFAIL_DECISION})"
pass "with awk failing everywhere an install is still denied"

# --- when a spec reader's sed or tr fails ---------------------------------------
# The spec readers rewrite a statement before reading it: quotes and grouping
# characters are removed, extras are removed, an npm alias is replaced by its
# target, a runner's operands are cut out. Each runs in a command substitution,
# so a failed sed or tr left no text, no text read as no spec, and a pinned
# install passed as if it named nothing to check. Each shim fails one reader
# alone, keyed on its script.
real_sed=$(command -v sed)
real_tr=$(command -v tr)
for reader in extras alias runner group; do
  mkdir -p "${fail_tmp}/reader-${reader}"
  tool=sed real="${real_sed}"
  case "${reader}" in
    extras) key='\[[^] ]*\]' ;;
    alias) key='@npm:/' ;;
    runner) key='(npx|pnpx|bunx|uvx)' ;;
    group) key='(){}' tool=tr real="${real_tr}" ;;
  esac
  cat > "${fail_tmp}/reader-${reader}/${tool}" <<SHIM
#!/usr/bin/env bash
case "\$*" in *'${key}'*) exit 2 ;; esac
exec '${real}' "\$@"
SHIM
  chmod +x "${fail_tmp}/reader-${reader}/${tool}"
done

# reader<TAB>command
sed_rows=(
  $'extras\tpip install \'evil[x]==1.0.0\''
  $'alias\tpnpm add left-pad@npm:evil-pkg@1.0.0'
  $'runner\tnpx evil@1.0.0'
  $'group\tpip install evil==1.0.0'
)
for row in "${sed_rows[@]}"; do
  reader="${row%%$'\t'*}" failing_command="${row#*$'\t'}"
  # Control: with sed working the same command is denied as a finding.
  scanfail_guard "" "${failing_command}"
  if [[ "${SCANFAIL_DECISION}" != "deny" ]] || grep -q 'UNDECIDED' <<< "${SCANFAIL_REASON}"; then
    fail "control: a working ${reader} reader denies ${failing_command} as a finding (got: ${SCANFAIL_DECISION})"
  fi
  scanfail_guard "${fail_tmp}/reader-${reader}" "${failing_command}"
  [[ "${SCANFAIL_DECISION}" == "deny" ]] \
    || fail "a failed ${reader} reader does not turn ${failing_command} into a pass (got: ${SCANFAIL_DECISION})"
  grep -q 'UNDECIDED' <<< "${SCANFAIL_REASON}" \
    || fail "a failed ${reader} reader is reported as undecided: ${failing_command}"
  grep -q 'scanner failed' <<< "${SCANFAIL_LOG}" \
    || fail "a failed ${reader} reader is recorded in advisory.log: ${failing_command}"
done
pass "a failed sed or tr in a spec reader denies the install as UNDECIDED (${#sed_rows[@]} readers, each against a working control)"

printf 'scan-contract: all checks passed\n'
