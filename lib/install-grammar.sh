#!/usr/bin/env bash
# safedeps: the install grammar -- which command lines the gates read as a
# package install, defined once.
#
# Every recognizer in scripts/safedeps-pre-guard.sh and
# scripts/safedeps-post-verify.sh reads these definitions. They used to carry
# seven hand-written copies of the verb list, and the copies had drifted:
# `pnpm i` was missing from one, `npm i` from another, and no copy knew npm's
# documented `in`/`isntall` aliases, so an install spelled that way skipped the
# pre-install gate and with it the `--ignore-scripts` rewrite.
#
# The scope rule is the one ARCHITECTURE.md states for the command gate:
# applying a rule the gate already states, at a place that skipped it, is in
# scope; adding a new carrier syntax is not. So this grammar knows each
# manager's own documented aliases, any number of options between a manager and
# its verb, version-suffixed interpreters (`pip3.11`), statement positions the
# shell grammar defines (`(`, `{`, `!`, `then`, `do`, an indented line), and
# the runner commands that fetch and execute a package. It does not know
# argv-passing wrappers such as `sudo`, `timeout`, `nohup` or `xargs`. Those
# stay outside the boundary on purpose, and scripts/test/consumer-forms.sh pins
# them as unjudged.
#
# Sourced on every Bash call through the PreToolUse hook. A parse error here
# takes that hook down, so edit it in a worktree and run `npm test` first.
# Bash 3.2 compatible: no associative arrays, no case modification.
# shellcheck disable=SC2034  # definitions for the files that source this one

# --- vocabulary ---------------------------------------------------------------
# Official aliases, as of 2026-10-01:
#   npm install: add, i, in, ins, inst, insta, instal, isnt, isnta, isntal, isntall
#   npm install-test: it          npm update: u, up, upgrade, udpate
#   npm ci: clean-install, ic, install-clean, isntall-clean
#   npm install-ci-test: cit, clean-install-test, sit
#   npm exec: x                   npm init: create, innit
#   pnpm install: i
#   pnpm update: up, upgrade      pnpm install-test: it
#   bun add: a, bun install: i (from `bun --help`)
#   yarn up (Berry) moves an existing dependency to the given version.
#   dotnet package add: the .NET 10 "noun first" spelling of `dotnet add
#     package`, same arguments (learn.microsoft.com/dotnet/core/tools/dotnet-package-add).
#   dotnet package update [<pkg>[@<ver>]...]: .NET 10, moves a referenced
#     package to <ver>, or to the newest one without it
#     (learn.microsoft.com/dotnet/core/tools/dotnet-package-update).
#
# npm's own spellings are not a fixed list. npm reads its command word with
# lib/utils/cmd-list.js `deref`: a camelCase word is read as dashed
# (`installTest` is `install-test`), then an exact command or alias, then any
# unique abbreviation of a command or an alias (`npm upd`, `npm install-te`,
# `npm exe`). The npm lists below are what deref maps to each command, measured
# from npm 11.19.0 by scripts/measure/npm-verb-spellings.sh, which also checks
# them against the npm on PATH. A dash before a letter is written `-?[xX]`,
# because deref accepts the camelCase form of every dashed spelling. A list
# copied from the documented aliases missed every abbreviation.
#   install, ci, install-test, install-ci-test, update:
SAFEDEPS_G_NPM_VERBS='add|ci|cit|clean-?[iI]nstall|clean-?[iI]nstall-|clean-?[iI]nstall-?[tT]|clean-?[iI]nstall-?[tT]e|clean-?[iI]nstall-?[tT]es|clean-?[iI]nstall-?[tT]est|i|ic|in|ins|inst|insta|instal|install|install-?[cC]i|install-?[cC]i-|install-?[cC]i-?[tT]|install-?[cC]i-?[tT]e|install-?[cC]i-?[tT]es|install-?[cC]i-?[tT]est|install-?[cC]l|install-?[cC]le|install-?[cC]lea|install-?[cC]lean|install-?[tT]|install-?[tT]e|install-?[tT]es|install-?[tT]est|isnt|isnta|isntal|isntall|isntall-|isntall-?[cC]|isntall-?[cC]l|isntall-?[cC]le|isntall-?[cC]lea|isntall-?[cC]lean|it|si|sit|u|ud|udp|udpa|udpat|udpate|up|upd|upda|updat|update|upg|upgr|upgra|upgrad|upgrade'
#   exec:
SAFEDEPS_G_NPM_EXEC_VERBS='exe|exec|x'
#   init, whose documented aliases are create and innit. With an initializer
#   it is `npm exec create-<initializer>` (docs/content/commands/npm-init.md);
#   without one it writes a package.json and fetches nothing.
SAFEDEPS_G_NPM_INIT_VERBS='cr|cre|crea|creat|create|ini|init|inn|inni|innit'
#   link, alias ln. npm reads each argument with npm-package-arg and installs
#   every one the global tree does not have yet into npm's global prefix
#   (lib/commands/link.js:92-104, linkInstall), then links it into the project.
#   A registry argument (a name, a version, a range, a tag, an `npm:` alias) is
#   fetched from the registry; a path, a tarball, a git or a URL argument is
#   linked as written. With no argument it links the project itself.
SAFEDEPS_G_NPM_LINK_VERBS='lin|link|ln'
SAFEDEPS_G_PNPM_VERBS='add|install|i|install-test|it|update|up|upgrade'
SAFEDEPS_G_YARN_VERBS='add|install|upgrade|up'
SAFEDEPS_G_BUN_VERBS='add|a|install|i|update|upgrade'

