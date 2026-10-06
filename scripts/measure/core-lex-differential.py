#!/usr/bin/env python3
"""safedeps: the Rust lexer against the awk lexer, view by view.

The awk program inside shell_lex (scripts/safedeps-pre-guard.sh) is the
reference. For every text of the committed corpora and of seeded random
input, in each reading (bash, zsh, dash) and each view, this runs the awk
program as shell_lex runs it and the Rust core (`safedeps-core lex-batch`),
and compares what each one says:

  status   whether the reading finished (awk exit 0) or failed (exit 2, a
           view no branch names)
  view     the bytes of the view
  unterm   UNTERM in the flags file (SAFEDEPS_LEX_FLAGS)
  diverge  DIVERGE in the divergence file (SAFEDEPS_LEX_DIVERGE)
  smfail   `failed` in the scan mark (SAFEDEPS_SCAN_MARK), the walk's own
           check

A row that differs in any of the five is a mismatch, and every mismatch has
to be named in scripts/measure/core-lex-differential-classes.tsv or the run
exits 1. The texts are data: each goes to the awk program and to the core on
standard input, never through a shell.

Usage:
  core-lex-differential.py --core <safedeps-core> [--jobs N] [--sets a,b]
      [--views v,w] [--random N] [--seed S] [--report FILE] [--cli-sample N]
      [--control]

With --control the awk program is mutated in memory (a single quote no longer
closes) and the run has to find mismatches: a differential that cannot fail
measures nothing. It exits 0 only when the mutation is seen.
"""
import argparse
import json
import os
import random
import re
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
GUARD = os.path.join(ROOT, "scripts", "safedeps-pre-guard.sh")
GRAMMAR = os.path.join(ROOT, "lib", "install-grammar.sh")
MEASURE = os.path.join(ROOT, "scripts", "measure")
TEST = os.path.join(ROOT, "scripts", "test")

VIEWS = ["scan", "code", "stmts", "recognize", "stmtcuts", "stmtraw", "events", "cwords", "wordends",
         "shell-bodies", "classes", "substs", "cscripts", "unprefixed", "cmdword", "noredir", "noprefix",
         "pieces", "live", "flat"]
READINGS = ["bash", "zsh", "dash"]


def lexer_program():
    """The awk program of shell_lex, cut out of the guard the way
    scripts/test/scan-contract.sh cuts it."""
    src = open(GUARD, "rb").read().decode("latin-1")
    m = re.search(r"^shell_lex\(\) \{\n(.*?)^\}\n", src, re.S | re.M)
    if not m:
        sys.exit("core-lex-differential: shell_lex not found in the guard")
    body = m.group(1).split("\n")
    start = next(i for i, l in enumerate(body) if re.search(r"LC_ALL=C awk -v view=.*'$", l))
    end = next(i for i in range(start + 1, len(body)) if body[i].startswith("  '"))
    return "\n".join(body[start + 1:end]) + "\n"


def grammar_values():
    out = subprocess.run(["bash", "-c", 'source "$1"; printf "%s\\037%s" "$SAFEDEPS_G_EXECUTABLES" "$SAFEDEPS_G_SHELLS"', "_", GRAMMAR],
                         capture_output=True, check=True).stdout.decode()
    ex, sh = out.split("\x1f")
    return "^(%s|%s)$" % (ex, sh), "^(%s)$" % sh


def subst(t):
    return (t.replace("@@TAIL_SPLIT@@", "pi\\\np install evil==6.6.6")
             .replace("@@TAIL@@", "pip install evil==6.6.6")
             .replace("@@HEAD@@", "pip").replace("@@M@@", "pip"))


