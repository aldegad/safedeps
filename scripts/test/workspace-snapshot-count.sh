#!/usr/bin/env bash
# safedeps: the workspace snapshot starts the same processes at any size.
#
# The pre-guard keeps a copy of every workspace member's package.json, because
# `npm install x -w packages/a` writes one and a rollback has to restore it. It
# used to copy and hash each member on its own, so the hook started two
# processes per member: a workspace of 1000 members took 20-33s to judge, past
# the runtime's 30s kill, which lets the command through unjudged
# (safedeps/effect-gate-blind-to-lockless-npm-installs). It now copies them in
# one go and hashes them in one go.
#
# A timing assertion would say the same thing badly: it moves with load, and on
# a loaded machine a fixed threshold either flakes or is set so loose that it
# passes the defect. This battery counts process starts instead. Every external
# command on PATH is replaced by a shim that logs its name and execs the real
# one, the real pre-guard judges `npm install sd-victim -w packages/m0` in a
# workspace of 10 members and again in one of 1000, and the two logs must
# agree name for name. `sleep` is the one name left out: the npm asks poll for
# their answer, so its count measures how long npm took, not how many members
# there are.
#
# The counts say nothing about whether the snapshot is complete, so the second
# half checks that: every member's manifest is in the snapshot, byte for byte,
# and the hash list names each one. Restoring from it is pinned by
# lockless-forms.sh section 8, which runs the real rollback.
#
# No install runs. The pre-guard judges the command as a payload; npm only
# loads its configuration, from a sandbox, and the advisory providers point at
# a closed local port.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "${ROOT_DIR}"

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

for tool in npm node jq; do
  command -v "${tool}" >/dev/null 2>&1 || fail "${tool} is required for the workspace snapshot count"
done

T=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-ws-count.XXXXXX")
T=$(cd "${T}" && pwd -P)
trap 'rm -rf "${T}"' EXIT
source "${ROOT_DIR}/scripts/test/lib/core-post-fixtures.sh"
native_fixtures_init "${T}/native-fixtures"

while IFS= read -r inherited; do
  unset "${inherited}"
done < <(env | awk -F= 'tolower($1) ~ /^npm_config_/ { print $1 }')
export HOME="${T}/home"
mkdir -p "${HOME}"
export npm_config_userconfig="${T}/npmrc" npm_config_globalconfig="${T}/gnpmrc" npm_config_cache="${T}/cache" \
  npm_config_update_notifier=false npm_config_logs_max=0 npm_config_offline=true
printf 'prefix=%s\n' "${T}/global" > "${npm_config_userconfig}"
: > "${npm_config_globalconfig}"
[[ "$(npm config get prefix 2>/dev/null)" == "${T}/global" ]] || fail "npm's global prefix is the sandbox"
export SAFEDEPS_OSV_API_URL=http://127.0.0.1:9/v1/query SAFEDEPS_OSV_BATCH_API_URL=http://127.0.0.1:9/v1/querybatch \
  SAFEDEPS_KEV_CATALOG_URL=http://127.0.0.1:9/kev.json SAFEDEPS_GHSA_API_URL=http://127.0.0.1:9/advisories

# One shim per executable name on PATH, first one wins as PATH would have it.
# The shim is bash builtins only, so it starts nothing it would have to count.
SHIMS="${T}/shims"
mkdir -p "${SHIMS}"
cat > "${T}/shim.sh" <<'EOF'
#!/bin/bash
name="${0##*/}"
printf '%s\n' "${name}" >> "${SAFEDEPS_COUNT_LOG:-/dev/null}"
IFS=: read -ra dirs <<< "${SAFEDEPS_REAL_PATH}"
for dir in "${dirs[@]}"; do
  [[ -n "${dir}" && -x "${dir}/${name}" && ! -d "${dir}/${name}" ]] && exec "${dir}/${name}" "$@"
done
printf '%s: not found\n' "${name}" >&2
exit 127
EOF
chmod +x "${T}/shim.sh"
export SAFEDEPS_REAL_PATH="${PATH}"
node - "${SHIMS}" "${T}/shim.sh" <<'EOF'
const fs = require('fs');
const path = require('path');
const [shims, shim] = process.argv.slice(2);
for (const dir of (process.env.SAFEDEPS_REAL_PATH || '').split(':')) {
  let names = [];
  try { names = fs.readdirSync(dir); } catch { continue; }
  for (const name of names) {
    const link = path.join(shims, name);
    if (fs.existsSync(link)) continue;
    try {
      const st = fs.statSync(path.join(dir, name));
      if (!st.isFile() || !(st.mode & 0o111)) continue;
      fs.symlinkSync(shim, link);
    } catch {}
  }
}
EOF
for tool in cp shasum tar mkdir; do
  [[ -L "${SHIMS}/${tool}" ]] || [[ "${tool}" == shasum && -L "${SHIMS}/sha256sum" ]] \
    || fail "${tool} is shimmed, so its starts are counted"
done

make_workspace() {
  local n="$1" dir="$2"
  node - "${n}" "${dir}" <<'EOF'
const fs = require('fs');
const [n, dir] = [Number(process.argv[2]), process.argv[3]];
fs.mkdirSync(dir, { recursive: true });
fs.writeFileSync(`${dir}/package.json`, JSON.stringify({ name: 'root', private: true, workspaces: ['packages/*'] }));
for (let i = 0; i < n; i++) {
  fs.mkdirSync(`${dir}/packages/m${i}`, { recursive: true });
  fs.writeFileSync(`${dir}/packages/m${i}/package.json`, JSON.stringify({ name: `m${i}`, version: '1.0.0' }) + '\n');
}
EOF
}

