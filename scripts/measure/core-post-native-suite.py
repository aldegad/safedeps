#!/usr/bin/env python3
"""Build narrow native failure copies, then run the original e2e assertions.

No product test switch or PATH injection is used for native operations.
I/O faults use permissions; this builds copies for native delay, clock
precision, and process query failure. It does not claim a Rust pre result.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--archive',required=True)
p.add_argument('--core',required=True)
p.add_argument('--cargo',required=True)
p.add_argument('--run-dir',required=True)
p.add_argument('--pre-core')
a=p.parse_args()
archive=Path(a.archive).resolve(strict=True);core=Path(a.core).resolve(strict=True);cargo=Path(a.cargo).resolve(strict=True)
run=Path(a.run_dir).resolve();run.mkdir(parents=True,exist_ok=False)
root=Path(__file__).resolve().parents[2]

def execute(argv,name,env=None):
    with (run/(name+'.log')).open('wb') as f:r=subprocess.run(argv,stdout=f,stderr=f,env=env)
    (run/(name+'.rc')).write_text(str(r.returncode)+'\n')
    return r.returncode

spec=importlib.util.spec_from_file_location('fault_edits',Path(__file__).with_name('core-post-native-injections.py'))
fault_edits=importlib.util.module_from_spec(spec);spec.loader.exec_module(fault_edits)
edits=fault_edits.EDITS
cores={}
for name,(relative,old,new) in edits.items():
    target=run/name;target.mkdir();subprocess.run(['tar','xf',str(archive),'-C',str(target)],check=True)
    path=target/relative;text=path.read_text()
    if text.count(old)!=1:raise SystemExit(name+': source injection is not unique')
    path.write_text(text.replace(old,new))
    (run/(name+'.mutation.json')).write_text(json.dumps(dict(file=relative,old=old,new=new),indent=2)+'\n')
    rc=execute([str(cargo),'build','--manifest-path',str(target/'rust/Cargo.toml'),'--release','--locked','--offline','-j1'],name+'-build',dict(os.environ,SAFEDEPS_CORE_BUILD_KIND='checkout'))
    if rc:raise SystemExit(rc)
    cores[name]=target/'rust/target/release/safedeps-core'
argv=[sys.executable,str(root/'scripts/measure/core-post-suite.py'),'--archive',str(archive),'--core',str(core),
      '--native-faults','--suite','e2e','--run-dir',str(run/'e2e'),
      '--walk-core',str(cores['walk']),'--owner-core',str(cores['owner']),'--coarse-core',str(cores['coarse'])]
if a.pre_core:argv+=['--pre-core',a.pre_core]
rc=execute(argv,'e2e')
raise SystemExit(rc)
