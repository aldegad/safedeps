#!/usr/bin/env bash
# safedeps: the Rust core's grammar against lib/install-grammar.sh.
#
# The core carries the grammar's vocabulary, patterns and tables as the same
# strings (rust/src/grammar.rs, rust/src/tables.rs). While both exist, this
# holds them equal: `safedeps-core grammar` prints `name=value` for each, and
# each value is compared with the shell file's after it is sourced. Any
# difference exits 1 and names the value.
#
# Usage: scripts/measure/core-grammar-drift.sh <safedeps-core>
set -uo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CORE="${1:?usage: core-grammar-drift.sh <safedeps-core>}"
# shellcheck source=../../lib/install-grammar.sh
source "${ROOT_DIR}/lib/install-grammar.sh"
fail=0 n=0
while IFS= read -r line; do
  name="${line%%=*}" value="${line#*=}"
  n=$((n + 1))
  shell_value="${!name-<unset>}"
  if [[ "${shell_value}" != "${value}" ]]; then
    printf 'drift: %s differs (core %d bytes, shell %d bytes)\n' "${name}" "${#value}" "${#shell_value}"
    fail=$((fail + 1))
  fi
done < <("${CORE}" grammar)
(( n > 20 )) || { printf 'core-grammar-drift: the core printed %d values\n' "${n}"; exit 1; }
printf 'core-grammar-drift: %d values, %d differ\n' "${n}" "${fail}"
(( fail == 0 ))
