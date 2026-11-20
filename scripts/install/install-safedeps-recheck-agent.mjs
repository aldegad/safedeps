#!/usr/bin/env node
/* Install a per-user macOS launchd agent for the daily safedeps watch scan
 * (the ledger re-check, then every registered project and the host's JDKs). */

import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const LABEL = 'com.aldegad.safedeps.recheck';
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, '..', '..');
const wrapperPath = path.join(repoRoot, 'scripts', 'safedeps-recheck-alert.sh');
const safedepsHome = path.join(os.homedir(), '.safedeps');
const agentRoot = path.join(safedepsHome, 'agent');
const installedWrapperPath = path.join(agentRoot, 'scripts', 'safedeps-recheck-alert.sh');
const launchAgentsDir = path.join(os.homedir(), 'Library', 'LaunchAgents');
const plistPath = path.join(launchAgentsDir, `${LABEL}.plist`);
const launchdStdoutPath = path.join(safedepsHome, 'launchd-recheck.out.log');
const launchdStderrPath = path.join(safedepsHome, 'launchd-recheck.err.log');
// Written into every runtime this installer builds. A root that holds files and
// has no marker is not ours to replace.
const MARKER = '.safedeps-recheck-runtime';
// What the runtime is: {version, digest, source_repo, built_at}. The scan reads
// it (safedeps_watch_runtime_info in lib/watch/scan.sh), hashes source_repo the
// same way, and reports agent_runtime_stale when the two digests differ.
const RUNTIME_META = '.safedeps-runtime.json';
// The files a runtime is built from, beside this machine's core (machineCore).
// runtimeDigest hashes them the way safedeps_watch_tree_digest does, so the
// two must change together.
const RUNTIME_SOURCES = ['bin/safedeps', 'lib', 'scripts/safedeps-recheck-alert.sh'];
const watchDir = path.join(safedepsHome, 'watch');
const watchConfigPath = path.join(watchDir, 'config.json');
const watchExcludePath = path.join(watchDir, 'exclude');
// Tools the native audits and the population command may need, found on the
// installer's PATH because launchd starts the agent with /usr/bin:/bin only.
const TOOL_NAMES = ['node', 'npm', 'pnpm', 'yarn', 'bun'];

function usage() {
  console.log(`usage: install-safedeps-recheck-agent.mjs <install|uninstall|status> [--hour HH] [--minute MM] [watch options]
       install-safedeps-recheck-agent.mjs stage --root DIR
       install-safedeps-recheck-agent.mjs configure [watch options]

Default schedule: 09:00 local time.
The runtime carries this machine's core, bin/native/<os>-<arch>/safedeps-core,
from this checkout: its re-check reads the approvals store with it. A checkout
without it is refused (core-missing) before anything is built.
stage builds the agent's runtime as DIR and checks that the built bin loads,
without launchd. DIR is replaced as a whole, so it must be absent, empty or a
runtime that stage built before, and it can not be this checkout, hold it or lie
inside it. The tests use it.

watch options (written to ~/.safedeps/watch/config.json and exclude; an option
not given keeps what is there):
  --population-command PATH   absolute path of the command that lists project
                              roots, one "name<TAB>path" a line
  --population-arg ARG        an argument of that command (repeatable)
  --population-timeout SECS   how long it may run (default 120)
  --exclude PATH              an absolute prefix the scan never reads (repeatable)
  --followup KIND=PLAN        the plan that owns an unmeasured kind (repeatable)
  --tool-path DIR             a directory for node/pnpm/yarn/bun (repeatable);
                              without it the installer's own PATH is searched
`);
}

