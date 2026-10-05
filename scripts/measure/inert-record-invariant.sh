#!/usr/bin/env bash
# The forms are shell text kept literal.
# shellcheck disable=SC2016
# The inert record invariant: wherever a command the pre-guard lets run makes
# an npm call that does not read ignore-scripts true, the pre-guard recorded
# that in advisory.log. Judgment only. Each form goes to one tree's pre-guard
# as a PreToolUse payload; the command that would run -- the rewrite the
# pre-guard sent, or the command as written where it sent none -- then runs
# under bash and zsh with a stub `npm` that writes down its argv and does
# nothing else. No package manager runs, and nothing is installed.
#
# A form is
#
#   denied      the pre-guard denied it, so nothing runs
#   flagged     every npm call reads ignore-scripts true (or no npm call ran)
#   recorded    some npm call does not, and advisory.log holds an inert record:
#               a downgrade, a floor, a release-only rewrite, a word the shell
#               decides, or an npm install verb in text the rewrite did not
#               read as a command
#   VIOLATION   some npm call does not, the pre-guard read the command as an
#               install (it wrote a snapshot record), and advisory.log holds no
#               inert record: a flag nobody placed, and nothing said
#   unjudged    some npm call does not, and the pre-guard did not read the
#               command as an install at all (no snapshot record, no inert
#               record). That is the recognizers' boundary, not the rewrite's:
#               the inert rewrite runs only for a command they call an npm
#               install. It is listed, never counted as passing.
#
# The sets, each a file in scripts/measure:
#
#   grid   the 292 forms of inert-downgrade-grid.sh (read with --forms-only)
#   ext    inert-record-forms.json .forms: the validator's probes of the rounds
#          that found an install in text the rewrite did not read passing
#          with no record, and one form per kind of such text
#   probe  inert-record-forms.json .probes: the third round's 21 forms (r3)
#          with four controls, and text the shell decodes or builds (e). An
#          e form whose scope is `cmp` is text another program computes at run
#          time (printf octal, base64, rev, tr, parameter pieces): no byte of
#          the command spells the install, so it is the effect gate's, and it
#          is listed by name, never counted as a violation
#   gen    inert-record-gen.jsonl, written by inert-record-gen.py from the
#          shells' own option, builtin and reserved-word tables and the
#          redirection and expansion sections of bash(1) and zsh(1)
#   var    inert-record-variants.jsonl, written by inert-record-variants.py:
#          one form per shape of the gen forms that made an unflagged npm
#          call on 5b5a775, with the script `npm ci` (F2) and beside an
#          install that already has the flag (S1)
#   data   inert-record-data.jsonl, written by inert-record-data.py: install
#          text that is data beside an install. A record there is noise, the
#          cost of the byte rule, and is counted, never failed
#
# Each run has a fresh working directory holding a directory `d` (forms `cd
# "d"`), and a shell the host lacks (mksh, fish, ...) is a stub that hands the
# script to /bin/sh, so a row reaches its npm instead of failing quietly before
# it. A run whose stderr says "not found" or "No such file" is marked `vac`
# and listed. inert-record-reach.tsv names the least number of npm calls a
# form makes in bash or zsh; a form that makes fewer is listed as SHORT and
# fails the run, because a row that never reaches its npm cannot fail.
#
# usage: scripts/measure/inert-record-invariant.sh [--jobs N] [--out DIR] [--sets LIST]
#                                                   [--reach-out FILE] [--tree DIR | <ref>]
#
# The default ref is HEAD, archived with `git archive`; `.` is the working tree
# as it is. --tree judges a tree already on disk, such as a mutated copy. The
# forms always come from this checkout. --sets is a comma list of the sets
# above (default: all). --reach-out writes, for every form of grid, ext, probe
# and var that was not denied, the larger of its bash and zsh call counts:
# that file, once read, becomes inert-record-reach.tsv. It exits 1 when any
# form outside cmp is a VIOLATION or any form is SHORT. At most 2 jobs, for the
# reason the grid gives: the guard's own budget turns a loaded machine into
# denies.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
M="${ROOT_DIR}/scripts/measure"
jobs=2 out="" tree_dir="" sets="grid,ext,probe,gen,var,data" reach_out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --jobs) jobs="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --tree) tree_dir="$2"; shift 2 ;;
    --sets) sets="$2"; shift 2 ;;
    --reach-out) reach_out="$2"; shift 2 ;;
    -h|--help) awk 'NR > 3 && /^#/ { sub(/^# ?/, ""); print; next } NR > 3 { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) break ;;
  esac