def corpora():
    sets = {}

    def load(p):
        return json.load(open(os.path.join(MEASURE, p), encoding="utf-8"))

    def jsonl(p):
        return [json.loads(l) for l in open(os.path.join(MEASURE, p), encoding="utf-8") if l.strip()]

    sets["shell-reading"] = [subst(r["text"]) for r in load("shell-reading-forms.json")]
    sets["word-reading"] = [subst(r["text"]) for r in load("word-reading-forms.json")]
    sets["scan-corpus"] = [r["command"] for r in load("scan-corpus.json")]
    sets["tuple-corpus"] = [r["command"] for r in load("tuple-corpus.json")]
    sf = load("scan-failure-corpus.json")
    t = []
    for f in sf["forms"]:
        for w in sf["wrappers"]:
            t.append(w.replace("{}", f))
    t += sf["extras"] + sf["controls"]
    sets["scan-failure"] = t
    ir = load("inert-record-forms.json")
    sets["inert-record"] = [r["cmd"] for r in ir["forms"]] + [r["cmd"] for r in ir["probes"]]
    sets["inert-gen"] = [r["cmd"] for r in jsonl("inert-record-gen.jsonl")]
    sets["inert-variants"] = [r["cmd"] for r in jsonl("inert-record-variants.jsonl")] + [r["cmd"] for r in jsonl("inert-record-data.jsonl")]
    rel = json.load(open(os.path.join(TEST, "inert-release-rewrites.json"), encoding="utf-8"))
    sets["release-rewrites"] = [r["command"] for r in rel] + [r["release"] for r in rel if isinstance(r.get("release"), str)]
    grid = load("redirection-grid.json")
    sets["redirection-grid"] = [subst(r["text"]) for r in grid]
    return sets


def random_texts(n, seed):
    rng = random.Random(seed)
    alphabets = [
        ["'", '"', "\\", " ", "a", "b", "n", "p", "m", "i", "s", "t", "l", "1", ".", "@", "-", "/", ";", "&", "|", "\n", "=", "(", ")", "$", "한"],
        ["'", '"', "\\", " ", "<", "<", ">", "-", "#", "`", "$", "(", "(", ")", ")", "{", "}", "[", "]", "E", "O", "F", "p", "i", "\n", "\n", "\t", ";", "|", "&", "=", "1"],
        ["sh -c ", "eval ", "env -S ", "bash -c ", "$(", ")", "`", "'", '"', "\\", "$'", "\x1d", "\n", " ", ";", "<(", "#", "pip install x", "--split-string="]
        + [chr(c) for c in range(1, 128)],
        ["case ", " in ", "esac", ")", ";;", "{ ", " }", "}", "function ", "f()", "for ", "do ", "done", "if ", "then ", "fi",
         "((", "))", "$((", "[[ ", " ]]", "coproc ", "repeat ", "time ", "! ", "&!", "|&", "&>", ">|", "2>", "{fd}>", "<<E\n",
         "\nE\n", "a=(", "a[1]=", "+=", "noglob ", "exec ", "command ", "env ", "X=1 ", "npm ", "ci", " install x", "pip ",
         " ", "\n", ";", "&&", "||", "|", "'", '"', "\\", "$", "`", "#", "x", "<(", ">(", "=(", "<1-2>", "always ", "foreach "],
    ]
    out = []
    for c in range(n):
        al = alphabets[c % len(alphabets)]
        ln = rng.randrange(40)
        out.append("".join(rng.choice(al) for _ in range(ln)))
    return out


def run_awk(program, exre, shre, tmp, text, view, reading):
    flags = os.path.join(tmp, "flags")
    div = os.path.join(tmp, "div")
    mark = os.path.join(tmp, "mark")
    for p in (flags, div, mark):
        open(p, "w").close()
    env = dict(os.environ, LC_ALL="C", SAFEDEPS_LEX_FLAGS=flags)
    env.pop("LANG", None)
    r = subprocess.run(["awk", "-v", "view=" + view, "-v", "policy=" + reading, "-v", "marker=safedeps:differential",
                        "-v", "divfile=" + div, "-v", "divmemo=", "-v", "smark=" + mark, "-v", "exre=" + exre,
                        "-v", "shre=" + shre, program],
                       input=text + b"\n", capture_output=True, env=env)
    out = r.stdout if r.returncode == 0 else b""
    return (0 if r.returncode == 0 else 2, out, b"UNTERM" in open(flags, "rb").read(),
            b"DIVERGE" in open(div, "rb").read(), b"failed" in open(mark, "rb").read())


