//! POSIX extended regular expressions, the way the guard's `grep -E` and
//! bash `=~` read the grammar's patterns: bytes in the C locale, ASCII case
//! folding when asked (`grep -i`, `shopt -s nocasematch`), and a yes or no
//! answer. Nothing here reports where a match is: a reader that needs the
//! parts of a match reads them with code of its own, written beside the
//! pattern it stands for.
//!
//! The patterns are compiled to a Thompson NFA and run as a lazily built DFA,
//! so a search is one pass over the text whatever the pattern holds. `^` and
//! `$` anchor at the ends of the text; `grep` semantics (each line on its own)
//! are `Regex::grep_lines`.

use std::cell::RefCell;
use std::collections::HashMap;

type Set = [u64; 4];

fn set_has(s: &Set, b: u8) -> bool {
    s[(b >> 6) as usize] & (1u64 << (b & 63)) != 0
}
fn set_add(s: &mut Set, b: u8) {
    s[(b >> 6) as usize] |= 1u64 << (b & 63);
}

#[derive(Clone, Debug)]
enum Node {
    Set(Set),
    Bol,
    Eol,
    Cat(Vec<Node>),
    Alt(Vec<Node>),
    Repeat(Box<Node>, u32, Option<u32>),
}

#[derive(Clone, Copy, Debug)]
enum Inst {
    Set(u32),
    Split(u32, u32),
    Jmp(u32),
    Bol,
    Eol,
    Match,
}

#[derive(Debug)]
pub struct Error(pub String);

struct Parser<'a> {
    p: &'a [u8],
    i: usize,
    icase: bool,
}

fn class_set(name: &str) -> Option<Set> {
    let mut s: Set = [0; 4];
    for b in 0u16..=255 {
        let c = b as u8;
        let yes = match name {
            "alpha" => c.is_ascii_alphabetic(),
            "digit" => c.is_ascii_digit(),
            "alnum" => c.is_ascii_alphanumeric(),
            "upper" => c.is_ascii_uppercase(),
            "lower" => c.is_ascii_lowercase(),
            "space" => matches!(c, b' ' | b'\t' | b'\n' | 0x0b | 0x0c | b'\r'),
            "blank" => c == b' ' || c == b'\t',
            "punct" => c.is_ascii_punctuation(),
            "print" => (0x20..=0x7e).contains(&c),
            "graph" => (0x21..=0x7e).contains(&c),
            "cntrl" => c < 0x20 || c == 0x7f,
            "xdigit" => c.is_ascii_hexdigit(),
            _ => return None,
        };
        if yes {
            set_add(&mut s, c);
        }
    }
    Some(s)
}

