#!/usr/bin/env python3
"""Readings the report oracle makes by a method that is not the hook's.

Twice the oracle and the hook ran the same wrong check and agreed: a find
without -H over a linked node_modules listed nothing on both sides (F1), and a
substring test for --ignore-scripts said "carries it" on both sides for
`--ignore-scripts=false` (F2). So these two facts are read here with other
tools: Python's directory walk for the listing, and Python's shlex and npm's
own option parser (`npm config get`) for the command.

  packages <node_modules>
      One path per line: the files named package.json at most three levels
      below node_modules, reached through directories. node_modules itself is
      followed when it is a link; a link below it is not, as the listings the
      hooks compare against do not follow one.

  listing <directory>
      One line per entry directly in the directory, sorted: the name, a tab,
      and what it is: l:<link target>, d, f:<sha256 of the bytes>, or o. A
      directory that cannot be read prints nothing.

  inert <carries|lacks> <command> <npm> <cache dir>
      Exit 0 when the claim holds for the command, 1 with the reason when it
      does not or cannot be shown. "carries": every npm install statement's
      words make npm read ignore-scripts as true, spelled --ignore-scripts or
      --ignore-scripts=true. "lacks": no word of the command can be read as the
      option, or npm reads it as false in every npm install statement.
"""
import hashlib
import os
import re
import shlex
import subprocess
import sys
import tempfile


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


# npm's install commands and their documented aliases (npm help install, ci,
# install-test, install-ci-test, update, link).
INSTALL_COMMANDS = {
    "install", "add", "i", "in", "ins", "inst", "insta", "instal", "isnt", "isnta", "isntal", "isntall",
    "ci", "clean-install", "ic", "install-clean", "isntall-clean",
    "install-test", "it", "install-ci-test", "cit", "clean-install-test", "sit",
    "update", "up", "upgrade", "udpate", "link", "ln",
}


def option_word(word):
    return word.startswith("-") and "ig" in word.lower()


def npm_reading(words, npm, cache):
    """npm's reading of the words after `npm`: (ignore-scripts value, command word)."""
    key = hashlib.sha1("\0".join(words).encode()).hexdigest()
    cached = os.path.join(cache, key)
    if os.path.exists(cached):
        with open(cached) as handle:
            text = handle.read()
    else:
        with tempfile.TemporaryDirectory() as home:
            for name in ("userrc", "globalrc"):
                open(os.path.join(home, name), "w").close()
            env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": home}
            result = subprocess.run(
                [npm, "config", "get", "ignore-scripts", *words,
                 "--userconfig=" + os.path.join(home, "userrc"),
                 "--globalconfig=" + os.path.join(home, "globalrc")],
                cwd=home, env=env, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=60,
            )
            text = result.stdout if result.returncode == 0 else ""
        os.makedirs(cache, exist_ok=True)
        with open(cached, "w") as handle:
            handle.write(text)
    lines = [line for line in text.splitlines() if line]
    if len(lines) < 2 or not lines[0].startswith("ignore-scripts="):
        return None, None
    return lines[0].split("=", 1)[1], lines[1].split("=", 1)[0]


REDIRECTION = re.compile(r"(?:(?<=[\s;&|])|^)\d*(?:&>>|&>|>>|>&|<&|>|<)\s*[^\s;&|<>]+")
SEPARATOR = re.compile(r"&&|\|\||[;|&\n]")
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*\+?=")
NPM_WORD = re.compile(r"(^|[/=])npm$")


def statements(command):
    """The statements of a command with nothing for the shell to decide, or None."""
    if re.search(r"[^A-Za-z0-9@%+,./:=^_~ \t\n;&|<>-]", command):
        return None
    return [part.split() for part in SEPARATOR.split(REDIRECTION.sub(" ", command)) if part.strip()]


def inert(claim, command, npm, cache):
    command = command.replace("\\\n", "")
    if claim == "lacks" and not re.search(r"[$`*?\[{]", command):
        lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
        lexer.commenters = ""
        try:
            words = list(lexer)
        except ValueError:
            words = None
        if words is not None and not any(option_word(word) for word in words):
            return None
    parts = statements(command)
    if parts is None:
        return "the command is not one this file can read statement by statement"
    counted = 0
    for words in parts:
        k = 0
        while k < len(words) and ASSIGNMENT.match(words[k]):
            k += 1
        if k < len(words) and words[k] == "npm":
            rest = words[k + 1:]
            value, verb = npm_reading(rest, npm, cache)
            if value is None:
                return "npm did not read the words of %r" % " ".join(words)
            if verb not in INSTALL_COMMANDS:
                continue
            counted += 1
            flagged = [word for word in rest if option_word(word)]
            if claim == "carries":
                if value != "true":
                    return "npm reads ignore-scripts as %s in %r" % (value, " ".join(words))
                if any(word not in ("--ignore-scripts", "--ignore-scripts=true") for word in flagged):
                    return "%r spells the option some other way" % " ".join(words)
            elif value != "false":
                return "npm reads ignore-scripts as %s in %r" % (value, " ".join(words))
        elif any(NPM_WORD.search(word) for word in words[k:]):
            return "an npm that does not start the statement %r" % " ".join(words)
    if counted == 0:
        return "no npm install statement"
    return None


def main():
    if sys.argv[1] == "packages":
        packages(sys.argv[2])
        return 0
    if sys.argv[1] == "listing":
        listing(sys.argv[2])
        return 0
    if sys.argv[1] == "inert":
        why = inert(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])
        if why:
            print(why)
            return 1
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
