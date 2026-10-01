#!/usr/bin/env bash
# safedeps: ask npm, under a deadline.
#
# Two questions about an npm install have only one authority, and it is npm:
# which directory an install lands in, and which packages `npm rebuild` runs
# over. safedeps used to answer both in bash, by reading npm's source and doing
# the same thing. Each answer drifted from npm twice, in a different place each
# time (safedeps/effect-gate-blind-to-lockless-npm-installs): a `cd` into a
# directory without a package.json, then a workspace member reached through a
# symlink; a version written over a recorded one, then a package inside a
# `file:` link target. A copy of npm's rules is a second judge, and the
# question was never whether it would disagree with npm again but where.
#
# So both hooks ask npm. The pre-guard asks where (lib/npm/ask.sh
# safedeps_npm_install_target), the post-verify hook asks what is installed
# (`npm query '*'`). Each costs a node start. scripts/measure/npm-ask-cost.sh
# measures it on the machine it runs on.
#
# An ask that does not answer is an answer of its own, never a fallback to the
# old reading: npm missing, npm failing, and npm not finishing before the
# deadline each come back as `?` with the reason, and each caller turns `?` into
# the direction that records or withholds rather than the one that passes.
#
# Sourced on every Bash call through the PreToolUse hook. A parse error here
# takes that hook's npm target resolution down, so edit it in a worktree and
# run `npm test` first. Bash 3.2 compatible.

# How long the pre-guard waits for npm, in total, for every install in one
# command. Not a knob: a budget a user can raise is a way to switch the deadline
# off (AGENTS.md, the self budget). The pre-guard runs inline, with no deadline
# of its own, for commands under the engage size, so this has to leave the
# runtime's 30s inside reach with the rest of the judgment still to do.
#
# Measured on a machine at load 140-220 (scripts/measure/npm-ask-cost.sh):
# `npm prefix` took up to 2.7s. At 8s an answer that slow still lands with room
# for one more, and on an idle machine it takes about 0.1s.
SAFEDEPS_NPM_ASK_PRE_SECONDS=8

# How long the post-verify hook waits for `npm query '*'`. Measured on the same
# machine: up to 4.4s for 111 packages under load 222, 1.6s for 5501. A query
# that does not finish skips the rebuild, so a short deadline costs a warning,
# never a script.
SAFEDEPS_NPM_ASK_POST_SECONDS=10

# Flags every ask carries. They change nothing npm decides about where or what;
# they keep the ask from writing a log file or checking for an npm update.
SAFEDEPS_NPM_ASK_QUIET=(--logs-max=0 --update-notifier=false)

SAFEDEPS_NPM_ASK_PIDS=()
SAFEDEPS_NPM_ASK_RCS=()

