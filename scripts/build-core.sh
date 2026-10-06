#!/usr/bin/env bash
# safedeps: build the Rust core into bin/native/<os>-<arch>/safedeps-core.
#
# One build, two callers. A checkout builds its own binary with this script
# (the installer runs it, and so does release step 7 after main moves), and
# the publish job builds the three binaries the package ships with it. No
# binary is committed: bin/native/ is ignored by git.
#
#   scripts/build-core.sh                    this machine's binary, from this
#                                            checkout's source
#   scripts/build-core.sh --target <triple>  that target's binary; repeatable
#   scripts/build-core.sh --publish ...      the publish job's build (below)
#   scripts/build-core.sh --sums <file>      also write `<sha256>  <dir>/safedeps-core`
#                                            per binary built, for a later
#                                            read-back
#
# What every build holds:
#
#   - The crate names no dependency. Cargo.lock lists one package, the crate
#     itself, and the build runs --locked --offline, so a dependency someone
#     adds fails here rather than being fetched.
#   - The binary carries a stamp (rust/build.rs): the kind of build and the
#     sha256 of the source it was built from (rust/Cargo.toml, Cargo.lock,
#     build.rs and src/**/*.rs). A checkout's binary checks that stamp against
#     the checkout's source when a hook starts, and does not judge from a
#     source it was not built from. --locked matters for that too: a cargo
#     that rewrote Cargo.lock would change the hash under the binary.
#   - The binary replaces the old one by rename, never by writing over it: a
#     hook may be running the old file, and macOS kills a process whose
#     executable was written under it.
#
# --publish marks the stamp `publish`. Such a binary ships in a package that
# has no rust/ directory, so it has no source to check itself against and does
# not look for one. The mark is fixed when the binary is built, here, by the
# publish job; nothing at run time can set it. A checkout never builds with
# --publish: its binary would stop noticing that the source moved.
#
# The toolchain is whatever `cargo` is on PATH. The publish job pins it; a
# checkout's is the developer's.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
CRATE_DIR="${ROOT_DIR}/rust"
NATIVE_DIR="${ROOT_DIR}/bin/native"

stop() { printf 'build-core: %s\n' "$1" >&2; exit 1; }

# The platform directory of a target triple. A closed table: the shim finds a
# binary by these names (scripts/safedeps-hook-entry-native.sh), so a target
# that is not here has no directory the shim would look in.
platform_of() {
  case "$1" in
    aarch64-apple-darwin) printf 'darwin-arm64' ;;
    x86_64-apple-darwin) printf 'darwin-x64' ;;
    x86_64-unknown-linux-musl) printf 'linux-x64' ;;
    *) return 1 ;;
  esac
}

# This machine's target, read from bash the way the shim reads its platform.
host_target() {
  local machine="${BASH_VERSINFO[5]:-}" cpu
  cpu="${machine%%-*}"
  case "${machine}" in
    *-darwin*)
      case "${cpu}" in
        arm64|aarch64) printf 'aarch64-apple-darwin' ;;
        x86_64) printf 'x86_64-apple-darwin' ;;
        *) return 1 ;;
      esac ;;
    *-linux*)
      case "${cpu}" in
        x86_64|amd64) printf 'x86_64-unknown-linux-musl' ;;
        *) return 1 ;;
      esac ;;
    *) return 1 ;;
  esac
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

