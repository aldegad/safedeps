#!/usr/bin/env bash
# safedeps: what `safedeps check` answers when it cannot read what it judges by.
#
# A provider answer that a writer could not finish, or that names no status of
# the list in lib/providers/providers.sh, approves nothing: the result is
# provider_unavailable, the exit is 4, advisory.log has a line, and --json has a
# report. Nothing here may depend on what a status is called: every row asserts
# the whole answer, because a jq compile error also exits 3 and 5.
#
# A row's fault is real where it can be (a damaged cache file, a closed port) and
# otherwise comes from a jq in front of the real one: the call whose arguments
# hold every line of STUB_MATCH fails, or, with STUB_STATUS set, has its output's
# status replaced. No row runs an install; `check` only reads and judges.
#
# Every row runs and reports whatever another one answered: a row's state root
# is its own, and one run says which rows a change turns red.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "${ROOT_DIR}"

failures=0
no() { printf '# %s\n' "$*" >&2; exit 1; }
row() {
  local name="$1"
  shift
  if ( "$@" ); then
    printf 'ok - %s\n' "${name}"
  else
    printf 'not ok - %s\n' "${name}" >&2
    failures=$((failures + 1))
  fi
}

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-check-fail-closed.XXXXXX")
tmp_root=$(cd "${tmp_root}" && pwd -P)
server_pid=""
cleanup() {
  local rc=$?
  if [[ -n "${server_pid}" ]]; then
    kill "${server_pid}" 2>/dev/null || true
    wait "${server_pid}" 2>/dev/null || true
  fi
  chmod -R u+rwx "${tmp_root}" 2>/dev/null || true
  if [[ "${rc}" -eq 0 ]]; then rm -rf "${tmp_root}"; else printf '# failed row artifacts: %s\n' "${tmp_root}" >&2; fi
  return "${rc}"
}
trap cleanup EXIT

port_file="${tmp_root}/port"
state_file="${tmp_root}/state.json"
printf '%s\n' '{"vulnerable":["fixture-dep@1.0.0"],"kev":["fixture-kev-dep@1.0.0"]}' > "${state_file}"
( cd "${tmp_root}" && exec node "${ROOT_DIR}/scripts/test/fixture-provider.mjs" "${port_file}" "${state_file}" ) &
server_pid=$!
for _ in {1..50}; do
  [[ -s "${port_file}" ]] && break
  sleep 0.1
done
[[ -s "${port_file}" ]] || { printf 'not ok - the fixture provider starts\n'; exit 1; }
port=$(cat "${port_file}")
export SAFEDEPS_OSV_API_URL="http://127.0.0.1:${port}/osv/v1/query"
export SAFEDEPS_OSV_BATCH_API_URL="http://127.0.0.1:${port}/osv/v1/querybatch"
export SAFEDEPS_KEV_CATALOG_URL="http://127.0.0.1:${port}/kev.json"
export SAFEDEPS_GHSA_API_URL="http://127.0.0.1:${port}/advisories"
closed_port='http://127.0.0.1:9/'

closures="${tmp_root}/closures.json"
cat > "${closures}" <<'JSON'
{
  "fixture-clean@1.0.0": [{"package":"fixture-clean","version":"1.0.0","direct":true}],
  "fixture-parent@1.0.0": [{"package":"fixture-parent","version":"1.0.0","direct":true},{"package":"fixture-child","version":"1.0.0","direct":false}],
  "fixture-vuln@1.0.0": [{"package":"fixture-vuln","version":"1.0.0","direct":true},{"package":"fixture-child","version":"1.0.0","direct":false}],
  "fixture-vuln@1.0.1": [{"package":"fixture-vuln","version":"1.0.1","direct":true}]
}
JSON
closure_with() {
  jq -c --arg dep "$1" '. + {"fixture-vuln@1.0.1": [{"package":"fixture-vuln","version":"1.0.1","direct":true},{"package":$dep,"version":"1.0.0","direct":false}]}' "${closures}" > "$2"
}
closure_with fixture-dep "${tmp_root}/closures-vulnerable.json"
closure_with fixture-kev-dep "${tmp_root}/closures-kev.json"
closure_with fixture-extra "${tmp_root}/closures-extra.json"
export SAFEDEPS_NPM_CLOSURE_FIXTURE_JSON="${closures}"

