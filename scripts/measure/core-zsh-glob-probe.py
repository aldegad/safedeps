#!/usr/bin/env python3
"""Retired comparison entry; any retained definitions are native fixture helpers."""
import sys

if __name__ == "__main__":
    sys.stderr.write('retired: This Bash reference lexer comparison is retired; actual shell corpus observations remain available. See native-measure-disposition.json.\n')
    raise SystemExit(2)

import argparse

import importlib.util

import io

import json

import os

from pathlib import Path

import subprocess

def words(core,command,reading):
    p=subprocess.run([core,'words'],input=command.encode(),env=dict(os.environ,SAFEDEPS_READING=reading),capture_output=True)
    f=io.BytesIO(p.stdout);pieces=[]
    unterm=f.readline();unreadable=f.readline()
    while True:
        line=f.readline()
        if not line.startswith(b'P '):break
        _,number,start,end,count=line.split()
        item=dict(start=int(start),end=int(end),words=[])
        for _ in range(int(count)):
            tag,a,z,size=f.readline().split();assert tag==b'W'
            value=f.read(int(size));assert f.read(1)==b'\n'
            item['words'].append(dict(start=int(a),end=int(z),value=value.decode()))
        pieces.append(item)
    return dict(rc=p.returncode,unterm=unterm.decode().strip(),unreadable=unreadable.decode().strip(),pieces=pieces,stderr=p.stderr.decode()),p.stdout
