# Safedeps

> **Treat every install as an unconfirmed block — `safedeps` approves the safe ones, reorgs the rest.**
>
> Pre-approve dependency installs against OSV / CISA KEV / GitHub Advisory, enforce the installed closure from Claude Code and Codex CLI hooks, and auto-rollback any install that diverges from the approved closure. *(한국어 README → [README.ko.md](./README.ko.md))*

## Why "reorg"?

In blockchain networks, a **reorganization (reorg)** invalidates a sequence of blocks and reverts the chain to a previously confirmed safe state. `safedeps` applies the same principle to your `node_modules`: every install is treated as an unconfirmed block candidate until it passes a battery of supply-chain security checks. If anything looks wrong, the tool performs a **reorg** -- rolling back lock files, `package.json`, and `node_modules` to the last confirmed safe snapshot.

No manual review. No leftover malicious code. Fully automatic.

## Distribution Model

Safedeps has two distribution surfaces:

1. **Agent skill + hooks (canonical)** -- the repo itself is the skill folder. `SKILL.md`, hook scripts, provider/ledger libraries, and install helpers stay together in one directory.
2. **npm package (CLI convenience)** -- `@aldegad/safedeps` installs the `safedeps` command. npm does **not** make Claude Code or Codex automatically discover the skill; after npm installation, users still need to run the hook/skill installer or manually register the skill folder.

Use the GitHub release when you want the full skill/hook source tree as the canonical artifact. Use npm when you mainly want a versioned global CLI.

## Two Lanes

`safedeps` owns two security lanes (full design in [`ARCHITECTURE.md`](./ARCHITECTURE.md) §1):

- **Install-time** (the focus of this README) — advisory gate + approved-spec ledger + PreToolUse/PostToolUse hooks + post-install reorg. Per-package, before the install runs.
- **Release-time** — `safedeps gates run`, `safedeps scan secrets [--repo|--worktree|--staged]`, `safedeps audit npm`, `safedeps hooks install|check`. Repo-tree secret scan, dependency audit, and repo-local git hook install/check before push/release. Repo-specific policy (gitleaks config, privacy paths) stays in the target repo; safedeps owns execution. *(Absorbed the former `security-release-gates`.)*

## How It Works

`safedeps` plugs into Claude Code and Codex CLI hooks as a pair of **PreToolUse** and **PostToolUse** hooks that wrap package install commands. The CLI owns provider lookups and the approved-spec ledger; hooks enforce that ledger and run post-install rollback checks. For npm, approval and enforcement cover the full lockfile closure, not just the direct package.

```
                         PreToolUse                          PostToolUse
                  (safedeps-pre-guard.sh)          (safedeps-post-verify.sh)
                            |                                    |
  install cmd ──> [ Advisory/ledger gate ] ──> [ Execute ] ──> [ Verify ]
                     |            |                           |       |
                  Block if      Snapshot                   Clean?  Suspicious?
                  unapproved    lock/manifest files,        |       |
                   or risky     package listings          Confirm  REORG
                                                              |       |
                                    |                       v       v
                                    +--- parent_snapshot_id ──> confirmed
                                                                    |
                                                              Rollback to last
                                                              confirmed snapshot
```

### Phase 1: Advisory Gate + Pre-flight (PreToolUse)

Before an agent installs a dependency, it should run:

```bash
safedeps check <ecosystem> <pkg>@<version|range> --json
```

That command queries OSV (canonical), CISA KEV (hard-risk overlay), and GitHub Advisory (enrichment). For npm, it first creates a script-free temp lockfile with `npm install --package-lock-only --ignore-scripts`, extracts the full dependency closure, and queries OSV `/v1/querybatch`. Clean or safely narrowed specs are written to `~/.safedeps/approved-specs/`; npm entries also record `transitive_specs`.

When Claude Code or Codex CLI is about to run `npm install`, `pip install`, `cargo add`, `go get`, `gem install`, or similar commands, the guard hook:

1. **Snapshots** the current `package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`, and `package.json` into `~/.safedeps/snapshots/`.
2. **Records metadata** including a `parent_snapshot_id` linking to the previous confirmed snapshot (forming a chain, just like blocks).
3. **Captures pre-install state** of `node_modules` (package listings and binary listings) for diff-based detection later.
4. **Fast-checks the approved-spec ledger** for explicit `pkg@version` install commands.
5. **Runs pre-flight checks** and **blocks** the command entirely if it detects:
   - Typosquatting package names (`lod_sh`, `reacct`, `axois`, etc.)
   - Non-standard `--registry` URLs (anything outside `registry.npmjs.org` and `registry.yarnpkg.com`)
   - Piped remote execution patterns (`curl ... | bash`)
   - Explicit disabling of install script safety (`npm config set ignore-scripts false`)

