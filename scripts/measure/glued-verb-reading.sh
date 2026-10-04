#!/usr/bin/env bash
# safedeps: a manager's last word glued to the operator after it.
#
# The shell ends a word at a blank and at an operator: `npm ci; echo x` hands
# npm the word `ci`, exactly as `npm ci ; echo x` does. The recognizers read a
# verb as ended only by a blank or the end of the line, so the glued spelling
# was no install at all to v2.17.2 (bb0787d), 7d66f8c and v2.18.0: no check,
# no `--ignore-scripts`, and for every manager but npm no later check either,
# since the pre-guard is the only gate pip, cargo, go, gem, maven and nuget
# have.
#
# This writes, for each manager and each operator, the command with the last
# word of the install glued to the operator, and the same command with a blank
# before the operator, and asks a guard for both. The oracle is the shell: it
# reads the two the same, so the guard must too. Each row also says what bash,
# zsh and dash hand the manager, read with a function standing in for it (the
# manager's name is replaced in the text; nothing here runs a manager).
#
# A `}` glued to the last word is zsh's: it closes a `{` group there and hands
# the word before it on (`{ npm ci}` runs `npm ci`), where bash and dash refuse
# the group. Those rows are held to `{ <install> ;}`, by their answers only:
# where the flag goes after a `}` is the rewrite's own business.
#
# The rewrite of the spaced form can carry one flag more, at its very end: the
# flag 7d66f8c appended to a one-statement install (inert_release_appends),
# which 7d66f8c never gave the glued form because it read no install there.
# The comparison sets that one aside.
#
# A heredoc fed to a shell (`bash <<E` with an install in the body) is a
# carrier outside the enumeration ARCHITECTURE.md states, so it is printed as a
# row of its own and not judged.
#
# Usage: scripts/measure/glued-verb-reading.sh [--tree <dir>] [--jobs <n>] [--out <file>]
#   --tree <dir>  judge with the guard of another checkout (bb0787d, a tree
#                 before the fix)
#   --jobs <n>    guards at once (default 2)
#   --out <file>  also write the table there, tab-separated
# Verdicts: same (read as the spaced form is), same-zsh (a glued `}`, answered
# as `{ <install> ;}`), silent (the same answers, which for that install say
# nothing), DIFF (read differently), unread (the spaced form is not read
# either: the tree does not know that install at all).
# Exit: 0 every glued form reads as its spaced form and is read, 1 otherwise.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TREE="${ROOT_DIR}" JOBS=2 OUT=""
while (( $# )); do
  case "$1" in
    --tree) TREE=$(cd "$2" && pwd); shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    *) printf 'usage: %s [--tree <dir>] [--jobs <n>] [--out <file>]\n' "$0" >&2; exit 2 ;;
  esac
done
command -v jq >/dev/null 2>&1 || { printf 'jq is required\n' >&2; exit 2; }

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-glued.XXXXXX")
trap 'rm -rf "${tmp_root}"' EXIT
project_dir="${tmp_root}/project"
mkdir -p "${project_dir}"
printf '{"dependencies":{}}\n' > "${project_dir}/package.json"
printf 'evil==1.0.0\n' > "${project_dir}/requirements.txt"

# <manager word>|<words before it>|<words after it>|<what the spaced form
# shows>. The manager word is the one the shell probe replaces; the operator
# goes right after the last word. What the spaced form shows says how a
# reading can be seen at all: `deny` (a pinned package, unapproved), `rewrite`
# (an npm install, which gets `--ignore-scripts`), or `silent`: an install that
# names no package and is no npm CLI install gets no check, record or rewrite
# whether it is read or not, so equal answers say nothing there and the row
# says so.
bases=(
  'npm||ci|rewrite'
  'npm||i|rewrite'
  'npm||install evil@1.0.0|deny'
  'npm||--prefix=. ci|rewrite'
  'npx||evil@1.0.0|deny'
  'npm||init vite@5.0.0|deny'
  'pnpm||install|silent'
  'pnpm||add evil@1.0.0|deny'
  'pnpm||dlx evil@1.0.0|deny'
  'yarn||install|silent'
  'yarn||add evil@1.0.0|deny'
  'bun||install|silent'
  'bun||add evil@1.0.0|deny'
  'bunx||evil@1.0.0|deny'
  'pip|PIP_REQUIREMENT=requirements.txt|install|silent'
  'pip||install evil==1.0.0|deny'
  'python3||-m pip install evil==1.0.0|deny'
  'uv||add evil==1.0.0|deny'
  'uv||pip install evil==1.0.0|deny'
  'uvx||ruff==0.1.0|deny'
  'poetry||add evil==1.0.0|deny'
  'pipx||install black==24.1.0|deny'
  'pipenv||install evil==1.0.0|deny'
  'cargo||add evil@1.0.0|deny'
  'cargo||install ripgrep --version 13.0.0|deny'
  'go||get|silent'
  'go||install|silent'
  'go||get example.com/m@v1.0.0|deny'
  'gem||install rake -v 13.0.0|deny'
  'bundle||add rails --version 7.1.0|deny'
  'mvn||-Dartifact=g:evil:1.0.0 dependency:get|deny'
  'mvn||dependency:get -Dartifact=g:evil:1.0.0|deny'
  'dotnet||package update|silent'
  'dotnet||add package Serilog --version 3.1.1|deny'
  'dotnet||tool install dotnet-ef --version 8.0.0|deny'
)

