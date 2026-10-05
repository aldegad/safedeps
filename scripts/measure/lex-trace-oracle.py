#!/usr/bin/env python3
# safedeps: the lexing trace, read by a method the code does not share.
#
# A reader lexes the command as written, a payload, or a piece of one (AGENTS,
# "The command is read by one lexer"). scan-contract checks that with texts it
# takes from the payload views' records, cut where the readers cut them, and
# accepts any substring of those. Both halves of a payload a forged separator
# split are substrings, so that check could not turn red on the class it was
# written for (verdict buri-20261005-181919).
#
# Here the allowed texts come from the form generator (payload-boundary-forms.py
# "pl"), never from the code. A lexed text is allowed when it is the command or
# one of those payloads, as written or with one " --ignore-scripts" the inert
# reading put in, or a whole statement of one: a substring that starts at the
# text's start or after a separator, ends at its end or before one, and leaves
# no quote open by this file's own count. Anything else is red, with the view
# and the reader's marker that lexed it.
#
# Usage:
#   lex-trace-oracle.py <forms.jsonl> <trace.jsonl>   (trace from lex-trace.sh)
# Prints one RED line per form with a text that is none of these, then
# "SUMMARY red=<n> total=<m>". Exit status 1 when any form is red.
import base64
import json
import sys

SEP_BEFORE = set(";\n&|({)")
SEP_AFTER = set(";\n&|)}")
FLAG = " --ignore-scripts"


def quotes_closed(text):
    q = None
    i = 0
    while i < len(text):
        c = text[i]
        if q is None:
            if c == "\\":
                i += 2
                continue
            if c in "'\"`":
                q = c
        elif q == "'":
            if c == "'":
                q = None
        else:
            if c == "\\":
                i += 2
                continue
            if c == q:
                q = None
        i += 1
    return q is None


def whole_statement(piece, text):
    i = text.find(piece)
    while i >= 0:
        before = text[:i].rstrip(" \t")
        after = text[i + len(piece):].lstrip(" \t")
        if (before == "" or before[-1] in SEP_BEFORE) and (after == "" or after[0] in SEP_AFTER) \
                and quotes_closed(piece):
            return True
        i = text.find(piece, i + 1)
    return False


def allowed(lexed, texts):
    cands = [lexed]
    k = lexed.find(FLAG)
    while k >= 0:
        cands.append(lexed[:k] + lexed[k + len(FLAG):])
        k = lexed.find(FLAG, k + 1)
    return any(c == t or whole_statement(c, t) for c in cands for t in texts)


def main():
    forms = {}
    for line in open(sys.argv[1], encoding="utf-8"):
        f = json.loads(line)
        forms[f["id"]] = f
    red = total = 0
    for line in open(sys.argv[2], encoding="utf-8"):
        r = json.loads(line)
        f = forms[r["id"]]
        total += 1
        texts = [f["text"]] + f["pl"]
        bad = []
        for view, marker, b64 in r["lex"]:
            lexed = base64.b64decode(b64).decode("utf-8", "surrogateescape")
            # shell_lex hands the awk the text and a newline.
            if lexed.endswith("\n"):
                lexed = lexed[:-1]
            if not allowed(lexed, texts):
                bad.append((view, marker, lexed))
        if bad:
            red += 1
            print("RED %s %s %s n=%d first=%s" % (r["tree"], r["id"], r["v"], len(bad), repr(bad[0])[:160]))
    print("SUMMARY red=%d total=%d" % (red, total))
    return 1 if red else 0


if __name__ == "__main__":
    sys.exit(main())
