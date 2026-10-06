//! `safedeps-core post`: the PostToolUse hook (and Claude Code's
//! PostToolUseFailure). Not written yet.
//!
//! Until it is, `scripts/safedeps-post-verify.sh` is the hook, and this exits
//! 2 so that a shim pointed here early says so instead of staying silent.

pub fn main(_input: &[u8]) -> i32 {
    eprintln!("safedeps-core post: not written yet. scripts/safedeps-post-verify.sh is the PostToolUse hook.");
    2
}
