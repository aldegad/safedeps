#!/usr/bin/env bash
# safedeps: the daily watch (`safedeps watch`, lib/watch/) and the re-check it
# runs first.
#
# Every source the watch reads is a loopback fixture (scripts/test/lib/
# watch-fixture.mjs) whose answers a row rewrites between scans, so one row is
# a timeline: approved and clean at T0, an advisory published at T1, a lockfile
# fixed at T2. Each row has its own SAFEDEPS_HOME, projects and population
# command, and says what the published state.json holds after each step.
#
# The rows are the verification table of the plan that made the watch
# (safedeps/advisory-watch-remediation-1118): what opens and closes a finding,
# what may never read as clean, where the scan does not read, the ledger
# re-check's error rows, and the lock, the atomic publish and the event
# hand-off under overlap and interruption. A scan paused at a point
# (SAFEDEPS_WATCH_PAUSE_AT) waits at most 60 seconds and then finishes on its
# own, in a home under this battery's mktemp root: that bound is what reaps a
# paused scan when the battery itself is killed. The fixture exits when its
# parent goes.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "${ROOT_DIR}"
SD="${ROOT_DIR}/bin/safedeps"
failures=0
# SAFEDEPS_WATCH_ROWS=<regex of row functions> runs only those (development).
only="${SAFEDEPS_WATCH_ROWS:-}"

pass() { printf 'ok - %s\n' "$1"; }
bad() { printf 'not ok - %s\n' "$1" >&2; failures=$((failures + 1)); }
no() { printf '# %s\n' "$*" >&2; exit 1; }

# Physical, so the roots the scan resolves are the paths written here.
tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-watch.XXXXXX")
tmp_root=$(cd -P "${tmp_root}" && pwd)
bg_pids=()
fixture_pid=""
cleanup() {
  local rc=$? pid
  for pid in "${bg_pids[@]+${bg_pids[@]}}"; do
    kill -9 "${pid}" 2>/dev/null || true
  done
  if [[ -n "${fixture_pid}" ]]; then
    kill "${fixture_pid}" 2>/dev/null || true
    wait "${fixture_pid}" 2>/dev/null || true
  fi
  if (( rc == 0 && failures == 0 )); then
    chmod -R u+rwx "${tmp_root}" 2>/dev/null || true
    rm -rf "${tmp_root}"
  else
    printf '# failed row artifacts: %s\n' "${tmp_root}" >&2
  fi
}
trap cleanup EXIT

# ---- the fixture -------------------------------------------------------------------
fx_state="${tmp_root}/fixture-state.json"
fx_log="${tmp_root}/fixture-requests.jsonl"
BASE_STATE='{"osv":{},"kev":[],"openjdk":[],"adoptium":{},"down":[],"delay_ms":0}'
printf '%s\n' "${BASE_STATE}" > "${fx_state}"
: > "${fx_log}"
node scripts/test/lib/watch-fixture.mjs "${tmp_root}/fixture-port" "${fx_state}" "${fx_log}" &
fixture_pid=$!
for _ in $(seq 100); do [[ -s "${tmp_root}/fixture-port" ]] && break; sleep 0.1; done
[[ -s "${tmp_root}/fixture-port" ]] || { printf 'not ok - the fixture server did not start\n'; exit 1; }
base="http://127.0.0.1:$(cat "${tmp_root}/fixture-port")"

fx() { # FILTER: rewrite the fixture's answers
  jq "$1" "${fx_state}" > "${fx_state}.new" && mv -f "${fx_state}.new" "${fx_state}"
}
# An OSV record: ID, ALIAS ("" for none), PACKAGE, FIXED ("" for no fix).
osv_record() {
  jq -nc --arg id "$1" --arg alias "$2" --arg pkg "$3" --arg fixed "$4" '
    {id: $id, modified: "2026-11-01T00:00:00Z", aliases: (if $alias == "" then [] else [$alias] end),
     affected: [{package: {ecosystem: "npm", name: $pkg},
                 ranges: [{type: "SEMVER", events: ([{introduced: "0"}] + (if $fixed == "" then [] else [{fixed: $fixed}] end))}]}]}'
}

# ---- a row's world -----------------------------------------------------------------
# Each row: d (its directory), home (SAFEDEPS_HOME and HOME), a population
# command that prints d/pop.tsv (or exits 3 while d/pop.fail exists), and the
# config that names it.
new_world() {
  d=$(mktemp -d "${tmp_root}/row.XXXXXX")
  home="${d}/home"
  mkdir -p "${home}/watch" "${d}/bin" "${d}/p" "${d}/fakebin"
  : > "${d}/pop.tsv"
  printf '#!/bin/sh\n[ -e "%s/pop.fail" ] && exit 3\ncat "%s/pop.tsv"\n' "${d}" "${d}" > "${d}/bin/pop"
  chmod +x "${d}/bin/pop"
  jq -n --arg pop "${d}/bin/pop" '{population_command: [$pop], followups: {cargo_lock: "safedeps/fixture-cargo-followup"}}' \
    > "${home}/watch/config.json"
  printf '%s\n' "${BASE_STATE}" > "${fx_state}"
  row_path="${d}/fakebin:${PATH}"
}
config() { # FILTER
  jq "$1" "${home}/watch/config.json" > "${home}/watch/config.new" && mv -f "${home}/watch/config.new" "${home}/watch/config.json"
}
register() { # NAME... : projects under d/p, in the population
  local name
  for name in "$@"; do
    mkdir -p "${d}/p/${name}"
    printf '%s\t%s\n' "${name}" "${d}/p/${name}" >> "${d}/pop.tsv"
  done
}
npm_lock() { # DIR NAME@VERSION...
  local dir="$1" spec
  shift
  for spec in "$@"; do printf '%s\n' "${spec}"; done \
    | jq -R -s 'split("\n") | map(select(length > 0) | split("@")) as $s
        | {name: "fixture", lockfileVersion: 3,
           packages: ({"": {name: "fixture"}} + ($s | map({key: ("node_modules/" + .[0]), value: {version: .[1]}}) | from_entries))}' \
    > "${dir}/package-lock.json"
}

envd() {
  env -u SAFEDEPS_ADVISORY_LOG -u SAFEDEPS_CACHE_DIR -u SAFEDEPS_NPM_CLOSURE_FIXTURE_JSON -u SAFEDEPS_RECHECK_FIXTURE_JSON \
    HOME="${home}" SAFEDEPS_HOME="${home}" PATH="${row_path}" SAFEDEPS_NOTIFY=0 \
    SAFEDEPS_PROVIDER_CACHE_TTL_SECONDS=-1 \
    SAFEDEPS_OSV_API_URL="${base}/osv/v1/query" SAFEDEPS_OSV_BATCH_API_URL="${base}/osv/v1/querybatch" \
    SAFEDEPS_KEV_CATALOG_URL="${base}/kev.json" SAFEDEPS_GHSA_API_URL="${base}/advisories" \
    SAFEDEPS_OPENJDK_ADVISORIES_URL="${base}/openjdk/" SAFEDEPS_ADOPTIUM_API_URL="${base}/adoptium" "$@"
}
# sd ARGS...: one CLI run in the row's world. rc and out hold its answer.
sd() {
  rc=0
  out=$(cd "${d}" && envd "${SD}" --json "$@" 2> "${d}/stderr") || rc=$?
}
scan() { sd watch scan "$@"; }
scan_ok() { scan "$@"; [[ "${rc}" == 0 ]] || no "scan $* exited ${rc}: ${out} $(head -c 400 "${d}/stderr")"; }
state() { cat "${home}/watch/state.json"; }
# st EXPR [WHAT]: EXPR holds of the published state.
# st [--arg NAME VALUE]... EXPR [WHAT [SHOW]]: EXPR holds of the published state.
st() {
  local -a args=()
  while [[ "${1:-}" == --arg ]]; do args+=(--arg "$2" "$3"); shift 3; done
  jq -e "${args[@]+"${args[@]}"}" "$1" "${home}/watch/state.json" > /dev/null \
    || no "${2:-state}: not $1 — $(jq -c "${3:-.summary.line}" "${home}/watch/state.json")"
}
npm_findings() { jq -c '[.findings[] | select(.ecosystem == "npm")]' "${home}/watch/state.json"; }

# row NAME FUNCTION
row() {
  local rc=0
  [[ -z "${only}" || "$2" =~ ^(${only})$ ]] || return 0
  set +e
  ( set -e; "$2" )
  rc=$?
  set -e
  if (( rc == 0 )); then pass "$1"; else bad "$1"; fi
}

# The owner contract uses offline provider functions and a controlled clock.
# It does not use this battery's loopback server or operational state.
row_owner_contract() { python3 "${ROOT_DIR}/scripts/test/watch-owner.py" "${ROOT_DIR}"; }
row "owner report, deployment and measurement order contracts (offline)" row_owner_contract

