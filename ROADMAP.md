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

- The npm package version in `package.json` is the single source of truth. `bin/safedeps` `SAFEDEPS_VERSION` tracks it and the smoke test reads `package.json` to compare (current: v2.12.1).
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

## v2.12.1 — the command gate's boundary, measured and written down (shipped)

Status: shipped as v2.12.1.

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
- the false-positive corpus from v2.12 stays allowed: quoted idioms, `npm run`, `npx`

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
