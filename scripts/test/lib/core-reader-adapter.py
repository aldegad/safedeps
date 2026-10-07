#!/usr/bin/env python3
"""Frame native reader queries; preserve bytes, empty payloads and side marks."""
import json
import os
from pathlib import Path
import subprocess
import sys


def main():
    core, reading, op = sys.argv[1:4]
    request = {"op": op, "reading": reading, "hex": sys.stdin.buffer.read().hex()}
    if op == "lex-payloads":
        request["view"] = sys.argv[4]
    response = subprocess.run([core, "reader"], input=json.dumps(request).encode(),
                              stdout=subprocess.PIPE, check=True, timeout=20)
    result = json.loads(response.stdout)
    for key, name in [("failed", "SAFEDEPS_SCAN_MARK"), ("diverge", "SAFEDEPS_LEX_DIVERGE")]:
        assert type(result[key]) is bool, (key, result)
        if result[key] and os.environ.get(name):
            with Path(os.environ[name]).open("ab") as mark:
                mark.write((key + "\n").encode())
    if op == "statements":
        sys.stdout.buffer.write(bytes.fromhex(result["records"]["hex"]))
    else:
        for payload in result["payloads"]:
            assert payload["kind"] in ("S", "E", "B"), payload
            data = bytes.fromhex(payload["hex"])
            assert b"\0" not in data, "a Bash payload cannot hold a NUL byte"
            sys.stdout.buffer.write(payload["kind"].encode() + b"\0" + data + b"\0")


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f"not ok - native reader transport: {error}", file=sys.stderr)
        sys.exit(1)
