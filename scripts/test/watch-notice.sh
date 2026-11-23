#!/usr/bin/env bash
# safedeps: the watch's session-start notice, and its registration.
#
# scripts/safedeps-watch-notice.sh is the Claude Code SessionStart hook that
# `install-safedeps-hooks.mjs --watch-notice` registers. It reads
# `safedeps --json watch status` and prints what the agent has to act on: the
# events no consumer has claimed, roots a walk did not finish, no scan yet, or
# a status it could not read. Otherwise it prints nothing.
#
# Each row has its own HOME (SAFEDEPS_HOME under it) and its own small checkout
# (the real bin/, lib/ and the notice, with a stand-in core), so the installer
# registers into a HOME no session reads and the notice it registers runs the
# real CLI. A watch state is built from the state's own definitions
# (lib/watch/state.jq: empty_state and summary), never from a copy of them.
# The claim row uses the real `safedeps watch claim`.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "${ROOT_DIR}"

failures=0
pass() { printf 'ok - %s\n' "$1"; }
bad() { printf 'not ok - %s\n' "$1" >&2; failures=$((failures + 1)); }
# A check that did not hold: says so and ends the row (each row is a subshell).
no() { printf '# %s\n' "$*" >&2; exit 1; }

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-watch-notice.XXXXXX")
cleanup() {
  local rc=$?
  if (( rc == 0 && failures == 0 )); then
    rm -rf "${tmp_root}"
  else
    printf '# failed row artifacts: %s\n' "${tmp_root}" >&2
  fi
}
trap cleanup EXIT

row() {
  local rc=0
  set +e
  ( set -e; "$2" )
  rc=$?
  set -e
  if (( rc == 0 )); then pass "$1"; else bad "$1"; fi
}

new_dir() { mktemp -d "${tmp_root}/row.XXXXXX"; }

case "$(uname -s)" in Darwin) native_os=darwin ;; Linux) native_os=linux ;; *) printf 'not ok - no binary directory for %s\n' "$(uname -s)"; exit 1 ;; esac
case "$(uname -m)" in arm64|aarch64) native_arch=arm64 ;; x86_64|amd64) native_arch=x64 ;; *) printf 'not ok - no binary directory for %s\n' "$(uname -m)"; exit 1 ;; esac

# A checkout the hooks installer takes as an installed package: the installer,
# the entry, the notice, the real CLI, and a core that answers nothing, so the
# installer's probe of the entry passes without cargo. The notice it registers
# runs this checkout's real bin/safedeps.
make_checkout() { # DIR
  mkdir -p "$1/scripts/install" "$1/bin/native/${native_os}-${native_arch}"
  cp scripts/install/install-safedeps-hooks.mjs "$1/scripts/install/"
  cp -p scripts/safedeps-hook-entry.sh scripts/safedeps-watch-notice.sh "$1/scripts/"
  cp -p bin/safedeps "$1/bin/safedeps"
  cp -R lib "$1/lib"
  printf '#!/bin/sh\nexit 0\n' > "$1/bin/native/${native_os}-${native_arch}/safedeps-core"
  chmod 755 "$1/bin/native/${native_os}-${native_arch}/safedeps-core"
}

# install CHECKOUT HOME [ARG...]: the checkout's hooks installer, in HOME.
# Leaves its exit status in LAST_RC and what it said in last.out.
LAST_RC=0
install_hooks() {
  local co="$1" h="$2"
  shift 2
  mkdir -p "${h}/.claude" "${h}/.codex"
  LAST_RC=0
  HOME="${h}" node "${co}/scripts/install/install-safedeps-hooks.mjs" "$@" > "${tmp_root}/last.out" 2>&1 || LAST_RC=$?
}

# The notice command Claude Code would run, read from the settings the
# installer wrote; one, or the row ends.
registered_notice() { # HOME
  local cmds
  cmds=$(jq -r '[.hooks.SessionStart[]?.hooks[]? | select(.command | test("safedeps-watch-notice"))] | map(.command) | .[]' "$1/.claude/settings.json")
  [[ -n "${cmds}" && "$(wc -l <<< "${cmds}" | tr -d ' ')" == 1 ]] || no "the settings hold no single notice: ${cmds}"
  printf '%s' "${cmds}"
}

