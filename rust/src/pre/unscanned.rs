//! `guard_looks_like_install_unscanned`: the test that decides a command no
//! reading finished, from its text alone.

use super::{is_space, W};
use crate::ere::Regex;
use crate::grammar;
use std::collections::hash_map::RandomState;
use std::collections::{HashMap, HashSet};
use std::hash::BuildHasher;
use std::ops::Range;

/// Whether the command's text reads as an install when no reading of it
/// finished. With no reader's answer in hand, the command is read as a set of
/// words, in no order and with no structure. The words are those of every
/// view of the command: the text after a sequence of the rewrites in
/// `REWRITES`, each a step the shell or a program it hands the text to takes
/// before a manager runs (line continuations joined, the escapes printf,
/// `echo -e` and `$'...'` expand, the quote characters dropped, a
/// `${name-word}` taken as its word, an expansion taken as empty, a glob's
/// group written as a brace group), in any order and as often as one changes
/// the text. Each view is cut into words as it is
/// and again without its quote characters and backslashes (`"npm"`, `n''pm`,
/// `\npm`). A word ends at each byte of `BREAKS`: a blank, a quote, `$`, a
/// backquote, a bracket of any kind, a redirection or an operator character,
/// `,`, `=` and a glob character. So a redirection, a
/// group, a glob qualifier, an expansion or a substitution beside a name
/// leaves the name a word (`pip>/dev/null`, `pip(N)`, `pip$IFS'install'`,
/// `$(npm`). A brace expansion adds the words it makes
/// (`in{stall,}` makes `install`), and a word with a glob character is also
/// read as a pattern, which stands for each name or verb it matches
/// (`/usr/bin/pi[p]`).
///
/// The words read as an install where they hold a form of the grammar's
/// install body (`grammar::install_forms`): a package manager's name, as a
/// word or the last part of a word's path, and that manager's install verbs
/// as words beside it. So a wrapper, a payload, a heredoc or a message around
/// them changes nothing, while a name inside another word (`pipefail`,
/// `Google`), a manager with no install verb beside it (`python3 -c`, `npm
/// run`) and a verb of another manager (`pip add`) are no install. One more
/// view reads as one though no verb is in it: a word whose value is decided
/// at run time (`$X`, not an assignment's value) and, after it in the same
/// statement, a manager's name as a word of its own, as in `env -S "$X" pip`.
/// That word can be the script that names the verb. A text with more views
/// than `UNSCANNED_VIEWS`, a sequence of more than `UNSCANNED_DEPTH`, or brace
/// expansions past `BRACE_BYTES` reads as an install: not all of it was read.
/// A view that holds a NUL byte reads as an install, whatever its words. bash
/// ends a `$'...'` at the first escape that stands for NUL and glues what
/// follows the closing quote, so `$'pi\0junk'p` is `pip` and `pip
/// $'inst\0junk'all` runs `pip install`, and the manager or verb it assembles
/// is a word no view reconstructs without lexing the shell's nested quotes,
/// which this test does not. A NUL-producing escape (`\0`, `\x00`, `\c@`, an
/// octal multiple of 256, `\u0000`), through any number of quote and
/// backslash layers, becomes a NUL byte in some view, because the rewrites
/// expand the escapes and drop the quotes again and again up to the bounds
/// below. Such an escape has no use an install needs and is in none of the
/// parent's real failed-reading denials, so a view that holds one is read as
/// an install rather than cut into words.
pub(super) fn looks_like_install_unscanned(command: &[u8]) -> bool {
    let Ok(run_time) = Regex::new(
        &format!(
            "(^|[[:space:];&|(){{}}`])[$][^[:space:];&|]*([[:space:]]+[^[:space:];&|]+)*[[:space:]]+([^[:space:];&|()<>`]*/)?({})([[:space:];&|)<>`]|$)",
            grammar::EXECUTABLES
        ),
        true,
    ) else {
        return true;
    };
    let mut words = Words::default();
    let first = continuations_joined(command);
    if words.read(&first, &run_time) {
        return true;
    }
    // A depth-first walk: each entry of `path` is a view, the next rewrite
    // to take of it, and which bytes it holds.
    let mut seen = HashSet::from([words.key(&first)]);
    let held = bytes_held(&first);
    let mut path = vec![(first, 0, held)];
    while let Some((view, next, held)) = path.last_mut() {
        let Some(&(rewrite, needs)) = REWRITES.get(*next) else {
            path.pop();
            continue;
        };
        *next += 1;
        if !needs.iter().any(|&b| held[usize::from(b)]) {
            continue;
        }
        let text = rewrite(view);
        if text == *view || !seen.insert(words.key(&text)) {
            continue;
        }
        if seen.len() > UNSCANNED_VIEWS || path.len() == UNSCANNED_DEPTH || words.read(&text, &run_time) {
            return true;
        }
        let held = bytes_held(&text);
        path.push((text, 0, held));
    }
    words.install()
}

