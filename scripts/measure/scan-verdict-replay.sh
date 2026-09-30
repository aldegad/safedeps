#!/usr/bin/env bash
# safedeps: replay every command's PreToolUse verdict at two revisions and diff.
#
# A change to command_scan_text changes what every detection predicate can see,
# so the only honest check on it is the verdict itself, at both revisions, on
# the same inputs. This runs the real guard -- not the extracted function -- so
# a divergence here is a divergence a user would experience.
#
# The corpus is committed next to this script (scan-corpus.json) so the counts
# this prints can be reproduced rather than taken on trust, and it carries the
# categories a scan change can plausibly move: install forms, hidden installs,
# wrapping carriers, the false-positive corpus, quoting edges, and multibyte
# text inside quotes. Randomized commands are generated from a seed on top of
# that, because a fixed corpus only ever finds what someone already thought of.
#
# Usage:
#   scripts/measure/scan-verdict-replay.sh <baseline-ref> [--random N] [--seed S]
#
#   scripts/measure/scan-verdict-replay.sh HEAD~1
#   scripts/measure/scan-verdict-replay.sh 4f95860 --random 200
#
# Exit status is 0 when no verdict moved, 1 when any did. A moved verdict is not
# automatically a defect -- it is the thing that has to be looked at and named.
#
# The baseline is extracted with `git archive` into a throwaway directory rather
# than checked out as a worktree: this script is run from inside a plan worktree
# that the author and a validator may both be holding, and adding or removing
# worktrees underneath that is how the two of them collide.
set -uo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "${REPO_DIR}"

BASELINE="${1:-}"
if [[ -z "${BASELINE}" ]]; then
  printf 'usage: %s <baseline-ref> [--random N] [--seed S]\n' "$0" >&2
  exit 2
fi
shift

RANDOM_COUNT=200
SEED=20260805
while [[ $# -gt 0 ]]; do
  case "$1" in
    --random) RANDOM_COUNT="${2:-200}"; shift 2 ;;
    --seed)   SEED="${2:-20260805}"; shift 2 ;;
    *) printf 'scan-verdict-replay: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
done

command -v jq > /dev/null || { printf 'scan-verdict-replay: jq is required\n' >&2; exit 2; }
command -v python3 > /dev/null || { printf 'scan-verdict-replay: python3 is required\n' >&2; exit 2; }
git rev-parse --verify "${BASELINE}^{commit}" > /dev/null 2>&1 \
  || { printf 'scan-verdict-replay: %s is not a commit\n' "${BASELINE}" >&2; exit 2; }

BASELINE_SHA=$(git rev-parse --short "${BASELINE}")
CURRENT_SHA=$(git rev-parse --short HEAD)

WORK=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-replay.XXXXXX")
trap 'rm -rf "${WORK}"' EXIT

BASE_TREE="${WORK}/baseline"
mkdir -p "${BASE_TREE}"
git archive "${BASELINE}" | tar -x -C "${BASE_TREE}"
[[ -f "${BASE_TREE}/scripts/safedeps-pre-guard.sh" ]] \
  || { printf 'scan-verdict-replay: baseline tree has no pre-guard\n' >&2; exit 2; }

PROJECT="${WORK}/project"
mkdir -p "${PROJECT}"
printf '{"dependencies":{}}\n' > "${PROJECT}/package.json"

# One verdict. Every call gets its own SAFEDEPS_HOME: the guard writes snapshots
# and ledger state, and a shared one would let an earlier command decide a later
# one -- which would show up as a divergence belonging to neither revision.
verdict() {
  local tree="$1" payload="$2" out safe
  safe=$(mktemp -d "${WORK}/safe.XXXXXX")
  out=$(HOME="${WORK}/home" SAFEDEPS_HOME="${safe}" \
    bash "${tree}/scripts/safedeps-pre-guard.sh" < "${payload}" 2>/dev/null)
  if [[ -z "${out}" ]]; then
    printf 'pass'
  else
    printf '%s' "$(jq -r '.hookSpecificOutput.permissionDecision // "pass"' <<< "${out}")"
  fi
}

CORPUS_FILE="${REPO_DIR}/scripts/measure/scan-corpus.json"
[[ -f "${CORPUS_FILE}" ]] || { printf 'scan-verdict-replay: corpus missing at %s\n' "${CORPUS_FILE}" >&2; exit 2; }

# Generated commands. Seeded so a rerun replays the same inputs, and shaped from
# the pieces the scan actually reasons about -- quotes, escaped quotes, escaped
# backslashes, separators, multibyte runs -- with real install text mixed in at
# both quoted and unquoted positions.
python3 - "${SEED}" "${RANDOM_COUNT}" > "${WORK}/random.json" <<'PY'
import json, random, sys

seed, count = int(sys.argv[1]), int(sys.argv[2])
rng = random.Random(seed)

