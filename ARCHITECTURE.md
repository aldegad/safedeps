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

**The same bypass has a different severity in each ecosystem, and that difference is the point.** For npm the boundary costs *delayed detection*: the effect gate reads the live lockfiles npm writes (`package-lock.json` and `node_modules/.package-lock.json`), and its own install recognizer is a raw text match with no carrier enumeration, so it fires on exactly the commands the command gate skipped. An unrecognized carrier still ends in a closure check and a rollback. For `pip`, `cargo`, `go`, `gem`, `maven`, and `nuget` there is no closure resolver behind the command gate, so the same carrier is a **complete miss**. The post hook recognizes the command, finds nothing it can check it with, and records `UNVERIFIED`. Read "the command gate does not parse this form" as npm-shaped and you will conclude something is still watching. In the ecosystems where the command gate is the authority, nothing is.

**"Delayed detection" for npm holds while the effect gate finishes, and that is a measured range, not a given.** The gate is registered at 30s and the runtime kills it there. Its cost rides on the project's lockfile closure, and it used to ride on the machine's approved-spec ledger as well: the gate asked the ledger about each closure package separately, and each question walked the whole ledger directory. On a 738-entry ledger that put it past 30s at a closure of **four packages** — which is to say, on nearly every install, npm's delayed detection was no detection. v2.16.0 reads the ledger once per closure instead of once per package, and the ledger axis goes flat (0.23s at any closure size measured). What remains is the OSV/KEV pass, which is per-package: on the same machine, with a cold provider cache, the gate now crosses 30s at a closure near **390 packages**. Below that npm's delayed detection is real; above it — a large application's lockfile — the gate is killed and the detection does not happen. Measure it on the machine that matters with `scripts/measure/effect-gate-cost.sh`; the crossing point moves with the host, the network, and the cache.

**When the gate is killed mid-rollback, that no longer disappears.** The rollback restores the lock and manifest files, then deletes and rebuilds `node_modules`, and it used to write its `reorg.log` entry and its message only after all of it. A kill anywhere inside left zero lines — including at points where the project had already been fully reverted, so the user's install vanished with nothing to explain it. The gate now writes a rollback journal entry before the first destructive act and clears it once the rollback has reported itself, so an entry that outlives its run *is* the report: the next PostToolUse moves it to a durable incident record, appends `REORG INTERRUPTED` to the same `reorg.log`, and says which stage was reached and what repairs it. Outliving its run is a liveness claim about the writer, not the presence of the file — a rollback in progress holds its own entry by design, so the report is gated on the entry's recorded pid being gone (v2.16.1). The state lock cannot carry that check: the hook releases it before the rollback begins, so the rollback runs unlocked. This is not atomicity — safedeps does not own the atomicity of an npm tree rebuild — it is the guarantee that an unfinished rollback is loud rather than silent. Pinned by `scripts/measure/rollback-kill-state.sh` and by both directions in the e2e battery.

The boundary is not an oversight, and widening it is not free. The two recognizers in this repo make opposite precision trades on purpose. A false positive in the effect gate costs one closure diff, so its recognizer is deliberately loose. A false positive in the command gate **denies the user's command**, so its recognizer must be precise — and precision is what an unenumerated carrier walks through. This is the same conclusion that moved npm's authority to the effect gate in the first place: command text cannot be a fail-closed authority, because deciding from text means deciding from a syntax you have to enumerate.

The rule for changing the command gate follows from that. Applying a rule the gate already states, at a place that skipped it, is in scope — normalizing `| /bin/sh` and `| env sh` to `| sh` is the gate's own existing statement that a path-qualified or env-prefixed invocation is the bare one, applied to the consumer side of the pipe instead of only the producer side. Two more are the same move (v2.18.0). The consumer is read through the shell's operators and groups, so `| sh; echo`, `(… | sh)` and `|&` are the pipe the gate already names; they had passed unjudged because the check wanted a blank after the shell's name. And a visible install no longer switches the pipe check off: `pip install requests==2.0.0 && printf 'pip install evil' | sh` checked `requests` and ran `evil` unchecked. Beside a visible install the gate now blanks the manager word of each install it reads and asks the pipe question of what is left. Adding a new carrier syntax to the recognizer is not, because that is where the enumeration grows without converging.

Reading a parser gap as npm-shaped was a misreading with more than one instance. The ledger gate itself is gated on a parseable `pkg@version` operand, and the code's stated reason for that is npm-shaped too: a bare `npm install` is a lockfile install that names no new package, so letting it fall through is correct *for npm*. `pip install evil` is not a lockfile install. It names a package. The same reasoning was carried into the ecosystems where this command gate is the authority, and there it means an unpinned install is never checked at all.

The direction is also inverted, which is the part enumeration would never surface. The hidden path denies when no spec can be extracted, and the plain path allows under the identical condition. One predicate is read in opposite directions inside one file: `printf 'pip install evil' | sh` is refused fail-closed, while `pip install evil` proceeds.

That case now writes an `UNGATED` record naming the ecosystem and the command. The exemption from it is keyed on the effect gate actually reading the result, not on the ledger ecosystem: pnpm, yarn and bun share npm's ledger ecosystem without the `package-lock.json` the gate reads, and until v2.18.0 that let an unpinned `pnpm add x` through with no record (GitHub #22). Only an npm CLI install that the lockfiles record is exempt now, and only because the PostToolUse hook keeps the record for it: an npm install that left no trace where the gate looked is recorded `UNGATED` there, whatever it named (see "A directory is where the gate looks" below). Runners that fetch a package are recorded here, `npm link <pkg>` too, since only the link lands in the project, and a runner of a binary the project already has is not a fetch. "Reads" has one definition: the record walks the statements `resolve_install_targets` lists, the same walk that chooses the directory the gate reads, and each statement carries its kind (`guard_effect_gate_reads`). Before v2.18.0 the record kept its own definition, a list of flags that stop npm writing `package-lock.json`, and the two disagreed in both directions. The list missed `--no-save` and `--save=false`, which the gate did not read then. And it named `--no-package-lock`, which the gate now reads through npm's hidden lockfile. An npm install inside a `sh -c` or `eval` payload is recorded, because where it lands is decided inside the payload. The record's unit is the operand, and it reads each statement through the same parse the spec extractor uses: an operand counts as pinned only when the extractor read a spec from that very token. So a command that pins one package and names another without a pin is recorded, and so is one that pins a package and names the same package again without a pin, in the same statement or another (`pnpm add x@1 && pnpm add x`). Until then the record was a second parser that asked the extractor by name, and each narrower name key (token shape, then name, then ecosystem and name) still let a same-named pin quiet an unpinned install. The same split ran the other way, recording the version after `gem install rails -v 7.1.0` as an unpinned package. One parse also means a misread shows: when the extractor reads a token wrongly, the token is not a spec it produced, and it is recorded. The line names each operand it recorded. Some records are harmless and declared rather than removed, because removing them needs runtime knowledge the gate does not have: pip resolving `pip install x==1 x` to the pin, a second install of a pinned package that is a no-op, a runner whose binary an earlier statement installs, and a flag the record does not know takes a value. It changes no verdict. Denying every unpinned install is a policy change that would break ordinary workflows, so it stays the repo owner's call; the record is what makes that call answerable from evidence rather than guesswork. The record's silence is scoped as deliberately as its noise, and the line is whether a package is named -- not which flags appear. A bare lockfile install names none, and neither does `pip install .`, which builds from the working tree instead of fetching. A source flag consumes only its own argument, and which flags take one is a property of the tool: pip's `-r`/`-c`/`-t`/`-f` do, while gem's `-r` is `--remote` and go's `-t` is a boolean. A record that fires on routine installs is background noise and background noise is the same as no record, but one that goes quiet whenever a flag appears is worse -- it reads as coverage it does not have.

