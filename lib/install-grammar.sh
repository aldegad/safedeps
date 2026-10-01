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
# walk, which reads each argument the way npa does (safedeps_npa_is_local),
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
|go${SAFEDEPS_G_O}[[:space:]]+run([[:space:]]+[^[:space:]]+)*[[:space:]]+[^-[:space:]][^[:space:]]*@[^[:space:]]+\
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

# How npm-package-arg (npa) reads an argument, as far as npm link needs it:
# npm link reads each of its arguments this way (lib/commands/link.js:92-104),
# links a directory or a file as written and installs everything else into the
# global prefix (safedeps_npa_is_local below). The steps are npa.js's
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

# --- npm's option reading ------------------------------------------------------
# Which word is npm's command, and which words are its arguments, is decided by
# nopt with the option types in @npmcli/config/lib/definitions: an option whose
# type is not Boolean takes the next word as its value, a Boolean one takes it
# only when it is `true` or `false`, and the rest are positional, the first of
# them being the command. The install grammar's regexes cannot know which
# options take a value, so they try both readings, and where both match the
# regex picked one. It picked wrong for `npm --prefix x install evil@1.0.0`:
# read as `npm x` (exec) with `install` as the package, the install was not
# checked against the ledger, and the record named `npm:install`. npm reads it
# as an install into x.
#
# So the words are read here the way nopt reads them, with npm's own table.
# Each entry is `<option>:<class>`: `v` takes the next word as its value unless
# that word is a dash run (`--`); `s` (String) takes it unless it also looks
# like an option; `b` (Boolean) takes only `true` or `false`. A `+` marks a type
# that lists several, and after it what else nopt takes where it reads the
# option as a Boolean (always for `b+`, and for any option spelled `--no-...`):
# `null` (n), a number (N), any word not starting with a single dash (S), or one
# of the literals after the `=`. `@host` stands for the addresses of the machine
# npm runs on (local-address), which no table can hold, so a reading that would
# need them says it cannot tell. The shorthands are
# npm's, expanded the way nopt expands them. Measured from npm 11.19.0 by
# scripts/measure/npm-option-reading.sh, which also runs nopt itself on a corpus
# of argument lists and fails on any word this reading places differently.
#
# The table is one npm's, and the npm a command runs may be another: npm adds,
# drops and retypes options between releases. Against an npm of another
# version the check names every option that npm defines differently and every
# argument list it reads differently because of one; that is that npm's
# boundary, reported as a skip with the names, never a quiet pass. A list read
# differently through an option both define alike is this reading's defect,
# and fails.
SAFEDEPS_G_NPM_OPTIONS_FROM='11.19.0'
SAFEDEPS_G_NPM_OPTIONS='
  _auth:v+nS access:v+n=restricted,public,private all:b
  allow-directory:v+=all,none,root allow-file:v+=all,none,root
  allow-git:v+=all,none,root allow-remote:v+=all,none,root
  allow-same-version:b allow-scripts-pending:b allow-scripts-pin:b
  allow-scripts:v+S also:v+n=dev,development
  audit-level:v+n=info,low,moderate,high,critical,none audit:b
  auth-type:v+=legacy,web before:v+n bin-links:b browser:b+nS bypass-2fa:b
  ca:v+nS cache-max:v cache-min:v cache:v cafile:v call:s cert:v+nS cidr:v+nS
  color:b+=always commit-hooks:b cpu:v+nS dangerously-allow-all-scripts:b
  depth:v+nN description:b dev:b diff-dst-prefix:s diff-ignore-all-space:b
  diff-name-only:b diff-no-prefix:b diff-src-prefix:s diff-text:b
  diff-unified:v diff:v+S dry-run:b editor:s engine-strict:b
  expect-result-count:v+nN expect-results:b+n expires:v+nN fetch-retries:v
  fetch-retry-factor:v fetch-retry-maxtimeout:v fetch-retry-mintimeout:v
  fetch-timeout:v force:b foreground-scripts:b format-package-lock:b fund:b
  git-tag-version:b git:s global-style:b global:b globalconfig:v heading:s
  https-proxy:v+n if-present:b ignore-scripts:b include-attestations:b
  include-staged:b include-workspace-root:b include:v+=prod,dev,optional,peer
  init-author-email:s init-author-name:s init-author-url:v+= init-license:s
  init-module:v init-private:b init-type:s init-version:v init.author.email:s
  init.author.name:s init.author.url:v+= init.license:s init.module:v
  init.version:v install-links:b
  install-strategy:v+=hoisted,nested,shallow,linked json:b key:v+nS
  legacy-bundling:b legacy-peer-deps:b libc:v+nS link:b
  local-address:v+n=@host location:v+=global,user,project
  lockfile-version:v+n=1,2,3
  loglevel:v+=silent,error,warn,notice,http,info,verbose,silly logs-dir:v+n
  logs-max:v long:b maxsockets:v message:s min-release-age-exclude:v+S
  min-release-age:v+nN name:v+nS node-gyp:v node-options:v+nS noproxy:v+S
  offline:b omit-lockfile-registry-resolved:b omit:v+=dev,optional,peer
  only:v+n=prod,production optional:b+n
  orgs-permission:v+n=read-only,read-write,no-access orgs:v+nS os:v+nS
  otp:v+nS pack-destination:s package-lock-only:b package-lock:b package:v+S
  packages-all:b
  packages-and-scopes-permission:v+n=read-only,read-write,no-access
  packages:v+nS parseable:b password:v+nS prefer-dedupe:b prefer-offline:b
  prefer-online:b prefix:v preid:s production:b+n progress:b provenance-file:v
  provenance:b proxy:v+n read-only:b rebuild-bundle:b registry:v
  replace-registry-host:v+S=npmjs,never,always save-bundle:b save-dev:b
  save-exact:b save-optional:b save-peer:b save-prefix:s save-prod:b save:b
  sbom-format:v+=cyclonedx,spdx sbom-type:v+=library,application,framework
  scope:s scopes:v+nS script-shell:v+nS searchexclude:s searchlimit:v
  searchopts:s searchstaleness:v shell:s shrinkwrap:b sign-git-commit:b
  sign-git-tag:b strict-allow-scripts:b strict-peer-deps:b strict-ssl:b
  tag-version-prefix:s tag:s timing:b token-description:v+nS umask:v unicode:b
  update-notifier:b usage:b user-agent:s userconfig:v version:b versions:b
  viewer:s which:v+nN workspace:v+S workspaces-update:b workspaces:b+n yes:b+n
