#!/usr/bin/env bash
# safedeps: the verdict of a run on our hosts -- did the units add up to the set?
#
#   ci-verdict.sh [--release] DIR
#
# scripts/ci/run-on-hosts.sh splits a set into units (scripts/test/run-all.sh
# --units) and runs them on several hosts. A unit that passed says only that
# what it ran passed. This says that together the units ran the set: every unit
# once, each green, no row skipped that is not named below, the row shards of
# every split battery adding up to the whole battery, the census shards adding
# up to the whole census, and no host lost on the way.
#
# DIR holds what the runner collected: each unit's <unit>.rc and <unit>.log
# (and .secs, .load-start, .load-end), a census shard's <unit>.out directory,
# at any depth, and the runner's own record in DIR/coordinator: <unit>.failed
# for a unit it saw fail (lost, stopped, its host gone) and host-<name>.dead
# for a host that failed.
#
# Red when any of these holds:
#   - a host failed, or the runner recorded a unit as failed
#   - a unit of the set left no exit status, or left two
#   - a unit exited non-zero or printed a `not ok` line
#   - a unit printed a skipped row SKIP_ALLOWED does not name
#   - the row shards of a battery do not add up: shards 1..M of one M must all
#     print their shard-end line, agree on the number of rows and the list, and
#     run each row once (scripts/test/lib/shard.sh)
#   - the census shards do not combine (scripts/measure/census-shards.sh)
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
set_flag=""
[[ "${1:-}" != --release ]] || { set_flag=--release; shift; }
dir="${1:?usage: ci-verdict.sh [--release] DIR}"
[[ -d "${dir}" ]] || { printf 'ci-verdict: %s is not a directory\n' "${dir}" >&2; exit 2; }

# A battery skips a row it cannot run here with an `ok` line that says SKIPPED
# (or a TAP `# SKIP`), so neither its exit status nor its counts show the row is
# gone. When CI put gitleaks in one group alone, e2e's pre-commit gate rows
# printed `ok ... SKIPPED` on both OSes and every job was green (run
# 37297541785). So a skipped row is red unless it is named here, as
# <battery>|<the whole line>. Only a row whose skip follows from the host and
# not from what is installed on it belongs here.
SKIP_ALLOWED=(
  # Root is exempt from the process limit the row sets; a host that runs the
  # suite as root skips it.
  "hook-entry|ok - out-of-processes row SKIPPED (the process limit does not bind this user)"
)

fail=0
red() { printf 'ci-verdict: %s\n' "$1" >&2; fail=1; }

units=$(bash "${ROOT_DIR}/scripts/test/run-all.sh" --units ${set_flag}) || { red "run-all.sh --units failed"; exit 1; }

# --- hosts and the runner's record -------------------------------------------------
while IFS= read -r f; do
  [[ -n "${f}" ]] || continue
  name=$(basename "${f}" .dead); name="${name#host-}"
  red "host ${name} failed: $(head -c 300 "${f}")"
done < <(find "${dir}" -type f -name 'host-*.dead' | sort)
while IFS= read -r f; do
  [[ -n "${f}" ]] || continue
  red "$(basename "${f}" .failed) failed: $(head -c 300 "${f}")"
done < <(find "${dir}" -type f -name '*.failed' | sort)

# --- every unit once, green ----------------------------------------------------------
got=$(find "${dir}" -type f -name '*.rc' | sed -e 's#.*/##' -e 's#\.rc$##' | sort)
twice=$(uniq -d <<< "${got}")
missing=$(comm -23 <(sort <<< "${units}") <(sort -u <<< "${got}"))
extra=$(comm -13 <(sort <<< "${units}") <(sort -u <<< "${got}") | grep -v '^$' || true)
[[ -z "${twice}" ]] || red "units run twice: ${twice//$'\n'/ }"
[[ -z "${missing}" ]] || red "units that left no exit status: ${missing//$'\n'/ }"
[[ -z "${extra}" ]] || red "units the set does not have: ${extra//$'\n'/ }"

