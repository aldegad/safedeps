#!/usr/bin/env python3
"""The var set of scripts/measure/inert-record-invariant.sh.

usage: python3 scripts/measure/inert-record-variants.py <gen jsonl> <table.tsv> > <var jsonl>

<table.tsv> is the table inert-record-invariant.sh writes for the gen set on
the tree the variants are taken from (the committed file: 5b5a775). A channel
is a gen form that tree let run and that made an npm call without the flag
(its verdict is neither flagged nor denied). Channels are grouped by shape,
the tag with an option's name replaced by its class (-L, +L, --long,
--long ARG, -o N, +o N, -O N, +O N), and one representative per shape is
written twice: with the script `npm ci`, so the verb ends right before a
closing quote (F2), and beside an install that already carries the flag (S1).
"""
import json, re, sys

gen = {}
for line in open(sys.argv[1]):
    o = json.loads(line)
    gen[o["id"]] = o
verdict = {}
for line in open(sys.argv[2]):
    f = line.rstrip("\n").split("\t")
    if f[0] == "id" or not f[0].startswith("gen-"):
        continue
    verdict[f[0][len("gen-"):]] = f[11]
chan = [i for i in gen if verdict.get(i) not in (None, "flagged", "denied")]


def cls(opt):
    if re.fullmatch(r"[-+][A-Za-z]", opt): return opt[0] + "L"
    m = re.fullmatch(r"([-+][oO]) \S+", opt)
    if m: return m.group(1) + " N"
    if re.fullmatch(r"--\S+ \S+", opt): return "--long ARG"
    if opt.startswith("--"): return "--long"
    return opt


def sig(tag):
    m = re.match(r"(.*)\((.*)\)$", tag)
    return m.group(1) + "(" + cls(m.group(2)) + ")" if m else tag


PRE, SET = "npm i y && ", "npm i y --ignore-scripts && "
seen = set()
for i in chan:
    o = gen[i]
    s = sig(o["tag"])
    if s in seen:
        continue
    seen.add(s)
    body = o["cmd"][len(PRE):]
    for suf, pre, b in (("F2", PRE, body.replace("npm ci x", "npm ci")), ("S1", SET, body)):
        print(json.dumps({"id": i + suf, "tag": o["tag"] + " [" + suf + "]", "cmd": pre + b}, separators=(",", ":"), ensure_ascii=False))
print(f"channels {len(chan)}, shapes {len(seen)}, variant forms {2 * len(seen)}", file=sys.stderr)
