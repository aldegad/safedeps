#!/usr/bin/env python3
"""Compare post's journal ownership, trace and staged snapshots with bash.
Run on a test host. Signals target only this script's own fixture child.
Neither npm nor a network request runs. Complete-hook checks remain separate.
"""
import argparse
import datetime
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import tempfile
import time

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--core',required=True)
p.add_argument('--report')
a=p.parse_args()
root=Path(__file__).resolve().parents[2]
core=str(Path(a.core).resolve())
src=(root/'scripts/safedeps-post-verify.sh').read_text()
def fun(name):
    start=src.index(name+'() {'); return src[start:src.index('\n}\n',start)+3]
wrapper='''#!/bin/bash
set -uo pipefail
GUARD_DIR="$SAFEDEPS_HOME"
SNAPSHOT_DIR="$GUARD_DIR/snapshots"
STATE_LOCK_DIR="$GUARD_DIR/state.lock"
source "$ROOT/lib/gates/rollback-journal.sh"
source "$ROOT/lib/gates/backstop-trace.sh"
source "$ROOT/lib/npm/workspaces.sh"
source "$ROOT/lib/npm/ask.sh"
SAFEDEPS_LOCK_FILES=(package-lock.json pnpm-lock.yaml yarn.lock bun.lock bun.lockb poetry.lock uv.lock Pipfile.lock requirements.txt Cargo.lock go.sum Gemfile.lock packages.lock.json)
SAFEDEPS_MANIFEST_FILES=(package.json pyproject.toml Pipfile Cargo.toml go.mod Gemfile pom.xml)
ROLLBACK_WARNINGS=()
SAFEDEPS_BACKSTOP_WALK_SECONDS=5
NPM_HIDDEN_LOCKFILE=node_modules/.package-lock.json
log_advisory(){ printf 'TIME\\t%s\\n' "$1" >> "$GUARD_DIR/advisory.log"; }
'''
for n in ['acquire_state_lock','release_state_lock','write_state_file','compute_dir_hash','files_differ','monitored_files','read_confirmed_snapshot','confirm_snapshot','verified_state_file_names','verified_state_path','stage_verified_state','staged_state_matches_project','seal_verified_state','discard_staged_state','confirm_verified_state','collect_protected_snapshot_ids','snapshot_is_protected','cleanup_old_snapshots','backstop_trace']:
    wrapper+=fun(n)+'\n'
wrapper+='''
input=$(cat)
op=$(jq -r .op <<< "$input")
PROJECT_DIR=$(jq -r '.path // ""' <<< "$input")
SNAPSHOT_ID=$(jq -r '.id // ""' <<< "$input")
DIR_HASH=$(compute_dir_hash "$PROJECT_DIR")
VERIFIED_ID="verified-$SNAPSHOT_ID"
VERIFIED_STAGED=true
case "$op" in
owner)
    rc=0; safedeps_journal_owner_state "$(jq -r .pid <<< "$input")" "$(jq -r .opened <<< "$input")" || rc=$?
    printf '%s' "$SAFEDEPS_JOURNAL_OWNER_FACT"; exit "$rc" ;;
trace)
    BACKSTOP_TRACE_ENTRY=$(jq -r .entry <<< "$input")
    BACKSTOP_TRACE_NONE=$(jq -r '.none // ""' <<< "$input")
    backstop_trace ;;
snapshot)
    case $(jq -r .action <<< "$input") in
    stage) stage_verified_state || { discard_staged_state; exit 1; } ;;
    confirm) confirm_verified_state; [[ ${#ROLLBACK_WARNINGS[@]} == 0 ]] || printf '%s' "${ROLLBACK_WARNINGS[*]}" ;;
    cleanup) cleanup_old_snapshots ;;
    esac ;;
journal)
    case $(jq -r .action <<< "$input") in
    report) out=$(safedeps_journal_report_unfinished "$GUARD_DIR/reorg.log" || true); printf '%s' "$out" ;;
    esac ;;
esac
'''

rows=[]
def run(side,request,d):
    env=dict(os.environ,ROOT=str(root),SAFEDEPS_HOME=str(d/'home'),LC_ALL='C')
    proc=subprocess.run(['bash',str(script)] if side=='bash' else [core,'post-probe'],input=json.dumps(request).encode(),capture_output=True,env=env,timeout=20)
    return proc.returncode,proc.stdout.decode(errors='replace').replace(str(d),'@ROOT@'),proc.stderr.decode(errors='replace')
