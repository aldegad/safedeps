# AGENTS.md — safedeps

Conventions for agents (Claude Code, Codex CLI) working in this repo. Claude Code reads this through the `CLAUDE.md` symlink. Edit **this** file, not `CLAUDE.md`.

safedeps gates development dependency installs (npm/pip/cargo/go/gem/maven/nuget) with OSV-backed advisory checks, an approved-spec ledger, and post-install reorg rollback. Full design: [`ARCHITECTURE.md`](./ARCHITECTURE.md).

## Engine support

Claude Code + Codex CLI only — not Grok/Hermes yet. When a hook capability differs between engines, **detect and branch; never assume parity.** Codex sends `turn_id`/`model` in the hook payload; Claude does not.

## Architecture invariants (do not break)

- **npm enforcement authority = the PostToolUse effect gate** (lockfile closure vs ledger + OSV batch).
- **The effect gate cannot deny, so its answer to "I did not finish" is a record, not a block.**
- **What a rollback, a refused step, a skipped rebuild and the unfinished-rollback report say is a closed set of line forms, and the output is what is checked.**
- **A line says what a process or an I/O operation returned only as an `Outcome`, never as a number or a name a caller chooses.**
- **A hook that runs out of time must answer before the runtime kills it.**
- **Two windows are left open, both read from the source and neither measured by running it.**
- **effect-primary is npm-only.** pip/cargo/go/gem/maven/nuget stay on the v2.1 command-gate + reorg model until their closure resolvers land.
- **`SAFEDEPS_ACCEPT_RISK` provides an audited, single-command override for unapproved and vulnerable npm packages without bypassing baseline safety checks.** Future changes must preserve these design rules:
  1. The override is parsed strictly from the command text by a single reader, `Run::accept_risk` and `accept_risk_value` in `rust/src/core.rs`. It accepts only leading assignments in front of each npm install statement and ignores process environments.
  2. Any invalid presence of the override must trigger an immediate pre-install denial via `accept_risk` and `approved` in `rust/src/pre/install.rs`, never falling back to running without the override.
  3. The reason travels only in this call's own pending record, keyed by `tool_use_id`, written to the `accept_risk` field by `rust/src/pre/pending.rs`, so it reaches this command's post-install hook and no other call, never persisting to the ledger.
  4. Only unapproved packages and vulnerable packages can be kept, evaluated by `effect::Accepted` in `rust/src/post/effect.rs`. A CISA KEV listing, a closure that cannot be read, a KEV catalog that cannot be read, a ledger check or OSV batch that cannot run, or heuristic integrity findings must strictly roll back.
  5. In `keep` within `rust/src/post/run.rs`, the audit entry via `state::accepted_risk_path` and `state::append_accepted_risk` in `rust/src/state.rs` must be written first; any failure to write the audit record must roll back the installation.
  6. Kept installs must never trigger `npm rebuild` and must never advance the verified baseline (`confirmed_<dir hash>`).
  7. The pre-install engine asymmetry must remain intact: Claude Code permits unapproved specs while withholding scripts, whereas Codex CLI must refuse named specs because it cannot withhold script execution.
  These invariants are enforced by `accept_risk_counts_only_in_front_of_each_npm_install` in `rust/src/core/reader_tests.rs`, the `SAFEDEPS_ACCEPT_RISK` rows of `scripts/test/e2e.sh`, and the `accepted` block of `scripts/test/lib/report-oracle.sh`.