# ---- T0 clean, T1 advisory, T2 fixed: through the daily wrapper ----------------------
row_timeline() {
  new_world; register a
  npm_lock "${d}/p/a" left@1.0.0 right@2.0.0
  local wrap="${ROOT_DIR}/scripts/safedeps-recheck-alert.sh" alerts="${home}/recheck-alerts.jsonl" n key
  run_wrapper() { rc=0; (cd "${d}" && envd SAFEDEPS_BIN="${SD}" "${wrap}" > /dev/null 2> "${d}/wrapper.err") || rc=$?; }
  run_wrapper
  [[ "${rc}" == 0 ]] || no "T0 wrapper exited ${rc}: $(cat "${d}/wrapper.err")"
  [[ "$(npm_findings)" == "[]" ]] || no "T0 has npm findings: $(npm_findings)"
  grep -q 'safedeps re-check status=0 runtime_version=' "${home}/recheck.log" || no "recheck.log has no runtime_version"
  st '.population.state == "fresh" and .summary.osv_measured == 1'
  n=0; [[ ! -f "${alerts}" ]] || n=$(wc -l < "${alerts}")
  # T1: one advisory under two ids that alias each other, KEV-listed.
  fx ".osv[\"left@1.0.0\"] = [$(osv_record GHSA-aaaa-bbbb-cccc CVE-2026-1111 left 1.0.3), $(osv_record CVE-2026-1111 GHSA-aaaa-bbbb-cccc left 1.0.3)] | .kev = [\"CVE-2026-1111\"]"
  run_wrapper
  [[ "${rc}" == 0 ]] || no "T1 wrapper exited ${rc}"
  [[ "$(npm_findings | jq 'length')" == 1 ]] || no "T1 npm findings: $(npm_findings)"
  npm_findings | jq -e '.[0] | .state == "open" and .fixed == ["1.0.3"] and .kev == true and .advisory == "CVE-2026-1111" and .package == "left"' > /dev/null \
    || no "T1 finding: $(npm_findings)"
  key=$(npm_findings | jq -r '.[0].key')
  st --arg k "${key}" '[.events[] | select(.finding == $k)] | length == 1' 'T1 events'
  [[ "$(wc -l < "${alerts}")" -eq $((n + 1)) ]] || no "T1 did not alert once: $(tail -n 2 "${alerts}")"
  tail -n 1 "${alerts}" | jq -e '.kind == "watch_attention" and .new_events >= 1' > /dev/null || no "T1 alert: $(tail -n 1 "${alerts}")"
  # The same answers again: nothing new, nothing said.
  run_wrapper
  [[ "${rc}" == 0 ]] || no "T1 again exited ${rc}"
  st --arg k "${key}" '([.diff.new, .diff.closed, .diff.changed] | map(length) | add) == 0 and ([.events[] | select(.finding == $k)] | length == 1)' 'T1 again'
  [[ "$(wc -l < "${alerts}")" -eq $((n + 1)) ]] || no "T1 again alerted"
  # T2: the lockfile holds the fixed version.
  npm_lock "${d}/p/a" left@1.0.3 right@2.0.0
  run_wrapper
  st --arg k "${key}" '.findings[$k].state == "closed" and .findings[$k].closed_reason == "seen_fixed"' 'T2'
  st --arg k "${key}" '[.events[] | select(.finding == $k and .to == "closed:seen_fixed")] | length == 1' 'T2 close event'
}
row "T0 clean, T1 advisory (two aliased ids, KEV) opens one finding and alerts once, again says nothing, T2 fixed closes it seen_fixed" row_timeline

# ---- no fix, withdrawn, provider down ------------------------------------------------
row_no_fix_withdrawn() {
  new_world; register a
  npm_lock "${d}/p/a" lone@1.0.0
  fx ".osv[\"lone@1.0.0\"] = [$(osv_record GHSA-nofx-nofx-nofx '' lone '')]"
  scan_ok
  npm_findings | jq -e 'length == 1 and .[0].state == "no_fix_available" and .[0].fixed == []' > /dev/null || no "no fix: $(npm_findings)"
  st '.summary.no_fix == 1 and .summary.fixable == 0'
  # OSV moves `modified` when it withdraws a record.
  fx '.osv["lone@1.0.0"][0] += {withdrawn: "2026-11-10T00:00:00Z", modified: "2026-11-10T00:00:00Z"}'
  scan_ok
  npm_findings | jq -e '.[0].state == "closed" and .[0].closed_reason == "advisory_withdrawn"' > /dev/null || no "withdrawn: $(npm_findings)"
}
row "an advisory with no fixed version is no_fix_available, and a withdrawn one closes advisory_withdrawn" row_no_fix_withdrawn

row_provider_down() {
  new_world; register a b
  npm_lock "${d}/p/a" left@1.0.0
  npm_lock "${d}/p/b" left@1.0.0
  fx '.down = ["osv"]'
  scan
  [[ "${rc}" == 1 ]] || no "a scan with OSV down exited ${rc}"
  st '[.errors[] | select(.kind == "provider_unavailable")] | length == 1'
  st '[.unmeasured[] | select(.kind == "provider_unavailable")] | length == 2'
  st '.summary.osv_measured == 0 and .last_success_at == null'
  # Up, the advisory is found; down again, the finding stays open, measured stale.
  fx ".down = [] | .osv[\"left@1.0.0\"] = [$(osv_record GHSA-down-down-down '' left 1.0.1)]"
  scan_ok
  [[ "$(npm_findings | jq '[.[] | select(.state == "open")] | length')" == 2 ]] || no "up: $(npm_findings)"
  npm_lock "${d}/p/a" left@1.0.1
  fx '.down = ["osv"]'
  scan
  [[ "${rc}" == 1 ]] || no "down again exited ${rc}"
  npm_findings | jq -e 'all(.[]; .state == "open" and .stale_measurement == true)' > /dev/null || no "down again closed or reopened: $(npm_findings)"
}
row "OSV 503 is provider_unavailable, never clean, and a finding it cannot re-measure stays open and stale" row_provider_down

# querybatch names an advisory's `modified` to the microsecond, and its record
# carries the same time with nine digits, as OSV does (the fixture cuts the
# batch's digits past the sixth). The record is the one querybatch named, by
# the microsecond rule (osv_same_time in lib/providers/providers.sh), so the
# lockfile reports its finding and is measured, not provider_unavailable.
row_record_nine_digits() {
  new_world; register a
  npm_lock "${d}/p/a" left@1.0.0
  fx ".osv[\"left@1.0.0\"] = [$(osv_record GHSA-nine-nine-nine '' left 1.0.1 | jq -c '.modified = "2026-09-10T03:50:51.191256883Z"')]"
  # The condition, measured: the batch names the advisory with six digits and
  # its record carries nine.
  local named record
  named=$(curl -fsS -H 'Content-Type: application/json' -d '{"queries":[{"version":"1.0.0","package":{"name":"left","ecosystem":"npm"}}]}' \
    "${base}/osv/v1/querybatch" | jq -r '.results[0].vulns[0].modified')
  record=$(curl -fsS "${base}/osv/v1/vulns/GHSA-nine-nine-nine" | jq -r '.modified')
  [[ "${named}" == 2026-09-10T03:50:51.191256Z && "${record}" == 2026-09-10T03:50:51.191256883Z ]] \
    || no "the fixture names ${named} and serves ${record}"
  scan_ok
  npm_findings | jq -e 'length == 1 and .[0].state == "open" and .[0].advisory == "GHSA-nine-nine-nine" and .[0].package == "left" and .[0].fixed == ["1.0.1"]' > /dev/null \
    || no "the finding: $(npm_findings)"
  st '[.. | objects | select(.kind? == "provider_unavailable" or .status? == "provider_unavailable")] | length == 0' \
    'provider_unavailable' '[.. | objects | select(.kind? == "provider_unavailable" or .status? == "provider_unavailable")]'
  st '.summary.osv_measured == 1'
}
row "a record with nine digits for the six querybatch gave is the named record: the lockfile reports its finding and is not provider_unavailable" row_record_nine_digits

# ---- native audit, resolvers not implemented ---------------------------------------
row_native_and_unmeasured() {
  new_world; register pn cg
  printf 'lockfileVersion: 9.0\n' > "${d}/p/pn/pnpm-lock.yaml"
  printf '[[package]]\nname = "x"\n' > "${d}/p/cg/Cargo.lock"
  printf 'FROM eclipse-temurin:21-jre\n' > "${d}/p/cg/Dockerfile"
  # No pnpm on the agent's path: unavailable, not clean.
  scan_ok
  st '[.unmeasured[] | select(.kind == "native_audit_unavailable" and .reason == "tool_not_found")] | length == 1'
  st '[.unmeasured[] | select(.kind == "cargo_lock" and .followup == "safedeps/fixture-cargo-followup")] | length == 1'
  st '[.unmeasured[] | select(.kind == "container_image" and .followup == null)] | length == 1'
  st '.summary.unmeasured_without_followup >= 1 and .summary.complete == false'
  # A pnpm stand-in that reports one high advisory, then none.
  mkdir -p "${d}/tools"
  printf '#!/bin/sh\n[ "$1" = audit ] || exit 2\ncat "%s/tools/report.json"\n[ -e "%s/tools/vuln" ] && exit 1\nexit 0\n' "${d}" "${d}" > "${d}/tools/pnpm"
  chmod +x "${d}/tools/pnpm"
  printf '{"metadata":{"vulnerabilities":{"info":0,"low":0,"moderate":0,"high":1,"critical":0}}}\n' > "${d}/tools/report.json"
  : > "${d}/tools/vuln"
  config ".tool_path = [\"${d}/tools\"]"
  scan_ok
  st '[.findings[] | select(.ecosystem == "pnpm" and .state == "triage_needed")] | length == 1'
  st '[.roots[].lockfiles[]? | select(.kind == "native" and .native_audit == "vulnerable")] | length == 1'
  st '.summary.triage == 1 and .summary.native_audit == 1 and .summary.osv_measured == 0'
  printf '{"metadata":{"vulnerabilities":{"info":0,"low":0,"moderate":0,"high":0,"critical":0}}}\n' > "${d}/tools/report.json"
  rm -f "${d}/tools/vuln"
  scan_ok
  st '[.roots[].lockfiles[]? | select(.kind == "native" and .native_audit == "no_finding")] | length == 1'
  st '.summary.osv_measured == 0'
}
row "pnpm without its tool is unavailable, with it vulnerable is one triage_needed and clean is no_finding (not OSV clean); Cargo and images are unmeasured with their follow-up" row_native_and_unmeasured

# ---- a root's measurement goes away: nothing closes without evidence ----------------
row_root_lifecycle() {
  new_world; register a keep
  npm_lock "${d}/p/a" left@1.0.0
  npm_lock "${d}/p/keep" right@2.0.0
  fx ".osv[\"left@1.0.0\"] = [$(osv_record GHSA-life-life-life '' left 1.0.1)]"
  scan_ok
  local key
  key=$(npm_findings | jq -r '.[0].key')
  kept() { st --arg k "${key}" '.findings[$k].state == "open" and .findings[$k].stale_measurement == true' "$1" ".findings[\"${key}\"]"; }
  mv "${d}/p/a/package-lock.json" "${d}/lock.aside"
  scan_ok
  kept "lockfile missing"
  st '[.unmeasured[] | select(.kind == "lockfile_missing")] | length == 1'
  mv "${d}/lock.aside" "${d}/p/a/package-lock.json"
  mv "${d}/p/a" "${d}/a.aside"
  scan_ok
  kept "root unreachable"
  st '[.unmeasured[] | select(.kind == "root_unreachable")] | length == 1'
  mv "${d}/a.aside" "${d}/p/a"
  grep -v "^a	" "${d}/pop.tsv" > "${d}/pop.new"; mv "${d}/pop.new" "${d}/pop.tsv"
  scan_ok
  kept "unregistered"
  st '[.unmeasured[] | select(.kind == "removed_from_population")] | length == 1'
  sd watch retire --root "${d}/p/a" --evidence "owner note: fixture root a deleted for good"
  [[ "${rc}" == 0 ]] || no "retire exited ${rc}"
  scan_ok
  st --arg k "${key}" '.findings[$k].state == "closed" and .findings[$k].closed_reason == "root_retired" and (.findings[$k].retired_evidence | test("owner note"))' "retired" ".findings[\"${key}\"]"
}
row "a missing lockfile, an unreachable root and an unregistered root keep the open finding stale; only a retire record closes it" row_root_lifecycle

