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
#   command_needs_inplace_inert      may the flag be appended
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
# offsets into the command or may be read again: scan (what the predicates
# read), code (what the payload readers read, quotes kept) and noredir (the
# command with its redirections blanked, what the spec extractor's pieces are
# cut from). Each keeps the byte length of the command, so an offset found in a
# view is the offset in the command, and each is idempotent, so a view read
# again is the view read once. Stripping a heredoc twice is how its body once
# swallowed the line after it (caught in review). The joined view is neither:
# it drops continuations on purpose. Checked on every recorded shell form and on
# random input drawn from the characters quotes, comments, heredocs,
# substitutions and redirections are made of.
#
# Each property holds within each reading (bash, zsh, dash): a view is read
# again only under the reading that made it. And one property holds across
# them: where the bash reading says no DIVERGE, the zsh and dash views are the
# bash views, byte for byte. That is what lets the guard skip the other two
# readings, so a place where the shells differ that the lexer does not report
# shows here as a reading that moved without a DIVERGE.
scan_view() { shell_lex "$1" scan "safedeps:scan-contract"; }
code_view() { shell_lex "$1" code "safedeps:scan-contract"; }
noredir_view() { shell_lex "$1" noredir "safedeps:scan-contract"; }
property_failures=0
diverge_file=$(mktemp "${TMPDIR:-/tmp}/safedeps-diverge.XXXXXX")
check_view_properties() { # input label
  local x="$1" v once twice reading bash_views="" views
  for reading in bash zsh dash; do
    views=""
    for v in scan_view code_view noredir_view; do
      # Not through capture: the outer $(...) would strip a trailing newline
      # from the view and read as a length change the lexer did not make.
      once=$(SAFEDEPS_READING="${reading}" "${v}" "${x}"; printf 'X'); once="${once%X}"
      views+="${once}"$'\036'
      if [[ "$(byte_len "${once}")" != "$(byte_len "${x}")" ]]; then
        printf 'length: %s (%s) changed the length of [%q] (%s)\n' "${v}" "${reading}" "${x}" "$2" >&2
        property_failures=$((property_failures + 1))
        continue
      fi
      twice=$(SAFEDEPS_READING="${reading}" "${v}" "${once}"; printf 'X'); twice="${twice%X}"
      if [[ "${twice}" != "${once}" ]]; then
        printf 'idempotence: %s (%s) read twice differs on [%q] (%s)\n  once  [%q]\n  twice [%q]\n' "${v}" "${reading}" "${x}" "$2" "${once}" "${twice}" >&2
        property_failures=$((property_failures + 1))
      fi
    done
    if [[ "${reading}" == bash ]]; then
      bash_views="${views}"
      : > "${diverge_file}"
      SAFEDEPS_READING=bash SAFEDEPS_LEX_DIVERGE="${diverge_file}" scan_view "${x}" > /dev/null
      SAFEDEPS_READING=bash SAFEDEPS_LEX_DIVERGE="${diverge_file}" code_view "${x}" > /dev/null
      SAFEDEPS_READING=bash SAFEDEPS_LEX_DIVERGE="${diverge_file}" noredir_view "${x}" > /dev/null
    elif [[ ! -s "${diverge_file}" && "${views}" != "${bash_views}" ]]; then
      printf 'diverge: the %s reading of [%q] differs from bash, and the bash reading said no DIVERGE (%s)\n' "${reading}" "${x}" "$2" >&2
      property_failures=$((property_failures + 1))
    fi
  done
}
forms_file="${ROOT_DIR}/scripts/measure/shell-reading-forms.json"
form_count=$(jq length "${forms_file}")
for ((i = 0; i < form_count; i++)); do
  form=$(jq -j ".[${i}].text" "${forms_file}" | sed -e 's/@@TAIL@@/pip install evil==6.6.6/' -e 's/@@TAIL_SPLIT@@/pi\\\
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
pass "view properties: scan, code and noredir keep length and are idempotent in the bash, zsh and dash readings, and read as bash wherever bash says no DIVERGE, on ${form_count} shell forms and ${fuzz_cases} random inputs"

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
for v in scan code joined unprefixed; do
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
mkdir -p "${fail_tmp}/scanner-only" "${fail_tmp}/all-awk" "${fail_tmp}/scanner-later" "${fail_tmp}/blanking-only" "${fail_tmp}/spans-only" "${fail_tmp}/project"
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
# The awk that sets a visible install aside before the pipe check reads the
# rest (install_managers_blanked). It fails alone, and counts its calls so the
# case below can show it was reached.
cat > "${fail_tmp}/blanking-only/awk" <<SHIM
#!/usr/bin/env bash
case "\$*" in
  *"safedeps:install_managers_blanked"*)
    printf 'x' >> '${fail_tmp}/blanking-only/count'
    exit 2
    ;;