function parseArgs(argv) {
  const args = {
    command: argv[0] || 'install', hour: 9, minute: 0, root: '',
    populationCommand: null, populationArgs: [], populationTimeout: null, excludes: [], followups: {}, toolPath: [],
  };
  if (args.command === '-h' || args.command === '--help') {
    args.command = 'help';
  }
  for (let i = 1; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--hour') {
      args.hour = Number(argv[++i]);
    } else if (arg === '--minute') {
      args.minute = Number(argv[++i]);
    } else if (arg === '--root') {
      args.root = argv[++i] || '';
    } else if (arg === '--population-command') {
      args.populationCommand = argv[++i] || '';
    } else if (arg === '--population-arg') {
      args.populationArgs.push(argv[++i] ?? '');
    } else if (arg === '--population-timeout') {
      args.populationTimeout = Number(argv[++i]);
    } else if (arg === '--exclude') {
      args.excludes.push(argv[++i] || '');
    } else if (arg === '--followup') {
      const value = argv[++i] || '';
      const eq = value.indexOf('=');
      if (eq <= 0 || eq === value.length - 1) {
        throw new Error(`--followup takes KIND=PLAN: ${value}`);
      }
      args.followups[value.slice(0, eq)] = value.slice(eq + 1);
    } else if (arg === '--tool-path') {
      args.toolPath.push(argv[++i] || '');
    } else if (arg === '-h' || arg === '--help') {
      args.command = 'help';
    } else {
      throw new Error(`unknown argument: ${arg}`);
    }
  }
  if (!Number.isInteger(args.hour) || args.hour < 0 || args.hour > 23) {
    throw new Error('--hour must be an integer from 0 to 23');
  }
  if (!Number.isInteger(args.minute) || args.minute < 0 || args.minute > 59) {
    throw new Error('--minute must be an integer from 0 to 59');
  }
  if (args.populationCommand !== null && !path.isAbsolute(args.populationCommand)) {
    throw new Error('--population-command must be an absolute path');
  }
  if (args.populationArgs.length > 0 && args.populationCommand === null) {
    throw new Error('--population-arg needs --population-command');
  }
  if (args.populationTimeout !== null && (!Number.isInteger(args.populationTimeout) || args.populationTimeout < 1)) {
    throw new Error('--population-timeout must be a positive integer');
  }
  for (const value of [...args.excludes, ...args.toolPath]) {
    if (!path.isAbsolute(value) || value.includes('\n')) {
      throw new Error(`--exclude and --tool-path take one absolute path: ${value}`);
    }
  }
  return args;
}

function xmlEscape(value) {
  return String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');
}