/// Which bytes `text` holds.
fn bytes_held(text: &[u8]) -> [bool; 256] {
    let mut held = [false; 256];
    for &b in text {
        held[usize::from(b)] = true;
    }
    held
}

/// The rewrites `looks_like_install_unscanned` makes its views with, each
/// with the bytes one of which a text must hold for it to change the text.
/// None of them lengthens the text, and each but `glob_groups_braced`
/// shortens a text it changes; that one leaves fewer parentheses, which only
/// an escape, and so a shorter text, brings back. So every sequence of them
/// that changes the text ends.
pub(super) const REWRITES: [(fn(&[u8]) -> W, &[u8]); 7] = [
    (continuations_joined, b"\\"),
    (escapes_expanded, b"\\"),
    (echo_escapes_expanded, b"\\"),
    (quotes_dropped, b"'\""),
    (defaults_taken, b"$"),
    (expansions_dropped, b"$`"),
    (glob_groups_braced, b"("),
];

/// The most views `looks_like_install_unscanned` reads of one command, and
/// the most it holds at once, the views of one sequence of rewrites. The walk
/// takes the time of a pass over the command for each rewrite of each view,
/// and holds a copy of the command for each view of the sequence it is on.
pub(super) const UNSCANNED_VIEWS: usize = 1024;
pub(super) const UNSCANNED_DEPTH: usize = 64;

/// The most bytes the brace expansions of one command make, counting each
/// text an expansion takes a step through.
pub(super) const BRACE_BYTES: usize = 1 << 24;

/// The bytes that end a word: a blank, a quote, `$`, a backquote, a bracket
/// of any kind, a redirection or an operator character, `,`, `=` and a glob
/// character. A backslash ends none, as in the shell (`junk\npm` is one
/// word); the cut without backslashes reads `\npm` and `n\pm`. A NUL from an
/// escape ends no word here, because `nul_escape` denied the command first.
const BREAKS: [bool; 256] = table(b"'\"`$()[]{}<>;&|,=*? \t\n\x0b\x0c\r");

/// Of those, the glob characters, which a word read as a pattern keeps.
const GLOB: [bool; 256] = table(b"[]*?");

/// The bytes that end the text a brace expansion stays in: those that end a
/// word, but for the glob characters, which a pattern the expansion makes
/// keeps. No word of an expansion goes past one, so two groups a break stands
/// between are expanded apart.
const SEGMENT_BREAKS: [bool; 256] = minus(BREAKS, GLOB);

/// A table of the bytes of `bytes`.
const fn table(bytes: &[u8]) -> [bool; 256] {
    let mut t = [false; 256];
    let mut i = 0;
    while i < bytes.len() {
        t[bytes[i] as usize] = true;
        i += 1;
    }
    t
}

/// The bytes of `a` that are not bytes of `b`.
const fn minus(a: [bool; 256], b: [bool; 256]) -> [bool; 256] {
    let mut t = a;
    let mut i = 0;
    while i < 256 {
        t[i] = a[i] && !b[i];
        i += 1;
    }
    t
}

/// The words of a command, gathered over its views.
#[derive(Default)]
struct Words {
    /// Two hashes under keys drawn for this call tell a text from another, so
    /// the sets hold no text and no command can be written to collide.
    keys: (RandomState, RandomState),
    /// The texts already cut into words.
    read: HashSet<(u64, u64)>,
    /// The segments already expanded.
    expanded: HashSet<(u64, u64)>,
    /// Each word once, folded to lower case.
    plain: HashSet<W>,
    /// Each word that has a glob character and a letter or digit, folded to
    /// lower case and kept with its glob characters, to be read as a pattern.
    globs: HashSet<W>,
    /// The bytes the brace expansions made.
    made: usize,
}

impl Words {
    fn key(&self, text: &[u8]) -> (u64, u64) {
        (self.keys.0.hash_one(text), self.keys.1.hash_one(text))
    }

