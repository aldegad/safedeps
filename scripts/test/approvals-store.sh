#!/usr/bin/env bash
# safedeps: the approvals store, through the real native CLI.
#
# re-check takes an approval's provenance from the store and from nothing
# else, so a line an append left behind when it said "not written" must vouch
# for nothing, then and after any later write. The rust-core battery holds the
# rule on bytes a test writes. These rows make the core's own write fail: a
# file size limit stops `safedeps-core approvals append` at a byte the row
# picks (scripts/test/lib/core-approvals-store.py), and the next appends and
# the index are the real CLI's.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "${ROOT_DIR}"

# shellcheck source=lib/core-reader.sh
source "${ROOT_DIR}/scripts/test/lib/core-reader.sh"
core_reader_init "${ROOT_DIR}"
python3 "${ROOT_DIR}/scripts/test/lib/core-approvals-store.py" "${SAFEDEPS_TEST_CORE}"

printf 'approvals store passed\n'
