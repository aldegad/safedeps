#!/bin/bash
set -euo pipefail

# safedeps audit — multi-ecosystem dependency lockfile audit.
# Delegates to each ecosystem's native audit tool (npm / pnpm / yarn / bun),
# all of which query the npm registry advisory endpoint, and normalizes the
# verdict so the caller (the pre-commit hook) gets one stable contract.
#
# Absorbed from kuma-studio scripts/security/run-npm-audit.sh; generalized in
# v2.9 from npm-only to npm/pnpm/yarn/bun.
#
# Exit codes are meaningful so a caller can tell a security verdict apart from
# an availability problem — every native audit tool collapses both into a
# non-zero exit on its own:
#   0  clean — no advisory at or above the audit level in any audited ecosystem
#   1  vulnerable — at least one advisory at or above the level (BLOCK)
#   2  could not produce a verdict — no lockfile, the audit tool/jq missing, or
#      the advisory database is unreachable (offline/registry error). This is an
#      AVAILABILITY failure, not a clean bill of health; the caller decides
#      whether to fail-closed or warn-and-continue.
#  64  usage error
#
# When several lockfiles coexist (or several ecosystems are named), the
# aggregate verdict is the worst: a real finding anywhere (1) dominates; else an
# availability failure anywhere (2); else clean (0). No ecosystem is skipped
# silently (no-silent-fallback invariant).

# The core and the npm readers this CLI uses, for the accepted-source ledger
# (accepted_out below).
SAFEDEPS_REPO_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../providers/providers.sh
source "${SAFEDEPS_REPO_DIR}/lib/providers/providers.sh"
# shellcheck source=../npm/closure.sh
source "${SAFEDEPS_REPO_DIR}/lib/npm/closure.sh"

REPO_ROOT=""
AUDIT_LEVEL="${SAFEDEPS_AUDIT_LEVEL:-${SAFEDEPS_NPM_AUDIT_LEVEL:-${KUMA_NPM_AUDIT_LEVEL:-moderate}}}"
ECOS_REQUESTED=()

usage() {
  printf 'Usage: safedeps audit [npm|pnpm|yarn|bun ...] [--root <repo>] [--level <low|moderate|high|critical>]\n' >&2
}

while [ $# -gt 0 ]; do
  case "$1" in
    npm|pnpm|yarn|bun) ECOS_REQUESTED+=("$1"); shift ;;
    --root) REPO_ROOT="${2:?--root needs a path}"; shift 2 ;;
    --level) AUDIT_LEVEL="${2:?--level needs a value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 64 ;;
  esac
done

if [ -z "$REPO_ROOT" ]; then REPO_ROOT="$(pwd)"; fi
REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"
cd "$REPO_ROOT"

note() { printf 'safedeps audit: %s\n' "$*" >&2; }

# Validate the resolved audit level (from --level or the env-var defaults) up
# front. An unrecognized value must be a usage error, not silently snapped to
# "moderate" — otherwise a deliberately strict `--level low` typo'd to garbage
# would quietly let a low-severity advisory pass.
case "${AUDIT_LEVEL}" in
  low|moderate|high|critical) ;;
  *) note "invalid audit level: ${AUDIT_LEVEL} (expected low|moderate|high|critical)"; exit 64 ;;
esac

# --- ecosystem detection ------------------------------------------------------
# Each lockfile names exactly one package manager.
detect_ecosystems() {
  local found=()
  { [ -f package-lock.json ] || [ -f npm-shrinkwrap.json ]; } && found+=("npm")
  [ -f pnpm-lock.yaml ] && found+=("pnpm")
  [ -f yarn.lock ] && found+=("yarn")
  { [ -f bun.lock ] || [ -f bun.lockb ]; } && found+=("bun")
  printf '%s\n' "${found[@]+"${found[@]}"}"
}

ecosystems=()
if [ "${#ECOS_REQUESTED[@]}" -gt 0 ]; then
  ecosystems=("${ECOS_REQUESTED[@]}")