    /// Takes the words of a view, and answers whether the view reads as an
    /// install on its own: by the run-time rule, or because its brace
    /// expansions went past `BRACE_BYTES`.
    fn read(&mut self, view: &[u8], run_time: &Regex) -> bool {
        if view.contains(&0) {
            return true;
        }
        let bare = unquoted(view);
        if run_time.grep_any(&bare) {
            return true;
        }
        for text in [view, bare.as_slice()] {
            if !self.read.insert(self.key(text)) {
                continue;
            }
            self.cut(text);
            if !self.expand(text) {
                return true;
            }
        }
        false
    }

    /// Takes the words of `text`, once with every byte of `BREAKS` ending a
    /// word and once with the glob characters kept.
    fn cut(&mut self, text: &[u8]) {
        let mut lower = W::new();
        for glob in [false, true] {
            let mut start = 0;
            for i in 0..=text.len() {
                if i < text.len() && !(BREAKS[usize::from(text[i])] && !(glob && GLOB[usize::from(text[i])])) {
                    continue;
                }
                let word = &text[start..i];
                start = i + 1;
                let set = match glob {
                    false => &mut self.plain,
                    true if word.iter().any(|&b| GLOB[usize::from(b)]) && word.iter().any(u8::is_ascii_alphanumeric) => &mut self.globs,
                    true => continue,
                };
                lower.clear();
                lower.extend(word.iter().map(u8::to_ascii_lowercase));
                if !word.is_empty() && !set.contains(&lower) {
                    set.insert(lower.clone());
                }
            }
        }
    }

    /// Takes the words of each text the brace expansions of `text` make.
    /// False when the expansions went past `BRACE_BYTES`.
    fn expand(&mut self, text: &[u8]) -> bool {
        if !text.contains(&b'{') {
            return true;
        }
        for range in segments(text) {
            let segment = &text[range];
            if group(segment).is_none() || !self.expanded.insert(self.key(segment)) {
                continue;
            }
            if !self.expansions(segment) {
                return false;
            }
        }
        true
    }

    /// Takes the words of each text a brace expansion of `segment` makes, as
    /// bash makes them: the segment with its first group replaced by each of
    /// its words, and the same again in that text, which is still one word.
    /// False when the texts went past `BRACE_BYTES`.
    fn expansions(&mut self, segment: &[u8]) -> bool {
        let mut texts = vec![segment.to_vec()];
        while let Some(text) = texts.pop() {
            let Some((open, close, words)) = group(&text) else {
                self.cut(&text);
                self.cut(&unquoted(&text));
                continue;
            };
            for word in words {
                let made = [&text[..open], &word, &text[close + 1..]].concat();
                self.made += made.len();
                if self.made > BRACE_BYTES {
                    return false;
                }
                texts.push(made);
            }
        }
        true
    }

    /// Whether the words hold a form of the install body.
    fn install(&self) -> bool {
        let mut stands = HashMap::new();
        let mut stand = |pattern: &str, name: bool| *stands.entry((pattern.to_string(), name)).or_insert_with(|| self.stands(pattern, name));
        for form in grammar::install_forms().iter().flatten() {
            if stand(form.manager, true) && form.words.iter().all(|word| stand(word, false)) {
                return true;
            }
        }
        false
    }

    /// Whether a word matches `pattern`, or with `name` whether the last part
    /// of a word's path does. A word read as a pattern matches it when some
    /// text matches both and the pattern spells it: all its bytes but one at
    /// most are each one byte, in either case (`pi[p]`, `n?m`, `pip3.1*`). A
    /// pattern that leaves more open (`[a-z]*`) stands for any file, and
    /// which file is the cwd's to say, not the text's. A verb is a file's name
    /// only as one spelling with no run in it (a coordinate of Maven's or an
    /// operand is no file of the cwd).
    fn stands(&self, pattern: &str, name: bool) -> bool {
        let alternatives = alternatives(pattern);
        let first = alternatives.iter().fold(Set::default(), |set, a| set.or(first(a)));
        let spellings: Vec<&Vec<Tok>> = alternatives.iter().filter(|a| name || a.iter().all(|t| t.kind != Kind::Star)).collect();
        self.plain.iter().map(|word| base(word, name)).any(|word| word.first().is_some_and(|&b| first.has(b)) && alternatives.iter().any(|a| matches(word, a)))
            || self
                .globs
                .iter()
                .map(|word| glob(base(word, name)))
                .filter(|toks| toks.iter().filter(|t| t.kind != Kind::One || !t.set.single()).count() <= 1 && toks.iter().any(|t| t.set.single()))
                .any(|toks| spellings.iter().any(|a| meet(&toks, a)))
    }
}