function plistXml({ hour, minute }) {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${xmlEscape(installedWrapperPath)}</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>${hour}</integer>
    <key>Minute</key>
    <integer>${minute}</integer>
  </dict>
  <key>EnvironmentVariables</key>
  <dict>
    <key>SAFEDEPS_HOME</key>
    <string>${xmlEscape(safedepsHome)}</string>
  </dict>
  <key>StandardOutPath</key>
  <string>${xmlEscape(launchdStdoutPath)}</string>
  <key>StandardErrorPath</key>
  <string>${xmlEscape(launchdStderrPath)}</string>
</dict>
</plist>
`;
}

function copyRuntimeFile(root, relativePath, mode) {
  const source = path.join(repoRoot, relativePath);
  const target = path.join(root, relativePath);

  fs.mkdirSync(path.dirname(target), { recursive: true, mode: 0o700 });
  fs.copyFileSync(source, target);
  // The source's own mode, without the write bits of group and other, so a
  // runtime built from a group-writable checkout is not group-writable too.
  fs.chmodSync(target, mode ?? (fs.statSync(source).mode & 0o755));
}

function copyRuntimeTree(root, relativeDir) {
  for (const entry of fs.readdirSync(path.join(repoRoot, relativeDir), { withFileTypes: true })) {
    const relativePath = path.join(relativeDir, entry.name);
    if (entry.isDirectory()) {
      copyRuntimeTree(root, relativePath);
    } else if (entry.isFile()) {
      copyRuntimeFile(root, relativePath);
    } else {
      throw new Error(`runtime entry is neither a file nor a directory: ${relativePath}`);
    }
  }
}

function within(outer, inner) {
  const relative = path.relative(outer, inner);
  return relative === '' || (relative !== '..' && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative));
}

// The real path of `target`, where the part of it that does not exist yet is
// taken as written.
function realpathLoose(target) {
  const rest = [];
  let current = path.resolve(target);
  for (;;) {
    try {
      return path.join(fs.realpathSync.native(current), ...rest);
    } catch (error) {
      const parent = path.dirname(current);
      if ((error.code !== 'ENOENT' && error.code !== 'ENOTDIR') || parent === current) {
        throw error;
      }
      rest.unshift(path.basename(current));
      current = parent;
    }
  }
}

// What replacing `root` as a whole may take away: 'absent', 'empty', or 'ours'
// for a runtime this installer built. `ownsRoot` is for the agent's fixed home,
// where an earlier version built the runtime before there was a marker.
function rootState(root, ownsRoot) {
  const realRoot = realpathLoose(root);
  const realRepo = fs.realpathSync.native(repoRoot);
  if (within(realRepo, realRoot) || within(realRoot, realRepo)) {
    throw new Error(`${root} is, holds or lies inside this checkout (${repoRoot}); the runtime is copied out of the checkout, never into it`);
  }
  let stat;
  try {
    stat = fs.lstatSync(root);
  } catch (error) {
    if (error.code === 'ENOENT') {
      return 'absent';
    }
    throw error;
  }
  if (!stat.isDirectory()) {
    throw new Error(`${root} exists and is not a plain directory`);
  }
  if (fs.readdirSync(root).length === 0) {
    return 'empty';
  }
  if (fs.lstatSync(path.join(root, MARKER), { throwIfNoEntry: false })?.isFile()) {
    return 'ours';
  }
  if (ownsRoot) {
    return 'ours';
  }
  throw new Error(
    `${root} has files in it and was not built by this installer (it has no ${MARKER}). ` +
    'The runtime replaces its root as a whole, so that is not done to a directory that may hold something else.',
  );
}

// This machine's core as a path under a checkout or a runtime, and the machine
// it was read from: {machine, core}, core null where no core is built for the
// machine. The answer is the scan's (safedeps_watch_core_file in
// lib/watch/scan.sh), so the file both digests count is named in one place:
// bin/native/<os>-<arch>/safedeps-core, the platform read from the machine
// bash was built for, as the runtime's CLI reads it when it looks for its core
// beside itself (sf_core in bin/safedeps).
function machineCore(root = repoRoot) {
  const scan = path.join(root, 'lib', 'watch', 'scan.sh');
  const run = spawnSync('bash', ['-c', 'printf "%s\\n" "${BASH_VERSINFO[5]:-}"; source "$1" || exit 2; safedeps_watch_core_file || exit 3', 'safedeps-core-file', scan], { encoding: 'utf8' });
  const [machine = '', core = ''] = (run.stdout || '').split('\n');
  if (run.status === 0 && core !== '') {
    return { machine, core };
  }
  if (run.status === 3) {
    return { machine, core: null };
  }
  const detail = [run.error ? run.error.message : '', run.stderr].map((x) => (x || '').trim()).filter(Boolean).join('\n');
  throw new Error(`could not read which core this machine runs from ${scan} (${run.error ? 'bash did not start' : `exit ${run.status}`})${detail ? `: ${detail}` : ''}`);
}

// The core the runtime is built with: this machine's, from this checkout, as a
// path under both. The runtime's re-check reads the approvals store with it,
// and a runtime without it fails every re-check with core_missing, so a
// checkout without it is refused here, by that name, before anything is built
// or written. It has to be a regular file that runs: the digests count regular
// files, and a symbolic link is none.
function requireMachineCore(root = repoRoot) {
  const { machine, core } = machineCore(root);
  const repair = fs.existsSync(path.join(root, 'rust', 'Cargo.toml'))
    ? `build it with ${path.join(root, 'scripts', 'build-core.sh')}`
    : 'reinstall the package';
  if (core === null) {
    throw new Error(
      `core-missing: no safedeps-core binary is built for this machine (bash was built for ${machine || 'an unnamed machine'}), ` +
      'and the runtime\'s re-check reads the approvals store with it. Nothing was built.',
    );
  }
  const file = path.join(root, core);
  let runs = false;
  try {
    runs = fs.lstatSync(file).isFile();
    fs.accessSync(file, fs.constants.X_OK);
  } catch {
    runs = false;
  }
  if (!runs) {
    throw new Error(
      `core-missing: the safedeps-core binary for this machine is missing: ${file} is not an executable regular file, ` +
      `and the runtime's re-check reads the approvals store with it. Repair: ${repair}. Nothing was built.`,
    );
  }
  return core;
}

