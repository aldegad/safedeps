#!/usr/bin/env python3
"""Measure the whole post backstop on synthetic closures, remotely.

Timing runs have no counting wrappers. A separate run counts selected external
program invocations through PATH; this is not a count of forks or Bash
subshells. Rust's direct child list is npm, curl, file, gzip. The default
fixture exercises the closure backstop. --bin-count adds a recorded empty
install that classifies new text bin files; --rotate-bytes exercises archive
creation. --rebuild uses one approved synthetic package whose harmless
lifecycle script leaves a receipt inside its own fixture directory.
Warm-cache and cold-loopback results are CPU/local-provider measurements,
not a claim about the canonical providers' network latency.
"""
import argparse
from collections import Counter
import hashlib
import importlib.util
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile
import threading
import time

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--core',required=True)
p.add_argument('--probe',action='store_true')
p.add_argument('--sizes',default='1,4,16,64,128')
p.add_argument('--ledger-sizes',default='0')
p.add_argument('--cache',choices=['warm','cold-loopback'],default='warm')
p.add_argument('--count',action='store_true',help='Run a separate PATH-instrumented sample')
p.add_argument('--bin-count',type=int,default=0,help='Use a recorded empty install with this many new text bin files')
p.add_argument('--rotate-bytes',type=int,default=0,help='Seed an INFO log and set the rotation threshold to this size')
p.add_argument('--rebuild',action='store_true',help='Measure config/query/rebuild over one approved local fixture package')
p.add_argument('--report',required=True)
a=p.parse_args()
sizes=[int(x) for x in a.sizes.split(',')]
ledgers=[int(x) for x in a.ledger_sizes.split(',')]
if any(x<0 for x in sizes+ledgers):p.error('sizes must be nonnegative')
if a.bin_count<0 or a.rotate_bytes<0:p.error('bin count and rotation bytes must be nonnegative')
if a.bin_count and (sizes!=[0] or ledgers!=[0]):p.error('--bin-count requires --sizes 0 --ledger-sizes 0')
if a.rebuild and (sizes!=[1] or ledgers!=[1] or a.bin_count or a.cache!='warm' or not a.count):
    p.error('--rebuild requires --sizes 1 --ledger-sizes 1 --cache warm --count and no bin fixture')
root=Path(__file__).resolve().parents[2]
core=str(Path(a.core).resolve(strict=True))
programs='npm curl file gzip jq date mkdir cat sed grep awk sort find stat sha256sum shasum md5 md5sum mktemp rm mv cp tr head tail cut paste wc ls sleep uname ps diff cmp readlink basename dirname realpath'.split()
real={name:shutil.which(name) for name in programs}
requests=[]
pre_evidence=None

class Provider(BaseHTTPRequestHandler):
    def log_message(self,*args):pass
    def do_POST(self):
        body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        queries=body['queries'];requests.append(dict(path=self.path,queries=len(queries)))
        data=json.dumps(dict(results=[dict(vulns=[]) for _ in queries])).encode()
        self.send_response(200);self.end_headers();self.wfile.write(data)
    def do_GET(self):
        requests.append(dict(path=self.path))
        self.send_response(200);self.end_headers();self.wfile.write(b'{"vulnerabilities":[]}')

server=HTTPServer(('127.0.0.1',0),Provider)
thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
endpoint='http://127.0.0.1:%d'%server.server_port

