//! The inert rewrite and its record: `--ignore-scripts` for every npm install
//! the shell runs, and whether the command holds an install the rewrite did
//! not read.
//!
//! # The reader
//!
//! A reader reads the top level of the text it is given, and nothing else.
//! Text nested in it is a payload, read by asking the same question of the
//! payload:
//!
//! ```text
//! places(text):
//!   for each statement of text's top level (Run::pieces) whose command
//!   word is npm and whose reading (manager::Reader) is an install:
//!       the place for its flag, among the ends of its words (read.rs)
//!   for each payload of text (Run::payloads, one level):
//!       places(payload.text), each carried back through payload.src
//! ```
//!
//! The lexer says where a statement starts and ends, which word is the
//! command, where each word stands and what a `}` closes. No reader here
//! looks for a verb or an end in a view's bytes. The bash rewrite did
//! (`inert_verb_ends` greps the live view, the end finder counts depth and
//! backticks there again, `inert_nested_verb_ends` and `inert_payload_spans`
//! patch what that misses), and each of its rejected defects was that reader
//! reading a nested text with the outer level's quoting. Those readers are
//! not ported.
//!
//! A place in a payload is a place in the command only through `src`, and
//! only once it is read back: the text the payload came from, with the flag
//! there, is lexed again, and the same payload must be the payload with the
//! flag at its place. A place that fails is not placed; the install keeps
//! its floor and is recorded as one.
//!
//! What the structure does not call a command is not read. The reference's
//! search finds a verb wherever the bytes `npm <verb>` stand: in an argument
//! of another command (`echo npm ci x`, `sudo npm ci x`), in an array value
//! (`a=(npm ci x)`), in a word a parameter expansion holds (`${u:-npm ci
//! x}`), in a word with an escaped operator. The bash rewrite went on to end
//! a statement at each with its own end finder and read it. Here such a verb
//! keeps the release's flag after it (floor.rs) and nothing else: no place is
//! read for it and it is not counted as read, so the record sees it. Where
//! the shell runs such text as a command, that is the structure's to say,
//! not a second reader's.
//!
//! # The release's floor (floor.rs)
//!
//! Every rewrite holds 7d66f8c's: the flag right after each verb the
//! reference rewrite's own search finds (`grep -ob` over the live and flat
//! views of the command and of each script the bash rewrite read as a text of
//! its own), the flag at the end of a command the release appended to, and
//! v2.17.2's flag in the
//! two texts the bash rewrite did not read: a heredoc body piped into another
//! command, and a script word its own search names as unread (a double-quoted
//! one with an escape or a substitution, one handed to another shell), there
//! in the word's bytes as written. Those positions say
//! where a flag goes and nothing else: not whether a statement is an install,
//! where it ends, whether its `npm` was read, or what npm makes of its
//! options. A floor position belongs to an install only where the two name
//! the same `npm` bytes, and only to drop the floor of an install that is
//! already true in a command the release left as written, as the bash rewrite
//! does. v2.17.2's flags in a script the bash rewrite did not read are never
//! dropped: it placed them without reading the install.
//!
//! Beyond those bytes the rewrite adds one thing, the place the reader read.
//! No flag goes after a verb the reference's search did not find, and no
//! offset of a payload's own text becomes an offset of the command without
//! being read back.
//!
//! # Duties that collide
//!
//! Three things are owed at once: the release's bytes (the floor), the
//! arguments and the data of the command as written, and a flag npm reads as
//! the option. They cannot always be had together. `echo npm ci x` beside an
//! install is the plain case: the release wrote its flag into what `echo`
//! prints, and no rewrite both keeps that flag and prints what the command
//! printed. Where they cannot, the command is not rewritten at all: the
//! reading's value is `collision <kind>`, and the guard answers `UNDECIDED`
//! with that as a reason of its own. The floor is not dropped to let the
//! command run, and a record does not stand in for a flag.
//!
//! A flag the release owes is one the reader can answer for where it stands
//! right after a word of an install the reader read (in the command, or read
//! back through every text above it), and npm's tables read the statement
//! with the flag there as they read it without, the flag an option.
//!
//! - `floor-outside-command`: the release owes a flag where no such word
//!   ends: in an argument of another command (`echo npm ci x`, `sudo npm ci
//!   x`), in an array value, in a word a parameter expansion holds, in a
//!   script no shell is handed (`echo sh -c 'npm ci x'`), in a heredoc body
//!   another command reads, in a script word whose flag does not read back.
//!   Whether such text reaches npm is the structure's to say, and it has not
//!   said so; nothing here guesses what a wrapper runs or follows a value to
//!   where it is used.
//! - `floor-not-an-option`: the word is an install's, and npm does not read
//!   the flag there as the option with everything else as before (`npm -- ci
//!   x`: an operand; `npm install true`: the flag takes the word as its
//!   value).
//! - `end-flag-outside-command`, `end-flag-not-an-option`: the same for the
//!   flag the release appended to a one-statement command, read back as one
//!   more word of the install (`npm install x --cache`: `--cache` takes it as
//!   its value).
//!
//! A word the shell decides at run time does not make a collision by
//! standing in a statement, and it does not excuse one. `npm install $X`
//! keeps its flags and is recorded as unverified, as before: the flag after
//! the verb is followed by a word nobody can read, and npm cannot be asked.
//! `npm -- ci $X` is a collision all the same: the words before the flag are
//! as written, and they make it an operand whatever `$X` turns out to be
//! (`read::Install::flag_after`). Unverified is a record, never a reading of
//! the option as true. The command is never run to find out.
//!
//! # The record (record.rs)
//!
//! `inert_bytes_left_unread` and `inert_dynamic_command_word`, ported as they
//! are. Two things decide whether a verb counts as read (`@`), and they are
//! kept apart:
//!
//! - What the reader read. The structure and the manager's tables say it: an
//!   install is a statement whose command word is npm by its value, quoted
//!   or not (`npm ci`, `"npm" ci`).
//! - What the bash rewrite left unread. Three facts of its reading are kept
//!   as duties to record, and each can only keep an install the reader read
//!   from counting: the text is one the bash rewrite read as a text of its
//!   own (the command, a substitution body, a quoted script for sh, bash,
//!   zsh, dash or eval), its search found the verb, and its command-word
//!   test agrees. None of them makes an install of text the reader did not
//!   read, and none of them places a flag or ends a statement.
//!
//! So where the bash rewrite recorded a verb it did not read, this records it
//! too, flag or no flag.
//!
//! # Differences from the bash rewrite
//!
//! The bash guard is the reference where this reads the same. Where it does
//! not, the difference has a name in
//! `scripts/measure/core-intended-inert.tsv`, and three rules hold:
//!
//! 1. It adds a flag, adds a record, or turns a pass into `UNDECIDED`. A
//!    difference that drops a flag or a record has no name; it is a defect.
//!    One input is named apart, with conditions the comparison checks
//!    (`argument-substitution-preserved`): there the bash rewrite put a flag
//!    inside an argument's substitution that holds no install.
//! 2. Its evidence is what the shells hand npm: the argv of a stand-in npm
//!    under bash, zsh and dash, beside both answers.
//! 3. A text with no payload reads as the bash rewrite reads it, but for two
//!    classes: a `}` after a line continuation, and a command whose three
//!    readings hold different rewrites, byte for byte, so that none is sent
//!    and the command is `UNDECIDED`.
//!
//! # Where the shell's plumbing decides a bash result
//!
//! - `$(shell_lex ...)` drops the newlines that end a view.
//! - The awk programs read each view from a file with `slurp`, which drops
//!   one newline at the end of the file, and read a command given on their
//!   input as lines, which drops the newline that ends it.
//! - `grep -ob` prints every match of a line, each the longest from the
//!   leftmost start, the next one searched after the last.
//! - The pieces view writes \002 for an empty word and for a blank, a
//!   parenthesis or a brace inside a word, and its readers turn \002 into a
//!   space: `WordSpan::folded` is that spelling.
//! - The offsets are sorted and made unique before the flags go in, and the
//!   release's end flag is the one at the command's last byte when a place
//!   already stands there.

