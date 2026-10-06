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
//! views of the command and of each script it hands to a shell), the flag at
//! the end of a command the release appended to, and v2.17.2's flag in the
//! two texts the bash rewrite did not read: a heredoc body piped into another
//! command, and a script word that is not one plain quoted segment or goes to
//! another shell, there in the word's bytes as written. Those positions say
//! where a flag goes and nothing else: not whether a statement is an install,
//! where it ends, whether its `npm` was read, or what npm makes of its
//! options. A floor position belongs to an install only where the two name
//! the same `npm` bytes, and only to drop the floor of an install that is
//! already true in a command the release left as written, as the bash rewrite
//! does. In a script the bash rewrite did not read, that floor is never
//! dropped: there it placed v2.17.2's flag without reading the install.
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
//! - What the bash rewrite left unread. Four facts of its reading are kept
//!   as duties to record, and each can only keep an install the reader read
//!   from counting: the command word is written as its bytes, the text is
//!   one the bash rewrite read as a text of its own (the command, a
//!   substitution body, a quoted script for sh, bash, zsh, dash or eval),
//!   its search found the verb, and its command-word test agrees. None of
//!   them makes an install of text the reader did not read, and none of them
//!   places a flag or ends a statement.
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
    // The release's floor: the reference's verbs in the command and in the
    // scripts it hands to a shell, and v2.17.2's flags in piped heredocs.
    // A pair in a script the bash rewrite did not read as a text of its own
    // (its U spans: another shell's script, a double-quoted one with an
    // escape or a substitution) is v2.17.2's flag there, placed whether or
    // not that install is already true: `always` keeps it.
    let mut pairs: Vec<(Option<usize>, usize)> = Vec::new();
    let mut always: Vec<usize> = Vec::new();
    let mut fed: BTreeSet<usize> = BTreeSet::new();
    for node in &nodes {
        if !matches!(node.kind, b'R' | b'S' | b'E') {
            continue;
        }
        let verbs = if mentions_npm(&node.text) { floor::verb_pairs(run, &rx.floor, &node.text)? } else { Vec::new() };
        for (s, e) in verbs {
            if let Some(er) = node.after(e) {
                if !pairs.contains(&(node.byte(s), er)) {
                    pairs.push((node.byte(s), er));
                }
                if node.kind != b'R' && !node.read_like {
                    always.push(er);
                }
            }
        }
        for e in floor::fed_ends(run, &rx.floor, &node.text)? {
            if let Some(er) = node.after(e) {
                fed.insert(er);
            }
        }
    }
    // v2.17.2's flags in a script the bash rewrite did not read, placed in
    // the word as written, in the bytes of the text that holds it. Two
    // sources name such a word, and a flag either names is placed: the bash
    // rewrite's own search for a script's head, in the texts it read (the
    // command, and the scripts it read as texts of their own), and a script
    // payload it did not read as a text of its own (a `sh -c` or `eval`
    // script word that is not one plain quoted segment, another shell's
    // script).
    for node in &nodes {
        if node.kind != b'R' && !(matches!(node.kind, b'S' | b'E') && node.read_like) {
            continue;
        }
        let spans = floor::unread_spans(run, &node.text)?;
        for e in floor::unread_script_ends(run, &rx.floor, &node.text, &spans)? {
            if let Some(er) = node.after(e) {
                fed.insert(er);
            }
        }
    }
    for node in &nodes {
        if !matches!(node.kind, b'S' | b'E') || node.read_like {
            continue;
        }
        let Some(lo) = node.src.iter().flatten().min().copied() else { continue };
        let Some(hi) = node.src.iter().flatten().max().map(|m| m + 1) else { continue };
        let parent = &nodes[node.parent];
        for e in floor::unread_script_ends(run, &rx.floor, &parent.text, &[(lo, hi)])? {
            if let Some(er) = parent.after(e) {
                fed.insert(er);
            }
        }
    }
    // The reader, in every text.
    struct Found {
        node: usize,
        npm: Option<usize>,
        verb: Option<usize>,
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
            let verb = node.after(inst.verb_end);
            let place = match inst.place {
                None => None,
                Some(q) if ni == 0 => Some(q),
                Some(q) => carry(run, &nodes, ni, q),
            };
            // The reader read this install: its statement's command word is
            // npm, by the structure. What follows is no part of that reading.
            // It is what the bash rewrite left unread, kept as a duty to
            // record: a command word not written as its bytes, a text the
            // bash rewrite did not read as one of its own, a verb its search
            // did not find, or one its command-word test did not pass. Each
            // can only keep a verb from counting as read, which can only add
            // a record; none makes an install of text the reader did not
            // read.
            let paired = npm.is_some_and(|x| pairs.iter().any(|(ps, _)| *ps == Some(x)));
            let mut left_unread = !inst.plain || !nodes[ni].read_like || !paired;
            if !left_unread {
                if !cmdwords.contains_key(&ni) {
                    let v = run.lex(&text, "cmdword")?;
                    cmdwords.insert(ni, v);
                }
                left_unread = !bash_command_word(&cmdwords[&ni], inst.npm.unwrap_or(0));
            }
            let at = if left_unread { None } else { npm };
            found.push(Found { node: ni, npm, verb, place, wanted: inst.place.is_some(), note: inst.note, at });
        }
    }
    // The flags.
    let settled_npm: Vec<usize> = found.iter().filter(|f| f.note == read::Note::Settled).filter_map(|f| f.npm).collect();
    let mut offsets: BTreeSet<usize> = BTreeSet::new();
    let (mut settled, mut asked, mut unverified, mut floor_rec) = (false, false, false, false);
    let mut read_at: Vec<usize> = Vec::new();
    for &(s, e) in &pairs {
        let kept = release_rewrote || always.contains(&e) || !s.is_some_and(|s| settled_npm.contains(&s));
        if kept {
            offsets.insert(e);
        }
        if let Some(d) = detail.as_mut() {
            d.extend_from_slice(format!("pair {} {} {}\n", num(s), e, kept as u8).as_bytes());
        }
    }
    for &e in &fed {
        offsets.insert(e);
        if let Some(d) = detail.as_mut() {
            d.extend_from_slice(format!("fed {}\n", e).as_bytes());
        }
    }
    for f in &found {
        let has_pair = f.npm.is_some_and(|s| pairs.iter().any(|(ps, _)| *ps == Some(s)));
        let floor_at = if has_pair { None } else { f.verb };
        match f.note {
            read::Note::Settled => {
                settled = true;
                if release_rewrote {
                    offsets.extend(floor_at);
                }
            }
            read::Note::Floor => {
                floor_rec = true;
                offsets.extend(floor_at);
            }
            read::Note::Unverified => {
                unverified = true;
                match f.place {
                    Some(p) => {
                        offsets.insert(p);
                    }
                    None => floor_rec = true,
                }
                offsets.extend(floor_at);
            }
            read::Note::Asked | read::Note::Plain => {
                match f.place {
                    Some(p) => {
                        offsets.insert(p);
                        if f.note == read::Note::Asked {
                            asked = true;
                        }
                    }
                    None => floor_rec = true,
                }
                offsets.extend(floor_at);
            }
        }
        read_at.extend(f.at);
        if let Some(d) = detail.as_mut() {
            d.extend_from_slice(
                format!(
                    "install {} {} {} {} {} {} {}\n",
                    f.node,
                    num(f.npm),
                    note_name(f.note),
                    num(f.verb),
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
    // The record.
    let left = record::bytes_left_unread(run, &rx.record, command, &read_at).ok()?;
    let mut unread = left.unread;
    if !unread {
        unread = record::dynamic_command_word(run, &rx.record, command, &left.levels).ok()?;
    }
    if let Some(d) = detail.as_mut() {
        d.extend_from_slice(format!("texts {} release {} unread {}\n", nodes.len(), release_rewrote as u8, unread as u8).as_bytes());
    }
    let n = command.len();
    offsets.retain(|&o| o >= 1 && o <= n);
    if offsets.is_empty() {
        if settled && !unread && !floor_rec {
            return Some(Rewrite { settled: true, ..Rewrite::default() });
        }
        return Some(Rewrite::default());
    }
    let append = floor::release_appends(run, &rx.floor, command, cands);
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
    Some(Rewrite { command: Some(out), settled, asked, unverified, floor: floor_rec, unread })
}

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
/// `none`, `downgrade`, or `rewrite` with its notes and the command on the
/// next line. A failed reading marks the run.
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
/// v2.17.2's in text the bash rewrite did not read, and `install <text>
/// <npm> <note> <verb end> <place> <wanted> <read at>` for each install the
/// reader found, each a statement whose command word is npm.
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
    use std::io::Write;
    let mut so = std::io::stdout().lock();
    let _ = so.write_all(&core::render(&core::Facts { records: recs }));
    let _ = so.flush();
    0
}
