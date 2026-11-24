// The store is never seeded by a row: only real check and migrate write it.
// Provider answers and the npm closure are the existing e2e fixtures. Each
// row has its own temporary home, and every CLI runs outside the checkout.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { Worker } from 'node:worker_threads';
import { gzipSync, gunzipSync } from 'node:zlib';

const root = path.resolve(process.argv[2]);
const cli = path.join(root, 'bin/safedeps');
const base = fs.mkdtempSync(path.join(os.tmpdir(), 'safedeps-approvals-provenance.'));
const portFile = path.join(base, 'port');
const stateFile = path.join(base, 'state.json');
const closureFile = path.join(base, 'closure.json');
fs.writeFileSync(stateFile, '{"vulnerable":[]}\n');
fs.writeFileSync(closureFile, JSON.stringify({
  'fixture-clean@1.0.0': [{ package: 'fixture-clean', version: '1.0.0', direct: true }],
}));

// A thread, not an independent server process: even SIGKILL of this suite
// takes the provider with it. Finally terminates it on ordinary exits. No
// row suspends a process, and there is no orphan server for a sweep to reap.
const provider = new Worker(path.join(root, 'scripts/test/fixture-provider.mjs'), {
  argv: [portFile, stateFile],
});
let providerError;
provider.on('error', (error) => { providerError = error; });
provider.on('exit', (code) => { providerError ??= new Error(`provider exited ${code}`); });

const inherited = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith('SAFEDEPS_')));
let env;
function home(name) {
  const dir = path.join(base, name);
  fs.mkdirSync(dir);
  return dir;
}
function run(dir, command, args, extra = {}) {
  const result = spawnSync(command, args, {
    cwd: base, env: { ...env, SAFEDEPS_HOME: dir, ...extra }, encoding: 'utf8',
  });
  assert.ifError(result.error);
  assert.equal(result.status, 0, `${path.basename(command)} ${args.join(' ')}: ${result.stderr}\n${result.stdout}`);
  return result.stdout;
}
function json(dir, ...args) {
  return JSON.parse(run(dir, cli, ['--json', ...args]));
}
function store(dir) { return fs.readFileSync(path.join(dir, 'approvals.jsonl')); }
function approve(dir) {
  const result = json(dir, 'check', 'npm', 'fixture-clean@1.0.0');
  assert.equal(result.result, 'clean', JSON.stringify(result));
  assert.equal(result.approved, true);
  return result.spec_hash;
}
function recheck(dir, label, forged = []) {
  const report = json(dir, 're-check');
  console.log(`# ${label}: ${JSON.stringify(report)}`);
  assert.deepEqual(report.errors, []);
  assert.deepEqual(report.revoked, []);
  assert.deepEqual(report.suspected_forgery.map(({ package: name, reason }) => [name, reason]), forged);
  assert.equal(report.approvals_store.broken, 0);
  assert.equal(report.approvals_store.unmatched, 0);
  return report;
}
function entry(dir, name) {
  // A deliberately direct ledger write, with an independently computed honest
  // hash. This is the forgery in row 3 and the old home in row 5, not approval.
  const hash = `sha256:${createHash('sha256').update(`npm\n${name}\n1.0.0`).digest('hex')}`;
  const ledger = path.join(dir, 'approved-specs');
  fs.mkdirSync(ledger, { recursive: true });
  fs.writeFileSync(path.join(ledger, `${hash.replace(':', '-')}.json`), JSON.stringify({
    hash, ecosystem: 'npm', package: name, version: '1.0.0', version_range: '1.0.0',
    approved_at: new Date().toISOString(), expires_at: new Date(Date.now() + 86400000).toISOString(),
    approved_by: 'safedeps check', evidence: { osv: [] },
  }) + '\n');
  return hash;
}
function approveLine(name, hash) {
  return `[2026-01-01T00:00:00Z] check approve(clean) ecosystem=npm package=${name} version=1.0.0 hash=${hash}\n`;
}

