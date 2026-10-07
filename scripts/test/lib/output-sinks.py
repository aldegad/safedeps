#!/usr/bin/env python3
"""Run the public census checker on source copies, retaining each actual diff.

Controls do not compile or execute the inserted output. This gate judges source
occurrences, and these controls exercise exactly that public checking path.
"""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(sys.argv[1]).resolve()
TOOL = ROOT / 'scripts/measure/output-sinks.py'
REGISTRY = Path('scripts/measure/output-sinks.json')
spec = importlib.util.spec_from_file_location('output_sinks', TOOL)
census = importlib.util.module_from_spec(spec)
spec.loader.exec_module(census)


def run(root):
    return subprocess.run([sys.executable, str(TOOL), '--root', str(root), '--check'],
                          capture_output=True, text=True, timeout=30)


def main():
    log_base = os.environ.get('SAFEDEPS_TEST_LOG_DIR')
    logs = Path(log_base) / 'output-sinks.controls' if log_base else Path(tempfile.mkdtemp(prefix='output-sinks-logs.'))
    logs.mkdir(parents=True, exist_ok=True)
    failed = 0
    results = []

    def check(label, result, expected, witness=''):
        nonlocal failed
        output = result.stdout + result.stderr
        (logs / (label + '.log')).write_text(output)
        ok = result.returncode == expected and witness in output
        # The rejected mutations must differ at a generated census entry, not
        # merely die with a parser error or fail to find the source directory.
        if expected == 1:
            ok = ok and 'source census differs' in output and 'generated from rust/src' in output
        results.append(dict(name=label, rc=result.returncode, expected_rc=expected, passed=ok))
        print(('ok' if ok else 'not ok') + ' - output-sinks: ' + label)
        if not ok:
            failed += 1
            print(output[:4000])

    baseline = run(ROOT)
    check('committed-census', baseline, 0, 'ok - output-sinks:')
    if baseline.returncode:
        return 1
    with tempfile.TemporaryDirectory(prefix='output-sinks-copies.') as scratch:
        serial = 0

        def copy():
            nonlocal serial
            serial += 1
            root = Path(scratch) / str(serial)
            shutil.copytree(ROOT / 'rust/src', root / 'rust/src')
            (root / REGISTRY).parent.mkdir(parents=True)
            shutil.copyfile(ROOT / REGISTRY, root / REGISTRY)
            return root

        def append(root, text):
            with (root / 'rust/src/pre.rs').open('a') as out:
                out.write('\n' + text + '\n')

        mutations = [
            ('new-stdout', 'fn census_extra() { println!("synthetic stdout"); }', 'println'),
            ('new-stderr', 'fn census_extra() { std :: eprintln ! { "synthetic stderr" }; }', 'eprintln'),
            ('new-file-append', '''fn census_extra() {
                use std::io::Write;
                let mut file = std::fs::OpenOptions::new().create(true).append(true).open("advisory.log").unwrap();
                let _ = writeln!(file, "synthetic direct file claim");
            }''', 'writeln'),
            ('new-direct-log-string', '''fn census_extra() {
                crate::state::log_advisory(std::path::Path::new("."), b"awk failed");
            }''', 'log_advisory'),
            ('aliased-file-write', '''fn census_extra() {
                use std::fs::write as persist;
                let _ = persist("advisory.log", b"synthetic aliased claim");
            }''', 'persist'),
            ('non-test-cfg-output', '''#[cfg(unix)]
                fn census_extra() { eprintln!("synthetic platform claim"); }''', 'eprintln'),
        ]
        for label, source, witness in mutations:
            root = copy()
            append(root, source)
            check(label, run(root), 1, witness)

        root = copy()
        path = root / 'rust/src/post/providers.rs'
        source = path.read_text()
        original = 'eprintln!("safedeps providers: curl is required for provider queries");'
        if original not in source:
            raise ValueError('deletion control anchor is missing')
        path.write_text(source.replace(original, '', 1))
        check('removed-listed-stderr', run(root), 1, 'eprintln')

        root = copy()
        append(root, r'''// eprintln!("comment"); fs::write("log", b"comment");
            /* nested /* println!("comment") */ write!(file, "comment") */
            const CENSUS_QUOTE: &str = r###"user command: awk failed; cp exit 1; println!("data"); /*"###;
            const CENSUS_BYTES: &[u8] = br#"write_all; log_advisory; { }"#;
            #[cfg(test)] mod census_test_only { #[test] fn says() { eprintln!("test"); } }
            #[cfg(test)] mod output_sink_fake_tests;
        ''')
        (root / 'rust/src/pre/output_sink_fake_tests.rs').write_text('fn fixture() { println!("test"); }\n')
        check('quoted-data-comments-and-test-code', run(root), 0, 'ok - output-sinks:')

        # There is no string blacklist: a serializer's input can quote shell
        # diagnostics. Its sink remains in the census with a DATA role.
        root = copy()
        path = root / 'rust/src/pre/snapshot.rs'
        with path.open('a') as out:
            out.write('''\nfn census_quote(path: &std::path::Path, command: &[u8]) {
                let _ = std::fs::write(path, command);
                let _ = std::fs::write(path, b"user path: /awk failed/cp exit 1");
            }\n''')
        check('new-data-exits-still-require-review', run(root), 1, 'census_quote')
        rows = census.inventory(root)['files']['rust/src/pre/snapshot.rs']
        writes = [row for row in rows if row['scope'] == 'census_quote' and row['operation'] == 'write']
        ok = len(writes) == 2 and all(row['role'] == 'data' for row in writes)
        print(('ok' if ok else 'not ok') + ' - output-sinks: command/path bytes are data, not authored claims')
        results.append(dict(name='data-role', passed=ok, rows=writes))
        failed += not ok

    (logs / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    print('# output-sinks control logs: ' + str(logs))
    return int(bool(failed))


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print('not ok - output-sinks: ' + str(error))
        sys.exit(1)