# jq, with one call gone wrong.
stub_bin="${tmp_root}/stub-bin"
mkdir -p "${stub_bin}"
real_jq=$(command -v jq)
cat > "${stub_bin}/jq" <<STUB
#!/usr/bin/env bash
hit=1
while IFS= read -r wanted; do
  [[ -n "\${wanted}" && "\$*" == *"\${wanted}"* ]] || hit=0
done <<< "\${STUB_MATCH:-}"
[[ "\${hit}" -eq 1 ]] || exec "${real_jq}" "\$@"
[[ -n "\${STUB_STATUS+set}" ]] || exit 5
args=()
first="\${STUB_MATCH%%\$'\n'*}"
for arg in "\$@"; do
  [[ "\${arg}" != *"\${first}"* ]] || arg="\${arg} | if type == \"object\" then .status = \"\${STUB_STATUS}\" else \"\${STUB_STATUS}\" end"
  args+=("\${arg}")
done
exec "${real_jq}" "\${args[@]}"
STUB
chmod +x "${stub_bin}/jq"

# The two status writers, the overlay and the line one package's answer is.
writer_batch='status_of($kev.exploited; .osv.vulns'
writer_one='status_of($kev_result.exploited'
writer_overlay='.cveID as $id'
writer_item='index: $item.index'

# A run in a state root of its own: leaves `home`, `json` and `rc`.
fresh_home() { home=$(mktemp -d "${tmp_root}/home.XXXXXX"); }
check_in() {
  local ecosystem="$1" spec="$2"
  shift 2
  rc=0
  json=$(env SAFEDEPS_HOME="${home}" "$@" ./bin/safedeps --json check "${ecosystem}" "${spec}" 2>"${home}/stderr") || rc=$?
}
check_with() {
  fresh_home
  check_in "$@"
}
faulted() {
  local ecosystem="$1" spec="$2" match="$3"
  shift 3
  check_with "${ecosystem}" "${spec}" PATH="${stub_bin}:${PATH}" STUB_MATCH="${match}" "$@"
}

# No approval of any kind: in the report, in the ledger or in the record.
no_approval() {
  jq -e '.approved != true' <<< "${json}" >/dev/null || no "the report approves: ${json}"
  [[ -z "$(find "${home}/approved-specs" -name '*.json' -type f 2>/dev/null)" ]] || no "a ledger entry was written"
  ! grep -q 'check approve' "${home}/advisory.log" 2>/dev/null || no "advisory.log records an approval"
}
unavailable() {
  [[ "${rc}" == 4 ]] || no "exit ${rc}, not 4: ${json}"
  jq -e '.command == "check" and .result == "provider_unavailable" and .approved == false' <<< "${json}" >/dev/null \
    || no "the report: ${json}"
  no_approval
  grep -q 'check fail-closed' "${home}/advisory.log" 2>/dev/null || no "advisory.log has no fail-closed line"
}

control_clean() {
  faulted npm fixture-clean@1.0.0 'a call no writer makes'
  [[ "${rc}" == 0 ]] || no "exit ${rc}: ${json}"
  jq -e '.result == "clean" and .approved == true' <<< "${json}" >/dev/null || no "the report: ${json}"
  faulted pypi fixture-clean@1.0.0 'a call no writer makes'
  [[ "${rc}" == 0 ]] || no "exit ${rc}: ${json}"
  jq -e '.result == "clean" and .approved == true' <<< "${json}" >/dev/null || no "the report: ${json}"
}
row "control: the stub in front of jq changes nothing a clean package answers" control_clean

