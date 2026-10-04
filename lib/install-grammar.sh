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

# The same, as the recognizers read it: an option's value may run over several
# words of the scan view, as a substitution or an escaped blank does there
# (`--prefix $(echo a b)`), but never past a `;`, `&` or `|`. The recognizers
# only say that a statement may be an install; which word is the command is
# the manager's grammar (safedeps_manager_read), so this can only be wider than
# the installs it finds, never narrower. The inert rewrite anchors on the
# narrow form above.
SAFEDEPS_G_O='([[:space:]]+(--|--?[A-Za-z0-9][A-Za-z0-9_.-]*(=[^[:space:]]*)?([[:space:]]+[^-[:space:];&|][^[:space:];&|]*)*))*'

# npm-CLI installs only. The effect gate reads package-lock.json, which only the
# npm CLI writes, so this is also the set the `--ignore-scripts` rewrite targets.
# A link is an install when any of its arguments is one npm fetches -- a
# registry, git or URL argument -- wherever it stands: link.js reads every
# argument. Reading only the first let a path in
# front hide the package after it (`npm link ../lib evil@1.0.0` installed evil
# globally, its scripts ran, and nothing was judged or recorded).
SAFEDEPS_G_NPM_INSTALL_BODY="npm${SAFEDEPS_G_O}[[:space:]]+(${SAFEDEPS_G_NPM_VERBS})|npm${SAFEDEPS_G_O}[[:space:]]+(${SAFEDEPS_G_NPM_LINK_VERBS})([[:space:]]+[^[:space:]]+)*[[:space:]]+(${SAFEDEPS_G_NPM_REGISTRY_OPERAND}|${SAFEDEPS_G_NPM_REMOTE_OPERAND})"

# Runners fetch a package and execute it. Nothing reads a lockfile after them.
# Which word is the package (`npx -p x@1 cmd` names it by option) is the
# manager's grammar below, not this pattern's.
#
# Each manager's `create` is a runner too: it rewrites its first operand into a
# package name (`vite` -> `create-vite`) and runs that the way its exec does.
# `npm init` with an initializer, `pnpm create` (into `pnpm dlx`), `yarn create`
# (into `yarn dlx`), and `bun create` / `bun c` (into `bunx`, for a name that is
# not a local template or a GitHub repo). guard_create_identity has the
# rewrites, each from that manager's source.
SAFEDEPS_G_CREATE_BODY="npm${SAFEDEPS_G_O}[[:space:]]+(${SAFEDEPS_G_NPM_INIT_VERBS})|pnpm${SAFEDEPS_G_O}[[:space:]]+create|yarn${SAFEDEPS_G_O}[[:space:]]+create|bun${SAFEDEPS_G_O}[[:space:]]+(create|c)"

SAFEDEPS_G_INSTALL_BODY="${SAFEDEPS_G_NPM_INSTALL_BODY}\
|(npx|pnpx|bunx|uvx)${SAFEDEPS_G_O}${SAFEDEPS_G_OPERAND}\
|npm${SAFEDEPS_G_O}[[:space:]]+(${SAFEDEPS_G_NPM_EXEC_VERBS})${SAFEDEPS_G_O}${SAFEDEPS_G_OPERAND}\
|(${SAFEDEPS_G_CREATE_BODY})${SAFEDEPS_G_O}${SAFEDEPS_G_OPERAND}\
|pnpm${SAFEDEPS_G_O}[[:space:]]+(${SAFEDEPS_G_PNPM_VERBS}|dlx)\
|yarn${SAFEDEPS_G_O}([[:space:]]+(global|workspace[[:space:]]+[^[:space:]]+|workspaces[[:space:]]+foreach${SAFEDEPS_G_O}))?${SAFEDEPS_G_O}[[:space:]]+(${SAFEDEPS_G_YARN_VERBS}|dlx)\
|bun${SAFEDEPS_G_O}[[:space:]]+(${SAFEDEPS_G_BUN_VERBS})\
|bun${SAFEDEPS_G_O}[[:space:]]+x${SAFEDEPS_G_O}${SAFEDEPS_G_OPERAND}\
|(pip[0-9.]*|(python[0-9.]*|py)${SAFEDEPS_G_O}[[:space:]]+-[A-Za-z0-9]*m[[:space:]]*pip)${SAFEDEPS_G_O}[[:space:]]+install\
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

# Unanchored, for raw text nobody has parsed: the jq-missing fail-closed check
# and the PostToolUse backstop. A false positive there costs a closure diff or a
# deny on a machine without jq, so these stay loose on purpose. The substring
# alternatives are the pre-grammar forms, kept so this can only widen.
SAFEDEPS_G_RAW_INSTALL_RE="(^|[^A-Za-z0-9_./-])(${SAFEDEPS_G_INSTALL_BODY})([^A-Za-z0-9_-]|$)|(npm|pnpm|yarn|bun)([^\"]*)(install|add|dlx)|pip[0-9]*[[:space:]]+install|cargo[[:space:]]+(add|install)|go[[:space:]]+(get|install)|gem[[:space:]]+install|bundle[[:space:]]+add|poetry[[:space:]]+add|uv[[:space:]]+(add|pip)|pipenv[[:space:]]+install|mvn([^\"]*)dependency:get|dotnet[[:space:]]+add[[:space:]]+package"
# The PostToolUse backstop's pattern, read case-insensitively with grep -E. The
# pre-guard reads the same one to decide which commands it did not read as an
# install still get a trace baseline, so the two cannot disagree on which
# commands the backstop judges.
SAFEDEPS_G_BACKSTOP_RE="${SAFEDEPS_G_RAW_INSTALL_RE}|(^|[^a-zA-Z0-9_-])npx[[:space:]]+(@?[A-Za-z0-9._-])"


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
# drops and retypes options between releases. npm 10.8.2's differences are
# tabled below (SAFEDEPS_G_NPM_OTHER), a statement that names one of them is
# read both ways, and the check holds that reading to npm 10.8.2's nopt. Against
# any other version the check names every option that npm defines differently
# and every argument list it reads differently because of one; that is that
# npm's boundary, reported as a skip with the names, never a quiet pass. A list
# read differently through an option both define alike is this reading's
# defect, and fails.
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
# Each table is searched with =~ as one line, every entry between single
# blanks. The tables are written one entry per word over many lines, so each
# is rewritten into that one line here, at load, by its variable's name. It is
# split into words rather than substituted: bash 3.2's `${table//$'\n'/ }` is
# quadratic in the table's length, and on the value-option table below it took
# 0.85s (macOS /bin/bash, 2026-10-03) -- on every Bash call, since this file
# is sourced by both hooks. scripts/test/self-budget.sh holds every load to a
# bound, under bash 3.2 where the machine has one.
safedeps_g_one_line() {
  local noglob=false IFS=$' \t\n'
  local -a words=()
  [[ "$-" != *f* ]] || noglob=true
  set -f
  # shellcheck disable=SC2206  # split on blanks on purpose; globbing is off
  words=( ${!1} )
  [[ "${noglob}" == true ]] || set +f
  IFS=' '
  printf -v "$1" ' %s ' "${words[*]}"
}
safedeps_g_one_line SAFEDEPS_G_NPM_OPTIONS
safedeps_g_one_line SAFEDEPS_G_NPM_SHORTHANDS

# Where another npm the gate supports defines an option differently, a word
# after that option is read both ways, and a statement is judged as the union:
# an install under either reading is judged. The table above is npm 11.19.0's;
# npm 10.8.2 (node 20, which GitHub CI and many machines run) does not define
# the options marked `-` below, so to it each is an unknown Boolean and the
# word after it is npm's command or an operand: `npm --min-release-age install
# evil@1.0.0` installs evil under npm 10 and runs a command named evil@1.0.0
# under npm 11. Judging only the npm 11 reading let that pass unchecked. Only
# these options start the second reading, so a command without one costs
# nothing more. scripts/measure/npm-option-reading.sh checks this list, and
# the reading under it, against an npm 10.8.2 on PATH.
SAFEDEPS_G_NPM_OTHER_FROM='10.8.2'
SAFEDEPS_G_NPM_OTHER='
  access:v+n=restricted,public allow-directory:- allow-file:- allow-git:-
  allow-remote:- allow-scripts:- allow-scripts-pending:-
  allow-scripts-pin:- bypass-2fa:- dangerously-allow-all-scripts:-
  expires:- include-attestations:- init-private:- init-type:-
  min-release-age:- min-release-age-exclude:- name:- node-gyp:- orgs:-
  orgs-permission:- packages:- packages-all:-
  packages-and-scopes-permission:- password:- scopes:-
  strict-allow-scripts:- token-description:-
'
safedeps_g_one_line SAFEDEPS_G_NPM_OTHER

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

# True when an option word among the arguments names, abbreviates or negates
# an option the other npm defines differently (SAFEDEPS_G_NPM_OTHER), so the
# arguments have a second reading.
safedeps_npm_other_applies() {
  local word s re
  for word in "$@"; do
    [[ "${word}" == -?* ]] || continue
    s="${word%%=*}"
    while [[ "${s}" == -* ]]; do s="${s#-}"; done
    while [[ "${s:0:3}" == [Nn][Oo]- ]]; do s="${s:3}"; done
    [[ -n "${s}" ]] || continue
    safedeps_ere_literal "${s}"
    re=" ${SAFEDEPS_G_ERE}[^ :]*:"
    [[ "${SAFEDEPS_G_NPM_OTHER}" =~ ${re} ]] && return 0
  done
  return 1
}

