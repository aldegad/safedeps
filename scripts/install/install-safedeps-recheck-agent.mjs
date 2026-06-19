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

function usage() {
  console.log(`usage: install-safedeps-recheck-agent.mjs <install|uninstall|status> [--hour HH] [--minute MM]

Default schedule: 09:00 local time.
`);
}

function parseArgs(argv) {
  const args = { command: argv[0] || 'install', hour: 9, minute: 0 };
  if (args.command === '-h' || args.command === '--help') {
    args.command = 'help';
  }
  for (let i = 1; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--hour') {
      args.hour = Number(argv[++i]);
    } else if (arg === '--minute') {
      args.minute = Number(argv[++i]);
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

function copyRuntimeFile(relativePath, mode) {
  const source = path.join(repoRoot, relativePath);
  const target = path.join(agentRoot, relativePath);

  fs.mkdirSync(path.dirname(target), { recursive: true, mode: 0o700 });
  fs.copyFileSync(source, target);
  fs.chmodSync(target, mode);
}

function installRuntime() {
  copyRuntimeFile('bin/safedeps', 0o755);
  copyRuntimeFile('lib/providers/providers.sh', 0o755);
  copyRuntimeFile('lib/ledger/ledger.sh', 0o755);
  // bin/safedeps sources lib/npm/closure.sh under `set -euo pipefail`, so omitting
  // it made the copied agent bin abort at source time on every scheduled run — the
  // daily re-check never actually ran (finding #6). Keep this list in sync with the
  // `source` set in bin/safedeps; the post-install smoke below guards against drift.
  copyRuntimeFile('lib/npm/closure.sh', 0o755);
  copyRuntimeFile('scripts/safedeps-recheck-alert.sh', 0o755);

  // Smoke the copied runtime so a future added lib dependency cannot silently
  // re-break the agent: the copied bin must at least load and answer `version`.
  const copiedBin = path.join(agentRoot, 'bin/safedeps');
  const smoke = spawnSync(copiedBin, ['--json', 'version'], { encoding: 'utf8' });
  if (smoke.status !== 0) {
    const detail = [smoke.stdout, smoke.stderr].filter(Boolean).join('\n').trim();
    throw new Error(
      `safedeps re-check agent runtime smoke failed — the copied bin did not load ` +
      `(a runtime file is likely missing from installRuntime()).${detail ? `\n${detail}` : ''}`,
    );
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
  installRuntime();
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
  } else {
    throw new Error(`unknown command: ${args.command}`);
  }
} catch (error) {
  console.error(`safedeps re-check agent: ${error.message}`);
  process.exit(1);
}
