#!/usr/bin/env bash
# safedeps: build the Rust core into bin/native/<os>-<arch>/safedeps-core.
#
# One build, two callers. A checkout builds its own binary with this script
# (the installer runs it, and so does release step 7 after main moves), and
# the publish job builds the three binaries the package ships with it. No
# binary is committed: the root .gitignore names bin/native/.
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
#   - The binary is the file cargo names in its own report of the build
#     (--message-format=json), never a path this script assumes: with
#     CARGO_TARGET_DIR or build.target-dir set, cargo writes elsewhere, and a
#     file left at the assumed path is an older build.
#   - The new binary is checked before it takes the old one's place, as a
#     file beside it: its header names the target, and where this machine can
#     run it, it prints its version, a stamp of this build's kind, and
#     `stamp --check` says ok. Only then does it replace the old one, by
#     rename, never by writing over it: a hook may be running the old file,
#     and macOS kills a process whose executable was written under it. A
#     check that fails leaves the old binary as it was. A binary for another
#     machine is checked as far as its header and is said to be built and not
#     run.
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
    -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) stop "unknown argument $1 (see --help)" ;;
  esac
  shift
done

[[ -f "${CRATE_DIR}/Cargo.toml" ]] \
  || stop "${CRATE_DIR}/Cargo.toml is not there. An installed package has no source to build from; it ships its binaries. Reinstall the package instead."
command -v cargo >/dev/null 2>&1 \
  || stop "cargo is not on PATH, so the core cannot be built from this checkout. Install Rust (https://rustup.rs), or install the published package, which ships built binaries."
command -v jq >/dev/null 2>&1 \
  || stop "jq is not on PATH. The build reads which file cargo built from cargo's own JSON report, and safedeps' hooks need jq as well."

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

# The first bytes of a binary name its format and its machine: Mach-O 64
# (cf fa ed fe) with the CPU type that follows, or 64-bit ELF (7f 45 4c 46 02)
# with x86-64 (3e 00) as e_machine at byte 18.
header_names() { # <file> <target>
  local head
  head=$(od -An -tx1 -N20 "$1" 2>/dev/null | tr -d ' \n') || return 1
  case "$2" in
    aarch64-apple-darwin) [[ "${head:0:16}" == cffaedfe0c000001 ]] ;;
    x86_64-apple-darwin) [[ "${head:0:16}" == cffaedfe07000001 ]] ;;
    x86_64-unknown-linux-musl) [[ "${head:0:10}" == 7f454c4602 && "${head:36:4}" == 3e00 ]] ;;
    *) return 1 ;;
  esac
}

host=$(host_target) || host=""
[[ -z "${sums}" ]] || : > "${sums}"
for target in "${targets[@]}"; do
  platform=$(platform_of "${target}")
  # The stamp's kind is read by rust/build.rs from this one variable, and only
  # here is it set. The musl target links with the linker the toolchain
  # ships, so the build needs no C toolchain for Linux on a Mac. cargo's
  # report goes to a file; its diagnostics still reach the terminal.
  report=$(mktemp "${TMPDIR:-/tmp}/safedeps-build-core.XXXXXX") || stop "could not make a file for cargo's report"
  if ! ( cd "${CRATE_DIR}" \
      && SAFEDEPS_CORE_BUILD_KIND="${kind}" CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER=rust-lld \
         cargo build --release --locked --offline --target "${target}" --message-format=json-render-diagnostics ) > "${report}"; then
    rm -f "${report}"
    stop "cargo build failed for ${target}. --offline: a crate that had to be fetched fails here. A cross target also needs its standard library (rustup target add ${target})."
  fi
  built=$(jq -r 'select(.reason == "compiler-artifact" and .target.name == "safedeps-core" and (.target.kind | any(. == "bin"))) | .executable // empty' "${report}") \
    || { rm -f "${report}"; stop "cargo's report of the ${target} build could not be read"; }
  rm -f "${report}"
  [[ -n "${built}" && "${built}" != *$'\n'* ]] \
    || stop "cargo's report of the ${target} build does not name one safedeps-core binary (it named: ${built:-none})"
  [[ -f "${built}" ]] || stop "cargo named ${built} as the binary it built for ${target}, and no file is there"

  mkdir -p "${NATIVE_DIR}/${platform}"
  staged=$(mktemp "${NATIVE_DIR}/${platform}/.safedeps-core.XXXXXX") || stop "could not make a file in ${NATIVE_DIR}/${platform}"
  discard() { rm -f "${staged}"; stop "$1 The binary that was at bin/native/${platform}/safedeps-core is as it was."; }
  { cp "${built}" "${staged}" && chmod 755 "${staged}"; } || discard "could not copy ${built} beside the binary."
  header_names "${staged}" "${target}" || discard "${built} does not start with the header of a ${target} binary."
  if [[ "${target}" == "${host}" ]]; then
    version=$("${staged}" version) || discard "the binary built for ${target} does not run."
    stamp=$("${staged}" stamp) || discard "the binary built for ${target} does not print its stamp."
    [[ "${stamp%% *}" == "${kind}" ]] || discard "the binary's stamp says ${stamp%% *}, and this was a ${kind} build."
    check=$("${staged}" stamp --check 2>&1) || discard "the binary's stamp check failed: ${check}"
    [[ "${check}" == ok ]] || discard "the binary's stamp check said: ${check}"
    ran="ran: ${version}, stamp ${stamp}, stamp --check ok"
  else
    ran="built and not run: this machine runs ${host:-a platform safedeps builds nothing for}; its header names ${target}"
  fi
  mv -f "${staged}" "${NATIVE_DIR}/${platform}/safedeps-core" || discard "could not move the checked binary into place."
  digest=$(sha256_of "${NATIVE_DIR}/${platform}/safedeps-core")
  printf 'build-core: bin/native/%s/safedeps-core %s\n' "${platform}" "${digest}"
  printf 'build-core: %s\n' "${ran}"
  [[ -z "${sums}" ]] || printf '%s  %s/safedeps-core\n' "${digest}" "${platform}" >> "${sums}"
done
