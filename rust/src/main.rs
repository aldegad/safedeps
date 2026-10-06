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

mod core;
mod ere;
mod extract;
mod grammar;
mod json;
mod lex;
mod manager;
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

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let code = match args.get(1).map(|s| s.as_str()) {
        Some("lex") => cmd_lex(&args[2..]),
        Some("lex-batch") => cmd_lex_batch(),
        Some("grammar") => {
            print!("{}", grammar::dump());
            0
        }
        Some("grep") => cmd_grep(&args[2..]),
        Some("facts") => cmd_facts(),
        _ => {
            eprintln!("usage: safedeps-core lex <view> | lex-batch | grammar | grep [-i] [-n] <pattern>");
            2
        }
    };
    std::process::exit(code);
}
