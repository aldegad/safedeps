//! The guard's judgment core, past the lexer: the payload readers, the install
//! recognizers, the pipe checks, the statement split, the kind of each
//! statement (the part of the landing that says whether the effect gate reads
//! it), the spec extractor, and the driver that runs them per reading.
//!
//! Each function stands for the shell function named in its comment, and the
//! shell's own plumbing is followed where it decides a result: a command
//! substitution drops trailing newlines, a here-string adds one, `read` splits
//! fields by its IFS rules and reads one line. Those are where a port that
//! "means the same" would differ, so they are written out.

use crate::ere::Regex;
use crate::extract::{self, XRegexes};
use crate::grammar;
use crate::lex::{self, Lex, Reading};
use crate::manager::{self, Reader, Regexes};

type W = Vec<u8>;

pub struct Core {
    pub g: lex::Grammar,
    pub mrx: Regexes,
    pub x: XRegexes,
    install_re: Regex,
    pipe_install_text: Regex,
    pipe_shell_consumer: Regex,
    pipe_compound: Regex,
    eco: Vec<(&'static str, Regex)>,
}

pub const PIPE_MANAGER_RE: &str = "(npm|npx|pnpm|pnpx|yarn|bun|bunx|pip[0-9.]*|(python[0-9.]*|py)[[:space:]]+-[A-Za-z0-9]*m[[:space:]]*pip|poetry|uv|uvx|pipx|pipenv|cargo|go|gem|bundle|mvn|dotnet)";
pub const PIPE_COMPOUND_CONSUMER_RE: &str = "(^|[^|])\\|&?[[:space:]]*([({]|(if|while|until|for|select|case|time|!)([[:space:]]|$))";

impl Core {
    pub fn new() -> Core {
        let p = grammar::patterns();
        let start = grammar::START;
        let end = &p.end;
        let eco = vec![
            ("npm", format!("{}(npm|pnpm|pnpx|yarn|npx|bun|bunx){}", start, end)),
            ("pypi", format!("{}(pip[0-9.]*|poetry|uv|uvx|pipx|pipenv|(python[0-9.]*|py){}[[:space:]]+-[A-Za-z0-9]*m[[:space:]]*pip){}", start, grammar::OPTS, end)),
            ("crates.io", format!("{}cargo{}", start, end)),
            ("go", format!("{}go{}", start, end)),
            ("rubygems", format!("{}(gem|bundle){}", start, end)),
            ("maven", format!("{}mvn{}", start, end)),
            ("nuget", format!("{}dotnet{}", start, end)),
        ]
        .into_iter()
        .map(|(k, r)| (k, Regex::new(&r, true).expect("eco regex")))
        .collect();
        let exre = format!("^({}|{})$", grammar::EXECUTABLES, grammar::SHELLS);
        let shre = format!("^({})$", grammar::SHELLS);
        Core {
            g: lex::Grammar {
                exre: Some(Regex::new(&exre, false).unwrap()),
                shre: Some(Regex::new(&shre, false).unwrap()),
            },
            mrx: Regexes::new(),
            x: XRegexes::new(),
            install_re: Regex::new(&p.install_re, true).expect("install pattern"),
            pipe_install_text: Regex::new(&format!("{}.*({})", PIPE_MANAGER_RE, p.all_verbs), true).unwrap(),
            pipe_shell_consumer: Regex::new(
                &format!("(^|[^|])\\|&?[[:space:]]*([({{;][[:space:]]*)*({})([[:space:];&|)}}<>`]|$)", grammar::SHELLS),
                true,
            )
            .unwrap(),
            pipe_compound: Regex::new(PIPE_COMPOUND_CONSUMER_RE, false).unwrap(),
            eco,
        }
    }
}

/// `$(...)`: the output with its trailing newlines removed.
fn subst(mut v: W) -> W {
    while v.last() == Some(&b'\n') {
        v.pop();
    }
    v
}

/// The lines `while read` reads from `<<< "$s"`: `$s` and a newline.
fn herestring_lines(s: &[u8]) -> Vec<&[u8]> {
    s.split(|&b| b == b'\n').collect()
}

/// The lines `while read` reads from a stream: a final line with no newline
/// is read, an empty one after the last newline is not.
fn stream_lines(s: &[u8]) -> Vec<&[u8]> {
    let mut v: Vec<&[u8]> = s.split(|&b| b == b'\n').collect();
    if s.last() == Some(&b'\n') || s.is_empty() {
        v.pop();
    }
    v
}

fn has_nonspace(s: &[u8]) -> bool {
    s.iter().any(|&b| !matches!(b, b' ' | b'\t' | b'\n' | 0x0b | 0x0c | b'\r'))
}

/// bash `IFS=<ifs> read -r v1 ... vn` on one line.
pub fn read_fields(line: &[u8], ifs: &[u8], n: usize) -> Vec<W> {
    let ws = |b: u8| ifs.contains(&b) && matches!(b, b' ' | b'\t' | b'\n');
    let nws = |b: u8| ifs.contains(&b) && !matches!(b, b' ' | b'\t' | b'\n');
    let mut out: Vec<W> = Vec::new();
    let mut p = 0;
    while p < line.len() && ws(line[p]) {
        p += 1;
    }
    while out.len() + 1 < n {
        if p >= line.len() {
            break;
        }
        let s = p;
        while p < line.len() && !ifs.contains(&line[p]) {
            p += 1;
        }
        out.push(line[s..p].to_vec());
        if p < line.len() {
            if ws(line[p]) {
                while p < line.len() && ws(line[p]) {
                    p += 1;
                }
                if p < line.len() && nws(line[p]) {
                    p += 1;
                    while p < line.len() && ws(line[p]) {
                        p += 1;
                    }
                }
            } else {
                p += 1;
                while p < line.len() && ws(line[p]) {
                    p += 1;
                }
            }
        }
    }
    if out.len() + 1 == n || (n == 1 && out.is_empty()) {
        let mut e = line.len();
        while e > p && ws(line[e - 1]) {
            e -= 1;
        }
        // When exactly one field remains, read assigns that word, without
        // its separator. With more fields than names it keeps the complete
        // remainder instead: IFS=: read a on a: -> a, on a:: -> a::.
        let word_end=(p..line.len()).find(|&i|ifs.contains(&line[i])).unwrap_or(line.len());
        let mut next=word_end;
        if next<line.len() {
            if ws(line[next]) {
                while next<line.len()&&ws(line[next]){next+=1}
                if next<line.len()&&nws(line[next]){next+=1}
            }else{next+=1}
            while next<line.len()&&ws(line[next]){next+=1}
        }
        if next==line.len(){e=word_end;}
        out.push(if p <= e { line[p..e].to_vec() } else { W::new() });
    }
    while out.len() < n {
        out.push(W::new());
    }
    out
}

/// bash `IFS=<c> read -ra a <<< "$s"` for a non-blank separator: the first
/// line cut at every separator, a trailing one giving no empty field.
pub(crate) fn read_array(s: &[u8], sep: u8) -> Vec<W> {
    let line = s.split(|&b| b == b'\n').next().unwrap_or(b"");
    if line.is_empty() {
        return vec![];
    }
    let mut v: Vec<W> = line.split(|&b| b == sep).map(|x| x.to_vec()).collect();
    if line.last() == Some(&sep) {
        v.pop();
    }
    v
}

/// Words as `( ${x} )` splits them with the default IFS.
pub(crate) fn ifs_words(s: &[u8]) -> Vec<W> {
    s.split(|&b| b == b' ' || b == b'\t' || b == b'\n').filter(|w| !w.is_empty()).map(|w| w.to_vec()).collect()
}

/// One guard run's shared state: the reading, the divergence file and the
/// scan mark.
pub struct Run<'c> {
    pub c: &'c Core,
    pub reading: Option<Reading>,
    pub diverge: bool,
    pub failed: bool,
}