/// The word, or with `name` the last part of its path.
fn base(word: &[u8], name: bool) -> &[u8] {
    match name {
        true => word.rsplit(|&b| b == b'/').next().unwrap_or(word),
        false => word,
    }
}

/// For each `{` of `text` that a `}` closes, the index of that `}`.
fn pairs(text: &[u8]) -> Vec<Option<usize>> {
    let mut pairs = vec![None; text.len()];
    let mut open = Vec::new();
    for (i, &b) in text.iter().enumerate() {
        match b {
            b'{' => open.push(i),
            b'}' => {
                if let Some(o) = open.pop() {
                    pairs[o] = Some(i);
                }
            }
            _ => {}
        }
    }
    pairs
}

/// The runs of `text` a brace expansion stays in: between the bytes of
/// `SEGMENT_BREAKS`, where a byte inside a pair of braces that holds one
/// word ends none.
fn segments(text: &[u8]) -> Vec<Range<usize>> {
    let pairs = pairs(text);
    let mut out = Vec::new();
    let (mut start, mut i) = (0, 0);
    while i < text.len() {
        if let Some(close) = pairs[i].filter(|&close| one_word(&text[i + 1..close])) {
            i = close + 1;
            continue;
        }
        if SEGMENT_BREAKS[usize::from(text[i])] {
            if i > start {
                out.push(start..i);
            }
            start = i + 1;
        }
        i += 1;
    }
    if start < text.len() {
        out.push(start..text.len());
    }
    out
}

/// Whether `text`, read from outside any quote, holds no blank, operator or
/// parenthesis outside quotes: bash expands a brace group only inside one
/// word, so a pair around code with blanks in it is no group.
fn one_word(text: &[u8]) -> bool {
    let mut quote = None;
    let mut i = 0;
    while i < text.len() {
        match (quote, text[i]) {
            (None | Some(b'"'), b'\\') => i += 1,
            (None, b @ (b'\'' | b'"')) => quote = Some(b),
            (Some(q), b) if b == q => quote = None,
            (None, b) if is_space(b) || b";&|<>()".contains(&b) => return false,
            _ => {}
        }
        i += 1;
    }
    true
}

/// The first group of a brace expansion in `segment`, the `}` that closes it
/// and the words it makes: a pair of braces, not opened by a `$`, around
/// words that commas outside any inner pair part, or around a sequence.
fn group(segment: &[u8]) -> Option<(usize, usize, Vec<W>)> {
    let pairs = pairs(segment);
    for (open, close) in pairs.iter().enumerate().filter_map(|(i, c)| c.map(|c| (i, c))) {
        if open > 0 && segment[open - 1] == b'$' {
            continue;
        }
        let mut words = Vec::new();
        let (mut start, mut i) = (open + 1, open + 1);
        while i < close {
            if let Some(c) = pairs[i] {
                i = c + 1;
                continue;
            }
            if segment[i] == b',' {
                words.push(segment[start..i].to_vec());
                start = i + 1;
            }
            i += 1;
        }
        if !words.is_empty() {
            words.push(segment[start..close].to_vec());
            return Some((open, close, words));
        }
        if let Some(words) = sequence(&segment[open + 1..close]) {
            return Some((open, close, words));
        }
    }
    None
}

/// The words of a sequence expression (`{a..e}`, `{1..9..2}`): the bytes
/// from one letter to the other by the step, or for integers the two ends as
/// written, since a digit only matters to a name like `pip3` and any digit
/// does there.
fn sequence(inner: &[u8]) -> Option<Vec<W>> {
    let text = std::str::from_utf8(inner).ok()?;
    let parts: Vec<&str> = text.split("..").collect();
    let step = match parts.len() {
        2 => 1,
        3 => parts[2].parse::<i64>().ok()?.unsigned_abs().max(1),
        _ => return None,
    };
    let integer = |s: &str| s.parse::<i64>().is_ok();
    if integer(parts[0]) && integer(parts[1]) {
        return Some(vec![parts[0].as_bytes().to_vec(), parts[1].as_bytes().to_vec()]);
    }
    let letter = |s: &str| (s.len() == 1 && s.as_bytes()[0].is_ascii_alphabetic()).then(|| s.as_bytes()[0]);
    let (a, b) = (letter(parts[0])?, letter(parts[1])?);
    Some((a.min(b)..=a.max(b)).step_by(step as usize).map(|c| vec![c]).collect())
}

