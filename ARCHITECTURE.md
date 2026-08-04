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
│                                        optional PR required checks   │
│   scope: the package being installed   scope: the whole repo tree    │
│                                        (absorbed from                 │
│                                         security-release-gates)       │
│                                                                      │
│   shared: public DBs (OSV/KEV/GHSA) · local-first · no silent        │
│   fallback (a provider/scanner miss is fail-closed)                  │
└──────────────────────────────────────────────────────────────────────┘
```

- **Install-time lane** (sections 2–13 below) — advisory check, fast command guard, and the npm effect gate + reorg. Per-package and proactive.
- **Release-time lane** — the repo-tree checks from `security-release-gates` (secret scan, dependency audit, repo hook install/check, privacy profile), exposed under the `safedeps scan|audit|hooks|doctor` command namespace. Repo-specific policy (`.gitleaks.toml`, lockfiles) stays in the target repo; safedeps owns local execution, install, and verification. Remote repository posture is opt-in and split by cost boundary: no-runner branch rules that block direct pushes to the default branch are recommended, while Actions-backed workflows and required status checks remain explicit cost-bearing opt-in.

The two lanes differ in timing and scope (one package's effect before/after install vs. the whole repo before a release). They live under one umbrella but stay separated by command namespace.

**The secret-leak side of the release-time lane is per-repo and opt-in.** Its detection policy lives in the target repo, not in safedeps, so it does nothing until the repo provides a `.gitleaks` config and an active `.githooks/pre-commit`. `safedeps doctor` is the repo-entry diagnostic that closes that gap: it reports each piece of the secret-leak lane (`.gitleaks` policy, `pre-commit`, `core.hooksPath`, scanner availability) plus the global install-time gate, and exits non-zero when the per-repo lane has gaps. `safedeps doctor --fix` (= `safedeps hooks init` then `safedeps hooks install`) scaffolds a starter policy from `lib/gates/templates/` and activates the local hooks. The scaffold is **non-destructive** — an existing repo-owned config is never overwritten — preserving the invariant that safedeps owns *execution*, not *policy*. The scaffolded `pre-commit` runs two checks. The secret scan (`safedeps scan secrets --staged`) runs on every commit and is fail-closed: an unresolvable `safedeps` or a missing scanner blocks rather than skipping silently. The dependency audit (`safedeps audit`) also runs on every commit in a repo with a supported lockfile — npm, pnpm, yarn, or bun, auto-detected from the lockfile(s) present, each delegated to that ecosystem's native audit — not only when the lockfile changes, so a CVE disclosed *after* a package was installed is caught at the next commit by re-querying the advisory DB. The audit separates the security verdict from an availability failure via meaningful exit codes (0 clean / 1 vulnerable / 2 could-not-run): a real finding **blocks** (fail-closed), while an unreachable advisory DB makes the hook **warn and allow the commit** — an explicit, observable availability failover (per the no-silent-fallback invariant: it is logged to the commit output and does not change canonical truth), with CI and the daily re-check re-covering what the offline commit could not verify.

**Remote enforcement is deliberately opt-in and cost-aware.** `doctor` can report whether a repo already has a security workflow and can name two separate default-branch postures: block direct pushes with a branch rule (no runner minutes) and require Actions-backed PR status checks (can spend hosted-runner minutes). It does not query or mutate branch protection and `doctor --fix` never creates `.github/workflows`. Local pre-commit checks run on the developer machine; remote GitHub Actions, gitleaks-in-CI, and required PR checks are outside the no-cost bundle. The JSON schema keeps those recommendations as `lane: "remote"` checks, while `gaps`/`ok` remain scoped to the local secret-leak lane.

**The effect-primary model is npm-only.** `pip`, `cargo`, `go`, `gem`, `maven`, and `nuget` stay on the v2.1 command-gate + reorg model until their closure resolvers land; they are not described as having PostToolUse closure authority.

#### Where each ecosystem's authority lives

The command gate decides whether a command is an install by recognizing the syntactic carrier that hands text to an interpreter. It knows `sh -c`, `eval`, command substitution, and a pipe into a shell. That list is an enumeration, and the shell has unbounded ways to route text to an interpreter, so the list has a boundary. A herestring, an `xargs`-built command line, and a script written to a file and then run all fall outside it. Extending the list finds more forms rather than fewer.

**The same bypass has a different severity in each ecosystem, and that difference is the point.** For npm the boundary costs *delayed detection*: the effect gate reads the live `package-lock.json`, and its own install recognizer is a raw text match with no carrier enumeration, so it fires on exactly the commands the command gate skipped. An unrecognized carrier still ends in a closure check and a rollback. For `pip`, `cargo`, `go`, `gem`, `maven`, and `nuget` there is no closure resolver behind the command gate, so the same carrier is a **complete miss**. The post hook recognizes the command, finds nothing it can check it with, and records `UNVERIFIED`. Read "the command gate does not parse this form" as npm-shaped and you will conclude something is still watching. In the ecosystems where the command gate is the authority, nothing is.

The boundary is not an oversight, and widening it is not free. The two recognizers in this repo make opposite precision trades on purpose. A false positive in the effect gate costs one closure diff, so its recognizer is deliberately loose. A false positive in the command gate **denies the user's command**, so its recognizer must be precise — and precision is what an unenumerated carrier walks through. This is the same conclusion that moved npm's authority to the effect gate in the first place: command text cannot be a fail-closed authority, because deciding from text means deciding from a syntax you have to enumerate.

The rule for changing the command gate follows from that. Applying a rule the gate already states, at a place that skipped it, is in scope — normalizing `| /bin/sh` and `| env sh` to `| sh` is the gate's own existing statement that a path-qualified or env-prefixed invocation is the bare one, applied to the consumer side of the pipe instead of only the producer side. Adding a new carrier syntax to the recognizer is not, because that is where the enumeration grows without converging.

Reading a parser gap as npm-shaped was a misreading with more than one instance. The ledger gate itself is gated on a parseable `pkg@version` operand, and the code's stated reason for that is npm-shaped too: a bare `npm install` is a lockfile install that names no new package, so letting it fall through is correct *for npm*. `pip install evil` is not a lockfile install. It names a package. The same reasoning was carried into the ecosystems where this command gate is the authority, and there it means an unpinned install is never checked at all.

The direction is also inverted, which is the part enumeration would never surface. The hidden path denies when no spec can be extracted, and the plain path allows under the identical condition. One predicate is read in opposite directions inside one file: `printf 'pip install evil' | sh` is refused fail-closed, while `pip install evil` proceeds.

That case now writes an `UNGATED` record naming the ecosystem and the command. It changes no verdict. Denying every unpinned install is a policy change that would break ordinary workflows, so it stays the repo owner's call; the record is what makes that call answerable from evidence rather than guesswork. The record's silence is scoped as deliberately as its noise, and the line is whether a package is named -- not which flags appear. A bare lockfile install names none, and neither does `pip install .`, which builds from the working tree instead of fetching. A source flag consumes only its own argument, and which flags take one is a property of the tool: pip's `-r`/`-c`/`-t`/`-f` do, while gem's `-r` is `--remote` and go's `-t` is a boolean. A record that fires on routine installs is background noise and background noise is the same as no record, but one that goes quiet whenever a flag appears is worse -- it reads as coverage it does not have.

`scripts/test/consumer-forms.sh` holds the measurement. It pins the forms the gate catches, the forms it deliberately leaves unjudged, the ecosystem consequence of each miss, and a third set that matters as much: **decoys**. `sh -c "sh -c "…""` reads as double nesting but the outer quotes close at the inner ones and nothing is installed, and `xargs sh -c` without `-I` or `-0` hands the line to `sh` as `$0` rather than as a script. The battery proves each form's status by running it against a fake package manager, so a form counts as a gap only when it actually reaches one.

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
  ],
  "project_context": null
}
```

