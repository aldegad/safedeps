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
# The core's manager reader (rust/src/manager.rs) reads the words the way nopt
# does, with npm's table copied into rust/src/tables.rs. This checks both
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
# The table is the source of truth, and it is one npm's
# (SAFEDEPS_G_NPM_OPTIONS_FROM). Against that npm version any difference
# fails. Against npm 10.8.2 (SAFEDEPS_G_NPM_OTHER_FROM), whose differences are
# tabled and read as a second reading, the differences must be exactly that
# table and the reading through it must agree with nopt everywhere. Against
# any other version, options that npm defines differently from
# the table (added, dropped, retyped; shorthands likewise) are expected to
# read differently, so they are named, and every argument list read
# differently is attributed to one of them: when all are, the run is a skip
# that names them, the boundary of the gate for that npm; when one is not, the
# reading itself is wrong for an option both versions agree on, and the run
# fails. Neither a quiet pass nor an unexplained red.
#
# Usage: scripts/measure/npm-option-reading.sh [--print]
#   --print   print the table measured from npm, in the grammar's form
# Exit: 0 both agree, 1 a disagreement (printed), 2 no npm to ask,
#       3 skipped: this npm keeps its config definitions elsewhere, or it is
#         an untabled version that reads only the named options differently.
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
node_rc=0
(cd "${npm_root}" && node -e '
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
// An option npm does not define is a Boolean to nopt, so the word after it is
// the command: `npm --foo x exec evil@1.0.0` runs `npm x`, which is exec.
add("--foo", "x", "exec", "evil@1.0.0")
const rows = lists.map(a => {
  const r = nopt(types, shorthands, ["node", "npm", ...a], 2)
  return a.join("\u001f") + "\u001e" + r.argv.remain.join("\u001f")
})
fs.writeFileSync(out + "/corpus", rows.join("\n") + "\n")
' "${work}") || node_rc=$?
if (( node_rc != 0 )); then
  if [[ "${node_rc}" == "${skipped}" ]]; then
    printf 'skipped: npm %s keeps no @npmcli/config/lib/definitions or nopt where this looks\n' "${version}"
    exit "${skipped}"
  fi
  printf 'could not ask npm %s option parser (node exited %s)\n' "${version}" "${node_rc}" >&2
  exit 2
fi

if [[ "${1:-}" == --print ]]; then
  printf 'npm %s\n' "${version}"
  printf '%s\n' "options:" && cat "${work}/options"
  printf '%s\n' "shorthands:" && cat "${work}/shorthands"
  exit 0
fi

source "${ROOT_DIR}/scripts/test/lib/native-measure-core.sh"
measure_grammar

rc=0
same_version=false
[[ "${version}" == "${SAFEDEPS_G_NPM_OPTIONS_FROM}" ]] && same_version=true
# The other npm the grammar reads as well (SAFEDEPS_G_NPM_OTHER_FROM): its
# differences are tabled, so against it the reading through that table must
# agree with nopt everywhere, and the table must be exactly its differences.
other_version=false
[[ "${version}" == "${SAFEDEPS_G_NPM_OTHER_FROM}" ]] && other_version=true
# 1. The table. The names whose entry differs, on either side, are the ones
# another npm version may read differently.
have_options=$(set -f; printf '%s\n' ${SAFEDEPS_G_NPM_OPTIONS} | sort)
have_shorthands=$(set -f; printf '%s\n' ${SAFEDEPS_G_NPM_SHORTHANDS} | sort)
comm -3 <(printf '%s\n' "${have_options}") <(sort "${work}/options") \
  | sed -E 's/^[[:space:]]+//; s/:.*//' | sort -u > "${work}/differ.options"
comm -3 <(printf '%s\n' "${have_shorthands}") <(sort "${work}/shorthands") \
  | sed -E 's/^[[:space:]]+//; s/=.*//' | sort -u > "${work}/differ.shorthands"
if [[ -s "${work}/differ.options" || -s "${work}/differ.shorthands" ]] && [[ "${same_version}" == true ]]; then
  printf 'npm %s, the version the table is from, defines these differently from lib/install-grammar.sh: %s\n' \
    "${version}" "$(cat "${work}/differ.options" "${work}/differ.shorthands" | paste -sd ' ' -)"
  rc=1
fi

if [[ "${other_version}" == true ]]; then
  want_other=$(
    while IFS= read -r key; do
      entry=$(grep -E "^${key//./[.]}:" "${work}/options" || true)
      printf '%s\n' "${entry:-${key}:-}"
    done < "${work}/differ.options" | sort)
  have_other=$(set -f; printf '%s\n' ${SAFEDEPS_G_NPM_OTHER} | sort)
  if [[ "${want_other}" != "${have_other}" || -s "${work}/differ.shorthands" ]]; then
    printf 'npm %s differs from the table otherwise than SAFEDEPS_G_NPM_OTHER says: want [%s], have [%s], shorthands [%s]\n' \
      "${version}" "$(paste -sd ' ' - <<< "${want_other}")" "$(paste -sd ' ' - <<< "${have_other}")" \
      "$(paste -sd ' ' - < "${work}/differ.shorthands")"
    rc=1
  fi
fi

# 2. The reading. A list read differently is explained when one of its option
# words names, abbreviates or bundles a name whose entry differs.
differ_names=" $(cat "${work}/differ.options" "${work}/differ.shorthands" | paste -sd ' ' -) "
explained_by() {
  local word name s
  for word in "$@"; do
    [[ "${word}" == -?* ]] || continue
    s="${word%%=*}"
    while [[ "${s}" == -* ]]; do s="${s#-}"; done
    while [[ "${s:0:3}" == [Nn][Oo]- ]]; do s="${s:3}"; done
    [[ -n "${s}" ]] || continue
    for name in ${differ_names}; do
      [[ "${name}" == "${s}"* ]] && { printf '%s' "${name}"; return 0; }
      # A bundle of one-character shorthands (`-gC`).
      [[ ${#name} -eq 1 && "${word}" != --* && "${s}" == *"${name}"* ]] && { printf '%s' "${name}"; return 0; }
    done
  done
  return 1
}
reader_table=plain
[[ "${other_version}" != true ]] || reader_table=other
python3 "${ROOT_DIR}/scripts/measure/native-manager-corpus.py" --core "${MEASURE_CORE}" \
  --table "${reader_table}" --corpus "${work}/corpus" --out "${work}/native-readings"
exec 3< "${work}/native-readings"
total=0 wrong=0 boundary=0
while IFS=$'\036' read -r args want; do
  total=$((total + 1))
  # Split on \037 alone, with globbing off: a word may be empty or `?`.
  set -f
  IFS=$'\037'
  # shellcheck disable=SC2206
  words=( ${args} )
  unset IFS
  set +f
  IFS= read -r got <&3 || { printf 'native reader omitted a corpus row\n' >&2; exit 2; }
  # `--no-local-address <word>` takes the word when it is one of this
  # machine's addresses; the reading says it cannot tell.
  if [[ "${args}" == --no-local-address$'\037'* ]]; then
    total=$((total - 1))
    continue
  fi
  if [[ "${got}" != "${want}" ]]; then
    if [[ "${same_version}" != true && "${other_version}" != true ]] && explained_by "${words[@]}" > /dev/null; then
      boundary=$((boundary + 1))
      continue
    fi
    wrong=$((wrong + 1))
    if (( wrong <= 40 )); then
      printf 'npm %s reads [%s] as [%s]; this reading has [%s]\n' "${version}" \
        "${args//$'\037'/ }" "${want//$'\037'/ }" "${got//$'\037'/ }"
    fi
  fi
done < "${work}/corpus"
exec 3<&-
if (( wrong > 0 )); then
  printf '%s of %s argument lists read differently from npm %s\n' "${wrong}" "${total}" "${version}"
  rc=1
fi
if (( rc == 0 )) && [[ "${same_version}" != true && "${other_version}" != true ]] \
    && [[ -s "${work}/differ.options" || -s "${work}/differ.shorthands" ]]; then
  printf 'skipped: npm %s is not npm %s, which the table is from; it defines these differently: %s; %s of %s argument lists read differently, each through one of them, and the rest agree\n' \
    "${version}" "${SAFEDEPS_G_NPM_OPTIONS_FROM}" \
    "$(cat "${work}/differ.options" "${work}/differ.shorthands" | paste -sd ' ' -)" "${boundary}" "${total}"
  exit "${skipped}"
fi
if (( rc == 0 )) && [[ "${other_version}" == true ]]; then
  printf 'npm %s: read through the table of its differences (SAFEDEPS_G_NPM_OTHER, %s options), %s argument lists agree\n' \
    "${version}" "$(wc -l < "${work}/differ.options" | tr -d ' ')" "${total}"
  exit 0
fi
if (( rc == 0 )); then
  printf 'npm %s: %s option classes, %s shorthands and %s argument lists agree\n' "${version}" \
    "$(wc -l < "${work}/options" | tr -d ' ')" "$(wc -l < "${work}/shorthands" | tr -d ' ')" "${total}"
fi
exit "${rc}"
