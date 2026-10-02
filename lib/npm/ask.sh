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
# A third question joined them when a record turned out not to say where its
# bytes came from: which registry npm fetches from (the fetch facts, below).
# The pre-guard asks it beside where, in parallel; the post-verify hook asks
# it again after the command.
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

# --- where npm fetches a package's bytes from --------------------------------
#
# A third question has only npm to answer it: which registry an install
# fetches from. A lockfile names a source in `resolved`, and the gate used to
# take a source on registry.npmjs.org for the public registry. It is not.
# npm's default `replace-registry-host=npmjs` fetches every
# https://registry.npmjs.org/ URL from the registry npm is configured with, and
# records the URL as it was. A committed .npmrc with `registry=<anywhere>`, or
# `npm_config_registry` in the command, sent an approved name and version to
# another tarball, both lockfiles said registry.npmjs.org, and the rebuild ran
# that tarball's scripts (measured, npm 11.19.0; the repo's own fixture
# registry depends on the same rewrite). So a recorded URL says where npm
# would have fetched from with no registry configured, never where it did.
#
# What npm reads for this is its configuration: `registry`,
# `replace-registry-host` and each `@scope:registry`, from the command line,
# the environment, and the project, user and global .npmrc. `npm config ls
# --json` prints all of it in one answer, and it is asked the way the install
# is: in the same directory, with the statement's own arguments and
# environment. That answer is what this file calls the fetch facts:
#
#   {"registry": <url or null>, "replace": <value or null>,
#    "scopes": {"@scope": <url>, ...}, "test_registry": <url or null>}
#
# or {"unknown": "<why>"} when npm could not be asked or did not answer. A
# value npm will not print (one holding a credential or something shaped like
# an id: lib/commands/config.js leaves out what @npmcli/redact would change) is
# null, and a null registry is not a public one.
#
# Whether npm swaps the host of a recorded URL is npm's rule, applied here to
# npm's answer: pacote's remote fetcher and arborist's reify both replace the
# host when `replace-registry-host` is `always` or names that host (`npmjs`
# is registry.npmjs.org), and fetch from the default `registry`. npm 11.19.0
# never fetches a recorded URL from a scope's registry (pacote lib/remote.js
# and lib/registry.js hand the tarball fetch the default registry). The
# scope's registry is judged as well, for a package under that scope: a
# version of npm that read it would otherwise pass silently, and judging it
# costs a skipped rebuild at most.

# The public registries: npm's and Yarn's, over https, read as a scheme and a
# host at the start of the value. The one definition (lib/npm/closure.sh and
# post-verify's rebuild check read it from here).
SAFEDEPS_NPM_PUBLIC_REGISTRY_RE='^https://registry\.(npmjs\.org|yarnpkg\.com)/'

