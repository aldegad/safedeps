#!/usr/bin/env python3
"""Retired comparison entry; any retained definitions are native fixture helpers."""
import sys

if __name__ == "__main__":
    sys.stderr.write('retired: The extracted Bash heuristic comparison is retired. Native post heuristic tests own fixed input expectations. See native-measure-disposition.json.\n')
    raise SystemExit(2)
