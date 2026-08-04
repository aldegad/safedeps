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
set -u

target="${1:-}"
case "${target}" in
  pre)  hook_name="safedeps-pre-guard.sh" ;;
  post) hook_name="safedeps-post-verify.sh" ;;
  *) echo "safedeps-hook-entry: usage: safedeps-hook-entry.sh pre|post" >&2; exit 2 ;;
esac

# Resolve through the ~/.<engine>/skills/safedeps symlink to the physical repo.
entry_dir="$(cd "$(dirname "$0")" && pwd -P)"
repo_root="$(cd "${entry_dir}/.." && pwd -P)"
hook_script="${entry_dir}/${hook_name}"

if [ "${target}" = "pre" ]; then
  consequence="Bash tool calls on this machine stay blocked fail-closed until the file is restored"
else
  consequence="post-install verification cannot run — treat the last dependency install as unverified"
fi

repo_state=""
if [ -e "${repo_root}/.git/MERGE_HEAD" ]; then
  repo_state=" A git merge is in progress in that checkout right now; this is temporary and whoever is merging will clear it within moments."
elif [ -d "${repo_root}/.git/rebase-merge" ] || [ -d "${repo_root}/.git/rebase-apply" ]; then
  repo_state=" A git rebase is in progress in that checkout right now; this is temporary."
fi

explain() {
  local breakage="$1"
  cat >&2 <<EOF
safedeps: the installed hook ${hook_name} ${breakage}. The hook runs live from the repo checkout at ${repo_root}, so EVERY session on this machine is affected — your session and your project are not broken, and this is not a defect in your own work.${repo_state} Consequence: ${consequence}. Recovery: the session merging/editing that repo restores the file (git -C ${repo_root} status; git -C ${repo_root} merge --abort if abandoning), or use a human terminal — hooks do not run there. Do not edit the main checkout from an agent session to fix this.
EOF
  exit 2
}

if [ ! -f "${hook_script}" ]; then
  explain "is missing from the checkout"
fi

bash "${hook_script}"
rc=$?
[ "${rc}" -eq 0 ] && exit 0

# The real hooks exit 0 on every designed path (decisions travel as JSON on
# stdout), so any non-zero exit means the source itself is unwell.
if ! bash -n "${hook_script}" 2>/dev/null; then
  explain "does not parse (syntax error — typically merge conflict markers left mid-merge; exit ${rc})"
fi
explain "crashed with exit ${rc}"
