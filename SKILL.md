---
name: safedeps
description: Gate dependency installs (npm/pip/cargo/go/gem/maven/nuget) with OSV-backed advisory checks, approved-spec ledger, and post-install reorg rollback. Run `safedeps check <eco> <pkg>@<range>` before any install command.
---

# Safedeps

Hook registration is performed by `scripts/install/install-safedeps-hooks.mjs`, which is the single channel: it registers `scripts/safedeps-hook-entry.sh pre|post` for `PreToolUse` and, on Claude Code, both `PostToolUse` and `PostToolUseFailure` (Codex: `PostToolUse` alone) at the timeout it owns (ARCHITECTURE names the number once). The entry runs one Rust binary, `bin/native/<os>-<arch>/safedeps-core`, which is both hooks; a checkout builds it with `scripts/build-core.sh`, and the installer does so before it registers anything. This file used to declare the hook scripts directly in its frontmatter, which no runtime reads as a registration and which drifted from what the installer actually writes — a second description of a registration is a second thing to keep in sync, so there is one now.

Two gates and a watch, one skill. Safedeps is an agent security skill backed by Claude/Codex hooks and a local CLI. It is not a Codex plugin bundle unless it is later wrapped with a plugin manifest.

You (the agent) are the primary user — drive all three:

- **Install-time gate** — clear every dependency install through an OSV-backed advisory check before it runs.
- **Secret-leak gate** — stop a secret or a real `.env` from being committed (per-repo, local by default).
- **Daily watch** — re-check the ledger and measure the lockfiles and JDKs of registered projects each day, and report what was not measured.

---

## Install-time gate

The hooks enforce this; you just run `check` first.

