#!/usr/bin/env python3
"""Generate the Rust core's output-boundary census; --check compares it exactly.

An exit is a source occurrence, not a permitted function name. We count stream
writes (including the hooks' JSON), file writes/appends, and calls of the core's
advisory/report writers. The latter catch a new direct log string even though
the physical append already exists. Human records include advisory/reorg logs,
journals and incidents. Serializers, snapshots, copies, captured child output
and measurement echoes are DATA exits: their bytes are not authored claims.
Opening/configuring an output, output API imports, FFI and macro definitions are BOUNDARY
entries, not claims. They make a new alias, child stream or foreign/macro escape
require review too. All three roles are checked; DATA is not an exemption.

The generator lexes rust/src, removes comments and literal contents from syntax
recognition, balances delimiters, and excludes only items marked cfg(test) or
test and the modules they declare. Other cfg branches are all counted. It does
not use a hand-maintained list of source sites. The vocabulary below describes
operations, and classification describes their roles, not their permission.
Matching is conservative: an in-memory append or a path helper named copy is
also listed as DATA. Counts are source candidates, not counts of physical I/O.
Identity is (file, function, role, exit kind, callee, argument origin kinds).
The count of that identity catches another call even if its name is already
listed. No source position, expression text or containing-function hash is
part of identity: an unrelated edit in that function must stay green. Each
identity occupies one TSV line, sorted deterministically.

Human argument origins are syntactic, not a type proof: fixed-literal,
result-renderer (the explicitly named result API), data-field (a binding or
field access), and other. Computations/calls not recognized as the renderer
stay other. A change of origin kind is red; different bytes of the same kind
are the output oracle's concern. In particular no string blacklist reads
user commands, paths or quoted data. Raw data writes have origin '-'.

BOUNDARY rows change only when the counts/names of output capabilities, output
API imports (including aliases), FFI declarations, or macro definitions change.
Ordinary collection/type imports are absent. An output import's identity is
its imported path and alias, not the whole use tree, so adding Vec beside File
does not change it. Macro bodies/foreign implementations are not expanded or
hashed: this gate requires review of new boundaries, not every body edit.

This is a lexical source gate, not Rust type/taint analysis or a truth oracle.
It covers this dependency-free core's explicit Rust output operations, not
implicit panic/OOM diagnostics in the runtime, or child programs' own code.
Import/FFI/macro entries close additions of other APIs for review; they do not
prove arbitrary future APIs safe. Review a diff before regenerating. The output
oracle owns the truth of rendered claims. No word blacklist examines data.

Usage (repository root, Python 3 stdlib only):
  python3 scripts/measure/output-sinks.py --generate
  python3 scripts/measure/output-sinks.py --check
--root selects a source copy. Generation alone writes output-sinks.tsv; checking
never updates the committed expectation. Parse/read errors fail the command.
"""
import argparse
from collections import Counter
import difflib
import json
from pathlib import Path
import re
import sys

REGISTRY = Path('scripts/measure/output-sinks.tsv')
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
DATA_MACROS = set('format format_args vec matches concat concat_bytes stringify env option_env '
                  'include_str include_bytes cfg file line column module_path'.split())
# Only the closed result API belongs here; report::io_outcome's free actor
# argument is not one. Unknown rendering calls are conservatively "other".
RESULT_RENDERERS = {'Outcome::describe'}


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
        token = text[start:i]
        out.append(token[2:] if token.startswith('r#') and IDENT.fullmatch(token) else token)
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


