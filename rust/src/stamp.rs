//! What this binary was built from, and whether that is still the source
//! beside it.
//!
//! No binary is committed: the publish job builds the ones a package
//! carries, and a checkout builds its own (`scripts/build-core.sh`). The
//! installed hooks are links into a checkout, so when the checkout moves the
//! hook's source moves with it and the binary does not. A hook that starts
//! as a checkout's binary therefore hashes `rust/` again and answers only
//! when the digest is the one it was built with.
//!
//! A package holds no `rust/`, and a missing source must not read as "the
//! same": the publish job's build is marked `publish` when it is built. Only
//! a marked binary in the package layout with no own `rust/` skips the check.
//! A publish binary beside source checks it too. A checkout's binary that
//! finds no source does not answer.

use std::{io, path::{Path, PathBuf}};

pub const KIND: &str = env!("SAFEDEPS_CORE_STAMP_KIND");
pub const SHA256: &str = env!("SAFEDEPS_CORE_STAMP_SHA256");

pub enum Check {
    /// A publish build in a package whose own source directory is absent.
    Published,
    /// The binary's own `rust/` hashes to its stamp.
    Same,
    /// The binary's own `rust/` hashes to something else.
    Differs { dir: PathBuf, now: String },
    /// The required source or the binary's placement cannot be read.
    NoSource { why: String },
}

/// Resolve placement, not source existence. Looking upwards for Cargo.toml
/// would mistake an enclosing project's source for an installed package's.
/// The bool identifies the package layout, where publish may omit source.
fn source_at(exe: &Path) -> Result<(PathBuf, bool), String> {
    let dir = exe.parent().ok_or_else(|| format!("{} has no parent directory", exe.display()))?;
    if let Some(native) = dir.parent().filter(|p| p.file_name().is_some_and(|n| n == "native")) {
        if let Some(bin) = native.parent().filter(|p| p.file_name().is_some_and(|n| n == "bin")) {
            if let Some(root) = bin.parent() { return Ok((root.join("rust"), true)); }
        }
    }
    // A normal cargo build has either target/<profile> or
    // target/<triple>/<profile>. These are exact shapes, never a search.
    if dir.file_name().is_some_and(|n| n == "release" || n == "debug") {
        if let Some(parent) = dir.parent() {
            let target = if parent.file_name().is_some_and(|n| n == "target") { Some(parent) }
                else { parent.parent().filter(|p| p.file_name().is_some_and(|n| n == "target")) };
            if let Some(rust) = target.and_then(Path::parent).filter(|p| p.file_name().is_some_and(|n| n == "rust")) {
                return Ok((rust.to_path_buf(), false));
            }
        }
    }
    // A directly placed probe/development binary can read source beside it,
    // but an unfamiliar layout never earns the source-free package exemption.
    Ok((dir.join("rust"), false))
}

fn source_dir() -> Result<(PathBuf, bool), String> {
    let exe = std::env::current_exe().map_err(|e| format!("the binary's own path cannot be read ({})", e))?;
    let exe = exe.canonicalize().map_err(|e| format!("{} cannot be resolved ({})", exe.display(), e))?;
    source_at(&exe)
}

/// The package that owns this executable, using the same placement rule as
/// the source stamp. The hook uses its CLI path in an approval prescription.
pub fn package_root() -> Result<PathBuf, String> {
    let (source, _) = source_dir()?;
    source.parent().map(Path::to_path_buf).ok_or_else(|| "the binary's package has no root".into())
}

pub fn check() -> Check {
    let (dir, packaged) = match source_dir() {
        Ok(d) => d,
        Err(why) => return Check::NoSource { why },
    };
    // lstat distinguishes absence from an unreadable or dangling source
    // link. is_dir/is_file would turn those failures into a publish pass.
    match std::fs::symlink_metadata(&dir) {
        Err(e) if e.kind() == io::ErrorKind::NotFound && packaged && KIND == "publish" => return Check::Published,
        Err(e) => return Check::NoSource { why: format!("{} cannot be read ({})", dir.display(), e) },
        Ok(_) => {}
    }
    match crate::srchash::digest(&dir) {
        Ok(now) if now == SHA256 => Check::Same,
        Ok(now) => Check::Differs { dir, now },
        Err(e) => Check::NoSource { why: format!("{} cannot be read ({})", dir.display(), e) },
    }
}

/// None when the binary may answer; otherwise the sentence that says why it
/// does not, for the hook's deny.
pub fn refusal() -> Option<String> {
    match check() {
        Check::Published | Check::Same => None,
        Check::Differs { dir, now } => Some(format!(
            "safedeps: the safedeps-core binary was built from another source than the one beside it. It was built from source digest {}, and {} now hashes to {}. Rebuild it: scripts/build-core.sh",
            SHA256,
            dir.display(),
            now
        )),
        Check::NoSource { why } => Some(format!(
            "safedeps: the safedeps-core binary cannot read the source beside it: {}. Rebuild it in its checkout: scripts/build-core.sh",
            why
        )),
    }
}
