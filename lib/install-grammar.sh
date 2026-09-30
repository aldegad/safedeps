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
#   npm exec: x                   pnpm install: i
#   pnpm update: up, upgrade      pnpm install-test: it
#   bun add: a, bun install: i (from `bun --help`)
#   yarn up (Berry) moves an existing dependency to the given version.
SAFEDEPS_G_NPM_VERBS='install|i|in|ins|inst|insta|instal|isnt|isnta|isntal|isntall|add|install-test|it|ci|clean-install|ic|install-clean|isntall-clean|install-ci-test|cit|clean-install-test|sit|update|u|up|upgrade|udpate'
SAFEDEPS_G_PNPM_VERBS='add|install|i|install-test|it|update|up|upgrade'
SAFEDEPS_G_YARN_VERBS='add|install|upgrade|up'
SAFEDEPS_G_BUN_VERBS='add|a|install|i|update|upgrade'

# Every token that can open an install's operand list, for the operand walks.
SAFEDEPS_G_ALL_VERBS="${SAFEDEPS_G_NPM_VERBS}|${SAFEDEPS_G_PNPM_VERBS}|${SAFEDEPS_G_YARN_VERBS}|${SAFEDEPS_G_BUN_VERBS}|dlx|exec|x|get|run|inject|dependency:get|package"

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

SAFEDEPS_G_O="${SAFEDEPS_G_OPTS}"

# npm-CLI installs only. The effect gate reads package-lock.json, which only the
# npm CLI writes, so this is also the set the `--ignore-scripts` rewrite targets.
SAFEDEPS_G_NPM_INSTALL_BODY="npm${SAFEDEPS_G_O}[[:space:]]+(${SAFEDEPS_G_NPM_VERBS})"

# Runners fetch a package and execute it. Nothing reads a lockfile after them.
# This ends AT the runner keyword. Options after it belong to the runner and can
# carry the package (`npx -p x@1 cmd`), so the operand walk has to see them.
SAFEDEPS_G_RUNNER_BODY="(npx|pnpx|bunx|uvx)|npm${SAFEDEPS_G_O}[[:space:]]+(exec|x)|pnpm${SAFEDEPS_G_O}[[:space:]]+dlx|yarn${SAFEDEPS_G_O}[[:space:]]+dlx|bun${SAFEDEPS_G_O}[[:space:]]+x|pipx${SAFEDEPS_G_O}[[:space:]]+run|uv${SAFEDEPS_G_O}[[:space:]]+tool${SAFEDEPS_G_O}[[:space:]]+run|go${SAFEDEPS_G_O}[[:space:]]+run"

SAFEDEPS_G_INSTALL_BODY="${SAFEDEPS_G_NPM_INSTALL_BODY}\
|(npx|pnpx|bunx|uvx)${SAFEDEPS_G_O}${SAFEDEPS_G_OPERAND}\
|npm${SAFEDEPS_G_O}[[:space:]]+(exec|x)${SAFEDEPS_G_O}${SAFEDEPS_G_OPERAND}\
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
|dotnet${SAFEDEPS_G_O}[[:space:]]+tool${SAFEDEPS_G_O}[[:space:]]+(install|update)"

# --- the patterns the gates read --------------------------------------------------
# Anchored at a statement start. Run these on command_scan_text output, where
# quoted text is already blanked.
SAFEDEPS_G_INSTALL_RE="${SAFEDEPS_G_START}(${SAFEDEPS_G_INSTALL_BODY})([[:space:]]|$)"
SAFEDEPS_G_NPM_INSTALL_RE="${SAFEDEPS_G_START}(${SAFEDEPS_G_NPM_INSTALL_BODY})([[:space:]]|$)"
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
