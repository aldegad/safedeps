#!/usr/bin/env python3
"""Narrow offline watch owner contracts. Real scan/producer, merge and CLI.

Providers are shell functions returning fixtures; curl is a tripwire. Times
are controlled inputs, never sleeps used as evidence of measurement order.
Optional --routine checks the executable blocks of the external Procedure.
"""
import argparse
import contextlib
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import sys
import time

p = argparse.ArgumentParser()
p.add_argument('repo', nargs='?', default=str(Path(__file__).resolve().parents[2]))
p.add_argument('--routine')
p.add_argument('--only', default='kev,order,deploy,pin')
a = p.parse_args()
repo = Path(a.repo).resolve()
# Reuse kernel identity and conservative reaping; this namespace belongs only
# to this fixture, so its sweep cannot affect another battery's children.
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent / 'lib'))
import native_budget_owners as owners
owners.MARKERS = Path('/tmp') / ('sdepsWatchOwnerLease-' + str(os.getuid()))
for receipt in owners.sweep():
    if receipt['survivors'] or receipt['unknown']:
        raise RuntimeError('watch owner fixture sweep: ' + str(receipt))
results = []
T0, T1 = '2026-11-18T00:00:00Z', '2026-11-18T00:00:01Z'


def check(name, truth, detail=''):
    results.append(bool(truth))
    print(('ok ' if truth else 'not ok ') + name + (': ' + str(detail) if not truth else ''), flush=True)


def run(cmd, env, cwd, data=None):
    return subprocess.run(cmd, input=data, text=True, capture_output=True,
                          env=env, cwd=cwd, timeout=30)


DRIVER = r'''
set -euo pipefail
SAFEDEPS_REPO_DIR="$1"
SAFEDEPS_VERSION=$(jq -r .version "$1/package.json")
source "$1/lib/providers/providers.sh"
source "$1/lib/ledger/ledger.sh"
source "$1/lib/npm/closure.sh"
for mod in lock mounts population lockfiles runtime scan; do source "$1/lib/watch/$mod.sh"; done
safedeps_watch_host_jdks() { :; }
safedeps_watch_runtime_info() { printf '%s\n' '{"version":"fixture","stale":false}'; }
safedeps_osv_query_batch() {
  if [[ "$WATCH_TEST_MODE" == unmeasured ]]; then return 1; fi
  jq -c 'map(. + {osv:{vulns:(if .version == "1.0.0" then [{id:"GHSA-owner",modified:"2026-11-18T00:00:00Z"}] else [] end)}})' "$2"
}
safedeps_osv_vuln_detail() {
  printf '%s\n' '{"id":"GHSA-owner","aliases":["CVE-2026-999999"],"affected":[]}'
}
safedeps_kev_refresh_catalog() {
  [[ "$WATCH_TEST_MODE" != unavailable ]] || return 1
  local id=CVE-2026-888888
  [[ "$WATCH_TEST_MODE" != listed ]] || id=CVE-2026-999999
  printf '{"vulnerabilities":[{"cveID":"%s"}]}\n' "$id" > "$1"
}
safedeps_watch_pause before_lock
safedeps_watch_lock_acquire
safedeps_watch_scan "$2" "${3:-}"
'''


