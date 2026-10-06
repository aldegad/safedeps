//! Stamps the binary with the source it is built from and the kind of build
//! (src/stamp.rs reads both). Nothing is fetched and nothing is generated:
//! this hashes the crate's own files with the crate's own SHA-256.

#[allow(dead_code)]
#[path = "src/sha256.rs"]
mod sha256;
#[allow(dead_code)]
#[path = "src/srchash.rs"]
mod srchash;

fn main() {
    let dir = std::path::PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR"));
    // `publish` is the publish job's build, shipped without `rust/`; any
    // other build is a checkout's and is held to the checkout's source.
    let kind = match std::env::var("SAFEDEPS_CORE_BUILD_KIND") {
        Err(_) => "checkout",
        Ok(k) if k.is_empty() || k == "checkout" => "checkout",
        Ok(k) if k == "publish" => "publish",
        Ok(k) => panic!("SAFEDEPS_CORE_BUILD_KIND is `{}`; it is `checkout` or `publish`", k),
    };
    let digest = srchash::digest(&dir).expect("hash the crate's source");
    println!("cargo:rustc-env=SAFEDEPS_CORE_STAMP_KIND={}", kind);
    println!("cargo:rustc-env=SAFEDEPS_CORE_STAMP_SHA256={}", digest);
    println!("cargo:rerun-if-env-changed=SAFEDEPS_CORE_BUILD_KIND");
    for f in ["src", "Cargo.toml", "Cargo.lock", "build.rs"] {
        println!("cargo:rerun-if-changed={}", f);
    }
}
