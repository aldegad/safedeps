//! Contracts migrated from the Bash source readers. These call the same Run,
//! manager tables and payload builder the native hook uses.
use super::*;

#[test]
fn payload_units_reject_missing_or_out_of_bounds_bytes() {
    let core = Core::new();
    for (units, expected, failed) in [
        (vec!["1:3"], b"abc".as_slice(), false),
        (vec!["2:1", "#65#37#92"], b"bA%\\".as_slice(), false),
        (vec!["1:1", "zz"], b"a".as_slice(), true),
        (vec!["2:3"], b"".as_slice(), true),
        (vec!["0:1"], b"".as_slice(), true),
        (vec!["1:0"], b"".as_slice(), true),
        (vec!["#0"], b"".as_slice(), true),
        (vec!["#128"], b"".as_slice(), true),
        (vec!["#65##66"], b"".as_slice(), true),
        (vec!["#65#"], b"".as_slice(), true),
        (vec!["#"], b"".as_slice(), true),
        (vec!["#065"], b"".as_slice(), true),
    ] {
        let mut run = Run::new(&core);
        let words: Vec<W> = units.iter().map(|s| s.as_bytes().to_vec()).collect();
        assert_eq!(run.payload_build(b"abc", &words), expected, "{units:?}");
        assert_eq!(run.failed, failed, "{units:?}");
    }
}

#[test]
fn recursive_payloads_reach_substitutions_and_bound_their_depth() {
    let core = Core::new();
    for reading in [Reading::Bash, Reading::Zsh, Reading::Dash] {
        let mut run = Run::new(&core);
        run.reading = Some(reading);
        let texts = run.raw_texts(b"sh -c 'x=$(pip i)'");
        assert!(texts.contains(&b"x=$(pip i)".to_vec()));
        assert!(texts.contains(&b"pip i".to_vec()));
        assert!(!run.failed);
        let deep = b"eval eval eval eval eval 'x=$(pip i)'";
        let texts = run.raw_texts(deep);
        assert!(!texts.is_empty());
        assert!(!run.failed);
        assert!(!run.candidate_texts(deep).is_empty());
        // Substitutions can be found in an outer payload as well. Hold the
        // recursion limit with plain eval words, without that second route.
        let deep = b"eval eval eval eval eval pwd";
        let mut scripts = Vec::new();
        run.read_payload_scripts(deep, b'E', 3, &mut scripts);
        assert_eq!(scripts, vec![b"eval eval eval eval pwd".to_vec()]);
        scripts.clear();
        run.read_payload_scripts(deep, b'E', 0, &mut scripts);
        assert_eq!(scripts, ["eval eval eval eval pwd", "eval eval eval pwd",
                            "eval eval pwd", "eval pwd"].map(|s| s.as_bytes().to_vec()));
        assert!(!run.failed);
    }
}

#[test]
fn missing_reading_invalid_view_and_statement_failure_remain_failures() {
    let core = Core::new();
    let mut run = Run::new(&core);
    assert!(run.lex(b"pip install x", "scan").is_none());
    assert!(run.failed);
    let mut run = Run::new(&core);
    run.reading = Some(Reading::Bash);
    assert!(run.lex(b"pip install x", "view-of-no-kind").is_none());
    assert!(run.failed);
    let mut run = Run::new(&core);
    assert!(run.pieces(b"pip install x").is_none());
    assert!(run.failed);
    let facts = run.facts(b"pip install evil==6.6.6");
    assert!(facts.records.iter().any(|(k,v)| k == "failed.facts" && v == b"true"));
    assert!(run.reading.is_none(), "the facts driver clears its reading");
}

#[test]
fn readings_and_views_do_not_reuse_another_commands_bytes() {
    // Native Run has no Bash checksum/disk memo. Reusing one Run must still
    // honor its current text, reading and view, including side effects.
    let core = Core::new();
    let mut run = Run::new(&core);
    for _ in 0..2 {
        run.reading = Some(Reading::Bash);
        assert_eq!(run.lex(b"echo 'x'", "scan").unwrap(), b"echo    ");
        assert_eq!(run.lex(b"echo 'y'", "code").unwrap(), b"echo 'y'");
        let text = b"echo a &>f pip i; pip i &>g";
        let bash = run.statements(text);
        run.reading = Some(Reading::Dash);
        let dash = run.statements(text);
        assert_eq!(bash.iter().filter(|&&b| b == b'\n').count(), 2);
        assert_eq!(dash.iter().filter(|&&b| b == b'\n').count(), 4);
        run.reading = Some(Reading::Bash);
        run.diverge = false;
        run.lex(text, "scan").unwrap();
        assert!(run.diverge);
    }
}

