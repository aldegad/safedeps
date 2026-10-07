//! The guard's shell lexer, `shell_lex` in scripts/safedeps-pre-guard.sh,
//! carried over function by function.
//!
//! One pass over the command as the shell lexes it gives every byte a class,
//! the walk over the words (`starts`) gives the events where commands start,
//! and every view is printed from those. The awk program is the reference:
//! each function here has the name, the order of rules and the state of its
//! awk counterpart, so a view the two print differently is a defect in this
//! file, found by the differential (scripts/measure/core-lex-differential.sh).
//! The comments that say why a rule is there live in the awk program; the
//! ones here only say where this code has to differ from awk to mean the
//! same thing.
//!
//! awk semantics kept on purpose:
//! - every array is 1-based, and a read past either end is the empty string
//!   (byte 0 here), a value that matches no class;
//! - an array element that was never set compares unequal to every value, so
//!   `DEP[k] != 1` holds for a byte the walk never gave a depth;
//! - state left in a context slot by a context that closed stays there until
//!   the next push overwrites it, as awk's arrays keep it.

use crate::ere::Regex;
use std::collections::HashSet;
use std::io::Write;

type I = isize;

// Byte classes.
const UNSET: u8 = 0;

// Context kinds.
const T_TOP: u8 = b'T';

// Lexer modes.
const M_NONE: u8 = 0;
const M_SQ: u8 = 1;
const M_AQ: u8 = 2;
const M_CM: u8 = 3;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Reading {
    Bash,
    Zsh,
    Dash,
}

impl Reading {
    pub fn parse(s: &str) -> Option<Reading> {
        match s {
            "bash" => Some(Reading::Bash),
            "zsh" => Some(Reading::Zsh),
            "dash" => Some(Reading::Dash),
            _ => None,
        }
    }
    fn idx(self) -> usize {
        match self {
            Reading::Bash => 0,
            Reading::Zsh => 1,
            Reading::Dash => 2,
        }
    }
}

/// What one lexing produced besides its view.
#[derive(Default, Debug, Clone)]
pub struct Side {
    pub unterm: bool,
    pub diverge: bool,
    pub smfail: bool,
}

/// A view no branch names: the awk program exits 2 there, a failed reading.
#[derive(Debug)]
pub struct UnknownView;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PayloadOrigin {
    ShellC,
    Eval,
    EnvSplit,
    CommandSubstitution,
    Backquote,
    ProcessSubstitution,
}

/// A payload owns its original byte map before the textual views compress
/// ranges into character codes. Decoded and synthetic bytes alone have no
/// source position. An S payload also names the shell word that runs it;
/// callers must not infer ksh/bash/etc from the surrounding text again.
#[derive(Debug, Clone)]
pub struct Payload {
    pub kind: u8,
    pub text: Vec<u8>,
    pub src: Vec<Option<usize>>,
    pub origin: PayloadOrigin,
    pub shell: Option<Vec<u8>>,
}

/// One word of a statement, as the walk of the pieces view reads it: the
/// bytes of the text it is written with, quotes included, and its value with
/// the quoting removed. `start..end` is a range of the lexed text, from 0.
#[derive(Debug, Clone, PartialEq)]
pub struct WordSpan {
    pub start: usize,
    pub end: usize,
    pub value: Vec<u8>,
}

impl WordSpan {
    /// The word as the shell readers of the pieces view read it back. The
    /// view writes \002 for a blank, a parenthesis, a brace and the two record
    /// separators inside a word, and \002 alone for an empty word; its
    /// readers take \002 alone for an empty word and any other \002 for a
    /// space. So a word that is one such byte (`{`, `' '`) reads back empty.
    pub fn folded(&self) -> Vec<u8> {
        let fold = |b: u8| matches!(b, b' ' | b'\t' | b'\n' | b'(' | b')' | b'{' | b'}' | 0x1e | 0x1f);
        if self.value.len() == 1 && fold(self.value[0]) {
            return Vec::new();
        }
        self.value.iter().map(|&b| if fold(b) { b' ' } else { b }).collect()
    }
}

/// One statement of the text's own top level (a piece of the pieces view):
/// `start..end` in the lexed text, and its words with the prefixes the
/// recognizers strip and its redirections set aside, the command word first.
/// An operator that stands in the statement (a parenthesis, a `<`) is no
/// word.
#[derive(Debug, Clone, PartialEq)]
pub struct PieceSpan {
    pub nn: usize,
    pub start: usize,
    pub end: usize,
    pub words: Vec<WordSpan>,
}

/// The statements of a text with where their words stand. It is the pieces
/// view's own walk, so a word here is a word there. `unreadable` is that
/// view's `!` line: a `$'...'` escape whose value the lexer cannot name.
#[derive(Debug, Clone, Default)]
pub struct Pieces {
    pub pieces: Vec<PieceSpan>,
    pub unreadable: bool,
    /// The pieces view of the same lexing.
    pub view: Vec<u8>,
}

pub struct Grammar {
    /// `^(executables|shells)$`, matched against a lowercased word.
    pub exre: Option<Regex>,
    /// `^(shells)$`.
    pub shre: Option<Regex>,
}

fn is_sep(c: u8) -> bool {
    matches!(c, b' ' | b'\t' | b'\n' | b';' | b'&' | b'|' | b'(' | b')' | b'<' | b'>')
}
fn is_blank(c: u8) -> bool {
    c == b' ' || c == b'\t'
}
fn is_name_start(c: u8) -> bool {
    c.is_ascii_alphabetic() || c == b'_'
}
fn is_name(c: u8) -> bool {
    c.is_ascii_alphanumeric() || c == b'_'
}

/// A boolean array with awk's membership: `k in A`.
struct Mark(Vec<bool>);
impl Mark {
    fn new(n: usize) -> Mark {
        Mark(vec![false; n])
    }
    fn has(&self, k: I) -> bool {
        k >= 0 && (k as usize) < self.0.len() && self.0[k as usize]
    }
    fn set(&mut self, k: I) {
        if k >= 0 {
            let u = k as usize;
            if u >= self.0.len() {
                self.0.resize(u + 1, false);
            }
            self.0[u] = true;
        }
    }
    fn unset(&mut self, k: I) {
        if k >= 0 && (k as usize) < self.0.len() {
            self.0[k as usize] = false;
        }
    }
}

/// An integer array where an unset element is absent: `k in A`, `A[k]`.
struct Vals(Vec<Option<I>>);
impl Vals {
    fn new(n: usize) -> Vals {
        Vals(vec![None; n])
    }
    fn get(&self, k: I) -> Option<I> {
        if k >= 0 && (k as usize) < self.0.len() {
            self.0[k as usize]
        } else {
            None
        }
    }
    fn has(&self, k: I) -> bool {
        self.get(k).is_some()
    }
    fn set(&mut self, k: I, v: I) {
        if k >= 0 {
            let u = k as usize;
            if u >= self.0.len() {
                self.0.resize(u + 1, None);
            }
            self.0[u] = Some(v);
        }
    }
    /// The element as awk reads it in arithmetic: 0 when unset.
    fn num(&self, k: I) -> I {
        self.get(k).unwrap_or(0)
    }
}

#[derive(Clone, Default)]
struct Ctx {
    kind: u8,
    par: I,
    pnp: I,
    besc: I,
    cpat: I,
    cpw: I,
    adol: I,
    glc: I,
    cst: I,
    wkind: u8,
    sbr: I,
    sid: I,
}

struct Pending {
    pd: Vec<u8>,
    ps: bool,
    pq: bool,
    pstart: I,
    pb: bool,
    p_s: bool,
}

pub struct Lex<'g> {
    g: &'g Grammar,
    view: String,
    wends: bool,
    rd: Reading,
    shb: bool,
    shz: bool,
    shd: bool,
    n: I,
    x: Vec<u8>,
    c: Vec<u8>,
    dep: Vals,
    rm: Vec<bool>,
    val: Vec<Option<u8>>,
    esc: Mark,
    wc: Mark,
    acl: Mark,
    ar: Mark,
    arm: Mark,
    rb: Mark,
    rbt: Mark,
    nc: Mark,
    gc: Mark,
    cpo: Mark,
    glo: Mark,
    wpo: Mark,
    subc: Vals,
    psn: Vals,
    keep: Mark,
    psb: Mark,
    drop: Mark,
    a: Mark,
    ev: Mark,
    ew: Mark,
    gor: Mark,
    goz: Mark,
    god: Mark,
    ez: Mark,
    ed: Mark,
    bf: Vals,
    wd: Vals,
    jmp: Vals,
    hstart: Vals,
    hend: Vec<I>,
    gl: HashSet<(I, I)>,
    bsf: [I; 3],
    // context stack, 1-based, never shrunk
    ctx: Vec<Ctx>,
    d: I,
    dq: I,
    dc: I,
    mode: u8,
    np: I,
    pend: Vec<Pending>,
    pfed: Vec<bool>,
    unterm: bool,
    hn: I,
    hstop: I,
    hb1: I,
    nh: I,
    div: bool,
    qtop: bool,
    aqbad: bool,
    smfail: bool,
    nsub: I,
    sbeg: Vec<I>,
    send: Vec<I>,
    skind: Vec<u8>,
    sparent: Vec<I>,
    i: I,
    cls: u8,
    hasbrace: bool,
    wantst: bool,
    wantgrp: bool,
    wantdep: bool,
    wantar: bool,
    out: Vec<u8>,
    spans: Option<Vec<PieceSpan>>,
    payloads: Option<Vec<Payload>>,
}

fn aqv(e: u8) -> Option<u8> {
    Some(match e {
        b'a' => 0x07,
        b'b' => 0x08,
        b'e' | b'E' => 0x1b,
        b'f' => 0x0c,
        b'n' => b'\n',
        b'r' => b'\r',
        b't' => b'\t',
        b'v' => 0x0b,
        b'\\' => b'\\',
        b'\'' => b'\'',
        b'"' => b'"',
        b'?' => b'?',
        _ => return None,
    })
}

fn is_dqs(c: u8) -> bool {
    matches!(c, b'\\' | b'"' | b'$' | b'`')
}
fn is_spc(c: u8) -> bool {
    matches!(
        c,
        b'\\' | b'$' | b'\'' | b'"' | b'#' | b'(' | b')' | b'<' | b'[' | b']' | b'}' | b'`' | b'c' | b'e' | b'i' | b';' | b'&' | b'\n'
    )
}

fn opener(w: &[u8]) -> bool {
    matches!(w, b"!" | b"{" | b"if" | b"then" | b"else" | b"elif" | b"while" | b"until" | b"do")
}
fn cbody(w: &[u8]) -> bool {
    matches!(w, b"if" | b"while" | b"until" | b"for" | b"select" | b"case" | b"[[")
}
fn zopener(w: &[u8]) -> bool {
    w == b"}" || w == b"always"
}
fn zprecmd(w: &[u8]) -> bool {
    matches!(w, b"-" | b"builtin" | b"nocorrect" | b"noglob")
}

fn lower(w: &[u8]) -> Vec<u8> {
    w.iter().map(|b| b.to_ascii_lowercase()).collect()
}

/// awk's default field split: runs of blanks, tabs and newlines.
fn awk_split(s: &str) -> Vec<&str> {
    s.split([' ', '\t', '\n']).filter(|t| !t.is_empty()).collect()
}

pub const VIEWS: &[&str] = &[
    "scan", "stmts", "recognize", "stmtcuts", "stmtraw", "events", "cwords", "wordends", "code", "shell-bodies",
    "classes", "substs", "unprefixed", "cmdword", "noredir", "noprefix", "pieces", "live", "flat", "cscripts",
];

