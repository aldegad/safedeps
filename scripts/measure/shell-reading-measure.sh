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
#   @@HEAD@@        the command word alone, followed in the form by its
#                   arguments `install evil==6.6.6`, so that something can
#                   stand between them (`@@HEAD@@ 2>/dev/null install ...`).
#                   Here it is `./ran`, a stub in the throwaway directory that
#                   leaves a file .reached only when its arguments are exactly
#                   those two words: a shell that read a word between them as
#                   an argument ran the command, but not that install. (The
#                   file is not named after the stub: macOS volumes ignore
#                   case, and a marker RAN was the stub `ran` itself.)
#
# SAFEDEPS_SHELL_FORMS names another corpus in the same format; the
# redirection grid (scripts/measure/redirection-grid.sh) is measured that way.
#
# Usage:
#   scripts/measure/shell-reading-measure.sh            compare with the record
#   scripts/measure/shell-reading-measure.sh --record   print the corpus with
#                                                       freshly measured values
#
# The agent columns are the Claude Code Bash tool's own wrapper (zsh -c with
# the session's shell snapshot, then eval), measured only where a snapshot
# exists. There are two, because the wrapper has been both and they run
# different forms:
#
#   agent        the wrapper as it is now (read from `ps -o command= -p $$`
#                inside the tool, 2026-10-03): after the snapshot it runs
#                `setopt NO_EXTENDED_GLOB NO_BARE_GLOB_QUAL`, so a bare glob
#                qualifier is no qualifier and `>/dev/(null) cmd` runs cmd
#   agent-noset  the wrapper without that line, which is also how any other
#                zsh -c caller reads: `>/dev/null(N) cmd` runs cmd
#
# One column for both would have missed the forms only the other runs.
#
# The shells are the ones the platform has. On macOS: bash 3.2, zsh, /bin/sh
# (bash in POSIX mode), the two agent wrappers and /bin/dash, recorded as
# measured.{bash,zsh,sh,agent,agent-noset,dash}. On Linux: bash and dash (which is /bin/sh
# there, and what reads a `sh -c` script), recorded as measured.linux.{bash,dash}.
# --record replaces only this platform's fields, so the record carries both
# after one run on each. On macOS, SAFEDEPS_MEASURE_BASH5=<path to a bash 5>
# adds measured.bash5: bash 4.1 and later read `{fd}>file` as a redirection,
# which /bin/bash 3.2 does not, and that column is the one that shows it. The gate reads the three shells as three readings, and
# dash reads `((`, `$[`, `$'...'`, an apostrophe in "${...}" and `&>` unlike bash.
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
FORMS="${SAFEDEPS_SHELL_FORMS:-${ROOT_DIR}/scripts/measure/shell-reading-forms.json}"
RECORD=false
[[ "${1:-}" == "--record" ]] && RECORD=true

PLATFORM=$(uname -s)
work=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-shell-reading.XXXXXX")
trap 'rm -rf "${work}"' EXIT
snapshot=$(ls -t "${HOME}"/.claude/shell-snapshots/snapshot-zsh-*.sh 2>/dev/null | head -1)

run_in() { # shell file -> R (ran the tail), - (did not), with ! when the shell reported a parse error
  local shell="$1" file="$2" dir out r="-"
  dir=$(mktemp -d "${work}/cwd.XXXXXX")
  printf '#!/bin/sh\n[ "$*" = "install evil==6.6.6" ] && : > .reached\n' > "${dir}/ran"
  chmod +x "${dir}/ran"
  case "${shell}" in
    bash) out=$(cd "${dir}" && /bin/bash -c "$(cat "${file}")" 2>"${dir}/.err" </dev/null) ;;
    zsh)  out=$(cd "${dir}" && /bin/zsh -c "$(cat "${file}")" 2>"${dir}/.err" </dev/null) ;;
    sh)   out=$(cd "${dir}" && /bin/sh -c "$(cat "${file}")" 2>"${dir}/.err" </dev/null) ;;
    dash)
      local dash_bin; dash_bin=$(command -v dash 2>/dev/null || true)
      [[ -n "${dash_bin}" ]] || { printf 'n/a'; return; }
      out=$(cd "${dir}" && "${dash_bin}" -c "$(cat "${file}")" 2>"${dir}/.err" </dev/null) ;;
    linux-bash) out=$(cd "${dir}" && bash -c "$(cat "${file}")" 2>"${dir}/.err" </dev/null) ;;
    bash5) out=$(cd "${dir}" && "${SAFEDEPS_MEASURE_BASH5}" -c "$(cat "${file}")" 2>"${dir}/.err" </dev/null) ;;
    agent|agent-noset)
      [[ -n "${snapshot}" ]] || { printf 'n/a'; return; }
      local q setopts=""; q=$(sed "s/'/'\\\\''/g" "${file}")
      [[ "${shell}" == agent-noset ]] || setopts="setopt NO_EXTENDED_GLOB NO_BARE_GLOB_QUAL 2>/dev/null || true && "
      out=$(cd "${dir}" && /bin/zsh -c "source ${snapshot} 2>/dev/null || true && ${setopts}eval '${q}' < /dev/null" 2>"${dir}/.err") ;;
  esac
  printf '%s\n' "${out}" | grep -qx REACHED && r="R"
  [[ -e "${dir}/.reached" ]] && r="R"
  grep -qiE 'parse error|syntax error|unexpected' "${dir}/.err" && r="${r}!"
  printf '%s' "${r}"
}

