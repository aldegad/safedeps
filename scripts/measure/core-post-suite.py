#!/usr/bin/env python3
"""Run an unchanged e2e/oracle or trace suite with a selected Rust hook.

Run on a test host under its queue. The archive is extracted into a new run
directory. Only its hook entry scripts are replaced; assertions, fixtures,
the independent report oracle, and the original checkout are untouched.
The default pre hook is Bash. Supply --pre-core when the shared pre is ready.
--probe wraps raw post input for the unfinished public entry's hook probe.
That adapter adds a Python process and is not a process-cost measurement.
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import time

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--archive', required=True)
p.add_argument('--core', required=True)
p.add_argument('--pre-core')
p.add_argument('--probe', action='store_true')
p.add_argument('--suite', choices=['e2e', 'effect-trace-grid'], required=True)
p.add_argument('--run-dir', required=True, help='A new evidence directory; existing paths are refused')
a = p.parse_args()
archive = Path(a.archive).resolve(strict=True)
core = Path(a.core).resolve(strict=True)
pre = Path(a.pre_core).resolve(strict=True) if a.pre_core else None
run = Path(a.run_dir).resolve()
run.mkdir(parents=True, exist_ok=False)
tree = run/'tree'
tree.mkdir()
subprocess.run(['tar', 'xf', str(archive), '-C', str(tree)], check=True)

def entry(path, binary, command, probe=False):
    # Python source literals, not shell interpolation. Fixed argv only.
    source = '#!' + sys.executable + '\nimport json, os, subprocess, sys\n'
    if probe:
        source += 'raw = sys.stdin.buffer.read().decode("utf-8", "surrogateescape")\n'
        source += 'request = json.dumps(dict(op="hook", input=raw), ensure_ascii=True).encode()\n'
        source += 'rc = subprocess.run(' + repr([str(binary), 'post-probe']) + ', input=request).returncode\n'
        source += 'raise SystemExit(rc if rc >= 0 else 128-rc)\n'
    else:
        source += 'os.execv(' + repr(str(binary)) + ', ' + repr([str(binary), command]) + ')\n'
    path.write_text(source)
    path.chmod(0o755)

entry(tree/'scripts/safedeps-post-verify.sh', core, 'post', a.probe)
if pre:
    entry(tree/'scripts/safedeps-pre-guard.sh', pre, 'pre')
started = time.time()
with (run/'suite.log').open('wb') as log:
    subprocess.run(['uptime'], stdout=log, stderr=log)
    result = subprocess.run(['bash', str(tree/'scripts/test'/(a.suite+'.sh'))], cwd=tree, stdout=log, stderr=log)
    subprocess.run(['uptime'], stdout=log, stderr=log)
(run/'suite.rc').write_text(str(result.returncode)+'\n')
report = dict(suite=a.suite, archive=str(archive), core=str(core),
              pre_core=str(pre) if pre else None, post_entry='probe' if a.probe else 'post',
              started=started, elapsed_seconds=time.time()-started, rc=result.returncode)
(run/'result.json').write_text(json.dumps(report, indent=2)+'\n')
print(json.dumps(report), flush=True)
raise SystemExit(result.returncode if result.returncode >= 0 else 128-result.returncode)
