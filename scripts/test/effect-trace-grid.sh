#!/usr/bin/env bash
# safedeps: an npm install counts as read only where it left a trace.
#
# The effect gate reads one directory per command, and the pre-guard picks it
# from the command text before the command runs. Three validation rounds found
# text that picked the wrong one: a `cd` that never ran (`false && cd sub;`), a
# `cd` spelled another way (`command cd sub`), a symlinked workspace member.
# Each time the gate read a directory the install never touched, confirmed it
# clean, and passed the install unread. The design judgment for
# safedeps/effect-gate-blind-to-lockless-npm-installs measured 21 such silent
# rows on fe160c1 and moved the authority: the text picks where to look, and
# the PostToolUse hook records the install UNGATED when that directory shows no
# trace of this command. A rule for commands with several lockfile-writing npm
# statements closes the case where one statement's trace hides another's.
#
# Every row runs the real sequence an agent's Bash call goes through, against a
# real npm and the local registry of scripts/test/lib/npm-sandbox.sh: PreToolUse,
# the command as PreToolUse left it, PostToolUse. The rows are the judgment's
# grid plus an inherited CDPATH (X1). Each row is judged on what happened on
# disk, not on what the hooks said about it:
#
#   - silent: sd-victim is on disk (in the project, the sandbox global prefix,
#     or the alternate tree) after the command, the post hook did not roll it
#     back, and nothing recorded UNGATED. This is the defect class. The battery
#     prints every row and fails at the end, so a run against an older tree
#     counts its silent rows instead of stopping at the first.
#   - expect: what the row must do here. `rollback`, `ungated` (with the
#     wording the record must carry), or `quiet` for an approved install.
#
# GRID_REPORT_ONLY=1 prints the rows and exits 0 whatever they say. It exists
# for the control run against a tree from before the repair, where the count is
# the result; `npm test` never sets it.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "${ROOT_DIR}"

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

NPM_SANDBOX_NAME=trace-grid
NPM_SANDBOX_SCRIPT_RE='effect-trace-grid\.sh'
NPM_SANDBOX_TOLERANT=true
# shellcheck source=lib/npm-sandbox.sh
source "${ROOT_DIR}/scripts/test/lib/npm-sandbox.sh"

# An alternate tree for CDPATH: <alt>/sub is a project of its own, so a `cd sub`
# that CDPATH sends there installs there.
ALT="${tmp_root}/alt"
mkdir -p "${ALT}/sub"
printf '{"name":"alt-sub","version":"1.0.0"}\n' > "${ALT}/sub/package.json"

REPORT_ONLY="${GRID_REPORT_ONLY:-0}"
FAILURES=()
SILENT_ROWS=()

note_failure() { FAILURES+=("$1"); printf '   FAIL %s\n' "$1"; }

# Where sd-victim is on disk after a row: the project tree, the sandbox global
# prefix, the alternate tree.
victim_on_disk() {
  {
    (cd "${CASE_PROJECT}" && find . -path '*/node_modules/sd-victim' -print 2>/dev/null)
    find "${tmp_root}/global" -path '*/node_modules/sd-victim' -print 2>/dev/null | sed "s#^${tmp_root}/#<sandbox>/#"
    find "${ALT}" -path '*/node_modules/sd-victim' -print 2>/dev/null | sed "s#^${tmp_root}/#<sandbox>/#"
  } | paste -sd, -
}

# Clears what one row leaves behind outside the project: the global prefix is
# cleared by run_install, the alternate tree here, its manifest included (an
# install there saves the package to it, and the next row would install it).
reset_alt() {
  rm -rf "${ALT}/sub/node_modules" "${ALT}/sub/package-lock.json"
  printf '{"name":"alt-sub","version":"1.0.0"}\n' > "${ALT}/sub/package.json"
}

post_ungated_lines() { grep 'post-verify UNGATED' "${CASE_HOME}/advisory.log" 2>/dev/null || true; }

