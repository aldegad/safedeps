#!/usr/bin/env bash
# safedeps: what `safedeps check` answers when it cannot read what it judges by.
#
# A provider answer that a writer could not finish, or that names no status of
# the list in lib/providers/providers.sh, approves nothing: the result is
# provider_unavailable, the exit is 4, advisory.log has a line, and --json has a
# report. OSV is asked on every check, page by page, with the record of every
# advisory it names, and an answer an earlier run left is never read. A local
# KEV catalog that holds no catalog is no cache: it is asked for again. A failed
# request is the same provider_unavailable. Nothing here may
# depend on what a status is called: every row asserts the whole answer, because
# a jq compile error also exits 3 and 5.
#
# A row's fault is real where it can be (a damaged cache file, a closed port) and
# otherwise comes from a jq in front of the real one: the call whose arguments
# and input hold every line of STUB_MATCH fails, or, with STUB_STATUS set, has
# its output's status replaced. No row runs an install; `check` only reads and
# judges.
#
# The last section fails each read a verdict rests on in the way that hides
# best: the tool runs, prints what it prints, and exits non-zero. Most of these
# reads run where errexit is off, so only their own check can see that.
#
# Every row runs and reports whatever another one answered: a row's state root
# is its own, and one run says which rows a change turns red.
#
# No row reaches a package manager. Each name a check could ask for is answered
# by a stand-in in this root, before anything else on PATH: a real one goes to a
# public registry. A row that needs an answer puts its own stand-in in front.
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

guard_bin="${tmp_root}/guard-bin"
guard_names=(npm npx yarn yarnpkg pnpm pnpx corepack pip pip3 pipx uv poetry cargo go gem bundle mvn dotnet nuget)
mkdir -p "${guard_bin}"
for tool in "${guard_names[@]}"; do
  printf '#!/bin/sh\nexit 127\n' > "${guard_bin}/${tool}"
