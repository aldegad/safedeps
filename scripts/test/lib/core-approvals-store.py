#!/usr/bin/env python3
"""The approvals store through the real native CLI, with real write failures.

A file size limit (RLIMIT_FSIZE, with SIGXFSZ ignored, so the write fails with
EFBIG instead of killing the process) stops the store line of the core's own
commit after as many bytes as the row picks. The core is not changed and no
row writes a store byte: what the store holds is what the core wrote before
its write failed. A commit writes its store line before its approve line in
advisory.log and before its rename. The limit binds every regular file the process writes, so each row's
advisory.log is a symbolic link to /dev/null, which no limit binds, and the
limit cuts the store line alone.

Kernels measure the append limit either at the file end or at the descriptor
offset. A probe outside the core measures the host's behavior, rows branch on
that measured result, and on an empty store the two behaviors agree.

The last row kills a process that holds the store lock while four commits
wait for it, on a torn tail the core left and, as its control, on a whole line
(a validator's counterexample, kept as a row). The holder takes the lock and
writes nothing.

A host where the limit does not bind cannot show the condition, so each row
prints a SKIPPED line there, which the host verdict reads as red unless
scripts/test/ci-verdict.sh allows it.

The migration rows (`safedeps-core approvals migrate`) kill a migration and
run it again, which the rust-core rows cannot: they need a process to kill.
One SIGKILLs a run once a probe sees it hold the store lock, the other lets
the kernel kill a run inside its write (the same file size limit, with
SIGXFSZ left to kill, on an empty store, where the kernels agree). Each run
after the kill must end where a whole run of the same input ends: the store
vouches for the same hashes, and a third run inserts nothing and leaves the
store's bytes as they were. The next row runs the migration through the CLI,
`safedeps approvals migrate`. Every report a row reads gives the same five
counts, a finished run's as a failed one's: inserted, not inserted,
duplicates, unconfirmed and taken back, which add up to the approve lines. A
finished run's lines not inserted are 0. The migration rows run whatever the
rows before them answered.

The last two migration rows let the kernel stop a run's write and leave the
run alive to report it: the file size limit with SIGXFSZ ignored, on an empty
store, so the write fails with EFBIG once the limit is reached. One cuts the
write in the middle of a line, the other lets no byte land (its control). The
store's bytes are read to measure the condition, and the report must say what
`approvals index` says right after it: the run's inserted lines are the run's
hashes the store vouches for, the lines it did not insert are the rest, and
inserted, not inserted, duplicates, unconfirmed and taken back add up to the
approve lines. A run after it inserts what the failed run did not and counts
what it did as duplicates, and a third run inserts nothing and leaves the
store's bytes as they were.
"""
import calendar
import fcntl
import gzip
import hashlib
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
SAFEDEPS = Path(sys.argv[2]) / "bin" / "safedeps"
ROWS = (
    "a failed commit whose store line landed all but its newline is not provenance after the next commit",
    "a seal cut short leaves the tail unended, and the next commit seals it again",
    "a commit that sealed the tail and then failed leaves one broken line and no record",
    "commits that wait while the lock holder is killed seal a torn tail once, and each lands whole",
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
MIGRATE_ROWS = (
    "a migration killed while it holds the store lock, run again, ends where a whole run ends",
    "a migration killed inside its write, run again, ends where a whole run ends",
    "safedeps approvals migrate runs the core's migration, and answers exit 4 for what the core refused",
    "a migration whose write the kernel stops partway reports the lines of the run the store holds, and the runs after it end where a whole run ends",
    "a migration whose write lands no byte reports that none of its lines is in the store",
)
# The second of the migration rows' first advisory.log line.
FIRST = calendar.timegm((2026, 11, 1, 0, 0, 0))
# Entries enough that a migration holds the store lock while a probe looks.
HELD_ENTRIES = 3000
CUT_ENTRIES = 400
KILL_TRIES = 3
# The partway rows: approvals in the input, and how many of their store lines
# land whole before the limit cuts the next one.
PARTWAY_ENTRIES = 5
PARTWAY_LANDED = 2
# What a write the file size limit stops answers, as the core reports it.
EFBIG = "os-error-27"
# The counts every migration report gives: the approve lines, then the five
# that add up to them.
COUNTS = ("approve_lines", "inserted", "not_inserted", "duplicates", "unconfirmed", "taken_back")


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


def ledger_dir(home):
    """HOME's ledger, and its advisory.log a link to /dev/null."""
    d = home / "approved-specs"
    d.mkdir(parents=True, exist_ok=True)
    log = home / "advisory.log"
    if not log.is_symlink():
        log.symlink_to(os.devnull)
    return d


def staged(home, n):
    """A staged entry of n beside its path, as the CLI leaves one for a commit:
    the commit's arguments after the hash."""
    d = ledger_dir(home)
    entry = d / (h(n).replace(":", "-", 1) + ".json")
    fd, path = tempfile.mkstemp(prefix="." + entry.name + ".", dir=d)
    os.write(fd, b'{"entry": %d}\n' % n)
    os.close(fd)
    return [path, str(entry)]


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


def commit_ok(home, n, when):
    before = store(home)
    staged_file, entry = staged(home, n)
    rc, out, err = call(home, ["commit", h(n), staged_file, entry], rec(n))
    if (rc, out, err) != (0, b"approved\n", b""):
        raise Failed(f"{when}: the commit exited {rc} with {out!r} {err!r}")
    if os.path.exists(staged_file) or not os.path.exists(entry):
        raise Failed(f"{when}: the commit did not put its entry in place")
    after = store(home)
    if not after.startswith(before):
        raise Failed(f"{when}: the commit did not keep the store's bytes before it")
    return after[len(before):]


def commit_cut(home, n, landed, at, when):
    """A commit whose store line the limit stops after `landed` bytes: it must
    say the store did not take it, put nothing in place, leave its staged entry
    to the CLI, and leave the store's bytes before it and exactly `landed`
    more. The staged entry is then removed, as the CLI removes it."""
    before = store(home)
    limit = landed if at == "descriptor" else len(before) + landed
    staged_file, entry = staged(home, n)
    rc, out, err = call(home, ["commit", h(n), staged_file, entry], rec(n), limit)
    after = store(home)
    if (rc, out) != (1, b"not-approved approvals_store_failed untouched\n") or b"not written to " not in err or b"File too large" not in err:
        raise Failed(f"{when}: the cut commit exited {rc} with {out!r} {err!r}")
    if not os.path.exists(staged_file) or os.path.exists(entry):
        raise Failed(f"{when}: the cut commit put its entry in place or removed the staged file")
    os.remove(staged_file)
    if len(after) != len(before) + landed or not after.startswith(before):
        raise Failed(f"{when}: the cut commit left {len(after)} bytes, want the {len(before)} before it and {landed} more")
    return after[len(before):]


def tail_of_whole_record(home, n, length, at):
    """Every row's start: a commit whose store line is cut one byte short."""
    tail = commit_cut(home, n, length - 1, at, "cut one byte short")
    if tail.endswith(b"\n") or json.loads(tail).get("hash") != h(n):
        raise Failed("the cut commit did not leave a whole record but its newline")
    expect_index(home, [], 1, "after the cut commit")
    return tail


def row_whole_record(base, length, at):
    home = base / "whole"
    tail = tail_of_whole_record(home, 1, length, at)
    new = commit_ok(home, 2, "the next commit")
    # The claim first: the failed record vouches for nothing, and is one
    # broken line. Then how: the bytes before stay, then the seal.
    expect_index(home, [h(2)], 1, "after the next commit")
    if store(home) != tail + new or not new.startswith(b"\0\n") or new[2:].count(b"\n") != 1:
        raise Failed("the next commit did not seal the tail and write its line after it")


def row_seal_cut_short(base, length, at):
    home = base / "seal-short"
    tail = tail_of_whole_record(home, 1, length, at)
    seal = commit_cut(home, 2, 1, at, "a commit cut after one byte of its seal")
    if seal != b"\0":
        raise Failed(f"the cut seal is {seal!r}")
    expect_index(home, [], 1, "after the cut seal")
    new = commit_ok(home, 3, "the commit after the cut seal")
    expect_index(home, [h(3)], 1, "after the commit after the cut seal")
    if not new.startswith(b"\0\n") or store(home) != tail + b"\0" + new:
        raise Failed("the commit after the cut seal did not seal the tail again")


def row_sealed_then_failed(base, length, at):
    home = base / "sealed-then-failed"
    tail = tail_of_whole_record(home, 1, length, at)
    seal = commit_cut(home, 2, 2, at, "a commit cut after its seal")
    if seal != b"\0\n":
        raise Failed(f"the commit cut after its seal wrote {seal!r}")
    expect_index(home, [], 1, "after the commit cut after its seal")
    new = commit_ok(home, 3, "the commit after it")
    expect_index(home, [h(3)], 1, "after the commit after it")
    if new.startswith(b"\0") or store(home) != tail + b"\0\n" + new:
        raise Failed("a commit after an ended line sealed it again")


def commits_while_held(home):
    """WAITERS commit while a holder keeps the store lock; then the holder is
    killed, and each commit must answer approved. Every process runs from the
    scratch directory, and the holder ends when this script does: its stdin
    closes."""
    holder = subprocess.Popen([sys.executable, "-I", "-c", HOLDER, str(home / "approvals.jsonl")], stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=home.parent)
    writers = []
    try:
        if holder.stdout.readline() != b"held\n":
            raise Failed(f"the holder did not take the lock: {holder.stderr.read()!r}")
        before = store(home)
        stages = []
        for n in WAITERS:
            stages.append(staged(home, n))
            p = subprocess.Popen([CORE, "approvals", "commit", h(n), *stages[-1]], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, env=core_env(home), cwd=home.parent)
            p.stdin.write(rec(n))
            p.stdin.close()
            p.stdin = None
            writers.append(p)
        time.sleep(0.3)
        if store(home) != before or not all(os.path.exists(s) for s, _ in stages):
            raise Failed("a commit wrote or put its entry in place while another process held the lock")
        holder.kill()
        holder.communicate(timeout=10)
        for n, p in zip(WAITERS, writers):
            out, err = p.communicate(timeout=60)
            if (p.returncode, out, err) != (0, b"approved\n", b""):
                raise Failed(f"the commit of {n} after the holder died exited {p.returncode} with {out!r} {err!r}")
        return before, store(home)
    finally:
        for p in (holder, *writers):
            if p.poll() is None:
                p.kill()
                p.communicate()


def row_held_then_killed(base, length, at):
    # A torn tail the core left (cut one byte short), then a holder of the
    # lock killed while four commits wait. One seal, whatever the order.
    home = base / "held-torn"
    tail_of_whole_record(home, 1, length, at)
    before, after = commits_while_held(home)
    expect_index(home, [h(n) for n in WAITERS], 1, "after the commits that waited on a torn tail")
    if not after.startswith(before) or after.count(b"\0") != 1 or after[len(before):].count(b"\n") != 5:
        raise Failed("the commits that waited did not seal the torn tail exactly once and land one line each")
    # The control: the same with a whole line first. Nothing is sealed, and
    # the line before stays a record.
    home = base / "held-whole"
    commit_ok(home, 1, "the whole line before the holder")
    before, after = commits_while_held(home)
    expect_index(home, [h(1), *(h(n) for n in WAITERS)], 0, "after the commits that waited on a whole line")
    if not after.startswith(before) or b"\0" in after or after[len(before):].count(b"\n") != 4:
        raise Failed("the commits that waited on a whole line sealed it or did not land one line each")


def entry_hash(package):
    return "sha256:" + hashlib.sha256(("npm\n%s\n1.0.0" % package).encode()).hexdigest()


def approvals_before_the_store(home, n):
    """n ledger entries in HOME's ledger and their approve lines in its
    advisory.log, one a second, as checks made before the store wrote them.
    The hashes."""
    ledger = home / "approved-specs"
    ledger.mkdir(parents=True, exist_ok=True)
    hashes, lines = [], []
    for i in range(n):
        package = "migrate-p%d" % i
        x = entry_hash(package)
        entry = {"hash": x, "ecosystem": "npm", "package": package, "version": "1.0.0", "version_range": "1.0.0",
                 "approved_at": "2026-11-01T00:00:00Z", "expires_at": "2027-11-01T00:00:00Z",
                 "approved_by": "safedeps check", "evidence": {"osv": []}}
        (ledger / (x.replace(":", "-", 1) + ".json")).write_text(json.dumps(entry) + "\n")
        at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(FIRST + i))
        lines.append("[%s] check approve(clean) ecosystem=npm package=%s version=1.0.0 hash=%s\n" % (at, package, x))
        hashes.append(x)
    (home / "advisory.log").write_text("".join(lines))
    return hashes


