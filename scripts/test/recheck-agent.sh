#!/usr/bin/env bash
# safedeps: the daily re-check agent's runtime, and what building it may touch.
#
# scripts/install/install-safedeps-recheck-agent.mjs builds a copy of the CLI
# for launchd to run (`stage --root DIR` builds it anywhere, `install` builds it
# in ~/.safedeps/agent and registers it). v2.19.1 built it by removing the old
# lib/ and copying a new one in, and that had four holes a validator found:
#
#   F1  `stage --root <this checkout>` removed the checkout's own lib/
#   F2  `stage --root DIR` removed whatever DIR/lib held, notes of the user's included
#   F3  a symbolic link in lib/ threw after the old lib/ was gone, so an agent
#       already installed was left with half a runtime
#   M   a file's mode came from its extension, not from the source
#   R   "removed first, so the copy holds nothing older" had no row: the line
#       could be deleted and the suite stayed green
#
# The runtime's re-check reads the approvals store with the core it finds
# beside its own bin (sf_core in bin/safedeps), and a runtime the installer
# built without one failed every daily re-check with core_missing. So the
# runtime carries this machine's core, both digests count it, and a checkout
# without it is refused by name. A fixture's core is a stand-in script: these
# rows copy, hash and refuse it, and none of them reads a store with it
# (scripts/test/watch.sh runs a runtime with the real core).
#
# Each fixture is a small checkout of its own (the installer finds its source
# from where it lives), so a row that goes wrong damages a copy and never this
# tree. Every row runs and reports whatever another one answered: a row's
# fixtures are its own, and one run then says which of the rows a change turns
# red. The battery exits non-zero when any row did not pass.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "${ROOT_DIR}"

INSTALLER=scripts/install/install-safedeps-recheck-agent.mjs
failures=0

pass() { printf 'ok - %s\n' "$1"; }
bad() { printf 'not ok - %s\n' "$1" >&2; failures=$((failures + 1)); }
# A check that did not hold: says so and ends the row it is in. A row runs in
# a subshell of its own (below), so this ends that and nothing else, from a
# helper or a condition alike.
no() { printf '# %s\n' "$*" >&2; exit 1; }
skip() { printf 'ok - %s: SKIPPED (%s)\n' "$1" "$2"; }

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-recheck-agent.XXXXXX")
cleanup() {
  local rc=$?
  if (( rc == 0 && failures == 0 )); then
    rm -rf "${tmp_root}"
  else
    printf '# failed row artifacts: %s\n' "${tmp_root}" >&2
  fi
}
trap cleanup EXIT

# row NAME FUNCTION: runs the row's function in a subshell with errexit on, so
# a command that fails unexpectedly ends the row too, and reports it.
row() {
  local rc=0
  set +e
  ( set -e; "$2" )
  rc=$?
  set -e
  if (( rc == 0 )); then pass "$1"; else bad "$1"; fi
}

new_dir() { mktemp -d "${tmp_root}/row.XXXXXX"; }

# This machine's core under a checkout or a runtime, where the CLI looks for
# its own (sf_core in bin/safedeps): bin/native/<os>-<arch>/safedeps-core, the
# platform read from the machine bash was built for. Written here again, so the
# rows hold the installer to the CLI's place and not to its own answer.
core_file() {
  local machine="${BASH_VERSINFO[5]:-}" os="" arch=""
  case "${machine}" in
    *-darwin*) os=darwin ;;
    *-linux*) os=linux ;;
  esac
  case "${machine%%-*}" in
    arm64|aarch64) arch=arm64 ;;
    x86_64|amd64) arch=x64 ;;
  esac
  [[ -n "${os}" && -n "${arch}" ]] || return 1
  printf 'bin/native/%s-%s/safedeps-core' "${os}" "${arch}"
}
CORE=$(core_file) || { printf 'not ok - no core is built for %s, so this battery has no core to place\n' "${BASH_VERSINFO[5]:-an unnamed machine}"; exit 1; }

# A checkout the installer can run from: it finds bin/, lib/, the wrapper and
# this machine's core beside its own scripts/install/ directory. The core is a
# stand-in that says what it is.
make_checkout() { # DIR
  mkdir -p "$1/scripts/install" "$1/bin" "$1/$(dirname "${CORE}")"
  cp "${INSTALLER}" "$1/${INSTALLER}"
  cp bin/safedeps "$1/bin/safedeps"
  cp -R lib "$1/lib"
  cp scripts/safedeps-recheck-alert.sh "$1/scripts/safedeps-recheck-alert.sh"
  printf '#!/bin/sh\necho "safedeps-core fixture"\n' > "$1/${CORE}"
  chmod 755 "$1/${CORE}"
}

