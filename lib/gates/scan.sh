#!/bin/bash
set -euo pipefail

# safedeps scan secrets — generic gitleaks runner.
# Absorbed from kuma-studio scripts/security/run-gitleaks.sh and made generic:
# repo root comes from --root (default: cwd), config from repo profile or override.
# Preference order: local gitleaks binary -> Docker image (explicit, printed).

GATES_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./repo-profile.sh
source "$GATES_LIB_DIR/repo-profile.sh"

REPO_ROOT=""
MODE="repo"
CONFIG_OVERRIDE=""
IMAGE="${SAFEDEPS_GITLEAKS_IMAGE:-${KUMA_GITLEAKS_IMAGE:-ghcr.io/gitleaks/gitleaks:latest}}"

usage() {
  printf 'Usage: safedeps scan secrets [--repo|--worktree|--staged] [--root <repo>] [--config <path>]\n' >&2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) MODE="repo"; shift ;;
    --worktree) MODE="worktree"; shift ;;
    --staged) MODE="staged"; shift ;;
    --root) REPO_ROOT="${2:?--root needs a path}"; shift 2 ;;
    --config) CONFIG_OVERRIDE="${2:?--config needs a path}"; shift 2 ;;
    secrets) shift ;; # allow `scan secrets ...`
    -h|--help) usage; exit 0 ;;
    *) usage; exit 64 ;;
  esac
done

if [ -z "$REPO_ROOT" ]; then REPO_ROOT="$(pwd)"; fi
REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"

REPO_PROFILE="$(safedeps_repo_profile "$REPO_ROOT")"
if [ -n "$CONFIG_OVERRIDE" ]; then
  CONFIG_PATH="$CONFIG_OVERRIDE"
else
  CONFIG_PATH="$(safedeps_gitleaks_config "$REPO_ROOT" "$REPO_PROFILE")"
fi
CONFIG_BASENAME="$(basename "$CONFIG_PATH")"

cd "$REPO_ROOT"

if [ ! -f "$CONFIG_PATH" ]; then
  printf 'ERROR: gitleaks config does not exist: %s\n' "$CONFIG_PATH" >&2
  exit 1
fi

printf 'safedeps secret scan: profile=%s config=%s mode=%s\n' "$REPO_PROFILE" "$CONFIG_BASENAME" "$MODE" >&2

SCAN_ROOT="$REPO_ROOT"

LOCAL_ARGS=(git --no-banner --redact --verbose --config "$CONFIG_PATH")
DOCKER_ARGS=(git --no-banner --redact --verbose --config "/repo/$CONFIG_BASENAME")

if [ "$MODE" = "staged" ]; then
  LOCAL_ARGS+=(--pre-commit --staged)
  DOCKER_ARGS+=(--pre-commit --staged)
elif [ "$MODE" = "worktree" ]; then
  LOCAL_ARGS=(dir --no-banner --redact --verbose --config "$CONFIG_PATH")
  DOCKER_ARGS=(dir --no-banner --redact --verbose --config "/repo/$CONFIG_BASENAME")
fi

LOCAL_ARGS+=("$SCAN_ROOT")
if [ "$MODE" = "worktree" ]; then
  DOCKER_ARGS+=("/repo")
else
  DOCKER_ARGS+=(/repo)
fi

if command -v gitleaks >/dev/null 2>&1; then
  gitleaks "${LOCAL_ARGS[@]}"
  exit $?
fi

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  docker run --rm -v "$REPO_ROOT:/repo" -w /repo "$IMAGE" "${DOCKER_ARGS[@]}"
  exit $?
fi

cat >&2 <<EOF
ERROR: gitleaks is not available.

Choose one:
1. Install locally: brew install gitleaks
2. Or start Docker so the scan can use: $IMAGE

The scan is blocked (fail-closed) until a scanner is available.
EOF
exit 1
