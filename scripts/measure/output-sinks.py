#!/usr/bin/env python3
"""Generate the Rust core's output-boundary census; --check compares it exactly.

An exit is a source occurrence, not a permitted function name. We count stream
writes (including the hooks' JSON), file writes/appends, and calls of the core's
advisory/report writers. The latter catch a new direct log string even though
the physical append already exists. Human records include advisory/reorg logs,
journals and incidents. Serializers, snapshots, copies, captured child output
and measurement echoes are DATA exits: their bytes are not authored claims.
Opening/configuring an output, imports, FFI and macro definitions are BOUNDARY
entries, not claims. They make a new alias, child stream or foreign/macro escape
require review too. All three roles are checked; DATA is not an exemption.

The generator lexes rust/src, removes comments and literal contents from syntax
recognition, balances delimiters, and excludes only items marked cfg(test) or
test and the modules they declare. Other cfg branches are all counted. It does
not use a hand-maintained list of source sites. The vocabulary below describes
operations, and classification describes their roles, not their permission.
Matching is conservative: an in-memory append or a path helper named copy is
also listed as DATA. Counts are source candidates, not counts of physical I/O.
Each entry holds its expression and a token hash of its containing function:
changing a target/value upstream of a write also requires review. Whitespace,
comments and test-only edits do not change that hash. Offsets are token ordinals
within that function, so two identical writes are still two entries.

This is a lexical source gate, not Rust type/taint analysis or a truth oracle.
It covers this dependency-free core's explicit Rust output operations, not
implicit panic/OOM diagnostics in the runtime, or child programs' own code.
Import/FFI/macro entries close additions of other APIs for review; they do not
prove arbitrary future APIs safe. Review a diff before regenerating. The output
oracle owns the truth of rendered claims. No word blacklist examines data.

Usage (repository root, Python 3 stdlib only):
  python3 scripts/measure/output-sinks.py --generate
  python3 scripts/measure/output-sinks.py --check
--root selects a source copy. Generation alone writes output-sinks.json; checking
never updates the committed expectation. Parse/read errors fail the command.
"""
import argparse
from collections import Counter
import difflib
import hashlib
import json
from pathlib import Path
import re
import sys

REGISTRY = Path('scripts/measure/output-sinks.json')
IDENT = re.compile(r'(?:r#)?[A-Za-z_][A-Za-z_0-9]*')
RAW = re.compile(r'(?:br|cr|r)(#*)"')
CHAR = re.compile(r"(?:b)?'(?:\\(?:u\{[0-9a-fA-F_]+\}|x[0-9a-fA-F]{2}|[^\n])|[^'\\\n])'")
HUMAN = set('log_advisory log_command raw_log log say warn'.split())
WRITES = set('write write_all write_fmt write_vectored write_all_vectored write_at write_all_at '
             'write_state_file write_renamed append'.split())
COPIES = set('copy copy_file copy_state_file renamed_file rename'.split())
CAPABILITIES = set('stdout stderr File OpenOptions Stdio Command create create_new open '
                   'truncate flush set_len spawn status output from_raw_fd from_raw_handle'.split())
MACROS = set('print println eprint eprintln write writeln dbg panic assert assert_eq assert_ne '
             'unreachable unimplemented todo'.split())


def lex(text):
    """Keep literal tokens intact for hashing, never search inside them."""
    out = []
    i = 0
    while i < len(text):
        if text[i].isspace():
            i += 1
            continue
        if text.startswith('//', i):
            end = text.find('\n', i)
            i = len(text) if end < 0 else end + 1
            continue
        if text.startswith('/*', i):
            depth = 1
            i += 2
            while depth and i < len(text):
                if text.startswith('/*', i): depth += 1; i += 2
                elif text.startswith('*/', i): depth -= 1; i += 2
                else: i += 1
            if depth: raise ValueError('unterminated block comment')
            continue
        start = i
        raw = RAW.match(text, i)
        char = CHAR.match(text, i)
        if raw:
            end = text.find('"' + raw[1], raw.end())
            if end < 0: raise ValueError('unterminated raw string')
            i = end + 1 + len(raw[1])
        elif char:
            i = char.end()
        elif text[i] == '"' or text[i:i+2] in ('b"', 'c"'):
            i += 1 if text[i] == '"' else 2
            while i < len(text) and text[i] != '"':
                i += 2 if text[i] == '\\' else 1
            if i >= len(text): raise ValueError('unterminated string')
            i += 1
        else:
            word = IDENT.match(text, i)
            if word: i = word.end()
            elif text.startswith('::', i): i += 2
            else: i += 1
        out.append(text[start:i])
    return out


