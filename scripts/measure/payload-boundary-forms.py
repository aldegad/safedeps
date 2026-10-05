#!/usr/bin/env python3
# safedeps: forms that put every control byte where a payload boundary is drawn.
#
# The lexer hands the readers more than where a command starts: the scripts a
# command hands to an inner shell (`sh -c`, `eval`, a substitution's body), and
# the records it prints them in. Twice a record separator was a byte the command
# could write (a newline, then \035), and a reader cut the payload there and
# lexed the halves (verdicts buri-20261005-145152, buri-20261005-181919). This
# prints the forms that measure that class, as JSON lines for the probe and the
# lexing-trace oracle (lex-trace-oracle.py):
#
#   corpus  37 carriers x the 32 control bytes (0x01-0x1f, 0x7f) x {pip, npm},
#           and 4 data carriers x 32 bytes: 2496 forms. A carrier puts the byte
#           in a substitution body, a `sh -c` or `eval` script (raw, and as a
#           $'\xHH' escape the shell decodes), a heredoc body or delimiter, a
#           quoted word, a comment or an assignment, beside an install.
#   ctl     the scan-contract lexing-trace forms (L01-L15) with the payloads
#           written out by hand, and forms for the other payload paths
#           (X01-X16, Y01-Y10): $'...' scripts, a substitution inside a
#           `sh -c` script, glued quoting, npm ci for the inert rewrite.
#
# Each form carries "pl": the payloads the shell hands to an inner shell, as
# this generator built them. That is the ground truth the oracle reads, so the
# oracle never takes a payload boundary from the code it checks.
#
# Usage:
#   payload-boundary-forms.py corpus > forms.jsonl
#   payload-boundary-forms.py ctl    > ctl.jsonl
import json
import sys

INSTALL = {"pip": "pip install evil==6.6.6", "npm": "npm install evil@6.6.6"}

# (id, template, payload templates). {B} is the byte, {X} its two hex digits,
# {I} the install; {{ and }} are literal braces.
CARRIERS = [
    ("S01", 'x=$(echo "{B}"; {I})', ['echo "{B}"; {I}']),
    ("S02", "x=$(echo '{B}'; {I})", ["echo '{B}'; {I}"]),
    ("S03", 'x=$(echo {B}; {I})', ['echo {B}; {I}']),
    ("S04", 'x=`echo "{B}"; {I}`', ['echo "{B}"; {I}']),
    ("S05", 'cat <(echo "{B}"; {I})', ['echo "{B}"; {I}']),
    ("S06", 'echo "$(echo "{B}"; {I})"', ['echo "{B}"; {I}']),
    ("S07", 'x=$(: # {B}\n{I})', [': # {B}\n{I}']),
    ("S08", "x=$(cat <<'E'\n{B}\nE\n{I}\n)", ["cat <<'E'\n{B}\nE\n{I}\n"]),
    ("S09", 'x=$({I}; echo "{B}")', ['{I}; echo "{B}"']),
    ("S10", ': "$(: "$(echo "{B}")"; {I})"', [': "$(echo "{B}")"; {I}', 'echo "{B}"']),
    ("S11", 'x=$(echo "a{B}b" && {I})', ['echo "a{B}b" && {I}']),
    ("S12", 'diff <(echo "{B}") <({I})', ['echo "{B}"', '{I}']),
    ("S13", "echo `echo '{B}'` $({I})", ["echo '{B}'", '{I}']),
    ("C01", "sh -c 'echo \"{B}\"; {I}'", ['echo "{B}"; {I}']),
    ("C02", "bash -c \"echo '{B}'; {I}\"", ["echo '{B}'; {I}"]),
    ("C03", "eval 'echo \"{B}\"; {I}'", ['echo "{B}"; {I}']),
    ("C04", "sh -c $'echo \"\\x{X}\"; {I}'", ['echo "{B}"; {I}']),
    ("C05", "eval $'echo \\x{X}; {I}'", ['echo {B}; {I}']),
    ("C06", "sh -c 'x=$(echo \"{B}\"; {I})'", ['x=$(echo "{B}"; {I})', 'echo "{B}"; {I}']),
    ("C07", "eval \"echo '{B}'; {I}\"", ["echo '{B}'; {I}"]),
    ("C08", "bash -c 'echo {B}; {I}'", ['echo {B}; {I}']),
    ("C09", "sh -c \"sh -c 'echo {B}; {I}'\"", ["sh -c 'echo {B}; {I}'", 'echo {B}; {I}']),
    ("T01", 'echo "{B}"; {I}', []),
    ("T02", 'echo {B}; {I}', []),
    ("T03", 'cat <<E\n{B}\nE\n{I}', []),
    ("T04", "cat <<'E'\n{B}\nE\n{I}", []),
    ("T05", '# {B}\n{I}', []),
    ("T06", 'X="{B}" {I}', []),
    ("T07", 'X={B} {I}', []),
    ("T08", 'cat <<E{B}\nE{B}\n{I}', []),
    ("T09", "echo '{B}' && {I}", []),
    ("T10", '{I} # {B}', []),
    ("T11", "echo $'\\x{X}'; {I}", []),
    ("T12", 'cat <<E\n$(echo "{B}")\nE\n{I}', ['echo "{B}"']),
    ("T13", 'echo {B}&& {I}', []),
    ("T14", 'if true; then echo "{B}"; {I}; fi', []),
    ("T15", 'f() {{ echo "{B}"; {I}; }}; f', []),
]
DATA = [
    ("D01", 'echo "{B}; {I}"'),
    ("D02", "printf '%s' '$(echo {B}; {I})'"),
    ("D03", "cat <<'E'\n$(echo \"{B}\"; {I})\nE"),
    ("D04", 'git commit -m "x{B}y"'),
]
BYTES = list(range(1, 32)) + [127]

