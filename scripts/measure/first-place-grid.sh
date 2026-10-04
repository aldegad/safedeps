#!/usr/bin/env bash
# safedeps: the first place of a command list, generated from the grammar.
#
# redirection-grid.sh crosses the manual's compound-command productions with
# four first places picked by hand (a command, a subshell, a group, `!`), and
# the starts that table missed were all in what the simple-command grammar puts
# before a command word. This axis is that grammar:
#
#   POSIX Shell Command Language 2.10.2 (Shell Grammar):
#     pipeline       : pipe_sequence | Bang pipe_sequence
#     cmd_prefix     : io_redirect | cmd_prefix io_redirect
#                    | ASSIGNMENT_WORD | cmd_prefix ASSIGNMENT_WORD
#     io_redirect    : io_file | IO_NUMBER io_file | io_here | IO_NUMBER io_here
#     io_file        : '<' | LESSAND | '>' | GREATAND | DGREAT | LESSGREAT | CLOBBER
#     io_here        : DLESS here_end | DLESSDASH here_end
#   bash 3.6 Redirections (&>, &>>, <<<, {varname}), 3.4 Parameters (+=,
#   NAME[i]=, NAME=(...)), 3.2.3 Pipelines (time, time -p), 4.1 (command, exec);
#   zsh 6.2 Precommand Modifiers (-, nocorrect, noglob), 7 Redirection (>!);
#   env(1).
#
# Each item stands first in the list slot of every production in
# redirection-grid.sh (read from that file, so the places are the committed
# ones), glued to what is before it and after a blank.
#
# Usage:
#   first-place-grid.sh generate pip|npm            > forms.jsonl
#   first-place-grid.sh measure <dir> <forms.jsonl> <pip|npm> <trees|-> <line>...
#
# measure: <dir> holds one source tree per name in <trees> (comma list, `-` for
# none). For each form it prints id, data, the shells that run the install
# (b bash, z zsh -f, s sh, d dash; a stub manager on PATH marks only the exact
# install argv), and each tree's pre-guard verdict on it as a payload:
# deny:notapproved, deny:undecided, deny:<reason>, rewrite (--ignore-scripts
# put in), or pass. A tree is asked only about a form some shell runs, a data
# form, or every form when ALL is set (a host without zsh). Nothing real is
# installed: the shells run a stub, and the guard only judges. Run it on a test
# host, two at a time at most:
#   seq 1 "$(grep -c . forms.jsonl)" | xargs -P 2 -n 40 first-place-grid.sh measure ...
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GRID="${REPO_DIR}/scripts/measure/redirection-grid.sh"

# id <TAB> prefix text (the install follows it after one blank)
ITEMS='lt	</dev/null
lessand	<&0
gt	>/dev/null
greatand	>&2
dgreat	>>/dev/null
lessgreat	<>/dev/null
clobber	>|/dev/null
ionum-gt	2>/dev/null
ionum-dup	2>&1
dless	<<E
dlessdash	<<-E
and-gt	&>/dev/null
and-dgreat	&>>/dev/null
tless	<<<x
varfd	{fd}>/dev/null
z-bang-gt	>!/dev/null
assign	X=1
assign-plus	X+=1
assign-sub	a[1]=x
assign-arr	a=(x)
bang	!
time	time
time-p	time -p
command	command
command-p	command -p
exec	exec
noglob	noglob
nocorrect	nocorrect
z-dash	-
env	env
env-assign	env X=1
env-u	env -u X
gt+assign	>/dev/null X=1
assign+gt	X=1 >/dev/null
ionum+command	2>/dev/null command
assign+command	X=1 command
gt+dup	>/dev/null 2>&1
bang+gt	! >/dev/null
time+gt	time >/dev/null
noglob+gt	noglob >/dev/null'

generate() {
  local table="$1" install items productions pid tpl data iid item list t
  if [[ "${table}" == npm ]]; then
    install='@@HEAD@@ ci'
    items=$(grep -E '^(gt|ionum-dup|assign|bang|command|gt\+assign|z-bang-gt|varfd)	' <<< "${ITEMS}")
  else
    install='@@HEAD@@ install evil==6.6.6'
    items="${ITEMS}"
  fi
  productions=$(awk '/^PRODUCTIONS=\x27/{p=1; sub(/^PRODUCTIONS=\x27/, "")} /^# id <TAB> what stands first/{exit} p{print}' "${GRID}" \
    | sed -e '$ s/'"'"'$//' -e "s/'\"'\"'/'/g")
  while IFS=$'\t' read -r pid _ tpl; do
    data=false; [[ "${pid}" != data-* ]] || data=true
    while IFS=$'\t' read -r iid item; do
      list="${item} ${install}"
      t="${tpl//%L/${list}}"
      t="${t//@NL@/$'\n'}"
      if [[ "${tpl}" == *%_* ]]; then
        emit "${pid}~${iid}~blank" "${data}" "${t//%_/ }"
        emit "${pid}~${iid}~glued" "${data}" "${t//%_/}"
      else
        emit "${pid}~${iid}" "${data}" "${t}"
      fi
    done <<< "${items}"
  done <<< "${productions}"
}

