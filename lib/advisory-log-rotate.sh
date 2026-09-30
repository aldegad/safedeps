#!/usr/bin/env bash
# advisory-log-rotate — THE owner of how much of the advisory log survives.
#
# WHY IT EXISTS. `${SAFEDEPS_HOME}/advisory.log` had no bound at all: safedeps
# appended to it forever and nothing ever rotated it. On a machine that runs
# dependency checks daily this file becomes the largest thing in the state root,
# and an unbounded file there is a disk-exhaustion fault. safedeps of all tools
# must not be the reason a machine stops being able to write.
#
# THE FILE IS TWO CHANNELS MIXED, AND THAT DECIDES THE DESIGN:
#   - EVIDENCE  — `check approve/block/warn`, `re-check revoke`, WARN, ERROR.
#     `sf_ledger_has_approval_provenance` READS these: it is the oracle that
#     tells a real ledger approval from a forged one. Losing a line here
#     silently converts a legitimate approval into a suspected forgery. Tiny,
#     and it grows only when a decision is made.
#   - TRACE     — `INFO` lines, overwhelmingly per-package cache-hit notices.
#     Nothing reads them once the run is over, and they are essentially all of
#     the volume: the file grows in proportion to packages inspected, not to
#     decisions taken.
#
# So rotation here is COMPACTION, not truncation: the whole file is archived
# (gzip, because this content is extremely repetitive), and the live file is
# rewritten with every non-INFO line kept. The oracle keeps its complete
# evidence set, the trace that nobody reads stops accumulating, and the full
# history including that trace is still in the archives.
#
# COPY -> GZIP -> REWRITE IN PLACE, never rename. Appenders hold the file by
# name with `>>`, but a concurrent safedeps process may have resolved the path
# already; renaming the inode out from under it would send its evidence lines
# into the archive instead of the live file. Rewriting in place keeps one inode.
#
# ORDER IS ARCHIVE FIRST. If the process dies between the two halves the archive
# already holds everything, so the worst case is a rotation that must be redone —
# never a window where lines exist in neither file.
#
# ONE ROTATOR AT A TIME. `mkdir` is atomic on every POSIX filesystem, so it is
# the lock. A second process that loses the race does not wait and does not
# rotate: the file is over the threshold by a few kilobytes, the winner is
# already handling it, and blocking a dependency check on a log chore would be
# the worse failure. A lock older than the stale window is reclaimed, so a
# process killed mid-rotation cannot disable rotation forever.

# Rotate once the live file passes this. 64MB: large enough that a normal
# working week never trips it, small enough that the archive step stays quick.
SAFEDEPS_ADVISORY_LOG_MAX_BYTES="${SAFEDEPS_ADVISORY_LOG_MAX_BYTES:-67108864}"
# How many compressed archives survive.
SAFEDEPS_ADVISORY_LOG_KEEP="${SAFEDEPS_ADVISORY_LOG_KEEP:-5}"
# Ceiling on all archives together, independent of the count. Both bounds are
# enforced; whichever bites first wins.
SAFEDEPS_ADVISORY_LOG_ARCHIVE_TOTAL_BYTES="${SAFEDEPS_ADVISORY_LOG_ARCHIVE_TOTAL_BYTES:-536870912}"
# A lock this old belonged to a process that died mid-rotation.
SAFEDEPS_ADVISORY_LOG_LOCK_STALE_SECONDS="${SAFEDEPS_ADVISORY_LOG_LOCK_STALE_SECONDS:-300}"

# Lines the live file KEEPS on compaction. Anchored to the level field the
# writers emit (`[<ts>] INFO <message>`), so it drops the trace channel and
# nothing else. Deliberately expressed as "drop INFO" rather than "keep the
# known evidence verbs": a verb added later is kept by default, and the failure
# direction of a mistake here is a slightly larger file rather than a missing
# approval.
SAFEDEPS_ADVISORY_LOG_TRACE_RE='^\[[^]]*\] INFO '

safedeps_advisory_log_size() {
  local file="$1"
  [[ -f "${file}" ]] || { printf '0\n'; return 0; }
  wc -c < "${file}" 2>/dev/null | tr -d ' \n' || printf '0\n'
}

