//! safedeps-core: the PreToolUse and PostToolUse hooks of safedeps, and the
//! read-only queries the batteries ask of the code the hooks run.
//!
//!   safedeps-core pre | post
//!       The hooks. The registered entry, scripts/safedeps-hook-entry.sh,
//!       runs them with the payload on stdin. They take the subcommand and
//!       nothing else: no argument and no environment variable chooses how
//!       one judges. `pre --budget-child` is the one extra argument, which
//!       the pre hook gives its own judgment process (see pre/budget.rs).
//!   safedeps-core stamp [--check]
//!       `<kind> <sha256>`: the kind of build (`checkout` or `publish`) and
//!       the digest of the source it was built from. With --check, whether a
//!       checkout's binary still stands beside that source: exit 0 and `ok`,
//!       or exit 1 and the reason. Both hooks check it before they judge.
//!   safedeps-core budget-config
//!       The pre hook's budget numbers, one JSON object: the runtime budget
//!       it assumes, the self budget's default and ceiling, the engage size's
//!       default and ceiling, and the limits on a knob's digits and length.
//!   safedeps-core version
//!
//! The queries below are read-only and none is on a hook's path. The
//! batteries read the lexer, the grammar and the readers through them.
//!
//!   safedeps-core lex <view> [<marker>] [--divmemo FILE]
//!       One lexing: the text on stdin, the reading in SAFEDEPS_READING, the
//!       flags file in SAFEDEPS_LEX_FLAGS, the divergence file in
//!       SAFEDEPS_LEX_DIVERGE and the scan mark in SAFEDEPS_SCAN_MARK. The
//!       view on stdout. A reading that is not set is a failed reading (exit
//!       1, `failed` on the mark), and so is a view no branch names (exit 2).
//!   safedeps-core lex-batch
//!       Many lexings in one process: records on stdin, `<reading> <view>
//!       <length>\n<bytes>`, answers on stdout, `<status> <unterm> <diverge>
//!       <smfail> <length>\n<bytes>`.
//!   safedeps-core grammar
//!       The grammar's values, `name=value` per line.
//!   safedeps-core grep [-i] [-n] <pattern>
//!       grep -E over stdin with this crate's regex engine.
//!   safedeps-core facts
//!       The judgment facts of one hook payload (stdin), per reading: whether
//!       the command closes and installs, the statements' kinds, the
//!       ecosystem and the extractor's readings, as `<key> <length>\n<bytes>\n`
//!       records.
//!   safedeps-core words
//!       The statements of a text (stdin, the reading in SAFEDEPS_READING)
//!       with where their words stand, and its payloads with where their
//!       bytes stand: the structure the inert rewrite reads, as records.
//!   safedeps-core payloads
//!       The payloads of a text as one JSON object, with each byte's source.
//!   safedeps-core inert
//!       The inert rewrite of one hook payload (stdin), as the reading's own
//!       account: the places it found and any collision (see inert.rs).
//!   safedeps-core reader
//!       One reader function of the core per query: `statements`,
//!       `raw-texts` or `lex-payloads` of a text in a reading. A query is a
//!       JSON object on a line of stdin, its answer one on a line of stdout
//!       (query.rs has the fields).
//!   safedeps-core manager
//!       The manager reader, the same way: `npa-local` of a word, `npm-read`
//!       of npm's words under its table or the other npm's, `read` of a
//!       statement's words (each word's role), and `option-class` of an
//!       option after a command path.
//!   safedeps-core kat [<path>]
//!       Known answers from the modules the hooks share (the digests, the
//!       JSON writer, how a file's times and inodes are spelled).
//!
//! `pre-probe`, `post-probe`, `ask-probe`, `ledger`, `state-rotate` and
//! `json-stream` are measurement entries: each takes data on stdin and calls
//! the operation a hook calls, and none takes a shell program.

// The modules marked `dead_code` carry items the hooks do not all call. The
// mark dates from when the callers were being moved in, and it has not been
// revisited.
#[allow(dead_code)]
mod ask;
mod callid;
mod core;
mod ere;
mod extract;
mod grammar;
#[allow(dead_code)]
mod inert;
#[allow(dead_code)]
mod jq;
mod json;
#[allow(dead_code)]
mod ledger;
mod lex;
mod manager;
mod md5;
#[allow(dead_code)]
mod os;
mod post;
mod pre;
mod query;
#[allow(dead_code)]
mod sha256;
mod srchash;
mod stamp;
#[allow(dead_code)]
mod state;
mod tables;