row_machine_core_process_results() {
  local d co node_bin kind expected rc
  kind="$1"
  node_bin=$(command -v node)
    d=$(new_dir); d=$(cd "${d}" && pwd -P); co="${d}/checkout"
    make_checkout "${co}"
    mkdir "${d}/commands"
    case "${kind}" in
      start) printf '#!/bin/sh\nprintf started > "$PROCESS_MARKER"\n' > "${d}/commands/bash"; chmod 644 "${d}/commands/bash"; expected='could not start bash: spawnSync error EACCES' ;;
      overflow) printf '#!/bin/sh\nprintf started > "$PROCESS_MARKER"\nexec /usr/bin/head -c 2097152 /dev/zero\n' > "${d}/commands/bash"; chmod 755 "${d}/commands/bash"; expected='started bash: spawnSync error ENOBUFS; signal SIGTERM' ;;
      signal) printf '#!/bin/sh\nprintf started > "$PROCESS_MARKER"\nkill -KILL $$\n' > "${d}/commands/bash"; chmod 755 "${d}/commands/bash"; expected='bash terminated by signal SIGKILL' ;;
      exit) printf '#!/bin/sh\nprintf started > "$PROCESS_MARKER"\nexit 2\n' > "${d}/commands/bash"; chmod 755 "${d}/commands/bash"; expected='ran bash: exit 2' ;;
    esac
    rc=0
    PROCESS_MARKER="${d}/started" HOME="${d}/home" PATH="${d}/commands" "${node_bin}" "${co}/${INSTALLER}" stage --root "${d}/runtime" > "${d}/out" 2> "${d}/err" || rc=$?
    [[ "${rc}" == 1 && ! -e "${d}/runtime" && ! -s "${d}/out" ]] || no "${kind}: the failed machine reading built a runtime or returned another answer"
    if [[ "${kind}" == start ]]; then
      [[ ! -e "${d}/started" ]] || no "${kind}: the child started"
    else
      [[ "$(cat "${d}/started")" == started ]] || no "${kind}: no start marker"
      ! grep -qF 'could not start' "${d}/err" || no "${kind}: a started child reported as not started: $(cat "${d}/err")"
    fi
    printf 'safedeps re-check agent: could not read which core this machine runs from %s (%s)\n' "${co}/lib/watch/scan.sh" "${expected}" > "${d}/expected"
    cmp -s "${d}/expected" "${d}/err" || no "${kind}: $(cat "${d}/err")"
}
row_machine_core_start() { row_machine_core_process_results start; }
row_machine_core_overflow() { row_machine_core_process_results overflow; }
row_machine_core_signal() { row_machine_core_process_results signal; }
row_machine_core_exit() { row_machine_core_process_results exit; }
row "the machine-core reading names EACCES when bash did not start" row_machine_core_start
row "the machine-core reading names ENOBUFS and SIGTERM after bash started" row_machine_core_overflow
row "the machine-core reading names the signal that ended bash" row_machine_core_signal
row "the machine-core reading names bash exit 2" row_machine_core_exit

home="${tmp_root}/home"
mkdir -p "${home}"
LAST_RC=0
# stage CHECKOUT ROOT: the checkout's installer builds the runtime at ROOT.
# Leaves its exit status in LAST_RC and its output in last.out and last.err.
stage() {
  LAST_RC=0
  HOME="${home}" node "$1/${INSTALLER}" stage --root "$2" > "${tmp_root}/last.out" 2> "${tmp_root}/last.err" || LAST_RC=$?
}
stage_ok() { # CHECKOUT ROOT
  stage "$1" "$2"
  (( LAST_RC == 0 )) || no "stage exited ${LAST_RC}: $(head -c 300 "${tmp_root}/last.err")"
}
# stage_refused CHECKOUT ROOT TEXT WATCH: stage leaves everything under WATCH as
# it was, exits non-zero and says TEXT. What it did comes first: a refusal that
# came after the damage is not one.
stage_refused() {
  local before
  before=$(digest "$4")
  stage "$1" "$2"
  [[ "$(digest "$4")" == "${before}" ]] || no "stage --root $2 changed what is under $4"
  (( LAST_RC != 0 )) || no "stage --root $2 exited 0"
  grep -qF -- "$3" "${tmp_root}/last.err" || no "stage --root $2 did not say '$3': $(head -c 300 "${tmp_root}/last.err")"
}

# Every name, kind and content under DIR, so a changed, added or removed entry
# shows. Links are listed and not followed.
digest() { # DIR
  ( cd "$1" && find . | LC_ALL=C sort && find . -type f -exec cksum {} + | LC_ALL=C sort )
}

if stat -c %a / > /dev/null 2>&1; then
  mode_of() { stat -c %a "$1"; }
else
  mode_of() { stat -f %Lp "$1"; }
fi

# The runtime answers `version` as launchd would run it, from its own place.
runtime_loads() { # ROOT
  HOME="${home}" "$1/bin/safedeps" --json version > /dev/null 2>&1 || no "the runtime at $1 does not answer version"
}

# What DIR holds, one path to a line.
entries() { find "$1" -mindepth 1 -maxdepth 1 | LC_ALL=C sort; }

# Nothing beside ROOT in its parent: no staging or aside directory is left.
parent_holds_only() { # ROOT
  local left
  left=$(entries "$(dirname "$1")")
  [[ "${left}" == "$1" ]] || no "the parent of $1 holds: ${left//$'\n'/ }"
}

# No staging or aside directory of ROOT's is left beside it, in a parent that
# holds other things too.
no_scraps() { # ROOT
  local scraps
  scraps=$(find "$(dirname "$1")" -mindepth 1 -maxdepth 1 -name ".$(basename "$1").*")
  [[ -z "${scraps}" ]] || no "left beside $1: ${scraps//$'\n'/ }"
}

# ---- a root that is not there ---------------------------------------------------------
row_fresh() {
  local d co
  d=$(new_dir); co="${d}/co"; make_checkout "${co}"
  stage_ok "${co}" "${d}/out/agent" || return 1
  diff -r "${co}/lib" "${d}/out/agent/lib" > /dev/null || no "lib/ is not the checkout's lib/"
  [[ -x "${d}/out/agent/bin/safedeps" && -x "${d}/out/agent/scripts/safedeps-recheck-alert.sh" ]] || no "an entry point is not executable"
  [[ -f "${d}/out/agent/.safedeps-recheck-runtime" ]] || no "the runtime has no marker"
  runtime_loads "${d}/out/agent" || return 1
  parent_holds_only "${d}/out/agent" || return 1
}
row "a runtime is built whole where there was none" row_fresh

