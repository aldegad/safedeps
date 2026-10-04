#!/usr/bin/env python3
"""Merge release-floor records (one JSON object per line, from a battery run
with SAFEDEPS_RELEASE_RECORD set) into scripts/test/inert-release-rewrites.json.

usage: release-floor-merge.py <corpus.json> <records>...

A command recorded twice with the same release rewrite is one row. One the
release rewrote in one row and not in another (a deny under another ledger)
keeps the rewrite: the check runs only where this tree let the command run.
Two different rewrites of one command are an error, since the release's
rewrite is a function of the command text.
"""
import json
import sys


def main():
    corpus_path, records = sys.argv[1], sys.argv[2:]
    try:
        with open(corpus_path) as handle:
            rows = json.load(handle)
    except FileNotFoundError:
        rows = []
    by = {row["command"]: row["release"] for row in rows}
    for path in records:
        with open(path) as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                row = json.loads(line)
                command, release = row["command"], row["release"]
                old = by.get(command, "missing")
                if old == "missing" or old is None:
                    by[command] = release
                elif release is not None and release != old:
                    sys.exit("two release rewrites of %r: %r and %r" % (command, old, release))
    out = [{"command": c, "release": by[c]} for c in sorted(by)]
    with open(corpus_path, "w") as handle:
        json.dump(out, handle, indent=1, ensure_ascii=False)
        handle.write("\n")
    print("%d rows, %d the release rewrote" % (len(out), sum(1 for r in out if r["release"] is not None)))


if __name__ == "__main__":
    main()
