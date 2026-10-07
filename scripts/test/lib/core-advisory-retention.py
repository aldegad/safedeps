#!/usr/bin/env python3
"""The CLI rotation contract, exercised through real native pre/post calls."""
from collections import Counter
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

CORE = sys.argv[1]
TRACE = re.compile(rb"^\[[^]]*\] INFO ")


def main():
    with tempfile.TemporaryDirectory(prefix="safedeps-native-retention.") as temp:
        root = Path(temp)
        state, project = root / "state", root / "project"
        state.mkdir()
        project.mkdir()
        (project / "package.json").write_text('{"name":"retention-fixture","version":"1.0.0"}')
        env = {key: value for key, value in os.environ.items() if not key.startswith("SAFEDEPS_")}
        env.update(HOME=str(root / "home"), SAFEDEPS_HOME=str(state),
                   SAFEDEPS_ADVISORY_LOG=str(root / "ignored.log"),
                   SAFEDEPS_ADVISORY_LOG_MAX_BYTES="999999999",
                   SAFEDEPS_ADVISORY_LOG_KEEP="3",
                   SAFEDEPS_OSV_BATCH_API_URL="http://127.0.0.1:1/no-network",
                   SAFEDEPS_KEV_CATALOG_URL="http://127.0.0.1:1/no-network")
        log = state / "advisory.log"
        # Fixed evidence from the existing Bash battery, not native output.
        evidence = (b"[2026-08-01T00:00:00Z] check approve(clean) ecosystem=npm package=e0 version=1.0.0 hash=sha256:h0\n"
                    b"[2026-08-01T00:00:00Z] ERROR OSV live query failed; stale cache refused package=e0\n")
        log.write_bytes(evidence)

        def call(phase, command, settings=env):
            payload = {"tool_name": "Bash", "tool_input": {"command": command}, "cwd": str(project)}
            result = subprocess.run([CORE, phase], input=json.dumps(payload).encode(),
                                    capture_output=True, env=settings, check=True, timeout=20)
            return json.loads(result.stdout) if result.stdout else {}

        def lock(packages):
            (project / "package-lock.json").write_text(json.dumps({
                "name": "retention-fixture", "version": "1.0.0", "lockfileVersion": 3,
                "packages": {"": {"name": "retention-fixture", "version": "1.0.0"}, **packages}}))

        # No install runs: the disk and provider caches are synthetic fixtures.
        # Native post generates the INFO channel from these cache hits.
        (state / "cache/osv").mkdir(parents=True)
        (state / "cache/kev").mkdir()
        (state / "cache/kev/known_exploited_vulnerabilities.json").write_text('{"vulnerabilities":[]}')
        packages = {}
        for index in range(40):
            name = f"retention-fixture-{index}"
            packages[f"node_modules/{name}"] = {"version": "1.0.0"}
            key = hashlib.sha256(f"osv\nnpm\n{name}\n1.0.0".encode()).hexdigest()
            (state / f"cache/osv/{key}.json").write_text('{"vulns":[]}')
        lock(packages)
        pre = call("pre", "pip install retention-denied==1.0.0")
        assert pre["hookSpecificOutput"]["permissionDecision"] == "deny", pre
        call("post", "npm ci")
        before = log.read_bytes()
        assert b"pre-guard DENY" in before, before
        assert sum(bool(TRACE.match(line)) for line in before.splitlines()) == 40, before
        assert before.startswith(evidence), before
        assert len(before) > 1000, len(before)
        assert not list(state.glob("advisory.log.*.gz"))
        print("ok - native pre/post append evidence and 40 INFO cache hits below the configured bound")

        # As in the CLI battery, the threshold and keep count are explicit
        # inputs. Older archives establish exactly which generations must go.
        older = []
        for index in range(1, 8):
            archive = state / f"advisory.log.2026080{index}T000000Z.gz"
            archive.write_bytes(gzip.compress(f"archive {index}\n".encode()))
            older.append(archive)
        env["SAFEDEPS_ADVISORY_LOG_MAX_BYTES"] = "1000"
        lock({})  # Provider initialization rotates, then adds no new INFO.
        held = state / "advisory.log.rotate.lock"
        held.mkdir()
        call("post", "npm ci")
        assert log.read_bytes().startswith(before), "a held lock compacted the live log"
        assert set(state.glob("advisory.log.*.gz")) == set(older)
        held.rmdir()
        print("ok - native rotation defers while the existing rotation lock is held")

        before = log.read_bytes()
        call("post", "npm ci")
        after = log.read_bytes()
        archives = set(state.glob("advisory.log.*.gz"))
        fresh = archives - set(older)
        assert len(fresh) == 1, archives
        archive = fresh.pop()
        assert gzip.decompress(archive.read_bytes()).startswith(before), "archive lost original bytes"
        retained = Counter(line for line in before.splitlines(keepends=True) if not TRACE.match(line))
        actual = Counter(after.splitlines(keepends=True))
        assert not retained - actual, retained - actual
        assert not any(TRACE.match(line) for line in after.splitlines()), after
        assert b"advisory log rotated" in after, after
        assert len(after) < len(before), (len(before), len(after))
        print(f"ok - native rotation archives original bytes, keeps all evidence and drops INFO ({len(before)} -> {len(after)} bytes)")
        assert archives == {archive, older[-1], older[-2]}, archives
        assert all(not path.exists() for path in older[:-2])
        print("ok - native retention keeps exactly three newest archives and removes the five oldest")

        assert not (root / "ignored.log").exists(), "the log escaped SAFEDEPS_HOME"
        assert b"SAFEDEPS_ADVISORY_LOG=" in after and b"ignored" in after
        default_env = dict(env)
        del default_env["SAFEDEPS_HOME"]
        call("pre", "pip install retention-denied==1.0.0", default_env)
        assert b"pre-guard DENY" in (root / "home/.safedeps/advisory.log").read_bytes()
        assert not (root / "ignored.log").exists()
        print("ok - native logs follow SAFEDEPS_HOME and default HOME/.safedeps, ignoring a separate log path")


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f"not ok - native advisory retention: {error}", file=sys.stderr)
        sys.exit(1)
