#!/usr/bin/env bash
# safedeps: the lexer read in a batch reads every text as it reads it alone.
#
# shell_lex_batch reads many texts in one awk process, so a reader that goes
# statement by statement pays for one process instead of one per statement.
# It runs shell_lex's own program, with its BEGIN and END made functions and
# every global cleared before each text. Two things can make a batch read a
# text differently from shell_lex alone, and this battery checks both:
#
#   1. A global the clearing lists miss. The program starts with every global
#      unset; one left over from the previous text is state that text never
#      had. The static check lists every global of the program shell_lex runs
#      (as the running shell holds it) and fails on any name missing from
#      SAFEDEPS_LEX_ARRAYS or SAFEDEPS_LEX_SCALARS, or listed as the other kind.
#   2. Anything else. The differential check reads the committed corpora and
#      seeded random commands in every view and every reading, as one batch in
#      order and as one batch in reverse, and compares each text's view and its
#      side outputs (DIVERGE, UNTERM, a failure mark, failed or not) with
#      shell_lex called alone. The two orders put every text after different
#      ones, so state left over shows as a difference between them as well.
#
# command_is_dependency_install_each asks command_is_dependency_install about
# many statements at once, on these batches. Section 4 asks it about the same
# inputs, in every reading, and compares each answer, and what replaying it
# appends to the DIVERGE, mark and flag files, with asking it alone.
#
# guard_detect_ecosystem asks one grep about every segment of a command.
# Section 5 compares it with the grep per segment it replaced, on forms that
# hold newlines inside statements, with grep working and with it failing.
#
# A batch that falls back to reading one text at a time gives the same answers
# by construction, so it would pass the comparison while losing the reason the
# batch exists: the battery also requires every batch to have run as one.
#
# Usage: scripts/test/lex-batch.sh [--full]
#   --full  compare every input alone in every view and reading (the default
#           compares one in eight alone, rotating, and every input between the
#           two batch orders).
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "${REPO_DIR}"
GUARD=scripts/safedeps-pre-guard.sh

FULL=false
[[ "${1:-}" != --full ]] || FULL=true

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1"; FAILED=1; }
FAILED=0

command -v python3 > /dev/null || { printf 'lex-batch: python3 is required\n' >&2; exit 2; }

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-lex-batch.XXXXXX")
trap 'rm -rf "${TMP_ROOT}"' EXIT
export TMPDIR="${TMP_ROOT}"

# The functions under test, extracted rather than sourced: the guard is an
# executable hook with no source guard.
src=$(sed -n \
  -e '/^guard_mark_reading_failed() {/,/^}/p' \
  -e '/^shell_lex() {/,/^}/p' \
  -e '/^SAFEDEPS_LEX_ARRAYS=/p' -e '/^SAFEDEPS_LEX_SCALARS=/p' \
  -e '/^shell_lex_batch() {/,/^}/p' \
  -e '/^shell_lex_batch_side() {/,/^}/p' \
  -e '/^shell_lex_batch_replay() {/,/^}/p' "${GUARD}")
eval "${src}"
for f in shell_lex shell_lex_batch shell_lex_batch_side shell_lex_batch_replay guard_mark_reading_failed; do
  declare -F "${f}" > /dev/null || { printf 'lex-batch: %s not found in the guard\n' "${f}" >&2; exit 2; }
done
SAFEDEPS_SCAN_MARK=""
SAFEDEPS_LEX_DIVERGE=""
SAFEDEPS_LEX_CACHE=""
SAFEDEPS_LB_IN=()

# --- 1. the clearing lists cover every global of the program -------------------

