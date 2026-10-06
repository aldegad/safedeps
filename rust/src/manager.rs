//! The manager word grammar of lib/install-grammar.sh: which word of a
//! statement is the manager, which are its command, its options and their
//! values, and which are the packages it installs or runs
//! (`safedeps_manager_read`), npm's own option reading (`safedeps_npm_read_args`,
//! nopt) and npx's first pass.
//!
//! The tables are the shell file's one-line tables (tables.rs), searched the
//! way its `=~` lookups search them: a lookup here scans for the same entry the
//! regex would match first, so a key that is no option at all reads the same
//! way in both.

use crate::ere::Regex;
use crate::grammar;
use crate::tables;

type W = Vec<u8>;

fn is_entry_start(t: &[u8], i: usize) -> bool {
    i >= 1 && t[i - 1] == b' '
}

/// `" KEY[:=]([^ ]*)"`: the value of the first entry whose key is KEY.
pub fn lookup(key: &[u8], t: &[u8]) -> Option<W> {
    let kl = key.len();
    for i in 1..=t.len() {
        if !is_entry_start(t, i) || !t[i..].starts_with(key) {
            continue;
        }
        match t.get(i + kl) {
            Some(b':') | Some(b'=') => {
                let s = i + kl + 1;
                let e = t[s..].iter().position(|&b| b == b' ').map(|p| s + p).unwrap_or(t.len());
                return Some(t[s..e].to_vec());
            }
            _ => {}
        }
    }
    None
}

fn starts_of(p: &[u8], t: &[u8]) -> Vec<usize> {
    (1..=t.len()).filter(|&i| is_entry_start(t, i) && t[i..].starts_with(p)).collect()
}

/// `safedeps_npm_unique_prefix`: the one entry key that starts with P.
pub fn unique_prefix(p: &[u8], t: &[u8]) -> W {
    if p.is_empty() {
        return W::new();
    }
    let st = starts_of(p, t);
    if st.len() >= 2 {
        return W::new();
    }
    for &i in &st {
        let mut q = i + p.len();
        while q < t.len() && !matches!(t[q], b' ' | b':' | b'=') {
            q += 1;
        }
        if q < t.len() && (t[q] == b':' || t[q] == b'=') {
            return t[i..q].to_vec();
        }
    }
    W::new()
}

/// One family's parser traits (`SAFEDEPS_G_PARSERS`).
fn traits_of(family: &str) -> W {
    let t = tables::PARSERS.as_bytes();
    let pat = format!(" {}:", family);
    let pb = pat.as_bytes();
    if let Some(p) = t.windows(pb.len()).position(|w| w == pb) {
        let s = p + pb.len();
        let e = t[s..].iter().position(|&b| b == b' ').map(|q| s + q).unwrap_or(t.len());
        return t[s..e].to_vec();
    }
    W::new()
}

fn find_all(hay: &[u8], needle: &[u8]) -> Vec<usize> {
    if needle.is_empty() || needle.len() > hay.len() {
        return vec![];
    }
    (0..=hay.len() - needle.len()).filter(|&i| &hay[i..i + needle.len()] == needle).collect()
}

/// `safedeps_manager_option_class`.
pub fn option_class(family: &str, path: &str, opt: &[u8]) -> Option<u8> {
    let mut opt = opt.to_vec();
    if family == "go" && opt.len() >= 3 && opt.starts_with(b"--") {
        opt.remove(0);
    }
    let t = tables::VALUE_OPTIONS.as_bytes();
    let probe = |scope: &str| -> Option<u8> {
        let mut needle = format!(" {}/{}:", family, scope).into_bytes();
        needle.extend_from_slice(&opt);
        needle.push(b'=');
        for p in find_all(t, &needle) {
            if let Some(&c) = t.get(p + needle.len()) {
                if c.is_ascii_alphabetic() {
                    return Some(c);
                }
            }
        }
        None
    };
    if !path.is_empty() {
        if let Some(c) = probe(path) {
            return Some(c);
        }
    }
    probe("*")
}

/// `safedeps_manager_long_option`: the long option OPT abbreviates.
pub fn long_option(family: &str, path: &str, opt: &[u8]) -> W {
    let t = tables::LONG_OPTIONS.as_bytes();
    let mut entries: Vec<(&[u8], &[u8], &[u8])> = Vec::new();
    for e in t.split(|&b| b == b' ').filter(|e| !e.is_empty()) {
        let Some(sl) = e.iter().position(|&b| b == b'/') else { continue };
        let Some(co) = e[sl..].iter().position(|&b| b == b':').map(|p| sl + p) else { continue };
        entries.push((&e[..sl], &e[sl + 1..co], &e[co + 1..]));
    }
    let in_scope = |s: &[u8]| s == b"*" || (!path.is_empty() && s == path.as_bytes());
    let mut matches: Vec<&[u8]> = Vec::new();
    for (f, s, o) in &entries {
        if *f != family.as_bytes() || !in_scope(s) {
            continue;
        }
        if *o == opt {
            return opt.to_vec();
        }
        if o.starts_with(opt) {
            matches.push(o);
        }
    }
    if matches.len() == 1 {
        matches[0].to_vec()
    } else {
        opt.to_vec()
    }
}

