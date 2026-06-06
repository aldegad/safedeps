# Safedeps Architecture

> Internal design and runtime flow. User-facing setup lives in [`README.md`](./README.md); the skill manifest and hook declarations live in [`SKILL.md`](./SKILL.md). *(한국어 → [ARCHITECTURE.ko.md](./ARCHITECTURE.ko.md))*
>
> **Naming** — the project shipped as `npm-reorg-guard` in v1. v2 unified ecosystems and added the advisory ledger, renaming the product and CLI to **`safedeps`**. The post-install rollback engine still inherits the v1 `reorg-guard` design, and for npm the PostToolUse effect gate is the primary enforcement surface.

---

## Core idea

> Safedeps does not decide at install time from several live truths at once. It approves one dependency closure from provider evidence *first*; then the post-install hook treats the installed lockfile closure as the authority, and reorg rolls back any unapproved or newly-vulnerable effect.

Approval happens **before** the install, against canonical advisory evidence. Enforcement happens **after** the install, against what actually landed on disk. For npm, the full closure (direct + transitive) is checked through OSV `/v1/querybatch` with a 24-hour per-`pkg@version` cache. Closure resolution for the other ecosystems is future work.

---

## 1. Two lanes, one umbrella

safedeps owns security gates at two distinct moments, under one skill. It absorbed the v1 `npm-reorg-guard` (install-time reorg) and then the `security-release-gates` project (release-time checks, 2026-05-24). The goal is not to pile every "security" concern into one file — it is to give the gates a single canonical owner while keeping each lane's responsibility separate (SRP).

```text
┌──────────────────────────────────────────────────────────────────────┐
│                  safedeps — one security umbrella                     │
│                                                                      │
│   INSTALL-TIME lane                    RELEASE-TIME lane              │
│   (during development, per install)    (before a release / push)     │
│   ─────────────────────                ──────────────────            │
│   advisory check   (npm: OSV batch)    safedeps scan secrets         │
│   fast command gate (PreToolUse)       safedeps audit deps           │
│   npm effect gate  (PostToolUse)       safedeps hooks install|check  │
│                                        safedeps git pre-commit       │
│   scope: the package being installed   scope: the whole repo tree    │
│                                        (absorbed from                 │
│                                         security-release-gates)       │
│                                                                      │
│   shared: public DBs (OSV/KEV/GHSA) · local-first · no silent        │
│   fallback (a provider/scanner miss is fail-closed)                  │
└──────────────────────────────────────────────────────────────────────┘
```

- **Install-time lane** (sections 2–13 below) — advisory check, fast command guard, and the npm effect gate + reorg. Per-package and proactive.
- **Release-time lane** — the repo-tree checks from `security-release-gates` (secret scan, dependency audit, repo hook install/check, privacy profile), exposed under the `safedeps scan|audit|hooks|doctor` command namespace. Repo-specific policy (`.gitleaks.toml`, lockfiles) stays in the target repo; safedeps owns execution, install, and verification.

