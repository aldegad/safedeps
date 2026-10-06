#!/usr/bin/env bash
# safedeps: hook entry shim, the form that runs the Rust core.
#
# NOT REGISTERED YET. The engines run scripts/safedeps-hook-entry.sh, which
# runs the bash hooks. This file takes that name in the change that moves the
# hooks to the core (ARCHITECTURE.md section 14, stage 4), and the bash shim
# and the bash hooks go in the same release. Until then nothing calls it but
# scripts/test/hook-entry.sh. There is no switch between the two: which one
# answers is which file the installer registered, and that is one name.
#
# The contract is the bash shim's. The core exits 0 on every designed path and
# its decisions travel as JSON on stdout; it aborts on a panic. So any other
# exit means the hook is unwell, and this shim turns it into an explained
# exit 2: a deny for PreToolUse, a loud report for PostToolUse. Each way the
# binary can fail to answer has its own sentence:
#
#   no binary for this platform   bash names a machine this install has no
#                                 directory for
#   no binary at all              bin/native is missing: a checkout that was
#                                 never built, or a damaged install
#   the binary is missing         the platform's directory has no safedeps-core
#   the binary cannot run         it lost its exec bit, or the system refused
#                                 to execute it (exit 126)
#   the binary was stopped        a signal: an abort is a panic in the core
#   the binary exited non-zero    a defect in the core
#
# None of them runs the bash hooks instead. Two authorities drift, and a hook
# that quietly answers from the older one is the silent fallback AGENTS.md
# forbids. Nothing in the environment chooses the binary or turns it off.
#
# The platform is read from BASH_VERSINFO[5], the machine bash was built for
# (`arm64-apple-darwin24`, `x86_64-pc-linux-gnu`). Not from OSTYPE and
# HOSTTYPE: bash keeps a value of those it inherits from the environment
# (measured, bash 3.2.57 and 5.2.21), so `OSTYPE=linux` exported on a Mac
# would send this shim to a binary the Mac cannot run. BASH_VERSINFO is
# read-only and bash sets it itself. No process is started to find the binary.
#
# The shim answers for its own stops as the bash shim does: bash exits 128
# (3.2) or 254 (5) when it cannot start a process, both engines read either as
# a non-blocking hook failure, and the EXIT trap turns any exit the shim did
# not choose into an explained exit 2, written with builtins.
set -u

target="${1:-}"
case "${target}" in
  pre|post) ;;
  *) echo "safedeps-hook-entry: usage: safedeps-hook-entry.sh pre|post" >&2; exit 2 ;;
esac

if [ "${target}" = "pre" ]; then
  hook_name="the PreToolUse hook"
  consequence="Bash tool calls on this machine stay blocked fail-closed until it is repaired"
  stop_consequence="this Bash tool call is denied; the next one is judged again"
else
  hook_name="the PostToolUse hook"
  consequence="post-install verification cannot run — treat the last dependency install as unverified"
  stop_consequence="post-install verification did not run — treat the last dependency install as unverified"
fi

answered=0
on_unanswered_exit() {
  local rc=$?
  [ "${answered}" = 1 ] && return
  if [ "${rc}" -eq 128 ] || [ "${rc}" -eq 254 ]; then
    printf 'safedeps: the hook entry for %s could not start a process (bash exits 128 or 254 when fork fails; the machine is likely out of processes for this user). This is transient and says nothing about the install or your work. Consequence: %s.\n' "${hook_name}" "${stop_consequence}" >&2
  else
    printf 'safedeps: the hook entry for %s stopped before it could judge (exit %s). Consequence: %s.\n' "${hook_name}" "${rc}" "${stop_consequence}" >&2
  fi
  exit 2
}
trap on_unanswered_exit EXIT

