#!/usr/bin/env bash
# The forms are shell text kept literal, and the script bodies are read through ${!v}.
# shellcheck disable=SC2016,SC2034
# The inert-rewrite grid: which commands each tree's pre-guard sends with an
# --ignore-scripts that npm reads. Judgment only. Each form goes to the
# pre-guard of two trees as a payload, and the rewrite each one sends is then
# run under bash and zsh with a stub `npm` that writes down its argv and does
# nothing else: no package manager runs, and nothing is installed. A cell is
#
#   Y   a rewrite, and every npm call it makes reads ignore-scripts true
#   N   a rewrite, and some npm call does not (the flag became `$0`, or went
#       after a word that ends npm's options)
#   -   a rewrite, and no npm call ran (the outer or inner shell is missing)
#   0   no rewrite
#   D   a deny
#
# with `/zsh:<cell>` added where zsh as the outer shell gave another cell, and
# `!calls:<a>><b>` where the rewrite made a different number of npm calls than
# the command as written. A form is LOSS where the base tree's cell is Y and the
# head tree's is neither Y nor D, GAIN where the head's is Y and the base's is
# not, and `same` otherwise. head_recorded counts the head's advisory.log lines
# that say it downgraded the install, could not place the flag, or did not read
# it.
#
# The forms are the v2.18.0 design judgment's grid (set g: shell carrier x
# quote x script content x statement position, 233 forms; set x: other escapes,
# substitutions and positions, 27; set h: an install beside a heredoc, 6) and
# the edges a review of its rule added (set b: the rule sentence and the doc
# examples, 20; set c: an npm spelled in another case inside a script, 6).
# The counts are counts of forms, not of how often anyone writes them.
#
# usage: scripts/measure/inert-downgrade-grid.sh [--jobs N] [--out DIR] [<base ref> [<head ref>]]
#        scripts/measure/inert-downgrade-grid.sh --forms-only DIR
#
# --forms-only writes the forms, as <id>.cmd and <id>.tag, into DIR and judges
# nothing: scripts/measure/inert-record-invariant.sh reads them from there.
# The defaults are bb0787d (v2.17.2, published) and HEAD. A ref is archived
# with `git archive`; `.` is the working tree as it is, uncommitted changes
# included. scripts/measure/inert-downgrade-rule.py reads the table this
# writes. At most 2 jobs: the guard runs its own judgment budget, and a loaded
# machine turns that into UNDECIDED denies, which the table would show as D.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
jobs=2 out="" forms_only=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --jobs) jobs="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --forms-only) forms_only="$2"; shift 2 ;;
    -h|--help) awk 'NR > 3 && /^#/ { sub(/^# ?/, ""); print; next } NR > 3 { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) break ;;
  esac
done
base_ref="${1:-bb0787d}" head_ref="${2:-HEAD}"
case "${jobs}" in 1|2) ;; *) printf 'inert-downgrade-grid: --jobs is 1 or 2\n' >&2; exit 2 ;; esac

W="${forms_only:-${out:-$(mktemp -d "${TMPDIR:-/tmp}/inert-downgrade-grid.XXXXXX")}}"
mkdir -p "${W}/forms"
W=$(cd "${W}" && pwd)

# ---- forms --------------------------------------------------------------
n=0 fset=""
add() { n=$((n + 1)); local id; id=$(printf '%s%03d' "${fset}" "${n}"); printf '%s' "$2" > "${W}/forms/${id}.cmd"; printf '%s' "$1" > "${W}/forms/${id}.tag"; }
NL=$'\n'

