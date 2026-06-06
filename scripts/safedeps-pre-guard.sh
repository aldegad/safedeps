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

command_is_dependency_install() {
  local command="$1"
  local scan_command
  local install_pattern

  install_pattern='(^|[;&|]+[[:space:]]*)((npm([[:space:]]+--?[a-zA-Z0-9_-]+([=[:space:]][^[:space:]]+)?)?[[:space:]]+(install|i|add|ci|update|up|upgrade))|npx[[:space:]]|pnpm([[:space:]]+--?[a-zA-Z0-9_-]+([=[:space:]][^[:space:]]+)?)?[[:space:]]+(add|install|update|up|dlx)|yarn([[:space:]]+--?[a-zA-Z0-9_-]+([=[:space:]][^[:space:]]+)?)?[[:space:]]+(add|install|upgrade|dlx)|((python3?|py)[[:space:]]+-m[[:space:]]+pip|pip3?)[[:space:]]+install|poetry[[:space:]]+add|uv[[:space:]]+(add|pip[[:space:]]+install)|pipenv[[:space:]]+install|cargo[[:space:]]+(add|install)|go[[:space:]]+(get|install)|gem[[:space:]]+install|bundle[[:space:]]+add|mvn[[:space:]]+dependency:get|dotnet[[:space:]]+add[[:space:]]+package)([[:space:]]|$)'

  while IFS= read -r scan_command; do
    scan_command=$(command_scan_text "${scan_command}")
    echo "${scan_command}" | grep -qEi "${install_pattern}" && return 0
  done < <(command_candidate_texts "${command}")
  return 1
}

command_hides_dependency_install() {
  local command="$1"
  local manager_pattern
  local verb_pattern

  manager_pattern='(npm|npx|pnpm|yarn|pip3?|python3?[[:space:]]+-m[[:space:]]+pip|poetry|uv|pipenv|cargo|go|gem|bundle|mvn|dotnet)'
  verb_pattern='(install|i|add|update|up|upgrade|dlx|get|dependency:get|package)'

  echo "${command}" | grep -qEi '(eval[[:space:]]|\$\(|`|(^|[[:space:];|&])(bash|sh|zsh)[[:space:]]+-[A-Za-z]*c[[:space:]])' && \
    echo "${command}" | grep -qEi "${manager_pattern}.*${verb_pattern}"
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
      -e 's#(^|[[:space:];|&])(/[^[:space:];|&]+/)(npm|npx|pnpm|yarn|pip3?|python3?|py|poetry|uv|pipenv|cargo|go|gem|bundle|mvn|dotnet)([[:space:];|&]|$)#\1\3\4#g' \
      -e 's#(^|[;&|][[:space:]]*)(env[[:space:]]+([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+[[:space:]]+)*|command[[:space:]]+)#\1#g')
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

if ! command_is_dependency_install "${COMMAND}"; then
  # Catch indirection patterns that hide install commands (V-002)
  if command_hides_dependency_install "${COMMAND}"; then
    : # Fall through — treat as install candidate
  else
    exit 0
  fi
fi

# --- Reorg Guard Activated ---

# Find lock files in common locations
# Per Claude Code / Codex CLI hook spec, `cwd` is top-level. Fall back to `pwd`
# only when the hook is invoked outside the engine (manual test, no stdin payload).
PROJECT_DIR=$(echo "${INPUT}" | jq -r '.cwd // empty' 2>/dev/null)
if [[ -z "${PROJECT_DIR}" ]]; then
  PROJECT_DIR=$(pwd)
fi

# Canonicalize to prevent path traversal (V-003)
if command -v realpath >/dev/null 2>&1; then
  PROJECT_DIR=$(realpath "${PROJECT_DIR}" 2>/dev/null || echo "${PROJECT_DIR}")
elif command -v readlink >/dev/null 2>&1; then
  PROJECT_DIR=$(readlink -f "${PROJECT_DIR}" 2>/dev/null || echo "${PROJECT_DIR}")
fi

TIMESTAMP=$(date +%s)
DIR_HASH=$(compute_dir_hash "${PROJECT_DIR}")
SNAPSHOT_ID="${TIMESTAMP}_${DIR_HASH}"

acquire_state_lock
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
SAFEDEPS_REPO_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/safedeps"

guard_detect_ecosystem() {
  local cmd="$1"
  local scan_cmd

  while IFS= read -r scan_cmd; do
    scan_cmd=$(command_scan_text "${scan_cmd}")
    if echo "${scan_cmd}" | grep -qEi '(^|[;&|]+[[:space:]]*)(npm|pnpm|yarn|npx)([[:space:]]|$)'; then
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
  # (`dev1@block-s.io`) or a secret value passed to `npx wrangler ...` from being
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
  #      (so `npx wrangler ... dev1@block-s.io` is never read as a spec).
  #   2. Email / host operands (user@domain.tld) are never package specs.
  # Each shell segment is judged independently so a genuine install in one
  # segment is still gated even when another segment just runs a tool via npx.
  local cmd="$1"
  local seg source=""

  while IFS= read -r seg; do
    [[ -z "${seg//[[:space:]]/}" ]] && continue
    if printf '%s' "${seg}" | grep -qEi '(^|[[:space:]])(npx|dlx)([[:space:]]|$)'; then
      source+="$(guard_runner_operands "${seg}")"$'\n'
    else
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
    if ! safedeps_ledger_check "${LEDGER_ECOSYSTEM}" "${pkg}" "${spec}" 2>/dev/null \
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
    exit 0
  fi
fi

# Write current state atomically for PostToolUse (V-004: single file prevents TOCTOU)
CURRENT_STATE=$(jq -n --arg sid "${SNAPSHOT_ID}" --arg pdir "${PROJECT_DIR}" --arg dhash "${DIR_HASH}" \
  '{snapshot_id: $sid, project_dir: $pdir, dir_hash: $dhash}')
write_state_file "${GUARD_DIR}/current_state" "${CURRENT_STATE}"

if ! jq -e 'has("turn_id")' <<< "${INPUT}" >/dev/null 2>&1 && \
   command_is_injectable_npm_install "${COMMAND}" && \
   ! command_has_ignore_scripts_flag "${COMMAND}"; then
  UPDATED_COMMAND="${COMMAND} --ignore-scripts"
  mark_ignore_scripts_injected
  jq -nc --arg command "${UPDATED_COMMAND}" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",updatedInput:{command:$command}}}'
  exit 0
fi

# Allow the command to proceed — PostToolUse will verify the result
exit 0
