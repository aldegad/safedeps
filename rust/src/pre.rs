//! `safedeps-core pre`: the PreToolUse hook. Not written yet.
//!
//! Until it is, `scripts/safedeps-pre-guard.sh` is the hook, and this exits 2
//! so that a shim pointed here early blocks instead of passing.

pub fn main(_input: &[u8]) -> i32 {
    eprintln!("safedeps-core pre: not written yet. scripts/safedeps-pre-guard.sh is the PreToolUse hook.");
    2
}