# ---- F1: the checkout is not a place to build into ---------------------------------------
row_checkout() {
  local d co root
  d=$(new_dir); co="${d}/co"; make_checkout "${co}"
  mkdir "${d}/side"; ln -s "${co}" "${d}/side/link"
  # The roots that do not exist yet come first: with the guard gone, only they
  # are still reached (the others are refused as roots that hold files), and
  # the build into them is what the guard keeps out.
  for root in "${co}/agent" "${co}/lib/x" "${d}/side/link/agent" "${co}" "${d}"; do
    stage_refused "${co}" "${root}" "this checkout" "${d}"
  done
}
row "stage refuses a root that is, holds or lies inside the checkout, and touches nothing" row_checkout

# ---- F2: a directory that holds other files is not replaced -----------------------------
row_foreign() {
  local d co root
  d=$(new_dir); co="${d}/co"; make_checkout "${co}"
  mkdir -p "${d}/notes/lib" "${d}/other" "${d}/real"
  printf 'precious\n' > "${d}/notes/lib/notes.txt"
  printf 'keep\n' > "${d}/other/keep"
  printf 'file\n' > "${d}/afile"
  ln -s "${d}/real" "${d}/linkroot"
  for root in notes other; do
    stage_refused "${co}" "${d}/${root}" "was not built by this installer" "${d}"
  done
  for root in afile linkroot; do
    stage_refused "${co}" "${d}/${root}" "not a plain directory" "${d}"
  done
  grep -qx precious "${d}/notes/lib/notes.txt" || no "notes.txt was lost"
}
row "stage refuses a root that holds files it did not build, and keeps them" row_foreign

# ---- an empty root is taken -------------------------------------------------------------
row_empty() {
  local d co
  d=$(new_dir); co="${d}/co"; make_checkout "${co}"
  mkdir -p "${d}/out/empty"
  stage_ok "${co}" "${d}/out/empty" || return 1
  diff -r "${co}/lib" "${d}/out/empty/lib" > /dev/null || no "lib/ is not the checkout's lib/"
  runtime_loads "${d}/out/empty" || return 1
  parent_holds_only "${d}/out/empty" || return 1
  [[ -f "${d}/out/empty/.safedeps-recheck-runtime" ]] || no "the runtime has no marker"
}
row "stage takes an empty root" row_empty

# ---- F3: a link in lib/ ends the build and leaves the old runtime ---------------------------
row_link() {
  local d co root
  d=$(new_dir); co="${d}/co"; make_checkout "${co}"
  root="${d}/out/agent"
  stage_ok "${co}" "${root}" || return 1
  ln -s closure.sh "${co}/lib/npm/zz-link.sh"
  stage_refused "${co}" "${root}" "neither a file nor a directory" "${d}/out"
  runtime_loads "${root}" || return 1
  parent_holds_only "${root}" || return 1
  # And with no runtime there yet, nothing is left behind.
  mkdir "${d}/fresh"
  stage_refused "${co}" "${d}/fresh/agent" "neither a file nor a directory" "${d}/fresh"
}
row "a link in lib/ stops the build and leaves the runtime already there as it was" row_link

# ---- a runtime that does not load is not put in place -------------------------------------
row_smoke() {
  local d good broken root
  d=$(new_dir); good="${d}/good"; broken="${d}/broken"
  make_checkout "${good}"; make_checkout "${broken}"
  printf '#!/usr/bin/env bash\necho "broken on purpose" >&2\nexit 1\n' > "${broken}/bin/safedeps"
  root="${d}/out/agent"
  stage_ok "${good}" "${root}" || return 1
  stage_refused "${broken}" "${root}" "runtime smoke failed" "${d}/out"
  runtime_loads "${root}" || return 1
  parent_holds_only "${root}" || return 1
}
row "a built runtime whose bin does not load never replaces the one that does" row_smoke

# ---- M: a file's mode is the source's ---------------------------------------------------
modes_stick() {
  local probe="${tmp_root}/mode-probe"
  : > "${probe}"
  chmod 640 "${probe}"
  [[ "$(mode_of "${probe}")" == 640 ]]
}
row_modes() {
  local d co root
  d=$(new_dir); co="${d}/co"; make_checkout "${co}"
  mkdir "${co}/lib/modes"
  printf 'x\n' > "${co}/lib/modes/tool";     chmod 755 "${co}/lib/modes/tool"
  printf 'x\n' > "${co}/lib/modes/data.sh";  chmod 644 "${co}/lib/modes/data.sh"
  printf 'x\n' > "${co}/lib/modes/shared";   chmod 664 "${co}/lib/modes/shared"
  printf 'x\n' > "${co}/lib/modes/private";  chmod 600 "${co}/lib/modes/private"
  root="${d}/out/agent"
  stage_ok "${co}" "${root}" || return 1
  [[ "$(mode_of "${root}/lib/modes/tool")" == 755 ]] || no "a file with no extension and mode 755 got $(mode_of "${root}/lib/modes/tool")"
  [[ "$(mode_of "${root}/lib/modes/data.sh")" == 644 ]] || no "a .sh file with mode 644 got $(mode_of "${root}/lib/modes/data.sh")"
  [[ "$(mode_of "${root}/lib/modes/shared")" == 644 ]] || no "a group-writable file got $(mode_of "${root}/lib/modes/shared"), not 644"
  [[ "$(mode_of "${root}/lib/modes/private")" == 600 ]] || no "a file with mode 600 got $(mode_of "${root}/lib/modes/private")"
  [[ "$(mode_of "${root}/bin/safedeps")" == 755 && "$(mode_of "${root}/scripts/safedeps-recheck-alert.sh")" == 755 ]] || no "an entry point is not 755"
}
if modes_stick; then
  row "a runtime file has the source's mode, whatever its name" row_modes