**Which file, and which directory, was a bypass of its own.** The exemption was keyed on flag spellings, and the gate read `package-lock.json` in the directory the command started in. Measured with npm 11.19.0 against a local registry, with a synthetic package whose lifecycle scripts leave a mark:

| Form | Where npm recorded it | Before v2.18.0 | Now |
|---|---|---|---|
| `--no-save`, `--save=false`, `npm_config_save=false`, `save=false` in `.npmrc` | `node_modules/.package-lock.json` only | confirmed clean, then `npm rebuild` ran the package's scripts | rolled back, no script runs |
| `--no-package-lock`, `--package-lock false`, `npm_config_package_lock=false` | `node_modules/.package-lock.json` and `package.json` | the same (`--no-package-lock` was also recorded `UNGATED`) | rolled back, no script runs |
| `npm -C sub install x`, `cd sub && npm install x`, `cd sub; npm install x` | `sub/package-lock.json` | confirmed clean, never rebuilt | rolled back |
| `npm install x` with the hook's cwd in `src/` (no `package.json`) or in a workspace member | the project's, or the workspace root's, lockfiles | nothing read, no record | rolled back |
| `npm_config_global=true npm install x` | npm's global prefix, no lockfile | confirmed clean, no record | recorded `UNGATED` |
| `global` or `location=global` in the project's or the user's `.npmrc` | npm's global prefix, no lockfile | confirmed clean, no record | recorded `UNGATED`, naming the file |
| `global=0` in `.npmrc`, or `location=global` there with `--location=project` | `node_modules`, in neither lockfile | confirmed clean, then `npm rebuild` ran the package's scripts | recorded `UNGATED`, rebuild skipped with a warning |
| The same settings, installing or updating a package already on record | a new version in `node_modules`, the old one still in both lockfiles | confirmed clean, then `npm rebuild` ran the new version's scripts | recorded `UNGATED`, rebuild skipped with a warning naming both versions |
| `npm install x -w packages/a` in a workspace | the root lockfiles and `packages/a/package.json` | the member key read as an unapproved package `packages`, and the rollback left `x` on disk | rolled back, member manifest included |

So the gate reads both of npm's records, in the directory npm installs in, and it asks npm which directory that is. `resolve_install_targets` follows the command to where it runs npm: a literal `cd` to a directory that exists, or `env -C`. There it runs `npm prefix` and `npm root` with the install's own arguments and the environment the command gives it (`lib/npm/ask.sh`). `npm prefix` names the local prefix: npm's walk to the nearest `package.json` or `node_modules`, its workspace roots, every `.npmrc` it reads, and `--prefix` or `-C`. `npm root` names the directory npm installs into, which is `<prefix>/node_modules` only for a project install; anything else is npm's global prefix, where no lockfile is written. The two run in parallel, under a deadline of 8 seconds for every install in one command.

This replaced a copy of npm's rules in bash, and the copy is why. Each version of it disagreed with npm somewhere, and each disagreement was a silent pass. Taking the named directory as the install directory sent the gate to `src` while `cd src && npm install x` wrote the project's lockfiles. The workspace resolver that fixed that resolved symlinks, and npm does not: from `real/a`, a member that the root's glob reaches as `packages/a -> ../real/a`, npm installs in `real/a`, and the resolver climbed to the root, read it clean, and left the package on disk (validator round 2, F1). A third copy would fail a third way. `scripts/test/install-dir-differential.sh` now holds the gate to `npm prefix` over the validator's 237 layouts and ten command forms, with no difference allowed.

Where npm cannot answer, the gate records why and looks in the cwd; it does not choose a directory some other way. The trace then says whether the install was there (below). The reasons are npm missing from the hook's `PATH`, npm failing (it refuses a `workspaces` value it cannot read, and so does the install), npm not answering within the deadline, and a command that hands npm something the shell decides at run time (`cd "$DIR"`, `npm install "$PKG"`, an exported `npm_config_*` set from a variable) or an `env` option this gate does not reproduce. Workspace selectors (`-w`, `--workspace`, `--workspaces`) are left off the ask, because npm refuses them on `prefix` and `root` and its `loadLocalPrefix` reads only a false `workspaces`, which is kept. Words are read the way the shell splits them, so a quoted `--prefix "/tmp/x y"` is one path. `npm_config_prefix` in the environment does not move a project install, and npm says so too: measured, it landed in the cwd project. `scripts/test/lockless-forms.sh` runs every row end to end, and it is red on the tree before the repair.

**An `.npmrc` moves an install the command does not show, and npm reads it.** Where an install lands is npm's answer, so every `.npmrc` npm reads is in it, the global and builtin ones included: `global=true` in any of them makes `npm root` name the global tree, and the install is recorded `UNGATED`. Whether npm writes a record where it lands is a different question, and npm cannot be asked it before the install. Two settings answer it without moving the install: measured, `global=0`, and `location=global` beside `--location=project`, put the package in the project's `node_modules` and in neither lockfile. So the pre-guard still reads `global` and `location` in two files for that question alone: the project's, in npm's local prefix, and the user's, from `--userconfig`, then `npm_config_userconfig`, then `~/.npmrc`. It reads them the way npm did in the measurements. Keys are case-sensitive, the last line wins, and the project file outranks the user file. Only `global=false`, `global=null`, `location=user` and `location=project` left an install on record, so any other value is read as off the record. This reading never chooses a directory. It can only turn an install the gate would read into an `UNGATED` one, and a wrong guess that way costs one line. The install is recorded, not checked: checking it would mean finding the package by name wherever npm put it, and that is left as a boundary. The same two settings in the global or builtin npmrc are not read for this question.

**A directory is where the gate looks; the install's trace says whether it was read.** Asking npm fixed how npm places an install. It did not fix which directory npm runs in, or with what environment, because the shell decides that, and validation round 3 found the text read wrong again. `false && cd sub; npm install x` installs in the cwd, and the gate followed the `cd` that never ran to `sub`. `command cd sub`, `builtin cd sub`, `eval cd sub` and a `cd` in a `case` arm install in `sub`, and the gate read the cwd. Each read a directory the install never touched, confirmed it clean and passed the install unread. Rounds 1 and 2 had the same shape. A design judgment then ran the forms of all three rounds and new ones end to end, counted 21 silent Claude Code rows, and found that no spelling list closes it: a command can change what npm reads (`npm init -y`, an `.npmrc` it writes, an inherited `CDPATH`) where no text shows it. So the prediction now only picks where to look, and the PostToolUse hook decides whether the install was there.

