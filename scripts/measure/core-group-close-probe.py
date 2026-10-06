#!/usr/bin/env python3
"""Check statement endpoints against closed groups, retaining literal braces.

This is a small boundary regression, not a shell syntax validator or an inert
rewrite comparison. Original shell return codes and calls are separate facts.
The previous core is the removal control. Inputs and raw observations are kept.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

HERE = Path(__file__).resolve().parent


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--core', required=True)
    ap.add_argument('--baseline', required=True)
    ap.add_argument('--out', required=True)
    args = ap.parse_args()
    out = Path(args.out); out.mkdir(parents=True)
    spec = importlib.util.spec_from_file_location('word_probe', HERE/'core-zsh-glob-probe.py')
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    fixture = HERE/'core-group-close-cases.jsonl'
    cases = [json.loads(x) for x in fixture.read_text().splitlines()]
    shell = shutil.which('zsh')
    assert shell, 'zsh required'
    stub = out/'stub'; stub.mkdir()
    npm = stub/'npm'
    npm.write_text('#!' + sys.executable + ' -I\n' + '''import json,os,sys
data=(json.dumps([os.fsencode(x).hex() for x in sys.argv[1:]])+'\\n').encode()
fd=os.open(os.environ['NPMLOG'],os.O_WRONLY|os.O_APPEND|os.O_CREAT,0o600)
assert os.write(fd,data)==len(data)
os.close(fd)
''')
    npm.chmod(0o700)
    rows = []; detected = []
    def check(case, axis, ok, **raw):
        rows.append(dict(id=case['id'], axis=axis, ok=ok, **raw))
    def view(core, command, reading, command_args):
        p = subprocess.run([core]+command_args, input=command.encode(), env=dict(os.environ, SAFEDEPS_READING=reading), capture_output=True, timeout=10)
        return dict(rc=p.returncode, stdout_hex=p.stdout.hex(), stderr_hex=p.stderr.hex())
    for case in cases:
        command = case['command']; parsed = {}
        for reading in ('bash', 'zsh', 'dash'):
            parsed[reading] = {}
            for label, core in [('before', args.baseline), ('after', args.core)]:
                data, raw = module.words(core, command, reading)
                parsed[reading][label] = data
                (out/(case['id']+'.'+reading+'.'+label+'.words')).write_bytes(raw)
                check(case, label+'/'+reading+'/read', data['rc'] == 0 and data['unterm'] == 'unterm 0' and data['unreadable'] == 'unreadable 0', data=data)
            if case.get('unchanged'):
                check(case, reading+'/unchanged-words', parsed[reading]['before'] == parsed[reading]['after'])
            for mode in (['payloads'], ['lex', 'classes'], ['lex', 'cmdword'], ['lex', 'live']):
                before = view(args.baseline, command, reading, mode)
                after = view(args.core, command, reading, mode)
                check(case, reading+'/unchanged-'+'-'.join(mode), before == after and after['rc'] == 0, before=before, after=after)
        if 'npm_end' in case:
            ends = {}
            for label, data in parsed['zsh'].items():
                found = [p for p in data['pieces'] if p['words'] and p['words'][0]['start'] == case['npm_start']]
                ends[label] = len(found) == 1 and found[0]['end'] == case['npm_end'] and [w['value'] for w in found[0]['words']] == ['npm','ci','--ignore-scripts=false']
            check(case, 'zsh/npm-end', ends['after'], before=ends['before'], after=ends['after'])
            if not ends['before']: detected.append(case['id'])
        work = out/case['id']; work.mkdir()
        log = out/(case['id']+'.calls.jsonl'); log.write_bytes(b'')
        env = dict(HOME=str(work), ZDOTDIR=str(work), PATH=str(stub)+':/usr/bin:/bin', NPMLOG=str(log), LC_ALL='C')
        p = subprocess.run([shell,'-c',command],cwd=work,env=env,input=b'',capture_output=True,timeout=10)
        calls = [json.loads(x) for x in log.read_text().splitlines()]
        expected = [[x.encode().hex() for x in call] for call in case['argv']]
        check(case, 'original-shell', p.returncode == case['zsh_rc'] and calls == expected, rc=p.returncode, stdout_hex=p.stdout.hex(), stderr_hex=p.stderr.hex(), calls_hex=calls, files={str(f.relative_to(work)):f.read_bytes().hex() for f in work.rglob('*') if f.is_file()})
    rows.append(dict(id='removal-control',axis='old-core-detected',ok=bool(detected), detected=detected))
    failures = [r for r in rows if not r['ok']]
    result = dict(rows=rows, failures=failures, fixture_sha256=hashlib.sha256(fixture.read_bytes()).hexdigest(), binaries={name:dict(path=core,sha256=hashlib.sha256(Path(core).read_bytes()).hexdigest()) for name,core in [('before',args.baseline),('after',args.core)]}, shell=dict(path=shell,sha256=hashlib.sha256(Path(shell).read_bytes()).hexdigest()))
    (out/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    print(f'{len(cases)} inputs, {len(rows)} checks, {len(failures)} failed; previous core lacks {len(detected)} group endpoints',flush=True)
    for failure in failures: print(json.dumps(failure),flush=True)
    return int(bool(failures))


if __name__ == '__main__':
    raise SystemExit(main())