pub struct TargetStatement {
    pub before: W, pub text: W, pub after: W, pub tokens: Vec<W>,
    pub words: W, pub uwords: W, pub rec: W,
}
impl TargetStatement {
    pub fn fields(&self)->W { [self.rec.as_slice(), &[0x1f], &self.uwords].concat() }
    pub fn manager_words(&self)->Vec<W> {
        ifs_words(&self.words.iter().map(|&b|if b"(){}".contains(&b){b' '}else{b}).collect::<W>())
    }
}

pub struct Facts {
    pub records: Vec<(String, W)>,
    pub hidden: [bool; 3],
    pub piped: bool,
}

pub use crate::lex::{Payload, PayloadOrigin};

impl<'c> Run<'c> {
    pub fn new(c: &'c Core) -> Run<'c> {
        Run { c, reading: None, diverge: false, failed: false }
    }

    /// `shell_lex <text> <view>`: None where the shell function returns 1.
    pub fn lex(&mut self, text: &[u8], view: &str) -> Option<W> {
        self.lex_unterm(text, view).0
    }

    fn lex_unterm(&mut self, text: &[u8], view: &str) -> (Option<W>, bool) {
        let Some(rd) = self.reading else {
            self.failed = true;
            return (None, false);
        };
        let r = Lex::new(&self.c.g, text, view, rd).run();
        match r {
            Ok((out, side)) => {
                if side.smfail {
                    self.failed = true;
                }
                if side.diverge {
                    self.diverge = true;
                }
                (Some(out), side.unterm)
            }
            Err((_, side)) => {
                if side.smfail {
                    self.failed = true;
                }
                if side.diverge {
                    self.diverge = true;
                }
                self.failed = true;
                (None, side.unterm)
            }
        }
    }

    // ---- payloads -------------------------------------------------------------
    fn payload_build(&mut self, text: &[u8], units: &[W]) -> W {
        let mut out = W::new();
        for tok in units {
            if let Some((a, n)) = parse_range(tok) {
                if a + n - 1 > text.len() as u64 {
                    self.failed = true;
                    continue;
                }
                out.extend_from_slice(&text[(a - 1) as usize..(a - 1 + n) as usize]);
            } else if let Some(bytes) = parse_codes(tok) {
                out.extend_from_slice(&bytes);
            } else {
                self.failed = true;
            }
        }
        out
    }

    /// The texts `text` hands on at its own top level, each with where its
    /// bytes stand in `text`: the scripts it gives `sh -c` and `eval` (the
    /// cscripts view) and the bodies of its substitutions (the substs view).
    /// One level: a substitution nested in another substitution is returned
    /// only when this is called on the enclosing payload. Order is cscripts
    /// first, then substitutions, in input-start order within each group.
    /// Bodies use the same units as the text views, but preserve the source
    /// map before compression. Arithmetic itself is not a payload.
    pub fn payloads(&mut self, text: &[u8]) -> Vec<Payload> {
        let Some(rd) = self.reading else { self.failed = true; return Vec::new(); };
        let mut res = Vec::new();
        for view in ["cscripts", "substs"] {
            match Lex::new(&self.c.g, text, view, rd).run_payloads() {
                Ok((mut payloads, side)) => {
                    self.failed |= side.smfail;
                    self.diverge |= side.diverge;
                    res.append(&mut payloads);
                }
                Err((_, side)) => { self.failed = true; self.diverge |= side.diverge; }
            }
        }
        res
    }

    /// The statements of `text`'s own top level and where their words stand
    /// (`lex::Pieces`), and whether the text ends inside a quote or a
    /// construct (the lexer's UNTERM). None where the lexing fails, which is
    /// a failed reading.
    pub fn pieces(&mut self, text: &[u8]) -> Option<(lex::Pieces, bool)> {
        let Some(rd) = self.reading else {
            self.failed = true;
            return None;
        };
        match Lex::new(&self.c.g, text, "pieces", rd).run_pieces() {
            Ok((p, side)) => {
                if side.smfail {
                    self.failed = true;
                }
                if side.diverge {
                    self.diverge = true;
                }
                Some((p, side.unterm))
            }
            Err((_, side)) => {
                if side.diverge {
                    self.diverge = true;
                }
                self.failed = true;
                None
            }
        }
    }

    /// `lex_payloads`: (kind, payload) for each record.
    fn lex_payloads(&mut self, text: &[u8], view: &str) -> Vec<(u8, W)> {
        let Some(out) = self.lex(text, view) else { return vec![] };
        let out = subst(out);
        let mut res = Vec::new();
        for rec in herestring_lines(&out) {
            if rec.is_empty() {
                continue;
            }
            if rec == b"!" {
                self.failed = true;
                continue;
            }
            if rec.iter().any(|&b| !(b"BSE:# ".contains(&b) || b.is_ascii_digit())) || !matches!(rec[0], b'B' | b'S' | b'E') {
                self.failed = true;
                continue;
            }
            let units = ifs_words(&rec[1..]);
            let p = self.payload_build(text, &units);
            res.push((rec[0], p));
        }
        res
    }

    fn read_payload_scripts(&mut self, text: &[u8], kind: u8, depth: u32, acc: &mut Vec<W>) {
        let ps = self.lex_payloads(text, "cscripts");
        for (k, t) in ps {
            if k == kind {
                acc.push(t.clone());
            }
            if depth < 3 {
                self.read_payload_scripts(&t, kind, depth + 1, acc);
            }
        }
    }

    fn shell_c_payloads(&mut self, text: &[u8]) -> Vec<W> {
        let mut acc = Vec::new();
        self.read_payload_scripts(text, b'S', 0, &mut acc);
        acc
    }
    fn eval_payloads(&mut self, text: &[u8]) -> Vec<W> {
        let mut acc = Vec::new();
        self.read_payload_scripts(text, b'E', 0, &mut acc);
        acc
    }
    fn subst_payloads(&mut self, text: &[u8]) -> Vec<W> {
        self.lex_payloads(text, "substs").into_iter().map(|(_, p)| p).collect()
    }

    /// `command_payload_raw_texts`.
    pub fn raw_texts(&mut self, text: &[u8]) -> Vec<W> {
        let mut queue: Vec<(W, u32)> = vec![(text.to_vec(), 0)];
        let mut found = Vec::new();
        let mut i = 0;
        while i < queue.len() {
            let (t, d) = queue[i].clone();
            i += 1;
            for k in ["cscripts", "substs"] {
                for (_, p) in self.lex_payloads(&t, k) {
                    found.push(p.clone());
                    if d < 3 {
                        queue.push((p, d + 1));
                    }
                }
            }
        }
        found
    }

    // ---- recognizers ------------------------------------------------------------
    fn start_text(&mut self, text: &[u8]) -> W {
        self.lex(text, "recognize").unwrap_or_default()
    }

    /// `command_candidate_start_texts`.
    pub fn candidate_texts(&mut self, text: &[u8]) -> W {
        let mut out = self.start_text(text);
        out.push(b'\n');
        for p in self.raw_texts(text) {
            if !has_nonspace(&p) {
                continue;
            }
            out.extend_from_slice(&self.start_text(&p));
            out.push(b'\n');
        }
        out
    }

    /// `recognized_dependency_install "$texts"`, the texts as a here-string.
    pub fn recognized(&self, texts: &[u8]) -> bool {
        self.c.install_re.grep_any(texts)
    }

    pub fn is_install(&mut self, text: &[u8]) -> bool {
        let t = subst(self.candidate_texts(text));
        self.recognized(&t)
    }

    // ---- pipes into a shell ------------------------------------------------------
    fn payload_pipes(&mut self, p: &[u8]) -> bool {
        if !p.contains(&b'|') {
            return false;
        }
        if !self.c.pipe_install_text.grep_any(p) {
            return false;
        }
        let ev = subst(self.start_text(p));
        let flat: W = ev.iter().map(|&b| if b == b'\n' { b' ' } else { b }).collect();
        if self.c.pipe_shell_consumer.grep_any(&flat) {
            return true;
        }
        if !self.c.pipe_compound.grep_any(&flat) {
            return false;
        }
        compound_consumer_runs_shell(&ev)
    }

    pub fn pipes_install_to_shell(&mut self, cmd: &[u8]) -> bool {
        if self.payload_pipes(cmd) {
            return true;
        }
        for p in self.raw_texts(cmd) {
            if p.is_empty() {
                continue;
            }
            if self.payload_pipes(&p) {
                return true;
            }
        }
        false
    }

    pub fn hides_install(&mut self, cmd: &[u8]) -> bool {
        if self.payload_pipes(cmd) {
            return true;
        }
        for p in self.shell_c_payloads(cmd) {
            if p.is_empty() {
                continue;
            }
            if self.payload_pipes(&p) {
                return true;
            }
        }
        for p in self.eval_payloads(cmd) {
            if p.is_empty() {
                continue;
            }
            if self.is_install(&p) || self.payload_pipes(&p) {
                return true;
            }
        }
        for p in self.subst_payloads(cmd) {
            if p.is_empty() {
                continue;
            }
            if self.is_install(&p) || self.payload_pipes(&p) {
                return true;
            }
        }
        false
    }

    /// `guard_check_command_reads`: whether the command closes.
    pub fn command_reads(&mut self, cmd: &[u8]) -> bool {
        let (_, unterm) = self.lex_unterm(cmd, "scan");
        !unterm
    }

    // ---- statements ---------------------------------------------------------------
    /// `command_statements`: the records it prints, one per line.
    pub fn statements(&mut self, cmd: &[u8]) -> W {
        let cuts = self.lex(cmd, "stmtcuts").unwrap_or_default();
        let raw = self.lex(cmd, "stmtraw").unwrap_or_default();
        statements_of(&cuts, &raw)
    }

    /// Statement and piece fields from the same original command, joined by
    /// their lexer ordinal. Both the pure facts and pre's disk questions use
    /// this structure; neither lexes a reconstructed statement.
    pub fn target_statements(&mut self, cmd: &[u8]) -> Vec<TargetStatement> {
        let statements = subst(self.statements(cmd));
        let pieces = subst(self.lex(cmd, "pieces").unwrap_or_default());
        let mut words: std::collections::HashMap<usize, W> = Default::default();
        let mut uwords: std::collections::HashMap<usize, W> = Default::default();
        let mut recs: std::collections::HashMap<usize, W> = Default::default();
        for line in herestring_lines(&pieces) {
            let f = read_fields(line, &[0x1f], 5);
            if f[0] == b"!" {
                self.failed = true;
                continue;
            }
            if f[0].is_empty() || !f[0].iter().all(|b| b.is_ascii_digit()) {
                continue;
            }
            let Ok(n) = std::str::from_utf8(&f[0]).unwrap_or("x").parse::<usize>() else { continue };
            words.insert(n, f[2].clone());
            uwords.insert(n, f[3].clone());
            recs.insert(n, f[4].clone());
        }
        herestring_lines(&statements).into_iter().enumerate().map(|(i,line)| {
            let f=read_fields(line, &[0x1d], 5);
            let n=i+1;
            TargetStatement { before:f[0].clone(), text:f[1].clone(), after:f[2].clone(),
                tokens:read_array(&f[3],0x1f), words:words.remove(&n).unwrap_or_default(),
                uwords:uwords.remove(&n).unwrap_or_default(), rec:recs.remove(&n).unwrap_or_default() }
        }).collect()
    }

    /// Pure target kinds used by the command facts; disk answers belong to pre.
    pub fn targets(&mut self, cmd: &[u8]) -> Vec<(String, W)> {
        let statements=self.target_statements(cmd);
        let mut out = Vec::new();
        let mut rd = Reader::new(&self.c.mrx);
        for statement in statements {
            let mut kind = "-".to_string();
            'one: loop {
                let mut toks = statement.tokens.clone();
                if toks.is_empty() {
                    break;
                }
                while !toks.is_empty() {
                    let h = &toks[0];
                    let s = h.iter().position(|&b| !matches!(b, b'(' | b'{' | b'!')).unwrap_or(h.len());
                    let head = h[s..].to_vec();
                    match head.as_slice() {
                        b"if" | b"while" | b"until" | b"" | b"then" | b"do" | b"else" | b"elif" | b"time" => {
                            toks.remove(0);
                        }
                        _ => {
                            toks[0] = head;
                            break;
                        }
                    }
                }
                if toks.is_empty() {
                    break;
                }
                match toks[0].as_slice() {
                    b"cd" | b"pushd" | b"popd" | b"export" | b"declare" | b"typeset" | b"local" | b"readonly" | b"unset" | b"source"
                    | b"." | b"eval" | b"set" => break 'one,
                    _ => {}
                }
                if assign_word(&toks[0]) && toks.iter().all(|t| assign_word(t)) {
                    break;
                }
                let rec = &statement.rec;
                if !self.recognized(&rec) {
                    break;
                }
                let pw = &statement.words;
                let pw: W = pw.iter().map(|&b| if matches!(b, b'(' | b')' | b'{' | b'}') { b' ' } else { b }).collect();
                let mw = ifs_words(&pw);
                kind = "other".into();
                if !mw.is_empty() {
                    rd.read(&mw);
                    if rd.family == "npm" && (rd.kind == "install" || rd.kind == "link") {
                        kind = "npm".into();
                    }
                }
                if kind != "npm" {
                    break;
                }
                if rd.kind == "link" {
                    kind = "npm-unrecorded".into();
                }
                break;
            }
            // The caller reads these from the resolver's five-field record.
            // In particular, a sole final record separator is consumed by
            // read, even when it came from a quoted byte in the command.
            let record=[b"\x1d\x1d\x1d\x1d".as_slice(),&statement.fields()].concat();
            let fields=read_fields(&record,&[0x1d],5).pop().unwrap_or_default();
            out.push((kind, fields));
        }
        out
    }