row_population() {
  new_world
  touch "${d}/pop.fail"
  scan
  [[ "${rc}" == 1 ]] || no "no provider and no snapshot exited ${rc}"
  st '.population.state == "missing" and ([.unmeasured[] | select(.kind == "population_missing")] | length == 1)'
  rm -f "${d}/pop.fail"; register a
  npm_lock "${d}/p/a" right@2.0.0
  scan_ok
  st '.population.state == "fresh" and .population.count == 1'
  touch "${d}/pop.fail"
  scan
  [[ "${rc}" == 1 ]] || no "a failed provider exited ${rc}"
  st '.population.state == "stale" and .population.reason == "exit_3" and .population.count == 1 and .summary.complete == false'
  st '[.roots[] | select(.class == "ok")] | length == 1' "the snapshot's roots are measured"
  rm -f "${d}/pop.fail"; register b
  npm_lock "${d}/p/b" right@2.0.0
  scan_ok
  st '.population.state == "fresh" and .population.count == 2 and ([.roots[] | select(.name == "b")] | length == 1)'
}
row "population: no snapshot is missing, a failed provider is stale on the last snapshot, a project registered since is in the next fresh scan" row_population

# ---- where the scan does not read -------------------------------------------------------
row_remote_and_excluded() {
  new_world
  local real_mount line
  real_mount=$(PATH=/sbin:/usr/sbin:/bin:/usr/bin command -v mount)
  mkdir -p "${d}/nas/proj" "${d}/forbidden/proj" "${d}/p/local/mnt"
  npm_lock "${d}/nas/proj" left@1.0.0
  npm_lock "${d}/forbidden/proj" left@1.0.0
  npm_lock "${d}/p/local/mnt" left@1.0.0
  npm_lock "${d}/p/local" right@2.0.0
  fx ".osv[\"left@1.0.0\"] = [$(osv_record GHSA-moun-moun-moun '' left 1.0.1)]"
  if [[ "$(uname -s)" == Darwin ]]; then
    line="//fixture@nas/share on ${d}/nas (smbfs, nodev, nosuid, mounted by fixture)
//fixture@nas/two on ${d}/p/local/mnt (smbfs, nodev, nosuid, mounted by fixture)"
  else
    line="nas:/share on ${d}/nas type nfs (rw)
nas:/two on ${d}/p/local/mnt type nfs (rw)"
  fi
  printf '#!/bin/sh\n%s\ncat <<'"'"'MOUNTS'"'"'\n%s\nMOUNTS\n' "${real_mount}" "${line}" > "${d}/fakebin/mount"
  chmod +x "${d}/fakebin/mount"
  printf '#!/bin/sh\nprintf "%%s\\n" "$PWD $*" >> "%s/find.log"\nexec %s "$@"\n' "${d}" "$(PATH=/usr/bin:/bin command -v find)" > "${d}/fakebin/find"
  chmod +x "${d}/fakebin/find"
  ln -s "${d}/nas/proj" "${d}/p/link-nas"
  ln -s "${d}/forbidden/proj" "${d}/p/link-forbidden"
  printf '%s\n' "${d}/forbidden" > "${home}/watch/exclude"
  printf 'nas\t%s\nlinknas\t%s\nforbidden\t%s\nlinkforbidden\t%s\nlocal\t%s\n' \
    "${d}/nas/proj" "${d}/p/link-nas" "${d}/forbidden/proj" "${d}/p/link-forbidden" "${d}/p/local" > "${d}/pop.tsv"
  config '.followups.remote_mount = "safedeps/fixture-remote-followup"'
  # Nothing may be read there, and nothing could be: the scan answers before it.
  chmod 000 "${d}/nas" "${d}/forbidden" "${d}/p/local/mnt"
  scan_ok
  chmod 755 "${d}/nas" "${d}/forbidden" "${d}/p/local/mnt"
  st '[.roots[] | select(.class == "remote_mount")] | length == 2' "remote roots" '.roots'
  st '[.unmeasured[] | select(.kind == "remote_mount" and .followup == "safedeps/fixture-remote-followup")] | length == 3'
  st --arg r "${d}/p/local" '[.unmeasured[] | select(.kind == "remote_mount" and .root == $r and .path == "./mnt")] | length == 1' "the nested mount" '.unmeasured'
  st '[.roots[] | select(.name == "local" and .whole == false and (.skipped | map(.path) == ["./mnt"]))] | length == 1' "the local root is not whole" '.roots'
  st '.population.excluded == 2' "excluded" '.population'
  st '[.findings[] | select(.package == "left")] | length == 0' "a finding was read where nothing may be read" '.findings'
  st '[.errors[] | select(.kind == "root_walk_incomplete")] | length == 0' "the walk went into the nested mount" '.errors'
  st '[.roots[] | select(.name == "local" and .class == "ok")] | length == 1' "the local root" '.roots'
  if grep -E "^(${d}/nas|${d}/forbidden|${d}/p/local/mnt)" "${d}/find.log"; then no "find ran inside a remote or excluded tree"; fi
  grep -q "^${d}/p/local " "${d}/find.log" || no "the harness saw no find at all: $(cat "${d}/find.log")"
}
row "network mounts, symlinks to them, an excluded prefix and a nested mount are classified before any read: remote_mount or excluded, zero reads, with the follow-up" row_remote_and_excluded

# A registered root that is itself a symlink to a local tree, with a network
# mount inside that tree: ~/.kuma as a link to workspace/.kuma, its vaults/
# holding an SMB share. The mount table names the mount by its real path, so
# the walk is of the resolved tree and the prune is matched there; matched
# against the path as registered it would match nothing. No exclude glob is
# involved: the mount table decides. What the walk left out is reported: the
# share is an unmeasured remote_mount with its follow-up, the root is not
# whole, and a finding the share used to show keeps its reason.
row_symlink_root_over_mount() {
  new_world
  local real_mount line key
  real_mount=$(PATH=/sbin:/usr/sbin:/bin:/usr/bin command -v mount)
  mkdir -p "${d}/real/kuma/vaults/share" "${d}/real/kuma/vaults/local-vault"
  npm_lock "${d}/real/kuma/vaults/share" left@1.0.0
  npm_lock "${d}/real/kuma/vaults/local-vault" right@2.0.0
  fx ".osv[\"left@1.0.0\"] = [$(osv_record GHSA-shar-shar-shar '' left 1.0.1)]"
  ln -s "${d}/real/kuma" "${d}/p/dot-kuma"
  printf 'kuma\t%s\n' "${d}/p/dot-kuma" > "${d}/pop.tsv"
  config '.followups.remote_mount = "safedeps/fixture-remote-followup"'
  # T0: vaults/share is a plain local directory, and its lockfile is measured.
  scan_ok
  key=$(npm_findings | jq -r '.[] | select(.package == "left") | .key')
  [[ -n "${key}" ]] || no "T0 measured nothing in the local share: $(npm_findings)"
  st '.summary.osv_measured == 2'
  # T1: the same path is now a network mount.
  if [[ "$(uname -s)" == Darwin ]]; then
    line="//fixture@nas/vault on ${d}/real/kuma/vaults/share (smbfs, nodev, nosuid, mounted by fixture)"
  else
    line="nas:/vault on ${d}/real/kuma/vaults/share type nfs (rw)"
  fi
  printf '#!/bin/sh\n%s\ncat <<'"'"'MOUNTS'"'"'\n%s\nMOUNTS\n' "${real_mount}" "${line}" > "${d}/fakebin/mount"
  chmod +x "${d}/fakebin/mount"
  printf '#!/bin/sh\nprintf "%%s\\n" "$PWD $*" >> "%s/find.log"\nexec %s "$@"\n' "${d}" "$(PATH=/usr/bin:/bin command -v find)" > "${d}/fakebin/find"
  chmod +x "${d}/fakebin/find"
  chmod 000 "${d}/real/kuma/vaults/share"
  scan_ok
  chmod 755 "${d}/real/kuma/vaults/share"
  # Measured beside it, nothing read inside it.
  st --arg r "${d}/real/kuma" '[.roots[] | select(.name == "kuma" and .class == "ok" and .resolved == $r and .partial == false)] | length == 1' "the linked root" '.roots'
  st '.summary.osv_measured == 1' "the local vault beside the share" '.roots'
  st '[.errors[] | select(.kind == "root_walk_incomplete")] | length == 0' "the walk went into the share" '.errors'
  if grep -E "^${d}/real/kuma/vaults/share" "${d}/find.log"; then no "find ran inside the share"; fi
  grep -q -- "-path ./vaults/share" "${d}/find.log" || no "the walk did not prune the share: $(cat "${d}/find.log")"
  # What was left out is said: the share, its follow-up, a root not whole.
  st --arg r "${d}/p/dot-kuma" '[.unmeasured[] | select(.kind == "remote_mount" and .root == $r and .path == "./vaults/share" and .followup == "safedeps/fixture-remote-followup")] | length == 1' "the share is unmeasured" '.unmeasured'
  st '[.roots[] | select(.name == "kuma" and .whole == false and (.skipped | map([.path, .class]) == [["./vaults/share", "remote_mount"]]))] | length == 1' "the root says what it skipped" '.roots'
  st '.summary.complete == false'
  # The finding the share showed at T0 is not closed and says why.
  st --arg k "${key}" '.findings[$k].state == "open" and .findings[$k].stale_measurement == true and .findings[$k].unmeasured_reason == "remote_mount"' "the hidden finding" ".findings[\"${key}\"]"
  st '[.unmeasured[] | select(.kind == "lockfile_missing")] | length == 0' "the hidden lockfile read as missing" '.unmeasured'
}
row "a registered root that is a symlink to a local tree with a network mount inside it: walked resolved, the mount pruned and reported unmeasured with its follow-up, the root not whole, a finding it hid kept open with its reason" row_symlink_root_over_mount

# ---- a walk that does not finish says so, with find's words ------------------------------
# A walk find does not finish is recorded with find's exit and its words, and
# the summary and the alert count it, so "osv measured 0" never stands alone
# for roots nobody read. A directory chmod 000 here is EACCES; an operating
# system that refuses a read says EPERM. Both take the same path: the walk
# lists what it can, and find's exit and words are kept as find gave them.