Just before the command runs, the pre-guard touches a baseline file and notes the inode of both npm lockfiles in the directory it picked. Afterwards, a lockfile `find -newer` than the baseline, or one with another inode, is this command's trace. npm rewrote `node_modules/.package-lock.json` on every install that installed anything, a reinstall of what was already there included, with the same content and a new mtime; `npm ci` replaced the file. Content and whole seconds are therefore no use: a no-op reinstall shows nothing in either, and it often finishes inside the second the baseline was touched in. Where neither lockfile shows a trace, the install is recorded `UNGATED` with `no install trace in <dir>: the install landed elsewhere or installed nothing`, no rebuild runs there, and on Claude Code the user is told that the install's scripts have not run wherever it landed. The check starts no npm. It cannot tell a dry run or a failed install from an install that went elsewhere, and says so in those words; that is noise, never a pass.

One trace answers for one npm statement. With two lockfile writers in one command, the first one's trace hid the second one landing elsewhere: `npm install a; command cd sub; npm install b` wrote both directories' lockfiles, and the gate found a trace in the one it read. So two or more npm statements that write a lockfile (every subcommand but the ones that only read, run or publish) share one trace only when nothing but inert statements runs between them (`echo`, `printf`, `tail`, `head`, `grep`, `ls`, `cat`, `true`, with no substitution and no redirection except to `/dev/null` or another descriptor) and none of them relocates itself (a directory or global flag, an `npm_config_*` setting or another word in front of `npm`, a group, a run-time word). An npm install inside a `sh -c`, `eval` or `$(...)` payload beside another one counts as relocated too. Otherwise the command is recorded `UNGATED`, naming what sits between.

The prediction keeps one change of its own. A `cd` that may not run, after `&&` or `||` or inside an `if`, `while`, `until`, `for` or `case` body, holds only along the `&&` chain after it, where every statement runs only if the `cd` succeeded; past that the directory is the one before it. That brings back the rollback of `false && cd sub; npm install x`, and `cd X || exit` is still followed. A conditional `cd` that did run (`[ -d sub ] && cd sub; npm install x`) is then recorded rather than read. With the trace deciding, a better reading of `cd` is coverage, fewer `UNGATED` lines, and no longer safety.

`scripts/test/effect-trace-grid.sh` runs the grid end to end: every row is rolled back or recorded, no Claude row runs a script of the unapproved package, 17 forms that installed something leave a trace and confirm quietly, and a no-op reinstall inside the baseline's second is caught. The same battery on the tree before this change shows the silent rows.

**The install grammar applies that rule, once.** v2.18.0 measured the recognizer against the spellings the managers document and the shell allows, and most of them passed with no verdict and no record: aliases (`pnpm i`, `npm isntall`, `yarn up`, `bun a`), several options before the verb (`pip --quiet install`), versioned interpreters (`pip3.11`), runners (`npx <pkg>@<ver>` matched a one-character name only; `npm exec`, `bunx`, `uvx`, `pipx run` were unknown), statement positions (`( ... )`, `then`, `do`, `!`, `time`), quoted specs, and flag-carried versions (`cargo install x --version 1`). None of these is a carrier: each is the install command itself. The verb list had seven hand-kept copies that had drifted apart, so `lib/install-grammar.sh` now defines the grammar once and every recognizer in both hooks reads it. Argv-passing wrappers (`sudo`, `timeout`, `nohup`, `nice`, `xargs`) run the install unchanged and are left out on purpose: the list of programs that exec their arguments does not converge, which is the carrier argument again.

Two spec readings checked the wrong identity, and an agent follows the deny message's prescription by itself, so both were bypasses. A Go module lost everything before its last path element, so `go get example.com/x@v1` prescribed `safedeps check go x@v1`, which approves a name no advisory mentions and then passes any `.../x@v1`. And every spec took the first ecosystem named in the command, so `npm run build && pip install evil==1` checked `evil` as an npm package. Go specs keep the whole module path now, and each spec carries the ecosystem of the statement it came from. Three more readings did the same, and each approved when checked. A version flag was bound to the first token after the verb that was not a flag, so an option's value in front of the package took its place: `gem install --source <url> rake -v 13.0.0` prescribed `check rubygems <url>@13.0.0`, `cargo install --root <dir> …` and `dotnet tool install --tool-path <dir> …` the same with a directory, and every later install with that option and version passed. A name that starts with a digit was read from its first letter (`poetry add 3to2@1.1.1` checked `to2`) or not read at all (`pip install 3to2==1.1.1`). And an npm alias `left-pad@npm:evil-pkg` prescribed `left-pad@npm`, which names neither package and never approves. A version flag now binds to every operand of the verb, and an option's value is left out only when the manager's own help documents a mandatory value for it, so a gap in that list adds a check instead of skipping the package. A name is read whole, and an alias is read as its target. A runner's options did the same with no version flag involved. Every option in front of the package was skipped and the next token taken as the package, so `uvx --python 3.12 ruff==0.1.0` ran ruff unchecked and recorded `pypi:3.12`, and `npx --cache /tmp/c evil@1.0.0` did the same with the cache directory. Each runner now has its own table, read from its own help or definitions. Some options name the package (`--from`, `--spec`, `--package`). Some add a package beside it (`--with`, which is now checked as well). The rest take a value that is not a package. Two parsers needed more than a table, and both were measured against the parser itself. `npm exec` hands its arguments to nopt, which lets a boolean take a following `true` or `false`, while npx's own first pass makes that token the package. And pipx accepts an abbreviated long option, so `--pyth` is `--python`.