- **PreToolUse** blocks an install whose spec is not approved and quotes the exact `safedeps check` to run. On Claude Code it also rewrites an npm install with `--ignore-scripts`, so that it runs **inert** until verified; whether npm keeps the flag is up to the shell state the command runs in, so safedeps says only that it added it. Codex CLI uses detect-and-rollback. A command it could not finish judging is blocked as `UNDECIDED` whatever it holds. A command it could not read (a reading step failed, or the command never closes) is blocked as `UNDECIDED` when a reading found an install or when its text reads as an install, that is, a package manager's name stands as a word of its own or ends a word's path, and one of that manager's install verbs stands as a word beside it, in either order. Otherwise the command runs, and the failure is recorded on stderr and in `advisory.log`. `UNDECIDED` is a statement that no answer was reached, not a finding. The command is read the way the shell lexes it (quotes, comments, heredocs, nested substitutions), so none of those can hide an install that follows them. It is read once each as bash, zsh and dash, an install any of them would run is judged, and `--ignore-scripts` goes in only where all three agree where the npm installs are (otherwise `UNDECIDED`). It also goes in only where it can be placed without changing the command's data or how npm reads its options. A one-statement install that ends in an option that takes a value (`npm install x --cache`) or has operands after a `--` (`npm ci -- x`), an install with `--` before its verb (`npm -- ci -- x`), `npm install true`, and install words in a heredoc body that another command reads have no such place, so they are `UNDECIDED` too, with no rewrite. Run the install as its own command, with options and their values before the package.
- **Pin the version, or the gate does not run.** The ledger check needs a parseable `pkg@version`. `pip install evil` names no version, so no spec is produced and nothing is checked. An npm CLI install that leaves its trace in the directory the gate reads (where npm installs, as `npm prefix` and `npm root` answer for that command) is still enforced by the effect gate, `--no-save` and `--no-package-lock` included. An npm install that leaves no trace there (global npm, an install moved by run-time shell state such as `cd "$DIR"`, a dry run) is recorded as `UNGATED` by the post-install hook, and so is a command whose two npm installs have something between them. Everywhere else — pip/cargo/go/gem/maven/nuget, pnpm/yarn/bun, an install the project or user `.npmrc` keeps off the record, `npm link <pkg>`, and runners such as `npx` — the install proceeds unverified and is only recorded as `UNGATED` in `~/.safedeps/advisory.log`, which names each unpinned package. An npm install inside `sh -c` or `eval` is judged where the command started, so write it as its own command in the project directory. The bytes it brings in are recorded as withheld on this machine. Install the exact version that `safedeps check` approved.
- **PostToolUse** is the npm enforcement authority: it reads the real closure from `package-lock.json` and npm's hidden `node_modules/.package-lock.json`, checks every package against the ledger + an OSV batch, and **reorgs** (rolls back) anything unapproved, vulnerable, or with suspicious install scripts, to the lock and manifest files the last verified install left (in a project with none yet, to the state before the command, and the message says so). If `node_modules` was a directory before the command, the rollback keeps it and removes only the entries the pre-command listing lacks. On Claude Code the inert install is rebuilt only when every package in the tree is on record and comes from the public registry (by its record and by the registry npm says it fetched from) or a declared workspace member; otherwise the install is kept, nothing is rebuilt, and a warning names what stopped it. When that is a registry outside the public ones (a company registry, a mirror, a proxy), the warning names the registry: confirm with the user that they trust it before you run `npm rebuild` yourself. safedeps also records those bytes by integrity, so no other project on this machine rebuilds them automatically either, and this version has no way to release that record. Effect-primary is **npm-only**; pip/cargo/go/gem/maven/nuget use the command-gate + reorg model. The gate holds inside its 30s hook budget, and that budget is a measured range, not a given: the Bash hook of v2.16.0 crossed 30s near a **390-package** closure on a 738-entry ledger (it was four packages before it read the ledger once per closure instead of once per package), and for the Rust post hook the first synthetic closure size measured over 30 seconds was 128,000 packages (33.55 to 72.92 seconds on an Apple M1, 2026-10-07; 64,000 took 12.77 to 29.60 seconds), with a local fixture in place of the advisory network and no rollback or rebuild. That gives no exact limit. Past the crossing the runtime kills the hook and the install is not judged; a rollback cut off partway now leaves a loud incident record instead of nothing.
- **`SAFEDEPS_ACCEPT_RISK` is a person's decision, not yours.** Place `SAFEDEPS_ACCEPT_RISK='<who decided and why>'` in front of each npm install statement in the command. It counts only when applied with one identical value across all installs, contains no variable expansions or control characters, uses only permitted shell builtins, and every npm install lands where npm records it in a lockfile (not a global install). When accepted, the install is kept despite unapproved or vulnerable packages, emitting a warning block detailing accepted risks, withheld scripts, and audit log paths. It never covers a CISA KEV listing, a check that cannot run, an unreadable closure, suspicious install scripts, non-standard sources, lockfile anomalies, or native binaries; any such finding rolls back the install. The override lasts for exactly one command and stores its reason only in that tool call's pending record. It does not approve packages or update the ledger. A subsequent install without the override evaluates the closure from scratch and rolls back if unapproved packages remain.

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
| `patched_still_vulnerable` | Do not install. No patch candidate is clean either; `suggested_spec` is the last one tried. Propose an alternative package. |
| `cve_unpatched` | Do not install. Surface the CVEs, propose an alternative package. |
| `closure_vulnerable` | Do not install. A dependency the install would bring in has an advisory; `closure_vulnerabilities` names it. Propose an alternative. |
| `kev_hard_block` | Do not install. Recommend an alternative — actively exploited in the wild. |
| `provider_unavailable` | Do not install. OSV did not answer, its answer or one of its advisory records could not be read or was not whole, or no CISA KEV catalog could be read. No OSV answer from an earlier run is used. Retry later or tell the human. |
| `error` | Read `error`. Fix the spec (e.g. an unpublished version) and retry. `ledger_write_failed` and `approvals_store_failed` mean the approval could not be committed, `approvals_store_in_doubt` means this check's own ledger entry is not confirmed standing (records may still exist), `core_missing` means the `safedeps-core` binary is missing, and `check_did_not_finish` means the check stopped before it could answer. In each case, do not treat the spec as approved: tell the human. |

Install only after approval. If the approved version differs from your argument, the hook blocks again — re-narrow and retry.

### Rules

- Never bypass the gate. A provider miss is **fail-closed**, never fail-open, and an audited acceptance by a person via `SAFEDEPS_ACCEPT_RISK` is the only way an unapproved or vulnerable npm closure is kept.
- Set `SAFEDEPS_ACCEPT_RISK` only when a person decided to accept the risk, and never decide it yourself or invent the reason. The reason must name who decided, when, why, and where the decision is recorded. Never use it for a KEV listing, to get past an `UNDECIDED` denial, or for an advisory the person has not seen. It is not a bypass, but an audited acceptance of known, named risk where every use is recorded.
- `kev_hard_block` is non-negotiable — recommend an alternative, never ask the human to override.
- Use `install_hint` / `suggested_spec` verbatim — a fresh range defeats the spec lock.

### When the hook blocks you

The block message is `permissionDecisionReason`. The command quoted in backticks is runnable as-is — run it **verbatim**, parse the `--json` output, and retry the install with the approved version.

