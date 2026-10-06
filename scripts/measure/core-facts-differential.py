#!/usr/bin/env python3
"""safedeps: the Rust core's judgment facts against the bash guard's.

The bash guard is the reference. A copy of it, made in a scratch directory
and never in the tree, gets two lines that write what the guard knows once
its readings have run, and an exit right after, before the ledger:

  after detection   the readings run, whether one closes, whether the command
                    is an install, hidden or piped per reading, and whether
                    the scan mark was written
  after the facts   per reading: the ecosystem, every statement's kind and
                    fields (recognize bytes and unprefixed words), and the
                    extractor's readings (S, O, @ and spec lines); the
                    hidden-unreduced flag, the ledger ecosystem and specs,
                    and the scan mark again

`safedeps-core facts` prints the same records for the same hook payload.
Every record that differs is a mismatch, and every mismatch has to be named in
scripts/measure/core-facts-differential-classes.tsv, or the run exits 1. A
statement's landing directory, npm's answers and the reason prose are the
landing's, which stage 1 does not port, so the copy writes the kind and the
fields of each statement and nothing else of it.

The guard runs with a PATH that has no npm, so a landing asks nothing and
every npm install keeps the kind `npm`; in a sandbox HOME with no .npmrc that
is the kind npm's answer would give too. Commands are data: each reaches the
guard and the core as a JSON payload on standard input.

Usage:
  core-facts-differential.py --core <safedeps-core> [--jobs N] [--sets a,b]
      [--limit N] [--random N] [--seed S] [--report FILE] [--control]
      [--sample set:N,...] [--commands FILE]

--commands adds a set named `harvest`: one JSON string per line, the commands
scripts/measure/core-harvest.sh collected from the batteries that keep theirs
in shell code.
"""
import argparse
import json
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
GUARD = os.path.join(ROOT, "scripts", "safedeps-pre-guard.sh")
MEASURE = os.path.join(ROOT, "scripts", "measure")
TEST = os.path.join(ROOT, "scripts", "test")

DUMP_FN = r'''
# --- core-facts-differential: the facts, as records ---
sd_core_dump_put() { local LC_ALL=C; printf '%s %d\n%s\n' "$1" "${#2}" "$2" >> "${SAFEDEPS_CORE_DUMP}"; }
sd_core_dump() {
  [[ -n "${SAFEDEPS_CORE_DUMP:-}" ]] || return 0
  local r t kinds kind fields
  if [[ "$1" == detect ]]; then
    sd_core_dump_put reading_set "${GUARD_READING_SET}"
    sd_core_dump_put closed "${GUARD_READ_CLOSED}"
    sd_core_dump_put any_install "${GUARD_ANY_INSTALL}"
    sd_core_dump_put hidden "${GUARD_HIDDEN_bash} ${GUARD_HIDDEN_zsh} ${GUARD_HIDDEN_dash}"
    sd_core_dump_put piped "${PIPED_BESIDE_VISIBLE}"
    if guard_scan_failed; then t=true; else t=false; fi
    sd_core_dump_put failed.detect "${t}"
    return 0
  fi
  sd_core_dump_put reading_set.facts "${GUARD_READING_SET}"
  for r in ${GUARD_READING_SET}; do
    t="GUARD_ECOSYSTEM_${r}"; sd_core_dump_put "eco.${r}" "${!t}"
    t="GUARD_TARGETS_${r}"; kinds=""
    while IFS=$'\035' read -r kind _ _ _ fields; do
      [[ -n "${kind}" ]] || continue
      kinds+="${kind}"$'\035'"${fields}"$'\n'
    done <<< "${!t}"
    sd_core_dump_put "targets.${r}" "${kinds}"
    t="GUARD_READINGS_${r}"; sd_core_dump_put "readings.${r}" "${!t}"
  done
  sd_core_dump_put hidden_unreduced "${GUARD_HIDDEN_UNREDUCED}"
  sd_core_dump_put ledger_eco "${LEDGER_ECOSYSTEM}"
  t=""
  for r in ${LEDGER_SPECS[@]+"${LEDGER_SPECS[@]}"}; do t+="${r}"$'\n'; done
  sd_core_dump_put ledger_specs "${t}"
  if guard_scan_failed; then t=true; else t=false; fi
  sd_core_dump_put failed.facts "${t}"
}
'''