# Enforce BOTH archive bounds. The only code that removes an archive, so what
# disappears is auditable in one place instead of implied by a shell command
# someone ran once.
safedeps_advisory_log_prune_archives() {
  local file="$1"
  local dir base
  dir="$(dirname "${file}")"
  base="$(basename "${file}")"

  local -a archives=()
  local entry
  # Newest first: the stamp is fixed-width and sortable, so a reverse name sort
  # is a reverse time sort without stat'ing anything.
  while IFS= read -r entry; do
    [[ -n "${entry}" ]] && archives+=("${entry}")
  done < <(find "${dir}" -maxdepth 1 -type f -name "${base}.*.gz" 2>/dev/null | sort -r)

  local index=0 running=0 size
  for entry in "${archives[@]}"; do
    size="$(safedeps_advisory_log_size "${entry}")"
    running=$(( running + size ))
    if (( index >= SAFEDEPS_ADVISORY_LOG_KEEP )); then
      rm -f "${entry}" 2>/dev/null || true
    elif (( index > 0 && running > SAFEDEPS_ADVISORY_LOG_ARCHIVE_TOTAL_BYTES )); then
      # `index > 0` keeps the newest archive whatever its size: a cap that can
      # delete the only surviving history is a cap that loses everything.
      rm -f "${entry}" 2>/dev/null || true
    fi
    index=$(( index + 1 ))
  done
}

safedeps_advisory_log_lock_is_stale() {
  local lock="$1"
  local now age
  now="$(date -u +%s)"
  # BSD and GNU stat disagree on flags; ask both and treat an unreadable mtime as
  # NOT stale. Guessing "stale" would let two rotations run at once, which is the
  # failure this lock exists to prevent.
  #
  # GNU goes first. On Linux `stat -f` means --file-system: it succeeds and
  # prints several lines of filesystem info, so asking BSD first handed that
  # text to the arithmetic below, which died under `set -u` on its first word
  # ("File: unbound variable", measured on ubuntu:24.04). The same order as
  # safedeps_file_mtime. Anything that is still not a number is unreadable.
  age="$(stat -c %Y "${lock}" 2>/dev/null || stat -f %m "${lock}" 2>/dev/null || printf '')"
  [[ "${age}" =~ ^[0-9]+$ ]] || return 1
  (( now - age > SAFEDEPS_ADVISORY_LOG_LOCK_STALE_SECONDS ))
}

# Rotate `$1` if it is over the size bound. Returns 0 whether or not it rotated —
# a dependency check must never fail because a log chore could not run — but
# every refusal and every failure is written to the log itself, so a rotation
# that is not happening is visible rather than assumed.
safedeps_advisory_log_rotate_if_needed() {
  local file="${1:-${SAFEDEPS_ADVISORY_LOG:-}}"
  [[ -n "${file}" && -f "${file}" ]] || return 0

  local size
  size="$(safedeps_advisory_log_size "${file}")"
  [[ "${size}" =~ ^[0-9]+$ ]] || return 0
  (( size < SAFEDEPS_ADVISORY_LOG_MAX_BYTES )) && return 0

  local lock="${file}.rotate.lock"
  if ! mkdir "${lock}" 2>/dev/null; then
    if safedeps_advisory_log_lock_is_stale "${lock}"; then
      rmdir "${lock}" 2>/dev/null || true
      mkdir "${lock}" 2>/dev/null || return 0
    else
      return 0
    fi
  fi
  # shellcheck disable=SC2064  # `lock` must be expanded now, not at trap time.
  trap "rmdir '${lock}' 2>/dev/null || true" RETURN

  local stamp archive tmp kept
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  archive="${file}.${stamp}.gz"

  # 1. Archive everything, trace included. Until this succeeds the live file is
  #    not touched at all.
  if ! gzip -c "${file}" > "${archive}" 2>/dev/null; then
    rm -f "${archive}" 2>/dev/null || true
    printf '[%s] ERROR advisory log rotation failed: could not write %s; the log stays whole and unbounded.\n' \
      "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "${archive}" >> "${file}"
    return 0
  fi

  # 2. Compact in place. Written to a temp file first and moved onto the live
  #    file by `cat >`, NOT `mv`: the redirect truncates and refills one inode,
  #    so a concurrent appender holding this path keeps writing to the file
  #    everyone else reads.
  tmp="$(mktemp "${file}.compact.XXXXXX" 2>/dev/null || printf '')"
  if [[ -z "${tmp}" ]]; then
    printf '[%s] ERROR advisory log rotation incomplete: archived to %s but could not open a temp file to compact; the live log still holds every line.\n' \
      "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "${archive}" >> "${file}"
    return 0
  fi
  grep -Ev "${SAFEDEPS_ADVISORY_LOG_TRACE_RE}" "${file}" > "${tmp}" 2>/dev/null || true
  kept="$(wc -l < "${tmp}" 2>/dev/null | tr -d ' \n')"
  cat "${tmp}" > "${file}"
  rm -f "${tmp}" 2>/dev/null || true

  printf '[%s] WARN advisory log rotated: %s bytes archived to %s; %s evidence line(s) kept live, INFO trace dropped from the live file (still in the archive).\n' \
    "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "${size}" "$(basename "${archive}")" "${kept:-0}" >> "${file}"

  safedeps_advisory_log_prune_archives "${file}"
  return 0
}
