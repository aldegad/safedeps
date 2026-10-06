//! The record: whether the command holds an npm install the rewrite did not
//! read. Ported as it is from the bash guard (`inert_bytes_left_unread`,
//! `inert_dynamic_command_word`, `inert_dynamic_in`). It reads the command's
//! bytes and the class the lexer gives each one, never the structure the
//! rewrite read, so it stands where the reader is wrong.
//!
//! The awk programs are followed where they decide a result:
//! - arrays are 1-based and a read past the end is the empty string (0 here,
//!   a byte no command holds once the guard has dropped its NULs);
//! - the quote removal reads its own input past the length it was given,
//!   where an earlier, longer level left bytes behind (`S[i + 1]` at the last
//!   byte), as the awk array keeps them;
//! - `index(s, "")` is 1 for a non-empty `s`, as the macOS awk (BWK) answers.

use crate::core::Run;
use crate::ere::Regex;
use crate::grammar;

type W = Vec<u8>;

/// `SAFEDEPS_SHELL_INERT_BYTES`: bytes no shell expansion acts on.
pub const INERT_BYTES: &[u8] = b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/@:+,=%-";

pub struct Rx {
    /// The byte rule's verb: the recognizers' option grammar, no left
    /// boundary, any case.
    left: Regex,
    /// `(^|[[:space:];&|()])=`
    eqstart: Regex,
}

impl Rx {
    pub fn new() -> Rx {
        Rx {
            left: Regex::new(
                &format!("npm{}[[:space:]]+({}|{})([^[:alnum:]_-]|$)", grammar::O, grammar::NPM_VERBS, grammar::NPM_LINK_VERBS),
                true,
            )
            .expect("byte rule pattern"),
            eqstart: Regex::new("(^|[[:space:];&|()])=", false).expect("eqstart pattern"),
        }
    }
}

/// awk `index(hay, c)` for one character; 0 stands for the empty string.
fn awk_index(hay: &[u8], c: u8) -> usize {
    if c == 0 {
        return if hay.is_empty() { 0 } else { 1 };
    }
    hay.iter().position(|&b| b == c).map(|p| p + 1).unwrap_or(0)
}

/// One level of quote removal as the shell does it (the awk `unq`): `s` is
/// the array, `ns` the length it is read to.
fn unq(s: &[u8], ns: usize) -> W {
    let g = |i: usize| -> u8 {
        if i >= 1 && i <= s.len() {
            s[i - 1]
        } else {
            0
        }
    };
    let oct = |c: u8| awk_index(b"01234567", c);
    let hex = |c: u8| awk_index(b"0123456789abcdef", c.to_ascii_lowercase());
    let mut d = W::new();
    let mut q = 0u8;
    let mut i = 1usize;
    while i <= ns {
        let c = g(i);
        if q == 1 {
            if c == b'\'' {
                q = 0;
            } else {
                d.push(c);
            }
            i += 1;
            continue;
        }
        if q == 2 {
            if c == b'"' {
                q = 0;
            } else if c == b'\\' && i < ns && matches!(g(i + 1), b'$' | b'`' | b'"' | b'\\' | b'\n') {
                i += 1;
                if g(i) != b'\n' {
                    d.push(g(i));
                }
            } else {
                d.push(c);
            }
            i += 1;
            continue;
        }
        if c == b'\\' {
            if i < ns {
                i += 1;
                if g(i) != b'\n' {
                    d.push(g(i));
                }
            }
            i += 1;
            continue;
        }
        if c == b'\'' {
            q = 1;
            i += 1;
            continue;
        }
        if c == b'"' {
            q = 2;
            i += 1;
            continue;
        }
        if c == b'$' && g(i + 1) == b'"' {
            q = 2;
            i += 2;
            continue;
        }
        if c == b'$' && g(i + 1) == b'\'' {
            i += 2;
            while i <= ns && g(i) != b'\'' {
                if g(i) != b'\\' || i == ns {
                    d.push(g(i));
                    i += 1;
                    continue;
                }
                i += 1;
                let e = g(i);
                if oct(e) > 0 {
                    let mut v = 0usize;
                    let mut n = 0;
                    while n < 3 && oct(g(i)) > 0 {
                        v = v * 8 + oct(g(i)) - 1;
                        i += 1;
                        n += 1;
                    }
                    i -= 1;
                    if v > 0 && v < 128 {
                        d.push(v as u8);
                    }
                    i += 1;
                    continue;
                }
                if e == b'x' && hex(g(i + 1)) > 0 {
                    let mut v = 0usize;
                    let mut n = 0;
                    while n < 2 && hex(g(i + 1)) > 0 {
                        i += 1;
                        v = v * 16 + hex(g(i)) - 1;
                        n += 1;
                    }
                    if v > 0 && v < 128 {
                        d.push(v as u8);
                    }
                    i += 1;
                    continue;
                }
                if (e == b'u' || e == b'U') && hex(g(i + 1)) > 0 {
                    let lim = if e == b'u' { 4 } else { 8 };
                    let mut v = 0u64;
                    let mut n = 0;
                    while n < lim && hex(g(i + 1)) > 0 {
                        i += 1;
                        v = v * 16 + (hex(g(i)) - 1) as u64;
                        n += 1;
                    }
                    if v > 0 && v < 128 {
                        d.push(v as u8);
                    }
                    i += 1;
                    continue;
                }
                if e == b'c' {
                    i += 2;
                    continue;
                }
                if e == b'n' {
                    d.push(b'\n');
                } else if e == b't' {
                    d.push(b'\t');
                } else if awk_index(b"abefrvE", e) > 0 {
                    d.push(b' ');
                } else {
                    d.push(e);
                }
                i += 1;
            }
            // The outer loop's step past the closing quote.
            i += 1;
            continue;
        }
        d.push(c);
        i += 1;
    }
    d
}

