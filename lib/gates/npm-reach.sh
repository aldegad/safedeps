#!/usr/bin/env bash
# Whether a root npm file of a project is a link that leads out of it. The
# rebuild after a verified inert install -- the one place safedeps still runs
# npm itself -- runs only where this answers nothing. A skipped rebuild reports
# its answer as the reason, never as a place to run npm, and a silence from it
# is not a promise.
#
# npm reads and writes package.json, the lockfiles and node_modules at the root
# and follows a link among them (measured: npm ci emptied whatever node_modules
# resolved to, and a fallback npm install saved a lockfile through a link). A
# rebuild through such a link runs install scripts in another checkout's tree,
# which this install neither wrote nor verified. Some worktree layouts link
# node_modules to another checkout's, so this is an ordinary case.
#
# The other ways npm reaches past a directory are answered elsewhere, each by
# the thing that can see it: `--prefix` stops the walk up to an enclosing
# project, and the whole-tree check before the rebuild (npm_rebuild_vouched in
# scripts/safedeps-post-verify.sh) asks npm which directories it would rebuild
# and lets only declared workspace members through.

# safedeps_link_target <path>: prints where the link <path> leads, as a
# physical path. readlink alone prints the link's own text, and a relative one
# ("../main/node_modules") does not resolve from the reader's directory, so a
# message naming it would name the wrong place.
safedeps_link_target() {
  local path="$1" raw dir

  raw=$(readlink "${path}" 2>/dev/null) || { printf 'an unreadable target'; return 0; }
  [[ "${raw}" == /* ]] || raw="$(dirname "${path}")/${raw}"
  if [[ -d "${raw}" ]] && dir=$(cd -P "${raw}" 2>/dev/null && pwd -P); then
    printf '%s' "${dir}"
  elif dir=$(cd -P "$(dirname "${raw}")" 2>/dev/null && pwd -P); then
    printf '%s/%s' "${dir}" "$(basename "${raw}")"
  else
    printf '%s' "${raw}"
  fi
}

# safedeps_npm_reach_blocker <dir>: prints which root npm file of <dir> is a
# link out of it (or that <dir> cannot be resolved), or nothing. The answer
# goes into a message as the reason, so it states only what was read from
# disk. What npm would do with that fact is the reasoning in this header,
# never part of the answer: an answer that carried a prediction ("npm would
# work in an enclosing project", where a real npm stayed put) was wrong.
safedeps_npm_reach_blocker() {
  local dir="$1" name

  if ! (cd -P "${dir}" 2>/dev/null); then
    printf 'the directory %s cannot be resolved' "${dir}"
    return 0
  fi
  for name in package.json package-lock.json npm-shrinkwrap.json node_modules; do
    if [[ -L "${dir}/${name}" ]]; then
      printf '%s/%s is a symbolic link to %s' "${dir}" "${name}" "$(safedeps_link_target "${dir}/${name}")"
      return 0
    fi
  done
}