// The files of RUNTIME_SOURCES and CORE (null for none) under `root`, regular
// files only, paths in byte order. The caller requires the machine core
// before hashing a checkout; a missing core is not a smaller tree.
function listRuntimeSources(root, core) {
  const files = [];
  const walk = (relative, top) => {
    let stat;
    try {
      stat = fs.lstatSync(path.join(root, relative));
    } catch (error) {
      if (top && (error.code === 'ENOENT' || error.code === 'ENOTDIR')) {
        return;
      }
      throw error;
    }
    if (stat.isDirectory()) {
      for (const name of fs.readdirSync(path.join(root, relative))) {
        walk(path.posix.join(relative, name), false);
      }
    } else if (stat.isFile()) {
      files.push(relative);
    }
  };
  for (const source of [...RUNTIME_SOURCES, ...(core ? [core] : [])]) {
    walk(source, true);
  }
  return files.sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)));
}

// One "<sha256>  <path>" line per file, paths in byte order, and the sha256 of
// those lines: safedeps_watch_tree_digest in lib/watch/scan.sh. CORE is this
// machine's core, counted beside the runtime's other files.
function runtimeDigest(root, core) {
  const lines = listRuntimeSources(root, core)
    .map((relative) => `${crypto.createHash('sha256').update(fs.readFileSync(path.join(root, relative))).digest('hex')}  ${relative}\n`)
    .join('');
  return crypto.createHash('sha256').update(lines).digest('hex');
}

function buildRuntime(dir, core) {
  copyRuntimeFile(dir, 'bin/safedeps', 0o755);
  // bin/safedeps sources lib/ files under `set -euo pipefail`, and they source
  // each other. A hand-kept list of them missed one twice, and each time the
  // copied bin aborted at source time, so the daily re-check never ran: first
  // lib/npm/closure.sh (finding #6), then lib/truth-sources.sh from v2.15.8 and
  // lib/advisory-log-rotate.sh and lib/npm/ask.sh from v2.18.0. So the whole
  // lib/ tree is copied, and there is no list to keep in step.
  copyRuntimeTree(dir, 'lib');
  copyRuntimeFile(dir, 'scripts/safedeps-recheck-alert.sh', 0o755);
  // The CLI finds its core beside itself and nowhere else, so the core goes
  // where it is in the checkout. Only this machine's: the CLI runs no other.
  // The runtime has no rust/ for the core's stamp check to read, and needs
  // none: that check runs on the hook path (pre, post), and the runtime's CLI
  // runs the core's `approvals` only.
  copyRuntimeFile(dir, core);
  fs.writeFileSync(path.join(dir, MARKER), 'built by install-safedeps-recheck-agent.mjs; the runtime is replaced as a whole\n', { mode: 0o644 });
}

// The runtime's own record of what it is. The version is the one the built bin
// answers, the digest is of the files it was built from, and built_at is when
// a runtime with this digest was first put at `root`: a build that changes
// nothing keeps the record it found, so it changes nothing.
function writeRuntimeMeta(dir, root, version, core) {
  const digest = runtimeDigest(dir, core);
  if (digest !== runtimeDigest(repoRoot, core)) {
    throw new Error('the built runtime does not hash to its checkout; a file changed while it was copied');
  }
  let builtAt = new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
  try {
    const previous = JSON.parse(fs.readFileSync(path.join(root, RUNTIME_META), 'utf8'));
    if (previous.digest === digest && previous.version === version && typeof previous.built_at === 'string') {
      builtAt = previous.built_at;
    }
  } catch {
    // No record, or none this build can keep: the build is new.
  }
  fs.writeFileSync(path.join(dir, RUNTIME_META), `${JSON.stringify({
    version,
    digest,
    source_repo: fs.realpathSync.native(repoRoot),
    built_at: builtAt,
  })}\n`, { mode: 0o644 });
}