use std::io::{BufRead, Read, Write};

fn grammar_regexes() -> lex::Grammar {
    let exre = format!("^({}|{})$", grammar::EXECUTABLES, grammar::SHELLS);
    let shre = format!("^({})$", grammar::SHELLS);
    lex::Grammar {
        exre: Some(ere::Regex::new(&exre, false).expect("executables pattern")),
        shre: Some(ere::Regex::new(&shre, false).expect("shells pattern")),
    }
}

fn mark_failed() {
    if let Ok(p) = std::env::var("SAFEDEPS_SCAN_MARK") {
        if !p.is_empty() {
            if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&p) {
                let _ = f.write_all(b"failed\n");
            }
        }
    }
}

fn cmd_lex(args: &[String]) -> i32 {
    let mut view: Option<&str> = None;
    let mut divmemo: Option<String> = None;
    let mut k = 0;
    while k < args.len() {
        if args[k] == "--divmemo" {
            divmemo = args.get(k + 1).cloned();
            k += 2;
            continue;
        }
        if view.is_none() {
            view = Some(&args[k]);
        }
        k += 1;
    }
    let Some(view) = view else {
        eprintln!("safedeps-core lex: no view");
        return 2;
    };
    let reading = std::env::var("SAFEDEPS_READING").ok().and_then(|r| lex::Reading::parse(&r));
    let Some(reading) = reading else {
        mark_failed();
        return 1;
    };
    let mut text = Vec::new();
    if std::io::stdin().read_to_end(&mut text).is_err() {
        mark_failed();
        return 1;
    }
    let g = grammar_regexes();
    let flags = std::env::var("SAFEDEPS_LEX_FLAGS").ok();
    let divfile = std::env::var("SAFEDEPS_LEX_DIVERGE").ok();
    let smark = std::env::var("SAFEDEPS_SCAN_MARK").ok();
    match lex::lex_with_files(&g, &text, view, reading, flags.as_deref(), divfile.as_deref(), divmemo.as_deref(), smark.as_deref()) {
        Ok(out) => {
            let mut so = std::io::stdout().lock();
            if so.write_all(&out).is_err() || so.flush().is_err() {
                return 1;
            }
            0
        }
        Err(()) => 2,
    }
}

fn cmd_lex_batch() -> i32 {
    let g = grammar_regexes();
    let stdin = std::io::stdin();
    let mut inp = stdin.lock();
    let mut so = std::io::BufWriter::new(std::io::stdout().lock());
    loop {
        let mut head = String::new();
        match inp.read_line(&mut head) {
            Ok(0) => break,
            Ok(_) => {}
            Err(_) => return 1,
        }
        let parts: Vec<&str> = head.trim_end_matches('\n').split(' ').collect();
        if parts.len() != 3 {
            eprintln!("safedeps-core lex-batch: bad header {:?}", head);
            return 2;
        }
        let len: usize = match parts[2].parse() {
            Ok(n) => n,
            Err(_) => return 2,
        };
        let mut text = vec![0u8; len];
        if inp.read_exact(&mut text).is_err() {
            return 2;
        }
        let Some(rd) = lex::Reading::parse(parts[0]) else {
            let _ = writeln!(so, "1 0 0 0 0");
            continue;
        };
        let r = lex::Lex::new(&g, &text, parts[1], rd).run();
        let (status, out, side) = match r {
            Ok((o, s)) => (0, o, s),
            Err((_, s)) => (2, Vec::new(), s),
        };
        let _ = write!(so, "{} {} {} {} {}\n", status, side.unterm as i32, side.diverge as i32, side.smfail as i32, out.len());
        let _ = so.write_all(&out);
    }
    let _ = so.flush();
    0
}