# Every token that can open an install's operand list, for the operand walks.
SAFEDEPS_G_ALL_VERBS="${SAFEDEPS_G_NPM_VERBS}|${SAFEDEPS_G_NPM_LINK_VERBS}|${SAFEDEPS_G_PNPM_VERBS}|${SAFEDEPS_G_YARN_VERBS}|${SAFEDEPS_G_BUN_VERBS}|${SAFEDEPS_G_NPM_EXEC_VERBS}|dlx|get|run|inject|dependency:get|package"

# Executables the gate names. Used to strip an absolute path prefix, so that
# `/usr/local/bin/pip3.11` is read as `pip3.11`.
SAFEDEPS_G_EXECUTABLES='npm|npx|pnpm|pnpx|yarn|bun|bunx|pip[0-9.]*|python[0-9.]*|py|poetry|uv|uvx|pipx|pipenv|cargo|go|gem|bundle|mvn|dotnet'

# --- building blocks ------------------------------------------------------------
# Where a command starts: the beginning of a line (indented or not), after a
# separator or an opening subshell, and after the reserved words that begin a
# statement. A reserved word only counts where a statement starts, so `echo do
# pip install` stays an echo. `!` and `{` are reserved words too, followed by a
# blank: they used to open a statement anywhere, so `echo ! pip install x | sh`
# read as a visible install instead of the piped one it is.
SAFEDEPS_G_START='(^[[:space:]]*|[;&|(][[:space:]]*)(([!{]|then|do|else|elif|if|while|until|time|coproc)[[:space:]]+)*'

# Options between a manager and its verb: any number, each with an optional
# value, plus the bare `--` that ends them. A value can only be told from the verb by trying both readings, which
# the regex engine does.
SAFEDEPS_G_OPTS='([[:space:]]+(--|--?[A-Za-z0-9][A-Za-z0-9_.-]*([=[:space:]][^[:space:]]+)?))*'

# The package a runner executes: the first operand that is not an option.
SAFEDEPS_G_OPERAND='[[:space:]]+[^-[:space:]][^[:space:]]*'

