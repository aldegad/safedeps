#!/usr/bin/env bash
# Native reader corpus regression. The former grep batch/single comparison
# is retired: Rust runs neither that grep batch nor its line-number mapping.
# The original corpora and seeded command generator remain reader inputs.
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "${ROOT_DIR}"
# shellcheck source=lib/core-reader.sh
source "${ROOT_DIR}/scripts/test/lib/core-reader.sh"
core_reader_init "${ROOT_DIR}"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/safedeps-statement-corpus.XXXXXX")
trap 'rm -rf "${TMP_ROOT}"' EXIT
python3 - > "${TMP_ROOT}/random" <<'PY'
import random, sys
# Seeded random commands from the pieces the lexer decides on, and statements
# of the shapes a statement reader hands it one at a time.
rnd = random.Random(20261005)
pal = ["npm install x", "pip install evil==1.0", "sh -c '", "bash -c \"", "eval ", "eval \"npm ci\"", "\"", "'",
       "\\", "\\\n", "$(", ")", "`", "${", "}", "((", "))", "<<EOF\n", "<<'E'\n", "<<-T\n", "\nEOF\n", "\nE\n",
       "\n\tT\n", "|", "||", "&&", ";", "&", "\n", "#", " ", "\t", "env A=b ", "FOO=\"a b\" ", "exec -a n ",
       "command -p ", "time -p ", "$'\\x41\\n'", "{ ", " }", "( ", " )", "case x in a) ", ";; esac", "> f ",
       "2>&1 ", "| sh", "/bin/sh -c ", "ksh -c ", "--", "cd /tmp && ", "npx a@1", "yarn add y", "f() { ",
       "(1)", "$x", "$[1]", "!", "if true; then ", "fi"]
out = []
for i in range(120):
    parts = []; target = rnd.choice([20, 80, 300, 2000])
    while sum(map(len, parts)) < target: parts.append(rnd.choice(pal))
    out.append("".join(parts))
unit = "f() { echo 'a b' \"$x\" (1); }; "
out += [unit, unit * 3, "echo line", "echo line7", "npm install left-pad@1.0.0", "", " ", "x" * 5000,
        "sh -c \"" + unit.replace('"', '\\"') * 4 + "\""]
sys.stdout.write("".join(s + "\0" for s in out))
PY

python3 "${ROOT_DIR}/scripts/test/lib/core-reader-check.py" "${SAFEDEPS_TEST_CORE}" corpus "${TMP_ROOT}/random"
