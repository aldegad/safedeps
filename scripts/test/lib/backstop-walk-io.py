#!/usr/bin/env python3
"""Read a real walk failure through both the trace query and the post hook.

The fixture moves the recorded baseline past its own permission change so
that the directory read, rather than that change's ctime, decides the trace.
The post hook must be silent; its advisory line is checked here in full.
"""
import argparse
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import time


def check(core, output):
    if os.geteuid() == 0:
        raise RuntimeError('the walk permission fixture requires a non-root uid')
    observed = dict(uid=os.geteuid())
    try:
        with tempfile.TemporaryDirectory(prefix='safedeps-walk-io.') as tmp:
            box = Path(tmp).resolve()
            project = box/'project'
            tree = project/'node_modules'
            blocked = tree/'unreadable'
            blocked.mkdir(parents=True)
            (blocked/'held').write_text('fixture bytes\n')
            (project/'package.json').write_text('{"name":"fixture","version":"1.0.0"}\n')
            (project/'package-lock.json').write_text(json.dumps(dict(
                name='fixture', version='1.0.0', lockfileVersion=3,
                packages={'': dict(name='fixture', version='1.0.0')}))+'\n')
            home = box/'state'
            env = {k: v for k, v in os.environ.items() if not k.startswith('SAFEDEPS_')}
            env.update(SAFEDEPS_HOME=str(home), SAFEDEPS_BACKSTOP_WALK_SECONDS='5')
            command = 'grep -n "npm install" README.md'
            payload = dict(tool_name='Bash', tool_use_id='walk-io', cwd=str(project),
                           tool_input=dict(command=command))

            def invoke(stage, value):
                result = subprocess.run([str(core), stage], input=json.dumps(value).encode(),
                                        env=env, capture_output=True)
                row = dict(rc=result.returncode, stdout=result.stdout.decode(),
                           stderr=result.stderr.decode())
                observed[stage] = row
                return row

            pre = invoke('pre', payload)
            assert pre == dict(rc=0, stdout='', stderr=''), ('pre', pre)
            entry_path = home/'pending/backstop/id-walk-io.json'
            entry = json.loads(entry_path.read_text())
            baseline = Path(entry['baseline'])
            mode = stat.S_IMODE(blocked.stat().st_mode)
            blocked.chmod(0)
            try:
                try:
                    with os.scandir(blocked) as entries:
                        list(entries)
                except PermissionError as error:
                    errno = error.errno
                else:
                    raise AssertionError('the directory read did not fail')
                observed['permission'] = dict(path=str(blocked), operation='scandir', errno=errno)
                after = time.time_ns()+1_000_000_000
                os.utime(baseline, ns=(after, after))
                observed['baseline_mtime_ns'] = baseline.stat().st_mtime_ns
                observed['node_ctime_ns'] = tree.stat().st_ctime_ns
                observed['blocked_ctime_ns'] = blocked.stat().st_ctime_ns
                assert max(observed['node_ctime_ns'], observed['blocked_ctime_ns']) < baseline.stat().st_mtime_ns
                line = f'the walk of {tree} returned OS error {errno}'
                probe = invoke('post-probe', dict(op='trace', path=str(project), entry=json.dumps(entry)))
                assert probe == dict(rc=0, stdout=line, stderr=''), ('walk I/O trace query', probe, line)
                before = (home/'advisory.log').read_bytes() if (home/'advisory.log').exists() else b''
                post = invoke('post', payload)
                assert post == dict(rc=0, stdout='', stderr=''), ('walk I/O silent post', post)
                log = (home/'advisory.log').read_bytes()
                assert log.startswith(before)
                added = log[len(before):].decode().splitlines()
                observed['advisory_added'] = added
                bodies = [row.split('\t', 1)[1] for row in added]
                expected = f'post-verify BACKSTOP traced: {line}. Command: {command}'
                assert bodies.count(expected) == 1, ('walk I/O advisory line', bodies, expected)
                assert len(bodies) == 2 and bodies[1].startswith('post-verify BACKSTOP clean: '), bodies
                assert not entry_path.exists() and not baseline.exists()
                assert not (home/'reorg.log').exists() or not (home/'reorg.log').read_bytes()
                assert not list((home/'rollback-journal').glob('*.json'))
            finally:
                blocked.chmod(mode)
            assert (blocked/'held').read_text() == 'fixture bytes\n'
            observed['passed'] = True
    finally:
        output.write_text(json.dumps(observed, indent=2)+'\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--core', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    check(args.core.resolve(strict=True), args.output)
