#!/usr/bin/env bash
# safedeps: the files a workspace install writes, for the snapshot.
#
# `npm install x -w packages/a` writes packages/a/package.json as well as the
# root's lockfiles, so a rollback has to restore the member's manifest. This
# file lists the members' manifests for the snapshot to keep, and names the
# snapshot files.
#
# It does NOT decide where an install lands or what `npm rebuild` runs over.
# Both used to be decided here, by reading npm's source and doing the same in
# bash, and both drifted from npm (safedeps/effect-gate-blind-to-lockless-npm-
# installs): the member list resolved a symlinked member to its physical path,
# where npm compares the path its glob found, and the gate climbed to a root npm
# did not. Both questions are now asked of npm (lib/npm/ask.sh). What is left
# here only chooses which files to copy before an install, so reading more
# members than npm would costs a copy, and reading fewer costs a manifest the
# rollback cannot restore. The lockfiles' member keys are read too, so a member
# npm recorded is kept even where the glob below does not find it.
#
# Read from npm 11.19.0's @npmcli/map-workspaces:
#
#   - `workspaces` is an array of glob patterns, or an object whose `packages`
#     is one. A pattern names directories that hold a package.json, never one
#     under node_modules, and `*` does not match a name that starts with a dot.
#
# Where a pattern uses a glob feature left out here (negation, braces,
# extglob), the answer is `?` and the lockfile keys are what remain.
#
# Sourced by both hooks, on every Bash call through the PreToolUse hook. A
# parse error here takes the snapshot of workspace manifests down, so edit it in
# a worktree and run `npm test` first. Bash 3.2 compatible.

# The workspace patterns <root>/package.json declares, one per line, after
# `ok`. `none` when it declares none or there is no package.json, and `?<TAB><why>` when it cannot be read.
safedeps_npm_workspace_patterns() {
  local root="$1" out
  if [[ ! -e "${root}/package.json" ]]; then
    printf 'none\n'
    return 0
  fi
  if [[ ! -r "${root}/package.json" ]]; then
    printf '?\t%s/package.json cannot be read\n' "${root}"
    return 0
  fi
  if ! out=$(jq -r '
      # npm reads `workspaces` only when it is truthy.
      if (.workspaces // false) == false or .workspaces == "" or .workspaces == 0 then "none"
      else
        (if (.workspaces | type) == "object" and ((.workspaces.packages // null) | type) == "array"
         then .workspaces.packages else .workspaces end) as $w
        | if ($w | type) != "array" then "bad"
          elif any($w[]; type != "string" or test("[[:cntrl:]]")) then "bad"
          else "ok", $w[]
          end
      end' "${root}/package.json" 2>/dev/null); then
    printf '?\t%s/package.json is not valid JSON\n' "${root}"
    return 0
  fi
  case "${out}" in
    bad) printf '?\t%s/package.json declares workspaces npm would reject\n' "${root}" ;;
    *) printf '%s\n' "${out}" ;;
  esac
}

# The directories one pattern names under <base>, one per line, each holding a
# package.json. The remaining arguments are the pattern's segments.
safedeps_npm_workspace_expand() {
  local base="$1" seg entry name
  shift
  if [[ $# -eq 0 ]]; then
    [[ -f "${base}/package.json" ]] && printf '%s\n' "${base}"
    return 0
  fi
  seg="$1"
  shift
  case "${seg}" in
    ''|.) safedeps_npm_workspace_expand "${base}" "$@" ;;
    '**')
      # Zero directories, then each subdirectory with `**` still in front. glob
      # does not crawl a symlinked directory here, so neither does this.
      safedeps_npm_workspace_expand "${base}" "$@"
      for entry in "${base}"/*; do
        name="${entry##*/}"
        [[ -d "${entry}" && ! -L "${entry}" && "${name}" != node_modules ]] || continue
        safedeps_npm_workspace_expand "${entry}" '**' "$@"
      done
      ;;
    *'*'*|*'?'*|*'['*)
      for entry in "${base}"/* "${base}"/.*; do
        name="${entry##*/}"
        [[ "${name}" != . && "${name}" != .. && "${name}" != node_modules && -d "${entry}" ]] || continue
        # A wildcard does not match a leading dot unless the pattern spells it.
        [[ "${name}" != .* || "${seg}" == .* ]] || continue
        # shellcheck disable=SC2053  # the pattern is meant to match as a glob
        [[ "${name}" == ${seg} ]] || continue
        safedeps_npm_workspace_expand "${entry}" "$@"
      done
      ;;
    node_modules) return 0 ;;
    *) [[ -d "${base}/${seg}" ]] && safedeps_npm_workspace_expand "${base}/${seg}" "$@" ;;
  esac
  return 0
}

