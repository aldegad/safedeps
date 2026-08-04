#!/usr/bin/env bash
# safedeps: PreToolUse hook
# Dependency install safety gate with reorg rollback support
# Detects package install commands and snapshots lock files before execution

set -euo pipefail

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

if ! command -v jq >/dev/null 2>&1; then
  # jq is required to parse the hook payload. Without it we cannot read the exact
  # command, so do a best-effort fail-closed: read the raw payload and, if it
  # looks like a dependency install, DENY (an install we cannot verify must not
  # proceed). Non-install commands are allowed — jq absence must not block `ls`.
  # Either branch is recorded in advisory.log; never a silent skip.
  raw_input=$(cat)
  log_advisory "pre-guard: jq missing — gate cannot parse the payload."
  if printf '%s' "${raw_input}" | grep -qiE '(npm|pnpm|yarn|bun)([^"]*)(install|add|dlx)|[^a-z]npx[[:space:]]|pip[0-9]*[[:space:]]+install|poetry[[:space:]]+add|uv[[:space:]]+(add|pip[[:space:]]+install)|pipenv[[:space:]]+install|cargo[[:space:]]+(add|install)|go[[:space:]]+(get|install)|gem[[:space:]]+install|bundle[[:space:]]+add|mvn([^"]*)dependency:get|dotnet[[:space:]]+add[[:space:]]+package'; then
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

  install_pattern='(^|[;&|]+[[:space:]]*)((npm([[:space:]]+--?[a-zA-Z0-9_-]+([=[:space:]][^[:space:]]+)?)?[[:space:]]+(install|i|add|ci|update|up|upgrade))|npx([[:space:]]+--?[a-zA-Z0-9_-]+([=[:space:]][^[:space:]]+)?)?[[:space:]]+(@?[A-Za-z0-9._-])|pnpm([[:space:]]+--?[a-zA-Z0-9_-]+([=[:space:]][^[:space:]]+)?)?[[:space:]]+(add|install|update|up|dlx)|yarn([[:space:]]+--?[a-zA-Z0-9_-]+([=[:space:]][^[:space:]]+)?)?[[:space:]]+(add|install|upgrade|dlx)|bun([[:space:]]+--?[a-zA-Z0-9_-]+([=[:space:]][^[:space:]]+)?)?[[:space:]]+(add|install|i|update|upgrade)|((python3?|py)[[:space:]]+-m[[:space:]]+pip|pip3?)[[:space:]]+install|poetry[[:space:]]+add|uv[[:space:]]+(add|pip[[:space:]]+install)|pipenv[[:space:]]+install|cargo[[:space:]]+(add|install)|go[[:space:]]+(get|install)|gem[[:space:]]+install|bundle[[:space:]]+add|mvn[[:space:]]+dependency:get|dotnet[[:space:]]+add[[:space:]]+package)([[:space:]]|$)'

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

