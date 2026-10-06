"""Apply named fixture adapters on an archive; never alter product assertions.

All assertions stay except the explicitly named owner diagnostic spelling.
The removed ps garbage-date parser row is reported as an absent code path,
not a passing native failure injection. Direct fact rows call native probes.
"""
import json
from pathlib import Path
import shlex
import sys

def python_entry(path,source):
    # The original entry shim explicitly runs `bash hook.sh`. Keep the
    # measurement adapter callable through that path as well as its shebang.
    path.write_text('#!/usr/bin/env bash\nexec '+shlex.quote(sys.executable)+' -c '+shlex.quote(source)+'\n')
    path.chmod(0o755)

def direct_calls(text,core):
    for variable,kind,project,extra in [
        ('nofile','missing','${tmp_root}/no-such-project',' --log-body "${nofile_log}"'),
        ('unresolved','unresolved','${unresolved_dir}',''),
    ]:
        start=text.index(variable+'_lines=$(\n')
        end=text.index('\n)\noracle_direct',start)+2
        replacement=(variable+'_lines=$('+shlex.quote(sys.executable)+' "${ROOT_DIR}/scripts/measure/core-post-direct-call.py" --core '
                     +shlex.quote(str(core))+' --meta "${'+variable+'_meta}" --input "${'+variable+'_input}"'
                     +' --project "'+project+'" --kind '+kind+extra+')')
        text=text[:start]+replacement+text[end:]
    return text

def adapt(tree,core,walk_core,owner_core,coarse_core,run):
    path=tree/'scripts/test/e2e.sh';text=path.read_text();edits=[]
    def replace(old,new,why):
        nonlocal text
        if text.count(old)!=1:raise RuntimeError('fixture edit not unique: '+why)
        text=text.replace(old,new);edits.append(dict(reason=why,old=old,new=new))
    replace('oracle_init "${tmp_root}/report-oracle"','oracle_init "${tmp_root}/report-oracle"\noracle_native_owner_forms',
            'same oracle, native owner form coverage')
    replace('Owner: pid ${race_stopped_pid} is stopped (ps state ',
            'Owner: pid ${race_stopped_pid} is stopped (process state ','diagnostic-source-correction')
    replace('for forms_ps_case in "empty|ps gives no start time for pid ${forms_owner_pid}" "garbage|the start time ps gives for pid ${forms_owner_pid} cannot be parsed"; do',
            'for forms_ps_case in "empty|native process query supplied no usable owner data for pid ${forms_owner_pid}"; do',
            'native integer API has no garbage lstart parser; zero response injected in a source copy')
    replace('rmfail_post=$(PATH=', 'printf "held fixture bytes\\n" > "${rmfail_wt}/node_modules/installed-package/held"\nrmfail_post=$(PATH=',
            'a nonempty readonly child makes removal fail under native I/O')
    text=direct_calls(text,core)
    edits.append(dict(reason='the two direct fact rows call the native fact probes; original oracle and assertions retained'))
    path.write_text(text)
    argv=[sys.executable,str(tree/'scripts/measure/core-post-native-hook.py'),'--core',str(core),
          '--walk-core',str(walk_core),'--owner-core',str(owner_core),'--coarse-core',str(coarse_core),
          '--receipts',str(run/'native-injections.jsonl')]
    wrapper=tree/'scripts/safedeps-post-verify.sh'
    python_entry(wrapper,'import os\nos.execv('+repr(sys.executable)+','+repr(argv)+')\n')
    (run/'fixture-adapters.json').write_text(json.dumps(dict(edits=edits,
        absent_native_path=['ps garbage lstart parsing'],
        still_bash=['pre hook']),indent=2)+'\n')
