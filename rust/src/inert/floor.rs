//! The release's floor, kept byte for byte: where the reference rewrite puts
//! the flag right after a verb, where v2.17.2 put it in text the bash rewrite
//! did not read, and the release's own decisions (`inert_release_skips`,
//! `inert_release_appends`).
//!
//! This is compatibility, not reading. The positions come from the reference
//! rewrite's own searches (`inert_verb_ends`: `grep -ob` of the verb pattern
//! over the lexer's live and flat views; `inert_payload_spans`: its search
//! for a script's head over the scan view) and are used for one thing: a
//! flag goes there. Nothing here decides whether a statement is an install,
//! where it ends, whether its `npm` was read, or what npm makes of its
//! options; the reader (`read.rs`) and the record (`record.rs`) do, from the
//! lexer's structure.
//!
//! No function here ends a statement or reads npm's options. A verb the
//! search finds where the lexer has no statement (an array value, a word a
//! parameter expansion holds) keeps the flag after it, which is the
//! release's, and nothing more: the bash rewrite went on to end a statement
//! there with its own end finder and to read it, and that reading is not
//! ported. Such text is not an install the rewrite read, so the record sees
//! its verb.

use crate::core::Run;
use crate::ere::Regex;
use crate::grammar;

type W = Vec<u8>;

pub struct Rx {
    /// `npm<OPTS>[[:space:]]+(<verbs>|<link verbs>)<END>`, any case.
    verb: Regex,
    /// The same with a blank or the end of the line after the verb, as
    /// v2.17.2's sed read it.
    verb_blank: Regex,
    /// `SAFEDEPS_G_NPM_INSTALL_RE`, any case.
    injectable: Regex,
    /// `(^|[[:space:]])--ignore-scripts([=[:space:]]|$)`
    skips: Regex,
    /// `[;&|()`$]`
    compound: Regex,
}

impl Rx {
    pub fn new() -> Rx {
        let p = grammar::patterns();
        let verbs = format!("npm{}[[:space:]]+({}|{})", grammar::OPTS, grammar::NPM_VERBS, grammar::NPM_LINK_VERBS);
        Rx {
            verb: Regex::new(&format!("{}{}", verbs, p.end), true).expect("verb pattern"),
            verb_blank: Regex::new(&format!("{}([[:space:]]|$)", verbs), true).expect("blank verb pattern"),
            injectable: Regex::new(&p.npm_install_re, true).expect("npm install pattern"),
            skips: Regex::new("(^|[[:space:]])--ignore-scripts([=[:space:]]|$)", false).expect("skips pattern"),
            compound: Regex::new("[;&|()`$]", false).expect("compound pattern"),
        }
    }
}

/// A command substitution's output: trailing newlines dropped.
pub fn subst(mut v: W) -> W {
    while v.last() == Some(&b'\n') {
        v.pop();
    }
    v
}

/// `grep -ob <re>` over `printf '%s\n' <text>`: each match of each line, the
/// longest from the leftmost start, the next searched after it, with its
/// offset in the text.
fn grep_ob(re: &Regex, text: &[u8]) -> Vec<(usize, W)> {
    let mut out = Vec::new();
    let mut off = 0usize;
    for line in text.split(|&b| b == b'\n') {
        let mut pos = 0usize;
        while pos <= line.len() {
            match re.find(&line[pos..]) {
                Some((s, e)) => {
                    out.push((off + pos + s, line[pos + s..pos + e].to_vec()));
                    pos += if e > s { e } else { s + 1 };
                }
                None => break,
            }
        }
        off += line.len() + 1;
    }
    out
}

/// The awk after the grep: the match ends in the byte that ended the verb
/// (unless the verb ended the line) and, before it, a `}` that closes a zsh
/// group; neither is the verb. `(start, end)`: the offset of the `npm` and
/// the offset just past the verb.
fn verb_end(s: usize, m: &[u8]) -> (usize, usize) {
    let mut len = m.len();
    if len > 0 && matches!(m[len - 1], b' ' | b'\t' | b'\n' | 0x0b | 0x0c | b'\r' | b';' | b'&' | b'|' | b'(' | b')' | b'<' | b'>' | b'`') {
        len -= 1;
    }
    if len > 0 && m[len - 1] == b'}' {
        len -= 1;
    }
    (s, s + len)
}

/// The reference rewrite's verbs in `text` (`inert_verb_ends`, then the end
/// finder's first test): `(npm start, verb end)`, the end being the offset
/// the floor flag goes after. A verb an opening backquote follows is none.
/// None on a failed reading.
pub fn verb_pairs(run: &mut Run, rx: &Rx, text: &[u8]) -> Option<Vec<(usize, usize)>> {
    let live = run.lex(text, "live")?;
    let flat = run.lex(text, "flat")?;
    let mut ms = grep_ob(&rx.verb, &live);
    if subst(flat.clone()) != subst(live.clone()) {
        ms.extend(grep_ob(&rx.verb, &flat));
    }
    let mut seen: Vec<(usize, usize)> = Vec::new();
    for (s, m) in ms {
        let pe = verb_end(s, &m);
        if !seen.contains(&pe) {
            seen.push(pe);
        }
    }
    let mut out = Vec::new();
    for (s, e) in seen {
        let inside = live[..e.min(live.len())].iter().filter(|&&b| b == b'`').count() % 2 == 1;
        if live.get(e) == Some(&b'`') && !inside {
            continue;
        }
        out.push((s, e));
    }
    Some(out)
}