class World:
    def __init__(self, base):
        self.base = Path(base)
        self.home = self.base / 'home'
        self.watch = self.home / 'watch'
        self.watch.mkdir(parents=True)
        self.root = self.base / 'project'
        self.other = self.base / 'other'
        self.root.mkdir(); self.other.mkdir()
        self.lock('1.0.0')
        self.bin = self.base / 'bin'; self.bin.mkdir()
        pop = self.bin / 'population'
        pop.write_text('#!/bin/sh\nprintf "project\\t%s\\nother\\t%s\\n" "$WATCH_TEST_ROOT" "$WATCH_TEST_OTHER"\n')
        pop.chmod(0o755)
        (self.watch / 'config.json').write_text(json.dumps({'population_command':[str(pop)]}))
        date = self.bin / 'date'
        date.write_text('''#!/bin/bash
if [[ "$*" == '-u +%Y-%m-%dT%H:%M:%SZ' ]]; then
  if [[ -n "${WATCH_TEST_GATE:-}" && ! -e "$WATCH_TEST_GATE.entered" ]]; then
    touch "$WATCH_TEST_GATE.entered"
    for ((n=0;n<200;n++)); do
      [[ ! -e "$WATCH_TEST_GATE" ]] && break
      sleep 0.05
    done
    [[ ! -e "$WATCH_TEST_GATE" ]] || exit 9
  fi
  printf '%s\\n' "$WATCH_TEST_TIME"
else
  exec /bin/date "$@"
fi
'''); date.chmod(0o755)
        curl = self.bin / 'curl'
        curl.write_text('#!/bin/sh\ntouch "$HOME/network-attempt"\nexit 98\n'); curl.chmod(0o755)
        self.env = dict(PATH=str(self.bin) + ':' + os.environ['PATH'], HOME=str(self.home),
                        SAFEDEPS_HOME=str(self.home), TMPDIR=str(self.base),
                        SAFEDEPS_PROVIDER_CACHE_TTL_SECONDS='-1', SAFEDEPS_NOTIFY='0',
                        WATCH_TEST_ROOT=str(self.root), WATCH_TEST_OTHER=str(self.other),
                        WATCH_TEST_TIME=T0, WATCH_TEST_MODE='healthy')
        self.file = self.watch / 'state.json'
        self.driver = self.base / 'scan.sh'; self.driver.write_text(DRIVER)

    def lock(self, version):
        (self.root / 'package-lock.json').write_text(json.dumps({'lockfileVersion':3,'packages':{
            '':{'name':'fixture'},'node_modules/dep':{'version':version}}}))

    def call(self, *args, env=None):
        return run([str(repo / 'bin/safedeps'), '--json', 'watch', *args], env or self.env, self.base)

    def doc(self):
        return json.loads(self.file.read_text())

    def status(self):
        r = self.call('status')
        assert r.returncode == 0, r.stderr
        return json.loads(r.stdout)

    def scan(self, mode='healthy', kind='root', root=None, at=T0):
        r = run(self.scan_cmd(kind, root), dict(self.env, WATCH_TEST_MODE=mode, WATCH_TEST_TIME=at), self.base)
        assert r.returncode in (0, 1), r.stdout + r.stderr
        assert not (self.home / 'network-attempt').exists(), 'network attempted'
        return r

    def scan_cmd(self, kind, root=None):
        return ['bash', str(self.driver), str(repo), kind, str(root or self.root) if kind == 'root' else '']

    def key(self):
        return next(iter(self.doc()['findings']))

    def why(self):
        return [r['why'] for r in self.status()['awaiting_owner'] if r['key'] == self.key()]

    def fact(self):
        r = run(['jq','-c','-L',str(repo/'lib/watch'),'include "state"; .findings[] | report_fact'],
                self.env, self.base, self.file.read_text())
        assert r.returncode == 0, r.stderr
        return json.loads(r.stdout)

    def record(self, state='fixed_pending_rescan', expect=None, **kw):
        args = ['remediation','--finding',self.key(),'--state',state,'--detail','owner next action: inspect plan fixture']
        if expect is not None: args += ['--expect',json.dumps(expect)]
        return self.call(*args, **kw)

    def refuse(self, fact):
        old = self.file.read_bytes()
        r = self.record('report_acknowledged', fact)
        return r.returncode != 0 and self.file.read_bytes() == old


@contextlib.contextmanager
def world():
    with tempfile.TemporaryDirectory(prefix='safedeps-owner-') as d:
        w = World(d)
        yield w
        assert not (w.home / 'network-attempt').exists(), 'network attempted'


@contextlib.contextmanager
def child(cmd, w, env):
    lease = owners.create(os.getpid())
    proc = subprocess.Popen(cmd, env=env, cwd=w.base, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, start_new_session=True)
    try:
        owners.register(lease, proc.pid, "watch-owner-child")
        yield proc
    finally:
        if proc.poll() is None:
            os.killpg(proc.pid, signal.SIGKILL)
        proc.communicate(timeout=5)
        receipt = owners.cleanup(lease)
        assert not receipt["survivors"] and not receipt["unknown"], receipt


def entered(marker):
    until = time.monotonic() + 10
    while not marker.exists() and time.monotonic() < until:
        time.sleep(.02)
    assert marker.exists(), 'pause never entered'


