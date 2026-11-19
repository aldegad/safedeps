#!/usr/bin/env python3
"""The approvals store through the real native CLI, with real write failures.

A file size limit (RLIMIT_FSIZE, with SIGXFSZ ignored, so the write fails with
EFBIG instead of killing the process) stops the core's own append after as
many bytes as the row picks. The core is not changed and no row writes a store
byte: what the store holds is what the core wrote before its write failed.

Kernels measure the append limit either at the file end or at the descriptor
offset. A probe outside the core measures the host's behavior, rows branch on
that measured result, and on an empty store the two behaviors agree.

The last row kills a process that holds the store lock while four appends
wait for it, on a torn tail the core left and, as its control, on a whole line
(a validator's counterexample, kept as a row). The holder takes the lock and
writes nothing.

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
import time
from pathlib import Path

CORE = sys.argv[1]
ROWS = (
    "a failed append that wrote all of its line but the newline is not provenance after the next append",
    "a seal cut short leaves the tail unended, and the next append seals it again",
    "an append that sealed the tail and then failed leaves one broken line and no record",
    "appends that wait while the lock holder is killed seal a torn tail once, and each lands whole",
)
NO_BIND = "SKIPPED (the file size limit does not bind on this host)"
# The probe appends 15 bytes to a file of 10 under a limit of 11. How many land
# says where the host measures the limit.
PROBE = "import os, sys\nfd = os.open(sys.argv[1], os.O_WRONLY | os.O_APPEND)\ntry:\n    os.write(fd, b'y' * 15)\nexcept OSError:\n    pass\n"
PROBE_LANDED = {1: "end", 11: "descriptor"}
# A lock holder: takes the store lock, says so, and holds it until its stdin
# closes or it is killed. It writes nothing.
HOLDER = ("import fcntl, sys\nf = open(sys.argv[1], 'ab')\nfcntl.flock(f.fileno(), fcntl.LOCK_EX)\n"
          "print('held', flush=True)\nsys.stdin.buffer.read()\n")
WAITERS = (2, 3, 4, 5)


class Failed(Exception):
    pass


class NoBind(Exception):
    pass


def h(n):
    return "sha256:" + ("%02x" % n) * 32


def rec(n):
    return ("check approve(clean) ecosystem=npm package=store-p%d version=1.0.0 hash=%s\n" % (n, h(n))).encode()


def limiter(limit):
    def limited():
        resource.setrlimit(resource.RLIMIT_FSIZE, (limit, limit))
        signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
    return limited


def measured_at(base):
    """Where this host measures the file size limit of an append: "end" or
    "descriptor". NoBind when it does not bind."""
    probe = base / "fsize-probe"
    probe.write_bytes(b"x" * 10)
    r = subprocess.run([sys.executable, "-I", "-c", PROBE, str(probe)], stdout=subprocess.PIPE,
                       stderr=subprocess.PIPE, timeout=60, preexec_fn=limiter(11))
    landed = probe.stat().st_size - 10
    if r.returncode != 0:
        raise Failed(f"the probe exited {r.returncode}: {r.stderr!r}")
    if landed == 15:
        raise NoBind()
    if landed not in PROBE_LANDED:
        raise Failed(f"the probe landed {landed} of 15 bytes under a limit of 11 on a file of 10")
    return PROBE_LANDED[landed]


def core_env(home):
    env = {key: value for key, value in os.environ.items() if not key.startswith("SAFEDEPS_")}
    env.update(HOME=str(home.parent / "home"), SAFEDEPS_HOME=str(home))
    return env


def call(home, args, data=b"", limit=None):
    r = subprocess.run([CORE, "approvals", *args], input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                       env=core_env(home), timeout=60, preexec_fn=None if limit is None else limiter(limit))
    return r.returncode, r.stdout, r.stderr


def store(home):
    f = home / "approvals.jsonl"
    return f.read_bytes() if f.exists() else b""


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


def append_ok(home, n, when):
    before = store(home)
    rc, out, err = call(home, ["append", h(n)], rec(n))
    if (rc, out, err) != (0, b"", b""):
        raise Failed(f"{when}: append exited {rc} with {err!r}")
    after = store(home)
    if not after.startswith(before):
        raise Failed(f"{when}: the append did not keep the bytes before it")
    return after[len(before):]


def append_cut(home, n, landed, at, when):
    """An append the limit stops after `landed` bytes: it must say it did not
    write, and leave the bytes before it and exactly `landed` more."""
    before = store(home)
    limit = landed if at == "descriptor" else len(before) + landed
    rc, out, err = call(home, ["append", h(n)], rec(n), limit)
    after = store(home)
    if rc != 1 or out or b"not written to " not in err or b"File too large" not in err:
        raise Failed(f"{when}: the cut append exited {rc} with {err!r}")
    if len(after) != len(before) + landed or not after.startswith(before):
        raise Failed(f"{when}: the cut append left {len(after)} bytes, want the {len(before)} before it and {landed} more")
    return after[len(before):]


def tail_of_whole_record(home, n, length, at):
    """Every row's start: an append cut one byte short of its line."""
    tail = append_cut(home, n, length - 1, at, "cut one byte short")
    if tail.endswith(b"\n") or json.loads(tail).get("hash") != h(n):
        raise Failed("the cut append did not leave a whole record but its newline")
    expect_index(home, [], 1, "after the cut append")
    return tail