/// A set of bytes.
#[derive(Clone, Copy, Default)]
struct Set([u64; 4]);

impl Set {
    fn all() -> Set {
        Set([u64::MAX; 4])
    }
    fn has(&self, b: u8) -> bool {
        self.0[usize::from(b >> 6)] >> (b & 63) & 1 == 1
    }
    fn add(&mut self, b: u8) {
        self.0[usize::from(b >> 6)] |= 1 << (b & 63);
        for c in [b.to_ascii_lowercase(), b.to_ascii_uppercase()] {
            self.0[usize::from(c >> 6)] |= 1 << (c & 63);
        }
    }
    fn of(b: u8) -> Set {
        let mut set = Set::default();
        set.add(b);
        set
    }
    fn or(self, other: Set) -> Set {
        Set(std::array::from_fn(|i| self.0[i] | other.0[i]))
    }
    fn not(self) -> Set {
        Set(self.0.map(|w| !w))
    }
    fn meets(&self, other: &Set) -> bool {
        (0..4).any(|i| self.0[i] & other.0[i] != 0)
    }
    /// Whether the set is one byte, in either case.
    fn single(&self) -> bool {
        (0..=255u8).find(|&b| self.has(b)).is_some_and(|b| self.0 == Set::of(b).0)
    }
}

/// How often a token takes a byte of its set: once, at most once, or any
/// number of times.
#[derive(Clone, Copy, PartialEq)]
enum Kind {
    One,
    Opt,
    Star,
}

#[derive(Clone, Copy)]
struct Tok {
    set: Set,
    kind: Kind,
}

/// The alternatives of a pattern of the grammar, each a sequence of tokens:
/// a byte, `.`, or a bracket expression, each with `?`, `*` or `+` after it
/// or none. Letters match in either case.
fn alternatives(pattern: &str) -> Vec<Vec<Tok>> {
    pattern
        .split('|')
        .map(|alternative| {
            let b = alternative.as_bytes();
            let mut toks = Vec::new();
            let mut i = 0;
            while i < b.len() {
                let (set, next) = match b[i] {
                    b'[' => class(b, i, b"^").unwrap_or((Set::of(b'['), i + 1)),
                    b'.' => (Set::all(), i + 1),
                    b'\\' if i + 1 < b.len() => (Set::of(b[i + 1]), i + 2),
                    c => (Set::of(c), i + 1),
                };
                let (kind, after) = match b.get(next) {
                    Some(b'?') => (Kind::Opt, next + 1),
                    Some(b'*') => (Kind::Star, next + 1),
                    Some(b'+') => {
                        toks.push(Tok { set, kind: Kind::One });
                        (Kind::Star, next + 1)
                    }
                    _ => (Kind::One, next),
                };
                toks.push(Tok { set, kind });
                i = after;
            }
            toks
        })
        .collect()
}

/// A word read as a glob pattern: `*` any run of bytes, `?` any byte, a
/// bracket expression its set, and any other byte itself.
fn glob(word: &[u8]) -> Vec<Tok> {
    let mut toks = Vec::new();
    let mut i = 0;
    while i < word.len() {
        let ((set, next), kind) = match word[i] {
            b'*' => ((Set::all(), i + 1), Kind::Star),
            b'?' => ((Set::all(), i + 1), Kind::One),
            b'[' => (class(word, i, b"!^").unwrap_or((Set::of(b'['), i + 1)), Kind::One),
            c => ((Set::of(c), i + 1), Kind::One),
        };
        toks.push(Tok { set, kind });
        i = next;
    }
    toks
}

/// The set of the bracket expression at `at` and the index after it: bytes,
/// ranges and `[:name:]` classes, the whole negated by a leading byte of
/// `negators`. None when it does not close.
fn class(b: &[u8], at: usize, negators: &[u8]) -> Option<(Set, usize)> {
    let mut i = at + 1;
    let negated = b.get(i).is_some_and(|c| negators.contains(c));
    i += usize::from(negated);
    let mut set = Set::default();
    let start = i;
    loop {
        let c = *b.get(i)?;
        if c == b']' && i > start {
            break;
        }
        if c == b'[' && b.get(i + 1) == Some(&b':') {
            let end = i + 2 + b[i + 2..].windows(2).position(|w| w == b":]")?;
            set = set.or(named(&b[i + 2..end]));
            i = end + 2;
        } else if b.get(i + 1) == Some(&b'-') && b.get(i + 2).is_some_and(|&d| d != b']') {
            (c..=b[i + 2]).for_each(|x| set.add(x));
            i += 3;
        } else {
            set.add(c);
            i += 1;
        }
    }
    Some((if negated { set.not() } else { set }, i + 1))
}

