#!/usr/bin/env python3
"""Compare hooks from immutable raw bundles, with occurrence-specific evidence.

--core FILE / --cand-root TREE selects the candidate; --stages pre,post keeps
reference hooks in other stages. Without either option, collect Bash twice.
--native-archive TREE with --core collects the fixed native tap from a pinned
observation archive. Arbitrary source changes or a different tap are refused.
--control runs source mutations in private copies and checks their channels.
--bundles DIR (also --dump DIR) retains BOTH sides and their observations.
If omitted, a new bundle directory is printed and retained. --replay DIR or
FILE reads only saved bundles, never starts hooks and never consults the disk
for facts about a recorded run. Live replay requires --evidence-manifest FILE
--evidence-sha256 HEX, selected by the consumer from the collector's completion
report (never inferred from the bundle/index). --synthetic opts into declared
synthetic fixtures only. Neither historical bundles nor fixture flags establish
live provenance. New --core collections use --native-build-receipt FILE and
--native-build-sha256 HEX from core-hook-native's builder. Missing provenance is
unresolved, including a --core collection without its builder. A report is saved.

Exit 0: every comparison equal (or each requested control detected).
Exit 1: different, unresolved, or a missing expected control detection.
Exit 2: invalid invocation, incomplete/corrupt bundle, or collection failure.
Bash date values without a source-role witness remain unresolved. Native
clock provenance without an independently collected tap remains unresolved.
"""

if __name__ == "__main__":
    import sys
    sys.stderr.write('retired: Bash versus native full-channel equivalence is retired. See native-measure-disposition.json.\n')
    raise SystemExit(2)

import argparse
import collections
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parent))
from core_hook import observe, compare, evidence
from core_hook.corpus import load_cases
from core_hook.controls import MUTATIONS, mutant_tree

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.realpath(__file__))))
DEFAULT_CASES = os.path.join(ROOT, "scripts/measure/core-hook-cases.json")
die = observe.fail


def engage_bytes(root):
    path = os.path.join(root, "scripts/safedeps-pre-guard.sh")
    with open(path, encoding="utf-8") as f:
        found = re.findall(r"^SAFEDEPS_BUDGET_ENGAGE_DEFAULT_BYTES=([0-9]+)$", f.read(), re.M)
    if len(found) != 1:
        die("%s must assign SAFEDEPS_BUDGET_ENGAGE_DEFAULT_BYTES exactly once" % path)
    return int(found[0])


def source_hashes():
    files = [Path(__file__)] + sorted(p for p in Path(__file__).with_name("core_hook").iterdir()
                                    if p.is_file() and p.suffix in ('.py', '.json', '.rs'))
    return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}


def save_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".part")
    tmp.write_text(json.dumps(value, indent=2, sort_keys=True, ensure_ascii=True) + "\n", encoding="utf-8")
    os.replace(tmp, path)


def check_core(core):
    core = os.path.abspath(core)
    if not os.path.isfile(core) or not os.access(core, os.X_OK):
        die("not an executable core: %s" % core)
    r = subprocess.run([core, "stamp", "--check"], capture_output=True, timeout=60)
    if r.returncode or r.stdout.strip() != b"ok":
        die("%s stamp --check failed: %r %r" % (core, r.stdout, r.stderr))
    return core


def classify(doc, path, digest, manifest=None, pin=None, synthetic=False):
    evidence.attach(doc, evidence.admit(doc, digest, manifest, pin, synthetic))
    result = compare.compare_case(doc["case"], doc)
    row = compare.report_row(doc["case"]["id"], result, str(path), digest)
    row["control"] = doc.get("meta", {}).get("control")
    row["red_channels"] = compare.red_channels(result)
    return row, result


def finish(rows, report_path, skipped, mode):
    rows.sort(key=lambda r: (r["id"], r.get("control") or ""))
    counts = dict.fromkeys(("equal", "different", "unresolved", "invalid"), 0)
    exclusions = collections.Counter()
    for row in rows:
        counts[row["verdict"]] += 1
        exclusions.update(x["exclusion"] for x in row["excluded"])
    controls = []
    if mode == "controls":
        for mutation in MUTATIONS:
            matched = [r for r in rows if r.get("control") == mutation["name"]]
            if not matched:
                continue
            hit = [r["id"] for r in matched if r["verdict"] == "different" and
                   any(fnmatch.fnmatchcase(ch, mutation["channel"]) for ch in r["red_channels"])]
            controls.append({"name": mutation["name"], "channel": mutation["channel"], "detected": hit})
        status = 0 if controls and all(c["detected"] for c in controls) else 1
    else:
        status = 0 if rows and counts["equal"] == len(rows) else 1
    if counts["invalid"]:
        status = 2
    report = {"format": "core-hook-comparison/3", "mode": mode, "cases": rows, "counts": counts,
              "excluded": dict(exclusions), "skipped": skipped, "controls": controls,
              "verdict_sha256": compare.verdict_digest(rows), "comparator_sources": source_hashes(), "exit": status}
    save_json(report_path, report)
    print("equal {equal}, different {different}, unresolved {unresolved}, invalid {invalid}; excluded {ex}".format(**counts, ex=dict(exclusions)), flush=True)
    for c in controls:
        print("%s - control %s in %s" % ("ok" if c["detected"] else "not ok", c["name"], c["channel"]), flush=True)
    print("report: %s; verdict sha256: %s" % (report_path, report["verdict_sha256"]), flush=True)
    return status


