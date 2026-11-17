#!/usr/bin/env bash
# Where the watch may read: a root is classified from the mount table and the
# exclude list before anything under it is opened.
#
# A registered path that looks local can be a network share mounted there (an
# SMB share mounted under ~/Documents/workspace reads like any other project),
# and a symlink can lead into a share or into a place the owner keeps closed.
# So a path is resolved one component at a time, and each component is judged
# by its string against the mount table and the exclude prefixes before it is
# lstat'ed. Nothing at or under a mount point whose filesystem is not on the
# local list is stat'ed, listed or read: such a root is `remote_mount`, a root
# under an exclude prefix is `excluded`, and both are counted, not measured.
# Reading a file first and checking the mount after is the order this file
# exists to prevent.
#
# The mount table is `mount`'s output (macOS: `dev on /p (type, opts)`, Linux:
# `dev on /p type t (opts)`). A table that cannot be read classifies nothing,
# and the caller measures nothing.

# Filesystems the watch reads. Any other type, a network one or one this list
# does not know, is not read.
SAFEDEPS_WATCH_LOCAL_FS=" apfs hfs devfs ext2 ext3 ext4 xfs btrfs zfs tmpfs overlay rootfs lxfs wslfs drvfs f2fs "

SAFEDEPS_WATCH_MOUNT_POINTS=()
SAFEDEPS_WATCH_MOUNT_TYPES=()
SAFEDEPS_WATCH_EXCLUDES=()

# Reads the mount table into the two arrays above.
safedeps_watch_mounts_load() {
  local table line rest opts mp fstype os
  SAFEDEPS_WATCH_MOUNT_POINTS=()
  SAFEDEPS_WATCH_MOUNT_TYPES=()
  table=$(mount 2>/dev/null) || return 1
  [[ -n "${table}" ]] || return 1
  os=$(uname -s)
  while IFS= read -r line; do
    [[ "${line}" == *" on "*" ("* ]] || continue
    rest="${line% (*}"
    if [[ "${os}" == "Linux" ]]; then
      [[ "${rest}" == *" type "* ]] || continue
      fstype="${rest##* type }"
      mp="${rest% type *}"
      mp="${mp#* on }"
    else
      opts="${line##* (}"
      fstype="${opts%%[,)]*}"
      mp="${rest#* on }"
    fi
    [[ "${mp}" == /* && -n "${fstype}" ]] || continue
    SAFEDEPS_WATCH_MOUNT_POINTS+=("${mp}")
    SAFEDEPS_WATCH_MOUNT_TYPES+=("${fstype}")
  done <<< "${table}"
  [[ "${#SAFEDEPS_WATCH_MOUNT_POINTS[@]}" -gt 0 ]]
}

# Reads ${SAFEDEPS_HOME}/watch/exclude: one absolute path prefix a line, `#`
# comments and blank lines skipped. A missing file is no exclusion.
safedeps_watch_excludes_load() {
  local file line
  SAFEDEPS_WATCH_EXCLUDES=()
  file="$(safedeps_watch_dir)/exclude"
  [[ -f "${file}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%%#*}"
    line="${line%"${line##*[![:space:]]}"}"
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -n "${line}" ]] || continue
    [[ "${line}" == /* ]] || return 1
    while [[ "${line}" == */ && "${line}" != / ]]; do line="${line%/}"; done
    SAFEDEPS_WATCH_EXCLUDES+=("${line}")
  done < "${file}"
}

