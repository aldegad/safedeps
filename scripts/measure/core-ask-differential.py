#!/usr/bin/env python3
"""Compare shared npm ask/fetch functions with bash. Uses an owned npm stand-in,
never a real install or network call. --control removes the reference's code
name filter; the unsafe PATH is an owned recorder, so the control is harmless.
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
p.add_argument('--control',action='store_true')
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
    wrapper=box/'reference.sh'
    wrapper.write_text('''#!/bin/bash
set -u
source "$1/lib/install-grammar.sh"
source "$1/lib/npm/ask.sh"
shift
'''+('safedeps_npm_code_name() { return 1; }\n' if a.control else '')+'''
op="$1"; shift
case "$op" in
 target) safedeps_npm_install_target "$1" $((SECONDS+8)) "${@:2}" ;;
 fetch) safedeps_npm_fetch_facts "$1" $((SECONDS+8)) "${@:2}" ;;
 query)
  tmp=$(mktemp -d "$TMPDIR/query.XXXXXX")
  safedeps_npm_ask_start "$tmp/query" "$1" -- query '*' --global=false --location=project --prefix "$1"
  safedeps_npm_ask_wait $((SECONDS+10))
  cat "$tmp/query"
  rm -rf "$tmp" ;;
 *)
  case "$op" in
   host) filter='.url | sd_host';;
   public) filter='. as $q | .registry | sd_registry_public($q.facts)';;
   origins) filter='sd_fetch_origins(.facts; .url)';;
   problems) filter='sd_fetch_problems(.facts; .url)';;
   known-problems) filter='sd_fetch_known_problems(.facts; .url)';;
  esac
  jq -c --arg public "$SAFEDEPS_NPM_PUBLIC_REGISTRY_RE" "$SAFEDEPS_NPM_FETCH_JQ $filter" ;;
esac
''')
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
        op=req['op']; argv=[op]
        if op in ['target','fetch','query']: argv += [str(project),*req.get('env',[]),'--',*req.get('args',[])]
        ref=subprocess.run(['bash',str(wrapper),str(root),*argv],input=data,env=env,cwd=root,capture_output=True,timeout=15)
        refcalls=recordings()
        rust=subprocess.run([core,'ask-probe'],input=data,env=env,cwd=root,capture_output=True,timeout=15)
        rustcalls=recordings()
        same=(ref.returncode,ref.stdout,refcalls)==(rust.returncode,rust.stdout,rustcalls)
        print(('ok ' if same else 'DIFF ')+label,flush=True)
        if not same:
            bad+=1
            print('  bash',ref.returncode,repr(ref.stdout),refcalls,repr(ref.stderr))
            print('  core',rust.returncode,repr(rust.stdout),rustcalls,repr(rust.stderr))
    print('end:',subprocess.check_output(['uptime'],text=True).strip())
    print(f'core-ask-differential: {len(cases)} cases, {bad} differ, control={a.control}')
    raise SystemExit(0 if (bad>0 if a.control else bad==0) else 1)
