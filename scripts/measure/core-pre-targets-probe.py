#!/usr/bin/env python3
"""Retired comparison entry; any retained definitions are native fixture helpers."""
import sys

if __name__ == "__main__":
    sys.stderr.write('retired: The extracted Bash target reader comparison is retired. Synthetic npm capture helpers remain for native pre probes. See native-measure-disposition.json.\n')
    raise SystemExit(2)

import argparse

import json

import os

from pathlib import Path

import shutil

import subprocess

import sys

import tempfile

def stub(box):
    path = box / 'bin/npm'
    path.parent.mkdir()
    path.write_text('#!' + sys.executable + ' -B\n' + '''import hashlib,json,os,sys
from pathlib import Path
box=Path(''' + repr(str(box)) + ''')
a=sys.argv[1:]
cache=a[-1]
assert a[-2]=='--cache' and Path(cache).parent.parent==box/'tmp', (a,cache)
a[-1]='@PRIVATE_CACHE@'
env={k:v for k,v in os.environ.items() if k not in ('_','SHLVL')}
row={'argv':a,'cwd':os.getcwd(),'env':env}
raw=json.dumps(row,sort_keys=True).encode()
key=hashlib.sha256(raw).hexdigest()
(box/'calls'/(key+'.'+str(os.getpid()))).write_bytes(raw)
config=json.loads((box/'answer.json').read_text())
prefix=config.get('prefix',os.getcwd())
if a[0]=='prefix': print(prefix)
elif a[0]=='root': print(config.get('root',prefix+'/node_modules'))
elif a[:2]==['config','ls']:
    registry=env.get('npm_config_registry',config.get('registry','https://registry.npmjs.org/'))
    print(json.dumps({'registry':registry,'replace-registry-host':'npmjs',**config.get('config',{})}))
else: raise SystemExit(91)
''')
    path.chmod(0o755)
    evil = box / 'evil'
    evil.mkdir()
    for name in ('npm', 'code'):
        p = evil / name
        p.write_text('#!/bin/sh\nprintf executed > ' + str(box / 'EXECUTED') + '\n')
        p.chmod(0o755)
