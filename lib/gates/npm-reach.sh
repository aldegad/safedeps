#!/usr/bin/env bash
# One judgment of whether npm, run in a directory, can reach past it. The
# rebuild after a verified inert install -- the one place safedeps still runs
# npm itself -- runs only where this answers nothing. No message uses it to
# tell the user what to run: it lists the ways it knows, and a silence from it
# is not a promise (a workspace member's bare npm ci reaches the workspace
# root, and a file: dependency's bin links reach its target).
#
# npm reaches past the files it is pointed at in these ways, each measured:
# - it reads and writes package.json, the lockfiles and node_modules at the
#   root and follows a link among them (npm ci empties whatever node_modules
#   resolves to; a fallback npm install saved a lockfile through a link);
# - without a package.json it walks up and works in an enclosing project;
# - npm ci empties the node_modules of every workspace, and a workspace may lie
#   outside the project. Which directories those are is npm's to say, and npm
#   cannot say before the tree is installed, so a project that declares
#   workspaces is answered as one npm may reach past.

# safedeps_npm_reach_blocker <dir>: prints why npm run in <dir> could reach
# past it, or nothing when it cannot.
safedeps_npm_reach_blocker() {
  local dir="$1" name

  if ! (cd -P "${dir}" 2>/dev/null); then
    printf 'the directory %s cannot be resolved' "${dir}"
    return 0
  fi
  for name in package.json package-lock.json npm-shrinkwrap.json node_modules; do
    if [[ -L "${dir}/${name}" ]]; then
      printf '%s/%s is a symbolic link to %s' "${dir}" "${name}" "$(readlink "${dir}/${name}" 2>/dev/null || printf 'an unreadable target')"
      return 0
    fi
  done
  if [[ ! -f "${dir}/package.json" ]]; then
    printf '%s has no package.json, so npm would work in an enclosing project' "${dir}"
    return 0
  fi
  if ! jq -e 'type == "object"' "${dir}/package.json" >/dev/null 2>&1; then
    printf '%s/package.json cannot be read as an object' "${dir}"
    return 0
  fi
  if jq -e 'has("workspaces")' "${dir}/package.json" >/dev/null 2>&1; then
    printf '%s/package.json declares workspaces; npm ci empties every workspace'"'"'s node_modules, and a workspace may lie outside the project' "${dir}"
  fi
}