impl<'a> Parser<'a> {
    fn peek(&self) -> Option<u8> {
        self.p.get(self.i).copied()
    }
    fn fold(&self, mut s: Set) -> Set {
        if self.icase {
            for c in b'A'..=b'Z' {
                let l = c.to_ascii_lowercase();
                if set_has(&s, c) || set_has(&s, l) {
                    set_add(&mut s, c);
                    set_add(&mut s, l);
                }
            }
        }
        s
    }
    fn lit(&self, b: u8) -> Node {
        let mut s: Set = [0; 4];
        set_add(&mut s, b);
        Node::Set(self.fold(s))
    }
    fn alt(&mut self) -> Result<Node, Error> {
        let mut br = vec![self.cat()?];
        while self.peek() == Some(b'|') {
            self.i += 1;
            br.push(self.cat()?);
        }
        Ok(if br.len() == 1 { br.pop().unwrap() } else { Node::Alt(br) })
    }
    fn cat(&mut self) -> Result<Node, Error> {
        let mut items = Vec::new();
        while let Some(c) = self.peek() {
            if c == b'|' || c == b')' {
                break;
            }
            items.push(self.repeat()?);
        }
        Ok(Node::Cat(items))
    }
    fn number(&mut self) -> Option<u32> {
        let st = self.i;
        while matches!(self.peek(), Some(b'0'..=b'9')) {
            self.i += 1;
        }
        if st == self.i {
            return None;
        }
        std::str::from_utf8(&self.p[st..self.i]).ok()?.parse().ok()
    }
    fn repeat(&mut self) -> Result<Node, Error> {
        let mut atom = self.atom()?;
        loop {
            match self.peek() {
                Some(b'*') => {
                    self.i += 1;
                    atom = Node::Repeat(Box::new(atom), 0, None);
                }
                Some(b'+') => {
                    self.i += 1;
                    atom = Node::Repeat(Box::new(atom), 1, None);
                }
                Some(b'?') => {
                    self.i += 1;
                    atom = Node::Repeat(Box::new(atom), 0, Some(1));
                }
                Some(b'{') if matches!(self.p.get(self.i + 1), Some(b'0'..=b'9')) => {
                    self.i += 1;
                    let m = self.number().ok_or_else(|| Error("bad interval".into()))?;
                    let n = if self.peek() == Some(b',') {
                        self.i += 1;
                        if self.peek() == Some(b'}') {
                            None
                        } else {
                            Some(self.number().ok_or_else(|| Error("bad interval".into()))?)
                        }
                    } else {
                        Some(m)
                    };
                    if self.peek() != Some(b'}') {
                        return Err(Error("unclosed interval".into()));
                    }
                    self.i += 1;
                    atom = Node::Repeat(Box::new(atom), m, n);
                }
                _ => break,
            }
        }
        Ok(atom)
    }
    fn atom(&mut self) -> Result<Node, Error> {
        let c = self.peek().ok_or_else(|| Error("unexpected end".into()))?;
        self.i += 1;
        match c {
            b'(' => {
                let n = self.alt()?;
                if self.peek() != Some(b')') {
                    return Err(Error("unclosed group".into()));
                }
                self.i += 1;
                Ok(n)
            }
            b'[' => self.bracket(),
            b'.' => Ok(Node::Set([u64::MAX; 4])),
            b'^' => Ok(Node::Bol),
            b'$' => Ok(Node::Eol),
            b'\\' => {
                let e = self.peek().ok_or_else(|| Error("trailing backslash".into()))?;
                self.i += 1;
                Ok(self.lit(e))
            }
            _ => Ok(self.lit(c)),
        }
    }
    fn bracket(&mut self) -> Result<Node, Error> {
        let mut s: Set = [0; 4];
        let mut neg = false;
        if self.peek() == Some(b'^') {
            neg = true;
            self.i += 1;
        }
        let mut first = true;
        loop {
            let c = self.peek().ok_or_else(|| Error("unclosed bracket".into()))?;
            if c == b']' && !first {
                self.i += 1;
                break;
            }
            first = false;
            if c == b'[' && matches!(self.p.get(self.i + 1), Some(b':') | Some(b'.') | Some(b'=')) {
                let kind = self.p[self.i + 1];
                let st = self.i + 2;
                let mut e = st;
                while e + 1 < self.p.len() && !(self.p[e] == kind && self.p[e + 1] == b']') {
                    e += 1;
                }
                if e + 1 >= self.p.len() {
                    return Err(Error("unclosed class".into()));
                }
                let name = std::str::from_utf8(&self.p[st..e]).map_err(|_| Error("class".into()))?;
                self.i = e + 2;
                if kind == b':' {
                    let cs = class_set(name).ok_or_else(|| Error(format!("unknown class {}", name)))?;
                    for k in 0..4 {
                        s[k] |= cs[k];
                    }
                } else {
                    for &b in name.as_bytes() {
                        set_add(&mut s, b);
                    }
                }
                continue;
            }
            self.i += 1;
            let lo = c;
            if self.peek() == Some(b'-') && self.p.get(self.i + 1).is_some_and(|&n| n != b']') {
                let hi = self.p[self.i + 1];
                self.i += 2;
                if hi < lo {
                    return Err(Error("bad range".into()));
                }
                for b in lo..=hi {
                    set_add(&mut s, b);
                }
            } else {
                set_add(&mut s, lo);
            }
        }
        s = self.fold(s);
        if neg {
            for k in 0..4 {
                s[k] = !s[k];
            }
            // Folding a negated set: a byte stays out when either case of it
            // was named (grep -i reads [^a] as neither a nor A).
            if self.icase {
                for c in b'A'..=b'Z' {
                    let l = c.to_ascii_lowercase();
                    if !set_has(&s, c) || !set_has(&s, l) {
                        s[(c >> 6) as usize] &= !(1u64 << (c & 63));
                        s[(l >> 6) as usize] &= !(1u64 << (l & 63));
                    }
                }
            }
        }
        Ok(Node::Set(s))
    }
}

struct Compiler {
    prog: Vec<Inst>,
    sets: Vec<Set>,
}

