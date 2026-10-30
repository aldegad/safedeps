//! Where a word of a CLI shell file is code, for the tests that hold a
//! declared name to its declaration. A list of the forms a spelling can take
//! keeps missing one, so these readings list what is allowed and read every
//! shape they do not know as code. A declared word may stand as prose only
//! in three places, each a whole line of one shape: a comment line, a line
//! of the body of a heredoc opened by a line that is exactly `cat <<WORD`
//! inside the help function `cmd_help`, and the quoted strings of a line
//! that is one message call and runs nothing else. Where such text expands,
//! every expansion only reads a variable (`reads_only`). A declared name
//! stands only in its declaration and as a whole read, wherever it is
//! written, quotes included.
//!
//! Prose is the text the CLI leaves as written: comments, log lines and
//! what it prints for a person. A line is taken as prose from its shape,
//! which does not prove that no code reads it back: an `advisory.log` line
//! is evidence `sf_ledger_has_approval_provenance` reads, any output can be
//! captured, and so can a function that runs the help. A word that code
//! reads back from such text is out of reach of these readings.
//!
//! These readings catch a second truth written plainly in code. A form
//! built to hide one is out of reach of a reading of the text, line by
//! line: a name or word built at run time (`eval`, `${!x}`, `declare -n`, a
//! word split across quotes or pieced together), a pattern that matches a
//! word without spelling it, a line joined to the next by a backslash, a
//! line of a heredoc body or of a multi-line quoted text read as a line of
//! its own, and a command prefix this reading does not know in front of
//! `source`. Reading the files with the core's lexer would close the
//! quoting part of that list; these readings do not.

/// The CLI and every file it sources: the files these tests read.
/// `cli_files_are_what_the_cli_sources` closes the set.
pub const CLI_FILES: [(&str, &str); 9] = [
    ("bin/safedeps", include_str!("../../bin/safedeps")),
    ("lib/providers/providers.sh", include_str!("../../lib/providers/providers.sh")),
    ("lib/truth-sources.sh", include_str!("../../lib/truth-sources.sh")),
    ("lib/advisory-log-rotate.sh", include_str!("../../lib/advisory-log-rotate.sh")),
    ("lib/ledger/ledger.sh", include_str!("../../lib/ledger/ledger.sh")),
    ("lib/ledger/context-kinds.sh", include_str!("../../lib/ledger/context-kinds.sh")),
    ("lib/ledger/recheck-report.sh", include_str!("../../lib/ledger/recheck-report.sh")),
    ("lib/npm/closure.sh", include_str!("../../lib/npm/closure.sh")),
    ("lib/npm/ask.sh", include_str!("../../lib/npm/ask.sh")),
];

/// The functions and commands whose quoted arguments these readings take as
/// prose: log lines and text printed for a person. `echo`, and `printf` with
/// a quoted format, count only when the line sends them to stderr, since on
/// stdout they are how a shell function returns a value. That code may read
/// such text back is out of reach (see the module doc).
const MESSAGES: [&str; 8] = ["sf_advisory_log", "sf_eprintf", "sf_err", "sf_info", "sf_ok", "sf_spinner_start", "sf_warn", "safedeps_provider_log"];

/// The functions whose `cat` heredocs are the help text.
/// `help_runs_only_in_its_known_forms` holds how they are run; a caller
/// that captures a function which runs one is out of reach. A heredoc
/// anywhere else may be captured.
const HELP: [&str; 1] = ["cmd_help"];

/// The bytes of a word in a name or a status.
pub fn word(b: u8) -> bool { b.is_ascii_alphanumeric() || b == b'_' }

/// Each line of `text` that is code, with what it holds as prose blanked:
/// comment lines and the help text are left out, and a message line keeps
/// only what stands outside its quoted strings.
fn code(text: &str) -> impl Iterator<Item = (&str, Vec<u8>)> {
    let mut heredoc: Option<(&str, bool)> = None;
    let mut help = false;
    text.lines().filter_map(move |line| {
        if let Some((end, quoted)) = heredoc {
            if line.trim_start_matches('\t') == end { heredoc = None; return None }
            // An unquoted delimiter expands the body, so a line that does
            // more than read a variable is code.
            return (!quoted && !reads_only(line)).then(|| (line, line.as_bytes().to_vec()));
        }
        let code = line.trim_start();
        if code.starts_with('#') { return None }
        // A help function ends at its closing brace or where any other
        // function begins, so a brace written another way cannot carry it on.
        if let Some(name) = opens_function(code) { help = HELP.contains(&name) } else if line == "}" { help = false }
        heredoc = if help { cat_heredoc(code) } else { None };
        Some((line, message(code).unwrap_or_else(|| code.as_bytes().to_vec())))
    })
}

