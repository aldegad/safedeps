# AGENTS.md — safedeps

Conventions for agents (Claude Code, Codex CLI) working in this repo. Claude Code reads this through the `CLAUDE.md` symlink. Edit **this** file, not `CLAUDE.md`.

safedeps gates development dependency installs (npm/pip/cargo/go/gem/maven/nuget) with OSV-backed advisory checks, an approved-spec ledger, and post-install reorg rollback. Full design: [`ARCHITECTURE.md`](./ARCHITECTURE.md).

## Engine support

Claude Code + Codex CLI only — not Grok/Hermes yet. When a hook capability differs between engines, **detect and branch; never assume parity.** Codex sends `turn_id`/`model` in the hook payload; Claude does not.

## Architecture invariants (do not break)

- **npm enforcement authority = the PostToolUse effect gate** (lockfile closure vs ledger + OSV batch). The PreToolUse command guard is a fast advisory/UX layer, *not* the authority. **It reads npm's two records of a project install — `package-lock.json` and the hidden `node_modules/.package-lock.json` — in one directory, chosen before the command runs by asking npm: `npm prefix` and `npm root`, run where the command runs npm and with the statement's own arguments and environment (`lib/npm/ask.sh`).** Do not answer that question in bash again. Two copies of npm's rules each disagreed with npm and each disagreement was a silent pass: the named directory itself sent the gate to `src` while npm wrote the project's lockfiles, and a workspace resolver that resolved symlinks climbed to a root npm did not. **An install counts as read only when the directory the gate read shows this call's install trace; prediction chooses where to look, never whether it was covered.** Just before the command runs, the pre-guard touches a baseline file and notes the inode of both lockfiles there; the post hook counts a lockfile `find -newer` than the baseline, or one with another inode, as the trace. Where neither shows one it records `UNGATED` ("no install trace in <dir>: the install landed elsewhere or installed nothing") and runs no rebuild there. Three rounds made the prediction better and each left a silent pass (a `cd` that never ran, `command cd`, a symlinked member); with the trace, a wrong prediction is a record. Do not compare content or whole seconds: a reinstall of what is already there rewrites the hidden lockfile with the same bytes, often inside the second the baseline was touched in. Two or more lockfile-writing npm statements share one trace only when nothing but inert statements (`echo`, `printf`, `tail`, `head`, `grep`, `ls`, `cat`, `true`, without redirection or substitution) runs between them and none relocates itself; otherwise the command is `UNGATED`, because the first one's trace hid the second one landing elsewhere. A `cd` that may not run (after `&&` or `||`, or inside a compound command) is followed only along the `&&` chain after it; `cd X || exit` is followed. Where npm cannot be asked or does not answer within its deadline, and where the command carries a word the shell decides at run time, the target is `?`, the reason is recorded, and the gate looks in the cwd. npm masks anything shaped like a UUID or a token in what it prints, paths included (11.19.0, measured), so a masked answer is never used as a path: it stands for the one directory from the cwd up that reads the same, and is `?` otherwise. npm's answer covers every `.npmrc` it reads. Whether npm writes a record where it installs is a separate question npm cannot be asked before the install, so the pre-guard still reads `global` and `location` in the project's and the user's `.npmrc` for that, and only for that: it can turn a read install into an `UNGATED` one, never choose a directory. `scripts/test/install-dir-differential.sh` holds the gate to `npm prefix` over 237 layouts. **This holds inside the hook budget only** — both hooks are killed at their registered timeout (30s when measured, 2026-08-04) and the effect gate's work is network- and project-bound, so do not write "npm is covered" without that qualifier. **The range is measured, so quote it rather than the word "structural"**: the gate crossed 30s at a closure of *four* packages until v2.16.0 stopped re-reading the whole ledger per package, and it crosses near 390 packages after. Re-measure with `scripts/measure/effect-gate-cost.sh` before writing a number — the crossing moves with host, network and cache, and a number from someone else's machine is decoration.
- **The effect gate cannot deny, so its answer to "I did not finish" is a record, not a block.** The install already ran. A rollback writes its journal entry *before* the first destructive act and clears it after it has reported itself, so an entry that outlives its run is itself the report — the next PostToolUse turns it into a durable incident plus a `REORG INTERRUPTED` line in `reorg.log`. **"Outlives its run" is a liveness claim, not a file test**: a rollback in progress has its own entry on disk by design, so the report is gated on the entry's recorded pid being gone (v2.16.1 — an unrelated Bash call used to read a live entry and report a working rollback as interrupted). The state lock cannot stand in for that check; it is released before the rollback begins. pid reuse is settled by process start time, and an owner that cannot be resolved counts as gone, because the failure to prefer is noise over silence. A zombie counts as gone too (v2.16.2): it keeps its table entry and its start time, so it clears both other tests, and it never goes away — reading one as alive loses the report permanently rather than delaying it. **A stopped owner is a third answer, not a gone one** (v2.17.0), so "gated on the pid being gone" is not the whole rule: a suspended process has not died and is not progressing, and calling it either way reproduces one of the two defects above. It is reported with its pid still alive, and the report says to resume or kill it before repairing. Stopped is judged only after the start-time check confirms the pid still belongs to this entry — ahead of it, any stopped process holding a recycled pid turned a genuinely interrupted rollback into "suspended, resume it" (caught in review). Do not move the record back after the work; that ordering is the whole defect (measured: a kill mid-rollback left `reorg.log` at zero lines with the project already reverted). And do not sell this as atomicity — safedeps does not own the atomicity of an npm tree rebuild.
- **A hook that runs out of time must answer before the runtime kills it.** The runtime's timeout is fail-open: the hook dies and the tool call proceeds. So the pre-guard keeps its own smaller budget (`SAFEDEPS_SELF_BUDGET_SECONDS`) and denies when its judgment does not finish. Keep that deny phrased as *undecided*, never as a detection — the two are different claims and conflating them teaches people to route around the gate. **That budget is clamped below the runtime's, and the clamp is part of the boundary, not a nicety**: any value at or above the registered hook timeout hands the kill back to the runtime and restores the fail-open, and the motive to raise it (an `UNDECIDED` on a big command reads as "the budget is short") is ordinary enough that leaving it open is the same as leaving it off. Lowering stays free, and the clamp says out loud that it happened. **The same holds for `SAFEDEPS_BUDGET_ENGAGE_BYTES`**, which decides whether the budget runs at all: it is clamped to 4KB, because a tuning knob that can be raised without limit is an off switch. Turning the deadline off is a separate, differently named act (`SAFEDEPS_BUDGET_DISABLED`) that logs every use — the battery's mutation check needs it, and a test that cannot produce the unbounded case only knows it passes, not that it catches anything. Keep tuning and disabling separate levers. **The parent/child marker lives in argv, never in the environment** — as an env var it was a second, unnamed off switch (export it and the parent skipped the deadline, silently); the entry shim passes no arguments, so argv is a channel the environment cannot reach.
- **effect-primary is npm-only.** pip/cargo/go/gem/maven/nuget stay on the v2.1 command-gate + reorg model until their closure resolvers land.
- **Inert install (Claude only).** The PreToolUse hook injects `--ignore-scripts` via `hookSpecificOutput.updatedInput`; post-verify runs `npm rebuild` only after the closure verifies clean, only when every node npm says the rebuild would run over (`npm query '*'`, links followed into their targets) passes a check of the whole tree, and with `--global=false --location=project --prefix <the directory the gate read>`, so a rejected or unread package's lifecycle scripts never run. The check: every node is one a lockfile records at that location, version and name (a key alone is not a record: an `.npmrc` let npm write 1.0.1 over a recorded 1.0.0; and a `file:` dependency's own `node_modules` is rebuilt with the project); every node under `node_modules` has every record name a public-registry https source (`SAFEDEPS_NPM_PUBLIC_REGISTRY_RE`, the one pattern the source check uses too) that npm says it fetched from there, or is bundled by its parent, judged from the tree and never from a lockfile's `inBundle` (the parent is under `node_modules` and passes the check itself, its `package.json` on disk names the package in `bundleDependencies`/`bundledDependencies`, and no record of the nested package names a non-public source; a committed record's flag and the root's own `bundleDependencies` each let an http tarball pass as bundled before, NB1 and NB2); every node outside it is a declared workspace member. Otherwise the whole rebuild is skipped with a warning naming each node, never a rollback. **The permission to run scripts comes from that check of the whole tree, never from a judgment of the change** — scripts run over the whole tree, and three holes in the change judgment in a row (a hidden lockfile not read, links dropped, an unverified rollback target) each became a script that ran; do not add a script path that asks only what the command changed. A query that fails or does not answer skips the rebuild. **A record's URL is not where the bytes came from**: npm's default `replace-registry-host=npmjs` fetches a registry.npmjs.org URL from the configured registry and records it unchanged, and a committed `.npmrc` or `npm_config_registry` ran an impostor's scripts under a record that read as public (RH1-RH3). So npm is asked which registry it fetches from (`npm config ls --json`, the fetch facts in `lib/npm/ask.sh`), beside `npm prefix` with the statement's own words before the command, and again in the read directory after it; a public URL vouches only when both answers say npm fetched it from the public registry. npm's answer never denies or rolls back an install: a company registry, a mirror and a proxy look exactly like an impostor's registry, and nothing can approve one yet, so a non-public answer keeps the install, withholds the rebuild, and the warning names the registry and tells the agent to confirm with the user before running `npm rebuild` itself (an agent told only to rebuild would run what the check withheld). Only a `--registry` the command spells out is denied, by the text check. Approving a registry is the next release's job; do not turn the warning back into a deny or a rollback without it. A missing answer withholds the scripts and is never a reason to roll back. **Where bytes came from is a fact of the fetch, so it is recorded when the gate sees the fetch and looked up afterwards, never inferred again.** Three readings in a row answered it with something not bound to the bytes, a lockfile's `inBundle`, its `resolved`, and the configuration at rebuild time, and each was a silent pass: once the setting that fetched an impostor was gone, the next approved install, a bare `npm install`, an `npm ci` from npm's cache, a rollback to a snapshot confirmed with it, and another project's `npm ci` of the same lockfile each rebuilt it. The one value npm binds to the bytes is integrity, so each integrity an install brings into either lockfile that npm did not say it fetched from the public registry is written to `${SAFEDEPS_HOME}/npm-withheld` (derived from `SAFEDEPS_HOME` like `advisory.log`, one file per run, renamed into place), by both engines, before the reorg decision. The record is machine-wide because npm's cache, which carries the bytes to other projects by integrity, is. The whole-tree check refuses a node that holds a recorded integrity, and a public record with no integrity at all, and skips the rebuild when the record cannot be read. Nothing releases a record in v2.18.0; the bytes leaving the tree is the only way out. The boundary is bytes from a fetch the gate never judged (an install outside the hooks, one it did not recognize or recorded `UNGATED`, a registry neither ask can see): a fourth counterexample of this class can come only from there. Do not read `.npmrc` or the environment for this in bash; the answer is npm's. Each lockfile field the check reads, and what it cannot vouch for, is tabled in ARCHITECTURE.md with the row that holds it. The source and install-script checks that must pass first read what the install brought into either lockfile, compared with both records from before the command, never only a changed `package-lock.json`: an install that saves nothing changes neither file, and until they read the hidden lockfile a tarball with an approved name and version passed both and the rebuild ran its scripts. A plain `npm rebuild` follows a project `.npmrc` into the global tree, and without `--prefix` it walks up from a workspace member to the root (both measured); do not drop the flags. The rollback's reinstall uses the same flags and is always inert (`npm ci --ignore-scripts`, or `npm install --ignore-scripts` when there is no lockfile or `npm ci` failed). Its scripts run only through the same rebuild, and only when the rollback restored a confirmed snapshot. With none, the rollback restores the state from before the command, which nothing verified and which can hold the rejected package (measured: a plain `npm ci` there ran it), so no script runs and the message, `reorg.log` and `advisory.log` say "no confirmed snapshot". They say "no install script was run" only when the install was inert; on Codex they say the install's own scripts already ran (RB1x). Codex lacks `updatedInput`, so it falls back to detect-and-rollback — keep this asymmetry honest in code and docs.
- **OSV is the single canonical advisory truth.** KEV is a hard-risk overlay; GHSA is enrichment. Do not add a second co-equal truth.
- **No silent fallback.** A provider miss is fail-closed. Every bypass must be observable and logged.
- **`lib/truth-sources.sh` is on the PreToolUse path, so breaking it blocks Bash machine-wide.** The guard sources it on every Bash call to report a moved advisory source, unconditionally and without an environment override (an override was a silent off switch for the notice, caught in review). A parse error there takes the guard down, which the entry shim turns into an explained fail-closed deny — the right direction, and a wider blast radius than the file's size suggests. Edit it in a worktree and run `npm test` before it reaches the main checkout.
- **The install grammar is defined once, in `lib/install-grammar.sh`, and it is on the PreToolUse path.** Every recognizer in both hooks reads it: the pre-guard's install and runner patterns, ecosystem detection, spec extraction, the `--ignore-scripts` rewrite, and the post-verify backstop. It replaced seven hand-kept copies of the verb list that had drifted apart (`pnpm i`, `npm isntall`, `npx <pkg>@<ver>` and more passed the gate, v2.18.0). Add an alias, a runner, or a statement position there and nowhere else. A missing grammar is an explained fail-closed deny for every Bash call, so edit it in a worktree like `lib/truth-sources.sh`. **Its scope follows the carrier rule in ARCHITECTURE.md**: the manager's own documented spellings, every command word npm's parser accepts (`deref`: abbreviations and camelCase, measured by `scripts/measure/npm-verb-spellings.sh`), and the shell's statement grammar are in; argv-passing wrappers (`sudo`, `timeout`, `nohup`, `nice`, `xargs`) are out and pinned as unjudged in `scripts/test/consumer-forms.sh`. Moving that line is a decision to record, not a regex to widen.
- **A scanner that fails must not read as "no install".** Every predicate reads `command_scan_text` inside a condition or a command substitution, where `set -e` is off, so a failed awk returns empty text. Every awk reading records its failure in a per-run mark file, and so do judgment greps (`judge_grep`: 1 is no match, 2 and up did not answer) and the seds on the judgment path; one gate settles them: every path that lets a command run crosses `guard_settle_scan_failure` once, after its last reading and before its first side effect (pending state, the inert meta, the allow). If a reading failed, a command that names a package manager's executable anywhere (`SAFEDEPS_G_EXECUTABLES`, any case, bash regex, no subprocess) is an `UNDECIDED` deny; anything else runs with the failure on stderr and in `advisory.log`. A deny that reports a finding calls `guard_undecided_if_scan_failed` first. A reader that cannot read its input to the end says so the same way rather than reading what it reached: the `sh -c`/`eval` payload reader marks a failed reading when a payload word in live code goes on past the quote it stops at, and the pieces view marks a `$'...'` escape whose value it cannot name. So: a new allow path crosses the gate, a new reading of the command goes before it, a new awk reading writes the mark on failure and carries a `safedeps:<function>` marker line, a new judgment grep goes through `judge_grep`, and `scripts/measure/scan-failure-census.sh` (quick subset in `npm test`) must still count zero weakened, mislabeled, after-gate and pending-on-deny. The marker is enforced, not remembered: the census fails on any awk call that carries no marker, or a marker it has no kind for, because it can fail only what it can name. Twice a hand-kept list of marked readings missed one, and the census reported zero over it.
- **The command is read by one lexer, `shell_lex`, and every reader takes a view of it.** Quotes, escapes, comments, heredocs, arithmetic, substitutions and continuations are lexed in one awk pass; `command_scan_text`, `strip_heredoc_bodies` and `join_line_continuations` are views of that pass, not parsers of their own, and so are the prefix stripping in `normalize_install_text` (the `unprefixed` view), the substitution extractor (the `substs` view), and the spec extractor's statements: their redirections (the `noredir` view), their quote removal and their cuts at `;` `|` `&` (the `pieces` view). The last three each had a reader with its own copy of the quoting, and each copy was a silent pass where it disagreed with the shell (v2.18.0: a `>` inside `"$(echo ">'")"` read as a redirection took the pinned spec after it along). A new reader of the command takes a view -- never a second parser, because three that had to agree did not, and each disagreement hid the lines after it (fail-open). The scan, code and noredir views keep byte length and are idempotent, so an offset in one is the offset in the command and reading one twice changes nothing; scan-contract checks both properties on the recorded shell forms and on random input, and checks the pieces view's words against the argv bash and zsh produced (`scripts/measure/word-reading-forms.json`). The joined view drops continuations on purpose and has neither property. Where bash and zsh diverge, each divergence is its own axis -- an arithmetic context holding `<<` or a comment, and an apostrophe inside `"${...}"` -- and the command is judged under every combination of the axes it flags; tying two axes to one switch left the reading zsh actually makes unjudged. A form a shell runs must get a verdict: `scripts/test/shell-reading.sh` checks the recorded shell values, and `scripts/measure/shell-reading-measure.sh` re-measures them.
- **Quotes and backslashes are read the way the shell reads them.** Inside double quotes backslashes pair up; outside quotes a backslash escapes the next byte, and an escaped operator (`\;`, `\|`, `\&`, `\!`, ...) is a character, not syntax; there are no escapes in single quotes; `!` and `{` open a statement only where a statement starts; an escaped newline and a newline inside quotes do not end a statement and are joined before anything splits the command into lines. Each earlier approximation blanked text the shell executes, which is a bypass, not a false negative to tune. `scripts/test/scan-contract.sh` holds the rules as a runnable reference.
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
- The registered command for both events is the entry shim `scripts/safedeps-hook-entry.sh pre|post`, not the hook scripts directly. The shim turns a broken hook source (mid-merge checkout, crash, missing file) into an explained fail-closed deny. It relies on one contract: **the real hooks exit 0 on every designed path** (decisions travel as JSON) — never add an intentional non-zero exit to a hook script. The shim also answers for its own stops: bash exits 128 (3.2) or 254 (5, after about 15 seconds of retries) when it cannot start a process, both engines read either as non-blocking, so an EXIT trap turns any exit the shim did not choose into an explained exit 2. Every designed exit sets `answered=1` first, and the messages are written with builtins, because a report that needs a process cannot report that no process can start.
- Hooks block clearly and explain; never a silent fallback.
- Installed copies under `~/.claude`/`~/.codex` are symlinks to this repo — edit the repo, never the installed copy.

## Testing

- `npm test` runs smoke + e2e. Keep it green.
- A security change needs **both** a bypass harness (the threat must DENY/REORG) and a regression check (normal installs still pass; no false positives on `echo`/heredoc/`npm run`/`npx`).
- **Cite counts a reader can reproduce from the repo.** "159 forms" measured in a scratch corpus is decoration — nobody can check it, and a number nobody can check reads as verification without being any. Quote the battery's own form count or `npm test`'s ok lines, or commit the corpus you counted.

## Verification hygiene

The verification procedure has its own shared state, and three defects came out
of it in one round. All three had the same shape: two actors each behaving
correctly, overlapping into a wrong result.

- **Run mutations on a copy, never in the plan worktree.** The validator is
  dispatched into that worktree and the author may still be working there, so
  both hold write access to one tree. Worse, if a mutation is restored with
  `git checkout -- <file>`, it discards *every* uncommitted change to that file,
  including the author's, and the file returns to a HEAD state that looks
  correct. Copy the tree (`git worktree add /tmp/mut-<id> HEAD`), mutate there,
  and throw it away -- not restoring is the safest restore there is. "The
  worktree belongs to the validator" is a discipline someone has to remember;
  mutating a copy is a structure with nothing to remember.
- **Sandbox names come from `mktemp`, not from `$$-$RANDOM`.** `$$` is constant
  within a run, so isolation rests on `RANDOM` alone, and `mkdir -p` succeeds on
  an existing directory -- a collision is undetectable rather than merely
  unlikely. That undetectability is the reason, so it does not need re-arguing
  when call counts change.
- **A test that suspends a process reaps it three ways.** An EXIT trap covers
  ordinary exits; a marker sweep at suite start covers SIGKILL, which defeats
  traps and is this repo's core scenario rather than a hypothetical; and
  spawning children with a cwd outside the worktree removes what the leak costs,
  since an orphan holding the plan worktree makes the close gate refuse to
  prescribe removal at finalize. (Measured, after review corrected it: `git
  worktree remove` itself exits 0 with a stopped process sitting in that cwd --
  the machine that refuses is kuma's live-cwd close gate, not git. The effect and
  the fix were right; the named cause was not.) Scope any sweep with a marker only your own children carry.
  A marker string shared by every run is not that: one run's sweep killed another
  run's fixtures, twice in one round. The marker carries the run's pid, and the
  sweep reaps only markers whose run is gone. Its name must not contain an older
  marker either, or a checkout still sweeping by that substring matches it.

### Citing a zero

A run that found nothing is a claim about a measurement, and three ways of
making that claim are wrong. Each of these was measured the wrong way first in
the round that produced this section.

1. **A zero from a harness with no control is not evidence.** If the check
   cannot fail, its silence says nothing. 27 clean runs were reported before the
   control was tried, and the control turned out to be broken itself.
2. **A trial whose condition was not measured is not an observation of that
   condition.** "Quiet machine" was inferred from who else was working; `uptime`
   showed load 19 during those runs. Record the condition per trial or the
   batches can neither be compared nor combined.
3. **Say whether a label came from measurement or from someone saying so.**
   Hearsay carries no sense of not having measured, so it passes check 2. A
   label that crossed between two people hardened at each hop while nothing at
   the origin had ever been measured -- and then a statistical test was run on
   top of it, which made it look verified rather than merely elaborated.

The failure mode behind all three: **elaboration feels like verification.**
Handling numbers produces the sensation of handling data, and the step that asks
where the input came from gets skipped entirely.

## Workflow

- Branch off `main`; do not commit to `main` directly.
- Do **not** commit or push unless asked. Use logical commits with clear messages.
- **Never resolve merge conflicts in the main checkout.** The installed hooks execute the main checkout live; conflict markers there blocked Bash machine-wide on 2026-08-04. Integrate in your worktree (merge `main` into your branch, resolve, test), then move `main` forward fast-forward-only (`git merge --ff-only`). The entry shim softens the blast, but the discipline removes the window.
- **Write commit messages through a quoted heredoc** (`git commit -F - <<'EOF'`), never `-m "..."`. Inside double quotes a backtick is command substitution, and this repo's messages quote install commands in backticks as a matter of course: a message about a bypass would run the bypass. The live gate caught one on 2026-10-01; do not rely on that.
- **A harness judges commands; it never runs them.** Feed a form to the guard as a payload. Do not `bash -c` it to "see what the shell does" -- the form is an install by construction. When shell semantics are the question, use an `echo` in place of the package manager.
  **The one exception is a battery that measures the package manager itself** -- what npm writes and where, what `npm rebuild` executes -- because no payload can answer that. `scripts/test/lockless-forms.sh` and `scripts/test/effect-trace-grid.sh` are the two, and both source `scripts/test/lib/npm-sandbox.sh`. Such a battery runs installs only when all four of these hold, and each is enforced in that file rather than remembered: every package is synthetic and packed by the battery; the registry is a fixture on 127.0.0.1, with npm's proxies pointed at a closed local port so any other request fails, and the gate lets that one registry through only by name (`SAFEDEPS_NPM_TEST_REGISTRY`, a loopback URL, announced in `advisory.log` on every run); the battery asserts at the end that the fixture saw requests for its own packages and nothing else; and it unsets every inherited `npm_config_*` before setting its own home, userconfig, globalconfig, cache and prefix, then checks with `npm config get` that the prefix is inside the sandbox before the first install. The last one was paid for: `npm test` exports npm's own configuration to its scripts, and an inherited `npm_config_prefix` sent the battery's global-install forms into the machine's real global prefix.

## Release procedure

A release is every step below, in order. The list exists because steps were
skipped and nothing noticed: v2.16.0 through v2.17.1 were never tagged,
released or published, so npm sat on 2.15.8 until v2.17.2 caught it up; v2.17.2
shipped with no ROADMAP entry and a stale "current" line; and tags and a
publish went out while ubuntu CI had been red for eight pushes. Do not start a
release without the intent to finish it, and do not report one finished while
any step is open.

1. **Integrate in a worktree.** Merge every finished plan branch into
   `plan/release-vX.Y.Z` and resolve conflicts there, never in the main checkout.
2. **Bump the version once.** `package.json` `version` and `bin/safedeps`
   `SAFEDEPS_VERSION` together (see Version SSoT). A change that moves a verdict
   is a feature for this purpose: minor, not patch.
3. **Record it.** A `ROADMAP.md` section for the version -- what changed, how it
   was verified, measured numbers with the conditions they were measured under
   -- and the same change in `ROADMAP.ko.md`. Update the "current: vX.Y.Z" line.
   Update README, ARCHITECTURE and SKILL, with their `.ko` mirrors, wherever a
   stated proposition moved. Credit issue reporters.
4. **Run the consistency audit** (next section) and read its ceiling. Then have
   someone other than the author re-read the changed propositions.
5. **Test on both platforms before anything leaves the machine.** `npm test` on
   macOS, and the CI steps on Linux: ubuntu:24.04 with jq, procps, git, node,
   npm, shellcheck and CI's pinned gitleaks, running CI's exact shellcheck list,
   `npm test`, `./bin/safedeps scan secrets --repo`, and `npm pack --dry-run`.
   Record `uptime` beside each run. Linux-only failures (GNU `stat -f`, the
   128KB `E2BIG` limit, ext4 directory order) were invisible on macOS and kept
   CI red for a month.
6. **Run the release gates.** `scripts/release-gates.sh --strict` (secret scan,
   dependency audit) passes, the package has zero runtime dependencies, and
   `npm pack --dry-run` lists only what `files` allows.
7. **Move main forward.** From the main checkout, `git merge --ff-only
   plan/release-vX.Y.Z`. The installed hooks now run the new code: push one
   benign command and one install through `scripts/safedeps-hook-entry.sh pre`
   and read both answers before going on.
8. **Push and watch CI.** `git push origin main`, then wait for the run on that
   commit. Both `test (ubuntu-latest)` and `test (macos-latest)` must be green.
   Red stops the release: fix forward, and do not tag a red commit.
9. **Tag and publish the GitHub release.** An annotated tag `vX.Y.Z` on the
   green commit, pushed, and `gh release create vX.Y.Z --notes-file <notes>`.
   The notes cover every user-visible change since the previous tag (derive them
   from `git log <previous-tag>..vX.Y.Z` and the ROADMAP section): security
   fixes first, each with what could get past before and how it is verified
   now, then fixes, then anything a user has to do. Then read it back:
   `gh release view vX.Y.Z --json isDraft,isPrerelease,tagName` must show
   `false`, `false` and the tag, and `gh release view --json tagName` (the
   latest release) must name it. A draft is not a release: users and
   `releases/latest` never see it.
10. **Publish to npm.** From a clean checkout of the tag, `npm whoami` (the
    owner logs in; publishing needs their 2FA), `npm publish --access public`,
    then confirm `npm view @aldegad/safedeps version` is X.Y.Z and that the
    published tarball's file list matches `npm pack --dry-run` of the tag.
11. **Close the loop.** Reply on every GitHub issue the release fixes with the
    fix commit and the release link, and close it.

## Consistency audit (before release or doc changes)

```bash
# version SSoT
[ "$(jq -r .version package.json)" = "$(./bin/safedeps --json version | jq -r .version)" ] || echo "VERSION MISMATCH"
grep -rqiE 'current.*2\.[0-9]+\.[0-9]+' ROADMAP*.md   # sanity-check the "current vX.Y.Z" line is right
# language purity: English docs have no Korean prose (ko-link lines excepted)
for f in README.md ROADMAP.md ARCHITECTURE.md; do
  grep -vP '\]\(\./[A-Za-z]+\.ko\.md\)' "$f" | grep -qP '[\x{AC00}-\x{D7A3}]' && echo "KOREAN IN $f"
done
# concept presence, per file. `grep -lq` over a file list exits on the FIRST
# match, so the old form passed when ONE of three documents still carried the
# concept -- it could only catch "all of them lost it at once", never drift
# between them. AGENTS.md is in the list because it owns the invariants.
for f in README.md README.ko.md ARCHITECTURE.md ARCHITECTURE.ko.md SKILL.md AGENTS.md; do
  grep -qi 'inert\|--ignore-scripts' "$f" || echo "inert-install missing from $f"
done
npm test
```

### What that check cannot do

It answers "is the concept absent from a file", not "do these files state the
same proposition". Measured against the real v2.16.1 drift, where AGENTS.md got
a liveness qualifier and the other documents kept the old file-existence
reading:

- **False negatives, 2 of 3.** Both ARCHITECTUREs were drifted and both already
  contained the word `pid` -- from an unrelated paragraph about the budget
  deadline killing a process tree. A per-file vocabulary check would have
  flagged only README.
- **False positive, 1.** After the fix, README.md states the new proposition
  correctly without using `pid` or `liveness` -- it is user-facing prose and says
  "the process that wrote it is gone" on purpose. A vocabulary check turns it
  red, and the way to clear the red is to plant jargon in user-facing prose,
  which the Docs section above forbids. The check and the convention would push
  against each other. (Cross-validation corrected this from 2: ARCHITECTURE.ko.md
  does use `pid` in that paragraph, so it would not be flagged. The count is the
  kind of claim this very section warns about -- re-derive it before quoting it:
  `git show 9b43aee^:README.md | grep -ci pid`.)

The cause is the direction of the approximation: a check like this approximates
a proposition by its vocabulary, and every document layer states the same
proposition in different words on purpose.

So the layers are:

1. **Concept absence** -- the loop above. Real, and this is its ceiling.
2. **Proposition declaration** -- have each document declare which version of a
   proposition it reflects, and bump the declaration when the proposition moves.
   Better than "did the commit touch all of them", because a declaration is an
   explicit claim by the author rather than an incidental co-edit. Not built.
3. **Proposition agreement** -- not mechanizable. Re-review owns this: another
   person reading the same object. That is a design decision, not a gap. Every
   defect in the v2.16.x round -- a fail-open early return, this prose drift, and
   a prescription written without opening the check it prescribed -- was invisible
   to any grep and was caught by someone re-reading.
