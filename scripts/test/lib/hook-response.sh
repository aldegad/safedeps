#!/usr/bin/env bash
# One reader for test hook responses. A required decision is never quiet;
# callers that accept silence name quiet or quiet-or-decision explicitly.
# Nonempty responses are exactly one JSON object. Parse errors are also kept
# outside command substitutions, where an empty result could pass a -z test.

hook_response_init() {
  HOOK_RESPONSE_FAILURES="$1"
  : > "${HOOK_RESPONSE_FAILURES}"
}

hook_response_error() {
  printf 'not ok - hook response: %s\n' "$1" >> "${HOOK_RESPONSE_FAILURES}"
  printf 'not ok - hook response: %s\n' "$1" >&2
  return 1
}

hook_response_assert() { [[ ! -s "${HOOK_RESPONSE_FAILURES}" ]]; }

# prefix is owned by this call (normally beside its existing mktemp home).
# Capture exact bytes and exit status without starting another process.
# Return the stdout path, not command-substituted bytes (which lose newlines).
hook_response_capture() {
  local prefix="$1" rc=0
  shift
  "$@" > "${prefix}.stdout" 2> "${prefix}.stderr" || rc=$?
  printf '%s\n' "${rc}" > "${prefix}.rc"
  printf '%s' "${prefix}.stdout"
  return "${rc}"
}

hook_response_status() { printf '%s' "$(< "$1.rc")"; }
hook_response_stderr() { cat "$1.stderr"; }

# Parse once when a row needs several fields; read() below replaces a single
# jq field read. @sh quotes data before the shell assigns the parsed fields.
hook_response_parse() {
  local file="$1" expect="${2:-decision}" fields
  HOOK_QUIET=false HOOK_DECISION='' HOOK_REASON='' HOOK_REWRITE=''
  HOOK_HAS_REWRITE=false HOOK_MESSAGE=''
  [[ -f "${file}" ]] || { hook_response_error "stdout file is missing: ${file}"; return 1; }
  case "${expect}" in
    quiet)
      [[ ! -s "${file}" ]] || { hook_response_error "expected quiet stdout, got: ${file}"; return 1; }
      HOOK_QUIET=true
      return 0 ;;
    quiet-or-decision|quiet-or-message)
      if [[ ! -s "${file}" ]]; then HOOK_QUIET=true; return 0; fi ;;
    decision|message) ;;
    *) hook_response_error "unknown expectation ${expect}"; return 1 ;;
  esac
  [[ -s "${file}" ]] || { hook_response_error "expected ${expect}, got no stdout"; return 1; }
  fields=$(jq -ers --arg expect "${expect}" '
    if length != 1 or (.[0] | type != "object") then error("expected one JSON object") else .[0] end
    | if $expect == "message" or $expect == "quiet-or-message" then
        if (.systemMessage | type) != "string" then error("expected a systemMessage string")
        else {HOOK_MESSAGE: .systemMessage} end
      else
        .hookSpecificOutput
        | if type != "object" then error("expected hookSpecificOutput object") else . end
        | if (.permissionDecision != "allow" and .permissionDecision != "deny" and .permissionDecision != "ask")
          then error("expected allow, deny or ask") else . end
        | if has("permissionDecisionReason") and (.permissionDecisionReason | type) != "string"
          then error("expected reason string") else . end
        | if has("updatedInput") and ((.updatedInput | type) != "object" or (.updatedInput.command | type) != "string")
          then error("expected updatedInput.command string") else . end
        | {HOOK_DECISION: .permissionDecision, HOOK_REASON: (.permissionDecisionReason // ""),
           HOOK_REWRITE: (if has("updatedInput") then .updatedInput.command else "" end),
           HOOK_HAS_REWRITE: (has("updatedInput") | tostring)}
      end
    | to_entries | map(.key + "=" + (.value | @sh)) | join(" ")
  ' "${file}") || { hook_response_error "invalid ${expect} stdout: ${file}"; return 1; }
  eval "${fields}"
}

hook_response_read() {
  local field="$1" file="$2" expect="${3:-decision}"
  hook_response_parse "${file}" "${expect}" || return 1
  case "${field}" in
    decision) printf '%s' "${HOOK_DECISION}" ;;
    reason) printf '%s' "${HOOK_REASON}" ;;
    rewrite) printf '%s' "${HOOK_REWRITE}" ;;
    required-rewrite)
      [[ "${HOOK_HAS_REWRITE}" == true && -n "${HOOK_REWRITE}" ]] \
        || { hook_response_error "expected a nonempty rewrite"; return 1; }
      printf '%s' "${HOOK_REWRITE}" ;;
    has-rewrite) printf '%s' "${HOOK_HAS_REWRITE}" ;;
    message) printf '%s' "${HOOK_MESSAGE}" ;;
    quiet) printf '%s' "${HOOK_QUIET}" ;;
    *) hook_response_error "unknown field ${field}"; return 1 ;;
  esac
}