mod floor;
mod read;
mod record;

use std::collections::{BTreeSet, HashMap};

use crate::core::{self, Core, Payload, PayloadOrigin, Run};
use crate::lex::Reading;

type W = Vec<u8>;

/// What the rewrite found, for one reading. The bash function's exit status
/// packs these: 4 alone is `settled` with no flag placed, and with a rewrite
/// printed it is 4 plus 1 (`asked`), 2 (`unverified`), 4 (`floor`) and 8
/// (`unread`).
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Rewrite {
    /// The command with every flag in place; None when no flag was placed.
    pub command: Option<Vec<u8>>,
    /// Every install already leaves ignore-scripts true.
    pub settled: bool,
    /// An install asked for its scripts and the flag now overrides it.
    pub asked: bool,
    /// An install holds a word the shell decides at run time.
    pub unverified: bool,
    /// An install keeps only the flag after its verb, or gets none.
    pub floor: bool,
    /// The command holds an npm install the rewrite did not read.
    pub unread: bool,
    /// The release owes a flag where the duties of this rewrite cannot be
    /// met together (see "Duties that collide"): no rewrite is sent, and the
    /// guard answers `UNDECIDED` with this as its reason.
    pub collision: Option<&'static str>,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Failed {
    /// A reading failed: the guard settles it as `UNDECIDED`.
    Reading,
}

