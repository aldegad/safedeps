//! Native scan-failure settlement and the discriminator used by that path.
use super::*;
use super::unscanned::{escapes_expanded, BRACE_BYTES, UNSCANNED_DEPTH, UNSCANNED_VIEWS};
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
    "browser-cli eval --expr '(()=>1)()'; ./mynpm install x && ./algo install",
    "browser-cli eval --expr '(()=>1)()'; BUILD_TARGET=$TARGET python3 tools/build.py && python3 $D/crop.py in.png out.png",
];

/// Installs the text shows without a reading: behind a wrapper or an
/// assignment, inside a quoted script, a substitution, a heredoc body or a
/// group, split by a line continuation, a redirection or a zsh glob
/// qualifier, quoted or escaped, spelled with a path, written with the
/// escapes printf and `$'...'` expand, and a manager beside a script decided
/// at run time.
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
    "printf 'mvn x:maven-dependency-plugin\\0723.6.0:get' | sh",
    "printf 'pip3\\05612 install x' | sh",
    "printf '\\560ip install x' | sh",
    "echo -e '\\0560ip install x' | sh",
    "$'\\560ip' install x",
    "NPM INSTALL x",
    "pip(N) install evil==1.0.0",
    "pip ((x) y) install evil==1.0.0",
    "env -S \"$X\" pip",
];

/// Installs that only two or more of the rewrites read together: an escape
/// and a redirection, a group and a redirection, an escape that makes a
/// group, a redirection or a line continuation, a continuation beside a
/// redirection or a group, quotes that split an escape or open a `$'...'`
/// inside a word, a quoted or substituted redirection target, an escape
/// expanded twice, and three at once.
const COMPOSED_INSTALLS: &[&str] = &[
    r"$'\x70ip'>/dev/null install sample==1.0.0",
    r"printf '\x70ip>/dev/null install sample==1.0.0' | sh",
    "pip(N)>/dev/null install sample==1.0.0",
    r"$'\x70ip'(N) install x",
    r"printf 'pip\x28N\x29 install x' | sh",
    r"printf 'pip\x3e/dev/null install x' | sh",
    r"printf 'pip\076/dev/null install x' | sh",
    r"printf 'pi\\\np install x' | sh",
    "pi\\\np>/dev/null install x",
    "pi\\\np(N) install x",
    r#"printf '\''x70ip install x' | sh"#,
    r"p$'\x69'p install x",
    "pip>'a b' install x",
    "pip 2>\"$(mktemp)\" install x",
    "pip>`mktemp` install x",
    "pip>$(mktemp) install x",
    "pip>a\\ b install x",
    r"echo -e '\0160ip install x' | sh",
    r"printf '\\x70ip install x' | xargs -0 printf | sh",
    "$'\\x70'\\\nip>/dev/null install x",
    "pip(N)\\\n2>&1 install x",
    r#"sh -c "$(printf '\x70ip(N)>/dev/null install x')""#,
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
    for text in ["ls -la", "git commit -m 'fix'", "echo \"pipe the pipefail\"", "go version", "python3 -c 'print(1)'", "env -S \"$X\""] {
        assert!(!looks_like_install_unscanned(text.as_bytes()), "{text}");
    }
}

/// The heads and the redirection targets a validator put together into
/// installs after a reading that fails, each head before each target: an
/// escape, a split or quoted name, and a glob qualifier, in front of a target
/// that is quoted, substituted, escaped, or holds a parenthesis inside quotes
/// that a count of parentheses takes for a close or an open.
const COMPOSED_HEADS: &[&str] = &[r"$'\x70'ip", r"p$'\151'p", "p\\\nip", r"'p'\i'p'", r"$'\160'ip(N)"];
const COMPOSED_TARGETS: &[&str] = &[
    "/dev/null",
    "'a b'",
    r#""${TMPDIR:-/tmp}/a b""#,
    r#"$(printf "%s" /dev/null)"#,
    r#""$(printf "%s" /dev/null)""#,
    r#"$(printf "%s" ")")"#,
    r#"$(printf "%s" "(")"#,
    r"a\ b",
    "$(echo $(echo /dev/null))",
    r#"$(printf "%s" "a;b")"#,
];

