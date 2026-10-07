#!/usr/bin/env python3
"""Check native project context using fixed fixtures and Python file hashes.
The historical Bash comparison is retired. No package manager is executed.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[2]



def put(path,value):
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_bytes(value if isinstance(value,bytes) else json.dumps(value).encode())


def seed(box,name):
    root=box/'project'
    root_names={'backslash-root':r'back\slash','bracket-root':'[abc]',
        'star-root':'star*','question-root':'question?',
        'quoted-star-root':r'quoted\*','paired-slash-root':r'paired\\',
        'unicode-root':'한글*'}
    if name in root_names:root=root/root_names[name]
    root.mkdir(parents=True);(root/'.git').write_text('synthetic worktree marker\n')
    manifest={'name':'fixture','version':'1.0.0'}
    env={};op='yarn';where=root
    if name=='backslash-temp':
        temp=box/'tmp\\slash';temp.mkdir();env['TMPDIR']=str(temp)
    if name.startswith('override'):
        op='overrides';manifest['overrides']={'z':'2','a':{'z':'3','a':'1'}}
        if name=='override-filter':manifest['overrides']={'ref':'$foo','nested':{'bar':'$bar'},'valid':'2','ignored':False}
        if name=='override-env':env['SAFEDEPS_NPM_OVERRIDES_JSON']='{"z":"3", "a":"1"}'
        if name=='override-subdir':where=root/'child';where.mkdir()
        if name=='override-boundary':
            put(box/'package.json',{'overrides':{'outside':'1'}});manifest.pop('overrides')
        if name=='override-empty':manifest['overrides']={}
    elif name=='none':pass
    else:
        manifest['resolutions']={'z':'2','a':'1'}
        put(root/'yarn.lock',b'__metadata:\n  version: 8\n' if name!='classic' else b'# yarn lockfile v1\n')
        if name=='no-lock':(root/'yarn.lock').unlink()
        if name=='subdir':where=root/'child';where.mkdir()
        if name=='boundary':
            put(box/'package.json',manifest);put(box/'yarn.lock',b'__metadata:\n');manifest.pop('resolutions')
        if name=='config-inputs':
            put(root/'.yarnrc.yml',b'enableGlobalCache: false\n')
            for file in ('releases/yarn.cjs','plugins/a.js','patches/pkg.patch','cache/not-input.zip','unplugged/not-input'):
                put(root/'.yarn'/file,('synthetic '+file+'\n').encode())
        if name.startswith('workspace'):
            pattern={'workspace-star':'packages/*','workspace-question':'packages/?','workspace-class':'packages/[ab]',
                'workspace-escape':r'packages/a\*','workspace-dot':'packages/.*','workspace-modules':'node_modules/*',
                'workspace-outside':'packages/outside','workspace-inside':'packages/inside',
                'workspace-bad':'packages/**','workspace-space':'packages/a b','workspace-negated':'!packages/*',
                'workspace-dotdot':'../*','workspace-quoted-slash':r'packages/ab\/*','workspace-paired-slash':r'packages/ab\\/*'}.get(name,'packages/*')
            manifest['workspaces']=[pattern]
            for rel in ('packages/a','packages/b','packages/.dot','packages/a*','node_modules/one','inside'):
                put(root/rel/'package.json',{'name':rel})
            if name in ('workspace-quoted-slash','workspace-paired-slash'):
                put(root/'packages'/'ab\\'/'item'/'package.json',{'name':'quoted-slash-fixture'})
            put(box/'outside/package.json',{'name':'outside'})
            (root/'packages/inside').symlink_to(root/'inside',target_is_directory=True)
            (root/'packages/outside').symlink_to(box/'outside',target_is_directory=True)
            if name!='workspace-outside':(root/'packages/outside').unlink()
    put(root/'package.json',manifest)
    return {'op':op,'path':str(where)},env


def main():
    ap=argparse.ArgumentParser();ap.add_argument('--core',required=True);ap.add_argument('--only');ap.add_argument('--report',required=True);a=ap.parse_args()
    names=['none','ordinary','classic','no-lock','subdir','boundary','config-inputs','workspace-star','workspace-question','workspace-class','workspace-escape','workspace-dot','workspace-modules','workspace-outside','workspace-inside','workspace-bad','workspace-space','workspace-negated','workspace-dotdot','override','override-filter','override-env','override-subdir','override-boundary','override-empty']
    names+=['workspace-quoted-slash','workspace-paired-slash','backslash-root','backslash-temp',
        'bracket-root','star-root','question-root','quoted-star-root','paired-slash-root','unicode-root']
    if a.only:names=[n for n in names if n in a.only.split(',')]
    assert names;rows=[]
    with tempfile.TemporaryDirectory(prefix='core-pre-context.') as temp:
        outer=Path(temp).resolve();box=outer/'box'
        for name in names:
            if box.exists():shutil.rmtree(box)
            row,extra=seed(box,name)
            env={k:v for k,v in os.environ.items() if not k.startswith('SAFEDEPS_')}
            env.update(extra,LC_ALL='C',LANG='C')
            p=subprocess.run([str(Path(a.core).resolve()),'ledger','context-probe'],input=json.dumps(row).encode(),cwd=box/'project',env=env,capture_output=True,timeout=15)
            absent={'none','no-lock','boundary','override-boundary','override-empty'}
            unsafe={'workspace-bad','workspace-space','workspace-negated','workspace-dotdot','workspace-outside',
                    'backslash-root','bracket-root','quoted-star-root','paired-slash-root'}
            expected_rc=1 if name in absent else 2 if name in unsafe or name=='classic' else 0
            checks={'status':p.returncode==expected_rc}
            if expected_rc:
                checks['empty_output']=not p.stdout
                checks['diagnostic']=bool(p.stderr)==(expected_rc==2)
            else:
                answer=json.loads(p.stdout);project=Path(row['path'])
                if name in ('subdir','override-subdir'):project=project.parent
                root_name='env' if name=='override-env' else str(project)
                checks['root']=answer['project_root']==root_name
                checks['context_hash']=answer['context_hash'].startswith('sha256:') and len(answer['context_hash'])==71
                if name.startswith('override'):
                    want={'valid':'2'} if name=='override-filter' else {'z':'3','a':'1'} if name=='override-env' else {'z':'2','a':{'z':'3','a':'1'}}
                    canonical=json.dumps(want,sort_keys=True,separators=(',',':')).encode()
                    digest=hashlib.sha256(canonical).hexdigest()
                    checks['overrides']=answer['overrides']==want
                    checks['source']=answer['overrides_source']==('env' if name=='override-env' else str(project/'package.json'))
                    checks['digest']=answer['overrides_sha256']=='sha256:'+digest
                    checks['context_hash']=answer['context_hash']=='sha256:'+hashlib.sha256((root_name+'\n'+digest).encode()).hexdigest()
                else:
                    members={'workspace-star':['packages/a','packages/a*','packages/b','inside'],
                             'workspace-question':['packages/a','packages/b'],
                             'workspace-class':['packages/a','packages/b'],
                             'workspace-escape':['packages/a*'],'workspace-dot':['packages/.dot'],
                             'workspace-inside':['inside'],
                             'workspace-paired-slash':[r'packages/ab\/item']}.get(name,[])
                    paths=['package.json','yarn.lock']+[m+'/package.json' for m in members]
                    if name=='config-inputs':paths+=['.yarnrc.yml','.yarn/releases/yarn.cjs','.yarn/plugins/a.js','.yarn/patches/pkg.patch']
                    expected_files=[dict(path=rel,sha256='sha256:'+('\\' if '\\' in str(project/rel) else '')+hashlib.sha256((project/rel).read_bytes()).hexdigest()) for rel in sorted(set(paths))]
                    checks['inputs']=answer['input_files']==expected_files
                    checks['manifest']=answer['manifest_path']==str(project/'package.json')
                    checks['lockfile']=answer['lockfile_path']==str(project/'yarn.lock')
                    checks['type']=answer['type']=='yarn-project-lockfile'
                checks['stderr']=not p.stderr
            passed=all(checks.values())
            rows.append(dict(case=name,checks=checks,passed=passed,rc=p.returncode,stdout=p.stdout.decode(),stderr=p.stderr.decode()))
            print(('ok - ' if passed else 'not ok - ')+name,flush=True)
    Path(a.report).write_text(json.dumps(rows,indent=2))
    bad=sum(not r['passed'] for r in rows)
    print(f'core-pre-context: {len(rows)} cases, {bad} failures',flush=True)
    return int(bool(bad))


if __name__=='__main__':raise SystemExit(main())
