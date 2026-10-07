#!/usr/bin/env python3
"""Fixed native reader contracts; no Bash implementation is read or run."""
import json
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[3]
CORE = sys.argv[1]


def query(args, data=b"", reading="bash"):
    return subprocess.run([CORE, *args], input=data, capture_output=True,
                          env=dict(os.environ, SAFEDEPS_READING=reading),
                          check=True, timeout=20).stdout


def table():
    grammar = dict(line.split("=", 1) for line in query(["grammar"]).decode().splitlines())
    commands = {word.split("=", 1)[0] for word in grammar["SAFEDEPS_G_COMMANDS"].split()}
    entries = {}
    for word in grammar["SAFEDEPS_G_VALUE_OPTIONS"].split():
        key, value = word.rsplit("=", 1)
        family, scoped = key.split("/", 1)
        scope, option = scoped.split(":", 1)
        assert key not in entries, ("duplicate", key)
        entries[key] = value
        if scope != "*":
            assert f"{family}:{scope}" in commands or any(
                command.startswith(f"{family}:{scope},") for command in commands
            ), ("unreachable", word)
            assert f" {family}/*:{option}=" not in grammar["SAFEDEPS_G_VALUE_OPTIONS"], (
                "global and command overlap", word)
    assert len(entries) > 100, "empty or truncated native table"
    print(f"ok - native grammar: {len(entries)} unique, reachable value options")


def source_map():
    cases = [json.loads(line) for line in
             (ROOT / "scripts/measure/core-payload-command-cases.jsonl").read_text().splitlines()]
    # The release's lexing rows: a glued brace belongs to the substitution's
    # own text; a nested backtick body loses its quoting backslashes once.
    # Query each level through the native payload API used by inert.
    cases += [
        {"command": "npm ci; x=$( { npm ci --ignore-scripts=false} )",
         "expected": [{"kind": "B", "text": " { npm ci --ignore-scripts=false} ",
                       "origin": "command-substitution", "shell": None}]},
        {"command": r"echo `echo \`{ npm ci}\``",
         "expected": [{"kind": "B", "text": "echo `{ npm ci}`",
                       "origin": "backquote", "shell": None}],
         "child_expected": [[{"kind": "B", "text": "{ npm ci}",
                              "origin": "backquote", "shell": None}]]},
    ]
    count = mapped = decoded = 0

    def check(text, expected, reading, failed=False):
        nonlocal count, mapped, decoded
        raw = text.encode()
        result = json.loads(query(["payloads"], raw, reading))
        assert result["failed"] == failed, (text, reading, result)
        shape = [{key: item[key] for key in ("kind", "text", "origin", "shell")}
                 for item in result["payloads"]]
        assert shape == expected, (text, reading, shape, expected)
        for item in result["payloads"]:
            data = item["text"].encode()
            assert len(data) == len(item["src"]), (text, item)
            for byte, offset in zip(data, item["src"]):
                if offset is None:
                    decoded += 1
                else:
                    assert isinstance(offset, int) and 0 <= offset < len(raw), item
                    assert raw[offset] == byte, (text, item, offset)
                    mapped += 1
        count += 1
        return result

    for case in cases:
        for reading in case.get("readings", ["bash", "zsh", "dash"]):
            result = check(case["command"], case["expected"], reading, case.get("failed", False))
            for index, expected in enumerate(case.get("child_expected", [])):
                check(result["payloads"][index]["text"], expected, reading)
    assert count and mapped and decoded, (count, mapped, decoded)
    print(f"ok - payload attribution: {count} readings, {mapped} source bytes, {decoded} decoded bytes")


def facts(text):
    payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": text}}).encode()
    stream = io.BytesIO(query(["facts"], payload))
    result = {}
    while line := stream.readline():
        key, length = line.decode().rstrip("\n").split(" ")
        assert key not in result, ("duplicate fact", key)
        value = stream.read(int(length))
        assert len(value) == int(length) and stream.read(1) == b"\n", line
        result[key] = value
    return result


def corpus():
    inputs = []
    for filename, field in [("scan-corpus.json", "command"), ("tuple-corpus.json", "command"),
                            ("shell-reading-forms.json", "text"), ("word-reading-forms.json", "text")]:
        inputs.extend(case[field] for case in json.loads((ROOT / "scripts/measure" / filename).read_text()))
    inputs.extend(text.decode() for text in Path(sys.argv[3]).read_bytes().split(b"\0")[:-1])
    installs = failed = 0
    for text in inputs:
        result = facts(text)
        if not text.rstrip("\n"):
            assert not result, ("empty command produced facts", result)
            continue
        for key in ("closed", "any_install", "piped", "failed.detect"):
            assert result[key] in (b"true", b"false"), (key, text, result)
        assert result["reading_set"] in (b"bash", b"bash zsh dash"), (text, result)
        if result["closed"] == b"false":
            assert result["failed.detect"] == b"true", ("unclosed input silently accepted", text, result)
        if result["any_install"] == b"true":
            installs += 1
            assert "ledger_specs" in result and "ledger_eco" in result, (text, result)
            assert result["failed.facts"] in (b"true", b"false"), (text, result)
            if result["failed.detect"] == b"true":
                assert result["failed.facts"] == b"true", ("failure lost", text, result)
        failed += result["failed.detect"] == b"true"
    # Fixed expectations for the multiline ecosystem cases from the former
    # batch comparison. These are an oracle, not another parser's answers.
    for row in json.loads((ROOT / "scripts/test/lib/reader-ecosystems.json").read_text()):
        text, expected = row["command"], row["ecosystem"].encode()
        result = facts(text)
        assert result["ledger_eco"] == expected, (text, result)
        assert result["failed.facts"] == b"false", (text, result)
    assert installs and failed, (installs, failed)
    print(f"ok - native facts: {len(inputs)} corpus inputs, {installs} installs, {failed} explicit failed readings")
    print("ok - ten multiline ecosystem expectations")


def settlement():
    # Public counterexamples connect the reader's failed state to pre's
    # settlement; internal invalid-view controls live beside Run in Rust.
    with tempfile.TemporaryDirectory(prefix="safedeps-reader-settlement.") as temp:
        root = Path(temp)
        for index, (command, denied) in enumerate([
            ('printf "\npip install evil==6.6.6', True), ("echo '", False)
        ]):
            state = root / str(index)
            payload = json.dumps({"tool_name": "Bash", "cwd": str(root),
                                  "tool_input": {"command": command}}).encode()
            result = subprocess.run([CORE, "pre"], input=payload, capture_output=True,
                                    env=dict(os.environ, HOME=str(root / "home"),
                                             SAFEDEPS_HOME=str(state)), check=True, timeout=20)
            log = (state / "advisory.log").read_text()
            assert "scanner failed" in log, (command, log)
            if denied:
                hook = json.loads(result.stdout)["hookSpecificOutput"]
                assert hook["permissionDecision"] == "deny", hook
                assert "UNDECIDED" in hook["permissionDecisionReason"], hook
                assert not list((state / "pending").glob("*.json")), command
            else:
                assert not result.stdout, result.stdout
                assert b"could not be fully read" in result.stderr, result.stderr
    print("ok - native pre settles unclosed manager input as UNDECIDED and reports unread non-installs")


if __name__ == "__main__":
    try:
        {"table": table, "source-map": source_map, "corpus": corpus,
         "settlement": settlement}[sys.argv[2]]()
    except (AssertionError, subprocess.SubprocessError, ValueError, KeyError) as error:
        print(f"not ok - native reader: {error}", file=sys.stderr)
        sys.exit(1)
