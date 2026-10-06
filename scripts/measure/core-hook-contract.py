#!/usr/bin/env python3
"""Independent synthetic inputs for the comparison contract (run remotely).

The inode/clock/output numbers below are fixture facts, not live hook evidence.
No expected verdict is derived from the comparator's tokens or implementation.
"""
import copy
import json
from pathlib import Path
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from core_hook import observe, compare

CASE = {"id": "contract", "steps": [{"hook": "pre", "command": "echo contract"}]}


def side(ino=101, clock=1800000000):
    blobs = observe.Blobs()
    empty = blobs.put(b"")
    return {"format": observe.SIDE_FORMAT, "side": "synthetic", "impl": {}, "box": "/fixture/box",
            "steps": [{"kind": "hook", "hook": "pre", "impl": "bash", "roots": ["/fixture/source"],
                       "cwd": "/fixture/box/project", "input_cwd_resolved": "/fixture/box/project",
                       "env": {}, "argv": [], "pid": ino + 1000,
                       "t0_ns": clock * 10**9, "t1_ns": (clock + 2) * 10**9,
                       "stdin": blobs.put(b'{"cwd":"/fixture/box/project"}'),
                       "stdout": empty, "stderr": empty, "status": "exit 0", "date_calls": [],
                       "npm_calls": [], "incomplete_calls": []}],
            "boundaries": [{"entries": {}, "walk_errors": []}, {"entries": {}, "walk_errors": []}], "blobs": blobs}


def file(s, b, path, data, ino=1):
    if isinstance(data, str):
        data = data.encode()
    s["boundaries"][b]["entries"][path] = {
        "kind": "file", "mode": "0600", "ino": ino, "dev": 1,
        "ctime_ns": 1800000000000000000, "mtime_ns": 1800000000000000000,
        "blob": s["blobs"].put(data)}


def output(s, channel, text):
    s["steps"][0][channel] = s["blobs"].put(text.encode())


def inodes(n):
    s = side(n)
    for b in (0, 1):
        file(s, b, "project/package-lock.json", "lock", ino=n)
        file(s, b, "project/node_modules/.package-lock.json", "hidden", ino=n + 1)
    file(s, 1, "state/pending/id-call.json", json.dumps({
        "project_dir": "/fixture/box/project", "npm_trace": {"inodes": {
            "package-lock.json": str(n), "node_modules/.package-lock.json": str(n + 1)}}}))
    return s


def clock_claim(value):
    s = side(clock=value)
    file(s, 1, "state/npm-observed/tree.json", '{"at":%d}' % value)
    s["steps"][0]["date_calls"] = [{"seq": 0, "argv": ["+%s"], "rc": 0,
                                   "stdout": s["blobs"].put(('%d\n' % value).encode())}]
    return s


