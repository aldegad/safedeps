#!/usr/bin/env bash
# safedeps: hook entry shim.
#
# The engines run the installed hook path on every Bash tool call, and that
# path resolves through ~/.<engine>/skills/safedeps (a symlink) into the live
# repo checkout. When that checkout is mid-merge or mid-edit, the real hook
# source may not parse. Without this shim the outcome is decided by accidental
# exit codes: a bash syntax error exits 2, which both engines treat as a
# BLOCKING deny with only the raw parser message as explanation, while a
# missing file (127) or a runtime crash (1) is a NON-blocking hook failure —
# the install gate silently vanishes. Neither behavior is designed.
#
# This shim makes the behavior designed. The real hooks always exit 0 and
# speak JSON; any other exit is abnormal. On abnormal exit the shim classifies
# what broke (does not parse / crashed / missing), checks whether a merge or
# rebase is in progress in the repo checkout, and exits 2 with a message that
# names the cause and the recovery path. Fail-closed stays fail-closed — it
# just stops being anonymous, and the fail-open forms stop being silent.
#
# The shim also answers for its own stops. bash ends a script at the first
# process it cannot start -- bash 3.2 at once with exit 128, bash 5 after about
# 15 seconds of retries with exit 254 (both measured) -- and both engines read
# either as a non-blocking hook failure: the tool call runs with no gate. That happens when
# the machine is out of processes, and it once surfaced as "the hook is missing
# from the checkout at /", because the failed fork inside `dirname` left the
# shim resolving its own location to the filesystem root. So the shim finds its
# location without `dirname`, writes with builtins only, and turns any stop it
# did not choose into an explained exit 2 from an EXIT trap.
set -u

target="${1:-}"
case "${target}" in
  pre)  hook_name="safedeps-pre-guard.sh" ;;
  post) hook_name="safedeps-post-verify.sh" ;;
  *) echo "safedeps-hook-entry: usage: safedeps-hook-entry.sh pre|post" >&2; exit 2 ;;
esac

if [ "${target}" = "pre" ]; then
  consequence="Bash tool calls on this machine stay blocked fail-closed until the file is restored"
  stop_consequence="this Bash tool call is denied; the next one is judged again"
else
  consequence="post-install verification cannot run — treat the last dependency install as unverified"
  stop_consequence="post-install verification did not run — treat the last dependency install as unverified"
fi

# Every designed exit sets this first. Anything else is a stop the shim did not
# choose, and the trap answers it as a deny instead of letting the exit code
# decide. printf is a builtin: a trap that needs a process cannot report the
# condition where no process can start.
answered=0
on_unanswered_exit() {
  local rc=$?
  [ "${answered}" = 1 ] && return
  if [ "${rc}" -eq 128 ] || [ "${rc}" -eq 254 ]; then
    printf 'safedeps: the hook entry for %s could not start a process (bash exits 128 or 254 when fork fails; the machine is likely out of processes for this user). This is transient and says nothing about the checkout or your work. Consequence: %s.\n' "${hook_name}" "${stop_consequence}" >&2
  else
    printf 'safedeps: the hook entry for %s stopped before it could judge (exit %s). Consequence: %s.\n' "${hook_name}" "${rc}" "${stop_consequence}" >&2
  fi
  exit 2
}
trap on_unanswered_exit EXIT

# Resolve through the ~/.<engine>/skills/safedeps symlink to the physical repo.
# Parameter expansion, not dirname: one fewer process that can fail to start.
case "$0" in
  */*) self_dir="${0%/*}" ;;
  *) self_dir="." ;;
esac
[ -n "${self_dir}" ] || self_dir="/"
entry_dir="$(cd "${self_dir}" && pwd -P)"
repo_root=""
[ -n "${entry_dir}" ] && repo_root="$(cd "${entry_dir}/.." && pwd -P)"
hook_script="${entry_dir}/${hook_name}"

repo_state=""
if [ -e "${repo_root}/.git/MERGE_HEAD" ]; then
  repo_state=" A git merge is in progress in that checkout right now; this is temporary and whoever is merging will clear it within moments."
elif [ -d "${repo_root}/.git/rebase-merge" ] || [ -d "${repo_root}/.git/rebase-apply" ]; then
  repo_state=" A git rebase is in progress in that checkout right now; this is temporary."
fi

explain() {
  local breakage="$1"
  printf '%s\n' "safedeps: the installed hook ${hook_name} ${breakage}. The hook runs live from the repo checkout at ${repo_root}, so EVERY session on this machine is affected — your session and your project are not broken, and this is not a defect in your own work.${repo_state} Consequence: ${consequence}. Recovery: the session merging/editing that repo restores the file (git -C ${repo_root} status; git -C ${repo_root} merge --abort if abandoning), or use a human terminal — hooks do not run there. Do not edit the main checkout from an agent session to fix this." >&2
  answered=1
  exit 2
}

# A location that did not resolve is not a missing file. "Missing from the
# checkout at /" sent people looking in the wrong place.
if [ -z "${entry_dir}" ] || [ -z "${repo_root}" ]; then
  printf 'safedeps: the hook entry could not resolve its own directory from %s, so it cannot find %s. Consequence: %s.\n' "$0" "${hook_name}" "${stop_consequence}" >&2
  answered=1
  exit 2
fi

if [ ! -f "${hook_script}" ]; then
  explain "is missing from the checkout"
fi

bash "${hook_script}"
rc=$?
if [ "${rc}" -eq 0 ]; then
  answered=1
  exit 0
fi

# The real hooks exit 0 on every designed path (decisions travel as JSON on
# stdout), so any non-zero exit means the source itself is unwell.
if ! bash -n "${hook_script}" 2>/dev/null; then
  explain "does not parse (syntax error — typically merge conflict markers left mid-merge; exit ${rc})"
fi
if [ "${rc}" -eq 128 ] || [ "${rc}" -eq 254 ]; then
  explain "stopped with exit ${rc} — bash exits 128 or 254 when it cannot start a process, so a machine that was out of processes a moment ago is the likely cause; the file itself parses"
fi
explain "crashed with exit ${rc}"