/// Where `name` stands whole in `scanned`, a line `part` says the bytes of a
/// word of.
fn stands(scanned: &[u8], name: &str, part: fn(u8) -> bool) -> Vec<usize> {
    scanned.windows(name.len()).enumerate().filter(|(at, w)| *w == name.as_bytes()
        && (*at == 0 || !part(scanned[at - 1])) && scanned.get(at + name.len()).is_none_or(|b| !part(*b))).map(|(at, _)| at).collect()
}

/// The lines of `text` where `word` stands whole in code. `part` says which
/// bytes continue a word, so `fixture` inside `safedeps_npm_fixture_closure`
/// is not one.
pub fn code_lines<'a>(text: &'a str, word: &str, part: fn(u8) -> bool) -> Vec<&'a str> {
    code(text).filter(|(_, scanned)| !stands(scanned, word, part).is_empty()).map(|(line, _)| line).collect()
}

/// The lines of `text` where the shell name `name` stands in code other than
/// as a whole read, `${name}` or an array's `${name[*]}` and `${name[@]}`.
/// The line is read as written, quoted strings included, and a name glued
/// to what comes before it (`printf -vNAME`) still counts. Every assignment,
/// in whatever form, is one of these lines.
pub fn bare_uses<'a>(text: &'a str, name: &str) -> Vec<&'a str> {
    code(text).filter(|(line, _)| {
        let mut rest = line.to_string();
        for read in [format!("${{{name}}}"), format!("${{{name}[*]}}"), format!("${{{name}[@]}}")] { rest = rest.replace(&read, " ") }
        rest.match_indices(name).any(|(at, _)| rest.as_bytes().get(at + name.len()).is_none_or(|b| !word(*b)))
    }).map(|(line, _)| line).collect()
}

/// The lines of `text` that define `name`: a shell function by `name()`,
/// `name ()` or `function name`, a jq function by `def name`. These are the
/// grammars' own forms, and there are no others.
pub fn definitions<'a>(text: &'a str, name: &str) -> Vec<&'a str> {
    code(text).filter(|(_, scanned)| stands(scanned, name, word).into_iter().any(|at| {
        let before = String::from_utf8_lossy(&scanned[..at]);
        let after = String::from_utf8_lossy(&scanned[at + name.len()..]);
        let before = before.trim_end();
        let keyword = |k: &str| before.strip_suffix(k).is_some_and(|b| b.bytes().last().is_none_or(|c| !word(c)));
        keyword("function") || keyword("def") || after.trim_start().strip_prefix('(').is_some_and(|a| a.trim_start().starts_with(')'))
    })).map(|(line, _)| line).collect()
}

/// The function a line begins to define, by the shell's own forms:
/// `name()`, `name ()` and `function name`.
fn opens_function(code: &str) -> Option<&str> {
    let (keyword, rest) = match code.strip_prefix("function ") { Some(rest) => (true, rest.trim_start()), None => (false, code) };
    let end = rest.find(|c: char| !(c.is_ascii_alphanumeric() || c == '_')).unwrap_or(rest.len());
    let parens = rest[end..].trim_start().strip_prefix('(').is_some_and(|after| after.trim_start().starts_with(')'));
    (end > 0 && (keyword || parens)).then(|| &rest[..end])
}

/// The delimiter of the heredoc this line opens when the line is that `cat`
/// and nothing else, so the body goes to the terminal, and whether it is
/// quoted, so the body goes as it is. A body that is piped, captured or read
/// by another command is code.
fn cat_heredoc(code: &str) -> Option<(&str, bool)> {
    let rest = code.trim_end().strip_prefix("cat <<")?;
    let rest = rest.strip_prefix('-').unwrap_or(rest);
    let quoted = rest.strip_prefix('\'').and_then(|r| r.strip_suffix('\''))
        .or_else(|| rest.strip_prefix('"').and_then(|r| r.strip_suffix('"')));
    let word = quoted.unwrap_or(rest);
    (!word.is_empty() && word.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_')).then_some((word, quoted.is_some()))
}

/// Whether every expansion in `text` only reads a variable: `$NAME`,
/// `${NAME}`, `${#NAME}`, `${NAME:-WORD}` with a plain word, or a positional
/// or special parameter. Anything else a `$` or a backquote begins may run a
/// command or assign (a substitution, arithmetic, a subscript, `:=`), so text
/// that holds one is not prose.
fn reads_only(text: &str) -> bool {
    let name = |n: &str| n.bytes().next().is_some_and(|b| b.is_ascii_alphabetic() || b == b'_') && n.bytes().all(word);
    let b = text.as_bytes();
    if b.contains(&b'`') { return false }
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            b'\\' => { i += 2; continue }
            b'$' => {}
            _ => { i += 1; continue }
        }
        let rest = &text[i + 1..];
        i += 1 + if let Some(inner) = rest.strip_prefix('{') {
            let Some(end) = inner.find('}') else { return false };
            let read = &inner[..end];
            let read = read.strip_prefix('#').unwrap_or(read);
            let (variable, default) = read.split_once(":-").map_or((read, None), |(v, d)| (v, Some(d)));
            let plain = default.is_none_or(|d| d.bytes().all(|c| c.is_ascii_alphanumeric() || b"_./ -".contains(&c)));
            if !((name(variable) || (variable.len() == 1 && variable.as_bytes()[0].is_ascii_digit())) && plain) { return false }
            end + 2
        } else {
            match rest.bytes().next() {
                None | Some(b' ' | b'"' | b'\'') => 0,
                Some(c) if c.is_ascii_digit() || b"@*#?$!-".contains(&c) => 1,
                Some(c) if c.is_ascii_alphabetic() || c == b'_' => rest.bytes().take_while(|c| word(*c)).count(),
                Some(_) => return false,
            }
        };
    }
    true
}