printf '# %-30s %-10s %4s %5s %7s %6s  %-20s %s\n' unit host rc ok 'not ok' secs 'load at start' 'load at end'
skips=0
while IFS= read -r rc_file; do
  [[ -n "${rc_file}" ]] || continue
  unit=$(basename "${rc_file}" .rc)
  base="${rc_file%.rc}"
  host=$(basename "$(dirname "${rc_file}")")
  rc=$(cat "${rc_file}")
  log="${base}.log"
  if [[ ! -f "${log}" ]]; then
    red "${unit} left no log"
    continue
  fi
  ok=$(grep -c '^ok' "${log}")
  not_ok=$(grep -c '^not ok' "${log}")
  printf '# %-30s %-10s %4s %5s %7s %6s  %-20s %s\n' "${unit}" "${host}" "${rc}" "${ok}" "${not_ok}" \
    "$(cat "${base}.secs" 2>/dev/null || printf '?')" \
    "$(cat "${base}.load-start" 2>/dev/null || printf '?')" "$(cat "${base}.load-end" 2>/dev/null || printf '?')"
  [[ "${rc}" == 0 ]] || red "${unit} exited ${rc}"
  [[ "${not_ok}" == 0 ]] || red "${unit} printed ${not_ok} not ok line(s)"
  battery="${unit%%@*}"
  grep_rc=0
  lines=$(grep -E '^ok .*(SKIPPED|# SKIP)' "${log}") || grep_rc=$?
  (( grep_rc <= 1 )) || { red "cannot read ${log} (grep exit ${grep_rc})"; continue; }
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    skips=$((skips + 1))
    allowed=false
    for entry in "${SKIP_ALLOWED[@]}"; do
      [[ "${entry}" != "${battery}|${line}" ]] || allowed=true
    done
    [[ "${allowed}" == true ]] || red "${unit} skipped a row: ${line}"
  done <<< "${lines}"
done < <(find "${dir}" -type f -name '*.rc' | sort)
printf 'units: %d in the set; skipped rows: %d\n' "$(grep -c . <<< "${units}")" "${skips}"

# --- row shards ------------------------------------------------------------------------
# For each battery split into M > 1 row shards (not the census, which has its
# own shards), the shards' logs must add up to the whole battery.
for battery in $(sed -n 's/@.*//p' <<< "${units}" | sort -u); do
  [[ "${battery}" != census ]] || continue
  m=$(grep -m1 "^${battery}@" <<< "${units}" | sed 's/.*of//')
  logs=()
  for (( i = 1; i <= m; i++ )); do
    log=$(find "${dir}" -type f -name "${battery}@${i}of${m}.log" | head -n 1)
    [[ -n "${log}" ]] || continue 2
    logs+=("${log}")
  done
  if ! out=$(awk -v m="${m}" '
      FNR == 1 { file++ }
      /^# shard-end / {
        ends[file]++
        split($3, im, "/"); if (im[1] != file || im[2] != m) bad = bad sprintf(" shard %d says it is %s;", file, $3)
        if (rows == "") { rows = $5; list = $7 }
        else if ($5 != rows || $7 != list) bad = bad sprintf(" shard %d counted %s rows (list %s), shard 1 %s (list %s);", file, $5, $7, rows, list)
        next
      }
      /^# shard-row [0-9]+$/ { ran[$3]++; next }
      END {
        for (f = 1; f <= m; f++) if (ends[f] != 1) bad = bad sprintf(" shard %d/%d printed %d shard-end lines;", f, m, ends[f] + 0)
        if (rows == "") { print "no shard-end line in any shard"; exit 1 }
        for (n = 1; n <= rows; n++) {
          if (!(n in ran)) { missing++; if (missing <= 5) bad = bad sprintf(" row %d ran in no shard;", n) }
          else if (ran[n] > 1) bad = bad sprintf(" row %d ran in %d shards;", n, ran[n])
        }
        for (n in ran) if (n + 0 < 1 || n + 0 > rows) bad = bad sprintf(" row %s is past the %d rows;", n, rows)
        if (bad != "") { print bad; exit 1 }
        printf "%d rows, each run once over %d shards", rows, m
      }' "${logs[@]}"); then
    red "${battery}: the row shards do not add up:${out}"
  else
    printf '%s: %s\n' "${battery}" "${out}"
  fi
done

# --- census shards ---------------------------------------------------------------------
if grep -q '^census@' <<< "${units}"; then
  shards=()
  while IFS= read -r f; do [[ -n "${f}" ]] && shards+=("${f%/shard}"); done \
    < <(find "${dir}" -type f -path '*/census@*.out/shard' | sort)
  if (( ${#shards[@]} == 0 )); then
    red "no census shard left its output directory"
  else
    bash "${ROOT_DIR}/scripts/measure/census-shards.sh" combine "${shards[@]}" || red "the census shards do not combine"
  fi
elif grep -qx census <<< "${units}"; then
  :  # an unsharded census is one unit like any other battery
fi

exit "${fail}"
