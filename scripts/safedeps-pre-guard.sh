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
  if printf '%s' "${raw_input}" | grep -qiE "${SAFEDEPS_RAW_INSTALL_RE}"; then
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

command_is_dependency_install() {
  local command="$1"
  local scan_command
  local install_pattern

  install_pattern="${SAFEDEPS_INSTALL_PATTERN}"

  while IFS= read -r scan_command; do
    scan_command=$(command_scan_text "${scan_command}")
    echo "${scan_command}" | grep -qEi "${install_pattern}" && return 0
  done < <(command_candidate_texts "${command}")
  return 1
}

command_hides_dependency_install() {
  local command="$1"
  local payload

  # Top-level pipe-to-shell: `<producer> | sh` whose producer text literally
  # contains a package manager + install verb (e.g. `printf 'pip install x' | sh`).
  # The install TEXT is searched raw (in a real hidden install it legitimately
  # lives inside the producer's quotes), but the PIPE must sit in execution
  # position — see payload_pipes_install_text_to_shell. Because outer quoting
  # hides an inner pipe from that position check, every executed inner text
  # (`sh -c` payloads, eval payloads, command substitutions) gets the same check
  # on its own quoting level below.
  payload_pipes_install_text_to_shell "${command}" && return 0

  while IFS= read -r payload; do
    [[ -z "${payload}" ]] && continue
    payload_pipes_install_text_to_shell "${payload}" && return 0
  done < <(extract_shell_c_payloads "${command}")

  while IFS= read -r payload; do
    [[ -z "${payload}" ]] && continue
    command_is_dependency_install "${payload}" && return 0
    payload_pipes_install_text_to_shell "${payload}" && return 0
  done < <(extract_eval_payloads "${command}")

  while IFS= read -r payload; do
    [[ -z "${payload}" ]] && continue
    command_is_dependency_install "${payload}" && return 0
    payload_pipes_install_text_to_shell "${payload}" && return 0
  done < <(extract_command_substitution_payloads "${command}")

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
          # and never opens one (`\"` is a quote character). Inside a double-
          # quoted region it is blanked like everything else and never closes it.
          put(q == 0 ? c : " ")
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

  for _ in 1 2 3; do
    text=$(printf '%s' "${text}" | sed -E \
      -e 's/^[[:space:]]+//' \
      -e "s#(^|[[:space:];|&({!])(/[^[:space:];|&]+/)(${SAFEDEPS_G_EXECUTABLES}|sh|bash|zsh)([[:space:];|&]|\$)#\\1\\3\\4#g" \
      -e 's#(^|[;&|({!][[:space:]]*|(then|do|else|elif|if|while|until|time|coproc)[[:space:]]+)(env([[:space:]]+(-i|--ignore-environment|-0|--null|-v|--debug|-u[[:space:]]*[^[:space:]]+|--unset(=|[[:space:]]+)[^[:space:]]+|-C[[:space:]]*[^[:space:]]+|--chdir(=|[[:space:]]+)[^[:space:]]+|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+))*[[:space:]]+|command[[:space:]]+|exec[[:space:]]+)#\1#g' \
      -e 's#(^|[;&|({!][[:space:]]*|(then|do|else|elif|if|while|until|time|coproc)[[:space:]]+)([A-Za-z_][A-Za-z0-9_]*=[^[:space:]'\''"]*[[:space:]]+)+#\1#g')
  done
  printf '%s' "${text}"
}

strip_heredoc_bodies() {
  local input="$1"
  local line
  local delimiter=""
  local heredoc_re="<<-?[[:space:]]*[\"']?([A-Za-z0-9_][A-Za-z0-9_.-]*)[\"']?"

  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ -n "${delimiter}" ]]; then
      if [[ "${line}" == "${delimiter}" ]]; then
        delimiter=""
      fi
      continue
    fi

    if [[ "${line}" =~ ${heredoc_re} ]]; then
      delimiter="${BASH_REMATCH[1]}"
    fi
    printf '%s\n' "${line}"
  done <<< "${input}"
}