def pairs(tokens):
    stack, matched = [], {}
    for i, t in enumerate(tokens):
        if t in ('(', '[', '{'): stack.append((i, t))
        elif t in (')', ']', '}'):
            if not stack or stack[-1][1] != {')': '(', ']': '[', '}': '{'}[t]:
                raise ValueError('unbalanced delimiter at token ' + str(i))
            start, _ = stack.pop()
            matched[start] = i
            matched[i] = start
    if stack: raise ValueError('unclosed delimiter')
    return matched


def item_end(tokens, matched, start):
    """End of an attributed item; nested groups before its body are skipped."""
    i = start
    while i < len(tokens):
        if tokens[i] == ';': return i + 1
        if tokens[i] == '{': return matched[i] + 1
        if tokens[i] in ('(', '['): i = matched[i]
        i += 1
    raise ValueError('item has no end')


def production(path):
    ts = lex(path.read_text())
    ps = pairs(ts)
    keep, excluded = [], []
    i = 0
    while i < len(ts):
        start = i
        attrs = []
        while i + 1 < len(ts) and ts[i:i+2] == ['#', '[']:
            end = ps[i+1]
            attrs.append(ts[i+2:end])
            i = end + 1
        if ['cfg', '(', 'test', ')'] in attrs or ['test'] in attrs:
            end = item_end(ts, ps, i)
            item = ts[i:end]
            if len(item) >= 3 and item[0] == 'mod' and item[2] == ';':
                explicit = next((a[2] for a in attrs if a[:2] == ['path', '=']), None)
                if explicit:
                    excluded.append(path.parent / json.loads(explicit))
                else:
                    base = path.parent if path.name in ('main.rs', 'lib.rs', 'mod.rs') else path.with_suffix('')
                    candidates = [base / (item[1]+'.rs'), base / item[1] / 'mod.rs']
                    found = [p for p in candidates if p.exists()]
                    if len(found) != 1: raise ValueError('cannot resolve test module ' + item[1])
                    excluded.extend(found)
            i = end
        else:
            keep.extend(ts[start:i+1])
            i += 1
    return keep, excluded


def functions(ts, ps):
    scopes = []
    for i, t in enumerate(ts):
        if t != 'fn' or i+2 >= len(ts) or not IDENT.fullmatch(ts[i+1]): continue
        j = i + 2
        while j < len(ts) and ts[j] not in ('{', ';'):
            if ts[j] in ('(', '['): j = ps[j]
            j += 1
        if j < len(ts) and ts[j] == '{':
            scopes.append((i, ps[j]+1, ts[i+1]))
    return scopes


def role(path, scope, name, expression):
    """Semantic roles of existing APIs; never suppress a candidate by role."""
    if name in ('use', 'extern', 'macro_rules') or name in CAPABILITIES:
        return 'boundary', 'output capability / import / foreign or macro code'
    if name in ('write', 'append') and expression[-3:] in (['(', 'true', ')'], ['(', 'false', ')']):
        return 'boundary', 'file open mode'
    if 'stderr' in expression:
        return 'human', 'stderr'
    if name in COPIES:
        return 'data', 'byte copy / path helper / publication of a stored record'
    if name in HUMAN:
        return 'human', 'advisory or staged hook/report output'
    if name in ('eprint', 'eprintln', 'dbg', 'panic', 'assert', 'assert_eq', 'assert_ne',
                'unreachable', 'unimplemented', 'todo'):
        return 'human', 'stderr / explicit diagnostic'
    if path == 'rust/src/post/journal.rs':
        return 'human', 'journal / incident / reorg record'
    if name == 'append' and path in ('rust/src/state/log.rs', 'rust/src/post/providers.rs',
                                    'rust/src/post/run.rs', 'rust/src/post/rollback.rs'):
        return 'human', 'advisory / reorg record'
    if path == 'rust/src/state.rs' and scope == 'log_advisory':
        return 'human', 'advisory record'
    if path == 'rust/src/state/log.rs' and scope == 'append':
        return 'human', 'advisory rotation report'
    if path == 'rust/src/pre.rs' or (path == 'rust/src/post/run.rs' and scope == 'main'):
        # The pre hook's trace records are serialized data, unlike its answers.
        if name == 'write_state_file': return 'data', 'serialized call trace'
        return 'human', 'hook JSON / stderr'
    if path == 'rust/src/main.rs' and 'deny' in expression:
        return 'human', 'hook JSON'
    if path == 'rust/src/lex.rs': return 'data', 'lexer side records'
    return 'data', 'raw bytes / serialization / copy / measurement echo'