/// A message line with its quoted strings blanked, when the line is one call
/// of a message command and runs nothing else: outside its quoted strings it
/// holds no `;`, `&`, `|`, redirection, subshell or substitution (a printf or
/// echo ends in its one `>&2`, and a printf does not assign with `-v`), and
/// no quoted string of it runs a command or assigns. Any other line is None,
/// and code.
fn message(code: &str) -> Option<Vec<u8>> {
    let first = code.split_whitespace().next()?;
    let call = if MESSAGES.contains(&first) { code.trim_end() }
        else if first == "echo" || (first == "printf" && code.split_whitespace().nth(1).is_some_and(|f| f.starts_with(['\'', '"']))) { code.trim_end().strip_suffix(">&2")? }
        else { return None };
    let blanked = unquoted(call)?;
    (!blanked.iter().any(|b| matches!(b, b';' | b'&' | b'|' | b'<' | b'>' | b'(' | b')' | b'`' | b'$'))).then_some(blanked)
}

/// The line with each quoted string blanked out, or None when a quoted
/// string is not text: a double-quoted one with an expansion that does more
/// than read a variable, or a quote left open.
fn unquoted(code: &str) -> Option<Vec<u8>> {
    let mut out = code.as_bytes().to_vec();
    let mut i = 0;
    while i < out.len() {
        let quote = out[i];
        if quote == b'\\' {
            // Outside quotes a backslash makes the next byte literal, so it
            // opens no quote.
            i += 2;
        } else if quote == b'\'' || quote == b'"' {
            let mut j = i + 1;
            while j < out.len() && out[j] != quote {
                if quote == b'"' && out[j] == b'\\' { j += 1 }
                j += 1;
            }
            if j >= out.len() { return None }
            if quote == b'"' && !reads_only(&code[i + 1..j]) { return None }
            for b in &mut out[i..=j] { *b = b' ' }
            i = j + 1;
        } else {
            i += 1;
        }
    }
    Some(out)
}

/// The shell's operators, longest first: the control and redirection
/// operators of bash(1) and the three that open a command inside a word.
const OPERATORS: [&str; 26] = [";;&", "<<<", "<<-", "&>>", ";;", ";&", "||", "&&", "|&", "<<", ">>", "<&", ">&", "<>", ">|", "&>",
    "<(", ">(", "$(", "|", "&", ";", "(", ")", "<", ">"];

/// The words and operators of a line whose quoted text is masked, split as
/// the shell splits them: at blanks and at its operators, longest first. A
/// backslash keeps the next byte in the word, `${...}` and `$((...))` stay in
/// theirs, and digits right before a redirection are part of it.
fn shell_tokens(masked: &[u8]) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let mut cur = String::new();
    let mut i = 0;
    let closing = |from: usize, open: u8, close: u8| {
        let mut depth = 0;
        (from..masked.len()).find(|&j| { if masked[j] == open { depth += 1 } else if masked[j] == close { depth -= 1 } depth == 0 }).map_or(masked.len(), |j| j + 1)
    };
    while i < masked.len() {
        let c = masked[i];
        let rest = &masked[i..];
        if c == b'\\' {
            cur.extend(rest.iter().take(2).map(|&b| b as char));
            i += 2;
        } else if c == b' ' || c == b'\t' {
            if !cur.is_empty() { out.push(std::mem::take(&mut cur)) }
            i += 1;
        } else if rest.starts_with(b"${") || rest.starts_with(b"$((") {
            let end = if rest[1] == b'{' { closing(i + 1, b'{', b'}') } else { closing(i + 1, b'(', b')') };
            cur.extend(masked[i..end].iter().map(|&b| b as char));
            i = end;
        } else if c == b'`' {
            if !cur.is_empty() { out.push(std::mem::take(&mut cur)) }
            out.push("`".into());
            i += 1;
        } else if let Some(op) = OPERATORS.iter().find(|op| rest.starts_with(op.as_bytes())) {
            let io = op.starts_with(['<', '>']) && !op.ends_with('(') && !cur.is_empty() && cur.bytes().all(|d| d.is_ascii_digit());
            if io { let n = std::mem::take(&mut cur); out.push(n + op) } else {
                if !cur.is_empty() { out.push(std::mem::take(&mut cur)) }
                out.push(op.to_string());
            }
            i += op.len();
        } else {
            cur.push(c as char);
            i += 1;
        }
    }
    if !cur.is_empty() { out.push(cur) }
    out
}