declare -f shell_lex | awk -v q="'" 'f && index($0, "  " q " && printf") == 1 { exit } f { print } /awk -v view=/ { f = 1 }' > "${TMP_ROOT}/prog.awk"
[[ -s "${TMP_ROOT}/prog.awk" ]] || { printf 'lex-batch: the lexer program was not found in shell_lex\n' >&2; exit 2; }
printf '%s\n' ${SAFEDEPS_LEX_ARRAYS} > "${TMP_ROOT}/arrays"
printf '%s\n' ${SAFEDEPS_LEX_SCALARS} > "${TMP_ROOT}/scalars"
static=$(python3 - "${TMP_ROOT}/prog.awk" "${TMP_ROOT}/arrays" "${TMP_ROOT}/scalars" <<'PY'
# The globals of an awk program: every name that is not a keyword, a builtin,
# a special variable, a function, or a parameter of the function it is used in.
# A name is an array when it is subscripted, follows `in` or `delete`, is
# split()'s second argument, or is passed where a function uses its parameter
# as an array.
import re, sys
src = open(sys.argv[1]).read()
arrays = set(open(sys.argv[2]).read().split()); scalars = set(open(sys.argv[3]).read().split())
KW = set("BEGIN END function func if else while for do break continue next nextfile exit return delete in getline print printf".split())
BI = set("length substr index split sub gsub match sprintf sin cos atan2 exp log sqrt int rand srand tolower toupper system close fflush".split())
SPECIAL = set("NR NF FS OFS ORS RS FILENAME FNR SUBSEP RSTART RLENGTH CONVFMT OFMT ENVIRON ARGC ARGV".split())
toks = []; i = 0; n = len(src); prev = None
while i < n:
    c = src[i]
    if c == '#':
        while i < n and src[i] != '\n': i += 1
        continue
    if c == '\\' and i + 1 < n and src[i+1] == '\n': i += 2; continue
    if c in ' \t': i += 1; continue
    if c == '\n': toks.append(('nl', '\n')); prev = ('nl', '\n'); i += 1; continue
    if c == '"':
        j = i + 1
        while j < n and src[j] != '"': j += 2 if src[j] == '\\' else 1
        toks.append(('str', '')); prev = ('str', ''); i = j + 1; continue
    if c == '/' and (prev is None or prev[0] == 'nl' or prev[0] == 'op' and prev[1] not in (')', ']') or prev[0] == 'kw' and prev[1] != 'getline'):
        j = i + 1; inbr = False
        while j < n:
            if src[j] == '\\': j += 2; continue
            if src[j] == '[': inbr = True
            elif src[j] == ']': inbr = False
            elif src[j] == '/' and not inbr: break
            j += 1
        toks.append(('re', '')); prev = ('re', ''); i = j + 1; continue
    m = re.match(r'[A-Za-z_][A-Za-z0-9_]*', src[i:i+64])
    if m:
        w = m.group(0); k = 'kw' if w in KW else 'id'
        toks.append((k, w)); prev = (k, w); i += len(w); continue
    m = re.match(r'[0-9]+(\.[0-9]*)?([eE][-+]?[0-9]+)?', src[i:i+64])
    if m:
        toks.append(('num', '')); prev = ('num', ''); i += len(m.group(0)); continue
    m = re.match(r'(\+\+|--|\+=|-=|\*=|/=|%=|\^=|==|!=|<=|>=|&&|\|\||>>|[-+*/%^!<>=?:,;(){}\[\]|$~&])', src[i:i+4])
    if not m: sys.exit('cannot read the program at byte %d: %r' % (i, src[i:i+30]))
    toks.append(('op', m.group(0))); prev = ('op', m.group(0)); i += len(m.group(0))
funcs = {}; scopes = []; header = set(); k = 0
while k < len(toks):
    if toks[k] == ('kw', 'function') or toks[k] == ('kw', 'func'):
        name = toks[k+1][1]; j = k + 3; params = []
        while toks[j][1] != ')':
            if toks[j][0] == 'id': params.append(toks[j][1]); header.add(j)
            j += 1
        while toks[j][1] != '{': j += 1
        depth = 0; s0 = j
        while True:
            if toks[j][1] == '{': depth += 1
            elif toks[j][1] == '}':
                depth -= 1
                if depth == 0: break
            j += 1
        funcs[name] = params; scopes.append((s0, j, name)); k = j
    k += 1
def scope_of(t):
    for s0, e0, f in scopes:
        if s0 <= t <= e0: return set(funcs[f])
    return set()
farr = {}
for s0, e0, f in scopes:
    used = set()
    for t in range(s0, e0 + 1):
        kind, w = toks[t]
        if kind == 'id' and w in funcs[f] and (toks[t+1][1] == '[' or toks[t-1][1] in ('in', 'delete')):
            used.add(funcs[f].index(w))
    farr[f] = used
glob = {}; calls = []; depth = 0
for t, (kind, w) in enumerate(toks):
    if (kind, w) == ('op', '('):
        depth += 1
        if t > 0 and toks[t-1][0] == 'id' and (toks[t-1][1] in funcs or toks[t-1][1] == 'split'):
            calls.append([toks[t-1][1], 0, depth])
        continue
    if (kind, w) == ('op', ')'):
        if calls and calls[-1][2] == depth: calls.pop()
        depth -= 1; continue
    if (kind, w) == ('op', ',') and calls and calls[-1][2] == depth:
        calls[-1][1] += 1; continue
    if kind != 'id' or t in header or w in BI or w in funcs or w in SPECIAL or w in scope_of(t): continue
    nxt = toks[t+1][1] if t + 1 < len(toks) else ''
    if nxt == '(': continue
    isarr = nxt == '[' or toks[t-1][1] in ('in', 'delete')
    if calls and calls[-1][2] == depth and toks[t-1][1] in ('(', ',') and nxt in (',', ')'):
        f, ai, _ = calls[-1]
        if (f == 'split' and ai == 1) or (f in farr and ai in farr[f]): isarr = True
    glob.setdefault(w, set()).add('array' if isarr else 'scalar')
bad = 0
for w in sorted(glob):
    kind = 'array' if 'array' in glob[w] else 'scalar'
    if kind == 'array' and w not in arrays:
        print('missing array %s%s' % (w, ' (listed as a scalar)' if w in scalars else '')); bad += 1
    elif kind == 'scalar' and w not in scalars:
        print('missing scalar %s%s' % (w, ' (listed as an array)' if w in arrays else '')); bad += 1
for w in sorted(arrays | scalars):
    if w in funcs or w in KW or w in BI or w in SPECIAL:
        print('listed name %s is not a variable of the program' % w); bad += 1
print('globals %d listed %d bad %d' % (len(glob), len(arrays | scalars), bad))
PY
) || { printf 'lex-batch: the static check did not run\n%s\n' "${static}" >&2; exit 2; }
printf '# %s\n' "${static}" | tail -1
if [[ "${static}" == *"bad 0" ]]; then
  pass "every global of the lexer program is cleared before each text of a batch"