# One word npm-package-arg reads as a registry package (types range, version,
# tag, alias), the shape `npm link` installs globally: a name with no `/` (or
# `@scope/name`), with no `:` and not starting with `-`, `.`, `/` or `~`, and
# optionally `@` and a spec that is an `npm:` alias or has no `/` and no `:`
# and does not start with `.`; or an `npm:` alias on its own. What it leaves out is a directory, a file, a git
# or a URL argument. One shape npa reads as a file still matches: a bare
# tarball name (`x.tgz`), which the regex cannot tell from a package name. The
# statement then reads as an install, gets `--ignore-scripts`, and the operand
# walk, which reads each argument the way npa does (guard_npa_is_registry),
# names nothing in it. scripts/measure/npm-link-operands.sh checks both
# against the npa of the npm on PATH.
SAFEDEPS_G_NPM_REGISTRY_OPERAND='([Nn][Pp][Mm]:[^[:space:]]+|(@[^/@[:space:]]+/[^/@[:space:]]+|[^-./~@:[:space:]][^/@:[:space:]]*)(@([Nn][Pp][Mm]:[^[:space:]]*|[^./:[:space:]][^/:[:space:]]*)?)?)'

# A git or URL argument, as npm-package-arg reads one: a git URL (git, git+*),
# a hosted shortcut (github:, gitlab:, bitbucket:, gist:), an http(s) tarball,
# an scp-style git address, or the `user/repo` shorthand. npm link fetches and
# installs each of these into the global prefix like a registry argument; only
# a directory or a file is linked as written. They carry no version the ledger
# can check, so the gate records them as UNGATED rather than leaving them quiet.
# A name may stand in front of any of them (`foo@github:u/r`, `foo@u/r`).
SAFEDEPS_G_NPM_REMOTE_SPEC='((git[+][A-Za-z]+|git|github|gitlab|bitbucket|gist|https?):[^[:space:]]+|[^:@%/[:space:].~-][^:@%/[:space:]]*/[^:@[:space:]/%]+(#[^[:space:]]*)?)'
SAFEDEPS_G_NPM_REMOTE_OPERAND="(${SAFEDEPS_G_NPM_REMOTE_SPEC}|[^@[:space:]]+@[^:.[:space:]]+[.][^:[:space:]]+:[^[:space:]]+|(@[^/@[:space:]]+/[^/@[:space:]]+|[^-./~@:[:space:]][^/@:[:space:]]*)@${SAFEDEPS_G_NPM_REMOTE_SPEC})"

SAFEDEPS_G_O="${SAFEDEPS_G_OPTS}"

# npm-CLI installs only. The effect gate reads package-lock.json, which only the
# npm CLI writes, so this is also the set the `--ignore-scripts` rewrite targets.
# A link is an install when any of its arguments is one npm fetches -- a
# registry, git or URL argument -- wherever it stands: link.js reads every
# argument. Reading only the first let a path in
# front hide the package after it (`npm link ../lib evil@1.0.0` installed evil
# globally, its scripts ran, and nothing was judged or recorded).
SAFEDEPS_G_NPM_INSTALL_BODY="npm${SAFEDEPS_G_O}[[:space:]]+(${SAFEDEPS_G_NPM_VERBS})|npm${SAFEDEPS_G_O}[[:space:]]+(${SAFEDEPS_G_NPM_LINK_VERBS})([[:space:]]+[^[:space:]]+)*[[:space:]]+(${SAFEDEPS_G_NPM_REGISTRY_OPERAND}|${SAFEDEPS_G_NPM_REMOTE_OPERAND})"

# Runners fetch a package and execute it. Nothing reads a lockfile after them.
# This ends AT the runner keyword. Options after it belong to the runner and can
# carry the package (`npx -p x@1 cmd`), so the operand walk has to see them.
#
# Each manager's `create` is a runner too: it rewrites its first operand into a
# package name (`vite` -> `create-vite`) and runs that the way its exec does.
# `npm init` with an initializer, `pnpm create` (into `pnpm dlx`), `yarn create`
# (into `yarn dlx`), and `bun create` / `bun c` (into `bunx`, for a name that is
# not a local template or a GitHub repo). guard_create_identity has the
# rewrites, each from that manager's source.
SAFEDEPS_G_CREATE_BODY="npm${SAFEDEPS_G_O}[[:space:]]+(${SAFEDEPS_G_NPM_INIT_VERBS})|pnpm${SAFEDEPS_G_O}[[:space:]]+create|yarn${SAFEDEPS_G_O}[[:space:]]+create|bun${SAFEDEPS_G_O}[[:space:]]+(create|c)"
SAFEDEPS_G_RUNNER_BODY="(npx|pnpx|bunx|uvx)|npm${SAFEDEPS_G_O}[[:space:]]+(${SAFEDEPS_G_NPM_EXEC_VERBS})|${SAFEDEPS_G_CREATE_BODY}|pnpm${SAFEDEPS_G_O}[[:space:]]+dlx|yarn${SAFEDEPS_G_O}[[:space:]]+dlx|bun${SAFEDEPS_G_O}[[:space:]]+x|pipx${SAFEDEPS_G_O}[[:space:]]+run|uv${SAFEDEPS_G_O}[[:space:]]+tool${SAFEDEPS_G_O}[[:space:]]+run|go${SAFEDEPS_G_O}[[:space:]]+run"

