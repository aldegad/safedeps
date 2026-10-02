#!/usr/bin/env bash
# safedeps: PreToolUse hook
# Dependency install safety gate with reorg rollback support
# Detects package install commands and snapshots lock files before execution

set -euo pipefail

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
  }
fi

# The workspace members' manifests, which a workspace install writes and a
# rollback has to restore, and the names snapshots keep files under.
SAFEDEPS_NPM_WORKSPACES_LIB="${BASH_SOURCE[0]%/*}/../lib/npm/workspaces.sh"
if [[ -r "${SAFEDEPS_NPM_WORKSPACES_LIB}" ]]; then
  # shellcheck source=../lib/npm/workspaces.sh
  source "${SAFEDEPS_NPM_WORKSPACES_LIB}"
else
  SAFEDEPS_SNAPSHOT_MEMBERS=members
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
# files instead of clobbering a single global one.
compute_pending_key() {
  local dir_hash="$1" command="$2" norm cmd_hash
  norm=$(printf '%s' "${command}" | sed -E 's/[[:space:]]+--ignore-scripts([[:space:]]|$)/ /g; s/[[:space:]]+/ /g; s/^ //; s/ $//')
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

# grep for a judgment: 0 is a match and 1 is no match. Anything else -- a grep
# that errored, was killed or could not be started -- is not "no match"; it is
# recorded and returns 1, and the gate decides.
judge_grep() {
  local rc=0
  grep "$@" || rc=$?
  (( rc <= 1 )) || guard_mark_reading_failed
  return $(( rc == 0 ? 0 : 1 ))
}

command_is_dependency_install() {
  local command="$1"
  local scan_command
  local install_pattern

  install_pattern="${SAFEDEPS_INSTALL_PATTERN}"

  while IFS= read -r scan_command; do
    scan_command=$(command_scan_text "${scan_command}")
    echo "${scan_command}" | judge_grep -qEi "${install_pattern}" && return 0
  done < <(command_candidate_texts "${command}")
  return 1
}

command_hides_dependency_install() {
  local command="$1"
  local payload stripped

  # Top-level pipe-to-shell: `<producer> | sh` whose producer text literally
  # contains a package manager + install verb (e.g. `printf 'pip install x' | sh`).
  # The install TEXT is searched raw (in a real hidden install it legitimately
  # lives inside the producer's quotes), but the PIPE must sit in execution
  # position — see payload_pipes_install_text_to_shell. Because outer quoting
  # hides an inner pipe from that position check, every executed inner text
  # (`sh -c` payloads, eval payloads, command substitutions) gets the same check
  # on its own quoting level below.
  payload_pipes_install_text_to_shell "${command}" && return 0

  # The payload readers take text with its heredoc bodies stripped, once.
  stripped=$(strip_heredoc_bodies "${command}")
  while IFS= read -r payload; do
    [[ -z "${payload}" ]] && continue
    payload_pipes_install_text_to_shell "${payload}" && return 0
  done < <(extract_shell_c_payloads "${stripped}")

  while IFS= read -r payload; do
    [[ -z "${payload}" ]] && continue
    command_is_dependency_install "${payload}" && return 0
    payload_pipes_install_text_to_shell "${payload}" && return 0
  done < <(extract_eval_payloads "${stripped}")

  while IFS= read -r payload; do
    [[ -z "${payload}" ]] && continue
    command_is_dependency_install "${payload}" && return 0
    payload_pipes_install_text_to_shell "${payload}" && return 0
  done < <(extract_command_substitution_payloads "${stripped}")

  return 1
}

# The pipe half of command_hides_dependency_install, asked beside a visible
# install (see payload_pipes_unread_install_text_to_shell). The payload loops
# are the same; the install question on eval and substitution payloads is not
# asked, because beside a visible install those payloads are candidate texts
# already and their specs reach the ledger.
command_pipes_unread_install_to_shell() {
  local command="$1"
  local payload stripped

  payload_pipes_unread_install_text_to_shell "${command}" && return 0
  stripped=$(strip_heredoc_bodies "${command}")
  while IFS= read -r payload; do
    [[ -z "${payload}" ]] && continue
    payload_pipes_unread_install_text_to_shell "${payload}" && return 0
  done < <(extract_shell_c_payloads "${stripped}"; extract_eval_payloads "${stripped}"; extract_command_substitution_payloads "${stripped}")
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
#   code    comments, heredoc operators and bodies blanked; quotes kept. What
#           the payload readers read.
#   joined  code, with line continuations removed and every newline that does
#           not end a statement blanked. What is read one line at a time.
#   shell-bodies  the bodies of heredocs whose command pipes into something.
#   live    scan, with code nested in quotes ("$(...)") and live code in an
#           unquoted heredoc body kept: every byte the shell runs at this
#           level. What the inert rewrite reads.
#   stmts   scan, with the `)` that closes a case pattern read as `;`: where a
#           statement ends. What command_statements splits on.
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
# `$'...'`), and a command is judged under every reading a shell could give it.
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
  if ! out=$(printf '%s\n' "${text}" | LC_ALL=C awk -v view="${view}" -v policy="${policy}" -v marker="${marker}" -v divfile="${SAFEDEPS_LEX_DIVERGE:-}" -v divmemo="${div}" '
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
      #              an escaped operator is `_`; length-preserving
      #   view=code    comments, heredoc operators and bodies blanked, quotes kept;
      #              length-preserving
      #   view=joined  code view with line continuations removed and every newline
      #              that does not end a statement blanked (a newline in code nested
      #              in quotes becomes `;`); for text read one line at a time
      #   view=shell-bodies  the raw lines of heredoc bodies whose command pipes
      #              into something
      #   view=substs  the body of every command substitution, one after another,
      #              as the shell delimits it: `$(...)` (case patterns inside close
      #              nothing) and backticks, a backtick body unescaped the way the
      #              shell unescapes it (`\`` nests). For the payload extractor.
      #   view=unprefixed  the text with the prefixes a statement may start with
      #              removed: assignments (NAME=value, the value one word however
      #              it is quoted or nested), env with its options and
      #              assignments, command and exec. Not length-preserving.
      #   view=noredir  every top-level redirection blanked: the operator, a file
      #              descriptor number that is the whole word in front of it, and
      #              the target word. An operator inside quotes, a substitution or
      #              after a backslash is a character, and one in the middle of a
      #              word still is an operator (`x==1>/dev/null`), as the shell
      #              reads it. `<(` and `>(` are process substitutions and stay.
      #              length-preserving
      #   view=unprefixed-lines  unprefixed, for text holding one statement per
      #              line, each line read from a fresh state like pieces: a case
      #              left open by one statement no longer swallows the prefixes of
      #              the next (caught in the release integration).
      #   view=pieces  for text holding one statement per line, each line read
      #              from a fresh state. One output line per piece, cut at
      #              top-level `;` `&` `|`, newlines and case-pattern closes:
      #              `<line>\037<raw>\037<words>`. <raw> is the piece as the noredir
      #              view has it. <words> is the same bytes after the shell quote
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
      }
      END {
        N = n
        d = 1; ctx[1] = "T"; par[1] = 0; dq = 0; dc = 1
        # The bytes any rule below acts on. Every other byte keeps the class of
        # its context and changes nothing, so it is classified without running
        # the rules -- most of a long command is such bytes.
        split("\\ $ \047 \042 # ( ) < ] } ` c e i ;", sl, " ")
        for (j in sl) SPC[sl[j]] = 1
        SPC["\n"] = 1
        DQS["\\"] = 1; DQS["\042"] = 1; DQS["$"] = 1; DQS["`"] = 1
        wantdep = (view == "unprefixed" || view == "unprefixed-lines" || view == "noredir" || view == "pieces" || view == "cscripts" || view == "stmts")
        if (view == "pieces") {
          # The value of each one-letter escape in $\047...\047.
          AQV["a"] = "\007"; AQV["b"] = "\010"; AQV["e"] = "\033"; AQV["E"] = "\033"
          AQV["f"] = "\014"; AQV["n"] = "\n"; AQV["r"] = "\r"; AQV["t"] = "\t"; AQV["v"] = "\013"
          AQV["\\"] = "\\"; AQV["\047"] = "\047"; AQV["\042"] = "\042"; AQV["?"] = "?"
        }
        mode = ""; np = 0; unterm = 0; hn = 0; hstop = 0; div = 0
        shb = (policy == "bash"); shz = (policy == "zsh"); shd = (policy == "dash")
        perline = (view == "pieces" || view == "unprefixed-lines")
        for (i = 1; i <= N; i++) {
          # The pieces view reads one statement per line. A line starts from
          # nothing, so a quote one statement left open on its line cannot run
          # into the next: when the statements of two readings were joined
          # into one text, a bash reading of an apostrophe in "${...}"
          # swallowed the install the zsh reading had split out (caught by the
          # verdict replay).
          if (perline && X[i] == "\n") {
            mode = ""; d = 1; dq = 0; dc = 1; hn = 0; np = 0; hstop = 0; par[1] = 0
            C[i] = "c"; DEP[i] = 1; continue
          }
          # An unquoted heredoc body ends where at_newline found its terminator
          # line: close what is open in it (a substitution left open there never
          # closes, as in the shell) and step over the terminator.
          if (hn > 0 && i == hstop + 1) {
            # A substitution left open in a body fails that one heredoc in the
            # shell; the lines after it still run (form H29), so it is dropped,
            # not counted as a command that never closes.
            while (d > 1 && ctx[d] != "H") pop()
            pop(); hstop = 0; mode = ""
          }
          if (i in JMP) { i = JMP[i]; continue }
          if (i in HSTART) { push("H"); hstop = HEND[HSTART[i]] }
          c = X[i]
          if (wantdep) DEP[i] = (mode == "") ? dc : 99
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
            if (w4 == "case" && cmdpos(i)) { C[i+1] = cls; C[i+2] = cls; C[i+3] = cls; i += 3; push("C"); continue }
            # `esac` ends the case where a pattern list could start, not as a
            # pattern word after `|` (`*|esac)`, form X7).
            if (w4 == "esac" && top == "C" && !(cpat[d] == 1 && cpw[d])) { C[i+1] = cls; C[i+2] = cls; C[i+3] = cls; i += 3; pop(); continue }
          }
          # Inside case: after `in`, and after each `;;` `;&` `;;&`, a pattern
          # runs to its `)`, which ends the pattern -- class p, read by the
          # unprefixed view as a statement boundary, so the arm is judged.
          if (top == "C") {
            if (cpat[d] == 0 && c == "i" && X[i+1] == "n" && wordstart(i) && (i + 2 > N || X[i+2] ~ /[ \t\n;&|()<>]/)) { C[i+1] = cls; i++; cpat[d] = 1; cpw[d] = 0; continue }
            if (cpat[d] == 1 && c == "(" && !cpw[d]) continue
            if (cpat[d] == 1 && c == ")") { C[i] = "p"; cpat[d] = 2; continue }
            if (cpat[d] == 1 && c !~ /[ \t\n]/) cpw[d] = 1
            # An arm ends at `;;`, `;&`, `;;&`, or zsh `;|` (forms X8, X9).
            if (cpat[d] == 2 && c == ";" && (X[i+1] == ";" || X[i+1] == "&" || X[i+1] == "|")) {
              C[i+1] = cls; i++
              if (X[i] == ";" && X[i+1] == "&") { C[i+1] = cls; i++ }
              cpat[d] = 1; cpw[d] = 0; continue
            }
          }
          if (top == "A" || top == "K") {
            if (top == "K") { if (c == "]") pop(); continue }
            if (c == "(") par[d]++
            else if (c == ")") { if (par[d] > 0) par[d]--; else if (X[i+1] == ")") { i++; C[i] = cls; if (adol[d]) WC[i] = 1; pop() } }
            else if (c == "\n") i = at_newline(i)
            continue
          }
          if (c == "#" && (wordstart(i) || top == "B" && X[i-1] == "`") && top != "V") {
            # Inside a glob word (see GL below) a `#` is a glob operator, never
            # a comment (form G5).
            if (glc[d] > 0) { div = 1; continue }
            C[i] = "m"; mode = "CM"; continue
          }
          if (c == "$" && X[i+1] == "(" && X[i+2] == "(") { C[i+1] = cls; C[i+2] = cls; arith_or_sub(i, 1); continue }
          # `((` is decided wherever it stands, not only where a command starts:
          # a hand list of command positions missed backticks, case patterns,
          # coproc and time -p (forms P1, P2, P15, Q2).
          if (c == "(" && X[i+1] == "(") { C[i+1] = cls; arith_or_sub(i, 0); continue }
          if (c == "$" && X[i+1] == "(") { C[i+1] = cls; i++; push("S"); continue }
          # dash has no `$[`: the bytes are a word, quotes and comments in it
          # read as anywhere else (forms K1, K2).
          if (c == "$" && X[i+1] == "[") { div = 1; if (shd) continue; C[i+1] = cls; i++; push("K"); continue }
          if (c == "$" && X[i+1] == "{") { C[i+1] = cls; i++; push("V"); continue }
          if (c == "`") { if (top == "B") pop(); else push("B"); continue }
          if (top == "V") { if (c == "}") pop(); continue }
          # A process substitution is a word like `$(...)`: its `)` ends no
          # token (PS marks the parenthesis level it opened, WC its close).
          # So is a glob word: zsh reads a `(` where an argument stands as the
          # start of one, and inside a substitution bash 3.2 reads it the same
          # way, so a `#` in it or after its `)` is no comment (forms G5,
          # ZG1); bash 5.2 and dash fail to parse it. GL marks the level for
          # the bash and zsh readings, glc counts the open ones, and the bash
          # reading says DIVERGE. An empty `()` is a function head, not a glob.
          if (c == "(") {
            par[d]++
            if (i > 1 && (X[i-1] == "<" || X[i-1] == ">") && C[i-1] == cls) PS[d, par[d]] = 1; else delete PS[d, par[d]]
            if (!shd && X[i+1] != ")" && (i == 1 || X[i-1] !~ /[$<>]/) && !cmdpos(i)) { GL[d, par[d]] = 1; glc[d]++; div = 1 } else delete GL[d, par[d]]
            continue
          }
          if (c == ")") {
            if (par[d] > 0) {
              if ((d, par[d]) in PS) { WC[i] = 1; delete PS[d, par[d]] }
              if ((d, par[d]) in GL) { WC[i] = 1; delete GL[d, par[d]]; glc[d]-- }
              par[d]--
            }
            else if (top == "S") { WC[i] = 1; pop() }
            continue
          }
          if (c == "<" && X[i+1] == "<" && X[i+2] != "<" && X[i-1] != "<") { i = heredoc_op(i); continue }
          if (c == "\n") { i = at_newline(i); continue }
        }
        if (mode == "SQ" || mode == "AQ" || d > 1 || np > 0) unterm = 1
        flagfile = ENVIRON["SAFEDEPS_LEX_FLAGS"]
        if (flagfile != "" && unterm) print "UNTERM" >> flagfile
        if (div) {
          if (divfile != "") print "DIVERGE" >> divfile
          if (divmemo != "") print "DIVERGE" > divmemo
        }
        # A reading that never closes strips nothing: a prefix word would run to
        # the end of the input and take every line after it along (form A7, a
        # heredoc inside `$((` that bash reads as arithmetic). Such a command is
        # settled as UNDECIDED by guard_check_command_reads anyway.
        if ((view == "unprefixed" || view == "unprefixed-lines") && !unterm) prefixes()
        # The same holds for redirections: in a reading that never closes, a
        # stripped target changes how the rest reads, and the view stops
        # being idempotent (random inputs in scan-contract).
        if ((view == "noredir" && !unterm) || view == "pieces" || view == "cscripts" || view == "stmts") redirs()
        if (view == "substs") emit_substs()
        else if (view == "pieces") emit_pieces()
        else if (view == "cscripts") emit_cscripts()
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

      # The top-level redirections: DROP marks the operator, a file descriptor
      # number that is the whole word in front of it, the blanks after it and
      # its target word.
      function redirs(   k, j, s) {
        for (k = 1; k <= N; k++) {
          if (C[k] != "c" || DEP[k] != 1) continue
          if (X[k] == "&" && X[k+1] == ">" && C[k+1] == "c") j = k + 1
          else if (X[k] == "<" || X[k] == ">") j = k
          else continue
          if (X[j+1] == "(") { k = j + 1; continue }
          s = k
          while (s > 1 && C[s-1] == "c" && DEP[s-1] == 1 && X[s-1] ~ /[0-9]/) s--
          if (s == k || s > 1 && !word_sep(s - 1)) s = k
          j++
          while (j <= N && C[j] == "c" && X[j] ~ /[<>]/) j++
          if (j <= N && C[j] == "c" && (X[j] == "&" || X[j] == "|")) j++
          while (j <= N && C[j] == "c" && DEP[j] == 1 && (X[j] == " " || X[j] == "\t")) j++
          while (j <= N && !word_sep(j)) j++
          for (; s < j; s++) DROP[s] = 1
          k = j - 1
        }
      }
      function emit_pieces(   k, a, ln, pln) {
        buf = ""; held = 0; ln = 1; a = 1; pln = 1
        for (k = 1; k <= N; k++) {
          if (!(k in DROP) && (C[k] == "p" || C[k] == "c" && DEP[k] == 1 && X[k] ~ /[;&|\n]/)) {
            piece(a, k - 1, pln)
            a = k + 1
            if (X[k] == "\n") ln++
            pln = ln
            continue
          }
          if (X[k] == "\n") ln++
        }
        piece(a, N, pln)
        if (aqbad) put("!\n")
        printf "%s", buf
      }
      # A byte of a piece as one line can carry it: a newline inside the piece
      # (code nested in a substitution) ends a command there, and the field
      # separators and a tab read as a blank, as do a comment and a heredoc
      # operator or body, which are not words.
      function pbyte(k,   cc) {
        if (k in DROP || C[k] == "m" || C[k] == "h" || C[k] == "b") return " "
        cc = X[k]
        if (cc == "\n") return (C[k] == "c" || C[k] == "Q" || C[k] == "B") ? ";" : " "
        if (cc == "\037" || cc == "\036" || cc == "\t") return " "
        return cc
      }
      function piece(a, z, n,   k, any) {
        any = 0
        for (k = a; k <= z; k++) if (!(k in DROP) && X[k] !~ /[ \t\n]/) { any = 1; break }
        if (!any) return
        put(n "\037")
        for (k = a; k <= z; k++) put(pbyte(k))
        put("\037")
        for (k = a; k <= z; k++) {
          if (k in DROP) put(" ")
          else if (k in VAL) put(VAL[k] == "\n" || VAL[k] == "\t" || VAL[k] == "\037" || VAL[k] == "\036" ? " " : VAL[k])
          else if (!RM[k]) put(pbyte(k))
        }
        put("\n")
      }

      # A byte that ends a word at the top level: unquoted blank or operator
      # in code that is not nested, or anything the shell does not read as a
      # word (a comment, a heredoc operator or body).
      function word_sep(k) {
        if (C[k] == "m" || C[k] == "h" || C[k] == "b" || C[k] == "B" || C[k] == "p") return 1
        return C[k] == "c" && DEP[k] == 1 && X[k] ~ /[ \t\n;&|()<>]/
      }
      function mark(a, z,   k) { for (k = a; k <= z; k++) A[k] = 1 }
      # Mark the prefixes each top-level statement starts with, and the blanks
      # after each. A word is cut only by word_sep, so a quoted or nested value
      # (FOO="a b", FOO=$(cmd arg), FOO=a\ b) stays one word -- the sed this
      # replaced read a value as the bytes up to the first blank or quote.
      function prefixes(   k, s, w, atstart, envmode, takes, hit, execmode, cmdmode, timemode) {
        atstart = 1; envmode = 0; takes = 0; execmode = 0; cmdmode = 0; timemode = 0; k = 1
        while (k <= N) {
          if (word_sep(k)) {
            if (X[k] ~ /[\n;&|(]/ || C[k] == "p") { atstart = 1; envmode = 0; takes = 0; execmode = 0; cmdmode = 0; timemode = 0 }
            k++; continue
          }
          s = k; w = ""
          while (k <= N && !word_sep(k)) { w = w X[k]; k++ }
          if (!atstart) continue
          hit = 0
          if (takes) { takes = 0; hit = 1 }
          else if (envmode && w ~ /^-/) { if (w ~ /^(-u|--unset|-C|--chdir)$/) takes = 1; hit = 1 }
          else if (execmode && w ~ /^-[a-z]+$/) { if (w ~ /a$/) takes = 1; hit = 1 }
          else if (cmdmode && w == "-p") hit = 1
          else if (timemode && w == "-p") hit = 1
          else if (w ~ /^[A-Za-z_][A-Za-z0-9_]*=/) hit = 1
          else if (w == "env") { envmode = 1; hit = 1 }
          else if (w == "exec") { envmode = 0; execmode = 1; cmdmode = 0; hit = 1 }
          else if (w == "command") { envmode = 0; cmdmode = 1; execmode = 0; hit = 1 }
          else if (w == "time") { envmode = 0; timemode = 1; continue }
          else if (w ~ /^(!|[{]|if|then|else|elif|while|until|do|coproc)$/) { envmode = 0; continue }
          else { atstart = 0; envmode = 0; continue }
          mark(s, k - 1)
          while (k <= N && C[k] == "c" && DEP[k] == 1 && (X[k] == " " || X[k] == "\t")) { A[k] = 1; k++ }
        }
      }

      function push(k) {
        d++; ctx[d] = k; par[d] = 0; pnp[d] = np; besc[d] = 0; cpat[d] = 0; cpw[d] = 0; adol[d] = 0; glc[d] = 0
        if (k == "D") dq++
        if (k == "H") hn++
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
      function cmdpos(j,   k, w) {
        k = j - 1
        while (k >= 1 && (X[k] == " " || X[k] == "\t" || C[k] == "l")) k--
        if (k < 1 || X[k] ~ /[\n;&|(!{)`]/) return 1
        w = ""
        while (k >= 1 && X[k] ~ /[a-z]/) { w = X[k] w; k-- }
        return w ~ /^(if|then|else|elif|while|until|do|time)$/
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
        else { i = j + 1; delete PS[d, par[d] + 1]; delete PS[d, par[d] + 2]; delete GL[d, par[d] + 1]; delete GL[d, par[d] + 2]; par[d] += 2 }
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
      # removed. A quoted delimiter makes the body literal.
      function heredoc_op(j,   k, strip, w, q, cc, sk) {
        k = j + 2; strip = 0
        if (X[k] == "-") { strip = 1; k++ }
        while (X[k] == " " || X[k] == "\t") k++
        w = ""; q = 0
        while (k <= N) {
          cc = X[k]
          if (cc ~ /[ \t\n;&|()<>]/) break
          if (cc == "\\") { q = 1; w = w X[k+1]; k += 2; continue }
          if (cc == "\047") { q = 1; k++; while (k <= N && X[k] != "\047") { w = w X[k]; k++ } k++; continue }
          if (cc == "\042") { q = 1; k++; while (k <= N && X[k] != "\042") { if (X[k] == "\\") k++; w = w X[k]; k++ } k++; continue }
          w = w cc; k++
        }
        if (w == "") { C[j] = cls; return j }
        np++; pd[np] = w; ps[np] = strip; pq[np] = q; pstart[np] = j; pdq[np] = (dq > 0); pb[np] = (ctx[d] == "B")
        pS[np] = 0
        for (sk = d; sk > 1; sk--) if (ctx[sk] == "S") { pS[np] = 1; break }
        for (mm = j; mm < k && mm <= N; mm++) C[mm] = "h"
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
            e = s; line = ""
            while (1) {
              while (e <= N && X[e] != "\n") { line = line X[e]; e++ }
              if (!pq[p] && e <= N && line ~ /(^|[^\\])(\\\\)*\\$/) { line = substr(line, 1, length(line) - 1); e++; continue }
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
              for (kk = s; kk < s + lead + length(pd[p]); kk++) C[kk] = "b"
              if (s + lead + length(pd[p]) - 1 >= s) JMP[s] = s + lead + length(pd[p]) - 1
              np = 0
              return j
            }
            if (t == pd[p]) {
              body_region(bs, s - 1, p)
              for (kk = s; kk < e; kk++) C[kk] = "b"
              if (e <= N) C[e] = "b"
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
        for (kk = bs; kk <= be; kk++) BF[kk] = p
        if (pq[p]) {
          for (kk = bs; kk <= be; kk++) C[kk] = "b"
          JMP[bs] = be
          return
        }
        nh++; HSTART[bs] = nh; HEND[nh] = be
      }
      # The scripts the command hands to a shell. Words are cut where the shell
      # cuts them (word_sep) and read after its quote removal, so a script word
      # holding escaped quotes, blanks in quotes, glued quoting, an ANSI-C word or
      # escaped blanks is the string the shell passes. Each record ends in \035:
      # `S` and the word after `sh|bash|zsh|dash -...c`, or `E` and the words
      # after `eval` joined by blanks. A $\047...\047 escape this cannot name
      # adds a record `!`.
      function emit_cscripts(   k, w, inw, n, W) {
        buf = ""; held = 0; n = 0; w = ""; inw = 0
        for (k = 1; k <= N + 1; k++) {
          if (k > N || word_sep(k)) {
            if (inw) { W[++n] = w; w = ""; inw = 0 }
            if (k > N || C[k] == "p" || C[k] == "c" && DEP[k] == 1 && X[k] ~ /[\n;&|()]/) { cscripts_of(W, n); n = 0 }
            continue
          }
          inw = 1
          if (k in DROP) continue
          if (k in VAL) w = w VAL[k]
          else if (!RM[k]) w = w X[k]
        }
        if (aqbad) put("!\035")
        printf "%s", buf
      }
      # A shell is any command word whose name ends in sh (ksh, csh, tcsh, fish
      # as well as sh, bash, zsh, dash): the reader it replaced matched those
      # by a regex open on the left, and narrowing it to four names passed
      # `ksh -c "pip install ..."` with no verdict (caught in review). Options
      # may stand before -c: -o and +o take a name, -- ends the options.
      function cscripts_of(W, n,   j, m, s, base, args) {
        for (j = 1; j <= n; j++) {
          base = W[j]; sub(/.*\//, "", base)
          if (base ~ /sh$/ && j < n) {
            for (m = j + 1; m <= n; m++) {
              # -o, or a cluster ending in o (-euo), takes the next word as an option name
              if (W[m] ~ /^[-+][A-Za-z]*o$/) { m++; continue }
              if (W[m] ~ /^-[A-Za-z]*c[A-Za-z]*$/) {
                s = m + 1
                if (s <= n && W[s] == "--") s++
                if (s <= n) { put("S" W[s] "\035"); j = s }
                break
              }
              if (W[m] ~ /^[-+][A-Za-z]+$/ || W[m] == "--") continue
              break
            }
            continue
          }
          if (W[j] == "eval" && j < n) {
            args = ""
            for (m = j + 1; m <= n; m++) args = args (m > j + 1 ? " " : "") W[m]
            put("E" args "\035"); break
          }
        }
      }
      function emit_substs(   k, a, z, t, b) {
        buf = ""; held = 0
        for (k = 1; k <= nsub; k++) {
          a = sbeg[k]; z = send[k]
          for (t = a; t <= z; t++) {
            b = X[t]
            # The shell unescapes a backtick body before it reads it.
            if (skind[k] == "B" && b == "\\" && t < z && (X[t+1] == "`" || X[t+1] == "\\" || X[t+1] == "$")) { t++; b = X[t] }
            put(b)
          }
          put("\n")
        }
        printf "%s", buf
      }
      function put(s) {
        buf = buf s
        if (++held >= 4096) { printf "%s", buf; buf = ""; held = 0 }
      }
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
          if (view == "noredir") { put((k in DROP) ? " " : cc); continue }
          if (view == "scan" || view == "live" || view == "stmts") {
            # A code `#` is never a comment start here, and must not become one
            # when the scan is read again: after a blanked region (a quoted word
            # with a `#` glued to its closing quote) or an escaped blank, which
            # this view prints as a blank, it would follow a blank, which is
            # where a comment starts (form WB7).
            if (cl == "p" && view == "stmts") put(";")
            # A statement ends only at a top-level separator: not inside a
            # substitution, an expansion or arithmetic, and not in a
            # redirection operator (`>|`, `<&-`, `2>&1`). command_statements
            # cut wherever these bytes were, so the words after
            # `$(pwd | sed x)` or `>| f` left the install (caught in review).
            else if (view == "stmts" && cl == "c" && (DEP[k] != 1 || (k in DROP)) && cc ~ /[;&|\n]/) put(cc == "\n" ? " " : "_")
            else if (cl == "c" || cl == "p") put(cc == "#" && (k == 1 || C[k-1] != "c" && C[k-1] != "e" || C[k-1] == "e" && X[k-1] ~ /[ \t]/) ? "_" : cc)
            else if (cl == "e") put(index(";&|()<>!{}#`\042\047\\$", cc) ? "_" : (cc == "\n" ? " " : cc))
            else if (view == "live" && (cl == "Q" || cl == "B")) put(cc)
            else put(" ")
            continue
          }
          if (view == "unprefixed" || view == "unprefixed-lines") {
            if (!(k in A)) put(cl == "p" ? ";" : cc)
            continue
          }
          if (view == "code") {
            if (cl == "m" || cl == "h" || cl == "b") put(cc == "\n" && cl != "h" ? "\n" : " ")
            else put(cc)
            continue
          }
          # joined
          if (cl == "l") continue
          if (cl == "m" || cl == "h") { put(" "); continue }
          if (cl == "b") { put(" "); continue }
          if (cc == "\n") {
            if (cl == "c") put("\n")
            else if (cl == "Q" || cl == "B") put(";")
            else put(" ")
            continue
          }
          put(cc)
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

normalize_install_text() {
  local text="$1" view="unprefixed"
  local normalized unprefixed
  # `lines`: <text> holds one statement per line, each read on its own.
  [[ "${2:-}" != lines ]] || view="unprefixed-lines"

  # An absolute path before an executable reads as the executable.
  if ! normalized=$(printf '%s' "${text}" | sed -E \
    -e 's/^[[:space:]]+//' \
    -e "s#(^|[[:space:];|&({!])(/[^[:space:];|&]+/)(${SAFEDEPS_G_EXECUTABLES}|sh|bash|zsh)([[:space:];|&]|\$)#\\1\\3\\4#g"); then
    # Empty text would read as "no install". Keep what there is and let the
    # gate settle the failure.
    guard_mark_reading_failed
    printf '%s' "${text}"
    return
  fi
  # The prefixes a statement may start with -- assignments, env with its
  # options and assignments, command, exec -- are removed by the lexer, which
  # knows where a value ends however it is quoted or nested. The sed this
  # replaced read a value as the bytes up to the first blank or quote, so
  # `FOO="a b" pip install evil==6.6.6` and `FOO=$(cmd arg) pip install ...`
  # kept their prefix and the install after it was never recognized (caught in
  # review). A failed reading keeps the text it had and is recorded.
  if unprefixed=$(shell_lex "${normalized}" "${view}" "safedeps:normalize_install_text"); then
    normalized="${unprefixed}"
  fi
  printf '%s' "${normalized}"
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

# The three payload readers below take text whose heredoc bodies are already
# stripped, and never strip it again. A body is data, so reading `sh -c` out of
# one made a heredoc that quotes an attack form read as that attack; but
# stripping twice is not a no-op either (see exec_text_pipes_to_shell), and the
# candidate texts are stripped before they get here -- a reader that stripped
# again dropped every line after a heredoc, so `sh -c` and `eval` installs
# written after one passed with no verdict (caught in review). Callers strip,
# once.
extract_shell_c_payloads() {
  read_payload_scripts "$1" S
}

extract_eval_payloads() {
  read_payload_scripts "$1" E
}

# The scripts <text> hands to `sh -c` (kind S) or to `eval` (kind E), one per
# line, read off the lexer's cscripts view: the word the shell passes, quotes
# removed and escapes applied, and recursively the scripts inside those.
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
  local text="$1" kind="$2" depth="${3:-0}" out rec
  out=$(shell_lex "${text}" cscripts "safedeps:read_payload_words") || return 0
  while IFS= read -r -d $'\035' rec; do
    if [[ "${rec}" == "!" ]]; then
      guard_mark_reading_failed
      continue
    fi
    [[ "${rec}" == "${kind}"* ]] && printf '%s\n' "${rec:1}"
    # A script holding another: `sh -c 'sh -c "pip install ..."'`.
    (( depth < 3 )) && read_payload_scripts "${rec:1}" "${kind}" $(( depth + 1 ))
  done <<< "${out}"
}

extract_command_substitution_payloads() {
  # The bodies as the lexer delimits them. The string scan this replaced cut a
  # body at its first `)` (so a case pattern ended it) and did not unescape or
  # nest backticks, and it was a second parser of the command.
  shell_lex "$1" substs "safedeps:extract_command_substitution_payloads"
}

# Install text as the pipe checks search for it: a manager, then a verb
# anywhere after it on the same line. Loose on purpose -- it reads text that is
# data at its own quoting level, where no statement grammar applies.
# The visible installs the blanking pass sets aside, found the way detection
# finds them: detection strips assignment and env/command prefixes before it
# matches, so the blanking pass has to step over them too. Read on the scan
# view, where a quoted value is already blank. Without the prefix, an install
# behind `PIP_INDEX_URL=x` was not set aside, and the pipe check read it as
# install text piped into a shell (caught in review).
BLANK_INSTALL_RE="${SAFEDEPS_G_START}((env|command)([[:space:]]+-[^[:space:]]*)*[[:space:]]+|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*(${SAFEDEPS_G_INSTALL_BODY})([[:space:]]|\$)"
PIPE_MANAGER_RE='(npm|npx|pnpm|pnpx|yarn|bun|bunx|pip[0-9.]*|(python[0-9.]*|py)[[:space:]]+-m[[:space:]]*pip|poetry|uv|uvx|pipx|pipenv|cargo|go|gem|bundle|mvn|dotnet)'
PIPE_INSTALL_TEXT_RE="${PIPE_MANAGER_RE}.*(${SAFEDEPS_G_ALL_VERBS})"

# The same, with the manager starting a word. Beside a visible install the text
# left after setting the install aside is mostly that install's own arguments,
# and a manager name inside a word matched there -- `go` inside `mongoose` --
# so `npm install mongoose@8.0.0 && cat setup.sh | sh` was denied (caught in
# review). The rest stays loose on purpose: what is piped is data the shell has
# not read yet, and printf escapes, glued quotes, an escaped blank or a `tr`
# turn `pip<something>install` into `pip install` on the way. Requiring whole
# blank-separated words let exactly those through (caught in review).
PIPE_INSTALL_WORD_START_RE="(^|[^[:alnum:]_.-])${PIPE_MANAGER_RE}.*(${SAFEDEPS_G_ALL_VERBS})"

# A pipe into a shell, read on normalized exec text. The consumer ends where the
# shell ends a word: at a blank, and also at an operator, a redirection or a
# group closer, so `| sh; echo`, `| sh&&x` and `(... | sh)` are the same
# consumer as `| sh `. `|&` pipes stderr as well, and a group opener before the
# shell (`| (sh)`, `| { sh; }`) still hands it the input. Each of these used to
# pass unjudged.
PIPE_SHELL_CONSUMER_RE='\|&?[[:space:]]*([({][[:space:]]*)*(bash|sh|zsh)([[:space:];&|)}<>`]|$)'

text_has_install_words() {
  printf '%s\n' "$1" | judge_grep -qEi "${PIPE_INSTALL_TEXT_RE}"
}

text_has_install_words_from_a_word_start() {
  printf '%s\n' "$1" | judge_grep -qEi "${PIPE_INSTALL_WORD_START_RE}"
}

# $1 has its heredoc bodies stripped already. Stripping twice is not a no-op:
# the second pass sees the `<<EOF` line again with no body and no terminator
# after it, and drops every line that follows.
exec_text_pipes_to_shell() {
  local exec_view
  # The consumer side is normalized the same way the producer side already is:
  # `| /bin/sh`, `| env sh`, and `| command sh` are the same consumer as `| sh`.
  # normalize_install_text is the file's existing statement of that equivalence —
  # it was applied to the install text and skipped here, so the two sides of one
  # pipe disagreed about what counts as the same invocation.
  exec_view=$(normalize_install_text "$(command_scan_text "$1")")
  # A line that ends in a pipe continues on the next one, and a heredoc's
  # terminator can sit between them: `cat <<EOF |`, the body, `EOF`, `sh`.
  # Only a pipe or a shell name can meet across the join, so reading the lines
  # as one costs nothing else.
  exec_view="${exec_view//$'\n'/ }"
  printf '%s\n' "${exec_view}" | judge_grep -qEi "${PIPE_SHELL_CONSUMER_RE}"
}

payload_pipes_install_text_to_shell() {
  local payload="$1"

  # The pipe must sit in EXECUTION position at this quoting level: outside
  # quotes (a quoted `| sh` is data — e.g. a repro idiom quoted in a commit
  # message) and outside heredoc bodies (a body is data; `cat <<EOF | sh` keeps
  # its pipe on the redirect line, which survives the strip). The install text
  # is still searched raw, because in a real hidden install it lives inside the
  # producer's quotes or heredoc body by construction.
  #
  # Check the raw install text FIRST: the grep is O(n) while building the exec
  # view is not free, and both checks are pure predicates, so conjunction order
  # cannot change the verdict — only the cost. Most commands carry no install
  # text at all and must not pay for the exec view.
  text_has_install_words "${payload}" || return 1
  exec_text_pipes_to_shell "$(strip_heredoc_bodies "${payload}")"
}

# The same question asked beside a visible install.
#
# payload_pipes_install_text_to_shell searches the whole payload for install
# text. That is right when nothing in the command is an install the gate can
# read: any install text there is something else. Beside a visible install it
# says nothing, because the visible install is install text too, so the
# recognition block never asked it -- and a hidden install piped into a shell
# passed with the visible one (`pip install requests==2.0.0 && printf 'pip
# install evil==6.6.6' | sh` checked requests and ran evil unchecked).
#
# So the visible installs are set aside first. Wherever the install pattern
# matches the scan text -- exactly what command_is_dependency_install reads as
# an install -- the manager word that starts the match is blanked out of the
# raw text, and the whole-payload question is asked of what is left, plus any
# heredoc bodies. A verb with no manager before it no longer reads as install
# text, so that is enough to set the install aside.
#
# Only the manager word goes, not the whole match. A match can run into the
# arguments: the grammar cannot know which options take a value, so in `npx -y
# echo-cli@1.0.0 pip install x | sh` it reads `pip` as the package npx runs,
# and blanking the whole match hid the `pip install` that is echoed into the
# shell (caught before review, by this function's own attack battery).
#
# An install the recognizer only reads after normalize_install_text (`env pip
# install`, `/usr/bin/pip install`) is not matched here and stays in the text.
# That can only turn an allow into a deny, and only beside a pipe into a shell.
payload_pipes_unread_install_text_to_shell() {
  local payload="$1"
  local commands remainder

  [[ "${payload}" == *'|'* ]] || return 1
  commands=$(strip_heredoc_bodies "${payload}")
  # Most visible installs pipe into no shell, and that answer is cheap.
  exec_text_pipes_to_shell "${commands}" || return 1

  remainder=$(install_managers_blanked "${commands}") || return 1
  text_has_install_words_from_a_word_start "${remainder}" && return 0
  [[ "${payload}" == *'<<'* ]] || return 1
  text_has_install_words_from_a_word_start "$(strip_heredoc_bodies "${payload}" shell-bodies)"
}

# $1 with the manager word of every install-pattern match blanked.
#
# The pattern is matched on the scan text, where quoted regions are blank, so a
# match is never install text inside quotes. The scanner blanks bytes and never
# moves one, so a byte offset into the scan text is the same offset into $1;
# the awk reads the two side by side and refuses a pair where that does not
# hold (the scan may only blank a byte, or write `_` for an escaped operator).
# Only bytes the scan text keeps are blanked. A quote character is blank
# there, so it is never touched and the quote structure of what is left is the
# quote structure of $1 -- blanking a quote would re-quote everything after it.
#
# A failure is recorded like a scanner failure (see command_scan_text), and the
# caller reads it as "no answer", which guard_settle_scan_failure turns into an
# UNDECIDED deny for a command that looks like an install -- and this command
# has a visible one.
install_managers_blanked() {
  local text="$1"
  local scan matches spans=""

  if ! scan=$(command_scan_text "${text}"); then
    return 1
  fi
  # `offset:match` per match, 0-based byte offsets. No match is not an error:
  # the text is then returned whole, which only keeps more install text in it.
  # The grep and the awk run apart so that only "no match" reads as no spans: a
  # failed awk used to be swallowed by the same `||`, and the visible install it
  # should have blanked was then read as install text piped into a shell -- a
  # finding drawn from a failed reading (caught in review).
  matches=$(printf '%s\n' "${scan}" | LC_ALL=C judge_grep -obEi "${BLANK_INSTALL_RE}") || matches=""
  if [[ -n "${matches}" ]] && ! spans=$(printf '%s\n' "${matches}" | LC_ALL=C awk '
    # safedeps:install_match_spans (scripts/measure/scan-failure-census.sh keys on this line)
    { c = index($0, ":"); printf "%d:%d ", substr($0, 1, c - 1), length($0) - c }'); then
    [[ -z "${SAFEDEPS_SCAN_MARK:-}" ]] || printf 'failed\n' >> "${SAFEDEPS_SCAN_MARK}"
    return 1
  fi

  if ! { printf '%s\n' "${spans}"; printf '%s\n' "${text}"; printf '%s' "${scan}"; } |
    SAFEDEPS_PIPE_MANAGER_RE="${PIPE_MANAGER_RE}" LC_ALL=C awk '
    # safedeps:install_managers_blanked (scripts/test/scan-contract.sh keys on this line)
    NR == 1 { nspan = split($0, span, " "); next }
    {
      if (NR > 2) X[++n] = "\n"
      m = split($0, c, "")
      for (j = 1; j <= m; j++) X[++n] = c[j]
    }
    END {
      # The raw text, a newline, then its scan text: 2L + 1 bytes in all.
      if (n % 2 == 0) exit 2
      L = (n - 1) / 2
      if (X[L + 1] != "\n") exit 2
      # The scan only blanks a byte or, for an escaped operator, writes `_`.
      for (i = 1; i <= L; i++) {
        s = X[L + 1 + i]
        if (s != X[i] && s != " " && s != "_") exit 2
      }
      # The first manager word inside each match, read on the scan text.
      mre = ENVIRON["SAFEDEPS_PIPE_MANAGER_RE"]
      for (k = 1; k <= nspan; k++) {
        split(span[k], p, ":")
        str = ""
        for (i = p[1] + 1; i <= p[1] + p[2] && i <= L; i++) str = str X[L + 1 + i]
        # The manager word as a whole word: `pip` inside `PIP_INDEX_URL=x pip
        # install` is no manager, and blanking it left the real install to be
        # read as install text piped into a shell (caught in review).
        s = tolower(str); slen = length(s); from = 1; at = 0
        while (from <= slen && match(substr(s, from), mre)) {
          a = from + RSTART - 1; z = a + RLENGTH
          pre = (p[1] + a - 1 >= 1) ? tolower(X[L + 1 + p[1] + a - 1]) : ""
          post = (z <= slen) ? substr(s, z, 1) : ""
          if (pre !~ /[a-z0-9_]/ && post !~ /[a-z0-9_]/) { at = a; alen = RLENGTH; break }
          from = a + 1
        }
        if (!at) continue
        for (i = p[1] + at; i < p[1] + at + alen; i++)
          if (X[L + 1 + i] != " " && X[i] != "\n") X[i] = " "
        # The assignment prefixes of the install are its arguments, not install
        # text: `PIP_INDEX_URL=x` left `pip` at a word start for the loose
        # search of the pipe check. A name is blanked always; it runs no code.
        # A value is blanked only when it holds no `$`, backtick or
        # parenthesis, so a substitution in it is still read.
        j = 1
        while (j < at) {
          while (j < at && substr(s, j, 1) ~ /[ \t]/) j++
          w0 = j
          while (j < at && substr(s, j, 1) !~ /[ \t]/) j++
          word = substr(s, w0, j - w0)
          if (!match(word, /^[a-z_][a-z0-9_]*=/)) continue
          e = (word ~ /[$`()]/) ? w0 + RLENGTH - 2 : j - 1
          for (q = w0; q <= e; q++) {
            i = p[1] + q
            if (X[L + 1 + i] != " " && X[i] != "\n") X[i] = " "
          }
        }
      }
      buf = ""; held = 0
      for (i = 1; i <= L; i++) {
        buf = buf X[i]
        if (++held >= 4096) { printf "%s", buf; buf = ""; held = 0 }
      }
      printf "%s", buf
    }
  '; then
    [[ -z "${SAFEDEPS_SCAN_MARK:-}" ]] || printf 'failed\n' >> "${SAFEDEPS_SCAN_MARK}"
    return 1
  fi
}

# The command as lines the shell reads as statements (the joined view): line
# continuations removed, newlines inside quotes, heredoc bodies and comments
# blanked.
join_line_continuations() {
  shell_lex "$1" joined "safedeps:join_line_continuations"
}

# The joined view of <text> in the current reading, read again. A reader that
# lexes the joined lines again reads them out of the context the first lexing
# had: live code in an unquoted heredoc body lands on one line with the code
# after the body, and lexed again at the top level, a quote in that body code
# (`$((cat <<EOF` then `it's` in a body) opened a quote that never closed and
# took the install after the body along (fuzz form F19, seed 20261001). Where
# <text> closes in this reading and its joined view does not, that second
# reading failed, and the gate settles it as one (UNDECIDED), never as "no
# install". Where <text> itself does not close, the reading already says so.
join_line_continuations_checked() {
  local f1 f2 joined
  if ! f1=$(mktemp "${TMPDIR:-/tmp}/safedeps-lex.XXXXXX" 2>/dev/null) || ! f2=$(mktemp "${TMPDIR:-/tmp}/safedeps-lex.XXXXXX" 2>/dev/null); then
    [[ -z "${f1:-}" ]] || rm -f "${f1}"
    guard_mark_reading_failed
    join_line_continuations "$1"
    return
  fi
  joined=$(SAFEDEPS_LEX_FLAGS="${f1}" shell_lex "$1" joined "safedeps:join_line_continuations")
  if ! grep -q '^UNTERM$' "${f1}" 2>/dev/null; then
    SAFEDEPS_LEX_FLAGS="${f2}" shell_lex "${joined}" scan "safedeps:command_scan_text" > /dev/null
    grep -q '^UNTERM$' "${f2}" 2>/dev/null && guard_mark_reading_failed
  fi
  rm -f "${f1}" "${f2}"
  printf '%s' "${joined}"
}

command_candidate_texts() {
  local command="$1"

  command=$(join_line_continuations_checked "${command}")

  normalize_install_text "${command}"
  printf '\n'
  command_payload_texts "${command}"
}

# The payloads of a command whose heredoc bodies are stripped and whose line
# continuations are joined: the text a `sh -c`, an `eval` or a command
# substitution hands to a shell, normalized, one per line. command_candidate_texts
# is the command itself followed by these.
command_payload_texts() {
  local command="$1"
  local payload

  while IFS= read -r payload; do
    [[ -z "${payload}" ]] && continue
    normalize_install_text "${payload}"
    printf '\n'
  done < <(extract_shell_c_payloads "${command}")
  while IFS= read -r payload; do
    [[ -z "${payload}" ]] && continue
    normalize_install_text "${payload}"
    printf '\n'
  done < <(extract_eval_payloads "${command}")
  while IFS= read -r payload; do
    [[ -z "${payload}" ]] && continue
    normalize_install_text "${payload}"
    printf '\n'
  done < <(extract_command_substitution_payloads "${command}")
}

command_is_injectable_npm_install() {
  local command="$1"
  local scan_command
  local npm_install_pattern

  npm_install_pattern="${SAFEDEPS_G_NPM_INSTALL_RE}"

  while IFS= read -r scan_command; do
    scan_command=$(command_scan_text "${scan_command}")
    echo "${scan_command}" | judge_grep -qEi "${npm_install_pattern}" && return 0
  done < <(command_candidate_texts "${command}")
  return 1
}

command_has_ignore_scripts_flag() {
  local command="$1"
  local scan_command

  while IFS= read -r scan_command; do
    scan_command=$(command_scan_text "${scan_command}")
    echo "${scan_command}" | judge_grep -qEi -- '(^|[[:space:]])--ignore-scripts([=[:space:]]|$)' && return 0
  done < <(command_candidate_texts "${command}")
  return 1
}

# True when appending `--ignore-scripts` to the end of the command would not put
# it on the npm install: the command chains more than one statement at the shell
# level (a `;`, `&&`, `||`, or `|` OUTSIDE quotes), runs over more than one line,
# or holds a `#` outside quotes. Quoted text is blanked by command_scan_text first
# so `echo "a && b"` is NOT a reason. Appending to a compound command lands the
# flag on the trailing statement (finding #7); appending after a comment lands it
# inside the comment, where the shell never passes it to npm and the lifecycle
# scripts run while the meta says they were suppressed (`npm ci # rebuild`,
# caught in the linearize design judgment). Appending after a heredoc lands it
# after the terminator. A `#` inside a word is not a comment, but the in-place
# rewrite is correct there too, so no attempt is made to tell them apart.
command_needs_inplace_inert() {
  local scanned code
  scanned=$(command_scan_text "$1")
  [[ "${scanned}" == *$'\n'* ]] && return 0
  # A group, a substitution or an expansion: the flag appended to the end lands
  # outside it, or becomes an argument of what it expands to.
  printf '%s' "${scanned}" | judge_grep -qE '[;&|()`$]' && return 0
  # An install that is not the command's own code -- a script handed to
  # `sh -c` or `eval` -- is not where an appended flag lands: it would become
  # that script's $0.
  printf '%s' "${scanned}" \
    | judge_grep -qE "npm${SAFEDEPS_G_OPTS}[[:space:]]+(${SAFEDEPS_G_NPM_VERBS}|${SAFEDEPS_G_NPM_LINK_VERBS})([[:space:]]|\$)" || return 0
  # A comment or a heredoc: the code view blanks both, so it differs from the
  # command wherever one is. The scan view blanks them too, which is why this
  # cannot be read off the scan view the way `;&|` are.
  code=$(strip_heredoc_bodies "$1")
  [[ "${code}" != "$1" ]]
}

# Offsets just past each npm install verb in <text>, one per line, read on the
# live view, so a verb in a comment, a quoted string or a heredoc body is not
# one, and a verb in a substitution inside quotes is. The live view keeps every
# byte in place, so an offset there is the offset in <text>.
inert_verb_ends() {
  local live matches
  live=$(shell_lex "$1" live "safedeps:inert_offsets") || return 1
  # The grep and the awk run apart so that only "no match" reads as no verb: a
  # failed awk shared one `||` with grep's exit 1, and the rewrite was then
  # dropped as if there were nothing to rewrite.
  matches=$(printf '%s\n' "${live}" \
    | LC_ALL=C judge_grep -obE "npm${SAFEDEPS_G_OPTS}[[:space:]]+(${SAFEDEPS_G_NPM_VERBS}|${SAFEDEPS_G_NPM_LINK_VERBS})([[:space:]]|\$)") || matches=""
  [[ -n "${matches}" ]] || return 0
  if ! printf '%s\n' "${matches}" | LC_ALL=C awk '
    # safedeps:inert_offsets (scripts/measure/scan-failure-census.sh keys on this line)
    { c = index($0, ":"); m = substr($0, c + 1); e = substr($0, 1, c - 1) + length(m); if (m ~ /[[:space:]]$/) e--; print e }'; then
    [[ -z "${SAFEDEPS_SCAN_MARK:-}" ]] || printf 'failed\n' >> "${SAFEDEPS_SCAN_MARK}"
    return 1
  fi
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

# Offsets just past every npm install verb the shell runs in <text>: its own
# code (the live view) and, recursively, the scripts it hands to a shell.
# Returns 3 when an install sits where no offset can reach it.
inert_offsets_of() {
  local text="$1" depth="${2:-0}" spans start len body inner e
  inert_verb_ends "${text}" || return 1
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
    for e in ${inner}; do
      printf '%s\n' "$(( start + e ))"
    done
  done <<< "${spans}"
}

# The command with `--ignore-scripts` inserted right after every npm install
# verb the shell runs: in the command's own code, in a substitution, and in a
# script it hands to `sh -c` or `eval`. Prints nothing when no verb was found.
# Returns 3, printing nothing, when an npm install sits where the rewrite cannot
# reach it -- a double-quoted script with an escape or a substitution in it, a
# heredoc piped into a shell -- so the caller records the downgrade instead of
# reporting the command inert.
#
# A raw-text rewrite used to land on an `npm i` inside a trailing comment and
# count that as done, and could not see past a quoted option value (caught in
# review); the scan view that replaced it blanked quoted scripts, so an install
# in `sh -c '...'` beside a visible one ran its lifecycle scripts with nothing
# recorded (caught in the release integration).
inert_rewrite_in_place() {
  local command="$1" offsets rc=0
  offsets=$(inert_offsets_of "${command}") || rc=$?
  (( rc == 0 )) || return "${rc}"
  if strip_heredoc_bodies "${command}" shell-bodies \
      | LC_ALL=C judge_grep -qE "npm${SAFEDEPS_G_OPTS}[[:space:]]+(${SAFEDEPS_G_NPM_VERBS}|${SAFEDEPS_G_NPM_LINK_VERBS})([[:space:]]|\$)"; then
    return 3
  fi
  offsets=$(printf '%s\n' "${offsets}" | LC_ALL=C sort -nu | tr '\n' ' ')
  [[ -n "${offsets// /}" ]] || return 0
  if ! { printf '%s\n' "${offsets}"; printf '%s' "${command}"; } | LC_ALL=C awk '
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
      printf "%s", buf
    }
  '; then
    [[ -z "${SAFEDEPS_SCAN_MARK:-}" ]] || printf 'failed\n' >> "${SAFEDEPS_SCAN_MARK}"
    return 1
  fi
}

# The statements of a command, one per line, as
# `<before>\035<text>\035<after>\035<words>\035<raw>`. <before> and <after> are the separators
# around the statement (`start`, `;`, `&&`, `||`, `|`, `&`, `end`) and <text> is
# its quote-blanked text, so a separator inside quotes is not one. Fields are
# split on \035 rather than a tab because `read` merges adjacent tabs, and an
# empty field (a statement with no words) then shifted the next one into it. A newline
# separates like `;`, and a redirection (`2>&1`, `&>`, `|&`) does not split a
# statement.
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
# the statement) carried as \036. It is what the spec extractor reads, so the
# extractor and resolve_install_targets read the same statements and a
# statement's landing travels with its text instead of being joined to it.
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
  printf '%s' "$1" > "${raw_file}"
  # The stmts view ends a statement at a case pattern's `)` as well. On the
  # scan view an arm after the first was split out as `*) pip install ...`,
  # where the `)` no longer closes a pattern, so the install was not at a
  # statement start: no spec and no record (caught when the lexer and the
  # extractor met in the release tree).
  shell_lex "$1" stmts "safedeps:command_scan_text" > "${scan_file}"
  if ! LC_ALL=C awk -v scan_file="${scan_file}" -v raw_file="${raw_file}" '
    # safedeps:command_statements (scripts/measure/scan-failure-census.sh and scripts/test/scan-contract.sh key on this line)
    function slurp(f,   out, line, count) {
      out = ""; count = 0
      while ((getline line < f) > 0) out = out (count++ ? "\n" : "") line
      close(f)
      return out
    }
    function word_end() {
      if (has) words = words (words == "" ? "" : "\037") word (dyn ? "\001" : "")
      word = ""; has = 0; dyn = 0
    }
    function words_of(from, to,   i, ch, q) {
      words = ""; word = ""; has = 0; dyn = 0; q = ""
      for (i = from; i <= to; i++) {
        ch = r[i]
        if (q == "") {
          if (ch == " " || ch == "\t" || ch == "\n") { word_end(); continue }
          if (ch == "\\") { if (i < to) { i++; word = word r[i]; has = 1 }; continue }
          if (ch == "\047") { q = "s"; has = 1; continue }
          if (ch == "\"") { q = "d"; has = 1; continue }
          if (ch == "$" || ch == "`" || ch == "*" || ch == "?" || ch == "[") dyn = 1
          if (ch == "~" && !has) dyn = 1
          word = word ch; has = 1
          continue
        }
        if (q == "s") { if (ch == "\047") q = ""; else word = word ch; continue }
        if (ch == "\\" && i < to && (r[i + 1] == "$" || r[i + 1] == "`" || r[i + 1] == "\"" || r[i + 1] == "\\")) {
          i++; word = word r[i]; continue
        }
        if (ch == "\"") { q = ""; continue }
        if (ch == "$" || ch == "`") dyn = 1
        if (ch == "\n" || ch == "\t") ch = " "
        word = word ch
      }
      word_end()
      return words
    }
    function raw_of(from, to,   i, ch, out) {
      out = ""
      for (i = from; i <= to; i++) {
        ch = r[i]
        if (ch == "\t" || ch == "\035" || ch == "\037") ch = " "
        else if (ch == "\n") ch = "\036"
        out = out ch
      }
      return out
    }
    function emit(nx, to) {
      text = cur; gsub(/[\t\035]/, " ", text)
      printf "%s\035%s\035%s\035%s\035%s\n", prev, text, nx, words_of(from, to), raw_of(from, to)
      prev = nx; cur = ""
    }
    BEGIN {
      n = split(slurp(scan_file), c, "")
      split(slurp(raw_file), r, "")
      prev = "start"; cur = ""; from = 1
      for (i = 1; i <= n; i++) {
        ch = c[i]
        if (ch == ";" || ch == "\n") { emit(";", i - 1); from = i + 1; continue }
        if (ch == "&") {
          if (c[i - 1] == ">" || c[i + 1] == ">") { cur = cur ch; continue }
          if (c[i + 1] == "&") { emit("&&", i - 1); i++; from = i + 1; continue }
          emit("&", i - 1); from = i + 1; continue
        }
        if (ch == "|") {
          if (c[i + 1] == "|") { emit("||", i - 1); i++; from = i + 1; continue }
          to = i - 1
          if (c[i + 1] == "&") i++
          emit("|", to); from = i + 1; continue
        }
        cur = cur ch
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
# the command (command_statements), as `<kind>\035<dir>\035<why>\035<raw>`.
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
# <raw> is the statement as command_statements gives it.
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
  local cmd="$1" cwd="$2" stripped
  stripped=$(strip_heredoc_bodies "${cmd}")
  resolve_reading_targets "$(join_line_continuations "${stripped}")" "${cwd}"
  return 0
}

# Where npm says an install lands (lib/npm/ask.sh), asked once per run for each
# question. Every reading resolves the statements it reads, and where the
# readings agree they ask the same question; each ask costs two npm processes
# and up to its deadline. The answer is kept in the run's private memo
# directory under the whole question -- the directory, the npm word, the
# environment words and the arguments, everything but the deadline -- and a
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

# The statements and where each lands (see resolve_install_targets). <text> is
# the joined view of the command.
resolve_reading_targets() {
  local text="$1" cwd="$2"
  local before stmt after words raw head target want kind manager tok value normalized in_env skip
  local user_rc cli_global_off why run_dir answer local_prefix npm_word npm_unknown i
  local dir="${cwd}" grouped=false env_userconfig=false exports_unknown=""
  local npm_until="" here cond_dir="" depth=0 conditional
  local -a toks=() npm_env=() npm_args=() npm_exports=()

  command_scan_text "${text}" | judge_grep -q '[(){}`]' && grouped=true
  command_scan_text "${text}" | judge_grep -qEi 'npm_config_userconfig=' && env_userconfig=true

  while IFS=$'\035' read -r before stmt after words raw; do
    if [[ "${before}" == "?" ]]; then
      printf '?\035?\035the command could not be split into statements (awk failed), so safedeps cannot tell where its installs land\035\n'
      continue
    fi
    kind=- target="" why=""
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

      # A statement may open with a group or a reserved word; the command is
      # what follows. A word that opens a compound command counts toward the
      # depth a `cd` is conditional at.
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
        export)
          # An npm setting exported earlier reaches every later npm, so the ask
          # carries it too. One the shell decides at run time, or one exported
          # where it may not reach the install (a group, a subshell), makes every
          # later npm install's directory unknown.
          for tok in "${toks[@]:1}"; do
            [[ "${tok}" == *=* ]] || continue
            value="${tok%%=*}"
            [[ "$(printf '%s' "${value}" | tr '[:upper:]' '[:lower:]')" == npm_config_* ]] || continue
            if [[ "${grouped}" == true || "${tok}" == *$'\001'* ]]; then
              exports_unknown="${tok%$'\001'}"
            else
              npm_exports+=("${tok}")
            fi
          done
          break
          ;;
      esac

      command_is_dependency_install "${stmt}" || break

      # Kind is read from the statement as the other recognizers read it, with
      # `VAR=value` prefixes and `env` wrappers stripped: `npm_config_save=false
      # npm install x` is an npm install.
      normalized=$(normalize_install_text "${stmt}")
      kind=other
      # The runner test is guard_segment_is_runner's, spelled out: that function
      # is defined further down, past the point where this one first runs.
      if ! command_scan_text "${normalized}" | grep -qEi "${SAFEDEPS_G_RUNNER_HEAD_RE}" \
          && printf '%s' "${normalized}" | grep -qEi "${SAFEDEPS_G_NPM_INSTALL_RE}"; then
        kind=npm
      fi
      manager=""
      if [[ "${kind}" == npm ]]; then
        manager=npm
      elif printf '%s' "${normalized}" | grep -qEi '(^|[[:space:]])pnpm([[:space:]]|$)'; then
        manager=pnpm
      fi

      # `env -C <dir>` / `env --chdir <dir>` runs the command in <dir>; its
      # options come before the first word that is neither an option nor an
      # assignment. That is the directory npm runs in. The other managers'
      # relocation flags are read here too; npm's own (`--prefix`, `-C`) are
      # npm's to read, below.
      run_dir="${here}"
      target="${here}"
      want=""
      skip=false
      in_env=false
      [[ "${toks[0]}" == env ]] && in_env=true
      for tok in "${toks[@]:1}"; do
        if [[ "${skip}" == true ]]; then skip=false; continue; fi
        if [[ -n "${want}" ]]; then
          if [[ "${want}" == env ]]; then
            run_dir=$(guard_literal_dir "${run_dir}" "${tok}")
          fi
          target=$(guard_literal_dir "${target}" "${tok}")
          want=""
          continue
        fi
        if [[ "${in_env}" == true ]]; then
          case "${tok}" in
            -C|--chdir) want=env; continue ;;
            --chdir=*)
              run_dir=$(guard_literal_dir "${run_dir}" "${tok#*=}")
              target=$(guard_literal_dir "${target}" "${tok#*=}")
              continue
              ;;
            -u|--unset) skip=true; continue ;;
            -*|*=*) continue ;;
            *) in_env=false ;;
          esac
        fi
        case "${tok}" in
          --prefix=*|--cwd=*|--dir=*|--install-dir=*)
            target=$(guard_literal_dir "${target}" "${tok#*=}")
            ;;
          --prefix|--cwd|--dir|--install-dir) want=1 ;;
          -C)
            if [[ -n "${manager}" ]]; then want=1; fi
            ;;
          -C?*)
            if [[ -n "${manager}" ]]; then target="?"; fi
            ;;
        esac
      done
      if [[ -n "${want}" ]]; then target="?"; run_dir="?"; fi
      why=""

      [[ "${kind}" == npm ]] || break
      # `npm link <pkg>` installs a package the global tree lacks into npm's
      # global prefix from the registry (lib/commands/link.js linkInstall),
      # whatever the flags say: with `--global` npm refuses to run it at all.
      if command_scan_text "${normalized}" | grep -qEi "${SAFEDEPS_G_NPM_LINK_RE}"; then
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
      # The words before npm go to env(1) in front of it, and the words after
      # it are npm's arguments, unchanged.
      npm_env=("${npm_exports[@]+"${npm_exports[@]}"}")
      npm_args=()
      npm_word=""
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
          if [[ "${want}" == u ]]; then npm_env+=("${tok}"); fi
          want=""
          continue
        fi
        [[ "${tok}" != *$'\001' ]] || { npm_unknown="${tok%$'\001'}"; continue; }
        case "${tok}" in
          npm|*/npm) npm_word="${tok}"; continue ;;
          env) in_env=true; continue ;;
          command|exec) continue ;;
        esac
        if [[ "${in_env}" == true ]]; then
          case "${tok}" in
            -C|--chdir) skip=true; continue ;;
            --chdir=*) continue ;;
            -u|--unset) npm_env+=(-u); skip=true; want=u; continue ;;
            --unset=*) npm_env+=(-u "${tok#*=}"); continue ;;
            -i|--ignore-environment) npm_env+=(-i); continue ;;
            -*) npm_unknown="env ${tok}"; continue ;;
          esac
        fi
        if [[ "${tok}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
          npm_env+=("${tok}")
          continue
        fi
        npm_unknown="${tok}"
      done
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
      answer=$(guard_npm_install_target "${run_dir}" "${npm_until}" "${npm_word}" \
        "${npm_env[@]+"${npm_env[@]}"}" -- "${npm_args[@]+"${npm_args[@]}"}")
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
          user_rc="${npm_config_userconfig:-${NPM_CONFIG_USERCONFIG:-${HOME}/.npmrc}}"
        fi
      fi
      case "${user_rc}" in
        '~/'*) user_rc="${HOME}/${user_rc#'~/'}" ;;
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
    printf '%s\035%s\035%s\035%s\n' "${kind}" "${target}" "${why}" "${raw}"
  done < <(command_statements "${text}")
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
  local stripped payload payloads=0
  stripped=$(strip_heredoc_bodies "${cmd}")

  while IFS= read -r payload; do
    [[ -n "${payload}" ]] || continue
    if command_scan_text "${payload}" | judge_grep -qEi "${SAFEDEPS_G_NPM_INSTALL_RE}"; then
      payloads=$(( payloads + 1 ))
    fi
  done < <(command_payload_texts "$(join_line_continuations "${stripped}")")

  guard_reading_writers_unattributable "$(join_line_continuations "${stripped}")" "${payloads}"
}