/// `safedeps_manager_command`: the kind of a command path, `more` when a
/// longer path starts with it.
pub fn command(family: &str, path: &[u8]) -> Option<String> {
    let t = tables::COMMANDS.as_bytes();
    let mut needle = format!(" {}:", family).into_bytes();
    needle.extend_from_slice(path);
    let mut exact = needle.clone();
    exact.push(b'=');
    for p in find_all(t, &exact) {
        let s = p + exact.len();
        let e = t[s..].iter().position(|b| !b.is_ascii_lowercase()).map(|q| s + q).unwrap_or(t.len());
        if e > s {
            return Some(String::from_utf8_lossy(&t[s..e]).into_owned());
        }
    }
    let mut more = needle.clone();
    more.push(b',');
    for p in find_all(t, &more) {
        let mut q = p + more.len();
        while q < t.len() && t[q] != b' ' && t[q] != b'=' {
            q += 1;
        }
        if q < t.len() && t[q] == b'=' {
            return Some("more".to_string());
        }
    }
    None
}

pub struct Regexes {
    npm_verbs: Regex,
    npm_link: Regex,
    npm_exec: Regex,
    npm_init: Regex,
    executables: Regex,
    exec_entries: Vec<(String, Regex)>,
    js_num1: Regex,
    js_num2: Regex,
}

impl Regexes {
    pub fn new() -> Regexes {
        let full = |s: &str, ic: bool| Regex::new(&format!("^({})$", s), ic).expect("grammar regex");
        let exec_entries = grammar::EXECUTABLES
            .split('|')
            .map(|e| (e.to_string(), Regex::new(&format!("^({})$", e), true).expect("executable")))
            .collect();
        Regexes {
            npm_verbs: full(grammar::NPM_VERBS, false),
            npm_link: full(grammar::NPM_LINK_VERBS, false),
            npm_exec: full(grammar::NPM_EXEC_VERBS, false),
            npm_init: full(grammar::NPM_INIT_VERBS, false),
            executables: full(grammar::EXECUTABLES, true),
            exec_entries,
            js_num1: Regex::new("^[+-]?(Infinity|[0-9]+[.]?[0-9]*([eE][+-]?[0-9]+)?|[.][0-9]+([eE][+-]?[0-9]+)?)$", false).unwrap(),
            js_num2: Regex::new("^0([xX][0-9a-fA-F]+|[oO][0-7]+|[bB][01]+)$", false).unwrap(),
        }
    }
}

fn base_of(w: &[u8]) -> &[u8] {
    match w.iter().rposition(|&b| b == b'/') {
        Some(p) => &w[p + 1..],
        None => w,
    }
}

/// `safedeps_manager_name WORD NAME`: the last part of WORD is NAME, any case.
pub fn name_is(w: &[u8], name: &str) -> bool {
    base_of(w).eq_ignore_ascii_case(name.as_bytes())
}

/// `safedeps_manager_name WORD`: the family WORD names, if any.
pub fn family_of(rx: &Regexes, w: &[u8]) -> Option<String> {
    let base = base_of(w);
    if !rx.executables.is_match(base) {
        return None;
    }
    for (e, re) in &rx.exec_entries {
        if re.is_match(base) {
            let mut f = e.split('[').next().unwrap_or("").to_string();
            if f == "py" {
                f = "python".to_string();
            }
            return Some(f);
        }
    }
    None
}

fn trim_space(w: &[u8]) -> &[u8] {
    let sp = |b: &u8| matches!(*b, b' ' | b'\t' | b'\n' | 0x0b | 0x0c | b'\r');
    let s = w.iter().position(|b| !sp(b)).unwrap_or(w.len());
    let e = w.iter().rposition(|b| !sp(b)).map(|p| p + 1).unwrap_or(s);
    &w[s..e.max(s)]
}

pub fn js_is_number(rx: &Regexes, w: &[u8]) -> bool {
    let w = trim_space(w);
    if w.is_empty() {
        return true;
    }
    rx.js_num1.is_match(w) || rx.js_num2.is_match(w)
}

fn is_dashes(w: &[u8]) -> bool {
    w.len() >= 2 && w.iter().all(|&b| b == b'-')
}
/// `^--+[^-]`
fn dashes_then(w: &[u8]) -> bool {
    let k = w.iter().position(|&b| b != b'-').unwrap_or(w.len());
    k >= 2 && k < w.len()
}
fn opt_word(w: &[u8]) -> bool {
    w.len() >= 2 && w[0] == b'-'
}

