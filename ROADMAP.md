# Safedeps Roadmap

> Timeline and priorities. The **why / how** lives in [`ARCHITECTURE.md`](./ARCHITECTURE.md); the **when / what first** lives here. *(한국어 → [ROADMAP.ko.md](./ROADMAP.ko.md))*

---

## Scope

Safedeps gates **development dependency installs** (npm / pip / cargo / go / gem / maven / nuget). At release time it also runs a repo-tree secret scan, dependency audit, and git-hook install/check (the lane absorbed from the former `security-release-gates`).

Out of scope: OS / system packages, container images, runtime sandboxing, registry integrity, and reputation analysis. Those are different security layers and stay in different tools — see [`ARCHITECTURE.md`](./ARCHITECTURE.md) §1 for the boundary.

---

## v1 — `npm-reorg-guard` (shipped)

- npm-only, self-contained, no external advisory database.
- PreToolUse hook: typosquat / `curl | bash` / non-standard registry pattern blocks.
- PostToolUse hook: lockfile diff + install-script analysis → reorg (rollback) on suspicion.

Limits: npm only, no CVE lookup (pattern matching), evadable by a determined adversary. The GitHub repo has since been renamed `aldegad/safedeps`.

---

## v2 — `safedeps` (shipped, v2.1.x)

The internal engine keeps the v1 `reorg-guard` assets.

### What changed

- **Multi-ecosystem**: npm / yarn / pnpm / pip (poetry, uv, pipenv) / cargo / go / gem / maven / nuget.
- **External advisory databases**: OSV.dev (canonical) + CISA KEV (hard-risk overlay) + GitHub Advisory (enrichment).
- **Three-phase defense**:
  1. Advisory gate (`safedeps check`) — query the advisory databases before the install command is written, decide a safe spec, and record it to the `~/.safedeps/approved-specs/` ledger.
  2. Hook enforcement (`safedeps-pre-guard.sh`) — verify the install matches the ledger.
  3. Post-install reorg (`safedeps-post-verify.sh`) — the v1 engine, rolling back on divergence.
- **Approved-spec TTL** (30 days) + **daily re-check** (revoke + alert when a new CVE appears).
- **No silent fallback**: a provider failure is fail-closed; any override is explicit and observable.

### Milestones (all shipped)

| Milestone | Output |
|---|---|
| `v2.0-doc` | `ARCHITECTURE.md` v2 written and pushed. |
| `v2.1-rename` | Repo / skill id / paths renamed to `safedeps`; `safedeps migrate` moves legacy `~/.npm-reorg-guard` state to `~/.safedeps` and cleans up legacy hooks. |
| `v2.1-providers` | `lib/providers/` — OSV / KEV / GHSA adapters behind one query interface, with a 24h response cache. |
| `v2.1-ledger` | `lib/ledger/` — approved-spec JSON I/O (atomic write, hash, TTL check). |
| `v2.1-cli` | `bin/safedeps` — `check`, `ledger`, `revoke`, `re-check`, `migrate`, `version` subcommands. |
| `v2.1-guard-patch` | `safedeps-pre-guard.sh` — ledger enforcement on top of the v1 pattern blocks. |
| `v2.1-verify-patch` | `safedeps-post-verify.sh` — lockfile-diff comparison against the approved spec on top of the v1 reorg. |
| `v2.1-multi-ecosystem` | pip / cargo / go / gem / maven / nuget command parsing + lockfile snapshots, shared as rollback truth across both hooks. |
| `v2.1-hook-rename` | Hook file namespacing + cross-engine installer (`install-safedeps-hooks.mjs`, idempotent, `--uninstall`). |
| `v2.1-recheck-cron` | Daily re-check LaunchAgent — re-queries every approved spec, revokes + notifies on new CVE/KEV/provider-skip. |
| `v2.1-tests` | End-to-end tests — fixture provider responses drive ledger / hook / re-check / migration checks. |
| `v2.1-release` | npm publish (`@aldegad/safedeps`) + GitHub release. |

### Release notes

- The npm package version in `package.json` is the single source of truth. `bin/safedeps` `SAFEDEPS_VERSION` tracks it and the smoke test reads `package.json` to compare (current: v2.16.0).
- `npm test` runs the release smoke suite; the full fixture E2E lives under `v2.1-tests`.
- The daily re-check uses no LLM tokens. It is opt-in: a macOS `launchd` user agent runs `safedeps re-check --json` daily, installed atomically by `install-safedeps-recheck-agent.mjs`. It writes `~/.safedeps/recheck.log` and `~/.safedeps/recheck-alerts.jsonl` and raises a macOS notification on a new CVE/KEV/revoke/provider-skip/suspected-forgery. Network is used only for OSV / CISA / GHSA queries.

## v2.2 — effect-based enforcement (npm)

Status: shipped as v2.2.0 (npm-first).

### What changed

- **Authority moved to effects**: PostToolUse now reads the actual `package-lock.json` closure and compares every installed `pkg@version` against approved direct specs plus their `transitive_specs`.
- **Full closure approval for npm**: `safedeps check npm <pkg>@<version>` resolves a script-free lockfile in a temp dir with `npm install --package-lock-only --ignore-scripts`, extracts the full closure, and queries OSV `/v1/querybatch`.
- **Batch + cache**: OSV batch responses are written back into the same per `pkg@version` 24h cache used by single-package provider queries.
- **No blind trust for transitives**: a clean direct package with an unapproved or vulnerable transitive dependency is not enough; the full closure must be clean and recorded.
- **PreToolUse demoted to fast UX guard**: command parsing still blocks obvious unapproved install attempts and keeps the bypass regression coverage, but PostToolUse is the primary enforcement surface.
- **Inert install (Claude Code)**: the PreToolUse hook rewrites an npm install to add `--ignore-scripts` via the hook `updatedInput` capability, so the install runs inert; PostToolUse runs `npm rebuild` only after the closure is verified clean, so a rejected package's lifecycle scripts never run. Codex CLI lacks `updatedInput`, so it stays on detect-and-rollback.

### npm-only boundary

This phase covers npm lockfile closure only. pip / cargo / go / gem / maven / nuget keep the v2.1 command/ledger/reorg behavior until each ecosystem has an explicit closure resolver and script/no-execution policy.

### Verification

- closure approval records `transitive_specs`
- unapproved transitive package in `package-lock.json` triggers post-verify reorg
- approved full-closure install passes without false reorg
- heredoc / echo text does not trigger install detection
- existing smoke + fixture E2E regression suite remains green

### Current focus

1. `v2.2.0-release`: merged `safedeps-security-hardening`, tagged `v2.2.0` (GitHub release + `npm publish`).

---

## v2.3 — secret-leak lane doctor + scaffold (shipped)

Status: shipped as v2.3.0.

### What changed

- **`safedeps doctor`** — a repo-entry posture check. It diagnoses the per-repo secret-leak lane (`.gitleaks` policy, `.githooks/pre-commit`, active `core.hooksPath`, scanner availability) and reports the global install-time gate too. Read-only by default, `--json` for agents, exits non-zero when the secret-leak lane has gaps.
- **`safedeps doctor --fix` / `safedeps hooks init`** — scaffolds a starter `.gitleaks.toml` (or `.gitleaks.private.toml`) and `.githooks/pre-commit` from `lib/gates/templates/`, then activates the hooks. Non-destructive: an existing repo-owned policy is never overwritten.
- **Agent-as-security-role framing** — `SKILL.md` makes `safedeps doctor` a repo-entry step so the agent, not a later leak, closes the secret-lane gap. The installer prints a per-repo nudge (no auto-write into repos — the policy boundary stays with the repo).
- **Fail-closed delegation** — the scaffolded `pre-commit` delegates to `safedeps scan secrets --staged` (one canonical scanner path); an unresolvable `safedeps` or a missing scanner blocks the commit rather than skipping silently.

### Design decisions

- `doctor` is holistic but **secret-lane-centric**: its exit code reflects the per-repo lane only; the global dependency gate is reported (`deps` check) but does not gate the repo result.
- safedeps owns **execution**, the repo owns **policy**. Templates are seeds the repo tunes, consistent with the existing Two Lanes invariant.

### Verification

- `safedeps doctor` flags gaps on an unconfigured repo and reports clean after `--fix`
- `hooks init` is non-destructive across a re-run (repo edits survive)
- pre-commit gate denies a committed secret, passes clean and `.env.example` placeholder commits (bypass harness + regression)
- existing smoke + fixture E2E regression suite remains green

---

## v2.4 — fail-closed hooks + supply-chain hardening (shipped)

Status: shipped as v2.4.0.

### What changed

- **Fail-closed gate** — the PreToolUse/PostToolUse hooks no longer `exit 0` (silent pass) when they cannot run. A lock-unavailable install now **denies** fail-closed; an unavoidable `jq`-missing case becomes an **explicit allow-with-warning**; every such outcome is recorded in `~/.safedeps/advisory.log` (observable, per the no-silent-fallback invariant). The PostToolUse path records an un-runnable gate as **UNVERIFIED** rather than a clean pass.
- **`SECURITY.md`** — vulnerability disclosure policy, supported versions, scope, and the by-design security properties (no SaaS, zero deps, no silent fallback).
- **CI hardening** — `actions/*` pinned to commit SHA; the gitleaks download is checksum-verified; a ShellCheck gate (error-clean); a macOS + Linux matrix (the v2.3 `stat` fix proved cross-OS coverage matters); and an `npm pack` step that keeps the zero-dependency property honest.

### Verification

- lock-unavailable install denies fail-closed and logs to `advisory.log`
- jq-missing denies a likely install (best-effort fail-closed) and logs it; only non-install commands fall through
- a missing ledger library denies fail-closed instead of falling through to allow
- ShellCheck (`--severity=error`) is clean across all shell sources
- existing smoke + e2e regression suite remains green on both Linux and macOS

### v2.4.1 — concurrent-install race fix (#5)