// Smoke the built runtime: its bin must at least load and answer `version`.
// Returns the version it answered.
function smokeRuntime(dir) {
  const smoke = spawnSync(path.join(dir, 'bin/safedeps'), ['--json', 'version'], { encoding: 'utf8' });
  let version = null;
  try {
    version = JSON.parse(smoke.stdout).version;
  } catch {
    version = null;
  }
  if (smoke.status !== 0 || typeof version !== 'string' || version === '') {
    const detail = [smoke.stdout, smoke.stderr].filter(Boolean).join('\n').trim();
    throw new Error(
      `safedeps re-check agent runtime smoke failed — the built bin did not load ` +
      `(a runtime file is likely missing from what buildRuntime() copies).${detail ? `\n${detail}` : ''}`,
    );
  }
  return version;
}

// Puts a runtime already built and smoked at `staging` where `root` is. An
// absent or empty root takes it with one rename. A root that holds a runtime is
// moved aside first and put back if the second rename fails; between the two
// renames `root` does not exist, and that is as short as two renames can make
// it. The old runtime is removed only once the new one is in place.
function swapRuntime(staging, root, state) {
  if (state !== 'ours') {
    fs.renameSync(staging, root);
    return;
  }
  const aside = fs.mkdtempSync(path.join(path.dirname(root), `.${path.basename(root)}.old-`));
  fs.renameSync(root, aside);
  try {
    fs.renameSync(staging, root);
  } catch (error) {
    try {
      fs.renameSync(aside, root);
    } catch (restore) {
      throw new Error(`${error.message}; the old runtime could not be put back either (${restore.message}) and is in ${aside}`);
    }
    throw error;
  }
  try {
    fs.rmSync(aside, { recursive: true, force: true });
  } catch (error) {
    console.error(`safedeps re-check agent: the new runtime is in place; the old one could not be removed from ${aside}: ${error.message}`);
  }
}

// The runtime is built whole beside `root`, smoked, and only then put in place,
// so a copy that fails, a runtime that does not load or a root that was not
// ours leaves what was there as it was. Removing the old lib/ and copying the
// new one into its place did not: a symbolic link in lib/ threw after the old
// lib/ was gone, and `stage --root <this checkout>` deleted the checkout's own.
// CORE is requireMachineCore's answer, asked by the caller before it writes
// anything of its own.
function installRuntime(root, core, { ownsRoot = false } = {}) {
  const state = rootState(root, ownsRoot);
  const parent = path.dirname(root);
  fs.mkdirSync(parent, { recursive: true, mode: 0o700 });
  const staging = fs.mkdtempSync(path.join(parent, `.${path.basename(root)}.new-`));
  let placed = false;
  try {
    buildRuntime(staging, core);
    writeRuntimeMeta(staging, root, smokeRuntime(staging), core);
    swapRuntime(staging, root, state);
    placed = true;
  } finally {
    if (!placed) {
      fs.rmSync(staging, { recursive: true, force: true });
    }
  }
}

function run(command, args, { allowFailure = false } = {}) {
  const result = spawnSync(command, args, { encoding: 'utf8' });
  if (result.status !== 0 && !allowFailure) {
    const detail = [result.stdout, result.stderr].filter(Boolean).join('\n').trim();
    throw new Error(`${command} ${args.join(' ')} failed${detail ? `\n${detail}` : ''}`);
  }
  return result;
}

function serviceTarget() {
  return `gui/${process.getuid()}/${LABEL}`;
}

function domainTarget() {
  return `gui/${process.getuid()}`;
}

function writeAtomic(target, text) {
  fs.mkdirSync(path.dirname(target), { recursive: true, mode: 0o700 });
  const temp = `${target}.${process.pid}.tmp`;
  fs.writeFileSync(temp, text, { mode: 0o600 });
  fs.renameSync(temp, target);
}

