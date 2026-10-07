#!/usr/bin/env python3
"""Native test fixtures. Permission faults exercise the unchanged core.

Clock, slow walk and owner-query faults use named source copies. These are
never installed, and their identity and reached operation are recorded apart
from the ordinary binary. No product environment switch is added.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import shutil
import stat
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]

def dump(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def receipt_code(label, detail='b"reached"'):
    return ('let _=std::fs::write(crate::state::guard_dir().join(".c3-reached"), '
            + detail + '); /* ' + label + ' */ ')

def prepare(a):
    if os.geteuid() == 0:
        raise RuntimeError('permission fixtures require a non-root uid')
    if platform.system() != 'Darwin':
        raise RuntimeError('native query source copies currently require Darwin; not a passing unsupported run')
    tree = Path(a.tree).resolve(strict=True)
    core = Path(a.core).resolve(strict=True)
    out = Path(a.output).resolve()
    out.mkdir(parents=True, exist_ok=False)
    spec = importlib.util.spec_from_file_location('edits', ROOT/'scripts/measure/core-post-native-injections.py')
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    edits = dict(module.EDITS)
    edits.update({'pre-'+k:v for k,v in module.PRE_EDITS.items() if k != 'mark'})
    edits['pre-same'] = ('rust/src/pre/snapshot.rs',
        'let timestamp=os::wall(os::WallRole::PreSnapshot).seconds();',
        'let timestamp='+str(int(time.time()))+'i64;')
    # The first snapshot and pending writes succeed. Only the atomic rewrite
    # writer encounters EACCES, on its actual directory, after its JSON read.
    edits['pre-mark'] = ('rust/src/pre/snapshot.rs',
        '        state::write_state_file(&self.path(b"meta.json"),jq::pretty(&jq::from_value(&value)).as_bytes())',
        '''        let mode=fs::metadata(&self.root)?.permissions();
        fs::set_permissions(&self.root,fs::Permissions::from_mode(0o555))?;
        let result=state::write_state_file(&self.path(b"meta.json"),jq::pretty(&jq::from_value(&value)).as_bytes());
        fs::set_permissions(&self.root,mode)?;
        let evidence=format!("{:?}",result);
        let _=fs::write(crate::state::guard_dir().join(".c3-reached"),evidence);
        result''')
    call = 'unsafe{proc_pidinfo(pid,3,1,&mut b as *mut _ as *mut _,size)}'
    edits['owner'] = ('rust/src/post/process.rs', call,
        '{'+receipt_code('query zero','format!(r#"{{"pid":"{}","expected_bytes":{},"returned_bytes":0}}"#,pid,size)')+'0}')
    edits['owner-short'] = ('rust/src/post/process.rs', call,
        '{'+receipt_code('query short','format!(r#"{{"pid":"{}","expected_bytes":{},"returned_bytes":{}}}"#,pid,size,size-8)')+'size-8}')
    edits['owner-wrong-pid'] = ('rust/src/post/process.rs', '    if b.pid!=pid as u32',
        '    b.pid=b.pid.wrapping_add(1); '+receipt_code('wrong pid','format!(r#"{{"pid":"{}","expected_bytes":{},"returned_bytes":{},"returned_pid":"{}"}}"#,pid,size,size,b.pid)')+'\n    if b.pid!=pid as u32')
    # A receipt is emitted at the changed observation, not by the selector.
    for name in ['walk','coarse','pre-coarse','pre-seconds','pre-same']:
        relative, old, new = edits[name]
        if name == 'coarse':
            new = 'if {'+receipt_code(name)+'(m.ctime(),0)>(b.mtime(),b.mtime_nsec())}'
        else:
            new = receipt_code(name) + new
        edits[name] = relative, old, new
    rows = {}
    for name, (relative, old, new) in edits.items():
        target = out/name
        shutil.copytree(tree, target, ignore=shutil.ignore_patterns('.git','.kuma','target','native','__pycache__'))
        file = target/relative; before = file.read_text()
        if before.count(old) != 1:
            raise RuntimeError(name+': injection anchor must occur exactly once')
        file.write_text(before.replace(old, new))
        dump(out/(name+'.patch.json'), dict(file=relative, old=old, new=new))
        argv=[a.cargo,'build','--manifest-path',str(target/'rust/Cargo.toml'),'--release','--locked','--offline','-j1']
        with (out/(name+'.build.log')).open('wb') as log:
            rc=subprocess.run(argv,env=dict(os.environ,SAFEDEPS_CORE_BUILD_KIND='checkout'),stdout=log,stderr=log).returncode
        (out/(name+'.build.rc')).write_text(str(rc)+'\n')
        if rc: raise RuntimeError(name+': build failed')
        binary=target/'rust/target/release/safedeps-core'
        check=subprocess.run([str(binary),'stamp','--check'],capture_output=True)
        (out/(name+'.stamp.log')).write_bytes(check.stdout+check.stderr)
        if check.returncode:raise RuntimeError(name+': source stamp mismatch')
        rows[name]=dict(core=str(binary),sha256=digest(binary),source=relative,source_sha256=digest(file))
    manifest=dict(schema='native-test-fixtures/1',core=str(core),sha256=digest(core),copies=rows,
                  receipts=str(out/'reached.jsonl'),uid=os.geteuid(),
                  retired={'owner-bad-start':'ps lstart text parser absent; native zero/short/wrong pid and malformed journal opening remain'})
    dump(out/'manifest.json',manifest)
    print(out/'manifest.json')

def denied(path, operation):
    try:
        if operation == 'read': fd=os.open(path,os.O_RDONLY)
        elif operation == 'write': fd=os.open(path,os.O_WRONLY)
        elif operation == 'create': fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
        else:
            os.unlink(path)
            raise RuntimeError('permission fault did not prevent unlink: '+str(path))
        os.close(fd)
        if operation=='create':path.unlink()
    except PermissionError as e:
        return dict(path=str(path),operation=operation,errno=e.errno,uid=os.geteuid(),reached=True)
    raise RuntimeError('permission fault did not prevent '+operation+': '+str(path))

def hook(a):
    manifest=json.loads(Path(a.manifest).read_text())
    raw=sys.stdin.buffer.read(); payload=json.loads(raw)
    project=Path(payload['cwd']); home=Path(os.environ['SAFEDEPS_HOME'])
    call=Path(os.environ['ORACLE_CALL']) if os.environ.get('ORACLE_CALL') else None
    fault=os.environ.get('SAFEDEPS_TEST_FAULT','')
    env=dict(os.environ);env.pop('SAFEDEPS_TEST_FAULT',None)
    if a.stage=='post' and call:(call/'native-owner-source').touch()
    selected={'bs_sec':'pre-seconds','same':'pre-same','markfail':'pre-mark',
              'bs_slow':'walk','owner-empty':'owner','owner-short':'owner-short','owner-wrong-pid':'owner-wrong-pid'}.get(fault)
    if fault=='bs_mix':selected='pre-coarse' if a.stage=='pre' else 'coarse'
    binary=manifest['copies'][selected]['core'] if selected else manifest['core']
    wanted=manifest['copies'][selected]['sha256'] if selected else manifest['sha256']
    if digest(Path(binary))!=wanted:raise RuntimeError('fixture binary changed')
    restore=[]; facts=[]; marker=home/'.c3-reached'
    marker.unlink(missing_ok=True)
    try:
        if fault in ['markread','cpfail','cpgone','rmfail','workspace']:
            if os.geteuid()==0:raise RuntimeError('root cannot exercise permissions')
            if fault=='markread':
                records=[]
                for record_path in (home/'pending').glob('*.json'):
                    try: r=json.loads(record_path.read_text())
                    except (OSError,ValueError): continue
                    if isinstance(r,dict) and r.get('project_dir')==str(project.resolve()):records.append(r)
                if len(records)!=1:raise RuntimeError('expected exactly one pending record')
                target=home/'snapshots'/(records[0]['snapshot_id']+'_meta.json');mode=0;op='read';probe=target
            elif fault=='workspace':
                # Explicitly show production discovery includes the unreadable member.
                target=project/'packages/m0/package.json';mode=0;op='read';probe=target
            elif fault=='cpfail':target=project/'package-lock.json';mode=0o444;op='write';probe=target
            elif fault=='cpgone':target=project;mode=0o555;op='create';probe=project/'package-lock.json'
            else:
                target=project/'node_modules/installed-package';mode=0o555;op='unlink';probe=target/'held'
                probe.write_bytes(b'held fixture bytes\n')
            restore.append((target,stat.S_IMODE(target.stat().st_mode)));target.chmod(mode)
            facts.append(denied(probe,op))
            if fault=='markread' and call:(call/'record-unread').touch()
            if fault=='workspace':
                query=subprocess.run([manifest['core'],'post-probe'],input=json.dumps(dict(op='workspaces',path=str(project))).encode(),capture_output=True)
                facts.append(dict(discovery_rc=query.returncode,discovery_stdout=query.stdout.decode(),discovery_stderr=query.stderr.decode()))
                if query.returncode or str(target.parent).encode() not in query.stdout.splitlines():
                    raise RuntimeError('production discovery did not include the unreadable workspace member')
        elif fault=='twoobj' and call:
            (call/'record-unread').touch()
        result=subprocess.run([binary,a.stage],input=raw,env=env,capture_output=True)
        if selected:
            if not marker.is_file():raise RuntimeError('selected operation was never reached: '+selected)
            reached=marker.read_text(); facts.append(dict(source_operation=selected,observed=reached))
            if selected=='pre-mark' and 'PermissionDenied' not in reached:
                raise RuntimeError('atomic rewrite did not fail with PermissionDenied')
            if selected.startswith('owner') and call:
                evidence=json.loads(reached)
                (call/'native-query-failure.json').write_text(json.dumps(evidence))
        if selected in ['pre-seconds','pre-coarse']:
            entry=home/'pending/backstop'/('id-'+payload['tool_use_id']+'.json')
            record=json.loads(entry.read_text());baseline=Path(record['baseline'])
            facts.append(dict(entry=record,baseline_mtime_ns=baseline.stat().st_mtime_ns,
                              node_ctime_ns=(project/'node_modules').stat().st_ctime_ns,
                              lock_ctime_ns=(project/'package-lock.json').stat().st_ctime_ns))
            if record['resolution']!='seconds' or baseline.stat().st_mtime_ns % 1_000_000_000:
                raise RuntimeError('native pre did not write the backdated whole-second baseline')
        if fault:
            with open(manifest['receipts'],'a') as f:
                f.write(json.dumps(dict(stage=a.stage,fault=fault,project=str(project),core=binary,
                                       source_copy=selected,facts=facts,rc=result.returncode))+'\n')
        sys.stdout.buffer.write(result.stdout);sys.stderr.buffer.write(result.stderr)
        return result.returncode if result.returncode>=0 else 128-result.returncode
    finally:
        for path,mode in reversed(restore):
            if path.exists():path.chmod(mode)

def main():
    p=argparse.ArgumentParser(description=__doc__);sub=p.add_subparsers(dest='cmd',required=True)
    q=sub.add_parser('prepare');q.add_argument('--tree',required=True);q.add_argument('--core',required=True)
    q.add_argument('--cargo',default='cargo');q.add_argument('--output',required=True)
    q=sub.add_parser('hook');q.add_argument('--manifest',required=True);q.add_argument('--stage',choices=['pre','post'],required=True)
    a=p.parse_args()
    return hook(a) if a.cmd=='hook' else prepare(a)
if __name__=='__main__':sys.exit(main())