/// The reader's state, the globals the shell functions share.
pub struct Reader<'r> {
    pub rx: &'r Regexes,
    npm_options: String,
    as_other: Option<String>,
    pub role: Vec<u8>,
    pub text: Vec<W>,
    pub family: String,
    pub kind: String,
    pub localbin: bool,
    ambiguous: i64,
    force_value: i64,
    other: bool,
    other_seen: bool,
    npx_words: Vec<W>,
    npx_at: Vec<i64>,
    npm_at: Vec<i64>,
    npm_words: Vec<W>,
    npm_values: Vec<(i64, W, W)>,
    pub npm_switches: Vec<(W, bool)>,
    npm_kind: String,
}

impl<'r> Reader<'r> {
    pub fn new(rx: &'r Regexes) -> Reader<'r> {
        Reader {
            rx,
            npm_options: tables::NPM_OPTIONS.to_string(),
            as_other: None,
            role: vec![],
            text: vec![],
            family: "none".into(),
            kind: "none".into(),
            localbin: false,
            ambiguous: -1,
            force_value: -1,
            other: false,
            other_seen: false,
            npx_words: vec![],
            npx_at: vec![],
            npm_at: vec![],
            npm_words: vec![],
            npm_values: vec![],
            npm_switches: vec![],
            npm_kind: String::new(),
        }
    }

    fn setrole(&mut self, k: usize, r: u8) {
        if k >= self.role.len() {
            self.role.resize(k + 1, b'-');
            self.text.resize(k + 1, W::new());
        }
        self.role[k] = r;
    }
    fn settext(&mut self, k: usize, t: W) {
        if k >= self.text.len() {
            self.role.resize(k + 1, b'-');
            self.text.resize(k + 1, W::new());
        }
        self.text[k] = t;
    }
    fn getrole(&self, k: usize) -> u8 {
        self.role.get(k).copied().unwrap_or(0)
    }

    // ---- npm's option reading -------------------------------------------------
    fn npm_short(&self, arg: &[u8]) -> (bool, W) {
        let mut s: &[u8] = arg;
        while s.first() == Some(&b'-') {
            s = &s[1..];
        }
        let opts = self.npm_options.as_bytes();
        let sh = tables::NPM_SHORTHANDS.as_bytes();
        if lookup(s, opts).is_some() {
            return (false, W::new());
        }
        if let Some(v) = lookup(s, sh) {
            return (true, v);
        }
        let mut c = W::new();
        let mut k = 0;
        while k < s.len() {
            match lookup(&s[k..k + 1], sh) {
                Some(v) => {
                    if !c.is_empty() {
                        c.push(b',');
                    }
                    c.extend_from_slice(&v);
                }
                None => break,
            }
            k += 1;
        }
        if k == s.len() {
            return (true, c);
        }
        if !unique_prefix(s, opts).is_empty() {
            return (false, W::new());
        }
        let picked = unique_prefix(s, sh);
        if picked.is_empty() {
            return (false, W::new());
        }
        let v = lookup(&picked, sh).unwrap_or_default();
        (true, v)
    }

    /// `safedeps_npm_read_args`. false where the bash function returns 1.
    pub fn npm_read_args(&mut self, words: &[W]) -> bool {
        let mut w: Vec<W> = words.to_vec();
        let mut at: Vec<i64> = (0..w.len() as i64).collect();
        self.npm_at.clear();
        self.npm_words.clear();
        self.npm_values.clear();
        self.npm_switches.clear();
        let mut i = 0usize;
        let mut steps = 0usize;
        while i < w.len() {
            steps += 1;
            if steps > 4 * w.len() + 64 {
                return false;
            }
            let mut arg = w[i].clone();
            if is_dashes(&arg) {
                for j in i + 1..w.len() {
                    self.npm_at.push(at[j]);
                    self.npm_words.push(w[j].clone());
                }
                return true;
            }
            if !opt_word(&arg) {
                self.npm_at.push(at[i]);
                self.npm_words.push(arg);
                i += 1;
                continue;
            }
            let mut hadeq = false;
            if let Some(p) = arg.iter().position(|&b| b == b'=') {
                hadeq = true;
                let v = arg[p + 1..].to_vec();
                arg = arg[..p].to_vec();
                let mut nw = w[..i].to_vec();
                nw.push(arg.clone());
                nw.push(v);
                nw.extend_from_slice(&w[i + 1..]);
                w = nw;
                let mut na = at[..i].to_vec();
                na.push(at[i]);
                na.extend_from_slice(&at[i..]);
                at = na;
            }
            let (set, short) = self.npm_short(&arg);
            if set {
                let exp: Vec<W> = if short.is_empty() { vec![] } else { short.split(|&b| b == b',').map(|x| x.to_vec()).collect() };
                // `while [[ -n "${v}" ]]; do exp+=("${v%%,*}") ...`: a value
                // that is only commas gives no words; split keeps empties, so
                // the shell's loop is followed literally.
                let exp = split_like_shell(&short).unwrap_or(exp);
                let n = exp.len();
                let mut nw = w[..i].to_vec();
                nw.extend(exp.iter().cloned());
                nw.extend_from_slice(&w[i + 1..]);
                w = nw;
                let v = at[i];
                let mut na = at[..i].to_vec();
                na.extend_from_slice(&at[i + 1..]);
                for _ in 0..n {
                    let mut nb = na[..i].to_vec();
                    nb.push(v);
                    nb.extend_from_slice(&na[i..]);
                    na = nb;
                }
                at = na;
                if !(n > 0 && arg == exp[0]) {
                    continue;
                }
            }
            let mut s: &[u8] = &arg;
            while s.first() == Some(&b'-') {
                s = &s[1..];
            }
            let mut no = false;
            let mut neg = false;
            while s.len() >= 3 && s[..2].eq_ignore_ascii_case(b"no") && s[2] == b'-' {
                no = true;
                s = &s[3..];
                neg = !neg;
            }
            let mut key = s.to_vec();
            let opts = self.npm_options.clone();
            let ob = opts.as_bytes();
            if lookup(&key, ob).is_none() {
                let p = unique_prefix(&key, ob);
                if !p.is_empty() {
                    key = p;
                }
            }
            let cls = lookup(&key, ob).unwrap_or_default();
            let (mut la, mut la_set) = (W::new(), false);
            if i + 1 < w.len() {
                la = w[i + 1].clone();
                la_set = true;
            }
            let mut consumed = 0usize;
            if no || cls.first() == Some(&b'b') || (cls.is_empty() && !hadeq) {
                if la_set && (la == b"true" || la == b"false") {
                    consumed = 1;
                    la_set = false;
                }
                if cls.len() >= 2 && cls[1] == b'+' && la_set && !la.is_empty() {
                    let mut flags = cls[2..].to_vec();
                    let mut lits = W::new();
                    if let Some(p) = flags.iter().position(|&b| b == b'=') {
                        lits.push(b',');
                        lits.extend_from_slice(&flags[p + 1..]);
                        lits.push(b',');
                        flags.truncate(p);
                    }
                    if lits == b",@host," {
                        return false;
                    }
                    let mut needle = vec![b','];
                    needle.extend_from_slice(&la);
                    needle.push(b',');
                    if !lits.is_empty() && !find_all(&lits, &needle).is_empty() {
                        consumed = 1;
                    } else if la == b"null" && flags.contains(&b'n') {
                        consumed = 1;
                    } else if flags.contains(&b'N') && !dashes_then(&la) && js_is_number(self.rx, &la) {
                        consumed = 1;
                    } else if flags.contains(&b'S') && !(la.len() >= 2 && la[0] == b'-' && la[1] != b'-') {
                        consumed = 1;
                    }
                }
            } else if la_set {
                consumed = 1;
                if cls == b"s" && la.len() >= 2 && la[0] == b'-' && {
                    let k = if la.len() >= 2 && la[1] == b'-' { 2 } else { 1 };
                    la.len() > k && la[k] != b'-'
                } {
                    consumed = 0;
                }
                if is_dashes(&la) {
                    consumed = 0;
                }
            }
            if consumed == 1 {
                self.npm_values.push((at[i + 1], key.clone(), w[i + 1].clone()));
            }
            if no || cls.first() == Some(&b'b') {
                let mut v: Option<bool> = Some(true);
                if consumed == 1 && w[i + 1] == b"false" {
                    v = Some(false);
                }
                if neg {
                    v = Some(!v.unwrap());
                }
                if consumed == 1 && w[i + 1] != b"true" && w[i + 1] != b"false" {
                    v = None;
                }
                if let Some(b) = v {
                    self.npm_switches.push((key.clone(), b));
                }
            }
            i += 1 + consumed;
        }
        true
    }

    fn npm_other_applies(&self, words: &[W]) -> bool {
        let t = tables::NPM_OTHER.as_bytes();
        for word in words {
            if !opt_word(word) {
                continue;
            }
            let mut s: &[u8] = match word.iter().position(|&b| b == b'=') {
                Some(p) => &word[..p],
                None => word,
            };
            while s.first() == Some(&b'-') {
                s = &s[1..];
            }
            while s.len() >= 3 && s[..2].eq_ignore_ascii_case(b"no") && s[2] == b'-' {
                s = &s[3..];
            }
            if s.is_empty() {
                continue;
            }
            for i in starts_of(s, t) {
                let mut q = i + s.len();
                while q < t.len() && t[q] != b' ' && t[q] != b':' {
                    q += 1;
                }
                if q < t.len() && t[q] == b':' {
                    return true;
                }
            }
        }
        false
    }

    fn options_as_other(&mut self) -> String {
        if let Some(s) = &self.as_other {
            return s.clone();
        }
        let other = tables::NPM_OTHER;
        let mut s = String::from(" ");
        for entry in tables::NPM_OPTIONS.split_whitespace() {
            let key = entry.split(':').next().unwrap_or("");
            if other.contains(&format!(" {}:", key)) {
                continue;
            }
            s.push_str(entry);
            s.push(' ');
        }
        for entry in other.split_whitespace() {
            let cls = match entry.find(':') {
                Some(p) => &entry[p + 1..],
                None => entry,
            };
            if cls != "-" {
                s.push_str(entry);
                s.push(' ');
            }
        }
        self.as_other = Some(s.clone());
        s
    }

    /// `safedeps_npx_first_pass`.
    fn npx_first_pass(&mut self, words: &[W]) -> bool {
        let mut w: Vec<W> = words.to_vec();
        let mut at: Vec<i64> = (0..w.len() as i64).collect();
        let mut i = 0usize;
        let mut steps = 0usize;
        while i < w.len() {
            steps += 1;
            if steps > 4 * w.len() + 64 {
                return false;
            }
            let arg = w[i].clone();
            if arg == b"--" {
                break;
            }
            if arg.first() != Some(&b'-') {
                let mut nw = w[..i].to_vec();
                nw.push(b"--".to_vec());
                nw.extend_from_slice(&w[i..]);
                w = nw;
                let mut na = at[..i].to_vec();
                na.push(at[i]);
                na.extend_from_slice(&at[i..]);
                at = na;
                break;
            }
            let mut key: &[u8] = &arg;
            while key.first() == Some(&b'-') {
                key = &key[1..];
            }
            let mut key = key.to_vec();
            let mut hasv = false;
            let mut v = W::new();
            if let Some(p) = key.iter().position(|&b| b == b'=') {
                hasv = true;
                v = key[p + 1..].to_vec();
                key.truncate(p);
            }
            match key.as_slice() {
                b"p" => {
                    let mut nw = b"--package".to_vec();
                    if hasv || !v.is_empty() {
                        nw.push(b'=');
                        nw.extend_from_slice(&v);
                    }
                    w[i] = nw;
                }
                b"shell" => {
                    let mut nw = b"--script-shell".to_vec();
                    if hasv || !v.is_empty() {
                        nw.push(b'=');
                        nw.extend_from_slice(&v);
                    }
                    w[i] = nw;
                }
                b"no-install" => {
                    w[i] = b"--yes=false".to_vec();
                }
                _ => {
                    if let Some(val) = lookup(&key, tables::NPM_SHORTHANDS.as_bytes()) {
                        let mut exp = split_like_shell(&val).unwrap_or_default();
                        if hasv {
                            let p = arg.iter().position(|&b| b == b'=').unwrap();
                            exp.push(arg[p + 1..].to_vec());
                        }
                        let n = exp.len();
                        let mut nw = w[..i].to_vec();
                        nw.extend(exp.iter().cloned());
                        nw.extend_from_slice(&w[i + 1..]);
                        w = nw;
                        let vv = at[i];
                        let mut na = at[..i].to_vec();
                        na.extend_from_slice(&at[i + 1..]);
                        for _ in 0..n {
                            let mut nb = na[..i].to_vec();
                            nb.push(vv);
                            nb.extend_from_slice(&na[i..]);
                            na = nb;
                        }
                        at = na;
                        continue;
                    }
                }
            }
            if !hasv {
                let switches = [&b"no-install"[..], b"quiet", b"q", b"version", b"v", b"help", b"h", b"always-spawn", b"ignore-existing", b"shell-auto-fallback"];
                if !switches.contains(&key.as_slice()) {
                    let is_bool = lookup(&key, self.npm_options.as_bytes()).map(|c| c.first() == Some(&b'b')).unwrap_or(false);
                    if !is_bool {
                        let takes = [&b"package"[..], b"p", b"call", b"c", b"shell", b"npm", b"node-arg", b"n", b"cache", b"userconfig"];
                        if takes.contains(&key.as_slice()) {
                            i += 1;
                        } else if i + 1 < w.len() && w[i + 1].first() != Some(&b'-') {
                            i += 1;
                        }
                    }
                }
            }
            i += 1;
        }
        self.npx_words = w;
        self.npx_at = at;
        true
    }

    // ---- the manager reading ---------------------------------------------------
    /// `safedeps_manager_read`. Always "succeeds", as the shell function does.
    pub fn read(&mut self, w: &[W]) {
        self.ambiguous = -1;
        self.force_value = -1;
        self.other = false;
        self.other_seen = false;
        self.read_once(w);
        if self.other_seen {
            self.other = true;
            self.read_union(w);
            self.other = false;
        }
        if self.ambiguous < 0 {
            return;
        }
        let amb = self.ambiguous;
        self.force_value = amb;
        self.other_seen = false;
        self.read_union(w);
        if self.other_seen {
            self.other = true;
            self.read_union(w);
            self.other = false;
        }
        self.force_value = -1;
    }

    fn read_union(&mut self, w: &[W]) {
        let role = self.role.clone();
        let text = self.text.clone();
        let kind = self.kind.clone();
        let localbin = self.localbin;
        self.read_once(w);
        for k in 0..role.len() {
            let a = role[k];
            let b = self.getrole(k);
            if b"orCpwDVd".contains(&a) && b != 0 && b"-gcva".contains(&b) {
                self.setrole(k, a);
                self.settext(k, text[k].clone());
            }
        }
        if self.kind == "none" {
            self.kind = kind;
        }
        if localbin {
            self.localbin = true;
        }
    }

    fn read_once(&mut self, words: &[W]) {
        let mut w: Vec<W> = words.to_vec();
        let n = w.len();
        let mut i = 0usize;
        self.family = "none".into();
        self.kind = "none".into();
        self.localbin = false;
        self.role = vec![b'-'; n];
        self.text = vec![W::new(); n];
        let mut t: W = W::new();
        while i < n {
            t = w[i].clone();
            while matches!(t.first(), Some(b'(') | Some(b'{') | Some(b'!') | Some(0x02)) {
                t.remove(0);
            }
            if matches!(t.as_slice(), b"" | b"then" | b"do" | b"else" | b"elif" | b"if" | b"while" | b"until" | b"time" | b"coproc" | b"command" | b"exec") {
                i += 1;
                continue;
            }
            if name_is(&t, "command") || name_is(&t, "time") {
                i += 1;
                continue;
            }
            if is_assignment_start(&t) {
                i += 1;
                continue;
            }
            if name_is(&t, "env") {
                i += 1;
                while i < n && opt_word(&w[i]) {
                    if !w[i].contains(&b'=') {
                        if let Some(c) = option_class("env", "", &w[i]) {
                            self.setrole(i, b'g');
                            self.setrole(i + 1, c);
                            i += 2;
                            continue;
                        }
                    }
                    i += 1;
                }
                continue;
            }
            break;
        }
        if i >= n {
            return;
        }
        w[i] = t.clone();
        let Some(mut family) = family_of(self.rx, &t) else { return };
        self.setrole(i, b'm');
        i += 1;

        if family == "python" {
            'outer: while i < n {
                let t = w[i].clone();
                self.setrole(i, b'g');
                if t.len() >= 3 && t.starts_with(b"--") {
                    if !t.contains(&b'=') && option_class("python", "", &t).is_some() {
                        self.setrole(i + 1, b'v');
                        i += 1;
                    }
                    i += 1;
                    continue;
                }
                if !opt_word(&t) || t == b"--" {
                    self.setrole(i, b'-');
                    return;
                }
                let mut k = 1usize;
                while k < t.len() {
                    match t[k] {
                        b'c' => return,
                        b'm' => {
                            let mut val = t[k + 1..].to_vec();
                            if val.is_empty() {
                                i += 1;
                                val = w.get(i).cloned().unwrap_or_default();
                            }
                            if !name_is(&val, "pip") {
                                return;
                            }
                            self.setrole(i, b'm');
                            i += 1;
                            family = "pip".into();
                            break 'outer;
                        }
                        _ => {}
                    }
                    let one = vec![b'-', t[k]];
                    if option_class("python", "", &one).is_some() {
                        if k + 1 == t.len() {
                            self.setrole(i + 1, b'v');
                            i += 1;
                        }
                        break;
                    }
                    k += 1;
                }
                i += 1;
            }
            if family != "pip" {
                return;
            }
        }
        self.family = family.clone();
        match family.as_str() {
            "npm" | "npx" => {
                self.read_npm(i, &w);
                return;
            }
            "mvn" => {
                self.read_mvn(i, &w);
                return;
            }
            _ => {}
        }
        if family == "cargo" && w.get(i).is_some_and(|x| x.first() == Some(&b'+')) {
            self.setrole(i, b'g');
            i += 1;
        }
        let traits = traits_of(&family);
        let has = |c: u8| traits.contains(&c);
        if family == "bunx" {
            self.localbin = true;
        }
        let mut kind = String::new();
        if let Some(k) = command(&family, b"") {
            if k != "more" {
                kind = k;
            }
        }
        let mut path: W = W::new();
        let mut endopts = false;
        let mut named = false;
        let mut unknown = false;
        while i < n {
            let mut t = w[i].clone();
            if !endopts && is_dashes(&t) {
                self.setrole(i, b'g');
                endopts = true;
                i += 1;
                continue;
            }
            if !endopts && opt_word(&t) {
                self.setrole(i, b'g');
                let mut opt = t.clone();
                let mut val = W::new();
                unknown = false;
                let pstr = String::from_utf8_lossy(&path).into_owned();
                if (t.starts_with(b"--") && t.contains(&b'=')) || (t.len() >= 2 && t[1] != b'-' && t[2..].contains(&b'=')) {
                    let p = t.iter().position(|&b| b == b'=').unwrap();
                    opt = t[..p].to_vec();
                    val = t[p + 1..].to_vec();
                } else if has(b'c') && t[1..].contains(&b':') {
                    let p = t.iter().position(|&b| b == b':').unwrap();
                    opt = t[..p].to_vec();
                    val = t[p + 1..].to_vec();
                }
                if has(b'x') && opt.len() >= 3 && opt.starts_with(b"--") {
                    let lv = long_option(&family, &pstr, &opt);
                    if lv != opt {
                        if opt == t {
                            t = lv.clone();
                        }
                        opt = lv;
                    }
                }
                if opt != t {
                    if let Some(c) = option_class(&family, &pstr, &opt) {
                        self.setrole(i, if c == b'b' { b'v' } else { c });
                        self.settext(i, val);
                    }
                } else if let Some(c0) = option_class(&family, &pstr, &t) {
                    let mut cls: Option<u8> = Some(c0);
                    if c0 == b'b' {
                        self.other_seen = true;
                        cls = Some(b'v');
                        if self.other {
                            cls = None;
                        }
                    }
                    if let Some(c) = cls {
                        if i + 1 < n && !(has(b'e') && opt_word(&w[i + 1])) {
                            self.setrole(i + 1, c);
                            if c == b'p' {
                                named = true;
                            }
                            i += 1;
                        }
                    }
                } else if has(b'a') && t.len() >= 3 && t[0] == b'-' && t[1].is_ascii_alphanumeric() && {
                    option_class(&family, &pstr, &t[..2]).is_some()
                } {
                    let c = option_class(&family, &pstr, &t[..2]).unwrap();
                    self.setrole(i, if c == b'b' { b'v' } else { c });
                    self.settext(i, t[2..].to_vec());
                } else {
                    unknown = true;
                }
                if self.getrole(i) == b'p' {
                    named = true;
                }
                i += 1;
                continue;
            }
            if kind.is_empty() {
                if i as i64 == self.force_value {
                    self.setrole(i, b'v');
                    unknown = false;
                    i += 1;
                    continue;
                }
                if unknown && self.ambiguous < 0 && self.force_value < 0 {
                    self.ambiguous = i as i64;
                }
                self.setrole(i, b'c');
                let mut cand = path.clone();
                if !cand.is_empty() {
                    cand.push(b',');
                }
                cand.extend_from_slice(&t);
                let mut star = path.clone();
                if !star.is_empty() {
                    star.push(b',');
                }
                star.push(b'*');
                let found = if let Some(k) = command(&family, &cand) {
                    path = cand;
                    k
                } else if let Some(k) = command(&family, &star) {
                    path = star;
                    k
                } else if unknown {
                    self.setrole(i, b'v');
                    unknown = false;
                    i += 1;
                    continue;
                } else {
                    self.setrole(i, b'-');
                    return;
                };
                if found != "more" {
                    kind = found;
                }
                if family == "bun" && path == b"x" {
                    self.localbin = true;
                }
                unknown = false;
                i += 1;
                continue;
            }
            if has(b's') {
                endopts = true;
            }
            match kind.as_str() {
                "install" => self.setrole(i, b'o'),
                "runner" | "create" => {
                    if !named {
                        if kind == "create" {
                            self.setrole(i, b'C');
                        } else if family == "go" && !t.contains(&b'@') {
                            self.setrole(i, b'a');
                        } else {
                            self.setrole(i, b'r');
                        }
                    } else {
                        self.setrole(i, b'a');
                    }
                    for j in i + 1..n {
                        self.setrole(j, b'a');
                    }
                    break;
                }
                _ => {}
            }
            i += 1;
        }
        if !kind.is_empty() {
            self.kind = kind;
        }
    }

