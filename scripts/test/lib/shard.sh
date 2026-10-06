#!/usr/bin/env bash
# safedeps: row shards, for a battery too long to finish on one host within the
# ten minutes a test run has (AGENTS.md, Testing).
#
# Sourced by the batteries that take `--shard I/M`. A row is one check the
# battery makes: an expect_* call, or one pass of a loop over forms. The battery
# numbers its rows in the order it reaches them, 1 to N, and shard I of M runs
# row n when (n - 1) mod M is I - 1. Every shard walks the whole battery and
# reaches every row in the same order; a row that is not its own checks nothing,
# and the battery goes on. Interleaving rather than cutting the list in blocks
# gives each shard a share of every section, so a section of slow rows is split
# too.
#
# A sharded battery says what it ran, so the shards can be added up:
#
#   # shard-row <n>                             each row this shard ran
#   # shard-end <I>/<M> rows <N> list <cksum>   at the end; <cksum> is of every
#                                               row's number and label, in order
#
# scripts/test/ci-verdict.sh reads those lines from the shards' logs. It fails
# unless shards 1..M of one M all printed shard-end, agree on N and the list,
# and ran rows 1..N each once. A shard that stops early prints no shard-end
# line, so the rows it did not reach count as missing, never as passed.
#
#   --shard I/M     run shard I of M
#   --shard-list    run no row; print every row this run would run as
#                   `# shard-row <n> <label>`, then the shard-end line. With
#                   --shard I/M it lists shard I's rows. This is the list
#                   scripts/test/shard-cover.sh compares with the battery's
#                   unsharded list.
#
# Without either flag a battery runs every row and prints none of this, as
# before. The flags are argv, never the environment: an exported shard would
# quietly make `npm test` run a fraction of a battery.
#
# The caller defines fail before calling shard_args.

SHARD_I=1
SHARD_M=1
SHARD_LIST=false
SHARD_ON=false
SHARD_N=0
SHARD_REST=()
SHARD_ROWS_FILE=""
SHARD_DEPTH=""

# shard_args "$@": takes --shard and --shard-list out of the arguments and
# leaves the rest in SHARD_REST.
shard_args() {
  SHARD_REST=()
  while (( $# > 0 )); do
    case "$1" in
      --shard)
        [[ "${2:-}" =~ ^([1-9][0-9]*)/([1-9][0-9]*)$ ]] || fail "--shard takes I/M (got ${2:-nothing})"
        SHARD_I="${BASH_REMATCH[1]}" SHARD_M="${BASH_REMATCH[2]}"
        (( SHARD_I <= SHARD_M )) || fail "--shard ${SHARD_I}/${SHARD_M}: I is past M"
        SHARD_ON=true
        shift 2 ;;
      --shard-list) SHARD_LIST=true SHARD_ON=true; shift ;;
      *) SHARD_REST+=("$1"); shift ;;
    esac
  done
  SHARD_DEPTH="${BASH_SUBSHELL}"
  [[ "${SHARD_ON}" == true ]] || return 0
  SHARD_ROWS_FILE=$(mktemp "${TMPDIR:-/tmp}/safedeps-shard-rows.XXXXXX") || fail "cannot create the shard row list"
}

# shard_row LABEL: counts a row and says whether this run runs it. Call it first
# in a row, as `shard_row "<label>" || return 0` in a function or
# `shard_row "<label>" || continue` in a loop. It must run in the battery's own
# shell: a count made in a subshell (a command substitution, a pipeline, a
# background job) is lost when the subshell ends, and every later row would
# take a number already used. So that is a failure, not a row.
shard_row() {
  [[ "${BASH_SUBSHELL}" == "${SHARD_DEPTH}" ]] \
    || fail "shard_row ran in a subshell (depth ${BASH_SUBSHELL}, the battery's is ${SHARD_DEPTH:-unset}): ${1:0:80}"
  SHARD_N=$(( SHARD_N + 1 ))
  [[ "${SHARD_ON}" == true ]] || return 0
  local label="${1//$'\n'/\\n}"
  printf '%s\t%s\n' "${SHARD_N}" "${label}" >> "${SHARD_ROWS_FILE}" || fail "cannot record row ${SHARD_N}"
  (( (SHARD_N - 1) % SHARD_M + 1 == SHARD_I )) || return 1
  if [[ "${SHARD_LIST}" == true ]]; then
    printf '# shard-row %s %s\n' "${SHARD_N}" "${label}"
    return 1
  fi
  printf '# shard-row %s\n' "${SHARD_N}"
}

# shard_listing: true in a list run. A list run runs no row, so a check of what
# the rows did (a request log, a floor on how many inputs were checked) has
# nothing to read there; such a check runs unless this is true.
shard_listing() { [[ "${SHARD_LIST}" == true ]]; }

# shard_end: the last line of a sharded run. Call it after the battery's last
# row, on the path a passing run takes.
shard_end() {
  [[ "${SHARD_ON}" == true ]] || return 0
  local sum
  sum=$(cksum < "${SHARD_ROWS_FILE}" | tr ' ' '-') || fail "cannot read the shard row list"
  rm -f "${SHARD_ROWS_FILE}"
  printf '# shard-end %s/%s rows %s list %s\n' "${SHARD_I}" "${SHARD_M}" "${SHARD_N}" "${sum}"
}
