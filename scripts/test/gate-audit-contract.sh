#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/safedeps-gate-audit-contract.XXXXXX")"
server_pid=""
cleanup() {
  if [ -n "${server_pid}" ]; then kill "${server_pid}" 2>/dev/null || true; wait "${server_pid}" 2>/dev/null || true; fi
  rm -rf -- "$tmp_root"
}
trap cleanup EXIT

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
  low)   printf '%s\n' '{"metadata":{"vulnerabilities":{"info":0,"low":2,"moderate":0,"high":0,"critical":0}}}'; exit 1 ;;
  failed) printf '%s\n' '{"metadata":{"vulnerabilities":{"info":0,"low":0,"moderate":0,"high":0,"critical":0}}}'; exit 5 ;;
  # One moderate advisory of a package from a site, as npm 7+ reports it.
  site) printf '%s\n' '{"vulnerabilities":{"site":{"name":"site","severity":"moderate","via":[{"source":1,"name":"site","url":"https://github.com/advisories/GHSA-site-aaaa-bbbb","severity":"moderate"}],"nodes":["node_modules/site"]}},"metadata":{"vulnerabilities":{"info":0,"low":0,"moderate":1,"high":0,"critical":0,"total":1}}}'; exit 1 ;;
  # The same advisory where a public package brings the site package in: npm
  # counts the parent too, for its dependency.
  site-nested) printf '%s\n' '{"vulnerabilities":{"site":{"name":"site","severity":"moderate","via":[{"source":1,"name":"site","url":"https://github.com/advisories/GHSA-site-aaaa-bbbb","severity":"moderate"}],"nodes":["node_modules/parent/node_modules/site"]},"parent":{"name":"parent","severity":"moderate","via":["site"],"nodes":["node_modules/parent"]}},"metadata":{"vulnerabilities":{"info":0,"low":0,"moderate":2,"high":0,"critical":0,"total":2}}}'; exit 1 ;;
esac
exit 98
FAKE

cat > "${fakebin}/yarn" <<'FAKE'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  printf '%s\n' "${FAKE_YARN_VERSION:-4.12.0}"
  exit 0
fi
if [ "${1:-}" = "audit" ]; then
  printf '%s\n' '{"type":"auditSummary","data":{"vulnerabilities":{"info":0,"low":0,"moderate":0,"high":0,"critical":0}}}'
  case "${FAKE_YARN_MODE:-clean}" in clean) exit 0 ;; esac
  exit 5
fi
[ "${1:-}" = "npm" ] && [ "${2:-}" = "audit" ] || exit 97
printf '%s\n' "$*" >> "${FAKE_YARN_ARGS_LOG:?}"
case " $* " in *' --all '*) ;; *) exit 96 ;; esac
case " $* " in *' --recursive '*) ;; *) exit 95 ;; esac
case " $* " in *' --json '*) ;; *) exit 94 ;; esac
case "${FAKE_YARN_MODE:-clean}" in
  clean) exit 0 ;;
  advisory) printf '%s\n' '{"value":"workspace-direct","children":{"Severity":"high"}}'; exit 0 ;;
  vuln)
    printf '%s\n' '{"value":"workspace-direct","children":{"Severity":"high"}}'
    printf '%s\n' '{"value":"workspace-transitive","children":{"Severity":"moderate"}}'
    exit 1
    ;;
esac
exit 93
FAKE

# jq, with the call whose arguments hold STUB_MATCH gone wrong: it prints what it
# prints and exits 5, or with STUB_BEFORE set exits 5 and prints nothing.
real_jq="$(command -v jq)"
cat > "${fakebin}/jq" <<STUB
#!/usr/bin/env bash
if [ -z "\${STUB_MATCH:-}" ] || [[ "\$*" != *"\${STUB_MATCH}"* ]]; then
  exec "${real_jq}" "\$@"