/// The bytes of a `[:name:]` class; a name it does not know is every byte.
fn named(name: &[u8]) -> Set {
    let test: fn(&u8) -> bool = match name {
        b"space" => |b| is_space(*b),
        b"blank" => |b| matches!(b, b' ' | b'\t'),
        b"alpha" | b"upper" | b"lower" => u8::is_ascii_alphabetic,
        b"digit" => u8::is_ascii_digit,
        b"alnum" => u8::is_ascii_alphanumeric,
        b"xdigit" => u8::is_ascii_hexdigit,
        b"punct" => u8::is_ascii_punctuation,
        _ => return Set::all(),
    };
    (0..=255u8).filter(test).fold(Set::default(), |set, b| set.or(Set::of(b)))
}

/// The bytes a match of `toks` can start with.
fn first(toks: &[Tok]) -> Set {
    let mut set = Set::default();
    for tok in toks {
        set = set.or(tok.set);
        if tok.kind == Kind::One {
            return set;
        }
    }
    Set::all()
}

/// Whether `toks` matches all of `word`.
fn matches(word: &[u8], toks: &[Tok]) -> bool {
    if toks.len() >= 128 {
        return meet(&glob_free(word), toks);
    }
    let m = toks.len();
    // A bit for each token a match can stand before; bit `m` is the end.
    let close = |mut s: u128| {
        for (i, tok) in toks.iter().enumerate() {
            if s >> i & 1 == 1 && tok.kind != Kind::One {
                s |= 1 << (i + 1);
            }
        }
        s
    };
    let mut state = close(1);
    for &b in word {
        let mut next = 0u128;
        for (i, tok) in toks.iter().enumerate() {
            if state >> i & 1 == 1 && tok.set.has(b) {
                next |= if tok.kind == Kind::Star { 1 << i } else { 1 << (i + 1) };
            }
        }
        state = close(next);
        if state == 0 {
            return false;
        }
    }
    state >> m & 1 == 1
}

/// A word's bytes as tokens that each take that byte.
fn glob_free(word: &[u8]) -> Vec<Tok> {
    word.iter().map(|&b| Tok { set: Set::of(b), kind: Kind::One }).collect()
}

/// Whether some text matches both `a` and `b`.
fn meet(a: &[Tok], b: &[Tok]) -> bool {
    let width = b.len() + 1;
    let mut seen = vec![false; (a.len() + 1) * width];
    let mut stack = vec![(0, 0)];
    while let Some((i, j)) = stack.pop() {
        if std::mem::replace(&mut seen[i * width + j], true) {
            continue;
        }
        if i == a.len() && j == b.len() {
            return true;
        }
        let (x, y) = (a.get(i), b.get(j));
        if x.is_some_and(|t| t.kind != Kind::One) {
            stack.push((i + 1, j));
        }
        if y.is_some_and(|t| t.kind != Kind::One) {
            stack.push((i, j + 1));
        }
        if let (Some(x), Some(y)) = (x, y) {
            // Both take one byte they share. Two runs that both go on stay
            // where they are, which skipping either one answers.
            let next = (i + usize::from(x.kind != Kind::Star), j + usize::from(y.kind != Kind::Star));
            if x.set.meets(&y.set) && next != (i, j) {
                stack.push(next);
            }
        }
    }
    false
}

/// The text with each line continuation, a backslash and the newline after
/// it, dropped.
pub(super) fn continuations_joined(text: &[u8]) -> W {
    let mut out = W::with_capacity(text.len());
    let mut i = 0;
    while i < text.len() {
        if text[i] == b'\\' && text.get(i + 1) == Some(&b'\n') {
            i += 2;
            continue;
        }
        out.push(text[i]);
        i += 1;
    }
    out
}

/// The text without its quote characters, with the `$` that opens a `$'...'`
/// or `$"..."` taken as one of them. Its backslashes stay, so an escape the
/// quotes split (`'\''x70ip`) is whole again.
pub(super) fn quotes_dropped(text: &[u8]) -> W {
    let mut out = W::with_capacity(text.len());
    for (i, &b) in text.iter().enumerate() {
        let opens = b == b'$' && matches!(text.get(i + 1), Some(b'\'' | b'"'));
        if !opens && !matches!(b, b'\'' | b'"') {
            out.push(b);
        }
    }
    out
}