/// More installs of the same validator: a verb escaped inside quotes, and an
/// escape that makes a group, a quote, a newline or two redirections.
const COMPOSED_NAMED: &[&str] = &[
    r"$'\x70'ip>'a b' i$'\x6e'stall sample==1.0.0",
    r"printf '\x70ip\x28N\x29\x3e/dev/null install sample==1.0.0' | sh",
    r#"echo -e '\0160ip\0076"a b" install sample==1.0.0' | sh"#,
    r"printf 'p\x5c\nip>/dev/null install sample==1.0.0' | sh",
    r#"$'\x70ip' 3>"a b" 4>$(printf x) install sample==1.0.0"#,
    r"p$'\x69'p((N))>'a b' install sample==1.0.0",
];

/// That validator's controls: a name inside a word, a manager with no verb,
/// and a manager that installs nothing, each behind the same escapes.
const COMPOSED_CONTROLS: &[&str] = &[
    r"printf '%s\n' pipefail",
    r#"$'\x70ip'>"a b" --version"#,
    r#"p$'\x79'thon3 >"a b" -c 'print(1)' "#,
];

#[test]
fn discriminator_reads_installs_two_rewrites_make_together() {
    let grid = COMPOSED_HEADS.iter().flat_map(|h| COMPOSED_TARGETS.iter().map(move |t| format!("{h}>{t} install sample==1.0.0")));
    let rows: Vec<String> = COMPOSED_INSTALLS.iter().chain(COMPOSED_NAMED).map(|t| t.to_string()).chain(grid).collect();
    assert_eq!(rows.len(), 22 + 6 + 50);
    for text in &rows {
        assert!(looks_like_install_unscanned(text.as_bytes()), "{text}");
        assert!(looks_like_install_unscanned(format!("{FAILS}; {text}").as_bytes()), "{text}");
    }
    for text in COMPOSED_CONTROLS {
        assert!(!looks_like_install_unscanned(format!("{FAILS}; {text}").as_bytes()), "{text}");
    }
}

/// Installs whose name or verb is a word only after a step of the shell that
/// is not an escape or a quote, each one in bash or zsh: a brace expansion, a
/// glob that a file of the name matches, the value of a `${name-word}`, zsh's
/// `=name`, words that `,` parts once IFS splits them, a name and verb that
/// the blanks of `$IFS` part, a name or verb an empty expansion splits, a
/// glob's group of zsh or of bash's extended globs, and a NUL: bash cuts a
/// `$'...'` there, exec cuts a name there, and bash and dash drop it from a
/// script they read.
const HIDDEN_INSTALLS: &[&str] = &[
    "pip in{stall,} x",
    "{pip,install} x",
    "p{i..i}p install x",
    "cargo {a,x}dd x",
    "pip in{\"s\"tall,' '} x",
    "pip {{in,}s,}tall x",
    "/usr/bin/pi[p] install x",
    "/opt/homebrew/bin/n?m i x",
    "/usr/local/bin/pip3.1[0-9] install x",
    "/usr/local/bin/pip3.1* install x",
    "pip i[n]stall x",
    "${x:-npm} i y",
    "${x-pip} install y",
    "${:-npm} i y",
    "pip ${x:-install} y",
    "${(L)x-npm} i y",
    "=npm install x",
    "x=npm,i; IFS=,; $x y",
    "pip$IFS'install' x",
    "npm${IFS}i x",
    "pip in${:-stall} x",
    "pip in${x:-st}all y",
    "n$()pm i x",
    "n``pm i x",
    "n${x}pm i y",
    "n$(: \")\")pm i y",
    "p$(echo)i$x\"p\" install y",
    "/opt/homebrew/bin/(n|q)pm i x",
    "/usr/local/bin/n(p)m i x",
    "/usr/bin/@(pip|q) install y",
    "/usr/bin/p?(i)p install y",
    "/opt/homebrew/bin/!(q)pm i x",
    "pip i(n|q)stall y",
    "# it's\npip in{stall,' '} x",
];