done
ref="${1:-HEAD}"
case "${jobs}" in 1|2) ;; *) printf 'inert-record-invariant: --jobs is 1 or 2\n' >&2; exit 2 ;; esac
for s in ${sets//,/ }; do
  case "${s}" in grid|ext|probe|gen|var|data) ;; *) printf 'inert-record-invariant: unknown set %s\n' "${s}" >&2; exit 2 ;; esac
done
want() { [[ ",${sets}," == *",$1,"* ]]; }

W="${out:-$(mktemp -d "${TMPDIR:-/tmp}/inert-record-invariant.XXXXXX")}"
mkdir -p "${W}/stub" "${W}/forms" "${W}/run" "${W}/project"
W=$(cd "${W}" && pwd)

if [[ -n "${tree_dir}" ]]; then
  T=$(cd "${tree_dir}" && pwd)
  printf 'tree\t%s\n' "${T}" > "${W}/refs.tsv"
else
  T="${W}/tree"
  mkdir -p "${T}"
  if [[ "${ref}" == . ]]; then
    (cd "${ROOT_DIR}" && git ls-files -z --cached --others --exclude-standard | xargs -0 tar -cf -) | tar -xf - -C "${T}"
  else
    (cd "${ROOT_DIR}" && git archive "${ref}") | tar -xf - -C "${T}"
  fi
  printf 'ref\t%s\t%s%s\n' "${ref}" "$(cd "${ROOT_DIR}" && git rev-parse --short "${ref/#./HEAD}")" \
    "$([[ "${ref}" == . && -n "$(cd "${ROOT_DIR}" && git status --porcelain)" ]] && printf '+changes')" > "${W}/refs.tsv"
fi
for s in bash zsh; do printf 'shell\t%s\t%s\n' "${s}" "$(command -v "${s}" || printf missing)"; done >> "${W}/refs.tsv"
printf 'sets\t%s\n' "${sets}" >> "${W}/refs.tsv"

# ---- forms: <set>-<id>.cmd, .tag, .scope -----------------------------------
put_form() { # <file id> <scope> <tag> <cmd>
  printf '%s' "$4" > "${W}/forms/$1.cmd"; printf '%s' "$3" > "${W}/forms/$1.tag"; printf '%s' "$2" > "${W}/forms/$1.scope"
}
from_jsonl() { # <set>, rows {id, tag, cmd[, scope]} on stdin
  local row id cmd
  while IFS= read -r row; do
    [[ -n "${row}" ]] || continue
    id=$(jq -r '.id' <<< "${row}")
    cmd=$(jq -j '.cmd' <<< "${row}"; printf x); cmd=${cmd%x}
    put_form "$1-${id}" "$(jq -r '.scope // "lit"' <<< "${row}")" "$(jq -j '.tag' <<< "${row}")" "${cmd}"
  done
}
if want grid; then
  bash "${M}/inert-downgrade-grid.sh" --forms-only "${W}/grid-forms" > /dev/null
  for f in "${W}"/grid-forms/*.cmd; do
    id=${f##*/}; id=${id%.cmd}
    cp "${f}" "${W}/forms/grid-${id}.cmd"; cp "${f%.cmd}.tag" "${W}/forms/grid-${id}.tag"; printf lit > "${W}/forms/grid-${id}.scope"
  done
fi
if want ext; then jq -c '.forms[]' "${M}/inert-record-forms.json" | from_jsonl ext; fi
if want probe; then jq -c '.probes[]' "${M}/inert-record-forms.json" | from_jsonl probe; fi
if want gen; then from_jsonl gen < "${M}/inert-record-gen.jsonl"; fi
if want var; then from_jsonl var < "${M}/inert-record-variants.jsonl"; fi
if want data; then from_jsonl data < "${M}/inert-record-data.jsonl"; fi
: > "${W}/reach.tsv"
[[ ! -f "${M}/inert-record-reach.tsv" ]] || cp "${M}/inert-record-reach.tsv" "${W}/reach.tsv"

