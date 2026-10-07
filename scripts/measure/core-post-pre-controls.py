#!/usr/bin/env python3
"""Remaining report controls reachable through public Codex pre and post.

The hook wrappers, pre/post oracle, and the named assertions are taken from
the existing e2e source. Synthetic projects use empty initial closures; the
pull fixture then writes an unapproved package with a warm advisory cache.
Copies alone receive a source mutation. A build error, missed fixture, or
oracle error is not an assertion control. This is not the full e2e suite.
"""
import argparse
import hashlib
import importlib.util
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
p.add_argument('--names',default='NoIdSilent,PullAlways')
a=p.parse_args()
root=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('native_edits',Path(__file__).with_name('core-post-native-injections.py'))
native_edits=importlib.util.module_from_spec(spec);spec.loader.exec_module(native_edits)
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
post_invocation='    "$POST_CORE" post)'
if wrappers.count(post_invocation)!=1:raise RuntimeError('post wrapper anchor not unique')
wrappers=wrappers.replace(post_invocation,post_invocation+''' || { printf '%s\\n' "$?" > "$call/hook.rc"; return 1; }
  printf '0\\n' > "$call/hook.rc"
  printf '%s' "$out" > "$call/native-hook.stdout"''')
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
    'Oldest':dict(file='rust/src/pre.rs',
        old='    let base = cat(&[&entry_text, b"/id-", id.as_bytes()]);',
        new='    let base = cat(&[&entry_text, b"/id-", state::pending_key(&dir_hash, &call.command).as_bytes(), b"_", std::process::id().to_string().as_bytes()]);',
        also=dict(file='rust/src/post/call.rs',
            old='            let base = call_base(&home.join("pending/backstop"), id);',
            new='''            let dir=home.join("pending/backstop");
            let prefix=format!("id-{}_",key);
            let mut entries:Vec<_>=fs::read_dir(&dir).into_iter().flatten().filter_map(Result::ok)
                .map(|e|e.path()).filter(|p|sh::basename(sh::bytes(p)).starts_with(prefix.as_bytes()) && p.extension().is_some_and(|e|e=="json")).collect();
            entries.sort_by_key(|p|fs::metadata(p).and_then(|m|m.modified()).ok());
            let base=entries.into_iter().next().unwrap_or_else(||call_base(&dir,id)).with_extension("");'''),
        diagnostic='a grep after a failed grep and a pull: the backstop says nothing'),
    'AnySubsecond':dict(file='rust/src/pre.rs',
        old='if present > 0 && subsecond == present && os::clock_has_subsecond',
        new='if subsecond > 0 && os::clock_has_subsecond',
        faults=[native_edits.PRE_EDITS['coarse'],native_edits.EDITS['coarse']],
        diagnostic='a write into node_modules on a whole-second mount beside a subsecond lockfile: the baseline is set back'),
    'F1':dict(file='rust/src/pre/snapshot.rs',
        old='if node.is_dir(){list_packages(&node,0,&mut packages);}',
        new='if node.is_dir()&&!fs::symlink_metadata(&node).is_ok_and(|m|m.file_type().is_symlink()){list_packages(&node,0,&mut packages);}',
        also=dict(file='rust/src/post/rollback.rs',
            old='let mut now=trace::package_files(&tree,true);',
            new='let mut now=trace::package_files(&tree,false);'),
        oracle=True,diagnostic='kept, but before the hook ran node_modules showed a write'),
}
names=a.names.split(',')
if not names or any(name not in cases for name in names):p.error('unknown control name')

def execute(argv,stem,env=None):
    with (run/(stem+'.log')).open('wb') as f:r=subprocess.run(argv,stdout=f,stderr=f,env=env)
    (run/(stem+'.rc')).write_text(str(r.returncode)+'\n')
    return r.returncode

def write_unapproved(path,home):
    path.write_text(json.dumps(dict(lockfileVersion=3,packages={'node_modules/fixture-unapproved':dict(version='1.0.0')}))+'\n')
    for sub in ['osv','kev']:(home/'cache'/sub).mkdir(parents=True,exist_ok=True)
    key=hashlib.sha256(b'osv\nnpm\nfixture-unapproved\n1.0.0').hexdigest()
    (home/'cache/osv'/(key+'.json')).write_text('{"vulns":[]}\n')
    (home/'cache/kev/known_exploited_vulnerabilities.json').write_text('{"vulnerabilities":[]}\n')

def build_copy(stem,edits):
    tree=run/(stem+'-source');tree.mkdir()
    subprocess.run(['tar','xf',str(archive),'-C',str(tree)],check=True)
    for edit in edits:
        path=tree/edit['file'];text=path.read_text()
        if text.count(edit['old'])!=1:raise SystemExit('mutation anchor not unique: '+stem)
        path.write_text(text.replace(edit['old'],edit['new']))
    (run/(stem+'.mutation.json')).write_text(json.dumps(edits,indent=2)+'\n')
    rc=execute([str(cargo),'build','--manifest-path',str(tree/'rust/Cargo.toml'),
                '--release','--locked','--offline','-j1'],stem+'-build',dict(os.environ,SAFEDEPS_CORE_BUILD_KIND='checkout'))
    return rc,tree/'rust/target/release/safedeps-core'