def kev():
    with world() as w:
        w.scan(kind='full')
        healthy = w.fact(); full = w.doc()['last_full_scan']
        healthy_record = w.record('report_acknowledged', healthy)
        check('K0 false preserved and judged', healthy['kev'] is False and healthy_record.returncode == 0)
        w.scan('unavailable')
        check('K1 root outage refuses healthy expect and awaits', w.refuse(healthy) and w.why() == ['acknowledged_other_state'])
        check('K2 error and full receipt retained', w.doc()['errors'] == [{'kind':'kev_unavailable','provider':'kev'}]
              and w.doc()['last_full_scan'] == full)
        failure = w.fact()
        check('K3 outage judgment accepted on null', failure['kev'] is None and w.record('report_acknowledged', failure).returncode == 0)
        w.scan(kind='full')
        check('K4 recovery refuses outage expect and awaits', w.refuse(failure) and w.why() == ['acknowledged_other_state'])
        current = w.fact()
        w.scan('listed')
        check('K5 true listing refuses false expect', w.refuse(current) and w.fact()['kev'] is True)
        listed = w.fact()
        check('K6 listed judgment accepted', w.record('report_acknowledged', listed).returncode == 0)
        w.scan('listed', at=T1)
        # Another root changes the global scan generation; this report stays put.
        (w.other / 'package-lock.json').write_text((w.root / 'package-lock.json').read_text())
        w.scan(root=w.other, at=T1)
        reversed_fact = dict(reversed(list(listed.items())))
        check('K7 key order time and unrelated scan do not invalidate', w.record('report_acknowledged', reversed_fact).returncode == 0 and not w.why() and len(w.doc()['findings']) == 2)


def order():
    with world() as w:
        w.scan()
        assert w.record().returncode == 0
        check('O0 no subsequent scan stays pending', w.why() == [])
        w.scan()
        f = w.doc()['findings'][w.key()]
        check('O1 same-second actual scan returns to owner', f['last_seen'] == f['remediation']['at'] and w.why() == ['rescan_still_live'])
        assert w.record().returncode == 0
        w.scan(root=w.other, at=T1)
        check('O2 unrelated root does not contradict', w.why() == [])
        w.scan('unmeasured', at=T1)
        check('O3 unmeasured root does not contradict', w.why() == [] and w.doc()['findings'][w.key()]['stale_measurement'])
        w.scan(at=T1)
        check('O4 measured root does contradict', w.why() == ['rescan_still_live'])
        assert w.record().returncode == 0
        w.lock('1.0.1'); w.scan()
        check('O5 absence closes with existing reason', w.doc()['findings'][w.key()]['closed_reason'] == 'seen_fixed' and not w.why())
    with world() as w:
        w.scan()
        gate = w.base / 'record-gate'; gate.touch()
        cmd = [str(repo/'bin/safedeps'),'--json','watch','remediation','--finding',w.key(),'--state','fixed_pending_rescan']
        with child(cmd, w, dict(w.env, WATCH_TEST_GATE=str(gate))) as proc:
            entered(Path(str(gate) + '.entered'))
            # The CLI has started its pre-lock clock read, but has not locked.
            w.scan(at=T1)
            scan_gen = w.doc()['scan_generation']
            gate.unlink(); out, err = proc.communicate(timeout=15)
            assert proc.returncode == 0, out + err
        print('# O6 observed pre-lock remediation call; scan published before record; scan_generation=' + str(scan_gen))
        check('O6 intervening scan before record does not contradict', w.why() == [])
        w.scan(at=T0)
        check('O7 subsequent measurement despite older clock contradicts', w.why() == ['rescan_still_live'])
    with world() as w:
        w.scan()
        pause = w.base / 'scan-pause'
        with child(w.scan_cmd('root'), w, dict(w.env, SAFEDEPS_WATCH_PAUSE_AT='before_lock', SAFEDEPS_WATCH_PAUSE_FILE=str(pause))) as proc:
            entered(pause)
            assert w.record().returncode == 0
            before = w.doc()['scan_generation']
            pause.unlink(); out, err = proc.communicate(timeout=20)
            assert proc.returncode == 0, out + err
        check('O8 scan started before record but measured after lock contradicts', w.doc()['scan_generation'] == before + 1 and w.why() == ['rescan_still_live'])
    with world() as w:
        w.scan(); assert w.record().returncode == 0
        doc = w.doc(); doc['findings'][w.key()]['remediation'].pop('scan_generation', None)
        w.file.write_text(json.dumps(doc))
        check('O9 legacy order is explicitly unknown', w.why() == ['rescan_order_unknown'])


def deploy():
    with world() as w:
        w.scan()
        r = w.call('remediation','--finding',w.key(),'--state','awaiting_deploy','--task','fixture-task',
                   '--detail','plan fixture/repair; deploy owner not assigned; next action: assign authorized owner')
        assert r.returncode == 0
        rows = w.status()['awaiting_owner']
        check('D0 deployment reaches owner with task and next action', len(rows) == 1 and rows[0]['why'] == 'awaiting_deploy'
              and rows[0]['remediation']['task'] == 'fixture-task' and 'not assigned' in rows[0]['remediation']['detail'])
        events = w.doc()['events']
        w.scan()
        check('D1 still vulnerable deploy stays nonfailure without new event', w.why() == ['awaiting_deploy']
              and w.doc()['findings'][w.key()]['remediation']['state'] == 'awaiting_deploy' and w.doc()['events'] == events)
        assert w.call('remediation','--finding',w.key(),'--state','awaiting_deploy').returncode == 0
        rows = w.status()['awaiting_owner']
        check('D2 missing authority is exposed without invented assignment', len(rows) == 1 and rows[0]['remediation']['task'] is None and rows[0]['remediation']['detail'] == '')
        assert w.record('dispatched').returncode == 0
        check('D3 ordinary dispatched work stays in progress', w.why() == [])
        assert w.record('fix_failed').returncode == 0
        check('D4 failed repair still reaches owner', w.why() == ['fix_failed'])