status_rewritten() {
  local ecosystem="$1" spec="$2" writer="$3" status="$4"
  faulted "${ecosystem}" "${spec}" "${writer}" STUB_STATUS="${status}"
  unavailable
}
for status in weird '' blocked CLEAN 'clean '; do
  row "npm: a provider status of '${status}' approves nothing" status_rewritten npm fixture-clean@1.0.0 "${writer_batch}" "${status}"
  row "non-npm: a provider status of '${status}' approves nothing" status_rewritten pypi fixture-clean@1.0.0 "${writer_one}" "${status}"
done

writer_failed() {
  faulted "$1" "$2" "$3"
  unavailable
}
row "npm: a jq error in the status writer does not leave an empty status" writer_failed npm fixture-clean@1.0.0 "${writer_batch}"
row "non-npm: a jq error in the status writer does not leave an empty status" writer_failed pypi fixture-clean@1.0.0 "${writer_one}"
row "npm: a jq error in the KEV overlay is not read as no KEV listing" writer_failed npm fixture-clean@1.0.0 "${writer_overlay}"
row "non-npm: a jq error in the KEV overlay is not read as no KEV listing" writer_failed pypi fixture-clean@1.0.0 "${writer_overlay}"
row "npm: a package of the closure with no answer is not read as clean" \
  writer_failed npm fixture-parent@1.0.0 "${writer_item}"$'\n''"package":"fixture-child"'

damaged_cache() {
  local ecosystem="$1" spec="$2" what="$3" key
  fresh_home
  mkdir -p "${home}/cache/kev" "${home}/cache/osv"
  if [[ "${what}" == kev ]]; then
    printf 'not json' > "${home}/cache/kev/known_exploited_vulnerabilities.json"
  else
    key=$(SAFEDEPS_HOME="${home}" bash -c 'source lib/providers/providers.sh; safedeps_cache_key osv "$(safedeps_osv_ecosystem "$1")" "${2%@*}" "${2##*@}"' cache-key "${ecosystem}" "${spec}")
    printf 'not json' > "${home}/cache/osv/${key}.json"
  fi
  check_in "${ecosystem}" "${spec}"
  unavailable
}
row "npm: a KEV catalog that does not parse approves nothing" damaged_cache npm fixture-clean@1.0.0 kev
row "non-npm: a KEV catalog that does not parse approves nothing" damaged_cache pypi fixture-clean@1.0.0 kev
row "npm: an OSV cache file that does not parse approves nothing" damaged_cache npm fixture-clean@1.0.0 osv
row "non-npm: an OSV cache file that does not parse approves nothing" damaged_cache pypi fixture-clean@1.0.0 osv

candidate_status() {
  faulted "$1" fixture-vuln@1.0.0 "$2"$'\n'"$3" STUB_STATUS=weird
  unavailable
  jq -e '.resolved_version == "1.0.0" and .suggested_spec == "1.0.1"' <<< "${json}" >/dev/null || no "the report: ${json}"
}
row "npm: a patch candidate's unknown status approves nothing" candidate_status npm "${writer_item}" '"package":"fixture-vuln","version":"1.0.1"'
row "non-npm: a patch candidate's unknown status is not a vulnerable candidate" candidate_status pypi "${writer_one}" ' 1.0.1 '

direct_query_failed() {
  check_with npm fixture-vuln@1.0.0 SAFEDEPS_OSV_API_URL="${closed_port}" SAFEDEPS_PROVIDER_CACHE_TTL_SECONDS=-1
  unavailable
}
row "npm: a failed direct advisory query is provider_unavailable, not cve_unpatched" direct_query_failed

direct_query_unknown() {
  faulted npm fixture-vuln@1.0.0 "${writer_one}" STUB_STATUS=weird
  unavailable
}
row "npm: a direct advisory answer with an unknown status is provider_unavailable" direct_query_unknown