def disk(d):
    out={}
    for f in (d/'home').rglob('*'):
        key=str(f.relative_to(d))
        if f.is_symlink(): out[key]=['link',os.readlink(f)]
        elif f.is_dir(): out[key]=['dir']
        else:
            text=f.read_text(errors='replace').replace(str(d),'@ROOT@')
            text=re.sub(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ','TIME',text)
            try:
                v=json.loads(text)
                if isinstance(v,dict) and 'timestamp' in v: v['timestamp']='TIME'
                text=json.dumps(v,sort_keys=True)
            except ValueError: pass
            out[key]=['file',text]
    return out
def record(name,bash,rust):
    same=bash==rust;rows.append(dict(name=name,same=same,reference=bash,core=rust))
    if not same: print('DIFF',name,repr(bash),repr(rust),flush=True)
def iso(seconds): return datetime.datetime.fromtimestamp(seconds,datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

print('start:',subprocess.check_output(['uptime'],text=True).strip(),flush=True)
with tempfile.TemporaryDirectory(prefix='core-post-state.') as tmp:
    box=Path(tmp); script=box/'reference.sh';script.write_text(wrapper)
    for label,pid,opened in [('no-pid','',iso(time.time())),('bad-pid','x',iso(time.time())),('gone','2147483647',iso(time.time())),('alive',str(os.getpid()),iso(time.time())),('reused',str(os.getpid()),'2000-01-01T00:00:00Z'),('bad-opened',str(os.getpid()),'bad'),('zero','0',iso(time.time()))]:
        req=dict(op='owner',pid=pid,opened=opened)
        record('owner-'+label,run('bash',req,box)[:2],run('rust',req,box)[:2])
    child=subprocess.Popen(['sleep','60'])
    try:
        os.kill(child.pid,signal.SIGSTOP)
        for label,opened in [('stopped',iso(time.time())),('stopped-reused','2000-01-01T00:00:00Z')]:
            req=dict(op='owner',pid=str(child.pid),opened=opened)
            record(label,run('bash',req,box)[:2],run('rust',req,box)[:2])
    finally:
        os.kill(child.pid,signal.SIGCONT);child.terminate();child.wait()
    for action in ['unchanged','changed','added','missing-staged']:
        results=[]
        for side in ['bash','rust']:
            d=box/side;shutil.rmtree(d,ignore_errors=True);(d/'home/snapshots').mkdir(parents=True);(d/'project').mkdir()
            (d/'project/package.json').write_text('{"name":"kept"}\n')
            (d/'home/snapshots/pre_monitored_files.list').write_text('package.json\npackage-lock.json\npackages/a/package.json\n')
            req=dict(op='snapshot',path=str(d/'project'),id='pre',action='stage')
            stages=[run(side,req,d)[:2]]
            if action=='changed':(d/'project/package.json').write_text('{"name":"changed"}\n')
            if action=='added':(d/'project/package-lock.json').write_text('{}')
            if action=='missing-staged':(d/'home/snapshots/verified-pre_monitored_files.list').unlink()
            req['action']='confirm';stages.append(run(side,req,d)[:2]);results.append([stages,disk(d)])
        record('snapshot-'+action,*results)
    for shape in ['empty','no-pid','gone','live','unreadable']:
        results=[]
        for side in ['bash','rust']:
            d=box/side;shutil.rmtree(d,ignore_errors=True);(d/'home/rollback-journal').mkdir(parents=True);(d/'project').mkdir()
            if shape!='empty':
                v=dict(journal_id='j',project_dir=str(d/'project'),rollback_snapshot='s',reasons='fixture',stage='restoring-files',opened_at=iso(time.time()))
                if shape=='gone':v['pid']='2147483647'
                if shape=='live':v['pid']=str(os.getpid())
                (d/'home/rollback-journal/j.json').write_text('[' if shape=='unreadable' else json.dumps(v))
            result=run(side,dict(op='journal',action='report'),d)[:2]
            result=(result[0],re.sub(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ','TIME',result[1]))
            results.append([result,disk(d)])
        record('journal-'+shape,*results)
if a.report:Path(a.report).write_text(json.dumps(rows,ensure_ascii=False,indent=2)+'\n')
bad=sum(not r['same'] for r in rows)
print('end:',subprocess.check_output(['uptime'],text=True).strip())
print(f'core-post-state: {len(rows)} cases, {bad} differ')
raise SystemExit(1 if bad else 0)
