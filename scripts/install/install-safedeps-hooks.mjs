#!/usr/bin/env node
// safedeps cross-engine installer.
// Registers the safedeps skill + PreToolUse/PostToolUse hooks for both
// Claude Code (~/.claude) and Codex CLI (~/.codex), and on Claude Code the
// post hook for PostToolUseFailure too.
//
// Idempotent: running twice leaves state unchanged.
// Backup-before-write: every JSON config file is copied to .bak before edit.
//
// Usage:
//   node scripts/install/install-safedeps-hooks.mjs
//   node scripts/install/install-safedeps-hooks.mjs --uninstall
//   node scripts/install/install-safedeps-hooks.mjs --link-bin   (optional ~/.local/bin/safedeps)
//   node scripts/install/install-safedeps-hooks.mjs --watch-notice      (Claude Code: tell a new session what the watch found)
//   node scripts/install/install-safedeps-hooks.mjs --no-watch-notice   (remove that notice, keep the gate)

import { existsSync, lstatSync, readFileSync, writeFileSync, copyFileSync, mkdirSync, symlinkSync, unlinkSync, readlinkSync, renameSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { homedir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, "..", "..");
const HOME = process.env.HOME || homedir();

const SKILL_ID = "safedeps";
// Legacy names are only for removing old registrations.
const PRE_HOOK_NAME = "safedeps-pre-guard.sh";
const POST_HOOK_NAME = "safedeps-post-verify.sh";
// The registered entry explains a missing or failed core before exiting 2.
const ENTRY_HOOK_NAME = "safedeps-hook-entry.sh";
const REPO_ENTRY_HOOK = join(REPO_ROOT, "scripts", ENTRY_HOOK_NAME);
const CLI_BIN = join(REPO_ROOT, "bin", "safedeps");
const BUILD_CORE = join(REPO_ROOT, "scripts", "build-core.sh");
const PRE_HOOK_TIMEOUT_SECONDS = 30;
const POST_HOOK_TIMEOUT_SECONDS = 30;
// The events the post hook is registered for, by engine. Claude Code runs
// PostToolUse only after a tool call succeeds, and PostToolUseFailure after a
// Bash call that ran and failed, with the same tool_name, tool_input and
// tool_use_id (source: https://code.claude.com/docs/en/hooks, "PostToolUse:
// Runs immediately after a tool completes successfully", "PostToolUseFailure:
// Runs when a tool that started executing fails", verified 2026-10-04).
// Without it a failed npm install was never judged, and its record stayed for
// the next call of the command. Codex runs PostToolUse after a Bash command
// that exits non-zero too, and documents no PostToolUseFailure (source:
// https://learn.chatgpt.com/docs/hooks, verified 2026-10-04).
const POST_EVENTS_BY_ENGINE = {
  claude: ["PostToolUse", "PostToolUseFailure"],
  codex: ["PostToolUse"],
};
// Every event a post hook was ever registered for, so --uninstall and the
// legacy cleanup reach all of them on either engine.
const ALL_POST_EVENTS = ["PostToolUse", "PostToolUseFailure"];

// The watch's session-start notice, registered only when asked. Claude Code
// runs SessionStart hooks when a session starts or resumes and adds their
// plain stdout to the session's context; the matcher filters on how the
// session started (`startup`, `resume`, `clear`, `compact`, `fork`) and takes
// a `|` list (source: https://code.claude.com/docs/en/hooks, "SessionStart"
// and "Matcher patterns", verified 2026-11-23). It is a notice, not a gate: it
// reads `safedeps watch status` and blocks nothing. Other engines get one line
// in their instruction file instead, which SKILL.md gives; the installer
// writes no instruction file.
const NOTICE_HOOK_NAME = "safedeps-watch-notice.sh";
const NOTICE_EVENT = "SessionStart";
const NOTICE_MATCHER = "startup|resume";
const NOTICE_TIMEOUT_SECONDS = 10;

const args = new Set(process.argv.slice(2));
const KNOWN_ARGS = new Set(["--uninstall", "--link-bin", "--watch-notice", "--no-watch-notice"]);
const UNINSTALL = args.has("--uninstall");
const LINK_BIN = args.has("--link-bin");
const WATCH_NOTICE = args.has("--watch-notice");
const NO_WATCH_NOTICE = args.has("--no-watch-notice");

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

function engineHookCommand(engineRoot, target) {
  const engineName = basename(engineRoot).replace(/^\./u, "");
  return `~/.${engineName}/skills/${SKILL_ID}/scripts/${ENTRY_HOOK_NAME} ${target}`;
}

function ensureHook(config, eventName, command, timeoutSeconds) {
  config.hooks = config.hooks ?? {};
  config.hooks[eventName] = config.hooks[eventName] ?? [];
  const buckets = config.hooks[eventName];

  let bashBucket = buckets.find((b) => b && b.matcher === "Bash");
  if (!bashBucket) {
    bashBucket = { matcher: "Bash", hooks: [] };
    buckets.push(bashBucket);
  }
  bashBucket.hooks = bashBucket.hooks ?? [];

  const existing = bashBucket.hooks.find((h) => h && h.type === "command" && h.command === command);
  if (existing) {
    if (existing.timeout !== timeoutSeconds) {
      existing.timeout = timeoutSeconds;
      return true;
    }
    return false;
  }

  bashBucket.hooks.push({ type: "command", command, timeout: timeoutSeconds });
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
  if (!normalized.includes("/safedeps/")) return false;
  const withoutTarget = normalized.replace(/ (?:pre|post)$/u, "");
  if (withoutTarget.endsWith(`/scripts/${ENTRY_HOOK_NAME}`)) return true;
  return normalized.endsWith(`/scripts/${hookName}`);
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

function noticeCommand(engineRoot) {
  const engineName = basename(engineRoot).replace(/^\./u, "");
  return `~/.${engineName}/skills/${SKILL_ID}/scripts/${NOTICE_HOOK_NAME}`;
}

function isSafedepsNoticeCommand(command) {
  if (typeof command !== "string") return false;
  const normalized = command.replace(/\\/gu, "/");
  return normalized.includes("/safedeps/") && normalized.endsWith(`/scripts/${NOTICE_HOOK_NAME}`);
}

// Removes every safedeps notice from SessionStart, and a group it leaves
// empty, and the event when nothing is left under it.
function removeNotice(config) {
  const buckets = config?.hooks?.[NOTICE_EVENT];
  if (!Array.isArray(buckets)) return false;
  let changed = false;
  const kept = [];
  for (const bucket of buckets) {
    if (!bucket || !Array.isArray(bucket.hooks)) { kept.push(bucket); continue; }
    const before = bucket.hooks.length;
    bucket.hooks = bucket.hooks.filter((h) => !isSafedepsNoticeCommand(h?.command));
    if (bucket.hooks.length !== before) {
      changed = true;
      if (bucket.hooks.length === 0) continue;
    }
    kept.push(bucket);
  }
  if (!changed) return false;
  if (kept.length === 0) delete config.hooks[NOTICE_EVENT];
  else config.hooks[NOTICE_EVENT] = kept;
  return true;
}

// One notice, in a group of its own with the canonical matcher and timeout.
// A notice anywhere else (another group, an older path) is removed first.
function ensureNotice(config, command) {
  const buckets = config?.hooks?.[NOTICE_EVENT];
  if (Array.isArray(buckets)) {
    const canonical = buckets.filter((b) => b && b.matcher === NOTICE_MATCHER && Array.isArray(b.hooks)
      && b.hooks.length === 1 && b.hooks[0]?.type === "command" && b.hooks[0].command === command
      && b.hooks[0].timeout === NOTICE_TIMEOUT_SECONDS);
    const all = buckets.flatMap((b) => (Array.isArray(b?.hooks) ? b.hooks : [])).filter((h) => isSafedepsNoticeCommand(h?.command));
    if (canonical.length === 1 && all.length === 1) return false;
  }
  removeNotice(config);
  config.hooks = config.hooks ?? {};
  config.hooks[NOTICE_EVENT] = config.hooks[NOTICE_EVENT] ?? [];
  config.hooks[NOTICE_EVENT].push({ matcher: NOTICE_MATCHER, hooks: [{ type: "command", command, timeout: NOTICE_TIMEOUT_SECONDS }] });
  return true;
}

function installInEngine({ engineRoot, configPath, label, engine }) {
  if (!existsSync(engineRoot)) {
    warn(`skip ${label} (${engineRoot} not present)`);
    return;
  }
  const skillsRoot = join(engineRoot, "skills");
  const skillLink = join(skillsRoot, SKILL_ID);
  const preCommand = engineHookCommand(engineRoot, "pre");
  const postCommand = engineHookCommand(engineRoot, "post");

  if (UNINSTALL) {
    removeSymlink(skillLink);
    if (existsSync(configPath)) {
      const cfg = readJson(configPath);
      const pre = removeHook(cfg, "PreToolUse", preCommand) || pruneAllSafedepsHooks(cfg, "PreToolUse", PRE_HOOK_NAME);
      let post = false;
      for (const event of ALL_POST_EVENTS) {
        post = (removeHook(cfg, event, postCommand) || pruneAllSafedepsHooks(cfg, event, POST_HOOK_NAME)) || post;
      }
      const notice = removeNotice(cfg);
      if (pre || post || notice) {
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
  const postEvents = POST_EVENTS_BY_ENGINE[engine];
  const legacyPreRemoved = pruneNonCanonicalSafedepsHooks(cfg, "PreToolUse", preCommand, PRE_HOOK_NAME);
  let legacyPostRemoved = false;
  for (const event of ALL_POST_EVENTS) {
    // An event this engine does not get is pruned whole, canonical command
    // included: a post hook there would be a registration nothing documents.
    const removed = postEvents.includes(event)
      ? pruneNonCanonicalSafedepsHooks(cfg, event, postCommand, POST_HOOK_NAME)
      : pruneAllSafedepsHooks(cfg, event, POST_HOOK_NAME);
    legacyPostRemoved = removed || legacyPostRemoved;
  }
  const preAdded = ensureHook(cfg, "PreToolUse", preCommand, PRE_HOOK_TIMEOUT_SECONDS);
  let postAdded = false;
  for (const event of postEvents) {
    postAdded = ensureHook(cfg, event, postCommand, POST_HOOK_TIMEOUT_SECONDS) || postAdded;
  }
  // The notice changes only when asked: a run without either flag keeps what
  // is there, so reinstalling the gate does not drop a notice the user chose.
  let notice = "kept";
  let noticeChanged = false;
  if (NO_WATCH_NOTICE) {
    noticeChanged = removeNotice(cfg);
    notice = noticeChanged ? "removed" : "none";
  } else if (WATCH_NOTICE && engine === "claude") {
    noticeChanged = ensureNotice(cfg, noticeCommand(engineRoot));
    notice = noticeChanged ? "added" : "ok";
  } else if (WATCH_NOTICE) {
    log(`${label}: no session-start notice is registered here; add the instruction line from SKILL.md ("Re-checking what is already installed") to this engine's instruction file instead`);
  }
  if (legacyPreRemoved || legacyPostRemoved || preAdded || postAdded || noticeChanged) {
    writeJsonWithBackup(configPath, cfg);
    log(`patched ${configPath} (pre=${preAdded ? "added" : "ok"}, post=${postAdded ? "added" : "ok"}, legacy=${legacyPreRemoved || legacyPostRemoved ? "removed" : "ok"}, watch notice=${notice})`);
  } else {
    log(`config ok   ${configPath} (hooks already registered, watch notice=${notice})`);
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

function safedepsOnPath() {
  const dirs = (process.env.PATH || "").split(":").filter(Boolean);
  return dirs.some((d) => {
    try { return existsSync(join(d, "safedeps")); } catch { return false; }
  });
}

// The dependency-install gate is global and now active. The rest of the
// surface (secret-leak lane, dep audit) is per-repo and opt-in — its policy
// lives in each repo. Nudge with a recommended setup; never auto-write.
function printRecommendedSetup() {
  const line = "─".repeat(58);
  const out = [];
  out.push("");
  out.push("Recommended setup");
  out.push(line);
  out.push("  1. Dependency-install gate  ........  ✓ active now (global, all repos)");
  out.push("       Every agent install is checked; for npm the installed");
  out.push("       closure is reorged (rolled back) if it diverges.");
  out.push("");
  out.push("  The rest is per-repo and opt-in. Run these INSIDE a repo:");
  out.push("");
  out.push("  2. Pre-commit gate  ...............  recommended");
  out.push("       safedeps doctor          # diagnose this repo (read-only)");
  out.push("       safedeps doctor --fix    # scaffold .gitleaks.toml + pre-commit, then activate");
  out.push("       → every commit: blocks a secret / real .env (fail-closed).");
  out.push("       → every commit (npm repos): audits deps for vulnerable transitives;");
  out.push("         a real finding blocks, an offline advisory DB only warns + allows.");
  out.push("");
  out.push("  3. No-runner remote guard  ........  recommended opt-in");
  out.push("       safedeps doctor          # reports main direct-push protection posture");
  out.push("       → recommended when installing the no-paid-CI setup: block direct");
  out.push("         pushes to main/default with a branch rule; no Actions runner needed.");
  out.push("");
  out.push("  4. Release / CI gate  .............  cost opt-in");
  out.push("       safedeps gates run       # secret scan + npm dep audit + hook/CI check");
  out.push("       → full-repo sweep for CI / pre-release: scans the whole tree (not just");
  out.push("         the staged diff) and verifies the hooks themselves are installed.");
  out.push("");
  out.push("  5. Re-check what is already installed  ...  recommended");
  out.push("       An advisory can come out after an install. Schedule");
  out.push("       `safedeps watch scan` twice a day (09:00 and 21:00 by default):");
  out.push("       SKILL.md / README → \"Re-checking what is already installed\".");
  out.push("       --watch-notice (Claude Code) tells each new session what it found.");
  out.push("");
  out.push("  Docs: README → \"Two Lanes\"");
  if (!safedepsOnPath()) {
    out.push("");
    out.push("  Note: `safedeps` is not on your PATH. To run the commands above:");
    out.push("    - re-run this installer with --link-bin (adds ~/.local/bin/safedeps), or");
    out.push("    - use the full path: ~/.claude/skills/safedeps/bin/safedeps");
  }
  out.push("");
  console.log(out.join("\n"));
}

// The entry, run the way an engine runs it, on a call it does not judge (a
// Read): it finds the binary for this platform by its own reading of the
// platform, runs it, and has to end with nothing to say. So the installer
// keeps no platform table of its own: the one that decides is the entry's.
function probeEntry() {
  const payload = JSON.stringify({ session_id: "safedeps-install", hook_event_name: "PreToolUse",
    tool_name: "Read", tool_input: { file_path: "/dev/null" } });
  const run = spawnSync(REPO_ENTRY_HOOK, ["pre"], { input: payload, encoding: "utf8" });
  if (run.error || run.status !== 0 || run.stdout.trim() !== "") {
    const said = [run.error ? run.error.message : "", run.stderr, run.stdout].map((x) => (x || "").trim()).filter(Boolean).join("\n");
    return `the entry ${REPO_ENTRY_HOOK} did not answer a call it does not judge (${run.error ? "it did not start" : `exit ${run.status}`}): ${said || "it said nothing"}`;
  }
  return null;
}

// The core has to be there before the hooks
// are registered: a checkout builds it (scripts/build-core.sh, which needs
// cargo), and an installed package must already carry it. Either way the
// entry then has to run it, and a failure stops the install with the reason,
// before any engine config is written. The entry would deny every Bash call
// without it.
function prepareCore() {
  if (existsSync(join(REPO_ROOT, "rust", "Cargo.toml"))) {
    log(`building the core from this checkout: ${BUILD_CORE}`);
    const run = spawnSync("bash", [BUILD_CORE], { stdio: "inherit" });
    if (run.error || run.status !== 0) {
      throw new Error(`scripts/build-core.sh did not build the core (${run.error ? run.error.message : `exit ${run.status}`}); its reason is above. Nothing was registered.`);
    }
    const failed = probeEntry();
    if (failed) throw new Error(`${failed}. Nothing was registered.`);
    log("the entry runs the core it built");
    return;
  }
  const failed = probeEntry();
  if (failed) throw new Error(`${failed}. Reinstall the package. Nothing was registered.`);
  log("the entry runs this package's core");
}

function main() {
  for (const arg of args) {
    if (!KNOWN_ARGS.has(arg)) throw new Error(`unknown argument: ${arg}. Nothing was registered.`);
  }
  if (WATCH_NOTICE && (NO_WATCH_NOTICE || UNINSTALL)) {
    throw new Error("--watch-notice adds the notice and --no-watch-notice or --uninstall removes it; give one. Nothing was registered.");
  }
  if (!UNINSTALL) prepareCore();

  installInEngine({
    engineRoot: join(HOME, ".claude"),
    configPath: join(HOME, ".claude", "settings.json"),
    label: "Claude Code",
    engine: "claude",
  });
  installInEngine({
    engineRoot: join(HOME, ".codex"),
    configPath: join(HOME, ".codex", "hooks.json"),
    label: "Codex CLI",
    engine: "codex",
  });

  maybeLinkBin();
  unlinkBin();

  if (UNINSTALL) {
    log("uninstall done.");
  } else {
    log("install done. New hook events fire on the next session start.");
    printRecommendedSetup();
  }
}

main();
