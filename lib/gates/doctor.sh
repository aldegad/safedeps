#!/bin/bash
set -euo pipefail

# safedeps doctor — repo security posture check.
#
# Diagnoses whether the per-repo secret-leak lane is set up (.gitleaks policy +
# .githooks/pre-commit + active core.hooksPath + an available scanner), reports
# the global dependency-install gate, and nudges remote repository governance as
# opt-in only. Read-only by default; `--fix` scaffolds the local secret lane
# (hooks init) and activates it (hooks install). It never creates remote
# workflows or mutates branch protection. No-runner branch rules are a safe
# recommendation, but any remote mutation still belongs to the human.
#
# Exit codes: 0 = no gaps in the secret-leak lane, 1 = gaps remain.

GATES_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./repo-profile.sh
source "$GATES_LIB_DIR/repo-profile.sh"

REPO_ROOT=""
FIX=0
JSON_MODE="${SAFEDEPS_JSON_MODE:-0}"

usage() {
  printf 'Usage: safedeps doctor [--root <repo>] [--fix] [--json]\n' >&2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --root) REPO_ROOT="${2:?--root needs a path}"; shift 2 ;;
    --fix) FIX=1; shift ;;
    --json) JSON_MODE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 64 ;;
  esac
done

if [ -z "$REPO_ROOT" ]; then REPO_ROOT="$(pwd)"; fi
REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"

# --- check collection ---------------------------------------------------------
# Each check appends a row: <lane>\t<status>\t<label>\t<remedy>
# status ∈ ok | gap | na
CHECK_ROWS=()
GAPS=0

add_check() {
  local lane="$1" status="$2" label="$3" remedy="${4:-}"
  CHECK_ROWS+=("${lane}"$'\t'"${status}"$'\t'"${label}"$'\t'"${remedy}")
  # The exit code reflects the per-repo secret-leak lane only. The global
  # dependency-install gate is reported (✗) but is a per-machine concern, so it
  # does not gate this repo's posture result.
  if [ "$status" = "gap" ] && [ "$lane" = "secret" ]; then GAPS=$((GAPS + 1)); fi
}

scanner_available() {
  if command -v gitleaks >/dev/null 2>&1; then printf 'gitleaks'; return 0; fi
  if command -v docker >/dev/null 2>&1; then printf 'docker'; return 0; fi
  return 1
}

has_remote_security_workflow() {
  local workflows_dir="$REPO_ROOT/.github/workflows"
  [ -d "$workflows_dir" ] || return 1
  find "$workflows_dir" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) -print0 2>/dev/null \
    | xargs -0 grep -E 'safedeps|gitleaks|npm audit|pnpm audit|yarn audit|bun audit|pip-audit|cargo audit|osv-scanner|trufflehog' >/dev/null 2>&1
}

main_branch_name() {
  local branch
  branch="$(git -C "$REPO_ROOT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)"
  if [ -n "$branch" ]; then printf '%s' "$branch"; return 0; fi
  if git -C "$REPO_ROOT" show-ref --verify --quiet refs/heads/main || git -C "$REPO_ROOT" show-ref --verify --quiet refs/remotes/origin/main; then
    printf 'main'
    return 0
  fi
  if git -C "$REPO_ROOT" show-ref --verify --quiet refs/heads/master || git -C "$REPO_ROOT" show-ref --verify --quiet refs/remotes/origin/master; then
    printf 'master'
    return 0
  fi
  printf 'main'
}

branch_protection_remedy() {
  local branch="$1"
  printf 'no-runner opt-in: require pull requests before updating %s; do not require status checks unless CI cost is accepted' "$branch"
}

required_status_remedy() {
  local branch="$1"
  printf 'cost-bearing opt-in: add a safedeps workflow, then require it before merging %s' "$branch"
}

