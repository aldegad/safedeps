#!/usr/bin/env python3
"""jq's stream parser versus the shared Rust parser. No hook, install or I/O
outside child stdin/stdout. --expect-difference checks an old/mutant core.
The seed cases are the parser portion of koon's M1 jq probe (94 total rows;
the other rows exercise jq programs, not the parser and are not counted here).
"""
import argparse
import json
import os
import resource
import subprocess
from pathlib import Path
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--core', required=True)
p.add_argument('--expect-difference', action='store_true')
p.add_argument('--report')
a = p.parse_args()
core = str(Path(a.core).resolve())
# An old recursive parser may abort on the deep controls. Keep its core dump
# out of the machine's disk; the signal remains a comparison failure.
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
cases = [(f'raw-control-{i:02x}', b'"a'+bytes([i])+b'b"') for i in range(32)]
cases += [(s, s.encode()) for s in ['+1','.5','007','nan','NaN','Infinity','-Infinity','0x10','truex','1-2','1 2','1[2]','[1,]','{"a":1,}','true','null','false','[null,true,false,{},[]]','{"a":1,"b":2,"a":3}','1.0','1e2','1.50','0.10','1E+2','-0','1.000000000000000000001','1e-7','0e-7','-0.0','1e','+','.','1..0','1e+-2','[1 2]','{"a" 1}','{"a":}','{1:2}','{}[]"x"false']]
cases += [('bom', b'\xef\xbb\xbf{"a":1}'), ('partial-bom',b'\xef\xbb'), ('bad-utf8',b'"a\xffb"'), ('lone-high',b'"\\ud800x"'), ('lone-low',b'"\\udfff"'), ('surrogate-pair',b'"\\ud83d\\ude00"'), ('escaped-nul',b'"a\\u0000b"'), ('good-then-bad',b'{"a":1}\n{"b"'), ('empty',b'')]
for n in [255,256,257,1000,10001,100000]: cases.append((f'array-depth-{n}',b'['*n+b']'*n))
for n in [127,128,129]: cases.append((f'object-depth-{n}',b'{"a":'*n+b'1'+b'}'*n))
print('start:', subprocess.check_output(['uptime'],text=True).strip(),flush=True)
print('reference:',subprocess.check_output(['jq','--version'],text=True).strip(),flush=True)
rows=[]
for label, data in cases:
    ref=subprocess.run(['jq','-c','.'],input=data,capture_output=True,timeout=10)
    rust=subprocess.run([core,'json-stream'],input=data,capture_output=True,timeout=10)
    same=(ref.returncode,ref.stdout)==(rust.returncode,rust.stdout)
    rows.append(dict(name=label,same=same,reference_rc=ref.returncode,core_rc=rust.returncode,
                     reference=ref.stdout.decode(errors='replace'),core=rust.stdout.decode(errors='replace')))
    if not same: print('DIFF',label,'jq',ref.returncode,repr(ref.stdout[:150]),'core',rust.returncode,repr(rust.stdout[:150]),flush=True)
bad=sum(not r['same'] for r in rows)
if a.report: Path(a.report).write_text(json.dumps(rows,ensure_ascii=False,indent=2)+'\n')
print('end:',subprocess.check_output(['uptime'],text=True).strip())
print(f'core-json-differential: {len(rows)} cases, {bad} differ')
raise SystemExit(0 if (bad>0 if a.expect_difference else bad==0) else 1)