/// Where v2.17.2 put the flag in a heredoc body the command pipes into
/// another command (class F): right after each npm install verb a blank
/// follows or that ends its line, in the body as written
/// (`inert_unread_offsets`, its F text). The offsets the flags go after.
pub fn fed_ends(run: &mut Run, rx: &Rx, text: &[u8]) -> Option<Vec<usize>> {
    if !text.windows(2).any(|w| w == b"<<") {
        return Some(Vec::new());
    }
    let classes = run.lex(text, "classes")?;
    if !classes.contains(&b'F') {
        return Some(Vec::new());
    }
    if classes.len() != text.len() {
        run.failed = true;
        return None;
    }
    let mut v: W = text.iter().map(|&b| if b == b'\n' { b'\n' } else { b' ' }).collect();
    for k in 0..text.len() {
        if classes[k] == b'F' {
            v[k] = text[k];
        }
    }
    let mut out = Vec::new();
    for (s, m) in grep_ob(&rx.verb_blank, &v) {
        let (_, e) = verb_end(s, &m);
        if !out.contains(&e) {
            out.push(e);
        }
    }
    Some(out)
}

fn wordch(b: u8) -> bool {
    b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b'-')
}

fn space(b: u8) -> bool {
    matches!(b, b' ' | b'\t' | b'\n' | 0x0b | 0x0c | b'\r')
}

/// The heads the reference rewrite's search finds in a scan view
/// (`inert_payload_spans`, its `grep -obE` of
/// `(^|[^[:alnum:]_.-])([[:alnum:]_.-]*sh[[:space:]]+-[A-Za-z]*c|eval)([[:space:]]|$)`):
/// for each, whether its word is one of bash, sh, zsh, dash and eval, and the
/// offset just past the match. The matches are grep's: per line, the leftmost
/// start, the longest from there, the next one searched after it, where `^`
/// no longer stands. Written out by hand, since the pattern is fixed: a head
/// starts at the line's first byte or after one byte that is no name byte;
/// its name bytes run up to `sh`, blanks follow, then `-`, letters and a last
/// `c`; a blank or the end of the line ends it.
fn script_heads(scan: &[u8]) -> Vec<(bool, usize)> {
    let mut out = Vec::new();
    let mut off = 0usize;
    for line in scan.split(|&b| b == b'\n') {
        let n = line.len();
        // The head whose name starts at `q`: the offset past the match, and
        // where the name ends.
        let head_at = |q: usize| -> Option<(usize, usize)> {
            if q + 4 <= n && line[q..q + 4] == b"eval"[..] && (q + 4 == n || space(line[q + 4])) {
                return Some(((q + 5).min(n), q + 4));
            }
            let mut r = q;
            while r < n && wordch(line[r]) {
                r += 1;
            }
            if r < q + 2 || line[r - 2..r] != b"sh"[..] {
                return None;
            }
            let mut u = r;
            while u < n && space(line[u]) {
                u += 1;
            }
            if u == r || u >= n || line[u] != b'-' {
                return None;
            }
            let mut v = u + 1;
            while v < n && line[v].is_ascii_alphabetic() {
                v += 1;
            }
            if v < u + 2 || line[v - 1] != b'c' {
                return None;
            }
            if v == n {
                return Some((v, r));
            }
            if space(line[v]) {
                return Some((v + 1, r));
            }
            None
        };
        let mut p = 0usize;
        while p < n {
            let q = if p == 0 && wordch(line[0]) {
                Some(0)
            } else if !wordch(line[p]) {
                Some(p + 1)
            } else {
                None
            };
            let found = match q {
                Some(q) => head_at(q).map(|(end, r)| (end, q, r)),
                None => None,
            };
            match found {
                Some((end, q, r)) => {
                    let name = &line[q..r];
                    let read = name == &b"bash"[..] || name == &b"sh"[..] || name == &b"zsh"[..] || name == &b"dash"[..] || name == &b"eval"[..];
                    out.push((read, off + end));
                    p = end.max(p + 1);
                }
                None => p += 1,
            }
        }
        off += n + 1;
    }
    out
}

/// The script words the reference rewrite's head search names in `text`
/// (`inert_payload_spans`), each as `lo..hi` in `text`.
pub struct Spans {
    /// A script it read as a text of its own (its R lines): what stands
    /// between the quotes of a single-quoted word, or of a double-quoted one
    /// with no escape and no substitution in it, after a head whose name is
    /// bash, sh, zsh, dash or eval.
    pub read: Vec<(usize, usize)>,
    /// A script word it did not read (its U lines): the word after a head
    /// whose name is no shell it reads (`ksh -c`, and whatever else the
    /// search takes for one: a name that ends in `sh`), and a double-quoted
    /// script for one it reads with an escape, a substitution or no closing
    /// quote in it. A word runs to the first byte the shell reads outside it,
    /// as the classes view says.
    pub unread: Vec<(usize, usize)>,
}