# g: script bodies by quote -- none, q (the other quote inside), esc (an
# escaped or closed-and-reopened own quote), subst $(), bq ``, var $X -- for
# each carrier, each in one statement, after `true;` and before `&& echo`.
fset=g n=0
dq_none='npm ci';              sq_none='npm ci'
dq_q="npm ci 'x'";             sq_q='npm ci "x"'
dq_esc='npm ci \"x\"';         sq_esc="npm ci '\\''x'\\''"
dq_subst='npm ci $(printf x)'; sq_subst='npm ci $(printf x)'
dq_bq='npm ci `printf x`';     sq_bq='npm ci `printf x`'
dq_var='npm ci $X';            sq_var='npm ci $X'
for car in "sh -c" "bash -c" "zsh -c" "dash -c" "ksh -c" "eval"; do
  for qu in dq sq; do
    for ib in none q esc subst bq var; do
      v="${qu}_${ib}"; body=${!v}
      if [[ "${qu}" == dq ]]; then s="${car} \"${body}\""; else s="${car} '${body}'"; fi
      add "${car}|${qu}|${ib}|one"  "${s}"
      add "${car}|${qu}|${ib}|pre"  "true; ${s}"
      add "${car}|${qu}|${ib}|post" "${s} && echo done"
    done
  done
done
add "sh -c|dq|esc|pre|install"   'true; sh -c "npm install x \"--loglevel=warn\""'
add "sh -c|dq|subst|pre|install" 'true; sh -c "npm install x $(printf y)"'
add "eval|dq|esc|one|install"    'eval "npm install x \"y\""'
add "sh -c|dq|esc|pre|cd"        'true; sh -c "cd . && npm ci \"x\""'
add "sh -c|dq|none|pre|cd"       'true; sh -c "cd . && npm ci"'
add "sh -c|dq|var|pre|var-only-elsewhere" 'true; sh -c "echo $X; npm ci"'
add "sh -c|dq|esc|pre|esc-elsewhere"      'true; sh -c "echo \"a\"; npm ci"'
add "heredoc|bash<<E|one"          "bash <<E${NL}npm ci${NL}E"
add "heredoc|bash<<'E'|one"        "bash <<'E'${NL}npm ci${NL}E"
add "heredoc|bash<<E|pre"          "true; bash <<E${NL}npm ci${NL}E"
add "heredoc|cat<<E|sh|one"        "cat <<E | sh${NL}npm ci${NL}E"
add "heredoc|cat<<E|sh|pre"        "true; cat <<E | sh${NL}npm ci${NL}E"
add "heredoc|npm&&cat<<E|wc|body-inert" "npm ci && cat <<E | wc -l${NL}npm install y${NL}E"
add "heredoc|npm;cat<<E|body-inert"     "npm ci; cat <<E${NL}npm install y${NL}E"
add "heredoc|cat<<E|wc;npm|body-inert"  "cat <<E | wc -l${NL}npm install y${NL}E${NL}npm ci"
add "heredoc|npm&&cat<<E>f|body-inert"  "npm ci && cat <<E > /dev/null${NL}npm install y${NL}E"
add "heredoc|bash<<E subst|one"    "bash <<E${NL}npm ci \$(printf x)${NL}E"

# x: other escapes, substitutions and positions.
fset=x n=0
add "sh -c|dq|esc-dollar|pre"     'true; sh -c "npm ci \$X"'
add "sh -c|dq|esc-letter|pre"     'true; sh -c "npm ci a\b"'
add "sh -c|dq|esc-bslash|pre"     'true; sh -c "npm ci a\\\\b"'
add "sh -c|dq|esc-bq|pre"         'true; sh -c "npm ci \`printf x\`"'
add "sh -c|dq|brace-var|pre"      'true; sh -c "npm ci ${X}"'
add "sh -c|dq|arith|pre"          'true; sh -c "npm ci $((1))"'
add "sh -c|dq|esc|subshell"       '(sh -c "npm ci \"x\"")'
add "sh -c|dq|esc|group"          '{ sh -c "npm ci \"x\""; }'
add "sh -c|dq|esc|if"             'if true; then sh -c "npm ci \"x\""; fi'
add "sh -c|dq|esc|pipe"           'sh -c "npm ci \"x\"" | cat'
add "sh -c|dq|esc|or"             'false || sh -c "npm ci \"x\""'
add "sh -c|dq|esc|cd&&"           'cd . && sh -c "npm ci \"x\""'
add "sh -c|dq|esc|one-redir"      'sh -c "npm ci \"x\"" > /dev/null'
add "sh -c|dq|esc|one-arg0"       'sh -c "npm ci \"x\"" sh'
add "bash -lc|dq|esc|pre"         'true; bash -lc "npm ci \"x\""'
add "sh -c|dq|esc|pre|i"          'true; sh -c "npm i x \"y\""'
add "sh -c|dq|esc|pre|install-flag-first" 'true; sh -c "npm install --save x \"y\""'
add "sh -c|dq|esc|pre|esc-before-npm"     'true; sh -c "echo \"a\" && npm ci"'
add "sh -c|dq|subst|pre|subst-before-npm" 'true; sh -c "echo $(printf a) && npm ci"'
add "sh -c|dq|none|pre|verb-quote-end"    'true; sh -c "npm ci"'
add "eval|dq|esc|pre"             'true; eval "npm ci \"x\""'
add "eval|dq|esc|one-redir"       'eval "npm ci \"x\"" > /dev/null'
add "eval|dq|subst|one"           'eval "npm ci $(printf x)"'
add "eval|dq|bq|one"              'eval "npm ci `printf x`"'
add "eval|dq|esc|one|install"     'eval "npm install x \"y\""'
add "eval|unquoted|one"           'eval npm ci \"x\"'
add "sh -c|dq|esc|two-installs"   'npm ci && sh -c "npm ci \"x\""'

