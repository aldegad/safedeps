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
# The effect gate's own warnings are prose, owned by a follow-up plan, and
# their bytes are not checked here. They are listed in ORACLE_PROSE by exact
# prefix and counted in the table, so the hole is a named one with a size.
#
# Scripts that change a line or add one change the form here in the same
# commit: scripts/test/report-mutations.sh turns nine such changes into
# failures of this file.

ORACLE_DIR=""
ORACLE_FAILED=0

# Forms the suite must show at least once.
ORACLE_FORMS="
head-rollback head-backstop-rollback head-backstop-none head-confirm head-journal-gone head-journal-stopped
snapshot-confirmed snapshot-pre snapshot-journal
restored not-restored-differs not-restored-absent removed not-removed
refused-restore-link refused-removal-link refused-unresolved
path-exists path-absent path-link workspaces-key changed-nothing
kept kept-files kept-packages kept-bins kept-not-newer
trace-none trace-baseline-gone trace-no-baseline
inert-added inert-asked inert-carried inert-none
rebuild-skipped-added rebuild-ran-added rebuild-skipped rebuild-ran
skip-fact-link skip-fact-unresolved skip-fact-trace
backstop-no-confirmed backstop-no-meta
journal owner-not-running owner-zombie owner-stopped owner-later owner-no-pid owner-no-start owner-bad-start owner-bad-opened
journal-differs journal-gone journal-extra journal-no-list
file-line file-line-absent
"

# The effect gate's prose, by the exact prefix each sentence starts with.
ORACLE_PROSE=(
  "prose-rebuild-not-run|npm rebuild was not run: "
  "prose-scripts-not-run|install scripts were not run in "
  "prose-baseline-not-moved|safedeps verified this install but could not record the result as the new rollback baseline ("
  "prose-bytes-unread|safedeps could not read which bytes this install brought into "
  "prose-fetch-unknown|safedeps could not tell where npm fetched the bytes this install brought into "
  "prose-record-failed|safedeps could not record the bytes this install fetched from a registry that is not the public npm registry ("
  "prose-fetched-elsewhere|this install fetched packages from a registry that is not the public npm registry ("
)

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
  project=$(jq -r '.project_dir // empty' "${pending}" 2>/dev/null)
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
  local pending="$1" snap project name copy names="" verdict=same
  snap=$(jq -r '.snapshot_id // empty' "${pending}" 2>/dev/null)
  project=$(jq -r '.project_dir // empty' "${pending}" 2>/dev/null)
  for name in package.json package-lock.json npm-shrinkwrap.json pnpm-lock.yaml yarn.lock bun.lock bun.lockb; do
    copy="${SAFEDEPS_HOME:-${HOME}/.safedeps}/snapshots/${snap}_${name}"
    if [[ -f "${copy}" ]]; then
      names+="${names:+, }${name}"
      cmp -s "${copy}" "${project}/${name}" || verdict=differs
    elif [[ -f "${copy}.missing" ]]; then
      names+="${names:+, }${name}"
      [[ ! -e "${project}/${name}" && ! -L "${project}/${name}" ]] || verdict=differs
    fi
  done
  printf '%s\n%s\n' "${names}" "${verdict}"
}

# oracle_before <call dir>: notes what the hook is about to consume.
oracle_before() {
  local call="$1" home="${SAFEDEPS_HOME:-${HOME}/.safedeps}" file id
  mkdir -p "${call}/pending" "${call}/journal"
  for file in "${home}/pending"/*.json; do
    [[ -f "${file}" ]] || continue
    cp "${file}" "${call}/pending/${file##*/}"
    oracle_trace_state "${file}" > "${call}/pending/${file##*/}.trace"
    oracle_node_files_state "${file}" > "${call}/pending/${file##*/}.nodefiles"
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

