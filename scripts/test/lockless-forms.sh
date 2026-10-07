#!/usr/bin/env bash
# safedeps: npm installs whose result package-lock.json does not show.
#
# The effect gate is npm's enforcement authority, and it can only enforce on
# what it reads. It used to read package-lock.json alone, in the directory the
# command started in. npm has many ways to install without touching that file,
# and each one was measured here with a real npm against a local registry:
#
#   - `--no-save`, `--save=false`, `--no-package-lock`, `--package-lock false`,
#     and the same settings from the environment or an .npmrc leave
#     package-lock.json byte-identical. The package lands in node_modules and
#     in the hidden lockfile node_modules/.package-lock.json.
#   - `npm -C <dir>`, `cd <dir> && npm install`, and `cd <dir>; npm install`
#     write <dir>/package-lock.json.
#   - A global install (`npm_config_global=true` and friends) writes no
#     lockfile at all.
#
# The gate confirmed every one of them clean. On Claude Code that confirmation
# is what triggers `npm rebuild`, so the inert install then ran the unverified
# package's preinstall, install and postinstall scripts -- the exact thing the
# inert install exists to prevent. This battery pins the repair from both
# sides: every form above is rolled back or recorded, no unverified script runs,
# and an approved install still installs, verifies and rebuilds.
#
# This battery RUNS the install commands, unlike the text batteries. The
# question it answers is what npm writes and what `npm rebuild` executes, which
# is a property of npm and not of the command text. What keeps that safe:
# the only packages are synthetic ones packed here, the registry is
# fixture-registry.mjs on 127.0.0.1, and npm's proxies point at a closed local
# port so a request for anything else fails instead of leaving the machine.
# The request log is checked at the end.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "${ROOT_DIR}"

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

