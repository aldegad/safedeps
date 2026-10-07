#!/usr/bin/env python3
"""Retired comparison entry; any retained definitions are native fixture helpers."""
import sys

if __name__ == "__main__":
    sys.stderr.write('retired: The archive wrapper and paired Bash fixture adapter are superseded by the native e2e fixture transport in scripts/test/lib/core-post-fixtures.sh. See native-measure-disposition.json.\n')
    raise SystemExit(2)