else
  skip "a runtime file has the source's mode, whatever its name" "this filesystem does not keep modes"
fi

# ---- R: the runtime holds what the checkout holds and nothing older -------------------------
row_current() {
  local d co root
  d=$(new_dir); co="${d}/co"; make_checkout "${co}"
  printf 'old\n' > "${co}/lib/was-here.txt"
  root="${d}/out/agent"
  stage_ok "${co}" "${root}" || return 1
  [[ -f "${root}/lib/was-here.txt" ]] || no "the file of the first build is not there to be removed"
  # A file the checkout dropped, and files a run left in the runtime itself.
  rm "${co}/lib/was-here.txt"
  mkdir -p "${root}/lib/oldgone"
  printf 'stale\n' > "${root}/lib/stale-old.sh"
  printf 'stale\n' > "${root}/lib/oldgone/x.txt"
  printf 'stale\n' > "${root}/bin/stale-tool"
  mkdir -p "${root}/scripts"
  printf 'stale\n' > "${root}/scripts/stale.sh"
  stage_ok "${co}" "${root}" || return 1
  local gone
  for gone in lib/was-here.txt lib/stale-old.sh lib/oldgone bin/stale-tool scripts/stale.sh; do
    [[ ! -e "${root}/${gone}" ]] || no "${gone} survived a second build"
  done
  diff -r "${co}/lib" "${root}/lib" > /dev/null || no "lib/ is not the checkout's lib/"
  local again
  again=$(digest "${root}")
  stage_ok "${co}" "${root}" || return 1
  [[ "$(digest "${root}")" == "${again}" ]] || no "a third build with nothing changed changed the runtime"
  parent_holds_only "${root}" || return 1
}
row "a second build holds what the checkout holds and nothing older, and a third changes nothing" row_current

# ---- the core: this machine's, beside the runtime's own bin ---------------------------------
# The runtime's CLI looks for its core beside itself and nowhere else, so the
# runtime carries this machine's core from its checkout, as the checkout has
# it, and no other platform's.
row_core() {
  local d co root
  d=$(new_dir); co="${d}/co"; make_checkout "${co}"
  mkdir -p "${co}/bin/native/plan9-mips"
  printf '#!/bin/sh\necho other\n' > "${co}/bin/native/plan9-mips/safedeps-core"
  chmod 755 "${co}/bin/native/plan9-mips/safedeps-core"
  root="${d}/out/agent"
  stage_ok "${co}" "${root}" || return 1
  [[ -f "${root}/${CORE}" && ! -L "${root}/${CORE}" && -x "${root}/${CORE}" ]] || no "the runtime has no executable ${CORE}"
  cmp -s "${co}/${CORE}" "${root}/${CORE}" || no "the runtime's ${CORE} is not the checkout's"
  [[ "$("${root}/${CORE}")" == "safedeps-core fixture" ]] || no "the runtime's core does not run"
  [[ "$(find "${root}/bin/native" -type f | wc -l | tr -d ' ')" == 1 ]] || no "bin/native holds: $(find "${root}/bin/native" | tr '\n' ' ')"
  parent_holds_only "${root}" || return 1
}
row "a runtime carries this machine's core from its checkout, beside its bin, and no other platform's" row_core

# ---- a checkout with no core is refused by name ---------------------------------------------
# No core, a core that cannot run, and a link to one: none is a core the
# runtime can carry (the digests count regular files, and a link is none).
# Each is refused by name before anything is built, and a runtime already in
# place stays as it was.
row_no_core() {
  local d co
  d=$(new_dir)
  co="${d}/none"; make_checkout "${co}"; rm -rf "${co}/bin/native"
  stage_refused "${co}" "${d}/out/agent" "core-missing: " "${d}"
  grep -qF "${CORE}" "${tmp_root}/last.err" || no "the refusal does not name ${CORE}: $(head -c 300 "${tmp_root}/last.err")"
  co="${d}/noexec"; make_checkout "${co}"; chmod 644 "${co}/${CORE}"
  stage_refused "${co}" "${d}/out/agent" "core-missing: " "${d}"
  co="${d}/link"; make_checkout "${co}"
  mv "${co}/${CORE}" "${co}/${CORE}.real"; ln -s safedeps-core.real "${co}/${CORE}"
  stage_refused "${co}" "${d}/out/agent" "core-missing: " "${d}"
  co="${d}/gone"; make_checkout "${co}"
  stage_ok "${co}" "${d}/out/agent" || return 1
  mv "${co}/${CORE}" "${d}/kept-core"
  stage_refused "${co}" "${d}/out/agent" "core-missing: " "${d}"
  runtime_loads "${d}/out/agent" || return 1
  cmp -s "${d}/kept-core" "${d}/out/agent/${CORE}" || no "the runtime in place lost its core"
  no_scraps "${d}/out/agent" || return 1
}
row "stage refuses a checkout with no core for this machine by name, and touches nothing" row_no_core