Key fields:

- `hash` — a deterministic hash of `(ecosystem, package, version)`, folded together with `project_context.context_hash` when one is present. The hook derives the same hash from a command (plus the live project context, if any) and looks the ledger up by it.
- `approved_at` / `expires_at` — lifecycle TTL, 30 days by default. After expiry a new CVE may exist, so the spec is auto-revoked and re-check is forced.
- `evidence` — which source saw what, at approval time. An audit trail.
- `transitive_specs` — the full transitive closure the direct entry approved. The npm effect gate reorgs any `pkg@version` that appears in the lockfile but is in neither the direct entry nor this array.
- `project_context` — `null` for an ordinary published-package approval, or `{ type, context_hash, project_root, manifest_path, lockfile_path, input_sha256, input_files }` when the approval came from a Yarn project's resolved closure (see "Yarn project-scoped closure" in section 4). `context_hash` is a hash of the project directory, its root `resolutions`, its `yarn.lock` content, and its canonical input set. `type` is `yarn-project-lockfile` when the package was already in the project lockfile, or `yarn-project-materialized-lockfile` when the candidate was resolved in an isolated mirror; the materialized form additionally carries `materialization { candidate, input_sha256, generated_lockfile_sha256, command, isolation }`. `safedeps_ledger_validate_json` requires those fields and rejects an entry whose `materialization.input_sha256` disagrees with the context `input_sha256`.