SAFEDEPS_G_INSTALL_BODY="${SAFEDEPS_G_NPM_INSTALL_BODY}\
|(npx|pnpx|bunx|uvx)${SAFEDEPS_G_O}${SAFEDEPS_G_OPERAND}\
|npm${SAFEDEPS_G_O}[[:space:]]+(${SAFEDEPS_G_NPM_EXEC_VERBS})${SAFEDEPS_G_O}${SAFEDEPS_G_OPERAND}\
|(${SAFEDEPS_G_CREATE_BODY})${SAFEDEPS_G_O}${SAFEDEPS_G_OPERAND}\
|pnpm${SAFEDEPS_G_O}[[:space:]]+(${SAFEDEPS_G_PNPM_VERBS}|dlx)\
|yarn${SAFEDEPS_G_O}([[:space:]]+(global|workspace[[:space:]]+[^[:space:]]+|workspaces[[:space:]]+foreach${SAFEDEPS_G_O}))?${SAFEDEPS_G_O}[[:space:]]+(${SAFEDEPS_G_YARN_VERBS}|dlx)\
|bun${SAFEDEPS_G_O}[[:space:]]+(${SAFEDEPS_G_BUN_VERBS})\
|bun${SAFEDEPS_G_O}[[:space:]]+x${SAFEDEPS_G_O}${SAFEDEPS_G_OPERAND}\
|(pip[0-9.]*|(python[0-9.]*|py)${SAFEDEPS_G_O}[[:space:]]+-m[[:space:]]*pip)${SAFEDEPS_G_O}[[:space:]]+install\
|poetry${SAFEDEPS_G_O}[[:space:]]+add\
|uv${SAFEDEPS_G_O}[[:space:]]+(add|pip${SAFEDEPS_G_O}[[:space:]]+install|tool${SAFEDEPS_G_O}[[:space:]]+install)\
|uv${SAFEDEPS_G_O}[[:space:]]+tool${SAFEDEPS_G_O}[[:space:]]+run${SAFEDEPS_G_O}${SAFEDEPS_G_OPERAND}\
|pipx${SAFEDEPS_G_O}[[:space:]]+(install|inject)\
|pipx${SAFEDEPS_G_O}[[:space:]]+run${SAFEDEPS_G_O}${SAFEDEPS_G_OPERAND}\
|pipenv${SAFEDEPS_G_O}[[:space:]]+install\
|cargo([[:space:]]+[+][^[:space:]]+)?${SAFEDEPS_G_O}[[:space:]]+(add|install)\
|go${SAFEDEPS_G_O}[[:space:]]+(get|install)\
|go${SAFEDEPS_G_O}[[:space:]]+run${SAFEDEPS_G_O}[[:space:]]+[^-[:space:]][^[:space:]]*@[^[:space:]]+\
|gem${SAFEDEPS_G_O}[[:space:]]+install\
|bundle${SAFEDEPS_G_O}[[:space:]]+add\
|mvn${SAFEDEPS_G_O}[[:space:]]+([^[:space:]]*maven-dependency-plugin[^[:space:]]*:get|dependency:get)\
|dotnet${SAFEDEPS_G_O}[[:space:]]+add([[:space:]]+[^-[:space:]][^[:space:]]*)?${SAFEDEPS_G_O}[[:space:]]+package\
|dotnet${SAFEDEPS_G_O}[[:space:]]+package${SAFEDEPS_G_O}[[:space:]]+(add|update)\
|dotnet${SAFEDEPS_G_O}[[:space:]]+tool${SAFEDEPS_G_O}[[:space:]]+(install|update)"