# One row. <id>|<fixture>|<cwd>|<engine>|<expect>|<command>
# <expect>: rollback | ungated-trace | ungated-attrib | quiet, or read: rolled
# back where the gate looked, or recorded as having left no trace there
# The command may say @ALT@ for the alternate tree; @ENVCDPATH@ as its first
# word runs it with CDPATH=<alt> inherited from the environment, which the
# hooks do not see.
run_row() {
  local row="$1" id fixture cwd engine expect form victim scripts silent=false status rb ug
  IFS='|' read -r id fixture cwd engine expect form <<< "${row}"
  form="${form//@ALT@/${ALT}}"
  CASE_CMD_ENV=()
  if [[ "${form}" == "@ENVCDPATH@ "* ]]; then
    form="${form#"@ENVCDPATH@ "}"
    CASE_CMD_ENV=("CDPATH=${ALT}")
  fi
  "new_${fixture}"
  CASE_CWD="${CASE_PROJECT}/${cwd}"
  reset_alt
  : > "${MARKS}"
  run_install "${form}" "${engine}"
  CASE_CMD_ENV=()

  victim=$(victim_on_disk)
  scripts=$(grep -c '^sd-victim' "${MARKS}" || true)
  rb=no; rolled_back && rb=yes
  ug=no; ungated && ug=yes
  if [[ -n "${victim}" && "${rb}" == no && "${ug}" == no ]]; then
    silent=true
    SILENT_ROWS+=("${id}(${engine})")
  fi
  status="rollback=${rb} ungated=${ug} victim=[${victim}] victim_scripts=${scripts} rc=${CASE_INSTALL_RC}"
  printf '%-4s %-7s %s | %s%s\n' "${id}" "${engine}" "${form}" "${status}" "$([[ "${silent}" == true ]] && printf ' SILENT')"

  [[ -z "${CASE_PRE_DENY}" ]] || { note_failure "${id}: the gate lets the command through (deny: ${CASE_PRE_DENY:0:160})"; return 0; }
  [[ "${silent}" == false ]] || note_failure "${id}: sd-victim is on disk, not rolled back and not recorded"
  if [[ "${engine}" == claude ]]; then
    [[ "${CASE_NOT_INERT}" == false ]] || note_failure "${id}: the install runs inert on Claude Code"
    [[ "${scripts}" == 0 ]] || note_failure "${id}: no script of sd-victim runs on Claude Code (${scripts})"
  fi
  case "${expect}" in
    rollback)
      [[ "${rb}" == yes ]] || note_failure "${id}: rolled back (post: ${CASE_POST:-<quiet>})"
      [[ -z "${victim}" ]] || note_failure "${id}: the rollback removes sd-victim from disk (${victim})"
      ;;
    ungated-trace)
      # The record says what it does not know: where the install went, or
      # whether it installed anything. Section 1b checks the directory it names.
      post_ungated_lines | grep -qF "post-verify UNGATED: no install trace in " \
        || note_failure "${id}: recorded UNGATED as an install with no trace ($(post_ungated_lines | cut -f2 | head -c 200))"
      post_ungated_lines | grep -qF 'the install landed elsewhere or installed nothing' \
        || note_failure "${id}: the record says the install landed elsewhere or installed nothing"
      [[ "${engine}" == codex ]] || ! grep -q '^sd-' <<< "${CASE_RAN}" \
        || note_failure "${id}: nothing is rebuilt where the install left no trace (${CASE_RAN})"
      ;;
    read)
      if [[ "${rb}" == yes ]]; then
        [[ -z "${victim}" ]] || note_failure "${id}: the rollback removes sd-victim from disk (${victim})"
      else
        post_ungated_lines | grep -qF 'the install landed elsewhere or installed nothing' \
          || note_failure "${id}: rolled back, or recorded UNGATED as an install with no trace (post: ${CASE_POST:-<quiet>})"
      fi
      ;;
    ungated-attrib)
      post_ungated_lines | grep -qF 'cannot answer for every npm install in this command' \
        || note_failure "${id}: recorded UNGATED because one trace cannot answer for every npm install ($(post_ungated_lines | cut -f2 | head -c 200))"
      ;;
    quiet)
      [[ -z "${CASE_POST}" ]] || note_failure "${id}: an approved install is confirmed quietly (post: ${CASE_POST})"
      ungated && note_failure "${id}: an install that left its trace is not recorded UNGATED ($(grep UNGATED "${CASE_HOME}/advisory.log" | cut -f2 | head -c 200))"
      grep -q '^sd-approved@[^	]*	install' <<< "${CASE_RAN}" \
        || note_failure "${id}: the verified inert install is rebuilt, so its scripts run (${CASE_RAN:-nothing ran})"
      ;;
    *) fail "unknown expectation ${expect} in row ${id}" ;;
  esac
  return 0
}

