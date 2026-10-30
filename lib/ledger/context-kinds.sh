#!/usr/bin/env bash
# What an npm closure was resolved against, declared once: the `type` a
# closure source carries, the three of them that scope a ledger approval to a
# project (its project_context), and the materialization a scoped Yarn
# candidate runs and records. lib/npm/closure.sh writes them, and
# lib/ledger/ledger.sh and bin/safedeps read them, only through these names.
# The core's ledger::ContextKind and MATERIALIZE_* are held to them by
# context_kinds_match_cli.
#
# A declaration only: sourcing it sets variables and defines one predicate,
# and reads nothing from the environment.

# shellcheck disable=SC2034  # read by the files that source this one

# The kinds that scope an approval: the closure is the project's Yarn
# lockfile, a candidate materialized in a private mirror of it, or the
# published closure probed under the project's npm overrides.
SAFEDEPS_CONTEXT_YARN_LOCKFILE="yarn-project-lockfile"
SAFEDEPS_CONTEXT_YARN_MATERIALIZED="yarn-project-materialized-lockfile"
SAFEDEPS_CONTEXT_NPM_OVERRIDES="npm-overrides-probe"
# Closure sources that scope nothing: a test fixture, the published closure,
# and a Yarn candidate that could not be materialized.
SAFEDEPS_SOURCE_FIXTURE="fixture"
SAFEDEPS_SOURCE_NPM_PACKAGE="npm-package-probe"
SAFEDEPS_SOURCE_YARN_CANDIDATE="yarn-project-candidate-materialization"
# How a Yarn candidate is materialized: run from this list and recorded as it.
SAFEDEPS_CONTEXT_MATERIALIZE=(yarn install --mode=update-lockfile --no-immutable)
SAFEDEPS_CONTEXT_MATERIALIZE_ISOLATION="private-project-mirror"

# The same names in a jq program: put this in front of its text.
SAFEDEPS_CONTEXT_JQ="def context_yarn_lockfile: \"${SAFEDEPS_CONTEXT_YARN_LOCKFILE}\"; def context_yarn_materialized: \"${SAFEDEPS_CONTEXT_YARN_MATERIALIZED}\"; def context_npm_overrides: \"${SAFEDEPS_CONTEXT_NPM_OVERRIDES}\"; def context_materialize_command: \"${SAFEDEPS_CONTEXT_MATERIALIZE[*]}\"; def context_materialize_isolation: \"${SAFEDEPS_CONTEXT_MATERIALIZE_ISOLATION}\"; def context_scopes: . == context_yarn_lockfile or . == context_yarn_materialized or . == context_npm_overrides; "

# True when a closure source of this type scopes an approval to its project.
safedeps_context_kind_scopes() {
  case "$1" in
    "${SAFEDEPS_CONTEXT_YARN_LOCKFILE}"|"${SAFEDEPS_CONTEXT_YARN_MATERIALIZED}"|"${SAFEDEPS_CONTEXT_NPM_OVERRIDES}") return 0 ;;
  esac
  return 1
}
