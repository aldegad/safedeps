#!/usr/bin/env bash
# safedeps: the installer of a test host's queue runner.
#
#   scripts/ci/install-slot.sh | ssh <host> bash -s
#
# Prints a shell script that installs scripts/ci/slot.sh as ~/safedeps-runs/slot.sh
# and the reader it asks, scripts/test/lib/native_budget_owners.py, as
# ~/safedeps-runs/slot-lib/native_budget_owners.py, on the host that runs it.
# Line 2 of each copy names its source and the sha256 of the source's bytes, so
# a copy says which file of the repository it is. Each file is written under a
# temporary name and renamed into place: bash reads a script as it runs it, so
# a suite still holding a slot keeps reading the copy it started with.
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
EOF_MARK=SAFEDEPS_SLOT_INSTALL_EOF

sha() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }

# file <repo path> <path under ~/safedeps-runs> <mode>
file() {
  local source="${ROOT_DIR}/$1"
  if grep -qx "${EOF_MARK}" "${source}" || [[ -n "$(tail -c 1 "${source}")" ]]; then
    printf 'install-slot.sh: %s holds the line %s, or does not end in a newline\n' "$1" "${EOF_MARK}" >&2
    exit 2
  fi
  printf 'mkdir -p "$d/%s"\n' "$(dirname "$2")"
  printf "cat > \"\$d/%s.new.\$\$\" <<'%s'\n" "$2" "${EOF_MARK}"
  sed -n 1p "${source}"
  printf '# installed from %s sha256 %s\n' "$1" "$(sha "${source}")"
  sed -n '2,$p' "${source}"
  printf '%s\n' "${EOF_MARK}"
  printf 'chmod %s "$d/%s.new.$$"\n' "$3" "$2"
  staged+=("$2")
}

staged=()
printf '%s\n' '#!/bin/bash' 'set -eu' 'd="$HOME/safedeps-runs"'
file scripts/test/lib/native_budget_owners.py slot-lib/native_budget_owners.py 644
file scripts/ci/slot.sh slot.sh 755
for path in "${staged[@]}"; do
  printf 'mv -f "$d/%s.new.$$" "$d/%s"\n' "${path}" "${path}"
done
printf 'sed -n 2p "$d/slot.sh" "$d/slot-lib/native_budget_owners.py"\n'