#[test]
fn multiline_statement_ecosystems_have_fixed_expectations() {
    let core = Core::new();
    for reading in [Reading::Bash, Reading::Zsh, Reading::Dash] {
        let rows = crate::json::parse_one(include_bytes!("../../../scripts/test/lib/reader-ecosystems.json")).unwrap();
        let crate::json::Value::Arr(rows) = rows else { panic!("expected ecosystem cases") };
        for row in rows {
            let text = row.get("command").unwrap().as_str().unwrap();
            let expected = row.get("ecosystem").unwrap().as_str().unwrap();
            let mut run = Run::new(&core);
            run.reading = Some(reading);
            assert_eq!(run.detect_ecosystem(text.as_bytes()), expected, "{text:?}");
            assert!(!run.failed, "{text:?}");
        }
    }
}

#[test]
fn recognition_keeps_multiline_and_non_utf8_bytes() {
    let core = Core::new();
    let run = Run::new(&core);
    for text in [b"npm install x\xe9".as_slice(), b"echo \xe9; npm install x",
                 b"pip install \xe2\x84\xaaafka==1", b"npm install x\nnpm ci"] {
        assert!(run.recognized(text), "{text:?}");
    }
    for text in [b"npm \xc4\xb1nstall x".as_slice(), b"npm in\xc5\xbftall x", b"\xff\xfe", b"", b" ", b"echo a\n"] {
        assert!(!run.recognized(text), "{text:?}");
    }
}

#[test]
fn manager_pipe_and_shell_names_agree_on_case_and_boundaries() {
    let core = Core::new();
    let ex = Regex::new(&format!("^({})$", grammar::EXECUTABLES), true).unwrap();
    let pipe = Regex::new(&format!("^{PIPE_MANAGER_RE}$"), true).unwrap();
    let install_body = grammar::patterns().install_body.replace('\\', "");
    for name in ["npm","npx","pnpm","pnpx","yarn","bun","bunx","pip","pip3","pip3.11",
                 "poetry","uv","uvx","pipx","pipenv","cargo","go","gem","bundle","mvn","dotnet","PIP","Npm"] {
        assert!(ex.is_match(name.as_bytes()), "{name}");
        assert!(pipe.is_match(name.as_bytes()), "{name}");
        let body_name = Regex::new(&format!("(^|[^[:alnum:]]){name}([^[:alnum:]]|$)"), true).unwrap();
        assert!(body_name.is_match(install_body.as_bytes())
                || name.starts_with("pip3") || name == "PIP" || name == "Npm",
                "{name} has an install body");
        let mut run = Run::new(&core);
        run.reading = Some(Reading::Bash);
        assert!(run.pipes_install_to_shell(format!("printf '{name} install x' | sh").as_bytes()), "{name}");
    }
    for name in ["npm.cmd","pipx-foo","pips","gox"] {
        assert!(!ex.is_match(name.as_bytes()), "{name}");
    }
    let shells = Regex::new(&format!("^({})$", grammar::SHELLS), false).unwrap();
    for name in ["sh","bash","dash","ksh","mksh","yash","posh","zsh","csh","tcsh","fish"] {
        assert!(shells.is_match(name.as_bytes()), "{name}");
    }
    for name in ["ssh","sshd","bash5","shx"] {
        assert!(!shells.is_match(name.as_bytes()), "{name}");
    }
}

#[test]
fn native_manager_value_entries_are_reachable_and_unambiguous() {
    use std::collections::BTreeSet;
    let mut keys = BTreeSet::new();
    for entry in crate::tables::VALUE_OPTIONS.split_whitespace() {
        let (key, class) = entry.rsplit_once('=').unwrap();
        assert!(keys.insert(key), "duplicate {key}");
        let (family, scoped) = key.split_once('/').unwrap();
        let (scope, option) = scoped.split_once(':').unwrap();
        assert_eq!(manager::option_class(family, if scope == "*" {""} else {scope}, option.as_bytes()), class.bytes().next(), "{entry}");
        if scope != "*" {
            assert!(manager::command(family, scope.as_bytes()).is_some(), "{entry}");
            assert!(!crate::tables::VALUE_OPTIONS.contains(&format!(" {family}/*:{option}=")), "{entry}");
        }
    }
    // The concrete regression the mutable zz fixture was intended to guard:
    // bun x -p names a package; bun's runtime -p is outside this value table.
    assert_eq!(manager::option_class("bun", "x", b"-p"), Some(b'p'));
    assert_eq!(manager::option_class("bun", "", b"-p"), None);
}