# Runs "$@" with npm's option table as the other npm defines it. The table is
# built once per process, by splitting it into words: bash's own substitution
# on a table this long is quadratic.
SAFEDEPS_G_NPM_OPTIONS_AS_OTHER=""
safedeps_npm_as_other() {
  local saved="${SAFEDEPS_G_NPM_OPTIONS}" entry key rc=0
  local -a entries=()
  if [[ -z "${SAFEDEPS_G_NPM_OPTIONS_AS_OTHER}" ]]; then
    read -ra entries <<< "${SAFEDEPS_G_NPM_OPTIONS}"
    SAFEDEPS_G_NPM_OPTIONS_AS_OTHER=" "
    for entry in "${entries[@]}"; do
      key="${entry%%:*}"
      case "${SAFEDEPS_G_NPM_OTHER}" in *" ${key}:"*) continue ;; esac
      SAFEDEPS_G_NPM_OPTIONS_AS_OTHER+="${entry} "
    done
    read -ra entries <<< "${SAFEDEPS_G_NPM_OTHER}"
    for entry in "${entries[@]}"; do
      [[ "${entry#*:}" == - ]] || SAFEDEPS_G_NPM_OPTIONS_AS_OTHER+="${entry} "
    done
  fi
  SAFEDEPS_G_NPM_OPTIONS="${SAFEDEPS_G_NPM_OPTIONS_AS_OTHER}"
  "$@" || rc=$?
  SAFEDEPS_G_NPM_OPTIONS="${saved}"
  return "${rc}"
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
# parse, nopt 9 in npm 11.19.0). Sets SAFEDEPS_G_NPM_AT and SAFEDEPS_G_NPM_WORDS
# (and SAFEDEPS_G_NPM_VALUES, each option value it took, and
# SAFEDEPS_G_NPM_SWITCHES, each switch it set, as `<option>=true|false` in the
# order npm reads them, so the last one for an option is the value npm keeps),
# the positional words in order with the index of the word each came from. The
# first is npm's command; the rest are its arguments. A positional can be the
# value half of a `--name=value` word whose option took no value
# (`--global=evil` installs evil), so it carries that word's index and the text
# after the `=`. No process is started: this runs once per statement. Returns 1
# when the reading depends on something a table cannot hold (`@host`).
safedeps_npm_read_args() {
  local -a w=("$@") at=() exp=()
  local i j n arg v s cls la la_set hadeq no neg key consumed flags lits steps=0
  SAFEDEPS_G_NPM_AT=() SAFEDEPS_G_NPM_WORDS=() SAFEDEPS_G_NPM_VALUES=() SAFEDEPS_G_NPM_SWITCHES=()
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
    no="" neg=false
    while [[ "${s:0:3}" == [Nn][Oo]- ]]; do
      no="set" s="${s:3}"
      [[ "${neg}" == true ]] && neg=false || neg=true
    done
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
    # Each value taken, as `<word index>\037<option>\037<value>`: a runner's
    # `--package` names the package it runs.
    if (( consumed )); then
      SAFEDEPS_G_NPM_VALUES+=("${at[i+1]}"$'\037'"${key}"$'\037'"${w[i+1]}")
    fi
    # A switch is true unless a `no-` (an odd number of them) or a `true` or
    # `false` after it says otherwise; nopt reads `--x false` as `--x=false`.
    if [[ -n "${no}" || "${cls}" == b* ]]; then
      v=true
      (( consumed )) && [[ "${w[i+1]}" == false ]] && v=false
      if [[ "${neg}" == true ]]; then
        [[ "${v}" == true ]] && v=false || v=true
      fi
      (( consumed )) && [[ "${w[i+1]}" != true && "${w[i+1]}" != false ]] && v=""
      [[ -z "${v}" ]] || SAFEDEPS_G_NPM_SWITCHES+=("${key}=${v}")
    fi
    i=$(( i + 1 + consumed ))
  done
  return 0
}


# --- The manager word grammar ---------------------------------------------------
# One reader of a statement's words for every manager: which word is the
# manager, which words name its command, which words are option values (and of
# what kind), and which are the operands it installs or the package it runs.
# The spec extractor, the UNGATED record, the landing of a non-npm install and
# the runner reader all read its roles and nothing else.
#
# It replaced four readers that each approximated the same grammar: the
# recognizer regexes picked a verb by trying both readings of an option that
# may take a value (`npm --prefix x install` read as `npm x`); the extractor's
# awk knew value options for gem, bundle, cargo and dotnet only, so `pip
# --cache-dir x install evil==1.0.0` recorded `pypi:install` and `cargo
# --config x install evil --version 1.0.0` passed unchecked; the record walk
# took the first word that looked like a verb (`pnpm --dir x add` recorded
# `npm:add`); and the landing read `--prefix|--cwd|--dir|--install-dir`
# wherever it stood. Each disagreed with the manager somewhere, and the
# disagreement was a silent pass or a false record.
#
# The tables below are each manager's own, from its help or source as noted. A
# value option not in a table is read as taking no value, which can only turn
# its value into an extra operand -- a check or a record, never a skipped
# package. The recognizer regexes stay as a filter that says whether a
# statement may be an install; they decide no position.

# What each command path of a manager is: `<family>:<path>=<kind>`. <path> is
# the command words after the manager, joined by `,`, where `*` stands for any
# one word (dotnet's project file). <kind> is install, runner or create. npm's
# commands come from its own reading (safedeps_manager_read_npm).
#   pnpm   pnpm --help (10.28.1); pnpx is `pnpm dlx`.
#   yarn   yarn --help (1.22.22) and yarnpkg.com/cli (Berry: up, dlx,
#          workspace, workspaces foreach).
#   bun    bun <command> --help (1.4.2); bunx is `bun x`. `bun upgrade` is
#          bun's own upgrade, kept as an install: a spurious check at worst.
#   pip    pip --help (26.1.2), also as `python -m pip`.
#   uv     uv --help (0.10.11); uvx is `uv tool run`.
#   pipx   pipx --help (1.12.0).
#   poetry python-poetry.org/docs/cli (2.x; not installed where measured).
#   pipenv pipenv.pypa.io/en/latest/cli (not installed where measured).
#   cargo  cargo --help (1.94.0); `cargo add --vers` is cargo-edit's, which
#          older toolchains still run, read as the pin it is there.
#          go: go help (go1.26.5).
#   gem    gem help install (3.0.3.1).  bundle: bundler.io/man/bundle-add.
#   dotnet learn.microsoft.com/dotnet/core/tools (.NET 10 SDK).
#   mvn    maven.apache.org/ref/current/maven-embedder/cli.html; the install
#          is the dependency:get goal, read apart (safedeps_manager_read).
SAFEDEPS_G_COMMANDS='
  pnpm:add=install pnpm:install=install pnpm:i=install pnpm:install-test=install
  pnpm:it=install pnpm:update=install pnpm:up=install pnpm:upgrade=install
  pnpm:dlx=runner pnpm:create=create pnpx:=runner
  yarn:add=install yarn:install=install yarn:upgrade=install yarn:up=install
  yarn:dlx=runner yarn:create=create
  yarn:global,add=install yarn:global,upgrade=install
  yarn:workspace,*,add=install yarn:workspace,*,up=install yarn:workspace,*,upgrade=install
  yarn:workspaces,foreach,add=install yarn:workspaces,foreach,install=install
  yarn:workspaces,foreach,up=install yarn:workspaces,foreach,upgrade=install
  yarn:workspaces,foreach,dlx=runner
  bun:add=install bun:a=install bun:install=install bun:i=install bun:update=install
  bun:upgrade=install bun:x=runner bun:create=create bun:c=create bunx:=runner
  pip:install=install
  uv:add=install uv:pip,install=install uv:tool,install=install uv:tool,run=runner
  uvx:=runner
  pipx:install=install pipx:inject=install pipx:run=runner
  poetry:add=install pipenv:install=install
  cargo:add=install cargo:install=install
  go:get=install go:install=install go:run=runner
  gem:install=install bundle:add=install
  dotnet:add,package=install dotnet:add,*,package=install dotnet:package,add=install
  dotnet:package,update=install dotnet:tool,install=install dotnet:tool,update=install
'

