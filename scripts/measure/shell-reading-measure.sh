#!/usr/bin/env bash
# safedeps: measure how real shells read each form in the shell-reading corpus.
#
# scripts/test/shell-reading.sh checks the gate against the values recorded in
# scripts/measure/shell-reading-forms.json: every form a shell runs to its last
# line must get a verdict. Those values are measurements, not claims, and this
# script is how they are re-measured -- a value copied from someone's notes is
# not one (AGENTS.md, "Citing a zero").
#
# Each form ends in a marker. Here the marker becomes `echo REACHED`, and the
# form runs in a throwaway directory under each shell; a shell that prints
# REACHED ran the line the gate must judge. Nothing in a form installs
# anything: the gate battery puts an install where the marker is, but that
# battery only hands the text to the guard and never runs it.
#
#   @@TAIL@@        the whole last command
#   @@TAIL_SPLIT@@  the same, with a line continuation inside the command word
#
# Usage:
#   scripts/measure/shell-reading-measure.sh            compare with the record
#   scripts/measure/shell-reading-measure.sh --record   print the corpus with
#                                                       freshly measured values
#
# The agent column is the Claude Code Bash tool's own wrapper (zsh -c with the
# session's shell snapshot, then eval), measured only where a snapshot exists.
#
# The shells are the ones the platform has. On macOS: bash 3.2, zsh, /bin/sh
# (bash in POSIX mode), the agent wrapper and /bin/dash, recorded as
# measured.{bash,zsh,sh,agent,dash}. On Linux: bash and dash (which is /bin/sh
# there, and what reads a `sh -c` script), recorded as measured.linux.{bash,dash}.
# --record replaces only this platform's fields, so the record carries both
# after one run on each. The gate reads the three shells as three readings, and
# dash reads `((`, `$[`, `$'...'`, an apostrophe in "${...}" and `&>` unlike bash.
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
FORMS="${ROOT_DIR}/scripts/measure/shell-reading-forms.json"
RECORD=false
[[ "${1:-}" == "--record" ]] && RECORD=true

PLATFORM=$(uname -s)
work=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-shell-reading.XXXXXX")
trap 'rm -rf "${work}"' EXIT
snapshot=$(ls -t "${HOME}"/.claude/shell-snapshots/snapshot-zsh-*.sh 2>/dev/null | head -1)

run_in() { # shell file -> R (ran the tail), - (did not), with ! when the shell reported a parse error
  local shell="$1" file="$2" dir out r="-"
  dir=$(mktemp -d "${work}/cwd.XXXXXX")
  case "${shell}" in
    bash) out=$(cd "${dir}" && /bin/bash -c "$(cat "${file}")" 2>"${dir}/.err" </dev/null) ;;
    zsh)  out=$(cd "${dir}" && /bin/zsh -c "$(cat "${file}")" 2>"${dir}/.err" </dev/null) ;;
    sh)   out=$(cd "${dir}" && /bin/sh -c "$(cat "${file}")" 2>"${dir}/.err" </dev/null) ;;
    dash)
      local dash_bin; dash_bin=$(command -v dash 2>/dev/null || true)
      [[ -n "${dash_bin}" ]] || { printf 'n/a'; return; }
      out=$(cd "${dir}" && "${dash_bin}" -c "$(cat "${file}")" 2>"${dir}/.err" </dev/null) ;;
    linux-bash) out=$(cd "${dir}" && bash -c "$(cat "${file}")" 2>"${dir}/.err" </dev/null) ;;
    agent)
      [[ -n "${snapshot}" ]] || { printf 'n/a'; return; }
      local q; q=$(sed "s/'/'\\\\''/g" "${file}")
      out=$(cd "${dir}" && /bin/zsh -c "source ${snapshot} 2>/dev/null || true && eval '${q}' < /dev/null" 2>"${dir}/.err") ;;
  esac
  printf '%s\n' "${out}" | grep -qx REACHED && r="R"
  grep -qiE 'parse error|syntax error|unexpected' "${dir}/.err" && r="${r}!"
  printf '%s' "${r}"
}

n=$(jq length "${FORMS}")
mismatches=0
records=()
for ((i = 0; i < n; i++)); do
  id=$(jq -r ".[${i}].id" "${FORMS}")
  jq -j ".[${i}].text" "${FORMS}" \
    | sed -e 's/@@TAIL@@/echo REACHED/' -e 's/@@TAIL_SPLIT@@/ec\\\
ho REACHED/' > "${work}/${id}.sh"
  if [[ "${PLATFORM}" == Linux ]]; then
    lb=$(run_in linux-bash "${work}/${id}.sh")
    ld=$(run_in dash "${work}/${id}.sh")
    if [[ "${RECORD}" == "true" ]]; then
      records+=("$(jq -c --argjson i "${i}" --arg b "${lb}" --arg d "${ld}" \
        '.[$i] | .measured.linux = {bash: $b, dash: $d}' "${FORMS}")")
      continue
    fi
    recorded=$(jq -r ".[${i}].measured.linux // {} | \"\(.bash) \(.dash)\"" "${FORMS}")
    measured="${lb} ${ld}"
  else
    bash_v=$(run_in bash "${work}/${id}.sh")
    zsh_v=$(run_in zsh "${work}/${id}.sh")
    sh_v=$(run_in sh "${work}/${id}.sh")
    agent_v=$(run_in agent "${work}/${id}.sh")
    dash_v=$(run_in dash "${work}/${id}.sh")
    if [[ "${RECORD}" == "true" ]]; then
      records+=("$(jq -c --argjson i "${i}" --arg b "${bash_v}" --arg z "${zsh_v}" --arg s "${sh_v}" --arg a "${agent_v}" --arg d "${dash_v}" \
        '.[$i] | .measured = ((.measured // {}) + {bash: $b, zsh: $z, sh: $s, agent: $a, dash: $d})' "${FORMS}")")
      continue
    fi
    recorded=$(jq -r ".[${i}].measured | \"\(.bash) \(.zsh) \(.sh) \(.dash)\"" "${FORMS}")
    measured="${bash_v} ${zsh_v} ${sh_v} ${dash_v}"
  fi
  if [[ "${recorded}" != "${measured}" ]]; then
    printf 'MISMATCH %s recorded [%s] measured [%s]\n' "${id}" "${recorded}" "${measured}"
    mismatches=$((mismatches + 1))
  else
    printf 'ok %s %s\n' "${id}" "${measured}"
  fi
done
if [[ "${RECORD}" == "true" ]]; then
  printf '%s\n' "${records[@]}" | jq -s '.'
  exit 0
fi
if [[ "${PLATFORM}" == Linux ]]; then
  printf 'shells: %s; dash %s; %d forms, %d mismatches\n' "$(bash --version | head -1 | cut -d' ' -f1-4)" "$(dpkg-query -W -f='${Version}' dash 2>/dev/null || echo '?')" "${n}" "${mismatches}"
else
  printf 'shells: %s; %s; /bin/dash; %d forms, %d mismatches\n' "$(/bin/bash --version | head -1 | cut -d' ' -f1-4)" "$(/bin/zsh --version)" "${n}" "${mismatches}"
fi
[[ ${mismatches} -eq 0 ]]