    fn read_npm(&mut self, start: usize, w: &[W]) -> bool {
        if !self.read_npm_once(start, w) {
            return false;
        }
        if !self.npm_other_applies(&w[start.min(w.len())..]) {
            return true;
        }
        let role = self.role.clone();
        let text = self.text.clone();
        let kind = self.kind.clone();
        let localbin = self.localbin;
        self.kind = "none".into();
        self.localbin = false;
        let saved = self.npm_options.clone();
        self.npm_options = self.options_as_other();
        let ok = self.read_npm_once(start, w);
        self.npm_options = saved;
        if !ok {
            return false;
        }
        for k in 0..role.len() {
            let r = role[k];
            if b"orCp".contains(&r) {
                self.setrole(k, r);
                self.settext(k, text[k].clone());
            }
        }
        if kind != "none" {
            self.kind = kind;
        }
        if localbin {
            self.localbin = true;
        }
        true
    }

    fn npm_at_of(&self, start: usize, a: i64) -> i64 {
        let mut a = a;
        if self.family == "npx" {
            if a <= 0 {
                return -1;
            }
            a = self.npx_at.get((a - 1) as usize).copied().unwrap_or(0);
        }
        start as i64 + a
    }

    fn npm_kind_of(&mut self, cmd: &[u8]) {
        self.npm_kind = if self.rx.npm_verbs.is_match(cmd) {
            "install"
        } else if self.rx.npm_link.is_match(cmd) {
            "link"
        } else if self.rx.npm_exec.is_match(cmd) {
            "exec"
        } else if self.rx.npm_init.is_match(cmd) {
            "init"
        } else {
            "other"
        }
        .into();
    }

