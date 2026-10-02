#!/usr/bin/env bash
# safedeps: the shell's redirection grammar as a grid of forms, measured.
#
# Three review rounds each found a redirection the lexer read unlike the shell
# (a target that is a process substitution, a `{varname}` descriptor word, a
# redirection between a manager and its verb), and each time the form was one
# no corpus held. So the forms are not picked one by one here: every operator
# the manuals list is put in every place a redirection can stand, and the
# shells say which of them run the install.
#
# The tables:
#
#   operators  bash REDIRECTION: [n]< [n]> [n]>| [n]>> &> &>> [n]>& [n]<&
#              [n]<> << <<- <<< [n]>&- [n]<&- [n]<&digit-, each with a
#              number and with bash's {varname} in front where the manual
#              allows one. zsh: >! >>! >>| &>| &>! >&| >&! >>& >>&| >>&!
#              &>>| &>>!. dash: the POSIX subset, where &> is & then >.
#   places     before the command, between the command word and its
#              arguments, among the arguments, after them; after a
#              separator, &&, a pipe, an assignment, env, command, exec, !,
#              time and another redirection; inside a function body, a
#              group, a subshell and an if; and two data places, where the
#              install words are arguments to echo.
#   targets    the target word as the lexer must cut it: plain, after a
#              blank, quoted, glued quoting, escaped, a substitution, a
#              backquote, a parameter expansion, a process substitution
#              (with a blank inside, a quoted parenthesis, a redirection of
#              its own), the empty word. Crossed with four operators and
#              three places.
#
# Each form names its command word @@HEAD@@ and its arguments
# `install evil==6.6.6` (see scripts/measure/shell-reading-measure.sh): the
# measurement runs a stub that marks only those exact arguments, and the gate
# battery reads `pip`.
#
# Usage:
#   scripts/measure/redirection-grid.sh generate   the grid, unmeasured
#   scripts/measure/redirection-grid.sh record     regenerate, keep the other
#       platform's measured values for forms whose text did not change,
#       measure this platform, and write scripts/measure/redirection-grid.json
#   scripts/measure/redirection-grid.sh check      the committed grid is the
#       generated one, this platform measures what it records, and the gate
#       judges every form a shell runs and leaves the data forms alone
#
# On macOS, SAFEDEPS_MEASURE_BASH5=<path to a bash 5> adds the bash5 column
# (bash 4.1 and later read {fd} as a descriptor; /bin/bash 3.2 does not).
# Both platforms record into one file: run `record` on macOS and on Linux.
set -uo pipefail
# bash 5.2 reads `&` in the replacement of ${var//pattern/replacement} as the
# matched text, and the operators below are full of `&`: on Linux the grid
# came out with other forms under the same ids than on macOS (bash 3.2).
shopt -u patsub_replacement 2>/dev/null || true

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GRID="${ROOT_DIR}/scripts/measure/redirection-grid.json"
ARGS='install evil==6.6.6'

# id <TAB> spelling, with T where the target goes and B where a heredoc
# delimiter goes <TAB> default target
OPERATORS='in	<T	/dev/null
out	>T	/dev/null
clobber	>|T	/dev/null
append	>>T	/dev/null
rw	<>T	/dev/null
dupin	<&T	0
dupout	>&T	2
dupword	>&T	/dev/null
closein	<&-
closeout	>&-
herestring	<<<T	x
heredoc	<<B
heredocstrip	<<-B
both	&>T	/dev/null
bothappend	&>>T	/dev/null
n-out	2>T	/dev/null
n-in	0<T	/dev/null
n-clobber	2>|T	/dev/null
n-append	2>>T	/dev/null
n-rw	3<>T	/dev/null
n-dup	2>&T	1
n-dupin	3<&T	0
n-close	2>&-
n-move	4<&0-
n-herestring	0<<<T	x
n-heredoc	0<<B
n-wide	10>T	/dev/null
v-out	{fd}>T	/dev/null
v-in	{fd}<T	/dev/null
v-clobber	{fd}>|T	/dev/null
v-append	{fd}>>T	/dev/null
v-rw	{fd}<>T	/dev/null
v-dup	{fd}>&T	2
v-dupin	{fd}<&T	0
v-herestring	{fd}<<<T	x
v-heredoc	{fd}<<B
z-bang	>!T	/dev/null
z-appendbang	>>!T	/dev/null
z-appendbar	>>|T	/dev/null
z-bothbar	&>|T	/dev/null
z-bothbang	&>!T	/dev/null
z-dupbar	>&|T	/dev/null
z-dupbang	>&!T	/dev/null
z-appendboth	>>&T	/dev/null
z-appendbothbar	>>&|T	/dev/null
z-appendbothbang	>>&!T	/dev/null
z-bothappendbar	&>>|T	/dev/null
z-bothappendbang	&>>!T	/dev/null
z-bang-blank	>! T	/dev/null'

# id <TAB> template: %R is the redirection, %H the command word and its
# arguments, %C the command word alone and %A its arguments
PLACES='pre	%R %H
mid	%C %R %A
post	%C install %R evil==6.6.6
end	%H %R
sep	true; %R %H
and	true && %R %H
pipe	true | %R %H
assign	FOO=1 %R %H
assignafter	%R FOO=1 %H
env	env %R %H
command	command %R %H
exec	exec %R %H
bang	! %R %H
time	time %R %H
two	%R %R %H
func	f() { %R %H; }; f
group	{ %R %H; }
subshell	( %R %H )
if	if %R %H; then :; fi
data-echo	echo %R %H
data-lead	%R echo %H'