**A command word is what the manager's parser accepts, and a `create` is checked as the package it runs.** npm does not read its command word from the documented aliases. Its `deref` (lib/utils/cmd-list.js) reads a camelCase word as dashed and takes any unique abbreviation of a command or an alias, so `npm upd`, `npm install-te`, `npm installTest`, `npm exe` and `npm cr` all install or run a package. A grammar copied from the aliases let every one of them through with no verdict. The npm spellings in `lib/install-grammar.sh` are now what `deref` maps to each command, and `scripts/measure/npm-verb-spellings.sh` regenerates them from the npm on PATH and fails when npm accepts one the grammar lacks. Each manager's `create` is a runner that rewrites its operand before it runs it. `npm init vite` runs `create-vite`, `npm init @usr/foo@2.0.0` runs `@usr/create-foo@2.0.0`, and `npm init @usr` runs `@usr/create`. pnpm keeps a name that already starts with `create-`, Yarn 2+ keeps one that matches `create` or `create-*` while Yarn 1 does not, and bun prefixes every name it hands to bunx. The prescription and the record name the rewritten package, read from each manager's source. Prescribing `vite@5.0.0` would have approved a package that never runs and left `create-vite@5.0.0` unchecked. Where Yarn 1 and Yarn 2+ disagree, both are checked, since the command does not say which yarn runs it. `npm init` with no initializer writes a `package.json` and fetches nothing, so it stays quiet. `npm link` (`ln`) reads every argument the way npm-package-arg does and installs each one the global tree lacks into npm's global prefix, then links it into the project (lib/commands/link.js:92-104). A registry argument -- a name, a version, a range, a tag or an `npm:` alias -- comes from the registry, so a pinned one is checked and an unpinned one is recorded `UNGATED`, wherever it stands among the arguments. The recognizer used to read only the first one, so a path in front hid the package after it: `npm link ./lib evil@1.0.0` installed evil globally and ran its install scripts with no verdict and no record. A path or a tarball links local code, and a git or URL argument names no registry package; these stay quiet, and so does `npm link` with no argument. `scripts/measure/npm-link-operands.sh` checks that reading against npm-package-arg itself. And a redirection is the shell's wherever it stands: bash reads an unquoted `>` or `<` as an operator in the middle of a word too, so `pip install requests==2.19.0>/dev/null` installs the pinned package. A reader that took an operator only at the start of a word read the whole word as an unpinned operand and checked nothing.

**The scanner reads quotes and backslashes the way the shell does, and a scan that fails is not an empty one.** Every predicate reads `command_scan_text`, which blanks quoted text, so blanking text the shell executes hides it from all of them at once. Four readings did that until v2.18.0: `"a\\"` read as an escaped quote, `\"` outside quotes read as an opening quote, a line continuation split into two lines, and a multi-line quoted string scanned line by line, whose closing quote then read as an opening one. Backslashes now pair up inside double quotes, escape the next byte outside them (an escaped `;` or `|` is a character, not the end of a statement), and do nothing inside single quotes; escaped newlines and newlines inside quotes are joined before the command is split into lines. The spec readers take their words from the same lexing (below). They used to delete the quote characters and keep every backslash, so `pip install ev\il==6.6.6`, which installs evil 6.6.6, was recorded as unpinned and never checked, and `pnpm add ev\il@6.6.6` prescribed `check npm il@6.6.6`. And because every predicate reads the scan where `set -e` is off, a failed scan used to read as "no install". Every awk reading now records its failure, as do the greps and seds a judgment depends on (a grep that exits 2 or more did not answer, which is not the same as no match), and one gate settles them: every path that lets a command run crosses it once, after its last reading and before its first side effect (pending state, the inert meta, the allow). If a reading failed, a command that names a package manager's executable anywhere, in any case, is denied as `UNDECIDED`, and anything else runs with the failure on record. That test is bash's own regex over `SAFEDEPS_G_EXECUTABLES`, with no subprocess, because the tools it stands in for are the ones that failed. The version it replaced re-ran a second recognizer through grep, sed and the join awk, went quiet with them, and could not match everything the scanned recognizers match (three review rounds). A deny that reports a finding after a failed reading reports `UNDECIDED` instead. `scripts/measure/scan-failure-census.sh` fails every reading one at a time and all at once and counts what got weaker; `npm test` runs its quick subset. It finds the readings by their marker, so it also fails when the guard calls awk without one: a reading it cannot name is a reading it never fails.

**The command is read in one pass, the way the shell lexes it.** One awk program (`shell_lex`) follows the lexical state the shell keeps: single, double and `$'...'` quotes, escapes, comments, heredoc operators and their bodies, arithmetic, command and parameter substitution, backticks and line continuations. Every reader of the command takes a view of that one lexing. The detection predicates read the scan view, with quoted text, comments and heredoc bodies blanked. The payload readers read the code view, which keeps quotes. Anything read one line at a time reads the joined view, where continuations are removed and a newline that does not end a statement is not a line break. A substitution in the body of a heredoc whose delimiter is unquoted is live code there, because the shell runs it; the body is walked by the same lexer, so a substitution in it may span lines, nest, or hold a case statement, where a separate line-at-a-time scanner had missed all three (caught in review). The prefixes a statement may start with -- assignments, `env` with its options and assignments, `command`, `exec` -- are read off the same lexing before an install is matched, so a value is one word however it is quoted or nested: `FOO="a b" pip install ...` and `FOO=$(cmd arg) pip install ...` passed with no verdict while a regex read the value as the bytes up to the first blank or quote. The lexer replaced three state machines that ran in turn -- a line-based heredoc pattern, a line joiner and the quote scanner -- and had to agree. Across three review rounds they did not: a heredoc was stripped twice, opened where there was none (a herestring, an arithmetic shift, a quoted `<<EOF`), or not opened where there was one (a digit delimiter, a multi-line string closing on the line that opens it), and each time every line after it vanished from the gate. `scripts/measure/shell-reading-forms.json` records each form with the values the shells produce for it, and `scripts/test/shell-reading.sh` requires a verdict on every form a shell runs to its last line; `scripts/measure/shell-reading-measure.sh` re-measures the shells.

**A command is read once per shell: bash, zsh and dash.** The shells lex the same text differently in a few places, and a line one of them runs can be quoted text, a heredoc body or arithmetic to another. So the lexer has three readings, and each reading is a shell. Every reader of the command reads it inside one reading, and text one reader hands another -- the joined lines, a `sh -c` script, a statement -- is lexed again in the same reading, never in another one. The gate judges the union. A finding in any reading is a finding, the targets and the specs are those of every reading, and a command is `UNDECIDED` only when no reading closes or a step of one reading failed. The readings agree byte for byte up to the first place where the shells differ, and the bash reading reaches that place in the same state, so the bash reading runs first and says whether the other two are needed. A command that never reaches such a place costs one reading.

Rewriting the command is not reading it. `--ignore-scripts` changes the text every shell reads, so it is added only where every reading puts the npm installs in the same place. Otherwise the command is `UNDECIDED`, and the reason says the shells read its npm installs in different places. Adding the flag where any reading saw an install would edit text that another shell reads as data, and a heredoc delimiter is one place where that changes what the shell reads next.

This replaced a reading per divergence ("axes") collected from the first reading, and the round that made the readings shells measured why that could not close. zsh decides a `((` at each site, so one command held a subshell `((` and an arithmetic one (form M1), and no switch for the whole command can follow that. Readers after the join lexed a zsh reading again under bash's rules and hid the line a second time (form SL1: `echo "${x:-'}"; <install>; echo "'}"`, which zsh and the agent's wrapper run). And dash, which reads a `sh -c` script on Linux, reads `((` like bash and the apostrophe like zsh (form D1). Inert installs had the same gap: zsh ran an `npm ci` that bash read as quoted text, with no flag, no record and a meta that said inert (forms I2, I3).