# Rows for --shard I/M (scripts/test/lib/shard.sh): each pass of a loop over
# forms, and each case below that stands alone. A row makes its own project and
# safedeps home, and run_install empties the global prefix, so no row reads
# what another left; the one thing a row leaves for later rows, a package it
# publishes to the fixture registry, is published in every shard.
# shellcheck source=lib/shard.sh
source "${ROOT_DIR}/scripts/test/lib/shard.sh"
shard_args "$@"
(( ${#SHARD_REST[@]} == 0 )) || fail "lockless-forms.sh takes --shard I/M or --shard-list, not ${SHARD_REST[0]}"

# The sandbox, the synthetic packages, the local registry and run_install. A
# battery that skips when a tool is missing is a battery that passes when it
# cannot look, so the sandbox fails when npm, node or jq is absent.
NPM_SANDBOX_NAME=lockless
NPM_SANDBOX_SCRIPT_RE='lockless-forms\.sh'
# shellcheck source=lib/npm-sandbox.sh
source "${ROOT_DIR}/scripts/test/lib/npm-sandbox.sh"
# Forms hold paths under the sandbox, so a row's label says <tmp> there.
shard_mask tmp "${tmp_root}"
# shellcheck source=lib/release-floor.sh
source "${ROOT_DIR}/scripts/test/lib/release-floor.sh"
NPM_SANDBOX_RELEASE_FLOOR=true
RELEASE_FLOOR_FAILS="${tmp_root}/release-floor.fails"
: > "${RELEASE_FLOOR_FAILS}"


# --- 1. Installs the effect gate now reads ------------------------------------
# Each lands in the directory the gate reads, and each leaves package-lock.json
# of that directory unchanged or absent. Before the repair every one of them was
# confirmed clean, and the ones that reached node_modules then had their scripts
# run by `npm rebuild`.
for form in \
  "npm install sd-victim --no-save" \
  "npm install --no-save sd-victim" \
  "npm install sd-victim --save=false" \
  "npm_config_save=false npm install sd-victim" \
  "NPM_CONFIG_SAVE=false npm install sd-victim" \
  "npm install sd-victim --package-lock false" \
  "npm install sd-victim --package-lock=false" \
  "npm install sd-victim --no-package-lock" \
  "npm_config_package_lock=false npm install sd-victim" \
  "printf 'save=false\\n' > .npmrc && npm install sd-victim" \
  "npm install sd-victim --no-save && npm run build --if-present" \
  "npm -C sub install sd-victim" \
  "npm --prefix=sub install sd-victim --no-save" \
  "cd sub && npm install sd-victim" \
  "cd sub; npm install sd-victim" \
  "env -C sub npm install sd-victim"
do
  shard_row "form: ${form}" || continue
  if [[ "${form}" == env\ -C* ]] && ! env -C / true 2>/dev/null; then
    continue  # this platform's env has no -C (BSD); the form cannot run here
  fi
  new_project
  : > "${MARKS}"
  run_install "${form}"
  rolled_back || fail "the effect gate rolls back an unapproved install it reads: ${form} (post: ${CASE_POST:-<quiet>})"
  victim_ran && fail "no script of the unverified package runs: ${form} ($(cut -f1,2 "${MARKS}" | paste -sd, -))"
  [[ ! -e "${CASE_PROJECT}/node_modules/sd-victim" && ! -e "${CASE_PROJECT}/sub/node_modules/sd-victim" ]] \
    || fail "the rollback removes the unapproved package from disk: ${form}"
done
pass "installs that leave package-lock.json unchanged, or land in a sub-project, are read and rolled back"

# --- 1b. Where npm records an install it does not save, and the record ---------
# The UNGATED record is skipped for exactly the installs the effect gate reads,
# and what the gate reads is decided by where each install lands
# (guard_effect_gate_reads). A flag list decided it before, and it missed
# `--no-save` and `--save=false`, so this measures each of those flags with a
# real npm: where npm wrote the install, that the gate read it there, and that
# no UNGATED line was written for it. The package is unpinned on purpose: an
# unpinned install is the only kind the record exists for.
#
# <form>|<package-lock.json>|<hidden lockfile>|<package.json>
snapshot_records() {
  cp "${CASE_PROJECT}/package-lock.json" "${tmp_root}/lock-before.json"
  cp "${CASE_PROJECT}/package.json" "${tmp_root}/manifest-before.json"
}
read_records() {
  local project="$1"
  if cmp -s "${tmp_root}/lock-before.json" "${project}/package-lock.json"; then RECORD_LOCK=unchanged; else RECORD_LOCK=changed; fi
  if grep -q '"node_modules/sd-victim"' "${project}/node_modules/.package-lock.json" 2>/dev/null; then
    RECORD_HIDDEN=recorded
  else
    RECORD_HIDDEN=absent
  fi
  if cmp -s "${tmp_root}/manifest-before.json" "${project}/package.json"; then RECORD_MANIFEST=unchanged; else RECORD_MANIFEST=changed; fi
}
for row in \
  "npm install sd-victim --no-save|unchanged|recorded|unchanged" \
  "npm install --no-save sd-victim|unchanged|recorded|unchanged" \
  "npm install sd-victim --save=false|unchanged|recorded|unchanged" \
  "npm i --save=false sd-victim|unchanged|recorded|unchanged" \
  "npm install sd-victim --no-package-lock|unchanged|recorded|changed" \
  "npm install --no-package-lock sd-victim|unchanged|recorded|changed"
do
  shard_row "row: ${row}" || continue
  IFS='|' read -r form want_lock want_hidden want_manifest <<< "${row}"
  new_project
  snapshot_records
  : > "${MARKS}"
  run_install "${form}" claude read_records
  [[ "${RECORD_LOCK}|${RECORD_HIDDEN}|${RECORD_MANIFEST}" == "${want_lock}|${want_hidden}|${want_manifest}" ]] \
    || fail "npm records ${form} as measured (package-lock.json ${RECORD_LOCK}, hidden lockfile ${RECORD_HIDDEN}, package.json ${RECORD_MANIFEST}; want ${want_lock}, ${want_hidden}, ${want_manifest})"
  rolled_back || fail "the effect gate reads the hidden lockfile and rolls back: ${form} (post: ${CASE_POST:-<quiet>})"
  ungated && fail "an install the effect gate reads is not recorded UNGATED: ${form} ($(grep UNGATED "${CASE_HOME}/advisory.log"))"
  victim_ran && fail "no script of the unverified package runs: ${form}"
done
pass "--no-save, --save=false and --no-package-lock leave package-lock.json alone and record the install in node_modules/.package-lock.json, the gate reads it there, and nothing is recorded UNGATED"

# --- 1c. `--prefix <dir>` with the value as its own word ------------------------
# The grammar's regexes read `npm --prefix x install ...` as `npm x` (exec),
# so the pre-guard skipped the ledger and recorded the package `install`; the
# `--prefix=x` spelling was read as the install it is. npm reads both alike
# (nopt, npm's option types), and the gate now does too. This measures what the
# effect gate makes of the install with a real npm: it lands in x, the gate
# reads x's lockfiles and rolls it back, no script runs, and nothing is
# recorded UNGATED, since the gate does read it.
for form in \
  "npm --prefix x install sd-victim" \
  "npm --prefix=x install sd-victim"
do
  shard_row "form: ${form}" || continue
  new_project
  mkdir -p "${CASE_PROJECT}/x"
  printf '{"name":"x","version":"1.0.0"}\n' > "${CASE_PROJECT}/x/package.json"
  : > "${MARKS}"
  run_install "${form}"
  rolled_back || fail "the effect gate reads the --prefix directory and rolls back: ${form} (post: ${CASE_POST:-<quiet>})"
  victim_ran && fail "no script of the unverified package runs: ${form} ($(cut -f1,2 "${MARKS}" | paste -sd, -))"
  [[ ! -e "${CASE_PROJECT}/x/node_modules/sd-victim" && ! -e "${CASE_PROJECT}/node_modules/sd-victim" ]] \
    || fail "the rollback removes the unapproved package from the --prefix directory: ${form}"
  ungated && fail "an install the effect gate reads is not recorded UNGATED: ${form} ($(grep UNGATED "${CASE_HOME}/advisory.log"))"
done
pass "npm --prefix x install, in both spellings, lands in x, is read there and rolled back, runs no script and is not recorded UNGATED"


# npm does not install in the directory it runs in. It walks up to the nearest
# package.json or node_modules, and from a workspace member on to the root that
# declares it. Each form below wrote the lockfiles of another directory than the
# one the command names, while the gate read the named one and confirmed it
# clean: the unapproved package stayed on disk and nothing was recorded.
# `<fixture>|<cwd>|<engine>|<form>`, where <cwd> is the hook's cwd relative to
# the project.
#
# The gate asks npm where (lib/npm/ask.sh). The rows after the first six are
# where a copy of npm's rules in bash disagreed with npm: a member reached
# through a symlink, where npm installs in real/a and the copy climbed to the
# root (validator round 2, F1), and the spellings that turn workspaces off.
for carrier in \
  "project|.|claude|cd src && npm install sd-victim" \
  "project|.|claude|cd src; npm install sd-victim --no-save" \
  "project|src|claude|npm install sd-victim" \
  "workspace|.|claude|cd packages/a && npm install sd-victim" \
  "workspace|packages/a|claude|npm install sd-victim" \
  "workspace|packages/a|claude|npm install sd-victim --no-save" \
  "negws|.|claude|cd packages/a && npm install sd-victim" \
  "symws|real/a|claude|npm install sd-victim" \
  "symws|.|claude|cd packages/a && npm install sd-victim" \
  "symws|.|claude|cd real/a && npm install sd-victim" \
  "symws|packages/a|claude|npm install sd-victim --no-save" \
  "symws|real/a|codex|npm install sd-victim" \
  "workspace|packages/a|claude|npm install sd-victim --no-workspaces" \
  "workspace|.|claude|cd packages/a && npm install sd-victim --workspaces false" \
  "workspace|.|claude|cd packages/a && npm install sd-victim --workspaces=false"
do
  shard_row "carrier: ${carrier}" || continue
  IFS='|' read -r fixture cwd engine form <<< "${carrier}"
  "new_${fixture}"
  CASE_CWD="${CASE_PROJECT}/${cwd}"
  : > "${MARKS}"
  run_install "${form}" "${engine}"
  rolled_back || fail "the effect gate reads the directory npm installed in and rolls back: ${carrier} (post: ${CASE_POST:-<quiet>})"
  ungated && fail "an install the effect gate reads is not recorded UNGATED: ${carrier}"
  # Codex has no inert install, so there the scripts ran during the install.
  [[ "${engine}" == codex ]] || ! victim_ran || fail "no script of the unverified package runs: ${carrier}"
  [[ -z "$(cd "${CASE_PROJECT}" && find . -path '*/node_modules/sd-victim' -print 2>/dev/null)" ]] \
    || fail "the rollback removes the unapproved package from disk: ${carrier}"
  grep -q 'packages@' <<< "${CASE_POST}" && fail "a workspace member is not read as a package: ${carrier} (post: ${CASE_POST})"
done
pass "an install from a directory without a package.json, a workspace member, or a symlinked member is read where npm put it"

# Where npm cannot be asked, or does not answer, the gate does not fall back to
# a reading of its own: it records why, and looks in the cwd for want of a
# better place. Whether the install was read there is the trace's to say
# (scripts/test/effect-trace-grid.sh): here npm did install in the cwd, so the
# gate read it and rolled it back. The stub stands in for npm in the
# PreToolUse hook only; the install itself runs the real npm.
# `<stub>|<commands>|<the reason the record gives>`.
for carrier in \
  "fail|prefix|root|npm prefix failed (exit 7: code EFAKE)" \
  "hang|prefix|root|npm did not say where this install lands within" \
  "missing|||npm is not on the PATH this hook runs with"
do
  shard_row "carrier: ${carrier}" || continue
  IFS='|' read -r behaviour cmd1 cmd2 reason <<< "${carrier}"
  new_project
  : > "${MARKS}"
  CASE_PRE_PATH=$(stub_npm_path "${behaviour}" "${cmd1}${cmd2:+|${cmd2}}")
  run_install "npm install sd-victim"
  CASE_PRE_PATH=""
  grep -qF "${reason}" "${CASE_HOME}/advisory.log" || fail "the record says why npm could not place it: ${behaviour} ($(grep pre-guard "${CASE_HOME}/advisory.log" | tail -2))"
  rolled_back || fail "an install npm could not place, that landed in the cwd, is read there and rolled back: ${behaviour} (post: ${CASE_POST:-<quiet>})"
  victim_ran && fail "no script of the unverified package runs when npm could not place the install: ${behaviour}"
done
pass "an install npm could not be asked about, or did not answer for, is recorded with the reason and read where it left its trace"

# --- 1e. Asking npm runs none of the command's code ---------------------------------
# The PreToolUse hook asks npm where an install lands. It used to ask with the
# command's own PATH, NODE_OPTIONS and npm word, so the code those chose ran
# while the gate was still judging the command: three times per judgment, and
# just the same when the gate then denied it. Here a fake npm first on a PATH
# and a NODE_OPTIONS preload each append to CX_MARKS. Each form is only judged,
# never run: an unapproved pinned spec must be denied and an approved one let
# through, and neither judgment may leave a line in CX_MARKS. The rows are the
# forms that ran the code before: a PATH in front of npm, literal or not, or
# exported, through env(1), a NODE_OPTIONS in each of those positions, and npm
# named by its path.
CX_MARKS="${tmp_root}/cx-marks"
CX_BIN="${tmp_root}/cx-bin"
mkdir -p "${CX_BIN}"
printf '#!/bin/sh\necho "fake npm $*" >> %q\nexit 1\n' "${CX_MARKS}" > "${CX_BIN}/npm"
chmod +x "${CX_BIN}/npm"
printf "require('fs').appendFileSync(%s, 'preload\\\\n')\n" "$(jq -Rn --arg p "${CX_MARKS}" '$p')" > "${tmp_root}/cx-preload.js"
# The fixture works, or the rows test nothing: each one writes a mark when run.
: > "${CX_MARKS}"
"${CX_BIN}/npm" --version >/dev/null 2>&1 || true
NODE_OPTIONS="--require=${tmp_root}/cx-preload.js" node -e 1
[[ "$(wc -l < "${CX_MARKS}" | tr -d ' ')" == 2 ]] || fail "the fake npm and the preload each leave a mark when they run ($(cat "${CX_MARKS}"))"
cx_failures=()
for form in \
  "PATH=${CX_BIN}:\$PATH npm install @SPEC@" \
  "PATH=${CX_BIN}:/usr/bin:/bin npm install @SPEC@" \
  "export PATH=${CX_BIN}:/usr/bin:/bin; npm install @SPEC@" \
  "export PATH=\"${CX_BIN}:\$PATH\" && npm install @SPEC@" \
  "env PATH=${CX_BIN}:/usr/bin:/bin npm install @SPEC@" \
  "${CX_BIN}/npm install @SPEC@" \
  "NODE_OPTIONS=--require=${tmp_root}/cx-preload.js npm install @SPEC@" \
  "NODE_OPTIONS='--require ${tmp_root}/cx-preload.js' npm install @SPEC@" \
  "export NODE_OPTIONS=--require=${tmp_root}/cx-preload.js; npm install @SPEC@" \
  "env NODE_OPTIONS=--require=${tmp_root}/cx-preload.js npm install @SPEC@"
do
  shard_row "form: ${form}" || continue
  for spec in sd-victim@1.0.0 sd-approved@1.0.0; do
    new_project
    : > "${CX_MARKS}"
    cmd="${form//@SPEC@/${spec}}"
    decision=$(jq -nc --arg c "${cmd}" --arg d "${CASE_CWD}" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}' \
      | SAFEDEPS_HOME="${CASE_HOME}" scripts/safedeps-hook-entry.sh pre 2>/dev/null \
      | jq -r '.hookSpecificOutput.permissionDecision // "allow"')
    want=allow
    [[ "${spec}" != sd-victim@* ]] || want=deny
    marks=$(wc -l < "${CX_MARKS}" | tr -d ' ')
    printf '   CX %-5s %s | marks=%s\n' "${decision}" "${cmd}" "${marks}"
    [[ "${decision}" == "${want}" ]] || cx_failures+=("the gate answers ${want}, not ${decision}: ${cmd}")
    [[ "${marks}" == 0 ]] || cx_failures+=("judging runs none of the command's code (${marks} marks: $(paste -sd'|' - < "${CX_MARKS}")): ${cmd}")
  done
done
[[ ${#cx_failures[@]} -eq 0 ]] || fail "$(printf '%s; ' "${cx_failures[@]}")"
pass "judging an install runs none of the code its PATH, NODE_OPTIONS or npm path chooses, whether the gate denies it or lets it through"

# --- 2. Installs no effect gate reads are recorded -----------------------------------
# A global install writes no lockfile anywhere, so there is nothing to read.
# The gate says so in advisory.log. Nothing runs its scripts either: the rebuild
# stays in the project, and the package is not in the project. These five forms
# are installed for real; whether a spelling is global is npm's answer, and the
# spellings npm's option parser also reads as global (`-gf`, `-g=true`,
# `--locat=global`, `--no-global=false`) are pinned as recorded in
# scripts/test/consumer-forms.sh, section 11, which asks npm without installing.
for form in \
  "npm_config_global=true npm install sd-victim" \
  "export npm_config_global=true; npm install sd-victim" \
  "npm_config_location=global npm install sd-victim" \
  "npm install -g sd-victim" \
  "npm install sd-victim --location=global"
do
  shard_row "form: ${form}" || continue
  new_project
  : > "${MARKS}"
  run_install "${form}"
  [[ -e "${tmp_root}/global/lib/node_modules/sd-victim" ]] || fail "the fixture global install lands in the sandbox prefix: ${form}"
  ungated || fail "an unpinned install the effect gate cannot read is recorded UNGATED: ${form}"
  victim_ran && fail "no script of the unverified global package runs: ${form}"
done
pass "global installs (-g, --location=global, npm_config_global/location prefixed or exported) are recorded as UNGATED and run no script"

# --- 3. Codex: detect and rollback ------------------------------------------------------
# Codex has no updatedInput, so the install is not inert and its scripts run
# during the install (documented asymmetry). The gate still reads the result
# and rolls it back.
# One row (scripts/test/lib/shard.sh), from here to its pass line.
if shard_row "on Codex, a --no-save install is detected and rolled back after its scripts ran (no inert install there)"; then
  new_project
  : > "${MARKS}"
  run_install "npm install sd-victim --no-save" codex
  rolled_back || fail "on Codex, a --no-save install of an unapproved package is rolled back"
  pass "on Codex, a --no-save install is detected and rolled back after its scripts ran (no inert install there)"
fi

# --- 4. An .npmrc that makes every install global ---------------------------------------
# `global=true` or `location=global` in the project's or the user's .npmrc sends
# a plain `npm install x` to the global prefix, where no lockfile is written.
# The command text does not show it, so the pre-guard reads those two files and
# records the install UNGATED, as it does for the same setting in the command.
# An install that went global also left no trace in the project, so nothing is
# rebuilt there either; the rebuild's own scope is pinned after this loop.
USER_NPMRC_BASE=$(cat "${npm_config_userconfig}")
# <where>|<setting>|<command>|<where npm put the package>
for carrier in \
  "project|global=true|npm install sd-victim|global" \
  "project|location=global|npm install sd-victim|global" \
  "project|global = true|npm install sd-victim|global" \
  "project|location = \"global\"|npm install sd-victim|global" \
  "project|global=1|npm install sd-victim|global" \
  "project|global=|npm install sd-victim|global" \
  "project|global=0|npm install sd-victim|unrecorded" \
  "project|location=global|npm install --location=project sd-victim|unrecorded" \
  "project|global=true|npm install --location=project sd-victim|global" \
  "project|location=global|npm install --global=false sd-victim|global" \
  "user|global=true|npm install sd-victim|global" \
  "user|location=global|npm install sd-victim|global" \
  "user|location=global|npm install --location=project sd-victim|unrecorded"
do
  shard_row "carrier: ${carrier}" || continue
  IFS='|' read -r where setting form lands <<< "${carrier}"
  new_project
  run_install "npm install sd-approved"
  [[ -z "${CASE_POST}" ]] || fail "an approved install stays quiet before the .npmrc case (post: ${CASE_POST})"
  case "${where}" in
    project) printf '%s\n' "${setting}" > "${CASE_PROJECT}/.npmrc" ;;
    user) printf '%s\n%s\n' "${USER_NPMRC_BASE}" "${setting}" > "${npm_config_userconfig}" ;;
  esac
  : > "${MARKS}"
  run_install "${form}"
  printf '%s\n' "${USER_NPMRC_BASE}" > "${npm_config_userconfig}"
  case "${lands}" in
    global)
      [[ -e "${tmp_root}/global/lib/node_modules/sd-victim" ]] \
        || fail "the fixture .npmrc sends the install to the global prefix: ${carrier}"
      ;;
    unrecorded)
      # In node_modules, and in neither record the gate reads.
      [[ -e "${CASE_PROJECT}/node_modules/sd-victim" ]] \
        && ! grep -q sd-victim "${CASE_PROJECT}/package-lock.json" "${CASE_PROJECT}/node_modules/.package-lock.json" 2>/dev/null \
        || fail "the fixture .npmrc puts the package in node_modules with no record: ${carrier}"
      ;;
  esac
  ungated || fail "an unpinned install that an .npmrc keeps off the record is recorded UNGATED: ${carrier}"
  grep -q "npmrc sets ${setting%%[ =]*}" "${CASE_HOME}/advisory.log" 2>/dev/null \
    || fail "the record names the .npmrc and the setting: ${carrier}"
  victim_ran && fail "no script of the unverified package runs: ${carrier} ($(cut -f1,2 "${MARKS}" | paste -sd, -))"
  case "${lands}" in
    global)
      [[ -z "${CASE_RAN}" ]] || fail "nothing is rebuilt where a global install left no trace: ${carrier} (${CASE_RAN})"
      grep -q 'post-verify UNGATED: no install trace in ' "${CASE_HOME}/advisory.log" \
        || fail "the post hook records that the install left no trace in the project: ${carrier}"
      ;;
    unrecorded)
      # The unrecorded package sits in the tree a rebuild would run, so no
      # rebuild runs, and the user is told. Measured with npm 11.19.0, npm also
      # left both lockfiles untouched here, so the post hook found no trace and
      # skipped the rebuild for that reason; were the hidden lockfile rewritten,
      # npm's own inventory would skip it and name the package. Either answer
      # is a skipped rebuild that says why.
      [[ -z "${CASE_RAN}" ]] || fail "npm rebuild does not run over a package no lockfile records: ${carrier} (${CASE_RAN})"
      grep -qE 'no install trace in |neither lockfile records \(node_modules/sd-victim \(sd-victim@1\.0\.0, not in either lockfile\)\)' <<< "${CASE_POST}" \
        || fail "the skipped rebuild says why: ${carrier} (post: ${CASE_POST:-<quiet>})"
      ;;
  esac
