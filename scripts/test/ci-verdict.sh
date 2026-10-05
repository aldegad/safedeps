#!/usr/bin/env bash
# safedeps: the CI verdict for one OS -- did the split jobs run everything?
#
# CI runs the batteries in groups (run-all.sh --group) and the census in shards
# (scan-failure-census.sh --shard), one job each. A green job says only that
# what it ran passed. This says that together they ran what `npm run
# test:release` runs: every battery with a CI group in run-all.sh, each once,
# and every run of the census, through census-shards.sh combine.
#
#   ci-verdict.sh DIR
#
# DIR holds the jobs' uploads for one OS: the battery groups' log directories
# (each battery leaves <name>.rc there when it finishes) and the census shards'
# --out directories (each holds a `shard` file). They are found by those files,
# at any depth, so the layout the download step chose does not matter.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
dir="${1:?usage: ci-verdict.sh DIR}"
[[ -d "${dir}" ]] || { printf 'ci-verdict: %s is not a directory\n' "${dir}" >&2; exit 2; }

want=$(bash "${ROOT_DIR}/scripts/test/run-all.sh" --list --ci | sort)
got=$(find "${dir}" -type f -name '*.rc' | sed -e 's#.*/##' -e 's#\.rc$##' | sort)
twice=$(uniq -d <<< "${got}")
missing=$(comm -23 <(printf '%s\n' "${want}") <(printf '%s\n' "${got}" | sort -u))
extra=$(comm -13 <(printf '%s\n' "${want}") <(printf '%s\n' "${got}" | sort -u))
fail=0
[[ -z "${twice}" ]] || { printf 'ci-verdict: batteries run by two jobs: %s\n' "${twice//$'\n'/ }" >&2; fail=1; }
[[ -z "${missing}" ]] || { printf 'ci-verdict: batteries no job ran: %s\n' "${missing//$'\n'/ }" >&2; fail=1; }
[[ -z "${extra}" ]] || { printf 'ci-verdict: batteries run-all.sh --list --ci does not name: %s\n' "${extra//$'\n'/ }" >&2; fail=1; }
(( fail == 0 )) && printf 'batteries: %d, each run by one job\n' "$(wc -l <<< "${want}" | tr -d ' ')"

shards=()
while IFS= read -r f; do shards+=("${f%/shard}"); done < <(find "${dir}" -type f -name shard | sort)
(( ${#shards[@]} > 0 )) || { printf 'ci-verdict: no census shard directory under %s\n' "${dir}" >&2; exit 1; }
bash "${ROOT_DIR}/scripts/measure/census-shards.sh" combine "${shards[@]}" || fail=1
exit "${fail}"