fn cmd_grep(args: &[String]) -> i32 {
    let mut icase = false;
    let mut number = false;
    let mut pat: Option<&String> = None;
    for a in args {
        match a.as_str() {
            "-i" => icase = true,
            "-n" => number = true,
            _ => pat = Some(a),
        }
    }
    let Some(pat) = pat else { return 2 };
    let re = match ere::Regex::new(pat, icase) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("safedeps-core grep: {}", e.0);
            return 2;
        }
    };
    let mut text = Vec::new();
    if std::io::stdin().read_to_end(&mut text).is_err() {
        return 2;
    }
    // grep reads lines; a final newline ends the last one.
    let body: &[u8] = if text.last() == Some(&b'\n') { &text[..text.len() - 1] } else { &text };
    let mut any = false;
    let mut so = std::io::stdout().lock();
    if !body.is_empty() || !text.is_empty() {
        for (k, line) in body.split(|&b| b == b'\n').enumerate() {
            if re.is_match(line) {
                any = true;
                if number {
                    let _ = write!(so, "{}:", k + 1);
                    let _ = so.write_all(line);
                    let _ = so.write_all(b"\n");
                }
            }
        }
    }
    if any {
        0
    } else {
        1
    }
}

fn cmd_facts() -> i32 {
    let mut input = Vec::new();
    if std::io::stdin().read_to_end(&mut input).is_err() {
        return 1;
    }
    let Some((tool, cmd)) = core::command_of_payload(&input) else { return 0 };
    // `COMMAND=$(... | jq -r ...)`: NUL bytes do not survive a bash string,
    // and the command substitution drops trailing newlines.
    let mut cmd: Vec<u8> = cmd.into_iter().filter(|&b| b != 0).collect();
    while cmd.last() == Some(&b'\n') {
        cmd.pop();
    }
    if tool != "Bash" || cmd.is_empty() {
        return 0;
    }
    let c = core::Core::new();
    let mut run = core::Run::new(&c);
    let f = run.facts(&cmd);
    let mut so = std::io::stdout().lock();
    let _ = so.write_all(&core::render(&f));
    let _ = so.flush();
    0
}

fn read_stdin() -> Option<Vec<u8>> {
    let mut input = Vec::new();
    std::io::stdin().read_to_end(&mut input).ok()?;
    Some(input)
}

fn cmd_kat(args: &[String]) -> i32 {
    use jq::J;
    let mut out: Vec<u8> = Vec::new();
    let mut line = |k: &str, v: &[u8]| {
        out.extend_from_slice(k.as_bytes());
        out.push(b' ');
        out.extend_from_slice(v);
        out.push(b'\n');
    };
    line("md5", md5::hex(b"abc").as_bytes());
    line("md5-empty", md5::hex(b"").as_bytes());
    line("sha256", sha256::hex(b"abc").as_bytes());
    line("sha256-empty", sha256::hex(b"").as_bytes());
    let long = vec![b'a'; 1_000_000];
    line("sha256-million-a", sha256::hex(&long).as_bytes());
    line("md5-million-a", md5::hex(&long).as_bytes());
    line("jq-escapes", jq::compact(&jq::obj(vec![("x", jq::arg(b"a\x01b\x7fc\x1bd\"e\\f/g<h>i&j\tk\nl\rm\x08n\x0co"))])).as_bytes());
    line("jq-invalid", jq::compact(&jq::arg(b"h\xed\x95\x9c \xff \xc3 z")).as_bytes());
    line("jq-invalid-tail", jq::compact(&jq::arg(b"a\xe2\x82 b\xf0\x9f\x98")).as_bytes());
    let nested = jq::obj(vec![
        ("snapshot_id", jq::s("x")),
        ("n", J::Num("1".into())),
        ("npm_trace", J::Null),
        ("o", J::Obj(vec![])),
        ("arr", J::Arr(vec![])),
        ("arr2", J::Arr(vec![J::Num("1".into()), jq::s("a")])),
        ("nested", jq::obj(vec![("a", jq::obj(vec![("b", J::Num("1".into()))]))])),
        ("ok", J::Bool(true)),
        ("tool_use_id", J::Null),
    ]);
    line("jq-pretty", jq::pretty(&nested).replace('\n', "|").as_bytes());
    line("jq-deny", jq::deny("a \"b\"\n<c>").as_bytes());
    line("utc-0", os::utc_stamp(0).as_bytes());
    line("utc-leap", os::utc_stamp(951_782_400).as_bytes());
    line("utc-2026", os::utc_stamp(1_791_291_940).as_bytes());
    line("subsecond", format!("{} {} {}", os::clock_has_subsecond("1.5|2.25") as i32, os::clock_has_subsecond("1.000000000|2.25") as i32, os::clock_has_subsecond("") as i32).as_bytes());
    if let Some(p) = args.first() {
        let path = std::path::Path::new(p);
        line("clock-c", os::tree_clock(path).as_bytes());
        line("clock-m", os::file_clock(path, b'm', false).as_bytes());
        line("clock-m-follow", os::file_clock(path, b'm', true).as_bytes());
        line("inode", os::tree_inode(path).as_bytes());
        line("realpath", &os::realpath(p.as_bytes()));
        line("bash-len", os::bash_len(p.as_bytes()).to_string().as_bytes());
    }
    let mut so = std::io::stdout().lock();
    if so.write_all(&out).is_err() || so.flush().is_err() {
        return 1;
    }
    0
}