'
SAFEDEPS_G_NPM_SHORTHANDS='
  enjoy-by=--before d=--loglevel,info dd=--loglevel,verbose
  ddd=--loglevel,silly quiet=--loglevel,warn q=--loglevel,warn
  s=--loglevel,silent silent=--loglevel,silent verbose=--loglevel,verbose
  desc=--description help=--usage local=--no-global n=--no-yes no=--no-yes
  porcelain=--parseable readonly=--read-only reg=--registry
  iwr=--include-workspace-root ws=--workspaces a=--all c=--call f=--force
  g=--global L=--location l=--long m=--message p=--parseable C=--prefix
  S=--save B=--save-bundle D=--save-dev E=--save-exact O=--save-optional
  P=--save-prod ?=--usage H=--usage h=--usage v=--version w=--workspace
  y=--yes
'
SAFEDEPS_G_NPM_OPTIONS=" ${SAFEDEPS_G_NPM_OPTIONS//$'\n'/ } "
SAFEDEPS_G_NPM_SHORTHANDS=" ${SAFEDEPS_G_NPM_SHORTHANDS//$'\n'/ } "

# <word> as an ERE that matches it literally, in SAFEDEPS_G_ERE. The tables are
# searched with =~, which is linear: bash's own pattern removal
# (`${table#* "${key}":}`) is quadratic in the table's length, and these
# lookups run for every option word of every npm statement.
safedeps_ere_literal() {
  local word="$1" i c
  SAFEDEPS_G_ERE=""
  for (( i = 0; i < ${#word}; i++ )); do
    c="${word:i:1}"
    case "${c}" in
      [A-Za-z0-9_@,:=-]) SAFEDEPS_G_ERE+="${c}" ;;
      '\'|'^') SAFEDEPS_G_ERE+="\\${c}" ;;
      *) SAFEDEPS_G_ERE+="[${c}]" ;;
    esac
  done
}

# The entry of <list> (`<key><sep><value>` entries, <sep> `:` or `=`, blank
# separated) whose key is <key>: its value in SAFEDEPS_G_VALUE, status 1 when
# there is none.
safedeps_npm_lookup() {
  local re
  safedeps_ere_literal "$1"
  re=" ${SAFEDEPS_G_ERE}[:=]([^ ]*)"
  [[ "$2" =~ ${re} ]] || return 1
  SAFEDEPS_G_VALUE="${BASH_REMATCH[1]}"
}

# The one entry of <list> whose key starts with <prefix>, as abbrev(1) does for
# nopt: its key in SAFEDEPS_G_PICKED, empty when none or more than one does.
# <prefix> is never a whole key here.
safedeps_npm_unique_prefix() {
  local re
  SAFEDEPS_G_PICKED=""
  [[ -n "$1" ]] || return 0
  safedeps_ere_literal "$1"
  re=" ${SAFEDEPS_G_ERE}[^ ]* (.* )?${SAFEDEPS_G_ERE}"
  [[ "$2" =~ ${re} ]] && return 0
  re=" (${SAFEDEPS_G_ERE}[^ :=]*)[:=]"
  [[ "$2" =~ ${re} ]] && SAFEDEPS_G_PICKED="${BASH_REMATCH[1]}"
  return 0
}

# nopt's resolveShort: what an option word expands to, as SAFEDEPS_G_SHORT_SET
# (true or false) and SAFEDEPS_G_SHORT (the expansion, comma separated, which
# can be empty).
safedeps_npm_short() {
  local s="$1" k c
  SAFEDEPS_G_SHORT_SET=false SAFEDEPS_G_SHORT=""
  while [[ "${s}" == -* ]]; do s="${s#-}"; done
  safedeps_npm_lookup "${s}" "${SAFEDEPS_G_NPM_OPTIONS}" && return 0
  if safedeps_npm_lookup "${s}" "${SAFEDEPS_G_NPM_SHORTHANDS}"; then
    SAFEDEPS_G_SHORT="${SAFEDEPS_G_VALUE}" SAFEDEPS_G_SHORT_SET=true
    return 0
  fi
  # Every character a one-character shorthand (`-gC`), expanded in order.
  c=""
  for (( k = 0; k < ${#s}; k++ )); do
    safedeps_npm_lookup "${s:k:1}" "${SAFEDEPS_G_NPM_SHORTHANDS}" || break
    c="${c:+${c},}${SAFEDEPS_G_VALUE}"
  done
  if (( k == ${#s} )); then
    SAFEDEPS_G_SHORT_SET=true SAFEDEPS_G_SHORT="${c}"
    return 0
  fi
  safedeps_npm_unique_prefix "${s}" "${SAFEDEPS_G_NPM_OPTIONS}"
  [[ -z "${SAFEDEPS_G_PICKED}" ]] || return 0
  safedeps_npm_unique_prefix "${s}" "${SAFEDEPS_G_NPM_SHORTHANDS}"
  [[ -n "${SAFEDEPS_G_PICKED}" ]] || return 0
  safedeps_npm_lookup "${SAFEDEPS_G_PICKED}" "${SAFEDEPS_G_NPM_SHORTHANDS}"
  SAFEDEPS_G_SHORT="${SAFEDEPS_G_VALUE}" SAFEDEPS_G_SHORT_SET=true
}

# True when JavaScript's isNaN(<word>) is false, which is nopt's test for a
# number: decimal (with a fraction or an exponent), hex, octal or binary,
# Infinity, each with blanks around it, and the blank or empty word, which is 0.
safedeps_js_is_number() {
  local w="$1"
  w="${w#"${w%%[![:space:]]*}"}"
  w="${w%"${w##*[![:space:]]}"}"
  [[ -z "${w}" ]] && return 0
  [[ "${w}" =~ ^[+-]?(Infinity|[0-9]+[.]?[0-9]*([eE][+-]?[0-9]+)?|[.][0-9]+([eE][+-]?[0-9]+)?)$ ]] && return 0
  [[ "${w}" =~ ^0([xX][0-9a-fA-F]+|[oO][0-7]+|[bB][01]+)$ ]]
}

# npm's reading of the words after `npm`, as nopt reads them (nopt-lib.js
# parse, nopt 9 in npm 11.19.0). Sets SAFEDEPS_G_NPM_AT and SAFEDEPS_G_NPM_WORDS,
# the positional words in order with the index of the word each came from. The
# first is npm's command; the rest are its arguments. A positional can be the
# value half of a `--name=value` word whose option took no value
# (`--global=evil` installs evil), so it carries that word's index and the text
# after the `=`. No process is started: this runs once per statement. Returns 1
# when the reading depends on something a table cannot hold (`@host`).
safedeps_npm_read_args() {
  local -a w=("$@") at=() exp=()
  local i j n arg v s cls la la_set hadeq no key consumed flags lits steps=0
  SAFEDEPS_G_NPM_AT=() SAFEDEPS_G_NPM_WORDS=()
  for (( i = 0; i < ${#w[@]}; i++ )); do at[i]=${i}; done
  i=0
  while (( i < ${#w[@]} )); do
    # Every step consumes a word or replaces one with npm's fixed expansions,
    # which never expand again; the bound only keeps a defect from spinning.
    (( ++steps <= 4 * ${#w[@]} + 64 )) || return 1
    arg="${w[i]}"
    if [[ "${arg}" =~ ^--+$ ]]; then
      for (( j = i + 1; j < ${#w[@]}; j++ )); do
        SAFEDEPS_G_NPM_AT+=("${at[j]}") SAFEDEPS_G_NPM_WORDS+=("${w[j]}")
      done
      return 0
    fi
    if [[ "${arg}" != -?* ]]; then
      SAFEDEPS_G_NPM_AT+=("${at[i]}") SAFEDEPS_G_NPM_WORDS+=("${arg}")
      i=$(( i + 1 ))
      continue
    fi
    hadeq=false
    if [[ "${arg}" == *=* ]]; then
      hadeq=true
      v="${arg#*=}" arg="${arg%%=*}"
      w=("${w[@]:0:i}" "${arg}" "${v}" "${w[@]:i+1}")
      at=("${at[@]:0:i}" "${at[i]}" "${at[@]:i}")
    fi
    safedeps_npm_short "${arg}"
    if [[ "${SAFEDEPS_G_SHORT_SET}" == true ]]; then
      exp=()
      v="${SAFEDEPS_G_SHORT}"
      while [[ -n "${v}" ]]; do
        exp+=("${v%%,*}")
        [[ "${v}" == *,* ]] && v="${v#*,}" || v=""
      done
      n=${#exp[@]}
      w=("${w[@]:0:i}" "${exp[@]+"${exp[@]}"}" "${w[@]:i+1}")
      v="${at[i]}"
      at=("${at[@]:0:i}" "${at[@]:i+1}")
      for (( j = 0; j < n; j++ )); do at=("${at[@]:0:i}" "${v}" "${at[@]:i}"); done
      (( n > 0 )) && [[ "${arg}" == "${exp[0]}" ]] || continue
    fi
    s="${arg}"
    while [[ "${s}" == -* ]]; do s="${s#-}"; done
    no=""
    while [[ "${s:0:3}" == [Nn][Oo]- ]]; do no="set"; s="${s:3}"; done
    key="${s}" cls=""
    if ! safedeps_npm_lookup "${key}" "${SAFEDEPS_G_NPM_OPTIONS}"; then
      safedeps_npm_unique_prefix "${key}" "${SAFEDEPS_G_NPM_OPTIONS}"
      [[ -z "${SAFEDEPS_G_PICKED}" ]] || key="${SAFEDEPS_G_PICKED}"
    fi
    safedeps_npm_lookup "${key}" "${SAFEDEPS_G_NPM_OPTIONS}" && cls="${SAFEDEPS_G_VALUE}"
    la="" la_set=false
    if (( i + 1 < ${#w[@]} )); then la="${w[i+1]}" la_set=true; fi
    consumed=0
    if [[ -n "${no}" || "${cls}" == b* || ( -z "${cls}" && "${hadeq}" == false ) ]]; then
      if [[ "${la_set}" == true && ( "${la}" == true || "${la}" == false ) ]]; then
        consumed=1 la_set=false
      fi
      if [[ "${cls}" == ?+* && "${la_set}" == true && -n "${la}" ]]; then
        flags="${cls#?+}" lits=""
        [[ "${flags}" != *=* ]] || { lits=",${flags#*=},"; flags="${flags%%=*}"; }
        [[ "${lits}" != ",@host," ]] || return 1
        if [[ -n "${lits}" && "${lits}" == *",${la},"* ]]; then
          consumed=1
        elif [[ "${la}" == null && "${flags}" == *n* ]]; then
          consumed=1
        elif [[ "${flags}" == *N* && ! "${la}" =~ ^--+[^-] ]] && safedeps_js_is_number "${la}"; then
          consumed=1
        elif [[ "${flags}" == *S* && ! "${la}" =~ ^-[^-] ]]; then
          consumed=1
        fi
      fi
    elif [[ "${la_set}" == true ]]; then
      consumed=1
      [[ "${cls}" == s && "${la}" =~ ^--?[^-] ]] && consumed=0
      [[ "${la}" =~ ^--+$ ]] && consumed=0
    fi
    i=$(( i + 1 + consumed ))
  done
  return 0
}

# Which kind of command npm runs for <words> (the words after `npm`): `install`,
# `link`, `exec` or `init` when its command word is one of the grammar's
# spellings for it, `other` for any other command, `none` without one. The
# index of the command word among <words> is SAFEDEPS_G_NPM_CMD_AT, -1 without
# one, and the positional words after it are npm's operands.
safedeps_npm_command_kind() {
  local cmd
  SAFEDEPS_G_NPM_KIND=none SAFEDEPS_G_NPM_CMD_AT=-1
  safedeps_npm_read_args "$@" || return 1
  [[ ${#SAFEDEPS_G_NPM_WORDS[@]} -gt 0 ]] || return 0
  cmd="${SAFEDEPS_G_NPM_WORDS[0]}" SAFEDEPS_G_NPM_CMD_AT="${SAFEDEPS_G_NPM_AT[0]}"
  if [[ "${cmd}" =~ ^(${SAFEDEPS_G_NPM_VERBS})$ ]]; then SAFEDEPS_G_NPM_KIND=install
  elif [[ "${cmd}" =~ ^(${SAFEDEPS_G_NPM_LINK_VERBS})$ ]]; then SAFEDEPS_G_NPM_KIND="link"
  elif [[ "${cmd}" =~ ^(${SAFEDEPS_G_NPM_EXEC_VERBS})$ ]]; then SAFEDEPS_G_NPM_KIND="exec"
  elif [[ "${cmd}" =~ ^(${SAFEDEPS_G_NPM_INIT_VERBS})$ ]]; then SAFEDEPS_G_NPM_KIND=init
  else SAFEDEPS_G_NPM_KIND=other
  fi
}