function findTools() {
  const dirs = [];
  const found = {};
  for (const name of TOOL_NAMES) {
    for (const dir of (process.env.PATH || '').split(path.delimiter)) {
      if (!path.isAbsolute(dir)) continue;
      const candidate = path.join(dir, name);
      try {
        fs.accessSync(candidate, fs.constants.X_OK);
      } catch {
        continue;
      }
      found[name] = candidate;
      if (!dirs.includes(dir)) dirs.push(dir);
      break;
    }
  }
  return { dirs, found };
}

// ~/.safedeps/watch/config.json and exclude, read and planned before anything is
// built, written once the runtime is in place. Each option given replaces its key;
// a key no option names keeps the value already there. A config that is not a
// JSON object is not overwritten: the scan reads it as config_unreadable, and
// so does this.
function planWatchConfig(args) {
  let config = {};
  if (fs.existsSync(watchConfigPath)) {
    config = JSON.parse(fs.readFileSync(watchConfigPath, 'utf8'));
    if (config === null || typeof config !== 'object' || Array.isArray(config)) {
      throw new Error(`${watchConfigPath} is not a JSON object; fix or remove it first`);
    }
  }
  if (args.populationCommand !== null) {
    config.population_command = [args.populationCommand, ...args.populationArgs];
  }
  if (args.populationTimeout !== null) {
    config.population_timeout_seconds = args.populationTimeout;
  }
  if (Object.keys(args.followups).length > 0) {
    config.followups = { ...(config.followups || {}), ...args.followups };
  }
  let toolSource = 'kept';
  if (args.toolPath.length > 0) {
    config.tool_path = args.toolPath;
    toolSource = 'given';
  } else {
    const { dirs } = findTools();
    if (dirs.length > 0) {
      config.tool_path = dirs;
      toolSource = 'installer PATH';
    }
  }
  let excludes = [];
  if (fs.existsSync(watchExcludePath)) {
    excludes = fs.readFileSync(watchExcludePath, 'utf8').split('\n').filter((line) => line.trim() !== '' && !line.startsWith('#'));
  }
  for (const value of args.excludes) {
    if (!excludes.includes(value)) excludes.push(value);
  }
  return { config, excludes, toolSource, configPath: watchConfigPath, excludePath: watchExcludePath };
}

function writeWatchConfig(plan) {
  writeAtomic(watchConfigPath, `${JSON.stringify(plan.config, null, 2)}\n`);
  if (plan.excludes.length > 0 || fs.existsSync(watchExcludePath)) {
    writeAtomic(watchExcludePath, plan.excludes.map((line) => `${line}\n`).join(''));
  }
  return plan;
}

function install(args) {
  if (process.platform !== 'darwin') {
    throw new Error('launchd re-check agent install is supported on macOS only');
  }
  if (!fs.existsSync(wrapperPath)) {
    throw new Error(`wrapper not found: ${wrapperPath}`);
  }
  const core = requireMachineCore();

  fs.mkdirSync(launchAgentsDir, { recursive: true, mode: 0o700 });
  fs.mkdirSync(safedepsHome, { recursive: true, mode: 0o700 });
  fs.chmodSync(wrapperPath, 0o755);
  const watch = planWatchConfig(args);
  installRuntime(agentRoot, core, { ownsRoot: true });
  writeWatchConfig(watch);
  fs.writeFileSync(launchdStdoutPath, '');
  fs.writeFileSync(launchdStderrPath, '');

  const tempPath = `${plistPath}.${process.pid}.tmp`;
  fs.writeFileSync(tempPath, plistXml(args), { mode: 0o644 });
  fs.renameSync(tempPath, plistPath);

  run('launchctl', ['bootout', domainTarget(), plistPath], { allowFailure: true });
  run('launchctl', ['bootstrap', domainTarget(), plistPath]);
  run('launchctl', ['kickstart', '-k', serviceTarget()]);

  console.log(JSON.stringify({
    installed: true,
    label: LABEL,
    plistPath,
    agentRoot,
    program: installedWrapperPath,
    runtime: JSON.parse(fs.readFileSync(path.join(agentRoot, RUNTIME_META), 'utf8')),
    schedule: { hour: args.hour, minute: args.minute },
    watch: { configPath: watch.configPath, excludePath: watch.excludePath, config: watch.config, excludes: watch.excludes, toolPath: watch.toolSource },
    logs: {
      recheck: path.join(os.homedir(), '.safedeps', 'recheck.log'),
      alerts: path.join(os.homedir(), '.safedeps', 'recheck-alerts.jsonl'),
      launchdStdout: launchdStdoutPath,
      launchdStderr: launchdStderrPath
    }
  }, null, 2));
}