`project_context.type` is also `npm-overrides-probe` when the published-package probe applied the consuming repo's npm `overrides`. That context carries `project_root`, `overrides_source` (the manifest path, or `env`), `overrides_sha256`, and the `overrides` themselves; `context_hash` is a hash of the project root and the canonical (key-sorted) override set, so two equivalent sets share one key. `safedeps_ledger_validate_json` requires those fields and rejects an entry with an empty override set. The rule behind it: a published-package approval may be global only because it is project-independent. Applying `overrides` makes the resolved closure a function of the consuming project, so that approval must be keyed like the Yarn project closure is — otherwise an approval earned in a repo that patched a transitive would satisfy the check in a repo that did not, whose real install resolves the vulnerable version. Repos with no `overrides` get no context and keep the ordinary global approval.

**Project-scoped isolation.** A `project_context` approval is keyed by `context_hash` in addition to `(ecosystem, package, version)`, so it lives at a different ledger path than a package-only approval of the same spec and cannot satisfy a lookup from a different project or from the same project after `resolutions`/`yarn.lock` changes (the hash changes with them). `safedeps_ledger_check` compares the caller's live context hash against the stored one and denies with `reason: "context_mismatch"` on any difference — an approval never silently leaks across project boundaries.

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

**Yarn project-scoped closure.** Before falling back to a fresh published-package probe, `safedeps_npm_yarn_project_closure` (in `lib/npm/closure.sh`) looks for a canonical Yarn project context:

```
resolve project context (walk up from cwd, stop at .git boundary):
        │
        ├─► package.json has non-empty root `resolutions` + a yarn.lock next to it
        │        │
        │        ├─► yarn.lock has no `__metadata:` marker ──► INVALID CONTEXT (fail-closed)
        │        └─► valid Berry lockfile
        │                 │
        │                 ▼
        │        context_hash = sha256(project_root, sha256(resolutions), sha256(yarn.lock))
        │                 │
        │                 ▼
        │        `yarn info -A -R --json` → full project locator graph
        │                 │
        │                 ▼
        │        traverse from the requested `pkg@npm:version` locator
        │                 │
        │                 ├─► locator found  ──► resolved project closure (approvable)
        │                 └─► locator absent  ──► materialize the candidate (see below)
        │                                          ├─► materialized ──► generated closure (approvable)
        │                                          └─► failed ──────► project-candidate-materialization-unavailable
        │                                                              (deny; the published closure is not used)
        │
        └─► no resolutions / no yarn.lock in this Git worktree ──► ordinary npm package-only check
```

Yarn owns descriptor-to-locator resolution; safedeps consumes `yarn info`'s machine-readable graph rather than re-implementing lockfile resolution. When the context resolves, the approved-spec ledger entry carries `project_context` (section 3) so the approval is scoped to that exact project and cannot leak to a different one or survive a `resolutions`/`yarn.lock` change.

**Yarn candidate materialization.** A locator is absent from `yarn.lock` precisely when the package has not been added yet, which is the normal pre-install check. `safedeps_npm_yarn_materialize_candidate_closure` resolves that candidate in an isolated mirror rather than denying it or falling back to the published closure:

```
locator absent from the project lockfile
        │
        ▼
   mktemp private mirror ◄── copy canonical inputs ONLY:
        │                     root + workspace package.json, yarn.lock, .yarnrc.yml,
        │                     .yarn/{releases,plugins,patches}
        │                     (never node_modules, caches, unplugged, install state, VCS)
        ▼
   re-hash inputs in the mirror; must equal the caller's input_sha256
        │
        ▼
   add the candidate to the MIRROR manifest only
        │
        ▼
   `yarn install --mode=update-lockfile --no-immutable` (no link step, no lifecycle scripts)
        │
        ▼
   re-hash the caller's inputs again ── changed? ──► INVALIDATE (concurrent project edit)
        │
        ▼
   `yarn info -A -R --json` over the GENERATED lockfile → candidate closure
        │
        ▼
   project_context.type = "yarn-project-materialized-lockfile"
   + materialization { candidate, input_sha256, generated_lockfile_sha256, command, isolation }
```

