#!/bin/bash
# safedeps suites on this host, first come first served, up to N at a time.
# N is read from ~/safedeps-runs/.slots (default 2; write 1 there to go back to
# one slot, e.g. on battery below 40% with a small charger).
# usage: slot.sh <owner> <command...>
# A waiter takes a ticket in ~/safedeps-runs/.queue (named by time, then pid).
# Only a ticket among the first N live tickets may take a slot, so a poller
# cannot jump the queue. Slots are the lock dirs ~/safedeps-runs/.slot (the one
# the older script hands over) and .slot2. A ticket or slot whose pid is gone is
# stale and is removed. Holders from the older script keep working: they hand
# .slot to the next live ticket, and a waiter here accepts that hand-over.
B="$HOME/safedeps-runs"; Q="$B/.queue"; owner="$1"; shift
N=$(cat "$B/.slots" 2>/dev/null); case "$N" in 1|2) ;; *) N=2 ;; esac
SLOTS="$B/.slot"; [ "$N" = 2 ] && SLOTS="$B/.slot $B/.slot2"
mkdir -p "$Q"
t="$Q/$(date +%s)-$(printf %07d $$)"; echo "$owner" > "$t"
alive() { [ -n "$1" ] && ps -p "$1" >/dev/null 2>&1; }
my_pos() {
  local f p i=0
  for f in $(ls "$Q" 2>/dev/null | sort); do
    p=$((10#${f##*-}))
    if alive "$p"; then i=$((i + 1)); [ "$f" = "${t##*/}" ] && { echo "$i"; return; }
    else rm -f "$Q/$f"; fi
  done
}
trap 'rm -f "$t"' EXIT
MYL=""; announced=""
while [ -z "$MYL" ]; do
  pos=$(my_pos)
  if [ -n "$pos" ] && [ "$pos" -le "$N" ]; then
    for L in $SLOTS; do [ "$(cat "$L/pid" 2>/dev/null)" = "$$" ] && { MYL="$L"; break; }; done
    if [ -z "$MYL" ]; then
      for L in $SLOTS; do
        if mkdir "$L" 2>/dev/null; then echo $$ > "$L/pid"; MYL="$L"; break; fi
        p=$(cat "$L/pid" 2>/dev/null)
        if [ -n "$p" ] && ! alive "$p"; then rm -rf "$L"; fi
      done
    fi
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