    fn read_npm_once(&mut self, start: usize, w: &[W]) -> bool {
        let args: Vec<W> = w[start.min(w.len())..].to_vec();
        let mut named = false;
        let mut call = false;
        if self.family == "npx" {
            if !self.npx_first_pass(&args) {
                return false;
            }
            let mut a = vec![b"exec".to_vec()];
            a.extend(self.npx_words.iter().cloned());
            if !self.npm_read_args(&a) {
                return false;
            }
        } else if !self.npm_read_args(&args) {
            return false;
        }
        for k in start..w.len() {
            self.setrole(k, b'g');
            self.settext(k, W::new());
        }
        if self.npm_words.is_empty() {
            return true;
        }
        let w0 = self.npm_words[0].clone();
        if w0 == b"exec" && self.family == "npx" {
            self.npm_kind = "exec".into();
        } else {
            self.npm_kind_of(&w0);
        }
        if self.family != "npx" {
            let at = self.npm_at_of(start, self.npm_at[0]);
            if at >= 0 {
                self.setrole(at as usize, b'c');
            }
        }
        let values = self.npm_values.clone();
        for (a, key, text) in values {
            let at = self.npm_at_of(start, a);
            if at < 0 {
                continue;
            }
            let at = at as usize;
            match key.as_slice() {
                b"package" => {
                    if self.npm_kind == "exec" {
                        self.setrole(at, b'p');
                        named = true;
                        if w.get(at).map(|x| x.as_slice()) != Some(text.as_slice()) {
                            self.settext(at, text.clone());
                        }
                    }
                }
                b"call" => {
                    if !text.is_empty() {
                        call = true;
                    }
                }
                _ => {}
            }
        }
        match self.npm_kind.as_str() {
            "install" | "link" => self.kind = self.npm_kind.clone(),
            "exec" => {
                self.kind = "runner".into();
                self.localbin = true;
            }
            "init" => {
                self.kind = "create".into();
                self.localbin = true;
            }
            _ => return true,
        }
        let words = self.npm_words.clone();
        let ats = self.npm_at.clone();
        for k in 1..words.len() {
            let at = self.npm_at_of(start, ats[k]);
            if at < 0 {
                continue;
            }
            let at = at as usize;
            match self.kind.as_str() {
                "install" | "link" => self.setrole(at, b'o'),
                _ => {
                    if k == 1 && !named && !call {
                        self.setrole(at, if self.kind == "create" { b'C' } else { b'r' });
                    } else {
                        if self.getrole(at) != b'g' {
                            continue;
                        }
                        self.setrole(at, b'a');
                    }
                }
            }
            if w.get(at).map(|x| x.as_slice()) != Some(words[k].as_slice()) {
                self.settext(at, words[k].clone());
            }
        }
        true
    }