    /// `guard_detect_ecosystem`.
    pub fn detect_ecosystem(&mut self, cmd: &[u8]) -> String {
        let texts = self.candidate_texts(cmd);
        let t: W = texts.iter().map(|&b| if matches!(b, b';' | b'|' | b'&') { b'\n' } else { b }).collect();
        for seg in stream_lines(&t) {
            if !has_nonspace(seg) {
                continue;
            }
            if !self.recognized(seg) {
                continue;
            }
            for (name, re) in &self.c.eco {
                if re.grep_any(seg) {
                    return name.to_string();
                }
            }
        }
        String::new()
    }

    /// `guard_extract_pieces` then `guard_extract_specs ... readings`.
    pub fn extract_specs(&mut self, cmd: &[u8], targets: &[(String, W)]) -> W {
        let mut lines: Vec<(bool, W, W)> = Vec::new();
        let mut piece_lines: Vec<W> = Vec::new();
        for (kind, fields) in targets {
            if kind.is_empty() {
                continue;
            }
            let mut l = if kind == "npm" { b"true\t".to_vec() } else { b"false\t".to_vec() };
            l.extend_from_slice(fields);
            piece_lines.push(l);
        }
        for p in self.raw_texts(cmd) {
            if !has_nonspace(&p) {
                continue;
            }
            let pieces = subst(self.lex(&p, "pieces").unwrap_or_default());
            for line in herestring_lines(&pieces) {
                if line == b"!" {
                    self.failed = true;
                    continue;
                }
                let f: Vec<&[u8]> = line.split(|&b| b == 0x1f).collect();
                if f.len() >= 5 {
                    let mut l = b"false\t".to_vec();
                    l.extend_from_slice(f[4]);
                    l.push(0x1f);
                    l.extend_from_slice(f[3]);
                    piece_lines.push(l);
                }
            }
        }
        for l in &piece_lines {
            for sub in stream_lines(&[l.as_slice(), b"\n"].concat()) {
                let f = read_fields(sub, b"\t\x1f", 3);
                lines.push((f[0] == b"true", f[1].clone(), f[2].clone()));
            }
        }
        let mut out = W::new();
        let mut rd = Reader::new(&self.c.mrx);
        for (gate_reads, seg, words) in lines {
            if !has_nonspace(&seg) {
                continue;
            }
            if !self.recognized(&seg) {
                continue;
            }
            extract::extract_statement(&self.c.x, &mut rd, gate_reads, &words, &mut out);
        }
        out
    }

