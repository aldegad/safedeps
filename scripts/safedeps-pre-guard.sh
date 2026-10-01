#!/usr/bin/env bash
# safedeps: PreToolUse hook
# Dependency install safety gate with reorg rollback support
# Detects package install commands and snapshots lock files before execution

set -euo pipefail

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

# Blank every quoted region, delimiters included, and leave unquoted text
# untouched. Every detection predicate below reads this instead of the raw
# command, which is why `echo "npm install evil"` is not an install: the text is
# there, but not in execution position. scripts/test/scan-contract.sh states the
# rules and checks this implementation against them.
#
# One awk pass. The bash character loop this replaces was quadratic because
# `${input:i:1}` counts from the start of the string on every index, so the cost
# of reading one character grew with its position. The first awk version kept
# the same shape: `substr($0, i, 1)` re-measures the string on each call in BSD
# awk (macOS), so one long line stayed quadratic (1MB took 28.5s; caught in
# review). Splitting the record into an array once makes every read constant,
# which is what makes the pass linear -- not the byte orientation, which is
# only what LC_ALL=C gives the split. Measured on this host, an unquoted command
# with no install text: 32KB went 36.2s -> 0.08s and 64KB went past two minutes
# -> 0.28s (scripts/measure/scan-cost.sh). The PreToolUse timeout is 30s and
# fails OPEN, so the old curve did not slow the gate down past ~29KB, it removed
# it.
#
# One thing changed, and it is the blank COUNT inside a quoted region: a
# multibyte character used to blank to one space and now blanks to one space per
# byte. Nothing else moves. Unquoted bytes pass through unchanged, so the output
# is byte-identical wherever no multibyte character sits inside quotes; and the
# three bytes the state machine tests (' " \) are ASCII, which no UTF-8
# continuation byte can collide with. Every consumer reads this through
# `grep -qE` or `read -ra`, and neither can tell one blank from three.
#
# When awk fails, this says so in SAFEDEPS_SCAN_MARK and returns non-zero. The
# status alone is not enough: every caller tests this output inside a condition
# or a command substitution, where `set -e` is off and a failed scan reads as
# empty text, which reads as "no install". That turned a scanner failure into a
# silent pass (caught in review), and the mark is what lets the top level see
# it. guard_settle_scan_failure is where it is read.
command_scan_text() {
  if ! printf '%s\n' "$1" | LC_ALL=C awk '
    # safedeps:command_scan_text (scripts/test/scan-contract.sh keys on this line)
    BEGIN { q = 0; esc = 0; buf = ""; held = 0 }

    # Emit through a bounded buffer. Appending to one string for the whole
    # input would put a quadratic memcpy back in place of the quadratic loop.
    function put(c) {
      buf = buf c
      if (++held >= 4096) { printf "%s", buf; buf = ""; held = 0 }
    }

    {
      # The newline that ended the previous record is a character too: it
      # survives outside a quoted region and blanks inside one. An escaped
      # newline is a line continuation, which the shell removes, so it blanks
      # everywhere and the two lines read as one. The trailing newline this
      # function adds terminates the last record and so is never emitted, which
      # is what keeps the output the same length as the input.
      if (NR > 1) {
        if (esc) { put(" "); esc = 0 }
        else     { put(q == 0 ? "\n" : " ") }
      }

      n = split($0, ch, "")
      for (i = 1; i <= n; i++) {
        c = ch[i]
        if (esc) {
          # The escaped byte. Outside a region it is data: it passes through
          # and never opens one (`\"` is a quote character). An escaped
          # operator is data too, so it passes as `_`: `\;` is a semicolon
          # argument to the shell, not the end of a statement, and read as one
          # it made `echo x \; pip install y | sh` a visible install.
          # Inside a double-quoted region it is blanked like everything else
          # and never closes it.
          if (q != 0)                     put(" ")
          else if (c ~ /[;&|()<>!{}#`]/)  put("_")
          else                            put(c)
          esc = 0
        }
        else if (q == 0) {
          if (c == "\\")        { esc = 1; put(" ") }
          else if (c == "\047") { q = 1; put(" ") }
          else if (c == "\042") { q = 2; put(" ") }
          else                  { put(c) }
        }
        else if (q == 1) {
          # No escapes inside single quotes.
          if (c == "\047") q = 0
          put(" ")
        }
        else {
          if (c == "\\")        esc = 1
          else if (c == "\042") q = 0
          put(" ")
        }
      }
    }

    END { printf "%s", buf }
  '; then
    [[ -z "${SAFEDEPS_SCAN_MARK:-}" ]] || printf 'failed\n' >> "${SAFEDEPS_SCAN_MARK}"
    return 1
  fi
}

normalize_install_text() {
  local text="$1"

  local normalized
  for _ in 1 2 3; do
    if ! normalized=$(printf '%s' "${text}" | sed -E \
      -e 's/^[[:space:]]+//' \
      -e "s#(^|[[:space:];|&({!])(/[^[:space:];|&]+/)(${SAFEDEPS_G_EXECUTABLES}|sh|bash|zsh)([[:space:];|&]|\$)#\\1\\3\\4#g" \
      -e 's#(^|[;&|({!][[:space:]]*|(then|do|else|elif|if|while|until|time|coproc)[[:space:]]+)(env([[:space:]]+(-i|--ignore-environment|-0|--null|-v|--debug|-u[[:space:]]*[^[:space:]]+|--unset(=|[[:space:]]+)[^[:space:]]+|-C[[:space:]]*[^[:space:]]+|--chdir(=|[[:space:]]+)[^[:space:]]+|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+))*[[:space:]]+|command[[:space:]]+|exec[[:space:]]+)#\1#g' \
      -e 's#(^|[;&|({!][[:space:]]*|(then|do|else|elif|if|while|until|time|coproc)[[:space:]]+)([A-Za-z_][A-Za-z0-9_]*=[^[:space:]'\''"]*[[:space:]]+)+#\1#g'); then
      # Empty text would read as "no install". Keep what there is and let the
      # gate settle the failure.
      guard_mark_reading_failed
      break
    fi
    text="${normalized}"
  done
  printf '%s' "${text}"
}

# Drop heredoc bodies and keep the command lines. With `shell-bodies` as the
# second argument it keeps the other side instead: the body lines of every
# heredoc whose opening line pipes into a shell (`cat <<EOF | sh`), and nothing
# else. A body written to a file or read by any other program is data. The one
# reading of where a body starts and ends serves both.
strip_heredoc_bodies() {
  local input="$1"
  local keep="${2:-commands}"
  local line
  local delimiter=""
  local feeds_shell=false
  local opened scanned
  # `<<` not next to another `<` (a herestring is `<<<`), then a delimiter
  # word. A delimiter starting with a digit is not read as one: `1<<2` is a
  # shift. The operator must also be unquoted and outside `((...))`, checked
  # on the scan text below. Each of these used to open a heredoc with no
  # terminator, and every line after it vanished from the gate (caught in
  # review: a herestring, an arithmetic shift or a quoted `<<EOF`, then an
  # install on the next line, passed with no verdict).
  local heredoc_re="(^|[^<])<<-?[[:space:]]*[\"']?([A-Za-z_][A-Za-z0-9_.-]*)[\"']?"
  # Bracket forms, not `\<`: GNU regex (Linux bash) reads `\<` as a word
  # boundary. In variables, because `[[ ]]` parses a bare `<` as an operator.
  local heredoc_operator_re='(^|[^<])[<][<]([^<]|$)'
  local arithmetic_shift_re='[(][(][^)]*[<][<]'
  local trailing_pipe_re='[|][[:space:]]*$'

  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ -n "${delimiter}" ]]; then
      if [[ "${line}" == "${delimiter}" ]]; then
        delimiter=""
      elif [[ "${keep}" == "shell-bodies" && "${feeds_shell}" == "true" ]]; then
        printf '%s\n' "${line}"
      fi
      continue
    fi

    if [[ "${line}" =~ ${heredoc_re} ]]; then
      opened="${BASH_REMATCH[2]}"
      scanned=$(command_scan_text "${line}")
      if [[ "${scanned}" =~ ${heredoc_operator_re} ]] \
          && ! [[ "${scanned}" =~ ${arithmetic_shift_re} ]]; then
        delimiter="${opened}"
        feeds_shell=false
        # A body goes to a shell when its opening line pipes into one, or ends
        # in a pipe that the line after the terminator continues.
        if [[ "${keep}" == "shell-bodies" ]] \
            && { exec_text_pipes_to_shell "${line}" || [[ "${scanned}" =~ ${trailing_pipe_re} ]]; }; then
          feeds_shell=true
        fi
      fi
    fi
    [[ "${keep}" == "shell-bodies" ]] || printf '%s\n' "${line}"
  done <<< "${input}"
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
  local rest

  rest="$1"
  while [[ "${rest}" =~ (bash|sh|zsh)[[:space:]]+-[A-Za-z]*c[[:space:]]+\"([^\"]*)\" ]]; do
    printf '%s\n' "${BASH_REMATCH[2]}"
    rest="${rest#*"${BASH_REMATCH[0]}"}"
  done

  rest="$1"
  while [[ "${rest}" =~ (bash|sh|zsh)[[:space:]]+-[A-Za-z]*c[[:space:]]+\'([^\']*)\' ]]; do
    printf '%s\n' "${BASH_REMATCH[2]}"
    rest="${rest#*"${BASH_REMATCH[0]}"}"
  done
}

extract_eval_payloads() {
  local rest="$1"

  while [[ "${rest}" =~ (^|[[:space:];|&])eval[[:space:]]+\"([^\"]*)\" ]]; do
    printf '%s\n' "${BASH_REMATCH[2]}"
    rest="${rest#*"${BASH_REMATCH[0]}"}"
  done

  rest="$1"
  while [[ "${rest}" =~ (^|[[:space:];|&])eval[[:space:]]+\'([^\']*)\' ]]; do
    printf '%s\n' "${BASH_REMATCH[2]}"
    rest="${rest#*"${BASH_REMATCH[0]}"}"
  done
}

extract_command_substitution_payloads() {
  local input="$1"
  local rest

  rest="${input}"
  while [[ "${rest}" == *'$('* ]]; do
    rest="${rest#*'$('}"
    printf '%s\n' "${rest%%)*}"
    rest="${rest#*)}"
  done

  rest="${input}"
  while [[ "${rest}" == *'`'* ]]; do
    rest="${rest#*\`}"
    printf '%s\n' "${rest%%\`*}"
    [[ "${rest}" == *'`'* ]] || break
    rest="${rest#*\`}"
  done
}

# Install text as the pipe checks search for it: a manager, then a verb
# anywhere after it on the same line. Loose on purpose -- it reads text that is
# data at its own quoting level, where no statement grammar applies.
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
  matches=$(printf '%s\n' "${scan}" | LC_ALL=C judge_grep -obEi "${SAFEDEPS_INSTALL_PATTERN}") || matches=""
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
        if (!match(tolower(str), mre)) continue
        for (i = p[1] + RSTART; i < p[1] + RSTART + RLENGTH; i++)
          if (X[L + 1 + i] != " " && X[i] != "\n") X[i] = " "
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

# Join what the shell reads as one line before anything splits the command
# into lines.
#
# Every consumer reads the candidate texts one line at a time. Two kinds of
# newline do not end a statement, and splitting at them broke the reading:
#
#   - An escaped newline. `pip \<newline>install x` was judged as two unrelated
#     lines, neither of them an install. The shell removes it, so this does
#     too: the backslash and the newline become two blanks.
#   - A newline inside quotes. The line that closes a multi-line string was
#     scanned alone, so its closing quote read as an OPENING one and blanked
#     whatever followed -- `echo "a<newline>b" ; pip install x` passed. The
#     other lines were scanned alone too, so a commit message whose second line
#     mentions an install read as that install. The newline becomes a blank,
#     which is what the scanner makes of it anyway.
#
# Both keep every byte where it was. What counts as escaped follows command_scan_text exactly -- backslashes
# pair up, and there are no escapes inside single quotes -- because getting it
# wrong in the other direction is worse: joining after `echo a\\` would make the
# next line an argument to echo and hide it.
#
# awk failing here is recorded like a scanner failure (see command_scan_text),
# and the text passes through unjoined.
join_line_continuations() {
  local joined
  if joined=$(printf '%s\n' "$1" | LC_ALL=C awk '
    # safedeps:join_line_continuations (scripts/measure/scan-failure-census.sh keys on this line)
    BEGIN { q = 0; out = ""; open = 0 }
    {
      n = split($0, ch, "")
      pending = 0
      for (i = 1; i <= n; i++) {
        c = ch[i]
        if (pending)                 { out = out "\\" c; pending = 0; continue }
        if (q == 1)                  { out = out c; if (c == "\047") q = 0; continue }
        if (c == "\\")               { pending = 1; continue }
        if (q == 0 && c == "\047")   q = 1
        else if (c == "\042")        q = (q == 2 ? 0 : 2)
        out = out c
      }
      if (pending)     { out = out "  "; open = 1 }
      else if (q != 0) { out = out " "; open = 1 }
      else             { print out; out = ""; open = 0 }
    }
    END { if (open) print out }
  '); then
    printf '%s' "${joined}"
  else
    [[ -z "${SAFEDEPS_SCAN_MARK:-}" ]] || printf 'failed\n' >> "${SAFEDEPS_SCAN_MARK}"
    printf '%s' "$1"
  fi
}

command_candidate_texts() {
  local command="$1"
  local payload

  command=$(strip_heredoc_bodies "${command}")
  command=$(join_line_continuations "${command}")

  normalize_install_text "${command}"
  printf '\n'
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
  local scanned
  scanned=$(command_scan_text "$1")
  [[ "${scanned}" == *$'\n'* ]] && return 0
  printf '%s' "${scanned}" | judge_grep -qE '[;&|#]'
}

# Echo the install directory when the command redirects the install target away
# from cwd via a tool-specific long flag — npm `--prefix`, pnpm `--dir`, yarn
# `--cwd`, or `--install-dir`. Empty when there is no override. Without this, an
# `npm install --prefix /other pkg` is snapshotted/effect-gated against cwd (which
# never changed), so the effect gate falsely confirms cwd clean and even advances
# the safe pointer while the real install lands in /other unverified (finding #3).
# Operates on the quote-blanked text so a quoted occurrence is not misread; only
# unambiguous long flags are honored to avoid colliding with other tools' `-C`.
resolve_install_dir_override() {
  local cmd="$1" scanned tok want=""
  local -a toks=()
  scanned=$(command_scan_text "${cmd}")
  read -ra toks <<< "${scanned//$'\n'/ }"
  for tok in "${toks[@]+${toks[@]}}"; do
    if [[ -n "${want}" ]]; then printf '%s' "${tok}"; return 0; fi
    case "${tok}" in
      --prefix=*)      printf '%s' "${tok#--prefix=}"; return 0 ;;
      --cwd=*)         printf '%s' "${tok#--cwd=}"; return 0 ;;
      --dir=*)         printf '%s' "${tok#--dir=}"; return 0 ;;
      --install-dir=*) printf '%s' "${tok#--install-dir=}"; return 0 ;;
      --prefix|--cwd|--dir|--install-dir) want=1 ;;
    esac
  done
  return 0
}

snapshot_project_file() {
  local relative_file="$1"
  local category="${2:-manifest}"
  local source_path="${PROJECT_DIR}/${relative_file}"
  local snapshot_path="${SNAPSHOT_DIR}/${SNAPSHOT_ID}_${relative_file}"

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
trap 'rm -f "${SAFEDEPS_SCAN_MARK:-}"' EXIT

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
  jq -nc '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:"safedeps: UNDECIDED, not unsafe — the command scanner (awk) failed while reading this command, so safedeps could not tell whether it installs a dependency or what it would install. It is blocked fail-closed, and no finding is claimed. Check that `echo x | awk 1` works, then retry."}}'
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
    printf 'safedeps: the command scanner (awk) failed, so this command could not be read. It names no package manager, so it was allowed. The failure is recorded in advisory.log.\n' >&2
  fi
  export SAFEDEPS_GATE_PASSED=1
}

HIDDEN_DEPENDENCY_INSTALL=false
PIPED_BESIDE_VISIBLE=false
if ! command_is_dependency_install "${COMMAND}"; then
  # Catch indirection patterns that hide install commands (V-002)
  if command_hides_dependency_install "${COMMAND}"; then
    HIDDEN_DEPENDENCY_INSTALL=true
    : # Fall through — treat as install candidate
  else
    guard_settle_scan_failure
    exit 0
  fi
elif command_pipes_unread_install_to_shell "${COMMAND}"; then
  # A visible install used to switch the hidden-install check off. It is a
  # hidden install like any other, and it is denied where the others are, after
  # the snapshot: every path between here and there is a deny.
  HIDDEN_DEPENDENCY_INSTALL=true
  PIPED_BESIDE_VISIBLE=true
fi

# --- Reorg Guard Activated ---

# Find lock files in common locations
# Per Claude Code / Codex CLI hook spec, `cwd` is top-level. Fall back to `pwd`
# only when the hook is invoked outside the engine (manual test, no stdin payload).
CWD_DIR=$(echo "${INPUT}" | jq -r '.cwd // empty' 2>/dev/null)
if [[ -z "${CWD_DIR}" ]]; then
  CWD_DIR=$(pwd)
fi

# Resolve the actual install target: an `--prefix`/`--cwd`/`--dir`/`--install-dir`
# override relocates the install away from cwd (finding #3). Snapshot + effect-gate
# must follow the real target, while the PostToolUse pending-key still keys on cwd
# (post-verify only knows cwd) — so KEY_DIR_HASH (cwd) and DIR_HASH (install dir)
# are tracked separately below.
PROJECT_DIR="${CWD_DIR}"
INSTALL_DIR_OVERRIDE=$(resolve_install_dir_override "${COMMAND}")
if [[ -n "${INSTALL_DIR_OVERRIDE}" ]]; then
  case "${INSTALL_DIR_OVERRIDE}" in
    /*) PROJECT_DIR="${INSTALL_DIR_OVERRIDE}" ;;
    *)  PROJECT_DIR="${CWD_DIR%/}/${INSTALL_DIR_OVERRIDE}" ;;
  esac
  log_advisory "pre-guard: install dir override detected (${INSTALL_DIR_OVERRIDE}) — snapshotting/verifying ${PROJECT_DIR} instead of cwd (${CWD_DIR})."
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
trap 'release_state_lock; rm -f "${SAFEDEPS_SCAN_MARK:-}"' EXIT

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
# is one that prefers it (npx, npm exec/x, bunx, bun x). pnpm dlx, yarn dlx,
# uvx and pipx run always fetch.
guard_runner_uses_local_bin() {
  local seg="$1" name="$2"
  [[ "${name}" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  [[ -x "${PROJECT_DIR:-.}/node_modules/.bin/${name}" ]] || return 1
  command_scan_text "${seg}" | judge_grep -qEi "${SAFEDEPS_G_START}((npx|bunx)([[:space:]]|\$)|npm${SAFEDEPS_G_OPTS}[[:space:]]+(exec|x)([[:space:]]|\$)|bun${SAFEDEPS_G_OPTS}[[:space:]]+x([[:space:]]|\$))"
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
  local cmd="$1"
  local candidate seg scan
  local found=false

  while IFS= read -r candidate; do
    while IFS= read -r seg; do
      [[ "${seg}" =~ [^[:space:]] ]] || continue
      scan=$(command_scan_text "${seg}")
      echo "${scan}" | judge_grep -qEi '(^|[[:space:]])npm([[:space:]]|$)' || continue
      echo "${scan}" | judge_grep -qEi "(^|[[:space:]])(${SAFEDEPS_G_NPM_VERBS})([[:space:]]|\$)" || continue
      found=true
      echo "${scan}" | judge_grep -qEi -- '(^|[[:space:]])(-g|--global(=true)?|--location(=|[[:space:]]+)global)([[:space:]]|$)' || return 1
    done < <(printf '%s\n' "${candidate}" | tr ';|&' '\n')
  done < <(command_candidate_texts "${cmd}")

  [[ "${found}" == true ]]
}

guard_runner_operands() {
  # Runner forms (`npx`, `pnpm dlx`, `yarn dlx`, `bunx`, `uvx`, `pipx run`, ...)
  # EXECUTE a package; tokens after the executed package are arguments to that
  # program, NOT package specs. Emit only the spec-bearing operands: any
  # `-p/--package <pkg>` value plus the first bare token (the executed package).
  # This stops an argument such as an email (`ops@example.test`) or a secret
  # value passed to `npx wrangler ...` from being misread as a `pkg@spec`.
  #
  # Quotes are delimiters here, not data: `npx "cowsay@1.5.0"` runs cowsay@1.5.0.
  local text after want_value tok
  local -a toks=()
  text=$(printf '%s' "$1" | tr -d "\"'")
  # The first line in bash rather than `| head -n1`: under pipefail, head
  # closing the pipe early would read as sed failing.
  if ! after=$(printf '%s\n' "${text}" \
      | sed -nE "s/^(.*[[:space:];&|({!])?(${SAFEDEPS_G_RUNNER_BODY})([[:space:]]|\$)//p"); then
    guard_mark_reading_failed
  fi
  after="${after%%$'\n'*}"
  [[ "${after}" =~ [^[:space:]] ]] || return 0

  local named_by_option=false
  want_value=false
  read -ra toks <<< "${after}"
  for tok in "${toks[@]+${toks[@]}}"; do
    if [[ "${want_value}" == true ]]; then
      printf '%s\n' "${tok}"
      want_value=false
      named_by_option=true
      continue
    fi
    case "${tok}" in
      -p|--package|--spec|--from) want_value=true ;;
      --package=*|--spec=*|--from=*) printf '%s\n' "${tok#*=}"; named_by_option=true ;;
      -*)           : ;;  # other flag (e.g. -y/--yes), skip
      *)
        # The executed package -- unless an option already named the package,
        # in which case this is the command it provides (`npx -p x@1 x-cli`).
        [[ "${named_by_option}" == true ]] || printf '%s\n' "${tok}"
        break
        ;;
    esac
  done
}

# The package an operand names, without its version, extras or markers:
# `evil[x]==1.0.0` -> evil, `@scope/x@1` -> @scope/x, `example.com/m@v1` ->
# example.com/m. Whether it is pinned is then asked of the extractor's output by
# this name, never read off the token's shape.
guard_operand_name() {
  local tok="$1" scope="" body
  if [[ "${tok}" == @* ]]; then
    scope="@"
    body="${tok#@}"
  else
    body="${tok}"
  fi
  body="${body%%;*}"
  body="${body%%\[*}"
  body="${body%%@*}"
  body="${body%%[=<>~!]*}"
  printf '%s%s' "${scope}" "${body}"
}

guard_names_package_without_spec() {
  # True when an install NAMES a package but carries no version spec, so the
  # ledger gate never ran for it. Used only to make that fact observable — it
  # changes no verdict.
  #
  # The boundary is what keeps this record readable. A record that fires on
  # routine installs becomes background noise, and background noise is the same
  # as no record. So a token is a named package only if it survives three tests,
  # each of which exists because getting it wrong hides a real install
  # (four, since the fourth was added for pinned-by-flag forms):
  #
  #   1. It is not a flag, and not the VALUE of a flag. A source flag consumes
  #      its own argument and nothing more — `-r requirements.txt` names no
  #      package, but `-r requirements.txt evil` still installs `evil`.
  #      Silencing the whole command on sight of `-r`/`-c`/`-e` hid that, and
  #      `-c` is not even a source flag: a constraint file only bounds versions
  #      while the install target still arrives on the command line. `-e`
  #      consumes nothing here either — its argument is judged like any other
  #      token, so `-e .` falls out as a working-tree build while
  #      `-e git+ssh://…` stays the fetch it is.
  #   2. It is not a local path (`.`, `..`, `./x`, `/x`). Those install from the
  #      working tree, not from a registry. A module path like
  #      `example.com/evil` is NOT a local path and stays reportable.
  #   3. Its `@` actually delimits a version. In a URL the `@` separates a user,
  #      so `git+ssh://git@host/evil.git` is no more pinned than
  #      `git+https://host/evil.git` — reading it as a spec silenced one and
  #      reported the other for the same install.
  #   4. The extractor did not produce a spec for it. "Pinned" means the ledger
  #      gate actually ran, so it is read from what guard_extract_specs found
  #      (LEDGER_SPECS), never re-derived from flags here: `gem install x -v 1`
  #      is pinned because the extractor reads gem's -v, while
  #      `cargo install x --version 1` is not, because it does not. Re-deriving
  #      it would make that second install neither gated nor recorded.
  local cmd="$1"
  local seg tok verb_seen skip_next seg_ecosystem entry entry_eco name
  local -a toks=()
  # Keyed by ecosystem as well as name: pypi `openai` and npm `openai` are
  # different packages, and a pin on one must not quiet the record for the
  # other (caught in review: `pip install openai==1 && pnpm add openai` left
  # no trace of the pnpm install).
  local pinned=$'\n'

  for entry in "${LEDGER_SPECS[@]+${LEDGER_SPECS[@]}}"; do
    IFS=$'\t' read -r entry_eco name _ <<< "${entry}"
    pinned+="${entry_eco}"$'\t'"${name}"$'\n'
  done

  while IFS= read -r seg; do
    [[ "${seg}" =~ [^[:space:]] ]] || continue
    command_is_dependency_install "${seg}" || continue

    verb_seen=false
    skip_next=false
    seg_ecosystem=$(guard_segment_ecosystem "${seg}")

    # A runner names the package it executes, and nothing after it.
    if guard_segment_is_runner "${seg}"; then
      while IFS= read -r tok; do
        [[ -z "${tok}" ]] && continue
        [[ "${pinned}" == *$'\n'"${seg_ecosystem}"$'\t'"$(guard_operand_name "${tok}")"$'\n'* ]] && continue
        # npx, npm exec and bunx run a binary the project already has without
        # fetching anything, so `npx tsc` in a TypeScript project is not an
        # install. Only a name with no local binary is fetched, and only that
        # is worth a record; recording every `npx tsc` would bury the ones that
        # matter.
        guard_runner_uses_local_bin "${seg}" "${tok}" && continue
        return 0
      done < <(guard_runner_operands "${seg}")
      continue
    fi

    # Quotes delimit operands; they do not hide them. `pip install "requests"`
    # names requests, and reading the blanked scan here made it invisible.
    read -ra toks <<< "$(printf '%s' "${seg}" | tr -d "\"'" | tr '(){}' '    ')"
    for tok in "${toks[@]+${toks[@]}}"; do
      # Maven's coordinate flag may sit on either side of the goal
      # (`mvn -Dartifact=g:x dependency:get`), so it is tested outside the verb
      # gate that orders the operand walk. A two-field coordinate names a
      # package with no version; a third field is the version. Whether Maven
      # accepts the versionless form is unverified (no maven on the measuring
      # machine), and for a RECORD the unresolved case resolves toward
      # reporting: a spurious line costs a line, a missing one costs the
      # invariant this layer exists to keep.
      case "${tok}" in
        -Dartifact=*:*:*) continue ;;
        -Dartifact=*:*)   return 0 ;;
      esac

      if [[ "${verb_seen}" != true ]]; then
        safedeps_grammar_is_verb "${tok}" && verb_seen=true
        continue
      fi

      # `dotnet add [<project>] package <id>`: the keyword and the project file
      # are not packages.
      if [[ "${seg_ecosystem}" == "nuget" ]]; then
        case "${tok}" in
          package|*.csproj|*.fsproj|*.vbproj|*.sln|*.slnx) continue ;;
        esac
      fi

      if [[ "${skip_next}" == true ]]; then
        skip_next=false
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
        # Installing from the working tree is not a registry fetch.
        .|..|./*|../*|/*) continue ;;
      esac

      # Pinned means the extractor produced a spec for this package, asked by
      # name. Reading it off the token's shape (`*@*|*==*`) let every spelling
      # the extractor does not read pass as pinned with no record:
      # `evil[x]==1.0.0`, `evil===1.0.0`, `evil==1.0.*` (caught in review). A
      # URL names a package and pins nothing, whatever `@` it carries.
      case "${tok}" in
        *://*) return 0 ;;
      esac
      [[ "${pinned}" == *$'\n'"${seg_ecosystem}"$'\t'"$(guard_operand_name "${tok}")"$'\n'* ]] && continue

      return 0
    done
  done < <(command_candidate_texts "${cmd}" | tr ';|&' '\n')
  return 1
}

guard_extract_flagged_specs() {
  # Specs carried by a flag rather than by `pkg@version`: pip's `name==version`,
  # gem's `-v`, cargo's `--vers`, bundle's and dotnet's `--version`, maven's
  # `-Dartifact` coordinate. The package is the
  # first operand after the verb, and the verb is found past any options between
  # it and the manager (`gem --norc install x -v 1`, `cargo +nightly add x`,
  # `dotnet add App.csproj package X`), which the adjacent-token reading missed.
  awk '
    # safedeps:extract_flagged_specs (scripts/measure/scan-failure-census.sh keys on this line)
    function operand(s,   j) {
      for (j = s; j <= NF; j++) if ($j !~ /^-/ && $j !~ /^[+]/) return j
      return 0
    }
    function verb_after(s, want,   j) {
      for (j = s; j <= NF; j++) {
        if ($j == want) return j
        if ($j !~ /^-/ && $j !~ /^[+]/) return 0
      }
      return 0
    }
    function versions(pkg, s, shortv,   j, v) {
      for (j = s; j <= NF; j++) {
        if (($j == "--version" || $j == "--vers" || (shortv && $j == "-v")) && $(j + 1) != "") print pkg "\t" $(j + 1)
        if ($j ~ /^--(vers|version)=/) { v = $j; sub(/^--(vers|version)=/, "", v); print pkg "\t" v }
      }
    }
    {
      for (i = 1; i <= NF; i++) {
        # `name==version`, and `name===version` (arbitrary equality, also an
        # exact pin). A wildcard such as `==1.0.*` is not a pin and stays out.
        if ($i ~ /^[A-Za-z][A-Za-z0-9._-]*===?[A-Za-z0-9][A-Za-z0-9._+!~-]*$/) {
          split($i, parts, /===?/)
          print parts[1] "\t" parts[2]
        }

        # maven-dependency-plugin: -Dartifact=groupId:artifactId:version[:packaging[:classifier]].
        # OSV names a Maven package groupId:artifactId. A two-field coordinate
        # pins nothing and is left to the UNGATED record.
        if ($i ~ /^-Dartifact=[^:]+:[^:]+:[^:]+/) {
          c = $i; sub(/^-Dartifact=/, "", c); split(c, m, ":")
          print m[1] ":" m[2] "\t" m[3]
        }

        if ($i == "gem" && (k = verb_after(i + 1, "install")) && (p = operand(k + 1))) {
          for (j = p + 1; j <= NF; j++) {
            if (($j == "-v" || $j == "--version") && $(j + 1) != "") print $p "\t" $(j + 1)
            if ($j ~ /^--version=/) { v = $j; sub(/^--version=/, "", v); print $p "\t" v }
          }
        }

        if ($i == "cargo" && ((k = verb_after(i + 1, "add")) || (k = verb_after(i + 1, "install"))) && (p = operand(k + 1))) {
          versions($p, p + 1, 0)
        }

        if ($i == "bundle" && (k = verb_after(i + 1, "add")) && (p = operand(k + 1))) {
          versions($p, p + 1, 1)
        }

        if ($i == "dotnet" && (k = verb_after(i + 1, "add"))) {
          for (j = k + 1; j <= NF; j++) if ($j == "package") break
          if (j < NF) versions($(j + 1), j + 2, 1)
        }

        if ($i == "dotnet" && (k = verb_after(i + 1, "tool"))) {
          if ($(k + 1) == "install" || $(k + 1) == "update") {
            if ((p = operand(k + 2))) versions($p, p + 1, 0)
          }
        }
      }
    }
  '
}

# Emit "<ecosystem><TAB><package><TAB><spec>" for every operand of one statement.
guard_operand_specs() {
  local eco="$1" text="$2" token pkg spec

  if [[ "${eco}" == "go" ]]; then
    # A Go package is its whole module path. The generic pattern below keeps
    # only the last path element, so `go get example.com/x@v1` was checked as
    # `x@v1` and the deny message prescribed `safedeps check go x@v1`, which
    # approves (no advisory names a bare `x`) and then lets any `.../x@v1`
    # through. The path is kept whole here.
    { printf '%s\n' "${text}" | grep -oE '(^|[[:space:]])[A-Za-z0-9][A-Za-z0-9._~/-]*@[A-Za-z0-9._+~-]+' || true; } \
      | while read -r token; do
          [[ -n "${token}" ]] || continue
          printf '%s\t%s\t%s\n' "${eco}" "${token%@*}" "${token##*@}"
        done
  else
    { printf '%s\n' "${text}" \
      | grep -oE '(@[a-zA-Z0-9._/-]+/)?[a-zA-Z][a-zA-Z0-9._-]*@[a-zA-Z0-9._^~|<>=*+-]+' || true; } \
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
  # Both readers here are on the judgment path: a spec they fail to produce is
  # a spec the ledger never checks, and the install then reads as unpinned --
  # a pass, recorded as UNGATED for the wrong reason (caught in review). A
  # failure of either is recorded like any failed reading, for the gate.
  printf '%s\n' "${text}" | guard_extract_flagged_specs \
    | awk -F'\t' -v eco="${eco}" '
        # safedeps:operand_specs_ecosystem (scripts/measure/scan-failure-census.sh keys on this line)
        NF == 2 { print eco "\t" $1 "\t" $2 }' \
    || { [[ -z "${SAFEDEPS_SCAN_MARK:-}" ]] || printf 'failed\n' >> "${SAFEDEPS_SCAN_MARK}"; }
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
  # Quotes delimit operands and are removed before matching: `pip install
  # "requests==2.0.0"` pins requests, and the `==` reader used to miss it.
  local cmd="$1"
  local seg eco text

  while IFS= read -r seg; do
    [[ "${seg}" =~ [^[:space:]] ]] || continue
    command_is_dependency_install "${seg}" || continue
    eco=$(guard_segment_ecosystem "${seg}")
    [[ -n "${eco}" ]] || continue
    if guard_segment_is_runner "${seg}"; then
      text=$(guard_runner_operands "${seg}")
    else
      text=$(printf '%s' "${seg}" | tr -d "\"'" | tr '(){}' '    ')
    fi
    # Python extras (`evil[x]==1.0.0`) select optional dependencies of the same
    # package; the package and its version are what the ledger judges.
    [[ "${eco}" == "pypi" ]] && text=$(printf '%s' "${text}" | sed -E 's/\[[^] ]*\]//g')
    guard_operand_specs "${eco}" "${text}"
  done < <(command_candidate_texts "${cmd}" | tr ';|&' '\n')
}

LEDGER_ECOSYSTEM=$(guard_detect_ecosystem "${COMMAND}")
LEDGER_SPECS=()
while IFS= read -r ledger_spec_line; do
  [[ -z "${ledger_spec_line}" ]] && continue
  if [[ ${#LEDGER_SPECS[@]} -gt 0 ]]; then
    for existing_spec_line in "${LEDGER_SPECS[@]}"; do
      [[ "${existing_spec_line}" == "${ledger_spec_line}" ]] && continue 2
    done
  fi
  LEDGER_SPECS+=("${ledger_spec_line}")
done < <(guard_extract_specs "${COMMAND}")

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
  if [[ "${LEDGER_HAS_NPM}" == true ]] && ! guard_all_npm_installs_are_global "${COMMAND}"; then
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

# True only when the PostToolUse effect gate reads the result of EVERY install
# statement in the command. That gate reads package-lock.json, which only the
# npm CLI writes, and only for a project install. So pnpm, yarn and bun are not
# covered even though their ledger ecosystem is npm; neither is a runner (npx,
# npm exec), which changes no lockfile; neither is a global install, which lands
# outside the project; and neither is `--no-package-lock`. The exemption below
# used to be keyed on "the ledger ecosystem is npm", and that let an unpinned
# `pnpm add x` through with no record at all (GitHub #22).
guard_effect_gate_reads_every_install() {
  local cmd="$1"
  local seg scan any=false

  while IFS= read -r seg; do
    [[ "${seg}" =~ [^[:space:]] ]] || continue
    command_is_dependency_install "${seg}" || continue
    any=true
    guard_segment_is_runner "${seg}" && return 1
    scan=$(command_scan_text "${seg}")
    printf '%s' "${scan}" | grep -qEi "${SAFEDEPS_G_NPM_INSTALL_RE}" || return 1
    printf '%s' "${scan}" | grep -qEi -- '(^|[[:space:]])(-g|--global(=true)?|--location(=|[[:space:]]+)global|--no-package-lock|--package-lock=false)([[:space:]]|$)' && return 1
  done < <(command_candidate_texts "${cmd}" | tr ';|&' '\n')
  [[ "${any}" == true ]]
}

# An install that names a package but pins no version yields no spec, so the
# ledger gate above never ran for it. Where the effect gate reads the result
# (above), that is not a gap: it enforces on the lockfile closure. Everywhere
# else there is nothing behind this gate, so the install proceeds unverified --
# and until the record existed it did so with no trace at all, which
# contradicts the invariant that every bypass must be observable.
#
# A command that pins one package and names another without a pin is recorded
# too: "pinned" is read from what the extractor found, per package.
#
# This records the fact. It deliberately does NOT deny: refusing every unpinned
# install is a policy change (it would block ordinary `cargo add x` workflows)
# and belongs to the repo owner, not to this gate. The record is what makes that
# decision answerable with evidence instead of guesswork.
if [[ "${HIDDEN_DEPENDENCY_INSTALL}" != "true" && -n "${LEDGER_ECOSYSTEM}" ]] \
    && ! guard_effect_gate_reads_every_install "${COMMAND}" \
    && guard_names_package_without_spec "${COMMAND}"; then
  log_advisory "pre-guard UNGATED: ${LEDGER_ECOSYSTEM} install names a package with no version spec, so the ledger gate did not run. No effect gate reads the result of this install, so it is unverified. Command: ${COMMAND}"
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

if [[ "${HIDDEN_DEPENDENCY_INSTALL}" == "true" && ( -z "${LEDGER_ECOSYSTEM}" || ${#LEDGER_SPECS[@]} -eq 0 ) ]]; then
  guard_undecided_if_scan_failed
  log_advisory "pre-guard DENY: hidden dependency install could not be reduced to an approved spec — fail-closed."
  jq -nc '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:"safedeps: hidden dependency install detected, but no package spec could be extracted for ledger approval — install blocked fail-closed."}}'
  exit 0
fi

# Decide the inert rewrite first: it reads the command (the injectable test,
# the compound test), so it belongs before the gate like every other reading.
# It used to sit after the last settle, where a failed scan made it skip the
# rewrite or land it at the end of a compound command, and nothing noticed.
UPDATED_COMMAND=""
INERT_DOWNGRADED=false
if ! jq -e 'has("turn_id")' <<< "${INPUT}" >/dev/null 2>&1 && \
   command_is_injectable_npm_install "${COMMAND}" && \
   ! command_has_ignore_scripts_flag "${COMMAND}"; then
  if command_needs_inplace_inert "${COMMAND}"; then
    # Insert `--ignore-scripts` immediately AFTER each npm-install verb so the
    # flag stays inside its own statement. Appending to the end of the
    # whole string would land it on the trailing statement (e.g.
    # `npm install evil && npm run build --ignore-scripts`), leaving the install
    # itself running lifecycle scripts (finding #7). `npm install --ignore-scripts <pkg>`
    # is valid npm syntax (flags may precede operands).
    # Groups: 1 = through the verb, 2-4 = the options, 5 = the verb, 6 = what
    # follows it. scripts/test/smoke.sh pins the landing spot.
    # A failed sed leaves UPDATED_COMMAND empty, which differs from COMMAND and
    # so would skip both the rewrite and the downgrade record below; the mark
    # makes the gate settle it instead.
    UPDATED_COMMAND=$(printf '%s' "${COMMAND}" | sed -E \
      "s/(npm${SAFEDEPS_G_OPTS}[[:space:]]+(${SAFEDEPS_G_NPM_VERBS}))([[:space:]]|\$)/\\1 --ignore-scripts\\6/g") \
      || guard_mark_reading_failed
    if [[ "${UPDATED_COMMAND}" == "${COMMAND}" ]]; then
      # Rewrite did not land — never blind-append to a compound command. Downgrade
      # to detect-and-rollback (the effect gate still verifies the closure) and
      # record it below, once the command is known to run; the inert guarantee is
      # observably relaxed, never silently.
      UPDATED_COMMAND=""
      INERT_DOWNGRADED=true
    fi
  else
    UPDATED_COMMAND="${COMMAND} --ignore-scripts"
  fi
fi

# The gate: every verdict from here on lets the command run, and nothing after
# this line reads the command text. Pending state, the inert meta and the allow
# are written only once it has passed, so a command it denies leaves no pending
# file for PostToolUse to pick up on the next identical command.
guard_settle_scan_failure

if [[ "${INERT_DOWNGRADED}" == "true" ]]; then
  log_advisory "pre-guard: could not make compound npm install inert in-place; lifecycle scripts may run before the effect gate verifies (downgraded to detect-and-rollback). Command: ${COMMAND}"
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
find "${PENDING_DIR}" -name '*.json' -type f -mmin +1440 -delete 2>/dev/null || true
# Key = (dir, normalized command); the snapshot id suffix makes the filename unique
# per install, so even two identical concurrent commands keep separate state.
PENDING_KEY=$(compute_pending_key "${KEY_DIR_HASH}" "${COMMAND}")
CURRENT_STATE=$(jq -n --arg sid "${SNAPSHOT_ID}" --arg pdir "${PROJECT_DIR}" --arg dhash "${DIR_HASH}" \
  '{snapshot_id: $sid, project_dir: $pdir, dir_hash: $dhash}')
# $$ (this pre hook's PID) guarantees a unique filename even for two installs in
# the same second (SNAPSHOT_ID has only 1s resolution).
write_state_file "${PENDING_DIR}/${PENDING_KEY}__${SNAPSHOT_ID}_$$.json" "${CURRENT_STATE}"

if [[ -n "${UPDATED_COMMAND}" ]]; then
  mark_ignore_scripts_injected
  jq -nc --arg command "${UPDATED_COMMAND}" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",updatedInput:{command:$command}}}'
  exit 0
fi

# Allow the command to proceed — PostToolUse will verify the result
exit 0
