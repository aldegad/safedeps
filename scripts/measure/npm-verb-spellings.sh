#!/usr/bin/env bash
# safedeps: every spelling npm accepts for the commands the install grammar
# names, asked of npm's own command parser.
#
# npm does not read its command word from a fixed list. lib/utils/cmd-list.js
# `deref` turns a camelCase word into dashed form (`installTest` is
# `install-test`), takes an exact command or a documented alias, and otherwise
# takes any unique abbreviation of a command or an alias (`npm upd`, `npm cre`,
# `npm lin`). A grammar copied from the documented aliases missed every
# abbreviation, so `npm cr vite` fetched and ran create-vite with no judgment.
#
# This prints, for the npm on PATH, the spellings deref maps to each command,
# in the form lib/install-grammar.sh writes them, and compares them with the
# grammar. A dash before a letter is written `-?[xX]`, because deref also
# accepts the camelCase form of every dashed spelling. Exit 1 when npm accepts a
# spelling the grammar does not have.
#
# Usage: scripts/measure/npm-verb-spellings.sh [--print]
#   --print   print the measured lists without comparing
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
command -v npm >/dev/null 2>&1 || { echo "npm is not on PATH; nothing to measure" >&2; exit 2; }
npm_root=$(cd "$(dirname "$(readlink -f "$(command -v npm)" 2>/dev/null || command -v npm)")/.." && pwd)
[[ -f "${npm_root}/lib/utils/cmd-list.js" ]] || { echo "cannot find npm's lib/utils/cmd-list.js under ${npm_root}" >&2; exit 2; }

measured=$(cd "${npm_root}" && node -e '
const { deref, commands, aliases } = require("./lib/utils/cmd-list.js")
// abbrev is resolved from cmd-list.js itself, so a distribution that unbundles
// the dependencies of npm finds the copy npm uses.
const abbrev = require(require.resolve("abbrev", { paths: [require("path").resolve("lib/utils")] }))
const words = new Set([...Object.keys(abbrev(commands.concat(Object.keys(aliases)))), ...commands, ...Object.keys(aliases)])
const groups = {
  INSTALL: ["install", "ci", "install-test", "install-ci-test", "update"],
  EXEC: ["exec"],
  INIT: ["init"],
  LINK: ["link"],
}
const write = w => w.replace(/-([a-z])/g, (m, c) => "-?[" + c + c.toUpperCase() + "]")
for (const [name, targets] of Object.entries(groups)) {
  const found = [...words].filter(w => targets.includes(deref(w))).sort()
  console.log(name + "=" + found.map(write).join("|"))
}
')
version=$(npm --version)

if [[ "${1:-}" == --print ]]; then
  printf 'npm %s\n%s\n' "${version}" "${measured}"
  exit 0
fi

# shellcheck source=../../lib/install-grammar.sh
. "${ROOT_DIR}/lib/install-grammar.sh"
rc=0
while IFS='=' read -r name want; do
  case "${name}" in
    INSTALL) have="${SAFEDEPS_G_NPM_VERBS}" ;;
    EXEC) have="${SAFEDEPS_G_NPM_EXEC_VERBS}" ;;
    INIT) have="${SAFEDEPS_G_NPM_INIT_VERBS}" ;;
    LINK) have="${SAFEDEPS_G_NPM_LINK_VERBS}" ;;
  esac
  missing=$(comm -13 <(tr '|' '\n' <<< "${have}" | sort) <(tr '|' '\n' <<< "${want}" | sort))
  extra=$(comm -23 <(tr '|' '\n' <<< "${have}" | sort) <(tr '|' '\n' <<< "${want}" | sort))
  if [[ -n "${missing}" ]]; then
    printf 'npm %s accepts %s spellings lib/install-grammar.sh does not have:\n%s\n' \
      "${version}" "${name}" "$(sed 's/^/  /' <<< "${missing}")"
    rc=1
  fi
  # A spelling this npm does not accept may be one an older or newer npm does
  # (a command added or removed changes which abbreviations are unique). It
  # can only add a judgment of a command that fails, so it is reported, not
  # failed.
  if [[ -n "${extra}" ]]; then
    printf 'npm %s does not accept these %s spellings the grammar has (kept: another npm may):\n%s\n' \
      "${version}" "${name}" "$(sed 's/^/  /' <<< "${extra}")"
  fi
done <<< "${measured}"
[[ "${rc}" == 0 ]] && printf 'npm %s: every spelling deref accepts is in the grammar\n' "${version}"
exit "${rc}"