/// The line with what its quoted strings hold masked, read the way the shell
/// quotes: a backslash outside single quotes keeps the next byte, `$'...'`
/// reads backslashes, and a command substitution or a backquoted text inside
/// double quotes is code again, so it is masked only where it quotes. The
/// quote marks stay. A quote the line leaves open is not masked, so what
/// follows it is read as code.
fn mask_quotes(code: &[u8]) -> Vec<u8> {
    let mut out = code.to_vec();
    let mut i = 0;
    while i < code.len() {
        match code[i] {
            b'\\' => i += 2,
            b'\'' => match single_end(code, i) {
                Some(j) => { out[i + 1..j].fill(b'x'); i = j + 1 }
                None => i += 1,
            },
            b'"' => match double_end(code, i + 1) {
                Some((j, spans)) => {
                    out[i + 1..j].fill(b'x');
                    for (s, e) in spans { out[s..e].copy_from_slice(&mask_quotes(&code[s..e])) }
                    i = j + 1;
                }
                None => i += 1,
            },
            _ => i += 1,
        }
    }
    out
}

/// Where the single-quoted text opened at `at` closes; `$'...'` reads a
/// backslash as keeping the next byte.
fn single_end(code: &[u8], at: usize) -> Option<usize> {
    let ansi = at > 0 && code[at - 1] == b'$';
    let mut j = at + 1;
    while j < code.len() && code[j] != b'\'' { j += if ansi && code[j] == b'\\' { 2 } else { 1 } }
    (j < code.len()).then_some(j)
}

/// Where the double-quoted text that starts at `from` closes, and the spans
/// in it that are code: each `$(...)` and each backquoted text.
fn double_end(code: &[u8], from: usize) -> Option<(usize, Vec<(usize, usize)>)> {
    let mut spans = Vec::new();
    let mut j = from;
    while j < code.len() {
        match code[j] {
            b'\\' => j += 2,
            b'"' => return Some((j, spans)),
            b'$' if code[j + 1..].starts_with(b"(") && !code[j + 1..].starts_with(b"((") => {
                let e = substitution_end(code, j + 2)?;
                spans.push((j, e + 1));
                j = e + 1;
            }
            b'`' => {
                let e = (j + 1..code.len()).find(|&k| code[k] == b'`' && code[k - 1] != b'\\')?;
                spans.push((j, e + 1));
                j = e + 1;
            }
            _ => j += 1,
        }
    }
    None
}

/// Where the command substitution whose text starts at `from` closes.
fn substitution_end(code: &[u8], from: usize) -> Option<usize> {
    let mut depth = 0;
    let mut j = from;
    while j < code.len() {
        match code[j] {
            b'\\' => j += 2,
            b'\'' => j = single_end(code, j)? + 1,
            b'"' => j = double_end(code, j + 1)?.0 + 1,
            b'(' => { depth += 1; j += 1 }
            b')' if depth == 0 => return Some(j),
            b')' => { depth -= 1; j += 1 }
            _ => j += 1,
        }
    }
    None
}