#[test]
fn runner_only_holds_node_runners_and_nothing_beside_them() {
    let core = Core::new();
    // Every statement is a runner or an inert builtin read as written.
    let runners = [
        "npx --no-install tsc --noEmit x", "npx vitest run x", "npm exec -- vitest run x", "npm x vitest",
        "pnpx vitest", "pnpm dlx vitest run x", "yarn dlx vitest run x", "bunx vitest run x", "bun x vitest run x",
        "npx -p @scope/tool@2 tool run", "cd sub && npx tsc", "cd /a/b-c && npx --no-install tsc --noEmit",
        "echo --- && npx vitest run x", "\"cd\" sub; npx tsc", "export CI=1 NODE_ENV=test && npx vitest run x",
        "test -d node_modules && npx tsc", "[ -d node_modules ] && npx tsc", "true; : ; npx tsc", "printf x; npx tsc",
        "npx tsc || true", "npx tsc && echo OK", "npx tsc 2>/dev/null", "# check\nnpx tsc", "FOO=1 npx tsc",
    ];
    // A statement that is neither keeps the call judged, whatever it is.
    let judged = [
        "yarn add fixture-tool@1.0.0", "pnpm add fixture-tool@1.0.0", "bun add fixture-tool@1.0.0",
        "npm install fixture-tool@1.0.0", "npx vitest run x && yarn add fixture-tool@1.0.0",
        "npx tsc; pip install requests==2.0.0", "npx yarn add x", "npx yarn@1.22.0 add x",
        "npx -p yarn yarn add x", "pnpm dlx --package=yarn yarn add x", "npx corepack yarn add x",
        "npx ./node_modules/.bin/pnpm add x", "npx -c 'yarn add x' fixture", "pnpm dlx -c 'yarn add x'",
        "npx $TOOL add x", "npx bash script.sh", "uvx ruff check", "pipx run black", "npm init vite@5", "echo hi",
        // unread installs beside a runner
        "yarn && npx fixture-tool@1.0.0", "npx fixture-tool@1.0.0; \"yarn\" add fixture-tool@1.0.0",
        "npx fixture-tool@1.0.0; sudo yarn add fixture-tool@1.0.0", "npx tsc; timeout 60 yarn add x",
        "npx tsc; corepack yarn add x", "npx tsc; y\\arn add x",
        // any other program, a shell, a group, an assignment
        "make && npx tsc", "npx tsc | head -1", "npx tsc; node --check x.js", "bash -c 'npx tsc'",
        "x=$(npx tsc --version)", "X=1; npx tsc", "(cd sub && npx tsc)", "{ cd sub; npx tsc; }",
        "if true; then npx tsc; fi", "npx tsc; source ./x.sh", "npx tsc; exit 0",
        // a builtin with a prefix, a redirection, a comment or a word the shell decides
        "X=1 cd sub && npx tsc", "command cd sub && npx tsc", "env echo x; npx tsc", "echo x > out; npx tsc",
        "cd sub # go\nnpx tsc", "echo $HOME && npx tsc", "echo $(yarn add x) && npx tsc", "cd ~ && npx tsc",
        "test -v 'a[$(yarn add x)]' && npx tsc", "printf -v 'a[$(yarn add x)]' x; npx tsc", "echo \"\" && npx tsc",
        "export X && npx tsc", "export -n X && npx tsc", "export PATH=/x:$PATH && npx tsc",
        // a text the payload walk does not go into
        "npx a $(npx b $(npx c $(npx d $(npx e $(yarn add x)))))",
    ];
    for reading in [Reading::Bash, Reading::Zsh, Reading::Dash] {
        for cmd in runners {
            let mut run = Run::new(&core);
            run.reading = Some(reading);
            assert!(run.runner_only(cmd.as_bytes()), "{reading:?}: {cmd}");
            assert!(!run.failed, "{reading:?}: {cmd}");
        }
        for cmd in judged {
            let mut run = Run::new(&core);
            run.reading = Some(reading);
            assert!(!run.runner_only(cmd.as_bytes()), "{reading:?}: {cmd}");
        }
        // dash has no pushd or popd builtin and looks them up on PATH.
        let mut run = Run::new(&core);
        run.reading = Some(reading);
        assert_eq!(run.runner_only(b"pushd sub && npx tsc && popd"), reading != Reading::Dash, "{reading:?}");
    }
}