The caller's tree is read-only for the whole operation; only the mirror is mutated. The input recheck before and after Yarn closes the read/copy race, so a manifest or lockfile edit that lands mid-flight invalidates the candidate instead of yielding an approval for a mixed project state. Approval truth is neither a registry probe nor the caller's stale lockfile — it is the Yarn resolution derived from a hash-bound copy of the caller's own inputs, and both the input hash and the generated lockfile hash are recorded as ledger evidence. Every failure path (input copy, context drift, Yarn invocation, unresolvable candidate) returns `project-candidate-materialization-unavailable` and denies. There is no published-closure fallback.

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

**The guard keeps a budget of its own.** The runtime gives this hook a fixed budget (the installer registers it) and kills it when that expires, after which the tool call proceeds — measured on Claude Code, 2026-08-04. The command scan is superlinear in command length, so that budget is reachable by padding: measured here, 28KB of command text took 29s and 32KB took 38s. Past that line the gate used to disappear without saying anything, which for `pip`/`cargo`/`go`/`gem` — where this gate is the authority, not an advisory layer — is a bypass that needs no knowledge of the scanner at all.

The runtime's timeout behavior is not safedeps' to change; answering before it fires is. The guard runs its judgment in a child under `SAFEDEPS_SELF_BUDGET_SECONDS` (default 20), and if that child has not answered by the deadline the guard answers for it: deny, because an install it could not judge must not run. Two properties that deny must keep — it is fail-closed but **not a finding** (the reason leads with `UNDECIDED, not unsafe` and says nothing was detected, because a reader who confuses "did not finish" with "found something" learns to route around the gate), and it is recorded to `advisory.log` like every other bypass or unavailability.

**That budget can be lowered, not raised.** `SAFEDEPS_SELF_BUDGET_SECONDS` is clamped to a ceiling of 25s; lowering it stays free, because a shorter budget only denies earlier. A budget at or above the runtime's is not a budget at all — the runtime kills the hook first and the tool call proceeds, which is the exact fail-open this machinery exists to remove. The motive to raise it is an ordinary one: someone who hits `UNDECIDED` on a large command reads it as "the budget is short" and turns off a security boundary without ever meaning to. A boundary the user can move is a default, not a boundary. The clamp is announced wherever the budget is in play — stderr, `advisory.log`, and the deny reason — because a silently reduced budget leaves the user debugging against a number that was never true.

The value is normalized before anything compares it, and only the normalized digits reach arithmetic. That ordering is load-bearing: bash arithmetic accepts a wider grammar than a `^[0-9]+$` check, so validating with the regex while the deadline consumes the raw string lets `+40`, ` 40` and `0x28` skip the clamp and then evaluate to 40 anyway — the fail-open, restored by a space. Surrounding whitespace and a leading `+` are read the way whoever typed them meant; anything else is not a budget and falls back to the default, which is inside the ceiling and is announced on the same channels as the clamp.

Length is checked before magnitude, and in the string domain, because bash integers are 64-bit and wrap silently. A value that wraps negative is not greater than the ceiling, so it passes the clamp untouched, and multiplying it into milliseconds wraps it again into a deadline that never arrives — measured, a 30-digit budget produced no answer for over 600s. Which way a value wraps depends on the value, so nothing about the wrap can be relied on. A run of digits longer than nine is therefore clamped on its digit count, before arithmetic sees it: nine digits is about 31 years of seconds, far past any real budget and far inside what the deadline multiplication can hold.

**Where the 30s comes from, and what would make it stale.** The hook payload does not carry the runtime's budget, and hook registrations from several settings files all fire, so the guard cannot tell at runtime which registration launched it. What it can do is name the number safedeps itself registers: `PRE_HOOK_TIMEOUT_SECONDS` in `scripts/install/install-safedeps-hooks.mjs`, 30s, matching the measured kill time. The smoke test pins those two constants together, so an installer change cannot leave the guard computing its ceiling against a stale number. The 5s between the ceiling and that budget is what the guard spends outside the budget window: up to 1s waiting out the final poll step, up to 0.5s of TERM grace before the KILL, and ~0.1s of reap, `jq`, and process start — a 1.6s structural worst case, against 0.73–1.05s measured end to end and flat from 4KB to 256KB of command text. A user who hand-edits the registered timeout below 30s is outside what this constant can know.

