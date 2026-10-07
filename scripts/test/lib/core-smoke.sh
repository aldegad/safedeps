#!/usr/bin/env bash
# Shared by smoke and its reader-only entry, so the focused run cannot drift.
# shellcheck source=core-reader.sh
source "${ROOT_DIR}/scripts/test/lib/core-reader.sh"

core_smoke_budget() {
  local config runtime ceiling timeout version
  version=$("${SAFEDEPS_TEST_CORE}" version)
  [[ "${version}" == "safedeps-core $(jq -r '.version' "${ROOT_DIR}/package.json")" ]] \
    || fail "native core version matches package.json"
  config=$("${SAFEDEPS_TEST_CORE}" budget-config)
  runtime=$(jq -er '.runtime_budget_seconds | numbers' <<< "${config}")
  ceiling=$(jq -er '.self_budget_max_seconds | numbers' <<< "${config}")
  timeout=$(sed -nE 's/^const PRE_HOOK_TIMEOUT_SECONDS = ([0-9]+);$/\1/p' "${ROOT_DIR}/scripts/install/install-safedeps-hooks.mjs")
  [[ "${runtime}" == "${timeout}" ]] || fail "native runtime budget matches installer timeout"
  (( ceiling < runtime )) || fail "native self budget is below runtime timeout"
  pass "native version and self-budget ceiling match the registered hook contract"
}

core_smoke_pending() {
  local safe project command before out rewritten after post
  safe=$(mktemp -d "${tmp_root}/core-key.XXXXXX")
  project="${safe}/project"
  mkdir -p "${project}"
  printf '{"dependencies":{}}\n' > "${project}/package.json"
  SAFEDEPS_HOME="${safe}/state" "${ROOT_DIR}/lib/ledger/ledger.sh" approve npm left-pad 1.3.0 1.3.0 smoke >/dev/null
  for command in \
    "npm install left-pad@1.3.0 --cache --ignore-scripts" \
    "npm install left-pad@1.3.0 --ignore-scripts=false" \
    "sh -c 'npm install left-pad@1.3.0'" \
    "npm install left-pad@1.3.0>install.log" \
    "npm install left-pad@1.3.0<input" \
    "npm install left-pad@1.3.0 --cache" \
    'npm ci $(printf -- --)' \
    'HOME=--cache; npm install left-pad@1.3.0 ~'
  do
    out=$(jq -nc --arg c "${command}" --arg cwd "${project}" \
      '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}' |
      HOME="${safe}/home" SAFEDEPS_HOME="${safe}/state" "${SAFEDEPS_TEST_CORE}" pre)
    rewritten=$(jq -er '.hookSpecificOutput.updatedInput.command | strings' <<< "${out}")
    [[ -n "${rewritten}" ]] || fail "the pending-key input was rewritten: ${command}"
    before=$(find "${safe}/state/pending" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')
    [[ "${before}" == 1 ]] || fail "one native pending record before post: ${command}"
    # A real post of the rewritten no-id call must consume the record created
    # above. This checks the production lookup, without recomputing its hash.
    post=$(jq -nc --arg c "${rewritten}" --arg cwd "${project}" \
      '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}' |
      HOME="${safe}/home" SAFEDEPS_HOME="${safe}/state" "${SAFEDEPS_TEST_CORE}" post)
    after=$(find "${safe}/state/pending" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')
    [[ "${after}" == 0 ]] || fail "native post consumes its rewritten no-id record: ${command}"
  done
  pass "native post consumes all eight no-id records from their inert rewrites"
}
