---
name: safedeps
description: Gate dependency installs (npm/pip/cargo/go/gem/maven/nuget) with OSV-backed advisory checks, approved-spec ledger, and post-install reorg rollback. Run `safedeps check <eco> <pkg>@<range>` before any install command.
hooks:
  - type: PreToolUse
    script: scripts/safedeps-pre-guard.sh
  - type: PostToolUse
    script: scripts/safedeps-post-verify.sh
---

# Safedeps

Safedeps protects development dependency installs with a three-phase flow:

1. **Phase 1 — Advisory gate (`safedeps check`)**: query OSV (canonical advisory truth), CISA KEV (overlay), and GitHub Advisory (enrichment) before install. For npm, resolve the full dependency closure with a script-free lockfile probe and OSV `/v1/querybatch`; write the approved direct spec plus `transitive_specs` to `~/.safedeps/approved-specs/<hash>.json` with a 30-day TTL.
2. **Phase 2 — Fast command guard (`scripts/safedeps-pre-guard.sh`)**: the PreToolUse hook does not call providers. It checks the approved-spec ledger for package/version tokens in the about-to-run install command and snapshots dependency truth. Miss or expired → block with a structured message that names the exact `safedeps check` command to run next.
3. **Phase 3 — Effect enforcement + reorg (`scripts/safedeps-post-verify.sh`)**: PostToolUse is the primary enforcement surface for npm. It compares the actual `package-lock.json` closure against direct ledger entries and their `transitive_specs`, re-checks the closure with OSV batch, and rolls back when any package is unapproved/vulnerable or install scripts look suspicious.

> **Release-time lane**: `security-release-gates` 의 release orchestrator 를 `safedeps gates` 로 흡수 완료 — repo-tree 게이트(secret scan, dependency audit, repo git hook/CI check, install-guard presence)를 한 진입점에서 실행한다. repo 의 `security:*` npm script / `scripts/security/*` / gitleaks·npm-audit fallback 을 탐지·orchestrate 한다. 개별 `scan`/`audit`/`hooks`/`git` command 분리와 대상 repo `scripts/security/*` 완전 이관은 후속(plan `safedeps-security-unification` Phase B 잔여/C). 설계 SSoT: `ARCHITECTURE.md` §1 (Two Lanes).

## CLI Reference

```
safedeps check <ecosystem> <pkg>@<version|range> [--json]
safedeps ledger [--json]
safedeps revoke <hash> | <ecosystem> <pkg>@<version> | <pkg>@<version> [--reason <r>] [--json]
safedeps re-check [--json]
safedeps migrate [--keep-legacy]
safedeps gates [run] [--root <repo>] [--strict] [--no-run]
safedeps help [command]
safedeps version
```

**Ecosystems** (OSV-normalized): `npm`, `pypi`, `crates.io`, `go`, `rubygems`, `maven`, `nuget`.

**Exit codes**:

| Code | Meaning |
|---:|---|
| 0 | clean — spec approved, install is safe |
| 2 | CVE found, no patched version available — install blocked, human decision required |
| 3 | CISA KEV match — hard block, install must not proceed |
| 4 | input error or provider unavailable (fail-closed) |

**Global flags**: `--json` (machine-readable, stable schema, no color, no spinner), `--no-color` (disable ANSI colors in human mode).

## For AI Agents

You are the primary user of this skill when you propose `npm install`, `pip install`, `cargo add`, etc. Treat `safedeps check` as a mandatory pre-step. The PreToolUse hook will block the install if you skip it.

### Workflow

1. **Before issuing any install command**, call:

   ```bash
   safedeps check <ecosystem> <pkg>@<range> --json
   ```

   Use `--json` so the output is parseable. Read the `result` field.

   If `safedeps` is not on your PATH, invoke it at the skill path instead — `~/.claude/skills/safedeps/bin/safedeps` (Claude Code) or `~/.codex/skills/safedeps/bin/safedeps` (Codex CLI). The hook's block messages already name a runnable path, so when blocked you never have to resolve this yourself.