done
chmod +x "${guard_bin}"/*
PATH="${guard_bin}:${PATH}"

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
  "fixture-unpatched@1.0.0": [{"package":"fixture-unpatched","version":"1.0.0","direct":true}],
  "fixture-paged@1.0.0": [{"package":"fixture-paged","version":"1.0.0","direct":true}],
  "fixture-bad-token@1.0.0": [{"package":"fixture-bad-token","version":"1.0.0","direct":true}],
  "fixture-endless@1.0.0": [{"package":"fixture-endless","version":"1.0.0","direct":true}],
  "fixture-kev-alias@1.0.0": [{"package":"fixture-kev-alias","version":"1.0.0","direct":true}],
  "fixture-record-missing@1.0.0": [{"package":"fixture-record-missing","version":"1.0.0","direct":true}],
  "fixture-record-other@1.0.0": [{"package":"fixture-record-other","version":"1.0.0","direct":true}],
  "fixture-stale-record@1.0.0": [{"package":"fixture-stale-record","version":"1.0.0","direct":true}],
  "fixture-precise@1.0.0": [{"package":"fixture-precise","version":"1.0.0","direct":true}]
}
JSON
closure_with() {
  jq -c --arg dep "$1" '. + {"fixture-vuln@1.0.1": [{"package":"fixture-vuln","version":"1.0.1","direct":true},{"package":$dep,"version":"1.0.0","direct":false}]}' "${closures}" > "$2"
}
closure_with fixture-dep "${tmp_root}/closures-vulnerable.json"
closure_with fixture-kev-dep "${tmp_root}/closures-kev.json"
closure_with fixture-extra "${tmp_root}/closures-extra.json"
export SAFEDEPS_NPM_CLOSURE_FIXTURE_JSON="${closures}"

# jq, with one call gone wrong. A call is matched by its arguments and, when it
# reads standard input, by that input too: a writer that takes its item on
# stdin is matched by the item. The stub reads stdin only for a call that jq
# reads it for, reads it once, and hands the real jq the same bytes.
stub_bin="${tmp_root}/stub-bin"
mkdir -p "${stub_bin}"
real_jq=$(command -v jq)
real_cat=$(command -v cat)
real_grep=$(command -v grep)
real_mktemp=$(command -v mktemp)
real_rm=$(command -v rm)
cat > "${stub_bin}/jq" <<STUB
#!/usr/bin/env bash
# jq reads stdin unless -n is given, an input file follows the filter, or the
# rest of the line is --args or --jsonargs.
reads=1 filter=0 rest=files skip=0 opts=1
for arg in "\$@"; do
  if (( skip > 0 )); then skip=\$((skip - 1)); continue; fi
  if (( opts )); then
    case "\${arg}" in
      --) opts=0; continue ;;
      --arg|--argjson|--slurpfile|--rawfile) skip=2; continue ;;
      -f|--from-file) filter=1; skip=1; continue ;;
      -L|--indent) skip=1; continue ;;
      -L?*) continue ;;
      --null-input) reads=0; continue ;;
      --args|--jsonargs) rest=args; continue ;;
      --*) continue ;;
      -?*) [[ "\${arg}" != *n* ]] || reads=0; continue ;;
    esac
  fi
  if (( filter == 0 )); then filter=1; elif [[ "\${rest}" == files ]]; then reads=0; fi
done
input=""
if (( reads )); then
  input=\$("${real_mktemp}" "${tmp_root}/stub-stdin.XXXXXX") || exit 2
  "${real_cat}" > "\${input}" || exit 2
fi
hit=1
while IFS= read -r wanted; do
  [[ -n "\${wanted}" ]] || { hit=0; continue; }
  [[ "\$*" != *"\${wanted}"* ]] || continue
  [[ -n "\${input}" ]] && "${real_grep}" -qF -- "\${wanted}" "\${input}" && continue
  hit=0
done <<< "\${STUB_MATCH:-}"
if [[ -n "\${input}" ]]; then
  exec < "\${input}"
  "${real_rm}" -f "\${input}"
fi
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

# A file replaced after the read that checked it: the tool runs, then the file
# SWAP_FILE holds SWAP_BODY when the arguments hold SWAP_AFTER, and the tool's own
# exit stands. A second read of that file sees what the check never saw.
swap_bin="${tmp_root}/swap-bin"
mkdir -p "${swap_bin}"
real_mv=$(command -v mv)
for tool in jq mv cp; do
  real=$(command -v "${tool}")
  cat > "${swap_bin}/${tool}" <<STUB
#!/usr/bin/env bash
"${real}" "\$@"
status=\$?
if [[ "\$*" == *"\${SWAP_AFTER}"* ]]; then
  printf '%s' "\${SWAP_BODY}" > "\${SWAP_FILE}.swap"
  "${real_mv}" -f "\${SWAP_FILE}.swap" "\${SWAP_FILE}"
fi
exit "\${status}"
STUB
done
chmod +x "${swap_bin}"/*
# The swap reached the file, so a row that holds says something: a needle that
# stopped matching would leave the row green with nothing injected.
swap_fired() {
  [[ "$(cat "$1")" == "$2" ]] || no "the file was not replaced: $(cat "$1")"
}

# The two status writers, the overlay and the line one package's answer is.
writer_batch='status_of($kev.exploited; .osv.vulns'
writer_one='status_of($kev_result.exploited'
writer_overlay='.cveID as $id'
writer_item='index: $item.index'

# Every PATH a row runs with, and what answers on it for each package manager.
only_stand_ins() {
  local path tool found
  for path in "${PATH}" "${stub_bin}:${PATH}" "${swap_bin}:${PATH}"; do
    for tool in "${guard_names[@]}"; do
      found=$(PATH="${path}" command -v "${tool}") || no "nothing answers for ${tool}"
      [[ "${found}" == "${tmp_root}/"* ]] || no "${tool} is ${found}"
    done
  done
}
row "only stand-ins answer for ${guard_names[*]}" only_stand_ins

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

# The core the CLI writes the approvals store with, to read the store back.
# shellcheck source=lib/core-reader.sh
source "${ROOT_DIR}/scripts/test/lib/core-reader.sh"
core_reader_init "${ROOT_DIR}"
core="${SAFEDEPS_TEST_CORE}"
store_of() { printf '%s/approvals.jsonl' "$1"; }
# The hashes the approvals store in HOME vouches for, one a line, or a failure
# when the store cannot be read.
vouched() {
  local index
  index=$(env SAFEDEPS_HOME="$1" "${core}" approvals index) || return 1
  jq -r '.hashes | keys[]' <<< "${index}"
}

# No approval of any kind: in the report, in the ledger, in the record or in
# the approvals store.
no_approval() {
  local hashes
  jq -e '.approved != true' <<< "${json}" >/dev/null || no "the report approves: ${json}"
  [[ -z "$(find "${home}/approved-specs" -name '*.json' -type f 2>/dev/null)" ]] || no "a ledger entry was written"
  ! grep -q 'check approve' "${home}/advisory.log" 2>/dev/null || no "advisory.log records an approval"
  if [[ -e "$(store_of "${home}")" ]]; then
    hashes=$(vouched "${home}") || no "the approvals store cannot be read"
    [[ -z "${hashes}" ]] || no "the approvals store vouches for ${hashes}"
  fi
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
# The catalog read is a copy, and the copy keeps the file's time: what an approval
# records about the catalog is what the file was.
kev_status_recorded() {
  local ecosystem="$1" field="$2" age="$3" want="$4" entry
  fresh_home
  plant_kev "${kev_catalog}" "${age}"
  check_in "${ecosystem}" fixture-clean@1.0.0 "${kev_down[@]}"
  passed_clean
  entry=$(find "${home}/approved-specs" -name '*.json' -type f)
  [[ "$(jq -r "${field}" "${entry}")" == "${want}" ]] || no "the entry says $(jq -r "${field}" "${entry}")"
}
# A catalog that holds no answer and that this user cannot write still gives way:
# the copy of it is the run's own, and a second copy takes its place.
kev_read_only_no_answer() {
  fresh_home
  plant_kev '{"vulnerabilities":[]}'
  chmod 400 "$(kev_file)"
  check_in "$1" fixture-clean@1.0.0
  passed_clean
  kev_replaced
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
row "npm: a read-only file that holds no catalog is replaced" kev_read_only_no_answer npm
row "pypi: a read-only file that holds no catalog is replaced" kev_read_only_no_answer pypi
row "npm: an approval from a stale KEV catalog says it was stale" kev_status_recorded npm '.evidence.provider.results[0].kev.status' stale stale
row "npm: an approval from a fresh KEV catalog says it was ok" kev_status_recorded npm '.evidence.provider.results[0].kev.status' fresh ok
row "pypi: an approval from a stale KEV catalog says it was stale" kev_status_recorded pypi '.evidence.kev.status' stale stale
row "pypi: an approval from a fresh KEV catalog says it was ok" kev_status_recorded pypi '.evidence.kev.status' fresh ok

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
  env SAFEDEPS_HOME="${home}" bash -c 'source lib/providers/providers.sh; safedeps_require_http_client() { return 1; }; if safedeps_kev_refresh_catalog "$1"; then exit 0; fi; exit 1' reader "${home}/catalog.json" >/dev/null 2>&1 || rc=$?
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
for body in '' 'null' '{}' '{"vulnerabilities":null}' '{"vulnerabilities":[]}' '{"vulnerabilities":{}}' '{"vulnerabilities":[{}]}'; do
  row "the overlay does not read '${body}' as a catalog with nothing listed" kev_overlay_refuses "${body}"
done

# The catalog a package is looked up in is the one the rule read. Replaced after
# that read, it changes nothing: what the rule passed still answers, listing
# included, and the replacement waits for the next run's read. It once read the
# file again: a catalog that listed a package passed the rule, the replacement
# was looked up in, and an empty list approved what the rule never saw.
kev_swapped() {
  local ecosystem="$1" spec="$2" answer="$3" source="$4" body="$5"
  local env_args=(PATH="${swap_bin}:${PATH}" SWAP_AFTER=known_exploited_vulnerabilities SWAP_BODY="${body}")
  fresh_home
  case "${source}" in
    fresh) plant_kev "${kev_catalog}"; env_args+=("${kev_down[@]}") ;;
    stale) plant_kev "${kev_catalog}" stale; env_args+=("${kev_down[@]}") ;;
    live) ;;
  esac
  check_in "${ecosystem}" "${spec}" "${env_args[@]}" SWAP_FILE="$(kev_file)"
  "${answer}"
  swap_fired "$(kev_file)" "${body}"
}
for body in '' 'null' '{"vulnerabilities":[]}' '{"vulnerabilities":{}}' '{"vulnerabilities":[{}]}' '{"vulnerabilities":[{"cveID":"CVE-2026-0001"}]}'; do
  for source in fresh stale live; do
    for ecosystem in npm pypi; do
      row "${ecosystem}: a ${source} KEV catalog replaced by '${body}' after its read still lists" kev_swapped "${ecosystem}" fixture-kev@1.0.0 hard_blocked "${source}" "${body}"
    done
  done
  row "npm: a KEV catalog replaced by '${body}' after its read still clears what it does not list" kev_swapped npm fixture-clean@1.0.0 passed_clean fresh "${body}"
  row "non-npm: a KEV catalog replaced by '${body}' after its read still clears what it does not list" kev_swapped pypi fixture-clean@1.0.0 passed_clean fresh "${body}"
done

# The next run reads what the replacement left, by the rule.
kev_replaced_then_read() {
  local ecosystem="$1" body="$2"
  kev_swapped "${ecosystem}" fixture-kev@1.0.0 hard_blocked fresh "${body}"
  check_in "${ecosystem}" fixture-clean@1.0.0 "${kev_down[@]}"
  unavailable
}
for body in '{"vulnerabilities":[]}' '{"vulnerabilities":{}}' '{"vulnerabilities":[{}]}'; do
  row "npm: what replaced a KEV catalog is read by the rule on the next run: '${body}'" kev_replaced_then_read npm "${body}"
  row "non-npm: what replaced a KEV catalog is read by the rule on the next run: '${body}'" kev_replaced_then_read pypi "${body}"
done

kev_said_once() {
  fresh_home
  plant_kev "${kev_catalog}" stale
  check_in npm fixture-parent@1.0.0 "${kev_down[@]}"
  passed_clean
  [[ "$(grep -c 'using stale local catalog' "${home}/advisory.log")" == 1 ]] || no "the stale catalog is not said once for two packages"
}
row "npm: a closure reads the KEV catalog once, and says it is stale once" kev_said_once

# What re-check says of an entry no provider answered: neither still clean nor
# revoked, an error of the run (exit 1), and the entry stays.
recheck_unanswered() {
  [[ "${rc}" == 1 ]] || no "exit ${rc}: ${json}"
  jq -e '.checked == 1 and .still_clean == 0 and .revoked == []
    and (.errors | map(.kind) == ["provider_unavailable"])
    and (.errors[0] | .ecosystem == "pypi" and .package == "fixture-clean" and .version == "1.0.0")' <<< "${json}" >/dev/null \
    || no "the report: ${json}"
  grep -q 're-check unanswered ecosystem=pypi package=fixture-clean version=1.0.0' "${home}/advisory.log" || no "advisory.log has no unanswered line"
  [[ -n "$(find "${home}/approved-specs" -name '*.json' -type f)" ]] || no "the entry was removed"
  jq -e '(.revoked_at // "") == ""' "$(find "${home}/approved-specs" -name '*.json' -type f | head -1)" >/dev/null || no "the entry was revoked"
}
kev_recheck_counts_nothing() {
  fresh_home
  check_in pypi fixture-clean@1.0.0
  [[ "${rc}" == 0 ]] || no "the first run exits ${rc}: ${json}"
  : > "$(kev_file)"
  rc=0
  json=$(env "${kev_down[@]}" SAFEDEPS_HOME="${home}" ./bin/safedeps --json re-check 2>"${home}/stderr") || rc=$?
  recheck_unanswered
}
row "re-check with no KEV catalog to read counts nothing clean and revokes nothing" kev_recheck_counts_nothing

# An answer of an earlier run is not an answer. Every check asks OSV, and a
# file left where the CLI once kept an OSV answer (cache/osv/, still fresh, any
# body) is never read: an advisory published since is not in it. A fresh no
# finding there once approved a package OSV had since named, and approved
# anything while OSV was down. The file is planted under the old name, so a
# read of it would change the verdict: the vulnerable package would pass, the
# clean one fail, and the down row approve. Go asks every module prefix, so a
# file is planted for each.
osv_cache_file() {
  local ecosystem="$1" spec="$2" key
  key=$(SAFEDEPS_HOME="${home}" bash -c 'source lib/providers/providers.sh; safedeps_cache_key osv "$(safedeps_osv_ecosystem "$1")" "${2%@*}" "${2##*@}"' cache-key "${ecosystem}" "${spec}")
  printf '%s/cache/osv/%s.json' "${home}" "${key}"
}
plant_osv() {
  local ecosystem="$1" spec="$2" body="$3" name="${2%@*}" version="${2##*@}"
  mkdir -p "${home}/cache/osv"
  if [[ "${ecosystem}" == go ]]; then
    printf '%s' "${body}" > "$(osv_cache_file go "${spec}")"
    printf '%s' "${body}" > "$(osv_cache_file go "${name%/*}@${version}")"
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
# The planted file is as it was planted: nothing read it into an answer, and
# nothing wrote an answer there.
planted_untouched() {
  local body="$1"
  if [[ "${body}" == unreadable ]]; then
    [[ ! -r "${planted}" ]] || no "the unreadable file was replaced"
  else
    [[ "$(cat "${planted}")" == "${body}" ]] || no "the planted file now holds: $(cat "${planted}")"
  fi
}
osv_down=(SAFEDEPS_OSV_API_URL="${closed_port}" SAFEDEPS_OSV_BATCH_API_URL="${closed_port}")

earlier_answer_vulnerable() {
  local ecosystem="$1" spec="$2" body="$3"
  fresh_home
  plant_osv "${ecosystem}" "${spec}" "${body}"
  check_in "${ecosystem}" "${spec}"
  [[ "${rc}" == 2 ]] || no "exit ${rc}: ${json}"
  jq -e '.result == "cve_unpatched" and .approved == false' <<< "${json}" >/dev/null || no "the report: ${json}"
  no_approval
  planted_untouched "${body}"
}
earlier_answer_clean() {
  local ecosystem="$1" spec="$2" body="$3"
  fresh_home
  plant_osv "${ecosystem}" "${spec}" "${body}"
  check_in "${ecosystem}" "${spec}"
  passed_clean
  planted_untouched "${body}"
}
earlier_answer_down() {
  local ecosystem="$1" spec="$2" body="$3"
  fresh_home
  plant_osv "${ecosystem}" "${spec}" "${body}"
  check_in "${ecosystem}" "${spec}" "${osv_down[@]}"
  unavailable
  planted_untouched "${body}"
}
for body in '' '{}' '{"vulns":[]}' '{"vulns":null}' '{"vulns":[{"id":"CVE-2026-1002"}]}' unreadable; do
  for case in 'npm fixture-unpatched@1.0.0 fixture-clean@1.0.0' \
    'pypi fixture-unpatched@1.0.0 fixture-clean@1.0.0' \
    'go example.com/mod/cmd/tool@v1.0.0 example.com/other/cmd/tool@v1.0.0'; do
    read -r ecosystem vulnerable clean <<< "${case}"
    row "${ecosystem}: an earlier answer of '${body}' is not read and the provider's advisory counts" earlier_answer_vulnerable "${ecosystem}" "${vulnerable}" "${body}"
    row "${ecosystem}: an earlier answer of '${body}' is not read and a clean package passes" earlier_answer_clean "${ecosystem}" "${clean}" "${body}"
    row "${ecosystem}: an earlier answer of '${body}' with OSV down approves nothing" earlier_answer_down "${ecosystem}" "${clean}" "${body}"
  done
done

# A check keeps no OSV answer: nothing is written where the next run could read
# it. The record of an advisory OSV named is kept under its id and `modified`,
# the pair that names one record, so a later record of the same advisory is
# another file.
no_answer_kept() {
  local ecosystem="$1"
  fresh_home
  check_in "${ecosystem}" fixture-unpatched@1.0.0
  [[ "${rc}" == 2 ]] || no "the vulnerable check exits ${rc}: ${json}"
  check_in "${ecosystem}" fixture-clean@1.0.0
  passed_clean
  [[ ! -e "${home}/cache/osv" ]] || no "an answer was kept: $(find "${home}/cache/osv" -type f)"
}
row "npm: a check keeps no OSV answer" no_answer_kept npm
row "non-npm: a check keeps no OSV answer" no_answer_kept pypi
# An approval says where its OSV answer came from: `answered` is "live", asked
# by this check, and `observed_at` is when the check held the whole answer. It
# is a UTC time no earlier than the query (`queried_at`) and within the check.
# The npm closure is asked by the batch query and pypi by the single query,
# and each writes its own status, so the row reads both.
answered_live() {
  local ecosystem osv queried entry before after
  for ecosystem in npm pypi; do
    if [[ "${ecosystem}" == npm ]]; then
      osv='.evidence.provider.results[0].provider_status.osv' queried='.evidence.provider.results[0].queried_at'
    else
      osv='.evidence.provider_status.osv' queried='.evidence.queried_at'
    fi
    fresh_home
    before=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    check_in "${ecosystem}" fixture-clean@1.0.0
    after=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    passed_clean
    entry=$(find "${home}/approved-specs" -name '*.json' -type f)
    jq -e --arg before "${before}" --arg after "${after}" "
      ${osv} as \$o | ${queried} as \$q
      | \$o.answered == \"live\"
        and (\$o.observed_at | type == \"string\" and test(\"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\$\"))
        and \$o.observed_at >= \$q and \$o.observed_at >= \$before and \$o.observed_at <= \$after" "${entry}" >/dev/null \
      || no "${ecosystem}: the entry's OSV status $(jq -c "${osv}" "${entry}"), queried at $(jq -r "${queried}" "${entry}"), check ${before}..${after}"
  done
}
row "an approval says OSV was asked live and when this check held its answer" answered_live
record_kept_by_pair() {
  local key
  fresh_home
  check_in npm fixture-unpatched@1.0.0
  [[ "${rc}" == 2 ]] || no "exit ${rc}: ${json}"
  key=$(SAFEDEPS_HOME="${home}" bash -c 'source lib/providers/providers.sh; safedeps_cache_key osv-vuln CVE-2026-1002 2026-01-01T00:00:00Z ""')
  jq -e '.id == "CVE-2026-1002" and .modified == "2026-01-01T00:00:00Z"' "${home}/cache/osv-vuln/${key}.json" >/dev/null \
    || no "the record is not kept under its id and modified: $(ls "${home}/cache/osv-vuln")"
}
row "npm: an advisory's record is kept under its id and modified" record_kept_by_pair

# A directory where the old cache file went is nothing the check reads.
old_name_is_a_directory() {
  local ecosystem="$1" spec="$2"
  fresh_home
  mkdir -p "$(osv_cache_file "${ecosystem}" "${spec}")"
  check_in "${ecosystem}" "${spec}"
  passed_clean
}
row "npm: a directory where the old cache file went changes nothing" old_name_is_a_directory npm fixture-clean@1.0.0
row "non-npm: a directory where the old cache file went changes nothing" old_name_is_a_directory pypi fixture-clean@1.0.0

# An answer in pages is read to its end, by the token OSV gives each query.
# A page token that is not one, and an answer that has not ended within the
# page limit, are no answer.
paged_advisory_counts() {
  local ecosystem="$1"
  fresh_home
  check_in "${ecosystem}" fixture-paged@1.0.0
  [[ "${rc}" == 2 ]] || no "exit ${rc}: ${json}"
  jq -e '.result == "cve_unpatched" and .approved == false' <<< "${json}" >/dev/null || no "the report: ${json}"
  no_approval
  grep -q "pages=2" "${home}/advisory.log" || no "advisory.log does not say two pages were read"
}
row "npm: an advisory on the second page of a batch answer counts" paged_advisory_counts npm
row "non-npm: an advisory on the second page of an answer counts" paged_advisory_counts pypi
paged_no_answer() {
  local ecosystem="$1" spec="$2" line="$3"
  fresh_home
  check_in "${ecosystem}" "${spec}"
  unavailable
  grep -q "${line}" "${home}/advisory.log" || no "advisory.log has no '${line}' line"
}
row "npm: a batch page token that is not a string approves nothing" paged_no_answer npm fixture-bad-token@1.0.0 'OSV batch result is not an answer'
row "non-npm: a page token that is not a string approves nothing" paged_no_answer pypi fixture-bad-token@1.0.0 'OSV live query failed'
row "npm: a batch answer that has not ended within the page limit approves nothing" paged_no_answer npm fixture-endless@1.0.0 'OSV batch answer did not end within 20 pages'
row "non-npm: an answer that has not ended within the page limit approves nothing" paged_no_answer pypi fixture-endless@1.0.0 'OSV answer did not end within 20 pages'

# querybatch names an advisory by its id and `modified`; the record says the
# rest. A KEV listing found only by the record's alias blocks, and a record
# that cannot be read, or that is another advisory's, is no answer.
record_alias_on_kev() {
  fresh_home
  check_in npm fixture-kev-alias@1.0.0
  hard_blocked
}
row "npm: a KEV listing named only by the record's alias blocks" record_alias_on_kev
row "npm: an advisory whose record OSV does not have approves nothing" paged_no_answer npm fixture-record-missing@1.0.0 'OSV record read failed id=GHSA-fixt-gone-0000 status=404'
row "npm: an advisory whose record is another advisory's approves nothing" paged_no_answer npm fixture-record-other@1.0.0 'OSV record read failed id=GHSA-fixt-othr-0000 status=200'
# A record is the one querybatch named only when it has that id and the same
# time as that `modified`. A record at another time is no answer: it is not
# used and not kept. A file kept under the pair that holds another record is
# not that record either: it is asked for again, left as it was, and a live
# record that matches replaces it.
stale_id=GHSA-fixt-stal-0000
stale_current=2026-01-02T00:00:00Z
serve_stale() {
  jq --argjson on "$1" '.serve_stale_record = $on' "${state_file}" > "${state_file}.next" && mv "${state_file}.next" "${state_file}"
}
stale_key() { SAFEDEPS_HOME="${home}" bash -c 'source lib/providers/providers.sh; safedeps_cache_key osv-vuln "$1" "$2" ""' _ "${stale_id}" "${stale_current}"; }
stale_file() { printf '%s/cache/osv-vuln/%s.json' "${home}" "$(stale_key)"; }
stale_record_not_used() {
  trap 'serve_stale false' EXIT
  fresh_home
  serve_stale true
  check_in npm fixture-stale-record@1.0.0
  unavailable
  grep -q "OSV record read failed id=${stale_id} status=200" "${home}/advisory.log" || no "advisory.log does not say the record was not read"
  [[ -z "$(find "${home}/cache/osv-vuln" -type f 2>/dev/null)" ]] || no "the record at another modified was kept: $(find "${home}/cache/osv-vuln" -type f)"
}
row "npm: a record OSV serves at another modified approves nothing and is not kept" stale_record_not_used
stale_kept_then_current() {
  trap 'serve_stale false' EXIT
  fresh_home
  mkdir -p "${home}/cache/osv-vuln"
  printf '{"id":"%s","modified":"2026-01-01T00:00:00Z","aliases":["%s"]}' "${stale_id}" "${stale_id}" > "$(stale_file)"
  cp "$(stale_file)" "${home}/kept.before"
  serve_stale true
  check_in npm fixture-stale-record@1.0.0
  unavailable
  grep -q "WARN OSV record kept for id=${stale_id} modified=${stale_current} is not that record; asking OSV again" "${home}/advisory.log" \
    || no "advisory.log does not say the kept record is not that record: $(cat "${home}/advisory.log")"
  grep -q "OSV record read failed id=${stale_id} status=200" "${home}/advisory.log" || no "advisory.log does not say the live record was not read"
  cmp -s "$(stale_file)" "${home}/kept.before" || no "the kept file was changed by a record that is not the one named"
  serve_stale false
  check_in npm fixture-stale-record@1.0.0
  hard_blocked
  jq -e --arg m "${stale_current}" '.modified == $m and .aliases == ["CVE-2026-9999"]' "$(stale_file)" >/dev/null \
    || no "the matching live record did not replace the kept file: $(cat "$(stale_file)")"
}
row "npm: a kept file that is not the named record is asked again, and the matching record replaces it" stale_kept_then_current
stale_record_control() {
  fresh_home
  check_in npm fixture-stale-record@1.0.0
  hard_blocked
  jq -e --arg m "${stale_current}" '.modified == $m' "$(stale_file)" >/dev/null || no "the matching record is not kept under its pair"
  ! grep -q 'is not that record' "${home}/advisory.log" || no "a fresh home warned about a kept record"
}
row "npm: the record querybatch named, KEV-listed by its alias, blocks and is kept" stale_record_control
# querybatch names an advisory's `modified` to the microsecond and its record
# carries the same time with nine digits, as OSV does (the fixture's
# PRECISE). That record is the one querybatch named, by the microsecond rule
# (osv_same_time): the advisory counts, and the record is kept under the pair
# querybatch gave. A record one microsecond later is another time: it is no
# answer and is not kept. A kept record with nine digits answers again for the
# six while OSV serves the later one, so the second answer comes from the file.
precise_id=GHSA-fixt-prec-0000
precise_batch=2026-09-10T03:50:51.191256Z
precise_record=2026-09-10T03:50:51.191256883Z
serve_later() {
  jq --argjson on "$1" '.serve_later_record = $on' "${state_file}" > "${state_file}.next" && mv "${state_file}.next" "${state_file}"
}
precise_file() {
  printf '%s/cache/osv-vuln/%s.json' "${home}" \
    "$(SAFEDEPS_HOME="${home}" bash -c 'source lib/providers/providers.sh; safedeps_cache_key osv-vuln "$1" "$2" ""' _ "${precise_id}" "${precise_batch}")"
}
# The condition, measured: the fixture's querybatch names the advisory with six
# digits, and its record carries nine.
precise_served() {
  local named record
  named=$(curl -fsS -H 'Content-Type: application/json' -d '{"queries":[{"version":"1.0.0","package":{"name":"fixture-precise","ecosystem":"npm"}}]}' \
    "${SAFEDEPS_OSV_BATCH_API_URL}" | jq -r '.results[0].vulns[0].modified')
  record=$(curl -fsS "${SAFEDEPS_OSV_BATCH_API_URL%/querybatch}/vulns/${precise_id}" | jq -r '.modified')
  [[ "${named}" == "${precise_batch}" && "${record}" == "$1" ]] || no "the fixture names ${named} and serves ${record}, not ${precise_batch} and $1"
}
precise_counts() {
  [[ "${rc}" == 2 ]] || no "exit ${rc}: ${json}"
  jq -e --arg id "${precise_id}" --arg m "${precise_record}" '.result == "cve_unpatched" and .approved == false
    and ([.closure_vulnerabilities[] | select(.package == "fixture-precise") | .vulnerabilities[] | select(.id == $id and .modified == $m)] | length) == 1' \
    <<< "${json}" >/dev/null || no "the report: ${json}"
  no_approval
  ! grep -q "OSV record read failed id=${precise_id}" "${home}/advisory.log" || no "advisory.log says the record was not read"
  jq -e --arg m "${precise_record}" '.modified == $m' "$(precise_file)" >/dev/null 2>&1 \
    || no "the record is not kept under the pair querybatch gave: $(ls "${home}/cache/osv-vuln" 2>/dev/null)"
}
precise_record_named() {
  fresh_home
  precise_served "${precise_record}"
  check_in npm fixture-precise@1.0.0
  precise_counts
}
row "npm: a record with nine digits for the six querybatch gave is the named record: the advisory counts and the record is kept" precise_record_named
precise_record_later() {
  trap 'serve_later false' EXIT
  fresh_home
  serve_later true
  precise_served 2026-09-10T03:50:51.191257883Z
  check_in npm fixture-precise@1.0.0
  unavailable
  grep -q "OSV record read failed id=${precise_id} status=200" "${home}/advisory.log" || no "advisory.log does not say the record was not read"
  [[ -z "$(find "${home}/cache/osv-vuln" -type f 2>/dev/null)" ]] || no "the later record was kept: $(find "${home}/cache/osv-vuln" -type f)"
}
row "npm: a record one microsecond later than querybatch named approves nothing and is not kept" precise_record_later
precise_record_kept() {
  trap 'serve_later false' EXIT
  fresh_home
  check_in npm fixture-precise@1.0.0
  precise_counts
  cp "$(precise_file)" "${home}/kept.before"
  serve_later true
  precise_served 2026-09-10T03:50:51.191257883Z
  check_in npm fixture-precise@1.0.0
  precise_counts
  ! grep -q 'is not that record' "${home}/advisory.log" || no "the kept record was read as another record: $(grep 'OSV record' "${home}/advisory.log")"
  cmp -s "$(precise_file)" "${home}/kept.before" || no "the kept record was replaced: $(cat "$(precise_file)")"
}
row "npm: a kept record with nine digits answers again for the six querybatch gave, while OSV serves a later one" precise_record_kept
record_url_not_derived() {
  fresh_home
  check_in npm fixture-unpatched@1.0.0 SAFEDEPS_OSV_BATCH_API_URL="${SAFEDEPS_OSV_BATCH_API_URL}?mirror=1"
  unavailable
  grep -q 'OSV record URL cannot be derived from' "${home}/advisory.log" || no "advisory.log does not say why"
}
row "npm: a batch URL with no record URL beside it approves nothing an advisory named" record_url_not_derived

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
  check_with npm fixture-vuln@1.0.0 SAFEDEPS_OSV_API_URL="${closed_port}"
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

# The fixture fails each querybatch that names a package of batch_fails and
# answers every other one, so a row can fail the candidate's batch alone.
fail_batches() {
  jq --argjson names "$1" '.batch_fails = $names' "${state_file}" > "${state_file}.next" && mv "${state_file}.next" "${state_file}"
}
# Only the candidate's batch fails: the requested version is judged, and the
# candidate it found has no answer. Under the same fault a package the fault
# does not name, and the requested version whose candidate does not name it,
# are answered.
candidate_batch_failed() {
  trap 'fail_batches "[]"' EXIT
  fail_batches '["fixture-extra@1.0.0"]'
  fresh_home
  check_in npm fixture-clean@1.0.0
  passed_clean
  fresh_home
  check_in npm fixture-vuln@1.0.0
  [[ "${rc}" == 0 ]] || no "the first run exits ${rc}: ${json}"
  jq -e '.result == "patched_available" and .approved == true and .suggested_spec == "1.0.1"' <<< "${json}" >/dev/null \
    || no "the first run's report: ${json}"
  check_in npm fixture-vuln@1.0.0 SAFEDEPS_NPM_CLOSURE_FIXTURE_JSON="${tmp_root}/closures-extra.json"
  [[ "${rc}" == 4 ]] || no "exit ${rc}: ${json}"
  jq -e '.result == "provider_unavailable" and .approved == false and .resolved_version == "1.0.0" and .suggested_spec == "1.0.1"' <<< "${json}" >/dev/null \
    || no "the report: ${json}"
  grep -q 'check fail-closed' "${home}/advisory.log" || no "advisory.log has no fail-closed line"
  grep -q 'OSV batch query failed status=500' "${home}/advisory.log" || no "advisory.log does not say a batch failed"
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

# ---- the approvals store ----------------------------------------------------
#
# An approval is a line in the approvals store, its `check approve(...)` line
# in advisory.log and a ledger entry, written in that order under the store
# lock, and the rename that puts the entry in place is the commit point
# (`safedeps-core approvals commit`, called by sf_check_commit in bin/safedeps).
# Before the store line the commit removes an entry at the path that the store
# does not vouch for. A cache hit is an approval the store vouches for, read
# from the store first and the entry after. Each fault below is put into the
# real CLI and the real core: a store the core may not open, a store that is a
# directory, a core killed while it waits for the store lock, before its rename
# or after it, an entry replaced after a core died, a rename that fails, a tree
# with no core, and commits of one spec that meet.
#
# Some faults no file system here can be made to show to the CLI: a store line
# the core cannot write once it holds the lock, a sync that fails alone, a
# store that cannot be read under the lock, an unlink that fails. rust-core
# holds the commit's answer to each, with the failure put into the core.

# The `check approve(...)` line in HOME's advisory.log, without its time.
approve_line() { sed -n 's/^\[[^]]*\] \(check approve(.*\)$/\1/p' "$1/advisory.log"; }
# The line number of the first line in HOME's advisory.log that holds TEXT.
log_at() { grep -nF -- "$2" "$1/advisory.log" | head -n 1 | cut -d: -f1; }
# The ledger entries in HOME.
entries() { find "$1/approved-specs" -name '*.json' -type f 2>/dev/null; }
# The store in HOME holds one line, written by check, and it is the approval
# advisory.log records, of KIND and HASH.
one_check_line() {
  local home="$1" kind="$2" hash="$3" line hashes
  line=$(approve_line "${home}")
  [[ "$(grep -c . <<< "${line}")" == 1 && "${line}" == "check approve(${kind}) "*" hash=${hash}"* ]] \
    || no "advisory.log's approval is not one ${kind} line of ${hash}: ${line}"
  hashes=$(vouched "${home}") || no "the approvals store cannot be read"
  [[ "${hashes}" == "${hash}" ]] || no "the approvals store vouches for '${hashes}', not ${hash}"
  [[ "$(grep -c . "$(store_of "${home}")")" == 1 ]] || no "the approvals store holds $(grep -c . "$(store_of "${home}")") lines"
  jq -e --arg line "${line}" '.via == "check" and .record == $line' "$(store_of "${home}")" >/dev/null \
    || no "the store line is not advisory.log's approval: $(cat "$(store_of "${home}")")"
}

store_line_for_every_approval() {
  local ecosystem spec kind hash
  while read -r ecosystem spec kind; do
    check_with "${ecosystem}" "${spec}" < /dev/null
    [[ "${rc}" == 0 ]] || no "${ecosystem} ${spec}: exit ${rc}: ${json}"
    hash=$(jq -r '.spec_hash' <<< "${json}")
    one_check_line "${home}" "${kind}" "${hash}"
  done <<'PATHS'
npm fixture-clean@1.0.0 clean closure
npm fixture-vuln@1.0.0 patched closure
pypi fixture-clean@1.0.0 clean
pypi fixture-vuln@1.0.0 patched
PATHS
}
row "every approval a check makes, clean, patched and closure, leaves its line in the approvals store" store_line_for_every_approval

vouched_entry_is_a_cache_hit() {
  local ecosystem hash
  for ecosystem in npm pypi; do
    check_with "${ecosystem}" fixture-clean@1.0.0
    [[ "${rc}" == 0 ]] || no "${ecosystem}: the first run exits ${rc}: ${json}"
    hash=$(jq -r '.spec_hash' <<< "${json}")
    check_in "${ecosystem}" fixture-clean@1.0.0
    [[ "${rc}" == 0 ]] || no "${ecosystem}: the second run exits ${rc}: ${json}"
    jq -e --arg hash "${hash}" '.result == "already_approved" and .spec_hash == $hash' <<< "${json}" >/dev/null || no "${ecosystem}: the report: ${json}"
    grep -qF "check approve(cache) ecosystem=${ecosystem} package=fixture-clean version=1.0.0 hash=${hash}" "${home}/advisory.log" \
      || no "${ecosystem}: advisory.log has no cache line"
    ! grep -q 'check ledger-unvouched' "${home}/advisory.log" || no "${ecosystem}: the vouched entry was checked again"
    [[ "$(grep -c . "$(store_of "${home}")")" == 1 ]] || no "${ecosystem}: the cache hit wrote to the approvals store"
  done
}
row "an entry the approvals store vouches for is a cache hit, and the hit writes no store line" vouched_entry_is_a_cache_hit

hand_written_entry_is_checked() {
  local answer
  fresh_home
  SAFEDEPS_HOME="${home}" lib/ledger/ledger.sh approve pypi fixture-unpatched 1.0.0 >/dev/null
  answer=$(env SAFEDEPS_HOME="${home}" bash -c 'source lib/ledger/ledger.sh; safedeps_ledger_check pypi fixture-unpatched 1.0.0') \
    || no "control: the ledger does not read the hand-written entry as approved: ${answer}"
  jq -e '.approved == true' <<< "${answer}" >/dev/null || no "control: the ledger's answer: ${answer}"
  check_in pypi fixture-unpatched@1.0.0
  [[ "${rc}" == 2 ]] || no "exit ${rc}: ${json}"
  jq -e '.result == "cve_unpatched" and .approved == false' <<< "${json}" >/dev/null || no "the report: ${json}"
  grep -qE '^\[[^]]*\] check ledger-unvouched ecosystem=pypi package=fixture-unpatched version=1\.0\.0 hash=sha256:[0-9a-f]{64} store=not-vouched$' "${home}/advisory.log" \
    || no "advisory.log does not say the entry was checked again"
  ! grep -q 'check approve' "${home}/advisory.log" || no "advisory.log records an approval"
  [[ ! -e "$(store_of "${home}")" ]] || no "the approvals store was written"
}
row "a hand-written entry with an honest hash is checked again, and a check that blocks blocks" hand_written_entry_is_checked

copied_entry_is_checked_again() {
  local first hash
  check_with npm fixture-clean@1.0.0
  [[ "${rc}" == 0 ]] || no "the approval in the first home exits ${rc}: ${json}"
  first="${home}"
  hash=$(jq -r '.spec_hash' <<< "${json}")
  fresh_home
  mkdir -p "${home}/approved-specs"
  cp "$(entries "${first}")" "${home}/approved-specs/"
  check_in npm fixture-clean@1.0.0
  [[ "${rc}" == 0 ]] || no "exit ${rc}: ${json}"
  jq -e --arg hash "${hash}" '.result == "clean" and .spec_hash == $hash' <<< "${json}" >/dev/null || no "the report: ${json}"
  grep -qF "check ledger-unvouched ecosystem=npm package=fixture-clean version=1.0.0 hash=${hash} store=not-vouched" "${home}/advisory.log" \
    || no "advisory.log does not say the entry was checked again"
  ! grep -q 'check approve(cache)' "${home}/advisory.log" || no "the copied entry was a cache hit"
  one_check_line "${home}" "clean closure" "${hash}"
}
row "an entry copied whole from another home is checked again, and the store holds only the line that check made" copied_entry_is_checked_again

logged_only_entry_is_checked_again() {
  local hash
  check_with pypi fixture-clean@1.0.0
  [[ "${rc}" == 0 ]] || no "the first run exits ${rc}: ${json}"
  hash=$(jq -r '.spec_hash' <<< "${json}")
  # A state from before the store: the approval is in the ledger and in
  # advisory.log, and there is no store.
  rm -f "$(store_of "${home}")"
  check_in pypi fixture-clean@1.0.0
  [[ "${rc}" == 0 ]] || no "exit ${rc}: ${json}"
  jq -e --arg hash "${hash}" '.result == "clean" and .spec_hash == $hash' <<< "${json}" >/dev/null || no "the report: ${json}"
  grep -qF "check ledger-unvouched ecosystem=pypi package=fixture-clean version=1.0.0 hash=${hash} store=not-vouched" "${home}/advisory.log" \
    || no "advisory.log does not say the entry was checked again"
  [[ "$(vouched "${home}")" == "${hash}" ]] || no "the new approval is not in the store"
  [[ "$(jq -r '.via + " " + .record' "$(store_of "${home}")")" == "check check approve(clean) "* ]] || no "the store line: $(cat "$(store_of "${home}")")"
}
row "an entry whose approval is only in advisory.log is no cache hit, and is checked again" logged_only_entry_is_checked_again

# A commit the store refused before it put anything in place: no approval, no
# line of the commit in advisory.log or the store, and no staged entry left in
# the ledger directory LEDGER. advisory.log holds APPROVALS approve lines, the
# ones earlier checks made.
refused_at_the_store() {
  local approvals="$1" ledger_dir="$2"
  [[ "${rc}" == 4 ]] || no "exit ${rc}: ${json}"
  jq -e '.result == "error" and .approved == false and .error == "approvals_store_failed" and (has("ledger_entry_left") or has("ledger_entry_kept") | not)' <<< "${json}" >/dev/null \
    || no "the report: ${json}"
  [[ "$(grep -c 'check approve' "${home}/advisory.log")" == "${approvals}" ]] || no "advisory.log: $(cat "${home}/advisory.log")"
  grep -qF 'check fail-closed approvals-store ecosystem=' "${home}/advisory.log" || no "advisory.log has no fail-closed line"
  [[ -z "$(find "${ledger_dir}" -name '.*' 2>/dev/null)" ]] || no "a staged entry was left: $(ls -a "${ledger_dir}")"
}
# A file's inode and the digest of its bytes: the file itself, not a copy.
identity() {
  python3 -I -c 'import hashlib, os, sys
p = sys.argv[1]
print(os.lstat(p).st_ino, hashlib.sha256(open(p, "rb").read()).hexdigest())' "$1"
}
not_committed() {
  grep -qF "safedeps-core approvals: not committed: $(store_of "${home}") could not be opened and locked" "${home}/stderr" || no "stderr: $(cat "${home}/stderr")"
}

store_refuses_the_commit() {
  fresh_home
  : > "$(store_of "${home}")"
  chmod 400 "$(store_of "${home}")"
  check_in npm fixture-clean@1.0.0
  chmod 600 "$(store_of "${home}")"
  refused_at_the_store 0 "${home}/approved-specs"
  [[ -z "$(entries "${home}")" ]] || no "a ledger entry was written: $(entries "${home}")"
  not_committed
}
row "an approval the store refuses is never put in place: no entry, no approve line, no store line" store_refuses_the_commit

refused_where_the_store_vouches() {
  local entry before
  check_with pypi fixture-clean@1.0.0
  [[ "${rc}" == 0 ]] || no "the first run exits ${rc}: ${json}"
  entry=$(entries "${home}")
  jq -c '.expires_at = "2020-01-01T00:00:00Z"' "${entry}" > "${entry}.next" && mv -f "${entry}.next" "${entry}"
  before=$(identity "${entry}")
  chmod 400 "$(store_of "${home}")"
  check_in pypi fixture-clean@1.0.0
  chmod 600 "$(store_of "${home}")"
  refused_at_the_store 1 "${home}/approved-specs"
  [[ "$(entries "${home}")" == "${entry}" && "$(identity "${entry}")" == "${before}" ]] || no "the entry that was there changed"
  [[ "$(grep -c . "$(store_of "${home}")")" == 1 ]] || no "the store changed"
  not_committed
}
row "a commit the store refuses where it vouches for the hash approves nothing, and the entry stays as it was" refused_where_the_store_vouches

store_cannot_be_read() {
  fresh_home
  mkdir "$(store_of "${home}")"
  check_in npm fixture-clean@1.0.0
  refused_at_the_store 0 "${home}/approved-specs"
  [[ -z "$(entries "${home}")" ]] || no "a ledger entry was written"
  not_committed
}
row "a store that is not a file takes no commit, and nothing is put in place" store_cannot_be_read

unreadable_store_is_no_cache_hit() {
  local hash entry before
  check_with pypi fixture-clean@1.0.0
  [[ "${rc}" == 0 ]] || no "the first run exits ${rc}: ${json}"
  hash=$(jq -r '.spec_hash' <<< "${json}")
  entry=$(entries "${home}")
  before=$(identity "${entry}")
  rm -f "$(store_of "${home}")"
  mkdir "$(store_of "${home}")"
  check_in pypi fixture-clean@1.0.0
  refused_at_the_store 1 "${home}/approved-specs"
  grep -qF "check ledger-unvouched ecosystem=pypi package=fixture-clean version=1.0.0 hash=${hash} store=unreadable" "${home}/advisory.log" \
    || no "advisory.log does not say the store could not be read"
  ! grep -q 'check approve(cache)' "${home}/advisory.log" || no "the entry was a cache hit"
  [[ "$(identity "${entry}")" == "${before}" ]] || no "the commit that could not lock the store changed the entry"
}
row "a store that cannot be read vouches for nothing: no cache hit, and the commit it refuses leaves the entry as it was" unreadable_store_is_no_cache_hit

# The core of the command started as PID, found among its processes by what it
# runs: `safedeps-core approvals VERB`, a commit unless VERB is given.
core_below() {
  local p verb="${2:-commit}"
  for p in $(pgrep -P "$1" 2>/dev/null); do
    if [[ "$(ps -o args= -p "${p}" 2>/dev/null)" == *"safedeps-core approvals ${verb}"* ]]; then
      printf '%s\n' "${p}"
      return 0
    fi
    core_below "${p}" "${verb}" && return 0
  done
  return 1
}

# HOME's check says on stderr that its core ended before it answered, its
# staged file still there: it put no entry in place, and the core may have
# written its store line, so it never says that nothing was written.
staged_in_doubt() {
  grep -qE '^safedeps: in-doubt: the commit of sha256:[0-9a-f]{64} ended with signal-9 before it answered\. Its staged entry is still there, so it put no entry in place\.' "$1/stderr" \
    || no "$(basename "$1")'s stderr: $(cat "$1/stderr")"
  ! grep -q 'nothing was written' "$1/stderr" || no "$(basename "$1")'s stderr says nothing was written: $(cat "$1/stderr")"
}

# A check whose core is killed while it waits for the store lock. A holder
# keeps the lock, the row finds the core among the check's own processes,
# kills it, then lets the lock go. The holder runs from the scratch root and
# ends when the row ends. The CLI cannot tell how far a core got that died
# before it renamed, so the check is in doubt, though here the core wrote
# nothing.
core_killed_while_waiting() {
  local holder pid core_pid="" release
  fresh_home
  release="${home}/release"
  ( cd "${tmp_root}" && exec python3 -I -c 'import fcntl, os, sys, time
f = open(sys.argv[1], "ab")
fcntl.flock(f.fileno(), fcntl.LOCK_EX)
open(sys.argv[2], "w").close()
end = time.monotonic() + 300
while not os.path.exists(sys.argv[3]) and time.monotonic() < end:
    time.sleep(0.02)' "$(store_of "${home}")" "${home}/held" "${release}" ) &
  holder=$!
  # The row runs in a subshell of its own, and this trap ends with it: the
  # values are put in now, since these locals are gone by then.
  trap ": > '${release}'; kill ${holder} 2>/dev/null || true" EXIT
  for _ in $(seq 1 3000); do [[ -e "${home}/held" ]] && break; sleep 0.02; done
  [[ -e "${home}/held" ]] || no "the holder did not take the lock"
  ( exec env SAFEDEPS_HOME="${home}" ./bin/safedeps --json check npm fixture-clean@1.0.0 > "${home}/out" 2> "${home}/stderr" < /dev/null ) &
  pid=$!
  trap ": > '${release}'; kill ${holder} ${pid} 2>/dev/null || true" EXIT
  while kill -0 "${pid}" 2>/dev/null; do
    core_pid=$(core_below "${pid}") && break
    sleep 0.02
  done
  [[ -n "${core_pid}" ]] || no "the check ended before its core waited for the lock: $(cat "${home}/out" "${home}/stderr")"
  kill -KILL "${core_pid}"
  : > "${release}"
  wait "${holder}" || true
  rc=0
  wait "${pid}" || rc=$?
  trap - EXIT
  json=$(cat "${home}/out")
  [[ "${rc}" == 4 ]] || no "exit ${rc}: ${json}"
  jq -e '.result == "error" and .approved == false and .error == "approvals_store_in_doubt" and (has("ledger_entry_left") or has("ledger_entry_kept") | not)' <<< "${json}" >/dev/null \
    || no "the report: ${json}"
  grep -qF 'check fail-closed approvals-store-in-doubt ecosystem=' "${home}/advisory.log" || no "advisory.log has no fail-closed line"
  ! grep -q 'check approve' "${home}/advisory.log" || no "advisory.log: $(cat "${home}/advisory.log")"
  [[ -z "$(find "${home}/approved-specs" -name '.*' 2>/dev/null)" ]] || no "a file of the check was left: $(ls -a "${home}/approved-specs")"
  [[ -z "$(entries "${home}")" ]] || no "a ledger entry was written: $(entries "${home}")"
  [[ ! -s "$(store_of "${home}")" ]] || no "the store holds: $(cat "$(store_of "${home}")")"
  staged_in_doubt "${home}"
}
row "a check whose core is killed while it waits for the store lock puts nothing in place, and is in doubt" core_killed_while_waiting

# ---- commits that overlap ---------------------------------------------------
#
# Two checks of one spec, A and B, whose commits meet. A commit holds the store
# lock from before its first read to its answer, so two commits never overlap.
# It writes its store line, then its approve line, then renames its entry into
# place, and the first step that fails stops it. So a failed check never
# removes or rewrites an approval another check made, leaves no entry of its
# own, and may leave its store line. The cases: one fails and the other then
# succeeds (sequential), both succeed while their commits meet (overlap), one
# fails while the other commits (overlap with failure), the earlier one
# succeeds and the later one, which looked the spec up first, fails
# (reversed), and the same with the store refusing the later one (store
# stage).
#
# A and B share the approvals store and the ledger, as two checks in one
# SAFEDEPS_HOME do. Each has an advisory.log of its own, so a row can fail or
# stall one of them alone. A check stops at a gate, the report an approval is
# made with, which is the last step before its commit: both have looked the
# spec up and found nothing by then. A check that is to stop inside its commit
# meets an advisory.log that is a FIFO. It stops at its approve line, after its
# store line and before its rename, or, where it removes an entry the store
# does not vouch for, at the line that says so, before its store line. A check
# or a revoke that is to stop at a jq call meets one that waits after the call
# whose arguments hold PAUSE_AFTER, until PAUSE_DIR/go. The checks run from the
# scratch root, and a row's trap ends what it started.

gate_bin="${tmp_root}/gate-bin"
mkdir -p "${gate_bin}"
cat > "${gate_bin}/jq" <<STUB
#!/usr/bin/env bash
if [[ -n "\${GATE_DIR:-}" && -d "\${GATE_DIR}" && ! -e "\${GATE_DIR}/passed" && "\$*" == *'install_hint:install_hint('* ]]; then
  : > "\${GATE_DIR}/waiting"
  end=\$((SECONDS + 120))
  until [[ -e "\${GATE_DIR}/go" ]]; do
    (( SECONDS < end )) || exit 5
    sleep 0.02
  done
  : > "\${GATE_DIR}/passed"
fi
if [[ -z "\${PAUSE_DIR:-}" || -z "\${PAUSE_AFTER:-}" || ! -d "\${PAUSE_DIR}" || -e "\${PAUSE_DIR}/passed" || "\$*" != *"\${PAUSE_AFTER}"* ]]; then
  exec "${real_jq}" "\$@"
fi
"${real_jq}" "\$@"
status=\$?
: > "\${PAUSE_DIR}/waiting"
end=\$((SECONDS + 120))
until [[ -e "\${PAUSE_DIR}/go" ]]; do
  (( SECONDS < end )) || exit 5
  sleep 0.02
done
: > "\${PAUSE_DIR}/passed"
exit "\${status}"
STUB
# A check whose advisory.log a row made unwritable at the gate (and marked
# with GATE_DIR/unlogged) has it writable again at the first step after its
# commit, the removal of its evidence file: so the approve line alone fails,
# and the check's own fail-closed line is written.
cat > "${gate_bin}/rm" <<STUB
#!/usr/bin/env bash
if [[ -n "\${GATE_DIR:-}" && -e "\${GATE_DIR}/unlogged" && "\$*" == *safedeps-evidence.* ]]; then
  chmod 600 "\${SAFEDEPS_HOME}/advisory.log"
  "${real_rm}" -f "\${GATE_DIR}/unlogged"
fi
exec "${real_rm}" "\$@"
STUB
chmod +x "${gate_bin}/jq" "${gate_bin}/rm"
# HOME's approve line will fail: advisory.log unwritable until the commit is
# done.
unlogged() {
  chmod 000 "$1/advisory.log"
  : > "$1/gate/unlogged"
}
# The approve line of HOME's commit met the fault, and the check went on past
# its commit.
log_refused() {
  [[ ! -e "$1/gate/unlogged" ]] || no "$(basename "$1") never made advisory.log writable again"
  ! grep -q 'check approve(' "$1/advisory.log" || no "$(basename "$1")'s approve line was written: $(grep 'check approve(' "$1/advisory.log")"
}

# Waits up to a minute for the command to succeed.
until_true() {
  for _ in $(seq 1 3000); do
    "$@" && return 0
    sleep 0.02
  done
  return 1
}
# Leaves home_a, home_b and ledger, and a trap that ends what the row starts.
pair() {
  local root
  root=$(mktemp -d "${tmp_root}/pair.XXXXXX")
  home_a="${root}/a" home_b="${root}/b" ledger="${root}/approved-specs"
  pid_a="" pid_b="" drain_pid="" revoke_pid=""
  mkdir -p "${home_a}" "${home_b}" "${ledger}"
  : > "${home_a}/advisory.log"
  : > "${home_b}/advisory.log"
  : > "$(store_of "${home_a}")"
  ln -s "$(store_of "${home_a}")" "$(store_of "${home_b}")"
  trap reap_pair EXIT
}
descendants() {
  local p
  for p in $(pgrep -P "$1" 2>/dev/null); do
    printf '%s\n' "${p}"
    descendants "${p}"
  done
}
reap_pair() {
  local gate pid
  for gate in "${home_a}/gate" "${home_b}/gate" "${home_a}/pause" "${home_b}/pause"; do [[ ! -d "${gate}" ]] || : > "${gate}/go"; done
  for pid in ${pid_a} ${pid_b} ${drain_pid} ${revoke_pid}; do
    # shellcheck disable=SC2046  # one pid a word
    kill -KILL $(descendants "${pid}") "${pid}" 2>/dev/null || true
  done
}
# The check of HOME, in the background, with the further NAME=VALUE words in
# its environment: its pid in $!.
launch() {
  ( cd "${tmp_root}" && exec env SAFEDEPS_HOME="$1" SAFEDEPS_LEDGER_DIR="${ledger}" GATE_DIR="$1/gate" PATH="${gate_bin}:${PATH}" "${@:2}" \
      "${ROOT_DIR}/bin/safedeps" --json check pypi fixture-clean@1.0.0 > "$1/out" 2> "$1/stderr" < /dev/null ) &
}
gated() { until_true test -e "$1/gate/waiting" || no "$(basename "$1") did not reach its commit: $(cat "$1/stderr")"; }
ledger_entries() { find "${ledger}" -name '*.json' -type f 2>/dev/null; }
entry_in_place() { [[ -n "$(ledger_entries)" ]]; }
store_lines() { grep -c . "$(store_of "${home_a}")"; }
# The store holds a line, or an entry is in place.
line_or_entry() { [[ "$(store_lines)" -gt 0 ]] || entry_in_place; }
# The store holds a line, or the entry at the path is gone or is not the file
# whose identity is $1.
moved_from() { [[ "$(store_lines)" -gt 0 || -z "$(ledger_entries)" ]] || [[ "$(identity "$(ledger_entries)")" != "$1" ]]; }
# A process other than this one holds the store lock.
lock_held() {
  python3 -I -c 'import fcntl, sys
f = open(sys.argv[1], "rb")
try:
    fcntl.flock(f.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    sys.exit(0)
sys.exit(1)' "$(store_of "${home_a}")"
}
# HOME's advisory.log becomes a FIFO, its lines kept aside: the next open for
# writing waits for a reader.
stall_log() {
  cp -p "$1/advisory.log" "$1/advisory.kept"
  mkfifo -m 600 "$1/advisory.fifo"
  ln "$1/advisory.fifo" "$1/advisory.next"
  mv -f "$1/advisory.next" "$1/advisory.log"
}
# The path is a file again, with the lines kept aside. The writer waiting on
# the FIFO still waits.
unstall_log() {
  cp -p "$1/advisory.kept" "$1/advisory.next"
  mv -f "$1/advisory.next" "$1/advisory.log"
}
# And a reader takes what the waiting writer writes into advisory.drained.
drain_log() {
  unstall_log "$1"
  cat "$1/advisory.fifo" > "$1/advisory.drained" &
  drain_pid=$!
}

# The check of HOME, which ended with RC, reported an approval, and its three
# records stand: the entry the hook reads, the approve line in LOG, and a store
# line holding that line.
stands() {
  local home="$1" rc="$2" log="${3:-$1/advisory.log}" json hash line
  json=$(cat "${home}/out")
  [[ "${rc}" == 0 ]] || no "$(basename "${home}") exits ${rc}: ${json} $(cat "${home}/stderr")"
  jq -e '.approved == true and .result == "clean"' <<< "${json}" >/dev/null || no "$(basename "${home}")'s report: ${json}"
  hash=$(jq -r '.spec_hash' <<< "${json}")
  [[ -f "${ledger}/${hash/:/-}.json" ]] || no "$(basename "${home}")'s entry of ${hash} is gone: $(ls -a "${ledger}")"
  line=$(sed -n "s/^\[[^]]*\] \(check approve(.* hash=${hash}.*\)\$/\1/p" "${log}")
  [[ -n "${line}" && "$(grep -c . <<< "${line}")" == 1 ]] || no "$(basename "${home}")'s approve line: ${line}"
  [[ -n "$(jq -c --arg line "${line}" --arg hash "${hash}" 'select(.via == "check" and .hash == $hash and .record == $line)' "$(store_of "${home_a}")")" ]] \
    || no "no store line holds $(basename "${home}")'s approve line: $(cat "$(store_of "${home_a}")")"
  vouched "${home_a}" | grep -qxF "${hash}" || no "the store does not vouch for ${hash}"
}
# The check of HOME, which ended with RC, approved nothing for FAILURE, and its
# report names no entry: whatever stands at the path is not this check's.
failed_as() {
  local home="$1" rc="$2" failure="$3" json
  json=$(cat "${home}/out")
  [[ "${rc}" == 4 ]] || no "$(basename "${home}") exits ${rc}: ${json} $(cat "${home}/stderr")"
  jq -e --arg failure "${failure}" \
    '.approved == false and .error == $failure and (has("ledger_entry_kept") or has("ledger_entry_left") | not)' <<< "${json}" >/dev/null \
    || no "$(basename "${home}")'s report: ${json}"
  [[ -z "$(find "${ledger}" -name '.*' 2>/dev/null)" ]] || no "a file was left beside the entry: $(ls -a "${ledger}")"
}

sequential_failure() {
  pair
  mkdir "${home_a}/gate"
  launch "${home_a}"
  pid_a=$!
  gated "${home_a}"
  unlogged "${home_a}"
  : > "${home_a}/gate/go"
  rc_a=0
  wait "${pid_a}" || rc_a=$?
  pid_a=""
  chmod 600 "${home_a}/advisory.log"
  failed_as "${home_a}" "${rc_a}" ledger_write_failed
  log_refused "${home_a}"
  [[ -z "$(ledger_entries)" ]] || no "A left its entry: $(ledger_entries)"
  launch "${home_b}"
  pid_b=$!
  rc_b=0
  wait "${pid_b}" || rc_b=$?
  pid_b=""
  stands "${home_b}" "${rc_b}"
  # A failed at its approve line, after its store line.
  [[ "$(store_lines)" == 2 ]] || no "the store holds $(store_lines) lines, not A's and B's"
}
row "commits that meet: a check that fails, then one that succeeds, and the later one's records stand" sequential_failure

# Both are let to their gates. B goes first and stops at its approve line,
# after its store line and before its rename. A meets FAULT, then goes as far
# as it can while B is inside its commit: to its end, or into a core that
# waits. Two seconds is far past what a commit takes when nothing holds it.
# Then B goes on. b_entry is the identity of the file B staged, the one its
# rename puts in place.
overlap() {
  local seen=""
  pair
  mkdir "${home_a}/gate" "${home_b}/gate"
  launch "${home_a}"
  pid_a=$!
  launch "${home_b}"
  pid_b=$!
  gated "${home_a}"
  gated "${home_b}"
  stall_log "${home_b}"
  : > "${home_b}/gate/go"
  until_true line_or_entry || no "B did not write its store line: $(cat "${home_b}/stderr")"
  b_entry=$(identity "$(find "${ledger}" -name '.*' -type f ! -name '*.mine.*' | head -n 1)")
  "$@"
  : > "${home_a}/gate/go"
  for _ in $(seq 1 3000); do
    kill -0 "${pid_a}" 2>/dev/null || break
    if [[ -z "${seen}" ]]; then
      core_below "${pid_a}" >/dev/null && seen=${SECONDS}
    elif (( SECONDS - seen >= 2 )); then
      break
    fi
    sleep 0.02
  done
  kill -0 "${pid_a}" 2>/dev/null && [[ -z "${seen}" ]] && no "A neither ended nor reached its commit: $(cat "${home_a}/stderr")"
  drain_log "${home_b}"
  rc_b=0
  wait "${pid_b}" || rc_b=$?
  pid_b=""
  rc_a=0
  wait "${pid_a}" || rc_a=$?
  pid_a=""
  wait "${drain_pid}" || true
  drain_pid=""
}

overlap_without_failure() {
  overlap :
  stands "${home_b}" "${rc_b}" "${home_b}/advisory.drained"
  stands "${home_a}" "${rc_a}"
  [[ "$(store_lines)" == 2 ]] || no "the store holds $(store_lines) lines"
}
row "commits that meet: two checks that both succeed both stand" overlap_without_failure

a_cannot_log() { unlogged "${home_a}"; }
overlap_with_failure() {
  overlap a_cannot_log
  chmod 600 "${home_a}/advisory.log"
  stands "${home_b}" "${rc_b}" "${home_b}/advisory.drained"
  [[ "$(identity "$(ledger_entries)")" == "${b_entry}" ]] || no "the entry is not the file B put in place"
  failed_as "${home_a}" "${rc_a}" ledger_write_failed
  # A failed at its approve line, after its store line.
  [[ "$(store_lines)" == 2 ]] || no "the store holds $(store_lines) lines, not B's and A's"
  log_refused "${home_a}"
}
row "commits that meet: a check that fails while another commits leaves the other's records whole" overlap_with_failure

# B is let to its gate, having looked the spec up. A then succeeds whole. B
# meets FAULT and goes on.
reversed() {
  pair
  mkdir "${home_b}/gate"
  launch "${home_b}"
  pid_b=$!
  gated "${home_b}"
  launch "${home_a}"
  pid_a=$!
  rc_a=0
  wait "${pid_a}" || rc_a=$?
  pid_a=""
  stands "${home_a}" "${rc_a}"
  a_entry=$(identity "$(ledger_entries)")
  "$@"
  : > "${home_b}/gate/go"
  rc_b=0
  wait "${pid_b}" || rc_b=$?
  pid_b=""
  [[ "$(identity "$(ledger_entries)")" == "${a_entry}" ]] || no "the entry is not the file A put in place"
  stands "${home_a}" 0
}

b_cannot_log() { unlogged "${home_b}"; }
reversed_failure() {
  reversed b_cannot_log
  chmod 600 "${home_b}/advisory.log"
  failed_as "${home_b}" "${rc_b}" ledger_write_failed
  log_refused "${home_b}"
  # B failed at its approve line, after its store line.
  [[ "$(store_lines)" == 2 ]] || no "the store holds $(store_lines) lines, not A's and B's"
}
row "commits that meet: a check that fails after another succeeded leaves the other's records whole" reversed_failure

store_read_only() { chmod 400 "$(store_of "${home_a}")"; }
reversed_store_refuses() {
  reversed store_read_only
  chmod 600 "$(store_of "${home_a}")"
  failed_as "${home_b}" "${rc_b}" approvals_store_failed
  ! grep -q 'check approve' "${home_b}/advisory.log" || no "B's advisory.log has a line of its commit"
  [[ "$(store_lines)" == 1 ]] || no "the store holds $(store_lines) lines, not A's alone"
}
row "commits that meet: a check the store refuses after another succeeded approves nothing, and the other's records stand" reversed_store_refuses

# The store vouches for the spec and no entry stands: A approved it, and its
# entry was removed by hand. B then fails at its approve line, after its store
# line and before its rename, so no entry stands after it, though the store
# vouches.
vouched_without_entry() {
  local hash
  pair
  launch "${home_a}"
  pid_a=$!
  rc_a=0
  wait "${pid_a}" || rc_a=$?
  pid_a=""
  stands "${home_a}" "${rc_a}"
  hash=$(jq -r '.spec_hash' "${home_a}/out")
  rm -f -- "$(ledger_entries)"
  mkdir "${home_b}/gate"
  launch "${home_b}"
  pid_b=$!
  gated "${home_b}"
  unlogged "${home_b}"
  : > "${home_b}/gate/go"
  rc_b=0
  wait "${pid_b}" || rc_b=$?
  pid_b=""
  chmod 600 "${home_b}/advisory.log"
  failed_as "${home_b}" "${rc_b}" ledger_write_failed
  log_refused "${home_b}"
  [[ -z "$(ledger_entries)" ]] || no "B's entry stands where nothing stood before it: $(ledger_entries)"
  vouched "${home_a}" | grep -qxF "${hash}" || no "the store no longer vouches for ${hash}"
}
row "a check that fails where the store vouches for the spec and no entry stood leaves no entry" vouched_without_entry

# A check whose core is killed inside its commit, before its rename: it stops
# at its approve line, its store line written, holding the store lock. Its
# staged file is still there, so the CLI knows the core put no entry in place,
# and it is in doubt: the store holds its line.
killed_before_rename() {
  local core_pid
  pair
  mkdir "${home_a}/gate"
  launch "${home_a}"
  pid_a=$!
  gated "${home_a}"
  stall_log "${home_a}"
  : > "${home_a}/gate/go"
  until_true line_or_entry || no "the commit wrote nothing: $(cat "${home_a}/stderr")"
  core_pid=$(core_below "${pid_a}") || no "no core holds the commit"
  lock_held || no "the commit wrote without holding the store lock"
  unstall_log "${home_a}"
  kill -KILL "${core_pid}"
  rc_a=0
  wait "${pid_a}" || rc_a=$?
  pid_a=""
  failed_as "${home_a}" "${rc_a}" approvals_store_in_doubt
  staged_in_doubt "${home_a}"
  [[ "$(store_lines)" == 1 ]] || no "the store holds $(store_lines) lines"
  [[ -z "$(ledger_entries)" ]] || no "the killed commit put its entry in place: $(ledger_entries)"
  ! grep -q 'check approve(' "${home_a}/advisory.log" || no "advisory.log has an approve line the commit never wrote"
}
row "a check whose core is killed after its store line and before its rename puts no entry in place, and is in doubt" killed_before_rename

# An entry no check approved stands at the path: one the fixture writer put
# there, which the store does not vouch for. A check of the spec removes it
# before its store line, and its core is killed while it says so in
# advisory.log. The entry is gone, the store holds no line, and the check is
# in doubt.
killed_after_removal() {
  local planted core_pid
  pair
  SAFEDEPS_HOME="${home_a}" SAFEDEPS_LEDGER_DIR="${ledger}" lib/ledger/ledger.sh approve pypi fixture-clean 1.0.0 >/dev/null
  planted=$(identity "$(ledger_entries)")
  mkdir "${home_a}/gate"
  launch "${home_a}"
  pid_a=$!
  gated "${home_a}"
  stall_log "${home_a}"
  : > "${home_a}/gate/go"
  until_true moved_from "${planted}" || no "the commit changed nothing: $(cat "${home_a}/stderr")"
  core_pid=$(core_below "${pid_a}") || no "no core holds the commit"
  lock_held || no "the commit changed the ledger without holding the store lock"
  unstall_log "${home_a}"
  kill -KILL "${core_pid}"
  rc_a=0
  wait "${pid_a}" || rc_a=$?
  pid_a=""
  failed_as "${home_a}" "${rc_a}" approvals_store_in_doubt
  staged_in_doubt "${home_a}"
  [[ -z "$(ledger_entries)" ]] || no "an entry stands: $(ledger_entries)"
  [[ "$(store_lines)" == 0 ]] || no "the store holds $(store_lines) lines"
}
row "a check that removes an entry no check approved and is killed before its store line leaves no entry and no line, and is in doubt" killed_after_removal

# A tree whose CLI finds, in place of its core, a stand-in that runs BODY for a
# commit and the real core for everything else. BODY sees the commit's
# arguments as "$@" (the hash is $3, the staged file $4, the entry $5) and the
# real core as ${core}. Leaves the tree's CLI in stand_in_cli.
stand_in() {
  local tree machine="${BASH_VERSINFO[5]:-}" os="" arch="" native
  case "${machine}" in
    *-darwin*) os=darwin ;;
    *-linux*) os=linux ;;
  esac
  case "${machine%%-*}" in
    arm64|aarch64) arch=arm64 ;;
    x86_64|amd64) arch=x64 ;;
  esac
  [[ -n "${os}" && -n "${arch}" ]] || no "no core is built for ${machine}"
  tree=$(mktemp -d "${tmp_root}/stand-in.XXXXXX")
  native="${tree}/bin/native/${os}-${arch}"
  mkdir -p "${native}"
  cp bin/safedeps "${tree}/bin/safedeps"
  cp -R lib "${tree}/lib"
  {
    printf '#!/usr/bin/env bash\ncore=%q\n' "${core}"
    cat <<'HEAD'
if [[ "$1 $2" == "approvals commit" ]]; then
HEAD
    printf '  %s\nfi\n' "$1"
    cat <<'TAIL'
exec "${core}" "$@"
TAIL
  } > "${native}/safedeps-core"
  chmod +x "${native}/safedeps-core"
  stand_in_cli="${tree}/bin/safedeps"
}

# A check whose core dies after its commit is done and before it answers: the
# stand-in runs the real commit, then kills itself. The check's file is at the
# entry's path, so the approval stands, and the check says so.
killed_after_commit() {
  local hash
  stand_in '"${core}" "$@" > /dev/null; kill -KILL $$'
  fresh_home
  rc=0
  json=$(env SAFEDEPS_HOME="${home}" "${stand_in_cli}" --json check pypi fixture-clean@1.0.0 2>"${home}/stderr") || rc=$?
  [[ "${rc}" == 0 ]] || no "exit ${rc}: ${json} $(cat "${home}/stderr")"
  jq -e '.approved == true and .result == "clean"' <<< "${json}" >/dev/null || no "the report: ${json}"
  hash=$(jq -r '.spec_hash' <<< "${json}")
  one_check_line "${home}" clean "${hash}"
  [[ "$(entries "${home}")" == "${home}/approved-specs/${hash/:/-}.json" ]] || no "the ledger holds: $(entries "${home}")"
  [[ -z "$(find "${home}/approved-specs" -name '.*' 2>/dev/null)" ]] || no "a file was left beside the entry: $(ls -a "${home}/approved-specs")"
  grep -qxF "safedeps: the commit of ${hash} ended with signal-9 before it answered. Its entry is at the ledger entry's path, so the approval stands." "${home}/stderr" \
    || no "stderr: $(cat "${home}/stderr")"
}
row "a check whose core dies after its rename and before it answers finds its own entry in place, and the approval stands" killed_after_commit

# The same, and the stand-in puts a copy of the entry in its place before it
# dies. This check's file is in neither place, so whether its approval stands
# is not known, and the check says only that: neither that the approval
# stands nor that nothing is approved.
killed_after_commit_and_replaced() {
  local said human
  stand_in '"${core}" "$@" > /dev/null; cp -p "$5" "$5.copy" && mv -f "$5.copy" "$5"; kill -KILL $$'
  fresh_home
  rc=0
  json=$(env SAFEDEPS_HOME="${home}" "${stand_in_cli}" --json check pypi fixture-clean@1.0.0 2>"${home}/stderr") || rc=$?
  [[ "${rc}" == 4 ]] || no "exit ${rc}: ${json} $(cat "${home}/stderr")"
  jq -e '.approved == false and .error == "approvals_store_in_doubt" and (has("ledger_entry_left") or has("ledger_entry_kept") | not)' <<< "${json}" >/dev/null \
    || no "the report: ${json}"
  grep -qE '^safedeps: in-doubt: the commit of sha256:[0-9a-f]{64} ended with signal-9 before it answered\. ' "${home}/stderr" \
    || no "stderr: $(cat "${home}/stderr")"
  grep -qF "This check's file is neither at the staged path nor at the entry's path." "${home}/stderr" || no "stderr: $(cat "${home}/stderr")"
  for said in "approval stands" "not approved" "nothing was written" "nothing is approved"; do
    ! grep -qF "${said}" "${home}/stderr" || no "stderr says ${said}: $(cat "${home}/stderr")"
  done
  [[ -z "$(find "${home}/approved-specs" -name '.*' 2>/dev/null)" ]] || no "a file of the check was left: $(ls -a "${home}/approved-specs")"
  fresh_home
  rc=0
  human=$(env SAFEDEPS_HOME="${home}" "${stand_in_cli}" check pypi fixture-clean@1.0.0 2>&1) || rc=$?
  [[ "${rc}" == 4 ]] || no "the human run exits ${rc}: ${human}"
  [[ "${human}" == *"in doubt"* && "${human}" != *"not approved"* && "${human}" != *"nothing is approved"* ]] || no "the human run says: ${human}"
}
row "a check whose core dies after its rename, its entry replaced since, is in doubt and says neither that the approval stands nor that it does not" killed_after_commit_and_replaced

# An entry no check approved stands at the path, and the check's rename fails:
# the stand-in removes the staged file before the real core runs. The commit
# removed the entry before its store line, so though the store vouches for the
# spec, no entry stands, and advisory.log says both, in that order.
rename_fails_over_an_entry_no_check_approved() {
  local entry hash removed_at undone_at
  stand_in 'rm -f -- "$4"; exec "${core}" "$@"'
  fresh_home
  SAFEDEPS_HOME="${home}" lib/ledger/ledger.sh approve pypi fixture-clean 1.0.0 >/dev/null
  entry=$(entries "${home}")
  hash=$(jq -r '.hash' "${entry}")
  rc=0
  json=$(env SAFEDEPS_HOME="${home}" "${stand_in_cli}" --json check pypi fixture-clean@1.0.0 2>"${home}/stderr") || rc=$?
  [[ "${rc}" == 4 ]] || no "exit ${rc}: ${json} $(cat "${home}/stderr")"
  jq -e '.approved == false and .error == "ledger_write_failed" and (has("ledger_entry_left") or has("ledger_entry_kept") | not)' <<< "${json}" >/dev/null \
    || no "the report: ${json}"
  vouched "${home}" | grep -qxF "${hash}" || no "control: the store does not vouch for ${hash}, so the row shows nothing"
  [[ -z "$(entries "${home}")" ]] || no "an entry stands, and the store vouches for its hash: $(entries "${home}")"
  removed_at=$(log_at "${home}" "check unvouched-entry-removal hash=${hash} entry=${entry} outcome=ok")
  undone_at=$(log_at "${home}" "check approve-undone hash=${hash} outcome=os-error-2")
  [[ -n "${removed_at}" && -n "${undone_at}" && "${removed_at}" -lt "${undone_at}" ]] || no "advisory.log: $(cat "${home}/advisory.log")"
  [[ -z "$(find "${home}/approved-specs" -name '.*' 2>/dev/null)" ]] || no "a file was left beside the entry: $(ls -a "${home}/approved-specs")"
}
row "a check whose rename fails over an entry no check approved leaves no entry, though the store vouches for the spec" rename_fails_over_an_entry_no_check_approved

# The cache lookup reads the store first and the entry after. An entry no check
# approved stands at the path. A's lookup stops after it read the entry; then B
# commits the spec: it removes that entry, writes its store line and puts its
# own entry in place, a copy of the same bytes. A's lookup goes on. It read the
# store before B's line, so the entry it read is no hit, and A checks the spec
# again.
cache_reads_the_store_first() {
  local hash staged
  pair
  SAFEDEPS_HOME="${home_a}" SAFEDEPS_LEDGER_DIR="${ledger}" lib/ledger/ledger.sh approve pypi fixture-clean 1.0.0 >/dev/null
  hash=$(jq -r '.hash' "$(ledger_entries)")
  mkdir "${home_a}/pause"
  launch "${home_a}" PAUSE_DIR="${home_a}/pause" PAUSE_AFTER='--argjson now_epoch'
  pid_a=$!
  until_true test -e "${home_a}/pause/waiting" || no "A's lookup did not read the entry: $(cat "${home_a}/stderr")"
  staged=$(mktemp "${ledger}/.staged.XXXXXX")
  cp "$(ledger_entries)" "${staged}"
  printf 'check approve(clean) ecosystem=pypi package=fixture-clean version=1.0.0 hash=%s\n' "${hash}" \
    | env SAFEDEPS_HOME="${home_b}" "${core}" approvals commit "${hash}" "${staged}" "${ledger}/${hash/:/-}.json" > /dev/null \
    || no "B's commit did not approve"
  vouched "${home_a}" | grep -qxF "${hash}" || no "control: the store does not vouch for ${hash}"
  : > "${home_a}/pause/go"
  rc_a=0
  wait "${pid_a}" || rc_a=$?
  pid_a=""
  ! grep -q 'check approve(cache)' "${home_a}/advisory.log" || no "A's lookup was a hit on an entry it read before the store vouched for it"
  grep -qF "check ledger-unvouched ecosystem=pypi package=fixture-clean version=1.0.0 hash=${hash} store=not-vouched" "${home_a}/advisory.log" \
    || no "A's advisory.log does not say the entry was checked again: $(cat "${home_a}/advisory.log")"
  stands "${home_a}" "${rc_a}"
  [[ "$(store_lines)" == 2 ]] || no "the store holds $(store_lines) lines"
}
row "the cache lookup reads the store before the entry, so an entry read before a commit vouched for its hash is no hit" cache_reads_the_store_first

# ---- a revoke that meets a commit -------------------------------------------
#
# A revoke rewrites an entry, so it runs under the store lock, as a commit
# does. B looks the spec up and stops at its gate, then A approves the spec: B
# started before A's approval, so its lookup found nothing and it goes on to
# commit. B stops inside its commit at its approve line, after its store line
# and before its rename, holding the lock. A revoke of the spec starts, and
# while B holds the lock it does not end and the entry stays A's. Then B's core
# is killed: B put no entry in place and is in doubt, and the revoke takes the
# lock and revokes the entry A approved. That a commit waits for a revoke that
# holds the lock is rust-core's: no step of a revoke under the lock can be
# stopped from here.
revoke_during_commit() {
  local core_pid seen=""
  pair
  mkdir "${home_b}/gate"
  launch "${home_b}"
  pid_b=$!
  gated "${home_b}"
  launch "${home_a}"
  pid_a=$!
  rc_a=0
  wait "${pid_a}" || rc_a=$?
  pid_a=""
  stands "${home_a}" "${rc_a}"
  a_entry=$(identity "$(ledger_entries)")
  stall_log "${home_b}"
  : > "${home_b}/gate/go"
  until_true core_below "${pid_b}" >/dev/null || no "B did not reach its commit: $(cat "${home_b}/stderr")"
  until_true b_moved || no "B did not write its store line: $(cat "${home_b}/stderr")"
  core_pid=$(core_below "${pid_b}") || no "no core holds B's commit"
  ( cd "${tmp_root}" && exec env SAFEDEPS_HOME="${home_a}" SAFEDEPS_LEDGER_DIR="${ledger}" \
      "${ROOT_DIR}/bin/safedeps" --json revoke pypi fixture-clean@1.0.0 > "${home_a}/revoke.out" 2> "${home_a}/revoke.err" < /dev/null ) &
  revoke_pid=$!
  # Two seconds is far past what a revoke takes when nothing holds the lock.
  for _ in $(seq 1 3000); do
    kill -0 "${revoke_pid}" 2>/dev/null || break
    if [[ -z "${seen}" ]]; then
      core_below "${revoke_pid}" revoke >/dev/null && seen=${SECONDS}
    elif (( SECONDS - seen >= 2 )); then
      break
    fi
    sleep 0.02
  done
  kill -0 "${revoke_pid}" 2>/dev/null || no "the revoke ended while B held the store lock: $(cat "${home_a}/revoke.out" "${home_a}/revoke.err")"
  [[ -n "${seen}" ]] || no "the revoke never reached its core: $(cat "${home_a}/revoke.err")"
  entry_is_a || no "the entry changed while B held the store lock"
  unstall_log "${home_b}"
  kill -KILL "${core_pid}"
  rc_b=0
  wait "${pid_b}" || rc_b=$?
  pid_b=""
  rc=0
  wait "${revoke_pid}" || rc=$?
  revoke_pid=""
  [[ "${rc}" == 0 ]] || no "the revoke exits ${rc}: $(cat "${home_a}/revoke.out" "${home_a}/revoke.err")"
  jq -e '.command == "revoke" and .revoked == true' "${home_a}/revoke.out" >/dev/null || no "the revoke's report: $(cat "${home_a}/revoke.out")"
  [[ "$(ledger_entries | grep -c .)" == 1 ]] || no "the ledger holds: $(ls -a "${ledger}")"
  jq -e '(.revoked_at // null) != null' "$(ledger_entries)" >/dev/null || no "the entry at the end is not revoked: $(cat "$(ledger_entries)")"
  [[ -z "$(find "${ledger}" -name '.*' 2>/dev/null)" ]] || no "a file was left beside the entry: $(ls -a "${ledger}")"
  failed_as "${home_b}" "${rc_b}" approvals_store_in_doubt
  staged_in_doubt "${home_b}"
  [[ "$(store_lines)" == 2 ]] || no "the store holds $(store_lines) lines, not A's and B's"
}
# The entry at the path is the file A put in place.
entry_is_a() { [[ -n "$(ledger_entries)" && "$(identity "$(ledger_entries)")" == "${a_entry}" ]]; }
# B wrote its store line, or the entry at the path is no longer A's.
b_moved() { [[ "$(store_lines)" -ge 2 ]] || ! entry_is_a; }
row "a revoke while a commit holds the store lock waits for it, and the entry at the end is revoked" revoke_during_commit

# A revoke that meets step 0 of a commit. An entry no check approved stands at
# the path. A revoke of it reads it and stops before its core; then a check of
# the spec removes the entry, and holds the lock while it says so in
# advisory.log. The revoke goes on to its core, which waits; the check's core
# is killed. The revoke's core then finds no entry where it read one, the
# revoke reads the path again, and it says that no entry stands and revokes
# nothing.
revoke_meets_a_removal() {
  local planted hash core_pid seen=""
  pair
  SAFEDEPS_HOME="${home_a}" SAFEDEPS_LEDGER_DIR="${ledger}" lib/ledger/ledger.sh approve pypi fixture-clean 1.0.0 >/dev/null
  planted=$(identity "$(ledger_entries)")
  hash=$(jq -r '.hash' "$(ledger_entries)")
  mkdir "${home_a}/gate" "${home_b}/pause"
  launch "${home_a}"
  pid_a=$!
  gated "${home_a}"
  ( cd "${tmp_root}" && exec env SAFEDEPS_HOME="${home_b}" SAFEDEPS_LEDGER_DIR="${ledger}" PATH="${gate_bin}:${PATH}" \
      PAUSE_DIR="${home_b}/pause" PAUSE_AFTER='revoked_at: $revoked_at' \
      "${ROOT_DIR}/bin/safedeps" --json revoke pypi fixture-clean@1.0.0 > "${home_b}/revoke.out" 2> "${home_b}/revoke.err" < /dev/null ) &
  revoke_pid=$!
  until_true test -e "${home_b}/pause/waiting" || no "the revoke did not read the entry: $(cat "${home_b}/revoke.err")"
  stall_log "${home_a}"
  : > "${home_a}/gate/go"
  until_true moved_from "${planted}" || no "the check changed nothing: $(cat "${home_a}/stderr")"
  core_pid=$(core_below "${pid_a}") || no "no core holds the check's commit"
  : > "${home_b}/pause/go"
  # Two seconds is far past what a revoke takes when nothing holds the lock.
  for _ in $(seq 1 3000); do
    kill -0 "${revoke_pid}" 2>/dev/null || break
    if [[ -z "${seen}" ]]; then
      core_below "${revoke_pid}" revoke >/dev/null && seen=${SECONDS}
    elif (( SECONDS - seen >= 2 )); then
      break
    fi
    sleep 0.02
  done
  kill -0 "${revoke_pid}" 2>/dev/null || no "the revoke ended while the check held the store lock: $(cat "${home_b}/revoke.out" "${home_b}/revoke.err")"
  [[ -n "${seen}" ]] || no "the revoke never reached its core: $(cat "${home_b}/revoke.err")"
  unstall_log "${home_a}"
  kill -KILL "${core_pid}"
  rc_a=0
  wait "${pid_a}" || rc_a=$?
  pid_a=""
  rc=0
  wait "${revoke_pid}" || rc=$?
  revoke_pid=""
  [[ "${rc}" == 1 ]] || no "the revoke exits ${rc}: $(cat "${home_b}/revoke.out" "${home_b}/revoke.err")"
  grep -qxF "safedeps: no ledger entry stands at ${ledger}/${hash/:/-}.json now, so nothing was revoked." "${home_b}/revoke.err" \
    || no "the revoke's stderr: $(cat "${home_b}/revoke.err")"
  failed_as "${home_a}" "${rc_a}" approvals_store_in_doubt
  [[ -z "$(ledger_entries)" ]] || no "an entry stands: $(ledger_entries)"
  [[ "$(store_lines)" == 0 ]] || no "the store holds $(store_lines) lines"
}
row "a revoke that meets a check removing an entry no check approved revokes nothing, and says no entry stands" revoke_meets_a_removal

core_missing() {
  local tree
  tree=$(mktemp -d "${tmp_root}/no-core.XXXXXX")
  mkdir -p "${tree}/bin"
  cp bin/safedeps "${tree}/bin/safedeps"
  cp -R lib "${tree}/lib"
  fresh_home
  rc=0
  json=$(env SAFEDEPS_HOME="${home}" "${tree}/bin/safedeps" --json check npm fixture-clean@1.0.0 2>"${home}/stderr") || rc=$?
  [[ "${rc}" == 4 ]] || no "exit ${rc}: ${json}"
  jq -e '.result == "error" and .approved == false and .error == "core_missing"' <<< "${json}" >/dev/null || no "the report: ${json}"
  no_approval
  [[ ! -e "$(store_of "${home}")" ]] || no "a store was made"
  grep -qE "^safedeps: core-missing: the safedeps-core binary is missing: ${tree}/bin/native/[a-z]+-[a-z0-9]+/safedeps-core is not an executable file\. Repair: reinstall the package\." "${home}/stderr" \
    || no "stderr: $(cat "${home}/stderr")"
  grep -qF 'check fail-closed core-missing ecosystem=npm package=fixture-clean version=1.0.0' "${home}/advisory.log" || no "advisory.log has no fail-closed line"
}
row "a CLI with no core binary approves nothing and names the path it looked at" core_missing

recheck_unknown_status() {
  fresh_home
  check_in pypi fixture-clean@1.0.0
  [[ "${rc}" == 0 ]] || no "the first run exits ${rc}: ${json}"
  rc=0
  json=$(env PATH="${stub_bin}:${PATH}" STUB_MATCH="${writer_one}" STUB_STATUS=weird SAFEDEPS_HOME="${home}" ./bin/safedeps --json re-check 2>"${home}/stderr") || rc=$?
  recheck_unanswered
}
row "re-check does not count an unknown status as clean, and reports it as an error" recheck_unknown_status
recheck_provider_down() {
  fresh_home
  check_in pypi fixture-clean@1.0.0
  [[ "${rc}" == 0 ]] || no "the first run exits ${rc}: ${json}"
  rc=0
  json=$(env "${osv_down[@]}" SAFEDEPS_HOME="${home}" ./bin/safedeps --json re-check 2>"${home}/stderr") || rc=$?
  recheck_unanswered
}
row "re-check with OSV down is an error of the run, not a skip" recheck_provider_down

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

# An entry is judged whole from the one read the predicate passed. Replaced at any
# point after that, the answer is still that entry's. An empty file behind a
# passed check once came out as approved with no spec.
ledger_body() {
  case "$1" in
    other) jq -c '.package = "fixture-other"' <<< "${entry}" ;;
    scoped) jq -c '.project_context = {context_hash: "sha256:other"}' <<< "${entry}" ;;
    *) printf '%s' "$1" ;;
  esac
}
ledger_swapped() {
  local after="$1" body="$2" entry file answer
  fresh_home
  entry=$(SAFEDEPS_HOME="${home}" lib/ledger/ledger.sh approve pypi fixture-clean 1.0.0)
  file=$(find "${home}/approved-specs" -name '*.json' -type f)
  body=$(ledger_body "${body}")
  rc=0
  answer=$(env SAFEDEPS_HOME="${home}" PATH="${swap_bin}:${PATH}" SWAP_AFTER="${after}" SWAP_FILE="${file}" SWAP_BODY="${body}" \
    bash -c 'source lib/ledger/ledger.sh; safedeps_ledger_check pypi fixture-clean 1.0.0' 2>/dev/null) || rc=$?
  [[ "${rc}" == 0 ]] || no "exit ${rc}: ${answer}"
  jq -e --argjson entry "${entry}" '.approved == true and .reason == "hit" and .spec == $entry' <<< "${answer}" >/dev/null || no "the answer: ${answer}"
  swap_fired "${file}" "${body}"
}
ledger_read_swapped() {
  local body="$1" entry file answer
  fresh_home
  entry=$(SAFEDEPS_HOME="${home}" lib/ledger/ledger.sh approve pypi fixture-clean 1.0.0)
  file=$(find "${home}/approved-specs" -name '*.json' -type f)
  body=$(ledger_body "${body}")
  rc=0
  answer=$(env SAFEDEPS_HOME="${home}" PATH="${swap_bin}:${PATH}" SWAP_AFTER='(.[0] | ledger_is_valid)' SWAP_FILE="${file}" SWAP_BODY="${body}" \
    bash -c 'source lib/ledger/ledger.sh; safedeps_ledger_read pypi fixture-clean 1.0.0' 2>/dev/null) || rc=$?
  [[ "${rc}" == 0 ]] || no "exit ${rc}: ${answer}"
  jq -e --argjson entry "${entry}" '. == $entry' <<< "${answer}" >/dev/null || no "the answer: ${answer}"
  swap_fired "${file}" "${body}"
}
ledger_expired_swapped() {
  local body="$1" entry file answer
  fresh_home
  SAFEDEPS_HOME="${home}" lib/ledger/ledger.sh approve pypi fixture-clean 1.0.0 >/dev/null
  file=$(find "${home}/approved-specs" -name '*.json' -type f)
  entry=$(jq -c '.expires_at = "2020-01-01T00:00:00Z"' "${file}")
  printf '%s\n' "${entry}" > "${file}"
  rc=0
  answer=$(env SAFEDEPS_HOME="${home}" PATH="${swap_bin}:${PATH}" SWAP_AFTER='--argjson now_epoch' SWAP_FILE="${file}" SWAP_BODY="${body}" \
    bash -c 'source lib/ledger/ledger.sh; safedeps_ledger_check pypi fixture-clean 1.0.0' 2>/dev/null) || rc=$?
  [[ "${rc}" == 1 ]] || no "exit ${rc}: ${answer}"
  jq -e --argjson entry "${entry}" '.approved == false and .reason == "expired" and .spec == $entry' <<< "${answer}" >/dev/null || no "the answer: ${answer}"
  swap_fired "${file}" "${body}"
}
ledger_hit_swapped() {
  local body="$1" file
  fresh_home
  check_in pypi fixture-clean@1.0.0
  [[ "${rc}" == 0 ]] || no "the first run exits ${rc}: ${json}"
  file=$(find "${home}/approved-specs" -name '*.json' -type f)
  check_in pypi fixture-clean@1.0.0 PATH="${swap_bin}:${PATH}" SWAP_AFTER='--argjson now_epoch' SWAP_FILE="${file}" SWAP_BODY="${body}"
  [[ "${rc}" == 0 ]] || no "exit ${rc}: ${json}"
  jq -e '.result == "already_approved" and (.expires_at | test("^[0-9]{4}-"))' <<< "${json}" >/dev/null || no "the report: ${json}"
  swap_fired "${file}" "${body}"
}
for body in '' 'null' '{}' other scoped; do
  row "a ledger entry replaced by '${body}' after the predicate read it answers as that entry" ledger_swapped '(.[0] | ledger_is_valid)' "${body}"
  row "a ledger entry replaced by '${body}' after its hash read answers as that entry" ledger_swapped '-r .hash' "${body}"
  row "a ledger entry replaced by '${body}' after its expiry read answers as that entry" ledger_swapped '--argjson now_epoch' "${body}"
  row "a ledger read replaced by '${body}' after the predicate read it prints that entry" ledger_read_swapped "${body}"
done
for body in '' 'null' '{}'; do
  row "an expired ledger entry replaced by '${body}' before its answer is that entry's answer" ledger_expired_swapped "${body}"
  row "non-npm: a ledger hit replaced by '${body}' before its report is that entry's report" ledger_hit_swapped "${body}"
done

# ---- a tool that prints, then fails ---------------------------------------
#
# Each call whose arguments hold every line of STUB_MATCH, and start with
# STUB_PREFIX when that is set, runs, prints what it prints, and exits 5. With
# STUB_BEFORE set it exits 5 and prints nothing. With STUB_SKIP_FIRST naming a
# file, the first such call runs whole and leaves the file. A read a verdict
# rests on is checked by its own return, so a row below names one read, and
# turning that check off turns the row red. A row that goes through `check` ends
# where the first failed read stops it, so a read that a later one would also
# catch has a row that calls its function.
after_bin="${tmp_root}/after-bin"
mkdir -p "${after_bin}"
for tool in jq date shasum sha256sum cat cut dirname mv cp find awk; do
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
if [[ "\${hit}" -eq 1 && -n "\${STUB_SKIP_FIRST:-}" && ! -e "\${STUB_SKIP_FIRST}" ]]; then
  : > "\${STUB_SKIP_FIRST}"
  hit=0
fi
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
# yarn with no network, the shape of the one in e2e.sh: a project holds the
# candidate only once the install has written the mirror's lockfile. It stands
# apart from after_bin because the rows there read a project with no yarn.
yarn_bin="${tmp_root}/yarn-bin"
mkdir -p "${yarn_bin}"
cat > "${yarn_bin}/yarn" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"install --mode=update-lockfile"*) printf '__metadata:\n  version: 8\n# candidate\n' > yarn.lock ;;
  *"info -A -R --json"*) if grep -q '^# candidate$' yarn.lock; then cat "${STUB_YARN_GRAPH}"; fi ;;
  *) exit 64 ;;
esac
STUB
chmod +x "${yarn_bin}/yarn"
# The hash tool the libraries pick: shasum, where there is one.
hash_tool=sha256sum hash_match=''
if command -v shasum >/dev/null 2>&1; then hash_tool=shasum hash_match='-a 256'; fi

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
  fresh_home
  project_check "$@"
}
project_check() {
  local ecosystem="$1" spec="$2" match="$3"
  shift 3
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
row "npm: an OSV batch page that jq merged and failed on is not read as an answer" fails_as unavailable npm fixture-clean@1.0.0 '($r | osv_page_token) as $token'
row "the OSV batch returns when jq prints the payload and fails" function_fails jq 'queries: [' safedeps_osv_query_batch npm "${one_package}"
row "the OSV batch returns when jq merges a page and fails" function_fails jq '($r | osv_page_token) as $token' safedeps_osv_query_batch npm "${one_package}"
row "the OSV batch returns when jq reads the advisories it named and fails" function_fails jq 'unique_by(.[0])' safedeps_osv_query_batch npm "${one_package}"

# What a provider answered.
row "non-npm: an OSV query that jq printed and failed on is not sent" fails_as unavailable pypi fixture-clean@1.0.0 '{version: $version, package: {name: $package, ecosystem: $ecosystem}}'
row "npm: the count of OSV batch queries still asked is read or the batch fails" fails_as unavailable npm fixture-clean@1.0.0 '[.[] | select(.ended | not)] | length'
row "npm: the count of OSV batch results is read or the batch fails" fails_as unavailable npm fixture-clean@1.0.0 '.results | length'
row "npm: the advisories an OSV batch named are read or the batch fails" fails_as unavailable npm fixture-clean@1.0.0 'unique_by(.[0])'
row "npm: an OSV record that jq printed and failed on is no record" fails_as unavailable npm fixture-unpatched@1.0.0 'select(length == 1 and (.[0] | osv_record($id; $modified)))'
row "non-npm: the next page's query that jq printed and failed on is not sent" fails_as unavailable pypi fixture-clean@1.0.0 'if $t == null then empty else $query + {page_token: $t} end'
row "non-npm: the pages of an OSV answer that jq joined and failed on are no answer" fails_as unavailable pypi fixture-clean@1.0.0 'map(.vulns // []) | add // []'
row "npm: a curl that printed 200 and failed is not an OSV batch answer" fails_as unavailable npm fixture-clean@1.0.0 'a call no row fails' STUB_CURL_FAILS=/osv/v1/querybatch
row "non-npm: a curl that printed 200 and failed is not an OSV answer" fails_as unavailable pypi fixture-clean@1.0.0 'a call no row fails' STUB_CURL_FAILS=/osv/v1/query
row "npm: a curl that printed 200 and failed is not an OSV record" fails_as unavailable npm fixture-unpatched@1.0.0 'a call no row fails' STUB_CURL_FAILS=/osv/v1/vulns/
# The one read of a catalog is its copy, and the copy answers by its exit status.
kev_copy_failed() {
  fresh_home
  plant_kev "${kev_catalog}"
  check_in "$1" fixture-clean@1.0.0 "${kev_down[@]}" PATH="${after_path}" STUB_MATCH=known_exploited_vulnerabilities STUB_TOOL_ONLY=cp
  unavailable
}
row "npm: a catalog cp copied and failed on is no catalog" kev_copy_failed npm
row "non-npm: a catalog cp copied and failed on is no catalog" kev_copy_failed pypi
row "npm: a curl that printed 200 and failed is not a KEV catalog" fails_as unavailable npm fixture-clean@1.0.0 'a call no row fails' STUB_CURL_FAILS=/kev.json
row "non-npm: a curl that printed 200 and failed is not a KEV catalog" fails_as unavailable pypi fixture-clean@1.0.0 'a call no row fails' STUB_CURL_FAILS=/kev.json
curl_failure_recorded() {
  after_check npm fixture-clean@1.0.0 'a call no row fails' STUB_CURL_FAILS=/osv/v1/querybatch
  grep -q 'ERROR OSV batch query failed status=200 exit 18' "${home}/advisory.log" || no "advisory.log does not say both: $(cat "${home}/advisory.log")"
  after_check npm fixture-clean@1.0.0 'a call no row fails' STUB_CURL_FAILS=/kev.json
  grep -q 'WARN CISA KEV unavailable and no readable local catalog status=200 exit 18' "${home}/advisory.log" || no "advisory.log does not say both: $(cat "${home}/advisory.log")"
}
row "the record says a failed request printed 200 and how it ended" curl_failure_recorded
ghsa_curl_failed() {
  after_check pypi fixture-clean@1.0.0 'a call no row fails' STUB_CURL_FAILS=/advisories
  [[ "${rc}" == 0 ]] || no "GHSA is enrichment, and the check exits ${rc}: ${json}"
  grep -q 'GHSA cross-check skipped .*status=200 exit 18' "${home}/advisory.log" || no "advisory.log does not say both: $(cat "${home}/advisory.log")"
}
row "a curl that printed 200 and failed is a skipped GHSA cross-check, and only that" ghsa_curl_failed
cache_file="${tmp_root}/fresh-cache-file"
: > "${cache_file}"
row "a cache file's age is read from a clock that answered" function_fails date '+%s' safedeps_cache_is_fresh "${cache_file}"
row "an OSV record cache key that shasum printed and failed on is no record" function_fails "${hash_tool}" "${hash_match}" safedeps_osv_vuln_detail CVE-2026-1002 2026-01-01T00:00:00Z

# What the ledger reads and writes.
row "the ledger hash returns when shasum prints and fails" function_fails "${hash_tool}" "${hash_match}" safedeps_ledger_hash npm fixture-clean 1.0.0
row "the ledger hash with a context returns when shasum prints and fails" function_fails "${hash_tool}" "${hash_match}" safedeps_ledger_hash npm fixture-clean 1.0.0 sha256:c
row "the ledger path returns when shasum prints and fails" function_fails "${hash_tool}" "${hash_match}" safedeps_ledger_path npm fixture-clean 1.0.0
ledger_read_failed() {
  fresh_home
  SAFEDEPS_HOME="${home}" lib/ledger/ledger.sh approve npm fixture-clean 1.0.0 >/dev/null
  rc=0
  env SAFEDEPS_HOME="${home}" PATH="${after_path}" STUB_MATCH="${hash_match}" STUB_TOOL_ONLY="${hash_tool}" \
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
row "a ledger check returns when shasum prints and fails" ledger_with_entry "${hash_tool}" "${hash_match}"
row "a ledger check does not take a stored hash jq printed and failed on" ledger_with_entry jq '-r .hash'
row "a ledger check does not take a stored context jq printed and failed on" ledger_with_entry jq $'-r \nledger_context_hash'
atomic_write_run() {
  rc=0
  env SAFEDEPS_HOME="${home}" PATH="${after_path}" "$@" \
    bash -c 'source lib/ledger/ledger.sh; if safedeps_ledger_atomic_write "$1" <<< "$2"; then exit 0; fi; exit 1' write "${target}" "${entry}" >/dev/null 2>&1 || rc=$?
}
atomic_write_cat() {
  local entry target
  fresh_home
  entry=$(SAFEDEPS_HOME="${home}" lib/ledger/ledger.sh approve npm fixture-clean 1.0.0)
  target="${home}/approved-specs/written.json"
  atomic_write_run STUB_MATCH='a call no row fails'
  [[ "${rc}" == 0 && -f "${target}" ]] || no "the control exits ${rc}"
  rm -f "${target}"
  atomic_write_run STUB_TOOL_ONLY=cat
  [[ "${rc}" != 0 ]] || no "the write returned 0"
  [[ -z "$(find "${home}/approved-specs" -name '*written*' 2>/dev/null)" ]] || no "the failed write left a file: $(ls -a "${home}/approved-specs")"
}
row "a ledger write that cat failed on leaves nothing and returns" atomic_write_cat
row "an approval's date comes from a clock that answered" function_fails date '-u +%Y' safedeps_ledger_render_approved_spec npm fixture-clean 1.0.0
row "an approval's expiry comes from a clock that answered" function_fails date '+%s' safedeps_ledger_render_approved_spec npm fixture-clean 1.0.0
row "an expiry is added to a clock that answered" function_fails date '+%s' safedeps_ledger_add_days_iso 30
row "an expiry is no date a failed clock left" function_fails date '%Y-%m-%dT%H:%M:%SZ' safedeps_ledger_add_days_iso 30
project_context_file="${tmp_root}/project-context.json"
printf '{"type":"npm-overrides-probe","context_hash":"sha256:c","project_root":"/r"}\n' > "${project_context_file}"
row "an approval's context hash is read or there is no approval" function_fails jq 'context_scopes' safedeps_ledger_render_approved_spec npm fixture-clean 1.0.0 1.0.0 local '' 30 '' "${project_context_file}"
row "an approval's hash is read or there is no approval" function_fails "${hash_tool}" "${hash_match}" safedeps_ledger_render_approved_spec npm fixture-clean 1.0.0
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
row "npm patched: an approval the record could not take is taken back" record_refused npm fixture-vuln@1.0.0
row "non-npm patched: an approval the record could not take is taken back" record_refused pypi fixture-vuln@1.0.0

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
  check_in "$1" fixture-clean@1.0.0
  [[ "${rc}" == 0 ]] || no "the first run exits ${rc}: ${json}"
  check_in "$1" fixture-clean@1.0.0 PATH="${after_path}" STUB_MATCH='.approved == true'
  [[ "${rc}" == 0 ]] || no "exit ${rc}: ${json}"
  jq -e '.result == "clean"' <<< "${json}" >/dev/null || no "the ledger hit was read: ${json}"
}
row "npm: an entry whose approved field jq printed and failed on is judged again" approved_read_failed npm
row "non-npm: an entry whose approved field jq printed and failed on is judged again" approved_read_failed pypi
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
yarn_context_rc() {
  fresh_home
  rc=0
  env SAFEDEPS_HOME="${home}" PATH="${after_path}" STUB_MATCH="$1" \
    bash -c 'source lib/npm/closure.sh; rc=0; safedeps_npm_yarn_project_context "$1" "$2" || rc=$?; exit "${rc}"' context "${tmp_root}/yarn-context.json" "${project}" >/dev/null 2>&1 || rc=$?
}
# Through `check` a project with no yarn is refused whatever these reads say, so
# each asks the function, against what it answers with no fault.
yarn_declares_failed() {
  project_dir
  printf '{"name":"p"}\n' > "${project}/package.json"
  printf '__metadata:\n  version: 8\n' > "${project}/yarn.lock"
  yarn_context_rc 'a call no row fails'
  [[ "${rc}" == 1 ]] || no "the control exits ${rc}"
  yarn_context_rc '.resolutions | type'
  [[ "${rc}" == 2 ]] || no "exit ${rc}, not 2"
}
yarn_context_failed() {
  yarn_project
  yarn_context_rc 'a call no row fails'
  [[ "${rc}" == 0 ]] || no "the control exits ${rc}"
  yarn_context_rc "$1"
  [[ "${rc}" == 2 ]] || no "exit ${rc}, not 2"
}
row "a Yarn manifest that answered none and then failed is no project with no resolutions" yarn_declares_failed
row "a Yarn manifest that answered some and then failed is a failed read" yarn_context_failed '.resolutions | type'
row "a Yarn context jq printed and failed on is no context" yarn_context_failed 'resolutions_sha256: $resolutions_sha256'
row "a Yarn input list jq wrote and failed on is no context" yarn_context_failed 'input_sha256: $input_sha256, input_files: $input_files'
row "a deny-only mark that does not read is no permission" fails_as refused npm fixture-clean@1.0.0 'source_approval_scope // ""'
row "a patch candidate whose deny-only mark does not read is no patch" fails_as candidate_withheld npm fixture-vuln@1.0.0 'source_approval_scope // ""'
row "overrides jq printed and failed on are not a project with none" overrides_refused refused npm fixture-clean@1.0.0 '.overrides | type'
row "a manifest jq printed and failed on is not a project with none" overrides_refused refused npm fixture-clean@1.0.0 $'-c . /\n/package.json'
row "overrides whose filter jq printed and failed on are not a project with none" overrides_refused refused npm fixture-clean@1.0.0 'to_entries'
row "overrides whose filter jq failed on before printing are not a project with none" overrides_refused refused npm fixture-clean@1.0.0 'to_entries' STUB_BEFORE=1
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
  in_project npm fixture-clean@1.0.0 "${hash_match}" STUB_TOOL_ONLY="${hash_tool}"
  refused
}
row "an overrides hash shasum printed and failed on is not the global key" overrides_shasum
# The ledger lookup asks for overrides before the closure does, and a project's
# overrides that fail there must not read as a project with none: the entry the
# global key finds was approved for no overrides at all.
overrides_lookup_failed() {
  project_dir
  in_project npm fixture-clean@1.0.0 'a call no row fails'
  [[ "${rc}" == 0 ]] || no "the first run exits ${rc}: ${json}"
  printf '{"name":"p","version":"0.0.0","overrides":{"fixture-child":"1.0.0"}}\n' > "${project}/package.json"
  project_check npm fixture-clean@1.0.0 "$@"
  [[ "${rc}" == 4 ]] || no "exit ${rc}: ${json}"
  jq -e '.result == "error" and .approved == false' <<< "${json}" >/dev/null || no "the report: ${json}"
}
row "overrides that did not read find no entry under the global key" overrides_lookup_failed 'to_entries' STUB_BEFORE=1
row "overrides with no context find no entry under the global key" overrides_lookup_failed 'overrides_sha256: $overrides_sha256'
# The set an overrides read returns is the set the read that found it saw. A
# manifest replaced between the two read as a project with none, and the entry
# the global key finds was approved for no overrides at all.
overrides_swapped() {
  local after="$1" body="$2" answer
  overrides_project
  [[ "${after}" != manifest ]] || after="-c . ${project}/package.json"
  rc=0
  answer=$(cd "${project}" && env PATH="${swap_bin}:${PATH}" SWAP_AFTER="${after}" SWAP_FILE="${project}/package.json" SWAP_BODY="${body}" \
    bash -c 'source "$1/lib/npm/closure.sh"; safedeps_npm_repo_overrides_json' overrides "${ROOT_DIR}" 2>/dev/null) || rc=$?
  [[ "${rc}" == 0 && "${answer}" == '{"fixture-child":"1.0.0"}' ]] || no "exit ${rc}: ${answer}"
  swap_fired "${project}/package.json" "${body}"
}
overrides_lookup_swapped() {
  local after="$1" body="$2"
  project_dir
  in_project npm fixture-clean@1.0.0 'a call no row fails'
  [[ "${rc}" == 0 ]] || no "the first run exits ${rc}: ${json}"
  printf '{"name":"p","version":"0.0.0","overrides":{"fixture-child":"1.0.0"}}\n' > "${project}/package.json"
  [[ "${after}" != manifest ]] || after="-c . ${project}/package.json"
  project_check npm fixture-clean@1.0.0 'a call no row fails' PATH="${swap_bin}:${after_path}" SWAP_AFTER="${after}" SWAP_FILE="${project}/package.json" SWAP_BODY="${body}"
  jq -e '.result != "already_approved"' <<< "${json}" >/dev/null || no "the global entry answered: ${json}"
  swap_fired "${project}/package.json" "${body}"
}
for body in '' 'null' '{}'; do
  row "overrides replaced by '${body}' after the read that found them are still those overrides" overrides_swapped '.overrides | type' "${body}"
  row "overrides replaced by '${body}' after the read that found them find no entry under the global key" overrides_lookup_swapped '.overrides | type' "${body}"
  row "overrides replaced by '${body}' after the manifest read are still those overrides" overrides_swapped manifest "${body}"
  row "overrides replaced by '${body}' after the manifest read find no entry under the global key" overrides_lookup_swapped manifest "${body}"
done
overrides_context_rc() {
  local want="$1" source="$2"
  shift 2
  rc=0
  env PATH="${after_path}" STUB_MATCH='a call no row fails' "$@" \
    bash -c 'source lib/npm/closure.sh; rc=0; safedeps_npm_overrides_context "$1" "$2" "$3" || rc=$?; exit "${rc}"' context "${tmp_root}/overrides-context.json" '{"fixture-child":"1.0.0"}' "${source}" >/dev/null 2>&1 || rc=$?
  [[ "${rc}" == "${want}" ]] || no "exit ${rc}, not ${want}"
}
row "control: overrides from a manifest have a context" overrides_context_rc 0 "${ROOT_DIR}/package.json"
row "overrides with no source are no context, which is not no overrides" overrides_context_rc 2 ''
row "overrides from a directory that cannot be entered are no context" overrides_context_rc 2 /no/such/directory/package.json
row "an overrides key shasum printed and failed on is no context" overrides_context_rc 2 "${ROOT_DIR}/package.json" STUB_MATCH="${hash_match}" STUB_TOOL_ONLY="${hash_tool}" STUB_SKIP_FIRST="${tmp_root}/overrides-hash-first"
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
walk_alone() {
  project_dir
  mkdir -p "${project}/inner"
  printf '{"name":"p","overrides":{"fixture-child":"1.0.0"}}\n' > "${project}/package.json"
  export SAFEDEPS_NPM_OVERRIDES_DIR="${project}/inner"
  function_fails dirname 'inner' safedeps_npm_repo_overrides_json
}
yarn_walk_alone() {
  yarn_project
  mkdir -p "${project}/inner"
  function_fails dirname 'inner' safedeps_npm_yarn_project_context "${tmp_root}/yarn-walk-context.json" "${project}/inner"
}
row "the walk to the overrides stops where dirname failed" walk_alone
row "the walk to the Yarn project stops where dirname failed" yarn_walk_alone
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
  shift
  in_project npm fixture-clean@1.0.0 '{type: $type}' "$@"
  closure_failed
}
invalid_yarn_project() {
  project_dir
  printf '{"name":"p","version":"0.0.0","resolutions":{"fixture-child":"1.0.0"}}\n' > "${project}/package.json"
  printf '# yarn lockfile v1\n' > "${project}/yarn.lock"
}
row "a closure source jq wrote and failed on stops the probe" source_write_failed project_dir
row "an overrides source jq wrote and failed on stops the probe" source_write_failed overrides_project
row "a deny-only source jq failed on before writing stops the probe" source_write_failed invalid_yarn_project STUB_BEFORE=1
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
yarn_graph() {
  printf '%s\n' '{"value":"fixture-clean@npm:1.0.0","children":{"Version":"1.0.0","Dependencies":[]}}' > "${tmp_root}/yarn.ndjson"
}
yarn_graph_failed() {
  yarn_project
  yarn_graph
  in_project npm fixture-clean@1.0.0 yarn.ndjson STUB_TOOL_ONLY=cat SAFEDEPS_YARN_INFO_FIXTURE_NDJSON="${tmp_root}/yarn.ndjson"
  refused
}
row "a Yarn graph cat printed and failed on is no graph" yarn_graph_failed
# A locator the project does not hold yet is read from a private mirror.
yarn_candidate() {
  yarn_project
  yarn_graph
  in_project npm fixture-clean@1.0.0 "$1" STUB_TOOL_ONLY="${2:-}" PATH="${yarn_bin}:${after_path}" STUB_YARN_GRAPH="${tmp_root}/yarn.ndjson"
}
yarn_candidate_control() {
  yarn_candidate 'a call no row fails'
  [[ "${rc}" == 0 ]] || no "exit ${rc}: ${json}"
  jq -e '.result == "clean" and .closure_source.type == "yarn-project-materialized-lockfile"' <<< "${json}" >/dev/null || no "the report: ${json}"
}
yarn_candidate_failed() {
  yarn_candidate "$@"
  refused
}
row "control: a locator the Yarn project does not hold is read from its mirror" yarn_candidate_control
row "a candidate manifest mv moved and failed on is no candidate" yarn_candidate_failed .safedeps-package mv
row "a candidate closure cat printed and failed on is no closure" yarn_candidate_failed safedeps-yarn-candidate-closure cat
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
# A ledger the revoke cannot write in: nothing is staged, and the entry is as
# it was.
revoke_unwritable() {
  fresh_home
  SAFEDEPS_HOME="${home}" lib/ledger/ledger.sh approve pypi fixture-clean 1.0.0 >/dev/null
  chmod 500 "${home}/approved-specs"
  rc=0
  json=$(env SAFEDEPS_HOME="${home}" ./bin/safedeps --json revoke pypi fixture-clean@1.0.0 2>"${home}/stderr") || rc=$?
  chmod 700 "${home}/approved-specs"
  [[ "${rc}" != 0 ]] || no "the revoke exits 0: ${json}"
  [[ -z "${json}" ]] || jq -e '.revoked != true' <<< "${json}" >/dev/null || no "the report says revoked: ${json}"
  jq -e '(.revoked_at // null) == null' "${home}"/approved-specs/*.json >/dev/null || no "the entry was revoked"
  [[ -z "$(find "${home}/approved-specs" -name '.*' 2>/dev/null)" ]] || no "a file was left beside the entry: $(ls -a "${home}/approved-specs")"
}
row "a revoked entry that could not be written is not reported revoked" revoke_unwritable
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
