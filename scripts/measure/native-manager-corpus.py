#!/usr/bin/env python3
"""Pass the actual npm parser corpus through one native manager process."""
import argparse
import json
from pathlib import Path
import subprocess

p=argparse.ArgumentParser(description=__doc__)
for name in ('core','corpus','out'):p.add_argument('--'+name,required=True)
p.add_argument('--table',choices=('plain','other'),required=True)
a=p.parse_args()
# Preserve empty argument words. splitlines() would split our RS separator.
rows=Path(a.corpus).read_text().split('\n')
if rows[-1]=='':rows.pop()
queries=[dict(op='npm-read',table=a.table,words=row.split('\x1e')[0].split('\x1f')) for row in rows]
r=subprocess.run([a.core,'manager'],input=''.join(json.dumps(q)+'\n' for q in queries),text=True,capture_output=True,check=True)
answers=[json.loads(line) for line in r.stdout.splitlines()]
if len(answers)!=len(queries):raise RuntimeError('native manager omitted a corpus row')
Path(a.out).write_text(''.join(('\x1f'.join(r['words']) if r['reads'] else '<no reading>')+'\n' for r in answers))
