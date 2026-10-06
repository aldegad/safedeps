//! The digest of the source a binary is built from. The build script takes
//! it when the binary is built, and a binary built in a checkout takes it
//! again when it starts as a hook: the installed hooks are links into a
//! checkout, the checkout moves, and a binary older than its source would
//! judge with rules the tree no longer holds.
//!
//! This file is compiled twice, into the crate and into `build.rs`, so it
//! names nothing of the crate but `crate::sha256`.

use std::path::Path;

/// The files that decide the binary, relative to `rust/`, in byte order:
/// `Cargo.toml`, `Cargo.lock`, `build.rs` and every `.rs` under `src/`.
pub fn files(rust_dir: &Path) -> std::io::Result<Vec<String>> {
    let mut out = vec!["Cargo.lock".to_string(), "Cargo.toml".to_string(), "build.rs".to_string()];
    let mut dirs = vec!["src".to_string()];
    while let Some(d) = dirs.pop() {
        for entry in std::fs::read_dir(rust_dir.join(&d))? {
            let entry = entry?;
            let name = match entry.file_name().into_string() {
                Ok(n) => n,
                Err(_) => return Err(std::io::Error::new(std::io::ErrorKind::InvalidData, "a source file's name is not UTF-8")),
            };
            let rel = format!("{}/{}", d, name);
            let kind = entry.file_type()?;
            if kind.is_dir() {
                dirs.push(rel);
            } else if name.ends_with(".rs") {
                out.push(rel);
            }
        }
    }
    out.sort();
    Ok(out)
}

/// SHA-256 over each file as `<path> NUL <length> NUL <bytes>`.
pub fn digest(rust_dir: &Path) -> std::io::Result<String> {
    let mut h = crate::sha256::Sha256::new();
    for rel in files(rust_dir)? {
        let bytes = std::fs::read(rust_dir.join(&rel))?;
        h.update(rel.as_bytes());
        h.update(&[0]);
        h.update(bytes.len().to_string().as_bytes());
        h.update(&[0]);
        h.update(&bytes);
    }
    Ok(h.hex())
}
