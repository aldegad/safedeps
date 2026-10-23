//! Native scan-failure settlement and the discriminator used by that path.
use super::*;
use std::os::unix::ffi::OsStrExt;

/// A failed reading the core makes today: the textual script search takes the
/// argument after `eval` for a script, and an arrow function in it does not
/// read as one. The rows below put it beside each command so the public hook
/// settles a reading that really failed.
const FAILS: &str = "browser-cli eval --expr '(()=>1)()'";

/// Commands that name a package manager and install nothing, in the shapes of
/// commands an agent sends a browser or a script. A name stands inside another
/// word, in an identifier, a path, a file name or a package name, or the
/// manager runs something other than an install.
const NOT_INSTALLS: &[&str] = &[
    "browser-cli eval --expr '(()=>{const a=[...document.querySelectorAll(\"a\")].find(x=>x.innerText.trim()===\"Google\"); a.click(); return 1})()'",
    "browser-cli eval --tab 7 --expr 'location.href + \"\\n\" + document.title + \"\\n\\n\" + (document.querySelector(\"#cargo-list\")||document.body).innerText.slice(0, 3000)'",
    "D=/tmp/work; browser-cli eval --expr \"$(cat $D/pypi-probe.js)\" > $D/out.json; browser-cli eval --expr '(()=>document.title)()'",
    "browser-cli eval --expr '(()=>{const gem=document.querySelector(\".gem\"); return gem.className})()'",
    "browser-cli eval --expr '(()=>{const pkgs=[\"@oven/bun-darwin-aarch64\",\"gopd\"]; return pkgs.join(\" \")})()'",
    "browser-cli eval --expr '(()=>1)()' | python3 -c 'import sys,json; print(json.load(sys.stdin))'",
    "python3 - <<'PY'\nimport json\nprint(json.dumps({\"category_srl\": 1}))\nPY\nbrowser-cli eval --expr '(()=>1)()'",
    "python3 tools/page.py eval '(document.body.innerText.slice(0, 3000))' > raw/page.json; head -c 300 raw/page.json",
    "set -euo pipefail; cd ~/src/algorithms && browser-cli eval --expr '(()=>1)()'",
    "browser-cli eval --expr '(()=>1)()'; grep -c 'ecosystem=npm package=wrappy version=1.0.2' state/advisory.log",
    "browser-cli eval --expr '(()=>1)()'; npm run build && npm test && go test ./... && cargo build --release",
    "browser-cli eval --expr '(()=>1)()'; pip --version; python3 -m pytest -q; node -e 'const gem = 1'",
    "browser-cli eval --expr '(()=>1)()'; echo npm",
];

/// Installs the text shows without a reading: behind a wrapper or an
/// assignment, inside a quoted script, a substitution, a heredoc body or a
/// group, split by a line continuation or a redirection, quoted or escaped,
/// spelled with a path, and written with the escapes printf and `$'...'`
/// expand.
const INSTALLS: &[&str] = &[
    "npm install left-pad@1.3.0",
    "pip install requests==2.0.0",
    "cargo add serde@1.0.0",
    "bash -c 'npm i left-pad@1.3.0'",
    "sudo -u root npm install x",
    "timeout 5 pip install x",
    "nohup cargo add x",
    "nice -n 5 go get example.com/x",
    "xargs npm install",
    "env -i PATH=/bin npm i x",
    "FOO=\"a b\" npm i x",
    "ssh host 'npm i x'",
    "sh -c \"cd /tmp && pip install x\"",
    "bash <<EOF\nnpm install x\nEOF",
    "cat <<'EOF' | sh\ngo get example.com/x\nEOF",
    "npm \\\ninstall x",
    "echo $(npm i x)",
    "echo `npm i x`",
    "(cd x && npm ci)",
    "{ npm ci; }",
    "if true; then npm i x; fi",
    "/usr/local/bin/npm i x",
    "./node_modules/.bin/pnpm add x",
    "$HOME/.cargo/bin/cargo install x",
    "\"npm\" install x",
    "\\npm install x",
    "n''pm install x",
    "pip>/dev/null install x",
    "npm 2>&1 install x",
    "printf 'echo a\\npip install x' | sh",
    "printf 'echo a\\012pip install x' | sh",
    "$'\\x6e\\x70\\x6d' install x",
    "NPM INSTALL x",
];

/// Each row of `NOT_INSTALLS` is a reading that fails, finds no install and
/// names a manager's executable, which the test this one replaced denied.
#[test]
fn not_installs_are_failed_readings_that_name_a_manager() {
    let core = crate::core::Core::new();
    let named = Regex::new(&format!("({})", grammar::EXECUTABLES), true).unwrap();
    for text in NOT_INSTALLS.iter().chain([&FAILS]) {
        let mut run = Run::new(&core);
        let read = readings::Readings::collect(&mut run, text.as_bytes(), b"/");
        assert!(run.failed, "the reading did not fail: {text}");
        assert!(!read.yes("any_install"), "{text}");
        assert!(named.is_match(text.as_bytes()) || *text == FAILS, "{text}");
    }
}