command_scan_text() {
  local input="$1"
  local output=""
  local quote=""
  local char
  local prev=""
  local i

  for ((i = 0; i < ${#input}; i++)); do
    char="${input:i:1}"

    if [[ -z "${quote}" ]]; then
      if [[ "${char}" == "'" ]]; then
        quote="single"
        output="${output} "
      elif [[ "${char}" == '"' ]]; then
        quote="double"
        output="${output} "
      else
        output="${output}${char}"
      fi
    elif [[ "${quote}" == "single" && "${char}" == "'" ]]; then
      quote=""
      output="${output} "
    elif [[ "${quote}" == "double" && "${char}" == '"' && "${prev}" != "\\" ]]; then
      quote=""
      output="${output} "
    else
      output="${output} "
    fi

    prev="${char}"
  done

  printf '%s' "${output}"
}

normalize_install_text() {
  local text="$1"

  for _ in 1 2 3; do
    text=$(printf '%s' "${text}" | sed -E \
      -e 's/^[[:space:]]+//' \
      -e 's#(^|[[:space:];|&])(/[^[:space:];|&]+/)(npm|npx|pnpm|yarn|bun|pip3?|python3?|py|poetry|uv|pipenv|cargo|go|gem|bundle|mvn|dotnet|sh|bash|zsh)([[:space:];|&]|$)#\1\3\4#g' \
      -e 's#(^|[;&|][[:space:]]*)(env[[:space:]]+([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+[[:space:]]+)*|command[[:space:]]+)#\1#g' \
      -e 's#(^|[;&|][[:space:]]*)([A-Za-z_][A-Za-z0-9_]*=[^[:space:]'\''"]*[[:space:]]+)+#\1#g')
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

  manager_pattern='(npm|npx|pnpm|yarn|bun|pip3?|python3?[[:space:]]+-m[[:space:]]+pip|poetry|uv|pipenv|cargo|go|gem|bundle|mvn|dotnet)'
  verb_pattern='(install|i|add|update|up|upgrade|dlx|get|dependency:get|package)'

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

command_candidate_texts() {
  local command="$1"
  local payload

  command=$(strip_heredoc_bodies "${command}")

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

  npm_install_pattern='(^|[;&|]+[[:space:]]*)npm([[:space:]]+--?[a-zA-Z0-9_-]+([=[:space:]][^[:space:]]+)?)?[[:space:]]+(install|i|add|ci|update|up|upgrade)([[:space:]]|$)'

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

SAFEDEPS_SELF_BUDGET_SECONDS="${SAFEDEPS_SELF_BUDGET_SECONDS:-20}"
SAFEDEPS_BUDGET_ENGAGE_BYTES="${SAFEDEPS_BUDGET_ENGAGE_BYTES:-1024}"

# `[0-9]` first because a non-numeric value must not reach the comparison: it
# stays as given and fails closed downstream (its deadline evaluates to zero and
# fires immediately), which is loud and safe rather than quietly permissive.
SAFEDEPS_SELF_BUDGET_CLAMPED_FROM=""
if [[ "${SAFEDEPS_SELF_BUDGET_SECONDS}" =~ ^[0-9]+$ ]] \
  && (( SAFEDEPS_SELF_BUDGET_SECONDS > SAFEDEPS_SELF_BUDGET_MAX_SECONDS )); then
  SAFEDEPS_SELF_BUDGET_CLAMPED_FROM="${SAFEDEPS_SELF_BUDGET_SECONDS}"
  SAFEDEPS_SELF_BUDGET_SECONDS="${SAFEDEPS_SELF_BUDGET_MAX_SECONDS}"
fi

if [[ -z "${SAFEDEPS_BUDGET_CHILD:-}" ]] && (( ${#COMMAND} >= SAFEDEPS_BUDGET_ENGAGE_BYTES )); then
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

  budget_out=$(mktemp "${TMPDIR:-/tmp}/safedeps-budget.XXXXXX")
  budget_err=$(mktemp "${TMPDIR:-/tmp}/safedeps-budget.XXXXXX")

  # Same payload, same script, one env marker so the child judges instead of
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
  SAFEDEPS_BUDGET_CHILD=1 bash "${BASH_SOURCE[0]}" \
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
  # When the budget was clamped, the reason says so. Otherwise the user reads a
  # budget figure they never set and concludes the setting did not take.
  budget_clamp_note=""
  if [[ -n "${SAFEDEPS_SELF_BUDGET_CLAMPED_FROM}" ]]; then
    budget_clamp_note=" Your SAFEDEPS_SELF_BUDGET_SECONDS=${SAFEDEPS_SELF_BUDGET_CLAMPED_FROM} was clamped to the ${SAFEDEPS_SELF_BUDGET_MAX_SECONDS}s ceiling: above it the ${SAFEDEPS_RUNTIME_BUDGET_SECONDS}s runtime hook budget kills this gate mid-judgment and the install runs unjudged, so raising it removes the check rather than extending it."
  fi
  jq -nc --arg budget "${SAFEDEPS_SELF_BUDGET_SECONDS}" --arg size "${#COMMAND}" --arg clamp "${budget_clamp_note}" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:("safedeps: UNDECIDED, not unsafe — safedeps could not finish judging this command within its " + $budget + "s budget (" + $size + " bytes of command text), so it is blocked fail-closed. Nothing was detected in it; the gate simply did not get to an answer, and an install it cannot judge must not run. Scan cost grows with command length. Split the command, or write long content with a file-writing tool instead of one very large shell command, and retry." + $clamp)}}'
  exit 0
fi

HIDDEN_DEPENDENCY_INSTALL=false
if ! command_is_dependency_install "${COMMAND}"; then
  # Catch indirection patterns that hide install commands (V-002)
  if command_hides_dependency_install "${COMMAND}"; then
    HIDDEN_DEPENDENCY_INSTALL=true
    : # Fall through — treat as install candidate
  else
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
trap 'release_state_lock' EXIT

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

guard_detect_ecosystem() {
  local cmd="$1"
  local scan_cmd

  while IFS= read -r scan_cmd; do
    scan_cmd=$(command_scan_text "${scan_cmd}")
    if echo "${scan_cmd}" | grep -qEi '(^|[;&|]+[[:space:]]*)(npm|pnpm|yarn|npx|bun)([[:space:]]|$)'; then
      printf 'npm'
      return 0
    elif echo "${scan_cmd}" | grep -qEi '(^|[;&|]+[[:space:]]*)(pip3?|poetry|uv|pipenv|((python3?|py)[[:space:]]+-m[[:space:]]+pip))([[:space:]]|$)'; then
      printf 'pypi'
      return 0
    elif echo "${scan_cmd}" | grep -qEi '(^|[;&|]+[[:space:]]*)cargo([[:space:]]|$)'; then
      printf 'crates.io'
      return 0
    elif echo "${scan_cmd}" | grep -qEi '(^|[;&|]+[[:space:]]*)go([[:space:]]|$)'; then
      printf 'go'
      return 0
    elif echo "${scan_cmd}" | grep -qEi '(^|[;&|]+[[:space:]]*)(gem|bundle)([[:space:]]|$)'; then
      printf 'rubygems'
      return 0
    elif echo "${scan_cmd}" | grep -qEi '(^|[;&|]+[[:space:]]*)mvn([[:space:]]|$)'; then
      printf 'maven'
      return 0
    elif echo "${scan_cmd}" | grep -qEi '(^|[;&|]+[[:space:]]*)dotnet([[:space:]]|$)'; then
      printf 'nuget'
      return 0
    fi
  done < <(command_candidate_texts "${cmd}")
  printf ''
}

guard_runner_operands() {
  # Runner forms (`npx`, `pnpm dlx`, `yarn dlx`) EXECUTE a package; tokens after
  # the executed package are arguments to that program, NOT package specs. Emit
  # only the spec-bearing operands: any `-p/--package <pkg>` value plus the first
  # bare token (the executed package). This stops an argument such as an email
  # (`ops@example.test`) or a secret value passed to `npx wrangler ...` from being
  # misread as a `pkg@spec` install.
  local scan="$1"
  local after want_value tok
  after=$(printf '%s' "${scan}" | grep -oiE '(npx|dlx)[[:space:]].*' | head -n1 || true)
  after="${after#* }"  # drop the runner keyword, keep its operands
  [[ -z "${after}" ]] && return 0

  want_value=false
  for tok in ${after}; do
    if [[ "${want_value}" == true ]]; then
      printf '%s\n' "${tok}"
      want_value=false
      continue
    fi
    case "${tok}" in
      -p|--package) want_value=true ;;
      --package=*)  printf '%s\n' "${tok#--package=}" ;;
      -*)           : ;;  # other flag (e.g. -y/--yes), skip
      *)
        printf '%s\n' "${tok}"  # executed package; rest are program args
        break
        ;;
    esac
  done
}

guard_names_package_without_spec() {
  # True when an install NAMES a package but carries no version spec, so the
  # ledger gate never ran for it. Used only to make that fact observable — it
  # changes no verdict.
  #
  # The boundary is what keeps this record readable. A record that fires on
  # routine installs becomes background noise, and background noise is the same
  # as no record. So a token is a named package only if it survives three tests,
  # each of which exists because getting it wrong hides a real install:
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
  local cmd="$1"
  local seg tok verb_seen skip_next seg_ecosystem
  local -a toks=()

  while IFS= read -r seg; do
    [[ -z "${seg//[[:space:]]/}" ]] && continue
    command_is_dependency_install "${seg}" || continue

    verb_seen=false
    skip_next=false
    seg_ecosystem=$(guard_detect_ecosystem "${seg}")
    read -ra toks <<< "$(command_scan_text "${seg}")"
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
        case "${tok}" in
          install|i|add|ci|get|up|update|upgrade|dependency:get|package) verb_seen=true ;;
        esac
        continue
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

      # `@` counts as a version delimiter only outside a URL, where it separates
      # a user rather than a version.
      case "${tok}" in
        *://*) : ;;
        *@*|*==*) continue ;;
      esac

      return 0
    done
  done < <(command_candidate_texts "${cmd}" | tr ';|&' '\n')
  return 1
}

guard_extract_flagged_specs() {
  awk '
    {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[A-Za-z][A-Za-z0-9._-]*==[A-Za-z0-9][A-Za-z0-9._+!~-]*$/) {
          split($i, parts, "==")
          print parts[1] "\t" parts[2]
        }

        if ($i == "gem" && $(i + 1) == "install") {
          pkg = $(i + 2)
          for (j = i + 3; j <= NF; j++) {
            if (($j == "-v" || $j == "--version") && $(j + 1) != "") print pkg "\t" $(j + 1)
            if ($j ~ /^--version=/) { sub(/^--version=/, "", $j); print pkg "\t" $j }
          }
        }

        if ($i == "cargo" && $(i + 1) == "add") {
          pkg = $(i + 2)
          for (j = i + 3; j <= NF; j++) {
            if (($j == "--vers" || $j == "--version") && $(j + 1) != "") print pkg "\t" $(j + 1)
            if ($j ~ /^--(vers|version)=/) { sub(/^--(vers|version)=/, "", $j); print pkg "\t" $j }
          }
        }

        if ($i == "dotnet" && $(i + 1) == "add" && $(i + 2) == "package") {
          pkg = $(i + 3)
          for (j = i + 4; j <= NF; j++) {
            if ($j == "--version" && $(j + 1) != "") print pkg "\t" $(j + 1)
            if ($j ~ /^--version=/) { sub(/^--version=/, "", $j); print pkg "\t" $j }
          }
        }
      }
    }
  '
}