# id <TAB> target word (an operator reads it in place of T)
TARGETS='plain	/dev/null
blank	 /dev/null
dq	"/dev/null"
sq	'"'"'/dev/null'"'"'
glued	/dev/nu'"''"'ll
escaped	\/dev/null
subst	$(echo /dev/null)
substq	"$(echo /dev/null)"
substblank	$(echo  /dev/null )
backquote	`echo /dev/null`
param	${HOME:+/dev/null}
psin	<(true)
psinblank	 <(true)
psout	>(cat)
psoutblank	 >(cat)
psblanks	>(true; true)
psparen	>(echo ")" >/dev/null)
psredir	>(cat >/dev/null)
semi	'"'"'a;b'"'"'
empty	""'
TARGET_OPS='out in n-out v-out'
TARGET_PLACES='pre mid sep'

# The heredoc bodies a form needs: one per delimiter B, in order.
bodies() { # count
  local k out=""
  for ((k = 0; k < $1; k++)); do out+=$'\nx\nE'; done
  printf '%s' "${out}"
}

# One form: <id> <label> <redirection> <place template> <data?>
form() {
  local id="$1" label="$2" redir="$3" place="$4" data="$5" text n
  text="${place//%H/%C %A}"
  text="${text//%A/${ARGS}}"
  text="${text//%C/@@HEAD@@}"
  text="${text//%R/${redir}}"
  n=$(grep -o '<<-\{0,1\}E' <<< "${text}" | grep -c . || true)
  text="${text}$(bodies "${n}")"$'\n'
  jq -nc --arg id "${id}" --arg label "${label}" --arg text "${text}" --argjson data "${data}" \
    '{id: $id, cls: "R", label: $label, text: $text} + (if $data then {data: true} else {} end)'
}

generate() {
  local op spell target place tpl redir pid tid ttext
  {
    while IFS=$'\t' read -r op spell target; do
      redir="${spell//T/${target}}"
      redir="${redir//B/E}"
      while IFS=$'\t' read -r pid tpl; do
        form "RG-${op}-${pid}" "operator ${spell} (${op}) at ${pid}" "${redir}" "${tpl}" \
          "$([[ "${pid}" == data-* ]] && echo true || echo false)"
      done <<< "${PLACES}"
    done <<< "${OPERATORS}"
    while IFS=$'\t' read -r tid ttext; do
      for op in ${TARGET_OPS}; do
        spell=$(awk -F'\t' -v o="${op}" '$1 == o { print $2 }' <<< "${OPERATORS}")
        redir="${spell//T/${ttext}}"
        for pid in ${TARGET_PLACES}; do
          tpl=$(awk -F'\t' -v p="${pid}" '$1 == p { print $2 }' <<< "${PLACES}")
          form "RT-${tid}-${op}-${pid}" "target ${tid} after ${spell} at ${pid}" "${redir}" "${tpl}" false
        done
      done
    done <<< "${TARGETS}"
  } | jq -s '.'
}

# A data form the shells all leave alone has to stay data: the gate passes
# it. Set from the measured values, so a data form some shell does run (dash
# runs `echo a &>f pip install x`) is held to a verdict instead.
with_gate() {
  jq '[.[] | if .data and ([.measured | .. | strings | select(startswith("R"))] | length) == 0
             then . + {gate: "pass"} else del(.gate) end]'
}

case "${1:-check}" in
  generate)
    generate
    ;;
  record)
    work=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-grid.XXXXXX")
    trap 'rm -rf "${work}"' EXIT
    generate > "${work}/new.json"
    # The other platform's values carry over to a form whose text is the same.
    if [[ -f "${GRID}" ]]; then
      jq --slurpfile old "${GRID}" '
        ($old[0] | map({key: .id, value: .}) | from_entries) as $o
        | map(if ($o[.id] != null and $o[.id].text == .text and $o[.id].measured != null)
              then . + {measured: $o[.id].measured} else . end)' "${work}/new.json" > "${work}/merged.json"
    else
      cp "${work}/new.json" "${work}/merged.json"
    fi
    SAFEDEPS_SHELL_FORMS="${work}/merged.json" "${ROOT_DIR}/scripts/measure/shell-reading-measure.sh" --record \
      | with_gate > "${work}/out.json" || exit 1
    mv "${work}/out.json" "${GRID}"
    printf 'recorded %s forms in %s\n' "$(jq length "${GRID}")" "${GRID}"
    ;;
  check)
    rc=0
    work=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-grid.XXXXXX")
    trap 'rm -rf "${work}"' EXIT
    generate > "${work}/new.json"
    if [[ "$(jq -c 'map({id, text})' "${work}/new.json")" != "$(jq -c 'map({id, text})' "${GRID}")" ]]; then
      printf 'not ok - the committed grid is not the generated one: run record on each platform\n'
      rc=1
    else
      printf 'ok - the committed grid is the generated one (%s forms)\n' "$(jq length "${GRID}")"
    fi
    SAFEDEPS_SHELL_FORMS="${GRID}" "${ROOT_DIR}/scripts/measure/shell-reading-measure.sh" | tail -1 || rc=1
    SAFEDEPS_SHELL_FORMS="${GRID}" bash "${ROOT_DIR}/scripts/test/shell-reading.sh" "${@:2}" || rc=1
    exit "${rc}"
    ;;
  *)
    printf 'usage: %s generate|record|check [--count]\n' "$0" >&2
    exit 2
    ;;
esac
