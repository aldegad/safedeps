#!/usr/bin/env bash
# safedeps: command_scan_text contract battery.
#
# command_scan_text is the guard's quoting model. Every detection predicate on
# the PreToolUse path reads its output rather than the raw command, so what this
# function blanks decides what the gate can see. The predicates are:
#
#   command_is_dependency_install    is this an install command
#   command_is_injectable_npm_install  may --ignore-scripts be injected
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
#      through as data and never opens a region (`\pip` is `pip`), and an
#      escaped newline -- a line continuation, which the shell removes -- is
#      blanked, so the two lines read as one. An escaped operator
#      (`;&|()<>!{}#` or a backtick) passes as `_`: it is a literal character
#      to the shell, and passed through as itself it would end a statement or
#      open one for every predicate that reads the scan. So does an escaped
#      quote, backslash or dollar: as itself it would open a quote, an escape
#      or a `$'` region when the scan is read again, and the scan view has to
#      read the same the second time (caught by the view-property check).
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
shipped_src=$(sed -n '/^shell_lex() {/,/^}/p; /^command_scan_text() {/,/^}/p' "${GUARD}")
[[ "${shipped_src}" == *"shell_lex() {"* && "${shipped_src}" == *"command_scan_text() {"* ]] \
  || fail "shell_lex and command_scan_text not found in ${GUARD} (renamed? then update this battery)"
eval "${shipped_src}"
declare -F command_scan_text > /dev/null || fail "extracted command_scan_text did not define the function"
# The lexer reads the lists of the grammar (the shells, the executables), as
# it does in the guard.
# shellcheck source=lib/install-grammar.sh
source "${ROOT_DIR}/lib/install-grammar.sh"
# This battery is a driver of its own: the reference below states the bash
# reading, so that is the reading it checks the shipped lexer under. The zsh
# and dash readings are checked by the view properties further down.
SAFEDEPS_READING=bash

# The lexer is one awk program inside single quotes, so an apostrophe in it ends
# the quoting. An odd count is a parse error; an even count splices the text
# between the two into the program unquoted, and it runs with no error (a
# comment that quoted a word did that, caught in review). Write \047 instead.
lexer_program=$(sed -n '/^shell_lex() {/,/^}/p' "${GUARD}" | sed -n '/LC_ALL=C awk -v view=.*'"'"'$/,/^  '"'"'/p' | sed '1d;$d')
[[ -n "${lexer_program}" ]] || fail "the lexer program could not be extracted from ${GUARD}"
[[ "${lexer_program}" != *"'"* ]] || fail "the lexer program holds an apostrophe, which ends its quoting; write \\047"
pass "the lexer program holds no apostrophe"

# A reading is picked in one place. shell_lex takes no reading argument, and
# the variable it reads is set only by the guard's driver -- the functions that
# run one reading's detection, judgment, UNGATED walk and inert/trace effects
# -- and cleared at the top.
# Before this, call sites named their reading, and one that lexed text another
# reading had produced under a fixed name hid a line zsh runs (form SL1).
lex_calls=$(grep -nE '(^|[^_[:alnum:]])shell_lex[[:space:]]' "${GUARD}" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -v 'shell_lex() {')
[[ -n "${lex_calls}" ]] || fail "no shell_lex call sites found in ${GUARD} (renamed? then update this check)"
bad_calls=$(printf '%s\n' "${lex_calls}" | grep -vE 'shell_lex "[^"]+" ("\$\{view\}"|[a-z-]+) "safedeps:[a-z_]+"' || true)
[[ -z "${bad_calls}" ]] || fail "shell_lex call sites that do not read <text> <view> <marker>:
${bad_calls}"
reading_sets=$(awk '
  /^[a-z_]+\(\) \{/ { fn = $1; sub(/\(\).*/, "", fn) }
  /^\}/ { fn = "" }
  /^[[:space:]]*#/ { next }
  /SAFEDEPS_READING=/ {
    if (fn == "" && $0 ~ /^SAFEDEPS_READING=""$/) next
    if (fn ~ /^guard_reading_(detect|facts|ungated|effects)$/) next
    if (fn == "shell_lex" && $0 !~ /SAFEDEPS_READING=[^:]/) next
    print FILENAME ":" NR ": " $0
  }' "${GUARD}")
[[ -z "${reading_sets}" ]] || fail "SAFEDEPS_READING is set outside the driver:
${reading_sets}"
pass "shell_lex call sites name no reading, and only the driver sets one ($(printf '%s\n' "${lex_calls}" | wc -l | tr -d ' ') call sites)"

# --- the spec -----------------------------------------------------------------
# Deliberately the slowest, most obvious statement of the seven rules. It is
# read by this battery only, so its cost is irrelevant and its clarity is not.
reference_spec_scan_text() {
  local LC_ALL=C
  local input="$1" output="" i c n=${#1}
  local mode="" sq_closes="${REF_SQ_CLOSES:-1}"
  # The context stack: T top, D double quotes, S $( or subshell, A arithmetic,
  # K $[, V ${. dq counts the D entries; par counts parentheses per level.
  local -a ctx=(T) par=(0)
  local d=0 dq=0
  for ((i = 0; i < n; i++)); do
    c="${input:i:1}"
    if [[ "${mode}" == "SQ" ]]; then
      output+=" "
      [[ "${c}" == "'" && "${sq_closes}" == 1 ]] && mode=""
      continue
    fi
    if [[ "${mode}" == "AQ" ]]; then
      output+=" "
      if [[ "${c}" == "\\" ]]; then ((i++)); [[ ${i} -lt ${n} ]] && output+=" "
      elif [[ "${c}" == "'" ]]; then mode=""; fi
      continue
    fi
    if [[ "${ctx[d]}" == "D" ]]; then
      output+=" "
      if [[ "${c}" == "\\" ]]; then ((i++)); [[ ${i} -lt ${n} ]] && output+=" "
      elif [[ "${c}" == '"' ]]; then ((d--)); ((dq--))
      elif [[ "${c}" == '$' && "${input:i+1:2}" == "((" ]]; then
        if reference_la "${input}" $((i + 3)); then output+="  "; ((i += 2)); ((d++)); ctx[d]=A; par[d]=0
        else output+=" "; ((i++)); ((d++)); ctx[d]=S; par[d]=0; fi
      elif [[ "${c}" == '$' && "${input:i+1:1}" == "(" ]]; then output+=" "; ((i++)); ((d++)); ctx[d]=S; par[d]=0
      elif [[ "${c}" == '$' && "${input:i+1:1}" == "{" ]]; then output+=" "; ((i++)); ((d++)); ctx[d]=V; par[d]=0
      fi
      continue
    fi
    # Code. Inside quotes (dq > 0) it is blanked like the quotes around it.
    local keep="${c}" two="${input:i:2}" three="${input:i:3}"
    [[ ${dq} -gt 0 ]] && { keep=" "; two="  "; three="   "; }
    if [[ "${c}" == "\\" ]]; then
      if [[ "${input:i+1:1}" == $'\n' ]]; then output+="  "; ((i++)); continue; fi
      output+=" "
      ((i++)); [[ ${i} -lt ${n} ]] || continue
      c="${input:i:1}"
      if [[ ${dq} -gt 0 ]]; then output+=" "
      else
        case "${c}" in
          ';'|'&'|'|'|'('|')'|'<'|'>'|'!'|'{'|'}'|'#'|'`'|'"'|"'"|\\|'$') output+="_" ;;
          *) output+="${c}" ;;
        esac
      fi
      continue
    fi
    if [[ "${c}" == '$' && "${input:i+1:1}" == "'" ]]; then output+="  "; ((i++)); mode=AQ; continue; fi
    if [[ "${c}" == "'" ]]; then output+=" "; mode=SQ; continue; fi
    if [[ "${c}" == '"' ]]; then output+=" "; ((d++)); ctx[d]=D; par[d]=0; ((dq++)); continue; fi
    if [[ "${ctx[d]}" == "A" || "${ctx[d]}" == "K" ]]; then
      output+="${keep}"
      if [[ "${ctx[d]}" == "K" ]]; then [[ "${c}" == "]" ]] && ((d--)); continue; fi
      if [[ "${c}" == "(" ]]; then ((par[d]++))
      elif [[ "${c}" == ")" ]]; then
        if [[ ${par[d]} -gt 0 ]]; then ((par[d]--))
        elif [[ "${input:i+1:1}" == ")" ]]; then output+="${keep}"; ((i++)); ((d--)); fi
      fi
      continue
    fi
    # `((` and `$((` are decided where they stand, by the look-ahead bash
    # makes (reference_la): arithmetic, or a subshell -- `$(` and a `(`.
    if [[ "${c}" == '$' && "${input:i+1:2}" == "((" ]]; then
      if reference_la "${input}" $((i + 3)); then output+="${three}"; ((i += 2)); ((d++)); ctx[d]=A; par[d]=0
      else output+="${two}"; ((i++)); ((d++)); ctx[d]=S; par[d]=0; fi
      continue
    fi
    if [[ "${c}" == "(" && "${input:i+1:1}" == "(" ]]; then
      output+="${two}"; ((i++))
      if reference_la "${input}" $((i + 1)); then ((d++)); ctx[d]=A; par[d]=0
      else par[d]=$((par[d] + 2)); fi
      continue
    fi
    if [[ "${c}" == '$' && "${input:i+1:1}" == "(" ]]; then output+="${two}"; ((i++)); ((d++)); ctx[d]=S; par[d]=0; continue; fi
    if [[ "${c}" == '$' && "${input:i+1:1}" == "[" ]]; then output+="${two}"; ((i++)); ((d++)); ctx[d]=K; par[d]=0; continue; fi
    if [[ "${c}" == '$' && "${input:i+1:1}" == "{" ]]; then output+="${two}"; ((i++)); ((d++)); ctx[d]=V; par[d]=0; continue; fi
    output+="${keep}"
    if [[ "${ctx[d]}" == "V" ]]; then [[ "${c}" == "}" ]] && ((d--)); continue; fi
    if [[ "${c}" == "(" ]]; then ((par[d]++))
    elif [[ "${c}" == ")" ]]; then
      if [[ ${par[d]} -gt 0 ]]; then ((par[d]--))
      elif [[ "${ctx[d]}" == "S" ]]; then ((d--)); fi
    fi
  done
  printf '%s' "${output}"
}

reference_scan_text() { reference_spec_scan_text "$@"; }