The pending state PreToolUse hands to PostToolUse was a single global `current_state` file, so two installs overlapping in one project could clobber each other and the effect gate could verify the wrong install (or skip one). Pending state is now keyed **per install** — `dir_hash` + a hash of the command with the inert-install rewrite normalized out — so PreToolUse and PostToolUse of the same install agree on a key while concurrent installs stay isolated. A concurrency harness (two installs → two pending files; a post consumes only its own) guards it.

---

## v2.5 — pre-commit dependency audit (shipped)

Status: shipped as v2.5.0.

### What changed

- **Pre-commit dependency audit** — the scaffolded `.githooks/pre-commit` now runs `safedeps audit npm` on **every commit** in a repo with an npm lockfile, alongside the secret scan. It catches a vulnerable direct or *transitive* dependency — including a CVE disclosed *after* the package was installed ("looked safe then, flagged now") — at the next commit, by re-querying the advisory DB instead of waiting for the daily re-check. Real usage drove it: a transitive `hono` advisory that Dependabot missed was caught exactly this way.
- **Meaningful `audit npm` exit codes** — `0` clean / `1` vulnerable / `2` could-not-run (no lockfile, npm/jq missing, advisory DB unreachable). This separates the **security verdict** from an **availability failure**; npm audit collapses both into exit 1 on its own.
- **Observable offline failover** — when the advisory DB is unreachable the hook **warns and allows** the commit (exit 2) rather than fail-closing, so a network outage never blocks an offline commit; a real finding (exit 1) still **blocks**. Per the no-silent-fallback invariant the failover is loud (printed to the commit output), and CI / the daily re-check re-cover what the offline commit could not verify.

### Verification

- `audit npm` exit-code contract (clean=0 / vulnerable=1 / unreachable=2), deterministic via a fake npm
- pre-commit blocks a commit carrying a vulnerable dependency; warns + allows when the advisory DB is unreachable
- existing secret-lane + smoke + e2e regression suite remains green

---

## v2.6 — English CLI output + hook hardening (shipped)

Status: shipped as v2.6.1.

### What changed (v2.6.0)

- **English-only agent-facing CLI output** — all CLI and hook messages an agent reads are English, so behavior does not depend on the operator's locale. The README hero gained a demo GIF.

### v2.6.1 — hook timeout + install false-positive hardening

A Codex PostToolUse hook was observed hanging ~600s on an unrelated Bash command. Three root causes, all fixed at the repo SSoT (the installer and the hooks), not just the live global config:

- **Hook timeout, registered and backfilled.** The installer now writes an explicit `timeout` (30s) on both engines' Pre/Post safedeps hooks and backfills it onto existing registrations. Previously it registered hooks with no timeout, and its idempotency check compared only the command — so a re-run could never add a missing timeout. Codex had no timeout cap, so a heavy hook ran unbounded.
- **Install-detection false positives removed.** `command_is_dependency_install` no longer flags bare `npx` / `npx --version`, and the indirection catcher now extracts `eval` and command-substitution payloads and judges by **execution position** instead of matching `$(`/backtick plus a `manager`…`verb` substring anywhere in the raw command. So `echo "npm install …"`, `grep`, heredoc/doc text, and `X=$(date); echo "…npm install…"` no longer create a snapshot. Genuine hidden installs (`eval "npm install …"`, `$(npm install …)`, `… | sh`) are still reduced to ledger specs and denied — fail-closed when no spec can be extracted.
- **Legacy pending fallback bounded.** The PostToolUse legacy/global pending fallback now runs only when the pending project matches the command's cwd and the command looks like an install. A mismatch writes an observable `post-verify SKIP` advisory and no-ops instead of entering closure/OSV verification for an unrelated command.

### Verification

- installer registers and backfills the 30s timeout on both engines (e2e)
- false-positive corpus (grep / echo / heredoc / `node` / `npm run` / `npm view` / `npx --version` / command-substitution + install text in data) produces no snapshot; hidden-install indirection still denies and snapshots (smoke)
- a stale legacy pending plus an unrelated Bash command no-ops with an observable skip (e2e)
- existing smoke + e2e regression suite remains green; zero npm dependencies; effect-primary stays npm-only; no silent fallback

---

## v2.7 — remote PR governance opt-in (shipped)

Status: shipped as v2.7.0.

### What changed

- **Remote repository posture in `doctor`** — `safedeps doctor` now reports a `remote` lane that detects an existing security workflow and names two default-branch postures: no-runner direct-push protection and CI-backed required checks.
- **Cost boundary made explicit** — blocking direct pushes to `main` with a branch rule does not run Actions and is recommended in the no-paid-CI setup. Remote GitHub Actions, CI gitleaks, and required PR checks may spend hosted-runner minutes, so safedeps only reports and nudges. It does not create workflows, query or mutate branch protection, or mark missing remote checks as repo posture failure.
- **Local-first fix remains automatic** — `doctor --fix` still scaffolds `.gitleaks` policy and repo-local pre-commit hooks, but it never creates `.github/workflows`.
- **JSON schema fixed** — `doctor --json` now keeps all checks, including `ok` rows without a remedy (`remedy: null`), and documents `lane: "secret | deps | remote"`.

### Verification

- `doctor` reports missing remote workflow as an opt-in `remote` gap and names no-runner direct-push protection separately from CI-backed required checks
- `doctor --fix` keeps `.github/workflows` absent and reports `ok: true` after the local secret lane is fixed
- existing smoke + e2e regression suite remains green; zero npm dependencies; remote cost-bearing enforcement stays opt-in, while no-runner direct-push protection is recommended posture

---

## v2.8 — adversarial re-audit + global-install fix (shipped)

Status: shipped as v2.8.1.

### v2.8.0 — adversarial re-audit (7 findings)

A multi-agent adversarial re-audit (22 raised → three-lens skeptic verification → 7 confirmed) closed real gaps, each reproduced by a regression test:

- **Parser bypass (critical)** — a leading whitespace or a bare `VAR=val ` env-prefix slipped past the install classifier entirely, disabling the gate, inert rewrite, snapshot, and effect gate at once. `normalize_install_text` now strips leading whitespace and bare assignment prefixes (quoted values excepted, so `msg="run npm install"` stays a non-match) at the single point every classifier passes through.
- **`bun` ungated** — `bun add` / `bun install` matched no classifier. Added to the install pattern, ecosystem detection (→ npm), pipe payloads, and the lock-file set (`bun.lock` / `bun.lockb`).
- **`--prefix` escape** — an install-dir override (`--prefix` / `--cwd` / `--dir` / `--install-dir`) was ignored by the effect gate, which then cleared cwd by mistake. Snapshot and effect-gate targets are redirected to the real install dir (the pending key stays on cwd so the post hook still matches).
- **`producer | sh` plain pipe** — pipe-to-shell detection ran only on command-substitution payloads; it now also runs on the raw command, catching `printf 'pip install x' | sh`.
- **Effect gate depended on the parser** — the README advertised a "command-independent backstop", but it only ran when pending state existed, inheriting the parser's blind spots (doc/code drift). The no-pending branch is now a true command-independent backstop (live `package-lock.json` closure check); auto-rollback runs only against a confirmed baseline, otherwise it fails loud.
- **`launchd` re-check was DOA** — the copied runtime omitted `lib/npm/closure.sh`, so the copied `bin` died at `source` under `set -e` and the daily re-check never ran once. `closure.sh` is now copied, with a post-install runtime smoke guard against future lib drift.
- **Compound inert defeat** — `--ignore-scripts` was appended at the end of the string, so in `npm install evil && npm run build` it landed on the trailing command (the install still ran scripts). Compound commands now inject the flag in place right after the verb, with an observable detect-and-rollback downgrade when in-place injection is not possible.

### v2.8.1 — global-install path resolution

