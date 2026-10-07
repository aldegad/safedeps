#!/usr/bin/env python3
"""Replay a saved archive adapter both directly and through the Bash shim.

The before entry is read verbatim from the failed measurement archive. Only
its wrapper is changed on the after side. Neither product code nor the shim
is changed, and every raw stderr is preserved.
"""

if __name__ == "__main__":
    import sys
    sys.stderr.write('retired: Replay of the historical Python-as-Bash adapter defect is retired; hook-entry tests own the native shim error contract. See native-measure-disposition.json.\n')
    raise SystemExit(2)
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--before-entry',required=True)
p.add_argument('--report',required=True)
a=p.parse_args()
root=Path(__file__).resolve().parents[2]
before=Path(a.before_entry).read_text()
spec=importlib.util.spec_from_file_location('adapter',Path(__file__).with_name('core-post-suite-adapt.py'))
adapter=importlib.util.module_from_spec(spec);spec.loader.exec_module(adapter)
rows=[]
with tempfile.TemporaryDirectory(prefix='core-post-entry.') as temporary:
    box=Path(temporary).resolve();project=box/'project';project.mkdir()
    scripts=box/'scripts';scripts.mkdir()
    shutil.copyfile(root/'scripts/safedeps-hook-entry.sh',scripts/'safedeps-hook-entry.sh')
    hook=scripts/'safedeps-post-verify.sh'
    payload=json.dumps(dict(tool_name='Bash',tool_input=dict(command='true'),cwd=str(project),tool_use_id='adapter-fixture')).encode()
    for side in ['before','after']:
        if side=='before':hook.write_text(before);hook.chmod(0o755)
        else:adapter.python_entry(hook,before)
        for route in ['direct','shim']:
            home=box/(side+'-'+route);home.mkdir()
            env=dict(os.environ,SAFEDEPS_HOME=str(home))
            env.pop('ORACLE_CALL',None)
            argv=[str(hook)] if route=='direct' else ['bash',str(scripts/'safedeps-hook-entry.sh'),'post']
            result=subprocess.run(argv,input=payload,capture_output=True,env=env,cwd=box)
            expected=2 if side=='before' and route=='shim' else 0
            passed=result.returncode==expected and not result.stdout
            if expected:passed=passed and b'does not parse' in result.stderr
            else:passed=passed and not result.stderr
            rows.append(dict(side=side,route=route,argv=argv,expected_rc=expected,actual_rc=result.returncode,
                             stdout=result.stdout.decode(),stderr=result.stderr.decode(),passed=passed))
report=dict(before_entry_sha256=hashlib.sha256(before.encode()).hexdigest(),rows=rows,passed=all(row['passed'] for row in rows))
Path(a.report).write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report))
raise SystemExit(0 if report['passed'] else 1)
