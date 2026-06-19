# safedeps

> **Stop your AI coding agent from installing vulnerable or unapproved dependencies — and roll back the ones that slip through.**
>
> `safedeps` gates every dependency install your Claude Code or Codex CLI agent runs. It pre-approves packages against OSV / CISA KEV / GitHub Advisory, re-verifies the closure that actually lands in your lockfile, and auto-rolls-back anything that diverges. Local-only, with zero runtime dependencies. *(한국어 README → [README.ko.md](./README.ko.md))*

- **Pre-approve** — every `pkg@version`, plus its full transitive closure for npm, is cleared against OSV (canonical), CISA KEV, and GitHub Advisory *before* it installs.
- **Enforce the real effect** — after the install, the actual `package-lock.json` closure is re-checked, so a wrapped or obfuscated command can't sneak a package past the gate.
- **Roll back** — anything unapproved or newly-vulnerable is reverted to the last confirmed safe snapshot. On Claude Code the install runs inert (`--ignore-scripts`), so a rejected package's lifecycle scripts never run.

## Quickstart

```bash
# 1. Install the CLI — the npm package is scoped, note the @aldegad/ prefix
npm install -g @aldegad/safedeps

# 2. Wire the hooks into Claude Code / Codex (idempotent)
cd "$(npm root -g)/@aldegad/safedeps" && node scripts/install/install-safedeps-hooks.mjs

# 3. Done — every dependency install your agent runs is now gated.
```

