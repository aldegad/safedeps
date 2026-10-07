#!/usr/bin/env python3
"""Exercise npm signal outcomes through each public ask query."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def check(core, output):
    spec=importlib.util.spec_from_file_location('outcome_oracle',Path(__file__).with_name('outcome-oracle.py'))
    oracle=importlib.util.module_from_spec(spec);spec.loader.exec_module(oracle)
    rows=[]
    try:
        with tempfile.TemporaryDirectory(prefix='safedeps-ask-outcome.') as tmp:
            box=Path(tmp).resolve();npm=box/'npm'
            npm.write_text('#!'+sys.executable+'\nimport os,signal\nos.kill(os.getpid(),signal.SIGKILL)\n')
            npm.chmod(0o700)
            env={k:v for k,v in os.environ.items() if not k.startswith('SAFEDEPS_')}
            env.update(PATH=str(box)+':/usr/bin:/bin',SAFEDEPS_HOME=str(box/'state'))
            direct=subprocess.run([str(npm),'query','*'],capture_output=True,env=env)
            observed=dict(returncode=direct.returncode)
            assert direct.returncode == -9 and not direct.stdout and not direct.stderr
            for operation in ('query','fetch','target'):
                request=dict(op=operation,dir=str(box),milliseconds=2000)
                result=subprocess.run([str(core),'ask-probe'],input=json.dumps(request).encode(),capture_output=True,env=env)
                text=result.stdout.decode()
                assert not result.stderr
                if operation=='query':
                    assert result.returncode == 1
                    lines=[text.rstrip('\n')]
                elif operation=='fetch':
                    assert result.returncode == 0
                    lines=[json.loads(text)['unknown']]
                else:
                    assert result.returncode == 0
                    target,facts=text.split('\n',1)
                    assert target.startswith('?\t')
                    lines=[target[2:],json.loads(facts)['unknown']]
                for line in lines:oracle.npm_failure(observed,line)
                rows.append(dict(operation=operation,observation=observed,rc=result.returncode,lines=lines))
    finally:
        output.write_text(json.dumps(rows,indent=2)+'\n')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--core',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args();check(args.core.resolve(strict=True),args.output)
