#!/usr/bin/env bash
# Source fault census: no test switches in production pre/post.
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
source "${ROOT_DIR}/scripts/test/lib/native-measure-core.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/native-scan-failures.XXXXXX")
trap 'rm -rf "${work}"' EXIT
# A host runner receives an archive without .git. Both paths copy source,
# never native/target outputs or another worktree's mutations.
if [[ -e "${ROOT_DIR}/.git" ]]; then
  git -C "${ROOT_DIR}" archive HEAD > "${work}/source.tar"
else
  (cd "${ROOT_DIR}" && tar --exclude='./bin/native' --exclude='./rust/target' --exclude='./.git' --exclude='./node_modules' -cf "${work}/source.tar" .)
fi
python3 "${ROOT_DIR}/scripts/measure/native-scan-failures.py" \
  --archive "${work}/source.tar" --core "${MEASURE_CORE}" \
  --cargo "${CARGO:-$(command -v cargo)}" --run-dir "${work}/result" "$@"
