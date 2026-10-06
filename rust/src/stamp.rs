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
//! same": the publish job's build is marked `publish` when it is built, and
//! only that mark skips the check. A checkout's binary that finds no source
//! does not answer.

use std::path::PathBuf;

pub const KIND: &str = env!("SAFEDEPS_CORE_STAMP_KIND");
pub const SHA256: &str = env!("SAFEDEPS_CORE_STAMP_SHA256");

pub enum Check {
    /// The publish job's build: there is no source to hold it to.
    Published,
    /// A checkout's build, and `rust/` there hashes to its stamp.
    Same,
    /// A checkout's build, and `rust/` there hashes to something else.
    Differs { dir: PathBuf, now: String },
    /// A checkout's build that cannot read a source to hold itself to.
    NoSource { why: String },
}

/// The `rust/` this binary answers for: in the nearest directory above the
/// binary, at most five up, that holds `rust/Cargo.toml`. An installed binary
/// is `<root>/bin/native/<os>-<arch>/safedeps-core`, a built one
/// `<root>/rust/target/[<target>/]release/safedeps-core`.
fn source_dir() -> Result<PathBuf, String> {
    let exe = std::env::current_exe().map_err(|e| format!("the binary's own path cannot be read ({})", e))?;
    let exe = exe.canonicalize().map_err(|e| format!("{} cannot be resolved ({})", exe.display(), e))?;
    let mut dir = exe.parent();
    for _ in 0..6 {
        let Some(d) = dir else { break };
        let rust = d.join("rust");
        if rust.join("Cargo.toml").is_file() {
            return Ok(rust);
        }
        dir = d.parent();
    }
    Err(format!("no rust/Cargo.toml in the five directories above {}", exe.display()))
}

pub fn check() -> Check {
    if KIND == "publish" {
        return Check::Published;
    }
    let dir = match source_dir() {
        Ok(d) => d,
        Err(why) => return Check::NoSource { why },
    };
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
            "safedeps: the safedeps-core binary is a checkout's build and cannot read the source it was built from: {}. Rebuild it in its checkout: scripts/build-core.sh",
            why
        )),
    }
}
