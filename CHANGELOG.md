# Changelog

[한국어](CHANGELOG.ko.md)

## Unreleased

- Replaced external `file` command execution with direct header signature checks for ELF (including shared objects), Mach-O (including shared libraries and universal binaries), and Windows PE across up to 20 newly added regular files and symlink targets in `node_modules/.bin/` against the snapshot, removing the optional `file` prerequisite. This eliminates false-positive native binary detections on shebang scripts and ordinary text files containing binary keywords without executing files or performing full binary execution validation.
