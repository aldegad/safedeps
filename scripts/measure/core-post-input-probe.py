#!/usr/bin/env python3
"""Exercise post's stream fields through its public call-record consumer.

Reuse the shared pre input corpus, with fixed pending records and no npm
lockfiles. All output and seeded files compare literally. New advisory
header timestamps are retained raw but their exact provenance is unobserved;
only the messages, line count and order are compared here. This does not
replace the independent report oracle or C's clock catalog.
"""

if __name__ == "__main__":
    import sys
    sys.stderr.write('retired: Bash/native payload channel comparison is retired; public native batteries check malformed input. See native-measure-disposition.json.\n')
    raise SystemExit(2)

import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
spec=importlib.util.spec_from_file_location('input_corpus',HERE/'core-pre-input-probe.py')
corpus=importlib.util.module_from_spec(spec);spec.loader.exec_module(corpus)
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--core',required=True)
p.add_argument('--report',required=True)
p.add_argument('--only')
p.add_argument('--expect-difference',action='store_true')
a=p.parse_args()
rows=[]
with tempfile.TemporaryDirectory(prefix='core-post-input.') as tmp:
    box=Path(tmp).resolve()/'paired';project=box/'project'
    cases=corpus.cases(project)
    if a.only:cases=[r for r in cases if r['id'] in a.only.split(',')]
    if not cases:p.error('no selected input rows')
    for row in cases:
        pair=[]
        for side in ['bash','core']:
            if box.exists():shutil.rmtree(box)
            project.mkdir(parents=True)
            home=box/'state';pending=home/'pending';pending.mkdir(parents=True)
            for name in ['call-1','other']:
                (pending/('id-'+name+'.json')).write_text(json.dumps(dict(snapshot_id='missing',project_dir=str(project),tool_use_id=name))+'\n')
            for name in ['home','tmp']:(box/name).mkdir()
            env=dict(os.environ,SAFEDEPS_HOME=str(home),HOME=str(box/'home'),TMPDIR=str(box/'tmp'),LANG='C',LC_ALL='C')
            for key in list(env):
                if key.startswith('SAFEDEPS_') and key!='SAFEDEPS_HOME':env.pop(key)
            argv=['/bin/bash',str(ROOT/'scripts/safedeps-post-verify.sh')] if side=='bash' else [str(Path(a.core).resolve()),'post']
            r=subprocess.run(argv,input=row['raw'],env=env,cwd=project,capture_output=True,timeout=20)
            raw={str(f.relative_to(home)):f.read_bytes().hex() for f in sorted(home.rglob('*')) if f.is_file()}
            advisory=bytes.fromhex(raw.get('advisory.log',''))
            messages=[];slots=[];errors=[]
            for i,line in enumerate(advisory.splitlines(keepends=True)):
                prefix,sep,message=line.partition(b'\t')
                if not sep:errors.append('advisory line has no header separator')
                messages.append(message.hex())
                slots.append(dict(line=i,raw_header_hex=prefix.hex(),provenance='unobserved'))
            pair.append(dict(rc=r.returncode,stdout_hex=r.stdout.hex(),stderr_hex=r.stderr.hex(),
                             raw_files=raw,advisory_messages=messages,unobserved_clock_slots=slots,errors=errors))
        left,right=pair
        compared={}
        for key in ['rc','stdout_hex','stderr_hex','advisory_messages']:
            compared[key]=left[key]==right[key]
        compared['nonclock_files']={k:v for k,v in left['raw_files'].items() if k!='advisory.log'}=={k:v for k,v in right['raw_files'].items() if k!='advisory.log'}
        compared['no_malformed_headers']=not left['errors'] and not right['errors']
        # This control has one valid emitted call id across two JSON values.
        # The original single-value restriction left its pending record behind.
        reference_ok=row['id']!='null-first' or 'pending/id-call-1.json' not in left['raw_files']
        rows.append(dict(id=row['id'],input_hex=row['raw'].hex(),compared=compared,
                         reference_oracle=reference_ok,reference=left,candidate=right,
                         passed=reference_ok and all(compared.values())))
        print(('ok ' if rows[-1]['passed'] else 'DIFF ')+row['id'],flush=True)
report=dict(rows=rows,failures=sum(not r['passed'] for r in rows),
            exact_clock_provenance='unobserved; not included in comparison')
Path(a.report).write_text(json.dumps(report,indent=2)+'\n')
reference_ok=all(row['reference_oracle'] for row in rows)
raise SystemExit(0 if reference_ok and (report['failures']>0 if a.expect_difference else report['failures']==0) else 1)
