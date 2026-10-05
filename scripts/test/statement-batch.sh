#!/usr/bin/env bash
# safedeps: a reader that asks about every statement at once answers as the
# reader that asked about each.
#
# guard_detect_ecosystem asks one grep about every segment of a command and
# maps grep's line numbers back to the segments. It replaced a grep per
# segment, which made the gate's cost grow with the number of statements.
# This battery keeps that loop, as it was, and compares the two on the
# committed corpora, seeded random commands, and forms that hold newlines
# inside statements, in every reading, with grep working and with it
# failing. Mutations of the mapping (line k read as segment k+1) turn it red.
#
# Usage: scripts/test/statement-batch.sh
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "${REPO_DIR}"
GUARD=scripts/safedeps-pre-guard.sh

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1"; FAILED=1; }
FAILED=0

command -v python3 > /dev/null || { printf 'statement-batch: python3 is required\n' >&2; exit 2; }

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-statement-batch.XXXXXX")
trap 'rm -rf "${TMP_ROOT}"' EXIT
export TMPDIR="${TMP_ROOT}"
SAFEDEPS_SCAN_MARK=""
SAFEDEPS_LEX_DIVERGE=""
SAFEDEPS_LEX_CACHE=""

# --- inputs ------------------------------------------------------------------

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
n=${#INPUTS[@]}


# Every function of the guard (definitions only) and the grammar it reads.
# shellcheck source=../../lib/install-grammar.sh
source lib/install-grammar.sh
eval "$(sed -n -e '/^[a-z_][a-z_0-9]*() {$/,/^}$/p' -e '/^SAFEDEPS_INSTALL_PATTERN=/p' "${GUARD}")"

# --- the ecosystem of the first install, one grep for every segment ------

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
  # <fn> <text>: the answer, and whether the DIVERGE, flag and mark files
  # were written, as one string. The loop read its segments from a process
  # substitution and returned at the first ecosystem, and the writer still
  # lexing payloads then died of SIGPIPE when it next wrote, so how many
  # lines it left in each file depended on that timing. The gate reads the
  # DIVERGE and mark files only for being empty or not
  # (guard_readings_diverge, guard_scan_failed), and sets no flag file while
  # it asks for the ecosystem, so that is what is compared. ECO_FULL keeps
  # all.
  local dir="${TMP_ROOT}/eco.$1" out
  mkdir -p "${dir}"
  : > "${dir}/d"; : > "${dir}/u"; : > "${dir}/m"
  out=$(SAFEDEPS_LEX_DIVERGE="${dir}/d" SAFEDEPS_LEX_FLAGS="${dir}/u" SAFEDEPS_SCAN_MARK="${dir}/m" "$1" "$2"; printf 'X')
  # Each test ends in true: an assignment returns the status of its last
  # command substitution, and an empty file would end the battery here.
  ECO="${out%X}|$([[ ! -s "${dir}/d" ]] || printf D)|$([[ ! -s "${dir}/u" ]] || printf U)|$([[ ! -s "${dir}/m" ]] || printf M)"
  ECO_FULL="${out%X}|$(cat "${dir}/d")|$(cat "${dir}/u")|$(cat "${dir}/m")"
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
asked=0 differ=0 named=0 counts=0
for reading in bash zsh dash; do
  SAFEDEPS_READING="${reading}"
  for text in "${eco_inputs[@]}"; do
    eco_both ecosystem_alone "${text}"; a="${ECO}"; af="${ECO_FULL}"
    eco_both guard_detect_ecosystem "${text}"; b="${ECO}"; bf="${ECO_FULL}"
    asked=$(( asked + 1 ))
    [[ "${af}" == "${bf}" ]] || counts=$(( counts + 1 ))
    [[ "${a}" == "|"* ]] || named=$(( named + 1 ))
    if [[ "${a}" != "${b}" ]]; then
      differ=$(( differ + 1 ))
      (( differ > 5 )) || printf '# differs: %s %q: alone %q, batched %q\n' "${reading}" "${text:0:60}" "${af}" "${bf}"
    fi
  done
done
printf '# %d commands asked both ways (%d named an ecosystem), %d differ; %d left a different number of DIVERGE or mark lines\n' "${asked}" "${named}" "${differ}" "${counts}"
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
  if [[ "${a%%|*}" != "${b%%|*}" || "${a##*|}" != M || "${b##*|}" != M ]]; then
    differ=$(( differ + 1 ))
    printf '# with grep failing: %q: alone %q, batched %q\n' "${text:0:60}" "${a:0:60}" "${b:0:60}"
  fi
done
(( differ == 0 )) && pass "with grep failing, both name no ecosystem and both mark the reading" \
  || fail "with grep failing, both name no ecosystem and both mark the reading"

(( FAILED == 0 )) || exit 1
printf 'statement-batch battery: all checks passed\n'