struct Rx {
    floor: floor::Rx,
    read: read::Rx,
    record: record::Rx,
}

thread_local! {
    static RX: Rx = Rx { floor: floor::Rx::new(), read: read::Rx::new(), record: record::Rx::new() };
}

/// How deep the payloads are read, and how many: past either, a payload is
/// not read, so its installs get no read place and no `@` (the record sees
/// them); the floor of the command's own search still holds.
const MAX_DEPTH: u32 = 8;
const MAX_TEXTS: usize = 1024;

/// How deep the reference rewrite read a script inside a script
/// (`inert_offsets_of`: a script's own scripts are searched while its depth
/// is under four).
const FLOOR_DEPTH: u32 = 4;

const FLAG: &[u8] = b" --ignore-scripts";

/// One text the rewrite reads: the command, or a payload of a text read.
struct Node {
    text: W,
    /// For each byte, where it stands in the command (from 0).
    map: Vec<Option<usize>>,
    /// `R` for the command, else the payload's kind.
    kind: u8,
    parent: usize,
    /// Its place among its parent's payloads.
    index: usize,
    /// For each byte, where it stands in the parent.
    src: Vec<Option<usize>>,
    depth: u32,
    /// The bash rewrite read this text as a text of its own, so a verb in it
    /// may count as read.
    read_like: bool,
    /// How many scripts (S and E payloads) lie on the way from the command.
    scripts: u32,
}

impl Node {
    fn byte(&self, k: usize) -> Option<usize> {
        self.map.get(k).copied().flatten()
    }
    /// The command offset a flag goes after, for offset `e` in this text.
    fn after(&self, e: usize) -> Option<usize> {
        if e == 0 {
            return None;
        }
        self.byte(e - 1).map(|k| k + 1)
    }
    /// Where three bytes from `a` stand in the command, when they stand
    /// there together.
    fn three(&self, a: usize) -> Option<usize> {
        let x = self.byte(a)?;
        (self.byte(a + 1)? == x + 1 && self.byte(a + 2)? == x + 2).then_some(x)
    }
}

fn insert(text: &[u8], at: usize) -> W {
    let at = at.min(text.len());
    let mut v = Vec::with_capacity(text.len() + FLAG.len());
    v.extend_from_slice(&text[..at]);
    v.extend_from_slice(FLAG);
    v.extend_from_slice(&text[at..]);
    v
}

/// Whether `npm` stands in the text, in any case: without it the reference's
/// search finds no verb, and the text is not searched.
fn mentions_npm(text: &[u8]) -> bool {
    text.windows(3).any(|w| w.eq_ignore_ascii_case(b"npm"))
}

fn base(w: &[u8]) -> &[u8] {
    match w.iter().rposition(|&b| b == b'/') {
        Some(p) => &w[p + 1..],
        None => w,
    }
}

/// Whether the bash rewrite read `p` as a text of its own, where a verb can
/// count as read: a substitution body; or a script for sh, bash, zsh, dash
/// or `eval` that is one quoted segment of the parent, a whole word, single
/// quoted or double quoted with no escape and no substitution in it, written
/// right after `<shell> -<letters>c` or `eval` (`inert_payload_spans`, its R
/// spans: the head is its pattern over the parent's bytes). This only keeps a
/// verb from counting as read, so it can only add a record.
fn read_like(parent: &[u8], p: &Payload) -> bool {
    let shellc = match p.origin {
        PayloadOrigin::CommandSubstitution | PayloadOrigin::Backquote | PayloadOrigin::ProcessSubstitution => return true,
        PayloadOrigin::EnvSplit => return false,
        PayloadOrigin::ShellC => true,
        PayloadOrigin::Eval => false,
    };
    if p.text.is_empty() || p.src.len() != p.text.len() {
        return false;
    }
    let Some(a) = p.src[0] else { return false };
    if p.src.iter().enumerate().any(|(i, s)| *s != Some(a + i)) {
        return false;
    }
    let z = a + p.text.len();
    if a == 0 || z >= parent.len() {
        return false;
    }
    let q = parent[a - 1];
    if (q != b'\'' && q != b'"') || parent[z] != q {
        return false;
    }
    if q == b'"' && (p.text.contains(&b'\\') || p.text.contains(&b'`') || p.text.windows(2).any(|w| w == b"$(")) {
        return false;
    }
    let after = z + 1 >= parent.len() || matches!(parent[z + 1], b' ' | b'\t' | b'\n' | b';' | b'&' | b'|' | b'(' | b')' | b'<' | b'>');
    if !after {
        return false;
    }
    // The head, read back from the opening quote.
    let blank = |b: u8| matches!(b, b' ' | b'\t' | b'\n' | 0x0b | 0x0c | b'\r');
    let name = |b: u8| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b'-');
    let mut j = a - 1;
    let gap = j;
    while j > 0 && matches!(parent[j - 1], b' ' | b'\t') {
        j -= 1;
    }
    if j == gap {
        return false;
    }
    if shellc {
        // `-<letters>c`
        if j == 0 || parent[j - 1] != b'c' {
            return false;
        }
        j -= 1;
        while j > 0 && parent[j - 1].is_ascii_alphabetic() {
            j -= 1;
        }
        if j == 0 || parent[j - 1] != b'-' {
            return false;
        }
        j -= 1;
        let gap = j;
        while j > 0 && blank(parent[j - 1]) {
            j -= 1;
        }
        if j == gap {
            return false;
        }
    }
    let end = j;
    while j > 0 && name(parent[j - 1]) {
        j -= 1;
    }
    let word = &parent[j..end];
    let ok = if shellc { matches!(word, b"sh" | b"bash" | b"zsh" | b"dash") } else { word == b"eval" };
    if !ok {
        return false;
    }
    if shellc && !p.shell.as_ref().is_some_and(|s| base(s) == word) {
        return false;
    }
    true
}