printf '{"name":"p","version":"1.0.0","dependencies":{}}\n' > "${W}/project/package.json"
printf '{"name":"p","version":"1.0.0","lockfileVersion":3,"requires":true,"packages":{"":{"name":"p","version":"1.0.0"}}}\n' > "${W}/project/package-lock.json"
cat > "${W}/stub/npm" <<'EOF'
#!/bin/sh
{ printf 'CALL'; for a in "$@"; do printf '\t%s' "$a"; done; printf '\n'; } >> "$NPMLOG"
EOF
# A shell the host lacks runs the script with /bin/sh, so the row reaches its
# npm; one the forms name and the host has is left alone.
for s in mksh fish pdksh yash posh ksh; do
  command -v "${s}" > /dev/null 2>&1 || printf '#!/bin/sh\nshift\nexec /bin/sh -c "$1"\n' > "${W}/stub/${s}"
done
chmod +x "${W}"/stub/*

# The pre-guard's inert records, by the words each one starts with. The last
# two are the same record before and after its wording became a fact
# sentence, so an older tree is read the same way.
INERT_RECORD_RE='pre-guard: (could not make every npm install in this command inert|an npm install in this command has no place where safedeps could read|could not place --ignore-scripts by reading|an npm install in this command holds a word the shell decides|an npm install in this command is in text safedeps could not read|text of this command that safedeps did not read as a command)'

calls() { # stdin: CALL lines; prints "<calls> <calls that do not read ignore-scripts true>"
  awk -F'\t' 'BEGIN { c = 0; u = 0 }
    $1 == "CALL" { c++; v = 0
      for (i = 2; i <= NF; i++) { a = $i; if (a == "--") break
        if (a == "--ignore-scripts" || a == "--ignore-scripts=true") v = 1
        else if (a == "--ignore-scripts=false" || a == "--no-ignore-scripts") v = 0 }
      if (!v) u++ }
    END { print c, u }'
}
runcmd() { # <outer shell> <command> <dir>: npm log and stderr in <dir>
  local name=${1##*/} c
  c="$3/cwd.${name}"
  : > "$3/npm.${name}"; : > "$3/err.${name}"
  [[ -x "$1" ]] || return 0
  rm -rf "${c}"; mkdir -p "${c}/d"
  (cd "${c}" && env -i HOME="${c}" ZDOTDIR="${c}" PATH="${W}/stub:/usr/bin:/bin" NPMLOG="$3/npm.${name}" \
      perl -e 'alarm 10; exec @ARGV' "$1" -c "$2" < /dev/null > /dev/null 2> "$3/err.${name}") || true
  rm -rf "${c}"
}
judge() { # <form id>
  local id=$1 r cmd out dec rw run payload cb ub cz uz rec judged verdict vac reach short
  r="${W}/run/${id}"
  cmd=$(cat "${W}/forms/${id}.cmd"; printf x); cmd=${cmd%x}
  rm -rf "${r}"; mkdir -p "${r}/h" "${r}/s"
  payload=$(jq -nc --arg command "${cmd}" --arg cwd "${W}/project" --arg id "toolu_inv${id}" \
    '{tool_name:"Bash",tool_input:{command:$command},cwd:$cwd,tool_use_id:$id,session_id:"inv",hook_event_name:"PreToolUse"}')
  out=$(cd "${W}/project" && printf '%s' "${payload}" | HOME="${r}/h" SAFEDEPS_HOME="${r}/s" \
    nice -n 10 bash "${T}/scripts/safedeps-pre-guard.sh" 2> "${r}/err") || true
  printf '%s' "${out}" > "${r}/out.json"
  dec=$(jq -r '.hookSpecificOutput.permissionDecision // "none"' <<< "${out:-{\}}" 2> /dev/null) || dec=none
  rw=""
  if jq -e '.hookSpecificOutput.updatedInput.command' <<< "${out:-{\}}" > /dev/null 2>&1; then
    jq -j '.hookSpecificOutput.updatedInput.command' <<< "${out}" > "${r}/rw"
    rw=$(cat "${r}/rw"; printf x); rw=${rw%x}
  fi
  rec=$(grep -cE "${INERT_RECORD_RE}" "${r}/s/advisory.log" 2> /dev/null || true)
  rec=${rec:-0}
  judged=no
  if compgen -G "${r}/s/snapshots/*_meta.json" > /dev/null; then judged=yes; fi
  cb=- ub=- cz=- uz=- vac=- short=-
  if [[ "${dec}" == deny ]]; then
    verdict=denied
  else
    run="${rw:-${cmd}}"
    runcmd /bin/bash "${run}" "${r}"; read -r cb ub < <(calls < "${r}/npm.bash")
    if [[ -x /bin/zsh ]]; then runcmd /bin/zsh "${run}" "${r}"; read -r cz uz < <(calls < "${r}/npm.zsh"); else cz="${cb}" uz="${ub}"; fi
    if (( ub == 0 && uz == 0 )); then verdict=flagged
    elif (( rec > 0 )); then verdict=recorded
    elif [[ "${judged}" == yes ]]; then verdict=VIOLATION
    else verdict=unjudged
    fi
    if grep -qiE 'not found|No such file' "${r}/err.bash" "${r}/err.zsh" 2> /dev/null; then vac=vac; fi
    reach=$(awk -F'\t' -v id="${id}" '$1 == id { print $2 }' "${W}/reach.tsv")
    if [[ -n "${reach}" ]] && (( (cb > cz ? cb : cz) < reach )); then short=SHORT; fi
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${id}" "${id%%-*}" "$(cat "${W}/forms/${id}.scope")" \
    "${dec}" "$([[ -n "${rw}" ]] && printf rw || printf -)" "${cb}" "${ub}" "${cz}" "${uz}" "${rec}" "${judged}" "${verdict}" "${vac}" "${short}" > "${r}/cell"
}
export -f judge calls runcmd
export W T INERT_RECORD_RE

