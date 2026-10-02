#!/usr/bin/env bash
# safedeps: replay every command's three answers at two revisions, and require
# each one that moved to be named.
#
# scan-verdict-replay.sh compares verdicts. A verdict is one of three answers
# the gate gives, and a repair that holds the verdict can still move the other
# two: the packages a deny prescribes (an agent approves exactly those), and
# the operands the UNGATED record names once they are approved. A repair round
# once claimed a record was gone, pinned the claim with a row that read only
# the verdict, and shipped a false record in its place. So this replays the
# tuple `verdict | prescriptions | recorded operands`, the same tuple
# scripts/test/manager-variants.sh and consumer-forms' record rows read.
#
# Every moved row has to be classified, in scripts/measure/tuple-replay-classes.tsv:
#   missing   the baseline missed a check or a record this revision makes
#   false     the baseline made a check or a record of something that is no
#             package (an option value, a program argument, a local path)
#   verdict   any other move, with the reason it is right
# An unclassified move exits 1: a move nobody can name is the thing to look at.
#
# Usage:
#   scripts/measure/tuple-replay.sh <baseline-ref|baseline-dir> [--random N] [--seed S]
#
# The baseline is extracted with `git archive`, never checked out as a
# worktree (see scan-verdict-replay.sh for why).
set -uo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "${REPO_DIR}"

BASELINE="${1:-}"
[[ -n "${BASELINE}" ]] || { printf 'usage: %s <baseline-ref> [--random N] [--seed S]\n' "$0" >&2; exit 2; }
shift
RANDOM_COUNT=200
SEED=20261002
while [[ $# -gt 0 ]]; do
  case "$1" in
    --random) RANDOM_COUNT="${2:-200}"; shift 2 ;;
    --seed) SEED="${2:-20261002}"; shift 2 ;;
    *) printf 'tuple-replay: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
done
for tool in jq python3; do
  command -v "${tool}" > /dev/null || { printf 'tuple-replay: %s is required\n' "${tool}" >&2; exit 2; }
done
WORK=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-tuple-replay.XXXXXX")
trap 'rm -rf "${WORK}"' EXIT
# The baseline is a commit, or a directory holding a tree (a machine that has
# the tree without its history). A directory names itself in the class file by
# its basename's last `-` part (`.../koon-70771ef` is 70771ef).
BASE_TREE="${WORK}/baseline"
if [[ -d "${BASELINE}" ]]; then
  BASE_TREE=$(cd "${BASELINE}" && pwd)
  BASELINE_SHA=$(basename "${BASE_TREE}")
  BASELINE_SHA="${BASELINE_SHA##*-}"
else
  git rev-parse --verify "${BASELINE}^{commit}" > /dev/null 2>&1 \
    || { printf 'tuple-replay: %s is not a commit\n' "${BASELINE}" >&2; exit 2; }
  BASELINE_SHA=$(git rev-parse --short "${BASELINE}")
  mkdir -p "${BASE_TREE}"
  git archive "${BASELINE}" | tar -x -C "${BASE_TREE}"
fi
CURRENT_SHA=$(git rev-parse --short HEAD 2>/dev/null || printf 'worktree')
PROJECT="${WORK}/project"
mkdir -p "${PROJECT}"
printf '{"dependencies":{}}\n' > "${PROJECT}/package.json"
for dir in x sub; do
  mkdir -p "${PROJECT}/${dir}"
  printf '{"dependencies":{}}\n' > "${PROJECT}/${dir}/package.json"
done

# The tuple for one command at one tree, after approving every prescription,
# the loop an agent follows. A prescription the ledger refuses to write (a name
# or version it cannot validate, which a misreading can produce) ends the loop
# there, and the ledger says so on stderr. That is the same at both trees for
# the same prescription, so it cannot move a row by itself.
tuple() {
  local tree="$1" command="$2" safe out reason first="" presc="" approved eco ps iter rec
  safe=$(mktemp -d "${WORK}/safe.XXXXXX")
  for iter in 1 2 3 4 5 6; do
    out=$(cd "${tree}" && jq -nc --arg c "${command}" --arg cwd "${PROJECT}" \
      '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}' |
      HOME="${safe}/home" SAFEDEPS_HOME="${safe}" bash scripts/safedeps-pre-guard.sh 2>/dev/null) || true
    reason=$(jq -r '.hookSpecificOutput.permissionDecisionReason // empty' <<< "${out:-{\}}" 2>/dev/null) || true
    if [[ "${iter}" == 1 ]]; then
      first=$(jq -r '.hookSpecificOutput.permissionDecision // "pass"' <<< "${out:-{\}}" 2>/dev/null) || first=pass
      [[ "${reason}" != *UNDECIDED* ]] || first=undecided
      presc=$(printf '%s\n' "${reason}" | sed -nE 's/.*run `([^`]*)` first.*/\1/p' \
        | awk '{ gsub(/ && /, "\n"); print }' | awk 'NF { print $(NF-1), $NF }' | sort -u | tr '\n' ';')
    fi
    [[ "${reason}" == *"install not approved"* ]] || break
    approved=0
    while read -r eco ps; do
      [[ -n "${ps}" ]] || continue
      ( export SAFEDEPS_HOME="${safe}"
        cd "${tree}" && . lib/ledger/ledger.sh
        safedeps_ledger_write_approved_spec "${eco}" "${ps%@*}" "${ps##*@}" >/dev/null ) && approved=$((approved + 1))
    done < <(printf '%s\n' "${reason}" | sed -nE 's/.*run `([^`]*)` first.*/\1/p' \
      | awk '{ gsub(/ && /, "\n"); print }' | awk 'NF { print $(NF-1), $NF }')
    [[ "${approved}" -gt 0 ]] || break
  done
  # A record line names its operands after `Unpinned:`. Older revisions wrote
  # the line without them; such a line reads as `*`, a record that names none.
  rec=$({ grep 'pre-guard UNGATED' "${safe}/advisory.log" 2>/dev/null || true; } \
    | sed -e '/ Unpinned: /!s/.*/*/' -e 's/.* Unpinned: //' -e 's/\. Command: .*//' | sed 's/, /\n/g' \
    | sort -u | tr '\n' ' ' | sed 's/ $//')
  printf '%s | %s | %s' "${first}" "${presc}" "${rec}"
}

