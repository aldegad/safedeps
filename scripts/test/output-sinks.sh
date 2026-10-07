#!/usr/bin/env bash
# Source gate and mutation controls. No core execution or build is needed.
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
python3 "${ROOT_DIR}/scripts/test/lib/output-sinks.py" "${ROOT_DIR}"