/// Commands that a NUL-producing escape makes an install of, which no view
/// reconstructs: bash ends a `$'...'` at the first NUL escape and glues what
/// follows the closing quote, so a manager or verb is truncated and rejoined
/// (`$'pi\0junk'p` is `pip`, `pip $'inst\0junk'all` runs `pip install`), and a
/// script piped to a shell loses its NUL bytes. The escape is written as `\0`,
/// `\x00`, `\c@`, `\C-@`, an octal multiple of 256, and under outer quotes a
/// validator split with `shlex.quote` or doubled the backslash in a
/// double-quoted `bash -c` carrier, where the NUL appears only in a later
/// view. A view that holds the NUL byte, at whatever escape depth, is denied.
const NUL_INSTALLS: &[&str] = &[
    r"$'pip\0junk' install x",
    r"$'pip\x00junk' install x",
    r"$'pip\c@junk' install x",
    r"$'pip\400junk' install x",
    r"$'pip\C-@junk' install x",
    r"$'pi\0x'p install x",
    r"$'pi\0\'x'p install x",
    r"$'pi\0junk'p install x",
    r"pip $'install\0junk' x",
    r"pip $'inst\0junk'all x",
    r"printf 'p\0ip install x' | sh",
    r#"bash -c '$'"'"'pi\0junk'"'"'p install sample==1.0.0'"#,
    r"$'pi\\0junk'p install x",
    r"pip $'inst\\0junk'all x",
    r#"bash -c "$'pi\\0junk'p install sample==1.0.0""#,
    r#"bash -c "pip $'inst\\0junk'all sample==1.0.0""#,
    r#"bash -c "$'pip\\0junk' install sample==1.0.0""#,
];

#[test]
fn discriminator_reads_words_the_shell_makes_without_a_rewrite() {
    for text in HIDDEN_INSTALLS {
        assert!(looks_like_install_unscanned(text.as_bytes()), "{text}");
        assert!(looks_like_install_unscanned(format!("{FAILS}; {text}").as_bytes()), "{text}");
    }
}

/// A NUL-producing escape denies the command, alone and after a failed
/// reading, whatever words it holds, because bash can truncate and glue a
/// manager or verb through it that no view reconstructs. A command with no
/// such escape is read as usual, so `\560` (a `p`) and `\012` (a newline)
/// are not NUL and do not deny on their own.
#[test]
fn discriminator_denies_a_nul_producing_escape() {
    for text in NUL_INSTALLS {
        assert!(looks_like_install_unscanned(text.as_bytes()), "{text}");
        assert!(looks_like_install_unscanned(format!("{FAILS}; {text}").as_bytes()), "{text}");
    }
    for text in [r"$'\0'", r"echo $'a\0b'", r"printf '\x00'", r"grep -c . a; : $'\c@'", r"x=$'\U00000000'; echo i", r#"bash -c "echo $'a\0b'""#] {
        assert!(looks_like_install_unscanned(text.as_bytes()), "{text}");
    }
    for text in [r"$'\560ip' --version", r"printf 'a\012b'", r"echo -e 'a\0560b'", "ls -la", "echo npm"] {
        assert!(!looks_like_install_unscanned(text.as_bytes()), "{text}");
    }
}