/// The text with each `${name-word}`, `${name:-word}` and the like (`=`, `+`
/// and `?` too, and zsh's `${:-word}` and flags) replaced by its word, the
/// value the shell gives it when the name has none.
pub(super) fn defaults_taken(text: &[u8]) -> W {
    let mut out = W::with_capacity(text.len());
    let mut i = 0;
    while i < text.len() {
        if text[i..].starts_with(b"${") {
            if let Some((word, end)) = default_word(text, i + 2) {
                out.extend_from_slice(word);
                i = end;
                continue;
            }
        }
        out.push(text[i]);
        i += 1;
    }
    out
}

/// The word of the default that opens at `at`, after its `${`, and the
/// index after its `}`.
fn default_word(text: &[u8], at: usize) -> Option<(&[u8], usize)> {
    let mut i = at;
    if text.get(i) == Some(&b'(') {
        i += text[i..].iter().position(|&b| b == b')')? + 1;
    }
    let name = text[i..].iter().take_while(|b| b.is_ascii_alphanumeric() || **b == b'_').count();
    i += if name > 0 { name } else { usize::from(matches!(text.get(i), Some(b'@' | b'*' | b'#' | b'?' | b'$' | b'!'))) };
    i += usize::from(text.get(i) == Some(&b':'));
    if !matches!(text.get(i), Some(b'-' | b'+' | b'=' | b'?')) {
        return None;
    }
    let end = closing(text, i + 1, b'{', b'}')?;
    Some((&text[i + 1..end - 1], end))
}

/// The text without its expansions: each `$(...)`, backquoted script,
/// `${...}` and `$name`. An expansion's value is decided at run time and can
/// be empty, so the bytes around it can be one word (`n$()pm`).
pub(super) fn expansions_dropped(text: &[u8]) -> W {
    let mut out = W::with_capacity(text.len());
    let mut i = 0;
    while i < text.len() {
        let end = match (text[i], text.get(i + 1)) {
            (b'$', Some(b'(')) => closing(text, i + 2, b'(', b')'),
            (b'$', Some(b'{')) => closing(text, i + 2, b'{', b'}'),
            (b'$', Some(&b)) if b.is_ascii_alphabetic() || b == b'_' => {
                Some(i + 1 + text[i + 1..].iter().take_while(|b| b.is_ascii_alphanumeric() || **b == b'_').count())
            }
            (b'$', Some(b'0'..=b'9' | b'@' | b'*' | b'#' | b'?' | b'$' | b'!' | b'-')) => Some(i + 2),
            (b'`', _) => text[i + 1..].iter().position(|&b| b == b'`').map(|n| i + n + 2),
            _ => None,
        };
        match end {
            Some(end) => i = end,
            None => {
                out.push(text[i]);
                i += 1;
            }
        }
    }
    out
}

/// The text with each group of a glob pattern written as the words it
/// matches: zsh's `(a|b)` and bash's `@(a|b)`, `?(a)`, `*(a)` and `+(a)`
/// become the brace group `{a,b}`, a group of one pattern becomes its
/// pattern (`n(p)m`, `?(n)pm`), and `!(a)` becomes `*`. A group is a pair of
/// parentheses around no blank, quote, other parenthesis or operator
/// character but `|`, that no `$`, `<`, `>` or `=` opens.
pub(super) fn glob_groups_braced(text: &[u8]) -> W {
    let pattern = |b: &u8| *b == b'|' || GLOB[usize::from(*b)] || !BREAKS[usize::from(*b)];
    let mut out = W::with_capacity(text.len());
    let mut i = 0;
    while i < text.len() {
        let prefix = matches!(text[i], b'@' | b'?' | b'*' | b'+' | b'!') && text.get(i + 1) == Some(&b'(');
        let open = i + usize::from(prefix);
        let opened = !prefix && open > 0 && matches!(text[open - 1], b'$' | b'<' | b'>' | b'=');
        let close = match text.get(open) {
            Some(b'(') if !opened => text[open + 1..].iter().position(|b| !pattern(b)).map(|n| open + 1 + n),
            _ => None,
        };
        let Some(close) = close.filter(|&c| text[c] == b')' && c > open + 1) else {
            out.push(text[i]);
            i += 1;
            continue;
        };
        let inner = &text[open + 1..close];
        match (text[i], inner.contains(&b'|')) {
            (b'!', _) => out.push(b'*'),
            (_, true) => {
                out.push(b'{');
                out.extend(inner.iter().map(|&b| if b == b'|' { b',' } else { b }));
                out.push(b'}');
            }
            (_, false) => out.extend_from_slice(inner),
        }
        i = close + 1;
    }
    out
}