# Starts `<npm> <args>` in <dir>, in the background. <npm> is the npm word the
# command uses (`npm`, or a path to one). <out> gets stdout and <out>.err
# stderr. The words before `--` go to env(1) in front of npm, so
# `NAME=value`, `-u NAME` and `-i` reach npm the way the command would have
# given them. The pid is appended to SAFEDEPS_NPM_ASK_PIDS.
#
# `exec`, so the pid is npm's own and the deadline can stop it.
safedeps_npm_ask_start() {
  local out="$1" dir="$2" npm="$3"
  local -a env_words=()
  shift 3
  while [[ $# -gt 0 && "$1" != -- ]]; do
    env_words+=("$1")
    shift
  done
  [[ $# -gt 0 ]] && shift
  ( cd "${dir}" 2>/dev/null || { printf 'cannot enter %s\n' "${dir}" >&2; exit 126; }
    exec env "${env_words[@]+"${env_words[@]}"}" "${npm}" "$@" "${SAFEDEPS_NPM_ASK_QUIET[@]}"
  ) > "${out}" 2> "${out}.err" &
  SAFEDEPS_NPM_ASK_PIDS+=("$!")
}

# Waits for every started ask until $SECONDS reaches <until>. Returns 0 when
# all answered, with their exit statuses in SAFEDEPS_NPM_ASK_RCS in start order.
# Returns 1 when the deadline came first, after killing what was still running.
# Either way the started list is emptied.
#
# Polling with `kill -0`, as the self budget does: a watchdog subshell that
# sleeps would hold the shell until its sleep ended. The step starts small,
# because an idle npm answers in about a tenth of a second.
safedeps_npm_ask_wait() {
  local until="$1" pid alive step=0.02 timed_out=false rc
  SAFEDEPS_NPM_ASK_RCS=()
  while :; do
    alive=false
    for pid in "${SAFEDEPS_NPM_ASK_PIDS[@]}"; do
      if kill -0 "${pid}" 2>/dev/null; then
        alive=true
        break
      fi
    done
    [[ "${alive}" == true ]] || break
    if (( SECONDS >= until )); then
      for pid in "${SAFEDEPS_NPM_ASK_PIDS[@]}"; do
        kill -KILL "${pid}" 2>/dev/null || true
      done
      timed_out=true
      break
    fi
    sleep "${step}"
    case "${step}" in
      0.02) step=0.05 ;;
      0.05) step=0.1 ;;
      *) step=0.2 ;;
    esac
  done
  # Reaped under a redirect: the shell announces a job that died by signal at
  # whatever statement it next reaches, and beside a hook's answer that line
  # reads as a malfunction.
  for pid in "${SAFEDEPS_NPM_ASK_PIDS[@]}"; do
    rc=0
    wait "${pid}" 2>/dev/null || rc=$?
    SAFEDEPS_NPM_ASK_RCS+=("${rc}")
  done
  SAFEDEPS_NPM_ASK_PIDS=()
  [[ "${timed_out}" == false ]]
}

# The first line npm wrote to stderr for <out>, for a reason string. npm
# prefixes its errors with `npm error`; the code line is the useful one.
safedeps_npm_ask_error() {
  local out="$1" line
  line=$(grep -m1 -E 'npm (error|ERR!) (code )?[A-Z]' "${out}.err" 2>/dev/null \
    || head -n 1 "${out}.err" 2>/dev/null || true)
  line="${line#npm error }"
  line="${line#npm ERR! }"
  printf '%s' "${line:-no output}"
}

# Where `npm <args>` installs when it runs in <dir>, asked of npm.
#
#   <dir>         the local prefix, a physical path: npm installs there and
#                 records it in that directory's lockfiles.
#   global<TAB><local prefix>
#                 npm installs in its global prefix, which no lockfile records.
#                 The local prefix is where the project .npmrc is read from.
#   ?<TAB><why>   npm could not be asked, or did not answer.
#
# Called as `<dir> <until> <npm> <env words> -- <args>`. The arguments are the
# install's own; the words before `--` go to env(1) and <npm> is the npm word
# (safedeps_npm_ask_start). <until> is a $SECONDS value shared by every install
# in one command.
#
# Two asks, in parallel, with the same arguments:
#
#   - `npm prefix <args> --global=false --location=project` is the local
#     prefix: npm's walk to the nearest package.json or node_modules, its
#     workspace roots, its .npmrc, and `--prefix`/`-C`. The two flags at the end
#     make it the local prefix even where the install is global, so the project
#     .npmrc can be read from it.
#   - `npm root <args>` is the directory npm installs into: `<local
#     prefix>/node_modules` for a project install, `<global prefix>/lib/
#     node_modules` for a global one (npm's own `npm.dir`).
#
# The install is local exactly when the second is the first plus
# /node_modules. `npm prefix` alone cannot say: with `--prefix sub`, the local
# and the global prefix are both `sub`.
#
# Workspace selectors are left off the asks. npm refuses them on `prefix` and
# `root` (ENOWORKSPACES), and they do not move the prefix: @npmcli/config
# loadLocalPrefix reads `workspaces` only to stop at a false, and never reads
# `workspace`. A false is kept.
safedeps_npm_install_target() {
  local dir="$1" until="$2" npm="$3" tmp prefix root why word
  local -a env_words=() args=()
  shift 3
  while [[ $# -gt 0 && "$1" != -- ]]; do
    env_words+=("$1")
    shift
  done
  [[ $# -gt 0 ]] && shift
  while [[ $# -gt 0 ]]; do
    word="$1"
    shift
    case "${word}" in
      -w|--workspace)
        [[ $# -gt 0 ]] && shift
        continue
        ;;
      -w?*|--workspace=*|--include-workspace-root|--include-workspace-root=*|-ws) continue ;;
      --workspaces|--workspaces=true)
        # nopt takes the next word as a boolean's value only when it is one.
        if [[ "${word}" == --workspaces && $# -gt 0 ]]; then
          case "$1" in
            false) args+=(--workspaces=false); shift; continue ;;
            true) shift; continue ;;
          esac
        fi
        continue
        ;;
    esac
    args+=("${word}")
  done

  if ! command -v "${npm}" >/dev/null 2>&1; then
    printf '?\t%s is not on the PATH this hook runs with, so safedeps cannot ask npm where this install lands\n' "${npm}"
    return 0
  fi
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-npm-ask.XXXXXX") || {
    printf '?\tsafedeps could not make a scratch directory to ask npm where this install lands\n'
    return 0
  }
  safedeps_npm_ask_start "${tmp}/prefix" "${dir}" "${npm}" "${env_words[@]+"${env_words[@]}"}" -- \
    prefix "${args[@]+"${args[@]}"}" --global=false --location=project
  safedeps_npm_ask_start "${tmp}/root" "${dir}" "${npm}" "${env_words[@]+"${env_words[@]}"}" -- \
    root "${args[@]+"${args[@]}"}"
  if ! safedeps_npm_ask_wait "${until}"; then
    printf '?\tnpm did not say where this install lands within %ss\n' "${SAFEDEPS_NPM_ASK_PRE_SECONDS}"
    rm -rf "${tmp}"
    return 0
  fi
  why=""
  if [[ "${SAFEDEPS_NPM_ASK_RCS[0]}" != 0 ]]; then
    why="npm prefix failed (exit ${SAFEDEPS_NPM_ASK_RCS[0]}: $(safedeps_npm_ask_error "${tmp}/prefix"))"
  elif [[ "${SAFEDEPS_NPM_ASK_RCS[1]}" != 0 ]]; then
    why="npm root failed (exit ${SAFEDEPS_NPM_ASK_RCS[1]}: $(safedeps_npm_ask_error "${tmp}/root"))"
  fi
  prefix=$(tail -n 1 "${tmp}/prefix" 2>/dev/null || true)
  root=$(tail -n 1 "${tmp}/root" 2>/dev/null || true)
  rm -rf "${tmp}"
  if [[ -n "${why}" ]]; then
    printf '?\t%s, so safedeps cannot tell where this install lands\n' "${why}"
    return 0
  fi
  if [[ "${prefix}" != /* || "${root}" != /* ]]; then
    printf '?\tnpm did not answer with a path (prefix %s, root %s), so safedeps cannot tell where this install lands\n' \
      "${prefix:-<empty>}" "${root:-<empty>}"
    return 0
  fi
  if [[ "${root}" != "${prefix%/}/node_modules" ]]; then
    printf 'global\t%s\n' "${prefix}"
    return 0
  fi
  # A `--prefix` that does not exist yet is created by the install. npm's path
  # is still where it lands, so it is kept as npm gave it.
  printf '%s\n' "$(cd "${prefix}" 2>/dev/null && pwd -P || printf '%s' "${prefix}")"
}