kind=checkout
sums=""
targets=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --publish) kind=publish ;;
    --target)
      [[ $# -ge 2 ]] || stop "--target needs a target triple"
      platform_of "$2" >/dev/null || stop "no platform directory for the target $2 (known: aarch64-apple-darwin, x86_64-apple-darwin, x86_64-unknown-linux-musl)"
      targets+=("$2")
      shift ;;
    --sums)
      [[ $# -ge 2 ]] || stop "--sums needs a file"
      sums="$2"
      shift ;;
    -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) stop "unknown argument $1 (see --help)" ;;
  esac
  shift
done

[[ -f "${CRATE_DIR}/Cargo.toml" ]] \
  || stop "${CRATE_DIR}/Cargo.toml is not there. An installed package has no source to build from; it ships its binaries. Reinstall the package instead."
command -v cargo >/dev/null 2>&1 \
  || stop "cargo is not on PATH, so the core cannot be built from this checkout. Install Rust (https://rustup.rs), or install the published package, which ships built binaries."

if [[ ${#targets[@]} -eq 0 ]]; then
  host=$(host_target) || stop "bash reports ${BASH_VERSINFO[5]:-no machine}, and safedeps builds no binary for it (darwin-arm64, darwin-x64, linux-x64)"
  targets=("${host}")
fi

# No dependency of any kind: the lockfile lists every package a build would
# use, and it lists one.
[[ -f "${CRATE_DIR}/Cargo.lock" ]] || stop "${CRATE_DIR}/Cargo.lock is not there; the build is --locked"
packages=$(grep -c '^\[\[package\]\]' "${CRATE_DIR}/Cargo.lock" || true)
[[ "${packages}" == 1 ]] \
  || stop "rust/Cargo.lock lists ${packages} packages. The core has no dependencies (AGENTS.md); it lists one, the crate itself."

printf 'build-core: %s, %s\n' "$(cargo --version)" "$(rustc --version 2>/dev/null || printf 'rustc did not answer')"
printf 'build-core: a %s build for %s\n' "${kind}" "${targets[*]}"

[[ -z "${sums}" ]] || : > "${sums}"
for target in "${targets[@]}"; do
  platform=$(platform_of "${target}")
  # The stamp's kind is read by rust/build.rs from this one variable, and only
  # here is it set. The musl target links with the linker the toolchain
  # ships, so the build needs no C toolchain for Linux on a Mac.
  ( cd "${CRATE_DIR}" \
      && SAFEDEPS_CORE_BUILD_KIND="${kind}" CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER=rust-lld \
         cargo build --release --locked --offline --target "${target}" ) \
    || stop "cargo build failed for ${target}. --offline: a crate that had to be fetched fails here. A cross target also needs its standard library (rustup target add ${target})."
  built="${CRATE_DIR}/target/${target}/release/safedeps-core"
  [[ -f "${built}" ]] || stop "cargo left no binary at ${built}"
  mkdir -p "${NATIVE_DIR}/${platform}"
  staged=$(mktemp "${NATIVE_DIR}/${platform}/.safedeps-core.XXXXXX")
  if ! { cp "${built}" "${staged}" && chmod 755 "${staged}" && mv -f "${staged}" "${NATIVE_DIR}/${platform}/safedeps-core"; }; then
    rm -f "${staged}"
    stop "could not place the binary in ${NATIVE_DIR}/${platform}"
  fi
  digest=$(sha256_of "${NATIVE_DIR}/${platform}/safedeps-core")
  printf 'build-core: bin/native/%s/safedeps-core %s\n' "${platform}" "${digest}"
  [[ -z "${sums}" ]] || printf '%s  %s/safedeps-core\n' "${digest}" "${platform}" >> "${sums}"
done

# Read back the binary this machine can run: its version, its stamp, and for
# a checkout build that the stamp is the source it was just built from.
if host=$(host_target) && host_platform=$(platform_of "${host}") && [[ " ${targets[*]} " == *" ${host} "* ]]; then
  core="${NATIVE_DIR}/${host_platform}/safedeps-core"
  version=$("${core}" version) || stop "the built binary does not run: ${core}"
  stamp=$("${core}" stamp) || stop "the built binary does not print its stamp: ${core}"
  printf 'build-core: %s, stamp %s\n' "${version}" "${stamp}"
  [[ "${stamp%% *}" == "${kind}" ]] || stop "the binary's stamp says ${stamp%% *}, and this was a ${kind} build"
  if [[ "${kind}" == checkout ]]; then
    check=$("${core}" stamp --check 2>&1) || stop "the built binary does not match the source it was built from: ${check}"
    [[ "${check}" == ok ]] || stop "the built binary's stamp check said: ${check}"
    printf 'build-core: the stamp matches rust/ as it is now\n'
  fi
else
  printf 'build-core: no binary for this machine was built, so none was run\n'
fi
