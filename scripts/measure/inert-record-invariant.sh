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
#               decides, or text the rewrite could not read
#   VIOLATION   some npm call does not, the pre-guard read the command as an
#               install (it wrote a snapshot record), and advisory.log holds no
#               inert record: a flag nobody placed, and nothing said
#   unjudged    some npm call does not, and the pre-guard did not read the
#               command as an install at all (no snapshot record, no inert
#               record). That is the recognizers' boundary, not the rewrite's:
#               the inert rewrite runs only for a command they call an npm
#               install. It is listed, never counted as passing.
#
# The forms are the 292 of scripts/measure/inert-downgrade-grid.sh (read with
# its --forms-only) and those in scripts/measure/inert-record-forms.json: the
# validator's probes of the two rounds that found an install in text the
# rewrite cannot read passing with no flag and no record (s002 and s004 beside
# an install already settled, x005 and x006 in a heredoc body fed to a shell
# and piped on), and one form per kind of text the rewrite does not read, each
# beside an install it flags.
#
# usage: scripts/measure/inert-record-invariant.sh [--jobs N] [--out DIR] [--tree DIR | <ref>]
#
# The default ref is HEAD, archived with `git archive`; `.` is the working tree
# as it is. --tree judges a tree already on disk, such as a mutated copy. It
# exits 1 when any form is a VIOLATION. At most 2 jobs, for the reason the
# grid gives: the guard's own budget turns a loaded machine into denies.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
jobs=2 out="" tree_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --jobs) jobs="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --tree) tree_dir="$2"; shift 2 ;;
    -h|--help) awk 'NR > 3 && /^#/ { sub(/^# ?/, ""); print; next } NR > 3 { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) break ;;
  esac
done
ref="${1:-HEAD}"
case "${jobs}" in 1|2) ;; *) printf 'inert-record-invariant: --jobs is 1 or 2\n' >&2; exit 2 ;; esac

W="${out:-$(mktemp -d "${TMPDIR:-/tmp}/inert-record-invariant.XXXXXX")}"
mkdir -p "${W}/stub" "${W}/forms" "${W}/home" "${W}/run" "${W}/project"
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

# The forms come from this checkout, whatever tree is judged, so a mutated copy
# is judged on the same forms.
bash "${ROOT_DIR}/scripts/measure/inert-downgrade-grid.sh" --forms-only "${W}/grid-forms" > /dev/null
for f in "${W}"/grid-forms/*.cmd; do
  id=${f##*/}; id=${id%.cmd}
  cp "${f}" "${W}/forms/grid-${id}.cmd"; cp "${W}/grid-forms/${id}.tag" "${W}/forms/grid-${id}.tag"
done
jq -c '.forms[]' "${ROOT_DIR}/scripts/measure/inert-record-forms.json" | while IFS= read -r row; do
  id=$(jq -r '.id' <<< "${row}")
  jq -j '.cmd' <<< "${row}" > "${W}/forms/ext-${id}.cmd"
  jq -j '.tag' <<< "${row}" > "${W}/forms/ext-${id}.tag"
done

printf '{"name":"p","version":"1.0.0","dependencies":{}}\n' > "${W}/project/package.json"
printf '{"name":"p","version":"1.0.0","lockfileVersion":3,"requires":true,"packages":{"":{"name":"p","version":"1.0.0"}}}\n' > "${W}/project/package-lock.json"
cat > "${W}/stub/npm" <<'EOF'
#!/bin/sh
{ printf 'CALL'; for a in "$@"; do printf '\t%s' "$a"; done; printf '\n'; } >> "$NPMLOG"
EOF
chmod +x "${W}/stub/npm"

# The pre-guard's inert records, by the words each one starts with.
INERT_RECORD_RE='pre-guard: (could not make every npm install in this command inert|an npm install in this command has no place where safedeps could read|could not place --ignore-scripts by reading|an npm install in this command holds a word the shell decides|an npm install in this command is in text safedeps could not read)'