# The options that take a value: `<family>/<scope>:<option>=<class>`. <scope>
# is `*` for the manager's own options, which every command accepts and which
# are read before the command as well, or a command path. A command path's
# entry is looked up first, so `*` never stands in for what a command reads.
# An option several commands read is listed once per command (bun's below):
# the table is read as written, with nothing expanded at load, because this
# file loads on every Bash call. <class> says what the value is:
#   v  a value that names no package
#   d  a directory the command runs in or installs into
#   V  the version every operand of the command is pinned to
#   p  the package itself (a runner's `--package`, pip's `-e`)
#   w  a package added beside the one that runs (uvx `--with`)
#   b  a value that names no package to one version of the manager, and a
#      switch to another, so the word after it is the value to one and an
#      operand to the other. The statement is read both ways and judged as the
#      union (safedeps_manager_read), as npm's are across npm 10.8.2 and 11.
#      poetry 2.x reads `add --optional <extra>`; poetry 1.8.5 reads
#      `--optional` as a switch (src/poetry/console/commands/add.py, option
#      "optional" at both tags), so `poetry add --optional evil==1.0.0` adds
#      evil under 1.8.5.
# Only options that always take a value are listed. One whose value is
# optional, or one that is not listed, takes none, so its value is read as an
# operand: a spurious check or record, never a package skipped. The other
# direction is the one that hides a package: an entry for an option the manager
# reads as a switch takes the package after it for its value. So each entry is
# held against the manager's own reading where the manager can be asked
# (scripts/measure/manager-option-reading.sh).
#
# bun has no `*` entry. It takes for its command the first word that does not
# start with `-` (bun 1.4.2, measured: `bun --cwd x add y` runs `bun x add y`),
# so no option takes a value before the command, and an option there is read
# both ways (safedeps_manager_read). Its runtime options (`bun --help`:
# --print, --eval, --preload, --port, ...) belong to `bun run` and to running
# a file, which install nothing; in an install command bun reads them as
# switches (`bun add --print x` installs x), so no scope here holds them.
# `-c, --config` and `--catalog` take a value only after `=` (`bun add -c x`
# installs x), and bunx reads `--cwd` as a switch.
SAFEDEPS_G_VALUE_OPTIONS='
  pnpm/*:-C=d pnpm/*:--dir=d pnpm/*:--filter=v pnpm/*:-F=v pnpm/*:--filter-prod=v
  pnpm/*:--loglevel=v pnpm/*:--reporter=v pnpm/*:--test-pattern=v
  pnpm/*:--changed-files-ignore-pattern=v pnpm/*:--store-dir=v pnpm/*:--virtual-store-dir=v
  pnpm/*:--modules-dir=v pnpm/*:--lockfile-dir=v pnpm/*:--global-dir=v
  pnpm/*:--child-concurrency=v pnpm/*:--network-concurrency=v pnpm/*:--hoist-pattern=v
  pnpm/*:--public-hoist-pattern=v pnpm/*:--trust-policy-exclude=v
  pnpm/*:--trust-policy-ignore-after=v pnpm/*:--allow-build=v
  pnpm/dlx:--package=p pnpx/*:--package=p pnpx/*:--allow-build=v
  pnpx/*:-C=d pnpx/*:--dir=d pnpx/*:--filter=v pnpx/*:-F=v pnpx/*:--loglevel=v pnpx/*:--reporter=v
  yarn/*:--cwd=d yarn/*:--cache-folder=v yarn/*:--global-folder=v yarn/*:--link-folder=v
  yarn/*:--modules-folder=v yarn/*:--mutex=v yarn/*:--network-concurrency=v
  yarn/*:--network-timeout=v yarn/*:--otp=v yarn/*:--preferred-cache-folder=v yarn/*:--proxy=v
  yarn/*:--https-proxy=v yarn/*:--registry=v yarn/*:--use-yarnrc=v
  yarn/dlx:-p=p yarn/dlx:--package=p yarn/create:-p=w yarn/create:--package=w
  yarn/workspaces,foreach,dlx:-p=p
  yarn/workspaces,foreach,dlx:--package=p
  yarn/workspaces,foreach:--include=v yarn/workspaces,foreach:--exclude=v
  yarn/workspaces,foreach:--from=v yarn/workspaces,foreach:-j=v yarn/workspaces,foreach:--jobs=v
  bun/add:--cwd=d bun/add:--backend=v bun/add:--ca=v bun/add:--cafile=v
  bun/add:--cache-dir=v bun/add:--registry=v bun/add:--concurrent-scripts=v
  bun/add:--network-concurrency=v bun/add:--omit=v bun/add:--linker=v
  bun/add:--minimum-release-age=v bun/add:--cpu=v bun/add:--os=v bun/add:-F=v
  bun/add:--filter=v
  bun/a:--cwd=d bun/a:--backend=v bun/a:--ca=v bun/a:--cafile=v bun/a:--cache-dir=v
  bun/a:--registry=v bun/a:--concurrent-scripts=v bun/a:--network-concurrency=v
  bun/a:--omit=v bun/a:--linker=v bun/a:--minimum-release-age=v bun/a:--cpu=v bun/a:--os=v
  bun/a:-F=v bun/a:--filter=v
  bun/install:--cwd=d bun/install:--backend=v bun/install:--ca=v bun/install:--cafile=v
  bun/install:--cache-dir=v bun/install:--registry=v bun/install:--concurrent-scripts=v
  bun/install:--network-concurrency=v bun/install:--omit=v bun/install:--linker=v
  bun/install:--minimum-release-age=v bun/install:--cpu=v bun/install:--os=v
  bun/install:-F=v bun/install:--filter=v
  bun/i:--cwd=d bun/i:--backend=v bun/i:--ca=v bun/i:--cafile=v bun/i:--cache-dir=v
  bun/i:--registry=v bun/i:--concurrent-scripts=v bun/i:--network-concurrency=v
  bun/i:--omit=v bun/i:--linker=v bun/i:--minimum-release-age=v bun/i:--cpu=v bun/i:--os=v
  bun/i:-F=v bun/i:--filter=v
  bun/update:--cwd=d bun/update:--backend=v bun/update:--ca=v bun/update:--cafile=v
  bun/update:--cache-dir=v bun/update:--registry=v bun/update:--concurrent-scripts=v
  bun/update:--network-concurrency=v bun/update:--omit=v bun/update:--linker=v
  bun/update:--minimum-release-age=v bun/update:--cpu=v bun/update:--os=v bun/update:-F=v
  bun/update:--filter=v
  bun/x:-p=p bun/x:--package=p bunx/*:-p=p bunx/*:--package=p
  pip/*:--python=v pip/*:--log=v pip/*:--keyring-provider=v pip/*:--proxy=v pip/*:--retries=v
  pip/*:--timeout=v pip/*:--exists-action=v pip/*:--trusted-host=v pip/*:--cert=v
  pip/*:--client-cert=v pip/*:--cache-dir=v pip/*:--use-feature=v pip/*:--use-deprecated=v
  pip/*:--resume-retries=v
  pip/install:-r=v pip/install:--requirement=v pip/install:-c=v pip/install:--constraint=v
  pip/install:--build-constraint=v pip/install:--requirements-from-script=v
  pip/install:-e=p pip/install:--editable=p pip/install:-t=d pip/install:--target=d
  pip/install:--platform=v pip/install:--python-version=v pip/install:--implementation=v
  pip/install:--abi=v pip/install:--root=d pip/install:--prefix=d pip/install:--src=v
  pip/install:--upgrade-strategy=v pip/install:-C=v pip/install:--config-settings=v
  pip/install:--progress-bar=v pip/install:--root-user-action=v pip/install:--report=v
  pip/install:--group=v pip/install:--all-releases=v pip/install:--only-final=v
  pip/install:--no-binary=v pip/install:--only-binary=v pip/install:-i=v
  pip/install:--index-url=v pip/install:--extra-index-url=v pip/install:-f=v
  pip/install:--find-links=v pip/install:--uploaded-prior-to=v
  uv/*:--cache-dir=v uv/*:--color=v uv/*:--allow-insecure-host=v uv/*:--directory=d
  uv/*:--project=d uv/*:--config-file=v uv/*:-p=v uv/*:--python=v
  uv/*:-i=v uv/*:--index=v uv/*:--default-index=v uv/*:--index-url=v uv/*:--extra-index-url=v
  uv/*:-f=v uv/*:--find-links=v uv/*:--index-strategy=v uv/*:--keyring-provider=v
  uv/*:-P=v uv/*:--upgrade-package=v uv/*:--resolution=v uv/*:--prerelease=v
  uv/*:--fork-strategy=v uv/*:--exclude-newer=v uv/*:--exclude-newer-package=v
  uv/*:--no-sources-package=v uv/*:--reinstall-package=v uv/*:--link-mode=v
  uv/*:-C=v uv/*:--config-setting=v uv/*:--config-settings-package=v
  uv/*:--no-build-isolation-package=v uv/*:--no-build-package=v uv/*:--no-binary-package=v
  uv/*:--refresh-package=v uv/*:-c=v uv/*:--constraints=v uv/*:--overrides=v uv/*:--excludes=v
  uv/*:-b=v uv/*:--build-constraints=v uv/*:--python-platform=v uv/*:--torch-backend=v
  uv/*:--env-file=v
  uv/add:-r=v uv/add:--requirements=v uv/add:-m=v uv/add:--marker=v uv/add:--optional=v
  uv/add:--group=v uv/add:--bounds=v uv/add:--rev=v uv/add:--tag=v uv/add:--branch=v
  uv/add:--extra=v uv/add:--package=v uv/add:--script=v uv/add:--no-install-package=v
  uv/pip,install:-r=v uv/pip,install:--requirements=v uv/pip,install:-e=p
  uv/pip,install:--editable=p uv/pip,install:--extra=v uv/pip,install:--group=v
  uv/pip,install:-t=d uv/pip,install:--target=d uv/pip,install:--prefix=d
  uv/pip,install:--no-binary=v uv/pip,install:--only-binary=v uv/pip,install:--python-version=v
  uv/tool,install:-w=w uv/tool,install:--with=w uv/tool,install:--with-requirements=v
  uv/tool,install:--with-editable=w uv/tool,install:--with-executables-from=w
  uv/tool,run:--from=p uv/tool,run:-w=w uv/tool,run:--with=w uv/tool,run:--with-editable=v
  uv/tool,run:--with-requirements=v
  uvx/*:--from=p uvx/*:-w=w uvx/*:--with=w uvx/*:--with-editable=v uvx/*:--with-requirements=v
  uvx/*:-c=v uvx/*:--constraints=v uvx/*:-b=v uvx/*:--build-constraints=v uvx/*:--overrides=v
  uvx/*:--env-file=v uvx/*:--python-platform=v uvx/*:--torch-backend=v uvx/*:--index=v
  uvx/*:--default-index=v uvx/*:-i=v uvx/*:--index-url=v uvx/*:--extra-index-url=v uvx/*:-f=v
  uvx/*:--find-links=v uvx/*:--index-strategy=v uvx/*:--keyring-provider=v uvx/*:-P=v
  uvx/*:--upgrade-package=v uvx/*:--resolution=v uvx/*:--prerelease=v uvx/*:--fork-strategy=v
  uvx/*:--exclude-newer=v uvx/*:--exclude-newer-package=v uvx/*:--no-sources-package=v
  uvx/*:--reinstall-package=v uvx/*:--link-mode=v uvx/*:-C=v uvx/*:--config-setting=v
  uvx/*:--config-settings-package=v uvx/*:--no-build-isolation-package=v
  uvx/*:--no-build-package=v uvx/*:--no-binary-package=v uvx/*:--cache-dir=v
  uvx/*:--refresh-package=v uvx/*:-p=v uvx/*:--python=v uvx/*:--color=v
  uvx/*:--allow-insecure-host=v uvx/*:--directory=d uvx/*:--project=d uvx/*:--config-file=v
  pipx/run:--spec=p pipx/run:--with=w pipx/*:--python=v pipx/*:--fetch-python=v pipx/*:-i=v
  pipx/*:--index-url=v pipx/*:--pip-args=v pipx/*:--backend=v pipx/install:--suffix=v
  pipx/install:--preinstall=w pipx/inject:-r=v pipx/inject:--requirement=v
  poetry/*:-C=d poetry/*:--directory=d poetry/*:-P=d poetry/*:--project=d
  poetry/add:-G=v poetry/add:--group=v poetry/add:-E=v poetry/add:--extras=v
  poetry/add:--optional=b poetry/add:--python=v poetry/add:--platform=v poetry/add:--markers=v
  poetry/add:--source=v
  pipenv/*:--python=v pipenv/*:--pypi-mirror=v pipenv/install:--categories=v
  pipenv/install:--extra-pip-args=v pipenv/install:-r=v pipenv/install:--requirements=v
  pipenv/install:-e=p pipenv/install:--editable=p pipenv/install:-i=v pipenv/install:--index=v
  cargo/*:--color=v cargo/*:--config=v cargo/*:-Z=v cargo/*:-C=d cargo/*:--explain=v
  cargo/*:--lockfile-path=v cargo/*:-F=v cargo/*:--features=v cargo/*:--registry=v
  cargo/*:--git=v cargo/*:--branch=v cargo/*:--tag=v cargo/*:--rev=v cargo/*:--path=v
  cargo/install:--version=V cargo/install:--vers=V cargo/install:--index=v
  cargo/install:--root=d cargo/install:--message-format=v cargo/install:-j=v
  cargo/install:--jobs=v cargo/install:--profile=v cargo/install:--target-dir=v
  cargo/add:--rename=v cargo/add:--manifest-path=v cargo/add:--base=v cargo/add:--target=v
  cargo/add:--vers=V cargo/add:--version=V
  go/*:-C=d go/*:-p=v go/*:-covermode=v go/*:-coverpkg=v go/*:-asmflags=v go/*:-buildmode=v
  go/*:-compiler=v go/*:-gccgoflags=v go/*:-gcflags=v go/*:-installsuffix=v go/*:-ldflags=v
  go/*:-mod=v go/*:-modfile=v go/*:-overlay=v go/*:-pgo=v go/*:-pkgdir=v go/*:-tags=v
  go/*:-toolexec=v go/run:-exec=v
  gem/*:--config-file=v
  gem/install:-v=V gem/install:--version=V gem/install:--platform=v gem/install:-i=d
  gem/install:--install-dir=d gem/install:-n=v gem/install:--bindir=v gem/install:--build-root=v
  gem/install:-P=v gem/install:--trust-policy=v gem/install:--without=v gem/install:-B=v
  gem/install:--bulk-threshold=v gem/install:-s=v gem/install:--source=v
  bundle/add:-v=V bundle/add:--version=V bundle/add:-g=v bundle/add:--group=v bundle/add:-s=v
  bundle/add:--source=v bundle/add:-r=v bundle/add:--require=v bundle/add:--path=v
  bundle/add:--git=v bundle/add:--github=v bundle/add:--branch=v bundle/add:--ref=v
  bundle/add:--glob=v
  dotnet/add,package:-v=V dotnet/add,package:--version=V dotnet/add,package:-f=v
  dotnet/add,package:--framework=v dotnet/add,package:-s=v dotnet/add,package:--source=v
  dotnet/add,package:--package-directory=v dotnet/add,*,package:-v=V
  dotnet/add,*,package:--version=V dotnet/add,*,package:-f=v dotnet/add,*,package:--framework=v
  dotnet/add,*,package:-s=v dotnet/add,*,package:--source=v
  dotnet/add,*,package:--package-directory=v
  dotnet/package,add:-v=V dotnet/package,add:--version=V dotnet/package,add:-f=v
  dotnet/package,add:--framework=v dotnet/package,add:-s=v dotnet/package,add:--source=v
  dotnet/package,add:--package-directory=v dotnet/package,add:--project=v
  dotnet/package,update:-v=v dotnet/package,update:--verbosity=v dotnet/package,update:--project=v
  dotnet/tool,install:--version=V dotnet/tool,install:-v=v dotnet/tool,install:--verbosity=v
  dotnet/tool,install:-a=v dotnet/tool,install:--arch=v dotnet/tool,install:--add-source=v
  dotnet/tool,install:--configfile=v dotnet/tool,install:--framework=v
  dotnet/tool,install:--source=v dotnet/tool,install:--tool-manifest=v
  dotnet/tool,install:--tool-path=d
  dotnet/tool,update:--version=V dotnet/tool,update:-v=v dotnet/tool,update:--verbosity=v
  dotnet/tool,update:-a=v dotnet/tool,update:--arch=v dotnet/tool,update:--add-source=v
  dotnet/tool,update:--configfile=v dotnet/tool,update:--framework=v
  dotnet/tool,update:--source=v dotnet/tool,update:--tool-manifest=v
  dotnet/tool,update:--tool-path=d
  mvn/*:-f=v mvn/*:--file=v mvn/*:-s=v mvn/*:--settings=v mvn/*:-gs=v mvn/*:--global-settings=v
  mvn/*:-t=v mvn/*:--toolchains=v mvn/*:-gt=v mvn/*:--global-toolchains=v mvn/*:-P=v
  mvn/*:--activate-profiles=v mvn/*:-pl=v mvn/*:--projects=v mvn/*:-rf=v mvn/*:--resume-from=v
  mvn/*:-T=v mvn/*:--threads=v mvn/*:-l=v mvn/*:--log-file=v mvn/*:-b=v mvn/*:--builder=v
  mvn/*:-D=v mvn/*:--define=v
  python/*:-W=v python/*:-X=v python/*:--check-hash-based-pycs=v
  env/*:-C=d env/*:--chdir=d env/*:-u=v env/*:--unset=v env/*:-P=v
'

# Every long option of a parser that takes a unique abbreviation of one (`x`
# below): pip's optparse, pipx's argparse and gem's OptionParser read
# `--pyth` as `--python` and `--vers` as `--version`. Booleans are listed too,
# since an abbreviation is unique only among all of them. From each help text
# named above (pipx run's, measured against its parser).
SAFEDEPS_G_LONG_OPTIONS='
  pip/*:--cache-dir pip/*:--cert pip/*:--client-cert pip/*:--debug
  pip/*:--disable-pip-version-check pip/*:--exists-action pip/*:--help
  pip/*:--isolated pip/*:--keyring-provider pip/*:--log pip/*:--no-cache-dir
  pip/*:--no-color pip/*:--no-input pip/*:--proxy pip/*:--python
  pip/*:--quiet pip/*:--require-virtualenv pip/*:--resume-retries
  pip/*:--retries pip/*:--timeout pip/*:--trusted-host pip/*:--use-deprecated
  pip/*:--use-feature pip/*:--verbose pip/*:--version pip/install:--abi
  pip/install:--all-releases pip/install:--break-system-packages
  pip/install:--build-constraint pip/install:--check-build-dependencies
  pip/install:--compile pip/install:--config-settings
  pip/install:--constraint pip/install:--dry-run pip/install:--editable
  pip/install:--extra-index-url pip/install:--find-links
  pip/install:--force-reinstall pip/install:--group
  pip/install:--ignore-installed pip/install:--ignore-requires-python
  pip/install:--implementation pip/install:--index-url
  pip/install:--no-binary pip/install:--no-build-isolation
  pip/install:--no-clean pip/install:--no-compile pip/install:--no-deps
  pip/install:--no-index pip/install:--no-warn-conflicts
  pip/install:--no-warn-script-location pip/install:--only-binary
  pip/install:--only-final pip/install:--platform pip/install:--pre
  pip/install:--prefer-binary pip/install:--prefix pip/install:--progress-bar
  pip/install:--python-version pip/install:--report
  pip/install:--require-hashes pip/install:--requirement
  pip/install:--requirements-from-script pip/install:--root
  pip/install:--root-user-action pip/install:--src pip/install:--target
  pip/install:--upgrade pip/install:--upgrade-strategy
  pip/install:--uploaded-prior-to pip/install:--user pipx/run:--help
  pipx/run:--quiet pipx/run:--verbose pipx/run:--global pipx/run:--no-cache
  pipx/run:--path pipx/run:--pypackages pipx/run:--with pipx/run:--spec
  pipx/run:--python pipx/run:--fetch-python pipx/run:--fetch-missing-python
  pipx/run:--system-site-packages pipx/run:--index-url pipx/run:--editable
  pipx/run:--pip-args pipx/run:--backend pipx/install:--help
  pipx/install:--quiet pipx/install:--verbose pipx/install:--global
  pipx/install:--include-deps pipx/install:--force pipx/install:--suffix
  pipx/install:--python pipx/install:--fetch-python
  pipx/install:--fetch-missing-python pipx/install:--preinstall
  pipx/install:--system-site-packages pipx/install:--index-url
  pipx/install:--editable pipx/install:--pip-args pipx/install:--backend
  pipx/inject:--help pipx/inject:--quiet pipx/inject:--verbose
  pipx/inject:--global pipx/inject:--requirement pipx/inject:--include-apps
  pipx/inject:--include-deps pipx/inject:--system-site-packages
  pipx/inject:--index-url pipx/inject:--editable pipx/inject:--pip-args
  pipx/inject:--force pipx/inject:--with-suffix pipx/inject:--backend
  gem/install:--backtrace gem/install:--bindir gem/install:--both
  gem/install:--build-flags gem/install:--build-root
  gem/install:--bulk-threshold gem/install:--clear-sources
  gem/install:--config-file gem/install:--conservative gem/install:--debug
  gem/install:--default gem/install:--development
  gem/install:--development-all gem/install:--document
  gem/install:--no-document gem/install:--env-shebang
  gem/install:--no-env-shebang gem/install:--explain gem/install:--file
  gem/install:--force gem/install:--no-force gem/install:--format-executable
  gem/install:--no-format-executable gem/install:--help
  gem/install:--http-proxy gem/install:--no-http-proxy
  gem/install:--ignore-dependencies gem/install:--install-dir
  gem/install:--local gem/install:--lock gem/install:--no-lock
  gem/install:--minimal-deps gem/install:--norc gem/install:--platform
  gem/install:--post-install-message gem/install:--no-post-install-message
  gem/install:--prerelease gem/install:--no-prerelease gem/install:--quiet
  gem/install:--remote gem/install:--silent gem/install:--source
  gem/install:--suggestions gem/install:--no-suggestions
  gem/install:--trust-policy gem/install:--update-sources
  gem/install:--no-update-sources gem/install:--user-install
  gem/install:--no-user-install gem/install:--vendor gem/install:--verbose
  gem/install:--no-verbose gem/install:--version gem/install:--without
  gem/install:--wrappers gem/install:--no-wrappers
'

# How each manager's parser reads an option word, beyond `--name=value`:
#   a  a one-letter option carries its value attached (`-tdir`, `-v1.0`)
#   c  `:` separates a value as well as `=` (`--version:1.0`)
#   s  options end at the first operand (Go's flag package)
#   e  a word starting with `-` is never a value (clap, argparse, optparse,
#      OptionParser and the .NET parser treat it as the next option)
#   x  a unique abbreviation of a long option is that option
#      (SAFEDEPS_G_LONG_OPTIONS)
SAFEDEPS_G_PARSERS='
  pnpm: yarn:e bun:e pip:ax uv:ae uvx:ae pipx:aex poetry:e pipenv:e cargo:ae go:s
  gem:aex bundle:e dotnet:ce mvn:a python:a env:a pnpx:
'
# The tables are searched with =~ as one line (safedeps_g_one_line).
safedeps_g_one_line SAFEDEPS_G_COMMANDS
safedeps_g_one_line SAFEDEPS_G_VALUE_OPTIONS
safedeps_g_one_line SAFEDEPS_G_LONG_OPTIONS
safedeps_g_one_line SAFEDEPS_G_PARSERS

# The class of <option> for <family> in command scope <path>, then in `*`:
# SAFEDEPS_G_VALUE, status 1 when it takes no value. The command comes first:
# what a command reads is the command's (`bun x -p pkg` names the package
# where bun's runtime `-p` printed), and `*` only fills in what it does not
# say.
safedeps_manager_option_class() {
  local family="$1" path="$2" opt="$3" re
  # Go reads `--flag` as `-flag`.
  [[ "${family}" != go || "${opt}" != --?* ]] || opt="${opt#-}"
  safedeps_ere_literal "${opt}"
  if [[ -n "${path}" ]]; then
    re=" ${family}/${path//\*/[*]}:${SAFEDEPS_G_ERE}=([a-zA-Z])"
    if [[ "${SAFEDEPS_G_VALUE_OPTIONS}" =~ ${re} ]]; then
      SAFEDEPS_G_VALUE="${BASH_REMATCH[1]}"
      return 0
    fi
  fi
  re=" ${family}/[*]:${SAFEDEPS_G_ERE}=([a-zA-Z])"
  [[ "${SAFEDEPS_G_VALUE_OPTIONS}" =~ ${re} ]] || return 1
  SAFEDEPS_G_VALUE="${BASH_REMATCH[1]}"
}