/// How many commands of this line source a file: `source`, or `.` followed by
/// a word that can be a path, where a command begins. A command begins at the
/// line's start, after a control operator, `(`, `$(`, `<(`, `>(` or a
/// backquote, after a reserved word a command follows, after `builtin` or
/// `command` and the options they take, and after an assignment
/// (`NAME=`, `NAME+=`, `NAME[...]=`) or a redirection with its word that
/// begins one. A command substitution counts wherever it stands. A `.`
/// before an operator or a word jq reserves is jq's, the way a line inside a
/// multi-line jq program reads.
fn source_commands(code: &str) -> usize {
    // What a quoted string holds is no command word; the quotes stay, so a
    // quoted path still follows its `.`.
    let masked = mask_quotes(code.as_bytes());
    // The commands a `$(...)` or a backquoted text runs, wherever it stands,
    // quotes included: the mask hides them in a double-quoted string.
    let b = code.as_bytes();
    let mut inner = 0;
    let mut at = 0;
    while at < b.len() {
        if b[at..].starts_with(b"$(") && !b[at..].starts_with(b"$((") {
            let mut depth = 0;
            let end = (at + 1..b.len()).find(|&j| { if b[j] == b'(' { depth += 1 } else if b[j] == b')' { depth -= 1 } depth == 0 }).unwrap_or(b.len());
            inner += source_commands(&code[at + 2..end.min(b.len())]);
            at = end + 1;
        } else if b[at] == b'`' {
            let end = (at + 1..b.len()).find(|&j| b[j] == b'`').unwrap_or(b.len());
            inner += source_commands(&code[at + 1..end]);
            at = end + 1;
        } else {
            at += 1;
        }
    }
    let tokens = shell_tokens(&masked);
    const JQ: [&str; 16] = ["as", "and", "or", "if", "then", "elif", "else", "end", "reduce", "foreach", "def", "try", "catch", "label", "import", "include"];
    let path = |w: &str| w == "--" || w == "<(" || (w.starts_with(|c: char| c.is_ascii_alphanumeric() || "\"'$/~._".contains(c)) && !JQ.contains(&w));
    let redirection = |w: &str| ["<<<", "<<-", "&>>", "<<", ">>", "<&", ">&", "<>", ">|", "&>", "<", ">"].contains(&w.trim_start_matches(|c: char| c.is_ascii_digit()));
    let control = |w: &str| [";;&", ";;", ";&", "||", "&&", "|&", "|", "&", ";", "(", ")", "$(", "<(", ">(", "`"].contains(&w);
    let assignment = |w: &str| w.split_once('=').is_some_and(|(n, _)| {
        let n = n.strip_suffix('+').unwrap_or(n);
        let n = n.strip_suffix(']').and_then(|n| n.split_once('[')).map_or(n, |(n, _)| n);
        !n.is_empty() && n.bytes().all(word) && !n.as_bytes()[0].is_ascii_digit()
    });
    let mut command = true;
    let mut target = false;
    let mut options = false;
    let mut found = 0;
    for (i, w) in tokens.iter().map(String::as_str).enumerate() {
        if target { target = false; continue }
        if redirection(w) { target = true; continue }
        if options && w.starts_with('-') { continue }
        if command && (w == "source" || (w == "." && tokens.get(i + 1).is_some_and(|next| path(next)))) { found += 1 }
        options = command && ["builtin", "command", "time"].contains(&w);
        command = control(w) || ["then", "do", "else", "elif", "if", "while", "until", "time", "builtin", "command", "{", "!"].contains(&w)
            || (command && assignment(w));
    }
    found + inner
}

/// The repo path a line of `file` sources, None when it sources nothing, and
/// Some(None) when it sources something this reading cannot place: a target
/// with a prefix it does not know, or a source command that is not the whole
/// line `source "TARGET"` or `. "TARGET"`.
fn sourced(file: &str, line: &str) -> Option<Option<String>> {
    let commands = source_commands(line);
    if commands == 0 { return None }
    let code = line.trim();
    let target = code.strip_prefix("source \"").or_else(|| code.strip_prefix(". \"")).and_then(|t| t.strip_suffix('"'))
        .filter(|_| commands == 1);
    let dir = file.rsplit_once('/').map_or("", |(d, _)| d);
    let path = target.and_then(|t| t.strip_prefix("${SAFEDEPS_REPO_DIR}/").map(str::to_string)
        .or_else(|| t.strip_prefix("${safedeps_lib_dir}/").or_else(|| t.strip_prefix("${BASH_SOURCE[0]%/*}/")).map(|r| format!("{dir}/{r}")))
        .or_else(|| t.strip_prefix("$(cd \"$(dirname \"${BASH_SOURCE[0]}\")/..\" && pwd)/").map(|r| format!("{dir}/../{r}"))));
    Some(path.and_then(|path| {
        let mut parts: Vec<&str> = Vec::new();
        for part in path.split('/') {
            match part { ".." => { parts.pop()?; } "." | "" => {} part => parts.push(part) }
        }
        Some(parts.join("/"))
    }))
}