else
  printf '%s\n' "${static}" | sed 's/^/#   /'
  fail "every global of the lexer program is cleared before each text of a batch"
fi

# --- 2. a batch reads each text as shell_lex reads it alone -------------------

# Seeded random commands, written first: a heredoc inside a process
# substitution is parsed by bash 3.2 for quotes, and these hold every kind.
python3 - > "${TMP_ROOT}/random" <<'PY'
import random, sys
# Seeded random commands from the pieces the lexer decides on, and statements
# of the shapes a statement reader hands it one at a time.
rnd = random.Random(20261005)
pal = ["npm install x", "pip install evil==1.0", "sh -c '", "bash -c \"", "eval ", "eval \"npm ci\"", "\"", "'",
       "\\", "\\\n", "$(", ")", "`", "${", "}", "((", "))", "<<EOF\n", "<<'E'\n", "<<-T\n", "\nEOF\n", "\nE\n",
       "\n\tT\n", "|", "||", "&&", ";", "&", "\n", "#", " ", "\t", "env A=b ", "FOO=\"a b\" ", "exec -a n ",
       "command -p ", "time -p ", "$'\\x41\\n'", "{ ", " }", "( ", " )", "case x in a) ", ";; esac", "> f ",
       "2>&1 ", "| sh", "/bin/sh -c ", "ksh -c ", "--", "cd /tmp && ", "npx a@1", "yarn add y", "f() { ",
       "(1)", "$x", "$[1]", "!", "if true; then ", "fi"]
