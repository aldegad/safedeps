#!/usr/bin/env bash
# safedeps: measure the argument words real shells hand to a package manager.
#
# The spec extractor reads a statement's words from the lexer's pieces view:
# redirections taken out and the shell's quote removal applied (the pieces view
# of rust/src/lex.rs). scripts/test/scan-contract.sh checks that view
# against the argv recorded in scripts/measure/word-reading-forms.json. Those
# argv are measurements, and this script is how they are re-measured.
#
# Each form starts with @@M@@, the manager. Here it becomes a shell function
# that prints its arguments, and the form runs in a throwaway directory under
# each shell, so a redirection in it writes there. Nothing in a form installs
# anything: the battery puts `pip` where the marker is, but it only hands the
# text to the lexer and never runs it.
#
# Usage:
#   scripts/measure/word-reading-measure.sh            compare with the record
#   scripts/measure/word-reading-measure.sh --record   print the corpus with
#                                                      freshly measured argv
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
FORMS="${ROOT_DIR}/scripts/measure/word-reading-forms.json"
RECORD=false
[[ "${1:-}" == "--record" ]] && RECORD=true

work=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-word-reading.XXXXXX")
trap 'rm -rf "${work}"' EXIT

# The arguments go to a file of their own, NUL-separated: a form may redirect
# the stand-in's output, which is the point of several of them.
stand_in='argv() { for a in "$@"; do printf "%s\0" "$a"; done >> "${ARGV_FILE}"; }'

argv_in() { # shell file -> JSON array of the arguments the stand-in received
  local shell="$1" file="$2" dir
  dir=$(mktemp -d "${work}/cwd.XXXXXX")
  : > "${dir}.argv"
  ( cd "${dir}" && ARGV_FILE="${dir}.argv" "/bin/${shell}" -c "${stand_in}
$(cat "${file}")" >/dev/null 2>&1 </dev/null )
  jq -Rsc 'split("\u0000") | .[:-1]' < "${dir}.argv"
}

n=$(jq length "${FORMS}")
mismatches=0
records=()
for ((i = 0; i < n; i++)); do
  id=$(jq -r ".[${i}].id" "${FORMS}")
  jq -j ".[${i}].text" "${FORMS}" | sed 's/@@M@@/argv/' > "${work}/${id}.sh"
  bash_v=$(argv_in bash "${work}/${id}.sh")
  zsh_v=$(argv_in zsh "${work}/${id}.sh")
  if [[ "${RECORD}" == "true" ]]; then
    records+=("$(jq -c --argjson i "${i}" --argjson b "${bash_v}" --argjson z "${zsh_v}" \
      '.[$i] + {argv: {bash: $b, zsh: $z}}' "${FORMS}")")
    continue
  fi
  recorded=$(jq -c ".[${i}].argv" "${FORMS}")
  measured=$(jq -nc --argjson b "${bash_v}" --argjson z "${zsh_v}" '{bash: $b, zsh: $z}')
  if [[ "${recorded}" != "${measured}" ]]; then
    printf 'MISMATCH %s recorded %s measured %s\n' "${id}" "${recorded}" "${measured}"
    mismatches=$((mismatches + 1))
  else
    printf 'ok %s %s\n' "${id}" "${bash_v}"
  fi
done
if [[ "${RECORD}" == "true" ]]; then
  printf '%s\n' "${records[@]}" | jq -s '.'
  exit 0
fi
printf 'shells: %s; %d forms, %d mismatches\n' "$(/bin/bash --version | head -1 | cut -d' ' -f1-4); $(/bin/zsh --version)" "${n}" "${mismatches}"
[[ ${mismatches} -eq 0 ]]
