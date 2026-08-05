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
#   resolve_install_dir_override     where does the install land
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
#   1. Length is preserved in characters. One input character produces exactly
#      one output character.
#   2. Outside quotes, characters pass through unchanged -- including a
#      backslash, which does NOT escape the quote that follows it.
#   3. A quote character that opens or closes a region is itself blanked.
#   4. Every character inside a quoted region is blanked, newlines included.
#   5. A single-quoted region ends at the next single quote, unconditionally.
#   6. A double-quoted region ends at the next double quote whose PRECEDING RAW
#      CHARACTER is not a backslash.
#   7. An unterminated region blanks the rest of the input.
#
# Rule 6 is a defect, and it is pinned here on purpose. `\\` is an escaped
# backslash in a real shell, so `"a\\"` closes; this rule reads the second
# backslash as escaping the quote and blanks everything after it. Measured
# against the real gate: `npm install evil@1.0.0` denies, and
# `echo "a\\" ; npm install evil@1.0.0` passes -- the same for pip and cargo,
# where the command gate is the primary authority. Correcting it is a verdict
# change and belongs to its own plan
# (safedeps/escaped-backslash-blanks-the-rest), not to a refactor whose whole
# check is that no verdict moved. Pinning it here is what makes the two
# separable: this file goes red when the escape rule changes, which is exactly
# when someone should be looking.
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
  local input="$1" output="" quote="" prev="" char i
  for ((i = 0; i < ${#input}; i++)); do
    char="${input:i:1}"
    if [[ -z "${quote}" ]]; then
      case "${char}" in
        "'") quote="single"; output="${output} " ;;
        '"') quote="double"; output="${output} " ;;
        *)   output="${output}${char}" ;;
      esac
    elif [[ "${quote}" == "single" && "${char}" == "'" ]]; then
      quote=""; output="${output} "
    elif [[ "${quote}" == "double" && "${char}" == '"' && "${prev}" != "\\" ]]; then
      quote=""; output="${output} "
    else
      output="${output} "
    fi
    prev="${char}"
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
  [[ ${#got} -eq ${#input} ]] || fail "${label}: length not preserved (${#input} in, ${#got} out)"
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

# rule 6, the pinned defect: `\\` should close and does not
check "escaped backslash before the closing quote blanks the rest (pinned defect)" \
  'echo "a\\" ; npm i x' \
  "echo$(sp 16)"

# rule 2: outside a region a backslash is an ordinary character
check "backslash outside a region does not escape the quote that follows" \
  'echo \"npm install evil\"' \
  "echo \\$(sp 19)"

check "backslash outside a region survives" \
  'echo a\ b' \
  'echo a\ b'

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

# rule 1 is in characters, not bytes: a multibyte character blanks to ONE blank
check "a multibyte character inside a region blanks to one character" \
  "echo '한글' x" \
  "echo$(sp 6)x"

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
  local input="$1" output="" quote="" prev="" char i
  for ((i = 0; i < ${#input}; i++)); do
    char="${input:i:1}"
    if [[ -z "${quote}" ]]; then
      case "${char}" in
        "'") quote="single"; output="${output} " ;;
        '"') quote="double"; output="${output} " ;;
        *)   output="${output}${char}" ;;
      esac
    elif [[ "${quote}" == "double" && "${char}" == '"' && "${prev}" != "\\" ]]; then
      quote=""; output="${output} "
    else
      output="${output} "
    fi
    prev="${char}"
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

printf 'scan-contract: all checks passed\n'
