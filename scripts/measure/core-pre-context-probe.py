#!/usr/bin/env python3
"""Project ledger context against the original Yarn/override file readers.

Every invocation uses the same restored absolute paths. No hash, path or
source date is normalized. Inputs are JSON, no package manager is executed.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[2]
REFERENCE=r'''#!/bin/bash
set -euo pipefail
source "$1/lib/npm/closure.sh"
input=$(cat)
project=$(jq -r .path <<< "$input")
op=$(jq -r .op <<< "$input")
output=$(mktemp)
source_file=$(mktemp)
trap 'rm -f "$output" "$source_file"' EXIT
if [[ "$op" == yarn || "$op" == project ]]; then
  rc=0
  safedeps_npm_yarn_project_context "$output" "$project" || rc=$?
  if [[ "$rc" == 0 ]]; then cat "$output"; exit 0; fi
  if [[ "$op" == yarn || "$rc" != 1 ]]; then exit "$rc"; fi
fi
raw=$(SAFEDEPS_NPM_OVERRIDES_DIR="$project" safedeps_npm_repo_overrides_json "$source_file")
safedeps_npm_overrides_context "$output" "$raw" "$(cat "$source_file")" || exit 1
cat "$output"
'''


def put(path,value):
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_bytes(value if isinstance(value,bytes) else json.dumps(value).encode())


def seed(box,name):
    root=box/'project';root.mkdir(parents=True);(root/'.git').write_text('synthetic worktree marker\n')
    manifest={'name':'fixture','version':'1.0.0'}
    env={};op='yarn';where=root
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
                'workspace-dotdot':'../*'}.get(name,'packages/*')
            manifest['workspaces']=[pattern]
            for rel in ('packages/a','packages/b','packages/.dot','packages/a*','node_modules/one','inside'):
                put(root/rel/'package.json',{'name':rel})
            put(box/'outside/package.json',{'name':'outside'})
            (root/'packages/inside').symlink_to(root/'inside',target_is_directory=True)
            (root/'packages/outside').symlink_to(box/'outside',target_is_directory=True)
            if name!='workspace-outside':(root/'packages/outside').unlink()
    put(root/'package.json',manifest)
    return {'op':op,'path':str(where)},env


def main():
    ap=argparse.ArgumentParser();ap.add_argument('--core',required=True);ap.add_argument('--only');ap.add_argument('--expect-difference',action='store_true');ap.add_argument('--report',required=True);a=ap.parse_args()
    names=['none','ordinary','classic','no-lock','subdir','boundary','config-inputs','workspace-star','workspace-question','workspace-class','workspace-escape','workspace-dot','workspace-modules','workspace-outside','workspace-inside','workspace-bad','workspace-space','workspace-negated','workspace-dotdot','override','override-filter','override-env','override-subdir','override-boundary','override-empty']
    if a.only:names=[n for n in names if n in a.only.split(',')]
    assert names;rows=[]
    with tempfile.TemporaryDirectory(prefix='core-pre-context.') as temp:
        outer=Path(temp).resolve();box=outer/'box';ref=outer/'reference.sh';ref.write_text(REFERENCE)
        for name in names:
            pair=[]
            for side in ('bash','core'):
                if box.exists():shutil.rmtree(box)
                row,extra=seed(box,name)
                env={k:v for k,v in os.environ.items() if not k.startswith('SAFEDEPS_')}
                env.update(extra,LC_ALL='C',LANG='C')
                cmd=['/bin/bash',str(ref),str(ROOT)] if side=='bash' else [str(Path(a.core).resolve()),'ledger','context-probe']
                p=subprocess.run(cmd,input=json.dumps(row).encode(),cwd=box/'project',env=env,capture_output=True,timeout=15)
                pair.append(dict(rc=p.returncode,stdout=p.stdout.decode(errors='surrogateescape'),stderr=p.stderr.decode(errors='surrogateescape')))
            channels=[k for k in pair[0] if pair[0][k]!=pair[1][k]]
            rows.append(dict(case=name,channels=channels,reference=pair[0],candidate=pair[1]))
            print(('DIFF' if channels else 'ok')+' '+name+' '+','.join(channels),flush=True)
    Path(a.report).write_text(json.dumps(rows,indent=2))
    bad=sum(bool(r['channels']) for r in rows);print(f'core-pre-context: {len(rows)} cases, {bad} differ',flush=True)
    return int(not bad if a.expect_difference else bool(bad))

if __name__=='__main__':raise SystemExit(main())
