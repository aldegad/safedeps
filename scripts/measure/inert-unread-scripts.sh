#!/usr/bin/env bash
# The sandbox reads the NPM_SANDBOX_* settings, and the forms are shell text kept literal.
# shellcheck disable=SC2016,SC2034
# shellcheck source-path=SCRIPTDIR
# How many install scripts run, with a real npm, when an approved install sits
# in text the inert rewrite cannot read: a double-quoted script with an escape
# or a substitution in it, a script handed to ksh, a heredoc body piped to
# another command. The forms are lockless-forms section 11e. For each, the
# pre-guard judges the command, the command it sends runs in a fresh sandbox
# project, and the synthetic package's preinstall, install and postinstall each
# write a mark: `install` counts the marks written while the command ran,
# `rebuild` the ones the post hook's rebuild wrote after the closure verified.
# Nothing leaves the machine (scripts/test/lib/npm-sandbox.sh: a local fixture
# registry, its own home, cache and prefix).
#
# usage: scripts/measure/inert-unread-scripts.sh
# Historical guard overlays are retired; use a complete historical archive.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "${ROOT_DIR}"

if [[ $# -gt 0 ]]; then
  printf '%s\n' 'The --guard overlay is retired. Run historical measurements from that commit’s complete archive.' >&2
  exit 2
fi

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
NPM_SANDBOX_NAME=unread-scripts
NPM_SANDBOX_SCRIPT_RE='inert-unread-scripts\.sh'
# shellcheck source=../test/lib/npm-sandbox.sh
source "${ROOT_DIR}/scripts/test/lib/npm-sandbox.sh"
# The sandbox's rows are outcomes here, not assertions: a command sent with no
# flag runs, and its marks are counted.
NPM_SANDBOX_TOLERANT=true

count_install_marks() { INSTALL_MARKS=$(grep -c '^sd-approved' "${MARKS}" || true); }
printf 'host\t%s\nload\t%s\n' "$(uname -sm)" "$(uptime | sed 's/.*averages*: //')"
for row in \
  'true; sh -c "npm install sd-approved@1.0.0 \"--loglevel=warn\""|sh' \
  'eval "npm install sd-approved@1.0.0 \"--loglevel=warn\""|sh' \
  'true; bash -c "npm install sd-approved@1.0.0 $(printf -- --loglevel=warn)"|bash' \
  'true; dash -c "npm install sd-approved@1.0.0 `printf -- --loglevel=warn`"|dash' \
  "true; ksh -c 'npm install sd-approved@1.0.0'|ksh" \
  $'npm install sd-approved@1.0.0 && cat <<E | wc -l\nnpm install sd-approved@1.0.0\nE|sh'
do
  form="${row%|*}" needs="${row##*|}"
  if ! command -v "${needs}" > /dev/null 2>&1; then
    printf 'skipped\t-\t-\t%s\n' "$(printf '%q' "${form}")"
    continue
  fi
  new_project
  : > "${MARKS}"
  INSTALL_MARKS=""
  run_install "${form}" claude count_install_marks
  rewritten=yes
  [[ "${CASE_EXEC}" != "${form}" ]] || rewritten=no
  [[ -z "${CASE_PRE_DENY}" ]] || rewritten=denied
  printf '%s\t%s\t%s\t%s\n' "${rewritten}" "${INSTALL_MARKS:-0}" "$(grep -c '^sd-approved' <<< "${CASE_RAN}" || true)" "$(printf '%q' "${form}")"
done
npm_sandbox_registry_was_local