# The local registry a test battery runs against, from
# SAFEDEPS_NPM_TEST_REGISTRY, normalized to end in `/`. It counts as a public
# registry, and nothing else does. Only a loopback http(s) root URL is taken:
# any other value is ignored, so this cannot admit a mirror or a private
# registry. Setting it is announced in advisory.log on every run, with the
# moved advisory sources (lib/truth-sources.sh), because a run that let a
# local registry through must not read like one that did not. Prints nothing
# when it is unset or not taken.
safedeps_npm_test_registry() {
  local value="${SAFEDEPS_NPM_TEST_REGISTRY:-}"
  [[ -n "${value}" ]] || return 0
  [[ "${value}" == */ ]] || value+=/
  [[ "${value}" =~ ^https?://(127\.0\.0\.1|localhost|\[::1\])(:[0-9]+)?/$ ]] || return 0
  printf '%s' "${value}"
}

# jq definitions over fetch facts. Every reader prepends them and passes
# `--arg public "${SAFEDEPS_NPM_PUBLIC_REGISTRY_RE}"`.
#
#   sd_fetch_problems($facts; $url)  why npm may have fetched the bytes
#       recorded at $url from somewhere other than $url's public registry,
#       under any of $facts (an array of fetch facts), as a list; empty when
#       every answer says the bytes came from there. An empty $facts is a
#       problem of its own, and so is an answer that is missing.
#   sd_fetch_known_problems($facts; $url)  the same, from the answers npm
#       gave only: a registry npm named that is not public. A missing answer
#       is not one, so a caller that rolls back reads this, and a caller that
#       only withholds scripts reads the first.
#   sd_registry_public($f)  whether the registry URL in `.` is public under
#       the facts $f (the test registry counts).
# shellcheck disable=SC2016 # jq programs: jq expands their $names
SAFEDEPS_NPM_FETCH_JQ='
  def sd_host: ((capture("^[A-Za-z][A-Za-z0-9+.-]*://([^@/?#]*@)?(?<h>\\[[^\\]]*\\]|[^/:?#]*)") // {h: ""}).h | ascii_downcase);
  def sd_registry_public($f):
    (type == "string")
    and ((if endswith("/") then . else . + "/" end) as $s
         | ($s | test($public; "i")) or ($f.test_registry != null and $s == $f.test_registry));
  def sd_fetch_problem($f; $url):
    if ($f | type) != "object" then "safedeps has no answer from npm about the registry"
    elif $f.unknown != null then ($f.unknown | tostring)
    else
      ($url | sd_host) as $h
      | ($f.replace // null) as $r
      | (if $r == null or $r == "always" then true
         elif $r == "never" then false
         else (if $r == "npmjs" then "registry.npmjs.org"
               elif ($r | test("://")) then ($r | sd_host)
               else ($r | ascii_downcase) end) == $h
         end) as $swapped
      | if ($swapped | not) then ""
        elif ($f.registry | sd_registry_public($f)) | not then
          "npm fetches it from the registry \($f.registry // "it will not print") (replace-registry-host=\($r // "not printed"))"
        else
          ([$url | capture("^[^:]+://[^/]+/(?<s>@[^/]+)/") | .s] | first) as $scope
          | if $scope != null and ($f.scopes[$scope] // null) != null
               and (($f.scopes[$scope] | sd_registry_public($f)) | not) then
              "npm has \($scope):registry=\($f.scopes[$scope]) (replace-registry-host=\($r))"
            else "" end
        end
    end;
  def sd_fetch_problems($facts; $url):
    if ($facts | type) != "array" or ($facts | length) == 0 then ["safedeps has no answer from npm about the registry"]
    else [$facts[] | sd_fetch_problem(.; $url) | select(. != "")] | unique end;
  def sd_fetch_known_problems($facts; $url):
    if ($facts | type) != "array" then []
    else [$facts[] | select(type == "object" and .unknown == null) | sd_fetch_problem(.; $url) | select(. != "")] | unique end;
'

# The fetch facts in <out>, the answer to `npm config ls --json` that exited
# <rc>, as one line of JSON (above). <what> names the ask for the reason.
safedeps_npm_fetch_read() {
  local out="$1" rc="$2" what="$3" facts
  if [[ "${rc}" != 0 ]]; then
    jq -nc --arg why "npm config failed (exit ${rc}: $(safedeps_npm_ask_error "${out}")), so safedeps cannot tell which registry ${what} fetches from" \
      '{unknown: $why}'
    return 0
  fi
  if facts=$(jq -c --arg test "$(safedeps_npm_test_registry)" '
      if type != "object" then error("not an object") else . end
      | {registry: (.registry // null | if type == "string" then . else null end),
         replace: (.["replace-registry-host"] // null | if type == "string" then . else null end),
         scopes: (to_entries
                  | map(select((.key | test("^@[^:/]+:registry$")) and (.value | type) == "string")
                        | {key: (.key | sub(":registry$"; "")), value: .value})
                  | from_entries),
         test_registry: (if $test == "" then null else $test end)}' "${out}" 2>/dev/null) \
      && [[ -n "${facts}" ]]; then
    printf '%s\n' "${facts}"
  else
    jq -nc --arg why "npm config answered with something safedeps could not read, so it cannot tell which registry ${what} fetches from" \
      '{unknown: $why}'
  fi
}

# The fetch facts of `npm <args>` run in <dir>, asked of npm, as one line of
# JSON. Called as `<dir> <until> <npm> <env words> -- <args>`, like
# safedeps_npm_install_target, which asks the same question beside its own
# for an install statement. The post-verify hook asks it again after the
# command, of the directory it read.
safedeps_npm_fetch_facts() {
  local dir="$1" until="$2" npm="$3" tmp
  local -a env_words=()
  shift 3
  while [[ $# -gt 0 && "$1" != -- ]]; do
    env_words+=("$1")
    shift
  done
  [[ $# -gt 0 ]] && shift
  if ! command -v "${npm}" >/dev/null 2>&1; then
    jq -nc --arg why "${npm} is not on the PATH this hook runs with, so safedeps cannot ask npm which registry it fetches from" '{unknown: $why}'
    return 0
  fi
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-npm-ask.XXXXXX") || {
    jq -nc '{unknown: "safedeps could not make a scratch directory to ask npm which registry it fetches from"}'
    return 0
  }
  safedeps_npm_ask_start "${tmp}/config" "${dir}" "${npm}" "${env_words[@]+"${env_words[@]}"}" -- \
    config ls "$@" --json
  if ! safedeps_npm_ask_wait "${until}"; then
    jq -nc '{unknown: "npm did not say which registry it fetches from before the deadline"}'
    rm -rf "${tmp}"
    return 0
  fi
  safedeps_npm_fetch_read "${tmp}/config" "${SAFEDEPS_NPM_ASK_RCS[0]}" "this install"
  rm -rf "${tmp}"
}

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

# The one directory from <dir> up, as a physical path, that reads as <masked>
# when each `***` in it stands for a hidden part of one path segment. Prints
# nothing when none does, or when more than one does.
#
# Only the `***` is read as a wildcard, so this holds whatever npm masks: the
# whole of a UUID, or what follows a token's `npm_`. Every other character is
# matched as itself. It runs no external command.
safedeps_npm_unmask() {
  local masked="$1" dir="$2" re="" c here found="" count=0 i=0
  while (( i < ${#masked} )); do
    if [[ "${masked:i:3}" == '***' ]]; then
      re+='[^/]+'
      i=$(( i + 3 ))
      continue
    fi
    c="${masked:i:1}"
    case "${c}" in
      '.'|'['|'$'|'('|')'|'|'|'*'|'+'|'?'|'{'|"\\"|'^') re+="\\${c}" ;;
      ']') re+='[]]' ;;
      '}') re+='[}]' ;;
      *) re+="${c}" ;;
    esac
    i=$(( i + 1 ))
  done
  here=$(cd "${dir}" 2>/dev/null && pwd -P) || return 0
  while :; do
    if [[ "${here}" =~ ^${re}$ ]]; then
      found="${here}"
      count=$(( count + 1 ))
    fi
    [[ "${here}" != / ]] || break
    here="${here%/*}"
    here="${here:-/}"
  done
  [[ "${count}" != 1 ]] || printf '%s' "${found}"
}

# Where `npm <args>` installs when it runs in <dir>, asked of npm.
#
#   <dir>         the local prefix, a physical path: npm installs there and
#                 records it in that directory's lockfiles.
#   global<TAB><local prefix>
#                 npm installs in its global prefix, which no lockfile records.
#                 The local prefix is where the project .npmrc is read from,
#                 and empty when npm masked it beyond reading (below).
#   ?<TAB><why>   npm could not be asked, did not answer, or masked the
#                 directory it named beyond reading.
#
# A second line follows: the install's fetch facts (above), from `npm config
# ls --json` asked beside the two below, in parallel and under the same
# deadline. One answer that is `?` does not make the other one `?`.
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
  local dir="$1" until="$2" npm="$3" tmp prefix root why word fetch config_refused_workspace
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
    jq -nc --arg why "${npm} is not on the PATH this hook runs with, so safedeps cannot ask npm which registry this install fetches from" '{unknown: $why}'
    return 0
  fi
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-npm-ask.XXXXXX") || {
    printf '?\tsafedeps could not make a scratch directory to ask npm where this install lands\n'
    jq -nc '{unknown: "safedeps could not make a scratch directory to ask npm which registry this install fetches from"}'
    return 0
  }
  safedeps_npm_ask_start "${tmp}/prefix" "${dir}" "${npm}" "${env_words[@]+"${env_words[@]}"}" -- \
    prefix "${args[@]+"${args[@]}"}" --global=false --location=project
  safedeps_npm_ask_start "${tmp}/root" "${dir}" "${npm}" "${env_words[@]+"${env_words[@]}"}" -- \
    root "${args[@]+"${args[@]}"}"
  safedeps_npm_ask_start "${tmp}/config" "${dir}" "${npm}" "${env_words[@]+"${env_words[@]}"}" -- \
    config ls "${args[@]+"${args[@]}"}" --json
  if ! safedeps_npm_ask_wait "${until}"; then
    printf '?\tnpm did not say where this install lands within %ss\n' "${SAFEDEPS_NPM_ASK_PRE_SECONDS}"
    jq -nc --arg s "${SAFEDEPS_NPM_ASK_PRE_SECONDS}" '{unknown: "npm did not say which registry this install fetches from within \($s)s"}'
    rm -rf "${tmp}"
    return 0
  fi
  fetch=$(safedeps_npm_fetch_read "${tmp}/config" "${SAFEDEPS_NPM_ASK_RCS[2]}" "this install")
  config_refused_workspace=false
  if [[ "${SAFEDEPS_NPM_ASK_RCS[2]}" != 0 ]] && grep -q 'ENOWORKSPACES' "${tmp}/config.err" 2>/dev/null; then
    config_refused_workspace=true
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
    printf '?\t%s, so safedeps cannot tell where this install lands\n%s\n' "${why}" "${fetch}"
    return 0
  fi
  if [[ "${prefix}" != /* || "${root}" != /* ]]; then
    printf '?\tnpm did not answer with a path (prefix %s, root %s), so safedeps cannot tell where this install lands\n%s\n' \
      "${prefix:-<empty>}" "${root:-<empty>}" "${fetch}"
    return 0
  fi
  # npm masks what it prints. npm 11.19.0 sends every line of output through
  # @npmcli/redact, which writes `***` over anything shaped like a UUID or an
  # npm token, paths included, and no setting turns it off (read in its
  # lib/utils/format.js). Measured with that npm under
  # .../3f944c98-33ca-4b92-9f2e-aab54047d1d6/project: `npm prefix` printed
  # .../***/project, and the gate went looking for a project there and denied
  # an approved install. An agent's scratch directory is often under a session
  # UUID.
  #
  # The masked answer is not a path, so it is never used as one. The local
  # prefix npm finds by itself is the cwd or a directory above it, so the
  # directories from <dir> up are the candidates, and the answer stands for one
  # of them only when exactly one reads the same with each `***` taken as a
  # hidden part of a single path segment. Comparing the two masked answers for
  # local or global is still sound: the mask is the same over the shared part.
  # Where no candidate reads the same (a masked `--prefix` anywhere but the
  # cwd and above), npm has not said where, and the answer is `?`. A `--prefix`
  # elsewhere that reads the same as a candidate sends the gate to the wrong
  # directory, which then shows no trace of the install and is recorded
  # UNGATED (scripts/test/effect-trace-grid.sh, section 1c).
  local masked=""
  if [[ "${prefix}" == *'***'* ]]; then
    masked="${prefix}"
    prefix=$(safedeps_npm_unmask "${masked}" "${dir}")
  fi
  if [[ "${root}" != "${masked:-${prefix%/}}/node_modules" ]]; then
    # Global. The local prefix only says which project .npmrc to read. A
    # masked one that no candidate reads the same as is left empty.
    printf 'global\t%s\n%s\n' "${prefix}" "${fetch}"
    return 0
  fi
  if [[ -n "${masked}" && -z "${prefix}" ]]; then
    printf '?\tnpm masked part of the directory it named (%s), the way it masks anything shaped like a UUID or a token, and no directory from %s up reads the same, so safedeps cannot tell where this install lands\n%s\n' \
      "${masked}" "${dir}" "${fetch}"
    return 0
  fi
  # In a workspace member npm will not run `config` at all: it counts the cwd as
  # an implicit `--workspace` and refuses with ENOWORKSPACES (npm.js
  # execCommandClass; `config` does not ignore the implicit workspace). The
  # install itself reads its project configuration at the workspace root, the
  # local prefix npm just named, and ignores the member's .npmrc. So the same
  # question, with the same words, is asked there. It is the same answer, not
  # a second reading: from the root, npm walks to the same prefix and reads
  # the same files and environment. `--workspaces=false` would stop the walk
  # at the member and read the member's .npmrc, and `--prefix` would move the
  # global config file with it; either answers a different install.
  if [[ "${config_refused_workspace}" == true ]]; then
    fetch=$(safedeps_npm_fetch_facts "${prefix}" "${until}" "${npm}" "${env_words[@]+"${env_words[@]}"}" -- \
      "${args[@]+"${args[@]}"}")
  fi
  # A `--prefix` that does not exist yet is created by the install. npm's path
  # is still where it lands, so it is kept as npm gave it.
  printf '%s\n%s\n' "$(cd "${prefix}" 2>/dev/null && pwd -P || printf '%s' "${prefix}")" "${fetch}"
}