def receiver_start(ts, ps, index):
    """A method receiver/path, backwards across balanced call/index groups."""
    at = index
    while at:
        if ts[at-1] in ('.', '::'):
            at -= 1
        elif ts[at-1] == '?' or ts[at-1] in (')', ']'):
            at = ps[at-1] if ts[at-1] in (')', ']') else at-1
        elif IDENT.fullmatch(ts[at-1]):
            at -= 1
            if at == 0 or ts[at-1] not in ('.', '::'): break
        else: break
    return at


def entries(path, ts):
    ps = pairs(ts)
    scopes = functions(ts, ps)
    rows = []
    for i, t in enumerate(ts):
        if not IDENT.fullmatch(t): continue
        before = ts[i-1] if i else ''
        after = ts[i+1] if i+1 < len(ts) else ''
        structural = t in ('use', 'extern', 'macro_rules')
        if not structural:
            if before == 'fn': continue
            if t in MACROS and after == '!': pass
            elif t in HUMAN | WRITES | COPIES | CAPABILITIES:
                if before not in ('.', '::') and after not in ('(', '::'): continue
            else: continue
        # Every enclosing scope is considered; the innermost function owns it.
        containing = [(a, b, n) for a, b, n in scopes if a <= i < b]
        start, stop, scope = min(containing, key=lambda x: x[1]-x[0]) if containing else (0, len(ts), '<module>')
        end = i + 1
        if structural:
            end = item_end(ts, ps, i)
        else:
            # Include the qualified callee and arguments, including macro groups.
            j = i+1
            if j < len(ts) and ts[j] == '!': j += 1
            if j < len(ts) and ts[j] in ('(', '[', '{'): end = ps[j]+1
        begin = i
        if i and ts[i-1] in ('.', '::'): begin = receiver_start(ts, ps, i)
        expression = ts[begin:end]
        kind, channel = role(path, scope, t, expression)
        # Module imports have their own tokens as the review boundary; do not
        # hash unrelated functions merely because an import is outside them.
        body = ts[start:stop] if containing else expression
        digest = hashlib.sha256(json.dumps(body, ensure_ascii=False).encode()).hexdigest()
        rows.append(dict(scope=scope, token=i-start, operation=t, role=kind, channel=channel,
                         expression=' '.join(expression), owner_sha256=digest))
    return rows


def inventory(root):
    paths = sorted((root / 'rust/src').rglob('*.rs'))
    if not paths: raise ValueError('rust/src contains no Rust source')
    parsed = {}
    excluded = set()
    for path in paths:
        tokens, tests = production(path)
        parsed[path] = tokens
        excluded.update(p.resolve() for p in tests)
    # External test-only module trees are excluded with their descendants.
    for path in list(excluded):
        base = path.parent if path.name == 'mod.rs' else path.with_suffix('')
        if base.is_dir(): excluded.update(p.resolve() for p in base.rglob('*.rs'))
    files = {}
    for path, ts in parsed.items():
        if path.resolve() in excluded: continue
        rel = path.relative_to(root).as_posix()
        files[rel] = entries(rel, ts)
    return dict(schema=1, files=files)


def encoded(value):
    return json.dumps(value, indent=2, ensure_ascii=False) + '\n'


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[2])
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument('--generate', action='store_true')
    mode.add_argument('--check', action='store_true')
    args = ap.parse_args()
    try:
        result = inventory(args.root)
        actual = encoded(result)
        target = args.root / REGISTRY
        if args.generate:
            target.write_text(actual)
        else:
            expected = target.read_text()
            if expected != actual:
                sys.stdout.writelines(difflib.unified_diff(expected.splitlines(True), actual.splitlines(True),
                                                         fromfile=str(REGISTRY), tofile='generated from rust/src'))
                print('not ok - output-sinks: source census differs; review before --generate')
                return 1
        counts = Counter(row['role'] for rows in result['files'].values() for row in rows)
        print(('generated' if args.generate else 'ok') + ' - output-sinks: ' +
              ', '.join(f'{n} {kind}' for kind, n in sorted(counts.items())) +
              f"; {len(result['files'])} production files")
        return 0
    except (OSError, ValueError, KeyError) as error:
        print('not ok - output-sinks: ' + str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
