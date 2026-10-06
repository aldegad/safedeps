#!/usr/bin/env python3
"""Exercise native I/O failures with disk permissions and the report oracle.

Run remotely as an unprivileged user. These fixtures replace e2e's jq/cp/rm
PATH shims with the same failed operation on disk. Each side receives the
same synthetic pending record and snapshot at the same absolute path. The
existing independent oracle is unchanged, and the expected failure line is
required separately, so an injection that never reached the operation fails.
This is a focused supplement, not a complete e2e or form-coverage result.
The absent-lockfile fixture makes its project directory read-only: this
prevents creating the lockfile AND removing node_modules itself. The
overwrite fixture keeps a writable parent and checks that removal continues.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--core',required=True)
p.add_argument('--report',required=True)
p.add_argument('--only',help='Comma-separated fixture names')
p.add_argument('--side',choices=['both','bash','rust'],default='both')
p.add_argument('--meta-shape',choices=['plain','v1','string-version','unstated','asked'],default='plain')
p.add_argument('--expect-oracle-text',help='Require a Rust-only source mutant to fail at this oracle diagnostic')
p.add_argument('--expect-assertion',help='Require a source mutant to violate this focused original e2e assertion')
a=p.parse_args()
if a.expect_oracle_text and (a.side!='rust' or not a.only or ',' in a.only):
    p.error('a source-mutation control requires --side rust and one --only fixture')
if a.expect_assertion and (a.side!='rust' or not a.only or ',' in a.only or a.expect_oracle_text):
    p.error('an assertion control requires one Rust fixture and no oracle-text control')
if os.geteuid()==0:
    p.error('permission injection needs an unprivileged user; no fixture was verified')
root=Path(__file__).resolve().parents[2]
core=str(Path(a.core).resolve(strict=True))
runner='''#!/bin/bash
set -uo pipefail
source "$ROOT/scripts/test/lib/report-oracle.sh"
oracle_init "$BOX/oracle"
payload=$(cat "$BOX/payload.json")
call="$BOX/oracle/call"
mkdir -p "$call"
[[ "$SIDE" != rust ]] || : > "$call/native-owner-source"
oracle_before "$call" "$payload"
if [[ "$FAULT" == unread-meta ]]; then
  : > "$call/record-unread"
  chmod 000 "$SAFEDEPS_HOME/snapshots/pre_meta.json"
fi
if [[ "$SIDE" == bash ]]; then
  out=$(printf '%s' "$payload" | "$ROOT/scripts/safedeps-post-verify.sh")
  rc=$?
else
  request=$(jq -cn --arg input "$payload" '{op:"hook",input:$input}')
  out=$(printf '%s' "$request" | "$CORE" post-probe)
  rc=$?
fi
printf '%s\\n' "$out" > "$BOX/hook.out"
printf '%s\\n' "$rc" > "$BOX/hook.rc"
# Restore only the test's permissions, after the hook. The oracle's unread
# marker came from the fixture before the hook, not from the hook's output.
[[ "$FAULT" != unread-meta ]] || chmod 600 "$SAFEDEPS_HOME/snapshots/pre_meta.json"
[[ "$rc" == 0 ]] || exit "$rc"
oracle_message "$call" "$payload" "$out"
'''

def unlock(d):
    # This owns only this fixture; permissions must allow its cleanup.
    for path in [d]+list(d.rglob('*')):
        if not path.is_symlink():
            path.chmod(0o700 if path.is_dir() else 0o600)

def seed(d,kind):
    if d.exists():unlock(d);shutil.rmtree(d)
    home=d/'state';project=d/'project';snapshot=home/'snapshots'
    snapshot.mkdir(parents=True);(home/'pending').mkdir();project.mkdir()
    for name in ['advisory.log','reorg.log']:(home/name).touch()
    (project/'node_modules/.bin').mkdir(parents=True)
    (project/'node_modules/kept').mkdir()
    (project/'node_modules/kept/data').write_text('fixture bytes\n')
    (project/'node_modules/.bin/drop').write_text('#!/bin/sh\nexit 0\n')
    before={'name':'before','dependencies':{}}
    lock={'lockfileVersion':3,'packages':{}}
    (snapshot/'pre_package.json').write_text(json.dumps(before)+'\n')
    (snapshot/'pre_package-lock.json').write_text(json.dumps(lock)+'\n')
    (snapshot/'pre_monitored_files.list').write_text('package-lock.json\npackage.json\n')
    (snapshot/'pre_packages.list').touch();(snapshot/'pre_bins.list').touch()
    command='grep -n "npm install" README.md' if kind in ['trace-untraced','trace-deadline'] else 'npm install fixture-item'
    record=dict(record=2,snapshot_id='pre',tool_use_id='fault-call',project_dir=str(project),
                ignore_scripts_injected=False,command=command,updated_command=command)
    (snapshot/'pre_meta.json').write_text(json.dumps(record)+'\n')
    (home/'pending/id-fault-call.json').write_text(json.dumps(record)+'\n')
    if a.meta_shape!='plain':
        meta=dict(record)
        if a.meta_shape=='v1':meta['record']=1
        elif a.meta_shape=='string-version':meta['record']='2'
        elif a.meta_shape=='unstated':meta.pop('ignore_scripts_injected')
        elif a.meta_shape=='asked':meta.update(ignore_scripts_injected=True,updated_command=command+' --ignore-scripts')
        (snapshot/'pre_meta.json').write_text(json.dumps(meta)+'\n')
    (project/'package.json').write_text(json.dumps(dict(name='after',dependencies={}))+'\n')
    (project/'package-lock.json').write_text(json.dumps(dict(lock,name='after'))+'\n')
    if kind in ['restore-link','confirm-link']:
        target=d/'outside-lock.json';target.write_bytes((project/'package-lock.json').read_bytes())
        (project/'package-lock.json').unlink();(project/'package-lock.json').symlink_to(target)
    if kind in ['confirm-link','confirm-clean','registry-claude']:
        (snapshot/'pre_monitored_files.list').write_text('package-lock.json\npackage.json\nyarn.lock\n')
        (snapshot/'pre_yarn.lock.missing').touch()
        for name in ['package.json','package-lock.json']:
            (snapshot/('pre_'+name)).write_bytes((project/name).read_bytes())
        (snapshot/'pre_bins.list').write_text('drop\n')
        if kind=='confirm-link':
            record['ignore_scripts_injected']=True
            (snapshot/'pre_meta.json').write_text(json.dumps(record)+'\n')
            (home/'pending/id-fault-call.json').write_text(json.dumps(record)+'\n')
    pending=home/'pending/id-fault-call.json'
    if kind=='pending-gone':(snapshot/'pre_meta.json').unlink()
    if kind=='pending-empty':
        record.pop('snapshot_id');pending.write_text(json.dumps(record)+'\n')
    if kind=='pending-object':pending.write_text('[1,2]\n')
    if kind=='pending-nodir':
        record.pop('project_dir');pending.write_text(json.dumps(record)+'\n')
    if kind=='pending-hash':
        record['dir_hash']='seed-wrong-hash';pending.write_text(json.dumps(record)+'\n')
        (home/'confirmed_seed-wrong-hash').write_text('decoy\n')
        for path in list(snapshot.glob('pre_*')):
            (snapshot/('decoy_'+path.name[4:])).write_bytes(path.read_bytes())
    if kind in ['pending-fallback','pending-legacy']:
        pending.unlink()
        if kind=='pending-fallback':
            # This plain command needs no quote/flag normalization. This is
            # the original shell pending key, independent of the core reader.
            dh=hashlib.md5(str(project).encode()).hexdigest()
            key=dh+'_'+hashlib.md5(command.encode()).hexdigest()
            record.pop('tool_use_id')
            (home/'pending'/(key+'__pre.json')).write_text(json.dumps(record)+'\n')
        else:
            (home/'current_snapshot_id').write_text('pre\n')
            (home/'current_project_dir').write_text(str(project)+'\n')
    if kind=='backstop-rollback' or kind.startswith('trace-'):
        pending.unlink()
        (home/('confirmed_'+hashlib.md5(str(project).encode()).hexdigest())).write_text('pre\n')
        (snapshot/'pre_meta.json').write_text('{"record":2,"snapshot_id":"pre"}\n')
        bad=dict(lockfileVersion=3,packages={'node_modules/fixture-unapproved':dict(version='1.0.0')})
        (project/'package-lock.json').write_text(json.dumps(bad)+'\n')
        for sub in ['osv','kev']:(home/'cache'/sub).mkdir(parents=True)
        key=hashlib.sha256(b'osv\nnpm\nfixture-unapproved\n1.0.0').hexdigest()
        (home/'cache/osv'/(key+'.json')).write_text('{"vulns":[]}\n')
        (home/'cache/kev/known_exploited_vulnerabilities.json').write_text('{"vulnerabilities":[]}\n')
        if kind.startswith('trace-'):
            lock=project/'package-lock.json'
            if kind=='trace-link':lock.rename(project/'target.json');lock.symlink_to('target.json')
            facts=d/'trace-facts.sh'
            facts.write_text('''#!/bin/bash
set -eu
source "$ROOT/lib/gates/backstop-trace.sh"
for rel in package-lock.json node_modules/.package-lock.json node_modules; do
 printf '%s\\t%s\\t%s\\n' "$rel" "$(safedeps_tree_inode "$1/$rel")" "$(safedeps_tree_clock "$1/$rel")"
done
''')
            raw=subprocess.check_output(['bash',str(facts),str(project)],env=dict(os.environ,ROOT=str(root),LC_ALL='C'),text=True)
            inodes={};clocks={}
            for line in raw.splitlines():
                name,inode,clock=line.split('\t');inodes[name]=inode;clocks[name]=clock
            directory=home/'pending/backstop';directory.mkdir()
            baseline=directory/'id-fault-call.trace';baseline.touch()
            dh=hashlib.md5(str(project).encode()).hexdigest()
            key=dh+'_'+hashlib.md5(command.encode()).hexdigest()
            entry=dict(key=key,baseline=str(baseline),resolution='subsecond',inodes=inodes,clocks=clocks)
            (directory/'id-fault-call.json').write_text(json.dumps(entry)+'\n')
            time.sleep(.03)
            if kind in ['trace-lock','trace-link']:lock.write_bytes(lock.read_bytes())
            if kind=='trace-tree':(project/'node_modules/kept/data').write_text('changed fixture bytes\n')
    if kind=='registry-claude':
        name='fixture-approved';url='https://registry.npmjs.org/fixture-approved/-/fixture-approved-1.0.0.tgz'
        (project/'package-lock.json').write_text(json.dumps(dict(lockfileVersion=3,packages={'node_modules/'+name:dict(version='1.0.0',resolved=url)}))+'\n')
        ledger=home/'approved-specs';ledger.mkdir()
        key=hashlib.sha256(('npm\n'+name+'\n1.0.0').encode()).hexdigest()
        approval=dict(hash='sha256:'+key,ecosystem='npm',package=name,version='1.0.0',version_range='1.0.0',
                      approved_at='2001-01-01T00:00:00Z',expires_at='2099-01-01T00:00:00Z',approved_by='fixture',evidence={})
        (ledger/('sha256-'+key+'.json')).write_text(json.dumps(approval)+'\n')
        for sub in ['osv','kev']:(home/'cache'/sub).mkdir(parents=True)
        key=hashlib.sha256(('osv\nnpm\n'+name+'\n1.0.0').encode()).hexdigest()
        (home/'cache/osv'/(key+'.json')).write_text('{"vulns":[]}\n')
        (home/'cache/kev/known_exploited_vulnerabilities.json').write_text('{"vulnerabilities":[]}\n')
        binaries=d/'bin';binaries.mkdir();npm=binaries/'npm'
        npm.write_text('#!/bin/sh\nprintf \'%s\\n\' \'{"registry":"http://127.0.0.1:9/elsewhere/","replace-registry-host":"npmjs"}\'\n')
        npm.chmod(0o755)
    hook_cwd=d/'hook-cwd';hook_cwd.mkdir()
    if kind=='pending-nodir':shutil.copytree(project,hook_cwd,dirs_exist_ok=True)
    if kind=='restore-readonly':(project/'package-lock.json').chmod(0o444)
    if kind=='restore-absent':
        (project/'package-lock.json').unlink();project.chmod(0o555)
    if kind=='remove-readonly':(project/'node_modules/kept').chmod(0o555)
    payload=dict(tool_name='Bash',tool_input=dict(command=command),cwd=str(project),tool_use_id='fault-call')
    (d/'payload.json').write_text(json.dumps(payload))
    return home,project

rows=[]
print('start:',subprocess.check_output(['uptime'],text=True).strip(),flush=True)
with tempfile.TemporaryDirectory(prefix='core-post-faults.') as tmp:
    box=Path(tmp).resolve();script=box/'oracle-run.sh';script.write_text(runner)
    d=box/'paired'
    kinds=['unread-meta','restore-readonly','restore-absent','remove-readonly']
    if a.only:kinds=a.only.split(',')
    allowed=kinds if not a.only else ['unread-meta','restore-readonly','restore-absent','remove-readonly',
        'restore-link','confirm-link','confirm-clean','pending-gone','pending-empty','pending-object',
        'pending-nodir','pending-hash','pending-fallback','pending-legacy','backstop-rollback',
        'trace-untraced','trace-lock','trace-link','trace-tree','trace-deadline','registry-claude']
    if any(kind not in allowed for kind in kinds):p.error('unknown fixture')
    for kind in kinds:
        if a.only and kind not in a.only.split(','):continue
        for side in (['bash','rust'] if a.side=='both' else [a.side]):
            home,project=seed(d,kind)
            env=dict(os.environ,ROOT=str(root),CORE=core,BOX=str(d),SAFEDEPS_HOME=str(home),LC_ALL='C',FAULT=kind,SIDE=side)
            if kind=='trace-deadline':env['SAFEDEPS_BACKSTOP_WALK_SECONDS']='1'
            if (d/'bin').is_dir():env['PATH']=str(d/'bin')+os.pathsep+env['PATH']
            try:
                result=subprocess.run(['bash',str(script)],cwd=d/'hook-cwd',env=env,capture_output=True,text=True,timeout=30)
                hook_rc=int((d/'hook.rc').read_text()) if (d/'hook.rc').exists() else None
                raw=(d/'hook.out').read_text() if (d/'hook.out').exists() else ''
                try:message=json.loads(raw)['systemMessage']
                except (ValueError,KeyError,TypeError):message=''
                log=(home/'advisory.log').read_text()
                if kind=='unread-meta':
                    reached='could not read the pre-guard\'s record of this command' in log and '--ignore-scripts' not in message
                elif kind=='restore-link':
                    reached=f'refused restore of {project}/package-lock.json: {project}/package-lock.json is a symbolic link to ' in message
                elif kind=='confirm-link':
                    reached=f'did not run npm rebuild: {project}/package-lock.json is a symbolic link to ' in message
                elif kind=='confirm-clean':
                    reached=not message and bool(list(home.glob('confirmed_*')))
                elif kind=='registry-claude':
                    reached='this install fetched packages from a registry that is not the public npm registry (' in message and '(on Codex it cannot)' not in message
                elif kind=='trace-untraced':reached=not message and 'BACKSTOP UNTRACED:' in log
                elif kind=='trace-deadline':
                    reached=('A rollback ran.' in message and not (project/'node_modules').exists()
                             and f'the walk of {project}/node_modules did not finish within 1s' in log)
                elif kind.startswith('trace-'):reached='A rollback ran.' in message and 'BACKSTOP traced:' in log
                elif kind in ['pending-gone','pending-empty','pending-object']:
                    clause={'pending-gone':'is not a file; this hook set the record aside',
                            'pending-empty':'names no snapshot; this hook set the record aside',
                            'pending-object':'is not one JSON object; this hook set the record aside'}[kind]
                    reached=clause in log and not (home/'pending/id-fault-call.json').exists()
                elif kind in ['pending-nodir','pending-hash','backstop-rollback']:
                    reached='A rollback ran.' in message and f'removed {project}/node_modules' in message
                elif kind in ['pending-fallback','pending-legacy']:
                    reached=not message and 'BACKSTOP clean:' in log
                    if kind=='pending-fallback':reached=reached and len(list((home/'pending').glob('*.json')))==1
                    else:reached=reached and (home/'current_snapshot_id').read_text()=='pre\n'
                elif kind.startswith('restore-'):
                    suffix='does not exist' if kind=='restore-absent' else 'differs from the snapshot'
                    reached=f'not restored {project}/package-lock.json: cp exit 1; {project}/package-lock.json {suffix}' in message
                else:
                    reached=f'not removed {project}/node_modules: rm exit 1; {project}/node_modules exists' in message
                journal_closed=not list((home/'rollback-journal').glob('*.json'))
                tree_exists=(project/'node_modules').exists()
                continued=True
                if kind=='restore-readonly':
                    continued=not tree_exists and f'removed {project}/node_modules' in message
                elif kind=='restore-absent':
                    continued=(tree_exists and f'not removed {project}/node_modules: rm exit 1; {project}/node_modules exists' in message)
                # The closed oracle checks the bytes/logs/disk, while this
                # assertion verifies this fixture reached its failure path.
                passed=hook_rc==0 and result.returncode==0 and reached and continued and journal_closed
                if a.expect_oracle_text:
                    passed=hook_rc==0 and result.returncode!=0 and a.expect_oracle_text in result.stderr and journal_closed
                assertion={'trace-untraced':'a grep right after a pull outside the gate: the backstop says nothing',
                           'trace-lock':'an install the pre-guard did not read: the backstop rolls back',
                           'trace-tree':'a write only into node_modules is a trace',
                           'trace-deadline':'a walk past its deadline: the backstop rolls back',
                           'trace-link':'a write through a linked lockfile is a trace'}.get(kind)
                if a.expect_assertion:
                    passed=hook_rc==0 and result.returncode==0 and not reached and a.expect_assertion==assertion and journal_closed
                rows.append(dict(name=kind,side=side,passed=passed,injection_reached=reached,
                                 rollback_continued=continued,journal_closed=journal_closed,node_modules_exists=tree_exists,
                                 rc=result.returncode,hook_rc=hook_rc,hook_stdout=raw,
                                 oracle_stdout=result.stdout,oracle_stderr=result.stderr))
                rows[-1]['assertion']=assertion
                print(('ok' if passed else 'FAIL'),side,kind,flush=True)
            finally:
                unlock(d)
report=dict(cases=len(rows),failures=sum(not r['passed'] for r in rows),rows=rows)
Path(a.report).write_text(json.dumps(report,indent=2)+'\n')
print('end:',subprocess.check_output(['uptime'],text=True).strip(),flush=True)
raise SystemExit(0 if rows and report['failures']==0 else 1)