# ---- what the runtime says it is ---------------------------------------------------------------
# The installer writes .safedeps-runtime.json; the scan (safedeps_watch_runtime_info
# in lib/watch/scan.sh) reads it, hashes the source checkout by the same rule
# and calls the runtime stale when the checkout has moved on.
runtime_info() { # RUNTIME
  ( SAFEDEPS_REPO_DIR="$1" SAFEDEPS_VERSION=unused HOME="${home}"
    # shellcheck source=../../lib/watch/scan.sh
    source "$1/lib/watch/scan.sh"
    safedeps_watch_runtime_info "$(mktemp "${tmp_root}/said.XXXXXX")" )
}
row_runtime_meta() {
  local d co root meta info
  d=$(new_dir); co="${d}/co"; make_checkout "${co}"
  root="${d}/out/agent"
  stage_ok "${co}" "${root}" || return 1
  meta="${root}/.safedeps-runtime.json"
  [[ -f "${meta}" ]] || no "the runtime has no .safedeps-runtime.json"
  [[ "$(jq -r '.version' "${meta}")" == "$(HOME="${home}" "${root}/bin/safedeps" --json version | jq -r '.version')" ]] || no "the recorded version is not the bin's"
  [[ "$(jq -r '.source_repo' "${meta}")" == "$(cd -P "${co}" && pwd)" ]] || no "source_repo is not the checkout"
  [[ "$(jq -r '.digest' "${meta}")" == "$( (source "${co}/lib/watch/scan.sh"; safedeps_watch_tree_digest "${co}" "$(mktemp "${tmp_root}/step.XXXXXX")") )" ]] \
    || no "the installer and the scan hash the checkout differently"
  info=$(runtime_info "${root}")
  jq -e '.built == true and .stale == false' <<< "${info}" > /dev/null || no "a fresh runtime: ${info}"
  printf '# moved on\n' >> "${co}/lib/watch/lock.sh"
  info=$(runtime_info "${root}")
  jq -e '.stale == true' <<< "${info}" > /dev/null || no "a runtime whose checkout moved on: ${info}"
}
row "the runtime records its version and the digest of its checkout, and reads stale once the checkout moves on" row_runtime_meta

# ---- the two digests count the core alike ----------------------------------------------------
# The installer records the digest of what it built from (runtimeDigest) and
# the scan hashes the checkout again (safedeps_watch_tree_digest): two
# implementations of one rule. They are held side by side on one checkout
# before and after its core changes, and nothing else: each pair agrees, the
# pairs differ, and the runtime built first then reads stale.
scan_digest() { ( source "$1/lib/watch/scan.sh"; safedeps_watch_tree_digest "$1" "$(mktemp "${tmp_root}/step.XXXXXX")" ); }
row_core_digest() {
  local d co first second d1 d2 info
  d=$(new_dir); co="${d}/co"; make_checkout "${co}"
  first="${d}/out/first"; second="${d}/out/second"
  stage_ok "${co}" "${first}" || return 1
  d1=$(jq -r '.digest' "${first}/.safedeps-runtime.json")
  [[ "${d1}" == "$(scan_digest "${co}")" ]] || no "one core: the installer recorded ${d1}, the scan hashes $(scan_digest "${co}")"
  printf '# built again\n' >> "${co}/${CORE}"
  stage_ok "${co}" "${second}" || return 1
  d2=$(jq -r '.digest' "${second}/.safedeps-runtime.json")
  [[ "${d2}" == "$(scan_digest "${co}")" ]] || no "another core: the installer recorded ${d2}, the scan hashes $(scan_digest "${co}")"
  [[ "${d2}" != "${d1}" ]] || no "the installer recorded one digest for two cores"
  info=$(runtime_info "${first}")
  jq -e '.stale == true' <<< "${info}" > /dev/null || no "the runtime built before the core changed: ${info}"
  info=$(runtime_info "${second}")
  jq -e '.stale == false' <<< "${info}" > /dev/null || no "the runtime built after the core changed: ${info}"
}
row "the installer and the scan count the core alike: two cores, two digests, each the scan's, and the older runtime reads stale" row_core_digest

# A checkout the digest cannot read has no digest: a file shasum cannot read
# and a directory find cannot read each leave stale null, with the first line
# that read said. A hash of what could be read would differ from the record
# and read as stale for a checkout that did not move.
row_runtime_unreadable() {
  local d co root info rc
  d=$(new_dir); co="${d}/co"; make_checkout "${co}"
  root="${d}/out/agent"
  stage_ok "${co}" "${root}" || return 1
  chmod 000 "${co}/lib/watch/lock.sh"
  rc=0; info=$(runtime_info "${root}") || rc=$?
  chmod 644 "${co}/lib/watch/lock.sh"
  [[ "${rc}" == 0 ]] || no "runtime_info exited ${rc}"
  jq -e '.built == true and .stale == null and .source_digest_now == null
      and (.error | startswith("source checkout unreadable: ") and contains("shasum") and contains("lib/watch/lock.sh"))
      and (.source_unreadable | .step == "shasum" and .exit > 0 and .lines > 0
           and ("source checkout unreadable: " + .said[0]) == $info.error)' --argjson info "${info}" <<< "${info}" > /dev/null \
    || no "a checkout file shasum cannot read: ${info}"
  chmod 000 "${co}/lib/npm"
  rc=0; info=$(runtime_info "${root}") || rc=$?
  chmod 755 "${co}/lib/npm"
  [[ "${rc}" == 0 ]] || no "runtime_info exited ${rc}"
  jq -e '.stale == null and .source_digest_now == null
      and (.error | startswith("source checkout unreadable: ") and contains("find") and contains("lib/npm"))
      and (.source_unreadable | .step == "find" and .exit > 0 and .lines > 0
           and ("source checkout unreadable: " + .said[0]) == $info.error)' --argjson info "${info}" <<< "${info}" > /dev/null \
    || no "a checkout directory find cannot read: ${info}"
  info=$(runtime_info "${root}")
  jq -e '.stale == false and (has("error") | not) and (has("source_unreadable") | not)' <<< "${info}" > /dev/null || no "the same checkout read again: ${info}"
}
row "a source checkout the digest cannot read (a file shasum cannot read, a directory find cannot read) is stale null with what that read said, not a digest of what it could read" row_runtime_unreadable