else
  while IFS= read -r e; do [ -n "$e" ] && ecosystems+=("$e"); done < <(detect_ecosystems)
fi

if [ "${#ecosystems[@]}" -eq 0 ]; then
  note 'no package-lock.json / pnpm-lock.yaml / yarn.lock / bun.lock — cannot produce a reproducible verdict.'
  exit 2
fi

# --- no-jq fallback -----------------------------------------------------------
# Without jq we cannot separate an offline failure from a real finding across
# the different tool schemas, so degrade to each tool's own plain audit and let
# any non-zero exit BLOCK (fail-closed, safe). An absent tool is an availability
# failure (2). This path never silently allows a vulnerability through.
if ! command -v jq >/dev/null 2>&1; then
  worst=0
  for eco in "${ecosystems[@]}"; do
    if ! command -v "$eco" >/dev/null 2>&1; then
      note "$eco not found and jq missing — cannot audit ${eco} lockfile."
      [ "$worst" -ne 1 ] && worst=2
      continue
    fi
    case "$eco" in
      yarn)
        # Mirror the jq path's version routing: Berry (2+) has no `yarn audit`,
        # so running it unconditionally would block every clean Berry repo.
        yv="$(yarn --version 2>/dev/null)"; ymaj="${yv%%.*}"
        if [[ "$ymaj" =~ ^[0-9]+$ ]] && [ "$ymaj" -ge 2 ]; then
          yarn npm audit --all --recursive >/dev/null 2>&1 || worst=1
        else
          yarn audit --level "$AUDIT_LEVEL" >/dev/null 2>&1 || worst=1
        fi ;;
      *)    "$eco" audit --audit-level "$AUDIT_LEVEL" >/dev/null 2>&1 || worst=1 ;;
    esac
  done
  exit "$worst"
fi

