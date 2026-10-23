# Changelog

[한국어](CHANGELOG.ko.md)

## Unreleased

- Narrowed the deny after a failed reading of a command to the two cases where a reading found an install or the command's text reads as an install. A command that only names a package manager inside another word (`pipefail`) or with a manager that installs nothing (`npm run`) is now allowed, with the failure still on stderr and in `advisory.log`. An install behind a wrapper, inside a quoted script or heredoc, split by line continuations or redirections, or spelled with quotes, escapes or a path is still denied as `UNDECIDED`. The allowed message now says "does not read as an install" where it said "names no package manager", and the advisory line of a deny names which of the two answers denied it.
- Replaced external `file` command with a supervised core child reading coherent image headers directly (ignoring scripts and text) across up to 20 sorted `.bin` targets and symlinks for ELF, Mach-O, and PE images. Candidates are strictly read without execution, offering no loadability or safety guarantee; inspection inability triggers fail-closed rollback. Core processes now run `npm`, `curl`, `gzip`, judgment, and native-inspection child, removing `file`.
- Added a second resolution with the package pinned to its own version in probe overrides for probe failures on npm before 11.6.0 caused by cyclic optional peer dependencies. The closure is judged only if a second run without the pin confirms that npm leaves the lockfile unchanged, reporting `npm_closure_resolution_failed` otherwise.