oracle_inert_holds() {
  local asked=false carried=false
  [[ -n "${O_META}" && "$(jq -r '.ignore_scripts_injected == true' "${O_META}" 2>/dev/null)" == true ]] && asked=true
  [[ "${O_CMD}" == *--ignore-scripts* ]] && carried=true
  [[ "$1" == "${asked}:${carried}" ]]
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

# What a block must hold once all its lines are read.
oracle_block_end() {
  case "${O_BLOCK}" in
    rollback|backstop-rollback)
      [[ -n "${O_SNAP}" ]] || { O_LINE="${O_HEAD}"; oracle_red "a rollback message with no snapshot line"; }
      [[ "${O_SAW_INERT}" == 1 ]] || { O_LINE="${O_HEAD}"; oracle_red "a rollback message with no --ignore-scripts line"; }
      [[ "${O_SAW_DETAILS}" == 1 ]] || { O_LINE="${O_HEAD}"; oracle_red "a rollback message with no Details log line"; }
      if [[ "${O_CHANGED}" == 0 && "${O_SAW_NOTHING}" != 1 ]]; then
        O_LINE="${O_HEAD}"; oracle_red "no step line and no 'The rollback changed nothing.'"
      fi
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
      ;;
  esac
  O_BLOCK="" O_SNAP="" O_SAW_INERT=0 O_SAW_DETAILS=0 O_SAW_NOTHING=0 O_CHANGED=0 O_SKIP=0
  O_JOURNAL_PROJECT="" O_JOURNAL_LINES="" O_JOURNAL_ID="" O_SAW_OWNER=0 O_SECTION=""
}

# A line of a rollback, a confirm or a backstop block must also be a line of
# the reorg.log entry: the records say the same thing in the same words.
oracle_in_reorg_log() {
  [[ "${O_DIRECT}" == 1 ]] && return 0
  grep -qxF -- "  $1" "${O_HOME}/reorg.log" 2>/dev/null || oracle_red "reorg.log does not carry this line"
}