dependency_gate_root() {
  # The dependency-install gate is installed globally as a skill symlink for
  # whichever engine(s) are present.
  local found=""
  [ -e "$HOME/.claude/skills/safedeps" ] && found="${found:+${found}, }~/.claude/skills/safedeps"
  [ -e "$HOME/.codex/skills/safedeps" ] && found="${found:+${found}, }~/.codex/skills/safedeps"
  printf '%s' "$found"
}

run_checks() {
  CHECK_ROWS=()
  GAPS=0

  local is_git=0
  if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then is_git=1; fi

  local profile="(n/a)"
  if [ "$is_git" = 1 ]; then
    add_check secret ok "git worktree"
    profile="$(safedeps_repo_profile "$REPO_ROOT")"

    local config_path config_label
    config_path="$(safedeps_gitleaks_config "$REPO_ROOT" "$profile")"
    config_label="gitleaks config ($(basename "$config_path"))"
    if [ -f "$config_path" ]; then
      add_check secret ok "$config_label"
    else
      add_check secret gap "$config_label" "safedeps hooks init --root \"$REPO_ROOT\""
    fi

    local hook_file="$REPO_ROOT/.githooks/pre-commit"
    if [ -x "$hook_file" ]; then
      add_check secret ok ".githooks/pre-commit (executable)"
    elif [ -f "$hook_file" ]; then
      add_check secret gap ".githooks/pre-commit (not executable)" "chmod +x \"$hook_file\""
    else
      add_check secret gap ".githooks/pre-commit (present)" "safedeps hooks init --root \"$REPO_ROOT\""
    fi

    local hooks_path
    hooks_path="$(git -C "$REPO_ROOT" config --get core.hooksPath || true)"
    if [ "$hooks_path" = ".githooks" ]; then
      add_check secret ok "git hooks active (core.hooksPath=.githooks)"
    else
      add_check secret gap "git hooks active (core.hooksPath=${hooks_path:-<unset>})" "safedeps hooks install --root \"$REPO_ROOT\""
    fi
  else
    add_check secret na "git worktree (secret lane needs git)"
  fi

  local scanner
  if scanner="$(scanner_available)"; then
    add_check secret ok "secret scanner available (${scanner})"
  else
    add_check secret gap "secret scanner available (gitleaks or docker)" "brew install gitleaks"
  fi

  local gate_root
  gate_root="$(dependency_gate_root)"
  if [ -n "$gate_root" ]; then
    add_check deps ok "dependency-install gate installed (${gate_root})"
  else
    add_check deps gap "dependency-install gate installed" "node scripts/install/install-safedeps-hooks.mjs"
  fi

  if [ "$is_git" = 1 ]; then
    local default_branch
    default_branch="$(main_branch_name)"
    if has_remote_security_workflow; then
      add_check remote ok "remote security workflow detected (.github/workflows)"
    else
      add_check remote gap "remote PR security workflow (opt-in; may spend CI minutes)" "safedeps gates run --root \"$REPO_ROOT\" --strict"
    fi
    # Remote settings are intentionally not auto-queried or auto-mutated.
    # A branch/ruleset that blocks direct pushes to the default branch does not
    # spend runner minutes by itself, so it is a recommended no-runner posture.
    # Required status checks are separate: once backed by hosted workflows, they
    # can spend CI minutes and remain explicit cost-bearing opt-in.
    add_check remote na "main direct-push protection for ${default_branch} (no runner minutes; opt-in)" "$(branch_protection_remedy "$default_branch")"
    add_check remote na "required PR status checks for ${default_branch} (CI-cost opt-in)" "$(required_status_remedy "$default_branch")"
  else
    add_check remote na "remote repository governance (needs git remote)"
  fi

  DOCTOR_PROFILE="$profile"
}