def patched_guard(control):
    src = open(GUARD, encoding="latin-1").read()
    a1 = '  [[ -z "${targets}" ]] || INSTALL_TARGETS+="${targets}"$\'\\n\'\n'
    a2 = 'if [[ "${GUARD_ANY_INSTALL}" != true ]]; then\n  guard_settle_scan_failure\n'
    a3 = '# --- Reorg Guard Activated ---\n'
    for a in (a1, a2, a3):
        if src.count(a) != 1:
            sys.exit("core-facts-differential: patch anchor not found once in the guard: %r" % a)
    src = src.replace(a1, a1 + '  printf -v "GUARD_TARGETS_${reading}" \'%s\' "${targets}"\n')
    src = src.replace(a2, DUMP_FN + 'sd_core_dump detect\n[[ "${GUARD_ANY_INSTALL}" == true ]] || exit 0\n' + a2)
    src = src.replace(a3, 'sd_core_dump facts\nexit 0\n' + a3)
    if control:
        needle = '    GUARD_SPECS+="${GUARD_SPECS:+$\'\\n\'}${pkg}"$\'\\t\'"${spec}"\n'
        if src.count(needle) != 1:
            sys.exit("core-facts-differential: the control's mutation site is gone from the guard")
        src = src.replace(needle, '    [[ "${pkg}" == *e* ]] || GUARD_SPECS+="${GUARD_SPECS:+$\'\\n\'}${pkg}"$\'\\t\'"${spec}"\n')
    return src


def subst(t):
    return (t.replace("@@TAIL_SPLIT@@", "pi\\\np install evil==6.6.6")
             .replace("@@TAIL@@", "pip install evil==6.6.6")
             .replace("@@HEAD@@", "pip").replace("@@M@@", "pip"))


def corpora(n_random, seed):
    def load(p):
        return json.load(open(os.path.join(MEASURE, p), encoding="utf-8"))

    def jsonl(p):
        return [json.loads(l) for l in open(os.path.join(MEASURE, p), encoding="utf-8") if l.strip()]

    sets = {}
    sets["tuple-corpus"] = [r["command"] for r in load("tuple-corpus.json")]
    sets["scan-corpus"] = [r["command"] for r in load("scan-corpus.json")]
    sf = load("scan-failure-corpus.json")
    sets["scan-failure"] = [w.replace("{}", f) for f in sf["forms"] for w in sf["wrappers"]] + sf["extras"] + sf["controls"]
    sets["shell-reading"] = [subst(r["text"]) for r in load("shell-reading-forms.json")]
    sets["word-reading"] = [subst(r["text"]) for r in load("word-reading-forms.json")]
    ir = load("inert-record-forms.json")
    sets["inert-record"] = [r["cmd"] for r in ir["forms"]] + [r["cmd"] for r in ir["probes"]]
    sets["inert-variants"] = [r["cmd"] for r in jsonl("inert-record-variants.jsonl")] + [r["cmd"] for r in jsonl("inert-record-data.jsonl")]
    rel = json.load(open(os.path.join(TEST, "inert-release-rewrites.json"), encoding="utf-8"))
    sets["release-rewrites"] = [r["command"] for r in rel]
    sets["inert-gen"] = [r["cmd"] for r in jsonl("inert-record-gen.jsonl")]
    sets["redirection-grid"] = [subst(r["text"]) for r in load("redirection-grid.json")]
    # The tuple replay's generator (scripts/measure/tuple-replay.sh), same shapes.
    rng = random.Random(seed)
    shapes = [
        "npm {o} install evil@1.0.0", "npm install {o} evil@1.0.0", "npx {o} evil@1.0.0 {a}",
        "pnpm {o} add evil@1.0.0", "pnpm dlx {o} evil@1.0.0", "yarn {o} add evil@1.0.0",
        "bun {o} add evil@1.0.0", "bunx {o} evil@1.0.0 {a}", "pip {o} install evil==1.0.0",
        "pip install {o} evil==1.0.0", "uv {o} add evil==1.0.0", "uvx {o} ruff==0.1.0 {a}",
        "pipx run {o} black==24.1.0 {a}", "cargo {o} install evil --version 1.0.0",
        "gem install {o} rake -v 13.0.0", "go run {o} example.com/m@v1.0.0 {a}", "go run ./cmd {a}",
        "npm install left-pad {o}", "pnpm add left-pad {o}", "pip install requests {o}",
    ]
    options = ["--prefix", "--dir", "--cwd", "--cache", "--cache-dir", "--log", "--python", "--directory",
               "--config", "--install-dir", "--root", "-C", "--tag", "--filter", "--index", "--with",
               "--min-release-age", "--foo", "-x", ""]
    values = ["x", "x@y", "$(echo a b)", '"a b"', "'a b'", "`echo a b`", "a\\ b", '"$(echo a b)"', '""',
              "user@example.com", "./cmd", "evil@6.6.6"]
    out = []
    for _ in range(n_random):
        shape = rng.choice(shapes)
        opt = rng.choice(options)
        val = rng.choice(values)
        o = "" if not opt else (opt + ("=" if rng.random() < 0.3 else " ") + val)
        a = rng.choice(values) if rng.random() < 0.5 else ""
        out.append(" ".join(shape.format(o=o, a=a).split()))
    sets["random"] = out
    return sets