- **Inert install (Claude only).**
- **Every rewrite holds the floor.**
- **A script the Bash rewrite could not read as the shell will is a payload the core reads.**
- **The record is an allow-list over the command's bytes.**
- **Where no place reads as true, and where no rewrite is sent.**
- **Which words the shell decides is an allow-list, never a list of what expands.**
- **Whether npm keeps the flag is not safedeps' to say.**
- **An install is left as written only when its own arguments leave the option true.**
- **An install that asks for its scripts is overridden and recorded in `advisory.log`, never denied.**
- **The permission to run scripts comes from a check of the whole tree, never from a judgment of the change.**
- **A record's URL is not where the bytes came from.**
- **Where bytes came from is a fact of the fetch, so it is recorded when the gate sees the fetch and looked up afterwards, never inferred again.**
- **Code the command runs first is the one unknown that records nothing, and only where npm answered the public registry.**
- **The exemption never replaces an answer npm gave.**
- **The source and install-script checks that must pass first read what the install brought into either lockfile.**
- **A plain `npm rebuild` follows a project `.npmrc`** into the global tree, and without `--prefix` it walks up from a workspace member to the root; do not drop the flags.
- **The rollback runs no npm.**
- **OSV is the single canonical advisory truth.** KEV is a hard-risk overlay; GHSA is enrichment. Do not add a second co-equal truth.
- **No silent fallback.** A provider miss is fail-closed. Every bypass must be observable and logged.
- **A read a verdict rests on answers by its exit status, not by what it printed, and each one checks its own return, because errexit does not reach it.**
- **The hook path is the entry shim and the binary it runs, and breaking either blocks Bash machine-wide.**
- **The install grammar is defined once, in the core, and it is on the PreToolUse path.**
- **Beside a visible install the pipe question is the standalone one, asked of the same text; nothing is set aside first.**
- **A reading that cannot finish must not read as "no install".**
- **The command is read by one lexer, `Lex` in `rust/src/lex.rs`, and every reader takes a view of it.**
- **Where a command starts is an event, not a byte.**
- **A reader lexes the command as written, or a payload (a `sh -c`/`eval` script, a substitution's body), or a piece of one cut at offsets, and never a view's output.**
- **Structure leaves the lexer as a rendering or as numbers; a record that carries the command's bytes is never cut by a reader.**
- **A redirection is one set of bytes, read once (`redirs()`), and every view that removes it removes those.**
- **Whether a byte ends a word is answered by the walk's depth alone.**
- **The recognizers end a word where the lexer does.**
- **A reading is a shell -- bash, zsh or dash -- and every reader reads inside one reading.**
- **A judgment's cost is a claim about shapes measured on a host, and a command a judgment cannot finish is answered, not killed.**
- **A cost that grows with the number of statements, not the bytes, was a defect of the Bash guard, and the core must not bring it back.**
- **Quotes and backslashes are read the way the shell reads them.**
- **`advisory.log` is derived from `SAFEDEPS_HOME`, never from its own variable.**
- **No SaaS dependency** — local CLI + public DBs only. The tool itself has **zero npm dependencies**; keep it that way (it is a security property, not an oversight).
- The ledger is a same-user convenience cache, **not** a security boundary against a same-user attacker (until signing/re-query lands). Do not document it as one.
- **Two implementations share the ledger's format: the core reads it and the CLI writes it.**
- **The Rust core is the hook, and there is no second authority.**

## CI

GitHub CI is not used: no test workflow is created or run on GitHub. CI runs separately, on the infrastructure Alex set up (the remote runners and test machines named under Testing). The reason is that GitHub's CI is too slow. This section mirrors the owner's global rule, and a new project copies it into its own `AGENTS.md`. `scripts/ci/run-on-hosts.sh` runs a test set on those hosts, and `scripts/ci/release-checks.sh` runs the release checks that are not batteries. The repository has no `.github/workflows/`: publishing to npm is a release step on our own hosts too (`RELEASING.md` step 10), so nothing runs on GitHub.

## Version SSoT

`package.json` `version` is the single source of truth. `bin/safedeps` `SAFEDEPS_VERSION`, the `version` in `rust/Cargo.toml` and the `safedeps-core` entry of `rust/Cargo.lock` must match it; the smoke test reads `package.json` to enforce all three, and the publish step (Release procedure, step 10) checks the tag against `package.json`, `bin/safedeps`, `rust/Cargo.toml` and the built binary. Bump them together — a feature (e.g. effect/inert) is a minor bump, docs-only is a patch. A change that moves a verdict is a feature, and the bump changes the crate's source digest, so the binaries are built again.

## Docs

- **English is SSoT; Korean is a mirror** named `<name>.ko.md` (`README.ko.md`, `ROADMAP.ko.md`, `ARCHITECTURE.ko.md`). Keep both in sync in the same change. `SKILL.md` is English (the loader-read manifest).
- No Korean prose in an English doc (CLI-output *examples* may show Korean). No version/concept drift between README/ARCHITECTURE/SKILL — they must agree on what is "primary", the npm-only boundary, and inert install.
- Write clean prose: short sentences, no run-ons, no parenthetical pile-ups, consistent register.
- Run the **consistency audit** (`RELEASING.md`) before shipping any doc change.

## Hooks

- Read `tool_input.command` (single field). `permissionDecision` is `allow`/`deny`/`ask`. `updatedInput` rewrites the command but is **Claude-only** — gate it on engine.
- The hooks are one binary, `safedeps-core`: `safedeps-core pre` is the PreToolUse hook (its advisory and deny lines still say "pre-guard") and `safedeps-core post` the PostToolUse hook. `chmod +x` the entry shim and commit it as mode `100755`; a missing exec bit is `Permission denied` in every session.
- **Registration has one channel: the installer.**
- The registered command for both events is the entry shim `scripts/safedeps-hook-entry.sh pre|post`, not the binary directly. It relies on one contract: **the core exits 0 on every designed path** (decisions travel as JSON) — never add an intentional non-zero exit to the core.
- Hooks block clearly and explain; never a silent fallback.
- Installed copies under `~/.claude`/`~/.codex` are symlinks to this repo — edit the repo, never the installed copy.

## Testing

- The suite runs on our hosts: alex-macbook-m1 and carenine for macOS (runner `~/safedeps-runs/slot.sh`), and WSL1 on the home Windows PC for Windows, the environment Kuma Studio's Windows build runs in. Linux is not tested: Kuma Studio ships for Windows and macOS only. A run has no time budget, and speed is not a goal.
- Two commands, one runner (`scripts/test/run-all.sh`). `npm test` is the development run: every battery except the native scan-failure census (`native-scan-failures.sh`) and `effect-trace-grid.sh`. `npm run test:release` runs every battery, those two included. A change that reaches the scan readings or the effect gate runs them by name: `scripts/test/native-scan-failures.sh`, `scripts/test/effect-trace-grid.sh`. Keep both commands green.
- `run-all.sh --list` prints the batteries a run would start, with `--release` as for a run. `--units` prints the units the host runner splits that set into, and `--plan` adds each unit's weight and seconds.
- The batteries run in parallel. They keep their state apart: each makes its own mktemp root, points `HOME` or `SAFEDEPS_HOME` into it, and starts its fixture servers on a port the kernel picks. A new battery keeps the same isolation, or it cannot run beside the others.
- The runner never takes the whole machine by default. At most `SAFEDEPS_TEST_JOBS` batteries run at once. The default is half the CPUs, rounded up. Raise it on a dedicated machine, or set it to 1 for the least load.
- **The host runner.** `scripts/ci/run-on-hosts.sh [--release] [--hosts a,b]` ships a commit, as `git archive`, to the hosts named in `~/.config/safedeps/test-hosts`. The format is in `scripts/ci/test-hosts.example`; host addresses stay out of this public repository.
- **Row shards.** A battery too long for one unit takes `--shard I/M` (`scripts/test/lib/shard.sh`). What a later row reads is made in every shard: a package a row publishes, an input drawn from the seed. A check that counts over many rows (a floor such as "more than 1000 events") takes the shard's share. A row's label holds nothing one run made: a temporary path, the tree's path or a fixture's port is written as a name (`shard_mask`), so shards on different hosts agree on the list.
- **The reader batteries ask the core and do not source a hook.**
- **A battery that draws random input draws all of it before it checks anything.**
- **The verdict is red** when a host failed, a unit left no exit status or two, a unit's files name another run's directory or none, a unit exited non-zero or printed `not ok`, a unit printed no `ok` line, a unit printed a skipped row (`ok ... SKIPPED`, or a TAP skip directive in any case, `# SKIP` or `# skip`) that `SKIP_ALLOWED` does not name, or a split battery's shards do not add up to its rows.
- Each battery writes its own log. At the end the runner prints every log in a fixed order, then one summary line per battery: exit code, `ok` and `not ok` counts, seconds, and the load at start and end. Then it prints the tail of each failed log. It exits non-zero when any battery exits non-zero, prints `not ok` or prints no `ok` line, and it names them. It does not judge skipped rows; the host runner's verdict does.
- `SAFEDEPS_TEST_SERIAL=1 npm test` runs the batteries one at a time, in the order of the old `&&` chain. When a battery fails only in parallel, rerun it this way before you call it a defect or a flake. `SAFEDEPS_TEST_LOG_DIR=<dir>` keeps the logs in a directory you choose.
- A security change needs **both** a bypass harness (the threat must DENY/REORG) and a regression check (normal installs still pass; no false positives on `echo`/heredoc/`npm run`/`npx`).
- **Cite counts a reader can reproduce from the repo.** Quote the battery's own form count or `npm test`'s ok lines, or commit the corpus you counted.

### What to run, and where

Each measurement runs once, at the level where it can fail.

- **Per change** (one plan's branch): the batteries the change reaches, once on macOS; one mutation control per fix, on a copy, where reverting the fix turns its new row red; and any measurement the plan's Done Criteria names. Nothing else.
- **Per release** (the integration tree, before main moves): `npm run test:release` on both platforms (`native-scan-failures.sh` and `effect-trace-grid.sh` included), and the judgment grids, corpora and replays of the areas the release changed. These do not run per branch unless the plan's Done Criteria names one.
- **A change to `rust/`** runs the batteries it reaches, on a core built from that change, and the release runs the whole development and release sets on both macOS hosts. A change that reaches the lexer, the grammar or the extractor runs `scan-contract`, `shell-reading`, `manager-variants` and `consumer-forms` by name.
- **A validator** reads the worker's own logs on the hosts and checks them against the claim. Its own runs are counterexample probes the author did not write, and one control showing a probe can fail. It does not rerun the worker's batteries.
- **A second rejection of the same class stops the patching.** When review rejects one class of defect twice, the next round starts with a design judgment, not a third shape fix.

The bypass-harness and regression rule above still holds for every security change; this section only says where each run happens.

## Verification hygiene

- **Run mutations on a copy, never in the plan worktree.**
- **Sandbox names come from `mktemp`, not from `$$-$RANDOM`.**
- **A test that suspends a process reaps it three ways.** An EXIT trap covers
  ordinary exits; a marker sweep at suite start covers SIGKILL, which defeats
  traps; and spawning children with a cwd outside the worktree removes what the
  leak costs, since an orphan holding the plan worktree makes the close gate
  refuse to prescribe removal at finalize. Scope any sweep with a marker only
  your own children carry. The marker carries the run's pid, and the sweep
  reaps only markers whose run is gone. Its name must not contain an older
  marker either, or a checkout still sweeping by that substring matches it.

### Citing a zero

A run that found nothing is a claim about a measurement, and three ways of
making that claim are wrong.

1. **A zero from a harness with no control is not evidence.** If the check
   cannot fail, its silence says nothing.
2. **A trial whose condition was not measured is not an observation of that
   condition.** Record the condition per trial or the batches can neither be
   compared nor combined.
3. **Say whether a label came from measurement or from someone saying so.**
   Hearsay carries no sense of not having measured, so it passes check 2.

## Workflow

- Branch off `main`; do not commit to `main` directly.
- **Never resolve merge conflicts in the main checkout.** The installed hooks execute the main checkout live. Integrate in your worktree (merge `main` into your branch, resolve, test), then move `main` forward fast-forward-only (`git merge --ff-only`). The entry shim softens the blast, but the discipline removes the window.
- **Write commit messages through a quoted heredoc** (`git commit -F - <<'EOF'`), never `-m "..."`. Inside double quotes a backtick is command substitution, and this repo's messages quote install commands in backticks as a matter of course: a message about a bypass would run the bypass.
- **A harness judges commands; it never runs them.** Feed a form to the guard as a payload. Do not `bash -c` it to "see what the shell does" -- the form is an install by construction. When shell semantics are the question, use an `echo` in place of the package manager.
  **The one exception is a battery that measures the package manager itself** -- what npm writes and where, what `npm rebuild` executes -- because no payload can answer that. `scripts/test/lockless-forms.sh` and `scripts/test/effect-trace-grid.sh` are the two, and both source `scripts/test/lib/npm-sandbox.sh`.

## Release procedure

`RELEASING.md`