# --- the patterns the gates read --------------------------------------------------
# Anchored at a statement start. Run these on command_scan_text output, where
# quoted text is already blanked.
SAFEDEPS_G_INSTALL_RE="${SAFEDEPS_G_START}(${SAFEDEPS_G_INSTALL_BODY})([[:space:]]|$)"
SAFEDEPS_G_NPM_INSTALL_RE="${SAFEDEPS_G_START}(${SAFEDEPS_G_NPM_INSTALL_BODY})([[:space:]]|$)"
# An npm link, which installs into the global prefix whatever its flags say.
SAFEDEPS_G_NPM_LINK_RE="${SAFEDEPS_G_START}npm${SAFEDEPS_G_O}[[:space:]]+(${SAFEDEPS_G_NPM_LINK_VERBS})([[:space:]]|$)"
# Ends at the runner keyword; what follows it is the runner's operand list.
SAFEDEPS_G_RUNNER_HEAD_RE="${SAFEDEPS_G_START}(${SAFEDEPS_G_RUNNER_BODY})([[:space:]]|$)"

# Unanchored, for raw text nobody has parsed: the jq-missing fail-closed check
# and the PostToolUse backstop. A false positive there costs a closure diff or a
# deny on a machine without jq, so these stay loose on purpose. The substring
# alternatives are the pre-grammar forms, kept so this can only widen.
SAFEDEPS_G_RAW_INSTALL_RE="(^|[^A-Za-z0-9_./-])(${SAFEDEPS_G_INSTALL_BODY})([^A-Za-z0-9_-]|$)|(npm|pnpm|yarn|bun)([^\"]*)(install|add|dlx)|pip[0-9]*[[:space:]]+install|cargo[[:space:]]+(add|install)|go[[:space:]]+(get|install)|gem[[:space:]]+install|bundle[[:space:]]+add|poetry[[:space:]]+add|uv[[:space:]]+(add|pip)|pipenv[[:space:]]+install|mvn([^\"]*)dependency:get|dotnet[[:space:]]+add[[:space:]]+package"

# True when <token> can open an install's operand list.
safedeps_grammar_is_verb() {
  [[ "$1" =~ ^(${SAFEDEPS_G_ALL_VERBS})$ ]]
}

