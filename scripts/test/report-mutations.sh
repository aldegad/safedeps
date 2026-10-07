#!/usr/bin/env bash
# Native source-copy controls. See lib/report-mutations.json for all 44 names.
# Builds and fixtures run on the caller's remote slot, serially (-j1).
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
exec python3 "${ROOT_DIR}/scripts/test/lib/report-mutations.py" "$@"
