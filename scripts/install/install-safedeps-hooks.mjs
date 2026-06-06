#!/usr/bin/env node
// safedeps cross-engine installer.
// Registers the safedeps skill + PreToolUse/PostToolUse hooks for both
// Claude Code (~/.claude) and Codex CLI (~/.codex).
//
// Idempotent: running twice leaves state unchanged.
// Backup-before-write: every JSON config file is copied to .bak before edit.
//
// Usage:
//   node scripts/install/install-safedeps-hooks.mjs
//   node scripts/install/install-safedeps-hooks.mjs --uninstall
//   node scripts/install/install-safedeps-hooks.mjs --link-bin   (optional ~/.local/bin/safedeps)

import { existsSync, lstatSync, readFileSync, writeFileSync, copyFileSync, mkdirSync, symlinkSync, unlinkSync, readlinkSync, renameSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, "..", "..");
const HOME = process.env.HOME || homedir();

const SKILL_ID = "safedeps";
const PRE_HOOK_NAME = "safedeps-pre-guard.sh";
const POST_HOOK_NAME = "safedeps-post-verify.sh";
const REPO_PRE_HOOK = join(REPO_ROOT, "scripts", PRE_HOOK_NAME);
const REPO_POST_HOOK = join(REPO_ROOT, "scripts", POST_HOOK_NAME);
const CLI_BIN = join(REPO_ROOT, "bin", "safedeps");

const args = new Set(process.argv.slice(2));
const UNINSTALL = args.has("--uninstall");
const LINK_BIN = args.has("--link-bin");

function log(...parts) { console.log(`[safedeps-install]`, ...parts); }
function warn(...parts) { console.warn(`[safedeps-install]`, ...parts); }

function isSymlink(p) {
  try { return lstatSync(p).isSymbolicLink(); } catch { return false; }
}

function ensureSymlink(target, linkPath) {
  if (isSymlink(linkPath)) {
    const current = readlinkSync(linkPath);
    if (current === target) { log(`symlink ok   ${linkPath} -> ${target}`); return; }
    unlinkSync(linkPath);
  } else if (existsSync(linkPath)) {
    throw new Error(`refusing to overwrite non-symlink at ${linkPath}`);
  }
  mkdirSync(dirname(linkPath), { recursive: true });
  symlinkSync(target, linkPath);
  log(`symlink wrote ${linkPath} -> ${target}`);
}

function removeSymlink(linkPath) {
  if (isSymlink(linkPath)) {
    unlinkSync(linkPath);
    log(`symlink removed ${linkPath}`);
  }
}

function readJson(path) {
  if (!existsSync(path)) return {};
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch (err) {
    throw new Error(`invalid JSON at ${path}: ${err.message}`);
  }
}

function writeJsonWithBackup(path, value) {
  if (existsSync(path)) {
    copyFileSync(path, `${path}.bak`);
  } else {
    mkdirSync(dirname(path), { recursive: true });
  }
  const tmpPath = `${path}.tmp.${process.pid}.${Date.now()}`;
  writeFileSync(tmpPath, JSON.stringify(value, null, 2) + "\n");
  renameSync(tmpPath, path);
}

function engineHookCommand(engineRoot, hookName) {
  const engineName = basename(engineRoot).replace(/^\./u, "");
  return `~/.${engineName}/skills/${SKILL_ID}/scripts/${hookName}`;
}

function ensureHook(config, eventName, command) {
  config.hooks = config.hooks ?? {};
  config.hooks[eventName] = config.hooks[eventName] ?? [];
  const buckets = config.hooks[eventName];

  const already = buckets.some((bucket) =>
    bucket?.matcher === "Bash" &&
    Array.isArray(bucket?.hooks) &&
    bucket.hooks.some((h) => h && h.type === "command" && h.command === command),
  );
  if (already) return false;

  let bashBucket = buckets.find((b) => b && b.matcher === "Bash");
  if (!bashBucket) {
    bashBucket = { matcher: "Bash", hooks: [] };
    buckets.push(bashBucket);
  }
  bashBucket.hooks = bashBucket.hooks ?? [];

  bashBucket.hooks.push({ type: "command", command });
  return true;
}

function removeHook(config, eventName, command) {
  const buckets = config?.hooks?.[eventName];
  if (!Array.isArray(buckets)) return false;
  let changed = false;
  for (const bucket of buckets) {
    if (!bucket || bucket.matcher !== "Bash" || !Array.isArray(bucket.hooks)) continue;
    const before = bucket.hooks.length;
    bucket.hooks = bucket.hooks.filter((h) => !(h && h.type === "command" && h.command === command));
    if (bucket.hooks.length !== before) changed = true;
  }
  return changed;
}

function isSafedepsHookCommand(command, hookName) {
  if (typeof command !== "string") return false;
  const normalized = command.replace(/\\/gu, "/");
  if (normalized.includes("npm-reorg-guard")) return true;
  return normalized.includes("/safedeps/") && normalized.endsWith(`/scripts/${hookName}`);
}