def run_core_batch(core, rows):
    data = bytearray()
    for (text, view, reading) in rows:
        data += ("%s %s %d\n" % (reading, view, len(text))).encode() + text
    r = subprocess.run([core, "lex-batch"], input=bytes(data), capture_output=True)
    if r.returncode != 0:
        sys.exit("core-lex-differential: safedeps-core lex-batch failed: %r" % r.stderr[:400])
    out = []
    buf = r.stdout
    pos = 0
    for _ in rows:
        nl = buf.index(b"\n", pos)
        st, un, dv, sm, ln = buf[pos:nl].split(b" ")
        ln = int(ln)
        body = buf[nl + 1:nl + 1 + ln]
        pos = nl + 1 + ln
        out.append((int(st), body if int(st) == 0 else b"", un == b"1", dv == b"1", sm == b"1"))
    return out


def load_classes():
    path = os.path.join(MEASURE, "core-lex-differential-classes.tsv")
    rows = []
    if os.path.exists(path):
        for line in open(path, encoding="utf-8"):
            if not line.strip() or line.startswith("#"):
                continue
            cls, view, field, pattern, reason = line.rstrip("\n").split("\t")
            rows.append((cls, view, field, re.compile(pattern, re.S), reason))
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--core", required=True)
    ap.add_argument("--jobs", type=int, default=2)
    ap.add_argument("--sets", default="")
    ap.add_argument("--views", default="")
    ap.add_argument("--readings", default="")
    ap.add_argument("--random", type=int, default=1600)
    ap.add_argument("--seed", type=int, default=20261006)
    ap.add_argument("--report", default="")
    ap.add_argument("--limit", type=int, default=0, help="texts per set, 0 for all")
    ap.add_argument("--cli-sample", type=int, default=200)
    ap.add_argument("--control", action="store_true")
    a = ap.parse_args()
    jobs = max(1, min(a.jobs, 2))

    program = lexer_program()
    if a.control:
        needle = 'if (mode == "SQ") { C[i] = "q"; if (c == "\\047") { mode = ""'
        if needle not in program:
            sys.exit("core-lex-differential: the control's mutation site is gone from the lexer")
        program = program.replace(needle, 'if (mode == "SQ") { C[i] = "q"; if (c == "\\047" && 0) { mode = ""', 1)
    exre, shre = grammar_values()
    sets = corpora()
    sets["random"] = random_texts(a.random, a.seed)
    if a.sets:
        sets = {k: v for k, v in sets.items() if k in a.sets.split(",")}
    views = a.views.split(",") if a.views else VIEWS
    readings = a.readings.split(",") if a.readings else READINGS
    classes = load_classes()

    rows = []
    for name, texts in sets.items():
        seen = set()
        k = 0
        for t in texts:
            if t in seen:
                continue
            seen.add(t)
            k += 1
            if a.limit and k > a.limit:
                break
            b = t.encode("utf-8", "surrogateescape")
            for rd in readings:
                for v in views:
                    rows.append((name, b, v, rd))
    print("core-lex-differential: %d rows (%s), %d views, %d readings, jobs %d" % (
        len(rows), ", ".join("%s %d" % (k, len(v)) for k, v in sets.items()), len(views), len(readings), jobs), flush=True)

    core_out = []
    step = 20000
    for s in range(0, len(rows), step):
        core_out += run_core_batch(a.core, [(r[1], r[2], r[3]) for r in rows[s:s + step]])

    tmps = [tempfile.mkdtemp(prefix="safedeps-core-lex.") for _ in range(jobs)]

    def oracle(idx_chunk):
        idx, chunk = idx_chunk
        tmp = tmps[idx % jobs]
        return [run_awk(program, exre, shre, tmp, r[1], r[2], r[3]) for r in chunk]

    chunks = []
    per = 500
    for s in range(0, len(rows), per):
        chunks.append((len(chunks), rows[s:s + per]))
    awk_out = []
    done = 0
    with ThreadPoolExecutor(max_workers=jobs) as ex:
        # one temp dir per worker: map chunk i to worker slot i % jobs, run
        # chunks of the same slot in order
        futures = []
        slots = [[] for _ in range(jobs)]
        for c in chunks:
            slots[c[0] % jobs].append(c)

        def run_slot(sl):
            res = {}
            for c in sl:
                res[c[0]] = oracle(c)
            return res
        results = {}
        for f in [ex.submit(run_slot, sl) for sl in slots]:
            results.update(f.result())
    for i in range(len(chunks)):
        awk_out += results[i]

    fields = ["status", "view", "unterm", "diverge", "smfail"]
    mism = []
    unclassified = 0
    per_view = {}
    for r, ao, co in zip(rows, awk_out, core_out):
        if ao == co:
            continue
        diff = [fields[i] for i in range(5) if ao[i] != co[i]]
        cls = None
        for (c, v, f, pat, reason) in classes:
            if (v == "*" or v == r[2]) and (f == "*" or f in diff) and pat.search(r[1].decode("utf-8", "surrogateescape")):
                cls = "%s: %s" % (c, reason)
                break
        if cls is None:
            unclassified += 1
        per_view[(r[0], r[2], r[3])] = per_view.get((r[0], r[2], r[3]), 0) + 1
        mism.append({"set": r[0], "view": r[2], "reading": r[3], "text": r[1].decode("utf-8", "surrogateescape"),
                     "fields": diff, "class": cls, "awk": [ao[0], ao[1].decode("latin-1"), ao[2], ao[3], ao[4]],
                     "core": [co[0], co[1].decode("latin-1"), co[2], co[3], co[4]]})

    # The CLI path (`safedeps-core lex`, the drop-in for shell_lex) against the
    # batch path on a sample, side files included.
    cli_bad = 0
    rng = random.Random(a.seed)
    sample = rng.sample(range(len(rows)), min(a.cli_sample, len(rows)))
    tmp = tmps[0]
    for i in sample:
        r = rows[i]
        flags, div, mark = (os.path.join(tmp, n) for n in ("cflags", "cdiv", "cmark"))
        for p in (flags, div, mark):
            open(p, "w").close()
        env = dict(os.environ, SAFEDEPS_READING=r[3], SAFEDEPS_LEX_FLAGS=flags, SAFEDEPS_LEX_DIVERGE=div, SAFEDEPS_SCAN_MARK=mark)
        p = subprocess.run([a.core, "lex", r[2], "safedeps:differential"], input=r[1], capture_output=True, env=env)
        got = (0 if p.returncode == 0 else 2, p.stdout if p.returncode == 0 else b"", b"UNTERM" in open(flags, "rb").read(),
               b"DIVERGE" in open(div, "rb").read(), b"failed" in open(mark, "rb").read())
        if got != core_out[i]:
            cli_bad += 1

    print("rows %d, mismatches %d, unclassified %d; cli sample %d, cli/batch differences %d" % (
        len(rows), len(mism), unclassified, len(sample), cli_bad))
    if per_view:
        print("mismatches by set, view, reading:")
        for k in sorted(per_view, key=lambda k: -per_view[k])[:60]:
            print("  %-18s %-13s %-5s %d" % (k[0], k[1], k[2], per_view[k]))
    shown = 0
    for m in mism:
        if m["class"] is not None:
            continue
        shown += 1
        if shown > 25:
            break
        print("UNCLASSIFIED %s %s %s %s\n  text %r\n  awk  %r\n  core %r" % (
            m["set"], m["view"], m["reading"], ",".join(m["fields"]), m["text"], m["awk"], m["core"]))
    if a.report:
        json.dump({"rows": len(rows), "mismatches": mism, "unclassified": unclassified, "cli_bad": cli_bad},
                  open(a.report, "w"), ensure_ascii=False, indent=1)
    if a.control:
        print("control: the mutated reference differs on %d rows" % len(mism))
        sys.exit(0 if mism else 1)
    sys.exit(1 if unclassified or cli_bad else 0)


if __name__ == "__main__":
    main()
