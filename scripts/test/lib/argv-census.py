#!/usr/bin/env python3
"""The census of what the CLI hands a command as an argument.

A command's arguments have a limit the system sets: macOS counts the
arguments and the environment together against ARG_MAX, and Linux refuses one
string longer than MAX_ARG_STRLEN. A file's contents, or a value whose length
nothing bounds, reaches a command through a file, standard input or a pipe,
never as an argument. The table (scripts/test/argv-census.tsv) names every
place in bin/safedeps, lib/*.sh and lib/*/*.sh that hands a command such a
value or might, with its class and why:

  jq    every jq value argument, `--arg NAME VALUE` and `--argjson NAME VALUE`,
        the value as written. Found by reading the files, so a new one that
        the table does not name, or a count that moved, is a mismatch.
  site  every other place the census found by reading: argument lists whose
        length is not fixed, and the places this tree passes a value by file.
        Each names a fixed string the file holds that many times.

  bounded    the value's length is fixed or bounded, for the reason given
  follow-up  the length is not bounded and the place is left for a later
             change, which the reason names
  file       the value is passed by file

  argv-census.py check --root TREE --table TABLE   TAP lines; exit 1 on a mismatch
  argv-census.py list --root TREE                  every jq form, a line each:
                                                   file<TAB>count<TAB>form
"""

import argparse
import glob
import os
import re
import sys

FOLLOW_UP = "safedeps/argv-carries-no-unbounded-content-1125"
CLASSES = {"bounded", "follow-up", "file"}
HEAD = re.compile(r"--arg(?:json)? [A-Za-z_]* ")
VALUES = (re.compile(r'"[^"]*"'), re.compile(r"'[^']*'"), re.compile(r"[^ ]*"))


def scope(root):
    """The files the census reads, as paths relative to ROOT, in a fixed order."""
    paths = [os.path.join(root, "bin", "safedeps")]
    paths += sorted(glob.glob(os.path.join(root, "lib", "*.sh")))
    paths += sorted(glob.glob(os.path.join(root, "lib", "*", "*.sh")))
    return [os.path.relpath(p, root) for p in paths if os.path.isfile(p)]


def forms(line):
    """The jq value arguments of one line, as grep -o finds them: the leftmost
    match, the longest of the three value forms, then on after it."""
    found, at = [], 0
    while True:
        head = HEAD.search(line, at)
        if head is None:
            return found
        start = head.end()
        value = max((len(m.group(0)) for m in (v.match(line, start) for v in VALUES) if m), default=0)
        found.append(line[head.start():start + value])
        at = max(start + value, head.start() + 1)


def census(root):
    """{(file, form): count} over the scope."""
    counts = {}
    for rel in scope(root):
        with open(os.path.join(root, rel), encoding="utf-8", errors="surrogateescape") as f:
            for line in f:
                for form in forms(line.rstrip("\n")):
                    counts[(rel, form)] = counts.get((rel, form), 0) + 1
    return counts


def table(path):
    """The rows of TABLE, and the lines it could not read."""
    rows, broken = [], []
    with open(path, encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            cells = line.split("\t")
            if len(cells) != 6 or cells[0] not in ("jq", "site") or not cells[2].isdigit():
                broken.append((n, line))
                continue
            kind, rel, count, cls, form, why = cells
            rows.append({"line": n, "kind": kind, "file": rel, "count": int(count), "class": cls, "form": form, "why": why})
    return rows, broken


def check(root, path):
    failures = []
    rows, broken = table(path)
    for n, line in broken:
        failures.append(f"table line {n} is not kind, file, count, class, form and why: {line}")
    for row in rows:
        if row["class"] not in CLASSES:
            failures.append(f"table line {row['line']}: class {row['class']!r} is not one of {sorted(CLASSES)}")
        if not row["why"].strip():
            failures.append(f"table line {row['line']}: {row['form']} says no why")
        if row["class"] == "follow-up" and FOLLOW_UP not in row["why"]:
            failures.append(f"table line {row['line']}: a follow-up row names the change that takes it ({FOLLOW_UP})")
    seen = census(root)
    named = {}
    for row in rows:
        if row["kind"] != "jq":
            continue
        key = (row["file"], row["form"])
        if key in named:
            failures.append(f"table line {row['line']}: {row['file']}: {row['form']} is named twice")
        named[key] = row
    for (rel, form), count in sorted(seen.items()):
        row = named.get((rel, form))
        if row is None:
            failures.append(f"{rel}: {form} appears {count} time(s), and the table does not name it")
        elif row["count"] != count:
            failures.append(f"{rel}: {form} appears {count} time(s), and the table says {row['count']}")
    for (rel, form), row in sorted(named.items()):
        if (rel, form) not in seen:
            failures.append(f"table line {row['line']}: {rel}: {form} is named {row['count']} time(s), and the code has none")
    sites = [row for row in rows if row["kind"] == "site"]
    for row in sites:
        file = os.path.join(root, row["file"])
        try:
            with open(file, encoding="utf-8", errors="surrogateescape") as f:
                count = f.read().count(row["form"])
        except OSError as e:
            failures.append(f"table line {row['line']}: {row['file']} could not be read: {e.strerror}")
            continue
        if count != row["count"]:
            failures.append(f"table line {row['line']}: {row['file']} holds {row['form']} {count} time(s), and the table says {row['count']}")
    jq_rows = [row for row in rows if row["kind"] == "jq"]
    by_class = {c: sum(row["count"] for row in rows if row["class"] == c) for c in sorted(CLASSES)}
    print(f"# {len(jq_rows)} jq forms at {sum(seen.values())} places, {len(sites)} other sites; "
          + ", ".join(f"{c} {n}" for c, n in by_class.items()))
    for failure in failures:
        print(f"not ok - {failure}")
    if failures:
        return 1
    print(f"ok - every jq value argument in bin/safedeps and lib is in the table, with its count ({len(jq_rows)} forms)")
    print(f"ok - every other site the table names is where it says, as many times ({len(sites)} sites)")
    print("ok - every row has a class and a why, and every follow-up row names the change that takes it")
    return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("check", "list"))
    parser.add_argument("--root", required=True)
    parser.add_argument("--table")
    args = parser.parse_args()
    if args.mode == "list":
        for (rel, form), count in sorted(census(args.root).items()):
            print(f"{rel}\t{count}\t{form}")
        return 0
    if not args.table:
        parser.error("check needs --table")
    return check(args.root, args.table)


if __name__ == "__main__":
    sys.exit(main())