> `safedeps` is the CLI command; the npm package is **`@aldegad/safedeps`** — the unscoped `safedeps` on npm is an unrelated package. Prefer the full skill source tree? See [Installation](#installation).

![safedeps withholds a vulnerable install, then clears the patched version](assets/demo.gif)

## Distribution Model

Safedeps has two distribution surfaces:

1. **Agent skill + hooks (canonical)** -- the repo itself is the skill folder. `SKILL.md`, hook scripts, provider/ledger libraries, and install helpers stay together in one directory.
2. **npm package (CLI convenience)** -- `@aldegad/safedeps` installs the `safedeps` command. npm does **not** make Claude Code or Codex automatically discover the skill; after npm installation, users still need to run the hook/skill installer or manually register the skill folder.

Use the GitHub release when you want the full skill/hook source tree as the canonical artifact. Use npm when you mainly want a versioned global CLI.

Terminology: safedeps is an agent security skill backed by Claude/Codex hooks and a local CLI. It is not a Codex plugin bundle unless it is later wrapped with a plugin manifest.

## Two Lanes

`safedeps` owns two security lanes (full design in [`ARCHITECTURE.md`](./ARCHITECTURE.md) §1):

- **Install-time** (the focus of this README) — advisory check + approved-spec ledger + fast PreToolUse guard + PostToolUse effect enforcement + post-install reorg. Per-package, around the install command and its actual lockfile effect.
- **Release-time** — `safedeps gates run`, `safedeps scan secrets [--repo|--worktree|--staged]`, `safedeps audit [npm|pnpm|yarn|bun]`, `safedeps hooks install|check`. Repo-tree secret scan, dependency audit, repo-local git hook install/check before push/release, plus opt-in remote repository posture checks. Repo-specific policy (gitleaks config, privacy paths) stays in the target repo; safedeps owns local execution. *(Absorbed the former `security-release-gates`.)*

The secret-leak side of the release-time lane is **per-repo and opt-in**. `safedeps doctor` is its repo-entry check: it diagnoses the repo's `.gitleaks` policy, `.githooks/pre-commit`, the active `core.hooksPath`, and scanner availability (and reports the global install-time gate too), then `safedeps doctor --fix` scaffolds a starter policy (`safedeps hooks init`) and activates it (`safedeps hooks install`). That local pre-commit setup is automatic once you choose `--fix`; it does not spend remote CI minutes. The scaffold is non-destructive — an existing repo-owned `.gitleaks.toml` is never overwritten — and the pre-commit hook runs a secret scan (`safedeps scan secrets --staged`) plus, on every commit in a repo with a supported lockfile, a dependency audit (`safedeps audit`, auto-detecting npm/pnpm/yarn/bun): a real finding blocks (fail-closed), while an unreachable advisory DB only warns and lets the commit through (observable offline failover). Remote enforcement is split: blocking direct pushes to `main` with a branch rule is recommended no-runner posture, while GitHub Actions workflows and required status checks remain explicit cost-bearing opt-in because hosted runners can cost money. See [Secret-Leak Lane (per-repo)](#secret-leak-lane-per-repo).

## How It Works

`safedeps` works in two moves around every install:

- **Before** — `safedeps check` clears a package against OSV (canonical), CISA KEV, and GitHub Advisory, then records the approval in a local ledger. For npm it resolves the package's full dependency closure and checks every transitive package too.
- **After** — the PostToolUse hook re-reads what actually landed in `package-lock.json` and reorgs (rolls back) anything that isn't in the ledger or that the advisory databases now flag.

The pre-install command hook (PreToolUse) is a fast advisory nudge — it blocks obvious unapproved installs and risky command forms so the agent gets immediate feedback. But for npm the real authority is the post-install effect gate: it judges what was *actually installed*, not what the command looked like, so a wrapped or obfuscated install command can't slip a package past it.

**Script safety (inert install).** On Claude Code, the PreToolUse hook rewrites an npm install to add `--ignore-scripts`, so the install runs **inert** — packages land on disk but no lifecycle script runs yet. The effect gate then verifies the closure; only if it passes does the PostToolUse hook run `npm rebuild` to execute the now-verified scripts. A package the gate rejects is reorged before any of its scripts run. (This uses the Claude Code hook `updatedInput` capability. Codex CLI does not expose it, so on Codex the install runs normally and the effect gate is detect-and-rollback — a malicious install script can run once before the rollback.)

This effect-primary model is npm-only for now. `pip`, `cargo`, `go`, `gem`, `maven`, and `nuget` stay on the v2.1 command-gate + reorg model until their closure resolvers land.

```
                         PreToolUse                          PostToolUse
                  (safedeps-pre-guard.sh)          (safedeps-post-verify.sh)
                            |                                    |
  install cmd ──> [ Advisory/ledger UX ] ──> [ Execute ] ──> [ npm effect gate ]
                     |            |                           |       |
                  Block obvious Snapshot                  Clean?  Suspicious?
                  misses/risk   lock/manifest files,        |       |
                                package listings          Confirm  REORG
                                                              |       |
                                    |                       v       v
                                    +--- parent_snapshot_id ──> confirmed
                                                                    |
                                                              Rollback to last
                                                              confirmed snapshot
```

### Phase 1: Advisory Check (`safedeps check`)

Before an agent installs a dependency, it should run:

```bash
safedeps check <ecosystem> <pkg>@<version|range> --json
```

That command queries OSV (canonical), CISA KEV (hard-risk overlay), and GitHub Advisory (enrichment). For npm, it first creates a script-free temp lockfile with `npm install --package-lock-only --ignore-scripts`, extracts the full dependency closure, and queries OSV `/v1/querybatch`. Clean or safely narrowed specs are written to `~/.safedeps/approved-specs/`; npm entries also record `transitive_specs`.

### Phase 2: Fast Command Guard + Snapshots (PreToolUse)

When Claude Code or Codex CLI is about to run `npm install`, `pip install`, `cargo add`, `go get`, `gem install`, or similar commands, the guard hook provides a fast advisory/UX layer:

1. **Snapshots** the current `package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`, and `package.json` into `~/.safedeps/snapshots/`.
2. **Records metadata** including a `parent_snapshot_id` linking to the previous confirmed snapshot (forming a chain, just like blocks).
3. **Captures pre-install state** of `node_modules` (package listings and binary listings) for diff-based detection later.
4. **Fast-checks the approved-spec ledger** for explicit `pkg@version` install commands.
5. **Runs pre-flight checks** and **blocks** the command entirely if it detects:
   - Typosquatting package names (`lod_sh`, `reacct`, `axois`, etc.)
   - Non-standard `--registry` URLs (anything outside `registry.npmjs.org` and `registry.yarnpkg.com`)
   - Piped remote execution patterns (`curl ... | bash`)
   - Explicit disabling of install script safety (`npm config set ignore-scripts false`)

If the ledger gate or a pre-flight check fails, the command is **blocked before execution** -- nothing is installed. This command guard is intentionally best-effort; it improves the agent loop and catches direct misses, while npm authority lives in the post-install effect gate.

### Phase 3: Post-install Effect Enforcement (`safedeps-post-verify.sh` -- PostToolUse)

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

### Confirm or Reorg

- **All checks pass** -- The snapshot is marked as **confirmed** in `~/.safedeps/confirmed`. This becomes the new safe baseline.
- **Any check fails** -- A **reorg** is triggered:
  1. Lock files are restored from the last confirmed snapshot.
  2. `package.json` is restored if it was modified.
  3. `node_modules` is rebuilt via `npm ci` (or `npm install` as fallback) to purge any malicious artifacts.
  4. The event is logged to `~/.safedeps/reorg.log`.
  5. Claude Code receives a system message detailing the detected threats and rollback actions.

## Why "reorg"?

The name borrows from blockchain, where a **reorganization (reorg)** invalidates a sequence of unconfirmed blocks and reverts the chain to its last confirmed safe state. `safedeps` treats every install the same way: an unconfirmed block candidate until it passes a battery of supply-chain checks. If the installed effect diverges, the tool performs a **reorg** -- rolling the lock file, `package.json`, and `node_modules` back to the last confirmed safe snapshot.

But the reorg is the **backstop, not the front line.** Most bad installs never reach it: the pre-approval gate *denies* an unapproved or flagged package before it runs, and on Claude Code the install runs **inert** (`--ignore-scripts`) so lifecycle scripts do not execute until the closure verifies clean. The reorg fires for the residual case -- an approved direct package that pulls in an unapproved or vulnerable transitive, or a wrapped command that slips past the advisory layer -- and even then it rolls back files that never got to run.

Fast advisory feedback, observable rollback, and no hidden fallback. The command guard is best-effort UX; the installed effect is the backstop.

## The Blockchain Analogy

| Blockchain Concept | Safedeps Equivalent |
|---|---|
| **Block candidate** | Snapshot taken before `npm install` |
| **Block validation** | Post-install effect checks (npm closure, scripts, lock diff, binaries) |
| **Finality / confirmation** | Snapshot ID written to `~/.safedeps/confirmed` |
| **Chain reorganization** | Rollback to last confirmed snapshot + `node_modules` rebuild |
| **Parent hash linking** | `parent_snapshot_id` in each snapshot's `_meta.json` |
| **Chain pruning** | Old unconfirmed snapshots cleaned up, confirmed chain preserved |

## Detection Rules

| Category | What it catches | Phase | Action |
|---|---|---|---|
| Typosquatting | Known misspelling patterns of popular packages | PreToolUse advisory guard | **Block** |
| Pipe execution | `curl \| bash`, `wget \| sh` | PreToolUse advisory guard | **Block** |
| Registry hijack | `--registry` pointing to unofficial sources | PreToolUse advisory guard | **Block** |
| Script safety bypass | `npm config set ignore-scripts false` | PreToolUse advisory guard | **Block** |
| Command indirection | `eval "npm install ..."`, subshell expansion, variable indirection | PreToolUse advisory guard | **Guard** |
| npx/dlx execution | `npx`, `pnpm dlx`, `yarn dlx` package execution | PreToolUse advisory guard | **Guard** |
| Unapproved transitive dependency | npm `package-lock.json` package missing from direct ledger or `transitive_specs` | PostToolUse npm primary effect gate | **Reorg** |
| Vulnerable closure package | npm direct/transitive package with OSV/KEV hit | PostToolUse npm primary effect gate | **Reorg** |
| Malicious install scripts | Network calls, `eval`/`exec`, sensitive path access in hooks | PostToolUse effect verify | **Reorg** |
| Obfuscated code | Base64, hex encoding, `Buffer.from` in install scripts | PostToolUse effect verify | **Reorg** |
| Lock file tampering | Resolved URLs from non-standard registries | PostToolUse effect verify | **Reorg** |
| Insecure protocols | `http://` or `git://` resolved URLs | PostToolUse effect verify | **Reorg** |
| Dependency confusion | >50 new dependencies in a single install | PostToolUse effect verify | **Reorg** |
| Native binaries | Compiled executables in `node_modules/.bin/` | PostToolUse effect verify | **Reorg** |

## Secret-Leak Lane (per-repo)

The install-time gate is global, but stopping a secret or a real `.env` from being committed is **per-repo** and stays opt-in — its detection policy lives in each repo, not in safedeps. `safedeps doctor` is the entry point that closes that gap.

```bash
# Diagnose this repo's posture (read-only). Exits non-zero if the secret lane has gaps.
$ safedeps doctor
safedeps doctor — repo security posture
repo:    /path/to/repo
profile: public

Secret-leak lane (per-repo)
  ✓ git worktree
  ✗ gitleaks config (.gitleaks.toml)             → safedeps hooks init --root "/path/to/repo"
  ✗ .githooks/pre-commit (present)               → safedeps hooks init --root "/path/to/repo"
  ✗ git hooks active (core.hooksPath=<unset>)    → safedeps hooks install --root "/path/to/repo"
  ✓ secret scanner available (gitleaks)

Dependency-install gate (global, all repos)
  ✓ dependency-install gate installed (~/.claude/skills/safedeps)

Remote repository governance (opt-in; no-runner vs CI-cost)
  ! remote PR security workflow (opt-in; may spend CI minutes)              → safedeps gates run --root "/path/to/repo" --strict
  – main direct-push protection for main (no runner minutes; opt-in)        → no-runner opt-in: require pull requests before updating main; do not require status checks unless CI cost is accepted
  – required PR status checks for main (CI-cost opt-in)                     → cost-bearing opt-in: add a safedeps workflow, then require it before merging main

3 gap(s) in the secret-leak lane.
Fix all at once:  safedeps doctor --fix --root "/path/to/repo"

# Scaffold the starter policy + activate the hooks (non-destructive).
$ safedeps doctor --fix
```

What the lane is made of:

- **`safedeps hooks init`** scaffolds a starter `.gitleaks.toml` (or `.gitleaks.private.toml` for a private repo) and a `.githooks/pre-commit`. Existing files are kept, never overwritten — the repo owns the policy.
- **`safedeps hooks install`** activates the repo-local hooks (`core.hooksPath = .githooks`).
- The **pre-commit hook runs two checks**:
  - **Secret scan** (`safedeps scan secrets --staged`) on every commit, **fail-closed**. If the scanner (local `gitleaks` or Docker) cannot run, it blocks the commit instead of skipping silently.
  - **Dependency audit** (`safedeps audit`) on **every commit** in a repo that has a supported lockfile. It auto-detects the ecosystem from the lockfile(s) present — npm (`package-lock.json`), pnpm (`pnpm-lock.yaml`), yarn (`yarn.lock`), or bun (`bun.lock`) — and delegates to that tool's native audit. This catches a vulnerable direct *or transitive* dependency — including a CVE that was published *after* you installed the package ("looked safe then, flagged now"), the kind of thing a human never reviews by hand. Running it every commit (not only when the lockfile changes) is the point: it re-queries the advisory DB so a newly-disclosed CVE on an already-installed dependency surfaces at the very next commit. The verdict and an availability failure are kept apart: a real finding **blocks** (fail-closed), but if the advisory DB is **unreachable** (offline / registry error) the hook **warns and lets the commit through** — an observable availability failover, never a silent skip. (CI and the daily re-check then re-cover what the offline commit could not verify.)

  The only intentional bypass is `git commit --no-verify`, which the human owns.

The scaffolded `.gitleaks.toml` is a **starter you tune**: it extends gitleaks' default ruleset, adds a rule for a committed `.env` with an assigned secret (the `.env.example`/`.sample`/`.template` variants are allowlisted), and leaves a repo-owned `[allowlist]` block for your fixtures. safedeps owns *execution* — running gitleaks via `safedeps scan secrets` — not the policy content.

`safedeps doctor --json` returns `{ command, repo, profile, gaps, ok, checks[] }`; `gaps`/`ok` reflect the per-repo secret-leak lane only. Remote posture appears as `lane: "remote"` checks, but missing remote workflows, branch rules, or required status checks do not change `ok`. `doctor --fix` is local-only: it scaffolds repo hooks and never creates `.github/workflows`, enables GitHub Actions, or mutates branch protection. A no-runner branch rule that blocks direct pushes to `main` is recommended when the user asks for "install everything that does not cost money"; Actions-backed required checks are not included in that no-cost bundle.

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
    npm/          # lockfile closure resolver
    gates/        # repo-tree lane: scan / audit / hooks / doctor + templates/
  scripts/
    safedeps-pre-guard.sh       # PreToolUse hook -- advisory ledger UX + snapshots
    safedeps-post-verify.sh     # PostToolUse hook -- npm primary effect verification + reorg
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
2. The PreToolUse hook does a fast advisory ledger check. If the direct spec is missing, expired, or obviously risky, it **blocks** the install and returns the exact `safedeps check npm foo@1.2.3` command the agent should run next, in the block reason.
3. The agent runs `safedeps check`. The CLI queries OSV / CISA KEV / GitHub Advisory and, if safe, **adds the spec to the ledger**. KEV matches are hard-block (no override). CVEs with an available patch are auto-narrowed to the fixed version.
4. The agent retries the install. The ledger entry now matches, so the install **proceeds**.
5. After the install, the PostToolUse hook is the npm primary authority: it verifies the actual lockfile closure against direct ledger entries, `transitive_specs`, and OSV batch, then checks install scripts and native binaries and **auto-reorgs** to the last confirmed snapshot if anything diverged.

Every install command gets fast advisory feedback before it runs; every npm install gets closure-level enforcement after it runs. The suspicious package a human would catch at PR review is already caught at install time — and there is no SaaS dependency, only the local CLI plus public databases (OSV / KEV / GHSA).

Two honest boundaries:

- **The command hook is a heuristic, not a sandbox.** Unusual wrappers, shell interpreters, or same-user tampering with local `~/.safedeps` state sit outside its trust boundary. The npm effect gate is the backstop — it catches what the command hook misses, because it inspects the installed result rather than the command text. It is **command-independent**: when an install-looking command leaves no pending state (the PreToolUse parser did not recognize it), the PostToolUse hook still runs the npm closure check against the live `package-lock.json`, so a parser blind spot does not also blind the backstop. Detection is always command-independent; *automatic rollback* of such a parser-missed install needs a prior confirmed-safe snapshot for that project — the first-ever install with no baseline is flagged loudly (systemMessage + advisory log) but not auto-reverted.
- **Effect-primary enforcement is npm-only today.** `pip`, `cargo`, `go`, `gem`, `maven`, and `nuget` stay on the v2.1 command-gate + reorg model until their closure resolvers land.

## Legacy / Migration: v1 `npm-reorg-guard`

The v1 product was named `npm-reorg-guard` and used `~/.npm-reorg-guard/` as the state directory. v2 moves state to `~/.safedeps/`. A one-shot migration is provided:

```bash
safedeps migrate
```

- If `~/.npm-reorg-guard/` exists, it copies the snapshot chain, confirmed pointers, and logs into `~/.safedeps/` and archives the legacy directory so there is no second active state root.
- If it does not exist, the command is a no-op (fresh v2 users do not need it).

## License

[Apache License 2.0](LICENSE)
