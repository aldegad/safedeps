#!/usr/bin/env python3
"""Exercise source ownership on copied checkout and publish binaries.

Both binaries must be built from --source/rust. No package manager or payload
command runs. --expect-difference is for a binary from before the correction;
it does not change any expected result. Every observation is emitted as JSONL.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--checkout', required=True)
    parser.add_argument('--publish', required=True)
    parser.add_argument('--source', required=True)
    parser.add_argument('--expect-difference', action='store_true')
    parser.add_argument('--only', help='one exact case name, for the source-check removal control')
    args = parser.parse_args()
    source = Path(args.source).resolve() / 'rust'
    binaries = {kind: Path(getattr(args, kind)).resolve() for kind in ('checkout', 'publish')}
    rows = []

    def observe(name, binary, expected, *, env=None, argv=('stamp', '--check')):
        if args.only and name != args.only:
            return
        result = subprocess.run([str(binary), *argv], capture_output=True, env=env, timeout=10)
        ok = result.returncode == expected and (expected != 0 or result.stdout == b'ok\n')
        row = dict(case=name, expected_rc=expected, rc=result.returncode, same=ok,
                   stdout=result.stdout.decode(errors='replace'), stderr=result.stderr.decode(errors='replace'))
        rows.append(row)
        print(json.dumps(row, ensure_ascii=True), flush=True)

    def copy_source(root):
        shutil.copytree(source, root / 'rust', ignore=shutil.ignore_patterns('target'))

    def place(root, kind, relative='bin/native/probe/safedeps-core'):
        binary = root / relative
        binary.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(binaries[kind], binary)
        return binary

    def no_source(root):
        pass

    def same_source(root):
        copy_source(root)

    def changed_source(root):
        copy_source(root)
        with (root / 'rust/src/stamp.rs').open('ab') as stream:
            stream.write(b'\n// stamp probe source change\n')

    def missing_manifest(root):
        copy_source(root)
        (root / 'rust/Cargo.toml').unlink()

    def dangling_source(root):
        (root / 'rust').symlink_to(root / 'absent-source', target_is_directory=True)

    def source_file(root):
        (root / 'rust').write_bytes(b'not a directory\n')

    def unreadable_file(root):
        copy_source(root)
        (root / 'rust/Cargo.toml').chmod(0)

    with tempfile.TemporaryDirectory(prefix='core-stamp.') as tmp:
        box = Path(tmp)
        shapes = [('absent', no_source), ('same', same_source), ('changed', changed_source),
                  ('missing-manifest', missing_manifest), ('dangling', dangling_source),
                  ('source-file', source_file), ('unreadable', unreadable_file)]
        for kind in binaries:
            for shape, setup in shapes:
                root = box / kind / shape
                binary = place(root, kind)
                setup(root)
                expected = 0 if shape == 'same' or (kind == 'publish' and shape == 'absent') else 1
                if shape == 'unreadable':
                    # Refuse to report a permissions test if the account can
                    # still read the file (for example a root test process).
                    try:
                        (root / 'rust/Cargo.toml').read_bytes()
                    except PermissionError:
                        pass
                    else:
                        raise RuntimeError('unreadable fixture is readable by this account')
                observe(f'{kind}/{shape}', binary, expected)
                if shape == 'unreadable':
                    (root / 'rust/Cargo.toml').chmod(0o600)

            # The ancestor really has matching source. It must not rescue a
            # checkout binary whose own source is gone, or choose a publish
            # package's source for it.
            outer = box / kind / 'ancestor'
            outer.mkdir(parents=True)
            copy_source(outer)
            binary = place(outer / 'package', kind)
            observe(f'{kind}/unrelated-ancestor-same', binary, 0 if kind == 'publish' else 1)
            with (outer / 'rust/src/stamp.rs').open('ab') as stream:
                stream.write(b'\n// unrelated ancestor change\n')
            observe(f'{kind}/unrelated-ancestor-changed', binary, 0 if kind == 'publish' else 1)

            # An executable symlink belongs to its resolved binary's package,
            # not the directory holding the link.
            linked = box / kind / 'linked'
            binary = place(linked, kind)
            copy_source(linked)
            link = box / kind / 'entry-link'
            link.symlink_to(binary)
            observe(f'{kind}/entry-symlink', link, 0)
            with (linked / 'rust/src/stamp.rs').open('ab') as stream:
                stream.write(b'\n// target package changed\n')
            observe(f'{kind}/entry-symlink-changed', link, 1)

            # Atomic installation checks a temporary filename in the final
            # native directory before rename. Ownership does not use basename.
            root = box / kind / 'staged'
            staged = place(root, kind, 'bin/native/probe/.safedeps-core.staged')
            copy_source(root)
            observe(f'{kind}/staged-same', staged, 0)

            for target in ('', 'synthetic-target/'):
                root = box / kind / ('cargo-cross' if target else 'cargo-host')
                root.mkdir(parents=True)
                copy_source(root)
                binary = place(root, kind, f'rust/target/{target}release/safedeps-core')
                observe(f'{kind}/cargo-{target or "host"}', binary, 0)

            # Runtime stamp variables cannot turn a checkout into publish or
            # erase a publish build's duty to compare source which is present.
            root = box / kind / 'environment'
            binary = place(root, kind)
            changed_source(root)
            env = dict(os.environ, SAFEDEPS_CORE_BUILD_KIND='publish', SAFEDEPS_CORE_STAMP_KIND='publish',
                       SAFEDEPS_CORE_STAMP_SHA256='not-a-digest')
            observe(f'{kind}/runtime-environment', binary, 1, env=env)

            # Outside the distribution layout, missing source is not a
            # source-free package, even for a publish build.
            loose = place(box / kind / 'loose', kind, 'safedeps-core')
            observe(f'{kind}/loose-without-source', loose, 1)

    if not rows:
        raise RuntimeError('no case matched --only')
    bad = sum(not row['same'] for row in rows)
    print(json.dumps(dict(summary='core-stamp-probe', checks=len(rows), differ=bad)), flush=True)
    return 0 if (bad > 0 if args.expect_difference else bad == 0) else 1


if __name__ == '__main__':
    raise SystemExit(main())