#[test]
fn cli_files_are_what_the_cli_sources() {
    let mut read = 0;
    for (file, text) in CLI_FILES {
        for (line, _) in code(text) {
            let Some(target) = sourced(file, line) else { continue };
            read += 1;
            let target = target.unwrap_or_else(|| panic!("{file} sources a path this test cannot place: {line}"));
            assert!(CLI_FILES.iter().any(|(other, _)| *other == target), "{file} sources {target}, which these tests read too");
            // A file that names its own directory safedeps_lib_dir sets it
            // to that directory and to nothing else, on the lines right
            // before this one, and nothing before them can skip them: only
            // blank lines, `set -euo pipefail` and plain assignments come
            // first.
            if line.contains("${safedeps_lib_dir}/") {
                let set = ["safedeps_lib_dir=\"${BASH_SOURCE[0]%/*}\"", "[[ \"${safedeps_lib_dir}\" != \"${BASH_SOURCE[0]}\" ]] || safedeps_lib_dir=."];
                assert_eq!(bare_uses(text, "safedeps_lib_dir"), [set[0], set[1], "unset safedeps_lib_dir"], "{file} sets safedeps_lib_dir to its own directory");
                let lines: Vec<&str> = code(text).map(|(l, _)| l).collect();
                let at = lines.iter().position(|l| *l == set[0]).unwrap();
                assert_eq!(lines[at..at + 4], [set[0], set[1], line, "unset safedeps_lib_dir"], "{file} sources right after it sets safedeps_lib_dir");
                assert!(lines[..at].iter().all(|l| runs_first(l)), "{file} runs only plain lines before it sets safedeps_lib_dir");
            }
        }
    }
    assert_eq!(read, 9, "the CLI's source lines");
    assert_eq!(sourced("lib/x/a.sh", ". \"${BASH_SOURCE[0]%/*}/../b.sh\""), Some(Some("lib/b.sh".into())));
    for unplaced in ["source \"${HOME}/b.sh\"", "source b.sh", ". ./b.sh", "[[ -r x ]] && source \"${SAFEDEPS_REPO_DIR}/b.sh\"",
                     "builtin source \"${SAFEDEPS_REPO_DIR}/b.sh\"", "source\t\"${SAFEDEPS_REPO_DIR}/b.sh\"", "if source \"x\"; then :; fi",
                     "x=1 . \"${SAFEDEPS_REPO_DIR}/b.sh\"", "a; source \"${SAFEDEPS_REPO_DIR}/b.sh\"", "2>/dev/null source \"x\"",
                     "> /dev/null . \"x\"", ". -- \"${SAFEDEPS_REPO_DIR}/b.sh\"", "{ source \"x\"; }", "$(source x)",
                     ">&2 source \"x\"", "2>&1 . \"x\"", ". <(cat x)", "x=\"$(source x; echo 1)\"", "y=`. ./b.sh`", "if ! source x; then :; fi",
                     "<&0 source \"x\"", ">&- source \"x\"", ">|/dev/null source \"x\"", "echo \\\" >/dev/null; source \"x\"",
                     "printf $'it\\'s\\n' >/dev/null; source \"x\"", "x=\"$(printf '%s\"' a)\"; source \"x\"", "x=\\' source \"x\"",
                     "x+=1 source \"x\"", "a[0]=1 source \"x\"", "builtin -- source \"x\"", "command -p source \"x\""] {
        assert_eq!(sourced("lib/x/a.sh", unplaced), Some(None), "{unplaced}");
    }
    for none in ["      . + {type: $type}", "jq -r . \"$f\"", "--slurpfile source \"$f\"", "x=. y", "safedeps_lib_dir=.",
                 "| jq -r 'if type==\"array\" then .[-1] elif type==\"string\" then . else empty end'", "sf_info \"a; source b\"",
                 "    | . as $entry", "    | if type == \"object\" then . else {} end"] {
        assert_eq!(sourced("lib/x/a.sh", none), None, "{none}");
    }
}

/// No line captures the help function: it is defined once, and every other
/// mention runs it in one of the forms the main dispatch and the
/// subcommands use. What a caller of such a line does with the output is
/// out of reach of this reading.
#[test]
fn help_runs_only_in_its_known_forms() {
    for name in HELP {
        let mut defined = 0;
        for (file, text) in CLI_FILES {
            for (line, _) in code(text) {
                if stands(line.as_bytes(), name, word).is_empty() { continue }
                let words = line.split_whitespace().collect::<Vec<_>>().join(" ");
                let topic = words.strip_prefix(&format!("-h|--help) {name} ")).and_then(|w| w.strip_suffix("; return 0 ;;"));
                if words == format!("{name}() {{") { defined += 1; continue }
                assert!(words == *name || words == format!("help) {name} \"$@\" ;;")
                    || topic.is_some_and(|t| !t.is_empty() && t.bytes().all(|b| b.is_ascii_lowercase() || b == b'-')),
                    "{file} runs {name} in a way this test does not know, or reads what it prints: {line}");
            }
        }
        assert_eq!(defined, 1, "{name} is defined once");
    }
}

