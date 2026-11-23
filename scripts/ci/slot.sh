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
# again after a reboot is the third fact. A record with no start that can be
# read is gone only on the first two, and what is not known stays. So this run
# does not queue when the kernel cannot name it.
#
# A value a verdict rests on is used only when every step that made it ended
# 0: where the reader is, N, this run's start, the clock, this run's ticket,
# the queue's list and its order, a record, the kernel's answer, and the record
# of the slot this run takes. A step that fails gives nothing, even after it
# printed part of an answer. So a pipeline fails when any of its commands
# fails, and each such value is a plain assignment whose status is read where it
# is made, never a substitution inside a word or a list. Before this run holds
# a ticket, a value it cannot know means it does not queue (exit 2); after, it
# waits and looks again. A ticket whose start cannot be read is judged on its
# pid, which is its name, alone, and a name that holds no pid is a ticket whose
# process is not known. A slot whose pid cannot be read stays, and a slot whose
# record this run cannot write is given back.
set -o pipefail
B="$HOME/safedeps-runs"; Q="$B/.queue"; owner="$1"; shift
nl=$'\n'
refuse() { echo "slot.sh: $1; not queueing" >&2; exit 2; }
src=$(dirname "${BASH_SOURCE[0]}") && HERE=$(cd "$src" && pwd) ||
  refuse "its own directory could not be read, so the reader beside it is not known"
LIB=""
for dir in "$HERE/slot-lib" "$HERE/../test/lib"; do
  [ -f "$dir/native_budget_owners.py" ] && { LIB=$dir; break; }
done
[ -n "$LIB" ] || refuse "no native_budget_owners.py in $HERE/slot-lib or $HERE/../test/lib"
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
# gone <pid> <identity>: whether the record's process is gone on a fact. A pid
# that is not a number names no process.
gone() {
  local said
  case "$1" in ''|0*|*[!0-9]*) return 1 ;; esac
  said=$(kernel running "$1" "$2") && [ "$said" = gone ]
}
ME=$(kernel identity $$) && [ -n "$ME" ] ||
  refuse "the kernel gave no start for this run (pid $$, reader $LIB/native_budget_owners.py), so a later process under the same pid could pass for it"
now=$(date +%s) || now=""
case "$now" in ''|*[!0-9]*)
  refuse "the clock gave no time for this run's ticket, so its place in the queue is not known" ;;
esac
mkdir -p "$Q" || refuse "the queue $Q could not be made"
# N is 2 when a list of the runs directory holds no .slots, and what .slots
# holds when it is there.
listing=$(ls -A "$B" 2>/dev/null) ||
  refuse "$B could not be listed, so whether it holds .slots is not known"
case "$nl$listing$nl" in
  *"$nl.slots$nl"*) N=$(cat "$B/.slots" 2>/dev/null) || refuse "$B/.slots could not be read, so N is not known" ;;
  *) N=2 ;;
esac
case "$N" in 1|2) ;; *) N=2 ;; esac
SLOTS="$B/.slot"; [ "$N" = 2 ] && SLOTS="$B/.slot $B/.slot2"
printf -v t '%s/%s-%07d' "$Q" "$now" "$$" || refuse "the name of this run's ticket could not be made"
trap 'rm -f "$t" "$B/.ticket-$$"' EXIT
printf '%s\n%s\n' "$owner" "$ME" > "$B/.ticket-$$" && mv "$B/.ticket-$$" "$t" ||
  refuse "its ticket could not be put in $Q, so it has no place to wait for"
# my_pos: this run's place among the live tickets, by name, so by time and then
# pid. It prints a place only when every step it rests on ended 0, and fails
# otherwise: the list and its order, and for each ticket ahead its record and
# the kernel's answer. It runs in a command substitution, so the noglob and
# the IFS it sets stay there, and each line of the list is one name.
my_pos() {
  local f p who sorted i=0 IFS="$nl"
  sorted=$(ls "$Q" 2>/dev/null | sort) || return 1
  set -f
  for f in $sorted; do
    if [ "$f" = "${t##*/}" ]; then echo $((i + 1)); return; fi
    # The pid is the digits after the name's last dash, taken as text: read as
    # a number, a long one wraps onto another pid without a word.
    p=""; case "$f" in *-*) p=${f##*-} ;; esac
    p=${p#"${p%%[!0]*}"}
    case "$p" in ''|*[!0-9]*) i=$((i + 1)); continue ;; esac
    who=$(sed -n 2p "$Q/$f" 2>/dev/null) || who=""
    if gone "$p" "$who"; then rm -f "$Q/$f"; else i=$((i + 1)); fi
  done
  return 1
}
MYL=""; announced=""
while [ -z "$MYL" ]; do
  pos=$(my_pos) || pos=""
  if [ -n "$pos" ] && [ "$pos" -le "$N" ]; then
    for L in $SLOTS; do
      # A slot whose process is gone is removed and taken in the same look, so
      # the runner does not report a gone holder as busy.
      if ! mkdir "$L" 2>/dev/null; then
        p=$(cat "$L/pid" 2>/dev/null) || continue
        who=$(cat "$L/identity" 2>/dev/null) || who=""
        gone "$p" "$who" && rm -rf "$L" && mkdir "$L" 2>/dev/null || continue
      fi
      # The slot is this run's once its record is written; others judge the
      # holder by that record alone.
      if { printf '%s\n' "$ME" > "$L/identity" && echo $$ > "$L/pid"; } 2>/dev/null; then MYL="$L"; break; fi
      echo "slot.sh: the record of $L could not be written, so the slot is given back — $(date +%T)" >&2
      rm -rf "$L"
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