# <name>^<glued template>^<spaced template>; %C% is the install.
operators=(
  ';^%C%; echo x^%C% ; echo x'
  ';end^%C%;^%C% ;'
  '&^%C%& echo x^%C% & echo x'
  '|^%C%| cat^%C% | cat'
  '&&^%C%&& echo x^%C% && echo x'
  '||^%C%|| echo x^%C% || echo x'
  ')^(%C%)^(%C% )'
  ';}^{ %C%;}^{ %C% ;}'
  '}^{ %C%}^{ %C% ;}'
  '>^%C%>/dev/null^%C% >/dev/null'
  '<^%C%</dev/null^%C% </dev/null'
)

# The guard's answers for one command, after approving what it prescribes,
# the loop an agent follows: `first | prescriptions | recorded | last | rewrite`.
tuple() {
  local command="$1" safe out reason first="" presc="" last="" rewrite="" approved eco ps iter rec
  safe=$(mktemp -d "${tmp_root}/home.XXXXXX")
  for iter in 1 2 3 4; do
    out=$(jq -nc --arg c "${command}" --arg cwd "${project_dir}" \
      '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}' |
      HOME="${safe}/home" SAFEDEPS_HOME="${safe}" "${TREE}/scripts/safedeps-pre-guard.sh" 2>/dev/null) || true
    reason=$(jq -r '.hookSpecificOutput.permissionDecisionReason // empty' <<< "${out:-{\}}" 2>/dev/null) || true
    last=$(jq -r '.hookSpecificOutput.permissionDecision // "pass"' <<< "${out:-{\}}" 2>/dev/null) || last=pass
    [[ "${reason}" != *UNDECIDED* ]] || last=undecided
    rewrite=$(jq -r '.hookSpecificOutput.updatedInput.command // empty' <<< "${out:-{\}}" 2>/dev/null) || rewrite=""
    if [[ "${iter}" == 1 ]]; then
      first="${last}"
      presc=$(printf '%s\n' "${reason}" | sed -nE 's/.*run `([^`]*)` first.*/\1/p' \
        | awk '{ gsub(/ && /, "\n"); print }' | awk 'NF { print $(NF-1), $NF }' | sort -u | tr '\n' ';')
    fi
    [[ "${reason}" == *"install not approved"* ]] || break
    approved=0
    while read -r eco ps; do
      [[ -n "${ps}" ]] || continue
      ( export SAFEDEPS_HOME="${safe}"
        . "${TREE}/lib/ledger/ledger.sh"
        safedeps_ledger_write_approved_spec "${eco}" "${ps%@*}" "${ps##*@}" >/dev/null ) && approved=$((approved + 1))
    done < <(printf '%s\n' "${reason}" | sed -nE 's/.*run `([^`]*)` first.*/\1/p' \
      | awk '{ gsub(/ && /, "\n"); print }' | awk 'NF { print $(NF-1), $NF }')
    [[ "${approved}" -gt 0 ]] || break
  done
  # The record without its time and command: the packages it names, or, from
  # a tree that does not name them (v2.17.2), the ecosystem.
  rec=$({ grep 'pre-guard UNGATED' "${safe}/advisory.log" 2>/dev/null || true; } | cut -f2- \
    | sed -E -e 's/^pre-guard UNGATED: [^ ]+ install.* Unpinned: (.*)\. Command: .*/\1/' \
             -e 's/^pre-guard UNGATED: ([^ ]+) install.*/ungated:\1/' \
    | sed 's/, /\n/g' | sort -u | tr '\n' ' ' | sed 's/ $//')
  printf '%s | %s | %s | %s\t%s' "${first}" "${presc}" "${rec}" "${last}" "${rewrite}"
}