impl Compiler {
    fn emit(&mut self, i: Inst) -> u32 {
        self.prog.push(i);
        (self.prog.len() - 1) as u32
    }
    fn node(&mut self, n: &Node) {
        match n {
            Node::Set(s) => {
                let idx = self.sets.len() as u32;
                self.sets.push(*s);
                self.emit(Inst::Set(idx));
            }
            Node::Bol => {
                self.emit(Inst::Bol);
            }
            Node::Eol => {
                self.emit(Inst::Eol);
            }
            Node::Cat(v) => {
                for x in v {
                    self.node(x);
                }
            }
            Node::Alt(v) => {
                // split L1, next ; L1: a ; jmp end ; next: split ... ; last
                let mut jumps = Vec::new();
                for (k, x) in v.iter().enumerate() {
                    if k + 1 < v.len() {
                        let sp = self.emit(Inst::Split(0, 0));
                        self.node(x);
                        jumps.push(self.emit(Inst::Jmp(0)));
                        let next = self.prog.len() as u32;
                        self.prog[sp as usize] = Inst::Split(sp + 1, next);
                    } else {
                        self.node(x);
                    }
                }
                let end = self.prog.len() as u32;
                for j in jumps {
                    self.prog[j as usize] = Inst::Jmp(end);
                }
            }
            Node::Repeat(x, m, n) => {
                for _ in 0..*m {
                    self.node(x);
                }
                match n {
                    None => {
                        // L: split body, end ; body ; jmp L
                        let l = self.emit(Inst::Split(0, 0));
                        self.node(x);
                        self.emit(Inst::Jmp(l));
                        let end = self.prog.len() as u32;
                        self.prog[l as usize] = Inst::Split(l + 1, end);
                    }
                    Some(n) => {
                        let mut splits = Vec::new();
                        for _ in *m..*n {
                            splits.push(self.emit(Inst::Split(0, 0)));
                            self.node(x);
                        }
                        let end = self.prog.len() as u32;
                        for s in splits {
                            self.prog[s as usize] = Inst::Split(s + 1, end);
                        }
                    }
                }
            }
        }
    }
}

struct DState {
    insts: Vec<u32>,
    matched: bool,
    eols: Vec<u32>,
    next: Vec<i32>,
}

struct Cache {
    map: HashMap<Vec<u32>, usize>,
    states: Vec<DState>,
}

pub struct Regex {
    prog: Vec<Inst>,
    sets: Vec<Set>,
    cache: RefCell<Cache>,
    start_mid: Vec<u32>,
    start_mid_matched: bool,
}

const CACHE_LIMIT: usize = 4096;

impl Regex {
    pub fn new(pattern: &str, icase: bool) -> Result<Regex, Error> {
        Self::from_bytes(pattern.as_bytes(), icase)
    }
    pub fn from_bytes(pattern: &[u8], icase: bool) -> Result<Regex, Error> {
        let mut p = Parser { p: pattern, i: 0, icase };
        let node = p.alt()?;
        if p.i != pattern.len() {
            return Err(Error(format!("unbalanced ) at {}", p.i)));
        }
        let mut c = Compiler { prog: Vec::new(), sets: Vec::new() };
        c.node(&node);
        c.emit(Inst::Match);
        let mut r = Regex {
            prog: c.prog,
            sets: c.sets,
            cache: RefCell::new(Cache { map: HashMap::new(), states: Vec::new() }),
            start_mid: Vec::new(),
            start_mid_matched: false,
        };
        let (sm, smm) = r.closure(&[0], false, false);
        r.start_mid = sm;
        r.start_mid_matched = smm;
        Ok(r)
    }

    /// The consuming instructions (and unresolved `$`) reachable from `pcs`
    /// without consuming a byte, and whether a match is.
    fn closure(&self, pcs: &[u32], at_start: bool, at_end: bool) -> (Vec<u32>, bool) {
        let mut seen = vec![false; self.prog.len()];
        let mut stack: Vec<u32> = pcs.to_vec();
        let mut out = Vec::new();
        let mut matched = false;
        while let Some(pc) = stack.pop() {
            if seen[pc as usize] {
                continue;
            }
            seen[pc as usize] = true;
            match self.prog[pc as usize] {
                Inst::Set(_) => out.push(pc),
                // The match is part of the state: two closures with the same
                // consuming instructions differ when only one reaches it, and
                // a state keyed without it handed one's answer to the other.
                Inst::Match => {
                    matched = true;
                    out.push(pc);
                }
                Inst::Split(a, b) => {
                    stack.push(b);
                    stack.push(a);
                }
                Inst::Jmp(a) => stack.push(a),
                Inst::Bol => {
                    if at_start {
                        stack.push(pc + 1)
                    }
                }
                Inst::Eol => {
                    if at_end {
                        stack.push(pc + 1)
                    } else {
                        out.push(pc)
                    }
                }
            }
        }
        out.sort_unstable();
        (out, matched)
    }