    // ---- the driver -------------------------------------------------------------------
    pub fn facts(&mut self, cmd: &[u8]) -> Facts {
        self.facts_with(cmd, |run| run.targets(cmd))
    }

    /// One reading driver for the pure comparison and the pre hook. The
    /// caller supplies the target records; detection, spec extraction and
    /// bringing in diverging readings remain the same operation.
    pub fn facts_with(&mut self, cmd: &[u8], mut resolve: impl FnMut(&mut Self) -> Vec<(String, W)>) -> Facts {
        let mut rec: Vec<(String, W)> = Vec::new();
        let mut set: Vec<Reading> = Vec::new();
        let mut closed = false;
        let mut any = false;
        let mut piped = false;
        let mut hidden = [false; 3];
        let idx = |r: Reading| match r {
            Reading::Bash => 0,
            Reading::Zsh => 1,
            Reading::Dash => 2,
        };
        let name = |r: Reading| match r {
            Reading::Bash => "bash",
            Reading::Zsh => "zsh",
            Reading::Dash => "dash",
        };
        let mut detect = |run: &mut Run, r: Reading, set: &mut Vec<Reading>, closed: &mut bool, any: &mut bool, piped: &mut bool, hidden: &mut [bool; 3]| {
            run.reading = Some(r);
            set.push(r);
            if run.command_reads(cmd) {
                *closed = true;
            }
            if run.is_install(cmd) {
                *any = true;
                if run.pipes_install_to_shell(cmd) {
                    *piped = true;
                    hidden[idx(r)] = true;
                }
            } else if run.hides_install(cmd) {
                *any = true;
                hidden[idx(r)] = true;
            }
            run.reading = None;
        };
        detect(self, Reading::Bash, &mut set, &mut closed, &mut any, &mut piped, &mut hidden);
        if self.diverge {
            detect(self, Reading::Zsh, &mut set, &mut closed, &mut any, &mut piped, &mut hidden);
            detect(self, Reading::Dash, &mut set, &mut closed, &mut any, &mut piped, &mut hidden);
        }
        if !closed {
            self.failed = true;
        }
        let tf = |b: bool| if b { b"true".to_vec() } else { b"false".to_vec() };
        let setname = |set: &Vec<Reading>| set.iter().map(|&r| name(r)).collect::<Vec<_>>().join(" ").into_bytes();
        rec.push(("reading_set".into(), setname(&set)));
        rec.push(("closed".into(), tf(closed)));
        rec.push(("any_install".into(), tf(any)));
        rec.push(("hidden".into(), format!("{} {} {}", hidden[0], hidden[1], hidden[2]).into_bytes()));
        rec.push(("piped".into(), tf(piped)));
        rec.push(("failed.detect".into(), tf(self.failed)));
        if !any {
            return Facts { records: rec, hidden, piped };
        }
        struct Per {
            eco: String,
            targets: W,
            readings: W,
        }
        let mut per: Vec<(Reading, Per)> = Vec::new();
        let mut ledger_eco = String::new();
        let mut ledger_specs: Vec<W> = Vec::new();
        let mut unreduced = false;
        let mut facts_of = |run: &mut Self, r: Reading, per: &mut Vec<(Reading, Per)>, hidden: &[bool; 3]| {
            run.reading = Some(r);
            let targets = resolve(run);
            let eco = run.detect_ecosystem(cmd);
            if ledger_eco.is_empty() {
                ledger_eco = eco.clone();
            }
            let lines = run.extract_specs(cmd, &targets);
            let mut readings = W::new();
            let mut specs = 0;
            for line in stream_lines(&lines) {
                if line.is_empty() {
                    continue;
                }
                readings.extend_from_slice(line);
                readings.push(b'\n');
                if line.starts_with(b"S\t") || line.starts_with(b"O\t") || line.starts_with(b"@\t") {
                    continue;
                }
                specs += 1;
                if !ledger_specs.iter().any(|s| s.as_slice() == line) {
                    ledger_specs.push(line.to_vec());
                }
            }
            if hidden[idx(r)] && (eco.is_empty() || specs == 0) {
                unreduced = true;
            }
            let mut t = W::new();
            for (k, f) in &targets {
                t.extend_from_slice(k.as_bytes());
                t.push(0x1d);
                t.extend_from_slice(f);
                t.push(b'\n');
            }
            per.push((r, Per { eco, targets: t, readings }));
            run.reading = None;
        };
        let first: Vec<Reading> = set.clone();
        for r in first {
            facts_of(self, r, &mut per, &hidden);
        }
        if set.len() == 1 && self.diverge {
            for r in [Reading::Zsh, Reading::Dash] {
                detect(self, r, &mut set, &mut closed, &mut any, &mut piped, &mut hidden);
                facts_of(self, r, &mut per, &hidden);
            }
        }
        rec.push(("reading_set.facts".into(), setname(&set)));
        for (r, p) in &per {
            rec.push((format!("eco.{}", name(*r)), p.eco.clone().into_bytes()));
            rec.push((format!("targets.{}", name(*r)), p.targets.clone()));
            rec.push((format!("readings.{}", name(*r)), p.readings.clone()));
        }
        rec.push(("hidden_unreduced".into(), tf(unreduced)));
        rec.push(("ledger_eco".into(), ledger_eco.into_bytes()));
        let mut ls = W::new();
        for s in &ledger_specs {
            ls.extend_from_slice(s);
            ls.push(b'\n');
        }
        rec.push(("ledger_specs".into(), ls));
        rec.push(("failed.facts".into(), tf(self.failed)));
        Facts { records: rec, hidden, piped }
    }
}