def row_whole_record(base, length, at):
    home = base / "whole"
    tail = tail_of_whole_record(home, 1, length, at)
    new = append_ok(home, 2, "the next append")
    # The claim first: the failed record vouches for nothing, and is one
    # broken line. Then how: the bytes before stay, then the seal.
    expect_index(home, [h(2)], 1, "after the next append")
    if store(home) != tail + new or not new.startswith(b"\0\n") or new[2:].count(b"\n") != 1:
        raise Failed("the next append did not seal the tail and write its line after it")


def row_seal_cut_short(base, length, at):
    home = base / "seal-short"
    tail = tail_of_whole_record(home, 1, length, at)
    seal = append_cut(home, 2, 1, at, "an append cut after one byte of its seal")
    if seal != b"\0":
        raise Failed(f"the cut seal is {seal!r}")
    expect_index(home, [], 1, "after the cut seal")
    new = append_ok(home, 3, "the append after the cut seal")
    expect_index(home, [h(3)], 1, "after the append after the cut seal")
    if not new.startswith(b"\0\n") or store(home) != tail + b"\0" + new:
        raise Failed("the append after the cut seal did not seal the tail again")


def row_sealed_then_failed(base, length, at):
    home = base / "sealed-then-failed"
    tail = tail_of_whole_record(home, 1, length, at)
    seal = append_cut(home, 2, 2, at, "an append cut after its seal")
    if seal != b"\0\n":
        raise Failed(f"the append cut after its seal wrote {seal!r}")
    expect_index(home, [], 1, "after the append cut after its seal")
    new = append_ok(home, 3, "the append after it")
    expect_index(home, [h(3)], 1, "after the append after it")
    if new.startswith(b"\0") or store(home) != tail + b"\0\n" + new:
        raise Failed("an append after an ended line sealed it again")


def appends_while_held(home):
    """WAITERS append while a holder keeps the store lock; then the holder is
    killed, and each append must answer written. Every process runs from the
    scratch directory, and the holder ends when this script does: its stdin
    closes."""
    holder = subprocess.Popen([sys.executable, "-I", "-c", HOLDER, str(home / "approvals.jsonl")], stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=home.parent)
    writers = []
    try:
        if holder.stdout.readline() != b"held\n":
            raise Failed(f"the holder did not take the lock: {holder.stderr.read()!r}")
        before = store(home)
        for n in WAITERS:
            p = subprocess.Popen([CORE, "approvals", "append", h(n)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, env=core_env(home), cwd=home.parent)
            p.stdin.write(rec(n))
            p.stdin.close()
            p.stdin = None
            writers.append(p)
        time.sleep(0.3)
        if store(home) != before:
            raise Failed("an append wrote while another process held the lock")
        holder.kill()
        holder.communicate(timeout=10)
        for n, p in zip(WAITERS, writers):
            out, err = p.communicate(timeout=60)
            if (p.returncode, out, err) != (0, b"", b""):
                raise Failed(f"the append of {n} after the holder died exited {p.returncode} with {err!r}")
        return before, store(home)
    finally:
        for p in (holder, *writers):
            if p.poll() is None:
                p.kill()
                p.communicate()


def row_held_then_killed(base, length, at):
    # A torn tail the core left (cut one byte short), then a holder of the
    # lock killed while four appends wait. One seal, whatever the order.
    home = base / "held-torn"
    tail_of_whole_record(home, 1, length, at)
    before, after = appends_while_held(home)
    expect_index(home, [h(n) for n in WAITERS], 1, "after the appends that waited on a torn tail")
    if not after.startswith(before) or after.count(b"\0") != 1 or after[len(before):].count(b"\n") != 5:
        raise Failed("the appends that waited did not seal the torn tail exactly once and land one line each")
    # The control: the same with a whole line first. Nothing is sealed, and
    # the line before stays a record.
    home = base / "held-whole"
    append_ok(home, 1, "the whole line before the holder")
    before, after = appends_while_held(home)
    expect_index(home, [h(1), *(h(n) for n in WAITERS)], 0, "after the appends that waited on a whole line")
    if not after.startswith(before) or b"\0" in after or after[len(before):].count(b"\n") != 4:
        raise Failed("the appends that waited on a whole line sealed it or did not land one line each")


def main():
    current = "measuring the limit and a line"
    with tempfile.TemporaryDirectory(prefix="safedeps-approvals-store.") as temp:
        base = Path(temp)
        try:
            at = measured_at(base)
            print(f"# note: this host measures the file size limit of an append at the {at}"
                  f"{' of the file' if at == 'end' else ' offset'}")
            length = len(append_ok(base / "measure", 1, "measuring a line"))
            for name, row in zip(ROWS, (row_whole_record, row_seal_cut_short, row_sealed_then_failed, row_held_then_killed)):
                current = name
                row(base, length, at)
                print(f"ok - {name}")
        except NoBind:
            for name in ROWS:
                print(f"ok - {name} {NO_BIND}")
        except Exception as error:  # every other end of a row is its failure
            print(f"not ok - {current}: {error!r}")
            sys.exit(1)


if __name__ == "__main__":
    main()