def spec(i):return 'fixture-%05d'%i
def write_json(path,value):path.write_text(json.dumps(value)+'\n')
def seed(d,n,l):
    if d.exists():shutil.rmtree(d)
    project=d/'project';home=d/'state';cache=home/'cache'
    project.mkdir(parents=True)
    for sub in ['osv','kev']:(cache/sub).mkdir(parents=True)
    ledger=home/'approved-specs';ledger.mkdir()
    packages={'':dict(name='cost-fixture',dependencies={spec(i):'1.0.0' for i in range(n)})}
    packages.update({'node_modules/'+spec(i):dict(version='1.0.0') for i in range(n)})
    write_json(project/'package-lock.json',dict(lockfileVersion=3,packages=packages))
    write_json(project/'package.json',dict(name='cost-fixture'))
    for i in range(l):
        name=spec(i);key=hashlib.sha256(('npm\n%s\n1.0.0'%name).encode()).hexdigest()
        write_json(ledger/('sha256-'+key+'.json'),dict(hash='sha256:'+key,ecosystem='npm',package=name,
                   version='1.0.0',version_range='1.0.0',approved_at='2001-01-01T00:00:00Z',
                   expires_at='2099-01-01T00:00:00Z',approved_by='synthetic-fixture',evidence={}))
    if a.cache=='warm':
        for i in range(n):
            key=hashlib.sha256(('osv\nnpm\n%s\n1.0.0'%spec(i)).encode()).hexdigest()
            write_json(cache/'osv'/(key+'.json'),dict(vulns=[]))
        write_json(cache/'kev/known_exploited_vulnerabilities.json',dict(vulnerabilities=[]))
    if a.rotate_bytes:
        line=b'[2001-02-03T04:05:06Z] INFO synthetic rotation fixture\n'
        (home/'advisory.log').write_bytes(line*(a.rotate_bytes//len(line)+1))
    payload=dict(tool_name='Bash',tool_input=dict(command='npm install fixture'),cwd=str(project),tool_use_id='cost-call')
    if a.bin_count or a.rebuild:
        bins=project/'node_modules/.bin';bins.mkdir(parents=True)
        for i in range(a.bin_count):(bins/('probe-%04d'%i)).write_text('plain text\n')
        shutil.copyfile(project/'package-lock.json',project/'node_modules/.package-lock.json')
        snapshots=home/'snapshots';snapshots.mkdir();pending=home/'pending';pending.mkdir()
        if a.rebuild:payload['tool_input']['command']='npm install --ignore-scripts '+spec(0)
        record=dict(record=2,snapshot_id='pre',tool_use_id='cost-call',project_dir=str(project),
                    command=payload['tool_input']['command'],ignore_scripts_injected=a.rebuild)
        if a.rebuild:
            record.update(updated_command=payload['tool_input']['command'],npm_fetch=dict(registry='https://registry.npmjs.org/',replace='npmjs',scopes={}))
        write_json(snapshots/'pre_meta.json',record);write_json(pending/'id-cost-call.json',record)
        (snapshots/'pre_monitored_files.list').write_text(pre_evidence['list'])
        for name in pre_evidence['list'].splitlines():
            if not name or '/' in name:raise RuntimeError('unexpected member in root-only pre fixture')
            if (project/name).is_file():shutil.copyfile(project/name,snapshots/('pre_'+name))
            else:(snapshots/('pre_'+name+'.missing')).touch()
        for name in ['bins.list','packages.list']:(snapshots/('pre_'+name)).touch()
        shutil.copyfile(project/'package-lock.json',snapshots/'pre_npm-tree-record.json')
        if a.rebuild:
            package=project/'node_modules'/spec(0);package.mkdir()
            write_json(package/'package.json',dict(name=spec(0),version='1.0.0',scripts=dict(install='node ./fixture-install.cjs')))
            (package/'fixture-install.cjs').write_text("require('fs').writeFileSync('rebuild-receipt', 'fixture lifecycle ran\\n');\n")
            packages['node_modules/'+spec(0)].update(resolved='https://registry.npmjs.org/'+spec(0)+'/-/'+spec(0)+'-1.0.0.tgz',integrity='sha512-Zml4dHVyZQ==')
            write_json(project/'package-lock.json',dict(lockfileVersion=3,packages=packages))
            shutil.copyfile(project/'package-lock.json',project/'node_modules/.package-lock.json')
            write_json(project/'package.json',dict(name='cost-fixture',version='1.0.0',dependencies={spec(0):'1.0.0'}))
            (project/'.npmrc').write_text('registry=https://registry.npmjs.org/\nignore-scripts=false\n')
    return home,json.dumps(payload).encode()

rows=[]
print('start:',subprocess.check_output(['uptime'],text=True).strip(),flush=True)
try:
    with tempfile.TemporaryDirectory(prefix='core-post-cost.') as tmp:
        box=Path(tmp).resolve();count_log=box/'invocations.jsonl';bin_dir=box/'count-bin';bin_dir.mkdir()
        if a.bin_count or a.rebuild:
            fixture_spec=importlib.util.spec_from_file_location('pre_fixture',Path(__file__).with_name('core-post-pre-fixture.py'))
            fixture=importlib.util.module_from_spec(fixture_spec);fixture_spec.loader.exec_module(fixture)
            pre_evidence=fixture.pre_list(root,box/'normal-pre')
        for name,path in real.items():
            if not path:continue
            # Each wrapper replaces itself with the real executable; it does
            # not add a child. Interpreter overhead is excluded from timings.
            wrapper=bin_dir/name
            wrapper.write_text('#!'+sys.executable+'\nimport json,os,sys\n'
                +'with open('+repr(str(count_log))+',"a") as f:f.write(json.dumps(dict(program='+repr(name)+',verb=sys.argv[1] if '+repr(name)+'=="npm" and len(sys.argv)>1 else None))+"\\n")\n'
                +'os.execv('+repr(path)+','+repr([path])+'+sys.argv[1:])\n')
            wrapper.chmod(0o755)
        for n in sizes:
            for l in ledgers:
                for side in ['bash','rust']:
                    samples={}
                    for counted in ([False,True] if a.count else [False]):
                        home,payload=seed(box/'paired',n,l);requests.clear();count_log.write_text('')
                        # Do not carry truth-source, cache, or ledger settings
                        # from the operator's own installation into a fixture.
                        env={k:v for k,v in os.environ.items() if not k.startswith('SAFEDEPS_')}
                        env.update(SAFEDEPS_HOME=str(home),SAFEDEPS_OSV_BATCH_API_URL=endpoint+'/osv',
                                   SAFEDEPS_KEV_CATALOG_URL=endpoint+'/kev',LC_ALL='C')
                        if a.rebuild:
                            user=home.parent/'user-home';user.mkdir(exist_ok=True)
                            env.update(HOME=str(user),NPM_CONFIG_USERCONFIG='/dev/null',NPM_CONFIG_IGNORE_SCRIPTS='false')
                        if a.rotate_bytes:env['SAFEDEPS_ADVISORY_LOG_MAX_BYTES']=str(a.rotate_bytes)
                        if counted:env['PATH']=str(bin_dir)+os.pathsep+env['PATH']
                        if side=='bash':argv=['bash',str(root/'scripts/safedeps-post-verify.sh')]
                        else:
                            argv=[core,'post-probe' if a.probe else 'post']
                            if a.probe:payload=json.dumps(dict(op='hook',input=payload.decode())).encode()
                        start=time.monotonic()
                        result=subprocess.run(argv,input=payload,env=env,cwd=box,capture_output=True)
                        elapsed=time.monotonic()-start
                        out=result.stdout.decode(errors='replace');err=result.stderr.decode(errors='replace')
                        log=(home/'advisory.log').read_text() if (home/'advisory.log').exists() else ''
                        expected=(not out and 'BACKSTOP clean:' in log) if l>=n else (
                            'No rollback ran.' in out and 'unapproved package(s)' in out and 'BACKSTOP FLAGGED (no baseline)' in log)
                        if a.bin_count:
                            expected=(not out and not (home/'pending/id-cost-call.json').exists()
                                      and len(list(home.parent.glob('project/node_modules/.bin/*')))==a.bin_count
                                      and bool(list(home.glob('confirmed_*'))))
                        if a.rebuild:
                            receipt=home.parent/'project/node_modules'/spec(0)/'rebuild-receipt'
                            expected=(not out and receipt.is_file() and receipt.read_text()=='fixture lifecycle ran\n'
                                      and not (home/'pending/id-cost-call.json').exists() and bool(list(home.glob('confirmed_*'))))
                        invocations=[json.loads(line) for line in count_log.read_text().splitlines()]
                        calls=Counter(call['program'] for call in invocations)
                        npm_commands=Counter(call['verb'] for call in invocations if call['program']=='npm')
                        expected_requests=[] if a.cache=='warm' or n==0 else [dict(path='/osv',queries=n),dict(path='/kev')]
                        provider_line='OSV batch cache hit' if a.cache=='warm' else 'OSV batch live query ok'
                        passed=(result.returncode==0 and expected and requests==expected_requests
                                and log.count(provider_line)==n and 'verification failed' not in out
                                and 'ledger closure check could not run' not in out)
                        if a.rotate_bytes:passed=passed and bool(list(home.glob('advisory.log.*.gz')))
                        if counted and side=='rust':
                            passed=passed and calls.get('file',0)==min(a.bin_count,20) and calls.get('gzip',0)==bool(a.rotate_bytes)
                            if a.rebuild:passed=passed and npm_commands==dict(config=1,query=1,rebuild=1)
                        sample=dict(rc=result.returncode,passed=passed,stdout=out,stderr=err,requests=list(requests))
                        if counted:sample.update(external_program_invocations=dict(calls),npm_commands=dict(npm_commands))
                        else:sample.update(seconds=elapsed,over_30s=elapsed>30)
                        samples['counted' if counted else 'timed']=sample
                        print(side,n,l,'counted' if counted else 'timed',result.returncode,
                              dict(calls) if counted else round(elapsed,3),'ok' if passed else 'FAIL',flush=True)
                    rows.append(dict(side=side,closure_size=n,ledger_size=l,cache=a.cache,**samples))
finally:
    server.shutdown();server.server_close();thread.join()
report=dict(host=dict(system=platform.system(),release=platform.release(),machine=platform.machine()),
            scope='verified rebuild of one approved fixture package' if a.rebuild else 'recorded empty install with new text bins' if a.bin_count else 'whole post command-independent backstop; no rebuild',
            bin_count=a.bin_count,rotation_seed_bytes=a.rotate_bytes,
            pre_generated_fixture=pre_evidence,
            count_unit='selected external program invocations, not forks or subshells',
            programs=real,core=core,entry='post-probe' if a.probe else 'post',rows=rows)
Path(a.report).write_text(json.dumps(report,indent=2)+'\n')
print('end:',subprocess.check_output(['uptime'],text=True).strip(),flush=True)
raise SystemExit(0 if rows and all(s['passed'] for row in rows for key,s in row.items() if key in ['timed','counted']) else 1)