/// `^([1-9][0-9]{0,8}):([1-9][0-9]{0,8})$`
fn parse_range(t: &[u8]) -> Option<(u64, u64)> {
    let c = t.iter().position(|&b| b == b':')?;
    let num = |s: &[u8]| -> Option<u64> {
        if s.is_empty() || s.len() > 9 || s[0] == b'0' || !s.iter().all(|b| b.is_ascii_digit()) {
            return None;
        }
        std::str::from_utf8(s).ok()?.parse().ok()
    };
    Some((num(&t[..c])?, num(&t[c + 1..])?))
}

/// `#c#c...`, each code 1-127 with no leading zero.
fn parse_codes(t: &[u8]) -> Option<W> {
    if t.len() < 2 || t[0] != b'#' || !t[1].is_ascii_digit() {
        return None;
    }
    if !t.iter().all(|&b| b == b'#' || b.is_ascii_digit()) || t.windows(2).any(|w| w == b"##") || t.last() == Some(&b'#') {
        return None;
    }
    let mut out = W::new();
    for code in t[1..].split(|&b| b == b'#') {
        if code[0] == b'0' || code.len() > 3 {
            return None;
        }
        let v: u32 = std::str::from_utf8(code).ok()?.parse().ok()?;
        if !(1..=127).contains(&v) {
            return None;
        }
        out.push(v as u8);
    }
    Some(out)
}

