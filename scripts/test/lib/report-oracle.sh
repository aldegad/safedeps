#!/usr/bin/env bash
# The report oracle: what the post hook says is a closed set of line forms, and
# every line it prints is read against that set and checked again on disk.
#
# Three rounds of review each found a sentence in a rollback message that was
# false, and each time the false part was a clause attached behind a true one:
# what is left in a directory, why a rollback stopped, what npm would do. A
# vocabulary check did not see them (two mutants that added such a clause
# passed the whole suite). So the check is on the output, not on the source:
#
#   - every line of every message the hook prints goes through oracle_message;
#     a row does not choose which of its lines are read;
#   - a line is a frame (a fixed string, matched whole), or it matches one
#     anchored form, or the run fails with "a line outside the grammar";
#   - a line that matches a form has that form's claim checked again here, from
#     disk and from what this file noted before the hook ran (the install trace,
#     the journal owner's state), by code that is not the hook's;
#   - oracle_table fails when a form never appeared, so a form whose check
#     cannot fail in this suite is not counted as checked. A fact that has two
#     values (exists / does not exist, confirmed / not) is two forms.
#
# Each message has a reorg.log entry, and the entry is read with the same
# grammar: the oracle builds the entries the message's lines call for (a frame
# and the message's own lines, in order) and the entries the hook appended must
# be exactly those. A line only the log carries, a refusal only the log
# carries, and reasons that differ between the two are all red. advisory.log is
# an operational log in free form and is not read, except its two rollback
# lines, which must repeat lines of the message, the line that says the
# pre-guard's record could not be read, and the line that names a consumed
# record that names no snapshot, whose snapshot has no meta file, or that is
# not one JSON object, which every such call says once, with a message or
# without one.
#
# The package.json listing of node_modules is read by a method that is not the
# hook's, because the hook and the oracle once ran the same wrong check and
# agreed (F1): Python's directory walk, which follows a linked node_modules, in
# lib/report-oracle-read.py.
#
# Neither reads the command for --ignore-scripts. The hook says "added" only
# where the command it received is, byte for byte, the command the pre-guard
# recorded writing, and the oracle checks that with cmp. Three rounds in a row,
# a reader of the command here and one in the hook shared a model of shell
# statements and were wrong on the same commands.
#
# Which record is this call's, and what it says, the oracle does not learn
# the hook's way either. The hook finds the record by the file named after the
# call's tool_use_id (or, for a call that names none, by the pending key) and
# reads it with jq; when the key missed (bamdori r18: `sh -c 'npm ci'`,
# rewritten), the oracle found the same nothing and agreed with a false "did
# not add". So the record is read here in Python (report-oracle-read.py), a
# record the hook consumed must hold this call's tool_use_id, "did not add" is
# red when a record of this call no hook has used yet, found by what it holds,
# says safedeps wrote exactly the command this hook received, an --ignore-scripts
# line is red in a message from a hook that
# found no record, and each record is checked when it is written: the rewrite
# the pre-guard printed is read from its stdout (oracle_pre) and must be, byte
# for byte, the command the record says it wrote.
#
# A hook whose read of that record failed says no --ignore-scripts line: "did
# not add" used to be said in its place. The oracle learns that the read
# failed from the row, not from the hook: a row that makes it fail leaves
# record-unread in the call's directory (ORACLE_CALL), and a record that is not
# one JSON object, read in Python, is one no reader can read. Such a call has
# no --ignore-scripts line, and says once in advisory.log that it could not
# read the record; a call whose read did not fail does not say that.
#
# A line is said only from a fact the record states, as version 2 (the rule is
# in report-oracle-read.py, read from the parsed record and not with the
# hook's jq). Each line is red unless the record states its fact, and a
# message that would carry a line and carries none is red unless the record
# states neither fact or could not be read, and advisory.log says which, once.
# A record that states neither (no file, another version, a v2.17.2 record, a
# string "true", a null command) used to be answered by its missing field.
#
# What a rollback changed on disk is read too: the oracle lists the project's
# top-level entries before the hook runs, and after a rollback every entry that
# changed must be named by a step line, "The rollback changed nothing." needs
# an unchanged listing, and "kept" needs a listing where node_modules is still
# what it was, the checks of the install from before the hook all showing no
# write, and the check lines the form is made of right after it.
#
# The effect gate's own warnings are prose, owned by a follow-up plan, and
# their bytes are not checked here. They are listed in ORACLE_PROSE by exact
# prefix, with the blocks each may appear in and the most lines this suite may
# show of it, so the hole is a named one with a size that is enforced.
#
# Scripts that change a line or add one change the form here in the same
# commit: scripts/test/report-mutations.sh turns such changes into failures of
# this file.

ORACLE_DIR=""
ORACLE_FAILED=0

# Forms the suite must show at least once.
ORACLE_FORMS="
head-rollback head-backstop-rollback head-backstop-none head-gone-rollback head-gone-none head-empty-rollback head-empty-none head-unread-rollback head-unread-none head-confirm head-journal-gone head-journal-stopped
snapshot-confirmed snapshot-pre snapshot-journal-confirmed snapshot-journal-pre
restored not-restored-differs not-restored-absent not-restored-not-file removed not-removed
refused-restore-link refused-removal-link refused-unresolved
path-exists path-absent path-link workspaces-key changed-nothing
kept kept-files kept-packages kept-bins kept-not-newer
reason-trace reason-file reason-package reason-bin reason-newer reason-no-snapshot
trace-none trace-baseline-gone trace-no-baseline
inert-added inert-asked inert-none
rebuild-skipped-added rebuild-ran-added rebuild-skipped rebuild-ran
skip-fact-link skip-fact-unresolved skip-fact-trace
backstop-no-confirmed backstop-no-meta
journal owner-not-running owner-zombie owner-stopped owner-later owner-no-pid owner-no-start owner-bad-start owner-bad-opened
journal-differs journal-gone journal-extra journal-no-list
file-line file-line-absent
log-rollback log-backstop log-confirm log-refused log-journal log-inert-unread log-inert-unstated log-record-gone log-record-empty log-record-unread
"

# The effect gate's prose: id | the blocks it may appear in | the most lines
# of it this suite may show | the exact prefix the sentence starts with. The
# rebuild warnings and "the install is kept" are said only of an install that
# was kept; the three about recording withheld bytes are written before the
# reorg decision and may precede a rollback.
ORACLE_PROSE=(
  "prose-rebuild-not-run|confirm|0|npm rebuild was not run: "
  "prose-baseline-not-moved|confirm|0|safedeps verified this install but could not record the result as the new rollback baseline ("
  "prose-bytes-unread|rollback confirm|0|safedeps could not read which bytes this install brought into "
  "prose-fetch-unknown|rollback confirm|0|safedeps could not tell where npm fetched the bytes this install brought into "
  "prose-record-failed|rollback confirm|0|safedeps could not record the bytes this install fetched from a registry that is not the public npm registry ("
  "prose-fetched-elsewhere|confirm|2|this install fetched packages from a registry that is not the public npm registry ("
)
oracle_prose_field() {
  local entry="$1" n="$2"
  while (( n > 1 )); do entry="${entry#*|}"; n=$(( n - 1 )); done
  [[ "$2" == 4 ]] && printf '%s' "${entry}" || printf '%s' "${entry%%|*}"
}

ORACLE_READ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/report-oracle-read.py"

oracle_init() {
  ORACLE_DIR="$1"
  mkdir -p "${ORACLE_DIR}/bin"
  : > "${ORACLE_DIR}/forms.log"
  # Every npm the hook runs is noted, with its exit status, and then handed to
  # the npm the row put on PATH. "safedeps did not run npm rebuild" is checked
  # against this, not against the row's own stub.
  cat > "${ORACLE_DIR}/bin/npm" <<'SHIM'
#!/usr/bin/env bash
self="${BASH_SOURCE[0]%/*}"
next="" rc=0
IFS=: read -r -a dirs <<< "${PATH}"
for d in "${dirs[@]}"; do
  [[ "${d}" != "${self}" && -x "${d}/npm" ]] || continue
  next="${d}/npm"
  break
done
if [[ -n "${next}" ]]; then "${next}" "$@" || rc=$?; else rc=127; fi
printf '%s\trc=%s\n' "$*" "${rc}" >> "${ORACLE_NPM_LOG}"
exit "${rc}"
SHIM
  chmod +x "${ORACLE_DIR}/bin/npm"
}

oracle_count() { printf '%s\n' "$1" >> "${ORACLE_DIR}/forms.log"; }
oracle_red() {
  printf 'not ok - report oracle: %s: [%s]\n' "$1" "${O_LINE:-}" >&2
  ORACLE_FAILED=1
}
oracle_phys() { python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }
oracle_epoch() { date -u -d "$1" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null; }

# What the journal owner is, read before the hook runs: the hook's report can
# arrive after the test resumed or reaped the process.
oracle_owner_state() {
  local pid="$1" opened="$2" stat lstart started opened_epoch
  [[ "${pid}" =~ ^[0-9]+$ ]] || { printf 'no-pid'; return; }
  kill -0 "${pid}" 2>/dev/null || { printf 'not-running'; return; }
  stat=$(ps -o stat= -p "${pid}" 2>/dev/null | tr -d '[:space:]')
  [[ "${stat}" != *Z* ]] || { printf 'zombie'; return; }
  lstart=$(ps -o lstart= -p "${pid}" 2>/dev/null)
  [[ -n "${lstart}" ]] || { printf 'no-start'; return; }
  started=$(date -d "${lstart}" +%s 2>/dev/null) || started=$(date -j -f '%a %b %d %T %Y' "${lstart}" +%s 2>/dev/null) \
    || { printf 'bad-start'; return; }
  opened_epoch=$(oracle_epoch "${opened}") || { printf 'bad-opened'; return; }
  (( started <= opened_epoch )) || { printf 'later'; return; }
  case "${stat}" in *T*|*t*) printf 'stopped'; return ;; esac
  printf 'running'
}

# The install trace of a pending install, read before the hook removes the
# baseline: present | none | gone (the baseline file) | unset (no baseline).
oracle_trace_state() {
  local pending="$1" baseline project rel file recorded inode
  baseline=$(jq -r '.npm_trace.baseline // empty' "${pending}" 2>/dev/null)
  project=$(jq -r '.project_dir | strings' "${pending}" 2>/dev/null)
  [[ -n "${project}" ]] || project="${2:-}"
  [[ -n "${baseline}" ]] || { printf 'unset'; return; }
  [[ -f "${baseline}" ]] || { printf 'gone'; return; }
  for rel in package-lock.json node_modules/.package-lock.json; do
    file="${project}/${rel}"
    [[ -e "${file}" ]] || continue
    recorded=$(jq -r --arg rel "${rel}" '.npm_trace.inodes[$rel] // ""' "${pending}" 2>/dev/null)
    inode=$(ls -di -- "${file}" 2>/dev/null | awk '{print $1}')
    if [[ "${inode}" != "${recorded}" || -n "$(find -H "${file}" -newer "${baseline}" -print 2>/dev/null)" ]]; then
      printf 'present'
      return
    fi
  done
  printf 'none'
}

# The node manifests and lockfiles of a pending install's project, against the
# snapshot the pre-guard took, read before the hook restores anything: the
# names that snapshot answers for, then `same` or `differs`.
oracle_node_files_state() {
  local pending="$1" snap project name copy names="" verdict=same differing=""
  snap=$(jq -r '.snapshot_id | strings' "${pending}" 2>/dev/null)
  project=$(jq -r '.project_dir | strings' "${pending}" 2>/dev/null)
  [[ -n "${project}" ]] || project="${2:-}"
  for name in package.json package-lock.json npm-shrinkwrap.json pnpm-lock.yaml yarn.lock bun.lock bun.lockb; do
    copy="${SAFEDEPS_HOME:-${HOME}/.safedeps}/snapshots/${snap}_${name}"
    if [[ -f "${copy}" ]]; then
      names+="${names:+, }${name}"
      cmp -s "${copy}" "${project}/${name}" || { verdict=differs; differing+=" ${name}"; }
    elif [[ -f "${copy}.missing" ]]; then
      names+="${names:+, }${name}"
      [[ ! -e "${project}/${name}" && ! -L "${project}/${name}" ]] || { verdict=differs; differing+=" ${name}"; }
    fi
  done
  printf '%s\n%s\n%s\n' "${names}" "${verdict}" "${differing# }"
}