function uninstall() {
  if (process.platform !== 'darwin') {
    throw new Error('launchd re-check agent uninstall is supported on macOS only');
  }
  run('launchctl', ['bootout', domainTarget(), plistPath], { allowFailure: true });
  if (fs.existsSync(plistPath)) {
    fs.rmSync(plistPath);
  }
  console.log(JSON.stringify({ installed: false, label: LABEL, plistPath, agentRoot }, null, 2));
}

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    return error.code === 'ENOENT' ? null : { error: error.message };
  }
}

// One JSON object: what launchd holds, the runtime and whether its checkout
// has moved on, the watch config, the scan state and the last receipt. The
// launchctl text is in `launchd.print` for a reader who needs the rest.
function status() {
  const result = run('launchctl', ['print', serviceTarget()], { allowFailure: true });
  const print = result.stdout || '';
  const field = (name) => (print.match(new RegExp(`^\\s*${name} = (.*)$`, 'm')) || [])[1] ?? null;
  const runtime = readJson(path.join(agentRoot, RUNTIME_META));
  let sourceDigestNow = null;
  if (runtime && runtime.source_repo && fs.existsSync(path.join(runtime.source_repo, 'bin', 'safedeps'))) {
    // A checkout without its required core has no digest, as at install.
    sourceDigestNow = runtimeDigest(runtime.source_repo, requireMachineCore(runtime.source_repo));
  }
  const state = readJson(path.join(watchDir, 'state.json'));
  const runsDir = path.join(watchDir, 'runs');
  const receipts = fs.existsSync(runsDir) ? fs.readdirSync(runsDir).filter((name) => name.endsWith('.json')).sort() : [];
  const lastReceipt = receipts.length > 0 ? readJson(path.join(runsDir, receipts[receipts.length - 1])) : null;
  console.log(JSON.stringify({
    label: LABEL,
    loaded: result.status === 0,
    launchd: {
      state: field('state'),
      runs: field('runs') === null ? null : Number(field('runs')),
      last_exit_code: field('last exit code'),
      program: field('program'),
    },
    plistPath,
    runtime,
    agent_runtime_stale: runtime && sourceDigestNow ? sourceDigestNow !== runtime.digest : null,
    watch: {
      config: readJson(watchConfigPath),
      excludes: fs.existsSync(watchExcludePath) ? fs.readFileSync(watchExcludePath, 'utf8').split('\n').filter(Boolean) : [],
      generation: state && !state.error ? state.generation ?? null : null,
      last_scan: state && !state.error ? state.last_scan ?? null : null,
      last_success_at: state && !state.error ? state.last_success_at ?? null : null,
      summary: state && !state.error ? state.summary ?? null : null,
      last_receipt: lastReceipt,
    },
  }, null, 2));
  process.exitCode = result.status === 0 ? 0 : 1;
}

try {
  const args = parseArgs(process.argv.slice(2));
  if (args.command === 'help') {
    usage();
  } else if (args.command === 'install') {
    install(args);
  } else if (args.command === 'uninstall') {
    uninstall();
  } else if (args.command === 'status') {
    status();
  } else if (args.command === 'configure') {
    const watch = writeWatchConfig(planWatchConfig(args));
    console.log(JSON.stringify({ configured: true, ...watch }, null, 2));
  } else if (args.command === 'stage') {
    if (!args.root) {
      throw new Error('stage needs --root DIR');
    }
    const root = path.resolve(args.root);
    installRuntime(root, requireMachineCore());
    console.log(JSON.stringify({ staged: true, root }, null, 2));
  } else {
    throw new Error(`unknown command: ${args.command}`);
  }
} catch (error) {
  console.error(`safedeps re-check agent: ${error.message}`);
  process.exit(1);
}
