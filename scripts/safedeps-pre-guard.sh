#!/usr/bin/env bash
# safedeps: PreToolUse hook
# Dependency install safety gate with reorg rollback support
# Detects package install commands and snapshots lock files before execution

set -euo pipefail

# When this script started, on bash's own clock. The self budget (see "Self
# budget" below) is measured from here, not from the spawn of its child,
# because the runtime's timer is already running when the hook starts.
# SECONDS counts whole seconds and costs no process to read, and it exists in
# bash 3.2, which is what macOS runs hooks under. Bash seeds it from the
# environment, so the deadline reads the difference from this value and never
# the value itself: compared bare, an exported SECONDS=-100000 would be one more
# off switch.
SAFEDEPS_GUARD_STARTED_SECONDS=${SECONDS}

# The lexer memo (see shell_lex) is made fresh below, per run. A directory named
# from outside would be a place to plant a view for a command, so a value from
# the environment is dropped before anything can read it.
SAFEDEPS_LEX_CACHE=""

# Which half of the budget machinery this process is: the parent that keeps the
# deadline, or the child it spawns to do the judging.
#
# This used to be an environment variable, and an environment variable is
# settable from outside. Exporting it made the parent believe it was already the
# child, so it skipped the deadline entirely — measured, a 12KB padded
# `pip install` answered in 3s normally and 32s with the marker exported, past
# the runtime kill, with nothing on stderr and nothing in advisory.log. An
# unnamed off switch beside the named one (SAFEDEPS_BUDGET_DISABLED), which is
# the thing this gate says it does not have.
#
# It travels in argv instead. The engines run the hook through the entry shim,
# which invokes this script with no arguments at all, so there is no path from
# the environment into this flag — the only process that can set it is the one
# that spawns the child, which is this script.
SAFEDEPS_BUDGET_ROLE="parent"
if [[ "${1:-}" == "--budget-child" ]]; then
  SAFEDEPS_BUDGET_ROLE="child"
fi

GUARD_DIR="${SAFEDEPS_HOME:-${HOME}/.safedeps}"
SNAPSHOT_DIR="${GUARD_DIR}/snapshots"
STATE_LOCK_DIR="${GUARD_DIR}/state.lock"

SAFEDEPS_LOCK_FILES=(
  "package-lock.json"
  "pnpm-lock.yaml"
  "yarn.lock"
  "bun.lock"
  "bun.lockb"
  "poetry.lock"
  "uv.lock"
  "Pipfile.lock"
  "requirements.txt"
  "Cargo.lock"
  "go.sum"
  "Gemfile.lock"
  "packages.lock.json"
)

SAFEDEPS_MANIFEST_FILES=(
  "package.json"
  "pyproject.toml"
  "Pipfile"
  "Cargo.toml"
  "go.mod"
  "Gemfile"
  "pom.xml"
)

umask 077
mkdir -p "${GUARD_DIR}" "${SNAPSHOT_DIR}"

# Observable record of any gate bypass / unavailability (AGENTS.md: no silent fallback —
# every bypass must be observable and logged).
log_advisory() {
  printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "${GUARD_DIR}/advisory.log" 2>/dev/null || true
}

# A moved advisory source is recorded from this hook too, not only from the CLI.
# The notice used to live in the provider stack, which this hook does not source
# — so a guard run under a moved source said nothing, and the only reason that
# was harmless is that the guard does not currently reach a provider or a
# fixture. "It does not take that path yet" is a reason that disappears when the
# code changes, and a channel that exists only where the claim is already true is
# not a channel.
#
# The list and the defaults live in lib/truth-sources.sh, resolved from this
# script's own location with plain expansion — no environment variable, and no
# subshell on a path that runs for every Bash call. The first version of this
# took the path from SAFEDEPS_TRUTH_SOURCES_LIB and returned quietly when the
# file could not be read, which is an unnamed off switch for the notice:
# pointing it at /dev/null left a run under a moved source recording nothing,
# silently. That is the defect the release before this one closed for the
# parent/child marker, rebuilt beside the invariant that forbids it.
#
# If the file cannot be read the notice is unavailable, and an unavailability is
# said out loud like every other one — the install gate itself is unaffected, so
# this reports rather than blocks.
safedeps_guard_announce_truth_sources() {
  local lib="${BASH_SOURCE[0]%/*}/../lib/truth-sources.sh"
  if [[ ! -r "${lib}" ]]; then
    log_advisory "pre-guard: lib/truth-sources.sh is unreadable — cannot tell whether the advisory sources were moved for this run."
    printf 'safedeps: lib/truth-sources.sh is unreadable, so this run cannot report whether its advisory sources were moved. The install gate is unaffected; the record is incomplete.\n' >&2
    return 0
  fi
  # shellcheck source=../lib/truth-sources.sh
  source "${lib}"
  safedeps_truth_sources_possibly_moved || return 0
  local moved
  moved="$(safedeps_truth_sources_moved_list)"
  [[ -n "${moved}" ]] || return 0
  log_advisory "pre-guard: advisory truth source moved: ${moved} — this run did not judge against the canonical sources."
}

# The install grammar every recognizer below reads. Without it this hook cannot
# tell an install from any other command, so it says so and blocks: the outcome
# the entry shim gives a hook that will not load, with the cause named instead
# of left for someone to guess.
SAFEDEPS_INSTALL_GRAMMAR_LIB="${BASH_SOURCE[0]%/*}/../lib/install-grammar.sh"
if [[ ! -r "${SAFEDEPS_INSTALL_GRAMMAR_LIB}" ]]; then
  log_advisory "pre-guard DENY: lib/install-grammar.sh is unreadable — the gate cannot tell an install from any other command, fail-closed."
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"safedeps: lib/install-grammar.sh is missing or unreadable, so this gate cannot tell a dependency install from any other command. Bash is blocked fail-closed until it is restored. Reinstall safedeps: node scripts/install/install-safedeps-hooks.mjs"}}'
  exit 0
fi
# shellcheck source=../lib/install-grammar.sh
source "${SAFEDEPS_INSTALL_GRAMMAR_LIB}"

# Where an npm install lands is asked of npm (lib/npm/ask.sh). Without that
# file it cannot be asked, so every npm install target is `?` and the install is
# recorded UNGATED rather than read in a directory npm may not have used.
SAFEDEPS_NPM_ASK_LIB="${BASH_SOURCE[0]%/*}/../lib/npm/ask.sh"
if [[ -r "${SAFEDEPS_NPM_ASK_LIB}" ]]; then
  # shellcheck source=../lib/npm/ask.sh
  source "${SAFEDEPS_NPM_ASK_LIB}"
else
  SAFEDEPS_NPM_ASK_PRE_SECONDS=0
  safedeps_npm_install_target() {
    printf '?\tlib/npm/ask.sh is unreadable, so safedeps cannot ask npm where this install lands\n'
    printf '%s\n' '{"unknown":"lib/npm/ask.sh is unreadable, so safedeps cannot ask npm which registry this install fetches from"}'
  }
  # Every answer is already unknown, and no cause is given to one.
  safedeps_npm_code_name() { return 1; }
fi

# The workspace members' manifests, which a workspace install writes and a
# rollback has to restore, and the names snapshots keep files under.
SAFEDEPS_NPM_WORKSPACES_LIB="${BASH_SOURCE[0]%/*}/../lib/npm/workspaces.sh"
if [[ -r "${SAFEDEPS_NPM_WORKSPACES_LIB}" ]]; then
  # shellcheck source=../lib/npm/workspaces.sh
  source "${SAFEDEPS_NPM_WORKSPACES_LIB}"
else
  SAFEDEPS_SNAPSHOT_MEMBERS=members
  SAFEDEPS_SNAPSHOT_NPM_TREE=npm-tree-record.json
  safedeps_snapshot_file_name() { printf '%s' "$1"; }
fi

# Loose, on purpose: this reads raw text nobody has parsed, for the two cases
# where the precise recognizer cannot run (jq missing, the scanner failing).
# A false positive there denies an install-looking command on a broken machine.
SAFEDEPS_RAW_INSTALL_RE="${SAFEDEPS_G_RAW_INSTALL_RE}|[^a-z]npx[[:space:]]"

# The precise install recognizer. It is read on scanned text by
# command_is_dependency_install, and on unscanned text by
# guard_settle_scan_failure, which has to judge without the scanner.
SAFEDEPS_INSTALL_PATTERN="${SAFEDEPS_G_INSTALL_RE}"

if ! command -v jq >/dev/null 2>&1; then
  # jq is required to parse the hook payload. Without it we cannot read the exact
  # command, so do a best-effort fail-closed: read the raw payload and, if it
  # looks like a dependency install, DENY (an install we cannot verify must not
  # proceed). Non-install commands are allowed — jq absence must not block `ls`.
  # Either branch is recorded in advisory.log; never a silent skip.
  raw_input=$(cat)
  log_advisory "pre-guard: jq missing — gate cannot parse the payload."
  # 0 is an install-looking command and 1 is not. Anything else is a grep that
  # could not answer, and with no jq there is nothing else to ask, so it denies.
  raw_rc=0
  printf '%s' "${raw_input}" | grep -qiE "${SAFEDEPS_RAW_INSTALL_RE}" || raw_rc=$?
  if (( raw_rc != 1 )); then
    log_advisory "pre-guard DENY: jq missing on a likely dependency-install command — fail-closed."
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"safedeps: jq is required to gate dependency installs and is not installed — install blocked fail-closed. Install jq, then retry."}}\n'
    exit 0
  fi
  echo "safedeps: jq is not installed — install gate disabled (non-install commands still allowed); logged to advisory.log." >&2
  exit 0
fi

acquire_state_lock() {
  local attempts=0

  while ! mkdir "${STATE_LOCK_DIR}" 2>/dev/null; do
    # Detect stale locks left by SIGKILL/OOM (V-005)
    if [[ -d "${STATE_LOCK_DIR}" ]]; then
      local lock_mtime=""
      # GNU (`-c %Y`, Linux) first, then BSD/macOS (`-f %m`): on Linux `stat -f`
      # means --file-system and would not yield an mtime.
      if lock_mtime=$(stat -c %Y "${STATE_LOCK_DIR}" 2>/dev/null) || \
         lock_mtime=$(stat -f %m "${STATE_LOCK_DIR}" 2>/dev/null); then
        local now
        now=$(date +%s)
        if [[ $(( now - lock_mtime )) -gt 60 ]]; then
          echo "safedeps: removing stale lock ($(( now - lock_mtime ))s old)." >&2
          rmdir "${STATE_LOCK_DIR}" 2>/dev/null || true
          continue
        fi
      fi
    fi

    attempts=$((attempts + 1))
    if [[ ${attempts} -ge ${SAFEDEPS_LOCK_MAX_ATTEMPTS:-100} ]]; then
      # acquire_state_lock is only reached for install candidates, so failing to
      # serialize/snapshot means this install cannot be gated — fail CLOSED (deny).
      log_advisory "pre-guard DENY: state lock unavailable for an install command — fail-closed."
      jq -nc '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:"safedeps: could not acquire the state lock (another safedeps run may be active). Install blocked fail-closed — retry in a moment."}}'
      exit 0
    fi
    sleep 0.1
  done
}

release_state_lock() {
  rmdir "${STATE_LOCK_DIR}" 2>/dev/null || true
}

write_state_file() {
  local target_path="$1"
  local value="$2"
  local target_dir
  local target_base
  local temp_path

  target_dir=$(dirname "${target_path}")
  target_base=$(basename "${target_path}")
  mkdir -p "${target_dir}" || return 1
  temp_path=$(mktemp "${target_dir}/.${target_base}.XXXXXX") || return 1
  printf '%s\n' "${value}" > "${temp_path}"
  mv -f "${temp_path}" "${target_path}"
}

compute_dir_hash() {
  local input_dir="$1"

  if command -v md5sum >/dev/null 2>&1; then
    printf '%s' "${input_dir}" | md5sum | cut -d' ' -f1
  elif command -v md5 >/dev/null 2>&1; then
    md5 -q -s "${input_dir}"
  else
    printf '%s' "${input_dir}" | cksum | cut -d' ' -f1
  fi
}

# Per-install pending-state key (issue #5): dir hash + a hash of the command with
# the inert-install rewrite normalized out, so PreToolUse (original command) and
# PostToolUse (possibly `--ignore-scripts`-appended) of the SAME install resolve to
# the same key. This keeps concurrent installs in one project on separate pending
# files instead of clobbering a single global one. Every ` --ignore-scripts`
# that is a whole word goes, whatever byte follows it. The flag is placed after
# a word, so the byte after it never continues it. A list of the bytes allowed
# to follow it missed `>` and `<` (`x>log` became `x --ignore-scripts>log`),
# the keys differed, and the PostToolUse hook found no pending state: no
# rebuild, and no rollback of an unapproved lockfile. The
# strip loops, because the flag can follow one the command already carried
# (`--cache --ignore-scripts` then ours) and a /g pass took the blank between
# them with the first.
compute_pending_key() {
  local dir_hash="$1" command="$2" norm cmd_hash
  norm=$(printf '%s' "${command}" | sed -E -e ':a' -e 's/[[:space:]]+--ignore-scripts([^=[:alnum:]_-]|$)/\1/' -e 'ta' -e 's/[[:space:]]+/ /g; s/^ //; s/ $//')
  if command -v md5sum >/dev/null 2>&1; then
    cmd_hash=$(printf '%s' "${norm}" | md5sum | cut -d' ' -f1)
  elif command -v md5 >/dev/null 2>&1; then
    cmd_hash=$(md5 -q -s "${norm}")
  else
    cmd_hash=$(printf '%s' "${norm}" | cksum | cut -d' ' -f1)
  fi
  printf '%s_%s' "${dir_hash}" "${cmd_hash}"
}

# A tool on the judgment path that fails is recorded like a failed awk reading
# (see command_scan_text), so the gate settles it. Without this, a predicate
# read a grep or sed that never answered as "no match", and a command that
# names a package manager passed as "not an install" -- the same class the gate
# closes for awk, measured at 267 of 282 corpus commands for each tool.
guard_mark_reading_failed() {
  [[ -z "${SAFEDEPS_SCAN_MARK:-}" ]] || printf 'failed\n' >> "${SAFEDEPS_SCAN_MARK}"
}

# Whether the lexer wrote <flag> into its flags file <file>. A grep that cannot
# answer (2 and up) is recorded and counts as the flag being set: the flag read
# here says a command does not close, and a grep that failed used to read as
# "it closes", which let everything the open quote swallowed go unread.
guard_lex_flag_set() {
  local rc=0
  grep -q "^$1\$" "$2" 2>/dev/null || rc=$?
  (( rc <= 1 )) || guard_mark_reading_failed
  (( rc != 1 ))
}

# grep for a judgment: 0 is a match and 1 is no match. Anything else -- a grep
# that errored, was killed or could not be started -- is not "no match"; it is
# recorded and returns 1, and the gate decides.
judge_grep() {
  local rc=0
  grep "$@" || rc=$?
  (( rc <= 1 )) || guard_mark_reading_failed
  return $(( rc == 0 ? 0 : 1 ))
}

# The texts are read in full before the grep: in a pipe, `grep -q` leaves at
# its first match, the writer then dies of SIGPIPE, and under pipefail a found
# install read as none (measured on form X3 while this was written).
command_is_dependency_install() {
  local texts
  texts=$(command_candidate_start_texts "$1")
  recognized_dependency_install "${texts}"
}

# Whether <texts>, read the way the recognizers read a command (its recognize
# view, or a statement's recognize bytes from the same lexing), hold a
# dependency install. The landing, the ecosystem detection and the spec
# extractor ask this of each statement's recognize bytes: asking
# command_is_dependency_install would lex those bytes again.
recognized_dependency_install() {
  judge_grep -qEi "${SAFEDEPS_INSTALL_PATTERN}" <<< "$1"
}

# recognized_dependency_install for every text in SAFEDEPS_RDI_IN, from one
# grep, for a reader that asks it statement by statement (the landing, the
# spec extractor, the ecosystem detection). One grep per statement, in each
# reading, was the gate's cost per statement: 3,200 one-line statements with
# an install took 45s on the project's Linux VM (scan-cost's statements
# table, deadline off), and 32KB of them was answered UNDECIDED.
#
# SAFEDEPS_RDI_ANS[i] is 0 where the answer for text i is yes, 1 where it is
# no, and 2 where the reader asks recognized_dependency_install itself. grep
# matches each line of its input on its own, as it matches a text of one
# line on a here-string, so line k of the input answers for text k-1. A text
# that holds a newline is not a line: 2. A text with a byte past ASCII is 2
# too, so the input grep reads, and the lines it prints, are ASCII: where a
# byte is not valid in the locale, GNU grep reads the input as binary from
# that point on and prints "binary file matches" in place of the numbered
# lines, and the texts after it would read as no. A grep that does not
# answer, or prints anything but numbered lines, makes every text 2.
#
# Nothing here marks the reading. A text the reader reaches with a 2 is asked
# alone, and that call marks the reading as it always did, so a grep that
# fails here costs what the greps cost before, and a statement the reader
# never reaches is never asked. scripts/test/statement-batch.sh compares
# this, asked alone where it says 2, with recognized_dependency_install.
recognized_dependency_install_each() {
  local i n=${#SAFEDEPS_RDI_IN[@]} all="" flags="" hits="" hit rc=0
  SAFEDEPS_RDI_ANS=()
  (( n > 0 )) || return 0
  # Which texts one line can stand for, one character each, read in the C
  # locale, where a pattern compares bytes. In a UTF-8 locale bash reads an
  # invalid byte together with the bytes after it: `read` took a newline
  # after one as part of the line, so two texts read as one and the second
  # reached grep unflagged.
  flags=$(LC_ALL=C
    hb=$'[\x80-\xff]'
    for t in "${SAFEDEPS_RDI_IN[@]}"; do
      if [[ "${t}" == *$'\n'* || "${t}" == *${hb}* ]]; then printf 2; else printf 1; fi
    done) || flags=""
  if (( ${#flags} != n )); then
    for (( i = 0; i < n; i++ )); do SAFEDEPS_RDI_ANS[i]=2; done
    return 0
  fi
  for (( i = 0; i < n; i++ )); do
    SAFEDEPS_RDI_ANS[i]="${flags:i:1}"
    if [[ "${SAFEDEPS_RDI_ANS[i]}" == 1 ]]; then all+="${SAFEDEPS_RDI_IN[i]}"$'\n'; else all+=$'\n'; fi
  done
  hits=$(grep -nEi "${SAFEDEPS_INSTALL_PATTERN}" <<< "${all%$'\n'}") || rc=$?
  if (( rc > 1 )) || { (( rc == 0 )) && [[ -z "${hits}" || $'\n'"${hits}" =~ $'\n'[^0-9] ]]; }; then
    for (( i = 0; i < n; i++ )); do SAFEDEPS_RDI_ANS[i]=2; done
    return 0
  fi
  while IFS= read -r hit; do
    hit="${hit%%:*}"
    [[ "${hit}" =~ ^[0-9]+$ ]] || continue
    (( SAFEDEPS_RDI_ANS[hit - 1] != 1 )) || SAFEDEPS_RDI_ANS[hit - 1]=0
  done <<< "${hits}"
  return 0
}

command_hides_dependency_install() {
  local command="$1"
  local payload
  local -a pls=()

  # Top-level pipe-to-shell: `<producer> | sh` whose producer text literally
  # contains a package manager + install verb (e.g. `printf 'pip install x' | sh`).
  # The install TEXT is searched raw (in a real hidden install it legitimately
  # lives inside the producer's quotes), but the PIPE must sit in execution
  # position — see payload_pipes_install_text_to_shell. Because outer quoting
  # hides an inner pipe from that position check, every executed inner text
  # (`sh -c` payloads, eval payloads, command substitutions) gets the same check
  # on its own quoting level below.
  payload_pipes_install_text_to_shell "${command}" && return 0

  # The payload readers take the command as written (see
  # extract_shell_c_payloads) and hand the payloads back in PAYLOADS.
  extract_shell_c_payloads "${command}"
  pls=(${PAYLOADS[@]+"${PAYLOADS[@]}"})
  for payload in ${pls[@]+"${pls[@]}"}; do
    [[ -z "${payload}" ]] && continue
    payload_pipes_install_text_to_shell "${payload}" && return 0
  done

  extract_eval_payloads "${command}"
  pls=(${PAYLOADS[@]+"${PAYLOADS[@]}"})
  for payload in ${pls[@]+"${pls[@]}"}; do
    [[ -z "${payload}" ]] && continue
    command_is_dependency_install "${payload}" && return 0
    payload_pipes_install_text_to_shell "${payload}" && return 0
  done

  extract_command_substitution_payloads "${command}"
  pls=(${PAYLOADS[@]+"${PAYLOADS[@]}"})
  for payload in ${pls[@]+"${pls[@]}"}; do
    [[ -z "${payload}" ]] && continue
    command_is_dependency_install "${payload}" && return 0
    payload_pipes_install_text_to_shell "${payload}" && return 0
  done

  return 1
}

# The pipe half of command_hides_dependency_install, asked beside a visible
# install. The question and the texts it is asked of are the standalone ones:
# the command, and its `sh -c`, eval and substitution payloads, each searched
# whole by payload_pipes_install_text_to_shell. The install question on eval and
# substitution payloads is not asked, because beside a visible install those
# payloads are candidate texts already and their specs reach the ledger.
#
# The visible install's own words are not set aside first. That was tried for
# three rounds, and each time the path beside a visible install searched less
# text than the standalone path and passed a pipe the standalone path denies: a
# whole-word search missed `\npip` and `pip\tinstall`, a word-start search missed
# `%spip` and `xpip ... | cut -c2-`, and setting aside the install's own words
# missed `echo "$_ install evil==6.6.6" | sh`, where the shell hands the last of
# those words to the producer. Setting a word aside rests on the claim that it
# prints nothing into the shell, and a producer can read the command's own text
# through `$_`, `$BASH_EXECUTION_STRING`, `ps` or a file, which the gate cannot
# list. So beside a visible install the same pipe gets the same verdict, and a
# command that mixes an install with an unrelated `| sh` is denied: the two run
# as separate commands.
command_pipes_install_to_shell() {
  local command="$1"
  local payload
  local -a pls=()

  payload_pipes_install_text_to_shell "${command}" && return 0
  command_payload_raw_texts "${command}"
  pls=(${PAYLOADS[@]+"${PAYLOADS[@]}"})
  for payload in ${pls[@]+"${pls[@]}"}; do
    [[ -z "${payload}" ]] && continue
    payload_pipes_install_text_to_shell "${payload}" && return 0
  done
  return 1
}

# The shell, as far as the gate reads it: one pass over the command in awk that
# follows the lexical state the shell keeps -- quotes (single, double, $'...'),
# escapes, comments, heredoc operators and their bodies, arithmetic, command
# and parameter substitution, backticks and line continuations -- and gives
# every byte a class. Each view is printed from those classes, so every reader
# of the command reads the same lexing:
#
#   scan    quoted text, comments, heredoc operators and bodies blanked; an
#           escaped operator is `_`. What the detection predicates read.
#   code    comments, heredoc operators and bodies blanked; quotes kept.
#   cscripts, substs  the scripts the command hands to a shell (`sh -c`,
#           `eval`) and the bodies of its substitutions, one record each: the
#           payloads, which are scripts of their own and the one text a
#           reader lexes besides the command.
#   pieces  the statements, cut where command_statements cuts them, each with
#           its words after quote removal, with and without its prefixes,
#           and its recognize bytes. What the spec extractor, the landing and
#           the inert reading read.
#   shell-bodies  the bodies of heredocs whose command pipes into something.
#   live    scan, with code nested in quotes ("$(...)") and live code in an
#           unquoted heredoc body kept, and every top-level redirection
#           blanked but the body of a process substitution in its target:
#           every byte the shell runs at this level, with nothing between a
#           command and its arguments. What the inert rewrite reads.
#   flat    live, with every top-level redirection blanked whole, the body of
#           a substitution in its target too. The inert rewrite reads it
#           beside the live view: there a command and its arguments are side
#           by side when a redirection whose target holds a substitution
#           stands between them (`npm >$(echo f) install x`).
#   stmts   scan, with every `;`, `&` or `|` that is not at the top level (in
#           arithmetic, a substitution, a redirection operator) written `_`,
#           since it ends nothing: a separator here is one the shell reads.
#           Length-preserving and idempotent. It carries no statement start.
#   recognize  what the install recognizers read (command_start_text): the
#           stmts view with the prefixes of each command removed, as
#           unprefixed removes them, every other top-level redirection
#           blanked, a line continuation dropped, and a `;` put in at each
#           statement start that no separator already stands before. Not
#           length-preserving.
#
# A reader lexes the command, or a payload, and nothing else: never the output
# of a view. A view changes bytes, and a text a view changed reads out of the
# context the first lexing had. Each reader that did so lost the line after a
# heredoc: the joined view kept the live code of an unquoted body (`$(date)`)
# and blanked the terminator line, so lexed again, that code stood where the
# next command did and took it for an argument (verdict buri-20261005-145152).
# scripts/test/scan-contract.sh traces every lexing of a guard run and holds
# each input to the command, a payload, or a piece of one.
#
# Where a command starts is not a byte. The walk over the words (starts() in
# the awk) follows the shell grammar and says where each command starts: an
# event between two bytes, which a view delivers by putting a separator in
# (recognize), by cutting there (stmtcuts, read by command_statements), or by
# listing it (events, cwords). The stmts view used to write each start over
# the byte before it, and a start with no byte of its own before it -- after a
# reserved word, `!`, a head's `)` or zsh's glued `{`, with a redirection
# first -- borrowed a byte of the token before or was lost: `then>/dev/null
# pip install x` was no install to any recognizer, and each repair borrowed
# one more byte (verdict bamdori-20261004-224625).
#
# It replaced three state machines that ran one after another -- a line-based
# heredoc regex, a line joiner and the quote scanner -- and had to agree. They
# did not: across three review rounds a heredoc read twice, read where there
# was none, or not read where there was one, and each time the lines after it
# vanished from the gate (fail-open). A design review measured 60 forms against
# bash and zsh: 31 hid a line the shell runs before this, 27 after the last
# regex repair, 0 with this lexer. scan and code keep the input's byte length
# and are idempotent, so reading a view again changes nothing -- which is why
# stripping twice can no longer drop anything.
#
# A reading is a shell: bash, zsh or dash, named by SAFEDEPS_READING. The three
# lex the same text differently in a few places (ARCHITECTURE.md has the table:
# `((`, `$((`, quotes inside arithmetic, `$[`, an apostrophe inside "${...}",
# `$'...'`, `&>`), and a command is judged under every reading a shell could give it.
# Nothing here picks a reading: the guard's driver sets the variable, once per
# reading, and every reader of the command lexes under it, including a reader
# that lexes text another reader handed it. A reading picked per call was how
# a line zsh runs was re-lexed the bash way one step later and hidden again
# (verdict bogeuli-20261001-234308, form SL1). A call with no reading set is a
# reader outside the driver, and it fails the reading rather than guess one.
#
# Where a lexing passes a place the readings answer differently, it appends
# DIVERGE to the file in SAFEDEPS_LEX_DIVERGE. The readings agree byte for byte
# up to the first such place, and the bash reading passes it in the same state,
# so the bash reading alone can say whether the others are needed. A reading
# that ends inside a quote, a body or a context reports UNTERM to the file in
# SAFEDEPS_LEX_FLAGS; guard_check_command_reads records that as a failed reading.
#
# One awk pass over a split array, emitted through a bounded buffer, so the
# cost is linear (see scripts/measure/scan-cost.sh). When awk fails it says so
# in SAFEDEPS_SCAN_MARK and returns non-zero, as every reading does.
shell_lex() {
  local text="$1" view="$2" marker="$3" policy="${SAFEDEPS_READING:-}" memo="" out tmp div=""
  case "${policy}" in
    bash|zsh|dash) ;;
    *)
      [[ -z "${SAFEDEPS_SCAN_MARK:-}" ]] || printf 'failed\n' >> "${SAFEDEPS_SCAN_MARK}"
      return 1
      ;;
  esac
  # One guard run reads the same text through the same view several times (25
  # lexer calls for 11 distinct inputs on a 32KB install command, measured).
  # Above 4KB, where a pass costs more than looking one up, a view is kept for
  # the rest of the run. The key only picks the file: a hit also requires the
  # stored text to equal this one byte for byte, because a checksum is easy to
  # collide on purpose and the command is the attacker. A run that asks for
  # flags is not memoized, since the flags are a side output. DIVERGE is a side
  # output too, and a hit must still report it, so the pass that fills an entry
  # leaves a .div beside it when it diverged. Nothing removes a .div: one left
  # by another text under a colliding key costs a reading, never a missed one.
  if [[ -n "${SAFEDEPS_LEX_CACHE:-}" && -d "${SAFEDEPS_LEX_CACHE}" && -z "${SAFEDEPS_LEX_FLAGS:-}" && ${#text} -gt 4096 ]]; then
    memo="${SAFEDEPS_LEX_CACHE}/${view}.${policy}.$(printf '%s' "${text}" | cksum | tr ' ' '.')"
    if [[ -f "${memo}.out" && -f "${memo}.in" ]] && [[ "$(cat "${memo}.in"; printf 'X')" == "${text}X" ]]; then
      if [[ -f "${memo}.div" && -n "${SAFEDEPS_LEX_DIVERGE:-}" ]]; then
        printf 'DIVERGE\n' >> "${SAFEDEPS_LEX_DIVERGE}" || {
          [[ -z "${SAFEDEPS_SCAN_MARK:-}" ]] || printf 'failed\n' >> "${SAFEDEPS_SCAN_MARK}"
          return 1
        }
      fi
      cat "${memo}.out"
      return 0
    fi
    div="${memo}.div"
  fi
  # The executables and the shells the grammar names: a command word that is
  # a path to one of them reads as the bare name (prefixes() in the awk), and
  # a shell word hands the script after -c to the payload reader (cscripts).
  # Empty where the grammar is not loaded; every reader of the views loads it.
  local exre="" shre=""
  [[ -z "${SAFEDEPS_G_EXECUTABLES:-}" ]] || exre="^(${SAFEDEPS_G_EXECUTABLES}|${SAFEDEPS_G_SHELLS})\$"
  [[ -z "${SAFEDEPS_G_SHELLS:-}" ]] || shre="^(${SAFEDEPS_G_SHELLS})\$"
  if ! out=$(printf '%s\n' "${text}" | LC_ALL=C awk -v view="${view}" -v policy="${policy}" -v marker="${marker}" -v divfile="${SAFEDEPS_LEX_DIVERGE:-}" -v divmemo="${div}" -v smark="${SAFEDEPS_SCAN_MARK:-}" -v exre="${exre}" -v shre="${shre}" '
      # One pass over the command as the shell lexes it. Every byte gets a class,
      # and each view is printed from the classes:
      #
      #   c  code                        x  escaping backslash (outside quotes)
      #   e  escaped byte (outside)      l  line continuation (backslash, newline)
      #   q  quoted text                 Q  code nested inside quotes ("$(...)")
      #   m  comment                     h  heredoc operator and delimiter word
      #   b  heredoc body (data)         B  live code in an unquoted heredoc body
      #
      # view=scan    quoted text, comments, heredoc operators and bodies blanked;
      #              an escaped operator is `_`, and a `}` glued to a word
      #              that closes no group is `%` (group_close); length-preserving
      #   view=stmts   scan, with a nested `;` `&` `|` as `_`; length-preserving
      #   view=recognize  stmts with the prefixes of each command removed (the
      #              A of the unprefixed view), every other top-level redirection
      #              blanked, a line continuation dropped, and a `;` put in
      #              before each start event no separator stands before (bare);
      #              not length-preserving
      #   view=stmtcuts  the offsets of the bare start events on the first
      #              line, space-separated, then the stmts view: where
      #              command_statements cuts
      #   view=stmtraw  the bytes command_statements reads words from: a
      #              comment, a heredoc operator, a heredoc body and the live
      #              code in one blank, a newline inside quotes blank, and each
      #              byte of a line continuation \001; length-preserving
      #   view=events  one line per event of this reading, in byte order:
      #              `S <offset> <class> <depth> <bare> <class before>` where
      #              a command starts (its first byte, a prefix included) and
      #              `W <offset> <class> <depth>` at the word the walk reads as
      #              its command or reserved word. For scan-contract.
      #   view=cwords  one line per start event: its offset, the offset of
      #              the first byte the prefixes leave, the stmts bytes of the
      #              prefixes, the recognize bytes of the statement from
      #              there to its end, and the stmts bytes of the same
      #              statement, \037 between them. For the event contract in
      #              scan-contract.
      #   view=wordends  the stmts view as a mask: 1 at each byte where the
      #              lexer ends a word that a word byte stands before, 0
      #              elsewhere; length-preserving. For scan-contract.
      #   view=code    comments, heredoc operators and bodies blanked, quotes kept;
      #              length-preserving
      #   view=shell-bodies  the raw lines of heredoc bodies whose command pipes
      #              into something
      #   view=substs  the body of every command substitution, one after another,
      #              as the shell delimits it: `$(...)` (case patterns inside close
      #              nothing) and backticks, a backtick body unescaped the way the
      #              shell unescapes it (`\`` nests), and the body of every
      #              process substitution, each ending in \035. For the payload
      #              extractor.
      #   view=unprefixed  the text with the prefixes a statement may start with
      #              removed: assignments (NAME=value, the value one word however
      #              it is quoted or nested), redirections with their targets,
      #              env with its options and assignments, command and exec, at
      #              every start event of the walk; and every other top-level
      #              redirection blanked, as noredir blanks it. Raw bytes
      #              otherwise. No reader of the guard takes it: scan-contract
      #              holds the prefix rules (A) on it, which recognize and
      #              pieces read. Not length-preserving.
      #   view=noredir  every top-level redirection blanked: the operator, the
      #              file descriptor word in front of it (a number or a {name}
      #              that is the whole word), and the target word, a process
      #              substitution whole. An operator inside quotes, a
      #              substitution or after a backslash is a character, and one in
      #              the middle of a word still is an operator
      #              (`x==1>/dev/null`), as the shell reads it. A process
      #              substitution that is an argument (`cat <(x)`) stays.
      #              length-preserving
      #   view=pieces  one output line per statement that holds a word, cut
      #              where command_statements cuts (a top-level separator, as
      #              the stmts view has it, or a bare start event), and
      #              numbered as it numbers them:
      #              `<n>\037<raw>\037<words>\037<uwords>\037<rec>`. <raw> is the
      #              statement as the noredir view has it. <uwords> is <words>
      #              without the prefixes of the statement (the A of the
      #              unprefixed view), and <rec> is the statement as the
      #              recognize view has it, one line. <words> is the same bytes
      #              after the shell quote
      #              removal: the quote characters go, and so does an escaping
      #              backslash outside quotes or inside double quotes before
      #              $ ` " \; a $\047...\047 escape is decoded; code nested in a
      #              substitution is kept as written. A $\047...\047 escape whose
      #              value this cannot name (\u, \U, \c, a NUL, a byte past 127)
      #              adds a line `!`, so the reader can record the failure. For
      #              the spec extractor.
      #
      # policy is the reading: bash, zsh or dash. Where they lex the same text
      # differently (the table in ARCHITECTURE.md, each cell measured in
      # scripts/measure/shell-reading-forms.json):
      #
      #   `((`         bash and zsh look ahead to the first unnested `)`:
      #                followed by `)` it is arithmetic, otherwise a subshell,
      #                and with none it is arithmetic left open. bash honors
      #                quotes in that look-ahead and zsh reads a bare quote as a
      #                character; both step over `$(...)`, backticks, `${...}`
      #                and an escape whole. dash: always a subshell.
      #   `$((`        bash and zsh as above; dash: always arithmetic.
      #   quotes inside arithmetic: bash honors them; zsh and dash read a
      #                character.
      #   `$[`         bash and zsh: arithmetic, as above; dash: plain text.
      #   `\047` inside "${...}": a quote to bash, a character to zsh and dash.
      #   `$\047...\047`  bash and zsh: an ANSI-C string, where \\047 does not
      #                close it; dash: `$` and a single-quoted string.
      #   `&>`         bash and zsh: a redirection of both outputs; dash: `&`,
      #                which ends a command, then `>` before the next one.
      #   `(` glued to a word, or where an argument stands: bash and zsh read
      #                a glob group or qualifier, part of the word (zsh runs
      #                it; bash 5 fails to parse it without extglob); dash:
      #                an operator.
      #   `NAME[...]=` bash pairs the brackets, so a blank inside is part of
      #                the assignment word; zsh and dash end the word there.
      #   `<N-M>`      zsh: a glob for a range of numbers, bytes of a word;
      #                bash and dash: two redirections.
      #   `noglob` `nocorrect` `-` `builtin` before a command: zsh reads a
      #                precommand modifier and the command after it; bash
      #                and dash read a command and its arguments.
      #   `}` glued to the end of a word, before a blank, an operator, a
      #                closing backtick or the end: zsh closes an open `{`
      #                group there and hands the word before it on (`{ p ci}`
      #                hands `ci`); bash and dash read a character. See
      #                group_close below.
      #
      # Each site is decided per shell where it stands: zsh read one `((` as a
      # subshell and the next as arithmetic in one command (form M1), which no
      # switch for the whole command can follow. A reading that passes a site
      # where the three answer differently writes DIVERGE (see shell_lex).
      # Flags go to ENVIRON["SAFEDEPS_LEX_FLAGS"] when set: UNTERM (the input
      # ended inside a quote, a heredoc body or a nested context).
      BEGIN { n = 0; started = 0 }
      {
        if (started) X[++n] = "\n"
        started = 1
        m = split($0, ch, "")
        for (j = 1; j <= m; j++) X[++n] = ch[j]
        if (index($0, "}")) hasbrace = 1
      }
      END {
        N = n
        # The wordends view is the stmts view read as a mask: `1` where the
        # lexer ends a word at the byte (word_sep, with a word byte before
        # it), `0` elsewhere. scan-contract holds the stmts view to printing
        # each such byte as one SAFEDEPS_G_END reads as a word end.
        wends = (view == "wordends")
        if (wends) view = "stmts"
        d = 1; ctx[1] = "T"; par[1] = 0; dq = 0; dc = 1
        # The bytes any rule below acts on. Every other byte keeps the class of
        # its context and changes nothing, so it is classified without running
        # the rules -- most of a long command is such bytes.
        split("\\ $ \047 \042 # ( ) < [ ] } ` c e i ; &", sl, " ")
        for (j in sl) SPC[sl[j]] = 1
        SPC["\n"] = 1
        DQS["\\"] = 1; DQS["\042"] = 1; DQS["$"] = 1; DQS["`"] = 1
        # The views that walk the words for where each command starts.
        wantst = (view == "recognize" || view == "stmtcuts" || view == "events" || view == "cwords" || view == "unprefixed" || view == "pieces")
        # The views that print a `}` as the close of a group or as a
        # character (group_close), which needs the group openers of the walk.
        wantgrp = hasbrace && (wantst || view == "scan" || view == "stmts" || view == "live" || view == "flat")
        wantdep = (wantst || wantgrp || view == "noredir" || view == "pieces" || view == "cscripts" || view == "stmts" || view == "live" || view == "flat")
        wantar = wantst || wantgrp
        # The value of each one-letter escape in $\047...\047, in every view.
        # A lexing fact is the same whichever view asks for it: this table
        # was loaded for the pieces view alone, so the cscripts view read
        # `sh -c $\047echo a\\npip install x\047` as a backslash and an n,
        # one statement after echo, and the install passed with nothing
        # recorded (v2.18.1 on).
        AQV["a"] = "\007"; AQV["b"] = "\010"; AQV["e"] = "\033"; AQV["E"] = "\033"
        AQV["f"] = "\014"; AQV["n"] = "\n"; AQV["r"] = "\r"; AQV["t"] = "\t"; AQV["v"] = "\013"
        AQV["\\"] = "\\"; AQV["\047"] = "\047"; AQV["\042"] = "\042"; AQV["?"] = "?"
        # The code of each byte an escape can decode to, for the payload
        # records (emit_cscripts).
        if (view == "cscripts") for (j = 1; j < 128; j++) ORD[sprintf("%c", j)] = j
        mode = ""; np = 0; unterm = 0; hn = 0; hstop = 0; div = 0
        shb = (policy == "bash"); shz = (policy == "zsh"); shd = (policy == "dash")
        for (i = 1; i <= N; i++) {
          # An unquoted heredoc body ends where at_newline found its terminator
          # line: close what is open in it (a substitution left open there never
          # closes, as in the shell) and step over the terminator.
          if (hn > 0 && i == hstop + 1) {
            # A substitution left open in a body fails that one heredoc in the
            # shell; the lines after it still run (form H29), so it is dropped,
            # not counted as a command that never closes. Its bytes become body
            # data, from the opener on: they run nowhere, and left as live code
            # a reader that lexed the joined lines again (none does now) read
            # them out of the body, where the open context ran on into the
            # lines after it (an open arithmetic with a quote in it took the
            # install after the body along, fuzz form F19).
            if (d > 1 && ctx[d] != "H") {
              for (kk = d; kk > 1 && ctx[kk-1] != "H"; kk--) ;
              for (j = cst[kk]; j > 1 && (X[j-1] == "$" || X[j-1] == "(") && C[j-1] != "b"; j--) ;
              for (; j < i; j++) C[j] = "b"
            }
            while (d > 1 && ctx[d] != "H") pop()
            pop(); hstop = 0; mode = ""
          }
          if (i in JMP) { i = JMP[i]; continue }
          if (i in HSTART) { push("H"); hstop = HEND[HSTART[i]] }
          c = X[i]
          # A comment has the depth of the context it stands in: one among the
          # elements of an array value, or inside a substitution, is nested
          # with them and ends no word at the top level.
          if (wantdep) DEP[i] = (mode == "" || mode == "CM") ? dc : 99
          # RM marks what the shell quote removal takes out of a top-level word
          # (qtop: the quote was opened at the top level, not in a substitution
          # or an expansion). Only the pieces view reads it.
          if (mode == "SQ") { C[i] = "q"; if (c == "\047") { mode = ""; if (qtop) RM[i] = 1 }; continue }
          if (mode == "AQ") {
            C[i] = "q"
            # dash has no ANSI-C string: to it `\\` ends nothing and the
            # escaped quote closes the string (form AC1).
            if (c == "\\") { if (X[i+1] == "\047") div = 1; if (qtop) aq_escape(i); i++; C[i] = "q" }
            else if (c == "\047") { mode = ""; if (qtop) RM[i] = 1 }
            continue
          }
          if (mode == "CM") {
            if (c == "\n") { mode = ""; i = at_newline(i) }
            # A comment inside backticks ends at the closing backtick: the shell
            # cuts the backtick body out before it reads the comment (form P3).
            else if (c == "`" && ctx[d] == "B") { mode = ""; C[i] = (dq > 0) ? "Q" : "c"; pop() }
            else C[i] = "m"
            continue
          }
          top = ctx[d]
          if (top == "D") {
            C[i] = "q"
            if (!(c in DQS)) continue
            if (c == "\\") {
              if (X[i+1] == "\n") { C[i] = "l"; C[i+1] = "l"; if (dc == 2) { RM[i] = 1; RM[i+1] = 1 }; i++ }
              else { if (dc == 2 && (X[i+1] in DQS)) RM[i] = 1; i++; C[i] = "q" }
            }
            else if (c == "\042") { if (dc == 2) RM[i] = 1; pop() }
            else if (c == "$" && X[i+1] == "(" && X[i+2] == "(") { C[i+1] = "q"; C[i+2] = "q"; arith_or_sub(i, 1) }
            else if (c == "$" && X[i+1] == "(") { C[i+1] = "q"; i++; push("S") }
            else if (c == "$" && X[i+1] == "{") { C[i+1] = "q"; i++; push("V") }
            else if (c == "`") push("B")
            continue
          }
          if (top == "H") {
            # Body bytes are data. In an unquoted body the shell performs
            # parameter, command and arithmetic substitution, and a backslash
            # escapes only $, ` and \ -- the main loop reads those, so a
            # substitution in a body is lexed by the same rules as anywhere else,
            # across lines too (forms X3-X6, X10).
            C[i] = "b"
            if (!(c in DQS)) continue
            if (c == "\\") { if (X[i+1] == "$" || X[i+1] == "`" || X[i+1] == "\\" || X[i+1] == "\n") { i++; C[i] = "b" } continue }
            # An opener is live code like what it opens, so every view keeps the
            # substitution whole (form E2).
            if (c == "$" && X[i+1] == "(" && X[i+2] == "(") { C[i] = "B"; C[i+1] = "B"; C[i+2] = "B"; arith_or_sub(i, 1); continue }
            if (c == "$" && X[i+1] == "(") { C[i] = "B"; C[i+1] = "B"; i++; push("S"); continue }
            if (c == "$" && X[i+1] == "{") { C[i] = "B"; C[i+1] = "B"; i++; push("V"); continue }
            if (c == "`") { C[i] = "B"; push("B"); continue }
            continue
          }
          cls = (dq > 0) ? "Q" : (hn > 0 ? "B" : "c")
          C[i] = cls
          # The top of an arithmetic context, where `;` `&` `|` are operators
          # and end no statement. Not inside its parentheses: there `$(...)`
          # is still a command substitution the shell runs.
          if (wantar && (top == "K" || top == "A" && par[d] == 0)) AR[i] = 1
          # A blank or an operator inside the subscript of an assignment word is
          # part of the word to bash alone (see the `[` rule below).
          if (top == "W" && wkind[d] == "s" && c ~ /[ \t\n;&|()<>]/) div = 1
          if (!(c in SPC) && !(top == "C" && cpat[d] == 1)) continue
          if (c == "\\") {
            if (X[i+1] == "\n") { C[i] = "l"; C[i+1] = "l"; if (dc == 1) { RM[i] = 1; RM[i+1] = 1 }; i++; continue }
            # Inside backticks an escaped backtick opens or closes a nested one.
            if (top == "B" && X[i+1] == "`") {
              C[i+1] = cls; i++
              if (besc[d]) pop(); else { push("B"); besc[d] = 1 }
              continue
            }
            if (dq > 0) { i++; C[i] = "Q"; ESC[i] = 1; continue }
            C[i] = "x"; if (dc == 1) RM[i] = 1; if (i < N) { i++; C[i] = "e" }
            continue
          }
          # dash reads `$` and a single-quoted string: the same extent unless
          # an escaped quote is inside (AQ above), so the `$` is blanked with
          # the string as bash blanks it, and only its word value differs.
          if (c == "$" && X[i+1] == "\047" && shd) { C[i] = "q"; continue }
          if (c == "$" && X[i+1] == "\047") {
            C[i] = "q"; C[i+1] = "q"; qtop = (dc == 1); if (qtop) { RM[i] = 1; RM[i+1] = 1 }
            i++; mode = "AQ"; continue
          }
          if (c == "\047") {
            # Inside arithmetic, and inside "${...}" within double quotes, bash
            # opens a quote here; zsh and dash read a plain character (forms
            # QM, P4, Q6).
            if (top == "A" || top == "K" || top == "V" && dq > 0) { div = 1; if (!shb) continue }
            C[i] = "q"; mode = "SQ"; qtop = (dc == 1); if (qtop) RM[i] = 1; continue
          }
          if (c == "\042") {
            if (top == "A" || top == "K") { div = 1; if (!shb) continue }
            C[i] = "q"; if (dc == 1) RM[i] = 1; push("D"); continue
          }
          # case ... esac: a pattern close `)` closes no substitution (form P8).
          if ((c == "c" || c == "e") && wordstart(i) && (i + 4 > N || X[i+4] ~ /[ \t\n;&|()<>]/)) {
            w4 = X[i] X[i+1] X[i+2] X[i+3]
            if (w4 == "case" && (cmdpos(i) || namehead(i))) { C[i+1] = cls; C[i+2] = cls; C[i+3] = cls; i += 3; push("C"); continue }
            # `esac` ends the case where a pattern list could start, not as a
            # pattern word after `|` (`*|esac)`, form X7).
            if (w4 == "esac" && top == "C" && !(cpat[d] == 1 && cpw[d])) { C[i+1] = cls; C[i+2] = cls; C[i+3] = cls; i += 3; pop(); continue }
          }
          # Inside case: after `in`, and after each `;;` `;&` `;;&`, a pattern
          # runs to its `)`, which ends the pattern -- class p, read by the
          # stmts view as a statement boundary, so the arm is judged. Only at
          # the top level: inside a substitution the close is a `)` of the
          # body like any other, nested with it, so a reader of class p never
          # has to ask how deep it is. Classed p there, it ended the value of
          # `x=$(case a in a) echo f;; esac)` and the target of `>$(case ...)`
          # at the pattern (form WC3).
          if (top == "C") {
            if (cpat[d] == 0 && c == "i" && X[i+1] == "n" && wordstart(i) && (i + 2 > N || X[i+2] ~ /[ \t\n;&|()<>]/)) { C[i+1] = cls; i++; cpat[d] = 1; cpw[d] = 0; continue }
            if (cpat[d] == 1 && c == "(" && !cpw[d]) { CPO[i] = 1; continue }
            if (cpat[d] == 1 && c == ")") { if (dc == 1) C[i] = "p"; cpat[d] = 2; continue }
            if (cpat[d] == 1 && c !~ /[ \t\n]/) cpw[d] = 1
            # An arm ends at `;;` or `;&` (forms X8, X9), at `;;&` in bash and
            # at `;|` in zsh. The other shells fail to parse those two, so
            # each is its own reading rule and the bash reading says DIVERGE
            # at both.
            if (cpat[d] == 2 && c == ";" && (X[i+1] == "|" || X[i+1] == ";" && X[i+2] == "&")) div = 1
            # The bytes after the first `;` are the rest of one operator:
            # at the top level ARM marks them, so no word reader takes them
            # for a word (the walk read the second `;` of `;;` as a command
            # word). Inside a substitution they are bytes of its word.
            if (cpat[d] == 2 && c == ";" && (X[i+1] == ";" || X[i+1] == "&" || X[i+1] == "|" && shz)) {
              C[i+1] = cls; i++; if (dc == 1) ARM[i] = 1
              if (X[i] == ";" && X[i+1] == "&" && shb) { C[i+1] = cls; i++; if (dc == 1) ARM[i] = 1 }
              cpat[d] = 1; cpw[d] = 0; continue
            }
          }
          if (top == "A" || top == "K") {
            if (top == "K") { if (c == "]") pop(); continue }
            if (c == "(") par[d]++
            # The `))` that closes an arithmetic command ends its word, as the
            # `((` that opens it starts one: bash and zsh read `((...))` as a
            # token of its own, so a reserved word or a group glued after it
            # is a word of its own (`for ((i=0;i<1;i++)){ pip install x; }`,
            # `for ((...))do`). ACL marks it for the walk. The close of `$((`
            # is a byte of the word it stands in.
            else if (c == ")") { if (par[d] > 0) par[d]--; else if (X[i+1] == ")") { i++; C[i] = cls; if (adol[d]) WC[i] = 1; else ACL[i] = 1; pop(); if ((i in ACL) && wantdep) DEP[i] = dc } }
            else if (c == "\n") i = at_newline(i)
            continue
          }
          if (c == "#" && (wordstart(i) || top == "B" && X[i-1] == "`") && top != "V" && !(top == "W" && wkind[d] != "a")) {
            # Inside a glob word (see GL below) a `#` is a glob operator, never
            # a comment (form G5); inside a subscript it is a character. Among
            # the elements of an array value it opens a comment as anywhere
            # (form WA10).
            if (glc[d] > 0) { div = 1; continue }
            C[i] = "m"; mode = "CM"; continue
          }
          if (c == "$" && X[i+1] == "(" && X[i+2] == "(") { C[i+1] = cls; C[i+2] = cls; arith_or_sub(i, 1); continue }
          # `((` is decided wherever it stands, not only where a command starts:
          # a hand list of command positions missed backticks, case patterns,
          # coproc and time -p (forms P1, P2, P15, Q2).
          # Not where the first `(` opens a process substitution (`<((pip
          # install x))`, a subshell inside one, which bash and zsh run, form
          # PS1) or zsh `=(`: the shell reads that opener before it looks for
          # arithmetic, and the `(` rule below reads it.
          if (c == "(" && X[i+1] == "(" && !(i > 1 && (X[i-1] == "<" || X[i-1] == ">") && C[i-1] == cls) && wparen(i) != "z") { C[i+1] = cls; arith_or_sub(i, 0); continue }
          if (c == "$" && X[i+1] == "(") { C[i+1] = cls; i++; push("S"); continue }
          # dash has no `$[`: the bytes are a word, quotes and comments in it
          # read as anywhere else (forms K1, K2).
          if (c == "$" && X[i+1] == "[") { div = 1; if (shd) continue; C[i+1] = cls; i++; push("K"); continue }
          if (c == "$" && X[i+1] == "{") { C[i+1] = cls; i++; push("V"); continue }
          if (c == "`") { if (top == "B") pop(); else push("B"); continue }
          if (top == "V") { if (c == "}") pop(); continue }
          # Every other `}` here is one the shell may read as the close of a
          # `{` group: one standing as a word, or one glued to the end of the
          # word before it, which zsh reads as a close there. Which of them
          # closes one is decided after the walk, from the groups the walk
          # opened (group_close); RBT marks the ones at the top level, where
          # the walk reads the words.
          if (c == "}") { RB[i] = 1; if (dc == 1) RBT[i] = 1; continue }
          # `&>` is one redirection operator to bash and zsh. dash has none:
          # the `&` ends the command before it, and the `>` is a redirection
          # that the next command starts with (forms AR1-AR13), so
          # `echo a &>/dev/null pip install x` runs the install in dash
          # alone. redirs() and starts() read it per reading, and the bash
          # reading says DIVERGE here. After `>` or `<` the `&` belongs to a
          # duplication (`2>&1`) in every shell.
          if (c == "&") { if (X[i+1] == ">" && !(i > 1 && X[i-1] ~ /[<>]/ && C[i-1] == cls)) div = 1; continue }
          # A subscript glued to a name at the start of a word, with `=` or
          # `+=` after its `]`, is part of an assignment word (SUBC holds its
          # close). bash reads the brackets as a pair wherever a command may
          # start, whatever they hold, so a blank inside ends no word there
          # (`a[1 + 1]=x pip install x` runs the install in bash alone, form
          # WA18): a context in the bash reading, which says DIVERGE at a blank
          # or an operator inside. zsh and dash cut the word at the blank.
          if (c == "[") {
            if (top == "W" && wkind[d] == "s") { sbr[d]++; continue }
            if (subname(i) && (wk = la_sub(i + 1)) && (X[wk] == "=" || X[wk] == "+" && X[wk+1] == "=")) {
              SUBC[i] = wk - 1
              if (shb) { push("W"); wkind[d] = "s"; sbr[d] = 0; if (wantdep) DEP[i] = dc }
            }
            continue
          }
          if (c == "]") {
            if (top == "W" && wkind[d] == "s") { if (sbr[d] > 0) sbr[d]--; else { SUBC[cst[d]] = i; pop() } }
            continue
          }
          # A parenthesis the shell reads as part of a word opens a context,
          # like `$(...)`, so every byte up to its `)` is nested: no blank or
          # operator in it ends the word, and no reader has to know why
          # (word_sep reads the depth). wparen() says which one this is:
          #
          #   a  the value of an array assignment, `NAME=(`, `NAME+=(` (bash,
          #      zsh). Its elements are words, so comments, quotes and
          #      substitutions read as anywhere (W, kind a).
          #   z  zsh `=(...)` at the start of a word: a process substitution
          #      through a temporary file. Its body runs, so it is a payload
          #      like `$(...)` (S, in substs).
          #   g  a glob group or qualifier glued to a word (zsh, and bash 3.2
          #      inside a substitution): a `#` in it is no comment (form G5).
          #      bash 5.2 and dash fail to parse it, so the bash reading says
          #      DIVERGE (W, kind g).
          #
          # `<(` and `>(` open a process substitution, in a word or as one:
          # its body runs and is a payload too (kind P), and the `<` or `>`
          # that opens it is a byte of that word, not an operator, so it
          # takes the depth of the body. Read at the top level, the opener
          # ended the word before it and three readers each needed a rule of
          # their own for the word after it (form W1).
          #
          # Any other `(` is an operator: a subshell, a function head, or in
          # zsh a glob word that starts where an argument stands (`ls
          # (a|b)*`). GL marks that level for the bash and zsh readings, glc
          # counts the open ones so that a `#` in it or after its `)` is no
          # comment (form ZG1), and the bash reading says DIVERGE. GLO marks
          # one the walk reads as that glob, for the consistency check in
          # starts().
          if (c == "(") {
            wk = wparen(i)
            if (wk == "z") { push("S"); if (wantdep) DEP[i] = dc; continue }
            if (wk == "a" || wk == "g") { if (wk == "g") div = 1; push("W"); wkind[d] = wk; WPO[i] = 1; if (wantdep) DEP[i] = dc; continue }
            if (i > 1 && (X[i-1] == "<" || X[i-1] == ">") && C[i-1] == cls) {
              push("S"); skind[nsub] = "P"; PSN[i] = nsub
              if (wantdep) { DEP[i] = dc; DEP[i-1] = dc }
              continue
            }
            par[d]++
            if (!shd && !emptyahead(i) && (i == 1 || X[i-1] !~ /[$<>]/) && !cmdpos(i) && !forlist(i)) { GL[d, par[d]] = 1; GLO[i] = 1; glc[d]++; div = 1 } else delete GL[d, par[d]]
            continue
          }
          if (c == ")") {
            if (par[d] > 0) {
              if ((d, par[d]) in GL) { WC[i] = 1; delete GL[d, par[d]]; glc[d]-- }
              par[d]--
            }
            else if (top == "S" || top == "W" && wkind[d] != "s") { WC[i] = 1; pop() }
            continue
          }
          if (top == "W" && wkind[d] == "s") continue
          # zsh reads `<N-M>`, with either number left out, as a glob for a
          # range of numbers: bytes of a word, where bash and dash read two
          # redirections (`pip >f<1-2> install x` runs the install in zsh
          # alone when a file matches; to bash `install` is a target). In the
          # zsh reading the `<` and `>` are characters, as escaped ones are,
          # and the bash reading says DIVERGE.
          if (c == "<" && cls == "c" && (wk = numglob(i))) {
            div = 1
            if (shz) {
              C[i] = "e"
              for (i++; i < wk; i++) { C[i] = cls; if (wantdep) DEP[i] = dc }
              C[i] = "e"; if (wantdep) DEP[i] = dc
              continue
            }
          }
          if (c == "<" && X[i+1] == "<" && X[i+2] != "<" && X[i-1] != "<") { i = heredoc_op(i); continue }
          if (c == "\n") { i = at_newline(i); continue }
        }
        if (mode == "SQ" || mode == "AQ" || d > 1 || np > 0) unterm = 1
        flagfile = ENVIRON["SAFEDEPS_LEX_FLAGS"]
        if (flagfile != "" && unterm) print "UNTERM" >> flagfile
        # A reading that never closes strips nothing: a prefix word would run to
        # the end of the input and take every line after it along (form A7, a
        # heredoc inside `$((` that bash reads as arithmetic). Such a command is
        # settled as UNDECIDED by guard_check_command_reads anyway.
        # Statement starts are read only from a reading that closes, for the
        # same reason: a word walk through a quote or a body that never ends
        # marks starts the shell never reads. The walk comes before redirs(),
        # which reads its events: a descriptor word starts a word where the
        # walk starts a command (fdword).
        if (wantst && !unterm) starts_all()
        # The same holds for redirections: in a reading that never closes, a
        # stripped target changes how the rest reads, and the view stops
        # being idempotent (random inputs in scan-contract).
        if (((view == "noredir" || view == "live" || view == "flat" || wantst) && !unterm) || view == "pieces" || view == "cscripts" || view == "stmts" || view == "recognize" || view == "stmtcuts" || view == "cwords") redirs()
        # Which glued `}` closes a group reads the groups the walk opened, and
        # the redirections (DROP) the views blank.
        if (wantgrp) group_close()
        if ((view == "unprefixed" || view == "recognize" || view == "cwords" || view == "pieces") && !unterm) prefixes()
        # After redirs(), which says DIVERGE at a `!` only zsh reads as part
        # of its operator.
        if (div) {
          if (divfile != "") print "DIVERGE" >> divfile
          if (divmemo != "") print "DIVERGE" > divmemo
        }
        if (view == "substs") emit_substs()
        else if (view == "pieces") emit_pieces()
        else if (view == "cscripts") emit_cscripts()
        else if (view == "events") emit_events()
        else if (view == "stmtcuts") emit_stmtcuts()
        else if (view == "stmtraw") emit_stmtraw()
        else if (view == "cwords") emit_cwords()
        else emit()
      }

      # One escape in a top-level $\047...\047 at byte j, read the way the shell
      # reads it: the backslash goes, a one-letter escape and the first byte of
      # a numeric one carry the value in VAL, and the rest of a numeric one
      # goes. An unknown letter keeps its backslash. A value this cannot name
      # as one plain byte sets aqbad.
      function aq_escape(j,   e, k, v, h) {
        RM[j] = 1; e = X[j+1]
        if (e in AQV) { VAL[j+1] = AQV[e]; return }
        if (e ~ /[0-7]/) {
          v = 0
          for (k = j + 1; k <= j + 3 && k <= N && X[k] ~ /[0-7]/; k++) { v = v * 8 + X[k]; if (k > j + 1) RM[k] = 1 }
        } else if (e == "x") {
          v = 0
          for (k = j + 2; k <= j + 3 && k <= N && (h = index("0123456789abcdef", tolower(X[k]))) > 0; k++) { v = v * 16 + h - 1; RM[k] = 1 }
          if (k == j + 2) v = 0
        } else if (e == "u" || e == "U" || e == "c") { aqbad = 1; return }
        else { RM[j] = 0; return }
        if (v < 1 || v > 127) { aqbad = 1; return }
        VAL[j+1] = sprintf("%c", v)
      }

      # The top-level redirections: DROP marks the operator, the file
      # descriptor word in front of it (fdword), the blanks after it and its
      # target word (wordend). In the dash reading `&>` is no operator: the
      # `&` ends a command, and the `>` after it is read on its own. zsh reads
      # a `!` after `>`, `>>`, `>&` or `&>` as part of the operator (`>!`
      # clobbers); bash and dash read it as the start of the target word. The
      # two agree on the bytes unless a blank follows the `!`, where the word
      # after it is the target to zsh alone, so the bash reading says DIVERGE
      # there.
      #
      # KEEP marks what the live view keeps of a redirection: the body of a
      # process substitution in its target, which is code the shell runs.
      # PSB marks the bytes that open and close it, which the live view
      # blanks with the rest of the redirection though they are nested. A
      # substitution in a target needs no mark, since its body is not
      # top-level code.
      function redirs(   k, j, s, m, e, z) {
        for (k = 1; k <= N; k++) {
          if (C[k] != "c" || DEP[k] != 1) continue
          if (X[k] == "&" && X[k+1] == ">" && C[k+1] == "c") { if (shd) continue; j = k + 1 }
          else if (X[k] == "<" || X[k] == ">") j = k
          else continue
          if (X[j+1] == "(") { k = j + 1; continue }
          s = fdword(k)
          j++
          # A `<` or `>` whose `(` opens a process substitution starts the
          # target, not more operator: `><(x)`, `>>(x)` and `<<(x)` are an
          # operator and a process substitution to zsh (and `><(x)` to bash),
          # and read as one operator they left `(x)` where the command
          # stands (the redirection grid, forms RT-ps*-mid).
          while (j <= N && C[j] == "c" && X[j] ~ /[<>]/ && !((j + 1) in PSN)) j++
          if (j <= N && C[j] == "c" && X[j] == "&") j++
          if (j <= N && C[j] == "c" && X[j] == "|") j++
          else if (j <= N && C[j] == "c" && X[j] == "!" && X[j-1] != "<") {
            if (j + 1 > N || word_sep(j + 1)) div = 1
            if (shz) j++
          }
          while (j <= N && C[j] == "c" && DEP[j] == 1 && (X[j] == " " || X[j] == "\t")) j++
          z = wordend(j)
          for (m = j; m < z; m++) {
            if (!((X[m] == "<" || X[m] == ">") && C[m] == "c" && (m + 1) in PSN)) continue
            for (e = m + 2; e <= send[PSN[m+1]]; e++) KEEP[e] = 1
            PSB[m] = 1; PSB[m+1] = 1; PSB[e] = 1
            m = e
          }
          for (j = z; s < j; s++) DROP[s] = 1
          k = j - 1
        }
      }
      # The first byte of the file descriptor word glued in front of the
      # redirection operator at byte j, or j when there is none: a number, or
      # a name in braces, which bash 4.1 and later and zsh read as a variable
      # the shell opens a descriptor into (`{fd}>/dev/null pip install x`
      # runs the install in bash 5). Older bash and dash read `{fd}` as a
      # word, the command name where it comes first; reading it as part of
      # the redirection there can only show a command that does not run.
      #
      # The word starts where the byte before it ends a token (wordstart) or
      # where the walk starts a command (EV, the start events of this
      # reading): zsh reads a `{` glued to the first word as the group
      # opener, so in `{2>/dev/null pip install x; }` the `2` starts a word
      # though the `{` before it ends none. Read from the byte alone, the `2`
      # was the command and the install its argument (zsh runs it).
      function fdword(j,   s) {
        s = j
        if (s > 1 && X[s-1] ~ /[0-9]/) {
          while (s > 1 && X[s-1] ~ /[0-9]/ && C[s-1] == C[j]) s--
        } else if (s > 3 && X[s-1] == "}" && C[s-1] == C[j]) {
          s = j - 2
          while (s > 1 && X[s] ~ /[A-Za-z0-9_]/ && C[s] == C[j]) s--
          if (X[s] != "{" || C[s] != C[j] || X[s+1] !~ /[A-Za-z_]/) return j
        }
        if (s == j || !wordstart(s) && !(s in EV)) return j
        # zsh reads a `{` glued to the first word as the group opener, and
        # its walk starts the command after it (EV): the word `{fd}` is then
        # no descriptor, and `fd}` is the command (zsh does not run `{fd}>f
        # pip install x`, measured).
        if (X[s] == "{" && ((s + 1) in EV) && !(s in EV)) return j
        return fdat(s, j, policy) ? s : j
      }
      # Whether bytes s..j-1, a word, are the descriptor word of the
      # redirection operator at byte j in reading rs: a `{name}`, or a
      # number. zsh and dash read one digit there and bash any number
      # (measured: `echo 12>/dev/null` prints 12 into /dev/null in zsh and
      # dash, an empty line in bash; the zsh manual says "preceded by a
      # digit"). So in zsh `repeat 12>&1 pip install x` repeats the install
      # twelve times with its output on the descriptor 1, where a reading of
      # `12` as the descriptor left `repeat` no count and took the install
      # for one. The bash reading says DIVERGE where the readings differ.
      function fdat(s, j, rs) {
        if (X[s] == "{") return 1
        if (j - s == 1) return 1
        if (rs == policy && shb) div = 1
        return rs == "bash"
      }
      # Whether the word the walk reads at bytes s..j-1 has the shape of a
      # descriptor word glued to the operator at j: digits, or `{name}`,
      # all of the class of the operator. The walk asks this with the word start
      # it found itself.
      function fdshape(s, j,   k) {
        if (s >= j) return 0
        if (X[s] == "{") {
          if (j - s < 3 || X[j-1] != "}" || X[s+1] !~ /[A-Za-z_]/) return 0
          for (k = s; k < j; k++) if (C[k] != C[j] || k > s && k < j - 1 && X[k] !~ /[A-Za-z0-9_]/) return 0
          return 1
        }
        for (k = s; k < j; k++) if (X[k] !~ /[0-9]/ || C[k] != C[j]) return 0
        return 1
      }
      # The byte after the word that starts at byte j, cut where the shell
      # cuts it (word_sep).
      function wordend(j) {
        while (j <= N && !word_sep(j)) j++
        return j
      }
      # The statements, cut where command_statements cuts them: at a top-level
      # separator as the stmts view has it (`;`, a newline, `&`, `&&`, `|`,
      # `||`, `|&`) and at a start no separator stands before. Each is numbered
      # as command_statements numbers it, an empty one included, so line n of
      # the landing (resolve_reading_targets) and piece n are one statement.
      # The pieces used to be cut from the text lines another reader handed
      # this view -- the statements of the joined view, one per line -- and
      # every line was lexed again from nothing: a heredoc body there left the
      # live code in it (`$(date)`) where the next command stood, which took
      # that command for its argument (verdict buri-20261005-145152).
      function emit_pieces(   k, a, n, ch) {
        buf = ""; held = 0; n = 1; a = 1
        for (k = 1; k <= N; k++) {
          if ((k in EV) && bare(k)) { piece(a, k - 1, n); n++; a = k }
          ch = sbyte(k)
          if (ch == ";" || ch == "\n") { piece(a, k - 1, n); n++; a = k + 1; continue }
          if (ch == "&") {
            piece(a, k - 1, n); n++
            if (k < N && sbyte(k + 1) == "&") k++
            a = k + 1; continue
          }
          if (ch == "|") {
            piece(a, k - 1, n); n++
            if (k < N && (sbyte(k + 1) == "|" || sbyte(k + 1) == "&")) k++
            a = k + 1; continue
          }
        }
        piece(a, N, n)
        if (aqbad) put("!\n")
        printf "%s", buf
      }
      # A byte of a piece as one line can carry it: a newline inside the piece
      # (code nested in a substitution) ends a command there, and the field
      # separators and a tab read as a blank, as do a comment, a heredoc
      # operator or body, a line continuation and a case pattern close, which
      # are not words.
      function pbyte(k,   cc) {
        if (k in DROP || C[k] == "m" || C[k] == "h" || C[k] == "b" || C[k] == "l" || C[k] == "p") return " "
        cc = X[k]
        if (cc == "\n") return (C[k] == "c" || C[k] == "Q" || C[k] == "B") ? ";" : " "
        if (cc == "\037" || cc == "\036" || cc == "\t") return " "
        return cc
      }
      # The words field: the piece after quote removal by the shell, one word
      # per blank-separated token. A word whose every byte was a quote is the
      # empty word, which the shell passes, so it is \002 too. Dropped, it
      # moved each later word up one place: `uvx --python "" evil==1.0.0` runs
      # evil (uv 0.10.11 reads the empty value as no preference), and
      # --python took evil==1.0.0 as its value. With `pre` 0, the prefixes of
      # the statement (A) are left out: the words the extractor reads.
      #
      # A `}` that closes a zsh group (GC, group_close) ends the word before
      # it, as zsh ends it there, and is no word of the statement. Read as a
      # grouping character inside the word, it made `{ mvn ...
      # dependency:get}` a goal of `dependency:get` and a marker, which no
      # goal reading names, and the install zsh runs passed.
      function pwords(a, z, pre,   k, w) {
        w = 0
        for (k = a; k <= z; k++) {
          if (!pre && (k in A)) continue
          if ((k in DROP) || (k in GC) || !(k in VAL) && !RM[k] && word_sep(k)) {
            if (w == 1) put("\002")
            w = 0
            put(((k in DROP) || (k in GC)) ? " " : pbyte(k))
            continue
          }
          if (w == 0) w = 1
          if (k in VAL) {
            if (VAL[k] != "") { put(VAL[k] ~ /^[ \t\n(){}\036\037]$/ ? "\002" : VAL[k]); w = 2 }
          } else if (!RM[k]) { put(wbyte(k)); w = 2 }
        }
        if (w == 1) put("\002")
      }
      # The statement as the recognize view has it, on one line: what the
      # recognizers read of this statement alone.
      function precog(a, z,   k, cc) {
        for (k = a; k <= z; k++) {
          if ((k in EV) && bare(k)) put(";")
          if ((k in A) || C[k] == "l") continue
          cc = ((k in DROP) && !unterm) ? " " : sbyte(k)
          put((cc == "\n" || cc == "\t" || cc == "\037" || cc == "\036") ? " " : cc)
        }
      }
      function piece(a, z, n,   k, any) {
        any = 0
        for (k = a; k <= z; k++) if (!(k in DROP) && X[k] !~ /[ \t\n]/ && C[k] != "m" && C[k] != "h" && C[k] != "b" && C[k] != "B" && C[k] != "l") { any = 1; break }
        if (!any) return
        put(n "\037")
        for (k = a; k <= z; k++) put(pbyte(k))
        put("\037")
        pwords(a, z, 1)
        put("\037")
        pwords(a, z, 0)
        put("\037")
        precog(a, z)
        put("\n")
      }
      # A byte inside a word, for the words field: one the extractor would cut
      # the word at -- a blank, which splits its tokens, or a grouping
      # character, which it blanks (guard_extract_statement_text) -- is \002,
      # so a quoted value or an unquoted substitution stays one word. Split on
      # blanks, `--python $(which python3) ruff==0.1.0` gave the option half a
      # word and read `python3)` as the package, and the real pin went
      # unchecked (caught in review). An operator inside a word is data: the
      # statement is already cut, and `requests>=3` is a version range.
      function wbyte(k) {
        return (X[k] ~ /^[ \t\n(){}\036\037]$/) ? "\002" : X[k]
      }

      # A byte that ends a word at the top level: unquoted blank or operator
      # in code that is not nested, or anything the shell does not read as a
      # word (a comment, a heredoc operator or body). Whether a byte is
      # nested is the depth of the walk (DEP) and nothing else: every
      # parenthesis the shell reads as part of a word is a context there (an
      # array value, a glob group, a process substitution, the subscript of
      # an assignment in bash), and a case pattern close is class p only at
      # the top level. This function used to answer from the byte alone, and
      # each word it cut where the walk did not was a statement no
      # recognizer read: `a=(x) pip install x` ran with `x)` as the command,
      # and the `)` of a case pattern inside `>$(case a in a) echo f;; esac)`
      # ended the target there (forms WA1, WC3).
      #
      # A heredoc operator, body or terminator ends a word where the heredoc
      # stands at the top level. One opened inside a substitution is part of
      # that word, as the rest of the substitution is (WD, the depth the
      # outermost heredoc stands at): read as a word end, it cut the target
      # of `npm >$(cat <<E ... E) install x` at the `<<`, and the verb was
      # never beside npm for the rewrite (no --ignore-scripts, no record).
      function word_sep(k) {
        if (k in ARM) return 1
        # Every byte of a body at the top level is no word of the command,
        # an escape or a comment in a substitution there too: read as word
        # bytes, they gave the walk a command inside the body.
        if (C[k] == "h" || C[k] == "b" || C[k] == "B" || (k in BF)) return !(k in WD) || WD[k] <= 1
        if (C[k] == "p") return 1
        if (C[k] == "m") return DEP[k] == 1
        return C[k] == "c" && DEP[k] == 1 && X[k] ~ /[ \t\n;&|()<>]/
      }
      function mark(a, z,   k) { for (k = a; k <= z; k++) A[k] = 1 }
      # Mark the prefixes each top-level statement starts with, and the blanks
      # after each. A word is cut only by word_sep, so a quoted or nested value
      # (FOO="a b", FOO=$(cmd arg), FOO=a\ b) stays one word -- the sed this
      # replaced read a value as the bytes up to the first blank or quote.
      # A statement starts where starts() found a command (EV), and only
      # there: this reads the events and no separator of its own. A
      # redirection there is a prefix like an assignment: redirs() has marked
      # its operator, file descriptor and target in DROP. Left in place,
      # `2>/dev/null pip install ...` put a word between the start and the
      # install, and no recognizer read it (every shell runs it). Read from
      # separators, the starts after `function NAME {` kept their
      # assignments the same way. A word is cut at an event inside it too:
      # zsh reads `{X=1 pip install x; }` as a group whose command starts
      # after the `{`, where word_sep alone saw one word `{X=1`.
      function prefixes(   k, s, w, atstart, envmode, takes, hit, execmode, cmdmode, timemode, sl, j, bw) {
        atstart = 0; envmode = 0; takes = 0; execmode = 0; cmdmode = 0; timemode = 0; k = 1
        while (k <= N) {
          if (k in EV) { atstart = 1; envmode = 0; takes = 0; execmode = 0; cmdmode = 0; timemode = 0 }
          if (word_sep(k)) {
            # A redirection that ends in an operator byte (the `)` of a
            # process substitution target) takes the blanks after it along,
            # as one that ends in a word does below.
            if (k in DROP) {
              if (atstart) { A[k] = 1; if (!((k + 1) in DROP)) while (k + 1 <= N && C[k+1] == "c" && DEP[k+1] == 1 && (X[k+1] == " " || X[k+1] == "\t")) { k++; A[k] = 1 } }
              k++; continue
            }
            k++; continue
          }
          s = k; sb_reset("w", "")
          while (k <= N && !word_sep(k) && !(k > s && (k in EV))) { sb_add("w", X[k]); k++ }
          w = sb_get("w")
          if (!atstart) continue
          # A word that is a path, with its last part plain: bw is that part.
          # `/usr/bin/env` is env as `/usr/bin/pip` is pip.
          sl = 0; bw = w
          for (j = s; j < k; j++) if (X[j] == "/" && C[j] == "c" && DEP[j] == 1) sl = j
          if (sl > 0) {
            for (j = sl + 1; j < k && C[j] == "c" && DEP[j] == 1; j++) ;
            if (j == k && sl < k - 1) bw = substr(w, sl - s + 2); else sl = 0
          }
          hit = 0
          if (s in DROP) hit = 1
          else if (takes) { takes = 0; hit = 1 }
          # `--` ends the options of `command` and `exec`: the word after it
          # is read afresh, as the command or another prefix (`exec --
          # noglob pip install x` runs the install in zsh). Read as the
          # command, it hid the install after it in every shell that runs
          # `command --` or `exec --`.
          else if ((execmode || cmdmode) && w == "--") { execmode = 0; cmdmode = 0; hit = 1 }
          # env takes a value after -u, -C and -P (macOS and GNU env; -S is
          # read by the payload reader, see cscripts_of).
          else if (envmode && w ~ /^-/) { if (w ~ /^(-[0iv]*[uCP]|--unset|--chdir)$/) takes = 1; hit = 1 }
          # exec takes `-c`, `-l` and `-a NAME` (bash and zsh), clustered as
          # getopt reads them: the first `a` takes the rest of its word as
          # the name, or the next word when it ends the word. `-aa` is the
          # name `a`; read as `-a` before a name, it took the command.
          else if (execmode && w ~ /^-[a-z]+$/) { if (index(w, "a") == length(w)) takes = 1; hit = 1 }
          # `command -p` runs the command from the default path; getopt
          # takes the switch any number of times (`-pp`). `-v` and `-V` only
          # say what the word is, so the install after them does not run.
          else if (cmdmode && w ~ /^-p+$/) hit = 1
          # time takes `-p` as the reserved word (bash, zsh), and in dash it is
          # /usr/bin/time, whose options end at `--` and where -o and -f take
          # a value; the walk skips every `-` word after time, and so does this.
          else if (timemode && w == "--") { timemode = 0; hit = 1 }
          else if (timemode && w ~ /^-/) { if (w ~ /^-[a-z]*[of]$/) takes = 1; hit = 1 }
          else if (assignat(s, k, 1)) hit = 1
          # env, command and time are programs too (macOS ships /usr/bin/env,
          # /usr/bin/command and /usr/bin/time), and a macOS volume ignores
          # case, so `TIME pip install x` runs the install there. Their names
          # are read as the grammar reads the name of a manager
          # (safedeps_manager_name): the last part of a path, in any case. The
          # start pattern of the recognizers read `time` in any case until the
          # walk took the reserved words over, and a merge with that pattern
          # gone left `TIME` the command name.
          else if (tolower(bw) == "env") { envmode = 1; hit = 1 }
          else if (w == "exec") { envmode = 0; execmode = 1; cmdmode = 0; hit = 1 }
          else if (tolower(bw) == "command") { envmode = 0; cmdmode = 1; execmode = 0; hit = 1 }
          # The reserved word `time` goes like the other prefixes, so a reader
          # of this view finds the command after it (`| time sh`, the pipe
          # check).
          else if (tolower(bw) == "time") { envmode = 0; timemode = 1; hit = 1 }
          else if (shz && zprecmd(w)) { envmode = 0; hit = 1 }
          else if (opener(w) || shz && zopener(w) || w == "coproc") { envmode = 0; continue }
          else {
            # A word zsh reads as a precommand modifier, where the other
            # readings read the command: zsh goes on to the command after it
            # (`exec -- noglob pip install x` runs the install in zsh alone).
            # The walk reads no command after `exec` or `command`, so its
            # starts agree there; this is where the readings part, and the
            # bash reading says so. A second lexing of this view used to find
            # the modifier at a start and say it by accident.
            if (!shz && zprecmd(w)) div = 1
            # The command word. A path before an executable the grammar
            # names reads as that executable, wherever the path points:
            # `/usr/bin/pip`, `.venv/bin/pip` and `$VENV/bin/pip` run a pip
            # (exre, the list in the grammar). The sed this replaced read only an
            # absolute path, after a byte of its own start set and before a
            # byte of its own end set, so `x)/usr/bin/pip install x` (a case
            # arm) and `/usr/bin/pip>/dev/null install x` passed unjudged.
            if (sl > 0 && exre != "" && tolower(bw) ~ exre) mark(s, sl)
            atstart = 0; envmode = 0; continue
          }
          mark(s, k - 1)
          while (k <= N && C[k] == "c" && DEP[k] == 1 && (X[k] == " " || X[k] == "\t")) { A[k] = 1; k++ }
        }
      }

      # The reserved words after which a command stands, the one list of them:
      # prefixes() and starts() read it. SAFEDEPS_G_START used to carry a
      # second copy as a regex chain, and a chain names only the words before
      # a command, never the shell state that puts one there (the function
      # heads, `for ((...))`, the zsh short forms). zopener() holds the two
      # only zsh reads so: `}` closes a group wherever it stands, and
      # `always` opens the block after one.
      function opener(w) { return w ~ /^(!|[{]|if|then|else|elif|while|until|do)$/ }
      # The words that open a compound command other than a group or a
      # subshell: what may follow `function NAME` and `coproc NAME` as a body.
      function cbody(w) { return w ~ /^(if|while|until|for|select|case|[[][[])$/ }
      function zopener(w) { return w == "}" || w == "always" }
      # The precommand modifiers only zsh reads: a word before a command that
      # changes how it is run and is no command itself (`noglob pip install
      # x` runs the install). The manual lists six; `command` and `exec` are
      # read in every reading, with their options, in prefixes().
      function zprecmd(w) { return w == "-" || w == "builtin" || w == "nocorrect" || w == "noglob" }
      # Whether the word at bytes s..k-1 assigns: the byte after its `=`, or
      # 0. A name, a subscript whose close the lexing found (SUBC), `=` or
      # `+=`. An assignment stays with the command it prefixes. A regex over
      # the word read `a[b[1]]=x` and `a["]"]=x` as commands, and `a+=x` and
      # `a[1]=x` were not listed at all, so the install after each was an
      # argument (forms WA7, WA15-WA17).
      #
      # The walk asks with a word start of its own (walked = 1), which the
      # lexing may not have seen: zsh reads `{a[1]=x pip install x; }` as a
      # group whose command assigns before the install, but the lexing,
      # which asks whether a byte ends a token, found no word start at the
      # `a` and no subscript there. The subscript is then read here, the way
      # the lexing reads one.
      function assignat(s, k, walked,   p, wk) {
        p = s
        if (X[p] !~ /[A-Za-z_]/) return 0
        while (p < k && X[p] ~ /[A-Za-z0-9_]/) p++
        if (p < k && X[p] == "[" && walked && !(p in SUBC) && (wk = la_sub(p + 1)) && (X[wk] == "=" || X[wk] == "+" && X[wk+1] == "=")) SUBC[p] = wk - 1
        if (p < k && X[p] == "[") { if (!(p in SUBC) || SUBC[p] >= k) return 0; p = SUBC[p] + 1 }
        if (p < k && X[p] == "+") p++
        return (p < k && X[p] == "=") ? p + 1 : 0
      }
      # Where each command starts, in the reading rs. The walk follows the
      # shell grammar word by word and keeps st set while the next word
      # stands where the shell reads a command name. Assignments and
      # redirections before a command are part of it, so no start falls
      # between them and the command, and a redirection that comes first is
      # where it starts; the word after a redirection operator is its
      # target, never a command.
      #
      # Every reading: after a separator or a case pattern, a reserved word, a
      # function head (an empty `()`, `function NAME... {`, or `function NAME`
      # before any other compound command: bash 5 reads `function WORD
      # function_body`, so `function f if pip install x; then :; fi` defines a
      # function that runs it), `time` and its options, `coproc`, `for
      # NAME... {` and `for ((...)) {`. A rule may be shared only when it adds
      # starts: a shell that has no such form fails to parse the command, and
      # runs none of it (measured per shell in scan-contract). zsh alone: `}` wherever it stands, `always`, the short
      # forms `for NAME (WORDS)`, `foreach`, `repeat WORD`, `[[ ... ]]` and an
      # arithmetic `((...))` before a body, and `case WORD {`. bash alone:
      # `coproc NAME` before a compound command (`coproc WORD shell_command`:
      # `{`, `if`, `while` and the rest of cbody). These take starts away from
      # what the shared walk reads (the words in `for i (1)`) or only one shell
      # runs them, so the reading that is not that shell does not read them;
      # the bash reading walks all three and says DIVERGE where they differ
      # (see starts_all).
      #
      # The arithmetic word is read as such: its first `(` is a separator to
      # the word walk, so the word starts at the second one, with AR after it.
      #
      # The walk writes events, never bytes. CS gets the first byte of each
      # command, its prefixes included: the first word, or the redirection
      # operator or file descriptor before it. CW gets the word it reads as
      # the command, or as the reserved word that opens one. A start is a
      # place between two bytes, and the readers take it from here: the
      # recognize view puts a separator in, command_statements cuts there,
      # prefixes() starts there.
      function starts(rs, CS, CW, GO,   k, s, w, op, st, pre, rd, fn, fr, fra, inp, rp, dbr, cop, tm, cs, zr, br, fh, j, pn, PST, body, HC, cw, PCOND, pcw, acond, hd) {
        zr = (rs == "zsh"); br = (rs == "bash")
        st = 1; pre = 0; rd = 0; fn = 0; fr = 0; fra = 0; inp = 0; rp = 0; dbr = 0; cop = 0; tm = 0; cs = 0; fh = 0; k = 1; pn = 0
        while (k <= N) {
          if (word_sep(k)) {
            op = (C[k] == "c" && DEP[k] == 1) ? X[k] : ""
            # An `&` is part of a redirection after `>` or `<` (`2>&1`) and,
            # outside dash, before `>` (`&>`); in dash that one ends a command.
            if (op == "&" && (X[k+1] == ">" && rs != "dash" || k > 1 && (X[k-1] == ">" || X[k-1] == "<") && C[k-1] == "c")) op = ">"
            # zsh reads `&!` as one list terminator, as `&` that disowns the
            # job (zsh manual, Simple Commands & Pipelines), so a command
            # glued after it starts there: `true&!pip install x` runs the
            # install in zsh alone, where bash and dash read `!pip` as a
            # command name. With a blank after it every shell starts one (in
            # bash and dash at the `!` they read as reserved).
            if (zr && op == "&" && X[k+1] == "!" && C[k+1] == "c" && DEP[k+1] == 1) {
              st = 1; pre = 0; rd = 0; fn = 0; fr = 0; inp = 0; rp = 0; dbr = 0; cop = 0; tm = 0; fh = 0
              k += 2; continue
            }
            if (C[k] == "p" || op ~ /[\n;&|]/) {
              st = 1; pre = 0; rd = 0; fn = 0; fr = 0; inp = 0; rp = 0; dbr = 0; cop = 0; tm = 0; fh = 0
            }
            else if (op == "<" || op == ">") {
              fh = 0
              # A redirection that comes first is the start of its command.
              # (The `<` or `>` that opens a process substitution is no
              # operator: it is nested, with the word it starts.)
              rd = 1
              # Not while the walk reads a head: the names after `function`,
              # the list of a `for`, the count of `repeat`, the words of `[[`,
              # the word of a `case`. No shell starts a command there, and a
              # start with no command word after it broke the event contract
              # (random input on bash 5: `function f g>x y`).
              hd = (fn || fr || rp || dbr || cs || inp)
              if (st && !pre && !hd) CS[k] = 1
              if (st && !hd) pre = 1
              if (op == ">" && X[k+1] == "|") k++
            }
            else if (op == "(") {
              for (j = k + 1; j <= N && (X[j] == " " || X[j] == "\t"); j++) ;
              if (!(st && !pre) && !fh && fn != 2 && cop != 2 && !(zr && fr == 2) && X[j] != ")" && !(X[k+1] == "(" && (k + 2) in AR) && !(k in CPO) && !(k in GLO)) BSF[rs]++
              # A subshell that is a function body (`f() ( ... )`, `function
              # f ( ... )`, and in bash `coproc NAME ( ... )`) starts a
              # command after a word, so the start is marked before it, as
              # before a `{`. Unmarked, the statement began at the function
              # name, and the extractor read the install in the body as
              # arguments of `f` (caught when the release met the lexer).
              # The `(` of an empty `()` is the head itself, not a body. A
              # body glued to the head (`f()(pip install x)`) has no blank to
              # mark, so the `(` itself is the start, as a case close glued
              # to its arm is.
              #
              # The same holds for any subshell where a command stands with
              # words of its statement before it: `function f { (pip install
              # x); }`, `for i do (pip install x); done`, and glued to a
              # reserved word, `if(true)then(pip install x)fi`. The start is
              # the `(`, so the statement no longer begins at `function` or
              # `for`, where the extractor read no manager in it (every shell
              # that has the form runs it, and each passed). Where the walk
              # is still reading a head -- the names after `for`, `function`
              # or `repeat`, the words of `[[ ... ]]` -- no command stands yet
              # (zsh `for NAME (WORDS)` opens its list there), and in a case
              # pattern the `(` belongs to the pattern.
              #
              # PST remembers, for each open `(`, whether it opened such a
              # subshell, so that its `)` can say a command ended there.
              #
              # After the header of an arithmetic `for ((...))` the `(` is
              # the body (zsh runs `for ((...)) (pip install x)`), and so it
              # is after the word list of zsh `for NAME (WORDS)`: HC marks
              # the `)` that closed such a head. A subshell glued to a case
              # pattern close (`*)(pip install x);;`) starts at its `(` too.
              body = ((fh || fn == 2 || br && cop == 2 || fr == 2 && fra || st && !pre && !fn && !fr && !rp && !dbr && !(k in CPO)) && !(X[k+1] == "(" && (k + 2) in AR) && !emptyahead(k))
              if (body) CS[k] = 1
              if (!(X[k+1] == "(" && (k + 2) in AR)) { PST[++pn] = body; PCOND[pn] = cw; cw = 0 }
              if (X[k+1] == "(" && (k + 2) in AR) { }
              else if (zr && fr == 2 && !fra) { inp = 1; fr = 0 }
              # The `(` that opens a case pattern opens no command: the word
              # after it is the pattern (`case x in (x) ...`).
              else if (k in CPO) { }
              else { st = 1; pre = 0; rd = 0; fn = 0; fr = 0; rp = 0; cop = 0; tm = 0 }
              fh = 0
            }
            else if (op == ")") {
              # The `))` of an arithmetic command or header ends its word and
              # nothing else: the `((` opened no subshell.
              # In zsh the condition of `if`, `elif`, `while` and `until` may
              # be an arithmetic command or a subshell with the body right
              # after it (the short forms), so its close is a head close too.
              # Only there: an arithmetic command elsewhere closes no head
              # (`((echo "a))b") )`, where zsh closes it early, runs nothing).
              if (k in ACL) { if (fr == 2 && fra || zr && acond) HC[k] = 1; acond = 0 }
              else if (inp) { inp = 0; st = 1; HC[k] = 1 }
              else if (emptyparen(k)) { st = 1; fn = 0; fh = 1 }
              else if (cs == 3) st = 1
              # The close of a subshell ends a command, so a reserved word
              # may follow it at once (`if (true) then ...`, which every
              # shell measured runs). A `(` that opened none -- a glob
              # word, a stray one among the arguments -- closes nothing.
              else if (pn > 0 && PST[pn]) { st = 1; pre = 0; if (zr && PCOND[pn]) HC[k] = 1 }
              if (pn > 0 && !(k in ACL)) pn--
            }
            k++; continue
          }
          s = k; sb_reset("w", "")
          while (k <= N && !word_sep(k)) { sb_add("w", X[k]); k++ }
          w = sb_get("w")
          fh = 0
          if (inp) continue
          if (rd) { rd = 0; continue }
          if (dbr) { if (w == "]]") { dbr = 0; st = zr }; continue }
          # fn counts the words after `function`: 2 right after the name,
          # where bash reads a body; 3 after more names, where only `{` opens
          # one (zsh).
          if (fn) {
            if (w == "{") { GO[s] = 1; fn = 0; st = 1; continue }
            if (fn != 2 || !cbody(w)) { fn = (fn == 1) ? 2 : 3; continue }
            fn = 0; st = 1
          }
          # fra is set when the head is arithmetic, `for ((...))`: then the
          # word after it is the body, a `do`, a `{` or, in zsh, a command
          # (the short form `for ((...)) sublist`; bash fails to parse it, so
          # the start is shared).
          if (fr == 1) { fr = 2; fra = (substr(w, 1, 1) == "(" && (s + 1) in AR); continue }
          if (fr == 2) {
            if (w == "in") { fr = 0; st = 0 }
            else if (w == "do" || w == "{") { if (w == "{") GO[s] = 1; fr = 0; st = 1 }
            else if (fra) { fr = 0; st = 1; fra = 0 }
            if (fr == 2 || w == "in" || w == "do" || w == "{") continue
          }
          if (rp) { rp = 0; st = 1; continue }
          if (cs == 1) { cs = 2; continue }
          if (cs == 2) { cs = (zr && w == "{") ? 3 : 0; continue }
          if (!st && br && cop == 2 && cbody(w)) { st = 1; cop = 0 }
          if (!st) {
            if (br && cop == 2 && w == "{") { GO[s] = 1; st = 1 }
            else if (zr && w == "}") st = 1
            cop = 0
            continue
          }
          # The options of time: `-p`, and in dash those of /usr/bin/time,
          # where -o and -f take the next word (prefixes() reads the same).
          if (tm == 2) { tm = 1; continue }
          if (tm && w ~ /^-/) { if (w ~ /^-[a-z]*[of]$/) tm = 2; continue }
          tm = 0
          # zsh reads a `{` glued to the first word of a command as the
          # group opener (`{pip install x; }` runs the install in zsh alone).
          # The rest of the word is read again, as the first word of the
          # command in the group: its start is the byte after the `{`.
          if (zr && !pre && length(w) > 1 && substr(w, 1, 1) == "{" && C[s] == "c" && DEP[s] == 1) { GO[s] = 1; k = s + 1; continue }
          # A file descriptor word glued to a redirection belongs to it. The
          # word starts where the walk says (s), which is not always where a
          # byte ends a token: after a `{` zsh reads as glued (`{2>/dev/null pip`).
          if ((X[k] == "<" || X[k] == ">") && C[k] == "c" && fdshape(s, k) && fdat(s, k, rs)) {
            if (!pre) CS[s] = 1
            pre = 1
            continue
          }
          # A command glued to the `)` that closes a head (zsh `for i
          # (1)pip install x`, `for ((...))pip install x`, `if ((1))pip ...`)
          # starts there like any other: the start is the place between the
          # `)` and the word.
          if (!pre) CS[s] = 1
          pre = 0
          if (!assignat(s, k, 1)) CW[s] = 1
          # The word after `coproc` is a command to zsh and to bash, unless
          # bash reads it as the NAME of a `coproc NAME {`. It is a start,
          # and read on as at any other.
          if (cop == 1) cop = (w == "{") ? 0 : 2
          pcw = cw; cw = 0
          if (opener(w) || zr && zopener(w)) { if (w == "{") GO[s] = 1; cop = 0; cw = (w ~ /^(if|elif|while|until)$/); continue }
          if (assignat(s, k, 1)) { pre = 1; continue }
          if (w == "time") { tm = 1; continue }
          if (zr && zprecmd(w)) continue
          if (w == "function") { fn = 1; continue }
          if (w == "for" || w == "select" || zr && w == "foreach") { fr = 1; continue }
          if (zr && w == "repeat") { rp = 1; continue }
          if (w == "[[") { dbr = 1; continue }
          if (w == "coproc") { cop = 1; continue }
          if (w == "case") { cs = 1; st = 0; continue }
          if (zr && substr(w, 1, 1) == "(" && (s + 1) in AR) { acond = pcw; continue }
          for (j = s; j < k; j++) if (j in WPO) { BSF[rs]++; break }
          st = 0
        }
      }
      # The starts of this reading in EV, its command words in EW. The bash
      # reading also walks as zsh and as dash, and says DIVERGE where a start
      # differs, so that a form only zsh runs brings the zsh reading in. On
      # the same classes the walks differ only by the rules above; where the
      # classes themselves differ, the lexing has said DIVERGE already. The
      # starts compared are the events: one with no byte before it to carry
      # it is a start all the same, and one that only zsh reads (`true&!pip
      # install x`) has to bring the zsh reading in.
      function starts_all(   j) {
        starts(policy, EV, EW, GOR)
        if (!shb) return
        starts("zsh", EZ, EZW, GOZ); starts("dash", ED, EDW, GOD)
        walks_fail()
        if (div) return
        for (j in EZ) if (!(j in EV)) { div = 1; return }
        for (j in ED) if (!(j in EV)) { div = 1; return }
        for (j in EV) if (!(j in EZ) || !(j in ED)) { div = 1; return }
      }
      # Whether the start at byte k is bare: no separator the shell reads
      # stands before it (blanks between), so a reader that knows only
      # separators would not find it. A start after `;`, `&`, `|`, `(` or a
      # newline, or at the beginning, is delivered by that byte already.
      function bare(k,   j) {
        j = k - 1
        while (j >= 1 && (X[j] == " " || X[j] == "\t") && C[j] == "c") j--
        if (j < 1 || (j in ARM)) return 0
        return !(C[j] == "c" && DEP[j] == 1 && !(j in DROP) && X[j] ~ /[\n;&|(]/)
      }
      # The walk checks its own answers. The lexing decides which `(` is part
      # of a word, and partly by the bytes before it (cmdpos, namehead,
      # wordstart); the walk decides where a command may start from the
      # grammar. Where the two disagree, one of them misread the command, and
      # which one cannot be told from here. BSF counts, per walk, the two
      # ways they can: a `(` the lexing left an operator where the walk has
      # no command position, no function head and no short-form list, and a
      # word parenthesis inside the word the walk reads as a command name.
      # (An arithmetic `((`, a case pattern `(` and a zsh glob word the
      # lexing marked are operators the walk expects, CPO and GLO.) Only the
      # bash reading asks, and only when its three walks all count one: a
      # `(` that zsh alone reads where a command stands (`foreach i (1)`) is
      # a form of that shell, not a misreading. Then the reading is failed --
      # the mark the guard settles as UNDECIDED for a command that names a
      # package manager -- never guessed. This closes nothing by itself: each
      # form found this way got its own rule (the `!` in cmdpos), and the
      # check stays for the next one.
      function walks_fail() { if (BSF["bash"] && BSF["zsh"] && BSF["dash"]) smfail() }
      function smfail() { if (smark != "" && !smdone) { print "failed" >> smark; smdone = 1 } }
      # Which word the `(` at byte j is part of: "a" an array value, "z" a
      # zsh `=(...)`, "g" a glob group or qualifier, "" none -- an operator
      # (see the `(` rule in the main loop). A `(` is part of a word only
      # glued to one: after a byte that ends no token. A line continuation is
      # no byte. An escaped byte, a closing quote and the close of a
      # substitution are bytes of a word whatever they are, so the `(` after
      # one is a glob (zsh; no other shell parses it): read by the byte
      # alone, `\)(` was an operator after a separator, and the view read
      # again, where the escape is `_`, was a word (random input in
      # scan-contract). An empty `()` is a function head, never a glob, with
      # blanks inside it too: bash, sh and dash run `f( ) { pip install x; }`.
      function wparen(j,   k, p, pc, s) {
        k = j
        while (k > 2 && C[k-1] == "l") k -= 2
        if (k < 2) return ""
        p = X[k-1]; pc = C[k-1]
        if (p == "=" && pc == C[j] && !((k - 1) in WC)) {
          if (wordstart(k - 1)) return "z"
          for (s = k - 1; s > 1 && C[s-1] == C[j] && X[s-1] !~ /[ \t\n;&|()<>]/; s--) ;
          if (assignat(s, k) == k) return "a"
        }
        # An empty `()` is a function head, never a glob; an array value may
        # be empty (`a=()`), which is decided above.
        if (emptyahead(j)) return ""
        if (pc == "e" || pc == "q" || (k - 1) in WC) return shd ? "" : "g"
        # The `&` of a duplication (`<&(`, `>&(`) is an operator byte the stmts
        # view prints as `_`, a word byte when the view is read again. No
        # shell parses a `(` there, so it is read the way the second reading
        # will read it.
        if (pc == C[j] && p == "&" && k > 2 && X[k-2] ~ /[<>]/ && C[k-2] == C[j]) return shd ? "" : "g"
        if (pc != C[j] || p ~ /[ \t\n;&|()<>]/) return ""
        if (!shd && p != "$" && !cmdpos(j)) return "g"
        return ""
      }
      # Whether the `(` at byte j is the `(` of an empty `()`, with or without
      # blanks inside.
      function emptyahead(j) {
        j++
        while (j <= N && (X[j] == " " || X[j] == "\t")) j++
        return X[j] == ")"
      }
      # The `>` that closes a zsh numeric range glob opened by the `<` at byte
      # j, the way zsh looks ahead for one: digits, `-`, digits, `>`. 0 when
      # the bytes are not one.
      function numglob(j,   k) {
        k = j + 1
        while (k <= N && X[k] ~ /[0-9]/) k++
        if (X[k] != "-") return 0
        k++
        while (k <= N && X[k] ~ /[0-9]/) k++
        return (k <= N && X[k] == ">") ? k : 0
      }
      # Whether the `[` at byte j follows a name that starts a word: `NAME[`.
      function subname(j,   k) {
        k = j - 1
        while (k >= 1 && X[k] ~ /[A-Za-z0-9_]/ && C[k] == C[j]) k--
        return k < j - 1 && X[k+1] ~ /[A-Za-z_]/ && wordstart(k + 1)
      }
      # The byte after the `]` that closes the subscript opened just before
      # k, the way bash pairs them: nested brackets count, and an escape, a
      # quote, `$(...)`, `${...}` and backticks are stepped over whole. 0
      # when there is none.
      function la_sub(k,   depth, cc) {
        depth = 0
        while (k <= N) {
          cc = X[k]
          if (cc == "\\") { k += 2; continue }
          if (cc == "\047") { k = la_sq(k + 1); continue }
          if (cc == "\042") { k = la_dq(k + 1); continue }
          if (cc == "`") { k = la_bq(k + 1); continue }
          if (cc == "$" && (X[k+1] == "(" || X[k+1] == "{")) { k = la_close(k + 2, X[k+1] == "(" ? ")" : "}"); continue }
          if (cc == "[") depth++
          else if (cc == "]") { if (depth > 0) depth--; else return k + 1 }
          k++
        }
        return 0
      }
      # The `)` at k closes an empty `()`: a function head.
      function emptyparen(k,   j) {
        j = k - 1
        while (j >= 1 && (X[j] == " " || X[j] == "\t") && C[j] == "c") j--
        return j >= 1 && X[j] == "(" && C[j] == "c" && DEP[j] == 1
      }

      function push(k) {
        d++; ctx[d] = k; par[d] = 0; pnp[d] = np; besc[d] = 0; cpat[d] = 0; cpw[d] = 0; adol[d] = 0; glc[d] = 0; cst[d] = i
        if (k == "D") dq++
        if (k == "H") { hn++; if (hn == 1) hb1 = dc }
        if (k != "C") dc++
        if (k == "S" || k == "B") { nsub++; sbeg[nsub] = i + 1; send[nsub] = N; skind[nsub] = k; sid[d] = nsub }
      }
      # A substitution that closes on the line it opened drops the heredocs
      # opened inside it: `x=$(cat <<EOF)` has no body, and every shell runs the
      # next line as a command (form P7).
      function pop() {
        if (d > 1) {
          if (ctx[d] == "S" || ctx[d] == "B") send[sid[d]] = besc[d] ? i - 2 : i - 1
          if ((ctx[d] == "S" || ctx[d] == "B") && np > pnp[d]) np = pnp[d]
          if (ctx[d] == "D") dq--
          if (ctx[d] == "H") hn--
          if (ctx[d] != "C") dc--
          d--
        }
      }
      # A `{` group, and the `}` glued to a word that closes one in zsh.
      #
      # zsh closes an open `{` group at a `}` that ends a word, when a blank,
      # an operator, a closing backtick or the end of the text follows it, and
      # hands the word before it on: `{ p ci}` hands `ci`, `{ p ci}&& q` runs
      # both, and `{ p ci}}` hands `ci}` (zsh 5.9, measured). With no group
      # open zsh refuses that `}`. bash and dash never close a group there:
      # they hand `ci}`, which npm refuses as a command, and a group holding
      # one is closed only by a later `}` that stands as a word. So
      #
      #   - a glued `}` with no zsh group open, or with a word byte after it,
      #     is a character to every shell that runs it (NC): the views the
      #     recognizers and the rewrite read print it as `%` (cbyte), so no
      #     reader takes `p ci}` for `p ci`. Read as an end there, it made
      #     `npm ci}`, which installs nothing, into `npm ci` through the
      #     `--ignore-scripts` rewrite (caught in review). It is `%`, a byte
      #     with no role in the lexer that ends no word: `_` is a byte of a
      #     name, so `}=(` read again was the array assignment `_=(`, and the
      #     view read twice was not the view (random input in scan-contract);
      #   - one zsh closes a group with (GC) stays `}` in those views, where
      #     the install grammar reads it as an end (SAFEDEPS_G_END). The zsh
      #     reading marks it at once. bash and dash mark it too when the text
      #     ends with a group bash has not closed, since bash then refuses
      #     that text and runs none of it, so reading it as zsh does changes
      #     nothing bash runs; otherwise bash runs the word with its `}`,
      #     marks it NC, and says DIVERGE.
      #
      # Which `{` opens a group is the answer of the walk, never a second reading
      # of the bytes: starts() marks GO wherever it reads a `{` as a group
      # opener, in each shell (after `function NAME`, an empty `()`, `repeat
      # WORD`, the list of `for NAME (WORDS)`, a reserved word, a separator).
      # A reading of its own here, by the bytes before the `{`, knew the
      # separators and the reserved words and none of the heads, so `function
      # f { npm ci}; f` closed no group in it, the `}` was a character, and
      # the install zsh runs passed with nothing recorded, where `function f {
      # npm ci; }; f` was read.
      #
      # Only at the top level, where the walk reads the words. A `}` nested in
      # a substitution, in quotes or in a heredoc body is decided where that
      # body is read as a payload, at its own top level; here a glued one is
      # NC. So the rewrite places no flag before the glued `}` of a group in
      # backticks or in `$(...)`: the body, read as a payload, is an install
      # to the recognizers, and the rewrite reads the verb against the `%` it
      # sees there (inert_nested_verb_ends) and records the install as a
      # downgrade, alone or beside an install it rewrites. Beside one, the
      # command used to read as rewritten, with nothing recorded.
      #
      # zg counts the groups zsh has open and bg those this reading may have
      # open. A `}` that stands as a word closes one in zsh wherever it
      # stands, and is counted as closing one for bash too, though bash closes
      # only at a command position: counted that way, bg can only be too low,
      # and too low makes bash run the word, which is the reading that can
      # only withhold a rewrite (the readings then differ, UNDECIDED).
      #
      # The bash reading also counts the groups the dash walk opens (bd), and
      # says DIVERGE where dash would settle a glued `}` otherwise: a reading
      # that says nothing at a place must print the views the other readings
      # print there, and the walks do not open the same groups everywhere
      # (each reading keeps rules of its own, see starts()).
      function group_close(   k, zg, bg, bd, end, pn, q, P) {
        if (!unterm) {
          if (!wantst) starts(policy, GXV, GXW, GOR)
          if (!shz && !(wantst && shb)) starts("zsh", GZV, GZW, GOZ)
          if (shb && !wantst) starts("dash", GDV, GDW, GOD)
        }
        zg = 0; bg = 0; bd = 0; pn = 0
        for (k = 1; k <= N; k++) {
          if (shz ? (k in GOR) : (k in GOZ)) zg++
          if (k in GOR) bg++
          if (k in GOD) bd++
          if (!(k in RB)) continue
          # Nested, a `}` is decided where its body is read (above), and is a
          # character here whether it stands as a word or not: the views print
          # a nested `;` `&` `|` as `_`, so one read as standing after such a
          # byte was glued when the view was read again, and the view was not
          # idempotent (random input in scan-contract). For the same reason a
          # `}` after an operator byte of a redirection, which the stmts view
          # blanks, is read as glued.
          if (!RBT[k]) { NC[k] = 1; continue }
          end = (k == N || X[k+1] ~ /[ \t\n;&|)<>`]/)
          if (wordstart(k) && !((k - 1) in DROP && X[k-1] ~ /[;&|]/)) {
            if (end && zg > 0) zg--
            if (end && bg > 0) bg--
            if (end && bd > 0) bd--
            continue
          }
          # Glued to the word before it and closing no group, a `}` is a
          # character of the word, at its end or inside it (`{ p a}b }` hands
          # `a}b`, `p ci}\047x\047` hands `ci}x`): NC, whatever follows it.
          # Kept as `}` inside a word, it read as a word end once the quote
          # after it was blanked, and the scan view read again was not the
          # scan view.
          if (!end || zg == 0) { NC[k] = 1; continue }
          zg--
          if (shz) GC[k] = 1
          else P[++pn] = k
        }
        for (q = 1; q <= pn; q++) {
          if (bg > 0) GC[P[q]] = 1
          else { NC[P[q]] = 1; if (shb) div = 1 }
        }
        if (shb && pn > 0 && (bg > 0) != (bd > 0)) div = 1
      }
      # Whether a word starts at byte j: the byte before it ends a token. That
      # is a question about the token, not the character: a blank or a newline
      # ends one only unescaped, and a `)` only as an operator, never where it
      # closes a `$(...)`, a `$((...))`, a process substitution or a glob
      # word, which are parts of a word. Read by the byte alone, `echo $(echo
      # a)#b` opened a comment that every shell reads as the word a#b, and a
      # comment that swallowed the close of a substitution hid the lines after
      # it (forms G1-G4). A line continuation is no byte at all: the shell
      # removes it before it splits tokens, so the byte before it decides
      # (`a \` then `#x` on the next line is a comment, `a\` then `#x` is the
      # word a#x; forms LC1-LC3, G4). Read as a byte, the continuation turned
      # that comment into a word whose quote hid the lines after it.
      function wordstart(j) {
        while (j > 2 && C[j-1] == "l") j -= 2
        if (j == 1) return 1
        if (X[j-1] !~ /[ \t\n;&|()<>]/) return 0
        return C[j-1] != "e" && C[j-1] != "l" && !((j - 1) in ESC) && !((j - 1) in WC)
      }
      # Whether byte j stands where a command starts, by the words before it.
      # A line continuation is skipped like a blank: the shell removes it.
      # A reserved word is one only as a word of its own: read by the byte,
      # the `!` of `f!(x)` put a command after it, and the extglob target
      # `>f!(x)` between `pip` and `install` was an operator `(` that took
      # the verb away (form WE2); the `do` of `>f-do(.)` did the same. And
      # `!` and `{` are reserved only where a command may start themselves:
      # the `!` of the extglob argument in `rm !(keep)` is a byte of that
      # word. bash 5 runs a subshell glued to `coproc`.
      function cmdpos(j,   k, w) {
        k = j - 1
        while (k >= 1 && (X[k] == " " || X[k] == "\t" || C[k] == "l")) k--
        if (k < 1 || X[k] ~ /[\n;&|()`]/) return 1
        if (X[k] == "!") return wordstart(k) && cmdpos(k)
        if (X[k] == "{") return wordstart(k) && (cmdpos(k) || namehead(k))
        w = ""
        while (k >= 1 && X[k] ~ /[a-z]/) { w = X[k] w; k-- }
        return w ~ /^(if|then|else|elif|while|until|do|time|coproc)$/ && wordstart(k + 1)
      }
      # The depth a heredoc stands at: the depth of the line its operator is on, or
      # inside a body, the depth the outermost heredoc stands at -- every byte
      # of a body at the top level is no word of the command.
      function hdepth() { return hn > 0 ? hb1 : dc }
      # Whether the `(` at byte j opens the word list of zsh `for NAME... (`
      # or `foreach NAME... (`: an operator of that head, never a glob word.
      # Read as a glob, its `)` made a subshell glued after it a glob
      # qualifier, and `for i (1)(pip install x)`, which zsh runs, had no
      # command in it.
      function forlist(j,   k, w, n) {
        k = j - 1; n = 0
        while (1) {
          while (k >= 1 && (X[k] == " " || X[k] == "\t") && C[k] == C[j]) k--
          w = ""
          while (k >= 1 && X[k] ~ /[A-Za-z0-9_]/ && C[k] == C[j]) { w = X[k] w; k-- }
          if (w == "") return 0
          if ((w == "for" || w == "foreach") && n > 0) return wordstart(k + 1) && cmdpos(k + 1)
          n++
          if (k >= 1 && X[k] !~ /[ \t]/) return 0
        }
      }
      # Whether byte j follows the NAME of `function NAME` or `coproc NAME`,
      # where bash 5 reads a compound command (see cbody). Asked where a
      # `case` opens, so that `function f case x in x) ...` has its arms: the
      # walk reads the body, and the pattern close is a start like any other.
      function namehead(j,   k, w) {
        k = j - 1
        while (k >= 1 && (X[k] == " " || X[k] == "\t" || C[k] == "l")) k--
        if (k < 1 || X[k] ~ /[ \t\n;&|()<>]/) return 0
        while (k >= 1 && X[k] !~ /[ \t\n;&|()<>]/) k--
        while (k >= 1 && (X[k] == " " || X[k] == "\t" || C[k] == "l")) k--
        w = ""
        while (k >= 1 && X[k] ~ /[a-z]/) { w = X[k] w; k-- }
        return (w == "function" || w == "coproc") && (k < 1 || X[k] ~ /[ \t\n;&|(!{)`]/)
      }
      # `((` (dollar=0) or `$((` (dollar=1) at byte j, decided the way this
      # reading decides it (see the table above). The bash reading also asks
      # how the others decide, and says DIVERGE where they differ.
      function arith_or_sub(j, dollar,   k, a, ab, az) {
        k = j + dollar + 2
        if (shd) a = dollar
        else if (shz) a = (la(k, 1) != 0)
        else {
          ab = (la(k, 0) != 0); az = (la(k, 1) != 0)
          if (ab != az || az != dollar) div = 1
          a = ab
        }
        if (a) { i = j + dollar + 1; push("A"); adol[d] = dollar; return }
        if (dollar) { i = j + 1; push("S") }
        else { i = j + 1; delete GL[d, par[d] + 1]; delete GL[d, par[d] + 2]; par[d] += 2 }
      }
      # The look-ahead bash and zsh make at `((`: from byte k to the first `)`
      # not nested in a parenthesis. 1 when another `)` follows it
      # (arithmetic), 0 when not (a subshell), -1 when there is none. With lit
      # set, a bare quote is a character (zsh); bash honors it. Both step over
      # an escape, `$(...)`, `${...}` and backticks whole, each read with its
      # own quoting (forms LA1-LA5).
      function la(k, lit,   depth, cc) {
        depth = 0
        while (k <= N) {
          cc = X[k]
          if (cc == "\\") { k += 2; continue }
          if (cc == "$" && (X[k+1] == "(" || X[k+1] == "{")) { k = la_close(k + 2, X[k+1] == "(" ? ")" : "}"); continue }
          if (cc == "`") { k = la_bq(k + 1); continue }
          if (!lit && cc == "\047") { k = la_sq(k + 1); continue }
          if (!lit && cc == "\042") { k = la_dq(k + 1); continue }
          if (cc == "(") depth++
          else if (cc == ")") { if (depth > 0) depth--; else return (X[k+1] == ")") ? 1 : 0 }
          k++
        }
        return -1
      }
      # The byte after the closer of a unit opened just before k, quotes honored.
      function la_close(k, closer,   depth, cc) {
        depth = 0
        while (k <= N) {
          cc = X[k]
          if (cc == "\\") { k += 2; continue }
          if (cc == "\047") { k = la_sq(k + 1); continue }
          if (cc == "\042") { k = la_dq(k + 1); continue }
          if (cc == "`") { k = la_bq(k + 1); continue }
          if (cc == "$" && (X[k+1] == "(" || X[k+1] == "{")) { k = la_close(k + 2, X[k+1] == "(" ? ")" : "}"); continue }
          if (closer == ")" && cc == "(") depth++
          else if (cc == closer) { if (depth > 0) depth--; else return k + 1 }
          k++
        }
        return N + 1
      }
      function la_sq(k) { while (k <= N && X[k] != "\047") k++; return k + 1 }
      function la_dq(k,   cc) {
        while (k <= N) {
          cc = X[k]
          if (cc == "\\") { k += 2; continue }
          if (cc == "\042") return k + 1
          if (cc == "`") { k = la_bq(k + 1); continue }
          if (cc == "$" && (X[k+1] == "(" || X[k+1] == "{")) { k = la_close(k + 2, X[k+1] == "(" ? ")" : "}"); continue }
          k++
        }
        return N + 1
      }
      function la_bq(k) {
        while (k <= N) { if (X[k] == "\\") { k += 2; continue } if (X[k] == "`") return k + 1; k++ }
        return N + 1
      }
      # `<<`, an optional `-`, blanks, then the delimiter word with its quoting
      # removed. A quoted delimiter makes the body literal. A file descriptor
      # word glued in front (`0<<E`, `{fd}<<E`) is part of the operator, so
      # every view that blanks the operator blanks it too: left as code, it
      # stood where the command name stands, and the install after it was
      # an argument to no recognizer.
      function heredoc_op(j,   k, strip, w, q, cc, sk) {
        k = j + 2; strip = 0
        if (X[k] == "-") { strip = 1; k++ }
        while (X[k] == " " || X[k] == "\t") k++
        sb_reset("w", ""); q = 0
        while (k <= N) {
          cc = X[k]
          if (cc ~ /[ \t\n;&|()<>]/) break
          if (cc == "\\") { q = 1; sb_add("w", X[k+1]); k += 2; continue }
          if (cc == "\047") { q = 1; k++; while (k <= N && X[k] != "\047") { sb_add("w", X[k]); k++ } k++; continue }
          if (cc == "\042") { q = 1; k++; while (k <= N && X[k] != "\042") { if (X[k] == "\\") k++; sb_add("w", X[k]); k++ } k++; continue }
          sb_add("w", cc); k++
        }
        w = sb_get("w")
        if (w == "") { C[j] = cls; return j }
        np++; pd[np] = w; ps[np] = strip; pq[np] = q; pstart[np] = j; pdq[np] = (dq > 0); pb[np] = (ctx[d] == "B")
        pS[np] = 0
        for (sk = d; sk > 1; sk--) if (ctx[sk] == "S") { pS[np] = 1; break }
        for (mm = fdword(j); mm < k && mm <= N; mm++) { C[mm] = "h"; WD[mm] = hdepth() }
        return k - 1
      }
      # A newline that ends a line of code. Pending heredoc bodies start after it.
      # This finds where each body and its terminator line are, the way the
      # shell does -- line by line, before anything in a body is expanded -- and
      # leaves the bodies to the main loop: a quoted body is data and is stepped
      # over; an unquoted one is walked as context H. There is no second reader
      # of the body (a line-at-a-time scanner here missed multi-line
      # substitutions and case patterns inside them; caught in review).
      function at_newline(j,   p, s, e, line, t, done, fed, kk, bs) {
        C[j] = (dq > 0) ? "Q" : (hn > 0 ? "B" : "c")
        if (np == 0) return j
        s = j + 1
        for (p = 1; p <= np; p++) {
          # Does the command of this heredoc pipe into something? Any `|` after the
          # operator on its line that is code and not `||`, or a line that ends
          # in one. Conservative on purpose: a body is searched for install text
          # only when it is fed to something.
          fed = 0
          for (kk = pstart[p]; kk < j; kk++) {
            if (X[kk] == "|" && (C[kk] == "c" || C[kk] == "Q" || C[kk] == "B")) {
              if (X[kk+1] == "|" || X[kk-1] == "|") continue
              fed = 1
            }
          }
          pfed[p] = fed
          done = 0; bs = s
          while (s <= N) {
            e = s; sb_reset("w", "")
            while (1) {
              while (e <= N && X[e] != "\n") { sb_add("w", X[e]); e++ }
              line = sb_get("w")
              if (!pq[p] && e <= N && line ~ /(^|[^\\])(\\\\)*\\$/) { sb_reset("w", substr(line, 1, length(line) - 1)); e++; continue }
              break
            }
            t = line; if (ps[p]) sub(/^\t+/, "", t)
            # Inside backticks the delimiter may be followed at once by the
            # closing backtick, which the main loop then reads as code (P19).
            # bash reads the delimiter followed at once by `)` as the end of a
            # body inside `$(...)`, and the `)` as code; zsh and dash read
            # the line as body (forms A2, HC1-HC3).
            if (shb && pS[p] && index(t, pd[p] ")") == 1) div = 1
            if (pb[p] && index(t, pd[p] "`") == 1 || shb && pS[p] && index(t, pd[p] ")") == 1) {
              lead = length(line) - length(t)
              body_region(bs, s - 1, p)
              for (kk = s; kk < s + lead + length(pd[p]); kk++) { C[kk] = "b"; WD[kk] = hdepth() }
              if (s + lead + length(pd[p]) - 1 >= s) JMP[s] = s + lead + length(pd[p]) - 1
              np = 0
              return j
            }
            if (t == pd[p]) {
              body_region(bs, s - 1, p)
              for (kk = s; kk < e; kk++) { C[kk] = "b"; WD[kk] = hdepth() }
              if (e <= N) { C[e] = "b"; WD[e] = hdepth() }
              JMP[s] = (e <= N) ? e : N
              s = e + 1; done = 1; break
            }
            s = e + 1
          }
          if (!done) { body_region(bs, N, p); unterm = 1 }
        }
        np = 0
        return j
      }
      # A body is bytes bs..be. A quoted one is data and stepped over; an
      # unquoted one is walked by the main loop as context H.
      function body_region(bs, be, p,   kk) {
        if (be < bs) return
        for (kk = bs; kk <= be; kk++) { BF[kk] = p; WD[kk] = hdepth() }
        if (pq[p]) {
          for (kk = bs; kk <= be; kk++) C[kk] = "b"
          JMP[bs] = be
          return
        }
        nh++; HSTART[bs] = nh; HEND[nh] = be
      }
      # The scripts the command hands to a shell, and the bodies of its
      # substitutions, go out as records of numbers, never of bytes. One
      # record per line: `S` (the word after `sh|bash|zsh|dash -...c`), `E`
      # (the words after `eval`, or an env -S string and the words after it,
      # joined by blanks) or `B` (a substitution body), then the payload as
      # units, ` a:n` for n bytes of the lexed text from byte a, and ` #c`
      # for a byte of code c that the text does not hold where the payload
      # needs it (an escape the shell decodes, the blank that joins two
      # words); consecutive codes fold into one unit (` #10#112#105`). A
      # `!` record says a payload here cannot be named. The reader holds the
      # text and cuts it (lex_payload_build).
      #
      # So a record holds `BSE!`, digits, `:`, `#` and blanks, and no byte
      # of the command can stand in one. These records carried the payload
      # bytes, each ending in \035, and the readers cut at that byte: a \035
      # the command wrote in a body or a script split one payload into two,
      # each lexed alone, and an install after it passed with nothing
      # recorded (verdict buri-20261005-181919). A newline separator had
      # done the same a round before. Structure leaves the lexer as a
      # rendering or as numbers (ARCHITECTURE.md, "What the lexer hands its
      # readers").
      #
      # Words are cut where the shell cuts them (word_sep) and read after
      # its quote removal, so a script word holding escaped quotes, blanks
      # in quotes, glued quoting, an ANSI-C word or escaped blanks is the
      # string the shell passes. W holds the value of each word, for the tests
      # below; WS its units.
      function emit_cscripts(   k, inw, n, W) {
        buf = ""; held = 0; n = 0; sb_reset("w", ""); sb_reset("ws", ""); inw = 0
        for (k = 1; k <= N + 1; k++) {
          if (k > N || word_sep(k)) {
            if (inw) { W[++n] = sb_get("w"); WS[n] = sb_get("ws"); sb_reset("w", ""); sb_reset("ws", ""); inw = 0 }
            if (k > N || C[k] == "p" || C[k] == "c" && DEP[k] == 1 && X[k] ~ /[\n;&|()]/) { cscripts_of(W, n); n = 0 }
            continue
          }
          inw = 1
          if (k in DROP) continue
          if (k in VAL) { sb_add("w", VAL[k]); sb_add("ws", " #" ORD[VAL[k]]) }
          else if (!RM[k]) { sb_add("w", X[k]); sb_add("ws", " " k) }
        }
        if (aqbad) put("!\n")
        printf "%s", buf
      }
      # A unit list with its first <cnt> units left out: the units of
      # `--split-string=VALUE` from its value on.
      function units_drop(s, cnt,   T, nt, i) {
        nt = split(s, T, " "); sb_reset("ud", "")
        for (i = cnt + 1; i <= nt; i++) sb_add("ud", " " T[i])
        return sb_get("ud")
      }
      # A unit list (` k` for byte k, ` #c` for code c) as the units of a record:
      # bytes of the text in a row become one ` a:n`, codes in a row one
      # ` #c#c...`. A run of fewer than four bytes between codes, each
      # below 128, goes out as codes, so an escape on every second byte
      # (`$\047\\na\\nb...\047`) is one unit, not one per byte: the reader
      # pays per unit. Pending codes always come before a pending run.
      function runs(s,   T, nt, i, u, v) {
        nt = split(s, T, " "); sb_reset("rn", ""); sb_reset("rc", ""); RCN = 0; RA = 0; RL = 0
        for (i = 1; i <= nt; i++) {
          u = T[i]
          if (substr(u, 1, 1) == "#") {
            if (RL && RL < 4 && ascii_run(RA, RL)) { for (v = RA; v < RA + RL; v++) rc_add(ORD[X[v]]); RL = 0 }
            else if (RL) { rc_flush(); rl_flush() }
            rc_add(substr(u, 2))
            continue
          }
          v = u + 0
          if (RL && v == RA + RL) { RL++; continue }
          if (RL) { rc_flush(); rl_flush() }
          RA = v; RL = 1
        }
        rc_flush(); rl_flush()
        return sb_get("rn")
      }
      function ascii_run(a, l,   v) {
        for (v = a; v < a + l; v++) if (!(X[v] in ORD)) return 0
        return 1
      }
      function rc_add(c) { sb_add("rc", (RCN++ ? "#" : "") c) }
      function rc_flush() { if (RCN) sb_add("rn", " #" sb_get("rc")); sb_reset("rc", ""); RCN = 0 }
      function rl_flush() { if (RL) sb_add("rn", " " RA ":" RL); RL = 0 }
      # A shell is a command word in the closed list of the grammar
      # (SAFEDEPS_G_SHELLS, passed in as shre): the reader it replaced matched
      # four names and passed `ksh -c "pip install ..."` (caught in review),
      # and the suffix rule after it read ssh as a shell. Options may stand
      # before -c: -o and +o take a name, -- ends the options.
      #
      # env -S STRING (and --split-string) splits STRING into words and runs
      # them with the words after it, so STRING and those words are a script
      # like the words after eval: an E record. Its splitting is not the
      # shell (no operators), so reading it as a script can only find more.
      # A STRING whose value is decided at run time cannot be read: a `!`
      # record, which the reader records as a failed reading.
      #
      # The name is the last part of the word after its last slash, taken by
      # split, which is one pass. It was taken with sub(/.*\//, ...), which the
      # macOS awk (BWK) tries from every byte and runs to the end of the word
      # from each, so one 64KB word cost 13s (scripts/measure/scan-cost.sh).
      function cscripts_of(W, n,   j, m, s, base, args, c, q, sv, svs, rest, np, P) {
        for (j = 1; j <= n; j++) {
          np = split(W[j], P, "/"); base = P[np]
          if (base == "env" && j < n) {
            sv = ""; svs = ""; rest = 0
            for (m = j + 1; m <= n && !rest; m++) {
              if (W[m] == "--" || W[m] !~ /^-/ && W[m] !~ /^[A-Za-z_][A-Za-z0-9_]*=/) break
              if (W[m] ~ /^--split-string=/) { sv = substr(W[m], 16); svs = units_drop(WS[m], 15); rest = m + 1; break }
              if (W[m] == "--split-string") { if (m < n) { sv = W[m+1]; svs = WS[m+1]; rest = m + 2 }; break }
              if (W[m] ~ /^--/ || W[m] !~ /^-/) continue
              for (q = 2; q <= length(W[m]); q++) {
                c = substr(W[m], q, 1)
                if (c ~ /[uCP]/) { if (q == length(W[m])) m++; break }
                if (c == "S") {
                  if (q < length(W[m])) { sv = substr(W[m], q + 1); svs = units_drop(WS[m], q); rest = m + 1 }
                  else if (m < n) { sv = W[m+1]; svs = WS[m+1]; rest = m + 2 }
                  break
                }
              }
              if (rest) break
            }
            if (rest) {
              if (sv ~ /[$`]/) { put("!\n"); break }
              sb_reset("ev", svs)
              for (m = rest; m <= n; m++) sb_add("ev", " #32" WS[m])
              put("E" runs(sb_get("ev")) "\n"); break
            }
            continue
          }
          if (shre != "" && base ~ shre && j < n) {
            for (m = j + 1; m <= n; m++) {
              # -o, or a cluster ending in o (-euo), takes the next word as an option name
              if (W[m] ~ /^[-+][A-Za-z]*o$/) { m++; continue }
              if (W[m] ~ /^-[A-Za-z]*c[A-Za-z]*$/) {
                s = m + 1
                if (s <= n && W[s] == "--") s++
                if (s <= n) { put("S" runs(WS[s]) "\n"); j = s }
                break
              }
              if (W[m] ~ /^[-+][A-Za-z]+$/ || W[m] == "--") continue
              break
            }
            continue
          }
          # The words go to the builder one at a time: joined into one string
          # first, each word copied the whole string again (BWK concatenates
          # by copy).
          if (W[j] == "eval" && j < n) {
            sb_reset("ev", "")
            for (m = j + 1; m <= n; m++) sb_add("ev", (m > j + 1 ? " #32" : "") WS[m])
            put("E" runs(sb_get("ev")) "\n"); break
          }
        }
      }
      # Each substitution body as a `B` record. A backtick body is unescaped
      # the way the shell unescapes it before it reads it (`\`` nests), so
      # its escaping backslashes are not units.
      function emit_substs(   k, a, z, t) {
        buf = ""; held = 0
        for (k = 1; k <= nsub; k++) {
          a = sbeg[k]; z = send[k]; sb_reset("su", "")
          for (t = a; t <= z; t++) {
            if (skind[k] == "B" && X[t] == "\\" && t < z && (X[t+1] == "`" || X[t+1] == "\\" || X[t+1] == "$")) t++
            sb_add("su", " " t)
          }
          put("B" runs(sb_get("su")) "\n")
        }
        printf "%s", buf
      }
      function put(s) {
        buf = buf s
        if (++held >= 4096) { printf "%s", buf; buf = ""; held = 0 }
      }
      # Byte k as the scan view prints it. A code `#` is never a comment
      # start here, and must not become one when the scan is read again:
      # after a blanked region (a quoted word with a `#` glued to its closing
      # quote) or an escaped blank, which this view prints as a blank, it
      # would follow a blank, which is where a comment starts (form WB7).
      function cbyte(k,   cc, cl) {
        cc = X[k]; cl = C[k]
        # A glued `}` that closes no group is a character (group_close).
        if (k in NC) return (cl == "c" || cl == "Q" || cl == "B") ? "%" : " "
        if (cl == "c" || cl == "p") return (cc == "#" && (k == 1 || C[k-1] != "c" && C[k-1] != "e" || C[k-1] == "e" && X[k-1] ~ /[ \t]/)) ? "_" : cc
        if (cl == "e") return index(";&|()<>!{}#`\042\047\\$", cc) ? "_" : (cc == "\n" ? " " : cc)
        return " "
      }
      # Byte k as the stmts view prints it. A statement ends only at a
      # top-level separator: not inside a substitution, an expansion or
      # arithmetic, and not in a redirection operator (`>|`, `<&-`, `2>&1`).
      # command_statements cut wherever these bytes were, so the words after
      # `$(pwd | sed x)` or `>| f` left the install (caught in review). The
      # `&` that opens `&>` ends the word before it, as the `>` of any other
      # redirection does, so it is a blank: written `_`, it was a byte of
      # that word to the recognizers, and `npm ci&>log` was no install
      # (SAFEDEPS_G_END in lib/install-grammar.sh).
      function sbyte(k,   cc) {
        cc = X[k]
        if (C[k] == "c" && (k in DROP) && cc == "&" && X[k+1] == ">") return " "
        if (C[k] == "c" && (DEP[k] != 1 || (k in DROP)) && cc ~ /[;&|\n]/) return (cc == "\n") ? " " : "_"
        return cbyte(k)
      }
      # Whether byte k is a separator the shell reads at the top level, or
      # a case pattern close: where a statement ends.
      function topsep(k) {
        return C[k] == "p" || C[k] == "c" && DEP[k] == 1 && !(k in DROP) && X[k] ~ /[;&|\n]/
      }
      function emit_events(   k) {
        for (k = 1; k <= N; k++) {
          if (k in EV) printf "S %d %s %d %d %s\n", k, C[k], DEP[k], bare(k), (k > 1 ? C[k-1] : "-")
          if (k in EW) printf "W %d %s %d\n", k, C[k], DEP[k]
        }
      }
      # The bare starts first, on one line, then the stmts view: the
      # statements are cut at its separators and at those starts.
      function emit_stmtcuts(   k, first) {
        buf = ""; held = 0; first = 1
        for (k = 1; k <= N; k++) if ((k in EV) && bare(k)) { put((first ? "" : " ") k); first = 0 }
        put("\n")
        for (k = 1; k <= N; k++) put(sbyte(k))
        printf "%s", buf
      }
      # The bytes command_statements reads the words of each statement from,
      # one per byte of the command: a comment, a heredoc operator and a
      # heredoc body, the live code in one too, are no words of a statement
      # and read as blanks, a newline inside quotes as a blank, and each byte
      # of a line continuation as \001, which the reader steps over; a \001
      # the command wrote is \002, so the reader does not step over it as
      # one (it read `c<\001>d` as `cd`). It read
      # the joined view before, which kept the live code of a body (`$(date)`)
      # and blanked the terminator line, so that code stood as the first word
      # of the statement after the body.
      function emit_stmtraw(   k, cl) {
        buf = ""; held = 0
        for (k = 1; k <= N; k++) {
          cl = C[k]
          if (cl == "l") put("\001")
          else if (cl == "m" || cl == "h" || cl == "b" || cl == "B") put(X[k] == "\n" ? "\n" : " ")
          else if (X[k] == "\n" && cl != "c") put(" ")
          else if (X[k] == "\001") put("\002")
          else put(X[k])
        }
        printf "%s", buf
      }
      # A byte of a cwords field: the record and field separators and a
      # newline read as a blank, so the command cannot forge a field.
      function fbyte(b) { return (b == "\037" || b == "\036" || b == "\n") ? " " : b }
      # Each start, the first byte its prefixes leave, the prefixes as the
      # stmts view has them, and the statement from there on up to its end
      # (the next start or a top-level separator) twice: as the recognize
      # view has it, which drops a line continuation, and as the stmts view
      # has it, which the statement split cuts, the bytes of a continuation
      # kept. A start whose prefixes leave nothing before the next has
      # no line.
      function emit_cwords(   k, w, j) {
        buf = ""; held = 0
        for (k = 1; k <= N; k++) {
          if (!(k in EV)) continue
          for (w = k; w <= N && !(w > k && (w in EV)) && ((w in A) || (X[w] == " " || X[w] == "\t") && C[w] == "c" && DEP[w] == 1); w++) ;
          if (w > N || (w > k && (w in EV)) || topsep(w) || word_sep(w)) continue
          put(k "\037" w "\037")
          for (j = k; j < w; j++) put(fbyte(sbyte(j)))
          put("\037")
          for (j = w; j <= N && !(j > w && (j in EV)) && !topsep(j); j++) if (C[j] != "l") put(fbyte((j in DROP) ? " " : sbyte(j)))
          put("\037")
          for (j = w; j <= N && !(j > w && (j in EV)) && !topsep(j); j++) put(fbyte((j in DROP) ? " " : sbyte(j)))
          put("\n")
        }
        printf "%s", buf
      }
      # The string builder (sb_*), the same in every awk program here that
      # builds a string a byte at a time. The macOS awk (BWK) copies
      # both strings on every concatenation, so `w = w c` costs the square of
      # the length: 0.17s for one 64KB word on an M1, paid again by each view
      # that builds one. Bytes go to a piece of 64, pieces to a chunk of 64
      # pieces, chunks to the string: a byte is copied a bounded number of
      # times until the string passes 4KB, and past that the string is copied
      # once per 4KB added. Strings are kept apart by name.
      function sb_reset(id, s) { SBS[id] = s; SBC[id] = ""; SBP[id] = ""; SBPN[id] = 0; SBCN[id] = 0 }
      function sb_add(id, s) {
        SBP[id] = SBP[id] s; if (++SBPN[id] < 64) return
        SBC[id] = SBC[id] SBP[id]; SBP[id] = ""; SBPN[id] = 0; if (++SBCN[id] < 64) return
        SBS[id] = SBS[id] SBC[id]; SBC[id] = ""; SBCN[id] = 0
      }
      function sb_get(id) { return SBS[id] SBC[id] SBP[id] }
      function emit(   k, cc, cl, p, first) {
        buf = ""; held = 0
        if (view == "shell-bodies") {
          first = 1
          for (k = 1; k <= N; k++) {
            if (k in BF) {
              p = BF[k]
              if (pfed[p]) put(X[k])
              else if (X[k] == "\n") put("\n")
            } else if (C[k] == "b" && X[k] == "\n") put("\n")
          }
          printf "%s", buf
          return
        }
        for (k = 1; k <= N; k++) {
          cc = X[k]; cl = C[k]
          if (wends) { put((k > 1 && word_sep(k) && !word_sep(k - 1)) ? "1" : "0"); continue }
          if (view == "noredir") { put((k in DROP) ? " " : cc); continue }
          if (view == "stmts") { put(sbyte(k)); continue }
          # The recognizers read the starts as separators: a `;` goes in at
          # each start no separator stands before, between two bytes, never
          # over one. The prefixes of each command are gone (A), so the `;`
          # stands right before the command word, and every other top-level
          # redirection is blank, as the extractor reads it (noredir).
          # A line continuation is dropped: the shell joins the bytes around
          # it, so `pi\<newline>p install` runs pip. Blanked, as the stmts
          # view keeps its length, it split that word in two.
          if (view == "recognize") {
            if ((k in EV) && bare(k)) put(";")
            if ((k in A) || cl == "l") continue
            put(((k in DROP) && !unterm) ? " " : sbyte(k))
            continue
          }
          if (view == "scan" || view == "live" || view == "flat") {
            # The live view blanks a redirection where it is top-level code,
            # so the inert rewrite finds the verb of `npm 2>/dev/null
            # install`; the body of a substitution in its target stays,
            # since the shell runs it.
            if (view == "live" && (k in DROP) && !(k in KEEP) && (cl == "c" && (DEP[k] == 1 || (k in PSB)) || cl == "e")) put(" ")
            # The flat view blanks the whole redirection: a body in its
            # target is read in the live view, where it stands.
            else if (view == "flat" && (k in DROP)) put(" ")
            else if ((view == "live" || view == "flat") && (cl == "Q" || cl == "B")) put((k in NC) ? "%" : cc)
            else put(cbyte(k))
            continue
          }
          if (view == "unprefixed") {
            # A start no separator stands before gets one put in, as in the
            # recognize view: removing the prefixes between a reserved word
            # and its command left nothing between them (`then>/dev/null pip`
            # as `thenpip`), and the pieces of a payload read from this view
            # had no install in them. A case pattern close stays `)`: written
            # as `;`, the text read again was a case that never closes.
            # A redirection anywhere else is blanked, as in noredir, so the
            # recognizers read the statement the spec extractor reads: left
            # in place, one between the manager and its verb (`pip
            # 2>/dev/null install`) hid the install from every recognizer
            # while the extractor read it.
            if ((k in EV) && bare(k)) put(";")
            if (!(k in A)) put((k in DROP) ? " " : cc)
            continue
          }
          # A view no branch names is a failed reading, never the code view:
          # a caller that asks for a view that is gone gets no text that
          # passes for one.
          if (view != "code") exit 2
          if (cl == "m" || cl == "h" || cl == "b") put(cc == "\n" && cl != "h" ? "\n" : " ")
          else put(cc)
        }
        printf "%s", buf
      }
  ' && printf 'X'); then
    [[ -z "${SAFEDEPS_SCAN_MARK:-}" ]] || printf 'failed\n' >> "${SAFEDEPS_SCAN_MARK}"
    return 1
  fi
  out="${out%X}"
  printf '%s' "${out}"
  # The output is written before the text it belongs to, and each by rename, so
  # a reader that finds the text also finds its view whole.
  if [[ -n "${memo}" ]] && tmp=$(mktemp "${memo}.XXXXXX" 2>/dev/null); then
    { printf '%s' "${out}" > "${tmp}" && mv -f "${tmp}" "${memo}.out" &&
      printf '%s' "${text}" > "${tmp}" && mv -f "${tmp}" "${memo}.in"; } 2>/dev/null || rm -f "${tmp}"
  fi
}

# Every detection predicate reads this instead of the raw command, which is
# why `echo "npm install evil"` is not an install: the text is there, but not
# in execution position. scripts/test/scan-contract.sh states the rules and
# checks this implementation against them. The marker names this reading for
# the scan-failure census and the scan-contract shims.
command_scan_text() {
  shell_lex "$1" scan "safedeps:command_scan_text"
}

# What the install recognizers read: the recognize view, where every place a
# command starts is a separator and the prefixes of each command are gone.
# SAFEDEPS_G_START knows only separators, so a pattern anchored with it has to
# read this view, never the scan view. The reserved words, function heads and
# zsh short forms that put a command at a word are the lexer's to know
# (starts() in shell_lex); a regex chain of the words before a command was a
# second copy of that, and could not see the state that puts a command there
# (`for ((...)) {`, `f g() {`, `repeat 1 {`). The marker is the scan's, so a
# failed reading here fails the recognition the same way (scan-contract's
# scanner shims).
command_start_text() {
  shell_lex "$1" recognize "safedeps:command_scan_text"
}

# The command with heredoc operators, bodies and comments blanked and quotes
# kept (the code view); with `shell-bodies`, only the raw bodies of heredocs
# whose command pipes into something. Both come from shell_lex.
strip_heredoc_bodies() {
  if [[ "${2:-commands}" == "shell-bodies" ]]; then
    shell_lex "$1" shell-bodies "safedeps:strip_heredoc_bodies"
  else
    shell_lex "$1" code "safedeps:strip_heredoc_bodies"
  fi
}

# The payload readers below take the command as written, or a payload, and
# put each payload they find into the array PAYLOADS. A payload never travels
# as bytes between the lexer and its reader: the lexer prints where it lies in
# the text (the cscripts and substs records, numbers only), and the reader cuts
# the text it holds (lex_payload_build). The records used to carry the bytes,
# each payload ending in \035, and a \035 the command wrote split one payload
# into two (verdict buri-20261005-181919); a newline had done the same before.
#
# The lexer knows a heredoc body is data and steps over it, so a `sh -c` a body
# quotes is no payload. The readers used to take the command with its bodies
# stripped and its lines joined, two views lexed again: the joined view kept
# the live code of a body where the command after it stood (verdict
# buri-20261005-145152), and a reader that stripped once more dropped every
# line after a heredoc (caught in review).
#
# Every one of them ends with status 0. They are called as plain commands,
# often inside a command substitution, and bash 3.2 runs that subshell under
# the caller's `set -e`: a reader that ended non-zero ended the subshell there,
# the texts after it were never printed, and the install in them read as none
# (a prototype of this change, 32 forms measured).

# One payload built from <text> and the units of a lexer record, into PAYLOAD.
# `a:n` is n bytes of <text> from byte a (1-based); `#c#c...` the bytes of
# those codes, which an escape decoded or a join put in. Anything else, a code
# outside 1-127 or a range past the end of <text>, is a failed reading: the
# lexer printed something this cannot place, and a payload built without it
# would be a text the shell never runs, read as if it were. The pieces are
# joined once at the end, since a string grown a piece at a time is copied
# whole each time. A run of codes is checked with tests that read it once (a
# glob for its shape, one search for a code that is not 1-127): a regex that
# repeats a group over it asks the regex library for the place of every
# repetition, and a run can be the whole 64KB command.
SAFEDEPS_PAYLOAD_BAD_CODE='(^|#)(0[0-9]*|[0-9]{4,}|[2-9][0-9][0-9]|1[3-9][0-9]|12[89])(#|$)'
lex_payload_build() {
  local LC_ALL=C text="$1" tok fmt ch IFS=$' \t\n'
  local -a parts=() codes=()
  PAYLOAD=""
  shift
  for tok in "$@"; do
    if [[ "${tok}" =~ ^([1-9][0-9]{0,8}):([1-9][0-9]{0,8})$ ]]; then
      if (( BASH_REMATCH[1] + BASH_REMATCH[2] - 1 > ${#text} )); then
        guard_mark_reading_failed
        continue
      fi
      parts+=("${text:BASH_REMATCH[1]-1:BASH_REMATCH[2]}")
    elif [[ "${tok}" == '#'[0-9]* && "${tok}" != *[!0-9#]* && "${tok}" != *'##'* && "${tok}" != *'#' ]] \
        && ! [[ "${tok:1}" =~ ${SAFEDEPS_PAYLOAD_BAD_CODE} ]]; then
      IFS='#'
      # shellcheck disable=SC2206 # split on `#`; the test above leaves digits only
      codes=(${tok:1})
      IFS=$' \t\n'
      printf -v fmt '\\%03o' "${codes[@]}"
      # shellcheck disable=SC2059 # the format is octal escapes only
      printf -v ch "${fmt}"
      parts+=("${ch}")
    else
      guard_mark_reading_failed
    fi
  done
  printf -v PAYLOAD '%s' ${parts[@]+"${parts[@]}"}
  return 0
}

# The payloads one lexing of <text> in <view> names, into LEX_PAYLOADS, with
# the kind of each (S, E or B) in LEX_PAYLOAD_KINDS: the scripts it hands to a
# shell (cscripts) or the bodies of its substitutions (substs). A `!` record, a
# record with any byte but the record's own, and a kind no reader knows are
# failed readings.
lex_payloads() {
  local text="$1" out rec IFS=$' \t\n'
  LEX_PAYLOADS=(); LEX_PAYLOAD_KINDS=()
  case "$2" in
    cscripts) out=$(shell_lex "${text}" cscripts "safedeps:read_payload_words") || return 0 ;;
    substs) out=$(shell_lex "${text}" substs "safedeps:extract_command_substitution_payloads") || return 0 ;;
    *) guard_mark_reading_failed; return 0 ;;
  esac
  while IFS= read -r rec; do
    [[ -n "${rec}" ]] || continue
    if [[ "${rec}" == "!" ]]; then
      guard_mark_reading_failed
      continue
    fi
    if [[ "${rec}" =~ [^BSE0-9:#\ ] || "${rec}" != [BSE]* ]]; then
      guard_mark_reading_failed
      continue
    fi
    # shellcheck disable=SC2086 # the units, split on blanks; the test above leaves no glob byte
    lex_payload_build "${text}" ${rec:1}
    LEX_PAYLOADS+=("${PAYLOAD}")
    LEX_PAYLOAD_KINDS+=("${rec:0:1}")
  done <<< "${out}"
  return 0
}

extract_shell_c_payloads() {
  PAYLOADS=()
  read_payload_scripts "$1" S
  return 0
}

extract_eval_payloads() {
  PAYLOADS=()
  read_payload_scripts "$1" E
  return 0
}

# The scripts <text> hands to `sh -c` (kind S) or to `eval` (kind E), added to
# PAYLOADS, read off the lexer's cscripts view: the word the shell passes,
# quotes removed and escapes applied, and recursively the scripts inside those.
#
# The reader this replaced took the word after `-c` up to its first matching
# quote. `sh -c "echo \"hi\"; pip install evil==1.0.0"` read that way is
# `echo \`, which installs nothing, and the install the shell runs after it
# passed with no verdict -- as did glued quoting, an ANSI-C word and escaped
# blanks. A floor that marked every such word unread made ordinary commands
# UNDECIDED (`bash -c "cd \"$dir\" && npm run build"`, 24 of 30 measured), so
# the word is read as the shell reads it instead, and only an escape the lexer
# cannot name is a failed reading. A head inside quoted text is data: the
# shell does not split that text into words, and neither does this.
read_payload_scripts() {
  local text="$1" kind="$2" depth="${3:-0}" i
  local -a texts=() kinds=()
  lex_payloads "${text}" cscripts
  texts=(${LEX_PAYLOADS[@]+"${LEX_PAYLOADS[@]}"})
  kinds=(${LEX_PAYLOAD_KINDS[@]+"${LEX_PAYLOAD_KINDS[@]}"})
  for (( i = 0; i < ${#texts[@]}; i++ )); do
    [[ "${kinds[i]}" != "${kind}" ]] || PAYLOADS+=("${texts[i]}")
    # A script holding another: `sh -c 'sh -c "pip install ..."'`.
    if (( depth < 3 )); then read_payload_scripts "${texts[i]}" "${kind}" $(( depth + 1 )); fi
  done
  return 0
}

# The bodies of <text>'s substitutions as the lexer delimits them, into
# PAYLOADS. The string scan this replaced cut a body at its first `)` (so a
# case pattern ended it) and did not unescape or nest backticks, and it was a
# second parser of the command.
extract_command_substitution_payloads() {
  lex_payloads "$1" substs
  PAYLOADS=(${LEX_PAYLOADS[@]+"${LEX_PAYLOADS[@]}"})
  return 0
}

# Install text as the pipe checks search for it: a manager, then a verb
# anywhere after it on the same line. Loose on purpose -- it reads text that is
# data at its own quoting level, where no statement grammar applies.
PIPE_MANAGER_RE='(npm|npx|pnpm|pnpx|yarn|bun|bunx|pip[0-9.]*|(python[0-9.]*|py)[[:space:]]+-[A-Za-z0-9]*m[[:space:]]*pip|poetry|uv|uvx|pipx|pipenv|cargo|go|gem|bundle|mvn|dotnet)'
PIPE_INSTALL_TEXT_RE="${PIPE_MANAGER_RE}.*(${SAFEDEPS_G_ALL_VERBS})"

# A pipe into a shell, read on the recognize view. The consumer ends where the
# shell ends a word: at a blank, and also at an operator, a redirection or a
# group closer, so `| sh; echo`, `| sh&&x` and `(... | sh)` are the same
# consumer as `| sh `. `|&` pipes stderr as well, and a group opener before the
# shell (`| (sh)`, `| { sh; }`) still hands it the input. Each of these used to
# pass unjudged. The view puts a `;` in where the command after `{` starts, so
# a `;` is stepped over with the openers: `| { ;sh; }`. A `|` that is half of
# `||` is no pipe: the shell after it runs only when the command before it
# fails, and reads the caller's input, not that command's output. Read as a
# pipe, `false || sh -c "npm ci \"x\""` was denied as an install piped into a
# shell.
PIPE_SHELL_CONSUMER_RE="(^|[^|])\\|&?[[:space:]]*([({;][[:space:]]*)*(${SAFEDEPS_G_SHELLS})([[:space:];&|)}<>\`]|\$)"

text_has_install_words() {
  printf '%s\n' "$1" | judge_grep -qEi "${PIPE_INSTALL_TEXT_RE}"
}

# $1 has its heredoc bodies stripped already. Stripping twice is not a no-op:
# the second pass sees the `<<EOF` line again with no body and no terminator
# after it, and drops every line that follows.
exec_text_pipes_to_shell() {
  local exec_view
  # The consumer side is read the way the producer side is: `| /bin/sh`, `| env
  # sh`, and `| command sh` are the same consumer as `| sh`. The recognize view
  # removes the prefixes at each start, so the two sides of one pipe agree about
  # what counts as the same invocation. It used to be the unprefixed view of the
  # scan view, a lexing of a text another lexing had already changed.
  exec_view=$(command_start_text "$1")
  # A line that ends in a pipe continues on the next one, and a heredoc's
  # terminator can sit between them: `cat <<EOF |`, the body, `EOF`, `sh`.
  # Only a pipe or a shell name can meet across the join, so reading the lines
  # as one costs nothing else.
  local lines="${exec_view}"
  exec_view="${exec_view//$'\n'/ }"
  printf '%s\n' "${exec_view}" | judge_grep -qEi "${PIPE_SHELL_CONSUMER_RE}" && return 0
  # Most pipes feed a simple command, and the walk below is for the rest.
  printf '%s\n' "${exec_view}" | judge_grep -qE "${PIPE_COMPOUND_CONSUMER_RE}" || return 1
  compound_consumer_runs_shell "${lines}"
}

# A pipe into a compound command: a brace group, a subshell, an if, a loop or a
# case, or a command behind `!` or `time`. Read on the exec view.
PIPE_COMPOUND_CONSUMER_RE='(^|[^|])\|&?[[:space:]]*([({]|(if|while|until|for|select|case|time|!)([[:space:]]|$))'

# True when a compound command that a pipe feeds runs a shell anywhere a command
# can stand inside it: `| { :; sh; }`, `| if true; then sh; fi`, `| while read
# -r l; do sh; done`, `| ! sh`. Every command in the compound reads the pipe
# until one of them has read it all, so the shell need not come first; the
# consumer pattern above only looked at the first word, and each of these passed
# unjudged.
#
# $1 is the exec view with its newlines, which end commands here. Words are cut
# at blanks and at the shell's operators; the compound ends at the word that
# closes what opened it, followed through nesting by kind (`{` by `}`, `(` by
# `)`, `if` by `fi`, a loop by `done`, `case` by `esac`). A closer that does not
# close the innermost opener closes nothing, so a misread compound runs on to
# the end of the command: that can only find more shells. Inside a case, a `)`
# ends a pattern and what follows it is a command, so a pattern named `sh` reads
# as a shell -- the same direction.
compound_consumer_runs_shell() {
  local rest="$1" nl=$'\n' tok top pend=false cmd=true skip=false re
  local -a stack=()
  re="^[^[:graph:]${nl}]*(\\|\\||&&|;;&?|;&|\\|&|[;&|(){}]|${nl}|[0-9]*[<>]+&?|[^[:space:];&|(){}<>]+)"
  while [[ "${rest}" =~ ${re} ]]; do
    rest="${rest:${#BASH_REMATCH[0]}}"
    tok="${BASH_REMATCH[1]}"
    if [[ "${skip}" == true && "${tok}" != "${nl}" ]]; then skip=false; continue; fi
    if (( ${#stack[@]} == 0 )); then
      case "${tok}" in
        '|'|'|&') pend=true ;;
        "${nl}") ;;
        # The recognize view puts a `;` in where a command starts with no
        # separator before it, as after `!` or `time`: `| ! sh` reads `| ! ;sh`
        # there. Right after a pipe no `;` the shell reads can stand, so this
        # one is a start, and the command after it still reads the pipe.
        ';') ;;
        '!'|time|-*) [[ "${pend}" == true ]] && cmd=true ;;
        '{'|'('|'if'|'while'|'until')
          if [[ "${pend}" == true ]]; then stack=("${tok}") cmd=true; fi
          pend=false ;;
        'for'|'select'|'case')
          if [[ "${pend}" == true ]]; then stack=("${tok}") cmd=false; fi
          pend=false ;;
        [Ss][Hh]|[Bb][Aa][Ss][Hh]|[Zz][Ss][Hh])
          # Behind `!` or `time`: `| ! sh`.
          [[ "${pend}" == true ]] && return 0
          pend=false ;;
        *) pend=false ;;
      esac
      continue
    fi
    top="${stack[${#stack[@]}-1]}"
    case "${tok}" in
      "${nl}"|';'|'&'|'&&'|'||'|'|'|'|&'|';;'|';&'|';;&') cmd=true; continue ;;
      '(') stack+=("(") cmd=true; continue ;;
      ')')
        if [[ "${top}" == '(' ]]; then
          unset "stack[${#stack[@]}-1]"; cmd=false
        else
          cmd=true
        fi
        continue ;;
      [0-9]*[\<\>]*|[\<\>]*) skip=true; continue ;;
    esac
    [[ "${cmd}" == true ]] || continue
    case "${tok}" in
      [Ss][Hh]|[Bb][Aa][Ss][Hh]|[Zz][Ss][Hh]) return 0 ;;
      '{'|'if'|'while'|'until') stack+=("${tok}") ;;
      'for'|'select'|'case') stack+=("${tok}") cmd=false ;;
      '}') [[ "${top}" != '{' ]] || unset "stack[${#stack[@]}-1]"; cmd=false ;;
      'fi') [[ "${top}" != if ]] || unset "stack[${#stack[@]}-1]"; cmd=false ;;
      'done')
        case "${top}" in 'while'|'until'|'for'|'select') unset "stack[${#stack[@]}-1]" ;; esac
        cmd=false ;;
      'esac') [[ "${top}" != case ]] || unset "stack[${#stack[@]}-1]"; cmd=false ;;
      'then'|'do'|'else'|'elif'|'!'|time|-*) ;;
      [A-Za-z_]*=*) ;;
      *) cmd=false ;;
    esac
  done
  # Text the walk could not cut into words is read as a shell, not as none.
  [[ -n "${rest//[[:space:]]/}" ]]
}

payload_pipes_install_text_to_shell() {
  local payload="$1"

  # The pipe must sit in EXECUTION position at this quoting level: outside
  # quotes (a quoted `| sh` is data — e.g. a repro idiom quoted in a commit
  # message) and outside heredoc bodies (a body is data; `cat <<EOF | sh` keeps
  # its pipe on the redirect line, which survives the strip). The install text
  # is still searched raw, because in a real hidden install it lives inside the
  # producer's quotes or heredoc body by construction. The exec view is the
  # recognize view of the payload as written, which blanks a body, the live
  # code in one too.
  #
  # Check the raw install text FIRST: the grep is O(n) while building the exec
  # view is not free, and both checks are pure predicates, so conjunction order
  # cannot change the verdict — only the cost. Most commands carry no install
  # text at all and must not pay for the exec view. A payload with no `|` has
  # no pipe in any view of it, and most visible installs, which carry install
  # text by definition, pipe nothing.
  [[ "${payload}" == *'|'* ]] || return 1
  text_has_install_words "${payload}" || return 1
  exec_text_pipes_to_shell "${payload}"
}

# The candidate texts as the install recognizers read them, in the current
# reading: the recognize view of the command, then of each of its payloads
# (command_payload_raw_texts), each followed by a newline. Each text is lexed
# once, as written: the command whole, since a statement start depends on
# what came before it (the second line of a case, `x) { pip install ...; };;`,
# is a case pattern with no case before it when read alone, form X22 of the
# statement-start judgment), and each payload on its own, since the inner
# shell reads a payload from its start.
#
# The command used to go through the joined view first, and the recognize
# view was the lexing of that view: a second lexing of a text the first had
# changed. The joined view blanked a heredoc body and its terminator line but
# kept the live code in an unquoted one, so `cat <<E`, `$(date)`, `E`, `pip
# install evil==6.6.6` read as `$(date)   pip install ...`, a command with
# arguments, and the install after the body passed with no verdict in every
# shell (verdict buri-20261005-145152). The recognize view drops a line
# continuation itself.
command_candidate_start_texts() {
  command_start_text "$1"
  printf '\n'
  command_payload_start_texts "$1"
  return 0
}

# The payloads of a command as written, into PAYLOADS: the text a `sh -c`, an
# `eval` or a command substitution hands to a shell, and the payloads of each
# payload, of every kind, to three levels. The readers used to follow a script
# only into the scripts inside it, so the substitution in `sh -c 'x=$(pip
# install ...)'` was read by no reader and the install passed with nothing
# recorded, whatever byte the script held (every tree to v2.18.1). Each text is
# lexed twice: once for its scripts, once for its substitutions.
command_payload_raw_texts() {
  local -a queue=("$1") level=(0) found=()
  local i=0 k t d p
  while (( i < ${#queue[@]} )); do
    t="${queue[i]}"; d="${level[i]}"; i=$(( i + 1 ))
    for k in cscripts substs; do
      lex_payloads "${t}" "${k}"
      for p in ${LEX_PAYLOADS[@]+"${LEX_PAYLOADS[@]}"}; do
        found+=("${p}")
        if (( d < 3 )); then queue+=("${p}"); level+=("$(( d + 1 ))"); fi
      done
    done
  done
  PAYLOADS=(${found[@]+"${found[@]}"})
  return 0
}

# The recognize view of each payload of <command> (command_payload_raw_texts),
# one per line: the text an install recognizer reads for each.
command_payload_start_texts() {
  local payload
  local -a pls=()
  command_payload_raw_texts "$1"
  pls=(${PAYLOADS[@]+"${PAYLOADS[@]}"})
  for payload in ${pls[@]+"${pls[@]}"}; do
    [[ "${payload}" =~ [^[:space:]] ]] || continue
    command_start_text "${payload}"
    printf '\n'
  done
  return 0
}

command_is_injectable_npm_install() {
  local texts
  texts=$(command_candidate_start_texts "$1")
  judge_grep -qEi "${SAFEDEPS_G_NPM_INSTALL_RE}" <<< "${texts}"
}

# The npm install verbs in the text on stdin, as grep reports them with the
# options given (`-q`, `-ob`). The name ignores case, as the recognizers and
# safedeps_manager_name read it: macOS volumes ignore case, so `NPM ci` runs
# npm. Three readers of the inert rewrite each kept a spelling of this pattern
# that matched case, so the recognizer called `NPM ci` an install and the
# rewrite found no verb in it: a downgrade, where main (a6fd57a) had
# appended the flag. Every reader here that looks for a verb to rewrite asks
# this one. The check for an npm verb in a heredoc body does not: its match
# withholds every rewrite, so it keeps the release's case (inert_rewrite_in_place).
# With --nested first, the verb ends in the `%` the live view prints for a glued
# `}` that closes no group there (inert_nested_verb_ends).
inert_npm_verb_grep() {
  local end="${SAFEDEPS_G_END}"
  if [[ "${1:-}" == --nested ]]; then end="%"; shift; fi
  LC_ALL=C judge_grep "$@" -Ei "npm${SAFEDEPS_G_OPTS}[[:space:]]+(${SAFEDEPS_G_NPM_VERBS}|${SAFEDEPS_G_NPM_LINK_VERBS})${end}"
}

# Each npm install verb in <text>, one per line, as `<start> <end>`: the offset
# of its `npm` and the offset just past the verb, read on the live view, so a
# verb in a comment, a quoted string or a heredoc body is not one, and a verb
# in a substitution inside quotes is. The live view keeps every byte in place,
# so an offset there is the offset in <text>.
#
# The live view keeps the body of a substitution in a redirection target,
# because the shell runs it and an npm install in it needs the flag where it
# stands. So a redirection with such a target between npm and its verb left
# the body between them, no verb was found, and the rewrite ended as if there
# were nothing to rewrite: `npm >$(echo f) install x` ran its lifecycle
# scripts with no flag and no record (every shell runs it). The flat view
# blanks the redirection whole, so the verb is found there; the two views
# keep the same offsets, and a verb both find is one pair.
inert_verb_ends() {
  local live flat matches more
  live=$(shell_lex "$1" live "safedeps:inert_offsets") || return 1
  flat=$(shell_lex "$1" flat "safedeps:inert_offsets") || return 1
  # The grep and the awk run apart so that only "no match" reads as no verb: a
  # failed awk shared one `||` with grep's exit 1, and the rewrite was then
  # dropped as if there were nothing to rewrite.
  matches=$(printf '%s\n' "${live}" | inert_npm_verb_grep -ob) || matches=""
  if [[ "${flat}" != "${live}" ]]; then
    more=$(printf '%s\n' "${flat}" | inert_npm_verb_grep -ob) || more=""
    if [[ -n "${more}" && -n "${matches}" ]]; then matches+=$'\n'"${more}"; elif [[ -n "${more}" ]]; then matches="${more}"; fi
  fi
  [[ -n "${matches}" ]] || return 0
  # The match ends in the byte that ended the verb, unless the verb ended the
  # line; no verb ends in one of those bytes.
  if ! printf '%s\n' "${matches}" | LC_ALL=C awk -v endre="${SAFEDEPS_G_WORD_END_CLASS}\$" '
    # safedeps:inert_offsets (scripts/measure/scan-failure-census.sh keys on this line)
    # The match ends with SAFEDEPS_G_END: the byte that ended the verb, unless
    # the verb ended the line, and before it a `}` that closes a zsh group.
    # Neither is the verb.
    { c = index($0, ":"); m = substr($0, c + 1); s = substr($0, 1, c - 1); if (m ~ endre) m = substr(m, 1, length(m) - 1); if (m ~ /[}]$/) m = substr(m, 1, length(m) - 1); e = s + length(m); if (!seen[s, e]++) print s, e }'; then
    [[ -z "${SAFEDEPS_SCAN_MARK:-}" ]] || printf 'failed\n' >> "${SAFEDEPS_SCAN_MARK}"
    return 1
  fi
}

# Each npm install verb in <text> that the rewrite cannot reach, one per line,
# the offset just past the verb: one glued to a `}` that stands inside the body
# of a substitution. The recognizers read that body as a payload, at its own
# top level, where zsh closes a group at the `}` and runs the install (``echo
# `{ npm ci}` ``). The rewrite reads <text>, where a nested `}` is a character
# (`%` in the live view, group_close in shell_lex), so inert_verb_ends finds no
# verb there. Alone, such an install left the rewrite nothing to do, and the
# command was a recorded downgrade. Beside an install the rewrite did reach,
# the command read as rewritten, and zsh ran the nested install's scripts with
# nothing recorded (verdict tookdaki-20261006-112251, R1). The caller keeps
# the rewrite as it is and records the floor (inert_rewrite_in_place).
#
# Whether the `}` is nested is the lexer's answer: it stands in a range the
# substs view names. Whether the payload's reading closes a group there is not
# asked, so a nested `npm ci}` that closes none is counted too. That can only
# add a record, never drop one.
inert_nested_verb_ends() {
  local LC_ALL=C text="$1" live matches subs m s pos rec tok inside IFS=$' \t\n'
  live=$(shell_lex "${text}" live "safedeps:inert_offsets") || return 1
  [[ "${live}" == *%* ]] || return 0
  matches=$(printf '%s\n' "${live}" | inert_npm_verb_grep --nested -ob) || matches=""
  [[ -n "${matches}" ]] || return 0
  subs=$(shell_lex "${text}" substs "safedeps:inert_offsets") || return 1
  while IFS= read -r m; do
    [[ -n "${m}" ]] || continue
    # grep's offset counts from 0, and its match ends in the `%`, so the
    # offset plus the length of the match is that byte, counted from 1.
    s="${m%%:*}" m="${m#*:}"
    pos=$(( s + ${#m} ))
    # A `%` the command holds as written is no `}`.
    [[ "${text:pos-1:1}" == "}" ]] || continue
    inside=false
    while IFS= read -r rec; do
      [[ -n "${rec}" ]] || continue
      if [[ "${rec}" =~ [^BSE0-9:#\ ] || "${rec}" != [BSE]* ]]; then
        guard_mark_reading_failed
        continue
      fi
      # shellcheck disable=SC2086 # the units, split on blanks; the test above leaves no glob byte
      for tok in ${rec:1}; do
        [[ "${tok}" =~ ^([1-9][0-9]{0,8}):([1-9][0-9]{0,8})$ ]] || continue
        (( pos < BASH_REMATCH[1] || pos >= BASH_REMATCH[1] + BASH_REMATCH[2] )) || inside=true
      done
    done <<< "${subs}"
    [[ "${inside}" != true ]] || printf '%s\n' "$(( pos - 1 ))"
  done <<< "${matches}"
  return 0
}

# Bytes that no shell expansion acts on, in bash, zsh or dash under their
# default options. A word is one the shell leaves as written only when every
# byte of it outside quotes is one of these and it does not start with `~` or
# `=` (shell_expands).
SAFEDEPS_SHELL_INERT_BYTES='abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/@:+,=%-'

# Whether the shell can change the words of a statement when it runs it. The
# answer is an allow-list, not a list of what expands: a word is left as
# written only when every byte of it outside quotes is in
# SAFEDEPS_SHELL_INERT_BYTES and it does not start with `~` or `=`; any other
# byte, wherever it stands, makes the word one the shell decides at run time.
# Two deny-lists stood here and each missed a kind of expansion one at a time:
# `$`, backquotes and globs without the tilde (`HOME=--cache; npm install x ~`
# handed npm `--cache` before the trailing flag, and the install ran its
# scripts with nothing recorded), then a list of the expansions that still
# missed zsh's named directories (`~c` after `hash -d`), its alternation glob
# `(--cache|zz)` and bash's extglob `@(--cache)` once a command turns it on.
#
# The set is what is left after the expansions bash's manual lists, in its
# order, with what zsh and dash add, each step naming the bytes it needs:
#
#   brace          `{` (bash, zsh: `{a,b}`, `{1..3}`)
#   tilde          `~` (a word's start: `~`, `~user`, `~+`, `~-`, zsh's `~1`
#                  and named directories `~name`; after `=` or `:` in a word
#                  shaped like an assignment, `a=x:~`, measured in bash)
#   parameter, command, arithmetic
#                  `$` and a backquote
#   process substitution
#                  `<(`, `>(`, zsh's `=(`
#   word splitting splits only what the steps above produced
#   pathname       `*`, `?`, `[`; bash's extglob `?(`, `*(`, `+(`, `@(`, `!(`;
#                  zsh's alternation `(a|b)`, qualifiers `x(.)`, numeric ranges
#                  `<1-3>`, and with extendedglob `^`, `#` and `~` in a word
#   zsh's `=cmd`   `=` at a word's start
#   history        `!` and `^` (only in an interactive shell)
#
# None of those bytes is in the set, and `=` only past a word's start, so a
# kind of expansion the table forgot still makes its word dynamic. A byte the
# set leaves out that expands nothing (`~` inside a version range like
# `foo@~1.2.3`, `^` in `foo@^1.2.3`) costs a record, never a pass. A `}` glued
# to a word that closes no group is `%` in the live view, a character to every
# shell that runs it, which no shell expands (group_close in shell_lex).
#
# Each byte is read in the quoting the shell reads it in. <live> is the
# statement with redirections, comments and quoted text blanked (the lexer's
# flat view), so a quoted byte is never judged by the set; a blank stands
# where a quote or a line continuation was, which only splits a word and can
# only add a word start. <words> is its words after quote removal (the pieces view),
# for `$` and backquotes, which act inside double quotes too; a `$` in single
# quotes counts there as well, which costs a record. A view that marks the
# quoted bytes of each word can replace both arguments with no change to the
# rule.
#
# An npm install still gets the flag right after its verb as well
# (inert_flag_offsets), so a word read as written that the shell changes
# anyway leaves the install where the flag after the verb alone left it.
shell_expands() {
  local live="$1" words="$2" w
  local -a live_words=()
  [[ "${words}" != *[\$\`]* ]] || return 0
  IFS=$' \t\n' read -r -d '' -a live_words <<< "${live}" || true
  for w in "${live_words[@]+"${live_words[@]}"}"; do
    [[ "${w}" != [~=]* && "${w}" != *[!"${SAFEDEPS_SHELL_INERT_BYTES}"]* ]] || return 0
  done
  return 1
}

# How npm reads the npm statement <text> (from its `npm` to where it ends),
# read the way npm reads its arguments (safedeps_npm_read_args, both npm
# versions where they differ). Sets INERT_READ_KIND to `read`, or to `dynamic`
# when the shell can change a word in it at run time (shell_expands: the word
# could be any option, or a `--`) or the reading depends on something no table
# holds;
# INERT_READ_ENDS to true when a word in it is only dashes, which ends npm's
# options; INERT_READ_LAST to the last value ignore-scripts takes in each
# reading (`unset` when none sets it); and INERT_READ_REST to everything else
# the reading found: the positional words, the option values and the other
# switches. Two statements with the same INERT_READ_REST differ at most in
# ignore-scripts, which is how a placement of the flag is checked: it must
# leave ignore-scripts true and change nothing else npm reads.
inert_statement_reads() {
  local pieces live line words w k last rest dynamic=false
  local -a argv=() line_words=()
  INERT_READ_KIND="" INERT_READ_ENDS=false INERT_READ_LAST="" INERT_READ_REST=""
  # The statement as written, lexed once: the pieces view reads a newline
  # inside quotes, a continuation and a comment as the shell reads them, the
  # whole text at a time. It used to read one line at a time, so the
  # statement went in as the joined view, which was a second lexing of a text
  # the first had changed. Fed as written to that reading, `--message
  # "a<newline>--ignore-scripts"` put the quoted line on a line of its own,
  # where it read as the flag, and the install ran its scripts unrewritten.
  pieces=$(shell_lex "$1" pieces "safedeps:inert_offsets") || return 1
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    if [[ "${line}" == "!" ]]; then dynamic=true; continue; fi
    words="${line#*$'\037'}"
    words="${words#*$'\037'}"
    words="${words%%$'\037'*}"
    IFS=$' \t' read -ra line_words <<< "${words}"
    for w in "${line_words[@]+"${line_words[@]}"}"; do
      [[ "${w}" == $'\002' ]] && w="" || w="${w//$'\002'/ }"
      [[ ! "${w}" =~ ^--+$ ]] || INERT_READ_ENDS=true
      argv+=("${w}")
    done
  done <<< "${pieces}"
  INERT_READ_KIND=dynamic
  [[ "${dynamic}" == false ]] || return 0
  live=$(shell_lex "$1" flat "safedeps:inert_offsets") || return 1
  ! shell_expands "${live}" "${argv[*]+"${argv[*]}"}" || return 0
  for k in plain other; do
    if [[ "${k}" == other ]]; then
      safedeps_npm_other_applies "${argv[@]:1}" || break
      safedeps_npm_as_other safedeps_npm_read_args "${argv[@]:1}" || return 0
    else
      safedeps_npm_read_args "${argv[@]:1}" || return 0
    fi
    last=unset rest="${k}"
    for w in "${SAFEDEPS_G_NPM_SWITCHES[@]+"${SAFEDEPS_G_NPM_SWITCHES[@]}"}"; do
      if [[ "${w}" == ignore-scripts=* ]]; then last="${w#*=}"; else rest+=$'\036'"s:${w}"; fi
    done
    for w in "${SAFEDEPS_G_NPM_WORDS[@]+"${SAFEDEPS_G_NPM_WORDS[@]}"}"; do rest+=$'\036'"w:${w}"; done
    for w in "${SAFEDEPS_G_NPM_VALUES[@]+"${SAFEDEPS_G_NPM_VALUES[@]}"}"; do rest+=$'\036'"v:${w#*$'\037'}"; done
    INERT_READ_LAST+="${last} " INERT_READ_REST+="${rest}"$'\035'
  done
  INERT_READ_KIND=read
}

# Where `--ignore-scripts` goes for each npm install verb in <text>: one line
# or two per verb, the offset of the byte a flag goes after. npm keeps the last
# value an option is given (measured on npm 11.19.0: `--ignore-scripts=false`,
# `--no-ignore-scripts`, `--no-ignore` and `--ign=false` after the flag each
# ran the install scripts), so the first place tried is just past the last
# word of the statement's own arguments, before a `--` that ends its options,
# a redirection, a comment, a heredoc operator or the separator that ends it.
# Placed right after the verb, it lost to all of them. A place stands only
# when the statement read with the flag there leaves ignore-scripts true and
# reads the same otherwise (inert_statement_reads), so an option that takes the
# next word as its value cannot take the flag. A statement whose arguments
# already leave the option true prints `-`. Every other statement also gets
# the flag right after its verb (the floor, where the release put it), so it
# prints the place read and the verb's end, each with ` asked` when it asked
# for its scripts; one holding a word the shell decides at run time prints the
# last argument's end and the verb's, each with ` unverified`; and one with no
# place read (its end not found, a `--` before the flag, or no place reading
# true) prints the verb's end with ` floor`, which the caller sends and
# records as a downgrade. A verb the rewrite cannot reach, glued to a `}`
# nested in a substitution (inert_nested_verb_ends), prints its end with
# ` nested`: the caller places no flag there and records the floor.
inert_flag_offsets() {
  local text="$1" pairs nested dir ends start bound at stmt cands p note want placed verb
  nested=$(inert_nested_verb_ends "${text}") || return 1
  while read -r p; do
    [[ -z "${p}" ]] || printf '%s nested\n' "${p}"
  done <<< "${nested}"
  pairs=$(inert_verb_ends "${text}") || return 1
  [[ -n "${pairs}" ]] || return 0
  dir=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-inert.XXXXXX") || {
    [[ -z "${SAFEDEPS_SCAN_MARK:-}" ]] || printf 'failed\n' >> "${SAFEDEPS_SCAN_MARK}"
    return 1
  }
  printf '%s' "${text}" > "${dir}/raw"
  if ! shell_lex "${text}" live "safedeps:inert_offsets" > "${dir}/live" \
     || ! shell_lex "${text}" code "safedeps:inert_offsets" > "${dir}/code" \
     || ! shell_lex "${text}" noredir "safedeps:inert_offsets" > "${dir}/noredir"; then
    rm -rf "${dir}"
    return 1
  fi
  # live finds where the statement ends: it keeps the code the shell runs at
  # this level, nested code inside quotes included, and blanks quoted text. code
  # and noredir say which trailing bytes are not arguments: a comment or a
  # heredoc operator (code) and a redirection (noredir). The three keep every
  # byte in place, so one index reads all of them and the command.
  if ! ends=$(printf '%s\n' "${pairs}" | LC_ALL=C awk -v dir="${dir}" '
    # safedeps:inert_offsets (scripts/measure/scan-failure-census.sh keys on this line)
    # The string builder (sb_*): see shell_lex.
    function sb_reset(id, s) { SBS[id] = s; SBC[id] = ""; SBP[id] = ""; SBPN[id] = 0; SBCN[id] = 0 }
    function sb_add(id, s) {
      SBP[id] = SBP[id] s; if (++SBPN[id] < 64) return
      SBC[id] = SBC[id] SBP[id]; SBP[id] = ""; SBPN[id] = 0; if (++SBCN[id] < 64) return
      SBS[id] = SBS[id] SBC[id]; SBC[id] = ""; SBCN[id] = 0
    }
    function sb_get(id) { return SBS[id] SBC[id] SBP[id] }
    function slurp(f,   line, count) {
      sb_reset("slurp", ""); count = 0
      while ((getline line < f) > 0) sb_add("slurp", (count++ ? "\n" : "") line)
      close(f)
      return sb_get("slurp")
    }
    function blank(c) { return c == " " || c == "\t" || c == "\n" || c == "" }
    function sep(k) { return L[k] == ";" || L[k] == "&" || L[k] == "|" || L[k] == "(" || L[k] == ")" || L[k] == "<" || L[k] == ">" || L[k] == "`" || L[k] == "\n" }
    BEGIN {
      n = split(slurp(dir "/raw"), T, ""); split(slurp(dir "/live"), L, "")
      split(slurp(dir "/code"), C, ""); split(slurp(dir "/noredir"), R, "")
    }
    {
      s = $1; e = $2; inside = 0
      for (k = 1; k <= e; k++) if (L[k] == "`") inside = !inside
      # A backtick against the verb ends it only when it closes a substitution
      # the verb is in. One that opens a substitution continues the word: `npm
      # ci`echo x`` hands npm `cix`, which installs nothing, and a flag after
      # `ci` would make it `npm ci`. Such a match is no verb.
      if (L[e + 1] == "`" && !inside) { print "x", s, e; next }
      depth = 0; brace = 0; b = 0; dd = 0; unsure = 0
      for (k = e + 1; k <= n; k++) {
        c = L[k]
        if (c == "`") {
          if (depth || brace) { unsure = 1; break }
          if (inside) { b = k; break }
          for (j = k + 1; j <= n && L[j] != "`"; j++) ;
          if (j > n) { unsure = 1; break }
          k = j; continue
        }
        # A `}` that stands as a word is not an end: to bash it is an argument
        # (`npm i x } --no-ignore` hands both words to npm), and zsh, which
        # closes a group with it, will not parse a word after it, so a flag
        # there runs nothing. A `}` glued to the end of a word is in the live
        # view only where zsh closes a group with it (the lexer prints any
        # other as `%`, group_close), and it ends the statement: the flag goes
        # before it, where zsh reads it as the last word (`{ npm ci
        # --ignore-scripts}`). After it, `{ npm ci} --ignore-scripts` is a
        # parse error in zsh and in bash.
        if (c == "}" && !depth && !brace && !blank(C[k - 1]) && (k == n || blank(L[k + 1]) || index(";&|)<>`", L[k + 1]))) { b = k; break }
        if (c == "(") { depth++; continue }
        if (c == ")") { if (!depth) { b = k; break }; depth--; continue }
        if (c == "$" && L[k + 1] == "{") { brace++; k++; continue }
        if (c == "}" && brace) { brace--; continue }
        if (depth || brace) continue
        if (c == "\n" || c == ";") { b = k; break }
        if (c == "&") { if (L[k - 1] == ">" || L[k - 1] == "<" || L[k + 1] == ">") continue; b = k; break }
        if (c == "|") { if (L[k - 1] == ">") continue; b = k; break }
        # A word that is only dashes, quoted or escaped or not, ends npm options:
        # the flag after it is an operand (`npm ci -- --ignore-scripts` ran the
        # scripts).
        if (!blank(C[k]) && blank(C[k - 1])) {
          sb_reset("w", "")
          for (j = k; j <= n && !blank(C[j]) && !sep(j); j++) sb_add("w", C[j])
          w = sb_get("w")
          gsub(/["\047\\]/, "", w)
          if (w ~ /^--+$/) { dd = k; b = k; break }
        }
      }
      if (unsure) { print "?", s, e; next }
      if (!b) b = n + 1
      at = b - 1
      while (at > e && (blank(C[at]) || blank(R[at]) || (T[at] == "\\" && T[at + 1] == "\n"))) at--
      # Every other place the flag could go, from the last argument back to the
      # verb: the end of each word. A blank inside quotes reads as a word end
      # here too; the reading of the placed flag rejects it, since it changes
      # a value npm reads.
      sb_reset("cands", at)
      for (k = at - 1; k > e; k--)
        if (!blank(T[k]) && !blank(C[k]) && !blank(R[k]) && blank(T[k + 1])) sb_add("cands", "," k)
      if (e < at) sb_add("cands", "," e)
      print s, b, at, (dd ? "dd" : "-"), sb_get("cands")
    }') || [[ -z "${ends}" ]]; then
    [[ -z "${SAFEDEPS_SCAN_MARK:-}" ]] || printf 'failed\n' >> "${SAFEDEPS_SCAN_MARK}"
    rm -rf "${dir}"
    return 1
  fi
  rm -rf "${dir}"
  while read -r start bound at _ cands; do
    # A match the end finder read as no verb (an opening backtick against it).
    [[ "${start}" != x ]] || continue
    # Where no place is read, the statement keeps the floor alone: the flag
    # right after its verb, where the release put it, recorded as a downgrade
    # (` floor`). Its end could not be found (the awk printed `? <start> <verb
    # end>`), or its words show a `--` the flag would land after (one the end
    # finder could not read, or one before the verb: `npm -- ci -- x`), or no
    # place reads as true below. These used to drop the rewrite of the whole
    # command, which left such an install with less than the release gave it.
    if [[ "${start}" == "?" ]]; then
      printf '%s floor\n' "${at}"
      continue
    fi
    verb="${cands##*,}"
    stmt="${text:start:bound-1-start}"
    inert_statement_reads "${stmt}" || return 1
    if [[ "${INERT_READ_ENDS}" == true ]]; then
      printf '%s floor\n' "${verb}"
      continue
    fi
    if [[ "${INERT_READ_KIND}" != read ]]; then
      # A word the shell decides at run time can be an option that sets
      # ignore-scripts, one that takes the next word as its value, or a `--`.
      # The flag goes both after the verb, where only a later word can undo
      # it, and after the last argument, where only a word before it can, and
      # the install is recorded as one whose flag nobody read.
      printf '%s unverified\n' "${at}"
      (( ${cands##*,} == at )) || printf '%s unverified\n' "${cands##*,}"
      continue
    fi
    if [[ " ${INERT_READ_LAST}" != *" "[!t]* ]]; then
      # Its own arguments leave the option true. The caller still writes the
      # floor here where the release rewrote the command, which it did unless
      # the text `--ignore-scripts` stood unquoted in it (inert_release_skips):
      # a quoted `"--ignore-scripts"` and `--no-no-ignore-scripts` it rewrote.
      printf '%s settled\n' "${verb}"
      continue
    fi
    note=""
    [[ " ${INERT_READ_LAST}" != *" false "* ]] || note=" asked"
    want="${INERT_READ_REST}" placed=""
    # The flag goes at the first place, from the last argument back, where npm
    # reads the placed statement with ignore-scripts true and everything else
    # as before. After the last argument it outlasts every word that sets the
    # option; it fails there when the last word is an option that takes the
    # next word as its value (`--cache`, `-C`, `--reg`), which then takes the
    # flag instead (measured on npm 11.19.0: the install ran its scripts).
    #
    #
    # The flag also goes right after the verb, always: that is the floor
    # (inert_rewrite_in_place adds the release's own end flag to it). The
    # place is read without it, since it only adds a true flag or takes a
    # `true` or `false` after the verb as its value, as the release's flag
    # did there.
    for p in ${cands//,/ }; do
      inert_statement_reads "${stmt:0:p-start}"" --ignore-scripts""${stmt:p-start}" || return 1
      [[ "${INERT_READ_KIND}" == read && "${INERT_READ_ENDS}" != true ]] || continue
      [[ " ${INERT_READ_LAST}" != *" "[!t]* && "${INERT_READ_REST}" == "${want}" ]] || continue
      placed="${p}"
      break
    done
    # No place in the statement leaves the option true without changing what
    # npm reads (`--no-ignore-scripts x --cache`): the floor alone, recorded.
    if [[ -z "${placed}" ]]; then
      printf '%s floor\n' "${verb}"
      continue
    fi
    printf '%s%s\n' "${placed}" "${note}"
    (( placed == verb )) || printf '%s%s\n' "${verb}" "${note}"
  done <<< "${ends}"
}

# The scripts handed to `sh -c` (or bash, zsh, dash) and `eval` in <command>, as
# `<start> <length>` in bytes, for each script whose bytes are the bytes the
# inner shell reads: a single-quoted one, or a double-quoted one with no
# escape and no substitution in it. Prints `?` instead when a double-quoted
# script it cannot map has `npm` anywhere after its head, so the caller records
# a downgrade rather than reporting the command inert.
inert_payload_spans() {
  local command="$1" scan heads
  scan=$(command_scan_text "${command}") || return 1
  # The grep and the awk run apart, as in inert_verb_ends: under pipefail a grep
  # that found no head failed the pipeline, and "no script handed to a shell"
  # read as a failed reading.
  heads=$(printf '%s\n' "${scan}" \
    | LC_ALL=C judge_grep -obE "(^|[^[:alnum:]_.-])((bash|sh|zsh|dash)[[:space:]]+-[A-Za-z]*c|eval)([[:space:]]|\$)") || heads=""
  [[ -n "${heads}" ]] || return 0
  heads=$(printf '%s\n' "${heads}" | LC_ALL=C awk '
      # safedeps:inert_payload_spans (scripts/measure/scan-failure-census.sh keys on this line)
      { c = index($0, ":"); printf "%d ", substr($0, 1, c - 1) + length(substr($0, c + 1)) }') || {
    [[ -z "${SAFEDEPS_SCAN_MARK:-}" ]] || printf 'failed\n' >> "${SAFEDEPS_SCAN_MARK}"
    return 1
  }
  if ! printf '%s' "${command}" | LC_ALL=C awk -v heads="${heads}" '
    # safedeps:inert_payload_spans (scripts/measure/scan-failure-census.sh keys on this line)
    { X = X (NR > 1 ? "\n" : "") $0 }
    END {
      n = split(heads, H, " ")
      for (j = 1; j <= n; j++) {
        p = H[j] + 1
        while (substr(X, p, 1) == " " || substr(X, p, 1) == "\t") p++
        q = substr(X, p, 1)
        if (q != "\047" && q != "\042") continue
        e = index(substr(X, p + 1), q)
        body = e ? substr(X, p + 1, e - 1) : ""
        if (q == "\042" && (!e || index(body, "\\") || index(body, "$(") || index(body, "`"))) {
          if (index(substr(X, p), "npm")) print "?"
          continue
        }
        if (e < 2) continue
        printf "%d %d\n", p, e - 1
      }
    }'; then
    [[ -z "${SAFEDEPS_SCAN_MARK:-}" ]] || printf 'failed\n' >> "${SAFEDEPS_SCAN_MARK}"
    return 1
  fi
}

# Where `--ignore-scripts` goes for every npm install the shell runs in <text>
# (inert_flag_offsets): its own code (the live view) and, recursively, the
# scripts it hands to a shell. Returns 3 when an install sits where no offset
# can reach it.
inert_offsets_of() {
  local text="$1" depth="${2:-0}" spans start len body inner e note
  inert_flag_offsets "${text}" || return $?
  (( depth < 4 )) || return 0
  spans=$(inert_payload_spans "${text}") || return 1
  [[ "${spans}" != *"?"* ]] || return 3
  while read -r start len; do
    [[ -n "${start}" ]] || continue
    body=$(printf '%s' "${text}" | LC_ALL=C awk -v s="${start}" -v l="${len}" '
      # safedeps:inert_payload_spans (scripts/measure/scan-failure-census.sh keys on this line)
      { X = X (NR > 1 ? "\n" : "") $0 } END { printf "%s", substr(X, s + 1, l) }') || {
      [[ -z "${SAFEDEPS_SCAN_MARK:-}" ]] || printf 'failed\n' >> "${SAFEDEPS_SCAN_MARK}"
      return 1
    }
    inner=$(inert_offsets_of "${body}" $(( depth + 1 ))) || return $?
    while read -r e note; do
      [[ -n "${e}" ]] || continue
      if [[ "${e}" == - ]]; then printf -- '-\n'; continue; fi
      printf '%s%s\n' "$(( start + e ))" "${note:+ ${note}}"
    done <<< "${inner}"
  done <<< "${spans}"
}

# The command with `--ignore-scripts` placed after the last argument of every
# npm install the shell runs: in the command's own code, in a substitution, and
# in a script it hands to `sh -c` or `eval`. Prints nothing when no verb was
# found. Returns 4, printing nothing, when every install already leaves
# ignore-scripts true. With the rewrite printed, it returns 4 plus the sum of
# 1 when an install asked for its scripts and the flag now overrides it, 2 when
# an install holds a word the shell decides at run time, so nobody read
# whether the flag holds, and 4 when an install keeps only the floor because
# no place in it reads as true, or gets no flag because its verb is glued to a
# `}` nested in a substitution (` nested`, inert_nested_verb_ends) -- a
# downgrade the caller records; 0 when none applies. Prints nothing and
# returns 0, the caller's downgrade, when such a nested install is the only
# one left to rewrite, even where every other install already leaves
# ignore-scripts true. Returns 3, printing nothing, when an npm install sits where the
# rewrite cannot reach it -- a double-quoted script with an escape or a
# substitution in it, a heredoc piped into a shell -- so the caller records the
# downgrade instead of reporting the command inert; the release did not
# rewrite these either.
#
# The rewrite always holds the release's own (7d66f8c): the flag right after
# every verb, which inert_flag_offsets prints, and, for a command the release
# appended to (inert_release_appends), the flag at the end of the command. So
# deleting the flags the release did not write gives the release's rewrite:
# whatever the shell does to the words, npm receives at least what the release
# gave it, and the flags placed by reading only add to that.
#
# A raw-text rewrite used to land on an `npm i` inside a trailing comment and
# count that as done, and could not see past a quoted option value (caught in
# review); the scan view that replaced it blanked quoted scripts, so an install
# in `sh -c '...'` beside a visible one ran its lifecycle scripts with nothing
# recorded (caught in the release integration).
inert_rewrite_in_place() {
  local command="$1" lines offsets="" e note settled=false asked=false unverified=false floor=false rc=0 append=0 release_rewrote=false
  lines=$(inert_offsets_of "${command}") || rc=$?
  (( rc == 0 )) || return "${rc}"
  # Matches case and ends the verb at a blank, as the release did: with -i or SAFEDEPS_G_END, return 3 drops the compound floor, as with the awk in inert_payload_spans (v2.18.1).
  if strip_heredoc_bodies "${command}" shell-bodies \
      | LC_ALL=C judge_grep -qE "npm${SAFEDEPS_G_OPTS}[[:space:]]+(${SAFEDEPS_G_NPM_VERBS}|${SAFEDEPS_G_NPM_LINK_VERBS})([[:space:]]|\$)"; then
    return 3
  fi
  inert_release_skips "${command}" || release_rewrote=true
  while read -r e note; do
    [[ -n "${e}" ]] || continue
    # An install the rewrite cannot reach gets no flag, and the command keeps
    # the rewrite of the others. Read as nothing, it left that rewrite to
    # report the command inert, with nothing recorded.
    if [[ "${note}" == nested ]]; then
      floor=true
      continue
    fi
    if [[ "${e}" == - || "${note}" == settled ]]; then
      settled=true
      [[ "${note}" == settled && "${release_rewrote}" == true ]] || continue
    fi
    [[ "${note}" != asked ]] || asked=true
    [[ "${note}" != unverified ]] || unverified=true
    [[ "${note}" != floor ]] || floor=true
    offsets+="${e}"$'\n'
  done <<< "${lines}"
  [[ -z "${offsets}" ]] || ! inert_release_appends "${command}" || append=1
  if [[ -z "${offsets}" ]]; then
    [[ "${settled}" == true && "${floor}" != true ]] && return 4
    return 0
  fi
  offsets=$(printf '%s' "${offsets}" | LC_ALL=C sort -nu | tr '\n' ' ')
  if ! { printf '%s\n' "${offsets}"; printf '%s' "${command}"; } | LC_ALL=C awk -v append="${append}" '
    # safedeps:inert_rewrite_in_place (scripts/measure/scan-failure-census.sh keys on this line)
    NR == 1 { k = split($0, at, " "); for (j = 1; j <= k; j++) want[at[j]] = 1; next }
    { if (NR > 2) X[++n] = "\n"; m = split($0, c, ""); for (j = 1; j <= m; j++) X[++n] = c[j] }
    END {
      buf = ""; held = 0
      for (i = 1; i <= n; i++) {
        buf = buf X[i]
        if (i in want) buf = buf " --ignore-scripts"
        if (++held >= 4096) { printf "%s", buf; buf = ""; held = 0 }
      }
      # The release appended its flag to the command; one placed there already
      # is that flag.
      if (append && !(n in want)) buf = buf " --ignore-scripts"
      printf "%s", buf
    }
  '; then
    [[ -z "${SAFEDEPS_SCAN_MARK:-}" ]] || printf 'failed\n' >> "${SAFEDEPS_SCAN_MARK}"
    return 1
  fi
  rc=0
  [[ "${asked}" != true ]] || rc=$(( rc + 1 ))
  [[ "${unverified}" != true ]] || rc=$(( rc + 2 ))
  [[ "${floor}" != true ]] || rc=$(( rc + 4 ))
  (( rc == 0 )) || return $(( rc + 4 ))
}

# Whether the release (7d66f8c) left <command> as written: it did whenever the
# text `--ignore-scripts` stood in the scan view of the command or of a script
# it hands to a shell, its prefixes removed (its command_has_ignore_scripts_flag),
# whatever npm made of it. That is the recognize view of each, read once: the
# scan view of the unprefixed view of the joined view, three lexings, is what
# the release read, and each lexing after the first read a text the one before
# had changed.
inert_release_skips() {
  local texts
  texts=$(command_candidate_start_texts "$1")
  judge_grep -qE -- '(^|[[:space:]])--ignore-scripts([=[:space:]]|$)' <<< "${texts}"
}

# Whether the release (7d66f8c) appended `--ignore-scripts` to the end of
# <command> rather than inserting it after each verb: it did for a command of
# one line whose scan view holds none of `;&|()`$`, shows the verb, and has no
# comment or heredoc, when the text `--ignore-scripts` was nowhere in it (it
# rewrote nothing then). This is the release's decision kept as it was, with
# this tree's grammar, so the floor is the release's rewrite and not a guess at
# it: a flag right after the verb alone is not, and against a word the shell
# expands into `--no-ignore-scripts` after the place a reading chose, the
# release's end flag is the one that stands. One part differs, and only adds
# a flag: the release matched the name `npm` in its case and so appended
# nothing to `NPM ci`, which main (a6fd57a) had appended to; the name here
# ignores case. The verb still ends where the release ended it, at a blank or
# the end of the line: `npm ci>log` was no install to the release, so it
# appended nothing there, and the in-place flag after the verb is this tree's
# own (SAFEDEPS_G_END).
inert_release_appends() {
  local scanned code
  scanned=$(command_scan_text "$1") || return 1
  [[ "${scanned}" != *$'\n'* ]] || return 1
  ! printf '%s' "${scanned}" | judge_grep -qE '[;&|()`$]' || return 1
  ! inert_release_skips "$1" || return 1
  printf '%s' "${scanned}" \
    | LC_ALL=C judge_grep -qEi "npm${SAFEDEPS_G_OPTS}[[:space:]]+(${SAFEDEPS_G_NPM_VERBS}|${SAFEDEPS_G_NPM_LINK_VERBS})([[:space:]]|\$)" || return 1
  code=$(strip_heredoc_bodies "$1")
  [[ "${code}" == "$1" ]]
}

# The statements of a command, one per line, as
# `<before>\035<text>\035<after>\035<words>\035<raw>`. <before> and <after> are the separators
# around the statement (`start`, `;`, `&&`, `||`, `|`, `&`, `end`) and <text> is
# its quote-blanked text, so a separator inside quotes is not one. Fields are
# split on \035 rather than a tab because `read` merges adjacent tabs, and an
# empty field (a statement with no words) then shifted the next one into it. A newline
# separates like `;`. A redirection (`2>&1`, `&>`) does not split a statement:
# the stmts view writes its `&` as `_` in a reading whose shell reads one
# there. This used to decide `&>` by itself, by the byte after the `&`, and
# kept the statement whole in the dash reading too, where the `&` ends the
# command and the next one starts at the `>`.
#
# A statement also ends where the next one starts with no separator before it
# (after a reserved word, a case pattern close, `!`, a head, zsh's `{` or
# `&!`): the lexer lists those starts (the stmtcuts view), and the cut is made
# there, between two bytes, with `;` as the separator. The starts used to be
# written into the stmts view over the byte before them, and a start with no
# blank before it had no byte of its own: `if true; then>/dev/null pip
# install x; fi` kept `then` and the install in one statement, which named no
# manager.
#
# <words> is the statement split into words the way the shell splits it, read
# from the raw text: quotes delimit and are removed, a backslash escapes, and
# `"/tmp/x y"` is one word. Words are joined by \037. A word whose value the
# shell decides at run time (a `$` or backquote outside single quotes, an
# unquoted glob or leading tilde) ends in \001, which guard_literal_dir reads as
# unknown. Reading the blanked text instead turned `--prefix "/tmp/x y" pkg`
# into `--prefix pkg` and sent the gate to <cwd>/pkg (caught in review). The two
# texts line up byte for byte because command_scan_text preserves length.
#
# A fifth field, <raw>, is the statement's own text as written, quotes and all,
# with a tab read as a space and a newline (one inside quotes; any other ends
# the statement) carried as \036.
#
# <text> is a command as written, never a view of one. The words and <raw> are
# read from the stmtraw view of it, where a comment, a heredoc operator and a
# heredoc body (with the live code in one) are blank and a line continuation
# is stepped over: the statement after a body begins with the body's bytes,
# which are no words of it. This used to read the joined view of the code view
# as if it were the command, and that view kept the live code of a body: the
# statement after `cat <<E`, `$(date)`, `E` began with the word `$(date)`.
#
# When the statements cannot be read (awk failed, or no temp file), this says
# so in SAFEDEPS_SCAN_MARK and adds a line whose <before> is `?`. The lines
# before it may be a partial reading, so the caller treats the whole command as
# landing somewhere it cannot name. The extractor reads this output too, and
# the mark is what keeps a failure from reading as "no statements", which reads
# as "no install".
command_statements() {
  local raw_file scan_file
  raw_file=$(mktemp "${TMPDIR:-/tmp}/safedeps-stmt-raw.XXXXXX") \
    && scan_file=$(mktemp "${TMPDIR:-/tmp}/safedeps-stmt-scan.XXXXXX") || {
      rm -f "${raw_file:-}"
      [[ -z "${SAFEDEPS_SCAN_MARK:-}" ]] || printf 'failed\n' >> "${SAFEDEPS_SCAN_MARK}"
      printf '?\035\035\035\035\n'
      return 0
    }
  # A case pattern's `)` ends a statement as well: the arm after it starts
  # one. On the scan view an arm after the first was split out as `*) pip
  # install ...`, where the `)` no longer closes a pattern, so the install was
  # not at a statement start: no spec and no record (caught when the lexer and
  # the extractor met in the release tree).
  shell_lex "$1" stmtcuts "safedeps:command_scan_text" > "${scan_file}"
  shell_lex "$1" stmtraw "safedeps:command_scan_text" > "${raw_file}"
  if ! LC_ALL=C awk -v scan_file="${scan_file}" -v raw_file="${raw_file}" '
    # safedeps:command_statements (scripts/measure/scan-failure-census.sh and scripts/test/scan-contract.sh key on this line)
    # The string builder (sb_*): see shell_lex.
    function sb_reset(id, s) { SBS[id] = s; SBC[id] = ""; SBP[id] = ""; SBPN[id] = 0; SBCN[id] = 0 }
    function sb_add(id, s) {
      SBP[id] = SBP[id] s; if (++SBPN[id] < 64) return
      SBC[id] = SBC[id] SBP[id]; SBP[id] = ""; SBPN[id] = 0; if (++SBCN[id] < 64) return
      SBS[id] = SBS[id] SBC[id]; SBC[id] = ""; SBCN[id] = 0
    }
    function sb_get(id) { return SBS[id] SBC[id] SBP[id] }
    function slurp(f,   line, count) {
      sb_reset("slurp", ""); count = 0
      while ((getline line < f) > 0) sb_add("slurp", (count++ ? "\n" : "") line)
      close(f)
      return sb_get("slurp")
    }
    # wne: whether the words so far are not empty, which decides the
    # separator as `words == ""` did when the words were one string.
    function word_end(   piece) {
      if (has) {
        piece = (wne ? "\037" : "") sb_get("word") (dyn ? "\001" : "")
        sb_add("words", piece)
        if (piece != "") wne = 1
      }
      sb_reset("word", ""); has = 0; dyn = 0
    }
    # A byte of a word that is a separator of this record (\037 joins the
    # words, \035 the fields) is \002 here, as in the pieces view: left as
    # it was, a \037 the command wrote split one word into two for every
    # reader of the words, and a \035 moved the fields after it.
    function wb(ch) { return (ch == "\037" || ch == "\035") ? "\002" : ch }
    function words_of(from, to,   i, ch, q) {
      sb_reset("words", ""); wne = 0; sb_reset("word", ""); has = 0; dyn = 0; q = ""
      for (i = from; i <= to; i++) {
        ch = wb(r[i])
        if (ch == "\001") continue
        if (q == "") {
          if (ch == " " || ch == "\t" || ch == "\n") { word_end(); continue }
          if (ch == "\\") { if (i < to) { i++; if (r[i] != "\001") sb_add("word", wb(r[i])); has = 1 }; continue }
          if (ch == "\047") { q = "s"; has = 1; continue }
          if (ch == "\"") { q = "d"; has = 1; continue }
          if (ch == "$" || ch == "`" || ch == "*" || ch == "?" || ch == "[") dyn = 1
          if (ch == "~" && !has) dyn = 1
          sb_add("word", ch); has = 1
          continue
        }
        if (q == "s") { if (ch == "\047") q = ""; else sb_add("word", ch); continue }
        if (ch == "\\" && i < to && (r[i + 1] == "$" || r[i + 1] == "`" || r[i + 1] == "\"" || r[i + 1] == "\\")) {
          i++; sb_add("word", wb(r[i])); continue
        }
        if (ch == "\"") { q = ""; continue }
        if (ch == "$" || ch == "`") dyn = 1
        if (ch == "\n" || ch == "\t") ch = " "
        sb_add("word", ch)
      }
      word_end()
      return sb_get("words")
    }
    function raw_of(from, to,   i, ch) {
      sb_reset("raw", "")
      for (i = from; i <= to; i++) {
        ch = r[i]
        if (ch == "\001") continue
        if (ch == "\t" || ch == "\035" || ch == "\037") ch = " "
        else if (ch == "\n") ch = "\036"
        sb_add("raw", ch)
      }
      return sb_get("raw")
    }
    function emit(nx, to) {
      text = sb_get("cur"); gsub(/[\t\035]/, " ", text)
      printf "%s\035%s\035%s\035%s\035%s\n", prev, text, nx, words_of(from, to), raw_of(from, to)
      prev = nx; sb_reset("cur", "")
    }
    BEGIN {
      # The first line holds the starts with no separator before them, the
      # rest is the stmts view.
      if ((getline line < scan_file) <= 0) exit 2
      ncut = split(line, cuts, " ")
      for (k = 1; k <= ncut; k++) CUT[cuts[k] + 0] = 1
      n = split(slurp(scan_file), c, "")
      split(slurp(raw_file), r, "")
      prev = "start"; sb_reset("cur", ""); from = 1
      for (i = 1; i <= n; i++) {
        ch = c[i]
        if (i in CUT) { emit(";", i - 1); from = i }
        if (ch == ";" || ch == "\n") { emit(";", i - 1); from = i + 1; continue }
        if (ch == "&") {
          if (c[i + 1] == "&") { emit("&&", i - 1); i++; from = i + 1; continue }
          emit("&", i - 1); from = i + 1; continue
        }
        if (ch == "|") {
          if (c[i + 1] == "|") { emit("||", i - 1); i++; from = i + 1; continue }
          to = i - 1
          if (c[i + 1] == "&") i++
          emit("|", to); from = i + 1; continue
        }
        sb_add("cur", ch)
      }
      emit("end", n)
    }'; then
    [[ -z "${SAFEDEPS_SCAN_MARK:-}" ]] || printf 'failed\n' >> "${SAFEDEPS_SCAN_MARK}"
    printf '?\035\035\035\035\n'
  fi
  rm -f "${raw_file}" "${scan_file}"
}

# The directory a literal path names from <dir>, or `?` when the text cannot
# say: a variable, a substitution, a tilde or a glob is resolved by the shell at
# run time, and a relative path from an unknown directory is unknown too.
guard_literal_dir() {
  local dir="$1" path="$2"
  [[ -n "${path}" && "${path}" != -* ]] || { printf '?'; return 0; }
  case "${path}" in
    *$'\001'*) printf '?'; return 0 ;;
    *'$'*|*'`'*|'~'*|*'*'*|*'?'*|*'['*) printf '?'; return 0 ;;
    /*) printf '%s' "${path}"; return 0 ;;
  esac
  [[ "${dir}" != "?" ]] || { printf '?'; return 0; }
  printf '%s/%s' "${dir%/}" "${path}"
}

# The last value an .npmrc gives <key>, prefixed with `=` so that a key set to
# nothing still reads as set. Nothing at all when the file does not set it.
#
# Read the way npm 11.19.0 read it, measured against a real install
# (safedeps/effect-gate-blind-to-lockless-npm-installs): keys are
# case-sensitive (`GLOBAL=true` did nothing), the last line wins, a key with no
# `=` is set, an unquoted value ends at `;` or `#`, and one pair of quotes is
# removed. A key under a `[section]` header is not a top-level key.
#
# `?` when the file is there and could not be read: awk failed, which is also
# written to SAFEDEPS_SCAN_MARK. An empty answer would read as "not set", and
# that is the answer that lets an install off the record count as recorded.
guard_npmrc_value() {
  local file="$1" key="$2"
  [[ -f "${file}" && -r "${file}" ]] || return 0
  awk -v key="${key}" -v q="'" '
    # safedeps:guard_npmrc_value (scripts/measure/scan-failure-census.sh keys on this line)
    /^[[:space:]]*\[/ { exit }
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (line == "" || line ~ /^[;#]/) next
      eq = index(line, "=")
      if (eq == 0) { k = line; v = "true" } else { k = substr(line, 1, eq - 1); v = substr(line, eq + 1) }
      sub(/[[:space:]]+$/, "", k)
      if (k != key) next
      sub(/^[[:space:]]+/, "", v)
      first = substr(v, 1, 1)
      if ((first == "\"" || first == q) && index(substr(v, 2), first) > 0) {
        v = substr(v, 2, index(substr(v, 2), first) - 1)
      } else {
        sub(/[;#].*$/, "", v)
        sub(/[[:space:]]+$/, "", v)
      }
      found = 1
      last = v
    }
    END { if (found) printf "=%s", last }
  ' "${file}" 2>/dev/null || {
    [[ -z "${SAFEDEPS_SCAN_MARK:-}" ]] || printf 'failed\n' >> "${SAFEDEPS_SCAN_MARK}"
    printf '?'
  }
}

# Why an npm install into <dir> is not recorded where the effect gate reads it,
# because of an .npmrc; nothing when the project and user .npmrc leave it alone.
#
# `global` and `location` decide it, each key on its own, and the project file
# outranks the user file. Measured with npm 11.19.0 (the battery in
# scripts/test/lockless-forms.sh pins the cases it names):
#
#   - `global=false` and `global=null` install in the project and record it.
#     Every other value sent the package to the global prefix (`true`, `1`,
#     `yes`, `off`, nothing) or put it in node_modules with no record at all
#     (`0`). A `--global=false` or `--no-global` on the command overrides the
#     file; `--location=project` does not.
#   - `location=user` and `location=project` install in the project. `global`
#     went to the global prefix. And no flag on the command undoes it:
#     `--global=false` still went global, and `--location=project` put the
#     package in node_modules with no record at all.
#
# So only the values measured to keep an install on record count as leaving it
# alone. Anything else is read as not recorded, which costs an UNGATED line
# where npm would have been harmless; the other direction costs a silent pass.
guard_npmrc_unrecorded() {
  local dir="$1" user_rc="$2" cli_global_off="$3"
  local project_rc key value source
  # <dir> is where npm installs, so its .npmrc is the project's: npm ignores a
  # workspace member's own .npmrc and reads the root's.
  project_rc="${dir}/.npmrc"
  local undecided=false
  for key in location global; do
    source="${project_rc}"
    value=$(guard_npmrc_value "${project_rc}" "${key}")
    if [[ "${value}" == "?" ]]; then
      printf '%s could not be read, so safedeps cannot tell whether npm records this install where the effect gate reads it' "${source}"
      return 0
    fi
    if [[ -z "${value}" ]]; then
      if [[ "${user_rc}" == "?" ]]; then
        undecided=true
        continue
      fi
      source="${user_rc}"
      value=$(guard_npmrc_value "${user_rc}" "${key}")
      if [[ "${value}" == "?" ]]; then
        printf '%s could not be read, so safedeps cannot tell whether npm records this install where the effect gate reads it' "${source}"
        return 0
      fi
    fi
    [[ -n "${value}" ]] || continue
    value="${value#=}"
    case "${key}:${value}" in
      location:user|location:project|global:false|global:null) continue ;;
    esac
    if [[ "${key}" == global && "${cli_global_off}" == true ]]; then
      continue
    fi
    printf '%s sets %s=%s, so npm does not record this install where the effect gate reads it' \
      "${source}" "${key}" "${value}"
    return 0
  done
  if [[ "${undecided}" == true ]]; then
    printf 'the user .npmrc is named by a value the shell decides at run time, so safedeps cannot tell whether npm records this install where the effect gate reads it'
  fi
  return 0
}

# Where each install statement in the command lands, one line per statement of
# the command (command_statements), as
# `<kind>\035<dir>\035<why>\035<fetch>\035<rec>\037<words>`.
# <kind> is `npm` for an npm CLI install that is not a runner,
# `npm-unrecorded` for one no lockfile of the project records whatever lands
# there (an .npmrc keeps it out of both lockfiles, or `npm link <pkg>` puts the
# package in the global tree and only the link in the project), `other` for
# every other install, `-` for a statement that is not an install (a `cd`, an
# `echo`), whose <dir> and <why> are empty, and `?` when the statements could
# not be read at all. <dir> is an absolute path,
# `global`, or `?` when the text does not say. <why> says why npm could not be
# asked or answered `global`, or names the .npmrc file and setting that keep
# the install off the record; it is empty otherwise.
# <fetch> is an npm install's fetch facts, one line of JSON asked of npm with
# the same words as <dir> (lib/npm/ask.sh): which registry it fetches from. It
# is empty where npm was not asked, and the reason is then <why>.
# <rec> is the statement as the recognizers read it and <words> its words
# after quote removal with its prefixes left out, both from the lexer's pieces
# view of the command (its <rec> and <uwords>): what the spec extractor reads.
#
# Every statement is listed, installs or not, because this is also the list of
# statements the spec extractor reads (guard_extract_specs). The extractor
# decides on its own which of them install what; what it takes from here is the
# statement and where it lands, read once.
#
# The effect gate reads one directory, chosen here before the command runs. An
# install that lands anywhere else is not read, whatever the gate says about the
# directory it did read. Four things move an install, and each was measured with
# a real npm against a local registry (safedeps/effect-gate-blind-to-lockless-npm-installs):
#
#   - A relocation flag on the install itself: `--prefix`, pnpm's `--dir`,
#     yarn's and bun's `--cwd`, `--install-dir`, and `-C` where the manager
#     documents it as one of those (npm: `--prefix`; pnpm: `--dir`). pip reads
#     `-C` as `--config-settings`, so `-C` is honoured for npm and pnpm only.
#     `npm -C sub install x` wrote sub/package-lock.json while the gate read the
#     cwd lockfile and confirmed it clean.
#   - A `cd` or `pushd` earlier in the command. `cd sub && npm install x` and
#     `cd sub; npm install x` both wrote sub/package-lock.json. A literal path
#     to a directory that exists now is followed. Anything the shell decides at
#     run time is `?`: a variable or substitution, a directory that does not
#     exist yet, `popd`, a `cd` inside a group or subshell, and a `cd` beside a
#     pipe or `&`, which run it in a subshell of its own.
#     A `cd` that may not run at all is followed only as far as it provably
#     ran. One after `&&` or `||`, or inside an if, while, until, for or case
#     body, holds along the `&&` chain that follows it, where every statement
#     runs only if the `cd` succeeded; past that chain the directory is the one
#     before it. `false && cd sub; npm install x` installs in the cwd, and
#     following that `cd` sent the gate to sub (validator round 3, G1). `cd sub
#     || exit` is unconditional and is followed.
#   - Global installs, which land in npm's global prefix and write no lockfile
#     at all. Whether an install is global is npm's answer too: `npm root`
#     names the global tree for it (lib/npm/ask.sh). A list of spellings
#     (`-g`, `--global`, `--location global`) used to decide it here, and npm
#     reads more than any list: `-gf`, `-fg`, `-g=true`, `--no-global=false` and
#     the abbreviation `--locat=global` are all global to npm's option parser
#     (nopt), and each read as a project install. The same settings given as
#     `npm_config_global` / `npm_config_location`, prefixed or exported, reach
#     the ask the way they reach npm.
#   - `npm_config_prefix` in the environment does NOT move a project install:
#     measured, it landed in the cwd project and the gate rolled it back.
#   - The same two settings in the project's or the user's .npmrc, which the
#     command does not show. guard_npmrc_unrecorded reads both files; an install
#     they keep off the record is `?` with the reason in <why>. The global and
#     builtin npmrc, and a file named only at run time, are outside what this
#     reads; ARCHITECTURE.md states that boundary.
#
# None of this decides whether the install was read. It decides where the
# effect gate looks; the PostToolUse hook then looks for this command's install
# trace there, and an install that left none is recorded UNGATED. A wrong
# answer here costs a record, never a silent pass.
#
# This reads one reading of the command (SAFEDEPS_READING): the guard's
# driver runs it once per reading and joins the lists. The readings used to be
# joined into one text and split again under the first reading's rules, so a
# context the first reading left open swallowed the reading appended after it,
# and an install only the zsh reading exposes yielded no statement, no spec
# and no record (caught when the lexer and the extractor met in the release
# tree).
resolve_install_targets() {
  resolve_reading_targets "$1" "$2"
  return 0
}

# Where npm says an install lands (lib/npm/ask.sh), asked once per run for each
# question. Every reading resolves the statements it reads, and where the
# readings agree they ask the same question; each ask costs two npm processes
# and up to its deadline. The answer is kept in the run's private memo
# directory under the whole question -- the directory, the environment words
# and the arguments, everything but the deadline -- and a
# hit also requires the stored question to equal this one byte for byte.
guard_npm_install_target() {
  local question memo="" answer tmp
  question=$(printf '%s\037' "$1" "${@:3}")
  if [[ -n "${SAFEDEPS_LEX_CACHE:-}" && -d "${SAFEDEPS_LEX_CACHE}" ]]; then
    memo="${SAFEDEPS_LEX_CACHE}/ask.$(printf '%s' "${question}" | cksum | tr ' ' '.')"
    if [[ -f "${memo}.out" && -f "${memo}.in" ]] && [[ "$(cat "${memo}.in"; printf 'X')" == "${question}X" ]]; then
      cat "${memo}.out"
      return 0
    fi
  fi
  answer=$(safedeps_npm_install_target "$@")
  printf '%s\n' "${answer}"
  if [[ -n "${memo}" ]] && tmp=$(mktemp "${memo}.XXXXXX" 2>/dev/null); then
    { printf '%s\n' "${answer}" > "${tmp}" && mv -f "${tmp}" "${memo}.out" &&
      printf '%s' "${question}" > "${tmp}" && mv -f "${tmp}" "${memo}.in"; } 2>/dev/null || rm -f "${tmp}"
  fi
}

# Whether assignment word <word> holds the text the shell assigns: nothing the
# shell decides at run time (the lexer's mark), and no tilde, which the shell
# expands in an assignment's value at its start and after a colon.
guard_assignment_literal() {
  local value="${1#*=}"
  [[ "$1" != *$'\001'* && "${value}" != '~'* && "${value}" != *':~'* ]]
}

# Whether <name> is exported in the environment this hook runs with, which is
# the one the agent's shell inherits too.
guard_name_inherited() {
  local flags
  flags=$(declare -p "$1" 2>/dev/null) || return 1
  flags="${flags#declare -}"
  [[ "${flags%% *}" == *x* ]]
}

# Carries assignment word <word> to every later npm install the caller
# (resolve_reading_targets) asks npm about, in its npm_exports. The last value
# a name was given stands. Fails, carrying nothing, when the value is not
# literal or the command has a group or a subshell, where the assignment may
# not reach the install.
guard_carry_setting() {
  local entry
  local -a kept=()
  [[ "${grouped}" != true ]] && guard_assignment_literal "$1" || return 1
  for entry in "${npm_exports[@]+"${npm_exports[@]}"}"; do
    [[ "${entry%%=*}" == "${1%%=*}" ]] || kept+=("${entry}")
  done
  npm_exports=("${kept[@]+"${kept[@]}"}" "$1")
  npm_unsets="${npm_unsets// ${1%%=*} / }"
}

# Carries `unset <name>` to every later npm install the caller asks npm about,
# as env(1)'s `-u <name>` (npm_unsets), and forgets what the command assigned
# or exported to it before. Fails, carrying nothing, where guard_carry_setting
# does: a group or a subshell, where the unset may not reach the install.
guard_carry_unset() {
  local name="$1" entry
  local -a kept=()
  [[ "${grouped}" != true ]] || return 1
  for entry in "${npm_exports[@]+"${npm_exports[@]}"}"; do
    [[ "${entry%%=*}" == "${name}" ]] || kept+=("${entry}")
  done
  npm_exports=("${kept[@]+"${kept[@]}"}")
  kept=()
  for entry in "${assigned_words[@]+"${assigned_words[@]}"}"; do
    [[ "${entry%%=*}" == "${name}" ]] || kept+=("${entry}")
  done
  assigned_words=("${kept[@]+"${kept[@]}"}")
  exported_names="${exported_names// ${name} / }"
  [[ "${npm_unsets}" == *" ${name} "* ]] || npm_unsets+="${name} "
}

# Whether npm word <word>, in a statement run in <dir>, is this hook's own npm:
# the one `command -v npm` finds here, by its directory as a physical path.
guard_npm_word_is_hooks() {
  local word="$1" dir="$2" hook here there
  hook=$(command -v npm 2>/dev/null) || return 1
  [[ "${hook}" == /* ]] || return 1
  [[ "${word}" != "${hook}" ]] || return 0
  here=$(cd "${dir}" 2>/dev/null && cd "${word%/*}/" 2>/dev/null && pwd -P) || return 1
  there=$(cd "${hook%/*}/" 2>/dev/null && pwd -P) || return 1
  [[ "${here}" == "${there}" ]]
}

# One assignment the caller's shell makes outside a command's own prefix:
# <word>, exported by the statement when <exporting> is true, with a value the
# statement keeps as written when <literal> is true. It sets the caller's
# npm_exports, exports_unknown, exported_names, assigned_words, env_changer
# and env_setting.
#
# Every name counts, whatever it names, because npm reads more of its
# environment than npm_config_*: `export HOME=<dir>` sends npm to
# <dir>/.npmrc, and so does the same assignment in front of npm, which the
# statement's own reading below carries to the ask. The export branch carried
# only npm_config_*, so `export HOME=<dir>; npm install x` was asked about
# under the hook's HOME and fetched from <dir>/.npmrc's registry unseen.
#
# An exported value the gate cannot reproduce makes every later npm install's
# directory unknown (exports_unknown). An assignment the statement does not
# export reaches npm when the name is already exported, which the gate cannot
# always tell. It is carried all the same: if it does not reach npm, npm runs
# with the hook's environment, and the PostToolUse hook asks npm again with
# exactly that, so one of the two answers is npm's either way. One whose value
# is not literal is unknown where the name is exported here, and an
# npm_config_* assignment is unknown as before (env_setting).
guard_shell_assignment() {
  local word="$1" exporting="$2" literal="$3" name="${1%%=*}" i
  # A name that chooses npm's code is never carried, whatever its value: the
  # ask runs this hook's own npm (code_changer).
  if safedeps_npm_code_name "${name}"; then
    [[ "${word}" != *=* ]] || code_changer="${name}="
    return 0
  fi
  [[ "${literal}" == true ]] || word="${word%$'\001'}"$'\001'
  if [[ "${word}" != *=* ]]; then
    [[ "${exporting}" == true ]] || return 0
    exported_names+="${name} "
    # A name exported bare carries the value an assignment earlier in the
    # command gave it: `HOME=<dir>; export HOME`.
    word=""
    for (( i = ${#assigned_words[@]} - 1; i >= 0; i-- )); do
      [[ "${assigned_words[i]%%=*}" != "${name}" ]] || { word="${assigned_words[i]}"; break; }
    done
    [[ -n "${word}" ]] || return 0
  else
    assigned_words+=("${word}")
    [[ "${exporting}" != true ]] || exported_names+="${name} "
  fi
  if [[ "${exported_names}" == *" ${name} "* ]]; then
    guard_carry_setting "${word}" || exports_unknown="${word%$'\001'}"
    return 0
  fi
  if ! guard_carry_setting "${word}" && guard_name_inherited "${name}"; then
    env_changer="${name}="; env_setting="${env_changer}"
  fi
  if [[ "$(printf '%s' "${name}" | tr '[:upper:]' '[:lower:]')" == npm_config_* ]]; then
    env_changer="${name}="; env_setting="${env_changer}"
  fi
  return 0
}

# The statements and where each lands (see resolve_install_targets). <text> is
# the command as written: every view this reads is a view of it, lexed once.
resolve_reading_targets() {
  local text="$1" cwd="$2"
  local before stmt after words raw head target want kind manager tok value in_env skip
  local user_rc cli_global_off why run_dir answer local_prefix npm_word npm_unknown i fetch cause
  local dir="${cwd}" grouped=false env_userconfig=false exports_unknown="" exported_names=" "
  local npm_until="" here cond_dir="" depth=0 conditional env_changer="" env_setting="" statements pieces piece_at pw puw prec n=0 m k role
  local opts exporting literal ignore_env unset_names rc_home
  local code_changer="" stmt_code changer npm_unsets=" "
  local -a toks=() npm_env=() npm_args=() npm_exports=() stmt_words=() stmt_uwords=() stmt_recs=() stmt_ans=() mw=() assigned_words=()
  local -a env_opts=() env_inherit=() env_after=()

  command_scan_text "${text}" | judge_grep -q '[(){}`]' && grouped=true
  command_scan_text "${text}" | judge_grep -qEi 'npm_config_userconfig=' && env_userconfig=true

  # Each statement's words as the shell splits them (the lexer's pieces view),
  # for the manager's grammar below, and its text as the recognizers read it:
  # piece N is statement N. Both views are lexings of the command itself. The
  # pieces used to be the statements' own texts, one per line, lexed again
  # from nothing, and the statements those of the joined view: the statement
  # after a heredoc body began with the live code of the body (`$(date)`),
  # which read as its command (verdict buri-20261005-145152).
  statements=$(command_statements "${text}")
  pieces=$(shell_lex "${text}" pieces "safedeps:extract_pieces") || pieces=""
  while IFS=$'\037' read -r piece_at _ pw puw prec; do
    if [[ "${piece_at}" == "!" ]]; then guard_mark_reading_failed; continue; fi
    [[ "${piece_at}" =~ ^[0-9]+$ ]] || continue
    stmt_words[piece_at]="${pw}"
    stmt_uwords[piece_at]="${puw}"
    stmt_recs[piece_at]="${prec}"
  done <<< "${pieces}"
  # Whether each statement is an install, asked of every statement at once
  # and read where the loop asks (recognized_dependency_install_each):
  # statement N is text N-1.
  SAFEDEPS_RDI_IN=()
  for k in ${stmt_recs[@]+"${!stmt_recs[@]}"}; do
    while (( ${#SAFEDEPS_RDI_IN[@]} < k )); do SAFEDEPS_RDI_IN+=("${stmt_recs[${#SAFEDEPS_RDI_IN[@]} + 1]:-}"); done
  done
  recognized_dependency_install_each
  stmt_ans=("${SAFEDEPS_RDI_ANS[@]+"${SAFEDEPS_RDI_ANS[@]}"}")

  while IFS=$'\035' read -r before stmt after words raw; do
    n=$(( n + 1 ))
    if [[ "${before}" == "?" ]]; then
      printf '?\035?\035the command could not be split into statements (awk failed), so safedeps cannot tell where its installs land\035\035\n'
      continue
    fi
    # Every field a statement prints starts empty here. `fetch` was reset only
    # after the early `break`s, so a statement that left before it (a `printf`
    # ahead of `npm install`) printed an unset variable, which bash 5 under
    # `set -u` aborts on: every such command was denied fail-closed. bash 3.2
    # read it as empty, or as the statement before's.
    kind=- target="" why="" fetch=""
    # The directory a conditional `cd` entered holds only while every
    # separator since it is `&&`.
    [[ "${before}" == "&&" ]] || cond_dir=""
    here="${cond_dir:-${dir}}"
    # One pass that `break` leaves early: every statement prints exactly one
    # line below, whichever test ends it.
    while :; do
      [[ -n "${words}" ]] || break
      IFS=$'\037' read -ra toks <<< "${words}"
      [[ ${#toks[@]} -gt 0 ]] || break

      # A statement may open with a group character glued to its command
      # (`(cd x`). A reserved word before a command is mostly a statement of
      # its own here, since the stmts view this splits on starts a statement
      # at the command; either way, a word that opens a compound command
      # counts toward the depth a `cd` is conditional at.
      while [[ ${#toks[@]} -gt 0 ]]; do
        head="${toks[0]}"
        head="${head#"${head%%[!({!]*}"}"
        case "${head}" in
          if|while|until) depth=$(( depth + 1 )); toks=("${toks[@]:1}") ;;
          ''|then|do|else|elif|time) toks=("${toks[@]:1}") ;;
          *) toks[0]="${head}"; break ;;
        esac
      done
      [[ ${#toks[@]} -gt 0 ]] || break
      case "${toks[0]}" in
        for|select|case) depth=$(( depth + 1 )) ;;
        fi|done|esac) (( depth == 0 )) || depth=$(( depth - 1 )) ;;
      esac

      case "${toks[0]}" in
        cd|pushd|popd)
          conditional=false
          if [[ "${before}" == "&&" || "${before}" == "||" ]] || (( depth > 0 )); then
            conditional=true
          fi
          if [[ "${grouped}" == true || "${toks[0]}" == popd \
                || "${before}" == "|" || "${before}" == "&" || "${after}" == "|" || "${after}" == "&" ]]; then
            value="?"
          else
            value=""
            for tok in "${toks[@]:1}"; do
              case "${tok}" in -L|-P|-e|-@|-n) continue ;; esac
              value="${tok}"
              break
            done
            value=$(guard_literal_dir "${here}" "${value}")
            [[ "${value}" == "?" || -d "${value}" ]] || value="?"
          fi
          if [[ "${conditional}" == false ]]; then
            dir="${value}"
            cond_dir=""
          elif [[ "${before}" == "||" ]]; then
            # `a || cd sub && npm install x` runs npm without the cd when `a`
            # succeeds, so not even the chain after it is known to be in sub.
            cond_dir=""
          else
            cond_dir="${value}"
          fi
          break
          ;;
        export|declare|typeset|local|readonly)
          # What a statement like this exports or assigns reaches every later
          # npm, so the ask carries it too (guard_shell_assignment). Options
          # come first. One that unexports (`export -n`, `declare +x`) or
          # changes the value the shell stores (`declare -xi`, `-l`, `-u`)
          # is a setting the gate reads but does not reproduce.
          opts=""
          for (( i = 1; i < ${#toks[@]}; i++ )); do
            case "${toks[i]}" in
              --) i=$(( i + 1 )); break ;;
              [-+]?*) opts+="${toks[i]%$'\001'}" ;;
              *) break ;;
            esac
          done
          exporting=false
          literal=true
          [[ "${toks[0]}" != export ]] || exporting=true
          case "${toks[0]}:${opts}" in
            export:|export:-p|*:-x|*:-xr|*:-rx|*:-x-r|*:-r-x) exporting=true ;;
            export:*|*:*+*|*:*x*)
              env_changer="${toks[0]} ${opts}"; env_setting="${env_changer}"
              break
              ;;
            *:|*:-r|*:-g|*:-rg|*:-gr|*:-r-g|*:-g-r) ;;
            *) literal=false ;;
          esac
          for (( ; i < ${#toks[@]}; i++ )); do
            tok="${toks[i]}"
            # `export PATH+=:<dir>`: a code name is the ask's never to carry.
            if [[ "${tok}" =~ ^([A-Za-z_][A-Za-z0-9_]*)\+= ]] && safedeps_npm_code_name "${BASH_REMATCH[1]}"; then
              code_changer="${BASH_REMATCH[1]}+="
              continue
            fi
            if [[ ! "${tok}" =~ ^[A-Za-z_][A-Za-z0-9_]*(=|$) || ( "${tok}" != *=* && "${tok}" == *$'\001' ) ]]; then
              # A name the shell decides at run time, an append (`+=`), an
              # array element: the value the install sees is not in the text.
              if [[ "${exporting}" == true ]]; then
                exports_unknown="${tok%$'\001'}"
              else
                env_changer="${toks[0]} ${tok%$'\001'}"; env_setting="${env_changer}"
              fi
              continue
            fi
            guard_shell_assignment "${tok}" "${exporting}" "${literal}"
          done
          break
          ;;
        # `unset NAME` reaches every later npm, so the ask carries it as `-u
        # NAME` for every name it would carry an assignment of. An unset of a
        # name that chooses npm's code is code the command chooses, like
        # setting one (code_changer). `-f` unsets functions, which npm does not
        # read. A name the shell decides at run time is unknown, as an export
        # of one is.
        unset)
          opts=""
          for (( i = 1; i < ${#toks[@]}; i++ )); do
            case "${toks[i]}" in
              --) i=$(( i + 1 )); break ;;
              -?*) opts+="${toks[i]%$'\001'}" ;;
              *) break ;;
            esac
          done
          [[ "${opts}" != *f* ]] || break
          for (( ; i < ${#toks[@]}; i++ )); do
            tok="${toks[i]}"
            if [[ ! "${tok}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
              exports_unknown="unset ${tok%$'\001'}"
            elif safedeps_npm_code_name "${tok}"; then
              code_changer="unset ${tok}"
            else
              guard_carry_unset "${tok}" || exports_unknown="unset ${tok}"
            fi
          done
          break
          ;;
        # Which registry npm fetches from is asked with the environment this
        # gate can see: the statement's own words and the exports above. A
        # statement that changes the environment where the text does not show
        # it makes that answer a guess, and a guess here has no trace to catch
        # it the way a wrong directory does: `source env.sh; npm install x`
        # with npm_config_registry in env.sh would get an answer that names
        # the registry the hook sees, not the one npm used. So every later npm
        # install's registry is unknown, which costs a skipped rebuild, never a
        # rollback (lib/npm/ask.sh, the fetch facts).
        #
        # Two kinds of statement do this, and the record of withheld bytes
        # tells them apart (env_setting below): code this gate does not read
        # (`source`, `.`, `eval`), and a setting it reads but cannot reproduce
        # (`set -a`, `declare -x`, an npm_config_* assignment). Code whose own
        # text names an npm setting is the second kind: `eval "export
        # npm_config_registry=..."`, or `.` of a here-string or a process
        # substitution that says it. The setting is in the command, so the
        # reason a record would protect nothing (the code came from somewhere
        # this gate does not read) does not hold. The text is read with quotes
        # and backslashes dropped, which can only find more.
        source|.|eval)
          env_changer="${toks[0]}"
          value="${stmt} ${toks[*]}"
          value="${value//[\"\'\\]/}"
          if [[ "${value}" =~ [Nn][Pp][Mm]_[Cc][Oo][Nn][Ff][Ii][Gg]_[A-Za-z0-9_]* ]]; then
            env_setting="${toks[0]} ${BASH_REMATCH[0]}"
          fi
          break
          ;;
        set)
          for tok in "${toks[@]:1}"; do
            case "${tok}" in
              -*a*|allexport)
                env_changer="${toks[0]} ${tok}"; env_setting="${env_changer}"; break ;;
            esac
          done
          break
          ;;
      esac
      # A statement of assignments alone sets shell variables, which reach
      # npm when the name is exported (guard_shell_assignment).
      # An append (`PATH+=:<dir>`) keeps a value the text does not show.
      if [[ "${toks[0]}" =~ ^[A-Za-z_][A-Za-z0-9_]*\+?= ]]; then
        value=true
        for tok in "${toks[@]}"; do
          [[ "${tok}" =~ ^[A-Za-z_][A-Za-z0-9_]*\+?= ]] || { value=false; break; }
        done
        if [[ "${value}" == true ]]; then
          for tok in "${toks[@]}"; do
            if [[ "${tok}" =~ ^([A-Za-z_][A-Za-z0-9_]*)\+=(.*)$ ]]; then
              tok="${BASH_REMATCH[1]}=${BASH_REMATCH[2]%$'\001'}"$'\001'
            fi
            guard_shell_assignment "${tok}" false true
          done
          break
        fi
      fi

      # The statement as the recognizers read it, its prefixes removed:
      # `npm_config_save=false npm install x` is an npm install.
      case "${stmt_ans[n - 1]:-2}" in
        0) ;;
        1) break ;;
        *) recognized_dependency_install "${stmt_recs[n]:-}" || break ;;
      esac

      # The npm word and its arguments. The words before npm go to env(1) in
      # front of npm when npm is asked below, and the words after it are npm's
      # arguments, unchanged. env(1) reads its options before any assignment,
      # so they go first, and what the shell exports, or assigns in front of
      # `env`, is passed only where `-i` and `-u` leave it. The npm asked is
      # this hook's own, never the npm word, and a word that chooses npm's code
      # is not passed (stmt_code, code_changer).
      npm_env=()
      env_opts=()
      env_inherit=("${npm_exports[@]+"${npm_exports[@]}"}")
      env_after=()
      ignore_env=false
      unset_names=" "
      npm_args=()
      npm_word=""
      stmt_code=""
      npm_unknown="${exports_unknown}"
      in_env=false
      skip=false
      want=""
      for (( i = 0; i < ${#toks[@]}; i++ )); do
        tok="${toks[i]}"
        if [[ -n "${npm_word}" ]]; then
          npm_args+=("${tok}")
          [[ "${tok}" != *$'\001' ]] || npm_unknown="${tok%$'\001'}"
          continue
        fi
        if [[ "${skip}" == true ]]; then
          skip=false
          if [[ "${want}" == u ]]; then
            env_opts+=(-u "${tok}"); unset_names+="${tok} "
            ! safedeps_npm_code_name "${tok}" || stmt_code="env -u ${tok}"
          fi
          want=""
          continue
        fi
        # An assignment to a name that chooses npm's code is not carried, whatever
        # its value: the ask runs this hook's own npm (code_changer).
        if [[ "${tok}" =~ ^([A-Za-z_][A-Za-z0-9_]*)\+?= ]] && safedeps_npm_code_name "${BASH_REMATCH[1]}"; then
          stmt_code="${BASH_REMATCH[1]}="
          continue
        fi
        [[ "${tok}" != *$'\001' ]] || { npm_unknown="${tok%$'\001'}"; continue; }
        # Names ignore case, as the recognizers read them (safedeps_manager_name).
        if safedeps_manager_name "${tok}" npm; then
          npm_word="${tok}"
          [[ "${tok}" != */* ]] || guard_npm_word_is_hooks "${tok}" "${here}" || stmt_code="${tok}"
          continue
        fi
        if [[ "${tok}" != */* ]] && safedeps_manager_name "${tok}" env; then in_env=true; continue; fi
        [[ "${tok}" != exec ]] || continue
        if [[ "${tok}" != */* ]] && safedeps_manager_name "${tok}" command; then continue; fi
        if [[ "${in_env}" == true ]]; then
          case "${tok}" in
            -C|--chdir) skip=true; continue ;;
            --chdir=*) continue ;;
            -u|--unset) skip=true; want=u; continue ;;
            --unset=*)
              env_opts+=(-u "${tok#*=}"); unset_names+="${tok#*=} "
              ! safedeps_npm_code_name "${tok#*=}" || stmt_code="env ${tok}"
              continue
              ;;
            # Without its environment, env finds npm on a PATH of its own.
            -i|--ignore-environment) env_opts+=(-i); ignore_env=true; stmt_code="env ${tok}"; continue ;;
            -*) npm_unknown="env ${tok}"; continue ;;
          esac
        fi
        if [[ "${tok}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
          # A tilde in the value is the shell's to expand, and the ask would
          # hand npm the tilde.
          guard_assignment_literal "${tok}" || { npm_unknown="${tok}"; continue; }
          if [[ "${in_env}" == true ]]; then env_after+=("${tok}"); else env_inherit+=("${tok}"); fi
          continue
        fi
        npm_unknown="${tok}"
      done
      npm_env=()
      if [[ "${ignore_env}" != true ]]; then
        for tok in ${npm_unsets}; do npm_env+=(-u "${tok}"); done
      fi
      npm_env+=("${env_opts[@]+"${env_opts[@]}"}")
      if [[ "${ignore_env}" != true ]]; then
        for tok in "${env_inherit[@]+"${env_inherit[@]}"}"; do
          [[ "${unset_names}" == *" ${tok%%=*} "* ]] || npm_env+=("${tok}")
        done
      fi
      npm_env+=("${env_after[@]+"${env_after[@]}"}")
      # What the statement's command is, and the directories its words name,
      # are the manager's grammar (safedeps_manager_read): `npm --prefix x
      # install` is an install, which the regexes read as `npm x`, and only
      # an option the manager reads as a directory moves the install: pnpm's
      # `-C` is one, pip's is not.
      set -f
      # shellcheck disable=SC2206
      pw="${stmt_words[n]:-}"
      mw=( ${pw//[(){\}]/ } )
      set +f
      kind=other
      run_dir="${here}"
      target="${here}"
      if [[ ${#mw[@]} -gt 0 ]]; then
        safedeps_manager_read "${mw[@]}" || guard_mark_reading_failed
        case "${SAFEDEPS_G_M_FAMILY}:${SAFEDEPS_G_M_KIND}" in
          npm:install|npm:link) kind=npm ;;
        esac
        m=-1
        for (( k = 0; k < ${#mw[@]}; k++ )); do
          role="${SAFEDEPS_G_M_ROLE[k]}"
          [[ "${role}" != m ]] || m=${k}
          [[ "${role}" == d ]] || continue
          # The word as the manager reads it: an empty word is the lexer's
          # blank mark alone, which names no directory (`--dir ""`).
          guard_word_as_read "" "${SAFEDEPS_G_M_TEXT[k]:-${mw[k]}}"
          value="${GUARD_WORD}"
          [[ "${value}" != $'\002' ]] || value=""
          value="${value//$'\002'/ }"
          # env's directory, before the manager, is where the command runs.
          (( m >= 0 )) || run_dir=$(guard_literal_dir "${run_dir}" "${value}")
          target=$(guard_literal_dir "${target}" "${value}")
        done
      fi
      why=""
      fetch=""

      [[ "${kind}" == npm ]] || break
      # `npm link <pkg>` installs a package the global tree lacks into npm's
      # global prefix from the registry (lib/commands/link.js linkInstall),
      # whatever the flags say: with `--global` npm refuses to run it at all.
      if [[ "${SAFEDEPS_G_M_KIND}" == link ]]; then
        target=global
        kind=npm-unrecorded
        why="npm link installs a package the global tree does not have into npm's global prefix, where no lockfile records it"
        break
      fi
      # Where an npm install lands is npm's to say, so npm is asked
      # (lib/npm/ask.sh). Every copy of npm's rules in this file disagreed with
      # npm somewhere, and each disagreement was a silent pass: a `cd` into a
      # directory without a package.json, then a workspace member reached
      # through a symlink, where npm installs in the member and the copy
      # climbed to the root. Whether it is global is part of that answer, so
      # no spelling of `--global` is read here.
      # The words before npm go to env(1) in front of this hook's npm, and
      # the words after it are npm's arguments, unchanged.
      if [[ -z "${npm_word}" ]]; then
        target="?"
        why="safedeps could not find the npm word in this install statement, so it cannot ask npm where the install lands"
        break
      elif [[ -n "${npm_unknown}" ]]; then
        target="?"
        why="this npm install depends on ${npm_unknown}, which the shell decides at run time or this gate does not reproduce, so safedeps cannot ask npm where it lands"
        break
      elif [[ "${run_dir}" == "?" ]]; then
        target="?"
        break
      fi
      [[ -n "${npm_until}" ]] || npm_until=$(( SECONDS + SAFEDEPS_NPM_ASK_PRE_SECONDS ))
      answer=$(guard_npm_install_target "${run_dir}" "${npm_until}" \
        "${npm_env[@]+"${npm_env[@]}"}" -- "${npm_args[@]+"${npm_args[@]}"}")
      # The second line is the install's fetch facts (lib/npm/ask.sh), asked
      # in the same breath: which registry npm fetches this install from.
      if [[ "${answer}" == *$'\n'* ]]; then
        fetch="${answer#*$'\n'}"
        fetch="${fetch%%$'\n'*}"
        answer="${answer%%$'\n'*}"
      fi
      # The cause `sourced` says the only reason is code the command runs
      # from somewhere this gate does not read, and npm answered the public
      # registry for everything the gate can read. The PostToolUse hook then
      # withholds this install's scripts but records nothing machine-wide
      # (record_npm_withheld): whoever wrote that code already runs code in
      # the agent's shell, so a record would protect nothing against them. A
      # setting the gate reads, or an ask npm did not answer, keeps no cause
      # and is recorded.
      #
      # Where npm named a registry that is not public, its answer stands as it
      # is and is recorded like any other. That answer came from the
      # command's own words, which the code cannot take back. The sourced
      # unknown used to replace it, so `. /dev/null;
      # npm_config_registry=<impostor> npm install x` recorded nothing, and
      # the next approved install rebuilt the impostor's bytes (VB1-VB3).
      #
      # Code the command chooses for npm to run is the same kind of reason.
      # A PATH, NODE_OPTIONS or other code name (safedeps_npm_code_name) the
      # command sets or unsets, `env -i`, or an npm named by a path that is
      # not this hook's own, each picks which npm runs or what it loads first.
      # The ask never runs that code (lib/npm/ask.sh), so its answer is this
      # hook's npm's, not the command's. Whoever chose that code already runs
      # it in the agent's shell, the way sourced code does. Before this,
      # `export PATH="<dir>:$PATH" && npm ci` was an unknown with no cause,
      # which recorded every package of a tree the hooks had not observed,
      # machine-wide.
      cause=""
      changer="${env_changer:-${stmt_code:-${code_changer}}}"
      if [[ -n "${changer}" && -z "${env_setting}" ]]; then
        # shellcheck disable=SC2016 # a jq program: jq expands its $names
        cause=$(jq -rn --arg public "${SAFEDEPS_NPM_PUBLIC_REGISTRY_RE}" "${SAFEDEPS_NPM_FETCH_JQ:-}"'
            input | . as $f
            | if type != "object" or .unknown != null then ""
              elif ($f.registry | sd_registry_public($f))
                   and ([($f.scopes // {}) | objects | .[]] | all(sd_registry_public($f))) then "sourced"
              else "answered" end' <<< "${fetch}" 2>/dev/null) || cause=""
      fi
      if [[ -n "${changer}" && "${cause}" != answered ]]; then
        if [[ -n "${env_setting}" ]]; then
          value="an earlier statement (${env_setting%$'\001'}) can change the environment npm runs with where the command does not show it"
        elif [[ -n "${env_changer}" ]]; then
          value="an earlier statement (${env_changer%$'\001'}) can change the environment npm runs with where the command does not show it"
        else
          value="the command chooses the code npm runs with (${changer%$'\001'}), and safedeps asks only its own npm and never runs that code"
        fi
        fetch=$(jq -nc --arg w "${value}" --arg cause "${cause}" \
          '{unknown: "\($w), so safedeps cannot tell which registry this install fetches from"}
           + (if $cause == "" then {} else {cause: $cause} end)' 2>/dev/null) \
          || fetch=""
      fi
      local_prefix=""
      case "${answer}" in
        '?'*)
          target="?"
          why="${answer#"?"}"
          why="${why#$'\t'}"
          ;;
        global*)
          target=global
          local_prefix="${answer#global}"
          local_prefix="${local_prefix#$'\t'}"
          why="npm installs this in its global prefix, where no lockfile records it"
          ;;
        *)
          target="${answer}"
          local_prefix="${answer}"
          ;;
      esac

      # npm said where. Whether npm writes a record there is a different
      # question, and two .npmrc settings answer it without moving the
      # install: measured, `global=0` and `location=global` under a
      # `--location=project` put the package in the project's node_modules
      # and in neither lockfile. So the project and user .npmrc are read
      # here, for that only. This reading can turn a gated install into a
      # recorded one, never the other way, and it never chooses a directory.
      [[ -n "${local_prefix}" ]] || break
      user_rc=""
      cli_global_off=false
      want=""
      # npm's home is the HOME it runs with, which the command may set.
      rc_home="${HOME}"
      for tok in "${npm_env[@]+"${npm_env[@]}"}"; do
        [[ "${tok}" != HOME=* ]] || rc_home="${tok#HOME=}"
      done
      for tok in "${toks[@]}"; do
        if [[ -n "${want}" ]]; then user_rc="${tok}"; want=""; continue; fi
        case "${tok}" in
          --userconfig) want=1 ;;
          --userconfig=*) user_rc="${tok#*=}" ;;
          --global=false|--no-global) cli_global_off=true ;;
        esac
      done
      if [[ -n "${want}" ]]; then
        user_rc="?"
      elif [[ -z "${user_rc}" ]]; then
        if [[ "${env_userconfig}" == true ]]; then
          user_rc="?"
        else
          user_rc="${npm_config_userconfig:-${NPM_CONFIG_USERCONFIG:-${rc_home}/.npmrc}}"
        fi
      fi
      case "${user_rc}" in
        '~/'*) user_rc="${rc_home}/${user_rc#'~/'}" ;;
      esac
      [[ "${user_rc}" == "?" ]] || user_rc=$(guard_literal_dir "${here}" "${user_rc}")
      value=$(guard_npmrc_unrecorded "${local_prefix}" "${user_rc}" "${cli_global_off}")
      if [[ -n "${value}" ]]; then
        why="${value}"
        kind=npm-unrecorded
        [[ "${target}" == global ]] || target="?"
      fi
      break
    done
    # The record is cut at \035 and at newlines, and two of its fields carry
    # values the command chose: npm's answer for where the install lands
    # (`--prefix` names it) and the prose, which quotes command words. A
    # directory holding a separator cannot be carried, so it reads as
    # unknown, which the gate records; the prose carries a blank there.
    # <fetch> is one line of JSON, which escapes both.
    if [[ "${target}" == *$'\035'* || "${target}" == *$'\n'* ]]; then
      target="?"
      why="${why:+${why}; }npm named a directory whose name holds a byte this record cannot carry"
    fi
    why="${why//$'\035'/ }"
    why="${why//$'\n'/ }"
    printf '%s\035%s\035%s\035%s\035%s\037%s\n' "${kind}" "${target}" "${why}" "${fetch}" "${stmt_recs[n]:-}" "${stmt_uwords[n]:-}"
  done <<< "${statements}"
  return 0
}

# Why an install trace in one directory cannot be credited to every npm
# install in the command; nothing when it can.
#
# The PostToolUse hook decides whether an install was read by looking for this
# command's install trace in the directory the gate read. One trace answers for
# one npm statement. With two npm statements that write a lockfile, the first
# one's trace hid the second one landing elsewhere: `npm install a; command cd
# sub; npm install b` wrote both the cwd's lockfiles and sub's, and the gate read
# the cwd, found a trace, and passed b unread (measured in the design judgment
# for safedeps/effect-gate-blind-to-lockless-npm-installs, rows M1, M2, M4). So
# two or more writers are credited to one trace only when nothing between them
# can move the second, and no writer moves itself:
#
#   - Every statement between the first and the last writer is inert: echo,
#     printf, tail, head, grep, ls, cat or true, with no substitution, group or
#     redirection other than to /dev/null or another descriptor. Anything else
#     may change the directory, the environment or the files npm reads, and
#     cannot be told apart from text: `npm init -y` between two installs gave
#     the second a package.json of its own.
#   - No writer carries a relocation of its own: a directory or global flag, an
#     npm_config_* setting in front of it, a wrapper word before `npm`, a group,
#     or a word the shell decides at run time.
#   - No npm install runs inside a `sh -c`, `eval` or `$(...)` payload, which
#     the statements here do not show.
#
# A writer is an npm statement whose subcommand writes a lockfile or may:
# everything but the subcommands below, which only read, run or publish. An
# unknown subcommand is a writer, so a misreading costs a record.
#
# This judges one reading; the guard's driver asks every reading and takes the
# first reason any gives. Counting across readings would count a statement
# both readings share twice.
guard_npm_writers_unattributable() {
  local cmd="$1"
  local payload payloads=0

  while IFS= read -r payload; do
    [[ -n "${payload}" ]] || continue
    if judge_grep -qEi "${SAFEDEPS_G_NPM_INSTALL_RE}" <<< "${payload}"; then
      payloads=$(( payloads + 1 ))
    fi
  done < <(command_payload_start_texts "${cmd}")

  guard_reading_writers_unattributable "${cmd}" "${payloads}"
}

# guard_npm_writers_unattributable over the command <text> as written, with
# <payloads> npm installs found in the command's payloads.
guard_reading_writers_unattributable() {
  local text="$1" payloads="$2"
  local before stmt words npm_at sub tok i scan writers=0
  local first_writer="" pending_between="" between="" moved="" n=0
  local -a toks=()

  while IFS=$'\035' read -r before stmt _ words _; do
    if [[ "${before}" == "?" ]]; then
      printf 'the command could not be split into statements (awk failed)'
      return 0
    fi
    [[ -n "${words}" ]] || continue
    IFS=$'\037' read -ra toks <<< "${words}"
    [[ ${#toks[@]} -gt 0 ]] || continue
    n=$(( n + 1 ))

    # The inert heads first: their arguments are text, `echo npm install` is
    # not an install.
    scan=$(printf '%s' "${stmt}" | sed -E 's#[0-9]*>>?[[:space:]]*/dev/null##g; s#[0-9]*>&[0-9-]##g') \
      || { guard_mark_reading_failed; scan="?"; }
    case "${toks[0]}" in
      echo|printf|tail|head|grep|ls|cat|true)
        if [[ "${scan}" != *[\<\>\(\)\{\}\`\$\?]* && "${words}" != *$'\001'* ]]; then
          continue
        fi
        ;;
    esac

    npm_at=-1
    for (( i = 0; i < ${#toks[@]}; i++ )); do
      if safedeps_manager_name "${toks[i]}" npm; then npm_at=${i}; break; fi
    done
    sub=""
    if (( npm_at >= 0 )); then
      for (( i = npm_at + 1; i < ${#toks[@]}; i++ )); do
        tok="${toks[i]}"
        case "${tok}" in
          -C|--prefix|-w|--workspace|--userconfig|--globalconfig|--cache|--registry|--location|--loglevel|--tag|--otp)
            i=$(( i + 1 )); continue ;;
          -*) continue ;;
        esac
        if [[ -z "${sub}" ]]; then
          sub="${tok}"
          [[ "${sub}" == audit ]] || break
          continue
        fi
        # `audit fix` writes; `audit` alone reads.
        [[ "${tok}" == fix ]] && sub="audit fix"
        break
      done
      case "${sub}" in
        ''|audit|run|run-script|rum|urn|test|tst|t|start|stop|restart|exec|x|init|create|innit|view|v|info|show|ls|list|ll|la|outdated|config|c|get|set|prefix|root|bin|query|explain|why|version|pack|publish|unpublish|help|help-search|doctor|ping|whoami|search|s|se|find|docs|home|repo|bugs|issues|fund|cache|completion|login|logout|adduser|add-user|token|profile|owner|team|access|deprecate|dist-tag|hook|org|star|stars|unstar|sbom|diff|pkg|set-script)
          npm_at=-1 ;;
      esac
    fi

    if (( npm_at < 0 )); then
      # Not a writer. Between two writers it is a statement that may move the
      # second one; it only counts once a writer has been seen.
      if [[ -n "${first_writer}" && -z "${pending_between}" ]]; then
        pending_between=$(printf '%s ' "${toks[@]}" | tr -d '\001')
      fi
      continue
    fi

    writers=$(( writers + 1 ))
    [[ -n "${first_writer}" ]] || first_writer="${n}"
    if [[ -n "${pending_between}" && -z "${between}" ]]; then
      between="${pending_between}"
    fi
    pending_between=""
    if [[ -z "${moved}" ]]; then
      if [[ "${words}" == *$'\001'* || "${stmt}" == *[\(\)\{\}\`]* ]]; then
        moved=$(printf '%s ' "${toks[@]}" | tr -d '\001')
      else
        for (( i = 0; i < ${#toks[@]}; i++ )); do
          tok="${toks[i]}"
          if (( i < npm_at )); then
            case "${tok}" in
              command|exec|time) continue ;;
            esac
            if [[ "${tok}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] \
                && [[ "$(printf '%s' "${tok%%=*}" | tr '[:upper:]' '[:lower:]')" != npm_config_* ]]; then
              continue
            fi
            moved="${tok}"
            break
          fi
          case "${tok}" in
            -C|-C?*|--prefix|--prefix=*|-g|--global|--global=*|--no-global|--location|--location=*|--workspaces|--workspaces=*|--no-workspaces|--userconfig|--userconfig=*|--globalconfig|--globalconfig=*)
              moved="${tok}"
              break
              ;;
          esac
        done
      fi
    fi
  done < <(command_statements "${text}")

  (( writers + payloads >= 2 )) || return 0
  if (( payloads > 0 )); then
    printf 'an npm install runs inside a `sh -c`, `eval` or `$(...)` payload beside another npm statement that writes a lockfile'
  elif [[ -n "${between}" ]]; then
    printf '%s npm statements write a lockfile, and `%s` runs between them' "${writers}" "${between% }"
  elif [[ -n "${moved}" ]]; then
    printf '%s npm statements write a lockfile, and one of them moves where it installs (`%s`)' "${writers}" "${moved% }"
  fi
  return 0
}

# True when the command runs an npm CLI install anywhere, payloads included:
# the installs whose result the effect gate reads, and so the ones the
# PostToolUse hook has to find a trace of.
#
# A grep that cannot answer counts as a match: the cost is a trace check on a
# command that needed none, where the other direction skips the check. It is
# recorded as a failed reading too, so the gate settles it. Counted as a match
# alone, it wrote an npm trace baseline into the pending state of a `pip
# install` with nothing said (the census, once it failed one grep at a time and
# compared that part of the record).
guard_command_has_npm_install() {
  local texts rc=0
  texts=$(command_candidate_start_texts "$1")
  grep -qEi "${SAFEDEPS_G_NPM_INSTALL_RE}" <<< "${texts}" || rc=$?
  (( rc <= 1 )) || guard_mark_reading_failed
  (( rc == 1 )) || return 0
  return 1
}

# The inode of <file>, or nothing when it is not there. `ls -i` is the one
# spelling BSD and GNU share.
guard_file_inode() {
  local inode
  [[ -e "$1" ]] || return 0
  read -r inode _ < <(ls -di -- "$1" 2>/dev/null) || return 0
  printf '%s' "${inode}"
}

snapshot_project_file() {
  local relative_file="$1"
  local category="${2:-manifest}"
  local source_path="${PROJECT_DIR}/${relative_file}"
  local snapshot_path
  snapshot_path="${SNAPSHOT_DIR}/${SNAPSHOT_ID}_$(safedeps_snapshot_file_name "${relative_file}")"

  printf '%s\n' "${relative_file}" >> "${SNAPSHOT_DIR}/${SNAPSHOT_ID}_monitored_files.list"

  if [[ -f "${source_path}" ]]; then
    cp "${source_path}" "${snapshot_path}"
    if command -v shasum &>/dev/null; then
      shasum -a 256 "${source_path}" > "${snapshot_path}.sha256"
    elif command -v sha256sum &>/dev/null; then
      sha256sum "${source_path}" > "${snapshot_path}.sha256"
    fi
    if [[ "${category}" == "lock" ]]; then
      SNAPSHOTTED=true
    fi
  else
    touch "${snapshot_path}.missing"
  fi
}

# Every workspace member's package.json, in one copy and one hash. A workspace
# install writes a member's manifest as well as the root's, and a rollback has
# to restore it. Which members an install writes is npm's to decide, so all of
# them are kept rather than a guess. They used to be copied and hashed one by
# one, two processes per member, and a workspace of 1000 members took 20-33s to
# judge: past the runtime's 30s kill, which lets the command through unjudged.
# Here the process count does not depend on the member count
# (scripts/test/workspace-snapshot-count.sh).
#
# The copies go under <snapshot id>_members as a tree, through tar, because cp
# cannot rename and flat names would need a rename per member. The hash list is
# written from the copies with paths relative to the project, so
# `shasum -c` run in the project compares the project with the snapshot.
# Returns 1 when the copy or the hash failed, with the reason on stderr.
snapshot_workspace_manifests() {
  local member dest
  local -a members=()
  while IFS= read -r member; do
    [[ -n "${member}" ]] && members+=("${member}")
  done < <(safedeps_npm_workspace_manifests "${PROJECT_DIR}")
  [[ ${#members[@]} -gt 0 ]] || return 0

  dest="${SNAPSHOT_DIR}/${SNAPSHOT_ID}_${SAFEDEPS_SNAPSHOT_MEMBERS}"
  # `./` keeps a name that starts with a dash from reading as an option. -h
  # copies a member's package.json, not a symlink to it. COPYFILE_DISABLE keeps
  # macOS tar from adding AppleDouble files beside each one.
  printf './%s\0' "${members[@]}" > "${dest}.files"
  mkdir "${dest}" || return 1
  (cd "${PROJECT_DIR}" && COPYFILE_DISABLE=1 tar -chf - --null -T "${dest}.files") \
    | tar -xf - -C "${dest}" || return 1
  # xargs splits the list only past the system's argument limit, so one shasum
  # covers every workspace short of tens of thousands of members.
  if command -v shasum >/dev/null 2>&1; then
    (cd "${dest}" && printf '%s\0' "${members[@]}" | xargs -0 shasum -a 256 --) > "${dest}.sha256" || return 1
  else
    (cd "${dest}" && printf '%s\0' "${members[@]}" | xargs -0 sha256sum --) > "${dest}.sha256" || return 1
  fi
  printf '%s\n' "${members[@]}" >> "${SNAPSHOT_DIR}/${SNAPSHOT_ID}_monitored_files.list"
}

# Read tool input from stdin
INPUT=$(cat)

# Extract tool name and command
TOOL_NAME=$(echo "${INPUT}" | jq -r '.tool_name // empty' 2>/dev/null)
COMMAND=$(echo "${INPUT}" | jq -r '.tool_input.command // empty' 2>/dev/null)

# Only intercept Bash tool calls
if [[ "${TOOL_NAME}" != "Bash" ]] || [[ -z "${COMMAND}" ]]; then
  exit 0
fi

# Said before any judging, and only by the parent, so the record carries one line
# per hook invocation rather than one per process — the budget child re-enters
# this script and would otherwise say it twice.
if [[ "${SAFEDEPS_BUDGET_ROLE}" == "parent" ]]; then
  safedeps_guard_announce_truth_sources
fi

# --- Self budget: never let the runtime kill us mid-judgment ----------------
#
# The runtime gives this hook a fixed budget (the installer registers 30s), and
# the measured behavior past that budget is FAIL-OPEN: the hook is killed and
# the tool call proceeds (Claude Code, measured 2026-08-04; Codex unmeasured, so
# no parity assumed). The command scan is superlinear in command length, so the
# budget is reachable by padding — measured here, 28KB took 29s and 32KB took
# 38s. Past that line this gate silently disappears, which for pip/cargo/go/gem
# (where the command gate is the authority, not an advisory layer) is a
# universal bypass that needs no cleverness at all.
#
# The runtime's timeout behavior is not ours to change. Answering before it
# fires is. So the guard runs its judgment in a child under a budget of its own,
# smaller than the runtime's, and if that child has not answered in time the
# guard answers for it: DENY, because an install we could not judge must not
# proceed. The runtime never gets to kill us mid-flight, so there is nothing
# left to fail open.
#
# Two properties this deny must keep, because both were paid for in incidents:
#   - It is fail-CLOSED but it is NOT a finding. "I did not finish looking" and
#     "I looked and found a violation" are different sentences, and a reader who
#     cannot tell them apart learns to route around the gate. The reason string
#     says which one this is, in its first four words.
#   - It is observable (advisory.log), like every other bypass or unavailability.
#
# Only commands large enough to be anywhere near the budget pay for the extra
# process. Below the engage size the judgment finishes orders of magnitude
# inside the budget (1KB measured at ~0.1s against a 30s runtime budget), so the
# machinery would be pure overhead on every Bash call the agent makes. The
# engage size is a performance gate with ~300x of headroom behind it, not a
# security boundary — the security boundary is the wall-clock budget below,
# which is machine-independent in a way a byte count can never be.
#
# The self budget is tunable, but only downward. A budget at or above the
# runtime's is not a budget: the runtime kills the hook first and the tool call
# proceeds, which is exactly the fail-open this machinery exists to remove. And
# the motive to raise it is an ordinary one — someone who hits UNDECIDED on a
# large command reads it as "the budget is short" and raises it, switching off a
# security boundary without ever meaning to. A boundary a user can move is not a
# boundary, it is a default. So the value is clamped to a ceiling below the
# runtime's budget, and lowering it stays free because a shorter budget only
# denies earlier.
#
# Where the runtime's number comes from: the hook payload does not carry it, and
# a Claude Code settings file that registers hooks can live in any of three
# places whose entries all fire, so the hook cannot tell at runtime which
# registration launched it. What it can do is name the number safedeps itself
# registers — `PRE_HOOK_TIMEOUT_SECONDS` in scripts/install/install-safedeps-hooks.mjs,
# 30s, matching the measured kill time (Claude Code, 2026-08-04). The smoke test
# pins the two constants together so an installer change cannot leave this one
# stale. A user who hand-edits the registered timeout below 30s is outside what
# this constant can know; the clamp is still correct for every install safedeps
# performs.
SAFEDEPS_RUNTIME_BUDGET_SECONDS=30

# The ceiling is the runtime's budget minus what the guard spends OUTSIDE the
# budget window, plus slack. The window opens when this script starts, so
# reading the payload and the knobs is inside it. The cost outside the window
# is structural, not proportional to the command:
#   - up to one poll step past the deadline: 1.0s asked for (the step doubles
#     and caps at 1s), plus whatever a loaded machine adds to that one sleep
#   - up to 0.5s of TERM grace before the KILL (10 polls x 50ms), stretched the
#     same way on a loaded machine, and spent in full only when TERM is ignored
#   - the entry shim and bash starting this script, then reap and jq: ~0.1s
# That is a 1.6s structural worst case on an idle machine. The deadline reads a
# whole-second clock, so it can also fire up to a second early, which only adds
# headroom. Measured end-to-end overshoot past the budget was 0.73-1.05s and
# flat from 4KB to 256KB of command text (2026-08-04, same machine as the 30s
# kill measurement, before the deadline read the clock). 30 - 25 = 5s of
# headroom, i.e. ~3x the structural worst case and ~5x the measured one, which
# is what a loaded machine needs before an on-time answer becomes a late one.
# Load stretches only the last step and the grace now. While the deadline added
# up the sleeps it asked for, load stretched every step of the wait.
SAFEDEPS_SELF_BUDGET_MAX_SECONDS=25

SAFEDEPS_SELF_BUDGET_DEFAULT_SECONDS=20

# The engage size has a ceiling for the same reason the budget does. It is the
# only condition on the whole machinery above — raise it and the judgment runs
# inline with no deadline at all, which is the same fail-open by a different
# door: measured, a 32KB padded `pip install` answers in 21s with the default
# engage size and takes 198s with the size raised past it, and the runtime kills
# the hook at 30s either way. Someone who cannot raise the budget any more looks
# for the next knob, and this is the next knob.
#
# 4KB, because the ceiling has to keep the un-engaged worst case far inside the
# runtime budget: on the cost curve recorded in ROADMAP v2.15.0 (1KB 0.1s, 4KB
# 0.68s, 8KB 2.5s, 16KB 9.6s), a command just under 4KB is judged in about 0.68s,
# roughly 44x inside the 30s runtime budget. Tuning between the 1KB default and
# this ceiling stays available, which is what the knob is actually for.
SAFEDEPS_BUDGET_ENGAGE_DEFAULT_BYTES=1024
SAFEDEPS_BUDGET_ENGAGE_MAX_BYTES=4096

# Normalize the value BEFORE anything compares or clamps it, and let only the
# normalized digits reach `$(( ))`. This ordering is the whole fix for a defect
# the first version of the clamp shipped: it validated with `^[0-9]+$` but the
# deadline consumed the raw string in arithmetic, and bash arithmetic accepts a
# strictly wider grammar than that regex. `+40`, ` 40` and `0x28` all fail the
# regex, so the clamp skipped them, and all three then evaluated to 40 as the
# budget — above the runtime's, which hands the kill back to the runtime and
# restores the exact fail-open this ceiling exists to remove. Measured: a 64KB
# command under `+40` produced no answer for 41s. Two grammars for one value is
# the bug; the fix is that there is now one, checked here, and the raw string
# never reaches arithmetic.
#
# Surrounding whitespace and a leading `+` are accepted and normalized away,
# because `SAFEDEPS_SELF_BUDGET_SECONDS="40 "` means 40 seconds to everyone who
# types it, and the clamp should read it the way its author meant it. Anything
# still not a run of digits is not a budget: it falls back to the default, which
# is inside the ceiling and therefore safe, and it says so on the same channels
# as the clamp. `10#` forces base 10 so `08` is eight rather than an octal error.
#
# Nine digits, because that is both far more than either knob can mean (a budget
# of 999999999s is about 31 years) and small enough that the value and the
# `* 1000` deadline below stay inside a 64-bit integer with room to spare.
SAFEDEPS_KNOB_MAX_DIGITS=9

# The longest input the reader will look at. Nine digits plus a sign, some
# whitespace, and room to spare — a real value never comes close, and refusing
# past it is what keeps the parse from being the slow path.
SAFEDEPS_KNOB_MAX_INPUT_CHARS=32

# One reader for both knobs, because they failed the same way and a second
# hand-rolled parser is how they would drift apart again. Prints the normalized
# digits, or nothing with a non-zero status when the value is not a number.
safedeps_normalize_knob() {
  local raw="$1" value
  # Length first, in one cheap pass before any pattern work, because everything
  # below is pattern work on the whole string, and pattern work is where this has
  # now failed twice. The
  # per-zero strip loop was quadratic; the regex that replaced it cut the
  # constant about a hundredfold and left the class alone — measured on the
  # reader itself, doubling the input quadrupled the time (50k 0.34s, 100k
  # 1.26s, 200k 5.01s, 400k 20.2s, 800k 88.0s), so 500000 leading zeros still
  # burned 224s end to end. That work happens before the child spawn, where the
  # deadline cannot reach it. A cheap ceiling on the INPUT is what actually
  # bounds it: no reachable knob value is 32 characters long, since nine digits
  # is already about 31 years of seconds, and anything longer is refused rather
  # than parsed.
  if (( ${#raw} > SAFEDEPS_KNOB_MAX_INPUT_CHARS )); then
    return 1
  fi
  value="${raw#"${raw%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  value="${value#+}"
  # Leading zeros are not magnitude, so they come off before the digit count
  # judges the value by its length: `0000000005` is five, not ten digits' worth.
  # One regex rather than one per zero — the loop this replaces was quadratic,
  # and it ran BEFORE the child spawn, where the deadline cannot reach it:
  # 40000 zeros took 28.9s and 60000 took 63.2s, past the runtime's own budget.
  if [[ "${value}" =~ ^0*([0-9].*)$ ]]; then
    value="${BASH_REMATCH[1]}"
  fi
  [[ "${value}" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "${value}"
}

SAFEDEPS_SELF_BUDGET_INVALID_FROM=""
SAFEDEPS_SELF_BUDGET_CLAMPED_FROM=""
if [[ -z "${SAFEDEPS_SELF_BUDGET_SECONDS:-}" ]]; then
  SAFEDEPS_SELF_BUDGET_SECONDS="${SAFEDEPS_SELF_BUDGET_DEFAULT_SECONDS}"
else
  budget_given="${SAFEDEPS_SELF_BUDGET_SECONDS}"
  if ! budget_normalized=$(safedeps_normalize_knob "${budget_given}"); then
    # Quoted back to the user, so it is truncated: a refused value can be
    # arbitrarily long, and echoing it whole would put megabytes on the hook's
    # stderr and into advisory.log.
    SAFEDEPS_SELF_BUDGET_INVALID_FROM="${budget_given:0:${SAFEDEPS_KNOB_MAX_INPUT_CHARS}}"
    if (( ${#budget_given} > SAFEDEPS_KNOB_MAX_INPUT_CHARS )); then
      SAFEDEPS_SELF_BUDGET_INVALID_FROM="${SAFEDEPS_SELF_BUDGET_INVALID_FROM}... (${#budget_given} characters)"
    fi
    SAFEDEPS_SELF_BUDGET_SECONDS="${SAFEDEPS_SELF_BUDGET_DEFAULT_SECONDS}"
  # Digits first, magnitude second. Bash integers are 64-bit and wrap silently,
  # so evaluating first and comparing after is not an option: a value that wraps
  # NEGATIVE is not `> ceiling`, so it walks straight past the clamp, and
  # `budget * 1000` then wraps again into a deadline that never arrives.
  # Measured before this check: a 30-digit value produced no answer for over
  # 600s. Counting digits happens in the string domain, where nothing can wrap.
  #
  # Either way the value is above the ceiling, so it is clamped rather than
  # rejected — the rule stays "anything above the ceiling is clamped", with no
  # exception for how it was written.
  elif (( ${#budget_normalized} > SAFEDEPS_KNOB_MAX_DIGITS )) \
    || (( 10#${budget_normalized} > SAFEDEPS_SELF_BUDGET_MAX_SECONDS )); then
    SAFEDEPS_SELF_BUDGET_CLAMPED_FROM="${budget_normalized}"
    SAFEDEPS_SELF_BUDGET_SECONDS="${SAFEDEPS_SELF_BUDGET_MAX_SECONDS}"
  else
    SAFEDEPS_SELF_BUDGET_SECONDS=$(( 10#${budget_normalized} ))
  fi
fi

# The engage size is read exactly the same way, for exactly the same reasons.
SAFEDEPS_BUDGET_ENGAGE_INVALID_FROM=""
SAFEDEPS_BUDGET_ENGAGE_CLAMPED_FROM=""
if [[ -z "${SAFEDEPS_BUDGET_ENGAGE_BYTES:-}" ]]; then
  SAFEDEPS_BUDGET_ENGAGE_BYTES="${SAFEDEPS_BUDGET_ENGAGE_DEFAULT_BYTES}"
else
  engage_given="${SAFEDEPS_BUDGET_ENGAGE_BYTES}"
  if ! engage_normalized=$(safedeps_normalize_knob "${engage_given}"); then
    SAFEDEPS_BUDGET_ENGAGE_INVALID_FROM="${engage_given:0:${SAFEDEPS_KNOB_MAX_INPUT_CHARS}}"
    if (( ${#engage_given} > SAFEDEPS_KNOB_MAX_INPUT_CHARS )); then
      SAFEDEPS_BUDGET_ENGAGE_INVALID_FROM="${SAFEDEPS_BUDGET_ENGAGE_INVALID_FROM}... (${#engage_given} characters)"
    fi
    SAFEDEPS_BUDGET_ENGAGE_BYTES="${SAFEDEPS_BUDGET_ENGAGE_DEFAULT_BYTES}"
  elif (( ${#engage_normalized} > SAFEDEPS_KNOB_MAX_DIGITS )) \
    || (( 10#${engage_normalized} > SAFEDEPS_BUDGET_ENGAGE_MAX_BYTES )); then
    SAFEDEPS_BUDGET_ENGAGE_CLAMPED_FROM="${engage_normalized}"
    SAFEDEPS_BUDGET_ENGAGE_BYTES="${SAFEDEPS_BUDGET_ENGAGE_MAX_BYTES}"
  else
    SAFEDEPS_BUDGET_ENGAGE_BYTES=$(( 10#${engage_normalized} ))
  fi
fi

# Turning the deadline off entirely is a separate, differently named thing.
#
# The mutation check in the battery has to be able to do it: a test that only
# knows it passes, and not that it catches the defect, is not evidence. But the
# way it used to do it was by raising the engage size past the input, which is
# also the way a user reduces friction — one switch served both, so tuning and
# disabling were the same act, and nothing said which one had happened.
#
# So they are split. The tuning knob has a ceiling and cannot disable anything;
# this variable does nothing else, says what it does in its name, and announces
# itself every time it takes effect. Someone who exports SAFEDEPS_BUDGET_DISABLED
# is not adjusting a threshold, and there is no version of that sentence they can
# arrive at by accident.
SAFEDEPS_BUDGET_DISABLED="${SAFEDEPS_BUDGET_DISABLED:-}"

# A disabled deadline is a bypass, so it is announced every time it is used, on
# the same channels as every other bypass. It is checked at the engage size and
# not above it, so turning the deadline off does not also turn its own notice off
# for the very commands the deadline exists for.
if [[ -n "${SAFEDEPS_BUDGET_DISABLED}" ]] && [[ "${SAFEDEPS_BUDGET_ROLE}" == "parent" ]] \
  && (( ${#COMMAND} >= SAFEDEPS_BUDGET_ENGAGE_BYTES )); then
  log_advisory "pre-guard: SAFEDEPS_BUDGET_DISABLED is set — the self-budget deadline is OFF for this command (${#COMMAND} bytes). Past the ${SAFEDEPS_RUNTIME_BUDGET_SECONDS}s runtime hook budget this gate is killed and the install proceeds unjudged."
  printf 'safedeps: SAFEDEPS_BUDGET_DISABLED is set, so the self-budget deadline is OFF for this command. The judgment now runs with no deadline of its own, and past the %ss runtime hook budget the runtime kills this gate and the install proceeds unjudged. Unset it to restore the gate.\n' \
    "${SAFEDEPS_RUNTIME_BUDGET_SECONDS}" >&2
fi

if [[ -z "${SAFEDEPS_BUDGET_DISABLED}" ]] && [[ "${SAFEDEPS_BUDGET_ROLE}" == "parent" ]] \
  && (( ${#COMMAND} >= SAFEDEPS_BUDGET_ENGAGE_BYTES )); then
  # Say that the clamp happened, and say it here rather than at the assignment
  # above: this is the point where the budget is actually in play, and a line on
  # every `ls` the agent runs would be noise people learn to scroll past. A
  # silently reduced budget would let the user believe the value they set is the
  # one running, and the next surprise gets debugged against a number that was
  # never true — so it goes to advisory.log like every other bypass or
  # unavailability, AND to stderr so it reaches the session and not only a file.
  if [[ -n "${SAFEDEPS_SELF_BUDGET_CLAMPED_FROM}" ]]; then
    log_advisory "pre-guard: SAFEDEPS_SELF_BUDGET_SECONDS=${SAFEDEPS_SELF_BUDGET_CLAMPED_FROM} exceeds the ${SAFEDEPS_SELF_BUDGET_MAX_SECONDS}s ceiling — clamped to ${SAFEDEPS_SELF_BUDGET_SECONDS}s. Above the ceiling the ${SAFEDEPS_RUNTIME_BUDGET_SECONDS}s runtime hook budget kills this gate first and the install proceeds unjudged."
    printf 'safedeps: SAFEDEPS_SELF_BUDGET_SECONDS=%ss exceeds the %ss ceiling and was clamped to %ss. The ceiling sits below the runtime hook budget (%ss); above it the runtime kills this gate mid-judgment and the install runs unjudged, so raising the value removes the check rather than extending it. Lower values are honoured as given.\n' \
      "${SAFEDEPS_SELF_BUDGET_CLAMPED_FROM}" "${SAFEDEPS_SELF_BUDGET_MAX_SECONDS}" \
      "${SAFEDEPS_SELF_BUDGET_SECONDS}" "${SAFEDEPS_RUNTIME_BUDGET_SECONDS}" >&2
  fi

  # A value that is not a number gets the same treatment for the same reason:
  # the budget in force is not the one the user set, so the user has to hear it.
  # Falling back to the default is safe in the only sense that matters here —
  # the default is inside the ceiling — but it is still a value nobody asked
  # for, and an unexplained one would send the next debugging session after a
  # number that was never true.
  # The marker that used to live in the environment is announced when it is
  # still set, because a signal that used to switch the deadline off and now
  # does nothing must not fail silently in either direction: someone whose
  # script exports it should learn that it stopped meaning anything, rather than
  # keep believing the deadline is off.
  if [[ -n "${SAFEDEPS_BUDGET_CHILD:-}" ]]; then
    log_advisory "pre-guard: SAFEDEPS_BUDGET_CHILD is set in the environment and is ignored — the parent/child marker moved to argv, where it cannot be injected. The deadline is running normally."
    printf 'safedeps: SAFEDEPS_BUDGET_CHILD is set in the environment and has no effect. The parent/child marker moved into argv so it cannot be set from outside; the deadline is running normally. To turn the deadline off deliberately, set SAFEDEPS_BUDGET_DISABLED.\n' >&2
  fi

  # The engage size reports itself on the same channels. It is the condition on
  # this whole branch, so a raised value that went unreported would be the
  # quietest of the three: the machinery would simply not be here.
  if [[ -n "${SAFEDEPS_BUDGET_ENGAGE_CLAMPED_FROM}" ]]; then
    log_advisory "pre-guard: SAFEDEPS_BUDGET_ENGAGE_BYTES=${SAFEDEPS_BUDGET_ENGAGE_CLAMPED_FROM} exceeds the ${SAFEDEPS_BUDGET_ENGAGE_MAX_BYTES}-byte ceiling — clamped to ${SAFEDEPS_BUDGET_ENGAGE_BYTES}. Above the ceiling the deadline never engages and the judgment runs unbounded."
    printf 'safedeps: SAFEDEPS_BUDGET_ENGAGE_BYTES=%s exceeds the %s-byte ceiling and was clamped to %s. The engage size decides when the deadline runs at all, so raising it past the ceiling would disable the deadline rather than tune it. To turn the deadline off deliberately, set SAFEDEPS_BUDGET_DISABLED.\n' \
      "${SAFEDEPS_BUDGET_ENGAGE_CLAMPED_FROM}" "${SAFEDEPS_BUDGET_ENGAGE_MAX_BYTES}" \
      "${SAFEDEPS_BUDGET_ENGAGE_BYTES}" >&2
  fi
  if [[ -n "${SAFEDEPS_BUDGET_ENGAGE_INVALID_FROM}" ]]; then
    log_advisory "pre-guard: SAFEDEPS_BUDGET_ENGAGE_BYTES='${SAFEDEPS_BUDGET_ENGAGE_INVALID_FROM}' is not a whole number of bytes — using the ${SAFEDEPS_BUDGET_ENGAGE_BYTES}-byte default instead."
    printf "safedeps: SAFEDEPS_BUDGET_ENGAGE_BYTES='%s' is not a whole number of bytes, so the %s-byte default is in force.\n" \
      "${SAFEDEPS_BUDGET_ENGAGE_INVALID_FROM}" "${SAFEDEPS_BUDGET_ENGAGE_BYTES}" >&2
  fi

  if [[ -n "${SAFEDEPS_SELF_BUDGET_INVALID_FROM}" ]]; then
    log_advisory "pre-guard: SAFEDEPS_SELF_BUDGET_SECONDS='${SAFEDEPS_SELF_BUDGET_INVALID_FROM}' is not a whole number of seconds — using the ${SAFEDEPS_SELF_BUDGET_SECONDS}s default instead."
    printf "safedeps: SAFEDEPS_SELF_BUDGET_SECONDS='%s' is not a whole number of seconds, so the %ss default is in force. Set a plain integer at or below the %ss ceiling.\n" \
      "${SAFEDEPS_SELF_BUDGET_INVALID_FROM}" "${SAFEDEPS_SELF_BUDGET_SECONDS}" \
      "${SAFEDEPS_SELF_BUDGET_MAX_SECONDS}" >&2
  fi

  budget_out=$(mktemp "${TMPDIR:-/tmp}/safedeps-budget.XXXXXX")
  budget_err=$(mktemp "${TMPDIR:-/tmp}/safedeps-budget.XXXXXX")

  # Same payload, same script, one argv marker so the child judges instead of
  # re-entering this wrapper.
  #
  # The payload goes through a file rather than a pipe, and job control is on
  # for the spawn, because the deadline has to be able to signal the whole child
  # TREE. A bash script blocked in a foreground external command does not act on
  # a signal until that command returns, and the expensive part of the judgment
  # is exactly such a command — so signalling the child shell alone lands late,
  # measured 9.1s late against a 20s budget. With job control the child is its
  # own process group leader, so `kill -- -PID` reaches the work as well as the
  # shell. A pipeline would make the group leader the `printf`, not the shell,
  # and `$!` would name neither.
  budget_in=$(mktemp "${TMPDIR:-/tmp}/safedeps-budget.XXXXXX")
  printf '%s' "${INPUT}" > "${budget_in}"

  # Silence this shell's own stderr for the spawn/deadline/reap region. The
  # shell announces a background job that died by signal ("Terminated: 15" and
  # the command text) at whatever statement it next reaches, which is why
  # redirecting `wait` alone does not catch it — the announcement can surface on
  # any command boundary in the region. Beside a security deny that line reads
  # as a malfunction rather than as the deadline doing its job. The child's own
  # stderr is captured to a file and re-emitted verbatim below, so nothing the
  # judgment actually says is lost; only the shell's bookkeeping is dropped.
  exec 3>&2 2>/dev/null
  bash "${BASH_SOURCE[0]}" --budget-child \
    <"${budget_in}" >"${budget_out}" 2>"${budget_err}" &
  budget_child=$!

  # The parent keeps the deadline itself rather than delegating to a watchdog
  # subshell. A watchdog would have to sleep in fixed steps, and killing it
  # while it sits in `sleep` does not return the shell until that sleep expires
  # — measured, that rounded every engaged call up to the next whole second
  # (a 788ms judgment took 1050ms). It would also outlive this process by up to
  # one step, holding a PID it might no longer own. Polling here costs one
  # `sleep` per step and starts fine-grained: a judgment that finishes inside
  # the first 50ms step is answered at 50ms, any judgment is answered at most
  # one step after it finishes, and a long one still coasts on 1s steps.
  #
  # The deadline is read from the clock, not added up from the sleeps. It used
  # to count the time each step asked for. On a loaded machine a sleep takes
  # longer than it asks for, and each step also forked to format its argument.
  # The real wait then ran past the budget by whatever load added to every
  # step, and past the runtime's 30s the hook is killed and the install runs
  # unjudged. The clock is SECONDS, measured from this script's
  # start (see SAFEDEPS_GUARD_STARTED_SECONDS): bash 3.2 has no finer clock
  # that costs no process. Whole seconds can fire the deadline up to a second
  # early, never late, and early only denies sooner. Late is bounded by one
  # poll step, however many steps came before it.
  #
  # The sum of the requested sleeps stays as a second bound because it does not
  # read the wall clock: if the clock is stepped back, SECONDS stalls and the
  # sum still ends the wait. It can only be late, never early, so it no longer
  # decides on its own. The step lengths are written out in advance, so a step
  # forks nothing but its `sleep`.
  budget_step_ms=(50 100 200 400 800 1000)
  budget_step_arg=(0.050 0.100 0.200 0.400 0.800 1.000)
  budget_step_last=$(( ${#budget_step_ms[@]} - 1 ))
  budget_step=0
  budget_waited_ms=0
  budget_timed_out=false
  budget_deadline_ms=$(( SAFEDEPS_SELF_BUDGET_SECONDS * 1000 ))
  while kill -0 "${budget_child}" 2>/dev/null; do
    if (( SECONDS - SAFEDEPS_GUARD_STARTED_SECONDS >= SAFEDEPS_SELF_BUDGET_SECONDS )) \
      || (( budget_waited_ms >= budget_deadline_ms )); then
      # Signal the child AND whatever it is currently blocked in. A bash script
      # does not act on a signal while a foreground external command is running,
      # and the expensive part of the judgment is exactly such a command — so a
      # TERM to the shell alone lands whenever that command happens to finish,
      # measured 9.1s late against a 20s budget.
      #
      # What makes the deadline unconditional is the SIGKILL below, because a
      # KILL cannot be deferred or trapped. The descendant sweep is not what
      # holds the guarantee: with `pgrep` absent from PATH the same input still
      # answers on time (11.8s -> 12.3s against an 11s budget, measured). It is
      # here so the running scan stops with the shell instead of being orphaned
      # and burning a core until it finishes on its own.
      #
      # Descendants are looked up from this child's own pid, never by name
      # pattern, so nothing outside this judgment can ever be selected.
      budget_kill_tree() {
        local signal="$1" root="$2" descendant
        for descendant in $(pgrep -P "${root}" 2>/dev/null); do
          budget_kill_tree "${signal}" "${descendant}"
        done
        kill "-${signal}" "${root}" 2>/dev/null || true
      }
      #
      # TERM first, so a judgment that hears it stops at once. Then a grace of
      # up to 10 polls of 50ms for the child to go, which ends early when it
      # does. Then KILL. The grace is a count of polls rather than a clock
      # reading, because SECONDS is too coarse for half a second; a loaded
      # machine stretches it like any sleep, and only a child that ignores TERM
      # waits it out.
      budget_kill_tree TERM "${budget_child}"
      budget_grace=0
      while kill -0 "${budget_child}" 2>/dev/null && (( budget_grace < 10 )); do
        sleep 0.05
        budget_grace=$(( budget_grace + 1 ))
      done
      budget_kill_tree KILL "${budget_child}"
      budget_timed_out=true
      break
    fi
    sleep "${budget_step_arg[budget_step]}"
    budget_waited_ms=$(( budget_waited_ms + budget_step_ms[budget_step] ))
    # Plain `if`, not `(( ... )) && assign`: under `set -e` a false arithmetic
    # test makes the whole && list fail and takes the guard down with it.
    if (( budget_step < budget_step_last )); then
      budget_step=$(( budget_step + 1 ))
    fi
  done

  # Always reap, and always with stderr redirected. The shell announces a
  # background job that died by signal ("Terminated: 15" plus the command text),
  # and it does so at whatever statement it next reaches — so skipping `wait`
  # does not avoid the announcement, it just relocates it to a line with no
  # redirection, where it lands on the hook's stderr beside a security deny and
  # reads as a malfunction. Reaping under a redirect is what actually absorbs it.
  budget_rc=0
  wait "${budget_child}" 2>/dev/null || budget_rc=$?
  if [[ "${budget_timed_out}" == "true" && ${budget_rc} -eq 0 ]]; then
    # It answered in the instant between the deadline and the signal landing.
    # We stopped judging it, so we do not get to use its answer.
    budget_rc=143
  fi

  exec 2>&3 3>&-

  # The hooks exit 0 on every designed path (decisions travel as JSON on
  # stdout), so a non-zero child is an unfinished judgment, whether the watchdog
  # killed it or it died some other way. Either way we did not judge it.
  if [[ ${budget_rc} -eq 0 ]]; then
    cat "${budget_err}" >&2
    cat "${budget_out}"
    rm -f "${budget_out}" "${budget_err}" "${budget_in}"
    exit 0
  fi

  rm -f "${budget_out}" "${budget_err}" "${budget_in}"
  log_advisory "pre-guard DENY: judgment unfinished within the ${SAFEDEPS_SELF_BUDGET_SECONDS}s self-budget (command ${#COMMAND} bytes, child rc=${budget_rc}) — fail-closed, not a detection."
  # When the budget in force is not the one the user set, the reason says so.
  # Otherwise the user reads a budget figure they never set and concludes the
  # setting did not take.
  budget_clamp_note=""
  if [[ -n "${SAFEDEPS_SELF_BUDGET_CLAMPED_FROM}" ]]; then
    budget_clamp_note=" Your SAFEDEPS_SELF_BUDGET_SECONDS=${SAFEDEPS_SELF_BUDGET_CLAMPED_FROM} was clamped to the ${SAFEDEPS_SELF_BUDGET_MAX_SECONDS}s ceiling: above it the ${SAFEDEPS_RUNTIME_BUDGET_SECONDS}s runtime hook budget kills this gate mid-judgment and the install runs unjudged, so raising it removes the check rather than extending it."
  elif [[ -n "${SAFEDEPS_SELF_BUDGET_INVALID_FROM}" ]]; then
    budget_clamp_note=" Your SAFEDEPS_SELF_BUDGET_SECONDS='${SAFEDEPS_SELF_BUDGET_INVALID_FROM}' is not a whole number of seconds, so the ${SAFEDEPS_SELF_BUDGET_SECONDS}s default is in force."
  fi
  jq -nc --arg budget "${SAFEDEPS_SELF_BUDGET_SECONDS}" --arg size "${#COMMAND}" --arg clamp "${budget_clamp_note}" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:("safedeps: UNDECIDED, not unsafe — safedeps could not finish judging this command within its " + $budget + "s budget (" + $size + " bytes of command text), so it is blocked fail-closed. Nothing was detected in it; the gate simply did not get to an answer, and an install it cannot judge must not run. Scan cost grows with command length. Split the command, or write long content with a file-writing tool instead of one very large shell command, and retry." + $clamp)}}'
  exit 0
fi

# Where command_scan_text records a failure (see there). An empty name means the
# mark could not be made, and guard_scan_failed treats that as a failure too:
# a scanner nobody can hear from is not one to trust.
SAFEDEPS_SCAN_MARK=$(mktemp "${TMPDIR:-/tmp}/safedeps-scan.XXXXXX" 2>/dev/null) || SAFEDEPS_SCAN_MARK=""
# Private to this run (mktemp -d is 0700). Without it the lexer simply runs
# every time.
SAFEDEPS_LEX_CACHE=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-lex.XXXXXX" 2>/dev/null) || SAFEDEPS_LEX_CACHE=""
trap 'rm -f "${SAFEDEPS_SCAN_MARK:-}"; rm -rf "${SAFEDEPS_LEX_CACHE:-}"' EXIT

# Set once the gate below has passed, and exported so that anything reading the
# command after that point can be counted: scripts/measure/scan-failure-census.sh
# shims awk and reports every scan that runs with this set. Nothing in the hook
# reads it, so a value inherited from the caller changes no verdict; it is
# cleared here only so the census never counts someone else's.
unset SAFEDEPS_GATE_PASSED

guard_scan_failed() {
  [[ -z "${SAFEDEPS_SCAN_MARK}" || -s "${SAFEDEPS_SCAN_MARK}" ]]
}

# Whether a command could be a dependency install, judged without reading it:
# does it name a package manager's executable anywhere, in any case? Every
# recognizer needs one spelled out somewhere in the raw command -- blanking
# quotes and normalizing only ever remove text -- so this answers yes for
# everything any of them could have found, whatever the scan would have said.
#
# The vocabulary is SAFEDEPS_G_EXECUTABLES, so it cannot fall behind the
# grammar, and the test is bash's own regex, so it still answers when awk,
# grep, sed or fork is what failed. The version it replaces called grep and the
# candidate-text pipeline, which runs sed and the join awk; it went quiet with
# the tools it was standing in for, and a raw regex could not match everything
# the scanned recognizers match anyway (three review rounds, then a design
# judgment). It is loose on purpose: `go` and `py` appear in ordinary words, and
# a false "yes" here costs one UNDECIDED deny on a run where awk had already
# failed. A line continuation is taken out first, as the recognizers drop it:
# `pi\<newline>p install` runs pip and spells it nowhere. Taken out of quotes
# too, where it is no continuation, it can only add a "yes".
guard_looks_like_install_unscanned() {
  local re="(${SAFEDEPS_G_EXECUTABLES})" rc=0 joined="${COMMAND//\\$'\n'/}"
  shopt -s nocasematch
  [[ "${joined}" =~ ${re} ]] || rc=1
  shopt -u nocasematch
  return ${rc}
}

# The one UNDECIDED answer for a failed scan. It is the answer both when the
# gate cannot tell whether a command installs anything and when a scan failed
# before a finding was reported: a finding read from partly missing text is not
# a finding, and saying "detected" there teaches people that the gate cries
# wolf. $1 says which, for advisory.log.
guard_deny_undecided_scan() {
  log_advisory "pre-guard DENY: the command scanner failed ($1) — undecided, fail-closed. Command: ${COMMAND}"
  jq -nc '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:"safedeps: UNDECIDED, not unsafe — safedeps could not finish reading this command: a scanner step (awk, grep or sed) failed, or the command does not close (an open quote, a heredoc without its terminator). So it could not tell whether the command installs a dependency or what it would install. It is blocked fail-closed, and no finding is claimed. Close the command, or check that `echo x | awk 1` works, then retry."}}'
  exit 0
}

# Every deny that reports a finding calls this first.
guard_undecided_if_scan_failed() {
  guard_scan_failed || return 0
  guard_deny_undecided_scan "a finding was read from a failed scan"
}

# The gate. Every path that lets the command run passes here once, after its
# last scan and before its first side effect (pending state, the inert meta,
# the allow itself). If any scan failed, the verdicts above were read from
# missing text and none of them stands: a command that names a package
# manager is denied as UNDECIDED, anything else runs with the failure on
# record.
guard_settle_scan_failure() {
  if guard_scan_failed; then
    if guard_looks_like_install_unscanned; then
      guard_deny_undecided_scan "the command names a package manager"
    fi
    log_advisory "pre-guard: the command scanner failed; the command names no package manager and was allowed. Command: ${COMMAND}"
    printf 'safedeps: this command could not be fully read (a scanner step failed, or the command does not close). It names no package manager, so it was allowed. The failure is recorded in advisory.log.\n' >&2
  fi
  export SAFEDEPS_GATE_PASSED=1
}

# Whether the command closes in the current reading. A command that ends inside
# a quote, a heredoc body or a nested context is one the lexer could not
# finish, and whatever it swallowed went unread -- a comment apostrophe or an
# unterminated string used to hide every line after it. Returns 1 then. A
# heredoc left without its terminator is the ordinary case here, and the shell
# reads it to the end of input as data.
guard_check_command_reads() {
  local flags rc=0
  if ! flags=$(mktemp "${TMPDIR:-/tmp}/safedeps-lex.XXXXXX" 2>/dev/null); then
    guard_mark_reading_failed
    return 0
  fi
  SAFEDEPS_LEX_FLAGS="${flags}" shell_lex "${COMMAND}" scan "safedeps:command_reads" > /dev/null || true
  ! guard_lex_flag_set UNTERM "${flags}" || rc=1
  rm -f "${flags}"
  return ${rc}
}

# The ecosystem of ONE statement, read from the manager that starts it. The
# statement is recognize text already (command_candidate_start_texts), so it is
# read as it is: lexed again, a statement cut out of that view is a text no
# shell reads.
guard_segment_ecosystem() {
  local scan="$1"
  if echo "${scan}" | judge_grep -qEi "${SAFEDEPS_G_START}(npm|pnpm|pnpx|yarn|npx|bun|bunx)${SAFEDEPS_G_END}"; then
    printf 'npm'
  elif echo "${scan}" | judge_grep -qEi "${SAFEDEPS_G_START}(pip[0-9.]*|poetry|uv|uvx|pipx|pipenv|(python[0-9.]*|py)${SAFEDEPS_G_OPTS}[[:space:]]+-[A-Za-z0-9]*m[[:space:]]*pip)${SAFEDEPS_G_END}"; then
    printf 'pypi'
  elif echo "${scan}" | judge_grep -qEi "${SAFEDEPS_G_START}cargo${SAFEDEPS_G_END}"; then
    printf 'crates.io'
  elif echo "${scan}" | judge_grep -qEi "${SAFEDEPS_G_START}go${SAFEDEPS_G_END}"; then
    printf 'go'
  elif echo "${scan}" | judge_grep -qEi "${SAFEDEPS_G_START}(gem|bundle)${SAFEDEPS_G_END}"; then
    printf 'rubygems'
  elif echo "${scan}" | judge_grep -qEi "${SAFEDEPS_G_START}mvn${SAFEDEPS_G_END}"; then
    printf 'maven'
  elif echo "${scan}" | judge_grep -qEi "${SAFEDEPS_G_START}dotnet${SAFEDEPS_G_END}"; then
    printf 'nuget'
  fi
}

# The ecosystem of the first INSTALL statement in the command. It used to be the
# first manager named anywhere, so `npm run build && pip install x==1` read as
# npm, and every spec in the command was checked under that one ecosystem. Each
# spec now carries its own statement's ecosystem (guard_extract_specs); this one
# names the command for the npm project context and for messages.
guard_detect_ecosystem() {
  local cmd="$1"
  local seg eco i
  local -a segs=() ans=()

  # The statements are cut on the recognize view, where every statement start
  # is a separator, so a cut at `;` `|` `&` is a cut between statements. A
  # segment is a line of that cut (read reads one line), so a statement over
  # several lines is several segments.
  while IFS= read -r seg; do
    [[ "${seg}" =~ [^[:space:]] ]] || continue
    segs+=("${seg}")
  done < <(command_candidate_start_texts "${cmd}" | tr ';|&' '\n')
  # Every segment is asked at once and its answer read in order, as the loop
  # asked them one by one (recognized_dependency_install_each).
  SAFEDEPS_RDI_IN=("${segs[@]+"${segs[@]}"}")
  recognized_dependency_install_each
  ans=("${SAFEDEPS_RDI_ANS[@]+"${SAFEDEPS_RDI_ANS[@]}"}")
  for (( i = 0; i < ${#segs[@]}; i++ )); do
    case "${ans[i]:-2}" in
      0) ;;
      1) continue ;;
      *) recognized_dependency_install "${segs[i]}" || continue ;;
    esac
    eco=$(guard_segment_ecosystem "${segs[i]}")
    [[ -n "${eco}" ]] && { printf '%s' "${eco}"; return 0; }
  done
  printf ''
}

# True when <name> resolves to a binary the project already has AND the runner
# is one that prefers it (npx, npm exec/x, bunx, bun x, and npm init and bun
# create, which run through those). pnpm dlx, yarn dlx (and so pnpm create and
# yarn create), uvx and pipx run always fetch.
guard_runner_uses_local_bin() {
  local name="$1"
  [[ "${name}" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  [[ -x "${PROJECT_DIR:-.}/node_modules/.bin/${name}" ]]
}



guard_all_npm_installs_are_global() {
  # A global npm operation resolves into npm's global prefix, not the cwd
  # project. Project-scoped Yarn/overrides context must therefore not be mixed
  # into its ledger key. Otherwise an approved global package is denied merely
  # because the agent session happens to be anchored in a project with
  # overrides. Keep mixed local+global compound commands project-scoped: one
  # context cannot safely represent both operations.
  #
  # "Global" is the landing resolve_install_targets read from npm, the same one
  # the record and the effect gate use. This used to be a second reading, a
  # regex over `-g`/`--global`/`--location global`, so the ledger context and
  # the record could disagree about one install, and every spelling npm reads
  # that the regex did not (`-gf`, `-g=true`, `--locat=global`) was project
  # scoped here while it installed globally. An npm install inside a payload
  # (`sh -c`, `eval`) is not in that list; its landing is decided inside the
  # payload, so the command stays project-scoped, the direction that can deny
  # an approved package but never drops the project's context from one.
  local cmd="$1" targets="$2" kind target payload found=false

  while IFS=$'\035' read -r kind target _ _; do
    [[ "${kind}" == npm || "${kind}" == npm-unrecorded ]] || continue
    found=true
    [[ "${target}" == global ]] || return 1
  done <<< "${targets}"
  [[ "${found}" == true ]] || return 1
  while IFS= read -r payload; do
    [[ -n "${payload}" ]] || continue
    judge_grep -qEi "${SAFEDEPS_G_NPM_INSTALL_RE}" <<< "${payload}" && return 1
  done < <(command_payload_start_texts "${cmd}")
  return 0
}

# The package a `create` command fetches and runs, for the operand it names.
# Each manager rewrites the initializer its own way, and the rewritten name is
# the package the ledger has to judge: approving `vite@5.0.0` must not pass
# `create-vite@5.0.0`. Read from each manager's source, not guessed:
#
#   npm   lib/commands/init.js execCreate (npm 11.19.0; npm-init.md lists the
#         same table): `@usr` -> `@usr/create`, `@usr@2.0.0` ->
#         `@usr/create@2.0.0`, `foo` -> `create-foo`, `@usr/foo` ->
#         `@usr/create-foo`, the version kept. Always prefixed, so `npm init
#         create-vite` runs `create-create-vite`. A hosted git shorthand
#         `user/project` runs `user/create-project`.
#   pnpm  convertToCreateName (pnpm 10.28.1): the same, except a name that
#         already starts with `create-` is kept.
#   yarn  Yarn 2+ plugin-dlx create.ts: a name matching ^create(-|$) is kept.
#         Yarn 1 (create.js coerceCreatePackageName) always prefixes. Both are
#         printed where they differ, since the command does not say which yarn.
#   bun   bunx_command.rs add_create_prefix: always prefixed, scopes as npm.
#         create_command.rs hands a name to bunx only when it is not in its
#         built-in list and has no `/` outside a scope; `elysia`,
#         `elysia-buchta` and `stric` come from `@bun-examples/<name>`, `react`
#         and `next` only print a message, and `user/repo` is a GitHub
#         download, read as written.
#
# The names are left one per line in GUARD_CREATED, set in this shell rather
# than printed into a substitution, whose fork could fail and read as no name.
# A path names a local template or component, which is not a fetch, so it
# names nothing (npm refuses one as an unrecognized initializer). Anything else
# (a URL) is printed as written.
guard_create_identity() {
  local family="$1" spec="$2" scope="" name="" version=""
  GUARD_CREATED=""
  case "${family}" in
    bun)
      case "${spec}" in
        react|next) return 0 ;;
        elysia|elysia-buchta|stric) GUARD_CREATED+="@bun-examples/${spec}"$'\n'; return 0 ;;
      esac
      ;;
  esac
  case "${spec}" in
    .*|/*|~*) return 0 ;;
    *://*) GUARD_CREATED+="${spec}"$'\n'; return 0 ;;
  esac
  if [[ "${spec}" =~ ^(@[^/@]+)(@.*)?$ ]]; then
    GUARD_CREATED+="${BASH_REMATCH[1]}/create${BASH_REMATCH[2]}"$'\n'
    return 0
  fi
  if [[ "${spec}" =~ ^(@[^/@]+/)?([^/@]+)(@.*)?$ ]]; then
    scope="${BASH_REMATCH[1]}" name="${BASH_REMATCH[2]}" version="${BASH_REMATCH[3]}"
    case "${family}" in
      pnpm)
        [[ "${name}" == create-* ]] || name="create-${name}"
        ;;
      yarn)
        if [[ "${name}" =~ ^create(-|$) ]]; then
          GUARD_CREATED+="${scope}${name}${version}"$'\n'
        fi
        name="create-${name}"
        ;;
      *) name="create-${name}" ;;
    esac
    GUARD_CREATED+="${scope}${name}${version}"$'\n'
    return 0
  fi
  if [[ "${family}" == npm && "${spec}" =~ ^((github|gitlab|bitbucket|gist):)?([^/:@]+)/([^/#:]+)(#.*)?$ ]]; then
    GUARD_CREATED+="${BASH_REMATCH[1]}${BASH_REMATCH[3]}/create-${BASH_REMATCH[4]}${BASH_REMATCH[5]}"$'\n'
    return 0
  fi
  GUARD_CREATED+="${spec}"$'\n'
}


guard_names_package_without_spec() {
  # True when an install NAMES a package but carries no version spec, so the
  # ledger gate never ran for it. Used only to make that fact observable -- it
  # changes no verdict. Every such operand is left in UNGATED_OPERANDS as
  # `<ecosystem>:<operand>`, for the record to name.
  #
  # The unit is the operand, and it is the extractor's operand: the manager's
  # own grammar (safedeps_manager_read) gave it its role, and the extractor
  # wrote it down with its position (`O` lines) beside the positions it read a
  # spec from (`@ bound`). Nothing is parsed here. Three rounds of review each
  # found a record missing because this walk used to be a second parser that
  # asked the extractor "was this package pinned?" by name, and a fourth found
  # it recording a local package as a module because it read the words after a
  # runner itself. An operand is pinned when the extractor bound THIS word.
  #
  # So an extractor misreading shows up here instead of being buried: when it
  # reads `left-pad@npm:evil-pkg` as something else, the word is still
  # recorded.
  #
  # The boundary is what keeps this record readable. A record that fires on
  # routine installs becomes background noise, and background noise is the
  # same as no record. So an operand is left out when it is a local path (`.`,
  # `./x`, `/x`, `~/x`: the working tree, not a registry), a word that starts
  # with `-`, or a runner's package that the project already has as a binary
  # (`npx tsc`). A URL names a package and pins nothing, whatever `@` it
  # carries, and is recorded.
  #
  # A statement the effect gate reads -- an npm CLI install, whose record is
  # the PostToolUse hook's -- is exempt; the rest of the command is not.
  #
  # It reads GUARD_READINGS, the extractor's reading of the command that the
  # gate took its specs from (guard_extract_specs ... readings).
  local line f1 f2 f3 eco="" localbin=false gate_reads=false bound=" " ops=""
  local open=false
  UNGATED_OPERANDS=""

  while IFS= read -r line; do
    case "${line}" in
      S$'\t'*)
        [[ "${open}" == true ]] && guard_record_statement
        # Fields are cut with expansions, not `read <<<`: bash 3.2 writes a
        # temp file for every here-string, and this loop runs per line.
        line="${line#S$'\t'}"
        eco="${line%%$'\t'*}"; line="${line#*$'\t'}"
        localbin="${line%%$'\t'*}"; line="${line#*$'\t'}"
        gate_reads="${line%%$'\t'*}"
        bound=" " ops="" open=true
        ;;
      @$'\t'bound$'\t'*) bound+="${line##*$'\t'} " ;;
      O$'\t'*) ops+="${line#O$'\t'}"$'\n' ;;
    esac
  done <<< "${GUARD_READINGS}"
  [[ "${open}" == true ]] && guard_record_statement
  [[ -n "${UNGATED_OPERANDS}" ]]
}

# The record of one statement, as guard_names_package_without_spec read it:
# eco, localbin, gate_reads, bound and ops are the caller's. <ops> holds one
# `<position><TAB><role><TAB><text>` per operand.
guard_record_statement() {
  local op at role text
  [[ "${gate_reads}" == true ]] && return 0
  while IFS= read -r op; do
    [[ -n "${op}" ]] || continue
    at="${op%%$'\t'*}"; op="${op#*$'\t'}"
    role="${op%%$'\t'*}"; text="${op#*$'\t'}"
    [[ "${bound}" == *" ${at} "* ]] && continue
    # Maven's coordinate keeps its `-D` spelling in the record.
    [[ "${role}" == D ]] || case "${text}" in
      -*|.|..|./*|../*|/*|'~'|'~/'*) continue ;;
    esac
    # npx, npm exec, bunx and their kin run a binary the project already has
    # without fetching anything, so `npx tsc` in a TypeScript project is not
    # an install. Recording every `npx tsc` would bury the ones that matter.
    if [[ "${role}" == r && "${localbin}" == true ]] && guard_runner_uses_local_bin "${text}"; then
      continue
    fi
    guard_note_ungated "${eco}" "${text}"
  done <<< "${ops}"
  return 0
}


# Add `<ecosystem>:<operand>` to UNGATED_OPERANDS once.
guard_note_ungated() {
  local entry="$1:$2"
  # An empty operand names nothing. Nor does one that is only the lexer's mark
  # for blanks inside a word, which is what an empty word (`pnpm add ""
  # left-pad`) reads as: it was recorded as `npm: `.
  [[ -n "${2//[$'\002'[:space:]]/}" ]] || return 0
  [[ ", ${UNGATED_OPERANDS}, " == *", ${entry}, "* ]] && return 0
  UNGATED_OPERANDS="${UNGATED_OPERANDS:+${UNGATED_OPERANDS}, }${entry//$'\002'/ }"
}





# The one answer to "does the effect gate answer for this install statement":
# an npm CLI install, not a runner, that the lockfiles record. <kind> is a
# statement's field from resolve_install_targets; an .npmrc that keeps the
# install out of both lockfiles has made it `npm-unrecorded` there.
#
# Where the install lands is not asked here. It used to be: the statement had
# to land in PROJECT_DIR, and a statement whose landing the text read wrong was
# exempt and unread. Three validation rounds found such text, a `cd` that never
# ran, `command cd`, a symlinked member, and each was a silent pass, because a
# prediction that errs toward the exemption leaves nothing to notice it. So the
# landing only picks where the effect gate looks, and the PostToolUse hook
# records an install that left no trace there (settle_npm_trace)
# (safedeps/effect-gate-blind-to-lockless-npm-installs).
#
# The UNGATED exemption asks this and nothing else. It used to have its own
# answer, a list of flags that keep npm from writing package-lock.json
# (`--no-package-lock`, `-g`, ...), and a flag list is never finished:
# `--no-save` and `--save=false` were missing from it, so an unpinned install
# with either went unrecorded although the gate of that time did not read it.
# Since the gate reads npm's hidden lockfile as well, the same flags leave an
# install the gate does read, and a flag list would now record it as unread.
# What the gate reads is decided in one place, and the record follows it.
guard_effect_gate_reads() {
  [[ "$1" == npm ]]
}

# The statements the spec extractor reads, one per line as
# `<read>\t<rec>\037<words>`. <read> is `true` when the effect gate reads the
# install the statement belongs to (guard_effect_gate_reads), and `false`
# otherwise. <rec> is the statement as the recognizers read it, and <words> its
# words after the shell's quote removal, its prefixes left out; both come from
# one lexing of the command (the pieces view of shell_lex).
#
# The command's own statements come from <targets>, resolve_install_targets'
# list, so the extractor and the landing read the same statements and each one
# carries its landing with it. Joining two separate readings of a command was
# the defect behind three rounds of the UNGATED record (a pin found by name,
# then by ecosystem and name), and a statement found by position in a second
# split would be the same join.
#
# The lexer reads the quotes, the redirections and the cuts. Each used to have a
# reader of its own, and each reader had its own model of the shell's quoting:
# an awk that knew `'...'`, `"..."` and a backslash took the `>` in
# `pip install --log "$(echo ">'")" evil==1.0.0` for a redirection, and with it
# everything to the end of the line, so the pinned install passed unchecked; a
# sed before it read a redirection only at the start of a word, and missed
# `"x >'" ... 2>"'"`; and the cut at `;` `|` `&` read no quotes at all, so
# `pip install --log "a;b" evil==1.0.0` was two pieces and the second was not an
# install. The shell reads all three with one set of rules, and so does this.
# The statements were then normalized together, one per line, and lexed again;
# the lexing that cuts them now is the one lexing of the command.
#
# Payloads (`sh -c`, `eval`, a command substitution) follow, with <read> false:
# where a payload's install lands is decided inside the payload, and the
# landing does not read inside it. Each payload is lexed on its own, as the
# inner shell reads it, so one that its reader could not finish does not run
# into the next.
guard_extract_pieces() {
  local cmd="$1" targets="$2"
  local kind fields payload pieces
  local -a pls=()

  while IFS=$'\035' read -r kind _ _ _ fields; do
    [[ -n "${kind}" ]] || continue
    if guard_effect_gate_reads "${kind}"; then
      printf 'true\t%s\n' "${fields}"
    else
      printf 'false\t%s\n' "${fields}"
    fi
  done <<< "${targets}"

  command_payload_raw_texts "${cmd}"
  pls=(${PAYLOADS[@]+"${PAYLOADS[@]}"})
  for payload in ${pls[@]+"${pls[@]}"}; do
    [[ "${payload}" =~ [^[:space:]] ]] || continue
    pieces=$(shell_lex "${payload}" pieces "safedeps:payload_pieces") || pieces=""
    printf '%s\n' "${pieces}" | LC_ALL=C awk -F'\037' '
      # safedeps:payload_pieces (scripts/measure/scan-failure-census.sh keys on this line)
      $0 == "!" { bad = 1; next }
      NF >= 5 { printf "false\t%s\037%s\n", $5, $4 }
      END { exit bad ? 3 : 0 }' || guard_mark_reading_failed
  done
  return 0
}

# The ecosystem a manager installs from, in GUARD_ECO (empty for none).
guard_family_ecosystem() {
  GUARD_ECO=""
  case "$1" in
    npm|npx|pnpm|pnpx|yarn|bun|bunx) GUARD_ECO=npm ;;
    pip|uv|uvx|pipx|poetry|pipenv) GUARD_ECO=pypi ;;
    cargo) GUARD_ECO=crates.io ;;
    go) GUARD_ECO=go ;;
    gem|bundle) GUARD_ECO=rubygems ;;
    mvn) GUARD_ECO=maven ;;
    dotnet) GUARD_ECO=nuget ;;
  esac
}

# A word as its package manager reads it. A blank or a grouping character
# inside a word is \002 (the lexer's pieces view), and the empty word is \002
# alone. A manager reads past the blanks at the ends of an argument (`pip
# install "evil==1.0.0 "` pins evil), and a Python requirement reads past every
# blank in it: PEP 508 allows `evil ==1.0.0`, and pip's parser (packaging,
# measured) reads it as a pin. Read as written, each was an unpinned name and
# the pin passed unchecked. Sets GUARD_WORD.
guard_word_as_read() {
  local eco="$1" word="$2"
  if [[ "${eco}" == pypi ]]; then
    word="${word//$'\002'/}"
  else
    while [[ "${word}" == $'\002'* ]]; do word="${word#$'\002'}"; done
    while [[ "${word}" == *$'\002' ]]; do word="${word%$'\002'}"; done
  fi
  [[ -n "${word}" ]] || word=$'\002'
  GUARD_WORD="${word}"
}

# The specs one operand carries, as `<pkg><TAB><spec>` lines in GUARD_SPECS:
# the reading of a package name with its version, per ecosystem.
#   go     a module path with its version, whole: `go get example.com/x@v1` is
#          `example.com/x`, never `x` (which approves, and then lets any
#          `.../x@v1` through).
#   pypi   `name==version` and `name===version` (arbitrary equality, also an
#          exact pin) after its extras are removed (`evil[x]==1.0.0` installs
#          evil); a wildcard such as `==1.0.*` is no pin. `name@version` as
#          poetry and uv write it.
#   rubygems `name:version`, which gem reads as the name and a requirement
#          (Gem::Command#extract_gem_name_and_version); a version alone, or
#          after `=`, is a pin. Read as a name, it was recorded as one and
#          the pin went unchecked.
#   others `name@spec` and `@scope/name@spec`, and an npm alias
#          (`left-pad@npm:evil-pkg@1`) read as its target, which is what is
#          fetched. A name may start with a digit (`7zip-bin`, `3to2`). An
#          email-shaped word (`user@domain.tld`) is no spec.
# Every one runs in this shell: a reader that is a process can fail, and a
# failed reader reads as "no spec".
guard_word_specs() {
  local eco="$1" word="$2" rest token pkg spec
  GUARD_SPECS=""
  if [[ "${eco}" == go ]]; then
    [[ "${word}" =~ ^[A-Za-z0-9][A-Za-z0-9._~/-]*@[A-Za-z0-9._+~-]+$ ]] || return 0
    GUARD_SPECS="${word%@*}"$'\t'"${word##*@}"
    return 0
  fi
  if [[ "${eco}" == pypi ]]; then
    while [[ "${word}" =~ \[[^]\ ]*\] ]]; do word="${word/"${BASH_REMATCH[0]}"/}"; done
    if [[ "${word}" =~ ^([A-Za-z0-9][A-Za-z0-9._-]*)===?([A-Za-z0-9][A-Za-z0-9._+!~-]*)$ ]]; then
      GUARD_SPECS="${BASH_REMATCH[1]}"$'\t'"${BASH_REMATCH[2]}"
      return 0
    fi
  fi
  if [[ "${eco}" == rubygems && "${word}" =~ ^([A-Za-z0-9][A-Za-z0-9._-]*):=?([0-9]+([.][0-9A-Za-z]+)*(-[0-9A-Za-z-]+([.][0-9A-Za-z-]+)*)?)$ ]]; then
    GUARD_SPECS="${BASH_REMATCH[1]}"$'\t'"${BASH_REMATCH[2]}"
    return 0
  fi
  if [[ "${eco}" == npm && "${word}" =~ ^(@[A-Za-z0-9._~-]+/)?[A-Za-z0-9._~-]+@[Nn][Pp][Mm]:(.*)$ ]]; then
    word="${BASH_REMATCH[2]}"
  fi
  rest="${word}"
  while [[ "${rest}" =~ (@[a-zA-Z0-9._/-]+/)?[a-zA-Z0-9][a-zA-Z0-9._-]*@[a-zA-Z0-9._^~|\<\>=*+-]+ ]]; do
    token="${BASH_REMATCH[0]}"
    rest="${rest#*"${token}"}"
    [[ "${token}" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] && continue
    if [[ "${token}" =~ ^(@[^@]+)@(.+)$ ]]; then
      pkg="${BASH_REMATCH[1]}" spec="${BASH_REMATCH[2]}"
    else
      pkg="${token%@*}" spec="${token##*@}"
    fi
    GUARD_SPECS+="${GUARD_SPECS:+$'\n'}${pkg}"$'\t'"${spec}"
  done
  return 0
}

guard_extract_specs() {
  # Echo one "eco<TAB>pkg<TAB>spec" line per operand genuinely being installed.
  # Which words are operands is the manager's grammar (safedeps_manager_read in
  # lib/install-grammar.sh): a statement it does not read as an install, a
  # runner or a create contributes nothing, an option's value is never an
  # operand, a runner contributes the package it runs and the packages its
  # options name, never the program's arguments (`npx wrangler ...
  # ops@example.test`), and a version option (`gem install rake -v 13.0.0`)
  # pins every operand of its command. Each spec carries the ecosystem of the
  # statement it came from: `npm run x && pip install evil==1` checks evil as a
  # PyPI package.
  #
  # <targets> is resolve_install_targets' list for <cmd>; the statements are
  # read from it (guard_extract_pieces).
  #
  # With `readings` as the third argument, each statement it reads is also
  # described for the UNGATED record: `S<TAB><eco><TAB><localbin><TAB><read>`,
  # then an `O<TAB><position><TAB><role><TAB><text>` line per operand and an
  # `@<TAB>bound<TAB><position>` line per operand a spec was read from, beside
  # the spec lines. <read> says whether the effect gate reads the statement's
  # install. The spec lines are the same in both modes; the gate reads only
  # those, so the other lines cannot move a verdict.
  local cmd="$1" targets="$2" mode="${3:-}"
  local seg words gate_reads eco family k role text out line versions spec_line created p
  local -a w=() roles=() texts=() p_reads=() p_segs=() p_words=() p_ans=()

  # The pieces carry no tab, so the tab and \037 cut the three fields. <seg>
  # is the statement as the recognizers read it, from the same lexing as its
  # words. They are read whole first, so whether each is an install is asked
  # of all of them at once (recognized_dependency_install_each) and read
  # below in order, where it was asked one piece at a time.
  while IFS=$'\t\037' read -r gate_reads seg words; do
    [[ "${seg}" =~ [^[:space:]] ]] || continue
    p_reads+=("${gate_reads}") p_segs+=("${seg}") p_words+=("${words}")
  done < <(guard_extract_pieces "${cmd}" "${targets}")
  SAFEDEPS_RDI_IN=("${p_segs[@]+"${p_segs[@]}"}")
  recognized_dependency_install_each
  p_ans=("${SAFEDEPS_RDI_ANS[@]+"${SAFEDEPS_RDI_ANS[@]}"}")

  for (( p = 0; p < ${#p_segs[@]}; p++ )); do
    gate_reads="${p_reads[p]}" seg="${p_segs[p]}" words="${p_words[p]}"
    case "${p_ans[p]:-2}" in
      0) ;;
      1) continue ;;
      *) recognized_dependency_install "${seg}" || continue ;;
    esac
    # Grouping characters are the shell's (`(npm i x)`, `{ pip install y; }`).
    words="${words//[(){\}]/ }"
    set -f
    # shellcheck disable=SC2206
    w=( ${words} )
    set +f
    [[ ${#w[@]} -gt 0 ]] || continue
    safedeps_manager_read "${w[@]}" || guard_mark_reading_failed
    [[ "${SAFEDEPS_G_M_KIND}" != none ]] || continue
    family="${SAFEDEPS_G_M_FAMILY}"
    guard_family_ecosystem "${family}"
    eco="${GUARD_ECO}"
    [[ -n "${eco}" ]] || continue
    roles=("${SAFEDEPS_G_M_ROLE[@]}") texts=("${SAFEDEPS_G_M_TEXT[@]}")
    out="" versions=""
    [[ "${mode}" != readings ]] || out="S"$'\t'"${eco}"$'\t'"${SAFEDEPS_G_M_LOCALBIN}"$'\t'"${gate_reads}"$'\n'
    for (( k = 0; k < ${#w[@]}; k++ )); do
      [[ "${roles[k]}" == V ]] || continue
      guard_word_as_read "${eco}" "${texts[k]:-${w[k]}}"
      versions+="${GUARD_WORD}"$'\n'
    done
    for (( k = 0; k < ${#w[@]}; k++ )); do
      role="${roles[k]}"
      case "${role}" in o|r|C|p|w|D) ;; *) continue ;; esac
      guard_word_as_read "${eco}" "${texts[k]:-${w[k]}}"
      text="${GUARD_WORD}"
      # The package a word names, for the record as for the spec: a Python
      # requirement without its extras (`requests[socks]` installs requests),
      # an npm alias as its target (`left-pad@npm:evil-pkg` fetches evil-pkg).
      if [[ "${eco}" == pypi ]]; then
        while [[ "${text}" =~ \[[^]\ ]*\] ]]; do text="${text/"${BASH_REMATCH[0]}"/}"; done
      elif [[ "${eco}" == npm && "${text}" =~ ^(@[A-Za-z0-9._~-]+/)?[A-Za-z0-9._~-]+@[Nn][Pp][Mm]:(.+)$ ]]; then
        text="${BASH_REMATCH[2]}"
      fi
      # npm link links a directory or a file as written and installs every
      # other argument (lib/commands/link.js:92-104, read with npa).
      if [[ "${SAFEDEPS_G_M_KIND}" == link ]] && safedeps_npa_is_local "${text}"; then
        continue
      fi
      if [[ "${role}" == D ]]; then
        # -Dartifact=groupId:artifactId:version[:packaging[:classifier]]; OSV
        # names a Maven package groupId:artifactId. Two fields pin nothing.
        text="-D${text}"
        if [[ "${text}" =~ ^-Dartifact=([^:]+):([^:]+):([^:]+) ]]; then
          out+="${eco}"$'\t'"${BASH_REMATCH[1]}:${BASH_REMATCH[2]}"$'\t'"${BASH_REMATCH[3]}"$'\n'
          [[ "${mode}" != readings ]] || out+="@"$'\t'"bound"$'\t'"${k}"$'\n'
        fi
        [[ "${mode}" != readings ]] || out+="O"$'\t'"${k}"$'\t'"${role}"$'\t'"${text}"$'\n'
        continue
      fi
      # A create runs the initializer under the name its manager gives it.
      if [[ "${role}" == C ]]; then
        case "${family}" in
          npm|npx) guard_create_identity npm "${text}" ;;
          pnpm|pnpx) guard_create_identity pnpm "${text}" ;;
          bun|bunx) guard_create_identity bun "${text}" ;;
          *) guard_create_identity "${family}" "${text}" ;;
        esac
        created="${GUARD_CREATED}"
        while IFS= read -r line; do
          [[ -n "${line}" ]] || continue
          guard_word_specs "${eco}" "${line}"
          while IFS= read -r spec_line; do
            [[ -n "${spec_line}" ]] || continue
            out+="${eco}"$'\t'"${spec_line}"$'\n'
            [[ "${mode}" != readings ]] || out+="@"$'\t'"bound"$'\t'"${k}"$'\n'
          done <<< "${GUARD_SPECS}"
          [[ "${mode}" != readings ]] || out+="O"$'\t'"${k}"$'\t'r$'\t'"${line}"$'\n'
        done <<< "${created}"
        continue
      fi
      guard_word_specs "${eco}" "${text}"
      while IFS= read -r spec_line; do
        [[ -n "${spec_line}" ]] || continue
        out+="${eco}"$'\t'"${spec_line}"$'\n'
        [[ "${mode}" != readings ]] || out+="@"$'\t'"bound"$'\t'"${k}"$'\n'
      done <<< "${GUARD_SPECS}"
      # A version option pins every operand of its command.
      if [[ "${role}" == o && -n "${versions}" ]]; then
        while IFS= read -r line; do
          [[ -n "${line}" ]] || continue
          out+="${eco}"$'\t'"${text}"$'\t'"${line}"$'\n'
          [[ "${mode}" != readings ]] || out+="@"$'\t'"bound"$'\t'"${k}"$'\n'
        done <<< "${versions}"
      fi
      [[ "${mode}" != readings ]] || out+="O"$'\t'"${k}"$'\t'"${role}"$'\t'"${text}"$'\n'
    done
    printf '%s' "${out}"
  done
}

# How the current reading would make the command's npm installs inert, as one
# value the readings can be compared on: none, downgrade, or `rewrite` (with
# ` asked`, ` unverified` and ` floor` when they apply, or ` release` alone
# when only the release's rewrite was written) and the rewritten command on the
# next line.
guard_reading_inert() {
  local outcome=none updated="" rc=0
  if command_is_injectable_npm_install "${COMMAND}"; then
    # Place `--ignore-scripts` after the last argument of each npm install, in
    # its own statement. Appending to the end of the whole string would land
    # it on the trailing statement (e.g. `npm install evil && npm run build
    # --ignore-scripts`), leaving the install itself running lifecycle scripts
    # (finding #7). Right after the verb alone, it lost to any later word that
    # sets the option, since npm keeps the last value; it now goes there too,
    # as a floor under the reading (inert_flag_offsets). Whether a statement already
    # carries the flag is read from that statement's own arguments: the bare
    # text anywhere in the command used to skip the rewrite for
    # `--ignore-scripts=false` and for `&& echo --ignore-scripts`, with no
    # record. scripts/test/smoke.sh pins the landing spot. A failed rewrite
    # marks the reading, so the gate settles it instead of reading it as
    # nothing to do.
    updated=$(inert_rewrite_in_place "${COMMAND}") || rc=$?
    case "${rc}" in
      0|5|6|7|8|9|10|11) ;;
      3|4) updated="" ;;
      *) guard_mark_reading_failed; updated="" ;;
    esac
    if (( rc == 4 )); then
      outcome=none
    elif [[ -z "${updated}" || "${updated}" == "${COMMAND}" ]]; then
      # The rewrite did not land -- never blind-append to a compound command.
      # Downgrade to detect-and-rollback (the effect gate still verifies the
      # closure), recorded once the command is known to run: the inert
      # guarantee is observably relaxed, never silently.
      outcome=downgrade
      # The floor holds on this path too, whatever stopped the rewrite (an
      # install in a script handed to a shell that no offset reaches, a heredoc
      # fed to a shell, no verb found, a failed reading): where the release
      # appended its flag to the command, the command gets that rewrite. It
      # used to get none, and `npm ci eval "\npm"` ran its scripts where the
      # release's `npm ci eval "\npm" --ignore-scripts` ran none.
      if inert_release_appends "${COMMAND}"; then
        outcome="rewrite release"$'\n'"${COMMAND} --ignore-scripts"
      fi
    else
      outcome=rewrite
      if (( rc > 4 )); then
        (( ((rc - 4) & 1) == 0 )) || outcome+=" asked"
        (( ((rc - 4) & 2) == 0 )) || outcome+=" unverified"
        (( ((rc - 4) & 4) == 0 )) || outcome+=" floor"
      fi
      outcome+=$'\n'"${updated}"
    fi
  fi
  printf -v "GUARD_INERT_$1" '%s' "${outcome}"
}

guard_deny_inert_readings_differ() {
  log_advisory "pre-guard DENY: the readings (${GUARD_READING_SET}) put this command's npm installs in different places, so no single --ignore-scripts rewrite is inert for every shell — undecided, fail-closed. Command: ${COMMAND}"
  jq -nc '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:"safedeps: UNDECIDED, not unsafe — bash, zsh and dash read the npm installs in this command in different places (a quote, an arithmetic expression or a parameter default that one shell closes where another does not). safedeps makes an npm install inert by adding --ignore-scripts after it, and here no single edit lands on the install for every shell without changing text another shell reads as data. It is blocked fail-closed, and no finding is claimed. Rewrite the command so its quoting reads the same in every shell (for example, move the npm install onto its own line, away from the quote), then retry."}}'
  exit 0
}

# --- The readings ---
#
# A reading is a shell: bash, zsh or dash (see shell_lex). Every reader of the
# command below reads it under one reading at a time, and the gate judges the
# command under every reading a shell could give it:
#
#   - The bash reading runs first. While it lexes, every place where the
#     readings differ says DIVERGE. Only then do the zsh and dash readings run;
#     the readings agree byte for byte up to the first such place, so a command
#     that never reaches one reads the same in all three.
#   - A finding in any reading is a finding: the install candidates, the hidden
#     and piped installs, the targets and the specs are the union.
#   - UNDECIDED needs a reading that failed a step, or no reading that closes.
#   - Rewriting the command (`--ignore-scripts`) needs every reading to agree
#     where the npm installs are (guard_reading_inert). A read-only side effect
#     takes the union; a change to the text cannot be made for one shell
#     without editing what another reads as data.
#
# The variable is set here and nowhere else. Splitting one reading's output and
# lexing it again under another reading's rules is how a line zsh runs was
# hidden again one step after the zsh reading had exposed it (form SL1); a
# reader that asks for a reading of its own fails the reading instead.
SAFEDEPS_READING=""

# Per Claude Code / Codex CLI hook spec, `cwd` is top-level. Fall back to `pwd`
# only when the hook is invoked outside the engine (manual test, no stdin payload).
CWD_DIR=$(echo "${INPUT}" | jq -r '.cwd // empty' 2>/dev/null)
if [[ -z "${CWD_DIR}" ]]; then
  CWD_DIR=$(pwd)
fi
# Codex sends turn_id; Claude does not. Asked once the command is an install
# candidate (below), so an ordinary command does not pay for one more jq.
GUARD_IS_CODEX=false

# Where the bash reading says DIVERGE. Without the file the gate cannot tell
# whether the readings differ, so it reads all three.
SAFEDEPS_LEX_DIVERGE=""
if [[ -n "${SAFEDEPS_LEX_CACHE}" ]]; then
  SAFEDEPS_LEX_DIVERGE="${SAFEDEPS_LEX_CACHE}/diverge"
  : > "${SAFEDEPS_LEX_DIVERGE}" 2>/dev/null || SAFEDEPS_LEX_DIVERGE=""
fi
guard_readings_diverge() {
  [[ -z "${SAFEDEPS_LEX_DIVERGE}" || -s "${SAFEDEPS_LEX_DIVERGE}" ]]
}

GUARD_READING_SET=""
GUARD_READ_CLOSED=false
GUARD_ANY_INSTALL=false
PIPED_BESIDE_VISIBLE=false
# Per reading, read through ${!name}.
# shellcheck disable=SC2034
GUARD_HIDDEN_bash=false GUARD_HIDDEN_zsh=false GUARD_HIDDEN_dash=false

# The detection half of one reading: does the command close, and is it an
# install the gate has to judge.
guard_reading_detect() {
  SAFEDEPS_READING="$1"
  GUARD_READING_SET="${GUARD_READING_SET:+${GUARD_READING_SET} }$1"
  guard_check_command_reads && GUARD_READ_CLOSED=true
  if command_is_dependency_install "${COMMAND}"; then
    GUARD_ANY_INSTALL=true
    # A visible install used to switch the hidden-install check off. It is a
    # hidden install like any other, and it is denied where the others are,
    # after the snapshot: every path between here and there is a deny.
    if command_pipes_install_to_shell "${COMMAND}"; then
      PIPED_BESIDE_VISIBLE=true
      printf -v "GUARD_HIDDEN_$1" '%s' true
    fi
  # Catch indirection patterns that hide install commands (V-002)
  elif command_hides_dependency_install "${COMMAND}"; then
    GUARD_ANY_INSTALL=true
    printf -v "GUARD_HIDDEN_$1" '%s' true
  fi
  SAFEDEPS_READING=""
}

INSTALL_TARGETS=""
LEDGER_ECOSYSTEM=""
LEDGER_SPECS=()
GUARD_READINGS=""
GUARD_HIDDEN_UNREDUCED=false
GUARD_UNGATED=""
GUARD_UNGATED_ECOSYSTEM=""
GUARD_NPM_SEEN=false
GUARD_NPM_ALL_GLOBAL=true
NPM_TRACE_WANTED=false
ATTRIBUTION=""
# shellcheck disable=SC2034
GUARD_INERT_bash="" GUARD_INERT_zsh="" GUARD_INERT_dash=""

# The judging half of one reading: where its installs land, what they install,
# and how it would make them inert. Each fact joins the others' the way its
# consumer needs (see "The readings" above).
guard_reading_facts() {
  local reading="$1" targets eco line readings="" specs=0 existing hidden
  SAFEDEPS_READING="${reading}"
  targets=$(resolve_install_targets "${COMMAND}" "${CWD_DIR}")
  [[ -z "${targets}" ]] || INSTALL_TARGETS+="${targets}"$'\n'
  eco=$(guard_detect_ecosystem "${COMMAND}")
  [[ -n "${LEDGER_ECOSYSTEM}" ]] || LEDGER_ECOSYSTEM="${eco}"
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    readings+="${line}"$'\n'
    case "${line}" in
      S$'\t'*|O$'\t'*|@$'\t'*) continue ;;
    esac
    specs=$(( specs + 1 ))
    if [[ ${#LEDGER_SPECS[@]} -gt 0 ]]; then
      for existing in "${LEDGER_SPECS[@]}"; do
        [[ "${existing}" == "${line}" ]] && continue 2
      done
    fi
    LEDGER_SPECS+=("${line}")
  done < <(guard_extract_specs "${COMMAND}" "${targets}" readings)
  GUARD_READINGS+="${readings}"
  printf -v "GUARD_READINGS_${reading}" '%s' "${readings}"
  printf -v "GUARD_ECOSYSTEM_${reading}" '%s' "${eco}"

  # A hidden install has to reduce to specs in the reading that hid it: the
  # specs another reading found are not this one's.
  hidden="GUARD_HIDDEN_${reading}"
  if [[ "${!hidden}" == true ]] && [[ -z "${eco}" || ${specs} -eq 0 ]]; then
    GUARD_HIDDEN_UNREDUCED=true
  fi

  # The npm context key leaves the project out only when every npm install in
  # every reading is global.
  if [[ $'\n'"${targets}" == *$'\n'npm$'\035'* || $'\n'"${targets}" == *$'\n'npm-unrecorded$'\035'* ]]; then
    GUARD_NPM_SEEN=true
    guard_all_npm_installs_are_global "${COMMAND}" "${targets}" || GUARD_NPM_ALL_GLOBAL=false
  fi

  SAFEDEPS_READING=""
}

# What only a command that gets past the ledger needs, per reading: how it
# would be made inert, and what the PostToolUse hook needs to tell whether its
# npm installs were read. Asked after the denies, as before the readings were
# shells: asking it first made every denied npm install pay for a rewrite it
# never got (measured, +15% on a denied install).
guard_reading_effects() {
  SAFEDEPS_READING="$1"
  [[ "${GUARD_IS_CODEX}" == true ]] || guard_reading_inert "$1"
  if guard_command_has_npm_install "${COMMAND}"; then
    NPM_TRACE_WANTED=true
    [[ -n "${ATTRIBUTION}" ]] || ATTRIBUTION=$(guard_npm_writers_unattributable "${COMMAND}")
  fi
  SAFEDEPS_READING=""
}

# The UNGATED record walks one reading's statements, after PROJECT_DIR is
# known: whether a runner's binary is local is asked there.
guard_reading_ungated() {
  local reading="$1" hidden="GUARD_HIDDEN_$1" readings="GUARD_READINGS_$1" eco="GUARD_ECOSYSTEM_$1"
  [[ "${!hidden}" != true && -n "${!eco}" ]] || return 0
  SAFEDEPS_READING="${reading}"
  if GUARD_READINGS="${!readings}" guard_names_package_without_spec; then
    [[ -n "${GUARD_UNGATED_ECOSYSTEM}" ]] || GUARD_UNGATED_ECOSYSTEM="${!eco}"
    GUARD_UNGATED="${GUARD_UNGATED:+${GUARD_UNGATED}, }${UNGATED_OPERANDS}"
  fi
  SAFEDEPS_READING=""
}

guard_reading_detect bash
if guard_readings_diverge; then
  guard_reading_detect zsh
  guard_reading_detect dash
fi
# Unread means no reading closes: a command that closes under another reading
# is one that shell runs.
[[ "${GUARD_READ_CLOSED}" == true ]] || guard_mark_reading_failed

# The PostToolUse backstop judges commands this hook did not read as an install
# but that match the backstop's pattern (SAFEDEPS_G_BACKSTOP_RE): `npm run
# deps:install`, and also `grep -n "npm install" README.md`. Its rollback
# removes node_modules, so it rolls back only where it sees this command's trace
# in the project's node tree, and for that it needs a record from just before
# the command: the inode and status change time of each npm lockfile, the inode
# of node_modules, and a baseline file touched now for the walk of node_modules.
#
# The baseline is not set back where the filesystems keep time below one
# second. Set back two seconds, it counted a pull made 0.3 seconds before a
# grep as the grep's trace, and the grep removed node_modules (lumi r1 R1); two
# Bash calls in one message are 0.16 seconds apart. Where the baseline file or
# any part of the project's node tree keeps whole seconds, a write in the
# second the baseline was touched in would not be newer than it, so there the
# baseline is set two seconds back as before. Every part has to show a time
# below the second, the target of a linked one included: a tree whose lockfile
# kept nanoseconds and whose node_modules was on a whole-second mount was read
# as subsecond when one part was enough, and the walk missed a write in the
# baseline's second (lumi r2 P3, 2 of 5 on a real mount). Which one applied is
# in the entry.
#
# The entry belongs to this tool call (safedeps_call_base in
# lib/gates/call-id.sh), and only this call's post hook reads it. A call whose
# post hook never runs (a call the user denied after this hook let it through,
# one cancelled while it runs, or a failed one on Claude Code where
# PostToolUseFailure is not registered) leaves its entry to the age sweep, and
# no other call reads it.
#
# This decides no verdict and runs after the gate. Anything that fails here
# leaves no entry, and the backstop counts a command with no entry as traced,
# which is what it did before there were entries. So the grep is not a judgment
# reading (judge_grep), and there is nothing for the gate to settle.
guard_backstop_trace_baseline() {
  local dir dir_hash entry_dir base id at stamp entry rel resolution=seconds lock hidden tree present=0 subsecond=0
  [[ -n "${SAFEDEPS_G_BACKSTOP_RE:-}" ]] || return 0
  printf '%s' "${COMMAND}" | grep -qiE "${SAFEDEPS_G_BACKSTOP_RE}" 2>/dev/null || return 0
  local lib="${BASH_SOURCE[0]%/*}/../lib/gates/backstop-trace.sh"
  [[ -r "${lib}" ]] || return 0
  # shellcheck source=../lib/gates/backstop-trace.sh
  source "${lib}" || return 0
  id=$(safedeps_call_id "${INPUT}") || return 0
  # The cwd as the PostToolUse hook resolves it, so the key is the one it builds.
  dir="${CWD_DIR}"
  if command -v realpath >/dev/null 2>&1; then
    dir=$(realpath "${dir}" 2>/dev/null || printf '%s' "${dir}")
  elif command -v readlink >/dev/null 2>&1; then
    dir=$(readlink -f "${dir}" 2>/dev/null || printf '%s' "${dir}")
  fi
  dir_hash=$(compute_dir_hash "${dir}")
  entry_dir="${GUARD_DIR}/pending/backstop"
  base=$(safedeps_call_base "${entry_dir}" "${id}") || return 0
  mkdir -p "${entry_dir}" 2>/dev/null || return 0
  find "${entry_dir}" -type f -mmin +1440 -delete 2>/dev/null || true
  lock=$(safedeps_tree_inode "${dir}/package-lock.json")
  hidden=$(safedeps_tree_inode "${dir}/node_modules/.package-lock.json")
  tree=$(safedeps_tree_inode "${dir}/node_modules")
  # Whether the project's node tree keeps time below one second, read from what
  # is there: a whole-second filesystem prints zeros below the second.
  for rel in package-lock.json node_modules/.package-lock.json node_modules; do
    [[ -e "${dir}/${rel}" || -L "${dir}/${rel}" ]] || continue
    present=$((present + 1))
    safedeps_clock_has_subsecond "$(safedeps_tree_clock "${dir}/${rel}")" && subsecond=$((subsecond + 1))
  done
  touch "${base}.trace" 2>/dev/null || return 0
  if (( present > 0 && subsecond == present )) \
    && safedeps_clock_has_subsecond "$(safedeps_file_clock "${base}.trace" m)"; then
    resolution=subsecond
  else
    at=$(( $(date +%s) - 2 ))
    stamp=$(date -r "${at}" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@${at}" +%Y%m%d%H%M.%S 2>/dev/null) \
      && touch -t "${stamp}" "${base}.trace" 2>/dev/null \
      || { rm -f "${base}.trace"; return 0; }
  fi
  entry=$(jq -nc --arg key "$(compute_pending_key "${dir_hash}" "${COMMAND}")" \
    --arg baseline "${base}.trace" --arg resolution "${resolution}" \
    --arg lock "${lock}" --arg hidden "${hidden}" --arg tree "${tree}" \
    --arg lock_clock "$(safedeps_tree_clock "${dir}/package-lock.json")" \
    --arg hidden_clock "$(safedeps_tree_clock "${dir}/node_modules/.package-lock.json")" \
    '{key: $key, baseline: $baseline, resolution: $resolution,
      inodes: {"package-lock.json": $lock, "node_modules/.package-lock.json": $hidden, node_modules: $tree},
      clocks: {"package-lock.json": $lock_clock, "node_modules/.package-lock.json": $hidden_clock}}' 2>/dev/null) \
    && write_state_file "${base}.json" "${entry}" 2>/dev/null \
    || rm -f "${base}.trace"
}

if [[ "${GUARD_ANY_INSTALL}" != true ]]; then
  guard_settle_scan_failure
  guard_backstop_trace_baseline || true
  exit 0
fi

jq -e 'has("turn_id")' <<< "${INPUT}" >/dev/null 2>&1 && GUARD_IS_CODEX=true
for guard_reading in ${GUARD_READING_SET}; do
  guard_reading_facts "${guard_reading}"
done
# A place where the readings differ first met while judging (in a payload, say)
# brings the other readings in now.
if [[ "${GUARD_READING_SET}" == bash ]] && guard_readings_diverge; then
  for guard_reading in zsh dash; do
    guard_reading_detect "${guard_reading}"
    guard_reading_facts "${guard_reading}"
  done
fi

# --- Reorg Guard Activated ---

# Resolve the actual install target: a relocation flag or an earlier `cd`
# moves the install away from cwd (finding #3; resolve_install_targets says
# which). Snapshot + effect-gate must follow the real target, while the
# PostToolUse pending-key still keys on cwd (post-verify only knows cwd) — so
# KEY_DIR_HASH (cwd) and DIR_HASH (install dir) are tracked separately below.
# The first install statement with a known, non-global target decides. That is
# where the effect gate looks; whether an npm install was there is the
# PostToolUse hook's to say, from the trace it finds (settle_npm_trace).
PROJECT_DIR="${CWD_DIR}"
# `target` when a statement named the directory, `cwd` when none did and the
# gate looks in the cwd for want of anything better.
PROJECT_DIR_FROM=cwd
# Which registry the install that chose PROJECT_DIR fetches from, as npm
# answered it beside where it lands (lib/npm/ask.sh, the fetch facts). The
# PostToolUse hook reads it from the pending state: a source the lockfiles
# record on the public registry is the public registry's only where npm says
# it fetched from there.
PROJECT_FETCH=""
PROJECT_FETCH_WHY="no npm install in this command named where it lands"
while IFS=$'\035' read -r _ install_target install_why install_fetch _; do
  [[ -n "${install_target}" && "${install_target}" != "?" && "${install_target}" != global ]] || continue
  PROJECT_DIR="${install_target}"
  PROJECT_DIR_FROM=target
  PROJECT_FETCH="${install_fetch}"
  PROJECT_FETCH_WHY="${install_why:-npm was not asked}"
  break
done <<< "${INSTALL_TARGETS}"
# An .npmrc that keeps an install off the record is not text in the command, so
# the record has to say which file did it; the UNGATED line alone would point at
# a command that looks like an ordinary project install. Each reason once,
# however many readings gave it. npm's registry answer says why it is missing
# the same way.
install_whys=$'\n'
while IFS=$'\035' read -r _ _ install_why install_fetch _; do
  if [[ "${install_fetch}" == '{"unknown":'* ]]; then
    install_why="${install_why:+${install_why}$'\n'}$(jq -r '.unknown' <<< "${install_fetch}" 2>/dev/null || printf 'npm did not say which registry this install fetches from')"
  fi
  [[ -n "${install_why}" ]] || continue
  while IFS= read -r install_why; do
    [[ -n "${install_why}" ]] || continue
    [[ "${install_whys}" != *$'\n'"${install_why}"$'\n'* ]] || continue
    install_whys+="${install_why}"$'\n'
    log_advisory "pre-guard: ${install_why}. Command: ${COMMAND}"
  done <<< "${install_why}"
done <<< "${INSTALL_TARGETS}"
if [[ "${PROJECT_DIR}" != "${CWD_DIR}" ]]; then
  log_advisory "pre-guard: the install lands outside cwd — snapshotting/verifying ${PROJECT_DIR} instead of cwd (${CWD_DIR})."
fi

# Canonicalize to prevent path traversal (V-003)
canonicalize_dir() {
  if command -v realpath >/dev/null 2>&1; then
    realpath "$1" 2>/dev/null || printf '%s' "$1"
  elif command -v readlink >/dev/null 2>&1; then
    readlink -f "$1" 2>/dev/null || printf '%s' "$1"
  else
    printf '%s' "$1"
  fi
}
PROJECT_DIR=$(canonicalize_dir "${PROJECT_DIR}")
CWD_DIR=$(canonicalize_dir "${CWD_DIR}")
for guard_reading in ${GUARD_READING_SET}; do
  guard_reading_ungated "${guard_reading}"
done

TIMESTAMP=$(date +%s)
DIR_HASH=$(compute_dir_hash "${PROJECT_DIR}")
# Pending-key hash keys on cwd so the PostToolUse hook (which only sees cwd) can
# find this install's pending state even when the install dir was overridden.
KEY_DIR_HASH=$(compute_dir_hash "${CWD_DIR}")

acquire_state_lock
# EXIT only, deliberately. Trapping TERM here looks like cheap insurance against
# a signalled child leaking the state lock, and it was committed as exactly that
# — but naming a signal in `trap` REPLACES its default disposition, so the child
# stopped dying at the deadline and ran its judgment to completion instead. The
# budget above then measured nothing: a padded install answered at 38.9s against
# a 30s runtime budget, which is the very fail-open this plan exists to close.
# A leaked lock is bounded by the 60s stale-lock sweep in acquire_state_lock; a
# defeated deadline is not bounded by anything.
trap 'release_state_lock; rm -f "${SAFEDEPS_SCAN_MARK:-}"; rm -rf "${SAFEDEPS_LEX_CACHE:-}"' EXIT

PARENT_SNAPSHOT_ID=""
CONFIRMED_FILE="${GUARD_DIR}/confirmed_${DIR_HASH}"
if [[ -f "${CONFIRMED_FILE}" ]]; then
  PARENT_SNAPSHOT_ID=$(cat "${CONFIRMED_FILE}" 2>/dev/null || true)
fi

if [[ -n "${PARENT_SNAPSHOT_ID}" ]] && [[ ! -f "${SNAPSHOT_DIR}/${PARENT_SNAPSHOT_ID}_meta.json" ]]; then
  # Fallback: check legacy global confirmed file for migration
  if [[ -f "${GUARD_DIR}/confirmed" ]]; then
    PARENT_SNAPSHOT_ID=$(cat "${GUARD_DIR}/confirmed" 2>/dev/null || true)
    if [[ -n "${PARENT_SNAPSHOT_ID}" ]] && [[ ! -f "${SNAPSHOT_DIR}/${PARENT_SNAPSHOT_ID}_meta.json" ]]; then
      PARENT_SNAPSHOT_ID=""
    fi
  else
    PARENT_SNAPSHOT_ID=""
  fi
fi

PARENT_SNAPSHOT_JSON=$(printf '%s' "${PARENT_SNAPSHOT_ID}" | jq -Rs 'if length == 0 then null else . end')

# The snapshot id is this call's own. The pending state and the post hook find
# the snapshot by it, and `${TIMESTAMP}_${DIR_HASH}` alone was the same for two
# calls in one project within one second: the second wrote its meta and its copy
# of the lockfiles over the first's, so one post hook read the other call's
# record and a rollback restored the other call's files (bamdori r19, SAME). The
# pid tells live calls apart; the exclusive create below tells apart a pid used
# again within the second, and a leftover of a killed run. The suffix is joined
# with `-`, not `_`, so no id is the start of another id's `${id}_*` files
# (cleanup removes a snapshot with that glob). The timestamp stays first, so ids
# still sort by time.
claim_snapshot_id() {
  local base="${TIMESTAMP}_${DIR_HASH}-$$" id n=0
  id="${base}"
  while ! ( set -C; : > "${SNAPSHOT_DIR}/${id}_monitored_files.list" ) 2>/dev/null; do
    [[ -e "${SNAPSHOT_DIR}/${id}_monitored_files.list" ]] || return 1
    n=$((n + 1))
    id="${base}-${n}"
  done
  printf '%s' "${id}"
}
SNAPSHOT_ID=$(claim_snapshot_id)

# Snapshot lock and manifest files that define dependency truth.
SNAPSHOTTED=false

for lock_file in "${SAFEDEPS_LOCK_FILES[@]}"; do
  snapshot_project_file "${lock_file}" "lock"
done

for manifest_file in "${SAFEDEPS_MANIFEST_FILES[@]}"; do
  snapshot_project_file "${manifest_file}" "manifest"
done

while IFS= read -r csproj_file; do
  snapshot_project_file "$(basename "${csproj_file}")" "manifest"
done < <(find "${PROJECT_DIR}" -maxdepth 1 -type f -name "*.csproj" 2>/dev/null | sort)

# npm's record of the installed tree as it is before the command. An install
# that saves nothing leaves package-lock.json as it was and writes only this
# file, so the effect gate's source and install-script checks need the version
# from before to tell what the install brought in (collect_npm_new_records).
# The copy is what the file said, and the file can be committed, so the record
# of withheld bytes leaves nothing out on its word unless it is a tree record
# the effect gate judged here (npm_tree_record_observed).
#
# Copied, never moved or touched: the trace below is this file's own mtime and
# inode. The copy goes through a temporary name, so the effect gate reads all
# of it or none of it. A copy that fails costs a smaller baseline, and a
# smaller baseline makes more of the tree read as new, so the failure errs
# toward checking more. It is recorded, because what it can cost is a rollback
# of an install that brought nothing new in.
NPM_TREE_RECORD="${PROJECT_DIR}/node_modules/.package-lock.json"
if [[ -f "${NPM_TREE_RECORD}" ]]; then
  NPM_TREE_COPY=""
  if ! { NPM_TREE_COPY=$(mktemp "${SNAPSHOT_DIR}/.${SNAPSHOT_ID}_tree.XXXXXX") \
      && cp "${NPM_TREE_RECORD}" "${NPM_TREE_COPY}" \
      && mv -f "${NPM_TREE_COPY}" "${SNAPSHOT_DIR}/${SNAPSHOT_ID}_${SAFEDEPS_SNAPSHOT_NPM_TREE}"; }; then
    rm -f "${NPM_TREE_COPY}"
    log_advisory "pre-guard: could not keep a copy of ${NPM_TREE_RECORD}, so the effect gate will compare this install with package-lock.json alone and may read packages already installed as new. Command: ${COMMAND}"
  fi
fi

# A workspace install writes a member's package.json as well as the root's.
# A snapshot that cannot keep them is a rollback that cannot undo the install,
# so the install waits rather than running without one.
if declare -F safedeps_npm_workspace_manifests >/dev/null; then
  if ! MEMBERS_ERROR=$(snapshot_workspace_manifests 2>&1 >/dev/null); then
    rm -rf "${SNAPSHOT_DIR}/${SNAPSHOT_ID}_${SAFEDEPS_SNAPSHOT_MEMBERS}"
    rm -f "${SNAPSHOT_DIR}/${SNAPSHOT_ID}_"*
    MEMBERS_ERROR=$(printf '%s' "${MEMBERS_ERROR}" | tr '\n' ' ')
    log_advisory "pre-guard: could not snapshot the workspace members' package.json files in ${PROJECT_DIR} (${MEMBERS_ERROR% }). Command: ${COMMAND}"
    jq -nc --arg reason "safedeps: undecided — safedeps could not keep a copy of the workspace members' package.json files in ${PROJECT_DIR} (${MEMBERS_ERROR% }), so it could not roll this install back. This is not a finding about the packages. Make the members' package.json files readable and retry." \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$reason}}'
    exit 0
  fi
fi

# Save pre-install listings for diff-based detection (avoids mtime-based find -newer).
# -H follows node_modules itself when it is a link and no link below it: the
# post hook lists the same way, and without -H both listings of a linked
# node_modules were empty, so "lists no package.json the snapshot lacks" held
# without looking at anything.
if [[ -d "${PROJECT_DIR}/node_modules" ]]; then
  find -H "${PROJECT_DIR}/node_modules" -maxdepth 3 -name "package.json" 2>/dev/null | sort > "${SNAPSHOT_DIR}/${SNAPSHOT_ID}_packages.list"
  { ls "${PROJECT_DIR}/node_modules/.bin/" 2>/dev/null || true; } | sort > "${SNAPSHOT_DIR}/${SNAPSHOT_ID}_bins.list"
else
  touch "${SNAPSHOT_DIR}/${SNAPSHOT_ID}_packages.list"
  touch "${SNAPSHOT_DIR}/${SNAPSHOT_ID}_bins.list"
fi

# Store metadata for PostToolUse verification. "record": 2 names what its
# fields mean: ignore_scripts_injected false here means safedeps sent no
# rewrite, because a rewrite whose record cannot be written is not sent
# (mark_ignore_scripts_injected). A v2.17.2 record held the same field and
# sent the rewrite anyway, so the post hook says an --ignore-scripts line only
# from a record that names this version (fact_inert).
cat > "${SNAPSHOT_DIR}/${SNAPSHOT_ID}_meta.json" << META_EOF
{
  "record": 2,
  "snapshot_id": "${SNAPSHOT_ID}",
  "parent_snapshot_id": ${PARENT_SNAPSHOT_JSON},
  "timestamp": ${TIMESTAMP},
  "project_dir": $(printf '%s' "${PROJECT_DIR}" | jq -Rs .),
  "command": $(printf '%s' "${COMMAND}" | jq -Rs .),
  "ignore_scripts_injected": false,
  "ignore_scripts_unread": false,
  "lock_files_found": ${SNAPSHOTTED}
}
META_EOF

# mark_ignore_scripts_injected <the command safedeps wrote>: the PostToolUse
# hook says "added" only where the command it receives is these bytes. Returns
# non-zero when the record was not written, and the caller then writes no
# rewrite: a rewrite with no record made the post hook's "did not add" false.
# ignore_scripts_unread says an install in it holds a word the shell decides
# at run time (INERT_UNVERIFIED), or the rewrite is only the release's because
# no place was read (INERT_RELEASE_ONLY), so nobody read where npm keeps the
# flag: a reason for the post hook to add a warning, never a permission to say
# the scripts did not run. A record that lacks it loses that warning and claims
# nothing more.
mark_ignore_scripts_injected() {
  local meta_file="${SNAPSHOT_DIR}/${SNAPSHOT_ID}_meta.json"
  local temp_file unread=false

  [[ -f "${meta_file}" ]] || return 1
  [[ "${INERT_UNVERIFIED}" != true && "${INERT_RELEASE_ONLY}" != true ]] || unread=true
  temp_file=$(mktemp "${SNAPSHOT_DIR}/.${SNAPSHOT_ID}_meta.XXXXXX") || return 1
  if jq --arg command "$1" --argjson unread "${unread}" \
      '.ignore_scripts_injected = true | .updated_command = $command | .ignore_scripts_unread = $unread' "${meta_file}" > "${temp_file}" \
    && mv -f "${temp_file}" "${meta_file}"; then
    return 0
  fi
  rm -f "${temp_file}"
  return 1
}

# --- Pre-flight security checks on the command itself ---

SUSPICIOUS=false
REASONS=()

# Check for piped install from suspicious sources
if echo "${COMMAND}" | judge_grep -qEi 'curl.*\|[[:space:]]*(bash|sh|node)'; then
  SUSPICIOUS=true
  REASONS+=("Command pipes remote content to shell execution")
fi

# Check for install with --ignore-scripts being removed (attacker might want scripts to run)
if echo "${COMMAND}" | judge_grep -qEi 'npm[[:space:]]+config[[:space:]]+set[[:space:]]+ignore-scripts[[:space:]]+false'; then
  SUSPICIOUS=true
  REASONS+=("Command explicitly enables install scripts")
fi

# Check for registry override to unknown registry
if echo "${COMMAND}" | judge_grep -qEi -- '--registry([=[:space:]]+)'; then
  if ! echo "${COMMAND}" | judge_grep -qEi -- '--registry([=[:space:]]+)https?://(registry\.npmjs\.org|registry\.yarnpkg\.com)(/|[[:space:]]|$)'; then
    SUSPICIOUS=true
    REASONS+=("Command uses non-standard npm registry")
  fi
fi
# The same question for every npm install is asked of npm rather than read
# from the text: the registry npm fetches from is whatever its configuration
# says, and `--registry` is one spelling of it among several. A committed
# .npmrc, `npm_config_registry` in front of the command or exported earlier in
# it, and the user's .npmrc each sent an approved name and version to another
# tarball while the text showed no `--registry` at all (RH1-RH3,
# safedeps/effect-gate-blind-to-lockless-npm-installs).
#
# npm's answer does not deny the install. A company registry, a mirror and a
# proxy are configured exactly this way, and safedeps has no path yet to
# approve one, so a deny here blocked those users with nothing they could do
# about it. The answer travels in the pending state instead, and the
# PostToolUse hook keeps the install but runs no install script of bytes npm
# fetched from a registry that is not public, and says which registry, so a
# person decides whether to trust it. The text check above stays a deny: a
# `--registry` the command itself spells out is a choice made in the command,
# not the project's standing configuration. Only the record is written here,
# so a run whose answer named another registry says so in advisory.log even on
# Codex, where the install's own scripts run before any hook can withhold them.
if [[ -n "${SAFEDEPS_NPM_FETCH_JQ:-}" ]]; then
  REGISTRY_FACTS=$(while IFS=$'\035' read -r install_kind _ _ install_fetch _; do
    [[ "${install_kind}" == npm* && "${install_fetch}" == '{'* ]] || continue
    printf '%s\n' "${install_fetch}"
  done <<< "${INSTALL_TARGETS}")
  if [[ -n "${REGISTRY_FACTS}" ]]; then
    REGISTRY_FOUND=$(jq -rn --arg public "${SAFEDEPS_NPM_PUBLIC_REGISTRY_RE}" "${SAFEDEPS_NPM_FETCH_JQ}"'
        [inputs | select(.unknown == null) | . as $f | select(($f.registry | sd_registry_public($f)) | not)
         | "registry=\($f.registry // "a value npm will not print")"] | unique | join(", ")' \
        <<< "${REGISTRY_FACTS}" 2>/dev/null) \
      || REGISTRY_FOUND="a registry safedeps could not read from npm's answer"
    [[ -z "${REGISTRY_FOUND}" ]] \
      || log_advisory "pre-guard: npm reads ${REGISTRY_FOUND} for this install from its configuration (an .npmrc or the environment), which is not the public npm registry. That alone does not deny the install; safedeps will not rebuild what npm fetched from there (on Codex the install runs its own scripts before any hook can withhold them). Command: ${COMMAND}"
  fi
fi

# Check for packages with suspicious naming patterns (typosquatting indicators)
TYPOSQUAT_PATTERNS='(lod[bcdfghjklmnpqrstvwxyz]sh|lodahs|loadsh|lodashh|reacct|exprss|axois|babeel|webpackk|esliint|l0dash|m0ment|4xios|reqeusts|requets|djagno|numppy|panddas|pilliow|tensorfow|scikit-learnn|serde_jsonn|tokioo|reqwestt|clapp|github\.con/|githb\.com/|railss|sinatraa|nokogirri|log4jj|springframewrok|commons-collectionss|newtonsoft\.josn|serilogg|nunittt)'
if echo "${COMMAND}" | judge_grep -qEi "${TYPOSQUAT_PATTERNS}"; then
  SUSPICIOUS=true
  REASONS+=("Package name matches known typosquatting patterns")
fi

if [[ "${SUSPICIOUS}" == "true" ]]; then
  guard_undecided_if_scan_failed
  REASON_STR=$(printf '%s; ' "${REASONS[@]}")
  jq -nc --arg reason "safedeps: ${REASON_STR%%; }" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$reason}}'
  exit 0
fi

# --- Phase 2 advisory gate — ledger enforcement -------------------------------
# For commands that name specific packages, require an entry in the approved-
# spec ledger. Miss/expired → block with a structured message that names a
# runnable `safedeps check` command the caller (agent or human) should run
# next — PATH command when present, else an absolute path, so the self-heal
# loop never dead-ends on a missing PATH symlink.
#
# Conservative: only block when at least one pkg@spec token is parseable. Bare
# `npm install` (lockfile install) falls through to the v1 reorg checks.

SAFEDEPS_LEDGER_LIB="${SAFEDEPS_LEDGER_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/ledger/ledger.sh}"
SAFEDEPS_NPM_CLOSURE_LIB="${SAFEDEPS_NPM_CLOSURE_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/npm/closure.sh}"
SAFEDEPS_REPO_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/safedeps"

# LEDGER_SPECS, LEDGER_ECOSYSTEM and GUARD_READINGS come from every reading
# (guard_reading_facts). The gate keeps the spec lines; the UNGATED record
# walked each reading's statements when that reading was judged, so the two
# never parse the same statement twice or differently.
LEDGER_HAS_NPM=false
for ledger_spec_line in "${LEDGER_SPECS[@]+${LEDGER_SPECS[@]}}"; do
  [[ "${ledger_spec_line%%$'\t'*}" == "npm" ]] && LEDGER_HAS_NPM=true
done

if [[ ${#LEDGER_SPECS[@]} -gt 0 ]]; then
  if [[ ! -f "${SAFEDEPS_LEDGER_LIB}" ]]; then
    # The ledger library is the gate for direct install specs. If it is missing
    # (broken install / moved repo) the gate cannot run — fail CLOSED, observably,
    # instead of falling through to allow.
    log_advisory "pre-guard DENY: ledger library missing (${SAFEDEPS_LEDGER_LIB}) — cannot enforce ${LEDGER_ECOSYSTEM} install, fail-closed."
    jq -nc --arg eco "${LEDGER_ECOSYSTEM}" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:("safedeps: the ledger library is missing, so the " + $eco + " install gate cannot run — install blocked fail-closed. Reinstall safedeps: node scripts/install/install-safedeps-hooks.mjs")}}'
    exit 0
  fi
  # shellcheck source=../lib/ledger/ledger.sh
  source "${SAFEDEPS_LEDGER_LIB}"

  LEDGER_CONTEXT_HASH=""
  LEDGER_CONTEXT_FILE=""
  if [[ "${LEDGER_HAS_NPM}" == true && ! -f "${SAFEDEPS_NPM_CLOSURE_LIB}" ]]; then
    log_advisory "pre-guard DENY: npm closure library missing (${SAFEDEPS_NPM_CLOSURE_LIB}); project-scoped approval cannot be enforced."
    jq -nc '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:"safedeps: the npm closure library is missing, so project-scoped approvals cannot be enforced. Install blocked fail-closed; reinstall safedeps."}}'
    exit 0
  fi
  if [[ "${LEDGER_HAS_NPM}" == true ]] && ! [[ "${GUARD_NPM_SEEN}" == true && "${GUARD_NPM_ALL_GLOBAL}" == true ]]; then
    # shellcheck source=../lib/npm/closure.sh
    source "${SAFEDEPS_NPM_CLOSURE_LIB}"
    LEDGER_CONTEXT_FILE=$(mktemp "${TMPDIR:-/tmp}/safedeps-pre-context.XXXXXX") || {
      log_advisory "pre-guard DENY: could not allocate project-context evidence; scoped approval cannot be enforced."
      jq -nc '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:"safedeps: project-context evidence could not be created. Install blocked fail-closed."}}'
      exit 0
    }
    if SAFEDEPS_NPM_PROJECT_DIR="${PROJECT_DIR}" safedeps_npm_yarn_project_context "${LEDGER_CONTEXT_FILE}"; then
      LEDGER_CONTEXT_HASH=$(jq -r '.context_hash' "${LEDGER_CONTEXT_FILE}")
    else
      context_status=$?
      if [[ "${context_status}" -eq 2 ]]; then
        log_advisory "pre-guard DENY: Yarn project resolution context is invalid in ${PROJECT_DIR}; scoped approval cannot be verified."
        rm -f "${LEDGER_CONTEXT_FILE}"
        jq -nc '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:"safedeps: Yarn project resolutions are present, but their lockfile context could not be verified. Install blocked fail-closed; repair the root package.json/yarn.lock context and run `safedeps check` again."}}'
        exit 0
      fi
      # No Yarn context. An npm `overrides` approval is scoped to the override
      # set that produced it, so the guard has to derive the same key or a
      # legitimately approved install would look unapproved here.
      overrides_source_file=$(mktemp "${TMPDIR:-/tmp}/safedeps-pre-ov-src.XXXXXX") || overrides_source_file=""
      if [[ -n "${overrides_source_file}" ]]; then
        overrides_json=$(SAFEDEPS_NPM_OVERRIDES_DIR="${PROJECT_DIR}" safedeps_npm_repo_overrides_json "${overrides_source_file}")
        overrides_source=$(cat "${overrides_source_file}" 2>/dev/null)
        rm -f "${overrides_source_file}"
        if [[ -n "${overrides_json}" && "${overrides_json}" != '{}' ]] && \
            safedeps_npm_overrides_context "${LEDGER_CONTEXT_FILE}" "${overrides_json}" "${overrides_source}"; then
          LEDGER_CONTEXT_HASH=$(jq -r '.context_hash' "${LEDGER_CONTEXT_FILE}")
        fi
      fi
    fi
  fi

  # Resolve a runnable `safedeps` invocation for the block message so the
  # self-heal loop works whether or not the CLI is on PATH. Prefer the PATH
  # command (clean UX); otherwise name the absolute repo bin (quoted via %q so
  # it survives spaces in $HOME). Keeps the gate self-contained — the install
  # of a `~/.local/bin/safedeps` symlink is a convenience, never a requirement.
  if command -v safedeps >/dev/null 2>&1; then
    SAFEDEPS_INVOKE="safedeps"
  else
    printf -v SAFEDEPS_INVOKE '%q' "${SAFEDEPS_REPO_BIN}"
  fi

  GUARD_BLOCKED_CMDS=()
  GUARD_BLOCKED_ECOSYSTEMS=""
  for entry in "${LEDGER_SPECS[@]}"; do
    IFS=$'\t' read -r eco pkg spec <<< "${entry}"
    [[ -z "${eco}" || -z "${pkg}" || -z "${spec}" ]] && continue
    # The npm project context keys npm approvals only.
    spec_context=""
    [[ "${eco}" == "npm" ]] && spec_context="${LEDGER_CONTEXT_HASH}"
    if ! safedeps_ledger_check "${eco}" "${pkg}" "${spec}" "${spec_context}" 2>/dev/null \
        | jq -e '.approved == true' >/dev/null 2>&1; then
      GUARD_BLOCKED_CMDS+=("${SAFEDEPS_INVOKE} check ${eco} ${pkg//$'\002'/ }@${spec//$'\002'/ }")
      case ",${GUARD_BLOCKED_ECOSYSTEMS}," in
        *",${eco},"*) : ;;
        *) GUARD_BLOCKED_ECOSYSTEMS="${GUARD_BLOCKED_ECOSYSTEMS:+${GUARD_BLOCKED_ECOSYSTEMS},}${eco}" ;;
      esac
    fi
  done

  if [[ ${#GUARD_BLOCKED_CMDS[@]} -gt 0 ]]; then
    # A prescription read from a failed scan can name the wrong package, and
    # agents run it: that is how a wrong identity gets approved.
    if guard_scan_failed; then
      [[ -z "${LEDGER_CONTEXT_FILE}" ]] || rm -f "${LEDGER_CONTEXT_FILE}"
      guard_undecided_if_scan_failed
    fi
    NEXT_CMD=""
    for ((i = 0; i < ${#GUARD_BLOCKED_CMDS[@]}; i++)); do
      if [[ -z "${NEXT_CMD}" ]]; then
        NEXT_CMD="${GUARD_BLOCKED_CMDS[$i]}"
      else
        NEXT_CMD="${NEXT_CMD} && ${GUARD_BLOCKED_CMDS[$i]}"
      fi
    done
    REASON_JSON=$(jq -nc \
      --arg next "${NEXT_CMD}" \
      --arg ecosystem "${GUARD_BLOCKED_ECOSYSTEMS}" \
      '{
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "deny",
          permissionDecisionReason: ("safedeps: install not approved (ecosystem=" + $ecosystem + ") — run `" + $next + "` first, then retry the install using the approved version (see install_hint in the check output).")
        }
      }')
    printf '%s\n' "${REASON_JSON}"
    [[ -z "${LEDGER_CONTEXT_FILE}" ]] || rm -f "${LEDGER_CONTEXT_FILE}"
    exit 0
  fi
  [[ -z "${LEDGER_CONTEXT_FILE}" ]] || rm -f "${LEDGER_CONTEXT_FILE}"
fi

# An install that names a package but pins no version yields no spec, so the
# ledger gate above never ran for it. Where the effect gate reads the result
# (guard_effect_gate_reads), that is not a gap: it enforces on the lockfile
# closure. Everywhere
# else there is nothing behind this gate, so the install proceeds unverified --
# and until the record existed it did so with no trace at all, which
# contradicts the invariant that every bypass must be observable.
#
# The unit is the operand. A command that pins one package and names another
# without a pin is recorded, and so is one that pins a package and then names
# the same package again without a pin (`pnpm add x@1 && pnpm add x`): the
# second operand installs whatever is latest, and the pin on the first says
# nothing about it. The line names each operand it recorded.
#
# This records the fact. It deliberately does NOT deny: refusing every unpinned
# install is a policy change (it would block ordinary `cargo add x` workflows)
# and belongs to the repo owner, not to this gate. The record is what makes that
# decision answerable with evidence instead of guesswork.
#
# Each reading walked its own statements (guard_reading_facts); the line names
# what any of them recorded.
if [[ -n "${GUARD_UNGATED}" ]]; then
  log_advisory "pre-guard UNGATED: ${GUARD_UNGATED_ECOSYSTEM} install names a package with no version spec, so the ledger gate did not run. No effect gate reads the result of this install, so it is unverified. Unpinned: ${GUARD_UNGATED}. Command: ${COMMAND}"
fi

# Specs are extracted from candidate texts only, and a pipe's producer is not
# one, so nothing can reduce a piped install to a spec. Beside a visible install
# the specs that were extracted are the visible one's, so the count below would
# read as "reduced" -- this case is settled on its own, fail-closed like the same
# pipe with nothing beside it. The visible install's own text counts as install
# text here (command_pipes_install_to_shell), so an install and an unrelated
# pipe into a shell in one command land here too, and the reason says to split
# them.
if [[ "${PIPED_BESIDE_VISIBLE}" == "true" ]]; then
  guard_undecided_if_scan_failed
  log_advisory "pre-guard DENY: install text piped into a shell beside a visible install could not be reduced to an approved spec — fail-closed. Command: ${COMMAND}"
  jq -nc '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:"safedeps: this command pipes text that reads like an install into a shell (`... | sh`) beside the install it runs. The gate checks the visible install, but it cannot extract a package spec from what is piped, and it cannot tell whether the piped text reads the install'"'"'s own words, so the command is blocked fail-closed. Run the install and the pipe into the shell as separate commands. If the piped text is itself an install, write it out rather than piping it, so it can be checked."}}'
  exit 0
fi

# Per reading: a hidden install another reading reduced to specs is not reduced
# in the reading that hid it (guard_reading_facts).
if [[ "${GUARD_HIDDEN_UNREDUCED}" == "true" ]]; then
  guard_undecided_if_scan_failed
  log_advisory "pre-guard DENY: hidden dependency install could not be reduced to an approved spec — fail-closed."
  jq -nc '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:"safedeps: hidden dependency install detected, but no package spec could be extracted for ledger approval — install blocked fail-closed."}}'
  exit 0
fi

# The inert rewrite was decided per reading (guard_reading_inert), before the
# gate like every other reading. It used to sit after the last settle, where a
# failed scan made it skip the rewrite or land it at the end of a compound
# command, and nothing noticed. A rewrite changes the text every shell reads,
# so it stands only when every reading made the same one; otherwise no single
# text is inert for every shell, and the command is UNDECIDED (I2, I3: zsh ran
# an `npm ci` that bash read as quoted text, with no flag and no record).
for guard_reading in ${GUARD_READING_SET}; do
  guard_reading_effects "${guard_reading}"
done
# These read text the readings above already lexed, so a place where the shells
# differ cannot first appear here. If one does, the other readings were never
# judged, and the command is settled as unread rather than half judged.
if [[ "${GUARD_READING_SET}" == bash ]] && guard_readings_diverge; then
  log_advisory "pre-guard: a place where the shells read differently was first met while deciding the inert rewrite; the zsh and dash readings were not judged. Command: ${COMMAND}"
  guard_mark_reading_failed
fi
UPDATED_COMMAND=""
INERT_DOWNGRADED=false
INERT_FLOOR_ONLY=false
INERT_RELEASE_ONLY=false
INERT_ASKED=false
INERT_UNVERIFIED=false
if [[ "${GUARD_IS_CODEX}" != true ]]; then
  inert_first="" inert_seen=false
  for guard_reading in ${GUARD_READING_SET}; do
    inert_var="GUARD_INERT_${guard_reading}"
    if [[ "${inert_seen}" != true ]]; then
      inert_first="${!inert_var}"
      inert_seen=true
    elif [[ "${!inert_var}" != "${inert_first}" ]]; then
      guard_deny_inert_readings_differ
    fi
  done
  case "${inert_first}" in
    downgrade) INERT_DOWNGRADED=true ;;
    rewrite*$'\n'*)
      UPDATED_COMMAND="${inert_first#*$'\n'}"
      inert_first="${inert_first%%$'\n'*}"
      [[ "${inert_first}" != *" asked"* ]] || INERT_ASKED=true
      [[ "${inert_first}" != *" unverified"* ]] || INERT_UNVERIFIED=true
      # A statement kept only the floor: the release's rewrite, with no place
      # read as true, or an install the rewrite cannot reach beside one it
      # rewrote (inert_nested_verb_ends). It is sent and recorded as a
      # downgrade.
      [[ "${inert_first}" != *" floor"* ]] || INERT_FLOOR_ONLY=true
      # No rewrite landed, and the command gets the release's own: the flag
      # at the end of a one-statement command. Also a recorded downgrade.
      [[ "${inert_first}" != *" release"* ]] || INERT_RELEASE_ONLY=true
      ;;
  esac
fi

# What the PostToolUse hook needs to tell whether this command's npm installs
# were read (NPM_TRACE_WANTED, ATTRIBUTION) was read per reading too
# (guard_reading_facts). The trace baseline itself is written with the pending
# state below.

# The gate: every verdict from here on lets the command run, and nothing after
# this line reads the command text. Pending state, the inert meta and the allow
# are written only once it has passed, so a command it denies leaves no pending
# file for PostToolUse to pick up on the next identical command.
guard_settle_scan_failure

if [[ "${INERT_DOWNGRADED}" == "true" ]]; then
  log_advisory "pre-guard: could not make every npm install in this command inert in place (one is in a compound command the rewrite did not land in, in a statement whose end it could not find, or in a script handed to a shell that it cannot reach); lifecycle scripts may run before the effect gate verifies (downgraded to detect-and-rollback). Command: ${COMMAND}"
fi
if [[ "${INERT_FLOOR_ONLY}" == "true" ]]; then
  log_advisory "pre-guard: an npm install in this command has no place where safedeps could read npm keeping --ignore-scripts true (its end could not be found, a -- ends npm's options before it, every place changes what npm reads, or its verb is glued to a } inside a substitution, which the rewrite reads as a character and gives no flag); safedeps put the flag right after each verb it read, where the release put it in a compound command, and at the end of a one-statement command, where the release put it there; lifecycle scripts may run before the effect gate verifies (downgraded to detect-and-rollback). Command: ${COMMAND}"
fi
if [[ "${INERT_RELEASE_ONLY}" == "true" ]]; then
  log_advisory "pre-guard: could not place --ignore-scripts by reading an npm install in this command (one is in a script handed to a shell that the rewrite cannot reach, in a heredoc fed to a shell, or in text it could not read); safedeps added the flag only at the end of the command, where the release added it, and could not read where npm keeps it, so lifecycle scripts may run before the effect gate verifies (downgraded to detect-and-rollback). Command: ${COMMAND}"
fi
if [[ "${INERT_ASKED}" == "true" ]]; then
  log_advisory "pre-guard: an npm install in this command sets ignore-scripts false; safedeps put --ignore-scripts after it, where npm reads the last value an option is given, and safedeps itself runs the install's scripts only through the rebuild after the closure verifies. Command: ${COMMAND}"
fi
if [[ "${INERT_UNVERIFIED}" == "true" ]]; then
  log_advisory "pre-guard: an npm install in this command holds a word the shell decides at run time (a tilde, a brace, \$x, \$(...), a glob or another expansion), which can set ignore-scripts, take the next word as its value, or end npm's options; safedeps put --ignore-scripts both right after the verb and after the last argument, and could not read whether npm keeps it true, so the install's scripts may run before the effect gate verifies. Command: ${COMMAND}"
fi

# Write the record of this install for the post hook of the same call. It is
# named by the call's tool_use_id (lib/gates/call-id.sh), which both hooks of
# one call receive and no other call does, so the post hook reads this call's
# record and no other. Records used to be found by the directory and the
# command, and a call could speak from another's: two overlapping calls of one
# command each took the other's record (bamdori r19 X1), and a call whose post
# hook never ran (a tool call the user rejected, or a failed one on Claude
# Code before PostToolUseFailure was registered) left a record the next call
# of the command consumed, rolling back what was edited in between (O2). The
# single-file write is still atomic (write_state_file).
PENDING_DIR="${GUARD_DIR}/pending"
mkdir -p "${PENDING_DIR}"
# GC pending entries whose PostToolUse never fired (crash/no-op). 24h is well past
# any real install, so this never deletes an in-flight one (a 60-min window could
# have reaped a slow native build that was still running).
find "${PENDING_DIR}" \( -name '*.json' -o -name '*.trace' \) -type f -mmin +1440 -delete 2>/dev/null || true
CALL_ID=""
CALL_ID_LIB="${BASH_SOURCE[0]%/*}/../lib/gates/call-id.sh"
# shellcheck source=../lib/gates/call-id.sh
if [[ -r "${CALL_ID_LIB}" ]] && source "${CALL_ID_LIB}" 2>/dev/null; then
  CALL_ID=$(safedeps_call_id "${INPUT}") || CALL_ID=""
  CALL_ID_WHY="this hook's input names no tool_use_id"
else
  CALL_ID_WHY="the pre-guard could not read ${CALL_ID_LIB}"
fi
if [[ -n "${CALL_ID}" ]]; then
  PENDING_BASE=$(safedeps_call_base "${PENDING_DIR}" "${CALL_ID}")
else
  # A call that names no tool_use_id keeps the key from before: the directory
  # and the command with the inert rewrite normalized out (issue #5), and the
  # snapshot id, which is unique per call (claim_snapshot_id). The post hook
  # finds the record by that key only for such a call, and two overlapping
  # calls of the command can then use each other's record, so it is recorded.
  PENDING_KEY=$(compute_pending_key "${KEY_DIR_HASH}" "${COMMAND}")
  PENDING_BASE="${PENDING_DIR}/${PENDING_KEY}__${SNAPSHOT_ID}"
  log_advisory "pre-guard: ${CALL_ID_WHY}, so the record of this install is kept under its directory and command, and another call of the same command in the same directory can use it. Command: ${COMMAND}"
fi

# The trace baseline: a file touched now, and the inode of each npm lockfile in
# the directory the gate reads. npm rewrote node_modules/.package-lock.json on
# every install that installed anything, a reinstall of what was already there
# included, with the same content and a new mtime; `npm ci` replaced the file,
# so the inode changed too (measured with npm 11.19.0 in the design judgment).
# Content is no use for this, and neither is a whole-second mtime: a reinstall
# that finishes within the second it started in shows nothing in either. So
# the trace is a lockfile `find -newer` than this file, or one with another
# inode (settle_npm_trace in the PostToolUse hook).
#
# It is written last, once the command is known to run, so the time between
# the touch and the command is the hook's exit and nothing else.
TRACE_JSON=null
if [[ "${NPM_TRACE_WANTED}" == true ]]; then
  TRACE_JSON=$(jq -nc --arg baseline "${PENDING_BASE}.trace" \
    --arg lock "$(guard_file_inode "${PROJECT_DIR}/package-lock.json")" \
    --arg hidden "$(guard_file_inode "${PROJECT_DIR}/node_modules/.package-lock.json")" \
    '{baseline: $baseline, inodes: {"package-lock.json": $lock, "node_modules/.package-lock.json": $hidden}}')
  : > "${PENDING_BASE}.trace"
fi
# The registry answer travels as npm gave it, or as the reason there is none.
# Never as a default: an install npm was not asked about has no answer, and the
# PostToolUse hook vouches for no source on the strength of a missing one.
FETCH_JSON=null
if [[ "${NPM_TRACE_WANTED}" == true ]]; then
  FETCH_JSON=$(jq -ce 'select(type == "object")' <<< "${PROJECT_FETCH}" 2>/dev/null) \
    || FETCH_JSON=$(jq -nc --arg why "${PROJECT_FETCH_WHY}" \
      '{unknown: ("npm was not asked which registry this install fetches from: " + $why)}')
fi
CURRENT_STATE=$(jq -n --arg sid "${SNAPSHOT_ID}" --arg pdir "${PROJECT_DIR}" --arg dhash "${DIR_HASH}" \
  --arg from "${PROJECT_DIR_FROM}" --argjson trace "${TRACE_JSON}" --arg attribution "${ATTRIBUTION}" \
  --argjson fetch "${FETCH_JSON}" --arg call "${CALL_ID}" \
  '{snapshot_id: $sid, project_dir: $pdir, dir_hash: $dhash, project_dir_from: $from,
    npm_trace: $trace, npm_unattributable: $attribution, npm_fetch: $fetch,
    tool_use_id: (if $call == "" then null else $call end)}')
write_state_file "${PENDING_BASE}.json" "${CURRENT_STATE}"

if [[ -n "${UPDATED_COMMAND}" ]]; then
  if mark_ignore_scripts_injected "${UPDATED_COMMAND}"; then
    jq -nc --arg command "${UPDATED_COMMAND}" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",updatedInput:{command:$command}}}'
    exit 0
  fi
  log_advisory "pre-guard: could not record the command safedeps would write in ${SNAPSHOT_DIR}/${SNAPSHOT_ID}_meta.json, so it was not rewritten: the install runs as given, without --ignore-scripts, and the effect gate falls back to detect-and-rollback. Command: ${COMMAND}"
fi

# Allow the command to proceed — PostToolUse will verify the result
exit 0