    fn state_id(&self, cache: &mut Cache, insts: Vec<u32>, matched: bool) -> usize {
        if let Some(&id) = cache.map.get(&insts) {
            return id;
        }
        let eols = insts.iter().copied().filter(|&pc| matches!(self.prog[pc as usize], Inst::Eol)).collect();
        let id = cache.states.len();
        cache.states.push(DState { insts: insts.clone(), matched, eols, next: vec![-1; 256] });
        cache.map.insert(insts, id);
        id
    }

    /// Whether the pattern matches anywhere in `text`, `^` and `$` at its ends.
    pub fn is_match(&self, text: &[u8]) -> bool {
        let mut cache = self.cache.borrow_mut();
        let (s0, m0) = self.closure(&[0], true, false);
        if m0 || self.start_mid_matched {
            return true;
        }
        let mut cur = self.state_id(&mut cache, s0, false);
        for &b in text {
            let nx = cache.states[cur].next[b as usize];
            let nid = if nx >= 0 {
                nx as usize
            } else {
                let mut targets: Vec<u32> = Vec::new();
                for &pc in &cache.states[cur].insts {
                    if let Inst::Set(si) = self.prog[pc as usize] {
                        if set_has(&self.sets[si as usize], b) {
                            targets.push(pc + 1);
                        }
                    }
                }
                let (mut set, matched) = self.closure(&targets, false, false);
                set.extend_from_slice(&self.start_mid);
                set.sort_unstable();
                set.dedup();
                if cache.states.len() >= CACHE_LIMIT {
                    let keep = cache.states[cur].insts.clone();
                    let keep_m = cache.states[cur].matched;
                    cache.map.clear();
                    cache.states.clear();
                    cur = self.state_id(&mut cache, keep, keep_m);
                }
                let nid = self.state_id(&mut cache, set, matched);
                cache.states[cur].next[b as usize] = nid as i32;
                nid
            };
            if cache.states[nid].matched {
                return true;
            }
            cur = nid;
        }
        // At the end of the text a pending `$` is satisfied.
        if cache.states[cur].eols.is_empty() {
            return false;
        }
        let next: Vec<u32> = cache.states[cur].eols.iter().map(|&pc| pc + 1).collect();
        let (_, m) = self.closure(&next, text.is_empty(), true);
        m
    }

    /// POSIX leftmost-longest: the first start where the pattern matches,
    /// and the longest match from there, as `[[ =~ ]]` reports
    /// `BASH_REMATCH[0]`. Read with a plain NFA walk: the texts asked are
    /// words.
    pub fn find(&self, text: &[u8]) -> Option<(usize, usize)> {
        for s in 0..=text.len() {
            let (mut set, m) = self.closure(&[0], s == 0, false);
            let mut last: Option<usize> = None;
            if m {
                last = Some(s);
            }
            let end_ok = |set: &Vec<u32>, pos: usize| -> bool {
                let eols: Vec<u32> = set.iter().copied().filter(|&pc| matches!(self.prog[pc as usize], Inst::Eol)).map(|pc| pc + 1).collect();
                !eols.is_empty() && self.closure(&eols, pos == 0, true).1
            };
            if s == text.len() && end_ok(&set, s) {
                last = Some(s);
            }
            let mut pos = s;
            while pos < text.len() && !set.is_empty() {
                let b = text[pos];
                let mut targets = Vec::new();
                for &pc in &set {
                    if let Inst::Set(si) = self.prog[pc as usize] {
                        if set_has(&self.sets[si as usize], b) {
                            targets.push(pc + 1);
                        }
                    }
                }
                pos += 1;
                let (ns, m) = self.closure(&targets, false, false);
                set = ns;
                if m {
                    last = Some(pos);
                }
                if pos == text.len() && end_ok(&set, pos) {
                    last = Some(pos);
                }
            }
            if let Some(e) = last {
                return Some((s, e));
            }
        }
        None
    }

    /// `grep` over a here-string: the numbers (from 1) of the lines the
    /// pattern matches. `<<< "$t"` hands grep `$t` and a newline, so the lines
    /// are `$t` cut at every newline, an empty last one included when `$t`
    /// ends in one.
    pub fn grep_lines(&self, text: &[u8]) -> Vec<usize> {
        let mut out = Vec::new();
        for (k, line) in text.split(|&b| b == b'\n').enumerate() {
            if self.is_match(line) {
                out.push(k + 1);
            }
        }
        out
    }

    /// `grep -q` over a here-string: whether any line matches.
    pub fn grep_any(&self, text: &[u8]) -> bool {
        text.split(|&b| b == b'\n').any(|line| self.is_match(line))
    }
}