out = []
for i in range(120):
    parts = []; target = rnd.choice([20, 80, 300, 2000])
    while sum(map(len, parts)) < target: parts.append(rnd.choice(pal))
    out.append("".join(parts))
unit = "f() { echo 'a b' \"$x\" (1); }; "
out += [unit, unit * 3, "echo line", "echo line7", "npm install left-pad@1.0.0", "", " ", "x" * 5000,
        "sh -c \"" + unit.replace('"', '\\"') * 4 + "\""]
sys.stdout.write("".join(s + "\0" for s in out))
PY

INPUTS=()
while IFS= read -r -d '' c; do INPUTS+=("${c}"); done < <(
  jq -j '.[] | .command + "\u0000"' scripts/measure/scan-corpus.json scripts/measure/tuple-corpus.json
  jq -j '.[] | .text + "\u0000"' scripts/measure/shell-reading-forms.json scripts/measure/word-reading-forms.json
  cat "${TMP_ROOT}/random"
)
printf '# %d inputs\n' "${#INPUTS[@]}"

VIEWS="scan code live noredir pieces cscripts stmts substs unprefixed unprefixed-lines joined shell-bodies recognize stmtcuts events cwords wordends"
single() {
  # shell_lex alone, its side outputs in files of the comparison's own.
  local dir="${TMP_ROOT}/single" o r=0
  mkdir -p "${dir}"
  : > "${dir}/d"; : > "${dir}/u"; : > "${dir}/m"
  o=$(SAFEDEPS_LEX_DIVERGE="${dir}/d" SAFEDEPS_LEX_FLAGS="${dir}/u" SAFEDEPS_SCAN_MARK="${dir}/m" \
    shell_lex "$1" "$2" "safedeps:lex-batch" && printf 'X') || r=1
  (( r == 0 )) || o=""
  SINGLE_OUT="${o%X}" SINGLE_F="${r}"
  SINGLE_D=$(cat "${dir}/d"; printf 'X'); SINGLE_D="${SINGLE_D%X}"
  SINGLE_U=$(cat "${dir}/u"; printf 'X'); SINGLE_U="${SINGLE_U%X}"
  SINGLE_M=$(cat "${dir}/m"; printf 'X'); SINGLE_M="${SINGLE_M%X}"
}