def use_end(ts, ps, start):
    i = start
    while i < len(ts):
        if ts[i] == ';': return i+1
        if ts[i] in ('(', '[', '{'): i = ps[i]
        i += 1
    raise ValueError('use has no semicolon')


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
        return 'boundary', 'capability'
    if name in ('write', 'append') and expression[-3:] in (['(', 'true', ')'], ['(', 'false', ')']):
        return 'boundary', 'file-mode'
    if 'stderr' in expression:
        return 'human', 'stderr'
    if name in COPIES:
        return 'data', 'copy-or-publish'
    if name in HUMAN:
        return 'human', 'log-or-report'
    if name in ('eprint', 'eprintln', 'dbg', 'panic', 'assert', 'assert_eq', 'assert_ne',
                'unreachable', 'unimplemented', 'todo'):
        return 'human', 'diagnostic'
    if path == 'rust/src/post/journal.rs':
        return 'human', 'journal-or-reorg'
    if name == 'append' and path in ('rust/src/state/log.rs', 'rust/src/post/providers.rs',
                                    'rust/src/post/run.rs', 'rust/src/post/rollback.rs'):
        return 'human', 'advisory-or-reorg'
    if path == 'rust/src/state.rs' and scope == 'log_advisory':
        return 'human', 'advisory'
    if path == 'rust/src/state/log.rs' and scope == 'append':
        return 'human', 'advisory-rotation'
    if path == 'rust/src/pre.rs' or (path == 'rust/src/post/run.rs' and scope == 'main'):
        # The pre hook's trace records are serialized data, unlike its answers.
        if name == 'write_state_file': return 'data', 'serialized-trace'
        return 'human', 'hook-answer'
    if path == 'rust/src/main.rs' and 'deny' in expression:
        return 'human', 'hook-answer'
    if path == 'rust/src/lex.rs': return 'data', 'lexer-record'
    return 'data', 'raw-or-serialized'


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


def use_paths(tokens, prefix=()):
    """Flatten Rust use trees so unrelated members do not change an import."""
    parts, start, depth = [], 0, 0
    for i, token in enumerate(tokens + [',']):
        if token == '{': depth += 1
        elif token == '}': depth -= 1
        elif token == ',' and depth == 0:
            parts.append(tokens[start:i]); start = i+1
    paths = []
    for part in parts:
        if not part: continue
        if '{' in part:
            at = part.index('{')
            paths.extend(use_paths(part[at+1:-1], prefix + tuple(t for t in part[:at] if t != '::')))
        else:
            alias = None
            if 'as' in part:
                at = part.index('as'); alias = part[at+1]; part = part[:at]
            names = prefix + tuple(t for t in part if t != '::' and t != 'self')
            paths.append(('::'.join(names), alias))
    return paths


def output_import(path):
    parts = path.split('::')
    standard = {
        'std::fs', 'std::io', 'std::process', 'std::io::Write',
        'std::io::BufWriter', 'std::io::LineWriter', 'std::io::Stdout', 'std::io::Stderr',
        'std::os::unix::fs::FileExt', 'std::os::windows::fs::FileExt',
        'std::os::fd::FromRawFd', 'std::os::unix::io::FromRawFd',
        'std::os::windows::io::FromRawHandle',
    }
    return path in standard or path in ('std::fs::*', 'std::io::*', 'std::process::*') or \
        parts[-1] in HUMAN | WRITES | COPIES | CAPABILITIES | MACROS


def arguments(ts):
    if not ts: return []
    ps = pairs(ts)
    args, start, i = [], 0, 0
    while i < len(ts):
        if ts[i] in ('(', '[', '{'): i = ps[i]
        elif ts[i] == ',': args.append(ts[start:i]); start = i+1
        i += 1
    if start < len(ts): args.append(ts[start:])
    return args