done
pass "an .npmrc that keeps installs off the record, project or user, is recorded UNGATED, and no rebuild runs what it put there"

# The rebuild that does run stays in the project. A plain `npm rebuild` reads
# the project's .npmrc, and with `global=true` or `location=global` there it
# rebuilt npm's global tree and ran the scripts of a package installed there
# unverified. Here the approved install leaves its trace in the project and the
# command then writes the .npmrc, so the post hook rebuilds with that file in
# place, while sd-victim sits in the global prefix (put there inert, between
# the command and the post hook, because run_install clears the prefix first).
seed_global_victim() {
  (cd "$1" && npm install -g sd-victim --ignore-scripts >/dev/null 2>&1) || fail "the fixture puts sd-victim in the global prefix"
}
for setting in global=true location=global; do
  shard_row "setting: ${setting}" || continue
  new_project
  : > "${MARKS}"
  run_install "npm install sd-approved && printf '%s\\n' '${setting}' > .npmrc" claude seed_global_victim
  [[ -e "${tmp_root}/global/lib/node_modules/sd-victim" ]] || fail "sd-victim is in the global prefix during the rebuild: ${setting}"
  [[ -z "${CASE_POST}" ]] || fail "the approved install confirms quietly: ${setting} (post: ${CASE_POST})"
  grep -q '^sd-approved@[^	]*	install' <<< "${CASE_RAN}" || fail "npm rebuild rebuilds the verified project tree: ${setting} (${CASE_RAN:-nothing ran})"
  victim_ran && fail "npm rebuild does not follow the .npmrc into the global tree: ${setting} ($(cut -f1,3 "${MARKS}" | paste -sd, -))"
done
pass "the rebuild stays in the project when the project .npmrc says global=true or location=global"

# The same settings can put a new version of a package over one that is on
# record, and leave the record saying the old one. A key on record is then not
# the package on disk: measured, the gate read the approved 1.0.0 in both
# lockfiles, and `npm rebuild` ran the unapproved 1.0.1's scripts.
# `<where>|<setting>|<command>`.
for carrier in \
  "project|global=0|npm install sd-swapped" \
  "project|location=global|npm install --location=project sd-swapped" \
  "user|location=global|npm install --location=project sd-swapped" \
  "project|global=0|npm update sd-swapped"
do
  shard_row "carrier: ${carrier}" || continue
  IFS='|' read -r where setting form <<< "${carrier}"
  new_project
  run_install "npm install sd-swapped@1.0.0"
  [[ -z "${CASE_POST}" ]] || fail "the approved 1.0.0 installs quietly before the version case (post: ${CASE_POST})"
  case "${where}" in
    project) printf '%s\n' "${setting}" > "${CASE_PROJECT}/.npmrc" ;;
    user) printf '%s\n%s\n' "${USER_NPMRC_BASE}" "${setting}" > "${npm_config_userconfig}" ;;
  esac
  : > "${MARKS}"
  run_install "${form}"
  printf '%s\n' "${USER_NPMRC_BASE}" > "${npm_config_userconfig}"
  [[ "$(jq -r .version "${CASE_PROJECT}/node_modules/sd-swapped/package.json")" == 1.0.1 ]] \
    && [[ "$(jq -r '.packages["node_modules/sd-swapped"].version' "${CASE_PROJECT}/package-lock.json")" == 1.0.0 ]] \
    && [[ "$(jq -r '.packages["node_modules/sd-swapped"].version' "${CASE_PROJECT}/node_modules/.package-lock.json")" == 1.0.0 ]] \
    || fail "the fixture puts 1.0.1 on disk and leaves both lockfiles at 1.0.0: ${carrier}"
  grep -q '^sd-swapped@1.0.1' "${MARKS}" \
    && fail "no script of the version no lockfile records runs: ${carrier} ($(cut -f1,2 "${MARKS}" | paste -sd, -))"
  [[ -z "${CASE_RAN}" ]] || fail "no rebuild runs over the version no lockfile records: ${carrier} (${CASE_RAN})"
  # As above: no trace here (measured), or npm's inventory naming both versions.
  grep -qE 'no install trace in |neither lockfile records \(node_modules/sd-swapped \(sd-swapped@1\.0\.1 on disk, the lockfile records sd-swapped@1\.0\.0\)\)' \
    <<< "${CASE_POST}" || fail "the skipped rebuild says why: ${carrier} (post: ${CASE_POST:-<quiet>})"
done
pass "a version written over a recorded one is not rebuilt, and the user is told why"

