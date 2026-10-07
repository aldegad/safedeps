#!/usr/bin/env python3
"""Keep raw control bytes while matching the shell record-read boundary.

The JSONL input is unchanged through the lexer and structured fields. Only
facts serializes the resolver record through Bash's IFS read contract.
An older core must fail at that boundary, not at the lexer or process layer.
"""

if __name__ == "__main__":
    import sys
    sys.stderr.write('retired: This extracted Bash fact/lexer comparison is retired with those references. See native-measure-disposition.json.\n')
    raise SystemExit(2)

import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile

HERE=Path(__file__).resolve().parent

def load(name,file):
    spec=importlib.util.spec_from_file_location(name,HERE/file);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m


def main():
    ap=argparse.ArgumentParser();ap.add_argument('--core',required=True);ap.add_argument('--baseline',required=True);ap.add_argument('--inputs',required=True);ap.add_argument('--report',required=True);a=ap.parse_args()
    commands=[json.loads(line) for line in Path(a.inputs).read_text().splitlines() if line.strip()]
    assert commands==['echo "\x1d"; pip install evil==6.6.6'],commands
    text=commands[0].encode();lex=load('lex_diff','core-lex-differential.py')
    program=lex.lexer_program();exre,shre=lex.grammar_values();rows=[];bad=[]
    with tempfile.TemporaryDirectory(prefix='target-boundary.') as tmp:
        for reading in ('bash','zsh','dash'):
            for view in ('pieces','stmtcuts','stmtraw','recognize'):
                expected=lex.run_awk(program,exre,shre,tmp,text,view,reading)
                for side,core in (('candidate',a.core),('baseline',a.baseline)):
                    actual=lex.run_core_batch(core,[(text,view,reading)])[0]
                    row=dict(stage='lexer',side=side,reading=reading,view=view,same=expected==actual,
                             expected=[expected[0],expected[1].hex(),*expected[2:]],actual=[actual[0],actual[1].hex(),*actual[2:]])
                    rows.append(row)
                    if not row['same']:bad.append(row)
            request=dict(op='target-statements',command=commands[0],cwd=tmp,reading=reading)
            p=subprocess.run([a.core,'pre-probe'],input=(json.dumps(request)+'\n').encode(),capture_output=True)
            value=json.loads(p.stdout) if p.returncode==0 else []
            # command_statements folds the quoted control byte to its empty
            # word marker, while the pieces retain the original byte. The
            # original stmtcuts/stmtraw/pieces outputs are compared above.
            same=bool(value) and value[0]['uwords']=='echo \x1d' and value[0]['words']=='echo \x1d' and value[0]['tokens']==['echo','\x02']
            row=dict(stage='structure',reading=reading,rc=p.returncode,same=same,value=value,stderr=p.stderr.decode(errors='replace'));rows.append(row)
            if not same:bad.append(row)
        for side,core,expected_rc in (('baseline',a.baseline,1),('candidate',a.core,0)):
            report=Path(tmp)/(side+'.json')
            p=subprocess.run(['python3',str(HERE/'core-facts-differential.py'),'--core',core,'--jobs','1','--sets','harvest','--commands',a.inputs,'--report',str(report)],capture_output=True)
            result=json.loads(report.read_text()) if report.exists() else None
            same=p.returncode==expected_rc and result is not None and result['commands']==1
            if side=='baseline':same=same and len(result['mismatches'])==1 and result['mismatches'][0]['keys']==['targets.bash'] and result['unclassified']==1
            else:same=same and not result['mismatches'] and result['unclassified']==0
            row=dict(stage='facts',side=side,expected_rc=expected_rc,actual_rc=p.returncode,same=same,result=result,stdout=p.stdout.decode(errors='replace'),stderr=p.stderr.decode(errors='replace'));rows.append(row)
            if not same:bad.append(row)
    Path(a.report).write_text(json.dumps(rows,indent=2))
    print(f'core-target-boundary: {len(rows)} checks, {len(bad)} failed')
    for row in bad:print(json.dumps(row))
    return int(bool(bad))

if __name__=='__main__':raise SystemExit(main())
