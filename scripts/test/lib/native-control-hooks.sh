# Native mutation harness only; production hooks never read this file.
native_pre_clock_ready() {
  # A host wall-clock step can put the next marker before an old record.
  # Wait before invoking the hook, using only actual marker timestamps;
  # never move records or teach the oracle to disregard a newer record.
  python3 - "$1" <<'PY'
import json,time,sys
from pathlib import Path
call=Path(sys.argv[1]);marker=call/'marker'
metas={line.split(' ',2)[2]:Path(line.split(' ',2)[2]).stat().st_mtime_ns
       for line in (call/'metas.before').read_text().splitlines()}
ceiling=max(metas.values(),default=0)
deadline=time.monotonic()+5
samples=[]
while True:
    observed=marker.stat().st_mtime_ns
    samples.append(observed)
    ready=observed>=ceiling
    if ready or time.monotonic()>=deadline:break
    time.sleep(.02)
    marker.touch()
(call/'native-pre-clock.json').write_text(json.dumps(dict(
    before_meta_mtimes_ns=metas,marker_samples_ns=samples,ready=ready),indent=2)+'\n')
if not ready:raise SystemExit('native fixture clock did not advance past existing records; hook was not run')
PY
}
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
  native_pre_clock_ready "${call}" || return $?
  out=$(printf '%s' "${payload}" | "$PRE_CORE" pre) || rc=$?
  printf '%s' "${out}"
  oracle_pre "${call}" "${out}" || exit 1
  return "${rc}"
}