# 0 when PATH is at or under PREFIX, by its string.
safedeps_watch_path_under() {
  [[ "$1" == "$2" || "$2" == / || "$1" == "$2"/* ]]
}

# The type of the deepest mount that holds PATH, by string.
safedeps_watch_fs_type() {
  local path="$1" best="" best_type="" i mp
  for i in "${!SAFEDEPS_WATCH_MOUNT_POINTS[@]}"; do
    mp="${SAFEDEPS_WATCH_MOUNT_POINTS[$i]}"
    if safedeps_watch_path_under "${path}" "${mp}" && [[ "${#mp}" -ge "${#best}" ]]; then
      best="${mp}"
      best_type="${SAFEDEPS_WATCH_MOUNT_TYPES[$i]}"
    fi
  done
  printf '%s\t%s' "${best_type}" "${best}"
}

safedeps_watch_fs_is_local() {
  [[ -n "$1" && "${SAFEDEPS_WATCH_LOCAL_FS}" == *" $1 "* ]]
}

safedeps_watch_excluded_by() {
  local path="$1" p
  for p in "${SAFEDEPS_WATCH_EXCLUDES[@]+${SAFEDEPS_WATCH_EXCLUDES[@]}}"; do
    if safedeps_watch_path_under "${path}" "${p}"; then
      printf '%s' "${p}"
      return 0
    fi
  done
  return 1
}

# Judges PATH (absolute) before anything under it is opened. Prints one line:
#   ok<TAB><resolved path>
#   remote_mount<TAB><mount point><TAB><fs type>
#   excluded<TAB><prefix>
#   unreachable<TAB><reason>
# Each component is judged by string first and lstat'ed only when it is on a
# local filesystem and outside every exclude prefix.
safedeps_watch_classify_root() {
  local path="$1" cur="" rest comp next target hops=0 fs prefix
  if [[ "${path}" != /* ]]; then
    printf 'unreachable\trelative_path\n'
    return 0
  fi
  if prefix=$(safedeps_watch_excluded_by "${path}"); then
    printf 'excluded\t%s\n' "${prefix}"
    return 0
  fi
  rest="${path#/}"
  while :; do
    while [[ "${rest}" == /* ]]; do rest="${rest#/}"; done
    [[ -n "${rest}" ]] || break
    comp="${rest%%/*}"
    if [[ "${rest}" == */* ]]; then rest="${rest#*/}"; else rest=""; fi
    case "${comp}" in
      .) continue ;;
      ..) cur="${cur%/*}"; continue ;;
    esac
    next="${cur}/${comp}"
    if prefix=$(safedeps_watch_excluded_by "${next}"); then
      printf 'excluded\t%s\n' "${prefix}"
      return 0
    fi
    fs=$(safedeps_watch_fs_type "${next}")
    if ! safedeps_watch_fs_is_local "${fs%%$'\t'*}"; then
      printf 'remote_mount\t%s\t%s\n' "${fs#*$'\t'}" "${fs%%$'\t'*}"
      return 0
    fi
    if [[ -L "${next}" ]]; then
      hops=$((hops + 1))
      if [[ "${hops}" -gt 40 ]]; then
        printf 'unreachable\tsymlink_loop\n'
        return 0
      fi
      if ! target=$(readlink "${next}"); then
        printf 'unreachable\tunreadable_link\n'
        return 0
      fi
      if [[ "${target}" == /* ]]; then
        cur=""
        rest="${target#/}${rest:+/${rest}}"
      else
        rest="${target}${rest:+/${rest}}"
      fi
      continue
    fi
    if [[ ! -e "${next}" ]]; then
      printf 'unreachable\tmissing\n'
      return 0
    fi
    cur="${next}"
  done
  [[ -n "${cur}" ]] || cur=/
  if [[ ! -d "${cur}" ]]; then
    printf 'unreachable\tnot_a_directory\n'
    return 0
  fi
  if [[ ! -r "${cur}" || ! -x "${cur}" ]]; then
    printf 'unreachable\tpermission\n'
    return 0
  fi
  printf 'ok\t%s\n' "${cur}"
}

# What strictly under ROOT a walk of ROOT must not enter, one line each:
# `remote_mount<TAB><mount point><TAB><fs type>` for a filesystem the watch does
# not read, `excluded<TAB><prefix><TAB>-` for an exclude prefix. Read from the
# mount table and the exclude file alone, so nothing under them is touched to
# know they are there. The scan reports each one; the walk prunes them.
safedeps_watch_skipped_under() {
  local root="$1" i mp p
  for i in "${!SAFEDEPS_WATCH_MOUNT_POINTS[@]}"; do
    mp="${SAFEDEPS_WATCH_MOUNT_POINTS[$i]}"
    if [[ "${mp}" == "${root}"/* ]] && ! safedeps_watch_fs_is_local "${SAFEDEPS_WATCH_MOUNT_TYPES[$i]}"; then
      printf 'remote_mount\t%s\t%s\n' "${mp}" "${SAFEDEPS_WATCH_MOUNT_TYPES[$i]}"
    fi
  done
  for p in "${SAFEDEPS_WATCH_EXCLUDES[@]+${SAFEDEPS_WATCH_EXCLUDES[@]}}"; do
    [[ "${p}" == "${root}"/* ]] && printf 'excluded\t%s\t-\n' "${p}"
  done
  return 0
}

# The paths alone, for the walk.
safedeps_watch_prunes_under() {
  local class path rest
  while IFS=$'\t' read -r class path rest; do
    printf '%s\n' "${path}"
  done < <(safedeps_watch_skipped_under "$1")
}
