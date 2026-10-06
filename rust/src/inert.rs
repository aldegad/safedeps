//! The inert rewrite and its record: `--ignore-scripts` for every npm install
//! the shell runs, and whether the command holds an install the rewrite did
//! not read. Not written yet; `rewrite_in_place` says so.
//!
//! # The reader
//!
//! A reader reads the top level of the text it is given, and nothing else.
//! Text nested in it is a payload, read by asking the same question of the
//! payload:
//!
//! ```text
//! places(text):
//!   for each statement of text's top level (Run::pieces) whose command word
//!   is npm and whose reading (manager::Reader) is an install:
//!       the places for its flag, among the ends of its words
//!   for each payload of text (Run::payloads):
//!       places(payload.text), each carried back through payload.src
//! ```
//!
//! The lexer says where a statement starts and ends, which word is the
//! command, where each word stands and what a `}` closes. No reader here
//! looks for a verb or an end in a view's bytes. The bash rewrite did
//! (`inert_verb_ends` greps the live view, the end finder counts depth and
//! backticks there again, `inert_nested_verb_ends` and `inert_payload_spans`
//! patch what that misses), and each of its three rejected defects was that
//! reader reading a nested text with the outer level's quoting. Those four
//! functions are not ported.
//!
//! A place in a payload is a place in the command only through `src`. A byte
//! the lexer decoded has no source byte (`None`); a flag that would stand
//! after one is not placed, and the install is one whose flag nobody read.
//! Text with no map at all (a script handed to another shell, a heredoc body
//! piped on) keeps the flag where v2.17.2 put it, and the unread record.
//!
//! # What is ported as it is
//!
//! These are not the reader, and they keep their rules:
//!
//! - `inert_statement_reads`: a place stands only when the statement, read
//!   with the flag there by npm's own tables (`Reader::npm_inert_reading`),
//!   leaves ignore-scripts true and reads the same otherwise.
//! - The places tried: from the last argument back to the verb, and the
//!   floor right after the verb, always.
//! - `inert_release_skips` and `inert_release_appends`: the release's own
//!   rewrite (7d66f8c), which every rewrite holds.
//! - `shell_expands`: the allow-list of bytes no shell expansion acts on.
//! - `inert_bytes_left_unread`: the record, an allow-list over the command's
//!   bytes through three levels of quote removal. It reads no structure, so
//!   it stands when the reader is wrong.
//! - `inert_dynamic_command_word`.
//!
//! # Differences from the bash rewrite
//!
//! The bash guard is the reference where this reads the same. Where it does
//! not, the difference has a name in
//! `scripts/measure/core-intended-inert.tsv`, and three rules hold:
//!
//! 1. It adds a flag, adds a record, or turns a pass into `UNDECIDED`. A
//!    difference that drops a flag or a record has no name; it is a defect.
//! 2. Its evidence is what the shells hand npm: the argv of a stand-in npm
//!    under bash, zsh and dash, beside both answers.
//! 3. A text with no payload reads as the bash rewrite reads it, but for one
//!    class: a `}` after a line continuation.
//!
//! # Where the shell's plumbing decides a bash result
//!
//! For the parts ported as they are, and for reading a difference:
//!
//! - `$(shell_lex ...)` drops the newlines that end a view. Offsets do not
//!   move; a comparison of two views' lengths does.
//! - The awk programs read each view from a file with `slurp`, which drops
//!   one newline at the end of the file.
//! - `grep -ob` prints every match of a line, each the longest from the
//!   leftmost start, the next one searched after the last. The option
//!   grammar can carry a match past the first verb (`npm --x install i`).
//! - Offsets are bytes (`grep -b`, awk under `LC_ALL=C`), and
//!   `${text:start:len}` in `inert_flag_offsets` counts characters in the
//!   hook's locale. Under a UTF-8 locale a multibyte character before a
//!   statement moves the statement the bash rewrite reads.
//!   `inert_nested_verb_ends` sets `LC_ALL=C` itself and reads bytes.
//! - The pieces view writes \002 for an empty word and for a blank, a
//!   parenthesis or a brace inside a word, and its readers turn \002 into a
//!   space: `WordSpan::folded` is that spelling, `WordSpan::value` the bytes.
//! - `inert_statement_reads` tests the words for a `--` before it asks
//!   whether the statement is dynamic, and a caller reads `INERT_READ_ENDS`
//!   first.
//! - The offsets are sorted and made unique before the flags go in, and the
//!   release's end flag is the one at the command's last byte when a place
//!   already stands there.
//! - `inert_bytes_left_unread` hides the three bytes of each `npm` the
//!   rewrite read, blanks the command's own comments, and searches without a
//!   left boundary and without case.

use crate::core::Run;

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
    /// This module is not written yet.
    NotYet,
}

/// `inert_rewrite_in_place <command>`, in the run's reading.
pub fn rewrite_in_place(_run: &mut Run, _command: &[u8]) -> Result<Rewrite, Failed> {
    Err(Failed::NotYet)
}

/// `safedeps-core inert`: the rewrite of one hook payload (stdin) in each
/// reading, as records, for the comparison.
pub fn cli(_input: &[u8]) -> i32 {
    eprintln!("safedeps-core inert: not written yet");
    2
}