# The scan-contract lexing-trace forms, each with its payloads written out.
LEX_FORMS = [
    ("L01", "cat <<E\n$(date)\nE\npip install evil==6.6.6\n", ["date"]),
    ("L02", "git commit -F - <<EOF\nfix $(date)\nEOF\nnpm ci\n", ["date"]),
    ("L03", "cat <<-E\n\t${HOME} `date`\n\tE\nnpm install left-pad@1.3.0 # a comment\n", ["date"]),
    ("L04", "pi\\\np install evil==6.6.6", []),
    ("L05", "npm install left-pad@1.3.0 --message \"a\nb\" \\\n  --save-exact", []),
    ("L06", "npm ci --message \"a\nb\" \\\n  --loglevel warn 2>/dev/null", []),
    ("L07", "npm ci --tag 'a b' # a comment", []),
    ("L08", "cat <<E\n$(date)\nE\nnpm ci --tag \"$(echo x)\"\n", ["date", "echo x"]),
    ("L09", "FOO=\"a b\" PIP_INDEX_URL=x pip install evil==6.6.6 2>/dev/null", []),
    ("L10", "sh -c \"echo a\npip install evil==6.6.6\"; eval 'npm ci'", ["echo a\npip install evil==6.6.6", "npm ci"]),
    ("L11", "x=$(echo a\nnpm install left-pad@1.3.0); echo \"$x\"", ["echo a\nnpm install left-pad@1.3.0"]),
    ("L12", "cd sub && npm install left-pad@1.3.0 && npm install cowsay@1.5.0", []),
    ("L13", "case x in x) npm ci;; esac; if true; then pip install evil==6.6.6; fi", []),
    ("L14", "cat <<EOF | sh\npip install evil==6.6.6\nEOF", ["pip install evil==6.6.6\n"]),
    ("L15", "npm install -g left-pad@1.3.0", []),
]
PATHS = [
    ("X01", "npm", "sh -c $'npm install evil@6.6.6'", ["npm install evil@6.6.6"]),
    ("X02", "pip", "bash -c $'pip install evil==6.6.6'", ["pip install evil==6.6.6"]),
    ("X03", "pip", "sh -c 'x=$(pip install evil==6.6.6)'", ["x=$(pip install evil==6.6.6)", "pip install evil==6.6.6"]),
    ("X04", "pip", "eval 'x=$(pip install evil==6.6.6)'", ["x=$(pip install evil==6.6.6)", "pip install evil==6.6.6"]),
    ("X05", "pip", "sh -c 'echo $(pip install evil==6.6.6)'", ["echo $(pip install evil==6.6.6)", "pip install evil==6.6.6"]),
    ("X06", "npm", "sh -c 'npm install evil@6.6.6 '\"--save\"", ["npm install evil@6.6.6 --save"]),
    ("X07", "npm", "eval $'npm install evil@6.6.6'", ["npm install evil@6.6.6"]),
    ("X08", "pip", "x=$(sh -c 'pip install evil==6.6.6')", ["sh -c 'pip install evil==6.6.6'", "pip install evil==6.6.6"]),
    ("X09", "pip", "sh -c $'echo a\\npip install evil==6.6.6'", ["echo a\npip install evil==6.6.6"]),
    ("X10", "pip", "eval $'echo a\\npip install evil==6.6.6'", ["echo a\npip install evil==6.6.6"]),
    ("X11", "pip", "sh -c $'pip\\tinstall evil==6.6.6'", ["pip\tinstall evil==6.6.6"]),
    ("X12", "npm", "sh -c $'echo a\\nnpm install evil@6.6.6'", ["echo a\nnpm install evil@6.6.6"]),
    ("X13", "pip", "bash -c $'echo a;pip install evil==6.6.6'", ["echo a;pip install evil==6.6.6"]),
    ("X14", "pip", "sh -c 'cat <<E\n$(date)\nE\npip install evil==6.6.6'", ["cat <<E\n$(date)\nE\npip install evil==6.6.6", "date"]),
    ("X15", "npm", "sh -c 'x=$(npm install evil@6.6.6)'", ["x=$(npm install evil@6.6.6)", "npm install evil@6.6.6"]),
    ("X16", "npm", "bash -c \"npm install evil@6.6.6 \\\"x\\\"\"", ["npm install evil@6.6.6 \"x\""]),
    ("Y01", "npm", "sh -c $'npm ci'", ["npm ci"]),
    ("Y02", "npm", "eval $'npm ci'", ["npm ci"]),
    ("Y03", "npm", "bash -c $'echo a\\nnpm ci'", ["echo a\nnpm ci"]),
    ("Y04", "npm", "x=$(echo \"\x1d\"; npm ci)", ["echo \"\x1d\"; npm ci"]),
    ("Y05", "npm", "sh -c 'echo \"\x1d\"; npm ci'", ["echo \"\x1d\"; npm ci"]),
    ("Y06", "npm", "sh -c \"npm ci \\\"x\\\"\"", ["npm ci \"x\""]),
    ("Y07", "npm", "sh -c 'npm ci'\"\"", ["npm ci"]),
    ("Y08", "npm", "sh -c 'x=$(npm ci)'", ["x=$(npm ci)", "npm ci"]),
    ("Y09", "pip", "sh -c 'sh -c \"x=\\$(pip install evil==6.6.6)\"'",
     ["sh -c \"x=\\$(pip install evil==6.6.6)\"", "x=$(pip install evil==6.6.6)", "pip install evil==6.6.6"]),
    ("Y10", "pip", "eval 'echo \"$(pip install evil==6.6.6)\"'",
     ["echo \"$(pip install evil==6.6.6)\"", "pip install evil==6.6.6"]),
]