# Resolve through the ~/.<engine>/skills/safedeps symlink to the physical tree.
# Parameter expansion, not dirname: one fewer process that can fail to start.
case "$0" in
  */*) self_dir="${0%/*}" ;;
  *) self_dir="." ;;
esac
[ -n "${self_dir}" ] || self_dir="/"
entry_dir="$(cd "${self_dir}" && pwd -P)"
repo_root=""
[ -n "${entry_dir}" ] && repo_root="$(cd "${entry_dir}/.." && pwd -P)"

if [ -z "${entry_dir}" ] || [ -z "${repo_root}" ]; then
  printf 'safedeps: the hook entry could not resolve its own directory from %s, so it cannot find the safedeps-core binary. Consequence: %s.\n' "$0" "${stop_consequence}" >&2
  answered=1
  exit 2
fi

# A checkout holds the core's source and builds its own binary; an installed
# package holds only the binaries the publish job built.
if [ -d "${repo_root}/rust" ]; then
  repair="Repair: build it from this checkout with ${repo_root}/scripts/build-core.sh (it needs cargo), from a human terminal — hooks do not run there."
else
  repair="Repair: reinstall the package (npm install -g @aldegad/safedeps, then node ${repo_root}/scripts/install/install-safedeps-hooks.mjs), from a human terminal — hooks do not run there."
fi

explain() {
  printf '%s\n' "safedeps: ${hook_name} cannot answer: $1. safedeps runs from ${repo_root}, so EVERY session on this machine is affected — your session and your project are not broken, and this is not a defect in your own work. Consequence: ${consequence}. ${repair}" >&2
  answered=1
  exit 2
}

machine="${BASH_VERSINFO[5]:-}"
cpu="${machine%%-*}"
case "${machine}" in
  *-darwin*) os=darwin ;;
  *-linux*) os=linux ;;
  *) os="" ;;
esac
case "${cpu}" in
  arm64|aarch64) arch=arm64 ;;
  x86_64|amd64) arch=x64 ;;
  *) arch="" ;;
esac

native_root="${repo_root}/bin/native"
if [ ! -d "${native_root}" ]; then
  explain "this install has no safedeps-core binary at all (${native_root} is missing)"
fi

# What this install does carry, for the sentence that says this platform is
# not among them. A glob, so no process.
carried=""
for candidate in "${native_root}"/*/safedeps-core; do
  [ -e "${candidate}" ] || continue
  candidate="${candidate%/safedeps-core}"
  carried="${carried:+${carried}, }${candidate##*/}"
done

if [ -z "${os}" ] || [ -z "${arch}" ] || [ ! -d "${native_root}/${os}-${arch}" ]; then
  explain "this install has no safedeps-core binary for this platform (bash was built for ${machine:-an unnamed machine}; this install carries: ${carried:-none})"
fi

core="${native_root}/${os}-${arch}/safedeps-core"
if [ ! -e "${core}" ]; then
  explain "the safedeps-core binary is missing (${core})"
fi
if [ ! -f "${core}" ] || [ ! -x "${core}" ]; then
  explain "the safedeps-core binary cannot run: ${core} is not an executable file (its exec bit is gone, or it is not a regular file)"
fi

"${core}" "${target}"
rc=$?
if [ "${rc}" -eq 0 ]; then
  answered=1
  exit 0
fi

# The core exits 0 on every designed path, so any other exit is the hook
# being unwell, never a verdict.
if [ "${rc}" -eq 126 ]; then
  explain "the safedeps-core binary cannot run: the system refused to execute ${core} (exit 126 — a binary for another machine, a damaged file, or a filesystem mounted noexec)"
fi
if [ "${rc}" -eq 127 ]; then
  explain "the safedeps-core binary cannot run: ${core} went missing or is not a program (exit 127)"
fi
if [ "${rc}" -eq 134 ]; then
  explain "the safedeps-core binary aborted (signal 6, exit 134): a panic in the core, which is a defect in safedeps and not a finding about the command"
fi
if [ "${rc}" -gt 128 ]; then
  explain "the safedeps-core binary was stopped by signal $((rc - 128)) (exit ${rc}) before it answered"
fi
explain "the safedeps-core binary ended with exit ${rc}; it exits 0 whenever it has an answer, so this is a defect in safedeps and not a finding about the command"
