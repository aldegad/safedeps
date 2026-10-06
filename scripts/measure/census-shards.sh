#!/usr/bin/env bash
# safedeps: the census in shards -- combine them, and show they cover the census.
#
# The host runner (scripts/ci/run-on-hosts.sh) splits the quick scan-failure
# census across machines (scan-failure-census.sh --shard I/M --out DIR).
# Splitting it is only safe while the shards together make every run the
# unsharded census makes, and while the one check a shard cannot judge alone,
# idle-mode, is still judged.
#
#   combine DIR...   the shards' --out directories, from one run. Fails
#                    unless they are shards 1..M of the same M, once each; all
#                    hold the same cases and the same list of every failing run;
#                    the failing runs they made, together, are exactly that
#                    list, none twice; and every mode in the list failed at
#                    least one call over all shards (idle-mode, which the
#                    census header explains).
#   cover [--shards M] [--quick]
#                    the list comparison. Runs the census with --list once
#                    unsharded and once per shard of M (default 2), each time
#                    from its own clean runs, and fails unless the union of the
#                    shards' lists is the unsharded list as a set, and no
#                    failing run is in two shards. The clean and counting runs
#                    are in every shard's list on purpose: every shard makes
#                    them, as the baseline of its failing runs.
#
# combine runs no guard and needs only bash, awk, sort and comm. cover runs the
# clean and counting runs M+1 times, so it is a measurement: run it on a host
# you may test on, not on a shared developer machine.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CENSUS="${ROOT_DIR}/scripts/measure/scan-failure-census.sh"

die() { printf 'census-shards: %s\n' "$1" >&2; exit 1; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/census-shards.XXXXXX")
trap 'rm -rf "${TMP}"' EXIT
# A line of the census's --list output: "<case number>:<cksum>-<size> <mode> <K>".
LIST_LINE='^[0-9]+:[0-9]+-[0-9]+ [a-z-]+ [0-9]+$'

combine() {
  (( $# > 0 )) || die "combine needs the shards' --out directories"
  local tmp="${TMP}" dir m="" i shard_m seen="" first="" f
  for dir in "$@"; do
    for f in shard cases jobs ran hits; do
      [[ -f "${dir}/${f}" ]] || die "${dir} has no ${f} file; it is not a census --out directory, or its shard did not finish"
    done
    read -r i shard_m < "${dir}/shard"
    [[ -n "${m}" ]] || m="${shard_m}"
    [[ "${shard_m}" == "${m}" ]] || die "${dir} is shard ${i}/${shard_m}, the others are of ${m}"
    case " ${seen} " in *" ${i} "*) die "shard ${i}/${m} appears twice" ;; esac
    seen="${seen} ${i}"
    if [[ -z "${first}" ]]; then
      first="${dir}"
    else
      cmp -s "${first}/cases" "${dir}/cases" || die "${dir} judged other cases than ${first}"
      cmp -s "${first}/jobs" "${dir}/jobs" || die "${dir} listed other failing runs than ${first} (its clean runs counted other readings)"
    fi
    grep -v -E ' (none|count) 0$' "${dir}/ran" >> "${tmp}/ran" || true
    cat "${dir}/hits" >> "${tmp}/hits"
  done
  (( $# == m )) || die "$# shard directories for ${m} shards"
  for (( i = 1; i <= m; i++ )); do
    case " ${seen} " in *" ${i} "*) ;; *) die "shard ${i}/${m} is missing" ;; esac
  done

  sort "${first}/jobs" > "${tmp}/want"
  sort "${tmp}/ran" > "${tmp}/got"
  local twice missing extra
  twice=$(uniq -d "${tmp}/got" | head -n 5)
  [[ -z "${twice}" ]] || die "failing runs made by two shards, first: ${twice//$'\n'/; }"
  missing=$(comm -23 "${tmp}/want" "${tmp}/got" | head -n 5)
  extra=$(comm -13 "${tmp}/want" "${tmp}/got" | head -n 5)
  [[ -z "${missing}" ]] || die "failing runs no shard made, first: ${missing//$'\n'/; }"
  [[ -z "${extra}" ]] || die "failing runs outside the census list, first: ${extra//$'\n'/; }"

  local idle
  idle=$(awk 'FNR == NR { mode[$2] = 1; next } { hits[$1] += $2 }
    END { for (m in mode) if (hits[m] + 0 == 0) print m }' "${first}/jobs" "${tmp}/hits" | sort)
  printf 'census shards: %d of %d, %d cases, %d failing runs, each made once\n' \
    "$#" "${m}" "$(wc -l < "${first}/cases" | tr -d ' ')" "$(wc -l < "${tmp}/want" | tr -d ' ')"
  if [[ -n "${idle}" ]]; then
    printf '  idle-mode        %d\n' "$(wc -l <<< "${idle}" | tr -d ' ')"
    while IFS= read -r f; do printf '  idle-mode\t%s failed no call in any run of any shard\n' "${f}"; done <<< "${idle}"
    exit 1
  fi
  printf '  idle-mode        0\n'
}

cover() {
  local shards=2 quick=() i tmp="${TMP}"
  while (( $# > 0 )); do
    case "$1" in
      --shards) [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || die "--shards needs a whole number"; shards="$2"; shift 2 ;;
      --quick) quick=(--quick); shift ;;
      *) die "cover takes --shards M and --quick" ;;
    esac
  done
  bash "${CENSUS}" ${quick[@]+"${quick[@]}"} --list | grep -E "${LIST_LINE}" | sort > "${tmp}/unsharded"
  : > "${tmp}/union"
  for (( i = 1; i <= shards; i++ )); do
    bash "${CENSUS}" ${quick[@]+"${quick[@]}"} --shard "${i}/${shards}" --list | grep -E "${LIST_LINE}" \
      | sort > "${tmp}/shard.${i}"
    printf '  shard %d/%d: %d runs (%d failing)\n' "${i}" "${shards}" "$(wc -l < "${tmp}/shard.${i}" | tr -d ' ')" \
      "$(grep -c -v -E ' (none|count) 0$' "${tmp}/shard.${i}" || true)"
    cat "${tmp}/shard.${i}" >> "${tmp}/union"
  done
  local failing_twice
  failing_twice=$(grep -v -E ' (none|count) 0$' "${tmp}/union" | sort | uniq -d | head -n 5)
  sort -u "${tmp}/union" > "${tmp}/union.set"
  printf 'unsharded: %d runs (%d failing)\n' "$(wc -l < "${tmp}/unsharded" | tr -d ' ')" \
    "$(grep -c -v -E ' (none|count) 0$' "${tmp}/unsharded" || true)"
  [[ -s "${tmp}/unsharded" ]] || die "the unsharded census listed no runs"
  [[ -z "${failing_twice}" ]] || die "failing runs in two shards, first: ${failing_twice//$'\n'/; }"
  if ! diff -u "${tmp}/unsharded" "${tmp}/union.set" > "${tmp}/diff"; then
    head -n 40 "${tmp}/diff" >&2
    die "the shards' union is not the unsharded list"
  fi
  printf 'the %d shards cover the unsharded census: same (case, mode, K) set, no failing run twice\n' "${shards}"
}

case "${1:-}" in
  combine) shift; combine "$@" ;;
  cover) shift; cover "$@" ;;
  *) printf 'usage: %s combine DIR... | cover [--shards M] [--quick]\n' "$0" >&2; exit 2 ;;
esac
