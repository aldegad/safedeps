#!/usr/bin/env python3
"""Native adapter for e2e's two direct fact-function calls.

The existing oracle and assertions consume these lines. The missing-meta row
uses a body-only test logger in Bash; retain the native raw append separately
and validate its invocation timestamp before passing its body to that row.
"""
import argparse
import datetime
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import time

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--core',required=True)
p.add_argument('--meta',required=True)
p.add_argument('--input',required=True)
p.add_argument('--project',required=True)
p.add_argument('--kind',choices=['missing','unresolved'],required=True)
p.add_argument('--log-body')
a=p.parse_args()
home=Path(os.environ['SAFEDEPS_HOME']);home.mkdir(parents=True,exist_ok=True)
log=home/'advisory.log';before=log.read_bytes() if log.exists() else b''
lo=math.floor(time.time())

def call(**request):
    result=subprocess.run([a.core,'post-probe'],input=json.dumps(request).encode(),capture_output=True)
    if result.returncode or result.stderr:raise RuntimeError(repr((request,result.returncode,result.stderr)))
    return result.stdout

lines=b''
if a.kind=='unresolved':
    lines+=call(op='report',action='refuse-outside',project=a.project,path=str(Path(a.project)/'package-lock.json'),kind='restore')
why=call(op='reach',path=a.project)
if not why:raise RuntimeError('the direct unresolved fixture unexpectedly resolves')
lines+=call(op='report',action='rebuild',path=a.meta,input=a.input,fact='did not run npm rebuild: '+why.decode())
hi=math.ceil(time.time())
after=log.read_bytes() if log.exists() else b''
if not after.startswith(before):raise RuntimeError('advisory prefix changed')
raw=after[len(before):]
if a.log_body:
    target=Path(a.log_body);target.with_name(target.name+'.raw').write_bytes(raw)
    if raw.count(b'\n')!=1 or b'\t' not in raw:raise RuntimeError('expected exactly one timestamped advisory append')
    timestamp,body=raw.split(b'\t',1)
    at=datetime.datetime.strptime(timestamp.decode(),'%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc).timestamp()
    if not lo<=at<=hi:raise RuntimeError('advisory timestamp is outside this invocation')
    target.write_bytes(body)
elif raw:raise RuntimeError('an intact v2 direct fact unexpectedly logged an unread record')
sys.stdout.buffer.write(lines)