#[test]
fn discriminator_reads_installs_and_not_names() {
    for text in INSTALLS {
        assert!(looks_like_install_unscanned(text.as_bytes()), "{text}");
        assert!(looks_like_install_unscanned(format!("{FAILS}; {text}").as_bytes()), "{text}");
    }
    for text in NOT_INSTALLS {
        assert!(!looks_like_install_unscanned(text.as_bytes()), "{text}");
    }
    for text in ["ls -la", "git commit -m 'fix'", "echo \"pipe the pipefail\"", "go version", "python3 -c 'print(1)'"] {
        assert!(!looks_like_install_unscanned(text.as_bytes()), "{text}");
    }
}

#[test]
fn discriminator_covers_the_failure_census_without_shell_tools() {
    let corpus = json::parse_one(include_bytes!("../../../scripts/measure/scan-failure-corpus.json")).unwrap();
    let list = |name: &str| match corpus.get(name) {
        Some(Value::Arr(items)) if !items.is_empty() => items.iter().map(|v| match v {
            Value::Str(s) => s.clone(),
            _ => panic!("non-string {name}"),
        }).collect::<Vec<_>>(),
        _ => panic!("missing {name}"),
    };
    let wrappers = list("wrappers");
    for form in list("forms") {
        for wrapper in &wrappers {
            let mut text = W::new();
            let at = wrapper.windows(2).position(|w| w == b"{}").expect("wrapper without {}");
            text.extend_from_slice(&wrapper[..at]);
            text.extend_from_slice(&form);
            text.extend_from_slice(&wrapper[at + 2..]);
            assert!(looks_like_install_unscanned(&text), "{}", String::from_utf8_lossy(&text));
        }
    }
    for text in list("extras") {
        assert!(looks_like_install_unscanned(&text), "{}", String::from_utf8_lossy(&text));
    }
    // The controls install nothing when read. Two of them quote an install,
    // and with no reading a quoted install is one: the text cannot tell a
    // script handed to a shell from a message.
    let quoted: [&[u8]; 2] = [b"echo \"npm install evil@1.0.0\"", b"git commit -m 'bump npm i x'"];
    for text in list("controls") {
        assert_eq!(looks_like_install_unscanned(&text), quoted.contains(&text.as_slice()), "{}", String::from_utf8_lossy(&text));
    }
}

#[test]
fn failed_reading_reaches_the_public_undecided_settlement() {
    let path = os::scratch_dir("safedeps-reader-settlement").unwrap();
    for (command, found, denied) in [
        ("pip install x", false, true),
        ("NPM INSTALL x", false, true),
        ("ls -la", false, false),
        ("echo npm; python3 -c 'print(1)'", false, false),
        ("echo npm", true, true),
    ] {
        let call = Call {
            input: json::read(b"{}"), command: command.as_bytes().to_vec(),
            guard: path.as_os_str().as_bytes().to_vec(), guard_dir: path.clone(),
        };
        let mut out = Out::default();
        assert!(!settle_scan_failure(&call, false, found, &mut out));
        assert!(out.stdout.is_empty() && out.stderr.is_empty());
        assert_eq!(settle_scan_failure(&call, true, found, &mut out), denied, "{command}");
        if denied {
            let v = json::parse_one(&out.stdout).unwrap();
            let hook = v.get("hookSpecificOutput").unwrap();
            assert_eq!(hook.get("permissionDecision").unwrap().as_str(), Some("deny"));
            let reason = hook.get("permissionDecisionReason").unwrap().as_str().unwrap();
            assert!(reason.contains("UNDECIDED"));
            assert!(reason.contains("could not finish reading this command"));
            assert!(reason.contains("could not tell whether the command installs a dependency or what it would install"));
            assert!(reason.contains("blocked fail-closed, and no finding is claimed"));
        } else {
            assert!(out.stdout.is_empty());
            assert!(String::from_utf8_lossy(&out.stderr).contains("could not be fully read"));
            assert!(String::from_utf8_lossy(&out.stderr).contains("does not read as a dependency install"));
        }
    }
    let log = String::from_utf8_lossy(&std::fs::read(path.join("advisory.log")).unwrap()).into_owned();
    assert!(log.contains("pre-guard DENY: the command scanner failed (the command reads as an install)"));
    assert!(log.contains("pre-guard DENY: the command scanner failed (a reading found an install)"));
    assert!(log.contains("does not read as an install and was allowed"));
    std::fs::remove_dir_all(path).unwrap();
}