uptime > "${W}/uptime.start"; date +%s > "${W}/t.start"
for f in "${W}"/forms/*.cmd; do
  id=${f##*/}; printf '%s\n' "${id%.cmd}"
done | xargs -P "${jobs}" -n 1 bash -c 'judge "$0"'
uptime > "${W}/uptime.end"; date +%s > "${W}/t.end"

{
  printf 'id\tset\tscope\tdecision\trewrite\tcalls_bash\tunflagged_bash\tcalls_zsh\tunflagged_zsh\tinert_records\tjudged\tverdict\tvac\treach\ttag\tform\n'
  for f in "${W}"/forms/*.cmd; do
    id=${f##*/}; id=${id%.cmd}
    printf '%s\t%s\t%s\n' "$(cat "${W}/run/${id}/cell")" "$(tr '\n\t' '~ ' < "${W}/forms/${id}.tag")" "$(tr '\n\t' '~ ' < "${f}")"
  done
} > "${W}/table.tsv"
if [[ -n "${reach_out}" ]]; then
  awk -F'\t' 'NR > 1 && $2 != "gen" && $2 != "data" && $3 == "lit" && $12 != "denied" { c = ($6 > $8) ? $6 : $8; if (c > 0) print $1 "\t" c }' \
    "${W}/table.tsv" | LC_ALL=C sort > "${reach_out}"
fi

printf 'inert-record-invariant: %s\n' "${W}/table.tsv"
cat "${W}/refs.tsv"
printf 'load\tstart\t%s\nload\tend\t%s\nseconds\t%s\n' "$(cat "${W}/uptime.start")" "$(cat "${W}/uptime.end")" \
  "$(( $(cat "${W}/t.end") - $(cat "${W}/t.start") ))"
awk -F'\t' 'NR > 1 { s = $2; v = $12; c[s "\t" v]++; t[s]++; all[v]++; n++
    if (v == "VIOLATION" || v == "unjudged") print v "\t" $1 "\t" $16
    if ($3 == "cmp") print "cmp\t" $1 "\t" v "\t" $16
    if ($13 == "vac") print "vac\t" $1 "\t" v "\t" $16
    if ($14 == "SHORT") print "SHORT\t" $1 "\t" v "\t" $16
    if (s == "data" && $10 > 0) { noise++; print "noise\t" $1 "\t" v "\t" $15 } }
  END {
    for (k in c) print "set\t" k "\t" c[k]
    for (k in t) print "set\t" k "\tforms\t" t[k]
    for (k in all) print "all\t" k "\t" all[k]
    print "all\tforms\t" n
    print "noise\tdata forms with an inert record\t" noise + 0
  }' "${W}/table.tsv" | LC_ALL=C sort
violations=$(awk -F'\t' 'NR > 1 && $12 == "VIOLATION" && $3 != "cmp"' "${W}/table.tsv" | wc -l | tr -d ' ')
shorts=$(awk -F'\t' 'NR > 1 && $14 == "SHORT"' "${W}/table.tsv" | wc -l | tr -d ' ')
printf 'violations\t%s\nshort\t%s\n' "${violations}" "${shorts}"
(( violations == 0 && shorts == 0 ))