# guard_npm_writers_unattributable over the joined view <text>, with
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
      case "${toks[i]}" in
        npm|*/npm) npm_at=${i}; break ;;
      esac
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
# command that needed none, where the other direction skips the check.
guard_command_has_npm_install() {
  local seg rc
  while IFS= read -r seg; do
    rc=0
    command_scan_text "${seg}" | grep -qEi "${SAFEDEPS_G_NPM_INSTALL_RE}" || rc=$?
    (( rc == 1 )) || return 0
  done < <(command_candidate_texts "$1")
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
# budget window, plus slack. The cost outside the window is structural, not
# proportional to the command:
#   - up to 1.0s waiting out the final poll step (the step doubles and caps at 1s)
#   - up to 0.5s of TERM grace before the KILL (10 polls x 50ms)
#   - reap, jq, process start and payload parse: ~0.1s
# That is a 1.6s structural worst case. Measured end-to-end overshoot past the
# budget was 0.73-1.05s and flat from 4KB to 256KB of command text (2026-08-04,
# same machine as the 30s kill measurement). 30 - 25 = 5s of headroom, i.e.
# ~3x the structural worst case and ~5x the measured one, which is what a
# loaded machine needs before an on-time answer becomes a late one.
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
  # `sleep` per step and starts fine-grained, so a fast judgment is delayed by
  # at most the first 50ms step while a long one still coasts on 1s steps.
  budget_waited_ms=0
  budget_step_ms=50
  budget_timed_out=false
  budget_deadline_ms=$(( SAFEDEPS_SELF_BUDGET_SECONDS * 1000 ))
  while kill -0 "${budget_child}" 2>/dev/null; do
    if (( budget_waited_ms >= budget_deadline_ms )); then
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
    sleep "$(printf '%d.%03d' $(( budget_step_ms / 1000 )) $(( budget_step_ms % 1000 )))"
    budget_waited_ms=$(( budget_waited_ms + budget_step_ms ))
    # Plain `if`, not `(( ... )) && assign`: under `set -e` a false arithmetic
    # test makes the whole && list fail and takes the guard down with it.
    budget_step_ms=$(( budget_step_ms * 2 ))
    if (( budget_step_ms > 1000 )); then
      budget_step_ms=1000
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
# failed.
guard_looks_like_install_unscanned() {
  local re="(${SAFEDEPS_G_EXECUTABLES})" rc=0
  shopt -s nocasematch
  [[ "${COMMAND}" =~ ${re} ]] || rc=1
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
  grep -q '^UNTERM$' "${flags}" 2>/dev/null && rc=1
  rm -f "${flags}"
  return ${rc}
}

# The ecosystem of ONE statement, read from the manager that starts it.
guard_segment_ecosystem() {
  local scan
  scan=$(command_scan_text "$1")
  if echo "${scan}" | judge_grep -qEi "${SAFEDEPS_G_START}(npm|pnpm|pnpx|yarn|npx|bun|bunx)([[:space:]]|\$)"; then
    printf 'npm'
  elif echo "${scan}" | judge_grep -qEi "${SAFEDEPS_G_START}(pip[0-9.]*|poetry|uv|uvx|pipx|pipenv|(python[0-9.]*|py)${SAFEDEPS_G_OPTS}[[:space:]]+-m[[:space:]]*pip)([[:space:]]|\$)"; then
    printf 'pypi'
  elif echo "${scan}" | judge_grep -qEi "${SAFEDEPS_G_START}cargo([[:space:]]|\$)"; then
    printf 'crates.io'
  elif echo "${scan}" | judge_grep -qEi "${SAFEDEPS_G_START}go([[:space:]]|\$)"; then
    printf 'go'
  elif echo "${scan}" | judge_grep -qEi "${SAFEDEPS_G_START}(gem|bundle)([[:space:]]|\$)"; then
    printf 'rubygems'
  elif echo "${scan}" | judge_grep -qEi "${SAFEDEPS_G_START}mvn([[:space:]]|\$)"; then
    printf 'maven'
  elif echo "${scan}" | judge_grep -qEi "${SAFEDEPS_G_START}dotnet([[:space:]]|\$)"; then
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
  local seg eco

  while IFS= read -r seg; do
    [[ "${seg}" =~ [^[:space:]] ]] || continue
    command_is_dependency_install "${seg}" || continue
    eco=$(guard_segment_ecosystem "${seg}")
    [[ -n "${eco}" ]] && { printf '%s' "${eco}"; return 0; }
  done < <(command_candidate_texts "${cmd}" | tr ';|&' '\n')
  printf ''
}

# True when <name> resolves to a binary the project already has AND the runner
# is one that prefers it (npx, npm exec/x, bunx, bun x, and npm init and bun
# create, which run through those). pnpm dlx, yarn dlx (and so pnpm create and
# yarn create), uvx and pipx run always fetch.
guard_runner_uses_local_bin() {
  local seg="$1" name="$2"
  [[ "${name}" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  [[ -x "${PROJECT_DIR:-.}/node_modules/.bin/${name}" ]] || return 1
  command_scan_text "${seg}" | judge_grep -qEi "${SAFEDEPS_G_START}((npx|bunx)([[:space:]]|\$)|npm${SAFEDEPS_G_OPTS}[[:space:]]+(${SAFEDEPS_G_NPM_EXEC_VERBS}|${SAFEDEPS_G_NPM_INIT_VERBS})([[:space:]]|\$)|bun${SAFEDEPS_G_OPTS}[[:space:]]+(x|create|c)([[:space:]]|\$))"
}

# True when the statement is a runner: something that fetches a package and
# executes it (npx, npm exec, pnpm dlx, bunx, uvx, pipx run, go run ...).
guard_segment_is_runner() {
  command_scan_text "$1" | judge_grep -qEi "${SAFEDEPS_G_RUNNER_HEAD_RE}"
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
    command_scan_text "${payload}" | judge_grep -qEi "${SAFEDEPS_G_NPM_INSTALL_RE}" && return 1
  done < <(command_payload_texts "$(join_line_continuations "$(strip_heredoc_bodies "${cmd}")")")
  return 0
}

# Each runner's options, from its own help, in three kinds: an option whose
# value names the package to fetch (`npx --package x cmd`, `uvx --from x cmd`),
# one whose value adds a package next to it (`uvx --with x ruff`), and one whose
# value is anything else and so is not an operand. Only options that always take
# a value are listed; one whose value is optional, or one the table does not
# know, leaves the next token as an operand, which can only add a check. A
# `--name=value` spelling carries its own value and is never in question.
#
# The tables exist because one shared reading did not fit any runner: every
# unknown option was skipped and the next token taken as the package, so
# `uvx --python 3.12 ruff==0.1.0` checked nothing and recorded `pypi:3.12`, and
# `npx --cache /tmp/c evil@1.0.0` recorded `npm:/tmp/c`. And `-p` named the
# package for every runner, though uv reads it as `--python`.
#
#   npm   npx, npm exec, npm x: every npm config whose type has no Boolean, and
#         their short forms, from npm 11.19.0's own definitions
#         (@npmcli/config/lib/definitions). `-p` is npx's `--package`.
#         `npm exec` and `npm x` hand their arguments to nopt, which also lets
#         an option written without `=` take a following `true` or `false`,
#         `null` where its type allows null, `--color` take `always`, and
#         `--browser` take anything that is not an option (measured against
#         npm's nopt and types). npx does not: its own first pass puts `--` in
#         front of the first token it reads as the package, so `npx --yes false
#         x` runs the package `false` (bin/npx-cli.js), and the table alone is
#         its whole reading. Both were measured by running npx's first pass
#         and npm's nopt on the arguments, with the command itself stubbed out.
#   pnpm  pnpx, pnpm dlx: `pnpm dlx --help` (10.28.1) and pnpm's global
#         `--dir`/`-C`, `--filter`/`-F`, `--loglevel`. `-c` is `--shell-mode`, a
#         boolean here. Whether pnpm, like nopt, lets a boolean take a
#         following `true` is not measured (pnpm ships as one binary), so it is
#         read as not taking it: if pnpm does, the record names `true` instead
#         of hiding a package.
#   yarn  yarn dlx: yarnpkg.com/cli/dlx (`-p,--package`, `-q`).
#   bun   bunx, bun x: `bunx --help` (1.3.14).
#   uv    uvx, uv tool run: `uvx --help` (0.10.11); the two list the same
#         options. `-p` is `--python`, `-w` is `--with`.
#   pipx  pipx run: `pipx run --help` (1.12.0). Its parser is argparse with
#         abbreviations allowed, so `--pyth` is `--python`; a long option that
#         is the start of exactly one of pipx run's options is read as that one.
#   go    go run: `go help run` and `go help build` (go1.26.5). Go reads `-x`
#         and `--x` alike.
SAFEDEPS_RUNNER_NAMES_PACKAGE_npm=" -p --package "
SAFEDEPS_RUNNER_ADDS_PACKAGE_npm=" "
SAFEDEPS_RUNNER_TAKES_VALUE_npm="
  --enjoy-by --reg -C -L -c -m -w --_auth --access --allow-directory
  --allow-file --allow-git --allow-remote --allow-scripts --also
  --audit-level --auth-type --before --ca --cache --cache-max --cache-min
  --cafile --call --cert --cidr --cpu --depth --diff --diff-dst-prefix
  --diff-src-prefix --diff-unified --editor --expect-result-count --expires
  --fetch-retries --fetch-retry-factor --fetch-retry-maxtimeout
  --fetch-retry-mintimeout --fetch-timeout --git --globalconfig --heading
  --https-proxy --include --init-author-email --init-author-name
  --init-author-url --init-license --init-module --init-type --init-version
  --init.author.email --init.author.name --init.author.url --init.license
  --init.module --init.version --install-strategy --key --libc
  --local-address --location --lockfile-version --loglevel --logs-dir
  --logs-max --maxsockets --message --min-release-age
  --min-release-age-exclude --name --node-gyp --node-options --noproxy
  --omit --only --orgs --orgs-permission --os --otp --pack-destination
  --packages --packages-and-scopes-permission --password --prefix
  --preid --provenance-file --proxy --registry --replace-registry-host
  --save-prefix --sbom-format --sbom-type --scope --scopes --script-shell
  --searchexclude --searchlimit --searchopts --searchstaleness --shell --tag
  --tag-version-prefix --token-description --umask --user-agent --userconfig
  --viewer --which --workspace "
SAFEDEPS_RUNNER_NAMES_PACKAGE_pnpm=" --package "
SAFEDEPS_RUNNER_ADDS_PACKAGE_pnpm=" "
SAFEDEPS_RUNNER_TAKES_VALUE_pnpm=" --allow-build --reporter --dir -C --filter -F --loglevel "
SAFEDEPS_RUNNER_NAMES_PACKAGE_yarn=" -p --package "
SAFEDEPS_RUNNER_ADDS_PACKAGE_yarn=" "
SAFEDEPS_RUNNER_TAKES_VALUE_yarn=" "
SAFEDEPS_RUNNER_NAMES_PACKAGE_bun=" -p --package "
SAFEDEPS_RUNNER_ADDS_PACKAGE_bun=" "
SAFEDEPS_RUNNER_TAKES_VALUE_bun=" "
SAFEDEPS_RUNNER_NAMES_PACKAGE_uv=" --from "
SAFEDEPS_RUNNER_ADDS_PACKAGE_uv=" -w --with "
SAFEDEPS_RUNNER_TAKES_VALUE_uv="
  --with-editable --with-requirements -c --constraints -b --build-constraints
  --overrides --env-file --python-platform --torch-backend --index
  --default-index -i --index-url --extra-index-url -f --find-links
  --index-strategy --keyring-provider -P --upgrade-package --resolution
  --prerelease --fork-strategy --exclude-newer --exclude-newer-package
  --no-sources-package --reinstall-package --link-mode -C --config-setting
  --config-settings-package --no-build-isolation-package --no-build-package
  --no-binary-package --cache-dir --refresh-package -p --python --color
  --allow-insecure-host --directory --project --config-file "
SAFEDEPS_RUNNER_NAMES_PACKAGE_pipx=" --spec "
SAFEDEPS_RUNNER_ADDS_PACKAGE_pipx=" --with "
SAFEDEPS_RUNNER_TAKES_VALUE_pipx=" --python --fetch-python -i --index-url --pip-args --backend "
SAFEDEPS_RUNNER_LONG_OPTIONS_pipx=" --help --quiet --verbose --global --no-cache --path --pypackages --with
  --spec --python --fetch-python --fetch-missing-python --system-site-packages --index-url
  --editable --pip-args --backend "
# Options whose type allows null, for nopt's `null` (npm exec only).
SAFEDEPS_RUNNER_NOPT_NULL_npm=" --browser --expect-results --optional --production --workspaces --yes -y "
SAFEDEPS_RUNNER_NAMES_PACKAGE_go=" "
SAFEDEPS_RUNNER_ADDS_PACKAGE_go=" "
SAFEDEPS_RUNNER_TAKES_VALUE_go="
  -C -p -covermode -coverpkg -asmflags -buildmode -compiler -gccgoflags
  -gcflags -installsuffix -ldflags -mod -modfile -overlay -pgo -pkgdir -tags
  -toolexec -exec "

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
# A path names a local template or component, which is not a fetch, so it
# prints nothing (npm refuses one as an unrecognized initializer). Anything else
# (a URL) is printed as written.
guard_create_identity() {
  local family="$1" spec="$2" scope="" name="" version=""
  case "${family}" in
    bun)
      case "${spec}" in
        react|next) return 0 ;;
        elysia|elysia-buchta|stric) printf '@bun-examples/%s\n' "${spec}"; return 0 ;;
      esac
      ;;
  esac
  case "${spec}" in
    .*|/*|~*) return 0 ;;
    *://*) printf '%s\n' "${spec}"; return 0 ;;
  esac
  if [[ "${spec}" =~ ^(@[^/@]+)(@.*)?$ ]]; then
    printf '%s/create%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
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
          printf '%s%s%s\n' "${scope}" "${name}" "${version}"
        fi
        name="create-${name}"
        ;;
      *) name="create-${name}" ;;
    esac
    printf '%s%s%s\n' "${scope}" "${name}" "${version}"
    return 0
  fi
  if [[ "${family}" == npm && "${spec}" =~ ^((github|gitlab|bitbucket|gist):)?([^/:@]+)/([^/#:]+)(#.*)?$ ]]; then
    printf '%s%s/create-%s%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}"
    return 0
  fi
  printf '%s\n' "${spec}"
}

guard_runner_operands() {
  # Runner forms (`npx`, `pnpm dlx`, `yarn dlx`, `bunx`, `uvx`, `pipx run`, ...)
  # EXECUTE a package; tokens after the executed package are arguments to that
  # program, NOT package specs. Emit only the spec-bearing operands: the value
  # of an option that names or adds a package, plus the first bare token (the
  # executed package). Which options those are, and which take a value that is
  # not a package, depends on the runner (the tables above).
  # This stops an argument such as an email (`ops@example.test`) or a secret
  # value passed to `npx wrangler ...` from being misread as a `pkg@spec`.
  #
  # It reads the statement's words, quotes already removed by the lexer
  # (guard_extract_pieces): `npx "cowsay@1.5.0"` runs cowsay@1.5.0.
  #
  # A failed sed here is a failed spec reader (see guard_operand_specs): it
  # yields no operand, and no operand reads as nothing to check.
  local text="$1" after head family names adds takes want tok key nopt last="" match option create=false
  local -a toks=()
  # The runner itself is kept, ahead of \037, to choose the table. The first
  # line is taken here rather than by `head -n1`, which can close the pipe on a
  # sed that still has lines to write, and pipefail reads that SIGPIPE as a
  # failed reader.
  after=$(printf '%s\n' "${text}" \
    | sed -nE "s/^(.*[[:space:];&|({!])?(${SAFEDEPS_G_RUNNER_BODY})([[:space:]]|\$)/\\2"$'\037'"/p") || guard_mark_reading_failed
  after="${after%%$'\n'*}"
  [[ "${after}" == *$'\037'* ]] || return 0
  head="${after%%$'\037'*}"
  after="${after#*$'\037'}"
  [[ "${after}" =~ [^[:space:]] ]] || return 0
  nopt=false
  case "${head%%[[:space:]]*}" in
    npx) family=npm ;;
    npm) family=npm nopt=true ;;
    pnpx|pnpm) family=pnpm ;;
    yarn) family=yarn ;;
    bunx|bun) family=bun ;;
    uvx|uv) family=uv ;;
    pipx) family=pipx ;;
    go) family=go ;;
    *) family=npm ;;
  esac
  key="SAFEDEPS_RUNNER_NAMES_PACKAGE_${family}"; names="${!key}"
  key="SAFEDEPS_RUNNER_ADDS_PACKAGE_${family}"; adds="${!key}"
  key="SAFEDEPS_RUNNER_TAKES_VALUE_${family}"; takes="${!key}"
  takes=" ${takes//$'\n'/ } "
  # A `create`: its first operand is rewritten into the package that runs. npm
  # init hands its other options to nopt like any npm command and ignores
  # `--package`, which is then just an option with a value. pnpm create and bun
  # create name no package by option; yarn create passes `-p` on to dlx.
  case "${family}:${head##*[[:space:]]}" in
    npm:*)
      if [[ "${head##*[[:space:]]}" =~ ^(${SAFEDEPS_G_NPM_INIT_VERBS})$ ]]; then
        create=true names=" " takes="${takes}--package "
      fi
      ;;
    pnpm:create|bun:create|bun:c) create=true names=" " ;;
    yarn:create) create=true ;;
  esac

  local named_by_option=false
  want=""
  read -ra toks <<< "${after}"
  for tok in "${toks[@]+${toks[@]}}"; do
    case "${want}" in
      names) printf '%s\n' "${tok}"; named_by_option=true; want=""; continue ;;
      adds) printf '%s\n' "${tok}"; want=""; continue ;;
      takes) want=""; continue ;;
      flag)
        # nopt's reading of the token after an option that took no value.
        want=""
        case "${tok}" in
          true|false) continue ;;
          null) [[ "${family}" == npm && "${SAFEDEPS_RUNNER_NOPT_NULL_npm}" == *" ${last} "* ]] && continue ;;
          always) [[ "${family}" == npm && "${last}" == --color ]] && continue ;;
        esac
        [[ "${family}" == npm && "${last}" == --browser && "${tok}" != -* ]] && continue
        ;;
    esac
    # bun create takes as its template the first argument that does not start
    # with `--` (create_command.rs), so a single-dash word is the template.
    if [[ "${create}" == true && "${family}" == bun && "${tok}" == -[!-]* ]]; then
      guard_create_identity bun "${tok}"
      break
    fi
    # An abbreviated long option, where the runner's parser accepts one.
    if [[ "${family}" == pipx && "${tok}" == --?* ]]; then
      key="${tok%%=*}"
      if [[ "${SAFEDEPS_RUNNER_LONG_OPTIONS_pipx}" != *" ${key} "* ]]; then
        match=""
        for option in ${SAFEDEPS_RUNNER_LONG_OPTIONS_pipx}; do
          [[ "${option}" == "${key}"* ]] && match+="${option} "
        done
        [[ "${match}" == *" "?* || -z "${match}" ]] || tok="${match% }${tok#"${key}"}"
      fi
    fi
    case "${tok}" in
      -*=*)
        key="${tok%%=*}"
        if [[ "${names}" == *" ${key} "* ]]; then
          printf '%s\n' "${tok#*=}"
          named_by_option=true
        elif [[ "${adds}" == *" ${key} "* ]]; then
          printf '%s\n' "${tok#*=}"
        fi
        ;;
      -*)
        if [[ "${names}" == *" ${tok} "* ]]; then
          want=names
        elif [[ "${adds}" == *" ${tok} "* ]]; then
          want=adds
        elif [[ "${takes}" == *" ${tok} "* ]] \
            || [[ "${family}" == go && "${takes}" == *" ${tok#-} "* ]]; then
          want=takes
        elif [[ "${nopt}" == true && "${tok}" != -- ]]; then
          want=flag
          last="${tok}"
        fi
        ;;
      *)
        # The executed package -- unless an option already named the package,
        # in which case this is the command it provides (`npx -p x@1 x-cli`).
        if [[ "${named_by_option}" != true ]]; then
          if [[ "${create}" == true ]]; then
            guard_create_identity "${family}" "${tok}"
          else
            printf '%s\n' "${tok}"
          fi
        fi
        break
        ;;
    esac
  done
}

guard_names_package_without_spec() {
  # True when an install NAMES a package but carries no version spec, so the
  # ledger gate never ran for it. Used only to make that fact observable — it
  # changes no verdict. Every such operand is left in UNGATED_OPERANDS as
  # `<ecosystem>:<operand>`, for the record to name.
  #
  # The unit is the operand, and it is read through the same parse the gate
  # reads (guard_operand_specs over guard_extract_statement_text). Three rounds
  # of review each found a record missing because this walk used to be a second
  # parser: it read the statement on its own, then asked the extractor "was this
  # package pinned?" by name. Each round narrowed the name (token shape, then
  # name, then ecosystem and name) and each round a collision survived:
  # `pnpm add x@1 && pnpm add x` quieted the second install because the first
  # pinned the same name. The same split ran the other way too: the walk did not
  # know which tokens the extractor had consumed as a flag's value, so
  # `gem install rails -v 7.1.0` was gated AND recorded as unpinned, on `7.1.0`.
  # There is no name join now. An operand is pinned when the extractor bound
  # THIS token: its position is one the extractor reports, or its text is the
  # text of a spec the extractor produced from this statement.
  #
  # So an extractor misreading shows up here instead of being buried: when it
  # reads `left-pad@npm:evil-pkg` as `left-pad@npm`, the token is not that text
  # and is recorded.
  #
  # The boundary is what keeps this record readable. A record that fires on
  # routine installs becomes background noise, and background noise is the same
  # as no record. So a token is a named package only if it survives these
  # tests, each of which exists because getting it wrong hides a real install
  # or invents one:
  #
  #   1. It is not a flag, and not the VALUE of a flag. A source flag consumes
  #      its own argument and nothing more — `-r requirements.txt` names no
  #      package, but `-r requirements.txt evil` still installs `evil`.
  #      Silencing the whole command on sight of `-r`/`-c`/`-e` hid that, and
  #      `-c` is not even a source flag: a constraint file only bounds versions
  #      while the install target still arrives on the command line. `-e`
  #      consumes nothing here either — its argument is judged like any other
  #      token, so `-e .` falls out as a working-tree build while
  #      `-e git+ssh://…` stays the fetch it is. A version flag's value is
  #      known from the extractor, which consumed it.
  #   2. It is not a local path (`.`, `..`, `./x`, `/x`). Those install from the
  #      working tree, not from a registry. A module path like
  #      `example.com/evil` is NOT a local path and stays reportable.
  #   3. A URL names a package and pins nothing, whatever `@` it carries:
  #      `git+ssh://git@host/evil.git` is no more pinned than
  #      `git+https://host/evil.git`.
  #   4. The extractor did not bind it (above).
  #
  # Statements are skipped whole in two cases. One whose ecosystem cannot be
  # read (the outer view of `bash -c '...'`, where the payload is blank) is
  # skipped as the extractor skips it; the payload is a candidate text of its
  # own and is read there. And a statement the effect gate answers for -- an
  # npm CLI install the lockfiles record, whose trace the PostToolUse hook
  # looks for -- is exempt; the rest of the command is not. A payload's install is never exempt, because where it
  # lands is decided inside the payload.
  #
  # It reads GUARD_READINGS, the extractor's reading of the command that the
  # gate took its specs from (guard_extract_specs ... readings): per statement
  # the ecosystem, whether it is a runner, the statement, the text it parsed,
  # and its spec and position lines. Parsing the command again here, even once,
  # doubled the guard's cost on a many-statement command and put a 4KB one past
  # the self-budget.
  local line seg seg_ecosystem text runner gate_reads f1 f2 f3 pinned bound consumed
  local open=false
  UNGATED_OPERANDS=""

  while IFS= read -r line; do
    case "${line}" in
      S$'\t'*)
        [[ "${open}" == true ]] && guard_walk_statement
        # Fields are cut with expansions, not `read <<<`: bash 3.2 writes a
        # temp file for every here-string, and this loop runs per line.
        line="${line#S$'\t'}"
        seg_ecosystem="${line%%$'\t'*}"
        line="${line#*$'\t'}"
        runner="${line%%$'\t'*}"
        gate_reads="${line#*$'\t'}"
        seg="" text="" pinned=$'\n' bound=" " consumed=" " open=true
        ;;
      G$'\t'*) seg="${line#G$'\t'}" ;;
      T$'\t'*) text="${line#T$'\t'}" ;;
      *)
        f1="${line%%$'\t'*}"
        line="${line#*$'\t'}"
        f2="${line%%$'\t'*}"
        f3="${line#*$'\t'}"
        if [[ "${f1}" == "@" ]]; then
          [[ "${f2}" == bound ]] && bound+="${f3} "
          [[ "${f2}" == consumed ]] && consumed+="${f3} "
        elif [[ -n "${f2}" ]]; then
          pinned+="${f2}@${f3}"$'\n'
        fi
        ;;
    esac
  done <<< "${GUARD_READINGS}"
  [[ "${open}" == true ]] && guard_walk_statement
  [[ -n "${UNGATED_OPERANDS}" ]]
}

# The operand walk over one statement, as guard_names_package_without_spec read
# it: seg, seg_ecosystem, runner, gate_reads, text, pinned, bound and consumed
# are the caller's. A statement whose install the effect gate reads is exempt as
# a whole (guard_effect_gate_reads, carried here as gate_reads).
guard_walk_statement() {
  local tok idx verb_seen verb_tok="" skip_next found=""
  local -a toks=()

  [[ "${gate_reads}" == true ]] && return 0

  # Split the way awk splits the same text, so a position means one token on
  # both sides: on blanks, with globbing off so that a token such as `x==1.*`
  # stays itself.
  set -f
  # shellcheck disable=SC2206
  toks=( ${text} )
  set +f

  verb_seen=false
  skip_next=false
  idx=0
  for tok in "${toks[@]+${toks[@]}}"; do
    idx=$((idx + 1))
    [[ "${bound}" == *" ${idx} "* || "${consumed}" == *" ${idx} "* ]] && continue

    if [[ "${runner}" == true ]]; then
      # A runner's text is its package operands only (guard_runner_operands).
      [[ "${pinned}" == *$'\n'"${tok}"$'\n'* ]] && continue
      # npx, npm exec and bunx run a binary the project already has without
      # fetching anything, so `npx tsc` in a TypeScript project is not an
      # install. Only a name with no local binary is fetched, and only that
      # is worth a record; recording every `npx tsc` would bury the ones that
      # matter.
      guard_runner_uses_local_bin "${seg}" "${tok}" && continue
      found+="${tok}"$'\n'
      continue
    fi

    # Maven's coordinate flag may sit on either side of the goal
    # (`mvn -Dartifact=g:x dependency:get`), so it is tested outside the verb
    # gate that orders the operand walk. One the extractor bound was skipped
    # above; any other names a package with no version it could read
    # (`g:evil`, `g:evil:`). Whether Maven accepts a versionless coordinate is
    # unverified (no maven on the measuring machine), and for a RECORD the
    # unresolved case resolves toward reporting: a spurious line costs a line,
    # a missing one costs the invariant this layer exists to keep.
    case "${tok}" in
      -Dartifact=*) found+="${tok}"$'\n'; continue ;;
    esac

    if [[ "${verb_seen}" != true ]]; then
      safedeps_grammar_is_verb "${tok}" && { verb_seen=true; verb_tok="${tok}"; }
      continue
    fi

    # `dotnet add [<project>] package <id>`: the keyword and the project file
    # are not packages. The .NET 10 spellings, `dotnet package add <id>` and
    # `dotnet package update <id>[@<version>]`, open the walk at `package`, and
    # their first operand is the verb.
    if [[ "${seg_ecosystem}" == "nuget" ]]; then
      if [[ "${verb_tok}" == package ]]; then
        verb_tok=""
        [[ "${tok}" == add || "${tok}" == update ]] && continue
      fi
      case "${tok}" in
        package|*.csproj|*.fsproj|*.vbproj|*.sln|*.slnx) continue ;;
      esac
    fi

    if [[ "${skip_next}" == true ]]; then
      skip_next=false
      continue
    fi

    # A comment ends the statement. Redirections are gone already (the lexer
    # pieces view).
    [[ "${tok}" == \#* ]] && break

    # npm link reads each argument the way npm-package-arg does and installs
    # every one that is not local code (lib/commands/link.js:92-104). A
    # directory or a file is linked as written and names no package here; a
    # git or URL argument is fetched, and is read here so it is recorded.
    if [[ "${seg_ecosystem}" == npm && "${tok}" != -* ]] \
        && [[ "${verb_tok}" =~ ^(${SAFEDEPS_G_NPM_LINK_VERBS})$ ]] \
        && safedeps_npa_is_local "${tok}"; then
      continue
    fi

    case "${tok}" in
      # A flag that takes a separate argument consumes exactly that argument —
      # but WHICH flags take one is a property of the tool, not of the flag
      # spelling. `-t` and `-f` take a value for pip and are booleans for go
      # (`go get -t`), gem (`-f` = --force), and cargo. Applying pip's table
      # everywhere ate the package that followed, so `go get -t example.com/x`
      # went silent while `gem install --force x` stayed reported: one install
      # split by which spelling the author used. That is the same mistake as
      # filing `-c` with `-r` — grouping flags by shape instead of meaning.
      #
      # An unknown flag is therefore assumed NOT to take a value. Guessing
      # wrong in that direction costs a spurious line; guessing wrong the other
      # way drops the install this record exists to catch.
      -r|--requirement|-c|--constraint|-t|--target|-f|--find-links|-i|--index-url|--extra-index-url)
        # Every one of these takes a value for pip and is a boolean somewhere
        # else: gem's `-r` is `--remote`, go's `-t` includes test deps, gem and
        # cargo spell `--force` as `-f`. Only the pypi family consumes an
        # argument here.
        #
        # `-i` is the short form of `--index-url`. Leaving it out did not hide
        # an install — it invented one: the mirror URL read as an operand, so
        # `pip install -i <mirror> -r requirements.txt` filed a spurious
        # record. Same defect as the silences above, pointing the other way,
        # which is why both directions belong in the battery.
        [[ "${seg_ecosystem}" == "pypi" ]] && { skip_next=true; continue; }
        continue
        ;;
      -*) continue ;;
      # Installing from the working tree is not a registry fetch, and a leading
      # tilde is a path once the shell has expanded it.
      .|..|./*|../*|/*|'~'|'~/'*) continue ;;
      *://*) found+="${tok}"$'\n'; continue ;;
    esac

    [[ "${pinned}" == *$'\n'"${tok}"$'\n'* ]] && continue
    found+="${tok}"$'\n'
  done
  [[ -n "${found}" ]] || return 0
  set -f
  for tok in ${found}; do
    guard_note_ungated "${seg_ecosystem}" "${tok}"
  done
  set +f
  return 0
}

# Add `<ecosystem>:<operand>` to UNGATED_OPERANDS once.
guard_note_ungated() {
  local entry="$1:$2"
  [[ ", ${UNGATED_OPERANDS}, " == *", ${entry}, "* ]] && return 0
  UNGATED_OPERANDS="${UNGATED_OPERANDS:+${UNGATED_OPERANDS}, }${entry}"
}

guard_extract_flagged_specs() {
  # Specs carried by a flag rather than by `pkg@version`: pip's `name==version`,
  # gem's `-v`, cargo's `--vers`, bundle's and dotnet's `--version`, maven's
  # `-Dartifact` coordinate. The verb is found past any options between it and
  # the manager (`gem --norc install x -v 1`, `cargo +nightly add x`,
  # `dotnet add App.csproj package X`), which the adjacent-token reading missed.
  #
  # Which operand a version flag pins is the part that has to be right, because
  # the deny message prescribes `safedeps check` on it and an agent runs the
  # prescription by itself. It used to be the first token after the verb that
  # was not a flag, so a value-taking option in front of the package put its
  # VALUE there: `gem install --source https://rubygems.org rake -v 13.0.0`
  # prescribed `check rubygems https://rubygems.org@13.0.0`, which approves (no
  # advisory names a URL), and from then on any gem at 13.0.0 installed with
  # that source passed. Now the version binds to EVERY operand of the verb.
  # An option's value is not an operand when the manager's own help says the
  # option takes one (the tables below: `gem help install`, `bundle add
  # --help`, `cargo install --help`, `cargo add --help`, and the .NET CLI
  # reference for `dotnet add package`, its .NET 10 spelling `dotnet package
  # add`, `dotnet package update`, and `dotnet tool install|update`). Only
  # mandatory values are listed.
  # An option whose value is optional, or one the table does not know, leaves
  # its value as an operand, and that can only add a check -- never skip the
  # package the manager installs.
  #
  # Two kinds of line come out. A spec line is `<pkg><TAB><spec>`, and it is all
  # the gate reads (guard_operand_specs keeps two-field lines). A position line
  # is `@<TAB>bound<TAB><n>` for the token a spec was read from, or
  # `@<TAB>consumed<TAB><n>` for an option value, counting tokens across the
  # whole text. The UNGATED record reads those, so that "pinned" and "is an
  # operand" come from the one reading that produced the spec -- the same
  # branch prints both, and there is no second copy of it to drift.
  awk '
    # safedeps:extract_flagged_specs (scripts/measure/scan-failure-census.sh keys on this line)
    BEGIN {
      takes["gem"]    = " -v --version --vers --platform -i --install-dir -n --bindir --build-root -P --trust-policy --without -B --bulk-threshold -s --source --config-file "
      takes["bundle"] = " -v --version -g --group -s --source -r --retry "
      takes["cargo"]  = " --version --vers --index --registry --git --branch --tag --rev --path --root --message-format --color --config -Z --lockfile-path -F --features -j --jobs --profile --target-dir --rename --manifest-path --base "
      takes["dotnet-add"]  = " -v --version -f --framework -s --source --package-directory --project "
      takes["dotnet-tool"] = " -v --verbosity --version -a --arch --add-source --configfile --framework --source --tool-manifest --tool-path "
      takes["dotnet-update"] = " -v --verbosity --project "
      # Which of those carry the version.
      vers["gem"]    = " -v --version --vers "
      vers["bundle"] = " -v --version --vers "
      vers["cargo"]  = " --version --vers "
      vers["dotnet-add"]  = " -v --version --vers "
      vers["dotnet-tool"] = " --version --vers "
    }
    function verb_after(s, want,   j) {
      for (j = s; j <= NF; j++) {
        if ($j == want) return j
        if ($j !~ /^-/ && $j !~ /^[+]/) return 0
      }
      return 0
    }
    function has(set, t) { return index(set, " " t " ") > 0 }
    # Read tokens s..NF for one manager: bind every version found to every
    # operand, and report every option value as consumed.
    function operands(tool, s,   j, nc, nv, c, v, vp, t, x, y) {
      nc = 0; nv = 0
      for (j = s; j <= NF; j++) {
        t = $j
        # A comment ends the statement; the shell owns it. Redirections are
        # gone from the text already (the lexer pieces view).
        if (t ~ /^#/) break
        if (has(takes[tool], t) && j < NF) {
          print "@\tconsumed\t" (base + j + 1)
          if (has(vers[tool], t)) { v[++nv] = $(j + 1); vp[nv] = j + 1 }
          j++
          continue
        }
        if (t ~ /^--(vers|version)=/ && (has(vers[tool], "--version") || has(vers[tool], "--vers"))) {
          sub(/^--(vers|version)=/, "", t); v[++nv] = t; vp[nv] = 0
          continue
        }
        if (t ~ /^-/ || t ~ /^[+]/) continue
        c[++nc] = j
      }
      for (x = 1; x <= nc; x++)
        for (y = 1; y <= nv; y++) {
          print $(c[x]) "\t" v[y]
          print "@\tbound\t" (base + c[x])
        }
    }
    {
      for (i = 1; i <= NF; i++) {
        # `name==version`, and `name===version` (arbitrary equality, also an
        # exact pin). A wildcard such as `==1.0.*` is not a pin and stays out.
        # A name may start with a digit (`3to2`); requiring a letter read no
        # spec at all for those, so the install went unchecked.
        if ($i ~ /^[A-Za-z0-9][A-Za-z0-9._-]*===?[A-Za-z0-9][A-Za-z0-9._+!~-]*$/) {
          split($i, parts, /===?/)
          print parts[1] "\t" parts[2]
          print "@\tbound\t" (base + i)
        }

        # maven-dependency-plugin: -Dartifact=groupId:artifactId:version[:packaging[:classifier]].
        # OSV names a Maven package groupId:artifactId. A two-field coordinate
        # pins nothing and is left to the UNGATED record.
        if ($i ~ /^-Dartifact=[^:]+:[^:]+:[^:]+/) {
          c0 = $i; sub(/^-Dartifact=/, "", c0); split(c0, m, ":")
          print m[1] ":" m[2] "\t" m[3]
          print "@\tbound\t" (base + i)
        }

        if ($i == "gem" && (k = verb_after(i + 1, "install"))) operands("gem", k + 1)
        if ($i == "cargo" && ((k = verb_after(i + 1, "add")) || (k = verb_after(i + 1, "install")))) operands("cargo", k + 1)
        if ($i == "bundle" && (k = verb_after(i + 1, "add"))) operands("bundle", k + 1)

        if ($i == "dotnet" && (k = verb_after(i + 1, "add"))) {
          for (j = k + 1; j <= NF; j++) if ($j == "package") break
          if (j < NF) operands("dotnet-add", j + 1)
        }
        # .NET 10 spells the same command noun first, with the same arguments:
        # `dotnet package add <id> [--project <p>] [-v <version>]`.
        if ($i == "dotnet" && (k = verb_after(i + 1, "package")) && (k2 = verb_after(k + 1, "add")))
          operands("dotnet-add", k2 + 1)
        # `dotnet package update [<id>[@<version>]...]` (.NET 10) has no version
        # option: its `-v` is --verbosity. A version travels as `<id>@<version>`,
        # which the generic reader takes. Only the option values are read here,
        # so that `-v q` and `--project src/App` are not operands.
        if ($i == "dotnet" && (k = verb_after(i + 1, "package")) && (k2 = verb_after(k + 1, "update")))
          operands("dotnet-update", k2 + 1)

        if ($i == "dotnet" && (k = verb_after(i + 1, "tool"))) {
          if ($(k + 1) == "install" || $(k + 1) == "update") operands("dotnet-tool", k + 2)
        }
      }
      base += NF
    }
  '
}

# Emit "<ecosystem><TAB><package><TAB><spec>" for every operand of one statement.
# With `positions` as the third argument, the flag reader's position lines
# (`@<TAB>bound|consumed<TAB><n>`) come through as well, for the UNGATED record.
# The gate never asks for them, so they cannot move a verdict.
#
# Every reader here is on the verdict path, and every caller reads this through
# a process substitution where a failed stage is invisible: a failed grep or awk
# yields no spec, and no spec reads as "nothing to check". So a failure is
# written to SAFEDEPS_SCAN_MARK, which the top level settles before any allow
# (guard_settle_scan_failure), the same contract as command_scan_text.
guard_operand_specs() {
  local eco="$1" text="$2" mode="${3:-}" token pkg spec rc

  if [[ "${eco}" == "go" ]]; then
    # A Go package is its whole module path. The generic pattern below keeps
    # only the last path element, so `go get example.com/x@v1` was checked as
    # `x@v1` and the deny message prescribed `safedeps check go x@v1`, which
    # approves (no advisory names a bare `x`) and then lets any `.../x@v1`
    # through. The path is kept whole here.
    { printf '%s\n' "${text}" | grep -oE '(^|[[:space:]])[A-Za-z0-9][A-Za-z0-9._~/-]*@[A-Za-z0-9._+~-]+' \
        || { rc=$?; (( rc <= 1 )) || guard_mark_reading_failed; }; } \
      | while read -r token; do
          [[ -n "${token}" ]] || continue
          printf '%s\t%s\t%s\n' "${eco}" "${token%@*}" "${token##*@}"
        done
  else
    # A name may start with a digit (`7zip-bin`, `3to2`). Requiring a letter did
    # not drop the spec -- `grep -o` matched from the first letter, so
    # `pnpm add 7zip-bin@5.2.0` was checked as `zip-bin@5.2.0`, another package.
    { printf '%s\n' "${text}" \
      | grep -oE '(@[a-zA-Z0-9._/-]+/)?[a-zA-Z0-9][a-zA-Z0-9._-]*@[a-zA-Z0-9._^~|<>=*+-]+' \
        || { rc=$?; (( rc <= 1 )) || guard_mark_reading_failed; }; } \
      | while IFS= read -r token; do
          # An email / host operand (user@domain.tld) is never a package spec.
          if [[ "${token}" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
            continue
          fi
          if [[ "${token}" =~ ^(@[^@]+)@(.+)$ ]]; then
            pkg="${BASH_REMATCH[1]}"
            spec="${BASH_REMATCH[2]}"
          else
            pkg="${token%@*}"
            spec="${token##*@}"
          fi
          printf '%s\t%s\t%s\n' "${eco}" "${pkg}" "${spec}"
        done
  fi
  # A pipeline in an `if`: this runs in a subshell under `set -e`, which would
  # otherwise end it on the failure before the mark is written.
  if ! printf '%s\n' "${text}" | guard_extract_flagged_specs \
    | awk -F'\t' -v eco="${eco}" -v positions="${mode}" '
        # safedeps:operand_specs_ecosystem (scripts/measure/scan-failure-census.sh keys on this line)
        NF == 2 { print eco "\t" $1 "\t" $2 }
        NF == 3 && $1 == "@" && positions == "positions" { print }
      '; then
    guard_mark_reading_failed
  fi
}

# One statement as the extractor reads it: a runner's package operands (one per
# line), or the statement's words with their grouping characters blanked.
# <words> is the statement after the shell's quote removal, from the lexer's
# pieces view (guard_extract_pieces): quotes delimit operands and are removed
# before matching, so `pip install "requests==2.0.0"` pins requests, and a
# backslash outside quotes leaves the byte after it, so `pip install
# ev\il==6.6.6` pins evil. Python extras (`evil[x]==1.0.0`) select optional
# dependencies of the same package; the package and its version are what the
# ledger judges. The UNGATED record walks this same text, so that its token
# positions are the extractor's.
guard_extract_statement_text() {
  local eco="$1" words="$2" runner="$3" text
  # Each transform below is a spec reader, and a failed one leaves no text or
  # the wrong text, which reads as no spec. So a failure is marked the way
  # guard_operand_specs marks its own (the runner reader marks inside).
  if [[ "${runner}" == true ]]; then
    text=$(guard_runner_operands "${words}")
  else
    text=$(printf '%s\n' "${words}" | tr '(){}' '    ') || guard_mark_reading_failed
  fi
  if [[ "${eco}" == "pypi" ]]; then
    text=$(printf '%s' "${text}" | sed -E 's/\[[^] ]*\]//g') || guard_mark_reading_failed
  fi
  # An npm alias installs its target under another name: `left-pad@npm:evil-pkg`
  # fetches evil-pkg. Read as written it prescribed `check npm left-pad@npm`,
  # which names neither package and can never approve. The alias name is
  # dropped, so the target is what the ledger judges, pinned or not.
  if [[ "${eco}" == "npm" ]]; then
    text=$(printf '%s' "${text}" | sed -E 's/(^|[[:space:]=])(@[A-Za-z0-9._~-]+\/)?[A-Za-z0-9._~-]+@npm:/\1/g') \
      || guard_mark_reading_failed
  fi
  printf '%s' "${text}"
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

# The statements the spec extractor reads, one piece per line as
# `<read>\t<piece>\037<words>`. <read> is `true` when the effect gate reads the
# install the piece belongs to (guard_effect_gate_reads), and `false`
# otherwise. <piece> is the statement as written, its redirections blanked, and
# <words> the same after the shell's quote removal; both come from one reading
# of the lexer (the pieces view of shell_lex).
#
# The command's own statements come from <targets>, resolve_install_targets'
# list, so the extractor and the landing read the same statements and each one
# carries its landing with it. Joining two separate readings of a command was
# the defect behind three rounds of the UNGATED record (a pin found by name,
# then by ecosystem and name), and a statement found by position in a second
# split would be the same join. The statements are normalized together, one per
# line, and the lexer cuts each at its own `;`, `|`, `&` and newlines, so line N
# is statement N.
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
#
# Payloads (`sh -c`, `eval`, a command substitution) follow, with <read> false:
# where a payload's install lands is decided inside the payload, and the
# landing does not read inside it. Each payload is read on its own, since one
# that its reader could not finish must not run into the next.
guard_extract_pieces() {
  local cmd="$1" targets="$2"
  local kind read_flags="" normalized pieces payload

  while IFS=$'\035' read -r kind _ _ _; do
    [[ -n "${kind}" ]] || continue
    if guard_effect_gate_reads "${kind}"; then
      read_flags+="1"
    else
      read_flags+="0"
    fi
  done <<< "${targets}"

  # One normalization for every statement, as one line each, so line N is
  # statement N. A command substitution drops only trailing empty lines, and
  # an empty statement has nothing to read.
  normalized=$(normalize_install_text "$(
    while IFS=$'\035' read -r kind _ _ raw; do
      [[ -n "${kind}" ]] || continue
      printf '%s\n' "${raw}"
    done <<< "${targets}"
  )" lines)
  # A failed lexer marks the failure itself; an escape it could not read is a
  # `!` line, marked here.
  pieces=$(shell_lex "${normalized}" pieces "safedeps:extract_pieces") || pieces=""
  if ! printf '%s\n' "${pieces}" | LC_ALL=C awk -F'\037' -v flags="${read_flags}" '
    # safedeps:extract_pieces (scripts/test/scan-contract.sh keys on this line)
    $0 == "!" { bad = 1; next }
    NF < 3 || $1 > length(flags) { next }
    { printf "%s\t%s\037%s\n", (substr(flags, $1, 1) == "1" ? "true" : "false"), $2, $3 }
    END { exit bad ? 3 : 0 }'; then
    guard_mark_reading_failed
  fi

  while IFS= read -r payload; do
    [[ "${payload}" =~ [^[:space:]] ]] || continue
    pieces=$(shell_lex "${payload}" pieces "safedeps:payload_pieces") || pieces=""
    printf '%s\n' "${pieces}" | LC_ALL=C awk -F'\037' '
      # safedeps:payload_pieces (scripts/measure/scan-failure-census.sh keys on this line)
      $0 == "!" { bad = 1; next }
      NF >= 3 { printf "false\t%s\037%s\n", $2, $3 }
      END { exit bad ? 3 : 0 }' || guard_mark_reading_failed
  done < <(command_payload_texts "$(join_line_continuations "$(strip_heredoc_bodies "${cmd}")")")
}

guard_extract_specs() {
  # Echo one "eco<TAB>pkg<TAB>spec" line per operand genuinely being installed.
  # Handles @scope/name@spec and bare-name@spec. Precision rules keep non-package
  # "@" tokens from being misread as an install:
  #   1. Only a statement that is itself an install contributes. A non-install
  #      statement (an echo, a path, a comment that merely MENTIONS a
  #      pkg@version) is data -- extracting it would falsely flag
  #      `echo "bumped left-pad@1.0.0"; npm install`.
  #   2. Runner statements (npx / npm exec / pnpm dlx / bunx / uvx ...)
  #      contribute ONLY their executed package -- trailing tokens are program
  #      arguments, so `npx wrangler ... ops@example.test` is never a spec.
  #   3. Email / host operands (user@domain.tld) are never package specs.
  # Each spec carries the ecosystem of the statement it came from. It used to
  # take the command's first ecosystem, so `npm run x && pip install evil==1`
  # checked evil as an npm package, prescribed `safedeps check npm evil@1`, and
  # passed once that approved.
  #
  # <targets> is resolve_install_targets' list for <cmd>; the statements are
  # read from it (guard_extract_pieces).
  #
  # With `readings` as the third argument, each statement it reads is also
  # described for the UNGATED record, which walks exactly these statements and
  # nothing else: `S<TAB><eco><TAB><runner><TAB><read>`, `G<TAB><statement>`,
  # `T<TAB><parsed text>`, then the spec lines and the flag reader's position
  # lines. <read> says whether the effect gate reads the statement's install.
  # The spec lines are the same in both modes; the gate reads only those, so the
  # other lines cannot move a verdict.
  local cmd="$1" targets="$2" mode="${3:-}"
  local seg words eco text text_line runner gate_reads

  # The pieces carry no tab, so the tab and \037 cut the three fields.
  while IFS=$'\t\037' read -r gate_reads seg words; do
    [[ "${seg}" =~ [^[:space:]] ]] || continue
    command_is_dependency_install "${seg}" || continue
    eco=$(guard_segment_ecosystem "${seg}")
    [[ -n "${eco}" ]] || continue
    runner=false
    guard_segment_is_runner "${seg}" && runner=true
    text=$(guard_extract_statement_text "${eco}" "${words}" "${runner}")
    if [[ "${mode}" != readings ]]; then
      guard_operand_specs "${eco}" "${text}"
      continue
    fi
    # A runner's operands are one per line; on one line they number the same,
    # since the flag reader counts tokens across lines. Only a runner's text
    # has newlines, and it is short: a bash 3.2 substitution over a long string
    # is what made the blank-segment test quadratic.
    [[ "${runner}" == true ]] && text_line="${text//$'\n'/ }" || text_line="${text}"
    printf 'S\t%s\t%s\t%s\nG\t%s\nT\t%s\n' "${eco}" "${runner}" "${gate_reads}" "${seg}" "${text_line}"
    guard_operand_specs "${eco}" "${text}" positions
  done < <(guard_extract_pieces "${cmd}" "${targets}")
}

# How the current reading would make the command's npm installs inert, as one
# value the readings can be compared on: none, append, downgrade, or `rewrite`
# and the rewritten command on the next line.
guard_reading_inert() {
  local outcome=none updated="" rc=0
  if command_is_injectable_npm_install "${COMMAND}" && \
     ! command_has_ignore_scripts_flag "${COMMAND}"; then
    if command_needs_inplace_inert "${COMMAND}"; then
      # Insert `--ignore-scripts` immediately AFTER each npm-install verb so the
      # flag stays inside its own statement. Appending to the end of the
      # whole string would land it on the trailing statement (e.g.
      # `npm install evil && npm run build --ignore-scripts`), leaving the install
      # itself running lifecycle scripts (finding #7). `npm install --ignore-scripts <pkg>`
      # is valid npm syntax (flags may precede operands).
      # scripts/test/smoke.sh pins the landing spot. A failed rewrite marks the
      # reading, so the gate settles it instead of reading it as nothing to do.
      updated=$(inert_rewrite_in_place "${COMMAND}") || rc=$?
      case "${rc}" in
        0) ;;
        3) updated="" ;;
        *) guard_mark_reading_failed; updated="" ;;
      esac
      if [[ -z "${updated}" || "${updated}" == "${COMMAND}" ]]; then
        # The rewrite did not land -- never blind-append to a compound command.
        # Downgrade to detect-and-rollback (the effect gate still verifies the
        # closure), recorded once the command is known to run: the inert
        # guarantee is observably relaxed, never silently.
        outcome=downgrade
      else
        outcome="rewrite"$'\n'"${updated}"
      fi
    else
      outcome=append
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
    if command_pipes_unread_install_to_shell "${COMMAND}"; then
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
      S$'\t'*|G$'\t'*|T$'\t'*|@$'\t'*) continue ;;
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

if [[ "${GUARD_ANY_INSTALL}" != true ]]; then
  guard_settle_scan_failure
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
while IFS=$'\035' read -r _ install_target _ _; do
  [[ -n "${install_target}" && "${install_target}" != "?" && "${install_target}" != global ]] || continue
  PROJECT_DIR="${install_target}"
  PROJECT_DIR_FROM=target
  break
done <<< "${INSTALL_TARGETS}"
# An .npmrc that keeps an install off the record is not text in the command, so
# the record has to say which file did it; the UNGATED line alone would point at
# a command that looks like an ordinary project install. Each reason once,
# however many readings gave it.
install_whys=$'\n'
while IFS=$'\035' read -r _ _ install_why _; do
  [[ -n "${install_why}" ]] || continue
  [[ "${install_whys}" != *$'\n'"${install_why}"$'\n'* ]] || continue
  install_whys+="${install_why}"$'\n'
  log_advisory "pre-guard: ${install_why}. Command: ${COMMAND}"
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
SNAPSHOT_ID="${TIMESTAMP}_${DIR_HASH}"

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

# Snapshot lock and manifest files that define dependency truth.
SNAPSHOTTED=false
: > "${SNAPSHOT_DIR}/${SNAPSHOT_ID}_monitored_files.list"

for lock_file in "${SAFEDEPS_LOCK_FILES[@]}"; do
  snapshot_project_file "${lock_file}" "lock"
done

for manifest_file in "${SAFEDEPS_MANIFEST_FILES[@]}"; do
  snapshot_project_file "${manifest_file}" "manifest"
done

while IFS= read -r csproj_file; do
  snapshot_project_file "$(basename "${csproj_file}")" "manifest"
done < <(find "${PROJECT_DIR}" -maxdepth 1 -type f -name "*.csproj" 2>/dev/null | sort)

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

# Save pre-install listings for diff-based detection (avoids mtime-based find -newer)
if [[ -d "${PROJECT_DIR}/node_modules" ]]; then
  find "${PROJECT_DIR}/node_modules" -maxdepth 3 -name "package.json" 2>/dev/null | sort > "${SNAPSHOT_DIR}/${SNAPSHOT_ID}_packages.list"
  { ls "${PROJECT_DIR}/node_modules/.bin/" 2>/dev/null || true; } | sort > "${SNAPSHOT_DIR}/${SNAPSHOT_ID}_bins.list"
else
  touch "${SNAPSHOT_DIR}/${SNAPSHOT_ID}_packages.list"
  touch "${SNAPSHOT_DIR}/${SNAPSHOT_ID}_bins.list"
fi

# Store metadata for PostToolUse verification
cat > "${SNAPSHOT_DIR}/${SNAPSHOT_ID}_meta.json" << META_EOF
{
  "snapshot_id": "${SNAPSHOT_ID}",
  "parent_snapshot_id": ${PARENT_SNAPSHOT_JSON},
  "timestamp": ${TIMESTAMP},
  "project_dir": $(printf '%s' "${PROJECT_DIR}" | jq -Rs .),
  "command": $(printf '%s' "${COMMAND}" | jq -Rs .),
  "ignore_scripts_injected": false,
  "lock_files_found": ${SNAPSHOTTED}
}
META_EOF

mark_ignore_scripts_injected() {
  local meta_file="${SNAPSHOT_DIR}/${SNAPSHOT_ID}_meta.json"
  local temp_file

  [[ -f "${meta_file}" ]] || return 0
  temp_file=$(mktemp "${SNAPSHOT_DIR}/.${SNAPSHOT_ID}_meta.XXXXXX") || return 0
  if jq '.ignore_scripts_injected = true' "${meta_file}" > "${temp_file}"; then
    mv -f "${temp_file}" "${meta_file}"
  else
    rm -f "${temp_file}"
  fi
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
      GUARD_BLOCKED_CMDS+=("${SAFEDEPS_INVOKE} check ${eco} ${pkg}@${spec}")
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
# pipe with nothing beside it.
if [[ "${PIPED_BESIDE_VISIBLE}" == "true" ]]; then
  guard_undecided_if_scan_failed
  log_advisory "pre-guard DENY: install text piped into a shell beside a visible install could not be reduced to an approved spec — fail-closed. Command: ${COMMAND}"
  jq -nc '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:"safedeps: this command pipes text that reads like an install into a shell (`... | sh`) beside the install it runs. The gate checks the visible install, but it cannot extract a package spec from what is piped, so the command is blocked fail-closed. Run the piped install as its own command, written out rather than piped, so it can be checked."}}'
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
    append) UPDATED_COMMAND="${COMMAND} --ignore-scripts" ;;
    downgrade) INERT_DOWNGRADED=true ;;
    rewrite$'\n'*) UPDATED_COMMAND="${inert_first#rewrite$'\n'}" ;;
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
  log_advisory "pre-guard: could not make every npm install in this command inert in place (one is in a compound command the rewrite did not land in, or in a script handed to a shell that it cannot reach); lifecycle scripts may run before the effect gate verifies (downgraded to detect-and-rollback). Command: ${COMMAND}"
fi

# Write per-install pending state for PostToolUse, keyed by (dir_hash, normalized
# command) so concurrent installs in the same project keep separate state instead
# of clobbering one global file (issue #5). The single-file write is still atomic
# (write_state_file) to prevent TOCTOU within one install.
PENDING_DIR="${GUARD_DIR}/pending"
mkdir -p "${PENDING_DIR}"
# GC pending entries whose PostToolUse never fired (crash/no-op). 24h is well past
# any real install, so this never deletes an in-flight one (a 60-min window could
# have reaped a slow native build that was still running).
find "${PENDING_DIR}" \( -name '*.json' -o -name '*.trace' \) -type f -mmin +1440 -delete 2>/dev/null || true
# Key = (dir, normalized command); the snapshot id suffix makes the filename unique
# per install, so even two identical concurrent commands keep separate state.
PENDING_KEY=$(compute_pending_key "${KEY_DIR_HASH}" "${COMMAND}")
# $$ (this pre hook's PID) guarantees a unique filename even for two installs in
# the same second (SNAPSHOT_ID has only 1s resolution).
PENDING_BASE="${PENDING_DIR}/${PENDING_KEY}__${SNAPSHOT_ID}_$$"

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
CURRENT_STATE=$(jq -n --arg sid "${SNAPSHOT_ID}" --arg pdir "${PROJECT_DIR}" --arg dhash "${DIR_HASH}" \
  --arg from "${PROJECT_DIR_FROM}" --argjson trace "${TRACE_JSON}" --arg attribution "${ATTRIBUTION}" \
  '{snapshot_id: $sid, project_dir: $pdir, dir_hash: $dhash, project_dir_from: $from,
    npm_trace: $trace, npm_unattributable: $attribution}')
write_state_file "${PENDING_BASE}.json" "${CURRENT_STATE}"

if [[ -n "${UPDATED_COMMAND}" ]]; then
  mark_ignore_scripts_injected
  jq -nc --arg command "${UPDATED_COMMAND}" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",updatedInput:{command:$command}}}'
  exit 0
fi

# Allow the command to proceed — PostToolUse will verify the result
exit 0
