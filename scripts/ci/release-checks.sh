#!/usr/bin/env bash
# safedeps: the release checks that are not test batteries, as one script.
#
#   scripts/ci/release-checks.sh [--install-gitleaks DIR]
#
# Run it from a clone with its full history, on each platform a release is
# tested on (AGENTS.md, Release procedure, step 5). The test run itself is
# scripts/ci/run-on-hosts.sh --release, or `npm run test:release` on the host.
# These steps lived in .github/workflows/ci.yml until the suite moved to our
# own hosts (owner, 2026-10-06); this is now where they are written down.
#
#   1. ShellCheck, at error severity, over the files listed below.
#   2. The secret scan over every commit (`safedeps scan secrets --repo`), with
#      the gitleaks version pinned below.
#   3. The package: no runtime dependencies, and nothing from node_modules, .env
#      or .git in what `npm pack` would publish.
#
# Every step runs, whatever an earlier one answered, and the script exits 1
# when any failed and names them.
#
# The secret scan runs gitleaks, so the gitleaks on PATH must be the pinned
# version. --install-gitleaks DIR downloads the pinned release for this
# platform into DIR, checks its sha256 against the pin, and puts DIR first on
# PATH. Only linux x64 and darwin arm64 are pinned.
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "${ROOT_DIR}" || exit 2

GITLEAKS_VERSION="8.30.1"
GITLEAKS_LINUX_X64_SHA256="551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb"
GITLEAKS_DARWIN_ARM64_SHA256="b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5"

# The files ShellCheck reads: the gate, its libraries and hooks, and the scripts
# that decide whether a run is green. The rest of the tree is error-clean too;
# its remaining warnings are unused variables and intentional literal tildes.
SHELLCHECK_FILES=(
  bin/safedeps
  lib/install-grammar.sh lib/gates/*.sh lib/ledger/*.sh lib/npm/*.sh lib/providers/*.sh
  scripts/safedeps-pre-guard.sh scripts/safedeps-post-verify.sh
  scripts/safedeps-recheck-alert.sh scripts/release-gates.sh
  scripts/test/smoke.sh scripts/test/e2e.sh
  scripts/test/run-all.sh scripts/test/ci-verdict.sh scripts/test/shard-cover.sh scripts/test/lib/shard.sh
  scripts/measure/scan-failure-census.sh scripts/measure/census-shards.sh
  scripts/ci/run-on-hosts.sh scripts/ci/remote.sh scripts/ci/release-checks.sh
)

die() { printf 'release-checks: %s\n' "$1" >&2; exit 2; }

if [[ "${1:-}" == --install-gitleaks ]]; then
  dest="${2:-}"
  [[ -n "${dest}" ]] || die "--install-gitleaks needs a directory"
  case "$(uname -s)/$(uname -m)" in
    Linux/x86_64) asset="linux_x64" sum="${GITLEAKS_LINUX_X64_SHA256}" ;;
    Darwin/arm64) asset="darwin_arm64" sum="${GITLEAKS_DARWIN_ARM64_SHA256}" ;;
    *) die "no gitleaks pin for $(uname -s)/$(uname -m)" ;;
  esac
  mkdir -p "${dest}" || die "cannot create ${dest}"
  tarball=$(mktemp "${TMPDIR:-/tmp}/gitleaks.XXXXXX") || die "cannot create a temporary file"
  curl -sSfL "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_${asset}.tar.gz" \
    -o "${tarball}" || die "cannot download gitleaks ${GITLEAKS_VERSION}"
  if command -v sha256sum >/dev/null 2>&1; then
    got=$(sha256sum "${tarball}" | cut -d' ' -f1)
  else
    got=$(shasum -a 256 "${tarball}" | cut -d' ' -f1)
  fi
  [[ "${got}" == "${sum}" ]] || { rm -f "${tarball}"; die "gitleaks ${asset} has sha256 ${got}, the pin is ${sum}"; }
  tar -xzf "${tarball}" -C "${dest}" gitleaks || die "cannot unpack gitleaks"
  rm -f "${tarball}"
  PATH="$(cd "${dest}" && pwd):${PATH}"
  shift 2
fi
(( $# == 0 )) || die "usage: release-checks.sh [--install-gitleaks DIR]"

failed=()
step() { printf '\n# ---- %s ----\n' "$1"; }

step "shellcheck"
if ! command -v shellcheck >/dev/null 2>&1; then
  printf 'not ok - shellcheck is not on PATH\n'
  failed+=(shellcheck)
else
  shellcheck --version | sed -n 's/^version: /shellcheck /p'
  if shellcheck --severity=error "${SHELLCHECK_FILES[@]}"; then
    printf 'ok - shellcheck finds no error in %d files\n' "${#SHELLCHECK_FILES[@]}"
  else
    printf 'not ok - shellcheck found errors\n'
    failed+=(shellcheck)
  fi
fi

step "secret scan"
if [[ "$(git rev-parse --is-shallow-repository 2>/dev/null)" != false ]]; then
  printf 'not ok - the secret scan needs a clone with its full history (this one is shallow or not a git checkout)\n'
  failed+=(secret-scan)
elif [[ "$(gitleaks version 2>/dev/null | sed 's/^v//')" != "${GITLEAKS_VERSION}" ]]; then
  printf 'not ok - gitleaks on PATH is %s, the pin is %s (--install-gitleaks DIR installs it)\n' \
    "$(gitleaks version 2>/dev/null || printf 'missing')" "${GITLEAKS_VERSION}"
  failed+=(secret-scan)
elif ./bin/safedeps scan secrets --repo; then
  printf 'ok - no secret in any commit (gitleaks %s)\n' "${GITLEAKS_VERSION}"
else
  printf 'not ok - the secret scan failed\n'
  failed+=(secret-scan)
fi

step "package contents"
deps=$(node -e "const p=require('./package.json'); console.log(Object.keys(Object.assign({}, p.dependencies, p.optionalDependencies)).join(' '))") \
  || deps="(package.json could not be read)"
if [[ -n "${deps}" ]]; then
  printf 'not ok - runtime dependencies: %s\n' "${deps}"
  failed+=(package)
fi
pack=$(npm pack --dry-run 2>&1) || { printf 'not ok - npm pack --dry-run failed: %s\n' "$(tail -n 3 <<< "${pack}")"; failed+=(package); }
if grep -Eq 'node_modules|/\.env|/\.git' <<< "${pack}"; then
  printf 'not ok - stray files in the package:\n%s\n' "$(grep -E 'node_modules|/\.env|/\.git' <<< "${pack}")"
  failed+=(package)
fi
case " ${failed[*]-} " in
  *" package "*) ;;
  *) printf 'ok - zero runtime dependencies, and the package holds %s files, none stray\n' \
       "$(sed -n 's/.*total files: *//p' <<< "${pack}")" ;;
esac

printf '\n'
if (( ${#failed[@]} > 0 )); then
  printf '# FAILED: %s\n' "${failed[*]}"
  exit 1
fi
printf '# release checks passed on %s\n' "$(uname -s)/$(uname -m)"