# Control: the markers can say no. The stub marks only its exact arguments,
# and only a shell that ran a marker can mark. A marker that always fired
# (once, on a volume that ignores case) recorded every form as run.
control_ok=true
for control in '@@HEAD@@ install evil==6.6.6|R' '@@HEAD@@ x install evil==6.6.6|-' 'echo @@HEAD@@ install evil==6.6.6|-' '@@TAIL@@|R' 'true|-'; do
  sed -e 's/@@TAIL@@/echo REACHED/' -e 's#@@HEAD@@#./ran#g' <<< "${control%|*}" > "${work}/control.sh"
  [[ "$(run_in "$( [[ "${PLATFORM}" == Linux ]] && echo linux-bash || echo bash )" "${work}/control.sh")" == "${control##*|}" ]] || {
    printf 'control failed: [%s] should measure %s\n' "${control%|*}" "${control##*|}"
    control_ok=false
  }
done
[[ "${control_ok}" == true ]] || exit 1

n=$(jq length "${FORMS}")
mismatches=0
records=()
for ((i = 0; i < n; i++)); do
  id=$(jq -r ".[${i}].id" "${FORMS}")
  jq -j ".[${i}].text" "${FORMS}" \
    | sed -e 's/@@TAIL@@/echo REACHED/' -e 's#@@HEAD@@#./ran#g' -e 's/@@TAIL_SPLIT@@/ec\\\
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
    noset_v=$(run_in agent-noset "${work}/${id}.sh")
    dash_v=$(run_in dash "${work}/${id}.sh")
    bash5_v=""
    [[ -z "${SAFEDEPS_MEASURE_BASH5:-}" ]] || bash5_v=$(run_in bash5 "${work}/${id}.sh")
    if [[ "${RECORD}" == "true" ]]; then
      records+=("$(jq -c --argjson i "${i}" --arg b "${bash_v}" --arg z "${zsh_v}" --arg s "${sh_v}" --arg a "${agent_v}" --arg an "${noset_v}" --arg d "${dash_v}" --arg b5 "${bash5_v}" \
        '.[$i] | .measured = ((.measured // {}) + {bash: $b, zsh: $z, sh: $s, agent: $a, "agent-noset": $an, dash: $d} + (if $b5 == "" then {} else {bash5: $b5} end))' "${FORMS}")")
      continue
    fi
    recorded=$(jq -r ".[${i}].measured | \"\(.bash) \(.zsh) \(.sh) \(.dash)\"" "${FORMS}")
    measured="${bash_v} ${zsh_v} ${sh_v} ${dash_v}"
    if [[ -n "${bash5_v}" ]]; then
      recorded+=" $(jq -r ".[${i}].measured.bash5 // \"\"" "${FORMS}")"
      measured+=" ${bash5_v}"
    fi
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
  printf 'shells: %s; %s; /bin/dash%s; %d forms, %d mismatches\n' "$(/bin/bash --version | head -1 | cut -d' ' -f1-4)" "$(/bin/zsh --version)" \
    "${SAFEDEPS_MEASURE_BASH5:+; bash5 $("${SAFEDEPS_MEASURE_BASH5}" --version | head -1 | cut -d' ' -f4)}" "${n}" "${mismatches}"
fi
[[ ${mismatches} -eq 0 ]]
