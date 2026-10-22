# Release procedure

A release is every step below, in order. Do not start a release without the
intent to finish it, and do not report one finished while any step is open.

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
4. **Run the consistency audit** (next section). Then have
   someone other than the author re-read the changed propositions.
5. **Test before anything leaves the machine.** Run the release tree, not a
   plan branch. The host runner records each host's load at the start and the
   end; record `uptime` beside any other run:
   - **macOS:** `scripts/ci/run-on-hosts.sh --release --rev <release head>
     --hosts <the macOS hosts>` (or `npm run test:release` on one host), and
     the release checks, `scripts/ci/release-checks.sh` in a clone with its
     full history: the ShellCheck file list, `./bin/safedeps scan secrets
     --repo`, and the package contents (zero runtime dependencies, `npm pack
     --dry-run`). The secret scan runs the gitleaks on PATH only when that
     binary's sha256 is the pinned release binary's; `--install-gitleaks DIR`
     installs the pinned release where it is not. ShellCheck has no such
     path: `release-checks.sh` has `--install-gitleaks` and nothing that
     prepares ShellCheck, and the tree pins no ShellCheck version.
   - **Windows:** in WSL1 on the home Windows PC, in the distribution made for
     these tests (`KumaWsl1Probe`, one slot): `smoke.sh`, `self-budget.sh`,
     `effect-trace-grid.sh` and `e2e.sh`, with the fixture projects on the
     Linux root and on a Windows drive, at nice 0 (no `nice` around the
     battery). These four reach what WSL1 does differently, the cost of a
     process and the file metadata of a Windows drive. The binary is the
     `linux-x64` one, built on a macOS host the way step 10 builds it
     (`scripts/build-core.sh --publish --target x86_64-unknown-linux-musl`)
     and checked in WSL1 with `stamp --check`. `smoke.sh`, `self-budget.sh`
     and `effect-trace-grid.sh` run from the `git archive` of the release
     head, `rust/` included (`smoke.sh` reads `rust/Cargo.toml`). `e2e.sh`
     runs from the tree a user receives: that archive without `rust/`, and
     the binary in `bin/native/linux-x64/`. With `rust/` beside it, e2e's
     installer rows require cargo, and WSL1 has none. e2e prints
     `# skipped rows: N; names: …` at its end, and a person reads that line:
     the rows that copy the source need Darwin and skip on Linux, and on a
     Windows drive the permission rows and the FIFO row skip as well. A skipped
     row is not a pass. The whole release set has not been run there and is not
     part of a release. `/proc/loadavg` is a constant in WSL1, so record the
     Windows CPU beside the run instead of `uptime`. Two limits, both in
     ROADMAP.md ("Known limits in WSL1"): if effect-trace-grid goes red on one
     provider call with no answer for 20s (`OSV batch query failed status=000`
     in `advisory.log`), run the battery once more, and two reds in a row are a
     defect; and `/proc/<pid>/stat` gives a wrong nice in WSL1, so a battery
     run at a positive nice goes red at e2e's stopped-owner row, which is why
     the batteries run at nice 0.

   `npm run test:release` on one host, and each battery run by hand in WSL1,
   is judged by `run-all.sh` or by the battery alone, and neither judges
   skipped rows (AGENTS.md, Testing): a battery that prints `ok ... SKIPPED` or a
   TAP skip directive and exits 0 is green there, and only the host runner's
   verdict turns it red. So such a run has its logs read for skipped rows
   before it counts.

6. **Run the release gates.** The package has zero runtime dependencies
   (`jq '(.dependencies // {}) + (.optionalDependencies // {}) | length'
   package.json` prints 0), `./bin/safedeps scan secrets --repo` passes, and
   `npm pack --dry-run` lists only what `files` allows.
   `scripts/ci/release-checks.sh` runs these three. `scripts/release-gates.sh
   --strict` is not the gate for this repo, because it cannot pass here: its
   dependency audit needs a lockfile, a package with no dependencies has none,
   and the audit exits 2 without one on every machine. Its install-guard check
   also fails wherever safedeps is not installed.