def fixture(name,pre,stem,post=None):
    box=run/stem;project=box/'project';project.mkdir(parents=True)
    home=box/'state';home.mkdir();(box/'home').mkdir()
    for log in ['advisory.log','reorg.log']:(home/log).touch()
    (project/'package.json').write_text('{"name":"fixture","version":"1.0.0","dependencies":{}}\n')
    lock=json.dumps(dict(lockfileVersion=3,packages={}))+'\n'
    (project/'package-lock.json').write_text(lock)
    if name=='F1':
        target=box/'linked-target/node_modules/@s/a';target.mkdir(parents=True)
        (target/'package.json').write_text('{"name":"@s/a","version":"1.0.0"}\n')
        (project/'node_modules').symlink_to(box/'linked-target/node_modules',target_is_directory=True)
        write_unapproved(project/'package-lock.json',home)
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
    if name=='F1':
        script+='''mkdir -p "$BOX/linked-target/node_modules/@s/evil"
printf '%s\\n' '{"name":"@s/evil","version":"1.0.0"}' > "$BOX/linked-target/node_modules/@s/evil/package.json"
post=$(post_hook < "$BOX/install.json")
printf '%s\\n' "$post" > "$BOX/install-post.out"
printf '%s\\n' 'install-post rc0 and original post oracle passed'
grep -qx "$BOX/project/node_modules lists $BOX/project/node_modules/@s/evil/package.json, which the pre-command snapshot .* does not" <<< "$(post_message "$post")" || fail "a package written through a linked node_modules is the reason line"
grep -q '^refused removal of .*/project/node_modules: ' <<< "$(post_message "$post")" || fail "the removal of the linked node_modules is refused"
[[ -L "$BOX/project/node_modules" && -f "$BOX/linked-target/node_modules/@s/evil/package.json" ]] || fail "a rollback leaves the target of a linked node_modules alone"
'''
    else:
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
    elif name!='F1':
        write_unapproved(box/'tampered.json',home)
        call['tool_input']['command']='grep -n "npm install" README.md';call['tool_use_id']='pull-call'
        (box/'grep.json').write_text(json.dumps(call))
        if name=='Oldest':
            failed=dict(call,tool_use_id='failed-call')
            (box/'failed.json').write_text(json.dumps(failed))
        script+='''mkdir -p "$BOX/project/node_modules/installed-package"
printf '%s\\n' '{"name":"installed-package","version":"1.0.0"}' > "$BOX/project/node_modules/installed-package/package.json"
tampered_lock=$(cat "$BOX/tampered.json")
'''
        if name=='Oldest':
            script+='''pre=$(pre_hook < "$BOX/failed.json")
[[ -z "$pre" ]] || fail "the first grep is allowed"
find "$SAFEDEPS_HOME/pending/backstop" -name '*.json' -type f > "$BOX/failed-entry-paths.txt"
'''
        if name!='AnySubsecond':
            script+='''
cp "$BOX/tampered.json" "$BOX/project/.pull"
mv "$BOX/project/.pull" "$BOX/project/package-lock.json"
'''
        script+='''
pre=$(pre_hook < "$BOX/grep.json")
printf '%s\\n' "$pre" > "$BOX/grep-pre.out"
[[ -z "$pre" ]] || fail "the pre-guard lets a grep run"
'''
        if name=='Oldest':
            # Preserve both entries even in the faulty copy, whose filenames
            # deliberately no longer contain the current call's id.
            script+='''mkdir "$BOX/entries-before-post"
cp "$SAFEDEPS_HOME/pending/backstop/"*.json "$BOX/entries-before-post/"
'''
        else:
            script+='cp "$SAFEDEPS_HOME/pending/backstop/id-pull-call.json" "$BOX/entry.json"\n'
        if name=='AnySubsecond':
            script+='''printf 'x\\n' > "$BOX/project/node_modules/installed-package/added.js"
python3 - "$BOX" <<'PY'
import json,os,sys
from pathlib import Path
box=Path(sys.argv[1]);project=box/'project';tree=project/'node_modules'
entry=json.loads((box/'entry.json').read_text());base=Path(entry['baseline']).stat().st_mtime_ns
paths=[tree]
for parent,dirs,files in os.walk(tree):paths.extend(Path(parent)/name for name in dirs+files)
observed=[dict(path=str(p),ctime_ns=p.lstat().st_ctime_ns) for p in paths]
newer=[r['path'] for r in observed if r['ctime_ns']//10**9*10**9>base]
receipt=dict(baseline_ns=base,lock_ctime_ns=(project/'package-lock.json').stat().st_ctime_ns,
             observed=observed,integer_time_newer_paths=newer,entry=entry)
(box/'precision.json').write_text(json.dumps(receipt,indent=2)+'\\n')
if receipt['lock_ctime_ns']%10**9==0:raise SystemExit('fixture lock has no subsecond precision')
PY
'''
        script+='''
post=$(post_hook < "$BOX/grep.json")
printf '%s\\n' "$post" > "$BOX/grep-post.out"
printf '%s\n' 'grep-post rc0 and original post oracle passed'
'''
        if name=='AnySubsecond':
            script+='''bs_mix_entry=$(cat "$BOX/entry.json")
'''+section('[[ "$(jq -r .resolution <<< "${bs_mix_entry:-null}")" == seconds ]]', '[[ "${bs_mix_walk}"')
            script+='''python3 - "$BOX/precision.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
if not d['integer_time_newer_paths']:raise SystemExit('shifted baseline missed the independent integer-time walk')
PY
grep -qF "post-verify BACKSTOP traced: $BOX/project/" "$SAFEDEPS_HOME/advisory.log" || fail "the mixed precision tree is traced"
'''
        elif name=='Oldest':
            script+='''bs_assert_untraced "$BOX/project" "$(post_message "$post")" "a grep after a failed grep and a pull"
[[ -f "$SAFEDEPS_HOME/pending/backstop/id-failed-call.json" && ! -e "$SAFEDEPS_HOME/pending/backstop/id-pull-call.json" ]] || fail "the failed call's entry stays and the read one is gone"
'''
        else:
            script+='''bs_assert_untraced "$BOX/project" "$(post_message "$post")" "a grep right after a pull outside the gate"
[[ "$(jq -r .resolution "$BOX/entry.json")" == subsecond ]] || fail "on a filesystem that keeps time below one second the baseline is not set back"
'''
    script+='printf "%s\\n" "fixture assertion reached and passed"\n'
    path=box/'run.sh';path.write_text(script)
    env={k:v for k,v in os.environ.items() if not k.startswith('SAFEDEPS_')}
    env.update(ROOT_DIR=str(root),BOX=str(box),PRE_CORE=str(pre),POST_CORE=str(post or core),
               SAFEDEPS_HOME=str(home),HOME=str(box/'home'),NPM_CONFIG_USERCONFIG='/dev/null',LC_ALL='C')
    rc=execute(['bash',str(path)],stem,env)
    log=(run/(stem+'.log')).read_text()
    # Preserve bytes and names before any subsequent run; generated times
    # are raw observations only, not claimed clock-provenance equalities.
    raw={str(f.relative_to(box)):f.read_bytes().hex() for f in box.rglob('*') if f.is_file()}
    (run/(stem+'.files.json')).write_text(json.dumps(raw,indent=2)+'\n')
    stages=dict(
        install_pre='install-pre rc0 and original pre oracle passed' in log,
        install_post='install-post rc0 and original post oracle passed' in log,
        grep_post='grep-post rc0 and original post oracle passed' in log)
    # F1 must pass the pre oracle, then fail the post oracle. NoIdSilent's
    # assertion likewise runs before post. Report the actual prerequisite,
    # without describing it as a successful post-oracle run.
    required_stage='install_pre' if name in ['NoIdSilent','F1'] else 'grep_post'
    return dict(rc=rc,expected_diagnostic=cases[name]['diagnostic'],
                diagnostic_found=(cases[name]['diagnostic'] if cases[name].get('oracle') else 'not ok - '+cases[name]['diagnostic']) in log,
                oracle_failed='report oracle:' in log,
                hook_rcs=[int(f.read_text()) for f in (box/'oracle').glob('call.*/hook.rc')],
                completed_hook_and_oracle_stages=stages,
                required_preceding_stage=required_stage,
                required_preceding_stage_passed=stages[required_stage],
                reached='fixture assertion reached and passed' in log)

