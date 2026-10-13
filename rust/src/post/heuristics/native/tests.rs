use super::*;
use std::{os::unix::fs::{symlink, PermissionsExt}, path::PathBuf, process::Command};

struct Fixture { root: PathBuf, dir: PathBuf, old: PathBuf }
impl Fixture {
    fn new() -> Self {
        let root = crate::os::scratch_dir("safedeps-native").unwrap();
        let dir = root.join(".bin"); fs::create_dir(&dir).unwrap();
        let old = root.join("bins.list");
        Self { root, dir, old }
    }
    fn check(&self) -> Inspection { scan(&self.dir,&self.old) }
    fn bin(&self, bytes: &[u8]) { fs::write(self.dir.join("candidate"),bytes).unwrap(); }
}
impl Drop for Fixture { fn drop(&mut self) { let _ = fs::remove_dir_all(&self.root); } }

#[test]
fn scripts_text_truncation_and_relative_links_are_not_native() {
    let f = Fixture::new();
    for bytes in [b"#!/usr/bin/env node\nconsole.log(42)".as_slice(),b"#!/bin/sh\nexit 42",b"#!/usr/bin/env python3\nprint(42)",
        b"executable Mach-O ELF shared object",b"",b"\x7fEL",b"\x7fELF",b"\xcf\xfa\xed\xfe",b"MZ\0\0"] {
        f.bin(bytes); assert!(matches!(f.check(),Inspection::NotNative),"{bytes:?}");
    }
    fs::write(f.root.join("cli.js"),b"#!/usr/bin/env node\nconsole.log(42)").unwrap();
    symlink("../cli.js",f.dir.join("linked")).unwrap();
    assert!(matches!(f.check(),Inspection::NotNative));
}

#[test]
fn compiled_cross_platform_images_and_fat_loader_cases() {
    let f = Fixture::new();
    let fixtures = f.root.join("images");
    let script = Path::new(env!("CARGO_MANIFEST_DIR")).join("src/post/heuristics/native/fixtures.py");
    let result = Command::new("python3").arg(script).arg(&fixtures).output().unwrap();
    assert!(result.status.success(),"{}",String::from_utf8_lossy(&result.stderr));
    for (name,format) in [("arm64.mach",Format::Mach),("x86_64.dylib",Format::Mach),("fat-junk-first",Format::Mach),
        ("hidden-arm64",Format::Mach),("fat64",Format::Mach),("elf-exec",Format::Elf),("elf-dyn",Format::Elf),("pe32",Format::Pe),("pe64-dll",Format::Pe)] {
        let target = f.dir.join("candidate"); symlink(fixtures.join(name),&target).unwrap();
        assert!(matches!(f.check(),Inspection::NativeImage(found,_) if found == format),"{name}");
        fs::remove_file(target).unwrap();
    }
    for name in ["elf.o","pe32.obj","ordinary.class","preview.class"] {
        f.bin(&fs::read(fixtures.join(name)).unwrap());
        assert!(matches!(f.check(),Inspection::NotNative),"{name}");
    }
    let original = fs::read(fixtures.join("arm64.mach")).unwrap();
    for kind in [1u32,4,10] { // object, core, dSYM
        let mut bytes = original.clone(); bytes[12..16].copy_from_slice(&kind.to_le_bytes()); f.bin(&bytes);
        assert!(matches!(f.check(),Inspection::NotNative));
    }
    f.bin(&original);
    fs::write(&f.old,b"candidate\n").unwrap();
    assert!(matches!(f.check(),Inspection::NotNative));
}

fn mach() -> Vec<u8> {
    // Synthetic envelope for arithmetic boundary tests; real positives above.
    let mut h = vec![0;40]; h[..4].copy_from_slice(&[0xcf,0xfa,0xed,0xfe]);
    for (i,n) in [(4,0x0100_000c_u32),(12,6),(16,1),(20,8)] { h[i..i+4].copy_from_slice(&n.to_le_bytes()); }
    h
}
fn fat(count: u32, wide: bool) -> Vec<u8> {
    let mut b = vec![0;32*1024+40];
    b[..4].copy_from_slice(&if wide { 0xcafebabfu32 } else { 0xcafebabeu32 }.to_be_bytes());
    b[4..8].copy_from_slice(&count.to_be_bytes());
    let start = 8+(count as usize-1)*if wide{32}else{20};
    b[start..start+4].copy_from_slice(&0x0100_000cu32.to_be_bytes());
    if wide {
        b[start+8..start+16].copy_from_slice(&32768u64.to_be_bytes());
        b[start+16..start+24].copy_from_slice(&40u64.to_be_bytes());
    } else {
        b[start+8..start+12].copy_from_slice(&32768u32.to_be_bytes());
        b[start+12..start+16].copy_from_slice(&40u32.to_be_bytes());
    }
    b[32768..].copy_from_slice(&mach()); b
}

#[test]
fn fat_profile_counts_ranges_cpu_and_budget_are_distinct() {
    let f = Fixture::new();
    for (count,wide) in [(818,false),(127,true)] {
        let b = fat(count,wide); f.bin(&b);
        assert!(matches!(f.check(),Inspection::NativeImage(Format::Mach,_)));
        let mut next = b.clone(); next[4..8].copy_from_slice(&(count+1).to_be_bytes()); f.bin(&next);
        assert!(matches!(f.check(),Inspection::NotNative));
        next[4..8].fill(255); f.bin(&next); assert!(matches!(f.check(),Inspection::NotNative));
    }
    for change in ["outside","overflow","short","cpu"] {
        let mut b = fat(1,true);
        match change {
            "outside" => b[16..24].copy_from_slice(&999999u64.to_be_bytes()),
            "overflow" => b[24..32].fill(255),
            "short" => b[24..32].copy_from_slice(&4u64.to_be_bytes()),
            _ => b[8..12].copy_from_slice(&7u32.to_be_bytes()),
        }
        f.bin(&b); assert!(matches!(f.check(),Inspection::NotNative),"{change}");
    }
    f.bin(&fat(1,false));
    let mut budget = Budget::new(); budget.bytes = TOTAL_BYTES;
    assert!(matches!(formats::inspect(&f.dir.join("candidate"),&mut budget),Err(Cause::Budget(_))));
}

#[test]
fn unreadable_candidates_and_oversize_baselines_are_incomplete() {
    let f = Fixture::new(); f.bin(b"\x7fELF"); let path = f.dir.join("candidate");
    fs::set_permissions(&path,fs::Permissions::from_mode(0o100)).unwrap();
    assert_eq!(fs::File::open(&path).unwrap_err().kind(),io::ErrorKind::PermissionDenied);
    assert!(matches!(f.check(),Inspection::Incomplete(Cause::Observed(_))));
    fs::set_permissions(&path,fs::Permissions::from_mode(0o600)).unwrap();
    fs::write(&f.old,vec![b'x';LIST_BYTES+1]).unwrap();
    assert!(matches!(f.check(),Inspection::Incomplete(Cause::Budget("directory/baseline bytes"))));
    fs::write(&f.old,b"x\n".repeat(LIST_ENTRIES+1)).unwrap();
    assert!(matches!(f.check(),Inspection::Incomplete(Cause::Budget("directory/baseline entries"))));
}

#[test]
fn directory_enumeration_cannot_grow_past_its_budget() {
    let f = Fixture::new();
    for n in 0..=LIST_ENTRIES { fs::write(f.dir.join(format!("bin-{n:05}")),b"").unwrap(); }
    assert!(matches!(f.check(),Inspection::Incomplete(Cause::Budget(_))));
}
