#!/usr/bin/env python3
"""The control for scripts/measure/inert-downgrade-rule.py.

Each mutation drops, narrows or widens one clause of the rule. Run against a
grid table whose head is v2.18.0 (main 2d96377), each must leave mismatches,
or the zero the rule reports says nothing about that clause. The mutated rule
is written to a temporary file and thrown away; the rule itself is never
edited.

The first ten came with the rule; the last three undo the review's
corrections (every verb, not any; a verb that ends the command; an npm
inside the ksh script, not anywhere in the command).

usage: scripts/measure/inert-downgrade-rule-mutations.py <table.tsv>...
Prints one line per mutation and exits non-zero when one is not red.
"""
import os
import subprocess
import sys
import tempfile

RULE = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'inert-downgrade-rule.py')

MUTATIONS = {
    'drop ksh clause': ("if re.search(r'\\bksh", "if False and re.search(r'\\bksh"),
    'drop $( from dq clause': ("r'\\\\|`|\\$\\('", "r'\\\\|`'"),
    'drop backslash from dq': ("r'\\\\|`|\\$\\('", "r'`|\\$\\('"),
    'drop backquote from dq': ("r'\\\\|`|\\$\\('", "r'\\\\|\\$\\('"),
    'add $VAR to dq clause': ("r'\\\\|`|\\$\\('", "r'\\\\|`|\\$'"),
    'drop heredoc-pipe clause': ("if '|' in opener and", "if False and"),
    'heredoc without pipe too': ("if '|' in opener and", "if True and"),
    'drop lone-eval landing': ("return bool(re.match(r'\\s*eval\\s', cmd))", "return False"),
    'eval only in compound': ("|\\beval)\\s+", ")\\s+"),
    'sq scripts also unreadable': ("for s in dq_scripts(cmd):",
                                   "for s in dq_scripts(cmd) + re.findall(r\"(?:-c|eval)\\s+'([^']*)'\", cmd):"),
    'any verb, not every': ("return bool(vs) and all(", "return bool(vs) and any("),
    'verb ending the command does not count': ("e == len(cmd) or cmd[e].isspace()", "cmd[e:e + 1].isspace()"),
    'ksh with npm anywhere': ("if re.search(r'\\bksh\\s+-[a-z]*c\\s+(\"(?:[^\"\\\\]|\\\\.)*npm|\\'[^\\']*npm|\\S*npm)', cmd):",
                              "if re.search(r'\\bksh\\s+-[a-z]*c\\b', cmd) and 'npm' in cmd:"),
}


def main(tables):
    src = open(RULE).read()
    rc = 0
    with tempfile.TemporaryDirectory() as tmp:
        for name, (old, new) in MUTATIONS.items():
            if src.count(old) != 1:
                print(f'{name}: DID NOT APPLY')
                rc = 1
                continue
            path = os.path.join(tmp, 'rule.py')
            with open(path, 'w') as f:
                f.write(src.replace(old, new))
            r = subprocess.run([sys.executable, path] + tables, capture_output=True, text=True)
            last = (r.stdout.strip().split('\n') or [''])[-1]
            red = r.returncode == 0 and 'mismatches=' in last and not last.endswith('mismatches=0')
            print(f'{name}: {last}{"" if red else "  NOT RED"}{" ERR " + r.stderr.strip().splitlines()[-1] if r.returncode else ""}')
            rc |= 0 if red else 1
    return rc


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
