#!/usr/bin/env bash
# safedeps: every lexing a guard run makes, for the lexing-trace oracle.
#
# scan-contract traces the lexings too, but it builds the texts it allows from
# the payload views' own records, cut at the separator the readers cut at. An
# oracle that reads a boundary the way the code reads it agrees with the code
# when both are wrong (verdict buri-20261005-181919: a \035 in a substitution
# body split it, for the readers and for the trace alike). So this only
# records what was lexed; lex-trace-oracle.py decides what was allowed, from
# the payloads the form generator built (payload-boundary-forms.py).
#
# An awk shim on PATH, as in scan-contract: shell_lex is the one awk called with
# a view and a policy, and the shim keeps its view, marker and input. One JSON
# line per form: {"id", "tree", "v": verdict, "lex": [[view, marker,
# base64(input)], ...]}. The guard only judges; nothing is installed.
#
# Usage (on a test host, one process; two at most):
#   lex-trace.sh <dir> <tree> <forms.jsonl> <line>... > trace.jsonl
#   <dir>/<tree> is a source tree; <line> numbers the forms to run.
set -u
base="$1"; tree="$2"; forms="$3"; shift 3
real_awk=$(command -v awk)
w=$(mktemp -d "${base}/lex-trace.XXXXXX")
# shellcheck disable=SC2064 # the directory is fixed when the trap is set
trap "rm -rf '${w}'" EXIT
mkdir -p "${w}/bin" "${w}/project" "${w}/home"
printf '{"dependencies":{}}\n' > "${w}/project/package.json"
cat > "${w}/bin/awk" <<SHIM
#!/usr/bin/env bash
view=""; marker=""; prev=""
for a in "\$@"; do
  [[ "\${prev}" == -v && "\${a}" == view=* ]] && view="\${a#view=}"
  [[ "\${prev}" == -v && "\${a}" == marker=* ]] && marker="\${a#marker=}"
  prev="\${a}"
done
case " \$* " in *" policy="*) ;; *) view="" ;; esac
[[ -n "\${view}" && -n "\${LEX_TRACE:-}" ]] || exec '${real_awk}' "\$@"
f=\$(mktemp "\${LEX_TRACE}/lex.XXXXXX") || exit 2
printf '%s' "\${view}" > "\${f}.view"
printf '%s' "\${marker}" > "\${f}.marker"
cat > "\${f}.in"
exec '${real_awk}' "\$@" < "\${f}.in"
SHIM
chmod +x "${w}/bin/awk"
while read -r n; do
  line=$(sed -n "${n}p" "${forms}")
  id=$(jq -r .id <<< "${line}"); text=$(jq -r .text <<< "${line}")
  tr="${w}/t.${n}"; mkdir -p "${tr}"; safe=$(mktemp -d "${w}/safe.XXXXXX")
  out=$(cd "${base}/${tree}" && jq -nc --arg c "${text}" --arg cwd "${w}/project" \
      '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}' |
      PATH="${w}/bin:${PATH}" LEX_TRACE="${tr}" HOME="${w}/home" SAFEDEPS_HOME="${safe}" \
      perl -e 'alarm 120; exec @ARGV' scripts/safedeps-pre-guard.sh 2>/dev/null) || true
  if [[ -z "${out}" ]]; then v=pass; else
    v=$(jq -r '.hookSpecificOutput as $h | ($h.permissionDecisionReason // "") as $r
      | if ($h.permissionDecision // "") == "deny" then
          "deny:" + (if ($r | test("install not approved")) then "notapproved"
                     elif ($r | test("UNDECIDED")) then "undecided" else "other" end)
        elif ($h.updatedInput.command // "") | test("--ignore-scripts") then "rewrite"
        else ($h.permissionDecision // "pass") end' <<< "${out}")
  fi
  lex="[]"
  for f in "${tr}"/lex.*.in; do
    [[ -f "${f}" ]] || continue
    lex=$(jq -c --arg v "$(cat "${f%.in}.view")" --arg m "$(cat "${f%.in}.marker")" \
      --arg b "$(base64 < "${f}" | tr -d '\n')" '. + [[$v,$m,$b]]' <<< "${lex}")
  done
  jq -nc --arg id "${id}" --arg t "${tree}" --arg v "${v}" --argjson lex "${lex}" \
    '{id:$id,tree:$t,v:$v,lex:$lex}'
  rm -rf "${tr}" "${safe}"
done < <(printf '%s\n' "$@")