    fn read_mvn(&mut self, start: usize, w: &[W]) {
        let mut install = false;
        let mut k = start;
        while k < w.len() {
            let t = &w[k];
            if t.len() >= 3 && t.starts_with(b"-D") {
                self.setrole(k, b'g');
                if t.starts_with(b"-Dartifact=") {
                    self.setrole(k, b'D');
                    self.settext(k, t[2..].to_vec());
                }
            } else if opt_word(t) {
                self.setrole(k, b'g');
                if !t.contains(&b'=') && option_class("mvn", "", t).is_some() {
                    let def = t == b"-D" || t == b"--define";
                    k += 1;
                    if def && w.get(k).is_some_and(|x| x.starts_with(b"artifact=")) {
                        self.setrole(k, b'D');
                    } else {
                        self.setrole(k, b'v');
                    }
                }
            } else {
                self.setrole(k, b'c');
                if t == b"dependency:get" || (t.ends_with(b":get") && find_all(t, b"maven-dependency-plugin").iter().any(|&p| p + 23 <= t.len() - 4)) {
                    install = true;
                }
            }
            k += 1;
        }
        if install {
            self.kind = "install".into();
        }
    }
}

/// `^[A-Za-z_][A-Za-z0-9_]*=`
fn is_assignment_start(t: &[u8]) -> bool {
    if t.is_empty() || !(t[0].is_ascii_alphabetic() || t[0] == b'_') {
        return false;
    }
    let mut p = 1;
    while p < t.len() && (t[p].is_ascii_alphanumeric() || t[p] == b'_') {
        p += 1;
    }
    p < t.len() && t[p] == b'='
}

/// The shell loop `while [[ -n "${v}" ]]; do exp+=("${v%%,*}"); [[ "${v}" ==
/// *,* ]] && v="${v#*,}" || v=""; done`: a trailing comma ends the list, an
/// empty value gives none.
fn split_like_shell(v: &[u8]) -> Option<Vec<W>> {
    let mut out = Vec::new();
    let mut v = v.to_vec();
    while !v.is_empty() {
        match v.iter().position(|&b| b == b',') {
            Some(p) => {
                out.push(v[..p].to_vec());
                v = v[p + 1..].to_vec();
            }
            None => {
                out.push(v.clone());
                v.clear();
            }
        }
    }
    Some(out)
}
