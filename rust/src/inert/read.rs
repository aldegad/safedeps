//! The reader: the npm installs of one text, read from the lexer's structure
//! of that text's own top level. A statement and its words are
//! `Run::pieces`; which word is npm's command and what npm makes of the rest
//! are `manager::Reader`. Nothing here reads a view's bytes to find a verb or
//! an end, and nothing here reads text nested in this one: a payload is a
//! text of its own, read by asking this of it (`inert.rs`).

use crate::core::Run;
use crate::ere::Regex;
use crate::grammar;
use crate::manager::{self, Reader};

use super::record::INERT_BYTES;

type W = Vec<u8>;

pub struct Rx {
    /// `^(<verbs>|<link verbs>)$`, any case, as the reference rewrite's
    /// search reads a verb.
    verb: Regex,
}

impl Rx {
    pub fn new() -> Rx {
        Rx { verb: Regex::new(&format!("^({}|{})$", grammar::NPM_VERBS, grammar::NPM_LINK_VERBS), true).expect("verb word pattern") }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Note {
    /// Its own arguments leave ignore-scripts true.
    Settled,
    /// It asked for its scripts; the placed flag overrides them.
    Asked,
    /// A place was read.
    Plain,
    /// A word in it is one the shell decides at run time.
    Unverified,
    /// No place reads as true: the flag after the verb alone.
    Floor,
}

#[derive(Clone, Debug)]
pub struct Install {
    /// Where the three bytes `npm` that end the head word start, when the
    /// head is written so (an `npm` the reference's search matches there).
    pub npm: Option<usize>,
    /// The head is the statement's command word, npm by its last part,
    /// written as its value: a verb the record may count as read.
    pub command_word: bool,
    /// The offset just past the verb: the floor flag goes after it.
    pub verb_end: usize,
    /// The offset the read flag goes after.
    pub place: Option<usize>,
    pub note: Note,
}

/// A word the reader takes for npm's name: no blank in its value, and its
/// last part ends in `npm` in any case. The reference's search has no left
/// boundary either (`pnpm add x` beside an npm install is flagged there).
fn is_head(v: &[u8]) -> bool {
    if v.iter().any(|&b| matches!(b, b' ' | b'\t' | b'\n')) {
        return false;
    }
    let base = match v.iter().rposition(|&b| b == b'/') {
        Some(p) => &v[p + 1..],
        None => v,
    };
    base.len() >= 3 && base[base.len() - 3..].eq_ignore_ascii_case(b"npm")
}

fn is_dashes(w: &[u8]) -> bool {
    w.len() >= 2 && w.iter().all(|&b| b == b'-')
}

/// `shell_expands`, over the words of the statement (their values) and the
/// flat view's bytes of the statement: a `$` or a backquote in a value, or a
/// blank-separated run of the flat bytes that starts with `~` or `=` or holds
/// a byte outside the inert set.
fn shell_expands(words: &[W], flat: &[u8]) -> bool {
    if words.iter().any(|w| w.contains(&b'$') || w.contains(&b'`')) {
        return true;
    }
    for lw in flat.split(|&b| matches!(b, b' ' | b'\t' | b'\n')).filter(|w| !w.is_empty()) {
        if lw[0] == b'~' || lw[0] == b'=' {
            return true;
        }
        if lw.iter().any(|b| !INERT_BYTES.contains(b)) {
            return true;
        }
    }
    false
}

/// What npm makes of a statement cut out of a text (`inert_statement_reads`):
/// whether a word of it is only dashes, and, unless the shell can change a
/// word of it at run time or a reading does not close, the readings of the
/// words after the first.
struct Cut {
    ends: bool,
    reads: Option<Vec<(String, W)>>,
}

fn cut_reads(run: &mut Run, stmt: &[u8]) -> Option<Cut> {
    let core = run.c;
    let (pieces, _) = run.pieces(stmt)?;
    let argv: Vec<W> = pieces.pieces.iter().flat_map(|p| p.words.iter().map(|w| w.folded())).collect();
    let ends = argv.iter().any(|w| is_dashes(w));
    if pieces.unreadable {
        return Some(Cut { ends, reads: None });
    }
    let flat = run.lex(stmt, "flat")?;
    if shell_expands(&argv, &flat) {
        return Some(Cut { ends, reads: None });
    }
    let mut rd = Reader::new(&core.mrx);
    let reads = rd.npm_inert_reading(argv.get(1..).unwrap_or(&[]));
    Some(Cut { ends, reads })
}

/// A verb the reference rewrite's search found that no statement of the
/// reader owns, read as the bash rewrite read it: the text from its `npm`
/// (`s`) to where the reference's end finder ended it (`bound`), cut out and
/// read as a statement, its words taken as npm's whatever the first of them
/// is, and the flag tried at each of `cands` in turn (`floor::orphan_end`).
/// `e` is the offset just past the verb. None on a failed reading.
///
/// The statement is the reference's, not the lexer's: that is what makes this
/// a reading of text that is no statement (an array value, a word a
/// parameter expansion holds). It places flags; it does not make the text an
/// install for anything else.
pub fn cut_statement(run: &mut Run, text: &[u8], s: usize, e: usize, bound: usize, cands: &[usize]) -> Option<Install> {
    let mut install = Install { npm: Some(s), command_word: false, verb_end: e, place: None, note: Note::Floor };
    let bound = bound.min(text.len());
    if s >= bound {
        return Some(install);
    }
    let stmt = &text[s..bound];
    let first = cut_reads(run, stmt)?;
    if first.ends {
        return Some(install);
    }
    let Some(reads) = first.reads else {
        install.note = Note::Unverified;
        install.place = cands.first().copied();
        return Some(install);
    };
    if reads.iter().all(|(l, _)| l == "true") {
        install.note = Note::Settled;
        return Some(install);
    }
    let asked = reads.iter().any(|(l, _)| l == "false");
    for &p in cands {
        if p < s || p > bound {
            continue;
        }
        let mut placed: W = stmt[..p - s].to_vec();
        placed.extend_from_slice(b" --ignore-scripts");
        placed.extend_from_slice(&stmt[p - s..]);
        let again = cut_reads(run, &placed)?;
        let Some(r2) = again.reads else { continue };
        if again.ends {
            continue;
        }
        if r2.iter().all(|(l, _)| l == "true") && r2.iter().map(|(_, r)| r).eq(reads.iter().map(|(_, r)| r)) {
            install.place = Some(p);
            install.note = if asked { Note::Asked } else { Note::Plain };
            break;
        }
    }
    Some(install)
}

/// The npm installs of `text`'s own statements. None on a failed reading.
pub fn installs(run: &mut Run, rx: &Rx, text: &[u8]) -> Option<Vec<Install>> {
    let core = run.c;
    let (pieces, _) = run.pieces(text)?;
    let unreadable = pieces.unreadable;
    let mut flat: Option<W> = None;
    let mut out = Vec::new();
    for piece in &pieces.pieces {
        let words = &piece.words;
        for h in 0..words.len() {
            let head = &words[h];
            if !is_head(&head.value) {
                continue;
            }
            let mut ws: Vec<W> = words[h..].iter().map(|w| w.folded()).collect();
            ws[0] = b"npm".to_vec();
            let mut rd = Reader::new(&core.mrx);
            rd.read(&ws);
            if rd.family != "npm" {
                continue;
            }
            let Some(v) = rd.role.iter().position(|&r| r == b'c') else { continue };
            if v == 0 || v >= ws.len() || !rx.verb.is_match(&ws[v]) {
                continue;
            }
            let cut = (v + 1..ws.len()).find(|&k| is_dashes(&ws[k])).unwrap_or(ws.len());
            let ends = (1..v).any(|k| is_dashes(&ws[k]));
            let last = &words[h + cut - 1];
            let npm = if head.end >= 3 && head.end <= text.len() && text[head.end - 3..head.end].eq_ignore_ascii_case(b"npm") {
                Some(head.end - 3)
            } else {
                None
            };
            let command_word = h == 0
                && npm.is_some()
                && manager::name_is(&head.value, "npm")
                && head.end <= text.len()
                && text[head.start..head.end] == head.value[..];
            let verb_end = words[h + v].end;
            let mut install = Install { npm, command_word, verb_end, place: None, note: Note::Floor };
            if ends {
                out.push(install);
                continue;
            }
            if flat.is_none() {
                flat = Some(run.lex(text, "flat")?);
            }
            let fl = flat.as_ref().unwrap();
            let span = &fl[head.start.min(fl.len())..last.end.min(fl.len())];
            if unreadable || shell_expands(&ws[..cut], span) {
                install.note = Note::Unverified;
                install.place = Some(last.end);
                out.push(install);
                continue;
            }
            let args = &ws[1..cut];
            let Some(reads) = rd.npm_inert_reading(args) else {
                install.note = Note::Unverified;
                install.place = Some(last.end);
                out.push(install);
                continue;
            };
            if reads.iter().all(|(l, _)| l == "true") {
                install.note = Note::Settled;
                out.push(install);
                continue;
            }
            let asked = reads.iter().any(|(l, _)| l == "false");
            let want: Vec<&W> = reads.iter().map(|(_, r)| r).collect();
            // The first place, from the last argument back to the verb,
            // where npm reads the statement with the flag there as true and
            // everything else as before.
            let mut placed = None;
            for j in (v..cut).rev() {
                let mut a2: Vec<W> = ws[1..=j].to_vec();
                a2.push(b"--ignore-scripts".to_vec());
                a2.extend_from_slice(&ws[j + 1..cut]);
                let Some(r2) = rd.npm_inert_reading(&a2) else { continue };
                if r2.iter().all(|(l, _)| l == "true") && r2.iter().map(|(_, r)| r).eq(want.iter().copied()) {
                    placed = Some(words[h + j].end);
                    break;
                }
            }
            if let Some(p) = placed {
                install.place = Some(p);
                install.note = if asked { Note::Asked } else { Note::Plain };
            }
            out.push(install);
        }
    }
    Some(out)
}
