#!/usr/bin/env bash
# safedeps: what `safedeps check` answers when it cannot read what it judges by.
#
# A provider answer that a writer could not finish, or that names no status of
# the list in lib/providers/providers.sh, approves nothing: the result is
# provider_unavailable, the exit is 4, advisory.log has a line, and --json has a
# report. A cached OSV file or a local KEV catalog that holds no answer is no
# cache: it is asked for again, and a failed request is the same
# provider_unavailable. Nothing here may
# depend on what a status is called: every row asserts the whole answer, because
# a jq compile error also exits 3 and 5.
#
# A row's fault is real where it can be (a damaged cache file, a closed port) and
# otherwise comes from a jq in front of the real one: the call whose arguments
# hold every line of STUB_MATCH fails, or, with STUB_STATUS set, has its output's
# status replaced. No row runs an install; `check` only reads and judges.
#
# The last section fails each read a verdict rests on in the way that hides
# best: the tool runs, prints what it prints, and exits non-zero. Most of these
# reads run where errexit is off, so only their own check can see that.
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
printf '%s\n' '{"vulnerable":["fixture-dep@1.0.0","example.com/mod@v1.0.0"],"kev":["fixture-kev-dep@1.0.0"]}' > "${state_file}"
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
  "fixture-kev@1.0.0": [{"package":"fixture-kev","version":"1.0.0","direct":true}],
  "fixture-parent@1.0.0": [{"package":"fixture-parent","version":"1.0.0","direct":true},{"package":"fixture-child","version":"1.0.0","direct":false}],
  "fixture-vuln@1.0.0": [{"package":"fixture-vuln","version":"1.0.0","direct":true},{"package":"fixture-child","version":"1.0.0","direct":false}],
  "fixture-vuln@1.0.1": [{"package":"fixture-vuln","version":"1.0.1","direct":true}],
  "fixture-unpatched@1.0.0": [{"package":"fixture-unpatched","version":"1.0.0","direct":true}]
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
# curl, answering an OSV query with STUB_OSV_BODY and a KEV download with
# STUB_KEV_BODY where those are set. A request whose arguments hold
# STUB_CURL_FAILS gets its real answer, code included, and exits 18: curl's
# status for a body cut short, and the code it printed is still 200.
real_curl=$(command -v curl)
cat > "${stub_bin}/curl" <<STUB
#!/usr/bin/env bash
out=""
args=("\$@")
for ((i = 0; i < \${#args[@]}; i++)); do
  [[ "\${args[i]}" != -o ]] || out="\${args[i + 1]}"
done
if [[ -n "\${STUB_CURL_FAILS:-}" && "\$*" == *"\${STUB_CURL_FAILS}"* ]]; then
  "${real_curl}" "\$@"
  exit 18
elif [[ -n "\${STUB_OSV_BODY+set}" && "\$*" == *"/osv/v1/"* ]]; then
  printf '%s' "\${STUB_OSV_BODY}" > "\${out}"
elif [[ -n "\${STUB_KEV_BODY+set}" && "\$*" == *"/kev.json"* ]]; then
  printf '%s' "\${STUB_KEV_BODY}" > "\${out}"
else
  exec "${real_curl}" "\$@"
fi
printf '200'
STUB
chmod +x "${stub_bin}/curl"

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

# The writers themselves, called under `if` as the check calls them, which is
# what turns errexit off. The rows above read the check, which also refuses what
# a failed writer leaves behind, so they cannot say the writer returned at all.
writer_rc() {
  local match="$1"
  shift
  fresh_home
  rc=0
  env SAFEDEPS_HOME="${home}" PATH="${stub_bin}:${PATH}" STUB_MATCH="${match}" \
    bash -c 'source lib/providers/providers.sh; if "$@"; then exit 0; fi; exit 1' writer "$@" >/dev/null 2>&1 || rc=$?
}
one_package="${tmp_root}/one-package.json"
printf '%s\n' '[{"package":"fixture-clean","version":"1.0.0","direct":true}]' > "${one_package}"
writer_returns() {
  local match="$1"
  shift
  writer_rc 'a call no writer makes' "$@"
  [[ "${rc}" == 0 ]] || no "the control exits ${rc}"
  writer_rc "${match}" "$@"
  [[ "${rc}" != 0 ]] || no "the writer returned 0"
}
row "a jq error in the last step of the OSV batch reaches its caller" \
  writer_returns 'sort_by(.index)' safedeps_osv_query_batch npm "${one_package}"
row "a jq error in the status writer of the batch reaches its caller" \
  writer_returns "${writer_batch}" safedeps_providers_query_batch npm "${one_package}"
row "a jq error in the last step of the batch query reaches its caller" \
  writer_returns 'sort_by(.index)'$'\n''results' safedeps_providers_query_batch npm "${one_package}"
row "a jq error in the last step of the single query reaches its caller" \
  writer_returns "${writer_one}" safedeps_providers_query pypi fixture-clean 1.0.0
row "a jq error in the KEV overlay reaches the query's caller" \
  writer_returns "${writer_overlay}" safedeps_providers_query pypi fixture-clean 1.0.0

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

# The catalog rows. A local KEV catalog with no catalog in it is no cache, fresh
# or stale: it is downloaded again, the download replaces the file, and with no
# catalog to read the check fails closed. An empty file once read as no listing:
# a package on the catalog came out as merely vulnerable, and a clean one was
# approved with nothing behind that.
kev_file() { printf '%s/cache/kev/known_exploited_vulnerabilities.json' "${home}"; }
kev_catalog='{"vulnerabilities":[{"cveID":"CVE-2026-9999"}]}'
plant_kev() {
  local body="$1" age="${2:-fresh}"
  mkdir -p "${home}/cache/kev"
  if [[ "${body}" == unreadable ]]; then
    printf '%s' "${kev_catalog}" > "$(kev_file)"
    chmod 000 "$(kev_file)"
  else
    printf '%s' "${body}" > "$(kev_file)"
  fi
  [[ "${age}" == fresh ]] || touch -t 202601010000 "$(kev_file)"
}
kev_down=(SAFEDEPS_KEV_CATALOG_URL="${closed_port}")
hard_blocked() {
  [[ "${rc}" == 3 ]] || no "exit ${rc}: ${json}"
  jq -e '.result == "kev_hard_block" and .approved == false' <<< "${json}" >/dev/null || no "the report: ${json}"
  no_approval
}
passed_clean() {
  [[ "${rc}" == 0 ]] || no "exit ${rc}: ${json}"
  jq -e '.result == "clean" and .approved == true' <<< "${json}" >/dev/null || no "the report: ${json}"
}
kev_replaced() {
  jq -e '.vulnerabilities[0].cveID == "CVE-2026-9999"' "$(kev_file)" >/dev/null 2>&1 || no "the file does not hold the catalog"
}
kev_asked_again() {
  local age="$1"
  [[ "${age}" != fresh ]] || grep -q 'WARN CISA KEV cache unreadable; asking again' "${home}/advisory.log" \
    || no "advisory.log does not say the file was not read"
}
kev_listing_counts() {
  local ecosystem="$1" body="$2" age="$3"
  fresh_home
  plant_kev "${body}" "${age}"
  check_in "${ecosystem}" fixture-kev@1.0.0
  hard_blocked
  kev_replaced
  kev_asked_again "${age}"
}
kev_clean_passes() {
  local ecosystem="$1" body="$2" age="$3"
  fresh_home
  plant_kev "${body}" "${age}"
  check_in "${ecosystem}" fixture-clean@1.0.0
  passed_clean
  kev_replaced
  kev_asked_again "${age}"
}
kev_and_download_failed() {
  local ecosystem="$1" body="$2" age="$3"
  fresh_home
  plant_kev "${body}" "${age}"
  check_in "${ecosystem}" fixture-clean@1.0.0 "${kev_down[@]}"
  unavailable
  kev_asked_again "${age}"
  grep -q 'WARN CISA KEV unavailable and no readable local catalog status=' "${home}/advisory.log" \
    || no "advisory.log does not say no catalog could be read"
  ! grep -q 'using stale local catalog' "${home}/advisory.log" || no "the file was used as a stale catalog"
}
for body in '' ' ' 'null' 'false' '[]' '1' '"x"' 'not json' '{}' '{}{}' \
  '{"vulnerabilities":null}' '{"vulnerabilities":false}' '{"vulnerabilities":""}' '{"vulnerabilities":{}}' '{"vulnerabilities":[]}' \
  '{"vulnerabilities":[1]}' '{"vulnerabilities":[{}]}' '{"vulnerabilities":[{"cveID":1}]}' '{"vulnerabilities":[{"cve_id":"CVE-2026-9999"}]}' \
  '{"vulnerabilities":[{"cveID":"CVE-2026-9999"}]} {}' unreadable; do
  for ecosystem in npm pypi; do
    row "${ecosystem}: a KEV catalog of '${body}' is downloaded again and a listing counts" kev_listing_counts "${ecosystem}" "${body}" fresh
    row "${ecosystem}: a KEV catalog of '${body}' is replaced and a clean package still passes" kev_clean_passes "${ecosystem}" "${body}" fresh
    row "${ecosystem}: a KEV catalog of '${body}' with CISA down approves nothing" kev_and_download_failed "${ecosystem}" "${body}" fresh
    row "${ecosystem}: a stale KEV catalog of '${body}' is replaced" kev_clean_passes "${ecosystem}" "${body}" stale
    row "${ecosystem}: a stale KEV catalog of '${body}' with CISA down approves nothing" kev_and_download_failed "${ecosystem}" "${body}" stale
  done
done

kev_absent_and_down() {
  fresh_home
  check_in "$1" fixture-clean@1.0.0 "${kev_down[@]}"
  unavailable
  grep -q 'WARN CISA KEV unavailable and no readable local catalog status=' "${home}/advisory.log" \
    || no "advisory.log does not say no catalog could be read"
}
kev_fresh_hit() {
  local ecosystem="$1" spec="$2" answer="$3"
  fresh_home
  plant_kev "${kev_catalog}"
  check_in "${ecosystem}" "${spec}" "${kev_down[@]}"
  "${answer}"
}
kev_stale_answers() {
  local ecosystem="$1" spec="$2" answer="$3"
  fresh_home
  plant_kev "${kev_catalog}" stale
  check_in "${ecosystem}" "${spec}" "${kev_down[@]}"
  "${answer}"
  grep -q 'WARN CISA KEV refresh failed; using stale local catalog status=' "${home}/advisory.log" \
    || no "advisory.log does not say the catalog is stale"
}
kev_is_a_directory() {
  fresh_home
  mkdir -p "$(kev_file)"
  check_in "$1" fixture-clean@1.0.0
  unavailable
}
for ecosystem in npm pypi; do
  row "${ecosystem}: no KEV catalog with CISA down approves nothing" kev_absent_and_down "${ecosystem}"
  row "${ecosystem}: a fresh KEV catalog is a hit with CISA down" kev_fresh_hit "${ecosystem}" fixture-clean@1.0.0 passed_clean
  row "${ecosystem}: a listing in a fresh KEV catalog counts with CISA down" kev_fresh_hit "${ecosystem}" fixture-kev@1.0.0 hard_blocked
  row "${ecosystem}: a stale KEV catalog answers with CISA down, and says so" kev_stale_answers "${ecosystem}" fixture-clean@1.0.0 passed_clean
  row "${ecosystem}: a listing in a stale KEV catalog counts with CISA down" kev_stale_answers "${ecosystem}" fixture-kev@1.0.0 hard_blocked
  row "${ecosystem}: a directory where the KEV catalog goes approves nothing" kev_is_a_directory "${ecosystem}"
done

# A download that returned something other than a catalog is a failed download,
# by the rule that reads the file: what is stored and what is read are one thing.
kev_live_no_answer() {
  local ecosystem="$1" body="$2"
  fresh_home
  check_in "${ecosystem}" fixture-clean@1.0.0 PATH="${stub_bin}:${PATH}" STUB_KEV_BODY="${body}"
  unavailable
  [[ ! -e "$(kev_file)" ]] || no "the download was stored"
}
kev_live_no_answer_keeps_stale() {
  local ecosystem="$1" body="$2"
  fresh_home
  plant_kev "${kev_catalog}" stale
  check_in "${ecosystem}" fixture-kev@1.0.0 PATH="${stub_bin}:${PATH}" STUB_KEV_BODY="${body}"
  hard_blocked
  kev_replaced
}
for body in '' 'null' '{}' '{"vulnerabilities":[]}' '{"vulnerabilities":[{}]}' '{"vulnerabilities":[{"cveID":"CVE-2026-9999"}]} {}'; do
  for ecosystem in npm pypi; do
    row "${ecosystem}: a KEV download of '${body}' approves nothing" kev_live_no_answer "${ecosystem}" "${body}"
    row "${ecosystem}: a KEV download of '${body}' leaves a stale catalog in place" kev_live_no_answer_keeps_stale "${ecosystem}" "${body}"
  done
done

# The reader itself, for what the rows above cannot reach. With no curl on PATH
# there is no jq or node either, so the row takes the check for curl away.
kev_reader_rc() {
  local state="$1" age="${2:-fresh}"
  fresh_home
  [[ "${state}" == absent ]] || plant_kev "${state}" "${age}"
  rc=0
  env SAFEDEPS_HOME="${home}" bash -c 'source lib/providers/providers.sh; safedeps_require_http_client() { return 1; }; if safedeps_kev_refresh_catalog; then exit 0; fi; exit 1' >/dev/null 2>&1 || rc=$?
}
kev_no_curl() {
  local want="$1" state="$2" age="${3:-fresh}"
  kev_reader_rc "${state}" "${age}"
  [[ "${rc}" == "${want}" ]] || no "exit ${rc}, not ${want}"
}
row "with no curl a fresh KEV catalog is read" kev_no_curl 0 "${kev_catalog}"
row "with no curl a stale KEV catalog is read" kev_no_curl 0 "${kev_catalog}" stale
row "with no curl an empty KEV catalog is no catalog" kev_no_curl 1 ''
row "with no curl a stale empty KEV catalog is no catalog" kev_no_curl 1 '' stale
row "with no curl and no KEV catalog there is none to read" kev_no_curl 1 absent

kev_failure_reaches_caller() {
  fresh_home
  rc=0
  env SAFEDEPS_HOME="${home}" "${kev_down[@]}" bash -c 'source lib/providers/providers.sh; if "$@"; then exit 0; fi; exit 1' writer "$@" >/dev/null 2>&1 || rc=$?
  [[ "${rc}" != 0 ]] || no "the writer returned 0"
  grep -q 'ERROR KEV overlay failed' "${home}/advisory.log" || no "advisory.log has no ERROR line"
}
row "no KEV catalog to read reaches the caller of the single query" kev_failure_reaches_caller safedeps_providers_query pypi fixture-clean 1.0.0
row "no KEV catalog to read reaches the caller of the batch query" kev_failure_reaches_caller safedeps_providers_query_batch npm "${one_package}"

# The overlay reads a file the reader passed a moment ago. If that file is no
# catalog by then, nothing is listed in it and nothing is unlisted either.
kev_overlay_rc() {
  rc=0
  env SAFEDEPS_HOME="${home}" bash -c 'source lib/providers/providers.sh; if safedeps_kev_overlay "$1" 2026-01-01T00:00:00Z "$2"; then exit 0; fi; exit 1' overlay "${home}/osv.json" "$1" >/dev/null 2>&1 || rc=$?
}
kev_overlay_refuses() {
  fresh_home
  printf '{}' > "${home}/osv.json"
  plant_kev "${kev_catalog}"
  kev_overlay_rc "$(kev_file)"
  [[ "${rc}" == 0 ]] || no "the control exits ${rc}"
  plant_kev "$1"
  kev_overlay_rc "$(kev_file)"
  [[ "${rc}" != 0 ]] || no "the overlay answered from '$1'"
}
for body in '' 'null' '{}' '{"vulnerabilities":null}'; do
  row "the overlay does not read '${body}' as a catalog with nothing listed" kev_overlay_refuses "${body}"
done

kev_said_once() {
  fresh_home
  plant_kev "${kev_catalog}" stale
  check_in npm fixture-parent@1.0.0 "${kev_down[@]}"
  passed_clean
  [[ "$(grep -c 'using stale local catalog' "${home}/advisory.log")" == 1 ]] || no "the stale catalog is not said once for two packages"
}
row "npm: a closure reads the KEV catalog once, and says it is stale once" kev_said_once

kev_recheck_counts_nothing() {
  fresh_home
  check_in pypi fixture-clean@1.0.0
  [[ "${rc}" == 0 ]] || no "the first run exits ${rc}: ${json}"
  : > "$(kev_file)"
  rc=0
  json=$(env "${kev_down[@]}" SAFEDEPS_HOME="${home}" ./bin/safedeps --json re-check 2>"${home}/stderr") || rc=$?
  [[ "${rc}" == 0 ]] || no "exit ${rc}: ${json}"
  jq -e '.checked == 1 and .still_clean == 0 and .revoked == []' <<< "${json}" >/dev/null || no "the report: ${json}"
  [[ -n "$(find "${home}/approved-specs" -name '*.json' -type f)" ]] || no "the entry is gone"
}
row "re-check with no KEV catalog to read counts nothing clean and revokes nothing" kev_recheck_counts_nothing

# The cache rows. A fresh cache file with no OSV answer in it is no cache,
# whatever it holds: the query is asked again, its answer replaces the file, and
# if it cannot be asked the check fails closed. An empty file once read as no
# advisories, the same as OSV's own `{}`. Go asks every module prefix, so the
# file planted there is the module's, and the other prefixes hold answers: with
# no answer to read a failed query would fail the row before the file mattered.
osv_cache_file() {
  local ecosystem="$1" spec="$2" key
  key=$(SAFEDEPS_HOME="${home}" bash -c 'source lib/providers/providers.sh; safedeps_cache_key osv "$(safedeps_osv_ecosystem "$1")" "${2%@*}" "${2##*@}"' cache-key "${ecosystem}" "${spec}")
  printf '%s/cache/osv/%s.json' "${home}" "${key}"
}
plant_osv() {
  local ecosystem="$1" spec="$2" body="$3" name="${2%@*}" version="${2##*@}"
  mkdir -p "${home}/cache/osv"
  if [[ "${ecosystem}" == go ]]; then
    printf '{}' > "$(osv_cache_file go "${spec}")"
    printf '{}' > "$(osv_cache_file go "${name%/*}@${version}")"
    planted=$(osv_cache_file go "${name%/*/*}@${version}")
  else
    planted=$(osv_cache_file "${ecosystem}" "${spec}")
  fi
  if [[ "${body}" == unreadable ]]; then
    printf '{}' > "${planted}"
    chmod 000 "${planted}"
  else
    printf '%s' "${body}" > "${planted}"
  fi
}
osv_down=(SAFEDEPS_OSV_API_URL="${closed_port}" SAFEDEPS_OSV_BATCH_API_URL="${closed_port}")

cache_asked_again() {
  local ecosystem="$1" spec="$2" body="$3"
  fresh_home
  plant_osv "${ecosystem}" "${spec}" "${body}"
  check_in "${ecosystem}" "${spec}"
  [[ "${rc}" == 2 ]] || no "exit ${rc}: ${json}"
  jq -e '.result == "cve_unpatched" and .approved == false' <<< "${json}" >/dev/null || no "the report: ${json}"
  no_approval
  jq -e 'length > 0' <<< "$(jq '.vulns' "${planted}")" >/dev/null || no "the file does not hold the answer"
}
cache_replaced() {
  local ecosystem="$1" spec="$2" body="$3"
  fresh_home
  plant_osv "${ecosystem}" "${spec}" "${body}"
  check_in "${ecosystem}" "${spec}"
  [[ "${rc}" == 0 ]] || no "exit ${rc}: ${json}"
  jq -e '.result == "clean" and .approved == true' <<< "${json}" >/dev/null || no "the report: ${json}"
  jq -es 'length == 1 and (.[0] | type == "object")' "${planted}" >/dev/null || no "the file was not replaced"
}
cache_and_query_failed() {
  local ecosystem="$1" spec="$2" body="$3"
  fresh_home
  plant_osv "${ecosystem}" "${spec}" "${body}"
  check_in "${ecosystem}" "${spec}" "${osv_down[@]}"
  unavailable
}
for body in '' ' ' 'null' 'false' '[]' '1' '"x"' 'not json' '{}{}' 'null {}' '{"vulns":false}' '{"vulns":""}' '{"vulns":{}}' '{"vulns":1}' unreadable; do
  for case in 'npm fixture-unpatched@1.0.0 fixture-clean@1.0.0' \
    'pypi fixture-unpatched@1.0.0 fixture-clean@1.0.0' \
    'go example.com/mod/cmd/tool@v1.0.0 example.com/other/cmd/tool@v1.0.0'; do
    read -r ecosystem vulnerable clean <<< "${case}"
    row "${ecosystem}: a cache file of '${body}' is asked again and the provider's advisory counts" cache_asked_again "${ecosystem}" "${vulnerable}" "${body}"
    row "${ecosystem}: a cache file of '${body}' is replaced and a clean package still passes" cache_replaced "${ecosystem}" "${clean}" "${body}"
    row "${ecosystem}: a cache file of '${body}' with OSV down approves nothing" cache_and_query_failed "${ecosystem}" "${clean}" "${body}"
  done
done

# What OSV writes stays a cache hit, and the provider is not asked.
cache_answers() {
  local ecosystem="$1" spec="$2" body="$3"
  fresh_home
  plant_osv "${ecosystem}" "${spec}" "${body}"
  check_in "${ecosystem}" "${spec}" "${osv_down[@]}"
  [[ "${rc}" == 0 ]] || no "exit ${rc}: ${json}"
  jq -e '.result == "clean" and .approved == true' <<< "${json}" >/dev/null || no "the report: ${json}"
}
cached_advisory() {
  local ecosystem="$1" spec="$2"
  fresh_home
  plant_osv "${ecosystem}" "${spec}" '{"vulns":[{"id":"CVE-2026-1002"}]}'
  check_in "${ecosystem}" "${spec}" "${osv_down[@]}"
  [[ "${rc}" == 2 ]] || no "exit ${rc}: ${json}"
  jq -e '.result == "cve_unpatched" and .approved == false' <<< "${json}" >/dev/null || no "the report: ${json}"
}
for ecosystem in npm pypi; do
  for body in '{}' '{"vulns":[]}' '{"vulns":null}'; do
    row "${ecosystem}: a cached answer of '${body}' is a hit with OSV down" cache_answers "${ecosystem}" fixture-clean@1.0.0 "${body}"
  done
  row "${ecosystem}: a cached advisory is a hit with OSV down" cached_advisory "${ecosystem}" fixture-clean@1.0.0
done

cache_is_a_directory() {
  local ecosystem="$1" spec="$2"
  fresh_home
  mkdir -p "$(osv_cache_file "${ecosystem}" "${spec}")"
  check_in "${ecosystem}" "${spec}"
  unavailable
}
row "npm: a directory where the cache file goes approves nothing" cache_is_a_directory npm fixture-clean@1.0.0
row "non-npm: a directory where the cache file goes approves nothing" cache_is_a_directory pypi fixture-clean@1.0.0

# A query that returned something other than an answer is a failed query, by the
# rule that reads the cache: what is stored and what is read are one thing.
live_no_answer() {
  local ecosystem="$1" body="$2"
  fresh_home
  check_in "${ecosystem}" fixture-clean@1.0.0 PATH="${stub_bin}:${PATH}" STUB_OSV_BODY="${body}"
  unavailable
}
for body in 'null {}' '[] {}' '{} {}' '{"vulns":false}' '{"vulns":""}'; do
  row "non-npm: a live answer of '${body}' approves nothing" live_no_answer pypi "${body}"
done
for body in '{"results":[null]}' '{"results":[false]}' '{"results":[[]]}' '{"results":[{"vulns":false}]}'; do
  row "npm: a live batch answer of '${body}' approves nothing" live_no_answer npm "${body}"
done

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

# ---- a tool that prints, then fails ---------------------------------------
#
# Each call whose arguments hold every line of STUB_MATCH, and start with
# STUB_PREFIX when that is set, runs, prints what it prints, and exits 5. With
# STUB_BEFORE set it exits 5 and prints nothing. A read a verdict rests on is
# checked by its own return, so a row below names one read, and turning that
# check off turns the row red.
after_bin="${tmp_root}/after-bin"
mkdir -p "${after_bin}"
for tool in jq date shasum sha256sum cat cut dirname mv find awk; do
  real=$(command -v "${tool}") || continue
  cat > "${after_bin}/${tool}" <<STUB
#!/usr/bin/env bash
hit=1
while IFS= read -r wanted; do
  [[ -n "\${wanted}" ]] || continue
  [[ "\$*" == *"\${wanted}"* ]] || hit=0
done <<< "\${STUB_MATCH:-}"
[[ -n "\${STUB_TOOL_ONLY:-}" && "\${STUB_TOOL_ONLY}" != ${tool} ]] && hit=0
[[ -z "\${STUB_PREFIX:-}" || "\$*" == "\${STUB_PREFIX}"* ]] || hit=0
[[ "\${hit}" -eq 1 ]] || exec "${real}" "\$@"
[[ -n "\${STUB_BEFORE:-}" ]] && exit 5
"${real}" "\$@"
[[ -z "\${STUB_THEN:-}" ]] || eval "\${STUB_THEN}"
exit 5
STUB
done
# npm with no network: a view prints a version, an install writes a lockfile with
# the spec and one dependency. STUB_NPM_FAILS names a subcommand that prints what
# it prints and exits 5; STUB_NPM_FIRST_INSTALL_FAILS fails the first install.
real_jq=$(command -v jq)
cat > "${after_bin}/npm" <<STUB
#!/usr/bin/env bash
case "\${1:-}" in
  view) printf '"1.0.0"\n' ;;
  install)
    if [[ -n "\${STUB_NPM_FIRST_INSTALL_FAILS:-}" && ! -e "\${STUB_NPM_FIRST_INSTALL_FAILS}" ]]; then
      : > "\${STUB_NPM_FIRST_INSTALL_FAILS}"
      exit 1
    fi
    spec="\${2:-}"
    [[ "\${spec}" == *@* ]] || spec=\$("${real_jq}" -r '.dependencies // {} | to_entries | map(.key + "@" + .value) | .[0] // "fixture-clean@1.0.0"' package.json)
    name="\${spec%@*}" version="\${spec##*@}"
    printf '{"lockfileVersion":3,"packages":{"":{"name":"p","version":"0.0.0"},"node_modules/%s":{"name":"%s","version":"%s"}}}\n' "\${name}" "\${name}" "\${version}" > package-lock.json
    ;;
  *) exit 64 ;;