# What node_modules of a pending install's project holds that the pre-command
# listings lack, and what in it is newer than the snapshot, read before the
# hook removes it: one `package <path>`, `bin <name>` or `newer <path>` per line.
# The package.json files are listed by Python's walk, not by the hook's find.
oracle_tree_state() {
  local pending="$1" snap project nm home="${SAFEDEPS_HOME:-${HOME}/.safedeps}" path
  snap=$(jq -r '.snapshot_id | strings' "${pending}" 2>/dev/null)
  project=$(jq -r '.project_dir | strings' "${pending}" 2>/dev/null)
  [[ -n "${project}" ]] || project="${2:-}"
  nm="${project}/node_modules"
  [[ -f "${home}/snapshots/${snap}_packages.list" ]] && oracle_packages_lacking "${nm}" "${home}/snapshots/${snap}_packages.list" | sed 's/^/package /'
  [[ -f "${home}/snapshots/${snap}_bins.list" ]] && { ls "${nm}/.bin/" 2>/dev/null || true; } | sort | comm -13 "${home}/snapshots/${snap}_bins.list" - | sed 's/^/bin /'
  for path in "${nm}/.package-lock.json" "${nm}"; do
    [[ -n "$(find -H "${path}" -prune -newer "${home}/snapshots/${snap}_meta.json" 2>/dev/null)" ]] && printf 'newer %s\n' "${path}"
  done
  return 0
}

# The package.json files under <node_modules> (Python's walk) that the listing
# file <list> does not hold, one per line. Red when the walk fails.
oracle_packages_lacking() {
  local walked
  walked=$(python3 "${ORACLE_READ}" packages "$1") || { O_LINE="$1"; oracle_red "the oracle's walk of node_modules failed"; return 0; }
  [[ -n "${walked}" ]] || return 0
  printf '%s\n' "${walked}" | LC_ALL=C sort | LC_ALL=C comm -13 <(LC_ALL=C sort "$2") -
}

# oracle_note_listing <call dir> <dir>: the top-level entries of <dir> before
# the hook runs, kept under a name made from the path.
oracle_note_listing() {
  local dir="$2"
  [[ -n "${dir}" && -d "${dir}" ]] || return 0
  mkdir -p "$1/listing"
  python3 "${ORACLE_READ}" listing "${dir}" > "$1/listing/$(oracle_dir_hash "${dir}")" 2>/dev/null || true
}

# oracle_before <call dir> [payload]: notes what the hook is about to consume.
oracle_before() {
  local call="$1" home="${SAFEDEPS_HOME:-${HOME}/.safedeps}" file id cwd=""
  mkdir -p "${call}/pending" "${call}/journal"
  wc -c < "${home}/reorg.log" 2>/dev/null | tr -d ' ' > "${call}/reorg.size" || true
  wc -c < "${home}/advisory.log" 2>/dev/null | tr -d ' ' > "${call}/advisory.size" || true
  if [[ -n "${2:-}" ]]; then
    cwd=$(jq -r '.cwd // empty' <<< "$2")
    [[ -z "${cwd}" ]] || { cwd=$(oracle_phys "${cwd}"); oracle_note_listing "${call}" "${cwd}"; }
  fi
  for file in "${home}/pending"/*.json; do
    [[ -f "${file}" ]] || continue
    cp "${file}" "${call}/pending/${file##*/}"
    # A record with no project_dir is judged in the payload's directory.
    oracle_trace_state "${file}" "${cwd}" > "${call}/pending/${file##*/}.trace"
    oracle_node_files_state "${file}" "${cwd}" > "${call}/pending/${file##*/}.nodefiles"
    oracle_tree_state "${file}" "${cwd}" > "${call}/pending/${file##*/}.tree"
    oracle_note_listing "${call}" "$(jq -r '.project_dir // empty' "${file}" 2>/dev/null)"
  done
  # The records a pre-#5 pre-guard left, which the hook must not read.
  for file in current_state current_snapshot_id; do
    [[ -f "${home}/${file}" ]] || continue
    mkdir -p "${call}/legacy"
    cp "${home}/${file}" "${call}/legacy/${file}"
  done
  for file in "${SAFEDEPS_JOURNAL_DIR:-${home}/rollback-journal}"/*.json; do
    [[ -f "${file}" ]] || continue
    id=$(jq -r '.journal_id // "unknown"' "${file}" 2>/dev/null)
    cp "${file}" "${call}/journal/${id}.json"
    oracle_owner_state "$(jq -r '.pid // empty' "${file}" 2>/dev/null)" "$(jq -r '.opened_at // empty' "${file}" 2>/dev/null)" \
      > "${call}/journal/${id}.owner"
  done
}

# Where a snapshot keeps <name>: a workspace member's file goes under members/.
oracle_stored() {
  case "$2" in
    */*) printf '%s/snapshots/%s_members/%s' "${O_HOME}" "$1" "$2" ;;
    *) printf '%s/snapshots/%s_%s' "${O_HOME}" "$1" "$2" ;;
  esac
}

# oracle_path_fact <text>: 0 when it is a path fact that holds, 1 when it is
# one that does not, 2 when it is not a path fact. O_FACT_PATH is the path.
oracle_path_fact() {
  local re_link='^(/.+) is a symbolic link to (.+)$' re_exists='^(/.+) exists$' re_absent='^(/.+) does not exist$'
  if [[ "$1" =~ ${re_link} ]]; then
    O_FACT_PATH="${BASH_REMATCH[1]}"; O_FACT_KIND=link
    [[ -L "${BASH_REMATCH[1]}" && "$(oracle_phys "${BASH_REMATCH[1]}")" == "${BASH_REMATCH[2]}" ]]
  elif [[ "$1" =~ ${re_exists} ]]; then
    O_FACT_PATH="${BASH_REMATCH[1]}"; O_FACT_KIND=exists
    [[ -e "${BASH_REMATCH[1]}" && ! -L "${BASH_REMATCH[1]}" ]]
  elif [[ "$1" =~ ${re_absent} ]]; then
    O_FACT_PATH="${BASH_REMATCH[1]}"; O_FACT_KIND=absent
    [[ ! -e "${BASH_REMATCH[1]}" && ! -L "${BASH_REMATCH[1]}" ]]
  else
    return 2
  fi
}

