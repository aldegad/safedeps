//! Native scan-failure settlement and the discriminator used by that path.
use super::*;
use std::os::unix::ffi::OsStrExt;

#[test]
fn discriminator_covers_the_failure_census_without_shell_tools() {
    for text in ["npm install x", "NPM INSTALL x", "echo hi\npip3.11 install x", "pi\\\np install x"] {
        assert!(looks_like_install_unscanned(text.as_bytes()), "{text}");
    }
    for text in ["ls -la", "git commit -m 'fix'"] {
        assert!(!looks_like_install_unscanned(text.as_bytes()), "{text}");
    }
    let corpus = json::parse_one(include_bytes!("../../../scripts/measure/scan-failure-corpus.json")).unwrap();
    for name in ["forms", "extras"] {
        let Some(Value::Arr(forms)) = corpus.get(name) else { panic!("missing {name}") };
        assert!(!forms.is_empty());
        for text in forms {
            let Value::Str(text) = text else { panic!("non-string {name}") };
            assert!(looks_like_install_unscanned(text), "{}", String::from_utf8_lossy(text));
        }
    }
}

#[test]
fn failed_reading_reaches_the_public_undecided_settlement() {
    let path = os::scratch_dir("safedeps-reader-settlement").unwrap();
    for (command, denied) in [("pip install x", true), ("NPM INSTALL x", true), ("ls -la", false)] {
        let call = Call {
            input: json::read(b"{}"), command: command.as_bytes().to_vec(),
            guard: path.as_os_str().as_bytes().to_vec(), guard_dir: path.clone(),
        };
        let mut out = Out::default();
        assert!(!settle_scan_failure(&call, false, &mut out));
        assert!(out.stdout.is_empty() && out.stderr.is_empty());
        assert_eq!(settle_scan_failure(&call, true, &mut out), denied);
        if denied {
            let v = json::parse_one(&out.stdout).unwrap();
            let hook = v.get("hookSpecificOutput").unwrap();
            assert_eq!(hook.get("permissionDecision").unwrap().as_str(), Some("deny"));
            assert!(hook.get("permissionDecisionReason").unwrap().as_str().unwrap().contains("UNDECIDED"));
        } else {
            assert!(out.stdout.is_empty());
            assert!(String::from_utf8_lossy(&out.stderr).contains("could not be fully read"));
        }
    }
    let log = std::fs::read(path.join("advisory.log")).unwrap();
    assert!(String::from_utf8_lossy(&log).contains("pre-guard DENY"));
    assert!(String::from_utf8_lossy(&log).contains("names no package manager and was allowed"));
    std::fs::remove_dir_all(path).unwrap();
}