/// The bash rewrite's test that an `npm` at offset `s` stands as a command
/// word, read on the cmdword view `v` of the text it was found in: at the
/// start or after a separator, a `(` or a backquote, or after a reserved word
/// that a command follows; a path's last part counts.
fn bash_command_word(v: &[u8], s: usize) -> bool {
    const KW: [&[u8]; 11] = [b"!", b"{", b"if", b"then", b"else", b"elif", b"while", b"until", b"do", b"time", b"coproc"];
    const PATHB: &[u8] = b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/@:+,=%-";
    let g = |j: isize| -> u8 {
        if j >= 1 && (j as usize) <= v.len() {
            v[j as usize - 1]
        } else {
            0
        }
    };
    let sep = |c: u8| c != 0 && b";&|(`\n".contains(&c);
    let mut j = s as isize;
    if j >= 1 && g(j) == b'/' {
        while j >= 1 && PATHB.contains(&g(j)) {
            j -= 1;
        }
    }
    loop {
        while j >= 1 && (g(j) == b' ' || g(j) == b'\t') {
            j -= 1;
        }
        if j < 1 || sep(g(j)) {
            return true;
        }
        let e = j;
        while j >= 1 && (g(j).is_ascii_lowercase() || g(j) == b'!' || g(j) == b'{') {
            j -= 1;
        }
        let w = &v[j as usize..e as usize];
        if !KW.contains(&w) {
            return false;
        }
        if j >= 1 && g(j) != b' ' && g(j) != b'\t' && !sep(g(j)) {
            return false;
        }
    }
}

/// The payload `index` of `parent`, read again with the flag at `t` in
/// `parent`: it must be `child` with the flag at `q`.
fn reads_back(run: &mut Run, parent: &[u8], t: usize, index: usize, child: &[u8], q: usize) -> bool {
    let p2 = insert(parent, t);
    let (failed, diverge) = (run.failed, run.diverge);
    let ps = run.payloads(&p2);
    run.failed = failed;
    run.diverge = diverge;
    ps.get(index).is_some_and(|p| p.text == insert(child, q))
}

/// A place `q` in node `ni`, carried to the command, read back at each level.
fn carry(run: &mut Run, nodes: &[Node], ni: usize, q: usize) -> Option<usize> {
    let (mut cur, mut pos) = (ni, q);
    while cur != 0 {
        let node = &nodes[cur];
        if pos == 0 {
            return None;
        }
        let t = node.src.get(pos - 1).copied().flatten()? + 1;
        let parent = &nodes[node.parent];
        if !reads_back(run, &parent.text, t, node.index, &node.text, pos) {
            return None;
        }
        pos = t;
        cur = node.parent;
    }
    Some(pos)
}

fn note_name(n: read::Note) -> &'static str {
    match n {
        read::Note::Settled => "settled",
        read::Note::Asked => "asked",
        read::Note::Plain => "plain",
        read::Note::Unverified => "unverified",
        read::Note::Floor => "floor",
    }
}

fn num(o: Option<usize>) -> String {
    o.map(|v| v.to_string()).unwrap_or_else(|| "-".into())
}