/// A manager or verb assembled across a `$'...'` escape-context boundary, the
/// opening `$'` left whole, where the shell makes an escape a byte inside
/// `$'...'` and the ordinary char outside: `\n` is the letter `n` and `\3` the
/// digit `3` outside, `$'\x70'` the byte `p` inside, so `\pi$'\x70'\3 install`
/// is `pip3 install` and `pip $'\x69'\nstall` is `pip install`. These run a
/// real install, so the discriminator denies them: `dollar_numeric_expanded`
/// expands each whole `$'...'` to its bytes and leaves the outside for the bare
/// cut to strip to the letter, so one view holds `<manager> <verb>` as words.
/// The old predicate blocked these too (a failed-reading command whose text
/// reads as an install), so allowing them was a regression. Rows drawn from
/// eve's checkpoint grid at `eve-redesign-checkpoint-3wzb1j63/results.json`.
const ESCAPE_MIXED_VERB_INSTALLS: &[&str] = &[
    r"\n$'\x70'm i sample==1.0.0",
    r"pip $'\x69'\nstall sample==1.0.0",
    r"pip3 i\n$'\x73'tall sample==1.0.0",
    r"cargo i\n$'\x73'tall sample",
    r"npm $'\x69'\nstall sample@1.0.0",
    r"gem i\n$'\x73'tall sample",
    r"bun \a$'\x64'd sample",
    r"yarn \a$'\x64'd sample",
    r"\pi$'\x70'\3 install requests==2.0.0",
];

#[test]
fn a_verb_assembled_across_a_whole_dollar_quote_boundary_is_an_install() {
    for text in ESCAPE_MIXED_VERB_INSTALLS {
        assert!(looks_like_install_unscanned(text.as_bytes()), "{text}");
        assert!(looks_like_install_unscanned(format!("{FAILS}; {text}").as_bytes()), "{text}");
    }
    // A failed reading with no manager word is still not an install (eve's
    // no-manager control), and a verb needs its manager (a bare verb is not).
    for text in [r"echo hello sample", r"i\n$'\x73'tall sample"] {
        assert!(!looks_like_install_unscanned(format!("{FAILS}; {text}").as_bytes()), "{text}");
    }
}
/// The words of each form of the install body, and nothing more, alone and
/// in another order: one install for each form, in the order of
/// `grammar::install_forms`. Each matches its alternative of the body.
const FORM_INSTALLS: &[&[&str]] = &[
    &["npm install x", "npm link x"],
    &["npx cowsay"],
    &["npm exec cowsay"],
    &["npm init vite", "pnpm create vite", "yarn create vite", "bun c vite"],
    &["pnpm dlx cowsay"],
    &["yarn add x"],
    &["bun add x"],
    &["bun x cowsay"],
    &["pip3.12 install x", "python3 -mpip install x"],
    &["poetry add x"],
    &["uv add x", "uv pip install x", "uv tool install x"],
    &["uv tool run x"],
    &["pipx inject x y"],
    &["pipx run x"],
    &["pipenv install x"],
    &["cargo install x"],
    &["go get x"],
    &["go run example.com/x@v1"],
    &["gem install x"],
    &["bundle add x"],
    &["mvn org.apache.maven.plugins:maven-dependency-plugin:3.6.0:get"],
    &["dotnet add app.csproj package x"],
    &["dotnet package update x"],
    &["dotnet tool update x"],
];

#[test]
fn every_form_of_the_install_body_is_read_from_its_words() {
    let p = grammar::patterns();
    let forms = grammar::install_forms();
    let executables: Vec<&str> = grammar::EXECUTABLES.split('|').collect();
    assert_eq!((forms.len(), FORM_INSTALLS.len()), (p.install_bodies.len(), p.install_bodies.len()));
    for ((body, forms), samples) in p.install_bodies.iter().zip(&forms).zip(FORM_INSTALLS) {
        assert_eq!(forms.len(), samples.len(), "{body}");
        let re = Regex::new(&format!("^({body}){}", p.end), true).unwrap();
        for (form, sample) in forms.iter().zip(*samples) {
            assert!(form.manager.split('|').all(|m| executables.contains(&m)), "{}", form.manager);
            assert!(re.is_match(sample.as_bytes()), "{sample}");
            assert!(looks_like_install_unscanned(sample.as_bytes()), "{sample}");
            let mut words: Vec<&str> = sample.split(' ').collect();
            words.reverse();
            assert!(looks_like_install_unscanned(words.join(" ").as_bytes()), "{sample}");
        }
    }
}