If the ledger gate or a pre-flight check fails, the command is **blocked before execution** -- nothing is installed.

### Phase 2: Post-install verification (`safedeps-post-verify.sh` -- PostToolUse)

After the install command completes, the verify hook analyzes what changed. For npm, this is the primary enforcement surface: it reads the actual `package-lock.json` closure, verifies every package against approved direct entries and their `transitive_specs`, and re-checks the closure with OSV batch.

1. **npm effect gate** -- Reorgs if any lockfile package is unapproved, KEV-blocked, vulnerable, or cannot be verified fail-closed.

2. **Install script analysis** -- Scans newly added packages for `preinstall`, `install`, and `postinstall` scripts containing:
   - Network access (`curl`, `wget`, `fetch`, `http`, `socket`, `dns`)
   - Dynamic code execution (`eval`, `exec`, `spawn`, `child_process`, `Function()`)
   - Sensitive path access (`~/.ssh`, `.env`, `.aws`, `credentials`)
   - Obfuscated content (`base64`, `atob`, `Buffer.from`, hex/unicode escapes)

3. **Lock file diff analysis** -- Compares the snapshotted lock file content against the post-install version:
   - Resolved URLs pointing to non-standard registries
   - Insecure protocols (`http://`, `git://`) in resolved URLs
   - Unusually large dependency additions (>50 new resolved entries, indicating potential dependency confusion)

4. **Binary inspection** -- Checks `node_modules/.bin/` for newly added native binaries (ELF, Mach-O, shared objects) that should not appear in a JavaScript project.

### Phase 3: Confirm or Reorg

- **All checks pass** -- The snapshot is marked as **confirmed** in `~/.safedeps/confirmed`. This becomes the new safe baseline.
- **Any check fails** -- A **reorg** is triggered:
  1. Lock files are restored from the last confirmed snapshot.
  2. `package.json` is restored if it was modified.
  3. `node_modules` is rebuilt via `npm ci` (or `npm install` as fallback) to purge any malicious artifacts.
  4. The event is logged to `~/.safedeps/reorg.log`.
  5. Claude Code receives a system message detailing the detected threats and rollback actions.

## The Blockchain Analogy

| Blockchain Concept | Safedeps Equivalent |
|---|---|
| **Block candidate** | Snapshot taken before `npm install` |
| **Block validation** | Post-install security checks (scripts, lock diff, binaries) |
| **Finality / confirmation** | Snapshot ID written to `~/.safedeps/confirmed` |
| **Chain reorganization** | Rollback to last confirmed snapshot + `node_modules` rebuild |
| **Parent hash linking** | `parent_snapshot_id` in each snapshot's `_meta.json` |
| **Chain pruning** | Old unconfirmed snapshots cleaned up, confirmed chain preserved |

## Detection Rules

| Category | What it catches | Phase | Action |
|---|---|---|---|
| Typosquatting | Known misspelling patterns of popular packages | Pre-flight | **Block** |
| Pipe execution | `curl \| bash`, `wget \| sh` | Pre-flight | **Block** |
| Registry hijack | `--registry` pointing to unofficial sources | Pre-flight | **Block** |
| Script safety bypass | `npm config set ignore-scripts false` | Pre-flight | **Block** |
| Command indirection | `eval "npm install ..."`, subshell expansion, variable indirection | Pre-flight | **Guard** |
| npx/dlx execution | `npx`, `pnpm dlx`, `yarn dlx` package execution | Pre-flight | **Guard** |
| Unapproved transitive dependency | npm `package-lock.json` package missing from direct ledger or `transitive_specs` | Post-install | **Reorg** |
| Vulnerable closure package | npm direct/transitive package with OSV/KEV hit | Post-install | **Reorg** |
| Malicious install scripts | Network calls, `eval`/`exec`, sensitive path access in hooks | Post-install | **Reorg** |
| Obfuscated code | Base64, hex encoding, `Buffer.from` in install scripts | Post-install | **Reorg** |
| Lock file tampering | Resolved URLs from non-standard registries | Post-install | **Reorg** |
| Insecure protocols | `http://` or `git://` resolved URLs | Post-install | **Reorg** |
| Dependency confusion | >50 new dependencies in a single install | Post-install | **Reorg** |
| Native binaries | Compiled executables in `node_modules/.bin/` | Post-install | **Reorg** |

