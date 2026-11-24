#!/usr/bin/env python3
"""A minimal npm registry on 127.0.0.1 for the end-to-end install tests. It
answers through lib/fixture_http.py, which says why it reads with blocking
recv().

  fixture-registry.py <port-file> <tarball-dir> <request-log> [<trace-file>] [--mark <text>] [--exit-on-stdin-eof]

It serves a packument and a tarball for every `<name>-<version>.tgz` in a
directory, next to the `<name>-<version>.tgz.json` manifest it was packed
from. Tarball URLs are written as registry.npmjs.org URLs on purpose: npm's
default `replace-registry-host=npmjs` fetches them from the configured
registry (this server), and the lockfile records the canonical URL, as it
does for a real install. So the lockfile heuristics in post-verify see an
ordinary lockfile rather than one pointing at a local port.

Every request is appended to the request log as `<method> <url>`, so a test
can show nothing left the machine. The trace file, if given, gets each
connection's events, and --exit-on-stdin-eof ends the server at end of file
on its standard input (lib/fixture_http.py).
"""
import base64
import hashlib
import json
import os
import re
import sys
import threading
import urllib.parse
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent / 'lib'))
import fixture_http  # noqa: E402

args = fixture_http.arguments(
    'fixture-registry.py <port-file> <tarball-dir> <request-log> [<trace-file>] [--mark <text>] [--exit-on-stdin-eof]',
    ['port_file', 'tar_dir', 'log_file'], 'trace_file')

TARBALL_NAME = re.compile(r'(.+)-([0-9]+\.[0-9]+\.[0-9]+)\.tgz')
TARBALL_URL = re.compile(r'/(.+)/-/([^/]+\.tgz)')
log_lock = threading.Lock()


def packument(name):
    versions = {}
    for file in sorted(os.listdir(args.tar_dir)):
        match = TARBALL_NAME.fullmatch(file)
        if not match or match.group(1) != name:
            continue
        with open(os.path.join(args.tar_dir, file), 'rb') as handle:
            tarball = handle.read()
        with open(os.path.join(args.tar_dir, file + '.json')) as handle:
            manifest = json.load(handle)
        version = dict(manifest)
        version['_id'] = '%s@%s' % (name, match.group(2))
        version['dist'] = {
            'tarball': 'https://registry.npmjs.org/%s/-/%s' % (name, file),
            'shasum': hashlib.sha1(tarball).hexdigest(),
            'integrity': 'sha512-' + base64.b64encode(hashlib.sha512(tarball).digest()).decode(),
        }
        versions[match.group(2)] = version
    if not versions:
        return None
    return {'name': name, 'versions': versions, 'dist-tags': {'latest': sorted(versions)[-1]}}


def route(method, url, body):
    with log_lock, open(args.log_file, 'a') as log:
        log.write('%s %s\n' % (method, url))
    path = urllib.parse.unquote(url.split('?')[0])
    tarball = TARBALL_URL.fullmatch(path)
    if tarball:
        file = os.path.join(args.tar_dir, tarball.group(2))
        if os.path.exists(file):
            with open(file, 'rb') as handle:
                return fixture_http.Answer(200, handle.read(), 'application/octet-stream')
    else:
        doc = packument(path[1:])
        if doc:
            return fixture_http.Answer(200, json.dumps(doc, separators=(',', ':')), 'application/json')
    return fixture_http.Answer(404, '{}')


fixture_http.serve(route, args.port_file, args.trace_file, args.exit_on_stdin_eof)
