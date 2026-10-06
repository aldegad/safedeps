#!/usr/bin/env python3
"""Measure the whole post backstop on synthetic closures, remotely.

Timing runs have no counting wrappers. A separate run counts selected external
program invocations through PATH; this is not a count of forks or Bash
subshells. Rust's direct child list is npm, curl, file, gzip. This fixture
exercises the closure backstop, so it does not measure rebuild or file/gzip.
Warm-cache and cold-loopback results are CPU/local-provider measurements,
not a claim about the canonical providers' network latency.
"""
import argparse
from collections import Counter
import hashlib
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
p.add_argument('--report',required=True)
a=p.parse_args()
sizes=[int(x) for x in a.sizes.split(',')]
ledgers=[int(x) for x in a.ledger_sizes.split(',')]
if any(x<0 for x in sizes+ledgers):p.error('sizes must be nonnegative')
root=Path(__file__).resolve().parents[2]
core=str(Path(a.core).resolve(strict=True))
programs='npm curl file gzip jq date mkdir cat sed grep awk sort find stat sha256sum shasum md5 md5sum mktemp rm mv cp tr head tail cut paste wc ls sleep uname ps diff cmp readlink basename dirname realpath'.split()
real={name:shutil.which(name) for name in programs}
requests=[]

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
    payload=dict(tool_name='Bash',tool_input=dict(command='npm install fixture'),cwd=str(project),tool_use_id='cost-call')
    return home,json.dumps(payload).encode()

rows=[]
print('start:',subprocess.check_output(['uptime'],text=True).strip(),flush=True)
try:
    with tempfile.TemporaryDirectory(prefix='core-post-cost.') as tmp:
        box=Path(tmp).resolve();count_log=box/'invocations.jsonl';bin_dir=box/'count-bin';bin_dir.mkdir()
        for name,path in real.items():
            if not path:continue
            # Each wrapper replaces itself with the real executable; it does
            # not add a child. Interpreter overhead is excluded from timings.
            wrapper=bin_dir/name
            wrapper.write_text('#!'+sys.executable+'\nimport json,os,sys\n'
                +'with open('+repr(str(count_log))+',"a") as f:f.write(json.dumps('+repr(name)+')+"\\n")\n'
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
                        calls=Counter(json.loads(line) for line in count_log.read_text().splitlines())
                        expected_requests=[] if a.cache=='warm' or n==0 else [dict(path='/osv',queries=n),dict(path='/kev')]
                        provider_line='OSV batch cache hit' if a.cache=='warm' else 'OSV batch live query ok'
                        passed=(result.returncode==0 and expected and requests==expected_requests
                                and log.count(provider_line)==n and 'verification failed' not in out
                                and 'ledger closure check could not run' not in out)
                        sample=dict(rc=result.returncode,passed=passed,stdout=out,stderr=err,requests=list(requests))
                        if counted:sample['external_program_invocations']=dict(calls)
                        else:sample.update(seconds=elapsed,over_30s=elapsed>30)
                        samples['counted' if counted else 'timed']=sample
                        print(side,n,l,'counted' if counted else 'timed',result.returncode,
                              dict(calls) if counted else round(elapsed,3),'ok' if passed else 'FAIL',flush=True)
                    rows.append(dict(side=side,closure_size=n,ledger_size=l,cache=a.cache,**samples))
finally:
    server.shutdown();server.server_close();thread.join()
report=dict(host=dict(system=platform.system(),release=platform.release(),machine=platform.machine()),
            scope='whole post command-independent backstop; no rebuild, bin classifier or rotation',
            count_unit='selected external program invocations, not forks or subshells',
            programs=real,core=core,entry='post-probe' if a.probe else 'post',rows=rows)
Path(a.report).write_text(json.dumps(report,indent=2)+'\n')
print('end:',subprocess.check_output(['uptime'],text=True).strip(),flush=True)
raise SystemExit(0 if rows and all(s['passed'] for row in rows for key,s in row.items() if key in ['timed','counted']) else 1)