# The workspace members <root> declares, as physical paths, one per line after
# `ok`. `none` when it declares no workspaces, `?<TAB><why>` when it cannot be
# decided.
safedeps_npm_workspace_members() {
  local root="$1" patterns pattern bangs member
  local -a segs=()
  patterns=$(safedeps_npm_workspace_patterns "${root}")
  case "${patterns}" in
    none|'?'*) printf '%s\n' "${patterns}"; return 0 ;;
  esac
  printf 'ok\n'
  {
    while IFS= read -r pattern; do
      bangs="${pattern%%[!!]*}"
      pattern="${pattern#"${bangs}"}"
      if [[ $(( ${#bangs} % 2 )) -eq 1 ]]; then
        printf '?\t%s/package.json excludes workspaces with a negated pattern\n' "${root}"
        continue
      fi
      case "${pattern}" in
        *'{'*|*'}'*|*'('*|*')'*|*'!'*|*'\'*)
          printf '?\t%s/package.json names workspaces with a glob this gate does not read (%s)\n' "${root}" "${pattern}"
          continue
          ;;
      esac
      # npm strips a leading `/` or `./`.
      while [[ "${pattern}" == /* || "${pattern}" == ./* ]]; do
        pattern="${pattern#.}"
        pattern="${pattern#/}"
      done
      IFS=/ read -ra segs <<< "${pattern}"
      safedeps_npm_workspace_expand "${root}" "${segs[@]+"${segs[@]}"}"
    done < <(printf '%s\n' "${patterns}" | tail -n +2)
  } | while IFS= read -r member; do
    case "${member}" in
      '?'*) printf '%s\n' "${member}" ;;
      *) (cd "${member}" 2>/dev/null && pwd -P) || printf '?\tcannot resolve %s\n' "${member}" ;;
    esac
  done | LC_ALL=C sort -u
}

# The file name a snapshot keeps <path> under, for a path relative to the
# project. Snapshots are flat files named `<snapshot id>_<name>`, and a
# workspace member's manifest (`packages/a/package.json`) has a slash in it, so
# `%` and `/` are escaped. A top-level name comes back unchanged, so snapshots
# written before members were kept still read the same. Both hooks name
# snapshot files through this one function, and a disagreement would be a
# restore that silently finds nothing.
safedeps_snapshot_file_name() {
  local name="${1//%/%25}"
  printf '%s' "${name//\//%2F}"
}

# The manifests of <root>'s workspace members, relative to <root>, one per line.
# An `npm install x -w packages/a` writes packages/a/package.json, so a rollback
# needs it. The members come from the root's `workspaces` and, because that can
# be undecidable, also from the lockfiles, which key each member by its path.
safedeps_npm_workspace_manifests() {
  local root="$1" member lockfile
  [[ "$(safedeps_npm_workspace_patterns "${root}")" != none ]] || return 0
  root=$(cd "${root}" 2>/dev/null && pwd -P) || return 0
  {
    safedeps_npm_workspace_members "${root}" | tail -n +2 | grep -v '^?' || true
    for lockfile in "${root}/package-lock.json" "${root}/node_modules/.package-lock.json"; do
      [[ -f "${lockfile}" ]] || continue
      jq -r '(.packages // {}) | keys[] | select(. != "" and (test("(^|/)node_modules/") | not))' \
        "${lockfile}" 2>/dev/null | while IFS= read -r member; do
          printf '%s/%s\n' "${root}" "${member}"
        done
    done
  } | while IFS= read -r member; do
    case "${member}" in
      "${root}"/*) ;;
      *) continue ;;
    esac
    member="${member#"${root}"/}"
    case "/${member}/" in
      */../*|*/./*) continue ;;
    esac
    [[ -f "${root}/${member}/package.json" ]] && printf '%s/package.json\n' "${member}"
  done | LC_ALL=C sort -u
}