/// A manager beside a verb that is not its own, a body cut short, a name that
/// is part of another word, and a glob that stands for no verb's file or for
/// any name at all: none is an install. A verb anywhere beside
/// the manager is one, though: the words are read in no order.
#[test]
fn a_manager_pairs_only_with_its_own_verbs() {
    for text in [
        "pip add x",
        "cargo get x",
        "uv install x",
        "go run main.go",
        "dotnet add reference x",
        "gem add x",
        "npm run build && echo done",
        "npm_config_registry=x node a.js install",
        "./mynpm install x",
        "echo junk\\npm; echo i",
        "pipx list --include-injected",
        "echo i; python3 -m pytest",
        "mvn test && ls target/*",
        "go run main.go && ls *.go",
        "ls src/*; echo i",
        "grep -o '[a-z]*' a.txt; npm --version",
        "python3 -c 'print(b[jump_repair][rounds])'; echo a",
    ] {
        assert!(!looks_like_install_unscanned(format!("{FAILS}; {text}").as_bytes()), "{text}");
    }
    assert!(looks_like_install_unscanned(format!("{FAILS}; echo install; pip --version").as_bytes()));
}

/// `\x5c` stands for a backslash, so an escape written inside `n - 1` of them
/// is expanded once more by each of `n` rewrites: its views are one sequence
/// of `n + 1`. `\0101` is two bytes to printf and one to `echo -e`, so a
/// text whose `k`-th escape is that one inside `k` backslashes takes a
/// different view from each of the two rewrites at each step, and `c` of
/// them make `2^(c + 1) - 1` views. Past `UNSCANNED_VIEWS` views or
/// `UNSCANNED_DEPTH` in a sequence, the text reads as an install, though
/// none of its views names a manager.
#[test]
fn discriminator_reads_a_text_past_its_views_as_an_install() {
    let nested = |n: usize| format!("echo \\{}x41", "x5c".repeat(n - 1));
    let mut view = nested(4).into_bytes();
    for _ in 0..4 {
        view = escapes_expanded(&view);
    }
    assert_eq!(view, b"echo A");
    assert!(!looks_like_install_unscanned(nested(UNSCANNED_DEPTH - 1).as_bytes()));
    assert!(looks_like_install_unscanned(nested(UNSCANNED_DEPTH).as_bytes()));
    let forks = |c: usize| format!("echo {}", (0..c).map(|k| format!("\\{}0101", "x5c".repeat(k))).collect::<Vec<_>>().join(" "));
    assert_eq!(((1 << 10) - 1, 1 << 10), (UNSCANNED_VIEWS - 1, UNSCANNED_VIEWS));
    assert!(!looks_like_install_unscanned(forks(9).as_bytes()));
    assert!(looks_like_install_unscanned(forks(10).as_bytes()));
}

/// `k` groups of two words side by side make `2^k` texts. Past `BRACE_BYTES`
/// of them, the text reads as an install, though none of them names a
/// manager. Groups a blank stands between are not side by side.
/// A rewrite changes no text that holds none of the bytes it needs, so the
/// walk passes it by there. Every row above and every view one rewrite makes
/// of it that a rewrite changes holds one of the bytes that rewrite needs.
#[test]
fn a_rewrite_changes_no_text_without_the_bytes_it_needs() {
    let rewrites = super::unscanned::REWRITES;
    let rows = INSTALLS.iter().chain(COMPOSED_INSTALLS).chain(COMPOSED_NAMED).chain(HIDDEN_INSTALLS).chain(NOT_INSTALLS);
    let mut texts: Vec<W> = rows.map(|t| t.as_bytes().to_vec()).collect();
    let views: Vec<W> = texts.iter().flat_map(|t| rewrites.iter().map(move |(rewrite, _)| rewrite(t))).collect();
    texts.extend(views);
    let mut changed = 0;
    for text in &texts {
        for (rewrite, needs) in rewrites {
            if rewrite(text) != *text {
                changed += 1;
                assert!(needs.iter().any(|b| text.contains(b)), "{needs:?} {}", String::from_utf8_lossy(text));
            }
        }
    }
    assert!(changed > 100);
}

