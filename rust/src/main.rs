//! safedeps-core: the judgment core of the safedeps PreToolUse guard.
//!
//!   safedeps-core lex <view> [<marker>] [--divmemo FILE]
//!       One lexing, a drop-in for the guard's `shell_lex`: the text on
//!       stdin, the reading in SAFEDEPS_READING, the flags file in
//!       SAFEDEPS_LEX_FLAGS, the divergence file in SAFEDEPS_LEX_DIVERGE and
//!       the scan mark in SAFEDEPS_SCAN_MARK. The view on stdout. A reading
//!       that is not set is a failed reading (exit 1, `failed` on the mark),
//!       and so is a view no branch names (exit 2), as in the awk program.
//!   safedeps-core lex-batch
//!       Many lexings in one process, for the differential: records on stdin,
//!       `<reading> <view> <length>\n<bytes>`, answers on stdout,
//!       `<status> <unterm> <diverge> <smfail> <length>\n<bytes>`.
//!   safedeps-core grammar
//!       The grammar's values, `name=value` per line, for the drift check.
//!   safedeps-core grep [-i] [-n] <pattern>
//!       grep -E over stdin with this crate's engine, for the differential.
//!   safedeps-core facts
//!       The judgment facts of one hook payload (stdin), per reading: whether
//!       the command closes and installs, the statements' kinds, the
//!       ecosystem and the extractor's readings, as `<key> <length>\n<bytes>\n`
//!       records. The guard's own facts are dumped the same way by
//!       scripts/measure/core-facts-differential.py.
//!   safedeps-core words
//!       The statements of a text (stdin, the reading in SAFEDEPS_READING)
//!       with where their words stand, and its payloads with where their
//!       bytes stand: the structure the inert rewrite reads, as records, for
//!       the contract check.
//!   safedeps-core inert
//!       The inert rewrite of one hook payload (stdin). Not written yet.
//!   safedeps-core pre | post
//!       The PreToolUse and PostToolUse hooks. Not written yet: each exits 2.
//!   safedeps-core kat [<path>]
//!       Known answers from the modules the hooks share (the digests, the
//!       JSON writer, how a file's times and inodes are spelled), one per
//!       line, for a check against the tools the bash hooks use.
//!   safedeps-core stamp [--check]
//!       `<kind> <sha256>`: the kind of build (`checkout` or `publish`) and
//!       the digest of the source it was built from. With --check, whether a
//!       checkout's binary still stands beside that source: exit 0 and `ok`,
//!       or exit 1 and the reason.

// The modules marked `dead_code` are what the hooks being moved read (`pre`,
// `post`, `inert`): they are in the tree before their callers so that the
// people writing those callers share one copy. The mark goes when the caller
// lands.
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
        Some("inert") => match read_stdin() {
            Some(input) => inert::cli(&input),
            None => 1,
        },
        // The hooks take the subcommand and nothing else: no argument and no
        // environment variable chooses how one judges.
        Some("pre") if args.len() > 2 => {
            println!("{}", jq::deny("safedeps: the PreToolUse hook was started with an argument, and it takes none. Bash is blocked fail-closed until the hook is registered as safedeps installs it: node scripts/install/install-safedeps-hooks.mjs"));
            0
        }
        Some("pre") => match read_stdin() {
            Some(input) => pre::main(&input),
            None => 2,
        },
        Some("post") => match read_stdin() {
            Some(input) => post::main(&input),
            None => 2,
        },
        Some("ledger") => match read_stdin() {
            Some(input) => ledger::main(&args[2..], &input),
            None => 1,
        },
        Some("json-stream") => match read_stdin() {
            Some(input) => match json::parse_stream(&input) {
                Ok(values) => {
                    for value in values { println!("{}", jq::compact(&jq::from_value(&value))); }
                    0
                }
                Err(_) => 5,
            },
            None => 2,
        },
        Some("kat") => cmd_kat(&args[2..]),
        Some("stamp") => cmd_stamp(&args[2..]),
        Some("version") => {
            println!("safedeps-core {}", env!("CARGO_PKG_VERSION"));
            0
        }
        _ => {
            eprintln!("usage: safedeps-core lex <view> | lex-batch | grammar | grep [-i] [-n] <pattern> | facts | words | inert | pre | post | kat [<path>] | stamp [--check] | version");
            2
        }
    };
    std::process::exit(code);
}