# The pre-guard judging the install in <dir>, every process start logged to
# <log>. Prints the pending snapshot id.
judge() {
  local dir="$1" log="$2" home="$3"
  : > "${log}"
  jq -nc --arg d "${dir}" '{tool_name:"Bash",tool_input:{command:"npm install sd-victim -w packages/m0"},cwd:$d}' \
    | SAFEDEPS_HOME="${home}" SAFEDEPS_COUNT_LOG="${log}" PATH="${SHIMS}" \
      "${NATIVE_TEST_CORE}" pre > "${log}.out" 2> "${log}.err" \
    || fail "the pre-guard judges the install ($(cat "${log}.err"))"
  find "${home}/snapshots" -maxdepth 1 -name '*_meta.json' | sed 's#.*/##; s#_meta\.json$##'
}

# <name> <count>, sorted, `sleep` left out.
counts() {
  grep -vx sleep "$1" | LC_ALL=C sort | uniq -c | awk '{ print $2, $1 }'
}

SIZES=(10 1000)
for n in "${SIZES[@]}"; do
  make_workspace "${n}" "${T}/ws-${n}"
  mkdir -p "${T}/safe-${n}"
  id=$(judge "${T}/ws-${n}" "${T}/starts-${n}.log" "${T}/safe-${n}")
  [[ -n "${id}" && "${id}" != *$'\n'* ]] || fail "one snapshot is pending for ${n} members (got '${id}')"
  printf '%s' "${id}" > "${T}/id-${n}"
  counts "${T}/starts-${n}.log" > "${T}/counts-${n}"
done

for tool in cp shasum sha256sum tar; do
  small=$(awk -v t="${tool}" '$1 == t { print $2 }' "${T}/counts-10")
  large=$(awk -v t="${tool}" '$1 == t { print $2 }' "${T}/counts-1000")
  printf '# %s: %s starts at 10 members, %s at 1000\n' "${tool}" "${small:-0}" "${large:-0}"
done
if ! diff "${T}/counts-10" "${T}/counts-1000" > "${T}/counts.diff"; then
  sed 's/^/#   /' "${T}/counts.diff" >&2
  fail "the pre-guard starts the same processes for 10 members as for 1000"
fi
pass "the pre-guard starts the same processes for 10 members as for 1000 ($(awk '{ s += $2 } END { print s }' "${T}/counts-10") starts, sleep aside)"

# Complete: every member's manifest is in the snapshot, byte for byte, and the
# hash list names it with the hash it has.
for n in "${SIZES[@]}"; do
  id=$(cat "${T}/id-${n}")
  snap="${T}/safe-${n}/snapshots/${id}_members"
  [[ -d "${snap}" ]] || fail "the snapshot keeps the members of ${n} under ${id}_members"
  kept=$(cd "${snap}" && find . -type f -name package.json | wc -l | tr -d ' ')
  [[ "${kept}" == "${n}" ]] || fail "the snapshot keeps all ${n} member manifests (kept ${kept})"
  for (( i = 0; i < n; i++ )); do
    cmp -s "${T}/ws-${n}/packages/m${i}/package.json" "${snap}/packages/m${i}/package.json" \
      || fail "member m${i} of ${n} is kept byte for byte"
  done
  hashes="${snap}.sha256"
  [[ "$(wc -l < "${hashes}" | tr -d ' ')" == "${n}" ]] || fail "the hash list names all ${n} members"
  if command -v shasum >/dev/null 2>&1; then
    (cd "${T}/ws-${n}" && shasum -a 256 -c --status "${hashes}") || fail "the hash list matches the ${n} members it names"
  else
    (cd "${T}/ws-${n}" && sha256sum -c --status "${hashes}") || fail "the hash list matches the ${n} members it names"
  fi
  grep -qx 'packages/m0/package.json' "${T}/safe-${n}/snapshots/${id}_monitored_files.list" \
    || fail "the monitored list names the members for the rollback (${n})"
done
pass "the snapshot keeps every member's manifest, byte for byte, and hashes each one (10 and 1000)"

# A snapshot that cannot keep the members is a rollback that cannot undo the
# install, so the install waits, and says it is undecided rather than detected.
# A real unreadable member, still found by production workspace discovery,
# makes native copying fail. The fixture checks EACCES as the same uid and
# restores permissions after the hook; root/ineffective chmod is an error.
mkdir -p "${T}/safe-broken"
out=$(jq -nc --arg d "${T}/ws-10" '{tool_name:"Bash",tool_input:{command:"npm install sd-victim -w packages/m0"},cwd:$d}' \
  | SAFEDEPS_HOME="${T}/safe-broken" SAFEDEPS_TEST_FAULT=workspace \
    native_fixture_hook pre) || fail "the pre-guard answers when the copy fails"
[[ "$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<< "${out}")" == deny ]] \
  || fail "a failed member snapshot denies the install (got ${out})"
jq -r '.hookSpecificOutput.permissionDecisionReason' <<< "${out}" | grep -q 'undecided' \
  || fail "the deny says undecided, not a finding (got ${out})"
grep -q 'could not snapshot the workspace members' "${T}/safe-broken/advisory.log" \
  || fail "the failed snapshot is recorded in advisory.log"
leftover=$(find "${T}/safe-broken/snapshots" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')
[[ "${leftover}" == 0 ]] || fail "a failed snapshot leaves nothing behind (${leftover} files)"
pass "a member snapshot that fails denies the install as undecided, records why, and leaves no snapshot"

printf 'workspace-snapshot-count passed\n'