# The wrapper's world: one run of scripts/safedeps-recheck-alert.sh, as launchd
# runs it. WRAPPER_BIN names the CLI it runs (the checkout's by default).
run_wrapper_of() { # WRAPPER
  rc=0
  (cd "${d}" && envd SAFEDEPS_BIN="${WRAPPER_BIN:-${SD}}" "$1" > /dev/null 2> "${d}/wrapper.err") || rc=$?
}
last_alert() { tail -n 1 "${home}/recheck-alerts.jsonl" 2>/dev/null; }
# The scan report the last wrapper run logged (one JSON line in recheck.log).
last_report() { grep '^{' "${home}/recheck.log" 2>/dev/null | tail -n 1; }

row_walk_incomplete() {
  new_world; register whole part
  npm_lock "${d}/p/whole" right@2.0.0
  npm_lock "${d}/p/part" right@2.0.0
  mkdir -p "${d}/p/part/locked"
  npm_lock "${d}/p/part/locked" left@1.0.0
  chmod 000 "${d}/p/part/locked"
  if ls "${d}/p/part/locked" > /dev/null 2>&1; then
    chmod 755 "${d}/p/part/locked"
    no "chmod 000 did not stop a read of the locked directory (is the battery running as root?)"
  fi
  run_wrapper_of "${ROOT_DIR}/scripts/safedeps-recheck-alert.sh"
  chmod 755 "${d}/p/part/locked"
  [[ "${rc}" == 1 ]] || no "the wrapper exited ${rc}, not 1 (published with errors): $(cat "${d}/wrapper.err")"
  # One error row, for the root the walk did not finish, with find's exit and words.
  st --arg r "${d}/p/part" '[.errors[] | select(.kind == "root_walk_incomplete")]
      | length == 1 and .[0].root == $r and .[0].exit == 1 and .[0].lines == 1 and (.[0].said | length) == 1
        and (.[0].said[0] | contains("./locked") and contains("Permission denied"))' "the walk's error row" '.errors'
  st --arg d "${d}" '[.errors[] | select(.kind == "root_walk_incomplete") | .said[] | select(contains($d))] | length == 0' "said names the root by its path" '.errors'
  # The root lines carry the same three facts; the whole root's walk said nothing.
  st --arg r "${d}/p/part" '.roots[$r] | .partial == true and .walk.exit == 1 and .walk.lines == 1 and (.walk.said | length) == 1' "the part root's line" '.roots'
  st --arg r "${d}/p/whole" '.roots[$r] | .partial == false and .walk == {exit: 0, said: [], lines: 0}' "the whole root's line" '.roots'
  st --arg p "${d}/p/part" '.roots[$p].walk.said == ([.errors[] | select(.kind == "root_walk_incomplete")][0].said)' "the root line and the error row" '.roots'
  # What the walk could list was measured: both top-level lockfiles. The line says the walk first.
  st '.summary.roots_walked == 1 and .summary.roots_walk_incomplete == 1 and .summary.osv_measured == 2'
  st '.summary.line | startswith("population fresh 2; roots walked 1/2 (1 incomplete); osv measured 2;")'
  # A checkout runs its own files: not stale, and the line says nothing of it.
  st '.summary.agent_runtime_stale == false and (.summary.line | contains("agent runtime") | not)'
  st '[.findings[] | select(.package == "left")] | length == 0' "a lockfile in the locked directory was read" '.findings'
  # The alert says how many of how many, find's first line, and what went unchecked.
  local said
  said=$(jq -r '[.errors[] | select(.kind == "root_walk_incomplete")][0].said[0]' "${home}/watch/state.json")
  last_alert | jq -e --arg r "${d}/p/part" --arg said "${said}" '
      .kind == "watch_attention" and .walk_incomplete == 1 and .roots == 2
      and .first_walk_incomplete.root == $r and .first_walk_incomplete.said == [$said]
      and .message == ("1 of 2 roots not read in full (" + $said + "); what find could not read in them was not checked. 0 new, population fresh, 1 errors")' > /dev/null \
    || no "the alert: $(last_alert)"
}
row "a root with a directory the walk cannot read: one root_walk_incomplete row with find's exit, first lines (the root as \".\") and line count, the same on the root's line, none for the root walked whole; the summary line counts the roots walked before osv measured, and the alert says how many of how many and what find said" row_walk_incomplete

# What find said, as find said it, through a find that stands in for the OS:
# words that name the root by its absolute path (spaces and a quote in it),
# more than three lines, and a find that exits 0 and still says something.
row_walk_said() {
  new_world
  local real_find
  real_find=$(PATH=/usr/bin:/bin command -v find)
  mkdir -p "${d}/p/it's a root" "${d}/p/quiet"
  npm_lock "${d}/p/it's a root" right@2.0.0
  npm_lock "${d}/p/quiet" right@2.0.0
  printf "it's a root\t%s\nquiet\t%s\n" "${d}/p/it's a root" "${d}/p/quiet" > "${d}/pop.tsv"
  cat > "${d}/fakebin/find" <<FIND
#!/bin/sh
case "\$PWD" in
  */"it's a root")
    "${real_find}" "\$@"
    printf 'find: %s: Operation not permitted\n' "\$PWD" >&2
    printf 'find: %s/deep dir: Operation not permitted\n' "\$PWD" >&2
    printf 'find: %s/a: Operation not permitted\n' "\$PWD" >&2
    printf 'find: %s/b: Operation not permitted\n' "\$PWD" >&2
    exit 1 ;;
  */quiet)
    "${real_find}" "\$@" || exit \$?
    printf 'find: a word on the side\n' >&2
    exit 0 ;;
  *) exec "${real_find}" "\$@" ;;
esac
FIND
  chmod +x "${d}/fakebin/find"
  run_wrapper_of "${ROOT_DIR}/scripts/safedeps-recheck-alert.sh"
  [[ "${rc}" == 1 ]] || no "the wrapper exited ${rc}, not 1: $(cat "${d}/wrapper.err")"
  st --arg r "${d}/p/it's a root" '[.errors[] | select(.kind == "root_walk_incomplete")]
      == [{kind: "root_walk_incomplete", root: $r, exit: 1, lines: 4,
           said: ["find: .: Operation not permitted", "find: ./deep dir: Operation not permitted", "find: ./a: Operation not permitted"]}]' \
    "the first three lines, the root as \".\", and the count of all four" '.errors'
  # Exit 0 is a whole walk, whatever find said; what it said is still on the root's line.
  st --arg r "${d}/p/quiet" '.roots[$r] | .partial == false and .walk == {exit: 0, said: ["find: a word on the side"], lines: 1}' "a find that exited 0 and spoke" '.roots'
  st '.summary.roots_walked == 1 and .summary.roots_walk_incomplete == 1 and .summary.osv_measured == 2'
  last_alert | jq -e '.message == "1 of 2 roots not read in full (find: .: Operation not permitted); what find could not read in them was not checked. 0 new, population fresh, 1 errors"' > /dev/null \
    || no "the alert: $(last_alert)"
}
row "find's words as it said them: a root path with spaces and a quote written as \".\", the first three of four lines with the count, and a find that exits 0 with words is a whole walk whose words stay on the root's line" row_walk_said

# A lockfile under a directory the walk could not read was not looked for, so
# a finding seen there before is not missing: it stays open and stale, and its
# reason is the walk's. A lockfile gone from a root the walk finished is still
# lockfile_missing, and only that one gets a lockfile_missing row.
row_walk_incomplete_not_missing() {
  new_world; register whole part
  mkdir -p "${d}/p/part/locked"
  npm_lock "${d}/p/whole" left@1.0.0
  npm_lock "${d}/p/part/locked" left@1.0.0
  fx ".osv[\"left@1.0.0\"] = [$(osv_record GHSA-walk-walk-walk '' left 1.0.1)]"
  scan_ok
  local part whole
  part=$(npm_findings | jq -r --arg r "${d}/p/part" '.[] | select(.root == $r) | .key')
  whole=$(npm_findings | jq -r --arg r "${d}/p/whole" '.[] | select(.root == $r) | .key')
  [[ -n "${part}" && -n "${whole}" ]] || no "a finding in each root: $(npm_findings)"
  chmod 000 "${d}/p/part/locked"
  if ls "${d}/p/part/locked" > /dev/null 2>&1; then
    chmod 755 "${d}/p/part/locked"
    no "chmod 000 did not stop a read of the locked directory (is the battery running as root?)"
  fi
  mv "${d}/p/whole/package-lock.json" "${d}/lock.aside"
  scan
  chmod 755 "${d}/p/part/locked"
  [[ "${rc}" == 1 ]] || no "the scan exited ${rc}, not 1 (published with errors): ${out}"
  st --arg r "${d}/p/part" '[.errors[] | select(.kind == "root_walk_incomplete")] | length == 1 and .[0].root == $r' "the walk's error row" '.errors'
  st --arg k "${part}" '.findings[$k] | .state == "open" and .stale_measurement == true and .unmeasured_reason == "root_walk_incomplete"' \
    "the finding the walk could not reach" ".findings[\"${part}\"]"
  st --arg k "${whole}" '.findings[$k] | .state == "open" and .stale_measurement == true and .unmeasured_reason == "lockfile_missing"' \
    "the finding whose lockfile is gone from a root walked whole" ".findings[\"${whole}\"]"
  st --arg r "${d}/p/whole" '[.unmeasured[] | select(.kind == "lockfile_missing")] | length == 1 and .[0].root == $r' "the lockfile_missing rows" '.unmeasured'
}
row "a finding under a directory the walk could not read stays open and stale with root_walk_incomplete, not lockfile_missing; a lockfile gone from a root walked whole is still lockfile_missing" row_walk_incomplete_not_missing