installs = [
    "npm install evil@1.0.0", "pip install requests==2.0.0", "cargo add serde@1.0.0",
    "go get example.com/mod@v1.0.0", "gem install rails -v 7.0.0", "npm i left-pad@1.0.0",
]
filler = ["echo hi", "ls", "cd /tmp", "git status", "true", "printf x", "한글 텍스트", "x" * 40]
seps = [" ; ", " && ", " || ", " | ", "\n"]

def fragment():
    r = rng.random()
    body = rng.choice(installs) if rng.random() < 0.45 else rng.choice(filler)
    if r < 0.20:   return "echo '%s'" % body
    if r < 0.40:   return 'echo "%s"' % body
    if r < 0.48:   return 'echo "%s\\\\"' % body          # closing quote after an escaped backslash
    if r < 0.56:   return 'echo "a\\"%s"' % body          # escaped quote inside the region
    if r < 0.62:   return "echo \"unterminated %s" % body
    if r < 0.68:   return "echo 'unterminated %s" % body
    if r < 0.74:   return "sh -c '%s'" % body
    if r < 0.80:   return 'sh -c "%s"' % body
    if r < 0.86:   return "printf '%s' | sh" % body
    if r < 0.92:   return "eval \"%s\"" % body
    return body

out = []
for i in range(count):
    n = rng.randint(1, 4)
    cmd = rng.choice(seps).join(fragment() for _ in range(n))
    out.append({"category": "random", "command": cmd})
print(json.dumps(out))
PY

jq -s '.[0] + .[1]' "${CORPUS_FILE}" "${WORK}/random.json" > "${WORK}/all.json"
TOTAL=$(jq 'length' "${WORK}/all.json")

printf 'safedeps verdict replay\n'
printf '  baseline %s -> current %s\n' "${BASELINE_SHA}" "${CURRENT_SHA}"
printf '  corpus %s committed + %s generated (seed %s) = %s commands\n\n' \
  "$(jq 'length' "${CORPUS_FILE}")" "${RANDOM_COUNT}" "${SEED}" "${TOTAL}"

payload="${WORK}/payload.json"
moved=0
declare -a moved_lines=()
counts_file="${WORK}/counts"
: > "${counts_file}"

for ((idx = 0; idx < TOTAL; idx++)); do
  category=$(jq -r ".[${idx}].category" "${WORK}/all.json")
  command_text=$(jq -r ".[${idx}].command" "${WORK}/all.json")
  jq -nc --arg c "${command_text}" --arg cwd "${PROJECT}" \
    '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}' > "${payload}"

  before=$(verdict "${BASE_TREE}" "${payload}")
  after=$(verdict "${REPO_DIR}" "${payload}")
  printf '%s\t%s\n' "${category}" "${before}" >> "${counts_file}"

  if [[ "${before}" != "${after}" ]]; then
    moved=$((moved + 1))
    moved_lines+=("$(printf '%-14s %s -> %s\n    %q' "${category}" "${before}" "${after}" "${command_text}")")
  fi
done

printf 'baseline verdict distribution by category:\n'
sort "${counts_file}" | uniq -c | sed 's/^/  /'
printf '\n'

if [[ ${moved} -eq 0 ]]; then
  printf 'no verdict moved: %s/%s identical\n' "${TOTAL}" "${TOTAL}"

  # A zero from a harness that cannot produce a non-zero says nothing about the
  # code, only about itself. So produce one: neuter the scan in the throwaway
  # baseline copy -- it now returns the command unblanked, which is the single
  # most consequential thing this function can get wrong, since quoted text
  # starts reading as executable -- and require the same corpus to move.
  # Running this always, rather than behind a flag, is deliberate: a control
  # nobody remembers to pass is a control that is not there.
  python3 - "${BASE_TREE}/scripts/safedeps-pre-guard.sh" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
start = s.index('command_scan_text() {')
depth, i = 0, start
while True:
    if s[i] == '{': depth += 1
    elif s[i] == '}':
        depth -= 1
        if depth == 0: break
    i += 1
neutered = 'command_scan_text() {\n  printf \'%s\' "$1"\n}'
open(p, 'w').write(s[:start] + neutered + s[i + 1:])
PY

  control_moved=0
  for ((idx = 0; idx < TOTAL; idx++)); do
    command_text=$(jq -r ".[${idx}].command" "${WORK}/all.json")
    jq -nc --arg c "${command_text}" --arg cwd "${PROJECT}" \
      '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}' > "${payload}"
    [[ "$(verdict "${BASE_TREE}" "${payload}")" != "$(verdict "${REPO_DIR}" "${payload}")" ]] \
      && control_moved=$((control_moved + 1))
  done

  if [[ ${control_moved} -eq 0 ]]; then
    printf 'CONTROL FAILED: a scan that blanks nothing moved no verdict either.\n'
    printf 'The zero above measures this harness, not the change. Do not cite it.\n'
    exit 2
  fi
  printf 'control: a scan that blanks nothing moves %s/%s verdicts, so the replay can fail\n' \
    "${control_moved}" "${TOTAL}"
  exit 0
fi

printf '%s verdict(s) moved:\n' "${moved}"
for line in "${moved_lines[@]}"; do printf '  %s\n' "${line}"; done
exit 1
