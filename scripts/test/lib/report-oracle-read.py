#!/usr/bin/env python3
"""Readings the report oracle makes by a method that is not the hook's.

The oracle and the hook once ran the same wrong check and agreed: a find
without -H over a linked node_modules listed nothing on both sides (F1). So the
listings are read here with Python's directory walk.

Whether a command carries --ignore-scripts used to be read here too, with
shlex and npm's own option parser, and the hook read it with the install
grammar. Both readers kept the same model of a shell statement, and both
missed the same commands (an assignment or an export of
npm_config_ignore_scripts, a project .npmrc). The hook no longer reads the
command for the flag, so neither does this file.

  packages <node_modules>
      One path per line: the files named package.json at most three levels
      below node_modules, reached through directories. node_modules itself is
      followed when it is a link; a link below it is not, as the listings the
      hooks compare against do not follow one.

  listing <directory>
      One line per entry directly in the directory, sorted: the name, a tab,
      and what it is: l:<link target>, d, f:<sha256 of the bytes>, or o. A
      directory that cannot be read prints nothing.

  string <JSON file> <key>...
      The string at that path of keys, its bytes and nothing else. Exit 1
      when there is no string there, 3 when the file is not JSON.

  wrote <snapshot meta file>
      The command a pre-guard record says safedeps wrote: updated_command,
      when ignore_scripts_injected is true. Exit 1 when the record says it
      wrote none, 3 when the file cannot be read or says it wrote one and
      holds no string. The hooks read these records with jq; the oracle reads
      them here (bamdori r18: the oracle found the record the way the hook
      did, and both said "did not add" of a command safedeps had written).
"""
import hashlib
import json
import os
import sys


def packages(nm):
    out = []

    def walk(directory, depth):
        try:
            entries = list(os.scandir(directory))
        except OSError:
            return
        for entry in entries:
            path = os.path.join(directory, entry.name)
            if entry.name == "package.json":
                out.append(path)
            try:
                is_dir = entry.is_dir(follow_symlinks=False)
            except OSError:
                is_dir = False
            if is_dir and depth + 1 < 3:
                walk(path, depth + 1)

    if os.path.isdir(nm):
        walk(nm, 0)
    for path in out:
        print(path)


def listing(directory):
    try:
        entries = sorted(os.scandir(directory), key=lambda entry: entry.name)
    except OSError:
        return
    for entry in entries:
        path = os.path.join(directory, entry.name)
        if entry.is_symlink():
            kind = "l:" + os.readlink(path)
        elif entry.is_dir(follow_symlinks=False):
            kind = "d"
        elif entry.is_file(follow_symlinks=False):
            digest = hashlib.sha256()
            try:
                with open(path, "rb") as handle:
                    for block in iter(lambda: handle.read(65536), b""):
                        digest.update(block)
                kind = "f:" + digest.hexdigest()
            except OSError:
                kind = "f:unreadable"
        else:
            kind = "o"
        print("%s\t%s" % (entry.name, kind))


def load(path):
    try:
        with open(path, "rb") as handle:
            return json.loads(handle.read().decode("utf-8"))
    except (OSError, ValueError):
        return None


def emit(text):
    sys.stdout.buffer.write(text.encode("utf-8", "surrogatepass"))


def string(path, keys):
    value = load(path)
    if value is None:
        return 3
    for key in keys:
        if not isinstance(value, dict) or key not in value:
            return 1
        value = value[key]
    if not isinstance(value, str):
        return 1
    emit(value)
    return 0


def wrote(path):
    meta = load(path)
    if not isinstance(meta, dict):
        return 3
    if meta.get("ignore_scripts_injected") is not True:
        return 1
    command = meta.get("updated_command")
    if not isinstance(command, str):
        return 3
    emit(command)
    return 0


def main():
    if sys.argv[1] == "string":
        return string(sys.argv[2], sys.argv[3:])
    if sys.argv[1] == "wrote":
        return wrote(sys.argv[2])
    if sys.argv[1] == "packages":
        packages(sys.argv[2])
        return 0
    if sys.argv[1] == "listing":
        listing(sys.argv[2])
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
