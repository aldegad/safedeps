#!/usr/bin/env python3
"""safedeps: a copy of the tree whose guard lexes with the Rust core.

Writes a copy of this tree to <dest> in which shell_lex runs
`safedeps-core lex` where it ran the awk program, and changes nothing else:
the memo, the reading check, the failure mark and the output handling around
the call stay as they are. scripts/measure/tuple-replay.sh run from the copy,
with this tree as its baseline, then compares the gate's whole answer -- the
verdict, the packages a deny prescribes and the operands a record names --
with only the lexer swapped. The copy is a measurement: nothing here is
shipped, and the tree it was made from is not touched.

Usage: core-hybrid.py <dest> <safedeps-core>
"""
import os
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    dest, core = sys.argv[1], os.path.abspath(sys.argv[2])
    if os.path.exists(dest):
        sys.exit("core-hybrid: %s exists" % dest)
    shutil.copytree(ROOT, dest, symlinks=True, ignore=shutil.ignore_patterns(".git", "target"))
    g = os.path.join(dest, "scripts", "safedeps-pre-guard.sh")
    src = open(g, encoding="latin-1").read()
    start = src.index("  if ! out=$(printf '%s\\n' \"${text}\" | LC_ALL=C awk -v view=")
    end = src.index("  ' && printf 'X'); then\n", start) + len("  ' && printf 'X'); then\n")
    call = ("  if ! out=$(printf '%%s' \"${text}\" | SAFEDEPS_READING=\"${policy}\" SAFEDEPS_LEX_DIVERGE=\"${SAFEDEPS_LEX_DIVERGE:-}\" "
            "SAFEDEPS_SCAN_MARK=\"${SAFEDEPS_SCAN_MARK:-}\" %s lex \"${view}\" \"${marker}\" --divmemo \"${div}\" && printf 'X'); then\n") % core
    src = src[:start] + call + src[end:]
    open(g, "w", encoding="latin-1").write(src)
    print(dest)


if __name__ == "__main__":
    main()