# The look-ahead bash makes at `((` (or `$((`), from offset k: to the first `)`
# not nested in a parenthesis, stepping over quotes, an escape, `$(...)`,
# `${...}` and backticks whole. Arithmetic (status 0) when another `)` follows
# it or when there is none; a subshell (status 1) otherwise. Measured cells:
# forms B1, LA1-LA5 in scripts/measure/shell-reading-forms.json.
reference_la() {
  local LC_ALL=C
  local input="$1" k="$2" n=${#1} depth=0 c
  while (( k < n )); do
    c="${input:k:1}"
    case "${c}" in
      \\) ((k += 2)); continue ;;
      "'") k=$(reference_la_sq "${input}" $((k + 1))); continue ;;
      '"') k=$(reference_la_dq "${input}" $((k + 1))); continue ;;
      '`') k=$(reference_la_bq "${input}" $((k + 1))); continue ;;
      '$')
        if [[ "${input:k+1:1}" == "(" ]]; then k=$(reference_la_close "${input}" $((k + 2)) ")"); continue; fi
        if [[ "${input:k+1:1}" == "{" ]]; then k=$(reference_la_close "${input}" $((k + 2)) "}"); continue; fi
        ;;
      "(") ((depth++)) ;;
      ")")
        if (( depth > 0 )); then ((depth--))
        else [[ "${input:k+1:1}" == ")" ]]; return; fi
        ;;
    esac
    ((k++))
  done
  return 0
}
reference_la_sq() { local LC_ALL=C k="$2"; while (( k < ${#1} )) && [[ "${1:k:1}" != "'" ]]; do ((k++)); done; printf '%s' $((k + 1)); }
reference_la_bq() {
  local LC_ALL=C k="$2"
  while (( k < ${#1} )); do
    case "${1:k:1}" in \\) ((k += 2)); continue ;; '`') printf '%s' $((k + 1)); return ;; esac
    ((k++))
  done
  printf '%s' $((k + 1))
}
reference_la_dq() {
  local LC_ALL=C input="$1" k="$2"
  while (( k < ${#input} )); do
    case "${input:k:1}" in
      \\) ((k += 2)); continue ;;
      '"') printf '%s' $((k + 1)); return ;;
      '`') k=$(reference_la_bq "${input}" $((k + 1))); continue ;;
      '$')
        if [[ "${input:k+1:1}" == "(" ]]; then k=$(reference_la_close "${input}" $((k + 2)) ")"); continue; fi
        if [[ "${input:k+1:1}" == "{" ]]; then k=$(reference_la_close "${input}" $((k + 2)) "}"); continue; fi
        ;;
    esac
    ((k++))
  done
  printf '%s' $((k + 1))
}
reference_la_close() {
  local LC_ALL=C input="$1" k="$2" closer="$3" depth=0 c
  while (( k < ${#input} )); do
    c="${input:k:1}"
    case "${c}" in
      \\) ((k += 2)); continue ;;
      "'") k=$(reference_la_sq "${input}" $((k + 1))); continue ;;
      '"') k=$(reference_la_dq "${input}" $((k + 1))); continue ;;
      '`') k=$(reference_la_bq "${input}" $((k + 1))); continue ;;
      '$')
        if [[ "${input:k+1:1}" == "(" ]]; then k=$(reference_la_close "${input}" $((k + 2)) ")"); continue; fi
        if [[ "${input:k+1:1}" == "{" ]]; then k=$(reference_la_close "${input}" $((k + 2)) "}"); continue; fi
        ;;
    esac
    if [[ "${closer}" == ")" && "${c}" == "(" ]]; then ((depth++))
    elif [[ "${c}" == "${closer}" ]]; then
      if (( depth > 0 )); then ((depth--)); else printf '%s' $((k + 1)); return; fi
    fi
    ((k++))
  done
  printf '%s' $((k + 1))
}

# `((` opens arithmetic only where a command starts.
reference_cmdpos() {
  local input="$1" k=$(( $2 - 1 )) w=""
  while [[ ${k} -ge 0 && ( "${input:k:1}" == " " || "${input:k:1}" == $'\t' ) ]]; do ((k--)); done
  [[ ${k} -lt 0 ]] && return 0
  case "${input:k:1}" in $'\n'|';'|'&'|'|'|'('|'!'|'{') return 0 ;; esac
  while [[ ${k} -ge 0 && "${input:k:1}" == [a-z] ]]; do w="${input:k:1}${w}"; ((k--)); done
  [[ "${w}" =~ ^(if|then|else|elif|while|until|do|time)$ ]]
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
  'echo  _npm install evil _'

check "an escaped single quote outside a region is data too" \
  "echo \' ; npm i x" \
  "echo  _ ; npm i x"

check "an escaped backslash or dollar passes as _, so the scan reads the same again" \
  'echo \\\$ ; npm i x' \
  'echo  _ _ ; npm i x'

check "a backslash before a command name is blanked" \
  '\pip install evil' \
  ' pip install evil'

check "an escaped semicolon is a character, not the end of a statement" \
  'echo a \; pip install evil' \
  'echo a  _ pip install evil'

check "an escaped pipe is a character, not a pipe" \
  'echo x \| sh' \
  'echo x  _ sh'

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
  REF_SQ_CLOSES=0 reference_spec_scan_text "$@"
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

# --- view properties ------------------------------------------------------------
# Every reader takes a view of the one lexing, and three views are read as
# offsets into the command: scan (what the predicates read), code (quotes
# kept, which the inert rewrite reads beside the live view) and noredir (the
# command with its redirections blanked). Each keeps the byte length of the
# command, so an offset found in a view is the offset in the command, and each
# is idempotent, so a view read again is the view read once. No reader of the
# guard lexes a view's output any more (the lexing trace below holds that), so
# idempotence is a property of the lexer here, not a license: stripping a
# heredoc twice is how its body once swallowed the line after it (caught in
# review), and lexing the joined view again is how the live code of a body
# took the next command for its argument (verdict buri-20261005-145152).
# Checked on every recorded shell form and on random input drawn from the
# characters quotes, comments, heredocs, substitutions and redirections are
# made of.
#
# Each property holds within each reading (bash, zsh, dash): a view is read
# again only under the reading that made it. And one property holds across
# them: where the bash reading says no DIVERGE, the zsh and dash views are the
# bash views, byte for byte. That is what lets the guard skip the other two
# readings, so a place where the shells differ that the lexer does not report
# shows here as a reading that moved without a DIVERGE. The statement starts
# are in that check too, as the events they are (the events view, and the
# recognize view the recognizers read): a start only zsh reads (`repeat 1 {`,
# `true&!pip i`) has to make the bash reading say DIVERGE, or the zsh reading
# that finds it never runs. Those two views are not offsets into the command
# (a start is a place between two bytes, and the recognize view puts a `;`
# in there), so they are held to the cross-reading check alone.
scan_view() { shell_lex "$1" scan "safedeps:scan-contract"; }
code_view() { shell_lex "$1" code "safedeps:scan-contract"; }
noredir_view() { shell_lex "$1" noredir "safedeps:scan-contract"; }
stmts_view() { shell_lex "$1" stmts "safedeps:scan-contract"; }
unprefixed_view() { shell_lex "$1" unprefixed "safedeps:scan-contract"; }
events_view() { shell_lex "$1" events "safedeps:scan-contract"; }
recognize_view() { shell_lex "$1" recognize "safedeps:scan-contract"; }
stmtcuts_view() { shell_lex "$1" stmtcuts "safedeps:scan-contract"; }
property_failures=0
stmts_unterm=0
diverge_file=$(mktemp "${TMPDIR:-/tmp}/safedeps-diverge.XXXXXX")
# Whether the lexer finishes reading <text> in the current reading: an open
# quote, body or context makes it UNTERM, which the guard settles as a failed
# reading.
reading_closes() {
  local flags rc=0
  flags=$(mktemp "${TMPDIR:-/tmp}/safedeps-flags.XXXXXX")
  SAFEDEPS_LEX_FLAGS="${flags}" shell_lex "$1" scan "safedeps:scan-contract" > /dev/null
  grep -q '^UNTERM$' "${flags}" && rc=1
  rm -f "${flags}"
  return "${rc}"
}
check_view_properties() { # input label
  local x="$1" v once twice reading bash_views="" views
  for reading in bash zsh dash; do
    views=""
    for v in scan_view code_view noredir_view stmts_view; do
      # Not through capture: the outer $(...) would strip a trailing newline
      # from the view and read as a length change the lexer did not make.
      once=$(SAFEDEPS_READING="${reading}" "${v}" "${x}"; printf 'X'); once="${once%X}"
      views+="${once}"$'\036'
      if [[ "$(byte_len "${once}")" != "$(byte_len "${x}")" ]]; then
        printf 'length: %s (%s) changed the length of [%q] (%s)\n' "${v}" "${reading}" "${x}" "$2" >&2
        property_failures=$((property_failures + 1))
        continue
      fi
      # The stmts view blanks a separator inside a redirection only for a
      # reading that closes (as the prefix and redirection views strip only
      # then). An unclosed reading, whose open quote the view prints blank,
      # may close when it is read again. Such a command is UNDECIDED, so
      # nothing reads its statements; the view is held to idempotence on
      # every reading that closes, and the ones skipped are counted below.
      # It carries no statement start, so there is nothing a second reading
      # may add: it used to write each start over the byte before it, and a
      # word holding an escape or a quote, read again, could find one more.
      if [[ "${v}" == stmts_view ]] && ! SAFEDEPS_READING="${reading}" reading_closes "${x}"; then
        stmts_unterm=$((stmts_unterm + 1))
        continue
      fi
      twice=$(SAFEDEPS_READING="${reading}" "${v}" "${once}"; printf 'X'); twice="${twice%X}"
      if [[ "${twice}" != "${once}" ]]; then
        printf 'idempotence: %s (%s) read twice differs on [%q] (%s)\n  once  [%q]\n  twice [%q]\n' "${v}" "${reading}" "${x}" "$2" "${once}" "${twice}" >&2
        property_failures=$((property_failures + 1))
      fi
    done
    # The starts, as events and as the recognizers read them: the
    # cross-reading check only.
    for v in events_view recognize_view; do
      once=$(SAFEDEPS_READING="${reading}" "${v}" "${x}"; printf 'X'); once="${once%X}"
      views+="${once}"$'\036'
    done
    if [[ "${reading}" == bash ]]; then
      bash_views="${views}"
      : > "${diverge_file}"
      for v in scan_view code_view noredir_view stmts_view events_view recognize_view; do
        SAFEDEPS_READING=bash SAFEDEPS_LEX_DIVERGE="${diverge_file}" "${v}" "${x}" > /dev/null
      done
    elif [[ ! -s "${diverge_file}" && "${views}" != "${bash_views}" ]]; then
      printf 'diverge: the %s reading of [%q] differs from bash, and the bash reading said no DIVERGE (%s)\n' "${reading}" "${x}" "$2" >&2
      property_failures=$((property_failures + 1))
    fi
  done
}
forms_file="${ROOT_DIR}/scripts/measure/shell-reading-forms.json"
form_count=$(jq length "${forms_file}")
for ((i = 0; i < form_count; i++)); do
  form=$(jq -j ".[${i}].text" "${forms_file}" | sed -e 's/@@TAIL@@/pip install evil==6.6.6/' -e 's/@@HEAD@@/pip/g' -e 's/@@TAIL_SPLIT@@/pi\\\
p install evil==6.6.6/'; printf 'X')
  check_view_properties "${form%X}" "$(jq -r ".[${i}].id" "${forms_file}")"
done
RANDOM="${fuzz_seed}"
heredoc_alphabet=(\' \" \\ ' ' '<' '<' '>' '-' '#' '`' '$' '(' '(' ')' ')' '{' '}' '[' ']' E O F p i $'\n' $'\n' $'\t' ';' '|' '&' '=' '1')
for ((c = 0; c < fuzz_cases; c++)); do
  len=$((RANDOM % 40))
  input=""
  for ((k = 0; k < len; k++)); do
    input+="${heredoc_alphabet[RANDOM % ${#heredoc_alphabet[@]}]}"
  done
  check_view_properties "${input}" "random ${c}"
done
[[ ${property_failures} -eq 0 ]] || fail "view properties: ${property_failures} violation(s) (seed ${fuzz_seed})"
rm -f "${diverge_file}"
pass "view properties: scan, code, noredir and stmts keep length and are idempotent in the bash, zsh and dash readings, and they and the starts (events, recognize) read as bash wherever bash says no DIVERGE, on ${form_count} shell forms and ${fuzz_cases} random inputs (stmts: ${stmts_unterm} unclosed readings not asked)"

# --- the statement starts (events) ----------------------------------------------
# Where a command starts is a place between two bytes, and the lexer's walk
# over the words (starts() in shell_lex) says where, from the shell grammar:
# after a separator, a case pattern close, a reserved word, a function head,
# `time`, `coproc`, the zsh short forms. SAFEDEPS_G_START knows only
# separators. The walk hands each start on as an event, never as a byte: the
# events view lists them, the recognize view the recognizers read puts a `;`
# in at each one no separator stands before (a bare start), and
# command_statements cuts there (the stmtcuts view). The stmts view used to
# write each start over the byte before it, and a start with no byte of its
# own -- after a reserved word, `!`, a head's `)` or zsh's glued `{`, with a
# redirection first -- borrowed a byte of the token before it or was lost:
# `if true; then>/dev/null pip install x; fi` was no install to any
# recognizer (verdict bamdori-20261004-224625). The rows below print the stmts
# view with a `;` put in at each bare start, which is what a recognizer reads
# but for the prefixes the recognize view removes. The rules, each as a
# literal:
#
#   1. The stmts view keeps the length and is idempotent in each reading on
#      every reading that closes (the property check above); it carries no
#      start. The starts read as bash wherever the bash reading says no
#      DIVERGE (the same check, on the events and recognize views).
#   2. A start is an event at top-level code. None falls inside quotes, a
#      substitution, an arithmetic context or a heredoc body.
#   3. A `;` `&` `|` that is not at the top level ends no statement and is
#      `_`: inside an arithmetic context (`for ((i=0;i<1;i++)) {` was cut at
#      its `;`, and the install in the body read as no statement start), and
#      inside a substitution, whose script the payload readers judge on its
#      own. Which `((` is arithmetic is the reading's to say: dash reads it as
#      a subshell, so there its `;` is a separator.
#   4. An assignment or a redirection before a command is part of it, so no
#      start falls between them and the command, and the word after a
#      redirection operator is its target, never a command. Splitting
#      `npm_config_global=true npm install x` there dropped its UNGATED record.
#      A redirection that comes first takes the start, glued to the token
#      before it or not.
#   5. A rule is the reading's whose shell has it. A rule every reading shares
#      only adds starts, at a form the shells without it fail to parse, such
#      as a compound command right after `function NAME` (bash 5 alone), or a
#      subshell glued to the close of another (no shell parses `(a)(b)`).
#      zsh alone: `}` wherever it stands, `always`, `for NAME (WORDS)`,
#      `foreach`, `repeat`, `[[ ... ]]` or an arithmetic `((...))` before a
#      body, `case WORD {`, `;|` ending an arm, a `{` glued to the first word
#      of a command, and `&!` ending one. bash alone: `coproc NAME` before a
#      compound command, and `;;&`. dash alone: the `&` of `&>` ends a
#      command, and the next starts at the `>` (bash and zsh read one
#      redirection there). The bash reading says DIVERGE at each, so the
#      reading that reads it runs.
#   6. A descriptor word is read as each shell reads it: zsh and dash read one
#      digit glued to a redirection operator, bash any number, and a `{name}`
#      in bash and zsh. A word starts where the walk starts a command too
#      (zsh `{2>/dev/null pip i; }`), not only after a byte that ends a token.
#
# Each row names the readings it holds in. The forms the rules rest on were
# run in the real shells (macOS bash 3.2, zsh 5.9 and dash; Linux bash 5.2 and
# dash), and stmts_shell_rows below keeps what each ran.
starts_view() { # text -> the stmts view with a `;` put in at each bare start
  local out cuts body k LC_ALL=C
  out=$(stmtcuts_view "$1"; printf 'X'); out="${out%X}"
  cuts="${out%%$'\n'*}"; body="${out#*$'\n'}"
  for k in $(tr ' ' '\n' <<< "${cuts}" | sort -rn); do
    body="${body:0:k-1};${body:k-1}"
  done
  printf '%s' "${body}"
}
check_starts() { # readings label input expected
  local got reading
  for reading in $1; do
    got=$(SAFEDEPS_READING="${reading}" capture starts_view "$3")
    [[ "${got}" == "$4" ]] || fail "starts (${reading}): $2: [${got}] != expected [$4]"
  done
}
all="bash zsh dash"
check_starts "${all}" "a reserved word opens a statement" \
  'if true; then pip i; fi' 'if ;true; then ;pip i; fi'
check_starts "${all}" "a function head opens its body" \
  'f() { pip i; }; f' 'f() ;{ ;pip i; }; f'
check_starts "${all}" "a subshell function body starts at its \`(\`, glued to the head or not" \
  'f() ( pip i ); f; f()(pip i); function f ( pip i ); function f () ( pip i )' \
  'f() ;( pip i ); f; f();(pip i); function f ;( pip i ); function f () ;( pip i )'
check_starts "bash" "a subshell after coproc NAME is its body in bash" \
  'coproc foo ( pip i )' 'coproc ;foo ;( pip i )'
check_starts "zsh dash" "and nothing outside bash" \
  'coproc foo ( pip i )' 'coproc ;foo ( pip i )'
check_starts "${all}" "a function with more than one name" \
  'function f g { pip i; }' 'function f g { ;pip i; }'
check_starts "bash" "coproc NAME opens its body in bash" \
  'coproc foo { pip i; }' 'coproc ;foo { ;pip i; }'
check_starts "zsh dash" "coproc NAME opens nothing outside bash" \
  'coproc foo { pip i; }' 'coproc ;foo { pip i; }'
check_starts "${all}" "a compound command right after function NAME is its body" \
  'function f if pip i; then :; fi' 'function f ;if ;pip i; then ;:; fi'
check_starts "${all}" "a loop right after function NAME is its body" \
  'function f while pip i; do :; done' 'function f ;while ;pip i; do ;:; done'
check_starts "${all}" "a case right after function NAME opens its arms" \
  'function f case x in x) pip i;; esac' 'function f ;case x in x) ;pip i;_ esac'
check_starts "${all}" "after a second name only a brace opens a body" \
  'function f g if pip i; then :; fi' 'function f g if pip i; then ;:; fi'
check_starts "bash" "coproc NAME before a compound command opens it in bash" \
  'coproc foo if pip i; then :; fi' 'coproc ;foo ;if ;pip i; then ;:; fi'
check_starts "zsh dash" "coproc NAME before a compound command opens nothing outside bash" \
  'coproc foo if pip i; then :; fi' 'coproc ;foo if pip i; then ;:; fi'
check_starts "bash" "a case after coproc NAME opens its arms in bash" \
  'coproc foo case x in x) pip i;; esac' 'coproc ;foo ;case x in x) ;pip i;_ esac'
check_starts "${all}" "a case pattern close is a start, after the close" \
  'case x in x) { pip i; };; esac' 'case x in x) ;{ ;pip i; };_ esac'
check_starts "${all}" "an arm glued to its pattern close starts after the close" \
  'case x in x)pip i;; esac' 'case x in x);pip i;_ esac'
check_starts "${all}" "a subshell in an arm starts at its \`(\`, and the pattern close stays a close" \
  'case x in x) (echo hi);; esac' 'case x in x) ;(echo hi);_ esac'
check_starts "${all}" "time and its options" \
  'time -p pip i' 'time -p ;pip i'
check_starts "zsh" "the zsh short forms" \
  'for i (1) pip i; repeat 1 pip i; if [[ 1 ]] pip i' 'for i (1) ;pip i; repeat 1 ;pip i; if ;[[ 1 ]] ;pip i'
check_starts "bash dash" "the zsh short forms are no forms outside zsh" \
  'for i (1) pip i; repeat 1 pip i; if [[ 1 ]] pip i' 'for i (1) pip i; repeat 1 pip i; if ;[[ 1 ]] pip i'
check_starts "zsh" "an arithmetic context before a body in zsh" \
  'while ((i++<1)) { pip i; }' 'while ((i++<1)) ;{ ;pip i; }'
check_starts "bash" "an arithmetic context is a command of its own in bash" \
  'while ((i++<1)) { pip i; }' 'while ((i++<1)) { pip i; }'
check_starts "zsh" "a group closes wherever its brace stands in zsh, and always opens a block" \
  '{ true } always { pip i }' '{ ;true } ;always ;{ ;pip i }'
check_starts "bash dash" "always is a word outside zsh" \
  '{ true } always { pip i }' '{ ;true } always { pip i }'
check_starts "zsh" "an arm ends at ;| in zsh" \
  'case x in x) true;| x) pip i;; esac' 'case x in x) ;true;_ x) ;pip i;_ esac'
check_starts "bash" "an arm goes on past ;| in bash" \
  'case x in x) true;| x) pip i;; esac' 'case x in x) ;true;| x) pip i;_ esac'
check_starts "${all}" "an argument that spells a reserved word opens nothing" \
  'echo { pip i }; echo then pip i; echo ! pip i' 'echo { pip i }; echo then pip i; echo ! pip i'
check_starts "${all}" "no start inside quotes" \
  'echo "then pip i" '"'"'{ pip i'"'" "echo$(sp 23)"
check_starts "${all}" "no start inside a substitution, and its separators end no top-level statement" \
  'echo $(if x; then pip i; fi)' 'echo $(if x_ then pip i_ fi)'
check_starts "${all}" "no start inside a heredoc body" \
  $'cat <<E\nthen pip i\nE' $'cat    \n'"$(sp 12)"
check_starts "bash zsh" "an arithmetic separator ends nothing" \
  'for ((i=0;i<1;i++)) { pip i; }' 'for ((i=0_i<1_i++)) { ;pip i; }'
check_starts "dash" "dash reads (( as a subshell, whose separators end statements" \
  'for ((i=0;i<1;i++)) { pip i; }' 'for ((i=0;i<1;i++)) { pip i; }'
check_starts "${all}" "a substitution inside arithmetic is nested, and ends nothing at the top" \
  'echo $(( $(true; pip i) ))' 'echo $(( $(true_ pip i) ))'
check_starts "${all}" "an assignment stays with its command" \
  'if FOO=1 BAR=2 pip i; fi' 'if ;FOO=1 BAR=2 pip i; fi'
check_starts "${all}" "a redirection stays with its command, and its target is no command" \
  '! > then 2>&1 pip i' '! ;> then 2>_1 pip i'
check_starts "${all}" "a redirection that comes first takes its command's start" \
  '{ 2>/dev/null pip i; }; if >f pip i; then :; fi' '{ ;2>/dev/null pip i; }; if ;>f pip i; then ;:; fi'
check_starts "bash zsh" "&> is one redirection operator outside dash" \
  'echo a &>/dev/null pip i; pip i &>f' 'echo a  >/dev/null pip i; pip i  >f'
check_starts "dash" "dash ends a command at the & of &>, and the next starts at the >" \
  'echo a &>/dev/null pip i; pip i &>f' 'echo a &>/dev/null pip i; pip i &>f'
check_starts "dash" "the command dash starts at the > reads its words as at any start" \
  'echo a &>/dev/null time pip i' 'echo a &>/dev/null time ;pip i'
check_starts "bash zsh" "after &> the same words are arguments" \
  'echo a &>/dev/null time pip i' 'echo a  >/dev/null time pip i'
check_starts "${all}" "after > the & of a duplication is the operator in every shell" \
  'echo a >&/dev/null pip i; echo a 2>&1 pip i' 'echo a >_/dev/null pip i; echo a 2>_1 pip i'
check_starts "${all}" "a command glued to a function head starts at its escape, which the view prints blank" \
  'f()\pip i' 'f(); pip i'
check_starts "${all}" "a subshell where a command stands, with words of its statement before it, is a start" \
  'function f { (pip i); }; f' 'function f { ;(pip i); }; f'
check_starts "${all}" "after do, glued to it or not" \
  'for i do (pip i); done; for i do(pip i); done' 'for i do ;(pip i); done; for i do;(pip i); done'
check_starts "${all}" "the close of a subshell ends a command, so a reserved word may follow it" \
  'if (true) then (pip i) fi' 'if ;(true) ;then ;(pip i) ;fi'
check_starts "${all}" "the same glued: each start is put in between the two bytes" \
  'if(true)then(pip i)fi' 'if;(true);then;(pip i);fi'
check_starts "${all}" "an empty () with a blank inside is a function head" \
  'f( ) { pip i; }; f( )( pip i )' 'f( ) ;{ ;pip i; }; f( );( pip i )'
check_starts "${all}" "a subshell after a separator needs no start" \
  'a && (pip i); (pip i) | (pip i)' 'a && (pip i); (pip i) | (pip i)'
check_starts "${all}" "a ( among the arguments opens no subshell, and its close ends no command" \
  'echo a (b) pip i' 'echo a (b) pip i'
check_starts "${all}" "inside [[ ... ]] a ( groups a test and starts nothing" \
  '[[ ( -n x ) ]] && pip i' '[[ ( -n x ) ]] && pip i'
check_starts "${all}" "a subshell glued to the close of another is a start no shell parses, delivered all the same" \
  '(a)(pip i); (a) (pip i)' '(a);(pip i); (a) ;(pip i)'
check_starts "${all}" "a process substitution opens a command, an argument after it does not" \
  'cat <(echo hi) pip i' 'cat <(echo hi) pip i'
# Starts with no byte of their own before them (the verdict's class): a
# redirection glued to a reserved word, `!`, a head's close or zsh's glued
# `{`. Each is a start the walk always found; only its delivery lost it.
check_starts "${all}" "a redirection glued to a reserved word or ! starts its command" \
  'if true; then>/dev/null pip i; fi; !>/dev/null pip i; if>f pip i; then :; fi' \
  'if ;true; then;>/dev/null pip i; fi; !;>/dev/null pip i; if;>f pip i; then ;:; fi'
check_starts "bash zsh" "a redirection glued to an arithmetic for head" \
  'for ((i=0;i<1;i++)) {>/dev/null pip i; }' 'for ((i=0_i<1_i++)) {;>/dev/null pip i; }'
check_starts "zsh" "after a short-form head's close" \
  'for i (1)>/dev/null pip i; if ((1))2>/dev/null pip i; if (true)2>&1 pip i' \
  'for i (1);>/dev/null pip i; if ((1));2>/dev/null pip i; if ;(true);2>_1 pip i'
check_starts "zsh" "after a { glued to the first word, with a prefix first" \
  '{X=1 pip i; }; {2>/dev/null pip i; }; {command pip i; }; () {2>&1 pip i; }; repeat 1 {X=1 pip i; }' \
  '{;X=1 pip i; }; {;2>/dev/null pip i; }; {;command pip i; }; () {;2>_1 pip i; }; repeat 1 {;X=1 pip i; }'
check_starts "bash dash" "where the { is the first byte of the command word" \
  '{X=1 pip i; }; {2>/dev/null pip i; }; () {2>&1 pip i; }' \
  '{X=1 pip i; }; {2>/dev/null pip i; }; () ;{2>_1 pip i; }'
check_starts "zsh" "a subscript assignment after a glued { is a prefix" \
  '{a[1]=x pip i; }' '{;a[1]=x pip i; }'
check_starts "zsh" "zsh ends a command at &!, glued to the next or not" \
  'true&!pip i; { true&!pip i; }; true &! pip i' 'true&!;pip i; { ;true&!;pip i; }; true &! ;pip i'
check_starts "bash dash" "bash and dash read the ! glued to & as part of the next word" \
  'true&!pip i; true &! pip i' 'true&!pip i; true &! ;pip i'
check_starts "zsh" "zsh reads one digit as a descriptor, so repeat counts the rest" \
  'repeat 12>&1 pip i' 'repeat 12;>_1 pip i'
check_starts "bash dash" "repeat is a command outside zsh" \
  'repeat 12>&1 pip i' 'repeat 12>_1 pip i'
check_starts "zsh" "a zsh precommand modifier is followed by a start" \
  'noglob pip i; echo noglob pip i' 'noglob ;pip i; echo noglob pip i'
pass "starts: each start the walk finds is an event, put in between two bytes, and nothing nested opens one"

# The unprefixed view puts a `;` in at each start no separator stands before,
# as the recognize view does, so a start whose prefix it removes keeps a
# separator before its command (`then>/dev/null pip` is `then;pip`, never
# `thenpip`); a start that was itself a removed prefix leaves its `;` too.
# It drops what a command starts with before its name --
# assignments, env, command, exec, and redirections -- at every start the
# stmts walk finds, so the install recognizers see the command name at a
# separator. A redirection left in place put a word between the start and the
# install (`2>/dev/null pip install ...`, which every shell runs), and the
# starts after `function NAME {` used to keep their assignments. A
# redirection anywhere else is blanked (the redirection rows below), and the
# words after it stay what they were: after echo, arguments.
check_unprefixed() { # readings label input expected
  local got reading
  for reading in $1; do
    got=$(SAFEDEPS_READING="${reading}" capture unprefixed_view "$3")
    [[ "${got}" == "$4" ]] || fail "unprefixed view (${reading}): $2: [${got}] != expected [$4]"
  done
}
check_unprefixed "${all}" "a redirection before the command name goes, with its target" \
  '2>/dev/null pip i' 'pip i'
check_unprefixed "${all}" "a redirection with a blank before its target, after a separator" \
  'echo a; 2> /dev/null pip i' 'echo a; pip i'
check_unprefixed "${all}" "redirections and assignments mixed, inside a group" \
  '{ FOO=1 </dev/null 2>&1 BAR=2 pip i; }' '{ ;pip i; }'
check_unprefixed "${all}" "a start after function NAME drops its prefixes" \
  'function f { 2>&1 FOO=1 pip i; }' 'function f { ;pip i; }'
check_unprefixed "${all}" "a redirection after the command name is blanked, and the words after it stay arguments" \
  'echo 2>/dev/null pip i' "echo$(sp 13)pip i"
check_unprefixed "bash zsh" "a redirection after an argument is blanked" \
  'echo a &>/dev/null pip i' "echo a$(sp 13)pip i"
check_unprefixed "dash" "after the & of &> a command starts, and its redirection goes" \
  'echo a &>/dev/null pip i' 'echo a &pip i'
check_unprefixed "dash" "the same with &>> and a blank before the target" \
  'echo a &>> /dev/null FOO=1 pip i' 'echo a &pip i'
check_unprefixed "${all}" "env, command and time are programs as well, named in any case or by a path" \
  'TIME pip i; /usr/bin/time -p pip i; ENV pip i; Command pip i; /usr/bin/env pip i' 'pip i; pip i; pip i; pip i; pip i'
pass "unprefixed view: the prefixes a command starts with go, redirections among them, and only at a start; a redirection elsewhere is blanked"

# A redirection is read where the shell reads one, and every view that drops
# it drops the same bytes: the operator, the descriptor word glued in front
# (a number, or bash's {varname}), and the target word as the shell cuts it.
# The recognizers read the unprefixed view, which blanks a redirection
# wherever it stands, so they read the statement the spec extractor reads
# (noredir). Three readings disagreed with the shell here, and each hid an
# install every shell of its kind runs:
#
#   - a target that is a process substitution was cut at its `<`, the empty
#     word, so `< <(true) pip install x` kept `<(true)` where the command
#     name stands (bash 3.2, bash 5, zsh);
#   - `{fd}>/dev/null pip install x` read `{fd}` as the command (bash 5);
#   - a redirection between the manager and its verb was left in the
#     recognizers' text, so `pip 2>/dev/null install x` was no install to
#     them while the extractor read one (every shell).
#
# A process substitution runs its body, so the body is a payload, like
# `$(...)`; the live view keeps it where the target is blanked. zsh reads a
# `!` after `>` as part of the operator; bash and dash read it as the target,
# and the bash reading says DIVERGE where that moves the target.
check_view() { # view readings label input expected
  local got reading
  for reading in $2; do
    # The sentinel again: a view can end in a newline, which a bare $(...)
    # here would strip. The substs view ends each body in \035.
    got=$(SAFEDEPS_READING="${reading}" capture "$1" "$4"; printf 'X'); got="${got%X}"
    [[ "${got}" == "$5" ]] || fail "$1 (${reading}): $3: [${got}] != expected [$5]"
  done
}
live_view() { shell_lex "$1" live "safedeps:scan-contract"; }
substs_view() { shell_lex "$1" substs "safedeps:scan-contract"; }
check_view noredir_view "zsh dash" "a descriptor word: zsh and dash read one digit glued to an operator as its descriptor" \
  'echo 12>/dev/null pip i; echo 1>/dev/null' "echo 12$(sp 10) pip i; echo$(sp 12)"
check_view noredir_view "bash" "bash reads any number" \
  'echo 12>/dev/null pip i; echo 1>/dev/null' "echo$(sp 13) pip i; echo$(sp 12)"
check_view recognize_view "zsh" "a descriptor word starts where the walk starts the command: after a { zsh reads as glued" \
  '{2>/dev/null pip i; }; ! 2>&1 pip i' '{;pip i; }; ! ;pip i'
check_view recognize_view "bash dash" "where the { is a byte of the first word, the word is the command" \
  '{2>/dev/null pip i; }; ! 2>&1 pip i' "{2$(sp 11)pip i; }; ! ;pip i"
check_view noredir_view "${all}" "a process substitution target is one word" \
  '< <(true) pip i' "$(sp 10)pip i"
check_view noredir_view "${all}" "a process substitution target with a blank and a redirection inside" \
  'cat > >(sort >/dev/null) x' "cat$(sp 22)x"
check_view noredir_view "${all}" "a {varname} descriptor is part of its redirection" \
  '{fd}>/dev/null pip i; pip {a}<&0 i' "$(sp 15)pip i; pip$(sp 8)i"
check_view noredir_view "${all}" "a number glued after a word is no descriptor, nor is a brace expansion" \
  'echo a2>f {a,b}>g' 'echo a2   {a,b}  '
check_view noredir_view "${all}" "an operator stops before the \`<\` or \`>\` that opens a process substitution" \
  'pip ><(true) i; pip >>(cat) i; pip <<(true) i' "pip$(sp 10)i; pip$(sp 9)i; pip$(sp 10)i"
check_view noredir_view "${all}" "a process substitution that is an argument stays" \
  'cat <(pip i) >(pip i)' 'cat <(pip i) >(pip i)'
check_view noredir_view "bash dash" "bash and dash read the ! after > as the target" \
  '>! f pip i' '   f pip i'
check_view noredir_view "zsh" "zsh reads >! as the operator" \
  '>! f pip i' "$(sp 5)pip i"
check_view noredir_view "${all}" "a ! glued to its target is the same bytes in every shell" \
  '>!f pip i' '    pip i'
check_view scan_view "${all}" "a descriptor number glued to a heredoc operator is part of it" \
  $'0<<E pip i\nx\nE' "$(sp 5)pip i"$'\n'"$(sp 3)"
check_view scan_view "${all}" "so is a {varname}" \
  $'{fd}<<E pip i\nx\nE' "$(sp 8)pip i"$'\n'"$(sp 3)"
check_view unprefixed_view "${all}" "a redirection between the manager and its verb is blanked" \
  'pip 2>/dev/null i' "pip$(sp 13)i"
check_view unprefixed_view "${all}" "a process substitution target before the command goes" \
  '< <(true) pip i' 'pip i'
check_view unprefixed_view "bash dash" "a {varname} redirection before the command goes, after an assignment, exec and !" \
  'FOO=1 {fd}>/dev/null pip i; exec {fd}>&2 pip i; ! {fd}<&0 pip i' 'pip i; pip i; ! ;pip i'
check_view unprefixed_view "zsh" "zsh reads a { glued to the first word as a group opener, so there {fd} is no descriptor" \
  'FOO=1 {fd}>/dev/null pip i; exec {fd}>&2 pip i; ! {fd}<&0 pip i' 'pip i; pip i; ! {;fd}    pip i'
check_view unprefixed_view "${all}" "after echo the words stay arguments" \
  'echo {fd}>/dev/null pip i' "echo$(sp 16)pip i"
check_view live_view "${all}" "the live view blanks a redirection, so the inert rewrite finds the verb" \
  'npm 2>/dev/null install x' "npm$(sp 13)install x"
check_view live_view "${all}" "and keeps the body of a process substitution in its target, which runs" \
  'npm i > >(npm i x)' "npm i$(sp 5)npm i x "
# The flat view is the live view with every redirection blanked whole. The
# inert rewrite reads both: the live view keeps a body in a target, which
# stands between a command and its arguments there.
flat_view() { shell_lex "$1" flat "safedeps:scan-contract"; }
check_view live_view "${all}" "the live view keeps the body of a substitution in a target" \
  'npm >$(echo f) i x' "npm$(sp 3)(echo f) i x"
check_view flat_view "${all}" "the flat view blanks it with the redirection, so the verb follows the command" \
  'npm >$(echo f) i x' "npm$(sp 12)i x"
check_view flat_view "${all}" "and a process substitution in a target, body and all" \
  'npm i > >(npm i x)' "npm i$(sp 13)"
check_view flat_view "${all}" "a substitution that is no target stays, as in the live view" \
  'npm i "$(echo x)" >f' "npm i$(sp 4)echo x)$(sp 4)"
check_view substs_view "${all}" "a process substitution body is a payload, an argument or a target" \
  'cat <(pip i) > >(npm i)' $'pip i\035npm i\035'
check_view substs_view "${all}" "nested in a substitution, both bodies" \
  'cat <(echo $(pip i))' $'echo $(pip i)\035pip i\035'
for form in '>! f pip i' 'pip >! f i' 'echo a >>! f'; do
  f=$(mktemp "${TMPDIR:-/tmp}/safedeps-diverge.XXXXXX")
  SAFEDEPS_READING=bash SAFEDEPS_LEX_DIVERGE="${f}" noredir_view "${form}" > /dev/null
  [[ -s "${f}" ]] || fail "noredir view: the bash reading of [${form}] says no DIVERGE, and zsh reads the word after the blank as the target"
  rm -f "${f}"
done
for form in '>!f pip i' 'pip >/dev/null i' '{fd}>&2 pip i' '< <(true) pip i'; do
  f=$(mktemp "${TMPDIR:-/tmp}/safedeps-diverge.XXXXXX")
  SAFEDEPS_READING=bash SAFEDEPS_LEX_DIVERGE="${f}" noredir_view "${form}" > /dev/null
  [[ ! -s "${f}" ]] || fail "noredir view: the bash reading of [${form}] says DIVERGE, and every shell drops the same bytes"
  rm -f "${f}"
done
pass "redirections: a process substitution target is one word whose body is a payload, a {varname} or number glued in front is part of the operator, a heredoc's too, and the recognizers read them blanked wherever they stand"

# Whether the bash reading of a text says the shells read it differently
# (used here and for rule 5 of the starts below). The events view runs the
# lexing and the walk, and the recognize view the prefixes too, so between
# them they say DIVERGE where any of the three differs.
bash_diverges() { # text -> 0 when the bash reading says DIVERGE
  local f rc=1
  f=$(mktemp "${TMPDIR:-/tmp}/safedeps-diverge.XXXXXX")
  SAFEDEPS_READING=bash SAFEDEPS_LEX_DIVERGE="${f}" events_view "$1" > /dev/null
  SAFEDEPS_READING=bash SAFEDEPS_LEX_DIVERGE="${f}" recognize_view "$1" > /dev/null
  [[ -s "${f}" ]] && rc=0
  rm -f "${f}"
  return "${rc}"
}

# Where a word ends is one answer: the depth of the lexer walk. The shell's
# grammar puts parentheses inside words, and each is a context on the walk's
# stack, so every byte up to its close is nested and no reader keeps a byte
# set of its own:
#
#   - the value of an array assignment, `NAME=(...)`, `NAME+=(...)`, its
#     elements read as words anywhere are (comments, quotes, substitutions);
#   - zsh `=(...)` at the start of a word, whose body runs and is a payload;
#   - a process substitution, with the `<` or `>` that opens it;
#   - a glob group or qualifier glued to a word (zsh; bash 3.2 inside a
#     substitution), where the bash reading says DIVERGE: dash reads an
#     operator there;
#   - in the bash reading, the subscript of an assignment word, `NAME[...]=`:
#     bash pairs the brackets whatever they hold, zsh and dash end the word
#     at a blank inside, and the bash reading says DIVERGE at one.
#
# A case pattern close ends a word only at the top level: inside a
# substitution it is nested with the rest of the body. An assignment word is
# a name, a subscript and `=` or `+=`. The zsh precommand modifiers are
# prefixes and starts in the zsh reading alone. zsh reads `<N-M>` as a glob
# for a range of numbers, bytes of a word, where bash and dash read two
# redirections; the scan view prints its `<` and `>` as it prints an escaped
# operator.
#
# Each of these was read short by a reader with its own byte set, and the
# word after it was a command no recognizer read: `a=(x) pip install x` ran
# with `x)` in the command's place.
word_inner='b;c|d&e f'
word_inner_nested='b_c_d_e f'
check_word_nested() { # readings label prefix suffix
  local reading got inner
  for reading in $1; do
    got=$(SAFEDEPS_READING="${reading}" capture stmts_view "$3${word_inner}$4")
    inner="${got:${#3}:${#word_inner}}"
    [[ "${inner}" == "${word_inner_nested}" ]] || fail "word depth (${reading}): $2: the bytes inside [$3...$4] read as [${inner}], and every separator there is nested (expected [${word_inner_nested}])"
  done
}
check_word_nested "${all}" "an array value" 'a=(' ') pip i'
check_word_nested "${all}" "an array append" 'a+=(' ') pip i'
check_word_nested "${all}" "an array value after a subscript" 'a[1,2]=(' ') pip i'
check_word_nested "${all}" "an array value that is an argument" 'declare -a a=(' ')'
check_word_nested "${all}" "zsh =(...)" 'cat =(' ') x'
check_word_nested "${all}" "a process substitution" 'cat <(' ') x'
check_word_nested "${all}" "a process substitution that is a target" 'pip > >(' ') i'
check_word_nested "bash zsh" "a glob group glued to a word" 'ls x(' ')'
check_word_nested "bash zsh" "a glob group after a closing quote" "ls 'x'(" ')'
check_word_nested "bash zsh" "a glob group after an escaped byte" 'ls \)(' ')'
check_word_nested "bash zsh" "a glob group after a substitution" 'ls $(x)(' ')'
check_word_nested "bash" "a subscript in bash" 'a[' ']=x pip i'
# What is not a word parenthesis keeps its separators at the top level.
check_starts "${all}" "a subshell is no word" \
  '(b;c) | (d&e)' '(b;c) | (d&e)'
check_starts "dash" "dash has no glob group: the ( is an operator" \
  'ls x(b;c)' 'ls x(b;c)'
check_starts "zsh dash" "a blank inside a subscript ends the word outside bash" \
  'a[b;c]=x' 'a[b;c]=x'
check_starts "${all}" "a # among array elements opens a comment, and the value closes after it" \
  $'a=(x # c)\ny) pip i' "a=(x$(sp 6)y) pip i"
check_starts "bash zsh" "a # inside a glob group glued to a word is none" \
  'ls x(a #b) # c' "ls x(a #b)$(sp 4)"
check_starts "bash" "a # inside a bash subscript is none" \
  'a[1 #2]=x pip i' 'a[1 #2]=x pip i'
check_starts "${all}" "a case pattern close inside a substitution starts nothing" \
  'x=$(case a in a) b;; esac) pip i' 'x=$(case a in a) b__ esac) pip i'
check_starts "${all}" "and at the top level it still does" \
  'case a in a) pip i;; esac' 'case a in a) ;pip i;_ esac'
check_unprefixed "${all}" "an array value is a prefix, blanks and all" \
  'a=( x y ) b+=(z) pip i' 'pip i'
check_unprefixed "${all}" "an array value with a comment and a newline inside" \
  $'a=(x # c\ny) pip i' 'pip i'
check_unprefixed "${all}" "an append, an element and a nested subscript are assignments" \
  'a+=x b[1]=y c[d[1]]+=z e["]"]=w pip i' 'pip i'
check_unprefixed "bash" "a subscript with a blank is one word in bash" \
  'a[1 + 1]=x pip i' 'pip i'
check_unprefixed "zsh dash" "and the command, cut at the blank, in zsh and dash" \
  'a[1 + 1]=x pip i' 'a[1 + 1]=x pip i'
check_unprefixed "${all}" "a name with a subscript and no = assigns nothing" \
  'a[1] pip i' 'a[1] pip i'
check_unprefixed "${all}" "a value that holds a case runs on to the close of its substitution" \
  'x=$(case a in a) echo f;; esac) pip i' 'pip i'
check_unprefixed "${all}" "so does a target, and a target that is a process substitution" \
  '>$(case a in a) echo f;; esac) < <(case a in a) true;; esac) pip i' 'pip i'
check_unprefixed "${all}" "a target between a command and its arguments" \
  'pip >$(case a in a) echo f;; esac) i' "pip$(sp 32)i"
check_unprefixed "${all}" "zsh =(...) is one word, here a target" \
  '< =(true; true) pip i' 'pip i'
check_view substs_view "${all}" "and its body is a payload" \
  'cat =(pip i) > =(npm i)' $'pip i\035npm i\035'
check_unprefixed "bash zsh" "a glob qualifier glued to a target is part of it" \
  '>/dev/null(N) pip i' 'pip i'
check_unprefixed "dash" "to dash the ( after the target is an operator" \
  '>/dev/null(N) pip i' '(N) pip i'
check_unprefixed "bash zsh" "a group glued behind a ! or a reserved word's letters is part of the word" \
  'pip >f!(x) i; pip >f-do(.) i' "pip$(sp 8)i; pip$(sp 10)i"
check_unprefixed "zsh" "the zsh precommand modifiers go, in any order, after exec too" \
  'noglob pip i; - nocorrect pip i; builtin pip i; exec - pip i' ';pip i; ;;pip i; ;pip i; pip i'
check_unprefixed "bash dash" "and are commands outside zsh" \
  'noglob pip i; - nocorrect pip i; builtin pip i' 'noglob pip i; - nocorrect pip i; builtin pip i'
check_unprefixed "zsh" "a zsh numeric range glob is part of a target, of a value and of an argument" \
  '>f<1-2> pip i; X=<-> pip i; pip >f<1-> i' "pip i; pip i; pip$(sp 8)i"
check_unprefixed "bash dash" "and two redirections to bash and dash, the second with the next word as its target" \
  '>f<1-2> pip i' 'i'
check_view scan_view "zsh" "the scan view prints the range glob's < and > as characters" \
  'echo a<1-2>b <1-2 >c' 'echo a_1-2_b <1-2 >c'
for form in 'a[1 + 1]=x pip i' '>/dev/null(N) pip i' 'pip >f!(x) i' 'noglob pip i' '- pip i' "ls 'x'(N)" 'pip >f<1-2> i'; do
  bash_diverges "${form}" || fail "word depth: the bash reading of [${form}] says no DIVERGE, and the shells do not read that word the same way"
done
for form in 'a=(x y) pip i' 'a[1]=x pip i' 'a+=x pip i' 'x=$(case a in a) echo f;; esac) pip i' '< =(true) pip i' 'cat <(a; b)' 'ls file[0-9].txt' 'cat <1-2 >out'; do
  bash_diverges "${form}" && fail "word depth: the bash reading of [${form}] says DIVERGE, and every reading reads that word the same way"
done

# The walk checks its own answers (walks_fail in the lexer): a `(` the lexing
# left an operator where none of the bash reading's three walks has a
# command, and a word parenthesis inside the word the walks read as the
# command name, fail the reading. The mark is the one a failed scanner
# leaves, so the guard settles it as UNDECIDED for a command that names a
# package manager. The forms that must not fail are every place the shells
# do read a `(`: a subshell where a command stands, a function head and
# body, the zsh short forms, a case pattern, arithmetic, a glob word.
walk_fails() { # text -> 0 when the bash reading of the view marks the scan failed
  local f rc=1
  f=$(mktemp "${TMPDIR:-/tmp}/safedeps-walk.XXXXXX")
  SAFEDEPS_READING=bash SAFEDEPS_SCAN_MARK="${f}" "$1" "$2" > /dev/null
  [[ -s "${f}" ]] && rc=0
  rm -f "${f}"
  return "${rc}"
}
for form in 'pip ((x) y) i' 'echo a ((b) c)' 'X=1 ((a) b)' 'pip(N) i' 'x(a) pip i'; do
  for v in events_view unprefixed_view; do
    walk_fails "${v}" "${form}" || fail "walk check (${v}): the bash reading of [${form}] is not failed, and its walks have no command where that ( stands"
  done
done
for form in '(pip i)' 'a && (pip i)' '! (pip i)' 'time (pip i)' '{ (pip i) }' 'if (true) then pip i; fi' \
    'f() ( pip i )' 'f()(pip i)' 'function f ( pip i )' 'coproc foo ( pip i )' 'coproc (pip i)' \
    'for i (1) pip i' 'foreach i (1) pip i; end' 'for ((i=0;i<1;i++)) { pip i; }' 'if ((1)) { pip i; }' \
    'case x in (x) pip i;; esac' 'case x in x) (pip i);; esac' 'x=$( (a) (b) )' 'echo a (b)' 'ls *(N) x(N)' \
    '[[ a == (a|b) ]] && pip i' '[[ a =~ ^(a|b)$ ]] && pip i' 'declare -a a=(x y)' 'a=(x) pip i' \
    'cat <(a) >(b)' 'cat =(a)' 'f () { pip i; }' 'pip >f!(x) i' 'echo fix(scope): x' \
    'f( ) { pip i; }' 'f( )( pip i )' 'if(true)then(pip i)fi' 'if (true) then (pip i) fi' 'coproc(pip i)' \
    'function f { (pip i); }' 'for i do(pip i); done' 'rm !(keep) x' 'echo {(a)} b' '(a) (pip i)'; do
  for v in events_view unprefixed_view; do
    walk_fails "${v}" "${form}" && fail "walk check (${v}): the bash reading of [${form}] is failed, and a shell reads that ( where it stands"
  done
done
pass "words: every parenthesis the shell puts inside a word is nested in the walk, a case pattern close ends a word only at the top level, assignment words and zsh precommand modifiers are read as such, and the walk fails a reading whose ( it cannot place"

# The statement split (command_statements) reads the stmts view and keeps no
# rule of its own for `&>`. It used to keep an `&` next to `>` inside the
# statement in every reading, so in the dash reading of `echo a &>/dev/null
# npm install` the install was a word of `echo a`, and its landing was read
# from that statement.
statements_src=$(sed -n '/^command_statements() {/,/^}/p' "${GUARD}")
[[ "${statements_src}" == *"command_statements() {"* ]] || fail "command_statements not found in ${GUARD} (renamed? then update this battery)"
eval "${statements_src}"
check_statements() { # readings label input expected-count
  local got reading
  for reading in $1; do
    got=$(SAFEDEPS_READING="${reading}" command_statements "$3" | wc -l | tr -d ' ')
    [[ "${got}" == "$4" ]] || fail "statement split (${reading}): $2: ${got} statements, expected $4"
  done
}
check_statements "bash zsh" "&> splits no statement outside dash" \
  'echo a &>/dev/null pip i; pip i &>f' 2
check_statements "dash" "dash splits at the & of &>" \
  'echo a &>/dev/null pip i; pip i &>f' 4
check_statements "${all}" "a duplication splits no statement in any shell" \
  'echo a 2>&1 pip i; echo a >&2 pip i' 2
pass "statement split: &> ends a statement in the dash reading alone"

# The statement split reads the command as written, so it reads each
# statement's words from the stmtraw view of that one lexing: a heredoc body
# (the live code in one too), a comment and a heredoc operator are no words of
# any statement, and a line continuation joins the bytes around it. It read
# the joined view of the code view before, which kept the live code of a body:
# the statement after `cat <<E`, `$(date)`, `E` began with `$(date)`, and the
# landing read that as its command (verdict buri-20261005-145152).
check_statement_words() { # readings label input expected-words-of-each-statement-that-has-some
  local got reading
  for reading in $1; do
    got=$(SAFEDEPS_READING="${reading}" command_statements "$3" | cut -d $'\035' -f4 | { grep -v '^$' || true; } | tr '\037\n' ' |')
    [[ "${got}" == "$4" ]] || fail "statement words (${reading}): $2: [${got}] != expected [$4]"
  done
}
check_statement_words "${all}" "a heredoc body, its live code and a comment are no words" \
  $'cat <<E\n$(date) `date`\nE\nnpm install left-pad@1.3.0 # $(x) y\n' 'cat|npm install left-pad@1.3.0|'
check_statement_words "${all}" "a line continuation joins the bytes around it" \
  $'np\\\nm install left-pad@1.3.0 \\\n  --save-exact' 'npm install left-pad@1.3.0 --save-exact|'
pass "statement split: each statement's words leave out a heredoc body, its live code and a comment, and join a continuation"

# Rule 5's other half: a form whose starts differ between the readings makes
# the bash reading say DIVERGE, and a form every shell reads the same way does
# not. Without the first, the zsh reading that finds `repeat 1 { pip i; }` is
# never asked. zsh `case x {` is not here: the lexer reads a case that never
# closes in every reading, which writes no starts and is UNDECIDED.
for form in 'repeat 1 { pip i; }' 'for i (1) pip i' 'foreach i (1) pip i; end' 'if [[ 1 ]] pip i' \
    'while ((i++<1)) { pip i; }' '{ true; } always { pip i; }' 'coproc foo { pip i; }' \
    'case x in x) true;| x) pip i;; esac' 'case x in x) true;;& x) pip i;; esac' 'coproc foo if pip i; then :; fi' \
    'echo a &>/dev/null pip i' 'pip i &>/dev/null' 'echo $(echo a &>f pip i)' \
    'true&!pip i' '{2>/dev/null pip i; }' '{X=1 pip i; }' '{a[1]=x pip i; }' 'repeat 12>&1 pip i' \
    'if ((1))2>/dev/null pip i' 'echo 12>/dev/null pip i' 'exec -- noglob pip i' 'command - pip i'; do
  bash_diverges "${form}" || fail "starts: the bash reading of [${form}] says no DIVERGE, and the starts there are not the same in every shell"
done
for form in 'if true; then pip i; fi' 'f() { pip i; }; f' 'time -p pip i' 'function f g { pip i; }' \
    'case x in x) { pip i; };; esac' 'echo { pip i }; echo then pip i' 'FOO=1 pip i > out' \
    'function f if pip i; then :; fi' '{ 2>/dev/null pip i; }' \
    'echo a 2>&1 pip i' 'echo a >&/dev/null pip i' 'echo a \&>/dev/null pip i' 'echo "a &>f" pip i' \
    'if true; then>/dev/null pip i; fi' '!>/dev/null pip i' 'echo 1>/dev/null pip i' 'true & pip i'; do
  bash_diverges "${form}" && fail "starts: the bash reading of [${form}] says DIVERGE, and every shell reads its starts the same way"
done
pass "starts: the bash reading says DIVERGE where the shells start commands differently, and only there"

# What each shell ran, the rows rule 5 rests on: R when the shell printed RAN,
# - when it did not (a parse error, or the form is no form to it). Columns:
# macOS bash 3.2, macOS zsh 5.9, macOS dash, Linux bash 5.2, Linux dash.
# Measured on 2026-10-02 with `<shell> -c` (zsh -f); re-run with
# SAFEDEPS_STMTS_MEASURE=1, which compares the shells this machine has.
stmts_shell_rows=(
  'repeat 1 { echo RAN; }|-R---'
  'repeat 1 echo RAN|-R---'
  'for i (1) { echo RAN; }|-R---'
  'for i (1) echo RAN|-R---'
  'foreach i (1) echo RAN; end|-R---'
  'for ((i=0;i<1;i++)) { echo RAN; }|RR-R-'
  'while ((i++<1)) { echo RAN; }|-R---'
  'if ((1)) echo RAN|-R---'
  'if [[ 1 ]] echo RAN|-R---'
  '{ true; } always { echo RAN; }|-R---'
  '{ true } always { echo RAN }|-R---'
  'case x { x) echo RAN;; }|-R---'
  'case x in x) true;| x) echo RAN;; esac|-R---'
  'case x in x) true;;& x) echo RAN;; esac|---R-'
  'case x in x) true;& y) echo RAN;; esac|-R-R-'
  'coproc foo { echo RAN >&2; }; wait|---R-'
  'coproc echo RAN >&2; wait|-R-R-'
  'function f g { echo RAN; }; g|-R---'
  'function f { echo RAN; }; f|RR-R-'
  'f() echo RAN; f|-RR-R'
  'f g () { echo RAN; }; g|-R---'
  'time -p echo RAN 2>/dev/null|R-RR-'
  'function f if echo RAN; then :; fi; f|---R-'
  'function f while echo RAN; do break; done; f|---R-'
  'function f case x in x) echo RAN;; esac; f|---R-'
  'function f g if echo RAN; then :; fi; g|-----'
  'coproc foo if echo RAN >&2; then :; fi; wait|---R-'
  'coproc foo while echo RAN >&2; do break; done; wait|---R-'
  '2>/dev/null echo RAN|RRRRR'
  '{ 2>/dev/null echo RAN; }|RRRRR'
  'echo a &>/dev/null echo RAN >&2|--R-R'
  'echo a &>>/dev/null echo RAN >&2|--R-R'
  # The redirection reads (measured 2026-10-03): a process substitution
  # target is one word before the command (dash has none), `{fd}` opens a
  # descriptor in bash 5 alone where it comes first and in zsh after exec, and
  # a descriptor word glued to a heredoc is part of it everywhere.
  '< <(true) echo RAN|RR-R-'
  '> >(cat) echo RAN >&2|RR-R-'
  'cat <(echo RAN)|RR-R-'
  '{fd}>/dev/null echo RAN|---R-'
  'exec {fd}>/dev/null echo RAN|-R-R-'
  $'0<<E echo RAN\nx\nE|RRRRR'
  $'{fd}<<E echo RAN\nx\nE|---R-'
  # The word reads (measured 2026-10-03): an array value and a subscript are
  # prefixes where the shell has arrays, a blank in the subscript in bash
  # alone, a case pattern inside a substitution ends no value (bash 3.2 does
  # not parse it there), and zsh alone reads `=(...)`, a glob qualifier in a
  # target, a numeric range glob and a precommand modifier.
  'a=(x y) echo RAN|RR-R-'
  'a[1]=x echo RAN|RR-R-'
  'a[1 + 1]=x echo RAN|R--R-'
  'x=$(case a in a) echo f;; esac) echo RAN|-RRRR'
  '< =(true) echo RAN|-R---'
  '>/dev/null(N) echo RAN >&2|-R---'
  '2>/dev/fd/<2-2> echo RAN|-R---'
  'noglob echo RAN|-R---'
  # A subshell where a command stands (measured 2026-10-03): after a function
  # name list, after do and then, glued or not, and a function head with a
  # blank inside its parentheses.
  'function f { (echo RAN); }; f|RR-R-'
  'set -- a; for i do (echo RAN); done|RRRRR'
  'set -- a; for i do(echo RAN); done|R-RRR'
  'if (true) then (echo RAN) fi|RRRRR'
  'if(true)then(echo RAN)fi|R-RRR'
  'f( ) { echo RAN; }; f|R-RRR'
)
if [[ "${SAFEDEPS_STMTS_MEASURE:-}" == 1 ]]; then
  stmts_col() { case "$(uname -s)" in Darwin) printf '%s' "${1:0:3}" ;; *) printf '%s%s' "${1:3:1}" "${1:4:1}" ;; esac; }
  for row in "${stmts_shell_rows[@]}"; do
    form="${row%|*}" want=$(stmts_col "${row##*|}") got=""
    case "$(uname -s)" in Darwin) shells="bash zsh dash" ;; *) shells="bash dash" ;; esac
    for sh in ${shells}; do
      flag=""; [[ "${sh}" == zsh ]] && flag="-f"
      if perl -e 'alarm 3; exec @ARGV' "${sh}" ${flag} -c "${form}" < /dev/null 2>&1 | grep -qx RAN; then got+="R"; else got+="-"; fi
    done
    [[ "${got}" == "${want}" ]] || fail "stmts shell rows: [${form}] ran as ${got} here, recorded ${want}"
  done
  pass "stmts shell rows: ${#stmts_shell_rows[@]} forms ran here as recorded"