const rows = [
  ['a core rotation between approval and re-check moves the approve line into an archive, and provenance stands', (dir) => {
    const hash = approve(dir);
    const before = store(dir);
    const log = path.join(dir, 'advisory.log');
    const whole = fs.readFileSync(log);
    const inode = fs.statSync(log).ino;
    assert(whole.includes(`hash=${hash}`));
    // re-check's first log write starts the rotation: the CLI looks at the
    // size and runs the core's (lib/providers/providers.sh:
    // safedeps_providers_init -> safedeps_advisory_log_rotate_once ->
    // safedeps-core advisory-log rotate). The core renames the whole file, so
    // the approve line leaves the live file before re-check reads anything,
    // and no window rewrites it. re-check reads the approvals store, a file
    // no rotation touches.
    const during = JSON.parse(run(dir, cli, ['--json', 're-check'], { SAFEDEPS_ADVISORY_LOG_MAX_BYTES: '1' }));
    console.log(`# core rotation: ${JSON.stringify(during)}`);
    assert.deepEqual(during.errors, []);
    assert.deepEqual(during.suspected_forgery, []);
    assert.equal(during.checked, 1);
    // Each process looks once, and re-check runs two that look: the CLI's
    // call to the core, then the core's provider initialization. At a bound
    // of one byte the second finds the first one's new live file over it
    // too. So the row asks where the approve line went, not how many
    // rotations ran.
    const names = fs.readdirSync(dir);
    const archives = names.filter((name) => /^advisory\.log\.\d{8}T\d{6}Z(?:\.[1-9]\d*)?(?:\.gz)?$/.test(name));
    assert(archives.length >= 1, `the core did not rotate: ${names.join(' ')}`);
    assert(archives.every((name) => !name.endsWith('.gz')), `an archive was compressed inside the quiet window: ${names.join(' ')}`);
    const renamed = archives.filter((name) => fs.statSync(path.join(dir, name)).ino === inode);
    assert.equal(renamed.length, 1, `no archive is the live file, renamed: ${names.join(' ')}`);
    assert.deepEqual(fs.readFileSync(path.join(dir, renamed[0])), whole, 'the archive is not the whole live file');
    const text = (name) => fs.readFileSync(path.join(dir, name), 'utf8');
    const record = ['advisory.log', ...archives];
    assert.deepEqual(record.filter((name) => text(name).includes(`hash=${hash}`)), renamed,
      'the approve line is not in the renamed archive alone');
    const rotated = `advisory log rotated: ${whole.length} bytes moved to ${renamed[0]}`;
    assert(record.some((name) => text(name).includes(rotated)), `no line names the archive: ${rotated}`);
    const after = recheck(dir, 'after a core rotation');
    assert.equal(after.checked, 1);
    assert.deepEqual(store(dir), before);
  }],
  ['a synthetic overlap with a clipped live prefix does not lose real approval provenance', (dir) => {
    const hash = approve(dir);
    const before = store(dir);
    const log = path.join(dir, 'advisory.log');
    const whole = fs.readFileSync(log);
    assert(whole.includes(`hash=${hash}`));
    // Synthetic overlapping-rotation end state, not a measured race. Both
    // archives cover the approval; live starts inside a trace line and has no
    // approval line. All bytes and times here are synthetic.
    const trace = '[2026-01-01T00:00:01Z] INFO synthetic trace\n';
    fs.writeFileSync(`${log}.20260101T000002Z.gz`, gzipSync(whole));
    fs.writeFileSync(`${log}.20260101T000003Z.gz`, gzipSync(Buffer.concat([whole, Buffer.from(trace)])));
    const clipped = trace.slice(trace.indexOf('synthetic') + 3);
    fs.writeFileSync(log, clipped + '[2026-01-01T00:00:03Z] WARN advisory log rotated: synthetic overlap\n');
    const live = fs.readFileSync(log, 'utf8');
    assert(live.startsWith('thetic trace\n'));
    assert(!live.includes('check approve'));
    assert(!live.includes(hash));
    for (const archive of fs.readdirSync(dir).filter((name) => name.endsWith('.gz'))) {
      assert(gunzipSync(fs.readFileSync(path.join(dir, archive))).includes(`hash=${hash}`));
    }
    const report = recheck(dir, 'synthetic overlap');
    assert.equal(report.checked, 1);
    assert.deepEqual(store(dir), before);
  }],
  ['an honest-hash ledger forgery stays unvouched even after a handwritten approve log line', (dir) => {
    const name = 'fixture-forged';
    const hash = entry(dir, name);
    assert(!fs.existsSync(path.join(dir, 'approvals.jsonl')));
    recheck(dir, 'forgery without log', [[name, 'unvouched']]);
    fs.appendFileSync(path.join(dir, 'advisory.log'), approveLine(name, hash));
    recheck(dir, 'forgery with handwritten log', [[name, 'unvouched']]);
    assert(!fs.existsSync(path.join(dir, 'approvals.jsonl')));
  }],
  ['an ordinary approval rechecks quietly and the same spec is served from the approval cache', (dir) => {
    const hash = approve(dir);
    const before = store(dir);
    const report = recheck(dir, 'ordinary approval');
    assert.equal(report.checked, 1);
    assert.equal(report.approvals_store.present, true);
    const cached = json(dir, 'check', 'npm', 'fixture-clean@1.0.0');
    assert.equal(cached.result, 'already_approved', JSON.stringify(cached));
    assert.equal(cached.approved, true);
    assert.equal(cached.spec_hash, hash);
    assert.deepEqual(store(dir), before);
    console.log(`# ordinary approval: cache=${cached.result}`);
  }],
  ['migration of a synthetic old home confirms live and archived approvals but not an entry with no approve line', (dir) => {
    const a = entry(dir, 'fixture-live');
    const b = entry(dir, 'fixture-archived');
    entry(dir, 'fixture-no-line');
    const missing = `sha256:${'a'.repeat(64)}`;
    // No store. A is live and duplicated in the archive; B is archive-only.
    // The missing entry gives a nonzero unconfirmed count, while no-line has
    // an entry but no approve line in either input and cannot be migrated.
    fs.writeFileSync(path.join(dir, 'advisory.log'), approveLine('fixture-live', a));
    const archive = path.join(dir, 'advisory.log.20260101T000001Z.gz');
    fs.writeFileSync(archive, gzipSync(approveLine('fixture-live', a)
      + approveLine('fixture-archived', b) + approveLine('fixture-missing', missing)));
    assert(!fs.existsSync(path.join(dir, 'approvals.jsonl')));
    const counts = ['approve_lines', 'inserted', 'not_inserted', 'duplicates', 'unconfirmed', 'taken_back'];
    for (const [turn, expected] of [[1, [4, 2, 0, 1, 1, 0]], [2, [4, 0, 0, 3, 1, 0]]]) {
      const before = turn === 2 ? store(dir) : null;
      const moved = json(dir, 'approvals', 'migrate', archive);
      console.log(`# migration ${turn}: ${JSON.stringify(moved)}`);
      assert.deepEqual(counts.map((key) => moved[key]), expected);
      assert.equal(counts.slice(1).reduce((sum, key) => sum + moved[key], 0), moved.approve_lines);
      assert.deepEqual(moved.unconfirmed_hashes, [{ hash: missing, reason: 'no_entry' }]);
      if (before) assert.deepEqual(store(dir), before);
      const report = recheck(dir, `migrated ${turn}`, [['fixture-no-line', 'unvouched']]);
      assert.equal(report.checked, 3);
      assert.equal(report.suspected_forgery.filter((item) => item.hash === a || item.hash === b).length, 0);
    }
  }],
];