esac
exec '${real_awk}' "\$@"
SHIM
# The awk that turns the install matches into byte spans for that blanking
# pass (install_match_spans). It ran under no marker and its failure was
# swallowed with grep's "no match", so the visible install was not set aside
# and was read as install text piped into a shell (caught in review).
cat > "${fail_tmp}/spans-only/awk" <<SHIM
#!/usr/bin/env bash
case "\$*" in
  *"safedeps:install_match_spans"*)
    printf 'x' >> '${fail_tmp}/spans-only/count'
    exit 2
    ;;
esac
exec '${real_awk}' "\$@"
SHIM
chmod +x "${fail_tmp}/scanner-only/awk" "${fail_tmp}/all-awk/awk" "${fail_tmp}/scanner-later/awk" "${fail_tmp}/blanking-only/awk" "${fail_tmp}/spans-only/awk"

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

# Beside a visible install, the pipe check sets the install aside with its own
# awk before reading the rest. When that awk fails the check has no answer, and
# no answer must not read as "nothing piped": the settle turns it into
# UNDECIDED. The visible spec is approved so that nothing else denies first.
piped_beside="pip install requests==2.0.0 && printf 'pip install evil==6.6.6' | sh"
scanfail_guard "" "${piped_beside}" "pypi requests 2.0.0"
[[ "${SCANFAIL_DECISION}" == "deny" ]] || fail "control: a working pipe check denies an install piped beside an approved one (got: ${SCANFAIL_DECISION})"
if grep -q 'UNDECIDED' <<< "${SCANFAIL_REASON}"; then fail "control: a working pipe check answers with a finding, not UNDECIDED"; fi
rm -f "${fail_tmp}/blanking-only/count"
scanfail_guard "${fail_tmp}/blanking-only" "${piped_beside}" "pypi requests 2.0.0"
[[ -s "${fail_tmp}/blanking-only/count" ]] || fail "the blanking shim was reached (otherwise this case tests nothing)"
[[ "${SCANFAIL_DECISION}" == "deny" ]] || fail "a failed blanking awk does not turn a piped install into a pass (got: ${SCANFAIL_DECISION})"
grep -q 'UNDECIDED' <<< "${SCANFAIL_REASON}" || fail "a failed blanking awk is reported as undecided, not as a finding"
grep -q 'scanner failed' <<< "${SCANFAIL_LOG}" || fail "a failed blanking awk is recorded in advisory.log"
pass "a failed blanking awk beside a visible install answers UNDECIDED, not pass"

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

# Nothing is piped here but the word `ok`, so a finding about piped install text
# could only come from the failed span reading.
spans_beside="pip install requests==2.0.0 && echo ok | sh"
scanfail_guard "" "${spans_beside}" "pypi requests 2.0.0"
[[ "${SCANFAIL_DECISION}" == "pass" ]] || fail "control: an approved install beside a pipe that carries no install passes (got: ${SCANFAIL_DECISION})"
rm -f "${fail_tmp}/spans-only/count"
scanfail_guard "${fail_tmp}/spans-only" "${spans_beside}" "pypi requests 2.0.0"
[[ -s "${fail_tmp}/spans-only/count" ]] || fail "the span shim was reached (otherwise this case tests nothing)"
[[ "${SCANFAIL_DECISION}" == "deny" ]] || fail "a failed span awk is not a pass for a command that names a package manager (got: ${SCANFAIL_DECISION})"
grep -q 'UNDECIDED' <<< "${SCANFAIL_REASON}" || fail "a failed span awk is reported as undecided, not as a piped-install finding"
grep -q 'scanner failed' <<< "${SCANFAIL_LOG}" || fail "a failed span awk is recorded in advisory.log"
pass "a failed span awk beside a visible install answers UNDECIDED, not a finding"

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