## Installation

### Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) with hook support
- `jq` -- JSON parsing (hooks exit gracefully if missing)
- `shasum` or `sha256sum` -- hash computation
- `file` (optional) -- binary detection

```bash
# macOS
brew install jq

# Ubuntu / Debian
sudo apt-get install jq
```

### Setup From GitHub (Skill + Hooks)

**1. Clone the repository:**

```bash
git clone https://github.com/aldegad/safedeps.git
cd safedeps
```

**2. Install the skill + hooks:**

```bash
node scripts/install/install-safedeps-hooks.mjs
```

The installer is idempotent. It symlinks the skill into `~/.claude/skills/safedeps` and `~/.codex/skills/safedeps` when those roots exist, patches the matching hook config, and — with `--link-bin` — can also place `safedeps` on PATH through `~/.local/bin`. That PATH link is optional: the hooks name an absolute fallback path in their block messages, so the gate is self-contained and works with zero PATH setup.

**3. Manual hook registration, if needed:**

Edit `.claude/settings.json` (project-level) or `~/.claude/settings.json` (global):

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/skills/safedeps/scripts/safedeps-pre-guard.sh"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/skills/safedeps/scripts/safedeps-post-verify.sh"
          }
        ]
      }
    ]
  }
}
```

**4. Verify permissions:**

```bash
chmod +x ~/.claude/skills/safedeps/scripts/safedeps-pre-guard.sh
chmod +x ~/.claude/skills/safedeps/scripts/safedeps-post-verify.sh
```

That's it. The guard activates automatically whenever Claude Code or Codex CLI runs a package install command.

### Setup From npm (CLI First)

```bash
npm install -g @aldegad/safedeps
safedeps version
```

npm puts `safedeps` on PATH through its standard `bin` entry. It does **not** register the agent skill or hooks for Claude Code / Codex. To enable the hooks from the npm-installed copy, run the installer from the installed package root:

```bash
cd "$(npm root -g)/@aldegad/safedeps"
node scripts/install/install-safedeps-hooks.mjs
```

The installer is idempotent and only adds symlinks/hook entries. The `--link-bin` flag is **only useful when you installed via GitHub clone instead of npm** — npm already places the CLI on PATH, so the flag is redundant in this path.

If you want the skill folder itself to be the canonical local source, prefer the GitHub setup above.

### Daily Re-check With macOS Alerts

Install a per-user LaunchAgent to re-check the approved-spec ledger once per day:

```bash
node scripts/install/install-safedeps-recheck-agent.mjs install --hour 9 --minute 0
```

This runs `safedeps re-check --json` against `~/.safedeps/approved-specs/`. It does not use LLM tokens; it only calls the advisory providers used by safedeps. If a new CVE/KEV is found, a spec is revoked, or a provider check is skipped, the wrapper writes `~/.safedeps/recheck-alerts.jsonl` and raises a macOS notification.

Useful commands:

```bash
node scripts/install/install-safedeps-recheck-agent.mjs status
node scripts/install/install-safedeps-recheck-agent.mjs uninstall
tail -f ~/.safedeps/recheck.log
```

## Real-World Attack Coverage

`safedeps` is designed to catch the patterns behind real supply-chain incidents:

- **`event-stream` (2018)** -- Malicious `postinstall` script with obfuscated code that exfiltrated cryptocurrency wallet keys. Caught by: install script analysis (obfuscation + network access detection).
- **`ua-parser-js` hijack (2021)** -- Compromised package added a `preinstall` script that downloaded and executed cryptominers. Caught by: install script analysis (network access + code execution).
- **`colors` / `faker` sabotage (2022)** -- While these were author-initiated, the abnormal dependency behavior would trigger the dependency explosion check.
- **Typosquatting campaigns** -- Ongoing campaigns publishing packages like `crossenv` (instead of `cross-env`) or `babelcli` (instead of `babel-cli`). Caught by: pre-flight typosquatting pattern matching.
- **Dependency confusion attacks** -- Internal package names published to the public registry with higher version numbers. Caught by: non-standard registry detection + large dependency count changes.

## Logs and Snapshots

| Path | Description |
|---|---|
| `~/.safedeps/reorg.log` | Full reorg event history with timestamps, reasons, and rolled-back files |
| `~/.safedeps/confirmed` | Current confirmed (safe) snapshot ID |
| `~/.safedeps/snapshots/` | All snapshot files (lock files, package.json copies, metadata) |

```bash
# View reorg history
cat ~/.safedeps/reorg.log