oracle_line() {
  local line="$1" rc=0 entry prose id
  O_LINE="${line}"

  local re_journal_head='^safedeps: a rollback of (/.+) (did not finish|has not finished)\.$'
  local re_snap_confirmed='^Rollback snapshot: ([^ ,]+), a confirmed snapshot$'
  local re_snap_pre='^Rollback snapshot: ([^ ,]+), taken before this command; no confirmed snapshot names it$'
  local re_snap_plain='^Rollback snapshot: ([^ ,]+)$'
  local re_restored='^restored (/.+)$'
  local re_not_restored_differs='^not restored (/.+): cp exit ([0-9]+); (/.+) differs from the snapshot$'
  local re_not_restored_absent='^not restored (/.+): cp exit ([0-9]+); (/.+) does not exist$'
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
    'safedeps: suspicious dependency change detected after a command the command gate did not recognize. A rollback ran.')
      oracle_block_end; O_BLOCK=backstop-rollback; O_HEAD="${line}"; oracle_count head-backstop-rollback; return 0 ;;
    'safedeps: suspicious dependency change detected after a command the command gate did not recognize. No rollback ran.')
      oracle_block_end; O_BLOCK=backstop-none; O_HEAD="${line}"; oracle_count head-backstop-none; return 0 ;;
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

  # The effect gate's prose, by exact prefix.
  for entry in "${ORACLE_PROSE[@]}"; do
    prose="${entry#*|}"
    if [[ "${line:0:${#prose}}" == "${prose}" ]]; then
      [[ "${O_BLOCK}" != journal && "${O_BLOCK}" != backstop-none ]] || oracle_red "effect-gate prose inside a report that has none"
      oracle_count "${entry%%|*}"
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
      oracle_in_reorg_log "${line}"
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
      oracle_in_reorg_log "${line}"
    elif [[ "${line}" =~ ${re_snap_plain} ]]; then
      oracle_count snapshot-journal
      O_SNAP="${BASH_REMATCH[1]}"
      [[ "$(jq -r '.rollback_snapshot // "unknown"' "${O_CALL}/journal/${O_JOURNAL_ID}.json" 2>/dev/null)" == "${O_SNAP}" ]] || oracle_red "the journal entry names another snapshot"
      oracle_in_reorg_log "${line}"
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
      [[ "${BASH_REMATCH[1]}" != "Incident record" ]] || oracle_in_reorg_log "${line}"
    else
      oracle_path_fact "${line}" || rc=$?
      if [[ ${rc} -eq 2 || "${O_SECTION}" != checked ]]; then
        oracle_red "a line outside the grammar"
      elif [[ ${rc} -ne 0 ]]; then
        oracle_red "the stated fact does not hold on disk"
      elif [[ "${O_FACT_PATH}" == "${O_JOURNAL_PROJECT}/node_modules" ]]; then
        oracle_count "path-${O_FACT_KIND}"
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
    oracle_in_reorg_log "${line}"
  elif [[ "${line}" =~ ${re_snap_pre} ]]; then
    oracle_count snapshot-pre; O_SNAP="${BASH_REMATCH[1]}"
    [[ "${O_SNAP}" == "${O_PRE}" ]] || oracle_red "the snapshot the pre-guard took for this command is '${O_PRE}'"
    ! grep -qsxF -- "${O_SNAP}" "${O_HOME}"/confirmed "${O_HOME}"/confirmed_* 2>/dev/null || oracle_red "a confirmed record names this snapshot"
    oracle_in_reorg_log "${line}"
  elif [[ "${line}" == 'The rollback changed nothing.' ]]; then
    oracle_count changed-nothing; O_SAW_NOTHING=1
    [[ "${O_CHANGED}" == 0 ]] || oracle_red "said next to a restored or removed line"
    oracle_in_reorg_log "${line}"
  elif [[ "${line}" =~ ${re_not_restored_differs} ]]; then
    oracle_count not-restored-differs
    [[ "${BASH_REMATCH[1]}" == "${BASH_REMATCH[3]}" ]] || oracle_red "two paths"
    [[ "${BASH_REMATCH[2]}" != 0 ]] || oracle_red "cp exit 0"
    { [[ -e "${BASH_REMATCH[1]}" ]] && ! cmp -s "$(oracle_stored "${O_SNAP}" "${BASH_REMATCH[1]#"${O_PROJECT}/"}")" "${BASH_REMATCH[1]}"; } || oracle_red "the file is gone, or equals the snapshot"
    oracle_in_reorg_log "${line}"
  elif [[ "${line}" =~ ${re_not_restored_absent} ]]; then
    oracle_count not-restored-absent
    [[ "${BASH_REMATCH[1]}" == "${BASH_REMATCH[3]}" ]] || oracle_red "two paths"
    [[ ! -e "${BASH_REMATCH[1]}" && ! -L "${BASH_REMATCH[1]}" ]] || oracle_red "the file exists"
    oracle_in_reorg_log "${line}"
  elif [[ "${line}" =~ ${re_restored} ]]; then
    oracle_count restored; O_CHANGED=1
    cmp -s "$(oracle_stored "${O_SNAP}" "${BASH_REMATCH[1]#"${O_PROJECT}/"}")" "${BASH_REMATCH[1]}" || oracle_red "the file does not equal the snapshot"
    oracle_in_reorg_log "${line}"
  elif [[ "${line}" =~ ${re_not_removed} ]]; then
    oracle_count not-removed
    local nr_path="${BASH_REMATCH[1]}" nr_rc="${BASH_REMATCH[2]}" nr_fact="${BASH_REMATCH[3]}"
    oracle_path_fact "${nr_fact}" || rc=$?
    [[ ${rc} -eq 0 && "${O_FACT_PATH}" == "${nr_path}" && "${O_FACT_KIND}" != absent ]] || oracle_red "the path is gone, or the fact names another path"
    [[ "${nr_rc}" != 0 ]] || oracle_red "rm exit 0"
    oracle_in_reorg_log "${line}"
  elif [[ "${line}" =~ ${re_removed} ]]; then
    oracle_count removed; O_CHANGED=1
    [[ ! -e "${BASH_REMATCH[1]}" && ! -L "${BASH_REMATCH[1]}" ]] || oracle_red "the path is still there"
    oracle_in_reorg_log "${line}"
  elif [[ "${line}" =~ ${re_refused} ]]; then
    local rf_kind="${BASH_REMATCH[1]}" rf_path="${BASH_REMATCH[2]}" rf_fact="${BASH_REMATCH[3]}"
    if [[ "${rf_fact}" =~ ${re_unresolved} ]]; then
      oracle_count refused-unresolved
      ! (cd -P "${BASH_REMATCH[1]}" 2>/dev/null) || oracle_red "the directory resolves"
      [[ "${rf_path}" == "${BASH_REMATCH[1]}"/* ]] || oracle_red "the path is not in that directory"
    else
      oracle_count "refused-${rf_kind}-link"
      oracle_path_fact "${rf_fact}" || rc=$?
      [[ ${rc} -eq 0 && "${O_FACT_KIND}" == link && "${O_FACT_PATH}" == "${rf_path}" ]] || oracle_red "not a link to that place, or the fact names another path"
    fi
    oracle_in_reorg_log "${line}"
  elif [[ "${line}" =~ ${re_wskey} ]]; then
    oracle_count workspaces-key
    jq -e 'type == "object" and has("workspaces")' "${BASH_REMATCH[1]}/package.json" >/dev/null 2>&1 || oracle_red "no workspaces key"
    oracle_in_reorg_log "${line}"
  elif [[ "${line}" =~ ${re_kept_files} ]]; then
    oracle_count kept-files
    [[ "${BASH_REMATCH[2]}" == "${O_PROJECT}" && "${BASH_REMATCH[3]}" == "${O_PRE}" ]] || oracle_red "another project or another snapshot"
    [[ "${O_NODE_FILES}" == "${BASH_REMATCH[1]}"$'\n'"same" ]] || oracle_red "before the hook ran this file read: ${O_NODE_FILES//$'\n'/ -> }"
    oracle_in_reorg_log "${line}"
  elif [[ "${line}" =~ ${re_kept_bins} ]]; then
    oracle_count kept-bins
    [[ "${BASH_REMATCH[2]}" == "${O_PRE}" && "${BASH_REMATCH[1]}" == "${O_PROJECT}/node_modules" ]] || oracle_red "another snapshot or another directory"
    [[ -z "$({ ls "${BASH_REMATCH[1]}/.bin/" 2>/dev/null || true; } | sort | comm -13 "${O_HOME}/snapshots/${O_PRE}_bins.list" - 2>&1)" ]] || oracle_red ".bin lists an entry the snapshot lacks, or the snapshot has no list"
    oracle_in_reorg_log "${line}"
  elif [[ "${line}" =~ ${re_kept_packages} ]]; then
    oracle_count kept-packages
    [[ "${BASH_REMATCH[2]}" == "${O_PRE}" && "${BASH_REMATCH[1]}" == "${O_PROJECT}/node_modules" ]] || oracle_red "another snapshot or another directory"
    [[ -z "$(find "${BASH_REMATCH[1]}" -maxdepth 3 -name package.json 2>/dev/null | sort | comm -13 "${O_HOME}/snapshots/${O_PRE}_packages.list" - 2>&1)" ]] || oracle_red "node_modules lists a package.json the snapshot lacks, or the snapshot has no list"
    oracle_in_reorg_log "${line}"
  elif [[ "${line}" =~ ${re_kept_newer} ]]; then
    oracle_count kept-not-newer
    [[ "${BASH_REMATCH[2]}" == "${O_PRE}" ]] || oracle_red "another snapshot"
    [[ -e "${BASH_REMATCH[1]}" && -f "${O_HOME}/snapshots/${O_PRE}_meta.json" && -z "$(find -H "${BASH_REMATCH[1]}" -prune -newer "${O_HOME}/snapshots/${O_PRE}_meta.json" 2>/dev/null)" ]] || oracle_red "it is newer than the snapshot, or one of the two is missing"
    oracle_in_reorg_log "${line}"
  elif [[ "${line}" =~ ${re_kept} ]]; then
    oracle_count kept
    [[ -e "${BASH_REMATCH[1]}" || -L "${BASH_REMATCH[1]}" ]] || oracle_red "the path is gone"
    oracle_in_reorg_log "${line}"
  elif [[ "${line}" =~ ${re_trace_none} ]]; then
    oracle_count trace-none
    [[ "${O_TRACE}" == none && "${BASH_REMATCH[1]}" == "${O_PROJECT}" ]] || oracle_red "the trace this file read before the hook is '${O_TRACE}' in ${O_PROJECT}"
    oracle_in_reorg_log "${line}"
  elif [[ "${line}" =~ ${re_trace_gone} ]]; then
    oracle_count trace-baseline-gone
    [[ "${O_TRACE}" == gone && "${BASH_REMATCH[1]}" == "${O_PROJECT}" ]] || oracle_red "the trace this file read before the hook is '${O_TRACE}'"
    oracle_in_reorg_log "${line}"
  elif [[ "${line}" == 'the pending state of this command names no install-trace baseline' ]]; then
    oracle_count trace-no-baseline
    [[ "${O_TRACE}" == unset ]] || oracle_red "the trace this file read before the hook is '${O_TRACE}'"
    oracle_in_reorg_log "${line}"
  elif [[ "${line}" =~ ${re_skip_added} ]]; then
    oracle_count rebuild-skipped-added
    local sk_fact="${BASH_REMATCH[1]}"
    oracle_inert_holds true:true || oracle_red "the pre-guard did not ask for --ignore-scripts, or the command this hook received does not carry it"
    [[ "$(oracle_rebuild_calls)" == 0 ]] || oracle_red "the hook ran npm rebuild"
    oracle_skip_fact "${sk_fact}"
    oracle_in_reorg_log "${line}"
  elif [[ "${line}" =~ ${re_ran_added} ]]; then
    oracle_count rebuild-ran-added
    oracle_inert_holds true:true || oracle_red "the pre-guard did not ask for --ignore-scripts, or the command this hook received does not carry it"
    grep -q "^rebuild.*"$'\t'"rc=${BASH_REMATCH[1]}\$" "${O_NPM_LOG}" 2>/dev/null || oracle_red "no npm rebuild with that exit status was run"
    oracle_in_reorg_log "${line}"
  elif [[ "${line}" =~ ${re_skip} ]]; then
    oracle_count rebuild-skipped
    local sp_fact="${BASH_REMATCH[1]}"
    [[ "${O_PREV}" == 'safedeps asked for --ignore-scripts on this install; the command this hook received does not carry it' ]] || oracle_red "not said after the line that the command does not carry --ignore-scripts"
    [[ "$(oracle_rebuild_calls)" == 0 ]] || oracle_red "the hook ran npm rebuild"
    oracle_skip_fact "${sp_fact}"
    oracle_in_reorg_log "${line}"
  elif [[ "${line}" =~ ${re_ran} ]]; then
    oracle_count rebuild-ran
    [[ "${O_PREV}" == 'safedeps asked for --ignore-scripts on this install; the command this hook received does not carry it' ]] || oracle_red "not said after the line that the command does not carry --ignore-scripts"
    grep -q "^rebuild.*"$'\t'"rc=${BASH_REMATCH[1]}\$" "${O_NPM_LOG}" 2>/dev/null || oracle_red "no npm rebuild with that exit status was run"
    oracle_in_reorg_log "${line}"
  elif [[ "${line}" == 'safedeps added --ignore-scripts to this install' ]]; then
    oracle_count inert-added; O_SAW_INERT=1
    oracle_inert_holds true:true || oracle_red "the pre-guard did not ask for it, or the command this hook received does not carry it"
    oracle_in_reorg_log "${line}"
  elif [[ "${line}" == 'safedeps asked for --ignore-scripts on this install; the command this hook received does not carry it' ]]; then
    oracle_count inert-asked; O_SAW_INERT=1
    oracle_inert_holds true:false || oracle_red "the pre-guard did not ask for it, or the command carries it"
    oracle_in_reorg_log "${line}"
  elif [[ "${line}" == 'safedeps did not add --ignore-scripts to this install; the command this hook received carries it' ]]; then
    oracle_count inert-carried; O_SAW_INERT=1
    oracle_inert_holds false:true || oracle_red "the pre-guard asked for it, or the command does not carry it"
    oracle_in_reorg_log "${line}"
  elif [[ "${line}" == 'safedeps did not add --ignore-scripts to this install; the command this hook received does not carry it' ]]; then
    oracle_count inert-none; O_SAW_INERT=1
    oracle_inert_holds false:false || oracle_red "the pre-guard asked for it, or the command carries it"
    oracle_in_reorg_log "${line}"
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
      oracle_in_reorg_log "${line}"
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
}

# oracle_message <call dir> <payload> <hook stdout>: reads every line.
oracle_message() {
  local call="$1" payload="$2" out="$3" message line file consumed=""
  [[ -n "${out}" ]] || return 0
  O_CALL="${call}" O_DIRECT=0
  O_HOME="${SAFEDEPS_HOME:-${HOME}/.safedeps}"
  O_NPM_LOG="${call}/npm.log"
  O_CMD=$(jq -r '.tool_input.command // empty' <<< "${payload}")
  O_PROJECT=$(jq -r '.cwd // empty' <<< "${payload}")
  O_PROJECT=$(oracle_phys "${O_PROJECT}")
  O_PRE="" O_META="" O_TRACE="unread" O_NODE_FILES="" O_DIR_HASH=""
  for file in "${call}/pending"/*.json; do
    [[ -f "${file}" && ! -e "${O_HOME}/pending/${file##*/}" ]] || continue
    consumed="${file}"
    break
  done
  if [[ -n "${consumed}" ]]; then
    O_PRE=$(jq -r '.snapshot_id // empty' "${consumed}")
    O_PROJECT=$(jq -r '.project_dir // empty' "${consumed}")
    O_META="${O_HOME}/snapshots/${O_PRE}_meta.json"
    O_TRACE=$(cat "${consumed}.trace")
    O_NODE_FILES=$(cat "${consumed}.nodefiles")
    O_DIR_HASH=$(jq -r '.dir_hash // empty' "${consumed}")
  fi
  [[ -n "${O_DIR_HASH}" ]] || O_DIR_HASH=$(oracle_dir_hash "${O_PROJECT}")
  oracle_reset
  # SAFEDEPS_ORACLE_DUMP=<file> keeps every message the suite read, for a
  # person to read too.
  [[ -z "${SAFEDEPS_ORACLE_DUMP:-}" ]] || { printf -- '--- %s\n' "${O_CMD}"; jq -r '.systemMessage // empty' <<< "${out}" 2>/dev/null; } >> "${SAFEDEPS_ORACLE_DUMP}"
  if ! message=$(jq -er '.systemMessage' <<< "${out}" 2>/dev/null) || [[ "$(jq -r 'keys | join(",")' <<< "${out}" 2>/dev/null)" != systemMessage ]]; then
    O_LINE="${out:0:200}"; oracle_red "the hook's stdout is not one object with a systemMessage"
    return 1
  fi
  while IFS= read -r line; do
    oracle_line "${line}"
    [[ -z "${line}" ]] || O_PREV="${line}"
  done <<< "${message}"
  oracle_block_end
  [[ "${ORACLE_FAILED}" == 0 ]]
}

# oracle_direct <meta file> <command> <lines>: lines a fact function printed
# when a row called it directly, for the facts no hook run in this suite
# reaches. They are read as the lines of a confirm block, with no reorg.log.
oracle_direct() {
  local line
  O_CALL="${ORACLE_DIR}" O_DIRECT=1 O_HOME="${SAFEDEPS_HOME:-${HOME}/.safedeps}" O_NPM_LOG=/dev/null
  O_META="$1" O_CMD="$2" O_PROJECT="" O_PRE="" O_TRACE="unread" O_NODE_FILES="" O_DIR_HASH=""
  oracle_reset
  O_BLOCK=confirm
  while IFS= read -r line; do
    oracle_line "${line}"
    [[ -z "${line}" ]] || O_PREV="${line}"
  done <<< "$3"
  O_BLOCK=""
  [[ "${ORACLE_FAILED}" == 0 ]]
}

# The form table: every form with the number of lines that matched it. A form
# no line matched fails the run; the effect gate's prose is counted and may be
# zero.
oracle_table() {
  local form count entry missing=""
  printf '# report forms (lines read by the oracle, per form)\n'
  for form in ${ORACLE_FORMS}; do
    count=$(grep -cxF -- "${form}" "${ORACLE_DIR}/forms.log" || true)
    printf '#   %-26s %s\n' "${form}" "${count}"
    [[ "${count}" != 0 ]] || missing+=" ${form}"
  done
  printf '# effect-gate prose, out of this grammar (owned by a follow-up plan), by exact prefix\n'
  for entry in "${ORACLE_PROSE[@]}"; do
    count=$(grep -cxF -- "${entry%%|*}" "${ORACLE_DIR}/forms.log" || true)
    printf '#   %-26s %s\n' "${entry%%|*}" "${count}"
  done
  [[ -z "${missing}" ]] || { printf 'not ok - report oracle: no line of the suite matched the form(s):%s\n' "${missing}" >&2; return 1; }
}