def origin(arg, bindings=None, typed=(), visiting=()):
    bindings = bindings or {}
    while arg and arg[0] == '&': arg = arg[1:]
    if not arg: return 'other'
    # Literal conversion methods do not turn a literal into a computed claim.
    if arg[-4:] in (['.', 'as_bytes', '(', ')'], ['.', 'to_vec', '(', ')']): arg = arg[:-4]
    if len(arg) == 1 and (arg[0].startswith(('"', 'b"', 'r"', 'br"', 'r#', 'br#'))):
        return 'fixed-literal'
    ps = pairs(arg)
    # Recognize the named API directly or as a method on an explicit Outcome
    # constructor / Outcome-typed parameter. Unknown receiver types stay other.
    if arg[-1] == ')' and ps[len(arg)-1] > 0:
        at = ps[len(arg)-1]
        callee = ''.join(arg[:at])
        if callee.removeprefix('crate::outcome::') in RESULT_RENDERERS:
            return 'result-renderer'
        if at >= 2 and arg[at-2:at] == ['.', 'describe'] and 'Outcome::describe' in RESULT_RENDERERS:
            receiver = arg[:at-2]
            receiver_text = ''.join(receiver).removeprefix('crate::outcome::')
            if receiver_text.startswith('Outcome::') or receiver_text in typed:
                return 'result-renderer'
        # These compose/convert bytes; all other calls are opaque.
        if callee in ('cat', 'report::cat', 'format!', 'jq::text', 'jv::s'):
            pieces = arg[at+1:-1]
            if callee.endswith('cat') and pieces[:2] == ['&', '['] and pieces[-1:] == [']']:
                pieces = pieces[2:-1]
            kinds = set()
            for piece in arguments(pieces): kinds.update(origin(piece, bindings, typed, visiting).split('+'))
            return '+'.join(sorted(kinds)) or 'other'
    if len(arg) == 1 and arg[0] in bindings:
        if arg[0] in visiting or bindings[arg[0]] is None: return 'other'
        return origin(bindings[arg[0]], bindings, typed, visiting + (arg[0],))
    if re.fullmatch(r'(?:r#)?[A-Za-z_]\w*(?:\.(?:[A-Za-z_]\w*|[0-9]+))*', ''.join(arg)):
        return 'data-field'
    return 'other'


def local_origins(ts):
    """Only unambiguous immutable let bindings; no interprocedural inference."""
    ps = pairs(ts)
    bindings, typed = {}, set()
    for i, t in enumerate(ts):
        if t == ':' and i and i+1 < len(ts):
            j = i+1
            while j < len(ts) and ts[j] in ('&', 'mut'): j += 1
            if ts[j:j+1] == ['Outcome'] or ts[j:j+5] == ['crate', '::', 'outcome', '::', 'Outcome']:
                typed.add(ts[i-1])
        if t != 'let' or i+2 >= len(ts): continue
        name, eq = ts[i+1], i+2
        if not IDENT.fullmatch(name) or name == 'mut': continue
        if ts[eq] != '=': continue
        end = eq+1
        while end < len(ts) and ts[end] != ';':
            if ts[end] in ('(', '[', '{'): end = ps[end]
            end += 1
        if end == len(ts): continue
        # Duplicate/shadowed or reassigned names are deliberately opaque.
        writes = sum(ts[j] == name and ts[j+1:j+2] == ['='] and ts[j+2:j+3] != ['=']
                     for j in range(len(ts)-2))
        bindings[name] = ts[eq+1:end] if writes == 1 else None
    return bindings, typed


def origins(name, args, bindings, typed):
    # Omit destinations and logger levels; classify the payload, not its path.
    if name in HUMAN | WRITES and name not in ('write',): args = args[-1:]
    if name in ('write', 'writeln'): args = args[1:]
    kinds = set()
    for arg in args: kinds.update(origin(arg, bindings, typed).split('+'))
    return '+'.join(sorted(kinds)) or 'other'


