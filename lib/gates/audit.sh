#!/bin/bash
set -euo pipefail

# safedeps audit npm — generic npm lockfile audit.
# Absorbed from kuma-studio scripts/security/run-npm-audit.sh.
#
# Exit codes are meaningful so a caller (e.g. the pre-commit hook) can tell a
# security verdict apart from an availability problem — npm audit collapses both
# into exit 1 on its own:
#   0  clean — no advisory at or above the audit level
#   1  vulnerable — at least one advisory at or above the level (BLOCK)
#   2  could not produce a verdict — no lockfile, npm/jq missing, or the npm
#      advisory database is unreachable (offline/registry error). This is an
#      AVAILABILITY failure, not a clean bill of health; the caller decides
#      whether to fail-closed or warn-and-continue.
#  64  usage error

REPO_ROOT=""
AUDIT_LEVEL="${SAFEDEPS_NPM_AUDIT_LEVEL:-${KUMA_NPM_AUDIT_LEVEL:-moderate}}"

usage() {
  printf 'Usage: safedeps audit [npm] [--root <repo>] [--level <low|moderate|high|critical>]\n' >&2
}

while [ $# -gt 0 ]; do
  case "$1" in
    npm) shift ;; # allow `audit npm`
    --root) REPO_ROOT="${2:?--root needs a path}"; shift 2 ;;
    --level) AUDIT_LEVEL="${2:?--level needs a value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 64 ;;
  esac
done

if [ -z "$REPO_ROOT" ]; then REPO_ROOT="$(pwd)"; fi
REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"
cd "$REPO_ROOT"

if [ ! -f package-lock.json ] && [ ! -f npm-shrinkwrap.json ]; then
  printf 'safedeps audit: no package-lock.json/npm-shrinkwrap.json — cannot produce a reproducible verdict.\n' >&2
  exit 2
fi

if ! command -v npm >/dev/null 2>&1; then
  printf 'safedeps audit: npm not found — cannot produce a dependency verdict.\n' >&2
  exit 2
fi

# Without jq we cannot reliably separate an offline failure from a real finding,
# so degrade to a plain, fail-closed audit: any non-zero exit blocks (safe).
if ! command -v jq >/dev/null 2>&1; then
  npm audit --audit-level="$AUDIT_LEVEL"
  exit $?
fi

# One JSON run. npm audit shares exit 1 between "vulnerable" and "could not run",
# so we read the verdict from the payload, not the exit code.
audit_json="$(npm audit --json 2>/dev/null || true)"

# Unreachable advisory DB / setup error → npm emits a top-level {"error":...},
# or no/invalid JSON. Availability failure, not a verdict.
if [ -z "$audit_json" ] \
   || ! printf '%s' "$audit_json" | jq -e . >/dev/null 2>&1 \
   || printf '%s' "$audit_json" | jq -e 'has("error")' >/dev/null 2>&1; then
  printf 'safedeps audit: could not reach the npm advisory database (offline or registry error).\n' >&2
  exit 2
fi

# Count advisories at or above the configured level.
n_at_level="$(printf '%s' "$audit_json" | jq --arg lvl "$AUDIT_LEVEL" '
  (.metadata.vulnerabilities // {}) as $v
  | ["low","moderate","high","critical"] as $order
  | (($order | index($lvl)) // 1) as $min
  | reduce $order[$min:][] as $s (0; . + ($v[$s] // 0))
')"

if [ "${n_at_level:-0}" -gt 0 ]; then
  printf '%s' "$audit_json" | jq -r '
    (.metadata.vulnerabilities // {}) as $v
    | "  severities: " +
      ([ "critical","high","moderate","low" ]
       | map(select(($v[.] // 0) > 0) | "\($v[.]) \(.)") | join(", "))
  ' >&2
  printf '%s' "$audit_json" | jq -r '(.vulnerabilities // {}) | keys[] | "  - " + .' 2>/dev/null | head -20 >&2 || true
  printf 'safedeps audit: %s advisory(ies) at or above "%s" — blocking. Run `npm audit` for the full report.\n' "$n_at_level" "$AUDIT_LEVEL" >&2
  exit 1
fi
exit 0
