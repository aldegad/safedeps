#!/usr/bin/env bash
# safedeps: how `npm link` reads each of its arguments, asked of npm's own
# argument parser.
#
# npm link reads every argument with npm-package-arg (npa) and installs the
# ones the global tree does not have into the global prefix
# (lib/commands/link.js:92-104). A directory or a file -- npa types directory
# and file -- is linked as written; every other argument (range, version, tag,
# alias, git, remote) is fetched and installed. The gate reads the same split
# twice: lib/install-grammar.sh recognizes a link as an install by the shape of
# a word npm fetches (SAFEDEPS_G_NPM_REGISTRY_OPERAND or
# SAFEDEPS_G_NPM_REMOTE_OPERAND, regexes over the scan view), and the operand
# walk asks safedeps_npa_is_local of each argument.
#
# This runs npa from the npm on PATH over a set of argument words and compares:
#   - safedeps_npa_is_local must agree with npa on every word;
#   - `npm link ../lib <word>` must be recognized as an install for every word
#     npa does not read as local. It may also be recognized for a bare tarball
#     name (`x.tgz`), the one file shape the regex cannot tell from a name
#     (stated in lib/install-grammar.sh); any other extra is a failure.
# A word npa rejects (it throws) makes npm link fail before it installs
# anything, so either answer is accepted for it.
#
# Usage: scripts/measure/npm-link-operands.sh [--print]
# Exit: 0 agree, 1 a disagreement, 2 no npm to ask, 3 this npm's npa cannot be
#       loaded (skipped).
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
command -v npm >/dev/null 2>&1 && command -v node >/dev/null 2>&1 \
  || { echo "npm and node are not on PATH; nothing to measure" >&2; exit 2; }
npm_root=$(cd "$(dirname "$(readlink -f "$(command -v npm)" 2>/dev/null || command -v npm)")/.." && pwd)
version=$(npm --version)

words=(
  ../lib ./lib /tmp/x '~/lib' file:lib lib/ . .. 'C:\x' user/repo github:u/r
  https://example.test/x.tgz x.tgz x.tar x.tar.gz FOO.TGZ
  git@github.com:u/r.git git+https://github.com/u/r.git gist:abc
  evil@1.0.0 lib foo left-pad 7zip-bin @s/x @s/x@1.0.0 @scope
  foo@latest 'foo@^1.0.0' 'foo@~1.2.3' 'foo@*' foo@ foo@1.0.0-beta.1 'foo@>=1.0.0'
  foo@npm:bar@1.0.0 npm:evil@1.0.0 foo@npm:@s/x@1
  foo@file:../x foo@../x foo@./x foo@/x 'foo@~/x' foo@github:u/r foo@u/r
  foo@https://example.test/x.tgz foo@x.tgz foo@gist:abc 'foo@C:x'
)

measured=$(cd "${ROOT_DIR}" && node -e '
let npa
try {
  npa = require(require.resolve("npm-package-arg", { paths: [process.argv[1]] }))
} catch (e) { process.exit(3) }
for (const w of process.argv.slice(2)) {
  let type
  try { type = npa(w).type } catch (e) { type = "error" }
  console.log(w + "\t" + type)
}
' "${npm_root}" "${words[@]}") || {
  rc=$?
  if [[ "${rc}" == 3 ]]; then
    printf 'skipped: npm %s: npm-package-arg could not be loaded from %s\n' "${version}" "${npm_root}"
    exit 3
  fi
  printf 'could not run npm %s npm-package-arg (node exited %s)\n' "${version}" "${rc}" >&2
  exit 2
}

if [[ "${1:-}" == --print ]]; then
  printf 'npm %s\n%s\n' "${version}" "${measured}"
  exit 0
fi

# shellcheck source=../../lib/install-grammar.sh
. "${ROOT_DIR}/lib/install-grammar.sh"
rc=0
while IFS=$'\t' read -r word type; do
  [[ "${type}" == error ]] && continue
  case "${type}" in
    directory|file) registry=false ;;
    *) registry=true ;;
  esac
  if safedeps_npa_is_local "${word}"; then said=false; else said=true; fi
  if [[ "${said}" != "${registry}" ]]; then
    printf 'npm %s reads %s as %s; safedeps_npa_is_local says local=%s\n' "${version}" "${word}" "${type}" "$([[ "${said}" == true ]] && echo false || echo true)"
    rc=1
  fi
  if printf '%s\n' "npm link ../lib ${word}" | grep -qE "${SAFEDEPS_G_NPM_INSTALL_RE}"; then seen=true; else seen=false; fi
  if [[ "${registry}" == true && "${seen}" != true ]]; then
    printf 'npm %s installs %s (%s) from npm link, and the grammar does not read it as an install\n' "${version}" "${word}" "${type}"
    rc=1
  fi
  if [[ "${registry}" != true && "${seen}" == true && ! "${word}" =~ ${SAFEDEPS_G_NPA_TARBALL_RE} ]]; then
    printf 'npm %s links %s (%s) as written, and the grammar reads it as an install\n' "${version}" "${word}" "${type}"
    rc=1
  fi
done <<< "${measured}"
[[ "${rc}" == 0 ]] && printf 'npm %s: npm link arguments are read the way npm-package-arg reads them (%s words)\n' "${version}" "${#words[@]}"
exit "${rc}"