The deadline is enforced against the child's whole process tree, not just the child shell. A shell does not act on a signal while a foreground external command is running, and the expensive part of the judgment is exactly such a command, so signalling the shell alone lands whenever that command happens to finish — measured 9.1s late against a 20s budget, which spends the whole margin the self budget exists to create. Descendants are resolved from the child's own pid (never by name pattern), signalled TERM, then KILL after a short grace. For the same reason the guard traps only `EXIT` and never `TERM`: naming a signal in `trap` replaces its default disposition, and a child that traps TERM survives its own deadline.

Only commands at least `SAFEDEPS_BUDGET_ENGAGE_BYTES` long (default 1KB) pay for the extra process; below that the judgment finishes about 300x inside the budget, so the machinery would be pure overhead on every Bash call. That engage size is a performance gate, not a security boundary — the security boundary is the wall-clock budget, which stays honest on machines faster or slower than the one these numbers were measured on.

**But a performance gate that can be raised without limit is an off switch.** The engage size is the only condition on the whole deadline, so raising it past the commands that matter removes the deadline for all of them — measured, a 32KB padded `pip install` answers in 21s at the default engage size and takes 198s with it raised, against a runtime that kills the hook at its budget either way. It is therefore clamped to 4KB, where a command just under the line is still judged in about 0.68s, some 44x inside the runtime budget. Tuning between the 1KB default and that ceiling is what the knob is for and stays available; the clamp announces itself on the same three channels as the budget's.

The marker that tells the spawned child it is the child travels in argv, not in the environment. As an environment variable it was a second off switch with no name on it: exporting it made the parent believe it was already the child and skip the deadline, measured at 32s on an input that answers in 3s, with nothing on stderr and nothing in `advisory.log`. The engines invoke the hook through a shim that passes no arguments, so argv is a channel the environment cannot reach. The old variable is still noticed and reported as ignored, because a signal that used to switch the deadline off should not become quietly inert either.

Turning the deadline off is a separate act with a separate name: `SAFEDEPS_BUDGET_DISABLED`. The battery needs it — a test that only knows it passes, and not that it catches the defect, is not evidence, so the mutation check has to be able to produce the unbounded case. Routing that through the engage size made tuning and disabling the same gesture, which is exactly how a friction adjustment silences a boundary without anyone deciding to. The off switch does nothing else, says what it does in its name, and logs every time it takes effect. Regression: `scripts/test/self-budget.sh`.

For an npm-ecosystem command, the guard resolves the same Yarn project context described above (`SAFEDEPS_NPM_PROJECT_DIR` pinned to the project directory) and folds its `context_hash` into the ledger lookup, so a project-scoped approval only passes the guard inside its own project. An invalid context (resolutions present, lockfile unusable) denies the command outright rather than falling back to a package-only lookup.

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

**This gate has the same budget, and it is killed the same way — measured, not assumed.** Using the protocol that established the PreToolUse behavior (a sandbox project, a hook that records when it starts and when it finishes, a control inside the budget and an experiment past it), a PostToolUse hook given 20s of work against a 5s budget started and never finished, while the 1s control finished. The work above is bounded by the user's project and the network rather than by anything safedeps controls: `npm ci`, `npm install`, `npm rebuild`, and an OSV batch over the whole closure.

So the sentence "the effect gate backs up the command gate" holds *inside* the budget and not past it, and it fails worse in kind: a killed pre-hook lets one unjudged command through, while a killed post-hook can land in the middle of a rollback. The pre-hook's answer to running out of time is to deny (Phase 2), but a post-install gate cannot deny — the command has already run — so its answer is a different design question, tracked as `safedeps/effect-gate-killed-mid-rollback` and not solved here. Codex CLI timeout behavior remains unmeasured on both hooks; parity is not assumed.

### Phase 0 — the installed command is an entry shim (`safedeps-hook-entry.sh`)

Both engines register one command per hook event: `…/skills/safedeps/scripts/safedeps-hook-entry.sh pre|post`. That path resolves through the `~/.claude`/`~/.codex` skill symlink into the live repo checkout, on every Bash tool call. The working tree *is* the runtime. A checkout that is mid-merge, mid-edit, or mid-update therefore changes hook behavior instantly — and before the shim existed, what happened next was decided by accidental exit codes. A bash syntax error (merge conflict markers) exits 2, which both engines treat as a blocking deny, so every session on the machine lost Bash with only a raw parser message as explanation (this happened on 2026-08-04). A missing file exits 127 and a runtime crash exits 1 — both are *non-blocking* hook failures, so those breakage shapes silently removed the install gate entirely.

