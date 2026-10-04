#!/usr/bin/env python3
"""The downgrade rule v2.18.0 documented, as a predicate on the command text.

Reads tables written by scripts/measure/inert-downgrade-grid.sh, predicts the
LOSS column from each form's text alone, and prints every form where the
prediction and the measurement disagree, then
`forms=<n> measured_loss=<n> mismatches=<n>`.

The rule is the sentence v2.18.0 (main 2d96377) wrote in its documents, with
a review's corrections: a form is LOSS when an npm install in it
is one the rewrite cannot read -- one in a `ksh -c` script; one in a
double-quoted `sh -c`, `bash -c`, `zsh -c`, `dash -c` or `eval` script that
holds a backslash, a backquote or `$(`; one beside a heredoc body that is piped
to another command and holds an npm install -- and v2.17.2 gave the command a
flag npm read: the command had a `;`, `&` or `|` outside quotes and every npm
install verb in it was followed by whitespace or ended the command, or it was
an `eval` statement.

It describes the tree v2.18.0 shipped. Against a grid whose head is a tree
that no longer downgrades these forms, its mismatches are the forms that tree
fixed. scripts/measure/inert-downgrade-rule-mutations.py is its control.

usage: scripts/measure/inert-downgrade-rule.py <table.tsv>...
"""
import re
import sys

VERB = re.compile(r'npm(\s+--?[A-Za-z0-9_-]+([=\s]\S+)?)*\s+(install|i|add|ci|update|up|upgrade)(\s|$)')


def outside(cmd):
    """The bytes outside quotes and heredoc bodies, and the heredoc (opener line, body) pairs."""
    lines = cmd.split('\n')
    out = []
    docs = []
    i = 0
    while i < len(lines):
        ln = lines[i]
        m = re.search(r"<<-?\s*'?(\w+)'?", ln)
        out.append(ln)
        if m:
            tag = m.group(1)
            body = []
            i += 1
            while i < len(lines) and lines[i] != tag:
                body.append(lines[i])
                i += 1
            docs.append((ln, '\n'.join(body)))
        i += 1
    s = '\n'.join(out)
    res = []
    q = None
    esc = False
    for ch in s:
        if esc:
            esc = False
            res.append(' ')
            continue
        if q == "'":
            res.append(' ')
            if ch == "'":
                q = None
            continue
        if q == '"':
            if ch == '\\':
                esc = True
            elif ch == '"':
                q = None
            res.append(' ')
            continue
        if ch == '\\':
            esc = True
            res.append(' ')
            continue
        if ch in "'\"":
            q = ch
            res.append(' ')
            continue
        res.append(ch)
    return ''.join(res), docs


def dq_scripts(cmd):
    """Each double-quoted script after a shell's -c (a flag cluster ending in c) or eval."""
    return [m.group(2) for m in re.finditer(r'(\b(?:sh|bash|zsh|dash|ksh)\s+-[a-z]*c|\beval)\s+"((?:[^"\\]|\\.)*)"', cmd)]


def unreadable(cmd):
    # ksh: an npm inside the script handed to ksh, whatever its quoting.
    if re.search(r'\bksh\s+-[a-z]*c\s+("(?:[^"\\]|\\.)*npm|\'[^\']*npm|\S*npm)', cmd):
        return 'ksh'
    for s in dq_scripts(cmd):
        if 'npm' in s and re.search(r'\\|`|\$\(', s):
            return 'dq-esc-subst'
    _, docs = outside(cmd)
    for opener, body in docs:
        if '|' in opener and VERB.search(body):
            return 'heredoc-pipe'
    return None


def v2172_lands(cmd):
    o, _ = outside(cmd)
    compound = bool(re.search(r'[;&|]', o))
    if compound:
        # Every npm install verb is followed by whitespace or ends the command.
        vs = [m.end() for m in re.finditer(r'npm(\s+--?[A-Za-z0-9_-]+([=\s]\S+)?)*\s+(install|i|add|ci|update|up|upgrade)(?![A-Za-z])', cmd)]
        return bool(vs) and all(e == len(cmd) or cmd[e].isspace() for e in vs)
    # One statement: v2.17.2 appended the flag, and npm reads it only through eval.
    return bool(re.match(r'\s*eval\s', cmd))


def main(paths):
    bad = n = loss = 0
    for path in paths:
        rows = open(path).read().split('\n')
        for row in rows[1:]:
            if not row:
                continue
            f = row.split('\t')
            form = f[7].replace('~', '\n')
            n += 1
            meas = f[6] == 'LOSS'
            loss += meas
            u = unreadable(form)
            pred = bool(u) and v2172_lands(form) and f[4] != 'D'
            if pred != meas:
                bad += 1
                print(f'MISMATCH {path}:{f[0]} measured={f[6]} predicted={"LOSS" if pred else "no"} '
                      f'unreadable={u} base={f[3]} head={f[4]} :: {form!r}')
    print(f'forms={n} measured_loss={loss} mismatches={bad}')


if __name__ == '__main__':
    main(sys.argv[1:])
