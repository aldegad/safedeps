#!/usr/bin/env bash
# safedeps: the CI verdict for one OS -- did the split jobs run everything?
#
# CI runs the batteries in groups (run-all.sh --group) and the census in shards
# (scan-failure-census.sh --shard), one job each. A green job says only that
# what it ran passed. This says that together they ran what `npm run
# test:release` runs: every battery with a CI group in run-all.sh, each once,
# with no skipped row but the ones named below, and every run of the census,
# through census-shards.sh combine.
#
#   ci-verdict.sh DIR
#
# DIR holds the jobs' uploads for one OS: the battery groups' log directories
# (each battery leaves <name>.rc and <name>.log there when it finishes) and the
# census shards' --out directories (each holds a `shard` file). They are found
# by those files, at any depth, so the layout the download step chose does not
# matter.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
dir="${1:?usage: ci-verdict.sh DIR}"
[[ -d "${dir}" ]] || { printf 'ci-verdict: %s is not a directory\n' "${dir}" >&2; exit 2; }

# A battery skips a row it cannot run here with an `ok` line that says SKIPPED
# (or a TAP `# SKIP`), so neither its exit status nor run-all's summary shows
# the row is gone. When the split put gitleaks in group a alone, e2e's
# pre-commit gate rows printed `ok ... SKIPPED` on both OSes in group b and every
# job was green (run 37297541785). So a skipped row fails the verdict unless it
# is named here, as <battery>|<the whole line>. Only a row whose skip follows
# from the runner and not from what the workflow installs belongs here.
SKIP_ALLOWED=(
  # Root is exempt from the process limit the row sets; GitHub's runners do
  # not run the suite as root, so this is for a runner that does.
  "hook-entry|ok - out-of-processes row SKIPPED (the process limit does not bind this user)"
)

want=$(bash "${ROOT_DIR}/scripts/test/run-all.sh" --list --ci | sort)
# want comes from the table, so a battery whose CI group became `-` would
# leave it, and CI, with nothing red. The release set outside the CI groups is
# the census alone, which the shards below account for.
release=$(bash "${ROOT_DIR}/scripts/test/run-all.sh" --list --release | sort)
outside=$(comm -23 <(printf '%s\n' "${release}") <(printf '%s\n' "${want}"))
got=$(find "${dir}" -type f -name '*.rc' | sed -e 's#.*/##' -e 's#\.rc$##' | sort)
twice=$(uniq -d <<< "${got}")
missing=$(comm -23 <(printf '%s\n' "${want}") <(printf '%s\n' "${got}" | sort -u))
extra=$(comm -13 <(printf '%s\n' "${want}") <(printf '%s\n' "${got}" | sort -u))
fail=0
[[ -z "${twice}" ]] || { printf 'ci-verdict: batteries run by two jobs: %s\n' "${twice//$'\n'/ }" >&2; fail=1; }
[[ -z "${missing}" ]] || { printf 'ci-verdict: batteries no job ran: %s\n' "${missing//$'\n'/ }" >&2; fail=1; }
[[ -z "${extra}" ]] || { printf 'ci-verdict: batteries run-all.sh --list --ci does not name: %s\n' "${extra//$'\n'/ }" >&2; fail=1; }
[[ "${outside}" == census ]] || {
  printf 'ci-verdict: run-all.sh --list --release outside --list --ci is not the census alone: %s\n' "${outside//$'\n'/ }" >&2
  fail=1
}
(( fail == 0 )) && printf 'batteries: %d, each run by one job\n' "$(wc -l <<< "${want}" | tr -d ' ')"

skip_fail=0 skips=0
while IFS= read -r rc_file; do
  [[ -n "${rc_file}" ]] || continue
  name=$(basename "${rc_file}" .rc)
  log="${rc_file%.rc}.log"
  [[ -f "${log}" ]] || { printf 'ci-verdict: %s left no log to read its skipped rows from\n' "${name}" >&2; skip_fail=1; continue; }
  grep_rc=0
  lines=$(grep -E '^ok .*(SKIPPED|# SKIP)' "${log}") || grep_rc=$?
  (( grep_rc <= 1 )) || { printf 'ci-verdict: cannot read %s (grep exit %d)\n' "${log}" "${grep_rc}" >&2; skip_fail=1; continue; }
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    skips=$((skips + 1))
    allowed=false
    for entry in "${SKIP_ALLOWED[@]}"; do
      [[ "${entry}" != "${name}|${line}" ]] || allowed=true
    done
    [[ "${allowed}" == true ]] || { printf 'ci-verdict: %s skipped a row: %s\n' "${name}" "${line}" >&2; skip_fail=1; }
  done <<< "${lines}"
done < <(find "${dir}" -type f -name '*.rc' | sort)
if (( skip_fail == 0 )); then
  printf 'skipped rows: %d, each one named in SKIP_ALLOWED\n' "${skips}"
else
  fail=1
fi

shards=()
while IFS= read -r f; do shards+=("${f%/shard}"); done < <(find "${dir}" -type f -name shard | sort)
(( ${#shards[@]} > 0 )) || { printf 'ci-verdict: no census shard directory under %s\n' "${dir}" >&2; exit 1; }
bash "${ROOT_DIR}/scripts/measure/census-shards.sh" combine "${shards[@]}" || fail=1
exit "${fail}"