/// The check results are declared in bin/safedeps, and their names stand in
/// the CLI files only there and as whole reads. A report is assembled in
/// bin/safedeps alone: no other CLI file names a check result, calls an
/// assembler or writes the word `result` in code.
#[test]
fn check_results_stand_only_in_their_declarations() {
    for (file, text) in &CLI_FILES[1..] {
        for (line, scanned) in code(text) {
            let scanned = String::from_utf8_lossy(&scanned);
            assert!(!line.contains("SAFEDEPS_CHECK_") && ["sf_check_json", "sf_npm_emit_closure_block_json", "result"].iter()
                .all(|w| stands(scanned.as_bytes(), w, word).is_empty()), "{file} names a check result or assembles a report outside bin/safedeps: {line}");
        }
    }
    let bin = CLI_FILES[0].1;
    let declared: Vec<&str> = bin.lines().filter(|line| line.starts_with("SAFEDEPS_CHECK_")).collect();
    assert_eq!(declared.len(), 9, "the check results: {declared:?}");
    for line in &declared {
        let name = line.split_once('=').unwrap().0;
        let uses: Vec<&str> = CLI_FILES.iter().flat_map(|(_, text)| bare_uses(text, name)).collect();
        assert_eq!(uses, [*line], "{name} stands only in its declaration and as a whole read");
        // A value is a word of its own too, so it stands in code only in its
        // declaration. `clean` is a status word, held where the statuses are,
        // and `error` also names a report field, so neither is read here.
        let value = line.split_once('=').unwrap().1.trim_matches('"');
        if ["clean", "error"].contains(&value) { continue }
        let spelled: Vec<&str> = CLI_FILES.iter().flat_map(|(_, text)| code_lines(text, value, word)).collect();
        assert_eq!(spelled, [*line], "the check result {value} is spelled in code only in its declaration");
    }
}

/// Whether a line can stand before a file's bootstrap without deciding
/// whether the bootstrap runs: a blank line, `set -euo pipefail` or an
/// assignment of a plain double-quoted value to an upper-case name.
fn runs_first(line: &str) -> bool {
    line.is_empty() || line == "set -euo pipefail" || line.split_once("=\"").is_some_and(|(n, v)| n.bytes().all(|b| b.is_ascii_uppercase() || b.is_ascii_digit() || b == b'_')
        && v.ends_with('"') && !v.bytes().any(|b| b";&|()`<>".contains(&b)))
}

/// The CLI finds its own files from the path it runs from, and from nothing
/// a caller sets: the names that hold that path are assigned only on these
/// lines, which derive it from `${BASH_SOURCE[0]}`, and read whole anywhere
/// else. The lines are one block at the top of `bin/safedeps`, and only
/// lines that cannot skip it come before it. So every target written under
/// `${SAFEDEPS_REPO_DIR}/` is a path in the repository.
#[test]
fn the_repo_dir_comes_from_the_script() {
    let bootstrap = ["SAFEDEPS_SOURCE=\"${BASH_SOURCE[0]}\"", "while [[ -h \"${SAFEDEPS_SOURCE}\" ]]; do",
        "  SAFEDEPS_BIN_DIR=$(cd -P \"$(dirname \"${SAFEDEPS_SOURCE}\")\" && pwd)", "  SAFEDEPS_SOURCE=$(readlink \"${SAFEDEPS_SOURCE}\")",
        "  [[ \"${SAFEDEPS_SOURCE}\" != /* ]] && SAFEDEPS_SOURCE=\"${SAFEDEPS_BIN_DIR}/${SAFEDEPS_SOURCE}\"", "done",
        "SAFEDEPS_BIN_DIR=$(cd -P \"$(dirname \"${SAFEDEPS_SOURCE}\")\" && pwd)", "SAFEDEPS_REPO_DIR=$(cd -P \"${SAFEDEPS_BIN_DIR}/..\" && pwd)"];
    let lines: Vec<&str> = code(CLI_FILES[0].1).map(|(l, _)| l).collect();
    let at = lines.iter().position(|l| *l == bootstrap[0]).expect("bin/safedeps derives its path");
    assert_eq!(lines[at..at + bootstrap.len()], bootstrap, "bin/safedeps derives its path in one block");
    assert!(lines[..at].iter().all(|l| runs_first(l)), "bin/safedeps runs only plain lines before it derives its path");
    let lines = |name| CLI_FILES.iter().flat_map(|(_, text)| bare_uses(text, name)).collect::<Vec<_>>();
    assert_eq!(lines("SAFEDEPS_SOURCE"), ["SAFEDEPS_SOURCE=\"${BASH_SOURCE[0]}\"", "  SAFEDEPS_SOURCE=$(readlink \"${SAFEDEPS_SOURCE}\")",
        "  [[ \"${SAFEDEPS_SOURCE}\" != /* ]] && SAFEDEPS_SOURCE=\"${SAFEDEPS_BIN_DIR}/${SAFEDEPS_SOURCE}\""]);
    assert_eq!(lines("SAFEDEPS_BIN_DIR"), ["  SAFEDEPS_BIN_DIR=$(cd -P \"$(dirname \"${SAFEDEPS_SOURCE}\")\" && pwd)",
        "SAFEDEPS_BIN_DIR=$(cd -P \"$(dirname \"${SAFEDEPS_SOURCE}\")\" && pwd)"]);
    assert_eq!(lines("SAFEDEPS_REPO_DIR"), ["SAFEDEPS_REPO_DIR=$(cd -P \"${SAFEDEPS_BIN_DIR}/..\" && pwd)"]);
}