n=${#INPUTS[@]}
# A batch whose texts hold no newline reads them as the lines of one input;
# one with a newline gives each text a file. The inputs as they are hold
# newlines, so the texts without one are read again as a batch of their own.
LINE_INPUTS=()
for c in "${INPUTS[@]}"; do [[ "${c}" == *$'\n'* ]] || LINE_INPUTS+=("${c}"); done
printf '# %d inputs hold no newline\n' "${#LINE_INPUTS[@]}"
compared=0 differ=0 orders=0 fellback=0 vi=0
for set in all lines; do
  if [[ "${set}" == all ]]; then CUR=("${INPUTS[@]}"); else CUR=("${LINE_INPUTS[@]}"); fi
  m=${#CUR[@]}
for reading in bash zsh dash; do
  SAFEDEPS_READING="${reading}"
  for view in ${VIEWS}; do
    vi=$(( vi + 1 ))
    SAFEDEPS_LB_IN=("${CUR[@]}")
    shell_lex_batch "${view}" "safedeps:lex-batch"
    [[ "${SAFEDEPS_LB_MODE}" == batch ]] || fellback=$(( fellback + 1 ))
    fw_out=("${SAFEDEPS_LB_OUT[@]}") fw_d=("${SAFEDEPS_LB_D[@]}") fw_u=("${SAFEDEPS_LB_U[@]}") fw_m=("${SAFEDEPS_LB_M[@]}") fw_f=("${SAFEDEPS_LB_F[@]}")
    SAFEDEPS_LB_IN=()
    for (( k = m - 1; k >= 0; k-- )); do SAFEDEPS_LB_IN+=("${CUR[k]}"); done
    shell_lex_batch "${view}" "safedeps:lex-batch"
    [[ "${SAFEDEPS_LB_MODE}" == batch ]] || fellback=$(( fellback + 1 ))
    for (( k = 0; k < m; k++ )); do
      r=$(( m - 1 - k ))
      if [[ "${fw_out[k]}" != "${SAFEDEPS_LB_OUT[r]}" || "${fw_d[k]}" != "${SAFEDEPS_LB_D[r]}" || "${fw_u[k]}" != "${SAFEDEPS_LB_U[r]}" \
            || "${fw_m[k]}" != "${SAFEDEPS_LB_M[r]}" || "${fw_f[k]}" != "${SAFEDEPS_LB_F[r]}" ]]; then
        orders=$(( orders + 1 ))
        (( orders > 5 )) || printf '# order differs: %s %s %s input %d\n' "${set}" "${reading}" "${view}" "${k}"
      fi
      [[ "${FULL}" == true ]] || (( (k + vi) % 8 == 0 )) || continue
      single "${CUR[k]}" "${view}"
      compared=$(( compared + 1 ))
      if [[ "${fw_out[k]}" != "${SINGLE_OUT}" || "${fw_d[k]}" != "${SINGLE_D}" || "${fw_u[k]}" != "${SINGLE_U}" \
            || "${fw_m[k]}" != "${SINGLE_M}" || "${fw_f[k]}" != "${SINGLE_F}" ]]; then
        differ=$(( differ + 1 ))
        (( differ > 5 )) || printf '# differs from shell_lex alone: %s %s %s input %d\n' "${set}" "${reading}" "${view}" "${k}"
      fi
    done
  done
done
done
printf '# %d texts compared with shell_lex alone, %d differ; %d differ between the two batch orders\n' "${compared}" "${differ}" "${orders}"
(( differ == 0 )) && pass "a batch reads each text as shell_lex alone reads it (view and side outputs)" \
  || fail "a batch reads each text as shell_lex alone reads it (view and side outputs)"
(( orders == 0 )) && pass "a batch reads each text the same whatever texts come before it" \
  || fail "a batch reads each text the same whatever texts come before it"
(( fellback == 0 )) && pass "every batch ran in one awk process" \
  || fail "every batch ran in one awk process (${fellback} fell back to one text at a time)"

# --- 3. replay writes what shell_lex alone writes -------------------------------

SAFEDEPS_READING=bash
SAFEDEPS_LB_IN=("x \"" "((a" "echo ok")
shell_lex_batch scan "safedeps:lex-batch"
mkdir -p "${TMP_ROOT}/replay"
: > "${TMP_ROOT}/replay/d"; : > "${TMP_ROOT}/replay/u"; : > "${TMP_ROOT}/replay/m"
got=""
for k in 0 1 2; do
  got+="[$(SAFEDEPS_LEX_DIVERGE="${TMP_ROOT}/replay/d" SAFEDEPS_LEX_FLAGS="${TMP_ROOT}/replay/u" SAFEDEPS_SCAN_MARK="${TMP_ROOT}/replay/m" \
    shell_lex_batch_replay "${k}"; printf ':%s' "$?")]"
done
want=""
: > "${TMP_ROOT}/replay/d2"; : > "${TMP_ROOT}/replay/u2"; : > "${TMP_ROOT}/replay/m2"
for k in 0 1 2; do
  want+="[$(SAFEDEPS_LEX_DIVERGE="${TMP_ROOT}/replay/d2" SAFEDEPS_LEX_FLAGS="${TMP_ROOT}/replay/u2" SAFEDEPS_SCAN_MARK="${TMP_ROOT}/replay/m2" \
    shell_lex "${SAFEDEPS_LB_IN[k]}" scan "safedeps:lex-batch"; printf ':%s' "$?")]"
done
if [[ "${got}" == "${want}" ]] && cmp -s "${TMP_ROOT}/replay/d" "${TMP_ROOT}/replay/d2" \
    && cmp -s "${TMP_ROOT}/replay/u" "${TMP_ROOT}/replay/u2" && cmp -s "${TMP_ROOT}/replay/m" "${TMP_ROOT}/replay/m2" \
    && [[ -s "${TMP_ROOT}/replay/u" ]]; then
  pass "replaying a text prints and writes what shell_lex alone prints and writes"
else
  fail "replaying a text prints and writes what shell_lex alone prints and writes (got ${got}, want ${want})"
fi
SAFEDEPS_READING=zsh
if shell_lex_batch_replay 0 > /dev/null 2>&1; then
  fail "a batch read in one reading is not replayed in another"
else
  pass "a batch read in one reading is not replayed in another"
fi

# --- 4. the batched install question answers as the question asked alone ----

# Every function of the guard (definitions only) and the grammar it reads.
# shellcheck source=../../lib/install-grammar.sh
source lib/install-grammar.sh
eval "$(sed -n -e '/^[a-z_][a-z_0-9]*() {$/,/^}$/p' -e '/^SAFEDEPS_INSTALL_PATTERN=/p' "${GUARD}")"
alone() {
  # command_is_dependency_install alone, its side outputs in files of its own.
  local dir="${TMP_ROOT}/alone" r=0
  mkdir -p "${dir}"
  : > "${dir}/d"; : > "${dir}/u"; : > "${dir}/m"
  SAFEDEPS_LEX_DIVERGE="${dir}/d" SAFEDEPS_LEX_FLAGS="${dir}/u" SAFEDEPS_SCAN_MARK="${dir}/m" \
    command_is_dependency_install "$1" || r=1
  ALONE="${r}|$(cat "${dir}/d")|$(cat "${dir}/u")|$(cat "${dir}/m")"
}
replayed() {
  local dir="${TMP_ROOT}/replayed" r=0
  mkdir -p "${dir}"
  : > "${dir}/d"; : > "${dir}/u"; : > "${dir}/m"
  SAFEDEPS_LEX_DIVERGE="${dir}/d" SAFEDEPS_LEX_FLAGS="${dir}/u" SAFEDEPS_SCAN_MARK="${dir}/m" \
    command_is_dependency_install_replay "$1" || r=1
  REPLAYED="${r}|$(cat "${dir}/d")|$(cat "${dir}/u")|$(cat "${dir}/m")"
}
asked=0 differ=0 installs=0
for reading in bash zsh dash; do
  SAFEDEPS_READING="${reading}"
  SAFEDEPS_ID_IN=("${INPUTS[@]}")
  command_is_dependency_install_each
  for (( k = 0; k < n; k++ )); do
    [[ "${FULL}" == true ]] || (( (k + ${#reading}) % 4 == 0 )) || continue
    alone "${INPUTS[k]}"
    replayed "${k}"
    asked=$(( asked + 1 ))
    [[ "${ALONE}" != 0* ]] || installs=$(( installs + 1 ))
    if [[ "${ALONE}" != "${REPLAYED}" ]]; then
      differ=$(( differ + 1 ))
      (( differ > 5 )) || printf '# differs: %s input %d: alone %q, batched %q\n' "${reading}" "${k}" "${ALONE:0:80}" "${REPLAYED:0:80}"
    fi
  done
done
printf '# %d questions asked both ways (%d installs), %d differ\n' "${asked}" "${installs}" "${differ}"
(( differ == 0 )) && pass "the batched install question answers, and writes, as the question asked alone" \
  || fail "the batched install question answers, and writes, as the question asked alone"

# --- 5. the ecosystem of the first install, one grep for every segment ------

# guard_detect_ecosystem asks one grep about every segment and maps grep's
# line numbers back to segments. The loop it replaced asked one grep per
# segment; it is kept here, as it was, to compare with. A segment is a line,
# so a statement over several lines is several segments: the forms below put
# newlines inside segments on purpose (a heredoc, quotes, a continuation, a
# script), where a mapping by statement would go wrong.
ecosystem_alone() {
  local cmd="$1"
  local seg eco
  while IFS= read -r seg; do
    [[ "${seg}" =~ [^[:space:]] ]] || continue
    judge_grep -qEi "${SAFEDEPS_INSTALL_PATTERN}" <<< "${seg}" || continue
    eco=$(guard_segment_ecosystem "${seg}")
    [[ -n "${eco}" ]] && { printf '%s' "${eco}"; return 0; }
  done < <(command_candidate_start_texts "${cmd}" | tr ';|&' '\n')
  printf ''
}
eco_both() {
  # <fn> <text>: the answer and the three files, as one string.
  local dir="${TMP_ROOT}/eco.$1" out
  mkdir -p "${dir}"
  : > "${dir}/d"; : > "${dir}/u"; : > "${dir}/m"
  out=$(SAFEDEPS_LEX_DIVERGE="${dir}/d" SAFEDEPS_LEX_FLAGS="${dir}/u" SAFEDEPS_SCAN_MARK="${dir}/m" "$1" "$2"; printf 'X')
  ECO="${out%X}|$(cat "${dir}/d")|$(cat "${dir}/u")|$(cat "${dir}/m")"
}
ECO_FORMS=(
  $'echo a\nnpm install left-pad@1.0.0'
  $'echo one\necho two\npip install evil==1.0\nnpm ci'
  $'cat <<EOF\nnpm install y@1\nEOF\npip install z==1'
  $'echo "a\nb" ; yarn add c@1 | tee log'
  $'npm run x && \\\n  pip install q==2'
  $'sh -c \'echo a\npip install q==1\'; echo done'
  $'x=1\n\ny=2; gem install rake -v 13.0.0'
  $'echo "npm install no"\ncargo install c@1\nnpm i d@1'
  $'f() {\n  echo hi\n}\ngo install a@v1'
  $'true\n\n\n\nmvn -Dartifact=g:a:1 dependency:get'
)
eco_inputs=("${ECO_FORMS[@]}")
for (( k = 0; k < n; k += 7 )); do eco_inputs+=("${INPUTS[k]}"); done
asked=0 differ=0 named=0
for reading in bash zsh dash; do
  SAFEDEPS_READING="${reading}"
  for text in "${eco_inputs[@]}"; do
    eco_both ecosystem_alone "${text}"; a="${ECO}"
    eco_both guard_detect_ecosystem "${text}"; b="${ECO}"
    asked=$(( asked + 1 ))
    [[ "${a}" == "|"* ]] || named=$(( named + 1 ))
    if [[ "${a}" != "${b}" ]]; then
      differ=$(( differ + 1 ))
      (( differ > 5 )) || printf '# differs: %s %q: alone %q, batched %q\n' "${reading}" "${text:0:60}" "${a:0:60}" "${b:0:60}"
    fi
  done
done
printf '# %d commands asked both ways (%d named an ecosystem), %d differ\n' "${asked}" "${named}" "${differ}"
(( differ == 0 )) && pass "one grep for every segment names the ecosystem, and writes, as a grep per segment" \
  || fail "one grep for every segment names the ecosystem, and writes, as a grep per segment"

# With every grep failing, both mark the reading and name nothing.
mkdir -p "${TMP_ROOT}/failgrep"
printf '#!/bin/sh\nexit 2\n' > "${TMP_ROOT}/failgrep/grep"
chmod +x "${TMP_ROOT}/failgrep/grep"
SAFEDEPS_READING=bash differ=0
for text in "${ECO_FORMS[@]}"; do
  PATH="${TMP_ROOT}/failgrep:${PATH}" eco_both ecosystem_alone "${text}"; a="${ECO}"
  PATH="${TMP_ROOT}/failgrep:${PATH}" eco_both guard_detect_ecosystem "${text}"; b="${ECO}"
  if [[ "${a%%|*}" != "${b%%|*}" || "${a##*|}" != *failed* || "${b##*|}" != *failed* ]]; then
    differ=$(( differ + 1 ))
    printf '# with grep failing: %q: alone %q, batched %q\n' "${text:0:60}" "${a:0:60}" "${b:0:60}"
  fi
done
(( differ == 0 )) && pass "with grep failing, both name no ecosystem and both mark the reading" \
  || fail "with grep failing, both name no ecosystem and both mark the reading"

(( FAILED == 0 )) || exit 1
printf 'lex-batch battery: all checks passed\n'