/// `inert_rewrite_in_place <command>`, in the run's reading; `cands` is the
/// candidate texts (`command_candidate_start_texts`), and `detail`, when
/// given, gets one line per place found, for the comparison.
fn rewrite_with(run: &mut Run, rx: &Rx, command: &[u8], cands: &[u8], detail: &mut Option<W>) -> Option<Rewrite> {
    let release_rewrote = !floor::release_skips(&rx.floor, cands);
    // The texts: the command and every payload, each mapped to the command.
    let mut nodes: Vec<Node> = vec![Node {
        text: command.to_vec(),
        map: (0..command.len()).map(Some).collect(),
        kind: b'R',
        parent: 0,
        index: 0,
        src: Vec::new(),
        depth: 0,
        read_like: true,
        scripts: 0,
    }];
    let mut i = 0;
    while i < nodes.len() {
        if nodes[i].depth < MAX_DEPTH && nodes.len() < MAX_TEXTS {
            let text = nodes[i].text.clone();
            let ps = run.payloads(&text);
            let mut kids = Vec::new();
            for (index, p) in ps.into_iter().enumerate() {
                if nodes.len() + kids.len() >= MAX_TEXTS {
                    break;
                }
                let parent = &nodes[i];
                let map = p.src.iter().map(|s| s.and_then(|k| parent.byte(k))).collect();
                let scripts = parent.scripts + matches!(p.kind, b'S' | b'E') as u32;
                let rl = parent.read_like && scripts <= 4 && read_like(&parent.text, &p);
                kids.push(Node { map, kind: p.kind, parent: i, index, depth: parent.depth + 1, read_like: rl, scripts, src: p.src, text: p.text });
            }
            nodes.extend(kids);
        }
        i += 1;
    }
    // The release's floor: the reference's verbs, v2.17.2's flags in piped
    // heredocs and its flags in the script words the bash rewrite did not
    // read, in the texts the reference searched. Which texts those are is the
    // reference's own search for a script's head (`floor::script_spans`): the
    // command, and each script it read as a text of its own, to the depth it
    // read them. Such a script is one quoted segment of the text that holds
    // it, so an offset in it is that offset in the command, shifted.
    //
    // None of this asks the lexer what a payload is. The floor is bytes the
    // release wrote: it wrote the flag into `echo sh -c 'npm ci x'` too,
    // where no shell is handed that script and the structure names no
    // payload, and a floor found only in the payloads the structure names
    // lost that flag. And a payload is no floor text: a flag carried from a
    // script's own text through its source map, unread, broke the word that
    // holds it (a script word of several quoted segments lost its last
    // argument), and v2.17.2's flags given to every script payload put one
    // after the `--` of an `npm -- ci x`.
    let mut pairs: Vec<(Option<usize>, usize)> = Vec::new();
    let mut fed: BTreeSet<usize> = BTreeSet::new();
    let mut floor_texts: Vec<(W, usize, u32)> = vec![(command.to_vec(), 0, 0)];
    let mut ft = 0;
    while ft < floor_texts.len() {
        let (text, base, depth) = floor_texts[ft].clone();
        ft += 1;
        if mentions_npm(&text) {
            for (s, e) in floor::verb_pairs(run, &rx.floor, &text)? {
                let pair = (Some(base + s), base + e);
                if !pairs.contains(&pair) {
                    pairs.push(pair);
                }
            }
        }
        if depth >= FLOOR_DEPTH {
            continue;
        }
        for e in floor::fed_ends(run, &rx.floor, &text)? {
            fed.insert(base + e);
        }
        let spans = floor::script_spans(run, &text)?;
        for e in floor::unread_script_ends(run, &rx.floor, &text, &spans.unread)? {
            fed.insert(base + e);
        }
        for (lo, hi) in spans.read {
            if floor_texts.len() < MAX_TEXTS {
                floor_texts.push((text[lo..hi].to_vec(), base + lo, depth + 1));
            }
        }
    }
    // The reader, in every text.
    struct Found {
        node: usize,
        npm: Option<usize>,
        /// The install as the reader read it, in its own text.
        inst: read::Install,
        place: Option<usize>,
        wanted: bool,
        note: read::Note,
        at: Option<usize>,
    }
    let mut memo: HashMap<W, Vec<read::Install>> = HashMap::new();
    let mut cmdwords: HashMap<usize, W> = HashMap::new();
    let mut found: Vec<Found> = Vec::new();
    for ni in 0..nodes.len() {
        let text = nodes[ni].text.clone();
        let ins = match memo.get(&text) {
            Some(v) => v.clone(),
            None => {
                let v = read::installs(run, &rx.read, &text)?;
                memo.insert(text.clone(), v.clone());
                v
            }
        };
        for inst in ins {
            let node = &nodes[ni];
            let npm = inst.npm.and_then(|a| node.three(a));
            let place = match inst.place {
                None => None,
                Some(q) if ni == 0 => Some(q),
                Some(q) => carry(run, &nodes, ni, q),
            };
            // The reader read this install: its statement's command word is
            // npm, by the structure. What follows is no part of that reading.
            // It is what the bash rewrite left unread, kept as a duty to
            // record: a text the bash rewrite did not read as one of its own,
            // a verb its search did not find (a quoted or escaped `npm` or
            // verb among them), or one its command-word test did not pass.
            // Each can only keep a verb from counting as read, which can only
            // add a record; none makes an install of text the reader did not
            // read.
            let paired = npm.is_some_and(|x| pairs.iter().any(|(ps, _)| *ps == Some(x)));
            let mut left_unread = !nodes[ni].read_like || !paired;
            if !left_unread {
                if !cmdwords.contains_key(&ni) {
                    let v = run.lex(&text, "cmdword")?;
                    cmdwords.insert(ni, v);
                }
                left_unread = !bash_command_word(&cmdwords[&ni], inst.npm.unwrap_or(0));
            }
            let at = if left_unread { None } else { npm };
            found.push(Found { node: ni, npm, place, wanted: inst.place.is_some(), note: inst.note, at, inst });
        }
    }
    // The flags.
    let settled_npm: Vec<usize> = found.iter().filter(|f| f.note == read::Note::Settled).filter_map(|f| f.npm).collect();
    let mut offsets: BTreeSet<usize> = BTreeSet::new();
    let (mut settled, mut asked, mut unverified, mut floor_rec) = (false, false, false, false);
    let mut read_at: Vec<usize> = Vec::new();
    // Every offset the release owes a flag at: the kept verb flags, and
    // v2.17.2's.
    let mut owed: Vec<usize> = Vec::new();
    for &(s, e) in &pairs {
        let kept = release_rewrote || !s.is_some_and(|s| settled_npm.contains(&s));
        if kept {
            offsets.insert(e);
            owed.push(e);
        }
        if let Some(d) = detail.as_mut() {
            d.extend_from_slice(format!("pair {} {} {}\n", num(s), e, kept as u8).as_bytes());
        }
    }
    for &e in &fed {
        offsets.insert(e);
        owed.push(e);
        if let Some(d) = detail.as_mut() {
            d.extend_from_slice(format!("fed {}\n", e).as_bytes());
        }
    }
    // What the reader adds to the floor is the place it read, and nothing
    // else: a place in the command is npm's own reading of the statement
    // with the flag there, and a place in a payload has been read back
    // through every text above it (`carry`). The flag after a verb is the
    // floor's, where the reference's search found that verb; where it did
    // not, no flag after the verb is owed and none is placed. One placed
    // there unread stood after a `--` (`npm -- ci x`, an operand to npm) or
    // outside the quotes of the word that holds the script.
    for f in &found {
        match f.note {
            read::Note::Settled => settled = true,
            read::Note::Floor => floor_rec = true,
            read::Note::Unverified => {
                unverified = true;
                match f.place {
                    Some(p) => {
                        offsets.insert(p);
                    }
                    None => floor_rec = true,
                }
            }
            read::Note::Asked | read::Note::Plain => match f.place {
                Some(p) => {
                    offsets.insert(p);
                    if f.note == read::Note::Asked {
                        asked = true;
                    }
                }
                None => floor_rec = true,
            },
        }
        read_at.extend(f.at);
        if let Some(d) = detail.as_mut() {
            d.extend_from_slice(
                format!(
                    "install {} {} {} {} {} {} {}\n",
                    f.node,
                    num(f.npm),
                    note_name(f.note),
                    num(nodes[f.node].after(f.inst.verb_end)),
                    num(f.place),
                    f.wanted as u8,
                    num(f.at)
                )
                .as_bytes(),
            );
        }
    }
    read_at.sort_unstable();
    read_at.dedup();
    // Duties that collide. A flag the release owes must be one the reader
    // can answer for: it stands right after a word of an install the reader
    // read (in the command, or read back through every text above it), and
    // npm reads the statement with the flag there as it reads it without,
    // the flag an option. A flag owed anywhere else stands in what the
    // structure calls data, or in the arguments of a command nobody here
    // knows to run npm; one npm does not read as the option changes an
    // argument. Neither can be sent and neither may be left out, so the
    // command is not rewritten at all.
    let n = command.len();
    let append = floor::release_appends(run, &rx.floor, command, cands);
    let mut collision: Option<(&'static str, usize)> = None;
    for &e in &owed {
        if collision.is_some() {
            break;
        }
        let mut check: Option<read::Check> = None;
        'owner: for f in &found {
            for (k, &q) in f.inst.ends.iter().enumerate() {
                if nodes[f.node].after(q) != Some(e) {
                    continue;
                }
                if f.node != 0 && carry(run, &nodes, f.node, q) != Some(e) {
                    continue;
                }
                check = Some(f.inst.flag_after(run.c, k));
                break 'owner;
            }
        }
        match check {
            None => collision = Some(("floor-outside-command", e)),
            Some(read::Check::Changes) => collision = Some(("floor-not-an-option", e)),
            Some(_) => {}
        }
    }
    if collision.is_none() && append && !offsets.contains(&n) {
        // The release's end flag: appended, it must be one more word of an
        // install the reader read in the command, and an option there.
        let mut check: Option<read::Check> = None;
        for f in found.iter().filter(|f| f.node == 0) {
            let (failed, diverge) = (run.failed, run.diverge);
            let last = read::appended_is_last_word(run, command, f.inst.piece);
            run.failed = failed;
            run.diverge = diverge;
            if last == Some(true) {
                check = Some(f.inst.flag_after(run.c, f.inst.ends.len().saturating_sub(1)));
                break;
            }
        }
        match check {
            None => collision = Some(("end-flag-outside-command", n)),
            Some(read::Check::Changes) => collision = Some(("end-flag-not-an-option", n)),
            Some(_) => {}
        }
    }
    if let Some((kind, at)) = collision {
        if let Some(d) = detail.as_mut() {
            d.extend_from_slice(format!("collision {} {}\n", kind, at).as_bytes());
        }
        return Some(Rewrite { collision: Some(kind), ..Rewrite::default() });
    }
    // The record.
    let left = record::bytes_left_unread(run, &rx.record, command, &read_at).ok()?;
    let mut unread = left.unread;
    if !unread {
        unread = record::dynamic_command_word(run, &rx.record, command, &left.levels).ok()?;
    }
    if let Some(d) = detail.as_mut() {
        d.extend_from_slice(format!("texts {} release {} unread {}\n", nodes.len(), release_rewrote as u8, unread as u8).as_bytes());
    }
    offsets.retain(|&o| o >= 1 && o <= n);
    if offsets.is_empty() {
        if settled && !unread && !floor_rec {
            return Some(Rewrite { settled: true, ..Rewrite::default() });
        }
        return Some(Rewrite::default());
    }
    let mut out = Vec::with_capacity(n + FLAG.len() * (offsets.len() + 1));
    for (k, &b) in command.iter().enumerate() {
        out.push(b);
        if offsets.contains(&(k + 1)) {
            out.extend_from_slice(FLAG);
        }
    }
    if append && !offsets.contains(&n) {
        out.extend_from_slice(FLAG);
    }
    Some(Rewrite { command: Some(out), settled, asked, unverified, floor: floor_rec, unread, collision: None })
}

