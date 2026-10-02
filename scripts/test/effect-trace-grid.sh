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
# impostor or of sd-fetchy ran at all, the rollback's own reinstall included),
# or `kept:<warning>` (not rolled back, with a warning that says <warning>).
printf '# what an install brought in (id engine command | outcome)\n'
failures_before=${#FAILURES[@]}
while IFS= read -r row; do
  [[ -n "${row}" && "${row}" != \#* ]] || continue
  IFS='|' read -r id fixture engine expect form <<< "${row}"
  "new_${fixture}"
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
# Install scripts run in two places, and both run over the whole tree: the
# rebuild after an inert install, and the rollback's reinstall. What allowed
# them was a judgment of the change, and three holes in that judgment in a row
# became scripts that ran (safedeps/effect-gate-blind-to-lockless-npm-installs,
# judgment C). The permission is now a predicate on the whole tree: every
# package on record, every package under node_modules recorded with a
# public-registry https source or bundled in one, every directory outside it a
# declared workspace member. Otherwise the whole rebuild is skipped with a
# warning that names the package, and nothing is rolled back. The rollback
# reinstalls with --ignore-scripts and rebuilds only toward a confirmed
# snapshot, through the same predicate; with no confirmed snapshot it says so
# in the message, reorg.log and advisory.log.
#
#   RB1, RB2, CH2b: a rollback with no confirmed snapshot restores a lockfile
#     that holds sd-victim. The reinstall used to run its scripts.
#   CH3c: a rollback to a confirmed snapshot still rebuilds.
#   CH1b, L1, L2: a tree that holds a directory or a source nobody approved,
#     from an earlier unrecorded install or a committed lockfile, is installed
#     and not rebuilt. The rebuild used to run it.
#   K4-K7: committed `file:` directory dependencies. Installed, not rebuilt,
#     named. This is what users see change: the rebuild used to run them.
#   K8, K9, NS1, BD1: workspaces, the nested strategy and a public package's
#     bundled dependency are rebuilt as before.
#   OM1: `omit-lockfile-registry-resolved` records no source, so nothing shows
#     the package came from the public registry. Not rebuilt; a boundary.
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
EVIL_INTEGRITY="sha512-$(node -e 'process.stdout.write(require("crypto").createHash("sha512").update(require("fs").readFileSync(process.argv[1])).digest("base64"))' "${EVIL_DIR}/sd-approved-1.0.0.tgz")"

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
new_omit() { new_project; printf 'omit-lockfile-registry-resolved=true\n' > "${CASE_PROJECT}/.npmrc"; }

# <id>|<fixture>|<engine>|<expect>|<command>, where <expect> is
#   fallback            rolled back with no confirmed snapshot, said in all three records
#   rebuilt:<package>   rolled back to a confirmed snapshot and <package> rebuilt
#   kept:<warning>      not rolled back, nothing rebuilt, the warning says <warning>
#   quiet:<package>     confirmed quietly, and <package> rebuilt (`-`: nothing to check)
printf '# install scripts over the whole tree (id engine command | outcome)\n'
failures_before=${#FAILURES[@]}
while IFS= read -r row; do
  [[ -n "${row}" && "${row}" != \#* ]] || continue
  IFS='|' read -r id fixture engine expect form <<< "${row}"
  "new_${fixture}"
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
  [[ -z "${CASE_PRE_DENY}" ]] || { note_failure "${id}: the gate lets the command through (deny: ${CASE_PRE_DENY:0:160})"; continue; }
  [[ "${CASE_INSTALL_RC}" == 0 ]] || { note_failure "${id}: the install itself succeeds (rc ${CASE_INSTALL_RC})"; continue; }
  [[ "${forbidden}" == 0 ]] || note_failure "${id}: no script of sd-victim, the EVIL tarball or a directory dependency runs after the command (${forbidden})"
  case "${expect}" in
    fallback)
      rolled_back || note_failure "${id}: rolled back (post: ${CASE_POST:-<quiet>})"
      grep -qF 'no confirmed snapshot' <<< "${CASE_POST}" || note_failure "${id}: the message says there is no confirmed snapshot (post: ${CASE_POST:0:300})"
      grep -qF 'no confirmed snapshot' <<< "${reorg_new}" || note_failure "${id}: reorg.log says there is no confirmed snapshot (${reorg_new:0:300})"
      grep -qF 'REORG with no confirmed snapshot' <<< "${advisory_new}" || note_failure "${id}: advisory.log says there is no confirmed snapshot (${advisory_new:0:300})"
      grep -qF 'last confirmed safe snapshot' <<< "${CASE_POST}" && note_failure "${id}: the message does not claim a confirmed snapshot"
      [[ -z "${CASE_RAN}" ]] || note_failure "${id}: the rollback runs no install script (${CASE_RAN})"
      ;;
    rebuilt:*)
      rolled_back || note_failure "${id}: rolled back (post: ${CASE_POST:-<quiet>})"
      grep -qF 'last confirmed safe snapshot' <<< "${CASE_POST}" || note_failure "${id}: rolled back to the confirmed snapshot (post: ${CASE_POST:0:300})"
      [[ "$(grep -c "^${expect#rebuilt:}@" <<< "${CASE_RAN}" || true)" == 3 ]] \
        || note_failure "${id}: the rollback rebuilds ${expect#rebuilt:}, all three scripts (${CASE_RAN:-nothing ran})"
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
CH3c|ch3|claude|rebuilt:sd-approved|npm install sd-approved@1.0.0
CH3x|ch3|codex|rebuilt:sd-approved|npm install sd-approved@1.0.0
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
OM1|omit|claude|kept:a package not recorded as coming from the public registry (node_modules/sd-approved (sd-approved@1.0.0 from no recorded source))|npm install sd-approved@1.0.0
ROWS
[[ ${#FAILURES[@]} -ne ${failures_before} ]] \
  || pass "install scripts run only over a tree on record from the public registry or a workspace, a rollback runs none without a confirmed snapshot and says so, and K4-K7 are installed but not rebuilt"

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
mkdir -p "${UUID_OTHER}/${leaf}" "${UUID_OTHER}/elsewhere"
printf '{"name":"other","version":"1.0.0"}\n' > "${UUID_OTHER}/${leaf}/package.json"
printf '{"name":"elsewhere","version":"1.0.0"}\n' > "${UUID_OTHER}/elsewhere/package.json"
for carrier in \
  "alike|npm install --prefix ../../${UUID_OTHER##*/}/${leaf} sd-victim|${UUID_OTHER}/${leaf}" \
  "unlike|npm install --prefix ${UUID_OTHER}/elsewhere sd-victim|${UUID_OTHER}/elsewhere"
do
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
