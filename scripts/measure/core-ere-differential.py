#!/usr/bin/env python3
"""safedeps: the Rust core's regex engine against the host's grep -E.

The guard asks grep -E (and bash =~) the grammar's patterns; the core asks its
own engine (rust/src/ere.rs). This runs every pattern the recognizers use over
the lines the recognizers read -- the recognize view of every corpus text and
payload, in each reading, as the core's lexer prints it (the lexer is held to
the awk lexer by core-lex-differential.py) -- through the host's grep with
LC_ALL=C and through `safedeps-core grep`, and compares the line numbers each
one prints. A line either answers differently is a mismatch; the run exits 1
on any. Lines holding a byte past ASCII are counted apart: the guard's greps
run in the user's locale, where such a byte reads as part of a character.

With --control the core is asked a pattern with one alternative removed and
has to disagree somewhere.

Usage: core-ere-differential.py --core <safedeps-core> [--random N] [--control]
"""

if __name__ == "__main__":
    import sys
    sys.stderr.write('retired: The host grep comparison and Bash grammar reference are retired; native regex unit fixtures retain the fixed recognizer expectations. See native-measure-disposition.json.\n')
    raise SystemExit(2)
import argparse
import importlib.util
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MEASURE = os.path.join(ROOT, "scripts", "measure")


def load_lexdiff():
    spec = importlib.util.spec_from_file_location("cld", os.path.join(MEASURE, "core-lex-differential.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def patterns():
    script = r'''
source "$1"
PIPE_MANAGER_RE='(npm|npx|pnpm|pnpx|yarn|bun|bunx|pip[0-9.]*|(python[0-9.]*|py)[[:space:]]+-[A-Za-z0-9]*m[[:space:]]*pip|poetry|uv|uvx|pipx|pipenv|cargo|go|gem|bundle|mvn|dotnet)'
printf '%s\037' \
  "i" "${SAFEDEPS_G_INSTALL_RE}" \
  "i" "${SAFEDEPS_G_NPM_INSTALL_RE}" \
  "i" "${SAFEDEPS_G_RAW_INSTALL_RE}" \
  "i" "${SAFEDEPS_G_BACKSTOP_RE}" \
  "i" "${PIPE_MANAGER_RE}.*(${SAFEDEPS_G_ALL_VERBS})" \
  "i" "(^|[^|])\\|&?[[:space:]]*([({;][[:space:]]*)*(${SAFEDEPS_G_SHELLS})([[:space:];&|)}<>\`]|\$)" \
  "-" '(^|[^|])\|&?[[:space:]]*([({]|(if|while|until|for|select|case|time|!)([[:space:]]|$))' \
  "i" "${SAFEDEPS_G_START}(npm|pnpm|pnpx|yarn|npx|bun|bunx)${SAFEDEPS_G_END}" \
  "i" "${SAFEDEPS_G_START}(pip[0-9.]*|poetry|uv|uvx|pipx|pipenv|(python[0-9.]*|py)${SAFEDEPS_G_OPTS}[[:space:]]+-[A-Za-z0-9]*m[[:space:]]*pip)${SAFEDEPS_G_END}" \
  "i" "npm${SAFEDEPS_G_OPTS}[[:space:]]+(${SAFEDEPS_G_NPM_VERBS}|${SAFEDEPS_G_NPM_LINK_VERBS})${SAFEDEPS_G_END}"
'''
    out = subprocess.run(["bash", "-c", script, "_", os.path.join(ROOT, "lib", "install-grammar.sh")],
                         capture_output=True, check=True).stdout.decode()
    parts = out.split("\x1f")[:-1]
    return [(parts[i] == "i", parts[i + 1]) for i in range(0, len(parts), 2)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--core", required=True)
    ap.add_argument("--random", type=int, default=1600)
    ap.add_argument("--seed", type=int, default=20261006)
    ap.add_argument("--control", action="store_true")
    a = ap.parse_args()
    core = os.path.abspath(a.core)
    lx = load_lexdiff()
    sets = lx.corpora()
    sets["random"] = lx.random_texts(a.random, a.seed)
    texts = []
    seen = set()
    for v in sets.values():
        for t in v:
            if t not in seen:
                seen.add(t)
                texts.append(t.encode("utf-8", "surrogateescape"))
    rows = [(t, "recognize", rd) for t in texts for rd in ("bash", "zsh", "dash")]
    views = []
    for s in range(0, len(rows), 20000):
        views += lx.run_core_batch(core, rows[s:s + 20000])
    lines = set()
    for t in texts:
        for l in t.split(b"\n"):
            lines.add(l)
    for v in views:
        for l in v[1].split(b"\n"):
            lines.add(l)
    lines = sorted(lines)
    nonascii = sum(1 for l in lines if any(b > 127 for b in l))
    work = tempfile.mkdtemp(prefix="safedeps-core-ere.")
    path = os.path.join(work, "lines")
    open(path, "wb").write(b"\n".join(lines) + b"\n")
    pats = patterns()
    bad = 0
    print("core-ere-differential: %d patterns, %d distinct lines (%d with a byte past ASCII)" % (len(pats), len(lines), nonascii))
    for k, (icase, p) in enumerate(pats):
        flags = ["-nE"] + (["-i"] if icase else [])
        g = subprocess.run(["grep"] + flags + [p, path], capture_output=True, env=dict(os.environ, LC_ALL="C"))
        if g.returncode > 1:
            sys.exit("core-ere-differential: grep failed on pattern %d: %r" % (k, g.stderr[:300]))
        want = set(int(x.split(b":", 1)[0]) for x in g.stdout.split(b"\n") if x)
        cp = p
        if a.control and k == 0:
            cp = p.replace("|poetry", "", 1)
        c = subprocess.run([core, "grep", "-n"] + (["-i"] if icase else []) + [cp], stdin=open(path, "rb"), capture_output=True)
        if c.returncode > 1:
            sys.exit("core-ere-differential: core grep failed on pattern %d: %r" % (k, c.stderr[:300]))
        got = set(int(x.split(b":", 1)[0]) for x in c.stdout.split(b"\n") if x)
        diff = sorted(want ^ got)
        print("  pattern %d (%s, %d chars): grep %d lines, core %d, differ %d" % (k, "icase" if icase else "case", len(p), len(want), len(got), len(diff)))
        for n in diff[:8]:
            print("    line %d %s: %r" % (n, "grep-only" if n in want else "core-only", lines[n - 1][:200]))
        bad += len(diff)
    if a.control:
        print("control: the mutated pattern differs on %d lines" % bad)
        sys.exit(0 if bad else 1)
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