# The report of a version no candidate could replace is that version's.
requested_version_report() {
  rc_wanted=2
  [[ "${rc}" == "${rc_wanted}" ]] || no "exit ${rc}: ${json}"
  jq -e '.result == "cve_unpatched" and .approved == false and .resolved_version == "1.0.0" and (has("suggested_spec") | not)
    and ([.resolved_closure[] | .package + "@" + .version] | sort) == ["fixture-child@1.0.0", "fixture-vuln@1.0.0"]
    and ([.closure_vulnerabilities[] | [.package, .version, .result]] == [["fixture-vuln", "1.0.0", "vulnerable"]])' \
    <<< "${json}" >/dev/null || no "the report: ${json}"
  no_approval
  grep -qF 'check block(vulnerable closure) package=fixture-vuln version=1.0.0 affected=fixture-vuln@1.0.0 (direct)' "${home}/advisory.log" \
    || no "advisory.log: $(grep 'check block' "${home}/advisory.log" || true)"
}
candidate_rejected() {
  check_with npm fixture-vuln@1.0.0 SAFEDEPS_NPM_CLOSURE_FIXTURE_JSON="${tmp_root}/$1"
  requested_version_report
}
row "cve_unpatched reports the requested version, not a candidate with a vulnerable dependency" candidate_rejected closures-vulnerable.json
row "cve_unpatched reports the requested version, not a candidate with a KEV-listed dependency" candidate_rejected closures-kev.json

deny_only_candidate() {
  local npm_bin="${tmp_root}/deny-npm-bin" project="${tmp_root}/deny-project"
  mkdir -p "${npm_bin}" "${project}"
  cat > "${npm_bin}/npm" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == "install" ]] || exit 64
name="${2%@*}"; version="${2##*@}"
printf '{"lockfileVersion":3,"packages":{"":{"name":"p","version":"0.0.0"},"node_modules/%s":{"name":"%s","version":"%s"},"node_modules/fixture-child":{"name":"fixture-child","version":"1.0.0"}}}\n' "${name}" "${name}" "${version}" > package-lock.json
STUB
  chmod +x "${npm_bin}/npm"
  printf '{"name":"p","version":"0.0.0","resolutions":{"x":"1.0.0"}}\n' > "${project}/package.json"
  printf 'no berry marker\n' > "${project}/yarn.lock"
  fresh_home
  rc=0
  json=$(cd "${project}" && env -u SAFEDEPS_NPM_CLOSURE_FIXTURE_JSON PATH="${npm_bin}:${PATH}" SAFEDEPS_HOME="${home}" SAFEDEPS_NPM_PROJECT_DIR="${project}" \
    "${ROOT_DIR}/bin/safedeps" --json check npm fixture-vuln@1.0.0 2>"${home}/stderr") || rc=$?
  requested_version_report
}
row "cve_unpatched reports the requested version, not a clean candidate it could not scope" deny_only_candidate

candidate_batch_failed() {
  fresh_home
  check_in npm fixture-vuln@1.0.0
  [[ "${rc}" == 0 ]] || no "the first run exits ${rc}: ${json}"
  check_in npm fixture-vuln@1.0.0 SAFEDEPS_NPM_CLOSURE_FIXTURE_JSON="${tmp_root}/closures-extra.json" SAFEDEPS_OSV_BATCH_API_URL="${closed_port}"
  [[ "${rc}" == 4 ]] || no "exit ${rc}: ${json}"
  jq -e '.result == "provider_unavailable" and .approved == false and .resolved_version == "1.0.0" and .suggested_spec == "1.0.1"' <<< "${json}" >/dev/null \
    || no "the report: ${json}"
  grep -q 'check fail-closed' "${home}/advisory.log" || no "advisory.log has no fail-closed line"
}
row "npm: a failed batch for a patch candidate answers in JSON and is recorded" candidate_batch_failed

ledger_write_failed() {
  check_with npm fixture-clean@1.0.0 SAFEDEPS_LEDGER_DIR="${tmp_root}/closures.json"
  [[ "${rc}" == 4 ]] || no "exit ${rc}: ${json}"
  jq -e '.result == "error" and .approved == false and .error == "ledger_write_failed"' <<< "${json}" >/dev/null || no "the report: ${json}"
  ! grep -q 'check approve' "${home}/advisory.log" || no "advisory.log records an approval"
}
row "a ledger that cannot be written answers in JSON and records no approval" ledger_write_failed