impl<'g> Lex<'g> {
    pub fn new(g: &'g Grammar, text: &[u8], view: &str, rd: Reading) -> Lex<'g> {
        let n = text.len();
        let cap = n + 16;
        let mut x = vec![0u8; cap];
        x[1..=n].copy_from_slice(text);
        let wends = view == "wordends";
        let view = if wends { "stmts".to_string() } else { view.to_string() };
        let hasbrace = text.contains(&b'}');
        let v = view.as_str();
        let wantst = matches!(v, "recognize" | "stmtcuts" | "events" | "cwords" | "unprefixed" | "pieces" | "cmdword" | "noprefix");
        let wantgrp = hasbrace && (wantst || matches!(v, "scan" | "stmts" | "live" | "flat"));
        let wantdep = wantst || wantgrp || matches!(v, "noredir" | "pieces" | "cscripts" | "stmts" | "live" | "flat");
        let wantar = wantst || wantgrp;
        let mut ctx = vec![Ctx::default(); 4];
        ctx[1].kind = T_TOP;
        Lex {
            g,
            view,
            wends,
            rd,
            shb: rd == Reading::Bash,
            shz: rd == Reading::Zsh,
            shd: rd == Reading::Dash,
            n: n as I,
            x,
            c: vec![UNSET; cap],
            dep: Vals::new(cap),
            rm: vec![false; cap],
            val: vec![None; cap],
            esc: Mark::new(cap),
            wc: Mark::new(cap),
            acl: Mark::new(cap),
            ar: Mark::new(cap),
            arm: Mark::new(cap),
            rb: Mark::new(cap),
            rbt: Mark::new(cap),
            nc: Mark::new(cap),
            gc: Mark::new(cap),
            cpo: Mark::new(cap),
            glo: Mark::new(cap),
            wpo: Mark::new(cap),
            subc: Vals::new(cap),
            psn: Vals::new(cap),
            keep: Mark::new(cap),
            psb: Mark::new(cap),
            drop: Mark::new(cap),
            a: Mark::new(cap),
            ev: Mark::new(cap),
            ew: Mark::new(cap),
            gor: Mark::new(cap),
            goz: Mark::new(cap),
            god: Mark::new(cap),
            ez: Mark::new(cap),
            ed: Mark::new(cap),
            bf: Vals::new(cap),
            wd: Vals::new(cap),
            jmp: Vals::new(cap),
            hstart: Vals::new(cap),
            hend: vec![0; 2],
            gl: HashSet::new(),
            bsf: [0; 3],
            ctx,
            d: 1,
            dq: 0,
            dc: 1,
            mode: M_NONE,
            np: 0,
            pend: vec![],
            pfed: vec![false; 2],
            unterm: false,
            hn: 0,
            hstop: 0,
            hb1: 0,
            nh: 0,
            div: false,
            qtop: false,
            aqbad: false,
            smfail: false,
            nsub: 0,
            sbeg: vec![0; 2],
            send: vec![0; 2],
            skind: vec![0; 2],
            sparent: vec![0; 2],
            i: 0,
            cls: UNSET,
            hasbrace,
            wantst,
            wantgrp,
            wantdep,
            wantar,
            out: Vec::new(),
            spans: None,
            payloads: None,
        }
    }

    // ---- array access with awk's empty element -------------------------------
    #[inline]
    fn xb(&self, k: I) -> u8 {
        if k < 1 || k > self.n {
            0
        } else {
            self.x[k as usize]
        }
    }
    #[inline]
    fn cb(&self, k: I) -> u8 {
        if k < 0 || k as usize >= self.c.len() {
            UNSET
        } else {
            self.c[k as usize]
        }
    }
    #[inline]
    fn setc(&mut self, k: I, v: u8) {
        if k >= 0 {
            let u = k as usize;
            if u >= self.c.len() {
                self.c.resize(u + 1, UNSET);
            }
            self.c[u] = v;
        }
    }
    #[inline]
    fn dep1(&self, k: I) -> bool {
        self.dep.get(k) == Some(1)
    }
    #[inline]
    fn setdep(&mut self, k: I, v: I) {
        self.dep.set(k, v);
    }
    #[inline]
    fn rmb(&self, k: I) -> bool {
        k >= 0 && (k as usize) < self.rm.len() && self.rm[k as usize]
    }
    #[inline]
    fn setrm(&mut self, k: I, v: bool) {
        if k >= 0 {
            let u = k as usize;
            if u >= self.rm.len() {
                self.rm.resize(u + 1, false);
            }
            self.rm[u] = v;
        }
    }
    #[inline]
    fn valb(&self, k: I) -> Option<u8> {
        if k >= 0 && (k as usize) < self.val.len() {
            self.val[k as usize]
        } else {
            None
        }
    }
    #[inline]
    fn setval(&mut self, k: I, v: u8) {
        if k >= 0 {
            let u = k as usize;
            if u >= self.val.len() {
                self.val.resize(u + 1, None);
            }
            self.val[u] = Some(v);
        }
    }
    fn ctxd(&mut self, d: I) -> &mut Ctx {
        let u = d as usize;
        if u >= self.ctx.len() {
            self.ctx.resize(u + 1, Ctx::default());
        }
        &mut self.ctx[u]
    }
    fn ck(&self, d: I) -> u8 {
        if d < 0 || d as usize >= self.ctx.len() {
            0
        } else {
            self.ctx[d as usize].kind
        }
    }
    fn top(&self) -> &Ctx {
        &self.ctx[self.d as usize]
    }

    // ---- the lexing ---------------------------------------------------------
    pub fn run(mut self) -> Result<(Vec<u8>, Side), (UnknownView, Side)> {
        let r = self.run_passes();
        let side = Side { unterm: self.unterm, diverge: self.div, smfail: self.smfail };
        match r {
            Ok(()) => Ok((self.out, side)),
            Err(e) => Err((e, side)),
        }
    }

    /// The pieces view's lexing, with where each statement and each of its
    /// words stands. The lexer must have been made for the `pieces` view.
    pub fn run_pieces(mut self) -> Result<(Pieces, Side), (UnknownView, Side)> {
        if self.view != "pieces" {
            return Err((UnknownView, Side::default()));
        }
        self.spans = Some(Vec::new());
        let r = self.run_passes();
        let side = Side { unterm: self.unterm, diverge: self.div, smfail: self.smfail };
        match r {
            Ok(()) => Ok((Pieces { pieces: self.spans.take().unwrap_or_default(), unreadable: self.aqbad, view: self.out }, side)),
            Err(e) => Err((e, side)),
        }
    }

    pub fn run_payloads(mut self) -> Result<(Vec<Payload>, Side), (UnknownView, Side)> {
        if !matches!(self.view.as_str(), "cscripts" | "substs") {
            return Err((UnknownView, Side::default()));
        }
        self.payloads = Some(Vec::new());
        if self.view == "cscripts" {
            // Semantic payloads share the statement and prefix walk with
            // pieces. The textual cscripts view remains a compatibility
            // search; an interpreter name in an argument is not a call.
            self.wantst = true;
            self.wantdep = true;
            self.wantar = true;
            self.wantgrp = self.x.contains(&b'}');
        }
        let r = self.run_passes();
        let side = Side { unterm: self.unterm, diverge: self.div, smfail: self.smfail || self.aqbad };
        match r {
            Ok(()) => Ok((self.payloads.take().unwrap_or_default(), side)),
            Err(e) => Err((e, side)),
        }
    }

    fn capture_payload(&mut self, kind: u8, units: &str, origin: PayloadOrigin, shell: Option<&[u8]>) {
        if self.payloads.is_none() { return; }
        let mut p = Payload { kind, text: Vec::new(), src: Vec::new(), origin, shell: shell.map(<[u8]>::to_vec) };
        for unit in awk_split(units) {
            if let Some(code) = unit.strip_prefix('#') {
                match code.parse::<u8>() {
                    Ok(b) => { p.text.push(b); p.src.push(None); }
                    Err(_) => self.smfail = true,
                }
            } else {
                match unit.parse::<usize>() {
                    Ok(n) if n > 0 && n <= self.n as usize => {
                        p.text.push(self.xb(n as I)); p.src.push(Some(n - 1));
                    }
                    _ => self.smfail = true,
                }
            }
        }
        self.payloads.as_mut().unwrap().push(p);
    }

    fn run_passes(&mut self) -> Result<(), UnknownView> {
        let n = self.n;
        let mut i: I = 1;
        while i <= n {
            self.i = i;
            if self.hn > 0 && i == self.hstop + 1 {
                if self.d > 1 && self.ck(self.d) != b'H' {
                    let mut kk = self.d;
                    while kk > 1 && self.ck(kk - 1) != b'H' {
                        kk -= 1;
                    }
                    let mut j = self.ctx[kk as usize].cst;
                    while j > 1 && (self.xb(j - 1) == b'$' || self.xb(j - 1) == b'(') && self.cb(j - 1) != b'b' {
                        j -= 1;
                    }
                    while j < i {
                        self.setc(j, b'b');
                        j += 1;
                    }
                }
                while self.d > 1 && self.ck(self.d) != b'H' {
                    self.pop();
                }
                self.pop();
                self.hstop = 0;
                self.mode = M_NONE;
            }
            if let Some(t) = self.jmp.get(i) {
                i = t + 1;
                continue;
            }
            if let Some(h) = self.hstart.get(i) {
                self.push(b'H');
                self.hstop = self.hend[h as usize];
            }
            i = self.step(i);
            i += 1;
        }
        self.i = i;
        if self.mode == M_SQ || self.mode == M_AQ || self.d > 1 || self.np > 0 {
            self.unterm = true;
        }
        let v = self.view.clone();
        let v = v.as_str();
        if self.wantst && !self.unterm {
            self.starts_all();
        }
        if ((matches!(v, "noredir" | "live" | "flat") || self.wantst) && !self.unterm)
            || matches!(v, "pieces" | "cscripts" | "stmts" | "recognize" | "stmtcuts" | "cwords")
        {
            self.redirs();
        }
        if self.wantgrp {
            self.group_close();
        }
        if (matches!(v, "unprefixed" | "recognize" | "cwords" | "pieces" | "cmdword" | "noprefix")
            || v == "cscripts" && self.payloads.is_some()) && !self.unterm {
            self.prefixes();
        }
        let r = match v {
            "substs" => {
                self.emit_substs();
                Ok(())
            }
            "pieces" => {
                self.emit_pieces();
                Ok(())
            }
            "cscripts" => {
                if self.payloads.is_some() {
                    if self.unterm {
                        // The text does not close in this reading, so the
                        // statement walk did not run and no script is read
                        // from a command position. That fails the reading
                        // only where the text hands a script on at all, and
                        // the textual search, which is broader than the
                        // walk, says whether it does. Where it finds none
                        // the text has no script payload and the reading
                        // stands. It failed there before, so a quote one
                        // shell leaves open in an argument (`echo "${x:-'}"`
                        // in the bash reading) failed the reading of a
                        // command with no script in it.
                        let keep = self.payloads.take();
                        let at = self.out.len();
                        self.emit_cscripts();
                        if self.out.len() > at {
                            self.smfail = true;
                        }
                        self.out.truncate(at);
                        self.payloads = keep;
                    } else {
                        self.emit_pieces();
                    }
                } else {
                    self.emit_cscripts();
                }
                Ok(())
            }
            "events" => {
                self.emit_events();
                Ok(())
            }
            "stmtcuts" => {
                self.emit_stmtcuts();
                Ok(())
            }
            "stmtraw" => {
                self.emit_stmtraw();
                Ok(())
            }
            "cwords" => {
                self.emit_cwords();
                Ok(())
            }
            _ => self.emit(),
        };
        r
    }

    /// One byte of the main loop at `i`; returns the `i` the loop's own `i++`
    /// continues from.
    fn step(&mut self, mut i: I) -> I {
        let n = self.n;
        let c = self.xb(i);
        if self.wantdep {
            let v = if self.mode == M_NONE || self.mode == M_CM { self.dc } else { 99 };
            self.setdep(i, v);
        }
        if self.mode == M_SQ {
            self.setc(i, b'q');
            if c == b'\'' {
                self.mode = M_NONE;
                if self.qtop {
                    self.setrm(i, true);
                }
            }
            return i;
        }
        if self.mode == M_AQ {
            self.setc(i, b'q');
            if c == b'\\' {
                if self.xb(i + 1) == b'\'' {
                    self.div = true;
                }
                if self.qtop {
                    self.aq_escape(i);
                }
                i += 1;
                self.setc(i, b'q');
            } else if c == b'\'' {
                self.mode = M_NONE;
                if self.qtop {
                    self.setrm(i, true);
                }
            }
            return i;
        }
        if self.mode == M_CM {
            if c == b'\n' {
                self.mode = M_NONE;
                i = self.at_newline(i);
            } else if c == b'`' && self.ck(self.d) == b'B' {
                self.mode = M_NONE;
                let v = if self.dq > 0 { b'Q' } else { b'c' };
                self.setc(i, v);
                self.i = i;
                self.pop();
            } else {
                self.setc(i, b'm');
            }
            return i;
        }
        let top = self.ck(self.d);
        if top == b'D' {
            self.setc(i, b'q');
            if !is_dqs(c) {
                return i;
            }
            if c == b'\\' {
                if self.xb(i + 1) == b'\n' {
                    self.setc(i, b'l');
                    self.setc(i + 1, b'l');
                    if self.dc == 2 {
                        self.setrm(i, true);
                        self.setrm(i + 1, true);
                    }
                    i += 1;
                } else {
                    if self.dc == 2 && is_dqs(self.xb(i + 1)) {
                        self.setrm(i, true);
                    }
                    i += 1;
                    self.setc(i, b'q');
                }
            } else if c == b'"' {
                if self.dc == 2 {
                    self.setrm(i, true);
                }
                self.i = i;
                self.pop();
            } else if c == b'$' && self.xb(i + 1) == b'(' && self.xb(i + 2) == b'(' {
                self.setc(i + 1, b'q');
                self.setc(i + 2, b'q');
                i = self.arith_or_sub(i, 1);
            } else if c == b'$' && self.xb(i + 1) == b'(' {
                self.setc(i + 1, b'q');
                i += 1;
                self.i = i;
                self.push(b'S');
            } else if c == b'$' && self.xb(i + 1) == b'{' {
                self.setc(i + 1, b'q');
                i += 1;
                self.i = i;
                self.push(b'V');
            } else if c == b'`' {
                self.i = i;
                self.push(b'B');
            }
            return i;
        }
        if top == b'H' {
            self.setc(i, b'b');
            if !is_dqs(c) {
                return i;
            }
            if c == b'\\' {
                let nx = self.xb(i + 1);
                if nx == b'$' || nx == b'`' || nx == b'\\' || nx == b'\n' {
                    i += 1;
                    self.setc(i, b'b');
                }
                return i;
            }
            if c == b'$' && self.xb(i + 1) == b'(' && self.xb(i + 2) == b'(' {
                self.setc(i, b'B');
                self.setc(i + 1, b'B');
                self.setc(i + 2, b'B');
                return self.arith_or_sub(i, 1);
            }
            if c == b'$' && self.xb(i + 1) == b'(' {
                self.setc(i, b'B');
                self.setc(i + 1, b'B');
                i += 1;
                self.i = i;
                self.push(b'S');
                return i;
            }
            if c == b'$' && self.xb(i + 1) == b'{' {
                self.setc(i, b'B');
                self.setc(i + 1, b'B');
                i += 1;
                self.i = i;
                self.push(b'V');
                return i;
            }
            if c == b'`' {
                self.setc(i, b'B');
                self.i = i;
                self.push(b'B');
                return i;
            }
            return i;
        }
        let cls = if self.dq > 0 {
            b'Q'
        } else if self.hn > 0 {
            b'B'
        } else {
            b'c'
        };
        self.cls = cls;
        self.setc(i, cls);
        let d = self.d;
        if self.wantar && (top == b'K' || top == b'A' && self.ctx[d as usize].par == 0) {
            self.ar.set(i);
        }
        if top == b'W' && self.ctx[d as usize].wkind == b's' && is_sep(c) {
            self.div = true;
        }
        if !is_spc(c) && !(top == b'C' && self.ctx[d as usize].cpat == 1) {
            return i;
        }
        if c == b'\\' {
            if self.xb(i + 1) == b'\n' {
                self.setc(i, b'l');
                self.setc(i + 1, b'l');
                if self.dc == 1 {
                    self.setrm(i, true);
                    self.setrm(i + 1, true);
                }
                return i + 1;
            }
            if top == b'B' && self.xb(i + 1) == b'`' {
                self.setc(i + 1, cls);
                i += 1;
                self.i = i;
                if self.ctx[d as usize].besc != 0 {
                    self.pop();
                } else {
                    self.push(b'B');
                    let dd = self.d;
                    self.ctxd(dd).besc = 1;
                }
                return i;
            }
            if self.dq > 0 {
                i += 1;
                self.setc(i, b'Q');
                self.esc.set(i);
                return i;
            }
            self.setc(i, b'x');
            if self.dc == 1 {
                self.setrm(i, true);
            }
            if i < n {
                i += 1;
                self.setc(i, b'e');
            }
            return i;
        }
        if c == b'$' && self.xb(i + 1) == b'\'' && self.shd {
            self.setc(i, b'q');
            return i;
        }
        if c == b'$' && self.xb(i + 1) == b'\'' {
            self.setc(i, b'q');
            self.setc(i + 1, b'q');
            self.qtop = self.dc == 1;
            if self.qtop {
                self.setrm(i, true);
                self.setrm(i + 1, true);
            }
            self.mode = M_AQ;
            return i + 1;
        }
        if c == b'\'' {
            if top == b'A' || top == b'K' || top == b'V' && self.dq > 0 {
                self.div = true;
                if !self.shb {
                    return i;
                }
            }
            self.setc(i, b'q');
            self.mode = M_SQ;
            self.qtop = self.dc == 1;
            if self.qtop {
                self.setrm(i, true);
            }
            return i;
        }
        if c == b'"' {
            if top == b'A' || top == b'K' {
                self.div = true;
                if !self.shb {
                    return i;
                }
            }
            self.setc(i, b'q');
            if self.dc == 1 {
                self.setrm(i, true);
            }
            self.i = i;
            self.push(b'D');
            return i;
        }
        if (c == b'c' || c == b'e') && self.wordstart(i) && (i + 4 > n || is_sep(self.xb(i + 4))) {
            let w4 = [self.xb(i), self.xb(i + 1), self.xb(i + 2), self.xb(i + 3)];
            if &w4 == b"case" && (self.cmdpos(i) || self.namehead(i)) {
                self.setc(i + 1, cls);
                self.setc(i + 2, cls);
                self.setc(i + 3, cls);
                i += 3;
                self.i = i;
                self.push(b'C');
                return i;
            }
            if &w4 == b"esac" && top == b'C' && !(self.ctx[d as usize].cpat == 1 && self.ctx[d as usize].cpw != 0) {
                self.setc(i + 1, cls);
                self.setc(i + 2, cls);
                self.setc(i + 3, cls);
                i += 3;
                self.i = i;
                self.pop();
                return i;
            }
        }
        if top == b'C' {
            let cpat = self.ctx[d as usize].cpat;
            if cpat == 0 && c == b'i' && self.xb(i + 1) == b'n' && self.wordstart(i) && (i + 2 > n || is_sep(self.xb(i + 2))) {
                self.setc(i + 1, cls);
                i += 1;
                let cx = self.ctxd(d);
                cx.cpat = 1;
                cx.cpw = 0;
                return i;
            }
            if cpat == 1 && c == b'(' && self.ctx[d as usize].cpw == 0 {
                self.cpo.set(i);
                return i;
            }
            if cpat == 1 && c == b')' {
                if self.dc == 1 {
                    self.setc(i, b'p');
                }
                self.ctxd(d).cpat = 2;
                return i;
            }
            if cpat == 1 && !(c == b' ' || c == b'\t' || c == b'\n') {
                self.ctxd(d).cpw = 1;
            }
            let cpat = self.ctx[d as usize].cpat;
            if cpat == 2 && c == b';' && (self.xb(i + 1) == b'|' || self.xb(i + 1) == b';' && self.xb(i + 2) == b'&') {
                self.div = true;
            }
            if cpat == 2 && c == b';' && (self.xb(i + 1) == b';' || self.xb(i + 1) == b'&' || self.xb(i + 1) == b'|' && self.shz) {
                self.setc(i + 1, cls);
                i += 1;
                if self.dc == 1 {
                    self.arm.set(i);
                }
                if self.xb(i) == b';' && self.xb(i + 1) == b'&' && self.shb {
                    self.setc(i + 1, cls);
                    i += 1;
                    if self.dc == 1 {
                        self.arm.set(i);
                    }
                }
                let cx = self.ctxd(d);
                cx.cpat = 1;
                cx.cpw = 0;
                return i;
            }
        }
        if top == b'A' || top == b'K' {
            // Arithmetic expands command substitutions too. Using the same
            // context stack keeps their shell bodies out of the arithmetic
            // parenthesis count and exposes them to every payload reader.
            if c == b'$' && self.xb(i + 1) == b'(' && self.xb(i + 2) != b'(' {
                self.setc(i + 1, cls);
                self.i = i + 1;
                self.push(b'S');
                return i + 1;
            }
            if c == b'`' {
                self.i = i;
                self.push(b'B');
                return i;
            }
            if top == b'K' {
                if c == b']' {
                    self.i = i;
                    self.pop();
                }
                return i;
            }
            if c == b'(' {
                self.ctxd(d).par += 1;
            } else if c == b')' {
                if self.ctx[d as usize].par > 0 {
                    self.ctxd(d).par -= 1;
                } else if self.xb(i + 1) == b')' {
                    i += 1;
                    self.setc(i, cls);
                    if self.ctx[d as usize].adol != 0 {
                        self.wc.set(i);
                    } else {
                        self.acl.set(i);
                    }
                    self.i = i;
                    self.pop();
                    if self.acl.has(i) && self.wantdep {
                        let dc = self.dc;
                        self.setdep(i, dc);
                    }
                }
            } else if c == b'\n' {
                i = self.at_newline(i);
            }
            return i;
        }
        if c == b'#'
            && (self.wordstart(i) || top == b'B' && self.xb(i - 1) == b'`')
            && top != b'V'
            && !(top == b'W' && self.ctx[d as usize].wkind != b'a')
        {
            if self.ctx[d as usize].glc > 0 {
                self.div = true;
                return i;
            }
            self.setc(i, b'm');
            self.mode = M_CM;
            return i;
        }
        if c == b'$' && self.xb(i + 1) == b'(' && self.xb(i + 2) == b'(' {
            self.setc(i + 1, cls);
            self.setc(i + 2, cls);
            return self.arith_or_sub(i, 1);
        }
        if c == b'('
            && self.xb(i + 1) == b'('
            && !(i > 1 && (self.xb(i - 1) == b'<' || self.xb(i - 1) == b'>') && self.cb(i - 1) == cls)
            && self.wparen(i) != b'z'
        {
            self.setc(i + 1, cls);
            return self.arith_or_sub(i, 0);
        }
        if c == b'$' && self.xb(i + 1) == b'(' {
            self.setc(i + 1, cls);
            i += 1;
            self.i = i;
            self.push(b'S');
            return i;
        }
        if c == b'$' && self.xb(i + 1) == b'[' {
            self.div = true;
            if self.shd {
                return i;
            }
            self.setc(i + 1, cls);
            i += 1;
            self.i = i;
            self.push(b'K');
            return i;
        }
        if c == b'$' && self.xb(i + 1) == b'{' {
            self.setc(i + 1, cls);
            i += 1;
            self.i = i;
            self.push(b'V');
            return i;
        }
        if c == b'`' {
            self.i = i;
            if top == b'B' {
                self.pop();
            } else {
                self.push(b'B');
            }
            return i;
        }
        if top == b'V' {
            if c == b'}' {
                self.i = i;
                self.pop();
            }
            return i;
        }
        if c == b'}' {
            self.rb.set(i);
            if self.dc == 1 {
                self.rbt.set(i);
            }
            return i;
        }
        if c == b'&' {
            let p = self.xb(i - 1);
            if self.xb(i + 1) == b'>' && !(i > 1 && (p == b'<' || p == b'>') && self.cb(i - 1) == cls) {
                self.div = true;
            }
            return i;
        }
        if c == b'[' {
            if top == b'W' && self.ctx[d as usize].wkind == b's' {
                self.ctxd(d).sbr += 1;
                return i;
            }
            if self.subname(i) {
                let wk = self.la_sub(i + 1);
                if wk != 0 && (self.xb(wk) == b'=' || self.xb(wk) == b'+' && self.xb(wk + 1) == b'=') {
                    self.subc.set(i, wk - 1);
                    if self.shb {
                        self.i = i;
                        self.push(b'W');
                        let dd = self.d;
                        let cx = self.ctxd(dd);
                        cx.wkind = b's';
                        cx.sbr = 0;
                        if self.wantdep {
                            let dc = self.dc;
                            self.setdep(i, dc);
                        }
                    }
                }
            }
            return i;
        }
        if c == b']' {
            if top == b'W' && self.ctx[d as usize].wkind == b's' {
                if self.ctx[d as usize].sbr > 0 {
                    self.ctxd(d).sbr -= 1;
                } else {
                    let cst = self.ctx[d as usize].cst;
                    self.subc.set(cst, i);
                    self.i = i;
                    self.pop();
                }
            }
            return i;
        }
        if c == b'(' {
            let wk = self.wparen(i);
            if wk == b'z' {
                self.i = i;
                self.push(b'S');
                if self.wantdep {
                    let dc = self.dc;
                    self.setdep(i, dc);
                }
                return i;
            }
            if wk == b'a' || wk == b'g' {
                if wk == b'g' {
                    self.div = true;
                }
                self.i = i;
                self.push(b'W');
                let dd = self.d;
                self.ctxd(dd).wkind = wk;
                self.wpo.set(i);
                if self.wantdep {
                    let dc = self.dc;
                    self.setdep(i, dc);
                }
                return i;
            }
            if i > 1 && (self.xb(i - 1) == b'<' || self.xb(i - 1) == b'>') && self.cb(i - 1) == cls {
                self.i = i;
                self.push(b'S');
                let ns = self.nsub;
                self.skind[ns as usize] = b'P';
                self.psn.set(i, ns);
                if self.wantdep {
                    let dc = self.dc;
                    self.setdep(i, dc);
                    self.setdep(i - 1, dc);
                }
                return i;
            }
            self.ctxd(d).par += 1;
            let par = self.ctx[d as usize].par;
            if !self.shd
                && !self.emptyahead(i)
                && (i == 1 || !matches!(self.xb(i - 1), b'$' | b'<' | b'>'))
                && !self.cmdpos(i)
                && !self.forlist(i)
            {
                if self.shz {
                    // A bare parenthesized pattern is one zsh word even
                    // after whitespace. Use the same word context as an
                    // attached pattern so its | cannot become a pipeline.
                    self.ctxd(d).par -= 1;
                    self.div = true;
                    self.i = i;
                    self.push(b'W');
                    let dd = self.d;
                    self.ctxd(dd).wkind = b'g';
                    self.wpo.set(i);
                    if self.wantdep { self.setdep(i, self.dc); }
                    return i;
                }
                self.gl.insert((d, par));
                self.glo.set(i);
                self.ctxd(d).glc += 1;
                self.div = true;
            } else {
                self.gl.remove(&(d, par));
            }
            return i;
        }
        if c == b')' {
            let par = self.ctx[d as usize].par;
            if par > 0 {
                if self.gl.contains(&(d, par)) {
                    self.wc.set(i);
                    self.gl.remove(&(d, par));
                    self.ctxd(d).glc -= 1;
                }
                self.ctxd(d).par -= 1;
            } else if top == b'S' || top == b'W' && self.ctx[d as usize].wkind != b's' {
                self.wc.set(i);
                self.i = i;
                self.pop();
            }
            return i;
        }
        if top == b'W' && self.ctx[d as usize].wkind == b's' {
            return i;
        }
        if c == b'<' && cls == b'c' {
            let wk = self.numglob(i);
            if wk != 0 {
                self.div = true;
                if self.shz {
                    self.setc(i, b'e');
                    i += 1;
                    while i < wk {
                        self.setc(i, cls);
                        if self.wantdep {
                            let dc = self.dc;
                            self.setdep(i, dc);
                        }
                        i += 1;
                    }
                    self.setc(i, b'e');
                    if self.wantdep {
                        let dc = self.dc;
                        self.setdep(i, dc);
                    }
                    return i;
                }
            }
        }
        if c == b'<' && self.xb(i + 1) == b'<' && self.xb(i + 2) != b'<' && self.xb(i - 1) != b'<' {
            return self.heredoc_op(i);
        }
        if c == b'\n' {
            return self.at_newline(i);
        }
        i
    }

    fn aq_escape(&mut self, j: I) {
        self.setrm(j, true);
        let e = self.xb(j + 1);
        if let Some(v) = aqv(e) {
            self.setval(j + 1, v);
            return;
        }
        let v: I;
        if (b'0'..=b'7').contains(&e) {
            let mut vv: I = 0;
            let mut k = j + 1;
            while k <= j + 3 && k <= self.n && (b'0'..=b'7').contains(&self.xb(k)) {
                vv = vv * 8 + (self.xb(k) - b'0') as I;
                if k > j + 1 {
                    self.setrm(k, true);
                }
                k += 1;
            }
            v = vv;
        } else if e == b'x' {
            let mut vv: I = 0;
            let mut k = j + 2;
            while k <= j + 3 && k <= self.n {
                let h = match self.xb(k).to_ascii_lowercase() {
                    c @ b'0'..=b'9' => (c - b'0') as I + 1,
                    c @ b'a'..=b'f' => (c - b'a') as I + 11,
                    _ => 0,
                };
                if h <= 0 {
                    break;
                }
                vv = vv * 16 + h - 1;
                self.setrm(k, true);
                k += 1;
            }
            if k == j + 2 {
                vv = 0;
            }
            v = vv;
        } else if e == b'u' || e == b'U' || e == b'c' {
            self.aqbad = true;
            return;
        } else {
            self.setrm(j, false);
            return;
        }
        if !(1..=127).contains(&v) {
            self.aqbad = true;
            return;
        }
        self.setval(j + 1, v as u8);
    }

    fn redirs(&mut self) {
        let n = self.n;
        let mut k: I = 1;
        while k <= n {
            if self.cb(k) != b'c' || !self.dep1(k) {
                k += 1;
                continue;
            }
            let mut j: I;
            if self.xb(k) == b'&' && self.xb(k + 1) == b'>' && self.cb(k + 1) == b'c' {
                if self.shd {
                    k += 1;
                    continue;
                }
                j = k + 1;
            } else if self.xb(k) == b'<' || self.xb(k) == b'>' {
                j = k;
            } else {
                k += 1;
                continue;
            }
            if self.xb(j + 1) == b'(' {
                k = j + 1;
                k += 1;
                continue;
            }
            let mut s = self.fdword(k);
            j += 1;
            while j <= n && self.cb(j) == b'c' && matches!(self.xb(j), b'<' | b'>') && !self.psn.has(j + 1) {
                j += 1;
            }
            if j <= n && self.cb(j) == b'c' && self.xb(j) == b'&' {
                j += 1;
            }
            if j <= n && self.cb(j) == b'c' && self.xb(j) == b'|' {
                j += 1;
            } else if j <= n && self.cb(j) == b'c' && self.xb(j) == b'!' && self.xb(j - 1) != b'<' {
                if j + 1 > n || self.word_sep(j + 1) {
                    self.div = true;
                }
                if self.shz {
                    j += 1;
                }
            }
            while j <= n && self.cb(j) == b'c' && self.dep1(j) && is_blank(self.xb(j)) {
                j += 1;
            }
            let z = self.wordend(j);
            let mut m = j;
            while m < z {
                if !(matches!(self.xb(m), b'<' | b'>') && self.cb(m) == b'c' && self.psn.has(m + 1)) {
                    m += 1;
                    continue;
                }
                let ps = self.psn.num(m + 1);
                let end = self.send[ps as usize];
                let mut e = m + 2;
                while e <= end {
                    self.keep.set(e);
                    e += 1;
                }
                self.psb.set(m);
                self.psb.set(m + 1);
                self.psb.set(e);
                m = e;
                m += 1;
            }
            j = z;
            while s < j {
                self.drop.set(s);
                s += 1;
            }
            k = j - 1;
            k += 1;
        }
    }

    fn fdword(&mut self, j: I) -> I {
        let mut s = j;
        let cj = self.cb(j);
        if s > 1 && self.xb(s - 1).is_ascii_digit() {
            while s > 1 && self.xb(s - 1).is_ascii_digit() && self.cb(s - 1) == cj {
                s -= 1;
            }
        } else if s > 3 && self.xb(s - 1) == b'}' && self.cb(s - 1) == cj {
            s = j - 2;
            while s > 1 && is_name(self.xb(s)) && self.cb(s) == cj {
                s -= 1;
            }
            if self.xb(s) != b'{' || self.cb(s) != cj || !is_name_start(self.xb(s + 1)) {
                return j;
            }
        }
        if s == j || !self.wordstart(s) && !self.ev.has(s) {
            return j;
        }
        if self.xb(s) == b'{' && self.ev.has(s + 1) && !self.ev.has(s) {
            return j;
        }
        let policy = self.rd;
        if self.fdat(s, j, policy) {
            s
        } else {
            j
        }
    }

    fn fdat(&mut self, s: I, j: I, rs: Reading) -> bool {
        if self.xb(s) == b'{' {
            return true;
        }
        if j - s == 1 {
            return true;
        }
        if rs == self.rd && self.shb {
            self.div = true;
        }
        rs == Reading::Bash
    }

    fn fdshape(&self, s: I, j: I) -> bool {
        if s >= j {
            return false;
        }
        let cj = self.cb(j);
        if self.xb(s) == b'{' {
            if j - s < 3 || self.xb(j - 1) != b'}' || !is_name_start(self.xb(s + 1)) {
                return false;
            }
            for k in s..j {
                if self.cb(k) != cj || k > s && k < j - 1 && !is_name(self.xb(k)) {
                    return false;
                }
            }
            return true;
        }
        for k in s..j {
            if !self.xb(k).is_ascii_digit() || self.cb(k) != cj {
                return false;
            }
        }
        true
    }

    fn wordend(&self, mut j: I) -> I {
        while j <= self.n && !self.word_sep(j) {
            j += 1;
        }
        j
    }

    fn word_sep(&self, k: I) -> bool {
        if self.arm.has(k) {
            return true;
        }
        let ck = self.cb(k);
        if ck == b'h' || ck == b'b' || ck == b'B' || self.bf.has(k) {
            return match self.wd.get(k) {
                None => true,
                Some(w) => w <= 1,
            };
        }
        if ck == b'p' {
            return true;
        }
        if ck == b'm' {
            return self.dep1(k);
        }
        ck == b'c' && self.dep1(k) && is_sep(self.xb(k))
    }

    fn mark(&mut self, a: I, z: I) {
        let mut k = a;
        while k <= z {
            self.a.set(k);
            k += 1;
        }
    }

    fn prefixes(&mut self) {
        let n = self.n;
        let (mut atstart, mut envmode, mut takes, mut execmode, mut cmdmode, mut timemode) = (false, false, false, false, false, false);
        let mut k: I = 1;
        while k <= n {
            if self.ev.has(k) {
                atstart = true;
                envmode = false;
                takes = false;
                execmode = false;
                cmdmode = false;
                timemode = false;
            }
            if self.word_sep(k) {
                if self.drop.has(k) {
                    if atstart {
                        self.a.set(k);
                        if !self.drop.has(k + 1) {
                            while k + 1 <= n && self.cb(k + 1) == b'c' && self.dep1(k + 1) && is_blank(self.xb(k + 1)) {
                                k += 1;
                                self.a.set(k);
                            }
                        }
                    }
                    k += 1;
                    continue;
                }
                k += 1;
                continue;
            }
            let s = k;
            let mut w: Vec<u8> = Vec::new();
            while k <= n && !self.word_sep(k) && !(k > s && self.ev.has(k)) {
                w.push(self.xb(k));
                k += 1;
            }
            if !atstart {
                continue;
            }
            let mut sl: I = 0;
            let mut bw: Vec<u8> = w.clone();
            for j in s..k {
                if self.xb(j) == b'/' && self.cb(j) == b'c' && self.dep1(j) {
                    sl = j;
                }
            }
            if sl > 0 {
                let mut j = sl + 1;
                while j < k && self.cb(j) == b'c' && self.dep1(j) {
                    j += 1;
                }
                if j == k && sl < k - 1 {
                    bw = w[(sl - s + 1) as usize..].to_vec();
                } else {
                    sl = 0;
                }
            }
            let lbw = lower(&bw);
            let hit;
            if self.drop.has(s) {
                hit = true;
            } else if takes {
                takes = false;
                hit = true;
            } else if (execmode || cmdmode) && w == b"--" {
                execmode = false;
                cmdmode = false;
                hit = true;
            } else if envmode && w.first() == Some(&b'-') {
                if env_takes(&w) {
                    takes = true;
                }
                hit = true;
            } else if execmode && w.len() >= 2 && w[0] == b'-' && w[1..].iter().all(|b| b.is_ascii_lowercase()) {
                // index(w, "a") == length(w)
                let ia = w.iter().position(|&b| b == b'a').map(|p| p + 1).unwrap_or(0);
                if ia == w.len() {
                    takes = true;
                }
                hit = true;
            } else if cmdmode && w.len() >= 2 && w[0] == b'-' && w[1..].iter().all(|&b| b == b'p') {
                hit = true;
            } else if timemode && w == b"--" {
                timemode = false;
                hit = true;
            } else if timemode && w.first() == Some(&b'-') {
                if time_takes(&w) {
                    takes = true;
                }
                hit = true;
            } else if self.assignat(s, k, true) != 0 {
                hit = true;
            } else if lbw == b"env" {
                if self.payloads.is_some() { self.ew.set(s); }
                envmode = true;
                hit = true;
            } else if w == b"exec" {
                envmode = false;
                execmode = true;
                cmdmode = false;
                hit = true;
            } else if lbw == b"command" {
                envmode = false;
                cmdmode = true;
                execmode = false;
                hit = true;
            } else if lbw == b"time" {
                envmode = false;
                timemode = true;
                hit = true;
            } else if self.shz && zprecmd(&w) {
                envmode = false;
                hit = true;
            } else if opener(&w) || self.shz && zopener(&w) || w == b"coproc" {
                envmode = false;
                continue;
            } else {
                // The prefix walk has reached the command, after consuming
                // option operands and assignments. Preserve that original
                // start for the structural script reader, including quotes
                // and executable paths, before prefix bytes are blanked.
                if self.payloads.is_some() { self.ew.set(s); }
                if !self.shz && zprecmd(&w) {
                    self.div = true;
                }
                if sl > 0 {
                    if let Some(re) = &self.g.exre {
                        if re.is_match(&lbw) {
                            self.mark(s, sl);
                        }
                    }
                }
                atstart = false;
                envmode = false;
                continue;
            }
            let _ = hit;
            self.mark(s, k - 1);
            while k <= n && self.cb(k) == b'c' && self.dep1(k) && is_blank(self.xb(k)) {
                self.a.set(k);
                k += 1;
            }
        }
    }

    fn assignat(&mut self, s: I, k: I, walked: bool) -> I {
        let mut p = s;
        if !is_name_start(self.xb(p)) {
            return 0;
        }
        while p < k && is_name(self.xb(p)) {
            p += 1;
        }
        if p < k && self.xb(p) == b'[' && walked && !self.subc.has(p) {
            let wk = self.la_sub(p + 1);
            if wk != 0 && (self.xb(wk) == b'=' || self.xb(wk) == b'+' && self.xb(wk + 1) == b'=') {
                self.subc.set(p, wk - 1);
            }
        }
        if p < k && self.xb(p) == b'[' {
            match self.subc.get(p) {
                None => return 0,
                Some(sc) if sc >= k => return 0,
                Some(sc) => p = sc + 1,
            }
        }
        if p < k && self.xb(p) == b'+' {
            p += 1;
        }
        if p < k && self.xb(p) == b'=' {
            p + 1
        } else {
            0
        }
    }

    /// The walk. Returns the start events, the command words and the group
    /// openers of reading `rs`.
    fn starts(&mut self, rs: Reading) -> (Mark, Mark, Mark) {
        let n = self.n;
        let cap = self.x.len();
        let mut cs_ = Mark::new(cap);
        let mut cw_ = Mark::new(cap);
        let mut go = Mark::new(cap);
        let zr = rs == Reading::Zsh;
        let br = rs == Reading::Bash;
        let (mut st, mut pre, mut rd, mut fnn, mut fr, mut fra, mut inp, mut rp, mut dbr, mut cop, mut tm, mut cs, mut fh) =
            (1i32, 0i32, 0i32, 0i32, 0i32, 0i32, 0i32, 0i32, 0i32, 0i32, 0i32, 0i32, 0i32);
        let mut pn: usize = 0;
        let mut pst: Vec<bool> = vec![false];
        let mut pcond: Vec<i32> = vec![0];
        let mut cw: i32 = 0;
        let mut acond: i32 = 0;
        let mut k: I = 1;
        while k <= n {
            if self.word_sep(k) {
                let mut op = if self.cb(k) == b'c' && self.dep1(k) { self.xb(k) } else { 0 };
                if op == b'&'
                    && (self.xb(k + 1) == b'>' && rs != Reading::Dash
                        || k > 1 && (self.xb(k - 1) == b'>' || self.xb(k - 1) == b'<') && self.cb(k - 1) == b'c')
                {
                    op = b'>';
                }
                if zr && op == b'&' && self.xb(k + 1) == b'!' && self.cb(k + 1) == b'c' && self.dep1(k + 1) {
                    st = 1;
                    pre = 0;
                    rd = 0;
                    fnn = 0;
                    fr = 0;
                    inp = 0;
                    rp = 0;
                    dbr = 0;
                    cop = 0;
                    tm = 0;
                    fh = 0;
                    k += 2;
                    continue;
                }
                if self.cb(k) == b'p' || matches!(op, b'\n' | b';' | b'&' | b'|') {
                    st = 1;
                    pre = 0;
                    rd = 0;
                    fnn = 0;
                    fr = 0;
                    inp = 0;
                    rp = 0;
                    dbr = 0;
                    cop = 0;
                    tm = 0;
                    fh = 0;
                } else if op == b'<' || op == b'>' {
                    fh = 0;
                    rd = 1;
                    let hd = fnn != 0 || fr != 0 || rp != 0 || dbr != 0 || cs != 0 || inp != 0;
                    if st != 0 && pre == 0 && !hd {
                        cs_.set(k);
                    }
                    if st != 0 && !hd {
                        pre = 1;
                    }
                    if op == b'>' && self.xb(k + 1) == b'|' {
                        k += 1;
                    }
                } else if op == b'(' {
                    let mut j = k + 1;
                    while j <= n && is_blank(self.xb(j)) {
                        j += 1;
                    }
                    let arith = self.xb(k + 1) == b'(' && self.ar.has(k + 2);
                    if !(st != 0 && pre == 0)
                        && fh == 0
                        && fnn != 2
                        && cop != 2
                        && !(zr && fr == 2)
                        && self.xb(j) != b')'
                        && !arith
                        && !self.cpo.has(k)
                        && !self.glo.has(k)
                    {
                        self.bsf[rs.idx()] += 1;
                    }
                    let body = (fh != 0
                        || fnn == 2
                        || br && cop == 2
                        || fr == 2 && fra != 0
                        || st != 0 && pre == 0 && fnn == 0 && fr == 0 && rp == 0 && dbr == 0 && !self.cpo.has(k))
                        && !arith
                        && !self.emptyahead(k);
                    if body {
                        cs_.set(k);
                    }
                    if !arith {
                        pn += 1;
                        if pst.len() <= pn {
                            pst.resize(pn + 1, false);
                            pcond.resize(pn + 1, 0);
                        }
                        pst[pn] = body;
                        pcond[pn] = cw;
                        cw = 0;
                    }
                    if arith {
                    } else if zr && fr == 2 && fra == 0 {
                        inp = 1;
                        fr = 0;
                    } else if self.cpo.has(k) {
                    } else {
                        st = 1;
                        pre = 0;
                        rd = 0;
                        fnn = 0;
                        fr = 0;
                        rp = 0;
                        cop = 0;
                        tm = 0;
                    }
                    fh = 0;
                } else if op == b')' {
                    if self.acl.has(k) {
                        acond = 0;
                    } else if inp != 0 {
                        inp = 0;
                        st = 1;
                    } else if self.emptyparen(k) {
                        st = 1;
                        fnn = 0;
                        fh = 1;
                    } else if cs == 3 {
                        st = 1;
                    } else if pn > 0 && pst[pn] {
                        st = 1;
                        pre = 0;
                    }
                    if pn > 0 && !self.acl.has(k) {
                        pn -= 1;
                    }
                }
                k += 1;
                continue;
            }
            let s = k;
            let mut w: Vec<u8> = Vec::new();
            while k <= n && !self.word_sep(k) {
                w.push(self.xb(k));
                k += 1;
            }
            fh = 0;
            if inp != 0 {
                continue;
            }
            if rd != 0 {
                rd = 0;
                continue;
            }
            if dbr != 0 {
                if w == b"]]" {
                    dbr = 0;
                    st = zr as i32;
                }
                continue;
            }
            if fnn != 0 {
                if w == b"{" {
                    go.set(s);
                    fnn = 0;
                    st = 1;
                    continue;
                }
                if fnn != 2 || !cbody(&w) {
                    fnn = if fnn == 1 { 2 } else { 3 };
                    continue;
                }
                fnn = 0;
                st = 1;
            }
            if fr == 1 {
                fr = 2;
                fra = (w.first() == Some(&b'(') && self.ar.has(s + 1)) as i32;
                continue;
            }
            if fr == 2 {
                if w == b"in" {
                    fr = 0;
                    st = 0;
                } else if w == b"do" || w == b"{" {
                    if w == b"{" {
                        go.set(s);
                    }
                    fr = 0;
                    st = 1;
                } else if fra != 0 {
                    fr = 0;
                    st = 1;
                    fra = 0;
                }
                if fr == 2 || w == b"in" || w == b"do" || w == b"{" {
                    continue;
                }
            }
            if rp != 0 {
                rp = 0;
                st = 1;
                continue;
            }
            if cs == 1 {
                cs = 2;
                continue;
            }
            if cs == 2 {
                cs = if zr && w == b"{" { 3 } else { 0 };
                continue;
            }
            if st == 0 && br && cop == 2 && cbody(&w) {
                st = 1;
                cop = 0;
            }
            if st == 0 {
                if br && cop == 2 && w == b"{" {
                    go.set(s);
                    st = 1;
                } else if zr && w == b"}" {
                    st = 1;
                }
                cop = 0;
                continue;
            }
            if tm == 2 {
                tm = 1;
                continue;
            }
            if tm != 0 && w.first() == Some(&b'-') {
                if time_takes(&w) {
                    tm = 2;
                }
                continue;
            }
            tm = 0;
            if zr && pre == 0 && w.len() > 1 && w[0] == b'{' && self.cb(s) == b'c' && self.dep1(s) {
                go.set(s);
                k = s + 1;
                continue;
            }
            if (self.xb(k) == b'<' || self.xb(k) == b'>') && self.cb(k) == b'c' && self.fdshape(s, k) && self.fdat(s, k, rs) {
                if pre == 0 {
                    cs_.set(s);
                }
                pre = 1;
                continue;
            }
            if pre == 0 {
                cs_.set(s);
            }
            pre = 0;
            if self.assignat(s, k, true) == 0 {
                cw_.set(s);
            }
            if cop == 1 {
                cop = if w == b"{" { 0 } else { 2 };
            }
            let pcw = cw;
            cw = 0;
            if opener(&w) || zr && zopener(&w) {
                if w == b"{" {
                    go.set(s);
                }
                cop = 0;
                cw = matches!(w.as_slice(), b"if" | b"elif" | b"while" | b"until") as i32;
                continue;
            }
            if self.assignat(s, k, true) != 0 {
                pre = 1;
                continue;
            }
            if w == b"time" {
                tm = 1;
                continue;
            }
            if zr && zprecmd(&w) {
                continue;
            }
            if w == b"function" {
                fnn = 1;
                continue;
            }
            if w == b"for" || w == b"select" || zr && w == b"foreach" {
                fr = 1;
                continue;
            }
            if zr && w == b"repeat" {
                rp = 1;
                continue;
            }
            if w == b"[[" {
                dbr = 1;
                continue;
            }
            if w == b"coproc" {
                cop = 1;
                continue;
            }
            if w == b"case" {
                cs = 1;
                st = 0;
                continue;
            }
            if zr && w.first() == Some(&b'(') && self.ar.has(s + 1) {
                acond = pcw;
                continue;
            }
            for j in s..k {
                if self.wpo.has(j) {
                    self.bsf[rs.idx()] += 1;
                    break;
                }
            }
            st = 0;
        }
        let _ = acond;
        (cs_, cw_, go)
    }

    fn starts_all(&mut self) {
        let (ev, ew, gor) = self.starts(self.rd);
        self.ev = ev;
        self.ew = ew;
        self.gor = gor;
        if !self.shb {
            return;
        }
        let (ez, _ezw, goz) = self.starts(Reading::Zsh);
        let (ed, _edw, god) = self.starts(Reading::Dash);
        self.ez = ez;
        self.goz = goz;
        self.ed = ed;
        self.god = god;
        self.walks_fail();
        if self.div {
            return;
        }
        let len = self.x.len().max(self.ev.0.len()).max(self.ez.0.len()).max(self.ed.0.len());
        for j in 0..len as I {
            if self.ez.has(j) && !self.ev.has(j) {
                self.div = true;
                return;
            }
        }
        for j in 0..len as I {
            if self.ed.has(j) && !self.ev.has(j) {
                self.div = true;
                return;
            }
        }
        for j in 0..len as I {
            if self.ev.has(j) && (!self.ez.has(j) || !self.ed.has(j)) {
                self.div = true;
                return;
            }
        }
    }

    fn bare(&self, k: I) -> bool {
        let mut j = k - 1;
        while j >= 1 && is_blank(self.xb(j)) && self.cb(j) == b'c' {
            j -= 1;
        }
        if j < 1 || self.arm.has(j) {
            return false;
        }
        !(self.cb(j) == b'c' && self.dep1(j) && !self.drop.has(j) && matches!(self.xb(j), b'\n' | b';' | b'&' | b'|' | b'('))
    }

    fn walks_fail(&mut self) {
        if self.bsf[0] != 0 && self.bsf[1] != 0 && self.bsf[2] != 0 {
            self.smfail = true;
        }
    }

    fn wparen(&mut self, j: I) -> u8 {
        let mut k = j;
        while k > 2 && self.cb(k - 1) == b'l' {
            k -= 2;
        }
        if k < 2 {
            return 0;
        }
        let p = self.xb(k - 1);
        let pc = self.cb(k - 1);
        let cj = self.cb(j);
        if p == b'=' && pc == cj && !self.wc.has(k - 1) {
            if self.wordstart(k - 1) {
                return b'z';
            }
            let mut s = k - 1;
            while s > 1 && self.cb(s - 1) == cj && !is_sep(self.xb(s - 1)) {
                s -= 1;
            }
            if self.assignat(s, k, false) == k {
                return b'a';
            }
        }
        if self.emptyahead(j) {
            return 0;
        }
        if pc == b'e' || pc == b'q' || self.wc.has(k - 1) {
            return if self.shd { 0 } else { b'g' };
        }
        if pc == cj && p == b'&' && k > 2 && matches!(self.xb(k - 2), b'<' | b'>') && self.cb(k - 2) == cj {
            return if self.shd { 0 } else { b'g' };
        }
        if pc != cj || is_sep(p) {
            return 0;
        }
        if !self.shd && p != b'$' && !self.cmdpos(j) {
            return b'g';
        }
        0
    }

    fn emptyahead(&self, mut j: I) -> bool {
        j += 1;
        while j <= self.n && is_blank(self.xb(j)) {
            j += 1;
        }
        self.xb(j) == b')'
    }

    fn numglob(&self, j: I) -> I {
        let n = self.n;
        let mut k = j + 1;
        while k <= n && self.xb(k).is_ascii_digit() {
            k += 1;
        }
        if self.xb(k) != b'-' {
            return 0;
        }
        k += 1;
        while k <= n && self.xb(k).is_ascii_digit() {
            k += 1;
        }
        if k <= n && self.xb(k) == b'>' {
            k
        } else {
            0
        }
    }

    fn subname(&self, j: I) -> bool {
        let cj = self.cb(j);
        let mut k = j - 1;
        while k >= 1 && is_name(self.xb(k)) && self.cb(k) == cj {
            k -= 1;
        }
        k < j - 1 && is_name_start(self.xb(k + 1)) && self.wordstart(k + 1)
    }

    fn la_sub(&self, mut k: I) -> I {
        let n = self.n;
        let mut depth = 0;
        while k <= n {
            let cc = self.xb(k);
            if cc == b'\\' {
                k += 2;
                continue;
            }
            if cc == b'\'' {
                k = self.la_sq(k + 1);
                continue;
            }
            if cc == b'"' {
                k = self.la_dq(k + 1);
                continue;
            }
            if cc == b'`' {
                k = self.la_bq(k + 1);
                continue;
            }
            if cc == b'$' && (self.xb(k + 1) == b'(' || self.xb(k + 1) == b'{') {
                let closer = if self.xb(k + 1) == b'(' { b')' } else { b'}' };
                k = self.la_close(k + 2, closer);
                continue;
            }
            if cc == b'[' {
                depth += 1;
            } else if cc == b']' {
                if depth > 0 {
                    depth -= 1;
                } else {
                    return k + 1;
                }
            }
            k += 1;
        }
        0
    }

    fn emptyparen(&self, k: I) -> bool {
        let mut j = k - 1;
        while j >= 1 && is_blank(self.xb(j)) && self.cb(j) == b'c' {
            j -= 1;
        }
        j >= 1 && self.xb(j) == b'(' && self.cb(j) == b'c' && self.dep1(j)
    }

    fn push(&mut self, k: u8) {
        self.d += 1;
        let i = self.i;
        let np = self.np;
        let d = self.d;
        {
            let cx = self.ctxd(d);
            cx.kind = k;
            cx.par = 0;
            cx.pnp = np;
            cx.besc = 0;
            cx.cpat = 0;
            cx.cpw = 0;
            cx.adol = 0;
            cx.glc = 0;
            cx.cst = i;
        }
        if k == b'D' {
            self.dq += 1;
        }
        if k == b'H' {
            self.hn += 1;
            if self.hn == 1 {
                self.hb1 = self.dc;
            }
        }
        if k != b'C' {
            self.dc += 1;
        }
        if k == b'S' || k == b'B' {
            self.nsub += 1;
            let ns = self.nsub as usize;
            if self.sbeg.len() <= ns {
                self.sbeg.resize(ns + 1, 0);
                self.send.resize(ns + 1, 0);
                self.skind.resize(ns + 1, 0);
                self.sparent.resize(ns + 1, 0);
            }
            self.sbeg[ns] = i + 1;
            self.send[ns] = self.n;
            self.skind[ns] = k;
            self.sparent[ns] = (1..d).rev().find(|&at| matches!(self.ctx[at as usize].kind, b'S' | b'B'))
                .map(|at| self.ctx[at as usize].sid).unwrap_or(0);
            self.ctxd(d).sid = ns as I;
        }
    }

    fn pop(&mut self) {
        if self.d > 1 {
            let d = self.d as usize;
            let kind = self.ctx[d].kind;
            let i = self.i;
            if kind == b'S' || kind == b'B' {
                let sid = self.ctx[d].sid as usize;
                self.send[sid] = if self.ctx[d].besc != 0 { i - 2 } else { i - 1 };
            }
            if (kind == b'S' || kind == b'B') && self.np > self.ctx[d].pnp {
                self.np = self.ctx[d].pnp;
                self.pend.truncate(self.np as usize);
            }
            if kind == b'D' {
                self.dq -= 1;
            }
            if kind == b'H' {
                self.hn -= 1;
            }
            if kind != b'C' {
                self.dc -= 1;
            }
            self.d -= 1;
        }
    }

    fn group_close(&mut self) {
        if !self.unterm {
            if !self.wantst {
                let (_, _, g) = self.starts(self.rd);
                self.gor = g;
            }
            if !self.shz && !(self.wantst && self.shb) {
                let (_, _, g) = self.starts(Reading::Zsh);
                self.goz = g;
            }
            if self.shb && !self.wantst {
                let (_, _, g) = self.starts(Reading::Dash);
                self.god = g;
            }
        }
        let n = self.n;
        let (mut zg, mut bg, mut bd) = (0i32, 0i32, 0i32);
        let mut pp: Vec<I> = Vec::new();
        for k in 1..=n {
            if if self.shz { self.gor.has(k) } else { self.goz.has(k) } {
                zg += 1;
            }
            if self.gor.has(k) {
                bg += 1;
            }
            if self.god.has(k) {
                bd += 1;
            }
            if !self.rb.has(k) {
                continue;
            }
            if !self.rbt.has(k) {
                self.nc.set(k);
                continue;
            }
            let end = k == n || matches!(self.xb(k + 1), b' ' | b'\t' | b'\n' | b';' | b'&' | b'|' | b')' | b'<' | b'>' | b'`');
            if self.wordstart(k) && !(self.drop.has(k - 1) && matches!(self.xb(k - 1), b';' | b'&' | b'|')) {
                if end && zg > 0 {
                    zg -= 1;
                }
                if end && bg > 0 {
                    bg -= 1;
                }
                if end && bd > 0 {
                    bd -= 1;
                }
                continue;
            }
            if !end || zg == 0 {
                self.nc.set(k);
                continue;
            }
            zg -= 1;
            if self.shz {
                self.gc.set(k);
            } else {
                pp.push(k);
            }
        }
        for &q in &pp {
            if bg > 0 {
                self.gc.set(q);
            } else {
                self.nc.set(q);
                if self.shb {
                    self.div = true;
                }
            }
        }
        if self.shb && !pp.is_empty() && (bg > 0) != (bd > 0) {
            self.div = true;
        }
    }

    fn wordstart(&self, mut j: I) -> bool {
        while j > 2 && self.cb(j - 1) == b'l' {
            j -= 2;
        }
        if j == 1 {
            return true;
        }
        if !is_sep(self.xb(j - 1)) {
            return false;
        }
        let p = self.cb(j - 1);
        p != b'e' && p != b'l' && !self.esc.has(j - 1) && !self.wc.has(j - 1)
    }

    fn cmdpos(&self, j: I) -> bool {
        let mut k = j - 1;
        while k >= 1 && (is_blank(self.xb(k)) || self.cb(k) == b'l') {
            k -= 1;
        }
        if k < 1 || matches!(self.xb(k), b'\n' | b';' | b'&' | b'|' | b'(' | b')' | b'`') {
            return true;
        }
        if self.xb(k) == b'!' {
            return self.wordstart(k) && self.cmdpos(k);
        }
        if self.xb(k) == b'{' {
            return self.wordstart(k) && (self.cmdpos(k) || self.namehead(k));
        }
        let e = k;
        while k >= 1 && self.xb(k).is_ascii_lowercase() {
            k -= 1;
        }
        let w = &self.x[(k + 1) as usize..(e + 1) as usize];
        matches!(w, b"if" | b"then" | b"else" | b"elif" | b"while" | b"until" | b"do" | b"time" | b"coproc") && self.wordstart(k + 1)
    }

    fn hdepth(&self) -> I {
        if self.hn > 0 {
            self.hb1
        } else {
            self.dc
        }
    }

    fn forlist(&self, j: I) -> bool {
        let cj = self.cb(j);
        let mut k = j - 1;
        let mut n = 0;
        loop {
            while k >= 1 && is_blank(self.xb(k)) && self.cb(k) == cj {
                k -= 1;
            }
            let e = k;
            while k >= 1 && is_name(self.xb(k)) && self.cb(k) == cj {
                k -= 1;
            }
            if e == k {
                return false;
            }
            let w = &self.x[(k + 1) as usize..(e + 1) as usize];
            if (w == b"for" || w == b"foreach") && n > 0 {
                return self.wordstart(k + 1) && self.cmdpos(k + 1);
            }
            n += 1;
            if k >= 1 && !is_blank(self.xb(k)) {
                return false;
            }
        }
    }

    fn namehead(&self, j: I) -> bool {
        let mut k = j - 1;
        while k >= 1 && (is_blank(self.xb(k)) || self.cb(k) == b'l') {
            k -= 1;
        }
        if k < 1 || is_sep(self.xb(k)) {
            return false;
        }
        while k >= 1 && !is_sep(self.xb(k)) {
            k -= 1;
        }
        while k >= 1 && (is_blank(self.xb(k)) || self.cb(k) == b'l') {
            k -= 1;
        }
        let e = k;
        while k >= 1 && self.xb(k).is_ascii_lowercase() {
            k -= 1;
        }
        let w = &self.x[(k + 1) as usize..(e + 1) as usize];
        (w == b"function" || w == b"coproc")
            && (k < 1 || matches!(self.xb(k), b' ' | b'\t' | b'\n' | b';' | b'&' | b'|' | b'(' | b'!' | b'{' | b')' | b'`'))
    }

    fn arith_or_sub(&mut self, j: I, dollar: I) -> I {
        let k = j + dollar + 2;
        let a: bool;
        if self.shd {
            a = dollar != 0;
        } else if self.shz {
            a = self.la(k, true) != 0;
        } else {
            let ab = self.la(k, false) != 0;
            let az = self.la(k, true) != 0;
            if ab != az || az != (dollar != 0) {
                self.div = true;
            }
            a = ab;
        }
        if a {
            let i = j + dollar + 1;
            self.i = i;
            self.push(b'A');
            let d = self.d;
            self.ctxd(d).adol = dollar;
            return i;
        }
        if dollar != 0 {
            let i = j + 1;
            self.i = i;
            self.push(b'S');
            i
        } else {
            let i = j + 1;
            let d = self.d;
            let par = self.ctx[d as usize].par;
            self.gl.remove(&(d, par + 1));
            self.gl.remove(&(d, par + 2));
            self.ctxd(d).par += 2;
            i
        }
    }

    fn la(&self, mut k: I, lit: bool) -> i32 {
        let n = self.n;
        let mut depth = 0;
        while k <= n {
            let cc = self.xb(k);
            if cc == b'\\' {
                k += 2;
                continue;
            }
            if cc == b'$' && (self.xb(k + 1) == b'(' || self.xb(k + 1) == b'{') {
                let closer = if self.xb(k + 1) == b'(' { b')' } else { b'}' };
                k = self.la_close(k + 2, closer);
                continue;
            }
            if cc == b'`' {
                k = self.la_bq(k + 1);
                continue;
            }
            if !lit && cc == b'\'' {
                k = self.la_sq(k + 1);
                continue;
            }
            if !lit && cc == b'"' {
                k = self.la_dq(k + 1);
                continue;
            }
            if cc == b'(' {
                depth += 1;
            } else if cc == b')' {
                if depth > 0 {
                    depth -= 1;
                } else {
                    return if self.xb(k + 1) == b')' { 1 } else { 0 };
                }
            }
            k += 1;
        }
        -1
    }

    fn la_close(&self, mut k: I, closer: u8) -> I {
        let n = self.n;
        let mut depth = 0;
        while k <= n {
            let cc = self.xb(k);
            if cc == b'\\' {
                k += 2;
                continue;
            }
            if cc == b'\'' {
                k = self.la_sq(k + 1);
                continue;
            }
            if cc == b'"' {
                k = self.la_dq(k + 1);
                continue;
            }
            if cc == b'`' {
                k = self.la_bq(k + 1);
                continue;
            }
            if cc == b'$' && (self.xb(k + 1) == b'(' || self.xb(k + 1) == b'{') {
                let cl = if self.xb(k + 1) == b'(' { b')' } else { b'}' };
                k = self.la_close(k + 2, cl);
                continue;
            }
            if closer == b')' && cc == b'(' {
                depth += 1;
            } else if cc == closer {
                if depth > 0 {
                    depth -= 1;
                } else {
                    return k + 1;
                }
            }
            k += 1;
        }
        n + 1
    }

    fn la_sq(&self, mut k: I) -> I {
        while k <= self.n && self.xb(k) != b'\'' {
            k += 1;
        }
        k + 1
    }

    fn la_dq(&self, mut k: I) -> I {
        let n = self.n;
        while k <= n {
            let cc = self.xb(k);
            if cc == b'\\' {
                k += 2;
                continue;
            }
            if cc == b'"' {
                return k + 1;
            }
            if cc == b'`' {
                k = self.la_bq(k + 1);
                continue;
            }
            if cc == b'$' && (self.xb(k + 1) == b'(' || self.xb(k + 1) == b'{') {
                let cl = if self.xb(k + 1) == b'(' { b')' } else { b'}' };
                k = self.la_close(k + 2, cl);
                continue;
            }
            k += 1;
        }
        n + 1
    }

    fn la_bq(&self, mut k: I) -> I {
        let n = self.n;
        while k <= n {
            if self.xb(k) == b'\\' {
                k += 2;
                continue;
            }
            if self.xb(k) == b'`' {
                return k + 1;
            }
            k += 1;
        }
        n + 1
    }

    fn heredoc_op(&mut self, j: I) -> I {
        let n = self.n;
        let mut k = j + 2;
        let mut strip = false;
        if self.xb(k) == b'-' {
            strip = true;
            k += 1;
        }
        while self.xb(k) == b' ' || self.xb(k) == b'\t' {
            k += 1;
        }
        let mut w: Vec<u8> = Vec::new();
        let mut q = false;
        while k <= n {
            let cc = self.xb(k);
            if is_sep(cc) {
                break;
            }
            if cc == b'\\' {
                q = true;
                let nx = self.xb(k + 1);
                if nx != 0 {
                    w.push(nx);
                }
                k += 2;
                continue;
            }
            if cc == b'\'' {
                q = true;
                k += 1;
                while k <= n && self.xb(k) != b'\'' {
                    w.push(self.xb(k));
                    k += 1;
                }
                k += 1;
                continue;
            }
            if cc == b'"' {
                q = true;
                k += 1;
                while k <= n && self.xb(k) != b'"' {
                    if self.xb(k) == b'\\' {
                        k += 1;
                    }
                    let b = self.xb(k);
                    if b != 0 {
                        w.push(b);
                    }
                    k += 1;
                }
                k += 1;
                continue;
            }
            w.push(cc);
            k += 1;
        }
        if w.is_empty() {
            let cls = self.cls;
            self.setc(j, cls);
            return j;
        }
        let mut p_s = false;
        let mut sk = self.d;
        while sk > 1 {
            if self.ck(sk) == b'S' {
                p_s = true;
                break;
            }
            sk -= 1;
        }
        let pb = self.ck(self.d) == b'B';
        self.np += 1;
        self.pend.truncate((self.np - 1) as usize);
        self.pend.push(Pending { pd: w, ps: strip, pq: q, pstart: j, pb, p_s });
        let mut mm = self.fdword(j);
        while mm < k && mm <= n {
            self.setc(mm, b'h');
            let hd = self.hdepth();
            self.wd.set(mm, hd);
            mm += 1;
        }
        k - 1
    }

    fn at_newline(&mut self, j: I) -> I {
        let n = self.n;
        let v = if self.dq > 0 {
            b'Q'
        } else if self.hn > 0 {
            b'B'
        } else {
            b'c'
        };
        self.setc(j, v);
        if self.np == 0 {
            return j;
        }
        let mut s = j + 1;
        let np = self.np as usize;
        for p in 1..=np {
            let mut fed = false;
            let pstart = self.pend[p - 1].pstart;
            let mut kk = pstart;
            while kk < j {
                if self.xb(kk) == b'|' && matches!(self.cb(kk), b'c' | b'Q' | b'B') {
                    if self.xb(kk + 1) == b'|' || self.xb(kk - 1) == b'|' {
                        kk += 1;
                        continue;
                    }
                    fed = true;
                }
                kk += 1;
            }
            if self.pfed.len() <= p {
                self.pfed.resize(p + 1, false);
            }
            self.pfed[p] = fed;
            let mut done = false;
            let bs = s;
            let pd = self.pend[p - 1].pd.clone();
            let ps = self.pend[p - 1].ps;
            let pq = self.pend[p - 1].pq;
            let pb = self.pend[p - 1].pb;
            let p_s = self.pend[p - 1].p_s;
            while s <= n {
                let mut e = s;
                let mut line: Vec<u8> = Vec::new();
                loop {
                    while e <= n && self.xb(e) != b'\n' {
                        line.push(self.xb(e));
                        e += 1;
                    }
                    if !pq && e <= n && odd_trailing_backslashes(&line) {
                        line.pop();
                        e += 1;
                        continue;
                    }
                    break;
                }
                let mut t: &[u8] = &line;
                if ps {
                    while t.first() == Some(&b'\t') {
                        t = &t[1..];
                    }
                }
                let mut pdp = pd.clone();
                pdp.push(b')');
                let mut pdb = pd.clone();
                pdb.push(b'`');
                if self.shb && p_s && t.starts_with(&pdp) {
                    self.div = true;
                }
                if pb && t.starts_with(&pdb) || self.shb && p_s && t.starts_with(&pdp) {
                    let lead = (line.len() - t.len()) as I;
                    self.body_region(bs, s - 1, p);
                    let lim = s + lead + pd.len() as I;
                    let mut kk = s;
                    while kk < lim {
                        self.setc(kk, b'b');
                        let hd = self.hdepth();
                        self.wd.set(kk, hd);
                        kk += 1;
                    }
                    if lim - 1 >= s {
                        self.jmp.set(s, lim - 1);
                    }
                    self.np = 0;
                    self.pend.clear();
                    return j;
                }
                if t == pd.as_slice() {
                    self.body_region(bs, s - 1, p);
                    let mut kk = s;
                    while kk < e {
                        self.setc(kk, b'b');
                        let hd = self.hdepth();
                        self.wd.set(kk, hd);
                        kk += 1;
                    }
                    if e <= n {
                        self.setc(e, b'b');
                        let hd = self.hdepth();
                        self.wd.set(e, hd);
                    }
                    self.jmp.set(s, if e <= n { e } else { n });
                    s = e + 1;
                    done = true;
                    break;
                }
                s = e + 1;
            }
            if !done {
                self.body_region(bs, n, p);
                self.unterm = true;
            }
        }
        self.np = 0;
        self.pend.clear();
        j
    }

    fn body_region(&mut self, bs: I, be: I, p: usize) {
        if be < bs {
            return;
        }
        let mut kk = bs;
        while kk <= be {
            self.bf.set(kk, p as I);
            let hd = self.hdepth();
            self.wd.set(kk, hd);
            kk += 1;
        }
        if self.pend[p - 1].pq {
            let mut kk = bs;
            while kk <= be {
                self.setc(kk, b'b');
                kk += 1;
            }
            self.jmp.set(bs, be);
            return;
        }
        self.nh += 1;
        let nh = self.nh as usize;
        self.hstart.set(bs, nh as I);
        if self.hend.len() <= nh {
            self.hend.resize(nh + 1, 0);
        }
        self.hend[nh] = be;
    }

    // ---- emitters -------------------------------------------------------------
    fn put(&mut self, s: &[u8]) {
        self.out.extend_from_slice(s);
    }
    fn put1(&mut self, b: u8) {
        self.out.push(b);
    }

    fn emit_cscripts(&mut self) {
        self.cscripts_range(1, self.n);
        if self.aqbad {
            self.put(b"!\n");
        }
    }

    fn cscripts_range(&mut self, a: I, n: I) {
        let mut words: Vec<Vec<u8>> = Vec::new();
        let mut units: Vec<String> = Vec::new();
        let mut starts: Vec<I> = Vec::new();
        let mut w: Vec<u8> = Vec::new();
        let mut ws = String::new();
        let mut inw = false;
        let mut k: I = a;
        while k <= n + 1 {
            if k > n || self.word_sep(k) {
                if inw {
                    words.push(std::mem::take(&mut w));
                    units.push(std::mem::take(&mut ws));
                    inw = false;
                }
                if k > n
                    || self.cb(k) == b'p'
                    || self.cb(k) == b'c' && self.dep1(k) && matches!(self.xb(k), b'\n' | b';' | b'&' | b'|' | b'(' | b')')
                {
                    self.cscripts_of(&words, &units, &starts);
                    words.clear();
                    units.clear();
                    starts.clear();
                }
                k += 1;
                continue;
            }
            if !inw { starts.push(k); }
            inw = true;
            if self.drop.has(k) {
                k += 1;
                continue;
            }
            if let Some(v) = self.valb(k) {
                w.push(v);
                ws.push_str(&format!(" #{}", v));
            } else if !self.rmb(k) {
                w.push(self.xb(k));
                ws.push_str(&format!(" {}", k));
            }
            k += 1;
        }
    }

    fn units_drop(s: &str, cnt: usize) -> String {
        let t = awk_split(s);
        let mut out = String::new();
        for u in t.iter().skip(cnt) {
            out.push(' ');
            out.push_str(u);
        }
        out
    }

    fn runs(&self, s: &str) -> String {
        let t = awk_split(s);
        let mut rn = String::new();
        let mut rc = String::new();
        let mut rcn = 0usize;
        let mut ra: I = 0;
        let mut rl: I = 0;
        fn rc_add(rc: &mut String, rcn: &mut usize, c: &str) {
            if *rcn > 0 {
                rc.push('#');
            }
            *rcn += 1;
            rc.push_str(c);
        }
        fn rc_flush(rn: &mut String, rc: &mut String, rcn: &mut usize) {
            if *rcn > 0 {
                rn.push_str(" #");
                rn.push_str(rc);
            }
            rc.clear();
            *rcn = 0;
        }
        fn rl_flush(rn: &mut String, ra: I, rl: &mut I) {
            if *rl > 0 {
                rn.push_str(&format!(" {}:{}", ra, rl));
            }
            *rl = 0;
        }
        for u in t {
            if let Some(code) = u.strip_prefix('#') {
                if rl > 0 && rl < 4 && self.ascii_run(ra, rl) {
                    let mut v = ra;
                    while v < ra + rl {
                        let o = self.xb(v) as u32;
                        rc_add(&mut rc, &mut rcn, &o.to_string());
                        v += 1;
                    }
                    rl = 0;
                } else if rl > 0 {
                    rc_flush(&mut rn, &mut rc, &mut rcn);
                    rl_flush(&mut rn, ra, &mut rl);
                }
                rc_add(&mut rc, &mut rcn, code);
                continue;
            }
            let v: I = awk_num(u);
            if rl > 0 && v == ra + rl {
                rl += 1;
                continue;
            }
            if rl > 0 {
                rc_flush(&mut rn, &mut rc, &mut rcn);
                rl_flush(&mut rn, ra, &mut rl);
            }
            ra = v;
            rl = 1;
        }
        rc_flush(&mut rn, &mut rc, &mut rcn);
        rl_flush(&mut rn, ra, &mut rl);
        rn
    }

    fn ascii_run(&self, a: I, l: I) -> bool {
        let mut v = a;
        while v < a + l {
            let b = self.xb(v);
            if !(1..=127).contains(&b) {
                return false;
            }
            v += 1;
        }
        true
    }

    fn cscripts_of(&mut self, w: &[Vec<u8>], ws: &[String], starts: &[I]) {
        let n = w.len();
        // 1-based views of the word arrays, as the awk reads them.
        let wv = |m: usize| -> &[u8] { if m >= 1 && m <= n { &w[m - 1] } else { b"" } };
        let wsv = |m: usize| -> &str { if m >= 1 && m <= n { &ws[m - 1] } else { "" } };
        let mut j = 1usize;
        while j <= n {
            if self.payloads.is_some() && !self.ew.has(starts[j - 1]) {
                j += 1;
                continue;
            }
            let word = wv(j);
            let base: &[u8] = match word.iter().rposition(|&b| b == b'/') {
                Some(p) => &word[p + 1..],
                None => word,
            };
            if base == b"env" && j < n {
                let mut sv: Vec<u8> = Vec::new();
                let mut svs = String::new();
                let mut rest = 0usize;
                let mut m = j + 1;
                while m <= n && rest == 0 {
                    let wm = wv(m);
                    if wm == b"--" || wm.first() != Some(&b'-') && !is_assign_word(wm) {
                        break;
                    }
                    if wm.starts_with(b"--split-string=") {
                        sv = wm[15..].to_vec();
                        svs = Self::units_drop(wsv(m), 15);
                        rest = m + 1;
                        break;
                    }
                    if wm == b"--split-string" {
                        if m < n {
                            sv = wv(m + 1).to_vec();
                            svs = wsv(m + 1).to_string();
                            rest = m + 2;
                        }
                        break;
                    }
                    if wm.starts_with(b"--") || wm.first() != Some(&b'-') {
                        m += 1;
                        continue;
                    }
                    let len = wm.len();
                    let mut q = 2usize;
                    while q <= len {
                        let c = wm[q - 1];
                        if matches!(c, b'u' | b'C' | b'P') {
                            if q == len {
                                m += 1;
                            }
                            break;
                        }
                        if c == b'S' {
                            if q < len {
                                sv = wm[q..].to_vec();
                                svs = Self::units_drop(wsv(m), q);
                                rest = m + 1;
                            } else if m < n {
                                sv = wv(m + 1).to_vec();
                                svs = wsv(m + 1).to_string();
                                rest = m + 2;
                            }
                            break;
                        }
                        q += 1;
                    }
                    if rest != 0 {
                        break;
                    }
                    m += 1;
                }
                if rest != 0 {
                    if sv.iter().any(|&b| b == b'$' || b == b'`') {
                        if self.payloads.is_some() { self.smfail = true; }
                        self.put(b"!\n");
                        break;
                    }
                    let mut ev = svs;
                    for m in rest..=n {
                        ev.push_str(" #32");
                        ev.push_str(wsv(m));
                    }
                    self.capture_payload(b'E', &ev, PayloadOrigin::EnvSplit, None);
                    let r = self.runs(&ev);
                    self.put(b"E");
                    self.put(r.as_bytes());
                    self.put(b"\n");
                    break;
                }
                j += 1;
                continue;
            }
            let is_shell = match &self.g.shre {
                Some(re) => re.is_match(base),
                None => false,
            };
            if is_shell && j < n {
                let mut m = j + 1;
                while m <= n {
                    let wm = wv(m);
                    if is_opt_o(wm) {
                        m += 2;
                        continue;
                    }
                    if is_opt_c(wm) {
                        let mut s = m + 1;
                        if s <= n && wv(s) == b"--" {
                            s += 1;
                        }
                        if s <= n {
                            self.capture_payload(b'S', wsv(s), PayloadOrigin::ShellC, Some(word));
                            let r = self.runs(wsv(s));
                            self.put(b"S");
                            self.put(r.as_bytes());
                            self.put(b"\n");
                            j = s;
                        }
                        break;
                    }
                    if is_opt_cluster(wm) || wm == b"--" {
                        m += 1;
                        continue;
                    }
                    break;
                }
                j += 1;
                continue;
            }
            if word == b"eval" && j < n {
                let mut ev = String::new();
                for m in (j + 1)..=n {
                    if m > j + 1 {
                        ev.push_str(" #32");
                    }
                    ev.push_str(wsv(m));
                }
                self.capture_payload(b'E', &ev, PayloadOrigin::Eval, None);
                let r = self.runs(&ev);
                self.put(b"E");
                self.put(r.as_bytes());
                self.put(b"\n");
                break;
            }
            j += 1;
        }
    }

    fn emit_substs(&mut self) {
        let mut out: Vec<u8> = Vec::new();
        for k in 1..=self.nsub as usize {
            let a = self.sbeg[k];
            let z = self.send[k];
            let mut su = String::new();
            let mut t = a;
            while t <= z {
                if self.skind[k] == b'B' && self.xb(t) == b'\\' && t < z && matches!(self.xb(t + 1), b'`' | b'\\' | b'$') {
                    t += 1;
                }
                su.push_str(&format!(" {}", t));
                t += 1;
            }
            let origin = match self.skind[k] {
                b'B' => PayloadOrigin::Backquote,
                b'P' => PayloadOrigin::ProcessSubstitution,
                _ => PayloadOrigin::CommandSubstitution,
            };
            // The structural API is one level. The legacy textual substs
            // view still lists all bodies, as the bash reference does.
            if self.sparent[k] == 0 { self.capture_payload(b'B', &su, origin, None); }
            out.push(b'B');
            out.extend_from_slice(self.runs(&su).as_bytes());
            out.push(b'\n');
        }
        self.out.extend_from_slice(&out);
    }

    fn cbyte(&self, k: I) -> u8 {
        let cc = self.xb(k);
        let cl = self.cb(k);
        if self.nc.has(k) {
            return if matches!(cl, b'c' | b'Q' | b'B') { b'%' } else { b' ' };
        }
        if cl == b'c' || cl == b'p' {
            let pc = self.cb(k - 1);
            return if cc == b'#' && (k == 1 || pc != b'c' && pc != b'e' || pc == b'e' && is_blank(self.xb(k - 1))) {
                b'_'
            } else {
                cc
            };
        }
        if cl == b'e' {
            return if b";&|()<>!{}#`\"'\\$".contains(&cc) && cc != 0 {
                b'_'
            } else if cc == b'\n' {
                b' '
            } else {
                cc
            };
        }
        b' '
    }

    fn sbyte(&self, k: I) -> u8 {
        let cc = self.xb(k);
        if self.cb(k) == b'c' && self.drop.has(k) && cc == b'&' && self.xb(k + 1) == b'>' {
            return b' ';
        }
        if self.cb(k) == b'c' && (!self.dep1(k) || self.drop.has(k)) && matches!(cc, b';' | b'&' | b'|' | b'\n') {
            return if cc == b'\n' { b' ' } else { b'_' };
        }
        self.cbyte(k)
    }

    fn topsep(&self, k: I) -> bool {
        self.cb(k) == b'p' || self.cb(k) == b'c' && self.dep1(k) && !self.drop.has(k) && matches!(self.xb(k), b';' | b'&' | b'|' | b'\n')
    }

    fn emit_events(&mut self) {
        let mut out = String::new();
        for k in 1..=self.n {
            let cls = |b: u8| if b == UNSET { String::new() } else { (b as char).to_string() };
            if self.ev.has(k) {
                let prev = if k > 1 { cls(self.cb(k - 1)) } else { "-".to_string() };
                out.push_str(&format!(
                    "S {} {} {} {} {}\n",
                    k,
                    cls(self.cb(k)),
                    self.dep.num(k),
                    self.bare(k) as i32,
                    prev
                ));
            }
            if self.ew.has(k) {
                out.push_str(&format!("W {} {} {}\n", k, cls(self.cb(k)), self.dep.num(k)));
            }
        }
        self.out.extend_from_slice(out.as_bytes());
    }

    fn emit_stmtcuts(&mut self) {
        let mut out: Vec<u8> = Vec::new();
        let mut first = true;
        for k in 1..=self.n {
            if self.ev.has(k) && self.bare(k) {
                if !first {
                    out.push(b' ');
                }
                out.extend_from_slice(k.to_string().as_bytes());
                first = false;
            }
        }
        out.push(b'\n');
        for k in 1..=self.n {
            out.push(self.sbyte(k));
        }
        self.out.extend_from_slice(&out);
    }

    fn emit_stmtraw(&mut self) {
        let mut out: Vec<u8> = Vec::with_capacity(self.n as usize);
        for k in 1..=self.n {
            let cl = self.cb(k);
            let xk = self.xb(k);
            if cl == b'l' {
                out.push(0x01);
            } else if matches!(cl, b'm' | b'h' | b'b' | b'B') {
                out.push(if xk == b'\n' { b'\n' } else { b' ' });
            } else if xk == b'\n' && cl != b'c' {
                out.push(b' ');
            } else if xk == 0x01 {
                out.push(0x02);
            } else {
                out.push(xk);
            }
        }
        self.out.extend_from_slice(&out);
    }

    fn emit_cwords(&mut self) {
        let n = self.n;
        let fbyte = |b: u8| if b == 0x1f || b == 0x1e || b == b'\n' { b' ' } else { b };
        let mut out: Vec<u8> = Vec::new();
        for k in 1..=n {
            if !self.ev.has(k) {
                continue;
            }
            let mut w = k;
            while w <= n
                && !(w > k && self.ev.has(w))
                && (self.a.has(w) || is_blank(self.xb(w)) && self.cb(w) == b'c' && self.dep1(w))
            {
                w += 1;
            }
            if w > n || (w > k && self.ev.has(w)) || self.topsep(w) || self.word_sep(w) {
                continue;
            }
            out.extend_from_slice(format!("{}\x1f{}\x1f", k, w).as_bytes());
            for j in k..w {
                out.push(fbyte(self.sbyte(j)));
            }
            out.push(0x1f);
            let mut j = w;
            while j <= n && !(j > w && self.ev.has(j)) && !self.topsep(j) {
                if self.cb(j) != b'l' {
                    out.push(fbyte(if self.drop.has(j) { b' ' } else { self.sbyte(j) }));
                }
                j += 1;
            }
            out.push(0x1f);
            let mut j = w;
            while j <= n && !(j > w && self.ev.has(j)) && !self.topsep(j) {
                out.push(fbyte(if self.drop.has(j) { b' ' } else { self.sbyte(j) }));
                j += 1;
            }
            out.push(b'\n');
        }
        self.out.extend_from_slice(&out);
    }

    fn emit_pieces(&mut self) {
        let n = self.n;
        let mut nn: I = 1;
        let mut a: I = 1;
        let mut k: I = 1;
        while k <= n {
            if self.ev.has(k) && self.bare(k) {
                self.piece(a, k - 1, nn);
                nn += 1;
                a = k;
            }
            let ch = self.sbyte(k);
            // group_close already removed this delimiter from the words.
            // End their statement here too: text after the group is not an
            // argument of the command before it. This is a lexical boundary,
            // not a claim that the whole shell program is valid.
            if ch == b';' || ch == b'\n' || self.gc.has(k) {
                self.piece(a, k - 1, nn);
                nn += 1;
                a = k + 1;
                k += 1;
                continue;
            }
            if ch == b'&' {
                self.piece(a, k - 1, nn);
                nn += 1;
                if k < n && self.sbyte(k + 1) == b'&' {
                    k += 1;
                }
                a = k + 1;
                k += 1;
                continue;
            }
            if ch == b'|' {
                self.piece(a, k - 1, nn);
                nn += 1;
                if k < n && (self.sbyte(k + 1) == b'|' || self.sbyte(k + 1) == b'&') {
                    k += 1;
                }
                a = k + 1;
                k += 1;
                continue;
            }
            k += 1;
        }
        self.piece(a, n, nn);
        if self.aqbad {
            self.put(b"!\n");
        }
    }

    fn pbyte(&self, k: I) -> u8 {
        let ck = self.cb(k);
        if self.drop.has(k) || matches!(ck, b'm' | b'h' | b'b' | b'l' | b'p') {
            return b' ';
        }
        let cc = self.xb(k);
        if cc == b'\n' {
            return if matches!(ck, b'c' | b'Q' | b'B') { b';' } else { b' ' };
        }
        if cc == 0x1f || cc == 0x1e || cc == b'\t' {
            return b' ';
        }
        cc
    }

    fn wbyte(&self, k: I) -> u8 {
        let b = self.xb(k);
        if matches!(b, b' ' | b'\t' | b'\n' | b'(' | b')' | b'{' | b'}' | 0x1e | 0x1f) {
            0x02
        } else {
            b
        }
    }

    fn pwords(&mut self, a: I, z: I, pre: bool) {
        let mut w = 0;
        let mut k = a;
        while k <= z {
            if !pre && self.a.has(k) {
                k += 1;
                continue;
            }
            let v = self.valb(k);
            if self.drop.has(k) || self.gc.has(k) || v.is_none() && !self.rmb(k) && self.word_sep(k) {
                if w == 1 {
                    self.put1(0x02);
                }
                w = 0;
                let b = if self.drop.has(k) || self.gc.has(k) { b' ' } else { self.pbyte(k) };
                self.put1(b);
                k += 1;
                continue;
            }
            if w == 0 {
                w = 1;
            }
            if let Some(vb) = v {
                let o = if matches!(vb, b' ' | b'\t' | b'\n' | b'(' | b')' | b'{' | b'}' | 0x1e | 0x1f) { 0x02 } else { vb };
                self.put1(o);
                w = 2;
            } else if !self.rmb(k) {
                let b = self.wbyte(k);
                self.put1(b);
                w = 2;
            }
            k += 1;
        }
        if w == 1 {
            self.put1(0x02);
        }
    }

    /// The words `pwords(a, z, false)` prints, with where each stands: the
    /// same tests in the same order, so the two cannot read a word apart.
    fn word_spans(&self, a: I, z: I) -> Vec<WordSpan> {
        let mut out: Vec<WordSpan> = Vec::new();
        let mut w = 0;
        let mut ws: I = 0;
        let mut we: I = 0;
        let mut value: Vec<u8> = Vec::new();
        let mut k = a;
        while k <= z {
            if self.a.has(k) {
                k += 1;
                continue;
            }
            let v = self.valb(k);
            if self.drop.has(k) || self.gc.has(k) || v.is_none() && !self.rmb(k) && self.word_sep(k) {
                if w != 0 {
                    out.push(WordSpan { start: (ws - 1) as usize, end: we as usize, value: std::mem::take(&mut value) });
                }
                w = 0;
                k += 1;
                continue;
            }
            if w == 0 {
                w = 1;
                ws = k;
            }
            we = k;
            if let Some(vb) = v {
                value.push(vb);
                w = 2;
            } else if !self.rmb(k) {
                value.push(self.xb(k));
                w = 2;
            }
            k += 1;
        }
        if w != 0 {
            out.push(WordSpan { start: (ws - 1) as usize, end: we as usize, value });
        }
        out
    }

    fn precog(&mut self, a: I, z: I) {
        let mut k = a;
        while k <= z {
            if self.ev.has(k) && self.bare(k) {
                self.put1(b';');
            }
            if self.a.has(k) || self.cb(k) == b'l' {
                k += 1;
                continue;
            }
            let cc = if self.drop.has(k) && !self.unterm { b' ' } else { self.sbyte(k) };
            let o = if matches!(cc, b'\n' | b'\t' | 0x1f | 0x1e) { b' ' } else { cc };
            self.put1(o);
            k += 1;
        }
    }

    fn piece(&mut self, a: I, z: I, nn: I) {
        if self.view == "cscripts" && self.payloads.is_some() {
            self.cscripts_range(a, z);
            return;
        }
        let mut any = false;
        let mut k = a;
        while k <= z {
            if !self.drop.has(k) && !matches!(self.xb(k), b' ' | b'\t' | b'\n') && !matches!(self.cb(k), b'm' | b'h' | b'b' | b'B' | b'l') {
                any = true;
                break;
            }
            k += 1;
        }
        if !any {
            return;
        }
        if self.spans.is_some() {
            let words = self.word_spans(a, z);
            if let Some(v) = self.spans.as_mut() {
                v.push(PieceSpan { nn: nn as usize, start: (a - 1).max(0) as usize, end: z.max(a - 1).max(0) as usize, words });
            }
        }
        self.put(nn.to_string().as_bytes());
        self.put1(0x1f);
        let mut k = a;
        while k <= z {
            let b = self.pbyte(k);
            self.put1(b);
            k += 1;
        }
        self.put1(0x1f);
        self.pwords(a, z, true);
        self.put1(0x1f);
        self.pwords(a, z, false);
        self.put1(0x1f);
        self.precog(a, z);
        self.put1(b'\n');
    }

    fn emit(&mut self) -> Result<(), UnknownView> {
        let n = self.n;
        let view = self.view.clone();
        let v = view.as_str();
        if v == "shell-bodies" {
            for k in 1..=n {
                if let Some(p) = self.bf.get(k) {
                    let fed = self.pfed.get(p as usize).copied().unwrap_or(false);
                    if fed {
                        let b = self.xb(k);
                        self.put1(b);
                    } else if self.xb(k) == b'\n' {
                        self.put1(b'\n');
                    }
                } else if self.cb(k) == b'b' && self.xb(k) == b'\n' {
                    self.put1(b'\n');
                }
            }
            return Ok(());
        }
        let known = matches!(v, "classes" | "noredir" | "stmts" | "recognize" | "cmdword" | "scan" | "live" | "flat" | "noprefix" | "unprefixed" | "code");
        if !known && !self.wends {
            if n >= 1 {
                return Err(UnknownView);
            }
            return Ok(());
        }
        let mut out: Vec<u8> = Vec::with_capacity(n as usize + 8);
        for k in 1..=n {
            let cc = self.xb(k);
            let cl = self.cb(k);
            if self.wends {
                out.push(if k > 1 && self.word_sep(k) && !self.word_sep(k - 1) { b'1' } else { b'0' });
                continue;
            }
            match v {
                "classes" => {
                    let fed = self.bf.get(k).map(|p| self.pfed.get(p as usize).copied().unwrap_or(false)).unwrap_or(false);
                    out.push(if fed {
                        b'F'
                    } else if cl == UNSET {
                        b'.'
                    } else {
                        cl
                    });
                }
                "noredir" => out.push(if self.drop.has(k) { b' ' } else { cc }),
                "stmts" => out.push(self.sbyte(k)),
                "recognize" => {
                    if self.ev.has(k) && self.bare(k) {
                        out.push(b';');
                    }
                    if self.a.has(k) || cl == b'l' {
                        continue;
                    }
                    out.push(if self.drop.has(k) && !self.unterm { b' ' } else { self.sbyte(k) });
                }
                "cmdword" => {
                    if cl == b'p' {
                        out.push(b';');
                    } else if self.a.has(k) || matches!(cl, b'm' | b'h' | b'b' | b'x' | b'l') {
                        out.push(if cc == b'\n' && cl != b'h' && cl != b'l' { b'\n' } else { b' ' });
                    } else if cl == b'e' {
                        out.push(if cc != 0 && b";&|()<>!{}#`\"'\\$ \t\n".contains(&cc) { b'_' } else { cc });
                    } else {
                        out.push(cc);
                    }
                }
                "scan" | "live" | "flat" => {
                    if v == "live"
                        && self.drop.has(k)
                        && !self.keep.has(k)
                        && (cl == b'c' && (self.dep1(k) || self.psb.has(k)) || cl == b'e')
                    {
                        out.push(b' ');
                    } else if v == "flat" && self.drop.has(k) {
                        out.push(b' ');
                    } else if (v == "live" || v == "flat") && (cl == b'Q' || cl == b'B') {
                        out.push(if self.nc.has(k) { b'%' } else { cc });
                    } else {
                        out.push(self.cbyte(k));
                    }
                }
                "noprefix" => {
                    out.push(if self.drop.has(k) || self.a.has(k) && !(cc == b'\n' && cl == b'c') { b' ' } else { cc });
                }
                "unprefixed" => {
                    if self.ev.has(k) && self.bare(k) {
                        out.push(b';');
                    }
                    if !self.a.has(k) {
                        out.push(if self.drop.has(k) { b' ' } else { cc });
                    }
                }
                _ => {
                    // code
                    if matches!(cl, b'm' | b'h' | b'b') {
                        out.push(if cc == b'\n' && cl != b'h' { b'\n' } else { b' ' });
                    } else {
                        out.push(cc);
                    }
                }
            }
        }
        self.out.extend_from_slice(&out);
        Ok(())
    }
}

fn odd_trailing_backslashes(line: &[u8]) -> bool {
    let mut c = 0;
    for &b in line.iter().rev() {
        if b == b'\\' {
            c += 1;
        } else {
            break;
        }
    }
    c % 2 == 1
}

/// `w ~ /^(-[0iv]*[uCP]|--unset|--chdir)$/`
fn env_takes(w: &[u8]) -> bool {
    if w == b"--unset" || w == b"--chdir" {
        return true;
    }
    if w.len() < 2 || w[0] != b'-' {
        return false;
    }
    let last = w[w.len() - 1];
    matches!(last, b'u' | b'C' | b'P') && w[1..w.len() - 1].iter().all(|&b| matches!(b, b'0' | b'i' | b'v'))
}

/// `w ~ /^-[a-z]*[of]$/`
fn time_takes(w: &[u8]) -> bool {
    if w.len() < 2 || w[0] != b'-' {
        return false;
    }
    let last = w[w.len() - 1];
    (last == b'o' || last == b'f') && w[1..w.len() - 1].iter().all(|b| b.is_ascii_lowercase())
}

/// `W ~ /^[A-Za-z_][A-Za-z0-9_]*=/`
fn is_assign_word(w: &[u8]) -> bool {
    if w.is_empty() || !is_name_start(w[0]) {
        return false;
    }
    let mut p = 1;
    while p < w.len() && is_name(w[p]) {
        p += 1;
    }
    p < w.len() && w[p] == b'='
}

/// `W ~ /^[-+][A-Za-z]*o$/`
fn is_opt_o(w: &[u8]) -> bool {
    w.len() >= 2 && (w[0] == b'-' || w[0] == b'+') && w[w.len() - 1] == b'o' && w[1..w.len() - 1].iter().all(|b| b.is_ascii_alphabetic())
}

/// `W ~ /^-[A-Za-z]*c[A-Za-z]*$/`
fn is_opt_c(w: &[u8]) -> bool {
    w.len() >= 2 && w[0] == b'-' && w[1..].iter().all(|b| b.is_ascii_alphabetic()) && w[1..].contains(&b'c')
}

/// `W ~ /^[-+][A-Za-z]+$/`
fn is_opt_cluster(w: &[u8]) -> bool {
    w.len() >= 2 && (w[0] == b'-' || w[0] == b'+') && w[1..].iter().all(|b| b.is_ascii_alphabetic())
}

/// awk's `u + 0` for a unit: the leading number, 0 when there is none.
fn awk_num(u: &str) -> I {
    let b = u.as_bytes();
    let mut k = 0;
    let neg = if k < b.len() && (b[k] == b'-' || b[k] == b'+') {
        k += 1;
        b[0] == b'-'
    } else {
        false
    };
    let mut v: I = 0;
    while k < b.len() && b[k].is_ascii_digit() {
        v = v * 10 + (b[k] - b'0') as I;
        k += 1;
    }
    if neg {
        -v
    } else {
        v
    }
}

/// Runs one lexing and writes its side outputs where the awk program writes
/// them: UNTERM to the flags file, DIVERGE to the divergence file and the
/// memo's mark, `failed` to the scan mark.
pub fn lex_with_files(
    g: &Grammar,
    text: &[u8],
    view: &str,
    rd: Reading,
    flags: Option<&str>,
    divfile: Option<&str>,
    divmemo: Option<&str>,
    smark: Option<&str>,
) -> Result<Vec<u8>, ()> {
    let r = Lex::new(g, text, view, rd).run();
    let side = match &r {
        Ok((_, s)) => s.clone(),
        Err((_, s)) => s.clone(),
    };
    let append = |path: &str, line: &[u8]| -> bool {
        match std::fs::OpenOptions::new().create(true).append(true).open(path) {
            Ok(mut f) => f.write_all(line).is_ok(),
            Err(_) => false,
        }
    };
    let mut ok = true;
    // The awk program writes UNTERM first, then `failed` (inside the walk),
    // then DIVERGE.
    if side.unterm {
        if let Some(f) = flags.filter(|f| !f.is_empty()) {
            ok &= append(f, b"UNTERM\n");
        }
    }
    if side.smfail {
        if let Some(f) = smark.filter(|f| !f.is_empty()) {
            ok &= append(f, b"failed\n");
        }
    }
    if side.diverge {
        if let Some(f) = divfile.filter(|f| !f.is_empty()) {
            ok &= append(f, b"DIVERGE\n");
        }
        if let Some(f) = divmemo.filter(|f| !f.is_empty()) {
            ok &= std::fs::write(f, b"DIVERGE\n").is_ok();
        }
    }
    match r {
        Ok((out, _)) if ok => Ok(out),
        _ => Err(()),
    }
}
