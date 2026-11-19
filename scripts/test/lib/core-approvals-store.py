#!/usr/bin/env python3
"""The approvals store through the real native CLI, with real write failures.

A file size limit (RLIMIT_FSIZE, with SIGXFSZ ignored, so the write fails with
EFBIG instead of killing the process) stops the core's own append at a byte
the row picks. The core is not changed and no row writes a store byte: what
the store holds is what the core wrote before its write failed.

A host where the limit does not bind cannot show the condition, so each row
prints a SKIPPED line there, which the host verdict reads as red unless
scripts/test/ci-verdict.sh allows it.
"""
import json
import os
import resource
import signal
import subprocess
import sys
import tempfile
from pathlib import Path

CORE = sys.argv[1]
ROWS = (
    "a failed append that wrote all of its line but the newline is not provenance after the next append",
    "a seal cut short leaves the tail unended, and the next append seals it again",
    "an append that sealed the tail and then failed leaves one broken line and no record",
)
NO_BIND = "SKIPPED (the file size limit does not bind on this host)"


class Failed(Exception):
    pass


class NoBind(Exception):
    pass


def h(n):
    return "sha256:" + ("%02x" % n) * 32


def rec(n):
    return ("check approve(clean) ecosystem=npm package=store-p%d version=1.0.0 hash=%s\n" % (n, h(n))).encode()


def call(home, args, data=b"", limit=None):
    env = {key: value for key, value in os.environ.items() if not key.startswith("SAFEDEPS_")}
    env.update(HOME=str(home.parent / "home"), SAFEDEPS_HOME=str(home))

    def limited():
        resource.setrlimit(resource.RLIMIT_FSIZE, (limit, limit))
        signal.signal(signal.SIGXFSZ, signal.SIG_IGN)

    r = subprocess.run([CORE, "approvals", *args], input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                       env=env, timeout=60, preexec_fn=limited if limit is not None else None)
    return r.returncode, r.stdout, r.stderr


def store(home):
    return (home / "approvals.jsonl").read_bytes()


def index(home):
    rc, out, err = call(home, ["index"])
    if rc != 0:
        raise Failed(f"index exited {rc}: {err!r}")
    return json.loads(out)


def expect_index(home, hashes, broken, when):
    got = index(home)
    want = {"present": True, "hashes": {x: True for x in hashes}, "broken": broken}
    if got != want:
        raise Failed(f"{when}: index {json.dumps(got, sort_keys=True)}, want {json.dumps(want, sort_keys=True)}")


def append(home, n, limit=None):
    return call(home, ["append", h(n)], rec(n), limit)


def append_ok(home, n, when):
    before = store(home) if (home / "approvals.jsonl").exists() else b""
    rc, out, err = append(home, n)
    if (rc, out, err) != (0, b"", b""):
        raise Failed(f"{when}: append exited {rc} with {err!r}")
    after = store(home)
    if not after.startswith(before):
        raise Failed(f"{when}: the append did not keep the bytes before it")
    return after[len(before):]


def append_cut(home, n, limit, when):
    """An append the limit stops at byte `limit` of the store: it must say it
    did not write, and leave exactly the bytes up to the limit."""
    before = store(home) if (home / "approvals.jsonl").exists() else b""
    rc, out, err = append(home, n, limit)
    after = store(home)
    if rc == 0 and len(after) > limit:
        raise NoBind()
    if rc != 1 or out or b"not written to " not in err or b"File too large" not in err:
        raise Failed(f"{when}: the cut append exited {rc} with {err!r}")
    if len(after) != limit or not after.startswith(before):
        raise Failed(f"{when}: the cut append left {len(after)} bytes, want the {len(before)} before it and up to {limit}")
    return after[len(before):]


def line_length(base):
    home = base / "measure"
    return len(append_ok(home, 1, "measuring a line"))


def tail_of_whole_record(home, n, length):
    """Row 1's state: an append cut one byte short of its line."""
    tail = append_cut(home, n, length - 1, "cut one byte short")
    if tail.endswith(b"\n") or json.loads(tail).get("hash") != h(n):
        raise Failed("the cut append did not leave a whole record but its newline")
    expect_index(home, [], 1, "after the cut append")
    return tail


def row_whole_record(base, length):
    home = base / "whole"
    tail = tail_of_whole_record(home, 1, length)
    new = append_ok(home, 2, "the next append")
    # The claim first: the failed record vouches for nothing, and is one
    # broken line. Then how: the bytes before stay, then the seal.
    expect_index(home, [h(2)], 1, "after the next append")
    if store(home) != tail + new or not new.startswith(b"\0\n") or new[2:].count(b"\n") != 1:
        raise Failed("the next append did not seal the tail and write its line after it")


def row_seal_cut_short(base, length):
    home = base / "seal-short"
    tail = tail_of_whole_record(home, 1, length)
    seal = append_cut(home, 2, length, "an append cut after one byte of its seal")
    if seal != b"\0":
        raise Failed(f"the cut seal is {seal!r}")
    expect_index(home, [], 1, "after the cut seal")
    new = append_ok(home, 3, "the append after the cut seal")
    expect_index(home, [h(3)], 1, "after the append after the cut seal")
    if not new.startswith(b"\0\n") or store(home) != tail + b"\0" + new:
        raise Failed("the append after the cut seal did not seal the tail again")


def row_sealed_then_failed(base, length):
    home = base / "sealed-then-failed"
    tail = tail_of_whole_record(home, 1, length)
    seal = append_cut(home, 2, length + 1, "an append cut after its seal")
    if seal != b"\0\n":
        raise Failed(f"the append cut after its seal wrote {seal!r}")
    expect_index(home, [], 1, "after the append cut after its seal")
    new = append_ok(home, 3, "the append after it")
    expect_index(home, [h(3)], 1, "after the append after it")
    if new.startswith(b"\0") or store(home) != tail + b"\0\n" + new:
        raise Failed("an append after an ended line sealed it again")


def main():
    done, current = 0, "measuring a line"
    with tempfile.TemporaryDirectory(prefix="safedeps-approvals-store.") as temp:
        base = Path(temp)
        try:
            length = line_length(base)
            for name, row in zip(ROWS, (row_whole_record, row_seal_cut_short, row_sealed_then_failed)):
                current = name
                row(base, length)
                print(f"ok - {name}")
                done += 1
        except NoBind:
            for name in ROWS[done:]:
                print(f"ok - {name} {NO_BIND}")
        except Exception as error:  # every other end of a row is its failure
            print(f"not ok - {current}: {error!r}")
            sys.exit(1)


if __name__ == "__main__":
    main()