# The corpus: the committed one, and commands generated from a seed out of the
# places a value can stand in a manager's words, the values, and the managers.
python3 - "${SEED}" "${RANDOM_COUNT}" > "${WORK}/random.json" <<'PY'
import json, random, sys
seed, count = int(sys.argv[1]), int(sys.argv[2])
rng = random.Random(seed)
shapes = [
    "npm {o} install evil@1.0.0", "npm install {o} evil@1.0.0", "npx {o} evil@1.0.0 {a}",
    "pnpm {o} add evil@1.0.0", "pnpm dlx {o} evil@1.0.0", "yarn {o} add evil@1.0.0",
    "bun {o} add evil@1.0.0", "bunx {o} evil@1.0.0 {a}", "pip {o} install evil==1.0.0",
    "pip install {o} evil==1.0.0", "uv {o} add evil==1.0.0", "uvx {o} ruff==0.1.0 {a}",
    "pipx run {o} black==24.1.0 {a}", "cargo {o} install evil --version 1.0.0",
    "gem install {o} rake -v 13.0.0", "go run {o} example.com/m@v1.0.0 {a}", "go run ./cmd {a}",
    "npm install left-pad {o}", "pnpm add left-pad {o}", "pip install requests {o}",
]
options = ["--prefix", "--dir", "--cwd", "--cache", "--cache-dir", "--log", "--python", "--directory",
           "--config", "--install-dir", "--root", "-C", "--tag", "--filter", "--index", "--with",
           "--min-release-age", "--foo", "-x", ""]
values = ["x", "x@y", "$(echo a b)", '"a b"', "'a b'", "`echo a b`", "a\\ b", '"$(echo a b)"', '""',
          "user@example.com", "./cmd", "evil@6.6.6"]
out = []
for _ in range(count):
    shape = rng.choice(shapes)
    opt = rng.choice(options)
    val = rng.choice(values)
    o = "" if not opt else (opt + ("=" if rng.random() < 0.3 else " ") + val)
    a = rng.choice(values) if rng.random() < 0.5 else ""
    out.append({"category": "random", "command": " ".join(shape.format(o=o, a=a).split())})
print(json.dumps(out))
PY
jq -s '.[0] + .[1]' "${REPO_DIR}/scripts/measure/tuple-corpus.json" "${WORK}/random.json" > "${WORK}/all.json"
TOTAL=$(jq 'length' "${WORK}/all.json")
printf 'safedeps tuple replay\n  baseline %s -> current %s\n  corpus %s committed + %s generated (seed %s) = %s commands\n\n' \
  "${BASELINE_SHA}" "${CURRENT_SHA}" "$(jq 'length' scripts/measure/tuple-corpus.json)" "${RANDOM_COUNT}" "${SEED}" "${TOTAL}"

# Eight at a time; each command gets its own homes.
mkdir -p "${WORK}/out"
for ((idx = 0; idx < TOTAL; idx++)); do
  (
    command_text=$(jq -r ".[${idx}].command" "${WORK}/all.json")
    printf '%s\n%s\n' "$(tuple "${BASE_TREE}" "${command_text}")" "$(tuple "${REPO_DIR}" "${command_text}")" \
      > "${WORK}/out/${idx}"
  ) &
  (( (idx + 1) % 8 == 0 )) && wait
done
wait

# A class line is `<class>\t<baseline label>\t<ERE over the command>\t<ERE
# over the move>\t<reason>`, the move written `<before> => <after>`; the first
# line whose two expressions both match names the row. An empty move
# expression matches every move.
CLASSES="${REPO_DIR}/scripts/measure/tuple-replay-classes.tsv"
moved=0 unclassified=0 move=""
declare -a report=()
for ((idx = 0; idx < TOTAL; idx++)); do
  command_text=$(jq -r ".[${idx}].command" "${WORK}/all.json")
  before=$(sed -n 1p "${WORK}/out/${idx}") after=$(sed -n 2p "${WORK}/out/${idx}")
  [[ "${before}" != "${after}" ]] || continue
  moved=$((moved + 1))
  class=""
  move="${before} => ${after}"
  while IFS=$'\t' read -r cls label pattern move_pattern reason; do
    [[ -n "${cls}" && "${cls}" != \#* ]] || continue
    [[ "${label}" == "*" || "${label}" == "${BASELINE_SHA}" || "${BASELINE}" == "${label}" ]] || continue
    [[ "${command_text}" =~ ${pattern} ]] || continue
    [[ -z "${move_pattern}" || "${move}" =~ ${move_pattern} ]] || continue
    class="${cls}: ${reason}"
    break
  done < "${CLASSES}"
  if [[ -z "${class}" ]]; then
    unclassified=$((unclassified + 1))
    class="UNCLASSIFIED"
  fi
  report+=("$(printf '%s\n    %s\n    [%s] -> [%s]\n    %q' "${class}" "" "${before}" "${after}" "${command_text}")")
done
printf '%s of %s rows moved, %s unclassified\n' "${moved}" "${TOTAL}" "${unclassified}"
for line in "${report[@]+"${report[@]}"}"; do printf '  %s\n' "${line}"; done
(( unclassified == 0 )) || exit 1
exit 0
