#!/usr/bin/env python3
"""Two remaining report controls through public Codex pre and native post.

The hook wrappers, pre/post oracle, and the named assertions are taken from
the existing e2e source. Synthetic projects use empty initial closures; the
pull fixture then writes an unapproved package with a warm advisory cache.
Copies alone receive a source mutation. A build error, missed fixture, or
oracle error is not an assertion control. This is not the full e2e suite.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--archive',required=True)
p.add_argument('--core',required=True)
p.add_argument('--cargo',required=True)
p.add_argument('--run-dir',required=True)
a=p.parse_args()
root=Path(__file__).resolve().parents[2]
archive=Path(a.archive).resolve(strict=True);core=Path(a.core).resolve(strict=True)
cargo=Path(a.cargo).resolve(strict=True)
run=Path(a.run_dir).resolve();run.mkdir(parents=True,exist_ok=False)
e2e=(root/'scripts/test/e2e.sh').read_text()

def section(start,end):
    if e2e.count(start)!=1 or e2e.count(end)!=1:raise RuntimeError('e2e anchor not unique')
    return e2e[e2e.index(start):e2e.index(end)]

wrappers=section('post_message() {','# Children the owner-state tests spawn')
wrappers=wrappers.replace('"${ROOT_DIR}/scripts/safedeps-pre-guard.sh"','"$PRE_CORE" pre')
wrappers=wrappers.replace('"${ROOT_DIR}/scripts/safedeps-post-verify.sh"','"$POST_CORE" post')
wrappers=wrappers.replace('  oracle_before "${call}" "${payload}"','  : > "${call}/native-owner-source"\n  oracle_before "${call}" "${payload}"')
noid_assert=section('grep -qF "pre-guard: this hook\'s input names no tool_use_id, so the record of this install is kept under its directory and command"', 'touch "${noid_wt}/package-lock.json"')
untraced=section('bs_assert_untraced() {','bs_assert_rollback() {')
prologue='''#!/bin/bash
set -euo pipefail
cd "$BOX/project"
fail() { printf 'not ok - %s\\n' "$1" >&2; exit 1; }
source "$ROOT_DIR/scripts/test/lib/report-oracle.sh"
oracle_init "$BOX/oracle"
'''+wrappers+untraced
cases={
    'NoIdSilent':dict(file='rust/src/pre/pending.rs',
        old='        state::log_advisory(&call.guard_dir,&cat(&[b"pre-guard: this hook\'s input names no tool_use_id, so the record of this install is kept under its directory and command, and another call of the same command in the same directory can use it. Command: ",&call.command]));',
        new='',diagnostic='the pre-guard records that a call names no tool_use_id'),
    'PullAlways':dict(file='rust/src/pre.rs',
        old='if present > 0 && subsecond == present && os::clock_has_subsecond',
        new='if false && present > 0 && subsecond == present && os::clock_has_subsecond',
        diagnostic='a grep right after a pull outside the gate: the backstop says nothing'),
}

def execute(argv,stem,env=None):
    with (run/(stem+'.log')).open('wb') as f:r=subprocess.run(argv,stdout=f,stderr=f,env=env)
    (run/(stem+'.rc')).write_text(str(r.returncode)+'\n')
    return r.returncode

def fixture(name,pre,stem):
    box=run/stem;project=box/'project';project.mkdir(parents=True)
    home=box/'state';home.mkdir();(box/'home').mkdir()
    for log in ['advisory.log','reorg.log']:(home/log).touch()
    (project/'package.json').write_text('{"name":"fixture","version":"1.0.0","dependencies":{}}\n')
    lock=json.dumps(dict(lockfileVersion=3,packages={}))+'\n'
    (project/'package-lock.json').write_text(lock)
    call=dict(tool_name='Bash',cwd=str(project),tool_input=dict(command='npm install'),turn_id='fixture-turn')
    if name!='NoIdSilent':call['tool_use_id']='setup-call'
    (box/'install.json').write_text(json.dumps(call))
    script=prologue+'''pre=$(pre_hook < "$BOX/install.json")
printf '%s\\n' "$pre" > "$BOX/install-pre.out"
[[ -z "$pre" ]] || fail "Codex empty install pre is quiet"
printf '%s\n' 'install-pre rc0 and original pre oracle passed'
'''
    if name=='NoIdSilent':
        script+='''noid_record=$(find "$SAFEDEPS_HOME/pending" -name '*.json' -type f | head -n 1)
[[ "${noid_record##*/}" == *__*.json ]] || fail "a call with no tool_use_id keeps its record under the directory and the command (${noid_record})"
'''+noid_assert
    script+='''touch "$BOX/project/package-lock.json"
post=$(post_hook < "$BOX/install.json")
printf '%s\\n' "$post" > "$BOX/install-post.out"
[[ -z "$post" ]] || fail "the setup install is confirmed quietly"
printf '%s\n' 'install-post rc0 and original post oracle passed'
'''
    if name=='NoIdSilent':
        script+='''[[ ! -e "$noid_record" ]] || fail "the post hook consumes the no-id record"
grep -qF "post-verify: this hook's input names no tool_use_id, so it took the record ${noid_record} by the directory and the command" "$SAFEDEPS_HOME/advisory.log" || fail "the post hook records that it took a record by the key"
'''
    else:
        tampered=json.dumps(dict(lockfileVersion=3,packages={'node_modules/fixture-unapproved':dict(version='1.0.0')}))
        (box/'tampered.json').write_text(tampered+'\n')
        for sub in ['osv','kev']:(home/'cache'/sub).mkdir(parents=True)
        key=hashlib.sha256(b'osv\nnpm\nfixture-unapproved\n1.0.0').hexdigest()
        (home/'cache/osv'/(key+'.json')).write_text('{"vulns":[]}\n')
        (home/'cache/kev/known_exploited_vulnerabilities.json').write_text('{"vulnerabilities":[]}\n')
        call['tool_input']['command']='grep -n "npm install" README.md';call['tool_use_id']='pull-call'
        (box/'grep.json').write_text(json.dumps(call))
        script+='''mkdir -p "$BOX/project/node_modules/installed-package"
printf '%s\\n' '{"name":"installed-package","version":"1.0.0"}' > "$BOX/project/node_modules/installed-package/package.json"
tampered_lock=$(cat "$BOX/tampered.json")
cp "$BOX/tampered.json" "$BOX/project/.pull"
mv "$BOX/project/.pull" "$BOX/project/package-lock.json"
pre=$(pre_hook < "$BOX/grep.json")
printf '%s\\n' "$pre" > "$BOX/grep-pre.out"
[[ -z "$pre" ]] || fail "the pre-guard lets a grep run"
cp "$SAFEDEPS_HOME/pending/backstop/id-pull-call.json" "$BOX/entry.json"
post=$(post_hook < "$BOX/grep.json")
printf '%s\\n' "$post" > "$BOX/grep-post.out"
printf '%s\n' 'grep-post rc0 and original post oracle passed'
bs_assert_untraced "$BOX/project" "$(post_message "$post")" "a grep right after a pull outside the gate"
[[ "$(jq -r .resolution "$BOX/entry.json")" == subsecond ]] || fail "on a filesystem that keeps time below one second the baseline is not set back"
'''
    script+='printf "%s\\n" "fixture assertion reached and passed"\n'
    path=box/'run.sh';path.write_text(script)
    env={k:v for k,v in os.environ.items() if not k.startswith('SAFEDEPS_')}
    env.update(ROOT_DIR=str(root),BOX=str(box),PRE_CORE=str(pre),POST_CORE=str(core),
               SAFEDEPS_HOME=str(home),HOME=str(box/'home'),NPM_CONFIG_USERCONFIG='/dev/null',LC_ALL='C')
    rc=execute(['bash',str(path)],stem,env)
    log=(run/(stem+'.log')).read_text()
    # Preserve bytes and names before any subsequent run; generated times
    # are raw observations only, not claimed clock-provenance equalities.
    raw={str(f.relative_to(box)):f.read_bytes().hex() for f in box.rglob('*') if f.is_file()}
    (run/(stem+'.files.json')).write_text(json.dumps(raw,indent=2)+'\n')
    return dict(rc=rc,expected_diagnostic=cases[name]['diagnostic'],
                diagnostic_found=('not ok - '+cases[name]['diagnostic']) in log,
                oracle_failed='report oracle:' in log,
                hook_and_oracle_passed=('install-pre rc0 and original pre oracle passed' if name=='NoIdSilent' else 'grep-post rc0 and original post oracle passed') in log,
                reached='fixture assertion reached and passed' in log)

rows=[]
for name,change in cases.items():
    baseline=fixture(name,core,name+'-baseline')
    if baseline['rc'] or not baseline['reached']:
        (run/'result.json').write_text(json.dumps(dict(rows=rows,failed_baseline=dict(name=name,**baseline)),indent=2)+'\n')
        raise SystemExit('baseline failed: '+name)
    tree=run/(name+'-source');tree.mkdir()
    subprocess.run(['tar','xf',str(archive),'-C',str(tree)],check=True)
    path=tree/change['file'];text=path.read_text()
    if text.count(change['old'])!=1:raise SystemExit('mutation anchor not unique: '+name)
    path.write_text(text.replace(change['old'],change['new']))
    (run/(name+'.mutation.json')).write_text(json.dumps(change,indent=2)+'\n')
    build=execute([str(cargo),'build','--manifest-path',str(tree/'rust/Cargo.toml'),
                   '--release','--locked','--offline','-j1'],name+'-build',dict(os.environ,SAFEDEPS_CORE_BUILD_KIND='checkout'))
    control=fixture(name,tree/'rust/target/release/safedeps-core',name+'-control') if build==0 else None
    passed=build==0 and control['rc']==1 and control['diagnostic_found'] and control['hook_and_oracle_passed'] and not control['oracle_failed']
    rows.append(dict(name=name,baseline=baseline,build_rc=build,control=control,passed=passed))
    print(name,'caught' if passed else 'FAIL',flush=True)
    (run/'result.json').write_text(json.dumps(dict(rows=rows,full_e2e=False),indent=2)+'\n')
    if not passed:raise SystemExit(1)