# Check current confirmed snapshot
cat ~/.safedeps/confirmed

# List all snapshots
ls -la ~/.safedeps/snapshots/
```

Old unconfirmed snapshots are automatically pruned (keeping the 10 most recent), while the confirmed snapshot chain is always preserved.

## Security Hardening

`safedeps` includes multiple layers of defense against attacks targeting the guard itself:

| Measure | What it prevents |
|---|---|
| **JSON-safe metadata** | `project_dir` is escaped via `jq -Rs` to prevent JSON injection in snapshot metadata |
| **Path canonicalization** | `realpath`/`readlink -f` resolves symlinks and `..` traversal in `cwd` before use |
| **Atomic state files** | Snapshot ID and project directory are written as a single JSON file, preventing TOCTOU races |
| **Stale lock recovery** | Locks older than 60 seconds are automatically removed, preventing permanent DoS from `SIGKILL`/OOM |
| **Project-scoped state** | Each project gets its own confirmed snapshot chain (`confirmed_${dir_hash}`), preventing cross-project interference |
| **Restrictive permissions** | `umask 077` ensures `~/.safedeps/` is readable only by the owner |
| **Indirection detection** | Commands using `eval`, `$()`, or backticks with package manager keywords are treated as install candidates |

## Project Structure

```
safedeps/
  bin/
    safedeps      # CLI -- advisory gate, ledger, revoke, re-check
  lib/
    providers/    # OSV / CISA KEV / GHSA adapters
    ledger/       # approved-spec ledger
  scripts/
    safedeps-pre-guard.sh       # PreToolUse hook -- snapshot + ledger enforcement
    safedeps-post-verify.sh     # PostToolUse hook -- post-install verification + reorg
    install/install-safedeps-hooks.mjs
    install/install-safedeps-recheck-agent.mjs
    install/migrate-safedeps-state.mjs
    safedeps-recheck-alert.sh
    test/
  package.json
  SKILL.md        # Claude Code / Codex skill manifest
  LICENSE         # Apache-2.0
```

## What's Different

`safedeps` intercepts package installs at **the moment an AI coding agent writes the install command** — not at CI scan time, PR review time, or runtime sandbox time. That timing is the core differentiator.

Typical flow:

1. The agent writes `npm install foo@1.2.3` (or any of the other supported install verbs).
2. The PreToolUse hook checks whether that spec is in the approved-spec ledger. If not, it **blocks** the install and returns the exact `safedeps check npm foo@1.2.3` command the agent should run next, in the block reason.
3. The agent runs `safedeps check`. The CLI queries OSV / CISA KEV / GitHub Advisory and, if safe, **adds the spec to the ledger**. KEV matches are hard-block (no override). CVEs with an available patch are auto-narrowed to the fixed version.
4. The agent retries the install. The ledger entry now matches, so the install **proceeds**.
5. After the install, the PostToolUse hook diffs the lockfile, checks install scripts and native binaries, and **auto-reorgs** to the last confirmed snapshot if anything diverged.

With this loop, ordinary package-manager install commands are forced through an advisory check before they run. The hook is a best-effort command heuristic, not a sandbox: unusual wrappers, interpreters, or same-user tampering with local safedeps state are outside the trust boundary until signed ledger enforcement is introduced. No SaaS dependency -- only the local CLI plus public databases (OSV / KEV / GHSA).

## Legacy State Migration (v1 only)

The v1 product was named `npm-reorg-guard` and used `~/.npm-reorg-guard/` as the state directory. v2 moves state to `~/.safedeps/`. A one-shot migration is provided:

```bash
safedeps migrate
```

- If `~/.npm-reorg-guard/` exists, it copies the snapshot chain, confirmed pointers, and logs into `~/.safedeps/` and archives the legacy directory so there is no second active state root.
- If it does not exist, the command is a no-op (fresh v2 users do not need it).

## License

[Apache License 2.0](LICENSE)