# oracle_inert_holds <added|asked|none>: the pre-guard's record that it
# rewrote the command, and whether the command this hook received is the one
# it wrote. Both strings are read in Python and compared by cmp.
oracle_inert_holds() {
  local asked=false same=false meta pending
  if [[ "${O_RECORD_UNREAD}" == 1 || "${O_VERDICT}" == unreadable ]]; then
    oracle_red "an --ignore-scripts line from a hook whose read of the pre-guard's record failed"
    return
  fi
  [[ "${O_VERDICT}" != nocommand ]] || { oracle_red "the hook input carries no command"; return; }
  case "${O_VERDICT}" in
    added) asked=true; same=true ;;
    asked) asked=true ;;
    none) ;;
    *) oracle_red "an --ignore-scripts line, and the pre-guard's record does not state it as a version 2 record: ${O_META:-no record}"; return ;;
  esac
  case "$1:${asked}:${same}" in
    added:true:true|asked:true:false|none:false:*) ;;
    *) oracle_red "the pre-guard's record says it rewrote the command: ${asked}; the command this hook received is the one it wrote: ${same}" ;;
  esac
  # "did not add" is a claim about every record of this call no hook has used
  # yet, not only the one the hook found: an outstanding record of this call
  # that says safedeps wrote exactly this command makes it false, however the
  # hook missed it. The records are those of the pending states noted before
  # the hook ran, found by what they hold, not by the hook's key, and a record
  # is this call's when it holds this call's tool_use_id, or holds none for a
  # call that names none. Records already used are left out because e2e runs
  # each call to its post hook: its Codex row that carries the flag itself
  # sends the bytes an earlier Claude rewrite wrote, and its "did not add" is
  # true (measured: scanning every record turned that row red). Another call's
  # outstanding record is left out for the same reason: an overlapping Claude
  # call of the same command can hold exactly those bytes (OV1).
  [[ "$1" == none && "${O_DIRECT}" != 1 ]] || return 0
  for pending in "${O_CALL}/pending"/*.json; do
    [[ -f "${pending}" ]] || continue
    [[ "$(python3 "${ORACLE_READ}" string "${pending}" tool_use_id 2>/dev/null)" == "${O_CALL_ID}" ]] || continue
    meta="${O_HOME}/snapshots/$(python3 "${ORACLE_READ}" string "${pending}" snapshot_id 2>/dev/null)_meta.json"
    [[ -f "${meta}" ]] || continue
    python3 "${ORACLE_READ}" wrote "${meta}" > "${O_CALL}/inert.any" 2>/dev/null || continue
    if cmp -s "${O_CALL}/inert.any" "${O_CALL}/inert.received"; then
      oracle_red "did not add, and a pre-guard record no call has used says safedeps wrote this command: ${meta}"
      return
    fi
  done
}

# The registry warning says safedeps cannot add --ignore-scripts on Codex only
# for a Codex call, and of a Codex call that safedeps did not add it it says so.
# It was said on either engine. The engine is read from the hook input in
# Python.
oracle_fetched_engine() {
  local engine
  engine=$(python3 "${ORACLE_READ}" engine "${O_CALL}/payload.json" 2>/dev/null) || engine=""
  case "$1" in
    *'. safedeps did not add --ignore-scripts to this install (on Codex it cannot), '*)
      [[ "${engine}" == codex ]] || oracle_red "the warning says safedeps cannot add --ignore-scripts on Codex, of a ${engine:-unread} call" ;;
    *'. safedeps did not add --ignore-scripts to this install, '*)
      [[ "${engine}" == claude ]] || oracle_red "the warning leaves out that safedeps cannot add --ignore-scripts on Codex, of a ${engine:-unread} call" ;;
  esac
}

# An --ignore-scripts line speaks from the pre-guard's record of this command,
# and the backstop's message is the one a hook that found no record prints.
oracle_inert_line() {
  oracle_count "$1"; O_SAW_INERT=1
  case "${O_BLOCK}" in
    backstop-*) oracle_red "an --ignore-scripts line from a hook that found no record of this command"; return ;;
  esac
  oracle_inert_holds "$2"
}

# The pre-guard's record, checked when it is written. oracle_pre_before notes
# the snapshot records before the pre-guard runs; oracle_pre <call dir> <hook
# stdout> reads the rewrite the pre-guard printed, if any, from its stdout and
# holds every record the call wrote against it: a call that printed a rewrite
# wrote exactly one record that says safedeps wrote those bytes, and a call
# that printed none wrote no record that says it wrote anything.
oracle_pre_before() {
  local home="${SAFEDEPS_HOME:-${HOME}/.safedeps}"
  mkdir -p "$1"
  : > "$1/marker"
  cksum "${home}/snapshots"/*_meta.json > "$1/metas.before" 2>/dev/null || true
}
oracle_pre() {
  local call="$1" home="${SAFEDEPS_HOME:-${HOME}/.safedeps}" printed=false n=0 meta rc
  O_LINE="pre-guard: $(head -c 200 <<< "$2")"
  printf '%s' "$2" > "${call}/pre.out"
  python3 "${ORACLE_READ}" string "${call}/pre.out" hookSpecificOutput updatedInput command > "${call}/pre.wrote" 2>/dev/null \
    && printed=true
  cksum "${home}/snapshots"/*_meta.json > "${call}/metas.after" 2>/dev/null || true
  # A record is this call's when it is new, its bytes changed, or it was
  # written after the marker. Only a new one may be: each call claims a snapshot
  # id of its own, and a record that was there before the call is another
  # call's. Two calls in one project within one second used to share an id, and
  # the second wrote over the first's record, so the first call's post hook
  # spoke from the second call's record (bamdori r19, SAME). The record still
  # agreed with the hook that read it, so only this check sees it.
  { grep -vxFf "${call}/metas.before" "${call}/metas.after" | awk '{ sub(/^[^ ]+ [^ ]+ /, ""); print }'
    find "${home}/snapshots" -maxdepth 1 -name '*_meta.json' -newer "${call}/marker" 2>/dev/null
  } | sort -u > "${call}/metas.written"
  awk '{ sub(/^[^ ]+ [^ ]+ /, ""); print }' "${call}/metas.before" > "${call}/metas.before.names"
  while IFS= read -r meta; do
    [[ -n "${meta}" ]] || continue
    ! grep -qxF -- "${meta}" "${call}/metas.before.names" \
      || oracle_red "a pre-guard call wrote over a record that was there before it ran: ${meta}"
    rc=0
    python3 "${ORACLE_READ}" wrote "${meta}" > "${call}/meta.wrote" 2>/dev/null || rc=$?
    case "${rc}" in
      0) n=$((n + 1))
         [[ "${printed}" == true ]] || oracle_red "a record says safedeps wrote a command, from a pre-guard call that printed no rewrite: ${meta}"
         [[ "${printed}" != true ]] || cmp -s "${call}/meta.wrote" "${call}/pre.wrote" \
           || oracle_red "the command a record says safedeps wrote is not the rewrite the pre-guard printed: ${meta}" ;;
      1) ;;
      4) oracle_red "a record the pre-guard wrote does not state, as a version 2 record, whether safedeps rewrote the command: ${meta}" ;;
      *) oracle_red "a pre-guard record cannot be read: ${meta}" ;;
    esac
  done < "${call}/metas.written"
  [[ "${printed}" != true || "${n}" == 1 ]] || oracle_red "the pre-guard printed a rewrite and no single record says it wrote one (${n} do)"
  [[ "${ORACLE_FAILED}" == 0 ]]
}

# The fact a skipped rebuild gives as its reason.
oracle_skip_fact() {
  local fact="$1" rc=0
  local re_unresolved='^the directory (/.+) cannot be resolved$'
  local re_trace='^no install trace in (/.*): neither npm lockfile there is newer than the baseline taken before this command or has another inode$'
  local re_gone='^no install trace in (/.*): the baseline file (/.+) does not exist$'
  if [[ "${fact}" =~ ${re_unresolved} ]]; then
    oracle_count skip-fact-unresolved
    ! (cd -P "${BASH_REMATCH[1]}" 2>/dev/null) || oracle_red "the directory resolves"
  elif [[ "${fact}" =~ ${re_trace} ]]; then
    oracle_count skip-fact-trace
    [[ "${O_TRACE}" == none && "${BASH_REMATCH[1]}" == "${O_PROJECT}" ]] || oracle_red "the trace this file read before the hook is '${O_TRACE}' in ${O_PROJECT}"
  elif [[ "${fact}" =~ ${re_gone} ]]; then
    oracle_count trace-baseline-gone
    [[ "${O_TRACE}" == gone && "${BASH_REMATCH[1]}" == "${O_PROJECT}" ]] || oracle_red "the trace this file read before the hook is '${O_TRACE}'"
  else
    oracle_path_fact "${fact}" || rc=$?
    if [[ ${rc} -eq 0 && "${O_FACT_KIND}" == link ]]; then
      oracle_count skip-fact-link
    else
      oracle_red "the reason is not a fact form that holds on disk"
    fi
  fi
}

# A rebuild line that does not start with "safedeps added" follows the line
# that says the pre-guard asked for the flag and the command this hook received
# is not the one it wrote.
oracle_after_asked_line() {
  O_INERT_EXPECTED=1
  oracle_no_line_allowed && return 0
  [[ "${O_PREV}" == 'safedeps asked for --ignore-scripts on this install; the command this hook received is not the one safedeps wrote' ]] \
    || oracle_red "not said after the line that the pre-guard asked for --ignore-scripts and the command this hook received is not the one it wrote"
}

oracle_rebuild_calls() {
  [[ -f "${O_NPM_LOG}" ]] || { printf '0'; return; }
  grep -c '^rebuild' "${O_NPM_LOG}" || true
}

# The monitored files of <project> that are not what <snapshot> holds, as the
# unfinished-rollback report words them.
oracle_journal_expected() {
  local project="$1" snap="$2" name stored
  local list="${O_HOME}/snapshots/${snap}_monitored_files.list"
  if [[ ! -f "${list}" ]]; then
    printf 'the snapshot %s has no list of monitored files\n' "${snap}"
    return
  fi
  while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    stored=$(oracle_stored "${snap}" "${name}")
    if [[ -L "${project}/${name}" ]]; then
      printf '%s is a symbolic link to %s\n' "${project}/${name}" "$(oracle_phys "${project}/${name}")"
    elif [[ -f "${stored}" && ! -e "${project}/${name}" ]]; then
      printf '%s does not exist; the snapshot %s has it\n' "${project}/${name}" "${snap}"
    elif [[ -f "${stored}" ]] && ! cmp -s "${stored}" "${project}/${name}"; then
      printf '%s differs from the snapshot %s\n' "${project}/${name}" "${snap}"
    elif [[ ! -f "${stored}" && -f "${stored}.missing" && -e "${project}/${name}" ]]; then
      printf '%s exists; the snapshot %s recorded it as absent\n' "${project}/${name}" "${snap}"
    fi
  done < <(sort -u "${list}")
}

# Which of the kept form's check lines <line> is, if any.
oracle_kept_token() {
  local nm="${O_PROJECT}/node_modules"
  case "$1" in
    "${nm} is a symbolic link to "*) printf 'link'; return ;;
    'the pending state of this command names no install-trace baseline'|'no install trace in '*) printf 'trace'; return ;;
    'when this rollback began, none of '*) printf 'kept-files'; return ;;
    "${nm} lists no package.json the pre-command snapshot "*) printf 'kept-packages'; return ;;
    "${nm}/.bin lists no entry the pre-command snapshot "*) printf 'kept-bins'; return ;;
    "${nm}/.package-lock.json is not newer than the pre-command snapshot "*|"${nm}/.package-lock.json does not exist") printf 'lockfile'; return ;;
    "${nm} is not newer than the pre-command snapshot "*) printf 'kept-not-newer'; return ;;
  esac
  printf 'other'
}

# oracle_disk_changes: the top-level entries of the project that differ from
# the listing taken before the hook, one path per line.
oracle_disk_changes() {
  local before after
  before="${O_CALL}/listing/$(oracle_dir_hash "${O_PROJECT}")"
  [[ -f "${before}" ]] || { printf 'unknown\n'; return 0; }
  after=$(python3 "${ORACLE_READ}" listing "${O_PROJECT}" 2>/dev/null) || { printf 'unknown\n'; return 0; }
  # The names whose line is in one listing and not the other.
  LC_ALL=C comm -3 <(LC_ALL=C sort "${before}") <(printf '%s\n' "${after}" | sed '/^$/d' | LC_ALL=C sort) \
    | awk -F'\t' -v dir="${O_PROJECT}" '{ print dir "/" ($1 == "" ? $2 : $1) }' | LC_ALL=C sort -u
}

# What a block must hold once all its lines are read.
oracle_block_end() {
  local changes path
  if [[ -n "${O_KEPT_EXPECT}" ]]; then
    O_LINE="${O_HEAD}"; oracle_red "kept is not followed by all its check lines (missing: ${O_KEPT_EXPECT})"
  fi
  case "${O_BLOCK}" in
    rollback|backstop-rollback)
      [[ -n "${O_SNAP}" ]] || { O_LINE="${O_HEAD}"; oracle_red "a rollback message with no snapshot line"; }
      # Only the rollback that consumed this command's record says what
      # safedeps did; the backstop found none (oracle_inert_line).
      [[ "${O_BLOCK}" != rollback ]] || O_INERT_EXPECTED=1
      [[ "${O_BLOCK}" != rollback || "${O_SAW_INERT}" == 1 ]] || oracle_no_line_allowed \
        || { O_LINE="${O_HEAD}"; oracle_red "a rollback message with no --ignore-scripts line, and the pre-guard's record states one: ${O_VERDICT}"; }
      [[ "${O_SAW_DETAILS}" == 1 ]] || { O_LINE="${O_HEAD}"; oracle_red "a rollback message with no Details log line"; }
      if [[ "${O_CHANGED}" == 0 && "${O_SAW_NOTHING}" != 1 ]]; then
        O_LINE="${O_HEAD}"; oracle_red "no step line and no 'The rollback changed nothing.'"
      fi
      # Every top-level entry the rollback changed is named by a step line, and
      # "The rollback changed nothing." needs a listing that did not change.
      if [[ "${O_DIRECT}" != 1 ]]; then
        changes=$(oracle_disk_changes)
        if [[ "${changes}" == unknown ]]; then
          O_LINE="${O_HEAD}"; oracle_red "no listing of ${O_PROJECT} from before the hook"
        else
          while IFS= read -r path; do
            [[ -n "${path}" ]] || continue
            O_LINE="${path}"
            [[ "${O_SAW_NOTHING}" != 1 ]] || oracle_red "'The rollback changed nothing.', and this entry of the project changed on disk"
            grep -qxF -- "${path}" <<< "${O_STEP_PATHS}" || oracle_red "this entry of the project changed on disk, and no step line names it"
          done <<< "${changes}"
        fi
      fi
      # A rollback acts in the project this call judged: the record's
      # project_dir, or the directory the payload says the command ran in.
      # A record with no project_dir once sent the hook to its own working
      # directory, and a rollback there acted on another project.
      while IFS= read -r path; do
        [[ -n "${path}" ]] || continue
        [[ "${path}" == "${O_PROJECT}" || "${path}" == "${O_PROJECT}/"* ]] && continue
        O_LINE="${path}"; oracle_red "a step line names a path outside ${O_PROJECT}"
      done <<< "${O_STEP_PATHS}"
      ;;
    journal)
      local expected reported
      expected=$(oracle_journal_expected "${O_JOURNAL_PROJECT}" "${O_SNAP}" | sort)
      reported=$(printf '%s' "${O_JOURNAL_LINES}" | sed '/^$/d' | sort)
      if [[ "${expected}" != "${reported}" ]]; then
        O_LINE="${O_HEAD}"
        oracle_red "the files reported are not the monitored files that differ (expected: ${expected//$'\n'/ | })"
      fi
      [[ "${O_SAW_OWNER}" == 1 ]] || { O_LINE="${O_HEAD}"; oracle_red "an unfinished-rollback report with no Owner line"; }
      [[ "${O_SAW_JNM}" == 1 ]] || { O_LINE="${O_HEAD}"; oracle_red "an unfinished-rollback report with no node_modules line"; }
      ;;
  esac
  oracle_expect_log
  O_BLOCK="" O_SNAP="" O_SAW_INERT=0 O_SAW_DETAILS=0 O_SAW_NOTHING=0 O_CHANGED=0 O_SKIP=0
  O_JOURNAL_PROJECT="" O_JOURNAL_LINES="" O_JOURNAL_ID="" O_SAW_OWNER=0 O_SECTION=""
  O_KEPT_EXPECT="" O_STEP_PATHS="" O_SAW_JNM=0 O_BODY="" O_REASONS="" O_REFUSED="" O_JFIELDS=""
}

# A line of a rollback, a confirm or a backstop block must also be a line of
# the reorg.log entry: the records say the same thing in the same words.
# Whether a line is one of the reasons a node_modules step is taken for.
oracle_is_reason() {
  [[ "$1" == 'this rollback has no snapshot from before the command' ]] && return 0
  [[ "$1" =~ ^/.+\ is\ newer\ than\ (the\ baseline|the\ pre-command\ snapshot) ]] && return 0
  [[ "$1" =~ \ differed\ from\ the\ pre-command\ snapshot\ .+\ when\ this\ rollback\ began$ ]] && return 0
  [[ "$1" =~ ,\ which\ the\ pre-command\ snapshot\ [^\ ]+\ does\ not$ ]] && return 0
  [[ "$1" =~ ^/.+\ does\ not\ exist$ ]] && return 0
  return 1
}
# A step over node_modules is said right after its reason.
oracle_nm_step() {
  [[ "$1" == */node_modules ]] || return 0
  oracle_is_reason "${O_PREV}" || oracle_red "a node_modules step with no reason line before it"
}