/// The kind of a `collision` value of `reading_inert`, or None for any other
/// value. Whoever settles the readings asks this of each reading's value
/// before anything else: one reading that holds a collision makes the command
/// `UNDECIDED`, with no rewrite and no record of one, whether the readings
/// agree or not.
pub fn collision_kind(value: &[u8]) -> Option<&[u8]> {
    value.strip_prefix(COLLISION)
}

const COLLISION: &[u8] = b"collision ";

/// Runs `f` with a fresh failure flag: a reading that fails inside is the
/// rewrite's failure, and the flag the run had stays set.
fn guarded<'c>(run: &mut Run<'c>, f: impl FnOnce(&mut Run<'c>) -> Option<Rewrite>) -> Result<Rewrite, Failed> {
    let before = run.failed;
    run.failed = false;
    let r = f(run);
    let failed = run.failed;
    run.failed = before || failed;
    match r {
        Some(rw) if !failed => Ok(rw),
        _ => {
            run.failed = true;
            Err(Failed::Reading)
        }
    }
}

/// `inert_rewrite_in_place <command>`, in the run's reading.
pub fn rewrite_in_place(run: &mut Run, command: &[u8]) -> Result<Rewrite, Failed> {
    let cands = floor::subst(run.candidate_texts(command));
    RX.with(|rx| guarded(run, |run| rewrite_with(run, rx, command, &cands, &mut None)))
}