# The long option <opt> abbreviates for <family> in scope <path>, as
# SAFEDEPS_G_VALUE: itself when it is one, the one option it is a unique prefix
# of, or itself when it is a prefix of none or of several.
safedeps_manager_long_option() {
  local family="$1" path="$2" opt="$3" scopes re first
  SAFEDEPS_G_VALUE="${opt}"
  safedeps_ere_literal "${opt}"
  scopes="[*]"
  [[ -z "${path}" ]] || scopes="([*]|${path//\*/[*]})"
  re=" ${family}/${scopes}:${SAFEDEPS_G_ERE}( |$)"
  [[ "${SAFEDEPS_G_LONG_OPTIONS}" =~ ${re} ]] && return 0
  re=" ${family}/${scopes}:(${SAFEDEPS_G_ERE}[^ ]*)"
  [[ "${SAFEDEPS_G_LONG_OPTIONS}" =~ ${re} ]] || return 0
  first="${BASH_REMATCH[2]}"
  [[ -n "${first}" ]] || first="${BASH_REMATCH[1]}"
  re=" ${family}/${scopes}:${SAFEDEPS_G_ERE}[^ ]* (.* )?${family}/${scopes}:${SAFEDEPS_G_ERE}[^ ]*"
  [[ "${SAFEDEPS_G_LONG_OPTIONS}" =~ ${re} ]] && return 0
  SAFEDEPS_G_VALUE="${first}"
}