# What <shell> hands the manager in <form>, the manager's name replaced by a
# function that writes its words to a file, so a redirection or a background
# job in the form does not hide them. `syntax` when the shell refuses the form
# or never calls the function.
shell_words() {
  local shell="$1" form="$2" f out
  command -v "${shell}" >/dev/null 2>&1 || { printf 'absent'; return; }
  f=$(mktemp "${tmp_root}/words.XXXXXX")
  ( cd "${tmp_root}" && SD_F="${f}" PATH=/usr/bin:/bin "${shell}" -c \
    '_sd_argv() { printf "%s," "$@" >> "$SD_F"; printf "\n" >> "$SD_F"; }
'"${form}"'
wait' >/dev/null 2>&1 </dev/null ) || true
  out=$(head -1 "${f}")
  [[ -n "${out}" ]] || out=syntax
  printf '%s' "${out%,}"
}

jobs_dir="${tmp_root}/jobs"
mkdir -p "${jobs_dir}"
n=0
for b in "${bases[@]}"; do
  IFS='|' read -r manager pre post shows <<< "${b}"
  install="${pre:+${pre} }${manager} ${post}"
  probe="${pre:+${pre} }_sd_argv ${post}"
  for o in "${operators[@]}"; do
    IFS='^' read -r name glued spaced <<< "${o}"
    g="${glued//%C%/${install}}" s="${spaced//%C%/${install}}"
    pg="${glued//%C%/${probe}}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${manager}" "${name}" "${g}" "${s}" "${pg}" "${shows}" > "${jobs_dir}/${n}.row"
    ( tuple "${g}" > "${jobs_dir}/${n}.g"
      if [[ -n "${spaced}" ]]; then tuple "${s}" > "${jobs_dir}/${n}.s"; else : > "${jobs_dir}/${n}.s"; fi
      for sh in bash zsh dash; do printf '%s=%s ' "${sh}" "$(shell_words "${sh}" "${pg}")"; done > "${jobs_dir}/${n}.w"
    ) &
    n=$((n + 1))
    (( n % JOBS == 0 )) && wait
  done
done
wait

# A heredoc fed to a shell: outside the enumeration, printed and not judged.
here_form=$'bash <<E\nnpm ci\nE'
here_got=$(tuple "${here_form}")

table=$(
  printf 'id\tmanager\top\tglued\tshells\tglued_tuple\tglued_rewrite\tspaced_tuple\tspaced_rewrite\tshows\tverdict\n'
  for (( k = 0; k < n; k++ )); do
    IFS=$'\t' read -r manager name g s _ shows < "${jobs_dir}/${k}.row"
    IFS=$'\t' read -r gt gr < "${jobs_dir}/${k}.g" || true
    st="" sr=""
    [[ ! -s "${jobs_dir}/${k}.s" ]] || IFS=$'\t' read -r st sr < "${jobs_dir}/${k}.s" || true
    gn="${gr// /}" sn="${sr// /}"
    [[ "${g}" == *--ignore-scripts ]] || gn="${gn%--ignore-scripts}"
    [[ "${s}" == *--ignore-scripts ]] || sn="${sn%--ignore-scripts}"
    if [[ "${name}" == '}' && "${gt}" != "${st}" ]] \
       || [[ "${name}" != '}' && ( "${gt}" != "${st}" || "${gn}" != "${sn}" ) ]]; then
      v=DIFF
    elif [[ "${shows}" == deny && "${st}" != deny* ]] || [[ "${shows}" == rewrite && -z "${sr}" ]]; then
      # The spaced form is not read either: the tree does not know the install
      # however it ends.
      v=unread
    elif [[ "${shows}" == silent ]]; then
      v=silent
    elif [[ "${name}" == '}' ]]; then
      v='same-zsh'
    else
      v=same
    fi
    printf '%03d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$((k + 1))" "${manager}" "${name}" \
      "${g}" "$(cat "${jobs_dir}/${k}.w")" "${gt}" "${gr}" "${st}" "${sr}" "${shows}" "${v}"
  done
  printf 'here\tnpm\theredoc\t%s\t-\t%s\t-\t-\t-\tout-of-enumeration\n' "${here_form//$'\n'/\\n}" "${here_got}"
)
[[ -z "${OUT}" ]] || printf '%s\n' "${table}" > "${OUT}"
printf '%s\n' "${table}"
diff_count=$(printf '%s\n' "${table}" | awk -F'\t' '$NF == "DIFF"' | wc -l | tr -d ' ')
unread_count=$(printf '%s\n' "${table}" | awk -F'\t' '$NF == "unread"' | wc -l | tr -d ' ')
printf '# tree %s (%s): %s forms, %s read differently from their spaced form, %s not read either way\n' \
  "${TREE}" "$(sed -nE 's/^SAFEDEPS_VERSION="?([^"]*)"?$/\1/p' "${TREE}/bin/safedeps" | head -1)" \
  "${n}" "${diff_count}" "${unread_count}"
(( diff_count == 0 && unread_count == 0 ))
