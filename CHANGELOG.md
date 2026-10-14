# Changelog

[한국어](CHANGELOG.ko.md)

## Unreleased

- Replaced external `file` command with a supervised core child reading coherent image headers directly (ignoring scripts and text) across up to 20 sorted `.bin` targets and symlinks for ELF, Mach-O, and PE images. Candidates are strictly read without execution, offering no loadability or safety guarantee; inspection inability triggers fail-closed rollback. Core processes now run `npm`, `curl`, `gzip`, judgment, and native-inspection child, removing `file`.
- Added a second resolution with the package pinned to its own version in probe overrides for probe failures on npm before 11.6.0 caused by cyclic optional peer dependencies. The closure is judged only if a second run without the pin confirms that npm leaves the lockfile unchanged, reporting `npm_closure_resolution_failed` otherwise.