/// `^[A-Za-z_][A-Za-z0-9_]*\+?=`
fn assign_word(t: &[u8]) -> bool {
    if t.is_empty() || !(t[0].is_ascii_alphabetic() || t[0] == b'_') {
        return false;
    }
    let mut p = 1;
    while p < t.len() && (t[p].is_ascii_alphanumeric() || t[p] == b'_') {
        p += 1;
    }
    if p < t.len() && t[p] == b'+' {
        p += 1;
    }
    p < t.len() && t[p] == b'='
}

/// The awk of `command_statements`, over the stmtcuts and stmtraw views as
/// it reads them back from its files: one trailing newline of each is lost
/// to awk's line reading, and a byte past the end reads as the empty string.
pub fn statements_of(cuts_view: &[u8], raw_view: &[u8]) -> W {
    let (first, rest) = match cuts_view.iter().position(|&b| b == b'\n') {
        Some(p) => (&cuts_view[..p], &cuts_view[p + 1..]),
        None => (cuts_view, &b""[..]),
    };
    let mut cut = std::collections::HashSet::new();
    for t in String::from_utf8_lossy(first).split_whitespace() {
        cut.insert(lex_num(t));
    }
    let strip1 = |v: &[u8]| -> W {
        let mut v = v.to_vec();
        if v.last() == Some(&b'\n') {
            v.pop();
        }
        v
    };
    let c = strip1(rest);
    let r = strip1(raw_view);
    let n = c.len() as i64;
    let rb = |i: i64| -> Option<u8> {
        if i >= 1 && (i as usize) <= r.len() {
            Some(r[(i - 1) as usize])
        } else {
            None
        }
    };
    let cb = |i: i64| -> Option<u8> {
        if i >= 1 && (i as usize) <= c.len() {
            Some(c[(i - 1) as usize])
        } else {
            None
        }
    };
    let wb = |ch: Option<u8>| -> Option<u8> {
        match ch {
            Some(0x1f) | Some(0x1d) => Some(0x02),
            x => x,
        }
    };
    let words_of = |from: i64, to: i64| -> W {
        let mut words = W::new();
        let mut wne = false;
        let mut word = W::new();
        let mut has = false;
        let mut dyn_ = false;
        let mut q = 0u8;
        let mut word_end = |words: &mut W, word: &mut W, has: &mut bool, dyn_: &mut bool, wne: &mut bool| {
            if *has {
                let mut piece = W::new();
                if *wne {
                    piece.push(0x1f);
                }
                piece.extend_from_slice(word);
                if *dyn_ {
                    piece.push(0x01);
                }
                words.extend_from_slice(&piece);
                if !piece.is_empty() {
                    *wne = true;
                }
            }
            word.clear();
            *has = false;
            *dyn_ = false;
        };
        let mut i = from;
        while i <= to {
            let ch = wb(rb(i));
            if ch == Some(0x01) {
                i += 1;
                continue;
            }
            if q == 0 {
                if matches!(ch, Some(b' ') | Some(b'\t') | Some(b'\n')) {
                    word_end(&mut words, &mut word, &mut has, &mut dyn_, &mut wne);
                    i += 1;
                    continue;
                }
                if ch == Some(b'\\') {
                    if i < to {
                        i += 1;
                        if rb(i) != Some(0x01) {
                            if let Some(b) = wb(rb(i)) {
                                word.push(b);
                            }
                        }
                        has = true;
                    }
                    i += 1;
                    continue;
                }
                if ch == Some(b'\'') {
                    q = b's';
                    has = true;
                    i += 1;
                    continue;
                }
                if ch == Some(b'"') {
                    q = b'd';
                    has = true;
                    i += 1;
                    continue;
                }
                if matches!(ch, Some(b'$') | Some(b'`') | Some(b'*') | Some(b'?') | Some(b'[')) {
                    dyn_ = true;
                }
                if ch == Some(b'~') && !has {
                    dyn_ = true;
                }
                if let Some(b) = ch {
                    word.push(b);
                }
                has = true;
                i += 1;
                continue;
            }
            if q == b's' {
                if ch == Some(b'\'') {
                    q = 0;
                } else if let Some(b) = ch {
                    word.push(b);
                }
                i += 1;
                continue;
            }
            if ch == Some(b'\\') && i < to && matches!(rb(i + 1), Some(b'$') | Some(b'`') | Some(b'"') | Some(b'\\')) {
                i += 1;
                if let Some(b) = wb(rb(i)) {
                    word.push(b);
                }
                i += 1;
                continue;
            }
            if ch == Some(b'"') {
                q = 0;
                i += 1;
                continue;
            }
            if matches!(ch, Some(b'$') | Some(b'`')) {
                dyn_ = true;
            }
            let ch = if matches!(ch, Some(b'\n') | Some(b'\t')) { Some(b' ') } else { ch };
            if let Some(b) = ch {
                word.push(b);
            }
            i += 1;
        }
        word_end(&mut words, &mut word, &mut has, &mut dyn_, &mut wne);
        words
    };
    let raw_of = |from: i64, to: i64| -> W {
        let mut o = W::new();
        let mut i = from;
        while i <= to {
            match rb(i) {
                Some(0x01) | None => {}
                Some(b'\t') | Some(0x1d) | Some(0x1f) => o.push(b' '),
                Some(b'\n') => o.push(0x1e),
                Some(b) => o.push(b),
            }
            i += 1;
        }
        o
    };
    let mut out = W::new();
    let mut prev: W = b"start".to_vec();
    let mut cur = W::new();
    let mut from = 1i64;
    let mut emit = |out: &mut W, prev: &mut W, cur: &mut W, nx: &[u8], from: i64, to: i64| {
        let text: W = cur.iter().map(|&b| if b == b'\t' || b == 0x1d { b' ' } else { b }).collect();
        out.extend_from_slice(prev);
        out.push(0x1d);
        out.extend_from_slice(&text);
        out.push(0x1d);
        out.extend_from_slice(nx);
        out.push(0x1d);
        out.extend_from_slice(&words_of(from, to));
        out.push(0x1d);
        out.extend_from_slice(&raw_of(from, to));
        out.push(b'\n');
        *prev = nx.to_vec();
        cur.clear();
    };
    let mut i = 1i64;
    while i <= n {
        let ch = cb(i);
        if cut.contains(&i) {
            emit(&mut out, &mut prev, &mut cur, b";", from, i - 1);
            from = i;
        }
        if ch == Some(b';') || ch == Some(b'\n') {
            emit(&mut out, &mut prev, &mut cur, b";", from, i - 1);
            from = i + 1;
            i += 1;
            continue;
        }
        if ch == Some(b'&') {
            if cb(i + 1) == Some(b'&') {
                emit(&mut out, &mut prev, &mut cur, b"&&", from, i - 1);
                i += 1;
                from = i + 1;
                i += 1;
                continue;
            }
            emit(&mut out, &mut prev, &mut cur, b"&", from, i - 1);
            from = i + 1;
            i += 1;
            continue;
        }
        if ch == Some(b'|') {
            if cb(i + 1) == Some(b'|') {
                emit(&mut out, &mut prev, &mut cur, b"||", from, i - 1);
                i += 1;
                from = i + 1;
                i += 1;
                continue;
            }
            let to = i - 1;
            if cb(i + 1) == Some(b'&') {
                i += 1;
            }
            emit(&mut out, &mut prev, &mut cur, b"|", from, to);
            from = i + 1;
            i += 1;
            continue;
        }
        if let Some(b) = ch {
            cur.push(b);
        }
        i += 1;
    }
    emit(&mut out, &mut prev, &mut cur, b"end", from, n);
    out
}

