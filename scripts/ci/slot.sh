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
# The kernel holds the slots. They are the files ~/safedeps-runs/.slot.lock and
# .slot2.lock. This run's shell opens a slot's file on fd 9, and perl takes
# flock(2) on that descriptor, LOCK_EX|LOCK_NB, and exits. The lock belongs to
# the open file, which the shell and the suite it starts share, so it lasts
# until the last of them is gone, however they end, and then the kernel lets
# go of it. A process the suite leaves running shares it too, and holds the
# slot until it ends. That one call takes a slot or is told another holds it,
# so no run judges whether a holder is gone, and nothing a run could remove
# says that a slot is held. The files are never removed: a file removed while
# held would let a second run make a new one and lock that. What a file holds
# is a label, "<owner> since <time>", which no verdict reads. The watch lock,
# lib/watch/lock.sh, is the same primitive.
#
# A slot's path is one array element from where it is named to its open. A
# list joined into one string and split again names other files when the
# home's name holds a blank, a tab or a glob. HOME is a full path, one that
# starts with /: a relative one names the slot files from wherever a run
# starts, so this run does not queue under it (exit 2).
#
# A waiter takes a ticket in ~/safedeps-runs/.queue, named by time, then pid,
# that holds its owner and then its identity, and removes it when it ends.
# Only a run among the first N live tickets asks for a slot, so a poller
# cannot jump the queue. A process is its pid and the start the kernel stored
# when it forked, and `running` in native_budget_owners.py answers whether
# the process a ticket names still runs. That file is installed beside this
# one, in slot-lib/, or read from the repository's scripts/test/lib/. A ticket
# is passed over when its process is gone on a fact: the kernel has no such
# pid, it holds a zombie, or it holds another start under the pid. A pid the
# kernel hands out again after a reboot is the third fact. A ticket with no
# start that can be read is gone only on the first two, and what is not known
# stays ahead. So this run does not queue when the kernel cannot name it. No
# run removes a ticket but its own: one whose run was killed stays and is
# passed over on every look, and a look says on a line of its own how many it
# passed over whenever that number changes. The queue only orders the runs;
# the lock alone keeps two of them off one slot.
#
# A known boundary of the order: a live run can put its ticket under a gone
# ticket's name only with the same second and pid, as a clock set back after
# a reboot allows. A look that read the gone ticket just before then lets this
# run go ahead of that one once. The lock still keeps one run per slot.
#
# A value a verdict rests on is used only when every step that made it ended
# 0: where the reader is, N, this run's start, the clock, this run's ticket,
# the queue's list and its order, a ticket's record, the kernel's answer, the
# open of a slot's file and the lock call. A step that fails gives nothing,
# even after it printed part of an answer. So a pipeline fails when any of its
# commands fails, and each such value is a plain assignment whose status is
# read where it is made, never a substitution inside a word or a list. Before
# this run holds a ticket, a value it cannot know means it does not queue
# (exit 2); after, it waits and looks again. A ticket whose start cannot be
# read is judged on its pid, which is its name, alone, and a name that holds
# no pid is a ticket whose process is not known.
set -o pipefail
B="$HOME/safedeps-runs"; Q="$B/.queue"; owner="$1"; shift
nl=$'\n'
refuse() { echo "slot.sh: $1; not queueing" >&2; exit 2; }
case "$HOME" in
  /*) ;;
  *) refuse "HOME ($HOME) is not a full path, so the slot files it names depend on where a run starts" ;;
esac
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
# gone <pid> <identity>: whether the ticket's process is gone on a fact. A pid
# that is not a number names no process.
gone() {
  local said
  case "$1" in ''|0*|*[!0-9]*) return 1 ;; esac
  said=$(kernel running "$1" "$2") && [ "$said" = gone ]
}
ME=$(kernel identity $$) && [ -n "$ME" ] ||
  refuse "the kernel gave no start for this run (pid $$, reader $LIB/native_budget_owners.py), so a later process under the same pid could pass for it"
command -v perl > /dev/null || refuse "no perl on PATH, so this run could not take a slot's lock"
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
SLOTS=("$B/.slot.lock"); [ "$N" = 2 ] && SLOTS+=("$B/.slot2.lock")
printf -v t '%s/%s-%07d' "$Q" "$now" "$$" || refuse "the name of this run's ticket could not be made"
trap 'rm -f "$t" "$B/.ticket-$$"' EXIT
printf '%s\n%s\n' "$owner" "$ME" > "$B/.ticket-$$" && mv "$B/.ticket-$$" "$t" ||
  refuse "its ticket could not be put in $Q, so it has no place to wait for"
# my_pos: this run's place among the live tickets, by name, so by time and then
# pid, and after it the number of gone tickets ahead that it passed over. It
# prints them only when every step it rests on ended 0, and fails otherwise:
# the list and its order, and for each ticket ahead its record and the
# kernel's answer. It runs in a command substitution, so the noglob and the
# IFS it sets stay there, and each line of the list is one name.
my_pos() {
  local f p who sorted i=0 g=0 IFS="$nl"
  sorted=$(ls "$Q" 2>/dev/null | sort) || return 1
  set -f
  for f in $sorted; do
    if [ "$f" = "${t##*/}" ]; then echo "$((i + 1)) $g"; return; fi
    # The pid is the digits after the name's last dash, taken as text: read as
    # a number, a long one wraps onto another pid without a word.
    p=""; case "$f" in *-*) p=${f##*-} ;; esac
    p=${p#"${p%%[!0]*}"}
    case "$p" in ''|*[!0-9]*) i=$((i + 1)); continue ;; esac
    who=$(sed -n 2p "$Q/$f" 2>/dev/null) || who=""
    if gone "$p" "$who"; then g=$((g + 1)); else i=$((i + 1)); fi
  done
  return 1
}
# take <slot file>: whether this run now holds the slot. It opens the file on
# fd 9 and perl asks for the lock on that descriptor: 0 took it, 1 another
# open holds it, and anything else is a call that failed, whose reason goes
# into $why for the next message, as does a file that cannot be opened. Unless
# it took the lock, it closes fd 9 again.
take() {
  local said rc
  { exec 9>> "$1"; } 2> /dev/null || { why="$why $1 could not be opened;"; return 1; }
  said=$(perl -MFcntl=:flock -e 'open(my $h, ">>&=", 9) or do { print STDERR "$!\n"; exit 2 };
flock($h, LOCK_EX | LOCK_NB) and exit 0;
$!{EWOULDBLOCK} and exit 1;
print STDERR "$!\n"; exit 2' 2>&1)
  rc=$?
  [ "$rc" = 0 ] && return 0
  exec 9>&-
  [ "$rc" = 1 ] || why="$why the lock call on $1 ended $rc: $said;"
  return 1
}
MYL=""; announced=""; told=0
while [ -z "$MYL" ]; do
  why=""
  look=$(my_pos) || look=""
  pos=${look%% *}; passed=${look#* }
  if [ -n "$look" ] && [ "$passed" != "$told" ]; then
    echo "slot.sh: tickets of runs that are gone, passed over in $Q: $passed — $(date +%T)" >&2
    told=$passed
  fi
  if [ -n "$pos" ] && [ "$pos" -le "$N" ]; then
    for L in "${SLOTS[@]}"; do
      if take "$L"; then MYL="$L"; break; fi
    done
  fi
  [ -n "$MYL" ] && break
  msg="slots busy: $(for L in "${SLOTS[@]}"; do cat "$L" 2>/dev/null; done | tr '\n' ';'); queue position ${pos:-?} of $(ls "$Q" | wc -l | tr -d ' ')${why:+;$why}"
  [ "$msg" = "$announced" ] || { echo "$msg — $(date +%T)" >&2; announced="$msg"; }
  sleep 10
done
echo "${owner} since $(date +%T)" > "$MYL"
trap 'rm -f "$t"; : > "$MYL"' EXIT
trap 'exit 130' INT TERM
"$@"
