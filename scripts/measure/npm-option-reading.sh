#!/usr/bin/env bash
# safedeps: npm's option reading, asked of npm's own parser.
#
# npm reads its arguments with nopt and the option types in
# @npmcli/config/lib/definitions. Which word is the command, and which words
# are option values, follows from those types: `npm --prefix x install` is an
# install into x, and `npm --silent x` runs `npm exec`. The install grammar's
# regexes cannot know a type, so they tried both readings, and where both
# matched they picked one; for `npm --prefix x install evil@1.0.0` they picked
# `npm x`, and the install went unchecked.
#
# lib/install-grammar.sh now reads the words the way nopt does
# (safedeps_npm_read_args), with npm's table copied into it. This checks both
# halves against the npm on PATH:
#
#   1. the table: every option's class and every shorthand, derived from npm's
#      definitions, equals the grammar's;
#   2. the reading: for a corpus of argument lists built from every option,
#      every shorthand, unique abbreviations, `=` values, `--no-`, dash runs and
#      the words nopt treats specially (`true`, `false`, `null`, `always`, an
#      empty word), the positional words this reading finds are the words nopt
#      leaves in argv.remain, in order.
#
# Usage: scripts/measure/npm-option-reading.sh [--print]
#   --print   print the table measured from npm, in the grammar's form
# Exit: 0 both agree, 1 a disagreement (printed), 2 no npm to ask,
#       3 this npm keeps its config definitions elsewhere (skipped).
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
command -v npm >/dev/null 2>&1 || { echo "npm is not on PATH; nothing to measure" >&2; exit 2; }
command -v node >/dev/null 2>&1 || { echo "node is not on PATH; nothing to measure" >&2; exit 2; }
npm_root=$(cd "$(dirname "$(readlink -f "$(command -v npm)" 2>/dev/null || command -v npm)")/.." && pwd)
version=$(npm --version)
skipped=3

work=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-npm-options.XXXXXX")
trap 'rm -rf "${work}"' EXIT

