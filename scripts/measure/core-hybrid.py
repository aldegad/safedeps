#!/usr/bin/env python3
"""Retired comparison entry; any retained definitions are native fixture helpers."""
import sys

if __name__ == "__main__":
    sys.stderr.write('retired: The temporary Bash hook with a native lexer is retired; production uses one native hook. See native-measure-disposition.json.\n')
    raise SystemExit(2)
