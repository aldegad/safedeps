#!/usr/bin/env bash
set -euo pipefail

ROOT=""
STRICT=0
NO_RUN=0

usage() {
  cat <<'EOF'
Usage: run-release-gates.sh [--root <repo>] [--strict] [--no-run]

Runs release-time security gates for the current repository tree.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --root)
      ROOT="${2:-}"
      shift 2
      ;;
    --strict)
      STRICT=1
      shift
      ;;
    --no-run)
      NO_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 64
      ;;
  esac
done

if [ -z "$ROOT" ]; then
  ROOT="$(pwd)"
fi

if command -v realpath >/dev/null 2>&1; then
  ROOT="$(realpath "$ROOT")"
else
  ROOT="$(cd "$ROOT" && pwd)"
fi

if [ ! -d "$ROOT" ]; then
  printf 'ERROR: repo root does not exist: %s\n' "$ROOT" >&2
  exit 1
fi

cd "$ROOT"

FAILURES=0
WARNINGS=0
RAN=0

section() {
  printf '\n== %s ==\n' "$1"
}

pass() {
  printf 'PASS [%s] %s\n' "$1" "$2"
}

warn() {
  WARNINGS=$((WARNINGS + 1))
  printf 'WARN [%s] %s\n' "$1" "$2" >&2
}

fail() {
  FAILURES=$((FAILURES + 1))
  printf 'FAIL [%s] %s\n' "$1" "$2" >&2
}

strict_or_warn() {
  if [ "$STRICT" -eq 1 ]; then
    fail "$1" "$2"
  else
    warn "$1" "$2"
  fi
}

run_cmd() {
  local gate="$1"
  local desc="$2"
  shift 2

  RAN=$((RAN + 1))
  printf 'RUN  [%s] %s\n' "$gate" "$desc"
  printf 'CMD  [%s] %s\n' "$gate" "$*"

  if [ "$NO_RUN" -eq 1 ]; then
    pass "$gate" "planned only (--no-run)"
    return 0
  fi

  if "$@"; then
    pass "$gate" "$desc"
  else
    fail "$gate" "$desc"
  fi
}

has_file() {
  [ -f "$1" ]
}

has_npm_script() {
  local script_name="$1"
  has_file package.json || return 1
  command -v node >/dev/null 2>&1 || return 1
  node -e '
const fs = require("node:fs");
const pkg = JSON.parse(fs.readFileSync("package.json", "utf8"));
process.exit(pkg.scripts && Object.prototype.hasOwnProperty.call(pkg.scripts, process.argv[1]) ? 0 : 1);
' "$script_name"
}

run_npm_script_if_present() {
  local script_name="$1"
  local gate="$2"
  if has_npm_script "$script_name"; then
    run_cmd "$gate" "npm run $script_name" npm run "$script_name"
    return 0
  fi
  return 1
}

detect_python_surface() {
  find . -maxdepth 3 \
    \( -name 'requirements*.txt' -o -name 'pyproject.toml' -o -name 'poetry.lock' -o -name 'uv.lock' -o -name 'Pipfile.lock' \) \
    -not -path './node_modules/*' \
    -not -path './.git/*' \
    -print
}

detect_requirements_files() {
  find . -maxdepth 3 \
    -name 'requirements*.txt' \
    -not -path './node_modules/*' \
    -not -path './.git/*' \
    -print | sort
}

hook_file_mentions_reorg_guard() {
  local file="$1"
  [ -f "$file" ] || return 1
  grep -q 'safedeps' "$file"
}

safedeps_install_guard_present() {
  [ -d "$HOME/.claude/skills/safedeps" ] && return 0
  [ -d "$HOME/.codex/skills/safedeps" ] && return 0
  hook_file_mentions_reorg_guard "$HOME/.claude/settings.json" && return 0
  hook_file_mentions_reorg_guard "$HOME/.codex/hooks.json" && return 0
  return 1
}

section "repo"
printf 'root: %s\n' "$ROOT"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  pass repo "inside git worktree"
else
  strict_or_warn repo "not inside a git worktree"
fi

if [ -f docs/security-release-gates.md ] || [ -f SECURITY.md ]; then
  pass repo "release/security documentation present"
else
  warn repo "no docs/security-release-gates.md or SECURITY.md"
fi

section "secrets"
if run_npm_script_if_present "security:hooks:check" "secrets"; then
  :
fi
if run_npm_script_if_present "security:scan:worktree" "secrets"; then
  :
elif [ -x scripts/security/run-gitleaks.sh ]; then
  run_cmd secrets "repo gitleaks wrapper" bash scripts/security/run-gitleaks.sh --worktree
elif command -v gitleaks >/dev/null 2>&1 && { [ -f .gitleaks.toml ] || [ -f gitleaks.toml ]; }; then
  config=".gitleaks.toml"
  [ -f "$config" ] || config="gitleaks.toml"
  run_cmd secrets "gitleaks dir scan" gitleaks dir --no-banner --redact --verbose --config "$config" .
else
  strict_or_warn secrets "no gitleaks gate detected"
fi

section "node"
if has_file package.json; then
  pass node "package.json detected"
  if run_npm_script_if_present "security:audit" "node"; then
    :
  elif has_file package-lock.json || has_file npm-shrinkwrap.json; then
    run_cmd node "npm audit --audit-level=moderate" npm audit --audit-level=moderate
  else
    strict_or_warn node "package.json exists but no npm lockfile/audit script was detected"
  fi

  if safedeps_install_guard_present; then
    pass install-guard "safedeps appears installed/configured"
  elif [ "$STRICT" -eq 1 ] || [ "${SECURITY_RELEASE_GATES_REQUIRE_INSTALL_GUARD:-0}" = "1" ]; then
    fail install-guard "npm project has no detectable safedeps install-time guard"
  else
    warn install-guard "safedeps not detected; release gate can continue, install-time guard is separate"
  fi
else
  pass node "no package.json detected"
fi

section "python"
PYTHON_SURFACE="$(detect_python_surface || true)"
if [ -z "$PYTHON_SURFACE" ]; then
  pass python "no Python dependency surface detected"
elif [ -n "${SECURITY_RELEASE_GATES_PYTHON_AUDIT_COMMAND:-}" ]; then
  run_cmd python "custom Python audit command" bash -lc "$SECURITY_RELEASE_GATES_PYTHON_AUDIT_COMMAND"
elif command -v pip-audit >/dev/null 2>&1; then
  REQUIREMENTS="$(detect_requirements_files || true)"
  if [ -n "$REQUIREMENTS" ]; then
    while IFS= read -r requirements_file; do
      [ -n "$requirements_file" ] || continue
      run_cmd python "pip-audit $requirements_file" pip-audit -r "$requirements_file"
    done <<EOF_REQ
$REQUIREMENTS
EOF_REQ
  else
    strict_or_warn python "Python lock/project files detected, but no requirements*.txt or repo-provided Python audit command exists"
  fi
else
  strict_or_warn python "Python dependency files detected, but pip-audit is not installed and no custom audit command was provided"
fi

section "ci"
if find .github/workflows -maxdepth 1 -type f 2>/dev/null | xargs grep -E 'security:|gitleaks|pip-audit|npm audit' >/dev/null 2>&1; then
  pass ci "workflow appears to run security gates"
else
  warn ci "no obvious GitHub security gate workflow detected"
fi

section "summary"
printf 'gates_run=%s warnings=%s failures=%s strict=%s no_run=%s\n' "$RAN" "$WARNINGS" "$FAILURES" "$STRICT" "$NO_RUN"

if [ "$FAILURES" -gt 0 ]; then
  exit 1
fi

exit 0
