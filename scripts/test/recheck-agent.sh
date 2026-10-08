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

# A checkout the installer can run from: it finds bin/, lib/ and the wrapper
# beside its own scripts/install/ directory.
make_checkout() { # DIR
  mkdir -p "$1/scripts/install" "$1/bin"
  cp "${INSTALLER}" "$1/${INSTALLER}"
  cp bin/safedeps "$1/bin/safedeps"
  cp -R lib "$1/lib"
  cp scripts/safedeps-recheck-alert.sh "$1/scripts/safedeps-recheck-alert.sh"
}

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
  install_in "${co}" "${h}"
  (( LAST_RC != 0 )) || no "install exited 0 with a link in lib/" || return 1
  grep -qF "neither a file nor a directory" "${tmp_root}/last.err" || no "install did not say why: $(head -c 300 "${tmp_root}/last.err")"
  [[ "$(digest "${agent}")" == "${before_agent}" ]] || no "the registered agent's runtime changed"
  [[ "$(cksum < "${plist}")" == "${before_plist}" ]] || no "the plist changed"
  [[ "$(wc -l < "${LC_LOG}" | tr -d ' ')" == "${calls}" ]] || no "launchctl was called again"
  runtime_loads "${agent}" || return 1
  no_scraps "${agent}" || return 1
}
if [[ "$(uname -s)" == Darwin ]]; then
  row "install registers an agent whose runtime was built whole" row_install
  row "install replaces an agent an earlier version built, which has no marker" row_install_legacy
  row "a failed install leaves the registered agent, its plist and launchd as they were" row_install_fails
else
  skip "install registers an agent whose runtime was built whole" "${installed_skip}"
  skip "install replaces an agent an earlier version built, which has no marker" "${installed_skip}"
  skip "a failed install leaves the registered agent, its plist and launchd as they were" "${installed_skip}"
fi

if (( failures > 0 )); then
  printf '# %d row(s) did not pass\n' "${failures}" >&2
  exit 1
fi