# The digest's steps each keep their own exit and their own words, and only a
# step that failed gives the reason. step_tools DIR FIND SHASUM writes a find
# and a shasum into DIR for the front of PATH, each "warn" (the real tool, then
# a line on stderr, ending 0 when the real one did) or "fail" (a line on
# stderr and a non-zero exit; find lists what it can first, shasum nothing).
# "real" writes none. Each one it writes adds its name to DIR/ran when run.
step_tools() { # DIR FIND SHASUM
  local dir="$1" real f
  mkdir -p "${dir}"
  : > "${dir}/ran"
  real=$(command -v find)
  case "$2" in
    warn) printf '#!/bin/sh\necho find >> "%s/ran"\n"%s" "$@" || exit $?\necho "find: a warning from a walk that finished" >&2\nexit 0\n' "${dir}" "${real}" > "${dir}/find" ;;
    fail) printf '#!/bin/sh\necho find >> "%s/ran"\n"%s" "$@"\necho "find: lib/npm: fixture walk failed" >&2\nexit 17\n' "${dir}" "${real}" > "${dir}/find" ;;
  esac
  real=$(command -v shasum)
  case "$3" in
    warn) printf '#!/bin/sh\necho shasum >> "%s/ran"\n"%s" "$@" || exit $?\necho "shasum: a warning from a hash that finished" >&2\nexit 0\n' "${dir}" "${real}" > "${dir}/shasum" ;;
    fail) printf '#!/bin/sh\necho shasum >> "%s/ran"\necho "shasum: lib/readable: fixture read failed" >&2\nexit 23\n' "${dir}" > "${dir}/shasum" ;;
  esac
  for f in find shasum; do
    [[ ! -e "${dir}/${f}" ]] || chmod +x "${dir}/${f}"
  done
}
# digest_steps FIND SHASUM: a fresh runtime of a fresh checkout, judged with
# those tools in front of PATH. info holds runtime_info's answer, tools the
# directory.
digest_steps() {
  local d co root
  d=$(new_dir); co="${d}/co"; make_checkout "${co}"
  root="${d}/out/agent"
  stage_ok "${co}" "${root}" || return 1
  tools="${d}/tools"
  step_tools "${tools}" "$1" "$2"
  info=$(PATH="${tools}:${PATH}" runtime_info "${root}")
}

row_digest_failed_step_after_warning() {
  local info tools
  digest_steps warn fail
  jq -e '.built == true and .stale == null and .source_digest_now == null
      and .error == "source checkout unreadable: shasum: lib/readable: fixture read failed"
      and .source_unreadable == {step: "shasum", exit: 23, said: ["shasum: lib/readable: fixture read failed"], lines: 1}' <<< "${info}" > /dev/null \
    || no "find warned and ended 0, then shasum failed: ${info}"
}
row "a find that warns and ends 0, then a shasum that fails: the reason is what shasum said, the step is shasum, and stale is null" row_digest_failed_step_after_warning

row_digest_find_fails() {
  local info tools
  digest_steps fail real
  jq -e '.built == true and .stale == null and .source_digest_now == null
      and .error == "source checkout unreadable: find: lib/npm: fixture walk failed"
      and .source_unreadable == {step: "find", exit: 17, said: ["find: lib/npm: fixture walk failed"], lines: 1}' <<< "${info}" > /dev/null \
    || no "find listed what it could and failed: ${info}"
}
row "a find that lists what it can and fails: the reason is what find said with its exit, the step is find, and no digest is made of what it listed" row_digest_find_fails

row_digest_first_failure() {
  local info tools
  digest_steps fail fail
  jq -e '.stale == null and .source_digest_now == null
      and .error == "source checkout unreadable: find: lib/npm: fixture walk failed"
      and .source_unreadable == {step: "find", exit: 17, said: ["find: lib/npm: fixture walk failed"], lines: 1}' <<< "${info}" > /dev/null \
    || no "find and shasum both fail: ${info}"
}
row "find and shasum both failing: the reason is the first step that failed, find, in its own words" row_digest_first_failure

row_digest_warnings_exit_0() {
  local info tools
  digest_steps warn warn
  # The tools in front of PATH were the ones run: find once, shasum for the
  # files and for the lines.
  [[ "$(grep -c '^find$' "${tools}/ran")" -ge 1 && "$(grep -c '^shasum$' "${tools}/ran")" -ge 2 ]] \
    || no "the warning tools did not run: $(tr '\n' ' ' < "${tools}/ran")"
  jq -e '.built == true and .stale == false and .source_digest_now == .digest
      and (has("error") | not) and (has("source_unreadable") | not)' <<< "${info}" > /dev/null \
    || no "find and shasum warned and ended 0: ${info}"
}
row "a find and a shasum that warn and end 0: the digest is made as the installer made it, stale is false and there is no error" row_digest_warnings_exit_0

