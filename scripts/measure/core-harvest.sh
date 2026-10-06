#!/usr/bin/env bash
# safedeps: the commands the batteries judge, as a corpus for the core.
#
# consumer-forms.sh and manager-variants.sh hold their commands in shell code,
# so no corpus file lists them. This runs those batteries in a copy of the
# tree whose guard is a recorder: it writes the command of each payload it is
# handed and then runs the real guard on it, so the battery reads the answers
# it always read. What is left is every command the batteries put to the gate,
# one JSON string per line, for core-facts-differential.py --commands.
#
# The recorder lets two guards run at a time, whatever the battery starts: a
# shared test host takes two (consumer-forms starts eight in one of its
# loops). A slot whose holder is gone is taken back.
#
# The copy is a measurement. Nothing here is shipped, and the tree it was made
# from is not touched.
#
# Usage: scripts/measure/core-harvest.sh <dest-dir> <out.jsonl> <battery.sh>...
set -uo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
DEST="${1:?usage: core-harvest.sh <dest-dir> <out.jsonl> <battery.sh>...}"
OUT="${2:?usage: core-harvest.sh <dest-dir> <out.jsonl> <battery.sh>...}"
shift 2
(( $# > 0 )) || { printf 'core-harvest: name at least one battery\n' >&2; exit 2; }
[[ ! -e "${DEST}" ]] || { printf 'core-harvest: %s exists\n' "${DEST}" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { printf 'core-harvest: jq is required\n' >&2; exit 2; }

mkdir -p "${DEST}"
DEST=$(cd "${DEST}" && pwd)
( cd "${ROOT_DIR}" && COPYFILE_DISABLE=1 tar --exclude=./rust/target --exclude=./.git --exclude=./safedeps-core -cf - . ) | tar -C "${DEST}" -xf - 2>/dev/null \
  || { printf 'core-harvest: could not copy the tree\n' >&2; exit 2; }
mv "${DEST}/scripts/safedeps-pre-guard.sh" "${DEST}/scripts/safedeps-pre-guard.real.sh"
cat > "${DEST}/scripts/safedeps-pre-guard.sh" <<'RECORDER'
#!/usr/bin/env bash
# core-harvest's recorder: the command of this payload, then the real guard.
input=$(cat)
dir="${SAFEDEPS_CORE_HARVEST_DIR:-}"
got=""
if [[ -n "${dir}" ]]; then
  one=$(mktemp "${dir}/cmd.XXXXXX" 2>/dev/null) \
    && printf '%s' "${input}" | jq -c '.tool_input.command // empty' > "${one}" 2>/dev/null
  while [[ -z "${got}" ]]; do
    for s in 1 2; do
      if mkdir "${dir}/slot${s}" 2>/dev/null; then
        printf '%s\n' "$$" > "${dir}/slot${s}/pid"
        got="${s}"
        break
      fi
      holder=$(cat "${dir}/slot${s}/pid" 2>/dev/null) || holder=""
      if [[ -n "${holder}" ]] && ! kill -0 "${holder}" 2>/dev/null; then
        rm -rf "${dir}/slot${s}"
      fi
    done
    [[ -n "${got}" ]] || sleep 0.05
  done
  trap 'rm -rf "${dir}/slot${got}"' EXIT
fi
printf '%s' "${input}" | bash "${BASH_SOURCE[0]%/*}/safedeps-pre-guard.real.sh" "$@"
rc=$?
exit "${rc}"
RECORDER
chmod 755 "${DEST}/scripts/safedeps-pre-guard.sh"

harvest=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-core-harvest.XXXXXX")
trap 'rm -rf "${harvest}"' EXIT
export SAFEDEPS_CORE_HARVEST_DIR="${harvest}"
export SAFEDEPS_TEST_JOBS=2
printf 'start: %s\n' "$(uptime)"
status=0
for battery in "$@"; do
  started=$(date +%s)
  log="${DEST}/harvest-$(basename "${battery}" .sh).log"
  ( cd "${DEST}" && bash "${battery}" > "${log}" 2>&1 )
  rc=$?
  printf '%s: exit %s, %s ok, %s not ok, %ss\n' "${battery}" "${rc}" \
    "$(grep -c '^ok' "${log}" || true)" "$(grep -c '^not ok' "${log}" || true)" "$(( $(date +%s) - started ))"
  (( rc == 0 )) || status=1
done
find "${harvest}" -name 'cmd.*' -type f -exec cat {} + | sort -u > "${OUT}"
printf 'harvested %s distinct commands into %s\n' "$(wc -l < "${OUT}" | tr -d ' ')" "${OUT}"
printf 'end: %s\n' "$(uptime)"
exit "${status}"