def fill(template, byte, install):
    t = template.replace("{{", "\0L").replace("}}", "\0R")
    t = t.replace("{B}", chr(byte)).replace("{X}", "%02x" % byte).replace("{I}", install)
    return t.replace("\0L", "{").replace("\0R", "}")


def corpus():
    for cid, template, payloads in CARRIERS:
        for kind in ("pip", "npm"):
            for b in BYTES:
                yield {"id": "%s-%s-%02x" % (cid, kind, b), "kind": kind,
                       "text": fill(template, b, INSTALL[kind]),
                       "pl": [fill(p, b, INSTALL[kind]) for p in payloads]}
    for cid, template in DATA:
        for b in BYTES:
            yield {"id": "%s-data-%02x" % (cid, b), "kind": "data",
                   "text": fill(template, b, INSTALL["pip"]), "pl": []}


def ctl():
    for fid, text, payloads in LEX_FORMS:
        yield {"id": fid, "kind": "ctl", "text": text, "pl": payloads}
    for fid, kind, text, payloads in PATHS:
        yield {"id": fid, "kind": kind, "text": text, "pl": payloads}


if __name__ == "__main__":
    which = sys.argv[1] if len(sys.argv) > 1 else ""
    if which not in ("corpus", "ctl"):
        sys.exit("usage: payload-boundary-forms.py corpus|ctl")
    for form in (corpus() if which == "corpus" else ctl()):
        print(json.dumps(form))