# --- shared verdict helpers ---------------------------------------------------
# Count advisories at or above AUDIT_LEVEL from a compact {info,low,..,critical}
# severity-count object on stdin.
counts_block_n() {
  jq --arg lvl "$AUDIT_LEVEL" '
    . as $v
    | ["info","low","moderate","high","critical"] as $order
    | (($order | index($lvl)) // 2) as $min
    | reduce $order[$min:][] as $s (0; . + (($v[$s] // 0) | tonumber))
  '
}

# Human-readable severity line from a compact severity-count object on stdin.
print_severities() {
  jq -r '
    . as $v
    | ["critical","high","moderate","low","info"]
    | map(select(($v[.] // 0) > 0) | "\($v[.]) \(.)")
    | if length > 0 then "  severities: " + join(", ") else empty end
  ' >&2
}

# Emit the per-ecosystem verdict and return 0/1/2 from a compact severity-count
# object ($2) for ecosystem $1. No count is no verdict: the callers run under
# `||`, where errexit is off, and a jq that failed here read as zero findings.
verdict_from_counts() {
  local eco="$1" counts="$2" n
  if ! n="$(printf '%s' "$counts" | counts_block_n)" || ! [[ "$n" =~ ^[0-9]+$ ]]; then
    note "could not read the ${eco} audit counts."
    return 2
  fi
  if [ "$n" -gt 0 ]; then
    printf '%s' "$counts" | print_severities
    note "$eco: ${n} advisory(ies) at or above \"${AUDIT_LEVEL}\" — blocking. Run \`${eco} audit\` for the full report."
    return 1
  fi
  return 0
}

# A non-zero exit is how npm, pnpm and yarn say they found something, so it
# cannot stop the run. One with no finding in the report is a run that failed,
# whatever it printed first. $1 is the exit, $2 the compact severity counts.
failed_with_no_finding() {
  [ "$1" -ne 0 ] && ! printf '%s' "$2" | jq -e 'any(.[]; . != 0)' >/dev/null 2>&1
}

# --- accepted sources (npm) ---------------------------------------------------
# A vulnerable package that the accepted-source ledger covers is taken out of
# npm's counts and named on one line that is not a warning. It is covered when
# every lock record of it names an entry's URL, integrity, name and version
# (SAFEDEPS_NPM_ACCEPTED_JQ, lib/npm/closure.sh), and every advisory npm names
# for it is one its entries name. npm names an advisory by its GitHub URL, so
# the id is the URL's last part. A KEV listing is never covered: each covered
# package is asked of OSV and the KEV catalog (safedeps_providers_query), and
# one that KEV lists, or that cannot be asked, is counted and said so. A
# package npm counts only for its dependencies (every `via` a name) is taken
# out once all of those are. The ledger is read through the core
# (`safedeps-core sources index`); one that cannot be read takes nothing out
# and says so.
#
# The lock records are those of the lockfile npm audits: the one npm reads
# (safedeps_npm_project_lockfile, lib/npm/closure.sh) in the directory npm
# resolves as its project, which it is asked for (`npm prefix`): in a
# workspace member that is the workspace's root. The lockfile is read once,
# into a copy of this run's own, and every judgment below reads the copy. A
# directory npm does not name, a lockfile that cannot be read and a project
# where neither lockfile holds a byte take nothing out, and say so. $1 is
# npm's report, $2 its counts; the counts left are printed.
accepted_out() {
  local copy rc=0
  if ! copy="$(mktemp "${TMPDIR:-/tmp}/safedeps-audit-lock.XXXXXX" 2>/dev/null)"; then
    note "npm: a copy of the lockfile could not be made, so every advisory npm reported is counted."
    printf '%s' "$2"; return 0
  fi
  accepted_counts "$1" "$2" "$copy" || rc=$?
  rm -f -- "$copy"
  return "$rc"
}
accepted_counts() {
  local report="$1" counts="$2" copy="$3" prefix lock unread=0 entries covered own pairs n v answer dropped='[]' out
  if ! printf '%s' "$report" | jq -e '(.vulnerabilities | type) == "object" and (.vulnerabilities | length) > 0' >/dev/null 2>&1; then
    printf '%s' "$counts"; return 0
  fi
  if ! sf_core 2>/dev/null \
    || ! entries="$(SAFEDEPS_HOME="${SAFEDEPS_HOME}" "${SF_CORE}" sources index 2>/dev/null | jq -ce '.entries | arrays')"; then
    note "npm: the accepted-source ledger could not be read, so every advisory npm reported is counted."
    printf '%s' "$counts"; return 0
  fi
  if [ "$entries" = '[]' ]; then printf '%s' "$counts"; return 0; fi
  if ! prefix="$(npm prefix 2>/dev/null)" || [ -z "$prefix" ] || [ ! -d "$prefix" ]; then
    note "npm: npm did not say which project it audits (npm prefix), so every advisory npm reported is counted."
    printf '%s' "$counts"; return 0
  fi
  lock="$(safedeps_npm_project_lockfile "$prefix" "$copy")" || unread=$?
  case "$unread" in
    0) ;;
    1) note "npm: ${prefix%/}/${lock} could not be read, so every advisory npm reported is counted."
       printf '%s' "$counts"; return 0 ;;
    *) note "npm: a copy of the lockfile could not be written, so every advisory npm reported is counted."
       printf '%s' "$counts"; return 0 ;;
  esac
  if [ -z "$lock" ]; then
    note "npm: neither npm-shrinkwrap.json nor package-lock.json in ${prefix} holds a byte, so no accepted source covers an advisory npm reported, and every one is counted."
    printf '%s' "$counts"; return 0
  fi
  lock="${prefix%/}/${lock}"
  # The packages an entry covers, each with the versions its records hold.
  if ! covered="$(jq -c --arg root "$prefix" --arg rel "$lock" --argjson entries "$entries" "${SAFEDEPS_NPM_ACCEPTED_JQ}" "$copy" | jq -sc .)" \
    || ! own="$(printf '%s' "$report" | jq -c --slurpfile lock "$copy" --argjson covered "$covered" "${SAFEDEPS_AUDIT_ACCEPTED_JQ}"'
      [$v | keys[] | select(covered(.)) | {name: ., versions: versions(.)}]')" \
    || ! pairs="$(printf '%s' "$own" | jq -r '.[] | .name as $n | .versions[] | [$n, .] | @tsv')"; then
    note "npm: the accepted-source ledger could not be compared with ${lock}, so every advisory npm reported is counted."
    printf '%s' "$counts"; return 0
  fi
  while IFS=$'\t' read -r n v; do
    [ -n "$n" ] || continue
    if answer="$(safedeps_providers_query npm "$n" "$v" 2>/dev/null)" \
      && printf '%s' "$answer" | jq -e '.kev.exploited == false' >/dev/null 2>&1; then
      continue
    fi
    if printf '%s' "$answer" | jq -e '.kev.exploited == true' >/dev/null 2>&1; then
      note "npm: ${n}@${v} has an accepted source, and CISA KEV lists one of its advisories, so it is counted."
    else
      note "npm: ${n}@${v} has an accepted source, and OSV or the KEV catalog could not be asked about it, so it is counted."
    fi
    if ! dropped="$(printf '%s' "$dropped" | jq -c --arg n "$n" '. + [$n]')"; then
      note "could not read the npm audit counts."
      return 1
    fi
  done <<< "$pairs"
  if ! out="$(printf '%s' "$report" | jq -c --slurpfile lock "$copy" --argjson covered "$covered" --argjson dropped "$dropped" --argjson counts "$counts" "${SAFEDEPS_AUDIT_ACCEPTED_JQ}"'
      def step($t): [$v | keys[] | . as $n
        | ([($v[$n].via // [])[] | objects] | length) as $objects
        | ([($v[$n].via // [])[] | strings]) as $deps
        | select(($objects > 0 or ($deps | length) > 0)
            and ($objects == 0 or (covered($n) and ($dropped | index([$n]) | not)))
            and all($deps[]; . as $d | $t | index([$d]) != null))];
      def fix($t): step($t) as $u | if $u == $t then $t else fix($u) end;
      fix([]) as $taken
      | {counts: (reduce $taken[] as $n ($counts; ($v[$n].severity // "") as $s
                   | if has($s) then .[$s] -= 1 | (if has("total") then .total -= 1 else . end) else . end)),
         taken: [$taken[] | . as $n | (versions($n) | join(", ")) as $vers
                 | ([($v[$n].via // [])[] | objects | (.url // "") | split("/") | last] | unique) as $ids
                 | $n + "@" + $vers + (if ($ids | length) > 0 then " (" + ($ids | join(", ")) + ")" else "" end)]}')"; then
    note "npm: the accepted-source ledger could not be compared with ${lock}, so every advisory npm reported is counted."
    printf '%s' "$counts"; return 0
  fi
  if printf '%s' "$out" | jq -e '.taken | length > 0' >/dev/null 2>&1; then
    note "npm: accepted sources (safedeps sources), not counted: $(printf '%s' "$out" | jq -r '.taken | join("; ")')"
  fi
  printf '%s' "$out" | jq -c '.counts'
}

# Definitions both reads of npm's report share: $v is its vulnerabilities,
# versions($n) the versions npm's nodes of $n hold in the lockfile, and
# covered($n) that every node of $n is a package an entry covers, and every
# advisory npm names for $n directly is one those entries name.
SAFEDEPS_AUDIT_ACCEPTED_JQ='
  ($lock[0].packages // {}) as $records
  | ($covered | map({key: (.package + "@" + .version), value: .advisories}) | from_entries) as $cov
  | .vulnerabilities as $v
  | def versions($n): [($v[$n].nodes // [])[] | ($records[.] // {}) | .version // empty] | unique;
    def covered($n): [($v[$n].nodes // [])[] | ($records[.] // {}) | $cov[$n + "@" + (.version // "")]] as $a
      | ($a | length) > 0 and all($a[]; . != null)
        and all(($v[$n].via // [])[] | objects; ((.url // "") | split("/") | last) as $id | all($a[]; index([$id]) != null));
'

# --- per-ecosystem audits -----------------------------------------------------

# npm and pnpm share the npm v6/v7 report shape: .metadata.vulnerabilities holds
# {info,low,moderate,high,critical[,total]}; an unreachable registry surfaces a
# top-level {"error":...} (or no/invalid JSON) instead.
audit_npm_like() {
  local eco="$1" report counts audit_rc=0
  command -v "$eco" >/dev/null 2>&1 || { note "$eco not found — cannot audit ${eco} lockfile."; return 2; }
  report="$("$eco" audit --json 2>/dev/null)" || audit_rc=$?
  if [ -z "$report" ] \
     || ! printf '%s' "$report" | jq -e . >/dev/null 2>&1 \
     || printf '%s' "$report" | jq -e 'has("error")' >/dev/null 2>&1 \
     || ! printf '%s' "$report" | jq -e '.metadata.vulnerabilities' >/dev/null 2>&1; then
    note "could not reach the advisory database via ${eco} (offline or registry error)."
    return 2
  fi
  if ! counts="$(printf '%s' "$report" | jq -c '.metadata.vulnerabilities')" || failed_with_no_finding "$audit_rc" "$counts"; then
    note "could not reach the advisory database via ${eco} (offline or registry error)."
    return 2
  fi
  if [ "$eco" = npm ]; then
    if ! counts="$(accepted_out "$report" "$counts")"; then
      note "could not read the npm audit counts."
      return 2
    fi
  fi
  verdict_from_counts "$eco" "$counts"
}

# yarn split its CLI: Classic (1.x) has a built-in `yarn audit`; Berry (2+) dropped
# it and moved auditing to `yarn npm audit`. Detect the major version and route.
audit_yarn() {
  local yv major
  command -v yarn >/dev/null 2>&1 || { note 'yarn not found — cannot audit yarn.lock.'; return 2; }
  yv="$(yarn --version 2>/dev/null)" || { note 'could not run yarn to audit yarn.lock.'; return 2; }
  major="${yv%%.*}"
  if [[ "${major}" =~ ^[0-9]+$ ]] && [ "${major}" -ge 2 ]; then
    audit_yarn_berry
  else
    audit_yarn_classic
  fi
}

# yarn Classic (1.x) streams newline-delimited JSON; the final auditSummary line
# carries .data.vulnerabilities as {info,low,moderate,high,critical}. No summary
# line means the audit could not complete (offline / missing lockfile) → 2.
audit_yarn_classic() {
  local out summary counts audit_rc=0
  out="$(yarn audit --json 2>/dev/null)" || audit_rc=$?
  summary="$(printf '%s\n' "$out" | grep -F '"type":"auditSummary"' | tail -1)"
  if [ -z "$summary" ] || ! counts="$(printf '%s' "$summary" | jq -ce '.data.vulnerabilities' 2>/dev/null)" \
     || failed_with_no_finding "$audit_rc" "$counts"; then
    note 'could not produce a yarn audit verdict (offline or registry error).'
    return 2
  fi
  verdict_from_counts "yarn" "$counts"
}

# yarn Berry (2+) `yarn npm audit` streams NDJSON advisory lines
# ({"value":<pkg>,"children":{"Severity":...}}) and exits non-zero on a finding.
# Clean is empty output + exit 0; an offline/registry error is empty output +
# non-zero exit (no advisory lines) → could-not-run (2), never a silent clean.
# Severities are fail-closed (an unrecognized value counts as critical).
audit_yarn_berry() {
  local out rc adv counts adv_rc=0
  out="$(yarn npm audit --all --recursive --json 2>/dev/null)"; rc=$?
  adv="$(printf '%s' "$out" | jq -c 'select(type == "object" and (.children.Severity? != null))' 2>/dev/null)" || adv_rc=$?
  if [ "${adv_rc}" -ne 0 ] || { [ "${rc}" -ne 0 ] && [ -z "${adv}" ]; }; then
    note 'could not produce a Yarn Berry npm audit verdict (offline or registry error).'
    return 2
  fi
  counts="$(printf '%s' "${adv}" | jq -cs '
    reduce (.[] | .children.Severity) as $sev
      ({info:0,low:0,moderate:0,high:0,critical:0};
       ($sev | if type == "string" then ascii_downcase else "" end) as $s
       | if has($s) then .[$s] += 1 else .critical += 1 end)
  ')" || { note 'could not parse the Yarn Berry audit report (unexpected shape).'; return 2; }
  verdict_from_counts "yarn" "$counts"
}

# bun emits an object keyed by package name, each value an array of advisories
# carrying .severity; {} means clean. Empty / non-object output is an error
# (offline / registry). Unlike npm/pnpm/yarn (which report pre-aggregated counts),
# bun is re-tallied from raw per-advisory severities, so the filter must be both
# total (never crash on an unexpected shape — that would empty `counts` and read
# as CLEAN) and fail-closed (an advisory with a missing or unrecognized severity
# counts as critical, never silently dropped). A jq failure → could-not-run (2),
# matching audit_yarn's guarded substitution. (no-silent-fallback invariant)
audit_bun() {
  local out rc counts
  command -v bun >/dev/null 2>&1 || { note 'bun not found — cannot audit bun lockfile.'; return 2; }
  out="$(bun audit --json 2>/dev/null)"; rc=$?
  # Could-not-run (parity with audit_npm_like, not just the empty/offline case):
  # empty output; not a JSON object; a registry/error object ({"error":...}); a
  # non-advisory shape (an object whose values are not advisory arrays); or a
  # non-zero exit whose body still looks clean ({}). Any of these is an
  # availability failure (2), never a silent clean (0).
  if [ -z "$out" ] \
     || ! printf '%s' "$out" | jq -e 'type == "object"' >/dev/null 2>&1 \
     || printf '%s' "$out" | jq -e 'has("error")' >/dev/null 2>&1 \
     || ! printf '%s' "$out" | jq -e '(. == {}) or (any(.[]; type == "array"))' >/dev/null 2>&1 \
     || { [ "$rc" -ne 0 ] && printf '%s' "$out" | jq -e '. == {}' >/dev/null 2>&1; }; then
    note 'could not produce a bun audit verdict (offline, registry error, or unexpected shape).'
    return 2
  fi
  counts="$(printf '%s' "$out" | jq -c '
    reduce (.[]? | arrays | .[]? | objects) as $adv
      ({info:0,low:0,moderate:0,high:0,critical:0};
       ($adv.severity) as $sev
       | if ($sev | type) == "string" and has($sev) then .[$sev] += 1
         else .critical += 1 end)
  ')" || { note 'could not parse the bun audit report (unexpected shape).'; return 2; }
  verdict_from_counts "bun" "$counts"
}

# --- drive every ecosystem, aggregate the verdict -----------------------------
worst=0
for eco in "${ecosystems[@]}"; do
  rc=0
  case "$eco" in
    npm|pnpm) audit_npm_like "$eco" || rc=$? ;;
    yarn)     audit_yarn || rc=$? ;;
    bun)      audit_bun || rc=$? ;;
    *)        note "unknown ecosystem: $eco"; rc=2 ;;
  esac
  if [ "$rc" -eq 1 ]; then
    worst=1
  elif [ "$rc" -eq 2 ] && [ "$worst" -ne 1 ]; then
    worst=2
  fi
done

exit "$worst"
