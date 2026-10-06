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
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys
import time

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--archive', required=True)
p.add_argument('--core', required=True)
p.add_argument('--pre-core')
p.add_argument('--probe', action='store_true')
p.add_argument('--native-faults',action='store_true',help='Adapt removed subprocess failure fixtures on the archive')
p.add_argument('--walk-core')
p.add_argument('--owner-core')
p.add_argument('--coarse-core')
p.add_argument('--suite', choices=['e2e', 'effect-trace-grid'], required=True)
p.add_argument('--grid-rows', help='Only these comma-separated table IDs, preserving original row assertions')
p.add_argument('--run-dir', required=True, help='A new evidence directory; existing paths are refused')
a = p.parse_args()
selected=a.grid_rows.split(',') if a.grid_rows else []
if selected and (a.suite!='effect-trace-grid' or any(not re.fullmatch(r'[A-Za-z0-9]+',s) for s in selected) or len(set(selected))!=len(selected)):
    p.error('--grid-rows requires unique alphanumeric effect-grid table IDs')
if a.native_faults and (a.probe or a.suite!='e2e' or not all([a.walk_core,a.owner_core,a.coarse_core])):
    p.error('--native-faults requires public e2e entry and all three injection cores')
archive = Path(a.archive).resolve(strict=True)
core = Path(a.core).resolve(strict=True)
pre = Path(a.pre_core).resolve(strict=True) if a.pre_core else None
run = Path(a.run_dir).resolve()
run.mkdir(parents=True, exist_ok=False)
tree = run/'tree'
tree.mkdir()
subprocess.run(['tar', 'xf', str(archive), '-C', str(tree)], check=True)
if selected:
    # Selection belongs to this measurement archive. The source battery and
    # every selected row's assertions remain intact. Never claim full-grid
    # coverage from the battery's final summary when this selector is used.
    shard=tree/'scripts/test/lib/shard.sh'
    text=shard.read_text();anchor='shard_row() {\n'
    if text.count(anchor)!=1: raise SystemExit('shard selection anchor is not unique')
    cases='|'.join("*': "+name+"|'*" for name in selected)
    selector='  case "$1" in '+cases+") printf '# focused-grid-row %s\\n' \"$1\" ;; *) return 1 ;; esac\n"
    shard.write_text(text.replace(anchor,anchor+selector))
spec=importlib.util.spec_from_file_location('native_adapter',Path(__file__).with_name('core-post-suite-adapt.py'))
adapter=importlib.util.module_from_spec(spec);spec.loader.exec_module(adapter)

def entry(path, binary, command, probe=False):
    # Python source literals, not shell interpolation. Fixed argv only.
    source = '#!' + sys.executable + '\nimport json, os, subprocess, sys\n'
    if command == 'post':
        source += 'call = os.environ.get("ORACLE_CALL")\n'
        source += 'if call: open(os.path.join(call, "native-owner-source"), "w").close()\n'
    if probe:
        source += 'raw = sys.stdin.buffer.read().decode("utf-8", "surrogateescape")\n'
        source += 'request = json.dumps(dict(op="hook", input=raw), ensure_ascii=True).encode()\n'
        source += 'rc = subprocess.run(' + repr([str(binary), 'post-probe']) + ', input=request).returncode\n'
        source += 'raise SystemExit(rc if rc >= 0 else 128-rc)\n'
    else:
        source += 'os.execv(' + repr(str(binary)) + ', ' + repr([str(binary), command]) + ')\n'
    adapter.python_entry(path,source)

entry(tree/'scripts/safedeps-post-verify.sh', core, 'post', a.probe)
if pre:
    entry(tree/'scripts/safedeps-pre-guard.sh', pre, 'pre')
if a.native_faults:
    adapter.adapt(tree,core,Path(a.walk_core).resolve(strict=True),Path(a.owner_core).resolve(strict=True),Path(a.coarse_core).resolve(strict=True),run)
started = time.time()
with (run/'suite.log').open('wb') as log:
    subprocess.run(['uptime'], stdout=log, stderr=log)
    result = subprocess.run(['bash', str(tree/'scripts/test'/(a.suite+'.sh'))], cwd=tree, stdout=log, stderr=log)
    subprocess.run(['uptime'], stdout=log, stderr=log)
(run/'suite.rc').write_text(str(result.returncode)+'\n')
report = dict(suite=a.suite, archive=str(archive), core=str(core),
              pre_core=str(pre) if pre else None, post_entry='probe' if a.probe else 'post',
              native_faults=a.native_faults,
              started=started, elapsed_seconds=time.time()-started, rc=result.returncode)
if selected:
    reached=re.findall(r'^# focused-grid-row [^\n]*: ([A-Za-z0-9]+)\|', (run/'suite.log').read_text(), re.M)
    report.update(selected_grid_rows=selected,reached_grid_rows=reached,full_grid=False)
    if sorted(reached)!=sorted(selected): report['rc']=1
(run/'result.json').write_text(json.dumps(report, indent=2)+'\n')
print(json.dumps(report), flush=True)
raise SystemExit(report['rc'] if report['rc'] >= 0 else 128-report['rc'])