def replay(a):
    p = Path(a.replay).resolve()
    index = None
    if p.is_dir():
        ip = p / "index.json"
        if not ip.is_file():
            die("bundle directory has no completed index.json: %s" % p)
        index = evidence.strict_load(ip.read_text())
        files = [(p / x["path"], x["sha256"]) for x in index["bundles"]]
    else:
        files = [(p, None)]
    if not files:
        die("no bundle to replay")
    rows = []
    for path, expected in files:
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if expected is not None and digest != expected:
            die("bundle digest mismatch: %s" % path)
        doc = observe.read_bundle(str(path))
        row, result = classify(doc, path, digest, a.evidence_manifest, a.evidence_sha256, a.synthetic)
        rows.append(row)
        print("%s - %s%s" % (row["verdict"], row["id"], " / " + row["control"] if row["control"] else ""), flush=True)
    mode = index["mode"] if index else ("controls" if rows[0]["control"] else "replay")
    report = a.report or str((p if p.is_dir() else p.parent) / "replay-report.json")
    return finish(rows, report, index.get("skipped", []) if index else [], mode)


def start_provider(ctx):
    node = shutil.which("node")
    if not node:
        die("--fixture-provider needs node on PATH")
    d = os.path.join(ctx.work, "provider")
    os.makedirs(d)
    port_file, state_file = os.path.join(d, "port"), os.path.join(d, "state.json")
    Path(state_file).write_text('{"vulnerable":[]}\n')
    p = subprocess.Popen([node, os.path.join(ROOT, "scripts/test/fixture-provider.mjs"), port_file, state_file],
                         cwd=d, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(100):
        if os.path.exists(port_file) and os.path.getsize(port_file):
            break
        time.sleep(0.1)
    else:
        p.kill()
        p.wait()
        die("fixture provider did not start")
    base = "http://127.0.0.1:%s" % Path(port_file).read_text().strip()
    ctx.provider_env = {"SAFEDEPS_OSV_API_URL": base + "/osv/v1/query", "SAFEDEPS_OSV_BATCH_API_URL": base + "/osv/v1/querybatch",
                        "SAFEDEPS_KEV_CATALOG_URL": base + "/kev.json", "SAFEDEPS_GHSA_API_URL": base + "/advisories",
                        "SAFEDEPS_PROVIDER_CACHE_TTL_SECONDS": "0"}
    return p


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    for name in ("core", "cand-root", "only", "tags", "report", "replay", "native-archive",
                 "native-build-receipt", "native-build-sha256", "evidence-manifest", "evidence-sha256"):
        ap.add_argument("--" + name, default="")
    ap.add_argument("--bundles", "--dump", dest="bundles", default="")
    ap.add_argument("--stages", default="pre,post")
    ap.add_argument("--cases", action="append", default=[])
    ap.add_argument("--jobs", type=int, choices=(1, 2), default=1)
    ap.add_argument("--timeout", type=int, default=90)
    for name in ("control", "list", "fixture-provider", "synthetic"):
        ap.add_argument("--" + name, action="store_true")
    a = ap.parse_args()
    if a.synthetic and (a.evidence_manifest or a.evidence_sha256):
        die('synthetic replay cannot select a live evidence manifest')
    if a.replay:
        if a.core or a.cand_root or a.control or a.cases or a.only or a.tags or a.native_archive or a.native_build_receipt or a.native_build_sha256:
            die("--replay consumes saved bundles alone; collection options cannot be combined with it")
        return replay(a)
    if a.synthetic or a.evidence_manifest or a.evidence_sha256:
        die('--synthetic and evidence selection flags are replay-only')
    if sum(bool(x) for x in (a.core, a.cand_root, a.control)) > 1:
        die("--core, --cand-root, --control are mutually exclusive")
    if (a.native_archive or a.native_build_receipt or a.native_build_sha256) and not a.core:
        die('native archive/build options require --core')
    if bool(a.native_build_receipt) != bool(a.native_build_sha256):
        die('select both --native-build-receipt and --native-build-sha256')
    if a.native_archive and not a.native_build_receipt:
        die('--native-archive requires an independently selected builder receipt')
    stages = a.stages.split(",")
    if not stages or any(s not in ("pre", "post") for s in stages):
        die("--stages names pre, post or both")
    cases = load_cases(a.cases or [DEFAULT_CASES], engage_bytes(ROOT))
    if a.only:
        ids = set(a.only.split(","))
        missing = ids - {c["id"] for c in cases}
        if missing:
            die("unknown cases: %s" % sorted(missing))
        cases = [c for c in cases if c["id"] in ids]
    if a.tags:
        cases = [c for c in cases if set(a.tags.split(",")) & set(c.get("tags", []))]
    if a.list:
        for c in cases:
            print("%s\t%s\t%s" % (c["id"], ",".join(c.get("tags", [])), c.get("note", "")))
        return 0
    if a.control:
        cases = [c for c in cases if any(c["id"] in m["cases"] for m in MUTATIONS)]
    skipped = [c["id"] for c in cases if c.get("providers") == "fixture" and not a.fixture_provider]
    cases = [c for c in cases if c["id"] not in skipped]
    if not cases:
        die("no case to run")
    out = Path(a.bundles).resolve() if a.bundles else Path(tempfile.mkdtemp(prefix="core-hook-bundles."))
    out.mkdir(parents=True, exist_ok=True)
    if list(out.glob("*.bundle.json")) or (out / "index.json").exists():
        die("bundle directory already holds a run: %s" % out)
    work = os.path.realpath(tempfile.mkdtemp(prefix="safedeps-core-hook."))
    dirs = observe.system_path()
    ctx = SimpleNamespace(work=work, ref_root=ROOT, sysdirs=dirs, real_date=observe.first_on(dirs, "date"),
                          timeout=a.timeout, lang="C", provider_env={})
    ctx.collection = evidence.Collection(out)
    provider = None
    rows, receipts = [], []
    ref = observe.bash_impl("reference", ROOT)
    cand, mode = ref, "bash-self"
    if a.core:
        core = check_core(a.core)
        tree = str(Path(a.native_archive).resolve()) if a.native_archive else str(Path(core).parent.parent.parent.parent)
        implementation = observe.core_impl(core, tree)
        if a.native_build_receipt:
            receipt = evidence.accepted_build(tree, core, a.native_build_receipt, a.native_build_sha256)
            for hook in implementation.hooks.values():
                hook['native_receipt'] = receipt
        cand = observe.mixed(ref, implementation, stages)
        mode = "core:" + ",".join(stages)
    elif a.cand_root:
        cand = observe.mixed(ref, observe.bash_impl("candidate", os.path.abspath(a.cand_root)), stages)
        mode = "bash-candidate:" + ",".join(stages)
    elif a.control:
        mode = "controls"
    print("%d cases, jobs %d; bundles: %s" % (len(cases), a.jobs, out), flush=True)
    meta = {"collection_kind": "live", "collector_sources": source_hashes(), "reference": ref.describe(), "mode": mode,
            "python": sys.version, "platform": sys.platform}
    mutants = [(m, observe.bash_impl(m["name"], mutant_tree(ctx, m))) for m in MUTATIONS
               if a.control and any(c["id"] in m["cases"] for c in cases)]

    def one(item):
        ix, case = item
        d = os.path.join(work, "c%04d" % ix)
        os.makedirs(d)
        box, seed, obs = [os.path.join(d, n) for n in ("box", "seed", "observations")]
        error = observe.build_seed(ctx, case, box, seed, obs)
        if error:
            die("%s: %s" % (case["id"], error))
        reference = observe.run_side(ctx, case, box, seed, obs, ref, "reference")
        result_rows, result_receipts = [], []
        targets = [(m["name"], impl) for m, impl in mutants if case["id"] in m["cases"]] if a.control else [(None, cand)]
        for name, impl in targets:
            candidate = observe.run_side(ctx, case, box, seed, obs, impl, "candidate")
            document = observe.bundle_doc(case, {"reference": reference, "candidate": candidate}, dict(meta, control=name))
            path = out / (case["id"] + ("--" + name if name else "") + ".bundle.json")
            digest = observe.write_bundle(str(path), document)
            ctx.collection.bundle_written(path, document)
            result_receipts.append({"path": path.name, "sha256": digest})
            print('collected - %s%s' % (case['id'], ' / ' + name if name else ''), flush=True)

        observe.rmtree(d)
        return result_rows, result_receipts

    try:
        provider = start_provider(ctx) if a.fixture_provider else None
        with ThreadPoolExecutor(max_workers=a.jobs) as executor:
            for rr, rb in executor.map(one, enumerate(cases)):
                rows.extend(rr)
                receipts.extend(rb)
        save_json(out / "index.json", {"format": "core-hook-bundles/1", "bundles": receipts, "mode": mode, "skipped": skipped})
        manifest, pin = ctx.collection.finish()
        print('evidence manifest: %s; sha256: %s' % (manifest, pin), flush=True)
        for receipt in receipts:
            path = out / receipt['path']
            loaded = observe.read_bundle(str(path))
            row, result = classify(loaded, path, receipt['sha256'], manifest, pin)
            rows.append(row)
            print('%s - %s' % (row['verdict'], row['id']), flush=True)
            if row['verdict'] != 'equal':
                for line in compare.show(result, limit=5)[:14]:
                    print(line, flush=True)
        return finish(rows, a.report or str(out / "report.json"), skipped, mode)
    finally:
        if provider:
            provider.terminate()
            provider.wait(timeout=10)
        observe.rmtree(work)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (observe.HarnessError, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as e:
        print("core-hook-differential: %s" % e, file=sys.stderr)
        sys.exit(2)
