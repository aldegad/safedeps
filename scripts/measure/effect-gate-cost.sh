#!/usr/bin/env bash
# Whole native post timing. The former Bash stage sum is retired: it did not
# measure the native hook. core-post-cost owns the options and cache scope.
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
exec python3 "${ROOT_DIR}/scripts/measure/core-post-cost.py" "$@"