row_configure() {
  local d co h cfg
  d=$(new_dir); co="${d}/co"; make_checkout "${co}"
  h="${d}/home"; mkdir -p "${h}"; cfg="${h}/.safedeps/watch/config.json"
  HOME="${h}" node "${co}/${INSTALLER}" configure --population-command /bin/echo --population-arg x \
    --exclude /fixture/forbidden --followup cargo_lock=p/one --tool-path /fixture/tools > /dev/null || no "configure exited $?"
  HOME="${h}" node "${co}/${INSTALLER}" configure --followup uv_lock=p/two > /dev/null || no "a second configure exited $?"
  jq -e '.population_command == ["/bin/echo", "x"] and .followups == {cargo_lock: "p/one", uv_lock: "p/two"}' "${cfg}" > /dev/null \
    || no "a key no option named was not kept: $(cat "${cfg}")"
  [[ "$(cat "${h}/.safedeps/watch/exclude")" == /fixture/forbidden ]] || no "the exclude file: $(cat "${h}/.safedeps/watch/exclude")"
  printf '[]\n' > "${cfg}"
  if HOME="${h}" node "${co}/${INSTALLER}" configure --followup a=b > /dev/null 2>&1; then no "a config that is not an object was overwritten"; fi
  [[ "$(cat "${cfg}")" == "[]" ]] || no "the unreadable config changed"
  if HOME="${h}" node "${co}/${INSTALLER}" configure --exclude relative/path > /dev/null 2>&1; then no "a relative exclude was taken"; fi
}
row "configure keeps what no option names, refuses a config that is not an object and a relative path" row_configure

# ---- install: the same runtime, registered ---------------------------------------------------
# `install` is macOS only and calls launchctl. A launchctl on PATH that only
# records its arguments stands in; nothing is registered.
installed_skip="launchd agent install is macOS only"
lc_shim="${tmp_root}/shim"
mkdir -p "${lc_shim}"
printf '#!/bin/sh\necho "$@" >> "${LC_LOG:?}"\nexit 0\n' > "${lc_shim}/launchctl" # the shim expands LC_LOG itself
chmod 755 "${lc_shim}/launchctl"

LC_LOG=""
# install CHECKOUT HOME: the checkout's installer registers the agent in HOME.
install_in() {
  LAST_RC=0
  mkdir -p "$2"
  HOME="$2" LC_LOG="${LC_LOG}" PATH="${lc_shim}:${PATH}" node "$1/${INSTALLER}" install > "${tmp_root}/last.out" 2> "${tmp_root}/last.err" || LAST_RC=$?
}
plist_of() { printf '%s/Library/LaunchAgents/com.aldegad.safedeps.recheck.plist' "$1"; }

# ---- a missing checkout core is an unreadable source, never stale -----------------------------
# The scan keeps find's failure; status uses the installer's named refusal.
# launchctl only prints here, so the shim serves on every platform.
row_status_core_gone() {
  local d co h out info rc
  d=$(new_dir); co="${d}/co"; make_checkout "${co}"
  h="${d}/home"; mkdir -p "${h}"; LC_LOG="${d}/lc.log"
  HOME="${h}" node "${co}/${INSTALLER}" stage --root "${h}/.safedeps/agent" > /dev/null 2> "${tmp_root}/last.err" \
    || no "stage exited $?: $(head -c 300 "${tmp_root}/last.err")"
  status_json() {
    HOME="${h}" LC_LOG="${LC_LOG}" PATH="${lc_shim}:${PATH}" node "${co}/${INSTALLER}" status 2> "${tmp_root}/last.err" \
      || no "status exited $?: $(head -c 300 "${tmp_root}/last.err")"
  }
  out=$(status_json)
  jq -e '.agent_runtime_stale == false' <<< "${out}" > /dev/null || no "status of a fresh runtime: $(jq -c '{runtime, agent_runtime_stale}' <<< "${out}")"
  info=$(runtime_info "${h}/.safedeps/agent")
  jq -e '.stale == false' <<< "${info}" > /dev/null || no "the scan of a fresh runtime: ${info}"
  rm -rf "${co}/bin/native"
  rc=0
  out=$(HOME="${h}" LC_LOG="${LC_LOG}" PATH="${lc_shim}:${PATH}" node "${co}/${INSTALLER}" status 2> "${tmp_root}/last.err") || rc=$?
  [[ "${rc}" == 1 && -z "${out}" ]] || no "status without its source core: exit ${rc}, stdout ${out}"
  grep -qF 'core-missing: ' "${tmp_root}/last.err" || no "status did not name its missing core"
  grep -qF "$(cd -P "${co}" && pwd)/${CORE}" "${tmp_root}/last.err" || no "status did not name the source core path"
  info=$(runtime_info "${h}/.safedeps/agent")
  jq -e --arg core "${CORE}" '.stale == null and .source_digest_now == null
      and (.source_unreadable | .step == "find" and .exit > 0 and any(.said[]; contains($core)))' <<< "${info}" > /dev/null \
    || no "the scan without its source core: ${info}"
}
row "a missing checkout core: status refuses core-missing by path, and the scan keeps find failure with stale null" row_status_core_gone

