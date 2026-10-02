#!/usr/bin/env bash
# safedeps: the manager word grammar, held by spelling rather than by example.
#
# Four rounds of review each found the next form a reader had not been given
# as an example: a cut in the wrong place, a word cut in two, an option value
# read as the package, a local package read as a module. Every one was a
# reader that approximated a manager's grammar, and every repair added the
# form that had been found. This battery does not list forms. For each place a
# value can stand -- an option of the manager before its command, an option of
# the command, an option of a runner, a word after the package a runner runs --
# it writes the same command with the value spelled nine ways, as `--opt V`
# and as `--opt=V`, and asks the gate for three answers: the verdict, the
# packages it prescribes, and the operands it records once the prescriptions
# are approved. The oracle is that the answers do not depend on how the value
# is spelled, and that the plain spelling gives the answers declared for it. A
# reader that takes part of a value, or a value for an operand, or an operand
# for a value, gives one spelling a different answer.
#
# A fifth class holds the options npm 10.8.2 does not define and npm 11.19.0
# does (SAFEDEPS_G_NPM_OTHER): there the word after the option is a value to
# one npm and the command or an operand to the other, and the gate judges the
# union. Its answers do depend on the spelling, because the value is a package
# to one npm; its oracle is that the pinned install is judged under every
# spelling.
#
# Commands are fed to the guard as payloads; nothing here runs them.
#
# Usage: scripts/test/manager-variants.sh [--tree <dir>]
#   --tree <dir>   judge with the guard in another checkout (the controls)
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TREE="${ROOT_DIR}"
if [[ "${1:-}" == --tree ]]; then
  TREE=$(cd "$2" && pwd)
fi
cd "${TREE}"

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
# A class that fails is reported and the next one still runs, so a control
# shows every class it breaks; the battery fails at the end.
failed=0
not_ok() { printf 'not ok - %s\n' "$1" >&2; failed=1; }

for tool in jq; do
  command -v "${tool}" >/dev/null 2>&1 || fail "${tool} is required"
done

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-variants.XXXXXX")
trap 'rm -rf "${tmp_root}"' EXIT
project_dir="${tmp_root}/project"
mkdir -p "${project_dir}"
printf '{"dependencies":{}}\n' > "${project_dir}/package.json"
# The plain spellings name directories, and a manager that changes directory
# reads its project there.
for dir in x x@y 'a b'; do
  mkdir -p "${project_dir}/${dir}"
  printf '{"dependencies":{}}\n' > "${project_dir}/${dir}/package.json"
done

# The tuple for one command: `verdict | prescriptions | recorded operands`,
# after approving every prescription the gate makes, the loop an agent follows.
tuple() {
  local command="$1" safe out reason first="" presc="" approved eco ps iter rec
  safe=$(mktemp -d "${tmp_root}/home.XXXXXX")
  for iter in 1 2 3 4 5 6; do
    out=$(jq -nc --arg c "${command}" --arg cwd "${project_dir}" \
      '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}' |
      HOME="${safe}/home" SAFEDEPS_HOME="${safe}" scripts/safedeps-pre-guard.sh 2>/dev/null) || true
    reason=$(jq -r '.hookSpecificOutput.permissionDecisionReason // empty' <<< "${out:-{\}}" 2>/dev/null) || true
    if [[ "${iter}" == 1 ]]; then
      first=$(jq -r '.hookSpecificOutput.permissionDecision // "pass"' <<< "${out:-{\}}" 2>/dev/null) || first=pass
      [[ "${reason}" != *UNDECIDED* ]] || first=undecided
      presc=$(printf '%s\n' "${reason}" | sed -nE 's/.*run `([^`]*)` first.*/\1/p' \
        | awk '{ gsub(/ && /, "\n"); print }' | awk 'NF { print $(NF-1), $NF }' | sort -u | tr '\n' ';')
    fi
    [[ "${reason}" == *"install not approved"* ]] || break
    approved=0
    while read -r eco ps; do
      [[ -n "${ps}" ]] || continue
      ( export SAFEDEPS_HOME="${safe}"
        . lib/ledger/ledger.sh
        safedeps_ledger_write_approved_spec "${eco}" "${ps%@*}" "${ps##*@}" >/dev/null ) && approved=$((approved + 1))
    done < <(printf '%s\n' "${reason}" | sed -nE 's/.*run `([^`]*)` first.*/\1/p' \
      | awk '{ gsub(/ && /, "\n"); print }' | awk 'NF { print $(NF-1), $NF }')
    [[ "${approved}" -gt 0 ]] || break
  done
  rec=$({ grep 'pre-guard UNGATED' "${safe}/advisory.log" 2>/dev/null || true; } \
    | sed -e 's/.* Unpinned: //' -e 's/\. Command: .*//' | sed 's/, /\n/g' | sort -u | tr '\n' ' ' | sed 's/ $//')
  printf '%s | %s | %s' "${first}" "${presc}" "${rec}"
}