emit_human() {
  local sym
  printf 'safedeps doctor — repo security posture\n'
  printf 'repo:    %s\n' "$REPO_ROOT"
  printf 'profile: %s\n\n' "$DOCTOR_PROFILE"

  printf 'Secret-leak lane (per-repo)\n'
  local row lane status label remedy
  for row in "${CHECK_ROWS[@]}"; do
    IFS=$'\t' read -r lane status label remedy <<< "$row"
    [ "$lane" = "secret" ] || continue
    case "$status" in
      ok) sym='✓' ;;
      gap) sym='✗' ;;
      *) sym='–' ;;
    esac
    if [ "$status" = "gap" ] && [ -n "$remedy" ]; then
      printf '  %s %-44s → %s\n' "$sym" "$label" "$remedy"
    else
      printf '  %s %s\n' "$sym" "$label"
    fi
  done

  printf '\nDependency-install gate (global, all repos)\n'
  for row in "${CHECK_ROWS[@]}"; do
    IFS=$'\t' read -r lane status label remedy <<< "$row"
    [ "$lane" = "deps" ] || continue
    case "$status" in
      ok) sym='✓' ;;
      gap) sym='✗' ;;
      *) sym='–' ;;
    esac
    if [ "$status" = "gap" ] && [ -n "$remedy" ]; then
      printf '  %s %-44s → %s\n' "$sym" "$label" "$remedy"
    else
      printf '  %s %s\n' "$sym" "$label"
    fi
  done

  printf '\nRemote repository governance (opt-in; no-runner vs CI-cost)\n'
  for row in "${CHECK_ROWS[@]}"; do
    IFS=$'\t' read -r lane status label remedy <<< "$row"
    [ "$lane" = "remote" ] || continue
    case "$status" in
      ok) sym='✓' ;;
      gap) sym='!' ;;
      *) sym='–' ;;
    esac
    if { [ "$status" = "gap" ] || [ "$status" = "na" ]; } && [ -n "$remedy" ]; then
      printf '  %s %-58s → %s\n' "$sym" "$label" "$remedy"
    else
      printf '  %s %s\n' "$sym" "$label"
    fi
  done

  printf '\n'
  if [ "$GAPS" -eq 0 ]; then
    printf 'No gaps in the secret-leak lane. The agent is on guard.\n'
  else
    printf '%d gap(s) in the secret-leak lane.\n' "$GAPS"
    printf 'Fix all at once:  safedeps doctor --fix --root "%s"\n' "$REPO_ROOT"
  fi
}

emit_json() {
  local rows_json="[]" row lane status label remedy
  for row in "${CHECK_ROWS[@]}"; do
    IFS=$'\t' read -r lane status label remedy <<< "$row"
    rows_json="$(jq -c \
      --arg lane "$lane" --arg status "$status" --arg label "$label" --arg remedy "$remedy" \
      '. + [{lane:$lane, status:$status, label:$label, remedy:(if ($remedy|length)>0 then $remedy else null end)}]' \
      <<< "$rows_json")"
  done
  jq -nc \
    --arg repo "$REPO_ROOT" \
    --arg profile "$DOCTOR_PROFILE" \
    --argjson gaps "$GAPS" \
    --argjson checks "$rows_json" \
    '{command:"doctor", repo:$repo, profile:$profile, gaps:$gaps, ok:($gaps==0), checks:$checks}'
}

# --- fix pass -----------------------------------------------------------------
if [ "$FIX" -eq 1 ]; then
  if ! git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf 'ERROR: --fix needs a git worktree (the secret lane is git-scoped): %s\n' "$REPO_ROOT" >&2
    exit 1
  fi
  [ "$JSON_MODE" -eq 1 ] || printf 'safedeps doctor --fix: scaffolding + activating the secret-leak lane...\n\n'
  bash "$GATES_LIB_DIR/hooks.sh" init --root "$REPO_ROOT"
  bash "$GATES_LIB_DIR/hooks.sh" install --root "$REPO_ROOT"
  [ "$JSON_MODE" -eq 1 ] || printf '\n'
fi

run_checks

if [ "$JSON_MODE" -eq 1 ]; then
  emit_json
else
  emit_human
fi

[ "$GAPS" -eq 0 ]