# The reorg.log entries a block's lines call for, in the order the hook writes
# them: the frame each kind of entry has, then the block's own lines.
oracle_expect_log() {
  local l
  [[ "${O_DIRECT}" != 1 ]] || return 0
  case "${O_BLOCK}" in
    rollback|backstop-rollback)
      while IFS= read -r l; do
        [[ -n "${l}" ]] || continue
        O_EXPECT+="log-refused"$'\037'"REORG REFUSED"$'\n'"  Project: ${O_PROJECT}"$'\n'"  ${l}"$'\036'
      done <<< "${O_REFUSED}"
      if [[ "${O_BLOCK}" == rollback ]]; then
        O_EXPECT+="log-rollback"$'\037'"REORG executed"$'\n'"  Snapshot: ${O_PRE}"$'\n'
      else
        O_EXPECT+="log-backstop"$'\037'"REORG executed (command-independent backstop)"$'\n'
      fi
      O_EXPECT+="  Project: ${O_PROJECT}"$'\n'"  Reasons: ${O_REASONS}"
      while IFS= read -r l; do
        [[ -n "${l}" ]] && O_EXPECT+=$'\n'"  ${l}"
      done <<< "${O_BODY}"
      O_EXPECT+=$'\036'
      ;;
    confirm)
      O_EXPECT+="log-confirm"$'\037'"CONFIRM warnings"$'\n'"  Snapshot: ${O_PRE}"$'\n'"  Project: ${O_PROJECT}"
      while IFS= read -r l; do
        [[ -n "${l}" ]] && O_EXPECT+=$'\n'"  ${l}"
      done <<< "${O_BODY}"
      O_EXPECT+=$'\036'
      ;;
    journal)
      local head='REORG INTERRUPTED'
      [[ "${O_JOURNAL_HEAD}" != stopped ]] || head='REORG STOPPED'
      O_EXPECT+="log-journal"$'\037'"${head}${O_JFIELDS}"$'\036'
      ;;
  esac
}

# Collects what oracle_expect_log needs from a line already read.
#
# oracle_collect <line> <whether it was the line under a reasons header>
oracle_collect() {
  local line="$1"
  case "${O_BLOCK}" in
    rollback|backstop-rollback)
      if [[ "$2" == 1 ]]; then
        O_REASONS="${line}"
      elif [[ "${line}" == 'Rollback snapshot: '* ]]; then
        O_BODY="${line}"$'\n'
      elif [[ -n "${O_BODY}" && -n "${line}" && "${line}" != 'What the rollback did and what it found:' && "${line}" != 'Details log: '* ]]; then
        O_BODY+="${line}"$'\n'
        [[ "${line}" != 'refused '* ]] || O_REFUSED+="${line}"$'\n'
      fi
      ;;
    confirm)
      [[ -z "${line}" || "${line}" == "${O_HEAD}" ]] || O_BODY+="${line}"$'\n'
      ;;
    journal)
      if [[ "$2" == 1 ]]; then
        O_JREASONS="${line}"
      fi
      case "${line}" in
        'Journal: '*) O_JFIELDS+=$'\n'"  ${line}" ;;
        'Owner: '*) O_JFIELDS+=$'\n'"  ${line}"$'\n'"  Project: ${O_JOURNAL_PROJECT}" ;;
        'Rollback snapshot: '*) O_JFIELDS+=$'\n'"  ${line}" ;;
        'Checked at the time of this report:') O_JFIELDS+=$'\n'"  Reasons: ${O_JREASONS}" ;;
        'Incident record: '*) O_JFIELDS+=$'\n'"  ${line}" ;;
      esac
      ;;
  esac
  [[ -z "${line}" ]] || O_ALL_LINES+="${line}"$'\n'
}