# notice HOME [COMMAND]: runs the notice as a shell runs a hook command, with
# HOME and SAFEDEPS_HOME of the row, and SessionStart's payload on stdin.
# Leaves stdout in notice.out, stderr in notice.err and the status in NOTICE_RC.
NOTICE_RC=0
notice() {
  local h="$1" cmd="${2:-${ROOT_DIR}/scripts/safedeps-watch-notice.sh}"
  NOTICE_RC=0
  printf '{"session_id":"watch-notice-test","hook_event_name":"SessionStart","source":"startup"}' \
    | HOME="${h}" SAFEDEPS_HOME="${h}/.safedeps" /bin/sh -c "${cmd}" > "${tmp_root}/notice.out" 2> "${tmp_root}/notice.err" || NOTICE_RC=$?
}

# write_state HOME ROOTS EVENTS: a published watch state with these roots and
# events and one open finding, its summary made by state.jq's own definition.
write_state() {
  mkdir -p "$1/.safedeps/watch"
  jq -n -L "${ROOT_DIR}/lib/watch" --argjson roots "$2" --argjson events "$3" '
    include "state";
    {kind: "full", started_at: "2026-11-23T00:00:00Z", finished_at: "2026-11-23T00:00:10Z"} as $scan
    | empty_state + {
        generation: 1, scan_generation: 1, last_scan: $scan, last_full_scan: ($scan + {errors: []}),
        last_success_at: $scan.finished_at,
        population: {state: "fresh", count: ($roots | length), excluded: 0, generated_at: $scan.started_at, reason: null, roots: []},
        roots: $roots,
        findings: {"/p/a|/p/a/package-lock.json|left-pad@1.0.0|GHSA-test-0001": {
          state: "open", ecosystem: "npm", root: "/p/a", scope: "/p/a/package-lock.json", package: "left-pad",
          version: "1.0.0", fixed: ["1.3.0"], advisory: "GHSA-test-0001", ids: ["GHSA-test-0001"], kev: false,
          first_seen: $scan.finished_at, last_seen: $scan.finished_at, last_seen_scan_generation: 1,
          stale_measurement: false, remediation: null}},
        events: $events}
    | . + {summary: summary}' > "$1/.safedeps/watch/state.json"
}
roots_whole='{"/p/a": {"path": "/p/a", "class": "ok", "partial": false, "walk": {"exit": 0, "said": [], "lines": 0}, "lockfiles": [{"kind": "npm", "status": "measured", "path": "/p/a/package-lock.json"}]},
              "/p/b": {"path": "/p/b", "class": "ok", "partial": false, "walk": {"exit": 0, "said": [], "lines": 0}, "lockfiles": []}}'
roots_partial='{"/p/a": {"path": "/p/a", "class": "ok", "partial": false, "walk": {"exit": 0, "said": [], "lines": 0}, "lockfiles": [{"kind": "npm", "status": "measured", "path": "/p/a/package-lock.json"}]},
                "/p/b": {"path": "/p/b", "class": "ok", "partial": true, "walk": {"exit": 1, "said": ["find: ./x: Operation not permitted"], "lines": 1}, "lockfiles": []}}'
one_event='[{"id": "e1", "kind": "finding", "finding": "/p/a|/p/a/package-lock.json|left-pad@1.0.0|GHSA-test-0001", "from": null, "to": "open",
             "created_at": "2026-11-23T00:00:10Z", "status": "pending", "claim": null, "task": null}]'

out_lines() { grep -c '' "${tmp_root}/notice.out" || true; }
said() { # TEXT: the notice printed TEXT
  grep -qF -- "$1" "${tmp_root}/notice.out" || no "the notice did not say '$1': $(cat "${tmp_root}/notice.out")"
}
quiet_ok() { # the notice exited 0 and wrote nothing to stderr
  (( NOTICE_RC == 0 )) || no "the notice exited ${NOTICE_RC}: $(cat "${tmp_root}/notice.err")"
  [[ ! -s "${tmp_root}/notice.err" ]] || no "the notice wrote to stderr: $(cat "${tmp_root}/notice.err")"
}

# ---- what the notice says -------------------------------------------------------------