/// `guard_reading_inert`: how this reading makes the command's npm installs
/// inert, as the value the readings are compared on (`GUARD_INERT_<reading>`):
/// `none`, `downgrade`, `rewrite` with its notes and the command on the next
/// line, or `collision <kind>` where the duties of the rewrite cannot be met
/// together. A failed reading marks the run.
///
/// `collision` is not a value of the bash guard's. Whoever settles the
/// readings answers `UNDECIDED` for the command when any reading holds it
/// (`collision_kind`), the same in all three or not, with a reason of its
/// own, sends no rewrite and writes no record of one. A caller that does not
/// ask reads the value as no rewrite and lets the command run as written,
/// which is the one thing a collision must not become.
pub fn reading_inert(run: &mut Run, command: &[u8]) -> W {
    reading_inert_detail(run, command, &mut None)
}

fn reading_inert_detail(run: &mut Run, command: &[u8], detail: &mut Option<W>) -> W {
    RX.with(|rx| {
        let cands = floor::subst(run.candidate_texts(command));
        if !floor::injectable(&rx.floor, &cands) {
            return b"none".to_vec();
        }
        let r = guarded(run, |run| rewrite_with(run, rx, command, &cands, detail));
        if let Ok(Rewrite { collision: Some(kind), .. }) = &r {
            let mut o = COLLISION.to_vec();
            o.extend_from_slice(kind.as_bytes());
            return o;
        }
        let updated = match &r {
            Ok(rw) if rw.command.is_none() && rw.settled => return b"none".to_vec(),
            Ok(rw) => rw.command.clone().filter(|c| c.as_slice() != command),
            Err(_) => None,
        };
        let Some(updated) = updated else {
            if floor::release_appends(run, &rx.floor, command, &cands) {
                let mut o = b"rewrite release\n".to_vec();
                o.extend_from_slice(command);
                o.extend_from_slice(FLAG);
                return o;
            }
            return b"downgrade".to_vec();
        };
        let rw = r.unwrap_or_default();
        let mut o = b"rewrite".to_vec();
        if rw.asked {
            o.extend_from_slice(b" asked");
        }
        if rw.unverified {
            o.extend_from_slice(b" unverified");
        }
        if rw.floor {
            o.extend_from_slice(b" floor");
        }
        if rw.unread {
            o.extend_from_slice(b" unread");
        }
        o.push(b'\n');
        o.extend_from_slice(&updated);
        o
    })
}

