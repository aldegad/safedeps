#!/usr/bin/env bash
# safedeps: the approvals store, through the real native CLI.
#
# re-check takes an approval's provenance from the store and from nothing
# else, so a line a store write left behind when it said "not written" must
# vouch for nothing, then and after any later write. The rust-core battery
# holds the rule on bytes a test writes. These rows make the core's own write fail: a
# file size limit stops the store line of `safedeps-core approvals commit` at
# a byte the row picks (scripts/test/lib/core-approvals-store.py), and the
# next commits and the index are the real CLI's. The last row kills a process
# holding the store lock while commits wait for it. What `safedeps check` does
# with the store's answers is check-fail-closed's.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "${ROOT_DIR}"

# shellcheck source=lib/core-reader.sh
source "${ROOT_DIR}/scripts/test/lib/core-reader.sh"
core_reader_init "${ROOT_DIR}"
python3 "${ROOT_DIR}/scripts/test/lib/core-approvals-store.py" "${SAFEDEPS_TEST_CORE}"

printf 'approvals store passed\n'
