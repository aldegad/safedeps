#!/usr/bin/env python3
"""Compare pre's target records and the hook npm's actual argv/cwd/environment.

Commands are JSONL data, never evaluated. The reference is the original Bash
resolver on a copy. Both readers ask the same private stub; only the fresh
private cache argv is normalized, after checking its location. Every other
argument and environment entry (except shell bookkeeping _ and SHLVL) stays.
This is a component comparison, not a full hook verdict or real npm model.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def reference(box):
    source = (ROOT / 'scripts/safedeps-pre-guard.sh').read_text()
    head = source[:source.index('# Read tool input from stdin')]
    start = source.index('guard_word_as_read() {\n')
    end = source.index('\n}\n', start) + 3
    script = box / 'oracle/scripts/targets.sh'
    script.parent.mkdir(parents=True)
    (box / 'oracle/lib').symlink_to(ROOT / 'lib', target_is_directory=True)
    script.write_text(head + source[start:end] + r'''
INPUT=$(cat)
COMMAND=$(jq -r .command <<< "$INPUT")
CWD=$(jq -r .cwd <<< "$INPUT")
SAFEDEPS_READING=$(jq -r .reading <<< "$INPUT")
SAFEDEPS_LEX_CACHE="$SAFEDEPS_HOME/cache"
mkdir -p "$SAFEDEPS_LEX_CACHE"
SAFEDEPS_SCAN_MARK="$SAFEDEPS_HOME/scan-mark"
: > "$SAFEDEPS_SCAN_MARK"
resolve_reading_targets "$COMMAND" "$CWD"
[[ ! -s "$SAFEDEPS_SCAN_MARK" ]]
''')
    return script


def stub(box):
    path = box / 'bin/npm'
    path.parent.mkdir()
    path.write_text('#!' + sys.executable + ' -B\n' + '''import hashlib,json,os,sys
from pathlib import Path
box=Path(''' + repr(str(box)) + ''')
a=sys.argv[1:]
cache=a[-1]
assert a[-2]=='--cache' and Path(cache).parent.parent==box/'tmp', (a,cache)
a[-1]='@PRIVATE_CACHE@'
env={k:v for k,v in os.environ.items() if k not in ('_','SHLVL')}
row={'argv':a,'cwd':os.getcwd(),'env':env}
raw=json.dumps(row,sort_keys=True).encode()
key=hashlib.sha256(raw).hexdigest()
(box/'calls'/(key+'.'+str(os.getpid()))).write_bytes(raw)
config=json.loads((box/'answer.json').read_text())
prefix=config.get('prefix',os.getcwd())
if a[0]=='prefix': print(prefix)
elif a[0]=='root': print(config.get('root',prefix+'/node_modules'))
elif a[:2]==['config','ls']:
    registry=env.get('npm_config_registry',config.get('registry','https://registry.npmjs.org/'))
    print(json.dumps({'registry':registry,'replace-registry-host':'npmjs',**config.get('config',{})}))
else: raise SystemExit(91)
''')
    path.chmod(0o755)
    evil = box / 'evil'
    evil.mkdir()
    for name in ('npm', 'code'):
        p = evil / name
        p.write_text('#!/bin/sh\nprintf executed > ' + str(box / 'EXECUTED') + '\n')
        p.chmod(0o755)


def cases(box):
    project = box / 'project'
    home = box / 'home'
    commands = [
        ('record-separator','echo \"\x1d\"; pip install evil==6.6.6'),
        ('plain','npm install x'), ('ci','npm ci'), ('other','pip install x==1'),
        ('link','npm link x'), ('echo','echo npm ci'), ('empty',''),
        ('space','npm --prefix "space here" ci'), ('empty-dir','npm --prefix "" ci'),
        ('cd','cd sub; npm ci'), ('cd-chain','cd sub && npm ci'),
        ('conditional','false && cd sub; npm ci'), ('conditional-chain','true && cd sub && npm ci'),
        ('or-chain','true || cd sub && npm ci'), ('cd-exit','cd sub || exit; npm ci'),
        ('group','(cd sub; npm ci)'), ('if','if true; then cd sub; npm ci; fi'),
        ('pushd','pushd sub; npm ci'), ('popd','popd; npm ci'), ('missing','cd missing; npm ci'),
        ('pipe-cd','echo hi | cd sub; npm ci'), ('bg-cd','cd sub & npm ci'),
        ('dir-pnpm','pnpm -C sub install x'), ('dir-pip','pip -C sub install x'),
        ('env-dir','env -C sub npm ci'), ('env-dir-eq','env --chdir=sub npm ci'),
        ('home','HOME='+str(home)+'/other npm ci'), ('export-home','export HOME='+str(home)+'/other; npm ci'),
        ('assign-export','HOME='+str(home)+'/other; export HOME; npm ci'),
        ('declare','declare -xr HOME='+str(home)+'/other; npm ci'),
        ('nonexport','HOME='+str(home)+'/other; npm ci'), ('unset','export FOO=bar; unset FOO; npm ci'),
        ('unset-f','export FOO=bar; unset -f FOO; npm ci'), ('env-unset','FOO=bar env -u FOO npm ci'),
        ('env-after','FOO=bar env --unset=FOO FOO=after npm ci'), ('two','npm ci; npm ci'),
        ('different','HOME='+str(home)+'/other npm ci; npm ci'),
        ('dynamic','npm install "$PKG"'), ('dynamic-export','export HOME="$OTHER"; npm ci'),
        ('tilde','HOME=~/other npm ci'), ('array','export A[0]=x; npm ci'),
        ('lower','declare -l HOME=OTHER; npm ci'), ('unexport','export -n HOME; npm ci'),
        ('allexport','set -a; npm ci'), ('append','HOME+=other; npm ci'),
        ('source','source '+str(box/'evil/code')+'; npm ci'),
        ('eval','eval "export FOO=bar"; npm ci'),
        ('eval-setting','eval "export npm_config_registry=x"; npm ci'),
        ('source-nonpublic','source '+str(box/'evil/code')+'; npm_config_registry=https://registry.example/ npm ci'),
        ('export-registry','export npm_config_registry=https://registry.example/; npm ci'),
        ('assign-registry','npm_config_registry=https://registry.npmjs.org/; npm ci'),
        ('code-path','PATH='+str(box/'evil')+' npm ci'),
        ('code-export','export PATH='+str(box/'evil')+':$PATH; npm ci'),
        ('code-load','NODE_OPTIONS=--require='+str(box/'evil/code')+' npm ci'),
        ('code-unset','unset NODE_OPTIONS; npm ci'), ('env-code','env -u PATH npm ci'),
        ('env-i','env -i npm ci'), ('path-word',str(box/'evil/npm')+' ci'),
        ('hook-word',str(box/'bin/npm')+' ci'), ('prefix-exec','exec npm ci'),
        ('prefix-command','command npm ci'), ('env-unknown','env --bad npm ci'),
        ('trailing','npm install x --cache'), ('dashdash','npm install x --'),
        ('heredoc','cat <<EOF\n$(date)\nEOF\nnpm ci'),
        ('quoted-cd','cd "space here" && npm ci'),
    ]
    rows=[{'id':i,'command':c} for i,c in commands]
    rows += [
        {'id':'rc-unreadable','command':'npm ci','rc':'global=0\n','rc_mode':0},
        {'id':'rc-global','command':'npm ci','rc':'global=0\n'},
        {'id':'rc-off','command':'npm ci --global=false','rc':'global=0\n'},
        {'id':'rc-location','command':'npm ci --location=project','rc':'location=global\n'},
        {'id':'rc-quotes','command':'npm ci','rc':'global="false" ;comment\nlocation=project #comment\n'},
        {'id':'rc-section','command':'npm ci','rc':'GLOBAL=true\n[foo]\nlocation=global\n'},
        {'id':'rc-last','command':'npm ci','rc':'global=false\nglobal\n'},
        {'id':'user-rc','command':'npm ci','user_rc':'global=0\n'},
        {'id':'unknown-rc','command':'npm_config_userconfig=x npm ci'},
        {'id':'global-answer','command':'npm ci','answer':{'root':str(box/'global/node_modules')}},
        {'id':'newline-answer','command':'npm ci','answer':{'prefix':str(project)+'\nsub'}},
    ]
    return rows


def run_one(argv,payload,env,box):
    shutil.rmtree(box/'calls',ignore_errors=True);(box/'calls').mkdir()
    shutil.rmtree(box/'state',ignore_errors=True);(box/'state').mkdir()
    p=subprocess.run(argv,input=(json.dumps(payload)+'\n').encode(),cwd=box/'project',env=env,capture_output=True,timeout=20)
    calls=sorted((json.loads(f.read_text()) for f in (box/'calls').iterdir()),key=lambda v:json.dumps(v,sort_keys=True))
    return {'rc':p.returncode,'stdout':p.stdout.decode('utf8','surrogateescape'),'stderr':p.stderr.decode('utf8','surrogateescape'),'calls':calls,'executed':(box/'EXECUTED').exists()}


def main():
    ap=argparse.ArgumentParser();ap.add_argument('--core',required=True);ap.add_argument('--only');ap.add_argument('--report',required=True);ap.add_argument('--expect-difference',action='store_true')
    args=ap.parse_args();core=str(Path(args.core).resolve());out=[]
    with tempfile.TemporaryDirectory(prefix='core-pre-targets.') as temporary:
        box=Path(temporary)
        for p in ('project/sub','project/space here','home/other','tmp','calls'):(box/p).mkdir(parents=True)
        stub(box);ref=reference(box)
        env={**os.environ,'HOME':str(box/'home'),'SAFEDEPS_HOME':str(box/'state'),'TMPDIR':str(box/'tmp'),'PATH':str(box/'bin')+':'+os.environ['PATH'],'PWD':str(box/'project'),'LANG':'C','LC_ALL':'C'}
        for key in list(env):
            if key.lower().startswith('npm_config_') or key.startswith('SAFEDEPS_') and key!='SAFEDEPS_HOME':env.pop(key)
        rows=cases(box)
        (Path(args.report).with_suffix('.inputs.jsonl')).write_text(''.join(json.dumps(row)+'\n' for row in rows))
        for row in rows:
            if args.only and row['id'] not in args.only.split(','):continue
            (box/'answer.json').write_text(json.dumps(row.get('answer',{})))
            (box/'project/.npmrc').unlink(missing_ok=True)
            (box/'project/.npmrc').write_text(row.get('rc',''));(box/'home/.npmrc').write_text(row.get('user_rc',''))
            (box/'project/.npmrc').chmod(row.get('rc_mode',0o600))
            for reading in ('bash','zsh','dash'):
                payload={'op':'targets','command':row['command'],'cwd':str(box/'project'),'reading':reading}
                expected=run_one(['/bin/bash',str(ref)],payload,env,box)
                actual=run_one([core,'pre-probe'],payload,env,box)
                channels=[k for k in expected if expected[k]!=actual[k]]
                if expected['executed'] or actual['executed']:channels.append('code-executed')
                out.append({'id':row['id'],'reading':reading,'channels':channels,'expected':expected,'actual':actual})
                print(('DIFF' if channels else 'ok')+' '+row['id']+'/'+reading+' '+','.join(channels),flush=True)
    Path(args.report).write_text(json.dumps(out,indent=2))
    bad=sum(bool(v['channels']) for v in out)
    print(f'core-pre-targets: {len(out)} rows, {bad} differ',flush=True)
    return int(not bad if args.expect_difference else bool(bad))

if __name__=='__main__':raise SystemExit(main())
