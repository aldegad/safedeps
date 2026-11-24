#!/usr/bin/env python3
"""The rotation contract, exercised through real native pre/post calls."""
import fcntl
import gzip
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import threading

CORE = sys.argv[1]
TRACE = re.compile(rb"^\[[^]]*\] INFO ")
ARCHIVE = re.compile(r"^advisory\.log\.\d{8}T\d{6}Z(?:\.[1-9]\d*)?(?:\.gz)?$")


def archives(state):
    """The archives in the state directory, plain and gzip."""
    return {path for path in state.iterdir() if ARCHIVE.match(path.name)}


class Batch(BaseHTTPRequestHandler):
    """OSV querybatch on loopback: no advisory for any package."""

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("content-length") or 0)) or b"{}")
        data = json.dumps({"results": [{} for _ in body.get("queries", [])]}).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Batch)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        run(f"http://127.0.0.1:{server.server_address[1]}/v1/querybatch")
    finally:
        server.shutdown()


def run(batch_url):
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
                   SAFEDEPS_OSV_BATCH_API_URL=batch_url,
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

        # No install runs: the lockfile and the KEV catalog are synthetic
        # fixtures, and OSV is the loopback batch above. Native post writes one
        # INFO line per package OSV answered.
        (state / "cache/kev").mkdir(parents=True)
        (state / "cache/kev/known_exploited_vulnerabilities.json").write_text('{"vulnerabilities":[{"cveID":"CVE-2026-9999"}]}')
        packages = {}
        for index in range(40):
            name = f"retention-fixture-{index}"
            packages[f"node_modules/{name}"] = {"version": "1.0.0"}
        lock(packages)
        # An unfinished manager command records the scanner's denial. An
        # ordinary unapproved install denies without writing that log line.
        denied_command = 'printf "\npip install retention-denied==1.0.0'
        pre = call("pre", denied_command)
        assert pre["hookSpecificOutput"]["permissionDecision"] == "deny", pre
        call("post", "npm ci")
        before = log.read_bytes()
        assert b"pre-guard DENY" in before, "the native pre denial left no evidence"
        assert sum(bool(TRACE.match(line)) for line in before.splitlines()) == 40, before
        assert before.startswith(evidence), before
        assert len(before) > 1000, len(before)
        assert not archives(state)
        assert not (state / "advisory.log.rotate.lock").exists(), "a look under the bound made the lock file"
        print("ok - native pre/post append evidence and 40 INFO live answers below the configured bound")

        # As in the CLI battery, the threshold and keep count are explicit
        # inputs. Older archives establish exactly which generations must go.
        older = []
        for index in range(1, 8):
            archive = state / f"advisory.log.2026080{index}T000000Z.gz"
            archive.write_bytes(gzip.compress(f"archive {index}\n".encode()))
            older.append(archive)
        env["SAFEDEPS_ADVISORY_LOG_MAX_BYTES"] = "1000"
        lock({})  # Provider initialization rotates, then adds no new INFO.
        with open(state / "advisory.log.rotate.lock", "a") as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            call("post", "npm ci")
            assert log.read_bytes().startswith(before), "a held lock rotated the live log"
            assert archives(state) == set(older)
        print("ok - native rotation defers while another process holds the rotation lock")

        before = log.read_bytes()
        inode = log.stat().st_ino
        call("post", "npm ci")
        after = log.read_bytes()
        found = archives(state)
        fresh = found - set(older)
        assert len(fresh) == 1, found
        archive = fresh.pop()
        assert not archive.name.endswith(".gz"), "the new archive is compressed"
        assert archive.stat().st_ino == inode, "the archive is not the live file renamed"
        assert archive.read_bytes().startswith(before), "the archive lost bytes of the live file"
        # The rotated file's evidence and INFO lines left the live file. The
        # run's own WARN lines may repeat earlier ones to the second, so they
        # are not compared.
        assert not any(TRACE.match(line) for line in after.splitlines()), after
        assert evidence not in after and b"pre-guard DENY" not in after, after
        assert after.startswith(b"[") and b"] WARN advisory log rotated: " in after.splitlines()[0], after
        assert f"bytes moved to {archive.name}".encode() in after.splitlines()[0], after
        assert len(after) < len(before), (len(before), len(after))
        lock_file = state / "advisory.log.rotate.lock"
        assert lock_file.is_file() and not lock_file.is_symlink(), "the lock is not a regular file"
        print(f"ok - native rotation renames the whole live log to a plain archive, and the new log starts with its line ({len(before)} -> {len(after)} bytes)")
        assert found == {archive, older[-1], older[-2]}, found
        assert all(not path.exists() for path in older[:-2])
        print("ok - native retention keeps exactly three newest archives and removes the five oldest")

        assert not (root / "ignored.log").exists(), "the log escaped SAFEDEPS_HOME"
        # The warning was written by an earlier call, so the rename moved it
        # with the rest of that file. The record is the live file and the
        # archive just made.
        record = archive.read_bytes() + after
        assert b"SAFEDEPS_ADVISORY_LOG=" in record and b"ignored" in record, "no line says the separate log path was ignored"
        default_env = dict(env)
        del default_env["SAFEDEPS_HOME"]
        call("pre", denied_command, default_env)
        assert b"pre-guard DENY" in (root / "home/.safedeps/advisory.log").read_bytes(), "the default home's log has no denial"
        assert not (root / "ignored.log").exists()
        print("ok - native logs follow SAFEDEPS_HOME and default HOME/.safedeps, ignoring a separate log path")


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f"not ok - native advisory retention: {error}", file=sys.stderr)
        sys.exit(1)
