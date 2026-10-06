//! The reader: the npm installs of one text, read from the lexer's structure
//! of that text's own top level. A statement and its words are
//! `Run::pieces`, and an install is a statement whose first word, the command
//! word, is npm by its value; which word is npm's command and what npm makes
//! of the rest are `manager::Reader`. A word that says `npm` anywhere else in
//! a statement (`echo npm ci x`, `sudo npm ci x`) is an argument of another
//! command and is not read. Nothing here reads a view's bytes to find a verb
//! or an end, and nothing here reads text nested in this one: a payload is a
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
    /// Where the three bytes `npm` that end the command word start, when the
    /// word is written so (an `npm` the reference's search can match there).
    /// A command word that is npm by its value and not by these bytes
    /// (`"npm" ci`, `n\pm ci`) is read all the same.
    pub npm: Option<usize>,
    /// The offset just past the verb: the floor flag goes after it.
    pub verb_end: usize,
    /// The offset the read flag goes after.
    pub place: Option<usize>,
    pub note: Note,
}

/// The command word names npm: no blank in its value, and its last part is
/// `npm` in any case (`npm`, `./node_modules/.bin/npm`, `NPM`).
fn is_npm(v: &[u8]) -> bool {
    !v.iter().any(|&b| matches!(b, b' ' | b'\t' | b'\n')) && manager::name_is(v, "npm")
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

/// The npm installs of `text`'s own statements. None on a failed reading.
pub fn installs(run: &mut Run, rx: &Rx, text: &[u8]) -> Option<Vec<Install>> {
    let core = run.c;
    let (pieces, _) = run.pieces(text)?;
    let unreadable = pieces.unreadable;
    let mut flat: Option<W> = None;
    let mut out = Vec::new();
    for piece in &pieces.pieces {
        let words = &piece.words;
        // The statement's command word, and nothing further on.
        let Some(head) = words.first() else { continue };
        if !is_npm(&head.value) {
            continue;
        }
        {
            let mut ws: Vec<W> = words.iter().map(|w| w.folded()).collect();
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
            let last = &words[cut - 1];
            let npm = if head.end >= 3 && head.end <= text.len() && text[head.end - 3..head.end].eq_ignore_ascii_case(b"npm") {
                Some(head.end - 3)
            } else {
                None
            };
            let verb_end = words[v].end;
            let mut install = Install { npm, verb_end, place: None, note: Note::Floor };
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
                    placed = Some(words[j].end);
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