`bin/safedeps` derived its repo dir from `${BASH_SOURCE[0]}` without resolving symlinks. A global install (`npm i -g`, or `~/.local/bin` via the installer's `--link-bin`) puts a file symlink at `<prefix>/bin/safedeps`, so `dirname/..` resolved to the node prefix and every command died at `source <prefix>/lib/providers/providers.sh: No such file or directory`. The bootstrap now walks the symlink chain to the real script (a portable `readlink` loop, not `readlink -f`) before deriving the repo dir. The hooks were unaffected — they are invoked through the skill's directory symlink, where `cd .../scripts && pwd` already lands in the real repo.

### Verification

- the CLI invoked through an npm-style global file symlink resolves its package dir and runs (smoke); the same invocation fails on the pre-fix bootstrap
- the v2.8.0 regression set: leading-space / env-prefix / bun / pipe bypass, compound in-place inert (#7), `--prefix` snapshot target (#3), command-independent backstop (#5)
- existing smoke + e2e regression suite remains green; zero npm dependencies; effect-primary stays npm-only; no silent fallback

---

## v2.9 — multi-ecosystem dependency audit (shipped)

Status: shipped as v2.9.0.

### What changed

- **`safedeps audit` covers npm / pnpm / yarn (Classic + Berry) / bun.** The pre-commit dependency audit was npm-only (it read `package-lock.json` / `npm-shrinkwrap.json` and a pnpm/yarn/bun project got exit 2 — no verdict). `safedeps audit` now auto-detects the ecosystem from the lockfile(s) present and delegates to each tool's native audit, which all query the npm registry advisory endpoint — so the audit lane's advisory source stays consistent across ecosystems (the install-time OSV gate is unchanged and still npm-only).
- **Native delegation, not lockfile parsing.** Each ecosystem's own `audit` command resolves its lockfile and reports advisories; safedeps normalizes the differing report shapes (npm/pnpm `.metadata.vulnerabilities`, yarn Classic NDJSON `auditSummary`, yarn Berry's `yarn npm audit` NDJSON advisory stream, bun's per-package advisory object) into one severity-count verdict. yarn routing detects the major version (Classic 1.x `yarn audit` vs Berry 2+ `yarn npm audit`); bun reads its lockfile so no `node_modules` is required. No new lockfile parsers, and the zero-dependency property is preserved (bun's binary `bun.lockb` never needs parsing).
- **Same exit-code contract, now per ecosystem and aggregate.** `0` clean / `1` vulnerable / `2` could-not-run (no lockfile, tool/jq missing, advisory DB unreachable) holds for every ecosystem. When several lockfiles coexist the aggregate verdict is the worst: a real finding anywhere dominates (1), else an availability failure anywhere (2), else clean (0). No ecosystem is skipped silently.
- **Auto-detecting pre-commit.** The scaffolded `.githooks/pre-commit` now detects any supported lockfile and runs `safedeps audit` (no ecosystem argument). `safedeps audit <eco>` remains for an explicit single-ecosystem run. The offline failover is unchanged: a real finding blocks, an unreachable advisory DB warns and allows.

### Verification

- exit-code contract (clean=0 / vulnerable=1 / unreachable=2) for npm, pnpm, yarn Classic, yarn Berry, and bun, deterministic via fake tools that emit each tool's real report shape — plus aggregate behavior across coexisting lockfiles and bun fail-closed handling of malformed / non-canonical / missing severities
- the scaffolded pre-commit hook blocks a commit carrying a vulnerable pnpm dependency exactly like npm (live integration)
- live-registry sanity: real npm/pnpm/yarn-Classic/bun clean audits return 0; a real pnpm vulnerable audit returns 1; a real Yarn Berry `yarn npm audit` and a real bun audit from a lockfile with no `node_modules` both return 1 on a vulnerable spec
- existing smoke + e2e regression suite remains green; zero npm dependencies; effect-primary stays npm-only; no silent fallback

### v2.9.1 — pre-guard spec-extraction false-positive

The PreToolUse guard extracted `pkg@version` tokens from *every* segment of a compound command, so a token that only appeared in a non-install segment (an `echo` / log line, a path, a comment) was attached to a real install elsewhere and triggered a spurious DENY — e.g. `echo "bumped left-pad@1.0.0"; npm install` was blocked as if installing `left-pad@1.0.0`. Spec extraction is now gated on `command_is_dependency_install` per segment: only a segment that is itself an install command contributes its operands (npx/dlx runners keep their existing operand handling). Real installs, hidden installs (`eval` / `$()` / `… | sh`), and the bypass corpus still DENY; the echoed-mention case now passes. Regression tests cover both the compound (deny names only the real spec) and bare-install (no false deny) cases.

### v2.9.2 — daily re-check alert surfaces suspected ledger forgeries

`safedeps re-check` already flagged ledger entries with no matching `advisory.log` approval record as `suspected_forgery`, but the daily alert wrapper (`safedeps-recheck-alert.sh`) never read that field: a forged entry whose package queries clean counted as `still_clean`, so no alert condition fired and the flag was silently swallowed — exactly the silent-fallback the invariants forbid. The wrapper now counts `suspected_forgery`, includes it in the alert trigger and the notification message, and the alert record carries the flagged entries. Smoke covers both directions: a forgery-only fixture (every other trigger zero) must alert, and a fully clean fixture must append nothing.

Cross-engine validator passes on the same release caught five more holes in the provenance check itself, all reproducible. (1) When `advisory.log` did not exist at all, the check was bypassed entirely (`[[ -f advisory.log ]]` treated file absence as proof of approval) — a missing log is now missing provenance, since every legitimate approval writes the log. (2) The stored ledger `hash` field is attacker-writable, so copying a valid 64-char hash from a legitimate approval let a forged entry for a *different* package borrow that approval's provenance — the canonical hash is now recomputed from the entry's own spec, and a stored-vs-recomputed mismatch is itself flagged (`hash_spec_mismatch`). (3) Log matching used substring `grep -F`, so a hash/package/version *prefix* (or an empty hash) matched a legitimate line. (4) The whole-field fix first used `awk -v`, which interprets backslash escapes in the value, so a forged package field like `fixture-p\141d` normalized to `fixture-pad` and borrowed its approval. Matching is now a pure-bash literal field comparison — no substring, no escape interpretation. (5) The canonical hash joins the three fields with newlines, so a real newline (or other control char) injected into a package/version could shift the field boundary and collide a different tuple onto a legit approval's hash — a spec carrying a control character is now rejected as `malformed_spec` before any hash or provenance comparison runs. e2e regressions cover the no-log, copied-hash, prefix-named, backslash-escape, and control-char forgeries plus the legit-approval-stays-clean case.

---

## v2.10 — Yarn resolution-aware check (shipped)

Status: shipped as v2.10.0.

`safedeps check` judged an npm spec only from its published closure, so a Yarn Berry project that patches a vulnerable transitive dependency through root `resolutions` was denied on a vulnerability it does not actually install. The published closure is the wrong truth for that project — the installed closure is. When the target directory is a Yarn Berry project with a non-empty root `resolutions` entry, `check` now resolves the closure from that project's real `yarn.lock` via `yarn info -A -R --json` instead of probing the registry. Yarn keeps ownership of descriptor-to-locator resolution; safedeps consumes its machine-readable graph rather than re-implementing lockfile resolution.

The resulting approval is project-scoped, not global. The ledger entry carries a `project_context` whose `context_hash` folds in the project directory, the root `resolutions`, and the `yarn.lock` content, so the approval cannot satisfy a lookup from another project or survive a `resolutions`/`yarn.lock` change; a mismatch denies with `context_mismatch`. The PreToolUse guard resolves the same context and folds the same hash into its lookup. Fail-closed behavior is unchanged everywhere else: a declared `resolutions` with an unusable lockfile is an invalid context that denies outright, and a package that cannot be verified in the resolved graph stays deny-only even when its published closure is clean.

## v2.11 — Yarn candidate closure materialization (shipped)

Status: shipped as v2.11.0.

v2.10 could only judge a package that was already in `yarn.lock`, which excluded the case the gate exists for: checking a dependency before adding it. An absent locator fell to `project-closure-unavailable` and became deny-only, so the original release path for a new Yarn dependency was blocked even when the project's own `resolutions` would have resolved it safely.

### What changed

- **Isolated candidate materialization.** When the locator is absent, safedeps builds a private mirror under `mktemp` and copies only the project's canonical resolution inputs: root and workspace `package.json` files, `yarn.lock`, `.yarnrc.yml`, and the `.yarn/releases`, `.yarn/plugins`, and `.yarn/patches` files. `node_modules`, caches, unplugged packages, install state, and VCS data are never copied — they are neither canonical resolution input nor safe to hand to a temporary resolver. The candidate is added to the mirror's manifest only, and Yarn resolves it there with `yarn install --mode=update-lockfile --no-immutable`. That documented mode updates lock resolution without the link step, so no candidate lifecycle script runs.
- **Caller invariance.** The caller's tree is read-only for the whole operation. safedeps re-hashes the project inputs both before and after the Yarn run; a manifest, `resolutions`, config, or lockfile edit landing mid-flight invalidates the candidate rather than producing an approval for a mixed project state.
- **Provenance-bound approval.** The ledger context becomes `yarn-project-materialized-lockfile` and carries `materialization` with the candidate locator, the bound `input_sha256`, the `generated_lockfile_sha256`, the exact Yarn command, and `isolation: "private-project-mirror"`. `safedeps_ledger_validate_json` requires every one of those fields and rejects an entry whose `materialization.input_sha256` disagrees with its context `input_sha256`. Approval truth is therefore neither a registry probe nor a stale lockfile, but the Yarn resolution derived from a hash-bound copy of the caller's own inputs.
- **No fallback.** Any failure to copy inputs, match the mirror to the canonical input hash, invoke Yarn, or resolve the candidate in the generated lockfile denies with `project-candidate-materialization-unavailable`. The published closure is never used as a substitute.

### Verification

- hermetic Yarn project fixture: the candidate approves only when the isolated closure resolves the patched `sharp@0.35.3` / `postcss@8.5.21`; the unpatched `sharp@0.34.5` / `postcss@8.4.31` closure denies
- unavailable materialization denies with no ledger approval and no published-closure probe; a changed input or lock context denies
- caller tree and lockfile hashes are byte-identical before and after; nested `node_modules` is asserted absent from the copied mirror inputs
- existing smoke + e2e regression suite green; zero npm dependencies; effect-primary stays npm-only

---

## v2.12 — npm `overrides` awareness, scoped to its override set (shipped)

Status: shipped as v2.12.0.

`overrides` is the standard npm remediation for a vulnerable transitive, but the closure probe resolved from an empty manifest and never saw it. A repo that had already patched a transitive that way was still denied, so safedeps punished the correct fix. `check` now discovers the consuming repo's `overrides` and applies them to the probe, resolving transitives the way the real install will.

### What changed

- **Overrides reach the probe.** Discovery reads `SAFEDEPS_NPM_OVERRIDES_JSON`, else the nearest `package.json` carrying a non-empty `overrides`, walking up from the working directory and stopping at the repository root. Only concrete pins are honored; `$`-references are dropped, having no meaning in a standalone probe. Failing to apply them is logged rather than silently dropped -- it only makes the check stricter, but an unexplained denial is not observable.
- **The boundary includes worktrees.** A worktree root carries a `.git` file, not a directory, so a directory-only test walked past it and picked up an ancestor's overrides. The walk now matches the Yarn project-context walk-up.
- **The approval is scoped to the override set.** Applying overrides makes the closure a function of the consuming project, and a published-package approval may be global only because it is project-independent. The ledger entry became `npm-overrides-probe`, carrying the project root, the override set, its canonical hash, and a `context_hash` over both; the key folds that hash in. An approval earned in a repo that patched a transitive no longer satisfies the check in a repo that did not, whose real install resolves the vulnerable version. The pre-guard derives the same key, so a scoped approval still passes the gate.

Honoring overrides cannot mask a vulnerability: the probe resolves each one to a concrete version and OSV is queried for that version, so an override pointing at a still-vulnerable release is flagged like any other.

### Verification

- approval scoping live and in tests: patched set approves, the same set reuses its approval, a repo with no overrides is denied, a different override set is denied
- an override pointing at a still-vulnerable version is denied
- pre-guard key parity: allow in the repo that earned the approval, deny in one without those overrides
- hermetic e2e stubs npm so the resolved closure depends on the probe manifest, fixing the whole chain without registry access; the scoping and injection paths are both mutation-verified
- ledger rejects an `npm-overrides-probe` context missing its override-set hash or carrying an empty set

---

## v2.13 — pipe-position hidden-install judgment + guard cost restore (shipped)

Status: shipped as v2.13.0.

The pre-guard's hidden-install detector judged pipe-to-shell by grepping the raw command text. A command that merely *quoted* the idiom — a commit message documenting a repro line — was denied as a hidden install, and two workers hit that on the same day. The fix changes what counts as an execution pipe. This release records that behavior change and restores the guard's constant cost, which the fix had regressed.

### What changed

- **A pipe counts only in execution position.** The pipe-to-shell operator must sit outside quotes and outside heredoc bodies at its own quoting level. The install text is still searched raw, because in a real hidden install it lives inside the producer's quotes by construction. Outer quoting hides inner pipes, so the same check recurses into `sh -c` payloads, `eval` payloads, and command substitutions.
- **Verdict changes a consumer will see** (this guard blocks commits in other repos, so the pass criteria shifted with no version signal until now):
  - *Now allowed:* a commit message or data heredoc quoting `... install ... | sh` as text. These were false-positive denials.
  - *Now denied:* `sh -c "... | sh"` and `eval "... | sh"` wrapped piped installs. The old raw grep required whitespace or end-of-line after the shell name, so a closing quote hugging it (`| sh"`) escaped detection. True-positive detection strictly grew; the substitution, heredoc-redirect, and plain-pipe forms were already caught and still are.
- **Check order restored to cheap-first.** The fix computed the quote-blanked execution view (a quadratic character scan) before the O(n) raw install-text grep, on every command. Both checks are pure predicates, so conjunction order cannot change any verdict — only the cost. The raw grep now runs first and the scan is skipped for the vast majority of commands, which carry no install text at all.

### Verification / measured bounds

- Smoke covers the full case set: 3 quoted-idiom false positives allow, 6 hidden installs (plain pipe, command substitutions, `sh -c`, `eval`, heredoc redirect line) deny. Verdicts were replayed under both check orders in both directions — identical on every case.
- Guard cost on a 6KB benign command: 1.5s before the fix, 2.8s with the fix, 1.4s after the order swap. When install text is present the scan must run and the cost stays ~2.7s at 6KB.
- The PreToolUse hook budget is 30s. The remaining quadratic scanner (compound-command splitting, untouched here) crosses that budget near ~29KB of command text (28KB → 28s measured). That bound predates this release — it sat near ~26KB before the fix — and its linearization is tracked as follow-up work.
- **Crossing the budget is fail-open.** Measured empirically on Claude Code (2026-08-04): a PreToolUse command hook that exceeds its timeout is killed and the tool call proceeds; an in-budget deny from the same hook blocks. So past the size bound this guard silently disappears, and padding a command past it is trivial. For npm the PostToolUse effect gate remains the enforcement authority (with its own 30s budget); for the other ecosystems the command gate is the primary gate, which is why the scanner linearization is tracked as security follow-up, not a nicety. Codex CLI timeout behavior is unmeasured — do not assume parity.
  - **Corrected in v2.15.0 on both halves.** The fail-open is closed at the source: the guard now answers on a budget of its own before the runtime's expires. And the npm sentence above was an assumption about an untimed hook — PostToolUse is killed at its budget too (measured), so npm is not covered past it either. See v2.15.0.

---

## v2.13.1 — the command gate's boundary, measured and written down (shipped)

Status: shipped as v2.13.1.

Five shell forms were reported as command-gate bypasses that old and new code missed alike. The question worth answering was not "can we catch five forms" but "do they get through for one reason or five" -- an earlier enumeration in a sibling tool closed five forms and surfaced nine.

The answer is one reason. The gate recognizes an install by the syntactic carrier that hands text to an interpreter, and that recognition is a closed enumeration applied at one quoting level. Every miss is a carrier outside the list. But fixing "that one spot" does not end the enumeration, because the spot *is* an enumeration: probing the reported five surfaced four more (`| command sh`, a script written then run, `eval` nested inside `sh -c`, a top-level command substitution) without looking hard. The 5-to-9 growth reproduced in a single session.

### What changed

- **One fix, and it is not a new carrier.** `normalize_install_text` already declares that a path-qualified or `env`-prefixed invocation is the bare one. It was applied to the install text and skipped on the consumer side of the pipe, so the two sides of one pipe disagreed about what counts as the same invocation. Normalizing the consumer closes `| /bin/sh`, `| /usr/bin/bash`, `| env sh`, `| env FOO=1 sh`, `| command sh`, and the same forms wrapped in `sh -c`. No new concept, and nothing else in the corpus changed decision.
- **No new carrier syntaxes were added.** A herestring, an `xargs`-built command line, a script written then run, `eval` nested in `sh -c`, and a same-quote nested `sh -c` stay unjudged on purpose. That is where the enumeration grows without converging, and the rule separating the two kinds of change is now written in `ARCHITECTURE.md`.
- **The ecosystem asymmetry is documented.** For npm an unrecognized carrier is *delayed detection*: the effect gate's recognizer is a raw text match with no carrier enumeration, so it fires on the same command and reads the live lockfile. For `pip`, `cargo`, `go`, `gem`, `maven`, and `nuget` nothing is behind the command gate, so the same form is a complete miss recorded as `UNVERIFIED`. Reading a parser gap as npm-shaped was the misreading this fixes.
- **Decoys are separated from gaps.** `sh -c "sh -c "…""` reads as double nesting, but the outer quotes close at the inner ones and nothing installs. `xargs sh -c` without `-I` or `-0` hands the line to `sh` as `$0`. Two of the five reported forms were decoys as written.
- **`scripts/test/consumer-forms.sh`** pins all of it and joins `npm test`.

### Verification

- decision drift measured across the full corpus at `1e33b65` (before the false-positive narrowing), at `main`, and after this fix: the narrowing shrank nothing, and this fix moved six forms from pass to deny and nothing else
- every form's status proved by execution against a fake package manager, so a form counts as a gap only when it actually reaches one
- the npm delayed-detection claim is machine-checked: the same wrapped command that the command gate passes triggers the effect-gate backstop
- the pypi complete-miss claim is machine-checked: `UNVERIFIED` is recorded and no rollback is produced
- battery mutation-verified against the pre-fix tree (red at the first normalization assertion)
- the false-positive corpus from v2.13 stays allowed: quoted idioms, `npm run`, `npx`

## v2.13.2 — the unpinned install is not gated, and now it says so (shipped)

Status: shipped as v2.13.2.

Found while measuring the carrier boundary in v2.13.1, and larger than what that release closed. The ledger gate runs on a parseable `pkg@version` operand. Omit the version and no spec is produced, so the gate never runs. `pip install evil`, `cargo add evil`, `go get example.com/evil`, `gem install evil`, `poetry add`, `uv add`, `bundle add`, and `dotnet add package` all pass. No wrapper is needed — the attacker does not have to reach for a herestring, only to leave the version off.

Two things made it invisible. The code's stated reason is npm-shaped: a bare `npm install` is a lockfile install that names no new package, so falling through is correct for npm, and the effect gate catches the result anyway. That reasoning was carried into the ecosystems where the command gate is the authority, where an unpinned install names a package and nothing is behind the gate. And the direction is inverted — the hidden path denies fail-closed when no spec can be extracted while the plain path allows under the identical condition, so one predicate is read in opposite directions inside one file.

### What changed

- **The ungated install leaves a record.** An install that names a package as a bare operand with no version, in an ecosystem with no effect gate behind the command gate, writes `UNGATED` to `~/.safedeps/advisory.log` with the ecosystem and the command. (The operand-only scope left gaps, closed in v2.14.1.) Until now it passed with no trace, which contradicted the invariant that every bypass must be observable.
- **It changes no verdict.** Refusing every unpinned install is a policy change that would block ordinary `cargo add x` workflows, so it stays the repo owner's decision. The record exists so that decision can be made from evidence.
- **The silence is scoped as carefully as the record.** File-driven installs (`-r`, `-c`, `-e`), bare lockfile installs, npm, and installs pinned in a form the spec extractor reads stay out of the log. That last qualifier matters: the extractor reads `cargo add --vers` but not `cargo install --version`, so a version can be present and the ledger gate still not run -- and the record correctly fires. A record that fires on routine installs is background noise, and background noise is the same as no record.

### Verification

- 68-case corpus replayed against `main`: zero decision change, so the record is verdict-neutral
- both halves pinned in `scripts/test/consumer-forms.sh` — ten named-unpinned installs recorded, twelve routine or already-gated commands silent
- mutation-verified against the tree without the fix (red at the first record assertion)

---

## v2.14.0 — hook entry shim: a broken checkout stops being anonymous (shipped)

Status: shipped as v2.14.0.

The installed hooks run live from the repo checkout through the skill symlink, so a checkout that is temporarily broken (merge conflict markers, a half-saved edit, a missing file) changes hook behavior on the very next Bash call. On 2026-08-04 a real mid-merge window blocked Bash for every session on the machine, and the only explanation anyone saw was a bash parser error; an unrelated session routed the outage as its own infra defect. The failure direction was also luck, not design: a parse error happens to exit 2 (blocking on both engines), while a missing file (127) or a runtime crash (1) is a non-blocking hook failure that silently removes the install gate.

### What changed

- **The registered command is now the entry shim** `scripts/safedeps-hook-entry.sh pre|post`. A healthy hook passes through untouched (measured overhead ~7 ms on a ~34 ms baseline). On any non-zero hook exit the shim classifies the breakage (does not parse / crashed / missing), detects an in-progress merge or rebase in the checkout and says so, and exits 2 with the breadth ("every session on this machine"), the cause, and the recovery path.
- **The hook exit-code contract is now explicit**: the real hooks exit 0 on every designed path; decisions travel as JSON. Any intentional non-zero exit in a hook script is a bug (`AGENTS.md`).
- **The shim's own failure mode is measured, not assumed**: a broken shim degrades to the pre-shim status quo (blocking with a raw parse error) and never to something wider; pinned in the battery.
- **Workflow rule**: never resolve merge conflicts in the main checkout — integrate in a worktree, move `main` fast-forward-only. The shim softens the blast; the discipline removes the window.
- **`scripts/test/hook-entry.sh`** pins the whole contract and joins `npm test`; the installer prunes the legacy direct-path registrations idempotently.

## v2.14.1 — the record had holes where it claimed coverage (shipped)

Status: shipped as v2.14.1.

The v2.13.2 record was validated with three notes. Two of them turned out to be behavior, not wording, and that distinction is the release: fixing them as prose would have narrowed a sentence and left the hole, which is the same invariant violation the record was introduced to end — just relocated from the code to the docs.

### What changed

- **A source flag consumes its argument, not the command.** Seeing `-r`, `-c`, or `-e` silenced the whole install. But `-c` is not a source flag at all — a constraint file only bounds versions while the install target still arrives on the command line — so `pip install -c constraints.txt evil` installed `evil` with no record. `-r requirements.txt evil` and `-e . evil` were silenced the same way. Each flag now consumes exactly its own argument.
- **A URL's `@` is not a version.** The `@` test meant to skip already-pinned tokens also matched the user field of a VCS URL, so `git+ssh://git@host/evil.git` went unrecorded while `git+https://host/evil.git` was recorded — the same install, split by transport.
- **Maven carries its coordinate in a flag.** `-Dartifact=<group>:<name>` never reached an operand walk, so Maven's actual idiom sat outside the record while a form nobody writes (`mvn dependency:get evil`) was inside it. A two-field coordinate is now reported and a three-field one stays quiet. Whether Maven accepts the versionless form is unverified — no Maven on the measuring machine — and for a record the unresolved case resolves toward reporting: a spurious line costs a line, a missing one costs the invariant.
- **Working-tree installs stay out.** `pip install .` and `pip install ./pkg` build from the tree rather than fetching, so they name no package. A module path such as `example.com/evil` is not a local path and stays reported.
- **The docs stopped explaining the boundary by flag.** The line is whether a package is named. The README said file-driven installs "name no package", which was never true of `-c`.
- **`SKILL.md` now states the boundary too.** It is the manifest agents read, and it told them to run `check` first without saying that omitting the version means nothing is checked.

### Verification

- 106-case corpus replayed against v2.13.2: zero decision change, so the fixes stay inside the observability layer
- every boundary pinned in `scripts/test/consumer-forms.sh` from both sides, including the Maven, `git+ssh`, and `-r <file> <pkg>` rows that had no coverage before
- the notes came from an adversarial probe of the record's edges, not from re-reading the code

---

### v2.14.2 — the per-ecosystem flag table (patch on v2.14.1)

The v2.14.1 fix applied pip's flag table to every ecosystem. `-t` and `-f` take a value for pip and are booleans for go (`go get -t`), gem (`--force`), and cargo, so the walk ate the package that followed: `go get -t example.com/evil` went silent while `gem install --force evil` stayed reported — one install split by which spelling the author used. That is exactly the mistake v2.14.1 diagnosed in `-c`, repeated one axis over: grouping flags by shape instead of by meaning. Caught by the validator, not by the author.

Value-consuming flags are now resolved per ecosystem, and an unknown flag is assumed to take no value — guessing wrong that way costs a spurious line, while guessing wrong the other way drops the install this record exists to catch. `-e` consumes nothing at all now: its argument is judged like any other token, so `-e .` falls out as a working-tree build while `-e git+ssh://…` stays the fetch it is. Maven's coordinate flag is also read on either side of the goal.

One boundary is pinned as deliberate rather than fixed: `mvn -Dartifact=… dependency:get` never reaches the record because install *recognition* (`mvn dependency:get`) does not match a flag before the goal. That belongs to command recognition, and widening it is the carrier enumeration `ARCHITECTURE.md` declines to grow.

Verified against a `git archive` of v2.13.2: decisions stay unchanged, and every registry-fetch form recorded then is recorded now. Two forms did move out of the record -- `pip install .` and `pip install ./local-pkg` -- which is the working-tree boundary v2.14.1 declared and the battery pins; they build from the tree rather than fetching. Stating it as a blanket "nothing moved" was wrong twice in this plan's history, so the claim is now scoped to what the battery checks.

---

### v2.14.3 — the same class, third time (patch on v2.14.2)

v2.14.2 announced that value-consuming flags were resolved per ecosystem, but only gated `-t` and `-f`. `-r` and `-c` stayed unconditional, and gem's `-r` is `--remote`, a boolean — so `gem install -r evil` went silent while `gem install --remote evil` was recorded. The same install split by spelling, for the third time in this plan, and this time the shipped prose was ahead of the code rather than behind it.

The whole table is now gated on the pypi family, which is the only one that consumes an argument for any of these spellings.

The verification sentence is also rewritten rather than restated. "Nothing moved from recorded to silent" was falsified twice here: `pip install .` and `pip install ./local-pkg` did move out, which is the working-tree boundary v2.14.1 declared and the battery pins. The claim is now scoped to registry-fetch forms, which is what the battery actually checks. A blanket claim that the author's own corpus cannot falsify is not a verification.

---

### v2.14.4 — the record's short-form trap (patch on v2.14.3)

`-i` was missing from the pypi value-consuming table while `--index-url` was in it. This did not hide an install; it invented one. The mirror URL read as an operand, so `pip install -i <mirror> -r requirements.txt` filed a spurious record and `pip install -i <mirror>` did too. Same defect as the three silences this plan already fixed, pointing the other way — which is the reason both directions now sit in the battery. Fixing one direction leaves the other.

Also corrected: "already-pinned installs stay out" was too strong. The spec extractor reads `cargo add --vers` but not `cargo install --version`, so a version can be present while the ledger gate still does not run — and the record correctly fires. The claim now says "pinned in a form the spec extractor reads", and the surprising-but-true row is pinned in the battery so it does not read as a stray line.

Two more silences are pinned rather than changed: `pip install --index-url <url>` alone names no package, and `pip install /tmp/evil.whl` installs from the filesystem. Both were already correct and now cannot drift unnoticed.

---

### v2.14.5 — pin what is known-odd, and stop citing numbers nobody can check (patch on v2.14.4)

Three validator notes that sat outside the verdict, closed as a set.

`bundle add evil --version 1.0.0` was named alongside the cargo form but only cargo got a battery row. Both are recorded even though a version is present, because the spec extractor reads `cargo add --vers` and neither `cargo install --version` nor `bundle add --version` — so the ledger gate really did not run. Both rows are pinned now, for the same reason: a true-but-surprising record should not read as a stray line.

`pip install --proxy <url> -r requirements.txt` still files a spurious record, and that is pinned rather than fixed. An unknown flag is assumed to take no value; guessing the other way would drop the install this record exists to catch. Widening the value table instead is the enumeration this work was burned by four times. The row makes the trade-off visible instead of leaving it to be rediscovered as a bug.

The last one is about evidence, not code. A previous release cited "159 forms" from a scratch corpus that no reader can reconstruct — the substantive claims held up under independent replay, but the number was decoration, and a number nobody can check reads as verification without being any. `AGENTS.md` now asks for counts a reader can reproduce: the battery's own form count, `npm test`'s ok lines, or a committed corpus.

---

## v2.15.0 — the guard answers on its own budget, so the runtime never kills it mid-judgment (shipped)

Status: shipped as v2.15.0.

v2.13.0 recorded that crossing the 30s hook budget is fail-open, and left it as an argument for linearizing the scanner. That was the wrong conclusion to stop at. Linearization moves the crossing point; it does not decide what happens past it, and past it the gate vanished without a word. Padding a command to ~30KB was the whole attack, and for `pip`, `cargo`, `go`, and `gem` — where the command gate is the authority rather than an advisory layer — that is a universal bypass requiring no knowledge of the scanner at all.

The runtime's timeout behavior is not ours to change. Answering before it fires is.

### What changed

- **The guard keeps a budget of its own**, smaller than the runtime's (default 20s against the registered 30s). It runs its judgment in a child, and if that child has not answered by the deadline the guard answers for it: deny, because an install it could not judge must not run. The runtime never gets to kill it mid-flight, so there is nothing left to fail open.
- **The deny says which kind of deny it is.** "I did not finish looking" and "I looked and found something" are different claims, and a reader who cannot tell them apart learns to route around the gate. The reason string leads with `UNDECIDED, not unsafe`, states that nothing was detected, and says what to do instead. It is recorded to `advisory.log` like every other bypass or unavailability.
- **Commands below the engage size pay nothing.** The machinery costs one integer comparison until the command is large enough to be anywhere near the budget (default 1KB, measured at ~0.1s against a 30s budget — about 300x of headroom). The engage size is a performance gate, not a security boundary; the security boundary is the wall-clock budget, which stays honest on a machine slower or faster than the one these numbers came from.
- **The deadline is polled by the guard itself, not by a watchdog subshell.** A watchdog has to sleep in fixed steps, and killing one while it sits in `sleep` does not return until that sleep expires — measured, that rounded every engaged call up to the next whole second (a 788ms judgment took 1050ms). Polling from the parent starts at 50ms and doubles to 1s, so a fast judgment loses at most the first step.
- **The deadline signals the child's whole process tree, then escalates.** A shell does not act on a signal while a foreground external command is running, and the expensive part of the judgment is exactly such a command — so signalling the child shell alone arrives whenever that command happens to finish, measured 9.1s late against a 20s budget, which spends the entire margin the self budget was there to create. Descendants are resolved from the child's own pid (never by name pattern), signalled TERM, then KILL after a short grace. A deadline that can be outlasted is not a deadline.

### Verification / measured bounds

- Cost curve on the development machine: 1KB → 0.1s, 4KB → 0.68s, 8KB → 2.5s, 16KB → 9.6s, 24KB → 21.4s, 28KB → 29.3s, 32KB → 37.8s. The 30s runtime budget is crossed between 28KB and 32KB, reproducing the bound recorded in v2.13.0 from the other side.
- With the budget engaged, a 32KB command is denied at ~20.2s against a 20s budget, and a 16KB padded `pip install` at ~20.9s: the answer arrives with ~9s still on the runtime's clock. The overshoot is bounded by one poll step (≤1s) **only because the deadline reaches the work and not just the shell** — with the signal sent to the child shell alone the same input answers at ~30s, past the runtime budget, and is therefore still fail-open.
- Machinery overhead where it engages, same input both ways: 4KB 684ms → 820ms, 8KB 2482ms → 2623ms. Below the engage size there is no child and no measurable change.
- `scripts/test/self-budget.sh` pins both directions and joins `npm test`: over-budget commands and padded `pip`/`cargo`/`go`/`gem` installs deny; the deny is marked undecided, is not phrased as a finding, and reaches `advisory.log`; benign commands, `npm run`, unapproved installs, and engaged-but-in-budget commands decide exactly as before.
- The battery carries its own mutation check: with the budget disengaged, the identical over-budget command walks through. Its first draft sized that input ~1.3x the budget and reported a false pass, so the committed version uses a ~5x margin.
- **The first version of this release shipped a defect the battery could not see, and it is worth recording how.** A `trap ... EXIT TERM INT` was added to the guard as insurance against a signalled child leaking the state lock. Naming a signal in `trap` replaces its default disposition, so the child stopped dying at the deadline and ran its judgment to completion: a 16KB padded `pip install` answered at 38.9s against a 30s runtime budget. Every over-budget case in the battery used a 1s budget, which lands the deadline early in the scan where the child is between external commands and takes a signal at once — so the corpus stayed green. The regression that covers it now sizes the input so the deadline lands deep in the scan (12KB against an 11s budget: ~12s enforced, ~17s not) and asserts the *overshoot*, which is the quantity the runtime actually cares about.

### The npm assumption did not survive being measured

v2.13.0 said the PostToolUse effect gate "remains the enforcement authority" for npm past the command gate's budget. That was an assumption about a hook nobody had timed. Measured 2026-08-04 with the same protocol used for PreToolUse — a sandbox project, a hook that records when it starts and when it finishes, a control inside the budget and an experiment past it:

- control (1s work, 5s budget): started and finished.
- experiment (20s work, 5s budget): started, never finished.

**PostToolUse is killed at its budget too.** The effect gate is registered with the same 30s, and its work — `npm ci`, `npm install`, `npm rebuild`, plus an OSV batch over the whole closure — is bounded by the user's project and the network rather than by anything safedeps controls. So npm has the same exposure, and it is worse in kind than the command gate's: the pre-hook's kill lets one unjudged command through, while the post-hook's kill can land in the middle of a rollback.

This release does not fix that. A post-install gate cannot deny — the command has already run — so its answer to "I could not finish" is a different design question, tracked as `safedeps/effect-gate-killed-mid-rollback`. What is fixed here is the claim: the docs no longer say npm is covered past the budget, because it is not.

---

### v2.15.1 — the self budget has a ceiling, because a boundary the user can move is a default (patch on v2.15.0)

v2.15.0's whole claim is that the guard answers on its own budget instead of vanishing past the runtime's. One environment variable undid it: `SAFEDEPS_SELF_BUDGET_SECONDS` had no upper bound, and any value above the registered 30s hook timeout hands the kill back to the runtime — silently, and with the fail-open exactly as it was before the release.

The motive to set such a value is an ordinary one, which is what makes it worth closing. Someone who meets an `UNDECIDED` deny on a large command reads it as "the budget is short" and raises it. No intent to disable anything, and the boundary is gone anyway.

- **The value is clamped to 25s**, and the clamp is one-directional: lower values are honoured as given, because a shorter budget only denies earlier. `SAFEDEPS_RUNTIME_BUDGET_SECONDS` (30) and `SAFEDEPS_SELF_BUDGET_MAX_SECONDS` (25) are named constants next to the budget they bound.
- **The 30s is hardcoded, and the reason is recorded next to it.** The hook payload does not carry the runtime's budget, and registrations from several settings files all fire, so the guard cannot tell which one launched it. It names the number safedeps itself registers — `PRE_HOOK_TIMEOUT_SECONDS` in the installer — and the smoke test pins the two constants together so an installer change cannot leave the guard computing against a stale one. A hand-edited registration below 30s is outside what the constant can know.
- **The 5s of headroom is the guard's cost outside the budget window**, not a round number: up to 1s waiting out the final poll step, up to 0.5s of TERM grace before the KILL, ~0.1s of reap, `jq`, and process start. A 1.6s structural worst case, against 0.73–1.05s measured end to end and flat from 4KB to 256KB of command text (2026-08-04, same machine as the 30s kill measurement).
- **The clamp is observable.** It is announced on stderr, recorded in `advisory.log`, and named in the `UNDECIDED` deny reason. A silently reduced budget would leave the user believing their value is the one running and debugging the next surprise against a number that was never true.

- **The first version of the clamp shipped the same hole in a different grammar, and cross-validation caught it before release.** It validated with `^[0-9]+$` and then let the deadline consume the raw string in `$(( ))`. Bash arithmetic accepts more than that regex does, so `+40`, ` 40` and `0x28` failed validation, skipped the clamp, and evaluated to 40 as the budget anyway — a 64KB command under `+40` produced no answer for 41s, past the runtime's kill. Two grammars for one value is the defect; the value is now normalized once (whitespace and a leading `+` read the way whoever typed them meant it) and only the normalized digits reach arithmetic. Anything else is not a budget: the default is used, which is inside the ceiling, and it is announced on the same channels as the clamp. `10#` keeps `08` from being an octal error.

- **A second cross-validation round found the same shape one layer down, in the value's range rather than its grammar.** With one grammar in place, `^[0-9]+$` still does not count digits, and bash integers are 64-bit and wrap silently. A value that wraps negative is not greater than the ceiling, so it passed the clamp untouched, and the deadline multiplication wrapped it again into a time that never arrives: a 30-digit budget produced no answer for over 600s. Digit count is now checked in the string domain, before arithmetic sees the value — more than nine digits is unambiguously above the ceiling and is clamped as such, so the rule stays "anything above the ceiling is clamped" with no exception for how it was written. Nine digits is about 31 years of seconds.

Verification: `scripts/test/self-budget.sh` gains a 64KB padded `pip install` under a 600s budget. That input's natural scan runs past 300s on the development machine, so only the ceiling can bring the answer back inside the runtime's 30s — it is denied as `UNDECIDED` at ~26s, with the clamp stated in all three places, while a budget under the ceiling passes through untouched and unannounced. The same 64KB case runs again under `" 40"` to pin the grammar fix end to end (25-26s where it was 41s), with cheap parse cases for `+40`, `0x28`, `abc`, `-5`, `4.5` and `08`. The overflow round adds the 30-digit budget at 64KB (over 600s before the digit gate, 26s after), the exact 64-bit bound, and a zero-padded short value that must stay five seconds rather than be judged by its length. `scripts/test/smoke.sh` pins the guard's runtime-budget constant to the installer's registered timeout and asserts the ceiling sits below it.

---

### v2.15.2 — the engage size tunes the deadline, it no longer switches it off (patch on v2.15.1)

v2.15.1 put a ceiling on the budget. It left the condition that decides whether the budget runs at all: `SAFEDEPS_BUDGET_ENGAGE_BYTES`. Raise that past the commands that matter and the judgment runs inline with no deadline — the same fail-open through the knob someone reaches for once the budget stops moving. Measured: a 32KB padded `pip install` answers in 21s at the default engage size and takes 198s with it raised, against a 30s runtime kill either way.

The battery was itself the proof that the door was open: its mutation check disabled the gate by raising the engage size, which is the same gesture a user makes to reduce friction.

- **The engage size is clamped to 4KB.** On the v2.15.0 cost curve a command just under 4KB is judged in about 0.68s, roughly 44x inside the runtime budget. Tuning between the 1KB default and the ceiling is what the knob is for and stays available.
- **Turning the deadline off is a separate act with a separate name.** `SAFEDEPS_BUDGET_DISABLED` does nothing else and announces itself on stderr and in `advisory.log` every time it takes effect. A test that only knows it passes, and not that it catches the defect, is not evidence — so the off switch exists; it just is not the same lever as the tuning knob.
- **Both knobs now go through one reader.** They failed the same way in v2.15.0 and v2.15.1, and a second hand-rolled parser is how they drift apart again. Whitespace, a leading `+`, leading zeros, non-numbers, and values too long for arithmetic are handled identically for both, and every fallback or clamp is announced.
- **The knob reader refuses over-long input before parsing it.** That reader runs before the child spawn, outside the deadline it serves, and it has been the slow path twice. v2.15.1's per-zero strip loop was quadratic (28.9s on 40000 leading zeros, 63.2s on 60000). The regex that replaced it cut the constant about a hundredfold and left the class alone — the reader still quadrupled its time for every doubling of the input (50k 0.34s, 400k 20.2s, 800k 88.0s), so 500000 zeros still burned 224s end to end, and the first fix only moved the failure a digit to the right. What bounds it is a length ceiling on the input, checked in one cheap pass before any pattern touches the string: no reachable value is 32 characters long, since nine digits is already about 31 years of seconds. Refused values are reported by length rather than quoted whole, so a megabyte of padding does not become a megabyte of stderr.

Verification: `scripts/test/self-budget.sh` (30 ok) pins the engage clamp with a padded install that must still be denied on the budget, the announcement on both channels, silent tuning inside the ceiling, a non-numeric engage size falling back to the default, the disable path as the mutation check, and a 500000-zero budget that must still answer inside the runtime budget with its value reported by length rather than quoted.

Still open, recorded rather than fixed: several one-value knobs replace canonical truth rather than tune it — `SAFEDEPS_OSV_API_URL` / `SAFEDEPS_KEV_CATALOG_URL` / `SAFEDEPS_GHSA_API_URL` repoint the advisory source, `SAFEDEPS_NPM_CLOSURE_FIXTURE_JSON` and `SAFEDEPS_YARN_INFO_FIXTURE_NDJSON` replace closure resolution with canned data, `SAFEDEPS_LEDGER_DEFAULT_TTL_DAYS` can make approvals never expire, and `SAFEDEPS_ADVISORY_LOG` repoints the channel that every bypass is supposed to be observable on. These are test seams and mirror support, and the friction story for at least the URLs is real (a network that blocks osv.dev). Tracked as `safedeps/truth-source-knobs-have-no-declaration`.

One more knob is the same shape as the one this release closed, and the enumeration above missed it on the first pass: **`SAFEDEPS_BUDGET_CHILD`**. It is the recursion marker the parent sets on the child it spawns, so exporting it makes the parent believe it *is* the child and skip the deadline entirely — measured, a 12KB padded `pip install` answers in 3s normally and 32s with it exported, with nothing on stderr and nothing in `advisory.log`. It has no ceiling, its name does not say "off switch", and unlike the engage size there is no friction story that leads anyone to it by accident. Cross-validation caught it inside 90 lines of the clamp this release added, which is the honest measure of how far a fresh reader sees past the change they just made. Tracked as `safedeps/budget-child-marker-is-an-unnamed-off-switch`.

---

### v2.15.3 — the parent/child marker moves out of the environment (patch on v2.15.2)

v2.15.2 shipped with this gap named in its release notes rather than implied: `SAFEDEPS_BUDGET_CHILD`, the marker the parent sets on the child it spawns, was an environment variable. Exporting it made the parent believe it was already the child and skip the deadline entirely — measured, a 12KB padded `pip install` answers in 3s normally and 32s with the marker exported, past the 30s runtime kill, with nothing on stderr and nothing in `advisory.log`. A second off switch, beside the named one, with no ceiling, no name that says what it does, and no record.

Cross-validation found it 90 lines from the clamp v2.15.2 added, which is the honest measure of how far a reader sees past the change they just made.

- **The marker travels in argv.** The engines invoke the hook through `safedeps-hook-entry.sh`, which passes no arguments, so there is no route from the environment into the flag — the only process that can set it is the one that spawns the child. Structural, not a check.
- **The old variable is reported, not ignored in silence.** A signal that used to switch the deadline off and now does nothing fails in the other direction if it says nothing: whoever exports it would keep believing the deadline is off. It is announced on stderr and in `advisory.log`, and it points at `SAFEDEPS_BUDGET_DISABLED` for the deliberate act.
- **The deadline machinery is unchanged.** The tree kill resolves descendants from the child's own pid and the reap waits on that pid; neither reads the marker. Verified rather than assumed, because "structurally closed" is a claim like any other.

Verification: through the real hook path (the entry shim) with the marker exported, a 12KB padded `pip install` is denied `UNDECIDED` at 3s against a 2s budget. The deadline landing deep in the scan still overshoots its 11s budget by 1s, the same as before, and leaves no orphaned processes. `scripts/test/self-budget.sh` (32 ok) pins both the deadline surviving an exported marker and the announcement on both channels.

With this landed, the "Known gap" note in the v2.15.2 release stands closed: the deadline has one off switch, it has a name, and it logs.

---

### v2.15.4 — the manual-install docs register what the installer registers (patch on v2.15.3)

`SKILL.md`, `README.md` and `README.ko.md` told a reader doing a manual install to register `safedeps-pre-guard.sh` and `safedeps-post-verify.sh` as the hook commands. The installer registers `safedeps-hook-entry.sh pre|post`, and `AGENTS.md` says the shim is the registered command — the docs had been describing a different installation than the one the tool performs, for as long as the shim has existed. `README.md` even explains the shim two hundred lines above the block that tells you not to use it.

Following the docs still gated installs, so nothing looked broken. What it dropped is the shim's whole job: turning a broken checkout — mid-merge, half-saved, crashed hook — from a silently disabled gate into an explained fail-closed deny. The reader had no way to know they were running without it.

- **The manual JSON registers the shim**, with the same 30s timeout the installer writes, and says in one line why the registered command is the shim rather than the hook.
- **`SKILL.md` no longer declares hooks in its frontmatter.** No runtime reads that block as a registration, so it was a second description of an installation with nothing keeping it true — which is how it drifted. Registration has one channel: the installer.
- **The comparison is machine-made now.** `scripts/test/smoke.sh` reads the installer's own entry-hook constant and fails if either README stops naming it for `pre` and `post`, if either registers a hook script directly, or if `SKILL.md` grows its own declaration again.

Verified by running the documented command as an engine would: the exact string from `README.md`, invoked on a payload, denies an unapproved `pip` install. The drift check was mutation-tested by restoring the old command, which turns it red.

---

### v2.15.5 — the drift check pins the value, not just the string (patch on v2.15.4)

v2.15.4's drift check read the installer's entry-hook constant and failed if the docs stopped naming it. It did not read the timeout. So the docs could keep naming the right command at a number the installer had stopped writing — the same defect one field over from the one that release closed, which is how it was found: the release notes named it as a known limit rather than implying it was covered.

- **The timeout is pinned like the command**, per event, read from the line beside the command rather than from anywhere in the file. The guard already reads `PRE_HOOK_TIMEOUT_SECONDS` for its own ceiling, so this is the same constant read a third time rather than a new place for the truth to live.
- **`SKILL.md` keeps no hook declaration, and that is now written down as a decision.** Claude does document skill-frontmatter hooks, and their schema is event-keyed with `matcher` and `command:` — but they are scoped to the skill's lifecycle and run only while the skill is active, and this gate has to judge every Bash call whether or not the skill was invoked. The documented form cannot carry it. The drift check therefore fails only on the legacy `script:` shape that no schema reads; it deliberately does not forbid the documented shape, because blocking a working feature by grep is not the same as removing a dead one. `AGENTS.md` carries the judgment.

Verification by mutation, three ways: moving the installer constant alone turns the existing guard pin red; moving a doc timeout alone turns the new check red; moving the installer constant **and** the guard constant together — the shape a legitimate budget change takes — leaves the docs behind and is caught by the new check, which is the case the old one missed.

---

### v2.15.6 — the prose names the hook budget once, and that once is pinned (patch on v2.15.5)

v2.15.5 pinned the timeout inside the two registration JSON blocks. The number went on living in six sentences that no check read — `SKILL.md`, both READMEs, both ARCHITECTUREs, `AGENTS.md` — so moving the constant would have left the docs stating a figure the installer no longer writes. The same drift one field over, again, and named as a known limit in the v2.15.5 notes rather than implied covered, which is why it is closed here.

- **One canonical sentence per language states the number**, in the ARCHITECTURE paragraph that already explains where it comes from, and smoke pins that sentence to `PRE_HOOK_TIMEOUT_SECONDS`. Everywhere else the prose names the budget instead of spelling it.
- **Dated measurements keep their figures.** "Killed at their registered timeout (30s when measured, 2026-08-04)" is a fact about a day; it stays true when the constant moves, and it is written so it does not read as the current setting.
- **The rule is proximity, not a list of phrasings.** A sentence putting the installer's own figure next to a budget word must be the canonical one or a dated measurement. Enumerating the ways to phrase a restatement is the shape this repo has been burned by twice; removing the number from the restatements is what actually closes it.

Stated plainly, because a check whose limits are unread gets mistaken for coverage: the canonical pin is what closes this, and it works whatever the prose looks like. The proximity rule is a backstop, and a leaky one — its document list is hardcoded, it matches one written form of the figure and only mid-line, it is line-based, and its measurement exemption tests for the word rather than for a date. Two further axes are outside both checks and need the documented JSON parsed against the installer's output: a second registration block for the same event, and a doc that swaps the `pre` and `post` registrations. All of it is written beside the check, where someone deciding whether to trust it will be looking.

Mutation-verified in an isolated clone: moving both installer constants, the guard constant, and both JSON blocks to 45 while leaving the canonical sentence at 30 turns it red; restoring a numeral to `SKILL.md` turns the proximity rule red.

---

### v2.15.7 — the record cannot be moved out from under the check (patch on v2.15.6)

Three releases closed knobs that could switch the deadline off. The enumeration behind them listed a different family and left it recorded rather than fixed: knobs that replace canonical truth instead of tuning it. The worst of them is `SAFEDEPS_ADVISORY_LOG`, because `advisory.log` is not only where every bypass is written — `re-check` reads it as the oracle for whether a ledger approval ever happened.

Measured: a forged ledger entry that `re-check` flags as `suspected_forgery` on the default path stops being flagged when `SAFEDEPS_ADVISORY_LOG` points at a caller-written file saying the approval happened. The same environment that writes the forgery hands the check its evidence. Nothing in the repo, the docs, the tests, or the installer ever set that variable — it was an unused knob holding open the one file the forgery check depends on.

- **The path is derived from `SAFEDEPS_HOME`.** Record and ledger move together or not at all, which is what keeps the check and the thing it checks in one trust domain. A set-but-ignored variable is reported on stderr and written to the canonical log, because a signal that used to do something and now does nothing must not go quietly inert.
- **The channel is single by construction now.** The hooks always wrote `$SAFEDEPS_HOME/advisory.log` while the CLI and providers honored the variable, so the observation channel could split in two depending on which half of the tool spoke.
- **Moved advisory sources are announced, not refused.** Provider URLs, the closure fixtures, and a non-default ledger TTL are real needs — a mirror on a network that blocks osv.dev, a fixture in this very suite. Each deviation is named once per run in `advisory.log`, at startup rather than on the first provider call, so a command that reaches no provider is still recorded. What is not allowed is a run judged against a moved truth looking exactly like a run judged against OSV.

Verification: the e2e forgery battery gains the relocation case and the moved-source record, and both were mutation-tested in an isolated clone by restoring the environment override — the forgery case turns red.

---

### v2.15.8 — the notice exists on the hook path too (patch on v2.15.7)

v2.15.7 said a run judged against a moved advisory source announces itself. That was true of the CLI. The PreToolUse guard does not source the provider stack, so it had nowhere to say it — a guard run under a moved source wrote nothing. It was harmless only because the guard does not currently reach a provider or a fixture, which is a reason that disappears the day the code changes. A channel that exists only where the claim is already true is not a channel.

- **The notice moved to `lib/truth-sources.sh`**, which the guard sources unconditionally, resolving the path from its own location with plain expansion — no environment variable, and no subshell on a path that runs for every Bash call. Making the source conditional would mean restating the knob list at the call site in order to decide whether to read the knob list, and a second copy is how the first goes stale. Cross-validation rejected the first attempt for exactly the reason the release before it exists: the path came from an environment variable and an unreadable file returned quietly, so pointing it at `/dev/null` left a run under a moved source recording nothing — an unnamed off switch, rebuilt beside the invariant that forbids them. An unreadable library is now an announced unavailability on both channels. One consequence is worth knowing before editing that file: it is sourced on every Bash call, so a parse error in it takes the guard down and the entry shim turns that into a fail-closed deny machine-wide. That is the direction this repo prefers over silence, but it is a wider blast radius than a seventy-line file suggests.
- **Defaults and the comparison live in that one file.** They were duplicated: the URL a run is compared against was written separately from the URL it was assigned, which is the shape a whole release went to fixing one field over.
- **Two more knobs are named.** `SAFEDEPS_NPM_OVERRIDES_JSON` replaces the overrides the closure verdict folds in — the e2e suite says so in its own assertion name — and `SAFEDEPS_RECHECK_FIXTURE_JSON` replaces the re-check output the daily alert reads. Both were outside the v2.15.7 enumeration, which is why that list is now written as a growing one rather than a complete one.

Verification: a guard run under a moved source records it and names the overrides knob; the unmoved control is built by unsetting the suite's own fixtures, so it asserts the notice tracks the environment rather than always firing.

---

### v2.16.0 — the effect gate finishes for ordinary projects, and an unfinished rollback is loud

v2.15.0 measured that PostToolUse is killed at its budget like PreToolUse, and stopped there: the exposure was recorded as structural, because nobody had measured where the effect gate actually crosses 30s. Measured now, with the harness committed as `scripts/measure/effect-gate-cost.sh`, the honest answer was worse than "structural".

The gate rides on two axes. One is the project's lockfile closure. The other was nobody's design: the gate asked the ledger about each closure package separately, and every one of those questions walked the whole approved-spec directory, spawning two or three `jq` processes per ledger file. That is O(closure x ledger).

- real 738-entry ledger: closure of 1 -> 10.8s, 2 -> 18.5s, **4 -> 36.6s**
- empty ledger, a 1081-package application lockfile: 256 -> 24.0s, **512 -> 72.0s, 1024 -> 100.7s**

A closure of four packages is nearly every real `npm install`. So for the machine this was measured on, npm's "delayed detection" was in practice no detection, and a fresh machine with nothing approved still crossed on any ordinary application.

- **The ledger is read once per closure, not once per package.** The predicate did not move: it is jq source that both the single-file validator and the new index embed, so "does the ledger approve this spec" still has one implementation rather than a fast copy and a slow one. Same harness, same ledger, same lockfile: closure of 4 goes 36.6s -> 2.1s, and the ledger stage is flat at ~0.23s from a closure of 4 to 512. Equivalence was checked against the previous per-file reader before landing — 60 specs drawn from the real ledger (owner, transitive, absent), identical verdicts on all 60.
- **A corrupt ledger entry cannot empty the index.** jq stops at the first file it cannot parse, so the index hands files over in chunks and retries a failed chunk one file at a time, naming what broke. An emptied index reads as "nothing is approved", which is a rollback of a clean install — a typo in one ledger file must not cost that.
- **What remains, stated as a range and not as a claim.** The OSV/KEV pass is still per-package. On the same machine with a cold provider cache the gate now crosses 30s near a **390-package** closure. Below that npm's delayed detection is real; above it the runtime kills the gate and the install is not judged. That number is a property of a host, a network, and a cache — the harness is committed so the next reader measures their own instead of inheriting this one.

### An interrupted rollback used to leave nothing at all

The gate cannot deny; by PostToolUse the install has run. Its answer to a bad closure is a rollback, and that rollback wrote its `reorg.log` entry and its message last, after the `node_modules` rebuild — the slowest step.

Measured with `scripts/measure/rollback-kill-state.sh`, which drives both real hooks in a sandbox and kills the post hook at controlled points:

- killed before the rollback: flagged install left in place, `reorg.log` **0 lines**
- killed inside the rollback: project fully reverted, `reorg.log` **0 lines**, no message

The second is the worse one. The first looks like the gate did not run; the second looks like the user's install undid itself for no stated reason, which is how people learn to distrust a gate and route around it.

- **The intent is written before the act.** A journal entry naming the project, the snapshot, the reasons, and the stage is written before the first destructive step and cleared once the rollback has reported itself. An entry that outlives its run *is* the report.
- **The next Bash call reports it — once.** PostToolUse fires on every Bash call, not only on installs, so the report arrives promptly. It moves the entry to `~/.safedeps/rollback-incidents/`, appends `REORG INTERRUPTED` to the same `reorg.log` the finished rollbacks write to, and states which stage was reached and what repairs the tree. Reported once and kept forever, rather than nagged on every later command.
- **This is not atomicity, and does not claim to be.** safedeps does not own the atomicity of an npm tree rebuild. What it owns is whether an unfinished rollback is silent.
- **One message channel.** Engines parse this hook's stdout as a single JSON object, so all of the hook's messages now leave through one emitter; a second object would be a lost message, not an extra one.

### Verification

- `npm test` green. Both directions pinned in the e2e battery: an interrupted rollback is reported, logged, kept as an incident, and not repeated; a completed rollback leaves no journal entry, so a clean run never cries interrupted.
- Ledger index verdicts pinned across owner, transitive, expired, revoked and absent specs, plus an unreadable entry that must not empty the index.
- Both measurement harnesses are committed rather than described, because a number nobody can reproduce is decoration.

### Known gap

Whether the engines kill the hook alone or its whole process tree is **not measured**. Killing the hook process by itself, the `npm ci` it spawned survived and finished the tree; if a runtime kills the process group instead, the tree stays torn. Measuring it means registering a deliberately slow hook on a live machine, which this repo has already had block Bash machine-wide once, so it was left unmeasured on purpose. The journal does not depend on the answer: the record is written before the first destructive act either way.

## v3 (future)

### Ledger tamper resistance

Defends the second-order attack where a malicious package's `postinstall` (running as the user) forges a "B approved" ledger entry so a later install of B skips the advisory check. The package cannot do this *before* it runs, so closing the install-time gate is the first line of defense; this hardens the case where a first compromise already happened.

Approach — **treat OSV as the authority and the ledger as a cache**, plus tamper detection. Cheap, layers onto existing infra:

1. **Re-validate at enforcement / re-check** — verify the stored evidence against OSV instead of trusting the ledger verdict. A forged entry with no real evidence (or for a package OSV reports as vulnerable) is caught and revoked. Reduces the ledger to memoization with OSV as SSoT. *(Still open — per-install network cost tradeoff.)*
2. **Watch `~/.safedeps/` in the post-install scan** — shipped: the post-verify sensitive-path scan flags install scripts touching `~/.safedeps` / `SAFEDEPS_HOME`, so a package that writes the ledger trips a reorg — catching the forge in the act (smoke: ledger-tamper fixture).
3. **Provenance cross-check in daily re-check** — shipped: `re-check` flags ledger entries with no matching `advisory.log` record as `suspected_forgery` (not revoked), and as of v2.9.2 the daily alert wrapper surfaces the flag.

Explicit non-approach: **cryptographic ledger signing is not pursued** — a same-uid attacker can read the signing key and re-sign forgeries, so a local HMAC/signature adds no real boundary. The defense is authority-elsewhere (OSV) + detection, not local secrets.

### Other v3 work

- **Plugin providers** — user-defined advisory sources (internal vuln DB, private registry).
- **Policy file** — `.safedeps.toml` for team policy (auto-block on KEV hit, user confirm on CVSS 7+, per-package allowlist).
- **CI mode** — `safedeps check --ci` for fail-fast in GitHub Actions / CircleCI.
- **Closure expansion beyond npm** — pip / cargo / go / gem / maven / nuget closure resolvers with explicit no-script/no-build policies.
- **Transitive risk score** — deps.dev graph integration; risk visualization beyond direct dependencies.

## v4+ (long-term)

- **Team-shared ledger** — multi-machine approved-spec sync.
- **Agent remediation** — Claude / Codex suggests a safer replacement when a vuln is found (LLM-as-judge).
- **Diff visualization** — dependency-tree diff between two approved-spec snapshots.

---

## History

- 2026-05-18: Initial ROADMAP — v1 → v2 decision plus v3 / v4 outline.