7. **Move main forward, and give the main checkout the binary built from
   what it now holds.** The installed hooks execute the main checkout, and
   the core refuses to judge from a source other than the one it was built
   from (the stamp). So the binary in the main checkout's `bin/native/` has
   to be the one built from the new source. Build it before main moves, on a
   remote macOS host (carenine or the M1), from an archive of the release
   head with `scripts/build-core.sh`, and bring the `darwin-arm64` binary
   back: the machine that holds the main checkout does not build with cargo.
   Build first, then `git merge --ff-only`, then put the new binary in the
   main checkout's `bin/native/<os>-<arch>/` by copying it to a name beside
   the old one and renaming it over, never by writing over the old file: a
   hook may be running it, and macOS kills a process whose executable was
   written under it. Between the move and the rename every install is denied
   `UNDECIDED` and every other command runs with the mismatch said on stderr.
   That window is fail-closed and lasts seconds, which is why the build comes
   first: building after main moves would hold every session on the machine in
   that state for the length of a build.

   Then run `bin/native/<os>-<arch>/safedeps-core stamp --check` in the main
   checkout and read `ok`. If it does not say `ok`, the binary does not
   match the source, and the state is the out-of-date one: an install is
   denied `UNDECIDED` and every other command runs with the mismatch said on
   stderr. It is not the "no binary" state. Build again on a remote macOS
   host from the release head, and replace the binary the same way, by
   copying it beside and renaming it over. That is the second path, and it
   is written here so that it is never a silent alternative; the window then
   lasts as long as the rebuild and the copy. Then push one benign command
   and one install through `scripts/safedeps-hook-entry.sh pre` and read both
   answers before going on.
8. **Push.** `git push origin main`.
9. **Tag and publish the GitHub release.** An annotated tag `vX.Y.Z` on the
   pushed commit, pushed, and `gh release create vX.Y.Z --notes-file <notes>`.
   Pushing the tag starts nothing: step 10 publishes to npm by hand.
   The notes cover every user-visible change since the previous tag (derive them
   from `git log <previous-tag>..vX.Y.Z` and the ROADMAP section): security
   fixes first, each with what could get past before and how it is verified
   now, then fixes, then anything a user has to do. Then read it back:
   `gh release view vX.Y.Z --json isDraft,isPrerelease,tagName` must show
   `false`, `false` and the tag, and `gh release view --json tagName` (the
   latest release) must name it. A draft is not a release: users and
   `releases/latest` never see it.
