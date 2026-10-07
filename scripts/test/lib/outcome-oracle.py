#!/usr/bin/env python3
"""Closed result forms, checked against observations owned by the fixture.

These receipts are made by the test, never by the hook or its renderer.
Unobserved variants have no passing receipt merely because their words match.
"""
import json
from pathlib import Path
import re
import subprocess
import sys


def rebuild(receipt, line):
    observed = json.loads(Path(receipt).read_text())
    calls = [json.loads(row) for row in Path(observed['calls']).read_text().splitlines()]
    if observed['kind'] == 'start':
        assert any(row['argv'][0] == 'query' for row in calls)
        assert all(row['argv'][0] != 'rebuild' for row in calls)
        assert not Path(observed['npm']).exists()
        try:
            subprocess.run([observed['npm'], 'rebuild'], check=False, capture_output=True)
        except OSError as error:
            errno = error.errno
        else:
            raise AssertionError('the missing npm unexpectedly started')
        assert errno == observed['errno']
        assert re.fullmatch(r'could not start npm rebuild: OS error ([0-9]+)', line)
        assert line == f'could not start npm rebuild: OS error {errno}'
        return 'start'
    if observed['kind'] == 'signal':
        runs = [row for row in calls if row['argv'][0] == 'rebuild']
        assert len(runs) == 1 and runs[0]['pid'] == observed['pid']
        assert observed['signal'] == 9 and observed['kill_returned'] is True
        assert re.fullmatch(r'npm rebuild terminated by signal ([0-9]+)', line)
        assert line == 'npm rebuild terminated by signal 9'
        return 'signal'
    raise AssertionError('no independent observation for this rebuild outcome')


def walk(observed, line):
    target = observed['permission']['path']
    try:
        with __import__('os').scandir(target) as entries:
            list(entries)
    except PermissionError as error:
        errno = error.errno
    else:
        raise AssertionError('the walk permission failure disappeared')
    assert errno == observed['permission']['errno']
    assert re.fullmatch(r'the walk of (.+) returned OS error ([0-9]+)', line)
    assert line == f'the walk of {Path(target).parent} returned OS error {errno}'


def npm_failure(observed, line):
    # The standalone invocation observes a signal as a negative returncode;
    # the production Rust code obtains an ExitStatus, a different interface.
    signal = -observed['returncode']
    assert signal > 0
    match = re.fullmatch(r'npm (config|query|prefix|root) failed \(signal ([0-9]+): no output\)(.*)', line)
    assert match and int(match[2]) == signal, line
    assert match[3] in ('', ', so safedeps cannot tell where this install lands',
                        ', so safedeps cannot tell which registry this install fetches from'), line


def npm_query_report(observed, line, project, advisory=False):
    if advisory:
        prefix = (f'post-verify: npm rebuild after the install skipped in {project}'
                  ' — safedeps asked npm which packages a rebuild would run over and got no answer (')
        suffix = '), so it cannot tell that tree is one it can vouch for.'
    else:
        prefix = 'npm rebuild was not run: safedeps asked npm which packages it would rebuild and got no answer ('
        suffix = ("), so it could not tell they are the ones it read. safedeps did not run npm rebuild; "
                  "review node_modules, then run `npm rebuild` yourself if it is what you expect")
    assert line.startswith(prefix) and line.endswith(suffix), line
    npm_failure(observed, line[len(prefix):-len(suffix)])


if __name__ == '__main__':
    assert sys.argv[1] == 'rebuild'
    print(rebuild(sys.argv[2], sys.argv[3]))