| Where | bash | zsh | dash | Forms |
|---|---|---|---|---|
| `((` | looks ahead to the first unnested `)`, honoring quotes: another `)` after it means arithmetic, anything else a subshell, none means arithmetic left open | the same look-ahead, with a bare quote read as a character | always a subshell | B1, M1, QM, D1, LA1-LA5 |
| `$((` | as `((` | as `((` | always arithmetic | Z2, A7 |
| a quote inside arithmetic | a quote | a character | a character | QM, QM2, SL2 |
| `$[` | arithmetic | arithmetic | plain text, so a quote, a comment or a heredoc in it is one | KD1-KD3 |
| `'` inside `"${...}"` | a quote | a character | a character | P4, SL1, SL3, D1 |
| `$'...'` | an ANSI-C string, where `\'` does not close it | an ANSI-C string | `$` and a single-quoted string | AC1, AC2 |
| a heredoc delimiter followed by `)` inside `$(...)` | ends the body, and the `)` is code | body | body | A2, HC1-HC3 |
| a `#` inside or right after a `(...)` that stands as an argument | no comment: inside a substitution bash 3.2 runs the line after it, bash 5.2 fails to parse | a glob word, no comment | a parse error | G5, ZG1 |

Each look-ahead steps over an escape, `$(...)`, `${...}` and backticks whole, each read with its own quoting. Each cell has forms in `scripts/measure/shell-reading-forms.json`, measured on macOS (bash 3.2, zsh 5.9, `/bin/sh`, `/bin/dash` and the agent's own wrapper) and on Linux (bash 5.2 and dash 0.5.12). `scripts/test/shell-reading.sh` holds each reading to its shell: wherever a shell ran a form's last line, that shell's reading must show it. It also holds the gate to a verdict on the form. `scripts/test/scan-contract.sh` checks that wherever the bash reading reports no divergence, the other two readings produce the bash views byte for byte, on the recorded forms and on random input. `scripts/measure/shell-reading-fuzz.sh` runs seeded random forms built from these places under the real shells.

A command that never closes -- an open quote, a heredoc without its terminator -- is a command the lexer could not finish, so it is treated as a failed reading: `UNDECIDED` when it names a package manager. The lexer does not model shell options or aliases set in a user's rc files, shells and versions other than those measured, or bash's own parse errors. One of those is measured: where bash takes a `$((` for a substitution, it finds the end of that substitution without reading heredocs, and a line it then runs can be hidden in the bash reading. In 400 seeded random forms this happened once, on macOS and Linux alike (F346). The zsh and dash readings showed the line, so the gate judged it. One form is unfaithful the other way on macOS (F19): zsh runs the line after a heredoc body that leaves an arithmetic open, and the zsh reading does not close; the bash and dash readings show it, so the gate judged it too.

**The lexer also owns where a statement and a substitution end.** A `case` pattern ends at its `)`, and that `)` is a statement boundary in the view the recognizers read, so an install in a case arm is judged; a grammar pattern could not tell that `)` from any other, so case arms used to sit outside the gate. The body of every command substitution comes from the lexer too -- `$(...)` as the shell delimits it, a backtick body unescaped the way the shell unescapes it, with `\`` nesting -- replacing a string scan that cut a body at its first `)`. A `((` is decided wherever it stands, not only where a command starts; a hand list of command positions let a heredoc swallow the line after it (caught in review). A `#` opens a comment only at the start of a word, which is a question about the token before it rather than the byte: after an unescaped blank, a newline, or an operator, and not after an escaped byte or the `)` that closes a `$(...)`, a `$((...))`, a process substitution or a zsh glob word, which are parts of a word (`echo $(echo a)#b` prints `a#b` in every shell measured). A line continuation is no byte at all: the shell removes it before it splits tokens, so the byte before it decides (`a \` then `#x` on the next line is a comment, `a\` then `#x` is the word `a#x`). Read by the byte, the lexer took such a `#` for a comment, and a comment that swallowed the close of a substitution hid the lines after it (forms G1-G4); read as a byte, a continuation turned a comment into a word whose quote hid the lines after it (LC1-LC3). The `)` of a subshell or an arithmetic command does end a token, and a `#` after it is a comment everywhere (G7, G8). The forms WB1-WB22 pin the answer for each kind of byte before a `#`, measured in every shell. A comment that starts a backtick body ends at the closing backtick, and a heredoc opened inside a substitution that closes on its own line has no body.

**The spec extractor's words come from the lexer too.** The extractor reads each install statement as words: its redirections taken out, the shell's quote removal applied, and the statement cut at `;`, `|` and `&`. Each of those had a reader of its own until v2.18.0, and each reader had its own model of the quoting, which was the lexer's model approximated. An awk that knew `'...'`, `"..."` and a backslash read the `>` inside `"$(echo ">'")"` or `$'...\'>'` as a redirection and took the rest of the line as its target, so the pinned install after it passed unchecked. The sed it replaced read a redirection only at the start of a word and kept a quoted target as operands. And the cut read no quotes at all, so `pip install --log "a;b" evil==1.0.0` left `evil==1.0.0` in a piece that was not an install. Each copy was wrong somewhere, and the place it was wrong was a silent pass. All three now read the lexer's classes: a redirection is an operator byte in top-level code, a quote is removed where the lexer opened it at the top level, a `$'...'` escape is decoded, and a cut is a separator in top-level code. `scripts/measure/word-reading-forms.json` records the argv bash and zsh hand a stand-in for the manager on each word form, and `scripts/test/scan-contract.sh` requires the extractor's words to be that argv. Inside a word, a byte the extractor would cut at -- a blank or a grouping character -- is carried as a marker, and the empty word is a marker alone, so a word stays one word and an empty one keeps its place. Split on blanks, `uvx --python $(which python3) ruff==0.1.0` and `uvx --python "" evil==1.0.0` each gave the option the wrong value, and the pin went unchecked. The spec reader then reads a word the way the manager does: past the blanks at its ends, and for a Python requirement past every blank in it, so `pip install "requests == 2.19.0"` is the pin PEP 508 says it is. One reading is still short of the shell's, and it is named rather than approximated: a `$'...'` escape whose value depends on the locale (`\u`, `\U`, `\c`) or is not one plain byte is a failed reading, so the install is `UNDECIDED`. The recognizers are a separate matter. They read the scan view, where a quoted word is blank, so a command word the shell assembles from quotes (`'pip' install`) and a runner whose quoted package has nothing but options after it (`npx "evil@1.0.0"`) are not recognized. v2.17.2 missed both. Reading them the way the shell does is the plan safedeps/command-words-read-as-the-shell-dequotes.

**Which word is the command, which is a value and which is a package is the manager's grammar, read once.** The lexer says where a shell word starts and ends. Which word is the manager's command, which words are option values and which are packages is a question for the manager's own parser, and until v2.18.0 four readers each answered it their own way. The recognizer regexes tried both readings of an option that may take a value, and where both matched they picked one: `npm --prefix x install evil@1.0.0` read as `npm x`, an exec, so the pinned install was allowed without a ledger check, and `bun --cwd x add evil@1.0.0` read as `bun x` passed the same way. The extractor knew the value options of four managers, so `cargo --config x install evil --version 1.0.0` passed unchecked and `pip --cache-dir x install evil==1.0.0` recorded the package `install`. The record walk took the first word that looked like a verb (`pnpm --dir x add` recorded `npm:add`). The landing read `--prefix`, `--cwd`, `--dir` and `--install-dir` wherever they stood. And the runner reader took the first word after `go run` for a module, so `go run ./cmd user@example.com` recorded `go:./cmd`. Each was a copy of a manager's grammar, and each was wrong somewhere.

Now one reader, `safedeps_manager_read` in `lib/install-grammar.sh`, gives every word of a statement a role: the manager, a command word, an option, an option value, an operand, the package a runner runs, or the runner's program arguments. It reads each manager's tables there. They list the command paths (`uv pip install`, `yarn workspace <name> add`, `dotnet add <project> package`) and the options that take a value, by command and by class: a plain value, a directory, a version every operand is pinned to, a package (`npx --package`, `pip -e`), or a package added beside the one that runs (`uvx --with`). Each comes from that manager's help or source, named beside the table. After the command, an option the table does not list takes no value, so its value is read as an operand, which costs a check or a record and never skips a package. Before the command, the word after such an option is read both as its value and as what it is otherwise, and the gate judges both readings: `bun --zzz x add evil@1.0.0` is checked whether bun runs `x add` or installs evil. The extractor, the record, the landing of an install that is not npm's, and the runner reader all read the roles and nothing else. The recognizer regexes are now a filter that says whether a statement may be an install. Their option slot lets a value run over several words of the scan view, as a substitution does there, so the filter is wider than the installs the reader finds, never narrower.

npm's roles come from npm's own parser. npm reads its arguments with nopt and the option types in `@npmcli/config`, so the reader mirrors nopt with npm's table: value and Boolean types, `=` values, `--no-`, unique abbreviations and shorthand expansion. npx first runs a pass of its own, which takes the next word for any option it does not know as a switch, and then hands the result to npm. `scripts/measure/npm-option-reading.sh` builds the table from the npm on PATH and runs nopt itself on four thousand argument lists. The table is npm 11.19.0's, and npm 10.8.2, which GitHub CI and many machines run, does not define 26 of its options. To npm 10 the word after one of those is a command or an operand, not a value: `npm --min-release-age install evil@1.0.0` installs evil under npm 10. So a statement that names one of them is read a second time with npm 10.8.2's definitions, and the gate judges the union. Any other npm version is checked against the table, and the options it defines differently are named as that version's boundary.

The other managers' tables are held against the manager too, wherever it can be asked. A missing entry costs a check. An entry for an option the manager reads as a switch costs a package: the word after the option is taken for its value, and when that word is the package, nothing checks it. A draft of the bun table listed bun's runtime options (`--print`, `--eval`, `--preload`, `--port` and about thirty more from `bun --help`) for every bun command. bun reads them as switches where it installs, so `bun add --print evil@1.0.0` passed with no check and no record. `scripts/measure/manager-option-reading.sh` asks each manager on PATH but npm how it reads a form, and compares the reader's roles with the answer. It runs bun against synthetic local packages, with every registry setting on a closed port. It asks pip's own parser, runs python, and reads the help of uv, cargo and go. A form where the manager installs a word the reader takes for a value fails it. Two facts came out of it for bun 1.4.2. bun takes for its command the first word that does not start with `-`, so no option takes a value before the command (`bun --cwd x add y` runs `bun x add y`), and the reader reads such a word both ways. And `-c, --config` takes a value only after `=`. A command's own entry is looked up before `*`, and no option is listed for both, so a command's reading is never decided by a manager-wide entry. pnpm, yarn, pipx, poetry, pipenv, gem, bundle, dotnet and mvn are skipped by name where they are not installed, and their tables stay what their help and source say.

The per-word readers run in the guard's own shell, so none can fail and read as "no spec"; `scripts/test/scan-contract.sh` checks that they start no process. The grammar is held by spelling rather than by example. `scripts/test/manager-variants.sh` writes a value in each place it can stand -- a manager's option before its command, a command's option, a runner's option, a word after a runner's package -- spelled nine ways, and requires the verdict, the prescription and the record to be the same for every spelling. It also puts each of bun's runtime options right before the package in every bun install spelling, and checks the table itself: a command's entry is read first, and every scope is a command path the reader can reach. `scripts/measure/tuple-replay.sh` replays those three answers at two revisions and fails on any moved row that is not classified as a missing check or record, a false one, or a reasoned verdict move.

**A script handed to a shell is read as the word the shell passes.** The `sh -c` and `eval` readers used to take the payload as one quoted word, up to the first matching quote. A word that went on past that point -- an escaped quote inside it (`sh -c "echo \"hi\"; pip install ..."`), more quoting glued to it, an ANSI-C word, an unquoted word with escapes -- was read as far as it went, and the install the shell runs after that point passed with no verdict. A floor that marked every such word as a failed reading closed that, but made ordinary commands `UNDECIDED`: 24 of 30 measured, among them `bash -c "cd \"$dir\" && npm run build"`. The readers now take the script from a lexer view (`cscripts`) that cuts words where the shell cuts them and applies the shell's quote removal, and they read the scripts inside a script too. Each bypass form is judged as the install it runs, with the real prescription; the ordinary commands pass; a `sh -c` named inside quoted text is data. Only an ANSI-C escape the lexer cannot name is still a failed reading.

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
- **Phase 3 — npm primary effect gate.** The PostToolUse hook compares the actual closure, read from `package-lock.json` and npm's hidden `node_modules/.package-lock.json`, against the ledger's direct entries and their `transitive_specs`, and re-queries OSV in batch. Any unapproved or vulnerable package triggers a reorg to the last confirmed snapshot. This authority is scoped to the npm closure.

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

**The record cannot be moved out from under the check.** `advisory.log` is where every bypass and unavailability is written, and `re-check` also reads it as the oracle for whether a ledger approval ever happened. While its path came from `SAFEDEPS_ADVISORY_LOG`, the same environment that writes a forged ledger entry could hand that oracle its own evidence — measured, an entry `re-check` flags as `suspected_forgery` stopped being flagged when the variable pointed at a caller-written file saying the approval had happened. The path is derived from `SAFEDEPS_HOME` now, so the record and the ledger it vouches for move together or not at all, and a set-but-ignored variable says so on stderr and in the log.

**A run judged against a moved source says so — on every path, and the list is not a completeness claim.** Pointing `SAFEDEPS_OSV_API_URL` (or the KEV/GHSA URLs, the closure fixtures, or a non-default ledger TTL) somewhere else is a real need — a mirror on a network that blocks osv.dev, a fixture in the test suite — so none of it is refused. What would be wrong is a run that answered from a moved truth looking exactly like a run that answered from OSV. Each deviation is recorded once per run, named, in `advisory.log`. The notice lives in `lib/truth-sources.sh` rather than in the provider stack, because the PreToolUse guard has to be able to say it too and cannot afford to source providers on every Bash call — it sources that one file, and only when something is actually set. Defaults and the comparison live there together, so a run is measured against the value it was assigned. The set of knobs listed there is what has been found: two of them were found by a validator after the enumeration that preceded them called itself complete, so it is written as a growing list.

For an npm-ecosystem command, the guard resolves the same Yarn project context described above (`SAFEDEPS_NPM_PROJECT_DIR` pinned to the project directory) and folds its `context_hash` into the ledger lookup, so a project-scoped approval only passes the guard inside its own project. An invalid context (resolutions present, lockfile unusable) denies the command outright rather than falling back to a package-only lookup.

### Phase 3 — npm primary effect gate + reorg (PostToolUse / `safedeps-post-verify.sh`)

```
install done → safedeps-post-verify.sh
        │
        ▼
   read the actual closure: package-lock.json + node_modules/.package-lock.json
   check every pkg@version against the ledger (direct entries + transitive_specs)
   re-query OSV in batch for the whole closure
   inspect install scripts + native binaries (v1 reorg-guard logic)
        │
        ├─ all approved, clean, no suspicion ──► CONFIRM (new safe baseline)
        └─ unapproved / vulnerable / suspicious ──► REORG:
                 • restore lockfile from the last confirmed snapshot
                 • reinstall node_modules in the project: npm ci from the
                   restored lock, or npm install --ignore-scripts without one
                 • append to reorg.log; message the agent
```

**The baseline is the state the last verified install left behind, as the checks read it.** Before the checks read the project, post-verify copies its lock and manifest files into a new snapshot (`verified-<id>`, whose `verified_from` names the pre-install snapshot). On CONFIRM it compares the project with that copy. Only if every file still holds the same bytes does it write the snapshot's `meta.json` and point `confirmed_${dir_hash}` at it. It used to confirm the pre-install snapshot instead, so the baseline ran one install behind. Measured with a real npm against a local registry, on Claude Code and Codex: an approved `npm install a` followed by an unapproved `npm install b` rolled back to a project without `a` in `package.json`, `package-lock.json` or `node_modules`, and after a second approved install the one lost was the last verified, not the first. `scripts/test/lockless-forms.sh` pins both, and it no longer needs the extra verified `npm install` it used to move the baseline forward.

The copy comes before the checks because a copy taken after them recorded whatever the project held by then. Measured with the same battery and a pinned schedule: a second Bash call's unapproved install finished between the closure check and the copy, and went into the baseline. Its own rollback could not remove it, and the rollback's `npm ci` ran its install scripts. The battery pins that schedule on Claude Code, where `npm rebuild` sits between the checks and the record. Codex has no rebuild there, so its window is shorter but has the same shape, and the same code closes it (not measured). The comparison is what ties the copy to the checks. Without it, a file that changed between the copy and the closure check would be recorded although the check read something else; with the copy alone, the pinned schedule above already stays out of the baseline, so the battery pins the comparison by the message it produces. What is compared is equal bytes before and after the checks. A change undone to the same bytes in between is not seen, but the bytes recorded are still the ones the project held at both ends.

Three boundaries follow from what the baseline is:

- **It is files, not `node_modules`.** The rollback rebuilds `node_modules` from the restored lockfile, so a verified install that saved nothing (`--no-save`) is not in the baseline and does not survive a later rollback (measured).
- **Only an install that passed the whole gate moves it.** The command-independent backstop runs the npm closure check alone, so a parser-missed install it finds clean is logged and left in place, but it is not confirmed. A later rollback returns to the baseline before it.
- **A baseline that cannot be recorded does not move.** That covers a copy that fails, a `meta.json` that cannot be written, and files that changed while the checks ran. In each case the pointer stays where it was, `advisory.log` says why, and the user is told that a later rollback would undo this install too. The new snapshot's `meta.json` is written last, through a rename, and every reader requires it, so a run killed part-way never leaves a baseline with files missing. It does leave the copied files behind, and they are not pruned: pruning lists `*_meta.json`, and a snapshot without one is also what a run in progress holds while its checks run. Nothing on disk tells the two apart, and pruning one in progress would let its `meta.json` land over missing files. So a killed run costs a few small files of disk, never a wrong baseline. A pre-install snapshot killed before its `meta.json` is left the same way.

**This gate has the same budget, and it is killed the same way — measured, not assumed.** Using the protocol that established the PreToolUse behavior (a sandbox project, a hook that records when it starts and when it finishes, a control inside the budget and an experiment past it), a PostToolUse hook given 20s of work against a 5s budget started and never finished, while the 1s control finished. The work above is bounded by the user's project and the network rather than by anything safedeps controls: `npm ci`, `npm install`, `npm rebuild`, and an OSV batch over the whole closure.

So the sentence "the effect gate backs up the command gate" holds *inside* the budget and not past it, and it fails worse in kind: a killed pre-hook lets one unjudged command through, while a killed post-hook can land in the middle of a rollback. The pre-hook's answer to running out of time is to deny (Phase 2), but a post-install gate cannot deny — the command has already run — so its answer is a different design question, tracked as `safedeps/effect-gate-killed-mid-rollback` and not solved here. Codex CLI timeout behavior remains unmeasured on both hooks; parity is not assumed.

### Phase 0 — the installed command is an entry shim (`safedeps-hook-entry.sh`)

Both engines register one command per hook event: `…/skills/safedeps/scripts/safedeps-hook-entry.sh pre|post`. That path resolves through the `~/.claude`/`~/.codex` skill symlink into the live repo checkout, on every Bash tool call. The working tree *is* the runtime. A checkout that is mid-merge, mid-edit, or mid-update therefore changes hook behavior instantly — and before the shim existed, what happened next was decided by accidental exit codes. A bash syntax error (merge conflict markers) exits 2, which both engines treat as a blocking deny, so every session on the machine lost Bash with only a raw parser message as explanation (this happened on 2026-08-04). A missing file exits 127 and a runtime crash exits 1 — both are *non-blocking* hook failures, so those breakage shapes silently removed the install gate entirely.

The shim makes both outcomes designed. The real hooks exit 0 on every intended path (decisions travel as JSON), so any non-zero exit means the source itself is unwell. The shim then classifies the breakage (does not parse / crashed / missing), checks the checkout for an in-progress merge or rebase and says so, and exits 2 with a message that names the machine-wide breadth, the cause, and the recovery path. Fail-closed stays fail-closed; it stops being anonymous, and the fail-open shapes stop being silent.

The shim also answers for its own stops. bash ends a script at the first process it cannot start -- bash 3.2 at once with exit 128, bash 5 after about 15 seconds of retries with exit 254 -- and both engines read either as a non-blocking failure, so on a machine out of processes the tool call ran with no gate. The same condition once produced a wrong diagnosis: a failed fork inside `dirname` left the shim resolving its own location to `/`, and it reported the hook as missing from a checkout there. The shim now finds its location by parameter expansion, writes its messages with builtins, and sets an EXIT trap that turns any stop it did not choose into an explained exit 2. Measured on bash 3.2 and bash 5.2: exit 128 and 254 before, a deny that names the failed fork after. `scripts/test/hook-entry.sh` reproduces the condition with a process limit of 1; root is exempt from that limit, so there the row reports itself skipped.

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

**Install-script timing.** A package's `postinstall` script runs *during* `npm install`. On Claude Code, the Phase 2 hook injects `--ignore-scripts`, so the install is inert and scripts run only after the effect gate confirms the closure (via `npm rebuild`) — a rejected package's scripts never run. On Codex CLI, which does not expose the `updatedInput` hook capability, the install runs normally and a malicious install script can execute once before the post-install reorg cleans up. (The package's *runtime* code is removed before your app runs it on both engines; only install-time lifecycle scripts have this Codex window.) The flag goes in only where bash, zsh and dash all read the npm installs in the same places. Where they do not, the command is `UNDECIDED` rather than half inert (see the readings above).

The rebuild covers only the tree the gate read. It runs with `--global=false --location=project --prefix <the directory the gate read>`. With `global=true` in a project `.npmrc`, a plain `npm rebuild` rebuilt npm's global tree and ran the scripts of a globally installed package nobody had verified; each of the first two flags alone failed against one of `global=true` and `location=global`, and the pair held against both. Without `--prefix`, npm walks up from where it runs the way an install does: after `npm install x --no-workspaces` in a workspace member, the gate read the member's lockfiles while `npm rebuild` there would have run over the workspace root.

And the rebuild is skipped, with a warning, when `node_modules` has no `.package-lock.json`, or when the tree npm would rebuild holds a package, or a version of one, that neither lockfile records. Which packages that tree holds is asked of npm, with the same flags: `npm query '*'` loads the tree the way `npm rebuild` does and names every package by location, name and version, and each is compared with what the two lockfiles record under that location. This replaced a walk of `node_modules` in bash, which twice covered less than npm rebuilds. It took a key on record for the package under it: with `global=0` in the project `.npmrc`, `npm install x` wrote 1.0.1 over a recorded 1.0.0 and left both lockfiles at 1.0.0, so the gate read the approved version and `npm rebuild` ran the other one's scripts. And it stopped at links: `npm rebuild` follows a `file:` dependency into its target and rebuilds the target's own `node_modules`, which no lockfile of the project records, so an approved install in the project ran the scripts of a package sitting unrecorded in the linked library (validator round 2, F2). npm's query lists that package as `../lib/node_modules/x`, and the warning names it. A link is not a node of its own there; its target is. A name is compared where the lockfile records one or the location implies one, which an `npm:` alias needs. A query that fails, or does not answer within 10 seconds, skips the rebuild too: then the tree is not known. `npm query` needs npm 8.16 or later; an older npm skips every rebuild with that warning. The skipped rebuild is a warning, not a rollback: an install off the record is already recorded `UNGATED`, and enforcing on such installs is a separate decision.

In a workspace, the root lockfile keys each member by its path (`packages/a`). The closure skips every key outside `node_modules`, because those are directories of the project rather than package names; read as one, `packages/a` was an unapproved package `packages`. And an install into a member writes the member's `package.json`, so the snapshot keeps every member's manifest. Without it, the rollback of `npm install x -w packages/a` restored the root lockfile, `npm ci` refused the member's new dependency, and the fallback reinstall put `x` back.

The snapshot keeps every member, not the ones an install is expected to write. Which members `npm install` writes is npm's to decide, and guessing it would be one more copy of npm's rules in bash. What keeps that affordable is the process count. All the manifests go through one `tar` copy into `<snapshot id>_members/` and one `shasum`, so the hook starts the same processes for 10 members as for 1000. `scripts/test/workspace-snapshot-count.sh` counts them through a shim on every command in `PATH`, which load cannot move the way it moves a time. Kept one at a time, with a `cp` and a `shasum` per member, a workspace of 1000 members took 20-33s to judge. That is past the runtime's 30s kill, where the command runs unjudged. Measured with `scripts/measure/npm-ask-cost.sh` on one machine (macOS arm64, npm 11.19.0), the whole pre-guard took 2.7s, 5.5s and 19.5s for 100, 300 and 1000 members before the change (load 18-21). After it, the medians were 0.9s, 1.0s and 1.7s (load 22-31). Re-measure before quoting these elsewhere. When the copy fails, the install is denied as undecided rather than run without a way back.

The rollback's reinstall follows the same two rules. It runs with the same flags: with `global=true` in the project `.npmrc`, a plain reinstall installed the project itself into the global prefix and left its `node_modules` empty. And when there is no lockfile to install from, or `npm ci` fails, the reinstall resolves `package.json` again. Measured, a `^1.0.0` range came back as a 1.0.1 published after the approval, and the reinstall ran its scripts. That reinstall now runs with `--ignore-scripts`, and the rollback message says so. `npm ci` from the restored lockfile keeps its scripts, because it installs exactly the tree that was on record before the command.

**What it does not stop (current limits):**

- A zero-day discovered *after* `approved_at` — only the daily re-check catches it, not the install itself.
- Compromise of the npm registry itself.
- An install that an `.npmrc` moves or keeps off the record. It is recorded `UNGATED` but not checked: npm names the global tree for any `.npmrc` it reads, and the project's and the user's are read for the settings that keep a project install unrecorded. The same settings in the global or builtin npmrc are not read for that, so such an install there is not recorded. Either way the package and its binaries land unverified. Its scripts do not run: the install is inert, and the rebuild is skipped when the tree npm would rebuild holds a package, or a version of one, that neither lockfile records.
- An npm install that left no trace where the gate looked: one sent elsewhere by something the text did not show, and one whose directory npm could not be asked about (npm missing from the hook's `PATH`, failing, not answering within 8 seconds, or handed a value the shell decides at run time) that did not land in the cwd. It is recorded `UNGATED`, and not checked. A dry run and a failed install are recorded the same way, because the trace cannot tell them apart.
- A trace the install did not leave. The trace belongs to the directory, not to the command: another npm writing to the same directory while the command runs makes one, and so does the command touching a lockfile itself. The second is a same-user attacker, the same boundary as the ledger's. A filesystem that keeps whole-second mtimes shows no trace for a lockfile written in the baseline's second, so there the install is recorded `UNGATED`: noise, not a pass.
- Two lockfile-writing npm statements with something between them are recorded `UNGATED` even when both landed where the gate looked. The rule cannot tell, and it errs toward the record.
- On Codex CLI, an install that left no trace has already run its scripts wherever it landed. The record is all there is (the existing Codex asymmetry).
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
├── confirmed_${dir_hash}      ← per-project baseline: the state the last verified install left
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
