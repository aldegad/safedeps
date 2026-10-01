#!/usr/bin/env bash
# safedeps: where npm installs, read the way npm reads it.
#
# A project install does not land in the directory the command starts in. npm
# walks up from there to the nearest directory with a package.json or a
# node_modules, and if a package.json further up declares that directory as one
# of its workspaces, npm installs at that workspace root instead. Both hooks
# need the answer: the pre-guard to choose the directory the effect gate reads,
# and the post-verify hook to know which trees `npm rebuild` would run over.
#
# Read from npm 11.19.0's own source (@npmcli/config loadLocalPrefix and
# @npmcli/map-workspaces) and measured with a real npm in
# scripts/test/lockless-forms.sh:
#
#   - The walk stops at the first directory with a package.json or a
#     node_modules. That is the local prefix.
#   - Every package.json above the local prefix is a candidate root, nearest
#     first. The first one whose `workspaces` names the local prefix wins.
#   - `workspaces` is an array of glob patterns, or an object whose `packages`
#     is one. A pattern names directories that hold a package.json, never one
#     under node_modules, and `*` does not match a name that starts with a dot.
#   - `--workspaces=false` on the command line stops the walk at the local
#     prefix.
#
# Where npm would have to do something this file does not reproduce, the
# answer is `?`, never a guess: a package.json that cannot be read or parsed, a
# `workspaces` value npm would reject, and the glob features left out here
# (negation, braces, extglob). npm skips an unparsable package.json above the
# prefix, so `?` there is stricter than npm. It costs an UNGATED record where
# npm would have been harmless; a guess costs a silent pass.
#
# Sourced on every Bash call through the PreToolUse hook. A parse error here
# takes that hook's npm target resolution down, so edit it in a worktree and
# run `npm test` first. Bash 3.2 compatible.

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

# The directory npm installs into when it runs in <dir>, as a physical path, or
# `?<TAB><why>` when that cannot be decided. <workspaces_off> is `true` when the
# command line turns workspaces off.
safedeps_npm_install_root() {
  local dir="$1" workspaces_off="${2:-false}" prefix probe members
  dir=$(cd "${dir}" 2>/dev/null && pwd -P) || { printf '?\t%s is not a directory npm can run in\n' "$1"; return 0; }
  prefix="${dir}"
  probe="${dir}"
  while :; do
    if [[ -e "${probe}/package.json" || -d "${probe}/node_modules" ]]; then
      prefix="${probe}"
      break
    fi
    if [[ "${probe}" == / ]]; then
      printf '%s\n' "${dir}"
      return 0
    fi
    probe=$(dirname "${probe}")
  done
  if [[ "${workspaces_off}" == true || "${prefix}" == / ]]; then
    printf '%s\n' "${prefix}"
    return 0
  fi
  probe=$(dirname "${prefix}")
  while :; do
    if [[ -e "${probe}/package.json" ]]; then
      members=$(safedeps_npm_workspace_members "${probe}")
      if grep -q '^?' <<< "${members}"; then
        grep -m1 '^?' <<< "${members}"
        return 0
      fi
      if grep -qxF -- "${prefix}" <<< "${members}"; then
        printf '%s\n' "${probe}"
        return 0
      fi
    fi
    [[ "${probe}" != / ]] || break
    probe=$(dirname "${probe}")
  done
  printf '%s\n' "${prefix}"
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
