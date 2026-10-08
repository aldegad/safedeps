#!/usr/bin/env node
/* Install a per-user macOS launchd agent for daily safedeps re-check. */

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

function usage() {
  console.log(`usage: install-safedeps-recheck-agent.mjs <install|uninstall|status> [--hour HH] [--minute MM]
       install-safedeps-recheck-agent.mjs stage --root DIR

Default schedule: 09:00 local time.
stage builds the agent's runtime as DIR and checks that the built bin loads,
without launchd. DIR is replaced as a whole, so it must be absent, empty or a
runtime that stage built before, and it can not be this checkout, hold it or lie
inside it. The tests use it.
`);
}

function parseArgs(argv) {
  const args = { command: argv[0] || 'install', hour: 9, minute: 0, root: '' };
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

function buildRuntime(dir) {
  copyRuntimeFile(dir, 'bin/safedeps', 0o755);
  // bin/safedeps sources lib/ files under `set -euo pipefail`, and they source
  // each other. A hand-kept list of them missed one twice, and each time the
  // copied bin aborted at source time, so the daily re-check never ran: first
  // lib/npm/closure.sh (finding #6), then lib/truth-sources.sh from v2.15.8 and
  // lib/advisory-log-rotate.sh and lib/npm/ask.sh from v2.18.0. So the whole
  // lib/ tree is copied, and there is no list to keep in step.
  copyRuntimeTree(dir, 'lib');
  copyRuntimeFile(dir, 'scripts/safedeps-recheck-alert.sh', 0o755);
  fs.writeFileSync(path.join(dir, MARKER), 'built by install-safedeps-recheck-agent.mjs; the runtime is replaced as a whole\n', { mode: 0o644 });
}

// Smoke the built runtime: its bin must at least load and answer `version`.
function smokeRuntime(dir) {
  const smoke = spawnSync(path.join(dir, 'bin/safedeps'), ['--json', 'version'], { encoding: 'utf8' });
  if (smoke.status !== 0) {
    const detail = [smoke.stdout, smoke.stderr].filter(Boolean).join('\n').trim();
    throw new Error(
      `safedeps re-check agent runtime smoke failed — the built bin did not load ` +
      `(a runtime file is likely missing from what buildRuntime() copies).${detail ? `\n${detail}` : ''}`,
    );
  }
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
function installRuntime(root, { ownsRoot = false } = {}) {
  const state = rootState(root, ownsRoot);
  const parent = path.dirname(root);
  fs.mkdirSync(parent, { recursive: true, mode: 0o700 });
  const staging = fs.mkdtempSync(path.join(parent, `.${path.basename(root)}.new-`));
  let placed = false;
  try {
    buildRuntime(staging);
    smokeRuntime(staging);
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

function install(args) {
  if (process.platform !== 'darwin') {
    throw new Error('launchd re-check agent install is supported on macOS only');
  }
  if (!fs.existsSync(wrapperPath)) {
    throw new Error(`wrapper not found: ${wrapperPath}`);
  }

  fs.mkdirSync(launchAgentsDir, { recursive: true, mode: 0o700 });
  fs.mkdirSync(safedepsHome, { recursive: true, mode: 0o700 });
  fs.chmodSync(wrapperPath, 0o755);
  installRuntime(agentRoot, { ownsRoot: true });
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
    schedule: { hour: args.hour, minute: args.minute },
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

function status() {
  const result = run('launchctl', ['print', serviceTarget()], { allowFailure: true });
  process.stdout.write(result.stdout || '');
  process.stderr.write(result.stderr || '');
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
  } else if (args.command === 'stage') {
    if (!args.root) {
      throw new Error('stage needs --root DIR');
    }
    const root = path.resolve(args.root);
    installRuntime(root);
    console.log(JSON.stringify({ staged: true, root }, null, 2));
  } else {
    throw new Error(`unknown command: ${args.command}`);
  }
} catch (error) {
  console.error(`safedeps re-check agent: ${error.message}`);
  process.exit(1);
}
