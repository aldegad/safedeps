#!/usr/bin/env python3
"""Inject each registered native reader failure on archive source copies.

Each copy forces one existing producer branch, marks that actual failure
assignment on stderr, and calls that producer once at the public pre driver.
The caller then runs unchanged public pre judgment. This is a propagation
census, not evidence that every branch is naturally reachable on every input.
No production hook reads a test switch. Builds are serial, release/offline.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import tempfile

ROOT=Path(__file__).resolve().parents[2]
FUNCTIONS=('lex_unterm','payload_build','payloads','pieces','lex_payloads')
ASSIGN=re.compile(r'\bself\.failed\s*(?:\|=|=)\s*[^;]+;')


def functions(text):
    starts=list(re.finditer(r'^    (?:pub )?fn (\w+)\([^\n]+\{',text,re.M))
    found={}
    for i,m in enumerate(starts):
        if m.group(1) not in FUNCTIONS:continue
        end=starts[i+1].start() if i+1<len(starts) else len(text)
        end=text.rfind('\n    }',m.end(),end)+6
        if end<m.end():raise RuntimeError('method boundary missing')
        found[m.group(1)]=(m.start(),end,text[m.start():end])
    if set(found)!=set(FUNCTIONS):raise RuntimeError('reader method inventory changed')
    return found


def inventory(text):
    rows=[]
    for fn,(_,_,body) in functions(text).items():
        for i,m in enumerate(ASSIGN.finditer(body),1):
            rows.append(dict(id=fn+'/'+str(i),statement=m.group(),
                             context=body[max(0,m.start()-70):m.end()+70],
                             method_sha256=hashlib.sha256(body.encode()).hexdigest()))
    return rows


def fault(text,name):
    fn,num=name.split('/');num=int(num)
    begin,end,body=functions(text)[fn]
    sites=list(ASSIGN.finditer(body));selected=sites[num-1]
    # Witness is attached to the actual existing assignment before forcing
    # the branch, so a fixture that misses it is red rather than an empty pass.
    marker='native-scan-site:'+name
    body=body[:selected.end()]+' eprintln!("'+marker+'");'+body[selected.end():]
    call={'lex_unterm':'self.lex_unterm(b"echo x","scan")',
          'pieces':'self.pieces(b"echo x")',
          'payloads':'self.payloads(b"echo x")',
          'payload_build':'self.payload_build(b"x",&[b"'+('9:1' if num==1 else 'bad')+'".to_vec()])',
          'lex_payloads':'self.lex_payloads(b"echo x","cscripts")'}[fn]
    def replace(old,new):
        nonlocal body
        if body.count(old)!=1:raise RuntimeError(name+': operation anchor is not unique')
        body=body.replace(old,new)
    side='crate::lex::Side { smfail: true, ..Default::default() }'
    if fn=='lex_unterm':
        if num==1:replace('= self.reading else','= None::<Reading> else')
        else:
            expr=('Ok((Vec::new(),'+side+'))' if num==2 else
                  'Err((crate::lex::UnknownView,'+(side if num==3 else 'crate::lex::Side::default()')+'))')
            replace('let r = Lex::new(&self.c.g, text, view, rd).run();',
                    'let r: Result<(Vec<u8>,crate::lex::Side),(crate::lex::UnknownView,crate::lex::Side)> = '+expr+';')
    elif fn=='pieces':
        if num==1:replace('= self.reading else','= None::<Reading> else')
        else:replace('Lex::new(&self.c.g, text, "pieces", rd).run_pieces()',
                     'Ok::<_,(crate::lex::UnknownView,crate::lex::Side)>((crate::lex::Pieces::default(),'+side+'))' if num==2 else
                     'Err::<(crate::lex::Pieces,crate::lex::Side),_>((crate::lex::UnknownView,crate::lex::Side::default()))')
    elif fn=='payloads':
        if num==1:replace('= self.reading else','= None::<Reading> else')
        else:replace('Lex::new(&self.c.g, text, view, rd).run_payloads()',
                     'Ok::<_,(crate::lex::UnknownView,crate::lex::Side)>((Vec::<Payload>::new(),'+side+'))' if num==2 else
                     'Err::<(Vec<Payload>,crate::lex::Side),_>((crate::lex::UnknownView,crate::lex::Side::default()))')
    elif fn=='lex_payloads':replace('let out = subst(out);','let out = b"'+('!\\n' if num==1 else 'X\\n')+'".to_vec();')
    text=text[:begin]+body+text[end:]
    insertion='''
    pub fn measure_inject(&mut self) {
        self.reading=Some(Reading::Bash);
        let _ = '''+call+''';
        self.reading=None;
    }
'''
    anchor="impl<'c> Run<'c> {"
    if text.count(anchor)!=1:raise RuntimeError('Run implementation anchor changed')
    return text.replace(anchor,anchor+insertion),marker


def fixture(binary,out,marker,expect_failure):
    rows=[]
    for label,command,deny in [('manager-name','echo npm',True),('install','npm install',True),('ordinary','echo fixture',False)]:
        box=out/label;project=box/'project';project.mkdir(parents=True)
        (project/'package.json').write_text('{"name":"fixture"}\n')
        env={k:v for k,v in os.environ.items() if not k.startswith('SAFEDEPS_') and not k.lower().startswith('npm_config_')}
        env.update(SAFEDEPS_HOME=str(box/'state'),HOME=str(box/'home'),NPM_CONFIG_USERCONFIG='/dev/null',LC_ALL='C')
        payload=dict(tool_name='Bash',tool_use_id='scan-'+label,cwd=str(project),tool_input=dict(command=command))
        r=subprocess.run([str(binary),'pre'],input=json.dumps(payload).encode(),env=env,cwd=project,capture_output=True,timeout=30)
        raw=r.stdout.decode();err=r.stderr.decode();messages=[]
        for line in raw.splitlines():
            if line.strip():messages.append(json.loads(line))
        hook=next((m['hookSpecificOutput'] for m in messages if 'hookSpecificOutput' in m),{})
        logs=box/'state/advisory.log';log=logs.read_text() if logs.exists() else ''
        pending=list((box/'state/pending').rglob('*.json'));meta=list((box/'state/snapshots').glob('*_meta.json'))
        checks={'hook_rc':r.returncode==0,'no_rewrite':'updatedInput' not in hook}
        if expect_failure:
            checks.update(witness=marker in err,no_pending=not pending,no_meta=not meta)
            if deny:checks.update(deny=hook.get('permissionDecision')=='deny',undecided='UNDECIDED' in hook.get('permissionDecisionReason',''))
            else:checks.update(allow=hook.get('permissionDecision')!='deny',stderr_failure='could not be fully read' in err,
                               advisory_failure='command scanner failed' in log)
        else:
            checks['no_fault_witness']='native-scan-site:' not in err
            # The baseline only exercises a benign manager mention/ordinary
            # command. An actual install may legitimately produce its record.
            checks['baseline_allow']=hook.get('permissionDecision')!='deny'
        row=dict(name=label,input=payload,rc=r.returncode,stdout=raw,stderr=err,advisory=log,
                 pending=[str(p) for p in pending],meta=[str(p) for p in meta],checks=checks,passed=all(checks.values()))
        rows.append(row)
    (out/'result.json').write_text(json.dumps(rows,indent=2)+'\n')
    return all(r['passed'] for r in rows)


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for key in ('archive','core','cargo','run-dir'):ap.add_argument('--'+key,required=True)
    ap.add_argument('--only',help='comma-separated site ids; default every registered site')
    ap.add_argument('--control',action='store_true',help='also prove a reader failure erased before settling is rejected')
    a=ap.parse_args();archive=Path(a.archive).resolve(strict=True);core=Path(a.core).resolve(strict=True);cargo=Path(a.cargo).resolve(strict=True)
    run=Path(a.run_dir).resolve();run.mkdir(parents=True,exist_ok=False)
    source=(ROOT/'rust/src/core.rs').read_text()
    registered=json.loads(Path(__file__).with_name('native-scan-sites.json').read_bytes())
    if inventory(source)!=registered['sites']:raise RuntimeError('unmarked or changed reader failure site; update the source inventory and its fault')
    ids=[r['id'] for r in registered['sites']];names=a.only.split(',') if a.only else ids
    if not names or any(n not in ids for n in names):ap.error('unknown site id')
    baseline=run/'baseline';baseline.mkdir()
    if not fixture(core,baseline,'',False):raise RuntimeError('baseline failed')
    rows=[]
    for name in names:
        for control in ([False,True] if a.control and name==names[0] else [False]):
            label=name.replace('/','-')+('-control' if control else '')
            tree=run/(label+'-source');tree.mkdir()
            subprocess.run(['tar','xf',str(archive),'-C',str(tree)],check=True)
            path=tree/'rust/src/core.rs';text=path.read_text()
            if inventory(text)!=registered['sites']:raise RuntimeError('archive reader inventory differs')
            changed,marker=fault(text,name);path.write_text(changed)
            pre=tree/'rust/src/pre.rs';text=pre.read_text();anchor='    let read = readings::Readings::collect(&mut run, &call.command, &cwd);'
            if text.count(anchor)!=1:raise RuntimeError('pre driver anchor changed')
            text=text.replace(anchor,'    run.measure_inject();\n'+anchor+('\n    run.failed=false;' if control else ''))
            pre.write_text(text)
            with (run/(label+'-build.log')).open('wb') as log:
                r=subprocess.run([str(cargo),'build','--manifest-path',str(tree/'rust/Cargo.toml'),'--release','--locked','--offline','-j1'],stdout=log,stderr=log,env=dict(os.environ,CARGO_TARGET_DIR=str(tree/'rust/target')))
            (run/(label+'-build.rc')).write_text(str(r.returncode)+'\n')
            if r.returncode:raise RuntimeError('fault build failed; no detection claimed')
            out=run/label;out.mkdir()
            passed=fixture(tree/'rust/target/release/safedeps-core',out,marker,True)
            accepted=not passed if control else passed
            # A countercontrol is only valid if the injected failure ran and
            # every hook returned normally; crashes are never negative proof.
            observed=json.loads((out/'result.json').read_bytes())
            if control:accepted=accepted and all(r['checks']['witness'] and r['checks']['hook_rc'] for r in observed)
            rows.append(dict(site=name,control=control,fixture_passed=passed,passed=accepted))
            (run/'result.json').write_text(json.dumps(dict(rows=rows),indent=2)+'\n')
            print(('ok - ' if accepted else 'not ok - ')+label,flush=True)
            if not accepted:
                print(json.dumps(observed,indent=2),flush=True)
                return 1
    return 0

if __name__=='__main__':raise SystemExit(main())