fi
[ -n "\${STUB_BEFORE:-}" ] && exit 5
"${real_jq}" "\$@"
exit 5
STUB

# find, with the call whose arguments hold STUB_FIND_MATCH gone the same way.
real_find="$(command -v find)"
cat > "${fakebin}/find" <<STUB
#!/usr/bin/env bash
if [ -z "\${STUB_FIND_MATCH:-}" ] || [[ "\$*" != *"\${STUB_FIND_MATCH}"* ]]; then
  exec "${real_find}" "\$@"
fi
[ -n "\${STUB_BEFORE:-}" ] && exit 5
"${real_find}" "\$@"
exit 5
STUB

cat > "${fakebin}/pip-audit" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE

chmod +x "${fakebin}/npm" "${fakebin}/yarn" "${fakebin}/jq" "${fakebin}/find" "${fakebin}/pip-audit"

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

# Exit 2, could not produce a verdict, however the read failed. Every call here
# runs under `||` in the audit, where errexit is off, so each read answers for
# itself: a jq that failed here read as zero findings, and a tool that printed a
# clean report and then failed read as clean.
audit_rc() {
  local fixture="$1"; shift
  run_with_rc "${tmp_root}/audit.out" env \
    PATH="${fakebin}:${PATH}" HOME="${fixture_home}" \
    FAKE_NPM_ARGS_LOG="${tmp_root}/npm-args.log" FAKE_YARN_ARGS_LOG="${tmp_root}/yarn-args.log" "$@" \
    bash "${ROOT_DIR}/lib/gates/audit.sh" --root "${fixture}" --level moderate
}
assert_audit() {
  local expected="$1" name="$2" fixture="$3"; shift 3
  audit_rc "${fixture}" "$@"
  [ "${RUN_RC}" = "${expected}" ] || fail "${name}: audit expected ${expected}, got ${RUN_RC}: $(cat "${tmp_root}/audit.out")"
  pass "${name}"
}
assert_audit 2 "npm: a clean report from an audit that failed is no verdict" "${npm_fixture}" FAKE_NPM_MODE=failed
assert_audit 0 "npm: an exit with a finding below the level stays clean at that level" "${npm_fixture}" FAKE_NPM_MODE=low
assert_audit 2 "npm: the counts jq printed and failed on are no count" "${npm_fixture}" STUB_MATCH='-c .metadata.vulnerabilities' FAKE_NPM_MODE=clean
assert_audit 2 "npm: the block count jq printed and failed on is no count" "${npm_fixture}" STUB_MATCH='$order' FAKE_NPM_MODE=clean
assert_audit 2 "npm: a block count jq failed on before printing is not zero" "${npm_fixture}" STUB_MATCH='$order' STUB_BEFORE=1 FAKE_NPM_MODE=clean
assert_audit 2 "npm: a finding the zero test jq failed on is no clean exit" "${npm_fixture}" STUB_MATCH='any(.[]; . != 0)' FAKE_NPM_MODE=low
assert_audit 2 "yarn classic: a clean summary from an audit that failed is no verdict" "${yarn_fixture}" FAKE_YARN_VERSION=1.22.22 FAKE_YARN_MODE=failed
assert_audit 0 "yarn classic: a clean summary from an audit that finished is clean" "${yarn_fixture}" FAKE_YARN_VERSION=1.22.22 FAKE_YARN_MODE=clean
assert_audit 2 "yarn Berry: advisory lines jq printed and failed on are no verdict" "${yarn_fixture}" STUB_MATCH='.children.Severity? != null' FAKE_YARN_MODE=advisory
assert_audit 2 "yarn Berry: advisory lines jq failed on before printing are not clean" "${yarn_fixture}" STUB_MATCH='.children.Severity? != null' STUB_BEFORE=1 FAKE_YARN_MODE=advisory