# The runtime digest reads the checkout the runtime was built from. When that
# checkout cannot be read, the digest is not made from what could be read: the
# runtime says it cannot tell (stale null) with the read's words, and the alert
# does not say stale. A walk that does not finish beside it keeps its own words.
row_runtime_source_unreadable() {
  new_world; register whole part
  npm_lock "${d}/p/whole" right@2.0.0
  mkdir -p "${d}/p/part/locked"
  local co="${d}/co" rt="${d}/rt" t digest
  for t in "${co}" "${rt}"; do
    mkdir -p "${t}/bin" "${t}/scripts"
    cp bin/safedeps "${t}/bin/safedeps"
    cp -R lib "${t}/lib"
    cp scripts/safedeps-recheck-alert.sh "${t}/scripts/safedeps-recheck-alert.sh"
  done
  digest=$( (source lib/watch/scan.sh; safedeps_watch_tree_digest "${co}") )
  [[ "${digest}" =~ ^[0-9a-f]{64}$ ]] || no "the checkout's digest: ${digest}"
  jq -n --arg digest "${digest}" --arg co "${co}" '{version: "fixture", digest: $digest, source_repo: $co, built_at: "2026-11-20T00:00:00Z"}' \
    > "${rt}/.safedeps-runtime.json"
  chmod 000 "${co}/lib/watch/lock.sh" "${d}/p/part/locked"
  WRAPPER_BIN="${rt}/bin/safedeps" run_wrapper_of "${rt}/scripts/safedeps-recheck-alert.sh"
  chmod 644 "${co}/lib/watch/lock.sh"
  chmod 755 "${d}/p/part/locked"
  [[ "${rc}" == 1 ]] || no "the wrapper exited ${rc}, not 1: $(cat "${d}/wrapper.err")"
  st '.last_scan.runtime | .built == true and .stale == null and .source_digest_now == null
      and (.error | startswith("source checkout unreadable: ") and contains("lib/watch/lock.sh") and (contains("locked") | not))' \
    "the runtime that could not read its checkout" '.last_scan.runtime'
  st --arg r "${d}/p/part" '[.errors[] | select(.kind == "root_walk_incomplete")] | length == 1 and .[0].root == $r
      and all(.[0].said[]; contains("lock.sh") | not)' "the walk's row beside it" '.errors'
  # Not known is null, neither stale nor fresh, and the summary line says so
  # with the read's words; the alert says unknown, not stale.
  st '.last_scan.runtime.error as $e | .summary.agent_runtime_stale == null
      and (.summary.line | endswith("; agent runtime stale unknown (" + $e + ")"))' "the summary of a runtime nobody could judge"
  last_report | jq -e 'has("agent_runtime_stale") and .agent_runtime_stale == null' > /dev/null \
    || no "the scan report: $(last_report | jq -c '{agent_runtime_stale, runtime}')"
  last_alert | jq -e 'has("agent_runtime_stale") and .agent_runtime_stale == null
      and (.message | startswith("1 of 2 roots not read in full (") and contains("locked"))
      and (.message | endswith(", 1 errors, agent runtime stale unknown"))' > /dev/null \
    || no "the alert: $(last_alert)"
  # The same runtime with its checkout readable again is judged: fresh, false,
  # and the line says nothing of it.
  WRAPPER_BIN="${rt}/bin/safedeps" run_wrapper_of "${rt}/scripts/safedeps-recheck-alert.sh"
  [[ "${rc}" == 0 ]] || no "the wrapper with the checkout readable exited ${rc}: $(cat "${d}/wrapper.err")"
  st '.last_scan.runtime.stale == false and .summary.agent_runtime_stale == false and (.summary.line | contains("agent runtime") | not)' \
    "the runtime read again" '.last_scan.runtime'
  last_report | jq -e '.agent_runtime_stale == false' > /dev/null || no "the scan report read again: $(last_report | jq -c '{agent_runtime_stale, runtime}')"
}
row "a runtime whose source checkout cannot be read says stale null with the read's words, not a digest of what it could read; the report's agent_runtime_stale is null, the summary line and the alert say unknown, not stale, and the walk that did not finish beside it keeps its own words; read again, the same runtime is false and the line is silent" row_runtime_source_unreadable