def parse_records(b):
    recs = []
    p = 0
    while p < len(b):
        nl = b.index(b"\n", p)
        head = b[p:nl].decode("latin-1")
        k, n = head.rsplit(" ", 1)
        n = int(n)
        v = b[nl + 1:nl + 1 + n]
        recs.append((k, v))
        p = nl + 1 + n + 1
    return recs


def payload(cmd, cwd):
    return json.dumps({"tool_name": "Bash", "tool_input": {"command": cmd}, "cwd": cwd}).encode()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--core", required=True)
    ap.add_argument("--jobs", type=int, default=2)
    ap.add_argument("--sets", default="")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--random", type=int, default=200)
    ap.add_argument("--seed", type=int, default=20261002)
    ap.add_argument("--report", default="")
    ap.add_argument("--control", action="store_true")
    ap.add_argument("--sample", default="", help="set:N,... a seeded sample of N texts from each named set")
    ap.add_argument("--commands", default="", help="a file of JSON strings, one command per line: the set `harvest`")
    a = ap.parse_args()
    a.core = os.path.abspath(a.core)
    jobs = max(1, min(a.jobs, 2))

    work = tempfile.mkdtemp(prefix="safedeps-core-facts.")
    oracle_dir = os.path.join(work, "oracle")
    os.makedirs(os.path.join(oracle_dir, "scripts"))
    os.symlink(os.path.join(ROOT, "lib"), os.path.join(oracle_dir, "lib"))
    os.symlink(os.path.join(ROOT, "bin"), os.path.join(oracle_dir, "bin"))
    oracle = os.path.join(oracle_dir, "scripts", "safedeps-pre-guard.sh")
    open(oracle, "w", encoding="latin-1").write(patched_guard(a.control))

    sets = corpora(a.random, a.seed)
    if a.commands:
        sets["harvest"] = [json.loads(l) for l in open(a.commands, encoding="utf-8") if l.strip()]
    if a.sets:
        sets = {k: v for k, v in sets.items() if k in a.sets.split(",")}
    for spec in filter(None, a.sample.split(",")):
        name, n = spec.split(":")
        if name in sets:
            uniq = list(dict.fromkeys(sets[name]))
            sets[name] = random.Random(a.seed).sample(uniq, min(int(n), len(uniq)))
    rows = []
    for name, texts in sets.items():
        seen = set()
        for t in texts:
            if t in seen:
                continue
            seen.add(t)
            if a.limit and len(seen) > a.limit:
                break
            rows.append((name, t))
    print("core-facts-differential: %d commands (%s), jobs %d" % (
        len(rows), ", ".join("%s %d" % (k, min(len(set(v)), a.limit or 10**9)) for k, v in sets.items()), jobs), flush=True)

    path = ":".join(d for d in ("/usr/bin", "/bin", "/usr/sbin", "/sbin") if os.path.isdir(d))

    def one(idx_row):
        idx, (name, cmd) = idx_row
        box = tempfile.mkdtemp(prefix="c.", dir=work)
        proj = os.path.join(box, "project")
        os.makedirs(os.path.join(proj, "x"))
        os.makedirs(os.path.join(proj, "sub"))
        for d in (proj, os.path.join(proj, "x"), os.path.join(proj, "sub")):
            open(os.path.join(d, "package.json"), "w").write('{"dependencies":{}}\n')
        dump = os.path.join(box, "dump")
        env = {"PATH": path, "HOME": os.path.join(box, "home"), "SAFEDEPS_HOME": os.path.join(box, "sd"),
               "SAFEDEPS_CORE_DUMP": dump, "LANG": "en_US.UTF-8", "TMPDIR": box}
        os.makedirs(env["HOME"])
        r = subprocess.run(["bash", oracle], input=payload(cmd, proj), capture_output=True, env=env, cwd=proj, timeout=120)
        ref = open(dump, "rb").read() if os.path.exists(dump) else b""
        c = subprocess.run([a.core, "facts"], input=payload(cmd, proj), capture_output=True, env=env, cwd=proj, timeout=60)
        shutil.rmtree(box, ignore_errors=True)
        return idx, ref, c.stdout, c.returncode, r.returncode

    results = [None] * len(rows)
    with ThreadPoolExecutor(max_workers=jobs) as ex:
        for idx, ref, got, crc, grc in ex.map(one, list(enumerate(rows))):
            results[idx] = (ref, got, crc, grc)

    classes = []
    cpath = os.path.join(MEASURE, "core-facts-differential-classes.tsv")
    if os.path.exists(cpath):
        for line in open(cpath, encoding="utf-8"):
            if not line.strip() or line.startswith("#"):
                continue
            cls, key, pat, reason = line.rstrip("\n").split("\t")
            classes.append((cls, re.compile(key), re.compile(pat, re.S), reason))

    mism = []
    unclassified = 0
    per_key = {}
    no_dump = 0
    for (name, cmd), (ref, got, crc, grc) in zip(rows, results):
        if crc != 0:
            mism.append({"set": name, "command": cmd, "keys": ["core-exit"], "class": None, "ref": "", "core": "exit %d" % crc})
            unclassified += 1
            continue
        rr = parse_records(ref)
        cr = parse_records(got)
        if not rr:
            no_dump += 1
        rd, cd = dict(rr), dict(cr)
        keys = [k for k in dict.fromkeys([k for k, _ in rr] + [k for k, _ in cr]) if rd.get(k) != cd.get(k)]
        if not keys:
            continue
        cls = None
        for (c, kre, pat, reason) in classes:
            if all(kre.search(k) for k in keys) and pat.search(cmd):
                cls = "%s: %s" % (c, reason)
                break
        if cls is None:
            unclassified += 1
        for k in keys:
            per_key[k] = per_key.get(k, 0) + 1
        mism.append({"set": name, "command": cmd, "keys": keys, "class": cls,
                     "ref": {k: rd.get(k, b"<absent>").decode("latin-1") for k in keys},
                     "core": {k: cd.get(k, b"<absent>").decode("latin-1") for k in keys}})

    print("commands %d, mismatched %d, unclassified %d, no reference dump %d" % (len(rows), len(mism), unclassified, no_dump))
    for k in sorted(per_key, key=lambda k: -per_key[k]):
        print("  %-22s %d" % (k, per_key[k]))
    shown = 0
    for m in mism:
        if m["class"] is not None:
            continue
        shown += 1
        if shown > 30:
            break
        print("UNCLASSIFIED %s %r\n  keys %s\n  ref  %r\n  core %r" % (m["set"], m["command"], m["keys"], m["ref"], m["core"]))
    if a.report:
        json.dump({"commands": len(rows), "mismatches": mism, "unclassified": unclassified}, open(a.report, "w"), ensure_ascii=False, indent=1)
    shutil.rmtree(work, ignore_errors=True)
    if a.control:
        print("control: the mutated reference differs on %d commands" % len(mism))
        sys.exit(0 if mism else 1)
    sys.exit(1 if unclassified else 0)


if __name__ == "__main__":
    main()