# One form, with a heredoc body per `<<E`/`<<-E` after it.
emit() { # id data text
  local text="$3" n k
  n=$(grep -o '<<-\{0,1\}E' <<< "${text}" | grep -c . || true)
  for ((k = 0; k < n; k++)); do text+=$'\nx\nE'; done
  jq -nc --arg id "$1" --argjson data "$2" --arg text "${text}"$'\n' '{id: $id, data: $data, text: $text}'
}

measure() {
  local base="$1" forms="$2" mgr="$3" trees="$4" want w n line id data force text ran row t
  shift 4
  w=$(mktemp -d "${base}/work.XXXXXX")
  # shellcheck disable=SC2064
  trap "rm -rf '${w}'" EXIT
  mkdir -p "${w}/stub" "${w}/project" "${w}/home" "${w}/cwd"
  printf '{"dependencies":{}}\n' > "${w}/project/package.json"
  if [[ "${mgr}" == npm ]]; then want='ci'; else want='install evil==6.6.6'; fi
  # shellcheck disable=SC2016
  printf '#!/bin/sh\n[ "$*" = "%s" ] && echo ran >> "$MARK"\nexit 0\n' "${want}" > "${w}/stub/${mgr}"
  chmod +x "${w}/stub/${mgr}"
  for n in "$@"; do
    line=$(sed -n "${n}p" "${forms}")
    id=$(jq -r .id <<< "${line}"); data=$(jq -r .data <<< "${line}"); force=$(jq -r '.force // false' <<< "${line}")
    text=$(jq -r .text <<< "${line}"); text="${text//@@HEAD@@/${mgr}}"
    ran=""
    ran_in "${w}" "${text}" /bin/bash -c && ran+="b"
    ran_in "${w}" "${text}" /bin/zsh -f -c && ran+="z"
    ran_in "${w}" "${text}" /bin/sh -c && ran+="s"
    ran_in "${w}" "${text}" /bin/dash -c && ran+="d"
    row="${id}	${data}	${ran:--}"
    if [[ "${trees}" != - ]] && { [[ -n "${ran}" || "${data}" == true || "${force}" == true || -n "${ALL:-}" ]]; }; then
      for t in ${trees//,/ }; do row+="	${t}=$(decide "${w}" "${base}/${t}" "${text}")"; done
    fi
    printf '%s\n' "${row}"
  done
}

ran_in() { # work text shell argv...
  local w="$1" text="$2" m="$1/mark"
  shift 2
  rm -f "${m}"
  (cd "${w}/cwd" && MARK="${m}" PATH="${w}/stub:/usr/bin:/bin" perl -e 'alarm 5; exec @ARGV' "$@" "${text}" </dev/null >/dev/null 2>&1) || true
  [[ -s "${m}" ]]
}

decide() { # work tree command
  local w="$1" tree="$2" cmd="$3" out safe
  safe=$(mktemp -d "${w}/safe.XXXXXX")
  out=$(cd "${tree}" && jq -nc --arg c "${cmd}" --arg cwd "${w}/project" \
    '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}' |
    HOME="${w}/home" SAFEDEPS_HOME="${safe}" perl -e 'alarm 60; exec @ARGV' scripts/safedeps-pre-guard.sh 2>/dev/null) || true
  rm -rf "${safe}"
  if [[ -z "${out}" ]]; then printf 'pass'; return; fi
  jq -r '.hookSpecificOutput as $h
    | if ($h.permissionDecision // "") == "deny" then
        "deny:" + (($h.permissionDecisionReason // "") | gsub("\n";" ")
          | if test("install not approved") then "notapproved"
            elif test("UNDECIDED") then "undecided"
            else .[0:40] end)
      elif ($h.updatedInput.command // "") | test("--ignore-scripts") then "rewrite"
      else ($h.permissionDecision // "pass") end' <<< "${out}"
}

case "${1:-}" in
  generate) generate "${2:-pip}" ;;
  measure) shift; measure "$@" ;;
  *) printf 'usage: %s generate pip|npm | measure <dir> <forms> <pip|npm> <trees|-> <line>...\n' "$0" >&2; exit 2 ;;
esac