# An advisory of a package the accepted-source ledger covers is taken out of
# npm's counts and named on one line; other bytes, an advisory no entry names
# and no entry at all leave the count as npm gave it. Each covered package is
# asked of OSV and the KEV catalog, here the fixture provider: a KEV listing,
# or no answer, leaves it counted. The entry is written here as an install
# would write it.
site_fixture="${tmp_root}/site-repo"
mkdir -p "${site_fixture}"
git -C "${site_fixture}" init -q
printf '%s\n' '{"name":"gate-audit-contract","private":true}' > "${site_fixture}/package.json"
site_home="${tmp_root}/site-home"
mkdir -p "${site_home}"
site_state="${tmp_root}/site-provider.json"
printf '%s\n' '{"vulnerable":["site@1.0.0"]}' > "${site_state}"
( cd "${tmp_root}" && exec node "${ROOT_DIR}/scripts/test/fixture-provider.mjs" "${tmp_root}/site-provider.port" "${site_state}" ) &
server_pid=$!
for _ in $(seq 50); do [ -s "${tmp_root}/site-provider.port" ] && break; sleep 0.1; done
[ -s "${tmp_root}/site-provider.port" ] || fail "the fixture provider starts"
site_osv="http://127.0.0.1:$(cat "${tmp_root}/site-provider.port")"
site_env=(SAFEDEPS_HOME="${site_home}" SAFEDEPS_PROVIDER_CACHE_TTL_SECONDS=0
  SAFEDEPS_OSV_API_URL="${site_osv}/osv/v1/query" SAFEDEPS_OSV_BATCH_API_URL="${site_osv}/osv/v1/querybatch"
  SAFEDEPS_KEV_CATALOG_URL="${site_osv}/kev.json" SAFEDEPS_GHSA_API_URL="${site_osv}/advisories")
site_url='https://example.test/site/-/site-1.0.0.tgz'
site_lock() { # INTEGRITY [KEY]
  jq -n --arg url "${site_url}" --arg integrity "$1" --arg key "${2:-node_modules/site}" '{name: "gate-audit-contract", lockfileVersion: 3, packages: ({
    "": {name: "gate-audit-contract"},
    "node_modules/parent": {version: "2.0.0", resolved: "https://registry.npmjs.org/parent/-/parent-2.0.0.tgz", integrity: "sha512-parentBytes200"}}
    + {($key): {version: "1.0.0", resolved: $url, integrity: $integrity}})}' > "${site_fixture}/package-lock.json"
}
site_entry() {
  jq -nc --arg url "${site_url}" --arg id "$1" '{at: "2026-01-02T03:04:05Z", op: "accept", url: $url, integrity: "sha512-siteBytes100",
    package: "site", version: "1.0.0", advisories: [$id], reason: "owner: the fix is on the maker site only",
    project: "/work/site", tool_use_id: null}' > "${site_home}/accepted-sources.jsonl"
}
site_said() { grep -qxF "safedeps audit: $1" "${tmp_root}/audit.out" || fail "$2: $(cat "${tmp_root}/audit.out")"; }
site_lock sha512-siteBytes100
assert_audit 1 "npm: an advisory of a package from a site, with no accepted source, counts" "${site_fixture}" FAKE_NPM_MODE=site "${site_env[@]}"
site_entry GHSA-site-aaaa-bbbb
assert_audit 0 "npm: an advisory an accepted-source entry names is not counted" "${site_fixture}" FAKE_NPM_MODE=site "${site_env[@]}"
site_said 'npm: accepted sources (safedeps sources), not counted: site@1.0.0 (GHSA-site-aaaa-bbbb)' "npm: the accepted advisory is named on one line"
site_lock sha512-siteBytes100 node_modules/parent/node_modules/site
assert_audit 0 "npm: a package npm counts only for an accepted dependency is not counted" "${site_fixture}" FAKE_NPM_MODE=site-nested "${site_env[@]}"
site_said 'npm: accepted sources (safedeps sources), not counted: parent@2.0.0; site@1.0.0 (GHSA-site-aaaa-bbbb)' "npm: the dependent package is named with it"
printf '%s\n' '{"kev":["site@1.0.0"]}' > "${site_state}"
assert_audit 1 "npm: an accepted package that KEV lists counts, and so does its dependent" "${site_fixture}" FAKE_NPM_MODE=site-nested "${site_env[@]}"
site_said 'npm: site@1.0.0 has an accepted source, and CISA KEV lists one of its advisories, so it is counted.' "npm: the KEV listing is said"
printf '%s\n' '{"vulnerable":["site@1.0.0"]}' > "${site_state}"
assert_audit 1 "npm: an accepted package OSV cannot be asked about counts" "${site_fixture}" FAKE_NPM_MODE=site "${site_env[@]}" SAFEDEPS_OSV_API_URL=http://127.0.0.1:9/osv/v1/query
site_said 'npm: site@1.0.0 has an accepted source, and OSV or the KEV catalog could not be asked about it, so it is counted.' "npm: the provider that did not answer is said"
site_lock sha512-siteBytes100
site_entry GHSA-site-cccc-dddd
assert_audit 1 "npm: an advisory no accepted-source entry names counts" "${site_fixture}" FAKE_NPM_MODE=site "${site_env[@]}"
site_entry GHSA-site-aaaa-bbbb
site_lock sha512-siteBytes101
assert_audit 1 "npm: other bytes under an accepted URL count" "${site_fixture}" FAKE_NPM_MODE=site "${site_env[@]}"