function pruneNonCanonicalSafedepsHooks(config, eventName, canonicalCommand, hookName) {
  const buckets = config?.hooks?.[eventName];
  if (!Array.isArray(buckets)) return false;
  let changed = false;
  let seenCanonical = false;
  for (const bucket of buckets) {
    if (!bucket || !Array.isArray(bucket.hooks)) continue;
    const before = bucket.hooks.length;
    bucket.hooks = bucket.hooks.filter((h) => {
      const command = h?.command;
      if (command === canonicalCommand) {
        if (bucket.matcher !== "Bash") return false;
        if (seenCanonical) return false;
        seenCanonical = true;
        return true;
      }
      return command === canonicalCommand || !isSafedepsHookCommand(command, hookName);
    });
    if (bucket.hooks.length !== before) changed = true;
  }
  return changed;
}

function pruneAllSafedepsHooks(config, eventName, hookName) {
  const buckets = config?.hooks?.[eventName];
  if (!Array.isArray(buckets)) return false;
  let changed = false;
  for (const bucket of buckets) {
    if (!bucket || !Array.isArray(bucket.hooks)) continue;
    const before = bucket.hooks.length;
    bucket.hooks = bucket.hooks.filter((h) => !isSafedepsHookCommand(h?.command, hookName));
    if (bucket.hooks.length !== before) changed = true;
  }
  return changed;
}

function installInEngine({ engineRoot, configPath, label }) {
  if (!existsSync(engineRoot)) {
    warn(`skip ${label} (${engineRoot} not present)`);
    return;
  }
  const skillsRoot = join(engineRoot, "skills");
  const skillLink = join(skillsRoot, SKILL_ID);
  const preCommand = engineHookCommand(engineRoot, PRE_HOOK_NAME);
  const postCommand = engineHookCommand(engineRoot, POST_HOOK_NAME);

  if (UNINSTALL) {
    removeSymlink(skillLink);
    if (existsSync(configPath)) {
      const cfg = readJson(configPath);
      const pre = removeHook(cfg, "PreToolUse", preCommand) || pruneAllSafedepsHooks(cfg, "PreToolUse", PRE_HOOK_NAME);
      const post = removeHook(cfg, "PostToolUse", postCommand) || pruneAllSafedepsHooks(cfg, "PostToolUse", POST_HOOK_NAME);
      if (pre || post) {
        writeJsonWithBackup(configPath, cfg);
        log(`patched ${configPath} (removed safedeps hooks)`);
      } else {
        log(`config clean ${configPath}`);
      }
    }
    return;
  }

  ensureSymlink(REPO_ROOT, skillLink);

  const cfg = readJson(configPath);
  const legacyPreRemoved = pruneNonCanonicalSafedepsHooks(cfg, "PreToolUse", preCommand, PRE_HOOK_NAME);
  const legacyPostRemoved = pruneNonCanonicalSafedepsHooks(cfg, "PostToolUse", postCommand, POST_HOOK_NAME);
  const preAdded = ensureHook(cfg, "PreToolUse", preCommand);
  const postAdded = ensureHook(cfg, "PostToolUse", postCommand);
  if (legacyPreRemoved || legacyPostRemoved || preAdded || postAdded) {
    writeJsonWithBackup(configPath, cfg);
    log(`patched ${configPath} (pre=${preAdded ? "added" : "ok"}, post=${postAdded ? "added" : "ok"}, legacy=${legacyPreRemoved || legacyPostRemoved ? "removed" : "ok"})`);
  } else {
    log(`config ok   ${configPath} (hooks already registered)`);
  }
}

function maybeLinkBin() {
  if (!LINK_BIN || UNINSTALL) return;
  const target = CLI_BIN;
  const linkPath = join(HOME, ".local", "bin", "safedeps");
  try {
    ensureSymlink(target, linkPath);
  } catch (err) {
    warn(`bin symlink skipped: ${err.message}`);
  }
}

function unlinkBin() {
  if (!UNINSTALL) return;
  removeSymlink(join(HOME, ".local", "bin", "safedeps"));
}

function main() {
  if (!existsSync(REPO_PRE_HOOK) || !existsSync(REPO_POST_HOOK)) {
    throw new Error(`hook scripts not found at ${REPO_PRE_HOOK} / ${REPO_POST_HOOK}`);
  }

  installInEngine({
    engineRoot: join(HOME, ".claude"),
    configPath: join(HOME, ".claude", "settings.json"),
    label: "Claude Code",
  });
  installInEngine({
    engineRoot: join(HOME, ".codex"),
    configPath: join(HOME, ".codex", "hooks.json"),
    label: "Codex CLI",
  });

  maybeLinkBin();
  unlinkBin();

  if (UNINSTALL) {
    log("uninstall done.");
  } else {
    log("install done. New hook events fire on the next session start.");
    // The dependency-install gate is global. The secret-leak lane is per-repo
    // and stays opt-in (its policy lives in each repo). Nudge, do not auto-write.
    log("secret-leak lane is per-repo — in a repo run: safedeps doctor (then `safedeps doctor --fix` to scaffold + activate).");
  }
}

main();
