#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/safedeps-gate-audit-contract.XXXXXX")"
trap 'rm -rf -- "$tmp_root"' EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

fakebin="${tmp_root}/fakebin"
fixture_home="${tmp_root}/home"
mkdir -p "${fakebin}" "${fixture_home}/.codex/skills/safedeps"

cat > "${fakebin}/npm" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_NPM_ARGS_LOG:?}"
if [ "${1:-}" = "run" ]; then
  [ "${2:-}" != "security:audit" ] || exit 99
  exit 0
fi
[ "${1:-}" = "audit" ] || exit 0
case "${FAKE_NPM_MODE:-clean}" in
  clean) printf '%s\n' '{"metadata":{"vulnerabilities":{"info":0,"low":0,"moderate":0,"high":0,"critical":0}}}'; exit 0 ;;
  vuln)  printf '%s\n' '{"metadata":{"vulnerabilities":{"info":0,"low":0,"moderate":4,"high":0,"critical":0}}}'; exit 1 ;;
esac
exit 98
FAKE

cat > "${fakebin}/yarn" <<'FAKE'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  printf '4.12.0\n'
  exit 0
fi
[ "${1:-}" = "npm" ] && [ "${2:-}" = "audit" ] || exit 97
printf '%s\n' "$*" >> "${FAKE_YARN_ARGS_LOG:?}"
case " $* " in *' --all '*) ;; *) exit 96 ;; esac
case " $* " in *' --recursive '*) ;; *) exit 95 ;; esac
case " $* " in *' --json '*) ;; *) exit 94 ;; esac
case "${FAKE_YARN_MODE:-clean}" in
  clean) exit 0 ;;
  vuln)
    printf '%s\n' '{"value":"workspace-direct","children":{"Severity":"high"}}'
    printf '%s\n' '{"value":"workspace-transitive","children":{"Severity":"moderate"}}'
    exit 1
    ;;
esac
exit 93
FAKE

chmod +x "${fakebin}/npm" "${fakebin}/yarn"

make_fixture() {
  local manager="$1" fixture="${tmp_root}/${1}-repo"
  mkdir -p "${fixture}"
  git -C "${fixture}" init -q
  printf '%s\n' '{"name":"gate-audit-contract","private":true,"scripts":{"security:scan:worktree":"exit 0","security:audit":"exit 99"}}' > "${fixture}/package.json"
  if [ "${manager}" = "npm" ]; then
    printf '%s\n' '{"name":"gate-audit-contract","lockfileVersion":3}' > "${fixture}/package-lock.json"
  else
    printf '%s\n' '__metadata:' '  version: 8' > "${fixture}/yarn.lock"
  fi
  printf '%s\n' "${fixture}"
}

run_with_rc() {
  local output_file="$1"; shift
  if "$@" >"${output_file}" 2>&1; then
    RUN_RC=0
  else
    RUN_RC=$?
  fi
}

assert_same_verdict() {
  local manager="$1" fixture="$2" mode="$3" expected="$4"
  local direct_out="${tmp_root}/${manager}-${mode}-audit.out"
  local gate_out="${tmp_root}/${manager}-${mode}-gate.out"
  local npm_mode=clean yarn_mode=clean
  [ "${manager}" != "npm" ] || npm_mode="${mode}"
  [ "${manager}" != "yarn" ] || yarn_mode="${mode}"

  run_with_rc "${direct_out}" env \
    PATH="${fakebin}:${PATH}" HOME="${fixture_home}" \
    FAKE_NPM_MODE="${npm_mode}" FAKE_YARN_MODE="${yarn_mode}" \
    FAKE_NPM_ARGS_LOG="${tmp_root}/npm-args.log" FAKE_YARN_ARGS_LOG="${tmp_root}/yarn-args.log" \
    bash "${ROOT_DIR}/lib/gates/audit.sh" --root "${fixture}" --level moderate
  direct_rc="${RUN_RC}"

  run_with_rc "${gate_out}" env \
    PATH="${fakebin}:${PATH}" HOME="${fixture_home}" \
    FAKE_NPM_MODE="${npm_mode}" FAKE_YARN_MODE="${yarn_mode}" \
    FAKE_NPM_ARGS_LOG="${tmp_root}/npm-args.log" FAKE_YARN_ARGS_LOG="${tmp_root}/yarn-args.log" \
    bash "${ROOT_DIR}/scripts/release-gates.sh" --root "${fixture}" --strict
  gate_rc="${RUN_RC}"

  [ "${direct_rc}" = "${expected}" ] || fail "${manager} ${mode}: audit expected ${expected}, got ${direct_rc}"
  [ "${gate_rc}" = "${expected}" ] || fail "${manager} ${mode}: strict gate expected ${expected}, got ${gate_rc}"
  if [ "${mode}" = "vuln" ]; then
    direct_severity="$(grep 'severities:' "${direct_out}" | tail -1)"
    gate_severity="$(grep 'severities:' "${gate_out}" | tail -1)"
    [ -n "${direct_severity}" ] || fail "${manager} vuln: audit omitted severity evidence"
    [ "${direct_severity}" = "${gate_severity}" ] || fail "${manager} vuln: gate/audit severity evidence diverged"
  fi
  grep -q 'lib/gates/audit.sh' "${gate_out}" || fail "${manager} ${mode}: strict gate did not call canonical audit owner"
}

npm_fixture="$(make_fixture npm)"
yarn_fixture="$(make_fixture yarn)"
for mode_expected in clean:0 vuln:1; do
  mode="${mode_expected%%:*}"
  expected="${mode_expected#*:}"
  assert_same_verdict npm "${npm_fixture}" "${mode}" "${expected}"
  assert_same_verdict yarn "${yarn_fixture}" "${mode}" "${expected}"
done

if grep -q '^run security:audit$' "${tmp_root}/npm-args.log"; then
  fail "release gate invoked repo security:audit instead of the canonical audit owner"
fi
[ "$(grep -c '^npm audit --all --recursive --json$' "${tmp_root}/yarn-args.log")" -eq 4 ] \
  || fail "Yarn Berry gate/audit calls did not all use --all --recursive --json"

pass "strict gate and canonical audit share npm/Yarn verdicts; Yarn Berry is whole-project recursive"
