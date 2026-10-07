#!/usr/bin/env python3
"""Record controls on isolated native source copies, with fixed expectations.

Public pre owns rewrite production. The snapshot collision fixture uses the
snapshot/pending probe with a fixed source clock in both candidate copies;
that is a component test, not a measured same-second public hook run.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
CASES = {
    'MarkOrig': [('rust/src/pre/install.rs', 'snap.mark_rewrite(command,unread)',
                  'snap.mark_rewrite(&call.command,unread)')],
    'MarkSkip': [('rust/src/pre/snapshot.rs',
                  '    pub fn mark_rewrite(&self,command:&[u8],unread:bool)->io::Result<()> {',
                  '    pub fn mark_rewrite(&self,command:&[u8],unread:bool)->io::Result<()> { return Ok(());')],
    'KeyRecords': [('rust/src/pre/pending.rs',
                    'let base=if let Some(id)=&id{dir.join(format!("id-{}",id))}else{',
                    'let base=if let Some(id)=None::<&String>{dir.join(format!("id-{}",id))}else{')],
    'Same': [('rust/src/pre/snapshot.rs',
              'let base=format!("{}_{}-{}",timestamp,hash,std::process::id());',
              'let base=format!("{}_{}",timestamp,hash);'),
             ('rust/src/pre/snapshot.rs',
              'fs::OpenOptions::new().create_new(true).write(true).mode(0o600).open(list)',
              'fs::OpenOptions::new().create(true).truncate(true).write(true).mode(0o600).open(list)')],
}
DIAGNOSTICS = {
    'MarkOrig': 'the command a record says safedeps wrote is not the rewrite the pre-guard printed',
    'MarkSkip': 'the pre-guard printed a rewrite and no single record says it wrote one',
    'KeyRecords': 'install records must be addressed by their own call ids',
    'Same': 'a snapshot call must preserve every previous snapshot byte',
}
CLOCK = ('rust/src/pre/snapshot.rs', 'os::wall(os::WallRole::PreSnapshot).seconds()', '1_000_000_000i64')
RUNNER = '''#!/bin/bash
set -euo pipefail
source "$ROOT/scripts/test/lib/report-oracle.sh"
oracle_init "$BOX/oracle"
call="$BOX/oracle/pre"
mkdir "$call"
oracle_pre_before "$call"
out=$("$CORE" pre < "$BOX/input.json")
printf '%s' "$out" > "$BOX/hook.stdout"
printf '0\\n' > "$BOX/hook.rc"
oracle_pre "$call" "$out"
'''


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ('archive', 'core', 'cargo', 'run-dir'): p.add_argument('--'+name, required=True)
    p.add_argument('--names', default=','.join(CASES))
    a = p.parse_args()
    archive, core, cargo = [Path(v).resolve(strict=True) for v in (a.archive, a.core, a.cargo)]
    run = Path(a.run_dir).resolve(); run.mkdir(parents=True, exist_ok=False)
    names = a.names.split(',')
    if not names or any(n not in CASES for n in names): p.error('unknown control')

    def build(name, edits):
        tree=run/(name+'-source');tree.mkdir()
        subprocess.run(['tar','xf',str(archive),'-C',str(tree)],check=True)
        for rel, old, new in edits:
            path=tree/rel;text=path.read_text()
            if text.count(old)!=1:raise RuntimeError(name+': mutation anchor not unique: '+rel)
            path.write_text(text.replace(old,new))
        (run/(name+'.mutation.json')).write_text(json.dumps(edits,indent=2)+'\n')
        with (run/(name+'-build.log')).open('wb') as log:
            r=subprocess.run([str(cargo),'build','--manifest-path',str(tree/'rust/Cargo.toml'),
                              '--release','--locked','--offline','-j1'],stdout=log,stderr=log,
                              env=dict(os.environ,SAFEDEPS_CORE_BUILD_KIND='checkout'))
        (run/(name+'-build.rc')).write_text(str(r.returncode)+'\n')
        if r.returncode:raise RuntimeError('build failed: '+name)
        return tree/'rust/target/release/safedeps-core'

    def fixture(name, binary, label):
        box=run/label;project=box/'project';project.mkdir(parents=True)
        home=box/'state';home.mkdir();(box/'home').mkdir()
        (project/'package.json').write_text('{"name":"fixture","version":"1.0.0"}\n')
        (project/'package-lock.json').write_text('{"lockfileVersion":3,"packages":{}}\n')
        env={k:v for k,v in os.environ.items() if not k.startswith('SAFEDEPS_') and not k.lower().startswith('npm_config_')}
        env.update(ROOT=str(ROOT),BOX=str(box),CORE=str(binary),SAFEDEPS_HOME=str(home),
                   HOME=str(box/'home'),NPM_CONFIG_USERCONFIG='/dev/null',LC_ALL='C')
        if name.startswith('Mark'):
            payload=dict(tool_name='Bash',tool_input=dict(command='npm install'),cwd=str(project),tool_use_id='record-call')
            (box/'input.json').write_text(json.dumps(payload))
            script=box/'run.sh';script.write_text(RUNNER)
            r=subprocess.run(['bash',str(script)],env=env,cwd=project,capture_output=True)
            hook_rc=(box/'hook.rc').read_text().strip() if (box/'hook.rc').exists() else None
            diagnostic=DIAGNOSTICS[name].encode() in r.stderr
            if r.returncode==0:
                out=json.loads((box/'hook.stdout').read_bytes())
                if not out.get('hookSpecificOutput',{}).get('updatedInput',{}).get('command'):
                    raise RuntimeError('rewrite fixture did not reach a rewrite')
            result=dict(rc=r.returncode,hook_rc=hook_rc,diagnostic_found=diagnostic,
                        stdout=r.stdout.decode(),stderr=r.stderr.decode())
        else:
            snapshots=home/'snapshots'; observations=[]; previous={}; failed=False
            for i in range(2):
                payload=dict(project=str(project),command='npm ci',tool_use_id='record-'+str(i),
                             pending=dict(cwd=str(project),trace=True))
                (project/'package.json').write_text(json.dumps(dict(name='fixture-'+str(i)))+'\n')
                r=subprocess.run([str(binary),'pre-probe'],input=json.dumps(payload).encode(),env=env,cwd=project,capture_output=True)
                if r.returncode:raise RuntimeError('snapshot fixture failed: '+repr(r.stderr))
                now={p.name:p.read_bytes().hex() for p in snapshots.rglob('*') if p.is_file()}
                if name=='Same' and any(now.get(k)!=v for k,v in previous.items()):failed=True
                previous=now
                observations.append(dict(input=payload,rc=r.returncode,stdout=r.stdout.decode(),stderr=r.stderr.decode()))
            records={p.name:json.loads(p.read_bytes()) for p in (home/'pending').glob('*.json')}
            if name=='KeyRecords':
                failed=set(records)!= {'id-record-0.json','id-record-1.json'} or any(records.get('id-record-'+str(i)+'.json',{}).get('tool_use_id')!='record-'+str(i) for i in range(2))
            result=dict(rc=int(failed),hook_rc='0',diagnostic_found=failed,observations=observations,records=records,
                        stderr=('not ok - '+DIAGNOSTICS[name]+'\n') if failed else '',stdout='')
        (run/(label+'.json')).write_text(json.dumps(result,indent=2)+'\n')
        (run/(label+'.log')).write_text(result['stdout']+result['stderr'])
        (run/(label+'.rc')).write_text(str(result['rc'])+'\n')
        return result

    rows=[]
    for name in names:
        extra=[CLOCK] if name=='Same' else []
        baseline=fixture(name,build(name+'-clock',extra) if extra else core,name+'-baseline')
        if baseline['rc']:raise RuntimeError(name+': baseline failed; no control claimed')
        mutant=build(name,extra+CASES[name])
        result=fixture(name,mutant,name+'-control')
        passed=result['rc']==1 and result['hook_rc']=='0' and result['diagnostic_found']
        rows.append(dict(name=name,baseline=baseline,control=result,passed=passed))
        (run/'result.json').write_text(json.dumps(dict(rows=rows),indent=2)+'\n')
        print(('ok - ' if passed else 'not ok - ')+name+': '+DIAGNOSTICS[name],flush=True)
        if not passed:return 1
    return 0

if __name__=='__main__':raise SystemExit(main())