extract_shell_c_payloads() {
  local rest="$1"

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

  rest=$(strip_heredoc_bodies "${rest}")
  while [[ "${rest}" =~ (^|[[:space:];|&])eval[[:space:]]+\"([^\"]*)\" ]]; do
    printf '%s\n' "${BASH_REMATCH[2]}"
    rest="${rest#*"${BASH_REMATCH[0]}"}"
  done

  rest="$1"
  rest=$(strip_heredoc_bodies "${rest}")
  while [[ "${rest}" =~ (^|[[:space:];|&])eval[[:space:]]+\'([^\']*)\' ]]; do
    printf '%s\n' "${BASH_REMATCH[2]}"
    rest="${rest#*"${BASH_REMATCH[0]}"}"
  done
}

extract_command_substitution_payloads() {
  local input="$1"
  local rest

  rest=$(strip_heredoc_bodies "${input}")
  while [[ "${rest}" == *'$('* ]]; do
    rest="${rest#*'$('}"
    printf '%s\n' "${rest%%)*}"
    rest="${rest#*)}"
  done

  rest=$(strip_heredoc_bodies "${input}")
  while [[ "${rest}" == *'`'* ]]; do
    rest="${rest#*\`}"
    printf '%s\n' "${rest%%\`*}"
    [[ "${rest}" == *'`'* ]] || break
    rest="${rest#*\`}"
  done
}

payload_pipes_install_text_to_shell() {
  local payload="$1"
  local exec_view
  local manager_pattern
  local verb_pattern

  manager_pattern='(npm|npx|pnpm|pnpx|yarn|bun|bunx|pip[0-9.]*|(python[0-9.]*|py)[[:space:]]+-m[[:space:]]*pip|poetry|uv|uvx|pipx|pipenv|cargo|go|gem|bundle|mvn|dotnet)'
  verb_pattern="(${SAFEDEPS_G_ALL_VERBS})"

  # The pipe must sit in EXECUTION position at this quoting level: outside
  # quotes (a quoted `| sh` is data — e.g. a repro idiom quoted in a commit
  # message) and outside heredoc bodies (a body is data; `cat <<EOF | sh` keeps
  # its pipe on the redirect line, which survives the strip). The install text
  # is still searched raw, because in a real hidden install it lives inside the
  # producer's quotes or heredoc body by construction.
  #
  # Check the raw install text FIRST: the grep is O(n) while the exec_view
  # scan is a quadratic character loop, and both checks are pure predicates,
  # so conjunction order cannot change the verdict — only the cost. Most
  # commands carry no install text at all and must not pay for the scan.
  # Measured on a 6KB no-install-text command: 1.51s with the raw greps
  # only, 2.75s with the scan forced first, 1.39s with this order.
  echo "${payload}" | grep -qEi "${manager_pattern}.*${verb_pattern}" || return 1

  # The consumer side is normalized the same way the producer side already is:
  # `| /bin/sh`, `| env sh`, and `| command sh` are the same consumer as `| sh`.
  # normalize_install_text is the file's existing statement of that equivalence —
  # it was applied to the install text and skipped here, so the two sides of one
  # pipe disagreed about what counts as the same invocation. It runs after the
  # raw-text short circuit above, so only install-bearing commands pay for it.
  exec_view=$(normalize_install_text "$(command_scan_text "$(strip_heredoc_bodies "${payload}")")")
  echo "${exec_view}" | grep -qEi '\|[[:space:]]*(bash|sh|zsh)([[:space:]]|$)'
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

  command=$(strip_heredoc_bodies "${command}")
  command=$(join_line_continuations "${command}")

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
    echo "${scan_command}" | grep -qEi "${npm_install_pattern}" && return 0
  done < <(command_candidate_texts "${command}")
  return 1
}

command_has_ignore_scripts_flag() {
  local command="$1"
  local scan_command

  while IFS= read -r scan_command; do
    scan_command=$(command_scan_text "${scan_command}")
    echo "${scan_command}" | grep -qEi -- '(^|[[:space:]])--ignore-scripts([=[:space:]]|$)' && return 0
  done < <(command_candidate_texts "${command}")
  return 1
}

# True when the command chains more than one statement at the shell level (a `;`,
# `&&`, `||`, or `|` OUTSIDE quotes). Quoted separators are blanked by
# command_scan_text first so `echo "a && b"` is NOT treated as compound. Used to
# decide how to inject `--ignore-scripts`: appending to a compound command lands
# the flag on the trailing statement, not on the npm install (finding #7).
command_is_compound() {
  local scanned
  scanned=$(command_scan_text "$1")
  printf '%s' "${scanned}" | grep -qE '[;&|]'
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
# The extractor depends on this output, so a failure here would read as "no
# statements", which reads as "no install". Every failure is marked the way
# command_scan_text marks its own (guard_settle_scan_failure reads it); the mark
# is written here because this runs before guard_mark_scan_failed is defined.
command_statements_failed() {
  [[ -z "${SAFEDEPS_SCAN_MARK:-}" ]] || printf 'failed\n' >> "${SAFEDEPS_SCAN_MARK}"
}
command_statements() {
  local raw_file scan_file
  raw_file=$(mktemp "${TMPDIR:-/tmp}/safedeps-stmt-raw.XXXXXX") || { command_statements_failed; return 1; }
  scan_file=$(mktemp "${TMPDIR:-/tmp}/safedeps-stmt-scan.XXXXXX") || { rm -f "${raw_file}"; command_statements_failed; return 1; }
  printf '%s' "$1" > "${raw_file}"
  command_scan_text "$1" > "${scan_file}" || { rm -f "${raw_file}" "${scan_file}"; return 1; }
  if ! LC_ALL=C awk -v scan_file="${scan_file}" -v raw_file="${raw_file}" '
    # safedeps:command_statements (scripts/test/scan-contract.sh keys on this line)
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
    rm -f "${raw_file}" "${scan_file}"
    command_statements_failed
    return 1
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
guard_npmrc_value() {
  local file="$1" key="$2"
  [[ -f "${file}" && -r "${file}" ]] || return 0
  awk -v key="${key}" -v q="'" '
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
  ' "${file}" 2>/dev/null || true
}

# The directory npm reads the project .npmrc from when it installs in <dir>: the
# nearest directory at or above <dir> with a package.json or a node_modules, or
# <dir> itself when there is none. `--prefix` names it outright. Measured: with
# the .npmrc beside the project's package.json, an install from a subdirectory
# followed it; with the .npmrc in a subdirectory that had no package.json, it
# did not.
guard_npm_local_prefix() {
  local dir="$1" named="$2" probe
  if [[ "${named}" == true ]]; then
    printf '%s' "${dir}"
    return 0
  fi
  probe="${dir}"
  while [[ -n "${probe}" ]]; do
    if [[ -e "${probe}/package.json" || -d "${probe}/node_modules" ]]; then
      printf '%s' "${probe}"
      return 0
    fi
    [[ "${probe}" != / ]] || break
    probe=$(dirname "${probe}")
  done
  printf '%s' "${dir}"
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
  local dir="$1" named="$2" user_rc="$3" cli_global_off="$4"
  local project_rc key value source
  project_rc="$(guard_npm_local_prefix "${dir}" "${named}")/.npmrc"
  local undecided=false
  for key in location global; do
    source="${project_rc}"
    value=$(guard_npmrc_value "${project_rc}" "${key}")
    if [[ -z "${value}" ]]; then
      if [[ "${user_rc}" == "?" ]]; then
        undecided=true
        continue
      fi
      source="${user_rc}"
      value=$(guard_npmrc_value "${user_rc}" "${key}")
    fi
    [[ -n "${value}" ]] || continue
    value="${value#=}"
    case "${key}:${value}" in
      location:user|location:project|global:false|global:null) continue ;;
    esac
    if [[ "${key}" == global && "${cli_global_off}" == true ]]; then
      continue
    fi
    printf '%s sets %s=%s' "${source}" "${key}" "${value}"
    return 0
  done
  if [[ "${undecided}" == true ]]; then
    printf 'the user .npmrc is named by a value the shell decides at run time'
  fi
  return 0
}

# Where each install statement in the command lands, one line per statement of
# the command (command_statements), as `<kind>\035<dir>\035<why>\035<raw>`.
# <kind> is `npm` for an npm CLI install that is not a runner, `other` for every
# other install, and `-` for a statement that is not an install (a `cd`, an
# `echo`), whose <dir> and <why> are empty. <dir> is an absolute path,
# `global`, or `?` when the text does not say. <why> is empty unless an .npmrc
# keeps the install off the record, and then it names the file and the setting.
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
#   - Global installs: `-g`, `--global`, `--location global`, and the same two
#     settings given as `npm_config_global` / `npm_config_location` anywhere in
#     the command, prefixed or exported. Those land in npm's global prefix and
#     write no lockfile at all.
#   - `npm_config_prefix` in the environment does NOT move a project install:
#     measured, it landed in the cwd project and the gate rolled it back.
#   - The same two settings in the project's or the user's .npmrc, which the
#     command does not show. guard_npmrc_unrecorded reads both files; an install
#     they keep off the record is `?` with the reason in <why>. The global and
#     builtin npmrc, and a file named only at run time, are outside what this
#     reads; ARCHITECTURE.md states that boundary.
resolve_install_targets() {
  local cmd="$1" cwd="$2"
  local text before stmt after words raw head target want kind manager tok value normalized in_env skip
  local named user_rc cli_global_off why
  local dir="${cwd}" grouped=false env_global=false env_userconfig=false
  local -a toks=()

  text=$(join_line_continuations "$(strip_heredoc_bodies "${cmd}")")
  command_scan_text "${text}" | grep -q '[(){}`]' && grouped=true
  command_scan_text "${text}" \
    | grep -qEi '(^|[[:space:];&|(])(export[[:space:]]+)?npm_config_(global|location)=' && env_global=true
  command_scan_text "${text}" | grep -qEi 'npm_config_userconfig=' && env_userconfig=true

  while IFS=$'\035' read -r before stmt after words raw; do
    kind=- target="" why=""
    # One pass that `break` leaves early: every statement prints exactly one
    # line below, whichever test ends it.
    while :; do
      [[ -n "${words}" ]] || break
      IFS=$'\037' read -ra toks <<< "${words}"
      [[ ${#toks[@]} -gt 0 ]] || break

      # A statement may open with a group or a reserved word; the command is
      # what follows.
      while [[ ${#toks[@]} -gt 0 ]]; do
        head="${toks[0]}"
        head="${head#"${head%%[!({!]*}"}"
        case "${head}" in
          ''|then|do|else|elif|if|while|until|time) toks=("${toks[@]:1}") ;;
          *) toks[0]="${head}"; break ;;
        esac
      done
      [[ ${#toks[@]} -gt 0 ]] || break

      case "${toks[0]}" in
        cd|pushd|popd)
          if [[ "${grouped}" == true || "${toks[0]}" == popd \
                || "${before}" == "|" || "${before}" == "&" || "${after}" == "|" || "${after}" == "&" ]]; then
            dir="?"
            break
          fi
          value=""
          for tok in "${toks[@]:1}"; do
            case "${tok}" in -L|-P|-e|-@|-n) continue ;; esac
            value="${tok}"
            break
          done
          dir=$(guard_literal_dir "${dir}" "${value}")
          [[ "${dir}" == "?" || -d "${dir}" ]] || dir="?"
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
      # assignment.
      target="${dir}"
      want=""
      skip=false
      named=false
      in_env=false
      [[ "${toks[0]}" == env ]] && in_env=true
      for tok in "${toks[@]:1}"; do
        if [[ "${skip}" == true ]]; then skip=false; continue; fi
        if [[ -n "${want}" ]]; then
          target=$(guard_literal_dir "${target}" "${tok}")
          want=""
          continue
        fi
        if [[ "${in_env}" == true ]]; then
          case "${tok}" in
            -C|--chdir) want=1; continue ;;
            --chdir=*) target=$(guard_literal_dir "${target}" "${tok#*=}"); continue ;;
            -u|--unset) skip=true; continue ;;
            -*|*=*) continue ;;
            *) in_env=false ;;
          esac
        fi
        case "${tok}" in
          --prefix=*|--cwd=*|--dir=*|--install-dir=*)
            target=$(guard_literal_dir "${target}" "${tok#*=}")
            named=true
            ;;
          --prefix|--cwd|--dir|--install-dir) want=1; named=true ;;
          -C)
            if [[ -n "${manager}" ]]; then want=1; named=true; fi
            ;;
          -C?*)
            if [[ -n "${manager}" ]]; then target="?"; fi
            ;;
        esac
      done
      if [[ -n "${want}" ]]; then target="?"; fi

      if [[ "${kind}" == npm ]]; then
        if [[ "${env_global}" == true ]] \
            || printf '%s' "${stmt}" | grep -qEi -- '(^|[[:space:]])(-g|--global(=true)?|--location(=|[[:space:]]+)global)([[:space:]]|$)'; then
          target=global
        fi
      fi

      # An install the command keeps in a known directory can still be kept off
      # the record by an .npmrc. The user file is the one npm would read: named
      # by `--userconfig`, then by npm_config_userconfig, then ~/.npmrc.
      why=""
      if [[ "${kind}" == npm && "${target}" != global && "${target}" != "?" ]]; then
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
        [[ "${user_rc}" == "?" ]] || user_rc=$(guard_literal_dir "${dir}" "${user_rc}")
        why=$(guard_npmrc_unrecorded "${target}" "${named}" "${user_rc}" "${cli_global_off}")
        [[ -z "${why}" ]] || target="?"
      fi
      break
    done
    printf '%s\035%s\035%s\035%s\n' "${kind}" "${target}" "${why}" "${raw}"
  done < <(command_statements "${text}")
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

guard_scan_failed() {
  [[ -z "${SAFEDEPS_SCAN_MARK}" || -s "${SAFEDEPS_SCAN_MARK}" ]]
}

# Called before every path that ALLOWS the command. If any scan failed, the
# verdicts above were read from missing text, so they are replaced with the rule
# the jq-missing path uses: an install-looking command is denied as UNDECIDED,
# anything else runs with the failure on record. Denies above stand as they are.
# Whether a command looks like an install, judged without the scanner: the
# precise pattern on every candidate text as it stands (quotes not blanked),
# or the loose raw pattern on the whole command. command_candidate_texts runs
# on bash and sed, so this still answers when awk is the thing that failed.
# The loose pattern alone missed `npm i`, `npm ci` and `npm update` (caught in
# review), and the precise one alone would miss what only the loose one sees,
# so neither may shrink what the other finds.
guard_looks_like_install_unscanned() {
  local text
  printf '%s' "${COMMAND}" | grep -qiE "${SAFEDEPS_RAW_INSTALL_RE}" && return 0
  while IFS= read -r text; do
    printf '%s\n' "${text}" | grep -qiE "${SAFEDEPS_INSTALL_PATTERN}" && return 0
  done < <(command_candidate_texts "${COMMAND}")
  return 1
}

guard_settle_scan_failure() {
  guard_scan_failed || return 0
  if guard_looks_like_install_unscanned; then
    log_advisory "pre-guard DENY: the command scanner failed on a likely dependency-install command — undecided, fail-closed. Command: ${COMMAND}"
    jq -nc '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:"safedeps: UNDECIDED, not unsafe — the command scanner (awk) failed, so safedeps could not tell whether this command installs a dependency. It looks like one, so it is blocked fail-closed. Nothing was detected in it. Check that `echo x | awk 1` works, then retry."}}'
    exit 0
  fi
  log_advisory "pre-guard: the command scanner failed; the command did not look like a dependency install and was allowed. Command: ${COMMAND}"
  printf 'safedeps: the command scanner (awk) failed, so this command was judged from its raw text only. It did not look like a dependency install and was allowed. The failure is recorded in advisory.log.\n' >&2
}

HIDDEN_DEPENDENCY_INSTALL=false
if ! command_is_dependency_install "${COMMAND}"; then
  # Catch indirection patterns that hide install commands (V-002)
  if command_hides_dependency_install "${COMMAND}"; then
    HIDDEN_DEPENDENCY_INSTALL=true
    : # Fall through — treat as install candidate
  else
    guard_settle_scan_failure
    exit 0
  fi
fi

# --- Reorg Guard Activated ---

# Find lock files in common locations
# Per Claude Code / Codex CLI hook spec, `cwd` is top-level. Fall back to `pwd`
# only when the hook is invoked outside the engine (manual test, no stdin payload).
CWD_DIR=$(echo "${INPUT}" | jq -r '.cwd // empty' 2>/dev/null)
if [[ -z "${CWD_DIR}" ]]; then
  CWD_DIR=$(pwd)
fi

# Resolve the actual install target: a relocation flag or an earlier `cd`
# moves the install away from cwd (finding #3; resolve_install_targets says
# which). Snapshot + effect-gate must follow the real target, while the
# PostToolUse pending-key still keys on cwd (post-verify only knows cwd) — so
# KEY_DIR_HASH (cwd) and DIR_HASH (install dir) are tracked separately below.
# The first install statement with a known, non-global target decides; an
# install that lands elsewhere is not read, and guard_effect_gate_reads says so.
PROJECT_DIR="${CWD_DIR}"
INSTALL_TARGETS=$(resolve_install_targets "${COMMAND}" "${CWD_DIR}")
while IFS=$'\035' read -r _ install_target _ _; do
  [[ -n "${install_target}" && "${install_target}" != "?" && "${install_target}" != global ]] || continue
  PROJECT_DIR="${install_target}"
  break
done <<< "${INSTALL_TARGETS}"
# An .npmrc that keeps an install off the record is not text in the command, so
# the record has to say which file did it; the UNGATED line alone would point at
# a command that looks like an ordinary project install.
while IFS=$'\035' read -r _ _ install_why _; do
  [[ -n "${install_why}" ]] || continue
  log_advisory "pre-guard: ${install_why}, so npm does not record this install where the effect gate reads it. Command: ${COMMAND}"
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
if echo "${COMMAND}" | grep -qEi 'curl.*\|[[:space:]]*(bash|sh|node)'; then
  SUSPICIOUS=true
  REASONS+=("Command pipes remote content to shell execution")
fi

# Check for install with --ignore-scripts being removed (attacker might want scripts to run)
if echo "${COMMAND}" | grep -qEi 'npm[[:space:]]+config[[:space:]]+set[[:space:]]+ignore-scripts[[:space:]]+false'; then
  SUSPICIOUS=true
  REASONS+=("Command explicitly enables install scripts")
fi

# Check for registry override to unknown registry
if echo "${COMMAND}" | grep -qEi -- '--registry([=[:space:]]+)'; then
  if ! echo "${COMMAND}" | grep -qEi -- '--registry([=[:space:]]+)https?://(registry\.npmjs\.org|registry\.yarnpkg\.com)(/|[[:space:]]|$)'; then
    SUSPICIOUS=true
    REASONS+=("Command uses non-standard npm registry")
  fi
fi

# Check for packages with suspicious naming patterns (typosquatting indicators)
TYPOSQUAT_PATTERNS='(lod[bcdfghjklmnpqrstvwxyz]sh|lodahs|loadsh|lodashh|reacct|exprss|axois|babeel|webpackk|esliint|l0dash|m0ment|4xios|reqeusts|requets|djagno|numppy|panddas|pilliow|tensorfow|scikit-learnn|serde_jsonn|tokioo|reqwestt|clapp|github\.con/|githb\.com/|railss|sinatraa|nokogirri|log4jj|springframewrok|commons-collectionss|newtonsoft\.josn|serilogg|nunittt)'
if echo "${COMMAND}" | grep -qEi "${TYPOSQUAT_PATTERNS}"; then
  SUSPICIOUS=true
  REASONS+=("Package name matches known typosquatting patterns")
fi

if [[ "${SUSPICIOUS}" == "true" ]]; then
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
  if echo "${scan}" | grep -qEi "${SAFEDEPS_G_START}(npm|pnpm|pnpx|yarn|npx|bun|bunx)([[:space:]]|\$)"; then
    printf 'npm'
  elif echo "${scan}" | grep -qEi "${SAFEDEPS_G_START}(pip[0-9.]*|poetry|uv|uvx|pipx|pipenv|(python[0-9.]*|py)${SAFEDEPS_G_OPTS}[[:space:]]+-m[[:space:]]*pip)([[:space:]]|\$)"; then
    printf 'pypi'
  elif echo "${scan}" | grep -qEi "${SAFEDEPS_G_START}cargo([[:space:]]|\$)"; then
    printf 'crates.io'
  elif echo "${scan}" | grep -qEi "${SAFEDEPS_G_START}go([[:space:]]|\$)"; then
    printf 'go'
  elif echo "${scan}" | grep -qEi "${SAFEDEPS_G_START}(gem|bundle)([[:space:]]|\$)"; then
    printf 'rubygems'
  elif echo "${scan}" | grep -qEi "${SAFEDEPS_G_START}mvn([[:space:]]|\$)"; then
    printf 'maven'
  elif echo "${scan}" | grep -qEi "${SAFEDEPS_G_START}dotnet([[:space:]]|\$)"; then
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
  command_scan_text "${seg}" | grep -qEi "${SAFEDEPS_G_START}((npx|bunx)([[:space:]]|\$)|npm${SAFEDEPS_G_OPTS}[[:space:]]+(exec|x)([[:space:]]|\$)|bun${SAFEDEPS_G_OPTS}[[:space:]]+x([[:space:]]|\$))"
}

# True when the statement is a runner: something that fetches a package and
# executes it (npx, npm exec, pnpm dlx, bunx, uvx, pipx run, go run ...).
guard_segment_is_runner() {
  command_scan_text "$1" | grep -qEi "${SAFEDEPS_G_RUNNER_HEAD_RE}"
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
      echo "${scan}" | grep -qEi '(^|[[:space:]])npm([[:space:]]|$)' || continue
      echo "${scan}" | grep -qEi "(^|[[:space:]])(${SAFEDEPS_G_NPM_VERBS})([[:space:]]|\$)" || continue
      found=true
      echo "${scan}" | grep -qEi -- '(^|[[:space:]])(-g|--global(=true)?|--location(=|[[:space:]]+)global)([[:space:]]|$)' || return 1
    done < <(printf '%s\n' "${candidate}" | tr ';|&' '\n')
  done < <(command_candidate_texts "${cmd}")

  [[ "${found}" == true ]]
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
  # Quotes are delimiters here, not data: `npx "cowsay@1.5.0"` runs cowsay@1.5.0.
  #
  # A failed tr or sed here is a failed spec reader (see guard_operand_specs):
  # it yields no operand, and no operand reads as nothing to check.
  local text after head family names adds takes want tok key nopt last="" match option
  local -a toks=()
  text=$(printf '%s\n' "$1" | guard_shell_dequote) || guard_mark_scan_failed
  # The runner itself is kept, ahead of \037, to choose the table. The first
  # line is taken here rather than by `head -n1`, which can close the pipe on a
  # sed that still has lines to write, and pipefail reads that SIGPIPE as a
  # failed reader.
  after=$(printf '%s\n' "${text}" \
    | sed -nE "s/^(.*[[:space:];&|({!])?(${SAFEDEPS_G_RUNNER_BODY})([[:space:]]|\$)/\\2"$'\037'"/p") || guard_mark_scan_failed
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
        [[ "${named_by_option}" == true ]] || printf '%s\n' "${tok}"
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
  # own and is read there. And a statement the effect gate reads -- an npm CLI
  # install that lands in the directory the gate reads -- is exempt; the rest of
  # the command is not. A payload's install is never exempt, because where it
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

    # A comment ends the statement. Redirections are gone already
    # (guard_strip_redirections).
    [[ "${tok}" == \#* ]] && break

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
        # gone from the text already (guard_strip_redirections).
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
        || { rc=$?; (( rc <= 1 )) || guard_mark_scan_failed; }; } \
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
        || { rc=$?; (( rc <= 1 )) || guard_mark_scan_failed; }; } \
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
        NF == 2 { print eco "\t" $1 "\t" $2 }
        NF == 3 && $1 == "@" && positions == "positions" { print }
      '; then
    guard_mark_scan_failed
  fi
}

guard_mark_scan_failed() {
  [[ -z "${SAFEDEPS_SCAN_MARK:-}" ]] || printf 'failed\n' >> "${SAFEDEPS_SCAN_MARK}"
}

# Text with its quoting removed the way the shell removes it, one line at a
# time. Outside quotes a backslash vanishes and leaves the next byte as a plain
# character; inside double quotes it does that only before `$`, a backquote,
# `"` or a backslash; inside single quotes it is just a backslash. The quote
# characters themselves go.
#
# The readers used to delete the quote characters and leave every backslash,
# so `pip install ev\il==6.6.6`, which the shell runs as evil==6.6.6, read as
# the unpinned operand `ev\il==6.6.6`: recorded, and never checked. Elsewhere
# the backslash cut the name: `pnpm add ev\il@6.6.6` prescribed
# `check npm il@6.6.6`, and `gem install ra\ke -v 13.0.0` prescribed
# `ra\ke@13.0.0`, identities no advisory names, which approve and then let
# the real package through. Blanks a quote held become plain blanks here, so a
# quoted operand with a blank still splits in two, as it did before.
guard_shell_dequote() {
  LC_ALL=C awk '
    # safedeps:shell_dequote (scripts/test/scan-contract.sh keys on this line)
    {
      out = ""; q = 0
      n = split($0, c, "")
      for (i = 1; i <= n; i++) {
        ch = c[i]
        if (q == 0) {
          if (ch == "\\") { if (i < n) { i++; out = out c[i] }; continue }
          if (ch == "\047") { q = 1; continue }
          if (ch == "\"") { q = 2; continue }
          out = out ch
          continue
        }
        if (q == 1) { if (ch == "\047") q = 0; else out = out ch; continue }
        if (ch == "\\" && i < n && (c[i + 1] == "$" || c[i + 1] == "`" || c[i + 1] == "\"" || c[i + 1] == "\\")) {
          i++; out = out c[i]; continue
        }
        if (ch == "\"") { q = 0; continue }
        out = out ch
      }
      print out
    }'
}

# A statement without its redirections. A redirection belongs to the shell,
# and so does its target: in `pnpm add left-pad >/dev/null` the shell opens
# /dev/null and pnpm never sees it. Every reader of the statement used to see
# it as an operand, so the record named `npm:>/dev/null` beside the package,
# and a version flag bound to it: `gem install rake -v 13.0.0 >/dev/null`
# prescribed `check rubygems >/dev/null@13.0.0`. The test runs on the text as
# written, quotes still in place, because only an unquoted operator at the
# start of a word is one: `'>=3'` is a version specifier. The target may be
# attached or follow blanks, and it is one shell word: unquoted bytes, a
# backslash escape, a double-quoted run (with its own escapes) and a
# single-quoted run, in any order. It reads stdin, a statement per line, so
# guard_extract_pieces runs it once over every statement instead of once per
# statement: a 4KB command of short installs is about 250 statements.
SAFEDEPS_REDIRECT_TARGET_CHAR="([^[:space:]'\"\\\\]|\\\\.|\"([^\"\\\\]|\\\\.)*\"|'[^']*')"
guard_strip_redirections() {
  sed -E \
    "s#(^|[[:space:]])[0-9]*(<<<|>>|>[|&]|<[&>]|>|<)[[:space:]]*${SAFEDEPS_REDIRECT_TARGET_CHAR}*#\\1#g"
}

# One statement as the extractor reads it: a runner's package operands (one per
# line), or the statement with its quotes removed and its grouping characters
# blanked. Quotes delimit operands and are removed before matching: `pip install
# "requests==2.0.0"` pins requests, and the `==` reader used to miss it. Python
# extras (`evil[x]==1.0.0`) select optional dependencies of the same package;
# the package and its version are what the ledger judges. The UNGATED record
# walks this same text, so that its token positions are the extractor's.
guard_extract_statement_text() {
  local eco="$1" seg="$2" runner="$3" text
  # Each transform below is a spec reader, and a failed one leaves no text or
  # the wrong text, which reads as no spec. So a failure is marked the way
  # guard_operand_specs marks its own (the runner reader marks inside).
  if [[ "${runner}" == true ]]; then
    text=$(guard_runner_operands "${seg}")
  else
    text=$(printf '%s\n' "${seg}" | guard_shell_dequote | tr '(){}' '    ') || guard_mark_scan_failed
  fi
  if [[ "${eco}" == "pypi" ]]; then
    text=$(printf '%s' "${text}" | sed -E 's/\[[^] ]*\]//g') || guard_mark_scan_failed
  fi
  # An npm alias installs its target under another name: `left-pad@npm:evil-pkg`
  # fetches evil-pkg. Read as written it prescribed `check npm left-pad@npm`,
  # which names neither package and can never approve. The alias name is
  # dropped, so the target is what the ledger judges, pinned or not.
  if [[ "${eco}" == "npm" ]]; then
    text=$(printf '%s' "${text}" | sed -E 's/(^|[[:space:]=])(@[A-Za-z0-9._~-]+\/)?[A-Za-z0-9._~-]+@npm:/\1/g') \
      || guard_mark_scan_failed
  fi
  printf '%s' "${text}"
}

# The one answer to "does the effect gate read this install statement": an npm
# CLI install, not a runner, that lands in the directory the gate reads. <kind>
# and <target> are a statement's fields from resolve_install_targets, which is
# also what chose PROJECT_DIR. An .npmrc that keeps the install off the record
# has already turned <target> into `?` there.
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
  local kind="$1" target="$2"
  [[ "${kind}" == npm ]] || return 1
  [[ -n "${target}" && "${target}" != "?" && "${target}" != global ]] || return 1
  [[ "$(canonicalize_dir "${target}")" == "${PROJECT_DIR}" ]]
}

# The statements the spec extractor reads, one piece per line as
# `<read>\t<piece>`. <read> is `true` when the effect gate reads the install the
# piece belongs to (guard_effect_gate_reads), and `false` otherwise.
#
# The command's own statements come from <targets>, resolve_install_targets'
# list, so the extractor and the landing read the same statements and each one
# carries its landing with it. Joining two separate readings of a command was
# the defect behind three rounds of the UNGATED record (a pin found by name,
# then by ecosystem and name), and a statement found by position in a second
# split would be the same join. Each statement is normalized and then cut at
# `;`, `|`, `&` and newlines as the whole command used to be, so the pieces,
# and the specs read from them, are the ones the extractor read before.
#
# Payloads (`sh -c`, `eval`, a command substitution) follow, with <read> false:
# where a payload's install lands is decided inside the payload, and the
# landing does not read inside it.
guard_extract_pieces() {
  local cmd="$1" targets="$2"
  local kind target read_flags="" normalized

  while IFS=$'\035' read -r kind target _ _; do
    [[ -n "${kind}" ]] || continue
    if guard_effect_gate_reads "${kind}" "${target}"; then
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
  )")
  normalized=$(printf '%s\n' "${normalized}" | guard_strip_redirections) || guard_mark_scan_failed
  if ! printf '%s\n' "${normalized}" | LC_ALL=C awk -v flags="${read_flags}" -v nl=$'\036' '
    # safedeps:extract_pieces (scripts/test/scan-contract.sh keys on this line)
    NR > length(flags) { exit }
    {
      reads = substr(flags, NR, 1) == "1" ? "true" : "false"
      n = split($0, pieces, "[;|&" nl "]")
      for (i = 1; i <= n; i++) printf "%s\t%s\n", reads, pieces[i]
    }'; then
    guard_mark_scan_failed
  fi

  command_payload_texts "$(join_line_continuations "$(strip_heredoc_bodies "${cmd}")")" \
    | guard_strip_redirections | tr ';|&' '\n' | awk '{ printf "false\t%s\n", $0 }' || guard_mark_scan_failed
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
  local seg eco text text_line runner gate_reads

  while IFS=$'\t' read -r gate_reads seg; do
    [[ "${seg}" =~ [^[:space:]] ]] || continue
    command_is_dependency_install "${seg}" || continue
    eco=$(guard_segment_ecosystem "${seg}")
    [[ -n "${eco}" ]] || continue
    runner=false
    guard_segment_is_runner "${seg}" && runner=true
    text=$(guard_extract_statement_text "${eco}" "${seg}" "${runner}")
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

LEDGER_ECOSYSTEM=$(guard_detect_ecosystem "${COMMAND}")
LEDGER_SPECS=()
# The extractor's one reading of the command. The gate keeps its spec lines;
# the UNGATED record walks the whole reading (guard_names_package_without_spec),
# so the two never parse the same statement twice or differently.
GUARD_READINGS=""
while IFS= read -r ledger_spec_line; do
  [[ -z "${ledger_spec_line}" ]] && continue
  GUARD_READINGS+="${ledger_spec_line}"$'\n'
  case "${ledger_spec_line}" in
    S$'\t'*|G$'\t'*|T$'\t'*|@$'\t'*) continue ;;
  esac
  if [[ ${#LEDGER_SPECS[@]} -gt 0 ]]; then
    for existing_spec_line in "${LEDGER_SPECS[@]}"; do
      [[ "${existing_spec_line}" == "${ledger_spec_line}" ]] && continue 2
    done
  fi
  LEDGER_SPECS+=("${ledger_spec_line}")
done < <(guard_extract_specs "${COMMAND}" "${INSTALL_TARGETS}" readings)

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
if [[ "${HIDDEN_DEPENDENCY_INSTALL}" != "true" && -n "${LEDGER_ECOSYSTEM}" ]] \
    && guard_names_package_without_spec; then
  log_advisory "pre-guard UNGATED: ${LEDGER_ECOSYSTEM} install names a package with no version spec, so the ledger gate did not run. No effect gate reads the result of this install, so it is unverified. Unpinned: ${UNGATED_OPERANDS}. Command: ${COMMAND}"
fi

if [[ "${HIDDEN_DEPENDENCY_INSTALL}" == "true" && ( -z "${LEDGER_ECOSYSTEM}" || ${#LEDGER_SPECS[@]} -eq 0 ) ]]; then
  log_advisory "pre-guard DENY: hidden dependency install could not be reduced to an approved spec — fail-closed."
  jq -nc '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:"safedeps: hidden dependency install detected, but no package spec could be extracted for ledger approval — install blocked fail-closed."}}'
  exit 0
fi

# Every verdict from here on allows the command, so this is the last point at
# which a failed scan can still turn into a deny.
guard_settle_scan_failure

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

if ! jq -e 'has("turn_id")' <<< "${INPUT}" >/dev/null 2>&1 && \
   command_is_injectable_npm_install "${COMMAND}" && \
   ! command_has_ignore_scripts_flag "${COMMAND}"; then
  UPDATED_COMMAND=""
  if command_is_compound "${COMMAND}"; then
    # Compound command: insert `--ignore-scripts` immediately AFTER each npm-install
    # verb so the flag stays inside its own statement. Appending to the end of the
    # whole string would land it on the trailing statement (e.g.
    # `npm install evil && npm run build --ignore-scripts`), leaving the install
    # itself running lifecycle scripts (finding #7). `npm install --ignore-scripts <pkg>`
    # is valid npm syntax (flags may precede operands).
    # Groups: 1 = through the verb, 2-4 = the options, 5 = the verb, 6 = what
    # follows it. scripts/test/smoke.sh pins the landing spot.
    UPDATED_COMMAND=$(printf '%s' "${COMMAND}" | sed -E \
      "s/(npm${SAFEDEPS_G_OPTS}[[:space:]]+(${SAFEDEPS_G_NPM_VERBS}))([[:space:]]|\$)/\\1 --ignore-scripts\\6/g")
    if [[ "${UPDATED_COMMAND}" == "${COMMAND}" ]]; then
      # Rewrite did not land — never blind-append to a compound command. Downgrade
      # to detect-and-rollback (the effect gate still verifies the closure) and
      # record it; the inert guarantee is observably relaxed, never silently.
      log_advisory "pre-guard: could not make compound npm install inert in-place; lifecycle scripts may run before the effect gate verifies (downgraded to detect-and-rollback). Command: ${COMMAND}"
      UPDATED_COMMAND=""
    fi
  else
    UPDATED_COMMAND="${COMMAND} --ignore-scripts"
  fi

  if [[ -n "${UPDATED_COMMAND}" ]]; then
    mark_ignore_scripts_injected
    jq -nc --arg command "${UPDATED_COMMAND}" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",updatedInput:{command:$command}}}'
    exit 0
  fi
fi

# Allow the command to proceed — PostToolUse will verify the result
exit 0