/// What the byte rule found.
pub struct Left {
    /// The command holds an npm install verb, or an unread `npm` in a word the
    /// shell computes, that the rewrite did not read.
    pub unread: bool,
    /// The texts the quote removal made, one per level, for the computed-word
    /// clause (`INERT_LEVELS`, cut at \036 as the shell's `read -d` cuts it).
    pub levels: Vec<W>,
}

/// `inert_bytes_left_unread <command> <at>`: `read_at` holds, for each verb
/// the rewrite read, the offset (from 0) of its `npm`. Err on a failed
/// reading.
pub fn bytes_left_unread(run: &mut Run, rx: &Rx, command: &[u8], read_at: &[usize]) -> Result<Left, ()> {
    let classes = run.lex(command, "classes").ok_or(())?;
    // awk reads the command as lines: a newline that ends it is not read.
    let mut x: W = command.to_vec();
    if x.last() == Some(&b'\n') {
        x.pop();
    }
    let n = x.len();
    let kc = |i: usize| -> u8 {
        if i >= 1 && i <= classes.len() {
            classes[i - 1]
        } else {
            0
        }
    };
    let mut hide = vec![false; n + 4];
    for &a in read_at {
        for s in a + 1..a + 4 {
            if s < hide.len() {
                hide[s] = true;
            }
        }
    }
    for i in 1..=n {
        if hide[i] {
            x[i - 1] = b'_';
        } else if kc(i) == b'm' {
            x[i - 1] = b' ';
        }
    }
    let g = |x: &W, i: usize| -> u8 {
        if i >= 1 && i <= x.len() {
            x[i - 1]
        } else {
            0
        }
    };
    // An `npm` the rewrite did not read inside a word the shell computes.
    let mut computed = false;
    let mut st: Vec<u8> = Vec::new();
    let mut i = 1usize;
    while i <= n && !computed {
        let three = [g(&x, i), g(&x, i + 1), g(&x, i + 2)];
        if (kc(i) == b'Q' || kc(i) == b'B' || !st.is_empty()) && three.iter().all(|&b| b != 0) && three.eq_ignore_ascii_case(b"npm") {
            computed = true;
        }
        if kc(i) != b'c' {
            i += 1;
            continue;
        }
        let c = g(&x, i);
        let c1 = g(&x, i + 1);
        if ((c == b'$' || c == b'<' || c == b'>') && c1 == b'(') || (c == b'$' && c1 == b'{') {
            st.push(if c1 == b'(' { b')' } else { b'}' });
            i += 1;
        } else if c == b'`' {
            if st.last() == Some(&b'`') {
                st.pop();
            } else {
                st.push(b'`');
            }
        } else if !st.is_empty() && c == b'(' {
            st.push(b')');
        } else if !st.is_empty() && st.last() == Some(&c) {
            st.pop();
        }
        i += 1;
    }
    // Every level of quoting out at once.
    let mut text0 = W::new();
    let mut i = 1usize;
    while i <= n {
        let c = g(&x, i);
        if c == b'\\' && g(&x, i + 1) == b'\n' {
            i += 2;
            continue;
        }
        if c == b'$' && (g(&x, i + 1) == b'\'' || g(&x, i + 1) == b'"') {
            i += 1;
            continue;
        }
        if c != b'"' && c != b'\'' && c != b'\\' {
            text0.push(c);
        }
        i += 1;
    }
    // Then one level at a time, up to three.
    let mut a: W = x.clone();
    let mut m = n;
    let mut levels_joined = W::new();
    for lv in 1..=3 {
        let d = unq(&a, m);
        m = d.len();
        a[..m].copy_from_slice(&d);
        if lv > 1 {
            levels_joined.push(0x1e);
        }
        levels_joined.extend_from_slice(&d);
        let more = d.iter().any(|&b| b == b'\'' || b == b'"' || b == b'\\');
        if !more {
            break;
        }
    }
    let levels: Vec<W> = levels_joined.split(|&b| b == 0x1e).map(|s| s.to_vec()).collect();
    if computed {
        return Ok(Left { unread: true, levels });
    }
    let mut all = text0;
    all.push(0x1e);
    all.extend_from_slice(&levels_joined);
    if !all.windows(3).any(|w| w.eq_ignore_ascii_case(b"npm")) {
        return Ok(Left { unread: false, levels });
    }
    let lines: W = all.iter().map(|&b| if b == 0x1e { b'\n' } else { b }).collect();
    Ok(Left { unread: rx.left.grep_any(&lines), levels })
}

