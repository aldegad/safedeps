#!/usr/bin/env bash
# safedeps: show that a battery's row shards cover the battery.
#
#   shard-cover.sh [BATTERY...]
#
# For each battery that scripts/test/run-all.sh splits into row shards (all of
# them when none is named), this lists the battery's rows once unsharded and
# once per shard of the table's M, each from a run of its own with
# --shard-list (scripts/test/lib/shard.sh), and fails unless:
#
#   - every list run ended with its shard-end line, and all of them counted the
#     same rows with the same list cksum
#   - the union of the shards' lists is the unsharded list: the same (row
#     number, label) pairs, so no row is lost and none is made up
#   - no row is in two shards' lists
#
# This is the list comparison behind the runner's split; scripts/test/ci-verdict.sh
# checks the same sums on the rows each shard of a real run says it ran.
#
# A list run runs no row, but it runs what a battery does outside its rows
# (setup, fixtures, the few checks that are not rows), so it is a test run: run
# it on a host you may test on.
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "${ROOT_DIR}" || exit 2
TMP=$(mktemp -d "${TMPDIR:-/tmp}/shard-cover.XXXXXX") || exit 2
trap 'rm -rf "${TMP}"' EXIT

fail=0
red() { printf 'shard-cover: %s\n' "$1" >&2; fail=1; }

# <battery> <M> <script>, for each battery the table splits into row shards.
table=$(bash scripts/test/run-all.sh --units --release | sed -n 's/^\([a-z][a-z0-9-]*\)@1of\([0-9]*\)$/\1 \2/p' | grep -v '^census ')
(( $# == 0 )) || table=$(for b in "$@"; do grep "^${b} " <<< "${table}" || red "${b} is not split into row shards"; done)
[[ -n "${table}" ]] || { red "no battery to compare"; exit 1; }

list_run() { # battery out-file args...
  local battery="$1" out="$2"
  shift 2
  bash "scripts/test/${battery}.sh" --shard-list "$@" > "${out}.log" 2>&1
  printf '%s\n' "$?" > "${out}.rc"
  grep '^# shard-row ' "${out}.log" | sed 's/^# shard-row //' | sort > "${out}.rows"
  grep '^# shard-end ' "${out}.log" | sed 's/^# shard-end [0-9]*\/[0-9]* //' > "${out}.end"
}

while read -r battery m _; do
  [[ -n "${battery}" ]] || continue
  list_run "${battery}" "${TMP}/${battery}.all"
  for (( i = 1; i <= m; i++ )); do
    list_run "${battery}" "${TMP}/${battery}.${i}" --shard "${i}/${m}"
  done
  bad=0
  for f in "${TMP}/${battery}".*.rc; do
    run="${f%.rc}"
    [[ "$(cat "${f}")" == 0 ]] || { red "${battery}: the list run $(basename "${run}") exited $(cat "${f}"): $(tail -n 3 "${run}.log" | tr '\n' ' ')"; bad=1; }
    [[ "$(wc -l < "${run}.end" | tr -d ' ')" == 1 ]] || { red "${battery}: the list run $(basename "${run}") printed no single shard-end line"; bad=1; }
    cmp -s "${run}.end" "${TMP}/${battery}.all.end" \
      || { red "${battery}: $(basename "${run}") counted [$(cat "${run}.end")], the unsharded list [$(cat "${TMP}/${battery}.all.end")]"; bad=1; }
  done
  cat "${TMP}/${battery}".[0-9]*.rows | sort > "${TMP}/${battery}.union"
  twice=$(cut -d' ' -f1 "${TMP}/${battery}.union" | uniq -d | head -n 5)
  [[ -z "${twice}" ]] || { red "${battery}: rows in two shards' lists, first: ${twice//$'\n'/ }"; bad=1; }
  if ! diff "${TMP}/${battery}.all.rows" <(sort -u "${TMP}/${battery}.union") > "${TMP}/${battery}.diff"; then
    red "${battery}: the shards' union is not the unsharded list; first differences: $(head -n 6 "${TMP}/${battery}.diff" | tr '\n' ' ' | cut -c1-400)"
    bad=1
  fi
  (( bad == 1 )) || printf '%s: %d shards cover the unsharded list of %d rows, each row in one shard (%s)\n' \
    "${battery}" "${m}" "$(wc -l < "${TMP}/${battery}.all.rows" | tr -d ' ')" "$(cat "${TMP}/${battery}.all.end")"
done <<< "${table}"
exit "${fail}"