# What <family> does with the command path <path>: SAFEDEPS_G_VALUE is the kind
# when the path is complete, `more` when a longer path starts with it, and
# status 1 when no path does. A literal word is preferred to `*`, so
# `dotnet add package X` is not `add <project> package`.
safedeps_manager_command() {
  local family="$1" path re
  safedeps_ere_literal "$2"
  path="${SAFEDEPS_G_ERE}"
  re=" ${family}:${path}=([a-z]+)"
  if [[ "${SAFEDEPS_G_COMMANDS}" =~ ${re} ]]; then
    SAFEDEPS_G_VALUE="${BASH_REMATCH[1]}"
    return 0
  fi
  re=" ${family}:${path},[^ =]*="
  if [[ "${SAFEDEPS_G_COMMANDS}" =~ ${re} ]]; then
    SAFEDEPS_G_VALUE=more
    return 0
  fi
  return 1
}

# npx's first pass over its arguments (bin/npx-cli.js, npm 11.19.0), ahead of
# npm's: an option it does not know as a switch takes the next word unless that
# word starts with `-`, `-p` and `--shell` are renamed, npm's shorthands are
# expanded, and `--` goes in front of the first positional word. npm then reads
# the result as `npm exec ...` (nopt). Sets SAFEDEPS_G_NPX_WORDS and
# SAFEDEPS_G_NPX_AT (the index each word came from).
safedeps_npx_first_pass() {
  local -a w=("$@") at=() exp=()
  local i j n arg key v hasv steps=0
  for (( i = 0; i < ${#w[@]}; i++ )); do at[i]=${i}; done
  i=0
  while (( i < ${#w[@]} )); do
    (( ++steps <= 4 * ${#w[@]} + 64 )) || return 1
    arg="${w[i]}"
    [[ "${arg}" != -- ]] || break
    if [[ "${arg}" != -* ]]; then
      w=("${w[@]:0:i}" "--" "${w[@]:i}")
      at=("${at[@]:0:i}" "${at[i]}" "${at[@]:i}")
      break
    fi
    key="${arg}"
    while [[ "${key}" == -* ]]; do key="${key#-}"; done
    hasv=false v=""
    if [[ "${key}" == *=* ]]; then hasv=true v="${key#*=}" key="${key%%=*}"; fi
    case "${key}" in
      p) w[i]="--package${v:+=${v}}"; [[ "${hasv}" == false ]] || w[i]="--package=${v}" ;;
      shell) w[i]="--script-shell"; [[ "${hasv}" == false ]] || w[i]="--script-shell=${v}" ;;
      no-install) w[i]="--yes=false" ;;
      *)
        if safedeps_npm_lookup "${key}" "${SAFEDEPS_G_NPM_SHORTHANDS}"; then
          exp=()
          v="${SAFEDEPS_G_VALUE}"
          while [[ -n "${v}" ]]; do exp+=("${v%%,*}"); [[ "${v}" == *,* ]] && v="${v#*,}" || v=""; done
          [[ "${hasv}" == false ]] || exp+=("${arg#*=}")
          n=${#exp[@]}
          w=("${w[@]:0:i}" "${exp[@]+"${exp[@]}"}" "${w[@]:i+1}")
          v="${at[i]}"
          at=("${at[@]:0:i}" "${at[@]:i+1}")
          for (( j = 0; j < n; j++ )); do at=("${at[@]:0:i}" "${v}" "${at[@]:i}"); done
          continue
        fi
        ;;
    esac
    # A switch takes no value: npm's Booleans and npx's own.
    if [[ "${hasv}" == false ]]; then
      case " no-install quiet q version v help h always-spawn ignore-existing shell-auto-fallback " in
        *" ${key} "*) ;;
        *)
          safedeps_npm_lookup "${key}" "${SAFEDEPS_G_NPM_OPTIONS}" && [[ "${SAFEDEPS_G_VALUE}" == b* ]] \
            || {
              case " package p call c shell npm node-arg n cache userconfig " in
                *" ${key} "*) i=$(( i + 1 )) ;;
                *) (( i + 1 < ${#w[@]} )) && [[ "${w[i+1]}" != -* ]] && i=$(( i + 1 )) ;;
              esac
            }
          ;;
      esac
    fi
    i=$(( i + 1 ))
  done
  SAFEDEPS_G_NPX_WORDS=("${w[@]+"${w[@]}"}") SAFEDEPS_G_NPX_AT=("${at[@]+"${at[@]}"}")
}

# Whether <word>, or the last part of it when it is a path, is <name>, matched
# whole and ignoring case, as the recognizers match it: macOS volumes ignore
# case, so `PIP`, `NPM` and `ENV` run pip, npm and env there. With no <name>,
# the manager the word names goes to SAFEDEPS_G_VALUE (the family, lowercase,
# from SAFEDEPS_G_EXECUTABLES; empty for none), and the answer is whether it
# names one. The readers that compare a word with a manager's name ask here, so
# none keeps a spelling of its own: a reader that matched case left `PIP install
# evil==6.6.6` with no spec to check while the recognizers called it an install.
safedeps_manager_name() {
  local base="${1##*/}" rest entry nocase=false rc=1
  shopt -q nocasematch && nocase=true
  shopt -s nocasematch
  if [[ $# -gt 1 ]]; then
    [[ "${base}" == "$2" ]] && rc=0
  else
    SAFEDEPS_G_VALUE=""
    if [[ "${base}" =~ ^(${SAFEDEPS_G_EXECUTABLES})$ ]]; then
      rest="${SAFEDEPS_G_EXECUTABLES}|"
      while [[ -n "${rest}" ]]; do
        entry="${rest%%|*}" rest="${rest#*|}"
        if [[ "${base}" =~ ^(${entry})$ ]]; then
          entry="${entry%%\[*}"
          [[ "${entry}" != py ]] || entry=python
          SAFEDEPS_G_VALUE="${entry}" rc=0
          break
        fi
      done
    fi
  fi
  [[ "${nocase}" == true ]] || shopt -u nocasematch
  return "${rc}"
}

# One statement's words as its package manager reads them. The arguments are
# the statement's words, one shell word each (the lexer's pieces view, quotes
# removed). Sets:
#   SAFEDEPS_G_M_FAMILY  the manager (npm, npx, pnpm, ..., none)
#   SAFEDEPS_G_M_KIND    install, link, runner, create, or none for a statement
#                        that installs nothing (no manager, or a command that
#                        is not one of the manager's installs or runners)
#   SAFEDEPS_G_M_ROLE    one role per word: - (before the manager, or nothing
#                        to the manager), m (the manager), c (a command word),
#                        g (an option), v d V p w (an option value, by class),
#                        o (an operand the command installs), r (the package a
#                        runner runs), C (a create's initializer), a (a runner's
#                        program and its arguments), D (maven's artifact define)
#   SAFEDEPS_G_M_TEXT    a role's text where it is not the whole word: the
#                        value of `--name=value`, `-xvalue`, `--name:value`
#   SAFEDEPS_G_M_LOCALBIN  true for a runner that runs a binary the project
#                        already has without fetching (npx, npm exec, bunx)
# No process is started: this runs once per statement.
safedeps_manager_read() {
  local ambiguous
  SAFEDEPS_G_M_AMBIGUOUS=-1 SAFEDEPS_G_M_FORCE_VALUE=-1
  SAFEDEPS_G_M_OTHER=false SAFEDEPS_G_M_OTHER_SEEN=false
  safedeps_manager_read_once "$@"
  # An option one version of the manager reads as a switch and another as an
  # option with a value (class b): the other version's reading is judged too.
  if [[ "${SAFEDEPS_G_M_OTHER_SEEN}" == true ]]; then
    SAFEDEPS_G_M_OTHER=true
    safedeps_manager_read_union "$@"
    SAFEDEPS_G_M_OTHER=false
  fi
  (( SAFEDEPS_G_M_AMBIGUOUS >= 0 )) || return 0
  # An option the table does not know, and then a word that is one of the
  # manager's commands (`bun --filter x add evil@1.0.0`, where `bun x` is a
  # runner): the manager may read the word as the option's value or as its
  # command, so both readings are judged, as the union.
  ambiguous="${SAFEDEPS_G_M_AMBIGUOUS}"
  SAFEDEPS_G_M_FORCE_VALUE="${ambiguous}" SAFEDEPS_G_M_OTHER_SEEN=false
  safedeps_manager_read_union "$@"
  if [[ "${SAFEDEPS_G_M_OTHER_SEEN}" == true ]]; then
    SAFEDEPS_G_M_OTHER=true
    safedeps_manager_read_union "$@"
    SAFEDEPS_G_M_OTHER=false
  fi
  SAFEDEPS_G_M_FORCE_VALUE=-1
  return 0
}

# Reads the statement again and keeps the union with the reading already made.
# A role either reading gives a word that the other reads as nothing
# particular is kept: a package, a version that pins the operands, a
# directory. A statement that either reading takes for an install or a runner
# is one.
safedeps_manager_read_union() {
  local -a role=("${SAFEDEPS_G_M_ROLE[@]}") text=("${SAFEDEPS_G_M_TEXT[@]}")
  local kind="${SAFEDEPS_G_M_KIND}" localbin="${SAFEDEPS_G_M_LOCALBIN}" k
  safedeps_manager_read_once "$@"
  for (( k = 0; k < ${#role[@]}; k++ )); do
    case "${role[k]}:${SAFEDEPS_G_M_ROLE[k]}" in
      [orCpwDVd]:[-gcva]) SAFEDEPS_G_M_ROLE[k]="${role[k]}" SAFEDEPS_G_M_TEXT[k]="${text[k]}" ;;
    esac
  done
  [[ "${SAFEDEPS_G_M_KIND}" != none ]] || SAFEDEPS_G_M_KIND="${kind}"
  [[ "${localbin}" != true ]] || SAFEDEPS_G_M_LOCALBIN=true
  return 0
}

safedeps_manager_read_once() {
  local -a w=("$@")
  local n=$# i=0 t family="" kind="" path="" traits="" endopts=false named=false
  local opt val cls j k unknown=false
  SAFEDEPS_G_M_FAMILY=none SAFEDEPS_G_M_KIND=none SAFEDEPS_G_M_LOCALBIN=false
  SAFEDEPS_G_M_ROLE=() SAFEDEPS_G_M_TEXT=()
  for (( j = 0; j < n; j++ )); do SAFEDEPS_G_M_ROLE[j]=-; SAFEDEPS_G_M_TEXT[j]=""; done

  # The command word: past grouping, reserved words, assignments, and the
  # prefixes the shell runs the command through (`command`, `exec`, and env
  # with its own options).
  while (( i < n )); do
    t="${w[i]}"
    while :; do
      case "${t}" in
        '('*|'{'*|'!'*|$'\002'*) t="${t:1}" ;;
        *) break ;;
      esac
    done
    case "${t}" in
      ''|then|do|else|elif|if|while|until|time|coproc|command|exec) i=$(( i + 1 )); continue ;;
    esac
    # macOS ships /usr/bin/command, which runs the builtin whatever case it
    # was called by, and /usr/bin/time.
    if safedeps_manager_name "${t}" command || safedeps_manager_name "${t}" time; then
      i=$(( i + 1 ))
      continue
    fi
    if [[ "${t}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then i=$(( i + 1 )); continue; fi
    if safedeps_manager_name "${t}" env; then
      i=$(( i + 1 ))
      while (( i < n )) && [[ "${w[i]}" == -?* ]]; do
        if [[ "${w[i]}" != *=* ]] && safedeps_manager_option_class env "" "${w[i]}"; then
          SAFEDEPS_G_M_ROLE[i]=g SAFEDEPS_G_M_ROLE[i+1]="${SAFEDEPS_G_VALUE}"
          i=$(( i + 2 ))
        else
          i=$(( i + 1 ))
        fi
      done
      continue
    fi
    break
  done
  (( i < n )) || return 0
  w[i]="${t}"
  safedeps_manager_name "${t}" || return 0
  family="${SAFEDEPS_G_VALUE}"
  SAFEDEPS_G_M_ROLE[i]=m
  i=$(( i + 1 ))

  # python reads its own options up to `-m <module>`; with pip as the module,
  # the rest is pip's. One-letter options cluster as getopt reads them: `-Im
  # pip` is `-I -m pip`, and `-Impip` is `-I -m pip` too, since an option that
  # takes a value takes the rest of its word when there is one. `-c` ends
  # python's options with a program, and so does the first operand (a script).
  if [[ "${family}" == python ]]; then
    while (( i < n )); do
      t="${w[i]}"
      SAFEDEPS_G_M_ROLE[i]=g
      if [[ "${t}" == --?* ]]; then
        if [[ "${t}" != *=* ]] && safedeps_manager_option_class python "" "${t}"; then
          SAFEDEPS_G_M_ROLE[i+1]=v i=$(( i + 1 ))
        fi
        i=$(( i + 1 ))
        continue
      fi
      if [[ "${t}" != -?* || "${t}" == -- ]]; then
        SAFEDEPS_G_M_ROLE[i]=-
        return 0
      fi
      for (( k = 1; k < ${#t}; k++ )); do
        case "${t:k:1}" in
          c) return 0 ;;
          m)
            val="${t:k+1}"
            if [[ -z "${val}" ]]; then
              i=$(( i + 1 ))
              val="${w[i]:-}"
            fi
            safedeps_manager_name "${val}" pip || return 0
            SAFEDEPS_G_M_ROLE[i]=m i=$(( i + 1 )) family=pip
            break 2
            ;;
        esac
        if safedeps_manager_option_class python "" "-${t:k:1}"; then
          if (( k + 1 == ${#t} )); then
            SAFEDEPS_G_M_ROLE[i+1]=v i=$(( i + 1 ))
          fi
          break
        fi
      done
      i=$(( i + 1 ))
    done
    [[ "${family}" == pip ]] || return 0
  fi
  SAFEDEPS_G_M_FAMILY="${family}"

  case "${family}" in
    npm|npx) safedeps_manager_read_npm "${i}" "${w[@]}"; return ;;
    mvn) safedeps_manager_read_mvn "${i}" "${w[@]}"; return ;;
  esac
  # cargo's toolchain override comes first (`cargo +nightly install`).
  if [[ "${family}" == cargo && "${w[i]:-}" == +* ]]; then SAFEDEPS_G_M_ROLE[i]=g; i=$(( i + 1 )); fi

  case "${SAFEDEPS_G_PARSERS}" in *" ${family}:"*) traits="${SAFEDEPS_G_PARSERS#* "${family}":}"; traits="${traits%% *}" ;; esac
  case "${family}" in bunx) SAFEDEPS_G_M_LOCALBIN=true ;; esac
  if safedeps_manager_command "${family}" "" && [[ "${SAFEDEPS_G_VALUE}" != more ]]; then
    kind="${SAFEDEPS_G_VALUE}"
  fi

  while (( i < n )); do
    t="${w[i]}"
    if [[ "${endopts}" == false && "${t}" =~ ^--+$ ]]; then
      SAFEDEPS_G_M_ROLE[i]=g endopts=true i=$(( i + 1 ))
      continue
    fi
    if [[ "${endopts}" == false && "${t}" == -?* ]]; then
      SAFEDEPS_G_M_ROLE[i]=g
      opt="${t}" val="" cls="" unknown=false
      if [[ "${t}" == --*=* || ( "${t}" == -[!-]*=* ) ]]; then
        opt="${t%%=*}" val="${t#*=}"
      elif [[ "${traits}" == *c* && "${t}" == -*:* ]]; then
        opt="${t%%:*}" val="${t#*:}"
      fi
      if [[ "${traits}" == *x* && "${opt}" == --?* ]]; then
        safedeps_manager_long_option "${family}" "${path}" "${opt}"
        if [[ "${SAFEDEPS_G_VALUE}" != "${opt}" ]]; then
          [[ "${opt}" == "${t}" ]] && t="${SAFEDEPS_G_VALUE}"
          opt="${SAFEDEPS_G_VALUE}"
        fi
      fi
      if [[ "${opt}" != "${t}" ]]; then
        # The value is in the word.
        # A version that reads the option as a switch refuses a value in
        # its word, so only the value reading installs anything.
        if safedeps_manager_option_class "${family}" "${path}" "${opt}"; then
          SAFEDEPS_G_M_ROLE[i]="${SAFEDEPS_G_VALUE/#b/v}" SAFEDEPS_G_M_TEXT[i]="${val}"
        fi
      elif safedeps_manager_option_class "${family}" "${path}" "${t}"; then
        cls="${SAFEDEPS_G_VALUE}"
        if [[ "${cls}" == b ]]; then
          SAFEDEPS_G_M_OTHER_SEEN=true cls=v
          [[ "${SAFEDEPS_G_M_OTHER}" == false ]] || cls=""
        fi
        if [[ -n "${cls}" ]] && (( i + 1 < n )) && ! [[ "${traits}" == *e* && "${w[i+1]}" == -?* ]]; then
          SAFEDEPS_G_M_ROLE[i+1]="${cls}"
          [[ "${cls}" != p ]] || named=true
          i=$(( i + 1 ))
        fi
      elif [[ "${traits}" == *a* && "${t}" =~ ^-[A-Za-z0-9]. ]] \
          && safedeps_manager_option_class "${family}" "${path}" "${t:0:2}"; then
        SAFEDEPS_G_M_ROLE[i]="${SAFEDEPS_G_VALUE/#b/v}" SAFEDEPS_G_M_TEXT[i]="${t:2}"
      else
        unknown=true
      fi
      [[ "${SAFEDEPS_G_M_ROLE[i]}" != p ]] || named=true
      i=$(( i + 1 ))
      continue
    fi
    # A positional word: the command path first, then what the command reads.
    if [[ -z "${kind}" ]]; then
      if (( i == SAFEDEPS_G_M_FORCE_VALUE )); then
        SAFEDEPS_G_M_ROLE[i]=v unknown=false i=$(( i + 1 ))
        continue
      fi
      if [[ "${unknown}" == true ]] && (( SAFEDEPS_G_M_AMBIGUOUS < 0 && SAFEDEPS_G_M_FORCE_VALUE < 0 )); then
        SAFEDEPS_G_M_AMBIGUOUS=${i}
      fi
      SAFEDEPS_G_M_ROLE[i]=c
      if safedeps_manager_command "${family}" "${path:+${path},}${t}"; then
        path="${path:+${path},}${t}"
      elif safedeps_manager_command "${family}" "${path:+${path},}*"; then
        path="${path:+${path},}*"
      elif [[ "${unknown}" == true ]]; then
        # An option the table does not know, and then a word that is no
        # command: the manager may read the word as that option's value, and
        # a table that misses a value option must not hide the install after
        # it. If the manager reads the word as its command instead, that
        # command is no install of its, so reading it as a value adds nothing.
        SAFEDEPS_G_M_ROLE[i]=v unknown=false i=$(( i + 1 ))
        continue
      else
        SAFEDEPS_G_M_ROLE[i]=-
        return 0
      fi
      [[ "${SAFEDEPS_G_VALUE}" == more ]] || kind="${SAFEDEPS_G_VALUE}"
      case "${family}:${path}" in bun:x) SAFEDEPS_G_M_LOCALBIN=true ;; esac
      unknown=false i=$(( i + 1 ))
      continue
    fi
    [[ "${traits}" != *s* ]] || endopts=true
    case "${kind}" in
      install) SAFEDEPS_G_M_ROLE[i]=o ;;
      runner|create)
        # The package a runner fetches is its first operand, unless an
        # option named it; everything after is the program's.
        if [[ "${named}" == false ]]; then
          if [[ "${kind}" == create ]]; then
            SAFEDEPS_G_M_ROLE[i]=C
          elif [[ "${family}" == go && "${t}" != *@* ]]; then
            # go run fetches by name only a package with a version suffix
            # (`go help run`); any other is local code.
            SAFEDEPS_G_M_ROLE[i]=a
          else
            SAFEDEPS_G_M_ROLE[i]=r
          fi
        else
          SAFEDEPS_G_M_ROLE[i]=a
        fi
        for (( j = i + 1; j < n; j++ )); do SAFEDEPS_G_M_ROLE[j]=a; done
        i=${n}
        break
        ;;
    esac
    i=$(( i + 1 ))
  done
  [[ -n "${kind}" ]] && SAFEDEPS_G_M_KIND="${kind}"
  return 0
}

# npm and npx, read with npm's own parser (safedeps_npm_read_args), npx after
# its first pass. <start> is the index of the first word after the manager.
safedeps_manager_read_npm() {
  local start="$1" k r
  local -a role=() text=()
  local kind localbin
  safedeps_manager_read_npm_once "$@" || return 1
  shift
  safedeps_npm_other_applies "${@:start+1}" || return 0
  # The union with the other npm's reading: a word either reading gives a
  # package role keeps it, and a statement either reads as an install is one.
  role=("${SAFEDEPS_G_M_ROLE[@]}") text=("${SAFEDEPS_G_M_TEXT[@]}")
  kind="${SAFEDEPS_G_M_KIND}" localbin="${SAFEDEPS_G_M_LOCALBIN}"
  SAFEDEPS_G_M_KIND=none SAFEDEPS_G_M_LOCALBIN=false
  safedeps_npm_as_other safedeps_manager_read_npm_once "${start}" "$@" || return 1
  for (( k = 0; k < ${#role[@]}; k++ )); do
    r="${role[k]}"
    case "${r}" in
      o|r|C|p) SAFEDEPS_G_M_ROLE[k]="${r}" SAFEDEPS_G_M_TEXT[k]="${text[k]}" ;;
    esac
  done
  [[ "${kind}" == none ]] || SAFEDEPS_G_M_KIND="${kind}"
  [[ "${localbin}" != true ]] || SAFEDEPS_G_M_LOCALBIN=true
}

safedeps_manager_read_npm_once() {
  local start="$1" k at key text cmd_at=-1 named=false call=false
  shift
  local -a w=("$@") args=()
  args=("${w[@]:start}")
  if [[ "${SAFEDEPS_G_M_FAMILY}" == npx ]]; then
    safedeps_npx_first_pass "${args[@]+"${args[@]}"}" || return 1
    # npx runs `npm exec` on the words it passed.
    safedeps_npm_read_args exec "${SAFEDEPS_G_NPX_WORDS[@]+"${SAFEDEPS_G_NPX_WORDS[@]}"}" || return 1
  else
    safedeps_npm_read_args "${args[@]+"${args[@]}"}" || return 1
  fi
  # Every word npm read as an option or its value.
  for (( k = start; k < ${#w[@]}; k++ )); do SAFEDEPS_G_M_ROLE[k]=g SAFEDEPS_G_M_TEXT[k]=""; done
  (( ${#SAFEDEPS_G_NPM_WORDS[@]} > 0 )) || return 0
  case "${SAFEDEPS_G_NPM_WORDS[0]}" in
    exec) [[ "${SAFEDEPS_G_M_FAMILY}" == npx ]] && SAFEDEPS_G_NPM_KIND=exec || safedeps_npm_kind_of "${SAFEDEPS_G_NPM_WORDS[0]}" ;;
    *) safedeps_npm_kind_of "${SAFEDEPS_G_NPM_WORDS[0]}" ;;
  esac
  if [[ "${SAFEDEPS_G_M_FAMILY}" != npx ]]; then
    safedeps_manager_npm_at "${start}" "${SAFEDEPS_G_NPM_AT[0]}"
    SAFEDEPS_G_M_ROLE[SAFEDEPS_G_AT]=c
  fi
  for k in "${SAFEDEPS_G_NPM_VALUES[@]+"${SAFEDEPS_G_NPM_VALUES[@]}"}"; do
    at="${k%%$'\037'*}" k="${k#*$'\037'}" key="${k%%$'\037'*}" text="${k#*$'\037'}"
    safedeps_manager_npm_at "${start}" "${at}"
    at="${SAFEDEPS_G_AT}"
    (( at >= 0 )) || continue
    case "${key}" in
      package)
        if [[ "${SAFEDEPS_G_NPM_KIND}" == exec ]]; then
          SAFEDEPS_G_M_ROLE[at]=p named=true
          [[ "${text}" == "${w[at]}" ]] || SAFEDEPS_G_M_TEXT[at]="${text}"
        fi
        ;;
      # libnpmexec runs the call instead of a package only when it is not
      # empty (`if (call && args.length)`); `--cwd`, which nopt expands into
      # `--call --workspace --loglevel info`, leaves it empty.
      call) [[ -z "${text}" ]] || call=true ;;
    esac
  done
  case "${SAFEDEPS_G_NPM_KIND}" in
    install|link) SAFEDEPS_G_M_KIND="${SAFEDEPS_G_NPM_KIND}" ;;
    exec) SAFEDEPS_G_M_KIND=runner SAFEDEPS_G_M_LOCALBIN=true ;;
    init) SAFEDEPS_G_M_KIND=create SAFEDEPS_G_M_LOCALBIN=true ;;
    *) return 0 ;;
  esac
  for (( k = 1; k < ${#SAFEDEPS_G_NPM_WORDS[@]}; k++ )); do
    safedeps_manager_npm_at "${start}" "${SAFEDEPS_G_NPM_AT[k]}"
    at="${SAFEDEPS_G_AT}"
    (( at >= 0 )) || continue
    case "${SAFEDEPS_G_M_KIND}" in
      install|link) SAFEDEPS_G_M_ROLE[at]=o ;;
      runner|create)
        if (( k == 1 )) && [[ "${named}" == false && "${call}" == false ]]; then
          [[ "${SAFEDEPS_G_M_KIND}" == create ]] && SAFEDEPS_G_M_ROLE[at]=C || SAFEDEPS_G_M_ROLE[at]=r
        else
          # One word can give npm several positionals (`--cwd=x` expands to
          # `--call --workspace --loglevel info x`); the package keeps it.
          [[ "${SAFEDEPS_G_M_ROLE[at]}" == g ]] || continue
          SAFEDEPS_G_M_ROLE[at]=a
        fi
        ;;
    esac
    [[ "${SAFEDEPS_G_NPM_WORDS[k]}" == "${w[at]}" ]] || SAFEDEPS_G_M_TEXT[at]="${SAFEDEPS_G_NPM_WORDS[k]}"
  done
}

# The index in the statement's words of a word npm read at <index> in the
# list it was given, the words after the manager starting at <start>: through
# npx's first pass for npx, whose list starts with the `exec` it adds.
# SAFEDEPS_G_AT, -1 for that `exec`.
safedeps_manager_npm_at() {
  local start="$1" a="$2"
  if [[ "${SAFEDEPS_G_M_FAMILY}" == npx ]]; then
    if (( a <= 0 )); then SAFEDEPS_G_AT=-1; return 0; fi
    a="${SAFEDEPS_G_NPX_AT[a-1]}"
  fi
  SAFEDEPS_G_AT=$(( start + a ))
}

# What kind of command npm's command word is, by the grammar's spellings for it.
safedeps_npm_kind_of() {
  local cmd="$1"
  if [[ "${cmd}" =~ ^(${SAFEDEPS_G_NPM_VERBS})$ ]]; then SAFEDEPS_G_NPM_KIND=install
  elif [[ "${cmd}" =~ ^(${SAFEDEPS_G_NPM_LINK_VERBS})$ ]]; then SAFEDEPS_G_NPM_KIND="link"
  elif [[ "${cmd}" =~ ^(${SAFEDEPS_G_NPM_EXEC_VERBS})$ ]]; then SAFEDEPS_G_NPM_KIND="exec"
  elif [[ "${cmd}" =~ ^(${SAFEDEPS_G_NPM_INIT_VERBS})$ ]]; then SAFEDEPS_G_NPM_KIND=init
  else SAFEDEPS_G_NPM_KIND=other
  fi
}

# Maven has no command word: its goals are positional, and the install is the
# dependency plugin's get goal, which fetches the coordinate in `-Dartifact=`.
safedeps_manager_read_mvn() {
  local start="$1" k t install=false
  shift
  local -a w=("$@")
  for (( k = start; k < ${#w[@]}; k++ )); do
    t="${w[k]}"
    if [[ "${t}" == -D?* ]]; then
      SAFEDEPS_G_M_ROLE[k]=g
      [[ "${t}" == -Dartifact=* ]] && { SAFEDEPS_G_M_ROLE[k]=D SAFEDEPS_G_M_TEXT[k]="${t#-D}"; }
    elif [[ "${t}" == -?* ]]; then
      SAFEDEPS_G_M_ROLE[k]=g
      if [[ "${t}" != *=* ]] && safedeps_manager_option_class mvn "" "${t}"; then
        k=$(( k + 1 ))
        if [[ "${t}" == -D || "${t}" == --define ]] && [[ "${w[k]:-}" == artifact=* ]]; then
          SAFEDEPS_G_M_ROLE[k]=D
        else
          SAFEDEPS_G_M_ROLE[k]=v
        fi
      fi
    else
      SAFEDEPS_G_M_ROLE[k]=c
      [[ "${t}" == dependency:get || "${t}" == *maven-dependency-plugin*:get ]] && install=true
    fi
  done
  [[ "${install}" == true ]] && SAFEDEPS_G_M_KIND=install
  return 0
}