guard_extract_specs() {
  # Echo one "pkg<TAB>spec" line per pkg@spec OPERAND genuinely being installed.
  # Handles @scope/name@spec and bare-name@spec. Two precision rules keep
  # non-package "@" tokens from being misread as an install:
  #   1. Runner segments (npx / pnpm dlx / yarn dlx) contribute ONLY their
  #      executed package — trailing tokens are program arguments, not specs
  #      (so `npx wrangler ... ops@example.test` is never read as a spec).
  #   2. Email / host operands (user@domain.tld) are never package specs.
  # Each shell segment is judged independently so a genuine install in one
  # segment is still gated even when another segment just runs a tool via npx.
  local cmd="$1"
  local seg source=""

  while IFS= read -r seg; do
    [[ -z "${seg//[[:space:]]/}" ]] && continue
    if printf '%s' "${seg}" | grep -qEi '(^|[[:space:]])(npx|dlx)([[:space:]]|$)'; then
      source+="$(guard_runner_operands "${seg}")"$'\n'
    elif command_is_dependency_install "${seg}"; then
      # Only a segment that is itself an install command contributes its operands.
      # A non-install segment (an echo / log line, a path, a comment that merely
      # MENTIONS a pkg@version) is data, not an install — extracting its tokens
      # would falsely flag e.g. `echo "bumped left-pad@1.0.0"; npm install`.
      source+="${seg}"$'\n'
    fi
  done < <(command_candidate_texts "${cmd}" | tr ';|&' '\n')

  { printf '%s' "${source}" \
    | grep -oE '(@[a-zA-Z0-9._/-]+/)?[a-zA-Z][a-zA-Z0-9._-]*@[a-zA-Z0-9._^~|<>=*+-]+' || true; } \
    | while IFS= read -r token; do
        # An email / host operand (user@domain.tld) is never a package spec.
        if [[ "${token}" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
          continue
        fi
        local pkg spec
        if [[ "${token}" =~ ^(@[^@]+)@(.+)$ ]]; then
          pkg="${BASH_REMATCH[1]}"
          spec="${BASH_REMATCH[2]}"
        else
          pkg="${token%@*}"
          spec="${token##*@}"
        fi
        printf '%s\t%s\n' "${pkg}" "${spec}"
      done
  printf '%s\n' "${source}" | guard_extract_flagged_specs
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

if [[ -n "${LEDGER_ECOSYSTEM}" && ${#LEDGER_SPECS[@]} -gt 0 ]]; then
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
  if [[ "${LEDGER_ECOSYSTEM}" == "npm" && ! -f "${SAFEDEPS_NPM_CLOSURE_LIB}" ]]; then
    log_advisory "pre-guard DENY: npm closure library missing (${SAFEDEPS_NPM_CLOSURE_LIB}); project-scoped approval cannot be enforced."
    jq -nc '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:"safedeps: the npm closure library is missing, so project-scoped approvals cannot be enforced. Install blocked fail-closed; reinstall safedeps."}}'
    exit 0
  fi
  if [[ "${LEDGER_ECOSYSTEM}" == "npm" ]]; then
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
  for entry in "${LEDGER_SPECS[@]}"; do
    pkg="${entry%%$'\t'*}"
    spec="${entry##*$'\t'}"
    [[ -z "${pkg}" || -z "${spec}" ]] && continue
    if ! safedeps_ledger_check "${LEDGER_ECOSYSTEM}" "${pkg}" "${spec}" "${LEDGER_CONTEXT_HASH}" 2>/dev/null \
        | jq -e '.approved == true' >/dev/null 2>&1; then
      GUARD_BLOCKED_CMDS+=("${SAFEDEPS_INVOKE} check ${LEDGER_ECOSYSTEM} ${pkg}@${spec}")
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
      --arg ecosystem "${LEDGER_ECOSYSTEM}" \
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
# ledger gate above never ran for it. In npm that is not a gap: the effect gate
# reads the resulting lockfile closure and enforces there. In the ecosystems
# where this command gate IS the authority there is nothing behind it, so the
# install proceeds unverified — and until now it did so with no record at all,
# which contradicts the invariant that every bypass must be observable.
#
# This records the fact. It deliberately does NOT deny: refusing every unpinned
# install is a policy change (it would block ordinary `cargo add x` workflows)
# and belongs to the repo owner, not to this gate. The record is what makes that
# decision answerable with evidence instead of guesswork.
if [[ "${HIDDEN_DEPENDENCY_INSTALL}" != "true" && -n "${LEDGER_ECOSYSTEM}" && "${LEDGER_ECOSYSTEM}" != "npm" \
      && ${#LEDGER_SPECS[@]} -eq 0 ]] && guard_names_package_without_spec "${COMMAND}"; then
  log_advisory "pre-guard UNGATED: ${LEDGER_ECOSYSTEM} install names a package with no version spec, so the ledger gate did not run. This ecosystem has no effect gate behind the command gate, so the install is unverified. Command: ${COMMAND}"
fi

if [[ "${HIDDEN_DEPENDENCY_INSTALL}" == "true" && ( -z "${LEDGER_ECOSYSTEM}" || ${#LEDGER_SPECS[@]} -eq 0 ) ]]; then
  log_advisory "pre-guard DENY: hidden dependency install could not be reduced to an approved spec — fail-closed."
  jq -nc '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:"safedeps: hidden dependency install detected, but no package spec could be extracted for ledger approval — install blocked fail-closed."}}'
  exit 0
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
    UPDATED_COMMAND=$(printf '%s' "${COMMAND}" | sed -E \
      's/(npm([[:space:]]+--?[a-zA-Z0-9_-]+([=[:space:]][^[:space:]]+)?)*[[:space:]]+(install|i|add|ci|update|up|upgrade))([[:space:]]|$)/\1 --ignore-scripts\5/g')
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