stale_entry_is_no_approval() {
  local dir
  fresh_home
  dir="${home}/approved-specs"
  SAFEDEPS_HOME="${home}" lib/ledger/ledger.sh approve npm fixture-clean 1.0.0 1.0.0 test '' 0 >/dev/null
  sleep 1
  chmod 500 "${dir}"
  check_in npm fixture-clean@1.0.0
  chmod 700 "${dir}"
  [[ "${rc}" == 4 ]] || no "exit ${rc}: ${json}"
  jq -e '.result == "error" and .approved == false' <<< "${json}" >/dev/null || no "the report: ${json}"
}
row "a failed ledger write is not reported as the expired entry it could not replace" stale_entry_is_no_approval

already_approved_hint() {
  fresh_home
  check_in npm fixture-clean@1.0.0
  [[ "${rc}" == 0 ]] || no "the first run exits ${rc}: ${json}"
  check_in npm fixture-clean@1.0.0
  [[ "${rc}" == 0 ]] || no "the second run exits ${rc}: ${json}"
  jq -e '.result == "already_approved" and .install_hint == "install with fixture-clean@1.0.0"' <<< "${json}" >/dev/null || no "the report: ${json}"
}
row "already_approved carries the install_hint the deny message and SKILL.md send a reader to" already_approved_hint

recheck_unknown_status() {
  fresh_home
  check_in pypi fixture-clean@1.0.0
  [[ "${rc}" == 0 ]] || no "the first run exits ${rc}: ${json}"
  rc=0
  json=$(env PATH="${stub_bin}:${PATH}" STUB_MATCH="${writer_one}" STUB_STATUS=weird SAFEDEPS_HOME="${home}" ./bin/safedeps --json re-check 2>"${home}/stderr") || rc=$?
  [[ "${rc}" == 0 ]] || no "exit ${rc}: ${json}"
  jq -e '.checked == 1 and .still_clean == 0 and .revoked == []' <<< "${json}" >/dev/null || no "the report: ${json}"
  grep -q 're-check skipped' "${home}/advisory.log" || no "advisory.log has no skipped line"
}
row "re-check does not count an unknown status as clean, and records the skip" recheck_unknown_status

plant_entry() {
  local filter="$1" file
  fresh_home
  SAFEDEPS_HOME="${home}" lib/ledger/ledger.sh approve pypi fixture-clean 1.0.0 >/dev/null
  file=$(find "${home}/approved-specs" -name '*.json' -type f)
  jq -c "${filter}" "${file}" > "${file}.new"
  mv -f "${file}.new" "${file}"
}
recheck_context_false() {
  plant_entry '.project_context = false'
  rc=0
  json=$(env SAFEDEPS_HOME="${home}" ./bin/safedeps --json re-check 2>"${home}/stderr") || rc=$?
  [[ "${rc}" == 0 ]] || no "exit ${rc}: ${json}"
  jq -e '.checked == 1 and .still_clean == 1' <<< "${json}" >/dev/null || no "the report: ${json}"
}
row "re-check reads an entry whose project_context is false, as the approval predicate does" recheck_context_false

listing_expiry() {
  plant_entry '.expires_at = "2999-1-1T00:00:00Z"'
  rc=0
  json=$(env SAFEDEPS_HOME="${home}" ./bin/safedeps --json ledger 2>"${home}/stderr") || rc=$?
  jq -e '.specs[0].expired == true' <<< "${json}" >/dev/null || no "the report: ${json}"
  SAFEDEPS_HOME="${home}" NO_COLOR=1 ./bin/safedeps ledger | grep -q '^EXPIRED' || no "the listing does not say EXPIRED"
  check_in pypi fixture-clean@1.0.0
  [[ "$(jq -r '.result' <<< "${json}")" == "clean" ]] || no "check reads the entry as live: ${json}"
}
row "the ledger listing and check read an unpadded expires_at the way the core does" listing_expiry

[[ "${failures}" -eq 0 ]]