#[test]
fn code_lines_reads_prose_and_code_apart() {
    let text = "# clean in a comment\n\
                sf_warn \"still clean\"\n\
                printf 'clean\\n' >&2\n\
                printf 'clean\\n'\n\
                echo \"clean\"\n\
                [[ \"$s\" = clean ]]\n\
                case \"$s\" in clean) : ;; esac\n\
                status_clean=1\n\
                x=\"${SAFEDEPS_STATUS_CLEAN}\" # clean\n\
                cmd_help() {\n\
                cat <<'EOF'\n\
                exit 0 clean\n\
                EOF\n\
                jq -r '.clean' <<EOF\n\
                clean\n\
                EOF\n\
                cat <<EOF | jq -c .\n\
                \"clean\"\n\
                EOF\n\
                }\n\
                cat <<EOF\n\
                captured clean\n\
                EOF\n\
                cmd_help() {\n\
                } # end\n\
                f() {\n\
                cat <<EOF\n\
                after clean\n\
                EOF\n\
                sf_info \"ok\"; [[ \"$s\" == \"clean\" ]]\n\
                sf_err \"read $(jq -r '.clean' f)\"\n\
                sf_warn \"${s:=clean}\"\n\
                printf -v w %s \"clean\" >&2\n\
                printf -vw '%s' \"clean\" >&2\n\
                printf '%s' \"clean\" >&2\n\
                sf_info status \\'$(x clean)\\'\n\
                sf_info \"status '$x' clean\"\n\
                sf_warn \"$[n=1] clean\"\n\
                sf_warn \"${a[i++]} clean\"\n\
                sf_warn \"${x:-${y}} clean\"\n\
                sf_warn \"${x:-ok} $1 $@ clean\"\n\
                cmd_help() {\n\
                cat <<EOF\n\
                ${SAFEDEPS_VERSION} clean\n\
                $(date) clean\n\
                EOF\n\
                }\n\
                sf_warn \"open clean\n";
    assert_eq!(code_lines(text, "clean", word), [
        "printf 'clean\\n'", "echo \"clean\"", "[[ \"$s\" = clean ]]", "case \"$s\" in clean) : ;; esac",
        "x=\"${SAFEDEPS_STATUS_CLEAN}\" # clean", "jq -r '.clean' <<EOF", "clean", "\"clean\"", "captured clean", "after clean",
        "sf_info \"ok\"; [[ \"$s\" == \"clean\" ]]", "sf_err \"read $(jq -r '.clean' f)\"", "sf_warn \"${s:=clean}\"",
        "printf -v w %s \"clean\" >&2", "printf -vw '%s' \"clean\" >&2", "sf_info status \\'$(x clean)\\'", "sf_warn \"$[n=1] clean\"", "sf_warn \"${a[i++]} clean\"", "sf_warn \"${x:-${y}} clean\"",
        "$(date) clean", "sf_warn \"open clean"]);
    let names = "SAFEDEPS_X=\"x\"\na=\"${SAFEDEPS_X}\" b=(\"${SAFEDEPS_X[@]}\")\nprintf -v SAFEDEPS_X %s y\nSAFEDEPS_X+=_y\n\
                 read -r SAFEDEPS_X <<< y\nlocal SAFEDEPS_X\n: \"${SAFEDEPS_X:=y}\"\n# SAFEDEPS_X=y\nSAFEDEPS_XY=1\n\
                 printf -vSAFEDEPS_X %s y\nsf_warn \"$[SAFEDEPS_X=1]\"\nsf_warn \"${SAFEDEPS_X} ok\"\n";
    assert_eq!(bare_uses(names, "SAFEDEPS_X"), ["SAFEDEPS_X=\"x\"", "printf -v SAFEDEPS_X %s y", "SAFEDEPS_X+=_y",
        "read -r SAFEDEPS_X <<< y", "local SAFEDEPS_X", ": \"${SAFEDEPS_X:=y}\"", "printf -vSAFEDEPS_X %s y", "sf_warn \"$[SAFEDEPS_X=1]\""]);
    let defs = "f() {\nf () { :; }\nfunction f {\n  f \"$x\"\nx='def f: 1; def g(a): a; g(f)'\nif f; then :; fi\nff() { :; }\n";
    assert_eq!(definitions(defs, "f"), ["f() {", "f () { :; }", "function f {", "x='def f: 1; def g(a): a; g(f)'"]);
    assert_eq!(definitions(defs, "g"), ["x='def f: 1; def g(a): a; g(f)'"]);
    assert_eq!(["f() {", "f () { :; }", "function f {", "function  f() {", "  f \"$x\"", "f=(a)", "if f; then"].map(opens_function),
        [Some("f"), Some("f"), Some("f"), Some("f"), None, None, None]);
}