# True when npm-package-arg reads <arg> as a registry package (types range,
# version, tag, alias) rather than a directory, a file, a git or a URL spec.
# npm link reads each of its arguments this way and installs the registry ones
# into the global prefix (lib/commands/link.js:92-104). The steps are npa.js's
# own (npm-package-arg, in npm 11.19.0): a URL-shaped or scp-shaped argument
# has no name; a name part with a `/` or a tarball suffix makes the whole
# argument a spec; otherwise `name@spec` is split at its `@` and the spec
# resolved. scripts/measure/npm-link-operands.sh runs npa itself on the same
# words and fails on any disagreement.
SAFEDEPS_G_NPA_URL_RE='^(git[+])?[A-Za-z]+:'
SAFEDEPS_G_NPA_SCP_RE='^[^@]+@[^:.]+[.][^:]+:.+$'
SAFEDEPS_G_NPA_TARBALL_RE='[.]([Tt][Gg][Zz]|[Tt][Aa][Rr].[Gg][Zz]|[Tt][Aa][Rr])$'
# hosted-git-info's `user/repo[#ref]` shorthand, which npa reads as git.
SAFEDEPS_G_NPA_HOSTED_RE='^[^:@%/[:space:].-][^:@%/[:space:]]*/[^:@[:space:]/%]+(#.*)?$'
safedeps_npa_is_registry() {
  local arg="$1" rest namepart spec
  [[ "${arg}" =~ ${SAFEDEPS_G_NPA_URL_RE} ]] && { safedeps_npa_spec_is_registry "${arg}"; return; }
  [[ "${arg}" =~ ${SAFEDEPS_G_NPA_SCP_RE} ]] && return 1
  if [[ "${arg}" == @* ]]; then
    rest="${arg:1}"
    if [[ "${rest}" == *@* ]]; then
      namepart="@${rest%%@*}" spec="${rest#*@}"
    else
      namepart="${arg}" spec=""
    fi
  elif [[ "${arg}" == ?*@* ]]; then
    namepart="${arg%%@*}" spec="${arg#*@}"
  else
    namepart="${arg}" spec=""
  fi
  if [[ "${namepart}" != @* ]]; then
    [[ "${namepart}" == */* || "${namepart}" =~ ${SAFEDEPS_G_NPA_TARBALL_RE} ]] && return 1
  fi
  if [[ "${namepart}" == "${arg}" ]]; then
    # A bare word: a scoped name is a name; anything else is a name unless
    # npa reads it as a path (`.`, `..`).
    [[ "${arg}" =~ ^@[^/@]+/[^/@]+$ ]] && return 0
    spec="${arg}"
  fi
  safedeps_npa_spec_is_registry "${spec}"
}
# npa's resolve() on a spec: a file spec, then an alias, then a hosted git, a
# URL, a path or a tarball; anything left is a registry range, version or tag.
safedeps_npa_spec_is_registry() {
  local spec="$1"
  case "${spec}" in
    '') return 0 ;;
    [Ff][Ii][Ll][Ee]:*|.*|'~/'*|/*|[A-Za-z]:*) return 1 ;;
    [Nn][Pp][Mm]:*) return 0 ;;
  esac
  [[ "${spec}" =~ ${SAFEDEPS_G_NPA_URL_RE} || "${spec}" == */* || "${spec}" =~ ${SAFEDEPS_G_NPA_TARBALL_RE} ]] && return 1
  return 0
}

# Whether npa reads an argument as local code -- a directory or a file -- which
# is what npm link links as written. Every other argument (registry, git, URL)
# is fetched and installed into the global prefix (lib/commands/link.js:92-104),
# so the operand walk reads it: judged when it pins a registry version, and
# recorded as UNGATED otherwise. Treating git and URL arguments as local left
# such an install with no record, which a release head had recorded.
safedeps_npa_spec_is_local() {
  local spec="$1"
  case "${spec}" in
    '') return 1 ;;
    [Ff][Ii][Ll][Ee]:*|.*|'~/'*|/*|[A-Za-z]:*) return 0 ;;
    [Nn][Pp][Mm]:*) return 1 ;;
  esac
  [[ "${spec}" =~ ${SAFEDEPS_G_NPA_URL_RE} || "${spec}" =~ ${SAFEDEPS_G_NPA_HOSTED_RE} ]] && return 1
  [[ "${spec}" == */* || "${spec}" =~ ${SAFEDEPS_G_NPA_TARBALL_RE} ]]
}

safedeps_npa_is_local() {
  local arg="$1" rest namepart spec
  case "${arg}" in
    [Ff][Ii][Ll][Ee]:*|.*|'~/'*|/*|[A-Za-z]:*) return 0 ;;
  esac
  [[ "${arg}" =~ ${SAFEDEPS_G_NPA_URL_RE} || "${arg}" =~ ${SAFEDEPS_G_NPA_SCP_RE} ]] && return 1
  if [[ "${arg}" == @* ]]; then
    rest="${arg:1}"
    if [[ "${rest}" == *@* ]]; then
      namepart="@${rest%%@*}" spec="${rest#*@}"
    else
      namepart="${arg}" spec=""
    fi
  elif [[ "${arg}" == ?*@* ]]; then
    namepart="${arg%%@*}" spec="${arg#*@}"
  else
    namepart="${arg}" spec=""
  fi
  # A word that is not a package name is the spec itself.
  if [[ "${namepart}" != @* ]] && [[ "${namepart}" == */* || "${namepart}" =~ ${SAFEDEPS_G_NPA_TARBALL_RE} ]]; then
    safedeps_npa_spec_is_local "${arg}"
    return
  fi
  [[ "${namepart}" != "${arg}" ]] || return 1
  safedeps_npa_spec_is_local "${spec}"
}