/// `inert_dynamic_command_word <command>`, with the levels the byte rule made.
pub fn dynamic_command_word(run: &mut Run, rx: &Rx, command: &[u8], levels: &[W]) -> Result<bool, ()> {
    let mut texts: Vec<W> = vec![command.to_vec()];
    texts.extend(run.raw_texts(command));
    for t in &texts {
        if t.iter().all(|&b| matches!(b, b' ' | b'\t' | b'\n' | 0x0b | 0x0c | b'\r')) {
            continue;
        }
        if dynamic_in(run, rx, t, false)? {
            return Ok(true);
        }
    }
    for t in levels {
        let t: W = t.iter().map(|&b| if b == b'<' { b'\n' } else { b }).collect();
        if dynamic_in(run, rx, &t, true)? {
            return Ok(true);
        }
    }
    Ok(false)
}

/// `inert_dynamic_in <text> <levels>`.
fn dynamic_in(run: &mut Run, rx: &Rx, text: &[u8], levels: bool) -> Result<bool, ()> {
    let plain = |b: u8| b" \t\n;&|<>()".contains(&b) || INERT_BYTES.contains(&b);
    if text.iter().all(|&b| plain(b)) && !rx.eqstart.is_match(text) {
        return Ok(false);
    }
    // A level text is one the byte rule built, not the command: where the
    // shells lex it differently is no place in the command.
    let diverge = run.diverge;
    let classes = run.lex(text, "classes");
    let noprefix = run.lex(text, "noprefix");
    if levels {
        run.diverge = diverge;
    }
    let (Some(kc), Some(xc)) = (classes, noprefix) else { return Err(()) };
    let n = xc.len();
    if kc.len() != n {
        run.failed = true;
        return Err(());
    }
    let k = |i: usize| -> u8 {
        if i >= 1 && i <= n {
            kc[i - 1]
        } else {
            0
        }
    };
    let x = |i: usize| -> u8 {
        if i >= 1 && i <= n {
            xc[i - 1]
        } else {
            0
        }
    };
    const KW: [&[u8]; 12] = [b"!", b"{", b"}", b"if", b"then", b"else", b"elif", b"while", b"until", b"do", b"time", b"coproc"];
    let is_kw = |w: &[u8]| KW.contains(&w);
    // Case patterns.
    let mut pat = vec![false; n + 2];
    let mut p = false;
    let mut kk = n;
    while kk >= 1 {
        if k(kk) == b'p' {
            p = true;
        } else if p && k(kk) == b'c' && awk_index(b";&(\n", x(kk)) > 0 {
            p = false;
        } else if p
            && k(kk) == b'c'
            && awk_index(b" \t", x(kk)) > 0
            && kk > 2
            && x(kk - 1) == b'n'
            && x(kk - 2) == b'i'
            && (kk == 3 || awk_index(b" \t", x(kk - 3)) > 0)
        {
            p = false;
        }
        pat[kk] = p;
        kk -= 1;
    }
    if levels {
        let mut st: Vec<u8> = Vec::new();
        let mut i = 1usize;
        while i <= n {
            let three = [x(i), x(i + 1), x(i + 2)];
            if (k(i) == b'Q' || k(i) == b'B' || !st.is_empty()) && three.iter().all(|&b| b != 0) && three.eq_ignore_ascii_case(b"npm") {
                return Ok(true);
            }
            if k(i) != b'c' {
                i += 1;
                continue;
            }
            let c = x(i);
            let c1 = x(i + 1);
            if ((c == b'$' || c == b'<' || c == b'>') && c1 == b'(') || (c == b'$' && c1 == b'{') {
                st.push(if c1 == b'(' { b')' } else { b'}' });
                i += 1;
            } else if c == b'`' {
                if st.last() == Some(&b'`') {
                    st.pop();
                } else {
                    st.push(b'`');
                }
            } else if !st.is_empty() && c == b'(' {
                st.push(b')');
            } else if !st.is_empty() && st.last() == Some(&c) {
                st.pop();
            }
            i += 1;
        }
    }
    let skip_cl = |cl: u8| matches!(cl, b'm' | b'h' | b'b' | b'F' | b'l');
    let stop_cl = |cl: u8| matches!(cl, b'm' | b'h' | b'b' | b'F');
    let mut start = true;
    let mut innpm = false;
    let mut opt = false;
    let mut kk = 1usize;
    while kk <= n {
        let c = x(kk);
        let top = k(kk) == b'c' || k(kk) == b'p';
        if skip_cl(k(kk)) {
            kk += 1;
            continue;
        }
        if top && matches!(c, b' ' | b'\t' | b'<' | b'>') {
            kk += 1;
            continue;
        }
        if top && awk_index(b";&|()\n", c) > 0 {
            start = true;
            innpm = false;
            kk += 1;
            continue;
        }
        let s = kk;
        let mut w = W::new();
        let mut t = W::new();
        let mut wl = 0usize;
        let mut rl = 0usize;
        let mut dynw = false;
        let mut depth: i64 = 0;
        while kk <= n {
            let c = x(kk);
            let cl = k(kk);
            let top = cl == b'c' || cl == b'p';
            if depth == 0 && ((top && awk_index(b" \t;&|()<>\n", c) > 0 && !(c == b'(' && rl > 0)) || stop_cl(cl)) {
                break;
            }
            rl += 1;
            if top && c == b'(' {
                depth += 1;
            } else if top && c == b')' {
                depth -= 1;
            }
            if c == b'$' || c == b'`' {
                dynw = true;
            } else if cl == b'c' && (!INERT_BYTES.contains(&c) || (kk == s && c == b'=')) {
                dynw = true;
            }
            if cl == b'x' || cl == b'l' || (cl == b'q' && (c == b'\'' || c == b'"')) {
                kk += 1;
                continue;
            }
            if wl < 8 {
                w.push(c);
            }
            if wl >= 4 {
                t.remove(0);
            }
            t.push(c);
            wl += 1;
            kk += 1;
        }
        // kk is the byte after the word: the outer loop goes on from it.
        if pat[s] {
            continue;
        }
        if start {
            if wl <= 8 && (is_kw(w.as_slice()) || w.as_slice() == b"[[" || w.as_slice() == b"[") {
                start = is_kw(w.as_slice());
                continue;
            }
            if dynw {
                return Ok(true);
            }
            start = false;
            opt = false;
            let tl: W = t.iter().map(|b| b.to_ascii_lowercase()).collect();
            innpm = (wl == 3 && tl.as_slice() == b"npm") || (wl > 3 && tl.as_slice() == b"/npm");
            continue;
        }
        if !innpm {
            continue;
        }
        if dynw {
            return Ok(true);
        }
        if w.first() == Some(&b'-') {
            opt = true;
        } else if !opt {
            innpm = false;
        }
    }
    Ok(false)
}
