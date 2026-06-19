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

Two gates, one skill. Safedeps is an agent security skill backed by Claude/Codex hooks and a local CLI. It is not a Codex plugin bundle unless it is later wrapped with a plugin manifest.

You (the agent) are the primary user — drive both:

- **Install-time gate** — clear every dependency install through an OSV-backed advisory check before it runs.
- **Secret-leak gate** — stop a secret or a real `.env` from being committed (per-repo, local by default).

---

## Install-time gate

The hooks enforce this; you just run `check` first.

- **PreToolUse** blocks an install whose spec is not approved and quotes the exact `safedeps check` to run. On Claude Code it also rewrites an npm install with `--ignore-scripts`, so it runs **inert** until verified; Codex CLI uses detect-and-rollback.
- **PostToolUse** is the npm enforcement authority: it reads the real `package-lock.json` closure, checks every package against the ledger + an OSV batch, and **reorgs** (rolls back) anything unapproved, vulnerable, or with suspicious install scripts. Effect-primary is **npm-only**; pip/cargo/go/gem/maven/nuget use the command-gate + reorg model.

### Before every install, run

```bash
safedeps check <ecosystem> <pkg>@<range> --json
```

- Ecosystems: `npm`, `pypi`, `crates.io`, `go`, `rubygems`, `maven`, `nuget`.
- Not on PATH? Use `~/.claude/skills/safedeps/bin/safedeps` (Claude) or `~/.codex/skills/safedeps/bin/safedeps` (Codex). Block messages already quote a runnable path.

### Then act on `result`

| `result` | Action |
|---|---|
| `clean` / `already_approved` | Install. Use `install_hint` verbatim — it pins the approved version. |
| `patched_available` | Install `suggested_spec` instead (e.g. `^14.0.0` → `14.0.5`). |
| `cve_unpatched` | Do not install. Surface the CVEs, propose an alternative package. |
| `kev_hard_block` | Do not install. Recommend an alternative — actively exploited in the wild. |
| `provider_unavailable` | Do not install. OSV unreachable, no fresh cache. Retry later or tell the human. |
| `error` | Fix the spec (e.g. an unpublished version) and retry. |

Install only after approval. If the approved version differs from your argument, the hook blocks again — re-narrow and retry.

### Rules

- Never bypass the gate. A provider miss is **fail-closed**, never fail-open.
- `kev_hard_block` is non-negotiable — recommend an alternative, never ask the human to override.
- Use `install_hint` / `suggested_spec` verbatim — a fresh range defeats the spec lock.

### When the hook blocks you

The block message is `permissionDecisionReason`. The command quoted in backticks is runnable as-is — run it **verbatim**, parse the `--json` output, and retry the install with the approved version.

---

## Secret-leak gate (per-repo)

The install-time gate is global; this one is per-repo and opt-in. Make it part of entering a repo, so the agent — not a later leak — is on guard. Local setup is allowed to be automatic after `doctor --fix`; remote PR enforcement is not.

```bash
safedeps doctor          # diagnose; exits non-zero if the secret lane has gaps
safedeps doctor --fix    # scaffold the policy + activate the hooks (non-destructive)
```

1. On repo entry, run `safedeps doctor` (`--json` for the `checks` array).
2. Gaps? Run `safedeps doctor --fix`. It scaffolds `.gitleaks.toml` (or `.gitleaks.private.toml`) and `.githooks/pre-commit`, then activates them. Existing repo files are never overwritten.
3. Tune the scaffolded `.gitleaks.toml` for the repo — allowlist fixtures, add rules. You own the policy; safedeps runs it (gitleaks via `safedeps scan secrets`).

The pre-commit hook runs two checks: a secret scan (`safedeps scan secrets --staged`) on every commit (fail-closed), and a dependency audit (`safedeps audit`) on every commit in a repo with a supported lockfile (npm / pnpm / yarn / bun, auto-detected from the lockfile) — so a CVE published *after* you installed a package is caught at the next commit, not weeks later. `audit` exits 0 clean / 1 vulnerable / 2 could-not-run; the hook **blocks** on a real finding (1) but **warns and allows** when the advisory DB is unreachable (2 — observable offline failover). No secret scanner → blocks. The only bypass is the human's `git commit --no-verify`.

Remote repository governance is opt-in and cost-aware. `doctor` may report `lane: "remote"` recommendations for two different things:

- No-runner posture: block direct pushes to `main`/the default branch by requiring pull requests. This is recommended when the human asks for the "no paid CI" setup, but agents still must not mutate remote branch protection unless explicitly told to do so for a specific repo.
- CI-cost posture: add GitHub Actions security workflows and require their status checks. Hosted CI can spend runner minutes; ask the human before adding this enforcement.

Running `safedeps gates run --root <repo> --strict` locally is the safe first step.

---

## CLI reference

```
safedeps check <ecosystem> <pkg>@<version|range> [--json]
safedeps ledger [--json]
safedeps revoke <hash> | <ecosystem> <pkg>@<version> | <pkg>@<version> [--reason <r>] [--json]
safedeps re-check [--json]
safedeps doctor [--root <repo>] [--fix] [--json]
safedeps hooks <install|check|init> [--root <repo>]
safedeps scan secrets [--repo|--worktree|--staged] [--root <repo>]
safedeps audit [npm|pnpm|yarn|bun] [--root <repo>] [--level <low|moderate|high|critical>]
safedeps gates [run] [--root <repo>] [--strict] [--no-run]
safedeps migrate [--keep-legacy]
safedeps help [command]
safedeps version
```

**Global flags**: `--json` (stable machine-readable schema), `--no-color`.

**Exit codes**: `0` clean/approved · `2` CVE, no patch (human decision) · `3` CISA KEV hard block · `4` input error or provider unavailable (fail-closed).

---

## JSON schemas (agent-facing)

`check`:

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

- `patched_available` adds `suggested_spec`. `kev_hard_block` keeps `vulnerabilities` + `kev.matches`. `cve_unpatched` keeps `vulnerabilities`.

`doctor`:

```json
{
  "command": "doctor",
  "repo": "/path/to/repo",
  "profile": "public | private",
  "gaps": 0,
  "ok": true,
  "checks": [
    { "lane": "secret | deps | remote", "status": "ok | gap | na", "label": "...", "remedy": "safedeps hooks init ..." }
  ]
}
```

- `gaps` / `ok` reflect the per-repo secret-leak lane only; missing global (`deps`) or remote PR (`remote`) posture checks do not change `ok`.

`ledger`, `revoke`, `re-check`, `migrate` each return a `{ "command": "...", ... }` envelope; run `safedeps help <command>` for the fields.

---

Human terminal guide, install steps, and internal design: [`README.md`](./README.md), [`ARCHITECTURE.md`](./ARCHITECTURE.md). `safedeps` is the canonical skill name, state namespace, and repository name.