#[test]
fn discriminator_reads_a_text_past_its_brace_expansions_as_an_install() {
    let groups = |k: usize| format!("echo x{}", "{a,b}".repeat(k));
    assert_eq!(BRACE_BYTES, 1 << 24);
    assert!(!looks_like_install_unscanned(groups(12).as_bytes()));
    assert!(looks_like_install_unscanned(groups(20).as_bytes()));
    assert!(looks_like_install_unscanned(groups(100_000).as_bytes()));
    // A pair of braces with blanks in it holds no group, though the groups in
    // it would make far more than `BRACE_BYTES` side by side.
    assert!(!looks_like_install_unscanned(format!("echo {{ {}}}", "{a,b} ".repeat(30)).as_bytes()));
}

/// What the bounds cost, printed by `cargo test --release unscanned_views_cost
/// -- --nocapture`: the shape above just under `UNSCANNED_VIEWS` after 100 kB
/// and 1 MB of other text, 100 kB and 1 MB of words, 1 MB of words and of
/// words read as patterns beside the name of every manager that needs a verb,
/// a browser eval with escapes, groups, globs, braces,
/// quotes and a redirection, repeated to about 360 kB, brace groups just
/// under `BRACE_BYTES`, 250 kB of objects one segment holds, each a group of
/// its own, and 250 kB of code whose braces hold blanks and so are no group.
/// None of them reads as an install.
#[test]
fn unscanned_views_cost() {
    let forks = format!("echo {}", (0..9).map(|k| format!("\\{}0101", "x5c".repeat(k))).collect::<Vec<_>>().join(" "));
    let words = |n: usize| (0..n).map(|i| format!("w{i}")).collect::<Vec<_>>().join(" ");
    let eval = r#"browser-cli eval --expr '(()=>{const a=[...document.querySelectorAll("a")].map(x=>(x.innerText||"").trim()).filter(t=>t.length>0&&(t.indexOf("\\n")<0)); const go=a[0]?.get; return JSON.stringify({n:a.length, s:"a\"b\nc\x41", m:(((1+2)*3)>2), p:{q:[1,2],r:{s:3,t:4}}, g:a.map(x=>x*2)})})()' > out.json 2>&1"#;
    let shapes = [
        ("views after 100 kB", format!("{} {forks}", "x".repeat(100_000))),
        ("views after 1 MB", format!("{} {forks}", "x".repeat(1_000_000))),
        ("100 kB of words", words(15_000)),
        ("1 MB of words", words(130_000)),
        ("1 MB of words and patterns beside each manager", format!("{} {}", grammar::EXECUTABLES.split('|').filter(|m| !m.ends_with('x')).collect::<Vec<_>>().join(" "), (0..90_000).map(|i| format!("w{i} q[{i}]?")).collect::<Vec<_>>().join(" "))),
        ("eval x1000", vec![eval; 1000].join("; ")),
        ("braces", format!("echo x{}", "{a,b}".repeat(18))),
        ("objects", format!("browser-cli eval --expr '[{}]'", vec!["{a:1,b:[2,3],c:{d:4,e:5}}"; 10_000].join(","))),
        ("blocks", format!("cat > a.cs <<'EOF'\n{}\nEOF", vec!["class A { void F(int a, int b) { var x = new[] { a, b }; if (a > b) { G(a, b); } } }"; 3_000].join("\n"))),
    ];
    for (name, text) in shapes {
        let start = Instant::now();
        let answer = looks_like_install_unscanned(text.as_bytes());
        eprintln!("{name}: {} bytes, {:.3}s, install={answer}", text.len(), start.elapsed().as_secs_f64());
        assert!(!answer, "{name}");
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