fi

# Rule 1's other half on random input, in each reading: where the stmts view
# differs from the scan view, the byte is a nested separator written as `_`
# (a nested newline as a blank), or the `&` of `&>` written as a blank. The
# view carries no start: it used to write each one over the byte before it (a
# blank, a case close, the `(` of a glued subshell, zsh's glued `{`, the
# escape or quote a glued word starts with), and each byte it could not write
# over was a start lost.
stmts_diffs=0
for reading in bash zsh dash; do
  RANDOM="${fuzz_seed}"
  for ((c = 0; c < fuzz_cases; c++)); do
    len=$((RANDOM % 40))
    input=""
    for ((k = 0; k < len; k++)); do
      input+="${heredoc_alphabet[RANDOM % ${#heredoc_alphabet[@]}]}"
    done
    sv=$(SAFEDEPS_READING="${reading}" capture scan_view "${input}"); tv=$(SAFEDEPS_READING="${reading}" capture stmts_view "${input}")
    LC_ALL=C
    for ((k = 0; k < ${#sv}; k++)); do
      a="${sv:k:1}" b="${tv:k:1}"
      [[ "${a}" == "${b}" ]] && continue
      if [[ "${b}" == "_" && "${a}" =~ [\;\&\|] ]] || [[ "${b}" == " " && "${a}" == $'\n' ]] \
          || [[ "${b}" == " " && "${a}" == "&" && "${sv:k+1:1}" == ">" ]]; then continue; fi
      printf 'stmts (%s) differs from scan at %d of [%q]: scan [%q] stmts [%q]\n' "${reading}" "${k}" "${input}" "${a}" "${b}" >&2
      stmts_diffs=$((stmts_diffs + 1))
    done
    unset LC_ALL
  done
done
[[ ${stmts_diffs} -eq 0 ]] || fail "stmts view: ${stmts_diffs} byte(s) differ from the scan view outside the stated rules (seed ${fuzz_seed})"
pass "stmts view: on ${fuzz_cases} random inputs in each reading it differs from the scan view only by nested separators"

# The random inputs above are mostly readings that do not close, and those are
# not asked for idempotence. These are drawn from the words the start walk
# reads -- reserved words, heads, short forms, redirections, arithmetic,
# assignments -- with no escape and no quote, so most readings close, and each
# that closes must read the same the second time, in its own reading.
grammar_words=('{' '}' '(' ')' '()' ';' '|' '&&' $'\n' '!' if then else fi do done for i in foreach end '(1)' \
  repeat 1 time -p '[[' ']]' '((i=0;i<1;i++))' '$((1;2))' '$(a; b)' coproc case x 'x)' ';;' ';|' ';;&' esac function f g \
  always '>' 'out' '2>&1' '<(a)' 'X=1' while true pip install)
grammar_closed=0
grammar_failures=0
for reading in bash zsh dash; do
  RANDOM="${fuzz_seed}"
  for ((c = 0; c < fuzz_cases; c++)); do
    len=$((RANDOM % 12 + 1))
    input=""
    for ((k = 0; k < len; k++)); do
      input+="${grammar_words[RANDOM % ${#grammar_words[@]}]}"
      (( RANDOM % 4 )) && input+=" "
    done
    SAFEDEPS_READING="${reading}" reading_closes "${input}" || continue
    grammar_closed=$((grammar_closed + 1))
    once=$(SAFEDEPS_READING="${reading}" stmts_view "${input}"; printf 'X'); once="${once%X}"
    twice=$(SAFEDEPS_READING="${reading}" stmts_view "${once}"; printf 'X'); twice="${twice%X}"
    if [[ "${once}" != "${twice}" || "$(byte_len "${once}")" != "$(byte_len "${input}")" ]]; then
      printf 'stmts (%s) on grammar words: [%q]\n  once  [%q]\n  twice [%q]\n' "${reading}" "${input}" "${once}" "${twice}" >&2
      grammar_failures=$((grammar_failures + 1))
    fi
  done
done
[[ ${grammar_failures} -eq 0 ]] || fail "stmts view: ${grammar_failures} of ${grammar_closed} closed readings of grammar words not idempotent (seed ${fuzz_seed})"
[[ ${grammar_closed} -gt $((fuzz_cases * 3 / 4)) ]] || fail "stmts view: only ${grammar_closed} of $((fuzz_cases * 3)) grammar-word readings closed, too few to say anything"
pass "stmts view: idempotent and length-preserving on ${grammar_closed} closed readings of $((fuzz_cases * 3)) random grammar-word inputs (bash, zsh, dash)"

# --- the event contract -----------------------------------------------------------
# What each reader of a start may rely on, checked on every event of a reading
# that closes, in each reading, on the recorded shell forms, the first places
# of the grid and random input (scripts/measure/first-place-grid.sh generates
# the places from the simple-command grammar):
#
#   E1. A start or a command word is an event at top-level code: depth 1, and
#       a byte of code, an escape or the quote a word opens with -- never a
#       byte inside quotes, a substitution, arithmetic or a heredoc.
#   E2. No start falls between a command's prefixes and its command word: the
#       prefixes of each start (the cwords view) run to a command word the
#       walk read, and no other start stands among them. Splitting
#       `npm_config_global=true npm install x` there dropped its UNGATED
#       record.
#   E3. The recognizers read the command word right after a separator: in
#       the recognize view the statement of each start, from its command word
#       on, follows one of `;` `&` `|` `(` or a newline, blanks between, or
#       begins the text. That is what SAFEDEPS_G_START anchors on.
#   E4. command_statements cuts there: a statement of its output begins with
#       the start's prefixes and command word, as the stmts view has them.
#       The statement split cuts the stmts view and keeps a line
#       continuation's bytes, which the recognize view of E3 drops.
event_failures=0
event_checked=0
event_inputs=0
event_flags=$(mktemp "${TMPDIR:-/tmp}/safedeps-event-flags.XXXXXX")
event_blanks=$' \t'
# Whether the offset <n> is in the space-separated list <list>.
in_list() { [[ " $1 " == *" $2 "* ]]; }
event_contract() { # input label
  local x="$1" reading ev cw rv stm line k w pre st sst first ok p head off rec slist="" wlist="" f1 f2 f3 f4 f6
  local LC_ALL=C
  event_inputs=$((event_inputs + 1))
  for reading in bash zsh dash; do
    : > "${event_flags}"
    ev=$(SAFEDEPS_READING="${reading}" SAFEDEPS_LEX_FLAGS="${event_flags}" events_view "${x}")
    ! grep -q '^UNTERM$' "${event_flags}" || continue
    cw=$(SAFEDEPS_READING="${reading}" shell_lex "${x}" cwords "safedeps:scan-contract")
    rv=$(SAFEDEPS_READING="${reading}" recognize_view "${x}"; printf 'X'); rv="${rv%X}"
    stm=$(SAFEDEPS_READING="${reading}" command_statements "${x}" | cut -d $'\035' -f2)
    slist=""; wlist=""
    while read -r f1 f2 f3 f4 _ f6; do
      [[ -n "${f1}" ]] || continue
      event_checked=$((event_checked + 1))
      if [[ "${f1}" == S ]]; then slist+=" ${f2}"; else wlist+=" ${f2}"; fi
      ok=1
      # An arithmetic command `((...))` is one word to the walk, which starts
      # at its second `(`; the lexing classes that byte with the first and
      # gives it no depth of its own.
      # A process substitution that stands as a word (`<(a)`) takes its `<`
      # or `>` into the nested depth of its body, as the lexing reads it.
      [[ "${f4}" == 1 || "${f4}" == 0 && "${x:f2-1:1}" == "(" && "${x:f2-2:1}" == "(" \
        || "${f4}" == 2 && "${x:f2-1:1}" == [\<\>] && "${x:f2:1}" == "(" ]] || ok=0
      case "${f3}" in
        c|x|l) ;;
        q) [[ "${x:f2-1:1}" == [\'\"\$] && ( "${f1}" == W || "${f6}" != q ) ]] || ok=0 ;;
        *) ok=0 ;;
      esac
      [[ ${ok} == 1 ]] || { printf 'E1 (%s): event [%s %s %s %s] of [%q] (%s) is not at top-level code\n' "${reading}" "${f1}" "${f2}" "${f3}" "${f4}" "${x}" "$2" >&2; event_failures=$((event_failures + 1)); }
    done <<< "${ev}"
    while IFS=$'\037' read -r k w pre st sst; do
      [[ -n "${k}" ]] || continue
      # A subshell that starts a command has no command word of its own: the
      # command inside it is the next start.
      if [[ "${x:k-1:1}" != "(" ]]; then
        ok=0
        for ((p = k; p <= w; p++)); do in_list "${wlist}" "${p}" && { ok=1; break; }; done
        for ((p = k + 1; p < w; p++)); do ! in_list "${slist}" "${p}" || ok=0; done
        [[ ${ok} == 1 ]] || { printf 'E2 (%s): the prefixes of the start at %s of [%q] (%s) reach no command word alone\n' "${reading}" "${k}" "${x}" "$2" >&2; event_failures=$((event_failures + 1)); }
      fi
      # After `;;`, `;&`, `;;&` or `;|` the walk reads the next word where an
      # arm or `esac` stands: no command, and the stmts view prints the
      # terminator's second byte as `_`. E3 and E4 are about commands.
      head="${x:0:k-1}"; head="${head%"${head##*[!${event_blanks}]}"}"
      [[ "${head}" != *";;" && "${head}" != *";&" && "${head}" != *";|" ]] || continue
      # A start right after a `(` is no cut of the statement split, which
      # does not cut at a `(` (the spec extractor blanks grouping bytes):
      # the command in a subshell, and the word of an arithmetic command,
      # which starts at the second `(` of its `((`.
      [[ "${head: -1}" != "(" ]] || continue
      # Each place the statement stands in the recognize view, until one
      # follows a separator or begins the text.
      ok=0; off=0
      while [[ "${rv:off}" == *"${st}"* ]]; do
        head="${rv:off}"; head="${head%%"${st}"*}"
        p=$((off + ${#head}))
        head="${rv:0:p}"; head="${head%"${head##*[!${event_blanks}]}"}"
        if [[ -z "${head}" || "${head: -1}" == [\;\&\|\(] || "${head: -1}" == $'\n' ]]; then ok=1; break; fi
        off=$((p + 1))
      done
      [[ ${ok} == 1 ]] || { printf 'E3 (%s): the statement [%q] of the start at %s of [%q] (%s) follows no separator in the recognize view [%q]\n' "${reading}" "${st}" "${k}" "${x}" "$2" "${rv}" >&2; event_failures=$((event_failures + 1)); }
      first="${sst%%[${event_blanks}]*}"
      ok=0
      while IFS= read -r rec; do
        rec="${rec#"${rec%%[!${event_blanks}]*}"}"
        [[ "${rec}" == "${pre}${first}"* ]] && { ok=1; break; }
      done <<< "${stm}"
      [[ ${ok} == 1 ]] || { printf 'E4 (%s): no statement of [%q] (%s) begins with [%q]\n' "${reading}" "${x}" "$2" "${pre}${first}" >&2; event_failures=$((event_failures + 1)); }
    done <<< "${cw}"
  done
}
for ((i = 0; i < form_count; i++)); do
  form=$(jq -j ".[${i}].text" "${forms_file}" | sed -e 's/@@TAIL@@/pip install evil==6.6.6/' -e 's/@@HEAD@@/pip/g' -e 's/@@TAIL_SPLIT@@/pi\\\
p install evil==6.6.6/'; printf 'X')
  event_contract "${form%X}" "$(jq -r ".[${i}].id" "${forms_file}")"
done
# Every twentieth first-place form of the grid's generator (pip), so each first
# place stands in a spread of productions.
first_place_forms=$(bash "${ROOT_DIR}/scripts/measure/first-place-grid.sh" generate pip | awk 'NR % 20 == 1')
first_place_count=0
while IFS= read -r line; do
  form=$(jq -j .text <<< "${line}" | sed 's/@@HEAD@@/pip/g'; printf 'X')
  event_contract "${form%X}" "$(jq -r .id <<< "${line}")"
  first_place_count=$((first_place_count + 1))
done <<< "${first_place_forms}"
RANDOM="${fuzz_seed}"
event_cases=$((fuzz_cases / 4))
for ((c = 0; c < event_cases; c++)); do
  len=$((RANDOM % 40))
  input=""
  for ((k = 0; k < len; k++)); do
    input+="${heredoc_alphabet[RANDOM % ${#heredoc_alphabet[@]}]}"
  done
  event_contract "${input}" "random ${c}"
  len=$((RANDOM % 12 + 1))
  input=""
  for ((k = 0; k < len; k++)); do
    input+="${grammar_words[RANDOM % ${#grammar_words[@]}]}"
    (( RANDOM % 4 )) && input+=" "
  done
  event_contract "${input}" "grammar ${c}"
done
rm -f "${event_flags}"
[[ ${event_failures} -eq 0 ]] || fail "event contract: ${event_failures} violation(s) (seed ${fuzz_seed})"
[[ ${event_checked} -gt 1000 ]] || fail "event contract: only ${event_checked} events checked, too few to say anything"
pass "event contract: ${event_checked} events of ${event_inputs} inputs (${form_count} shell forms, ${first_place_count} first-place forms, $((event_cases * 2)) random), in bash, zsh and dash: each at top-level code, none between a command's prefixes and its word, each command word after a separator to the recognizers and at a cut of command_statements"

# --- where a word ends (SAFEDEPS_G_END) ------------------------------------------
# The recognizers end a manager and a verb with SAFEDEPS_G_END, read on the
# stmts view. That is the lexer's answer only if the view prints every byte
# where the lexer ends a word as one of the bytes SAFEDEPS_G_END reads as a
# word end. The wordends view is the lexer's own answer, as a mask over the
# same bytes, so each recorded shell form, the grammar words and random input
# are held to it in every reading. The tails used to be `([[:space:]]|$)`, a
# set of the recognizers' own: `npm ci;`, `(npm install)` and `then npm ci;
# fi` were no install to any of them.
wordends_view() { shell_lex "$1" wordends "safedeps:scan-contract"; }
word_end_failures=0
word_end_checked=0
check_word_ends() { # input label
  local x="$1" reading mask tv k b v LC_ALL=C
  for reading in bash zsh dash; do
    mask=$(SAFEDEPS_READING="${reading}" wordends_view "${x}"; printf 'X'); mask="${mask%X}"
    if [[ ${#mask} -ne ${#x} ]]; then
      printf 'wordends (%s) changed the length of [%q] (%s)\n' "${reading}" "${x}" "$2" >&2
      word_end_failures=$((word_end_failures + 1))
      continue
    fi
    # The recognizers read the stmts view; the inert rewrite finds its verbs
    # with the same tail on the live and flat views.
    for v in stmts live flat; do
      tv=$(SAFEDEPS_READING="${reading}" shell_lex "${x}" "${v}" "safedeps:scan-contract"; printf 'X'); tv="${tv%X}"
      for ((k = 0; k < ${#mask}; k++)); do
        [[ "${mask:k:1}" == 1 ]] || continue
        word_end_checked=$((word_end_checked + 1))
        b="${tv:k:1}"
        [[ "${b}" =~ ^${SAFEDEPS_G_WORD_END_CLASS}$ ]] && continue
        printf 'word end (%s) at %d of [%q] (%s) is [%q] in the %s view\n' "${reading}" "${k}" "${x}" "$2" "${b}" "${v}" >&2
        word_end_failures=$((word_end_failures + 1))
      done
    done
  done
}
for ((i = 0; i < form_count; i++)); do
  form=$(jq -j ".[${i}].text" "${forms_file}" | sed -e 's/@@TAIL@@/pip install evil==6.6.6/' -e 's/@@HEAD@@/pip/g' -e 's/@@TAIL_SPLIT@@/pi\\\
p install evil==6.6.6/'; printf 'X')
  check_word_ends "${form%X}" "$(jq -r ".[${i}].id" "${forms_file}")"
done
for form in 'npm ci;' '(npm install)' 'if true; then npm ci; fi' 'npm ci&>log' 'npm ci&&echo' 'npm ci|cat' \
  'npm ci&' "npm 'ci';" 'x)npm ci;;' 'npm ci 2>&1' 'case x in x) npm ci;; esac' 'npm ci<<E
x
E'; do
  check_word_ends "${form}" "row"
done
RANDOM="${fuzz_seed}"
for ((c = 0; c < fuzz_cases; c++)); do
  len=$((RANDOM % 40))
  input=""
  for ((k = 0; k < len; k++)); do
    input+="${heredoc_alphabet[RANDOM % ${#heredoc_alphabet[@]}]}"
  done
  check_word_ends "${input}" "random ${c}"
  len=$((RANDOM % 12 + 1))
  input=""
  for ((k = 0; k < len; k++)); do
    input+="${grammar_words[RANDOM % ${#grammar_words[@]}]}"
    (( RANDOM % 4 )) && input+=" "
  done
  check_word_ends "${input}" "grammar ${c}"
done
[[ ${word_end_failures} -eq 0 ]] || fail "word ends: ${word_end_failures} byte(s) where the lexer ends a word print as a byte SAFEDEPS_G_END does not read as one (seed ${fuzz_seed})"
[[ ${word_end_checked} -gt 1000 ]] || fail "word ends: only ${word_end_checked} word ends checked, too few to say anything"
for got in "npm ci;" "(npm install)" "npm ci&>log"; do
  SAFEDEPS_READING=bash stmts_view "${got}" | grep -qE "${SAFEDEPS_G_NPM_INSTALL_RE}" \
    || fail "word ends: the npm recognizer reads [${got}] as an install"
done
pass "word ends: every byte where the lexer ends a word prints as a word end SAFEDEPS_G_END reads in the stmts, live and flat views, on ${word_end_checked} word ends of the shell forms, rows, $((fuzz_cases * 2)) random inputs, in bash, zsh and dash"

# --- one list of executables and one of shells ------------------------------------
# A word is a manager or a shell by one list each in the grammar. The other
# places that name managers -- the install body, the ecosystem of a
# statement, the pipe check's install text -- must agree with it on every
# spelling, or a path the lexer reads as a manager is one no recognizer reads
# (or the other way round).
guard_src_lists=$(sed -n '/^PIPE_MANAGER_RE=/p' "${GUARD}")
eval "${guard_src_lists}"
[[ -n "${PIPE_MANAGER_RE:-}" ]] || fail "PIPE_MANAGER_RE not found in ${GUARD}"
for name in npm npx pnpm pnpx yarn bun bunx pip pip3 pip3.11 poetry uv uvx pipx pipenv cargo go gem bundle mvn dotnet PIP Npm; do
  [[ "$(tr '[:upper:]' '[:lower:]' <<< "${name}")" =~ ^(${SAFEDEPS_G_EXECUTABLES})$ ]] \
    || fail "${name} is an executable of the grammar"
  grep -qiE "^${PIPE_MANAGER_RE}\$" <<< "${name}" || fail "${name} is a manager to the pipe check too"
  grep -qiE "(^|[^[:alnum:]])${name}([^[:alnum:]]|\$)" <<< "${SAFEDEPS_G_INSTALL_BODY//\\/}" \
    || [[ "${name}" == pip3* || "${name}" == PIP || "${name}" == Npm ]] || fail "${name} has an install body"
done
for name in npm.cmd pipx-foo pips gox; do
  [[ ! "${name}" =~ ^(${SAFEDEPS_G_EXECUTABLES})$ ]] || fail "${name} is no executable of the grammar"
done
for name in sh bash dash ksh mksh yash posh zsh csh tcsh fish; do
  [[ "${name}" =~ ^(${SAFEDEPS_G_SHELLS})$ ]] || fail "${name} is a shell of the grammar"
done
for name in ssh sshd bash5 shx; do
  [[ ! "${name}" =~ ^(${SAFEDEPS_G_SHELLS})$ ]] || fail "${name} is no shell of the grammar"
done
pass "one list of executables, matched whole and ignoring case, and one closed list of shells"

# --- the words the spec extractor reads -----------------------------------------
# The pieces view hands the extractor each statement's words: redirections out,
# the shell's quote removal applied. Each form in word-reading-forms.json
# carries the argv bash and zsh actually handed to a stand-in for the manager
# (scripts/measure/word-reading-measure.sh re-measures them), and the words the
# view reads must be that argv, for each shell that ran the form. A reader
# with its own model of the quoting disagreed here: it took the `>` inside
# "x>'" for a redirection and dropped the pinned spec after it.
#
# Inside a word, a byte the extractor would cut at -- a blank or a grouping
# character -- is \002, and the empty word is \002 alone, so each word stays
# one token. The argv is mapped the same way before the comparison, so the
# check holds the word boundaries and every other byte; a blanked \002 here
# could not tell `"a b"` from `a b`, which is the defect it is meant to catch.
#
# The boundary, stated so it is not mistaken for coverage: a substitution is
# kept as written, since its value is not known before it runs. No form here
# has one.
words_view_of() { # text -> the words field of its first piece, one per line
  local line
  line=$(shell_lex "$1" pieces "safedeps:scan-contract" | head -n1)
  line="${line#*$'\037'}"; line="${line#*$'\037'}"
  set -f
  # shellcheck disable=SC2086
  printf '%s\n' ${line}
  set +f
}
words_forms="${ROOT_DIR}/scripts/measure/word-reading-forms.json"
words_count=$(jq length "${words_forms}")
words_checked=0
for ((i = 0; i < words_count; i++)); do
  id=$(jq -r ".[${i}].id" "${words_forms}")
  text=$(jq -j ".[${i}].text" "${words_forms}" | sed 's/@@M@@/pip/'; printf 'X'); text="${text%X}"
  got=$(words_view_of "${text}" | sed 1d | jq -Rsc 'split("\n") | .[:-1]')
  ran=0
  for shell in bash zsh; do
    want=$(jq -c ".[${i}].argv.${shell}" "${words_forms}")
    [[ "${want}" != "[]" ]] || continue
    want=$(jq -c 'map(gsub("[ \t\n(){}\u001e\u001f]"; "\u0002") | if . == "" then "\u0002" else . end)' <<< "${want}")
    ran=$((ran + 1))
    [[ "${got}" == "${want}" ]] || fail "words: ${id} reads ${got}; ${shell} handed the manager ${want}"
  done
  [[ ${ran} -gt 0 ]] || fail "words: ${id} ran under no shell, so it checks nothing (re-measure it)"
  words_checked=$((words_checked + 1))
done
pass "words: the pieces view reads the argv bash and zsh hand the manager on ${words_checked} recorded forms"

# --- the lexer memo -------------------------------------------------------------
# Above 4KB a view is reused within one guard run. Its key is a checksum, which
# the author of a command can collide on purpose, so a hit must also match the
# stored text byte for byte. And the memo directory is made by the guard: one
# named in the environment would be a place to plant a view for a command.
memo_dir=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-memo-test.XXXXXX")
big_install="pip install evil==6.6.6; echo '$(printf 'x%.0s' $(seq 1 5000))'"
memo_key="${memo_dir}/scan.bash.$(printf '%s' "${big_install}" | cksum | tr ' ' '.')"
printf 'PLANTED' > "${memo_key}.out"; printf 'some other text' > "${memo_key}.in"
got=$(SAFEDEPS_LEX_CACHE="${memo_dir}" shell_lex "${big_install}" scan "safedeps:scan-contract"; printf 'X'); got="${got%X}"
[[ "${got}" != "PLANTED" && "${got}" == "pip install evil==6.6.6;"* ]] \
  || fail "a memo entry under the right key but for other text is not returned"
printf 'PLANTED' > "${memo_key}.out"; printf '%s' "${big_install}" > "${memo_key}.in"
got=$(SAFEDEPS_LEX_CACHE="${memo_dir}" shell_lex "${big_install}" scan "safedeps:scan-contract"; printf 'X'); got="${got%X}"
[[ "${got}" == "PLANTED" ]] || fail "an exact-text memo entry is returned, so the memo is in use"
# A hit still reports DIVERGE: the guard reads only bash when nothing says the
# readings differ, so a memo that dropped the flag would drop zsh and dash.
diverging="((1' ))"$'\n'"pip install evil==6.6.6"$'\n'"# $(printf 'x%.0s' $(seq 1 5000)) ' ))"
memo_diverge=$(mktemp "${TMPDIR:-/tmp}/safedeps-memo-div.XXXXXX")
SAFEDEPS_LEX_CACHE="${memo_dir}" SAFEDEPS_LEX_DIVERGE="${memo_diverge}" shell_lex "${diverging}" scan "safedeps:scan-contract" > /dev/null
[[ -s "${memo_diverge}" ]] || fail "a diverging text says DIVERGE when it fills the memo"
: > "${memo_diverge}"
SAFEDEPS_LEX_CACHE="${memo_dir}" SAFEDEPS_LEX_DIVERGE="${memo_diverge}" shell_lex "${diverging}" scan "safedeps:scan-contract" > /dev/null
[[ -s "${memo_diverge}" ]] || fail "a memo hit on a diverging text still says DIVERGE"
rm -f "${memo_diverge}"
# The guard ignores a memo directory from the environment. Plant a blank view
# for every view of the command; the install must still be judged.
for v in scan code recognize pieces stmtcuts stmtraw cscripts substs; do
  for pol in bash zsh dash; do
    k="${memo_dir}/${v}.${pol}.$(printf '%s' "${big_install}" | cksum | tr ' ' '.')"
    printf '%*s' "${#big_install}" '' > "${k}.out"; printf '%s' "${big_install}" > "${k}.in"
  done
done
planted_home=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-memo-home.XXXXXX")
planted_out=$(jq -nc --arg c "${big_install}" --arg cwd "${planted_home}" '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}' |
  SAFEDEPS_LEX_CACHE="${memo_dir}" HOME="${planted_home}" SAFEDEPS_HOME="${planted_home}/safe" scripts/safedeps-hook-entry.sh pre 2>/dev/null)
[[ "$(jq -r '.hookSpecificOutput.permissionDecision // "pass"' <<< "${planted_out:-{\}}")" == "deny" ]] \
  || fail "a memo directory planted through the environment does not hide an install"
rm -rf "${memo_dir}" "${planted_home}"
pass "the lexer memo returns a view only for the exact text, and only from the guard's own directory"

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

# Runs the guard through the entry shim, the way the engines do. An optional
# third argument, `<ecosystem> <name> <version>`, is approved first.
scanfail_guard() {
  local bin="$1" command="$2" approve="${3:-}" home
  home=$(mktemp -d "${fail_tmp}/home.XXXXXX")
  if [[ -n "${approve}" ]]; then
    # shellcheck disable=SC2086 # three words on purpose
    ( export SAFEDEPS_HOME="${home}/safe"
      . lib/ledger/ledger.sh
      safedeps_ledger_write_approved_spec ${approve} >/dev/null ) \
      || fail "the scan-failure fixture approval could be written: ${approve}"
  fi
  SCANFAIL_OUT=$(jq -nc --arg c "${command}" --arg cwd "${fail_tmp}/project" \
    '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}' |
    PATH="${bin:+${bin}:}${PATH}" HOME="${home}" SAFEDEPS_HOME="${home}/safe" \
    scripts/safedeps-hook-entry.sh pre 2>"${home}/stderr") || fail "the hook exited non-zero for: ${command}"
  SCANFAIL_HOME="${home}"
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

# grep and sed sit on the judgment path too. A predicate that reads a grep or
# sed that never answered as "no match" passed every one of these on the tree
# before this check existed. They are recorded like a failed awk reading and
# settled at the same gate.
mkdir -p "${fail_tmp}/grep-all" "${fail_tmp}/sed-all"
printf '#!/usr/bin/env bash\nexit 2\n' > "${fail_tmp}/grep-all/grep"
printf '#!/usr/bin/env bash\nexit 2\n' > "${fail_tmp}/sed-all/sed"
chmod +x "${fail_tmp}/grep-all/grep" "${fail_tmp}/sed-all/sed"
for tool in grep sed; do
  for failing_command in "pip install requests==2.0.0" "npm install left-pad@1.3.0" "cargo add serde@1.0.0"; do
    scanfail_guard "${fail_tmp}/${tool}-all" "${failing_command}"
    [[ "${SCANFAIL_DECISION}" == "deny" ]] \
      || fail "a failed ${tool} does not turn an install into a pass: ${failing_command} (got: ${SCANFAIL_DECISION})"
    grep -q 'UNDECIDED' <<< "${SCANFAIL_REASON}" \
      || fail "a failed ${tool} is reported as undecided: ${failing_command}"
  done
  scanfail_guard "${fail_tmp}/${tool}-all" "ls -la"
  [[ "${SCANFAIL_DECISION}" == "pass" ]] || fail "a failed ${tool} does not block a command that names no package manager (got: ${SCANFAIL_DECISION})"
done
pass "a failed grep or sed on the judgment path denies install-looking commands as UNDECIDED"

# One judgment grep failing alone. grep-all cannot show these: the first grep a
# command reaches marks its failure, and that mark covers every later grep. The
# census fails each grep call alone (grep-k), but only in its full run, which
# npm test does not pay for, so the two sites the census found that way are
# held here. The shim fails the J-th call whose first two arguments are the
# site's, and only that call; a counting run first finds how many such calls a
# command makes, so every one of them fails alone and none is left out.
mkdir -p "${fail_tmp}/grep-one"
real_grep=$(command -v grep)
cat > "${fail_tmp}/grep-one/grep" <<SHIM
#!/usr/bin/env bash
if [[ "\$1" == "\${GREP_ONE_A1}" && "\$2" == "\${GREP_ONE_A2}" ]]; then
  printf 'x\n' >> "\${GREP_ONE_TALLY}"
  n=0
  while IFS= read -r _; do n=\$(( n + 1 )); done < "\${GREP_ONE_TALLY}"
  [[ "\${n}" != "\${GREP_ONE_AT}" ]] || exit 2
fi
exec '${real_grep}' "\$@"
SHIM
chmod +x "${fail_tmp}/grep-one/grep"

# Fails the J-th call of the site <a1> <a2> alone, for every J the command
# reaches, and hands each run to <check>. A site the command never reaches is a
# failure of this battery, not a pass.
grep_one_each() {
  local a1="$1" a2="$2" command="$3" approve="$4" check="$5" calls at
  export GREP_ONE_A1="${a1}" GREP_ONE_A2="${a2}" GREP_ONE_TALLY="${fail_tmp}/grep-one/tally"
  rm -f "${GREP_ONE_TALLY}"
  GREP_ONE_AT=0 scanfail_guard "${fail_tmp}/grep-one" "${command}" "${approve}"
  calls=0
  [[ ! -f "${GREP_ONE_TALLY}" ]] || calls=$(wc -l < "${GREP_ONE_TALLY}" | tr -d ' ')
  (( calls > 0 )) || fail "the command reaches the grep site ${a1} ${a2:0:40} (otherwise this case tests nothing): ${command}"
  for (( at = 1; at <= calls; at++ )); do
    rm -f "${GREP_ONE_TALLY}"
    GREP_ONE_AT="${at}" scanfail_guard "${fail_tmp}/grep-one" "${command}" "${approve}"
    "${check}" "${at}/${calls}"
  done
  unset GREP_ONE_A1 GREP_ONE_A2 GREP_ONE_TALLY
}

# (a) The grep that reads the lexer's UNTERM flag. A failure there read as "the
# command closes", and the line the open quote swallowed went unread: this
# command went from an UNDECIDED deny to a pass (0240b78).
open_quote=$'echo "a\npip install evil==6.6.6'
check_open_quote() {
  [[ "${SCANFAIL_DECISION}" == "deny" ]] \
    || fail "the UNTERM grep failing alone (call $1) does not let an open quote through (got: ${SCANFAIL_DECISION})"
  grep -q 'UNDECIDED' <<< "${SCANFAIL_REASON}" || fail "the UNTERM grep failing alone (call $1) answers UNDECIDED"
  grep -q 'scanner failed' <<< "${SCANFAIL_LOG}" || fail "the UNTERM grep failing alone (call $1) is recorded in advisory.log"
}
grep_one_each -q '^UNTERM$' "${open_quote}" "" check_open_quote
pass "the UNTERM flag grep failing alone, at each of its calls, leaves an open quote over an install UNDECIDED"

# (b) The grep in guard_command_has_npm_install. A failure there counted as a
# match, which is the safe answer, but nothing recorded it, so an approved `pip
# install` was allowed with an npm trace baseline in its pending state and
# nothing said (0240b78). The other calls of the same pattern go through
# judge_grep and are failed here too.
npm_install_re=$(bash -c '. lib/install-grammar.sh && printf "%s" "${SAFEDEPS_G_NPM_INSTALL_RE}"')
[[ -n "${npm_install_re}" ]] || fail "SAFEDEPS_G_NPM_INSTALL_RE could be read from lib/install-grammar.sh"
pending_npm_traces() {
  local f found=0
  for f in "$1"/pending/*.json; do
    [[ -f "${f}" ]] || continue
    [[ "$(jq -r '.npm_trace | type' "${f}")" == "null" ]] || found=$(( found + 1 ))
  done
  printf '%s' "${found}"
}
scanfail_guard "" "pip install requests==2.0.0" "pypi requests 2.0.0"
[[ "${SCANFAIL_DECISION}" != "deny" ]] || fail "control: an approved pip install is not denied (got: ${SCANFAIL_DECISION})"
ls "${SCANFAIL_HOME}"/safe/pending/*.json > /dev/null 2>&1 || fail "control: an allowed pip install writes pending state"
[[ "$(pending_npm_traces "${SCANFAIL_HOME}/safe")" == "0" ]] || fail "control: an allowed pip install has no npm trace baseline"
check_pip_trace() {
  [[ "$(pending_npm_traces "${SCANFAIL_HOME}/safe")" == "0" ]] \
    || fail "the npm-install grep failing alone (call $1) writes no npm trace baseline into a pip install's pending state"
  [[ "${SCANFAIL_DECISION}" == "deny" ]] && grep -q 'UNDECIDED' <<< "${SCANFAIL_REASON}" \
    || fail "the npm-install grep failing alone (call $1) answers UNDECIDED (got: ${SCANFAIL_DECISION})"
  grep -q 'scanner failed' <<< "${SCANFAIL_LOG}" || fail "the npm-install grep failing alone (call $1) is recorded in advisory.log"
}
grep_one_each -qEi "${npm_install_re}" "pip install requests==2.0.0" "pypi requests 2.0.0" check_pip_trace
pass "the npm-install grep failing alone, at each of its calls, is recorded and leaves no npm trace in a pip install's pending state"

scanfail_guard "${fail_tmp}/all-awk" "pip install requests==2.0.0"
[[ "${SCANFAIL_DECISION}" == "deny" ]] || fail "with awk failing everywhere an install is still denied (got: ${SCANFAIL_DECISION})"
pass "with awk failing everywhere an install is still denied"

# --- every lexing reads the command or a payload ----------------------------------
# A reader lexes the command as written, or a payload (a script it hands to
# `sh -c` or `eval`, the body of a substitution), or a piece of one cut at
# offsets (a statement, the inert reading's statement with the flag put in);
# never the output of a view. A view changes bytes, and a text a view changed
# reads out of the context the first lexing had. The recognizers, the landing,
# the extractor and the inert reading each lexed the joined view again, which
# blanked a heredoc body and its terminator line but kept the live code in an
# unquoted one: `$(date)` then stood where the command after the body did, and
# the install there passed with no verdict (verdict buri-20261005-145152). The
# comment over that reader said "Each text is lexed once", and a review that
# read the comment instead of the call chain passed it.
#
# So the call chain is measured. An awk shim records every lexing a guard run
# makes (shell_lex is the one awk called with a view and a policy): the view,
# the text, and for the payload views (cscripts, substs) the payloads they
# hand back. Each text lexed must then be a substring of the command or of a
# payload, after taking out at most one ` --ignore-scripts` the inert reading
# put in. A view's output is such a substring only where the view changed no
# byte, and then lexing it is lexing the command. The forms reach every reader
# that lexes (the views must all show up in the trace, or this checks nothing),
# with the bytes a view used to change: a heredoc with live code, a line
# continuation, a comment, a newline inside quotes, prefixes, payloads that
# hold newlines, and installs the landing and the inert rewrite read. The
# inert rewrite runs only for an install the gate lets through, so its forms
# are `npm ci`, which names no package, with quotes and a comment in it.
mkdir -p "${fail_tmp}/lex-trace-bin"
cat > "${fail_tmp}/lex-trace-bin/awk" <<SHIM
#!/usr/bin/env bash
view=""; marker=""; prev=""
for a in "\$@"; do
  [[ "\${prev}" == -v && "\${a}" == view=* ]] && view="\${a#view=}"
  [[ "\${prev}" == -v && "\${a}" == marker=* ]] && marker="\${a#marker=}"
  prev="\${a}"
done
case " \$* " in *" policy="*) ;; *) view="" ;; esac
[[ -n "\${view}" && -n "\${LEX_TRACE:-}" ]] || exec '${real_awk}' "\$@"
f=\$(mktemp "\${LEX_TRACE}/lex.XXXXXX") || exit 2
printf '%s' "\${view}" > "\${f}.view"
printf '%s' "\${marker}" > "\${f}.marker"
cat > "\${f}.in"
case "\${view}" in
  cscripts|substs)
    '${real_awk}' "\$@" < "\${f}.in" > "\${f}.out"; rc=\$?
    cat "\${f}.out"
    exit "\${rc}"
    ;;
esac
exec '${real_awk}' "\$@" < "\${f}.in"
SHIM
chmod +x "${fail_tmp}/lex-trace-bin/awk"

# Whether <text> is a substring of one of the allowed texts (LEX_ALLOWED), as
# it is or with one ` --ignore-scripts` taken out.
lex_text_allowed() {
  local text="$1" a rest head pre="" cand
  for a in "${LEX_ALLOWED[@]}"; do [[ "${a}" == *"${text}"* ]] && return 0; done
  rest="${text}"
  while [[ "${rest}" == *" --ignore-scripts"* ]]; do
    head="${rest%%" --ignore-scripts"*}"
    rest="${rest#*" --ignore-scripts"}"
    cand="${pre}${head}${rest}"
    for a in "${LEX_ALLOWED[@]}"; do [[ "${a}" == *"${cand}"* ]] && return 0; done
    pre="${pre}${head} --ignore-scripts"
  done
  return 1
}

# Runs the guard on <command> under the trace and checks every lexing it made.
# Adds the views and the readers (their markers) it saw to LEX_VIEWS_SEEN; each
# lexing of a text that is not
# the command, a payload or a piece of one is a line in LEX_BAD.
lex_trace_check() {
  local command="$1" trace f view out rec text
  trace=$(mktemp -d "${fail_tmp}/lex-trace.XXXXXX")
  LEX_TRACE="${trace}" scanfail_guard "${fail_tmp}/lex-trace-bin" "${command}"
  LEX_ALLOWED=("${command}")
  for f in "${trace}"/lex.*.out; do
    [[ -f "${f}" ]] || continue
    view=$(cat "${f%.out}.view")
    out=$(cat "${f}"; printf 'X'); out="${out%X}"
    while IFS= read -r -d $'\035' rec; do
      [[ "${view}" != cscripts ]] || rec="${rec:1}"
      [[ -z "${rec}" ]] || LEX_ALLOWED+=("${rec}")
    done <<< "${out}"
  done
  for f in "${trace}"/lex.*.in; do
    [[ -f "${f}" ]] || continue
    view=$(cat "${f%.in}.view")
    LEX_VIEWS_SEEN+=" ${view} $(cat "${f%.in}.marker") "
    # shell_lex hands the awk the text and a newline.
    text=$(cat "${f}"; printf 'X'); text="${text%X}"; text="${text%$'\n'}"
    lex_text_allowed "${text}" || LEX_BAD+="${view} of [${text}] in [${command}]"$'\n'
  done
  rm -rf "${trace}"
}
LEX_VIEWS_SEEN="" LEX_BAD=""
lex_forms=(
  $'cat <<E\n$(date)\nE\npip install evil==6.6.6\n'
  $'git commit -F - <<EOF\nfix $(date)\nEOF\nnpm ci\n'
  $'cat <<-E\n\t${HOME} `date`\n\tE\nnpm install left-pad@1.3.0 # a comment\n'
  $'pi\\\np install evil==6.6.6'
  $'npm install left-pad@1.3.0 --message "a\nb" \\\n  --save-exact'
  $'npm ci --message "a\nb" \\\n  --loglevel warn 2>/dev/null'
  "npm ci --tag 'a b' # a comment"
  $'cat <<E\n$(date)\nE\nnpm ci --tag "$(echo x)"\n'
  'FOO="a b" PIP_INDEX_URL=x pip install evil==6.6.6 2>/dev/null'
  $'sh -c "echo a\npip install evil==6.6.6"; eval \'npm ci\''
  $'x=$(echo a\nnpm install left-pad@1.3.0); echo "$x"'
  'cd sub && npm install left-pad@1.3.0 && npm install cowsay@1.5.0'
  $'case x in x) npm ci;; esac; if true; then pip install evil==6.6.6; fi'
  $'cat <<EOF | sh\npip install evil==6.6.6\nEOF'
  'npm install -g left-pad@1.3.0'
)
for form in "${lex_forms[@]}"; do lex_trace_check "${form}"; done
for v in recognize pieces stmtcuts stmtraw cscripts substs scan flat live \
    safedeps:inert_offsets safedeps:extract_pieces safedeps:payload_pieces safedeps:read_payload_words \
    safedeps:extract_command_substitution_payloads safedeps:command_reads; do
  [[ "${LEX_VIEWS_SEEN}" == *" ${v} "* ]] || fail "the lexing trace saw ${v} (otherwise this checks less than it says)"
done
[[ -z "${LEX_BAD}" ]] || fail "every lexing reads the command, a payload or a piece of one; these read a view's output:
${LEX_BAD}"
pass "every lexing of a guard run reads the command, a payload or a piece of one, never a view's output (${#lex_forms[@]} forms)"

# --- the spec readers start no process ------------------------------------------
# The spec readers used to rewrite a statement with sed and tr before reading it
# -- extras, an npm alias, a runner's operands, grouping characters -- and each
# ran in a command substitution, so a failed one left no text, no text read as
# no spec, and a pinned install passed as if it named nothing to check. Each
# had to carry a failure mark. They are now the manager's grammar
# (safedeps_manager_read) and per-word readers that run in the guard's own
# shell, which cannot fail that way, so the mark has nothing left to cover.
# This holds that: none of them starts sed, tr, awk or grep.
grammar_src="${ROOT_DIR}/lib/install-grammar.sh"
reader_bodies=$(
  for fn in guard_extract_specs guard_word_specs guard_word_as_read guard_names_package_without_spec guard_record_statement; do
    sed -n "/^${fn}() {/,/^}/p" "${GUARD}"
  done
  for fn in safedeps_manager_read safedeps_manager_read_union safedeps_manager_read_once safedeps_manager_read_npm safedeps_manager_read_npm_once safedeps_manager_read_mvn \
      safedeps_npx_first_pass safedeps_npm_read_args safedeps_manager_option_class safedeps_manager_command \
      safedeps_manager_npm_at safedeps_manager_long_option safedeps_manager_name; do
    sed -n "/^${fn}() {/,/^}/p" "${grammar_src}"
  done
)
[[ "${reader_bodies}" == *"safedeps_manager_read() {"* && "${reader_bodies}" == *"guard_extract_specs() {"* ]] \
  || fail "the spec readers are where this battery looks for them (renamed? then update this battery)"
for fn in guard_create_identity guard_family_ecosystem; do
  reader_bodies+=$'\n'"$(sed -n "/^${fn}() {/,/^}/p" "${GUARD}")"
done
if grep -nE '(^|[|$(;&[:space:]])(sed|tr|awk|grep|judge_grep)[[:space:]]|[$][(][^(]|`' \
    <<< "$(grep -v '^[[:space:]]*#' <<< "${reader_bodies}")"; then
  fail "a spec reader starts a process, which can fail and read as no spec"
fi
pass "the spec readers run in the guard's shell: no sed, tr, awk, grep or substitution to fail and read as no spec"

# --- when the statement readers fail ---------------------------------------------
# The extractor reads the command's statements from resolve_install_targets,
# which reads them from command_statements, and cuts them into pieces in one
# more awk. Either failing left no statements, no statements read as no spec,
# and an unapproved pinned install would pass as if it named nothing.
for reader in command_statements extract_pieces; do
  mkdir -p "${fail_tmp}/statements-${reader}"
  cat > "${fail_tmp}/statements-${reader}/awk" <<SHIM
#!/usr/bin/env bash
case "\$*" in *"safedeps:${reader}"*) exit 2 ;; esac
exec '${real_awk}' "\$@"
SHIM
  chmod +x "${fail_tmp}/statements-${reader}/awk"
  for failing_command in "pip install evil==1.0.0" "pnpm add evil@1.0.0 && echo done"; do
    scanfail_guard "" "${failing_command}"
    if [[ "${SCANFAIL_DECISION}" != "deny" ]] || grep -q 'UNDECIDED' <<< "${SCANFAIL_REASON}"; then
      fail "control: working statement readers deny ${failing_command} as a finding (got: ${SCANFAIL_DECISION})"
    fi
    scanfail_guard "${fail_tmp}/statements-${reader}" "${failing_command}"
    [[ "${SCANFAIL_DECISION}" == "deny" ]] \
      || fail "a failed ${reader} does not turn ${failing_command} into a pass (got: ${SCANFAIL_DECISION})"
    grep -q 'UNDECIDED' <<< "${SCANFAIL_REASON}" \
      || fail "a failed ${reader} is reported as undecided: ${failing_command}"
    grep -q 'scanner failed' <<< "${SCANFAIL_LOG}" \
      || fail "a failed ${reader} is recorded in advisory.log: ${failing_command}"
  done
done
pass "a failed statement reader denies the install as UNDECIDED (command_statements, extract_pieces, each against a working control)"


# --- the discriminator the gate falls back on ---------------------------------
# When a reading failed, the gate asks one question without reading the command:
# does it name a package manager's executable anywhere? Two properties make
# that answer trustworthy, and both are checked on the function as the guard
# defines it, extracted from the script.
discriminator=$(sed -n '/^guard_looks_like_install_unscanned() {$/,/^}$/p' scripts/safedeps-pre-guard.sh)
[[ -n "${discriminator}" ]] || fail "the discriminator can be extracted from the guard"
discriminate() {
  # An empty PATH: any subprocess it tried to start would fail, and it must
  # answer anyway, because the tools it stands in for are the ones failing.
  env -i PATH= COMMAND="$1" /bin/bash -c '
    source lib/install-grammar.sh
    eval "$1"
    guard_looks_like_install_unscanned' _ "${discriminator}"
}
discriminate "npm install left-pad@1.3.0" || fail "the discriminator answers with no PATH (no subprocess) for an install"
if discriminate "ls -la"; then fail "the discriminator says no for a command that names no manager"; fi
if discriminate "git commit -m 'fix'"; then fail "the discriminator says no for a plain commit"; fi
discriminate "NPM INSTALL x" || fail "the discriminator ignores case"
discriminate $'echo hi\npip3.11 install x' || fail "the discriminator reads every line"
pass "the discriminator needs no subprocess and ignores case"

# It must say yes to everything any recognizer could find. It is derived from
# SAFEDEPS_G_EXECUTABLES rather than listed by hand; this checks the derivation
# against every install form the failure census uses, and against every manager
# the pipe check names.
while IFS= read -r -d '' form; do
  discriminate "${form}" || fail "the discriminator names every census form: ${form}"
done < <(jq -j '.forms[], .extras[] | . + "\u0000"' scripts/measure/scan-failure-corpus.json)
pipe_managers=$(sed -n "s/^PIPE_MANAGER_RE='(\(.*\))'\$/\1/p" scripts/safedeps-pre-guard.sh)
[[ -n "${pipe_managers}" ]] || fail "the pipe check's manager list can be read"
for manager in $(tr '|' '\n' <<< "${pipe_managers}" | sed -E 's/\[[^]]*\][*+]?//g; s/[()]//g' | grep -E '^[a-z]+$'); do
  discriminate "${manager} install x" || fail "the discriminator names the pipe check's manager ${manager}"
done
pass "the discriminator names every census form and every manager the pipe check knows"

printf 'scan-contract: all checks passed\n'