/// The index after the `close` that ends what opened before `at`, counting
/// the `open` and `close` that stand outside quotes and escapes. None when
/// it does not close.
fn closing(text: &[u8], at: usize, open: u8, close: u8) -> Option<usize> {
    let (mut depth, mut i) = (1, at);
    while i < text.len() {
        match text[i] {
            b'\\' => i += 1,
            b'\'' => i += text[i + 1..].iter().position(|&b| b == b'\'')? + 1,
            b'"' => {
                i += 1;
                while *text.get(i)? != b'"' {
                    i += if text[i] == b'\\' { 2 } else { 1 };
                }
            }
            b if b == open => depth += 1,
            b if b == close => {
                depth -= 1;
                if depth == 0 {
                    return Some(i + 1);
                }
            }
            _ => {}
        }
        i += 1;
    }
    None
}

/// The text without its quote characters and backslashes.
pub(super) fn unquoted(text: &[u8]) -> W {
    quotes_dropped(text).into_iter().filter(|&b| b != b'\\').collect()
}

/// The text with each escape printf and `$'...'` expand replaced by the byte
/// it stands for: a letter escape, `\cX` and zsh's `\C-X` (the low five bits
/// of `X`), `\\`, one to three octal digits, and `\x`, `\u` or `\U` with
/// their hex digits.
/// An octal value past 255 stands for its low byte, as the shells write it
/// (`\560` is `p`). A byte past ASCII, and a
/// character `\u` or `\U` names past it, is no byte of a name, so it stands
/// as 0x80.
pub(super) fn escapes_expanded(text: &[u8]) -> W {
    escapes(text, false)
}

/// The same, read as `echo -e` and printf's `%b` read it: `\0` takes up to
/// three octal digits after it.
pub(super) fn echo_escapes_expanded(text: &[u8]) -> W {
    escapes(text, true)
}

fn escapes(text: &[u8], echo: bool) -> W {
    let mut out = W::with_capacity(text.len());
    let mut i = 0;
    while i < text.len() {
        // The bytes the escape at `i` takes, and the value it stands for.
        let number = |from: usize, max: usize, radix: u32| {
            let n = text[from..].iter().take(max).take_while(|&&b| (b as char).is_digit(radix)).count();
            let value = text[from..from + n].iter().fold(0u32, |v, &b| v * radix + (b as char).to_digit(radix).unwrap_or(0));
            (n > 0).then_some((from + n - i, value))
        };
        let escape = match text.get(i + 1) {
            _ if text[i] != b'\\' => None,
            Some(b'\\') => Some((2, u32::from(b'\\'))),
            Some(b'a') => Some((2, 0x07)),
            Some(b'b') => Some((2, 0x08)),
            Some(b'e' | b'E') => Some((2, 0x1b)),
            Some(b'f') => Some((2, 0x0c)),
            Some(b'n') => Some((2, 0x0a)),
            Some(b'r') => Some((2, 0x0d)),
            Some(b't') => Some((2, 0x09)),
            Some(b'v') => Some((2, 0x0b)),
            Some(b'c') => text.get(i + 2).map(|&b| (3, u32::from(b & 0x1f))),
            Some(b'C') if text.get(i + 2) == Some(&b'-') => text.get(i + 3).map(|&b| (4, u32::from(b & 0x1f))),
            Some(b'0') if echo => number(i + 2, 3, 8).map(|(len, v)| (len, v & 0xff)).or(Some((2, 0))),
            Some(b'0'..=b'7') => number(i + 1, 3, 8).map(|(len, v)| (len, v & 0xff)),
            Some(b'x') => number(i + 2, 2, 16),
            Some(b'u') => number(i + 2, 4, 16),
            Some(b'U') => number(i + 2, 8, 16),
            _ => None,
        };
        match escape {
            Some((len, value)) => {
                out.push(if value < 0x80 { value as u8 } else { 0x80 });
                i += len;
            }
            None => {
                out.push(text[i]);
                i += 1;
            }
        }
    }
    out
}
