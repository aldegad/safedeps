//! Where a word of a CLI shell file is code, for the tests that hold a
//! declared name to its declaration. A list of the forms a spelling can take
//! keeps missing one, so the places a declared word may stand as prose are
//! the list instead: a comment line, the body of a `cat` heredoc (the help
//! text), and a quoted string on a line that prints a message. Every other
//! whole-word occurrence is code, whatever its form.

/// The functions and commands whose quoted arguments are text for a person.
/// `printf` and `echo` count only when the line sends them to stderr: on
/// stdout they are how a shell function returns a value.
const MESSAGES: [&str; 8] = ["sf_advisory_log", "sf_eprintf", "sf_err", "sf_info", "sf_ok", "sf_spinner_start", "sf_warn", "safedeps_provider_log"];

/// The lines of `text` where `word` stands whole in code. `part` says which
/// bytes continue a word, so `fixture` inside `safedeps_npm_fixture_closure`
/// is not one.
pub fn code_lines<'a>(text: &'a str, word: &str, part: fn(u8) -> bool) -> Vec<&'a str> {
    let mut heredoc: Option<&str> = None;
    let mut found = Vec::new();
    for line in text.lines() {
        if let Some(end) = heredoc {
            if line.trim_start_matches('\t') == end { heredoc = None }
            continue;
        }
        let code = line.trim_start();
        if code.starts_with('#') { continue }
        heredoc = cat_heredoc(code);
        let first = code.split_whitespace().next().unwrap_or("");
        let message = MESSAGES.contains(&first) || (matches!(first, "printf" | "echo") && code.trim_end().ends_with(">&2"));
        let scanned = if message { unquoted(code) } else { code.as_bytes().to_vec() };
        let whole = |at: usize| (at == 0 || !part(scanned[at - 1])) && scanned.get(at + word.len()).is_none_or(|b| !part(*b));
        if scanned.windows(word.len()).enumerate().any(|(at, w)| w == word.as_bytes() && whole(at)) { found.push(line) }
    }
    found
}

/// The delimiter of a `cat` heredoc this line opens, if it opens one.
fn cat_heredoc(code: &str) -> Option<&str> {
    let (_, rest) = code.split_once("cat <<")?;
    let rest = rest.strip_prefix('-').unwrap_or(rest).trim_start_matches(['\'', '"']);
    let end = rest.find(|c: char| !(c.is_ascii_alphanumeric() || c == '_')).unwrap_or(rest.len());
    (end > 0).then(|| &rest[..end])
}

/// The line with each quoted string blanked out.
fn unquoted(code: &str) -> Vec<u8> {
    let mut out = code.as_bytes().to_vec();
    let mut i = 0;
    while i < out.len() {
        let quote = out[i];
        if quote == b'\'' || quote == b'"' {
            let mut j = i + 1;
            while j < out.len() && out[j] != quote {
                if quote == b'"' && out[j] == b'\\' { j += 1 }
                j += 1;
            }
            let end = j.min(out.len() - 1) + 1;
            for b in &mut out[i..end] { *b = b' ' }
            i = j + 1;
        } else {
            i += 1;
        }
    }
    out
}

#[test]
fn code_lines_reads_prose_and_code_apart() {
    let word = |b: u8| b.is_ascii_alphanumeric() || b == b'_';
    let text = "# clean in a comment\n\
                sf_warn \"still clean\"\n\
                printf 'clean\\n' >&2\n\
                printf 'clean\\n'\n\
                echo \"clean\"\n\
                [[ \"$s\" = clean ]]\n\
                case \"$s\" in clean) : ;; esac\n\
                status_clean=1\n\
                x=\"${SAFEDEPS_STATUS_CLEAN}\" # clean\n\
                cat <<'EOF'\n\
                exit 0 clean\n\
                EOF\n\
                jq -r '.clean' <<EOF\n\
                clean\n\
                EOF\n";
    assert_eq!(code_lines(text, "clean", word), [
        "printf 'clean\\n'", "echo \"clean\"", "[[ \"$s\" = clean ]]", "case \"$s\" in clean) : ;; esac",
        "x=\"${SAFEDEPS_STATUS_CLEAN}\" # clean", "jq -r '.clean' <<EOF", "clean"]);
}