# The registered command, run as a shell runs it, tells the one new event; the
# real `watch claim` takes it, and the next session is told nothing.
row_one_event_then_claimed() {
  local d co h cmd
  d=$(new_dir); co="${d}/co"; make_checkout "${co}"; h="${d}/home"
  install_hooks "${co}" "${h}" --watch-notice
  (( LAST_RC == 0 )) || no "install --watch-notice exited ${LAST_RC}: $(cat "${tmp_root}/last.out")"
  cmd=$(registered_notice "${h}")
  write_state "${h}" "${roots_whole}" "${one_event}"
  notice "${h}" "${cmd}"
  quiet_ok
  [[ "$(out_lines)" == 2 ]] || no "the notice printed $(out_lines) lines, not 2: $(cat "${tmp_root}/notice.out")"
  said "safedeps watch: 1 new event not yet claimed (last full scan 2026-11-23T00:00:10Z, "
  said "claim the events, fix on a branch, run the tests, ask before merging, and ack each event."
  said '"Re-checking what is already installed"'
  HOME="${h}" SAFEDEPS_HOME="${h}/.safedeps" "${co}/bin/safedeps" --json watch claim --consumer notice-test > "${d}/claim.json" \
    || no "watch claim exited $?"
  jq -e '.claimed | map(.id) == ["e1"]' "${d}/claim.json" > /dev/null || no "the claim took $(jq -c '.claimed | map(.id)' "${d}/claim.json")"
  notice "${h}" "${cmd}"
  quiet_ok
  [[ ! -s "${tmp_root}/notice.out" ]] || no "a claimed event was told again: $(cat "${tmp_root}/notice.out")"
}
row "the registered notice tells one new event, and once it is claimed tells nothing" row_one_event_then_claimed

row_partial_walk() {
  local h
  h="$(new_dir)/home"
  write_state "${h}" "${roots_partial}" '[]'
  notice "${h}"
  quiet_ok
  [[ "$(out_lines)" == 1 ]] || no "the notice printed $(out_lines) lines, not 1: $(cat "${tmp_root}/notice.out")"
  said "safedeps watch: 1 of 2 roots was not read in full on the last scan, so what could not be read there was not checked."
  if grep -qF "claim the events" "${tmp_root}/notice.out"; then no "with no new event the notice asked for a claim"; fi
}
row "with no new event, a root walked partway is still told, so silence never stands for roots not read" row_partial_walk

row_nothing_new() {
  local h
  h="$(new_dir)/home"
  write_state "${h}" "${roots_whole}" '[]'
  notice "${h}"
  quiet_ok
  [[ ! -s "${tmp_root}/notice.out" ]] || no "with nothing new the notice said: $(cat "${tmp_root}/notice.out")"
}
row "with no new event and every root read, the notice prints nothing" row_nothing_new

row_no_scan() {
  local h
  h="$(new_dir)/home"; mkdir -p "${h}"
  notice "${h}"
  quiet_ok
  [[ "$(out_lines)" == 1 ]] || no "the notice printed $(out_lines) lines, not 1"
  said "safedeps watch: no watch scan has been published yet, so nothing already installed has been checked again."
}
row "with no scan published, the notice says that nothing installed was checked again" row_no_scan

row_unreadable() {
  local h
  h="$(new_dir)/home"; mkdir -p "${h}/.safedeps/watch"
  printf '{}\n' > "${h}/.safedeps/watch/state.json"
  notice "${h}"
  quiet_ok
  [[ "$(out_lines)" == 1 ]] || no "the notice printed $(out_lines) lines, not 1"
  said "safedeps watch: the status could not be read (safedeps watch status exited 3: "
  said "Nothing about the watch is known in this session"
}
row "a status that cannot be read is said, with its exit, and the hook still exits 0" row_unreadable

# ---- registration -------------------------------------------------------------------

