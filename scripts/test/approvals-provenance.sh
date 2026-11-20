#!/usr/bin/env bash
# Approval provenance through check, rotation, re-check and migration.
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
source "${ROOT_DIR}/scripts/test/lib/core-reader.sh"
core_reader_init "${ROOT_DIR}"
exec node "${ROOT_DIR}/scripts/test/lib/approvals-provenance.mjs" "${ROOT_DIR}"
