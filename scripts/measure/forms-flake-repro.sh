#!/usr/bin/env bash
# safedeps: hunt the intermittent consumer-forms failure, and preserve the one
# thing that can explain it.
#
# Observed: 3 failures in 52 runs of `scripts/test/consumer-forms.sh`, condition
# unmeasured. Three different assertions, all in the `logged_ungated` family,
# all the same direction -- a command that must stay quiet saw an `UNGATED` line.
#
# `grep -q 'UNGATED' "${safe}/advisory.log"` becomes true two ways, and they
# call for opposite fixes:
#
#   (a) the sandbox was contaminated -- the line belongs to a DIFFERENT command
#   (b) the verdict is nondeterministic -- the quiet command logged it ITSELF
#
# The `UNGATED` record names its ecosystem and its command, so one line settles
# it. The suite's own trap deletes that evidence on the way out, which is why
# every failure so far has been re-run blind. This keeps the sandbox of a failing
# trial and prints its records.
#
# Usage:
#   scripts/measure/forms-flake-repro.sh [runs]         # hunt
#   scripts/measure/forms-flake-repro.sh --self-test    # prove it can fail
#
# --self-test is not optional politeness. A hunt that reports "0 failures"
# proves nothing unless the harness can produce a failure at all, and an earlier
# version of this measurement reported a clean 27 runs while its own control was
# silently broken. Run the self-test before quoting a zero.

set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "${ROOT_DIR}"

KEEP_DIR="${TMPDIR:-/tmp}/safedeps-flake-evidence"
mkdir -p "${KEEP_DIR}"

# A copy of the suite whose cleanup keeps the sandbox when the run failed. The
# copy also hardcodes ROOT_DIR, since it no longer sits inside the repo.
build_probe() {
  local dest="$1"
  sed -e "s|^ROOT_DIR=.*|ROOT_DIR=\"${ROOT_DIR}\"|" \
      -e 's|^  rm -rf "${tmp_root}"|  if [[ "${PROBE_FAILED:-0}" = 1 ]]; then printf "PRESERVED %s\\n" "${tmp_root}" >\&2; else rm -rf "${tmp_root}"; fi|' \
      -e 's|^  exit 1|  PROBE_FAILED=1; exit 1|' \
      "${ROOT_DIR}/scripts/test/consumer-forms.sh" > "${dest}"
}

# Read the evidence a failing trial left: which command each UNGATED line names.
read_evidence() {
  local log="$1"
  local kept
  kept=$(grep -o 'PRESERVED .*' "${log}" | awk '{print $2}' | head -1)
  if [[ -z "${kept}" ]]; then
    printf '  (no sandbox preserved -- the failure was not an assertion)\n'
    return
  fi
  printf '  sandbox: %s\n' "${kept}"
  local f
  while IFS= read -r f; do
    grep -q 'UNGATED' "${f}" 2>/dev/null || continue
    printf '  %s\n' "${f#"${kept}"/}"
    sed 's/^/    /' "${f}"
  done < <(find "${kept}" -name advisory.log 2>/dev/null)
  printf '  --> if a line names the quiet command itself, the verdict is\n'
  printf '      nondeterministic (b). If it names another command, the sandbox\n'
  printf '      was contaminated (a).\n'
}

probe="${KEEP_DIR}/forms-probe.sh"
build_probe "${probe}"

if [[ "${1:-}" == "--self-test" ]]; then
  # Turn one quiet case loud. The suite must go red and preserve its sandbox;
  # anything else means a zero from this harness is meaningless.
  ctl="${KEEP_DIR}/forms-probe-selftest.sh"
  sed 's|^  "pip install ./local-pkg" \\|  "pip install definitely-unpinned-evil" \\|' "${probe}" > "${ctl}"
  if ! grep -q 'definitely-unpinned-evil' "${ctl}"; then
    printf 'SELF-TEST INCONCLUSIVE: the substitution did not apply, so this\n'
    printf 'proves nothing about the harness.\n' >&2
    exit 2
  fi
  out="${KEEP_DIR}/selftest.log"
  if bash "${ctl}" > "${out}" 2>&1; then
    printf 'SELF-TEST FAILED: a deliberately loud case did not turn the suite red.\n' >&2
    printf 'Do not quote a zero from this harness until this passes.\n' >&2
    exit 1
  fi
  printf 'SELF-TEST PASSED: the harness detects a failure and keeps the evidence.\n'
  grep -m1 'not ok' "${out}" | sed 's/^/  /'
  read_evidence "${out}"
  exit 0
fi

runs="${1:-20}"
fails=0
printf 'load at start: %s\n' "$(uptime | sed 's/.*load/load/')"
for i in $(seq 1 "${runs}"); do
  out="${KEEP_DIR}/run-${i}.log"
  if bash "${probe}" > "${out}" 2>&1; then
    rm -f "${out}"
    printf '.'
  else
    fails=$((fails + 1))
    printf 'X\n'
    grep -m1 'not ok' "${out}" | sed 's/^/  /'
    printf '  load now: %s\n' "$(uptime | sed 's/.*load/load/')"
    read_evidence "${out}"
  fi
done
printf '\n%s failures in %s runs\n' "${fails}" "${runs}"
if [[ "${fails}" -eq 0 ]]; then
  printf 'A zero here is only evidence if --self-test passes on this machine,\n'
  printf 'and it is only evidence about the load this run actually saw.\n'
fi
