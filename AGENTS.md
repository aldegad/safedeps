# AGENTS.md — safedeps

Conventions for agents (Claude Code, Codex CLI) working in this repo. Claude Code reads this through the `CLAUDE.md` symlink. Edit **this** file, not `CLAUDE.md`.

safedeps gates development dependency installs (npm/pip/cargo/go/gem/maven/nuget) with OSV-backed advisory checks, an approved-spec ledger, and post-install reorg rollback. Full design: [`ARCHITECTURE.md`](./ARCHITECTURE.md).

## Engine support

Claude Code + Codex CLI only — not Grok/Hermes yet. When a hook capability differs between engines, **detect and branch; never assume parity.** Codex sends `turn_id`/`model` in the hook payload; Claude does not.

## Architecture invariants (do not break)

- **npm enforcement authority = the PostToolUse effect gate** (lockfile closure vs ledger + OSV batch). The PreToolUse command guard is a fast advisory/UX layer, *not* the authority. **This holds inside the hook budget only** — both hooks are killed at their registered timeout (30s when measured, 2026-08-04) and the effect gate's work is network- and project-bound, so do not write "npm is covered" without that qualifier. **The range is measured, so quote it rather than the word "structural"**: the gate crossed 30s at a closure of *four* packages until v2.16.0 stopped re-reading the whole ledger per package, and it crosses near 390 packages after. Re-measure with `scripts/measure/effect-gate-cost.sh` before writing a number — the crossing moves with host, network and cache, and a number from someone else's machine is decoration.
- **The effect gate cannot deny, so its answer to "I did not finish" is a record, not a block.** The install already ran. A rollback writes its journal entry *before* the first destructive act and clears it after it has reported itself, so an entry that outlives its run is itself the report — the next PostToolUse turns it into a durable incident plus a `REORG INTERRUPTED` line in `reorg.log`. **"Outlives its run" is a liveness claim, not a file test**: a rollback in progress has its own entry on disk by design, so the report is gated on the entry's recorded pid being gone (v2.16.1 — an unrelated Bash call used to read a live entry and report a working rollback as interrupted). The state lock cannot stand in for that check; it is released before the rollback begins. pid reuse is settled by process start time, and an owner that cannot be resolved counts as gone, because the failure to prefer is noise over silence. A zombie counts as gone too (v2.16.2): it keeps its table entry and its start time, so it clears both other tests, and it never goes away — reading one as alive loses the report permanently rather than delaying it. Do not move the record back after the work; that ordering is the whole defect (measured: a kill mid-rollback left `reorg.log` at zero lines with the project already reverted). And do not sell this as atomicity — safedeps does not own the atomicity of an npm tree rebuild.
- **A hook that runs out of time must answer before the runtime kills it.** The runtime's timeout is fail-open: the hook dies and the tool call proceeds. So the pre-guard keeps its own smaller budget (`SAFEDEPS_SELF_BUDGET_SECONDS`) and denies when its judgment does not finish. Keep that deny phrased as *undecided*, never as a detection — the two are different claims and conflating them teaches people to route around the gate. **That budget is clamped below the runtime's, and the clamp is part of the boundary, not a nicety**: any value at or above the registered hook timeout hands the kill back to the runtime and restores the fail-open, and the motive to raise it (an `UNDECIDED` on a big command reads as "the budget is short") is ordinary enough that leaving it open is the same as leaving it off. Lowering stays free, and the clamp says out loud that it happened. **The same holds for `SAFEDEPS_BUDGET_ENGAGE_BYTES`**, which decides whether the budget runs at all: it is clamped to 4KB, because a tuning knob that can be raised without limit is an off switch. Turning the deadline off is a separate, differently named act (`SAFEDEPS_BUDGET_DISABLED`) that logs every use — the battery's mutation check needs it, and a test that cannot produce the unbounded case only knows it passes, not that it catches anything. Keep tuning and disabling separate levers. **The parent/child marker lives in argv, never in the environment** — as an env var it was a second, unnamed off switch (export it and the parent skipped the deadline, silently); the entry shim passes no arguments, so argv is a channel the environment cannot reach.
- **effect-primary is npm-only.** pip/cargo/go/gem/maven/nuget stay on the v2.1 command-gate + reorg model until their closure resolvers land.
- **Inert install (Claude only).** The PreToolUse hook injects `--ignore-scripts` via `hookSpecificOutput.updatedInput`; post-verify runs `npm rebuild` only after the closure verifies clean, so a rejected package's lifecycle scripts never run. Codex lacks `updatedInput`, so it falls back to detect-and-rollback — keep this asymmetry honest in code and docs.
- **OSV is the single canonical advisory truth.** KEV is a hard-risk overlay; GHSA is enrichment. Do not add a second co-equal truth.
- **No silent fallback.** A provider miss is fail-closed. Every bypass must be observable and logged.
- **`lib/truth-sources.sh` is on the PreToolUse path, so breaking it blocks Bash machine-wide.** The guard sources it on every Bash call to report a moved advisory source, unconditionally and without an environment override (an override was a silent off switch for the notice, caught in review). A parse error there takes the guard down, which the entry shim turns into an explained fail-closed deny — the right direction, and a wider blast radius than the file's size suggests. Edit it in a worktree and run `npm test` before it reaches the main checkout.
- **`advisory.log` is derived from `SAFEDEPS_HOME`, never from its own variable.** It is not just a log: `re-check` reads it as the oracle for whether an approval ever happened, so a movable path let the same environment that forges a ledger entry also supply its provenance (measured — the forgery flag disappeared). Record and ledger move together or not at all. Moved advisory sources (provider URLs, closure fixtures, a non-default ledger TTL) stay allowed and are announced there once per run: a run that answered from a mirror must not look like a run that answered from OSV.
- **No SaaS dependency** — local CLI + public DBs only. The tool itself has **zero npm dependencies**; keep it that way (it is a security property, not an oversight).
- The ledger is a same-user convenience cache, **not** a security boundary against a same-user attacker (until signing/re-query lands). Do not document it as one.

