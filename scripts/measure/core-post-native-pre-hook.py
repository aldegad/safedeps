#!/usr/bin/env python3
"""Select archive-only native faults for the original pre e2e fixtures.

These selectors replace the fixture's date/touch/stat/jq PATH shims. Product
hooks contain no selector or fault switch. The original payload and exit
status pass through; every selected source copy is recorded beside the run.
"""
import argparse
import json
from pathlib import Path
import sys
import subprocess

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--core',required=True)
for name in ['coarse','seconds','mark','same']:p.add_argument('--'+name+'-core',required=True)
p.add_argument('--receipts',required=True)
a=p.parse_args()
raw=sys.stdin.buffer.read()
payload=json.loads(raw)
name=Path(payload.get('cwd','')).name
selected=a.core
kind=None
if name=='bs-mix-wt':kind='coarse'
elif name=='bs-sec-wt':kind='seconds'
elif name.startswith('markfail-wt.'):kind='mark'
elif name.startswith('same-wt.'):kind='same'
if kind:
    selected=getattr(a,kind+'_core')
    with open(a.receipts,'a') as f:
        f.write(json.dumps(dict(stage='pre',fixture=name,operation=kind,core=selected))+'\n')
# Preserve stdin bytes for the executable after inspecting the fixture id.
r=subprocess.run([selected,'pre'],input=raw)
raise SystemExit(r.returncode if r.returncode>=0 else 128-r.returncode)