def entries(path, ts, foreign_names):
    ps = pairs(ts)
    scopes = functions(ts, ps)
    aliases, declarations = {}, set()
    for i, t in enumerate(ts):
        if t == 'use':
            end = use_end(ts, ps, i)
            declarations.update(range(i+1, end))
            for imported, alias in use_paths(ts[i+1:end-1]):
                if alias and output_import(imported): aliases[alias] = imported.split('::')[-1]
    rows = []
    provenance = {(a, b): local_origins(ts[a:b]) for a, b, _ in scopes}
    def add(scope, kind, channel, callee, source='-'):
        rows.append(dict(file=path, function=scope, role=kind, exit=channel, callee=callee, origins=source))

    for i, t in enumerate(ts):
        if not IDENT.fullmatch(t): continue
        if i in declarations: continue
        name = aliases.get(t, t)
        before = ts[i-1] if i else ''
        after = ts[i+1] if i+1 < len(ts) else ''
        structural = t in ('use', 'extern', 'macro_rules')
        if not structural:
            if before == 'fn': continue
            if after == '!' and name not in DATA_MACROS and ts[i+2:i+3] in (['('], ['{'], ['[']): pass
            elif name in foreign_names and after == '(': pass
            elif name in HUMAN | WRITES | COPIES | CAPABILITIES:
                if before not in ('.', '::') and after not in ('(', '::'): continue
                # Merely reading child.stdout or record.status is no capability.
                if name in CAPABILITIES and after not in ('(', '::'): continue
            else: continue
        # Every enclosing scope is considered; the innermost function owns it.
        containing = [(a, b, n) for a, b, n in scopes if a <= i < b]
        start, stop, scope = min(containing, key=lambda x: x[1]-x[0]) if containing else (0, len(ts), '<module>')
        end = i + 1
        if structural:
            end = use_end(ts, ps, i) if t == 'use' else item_end(ts, ps, i)
            if t == 'use':
                for imported, alias in use_paths(ts[i+1:end-1]):
                    if output_import(imported):
                        add(scope, 'boundary', 'import', imported + (' as '+alias if alias else ''))
            elif t == 'extern':
                # Names/signatures remain visible without pinning bodies or offsets.
                for j in range(i, end-1):
                    if ts[j] == 'fn': add(scope, 'boundary', 'foreign-function', ts[j+1])
            else:
                add(scope, 'boundary', 'macro-definition', ts[i+2])
            continue
        else:
            # Include the qualified callee and arguments, including macro groups.
            j = i+1
            if j < len(ts) and ts[j] == '!': j += 1
            if j < len(ts) and ts[j] in ('(', '[', '{'): end = ps[j]+1
        begin = i
        if i and ts[i-1] in ('.', '::'): begin = receiver_start(ts, ps, i)
        expression = ts[begin:end]
        kind, channel = role(path, scope, name, expression)
        if after == '!' and name not in MACROS: kind, channel = 'boundary', 'macro-call'
        if name in foreign_names: kind, channel = 'boundary', 'foreign-call'
        # For methods the callee is the method name, not the receiver expression.
        # Qualified free-function names keep their namespace.
        qualified = i
        while qualified >= 2 and ts[qualified-1] == '::' and IDENT.fullmatch(ts[qualified-2]): qualified -= 2
        callee = ''.join(ts[qualified:i+1]) + ('!' if after == '!' else '')
        j = i+2 if after == '!' else i+1
        args = arguments(ts[j+1:end-1]) if j < len(ts) and ts[j] in ('(', '[', '{') else []
        bindings, typed = provenance.get((start, stop), ({}, set()))
        source = origins(name, args, bindings, typed) if kind == 'human' else '-'
        add(scope, kind, channel, callee, source)
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
    rows = []
    foreign_names = set()
    for path, ts in parsed.items():
        if path.resolve() in excluded: continue
        ps = pairs(ts)
        for i, t in enumerate(ts):
            if t == 'extern':
                end = item_end(ts, ps, i)
                foreign_names.update(ts[j+1] for j in range(i, end-1) if ts[j] == 'fn')
    for path, ts in parsed.items():
        if path.resolve() in excluded: continue
        rel = path.relative_to(root).as_posix()
        rows.extend(entries(rel, ts, foreign_names))
    counts = Counter(tuple(row[key] for key in COLUMNS[:-1]) for row in rows)
    return [dict(zip(COLUMNS, key + (count,))) for key, count in sorted(counts.items())]


COLUMNS = ('file', 'function', 'role', 'exit', 'callee', 'origins', 'count')


def encoded(value):
    return '\t'.join(COLUMNS) + '\n' + ''.join('\t'.join(str(row[k]) for k in COLUMNS) + '\n' for row in value)


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
        counts = Counter()
        for row in result: counts[row['role']] += row['count']
        print(('generated' if args.generate else 'ok') + ' - output-sinks: ' +
              ', '.join(f'{n} {kind}' for kind, n in sorted(counts.items())) +
              f"; {len(result)} identities")
        return 0
    except (OSError, ValueError, KeyError) as error:
        print('not ok - output-sinks: ' + str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
