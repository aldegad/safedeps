#!/usr/bin/env python3
"""The approval prescription's path quoting, against bash printf %q.

JSONL hex data preserves pathname bytes. No input is evaluated as code.
Run this on a test host; omitting --core records only the Bash oracle.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess


def main():
    ap=argparse.ArgumentParser();ap.add_argument('--core');ap.add_argument('--report',required=True);a=ap.parse_args()
    paths=[b'',b'/plain/bin/safedeps',b'/has space/bin/safedeps',b'/a#b/bin/safedeps',
        b'/a~b/bin/safedeps',b'/a=b/bin/safedeps',b'/a:b/bin/safedeps',b'/a^b/bin/safedeps',
        b'/a%b/bin/safedeps',b'/back\\slash/bin/safedeps',b'''/"'`$&();<>|*?[]{}!#~/bin/safedeps''',
        '/한글/é/😀/bin/safedeps'.encode(),b'/invalid\xff\xfe/bin/safedeps',
        *[b'/control'+bytes([i])+b'/bin/safedeps' for i in range(1,33)],b'/del\x7f/bin/safedeps']
    requests=[dict(op='invoke-quote',hex=p.hex(),locale=locale) for locale in ('C','en_US.UTF-8') for p in paths]
    inputs=Path(a.report).with_suffix('.inputs.jsonl');inputs.write_text(''.join(json.dumps(r)+'\n' for r in requests))
    rows=[]
    for line in inputs.read_text().splitlines():
        row=json.loads(line);env=dict(os.environ,LC_ALL=row['locale'],LANG=row['locale']);raw=bytes.fromhex(row['hex'])
        p=subprocess.run([b'/bin/bash',b'-c',b'printf %q "$1"',b'quote-probe',raw],env=env,capture_output=True,timeout=5)
        expected=dict(rc=p.returncode,stdout=p.stdout.hex(),stderr=p.stderr.hex())
        actual=None;channels=[]
        if a.core:
            q=subprocess.run([a.core,'pre-probe'],input=line.encode(),env=env,capture_output=True,timeout=5)
            actual=dict(rc=q.returncode,stdout=q.stdout.hex(),stderr=q.stderr.hex())
            channels=[k for k in expected if expected[k]!=actual[k]]
        if expected['rc']!=0 or expected['stderr']:channels.append('reference-failed')
        rows.append(dict(input=row,expected=expected,actual=actual,channels=channels))
    Path(a.report).write_text(json.dumps(rows,indent=2))
    bad=sum(bool(r['channels']) for r in rows)
    print(f'core-pre-quote: {len(rows)} rows, {bad} differ'+(' (reference only)' if not a.core else ''),flush=True)
    for r in rows:
        if r['channels']:print(json.dumps(r),flush=True)
    return int(bool(bad))

if __name__=='__main__':raise SystemExit(main())