# The rebuild's own check, where the install did leave a trace. The approved
# install below rewrites the lockfiles, and then, between the command and the
# post hook, sd-swapped 1.0.1 is unpacked over the recorded 1.0.0 the way the
# .npmrc forms above put it there. npm's inventory sees 1.0.1, both lockfiles
# say 1.0.0, so the rebuild is skipped and the warning names both versions.
unpack_swapped_101() {
  rm -rf "$1/node_modules/sd-swapped" && mkdir -p "$1/node_modules/sd-swapped" \
    && tar -xzf "${tmp_root}/tarballs/sd-swapped-1.0.1.tgz" -C "$1/node_modules/sd-swapped" --strip-components=1 \
    || fail "the fixture unpacks sd-swapped 1.0.1 over the recorded 1.0.0"
}
# One row (scripts/test/lib/shard.sh), from here to its pass line.
if shard_row "where the install left a trace, a version no lockfile records skips the rebuild, and the warning names the key and both versions"; then
  new_project
  run_install "npm install sd-swapped@1.0.0"
  [[ -z "${CASE_POST}" ]] || fail "the approved 1.0.0 installs quietly before the version case (post: ${CASE_POST})"
  : > "${MARKS}"
  run_install "npm install sd-approved" claude unpack_swapped_101
  grep -q '^sd-swapped@1.0.1' "${MARKS}" && fail "no script of the version no lockfile records runs ($(cut -f1,2 "${MARKS}" | paste -sd, -))"
  grep -q 'neither lockfile records (node_modules/sd-swapped (sd-swapped@1.0.1 on disk, the lockfile records sd-swapped@1.0.0))' \
    <<< "${CASE_POST}" || fail "the skipped rebuild names the package and both versions (post: ${CASE_POST:-<quiet>})"
  pass "where the install left a trace, a version no lockfile records skips the rebuild, and the warning names the key and both versions"
fi

# The same files can say the opposite, and the command outranks them. None of
# these lands in the global prefix, so each is read and rolled back, and none
# is recorded UNGATED.
for carrier in \
  "project|global=false|npm install sd-victim" \
  "project|global=null|npm install sd-victim" \
  "project|location=user|npm install sd-victim" \
  "project|global=true|npm install --global=false sd-victim" \
  "project|global=true|npm install --no-global sd-victim" \
  "user|global=true|npm install --no-global sd-victim" \
  "project|GLOBAL=true|npm install sd-victim" \
  "project|; global=true|npm install sd-victim" \
  "project|global=true\nglobal=false|npm install sd-victim" \
  "project|[section]\nglobal=true|npm install sd-victim"
do
  shard_row "carrier: ${carrier}" || continue
  IFS='|' read -r where setting form <<< "${carrier}"
  new_project
  case "${where}" in
    project) printf '%b\n' "${setting}" > "${CASE_PROJECT}/.npmrc" ;;
    user) printf '%s\n%b\n' "${USER_NPMRC_BASE}" "${setting}" > "${npm_config_userconfig}" ;;
  esac
  : > "${MARKS}"
  run_install "${form}"
  printf '%s\n' "${USER_NPMRC_BASE}" > "${npm_config_userconfig}"
  [[ ! -e "${tmp_root}/global/lib/node_modules/sd-victim" ]] || fail "the fixture install stays in the project: ${carrier}"
  rolled_back || fail "the effect gate rolls back an unapproved install that stays in the project: ${carrier} (post: ${CASE_POST:-<quiet>})"
  ungated && fail "an install that stays in the project is not recorded UNGATED: ${carrier}"
  victim_ran && fail "no script of the unverified package runs: ${carrier}"
done
pass "an .npmrc that keeps installs in the project, or a command that overrides it, is read and not recorded UNGATED"

# --- 5. A tree nobody recorded is not rebuilt ---------------------------------------------
drop_hidden_lockfile() { rm -f "$1/node_modules/.package-lock.json"; }
# One row (scripts/test/lib/shard.sh), from here to its pass line.
if shard_row "a node_modules with no hidden lockfile is not rebuilt, and the user is told"; then
  new_project
  : > "${MARKS}"
  run_install "npm install sd-approved" claude drop_hidden_lockfile
  [[ -z "${CASE_RAN}" ]] || fail "npm rebuild does not run over a node_modules with no hidden lockfile (${CASE_RAN})"
  grep -q 'npm rebuild was not run' <<< "${CASE_POST}" || fail "the skipped rebuild is reported (post: ${CASE_POST:-<quiet>})"
  pass "a node_modules with no hidden lockfile is not rebuilt, and the user is told"
fi

# Which packages a rebuild runs over is asked of npm (`npm query '*'`). When
# npm does not answer, the tree is not known, so the rebuild is skipped rather
# than run over a tree nobody compared with the record. The stub stands in for
# npm's query in the PostToolUse hook only.
for behaviour in fail hang; do
  shard_row "behaviour: ${behaviour}" || continue
  new_project
  : > "${MARKS}"
  CASE_POST_PATH=$(stub_npm_path "${behaviour}" query)
  run_install "npm install sd-approved"
  CASE_POST_PATH=""
  [[ -z "${CASE_RAN}" ]] || fail "npm rebuild does not run when npm did not say what it would rebuild: ${behaviour} (${CASE_RAN})"
  grep -q 'npm rebuild was not run: safedeps asked npm which packages it would rebuild and got no answer' <<< "${CASE_POST}" \
    || fail "the skipped rebuild says npm did not answer: ${behaviour} (post: ${CASE_POST:-<quiet>})"
done
pass "when npm does not say what a rebuild would run over, the rebuild is skipped and the user is told"

# --- 6. Regression: approved installs still install, verify and rebuild -------------------
# `<fixture>|<cwd>|<form>|<where npm installs>`, directories relative to the
# project.
for carrier in \
  "project|.|npm install sd-approved|." \
  "project|.|npm install sd-approved@1.0.0|." \
  "project|.|npm install sd-approved --no-save|." \
  "project|.|cd sub && npm install sd-approved|sub" \
  "project|.|npm -C sub install sd-approved|sub" \
  "project|.|cd src && npm install sd-approved|." \
  "project|src|npm install sd-approved|." \
  "workspace|.|cd packages/a && npm install sd-approved|." \
  "workspace|packages/a|npm install sd-approved|." \
  "workspace|.|npm install sd-approved -w packages/a|." \
  "workspace|packages/a|npm install sd-approved --no-workspaces|packages/a" \
  "symws|real/a|npm install sd-approved|real/a" \
  "symws|.|cd packages/a && npm install sd-approved|real/a" \
  "symws|.|cd real/a && npm install sd-approved|real/a" \
  "symws|packages/a|npm install sd-approved --no-save|real/a"
do
  shard_row "carrier: ${carrier}" || continue
  IFS='|' read -r fixture cwd form where <<< "${carrier}"
  "new_${fixture}"
  CASE_CWD="${CASE_PROJECT}/${cwd}"
  : > "${MARKS}"
  run_install "${form}"
  [[ -z "${CASE_POST}" ]] || fail "an approved install is confirmed quietly: ${carrier} (post: ${CASE_POST})"
  ungated && fail "an install the effect gate reads is not recorded UNGATED: ${carrier}"
  grep -q '^sd-approved@[^	]*	install' <<< "${CASE_RAN}" || fail "the verified inert install is rebuilt, so its scripts run: ${carrier}"
  where=$(cd "${CASE_PROJECT}/${where}" && pwd -P)
  grep -q "	${where}/node_modules/sd-approved\$" <<< "${CASE_RAN}" \
    || fail "the rebuild runs where the install landed: ${carrier} (${CASE_RAN})"
done
pass "approved installs, including --no-save, sub-project, subdirectory, workspace and symlinked-member forms, confirm quietly and rebuild where they landed"

# --- 7. A rollback keeps what was verified before it -----------------------------------
# The rollback baseline is the state the last verified install left behind. It
# used to be the state before that install, so the baseline ran one install
# behind: an approved `npm install sd-approved` followed by an unapproved
# `npm install sd-victim` rolled back to a project without sd-approved in
# package.json, package-lock.json or node_modules. Each case below checks all
# three, on both engines, and a second approved install pins the lag itself: the
# package that goes missing is the last one verified, not the first.
# What a rollback keeps is what the files it restored record. It runs no
# package manager and removes the project's own node_modules, so nothing is
# installed until the next install.
records_dependency() {
  local package="$1"
  jq -e --arg p "${package}" '.dependencies[$p] != null' "${CASE_PROJECT}/package.json" >/dev/null \
    && jq -e --arg p "node_modules/${package}" '.packages[$p] != null' "${CASE_PROJECT}/package-lock.json" >/dev/null
}
rollback_removed_node_modules() {
  [[ ! -e "${CASE_PROJECT}/node_modules" ]] && jq -r '.systemMessage // empty' <<< "${CASE_POST}" | grep -qx 'removed .*/node_modules'
}
lacks_dependency() {
  local package="$1"
  ! jq -e --arg p "${package}" '.dependencies[$p] != null' "${CASE_PROJECT}/package.json" >/dev/null \
    && ! jq -e --arg p "node_modules/${package}" '.packages[$p] != null' "${CASE_PROJECT}/package-lock.json" >/dev/null \
    && [[ ! -e "${CASE_PROJECT}/node_modules/${package}" ]]
}
make_package sd-approved-too
approve_too() {
  ( export SAFEDEPS_HOME="${CASE_HOME}"
    . lib/ledger/ledger.sh
    safedeps_ledger_write_approved_spec npm sd-approved-too 1.0.0 >/dev/null ) \
    || fail "the second fixture approval is written"
}
for engine in claude codex; do
  shard_row "engine: ${engine}" || continue
  new_project
  approve_too
  run_install "npm install sd-approved" "${engine}"
  [[ -z "${CASE_POST}" ]] || fail "the first approved install is confirmed quietly on ${engine} (post: ${CASE_POST})"
  : > "${MARKS}"
  run_install "npm install sd-victim" "${engine}"
  rolled_back || fail "an unapproved install after an approved one is rolled back on ${engine} (post: ${CASE_POST:-<quiet>})"
  records_dependency sd-approved \
    || fail "the rollback keeps the approved install verified just before it on ${engine} (package.json: $(jq -c .dependencies "${CASE_PROJECT}/package.json"))"
  lacks_dependency sd-victim || fail "the rollback removes the unapproved install on ${engine}"
  rollback_removed_node_modules \
    || fail "the rollback removes node_modules and says so on ${engine} (post: ${CASE_POST:0:300})"
  [[ "${engine}" == codex ]] || ! victim_ran || fail "no script of the unverified package runs on ${engine}"

  run_install "npm install sd-approved-too" "${engine}"
  [[ -z "${CASE_POST}" ]] || fail "the second approved install is confirmed quietly on ${engine} (post: ${CASE_POST})"
  run_install "npm install sd-victim" "${engine}"
  rolled_back || fail "a second unapproved install is rolled back on ${engine} (post: ${CASE_POST:-<quiet>})"
  records_dependency sd-approved && records_dependency sd-approved-too \
    || fail "the rollback keeps both verified installs on ${engine} (package.json: $(jq -c .dependencies "${CASE_PROJECT}/package.json"))"
  lacks_dependency sd-victim || fail "the second rollback removes the unapproved install on ${engine}"