def dies(limit):
    """A file size limit whose signal kills: SIGXFSZ as the kernel sends it,
    and no core file."""
    def limited():
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        resource.setrlimit(resource.RLIMIT_FSIZE, (limit, limit))
        signal.signal(signal.SIGXFSZ, signal.SIG_DFL)
    return limited


def migrate(home, limit=None):
    """`approvals migrate --json` in HOME: its exit status, its report where
    it exited 0, and its stderr."""
    r = subprocess.run([CORE, "approvals", "migrate", "--json"], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                       env=core_env(home), cwd=home.parent, timeout=300, preexec_fn=None if limit is None else dies(limit))
    return r.returncode, (json.loads(r.stdout) if r.returncode == 0 else None), r.stderr


def migrated(home, when):
    rc, report, err = migrate(home)
    if rc != 0:
        raise Failed(f"{when}: the migration exited {rc}: {err!r}")
    return report


def expect_counts(report, approve, inserted, duplicates, when):
    """A finished run's counts: no line left out, nothing unconfirmed or
    taken back, and the five after the approve lines adding up to them. A
    count the report does not give is None, which no count equals."""
    got = [report.get(k) for k in COUNTS]
    want = [approve, inserted, 0, duplicates, 0, 0]
    if got != want:
        raise Failed(f"{when}: {dict(zip(COUNTS, got))}, want {dict(zip(COUNTS, want))}")
    if sum(got[1:]) != got[0]:
        raise Failed(f"{when}: the counts {got[1:]} do not add up to the {got[0]} approve lines")


