#!/usr/bin/env python3
"""Hold the consumers of target statements to Bash's original reading driver.

No command is evaluated. The same npm stub records every argument and the
full carried environment. Field values and the trace-attribution sentence
are compared without text/path normalization. A saved JSONL is the input.
"""

if __name__ == "__main__":
    import sys
    sys.stderr.write('retired: The patched Bash reading-state reference is retired. Native reader batteries own fixed expectations. See native-measure-disposition.json.\n')
    raise SystemExit(2)

import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import tempfile

HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('target_probe',HERE/'core-pre-targets-probe.py')
target=importlib.util.module_from_spec(spec);spec.loader.exec_module(target)

def reference(box):
    source=(target.ROOT/'scripts/safedeps-pre-guard.sh').read_text()
    source=source[:source.index('\nTIMESTAMP=$(date +%s)',source.index('# --- Reorg Guard Activated ---'))]
    source+='''
GUARD_IS_CODEX=true
for guard_reading in ${GUARD_READING_SET}; do guard_reading_effects "$guard_reading"; done
FAILED=false
guard_scan_failed && FAILED=true
SPECS=""
if (( ${#LEDGER_SPECS[@]} > 0 )); then SPECS=$(printf '%s\\n' "${LEDGER_SPECS[@]}"); fi
FETCH_JSON=null
[[ -z "$PROJECT_FETCH" ]] || FETCH_JSON="$PROJECT_FETCH"
jq -nc --arg set "$GUARD_READING_SET" --argjson closed "$GUARD_READ_CLOSED" --argjson install "$GUARD_ANY_INSTALL" \\
 --argjson piped "$PIPED_BESIDE_VISIBLE" --argjson hidden "$GUARD_HIDDEN_UNREDUCED" \\
 --arg eco "$LEDGER_ECOSYSTEM" --arg specs "$SPECS" --arg project "$PROJECT_DIR" --arg from "$PROJECT_DIR_FROM" \\
 --argjson fetch "$FETCH_JSON" --arg why "$PROJECT_FETCH_WHY" --argjson seen "$GUARD_NPM_SEEN" --argjson global "$GUARD_NPM_ALL_GLOBAL" \\
 --arg ungeco "$GUARD_UNGATED_ECOSYSTEM" --arg ungated "$GUARD_UNGATED" --argjson trace "$NPM_TRACE_WANTED" \\
 --arg attribution "$ATTRIBUTION" --argjson failed "$FAILED" \\
 '{reading_set:$set,closed:$closed,any_install:$install,piped:$piped,hidden_unreduced:$hidden,ledger_eco:$eco,ledger_specs:$specs,project:$project,project_from:$from,fetch:$fetch,fetch_why:$why,npm_seen:$seen,npm_all_global:$global,ungated_eco:$ungeco,ungated:$ungated,trace:$trace,attribution:$attribution,failed:$failed}'
'''
    ref=box/'oracle/scripts/readings.sh';ref.parent.mkdir(parents=True)
    (box/'oracle/lib').symlink_to(target.ROOT/'lib',target_is_directory=True)
    ref.write_text(source);return ref

def cases(box):
    names={'plain','ci','other','cd','global-answer','export-home','rc-global','code-path','dynamic','record-separator'}
    rows=[row for row in target.cases(box) if row['id'] in names]
    rows.extend(dict(id=i,command=c) for i,c in [
        ('unpinned','pip install unpinned'),('mixed','pip install one==1 two'),
        ('runner','npx tool'),('pinned-and-unpinned','pnpm add one@1 && pnpm add one'),
        ('two-writers','npm ci; npm ci'),('inert-between','npm ci; echo hi; npm ci'),
        ('change-between','npm ci; cd sub; npm ci'),('writer-and-script','npm ci; npm run build; npm ci'),
        ('relocates','npm --prefix sub ci; npm ci'),('payload-writer',"npm ci; sh -c 'npm ci'"),
        ('payload-alone',"sh -c 'npm ci'"),('redirect','npm ci; echo hi > file; npm ci'),
        ('null-redirect','npm ci; echo hi > /dev/null; npm ci'),
        ('fd-redirect','npm ci; echo hi 2>&1; npm ci'),
        ('substitution','npm ci; echo $(true); npm ci'),('piped',"npm ci; echo 'npm ci' | sh"),
        ('global-with-payload',"npm -g install x; sh -c 'npm ci'"),
    ])
    return rows

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--core',required=True);ap.add_argument('--report',required=True);ap.add_argument('--only');ap.add_argument('--expect-difference',action='store_true');a=ap.parse_args()
    results=[]
    with tempfile.TemporaryDirectory(prefix='core-pre-readings.') as temp:
        box=Path(temp).resolve();ref=reference(box);target.stub(box)
        for rel in ('project/sub','home/other','tmp','state','calls'):(box/rel).mkdir(parents=True,exist_ok=True)
        env=dict(os.environ,HOME=str(box/'home'),TMPDIR=str(box/'tmp'),SAFEDEPS_HOME=str(box/'state'),PATH=str(box/'bin')+':'+os.environ['PATH'],LANG='C',LC_ALL='C',PWD=str(box/'project'))
        for k in list(env):
            if k.lower().startswith('npm_config_') or k.startswith('SAFEDEPS_') and k!='SAFEDEPS_HOME':env.pop(k)
        rows=cases(box)
        if a.only:rows=[r for r in rows if r['id'] in a.only.split(',')]
        assert rows
        Path(a.report).with_suffix('.inputs.jsonl').write_text(''.join(json.dumps(r)+'\n' for r in rows))
        for row in rows:
            (box/'answer.json').write_text(json.dumps(row.get('answer',{})))
            (box/'project/.npmrc').write_text(row.get('rc',''))
            payload=dict(op='readings',command=row['command'],tool_name='Bash',tool_input={'command':row['command']},cwd=str(box/'project'),turn_id='synthetic-turn')
            expected=target.run_one(['/bin/bash',str(ref)],payload,env,box)
            actual=target.run_one([a.core,'pre-probe'],payload,env,box)
            channels=[k for k in expected if expected[k]!=actual[k]]
            if expected['rc']!=0 or not expected['stdout'].startswith('{'):channels.append('reference-failed')
            if expected['executed'] or actual['executed']:channels.append('code-executed')
            results.append(dict(id=row['id'],channels=channels,expected=expected,actual=actual))
            print(('DIFF' if channels else 'ok')+' '+row['id']+' '+','.join(channels),flush=True)
    Path(a.report).write_text(json.dumps(results,indent=2));bad=sum(bool(r['channels']) for r in results)
    print(f'core-pre-readings: {len(results)} rows, {bad} differ',flush=True)
    reference_ok=all(r['expected']['rc']==0 and r['expected']['stdout'].startswith('{') and not r['expected']['executed'] for r in results)
    return int(not (reference_ok and bad) if a.expect_difference else bool(bad))

if __name__=='__main__':raise SystemExit(main())