# The release gate's two reads of the Python surface. A find that failed is no
# "no surface", and a list it printed first may be missing what it could not read.
assert_gate() {
  local expected="$1" line="$2" name="$3" fixture="$4" strict="$5"; shift 5
  run_with_rc "${tmp_root}/gate.out" env \
    PATH="${fakebin}:${PATH}" HOME="${fixture_home}" \
    FAKE_NPM_ARGS_LOG="${tmp_root}/npm-args.log" FAKE_YARN_ARGS_LOG="${tmp_root}/yarn-args.log" "$@" \
    bash "${ROOT_DIR}/scripts/release-gates.sh" --root "${fixture}" ${strict}
  [ "${RUN_RC}" = "${expected}" ] || fail "${name}: gate expected ${expected}, got ${RUN_RC}: $(cat "${tmp_root}/gate.out")"
  grep -qF -- "${line}" "${tmp_root}/gate.out" || fail "${name}: no '${line}' in: $(cat "${tmp_root}/gate.out")"
  pass "${name}"
}
surface_read='pyproject.toml'
requirements_read='requirements*.txt -not'
assert_gate 0 'PASS [python] no Python dependency surface detected' "control: a surface read that finished finds none" "${npm_fixture}" --strict STUB_MATCH=''
assert_gate 1 'FAIL [python] could not read the Python dependency surface' "strict: a surface read that failed is no 'no surface'" "${npm_fixture}" --strict STUB_FIND_MATCH="${surface_read}" STUB_BEFORE=1
assert_gate 0 'WARN [python] could not read the Python dependency surface' "default: a surface read that failed warns" "${npm_fixture}" '' STUB_FIND_MATCH="${surface_read}" STUB_BEFORE=1
printf 'left-pad==1.0.0\n' > "${npm_fixture}/requirements.txt"
assert_gate 0 'PASS [python] pip-audit ./requirements.txt' "control: a requirements list that finished is audited" "${npm_fixture}" --strict STUB_MATCH=''
assert_gate 1 'FAIL [python] could not read the Python dependency surface' "strict: a surface list find printed and failed on stops there" "${npm_fixture}" --strict STUB_FIND_MATCH="${surface_read}"
assert_gate 1 'FAIL [python] could not read the requirements files' "strict: a requirements list find printed and failed on audits nothing" "${npm_fixture}" --strict STUB_FIND_MATCH="${requirements_read}"