Two blocks are not about the package. `UNDECIDED, not unsafe` says safedeps could not finish judging or reading the command; split it, or write the install as its own command, and retry. A message that says the `safedeps-core` binary is missing, will not run, or was built from another source than the one beside it is a build state, not a finding: tell the human to run `scripts/build-core.sh` in the checkout (or reinstall the package and run the installer again). Do not work around it, and do not run the install by another route.

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

## Approvals store and migration

Fresh `clean`, `patched`, `clean closure`, and `patched closure` approvals write provenance to `${SAFEDEPS_HOME}/approvals.jsonl`. A cache hit requires both a valid ledger entry hash and a store vouch; after upgrading, any unvouched ledger entry is checked again from the start (including a provider requery) once per entry until migrated or rechecked.

Run migration once after upgrading to import verified approvals from live `advisory.log` (always read first) and any named existing archive files (`.gz` supported), without provider calls or ledger/log writes (distinct from legacy `safedeps migrate`):

```bash
safedeps [--json] approvals migrate [<archive>...]
```

Every migration report carrying `approve_lines` reports five counts—`inserted`, `not_inserted`, `duplicates`, `unconfirmed` (`no_entry`, `not_an_entry`, `hash_mismatch`), and `taken_back`—summing to `approve_lines` when known (`not_inserted` is `0` on success; `cache`, `broken`, and `torn` are counted separately and never imported). Re-running is idempotent (`duplicates`).

Pre-write failures (`input_unreadable`, `ledger_entry_unreadable`, `approvals_store_failed`) write nothing. `approvals_store_write_failed` rereads its own hashes under the lock or reports `"unknown"` for `inserted` and `not_inserted` with `reread_outcome`; `approvals_store_unsynced` means written lines were not synced; `core_missing` names the missing `safedeps-core` path. CLI failures and usage errors exit `4`. Retrying migration is safe, and a partial outcome is not a success.