fn cmd_stamp(args: &[String]) -> i32 {
    if args.first().map(|s| s.as_str()) != Some("--check") {
        println!("{} {}", stamp::KIND, stamp::SHA256);
        return 0;
    }
    match stamp::refusal() {
        None => {
            println!("ok");
            0
        }
        Some(why) => {
            println!("{}", why);
            1
        }
    }
}

/// The structure of one text: `unterm`, `unreadable`, then per statement
/// `P <nn> <start> <end> <words>` and per word `W <start> <end> <length>`
/// with the value's bytes on the next line, `V <length>` with the pieces view,
/// and per payload `Y <kind> <length>` with its bytes and `S` with where each
/// stands (`-` for a decoded byte).
fn cmd_words() -> i32 {
    let Some(reading) = std::env::var("SAFEDEPS_READING").ok().and_then(|r| lex::Reading::parse(&r)) else {
        mark_failed();
        return 1;
    };
    let Some(text) = read_stdin() else { return 1 };
    let c = core::Core::new();
    let mut run = core::Run::new(&c);
    run.reading = Some(reading);
    let mut out: Vec<u8> = Vec::new();
    let Some((pieces, unterm)) = run.pieces(&text) else {
        mark_failed();
        return 1;
    };
    out.extend_from_slice(format!("unterm {}\nunreadable {}\n", unterm as i32, pieces.unreadable as i32).as_bytes());
    for p in &pieces.pieces {
        out.extend_from_slice(format!("P {} {} {} {}\n", p.nn, p.start, p.end, p.words.len()).as_bytes());
        for w in &p.words {
            out.extend_from_slice(format!("W {} {} {}\n", w.start, w.end, w.value.len()).as_bytes());
            out.extend_from_slice(&w.value);
            out.push(b'\n');
        }
    }
    out.extend_from_slice(format!("V {}\n", pieces.view.len()).as_bytes());
    out.extend_from_slice(&pieces.view);
    out.push(b'\n');
    for y in run.payloads(&text) {
        out.extend_from_slice(format!("Y {} {}\n", y.kind as char, y.text.len()).as_bytes());
        out.extend_from_slice(&y.text);
        out.extend_from_slice(b"\nS");
        for s in &y.src {
            match s {
                Some(k) => out.extend_from_slice(format!(" {}", k).as_bytes()),
                None => out.extend_from_slice(b" -"),
            }
        }
        out.push(b'\n');
    }
    out.extend_from_slice(format!("failed {}\n", run.failed as i32).as_bytes());
    let mut so = std::io::stdout().lock();
    if so.write_all(&out).is_err() || so.flush().is_err() {
        return 1;
    }
    0
}

/// JSON structure probe: source offsets are data, not the compressed view.
fn cmd_payloads() -> i32 {
    let Some(input) = read_stdin() else { return 2; };
    let Some(reading) = std::env::var("SAFEDEPS_READING").ok().and_then(|r| lex::Reading::parse(&r)) else { return 1; };
    let core = core::Core::new();
    let mut run = core::Run::new(&core);
    run.reading = Some(reading);
    let payloads = run.payloads(&input).into_iter().map(|p| {
        let origin = match p.origin {
            core::PayloadOrigin::ShellC => "shell-c",
            core::PayloadOrigin::Eval => "eval",
            core::PayloadOrigin::EnvSplit => "env-split",
            core::PayloadOrigin::CommandSubstitution => "command-substitution",
            core::PayloadOrigin::Backquote => "backquote",
            core::PayloadOrigin::ProcessSubstitution => "process-substitution",
        };
        jq::obj(vec![("kind", jq::s(&(p.kind as char).to_string())), ("text", jq::arg(&p.text)),
            ("src", jq::J::Arr(p.src.into_iter().map(|n| n.map(|n| jq::J::Num(n.to_string())).unwrap_or(jq::J::Null)).collect())),
            ("origin", jq::s(origin)), ("shell", p.shell.map(|s| jq::arg(&s)).unwrap_or(jq::J::Null))])
    }).collect();
    println!("{}", jq::compact(&jq::obj(vec![("payloads", jq::J::Arr(payloads)), ("failed", jq::J::Bool(run.failed)), ("diverge", jq::J::Bool(run.diverge))])));
    0
}

