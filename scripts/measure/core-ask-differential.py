#!/usr/bin/env python3
"""Check native npm questions against an owned recorder and fixed facts.
No Bash reference, real install, or network call is used.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--core',required=True)
a=p.parse_args()
root=Path(__file__).resolve().parents[2]
core=str(Path(a.core).resolve())
print('start:',subprocess.check_output(['uptime'],text=True).strip(),flush=True)
with tempfile.TemporaryDirectory(prefix='core-ask.') as tmp:
    box=Path(tmp).resolve(); project=box/'project'; project.mkdir()
    bindir=box/'bin'; bindir.mkdir(); calls=box/'calls'; calls.mkdir(); scratch=box/'tmp'; scratch.mkdir()
    stub=bindir/'npm'
    stub.write_text('''#!/usr/bin/python3
import os,sys,json,hashlib
from pathlib import Path
args=sys.argv[1:]
record=dict(argv=args,cwd=os.getcwd(),env={k:os.environ.get(k) for k in ['PATH','NODE_OPTIONS','NODE_PATH','npm_config_node_options','HOME','PWD','OLDPWD','ASK_SETTING']})
# -i deliberately drops the recorder variable; keep the directory literal.
where=Path('''+repr(str(calls))+''')
where.joinpath(str(os.getpid())+'.json').write_text(json.dumps(record,sort_keys=True))
if args[0]=='prefix': print(os.getcwd())
elif args[0]=='root': print(os.getcwd()+'/node_modules')
elif args[0]=='query': print('[]')
else: print(json.dumps({'registry':os.environ.get('npm_config_registry','https://registry.npmjs.org/'),'replace-registry-host':'npmjs','@scope:registry':'https://mirror.example/'}))
''')
    stub.chmod(0o700)
    env=dict(os.environ,PATH=str(bindir)+':'+os.environ['PATH'],HOME=str(box/'home'),TMPDIR=str(scratch),LANG='C',LC_ALL='C')
    for k in list(env):
        if k.lower().startswith('npm_config_') or k.startswith(('NODE_','LD_','DYLD_')) or k in ['BASH_ENV','OPENSSL_CONF','OPENSSL_MODULES']: del env[k]
    # Shell cd starts in a physical cwd. Both readers get that same cwd.
    env['PWD']=str(root)
    cases=[]
    def add(label,op,**kw): cases.append((label,dict(op=op,dir=str(project),**kw)))
    for name,words in [('plain',[]),('setting',['ASK_SETTING=x']),('unset',['-u','HOME']),('empty',['-i']),('code',['NODE_OPTIONS=--require=/must-not-load','NODE_PATH=/must-not-load','npm_config_node_options=--require=/must-not-load'])]:
        add('target-'+name,'target',env=words,args=[])
    for args in [['--cache'],['--'],['-C'],['--workspace','member'],['--workspaces','false'],['--workspaces=true'],['--registry','https://mirror.example/']]: add('target-'+repr(args),'target',args=args)
    add('fetch','fetch',args=['--workspaces=false'])
    add('query','query')
    for url in ['https://Registry.NPMJS.org/x','https://u:p@h.example:8080/x','https://[::1]:80/x','https://[::1/x','file:x','git+ssh://git@github.com/a/b','https:///x','HTTP://É.example/x','https://a@b@c/x','x','']:
        add('host-'+url,'host',url=url)
    public={'registry':'https://registry.npmjs.org/','replace':'npmjs','scopes':{},'test_registry':None}
    facts=[None,[],[None],[{'unknown':'missing'}],[public],[dict(public,registry='https://mirror.example/')],[dict(public,replace='never',registry='https://mirror.example/')],[dict(public,scopes={'@scope':'https://mirror.example/'})],[dict(public,replace='always')],[public,public,{'unknown':'missing'}]]
    for i,f in enumerate(facts):
        for op in ['origins','problems','known-problems']: add(f'{op}-{i}',op,facts=f,url='https://registry.npmjs.org/@scope/pkg/-/pkg.tgz')
    def recordings():
        records=[]
        for path in calls.glob('*.json'):
            text=path.read_text()
            text=re.sub(re.escape(str(scratch))+r'/[^/" ]+/cache','@CACHE@',text)
            records.append(json.loads(text))
            path.unlink()
        return sorted(records,key=lambda r:r['argv'])
    bad=0
    for label,req in cases:
        data=json.dumps(req).encode()
        op=req['op']
        rust=subprocess.run([core,'ask-probe'],input=data,env=env,cwd=root,capture_output=True,timeout=15)
        observed=recordings()
        same=rust.returncode==0 and not rust.stderr
        answer=rust.stdout.decode().splitlines()
        if op in ('target','fetch','query'):
            blocked=op=='target' and req.get('args') in (['--cache'],['--'],['-C'])
            if blocked:
                same=same and not observed and answer[0].startswith('?\t') and 'unknown' in json.loads(answer[1])
            else:
                same=same and len(observed)==(3 if op=='target' else 1)
                for call in observed:
                    same=same and call['cwd']==str(project) and call['env']['PATH']==env['PATH']
                    same=same and all(call['env'][k] is None for k in ('NODE_OPTIONS','NODE_PATH','npm_config_node_options'))
                    same=same and call['env']['ASK_SETTING']==('x' if label=='target-setting' else None)
                    same=same and call['env']['HOME']==(None if label in ('target-unset','target-empty') else env['HOME'])
                    same=same and call['argv'][-4:]==['--logs-max=0','--update-notifier=false','--cache','@CACHE@']
                if op=='query':same=same and json.loads(rust.stdout)==[]
                else:
                    if op=='target':same=same and answer[0]==str(project)
                    want=dict(registry='https://registry.npmjs.org/',replace='npmjs',scopes={'@scope':'https://mirror.example/'},test_registry=None)
                    same=same and json.loads(answer[-1])==want
        elif op=='host':
            wanted=['registry.npmjs.org','h.example','[::1]','[','','github.com','','É.example','b@c','','']
            urls=[r['url'] for _,r in cases if r['op']=='host']
            same=same and not observed and json.loads(rust.stdout)==wanted[urls.index(req['url'])]
        else:
            index=int(label.rsplit('-',1)[1])
            unknown='safedeps has no answer from npm about the registry'
            origins={0:[{'unknown':unknown}],1:[{'unknown':unknown}],2:[{'unknown':unknown}],
                     3:[{'unknown':'missing'}],5:[{'registry':'https://mirror.example/','replace':'npmjs'}],
                     7:[{'registry':'https://mirror.example/','replace':'npmjs','scope':'@scope'}],9:[{'unknown':'missing'}]}
            problems={0:[unknown],1:[unknown],2:[unknown],3:['missing'],
                      5:['npm fetches it from the registry https://mirror.example/ (replace-registry-host=npmjs)'],
                      7:['npm has @scope:registry=https://mirror.example/ (replace-registry-host=npmjs)'],9:['missing']}
            wanted=origins.get(index,[]) if op=='origins' else problems.get(index,[])
            if op=='known-problems' and index not in (5,7):wanted=[]
            same=same and not observed and json.loads(rust.stdout)==wanted
        print(('ok - ' if same else 'not ok - ')+label,flush=True)
        if not same:
            bad+=1
            print('  core',rust.returncode,repr(rust.stdout),observed,repr(rust.stderr))
    print('end:',subprocess.check_output(['uptime'],text=True).strip())
    print(f'core-ask: {len(cases)} cases, {bad} failures')
    raise SystemExit(1 if bad else 0)