The two lanes differ in timing and scope (one package's effect before/after install vs. the whole repo before a release). They live under one umbrella but stay separated by command namespace.

**The secret-leak side of the release-time lane is per-repo and opt-in.** Its detection policy lives in the target repo, not in safedeps, so it does nothing until the repo provides a `.gitleaks` config and an active `.githooks/pre-commit`. `safedeps doctor` is the repo-entry diagnostic that closes that gap: it reports each piece of the secret-leak lane (`.gitleaks` policy, `pre-commit`, `core.hooksPath`, scanner availability) plus the global install-time gate, and exits non-zero when the per-repo lane has gaps. `safedeps doctor --fix` (= `safedeps hooks init` then `safedeps hooks install`) scaffolds a starter policy from `lib/gates/templates/` and activates the hooks. The scaffold is **non-destructive** — an existing repo-owned config is never overwritten — preserving the invariant that safedeps owns *execution*, not *policy*. The scaffolded `pre-commit` runs two checks. The secret scan (`safedeps scan secrets --staged`) runs on every commit and is fail-closed: an unresolvable `safedeps` or a missing scanner blocks rather than skipping silently. The npm dependency audit (`safedeps audit npm`) also runs on every commit in a repo with an npm lockfile — not only when the lockfile changes — so a CVE disclosed *after* a package was installed is caught at the next commit by re-querying the advisory DB. The audit separates the security verdict from an availability failure via meaningful exit codes (0 clean / 1 vulnerable / 2 could-not-run): a real finding **blocks** (fail-closed), while an unreachable advisory DB makes the hook **warn and allow the commit** — an explicit, observable availability failover (per the no-silent-fallback invariant: it is logged to the commit output and does not change canonical truth), with CI and the daily re-check re-covering what the offline commit could not verify.

**The effect-primary model is npm-only.** `pip`, `cargo`, `go`, `gem`, `maven`, and `nuget` stay on the v2.1 command-gate + reorg model until their closure resolvers land; they are not described as having PostToolUse closure authority.

### Install-time flow

```
   intent ("I want to install this package")
      │
      ▼
   ┌─────────────┐     OSV.dev  ──canonical──►
   │ safedeps    │     CISA KEV ──hard-risk──►   advisory check
   │   check     │     GHSA     ──enrichment─►   (Phase 1)
   └──────┬──────┘
          │  approve
          ▼
   ┌──────────────────────┐
   │ approved-spec ledger │   ~/.safedeps/approved-specs/<hash>.json
   │ ecosystem · pkg@ver  │   + transitive_specs (npm closure)
   │ approved_at/expires  │
   └──────────────────────┘
          │
          ▼
   install command issued ──► PreToolUse hook (fast command guard, Phase 2)
                                  │  ledger match?  ── miss ──► BLOCK + "run safedeps check first"
                                  │  match ──► run
                                  ▼
                              install runs
                                  │
                                  ▼
                              PostToolUse hook (npm effect gate, Phase 3)
                                  │  lockfile closure vs ledger + OSV batch
                                  ├─ approved & clean ──► CONFIRM (new safe baseline)
                                  └─ unapproved / vulnerable ──► REORG (roll back to last confirmed)
```

- **Phase 1 — advisory check.** For npm, safedeps builds a script-free lockfile in a temp dir (`npm install <pkg>@<version> --package-lock-only --ignore-scripts`), extracts the full closure, and queries OSV `/v1/querybatch` for direct and transitive packages together. When clean, the direct ledger entry records `transitive_specs`.
- **Phase 2 — fast command gate.** The PreToolUse hook parses the command, blocks obvious unapproved installs, and snapshots dependency files. It is a best-effort advisory layer that gives the agent immediate feedback — not the final authority. On Claude Code it also rewrites an npm install to add `--ignore-scripts` (via the hook `updatedInput` capability), so the install runs inert and no lifecycle script executes until the effect gate has verified the closure.
- **Phase 3 — npm primary effect gate.** The PostToolUse hook compares the actual `package-lock.json` closure against the ledger's direct entries and their `transitive_specs`, and re-queries OSV in batch. Any unapproved or vulnerable package triggers a reorg to the last confirmed snapshot. This authority is scoped to the npm closure.

---

## 2. Advisory sources — one canonical truth

```
TIER 1 — PRIMARY (canonical truth)
  OSV.dev
    • multi-ecosystem (npm, pip, cargo, go, gem, maven, nuget, …)
    • normalized package@version queries · free JSON API (Google)
    • aggregates GHSA, RustSec, GoVulnDB, and more
    → the first query target for every advisory

TIER 2 — OVERLAY (hard-risk signal)
  CISA KEV (Known Exploited Vulnerabilities)
    • only "confirmed exploited in the wild"
    • cross-referenced with OSV results; a KEV match is a hard block (no override)
    → the line between an ordinary CVE and an urgent one

TIER 3 — ENRICHMENT / CROSS-CHECK
  GitHub Advisory (GHSA) — developer-friendly patched-version metadata; surfaced when it disagrees with OSV
  NVD       — CVE source, CVSS scores, KEV flag (for score-based prioritization)
  deps.dev  — OSV-based package graph metadata (transitive risk)
  Snyk DB   — optional configured feed only (free-quota limited)
```

Design principle: **OSV is the one canonical truth.** Every other source is overlay or enrichment. Treating several live sources as co-equal truths invites cross-fire; instead OSV is the truth, and KEV/GHSA/NVD/deps.dev only surface signals that disagree with OSV or that OSV did not see.

---

## 3. Approved-spec ledger (SSoT)

`~/.safedeps/approved-specs/<hash>.json`:

```json
{
  "hash": "sha256:abc123…",
  "ecosystem": "npm",
  "package": "@jackwener/opencli",
  "version": "1.7.16",
  "version_range": "^1.7.16",
  "approved_at": "2026-05-18T13:00:00Z",
  "expires_at": "2026-06-18T13:00:00Z",
  "approved_by": "user@example.com",
  "evidence": {
    "closure_checked": true,
    "provider": { "type": "osv-querybatch", "results": [] },
    "closure": []
  },
  "transitive_specs": [
    { "ecosystem": "npm", "package": "…", "version": "…" }
  ]
}
```

Key fields:

- `hash` — a deterministic hash of `(ecosystem, package, version)`. The hook derives the same hash from a command and looks the ledger up by it.
- `approved_at` / `expires_at` — lifecycle TTL, 30 days by default. After expiry a new CVE may exist, so the spec is auto-revoked and re-check is forced.
- `evidence` — which source saw what, at approval time. An audit trail.
- `transitive_specs` — the full transitive closure the direct entry approved. The npm effect gate reorgs any `pkg@version` that appears in the lockfile but is in neither the direct entry nor this array.

Lifecycle:

```
approve            install            confirm              re-check (daily)
───────            ───────            ───────              ────────────────
ledger entry  ──►  hook passes   ──►  post-verify match  ──►  OSV re-query
approved_at=now    spec matches       confirmed = true          │
expires_at=+30d                                                 ▼
                                                    still clean ──► extend expiry
                                                    new CVE     ──► revoke + warn (+ optional reorg)
```

---

## 4. Runtime flow in detail

### Phase 1 — `safedeps check <ecosystem> <pkg>@<range>`

```
safedeps check npm "@jackwener/opencli@^1.7.0"
        │
        ├─► ledger lookup ── hit (valid) ──► "already safe, install is fine"
        │                  └ miss/expired ──► proceed to check
        ▼
   resolve range → concrete version(s)
        │
        ▼
   OSV query  ──►  KEV overlay  ──►  GHSA cross-check
        │
        ▼
   classify:
     • clean              → approve
     • patched available  → approve, rewrite spec to the fixed version (^1.7.0 → ^1.7.16)
     • KEV hit            → HARD BLOCK ("exploited in the wild; do not install")
     • CVE, no patch      → WARN (user decision required)
        │
        ▼
   write a new approved-spec ledger entry
```

For npm, "OSV query" runs over the **whole resolved closure** in one `/v1/querybatch` call, and the approved entry records every transitive package in `transitive_specs`.

### Phase 2 — fast command guard (PreToolUse / `safedeps-pre-guard.sh`)

```
Claude runs: npm install @jackwener/opencli@^1.7.16
        │
        ▼
   parse command → ecosystem, package, version_range
   compute spec hash → ledger lookup
        │
        ├─ hit (approved, not expired) ──► PASS (run the command)
        └─ miss / expired ──────────────► BLOCK + "run `safedeps check …` first, then retry"
```

The guard also snapshots lockfiles/manifests and keeps the v1 hardcoded pattern blocks (see section 5). It is fast and advisory; the authority is the post-install gate.

### Phase 3 — npm primary effect gate + reorg (PostToolUse / `safedeps-post-verify.sh`)

```
install done → safedeps-post-verify.sh
        │
        ▼
   read the actual package-lock.json closure
   check every pkg@version against the ledger (direct entries + transitive_specs)
   re-query OSV in batch for the whole closure
   inspect install scripts + native binaries (v1 reorg-guard logic)
        │
        ├─ all approved, clean, no suspicion ──► CONFIRM (new safe baseline)
        └─ unapproved / vulnerable / suspicious ──► REORG:
                 • restore lockfile from the last confirmed snapshot
                 • rm -rf node_modules; reinstall to match the ledger
                 • append to reorg.log; message the agent
```

---

## 5. Threat model

```
ADVISORY CHECK (safedeps check)
  • known-CVE matching (OSV, multi-ecosystem)
  • KEV match → hard block (no user override)
  • patched-available → auto-rewrite the spec to the fixed version
  • transitive vulns recorded in the ledger, so sub-dependency compromise is detectable

FAST COMMAND GUARD (safedeps-pre-guard.sh)
  v1 hardcoded patterns (defense-in-depth): typosquat list · curl|bash pipes ·
  non-standard --registry · install-script-safety disabling · eval/subshell indirection
  + fast advisory ledger check: missing/expired spec → block with advisory-gate guidance

npm PRIMARY EFFECT GATE + REORG (safedeps-post-verify.sh)
  • install-script network / code-execution / sensitive-path access
  • base64 / hex obfuscation
  • non-standard registry resolved URLs · 50+ dependency explosion · native binaries
  • npm lockfile closure diverging from approved specs / transitive_specs → REORG
```

**Install-script timing.** A package's `postinstall` script runs *during* `npm install`. On Claude Code, the Phase 2 hook injects `--ignore-scripts`, so the install is inert and scripts run only after the effect gate confirms the closure (via `npm rebuild`) — a rejected package's scripts never run. On Codex CLI, which does not expose the `updatedInput` hook capability, the install runs normally and a malicious install script can execute once before the post-install reorg cleans up. (The package's *runtime* code is removed before your app runs it on both engines; only install-time lifecycle scripts have this Codex window.)

**What it does not stop (current limits):**

- A zero-day discovered *after* `approved_at` — only the daily re-check catches it, not the install itself.
- Compromise of the npm registry itself.
- An install the user explicitly waved through with `--allow-unverified` (observable, logged).
- An attacker writing to `~/.safedeps/approved-specs/` directly under the same OS user. The ledger is a local convenience cache; until signing/HMAC or install-time re-validation is added, it is not a security boundary against a same-user attacker. (The effect gate's OSV re-query does, however, still catch a forged approval for a *known-vulnerable* package — see [`ROADMAP.md`](./ROADMAP.md) "Ledger tamper resistance".)

---

## 6. Provider failure modes (no silent fallback)

```
OSV.dev — no response / timeout
  • first: use the local provider cache (24h TTL)
  • cache miss → fail-closed (block; "no OSV response, retry")
  • bypass only with explicit --allow-unverified, and it is logged

CISA KEV — no response
  • KEV is a static catalog downloaded once a day; only the local cache is used
  • warn when it is more than 24h stale

GHSA / NVD — no response
  • enrichment only, so fail-open is allowed
  • proceed on OSV alone and log "GHSA cross-check skipped"
```

Design principle: **no silent fallback.** Every bypass is observable and logged. When the canonical truth (OSV) cannot answer, the default is fail-closed.

---

## 7. State layout — `~/.safedeps/`

```
~/.safedeps/
├── approved-specs/            ← ledger SSoT, one JSON file per (ecosystem, package, version)
│   ├── sha256-abc123.json
│   └── …
├── snapshots/                 ← reorg snapshots (inherited from v1, extended to all lockfiles)
│   └── <id>/ { package-lock.json, yarn.lock, pnpm-lock.yaml, poetry.lock, uv.lock,
│               Cargo.lock, go.sum, Gemfile.lock, meta.json }
├── confirmed_${dir_hash}      ← per-project last confirmed snapshot
├── cache/
│   ├── osv/                   ← OSV query responses (24h TTL)
│   └── kev/                   ← CISA KEV daily catalog
├── locks/                     ← atomic state (TOCTOU guard)
├── reorg.log                  ← reorg events (append-only)
└── advisory.log               ← advisory-gate decisions (approve / block)
```

- `approved-specs/` is the ledger SSoT, one atomic JSON write per spec.
- `snapshots/` keeps the v1 design plus the Python/Rust/Go/Ruby lockfiles.
- `cache/osv/` and `cache/kev/` hold provider responses under TTL.
- `advisory.log` is the audit trail of every approve/block decision.

---

## 8. Multi-ecosystem support

| Ecosystem | Manifest | Lockfile | `safedeps check` |
|---|---|---|---|
| npm | `package.json` | `package-lock.json` | `safedeps check npm <pkg>@<range>` |
| yarn | `package.json` | `yarn.lock` | `safedeps check npm <pkg>@<range>` |
| pnpm | `package.json` | `pnpm-lock.yaml` | `safedeps check npm <pkg>@<range>` |
| pip (Poetry) | `pyproject.toml` | `poetry.lock` | `safedeps check pypi <pkg>@<range>` |
| pip (uv) | `pyproject.toml` | `uv.lock` | `safedeps check pypi <pkg>@<range>` |
| pip (Pipenv) | `Pipfile` | `Pipfile.lock` | `safedeps check pypi <pkg>@<range>` |
| pip (raw) | `requirements.txt` | (weak) | `safedeps check pypi <pkg>@<range>` |
| cargo | `Cargo.toml` | `Cargo.lock` | `safedeps check crates.io <pkg>@<range>` |
| go | `go.mod` | `go.sum` | `safedeps check go <pkg>@<range>` |
| ruby | `Gemfile` | `Gemfile.lock` | `safedeps check rubygems <pkg>@<range>` |
| maven | `pom.xml` | (directory) | `safedeps check maven <group>:<artifact>@<range>` |
| nuget | `*.csproj` | `packages.lock.json` | `safedeps check nuget <pkg>@<range>` |

OSV normalizes ecosystem names, so one API path covers all of them at advisory-check time. Per-ecosystem typosquat lists and install-script risk patterns live in separate static lists. Note that the npm effect gate (closure-vs-ledger enforcement) is npm-only today; the other ecosystems use the command-gate + reorg model.

---

## 9. Component responsibilities (SoC)

| Component | Responsibility |
|---|---|
| `SKILL.md` | The SSoT the Claude/Codex skill loader reads — hook declarations + advisory-gate usage. |
| `README.md` | User install guide. |
| `ARCHITECTURE.md` | This document — internal flow and design. |
| `bin/safedeps` | CLI entry — advisory check, ledger management, re-check, migrate. |
| `scripts/safedeps-pre-guard.sh` | PreToolUse hook — ledger match + v1 hardcoded patterns + snapshots. |
| `scripts/safedeps-post-verify.sh` | PostToolUse hook — closure-vs-ledger effect gate + reorg. |
| `lib/providers/` | OSV / KEV / GHSA (and optional NVD / deps.dev / Snyk) adapters behind one query interface. |
| `lib/ledger/` | Approved-spec ledger I/O — atomic write, hashing, TTL checks. |
| `lib/npm/closure.sh` | npm closure resolution from a lockfile. |
| `lib/gates/` | Release-time repo lane — `scan.sh` (gitleaks runner), `audit.sh` (npm lockfile audit), `hooks.sh` (`install`/`check`/`init`), `doctor.sh` (posture diagnose + `--fix`), `repo-profile.sh` (public/private resolution). Owns *execution*; the repo owns *policy*. |
| `lib/gates/templates/` | Starter `.gitleaks[.private].toml` + `.githooks/pre-commit`, scaffolded by `hooks init`. Seeds the repo owns and tunes — never overwritten on re-run. |

---

## 10. How safedeps differs from existing tools

| Tool | Focus | When | Difference from safedeps |
|---|---|---|---|
| `npm audit` | report vulns from the materialized lock | post-install | reports only; no spec decision or blocking |
| `pip-audit` / `cargo audit` / `bundler-audit` | same, other ecosystems | post-install | same |
| socket.dev | SaaS risk intelligence (behavioral + static) | pre/post-install | cloud-dependent, free-quota limited, external SaaS |
| lavamoat | runtime permission sandbox | runtime | no pre-install block; heavy on the dev loop |
| pnpm `onlyBuiltDependencies` | lifecycle-script allowlist | install | no typosquat/vuln DB; script blocking only |
| deps.dev | package graph metadata | query only | data, not an active gate |
| OSV-Scanner | OSV scan of a lockfile | post-install (CI) | reports the lockfile; no spec gate |
| GitHub Dependabot | PR-based dep updates | repo (PR) | no local install block; PR stage only |
| **`safedeps`** | **advisory check + approved-spec ledger + npm effect gate + reorg** | **pre/install/post** | **closure-level enforcement, multi-ecosystem command guard, local-first** |

In short: other tools focus on one of "report," "sandbox," "script-block," or "PR suggestion." safedeps layers advisory check → fast command guard → npm effect gate + reorg into defense-in-depth, and — unlike Snyk or socket.dev — depends on no SaaS, only the local CLI plus public databases (OSV / KEV / GHSA).

---

## 11. Operational logs

```bash
tail -f ~/.safedeps/advisory.log     # advisory-gate decisions (approve / block)
tail -f ~/.safedeps/reorg.log        # reorg events
ls -lt ~/.safedeps/approved-specs/   # current approved specs
jq '.evidence' ~/.safedeps/approved-specs/sha256-abc123.json   # one spec's evidence
rm -rf ~/.safedeps/cache/osv/        # clear the OSV cache (force re-query)
```

---

## 12. Legacy / migration: v1 `npm-reorg-guard` → v2

| v1 (`npm-reorg-guard`) | v2 (`safedeps`) |
|---|---|
| `~/.npm-reorg-guard/` | `~/.safedeps/` |
| `~/.claude/skills/npm-reorg-guard/` | `~/.claude/skills/safedeps/` |
| `scripts/guard.sh` (pattern match only) | `scripts/safedeps-pre-guard.sh` (+ ledger lookup, namespaced) |
| `scripts/verify.sh` (lockfile diff + reorg) | `scripts/safedeps-post-verify.sh` (+ approved-spec diff, namespaced) |
| — | `bin/safedeps` — new CLI (check / approve / revoke / re-check / ledger) |
| — | `lib/providers/`, `lib/ledger/` |
| GitHub `aldegad/npm-reorg-guard` | `aldegad/safedeps` (redirect only) |

Migration:

- The v1 hook path (`~/.claude/skills/npm-reorg-guard/scripts/*.sh`) is not canonical; settings point at `~/.claude/skills/safedeps/scripts/*.sh`.
- When a `~/.npm-reorg-guard/` directory is found, its state migrates to `~/.safedeps/` (snapshot chain preserved).
- A v1 user runs `safedeps migrate` once: it creates the ledger and carries existing confirmed snapshots over.

---

## 13. Limits and future direction

**Current limits:**

- A zero-day discovered after `approved_at` is caught only by the daily re-check.
- A compromise of the registry itself (npm/PyPI/…) is out of reach.
- KEV updates once a day; a KEV listed in between is not caught until the next refresh.
- Transitive-closure checking can grow the ledger to hundreds of entries; this needs optimization.

**Future direction** (see [`ROADMAP.md`](./ROADMAP.md)):

- Effect-based closure enforcement for the non-npm ecosystems.
- Ledger tamper resistance (OSV-as-authority + tamper detection; no local signing).
- Plugin providers, a `.safedeps.toml` policy file, CI mode, multi-machine ledger sync, and agent-suggested safe replacements.