let failed = false;
try {
  for (let n = 0; !fs.existsSync(portFile); n++) {
    if (providerError) throw providerError;
    assert(n < 100, 'fixture provider did not publish its port');
    await delay(50);
  }
  const url = `http://127.0.0.1:${fs.readFileSync(portFile, 'utf8')}`;
  env = {
    ...inherited,
    SAFEDEPS_OSV_API_URL: `${url}/osv/v1/query`, SAFEDEPS_OSV_BATCH_API_URL: `${url}/osv/v1/querybatch`,
    SAFEDEPS_KEV_CATALOG_URL: `${url}/kev.json`, SAFEDEPS_GHSA_API_URL: `${url}/advisories`,
    SAFEDEPS_PROVIDER_CACHE_TTL_SECONDS: '0', SAFEDEPS_NPM_CLOSURE_FIXTURE_JSON: closureFile,
  };
  for (const [index, [name, row]] of rows.entries()) {
    try {
      if (providerError) throw providerError;
      row(home(`row-${index + 1}`));
      console.log(`ok - ${name}`);
    } catch (error) {
      failed = true;
      console.log(`not ok - ${name}: ${error.stack}`);
    }
  }
} catch (error) {
  failed = true;
  console.log(`not ok - approvals provenance setup: ${error.stack}`);
} finally {
  await provider.terminate();
  if (failed) console.log(`# failed row artifacts: ${base}`);
  else fs.rmSync(base, { recursive: true });
}
if (failed) process.exitCode = 1;