fn lex_num(t: &str) -> i64 {
    let mut v: i64 = 0;
    for b in t.bytes() {
        if !b.is_ascii_digit() {
            break;
        }
        v = v * 10 + (b - b'0') as i64;
    }
    v
}

/// `compound_consumer_runs_shell`.
pub fn compound_consumer_runs_shell(text: &[u8]) -> bool {
    let mut rest: &[u8] = text;
    let mut stack: Vec<W> = Vec::new();
    let mut pend = false;
    let mut cmd = true;
    let mut skip = false;
    let is_graph = |b: u8| (0x21..=0x7e).contains(&b) || b >= 0x80;
    let is_space = |b: u8| matches!(b, b' ' | b'\t' | b'\n' | 0x0b | 0x0c | b'\r');
    let word_ch = |b: u8| !is_space(b) && !b";&|(){}<>".contains(&b);
    let is_shell = |t: &[u8]| t.eq_ignore_ascii_case(b"sh") || t.eq_ignore_ascii_case(b"bash") || t.eq_ignore_ascii_case(b"zsh");
    loop {
        let mut p = 0;
        while p < rest.len() && !is_graph(rest[p]) && rest[p] != b'\n' {
            p += 1;
        }
        let tlen;
        if p >= rest.len() {
            // A shorter skip can leave a control byte for the word
            // alternative; the longest skip that still matches leaves the
            // last byte alone.
            if p > 0 && word_ch(rest[p - 1]) {
                p -= 1;
                tlen = 1;
            } else {
                break;
            }
        } else {
            let s = &rest[p..];
            let mut best = 0usize;
            let ops: [&[u8]; 6] = [b"||", b"&&", b";;&", b";;", b";&", b"|&"];
            for o in ops {
                if s.starts_with(o) {
                    best = best.max(o.len());
                }
            }
            if b";&|(){}".contains(&s[0]) || s[0] == b'\n' {
                best = best.max(1);
            }
            let mut d = 0;
            while d < s.len() && s[d].is_ascii_digit() {
                d += 1;
            }
            let mut e = d;
            while e < s.len() && (s[e] == b'<' || s[e] == b'>') {
                e += 1;
            }
            if e > d {
                if e < s.len() && s[e] == b'&' {
                    e += 1;
                }
                best = best.max(e);
            }
            let mut wl = 0;
            while wl < s.len() && word_ch(s[wl]) {
                wl += 1;
            }
            best = best.max(wl);
            if best == 0 {
                break;
            }
            tlen = best;
        }
        let tok = rest[p..p + tlen].to_vec();
        rest = &rest[p + tlen..];
        let t = tok.as_slice();
        if skip && t != b"\n" {
            skip = false;
            continue;
        }
        if stack.is_empty() {
            match t {
                b"|" | b"|&" => pend = true,
                b"\n" | b";" => {}
                _ if t == b"!" || t == b"time" || t.first() == Some(&b'-') => {
                    if pend {
                        cmd = true;
                    }
                }
                b"{" | b"(" | b"if" | b"while" | b"until" => {
                    if pend {
                        stack = vec![t.to_vec()];
                        cmd = true;
                    }
                    pend = false;
                }
                b"for" | b"select" | b"case" => {
                    if pend {
                        stack = vec![t.to_vec()];
                        cmd = false;
                    }
                    pend = false;
                }
                _ if is_shell(t) => {
                    if pend {
                        return true;
                    }
                    pend = false;
                }
                _ => pend = false,
            }
            continue;
        }
        let top = stack.last().cloned().unwrap_or_default();
        match t {
            b"\n" | b";" | b"&" | b"&&" | b"||" | b"|" | b"|&" | b";;" | b";&" | b";;&" => {
                cmd = true;
                continue;
            }
            b"(" => {
                stack.push(b"(".to_vec());
                cmd = true;
                continue;
            }
            b")" => {
                if top == b"(" {
                    stack.pop();
                    cmd = false;
                } else {
                    cmd = true;
                }
                continue;
            }
            _ => {}
        }
        if (t.first().is_some_and(|b| b.is_ascii_digit()) && t[1..].iter().any(|&b| b == b'<' || b == b'>'))
            || matches!(t.first(), Some(b'<') | Some(b'>'))
        {
            skip = true;
            continue;
        }
        if !cmd {
            continue;
        }
        if is_shell(t) {
            return true;
        }
        match t {
            b"{" | b"if" | b"while" | b"until" => stack.push(t.to_vec()),
            b"for" | b"select" | b"case" => {
                stack.push(t.to_vec());
                cmd = false;
            }
            b"}" => {
                if top == b"{" {
                    stack.pop();
                }
                cmd = false;
            }
            b"fi" => {
                if top == b"if" {
                    stack.pop();
                }
                cmd = false;
            }
            b"done" => {
                if matches!(top.as_slice(), b"while" | b"until" | b"for" | b"select") {
                    stack.pop();
                }
                cmd = false;
            }
            b"esac" => {
                if top == b"case" {
                    stack.pop();
                }
                cmd = false;
            }
            b"then" | b"do" | b"else" | b"elif" | b"!" | b"time" => {}
            _ if t.first() == Some(&b'-') => {}
            _ if (t.first().is_some_and(|b| b.is_ascii_alphabetic() || *b == b'_')) && t.contains(&b'=') => {}
            _ => cmd = false,
        }
    }
    rest.iter().any(|&b| !is_space(b))
}