row_register() {
  local d co h claude codex before
  d=$(new_dir); co="${d}/co"; make_checkout "${co}"; h="${d}/home"
  claude="${h}/.claude/settings.json"; codex="${h}/.codex/hooks.json"
  mkdir -p "${h}/.claude"
  # A SessionStart group of the user's own stays through every step.
  printf '{"hooks":{"SessionStart":[{"matcher":"startup","hooks":[{"type":"command","command":"echo mine"}]}]}}\n' > "${claude}"

  install_hooks "${co}" "${h}"
  (( LAST_RC == 0 )) || no "install exited ${LAST_RC}: $(cat "${tmp_root}/last.out")"
  jq -e '[.hooks.SessionStart[]?.hooks[]?.command] == ["echo mine"]' "${claude}" > /dev/null \
    || no "an install without --watch-notice added a notice: $(jq -c .hooks.SessionStart "${claude}")"

  install_hooks "${co}" "${h}" --watch-notice
  (( LAST_RC == 0 )) || no "install --watch-notice exited ${LAST_RC}: $(cat "${tmp_root}/last.out")"
  jq -e '.hooks.SessionStart == [
      {matcher: "startup", hooks: [{type: "command", command: "echo mine"}]},
      {matcher: "startup|resume", hooks: [{type: "command", command: "~/.claude/skills/safedeps/scripts/safedeps-watch-notice.sh", timeout: 10}]}]' \
    "${claude}" > /dev/null || no "the notice group is not as registered: $(jq -c .hooks.SessionStart "${claude}")"
  jq -e '.hooks | has("SessionStart") | not' "${codex}" > /dev/null || no "codex got a SessionStart hook"
  grep -qF "Codex CLI: no session-start notice is registered here" "${tmp_root}/last.out" || no "the installer did not say what codex gets instead"

  before=$(cat "${claude}")
  install_hooks "${co}" "${h}" --watch-notice
  [[ "$(cat "${claude}")" == "${before}" ]] || no "a second --watch-notice changed the settings"
  install_hooks "${co}" "${h}"
  [[ "$(cat "${claude}")" == "${before}" ]] || no "an install without the flag changed the notice the user chose"

  install_hooks "${co}" "${h}" --no-watch-notice
  (( LAST_RC == 0 )) || no "install --no-watch-notice exited ${LAST_RC}: $(cat "${tmp_root}/last.out")"
  jq -e '.hooks.SessionStart == [{matcher: "startup", hooks: [{type: "command", command: "echo mine"}]}]' "${claude}" > /dev/null \
    || no "--no-watch-notice left: $(jq -c .hooks.SessionStart "${claude}")"
  jq -e '[.hooks.PreToolUse[]?.hooks[]?.command] | any(endswith("safedeps-hook-entry.sh pre"))' "${claude}" > /dev/null \
    || no "--no-watch-notice removed the gate"

  install_hooks "${co}" "${h}" --watch-notice
  install_hooks "${co}" "${h}" --uninstall
  (( LAST_RC == 0 )) || no "uninstall exited ${LAST_RC}: $(cat "${tmp_root}/last.out")"
  jq -e '[.hooks[]?[]?.hooks[]? | select(.command | contains("/safedeps/"))] | length == 0' "${claude}" > /dev/null \
    || no "uninstall left a safedeps hook: $(jq -c .hooks "${claude}")"
  jq -e '.hooks.SessionStart == [{matcher: "startup", hooks: [{type: "command", command: "echo mine"}]}]' "${claude}" > /dev/null \
    || no "uninstall touched the user's SessionStart group"
}
row "--watch-notice registers the notice for Claude Code only, once; a plain install keeps it; --no-watch-notice and --uninstall remove it and nothing of the user's" row_register

row_register_refused() {
  local d co h args
  d=$(new_dir); co="${d}/co"; make_checkout "${co}"
  for args in "--watch-notice --no-watch-notice" "--watch-notice --uninstall" "--watch-notices"; do
    h=$(mktemp -d "${d}/home.XXXXXX")
    # shellcheck disable=SC2086 # ARGS is a list of words by construction
    install_hooks "${co}" "${h}" ${args}
    (( LAST_RC != 0 )) || no "install ${args} exited 0"
    grep -qF "Nothing was registered" "${tmp_root}/last.out" || no "install ${args} did not say nothing was registered: $(cat "${tmp_root}/last.out")"
    [[ ! -e "${h}/.claude/settings.json" && ! -e "${h}/.codex/hooks.json" ]] || no "install ${args} wrote an engine config"
  done
}
row "conflicting or unknown installer arguments register nothing" row_register_refused

if (( failures > 0 )); then
  printf '# %d row(s) did not pass\n' "${failures}" >&2
  exit 1
fi