esac
[[ "\${STUB_NPM_FAILS:-}" != "\${1:-}" ]] || exit 5
STUB
chmod +x "${after_bin}"/*
after_path="${after_bin}:${stub_bin}:${PATH}"

# Fails one call of `check`, and leaves `home`, `json` and `rc`.
after_check() {
  local ecosystem="$1" spec="$2" match="$3"
  shift 3
  check_with "${ecosystem}" "${spec}" PATH="${after_path}" STUB_MATCH="${match}" "$@"
}
# The same in a project, with the fixture closures out of the way, so the check
# reads the project and asks the npm above. `project` is the row's directory.
project_dir() {
  project=$(mktemp -d "${tmp_root}/project.XXXXXX")
  mkdir "${project}/.git"
}
in_project() {
  local ecosystem="$1" spec="$2" match="$3"
  shift 3
  fresh_home
  rc=0
  json=$(cd "${project}" && env -u SAFEDEPS_NPM_CLOSURE_FIXTURE_JSON SAFEDEPS_HOME="${home}" PATH="${after_path}" STUB_MATCH="${match}" "$@" \
    "${ROOT_DIR}/bin/safedeps" --json check "${ecosystem}" "${spec}" 2>"${home}/stderr") || rc=$?
}
refused() {
  [[ "${rc}" == 4 ]] || no "exit ${rc}, not 4: ${json}"
  jq -e '.command == "check" and .result == "error" and .approved == false' <<< "${json}" >/dev/null || no "the report: ${json}"
  no_approval
}
not_written() {
  refused
  jq -e '.error == "ledger_write_failed"' <<< "${json}" >/dev/null || no "the report: ${json}"
  grep -q 'check fail-closed ledger-write' "${home}/advisory.log" 2>/dev/null || no "advisory.log has no fail-closed line"
}
did_not_finish() {
  refused
  jq -e '.error == "check_did_not_finish"' <<< "${json}" >/dev/null || no "the report: ${json}"
  grep -q 'check fail-closed did-not-finish' "${home}/advisory.log" 2>/dev/null || no "advisory.log has no fail-closed line"
}
version_unresolved() {
  [[ "${rc}" == 4 ]] || no "exit ${rc}: ${json}"
  jq -e '.result == "error" and .error == "version_resolution_failed"' <<< "${json}" >/dev/null || no "the report: ${json}"
  no_approval
}
candidate_withheld() {
  [[ "${rc}" != 0 ]] || no "exit ${rc}: ${json}"
  jq -e '.approved != true' <<< "${json}" >/dev/null || no "the report: ${json}"
  no_approval
}
closure_failed() {
  [[ "${rc}" == 4 ]] || no "exit ${rc}: ${json}"
  jq -e '.result == "error" and .error == "npm_closure_resolution_failed" and .approved == false' <<< "${json}" >/dev/null || no "the report: ${json}"
  no_approval
}
fails_as() {
  local oracle="$1"
  shift
  after_check "$@"
  "${oracle}"
}
in_project_fails_as() {
  local oracle="$1"
  shift
  in_project "$@"
  "${oracle}"
}

# A function called under `if`, as `check` calls it, with the libraries sourced.
function_rc() {
  local match="$1"
  shift
  fresh_home
  rc=0
  env SAFEDEPS_HOME="${home}" PATH="${after_path}" STUB_MATCH="${match}" \
    bash -c 'source lib/providers/providers.sh; source lib/ledger/ledger.sh; source lib/npm/closure.sh; if "$@"; then exit 0; fi; exit 1' function "$@" >/dev/null 2>"${tmp_root}/function-stderr" || rc=$?
}
function_fails() {
  local tool="$1" match="$2"
  shift 2
  function_rc 'a call no function makes' "$@"
  [[ "${rc}" == 0 ]] || no "the control exits ${rc}: $(cat "${tmp_root}/function-stderr")"
  STUB_TOOL_ONLY="${tool}" function_rc "${match}" "$@"
  [[ "${rc}" != 0 ]] || no "the function returned 0"
}

# The validator's two injections: both left a report of clean, one approval and
# one `check approve` line.
row "npm: an OSV batch payload that jq printed and failed on is not sent" fails_as unavailable npm fixture-clean@1.0.0 'queries: ['
row "npm: an OSV batch item that jq printed and failed on is not read as an answer" fails_as unavailable npm fixture-clean@1.0.0 '.results[$i]'
row "the OSV batch returns when jq prints the payload and fails" function_fails jq 'queries: [' safedeps_osv_query_batch npm "${one_package}"
row "the OSV batch returns when jq prints an item and fails" function_fails jq '.results[$i]' safedeps_osv_query_batch npm "${one_package}"

# What a provider answered.
row "non-npm: an OSV query that jq printed and failed on is not sent" fails_as unavailable pypi fixture-clean@1.0.0 '{version: $version, package: {name: $package, ecosystem: $ecosystem}}'
row "npm: the count of OSV batch misses is read or the batch fails" fails_as unavailable npm fixture-clean@1.0.0 $'-s length\nmisses.jsonl'
row "npm: the count of OSV batch results is read or the batch fails" fails_as unavailable npm fixture-clean@1.0.0 '.results | length'
row "npm: the cache path of an OSV batch miss is read or the batch fails" fails_as unavailable npm fixture-clean@1.0.0 '-r .cache_path'
row "npm: a curl that printed 200 and failed is not an OSV batch answer" fails_as unavailable npm fixture-clean@1.0.0 'a call no row fails' STUB_CURL_FAILS=/osv/v1/querybatch
row "non-npm: a curl that printed 200 and failed is not an OSV answer" fails_as unavailable pypi fixture-clean@1.0.0 'a call no row fails' STUB_CURL_FAILS=/osv/v1/query
row "npm: a curl that printed 200 and failed is not a KEV catalog" fails_as unavailable npm fixture-clean@1.0.0 'a call no row fails' STUB_CURL_FAILS=/kev.json
row "non-npm: a curl that printed 200 and failed is not a KEV catalog" fails_as unavailable pypi fixture-clean@1.0.0 'a call no row fails' STUB_CURL_FAILS=/kev.json
curl_failure_recorded() {
  after_check npm fixture-clean@1.0.0 'a call no row fails' STUB_CURL_FAILS=/osv/v1/querybatch
  grep -q 'ERROR OSV batch query failed status=200 exit 18' "${home}/advisory.log" || no "advisory.log does not say both: $(cat "${home}/advisory.log")"
  after_check npm fixture-clean@1.0.0 'a call no row fails' STUB_CURL_FAILS=/kev.json
  grep -q 'WARN CISA KEV unavailable and no readable local catalog status=200 exit 18' "${home}/advisory.log" || no "advisory.log does not say both: $(cat "${home}/advisory.log")"
}
row "the record says a failed request printed 200 and how it ended" curl_failure_recorded
cache_file="${tmp_root}/fresh-cache-file"
: > "${cache_file}"
row "a cache file's age is read from a clock that answered" function_fails date '+%s' safedeps_cache_is_fresh "${cache_file}"
row "an OSV cache key that shasum printed and failed on is no cache path" function_fails shasum '-a 256' safedeps_osv_query_batch npm "${one_package}"
row "an OSV single-query cache key that shasum printed and failed on is no cache path" function_fails shasum '-a 256' safedeps_osv_query pypi fixture-clean 1.0.0

# What the ledger reads and writes.
row "the ledger hash returns when shasum prints and fails" function_fails shasum '-a 256' safedeps_ledger_hash npm fixture-clean 1.0.0
row "the ledger hash with a context returns when shasum prints and fails" function_fails shasum '-a 256' safedeps_ledger_hash npm fixture-clean 1.0.0 sha256:c
row "the ledger path returns when shasum prints and fails" function_fails shasum '-a 256' safedeps_ledger_path npm fixture-clean 1.0.0
ledger_read_failed() {
  fresh_home
  SAFEDEPS_HOME="${home}" lib/ledger/ledger.sh approve npm fixture-clean 1.0.0 >/dev/null
  rc=0
  env SAFEDEPS_HOME="${home}" PATH="${after_path}" STUB_MATCH='-a 256' STUB_TOOL_ONLY=shasum \
    bash -c 'source lib/ledger/ledger.sh; if safedeps_ledger_read npm fixture-clean 1.0.0 >/dev/null; then exit 0; fi; exit 1' >/dev/null 2>&1 || rc=$?
  [[ "${rc}" != 0 ]] || no "the entry was read"
}
ledger_with_entry() {
  local want="$1" match="$2"
  fresh_home
  SAFEDEPS_HOME="${home}" lib/ledger/ledger.sh approve npm fixture-clean 1.0.0 >/dev/null
  rc=0
  env SAFEDEPS_HOME="${home}" PATH="${after_path}" STUB_MATCH="${match}" STUB_TOOL_ONLY="${want}" \
    bash -c 'source lib/ledger/ledger.sh; if safedeps_ledger_check npm fixture-clean 1.0.0 >/dev/null; then exit 0; fi; exit 1' >/dev/null 2>&1 || rc=$?
  [[ "${rc}" != 0 ]] || no "the entry reads as approved"
}
ledger_check_control() {
  fresh_home
  SAFEDEPS_HOME="${home}" lib/ledger/ledger.sh approve npm fixture-clean 1.0.0 >/dev/null
  rc=0
  env SAFEDEPS_HOME="${home}" PATH="${after_path}" STUB_MATCH='a call no row fails' \
    bash -c 'source lib/ledger/ledger.sh; if safedeps_ledger_check npm fixture-clean 1.0.0 >/dev/null; then exit 0; fi; exit 1' >/dev/null 2>&1 || rc=$?
  [[ "${rc}" == 0 ]] || no "the control exits ${rc}"
}
row "control: a ledger entry reads as approved under the stubs" ledger_check_control
row "a ledger read returns when shasum prints and fails" ledger_read_failed
row "a ledger check returns when shasum prints and fails" ledger_with_entry shasum '-a 256'
row "a ledger check does not take a stored hash jq printed and failed on" ledger_with_entry jq '-r .hash'
row "a ledger check does not take a stored context jq printed and failed on" ledger_with_entry jq 'ledger_context_hash'
atomic_write_cat() {
  fresh_home
  rc=0
  env SAFEDEPS_HOME="${home}" PATH="${after_path}" STUB_TOOL_ONLY=cat \
    bash -c 'source lib/ledger/ledger.sh; if safedeps_ledger_atomic_write "${SAFEDEPS_HOME}/approved-specs/x.json" <<< "{}"; then exit 0; fi; exit 1' >/dev/null 2>&1 || rc=$?
  [[ "${rc}" != 0 ]] || no "the write returned 0"
  [[ -z "$(find "${home}/approved-specs" -type f 2>/dev/null)" ]] || no "the failed write left a file: $(ls -a "${home}/approved-specs")"
}
row "a ledger write that cat failed on leaves nothing and returns" atomic_write_cat
row "an approval's dates come from a clock that answered" function_fails date '%Y-%m-%dT%H:%M:%SZ' safedeps_ledger_render_approved_spec npm fixture-clean 1.0.0
row "an approval's expiry comes from a clock that answered" function_fails date '+%s' safedeps_ledger_add_days_iso 30
row "an approval's expiry is no date a failed clock left" function_fails date '-r' safedeps_ledger_add_days_iso 30
project_context_file="${tmp_root}/project-context.json"
printf '{"type":"npm-overrides-probe","context_hash":"sha256:c","project_root":"/r"}\n' > "${project_context_file}"
row "an approval's context hash is read or there is no approval" function_fails jq 'context_scopes' safedeps_ledger_render_approved_spec npm fixture-clean 1.0.0 1.0.0 local '' 30 '' "${project_context_file}"
row "an approval's hash is read or there is no approval" function_fails shasum '-a 256' safedeps_ledger_render_approved_spec npm fixture-clean 1.0.0
row "the entry an approval writes is one jq finished" function_fails jq 'version_range: $version_range' safedeps_ledger_render_approved_spec npm fixture-clean 1.0.0

# An approval is made whole and then written, or it is not written.
row "npm: a ledger entry jq printed and failed on is not written" fails_as not_written npm fixture-clean@1.0.0 'version_range: $version_range'
row "non-npm: a ledger entry jq printed and failed on is not written" fails_as not_written pypi fixture-clean@1.0.0 'version_range: $version_range'
row "npm patched: a ledger entry jq printed and failed on is not written" fails_as not_written npm fixture-vuln@1.0.0 'version_range: $version_range'
row "non-npm patched: a ledger entry jq printed and failed on is not written" fails_as not_written pypi fixture-vuln@1.0.0 'version_range: $version_range'
for field in hash expires_at; do
  row "npm: an approval's ${field} jq printed and failed on writes nothing" fails_as not_written npm fixture-clean@1.0.0 "-r .${field}"
  row "non-npm: an approval's ${field} jq printed and failed on writes nothing" fails_as not_written pypi fixture-clean@1.0.0 "-r .${field}"
  row "npm patched: an approval's ${field} jq printed and failed on writes nothing" fails_as not_written npm fixture-vuln@1.0.0 "-r .${field}"
  row "non-npm patched: an approval's ${field} jq printed and failed on writes nothing" fails_as not_written pypi fixture-vuln@1.0.0 "-r .${field}"
done
row "npm: a transitive count jq printed and failed on writes nothing" fails_as not_written npm fixture-clean@1.0.0 'safedeps-closure' STUB_PREFIX='length /'
row "npm patched: a transitive count jq printed and failed on writes nothing" fails_as not_written npm fixture-vuln@1.0.0 'safedeps-closure' STUB_PREFIX='length /'
row "npm: a closure source cat printed and failed on writes nothing" fails_as not_written npm fixture-clean@1.0.0 'safedeps-evidence' STUB_TOOL_ONLY=cat
row "npm: a resolved closure cat printed and failed on writes nothing" fails_as not_written npm fixture-clean@1.0.0 'safedeps-closure' STUB_TOOL_ONLY=cat
row "npm patched: a closure source cat printed and failed on writes nothing" fails_as not_written npm fixture-vuln@1.0.0 'safedeps-evidence' STUB_TOOL_ONLY=cat
row "npm patched: a resolved closure cat printed and failed on writes nothing" fails_as not_written npm fixture-vuln@1.0.0 'safedeps-closure' STUB_TOOL_ONLY=cat
row "npm: a closure source type jq printed and failed on writes nothing" fails_as not_written npm fixture-clean@1.0.0 '-r .type'
row "npm patched: a closure source type jq printed and failed on writes nothing" fails_as not_written npm fixture-vuln@1.0.0 '-r .type'
row "npm: a report jq printed and failed on writes nothing" fails_as not_written npm fixture-clean@1.0.0 'install_hint:install_hint($version)'
row "non-npm: a report jq printed and failed on writes nothing" fails_as not_written pypi fixture-clean@1.0.0 'install_hint:install_hint($version)'
row "npm patched: a report jq printed and failed on writes nothing" fails_as not_written npm fixture-vuln@1.0.0 'install_hint:install_hint($patched)'
row "non-npm patched: a report jq printed and failed on writes nothing" fails_as not_written pypi fixture-vuln@1.0.0 'install_hint:install_hint($patched)'
row "an entry mv moved and then failed on is taken back" fails_as not_written npm fixture-clean@1.0.0 'approved-specs' STUB_TOOL_ONLY=mv
# jq, and once the report has been made the record can no longer be written.
record_stub="${tmp_root}/record-stub"
mkdir -p "${record_stub}"
cat > "${record_stub}/jq" <<STUB
#!/usr/bin/env bash
"${real_jq}" "\$@"
status=\$?
[[ "\$*" != *"\${RECORD_DIES_ON}"* ]] || chmod 000 "\${SAFEDEPS_HOME}/advisory.log"
exit "\${status}"
STUB
chmod +x "${record_stub}/jq"
record_refused() {
  fresh_home
  rc=0
  json=$(env SAFEDEPS_HOME="${home}" PATH="${record_stub}:${PATH}" RECORD_DIES_ON='install_hint' ./bin/safedeps --json check "$1" "$2" 2>"${home}/stderr") || rc=$?
  [[ "${rc}" == 4 ]] || no "exit ${rc}: ${json}"
  jq -e '.approved == false' <<< "${json}" >/dev/null || no "the report: ${json}"
  [[ -z "$(find "${home}/approved-specs" -name '*.json' -type f 2>/dev/null)" ]] || no "a ledger entry stands with no record"
}
row "npm: an approval the record could not take is taken back" record_refused npm fixture-clean@1.0.0
row "non-npm: an approval the record could not take is taken back" record_refused pypi fixture-clean@1.0.0

# What the report is read from.
row "npm: a vulnerable count jq printed and failed on is no count" fails_as unavailable npm fixture-clean@1.0.0 'select(.status == status_vulnerable)] | length'
row "npm: a KEV count jq printed and failed on is no count" fails_as unavailable npm fixture-clean@1.0.0 'select(.status == status_hard_block)] | length'
row "npm: a direct status jq printed and failed on is no status" fails_as unavailable npm fixture-clean@1.0.0 '"missing"'
row "npm patched: a candidate's count jq printed and failed on is no count" fails_as unavailable npm fixture-vuln@1.0.0 'select(.status | status_risky)] | length'
row "non-npm: a status jq printed and failed on is no status" fails_as unavailable pypi fixture-clean@1.0.0 'select(status_known)'
row "non-npm patched: a candidate's status jq printed and failed on is no status" fails_as unavailable pypi fixture-vuln@1.0.0 'select(status_known)'
row "npm patched: a direct status jq printed and failed on is no status" fails_as unavailable npm fixture-vuln@1.0.0 'select(status_known)'
row "a range npm printed and failed on resolves to nothing" fails_as version_unresolved npm 'fixture-clean@^1.0.0' 'a call no row fails' STUB_NPM_FAILS=view
row "a resolved version jq printed and failed on is no version" fails_as version_unresolved npm 'fixture-clean@^1.0.0' 'if type=="array" then .[-1]'
approved_read_failed() {
  fresh_home
  check_in npm fixture-clean@1.0.0
  [[ "${rc}" == 0 ]] || no "the first run exits ${rc}: ${json}"
  check_in npm fixture-clean@1.0.0 PATH="${after_path}" STUB_MATCH='.approved == true'
  [[ "${rc}" == 0 ]] || no "exit ${rc}: ${json}"
  jq -e '.result == "clean"' <<< "${json}" >/dev/null || no "the ledger hit was read: ${json}"
}
row "an entry whose approved field jq printed and failed on is judged again" approved_read_failed
cached_report_failed() {
  fresh_home
  check_in npm fixture-clean@1.0.0
  [[ "${rc}" == 0 ]] || no "the first run exits ${rc}: ${json}"
  check_in npm fixture-clean@1.0.0 PATH="${after_path}" STUB_MATCH="$1"
  [[ "${rc}" == 4 ]] || no "exit ${rc}: ${json}"
  jq -es 'length == 1 and .[0].error == "check_did_not_finish"' <<< "${json}" >/dev/null || no "the report: ${json}"
}
row "a ledger hit's context jq printed and failed on is no report" cached_report_failed '.spec.project_context // null'
row "a ledger hit's closure jq printed and failed on is no report" cached_report_failed '.spec.evidence.closure // []'

# A command that stops the run under set -e still ends in a report.
row "npm: a run stopped by the evidence jq says so" fails_as did_not_finish npm fixture-clean@1.0.0 'closure_checked: true'
row "npm: a run stopped by the transitive list jq says so" fails_as did_not_finish npm fixture-clean@1.0.0 '{ecosystem: "npm", package: .package, version: (.version | tostring)}'
row "non-npm: a run stopped by the CVE count says so" fails_as did_not_finish pypi fixture-vuln@1.0.0 '(.vulnerabilities // []) | length'
human_stop() {
  fresh_home
  rc=0
  env SAFEDEPS_HOME="${home}" PATH="${after_path}" STUB_MATCH='closure_checked: true' ./bin/safedeps check npm fixture-clean@1.0.0 >/dev/null 2>"${home}/stderr" || rc=$?
  [[ "${rc}" == 4 ]] || no "exit ${rc}, not 4"
  grep -q 'check fail-closed did-not-finish' "${home}/advisory.log" || no "advisory.log has no fail-closed line"
}
row "a human run stopped under set -e exits 4 and has a record" human_stop
one_report() {
  fresh_home
  rc=0
  json=$(env SAFEDEPS_HOME="${home}" ./bin/safedeps --json check 2>/dev/null) || rc=$?
  [[ "${rc}" == 4 ]] || no "exit ${rc}: ${json}"
  jq -es 'length == 1 and (.[0].approved == false)' <<< "${json}" >/dev/null || no "the report: ${json}"
}
row "a check with no arguments still answers in JSON" one_report
no_home() {
  rc=0
  json=$(env SAFEDEPS_HOME=/dev/null/home ./bin/safedeps --json check pypi fixture-clean@1.0.0 2>/dev/null) || rc=$?
  [[ "${rc}" == 4 ]] || no "exit ${rc}: ${json}"
  jq -es 'length == 1 and (.[0].approved == false)' <<< "${json}" >/dev/null || no "the report: ${json}"
}
row "a check with a home it cannot make still answers in JSON" no_home

# A find in a process substitution has no exit anyone can see, so what lists the
# ledger keeps it apart, and an unreadable ledger is not an empty one.
ledger_listed() {
  fresh_home
  check_in pypi fixture-clean@1.0.0
  [[ "${rc}" == 0 ]] || no "the first run exits ${rc}: ${json}"
}
unlisted() {
  [[ "${rc}" == 4 ]] || no "exit ${rc}: ${json}"
  jq -es --arg command "$1" 'length == 1 and .[0].command == $command and .[0].error == "ledger_unlisted"' <<< "${json}" >/dev/null || no "the report: ${json}"
  grep -q "$1 fail-closed ledger-unlisted" "${home}/advisory.log" || no "advisory.log has no fail-closed line"
}
ledger_unlisted_as() {
  local command="$1" before="$2"
  shift 2
  ledger_listed
  rc=0
  json=$(env SAFEDEPS_HOME="${home}" PATH="${after_path}" STUB_MATCH='approved-specs' STUB_TOOL_ONLY=find STUB_BEFORE="${before}" ./bin/safedeps --json "${command}" "$@" 2>"${home}/stderr") || rc=$?
  unlisted "${command}"
  jq -e '.revoked_at == null' "${home}"/approved-specs/*.json >/dev/null || no "an entry was revoked"
}
row "a re-check that find printed and failed under is no whole listing" ledger_unlisted_as re-check ''
row "a re-check that find failed under is no empty ledger" ledger_unlisted_as re-check 1
row "a ledger listing that find printed and failed under is no whole listing" ledger_unlisted_as ledger ''
row "a ledger listing that find failed under is no empty ledger" ledger_unlisted_as ledger 1
row "a revoke that find failed under is no missing entry" ledger_unlisted_as revoke 1 pypi fixture-clean@1.0.0
row "a revoke by name that find failed under is no missing entry" ledger_unlisted_as revoke 1 fixture-clean@1.0.0
real_unreadable_ledger() {
  ledger_listed
  chmod 000 "${home}/approved-specs"
  rc=0
  json=$(env SAFEDEPS_HOME="${home}" ./bin/safedeps --json re-check 2>"${home}/stderr") || rc=$?
  chmod 700 "${home}/approved-specs"
  unlisted re-check
}
row "a re-check of a ledger it may not read checked nothing and says so" real_unreadable_ledger
ledger_listing_control() {
  ledger_listed
  rc=0
  json=$(env SAFEDEPS_HOME="${home}" PATH="${after_path}" STUB_MATCH='a call no row fails' ./bin/safedeps --json re-check 2>"${home}/stderr") || rc=$?
  [[ "${rc}" == 0 ]] || no "exit ${rc}: ${json}"
  jq -e '.checked == 1 and .still_clean == 1' <<< "${json}" >/dev/null || no "the report: ${json}"
  rc=0
  json=$(env SAFEDEPS_HOME="${home}" PATH="${after_path}" STUB_MATCH='a call no row fails' ./bin/safedeps --json ledger 2>"${home}/stderr") || rc=$?
  [[ "${rc}" == 0 ]] || no "exit ${rc}: ${json}"
  jq -e '.count == 1' <<< "${json}" >/dev/null || no "the report: ${json}"
}
row "control: a ledger that lists is read whole" ledger_listing_control

# What the closure is read from.
yarn_project() {
  project_dir
  printf '{"name":"p","version":"0.0.0","resolutions":{"fixture-child":"1.0.0"}}\n' > "${project}/package.json"
  printf '__metadata:\n  version: 8\n' > "${project}/yarn.lock"
}
overrides_project() {
  project_dir
  printf '{"name":"p","version":"0.0.0","overrides":{"fixture-child":"1.0.0"}}\n' > "${project}/package.json"
}
yarn_refused() {
  yarn_project
  in_project_fails_as "$1" npm fixture-clean@1.0.0 "$2"
}
overrides_refused() {
  overrides_project
  in_project_fails_as "$@"
}
control_project() {
  overrides_project
  in_project npm fixture-clean@1.0.0 'a call no row fails'
  [[ "${rc}" == 0 ]] || no "exit ${rc}: ${json}"
  jq -e '.result == "clean" and .closure_source.type == "npm-overrides-probe"' <<< "${json}" >/dev/null || no "the report: ${json}"
  project_dir
  in_project npm fixture-clean@1.0.0 'a call no row fails'
  [[ "${rc}" == 0 ]] || no "exit ${rc}: ${json}"
  jq -e '.result == "clean" and .closure_source.type == "npm-package-probe"' <<< "${json}" >/dev/null || no "the report: ${json}"
}
row "control: a project with overrides and one without clear the closure probe" control_project
row "a Yarn manifest jq printed and failed on is not a project with no resolutions" yarn_refused refused '.resolutions | type'
row "a Yarn context jq printed and failed on is no context" yarn_refused refused 'resolutions_sha256: $resolutions_sha256'
row "a deny-only mark that does not read is no permission" fails_as refused npm fixture-clean@1.0.0 'source_approval_scope'
row "a patch candidate whose deny-only mark does not read is no patch" fails_as candidate_withheld npm fixture-vuln@1.0.0 'source_approval_scope'
row "overrides jq printed and failed on are not a project with none" overrides_refused refused npm fixture-clean@1.0.0 '.overrides | type'
row "overrides whose filter jq printed and failed on are not a project with none" overrides_refused refused npm fixture-clean@1.0.0 'to_entries'
row "an overrides context jq printed and failed on is not the global key" overrides_refused refused npm fixture-clean@1.0.0 'overrides_sha256: $overrides_sha256'
row "a canonical override set jq printed and failed on is not the global key" overrides_refused refused npm fixture-clean@1.0.0 '-cS .'
overrides_source_lost() {
  overrides_project
  in_project npm fixture-clean@1.0.0 'safedeps-npm-overrides-src' STUB_TOOL_ONLY=cat
  refused
}
row "an overrides source cat printed and failed on is not an unnamed source" overrides_source_lost
overrides_shasum() {
  overrides_project
  in_project npm fixture-clean@1.0.0 '-a 256' STUB_TOOL_ONLY=shasum
  refused
}
row "an overrides hash shasum printed and failed on is not the global key" overrides_shasum
walk_dirname() {
  project_dir
  mkdir -p "${project}/inner"
  printf '{"name":"p","overrides":{"fixture-child":"1.0.0"}}\n' > "${project}/package.json"
  project="${project}/inner"
  in_project npm fixture-clean@1.0.0 'inner' STUB_TOOL_ONLY=dirname
  refused
}
row "a walk to the overrides that dirname failed on is not a walk that found none" walk_dirname
yarn_walk_dirname() {
  yarn_project
  mkdir -p "${project}/inner"
  project="${project}/inner"
  in_project npm fixture-clean@1.0.0 'inner' STUB_TOOL_ONLY=dirname
  refused
}
row "a walk to the Yarn project that dirname failed on is not a walk that found none" yarn_walk_dirname
yarn_inputs_unread() {
  local mirror inputs
  mirror=$(mktemp -d "${tmp_root}/mirror.XXXXXX")
  inputs="${mirror}.inputs"
  project_dir
  printf '{"name":"p"}\n' > "${project}/package.json"
  printf '{"input_files":[{"path":"package.json"}]}\n' > "${inputs}"
  rc=0
  env PATH="${after_path}" STUB_MATCH="$1" bash -c 'source lib/npm/closure.sh; if safedeps_npm_yarn_copy_materialization_inputs "$@"; then exit 0; fi; exit 1' inputs "${project}" "${mirror}" "${inputs}" >/dev/null 2>&1 || rc=$?
  [[ "${rc}" == "$2" ]] || no "exit ${rc}, not $2"
  [[ "$2" == 1 || -f "${mirror}/package.json" ]] || no "nothing was copied"
}
row "control: a mirror's inputs are copied" yarn_inputs_unread 'a call no row fails' 0
row "a mirror's inputs jq printed and failed on are no list of inputs" yarn_inputs_unread '.input_files[]?.path' 1
fixture_read_failed() {
  project_dir
  closure=$(cd "${project}" && env PATH="${after_path}" STUB_MATCH='--arg key' bash -c 'source "$1/lib/npm/closure.sh"; safedeps_npm_resolve_spec_closure fixture-clean 1.0.0' closure "${ROOT_DIR}" 2>/dev/null) || no "the real resolution failed"
  jq -es 'length == 1' <<< "${closure}" >/dev/null || no "two closures on stdout: ${closure}"
}
row "a fixture closure jq printed and failed on is not printed before the real one" fixture_read_failed
row "a source jq wrote and failed on stops the fixture path" fails_as closure_failed npm fixture-clean@1.0.0 '{type: $type}'
source_write_failed() {
  "$1"
  in_project npm fixture-clean@1.0.0 '{type: $type}'
  closure_failed
}
row "a closure source jq wrote and failed on stops the probe" source_write_failed project_dir
row "an overrides source jq wrote and failed on stops the probe" source_write_failed overrides_project
yarn_source_failed() {
  yarn_project
  printf '%s\n' '{"value":"fixture-clean@npm:1.0.0","children":{"Version":"1.0.0","Dependencies":[]}}' > "${tmp_root}/yarn.ndjson"
  in_project npm fixture-clean@1.0.0 '{type: $type}' SAFEDEPS_YARN_INFO_FIXTURE_NDJSON="${tmp_root}/yarn.ndjson"
  closure_failed
}
row "a Yarn closure source jq wrote and failed on stops the check" yarn_source_failed
yarn_root_failed() {
  yarn_project
  printf '%s\n' '{"value":"fixture-clean@npm:1.0.0","children":{"Version":"1.0.0","Dependencies":[]}}' > "${tmp_root}/yarn.ndjson"
  in_project npm fixture-clean@1.0.0 '.project_root' SAFEDEPS_YARN_INFO_FIXTURE_NDJSON="${tmp_root}/yarn.ndjson"
  closure_failed
}
row "a Yarn project root jq printed and failed on stops the check" yarn_root_failed
pinned_equality() {
  local dir
  dir=$(mktemp -d "${tmp_root}/probe.XXXXXX")
  printf '{}\n' > "${dir}/package.json"
  rc=0
  env PATH="${after_path}" STUB_MATCH="$1" bash -c 'source lib/npm/closure.sh; if safedeps_npm_probe_self_pinned "$1" fixture-clean 1.0.0 "{}"; then exit 0; fi; exit 1' pinned "${dir}" >/dev/null 2>&1 || rc=$?
}
pinned_equal() {
  pinned_equality 'a call no row fails'
  [[ "${rc}" == 0 ]] || no "the control exits ${rc}"
  pinned_equality '$pinned == $kept'
  [[ "${rc}" != 0 ]] || no "the pinned lockfile was used"
}
row "a pinned lockfile compared by a jq that failed is not used" pinned_equal

# revoke says what it did.
revoke_faulted() {
  local match="$1"
  fresh_home
  SAFEDEPS_HOME="${home}" lib/ledger/ledger.sh approve pypi fixture-clean 1.0.0 >/dev/null
  shift
  rc=0
  json=$(env SAFEDEPS_HOME="${home}" PATH="${after_path}" STUB_MATCH="${match}" "$@" ./bin/safedeps --json revoke pypi fixture-clean@1.0.0 2>"${home}/stderr") || rc=$?
  [[ "${rc}" != 0 ]] || no "the revoke exits 0: ${json}"
  [[ -z "${json}" ]] || jq -e '.revoked != true' <<< "${json}" >/dev/null || no "the report says revoked: ${json}"
}
row "a revoked entry jq printed and failed on is not reported revoked" revoke_faulted 'revoked_reason: $reason'
row "a revoked entry jq failed on before printing is not reported revoked" revoke_faulted 'revoked_reason: $reason' STUB_BEFORE=1
row "a revoke with no clock is not reported revoked" revoke_faulted '%Y-%m-%dT%H:%M:%SZ' STUB_TOOL_ONLY=date
misses_run() {
  local closure index
  closure=$(mktemp "${tmp_root}/closure.XXXXXX")
  index=$(mktemp "${tmp_root}/index.XXXXXX")
  printf '[{"package":"fixture-clean","version":"1.0.0"}]\n' > "${closure}"
  rc=0
  env PATH="${after_path}" STUB_MATCH="$1" STUB_TOOL_ONLY="$2" STUB_BEFORE="$3" bash -c 'source lib/ledger/ledger.sh; rc=0; safedeps_ledger_effect_misses "$@" || rc=$?; exit "${rc}"' misses "${index}" npm "${closure}" >/dev/null 2>&1 || rc=$?
  [[ "${rc}" == "$4" ]] || no "exit ${rc}, not $4"
}
row "control: a closure the index does not approve has a miss" misses_run 'a call no row fails' '' '' 1
row "a comparison awk failed on is no list of misses" misses_run 'SUBSEP' awk 1 2
row "a comparison awk printed and failed on is no list of misses" misses_run 'SUBSEP' awk '' 2
row "a closure jq failed on is no list of misses" misses_run '@tsv' jq 1 2

[[ "${failures}" -eq 0 ]]