# The nine spellings of a value. Each is one shell word.
spellings=(
  'x'
  'x@y'
  '$(echo a b)'
  '"a b"'
  "'a b'"
  '`echo a b`'
  'a\ b'
  '"$(echo a b)"'
  '""'
)

# <class>|<template, %V% standing for the option and its value>|<option>|<declared tuple for the plain spelling>
templates=(
  # 1. The manager's own option, before its command.
  'manager|npm %V% install evil@1.0.0|--prefix|deny | npm evil@1.0.0; | '
  'manager|pnpm %V% add evil@1.0.0|--dir|deny | npm evil@1.0.0; | '
  'manager|yarn %V% add evil@1.0.0|--cwd|deny | npm evil@1.0.0; | '
  'manager|pip %V% install evil==1.0.0|--cache-dir|deny | pypi evil@1.0.0; | '
  'manager|uv %V% add evil==1.0.0|--directory|deny | pypi evil@1.0.0; | '
  'manager|cargo %V% install evil --version 1.0.0|--config|deny | crates.io evil@1.0.0; | '
  'manager|gem %V% install rake -v 13.0.0|--config-file|deny | rubygems rake@13.0.0; | '
  'manager|poetry %V% add evil@1.0.0|--directory|deny | pypi evil@1.0.0; | '
  'manager|mvn %V% dependency:get -Dartifact=g:evil:1.0.0|-f|deny | maven g:evil@1.0.0; | '
  # 2. The command's option, after the command.
  'command|npm install %V% evil@1.0.0|--tag|deny | npm evil@1.0.0; | '
  'command|pip install %V% evil==1.0.0|--log|deny | pypi evil@1.0.0; | '
  'command|gem install %V% rake -v 13.0.0|--install-dir|deny | rubygems rake@13.0.0; | '
  'command|cargo install %V% ripgrep --version 13.0.0|--root|deny | crates.io ripgrep@13.0.0; | '
  'command|dotnet add package Serilog %V% --version 3.1.1|--source|deny | nuget Serilog@3.1.1; | '
  'command|uv add %V% evil==1.0.0|--index|deny | pypi evil@1.0.0; | '
  'command|pnpm add %V% evil@1.0.0|--filter|deny | npm evil@1.0.0; | '
  'command|bundle add rails %V% --version 7.1.0|--group|deny | rubygems rails@7.1.0; | '
  # 3. A runner's option, before the package it runs.
  'runner|npx %V% evil@1.0.0|--cache|deny | npm evil@1.0.0; | '
  'runner|uvx %V% ruff==0.1.0|--python|deny | pypi ruff@0.1.0; | '
  'runner|go run %V% example.com/m@v1.0.0|-C|deny | go example.com/m@v1.0.0; | '
  'runner|pipx run %V% black==24.1.0|--python|deny | pypi black@24.1.0; | '
  'runner|pnpm dlx %V% evil@1.0.0|--dir|deny | npm evil@1.0.0; | '
  # 4. The program's arguments, after the package a runner runs.
  'program|npx evil@1.0.0 %V%||deny | npm evil@1.0.0; | '
  'program|uvx ruff==0.1.0 %V%||deny | pypi ruff@0.1.0; | '
  'program|pipx run black==24.1.0 %V%||deny | pypi black@24.1.0; | '
  'program|bunx evil@1.0.0 %V%||deny | npm evil@1.0.0; | '
  'program|go run ./cmd %V%||pass |  | '
  'program|go run main.go --email %V%||pass |  | '
  # 5. npm 10.8.2 defines no such option: the word after it is a value to one
  #    npm and a command or an operand to the other.
  'npm10|npm %V% install evil@1.0.0|--min-release-age|'
  'npm10|npm install %V% evil@1.0.0|--min-release-age|'
  'npm10|npx %V% evil@1.0.0|--min-release-age|'
  # 6. Declared rows: an empty word in an operand's place names nothing, so it
  #    is neither checked nor recorded; the record names the real package.
  'declared|pnpm add "" left-pad||pass |  | npm:left-pad'
  'declared|npx "" evil@1.0.0||pass |  | '
  'declared|uvx --python "" "" evil==1.0.0||pass |  | '
  # bun takes for its command the first word that does not start with `-`, so
  # an option before the command takes no value: `bun --cwd x add evil@1.0.0`
  # runs `bun x add evil@1.0.0`, which fetches the package `add` (bun 1.4.2,
  # measured). The word is judged both ways; bun's own reading is the record.
  'declared|bun --cwd x add evil@1.0.0||deny | npm evil@1.0.0; | npm:add'
  'declared|bun --cwd=x add evil@1.0.0||deny | npm evil@1.0.0; | '
  # bunx reads `--cwd` as a switch, so `x` is the package it fetches and runs,
  # and evil@1.0.0 is that program's argument (bun 1.4.2, measured).
  'declared|bunx --cwd x evil@1.0.0||pass |  | npm:x'
  'declared|bunx --cwd=x evil@1.0.0||deny | npm evil@1.0.0; | '
)