# oracle_check_logs: the reorg.log entries the hook appended are exactly the
# ones its message calls for, its two rollback lines in advisory.log repeat
# lines of the message, and it says it could not read the record exactly when
# its read failed.
oracle_check_logs() {
  local size actual expected="" e kind a line re_adv re_adv_bare re_unread re_unstated unread=0 unstated=0 want
  size=$(cat "${O_CALL}/reorg.size" 2>/dev/null); size="${size:-0}"
  # Each entry starts with a timestamped headline; the frame and the lines are
  # indented by two spaces.
  actual=$(tail -c +"$(( size + 1 ))" "${O_HOME}/reorg.log" 2>/dev/null | awk '
    /^\[[0-9TZ:-]+\] / { if (n++) printf "\036"; sub(/^\[[0-9TZ:-]+\] /, ""); printf "%s", $0; next }
    { printf "\n%s", $0 }
    END { if (n) printf "\036" }')
  while IFS= read -r -d $'\036' e; do
    kind="${e%%$'\037'*}"
    expected+="${e#*$'\037'}"$'\036'
    oracle_count "${kind}"
  done < <(printf '%s' "${O_EXPECT}")
  if [[ "${actual}" != "${expected}" ]]; then
    O_LINE="reorg.log"
    oracle_red "the reorg.log entries this hook appended are not the ones its message calls for -- appended: [${actual//$'\036'/ || }] -- called for: [${expected//$'\036'/ || }]"
  fi
  size=$(cat "${O_CALL}/advisory.size" 2>/dev/null); size="${size:-0}"
  re_adv='^post-verify REORG with no confirmed snapshot in (/[^:]*): (Rollback snapshot: .*); (safedeps [^.]*)\. Reasons: (.*)$'
  re_adv_bare='^post-verify REORG with no confirmed snapshot in (/[^:]*): (Rollback snapshot: .*)\. Reasons: (.*)$'
  re_unread="^post-verify: could not read the pre-guard's record of this command in (.*), so no --ignore-scripts line was said$"
  re_unstated='^post-verify: (.*) is not a version 2 pre-guard record that states whether safedeps rewrote this command, so no --ignore-scripts line was said$'
  while IFS=$'\t' read -r _ a; do
    O_LINE="advisory.log: ${a}"
    if [[ "${a}" == 'post-verify REORG REFUSED: '* ]]; then
      line="${a#post-verify REORG REFUSED: }"; line="${line% -- project *}"
      grep -qxF -- "${line}" <<< "${O_ALL_LINES}" || oracle_red "advisory.log carries a refusal the message does not"
    elif [[ "${a}" =~ ${re_adv} ]]; then
      grep -qxF -- "${BASH_REMATCH[2]}" <<< "${O_ALL_LINES}" || oracle_red "advisory.log carries a snapshot line the message does not"
      grep -qxF -- "${BASH_REMATCH[3]}" <<< "${O_ALL_LINES}" || oracle_red "advisory.log carries an --ignore-scripts line the message does not"
    elif [[ "${a}" =~ ${re_adv_bare} ]]; then
      grep -qxF -- "${BASH_REMATCH[2]}" <<< "${O_ALL_LINES}" || oracle_red "advisory.log carries a snapshot line the message does not"
      oracle_no_line_allowed || oracle_red "an advisory.log rollback line with no --ignore-scripts line from a hook that read the record"
    elif [[ "${a}" =~ ${re_unread} ]]; then
      oracle_count log-inert-unread; unread=$(( unread + 1 ))
      [[ "${O_RECORD_UNREAD}" == 1 || "${O_VERDICT}" == unreadable ]] || oracle_red "advisory.log says the record could not be read, and the hook's read of it did not fail"
      [[ "${BASH_REMATCH[1]}" == "${O_META}" ]] || oracle_red "advisory.log names another record than this call's (${O_META})"
    elif [[ "${a}" =~ ${re_unstated} ]]; then
      oracle_count log-inert-unstated; unstated=$(( unstated + 1 ))
      [[ "${O_RECORD_UNREAD}" != 1 && "${O_VERDICT}" == unstated ]] || oracle_red "advisory.log says the record does not state whether safedeps rewrote the command, and it does: ${O_VERDICT}"
      [[ "${BASH_REMATCH[1]}" == "${O_META}" ]] || oracle_red "advisory.log names another record than this call's (${O_META})"
    elif [[ "${a}" == 'post-verify REORG with no confirmed snapshot'* ]]; then
      oracle_red "an advisory.log rollback line outside its form"
    fi
  done < <(tail -c +"$(( size + 1 ))" "${O_HOME}/advisory.log" 2>/dev/null)
  if [[ "${O_RECORD_UNREAD}" == 1 && "${unread}" != 1 ]]; then
    O_LINE="advisory.log"
    oracle_red "a hook whose read of the pre-guard's record failed said so in advisory.log ${unread} times, not once"
  fi
  # A message that would carry a line and carries none says why once.
  if [[ "${O_RECORD_UNREAD}" != 1 ]]; then
    want=0; [[ "${O_INERT_EXPECTED}" == 1 && "${O_VERDICT}" == unreadable ]] && want=1
    [[ "${unread}" == "${want}" ]] \
      || { O_LINE="advisory.log"; oracle_red "a hook that could not read the pre-guard's record said so in advisory.log ${unread} times, not ${want}"; }
    want=0; [[ "${O_INERT_EXPECTED}" == 1 && "${O_VERDICT}" == unstated ]] && want=1
    [[ "${unstated}" == "${want}" ]] \
      || { O_LINE="advisory.log"; oracle_red "a hook whose record states no --ignore-scripts line said so in advisory.log ${unstated} times, not ${want}"; }
  elif [[ "${unstated}" != 0 ]]; then
    O_LINE="advisory.log"; oracle_red "a hook whose read of the pre-guard's record failed says the record states no line"
  fi
}

# Whether this call may carry no --ignore-scripts line where a message would
# carry one: its read failed (from the row), or the record, read in Python,
# states neither fact or is not one JSON object.
oracle_no_line_allowed() {
  [[ "${O_RECORD_UNREAD}" == 1 || "${O_VERDICT}" == unstated || "${O_VERDICT}" == unreadable ]]
}

# oracle_verdict: the line the record allows for this call, from Python
# (report-oracle-read.py said): added, asked, none, unstated, unreadable, or
# nocommand when the hook input carries no command.
oracle_verdict() {
  printf '%s' "${O_PAYLOAD}" > "${O_CALL}/inert.payload"
  if ! python3 "${ORACLE_READ}" string "${O_CALL}/inert.payload" tool_input command > "${O_CALL}/inert.received" 2>/dev/null; then
    O_VERDICT=nocommand
    return
  fi
  O_VERDICT=$(python3 "${ORACLE_READ}" said "${O_META:-${O_CALL}/no-record}" "${O_CALL}/inert.received" 2>/dev/null) || O_VERDICT=unreadable
}

oracle_line() {
  local line="$1" rc=0 entry prose id
  O_LINE="${line}"

  local re_journal_head='^safedeps: a rollback of (/.+) (did not finish|has not finished)\.$'
  local re_snap_confirmed='^Rollback snapshot: ([^ ,]+), a confirmed snapshot$'
  local re_snap_pre='^Rollback snapshot: ([^ ,]+), taken before this command; no confirmed snapshot names it$'
  local re_snap_journal_pre='^Rollback snapshot: ([^ ,;]+); no confirmed snapshot names it$'
  local re_restored='^restored (/.+)$'
  local re_not_restored_differs='^not restored (/.+): cp exit ([0-9]+); (/.+) differs from the snapshot$'
  local re_not_restored_absent='^not restored (/.+): cp exit ([0-9]+); (/.+) does not exist$'
  local re_not_restored_not_file='^not restored (/.+): (/.+) exists and is not a regular file$'
  local re_removed='^removed (/.+)$'
  local re_not_removed='^not removed (/.+): rm exit ([0-9]+); (.+)$'
  local re_refused='^refused (restore|removal) of (/.+): (.+)$'
  local re_unresolved='^the project directory (/.+) cannot be resolved$'
  local re_wskey='^(/.+)/package\.json has the key workspaces$'
  local re_kept='^kept (/.+)$'
  local re_kept_files='^when this rollback began, none of (.+) in (/.+) differed from the pre-command snapshot ([^ ]+)$'
  local re_kept_packages='^(/.+) lists no package\.json the pre-command snapshot ([^ ]+) lacks$'
  local re_kept_bins='^(/.+)/\.bin lists no entry the pre-command snapshot ([^ ]+) lacks$'
  local re_kept_newer='^(/.+) is not newer than the pre-command snapshot ([^ ]+)$'
  local re_reason_trace='^(/.+) is newer than the baseline taken before this command or has another inode$'
  local re_reason_file='^(/.+)/([^/]+) differed from the pre-command snapshot ([^ ]+) when this rollback began$'
  local re_reason_bin='^(/.+)/\.bin lists ([^/]+), which the pre-command snapshot ([^ ]+) does not$'
  local re_reason_package='^(/.+) lists (/.+), which the pre-command snapshot ([^ ]+) does not$'
  local re_reason_newer='^(/.+) is newer than the pre-command snapshot ([^ ]+)$'
  local re_trace_none='^no install trace in (/.*): neither npm lockfile there is newer than the baseline taken before this command or has another inode$'
  local re_trace_gone='^no install trace in (/.*): the baseline file (/.+) does not exist$'
  local re_skip_added='^safedeps added --ignore-scripts to this install and did not run npm rebuild: (.+)$'
  local re_ran_added='^safedeps added --ignore-scripts to this install and ran npm rebuild: exit ([0-9]+)$'
  local re_skip='^safedeps did not run npm rebuild: (.+)$'
  local re_ran='^safedeps ran npm rebuild: exit ([0-9]+)$'
  local re_no_confirmed='^no confirmed snapshot is recorded for (/.+)$'
  local re_no_meta='^the confirmed snapshot ([^ ]+) of (/.+): (/.+) does not exist$'
  local re_journal='^Journal: ([^,]+), opened ([^;]+); last recorded stage ([a-z-]+)(, entered ([^ ]+)( [^ ]+ ([0-9]+)s into the rollback)?)?$'
  local re_owner='^Owner: (.+)$'
  local re_j_differs='^(/.+) differs from the snapshot ([^ ]+)$'
  local re_j_gone='^(/.+) does not exist; the snapshot ([^ ]+) has it$'
  local re_j_extra='^(/.+) exists; the snapshot ([^ ]+) recorded it as absent$'
  local re_j_nolist='^the snapshot ([^ ]+) has no list of monitored files$'
  local re_file_absent='^(Details log|Incident record|Rollback log): (/.+) is not a file$'
  local re_file='^(Details log|Incident record|Rollback log): (/.+)$'

  # The reasons a rollback was started are the checks' own strings and are not
  # read here: exactly one line, then a blank one.
  if [[ "${O_SKIP}" == 1 ]]; then
    [[ -n "${line}" ]] || oracle_red "no reason line under the reasons header"
    O_SKIP=2
    return 0
  elif [[ "${O_SKIP}" == 2 ]]; then
    [[ -z "${line}" ]] || oracle_red "more than one line under the reasons header"
    O_SKIP=0
    [[ -z "${line}" ]] && return 0
  fi

  case "${line}" in
    '') return 0 ;;
    'safedeps: suspicious dependency change detected. A rollback ran.')
      oracle_block_end; O_BLOCK=rollback; O_HEAD="${line}"; oracle_count head-rollback; return 0 ;;
    'safedeps: suspicious dependency change detected; this hook found no record of this command from before it ran. A rollback ran.')
      oracle_block_end; O_BLOCK=backstop-rollback; O_HEAD="${line}"; oracle_count head-backstop-rollback
      oracle_record_none; return 0 ;;
    'safedeps: suspicious dependency change detected; this hook found no record of this command from before it ran. No rollback ran.')
      oracle_block_end; O_BLOCK=backstop-none; O_HEAD="${line}"; oracle_count head-backstop-none
      oracle_record_none; return 0 ;;
    'safedeps: suspicious dependency change detected; this hook found a pre-guard record, and the snapshot it names has no meta file. A rollback ran.')
      oracle_block_end; O_BLOCK=backstop-rollback; O_HEAD="${line}"; oracle_count head-gone-rollback
      oracle_record_gone_head; return 0 ;;
    'safedeps: suspicious dependency change detected; this hook found a pre-guard record, and the snapshot it names has no meta file. No rollback ran.')
      oracle_block_end; O_BLOCK=backstop-none; O_HEAD="${line}"; oracle_count head-gone-none
      oracle_record_gone_head; return 0 ;;
    'safedeps: suspicious dependency change detected; this hook found a pre-guard record, and the record names no snapshot. A rollback ran.')
      oracle_block_end; O_BLOCK=backstop-rollback; O_HEAD="${line}"; oracle_count head-empty-rollback
      oracle_record_empty_head; return 0 ;;
    'safedeps: suspicious dependency change detected; this hook found a pre-guard record, and the record names no snapshot. No rollback ran.')
      oracle_block_end; O_BLOCK=backstop-none; O_HEAD="${line}"; oracle_count head-empty-none
      oracle_record_empty_head; return 0 ;;
    'safedeps: suspicious dependency change detected; this hook found a pre-guard record, and the record is not one JSON object. A rollback ran.')
      oracle_block_end; O_BLOCK=backstop-rollback; O_HEAD="${line}"; oracle_count head-unread-rollback
      oracle_record_unread_head; return 0 ;;
    'safedeps: suspicious dependency change detected; this hook found a pre-guard record, and the record is not one JSON object. No rollback ran.')
      oracle_block_end; O_BLOCK=backstop-none; O_HEAD="${line}"; oracle_count head-unread-none
      oracle_record_unread_head; return 0 ;;
    'safedeps: this install was not rolled back.')
      oracle_block_end; O_BLOCK=confirm; O_HEAD="${line}"; oracle_count head-confirm; return 0 ;;
    'Detected problems:')
      [[ "${O_BLOCK}" == rollback || "${O_BLOCK}" == backstop-rollback || "${O_BLOCK}" == backstop-none ]] || oracle_red "a reasons header outside a rollback message"
      O_SKIP=1; return 0 ;;
    'Recorded reasons:')
      [[ "${O_BLOCK}" == journal ]] || oracle_red "a recorded-reasons header outside an unfinished-rollback report"
      O_SKIP=1; return 0 ;;
    'What the rollback did and what it found:')
      [[ "${O_BLOCK}" == rollback || "${O_BLOCK}" == backstop-rollback ]] || oracle_red "a rollback header outside a rollback message"
      return 0 ;;
    'Checked at the time of this report:')
      [[ "${O_BLOCK}" == journal ]] || oracle_red "a report header outside an unfinished-rollback report"
      O_SECTION=checked; return 0 ;;
  esac

  if [[ "${line}" =~ ${re_journal_head} ]]; then
    oracle_block_end
    O_BLOCK=journal; O_HEAD="${line}"; O_JOURNAL_PROJECT="${BASH_REMATCH[1]}"
    if [[ "${BASH_REMATCH[2]}" == "has not finished" ]]; then O_JOURNAL_HEAD=stopped; oracle_count head-journal-stopped
    else O_JOURNAL_HEAD=gone; oracle_count head-journal-gone; fi
    return 0
  fi
  [[ -n "${O_BLOCK}" ]] || { oracle_red "a line before any headline"; return 0; }

  # The effect gate's prose, by exact prefix, in the blocks it is said in.
  for entry in "${ORACLE_PROSE[@]}"; do
    prose=$(oracle_prose_field "${entry}" 4)
    if [[ "${line:0:${#prose}}" == "${prose}" ]]; then
      [[ " $(oracle_prose_field "${entry}" 2) " == *" ${O_BLOCK} "* ]] || oracle_red "effect-gate prose in a block it is not said in (${O_BLOCK})"
      oracle_count "${entry%%|*}"
      [[ "${entry%%|*}" != prose-fetched-elsewhere ]] || oracle_fetched_engine "${line}"
      return 0
    fi
  done

  if [[ "${O_BLOCK}" == journal ]]; then
    if [[ "${line}" =~ ${re_journal} ]]; then
      oracle_count journal
      O_JOURNAL_ID="${BASH_REMATCH[1]}"
      local copy="${O_CALL}/journal/${BASH_REMATCH[1]}.json" opened="${BASH_REMATCH[2]}" stage="${BASH_REMATCH[3]}" entered="${BASH_REMATCH[5]}" into="${BASH_REMATCH[7]}"
      [[ "$(jq -r '.opened_at // "unknown"' "${copy}" 2>/dev/null)" == "${opened}" ]] || oracle_red "the journal entry was opened at another time"
      [[ "$(jq -r '.stage // "unknown"' "${copy}" 2>/dev/null)" == "${stage}" ]] || oracle_red "the journal entry records another stage"
      [[ "$(jq -r '.stage_at // empty' "${copy}" 2>/dev/null)" == "${entered}" ]] || oracle_red "the journal entry records another stage time"
      if [[ -n "${into}" ]]; then
        [[ "$(( $(oracle_epoch "${entered}") - $(oracle_epoch "${opened}") ))" == "${into}" ]] || oracle_red "the seconds are not the distance between the two stamps"
      fi
      [[ "$(jq -r '.project_dir // "unknown"' "${copy}" 2>/dev/null)" == "${O_JOURNAL_PROJECT}" ]] || oracle_red "the journal entry names another project"
    elif [[ "${line}" =~ ${re_owner} ]]; then
      local fact="${BASH_REMATCH[1]}" state expected=""
      O_SAW_OWNER=1
      state=$(cat "${O_CALL}/journal/${O_JOURNAL_ID}.owner" 2>/dev/null)
      local pid; pid=$(jq -r '.pid // empty' "${O_CALL}/journal/${O_JOURNAL_ID}.json" 2>/dev/null)
      case "${fact}" in
        "pid ${pid} is not running") expected=not-running ;;
        "pid ${pid} is a zombie (ps state "*")") expected=zombie ;;
        "pid ${pid} is stopped (ps state "*")") expected=stopped ;;
        "pid ${pid} started after the journal was opened") expected=later ;;
        "the journal records no pid") expected=no-pid ;;
        "ps gives no start time for pid ${pid}") expected=no-start ;;
        "the start time ps gives for pid ${pid} cannot be parsed") expected=bad-start ;;
        "the opening time of the journal cannot be parsed") expected=bad-opened ;;
        *) oracle_red "a line outside the grammar"; return 0 ;;
      esac
      oracle_count "owner-${expected}"
      [[ "${state}" == "${expected}" ]] || oracle_red "the owner this file read before the hook is '${state}'"
      if [[ "${expected}" == stopped ]]; then
        [[ "${O_JOURNAL_HEAD}" == stopped ]] || oracle_red "a stopped owner under a headline that says the rollback did not finish"
      else
        [[ "${O_JOURNAL_HEAD}" == gone ]] || oracle_red "an owner that is not stopped under a headline that says it has not finished"
      fi
    elif [[ "${line}" =~ ${re_snap_confirmed} || "${line}" =~ ${re_snap_journal_pre} ]]; then
      O_SNAP="${BASH_REMATCH[1]}"
      [[ "$(jq -r '.rollback_snapshot // "unknown"' "${O_CALL}/journal/${O_JOURNAL_ID}.json" 2>/dev/null)" == "${O_SNAP}" ]] || oracle_red "the journal entry names another snapshot"
      local jrec jconf=""
      jrec="${O_HOME}/confirmed_$(oracle_dir_hash "${O_JOURNAL_PROJECT}")"
      if [[ -f "${jrec}" ]]; then jconf=$(cat "${jrec}"); elif [[ -f "${O_HOME}/confirmed" ]]; then jconf=$(cat "${O_HOME}/confirmed"); fi
      if [[ "${line}" =~ ${re_snap_confirmed} ]]; then
        oracle_count snapshot-journal-confirmed
        [[ "${jconf}" == "${O_SNAP}" ]] || oracle_red "the project's confirmed record does not name this snapshot"
      else
        oracle_count snapshot-journal-pre
        [[ "${jconf}" != "${O_SNAP}" ]] || oracle_red "the project's confirmed record names this snapshot"
      fi
    elif [[ "${line}" =~ ${re_j_gone} ]]; then
      oracle_count journal-gone; O_JOURNAL_LINES+="${line}"$'\n'
    elif [[ "${line}" =~ ${re_j_extra} ]]; then
      oracle_count journal-extra; O_JOURNAL_LINES+="${line}"$'\n'
    elif [[ "${line}" =~ ${re_j_differs} ]]; then
      oracle_count journal-differs; O_JOURNAL_LINES+="${line}"$'\n'
    elif [[ "${line}" =~ ${re_j_nolist} ]]; then
      oracle_count journal-no-list; O_JOURNAL_LINES+="${line}"$'\n'
    elif [[ "${line}" =~ ${re_file_absent} ]]; then
      oracle_count file-line-absent
      [[ "${BASH_REMATCH[1]}" != "Details log" ]] || oracle_red "a Details log line in an unfinished-rollback report"
      [[ ! -f "${BASH_REMATCH[2]}" ]] || oracle_red "it is a file"
    elif [[ "${line}" =~ ${re_file} ]]; then
      oracle_count file-line
      [[ "${BASH_REMATCH[1]}" != "Details log" ]] || oracle_red "a Details log line in an unfinished-rollback report"
      [[ -f "${BASH_REMATCH[2]}" ]] || oracle_red "no such file"
      else
      oracle_path_fact "${line}" || rc=$?
      if [[ ${rc} -eq 2 || "${O_SECTION}" != checked ]]; then
        oracle_red "a line outside the grammar"
      elif [[ ${rc} -ne 0 ]]; then
        oracle_red "the stated fact does not hold on disk"
      elif [[ "${O_FACT_PATH}" == "${O_JOURNAL_PROJECT}/node_modules" ]]; then
        oracle_count "path-${O_FACT_KIND}"; O_SAW_JNM=1
      elif [[ "${O_FACT_KIND}" == link ]]; then
        oracle_count path-link; O_JOURNAL_LINES+="${line}"$'\n'
      else
        oracle_red "a path line the unfinished-rollback report has no form for"
      fi
    fi
    return 0
  fi

  if [[ "${O_BLOCK}" == backstop-none ]]; then
    if [[ "${line}" =~ ${re_no_confirmed} ]]; then
      oracle_count backstop-no-confirmed
      [[ "${BASH_REMATCH[1]}" == "${O_PROJECT}" ]] || oracle_red "another project"
      [[ ! -e "${O_HOME}/confirmed" && ! -e "${O_HOME}/confirmed_${O_DIR_HASH}" ]] || oracle_red "a confirmed record exists for the project"
    elif [[ "${line}" =~ ${re_no_meta} ]]; then
      oracle_count backstop-no-meta
      [[ "$(cat "${O_HOME}/confirmed_${O_DIR_HASH}" 2>/dev/null)" == "${BASH_REMATCH[1]}" ]] || oracle_red "the confirmed record names another snapshot"
      [[ "${BASH_REMATCH[3]}" == "${O_HOME}/snapshots/${BASH_REMATCH[1]}_meta.json" && ! -e "${BASH_REMATCH[3]}" ]] || oracle_red "the meta file exists, or is another file"
    else
      oracle_red "a line outside the grammar"
    fi
    return 0
  fi

  # A rollback or a confirm block.
  if [[ "${line}" =~ ${re_snap_confirmed} ]]; then
    oracle_count snapshot-confirmed; O_SNAP="${BASH_REMATCH[1]}"
    [[ "$(cat "${O_HOME}/confirmed_${O_DIR_HASH}" 2>/dev/null || cat "${O_HOME}/confirmed" 2>/dev/null)" == "${O_SNAP}" ]] || oracle_red "the confirmed record of the project does not name this snapshot"
  elif [[ "${line}" =~ ${re_snap_pre} ]]; then
    oracle_count snapshot-pre; O_SNAP="${BASH_REMATCH[1]}"
    [[ "${O_SNAP}" == "${O_PRE}" ]] || oracle_red "the snapshot the pre-guard took for this command is '${O_PRE}'"
    ! grep -qsxF -- "${O_SNAP}" "${O_HOME}"/confirmed "${O_HOME}"/confirmed_* 2>/dev/null || oracle_red "a confirmed record names this snapshot"
  elif [[ "${line}" == 'The rollback changed nothing.' ]]; then
    oracle_count changed-nothing; O_SAW_NOTHING=1
    [[ "${O_CHANGED}" == 0 ]] || oracle_red "said next to a restored or removed line"
  elif [[ "${line}" =~ ${re_not_restored_not_file} ]]; then
    oracle_count not-restored-not-file
    [[ "${BASH_REMATCH[1]}" == "${BASH_REMATCH[2]}" ]] || oracle_red "two paths"
    [[ -e "${BASH_REMATCH[1]}" && ! -L "${BASH_REMATCH[1]}" && ! -f "${BASH_REMATCH[1]}" ]] || oracle_red "it is a regular file, a link, or not there"
    O_STEP_PATHS+="${BASH_REMATCH[1]}"$'\n'
  elif [[ "${line}" =~ ${re_not_restored_differs} ]]; then
    oracle_count not-restored-differs; O_CHANGED=1
    O_STEP_PATHS+="${BASH_REMATCH[1]}"$'\n'
    [[ "${BASH_REMATCH[1]}" == "${BASH_REMATCH[3]}" ]] || oracle_red "two paths"
    [[ "${BASH_REMATCH[2]}" != 0 ]] || oracle_red "cp exit 0"
    { [[ -e "${BASH_REMATCH[1]}" ]] && ! cmp -s "$(oracle_stored "${O_SNAP}" "${BASH_REMATCH[1]#"${O_PROJECT}/"}")" "${BASH_REMATCH[1]}"; } || oracle_red "the file is gone, or equals the snapshot"
  elif [[ "${line}" =~ ${re_not_restored_absent} ]]; then
    oracle_count not-restored-absent; O_CHANGED=1
    O_STEP_PATHS+="${BASH_REMATCH[1]}"$'\n'
    [[ "${BASH_REMATCH[1]}" == "${BASH_REMATCH[3]}" ]] || oracle_red "two paths"
    [[ ! -e "${BASH_REMATCH[1]}" && ! -L "${BASH_REMATCH[1]}" ]] || oracle_red "the file exists"
  elif [[ "${line}" =~ ${re_restored} ]]; then
    oracle_count restored; O_CHANGED=1
    O_STEP_PATHS+="${BASH_REMATCH[1]}"$'\n'
    cmp -s "$(oracle_stored "${O_SNAP}" "${BASH_REMATCH[1]#"${O_PROJECT}/"}")" "${BASH_REMATCH[1]}" || oracle_red "the file does not equal the snapshot"
  elif [[ "${line}" =~ ${re_not_removed} ]]; then
    oracle_count not-removed; O_CHANGED=1
    local nr_path="${BASH_REMATCH[1]}" nr_rc="${BASH_REMATCH[2]}" nr_fact="${BASH_REMATCH[3]}"
    O_STEP_PATHS+="${nr_path}"$'\n'
    oracle_nm_step "${nr_path}"
    oracle_path_fact "${nr_fact}" || rc=$?
    [[ ${rc} -eq 0 && "${O_FACT_PATH}" == "${nr_path}" && "${O_FACT_KIND}" != absent ]] || oracle_red "the path is gone, or the fact names another path"
    [[ "${nr_rc}" != 0 ]] || oracle_red "rm exit 0"
  elif [[ "${line}" =~ ${re_removed} ]]; then
    oracle_count removed; O_CHANGED=1
    local rm_path="${BASH_REMATCH[1]}"
    O_STEP_PATHS+="${rm_path}"$'\n'
    oracle_nm_step "${rm_path}"
    [[ ! -e "${rm_path}" && ! -L "${rm_path}" ]] || oracle_red "the path is still there"
  elif [[ "${line}" =~ ${re_refused} ]]; then
    local rf_kind="${BASH_REMATCH[1]}" rf_path="${BASH_REMATCH[2]}" rf_fact="${BASH_REMATCH[3]}"
    [[ "${rf_kind}" != removal ]] || oracle_nm_step "${rf_path}"
    if [[ "${rf_fact}" =~ ${re_unresolved} ]]; then
      oracle_count refused-unresolved
      ! (cd -P "${BASH_REMATCH[1]}" 2>/dev/null) || oracle_red "the directory resolves"
      [[ "${rf_path}" == "${BASH_REMATCH[1]}"/* ]] || oracle_red "the path is not in that directory"
    else
      oracle_count "refused-${rf_kind}-link"
      oracle_path_fact "${rf_fact}" || rc=$?
      [[ ${rc} -eq 0 && "${O_FACT_KIND}" == link && "${O_FACT_PATH}" == "${rf_path}" ]] || oracle_red "not a link to that place, or the fact names another path"
    fi
  elif [[ "${line}" =~ ${re_wskey} ]]; then
    oracle_count workspaces-key
    jq -e 'type == "object" and has("workspaces")' "${BASH_REMATCH[1]}/package.json" >/dev/null 2>&1 || oracle_red "no workspaces key"
  elif [[ "${line}" == 'this rollback has no snapshot from before the command' ]]; then
    oracle_count reason-no-snapshot
    [[ "${O_BLOCK}" == backstop-rollback && -z "${O_PRE}" ]] || oracle_red "said outside the backstop, or a pending state was consumed for this command"
  elif [[ "${line}" =~ ${re_reason_trace} ]]; then
    oracle_count reason-trace
    [[ "${O_TRACE}" == present ]] || oracle_red "the trace this file read before the hook is '${O_TRACE}'"
    [[ "${BASH_REMATCH[1]}" == "${O_PROJECT}/package-lock.json" || "${BASH_REMATCH[1]}" == "${O_PROJECT}/node_modules/.package-lock.json" ]] || oracle_red "not one of the project's two npm lockfiles"
  elif [[ "${line}" =~ ${re_reason_file} ]]; then
    oracle_count reason-file
    [[ "${BASH_REMATCH[1]}" == "${O_PROJECT}" && "${BASH_REMATCH[3]}" == "${O_PRE}" ]] || oracle_red "another project or another snapshot"
    [[ " $(sed -n 3p <<< "${O_NODE_FILES}") " == *" ${BASH_REMATCH[2]} "* ]] || oracle_red "before the hook ran, ${BASH_REMATCH[2]} did not differ from the snapshot"
  elif [[ "${line}" =~ ${re_reason_bin} ]]; then
    oracle_count reason-bin
    [[ "${BASH_REMATCH[1]}" == "${O_PROJECT}/node_modules" && "${BASH_REMATCH[3]}" == "${O_PRE}" ]] || oracle_red "another directory or another snapshot"
    grep -qxF -- "bin ${BASH_REMATCH[2]}" <<< "${O_TREE}" || oracle_red "before the hook ran, .bin did not list that entry, or the snapshot did"
  elif [[ "${line}" =~ ${re_reason_package} ]]; then
    oracle_count reason-package
    [[ "${BASH_REMATCH[1]}" == "${O_PROJECT}/node_modules" && "${BASH_REMATCH[2]}" == "${BASH_REMATCH[1]}"/* && "${BASH_REMATCH[3]}" == "${O_PRE}" ]] || oracle_red "another directory or another snapshot"
    grep -qxF -- "package ${BASH_REMATCH[2]}" <<< "${O_TREE}" || oracle_red "before the hook ran, node_modules did not list that file, or the snapshot did"
  elif [[ "${line}" =~ ${re_reason_newer} ]]; then
    oracle_count reason-newer
    [[ "${BASH_REMATCH[2]}" == "${O_PRE}" ]] || oracle_red "another snapshot"
    grep -qxF -- "newer ${BASH_REMATCH[1]}" <<< "${O_TREE}" || oracle_red "before the hook ran, that path was not newer than the snapshot"
  elif [[ "${line}" =~ ${re_kept_files} ]]; then
    oracle_count kept-files
    [[ "${BASH_REMATCH[2]}" == "${O_PROJECT}" && "${BASH_REMATCH[3]}" == "${O_PRE}" ]] || oracle_red "another project or another snapshot"
    [[ "${O_NODE_FILES}" == "${BASH_REMATCH[1]}"$'\n'"same"$'\n' || "${O_NODE_FILES}" == "${BASH_REMATCH[1]}"$'\n'"same" ]] || oracle_red "before the hook ran this file read: ${O_NODE_FILES//$'\n'/ -> }"
  elif [[ "${line}" =~ ${re_kept_bins} ]]; then
    oracle_count kept-bins
    [[ "${BASH_REMATCH[2]}" == "${O_PRE}" && "${BASH_REMATCH[1]}" == "${O_PROJECT}/node_modules" ]] || oracle_red "another snapshot or another directory"
    [[ -z "$({ ls "${BASH_REMATCH[1]}/.bin/" 2>/dev/null || true; } | sort | comm -13 "${O_HOME}/snapshots/${O_PRE}_bins.list" - 2>&1)" ]] || oracle_red ".bin lists an entry the snapshot lacks, or the snapshot has no list"
  elif [[ "${line}" =~ ${re_kept_packages} ]]; then
    oracle_count kept-packages
    [[ "${BASH_REMATCH[2]}" == "${O_PRE}" && "${BASH_REMATCH[1]}" == "${O_PROJECT}/node_modules" ]] || oracle_red "another snapshot or another directory"
    if [[ ! -f "${O_HOME}/snapshots/${O_PRE}_packages.list" ]]; then
      oracle_red "the snapshot has no list of package.json files"
    else
      local lacking
      lacking=$(oracle_packages_lacking "${BASH_REMATCH[1]}" "${O_HOME}/snapshots/${O_PRE}_packages.list")
      [[ -z "${lacking}" ]] || oracle_red "node_modules holds a package.json the snapshot lacks: ${lacking//$'\n'/ }"
    fi
  elif [[ "${line}" =~ ${re_kept_newer} ]]; then
    oracle_count kept-not-newer
    [[ "${BASH_REMATCH[2]}" == "${O_PRE}" ]] || oracle_red "another snapshot"
    [[ -e "${BASH_REMATCH[1]}" && -f "${O_HOME}/snapshots/${O_PRE}_meta.json" && -z "$(find -H "${BASH_REMATCH[1]}" -prune -newer "${O_HOME}/snapshots/${O_PRE}_meta.json" 2>/dev/null)" ]] || oracle_red "it is newer than the snapshot, or one of the two is missing"
  elif [[ "${line}" =~ ${re_kept} ]]; then
    oracle_count kept
    local kp="${BASH_REMATCH[1]}"
    [[ "${kp}" == "${O_PROJECT}/node_modules" ]] || oracle_red "kept names a path other than the project's node_modules"
    [[ -e "${kp}" || -L "${kp}" ]] || oracle_red "the path is gone"
    oracle_is_reason "${O_PREV}" && oracle_red "kept, right after a reason to remove it"
    # Before the hook ran, every check of the install showed no write.
    [[ "${O_TRACE}" != present ]] || oracle_red "kept, but before the hook ran the install trace was present"
    [[ "$(sed -n 2p <<< "${O_NODE_FILES}")" == same ]] || oracle_red "kept, but before the hook ran a node file differed from the snapshot: ${O_NODE_FILES//$'\n'/ -> }"
    [[ -z "${O_TREE}" ]] || oracle_red "kept, but before the hook ran node_modules showed a write: ${O_TREE//$'\n'/ | }"
    # The form is the line and the checks that follow it, in this order.
    O_KEPT_EXPECT="link trace kept-files kept-packages kept-bins lockfile kept-not-newer"
    [[ -L "${kp}" ]] || O_KEPT_EXPECT="${O_KEPT_EXPECT#link }"
  elif [[ "${line}" =~ ${re_trace_none} ]]; then
    oracle_count trace-none
    [[ "${O_TRACE}" == none && "${BASH_REMATCH[1]}" == "${O_PROJECT}" ]] || oracle_red "the trace this file read before the hook is '${O_TRACE}' in ${O_PROJECT}"
  elif [[ "${line}" =~ ${re_trace_gone} ]]; then
    oracle_count trace-baseline-gone
    [[ "${O_TRACE}" == gone && "${BASH_REMATCH[1]}" == "${O_PROJECT}" ]] || oracle_red "the trace this file read before the hook is '${O_TRACE}'"
  elif [[ "${line}" == 'the pending state of this command names no install-trace baseline' ]]; then
    oracle_count trace-no-baseline
    [[ "${O_TRACE}" == unset ]] || oracle_red "the trace this file read before the hook is '${O_TRACE}'"
  elif [[ "${line}" =~ ${re_skip_added} ]]; then
    oracle_count rebuild-skipped-added
    local sk_fact="${BASH_REMATCH[1]}"
    oracle_inert_holds added
    [[ "$(oracle_rebuild_calls)" == 0 ]] || oracle_red "the hook ran npm rebuild"
    oracle_skip_fact "${sk_fact}"
  elif [[ "${line}" =~ ${re_ran_added} ]]; then
    oracle_count rebuild-ran-added
    oracle_inert_holds added
    grep -q "^rebuild.*"$'\t'"rc=${BASH_REMATCH[1]}\$" "${O_NPM_LOG}" 2>/dev/null || oracle_red "no npm rebuild with that exit status was run"
  elif [[ "${line}" =~ ${re_skip} ]]; then
    oracle_count rebuild-skipped
    local sp_fact="${BASH_REMATCH[1]}"
    oracle_after_asked_line
    [[ "$(oracle_rebuild_calls)" == 0 ]] || oracle_red "the hook ran npm rebuild"
    oracle_skip_fact "${sp_fact}"
  elif [[ "${line}" =~ ${re_ran} ]]; then
    oracle_count rebuild-ran
    oracle_after_asked_line
    grep -q "^rebuild.*"$'\t'"rc=${BASH_REMATCH[1]}\$" "${O_NPM_LOG}" 2>/dev/null || oracle_red "no npm rebuild with that exit status was run"
  elif [[ "${line}" == 'safedeps added --ignore-scripts to this install' ]]; then
    oracle_inert_line inert-added added
  elif [[ "${line}" == 'safedeps asked for --ignore-scripts on this install; the command this hook received is not the one safedeps wrote' ]]; then
    oracle_inert_line inert-asked asked
  elif [[ "${line}" == 'safedeps did not add --ignore-scripts to this install' ]]; then
    oracle_inert_line inert-none none
  elif [[ "${line}" == "safedeps could not read where npm keeps the --ignore-scripts in the command safedeps wrote, so the install's own scripts may have run" ]]; then
    # Said only right after an "added" or "asked" line, from a record that
    # states the warning.
    oracle_count inert-unread
    case "${O_PREV}" in
      'safedeps added --ignore-scripts to this install'*|'safedeps asked for --ignore-scripts on this install; the command this hook received is not the one safedeps wrote') ;;
      *) oracle_red "the unread warning follows no line that says safedeps added or asked for --ignore-scripts" ;;
    esac
    [[ "$(python3 "${ORACLE_READ}" unread "${O_META:-${O_CALL}/no-record}" 2>/dev/null)" == 1 ]] \
      || oracle_red "the unread warning, and the pre-guard's record does not state ignore_scripts_unread true: ${O_META:-no record}"
  elif [[ "${line}" =~ ${re_file_absent} ]]; then
    oracle_count file-line-absent; O_SAW_DETAILS=1
    [[ "${BASH_REMATCH[1]}" == "Details log" && "${O_BLOCK}" != confirm ]] || oracle_red "this file line does not belong in this message"
    [[ ! -f "${BASH_REMATCH[2]}" ]] || oracle_red "it is a file"
  elif [[ "${line}" =~ ${re_file} ]]; then
    oracle_count file-line; O_SAW_DETAILS=1
    [[ "${BASH_REMATCH[1]}" == "Details log" && "${O_BLOCK}" != confirm ]] || oracle_red "this file line does not belong in this message"
    [[ "${BASH_REMATCH[2]}" == "${O_HOME}/reorg.log" && -f "${BASH_REMATCH[2]}" ]] || oracle_red "no such file, or not the reorg log"
  else
    oracle_path_fact "${line}" || rc=$?
    if [[ ${rc} -eq 2 ]]; then
      oracle_red "a line outside the grammar"
    elif [[ ${rc} -ne 0 ]]; then
      oracle_red "the stated fact does not hold on disk"
    else
      oracle_count "path-${O_FACT_KIND}"
    fi
  fi
}

oracle_dir_hash() {
  if command -v md5sum >/dev/null 2>&1; then printf '%s' "$1" | md5sum | cut -d' ' -f1
  elif command -v md5 >/dev/null 2>&1; then md5 -q -s "$1"
  else printf '%s' "$1" | cksum | cut -d' ' -f1; fi
}

oracle_reset() {
  O_BLOCK="" O_HEAD="" O_SNAP="" O_SAW_INERT=0 O_SAW_DETAILS=0 O_SAW_NOTHING=0 O_CHANGED=0 O_SKIP=0
  O_JOURNAL_PROJECT="" O_JOURNAL_LINES="" O_JOURNAL_ID="" O_JOURNAL_HEAD="" O_SAW_OWNER=0 O_SECTION="" O_PREV="" O_LINE=""
  O_KEPT_EXPECT="" O_STEP_PATHS="" O_SAW_JNM=0 O_BODY="" O_REASONS="" O_REFUSED="" O_JFIELDS="" O_JREASONS=""
  O_EXPECT="" O_ALL_LINES="" O_INERT_EXPECTED=0 O_VERDICT=""
}

# One line of the kept form's sequence: after `kept`, the next lines are its
# checks in order, and nothing else.
oracle_kept_step() {
  local want token
  [[ -n "${O_KEPT_EXPECT}" ]] || return 0
  want="${O_KEPT_EXPECT%% *}"
  token=$(oracle_kept_token "$1")
  O_LINE="$1"
  if [[ "${token}" != "${want}" ]]; then
    oracle_red "kept is not followed by its check lines in order (expected ${want})"
    O_KEPT_EXPECT=""
  elif [[ "${O_KEPT_EXPECT}" == *" "* ]]; then
    O_KEPT_EXPECT="${O_KEPT_EXPECT#* }"
  else
    O_KEPT_EXPECT=""
  fi
}

# Reads the lines of a message: each through the grammar, then into what the
# reorg.log entries must hold.
oracle_read_lines() {
  local line skip
  while IFS= read -r line; do
    skip="${O_SKIP}"
    oracle_kept_step "${line}"
    oracle_line "${line}"
    oracle_collect "${line}" "${skip}"
    [[ -z "${line}" ]] || O_PREV="${line}"
  done <<< "$1"
  oracle_block_end
}

# oracle_record_gone <consumed record or empty> <its path in the home> <json|text>:
# a record of the pre-guard the hook consumed that names no snapshot, whose
# snapshot has no meta file, or that is not one JSON object. The hook used to
# end there with nothing said (bamdori r23), so the install was never judged,
# or, for the last, die under set -e on every call of the command for 24
# hours. It now says so once in advisory.log, whether or not a message
# follows, and the backstop judges the command. The record, the id and the
# meta are read in Python, not with the hook's jq, cat and -f. A legacy
# current_snapshot_id is text, read as `$(cat)` reads it.
oracle_record_gone() {
  local snap meta n=0 want a size form what
  O_CONSUMED="$1" O_GONE=0 O_EMPTY=0 O_UNREAD=0
  [[ -n "$1" ]] || return 0
  if [[ "$3" == json ]] && ! python3 "${ORACLE_READ}" object "$1"; then
    O_UNREAD=1 form=log-record-unread what="a record that is not one JSON object"
    want="post-verify: the pre-guard's record $2 is not one JSON object; this hook set the record aside"
  else
    if [[ "$3" == text ]]; then
      snap=$(python3 -c 'import sys; sys.stdout.write(open(sys.argv[1], "rb").read().decode().rstrip("\n"))' "$1" 2>/dev/null)
    else
      snap=$(python3 "${ORACLE_READ}" string "$1" snapshot_id 2>/dev/null)
    fi
    if [[ -z "${snap}" ]]; then
      O_EMPTY=1 form=log-record-empty what="a record that names no snapshot"
      want="post-verify: the pre-guard's record $2 names no snapshot; this hook set the record aside, and the command goes to the command-independent backstop"
    else
      meta="${O_HOME}/snapshots/${snap}_meta.json"
      python3 -c 'import os, sys; sys.exit(0 if os.path.isfile(sys.argv[1]) else 1)' "${meta}" && return 0
      O_GONE=1 form=log-record-gone what="a pending state whose snapshot has no meta file"
      want="post-verify: the pre-guard's record $2 names the snapshot ${snap}, and ${meta} is not a file; this hook set the record aside, and the command goes to the command-independent backstop"
    fi
  fi
  size=$(cat "${O_CALL}/advisory.size" 2>/dev/null); size="${size:-0}"
  while IFS=$'\t' read -r _ a; do
    [[ "${a}" == "${want}" ]] && n=$(( n + 1 ))
  done < <(tail -c +"$(( size + 1 ))" "${O_HOME}/advisory.log" 2>/dev/null)
  O_LINE="advisory.log: ${want}"
  if [[ "${n}" == 1 ]]; then
    oracle_count "${form}"
  else
    oracle_red "${what} was consumed, and advisory.log names it ${n} times, not once"
  fi
}
# The backstop's four heads: one says no record of the command was found, and
# none was consumed; the others say one was, and its snapshot has no meta file,
# or it names no snapshot, or it is not one JSON object.
oracle_record_none() {
  [[ -z "${O_CONSUMED}" ]] || oracle_red "the head says no record was found, and the hook consumed ${O_CONSUMED##*/}"
}
oracle_record_gone_head() {
  [[ "${O_GONE}" == 1 ]] || oracle_red "the head says the record's snapshot has no meta file, and the hook consumed no such record"
}
oracle_record_empty_head() {
  [[ "${O_EMPTY}" == 1 ]] || oracle_red "the head says the record names no snapshot, and the hook consumed no such record"
}
oracle_record_unread_head() {
  [[ "${O_UNREAD}" == 1 ]] || oracle_red "the head says the record is not one JSON object, and the hook consumed no such record"
}

# oracle_message <call dir> <payload> <hook stdout>: reads every line.
oracle_message() {
  local call="$1" payload="$2" out="$3" message line file consumed="" size now project
  O_HOME="${SAFEDEPS_HOME:-${HOME}/.safedeps}"
  O_CALL="${call}"
  for file in "${call}/pending"/*.json; do
    [[ -f "${file}" && ! -e "${O_HOME}/pending/${file##*/}" ]] || continue
    consumed="${file}"
    break
  done
  if [[ -n "${consumed}" ]]; then
    oracle_record_gone "${consumed}" "${O_HOME}/pending/${consumed##*/}" json
  else
    oracle_record_gone ""
  fi
  # Which call this is, read from the hook input in Python, and whose record
  # the hook consumed, read from what the record holds. A record is the
  # pre-guard's for one call, so a call that names a tool_use_id consumes only
  # a record that holds it, and a call that names none only a record that
  # holds none. Two overlapping calls of one command each took the other's
  # record, and the oracle, reading the record each took, agreed with both
  # (bamdori r19 X1). A record that is not one JSON object holds nothing to
  # compare.
  printf '%s' "${payload}" > "${call}/payload.json"
  O_CALL_ID=$(python3 "${ORACLE_READ}" call "${call}/payload.json" 2>/dev/null) || O_CALL_ID=""
  if [[ -n "${consumed}" && "${O_UNREAD}" != 1 ]]; then
    local held
    held=$(python3 "${ORACLE_READ}" string "${consumed}" tool_use_id 2>/dev/null) || held=""
    if [[ "${held}" != "${O_CALL_ID}" ]]; then
      O_LINE="record ${consumed##*/}"
      oracle_red "the hook consumed the record of the call '${held}', and this call is '${O_CALL_ID}'"
    fi
  fi
  # The records a pre-#5 pre-guard left are no call's, and none is read.
  for file in current_state current_snapshot_id; do
    if [[ -f "${call}/legacy/${file}" && ! -e "${O_HOME}/${file}" ]]; then
      O_LINE="${O_HOME}/${file}"
      oracle_red "the hook consumed a record a pre-#5 pre-guard left, which belongs to no call"
    fi
  done
  # A call that printed nothing appended nothing to reorg.log. The post hook
  # writes an entry in four places (a rollback, a refused step, the confirm
  # warnings, an unfinished rollback's report), and each of them prints a
  # message, so an entry from a quiet call is one nobody was told about.
  if [[ -z "${out}" ]]; then
    size=$(cat "${call}/reorg.size" 2>/dev/null); size="${size:-0}"
    now=$(wc -c < "${O_HOME}/reorg.log" 2>/dev/null | tr -d ' '); now="${now:-0}"
    [[ "${now}" == "${size}" ]] && { [[ "${ORACLE_FAILED}" == 0 ]]; return; }
    O_LINE=$(tail -c +"$(( size + 1 ))" "${O_HOME}/reorg.log" 2>/dev/null | head -1)
    oracle_red "reorg.log grew by $(( now - size )) bytes in a call that printed no message"
    return 1
  fi
  O_DIRECT=0 O_RECORD_UNREAD=0
  [[ ! -e "${call}/record-unread" ]] || O_RECORD_UNREAD=1
  O_NPM_LOG="${call}/npm.log"
  O_PAYLOAD="${payload}"
  O_CMD=$(jq -r '.tool_input.command // empty' <<< "${payload}")
  O_PROJECT=$(jq -r '.cwd // empty' <<< "${payload}")
  O_PROJECT=$(oracle_phys "${O_PROJECT}")
  O_PRE="" O_META="" O_TRACE="unread" O_NODE_FILES="" O_TREE="" O_DIR_HASH=""
  if [[ -n "${consumed}" && "${O_UNREAD}" != 1 ]]; then
    # The record's fields count only as strings, as the hook reads them; read
    # in Python, not with the hook's jq.
    O_PRE=$(python3 "${ORACLE_READ}" string "${consumed}" snapshot_id 2>/dev/null) || O_PRE=""
    # A record with no project_dir is judged in the directory the payload
    # names, and with that directory's hash, as the hook does.
    project=$(python3 "${ORACLE_READ}" string "${consumed}" project_dir 2>/dev/null) || project=""
    O_META="${O_HOME}/snapshots/${O_PRE}_meta.json"
    O_TRACE=$(cat "${consumed}.trace")
    O_NODE_FILES=$(cat "${consumed}.nodefiles")
    O_TREE=$(cat "${consumed}.tree")
    [[ -z "${project}" ]] || O_PROJECT="${project}"
    # A snapshot with no meta file is not one the backstop restores from or
    # compares with, so the call has no snapshot from before the command.
    [[ "${O_GONE}" != 1 ]] || O_PRE=""
  fi
  # The hash that picks the project's confirmed snapshot is the project's own,
  # never the record's dir_hash (bamdori J: a record naming X with Z's hash
  # restored Z's snapshot into X, and this file, reading the record's hash
  # too, agreed). Computed in Python, not with the hook's md5 tools.
  O_DIR_HASH=$(python3 -c 'import hashlib, sys; print(hashlib.md5(sys.argv[1].encode("utf-8", "surrogateescape")).hexdigest())' "${O_PROJECT}")
  oracle_reset
  oracle_verdict
  # SAFEDEPS_ORACLE_DUMP=<file> keeps every message the suite read, for a
  # person to read too.
  [[ -z "${SAFEDEPS_ORACLE_DUMP:-}" ]] || { printf -- '--- %s\n' "${O_CMD}"; jq -r '.systemMessage // empty' <<< "${out}" 2>/dev/null; } >> "${SAFEDEPS_ORACLE_DUMP}"
  if ! message=$(jq -er '.systemMessage' <<< "${out}" 2>/dev/null) || [[ "$(jq -r 'keys | join(",")' <<< "${out}" 2>/dev/null)" != systemMessage ]]; then
    O_LINE="${out:0:200}"; oracle_red "the hook's stdout is not one object with a systemMessage"
    return 1
  fi
  oracle_read_lines "${message}"
  oracle_check_logs
  [[ "${ORACLE_FAILED}" == 0 ]]
}

# oracle_direct <meta file> <hook input> <lines>: lines a fact function printed
# when a row called it directly, for the facts no hook run in this suite
# reaches. They are read as the lines of a confirm block, with no reorg.log.
oracle_direct() {
  local line
  O_CALL="${ORACLE_DIR}" O_DIRECT=1 O_RECORD_UNREAD=0 O_CALL_ID="" O_CONSUMED="" O_GONE=0 O_EMPTY=0 O_UNREAD=0 O_HOME="${SAFEDEPS_HOME:-${HOME}/.safedeps}" O_NPM_LOG=/dev/null
  O_META="$1" O_PAYLOAD="$2" O_CMD=$(jq -r '.tool_input.command // empty' <<< "$2") O_PROJECT="" O_PRE="" O_TRACE="unread" O_NODE_FILES="" O_TREE="" O_DIR_HASH=""
  oracle_reset
  oracle_verdict
  O_BLOCK=confirm
  oracle_read_lines "$3"
  O_BLOCK=""
  [[ "${ORACLE_FAILED}" == 0 ]]
}

# The form table: every form with the number of lines that matched it. A form
# no line matched fails the run; the effect gate's prose is counted, may be
# zero, and fails the run above the most lines its row allows.
oracle_table() {
  local form count entry missing="" over="" cap
  printf '# report forms (lines read by the oracle, per form)\n'
  for form in ${ORACLE_FORMS}; do
    count=$(grep -cxF -- "${form}" "${ORACLE_DIR}/forms.log" || true)
    printf '#   %-26s %s\n' "${form}" "${count}"
    [[ "${count}" != 0 ]] || missing+=" ${form}"
  done
  printf '# effect-gate prose, out of this grammar (owned by a follow-up plan), by exact prefix: lines / most allowed\n'
  for entry in "${ORACLE_PROSE[@]}"; do
    count=$(grep -cxF -- "${entry%%|*}" "${ORACLE_DIR}/forms.log" || true)
    cap=$(oracle_prose_field "${entry}" 3)
    printf '#   %-26s %s / %s\n' "${entry%%|*}" "${count}" "${cap}"
    (( count <= cap )) || over+=" ${entry%%|*}"
  done
  [[ -z "${missing}" ]] || { printf 'not ok - report oracle: no line of the suite matched the form(s):%s\n' "${missing}" >&2; return 1; }
  [[ -z "${over}" ]] || { printf 'not ok - report oracle: more lines of effect-gate prose than this suite shows:%s\n' "${over}" >&2; return 1; }
}