/// `safedeps-core inert`: the rewrite of one hook payload (stdin) in each
/// reading the guard reads it in, as `<key> <length>\n<bytes>\n` records:
/// `reading_set`, `any_install`, then per reading `inert.<reading>` (the
/// value `guard_reading_inert` sets), `payloads.<reading>` (how many payloads
/// the command's own top level hands on) and `detail.<reading>`, and last
/// `failed` (the scan mark once the rewrite has run).
///
/// A detail is this reading's own account, for the comparison to sort rows
/// by, never evidence of what a shell runs: `pair <npm> <verb end> <kept>`
/// for each verb the reference search found, `fed <offset>` for each flag of
/// v2.17.2's in text the bash rewrite did not read, `install <text>
/// <npm> <note> <verb end> <place> <wanted> <read at>` for each install the
/// reader found, each a statement whose command word is npm, and `collision
/// <kind> <offset>` for the first owed flag nobody can answer for.
pub fn cli(input: &[u8]) -> i32 {
    let Some((tool, cmd)) = core::command_of_payload(input) else { return 0 };
    let mut cmd: W = cmd.into_iter().filter(|&b| b != 0).collect();
    while cmd.last() == Some(&b'\n') {
        cmd.pop();
    }
    if tool != "Bash" || cmd.is_empty() {
        return 0;
    }
    let c = Core::new();
    let mut run = Run::new(&c);
    let facts = run.facts(&cmd);
    let get = |k: &str| facts.records.iter().find(|(key, _)| key == k).map(|(_, v)| v.clone());
    let any = get("any_install").as_deref() == Some(&b"true"[..]);
    let set = get("reading_set.facts").or_else(|| get("reading_set")).unwrap_or_default();
    let mut recs: Vec<(String, W)> = vec![("reading_set".into(), set.clone()), ("any_install".into(), if any { b"true".to_vec() } else { b"false".to_vec() })];
    if any {
        let readings: Vec<Reading> = set.split(|&b| b == b' ').filter_map(|r| Reading::parse(std::str::from_utf8(r).unwrap_or(""))).collect();
        for r in readings {
            let name = match r {
                Reading::Bash => "bash",
                Reading::Zsh => "zsh",
                Reading::Dash => "dash",
            };
            run.reading = Some(r);
            let (failed, diverge) = (run.failed, run.diverge);
            let payloads = run.payloads(&cmd).len();
            run.failed = failed;
            run.diverge = diverge;
            let mut detail = Some(W::new());
            let o = reading_inert_detail(&mut run, &cmd, &mut detail);
            recs.push((format!("inert.{}", name), o));
            recs.push((format!("payloads.{}", name), payloads.to_string().into_bytes()));
            recs.push((format!("detail.{}", name), detail.unwrap_or_default()));
            run.reading = None;
        }
        if set == b"bash" && run.diverge {
            run.failed = true;
        }
    }
    recs.push(("failed".into(), if run.failed { b"true".to_vec() } else { b"false".to_vec() }));
    // The records as `safedeps-core facts` writes its own: `<key> <length>`,
    // the bytes, a newline. Written here, so that this output does not
    // depend on what else the shared record type comes to hold.
    let mut out = W::new();
    for (k, v) in &recs {
        out.extend_from_slice(format!("{} {}\n", k, v.len()).as_bytes());
        out.extend_from_slice(v);
        out.push(b'\n');
    }
    use std::io::Write;
    let mut so = std::io::stdout().lock();
    let _ = so.write_all(&out);
    let _ = so.flush();
    0
}