# One command per template, spelling and form; judged eight at a time.
jobs_dir="${tmp_root}/jobs"
mkdir -p "${jobs_dir}"
n=0
for t in "${templates[@]}"; do
  IFS='|' read -r class template option _ <<< "${t}"
  for (( s = 0; s < ${#spellings[@]}; s++ )); do
    [[ "${class}" != declared || "${s}" == 0 ]] || continue
    for form in sep eq; do
      value="${spellings[s]}"
      if [[ -z "${option}" ]]; then
        [[ "${form}" == sep ]] || continue
        word="${value}"
      elif [[ "${form}" == sep ]]; then
        word="${option} ${value}"
      else
        word="${option}=${value}"
      fi
      command="${template//%V%/${word}}"
      printf '%s\n' "${command}" > "${jobs_dir}/${n}.cmd"
      ( tuple "${command}" > "${jobs_dir}/${n}.out" ) &
      n=$((n + 1))
      (( n % 8 == 0 )) && wait
    done
  done
done
wait

red=0 k=0
for t in "${templates[@]}"; do
  IFS='|' read -r class template option want <<< "${t}"
  want="${t#*|*|*|}"
  base="" rows="" bad=false
  for (( s = 0; s < ${#spellings[@]}; s++ )); do
    [[ "${class}" != declared || "${s}" == 0 ]] || continue
    for form in sep eq; do
      [[ -n "${option}" || "${form}" == sep ]] || continue
      got=$(cat "${jobs_dir}/${k}.out") cmd=$(cat "${jobs_dir}/${k}.cmd")
      k=$((k + 1))
      rows+="    [${got}] ${cmd}"$'\n'
      if [[ "${class}" == npm10 ]]; then
        # The union: the pinned install is judged whichever npm runs it.
        [[ "${got}" == deny\ \|*"evil@1.0.0;"* ]] || bad=true
        continue
      fi
      if (( s == 0 )); then
        [[ "${got}" == "${want}" ]] || bad=true
      fi
      [[ -n "${base}" ]] || base="${got}"
      [[ "${got}" == "${base}" ]] || bad=true
    done
  done
  if [[ "${bad}" == true ]]; then
    red=$((red + 1))
    printf '# RED %s: %s (declared: [%s])\n%s' "${class}" "${template}" "${want}" "${rows}" >&2
  fi
done
if (( red > 0 )); then
  not_ok "the gate's answers depend on how a value is spelled (${red} of ${#templates[@]} templates, ${n} commands)"
else
  pass "verdict, prescription and record do not depend on how a value is spelled (${#templates[@]} templates, ${#spellings[@]} spellings, ${n} commands)"
fi

# --- A manager's runtime option where it installs --------------------------------
# bun's `--help` lists options that take a value when bun runs a file: --print,
# --eval, --preload, --port and the rest. In an install command bun reads each
# of them as a switch, and `-c, --config` and `--catalog` take a value only
# after `=` (bun 1.4.2, measured: `bun add --print x` installs x). The table
# once listed them for every bun command, so the package after one was read as
# its value: `bun add --print evil@1.0.0` passed with no check and no record.
# Before the command bun reads no option's value at all. Each option stands
# right before the package, in every install spelling and before the command,
# with the package spelled three ways; the answer is the same denial each time.
runtime_options=(
  -p --print -e --eval -r --preload --require --import -c --config --catalog -d --define
  -l --loader --port --title --env-file --conditions --shell --elide-lines --watch-kill-signal
  --inspect --inspect-wait --inspect-brk --install --fetch-preconnect --max-http-header-size
  --dns-result-order --redirect-warnings --disable-warning --unhandled-rejections
  --console-depth --user-agent --cron-title --cron-period --main-fields --extension-order
  --tsconfig-override --drop --feature --jsx-factory --jsx-fragment --jsx-import-source
  --jsx-runtime --cpu-prof-name --cpu-prof-dir --cpu-prof-interval --heap-prof-name
  --heap-prof-dir --heap-prof-interval
)
packages=('evil@1.0.0' '"evil@1.0.0"' 'ev"il"@1.0.0')
want_runtime='deny | npm evil@1.0.0; | '
jobs_dir="${tmp_root}/runtime"
mkdir -p "${jobs_dir}"
n=0
for option in "${runtime_options[@]}"; do
  for package in "${packages[@]}"; do
    for command in "bun add ${option} ${package}" "bun i ${option} ${package}" \
        "bun install ${option} ${package}" "bun ${option} add ${package}"; do
      printf '%s\n' "${command}" > "${jobs_dir}/${n}.cmd"
      ( tuple "${command}" > "${jobs_dir}/${n}.out" ) &
      n=$((n + 1))
      (( n % 8 == 0 )) && wait
    done
  done
done
wait
red=0
for (( k = 0; k < n; k++ )); do
  got=$(cat "${jobs_dir}/${k}.out")
  [[ "${got}" == "${want_runtime}" ]] && continue
  red=$((red + 1))
  printf '# RED [%s] %s\n' "${got}" "$(cat "${jobs_dir}/${k}.cmd")" >&2
done
if (( red > 0 )); then
  not_ok "a runtime option of bun hides the package after it (${red} of ${n} commands)"
else
  pass "bun's runtime options take no value where bun installs (${#runtime_options[@]} options, ${#packages[@]} spellings, ${n} commands)"
fi

# --- The table itself ----------------------------------------------------------
# A command's entry is looked up before `*`: with `*` first, `bun x -p` was
# read as bun's runtime `-p` and the package it names was never checked.
# A synthetic table holds the order: one option, two classes.
order=$(
  # shellcheck source=../../lib/install-grammar.sh
  source "${TREE}/lib/install-grammar.sh"
  SAFEDEPS_G_VALUE_OPTIONS+=" zz/*:-q=v zz/run:-q=p "
  safedeps_manager_option_class zz run -q && printf '%s' "${SAFEDEPS_G_VALUE}"
  safedeps_manager_option_class zz "" -q && printf ' %s' "${SAFEDEPS_G_VALUE}"
  true
)
[[ "${order}" == "p v" ]] || not_ok "a command's own entry is read before \`*\` (got [${order}], want [p v])"
# No option is listed both for `*` and for a command of the same manager: the
# command's entry would silently decide one reading and `*` the other. And
# every scope names a command path the manager has, or no lookup reaches it.
table_faults=$(
  # shellcheck source=../../lib/install-grammar.sh
  source "${TREE}/lib/install-grammar.sh"
  set -f
  for e in ${SAFEDEPS_G_VALUE_OPTIONS}; do
    family="${e%%/*}" scope="${e#*/}" scope="${scope%%:*}" option="${e#*:}" option="${option%=*}"
    if [[ "${scope}" == '*' ]]; then
      for f in ${SAFEDEPS_G_VALUE_OPTIONS}; do
        [[ "${f}" == "${family}/"* && "${f}" != "${family}/*:"* && "${f#*:}" == "${option}="* ]] \
          && printf 'both %s and %s\n' "${e}" "${f}"
      done
    elif ! safedeps_manager_command "${family}" "${scope}"; then
      printf 'no command path %s:%s for %s\n' "${family}" "${scope}" "${e}"
    fi
  done
  true
)
[[ -z "${table_faults}" ]] || not_ok "the value table has an entry no lookup reads as written: ${table_faults//$'\n'/; }"
[[ "${order}" != "p v" || -n "${table_faults}" ]] \
  || pass "the value table reads a command's entry first, lists no option for both \`*\` and a command, and every scope is a command path"
exit "${failed}"
