#!/usr/bin/env bash
# safedeps: the census of what the CLI hands a command as an argument.
#
#   scripts/test/argv-census.sh
#
# A command's arguments have a limit the system sets, and a file or a ledger
# has none, so a file's contents reach a command through a file, standard
# input or a pipe. scripts/test/argv-census.tsv names every jq value argument
# in bin/safedeps, lib/*.sh and lib/*/*.sh, and every other place the census
# found, with its class and why; scripts/test/lib/argv-census.py reads both
# and says where they differ. The first row holds this tree to the table. The
# controls show that each direction can fail: a copy of the tree with a site
# the table does not name, the table without a row the tree holds, and the
# table with a row the tree does not hold.
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
census="${ROOT_DIR}/scripts/test/lib/argv-census.py"
table="${ROOT_DIR}/scripts/test/argv-census.tsv"
failures=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1"; failures=$((failures + 1)); }

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-argv-census.XXXXXX") || exit 2
trap 'rm -rf "${tmp_root}"' EXIT

# This tree against its table: the census's own lines, then its verdict.
if python3 "${census}" check --root "${ROOT_DIR}" --table "${table}"; then
  pass "this tree matches the census table"
else
  fail "this tree matches the census table"
fi

# control ROW EXPECTED ROOT TABLE: the check fails, and says EXPECTED.
control() {
  local name="$1" expected="$2" rc=0
  python3 "${census}" check --root "$3" --table "$4" > "${tmp_root}/control.out" 2>&1 || rc=$?
  if [[ "${rc}" -eq 1 ]] && grep -qF -- "${expected}" "${tmp_root}/control.out"; then
    pass "control: ${name}"
  else
    fail "control: ${name}: the check exited ${rc} and said: $(tr '\n' ' ' < "${tmp_root}/control.out")"
  fi
}

# A copy of the tree's scope with one jq value argument the table does not name.
tree="${tmp_root}/tree"
mkdir -p "${tree}/bin"
cp "${ROOT_DIR}/bin/safedeps" "${tree}/bin/safedeps"
cp -R "${ROOT_DIR}/lib" "${tree}/lib"
printf '%s\n' 'jq -n --argjson entries "${ledger_json}" '"'"'$entries'"'"'' >> "${tree}/lib/gates/audit.sh"
control "a jq value argument the table does not name is a mismatch" \
  'lib/gates/audit.sh: --argjson entries "${ledger_json}" appears 1 time(s), and the table does not name it' "${tree}" "${table}"

# The table without the row of a form the tree holds.
grep -vF -- '--argjson counts "$counts"' "${table}" > "${tmp_root}/without.tsv"
control "a form the tree holds and the table does not is a mismatch" \
  'lib/gates/audit.sh: --argjson counts "$counts" appears 1 time(s), and the table does not name it' "${ROOT_DIR}" "${tmp_root}/without.tsv"

# The table with a row the tree does not hold, and a site that moved.
{ cat "${table}"; printf 'jq\tlib/gates/audit.sh\t1\tbounded\t--argjson gone "${gone}"\ta control\n'; } > "${tmp_root}/extra.tsv"
control "a row the tree does not hold is a mismatch" \
  'lib/gates/audit.sh: --argjson gone "${gone}" is named 1 time(s), and the code has none' "${ROOT_DIR}" "${tmp_root}/extra.tsv"
awk -F '\t' -v OFS='\t' '$1 == "site" && $2 == "lib/watch/lockfiles.sh" && index($5, "--slurpfile sources") == 1 { $3 = 2 } { print }' \
  "${table}" > "${tmp_root}/moved.tsv"
control "a site whose count moved is a mismatch" \
  'holds --slurpfile sources "${sources}" 1 time(s), and the table says 2' "${ROOT_DIR}" "${tmp_root}/moved.tsv"

if (( failures > 0 )); then
  printf '# %d row(s) failed\n' "${failures}"
  exit 1
fi