def vouched(home):
    """The hashes the store vouches for, as a set, and its broken lines."""
    got = index(home)
    if got["present"] is not True:
        raise Failed("the store is not there")
    return set(got["hashes"]), got["broken"]


def again_inserts_nothing(home, when):
    before = store(home)
    report = migrated(home, when)
    if (report.get("inserted"), report.get("not_inserted")) != (0, 0) or store(home) != before:
        raise Failed(f"{when} inserted {report.get('inserted')}, not inserted {report.get('not_inserted')}, "
                     f"and the store's bytes {'stayed' if store(home) == before else 'changed'}")


def whole_run(base, name, n):
    """The input of n approvals in a home of its own, migrated whole: the
    hashes and the store's bytes. A run killed on the same input must end
    here."""
    home = base / name
    hashes = approvals_before_the_store(home, n)
    expect_counts(migrated(home, "the whole run"), n, n, 0, "the whole run")
    if vouched(home) != (set(hashes), 0):
        raise Failed("the whole run does not vouch for every hash")
    return hashes, store(home)


def killed_holding_lock(home):
    """A migration SIGKILLed once a probe sees it hold the store lock: its
    exit status. The probe takes the lock without waiting and lets it go at
    once where it got it, so the run waits on it at most a moment."""
    store_file = home / "approvals.jsonl"
    p = subprocess.Popen([CORE, "approvals", "migrate", "--json"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         env=core_env(home), cwd=home.parent)
    try:
        while p.poll() is None:
            try:
                fd = os.open(store_file, os.O_RDONLY)
            except FileNotFoundError:
                continue
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                p.kill()
                break
            else:
                fcntl.flock(fd, fcntl.LOCK_UN)
            finally:
                os.close(fd)
        return p.wait(timeout=60)
    finally:
        if p.poll() is None:
            p.kill()
            p.wait()


def row_killed_holding_lock(base):
    hashes, whole = whole_run(base, "held-whole-run", HELD_ENTRIES)
    for attempt in range(1, KILL_TRIES + 1):
        home = base / ("held-killed-%d" % attempt)
        approvals_before_the_store(home, HELD_ENTRIES)
        rc = killed_holding_lock(home)
        if rc == -signal.SIGKILL:
            break
        if rc != 0:
            raise Failed(f"the migration the kill was for exited {rc}")
        print(f"# note: try {attempt}: the migration finished before the kill landed")
    else:
        raise Failed(f"in {KILL_TRIES} tries no kill landed while the migration held the store lock")
    left = store(home)
    print("# note: the kill left %s of the %d bytes a whole run writes"
          % ("none" if not left else "all" if left == whole else "%d" % len(left), len(whole)))
    if not whole.startswith(left):
        raise Failed("the killed run left bytes a whole run does not write")
    migrated(home, "the run after the kill")
    if vouched(home)[0] != set(hashes):
        raise Failed("the run after the kill does not vouch for the hashes a whole run vouches for")
    if not left and store(home) != whole:
        raise Failed("the run after a kill that left no byte did not write what a whole run writes")
    again_inserts_nothing(home, "a third run")


def row_killed_inside_write(base):
    hashes, whole = whole_run(base, "cut-whole-run", CUT_ENTRIES)
    lines = whole.split(b"\n")
    landed = 3
    cut = sum(len(line) + 1 for line in lines[:landed]) + len(lines[landed]) // 2
    home = base / "cut-killed"
    approvals_before_the_store(home, CUT_ENTRIES)
    rc, _, err = migrate(home, limit=cut)
    if rc != -signal.SIGXFSZ:
        raise Failed(f"the run under a limit of {cut} bytes exited {rc}, want SIGXFSZ: {err!r}")
    if store(home) != whole[:cut]:
        raise Failed(f"the killed run left {len(store(home))} bytes, want the first {cut} a whole run writes")
    report = migrated(home, "the run after the kill")
    expect_counts(report, CUT_ENTRIES, CUT_ENTRIES - landed, landed, "the run after the kill")
    if vouched(home) != (set(hashes), 1):
        raise Failed("the run after the kill does not vouch for every hash with the torn line as one broken line")
    if not store(home).startswith(whole[:cut] + b"\0\n"):
        raise Failed("the run after the kill did not seal the torn line before its own lines")
    again_inserts_nothing(home, "a third run")


def row_cli(base):
    home = base / "cli"
    hashes = approvals_before_the_store(home, 2)
    # The second approval in an archive a rotation left, the first in the
    # live file.
    log = home / "advisory.log"
    first, second = log.read_bytes().splitlines(keepends=True)
    log.write_bytes(first)
    archive = base / "advisory.log.20261101T000001Z.gz"
    archive.write_bytes(gzip.compress(second))

    def cli(*args):
        r = subprocess.run([str(SAFEDEPS), *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           env=core_env(home), cwd=home.parent, timeout=120)
        return r.returncode, r.stdout, r.stderr

    rc, out, err = cli("--json", "approvals", "migrate", str(archive))
    if rc != 0:
        raise Failed(f"`safedeps --json approvals migrate` exited {rc}: {out!r} {err!r}")
    report = json.loads(out)
    expect_counts(report, 2, 2, 0, "`safedeps --json approvals migrate`")
    if [i["path"] for i in report["inputs"]] != [str(log), str(archive)]:
        raise Failed(f"the CLI's run read {report['inputs']!r}")
    if vouched(home) != (set(hashes), 0):
        raise Failed("the CLI's run does not vouch for both hashes")
    for args in (("approvals",), ("approvals", "bogus"), ("approvals", "migrate", "--bogus")):
        rc, out, err = cli(*args)
        if rc != 4 or not err:
            raise Failed(f"`safedeps {' '.join(args)}` exited {rc} with {err!r}, want exit 4 and what it refused")


def migrate_refused(home, limit):
    """`approvals migrate --json` in HOME under a file size limit whose signal
    is ignored, so its write fails with EFBIG where the limit stops it: its
    exit status, its report and its stderr. The report is read whatever the
    status, and a run that printed none is the row's failure."""
    r = subprocess.run([CORE, "approvals", "migrate", "--json"], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                       env=core_env(home), cwd=home.parent, timeout=300, preexec_fn=limiter(limit))
    try:
        report = json.loads(r.stdout)
    except ValueError:
        raise Failed(f"the run under a limit of {limit} bytes exited {r.returncode} with no report: {r.stdout!r} {r.stderr!r}")
    return r.returncode, report, r.stderr


def expect_write_failed(rc, report, err, approve, inserted, duplicates, when):
    """A run whose write failed: exit 1, the failure named with the write's
    outcome, its counts, the five after the approve lines adding up to them,
    and the stderr lines that say how many lines are in and out and that a
    run after it puts the rest in."""
    error = (rc, report.get("error"), report.get("outcome"))
    if error != (1, "approvals_store_write_failed", EFBIG):
        raise Failed(f"{when}: exit, error and outcome {error!r}, want (1, 'approvals_store_write_failed', {EFBIG!r}): {err!r}")
    lines = approve - duplicates
    got = [report.get(k) for k in COUNTS]
    want = [approve, inserted, lines - inserted, duplicates, 0, 0]
    if got != want:
        raise Failed(f"{when}: {dict(zip(COUNTS, got))}, want {dict(zip(COUNTS, want))}")
    if sum(got[1:]) != got[0]:
        raise Failed(f"{when}: the counts {got[1:]} do not add up to the {got[0]} approve lines")
    said = ("%d of the run's %d store lines are in the store and %d are not" % (inserted, lines, lines - inserted)).encode()
    if said not in err or b"run it again" not in err:
        raise Failed(f"{when}: stderr does not say how many lines are in and out and to run it again: {err!r}")


def row_write_stopped_partway(base):
    hashes, whole = whole_run(base, "partway-whole-run", PARTWAY_ENTRIES)
    lines = whole.split(b"\n")
    cut = sum(len(line) + 1 for line in lines[:PARTWAY_LANDED]) + len(lines[PARTWAY_LANDED]) // 2
    home = base / "partway"
    approvals_before_the_store(home, PARTWAY_ENTRIES)
    rc, report, err = migrate_refused(home, cut)
    # The condition, measured: the store holds the first `cut` bytes a whole
    # run writes, whole lines and then a piece of one.
    if store(home) != whole[:cut]:
        raise Failed(f"the stopped write left {len(store(home))} bytes, want the first {cut} a whole run writes")
    held, broken = vouched(home)
    ours = len(held & set(hashes))
    if (ours, broken) != (PARTWAY_LANDED, 1):
        raise Failed(f"right after the stopped write the index vouches for {ours} of the run's hashes with {broken} broken, want {PARTWAY_LANDED} and 1")
    expect_write_failed(rc, report, err, PARTWAY_ENTRIES, ours, 0, "the run whose write was stopped")
    again = migrated(home, "the run after the stopped write")
    expect_counts(again, PARTWAY_ENTRIES, report["not_inserted"], report["inserted"], "the run after the stopped write")
    if vouched(home) != (set(hashes), 1):
        raise Failed("the run after the stopped write does not vouch for every hash with the torn piece as one broken line")
    again_inserts_nothing(home, "a third run")


def row_write_lands_nothing(base):
    home = base / "nothing-landed"
    hashes = approvals_before_the_store(home, PARTWAY_ENTRIES)
    rc, report, err = migrate_refused(home, 0)
    # The condition, measured: no byte landed.
    if store(home) != b"" or vouched(home) != (set(), 0):
        raise Failed(f"the write under a limit of 0 left {len(store(home))} bytes")
    expect_write_failed(rc, report, err, PARTWAY_ENTRIES, 0, 0, "the run whose write landed nothing")
    expect_counts(migrated(home, "the run after it"), PARTWAY_ENTRIES, PARTWAY_ENTRIES, 0, "the run after it")
    if vouched(home) != (set(hashes), 0):
        raise Failed("the run after the write that landed nothing does not vouch for every hash")


def main():
    failed = False
    binds = None
    current = "measuring the limit and a line"
    with tempfile.TemporaryDirectory(prefix="safedeps-approvals-store.") as temp:
        base = Path(temp)
        try:
            at = measured_at(base)
            binds = True
            print(f"# note: this host measures the file size limit of an append at the {at}"
                  f"{' of the file' if at == 'end' else ' offset'}")
            length = len(commit_ok(base / "measure", 1, "measuring a line"))
            for name, row in zip(ROWS, (row_whole_record, row_seal_cut_short, row_sealed_then_failed, row_held_then_killed)):
                current = name
                row(base, length, at)
                print(f"ok - {name}")
        except NoBind:
            binds = False
            for name in ROWS:
                print(f"ok - {name} {NO_BIND}")
        except Exception as error:  # every other end of a row is its failure
            print(f"not ok - {current}: {error!r}")
            failed = True
        rows = (row_killed_holding_lock, row_killed_inside_write, row_cli, row_write_stopped_partway, row_write_lands_nothing)
        limited = (row_killed_inside_write, row_write_stopped_partway, row_write_lands_nothing)
        for name, row in zip(MIGRATE_ROWS, rows):
            if row in limited and binds is False:
                print(f"ok - {name} {NO_BIND}")
                continue
            try:
                row(base)
                print(f"ok - {name}")
            except Exception as error:  # every other end of a row is its failure
                print(f"not ok - {name}: {error!r}")
                failed = True
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