# The table and the corpus, from npm's own modules. nopt and the definitions
# are resolved from npm's install, so a distribution that unbundles npm's
# dependencies finds the copies npm uses.
if ! (cd "${npm_root}" && node -e '
const path = require("path")
const fs = require("fs")
const from = { paths: [path.resolve(".")] }
let defs, nopt
try {
  defs = require(require.resolve("@npmcli/config/lib/definitions", from))
  nopt = require(require.resolve("nopt", from))
} catch (e) { process.exit(3) }
const { definitions, shorthands } = defs
if (!definitions || !shorthands) process.exit(3)
const cls = (t) => {
  const a = Array.isArray(t) && t.length === 1 ? t[0] : t
  if (Array.isArray(a)) {
    let x = ""
    if (a.includes(null)) x += "n"
    if (a.includes(Number)) x += "N"
    if (a.includes(String)) x += "S"
    const lits = a.filter(e => typeof e === "string")
    const extra = x + (lits.length ? "=" + lits.join(",") : "")
    if (a.includes(Boolean)) return "b+" + extra
    return extra ? "v+" + extra : "v"
  }
  return a === Boolean ? "b" : a === String ? "s" : "v"
}
const types = {}
for (const [k, d] of Object.entries(definitions)) types[k] = d.type
// local-address lists the addresses of the machine npm runs on, which a table
// cannot carry; the grammar writes `@host` for them and reads no word as one.
const klass = k => k === "local-address" ? cls(types[k]).replace(/=.*/, "=@host") : cls(types[k])
const out = process.argv[1]
fs.writeFileSync(out + "/options", Object.keys(types).sort().map(k => k + ":" + klass(k)).join("\n") + "\n")
fs.writeFileSync(out + "/shorthands", Object.keys(shorthands).sort().map(k => k + "=" + [].concat(shorthands[k]).join(",")).join("\n") + "\n")

// The corpus. Each list ends in two positionals, so a reading that eats one
// too many or too few words shows.
const keys = Object.keys(types)
const shorts = Object.keys(shorthands)
const lists = []
const add = (...a) => lists.push([...a, "cmd", "arg"])
// The words nopt treats apart after an option: a value, the two booleans,
// a word that looks like an option, a dash run, the empty word.
for (const k of keys) {
  for (const x of ["x", "true", "null", "always", "-y", "--y", "--", ""]) add("--" + k, x)
  for (const x of ["x", "5", "0x1f", " ", "null", "-y", "--5"]) add("--no-" + k, x)
  const t = Array.isArray(types[k]) ? types[k] : []
  const lit = t.find(e => typeof e === "string" && e)
  if (lit && k !== "local-address") { add("--no-" + k, lit); add("--" + k, lit) }
  add("-" + k, "x")
  add("--" + k + "=x")
  add("--" + k + "=")
  add("--" + k + "=-y")
  // The shortest prefix that names only this option, and the one before it.
  let n = 1
  while (n < k.length && keys.filter(o => o.startsWith(k.slice(0, n))).length > 1) n++
  add("--" + k.slice(0, n), "x")
  if (n > 1) add("--" + k.slice(0, n - 1), "x")
}
for (const s of shorts) {
  add("-" + s, "x")
  add("--" + s, "x")
  add("-" + s + "=x")
}
const singles = ["g", "C", "s", "y", "L", "w", "d", "n"]
for (const a of singles) for (const b of singles) add("-" + a + b, "x")
for (const w of ["--", "---", "-", "--=x", "-=x", "--No-global", "--NO-yes", "x", "-ws", "-iwr", "-dd", "-gws", "-sdC", "--pref", "--prefi"]) add(w, "x")
add("--prefix", "x", "--silent", "--loglevel", "error", "--", "--yes")
add("--yes", "false", "--cache", "-y", "--browser", "--x")
add("--color", "always", "--global=install", "x")
const rows = lists.map(a => {
  const r = nopt(types, shorthands, ["node", "npm", ...a], 2)
  return a.join("\u001f") + "\u001e" + r.argv.remain.join("\u001f")
})
fs.writeFileSync(out + "/corpus", rows.join("\n") + "\n")
' "${work}"); then
  rc=$?
  if [[ "${rc}" == "${skipped}" ]]; then
    printf 'skipped: npm %s keeps no @npmcli/config/lib/definitions or nopt where this looks\n' "${version}"
    exit "${skipped}"
  fi
  printf 'could not ask npm %s option parser (node exited %s)\n' "${version}" "${rc}" >&2
  exit 2
fi

if [[ "${1:-}" == --print ]]; then
  printf 'npm %s\n' "${version}"
  printf '%s\n' "options:" && cat "${work}/options"
  printf '%s\n' "shorthands:" && cat "${work}/shorthands"
  exit 0
fi

# shellcheck source=../../lib/install-grammar.sh
. "${ROOT_DIR}/lib/install-grammar.sh"

rc=0
# 1. The table.
have_options=$(printf '%s\n' ${SAFEDEPS_G_NPM_OPTIONS} | sort)
have_shorthands=$(set -f; printf '%s\n' ${SAFEDEPS_G_NPM_SHORTHANDS} | sort)
if ! diff <(printf '%s\n' "${have_options}") <(sort "${work}/options") > "${work}/diff.options"; then
  printf 'npm %s option classes differ from lib/install-grammar.sh (< grammar, > npm):\n' "${version}"
  cat "${work}/diff.options"
  rc=1
fi
if ! diff <(printf '%s\n' "${have_shorthands}") <(sort "${work}/shorthands") > "${work}/diff.shorthands"; then
  printf 'npm %s shorthands differ from lib/install-grammar.sh (< grammar, > npm):\n' "${version}"
  cat "${work}/diff.shorthands"
  rc=1
fi

# 2. The reading.
total=0 wrong=0
while IFS=$'\036' read -r args want; do
  total=$((total + 1))
  # Split on \037 alone, with globbing off: a word may be empty or `?`.
  set -f
  IFS=$'\037'
  # shellcheck disable=SC2206
  words=( ${args} )
  unset IFS
  set +f
  got=""
  # `--no-local-address <word>` takes the word when it is one of this
  # machine's addresses; the reading says it cannot tell.
  if [[ "${args}" == --no-local-address$'\037'* ]]; then
    total=$((total - 1))
    continue
  fi
  if safedeps_npm_read_args "${words[@]}"; then
    got=$(IFS=$'\037'; printf '%s' "${SAFEDEPS_G_NPM_WORDS[*]+"${SAFEDEPS_G_NPM_WORDS[*]}"}")
  else
    got="<no reading>"
  fi
  if [[ "${got}" != "${want}" ]]; then
    wrong=$((wrong + 1))
    if (( wrong <= 40 )); then
      printf 'npm %s reads [%s] as [%s]; this reading has [%s]\n' "${version}" \
        "${args//$'\037'/ }" "${want//$'\037'/ }" "${got//$'\037'/ }"
    fi
  fi
done < "${work}/corpus"
if (( wrong > 0 )); then
  printf '%s of %s argument lists read differently from npm %s\n' "${wrong}" "${total}" "${version}"
  rc=1
fi
if (( rc == 0 )); then
  printf 'npm %s: %s option classes, %s shorthands and %s argument lists agree\n' "${version}" \
    "$(wc -l < "${work}/options" | tr -d ' ')" "$(wc -l < "${work}/shorthands" | tr -d ' ')" "${total}"
fi
exit "${rc}"