done
pass "a rollback returns to the state the last verified install left, on Claude Code and Codex"

# If the verified state cannot be recorded, the baseline does not move, and the
# user is told that a later rollback will undo this install too.
#
# The failure is a directory standing where the new snapshot's file list goes.
# A read-only snapshots directory was tried first and held on macOS, but CI's
# Linux image runs as root, which writes through it, and the case went red for
# the harness rather than the gate.
block_verified_snapshot() {
  local sid
  sid=$(jq -r '.snapshot_id' "${CASE_HOME}"/pending/*.json) || fail "the pending install names its snapshot"
  mkdir "${CASE_HOME}/snapshots/verified-${sid}_monitored_files.list"
}
# One row (scripts/test/lib/shard.sh), from here to its pass line.
if shard_row "a verified state that cannot be recorded leaves the baseline in place, and says so"; then
  new_project
  approve_too
  run_install "npm install sd-approved"
  baseline=$(cat "${CASE_HOME}"/confirmed_*)
  run_install "npm install sd-approved-too" claude block_verified_snapshot
  rolled_back && fail "the unrecorded case is an approved install, confirmed rather than rolled back (post: ${CASE_POST})"
  [[ "$(cat "${CASE_HOME}"/confirmed_*)" == "${baseline}" ]] \
    || fail "an unrecorded verified state leaves the baseline where it was"
  grep -q 'could not record the result as the new rollback baseline' <<< "${CASE_POST}" \
    || fail "the user is told the baseline did not move (post: ${CASE_POST:-<quiet>})"
  grep -q 'rollback baseline was not moved' "${CASE_HOME}/advisory.log" \
    || fail "advisory.log records that the baseline did not move"
  pass "a verified state that cannot be recorded leaves the baseline in place, and says so"
fi

# An unapproved install that finishes while an approved one is being verified.
# The baseline used to be copied after the checks, from whatever the project
# held by then. Measured: sd-victim, installed by a second Bash call between
# sd-approved's closure check and that copy, went into the baseline. Its own
# rollback then restored it, and the `npm ci` the rollback ran at the time ran
# its install scripts. The record is now copied before the checks and sealed only if the
# project still holds those bytes afterwards.
#
# The schedule is pinned rather than hoped for: a PATH shim on npm lets
# post-verify's real `npm rebuild` finish, then runs the second call (its
# PreToolUse and its install) before handing control back. On Claude Code that
# rebuild sits between the checks and the record. Codex has no rebuild there,
# so this pins the Claude Code schedule only; the code path is the same one.
# One row (scripts/test/lib/shard.sh), from here to its pass line. Not indented:
# the heredocs below write scripts whose text must stay as it is.
if shard_row "an unapproved install that lands while an approved one is verified stays out of the baseline and is rolled back"; then
new_project
real_npm=$(command -v npm)
race_dir=$(mktemp -d "${tmp_root}/race.XXXXXX")
mkdir -p "${race_dir}/shim"
cat > "${race_dir}/second-call.sh" <<RACE_EOF
#!/usr/bin/env bash
payload=\$(jq -nc --arg c "npm install sd-victim" --arg d "${CASE_PROJECT}" '{tool_name:"Bash",tool_input:{command:\$c},cwd:\$d}')
pre=\$(printf '%s' "\${payload}" | SAFEDEPS_HOME="${CASE_HOME}" "${ROOT_DIR}/scripts/safedeps-hook-entry.sh" pre 2>/dev/null)
cmd=\$(jq -r '.hookSpecificOutput.updatedInput.command // empty' <<< "\${pre}")
printf '%s' "\${cmd}" > "${race_dir}/second.cmd"
[[ -n "\${cmd}" ]] && (cd "${CASE_PROJECT}" && bash -c "\${cmd}") > "${race_dir}/second.log" 2>&1
printf 'exit=%s\n' "\$?" >> "${race_dir}/second.log"
RACE_EOF
cat > "${race_dir}/shim/npm" <<RACE_EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == rebuild && ! -e "${race_dir}/fired" ]]; then
  touch "${race_dir}/fired"
  "${real_npm}" "\$@"; rc=\$?
  "${race_dir}/second-call.sh"
  exit "\${rc}"
fi
exec "${real_npm}" "\$@"
RACE_EOF
chmod +x "${race_dir}/second-call.sh" "${race_dir}/shim/npm"

: > "${MARKS}"
payload=$(jq -nc --arg c "npm install sd-approved" --arg d "${CASE_PROJECT}" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}')
pre=$(printf '%s' "${payload}" | SAFEDEPS_HOME="${CASE_HOME}" scripts/safedeps-hook-entry.sh pre 2>/dev/null)
first_cmd=$(jq -r '.hookSpecificOutput.updatedInput.command // empty' <<< "${pre}")
[[ "${first_cmd}" == *--ignore-scripts* ]] || fail "the approved install runs inert on Claude Code (pre: ${pre})"
(cd "${CASE_PROJECT}" && bash -c "${first_cmd}" > "${race_dir}/first.log" 2>&1) || fail "the approved install succeeds"
payload=$(jq -nc --arg c "${first_cmd}" --arg d "${CASE_PROJECT}" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}')
first_post=$(printf '%s' "${payload}" | PATH="${race_dir}/shim:${PATH}" SAFEDEPS_HOME="${CASE_HOME}" \
  scripts/safedeps-hook-entry.sh post 2>/dev/null)
[[ -e "${race_dir}/fired" ]] || fail "the second call ran inside the first one's post-verify (post: ${first_post:-<quiet>})"
second_cmd=$(cat "${race_dir}/second.cmd")
[[ "${second_cmd}" == *--ignore-scripts* ]] || fail "the second call was let through inert to the effect gate"
grep -qx 'exit=0' "${race_dir}/second.log" || fail "the second install succeeds ($(tail -3 "${race_dir}/second.log"))"
jq -e '.dependencies["sd-victim"] != null' "${CASE_PROJECT}/package.json" >/dev/null \
  || fail "the second install landed in the project while the first was verified"

payload=$(jq -nc --arg c "${second_cmd}" --arg d "${CASE_PROJECT}" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}')
CASE_POST=$(printf '%s' "${payload}" | SAFEDEPS_HOME="${CASE_HOME}" scripts/safedeps-hook-entry.sh post 2>/dev/null)
rolled_back || fail "the unapproved install is rolled back (post: ${CASE_POST:-<quiet>})"
lacks_dependency sd-victim \
  || fail "the rollback removes the unapproved install that landed during verification (package.json: $(jq -c .dependencies "${CASE_PROJECT}/package.json"))"
victim_ran && fail "no script of the unapproved package runs, in the rebuild or the rollback ($(cut -f1,2 "${MARKS}" | paste -sd, -))"
for confirmed in "${CASE_HOME}"/confirmed_*; do
  [[ -f "${confirmed}" ]] || continue
  for recorded in "${CASE_HOME}/snapshots/$(cat "${confirmed}")"_package{,-lock}.json; do
    [[ -f "${recorded}" ]] || continue
    grep -q sd-victim "${recorded}" && fail "the baseline records the unapproved package ($(basename "${recorded}"))"
  done
done
for meta in "${CASE_HOME}"/snapshots/*_meta.json; do
  [[ -f "${meta}" ]] || continue
  for recorded in "${meta%_meta.json}"_package{,-lock}.json; do
    [[ -f "${recorded}" ]] || continue
    grep -q sd-victim "${recorded}" && fail "no snapshot a rollback can take records the unapproved package ($(basename "${recorded}"))"
  done
done
records_dependency sd-approved \
  || fail "the approved install stays (package.json: $(jq -c .dependencies "${CASE_PROJECT}/package.json"))"
grep -q 'changed while they were being verified' <<< "${first_post}" \
  || fail "the first install says its baseline was not recorded because the files changed (post: ${first_post:-<quiet>})"
grep -q 'changed while they were being verified' "${CASE_HOME}/advisory.log" \
  || fail "advisory.log records why the baseline did not move"
pass "an unapproved install that lands while an approved one is verified stays out of the baseline and is rolled back"
fi

# --- 8. A rollback runs no package manager ------------------------------------------------
# The rollback restores the files it snapshotted and removes the project's own
# node_modules. It used to reinstall, and each reinstall went somewhere nobody
# had checked: a project .npmrc with global=true sent a plain `npm ci` to the
# global prefix, and a project with no package-lock.json had its ranges
# resolved again, to a version published after the approval, whose install
# scripts then ran. With no npm in the rollback neither can happen; the next
# install is the reinstall, and the gate checks it like any other.
approve_baseline() {
  run_install "npm install sd-approved"
  [[ -z "${CASE_POST}" ]] || fail "an approved install stays quiet before the restore case (post: ${CASE_POST})"
}
# One row (scripts/test/lib/shard.sh), from here to its pass line.
if shard_row "the rollback runs no npm when the project .npmrc says global=true, and installs nothing into the global prefix"; then
  new_project
  approve_baseline
  printf 'global=true\n' > "${CASE_PROJECT}/.npmrc"
  : > "${MARKS}"
  run_install "npm install --global=false sd-victim"
  rolled_back || fail "an unapproved install beside a global .npmrc is rolled back (post: ${CASE_POST:-<quiet>})"
  rollback_removed_node_modules \
    || fail "the rollback removes the project's own node_modules and says so (node_modules: $(ls "${CASE_PROJECT}/node_modules" 2>&1 | paste -sd, -))"
  records_dependency sd-approved || fail "the restored files still record the approved install"
  [[ ! -e "${tmp_root}/global/lib/node_modules" ]] \
    || fail "the rollback installs nothing into the global prefix ($(ls "${tmp_root}/global/lib/node_modules" | paste -sd, -))"
  [[ ! -s "${MARKS}" ]] || fail "the rollback runs no install script ($(cut -f1,2 "${MARKS}" | paste -sd, -))"
  pass "the rollback runs no npm when the project .npmrc says global=true, and installs nothing into the global prefix"
fi

# A project that keeps no package-lock.json. sd-approved@1.0.0 is approved and
# installed, and then 1.0.1 is published, which nobody approved. A reinstall
# would resolve `^1.0.0` to 1.0.1; the rollback does not reinstall.
# One row (scripts/test/lib/shard.sh), from here to its pass line.
if shard_row "a rollback with no package-lock.json resolves nothing again and runs no install script"; then
  new_project
  rm -f "${CASE_PROJECT}/package-lock.json"
  printf 'package-lock=false\n' > "${CASE_PROJECT}/.npmrc"
  approve_baseline
  [[ ! -e "${CASE_PROJECT}/package-lock.json" ]] || fail "the fixture project keeps no package-lock.json"
  make_package sd-approved 1.0.1
  : > "${MARKS}"
  run_install "npm install sd-victim"
  rolled_back || fail "an unapproved install in a project with no package-lock.json is rolled back (post: ${CASE_POST:-<quiet>})"
  rollback_removed_node_modules \
    || fail "the rollback resolves nothing again: node_modules is removed, not reinstalled (node_modules: $(ls "${CASE_PROJECT}/node_modules" 2>&1 | paste -sd, -))"
  [[ ! -s "${MARKS}" ]] || fail "the rollback runs no install script ($(cut -f1,2 "${MARKS}" | paste -sd, -))"
  jq -r '.systemMessage // empty' <<< "${CASE_POST}" | grep -qx '.*/package-lock\.json does not exist' \
    && jq -r '.systemMessage // empty' <<< "${CASE_POST}" | grep -qx '.*/npm-shrinkwrap\.json does not exist' \
    || fail "the rollback says the project has no npm lockfile (post: ${CASE_POST})"
  pass "a rollback with no package-lock.json resolves nothing again and runs no install script"
else
  # Later rows install sd-approved unpinned, and get 1.0.1 because this row
  # published it; a shard that skips the row publishes it all the same.
  make_package sd-approved 1.0.1
fi

# --- 9. Workspaces: a member is not a package, and its manifest is rolled back ---------------
# The root lockfile keys each member by its path (`packages/a`). The closure
# read that key as a package named `packages` and called it unapproved. And an
# install into a member writes the member's package.json, which the snapshot did
# not keep: the rollback restored the root lockfile, the `npm ci` it ran at the
# time refused the member's new dependency, and its fallback reinstall put the
# package back.
# One row (scripts/test/lib/shard.sh), from here to its pass line.
if shard_row "an unapproved workspace install is rolled back from disk, member manifest included, and no member is read as a package"; then
  new_workspace
  : > "${MARKS}"
  run_install "npm install sd-victim -w packages/a"
  rolled_back || fail "an unapproved install into a workspace member is rolled back (post: ${CASE_POST:-<quiet>})"
  grep -q 'packages@' <<< "${CASE_POST}" && fail "a workspace member is not read as a package (post: ${CASE_POST})"
  [[ "$(jq -c '.dependencies // {}' "${CASE_PROJECT}/packages/a/package.json")" == '{}' ]] \
    || fail "the rollback restores the member's package.json ($(cat "${CASE_PROJECT}/packages/a/package.json"))"
  [[ -z "$(cd "${CASE_PROJECT}" && find . -path '*/node_modules/sd-victim' -print 2>/dev/null)" ]] \
    || fail "the rollback removes the unapproved package from disk"
  [[ ! -e "${CASE_PROJECT}/node_modules" ]] \
    || fail "the rollback removes the workspace root's own node_modules"
  jq -r '.systemMessage // empty' <<< "${CASE_POST}" | grep -qx '.*/package\.json has the key workspaces' \
    || fail "the rollback says the root package.json has the key workspaces (post: ${CASE_POST})"
  [[ "$(jq -r '.systemMessage // empty' <<< "${CASE_POST}" | grep -c '^removed .*/node_modules$')" == 1 ]] \
    || fail "the rollback names the one node_modules it removed, the workspace root's (post: ${CASE_POST})"
  victim_ran && fail "no script of the unverified package runs in a workspace rollback"
  pass "an unapproved workspace install is rolled back from disk, member manifest included, and no member is read as a package"
fi

# --- 10. A `file:` dependency's own node_modules is rebuilt with the project -----------------
# `npm rebuild` follows the link to a `file:` dependency and rebuilds what is
# in the target's node_modules, which no lockfile of the project records. The
# rebuild precondition walked the project's node_modules in bash and stopped at
# the link (validator round 2, F2): an approved install in the project then ran
# the scripts of a package sitting unrecorded in the linked library.
#
# Step 1 puts sd-victim in lib/node_modules off the record: an .npmrc there
# keeps npm from writing it down, so the install is recorded UNGATED and its
# rebuild skipped. Step 2 is an approved install in the project that links lib.
# One row (scripts/test/lib/shard.sh), from here to its pass line.
if shard_row "a package in a file: dependency's node_modules that no lockfile records is not rebuilt, and the warning names it"; then
  FILELINK_PARENT=$(mktemp -d "${tmp_root}/filelink.XXXXXX")
  FILELINK_PARENT=$(cd "${FILELINK_PARENT}" && pwd -P)
  mkdir -p "${FILELINK_PARENT}/project" "${FILELINK_PARENT}/lib"
  CASE_PROJECT="${FILELINK_PARENT}/project"
  printf '{"name":"lib","version":"1.0.0"}\n' > "${FILELINK_PARENT}/lib/package.json"
  printf '{"name":"proj","version":"1.0.0","dependencies":{"lib":"file:../lib"}}\n' > "${CASE_PROJECT}/package.json"
  # npm 9.0-9.3 (the CI image has 9.2.0) copy a `file:` dependency instead of
  # linking it unless told otherwise. The case here is the link.
  printf 'install-links=false\n' > "${CASE_PROJECT}/.npmrc"
  (cd "${CASE_PROJECT}" && npm install --ignore-scripts >/dev/null 2>&1) || fail "the fixture project with a file: dependency installs"
  [[ -L "${CASE_PROJECT}/node_modules/lib" ]] || fail "the fixture links lib into the project"
  new_safedeps_home
  printf 'global=0\n' > "${FILELINK_PARENT}/lib/.npmrc"
  CASE_CWD="${FILELINK_PARENT}/lib"
  : > "${MARKS}"
  run_install "npm install sd-victim"
  [[ -e "${FILELINK_PARENT}/lib/node_modules/sd-victim" ]] || fail "the fixture leaves sd-victim in lib/node_modules"
  ungated || fail "the install the .npmrc keeps off the record is recorded UNGATED"
  victim_ran && fail "no script of the unrecorded package runs in step 1 ($(cut -f1,2 "${MARKS}" | paste -sd, -))"
  CASE_CWD="${CASE_PROJECT}"
  : > "${MARKS}"
  # Pinned: section 8 published an unapproved sd-approved@1.0.1.
  run_install "npm install sd-approved@1.0.0"
  [[ -e "${FILELINK_PARENT}/lib/node_modules/sd-victim" ]] || fail "sd-victim is still in the linked library for step 2"
  victim_ran && fail "an approved install in the project runs no script of the package in the linked library ($(cut -f1,3 "${MARKS}" | paste -sd, -))"
  grep -q 'neither lockfile records (../lib/node_modules/sd-victim (sd-victim@1.0.0, not in either lockfile))' <<< "${CASE_POST}" \
    || fail "the skipped rebuild names the package in the linked library (post: ${CASE_POST:-<quiet>})"
  pass "a package in a file: dependency's node_modules that no lockfile records is not rebuilt, and the warning names it"
fi

# --- 11. The inert flag is the value npm reads -------------------------------------------
# npm keeps the last value an option is given. The pre-guard skipped the
# rewrite whenever the text `--ignore-scripts` stood anywhere in the command,
# so `--ignore-scripts=false` and `&& echo --ignore-scripts` ran the install
# with its scripts, and the meta said nothing was injected. Each form here is
# an approved install that asks npm, one way or another, to run its scripts. It
# must run none during the install, and the rebuild after the closure verifies
# runs them; for the install inside `sh -c`, which npm is not asked about, the
# rebuild is withheld with a warning instead. The last two rows already carry a true flag: the command runs as
# written and runs no script at all.
count_install_marks() { INSTALL_MARKS=$(grep -c '^sd-approved' "${MARKS}" || true); }
for row in \
  "npm install sd-approved@1.0.0 --ignore-scripts=false|asked" \
  "npm install sd-approved@1.0.0 --no-ignore-scripts|asked" \
  "npm install sd-approved@1.0.0 --ignore-scripts false|asked" \
  "npm install sd-approved@1.0.0 --no-ignore|asked" \
  "npm install sd-approved@1.0.0 --ignore-scripts --ign=false|asked" \
  "npm install sd-approved@1.0.0 && echo --ignore-scripts|rebuilt" \
  "X=--ignore-scripts npm install sd-approved@1.0.0|rebuilt" \
  "npm install sd-approved@1.0.0 --cache --ignore-scripts|rebuilt" \
  "npm install sd-approved@1.0.0 --prefix . --ignore-scripts=false > install.log 2>&1|asked" \
  "sh -c 'npm install sd-approved@1.0.0 --ignore-scripts=false'|asked-withheld" \
  "npm install sd-approved@1.0.0 --ignore-scripts|as written" \
  "npm install --ignore-scripts=true sd-approved@1.0.0 --save|as written"
do
  shard_row "row: ${row}" || continue
  IFS='|' read -r form want <<< "${row}"
  new_project
  : > "${MARKS}"
  INSTALL_MARKS=""
  run_install "${form}" claude count_install_marks
  [[ "${INSTALL_MARKS}" == 0 ]] \
    || fail "an approved install runs no script during the install: ${form} (ran: $(cut -f1,2 "${MARKS}" | paste -sd, -); command: ${CASE_EXEC})"
  [[ -e "${CASE_PROJECT}/node_modules/sd-approved" ]] || fail "the approved install installs: ${form}"
  if [[ "${want}" != "as written" ]]; then
    [[ "${CASE_EXEC}" != "${form}" ]] || fail "the install is rewritten: ${form}"
    if [[ "${want}" == asked-withheld ]]; then
      # npm is not asked which registry an install inside `sh -c` fetches
      # from, so the rebuild is withheld with a warning; the install stays
      # inert either way.
      [[ -z "${CASE_RAN}" ]] && grep -q 'did not run npm rebuild' <<< "${CASE_POST}" \
        || fail "an inert install the gate cannot ask npm about is not rebuilt, and the user is told: ${form} (post: ${CASE_POST:-<quiet>})"
    else
      grep -q '^sd-approved@[^	]*	install' <<< "${CASE_RAN}" \
        || fail "the verified install is rebuilt, so its scripts run after the check: ${form} (post: ${CASE_POST:-<quiet>})"
    fi
    if [[ "${want}" == asked* ]]; then
      grep -q 'sets ignore-scripts false; safedeps put --ignore-scripts after it' "${CASE_HOME}/advisory.log" \
        || fail "an install that asked for its scripts is recorded in advisory.log: ${form}"
    fi
  else
    [[ "${CASE_EXEC}" == "${form}" ]] || fail "an install that already carries the flag runs as written: ${form} (got: ${CASE_EXEC})"
    [[ -z "${CASE_RAN}" ]] || fail "an install the command made inert itself runs no script: ${form} (${CASE_RAN})"
  fi
done
pass "an approved install that asks npm for its scripts runs none during the install, wherever the request stands, and one that carries the flag runs as written"

# --- 11b. The flag stands where npm reads it as true -------------------------------------
# After the last argument is where npm reads the flag last, but not always as
# the flag: an install whose last word is an option that takes the next word
# as its value (`--cache`, `-C`) took the flag as that value and ran its
# scripts, and a run-time word that turned out to be `--` made it an operand.
# The pre-guard now reads the placed statement the way npm does and keeps a
# place only where ignore-scripts comes out true. Where a word is decided at
# run time it puts the flag after the verb and after the last argument, and
# records that nobody read which one npm keeps. npm is not asked about these
# installs (the ask's own flags would be taken the same way, or the words are
# not known), so the rebuild is withheld with a warning; the install stays
# inert either way. And a flag placed right before a `>` with no blank still
# finds the pending state, so an unapproved package in the lockfile is rolled
# back, not only flagged.
lock_approved() { (cd "${CASE_PROJECT}" && npm install sd-approved@1.0.0 --ignore-scripts >/dev/null 2>&1 && rm -rf node_modules); }
lock_victim() { (cd "${CASE_PROJECT}" && npm install sd-victim@1.0.0 --ignore-scripts >/dev/null 2>&1 && rm -rf node_modules); }
for row in \
  "npm install sd-approved@1.0.0 --cache && echo ok|withheld||" \
  "npm install sd-approved@1.0.0 --cache|collision:end-flag-not-an-option||" \
  "npm install sd-approved@1.0.0 -C|collision:end-flag-not-an-option||" \
  "npm ci \$(printf -- --)|unverified|lock_approved|" \
  "npm install sd-approved@1.0.0 \$FLAGS|unverified||FLAGS=--no-ignore-scripts" \
  "npm install sd-approved@1.0.0 \$FLAGS|unverified||FLAGS=--cache" \
  "npm install sd-approved@1.0.0>install.log|rebuilt||" \
  "npm install sd-approved@1.0.0>install.log|rolled back|lock_victim|"
do
  shard_row "row: ${row}" || continue
  IFS='|' read -r form want setup cmd_env <<< "${row}"
  new_project
  [[ -z "${setup}" ]] || "${setup}"
  : > "${MARKS}"
  INSTALL_MARKS=""
  CASE_CMD_ENV=()
  [[ -z "${cmd_env}" ]] || CASE_CMD_ENV=("${cmd_env}")
  if [[ "${want}" == collision:* ]]; then
    # A one-statement command owes the release's flag at its end, and after an
    # option that takes the next word as its value (`--cache`, `-C`) npm reads
    # that flag as the value. No rewrite keeps both the flag and npm's reading
    # of the options as written, so the gate sends none: UNDECIDED with a
    # reason of its own, the kind in advisory.log, and the install does not
    # run. The bash guard sent the rewrite, and the install took
    # `--ignore-scripts` as its cache directory or as the directory it ran in
    # (scripts/measure/core-intended-battery-rows.tsv). With a statement after
    # it the command owes no end flag, which is the first row.
    NPM_SANDBOX_TOLERANT=true
    run_install "${form}" claude count_install_marks
    unset NPM_SANDBOX_TOLERANT
    [[ "${CASE_PRE_DENY}" == *UNDECIDED*"no rewritten command was sent"*"not a finding"* ]] \
      || fail "an install whose end flag npm would read as an option's value is UNDECIDED because the flag cannot be placed: ${form} (deny: ${CASE_PRE_DENY:-<none>})"
    [[ "$(jq -r '.hookSpecificOutput | has("updatedInput")' <<< "${CASE_PRE}")" == false ]] \
      || fail "an install whose end flag cannot be placed gets no rewrite: ${form} (${CASE_PRE})"
    grep -q "pre-guard DENY: .*(${want#collision:})" "${CASE_HOME}/advisory.log" \
      || fail "advisory.log names the kind ${want#collision:}: ${form} ($(tail -2 "${CASE_HOME}/advisory.log" 2>/dev/null))"
    [[ -z "${CASE_EXEC}" && ! -s "${MARKS}" ]] \
      || fail "an install the gate did not let through does not run: ${form} (ran: ${CASE_EXEC}; scripts: $(cut -f1,2 "${MARKS}" | paste -sd, -))"
    [[ -z "$(find "${CASE_PROJECT}" -maxdepth 1 -name '-*' -print -quit)" ]] \
      || fail "judging the install makes nothing in the project: ${form} ($(find "${CASE_PROJECT}" -maxdepth 1 -name '-*' | paste -sd, -))"
    continue
  fi
  run_install "${form}" claude count_install_marks
  CASE_CMD_ENV=()
  [[ "${INSTALL_MARKS}" == 0 ]] \
    || fail "an approved install runs no script during the install: ${form} ${cmd_env} (ran: $(cut -f1,2 "${MARKS}" | paste -sd, -); command: ${CASE_EXEC})"
  [[ "${CASE_EXEC}" != "${form}" ]] || fail "the install is rewritten: ${form}"
  # The ask's own flags after a trailing `--cache` became the cache directory,
  # created in the project while the gate judged the command. (Under
  # FLAGS=--cache the install itself takes the trailing flag as its cache,
  # which is the command's doing and the reason the flag is also after the
  # verb.) A one-statement command owed the release's flag at its end, where
  # the install took it as its cache directory and made `--ignore-scripts` in
  # the project; that command is the collision row above, and the name stays
  # set aside here as the install's, not the ask's.
  if [[ "${want}" == withheld ]]; then
    [[ -z "$(find "${CASE_PROJECT}" -maxdepth 1 -name '-*' ! -name '--ignore-scripts' -print -quit)" ]] \
      || fail "asking npm about the install makes nothing in the project: ${form} ($(find "${CASE_PROJECT}" -maxdepth 1 -name '-*' ! -name '--ignore-scripts' | paste -sd, -))"
  fi
  case "${want}" in
    withheld)
      [[ -z "${CASE_RAN}" ]] && grep -q 'did not run npm rebuild' <<< "${CASE_POST}" \
        || fail "an inert install npm was not asked about is not rebuilt, and the user is told: ${form} (post: ${CASE_POST:-<quiet>})"
      ;;
    unverified)
      # Nobody read whether npm kept the flag, so the post hook does not say
      # the install's scripts did not run.
      [[ -z "${CASE_RAN}" ]] && grep -q 'safedeps did not read all of the command it wrote as the shell will' <<< "${CASE_POST}" \
        && ! grep -q 'install scripts were not run' <<< "${CASE_POST}" \
        || fail "an install whose flag nobody read is not rebuilt, and the user is told safedeps did not read all of the command: ${form} (post: ${CASE_POST:-<quiet>})"
      ;;
    rebuilt)
      grep -q '^sd-approved@[^	]*	install' <<< "${CASE_RAN}" \
        || fail "the verified install is rebuilt, so its scripts run after the check: ${form} (post: ${CASE_POST:-<quiet>})"
      ;;
    "rolled back")
      rolled_back && [[ ! -e "${CASE_PROJECT}/node_modules/sd-victim" ]] && ! victim_ran \
        || fail "an install whose lockfile holds an unapproved package is rolled back: ${form} (post: ${CASE_POST:-<quiet>})"
      ;;
  esac
  if [[ "${want}" == unverified ]]; then
    grep -q 'holds a word the shell decides at run time' "${CASE_HOME}/advisory.log" \
      || fail "an install whose flag nobody could read is recorded in advisory.log: ${form}"
  fi