rows=[]
for name in names:
    change=cases[name]
    faults=[dict(zip(['file','old','new'],edit)) for edit in change.get('faults',[])]
    baseline_core=core
    if faults:
        fault_rc,baseline_core=build_copy(name+'-observations',faults)
        if fault_rc:raise SystemExit(fault_rc)
    baseline=fixture(name,baseline_core,name+'-baseline',post=baseline_core if faults else None)
    if baseline['rc'] or not baseline['reached']:
        (run/'result.json').write_text(json.dumps(dict(rows=rows,failed_baseline=dict(name=name,**baseline)),indent=2)+'\n')
        raise SystemExit('baseline failed: '+name)
    build,mutant=build_copy(name,faults+[change]+([change['also']] if 'also' in change else []))
    control=fixture(name,mutant,name+'-control',post=mutant if faults or 'also' in change else None) if build==0 else None
    passed=(build==0 and control['rc']==1 and control['diagnostic_found'] and control['required_preceding_stage_passed']
            and control['oracle_failed']==bool(change.get('oracle')) and all(rc==0 for rc in control['hook_rcs']))
    if change.get('oracle'):passed=passed and bool(control['hook_rcs'])
    rows.append(dict(name=name,baseline=baseline,build_rc=build,control=control,passed=passed))
    print(name,'caught' if passed else 'FAIL',flush=True)
    (run/'result.json').write_text(json.dumps(dict(rows=rows,full_e2e=False),indent=2)+'\n')
    if not passed:raise SystemExit(1)
