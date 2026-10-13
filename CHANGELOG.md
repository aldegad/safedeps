# Changelog

[한국어](CHANGELOG.ko.md)

## Unreleased

- Replaced external `file` command with a supervised core child reading coherent image headers directly (ignoring scripts and text) across up to 20 sorted `.bin` targets and symlinks for ELF, Mach-O, and PE images. Candidates are strictly read without execution, offering no loadability or safety guarantee; inspection inability triggers fail-closed rollback. Core processes now run `npm`, `curl`, `gzip`, judgment, and native-inspection child, removing `file`.
