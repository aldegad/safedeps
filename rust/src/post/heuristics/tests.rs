use super::*;
use std::os::unix::fs::{symlink, PermissionsExt};

struct Fixture { root: std::path::PathBuf, store: Store }
impl Fixture {
    fn new() -> Self {
        let root = crate::os::scratch_dir("safedeps-native-bins").unwrap();
        let store = Store::new(root.join("state"), root.join("project"), b"before".to_vec());
        fs::create_dir_all(store.home.join("snapshots")).unwrap();
        fs::create_dir_all(store.project.join("node_modules/.bin")).unwrap();
        Self { root, store }
    }
    fn bin(&self, name: &str, bytes: &[u8]) {
        let path = self.store.project.join("node_modules/.bin").join(name);
        fs::write(&path, bytes).unwrap();
        fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
    }
    fn reasons(&self) -> Vec<W> {
        let mut reasons = Vec::new();
        binaries(&self.store, &mut reasons);
        reasons
    }
    fn native(&self, name: &str) {
        assert_eq!(self.reasons(), vec![format!("Native binary '{}' found in node_modules/.bin", name).into_bytes()]);
    }
}
impl Drop for Fixture { fn drop(&mut self) { fs::remove_dir_all(&self.root).unwrap(); } }

#[test]
fn scripts_and_script_symlinks_have_no_native_reason() {
    let f = Fixture::new();
    for (name, bytes) in [
        ("node-cli", b"#!/usr/bin/env node\nconsole.log('ok');\n".as_slice()),
        ("shell-cli", b"#!/bin/sh\nprintf 'ok\\n'\n"),
        ("python-cli", b"#!/usr/bin/env python3\nprint('ok')\n"),
        ("executable-Mach-O-ELF", b"plain text\n"),
        ("empty", b""), ("short", b"\x7fEL"),
    ] { f.bin(name, bytes); }
    let package = f.store.project.join("node_modules/fixture-cli/dist");
    fs::create_dir_all(&package).unwrap();
    fs::write(package.join("cli.js"), b"#!/usr/bin/env node\nconsole.log('fixture');\n").unwrap();
    fs::set_permissions(package.join("cli.js"), fs::Permissions::from_mode(0o755)).unwrap();
    symlink("../fixture-cli/dist/cli.js", f.store.project.join("node_modules/.bin/fixture-cli")).unwrap();
    assert_eq!(f.reasons(), Vec::<W>::new());
}

#[test]
fn native_headers_are_detected_independent_of_host_file_classifier() {
    for magic in [*b"\x7fELF", [0xfe,0xed,0xfa,0xce], [0xce,0xfa,0xed,0xfe],
        [0xfe,0xed,0xfa,0xcf], [0xcf,0xfa,0xed,0xfe]] {
        let f = Fixture::new();
        let mut header = [0u8; 64];
        header[..4].copy_from_slice(&magic);
        f.bin("native", &header);
        f.native("native");
    }
}

#[test]
fn host_native_binary_symlink_and_snapshot_filter() {
    let f = Fixture::new();
    let target = f.store.project.join("node_modules/fixture-native");
    fs::copy("/bin/echo", &target).unwrap();
    symlink("../fixture-native", f.store.project.join("node_modules/.bin/native")).unwrap();
    f.native("native");
    fs::write(f.store.path(&f.store.id, b"bins.list"), b"native\n").unwrap();
    assert!(f.reasons().is_empty());
}

#[test]
fn universal_mach_o_requires_a_mach_o_slice_and_pe_requires_its_signature() {
    for (magic, little, wide) in [
        ([0xca,0xfe,0xba,0xbe], false, false), ([0xbe,0xba,0xfe,0xca], true, false),
        ([0xca,0xfe,0xba,0xbf], false, true), ([0xbf,0xba,0xfe,0xca], true, true),
    ] {
        let f = Fixture::new();
        let mut bytes = [0u8; 128];
        bytes[..4].copy_from_slice(&magic);
        bytes[4..8].copy_from_slice(&if little { 1u32.to_le_bytes() } else { 1u32.to_be_bytes() });
        if wide {
            bytes[16..24].copy_from_slice(&if little { 64u64.to_le_bytes() } else { 64u64.to_be_bytes() });
        } else {
            bytes[16..20].copy_from_slice(&if little { 64u32.to_le_bytes() } else { 64u32.to_be_bytes() });
        }
        bytes[64..68].copy_from_slice(&[0xcf,0xfa,0xed,0xfe]);
        f.bin("universal native", &bytes);
        f.native("universal native");
        bytes[64..68].copy_from_slice(b"text");
        f.bin("universal native", &bytes);
        assert!(f.reasons().is_empty());
    }
    let f = Fixture::new();
    f.bin("java-class", &[0xca,0xfe,0xba,0xbe,0,0,0,65,0,1,0,0]);
    assert!(f.reasons().is_empty());
    let mut pe = [0u8; 128];
    pe[..2].copy_from_slice(b"MZ");
    pe[0x3c..0x40].copy_from_slice(&64u32.to_le_bytes());
    pe[64..68].copy_from_slice(b"PE\0\0");
    f.bin("windows", &pe);
    f.native("windows");
    pe[64..68].copy_from_slice(b"text");
    f.bin("windows", &pe);
    assert!(f.reasons().is_empty());
}