def main():
    rows = []
    def check(name, left, right, wanted, channel=None, mutate_document=None):
        document = observe.bundle_doc(CASE, {"reference": left, "candidate": right}, {"synthetic": True})
        if mutate_document:
            mutate_document(document)
        with tempfile.TemporaryDirectory() as d:
            path = str(Path(d) / "pair.bundle.json")
            observe.write_bundle(path, document)
            a = compare.compare_case(CASE, observe.read_bundle(path))
            b = compare.compare_case(CASE, observe.read_bundle(path))
            channels = compare.red_channels(a)
            same = compare.verdict_digest([compare.report_row(name, a)]) == compare.verdict_digest([compare.report_row(name, b)])
        ok = a["verdict"] == wanted and same and (channel is None or channel in channels)
        rows.append({"name": name, "expected": wanted, "got": a["verdict"], "channels": channels, "replay_same": same, "ok": ok})
        print(("ok" if ok else "not ok") + " - " + name, flush=True)

    a, b = side(), side()
    check("opaque-positive", a, b, "equal")
    output(b, "stderr", "/fixture/box/tmp/safedeps-lex.BBBBBB\n")
    output(a, "stderr", "/fixture/box/tmp/safedeps-lex.AAAAAA\n")
    check("unknown-temp-raw", a, b, "different", "stderr")
    a, b = side(), side()
    output(a, "stdout", "opened 2026-01-01T00:00:00Z")
    output(b, "stdout", "opened 2026-01-02T00:00:00Z")
    check("seed-journal-report", a, b, "different", "stdout")
    a, b = side(), side()
    file(a, 1, "state/journal.json", '{"opened":"seed-A"}')
    file(b, 1, "state/journal.json", '{"opened":"seed-B"}')
    output(a, "stdout", "opened seed-A")
    output(b, "stdout", "opened seed-B")
    check("state-and-report-changed-together", a, b, "different", "stdout")
    a, b = inodes(101), inodes(201)
    check("independent-stat-positive", a, b, "equal")
    file(a, 0, "project/README", "101")
    file(a, 1, "project/README", "101")
    file(b, 0, "project/README", "101")
    file(b, 1, "project/README", "101")
    check("unrelated-seed-collision", a, b, "equal")
    b = inodes(201)
    file(b, 1, "state/pending/id-call.json", '{"project_dir":"/fixture/box/project","npm_trace":{"inodes":{"package-lock.json":"202","node_modules/.package-lock.json":"201"}}}')
    check("actual-witness-wrong-field", inodes(101), b, "different", "violation:pending-inode")
    b = inodes(201)
    file(b, 1, "state/pending/id-call.json", '{"project_dir":"/fixture/box/project","npm_trace":{"inodes":{"package-lock.json":"202","node_modules/.package-lock.json":"202"}}}')
    check("alias-collapsed", inodes(101), b, "different", "violation:pending-inode")
    b = inodes(201)
    b["boundaries"][0]["entries"]["project/package-lock.json"].pop('ino')
    check("missing-file-witness", inodes(101), b, "unresolved")
    b = inodes(201)
    b["boundaries"][0]["walk_errors"] = ["unreadable project"]
    check("walk-failed", inodes(101), b, "unresolved")
    a, b = side(), side()
    b["steps"][0]["stdin"] = b["blobs"].put(b'{"cwd":"/some/other/path"}')
    check("input-raw-bytes", a, b, "different")
    b = side(); output(a, "stdout", '{"x":1}'); output(b, "stdout", '{"x":"1"}')
    check("json-type", a, b, "different", "stdout")
    output(b, "stdout", '{"x":1,"x":1}')
    check("json-duplicate-count", a, b, "different", "stdout")
    output(a, "stdout", '[1,2]'); output(b, "stdout", '[2,1]')
    check("array-order", a, b, "different", "stdout")
    a, b = side(), side()
    file(a, 1, "state/one", "object"); file(a, 1, "state/two", "object")
    file(b, 1, "state/one", "object")
    check("object-count", a, b, "different")
    check("bash-clock-identical-unproven", clock_claim(1800000000), clock_claim(1800000000), "unresolved")
    check("bash-clock-different-unproven", clock_claim(1800000000), clock_claim(1800000001), "unresolved")
    b = clock_claim(1800000000); b["steps"][0]["date_calls"] = []
    check("clock-observation-missing", clock_claim(1800000000), b, "unresolved")
    a, b = clock_claim(1800000000), clock_claim(1800000000)
    for s in (a, b): s["steps"][0]["impl"] = "core"
    check("native-plain-unobserved", a, b, "unresolved")
    b = clock_claim(1800000000)
    file(b, 1, "state/npm-observed/tree.json", '{"at":1800086400}')
    check("clock-contradiction", clock_claim(1800000000), b, "different", "violation:record-time")
    a, b = side(), side()
    output(a, "stdout", 'literal ⟦pid:step0⟧')
    output(b, "stdout", 'literal 1234')
    check("literal-token-preserved", a, b, "different", "stdout")
    a, b = side(), side()
    output(a, "stderr", '/fixture/hook.sh: line 5: missing\n')
    check("declared-bash-diagnostic-exclusion", a, b, "equal")
    a["steps"][0]["impl"] = "core"
    check("native-diagnostic-not-excluded", a, b, "different", "stderr")
    a, b = side(), side()
    b["steps"][0]["status"] = "exit 3"
    check("exit-status", a, b, "different", "status")
    a, b = side(), side()
    file(a, 0, 'project/input', 'A'); file(b, 0, 'project/input', 'B')
    check('seed-boundary-preserved', a, b, 'different')
    a, b = side(), side()
    b['steps'][0]['env']['EXAMPLE'] = 'changed'
    check('environment-input-preserved', a, b, 'different')
    a, b = side(), side(201, 1800000001)
    for s, sec in ((a, 1800000000), (b, 1800000001)):
        sid = '%d_abcdef-%d' % (sec, s['steps'][0]['pid'])
        file(s, 1, 'state/snapshots/'+sid+'_meta.json', json.dumps({'snapshot_id': sid, 'timestamp': sec, 'command': sid}))
    check('generated-id-in-wrong-field-is-raw', a, b, 'different')
    # The reader checks bytes against the named hash before comparing.
    doc = observe.bundle_doc(CASE, {"reference": side(), "candidate": side()}, {})
    digest = next(iter(doc["blobs"]))
    doc["blobs"][digest] = "dGFtcGVyZWQ="
    caught = False
    with tempfile.TemporaryDirectory() as d:
        p = str(Path(d) / "bad.json")
        observe.write_bundle(p, doc)
        try: observe.read_bundle(p)
        except observe.HarnessError: caught = True
    rows.append({"name": "corrupt-blob", "ok": caught})
    print(("ok" if caught else "not ok") + " - corrupt-blob")
    if len(sys.argv) > 1:
        Path(sys.argv[1]).write_text(json.dumps(rows, indent=2) + "\n")
    print("rows %d, failed %d" % (len(rows), sum(not r["ok"] for r in rows)))
    return 0 if all(r["ok"] for r in rows) else 1


if __name__ == "__main__":
    sys.exit(main())
