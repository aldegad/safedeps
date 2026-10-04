#!/usr/bin/env bash
# Records scripts/test/inert-release-rewrites.json: what the release's own
# pre-guard (7d66f8c, the last commit before the inert rewrite read the
# install's words) prints for every command smoke and lockless-forms rewrite.
# The release floor check (scripts/test/lib/release-floor.sh) compares this
# tree's rewrite with these, so they are measured by running that hook, never
# written by hand: where the record came from is the whole of the check.
#
# usage: scripts/measure/release-floor-record.sh [<release ref>]
#
# It archives the release into a scratch directory, runs both batteries from a
# copy of this tree with SAFEDEPS_RELEASE_HOOK pointing at the release's hook,
# and merges what they recorded into the corpus. Each recorded call runs the
# release's hook on the same payload, in a copy of the project and the safedeps
# home. lockless-forms installs synthetic packages from its local registry, as
# it always does (scripts/test/lib/npm-sandbox.sh). A battery that fails still
# records what it reached, and the script says so and exits non-zero.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "${ROOT_DIR}"
ref="${1:-7d66f8c}"

scratch=$(mktemp -d "${TMPDIR:-/tmp}/release-floor-record.XXXXXX")
trap 'rm -rf "${scratch}"' EXIT
mkdir -p "${scratch}/release" "${scratch}/tree"
git archive "${ref}" | tar -xf - -C "${scratch}/release"
git ls-files -z --cached --others --exclude-standard | xargs -0 tar -cf - | tar -xf - -C "${scratch}/tree"
printf '[]\n' > "${scratch}/tree/scripts/test/inert-release-rewrites.json"

rc=0
for battery in smoke lockless-forms; do
  if ! (cd "${scratch}/tree" \
        && SAFEDEPS_RELEASE_HOOK="${scratch}/release/scripts/safedeps-pre-guard.sh" \
           SAFEDEPS_RELEASE_RECORD="${scratch}/${battery}.jsonl" \
           bash "scripts/test/${battery}.sh" > "${scratch}/${battery}.log" 2>&1); then
    printf 'release-floor-record: %s failed while recording; its log ends:\n' "${battery}" >&2
    tail -5 "${scratch}/${battery}.log" >&2
    rc=1
  fi
  touch "${scratch}/${battery}.jsonl"
done

python3 scripts/test/lib/release-floor-merge.py scripts/test/inert-release-rewrites.json \
  "${scratch}/smoke.jsonl" "${scratch}/lockless-forms.jsonl"
printf 'release-floor-record: recorded from %s (%s)\n' "${ref}" "$(git rev-parse "${ref}")"
exit "${rc}"