row_install() {
  local d co h
  d=$(new_dir); co="${d}/co"; make_checkout "${co}"
  h="${d}/home"; LC_LOG="${d}/lc.log"
  install_in "${co}" "${h}"
  (( LAST_RC == 0 )) || no "install exited ${LAST_RC}: $(head -c 300 "${tmp_root}/last.err")" || return 1
  # The harness has to be able to see a registration for the rows below to mean anything.
  [[ "$(wc -l < "${LC_LOG}" | tr -d ' ')" == 3 ]] || no "launchctl was not called three times"
  grep -q '^bootstrap ' "${LC_LOG}" || no "launchctl was not asked to bootstrap"
  [[ -f "$(plist_of "${h}")" ]] || no "no plist"
  diff -r "${co}/lib" "${h}/.safedeps/agent/lib" > /dev/null || no "the agent's lib/ is not the checkout's lib/"
  [[ -f "${h}/.safedeps/agent/.safedeps-recheck-runtime" ]] || no "the agent has no marker"
  runtime_loads "${h}/.safedeps/agent" || return 1
  no_scraps "${h}/.safedeps/agent" || return 1
}
row_install_legacy() {
  local d co h agent
  d=$(new_dir); co="${d}/co"; make_checkout "${co}"
  h="${d}/home"; agent="${h}/.safedeps/agent"; LC_LOG="${d}/lc.log"
  # What every version before the marker left there: the entry points and a lib/
  # that is not the checkout's.
  mkdir -p "${agent}/bin" "${agent}/lib/providers" "${agent}/scripts"
  printf '#!/bin/sh\nexit 0\n' > "${agent}/bin/safedeps"
  printf 'old\n' > "${agent}/lib/providers/providers.sh"
  printf '#!/bin/sh\n' > "${agent}/scripts/safedeps-recheck-alert.sh"
  install_in "${co}" "${h}"
  (( LAST_RC == 0 )) || no "install exited ${LAST_RC}: $(head -c 300 "${tmp_root}/last.err")" || return 1
  diff -r "${co}/lib" "${agent}/lib" > /dev/null || no "the agent's lib/ is not the checkout's lib/"
  runtime_loads "${agent}" || return 1
  no_scraps "${agent}" || return 1
}
row_install_fails() {
  local d co h agent plist calls before_agent before_plist
  d=$(new_dir); co="${d}/co"; make_checkout "${co}"
  h="${d}/home"; agent="${h}/.safedeps/agent"; LC_LOG="${d}/lc.log"
  install_in "${co}" "${h}"
  (( LAST_RC == 0 )) || no "the first install exited ${LAST_RC}: $(head -c 300 "${tmp_root}/last.err")" || return 1
  plist=$(plist_of "${h}")
  before_agent=$(digest "${agent}"); before_plist=$(cksum < "${plist}"); calls=$(wc -l < "${LC_LOG}" | tr -d ' ')
  ln -s closure.sh "${co}/lib/npm/zz-link.sh"
  rm -f "${h}/.safedeps/watch/config.json"
  install_in "${co}" "${h}"
  [[ ! -e "${h}/.safedeps/watch/config.json" ]] || no "a failed install wrote the watch config"
  (( LAST_RC != 0 )) || no "install exited 0 with a link in lib/" || return 1
  grep -qF "neither a file nor a directory" "${tmp_root}/last.err" || no "install did not say why: $(head -c 300 "${tmp_root}/last.err")"
  [[ "$(digest "${agent}")" == "${before_agent}" ]] || no "the registered agent's runtime changed"
  [[ "$(cksum < "${plist}")" == "${before_plist}" ]] || no "the plist changed"
  [[ "$(wc -l < "${LC_LOG}" | tr -d ' ')" == "${calls}" ]] || no "launchctl was called again"
  runtime_loads "${agent}" || return 1
  no_scraps "${agent}" || return 1
}
# A checkout with no core is refused before install writes anything: no
# directory, no plist, no watch config, no launchctl call.
row_install_no_core() {
  local d co h before
  d=$(new_dir); co="${d}/co"; make_checkout "${co}"
  rm -rf "${co}/bin/native"
  h="${d}/home"; mkdir -p "${h}"; LC_LOG="${d}/lc.log"
  before=$(digest "${d}")
  install_in "${co}" "${h}"
  (( LAST_RC != 0 )) || no "install exited 0 with no core"
  grep -qF "core-missing: " "${tmp_root}/last.err" || no "install did not refuse by name: $(head -c 300 "${tmp_root}/last.err")"
  [[ "$(digest "${d}")" == "${before}" ]] || no "a refused install changed what is under ${d}"
}
if [[ "$(uname -s)" == Darwin ]]; then
  row "install registers an agent whose runtime was built whole" row_install
  row "install replaces an agent an earlier version built, which has no marker" row_install_legacy
  row "a failed install leaves the registered agent, its plist and launchd as they were" row_install_fails
  row "install refuses a checkout with no core for this machine by name before it writes anything" row_install_no_core
else
  skip "install registers an agent whose runtime was built whole" "${installed_skip}"
  skip "install replaces an agent an earlier version built, which has no marker" "${installed_skip}"
  skip "a failed install leaves the registered agent, its plist and launchd as they were" "${installed_skip}"
  skip "install refuses a checkout with no core for this machine by name before it writes anything" "${installed_skip}"
fi

if (( failures > 0 )); then
  printf '# %d row(s) did not pass\n' "${failures}" >&2
  exit 1
fi