## Version SSoT

`package.json` `version` is the single source of truth. `bin/safedeps` `SAFEDEPS_VERSION` must match it; the smoke test reads `package.json` to enforce the match. Bump them together — a feature (e.g. effect/inert) is a minor bump, docs-only is a patch.

## Docs

- **English is SSoT; Korean is a mirror** named `<name>.ko.md` (`README.ko.md`, `ROADMAP.ko.md`, `ARCHITECTURE.ko.md`). Keep both in sync in the same change. `SKILL.md` is English (the loader-read manifest).
- No Korean prose in an English doc (CLI-output *examples* may show Korean). No version/concept drift between README/ARCHITECTURE/SKILL — they must agree on what is "primary", the npm-only boundary, and inert install.
- Write clean prose: short sentences, no run-ons, no parenthetical pile-ups, consistent register. **User-facing prose is a Claude job — do not dispatch doc rewriting to a Codex worker** (its output reads clunky).
- Run the **consistency audit** below before shipping any doc change.

## Hooks

See the `skill-hook-authoring` skill for the full payload/decision schema. Essentials:

- Read `tool_input.command` (single field). `permissionDecision` is `allow`/`deny`/`ask`. `updatedInput` rewrites the command but is **Claude-only** — gate it on engine.
- `chmod +x` every hook and commit mode `100755`; a missing exec bit is `Permission denied` in every session.
- **Registration has one channel: the installer.** `SKILL.md` does not declare hooks, and that is a decision, not an oversight. Claude does document skill-frontmatter hooks (`hooks: {PreToolUse: [{matcher, hooks: [{type, command}]}]}`), but they are **scoped to the skill's lifecycle — they only run while the skill is active**, and this gate has to judge every Bash call whether or not the skill was invoked. So the documented form cannot do this job, and a second declaration of a registration is a second thing to keep true. The smoke drift check deliberately fails only on the legacy `script:` shape that no schema reads; it does not forbid the documented shape, because blocking a working feature by grep is not the same as removing a dead one.
- The registered command for both events is the entry shim `scripts/safedeps-hook-entry.sh pre|post`, not the hook scripts directly. The shim turns a broken hook source (mid-merge checkout, crash, missing file) into an explained fail-closed deny. It relies on one contract: **the real hooks exit 0 on every designed path** (decisions travel as JSON) — never add an intentional non-zero exit to a hook script.
- Hooks block clearly and explain; never a silent fallback.
- Installed copies under `~/.claude`/`~/.codex` are symlinks to this repo — edit the repo, never the installed copy.

## Testing

- `npm test` runs smoke + e2e. Keep it green.
- A security change needs **both** a bypass harness (the threat must DENY/REORG) and a regression check (normal installs still pass; no false positives on `echo`/heredoc/`npm run`/`npx`).
- **Cite counts a reader can reproduce from the repo.** "159 forms" measured in a scratch corpus is decoration — nobody can check it, and a number nobody can check reads as verification without being any. Quote the battery's own form count or `npm test`'s ok lines, or commit the corpus you counted.

## Workflow

- Branch off `main`; do not commit to `main` directly.
- Do **not** commit or push unless asked. Use logical commits with clear messages.
- **Never resolve merge conflicts in the main checkout.** The installed hooks execute the main checkout live; conflict markers there blocked Bash machine-wide on 2026-08-04. Integrate in your worktree (merge `main` into your branch, resolve, test), then move `main` forward fast-forward-only (`git merge --ff-only`). The entry shim softens the blast, but the discipline removes the window.

## Consistency audit (before release or doc changes)

```bash
# version SSoT
[ "$(jq -r .version package.json)" = "$(./bin/safedeps --json version | jq -r .version)" ] || echo "VERSION MISMATCH"
grep -rqiE 'current.*2\.[0-9]+\.[0-9]+' ROADMAP*.md   # sanity-check the "current vX.Y.Z" line is right
# language purity: English docs have no Korean prose (ko-link lines excepted)
for f in README.md ROADMAP.md ARCHITECTURE.md; do
  grep -vP '\]\(\./[A-Za-z]+\.ko\.md\)' "$f" | grep -qP '[\x{AC00}-\x{D7A3}]' && echo "KOREAN IN $f"
done
# concept presence across the prose docs
grep -lqi 'inert\|--ignore-scripts' README.md ARCHITECTURE.md SKILL.md || echo "inert-install undocumented"
npm test
```