# h: is a visible install beside a heredoc read at all.
fset=h n=0
add "npm;echo"                 'npm ci; echo x'
add "npm;cat<<E body=hello"    "npm ci; cat <<E${NL}hello${NL}E"
add "npm;cat<<E body=install"  "npm ci; cat <<E${NL}npm install y${NL}E"
add "npm&&cat<<E body=hello"   "npm ci && cat <<E${NL}hello${NL}E"
add "cat<<E;npm body=hello"    "cat <<E${NL}hello${NL}E${NL}npm ci"
add "bash<<E npm install x"    "bash <<E${NL}npm install x${NL}E"

# b: edges of the rule sentence and the doc examples.
fset=b n=0
add "ex|roadmap-gain-quote"       'true; sh -c "cd . && npm ci"'
add "ex|one-sq"                   "sh -c 'npm ci'"
add "ex|one-dq"                   'sh -c "npm ci"'
add "ex|one-dq-esc"               'sh -c "npm ci \"x\""'
add "ex|one-bash-dq"              'bash -c "npm ci"'
add "ex|roadmap-loss-ksh"         "true; ksh -c 'npm ci'"
add "ex|roadmap-loss-sh"          'true; sh -c "npm ci \"x\""'
add "ex|roadmap-loss-eval"        'eval "npm ci \"x\""'
add "ex|roadmap-loss-heredoc"     "npm ci && cat <<E | wc -l${NL}npm install y${NL}E"
add "edge|two-installs-one-ws"    'true; sh -c "npm ci \"x\" && npm ci"'
add "edge|ksh-no-npm-npm-outside" "true; ksh -c 'echo hi'; npm ci x"
add "edge|heredoc-pip-body"       "npm ci && cat <<E | wc -l${NL}pip install y${NL}E"
add "edge|heredoc-npm-ci-body"    "npm ci && cat <<E | wc -l${NL}npm ci${NL}E"
add "edge|ksh-lc"                 "true; ksh -lc 'npm ci x'"
add "edge|dq-dollar-paren-arith"  'true; zsh -c "npm ci $((1))"'
add "edge|dash-bq"                'true; dash -c "npm ci `printf x`"'
add "edge|eval-sq-esc"            "true; eval 'npm ci \"x\"'"
add "note|NPM-case"               'npm install x; sh -c "true && NPM ci"'
add "note|NPM-case-pre"           'true; sh -c "cd . && NPM ci"'
add "edge|or-deny"                'false || sh -c "npm ci \"x\""'

# c: an npm spelled in another case inside a script handed to a shell.
fset=c n=0
add "npmcase|readable-dq"        'npm install x; sh -c "true && NPM ci"'
add "npmcase|esc-dq"             'npm install x; sh -c "cd \"d\" && NPM ci"'
add "npmcase|subst-dq"           'npm install x; sh -c "cd $(pwd) && NPM ci"'
add "npmcase|sq"                 "npm install x; sh -c 'true && NPM ci'"
add "npmcase|esc-dq-alone"       'true; sh -c "cd \"d\" && NPM ci"'
add "ksh|sq-arg"                 "true; ksh -c 'npm ci x'"

