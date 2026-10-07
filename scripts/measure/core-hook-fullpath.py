#!/usr/bin/env python3
"""Replay the two historical false-equality defects on private source copies.

Old comparator files are explicit inputs pinned by the caller's source
manifest. They are controls only, never a fallback in the shipping CLI.
"""

if __name__ == "__main__":
    import sys
    sys.stderr.write('retired: Bash source comparator mutations are retired with the channel comparison. See native-measure-disposition.json.\n')
    raise SystemExit(2)

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--old-seeded-harness', required=True)
    ap.add_argument('--old-unknown-harness', required=True)
    ap.add_argument('--out', required=True)
    args = ap.parse_args()
    source = Path(__file__).resolve().parents[2]
    out = Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=False)
    copies = out / 'copies'
    copies.mkdir()
    rows = []
    def tree(name, old=None, stderr=None, journal=None):
        dst = copies / name
        dst.mkdir()
        for d in ('scripts', 'lib', 'bin'):
            shutil.copytree(source/d, dst/d, ignore=shutil.ignore_patterns('native', '__pycache__'))
        if old:
            shutil.copyfile(old, dst/'scripts/measure/core-hook-differential.py')
        if stderr is not None:
            p = dst/'scripts/safedeps-post-verify.sh'
            text = p.read_text()
            p.write_text(text.replace('\n', "\nprintf '%s\\n' 'safedeps-lex."+stderr+"' >&2\n", 1))
        if journal:
            p = dst/'lib/gates/rollback-journal.sh'
            text = p.read_text()
            oldline = 'journal_line="Journal: ${journal_id}, opened ${opened_at}; last recorded stage ${stage}${stage_detail}"'
            if text.count(oldline) != 1:
                raise RuntimeError('journal mutation source drift')
            replacement = oldline.replace('${opened_at}', '${stage_at:-${opened_at}}', 1) if journal == 'iso' else oldline.replace('opened ', 'opened at ', 1)
            p.write_text(text.replace(oldline, replacement))
        return dst
    def run(name, ref, cand, expected_rc, channel, historical=False):
        report = out/(name+'.json')
        argv = [sys.executable, str(ref/'scripts/measure/core-hook-differential.py'), '--only', 'post-journal-unfinished',
                '--cand-root', str(cand), '--jobs', '1', '--report', str(report)]
        if not historical:
            argv += ['--bundles', str(out/(name+'-bundles'))]
        with (out/(name+'.log')).open('wb') as log:
            rc = subprocess.run(argv, stdout=log, stderr=subprocess.STDOUT).returncode
        doc = json.loads(report.read_text()) if report.exists() else {}
        found = doc.get('cases', [{}])[0]
        channels = found.get('red_channels', [])
        ok = rc == expected_rc and (historical or (found.get('verdict') == 'different' and channel in channels))
        rows.append({'name': name, 'expected_rc': expected_rc, 'rc': rc, 'channels': channels,
                     'ok': ok, 'historical_comparator': historical, 'argv': argv})
        print(('ok' if ok else 'not ok')+' - '+name, flush=True)
    normal = tree('normal')
    journal = tree('journal', journal='iso')
    wording = tree('wording', journal='word')
    left = tree('unknown-left', stderr='AAAAAA')
    right = tree('unknown-right', stderr='BBBBBB')
    control = tree('unknown-word', stderr='BBBBBB!DIFFERENT')
    old_journal = tree('old-journal', old=args.old_seeded_harness)
    old_unknown = tree('old-unknown', old=args.old_unknown_harness, stderr='AAAAAA')
    run('new-journal', normal, journal, 1, 'stdout')
    run('old-journal-misses', old_journal, journal, 0, None, True)
    run('old-journal-word-control', old_journal, wording, 1, None, True)
    run('new-unknown', left, right, 1, 'stderr')
    run('old-unknown-misses', old_unknown, right, 0, None, True)
    run('old-unknown-word-control', old_unknown, control, 1, None, True)
    (out/'result.json').write_text(json.dumps({'rows': rows, 'old_sha256': {
        p: hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in (args.old_seeded_harness,args.old_unknown_harness)}},indent=2)+'\n')
    return 0 if all(row['ok'] for row in rows) else 1


if __name__ == '__main__':
    sys.exit(main())