unflagged() { # stdin: CALL lines; prints how many calls do not read ignore-scripts true
  awk -F'\t' 'BEGIN { u = 0 }
    $1 == "CALL" { v = 0
      for (i = 2; i <= NF; i++) { a = $i; if (a == "--") break
        if (a == "--ignore-scripts" || a == "--ignore-scripts=true") v = 1
        else if (a == "--ignore-scripts=false" || a == "--no-ignore-scripts") v = 0 }
      if (!v) u++ }
    END { print u }'
}
runcmd() { # <outer shell> <command> <log>
  : > "$3"
  [[ -x "$1" ]] || return 0
  (cd "${W}/home" && env -i HOME="${W}/home" ZDOTDIR="${W}/home" PATH="${W}/stub:/usr/bin:/bin" NPMLOG="$3" \
      perl -e 'alarm 10; exec @ARGV' "$1" -c "$2" < /dev/null > /dev/null 2>&1) || true
}
judge() { # <form id>
  local id=$1 r cmd out dec rw run payload ub uz rec judged verdict
  r="${W}/run/${id}"
  cmd=$(cat "${W}/forms/${id}.cmd"; printf x); cmd=${cmd%x}
  mkdir -p "${r}/h" "${r}/s"
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
  ub=- uz=-
  if [[ "${dec}" == deny ]]; then
    verdict=denied
  else
    run="${rw:-${cmd}}"
    runcmd /bin/bash "${run}" "${r}/npm.bash"; ub=$(unflagged < "${r}/npm.bash")
    if [[ -x /bin/zsh ]]; then runcmd /bin/zsh "${run}" "${r}/npm.zsh"; uz=$(unflagged < "${r}/npm.zsh"); else uz="${ub}"; fi
    if (( ub == 0 && uz == 0 )); then verdict=flagged
    elif (( rec > 0 )); then verdict=recorded
    elif [[ "${judged}" == yes ]]; then verdict=VIOLATION
    else verdict=unjudged
    fi
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${id}" "${dec}" "$([[ -n "${rw}" ]] && printf rw || printf -)" \
    "${ub}" "${uz}" "${rec}" "${judged}" "${verdict}" > "${r}/cell"
}
export -f judge unflagged runcmd
export W T INERT_RECORD_RE

uptime > "${W}/uptime.start"
for f in "${W}"/forms/*.cmd; do
  id=${f##*/}; printf '%s\n' "${id%.cmd}"
done | xargs -P "${jobs}" -n 1 bash -c 'judge "$0"'
uptime > "${W}/uptime.end"

{
  printf 'id\tdecision\trewrite\tunflagged_bash\tunflagged_zsh\tinert_records\tjudged\tverdict\ttag\tform\n'
  for f in "${W}"/forms/*.cmd; do
    id=${f##*/}; id=${id%.cmd}
    printf '%s\t%s\t%s\n' "$(cat "${W}/run/${id}/cell")" "$(cat "${W}/forms/${id}.tag")" "$(tr '\n' '~' < "${f}")"
  done
} > "${W}/table.tsv"

printf 'inert-record-invariant: %s\n' "${W}/table.tsv"
cat "${W}/refs.tsv"
printf 'load\tstart\t%s\nload\tend\t%s\n' "$(cat "${W}/uptime.start")" "$(cat "${W}/uptime.end")"
awk -F'\t' 'NR > 1 { src = ($1 ~ /^grid-/) ? "grid" : "ext"; v[src "\t" $8]++; t[src]++; all[$8]++; n++
    if ($8 == "VIOLATION" || $8 == "unjudged") print $8 "\t" $1 "\t" $10 }
  END {
    for (k in v) print "set\t" k "\t" v[k]
    for (k in t) print "set\t" k "\tforms\t" t[k]
    for (k in all) print "all\t" k "\t" all[k]
    print "all\tforms\t" n
  }' "${W}/table.tsv" | LC_ALL=C sort
violations=$(awk -F'\t' 'NR > 1 && $8 == "VIOLATION"' "${W}/table.tsv" | wc -l | tr -d ' ')
printf 'violations\t%s\n' "${violations}"
(( violations == 0 ))