if [[ -n "${forms_only}" ]]; then
  # The forms alone, for a reader that judges them its own way.
  mv "${W}"/forms/* "${W}/" && rmdir "${W}/forms"
  exit 0
fi
mkdir -p "${W}/stub" "${W}/home" "${W}/run" "${W}/tree/base" "${W}/tree/head" "${W}/project"

archive() { # <ref> <dir>
  if [[ "$1" == . ]]; then
    (cd "${ROOT_DIR}" && git ls-files -z --cached --others --exclude-standard | xargs -0 tar -cf -) | tar -xf - -C "$2"
  else
    (cd "${ROOT_DIR}" && git archive "$1") | tar -xf - -C "$2"
  fi
}
archive "${base_ref}" "${W}/tree/base"
archive "${head_ref}" "${W}/tree/head"
{
  printf 'base\t%s\t%s\n' "${base_ref}" "$(cd "${ROOT_DIR}" && git rev-parse --short "${base_ref/#./HEAD}")"
  printf 'head\t%s\t%s%s\n' "${head_ref}" "$(cd "${ROOT_DIR}" && git rev-parse --short "${head_ref/#./HEAD}")" \
    "$([[ "${head_ref}" == . && -n "$(cd "${ROOT_DIR}" && git status --porcelain)" ]] && printf '+changes')"
  for s in bash zsh sh dash ksh; do printf 'shell\t%s\t%s\n' "${s}" "$(command -v "${s}" || printf missing)"; done
} > "${W}/refs.tsv"

printf '{"name":"p","version":"1.0.0","dependencies":{}}\n' > "${W}/project/package.json"
printf '{"name":"p","version":"1.0.0","lockfileVersion":3,"requires":true,"packages":{"":{"name":"p","version":"1.0.0"}}}\n' > "${W}/project/package-lock.json"
cat > "${W}/stub/npm" <<'EOF'
#!/bin/sh
{ printf 'CALL'; for a in "$@"; do printf '\t%s' "$a"; done; printf '\n'; } >> "$NPMLOG"
EOF
chmod +x "${W}/stub/npm"

# ---- judge one form under one tree --------------------------------------
reads_flag() { # stdin: CALL lines; Y if every call reads ignore-scripts true, N if one does not, - if none ran
  awk -F'\t' 'BEGIN { c = 0; ok = 1 }
    $1 == "CALL" { c++; v = 0
      for (i = 2; i <= NF; i++) { a = $i; if (a == "--") break
        if (a == "--ignore-scripts" || a == "--ignore-scripts=true") v = 1
        else if (a == "--ignore-scripts=false" || a == "--no-ignore-scripts") v = 0 }
      if (!v) ok = 0 }
    END { if (c == 0) print "-"; else print (ok ? "Y" : "N") }'
}
runcmd() { # <outer shell> <command> <log>
  : > "$3"
  [[ -x "$1" ]] || return 0
  # The stub is the only npm on PATH. The original command runs only to count
  # its npm calls, against the same stub.
  (cd "${W}/home" && env -i HOME="${W}/home" ZDOTDIR="${W}/home" PATH="${W}/stub:/usr/bin:/bin" NPMLOG="$3" \
      perl -e 'alarm 10; exec @ARGV' "$1" -c "$2" < /dev/null > /dev/null 2>&1) || true
}
judge() { # <form id> <tree: base|head>
  local id=$1 tree=$2 cmd out dec rw r payload gb gz cnt0 cnt1 rec
  r="${W}/run/${id}-${tree}"
  cmd=$(cat "${W}/forms/${id}.cmd"; printf x); cmd=${cmd%x}
  mkdir -p "${r}/h" "${r}/s"
  payload=$(jq -nc --arg command "${cmd}" --arg cwd "${W}/project" --arg id "toolu_grid${id}${tree}" \
    '{tool_name:"Bash",tool_input:{command:$command},cwd:$cwd,tool_use_id:$id,session_id:"grid",hook_event_name:"PreToolUse"}')
  out=$(cd "${W}/project" && printf '%s' "${payload}" | HOME="${r}/h" SAFEDEPS_HOME="${r}/s" \
    nice -n 10 bash "${W}/tree/${tree}/scripts/safedeps-pre-guard.sh" 2> "${r}/err") || true
  printf '%s' "${out}" > "${r}/out.json"
  dec=$(jq -r '.hookSpecificOutput.permissionDecision // "none"' <<< "${out:-{\}}" 2> /dev/null) || dec=none
  rw=""
  if jq -e '.hookSpecificOutput.updatedInput.command' <<< "${out:-{\}}" > /dev/null 2>&1; then
    jq -j '.hookSpecificOutput.updatedInput.command' <<< "${out}" > "${r}/rw"
    rw=$(cat "${r}/rw"; printf x); rw=${rw%x}
  fi
  if [[ "${dec}" == deny ]]; then gb=D gz=D
  elif [[ -z "${rw}" ]]; then gb=0 gz=0
  else
    runcmd /bin/bash "${rw}" "${r}/npm.bash"; gb=$(reads_flag < "${r}/npm.bash")
    if [[ -x /bin/zsh ]]; then
      runcmd /bin/zsh "${rw}" "${r}/npm.zsh"; gz=$(reads_flag < "${r}/npm.zsh")
    else
      gz="${gb}"
    fi
    runcmd /bin/bash "${cmd}" "${r}/npm.orig"
    cnt0=$(grep -c '^CALL' "${r}/npm.orig" || true); cnt1=$(grep -c '^CALL' "${r}/npm.bash" || true)
    [[ "${cnt0}" == "${cnt1}" ]] || gb="${gb}!calls:${cnt0}>${cnt1}"
  fi
  rec=$(grep -c 'downgrad\|could not\|unread' "${r}/s/advisory.log" 2> /dev/null || true)
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${id}" "${tree}" "${dec}" "${gb}" "${gz}" "${rec:-0}" > "${r}/cell"
}
export -f judge reads_flag runcmd
export W

uptime > "${W}/uptime.start"
for f in "${W}"/forms/*.cmd; do
  id=${f##*/}; id=${id%.cmd}
  printf '%s base\n%s head\n' "${id}" "${id}"
