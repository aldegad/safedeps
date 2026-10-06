#!/usr/bin/env python3
"""Archive-only controls for core-pre-claude-probe; run inside a remote slot.

Two preflight faults use the unchanged, stamped core and must stop before the
public hook. Removing A's collision consumer must fail the public oracle.
The synthetic producer forces three readings and supplies equal/mixed values;
it checks consumer precedence, not B's classification of a real command.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tarfile


def write_json(path, obj):
    path.write_text(json.dumps(obj, indent=2) + '\n')


def replace_once(path, old, new):
    text = path.read_text()
    if text.count(old) != 1:
        raise ValueError('mutation occurrence count: ' + str(path))
    before = hashlib.sha256(path.read_bytes()).hexdigest()
    path.write_text(text.replace(old, new))
    return dict(path=str(path), before=before,
                after=hashlib.sha256(path.read_bytes()).hexdigest(), old=old, new=new)


def invoke(argv, cwd, env, prefix):
    with prefix.with_suffix('.stdout').open('wb') as out, prefix.with_suffix('.stderr').open('wb') as err:
        p = subprocess.run(argv, cwd=cwd, env=env, stdout=out, stderr=err)
    prefix.with_suffix('.rc').write_text(str(p.returncode) + '\n')
    return p.returncode


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source', required=True)
    ap.add_argument('--core', required=True)
    ap.add_argument('--cases', required=True)
    ap.add_argument('--toolchain', required=True)
    ap.add_argument('--out', required=True)
    args = ap.parse_args()
    source, original, toolchain = (Path(s).resolve() for s in (args.source, args.core, args.toolchain))
    out = Path(args.out).resolve(); out.mkdir(parents=True, exist_ok=False)
    cases = [json.loads(line) for line in Path(args.cases).read_bytes().splitlines()]
    named = {r['id']: r for r in cases}
    results = []
    for mode in ('preflight-env', 'preflight-loss', 'removed-consumer', 'synthetic-readings'):
        dest = out / mode; dest.mkdir()
        tree = dest / 'tree'; tree.mkdir()
        with tarfile.open(source) as archive:
            # Trusted source is a locally prepared git archive, never user input.
            archive.extractall(tree)
        probe = tree / 'scripts/measure/core-pre-claude-probe.py'
        install = tree / 'rust/src/pre/install.rs'
        mutations = []
        if mode == 'preflight-env':
            mutations.append(replace_once(probe,
                'run(argv, b\'\', env, box / \'project\', dest)',
                'run(argv, b\'\', {**env, \'X\': \'unexpected\'}, box / \'project\', dest)'))
            selected = [named['direct-npm']]
        elif mode == 'preflight-loss':
            mutations.append(replace_once(probe, '    target.stub(box)\n',
                "    target.stub(box)\n    stub = box / 'bin/npm'\n"
                "    text = stub.read_text()\n    assert text.count('.write_bytes(raw)') == 1\n"
                "    stub.write_text(text.replace('.write_bytes(raw)', '.name'))\n"))
            selected = [named['direct-npm']]
        elif mode == 'removed-consumer':
            mutations.append(replace_once(install,
                'if let Some(kind)=rewrites.iter().find_map(|value|crate::inert::collision_kind(value)) {',
                'if let Some(kind)=std::iter::empty::<&[u8]>().next() {'))
            selected = [named['floor-echo']]
        else:
            mutations.append(replace_once(install,
                'for &reading in &read.set {',
                'for &reading in &[Reading::Bash,Reading::Zsh,Reading::Dash] {'))
            mutations.append(replace_once(install,
                'if !codex{rewrites.push(inert(run,&call.command))}',
                'if !codex{rewrites.push(if call.command==b"npm install x" || reading==Reading::Zsh { b"collision floor-outside-command".to_vec() } else { b"none".to_vec() })}'))
            selected = [dict(id='same-collision', command='npm install x', expect='collision', kind='floor-outside-command'),
                        dict(id='mixed-collision', command='npm install y', expect='collision', kind='floor-outside-command')]
        write_json(dest / 'mutations.json', mutations)
        fixture = dest / 'cases.jsonl'
        fixture.write_text(''.join(json.dumps(r) + '\n' for r in selected))
        write_json(dest / 'declaration.json', dict(mode=mode, public_entry=True,
            producer='synthetic values, not B classification' if mode == 'synthetic-readings' else 'fixed B runtime',
            source_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),
            original_binary_sha256=hashlib.sha256(original.read_bytes()).hexdigest(),
            cases_sha256=hashlib.sha256(fixture.read_bytes()).hexdigest(),
            rust={str(p.relative_to(tree)): hashlib.sha256(p.read_bytes()).hexdigest()
                  for p in sorted((tree / 'rust').rglob('*')) if p.is_file()}))
        env = dict(os.environ, RUSTC=str(toolchain / 'bin/rustc'),
                   CARGO_HOME=str(dest / 'cargo-home'), CARGO_TARGET_DIR=str(tree / 'rust/target'))
        core = original
        if mode in ('removed-consumer', 'synthetic-readings'):
            build = invoke([str(toolchain / 'bin/cargo'), 'build', '--release', '--locked', '--offline', '-j1'], tree / 'rust', env, dest / 'build')
            if build:
                results.append(dict(mode=mode, error='build', rc=build)); continue
            core = tree / 'rust/target/release/safedeps-core'
        stamp = invoke([str(core), 'stamp', '--check'], tree, env, dest / 'stamp')
        if stamp:
            results.append(dict(mode=mode, error='stamp', rc=stamp)); continue
        (dest / 'binary.sha256').write_text(hashlib.sha256(core.read_bytes()).hexdigest() + '\n')
        rc = invoke(['python3', '-B', '-I', str(probe), '--core', str(core), '--cases', str(fixture), '--bundles', str(dest / 'bundles')], tree, env, dest / 'probe')
        report = json.loads((dest / 'bundles/result.json').read_bytes())
        if mode.startswith('preflight-'):
            row = report['rows'][0]
            ok = (rc == 2 and report['counts']['collection-error'] == 1
                  and row['error'] == "ValueError('npm stub preflight did not match fixed argv/output/one record')"
                  and not list((dest / 'bundles').glob('*/hook/process.json')))
        elif mode == 'removed-consumer':
            row = report['rows'][0]
            ok = (rc == 1 and row['error'] is None
                  and {'collision-deny', 'no-own-pending-or-trace', 'one-collision-advisory'} <= set(row['failures']))
        else:
            ok = rc == 0 and report['counts'] == {'contract-pass': 2, 'unresolved': 0, 'fail': 0, 'collection-error': 0}
        results.append(dict(mode=mode, expected_observation=ok, rc=rc, report=report))
        write_json(out / 'result.json', results)
        print(mode + ': ' + ('expected' if ok else 'FAIL') + ' rc=' + str(rc), flush=True)
    write_json(out / 'result.json', results)
    return int(any(not r.get('expected_observation') for r in results))


if __name__ == '__main__':
    raise SystemExit(main())
