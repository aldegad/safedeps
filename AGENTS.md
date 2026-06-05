# AGENTS.md — safedeps

Conventions for agents (Claude Code, Codex CLI) working in this repo. Claude Code reads this through the `CLAUDE.md` symlink. Edit **this** file, not `CLAUDE.md`.

safedeps gates development dependency installs (npm/pip/cargo/go/gem/maven/nuget) with OSV-backed advisory checks, an approved-spec ledger, and post-install reorg rollback. Full design: [`ARCHITECTURE.md`](./ARCHITECTURE.md).

## Engine support

Claude Code + Codex CLI only — not Grok/Hermes yet. When a hook capability differs between engines, **detect and branch; never assume parity.** Codex sends `turn_id`/`model` in the hook payload; Claude does not.

## Architecture invariants (do not break)

- **npm enforcement authority = the PostToolUse effect gate** (lockfile closure vs ledger + OSV batch). The PreToolUse command guard is a fast advisory/UX layer, *not* the authority.
- **effect-primary is npm-only.** pip/cargo/go/gem/maven/nuget stay on the v2.1 command-gate + reorg model until their closure resolvers land.
- **Inert install (Claude only).** The PreToolUse hook injects `--ignore-scripts` via `hookSpecificOutput.updatedInput`; post-verify runs `npm rebuild` only after the closure verifies clean, so a rejected package's lifecycle scripts never run. Codex lacks `updatedInput`, so it falls back to detect-and-rollback — keep this asymmetry honest in code and docs.
- **OSV is the single canonical advisory truth.** KEV is a hard-risk overlay; GHSA is enrichment. Do not add a second co-equal truth.
- **No silent fallback.** A provider miss is fail-closed. Every bypass must be observable and logged.
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
- Hooks block clearly and explain; never a silent fallback.
- Installed copies under `~/.claude`/`~/.codex` are symlinks to this repo — edit the repo, never the installed copy.

## Testing

- `npm test` runs smoke + e2e. Keep it green.
- A security change needs **both** a bypass harness (the threat must DENY/REORG) and a regression check (normal installs still pass; no false positives on `echo`/heredoc/`npm run`/`npx`).

## Workflow

- Branch off `main`; do not commit to `main` directly.
- Do **not** commit or push unless asked. Use logical commits with clear messages.

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
