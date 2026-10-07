#!/usr/bin/env python3
"""Actual npm start failure and signal, through the public hook and oracle.

The query fixture removes its executable before rebuild, or rebuild waits
for this test's SIGKILL. The product receives no test selector. Normal npm
shim wrapping would conceal these outcomes, so these rows invoke it directly.
"""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[3]
STUB = r'''import json,os,pathlib,sys,time
p=pathlib.Path(__file__);box=p.parent.parent
with (box/'calls.jsonl').open('a') as out:
 out.write(json.dumps(dict(argv=sys.argv[1:],pid=os.getpid()))+'\n')
project=box/'project'
if sys.argv[1]=='prefix': print(project)
elif sys.argv[1]=='root': print(project/'node_modules')
elif sys.argv[1]=='config': print('{"registry":"https://registry.npmjs.org/","replace-registry-host":"npmjs"}')
elif sys.argv[1]=='query':
 if (box/'kind').read_text()=='start': p.unlink()
 print('[]')
elif sys.argv[1]=='rebuild':
 (box/'ready.tmp').write_text(str(os.getpid()));(box/'ready.tmp').replace(box/'ready')
 while True: time.sleep(.05)
else: raise RuntimeError('unexpected npm operation')
'''


def run(core, out, oracle_dir):
    out.mkdir(parents=True, exist_ok=False)
    for kind in ('start', 'signal'):
        for injected in (True, False):
            box = out/(kind+('-added' if injected else '-asked'))
            project = box/'project'; tree = project/'node_modules'
            tree.mkdir(parents=True)
            (project/'package.json').write_text('{"name":"fixture","version":"1.0.0"}')
            lock = '{"lockfileVersion":3,"packages":{}}'
            (project/'package-lock.json').write_text(lock)
            (tree/'.package-lock.json').write_text(lock)
            bins = box/'bin'; bins.mkdir()
            npm = bins/'npm'; npm.write_text('#!'+sys.executable+'\n'+STUB); npm.chmod(0o700)
            (box/'kind').write_text(kind)
            env = {k: v for k, v in os.environ.items() if not k.startswith('SAFEDEPS_')}
            env['SAFEDEPS_HOME'] = str(box/'home')
            product_env = dict(env, PATH=str(bins)+':/usr/bin:/bin')
            assert not any((Path(p)/'npm').exists() for p in ('/usr/bin', '/bin'))
            payload = dict(tool_name='Bash',tool_use_id='result-'+kind,cwd=str(project),
                           tool_input=dict(command='npm install'))
            payload_file = box/'input.json'
            payload_file.write_text(json.dumps(payload))
            pre_call = box/'pre-call'; pre_call.mkdir()
            call = box/'post-call'; call.mkdir()

            def oracle(body, *args):
                prefix = 'source "$1"; ORACLE_DIR="$2"; oracle_native_owner_forms; oracle_native_io_forms; shift 2; '
                subprocess.run(['/bin/bash','-eu','-c',prefix+body,'oracle',
                    str(ROOT/'scripts/test/lib/report-oracle.sh'),str(oracle_dir),*map(str,args)],env=env,check=True)

            oracle('oracle_pre_before "$1"',pre_call)
            pre = subprocess.run([str(core),'pre'],input=payload_file.read_bytes(),env=product_env,capture_output=True)
            (box/'pre.json').write_bytes(pre.stdout)
            assert pre.returncode == 0 and not pre.stderr, pre
            oracle('oracle_pre "$1" "$(cat "$2")"',pre_call,box/'pre.json')
            rewrite = json.loads(pre.stdout)['hookSpecificOutput']['updatedInput']['command']
            if injected: payload['tool_input']['command'] = rewrite
            payload_file.write_text(json.dumps(payload))
            # A new inode supplies the actual post-install trace.
            (tree/'.package-lock.json').unlink(); (tree/'.package-lock.json').write_text(lock)
            oracle('oracle_before "$1" "$(cat "$2")"',call,payload_file)
            child = subprocess.Popen([str(core),'post'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE,env=product_env,start_new_session=True)
            child.stdin.write(payload_file.read_bytes()); child.stdin.close(); child.stdin=None
            receipt = dict(kind=kind,npm=str(npm),calls=str(box/'calls.jsonl'))
            try:
                if kind == 'signal':
                    limit = time.monotonic()+30
                    while not (box/'ready').exists() and child.poll() is None and time.monotonic()<limit:
                        time.sleep(.02)
                    assert (box/'ready').exists(), 'the fixture rebuild was never reached'
                    pid = int((box/'ready').read_text())
                    os.kill(pid, signal.SIGKILL)
                    receipt.update(pid=pid,signal=int(signal.SIGKILL),kill_returned=True)
                stdout, stderr = child.communicate(timeout=30)
            finally:
                if child.poll() is None:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.communicate()
            assert child.returncode == 0 and not stderr, (child.returncode,stdout,stderr)
            (box/'post.json').write_bytes(stdout)
            if kind == 'start':
                assert not npm.exists()
                try: subprocess.run([str(npm),'rebuild'],capture_output=True)
                except OSError as error: receipt['errno']=error.errno
                else: raise AssertionError('the missing npm started')
            (call/'rebuild-outcome.json').write_text(json.dumps(receipt,indent=2)+'\n')
            oracle('oracle_message "$1" "$(cat "$2")" "$(cat "$3")"',call,payload_file,box/'post.json')
            message = json.loads(stdout)['systemMessage']
            expected = ('could not start npm rebuild: OS error '+str(receipt['errno']) if kind=='start'
                        else 'npm rebuild terminated by signal 9')
            head = ('safedeps added --ignore-scripts to this install and ' if injected else 'safedeps ')
            assert (head+expected) in message.splitlines(), message
            print('ok - rebuild outcome '+box.name)


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--core',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--oracle-dir',type=Path,required=True)
    args=parser.parse_args()
    run(args.core.resolve(strict=True),args.output.resolve(),args.oracle_dir.resolve())