done
pass "the flag stands where npm reads it as true: not as a trailing option's value, not after a run-time --, and the pending state is found before a > with no blank"

# --- 11c. A word any shell expansion decides --------------------------------------------
# Which words the shell decides at run time is read from its expansions, step by
# step. The list it replaced knew `$`, backquotes and globs and not the tilde:
# `HOME=--cache; npm install x ~` read `~` as written, the flag went after it
# alone, the shell handed npm `--cache` there, and npm took the flag as the
# cache directory and ran the install's scripts, with nothing recorded. One row
# per step that can hand npm a word it does not show: tilde (`~`, `~-`), brace,
# arithmetic, process substitution and pathname (a glob that matches a file
# named `--cache`); parameter and command substitution are the rows of 11b. The
# assignment tilde and zsh's `=cmd` cannot make an option, and these rows run
# under bash, where `=npm` is a word as written; they hold the reading and the
# record. Each install runs no script while it installs, and is recorded as one
# whose flag nobody read.
plant_cache_file() { : > "${CASE_PROJECT}/--cache"; }
for row in \
  "HOME=--cache; npm install sd-approved@1.0.0 ~|" \
  "OLDPWD=--cache; npm install sd-approved@1.0.0 ~-|" \
  "npm install sd-approved@1.0.0 {--cache,}|" \
  "npm install sd-approved@1.0.0 --fetch-retries {1,--cache}|" \
  $'shopt -s extglob\nnpm install sd-approved@1.0.0 @(--cache)|plant_cache_file' \
  "npm install sd-approved@1.0.0 --fetch-retries \$((1))|" \
  "npm install sd-approved@1.0.0 --message <(true)|" \
  "npm install sd-approved@1.0.0 --cach?|plant_cache_file" \
  "npm install sd-approved@1.0.0 --message a=~|" \
  "npm install sd-approved@1.0.0 --message =npm|"