/// `inert_payload_spans`, its R and U lines. None on a failed reading.
///
/// These say where the release's bytes go and nothing else: not that a word
/// is a script any shell is handed, and not that anything in it was read.
/// The search knows no command position: it names the word after `sh -c` in
/// `echo sh -c 'npm ci x'` as the bash rewrite did, and the release's flag
/// stands there.
pub fn script_spans(run: &mut Run, text: &[u8]) -> Option<Spans> {
    let mut out = Spans { read: Vec::new(), unread: Vec::new() };
    let scan = subst(run.lex(text, "scan")?);
    let heads = script_heads(&scan);
    if heads.is_empty() {
        return Some(out);
    }
    let classes = run.lex(text, "classes")?;
    let n = text.len();
    if classes.len() != n {
        run.failed = true;
        return None;
    }
    let inword = |z: usize| -> bool {
        if classes[z] == b'c' {
            !matches!(text[z], b' ' | b'\t' | b'\n' | b';' | b'&' | b'|' | b'(' | b')' | b'<' | b'>')
        } else {
            !matches!(classes[z], b'p' | b'F' | b'.')
        }
    };
    for (read, pos) in heads {
        let mut p = pos;
        while p < n && matches!(text[p], b' ' | b'\t') {
            p += 1;
        }
        let mut z = p;
        while z < n && inword(z) {
            z += 1;
        }
        if read {
            let q = text.get(p).copied().unwrap_or(0);
            if q != b'\'' && q != b'"' {
                continue;
            }
            let close = text[p + 1..].iter().position(|&b| b == q);
            let body = close.map(|i| &text[p + 1..p + 1 + i]);
            let unreadable = q == b'"'
                && body.is_none_or(|b| b.contains(&b'\\') || b.contains(&b'`') || b.windows(2).any(|w| w == b"$("));
            if !unreadable {
                if let Some(i) = close {
                    if i >= 1 && !out.read.contains(&(p + 1, p + 1 + i)) {
                        out.read.push((p + 1, p + 1 + i));
                    }
                }
                continue;
            }
        }
        if z > p && !out.unread.contains(&(p, z)) {
            out.unread.push((p, z));
        }
    }
    Some(out)
}

/// Where v2.17.2 put the flag in script words the bash rewrite could not read
/// as texts of their own (`inert_unread_offsets`, its U text): right after
/// each npm install verb a blank follows or that ends its line, in the words'
/// bytes as written, quoted text included, code nested in their quotes left
/// out. `spans` are the words' ranges in `text`. The offsets the flags go
/// after, in `text`.
pub fn unread_script_ends(run: &mut Run, rx: &Rx, text: &[u8], spans: &[(usize, usize)]) -> Option<Vec<usize>> {
    if spans.is_empty() {
        return Some(Vec::new());
    }
    let classes = run.lex(text, "classes")?;
    if classes.len() != text.len() {
        run.failed = true;
        return None;
    }
    let mut v: W = text.iter().map(|&b| if b == b'\n' { b'\n' } else { b' ' }).collect();
    for &(lo, hi) in spans {
        for k in lo..hi.min(text.len()) {
            if matches!(classes[k], b'q' | b'l' | b'x' | b'e' | b'c') {
                v[k] = text[k];
            }
        }
    }
    let mut out = Vec::new();
    for (s, m) in grep_ob(&rx.verb_blank, &v) {
        let (_, e) = verb_end(s, &m);
        if !out.contains(&e) {
            out.push(e);
        }
    }
    Some(out)
}

/// `command_is_injectable_npm_install`, given the candidate texts.
pub fn injectable(rx: &Rx, candidates: &[u8]) -> bool {
    rx.injectable.grep_any(candidates)
}

/// `inert_release_skips`: the release left the command as written, because
/// the text `--ignore-scripts` stood in it.
pub fn release_skips(rx: &Rx, candidates: &[u8]) -> bool {
    rx.skips.grep_any(candidates)
}

/// `inert_release_appends`: the release appended its flag to the end of the
/// command, which it did for one statement on one line with no comment and
/// no heredoc.
pub fn release_appends(run: &mut Run, rx: &Rx, command: &[u8], candidates: &[u8]) -> bool {
    let Some(scanned) = run.lex(command, "scan") else { return false };
    let scanned = subst(scanned);
    if scanned.contains(&b'\n') {
        return false;
    }
    if rx.compound.is_match(&scanned) {
        return false;
    }
    if release_skips(rx, candidates) {
        return false;
    }
    if !rx.verb_blank.is_match(&scanned) {
        return false;
    }
    let Some(code) = run.lex(command, "code") else { return false };
    subst(code) == command
}
