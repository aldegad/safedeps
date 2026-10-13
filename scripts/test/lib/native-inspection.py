#!/usr/bin/env python3
"""Public post ordering and blocked-I/O controls, using only local fixtures."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

core = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix='native-inspection-public-') as temp:
    root = Path(temp)
    for case in ('script', 'blocked', 'prior-reason'):
        project = root/case
        project.mkdir()
        home = root/(case+'-state')
        env = dict(os.environ, SAFEDEPS_HOME=str(home))
        # An empty approved closure makes this a native-inspection test,
        # without an external advisory service or a package-code execution.
        lock = {'name': 'fixture', 'lockfileVersion': 3, 'packages': {}}
        (project/'package.json').write_text('{"name":"fixture","version":"1.0.0"}')
        (project/'package-lock.json').write_text(json.dumps(lock))
        request = {'tool_name': 'Bash', 'tool_use_id': 'native-'+case,
                   'tool_input': {'command': 'npm install --ignore-scripts'}, 'cwd': str(project), 'turn_id': 'fixture'}
        def call(stage):
            start = time.monotonic()
            result = subprocess.run([core, stage], input=json.dumps(request), env=env,
                                    cwd=project, text=True, capture_output=True, timeout=12)
            assert result.returncode == 0, result.stderr
            return result, time.monotonic()-start
        pre, _ = call('pre')
        assert 'deny' not in pre.stdout.lower(), pre.stdout
        pending = list((home/'pending').glob('*.json'))
        assert len(pending) == 1, pending
        record = json.loads(pending[0].read_text())
        snapshot = record['snapshot_id']
        bins = project/'node_modules/.bin'
        bins.mkdir(parents=True)
        (project/'node_modules/.package-lock.json').write_text(json.dumps(lock))
        (project/'node_modules/cli.js').write_text('#!/usr/bin/env node\nconsole.log(42)\n')
        (bins/'fixture-cli').symlink_to('../cli.js')
        baseline = home/'snapshots'/(snapshot+'_bins.list')
        if case != 'script':
            baseline.unlink()
            os.mkfifo(baseline)
        if case == 'prior-reason':
            (project/'package.json').write_text('{"name":"fixture","version":"1.0.1"}')
            package = project/'node_modules/fixture'
            package.mkdir()
            (package/'package.json').write_text(json.dumps({'name':'fixture', 'version':'1.0.0',
                'scripts':{'postinstall':'curl https://example.invalid/fixture'}}))
        post, elapsed = call('post')
        message = json.loads(post.stdout or '{}').get('systemMessage','')
        if case == 'script':
            assert 'rollback ran' not in message and 'Native binary' not in message, message
            assert (bins/'fixture-cli').exists()
            assert list(home.glob('confirmed*')), 'normal script install must CONFIRM'
        else:
            assert 'A rollback ran.' in message, message
            assert not (project/'node_modules').exists()
            assert not list(home.glob('confirmed*')), 'incomplete/rejected install must not CONFIRM'
            if case == 'blocked':
                assert 'Native binary inspection incomplete:' in message and 'deadline' in message, message
                assert elapsed < 4, elapsed
            else:
                assert 'install script with network access' in message, message
                assert 'Native binary inspection incomplete' not in message, message
                assert elapsed < 4, elapsed
        print(f'ok - native-inspection public {case}: {elapsed:.3f}s', flush=True)
