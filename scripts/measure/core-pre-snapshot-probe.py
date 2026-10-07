#!/usr/bin/env python3
"""Retired comparison entry; any retained definitions are native fixture helpers."""
import sys

if __name__ == "__main__":
    sys.stderr.write('retired: The extracted Bash snapshot comparison is retired. Synthetic seed and independent harvest helpers remain for native controls. See native-measure-disposition.json.\n')
    raise SystemExit(2)

import argparse

import hashlib

import json

import os

from pathlib import Path

import re

import shutil

import stat

import subprocess

import tempfile

import time

def put(root, rel, data, mode=0o644):
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data if isinstance(data, bytes) else json.dumps(data).encode())
    path.chmod(mode)

def seed(box, name, project_hash):
    project = box / 'project'
    project.mkdir(parents=True)
    guard = box / 'state'
    (guard / 'snapshots').mkdir(parents=True, mode=0o700)
    guard.chmod(0o700)
    if name == 'empty':
        return
    put(project, 'package.json', {'name': 'example', 'version': '1.0.0'})
    put(project, 'package-lock.json', {'lockfileVersion': 3, 'packages': {}})
    if name == 'root-files':
        put(project, 'Cargo.lock', b'fixed lock bytes\n', 0o751)
        put(project, 'a.csproj', b'<Project/>\n')
        put(project, 'b.csproj', b'<Project/>\n', 0o400)
        (project / 'c.csproj').symlink_to('a.csproj')
    if name in ('hidden', 'node-link'):
        put(project, 'node_modules/.package-lock.json', b'{"packages":{}}', 0o751)
        put(project, 'node_modules/a/package.json', b'{"name":"a"}')
        put(project, 'node_modules/@x/b/package.json', b'{"name":"b"}')
        put(project, 'node_modules/a/deeper/package.json', b'{}')
        put(project, 'outside/package.json', b'{}')
        (project / 'node_modules/link').symlink_to(project / 'outside', target_is_directory=True)
        put(project, 'node_modules/.bin/a', b'#!/bin/sh\n', 0o755)
        put(project, 'node_modules/.bin/.hidden', b'x')
        if name == 'node-link':
            (project / 'node_modules').rename(project / 'tree')
            (project / 'node_modules').symlink_to('tree', target_is_directory=True)
    if name in ('workspace', 'workspace-link', 'lock-members', 'no-workspaces'):
        if name != 'no-workspaces':
            patterns = ['{unsupported}'] if name == 'lock-members' else ['packages/*']
            put(project, 'package.json', {'workspaces': patterns})
        put(project, 'packages/a/package.json', b'{"name":"a"}', 0o751)
        put(project, 'packages/b/package.json', b'{"name":"b"}\n', 0o600)
        put(project, 'hidden/c/package.json', b'{"name":"c"}')
        put(project, 'terminal/node_modules/package.json', b'{"name":"terminal"}')
        put(project, 'node_modules/dep/package.json', b'{"name":"dep"}')
        put(project, 'package-lock.json', {'packages': {
            'packages/a': {}, 'node_modules/dep': {}, '../escape': {},
            'terminal/node_modules': {}, 'packages/./b': {}}})
        put(project, 'node_modules/.package-lock.json', {'packages': {'hidden/c': {}}})
        if name == 'workspace-link':
            (project / 'packages/b').rename(project / 'b-target')
            (project / 'packages/b').symlink_to(project / 'b-target', target_is_directory=True)
    if name in ('parent', 'parent-fallback', 'parent-empty'):
        put(guard, 'snapshots/seed_meta.json', b'{"snapshot_id":"seed","timestamp":4102444800}', 0o600)
        put(guard, 'confirmed', b'seed\n', 0o600)
        own = b'seed\n' if name == 'parent' else b'missing\n' if name == 'parent-fallback' else b''
        put(guard, 'confirmed_' + project_hash, own, 0o600)
