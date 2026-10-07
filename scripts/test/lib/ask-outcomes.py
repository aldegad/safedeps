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

            # Carry the same independently observed failure all the way to
            # the hook's systemMessage and advisory.log, not only the probe.
            project=box/'project';tree=project/'node_modules';tree.mkdir(parents=True)
            (project/'package.json').write_text('{"name":"fixture","version":"1.0.0"}')
            lock='{"lockfileVersion":3,"packages":{}}'
            (project/'package-lock.json').write_text(lock)
            (tree/'.package-lock.json').write_text(lock)
            npm.write_text('#!'+sys.executable+'\nimport os,signal,sys\n'
                f'project={str(project)!r}\n'
                'if sys.argv[1]=="prefix": print(project)\n'
                'elif sys.argv[1]=="root": print(project+"/node_modules")\n'
                'elif sys.argv[1]=="config": print(\'{"registry":"https://registry.npmjs.org/","replace-registry-host":"npmjs"}\')\n'
                'elif sys.argv[1]=="query": os.kill(os.getpid(),signal.SIGKILL)\n'
                'else: raise RuntimeError("unexpected npm operation")\n')
            direct=subprocess.run([str(npm),'query','*'],capture_output=True,env=env)
            observed=dict(returncode=direct.returncode)
            assert direct.returncode == -9 and not direct.stdout and not direct.stderr
            payload=dict(tool_name='Bash',tool_use_id='query-result',cwd=str(project),tool_input=dict(command='npm install'))
            pre=subprocess.run([str(core),'pre'],input=json.dumps(payload).encode(),capture_output=True,env=env)
            assert pre.returncode == 0 and not pre.stderr, pre
            payload['tool_input']['command']=json.loads(pre.stdout)['hookSpecificOutput']['updatedInput']['command']
            (tree/'.package-lock.json').unlink();(tree/'.package-lock.json').write_text(lock)
            log=box/'state/advisory.log';before=log.read_bytes() if log.exists() else b''
            post=subprocess.run([str(core),'post'],input=json.dumps(payload).encode(),capture_output=True,env=env)
            assert post.returncode == 0 and not post.stderr, post
            message=json.loads(post.stdout)['systemMessage']
            result_lines=[line for line in message.splitlines() if line.startswith('npm rebuild was not run:')]
            assert len(result_lines)==1, message
            oracle.npm_query_report(observed,result_lines[0],project)
            after=log.read_bytes();assert after.startswith(before)
            advisory=[line.split('\t',1)[1] for line in after[len(before):].decode().splitlines()
                      if '\tpost-verify: npm rebuild after the install skipped in ' in line]
            assert len(advisory)==1, after
            oracle.npm_query_report(observed,advisory[0],project,advisory=True)
            rows.append(dict(operation='post',observation=observed,rc=post.returncode,lines=result_lines,advisory=advisory))
    finally:
        output.write_text(json.dumps(rows,indent=2)+'\n')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--core',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args();check(args.core.resolve(strict=True),args.output)