2. **Decide from `result`**:

   | `result` | Action |
   |---|---|
   | `clean` / `already_approved` | Proceed with the install. Use `install_hint` verbatim if present (it pins to the exact approved version). |
   | `patched_available` | Approved spec narrowed to a safe version. Replace your install argument with `suggested_spec`. Example: `^14.0.0` → `14.0.5`. |
   | `cve_unpatched` | Do **not** install. Surface the CVE list to the human, propose an alternative package. |
   | `kev_hard_block` | Do **not** install. Recommend an alternative module — the package is actively exploited in the wild. |
   | `provider_unavailable` | OSV is unreachable and there is no fresh cache. Do not install. Retry later or tell the human. |
   | `error` | Argument parsing failed. Fix and retry. |

3. **Issue the install** only after the spec is approved. The hook re-checks the ledger; if the approved version differs from your install argument, the hook will block again — re-narrow and retry.

### JSON schema (stable, agent-facing)

`check` result envelope, common fields:

```json
{
  "command": "check",
  "ecosystem": "npm",
  "package": "@scope/pkg",
  "input_range": "^1.2.0",
  "resolved_version": "1.2.4",
  "result": "clean | already_approved | patched_available | cve_unpatched | kev_hard_block | patched_still_vulnerable | provider_unavailable",
  "approved": true,
  "spec_hash": "sha256:...",
  "expires_at": "2026-06-17T05:39:03Z",
  "install_hint": "install with @scope/pkg@1.2.4"
}
```

`patched_available` adds `"suggested_spec": "1.2.5"`. `kev_hard_block` retains the full `vulnerabilities` and `kev.matches` arrays for evidence. `cve_unpatched` retains `vulnerabilities`.

`ledger` returns `{ "command": "ledger", "count": N, "specs": [...] }` where each spec has `hash`, `ecosystem`, `package`, `version`, `version_range`, `approved_at`, `expires_at`, `approved_by`, `expired` (bool), `revoked` (bool).

`revoke` returns `{ "command": "revoke", "revoked": true, "reason": "...", "spec": {...} }`.

`re-check` returns `{ "command": "re-check", "checked": N, "still_clean": N, "newly_vulnerable": [...], "kev_hit": [...], "revoked": [...] }`.

`migrate` returns `{ "migrated": bool, "legacyRoot": "...", "targetRoot": "...", "copied": N, "skipped": N, "archivedAs": "..." }`.

### When the hook blocks you

`scripts/safedeps-pre-guard.sh` emits a Claude Code / Codex CLI hook decision using the modern PreToolUse schema:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "safedeps: install not approved (ecosystem=npm) — run `safedeps check npm @scope/pkg@^1.2.0` first, then retry the install using the approved version (see install_hint in the check output)."
  }
}
```

Both engines surface `permissionDecisionReason` back to you as the block message. The command quoted inside backticks is already runnable as-is — bare `safedeps` when the CLI is on PATH, otherwise an absolute path. Run it **verbatim** (do not rewrite a full path back down to a bare `safedeps`), parse the `--json` output, and retry the install with the approved version.

### Hard rules

- Never bypass the advisory gate. There is no silent fallback. If the provider is unreachable, fail-closed is the correct outcome.
- KEV (`result: "kev_hard_block"`) is non-negotiable. Recommend an alternative; do not ask the human to override.
- Use `install_hint` or `suggested_spec` verbatim. Do not rewrite the version with a fresh range — that defeats the spec lock.

## For Humans

Default output is Korean + ANSI color + braille spinner during long calls. Designed for terminal use, no flags needed.

```bash
$ safedeps check npm "@scope/pkg@^14.0.0"
· 버전 해석 중 (@scope/pkg@^14.0.0)
· 취약점 조회 중 (OSV / KEV / GHSA)
⚠ @scope/pkg@14.0.3 에 2 개 CVE — 안전 버전 14.0.5 으로 좁혀 재조회합니다.
· 14.0.5 재조회 중
✓ @scope/pkg@14.0.5 승인 (until 2026-06-17T...)
· ledger: sha256:abc123...