/// The records as `safedeps-core facts` prints them: `<key> <length>\n<bytes>\n`.
pub fn render(f: &Facts) -> W {
    let mut o = W::new();
    for (k, v) in &f.records {
        o.extend_from_slice(format!("{} {}\n", k, v.len()).as_bytes());
        o.extend_from_slice(v);
        o.push(b'\n');
    }
    o
}

pub fn command_of_payload(input: &[u8]) -> Option<(String, W)> {
    // The hook payload as JSON: tool_name and tool_input.command.
    let v = crate::json::parse(input).ok()?;
    let tool = v.get("tool_name").and_then(|x| x.as_str()).unwrap_or("").to_string();
    let cmd = v.get("tool_input").and_then(|t| t.get("command")).and_then(|x| x.as_bytes()).unwrap_or_default();
    Some((tool, cmd))
}

#[allow(dead_code)]
fn unused(_: &manager::Regexes) {}

#[cfg(test)]
mod field_tests {
    use super::read_fields;
    #[test]
    fn final_field_keeps_only_extra_separators() {
        // Bash 3.2 read -r, with a nonblank IFS and one/two destinations.
        for (input,one,two) in [
            ("a","a",["a",""]), ("a:","a",["a",""]),
            ("a::","a::",["a",""]), ("a:b:","a:b:",["a","b"]),
            ("a:b::","a:b::",["a","b::"]), ("a:b:c:","a:b:c:",["a","b:c:"]),
            (":","",["",""]), ("::","::",["",""]), ("a::b:","a::b:",["a",":b:"]),
        ] {
            assert_eq!(read_fields(input.as_bytes(),b":",1),vec![one.as_bytes().to_vec()],"one {input:?}");
            assert_eq!(read_fields(input.as_bytes(),b":",2),two.iter().map(|s|s.as_bytes().to_vec()).collect::<Vec<_>>(),"two {input:?}");
        }
        for (tail,expected) in [("\x1d",""),("\x1d\x1d","\x1d\x1d"),("a\x1d","a"),("a\x1db\x1d","a\x1db\x1d")] {
            let raw=format!("-\x1d\x1d\x1d\x1decho \x1fecho {tail}");
            assert_eq!(read_fields(raw.as_bytes(),&[0x1d],5)[4],format!("echo \x1fecho {expected}").as_bytes());
        }
    }
}
