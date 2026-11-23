#!/bin/bash
# safedeps suites on this host, first come first served, up to N at a time.
# The source is scripts/ci/slot.sh in the safedeps repository. A host's copy is
# installed from it by scripts/ci/install-slot.sh, which writes the source's
# path and sha256 on line 2, and edits go to the repository, not the copy.
#
# N is read from ~/safedeps-runs/.slots (default 2; write 1 there to go back to
# one slot, e.g. on battery below 40% with a small charger).
# usage: slot.sh <owner> <command...>
#
# A waiter takes a ticket in ~/safedeps-runs/.queue, named by time, then pid,
# that holds its owner and then its identity. Only a ticket among the first N
# live tickets may take a slot, so a poller cannot jump the queue. Slots are
# the lock dirs ~/safedeps-runs/.slot and .slot2, each holding the holder's
# identity, pid and owner.
#
# A process is its pid and the start the kernel stored when it forked, and
# `running` in native_budget_owners.py answers whether the process a record
# names still runs. That file is installed beside this one, in slot-lib/, or
# read from the repository's scripts/test/lib/. A ticket or a slot is removed
# only when its process is gone on a fact: the kernel has no such pid, it holds
# a zombie, or it holds another start under the pid. A pid the kernel hands out
# again after a reboot is the third fact. A record whose start cannot be read,
# or that has none, is not known, and what is not known stays. So this run does
# not queue when the kernel cannot name it.
B="$HOME/safedeps-runs"; Q="$B/.queue"; owner="$1"; shift
N=$(cat "$B/.slots" 2>/dev/null); case "$N" in 1|2) ;; *) N=2 ;; esac
SLOTS="$B/.slot"; [ "$N" = 2 ] && SLOTS="$B/.slot $B/.slot2"
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
for LIB in "$HERE/slot-lib" "$HERE/../test/lib"; do
  [ -f "$LIB/native_budget_owners.py" ] && break
done
# kernel identity <pid>: the identity the kernel holds for pid, empty when it
# gives none. kernel running <pid> <identity>: running, gone or unknown.
kernel() {
  python3 -c 'import sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
import native_budget_owners as owners
if sys.argv[2] == "identity":
    print(owners.identity(int(sys.argv[3])))
else:
    print({True: "running", False: "gone", None: "unknown"}[owners.running({"pid": int(sys.argv[3]), "identity": sys.argv[4]})])' \
    "$LIB" "$@" 2>/dev/null
}
gone() { [ -n "$1" ] && [ "$(kernel running "$1" "$2")" = gone ]; }
ME=$(kernel identity $$)
[ -n "$ME" ] || {
  echo "slot.sh: the kernel gave no start for this run (pid $$, reader $LIB/native_budget_owners.py), so a later process under the same pid could pass for it; not queueing" >&2
  exit 2
}
mkdir -p "$Q"
t="$Q/$(date +%s)-$(printf %07d $$)"
printf '%s\n%s\n' "$owner" "$ME" > "$B/.ticket-$$" && mv "$B/.ticket-$$" "$t"
my_pos() {
  local f p i=0
  for f in $(ls "$Q" 2>/dev/null | sort); do
    if [ "$f" = "${t##*/}" ]; then i=$((i + 1)); echo "$i"; return; fi
    p=$((10#${f##*-}))
    if gone "$p" "$(sed -n 2p "$Q/$f" 2>/dev/null)"; then rm -f "$Q/$f"; else i=$((i + 1)); fi
  done
}
trap 'rm -f "$t" "$B/.ticket-$$"' EXIT
MYL=""; announced=""
while [ -z "$MYL" ]; do
  pos=$(my_pos)
  if [ -n "$pos" ] && [ "$pos" -le "$N" ]; then
    for L in $SLOTS; do
      if mkdir "$L" 2>/dev/null; then
        printf '%s\n' "$ME" > "$L/identity"; echo $$ > "$L/pid"; MYL="$L"; break
      fi
      p=$(cat "$L/pid" 2>/dev/null)
      if gone "$p" "$(cat "$L/identity" 2>/dev/null)"; then rm -rf "$L"; fi
    done
  fi
  [ -n "$MYL" ] && break
  msg="slots busy: $(for L in $SLOTS; do cat "$L/owner" 2>/dev/null; done | tr '\n' ';'); queue position ${pos:-?} of $(ls "$Q" | wc -l | tr -d ' ')"
  [ "$msg" = "$announced" ] || { echo "$msg — $(date +%T)" >&2; announced="$msg"; }
  sleep 10
done
echo "${owner} since $(date +%T)" > "$MYL/owner"
trap 'rm -f "$t"; rm -rf "$MYL"' EXIT
trap 'exit 130' INT TERM
"$@"
