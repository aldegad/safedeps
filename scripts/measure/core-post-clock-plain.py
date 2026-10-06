#!/usr/bin/env python3
"""Check clock consumers' file effects in an uninstrumented archive binary.

Raw requests, stdout/stderr and file bytes are retained. Generated clock
slots remain unobserved: these checks establish structure, references and
preservation of seeded values, not the exact source of any generated time.
The independent clock catalog and source controls belong to the C harness.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--core',required=True)
p.add_argument('--report',required=True)
a=p.parse_args()
if os.geteuid()==0:p.error('failed-write fixture requires an unprivileged user')
core=str(Path(a.core).resolve(strict=True))
rows=[]

def files(home):
    return {str(f.relative_to(home)):f.read_bytes().hex() for f in sorted(home.rglob('*')) if f.is_file()}

def invoke(home,request):
    r=subprocess.run([core,'post-probe'],input=json.dumps(request).encode(),capture_output=True,
                     env=dict(os.environ,SAFEDEPS_HOME=str(home)),timeout=20)
    return dict(request=request,rc=r.returncode,stdout_hex=r.stdout.hex(),stderr_hex=r.stderr.hex())

def record(name,calls,checks,home,slots):
    rows.append(dict(name=name,calls=calls,checks=checks,passed=all(checks.values()),
                     raw_files=files(home),unobserved_clock_slots=slots))

with tempfile.TemporaryDirectory(prefix='core-post-clock-plain.') as tmp:
    root=Path(tmp)
    for shape in ['open','stage-stream','stage-invalid-tail','open-write-fails','stage-write-fails']:
        home=root/shape;directory=home/'rollback-journal';directory.mkdir(parents=True)
        project=home/'project';project.mkdir()
        path=directory/'seed.json'
        seed={'journal_id':'seed','opened_at':'2001-02-03T04:05:06Z','pid':'123',
              'stage_at':'2001-02-03T04:05:17Z','stage':'seed-stage','project_dir':str(project)}
        values=[seed,dict(seed,journal_id='seed-2'),None]
        if shape=='stage-invalid-tail':values.append(7)
        before=b'\n'.join(json.dumps(v).encode() for v in values)
        if shape.startswith('stage'):path.write_bytes(before)
        request=dict(op='journal',id='seed',path=str(project),snapshot='seed-snapshot',
                     reasons='fixture',stage='next-stage',action='stage' if shape.startswith('stage') else 'open')
        if shape.endswith('write-fails'):directory.chmod(0o500)
        try:
            call=invoke(home,request)
        finally:
            directory.chmod(0o700)
        checks=dict(quiet=not call['stdout_hex'] and not call['stderr_hex'])
        slots=[]
        if shape=='open':
            value=json.loads(path.read_bytes()) if path.exists() else {}
            checks.update(rc=call['rc']==0,identity=value.get('journal_id')=='seed',
                          project=value.get('project_dir')==str(project),snapshot=value.get('rollback_snapshot')=='seed-snapshot',
                          stage=value.get('stage')=='next-stage',pid=value.get('pid','').isdigit(),
                          opened_string=isinstance(value.get('opened_at'),str))
            slots=['rollback-journal/seed.json:/opened_at']
        elif shape=='stage-stream':
            after=[json.loads(line) for line in path.read_bytes().splitlines()]
            checks.update(rc=call['rc']==0,count=len(after)==3)
            checks['preserved_seeds']=len(after)==3 and all(
                all(v.get(k)==x for k,x in original.items() if k not in ['stage','stage_at'])
                for original,v in zip(values[:2],after[:2]))
            checks['ordered_ids']=[v.get('journal_id') for v in after]==['seed','seed-2',None]
            checks['new_stage']=all(v.get('stage')=='next-stage' and isinstance(v.get('stage_at'),str) for v in after)
            checks['null_object_fields']=len(after)==3 and set(after[2])=={'stage','stage_at'}
            slots=['rollback-journal/seed.json:value[%d]/stage_at'%i for i in range(len(after))]
        elif shape=='open-write-fails':
            checks.update(rc=call['rc']==1,no_journal=not path.exists(),no_temporary=list(directory.iterdir())==[])
        else:
            checks.update(rc=call['rc']==(1 if shape.endswith('write-fails') else 0),unchanged=path.read_bytes()==before,
                          no_temporary=list(directory.iterdir())==[path])
        record(shape,[call],checks,home,slots)
    for changed in [False,True]:
        home=root/('snapshot-changed' if changed else 'snapshot-kept')
        snapshots=home/'snapshots';snapshots.mkdir(parents=True)
        project=home/'project';project.mkdir()
        manifest=project/'package.json';manifest.write_bytes(b'{"name":"fixture"}\n')
        before=manifest.read_bytes();listing=b'package.json\nyarn.lock\n'
        (snapshots/'seed_monitored_files.list').write_bytes(listing)
        request=dict(op='snapshot',path=str(project),id='seed',action='stage')
        calls=[invoke(home,request)]
        if changed:manifest.write_bytes(b'{"name":"changed"}\n')
        live=manifest.read_bytes();calls.append(invoke(home,dict(request,action='confirm')))
        pointer=home/('confirmed_'+hashlib.md5(str(project).encode()).hexdigest())
        meta=snapshots/'verified-seed_meta.json'
        checks=dict(rc=all(c['rc']==0 for c in calls),project_unchanged_by_hook=manifest.read_bytes()==live,
                    list_unchanged=(snapshots/'seed_monitored_files.list').read_bytes()==listing)
        if changed:
            checks.update(no_pointer=not pointer.exists(),no_meta=not meta.exists(),warning=bool(calls[-1]['stdout_hex']))
            slots=[]
        else:
            value=json.loads(meta.read_bytes()) if meta.exists() else {}
            copy=snapshots/'verified-seed_package.json'
            checks.update(quiet=not calls[-1]['stdout_hex'],pointer=pointer.exists() and pointer.read_bytes()==b'verified-seed\n',
                          copy=copy.exists() and copy.read_bytes()==before,own_project=value.get('project_dir')==str(project),
                          identity=value.get('snapshot_id')=='verified-seed' and value.get('verified_from')=='seed',
                          parent=value.get('parent_snapshot_id') is None,timestamp_type=type(value.get('timestamp')) is int)
            slots=['snapshots/verified-seed_meta.json:/timestamp']
        record('snapshot-changed' if changed else 'snapshot-kept',calls,checks,home,slots)
report=dict(instrumented=False,exact_clock_provenance='unobserved; not compared as equal',rows=rows,
            failures=sum(not row['passed'] for row in rows))
Path(a.report).write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(dict(cases=len(rows),failures=report['failures'])))
raise SystemExit(1 if report['failures'] else 0)
