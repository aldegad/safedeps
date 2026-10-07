# Native mutation harness only; production hooks never read this file.
post_message() { jq -r '.systemMessage // empty' <<< "$1"; }
post_hook() {
  local payload out call
  payload=$(cat)
  call=$(mktemp -d "${ORACLE_DIR}/call.XXXXXX")
  : > "${call}/native-owner-source"
  oracle_before "${call}" "${payload}"
  # The npm shim goes on PATH only where the row has an npm: on a PATH with
  # none, the shim would be the npm the hook finds, and the row would test a
  # hook that has one.
  local path="${PATH}"
  command -v npm >/dev/null 2>&1 && path="${ORACLE_DIR}/bin:${PATH}"
  out=$(printf '%s' "${payload}" | ORACLE_NPM_LOG="${call}/npm.log" ORACLE_CALL="${call}" PATH="${path}" \
    "$POST_CORE" post) || { printf '%s\n' "$?" > "$call/hook.rc"; return 1; }
  printf '0\n' > "$call/hook.rc"
  printf '%s' "$out" > "$call/native-hook.stdout"
  printf '%s' "${out}"
  oracle_message "${call}" "${payload}" "${out}" || exit 1
}
# Every pre-guard call goes through here too, so the oracle reads the rewrite
# the pre-guard printed and holds the record it wrote against it
# (oracle_pre). Output and status pass through unchanged.
pre_hook() {
  local payload out call rc=0
  payload=$(cat)
  call=$(mktemp -d "${ORACLE_DIR}/pre.XXXXXX")
  oracle_pre_before "${call}"
  out=$(printf '%s' "${payload}" | "$PRE_CORE" pre) || rc=$?
  printf '%s' "${out}"
  oracle_pre "${call}" "${out}" || exit 1
  return "${rc}"
}
