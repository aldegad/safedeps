#!/usr/bin/env bash
# safedeps: measure where the PostToolUse effect gate crosses the hook budget.
#
# The pre-guard's cost is bound by the command text. The effect gate's is not —
# it is bound by the project's lockfile closure (N) and by the machine's own
# approved-spec ledger (L), because `safedeps_ledger_effect_check` walks every
# ledger file for every closure entry. This harness sweeps both axes and prints
# the wall clock of each stage, so the crossing point against the registered 30s
# hook timeout is a measured number rather than an impression.
#
# Usage:
#   scripts/measure/effect-gate-cost.sh <package-lock.json> [--ledger <dir>] [N...]
#
# --ledger <dir>   ledger to check against. Default: an empty throwaway dir
#                  (the floor: a machine that has approved nothing). Pass
#                  ~/.safedeps/approved-specs to read a real machine.
#
# The OSV/KEV cache is always a throwaway, so the provider column is the
# cold-cache case a real install hits for packages this machine has not queried.

set -uo pipefail

LOCKFILE="${1:-}"
if [[ -z "${LOCKFILE}" || ! -f "${LOCKFILE}" ]]; then
  printf 'usage: %s <package-lock.json> [--ledger <dir>] [N...]\n' "$0" >&2
  exit 2
fi
shift || true

LEDGER_ARG=""
SIZES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ledger) LEDGER_ARG="${2:-}"; shift 2 ;;
    *) SIZES+=("$1"); shift ;;
  esac
done
[[ ${#SIZES[@]} -eq 0 ]] && SIZES=(1 2 4 8 16 32)

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

MEASURE_HOME=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-measure.XXXXXX")
export SAFEDEPS_HOME="${MEASURE_HOME}"
export SAFEDEPS_CACHE_DIR="${MEASURE_HOME}/cache"
if [[ -n "${LEDGER_ARG}" ]]; then
  export SAFEDEPS_LEDGER_DIR="${LEDGER_ARG}"
else
  export SAFEDEPS_LEDGER_DIR="${MEASURE_HOME}/approved-specs"
  mkdir -p "${SAFEDEPS_LEDGER_DIR}"
fi

# shellcheck source=../../lib/ledger/ledger.sh
source "${REPO_DIR}/lib/ledger/ledger.sh"
# shellcheck source=../../lib/npm/closure.sh
source "${REPO_DIR}/lib/npm/closure.sh"
# shellcheck source=../../lib/providers/providers.sh
source "${REPO_DIR}/lib/providers/providers.sh"

# The sourced libs carry `set -e`; a stage returning non-zero here is data, not
# a crash, so turn it back off after sourcing.
set +e

FULL_CLOSURE=""
SLICE=""
PROVIDER_OUT=""
cleanup() {
  rm -rf "${MEASURE_HOME}"
  rm -f "${FULL_CLOSURE}" "${SLICE}" "${PROVIDER_OUT}"
}
trap cleanup EXIT

now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }

FULL_CLOSURE=$(mktemp "${TMPDIR:-/tmp}/safedeps-measure-closure.XXXXXX")
if ! safedeps_npm_lock_closure "${LOCKFILE}" > "${FULL_CLOSURE}"; then
  printf 'could not parse closure from %s\n' "${LOCKFILE}" >&2
  exit 1
fi
TOTAL=$(jq 'length' "${FULL_CLOSURE}")
LEDGER_N=$(find "${SAFEDEPS_LEDGER_DIR}" -maxdepth 1 -name '*.json' -type f 2>/dev/null | wc -l | tr -d ' ')

printf 'lockfile:        %s\n' "${LOCKFILE}"
printf 'closure size:    %s packages available\n' "${TOTAL}"
printf 'ledger:          %s (%s entries)\n' "${SAFEDEPS_LEDGER_DIR}" "${LEDGER_N}"
printf 'provider cache:  cold (throwaway)\n'
printf 'hook budget:     30s registered\n\n'
printf '%6s  %10s  %12s  %12s  %10s  %s\n' 'N' 'parse(s)' 'ledger(s)' 'osv+kev(s)' 'total(s)' 'vs 30s'

SLICE=$(mktemp "${TMPDIR:-/tmp}/safedeps-measure-slice.XXXXXX")
PROVIDER_OUT=$(mktemp "${TMPDIR:-/tmp}/safedeps-measure-provider.XXXXXX")

for n in "${SIZES[@]}"; do
  (( n > TOTAL )) && continue

  t0=$(now_ms)
  jq -c --argjson n "${n}" '.[0:$n]' "${FULL_CLOSURE}" > "${SLICE}"
  t1=$(now_ms)

  while IFS=$'\t' read -r package_name version; do
    [[ -n "${package_name}" && -n "${version}" ]] || continue
    safedeps_ledger_effect_check "npm" "${package_name}" "${version}" >/dev/null 2>&1
  done < <(jq -r '.[] | [.package, (.version | tostring)] | @tsv' "${SLICE}")
  t2=$(now_ms)

  safedeps_providers_query_batch "npm" "${SLICE}" > "${PROVIDER_OUT}" 2>/dev/null
  rc=$?
  t3=$(now_ms)

  python3 - "$n" "$t0" "$t1" "$t2" "$t3" "$rc" <<'PY'
import sys
n, t0, t1, t2, t3, rc = (int(x) for x in sys.argv[1:7])
total = (t3-t0)/1000
verdict = 'OVER' if total > 30 else 'under'
if rc != 0:
    verdict += ' [osv batch rc=%d]' % rc
print('%6d  %10.2f  %12.2f  %12.2f  %10.2f  %s' % (
    n, (t1-t0)/1000, (t2-t1)/1000, (t3-t2)/1000, total, verdict))
PY
done