# ---- Java ------------------------------------------------------------------------------
row_jdk() {
  new_world; register older same pre down
  printf 'java=21.0.10-tem\n' > "${d}/p/older/.sdkmanrc"
  printf 'java=21.0.14-tem\n' > "${d}/p/same/.sdkmanrc"
  printf 'temurin-17.0.18\n' > "${d}/p/pre/.java-version"
  printf 'java temurin-25.0.2\n' > "${d}/p/down/.tool-versions"
  # A host JDK in the row's own SDKMAN, and one from a vendor with no feed.
  mkdir -p "${home}/.sdkman/candidates/java/21.0.10-tem" "${home}/.sdkman/candidates/java/21.0.9-oracle"
  printf 'IMPLEMENTOR="Eclipse Adoptium"\nJAVA_RUNTIME_VERSION="21.0.10+7-LTS"\n' > "${home}/.sdkman/candidates/java/21.0.10-tem/release"
  printf 'IMPLEMENTOR="Oracle Corporation"\nJAVA_RUNTIME_VERSION="21.0.9+8-LTS"\n' > "${home}/.sdkman/candidates/java/21.0.9-oracle/release"
  release() { jq -nc --arg n "$1" --argjson maj "$2" --argjson sec "$3" '{release_name: $n, timestamp: "2026-10-22T00:00:00Z", release_link: "https://example.invalid/r", version_data: {major: $maj, minor: 0, security: $sec, build: 7, openjdk_version: "\($maj).0.\($sec)+7-LTS"}}'; }
  fx ".adoptium = {\"21\": $(release jdk-21.0.14+7 21 14), \"17\": $(release jdk-17.0.18+7 17 18)}
      | .openjdk = [{date: \"2026-10-20\", affected: \"25.0.1, 21.0.13, 17.0.18, 8u504\"}]"
  scan_ok
  local s
  s() { jq -r --arg l "$1" '[.runtime.jdks[] | select(.location == $l or .scope == $l)][0].state // "none"' "${home}/watch/state.json"; }
  [[ "$(s ./.sdkmanrc)" != none ]] || no "no pin judged: $(jq -c '.runtime' "${home}/watch/state.json")"
  st --arg r "${d}/p/older" '[.findings[] | select(.root == $r and .ecosystem == "runtime" and .state == "update_available" and .fixed == ["21.0.14+7-LTS"])] | length == 1' "older pin" '.runtime'
  st --arg r "${d}/p/same" '[.runtime.jdks[] | select(.root == $r and (.state == "current_as_of" or .state == "pre_announced"))] | length == 1' "same pin" '.runtime'
  # The next scheduled OpenJDK update (third Tuesday of Jan, Apr, Jul, Oct)
  # decides between the two: within 14 days it is pre_announced.
  local within
  within=$(node -e '
    const now = new Date(); let best = null;
    for (let y = now.getUTCFullYear(); y <= now.getUTCFullYear() + 1; y++) for (const m of [0, 3, 6, 9]) {
      const first = new Date(Date.UTC(y, m, 1)); const day = 1 + ((2 - first.getUTCDay() + 7) % 7) + 14;
      const t = new Date(Date.UTC(y, m, day)); if (t > now && (best === null || t < best)) best = t; }
    console.log((best - now) / 86400000 <= 14 ? "yes" : "no");')
  if [[ "${within}" == no ]]; then
    st --arg r "${d}/p/same" '[.runtime.jdks[] | select(.root == $r and .state == "current_as_of")] | length == 1' "same pin, no update due" '.runtime'
  fi
  st --arg r "${d}/p/pre" '[.findings[] | select(.root == $r and .state == "pre_announced")] | length == 1' "affected latest build" '.runtime'
  st --arg r "${d}/p/down" '[.runtime.jdks[] | select(.root == $r and .state == "feed_unavailable")] | length == 1' "no feed for 25" '.runtime'
  st --arg r "${d}/p/down" '[.unmeasured[] | select(.kind == "runtime_feed_unavailable" and .root == $r)] | length == 1'
  st '[.findings[] | select(.root == "@host" and (.location | test("21.0.10-tem")) and .state == "update_available")] | length == 1' "host JDK" '.runtime'
  st '[.unmeasured[] | select(.kind == "jdk_vendor_feed_missing")] | length >= 1' "oracle" '.unmeasured'
  st '[.runtime.jdks[] | select(.state == "clean")] | length == 0'
  fx '.down = ["adoptium", "openjdk"]'
  scan_ok
  st --arg r "${d}/p/older" '[.runtime.jdks[] | select(.root == $r and .state == "feed_unavailable")] | length == 1' "feeds down" '.runtime'
  st --arg r "${d}/p/older" '[.findings[] | select(.root == $r and .ecosystem == "runtime" and .state == "update_available")] | length == 1' "feeds down keeps the finding" '.findings'
}
row "JDK: older than the vendor's latest is update_available, the same is current_as_of, an affected latest is pre_announced, no feed is feed_unavailable; nothing is clean" row_jdk

# ---- the ledger re-check ----------------------------------------------------------------
row_ledger_errors() {
  new_world
  sd check PyPI lumi-ledger-read-probe@1.0.0
  [[ "${rc}" == 0 ]] || no "setup check exited ${rc}: ${out}"
  sd re-check
  [[ "${rc}" == 0 ]] || no "control re-check exited ${rc}"
  jq -e '.checked == 1 and .still_clean == 1 and .errors == []' <<< "${out}" > /dev/null || no "control: ${out}"
  # validator-lumi/probe.py's counterexample: one file that is not JSON.
  printf '{"ecosystem":"PyPI",\n' > "${home}/approved-specs/malformed.json"
  sd re-check
  [[ "${rc}" == 1 ]] || no "a malformed entry exited ${rc}"
  jq -e '.checked == 1 and .still_clean == 1 and (.errors | length == 1) and .errors[0].kind == "ledger_entry_unreadable" and .errors[0].file == "malformed.json"' <<< "${out}" > /dev/null \
    || no "malformed: ${out}"
  rm -f "${home}/approved-specs/malformed.json"
  # A revoke that cannot write: the report stays, one errors row, the others judged.
  sd check PyPI lumi-second@1.0.0
  fx ".osv[\"lumi-ledger-read-probe@1.0.0\"] = [{id: \"PYSEC-2026-1\", modified: \"2026-11-01T00:00:00Z\", affected: [{package: {ecosystem: \"PyPI\", name: \"lumi-ledger-read-probe\"}, ranges: [{type: \"ECOSYSTEM\", events: [{introduced: \"0\"}, {fixed: \"1.0.1\"}]}]}]}]"
  chmod 500 "${home}/approved-specs"; chmod 400 "${home}"/approved-specs/*.json
  sd re-check
  chmod 700 "${home}/approved-specs"; chmod 600 "${home}"/approved-specs/*.json
  [[ "${rc}" == 1 ]] || no "a failed revoke exited ${rc}: ${out}"
  jq -e '.checked == 2 and .still_clean == 1 and (.errors | length == 1) and .errors[0].kind == "revoke_failed" and .revoked == []' <<< "${out}" > /dev/null \
    || no "revoke failure: ${out}"
  # The scan carries the ledger's errors and publishes anyway.
  chmod 500 "${home}/approved-specs"; chmod 400 "${home}"/approved-specs/*.json
  scan
  chmod 700 "${home}/approved-specs"; chmod 600 "${home}"/approved-specs/*.json
  [[ "${rc}" == 1 ]] || no "a scan with a failed revoke exited ${rc}"
  st '([.errors[] | select(.kind == "ledger_revoke_failed")] | length == 1) and .ledger.checked == 2' "ledger errors in the scan" '.errors'
}
row "re-check: a malformed entry and a revoke that cannot write are errors rows, the report is printed and the run exits 1" row_ledger_errors

row_ledger_mixed() {
  new_world
  local ctx="${d}/context.json"
  jq -n --arg root "${d}/p/x" '{type: "npm-overrides-probe", context_hash: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
    project_root: $root, overrides_source: "package.json", overrides_sha256: "sha256:2222222222222222222222222222222222222222222222222222222222222222",
    overrides: {"mixed": "1.0.0"}}' > "${ctx}"
  envd lib/ledger/ledger.sh approve npm mixed 1.0.0 > /dev/null
  envd lib/ledger/ledger.sh approve npm mixed 1.0.0 1.0.0 local "" "" "" "${ctx}" > /dev/null
  envd lib/ledger/ledger.sh approve npm other 2.0.0 > /dev/null
  [[ "$(find "${home}/approved-specs" -name '*.json' | wc -l | tr -d ' ')" == 3 ]] || no "the ledger does not hold three entries"
  : > "${fx_log}"
  sd re-check
  [[ "${rc}" == 0 ]] || no "a mixed ledger exited ${rc}: ${out}"
  jq -e '.checked == 3 and .still_clean == 3' <<< "${out}" > /dev/null || no "mixed: ${out}"
  [[ "$(grep -c '"path":"/osv/v1/query"' "${fx_log}")" == 2 ]] || no "each spec is not asked once: $(grep -c '/osv/v1/query' "${fx_log}") OSV queries"
  fx ".osv[\"mixed@1.0.0\"] = [$(osv_record GHSA-mixd-mixd-mixd '' mixed 1.0.1)]"
  sd re-check
  jq -e '.checked == 3 and .still_clean == 1 and (.revoked | length == 2) and .errors == []' <<< "${out}" > /dev/null || no "both contexts of the spec are not revoked: ${out}"
}
row "a ledger of entries with and without a project context: every entry judged, each spec asked once, both contexts revoked" row_ledger_mixed

# ---- the lock, the publish, the hand-off ------------------------------------------------
wait_for() { # FILE
  local i
  for i in $(seq 300); do [[ -e "$1" ]] && return 0; sleep 0.1; done
  no "timed out waiting for $1"
}
bg_scan() { # NAME POINT [ARGS]: a scan paused at POINT, in the background
  local name="$1" point="$2"
  shift 2
  (cd "${d}" && exec env SAFEDEPS_WATCH_PAUSE_AT="${point}" SAFEDEPS_WATCH_PAUSE_FILE="${d}/${name}.pause" \
    HOME="${home}" SAFEDEPS_HOME="${home}" PATH="${row_path}" SAFEDEPS_NOTIFY=0 SAFEDEPS_PROVIDER_CACHE_TTL_SECONDS=-1 \
    SAFEDEPS_OSV_API_URL="${base}/osv/v1/query" SAFEDEPS_OSV_BATCH_API_URL="${base}/osv/v1/querybatch" \
    SAFEDEPS_KEV_CATALOG_URL="${base}/kev.json" SAFEDEPS_GHSA_API_URL="${base}/advisories" \
    SAFEDEPS_OPENJDK_ADVISORIES_URL="${base}/openjdk/" SAFEDEPS_ADOPTIUM_API_URL="${base}/adoptium" \
    "${SD}" --json watch scan "$@" > "${d}/${name}.out" 2> "${d}/${name}.err") &
  bg_pid=$!
  bg_pids+=("${bg_pid}")
}
gen() { jq '.generation' "${home}/watch/state.json"; }

row_overlap() {
  new_world; register a
  npm_lock "${d}/p/a" left@1.0.0
  fx ".osv[\"left@1.0.0\"] = [$(osv_record GHSA-over-over-over '' left 1.0.1)] | .delay_ms = 200"
  : > "${fx_log}"
  bg_scan first after_lock
  local first=${bg_pid}
  wait_for "${d}/first.pause"
  scan
  [[ "${rc}" == 75 ]] || no "a second full scan exited ${rc}"
  jq -e '.busy == true' <<< "${out}" > /dev/null || no "the refusal: ${out}"
  scan --root "${d}/p/a"
  [[ "${rc}" == 75 ]] || no "a root scan exited ${rc}"
  sd re-check
  [[ "${rc}" == 75 ]] || no "a re-check exited ${rc}"
  # 09:30: the consumer finds the scan running. It reads the last complete
  # generation (none yet) and claims nothing.
  sd watch claim --consumer routine
  [[ "${rc}" == 75 ]] || no "a claim during a scan exited ${rc}"
  sd watch status
  [[ "${rc}" == 0 ]] || no "status during a scan exited ${rc}"
  jq -e '.generation == 0 and .last_scan == null' <<< "${out}" > /dev/null || no "status during a scan: ${out}"
  rm -f "${d}/first.pause"
  wait "${first}" || no "the first scan exited $?: $(cat "${d}/first.err" | head -c 300)"
  [[ "$(gen)" == 1 ]] || no "generation $(gen) after one published scan"
  st '[.events[] | select(.kind == "finding" and (.finding | test("\\|npm\\|")))] | length == 1'
  [[ "$(jq -s 'map(.in_flight) | max' "${fx_log}")" -le 1 ]] || no "provider requests overlapped: $(jq -s 'map(.in_flight) | max' "${fx_log}")"
  # The follow-up consumption, once the scan is done.
  sd watch claim --consumer routine
  [[ "${rc}" == 0 ]] || no "the follow-up claim exited ${rc}"
  jq -e '[.claimed[] | select(.finding | test("\\|npm\\|"))] | length == 1' <<< "${out}" > /dev/null || no "follow-up claim: ${out}"
  # Serial control: the same three scans one after another.
  local overlapped_events
  overlapped_events=$(jq '[.events[] | select(.finding | test("\\|npm\\|"))] | length' "${home}/watch/state.json")
  new_world; register a
  npm_lock "${d}/p/a" left@1.0.0
  fx ".osv[\"left@1.0.0\"] = [$(osv_record GHSA-over-over-over '' left 1.0.1)]"
  scan_ok; scan_ok; scan_ok --root "${d}/p/a"
  [[ "$(gen)" == 3 ]] || no "serial generations: $(gen)"
  [[ "$(jq '[.events[] | select(.finding | test("\\|npm\\|"))] | length' "${home}/watch/state.json")" == "${overlapped_events}" ]] || no "serial and overlapped runs raised different events"
}
row "overlapping scans, re-check and claim in one home: the others exit 75, providers see one run, one generation and one event; the consumer reads the complete generation and claims after" row_overlap

row_homes() {
  new_world; register a
  npm_lock "${d}/p/a" right@2.0.0
  local d1="${d}" h1="${home}" p1
  bg_scan one after_lock; p1=${bg_pid}
  wait_for "${d1}/one.pause"
  new_world; register b
  npm_lock "${d}/p/b" right@2.0.0
  local p2
  bg_scan two after_lock; p2=${bg_pid}
  wait_for "${d}/two.pause"
  rm -f "${d1}/one.pause" "${d}/two.pause"
  wait "${p1}" || no "the first home's scan exited $?"
  wait "${p2}" || no "the second home's scan exited $?"
  [[ "$(jq '.generation' "${h1}/watch/state.json")" == 1 && "$(gen)" == 1 ]] || no "a home's generation is not 1"
  [[ "$(jq -r '[.roots[]][0].name' "${h1}/watch/state.json")" == a ]] || no "the first home holds another's roots"
  [[ "$(jq -r '[.roots[]][0].name' "${home}/watch/state.json")" == b ]] || no "the second home holds another's roots"
}
row "scans in two homes at once each hold their own lock and publish their own state" row_homes

row_interrupt() {
  new_world; register a
  npm_lock "${d}/p/a" right@2.0.0
  scan_ok
  local before pid
  before=$(state)
  # Killed after the new generation is written and checked, before the rename.
  bg_scan cut before_publish; pid=${bg_pid}
  wait_for "${d}/cut.pause"
  [[ -n "$(find "${home}/watch" -maxdepth 1 -name '.state.json.*')" ]] || no "no generation was written beside the state"
  # A live run's lock is not taken, and its file is not swept.
  scan
  [[ "${rc}" == 75 ]] || no "a scan beside a live one exited ${rc}"
  [[ -n "$(find "${home}/watch" -maxdepth 1 -name '.state.json.*')" ]] || no "the live run's generation was swept"
  kill -9 "${pid}"
  wait "${pid}" 2>/dev/null || true
  [[ "$(state)" == "${before}" ]] || no "a run killed before its rename changed the state"
  jq -e '.generation == 1' "${home}/watch/state.json" > /dev/null || no "the state is not the last complete generation"
  for _ in $(seq 40); do scan; [[ "${rc}" != 75 ]] && break; sleep 0.25; done
  [[ "${rc}" == 0 ]] || no "the next scan exited ${rc}"
  [[ "$(gen)" == 2 ]] || no "the next scan published generation $(gen)"
  [[ -z "$(find "${home}/watch" -maxdepth 1 -name '.state.json.*')" ]] || no "the killed run's file is still there"
  # Killed after the rename: the new generation is whole.
  bg_scan after after_publish; pid=${bg_pid}
  wait_for "${d}/after.pause"
  kill -9 "${pid}"
  wait "${pid}" 2>/dev/null || true
  jq -e '.generation == 3 and (.findings | type == "object")' "${home}/watch/state.json" > /dev/null || no "after the rename: generation $(gen)"
  for _ in $(seq 40); do scan; [[ "${rc}" != 75 ]] && break; sleep 0.25; done
  [[ "${rc}" == 0 && "$(gen)" == 4 ]] || no "the scan after a kill past the rename exited ${rc} at generation $(gen)"
}
row "a scan killed before or after its rename leaves a whole generation, a live scan's lock and file are left alone, and the next scan publishes" row_interrupt

row_delayed_old_scan() {
  new_world; register a b
  npm_lock "${d}/p/a" left@1.0.0
  npm_lock "${d}/p/b" right@2.0.0
  fx ".osv[\"left@1.0.0\"] = [$(osv_record GHSA-dela-dela-dela '' left 1.0.1)] | .osv[\"right@2.0.0\"] = [$(osv_record GHSA-righ-righ-righ '' right 2.0.1)]"
  scan_ok
  local key_a key_b old
  key_a=$(npm_findings | jq -r '.[] | select(.package == "left") | .key')
  key_b=$(npm_findings | jq -r '.[] | select(.package == "right") | .key')
  # An old full scan starts and is held before it takes the lock.
  bg_scan old before_lock; old=${bg_pid}
  wait_for "${d}/old.pause"
  # Meanwhile a root scan of a, now fixed, closes a's finding.
  npm_lock "${d}/p/a" left@1.0.1
  scan_ok --root "${d}/p/a"
  st --arg k "${key_a}" '.findings[$k].state == "closed"'
  rm -f "${d}/old.pause"
  wait "${old}" || no "the old scan exited $?"
  [[ "$(gen)" == 3 ]] || no "the old scan did not publish on top of the root scan: generation $(gen)"
  st --arg k "${key_a}" '.findings[$k].state == "closed" and ([.events[] | select(.finding == $k and .to == "closed:seen_fixed")] | length == 1)' "a"
  st --arg k "${key_b}" '.findings[$k].state == "open" and ([.events[] | select(.finding == $k and .status == "pending")] | length == 1)' "b"
}
row "an old scan held before the lock merges onto the root scan that published meanwhile: the closed finding, the other root and the undelivered events stay" row_delayed_old_scan

row_consumers() {
  new_world; register a
  npm_lock "${d}/p/a" left@1.0.0 right@2.0.0
  fx ".osv[\"left@1.0.0\"] = [$(osv_record GHSA-cons-cons-cons '' left 1.0.1)] | .osv[\"right@2.0.0\"] = [$(osv_record GHSA-cont-cont-cont '' right 2.0.1)]"
  scan_ok
  local e1 e2
  sd watch claim --consumer c1 --limit 1
  e1=$(jq -r '.claimed[0].id' <<< "${out}")
  sd watch claim --consumer c2 --limit 5
  e2=$(jq -r '.claimed[0].id' <<< "${out}")
  [[ "$(jq '.claimed | length' <<< "${out}")" == 1 && "${e1}" != "${e2}" && "${e1}" != null ]] || no "two consumers claimed: ${e1} ${e2}"
  # c1 stops after its claim. Its event stays its own: no one else claims it.
  sd watch claim --consumer c2
  [[ "$(jq '.claimed | length' <<< "${out}")" == 0 ]] || no "a claimed event was claimed again: ${out}"
  sd watch claimed --consumer c1
  [[ "$(jq -r '.claimed[0].id' <<< "${out}")" == "${e1}" ]] || no "c1's claim is gone: ${out}"
  sd watch ack --event "${e1}" --consumer c2 --task other
  [[ "${rc}" != 0 ]] || no "another consumer acked c1's event"
  # c1 cannot tell whether it dispatched: unknown, kept, never retried.
  sd watch ack --event "${e1}" --consumer c1 --unknown
  [[ "${rc}" == 0 ]] || no "ack unknown exited ${rc}"
  sd watch ack --event "${e2}" --consumer c2 --task kongkongi-fixture-1
  [[ "${rc}" == 0 ]] || no "ack task exited ${rc}"
  sd watch ack --event "${e2}" --consumer c2 --task kongkongi-fixture-2
  [[ "${rc}" != 0 ]] || no "an acked event was acked again"
  scan_ok
  sd watch claim --consumer c3
  [[ "$(jq '.claimed | length' <<< "${out}")" == 0 ]] || no "an unknown or dispatched event was claimed again: ${out}"
  st --arg e "${e1}" '[.events[] | select(.id == $e and .status == "unknown")] | length == 1' "the unknown event is kept"
  # The repair's states, as the routine records them.
  local key
  key=$(npm_findings | jq -r '.[] | select(.package == "left") | .key')
  sd watch remediation --finding "${key}" --state blocked --detail "dirty main"
  [[ "${rc}" == 0 ]] || no "remediation blocked exited ${rc}"
  st '.summary.blocked == 1 and .summary.complete == false'
  sd watch remediation --finding "${key}" --state fix_failed --detail "tests failed; branch kept" --task kongkongi-fixture-1
  st --arg k "${key}" '.findings[$k].remediation.state == "fix_failed" and .summary.blocked == 0'
  sd watch remediation --finding "${key}" --state fixed
  [[ "${rc}" != 0 ]] || no "a remediation state outside the closed set was taken"
}
row "two consumers: a claimed event is held by its consumer until it acks it, unknown is kept and never retried, a dispatched event is acked once; remediation states are a closed set" row_consumers

# ---- what waits for the owner, and the last full scan --------------------------------------
# aw KEY: the why of KEY in the last `watch status` (out), as a JSON array.
aw() { jq -c --arg k "$1" '[.awaiting_owner[] | select(.key == $k) | .why]' <<< "${out}"; }
# rf KEY: the report_fact of KEY's row in the last `watch status` (out), the
# value the owner hands back with --expect.
rf() { jq -c --arg k "$1" '.awaiting_owner[] | select(.key == $k) | .report_fact' <<< "${out}"; }
ack_all_unknown() { # CONSUMER: claim every pending event and ack each --unknown
  local e
  sd watch claim --consumer "$1" --limit 50
  [[ "${rc}" == 0 ]] || no "claim exited ${rc}"
  for e in $(jq -r '.claimed[].id' <<< "${out}"); do
    sd watch ack --event "${e}" --consumer "$1" --unknown
    [[ "${rc}" == 0 ]] || no "ack --unknown exited ${rc}"
  done
}

row_report_only_npm() {
  new_world; register a
  npm_lock "${d}/p/a" lone@1.0.0 left@1.0.0
  fx ".osv[\"lone@1.0.0\"] = [$(osv_record GHSA-lone-lone-lone CVE-2026-4101 lone '')] | .osv[\"left@1.0.0\"] = [$(osv_record GHSA-left-left-left '' left 1.0.1)]"
  scan_ok
  local lone left g events fact left_fact
  lone=$(npm_findings | jq -r '.[] | select(.package == "lone") | .key')
  left=$(npm_findings | jq -r '.[] | select(.package == "left") | .key')
  # The day's send failed: every event was acked unknown. Both findings still wait.
  ack_all_unknown routine
  scan_ok
  sd watch status
  [[ "$(aw "${lone}")" == '["unassigned"]' && "$(aw "${left}")" == '["unassigned"]' ]] || no "after unknown acks: lone $(aw "${lone}"), left $(aw "${left}")"
  fact=$(rf "${lone}")
  left_fact=$(rf "${left}")
  [[ "$(jq -c '{state, fixed, kev}' <<< "${fact}")" == '{"state":"no_fix_available","fixed":[],"kev":false}' ]] || no "lone's report_fact: ${fact}"
  # A finding that can be fixed, a judgment without words, and one that does
  # not name the report it judged are refused.
  g=$(gen)
  sd watch remediation --finding "${left}" --state report_acknowledged --detail "seen" --expect "${left_fact}"
  [[ "${rc}" != 0 && "$(gen)" == "${g}" ]] || no "report_acknowledged on an open finding: rc ${rc}, generation $(gen)"
  sd watch remediation --finding "${lone}" --state report_acknowledged --detail "   " --expect "${fact}"
  [[ "${rc}" != 0 && "$(gen)" == "${g}" ]] || no "report_acknowledged with a blank detail: rc ${rc}, generation $(gen)"
  sd watch remediation --finding "${lone}" --state report_acknowledged --detail "upstream fix awaited"
  [[ "${rc}" != 0 && "$(gen)" == "${g}" ]] || no "report_acknowledged without --expect: rc ${rc}, generation $(gen)"
  # KEV lists lone after the owner read the status: the judgment was made on
  # another report. It is refused, nothing is written, and the error shows the
  # report as it is now.
  fx '.kev = ["CVE-2026-4101"]'
  scan_ok
  g=$(gen)
  sd watch remediation --finding "${lone}" --state report_acknowledged --detail "upstream fix awaited" --expect "${fact}"
  [[ "${rc}" != 0 && "$(gen)" == "${g}" ]] || no "a judgment of the report before the KEV listing: rc ${rc}, generation $(gen)"
  grep -qF '"kev":true' "${d}/stderr" || no "the refusal does not show the report now: $(head -c 400 "${d}/stderr")"
  sd watch status
  [[ "$(aw "${lone}")" == '["unassigned"]' && "$(rf "${lone}" | jq '.kev')" == true ]] || no "after the refusal: lone $(aw "${lone}") $(rf "${lone}")"
  fact=$(rf "${lone}")
  sd watch remediation --finding "${lone}" --state report_acknowledged --detail "listed in KEV; upstream fix awaited" --expect "${fact}"
  [[ "${rc}" == 0 ]] || no "report_acknowledged exited ${rc}: $(head -c 300 "${d}/stderr")"
  events=$(jq -c '[.events[] | {id, status}]' "${home}/watch/state.json")
  scan_ok
  sd watch status
  [[ "$(aw "${lone}")" == '[]' && "$(aw "${left}")" == '["unassigned"]' ]] || no "after the judgment and a scan: lone $(aw "${lone}"), left $(aw "${left}")"
  [[ "$(jq -c '[.events[] | {id, status}]' "${home}/watch/state.json")" == "${events}" ]] || no "the events moved: $(jq -c '[.events[] | {id, status}]' "${home}/watch/state.json")"
  # A fixed version is published: the judgment was made on another report.
  # OSV moves `modified` when it changes a record.
  fx ".osv[\"lone@1.0.0\"] = [$(osv_record GHSA-lone-lone-lone CVE-2026-4101 lone 1.0.2)] | .osv[\"lone@1.0.0\"][0].modified = \"2026-11-10T00:00:00Z\""
  scan_ok
  sd watch status
  [[ "$(aw "${lone}")" == '["acknowledged_other_state"]' ]] || no "no_fix -> open: lone $(aw "${lone}")"
  st --arg k "${lone}" '[.events[] | select(.finding == $k and .from == "no_fix_available" and .to == "open" and .status == "pending")] | length == 1' "one no_fix -> open event" '.events'
}
row "awaiting_owner: a no-fix finding acked --unknown still waits; report_acknowledged takes it out, is refused on an open finding, a blank detail, no --expect or a report KEV listed after the status was read, and holds until a fix is published" row_report_only_npm

row_report_only_runtime() {
  new_world; register older pre
  printf 'java=21.0.10-tem\n' > "${d}/p/older/.sdkmanrc"
  printf 'temurin-17.0.18\n' > "${d}/p/pre/.java-version"
  release() { jq -nc --arg n "$1" --argjson maj "$2" --argjson sec "$3" '{release_name: $n, timestamp: "2026-10-22T00:00:00Z", release_link: "https://example.invalid/r", version_data: {major: $maj, minor: 0, security: $sec, build: 7, openjdk_version: "\($maj).0.\($sec)+7-LTS"}}'; }
  fx ".adoptium = {\"21\": $(release jdk-21.0.14+7 21 14), \"17\": $(release jdk-17.0.18+7 17 18)}
      | .openjdk = [{date: \"2026-10-20\", affected: \"21.0.13, 17.0.18\"}]"
  scan_ok
  local older pre pending older_fact pre_fact
  older=$(jq -r --arg r "${d}/p/older" '.findings[] | select(.root == $r and .ecosystem == "runtime") | .key' "${home}/watch/state.json")
  pre=$(jq -r --arg r "${d}/p/pre" '.findings[] | select(.root == $r and .ecosystem == "runtime") | .key' "${home}/watch/state.json")
  st --arg o "${older}" --arg p "${pre}" '.findings[$o].state == "update_available" and .findings[$p].state == "pre_announced" and .findings[$p].fixed == []' "the two runtime findings" '.findings'
  ack_all_unknown routine
  scan_ok
  sd watch status
  [[ "$(aw "${older}")" == '["unassigned"]' && "$(aw "${pre}")" == '["unassigned"]' ]] || no "after unknown acks: older $(aw "${older}"), pre $(aw "${pre}")"
  older_fact=$(rf "${older}")
  pre_fact=$(rf "${pre}")
  sd watch remediation --finding "${older}" --state report_acknowledged --detail "the owner installs the update on 2026-11-25" --expect "${older_fact}"
  [[ "${rc}" == 0 ]] || no "report_acknowledged on older exited ${rc}: $(head -c 300 "${d}/stderr")"
  sd watch remediation --finding "${pre}" --state report_acknowledged --detail "the owner installs the update on 2026-11-25" --expect "${pre_fact}"
  [[ "${rc}" == 0 ]] || no "report_acknowledged on pre exited ${rc}: $(head -c 300 "${d}/stderr")"
  # A newer advisory names 17.0.18 again: pre stays pre_announced with fixed []
  # and a new date, so it waits again. Older's report did not move: it does not.
  fx '.openjdk += [{date: "2026-11-10", affected: "17.0.18"}]'
  scan_ok
  sd watch status
  [[ "$(aw "${pre}")" == '["acknowledged_other_state"]' && "$(aw "${older}")" == '[]' ]] || no "a new advisory: pre $(aw "${pre}"), older $(aw "${older}")"
  # The vendor ships 21.0.15: older's fixed moves and its state does not. It
  # waits again, and no event is raised.
  pending=$(jq --arg k "${older}" '[.events[] | select(.finding == $k and .status == "pending")] | length' "${home}/watch/state.json")
  fx ".adoptium[\"21\"] = $(release jdk-21.0.15+7 21 15)"
  scan_ok
  sd watch status
  [[ "$(aw "${older}")" == '["acknowledged_other_state"]' ]] || no "a newer build: older $(aw "${older}")"
  st --arg k "${older}" --arg n "${pending}" '.findings[$k].state == "update_available" and ([.events[] | select(.finding == $k and .status == "pending")] | length) == ($n | tonumber)' "no event for a moved fixed" '.findings'
}
row "awaiting_owner on runtimes: report_acknowledged holds while the report holds; a new advisory date on pre_announced and a newer build on update_available put each back, without an event" row_report_only_runtime

row_report_ack_lock() {
  new_world; register a
  npm_lock "${d}/p/a" lone@1.0.0 kevd@1.0.0
  fx ".osv[\"lone@1.0.0\"] = [$(osv_record GHSA-lock-lock-lock '' lone '')] | .osv[\"kevd@1.0.0\"] = [$(osv_record GHSA-kevd-kevd-kevd CVE-2026-4102 kevd '')]"
  scan_ok
  local lone kevd first g lone_fact kevd_fact
  lone=$(npm_findings | jq -r '.[] | select(.package == "lone") | .key')
  kevd=$(npm_findings | jq -r '.[] | select(.package == "kevd") | .key')
  sd watch status
  lone_fact=$(rf "${lone}")
  kevd_fact=$(rf "${kevd}")
  bg_scan first after_lock
  first=${bg_pid}
  wait_for "${d}/first.pause"
  g=$(gen)
  sd watch remediation --finding "${lone}" --state report_acknowledged --detail "seen" --expect "${lone_fact}"
  [[ "${rc}" == 75 && "$(gen)" == "${g}" ]] || no "report_acknowledged during a scan: rc ${rc}, generation $(gen)"
  sd watch remediation --finding "${kevd}" --state report_acknowledged --detail "seen" --expect "${kevd_fact}"
  [[ "${rc}" == 75 && "$(gen)" == "${g}" ]] || no "report_acknowledged during a scan: rc ${rc}, generation $(gen)"
  # The scan that held the lock reads KEV after the pause, and KEV lists kevd.
  fx '.kev = ["CVE-2026-4102"]'
  rm -f "${d}/first.pause"
  wait "${first}" || no "the paused scan exited $?: $(head -c 300 "${d}/first.err")"
  # The same commands again, as they were.
  sd watch remediation --finding "${lone}" --state report_acknowledged --detail "seen" --expect "${lone_fact}"
  [[ "${rc}" == 0 ]] || no "the retry exited ${rc}: $(head -c 300 "${d}/stderr")"
  g=$(gen)
  sd watch remediation --finding "${kevd}" --state report_acknowledged --detail "seen" --expect "${kevd_fact}"
  [[ "${rc}" != 0 && "${rc}" != 75 && "$(gen)" == "${g}" ]] || no "the retry after a scan that listed kevd in KEV: rc ${rc}, generation $(gen)"
  grep -qF '"kev":true' "${d}/stderr" || no "the refusal does not show the report now: $(head -c 400 "${d}/stderr")"
  scan_ok
  sd watch status
  [[ "$(aw "${lone}")" == '[]' && "$(aw "${kevd}")" == '["unassigned"]' ]] || no "after the next scan: lone $(aw "${lone}"), kevd $(aw "${kevd}")"
}
row "report_acknowledged while a scan holds the lock exits 75 and changes nothing; the same command again is kept by the next scan, and refused for a finding that scan listed in KEV" row_report_ack_lock

# fixed_pending_rescan captures the scan generation under the lock. Only a
# later measurement of this finding contradicts it. awaiting_deploy remains
# visible as nonfailure deployment work.
row_rescan_still_live() {
  new_world; register a
  npm_lock "${d}/p/a" left@1.0.0 right@2.0.0
  fx ".osv[\"left@1.0.0\"] = [$(osv_record GHSA-resc-resc-resc '' left 1.0.1)] | .osv[\"right@2.0.0\"] = [$(osv_record GHSA-depl-depl-depl '' right 2.0.1)]"
  scan_ok
  local left right
  left=$(npm_findings | jq -r '.[] | select(.package == "left") | .key')
  right=$(npm_findings | jq -r '.[] | select(.package == "right") | .key')
  sd watch remediation --finding "${left}" --state fixed_pending_rescan --task kongkongi-fixture-3
  [[ "${rc}" == 0 ]] || no "fixed_pending_rescan exited ${rc}"
  sd watch remediation --finding "${right}" --state awaiting_deploy --task kongkongi-fixture-4
  [[ "${rc}" == 0 ]] || no "awaiting_deploy exited ${rc}"
  sd watch status
  [[ "$(aw "${left}")" == '[]' && "$(aw "${right}")" == '["awaiting_deploy"]' ]] || no "before a scan: left $(aw "${left}"), right $(aw "${right}")"
  scan_ok
  sd watch status
  [[ "$(aw "${left}")" == '["rescan_still_live"]' && "$(aw "${right}")" == '["awaiting_deploy"]' ]] || no "a scan that still sees both: left $(aw "${left}"), right $(aw "${right}")"
  [[ "$(rf "${left}" | jq -c '{state, fixed}')" == '{"state":"open","fixed":["1.0.1"]}' ]] || no "left's row: $(rf "${left}")"
  npm_lock "${d}/p/a" left@1.0.1 right@2.0.0
  scan_ok
  st --arg k "${left}" '.findings[$k].state == "closed" and .findings[$k].closed_reason == "seen_fixed"' "left closed by the fixed lockfile" '.findings'
}
row "fixed_pending_rescan: a later scan that still sees the finding puts it back as rescan_still_live, and one that sees the fix closes it; awaiting_deploy stays visible without failure" row_rescan_still_live

row_last_full_scan() {
  new_world; register a
  npm_lock "${d}/p/a" right@2.0.0
  scan_ok
  st '.last_full_scan == (.last_scan + {errors: .errors})' "the first full scan"
  touch "${d}/pop.fail"
  scan
  [[ "${rc}" == 1 ]] || no "a full scan on a stale population exited ${rc}"
  local full
  full=$(jq -c '.last_scan | {run_id, finished_at}' "${home}/watch/state.json")
  rm -f "${d}/pop.fail"
  scan_ok --root "${d}/p/a"
  sd watch status
  jq -e --argjson f "${full}" '.last_scan.kind == "root" and (.errors | length) == 0
      and .last_full_scan.kind == "full" and .last_full_scan.run_id == $f.run_id and .last_full_scan.finished_at == $f.finished_at
      and ([.last_full_scan.errors[] | select(.kind == "population_stale")] | length) == 1
      and (.full_age_hours | type) == "number" and (.last_full_scan.runtime | type) == "object"' <<< "${out}" > /dev/null \
    || no "status after a root scan: $(jq -c '{last_scan: .last_scan.kind, errors, last_full_scan, full_age_hours}' <<< "${out}")"
}
row "last_full_scan: a root scan after a full scan with errors keeps the full scan's run, time and errors; last_scan is the root scan" row_last_full_scan

if (( failures > 0 )); then
  printf '# %d row(s) did not pass\n' "${failures}" >&2
  exit 1
fi