def block(text, marker):
    return text.split('<!-- '+marker+' -->',1)[1].split('```bash',1)[1].split('```',1)[0]


def pin():
    if not a.routine:
        return
    text = Path(a.routine).read_text()
    with world() as w:
        w.scan()
        status = json.dumps(w.status())
        state = w.file.read_text()
        checks = block(text, 'status-check')
        pin_code = block(text, 'state-pin')
        # Fake readers return exact supplied bytes and exits. The executable
        # Procedure block owns retry limits and decides what may be consumed.
        cases = [
            ('P0 same generation', state, 0, 0, True, ''),
            ('P1 valid JSON plus read failure', state, 7, 0, False, 'state_read_failed'),
            ('P2 invalid JSON', '{', 0, 0, False, 'state_json_invalid'),
            ('P3 invalid structure', '{"generation":1}', 0, 0, False, 'state_structure_invalid'),
            ('P4 changed generation', json.dumps(dict(w.doc(),generation=999)), 0, 0, False, 'generation_changed'),
            ('P5 retry read succeeds', state, 7, 0, True, ''),
            ('P6 retry status exit failure', state, 7, 8, False, 'status_read_failed'),
            ('P8 retry advances both generations', json.dumps(dict(w.doc(),generation=999)), 0, 0, True, ''),
            ('P9 retry cannot mix new status with old state', state, 7, 0, False, 'generation_changed'),
        ]
        for name, payload, rc, src, expected, why in cases:
            (w.base/'state-bytes').write_text(payload)
            (w.base/'status-bytes').write_text(status)
            retry_status = dict(json.loads(status), generation=999) if name.startswith(('P8', 'P9')) else json.loads(status)
            (w.base/'retry-status-bytes').write_text(json.dumps(retry_status))
            (w.base/'reads').write_text('0')
            fake = w.base/'status-command'
            fake.write_text('#!/bin/bash\n/bin/cat "$TEST_BASE/retry-status-bytes"\nexit "$TEST_STATUS_RC"\n'); fake.chmod(0o755)
            script = r'''
cat() {
  local n
  n=$(/bin/cat "$TEST_BASE/reads"); n=$((n+1)); printf '%s' "$n" > "$TEST_BASE/reads"
  /bin/cat "$TEST_BASE/state-bytes"
  if [[ "$TEST_RECOVER" == 1 && "$n" -gt 1 ]]; then return 0; fi
  return "$TEST_READ_RC"
}
status_json=$(/bin/cat "$TEST_BASE/status-bytes")
status_exit=0
S="$TEST_BASE/status-command"
''' + checks + '\n' + pin_code + r'''
printf '\nRESULT=%s|%s|%s|%s\n' "${state_ready:-false}" "${state_failure:-}" "${state_json:+present}" "$(/bin/cat "$TEST_BASE/reads")"
'''
            env = dict(w.env, TEST_BASE=str(w.base),TEST_READ_RC=str(rc),TEST_STATUS_RC=str(src),TEST_RECOVER='1' if name.startswith(('P5', 'P9')) else '0')
            r = run(['bash'],env,w.base,script)
            line = next((l for l in r.stdout.splitlines() if l.startswith('RESULT=')), '')
            parts = line[len('RESULT='):].split('|')
            ok = r.returncode == 0 and len(parts) == 4 and parts[0] == str(expected).lower() and parts[1] == why and parts[2] == ('present' if expected else '') and int(parts[3]) == (1 if name.startswith(('P0', 'P6')) else 2)
            check(name, ok, r.stdout + r.stderr)
        check('P7 deployment carried by main fire and missing owner explicit',
              '배포 대기' in text and 'remediation.task' in text and '담당 미확정' in text
              and '배포 대기가 하나라도' in text)


for group in a.only.split(','):
    globals()[group]()
print(f'# {len(results)} rows, {results.count(False)} not ok')
raise SystemExit(0 if all(results) else 1)
