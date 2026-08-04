#!/usr/bin/env bash
# safedeps: canonical advisory sources, and the notice when a run does not use them.
#
# Two things live here so they cannot drift apart: the default location of every
# source the tool treats as truth, and the check that says out loud when a run
# was pointed somewhere else. The comparison and the assignment read the same
# constant — holding the default in two places is how "the docs say 30s" became
# a release of its own.
#
# None of these knobs is forbidden. A mirror on a network that blocks osv.dev is
# a real need, and this repo's own test suite runs on the fixtures. What must not
# happen is a run judged against a moved source looking exactly like a run judged
# against OSV, so each deviation is named once per run in advisory.log.
#
# This file is separate from providers.sh because the PreToolUse guard must be
# able to say it too, and that hook runs on every Bash call — it cannot afford to
# source the provider stack, so it sources this instead, and only when something
# is actually set.

SAFEDEPS_DEFAULT_OSV_API_URL="https://api.osv.dev/v1/query"
SAFEDEPS_DEFAULT_OSV_BATCH_API_URL="https://api.osv.dev/v1/querybatch"
SAFEDEPS_DEFAULT_KEV_CATALOG_URL="https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json"
SAFEDEPS_DEFAULT_GHSA_API_URL="https://api.github.com/advisories"
SAFEDEPS_DEFAULT_LEDGER_TTL_DAYS="30"

# True when anything at all is set, so a caller on a hot path can skip the rest.
# Deliberately cheap: no subshells, no file access.
safedeps_truth_sources_possibly_moved() {
  [[ -n "${SAFEDEPS_OSV_API_URL:-}" ]] && return 0
  [[ -n "${SAFEDEPS_OSV_BATCH_API_URL:-}" ]] && return 0
  [[ -n "${SAFEDEPS_KEV_CATALOG_URL:-}" ]] && return 0
  [[ -n "${SAFEDEPS_GHSA_API_URL:-}" ]] && return 0
  [[ -n "${SAFEDEPS_NPM_CLOSURE_FIXTURE_JSON:-}" ]] && return 0
  [[ -n "${SAFEDEPS_YARN_INFO_FIXTURE_NDJSON:-}" ]] && return 0
  [[ -n "${SAFEDEPS_NPM_OVERRIDES_JSON:-}" ]] && return 0
  [[ -n "${SAFEDEPS_RECHECK_FIXTURE_JSON:-}" ]] && return 0
  [[ -n "${SAFEDEPS_LEDGER_DEFAULT_TTL_DAYS:-}" ]] && return 0
  [[ -n "${SAFEDEPS_ADVISORY_LOG:-}" ]] && return 0
  return 1
}

# The list below is what has been found, not a claim that nothing else exists.
# The last two entries were found by a validator after the enumeration that
# preceded them called itself complete — so treat this as a growing list and add
# to it when a new knob turns out to decide an answer.
safedeps_truth_sources_moved_list() {
  local moved=()
  [[ "${SAFEDEPS_OSV_API_URL:-${SAFEDEPS_DEFAULT_OSV_API_URL}}" == "${SAFEDEPS_DEFAULT_OSV_API_URL}" ]] \
    || moved+=("osv=${SAFEDEPS_OSV_API_URL}")
  [[ "${SAFEDEPS_OSV_BATCH_API_URL:-${SAFEDEPS_DEFAULT_OSV_BATCH_API_URL}}" == "${SAFEDEPS_DEFAULT_OSV_BATCH_API_URL}" ]] \
    || moved+=("osv-batch=${SAFEDEPS_OSV_BATCH_API_URL}")
  [[ "${SAFEDEPS_KEV_CATALOG_URL:-${SAFEDEPS_DEFAULT_KEV_CATALOG_URL}}" == "${SAFEDEPS_DEFAULT_KEV_CATALOG_URL}" ]] \
    || moved+=("kev=${SAFEDEPS_KEV_CATALOG_URL}")
  [[ "${SAFEDEPS_GHSA_API_URL:-${SAFEDEPS_DEFAULT_GHSA_API_URL}}" == "${SAFEDEPS_DEFAULT_GHSA_API_URL}" ]] \
    || moved+=("ghsa=${SAFEDEPS_GHSA_API_URL}")
  [[ -z "${SAFEDEPS_NPM_CLOSURE_FIXTURE_JSON:-}" ]] || moved+=("npm-closure-fixture=${SAFEDEPS_NPM_CLOSURE_FIXTURE_JSON}")
  [[ -z "${SAFEDEPS_YARN_INFO_FIXTURE_NDJSON:-}" ]] || moved+=("yarn-info-fixture=${SAFEDEPS_YARN_INFO_FIXTURE_NDJSON}")
  # Replaces the repo's own overrides, which the closure resolver folds into the
  # verdict — the e2e suite says so in its own assertion name.
  [[ -z "${SAFEDEPS_NPM_OVERRIDES_JSON:-}" ]] || moved+=("npm-overrides=set")
  # Replaces the re-check output the daily alert reads.
  [[ -z "${SAFEDEPS_RECHECK_FIXTURE_JSON:-}" ]] || moved+=("recheck-fixture=${SAFEDEPS_RECHECK_FIXTURE_JSON}")
  # Not an advisory source, but the same class of claim: the ledger TTL is the
  # promise that an old approval gets asked again, and a large enough value
  # retires that promise without retiring the sentence that makes it.
  [[ "${SAFEDEPS_LEDGER_DEFAULT_TTL_DAYS:-${SAFEDEPS_DEFAULT_LEDGER_TTL_DAYS}}" == "${SAFEDEPS_DEFAULT_LEDGER_TTL_DAYS}" ]] \
    || moved+=("ledger-ttl-days=${SAFEDEPS_LEDGER_DEFAULT_TTL_DAYS}")
  printf '%s' "${moved[*]:-}"
}