fn main() {
    // An argument that is not text must not end the process before it answers.
    let args: Vec<String> = std::env::args_os().map(|a| a.to_string_lossy().into_owned()).collect();
    let code = match args.get(1).map(|s| s.as_str()) {
        Some("lex") => cmd_lex(&args[2..]),
        Some("lex-batch") => cmd_lex_batch(),
        Some("grammar") => {
            print!("{}", grammar::dump());
            0
        }
        Some("grep") => cmd_grep(&args[2..]),
        Some("facts") => cmd_facts(),
        Some("words") => cmd_words(),
        Some("payloads") => cmd_payloads(),
        Some("inert") => match read_stdin() {
            Some(input) => inert::cli(&input),
            None => 1,
        },
        // The hooks take the subcommand and nothing else: no argument and no
        // environment variable chooses how one judges.
        Some("pre") if args.len() == 3 && args[2] == "--budget-child" => match read_stdin() {
            Some(input) => pre::main(&input, true),
            None => 2,
        },
        Some("pre") if args.len() > 2 => {
            println!("{}", jq::deny("safedeps: the PreToolUse hook was started with an argument, and it takes none. Bash is blocked fail-closed until the hook is registered as safedeps installs it: node scripts/install/install-safedeps-hooks.mjs"));
            0
        }
        Some("pre") => match read_stdin() {
            Some(input) => pre::main(&input, false),
            None => 2,
        },
        Some("post") => match read_stdin() {
            Some(input) => post::main(&input),
            None => 2,
        },
        Some("post-probe") => match read_stdin() {
            Some(input) => post::probe(&input),
            None => 2,
        },
        Some("pre-probe") => match read_stdin() {
            Some(input) => pre::probe(&input),
            None => 2,
        },
        Some("ledger") => match read_stdin() {
            Some(input) => ledger::main(&args[2..], &input),
            None => 1,
        },
        Some("ask-probe") => match read_stdin() {
            Some(input) => ask::probe(&input),
            None => 2,
        },
        Some("state-rotate") => {
            os::set_umask(0o077);
            let path = state::guard_dir().join("advisory.log");
            state::advisory_rotate_once(&path);
            if let Some(input) = read_stdin().filter(|v| !v.is_empty()) {
                if let Ok(mut f) = std::fs::OpenOptions::new().append(true).open(&path) {
                    let _ = f.write_all(&input);
                }
                state::advisory_rotate_once(&path);
            }
            0
        },
        Some("json-stream") => match read_stdin() {
            Some(input) => {
                let stream = json::read(&input);
                for value in stream.values { println!("{}", jq::compact(&jq::from_value(&value))); }
                if stream.failed { 5 } else { 0 }
            }
            None => 2,
        },
        // Read-only queries: none is on a hook's path, and none takes an
        // argument or an environment variable that changes an answer.
        Some("budget-config") => {
            println!("{}", pre::budget_config());
            0
        }
        Some("reader") => match read_stdin() {
            Some(input) => query::reader(&input),
            None => 1,
        },
        Some("manager") => match read_stdin() {
            Some(input) => query::manager(&input),
            None => 1,
        },
        Some("kat") => cmd_kat(&args[2..]),
        Some("stamp") => cmd_stamp(&args[2..]),
        Some("version") => {
            println!("safedeps-core {}", env!("CARGO_PKG_VERSION"));
            0
        }
        _ => {
            eprintln!("usage: safedeps-core lex <view> | lex-batch | grammar | grep [-i] [-n] <pattern> | facts | words | inert | pre | post | budget-config | reader | manager | kat [<path>] | stamp [--check] | version");
            2
        }
    };
    std::process::exit(code);
}
