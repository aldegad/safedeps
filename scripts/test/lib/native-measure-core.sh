# Measurement consumer only. The production entry does not read this setting.
# The caller names ROOT_DIR (or TREE for a source-copy control).
measure_root="${TREE:-${ROOT_DIR}}"
case "$(uname -s):$(uname -m)" in
  Darwin:arm64) measure_platform=darwin-arm64 ;;
  Darwin:x86_64) measure_platform=darwin-x64 ;;
  Linux:x86_64) measure_platform=linux-x64 ;;
  *) printf 'unsupported native measurement host\n' >&2; exit 2 ;;
esac
MEASURE_CORE="${SAFEDEPS_MEASURE_CORE:-${measure_root}/bin/native/${measure_platform}/safedeps-core}"
[[ -x "${MEASURE_CORE}" ]] || { printf 'prepare the native core before measurement: %s\n' "${MEASURE_CORE}" >&2; exit 2; }
measure_grammar() {
  local record key value
  record=$("${MEASURE_CORE}" grammar) || return $?
  while IFS= read -r record; do
    key="${record%%=*}"; value="${record#*=}"
    [[ "${key}" == SAFEDEPS_G_* && "${record}" == *=* ]] || return 2
    printf -v "${key}" '%s' "${value}"
  done <<< "${record}"
}