After upgrading, reinstall the daily watch LaunchAgent from a checkout containing `bin/native/<os>-<arch>/safedeps-core` (`node scripts/install/install-safedeps-recheck-agent.mjs install` with the host's `--hour` and `--minute`); otherwise scheduled runs stay on the old runtime (`agent_runtime_stale: true`) or fail with `core_missing`.

## Daily watch

`safedeps watch` re-checks the ledger, measures the lockfiles and JDKs of registered projects, and publishes one state file, `~/.safedeps/watch/state.json`. It detects and records. It never edits a project, installs anything or updates a JDK.

Entry points:

- `safedeps watch status [--json]`: read the last published state without taking the lock. Use it to see the age of the last scan, the last full scan (`last_full_scan`, which a root scan does not replace) and the last success, and `awaiting_owner`: the live findings that wait for the owner's judgment and the locally closed findings whose deployment wait (`awaiting_deploy`) the owner has not resolved, each with why, `closed_reason` (null while the finding is live) and its `report_fact`.
- `safedeps watch scan [--json]`: run a full scan under the lock. The installed LaunchAgent runs the same scan once a day.
- `safedeps watch scan --root DIR`: measure one root again. Every other root's state and every undelivered event are kept. Run it before and after a repair.

Reading a report:

- Read the summary line first: `population <state> <count>; roots walked N/M (K incomplete); osv measured A; native audit B; unmeasured C (by kind); blocked D; open E (fixable F, triage G, no fix H)`. N is `roots_walked`, K is `roots_walk_incomplete`, and M is N + K, the roots of class `ok`. `(K incomplete)` is always shown, also as `(0 incomplete)`. Do not read `osv measured 0` as "nothing found" when the roots were not read. The line ends with `; agent runtime stale unknown (<error>)` when the scan could not tell whether the agent runtime is stale, where `<error>` is `last_scan.runtime.error`.
- `complete` is true only when the population is fresh, nothing is unmeasured and nothing is blocked. Only then say that every project was measured.
- An unmeasured row has a `kind` and a `followup`. It is not clean. A row with no followup is counted as `unmeasured_without_followup`.
- `provider_unavailable`: a provider failed, so those lockfiles were not judged. Their findings are kept, not closed.
- `stale_measurement`: the finding could not be measured again and stays as it was, with the reason.
- `root_walk_incomplete`: find exited non-zero on a root, so the walk did not finish. The row carries `root`, `exit`, `said` and `lines`. `exit` is find's exit status. `said` is the first three lines find wrote to stderr, with the root's path written as `.`. `lines` is how many lines find wrote to stderr. The reason is what find said. safedeps names no reason of its own and does not classify the words. The root's line in `roots` has the same facts as `walk: {exit, said, lines}`, with `partial: true`. What the walk did list is still judged. The whole scope of that root is unmeasured, with the reason `root_walk_incomplete`. An earlier finding whose lockfile the walk did not list stays open as `stale_measurement` with `unmeasured_reason` `root_walk_incomplete`, not `lockfile_missing`.
- `last_scan.runtime` with `stale: null` and `error`: the source checkout could not be read, so the scan cannot tell whether the runtime is stale. This is not a stale runtime. `source_unreadable` is `{step, exit, said, lines}`. `step` is the name of the step that failed. The step is `find`, `sort`, `shasum` or `digest`. `exit` is that step's exit status. `said` is the first three lines that step wrote to stderr. `lines` is how many lines it wrote. `said` and `lines` are null when the words could not be read back. `error` is `source checkout unreadable: <the first line the failed step said>`. When that step said nothing, `error` is `source checkout unreadable: exit <n>, nothing said`. `<n>` is that step's exit status. `source_digest_now` is null and `agent_runtime_stale` is null, not false. The summary line ends with `; agent runtime stale unknown (<error>)`. There is no error row and no alert for it. When the wrapper alerts for another reason, the notification adds `, agent runtime stale unknown`. A stale runtime is `stale: true`, and the fix for that is still to reinstall the agent.
- Exit 75 is busy: another run holds the lock, and nothing changed. It is neither a pass nor a finding. Retry later.
- Exit 1 is published with errors. The full report is still printed. Read `errors`.
- Exit 3 is nothing published. The previous generation stands.

Rules:

- Never call a project, a lockfile or a JDK clean. No state is named `clean`.
- Never close a finding by hand. Record `safedeps watch retire --root DIR --evidence TEXT` only on the owner's evidence that the root is gone for good.
- Never read a network mount or an excluded prefix to fill a gap. It is measured only on the host that owns it.
- As a consumer: `claim --consumer ID`, then dispatch, then `ack --event ID --consumer ID` with `--task T` or `--unknown`. Never re-send by time.
- As a consumer, read `last_full_scan` and `awaiting_owner` from `watch status` by name. Do not rebuild either from `state.json`. An `--unknown` ack does not take a finding out of `awaiting_owner`. A `closed:*` event is a notice of a local closure, not of a deployment. A closed finding whose remediation is `awaiting_deploy` stays a row, with its `closed_reason`, through the ack and through later scans.
- `report_acknowledged` is the owner's judgment of a finding that only reports: `no_fix_available`, or a runtime's `update_available` or `pre_announced`. Only the owner records it, with the judgment in `--detail` and, in `--expect`, the `report_fact` of the row they judged. If the finding's report is another one by then, nothing is written. It is not a repair. A scan that changes the report later puts the finding back in `awaiting_owner`. KEV true (listed), false (not listed) and null (unknown) are distinct; an outage and recovery each require a new judgment.
- `deploy_resolved` is the owner's record that a deployment wait is over. It says the linked task/plan holds evidence that the fix behind an `awaiting_deploy` record is deployed, or that no deployment is needed. Only the owner records it, on a closed finding: `safedeps watch remediation --finding KEY --state deploy_resolved --task T --detail TEXT --expect REPORT_FACT`. Before writing, the owner reads `watch status` after their last dispatch for that finding, and reads the authoritative evidence in the linked task/plan. `--task` is the task of the `awaiting_deploy` record, `--detail` says deployed or not needed and cites the evidence, and `--expect` is the `report_fact` of the row that status printed. Under the lock, the write happens only when all of these hold: the finding exists, it is closed, its remediation is `awaiting_deploy`, that record's task is not null and equals `--task`, the detail is not blank, and `--expect` is well formed and equals the finding's `report_fact` now. Otherwise nothing is written, the exit is 1, and the error prints the current state, `closed_reason`, remediation and `report_fact`. A record with no task is linked first by recording `awaiting_deploy --task T` again. The new record keeps that `report_fact` in `seen` and the whole `awaiting_deploy` record it replaced in `resolves`. After exit 75, retry the same command with the same `--task`, `--detail` and `--expect`. After a refusal, read the current report and the linked evidence and judge again; never change only `--task` or `--expect`. A scan or an ack never records a deployment. A scan that sees the finding live again clears its remediation: the finding returns live and `unassigned`, and the earlier round's history stays in its linked task/plan. The owner can record `awaiting_deploy` again after `deploy_resolved`, for example when the evidence was wrong or the deploy was rolled back.
- `deploy_resolved` has limits. The product does not authenticate the writer: any process of the same user can write it, so owner-only is this role rule, as for `report_acknowledged`. The product does not verify deployment evidence; it binds the write to the linked task, the owner's words and the report that was read. When the same task is reused across a regression, a new dispatch, a new `awaiting_deploy` and a second closure with the same `report_fact`, a command judged in the earlier round still passes. The lock does not close every such cycle. That is why the owner judges from a status read made after their last dispatch for that finding.

When you are handed a watch finding to repair:

- Work in a fresh worktree from the project's main branch. If main is dirty or another worker is already in that project, record `blocked` and coordinate.
- Run `safedeps check <eco> <pkg>@<fixed>` first, then go through the normal install gates. Raise the range of a direct dependency. Add an `overrides` entry for a transitive one.
- Run the project's tests and `safedeps watch scan --root <root>` before and after.
- Pass: merge locally only. Push and deploy follow that project's existing authority. Record a local merge as `awaiting_deploy`, always, even when a scan has already closed the finding. Do not record it as `fixed_pending_rescan`. Give the linked task/plan in `--task`. In `--detail` and the linked task/plan, record the deployment owner, authority and next action; say explicitly which are unknown. This nonfailure row remains in `awaiting_owner` for the owner to resolve, without automatic assignment or deployment. It stays after a scan closes the finding locally, with the `closed_reason`, after the closure event is acked, and through later scans. A local closure is not a deployment. Only the owner's `deploy_resolved` ends the wait, and you never record it.
- Fail: keep the branch and the logs, leave main untouched, record `fix_failed`.
- No fixed version: the finding is `no_fix_available` and is looked at again every day. Never use a made-up version or an arbitrary downgrade. `SAFEDEPS_ACCEPT_RISK` is a person's decision and is not a repair.
- Record progress with `safedeps watch remediation --finding KEY --state S [--detail TEXT] [--task T]`, where S is `dispatched`, `blocked`, `fix_failed`, `awaiting_deploy` or `fixed_pending_rescan`. It does not close the finding. The next scan that sees the fixed version does. The record captures `scan_generation` under the lock. A later actual measurement of this finding advances its `last_seen_scan_generation` and puts it back in `awaiting_owner` as `rescan_still_live`. Wall time, unrelated roots and unmeasured scopes do not establish this order. A legacy record without the boundary appears as `rescan_order_unknown`; check the evidence, record the boundary again and request a new scan. That scan order is the meaning of `fixed_pending_rescan`, and it is unchanged for an actual runtime fix; a local merge is `awaiting_deploy` instead. On a closed finding whose remediation is `awaiting_deploy`, only `awaiting_deploy` can be recorded again; `dispatched`, `blocked`, `fix_failed` and `fixed_pending_rescan` are refused. `report_acknowledged` and `deploy_resolved` are the owner's, not yours.

Options: `safedeps help watch`. How it works: [ARCHITECTURE.md, The daily watch](./ARCHITECTURE.md#the-daily-watch). Installing the agent: [`README.md`](./README.md#daily-watch-with-macos-alerts).

---

## CLI reference

```
safedeps check <ecosystem> <pkg>@<version|range> [--json]
safedeps ledger [--json]
safedeps revoke <hash> | <ecosystem> <pkg>@<version> | <pkg>@<version> [--reason <r>] [--json]
safedeps re-check [--json]
safedeps watch <scan [--root DIR]|status|claim|claimed|ack|remediation|retire> [--json]
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

**Exit codes**: `0` clean/approved · `2` CVE, no patch (human decision) · `3` CISA KEV hard block · `4` input error, provider unavailable, a check that could not finish, or a ledger that could not be listed (fail-closed).

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
  "result": "clean",
  "approved": true,
  "spec_hash": "sha256:...",
  "expires_at": "2026-06-17T05:39:03Z",
  "closure_source": { "type": "npm-package-probe | npm-overrides-probe | yarn-project-lockfile | yarn-project-materialized-lockfile | yarn-project-candidate-materialization | fixture" },
  "resolved_closure": [ { "ecosystem": "npm", "package": "...", "version": "...", "direct": true } ],
  "install_hint": "install with @scope/pkg@1.2.4"
}
```

- `result` is one of the results in the table under "Then act on `result`".
- `patched_available` adds `suggested_spec`. For npm, `kev_hard_block`, `closure_vulnerable` and `cve_unpatched` carry `closure_vulnerabilities`, one item per risky package of the requested version's closure, each with `package`, `version`, `direct`, `result`, `vulnerabilities` and `kev`. For the other ecosystems, `kev_hard_block` and `cve_unpatched` keep `vulnerabilities` and `kev.matches` at the top level.
- `already_approved` reads `closure_source` from the ledger entry's `project_context`, so it is `null` for an ordinary published-package approval.
- `closure_source.type` is `yarn-project-lockfile` when the closure came from the current directory's Yarn project (root `resolutions` + `yarn.lock`) instead of a fresh published-package probe; it then also carries `context_hash`, `project_root`, `manifest_path`, `lockfile_path`, `resolutions_sha256`, `lockfile_sha256`, `input_sha256`, and `input_files`. A `project_resolution_status` field (e.g. `project-closure-unavailable`, `project-context-invalid`) plus `approval_scope: "deny-only"` means a Yarn project context was detected but the requested package could not be verified in it — the check stays fail-closed even on a clean published closure. With `project-context-invalid` the type is `npm-package-probe` and the source has none of the context fields, because the project could not be read.
- `closure_source.type` is `npm-overrides-probe` when the published-package probe applied the consuming repo's npm `overrides`. It then also carries `context_hash`, `project_root`, `overrides_source` (the manifest path, or `env`), `overrides_sha256`, and the `overrides` themselves. Applying overrides makes the closure project-specific, so the approval is keyed to that override set: a repo with different overrides, or none, does not inherit it. Only concrete pins are honored; `$`-references are dropped. Overrides cannot mask a vulnerability — the probe resolves each one to a concrete version and OSV is queried for that version.
- `closure_source.type` is `yarn-project-materialized-lockfile` when the package was not yet in the project lockfile and safedeps resolved the candidate in a private mirror of the project's canonical inputs. It then also carries `materialization` with the `candidate` locator, the `input_sha256` it was bound to, the `generated_lockfile_sha256`, the exact Yarn `command`, and `isolation: "private-project-mirror"`. Your project tree is never modified. If the mirror, the Yarn run, or the candidate resolution fails, `project_resolution_status` is `project-candidate-materialization-unavailable` and the check denies — the published closure is never used as a fallback. That source has the type `yarn-project-candidate-materialization`.

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

`ledger`, `revoke` and `re-check` return these envelopes:

- `ledger`: `command`, `count`, and `specs`, each with `hash`, `ecosystem`, `package`, `version`, `version_range`, `approved_at`, `expires_at`, `approved_by`, `expired` and `revoked`.
- `revoke`: `command`, `revoked`, `reason`, and `spec`, the ledger entry after revocation.
- `re-check`: `command`, `checked`, `still_clean`, `approvals_store` (`{present, broken, unmatched}`), and the lists `newly_vulnerable`, `kev_hit`, `revoked`, `suspected_forgery` (unvouched entries carry reason `unvouched`) and `errors`. `approvals_store.present` is `false` when the store is missing, `broken` counts corrupt store lines without stopping other judgments, and `unmatched` is a diagnostic count of unique stored hashes absent from the ledger (not a warning). Each `errors` row has a `kind`: `ledger_entry_unreadable` with `file`, or `revoke_failed` or `provider_unavailable` with `ecosystem`, `package`, `version` and `file`. A `provider_unavailable` row is a ledger entry the providers gave no answer for: it is neither still clean nor revoked, and it stays in the ledger. A report with errors exits 1 after it is printed; if the store cannot be read (`approvals_store_unreadable`) or `safedeps-core` is missing (`core_missing`, naming the path), `re-check` exits 4 with no judgments.

Any of the three answers `command` and `error: "ledger_unlisted"` with exit 4 when the ledger's files could not be listed. That is no reading of the ledger, not an empty one.

- `watch scan`: `command`, `run_id`, `exit`, `kind` (`full` or `root`), `root`, `generation`, `scan_generation`, `state_file`, `population`, `summary`, `diff`, `new_events`, `runtime`, `agent_runtime_stale`, `errors` and `ledger`, which is the `re-check` report. A run that could not take the lock prints `command`, `busy`, `error` and `lock` instead.

`migrate` ignores `--json` and always prints its own JSON report, without a `command` field.

---

Human terminal guide, install steps, and internal design: [`README.md`](./README.md), [`ARCHITECTURE.md`](./ARCHITECTURE.md). `safedeps` is the canonical skill name, state namespace, and repository name.