do
  shard_row "row: ${row}" || continue
  # The extglob form spans two lines, which `read` would cut at the first.
  form="${row%|*}" setup="${row##*|}"
  new_project
  [[ -z "${setup}" ]] || "${setup}"
  : > "${MARKS}"
  INSTALL_MARKS=""
  run_install "${form}" claude count_install_marks
  [[ "${INSTALL_MARKS}" == 0 ]] \
    || fail "an approved install runs no script during the install: ${form} (ran: $(cut -f1,2 "${MARKS}" | paste -sd, -); command: ${CASE_EXEC})"
  [[ -e "${CASE_PROJECT}/node_modules/sd-approved" ]] || fail "the approved install installs: ${form}"
  grep -q 'holds a word the shell decides at run time' "${CASE_HOME}/advisory.log" \
    || fail "an install holding a word the shell expands is recorded in advisory.log: ${form}"
  ! grep -qE 'install scripts were not run|no install script was run' <<< "${CASE_POST}" \
    || fail "the post hook does not say the scripts of an install whose flag nobody read did not run: ${form} (post: ${CASE_POST})"
done
pass "an install holding a word any shell expansion decides runs no script while it installs, and is recorded"

# An install whose flag nobody read has its scripts run during the install when
# the words around the flags undo both: here the substitution splits into an
# override and a value option that takes the trailing flag. The record says so
# before the command runs; the post hook said "install scripts were not run",
# and a rollback with no confirmed snapshot said "no install script was run".
# No line says that any more: a line says what safedeps did. The meta records
# that the flag went in unread (ignore_scripts_unread), and that adds the one
# warning that safedeps did not read all of the command it wrote.
# The meta is read between the install and the post hook, which consumes it.
capture_meta() { CASE_META=$(cat "${CASE_HOME}"/snapshots/*_meta.json 2>/dev/null) || CASE_META=""; }
for row in \
  'npm ci $(printf -- "--no-ignore-scripts --cache")|lock_approved' \
  'npm ci $(printf -- "--no-ignore-scripts --cache")|lock_victim'
do
  shard_row "row: ${row}" || continue
  IFS='|' read -r form setup <<< "${row}"
  new_project
  "${setup}"
  : > "${MARKS}"
  CASE_META=""
  run_install "${form}" claude capture_meta
  jq -e '.ignore_scripts_injected == true and .ignore_scripts_unread == true' <<< "${CASE_META}" >/dev/null \
    || fail "the meta records that nobody read the flag: ${form} (${setup}) (meta: ${CASE_META:-<none>})"
  ! grep -qE 'install scripts were not run|no install script was run' <<< "${CASE_POST}" \
    || fail "the post hook does not say no install script ran: ${form} (${setup}) (post: ${CASE_POST})"
  if [[ "${setup}" == lock_victim ]]; then
    rolled_back && grep -q "safedeps did not read all of the command it wrote as the shell will" <<< "${CASE_POST}" \
      || fail "the rollback says safedeps did not read all of the command it wrote: ${form} (post: ${CASE_POST})"
  else
    grep -q 'safedeps did not read all of the command it wrote as the shell will' <<< "${CASE_POST}" \
      || fail "the post hook says safedeps did not read all of the command it wrote: ${form} (post: ${CASE_POST:-<quiet>})"
  fi
done
pass "no post hook line says no install script ran, and one whose flag went in unread says safedeps did not read all of the command"

# --- 11d. The flag after the verb is a floor under the reading --------------------------
# Every rewritten install also gets the flag right after its verb, where the
# release put it. A word the reading misses as one the shell expands can take
# the flag after the last argument as its value; the flag after the verb still
# stands. npm reads the two flags as one: an install that carries both runs no
# script and installs.
for form in \
  "npm install --ignore-scripts sd-approved@1.0.0 --ignore-scripts" \
  "npm install --ignore-scripts sd-approved@1.0.0 --no-ignore-scripts --ignore-scripts" \
  "npm install --ignore-scripts sd-approved@1.0.0 --cache --ignore-scripts"
do
  shard_row "form: ${form}" || continue
  new_project
  : > "${MARKS}"
  INSTALL_MARKS=""
  run_install "${form}" claude count_install_marks
  [[ "${INSTALL_MARKS}" == 0 ]] \
    || fail "an install that carries the flag after its verb and after its last argument runs no script: ${form} (ran: $(cut -f1,2 "${MARKS}" | paste -sd, -))"
  [[ -e "${CASE_PROJECT}/node_modules/sd-approved" ]] || fail "an install that carries the flag twice installs: ${form}"
done
pass "npm reads the flag after the verb and the flag after the last argument as one, and the one after the verb stands when a later word takes the other"

# --- 11e. An install in text the rewrite cannot read ----------------------------------
# v2.18.0 gave no --ignore-scripts to a command that ran an npm install it
# could not read -- one in a double-quoted script with an escape or a
# substitution in it, one in a script handed to ksh, one beside a heredoc body
# piped to another command -- and dropped the flags of the command's other
# installs with it, where v2.17.2 had put the flag right after each verb
# (scripts/measure/inert-downgrade-grid.sh measures both trees). The rewrite
# puts it there again and records that nobody read it. Each approved install
# here runs no script while it installs, and no post hook line says its
# scripts did not run. A row whose shell is not installed is skipped and says
# so.
for row in \
  'true; sh -c "npm install sd-approved@1.0.0 \"--loglevel=warn\""|sh' \
  'eval "npm install sd-approved@1.0.0 \"--loglevel=warn\""|sh' \
  'true; bash -c "npm install sd-approved@1.0.0 $(printf -- --loglevel=warn)"|bash' \
  'true; dash -c "npm install sd-approved@1.0.0 `printf -- --loglevel=warn`"|dash' \
  "true; ksh -c 'npm install sd-approved@1.0.0'|ksh" \
  $'npm install sd-approved@1.0.0 && cat <<E | wc -l\nnpm install sd-approved@1.0.0\nE|sh'
do
  form="${row%|*}" needs="${row##*|}"
  if ! command -v "${needs}" > /dev/null 2>&1; then
    printf '# skipped, %s is not installed: %s\n' "${needs}" "${form}"
    continue
  fi
  new_project
  : > "${MARKS}"
  INSTALL_MARKS=""
  run_install "${form}" claude count_install_marks
  [[ "${INSTALL_MARKS}" == 0 ]] \
    || fail "an approved install in text the rewrite cannot read runs no script during the install: ${form} (ran: $(cut -f1,2 "${MARKS}" | paste -sd, -); command: ${CASE_EXEC})"
  [[ -e "${CASE_PROJECT}/node_modules/sd-approved" ]] || fail "the approved install installs: ${form}"
  grep -q 'safedeps did not read as a command holds an npm install verb' "${CASE_HOME}/advisory.log" \
    || fail "an install in text the rewrite cannot read is recorded in advisory.log: ${form}"
  ! grep -qE 'install scripts were not run|no install script was run' <<< "${CASE_POST}" \
    || fail "the post hook does not say the scripts of an install whose flag nobody read did not run: ${form} (post: ${CASE_POST})"
done
pass "an approved install in text the rewrite cannot read runs no script while it installs, and is recorded as one whose flag nobody read"

# --- every rewrite holds the release's -------------------------------------------------
release_floor_settle
pass "deleting flags the hook inserted gives the release's rewrite, for every install this battery rewrites"

# --- the fixture never left the machine ---------------------------------------------------
# A list run (--shard-list) installs nothing, so nothing reached the registry.
shard_listing || npm_sandbox_registry_was_local

shard_end
printf 'lockless-forms passed\n'