The shim makes both outcomes designed. The real hooks exit 0 on every intended path (decisions travel as JSON), so any non-zero exit means the source itself is unwell. The shim then classifies the breakage (does not parse / crashed / missing), checks the checkout for an in-progress merge or rebase and says so, and exits 2 with a message that names the machine-wide breadth, the cause, and the recovery path. Fail-closed stays fail-closed; it stops being anonymous, and the fail-open shapes stop being silent.

Measured cost: ~7 ms per Bash call on top of a ~34 ms guard baseline. Residual windows, kept honest: if the shim itself is broken, behavior degrades to the pre-shim status quo (blocking with a raw parse error — never wider), and the shim is a small, rarely edited file, unlike the actively developed guard; if the shim file is missing during a checkout transition (milliseconds), that call is a silent non-blocking failure, same as the pre-shim behavior for any missing hook. The regression battery for all of this is `scripts/test/hook-entry.sh`.

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
- A manual package-manager install run outside the configured Claude/Codex hook path; release-time gates are the backstop for those changes, not proof of install-time approval.
- An attacker writing to `~/.safedeps/approved-specs/` directly under the same OS user. The ledger is a local convenience cache; until signing/HMAC or install-time re-validation is added, it is not a security boundary against a same-user attacker. (The effect gate's OSV re-query does, however, still catch a forged approval for a *known-vulnerable* package — see [`ROADMAP.md`](./ROADMAP.md) "Ledger tamper resistance".)

---

## 6. Provider failure modes (no silent fallback)

```
OSV.dev — no response / timeout
  • first: use the local provider cache (24h TTL)
  • cache miss → fail-closed (block; "no OSV response, retry")
  • no install-time CLI bypass flag exists; retry when OSV or the cache can answer

CISA KEV — no response
  • KEV is a static catalog downloaded once a day; only the local cache is used
  • warn when it is more than 24h stale

GHSA / NVD — no response
  • enrichment only, so fail-open is allowed
  • proceed on OSV alone and log "GHSA cross-check skipped"
```

Design principle: **no silent fallback.** When the canonical truth (OSV) cannot answer and the cache misses, safedeps fails closed instead of inventing a secondary truth or hidden bypass.

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

OSV normalizes ecosystem names, so one API path covers all of them at advisory-check time. Per-ecosystem typosquat lists and install-script risk patterns live in separate static lists. Note that the npm effect gate (closure-vs-ledger enforcement) is npm-only today; the other ecosystems use the command-gate + reorg model. Yarn is the one npm-routed lockfile that gets project-scoped closure resolution (section 4, Phase 1) when a root `resolutions` entry is present. Plain npm uses the published-package probe, but applies the consuming repo's `overrides` to it when there are any, which scopes that approval to the override set (section 4, Phase 1). pnpm always uses the bare published-package probe.

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
| `lib/ledger/` | Approved-spec ledger I/O — atomic write, hashing, TTL checks, project-context-scoped keys. |
| `lib/npm/closure.sh` | npm closure resolution from a lockfile, plus Yarn project context/closure resolution (root `resolutions` + `yarn info`) and isolated candidate materialization. |
| `lib/gates/` | Release-time repo lane — `scan.sh` (gitleaks runner), `audit.sh` (multi-ecosystem lockfile audit — npm/pnpm/yarn/bun, delegated to each native tool), `hooks.sh` (`install`/`check`/`init`), `doctor.sh` (posture diagnose + `--fix`), `repo-profile.sh` (public/private resolution). Owns *execution*; the repo owns *policy*. |
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
- Yarn project-scoped closure requires the Yarn CLI on `PATH` and a Yarn Berry lockfile (`__metadata:` present); Yarn Classic (`yarn.lock` v1) and workspaces without a root `resolutions` entry fall back to the ordinary npm package-only check.
- Candidate materialization additionally requires that Yarn can resolve the mirror offline or from the network, and that the root manifest's `workspaces` patterns are plain relative globs. An absolute, escaping, `**`, or negated workspace pattern is refused rather than guessed at, and the candidate is denied.

**Future direction** (see [`ROADMAP.md`](./ROADMAP.md)):

- Effect-based closure enforcement for the non-npm ecosystems.
- Ledger tamper resistance (OSV-as-authority + tamper detection; no local signing).
- Plugin providers, a `.safedeps.toml` policy file, CI mode, multi-machine ledger sync, and agent-suggested safe replacements.