done | xargs -P "${jobs}" -n 2 bash -c 'judge "$0" "$1"'
uptime > "${W}/uptime.end"

# ---- table --------------------------------------------------------------
cell() { awk -F'\t' '{ g = $4; if ($5 != $4) g = g "/zsh:" $5; print g }' "${W}/run/$1-$2/cell"; }
{
  printf 'id\tset\ttag\tbase\thead\thead_recorded\tverdict\tform\n'
  for f in "${W}"/forms/*.cmd; do
    id=${f##*/}; id=${id%.cmd}
    b=$(cell "${id}" base); h=$(cell "${id}" head)
    hr=$(cut -f6 "${W}/run/${id}-head/cell")
    v=same
    [[ "${b}" != Y || "${h}" == Y || "${h}" == D ]] || v=LOSS
    [[ "${h}" != Y || "${b}" == Y ]] || v=GAIN
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${id}" "${id:0:1}" "$(cat "${W}/forms/${id}.tag")" "${b}" "${h}" "${hr}" "${v}" "$(tr '\n' '~' < "${f}")"
  done
} > "${W}/table.tsv"

printf 'inert-downgrade-grid: %s\n' "${W}/table.tsv"
cat "${W}/refs.tsv"
printf 'load\tstart\t%s\nload\tend\t%s\n' "$(cat "${W}/uptime.start")" "$(cat "${W}/uptime.end")"
awk -F'\t' 'NR > 1 { n[$2]++; v[$2 "\t" $7]++; t++; tv[$7]++; if ($7 == "LOSS" && $6 > 0) rec++ }
  END {
    for (k in v) print "set\t" k "\t" v[k]
    for (k in tv) print "all\t" k "\t" tv[k]
    print "all\tforms\t" t
    print "all\tLOSS recorded by head\t" (rec + 0)
  }' "${W}/table.tsv" | LC_ALL=C sort