$ safedeps ledger
STATE    ECOSYSTEM    PACKAGE       VERSION    APPROVED              EXPIRES               HASH
ACTIVE   npm          @scope/pkg    14.0.5     2026-05-18T...        2026-06-17T...        sha256:abc...

$ safedeps revoke @scope/pkg@14.0.5 --reason "team policy change"
✓ 취소: npm @scope/pkg@14.0.5

$ safedeps re-check
· 재검증 npm left-pad@1.3.0
· 검증 완료: 1 개 중 1 개 clean
```

### Color legend

- `· gray` — info / progress
- `✓ green` — safe, approved
- `⚠ yellow` — warning, manual decision required
- `✗ red` — hard error or KEV block

Disable color with `--no-color` or `NO_COLOR=1`. Non-TTY pipes also strip color automatically.

## Current Components

- `bin/safedeps` — CLI (this entry point). Bash. Source-loads providers + ledger libs.
- `lib/providers/providers.sh` — OSV / CISA KEV / GitHub Advisory adapters with a single query interface and 24h local cache under `~/.safedeps/cache/`.
- `lib/ledger/ledger.sh` — approved spec JSON ledger I/O under `~/.safedeps/approved-specs/`, deterministic spec hash, TTL checks, atomic writes.
- `scripts/safedeps-pre-guard.sh` — PreToolUse hook. v1 command pattern guard + ledger lookup for install commands.
- `scripts/safedeps-post-verify.sh` — PostToolUse hook. v1 rollback engine + npm effect gate (lockfile closure vs ledger + OSV batch).
- `lib/npm/closure.sh` — npm lockfile closure extraction and script-free temp lockfile resolver.
- `scripts/install/install-safedeps-hooks.mjs` — cross-engine installer. Symlinks `~/.claude/skills/safedeps` and `~/.codex/skills/safedeps`, idempotently patches `~/.claude/settings.json` and `~/.codex/hooks.json`. `--uninstall` removes both.

## Provider Failure Policy

- OSV.dev is primary. Fresh cache may be used for 24h; cache miss or stale cache on OSV failure is fail-closed (`safedeps check` exits 4, hook blocks).
- CISA KEV is an overlay. Stale or unavailable catalog is surfaced as a warning/status, not hidden.
- GitHub Advisory is enrichment. Failure is fail-open only with an observable skipped status and advisory log entry.

## Installation

The cross-engine installer registers the skill + hooks for Claude Code and Codex CLI in one shot. It is idempotent and backs up `settings.json` / `hooks.json` before writing.

```bash
node scripts/install/install-safedeps-hooks.mjs            # install
node scripts/install/install-safedeps-hooks.mjs --uninstall # remove
```

What it does:

- Symlink the repo at `~/.claude/skills/safedeps` (when `~/.claude` exists) and `~/.codex/skills/safedeps` (when `~/.codex` exists).
- Patch `~/.claude/settings.json` `hooks.PreToolUse[matcher=Bash]` and `hooks.PostToolUse[matcher=Bash]` with the canonical script paths.
- Patch `~/.codex/hooks.json` with the same matcher and paths.
- Optionally symlink `~/.local/bin/safedeps -> bin/safedeps` (via `--link-bin`) for a clean `safedeps` on PATH. **Not required** — the hook block messages and this skill fall back to the absolute skill-relative path, so the gate is fully self-contained without any PATH setup.

Manual registration is also supported — see [Claude Code Hooks reference](https://code.claude.com/docs/en/hooks) and [Codex CLI Hooks](https://developers.openai.com/codex/hooks). The canonical script paths are:

- PreToolUse: `<skills-root>/safedeps/scripts/safedeps-pre-guard.sh`
- PostToolUse: `<skills-root>/safedeps/scripts/safedeps-post-verify.sh`

## State

- Approved specs: `~/.safedeps/approved-specs/`
- Provider cache: `~/.safedeps/cache/`
- Reorg snapshots: `~/.safedeps/snapshots/`
- Advisory log: `~/.safedeps/advisory.log`
- Reorg log: `~/.safedeps/reorg.log`

`safedeps` is the canonical skill name, state namespace, and repository name.
