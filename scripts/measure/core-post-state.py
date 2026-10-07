#!/usr/bin/env python3
"""Compare post's journal ownership, trace and staged snapshots with bash.
Run on a test host. Signals target only this script's own fixture child.
Neither npm nor a network request runs. Complete-hook checks remain separate.
"""

if __name__ == "__main__":
    import sys
    sys.stderr.write('retired: Bash journal/trace/workspace comparison is retired. Native owner, trace and report controls retain independent fixtures. See native-measure-disposition.json.\n')
    raise SystemExit(2)

import argparse
import datetime
import hashlib
import importlib.util
import json
import math
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
p.add_argument('--only', help='Comma-separated row names')
p.add_argument('--control-journal-opened', action='store_true', help='Change the reported opening date to the seeded stage date')
p.add_argument('--expect-difference', action='store_true')
p.add_argument('--accept-class',choices=['verified-snapshot-last-present'])
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
log_advisory(){ printf '%s\\t%s\\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$GUARD_DIR/advisory.log"; }
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
clock_slots={}
SEEDED_OPENED='2001-02-03T04:05:06Z'
SEEDED_STAGE='2001-02-03T04:05:17Z'
def wanted(name): return not a.only or name in a.only.split(',')
def epoch(text):
    try: return int(datetime.datetime.strptime(text,'%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc).timestamp())
    except ValueError: return None
def run(side,request,d):
    env=dict(os.environ,ROOT=str(root),SAFEDEPS_HOME=str(d/'home'),LC_ALL='C')
    slots=clock_slots.setdefault(d,dict(logs={},metas={}))
    logs={name:(d/name).read_bytes() if (d/name).is_file() else b'' for name in ['home/advisory.log','home/reorg.log']}
    meta='home/snapshots/verified-'+request.get('id','')+'_meta.json'
    may_seal=request.get('op')=='snapshot' and request.get('action')=='confirm' and not (d/meta).exists()
    lo=math.floor(time.time())
    proc=subprocess.run(['bash',str(script)] if side=='bash' else [core,'post-probe'],input=json.dumps(request).encode(),capture_output=True,env=env,timeout=20)
    hi=math.ceil(time.time())
    for name,before in logs.items():
        after=(d/name).read_bytes() if (d/name).is_file() else b''
        # Only appended log headers generated during this invocation may vary.
        if after.startswith(before): slots['logs'].setdefault(name,[]).append((len(before),len(after),lo,hi))
    if may_seal and (d/meta).is_file(): slots['metas'][meta]=(lo,hi)
    output=proc.stdout.decode(errors='replace')
    if a.control_journal_opened and side=='rust' and request.get('op')=='journal':
        old='Journal: j, opened '+SEEDED_OPENED
        new='Journal: j, opened '+SEEDED_STAGE
        output=output.replace(old,new)
        log=d/'home/reorg.log'
        if log.is_file(): log.write_text(log.read_text().replace(old,new))
    return proc.returncode,output.replace(str(d),'@ROOT@'),proc.stderr.decode(errors='replace')
def disk(d):
    out={}
    for f in (d/'home').rglob('*'):
        key=str(f.relative_to(d))
        if f.is_symlink(): out[key]=['link',os.readlink(f)]
        elif f.is_dir(): out[key]=['dir']
        else:
            raw=f.read_bytes()
            slots=clock_slots.get(d,dict(logs={},metas={}))
            # No shape-wide ISO substitution: opening/stage dates in prose
            # and in an incident are facts read from the immutable seed.
            for start,end,lo,hi in reversed(slots['logs'].get(key,[])):
                chunk=raw[start:end]
                pattern=rb'(?m)^(\[?)(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)(\] |\t)'
                def generated_header(match):
                    at=epoch(match[2].decode())
                    return match[1]+b'TIME'+match[3] if at is not None and lo<=at<=hi else match[0]
                raw=raw[:start]+re.sub(pattern,generated_header,chunk)+raw[end:]
            text=raw.decode(errors='replace').replace(str(d),'@ROOT@')
            try:
                v=json.loads(text)
                if key in slots['metas'] and isinstance(v,dict):
                    lo,hi=slots['metas'][key]
                    timestamp=v.get('timestamp')
                    if type(timestamp) is int and lo<=timestamp<=hi: v['timestamp']='TIME'
                text=json.dumps(v,sort_keys=True)
            except ValueError: pass
            out[key]=['file',text]
    return out
def record(name,bash,rust):
    same=bash==rust;rows.append(dict(name=name,same=same,reference=bash,core=rust))
    if not same: print('DIFF',name,repr(bash),repr(rust),flush=True)
def iso(seconds): return datetime.datetime.fromtimestamp(seconds,datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
fixture_spec=importlib.util.spec_from_file_location('pre_fixture',Path(__file__).with_name('core-post-pre-fixture.py'))
pre_fixture=importlib.util.module_from_spec(fixture_spec);fixture_spec.loader.exec_module(pre_fixture)
project_bytes=pre_fixture.project_bytes

print('start:',subprocess.check_output(['uptime'],text=True).strip(),flush=True)
with tempfile.TemporaryDirectory(prefix='core-post-state.') as tmp:
    box=Path(tmp); script=box/'reference.sh';script.write_text(wrapper)
    for label,pid,opened in [('no-pid','',iso(time.time())),('bad-pid','x',iso(time.time())),('gone','2147483647',iso(time.time())),('alive',str(os.getpid()),iso(time.time())),('reused',str(os.getpid()),'2000-01-01T00:00:00Z'),('bad-opened',str(os.getpid()),'bad'),('zero','0',iso(time.time()))]:
        if not wanted('owner-'+label): continue
        req=dict(op='owner',pid=pid,opened=opened)
        record('owner-'+label,run('bash',req,box)[:2],run('rust',req,box)[:2])
    if wanted('stopped') or wanted('stopped-reused'):
        child=subprocess.Popen(['sleep','60'])
        try:
            os.kill(child.pid,signal.SIGSTOP)
            os.waitpid(child.pid,os.WUNTRACED)
            for label,opened in [('stopped',iso(time.time())),('stopped-reused','2000-01-01T00:00:00Z')]:
                if not wanted(label): continue
                req=dict(op='owner',pid=str(child.pid),opened=opened)
                record(label,run('bash',req,box)[:2],run('rust',req,box)[:2])
        finally:
            os.kill(child.pid,signal.SIGCONT);child.terminate();child.wait()
    if wanted('stopped-session'):
        child=subprocess.Popen(['sleep','60'],start_new_session=True)
        try:
            os.kill(child.pid,signal.SIGSTOP)
            os.waitpid(child.pid,os.WUNTRACED)
            req=dict(op='owner',pid=str(child.pid),opened=iso(time.time()))
            record('stopped-session',run('bash',req,box)[:2],run('rust',req,box)[:2])
        finally:
            os.kill(child.pid,signal.SIGCONT);child.terminate();child.wait()
    if wanted('zombie-session'):
        pid=os.fork()
        if pid==0:
            os.setsid()
            os._exit(0)
        try:
            # Do not reap until both readers have observed this fixture's
            # zombie, including inherited nice and session-leader modifiers.
            until=time.monotonic()+5
            while True:
                status=subprocess.check_output(['ps','-o','state=','-p',str(pid)]).strip()
                if status.startswith(b'Z'):break
                if time.monotonic()>=until:raise RuntimeError('fixture did not become a zombie')
                time.sleep(.01)
            req=dict(op='owner',pid=str(pid),opened=iso(time.time()))
            record('zombie-session',run('bash',req,box)[:2],run('rust',req,box)[:2])
        finally:
            os.waitpid(pid,0)
    facts=box/'trace-facts.sh'
    facts.write_text('''#!/bin/bash
set -eu
source "$ROOT/lib/gates/backstop-trace.sh"
for rel in package-lock.json node_modules/.package-lock.json node_modules; do
    printf '%s\\t%s\\t%s\\n' "$rel" "$(safedeps_tree_inode "$1/$rel")" "$(safedeps_tree_clock "$1/$rel")"
done
''')
    for shape in ['no-entry','malformed','baseline-gone','unchanged','appeared','removed','new-inode','lock-write','linked-lock-write','tree-write']:
        if not wanted('trace-'+shape): continue
        d=box/'trace';shutil.rmtree(d,ignore_errors=True)
        (d/'home').mkdir(parents=True);project=d/'project';project.mkdir()
        clock_slots.pop(d,None)
        lock=project/'package-lock.json';lock.write_text('{}')
        node=project/'node_modules';(node/'item').mkdir(parents=True)
        (node/'item/index.js').write_text('before')
        if shape=='linked-lock-write':
            lock.rename(project/'target.json');lock.symlink_to('target.json')
        if shape=='appeared':lock.unlink()
        listed=subprocess.check_output(['bash',str(facts),str(project)],env=dict(os.environ,ROOT=str(root),LC_ALL='C'),text=True)
        inodes={};clocks={}
        for line in listed.splitlines():
            rel,inode,clock=line.split('\t');inodes[rel]=inode;clocks[rel]=clock
        baseline=d/'baseline';baseline.touch()
        entry=dict(baseline=str(baseline),resolution='subsecond',inodes=inodes,clocks=clocks)
        if shape=='baseline-gone':baseline.unlink()
        if shape=='appeared':lock.write_text('{}')
        if shape=='removed':lock.unlink()
        if shape=='new-inode':
            new=project/'new.json';new.write_text('{}');new.replace(lock)
        if shape in ['lock-write','linked-lock-write']:lock.write_text('{"changed":true}')
        if shape=='tree-write':(node/'item/index.js').write_text('after')
        raw='' if shape=='no-entry' else '[' if shape=='malformed' else json.dumps(entry)
        req=dict(op='trace',path=str(project),entry=raw,none='fixture names no call')
        # A trace probe reads metadata only, so both readers see this one disk.
        record('trace-'+shape,run('bash',req,d)[:2],run('rust',req,d)[:2])
    for action in ['unchanged','changed','added','missing-staged','last-present','two-present','two-content-change','two-list-change','normal-pre','last-absent','empty-list']:
        if not wanted('snapshot-'+action): continue
        normal_list=None;pre_evidence=None
        if action=='normal-pre':
            pre_evidence=pre_fixture.pre_list(root,box/'normal-pre')
            normal_list=pre_evidence['list']
        results=[]
        for side in ['bash','rust']:
            # Restore the seed at one absolute path. The confirmed filename
            # hashes this path, which must remain comparable without a mask.
            d=box/'paired';shutil.rmtree(d,ignore_errors=True);(d/'home/snapshots').mkdir(parents=True);(d/'project').mkdir()
            clock_slots.pop(d,None)
            (d/'project/package.json').write_text('{"name":"kept"}\n')
            (d/'home/snapshots/pre_monitored_files.list').write_text('package.json\npackage-lock.json\npackages/a/package.json\n')
            if action in ['last-present','two-present','two-content-change','two-list-change','normal-pre','last-absent','empty-list']:
                names={'last-present':'package.json\n','two-present':'package.json\npackage-lock.json\n',
                       'two-content-change':'package.json\npackage-lock.json\n','two-list-change':'package.json\npackage-lock.json\n',
                       'normal-pre':normal_list,'last-absent':'package.json\nyarn.lock\n','empty-list':''}[action]
                (d/'home/snapshots/pre_monitored_files.list').write_text(names)
                if action.startswith('two-') or action=='normal-pre':(d/'project/package-lock.json').write_text('{"lockfileVersion":3,"packages":{}}\n')
            before=project_bytes(d/'project')
            list_before=(d/'home/snapshots/pre_monitored_files.list').read_bytes().hex()
            req=dict(op='snapshot',path=str(d/'project'),id='pre',action='stage')
            stages=[run(side,req,d)[:2]]
            if action in ['changed','two-content-change']:(d/'project/package.json').write_text('{"name":"changed"}\n')
            if action=='two-list-change':(d/'home/snapshots/pre_monitored_files.list').write_text('package.json\npackage-lock.json\nyarn.lock\n')
            if action=='added':(d/'project/package-lock.json').write_text('{}')
            if action=='missing-staged':(d/'home/snapshots/verified-pre_monitored_files.list').unlink()
            req['action']='confirm';stages.append(run(side,req,d)[:2]);results.append([stages,disk(d),
                dict(project_before=before,project_after=project_bytes(d/'project'),list_before=list_before,
                     list_after=(d/'home/snapshots/pre_monitored_files.list').read_bytes().hex())])
            if action.startswith('two-'):
                results[-1].append({name:(d/'home/snapshots'/('verified-pre_'+name)).read_bytes().hex()
                                    for name in before if (d/'home/snapshots'/('verified-pre_'+name)).is_file()})
        record('snapshot-'+action,*results)
        if pre_evidence is not None:rows[-1]['pre_generated_fixture']=pre_evidence
        if action.startswith('two-'):
            # The named difference is bounded by this exact synthetic list,
            # unchanged live bytes, and the candidate's real sealed files.
            # No output or disk channel is removed from the row comparison.
            reference,candidate=results
            pointer='home/confirmed_'+hashlib.md5(str(d/'project').encode()).hexdigest()
            state=candidate[1];evidence=candidate[2]
            unchanged=(evidence['project_before']==evidence['project_after'] and evidence['list_before']==evidence['list_after']
                       and reference[2]==evidence)
            copied=all(candidate[3].get(name)==value[1]
                       for name,value in evidence['project_after'].items())
            meta=state.get('home/snapshots/verified-pre_meta.json',['file','null'])[1]
            sealed=json.loads(meta) if meta else None
            sealed_ok=(isinstance(sealed,dict) and sealed.get('project_dir')=='@ROOT@/project'
                       and sealed.get('snapshot_id')=='verified-pre' and sealed.get('verified_from')=='pre'
                       and sealed.get('parent_snapshot_id') is None and sealed.get('timestamp')=='TIME')
            proof=dict(unchanged=unchanged,copies_match_live=copied,sealed_for_this_project=sealed_ok,
                       verified_list_matches=state.get('home/snapshots/verified-pre_monitored_files.list')==['file','package-lock.json\npackage.json\n'],
                       pointer_names_verified=state.get(pointer)==['file','verified-pre\n'],
                       reference_no_pointer=pointer not in reference[1],
                       reference_no_staged_files=not any(k.startswith('home/snapshots/verified-pre_') for k in reference[1]),
                       reference_changed_warning='the dependency files changed while they were being verified' in reference[0][-1][1])
            rows[-1]['independent_confirmation']=proof
            if action=='two-present' and all(proof.values()) and candidate[0][-1]==(0,''):
                rows[-1]['classified_difference']='verified-snapshot-last-present'
            if action!='two-present':
                no_confirmation=all(not any(k.startswith('home/confirmed_') or k=='home/snapshots/verified-pre_meta.json' for k in result[1]) for result in results)
                rows[-1]['changed_input_was_not_confirmed']=no_confirmation
                if not no_confirmation:raise SystemExit('changed bytes or list was confirmed')
    for shape in ['empty','no-pid','gone','live','unreadable','gone-staged']:
        if not wanted('journal-'+shape): continue
        results=[]
        opened=iso(time.time()) if shape=='live' else SEEDED_OPENED
        for side in ['bash','rust']:
            d=box/'paired';shutil.rmtree(d,ignore_errors=True);(d/'home/rollback-journal').mkdir(parents=True);(d/'project').mkdir()
            clock_slots.pop(d,None)
            if shape!='empty':
                v=dict(journal_id='j',project_dir=str(d/'project'),rollback_snapshot='s',reasons='fixture',stage='restoring-files',opened_at=opened)
                if shape in ['gone','gone-staged']:v['pid']='2147483647'
                if shape=='gone-staged':v['stage_at']=SEEDED_STAGE
                if shape=='live':v['pid']=str(os.getpid())
                (d/'home/rollback-journal/j.json').write_text('[' if shape=='unreadable' else json.dumps(v))
            result=run(side,dict(op='journal',action='report'),d)[:2]
            results.append([result,disk(d)])
        record('journal-'+shape,*results)
if a.report:Path(a.report).write_text(json.dumps(rows,ensure_ascii=False,indent=2)+'\n')
bad=sum(not r['same'] for r in rows)
unclassified=sum(not r['same'] and r.get('classified_difference')!=a.accept_class for r in rows)
print('end:',subprocess.check_output(['uptime'],text=True).strip())
print(f'core-post-state: {len(rows)} cases, {bad} differ')
raise SystemExit(0 if rows and (unclassified==0 if a.accept_class else bool(bad)==a.expect_difference) else 1)