10. **Publish to npm, from our own hosts.** npm's trusted publishing and its
    provenance attestations need a cloud-hosted CI runner (GitHub-hosted,
    GitLab.com shared or CircleCI cloud), and our hosts are not one. So a
    version published here names the owner's npm account as its publisher and
    carries no provenance. Do not pass `--provenance`.

    A remote macOS host (step 7)
    builds, with the toolchain pinned below and nowhere else, and holds no npm
    credential. The publishing machine, an Apple silicon Mac with the owner's
    npm login, `jq` and npm, runs no compiler. Both start from one archive of
    the tag, `rust/` included. Each block below runs as one bash script with
    `set -euo pipefail` and `V=X.Y.Z`, so a failed line stops it.

    - **Archive** (publishing machine, main checkout, after step 9):
      `git archive --format=tar.gz -o "$R/safedeps-v$V.tar.gz" "v$V"`, where
      `$R` is a new empty directory. Copy the archive to the build host and
      to WSL1.
    - **Build** (build host, in a new empty directory holding the archive):

      ```bash
      mkdir src && tar -xzf "safedeps-v$V.tar.gz" -C src && cd src
      rustup toolchain install 1.94.0 --profile minimal --no-self-update \
        --target aarch64-apple-darwin --target x86_64-apple-darwin --target x86_64-unknown-linux-musl
      RUSTUP_TOOLCHAIN=1.94.0 scripts/build-core.sh --publish --sums native.sha256 \
        --target aarch64-apple-darwin --target x86_64-apple-darwin --target x86_64-unknown-linux-musl
      [ "$(wc -l < native.sha256 | tr -d ' ')" = 3 ]
      if arch -x86_64 /usr/bin/true 2>/dev/null; then
        arch -x86_64 ./bin/native/darwin-x64/safedeps-core version
        arch -x86_64 ./bin/native/darwin-x64/safedeps-core stamp
      else
        echo "this host cannot run x86_64 programs: darwin-x64 was built and not run"
      fi
      COPYFILE_DISABLE=1 tar -czf ../native.tar.gz bin/native native.sha256
      ```

      `build-core.sh` runs the `darwin-arm64` binary and checks its stamp
      against the tag's `rust/` before it places it. Bring `native.tar.gz` to
      `$R` on the publishing machine and to WSL1.
    - **Linux check** (WSL1, the distribution of step 5, in a new empty
      directory holding both files). The package ships this binary, and no
      other host runs it before the publish:

      ```bash
      mkdir pkg && tar -xzf "safedeps-v$V.tar.gz" -C pkg && tar -xzf native.tar.gz -C pkg && cd pkg
      ( cd bin/native && sha256sum -c ../../native.sha256 )
      core=./bin/native/linux-x64/safedeps-core
      [ "$("$core" version)" = "safedeps-core $V" ]
      stamp=$("$core" stamp); [ "${stamp%% *}" = publish ]
      [ "$("$core" stamp --check 2>&1)" = ok ]
      ```

    - **Check the package** (publishing machine, in `$R`):

      ```bash
      mkdir pkg && tar -xzf "safedeps-v$V.tar.gz" -C pkg && tar -xzf native.tar.gz -C pkg && cd pkg
      [ "$(wc -l < native.sha256 | tr -d ' ')" = 3 ]
      ( cd bin/native && shasum -a 256 -c ../../native.sha256 )
      chmod 755 bin/native/*/safedeps-core
      core=./bin/native/darwin-arm64/safedeps-core
      stamp=$("$core" stamp); [ "${stamp%% *}" = publish ]
      [ "$("$core" stamp --check 2>&1)" = ok ]
      [ "$(jq -r .version package.json)" = "$V" ]
      [ "$(./bin/safedeps --json version | jq -r .version)" = "$V" ]
      [ "$(sed -n 's/^version = "\(.*\)"$/\1/p' rust/Cargo.toml | head -n 1)" = "$V" ]
      [ "$("$core" version)" = "safedeps-core $V" ]
      [ "$(jq '(.dependencies // {}) + (.optionalDependencies // {}) + (.peerDependencies // {}) | length' package.json)" = 0 ]
      npm pack --dry-run --json > ../pack.json
      for p in darwin-arm64 darwin-x64 linux-x64; do
        [ "$(jq -r --arg f "bin/native/$p/safedeps-core" '[.[0].files[] | select(.path == $f) | .mode] | if length == 1 then .[0] else "none" end' ../pack.json)" = 493 ]
      done
      [ "$(jq '.[0].files | map(.path) | any(startswith("rust/"))' ../pack.json)" = false ]
      [ "$(npm config get provenance)" = false ]
      ```

    - **Publish** (publishing machine, in `$R/pkg`, by hand, because npm asks
      for the second factor). `npm whoami` must print an account that
      `npm owner ls @aldegad/safedeps` lists; if it prints none, `npm login`
      first (a browser login by default). Then `npm publish`, and answer
      npm's one-time password challenge. Nothing is installed: the package
      has no dependencies and no lockfile. What is packed is this tree, the
      tag's files and the binaries the build made.
    - **Read the release back** (publishing machine, in `$R/pkg`). The
      registry can answer 404 for minutes after a publish, so each try asks the version document and the package
      document with a fresh query string and no-cache, for up to 20 minutes:

      ```bash
      name=@aldegad/safedeps base=https://registry.npmjs.org/@aldegad%2fsafedeps
      sums="$PWD/native.sha256"
      unconfirmed() { echo "$name@$V was published, but the read-back failed: $1. Do not publish it again; read 'npm view $name@$V' and fix forward in the next patch." >&2; exit 1; }
      meta="" deadline=$(( $(date +%s) + 1200 )) try=0
      while [ -z "$meta" ]; do
        try=$((try + 1)); fresh="t=$(date +%s)-$try-$RANDOM"
        code=$(curl -sS -o ../version.json -w '%{http_code}' -H 'Cache-Control: no-cache' "$base/$V?$fresh" || true)
        if [ "$code" = 200 ] && jq -e --arg v "$V" '.version == $v' ../version.json >/dev/null; then meta=$(cat ../version.json); break; fi
        pcode=$(curl -sS -o ../document.json -w '%{http_code}' -H 'Cache-Control: no-cache' "$base?$fresh" || true)
        if [ "$pcode" = 200 ] && jq -e --arg v "$V" '.versions[$v]' ../document.json >/dev/null; then meta=$(jq --arg v "$V" '.versions[$v]' ../document.json); break; fi
        echo "try $try: version document $code, package document $pcode without $V"
        [ "$(date +%s)" -lt "$deadline" ] || unconfirmed "the registry did not name $V for 20 minutes"
        sleep 20
      done
      jq -r '"publisher: \(._npmUser.name // "none"), trusted publisher: \(._npmUser.trustedPublisher.id // "none"), provenance: \(.dist.attestations.provenance.predicateType // "none")"' <<<"$meta"
      [ "$(jq -r '._npmUser.name // empty' <<<"$meta")" = "$(npm whoami)" ] || unconfirmed "the registry names another publisher"
      npm pack --dry-run --json | jq -r '.[0].files[].path' | sort > ../local.txt || unconfirmed "npm pack --dry-run of this tree did not list its files"
      url=$(jq -r '.dist.tarball // empty' <<<"$meta"); [ -n "$url" ] || unconfirmed "the registry names no dist.tarball"
      curl -sSfL --retry 10 --retry-delay 15 --retry-all-errors -o ../published.tgz "$url" || unconfirmed "$url did not download"
      tar -tzf ../published.tgz | sed 's#^package/##' | sort > ../published.txt || unconfirmed "the tarball did not list as a gzip tar"
      diff -u ../local.txt ../published.txt || unconfirmed "the published file list differs from npm pack --dry-run of this tree"
      for p in darwin-arm64 darwin-x64 linux-x64; do
        tar -tvzf ../published.tgz "package/bin/native/$p/safedeps-core" | grep -q '^-rwxr-xr-x' || unconfirmed "bin/native/$p/safedeps-core is not mode 755 in the tarball"
      done
      mkdir ../published && tar -xzf ../published.tgz -C ../published || unconfirmed "the tarball did not unpack"
      ( cd ../published/package/bin/native && shasum -a 256 -c "$sums" ) || unconfirmed "a published binary is not the bytes the build made"
      [ "$(../published/package/bin/native/darwin-arm64/safedeps-core version)" = "safedeps-core $V" ] || unconfirmed "the published darwin-arm64 binary does not say safedeps-core $V"
      ```

    Then confirm it by hand: `npm view @aldegad/safedeps version` is X.Y.Z.
    A failure at `npm publish` is a login, second-factor or permission
    failure. Read `npm view @aldegad/safedeps@X.Y.Z version` before trying
    again, because a publish that failed late can still have published. A
    failure in the read-back comes after the publish: the version is
    published and cannot be published again, so fix forward in the next
    patch.

    **Not yet run.** No version has been built and published by this step,
    the `darwin-x64` binary has not run on Intel hardware, and no version
    published this way has been read back. Do not write any of these as
    verified before a run has shown it.

    **Publishing access is the owner's choice** (npmjs.com, the package's
    Settings → Publishing access). Under "Require two-factor authentication
    and disallow tokens", only an interactive publish with the second factor
    works, which is this step. A granular access token with "Bypass 2FA"
    publishes only under the default setting, and npm removes direct
    publishing with such a token in January 2027 (npm Docs, "About access
    tokens"), so this step uses none. The trusted publisher on npmjs.com that
    names `publish.yml` and the `npm-publish` environment, and that
    environment on GitHub, no longer have a workflow. While they stay, a
    workflow file of that name in this repository, run from a `v*` tag, could
    still publish with an OIDC token. Deleting them is the owner's choice; a
    trusted publisher connection can be deleted, not edited.
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
# concept presence, per file
for f in README.md README.ko.md ARCHITECTURE.md ARCHITECTURE.ko.md SKILL.md AGENTS.md; do
  grep -qi 'inert\|--ignore-scripts' "$f" || echo "inert-install missing from $f"
done
npm test
```
