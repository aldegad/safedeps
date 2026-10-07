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
      The command a pre-guard record says safedeps wrote: updated_command.
      Exit 1 when the record says it wrote none, 3 when the file is not one
      JSON object, 4 when there is no file or the record does not state
      either (see record). The hooks read these records with jq; the oracle
      reads them here (bamdori r18: the oracle found the record the way the
      hook did, and both said "did not add" of a command safedeps had
      written).

  call <hook input file>
      The call the input names: its top-level tool_use_id when that is a
      string of 1 to 128 letters, digits, `_` or `-`, which is what a file can
      be named after. Exit 1 when it names none (the hooks then fall back to
      the directory and the command).

  engine <hook input file>
      codex when the input carries turn_id, which Codex sends and Claude Code
      does not, and claude otherwise.

  said <snapshot meta file> <file holding the command the hook received>
      The --ignore-scripts line the record allows: added, asked, none,
      unstated (no line, the record does not state the fact), or unreadable
      (no line, the file is not one JSON object).

A record states a fact only as version 2 ("record": 2): ignore_scripts_injected
false (the JSON false) is "safedeps wrote none", and true with updated_command a
string is "safedeps wrote this command". Every other shape states neither: no
file, a record of another version or none (v2.17.2's false did not mean no
rewrite, and its true held no command), a string "true", a null command. That
rule is read here from the parsed record, not with the hook's jq program.
"""
import hashlib
import json
import os
import re
import subprocess
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


def record(path):
    """What a pre-guard record states: ("wrote", command), ("none", None),
    ("unstated", None) or ("unreadable", None)."""
    if not os.path.lexists(path):
        return ("unstated", None)
    meta = load(path)
    if not isinstance(meta, dict):
        return ("unreadable", None)
    version = meta.get("record")
    if isinstance(version, bool) or not isinstance(version, (int, float)) or version != 2:
        return ("unstated", None)
    injected = meta.get("ignore_scripts_injected")
    command = meta.get("updated_command")
    if injected is False:
        return ("none", None)
    if injected is True and isinstance(command, str):
        return ("wrote", command)
    return ("unstated", None)


def wrote(path):
    kind, command = record(path)
    if kind == "wrote":
        emit(command)
        return 0
    return {"none": 1, "unreadable": 3}.get(kind, 4)


def said(path, received_path):
    kind, command = record(path)
    if kind == "wrote":
        try:
            with open(received_path, "rb") as handle:
                received = handle.read()
        except OSError:
            return 3
        kind = "added" if command.encode("utf-8", "surrogatepass") == received else "asked"
    emit(kind + "\n")
    return 0


def call(path):
    data = load(path)
    value = data.get("tool_use_id") if isinstance(data, dict) else None
    if isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9_-]{1,128}", value):
        emit(value)
        return 0
    return 1


def engine(path):
    data = load(path)
    emit("codex" if isinstance(data, dict) and "turn_id" in data else "claude")
    return 0


def is_object(path):
    """0 when the file is one JSON object, 1 when it is anything else."""
    return 0 if isinstance(load(path), dict) else 1


def unread(path):
    """1 when a version 2 record says safedeps rewrote the command and an
    install in it holds a word the shell decides at run time
    (ignore_scripts_unread, the JSON true); 0 otherwise."""
    kind, _ = record(path)
    meta = load(path) if kind == "wrote" else None
    emit("1\n" if isinstance(meta, dict) and meta.get("ignore_scripts_unread") is True else "0\n")
    return 0


def process_stat(pid):
    """Independent observation for native hooks: ps, not libproc or /proc."""
    if not re.fullmatch(r'[0-9]+', pid):
        return 1
    result = subprocess.run(['ps', '-o', 'stat=', '-p', pid], capture_output=True)
    if result.returncode:
        return 1
    emit(result.stdout.strip().decode('ascii', 'strict'))
    return 0


def native_query_failure(path, pid):
    """The fixture owns this evidence, as it owns record-unread.

    A source-copy injection records its selected response before the hook;
    the hook never writes this marker. A successful/full response cannot
    justify a failure report. Do not infer an injection from hook output.
    """
    evidence = load(path)
    if not isinstance(evidence, dict) or evidence.get('pid') != pid:
        return 1
    size, returned = evidence.get('expected_bytes'), evidence.get('returned_bytes')
    if type(size) is not int or size <= 0 or type(returned) is not int:
        return 1
    return 0 if returned != size or evidence.get('returned_pid', pid) != pid else 1


def native_io_before(project, output):
    """Independent non-destructive readings while the fixture's modes apply.

    A copy opens its destination; read that permission with a non-truncating
    Python open. A recursive removal unlinks entries; read directory write
    and search permission through access(2), not the hook's unlink/rmdir walk.
    This does not predict arbitrary future I/O errors. Unobserved errors fail
    the oracle instead of being accepted because their number is nonzero.
    """
    import ctypes
    import stat
    if os.getuid() != os.geteuid() or os.geteuid() == 0:
        raise RuntimeError('native I/O oracle requires the fixture non-root uid')
    libc = ctypes.CDLL(None, use_errno=True)
    libc.access.argtypes = [ctypes.c_char_p, ctypes.c_int]
    libc.access.restype = ctypes.c_int
    errors = []
    for directory, dirs, files in os.walk(project, followlinks=False):
        dirs[:] = [name for name in dirs if name != '.git' and not os.path.islink(os.path.join(directory, name))]
        if libc.access(os.fsencode(directory), os.W_OK | os.X_OK):
            errors.append(dict(path=directory, method='directory-access', errno=ctypes.get_errno()))
        for name in files:
            path = os.path.join(directory, name)
            try:
                if not stat.S_ISREG(os.lstat(path).st_mode):
                    continue
                fd = os.open(path, os.O_WRONLY)
                os.close(fd)
            except OSError as e:
                errors.append(dict(path=path, method='open-write', errno=e.errno))
    with open(output, 'w') as f:
        json.dump(dict(project=project, uid=os.geteuid(), errors=errors), f)
    return 0


def native_io_result(evidence, action, target, outcome, source, project):
    """Check only an independently observed error at this operation's path."""
    data = load(evidence)
    if outcome == 'returned without error':
        # A no-write source copy supplies its raw return, never inferred from
        # the report. The source-copy receipt is checked before the oracle.
        proof = load(os.path.join(os.path.dirname(evidence), 'native-copy-result.json'))
        if not isinstance(proof, dict) or set(proof) != {'source', 'target', 'result'}:
            return 1
        return 0 if (action == 'copy' and proof['result']=='Ok(())'
                     and os.path.realpath(proof['source']) == os.path.realpath(source)
                     and os.path.realpath(proof['target']) == os.path.realpath(target)) else 1
    if outcome == 'returned an error without an OS code':
        try:
            refused = (os.path.islink(target) and not os.path.exists(target)) or os.path.isdir(source) or os.path.samefile(source, target)
        except OSError:
            refused = False
        return 0 if action == 'copy' and refused else 1
    match = re.fullmatch(r'returned OS error ([1-9][0-9]*)', outcome)
    if not match or not isinstance(data, dict) or data.get('uid') != os.geteuid() or not isinstance(data.get('project'),str) or os.path.realpath(data['project']) != os.path.realpath(project):
        return 1
    number = int(match[1])
    target = os.path.realpath(target)
    for fact in data.get('errors', []):
        if fact.get('errno') != number:
            continue
        path = os.path.realpath(fact['path'])
        if action == 'copy' and fact['method'] == 'open-write' and path == target:
            return 0
        if fact['method'] == 'directory-access':
            if action == 'copy' and os.path.dirname(target) == path:
                return 0
            if action == 'removal' and (os.path.dirname(target) == path or path == target or path.startswith(target + os.sep)):
                return 0
    return 1


def main():
    if sys.argv[1] == "native-io-before":
        return native_io_before(sys.argv[2], sys.argv[3])
    if sys.argv[1] == "native-io-result":
        return native_io_result(*sys.argv[2:])
    if sys.argv[1] == "process-stat":
        return process_stat(sys.argv[2])
    if sys.argv[1] == "native-query-failure":
        return native_query_failure(sys.argv[2], sys.argv[3])
    if sys.argv[1] == "object":
        return is_object(sys.argv[2])
    if sys.argv[1] == "unread":
        return unread(sys.argv[2])
    if sys.argv[1] == "string":
        return string(sys.argv[2], sys.argv[3:])
    if sys.argv[1] == "wrote":
        return wrote(sys.argv[2])
    if sys.argv[1] == "engine":
        return engine(sys.argv[2])
    if sys.argv[1] == "call":
        return call(sys.argv[2])
    if sys.argv[1] == "said":
        return said(sys.argv[2], sys.argv[3])
    if sys.argv[1] == "packages":
        packages(sys.argv[2])
        return 0
    if sys.argv[1] == "listing":
        listing(sys.argv[2])
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