# --- 1. The grid -----------------------------------------------------------------------
# `sub` has a package.json of its own, `src` does not. Rows C/R2/F1 are the
# forms of rounds 1 and 2; G1/G2 of round 3; N, M, X were added by the design
# judgment. The expectation column is what the repaired gate does; the comment
# after a group says why.
printf '# grid (id engine command | outcome)\n'
while IFS= read -r row; do
  [[ -n "${row}" && "${row}" != \#* ]] || continue
  run_row "${row}"
done <<'ROWS'
C1|project|.|claude|rollback|npm install sd-victim
C2|project|.|claude|rollback|cd sub && npm install sd-victim
C3|project|.|claude|rollback|cd sub; npm install sd-victim
C4|project|.|claude|quiet|cd sub && npm install sd-approved
R2a|project|.|claude|rollback|cd src && npm install sd-victim
R2b|project|.|claude|rollback|cd src; npm install sd-victim --no-save
R2c|workspace|.|claude|rollback|cd packages/a && npm install sd-victim
F1a|symws|real/a|claude|rollback|npm install sd-victim
F1b|symws|.|claude|rollback|cd packages/a && npm install sd-victim
F1c|symws|.|claude|rollback|cd real/a && npm install sd-victim
F1d|symws|packages/a|claude|rollback|npm install sd-victim --no-save
F1e|symws|real/a|codex|rollback|npm install sd-victim
# A `cd` that may not run is not followed past the `&&` chain after it, so the
# gate reads the cwd, where npm installed (round 3, G1).
G1a|project|.|claude|rollback|false && cd sub; npm install sd-victim
G1b|project|.|claude|rollback|true || cd sub; npm install sd-victim
G1c|project|.|claude|rollback|if false; then cd sub; fi; npm install sd-victim
G1d|project|.|codex|rollback|false && cd sub; npm install sd-victim
# Spellings of `cd` the text does not follow. npm installs in sub, the gate
# reads the cwd and finds no trace there.
G2a|project|.|claude|ungated-trace|command cd sub; npm install sd-victim
G2b|project|.|claude|ungated-trace|builtin cd sub; npm install sd-victim
G2c|project|.|claude|ungated-trace|FOO=1 cd sub; npm install sd-victim
G2d|project|.|claude|ungated-trace|eval cd sub; npm install sd-victim
G2e|project|.|claude|ungated-trace|case x in x) cd sub;; esac; npm install sd-victim
G2f|project|.|codex|ungated-trace|command cd sub; npm install sd-victim
N1|project|.|claude|rollback|cd sub || exit 1; npm install sd-victim
# A conditional `cd` that does run: the text cannot tell it from G1, so the
# gate reads the cwd and records what it did not find.
N2|project|.|claude|ungated-trace|[ -d sub ] && cd sub; npm install sd-victim
N3|project|.|claude|rollback|true && cd sub && npm install sd-victim
N4|project|.|claude|rollback|cd sub 2>/dev/null; npm install sd-victim
N5|project|.|claude|ungated-trace|(cd sub && npm install sd-victim)
N6|project|.|claude|rollback|(cd sub); npm install sd-victim
N7|project|.|claude|ungated-trace|f() { cd sub; }; f; npm install sd-victim
N8|project|.|claude|ungated-trace|printf 'cd sub\n' > go.sh; . ./go.sh; npm install sd-victim
N9|project|.|claude|rollback|pushd sub >/dev/null; npm install sd-victim
N10|project|.|claude|rollback|cd sub; cd -; npm install sd-victim
N11|project|.|claude|ungated-trace|cd "$(pwd)/sub" && npm install sd-victim
N12|project|.|claude|rollback|cd nonexist; npm install sd-victim
N13|project|.|claude|ungated-trace|CDPATH=@ALT@; cd sub; npm install sd-victim
X1|project|.|claude|ungated-trace|@ENVCDPATH@ cd sub; npm install sd-victim
# The command changes what npm's answer depends on: a package.json, an .npmrc,
# the workspace declaration. N14 and N15 were recorded UNGATED before the
# release tree was merged in and rolled back after it (measured; the cause was
# not traced); either is the gate answering for the install.
N14|project|src|claude|read|npm init -y >/dev/null && npm install sd-victim
N15|project|.|claude|read|cd src && npm init -y >/dev/null && npm install sd-victim
N16|project|.|claude|ungated-trace|cd sub && rm -f package.json && npm install sd-victim
N17|project|.|claude|ungated-trace|printf 'global=true\n' > .npmrc && npm install sd-victim
N18|project|.|claude|ungated-trace|mkdir -p newp && cd newp && npm init -y >/dev/null && npm install sd-victim
N19|workspace|.|claude|ungated-trace|printf '{"name":"root","version":"1.0.0","private":true}\n' > package.json && cd packages/a && npm install sd-victim
N20|project|.|claude|ungated-trace|npm_config_global=true; export npm_config_global; npm install sd-victim
N21|project|.|claude|ungated-trace|declare -x npm_config_global=true; npm install sd-victim
N22|project|.|claude|ungated-trace|printf 'export npm_config_global=true\n' > e.sh; . ./e.sh; npm install sd-victim
# Two lockfile writers with something between them: the first one's trace
# would answer for both.
M1|project|.|claude|ungated-attrib|npm install sd-approved; command cd sub; npm install sd-victim
M2|project|src|claude|ungated-attrib|npm install sd-approved && npm init -y >/dev/null && npm install sd-victim
M3|project|.|claude|ungated-attrib|cd sub && npm install sd-approved; cd ..; npm install sd-victim
M4|project|src|claude|ungated-attrib|npm prune; npm init -y >/dev/null; npm install sd-victim
M5|project|.|claude|ungated-attrib|npm install sd-approved && npm -C sub install sd-victim
M6|project|.|claude|ungated-attrib|npm install sd-approved; sh -c 'cd sub && npm install sd-victim'
# Nothing installed: a dry run, a package the registry does not have.
E1|project|.|claude|ungated-trace|npm install --dry-run sd-victim
E2|project|.|claude|ungated-trace|npm install sd-nope
# An inherited CDPATH sends an approved install elsewhere: recorded, not
# rebuilt here.
X2|project|.|claude|ungated-trace|@ENVCDPATH@ cd sub && npm install sd-approved
# A bare install with no name, sent elsewhere: recorded whatever it names.
X3|project|.|claude|ungated-trace|printf '{"name":"sub","version":"1.0.0","dependencies":{"sd-victim":"1.0.0"}}' > sub/package.json; command cd sub; npm install
ROWS
claude_silent=0
for row in "${SILENT_ROWS[@]+"${SILENT_ROWS[@]}"}"; do
  [[ "${row}" != *"(claude)" ]] || claude_silent=$(( claude_silent + 1 ))
done
printf '# silent rows: %s, Claude %s (%s)\n' "${#SILENT_ROWS[@]}" "${claude_silent}" "${SILENT_ROWS[*]:-none}"

if [[ "${REPORT_ONLY}" == 1 ]]; then
  printf '# GRID_REPORT_ONLY: %s failure(s) not enforced\n' "${#FAILURES[@]}"
  exit 0
fi

# --- 1b. The record names the directory the gate read --------------------------------------
# The rows above check the wording; these check the directory: the cwd for a
# row the text does not move, sub for one it does.
for carrier in \
  "project|.|command cd sub; npm install sd-victim|." \
  "project|.|cd sub && rm -f package.json && npm install sd-victim|sub" \
  "project|.|npm install --dry-run sd-victim|."
do
  IFS='|' read -r fixture cwd form where <<< "${carrier}"
  "new_${fixture}"
  CASE_CWD="${CASE_PROJECT}/${cwd}"
  : > "${MARKS}"
  run_install "${form}"
  where=$(cd "${CASE_PROJECT}/${where}" && pwd -P)
  post_ungated_lines | grep -qF "no install trace in ${where}: the install landed elsewhere or installed nothing" \
    || note_failure "the record names the directory the gate read: ${form} (${where}; $(post_ungated_lines | cut -f2 | head -c 200))"
  grep -qF "no install trace in ${where}" <<< "${CASE_POST}" \
    || note_failure "the user is told, on Claude Code, that nothing was verified or rebuilt: ${form} (post: ${CASE_POST:-<quiet>})"
done

# --- 2. No false positives: installs that installed something left a trace ----------------
# The design judgment's oracle: every form that installed anything rewrote a
# lockfile, a reinstall of what was already there included (same content, new
# mtime), and `npm ci` replaced the file. Each is an approved install here, so
# each must confirm quietly, record nothing, and rebuild. `<approved first>|<form>`.
for carrier in \
  "yes|npm install sd-approved" \
  "yes|npm install" \
  "yes|npm ci" \
  "yes|npm install sd-approved --no-save" \
  "yes|npm update" \
  "yes|npm install sd-approved@1.0.0" \
  "yes|npm install --package-lock-only" \
  "yes|npm install sd-swapped@1.0.0" \
  "yes|npm install sd-swapped@1.0.0 --no-save" \
  "yes|rm -rf node_modules && npm install" \
  "yes|npm install sd-approved --no-package-lock" \
  "yes|npm install sd-approved --prefer-offline" \
  "yes|npm install sd-approved && npm install sd-approved" \
  "no|npm install" \
  "no|npm install sd-approved" \
  "yes|npm install -D sd-approved" \
  "yes|npm ci && npm ci"
do
  IFS='|' read -r approved_first form <<< "${carrier}"
  new_project
  if [[ "${approved_first}" == yes ]]; then
    (cd "${CASE_PROJECT}" && npm install sd-approved --ignore-scripts >/dev/null 2>&1) || fail "the fixture installs sd-approved first"
  fi
  : > "${MARKS}"
  run_install "${form}"
  [[ -z "${CASE_PRE_DENY}" && "${CASE_INSTALL_RC}" == 0 ]] || note_failure "the approved install runs: ${form} (${CASE_PRE_DENY:-rc ${CASE_INSTALL_RC}})"
  [[ -z "${CASE_POST}" ]] || note_failure "an approved install that left a trace confirms quietly: ${form} (post: ${CASE_POST})"
  ungated && note_failure "an install that left its trace is not recorded UNGATED: ${form} ($(grep UNGATED "${CASE_HOME}/advisory.log" | cut -f2 | head -c 200))"
  if [[ -e "${CASE_PROJECT}/node_modules/sd-approved" ]]; then
    grep -q '^sd-approved@[^	]*	install' <<< "${CASE_RAN}" || note_failure "the verified install is rebuilt: ${form} (${CASE_RAN:-nothing ran})"
  fi
done
pass "17 forms that installed something, no-op reinstalls and npm ci included, leave a trace and confirm quietly"

# The approved forms of the moved installs: in sub, from a subdirectory, from a
# workspace member, from a symlinked member. Each leaves its trace where the
# gate reads.
for carrier in \
  "project|.|cd sub && npm install sd-approved|sub" \
  "project|sub|npm install sd-approved|sub" \
  "project|src|npm install sd-approved|." \
  "workspace|packages/a|npm install sd-approved|." \
  "symws|.|cd packages/a && npm install sd-approved|real/a" \
  "symws|real/a|npm install sd-approved|real/a"
do
  IFS='|' read -r fixture cwd form where <<< "${carrier}"
  "new_${fixture}"
  CASE_CWD="${CASE_PROJECT}/${cwd}"
  : > "${MARKS}"
  run_install "${form}"
  [[ -z "${CASE_POST}" ]] || note_failure "an approved install confirms quietly: ${carrier} (post: ${CASE_POST})"
  ungated && note_failure "an install that left its trace is not recorded UNGATED: ${carrier}"
  where=$(cd "${CASE_PROJECT}/${where}" && pwd -P)
  grep -q "	${where}/node_modules/sd-approved\$" <<< "${CASE_RAN}" \
    || note_failure "the rebuild runs where the install landed: ${carrier} (${CASE_RAN:-nothing ran})"
done
pass "approved installs in sub, a subdirectory, a workspace member and a symlinked member leave a trace and rebuild where they landed"

# --- 3. A reinstall inside the second the pre-guard ran in ------------------------------
# A whole-second mtime cannot tell a lockfile written in the same second as the
# baseline from one written before it, and a no-op reinstall writes the same
# content, so neither a second-granularity comparison nor a content hash sees
# it. The row is real only when that condition happened, so each trial records
# the baseline's and the lockfile's mtimes, read between the command and the
# post hook while the baseline still exists, and the battery requires at least
# one trial in which the lockfile was written after the baseline and inside the
# same whole second. Nothing sleeps between the pre-guard and the command.
record_same_second() {
  local baseline lock
  baseline=$(jq -r '.npm_trace.baseline // empty' "${CASE_HOME}"/pending/*.json 2>/dev/null | head -n 1)
  lock="${CASE_PROJECT}/node_modules/.package-lock.json"
  TRIAL=$(node -e '
    const fs = require("fs");
    const [baseline, lock] = process.argv.slice(1);
    try {
      const b = fs.statSync(baseline).mtimeMs, l = fs.statSync(lock).mtimeMs;
      const same = l > b && Math.floor(b / 1000) === Math.floor(l / 1000);
      process.stdout.write(`baseline=${b} lock=${l} same_second=${same ? "yes" : "no"}`);
    } catch (e) { process.stdout.write(`unreadable (${e.code}) same_second=no`); }
  ' "${baseline:-<none>}" "${lock}")
}
same_second_seen=0
for trial in 1 2 3 4 5 6 7 8 9 10 11 12; do
  new_project
  (cd "${CASE_PROJECT}" && npm install sd-approved --ignore-scripts >/dev/null 2>&1) || fail "the fixture installs sd-approved first"
  : > "${MARKS}"
  TRIAL=""
  run_install "npm install sd-approved" claude record_same_second
  [[ "${TRIAL}" != *same_second=yes* ]] || same_second_seen=$(( same_second_seen + 1 ))
  printf '   trial %s: %s ungated=%s\n' "${trial}" "${TRIAL}" "$(ungated && echo yes || echo no)"
  ungated && note_failure "a no-op reinstall leaves a trace even in the baseline's second (trial ${trial}: ${TRIAL})"
  [[ -z "${CASE_POST}" ]] || note_failure "a no-op reinstall confirms quietly (trial ${trial}: ${CASE_POST})"
  (( same_second_seen < 2 )) || break
done
(( same_second_seen > 0 )) || note_failure "no trial put the lockfile write in the baseline's second, so the same-second row observed nothing"
pass "a no-op reinstall in the second the pre-guard ran in leaves a trace (${same_second_seen} same-second trial(s) observed)"

# --- 4. The trace check starts no npm -------------------------------------------------------
# Deciding whether the install was read costs a `find` and two `ls`, never an
# npm start. On a row with no trace the post hook has nothing else to ask npm
# (no rebuild), so it starts none; on a row with a trace it starts the two the
# rebuild needs (`npm query`, `npm rebuild`) and nothing more. The shim counts
# what reaches npm through the PATH the post hook runs with.
count_dir="${tmp_root}/count-bin"
mkdir -p "${count_dir}"
real_npm=$(command -v npm)
{
  printf '#!/usr/bin/env bash\n'
  printf 'printf "%%s\\n" "$1" >> %q\n' "${tmp_root}/npm-calls.log"
  printf 'exec %q "$@"\n' "${real_npm}"
} > "${count_dir}/npm"
chmod +x "${count_dir}/npm"
for carrier in \
  "npm install --dry-run sd-victim|" \
  "command cd sub; npm install sd-approved|" \
  "npm install sd-approved|query rebuild"
do
  IFS='|' read -r form expected <<< "${carrier}"
  new_project
  : > "${tmp_root}/npm-calls.log"
  CASE_POST_PATH="${count_dir}:${PATH}"
  run_install "${form}"
  CASE_POST_PATH=""
  calls=$(sort "${tmp_root}/npm-calls.log" | paste -sd' ' -)
  [[ "${calls}" == "${expected}" ]] \
    || note_failure "the post hook starts npm only for the rebuild: ${form} (started: ${calls:-none}; expected: ${expected:-none})"
done
pass "the trace check starts no npm: none on a row with no trace, query and rebuild only on a row with one"

npm_sandbox_registry_was_local

if [[ ${#FAILURES[@]} -gt 0 ]]; then
  printf 'not ok - %s\n' "${FAILURES[@]}" >&2
  fail "${#FAILURES[@]} expectation(s) failed in the effect-trace grid"
fi
pass "the grid has no silent row, every Claude row ran no sd-victim script, and G1a-c roll back"
printf 'effect-trace-grid passed\n'
